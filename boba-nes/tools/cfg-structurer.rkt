#lang racket/base

;; ============================================================================
;; tools/cfg-structurer.rkt
;; Deterministic Control-Flow Graph (CFG) Structurer, State-Machine Dispatcher
;; Lifter & High-Level Hardware/Physics Idiom Recognizer for:
;;   - MOS 6502 (NES)
;;   - Sharp SM83 / LR35902 (Game Boy & Game Boy Color)
;; ============================================================================

(require racket/bytes
         racket/format
         racket/list
         racket/match
         racket/set
         racket/string)

(provide
 STRUCTURED-CFG-TAGS
 structured-cfg-form?
 flatten-structured-insts
 decode-hw-bitfield-flags
 infer-subroutine-abi-signature
 build-memory-layout-sexp
 infer-nes-rom-memory-layout
 infer-sm83-rom-memory-layout
 structure-subroutine-cfg
 synthesize-subroutine-pseudo-code
 lift-nes-state-machines-and-idioms
 lift-sm83-state-machines-and-idioms)

;; ============================================================================
;; 1. Recursive Instruction Extractor (`flatten-structured-insts`)
;; ============================================================================

(define STRUCTURED-CFG-TAGS
  '(when-branch
    if-else
    then-branch
    else-branch
    counted-loop
    spin-wait-mmio-loop
    do-while-loop
    guard-return))

(define (structured-cfg-form? form)
  (and (pair? form)
       (memq (car form) STRUCTURED-CFG-TAGS)
       #t))

;; Strip leading keyword-value arguments (`#:header-pc ... #:cond ...`) from a structured form's tail
(define (strip-leading-kw-args rem)
  (match rem
    [(list* (? keyword?) _ rest)
     (strip-leading-kw-args rest)]
    [_ rem]))

;; Given any subroutine body containing a mix of raw instruction S-expressions
;; (e.g. `(LDA #:imm #x10 #:pc #x8002)`), `(decompiled-pseudo-code ...)`, and
;; structured control-flow forms (`(when-branch ...)`, `(if-else ...)`,
;; `(counted-loop ...)`, `(spin-wait-mmio-loop ...)`, `(do-while-loop ...)`,
;; `(guard-return ...)`), recursively extracts all leaf instruction S-expressions
;; in exact PC order while ignoring `(decompiled-pseudo-code ...)`.
(define (flatten-structured-insts body-forms)
  (let loop ([forms body-forms]
             [acc '()])
    (cond
      [(null? forms)
       (reverse acc)]
      [else
       (define f (car forms))
       (cond
         [(and (pair? f) (eq? (car f) 'decompiled-pseudo-code))
          (loop (cdr forms) acc)]
         [(structured-cfg-form? f)
          (define children (strip-leading-kw-args (cdr f)))
          (define flat-children (flatten-structured-insts children))
          (loop (cdr forms) (append (reverse flat-children) acc))]
         [(and (pair? f) (symbol? (car f)) (not (keyword? (car f))))
          (loop (cdr forms) (cons f acc))]
         [else
          (loop (cdr forms) acc)])])))

;; ============================================================================
;; 2. Instruction Inspection Helpers & Condition Tables (MOS 6502 + Sharp SM83)
;; ============================================================================

(define (inst-mnem inst)
  (and (pair? inst) (car inst)))

(define (inst-mode inst)
  (and (pair? inst) (pair? (cdr inst)) (cadr inst)))

(define (inst-operand inst)
  (and (pair? inst) (pair? (cdr inst)) (pair? (cddr inst)) (caddr inst)))

(define (inst-pc inst)
  (let loop ([rem (if (and (pair? inst) (pair? (cdr inst)) (pair? (cddr inst)))
                      (cdddr inst)
                      '())])
    (match rem
      [(list* '#:pc pc _) pc]
      [(cons _ rest) (loop rest)]
      ['() #f])))

(define (inst-sym inst)
  (let loop ([rem (if (and (pair? inst) (pair? (cdr inst)) (pair? (cddr inst)))
                      (cdddr inst)
                      '())])
    (match rem
      [(list* '#:sym s _) s]
      [(cons _ rest) (loop rest)]
      ['() #f])))

(define (inst-byte-len inst arch)
  (define mode (inst-mode inst))
  (case arch
    [(mos6502)
     (case mode
       [(#:imp #:acc) 1]
       [(#:imm #:zp #:zpx #:zpy #:indx #:indy #:rel) 2]
       [(#:abs #:absx #:absy #:ind) 3]
       [else 1])]
    [(sm83)
     (case mode
       [(#:imp) 1]
       [(#:cb #:d8 #:io8 #:rel) 2]
       [(#:d16 #:a16) 3]
       [else 1])]
    [else 1]))

;; Condition name & logical negation tables for 6502 and SM83 branches
(define COND-INFO-HASH
  (hasheq
   ;; MOS 6502 conditional branches
   'BPL (cons 'plus/positive       'minus/negative)
   'BMI (cons 'minus/negative      'plus/positive)
   'BEQ (cons 'zero/equal          'not-zero/not-equal)
   'BNE (cons 'not-zero/not-equal  'zero/equal)
   'BCC (cons 'carry-clear/lt      'carry-set/ge)
   'BCS (cons 'carry-set/ge        'carry-clear/lt)
   'BVC (cons 'overflow-clear      'overflow-set)
   'BVS (cons 'overflow-set        'overflow-clear)
   ;; Sharp SM83 conditional branches & conditional returns
   'JR_Z   (cons 'zero     'not-zero)
   'JR_NZ  (cons 'not-zero 'zero)
   'JR_C   (cons 'carry    'no-carry)
   'JR_NC  (cons 'no-carry 'carry)
   'JP_Z   (cons 'zero     'not-zero)
   'JP_NZ  (cons 'not-zero 'zero)
   'JP_C   (cons 'carry    'no-carry)
   'JP_NC  (cons 'no-carry 'carry)
   'RET_Z  (cons 'zero     'not-zero)
   'RET_NZ (cons 'not-zero 'zero)
   'RET_C  (cons 'carry    'no-carry)
   'RET_NC (cons 'no-carry 'carry)))

(define (cond-branch-mnem? mnem arch)
  (case arch
    [(mos6502)
     (and (memq mnem '(BPL BMI BVC BVS BCC BCS BNE BEQ)) #t)]
    [(sm83)
     (and (memq mnem '(JR_NZ JR_Z JR_NC JR_C JP_NZ JP_Z JP_NC JP_C)) #t)]
    [else #f]))

(define (uncond-jump-inst? inst arch)
  (define mnem (inst-mnem inst))
  (define mode (inst-mode inst))
  (case arch
    [(mos6502)
     (and (eq? mnem 'JMP) (eq? mode '#:abs))]
    [(sm83)
     (or (and (eq? mnem 'JR) (eq? mode '#:rel))
         (and (eq? mnem 'JP) (eq? mode '#:a16)))]
    [else #f]))

(define (return-inst? inst arch)
  (define mnem (inst-mnem inst))
  (case arch
    [(mos6502) (and (memq mnem '(RTS RTI)) #t)]
    [(sm83)    (and (memq mnem '(RET RETI)) #t)]
    [else #f]))

(define (sm83-cond-return-inst? inst arch)
  (and (eq? arch 'sm83)
       (memq (inst-mnem inst) '(RET_NZ RET_Z RET_NC RET_C))
       #t))

(define (branch-cond-sym mnem)
  (car (hash-ref COND-INFO-HASH mnem (cons 'branch-cond 'neg-branch-cond))))

(define (branch-neg-cond-sym mnem)
  (cdr (hash-ref COND-INFO-HASH mnem (cons 'branch-cond 'neg-branch-cond))))

(define MMIO-POLL-SYMS
  (seteq
   ;; NES 2C02 / 2A03 MMIO registers
   'PPUCTRL 'PPUMASK 'PPUSTATUS 'OAMADDR 'OAMDATA 'PPUSCROLL 'PPUADDR 'PPUDATA
   'OAMDMA 'SND_CHN 'JOY1 'JOY2
   ;; DMG / CGB SM83 MMIO registers
   'JOYP 'SB 'SC 'DIV 'TIMA 'TMA 'TAC 'IF 'IE
   'LCDC 'STAT 'SCY 'SCX 'LY 'LYC 'DMA 'BGP 'OBP0 'OBP1 'WY 'WX
   'KEY1 'VBK 'HDMA1 'HDMA2 'HDMA3 'HDMA4 'HDMA5 'RP 'BCPS 'BCPD 'OCPS 'OCPD 'SVBK
   'NR10 'NR11 'NR12 'NR13 'NR14 'NR21 'NR22 'NR23 'NR24
   'NR30 'NR31 'NR32 'NR33 'NR34 'NR41 'NR42 'NR43 'NR44 'NR50 'NR51 'NR52))

(define ALL-HW-MMIO-SYMS
  (set-union
   MMIO-POLL-SYMS
   (seteq
    'SQ1_VOL 'SQ1_SWEEP 'SQ1_LO 'SQ1_HI
    'SQ2_VOL 'SQ2_SWEEP 'SQ2_LO 'SQ2_HI
    'TRI_LINEAR 'TRI_UNUSED 'TRI_LO 'TRI_HI
    'NOISE_VOL 'NOISE_UNUSED 'NOISE_LO 'NOISE_HI
    'DMC_FREQ 'DMC_RAW 'DMC_START 'DMC_LEN
    'MMC1_CTRL 'MMC1_CHR0 'MMC1_CHR1 'MAPPER_PRG_BANK
    'MBC_RAM_EN 'MBC_ROM_BANK 'MBC_RAM_BANK 'MBC_BANK_MODE
    'WAVE_RAM_0 'WAVE_RAM_1 'WAVE_RAM_2 'WAVE_RAM_3
    'WAVE_RAM_4 'WAVE_RAM_5 'WAVE_RAM_6 'WAVE_RAM_7
    'WAVE_RAM_8 'WAVE_RAM_9 'WAVE_RAM_A 'WAVE_RAM_B
    'WAVE_RAM_C 'WAVE_RAM_D 'WAVE_RAM_E 'WAVE_RAM_F)))

(define (inst-flags inst)
  (let loop ([rem (if (and (pair? inst) (pair? (cdr inst)) (pair? (cddr inst)))
                      (cdddr inst)
                      '())])
    (match rem
      [(list* '#:flags fl _) fl]
      [(cons _ rest) (loop rest)]
      ['() #f])))

(define (mirror-or-mmio-sym? s)
  (and (symbol? s)
       (or (set-member? ALL-HW-MMIO-SYMS s)
           (regexp-match? #px"(?:_mirror_|_state_|^zp_ptr_)" (symbol->string s)))))

;; Decode an 8-bit hardware bitmask written to PPUCTRL, PPUMASK, LCDC, or STAT into symbolic flags
(define (decode-hw-bitfield-flags reg-sym mask)
  (and (symbol? reg-sym)
       (exact-integer? mask)
       (<= 0 mask #xFF)
       (let* ([s-str (symbol->string reg-sym)]
              [canon-reg
               (cond
                 [(or (eq? reg-sym 'PPUCTRL) (string-prefix? s-str "ppuctrl_mirror_")) 'PPUCTRL]
                 [(or (eq? reg-sym 'PPUMASK) (string-prefix? s-str "ppumask_mirror_")) 'PPUMASK]
                 [(or (eq? reg-sym 'LCDC)    (string-prefix? s-str "lcdc_mirror_"))    'LCDC]
                 [(or (eq? reg-sym 'STAT)    (string-prefix? s-str "stat_mirror_"))    'STAT]
                 [else #f])])
         (case canon-reg
           [(PPUCTRL)
            (if (= mask 0)
                '(PPUCTRL_CLEAR)
                (filter
                 values
                 (list (and (bitwise-bit-set? mask 7) 'NMI_ENABLE)
                       (and (bitwise-bit-set? mask 6) 'PPU_MASTER_EXT)
                       (and (bitwise-bit-set? mask 5) 'SPRITE_8X16)
                       (and (bitwise-bit-set? mask 4) 'BG_PATTERN_1000)
                       (and (bitwise-bit-set? mask 3) 'SPRITE_PATTERN_1000)
                       (and (bitwise-bit-set? mask 2) 'VRAM_INC_32)
                       (case (bitwise-and mask #x03)
                         [(1) 'NAMETABLE_2400]
                         [(2) 'NAMETABLE_2800]
                         [(3) 'NAMETABLE_2C00]
                         [else #f]))))]
           [(PPUMASK)
            (if (= mask 0)
                '(RENDER_DISABLE)
                (filter
                 values
                 (list (and (bitwise-bit-set? mask 7) 'EMPHASIZE_BLUE)
                       (and (bitwise-bit-set? mask 6) 'EMPHASIZE_GREEN)
                       (and (bitwise-bit-set? mask 5) 'EMPHASIZE_RED)
                       (and (bitwise-bit-set? mask 4) 'SHOW_SPRITES)
                       (and (bitwise-bit-set? mask 3) 'SHOW_BG)
                       (and (bitwise-bit-set? mask 2) 'SHOW_SPRITES_LEFT8)
                       (and (bitwise-bit-set? mask 1) 'SHOW_BG_LEFT8)
                       (and (bitwise-bit-set? mask 0) 'GREYSCALE))))]
           [(LCDC)
            (if (= mask 0)
                '(LCD_DISABLE)
                (filter
                 values
                 (list (and (bitwise-bit-set? mask 7) 'LCD_ENABLE)
                       (and (bitwise-bit-set? mask 6) 'WIN_TILEMAP_9C00)
                       (and (bitwise-bit-set? mask 5) 'WIN_ENABLE)
                       (and (bitwise-bit-set? mask 4) 'BG_TILE_8000)
                       (and (bitwise-bit-set? mask 3) 'BG_TILEMAP_9C00)
                       (and (bitwise-bit-set? mask 2) 'OBJ_8X16)
                       (and (bitwise-bit-set? mask 1) 'OBJ_ENABLE)
                       (and (bitwise-bit-set? mask 0) 'BG_WIN_ENABLE))))]
           [(STAT)
            (if (= mask 0)
                '(STAT_INT_DISABLE)
                (filter
                 values
                 (list (and (bitwise-bit-set? mask 6) 'LYC_INT_ENABLE)
                       (and (bitwise-bit-set? mask 5) 'OAM_INT_ENABLE)
                       (and (bitwise-bit-set? mask 4) 'VBLANK_INT_ENABLE)
                       (and (bitwise-bit-set? mask 3) 'HBLANK_INT_ENABLE)
                       (and (bitwise-bit-set? mask 2) 'LYC_EQUAL_FLAG)
                       (case (bitwise-and mask #x03)
                         [(1) 'MODE_VBLANK]
                         [(2) 'MODE_OAM]
                         [(3) 'MODE_VRAM]
                         [else #f]))))]
           [else #f]))))

(define (hex2-str v)
  (string-upcase (~r (bitwise-and #xFF v) #:base 16 #:min-width 2 #:pad-string "0")))

(define (mos6502-operand->sym-expr inst)
  (define mode (inst-mode inst))
  (define operand (or (inst-operand inst) 0))
  (define s (inst-sym inst))
  (define mmio-s (and s (mirror-or-mmio-sym? s) s))
  (case mode
    [(#:imm) operand]
    [(#:acc) 'A]
    [(#:zp)  (or mmio-s `(zp ,operand))]
    [(#:zpx) (if mmio-s `(aref ,mmio-s X) `(aref zp ,operand X))]
    [(#:zpy) (if mmio-s `(aref ,mmio-s Y) `(aref zp ,operand Y))]
    [(#:indx)
     `(deref-indx ,(string->symbol (format "zp_ptr_~a" (hex2-str operand))) X)]
    [(#:indy)
     `(deref-indy ,(string->symbol (format "zp_ptr_~a" (hex2-str operand))) Y)]
    [(#:abs)
     (cond
       [mmio-s mmio-s]
       [(< operand #x0100) `(zp ,operand)]
       [(<= #x0200 operand #x02FF) `(oam ,operand)]
       [(< operand #x2000) `(wram ,operand)]
       [(<= #x6000 operand #x7FFF) `(sram ,operand)]
       [else `(rom ,operand)])]
    [(#:absx)
     (cond
       [mmio-s `(aref ,mmio-s X)]
       [(<= #x0200 operand #x02FF) `(aref oam ,operand X)]
       [(< operand #x2000) `(aref wram ,operand X)]
       [(<= #x6000 operand #x7FFF) `(aref sram ,operand X)]
       [else `(aref rom ,operand X)])]
    [(#:absy)
     (cond
       [mmio-s `(aref ,mmio-s Y)]
       [(<= #x0200 operand #x02FF) `(aref oam ,operand Y)]
       [(< operand #x2000) `(aref wram ,operand Y)]
       [(<= #x6000 operand #x7FFF) `(aref sram ,operand Y)]
       [else `(aref rom ,operand Y)])]
    [else (or s operand)]))

(define (sm83-io-or-mem-sym inst)
  (define mode (inst-mode inst))
  (define op (or (inst-operand inst) 0))
  (define s (inst-sym inst))
  (cond
    [s s]
    [(eq? mode '#:io8)
     (define addr (+ #xFF00 op))
     (string->symbol (format "HRAM_~a" (string-upcase (~r addr #:base 16 #:min-width 4 #:pad-string "0"))))]
    [(and (eq? mode '#:a16) (>= op #xC000) (< op #xE000))
     `(wram ,op)]
    [(and (eq? mode '#:a16) (>= op #x8000) (< op #xA000))
     `(vram ,op)]
    [(and (eq? mode '#:a16) (>= op #xA000) (< op #xC000))
     `(sram ,op)]
    [else op]))

;; Infer a folded symbolic condition expression for a branch at `b-idx`
(define (infer-branch-cond-expr ivec b-idx negated? arch)
  (define b-inst (vector-ref ivec b-idx))
  (define b-mnem (inst-mnem b-inst))
  (define eff-cond (if negated? (branch-neg-cond-sym b-mnem) (branch-cond-sym b-mnem)))
  (case arch
    [(mos6502)
     (define (find-recent-a-src limit-idx)
       (let loop ([k (sub1 limit-idx)])
         (if (< k (max 0 (- limit-idx 3)))
             'A
             (let* ([ins (vector-ref ivec k)]
                    [m (inst-mnem ins)])
               (cond
                 [(eq? m 'LDA) (mos6502-operand->sym-expr ins)]
                 [(eq? m 'TXA) 'X]
                 [(eq? m 'TYA) 'Y]
                 [(memq m '(JSR RTS RTI JMP BPL BMI BVC BVS BCC BCS BNE BEQ)) 'A]
                 [else (loop (sub1 k))])))))
     (let scan ([k (sub1 b-idx)])
       (if (< k (max 0 (- b-idx 4)))
           (case eff-cond
             [(zero/equal)         '(== A 0)]
             [(not-zero/not-equal) '(!= A 0)]
             [(plus/positive)      '(>= A 0)]
             [(minus/negative)     '(< A 0)]
             [(carry-clear/lt)     '(== carry 0)]
             [(carry-set/ge)       '(== carry 1)]
             [else eff-cond])
           (let* ([ins (vector-ref ivec k)]
                  [m (inst-mnem ins)])
             (cond
               [(memq m '(CMP CPX CPY))
                (define lhs
                  (case m
                    [(CMP) (find-recent-a-src k)]
                    [(CPX) 'X]
                    [(CPY) 'Y]))
                (define rhs (mos6502-operand->sym-expr ins))
                (case eff-cond
                  [(zero/equal)         `(== ,lhs ,rhs)]
                  [(not-zero/not-equal) `(!= ,lhs ,rhs)]
                  [(carry-clear/lt)     `(< ,lhs ,rhs)]
                  [(carry-set/ge)       `(>= ,lhs ,rhs)]
                  [(plus/positive)      `(>= (- ,lhs ,rhs) 0)]
                  [(minus/negative)     `(< (- ,lhs ,rhs) 0)]
                  [else `(,eff-cond ,lhs ,rhs)])]
               [(memq m '(DEX INX))
                (case eff-cond
                  [(zero/equal)         '(== X 0)]
                  [(not-zero/not-equal) '(!= X 0)]
                  [(plus/positive)      '(>= X 0)]
                  [(minus/negative)     '(< X 0)]
                  [else `(,eff-cond X 0)])]
               [(memq m '(DEY INY))
                (case eff-cond
                  [(zero/equal)         '(== Y 0)]
                  [(not-zero/not-equal) '(!= Y 0)]
                  [(plus/positive)      '(>= Y 0)]
                  [(minus/negative)     '(< Y 0)]
                  [else `(,eff-cond Y 0)])]
               [(memq m '(DEC INC))
                (define dst (mos6502-operand->sym-expr ins))
                (case eff-cond
                  [(zero/equal)         `(== ,dst 0)]
                  [(not-zero/not-equal) `(!= ,dst 0)]
                  [(plus/positive)      `(>= ,dst 0)]
                  [(minus/negative)     `(< ,dst 0)]
                  [else `(,eff-cond ,dst 0)])]
               [(eq? m 'BIT)
                (define dst (mos6502-operand->sym-expr ins))
                (case eff-cond
                  [(plus/positive)      `(== (bit-and ,dst #x80) 0)]
                  [(minus/negative)     `(!= (bit-and ,dst #x80) 0)]
                  [(overflow-clear)     `(== (bit-and ,dst #x40) 0)]
                  [(overflow-set)       `(!= (bit-and ,dst #x40) 0)]
                  [(zero/equal)         `(== (bit-and A ,dst) 0)]
                  [(not-zero/not-equal) `(!= (bit-and A ,dst) 0)]
                  [else `(bit-test ,dst ,eff-cond)])]
               [(memq m '(AND ORA EOR))
                (define lhs (find-recent-a-src k))
                (define rhs (mos6502-operand->sym-expr ins))
                (define op-sym (case m [(AND) 'bit-and] [(ORA) 'bit-ior] [(EOR) 'bit-xor]))
                (case eff-cond
                  [(zero/equal)         `(== (,op-sym ,lhs ,rhs) 0)]
                  [(not-zero/not-equal) `(!= (,op-sym ,lhs ,rhs) 0)]
                  [(plus/positive)      `(== (bit-and (,op-sym ,lhs ,rhs) #x80) 0)]
                  [(minus/negative)     `(!= (bit-and (,op-sym ,lhs ,rhs) #x80) 0)]
                  [else `(,eff-cond (,op-sym ,lhs ,rhs) 0)])]
               [(memq m '(LDA LDX LDY))
                (define src (mos6502-operand->sym-expr ins))
                (case eff-cond
                  [(zero/equal)         `(== ,src 0)]
                  [(not-zero/not-equal) `(!= ,src 0)]
                  [(plus/positive)      `(== (bit-and ,src #x80) 0)]
                  [(minus/negative)     `(!= (bit-and ,src #x80) 0)]
                  [else `(,eff-cond ,src 0)])]
               [(memq m '(JSR RTS RTI JMP BPL BMI BVC BVS BCC BCS BNE BEQ))
                (scan -1)]
               [else
                (scan (sub1 k))]))))]
    [(sm83)
     (define (find-recent-sm83-a limit-idx)
       (let loop ([k (sub1 limit-idx)])
         (if (< k (max 0 (- limit-idx 3)))
             'A
             (let* ([ins (vector-ref ivec k)]
                    [m (inst-mnem ins)])
               (cond
                 [(eq? m 'LDH_IN) (sm83-io-or-mem-sym ins)]
                 [(eq? m 'LD_A_A16) (sm83-io-or-mem-sym ins)]
                 [(eq? m 'LD_A_HLI) '(deref HL++)]
                 [(eq? m 'LD_A_HLD) '(deref HL--)]
                 [(eq? m 'LD_A_HL-IND) '(deref HL)]
                 [(eq? m 'LD_A_DE_IND) '(deref DE)]
                 [(eq? m 'LD_A_BC_IND) '(deref BC)]
                 [else (loop (sub1 k))])))))
     (let scan ([k (sub1 b-idx)])
       (if (< k (max 0 (- b-idx 4)))
           (case eff-cond
             [(zero)     '(== A 0)]
             [(not-zero) '(!= A 0)]
             [(carry)    '(== carry 1)]
             [(no-carry) '(== carry 0)]
             [else eff-cond])
           (let* ([ins (vector-ref ivec k)]
                  [m (inst-mnem ins)]
                  [m-str (symbol->string m)])
             (cond
               [(eq? m 'CP_A)
                (define lhs (find-recent-sm83-a k))
                (define rhs (or (inst-operand ins) 0))
                (case eff-cond
                  [(zero)     `(== ,lhs ,rhs)]
                  [(not-zero) `(!= ,lhs ,rhs)]
                  [(carry)    `(< ,lhs ,rhs)]
                  [(no-carry) `(>= ,lhs ,rhs)]
                  [else `(,eff-cond ,lhs ,rhs)])]
               [(regexp-match #px"^CP_A_(.+)$" m-str)
                => (lambda (mt)
                     (define r (string->symbol (second mt)))
                     (define rhs (if (eq? r 'HL-IND) '(deref HL) r))
                     (case eff-cond
                       [(zero)     `(== A ,rhs)]
                       [(not-zero) `(!= A ,rhs)]
                       [(carry)    `(< A ,rhs)]
                       [(no-carry) `(>= A ,rhs)]
                       [else `(,eff-cond A ,rhs)]))]
               [(regexp-match #px"^BIT_([0-7])_(.+)$" m-str)
                => (lambda (mt)
                     (define bit (string->number (second mt)))
                     (define r (string->symbol (third mt)))
                     (define tgt (if (eq? r 'HL-IND) '(deref HL) r))
                     (case eff-cond
                       [(zero)     `(== (bit-test? ,tgt ,bit) 0)]
                       [(not-zero) `(bit-test? ,tgt ,bit)]
                       [else `(bit-test? ,tgt ,bit)]))]
               [(regexp-match #px"^(?:DEC|INC)_(.+)$" m-str)
                => (lambda (mt)
                     (define r (string->symbol (second mt)))
                     (define tgt (if (or (eq? r 'HL_IND) (eq? r 'HL-IND)) '(deref HL) r))
                     (case eff-cond
                       [(zero)     `(== ,tgt 0)]
                       [(not-zero) `(!= ,tgt 0)]
                       [else `(,eff-cond ,tgt 0)]))]
               [(eq? m 'AND_A)
                (define lhs (find-recent-sm83-a k))
                (define mask (or (inst-operand ins) 0))
                (case eff-cond
                  [(zero)     `(== (bit-and ,lhs ,mask) 0)]
                  [(not-zero) `(!= (bit-and ,lhs ,mask) 0)]
                  [else `(,eff-cond (bit-and ,lhs ,mask) 0)])]
               [(or (eq? m 'OR_A_C) (eq? m 'OR_A_B))
                (case eff-cond
                  [(zero)     '(== BC 0)]
                  [(not-zero) '(!= BC 0)]
                  [else `(,eff-cond BC 0)])]
               [(or (eq? m 'OR_A_A) (eq? m 'AND_A_A))
                (define lhs (find-recent-sm83-a k))
                (case eff-cond
                  [(zero)     `(== ,lhs 0)]
                  [(not-zero) `(!= ,lhs 0)]
                  [else `(,eff-cond ,lhs 0)])]
               [else
                (scan (sub1 k))]))))]
    [else eff-cond]))

(define LOOP-STEP-MNEMS
  (seteq
   ;; 6502 index/memory counter step instructions
   'DEX 'DEY 'INX 'INY 'DEC 'INC
   ;; SM83 index/pointer/counter step instructions
   'DEC_B 'DEC_C 'DEC_D 'DEC_E 'DEC_H 'DEC_L 'DEC_A
   'DEC_HL_IND 'DEC_HL-IND 'DEC_BC 'DEC_DE 'DEC_HL
   'INC_B 'INC_C 'INC_D 'INC_E 'INC_H 'INC_L 'INC_A
   'INC_HL_IND 'INC_HL-IND 'INC_BC 'INC_DE 'INC_HL
   'LD_HLD_A 'LD_HLI_A 'LD_A_HLD 'LD_A_HLI))

;; ============================================================================
;; 3. Subroutine Control-Flow Structurer (`structure-subroutine-cfg`)
;; ============================================================================

(define (vec-slice->list vec start-idx end-idx)
  (for/list ([k (in-range start-idx (add1 end-idx))])
    (vector-ref vec k)))

(define (range-unclaimed? claimed-vec start-idx end-idx)
  (for/and ([k (in-range start-idx (add1 end-idx))])
    (not (vector-ref claimed-vec k))))

(define (claim-range! claimed-vec start-idx end-idx val)
  (for ([k (in-range start-idx (add1 end-idx))])
    (vector-set! claimed-vec k val)))

;; Find MMIO register symbol in a loop slice `[h-idx .. l-idx]` (also checking `h-idx - 1`
;; for `LD_HL #:d16 <mmio> #:sym <STAT/LY>` setup immediately preceding the spin loop)
(define (find-loop-mmio-sym ivec h-idx l-idx)
  (or (for/or ([k (in-range h-idx (add1 l-idx))])
        (define s (inst-sym (vector-ref ivec k)))
        (and s (set-member? MMIO-POLL-SYMS s) s))
      (and (> h-idx 0)
           (let ([s (inst-sym (vector-ref ivec (sub1 h-idx)))])
             (and s (set-member? MMIO-POLL-SYMS s) s)))))

;; Find counter/index step mnemonic inside a loop body `[h-idx .. l-idx]`
(define (find-loop-step-mnem ivec h-idx l-idx)
  (for/or ([k (in-range h-idx (add1 l-idx))])
    (define m (inst-mnem (vector-ref ivec k)))
    (and (set-member? LOOP-STEP-MNEMS m) m)))

(define (structure-subroutine-cfg insts #:arch [arch 'mos6502])
  (define n (length insts))
  (cond
    [(= n 0)
     (values '() (hasheq 'loops 0 'spin-waits 0 'conditionals 0 'guard-returns 0))]
    [else
     (define ivec (list->vector insts))
     (define pc->idx (make-hasheq))
     (for ([i (in-range n)])
       (define pc (inst-pc (vector-ref ivec i)))
       (when pc
         (hash-set! pc->idx pc i)))

     (define sub-start-pc (or (inst-pc (vector-ref ivec 0)) 0))
     (define last-inst (vector-ref ivec (sub1 n)))
     (define sub-end-pc (+ (or (inst-pc last-inst) 0)
                           (inst-byte-len last-inst arch)))

     ;; Track claimed instruction indices `0 .. n-1` and region builders keyed by `start-idx`
     (define claimed (make-vector n #f))
     (define region-at-start (make-hasheq))

     (define loop-count 0)
     (define spin-wait-count 0)
     (define cond-count 0)
     (define guard-ret-count 0)

     ;; ------------------------------------------------------------------------
     ;; Pass 1: Backward Branches -> `spin-wait-mmio-loop`, `counted-loop`, `do-while-loop`
     ;; ------------------------------------------------------------------------
     (define loop-candidates '())
     (for ([l-idx (in-range n)])
       (define inst (vector-ref ivec l-idx))
       (define mnem (inst-mnem inst))
       (when (cond-branch-mnem? mnem arch)
         (define branch-pc (inst-pc inst))
         (define target-pc (inst-operand inst))
         (define h-idx (and target-pc (hash-ref pc->idx target-pc #f)))
         (when (and h-idx
                    branch-pc
                    (<= target-pc branch-pc)
                    (>= target-pc sub-start-pc)
                    (<= h-idx l-idx))
           (set! loop-candidates
                 (cons (list (- l-idx h-idx) h-idx l-idx target-pc branch-pc mnem)
                       loop-candidates)))))

     ;; Sort loop candidates by span length (innermost/tightest first, then by header index)
     (define sorted-loops
       (sort loop-candidates
             (lambda (a b)
               (if (= (first a) (first b))
                   (< (second a) (second b))
                   (< (first a) (first b))))))

     (for ([cand (in-list sorted-loops)])
       (match-define (list _span h-idx l-idx header-pc latch-pc mnem) cand)
       (define num-insts (add1 (- l-idx h-idx)))
       (when (range-unclaimed? claimed h-idx l-idx)
         (define body-slice (vec-slice->list ivec h-idx l-idx))
         (define c-sym (branch-cond-sym mnem))
         (define c-expr (infer-branch-cond-expr ivec l-idx #f arch))
         (define mmio-sym (and (<= num-insts 6) (find-loop-mmio-sym ivec h-idx l-idx)))
         (define step-mnem (find-loop-step-mnem ivec h-idx l-idx))
         (define form
           (cond
             [mmio-sym
              (set! spin-wait-count (add1 spin-wait-count))
              (set! loop-count (add1 loop-count))
              `(spin-wait-mmio-loop
                #:header-pc ,header-pc
                #:latch-pc ,latch-pc
                #:mmio ,mmio-sym
                #:cond ,c-sym
                #:cond-expr ,c-expr
                ,@body-slice)]
             [step-mnem
              (set! loop-count (add1 loop-count))
              `(counted-loop
                #:header-pc ,header-pc
                #:latch-pc ,latch-pc
                #:step ,step-mnem
                #:cond ,c-sym
                #:cond-expr ,c-expr
                ,@body-slice)]
             [else
              (set! loop-count (add1 loop-count))
              `(do-while-loop
                #:header-pc ,header-pc
                #:latch-pc ,latch-pc
                #:cond ,c-sym
                #:cond-expr ,c-expr
                ,@body-slice)]))
         (claim-range! claimed h-idx l-idx 'loop)
         (hash-set! region-at-start h-idx (cons l-idx form))))

     ;; ------------------------------------------------------------------------
     ;; Pass 2: Forward Conditional Branches & Conditional Returns ->
     ;;         `guard-return`, `if-else`, `when-branch`
     ;; ------------------------------------------------------------------------
     (let scan ([i 0])
       (when (< i n)
         (cond
           [(vector-ref claimed i)
            (scan (add1 i))]
           [else
            (define inst (vector-ref ivec i))
            (define mnem (inst-mnem inst))
            (define b-pc (inst-pc inst))
            (cond
              ;; 4a. SM83 single-instruction conditional return (`RET_NZ`, `RET_Z`, `RET_NC`, `RET_C`)
              [(sm83-cond-return-inst? inst arch)
               (define c-sym (branch-cond-sym mnem))
               (define c-expr (infer-branch-cond-expr ivec i #f arch))
               (define form `(guard-return #:branch-pc ,b-pc #:cond ,c-sym #:cond-expr ,c-expr ,inst))
               (claim-range! claimed i i 'guard-return)
               (hash-set! region-at-start i (cons i form))
               (set! guard-ret-count (add1 guard-ret-count))
               (set! cond-count (add1 cond-count))
               (scan (add1 i))]

              ;; Forward conditional branch at index `i`
              [(cond-branch-mnem? mnem arch)
               (define target-pc (inst-operand inst))
               (define target-idx
                 (cond
                   [(and target-pc (hash-ref pc->idx target-pc #f)) => values]
                   [(and target-pc (= target-pc sub-end-pc)) n]
                   [else #f]))
               (cond
                 [(not (and b-pc target-pc (> target-pc b-pc) target-idx (> target-idx (add1 i))))
                  (scan (add1 i))]
                 [else
                  (define span-len (- target-idx i)) ; number of instructions from `i` to `target-idx - 1`
                  (define end-idx (sub1 target-idx))
                  (define prev-inst (vector-ref ivec end-idx))
                  (cond
                    ;; 4b. `guard-return`: forward conditional branch skipping 1..3 instructions ending in RTS/RET/RETI
                    [(and (<= 2 span-len 4)
                          (return-inst? prev-inst arch)
                          (range-unclaimed? claimed i end-idx))
                     (define c-sym (branch-neg-cond-sym mnem))
                     (define c-expr (infer-branch-cond-expr ivec i #t arch))
                     (define form
                       `(guard-return
                         #:branch-pc ,b-pc
                         #:cond ,c-sym
                         #:cond-expr ,c-expr
                         ,@(vec-slice->list ivec i end-idx)))
                     (claim-range! claimed i end-idx 'guard-return)
                     (hash-set! region-at-start i (cons end-idx form))
                     (set! guard-ret-count (add1 guard-ret-count))
                     (set! cond-count (add1 cond-count))
                     (scan (add1 end-idx))]

                    ;; 5. `if-else`: `prev-inst` immediately preceding `else-pc` (`target-pc`) is a forward
                    ;;    unconditional JMP/JR/JP to `merge-pc > else-pc` within the subroutine
                    [(and (< target-idx n)
                          (uncond-jump-inst? prev-inst arch)
                          (let ([merge-pc (inst-operand prev-inst)])
                            (and merge-pc
                                 (> merge-pc target-pc)
                                 (or (hash-ref pc->idx merge-pc #f)
                                     (and (= merge-pc sub-end-pc) n)))))
                     => (lambda (merge-idx)
                          (define merge-pc (inst-operand prev-inst))
                          (define else-end-idx (sub1 merge-idx))
                          (if (and (>= else-end-idx target-idx)
                                   (<= (- merge-idx i) 20)
                                   (range-unclaimed? claimed i else-end-idx))
                              (let* ([neg-sym (branch-neg-cond-sym mnem)]
                                     [c-expr (infer-branch-cond-expr ivec i #t arch)]
                                     [then-insts (vec-slice->list ivec i end-idx)]
                                     [else-insts (vec-slice->list ivec target-idx else-end-idx)]
                                     [form
                                      `(if-else
                                        #:branch-pc ,b-pc
                                        #:else-pc ,target-pc
                                        #:merge-pc ,merge-pc
                                        #:cond ,neg-sym
                                        #:cond-expr ,c-expr
                                        (then-branch ,@then-insts)
                                        (else-branch ,@else-insts))])
                                (claim-range! claimed i else-end-idx 'if-else)
                                (hash-set! region-at-start i (cons else-end-idx form))
                                (set! cond-count (add1 cond-count))
                                (scan (add1 else-end-idx)))
                              ;; Otherwise try `when-branch` on `[i .. end-idx]`
                              (if (and (<= 2 span-len 12)
                                       (range-unclaimed? claimed i end-idx))
                                  (let* ([neg-sym (branch-neg-cond-sym mnem)]
                                         [c-expr (infer-branch-cond-expr ivec i #t arch)]
                                         [form
                                          `(when-branch
                                            #:branch-pc ,b-pc
                                            #:join-pc ,target-pc
                                            #:cond ,neg-sym
                                            #:cond-expr ,c-expr
                                            ,@(vec-slice->list ivec i end-idx))])
                                    (claim-range! claimed i end-idx 'when-branch)
                                    (hash-set! region-at-start i (cons end-idx form))
                                    (set! cond-count (add1 cond-count))
                                    (scan (add1 end-idx)))
                                  (scan (add1 i)))))]

                    ;; 6. `when-branch`: forward conditional branch spanning 2..12 instructions
                    ;;    without crossing an already-structured loop boundary
                    [(and (<= 2 span-len 12)
                          (range-unclaimed? claimed i end-idx))
                     (define neg-sym (branch-neg-cond-sym mnem))
                     (define c-expr (infer-branch-cond-expr ivec i #t arch))
                     (define form
                       `(when-branch
                         #:branch-pc ,b-pc
                         #:join-pc ,target-pc
                         #:cond ,neg-sym
                         #:cond-expr ,c-expr
                         ,@(vec-slice->list ivec i end-idx)))
                     (claim-range! claimed i end-idx 'when-branch)
                     (hash-set! region-at-start i (cons end-idx form))
                     (set! cond-count (add1 cond-count))
                     (scan (add1 end-idx))]

                    [else
                     (scan (add1 i))])])]

              [else
               (scan (add1 i))])])))

     ;; ------------------------------------------------------------------------
     ;; Pass 3: Assemble ordered `structured-body-forms` & verify round-trip invariant
     ;; ------------------------------------------------------------------------
     (define structured-forms
       (let emit-loop ([i 0]
                       [acc '()])
         (if (>= i n)
             (reverse acc)
             (let ([reg (hash-ref region-at-start i #f)])
               (if reg
                   (emit-loop (add1 (car reg)) (cons (cdr reg) acc))
                   (emit-loop (add1 i) (cons (vector-ref ivec i) acc)))))))

     ;; Guarantee `(equal? (flatten-structured-insts structured-body-forms) insts)`
     (define verified-forms
       (if (equal? (flatten-structured-insts structured-forms) insts)
           structured-forms
           insts))

     (values verified-forms
             (hasheq 'loops         loop-count
                     'spin-waits    spin-wait-count
                     'conditionals  cond-count
                     'guard-returns guard-ret-count))]))

;; ============================================================================
;; 3B. Symbolic Expression / SSA Pseudo-Code Synthesizer (`synthesize-subroutine-pseudo-code`)
;; ============================================================================

(define (extract-kw-arg form kw [default #f])
  (let loop ([rem (cdr form)])
    (match rem
      [(list* k v rest)
       #:when (keyword? k)
       (if (eq? k kw) v (loop rest))]
      [_ default])))

(define (drop-last-if-branch forms arch)
  (if (and (pair? forms)
           (let ([last-f (last forms)])
             (and (pair? last-f)
                  (cond-branch-mnem? (inst-mnem last-f) arch))))
      (take forms (sub1 (length forms)))
      forms))

(define (drop-first-if-branch forms arch)
  (if (and (pair? forms)
           (let ([first-f (car forms)])
             (and (pair? first-f)
                  (cond-branch-mnem? (inst-mnem first-f) arch))))
      (cdr forms)
      forms))

(define (drop-last-if-uncond-jump forms arch)
  (if (and (pair? forms)
           (uncond-jump-inst? (last forms) arch))
      (take forms (sub1 (length forms)))
      forms))

(define ALL-PSEUDO-REGS '(A X Y B C D E H L BC DE HL))

;; Synthesize folded high-level `(decompiled-pseudo-code <stmt> ...)` from structured CFG & instructions
(define (synthesize-subroutine-pseudo-code structured-body #:arch [arch 'mos6502])
  (define root-regs (make-hasheq))
  (for ([r (in-list ALL-PSEUDO-REGS)])
    (hash-set! root-regs r r))
  (define root-dirty (mutable-seteq))

  ;; Set of instruction PCs that are direct subroutine returns (`RTS`, `RTI`, `RET`, `RETI`)
  (define ret-pcs
    (for/seteq ([ins (in-list (flatten-structured-insts structured-body))]
                #:when (and (pair? ins)
                            (memq (inst-mnem ins) '(RTS RTI RET RETI))
                            (exact-integer? (inst-pc ins))))
      (inst-pc ins)))

  ;; Synthesize an algebraic condition expression from a branch/return/call mnemonic
  ;; and the most recent flag-setting operation `(kind, lhs, rhs)`.
  (define (synthesize-branch-cond mnem kind lhs rhs)
    (define l (or lhs 'A))
    (define r (or rhs 0))
    (case mnem
      [(BEQ JR_Z JP_Z RET_Z CALL_Z)
       (if (eq? kind 'bit)
           `(== (bit-and ,r ,l) #x00)
           `(== ,l ,r))]
      [(BNE JR_NZ JP_NZ RET_NZ CALL_NZ)
       (if (eq? kind 'bit)
           `(!= (bit-and ,r ,l) #x00)
           `(!= ,l ,r))]
      [(BCS JR_C JP_C RET_C CALL_C)
       (cond
         [(eq? kind 'cmp) `(>= ,l ,r)]
         [(eq? kind 'alu) `(carry? ,l)]
         [else            '(== Carry 1)])]
      [(BCC JR_NC JP_NC RET_NC CALL_NC)
       (cond
         [(eq? kind 'cmp) `(< ,l ,r)]
         [(eq? kind 'alu) `(no-carry? ,l)]
         [else            '(== Carry 0)])]
      [(BMI)
       (cond
         [(eq? kind 'cmp) `(< (- ,l ,r) #x00)]
         [(eq? kind 'bit) `(bit-test? ,l 7)]
         [else            `(< ,l #x00)])]
      [(BPL)
       (cond
         [(eq? kind 'cmp) `(>= (- ,l ,r) #x00)]
         [(eq? kind 'bit) `(not (bit-test? ,l 7))]
         [else            `(>= ,l #x00)])]
      [(BVS)
       (if (eq? kind 'bit)
           `(bit-test? ,l 6)
           '(== Overflow 1))]
      [(BVC)
       (if (eq? kind 'bit)
           `(not (bit-test? ,l 6))
           '(== Overflow 0))]
      [else
       (branch-cond-sym mnem)]))

  (define (fallback-flag-or-nop-stmts children)
    (define flag-stmts
      (for/fold ([acc '()])
                ([ins (in-list children)]
                 #:when (pair? ins))
        (case (car ins)
          [(SEC SCF) (cons '(set! Carry 1) acc)]
          [(CLC)     (cons '(set! Carry 0) acc)]
          [(CCF)     (cons '(set! Carry (bit-xor Carry 1)) acc)]
          [(SEI DI)  (cons '(disable-interrupts!) acc)]
          [(CLI EI)  (cons '(enable-interrupts!) acc)]
          [(CLD)     (cons '(clear-decimal!) acc)]
          [(SED)     (cons '(set-decimal!) acc)]
          [(PUSH_AF) (cons '(push! AF) acc)]
          [(PUSH_BC) (cons '(push! BC) acc)]
          [(PUSH_DE) (cons '(push! DE) acc)]
          [(PUSH_HL) (cons '(push! HL) acc)]
          [(POP_AF)  (cons '(set! AF (pop!)) acc)]
          [(POP_BC)  (cons '(set! BC (pop!)) acc)]
          [(POP_DE)  (cons '(set! DE (pop!)) acc)]
          [(POP_HL)  (cons '(set! HL (pop!)) acc)]
          [else acc])))
    (if (pair? flag-stmts)
        (reverse flag-stmts)
        '((nop))))

  (define (ensure-non-empty-branch-stmts raw-stmts children regs-before regs-branch dirty-branch)
    (define flushed-regs '())
    (define extra-reg-stmts
      (for/fold ([acc '()])
                ([r (in-list ALL-PSEUDO-REGS)])
        (define v-before (hash-ref regs-before r r))
        (define v-branch (hash-ref regs-branch r r))
        (if (or (set-member? dirty-branch r)
                (and (null? raw-stmts)
                     (not (equal? v-branch v-before))))
            (begin
              (set! flushed-regs (cons r flushed-regs))
              (cons `(set! ,r ,v-branch) acc))
            acc)))
    (define combined (append raw-stmts (reverse extra-reg-stmts)))
    (values (if (pair? combined)
                combined
                (fallback-flag-or-nop-stmts children))
            (reverse flushed-regs)))

  (define (infer-loop-step-sym children arch)
    (case arch
      [(mos6502)
       (or (for/or ([ins (in-list (reverse children))]
                    #:when (pair? ins))
             (and (memq (inst-mnem ins) '(DEX DEY INX INY DEC INC))
                  (inst-mnem ins)))
           'DEX)]
      [(sm83)
       (or (for/or ([ins (in-list (reverse children))]
                    #:when (pair? ins))
             (and (memq (inst-mnem ins)
                        '(DEC_B DEC_C DEC_D DEC_E DEC_BC DEC_DE DEC_HL
                          INC_B INC_C INC_D INC_E INC_BC INC_DE INC_HL
                          LD_HLI_A LD_HLD_A LD_A_HLI LD_A_HLD))
                  (inst-mnem ins)))
           'DEC_B)]
      [else 'step]))

  ;; Inspect loop body instructions to synthesize high-level `(mem-fill! target val step)`
  ;; or `(mem-copy! dst src step)` array intrinsics at the start of the loop body.
  (define (infer-loop-mem-intrinsic children regs-before step-sym arch)
    (case arch
      [(mos6502)
       (define indexed-src #f)
       (define indexed-dst #f)
       (define ppu-dst     #f)
       (define store-reg   'A)
       (define inline-imm  #f)
       (for ([ins (in-list children)]
             #:when (and (pair? ins) (not (structured-cfg-form? ins))))
         (define mnem (inst-mnem ins))
         (define mode (inst-mode ins))
         (cond
           [(and (eq? mnem 'LDA) (eq? mode '#:imm) (not indexed-dst))
            (set! inline-imm (inst-operand ins))]
           [(and (memq mnem '(LDA LDX LDY))
                 (memq mode '(#:absx #:absy #:zpx #:zpy #:indx #:indy))
                 (not indexed-src))
            (set! indexed-src (mos6502-operand->sym-expr ins))]
           [(and (memq mnem '(STA STX STY))
                 (memq mode '(#:absx #:absy #:zpx #:zpy #:indx #:indy))
                 (not indexed-dst))
            (set! indexed-dst (mos6502-operand->sym-expr ins))
            (set! store-reg (case mnem [(STA) 'A] [(STX) 'X] [(STY) 'Y]))]
           [(and (eq? mnem 'STA)
                 (eq? mode '#:abs)
                 (let ([dst (mos6502-operand->sym-expr ins)])
                   (or (eq? dst 'PPUDATA)
                       (and (symbol? dst)
                            (string-prefix? (symbol->string dst) "ppudata_mirror_")))))
            (set! ppu-dst (mos6502-operand->sym-expr ins))]))
       (define eff-dst (or indexed-dst ppu-dst))
       (cond
         [(and indexed-src eff-dst (not (equal? eff-dst indexed-src)))
          (list `(mem-copy! ,eff-dst ,indexed-src ,step-sym))]
         [(and indexed-dst (not indexed-src))
          (define val-expr
            (if (eq? store-reg 'A)
                (or inline-imm (hash-ref regs-before 'A 'A))
                (hash-ref regs-before store-reg store-reg)))
          (list `(mem-fill! ,indexed-dst ,val-expr ,step-sym))]
         [else '()])]

      [(sm83)
       (define block-src  #f)
       (define block-dst  #f)
       (define inline-imm #f)
       (for ([ins (in-list children)]
             #:when (and (pair? ins) (not (structured-cfg-form? ins))))
         (define mnem (inst-mnem ins))
         (cond
           [(and (eq? mnem 'LD_A) (not block-dst))
            (set! inline-imm (inst-operand ins))]
           [(and (eq? mnem 'XOR_A_A) (not block-dst))
            (set! inline-imm 0)]
           [(and (memq mnem '(LD_A_HLI LD_A_HLD LD_A_DE_IND LD_A_DE LD_A_BC_IND LD_A_BC LD_A_HL-IND))
                 (not block-src))
            (set! block-src
                  (case mnem
                    [(LD_A_HLI)              '(deref HL++)]
                    [(LD_A_HLD)              '(deref HL--)]
                    [(LD_A_DE_IND LD_A_DE)   '(deref DE)]
                    [(LD_A_BC_IND LD_A_BC)   '(deref BC)]
                    [(LD_A_HL-IND)           '(deref HL)]))]
           [(and (memq mnem '(LD_HLI_A LD_HLD_A LD_DE_IND_A LD_DE_A LD_BC_IND_A LD_BC_A LD_HL-IND_A LD_HL_IND))
                 (not block-dst))
            (when (eq? mnem 'LD_HL_IND)
              (set! inline-imm (inst-operand ins)))
            (set! block-dst
                  (case mnem
                    [(LD_HLI_A)              '(deref HL++)]
                    [(LD_HLD_A)              '(deref HL--)]
                    [(LD_DE_IND_A LD_DE_A)   '(deref DE)]
                    [(LD_BC_IND_A LD_BC_A)   '(deref BC)]
                    [(LD_HL-IND_A LD_HL_IND) '(deref HL)]))]))
       (cond
         [(and block-src block-dst (not (equal? block-dst block-src)))
          (list `(mem-copy! ,block-dst ,block-src ,step-sym))]
         [(and block-dst (not block-src))
          (define val-expr (or inline-imm (hash-ref regs-before 'A 'A)))
          (list `(mem-fill! ,block-dst ,val-expr ,step-sym))]
         [else '()])]

      [else '()]))

  (define (fold-forms forms regs dirty [in-loop? #f] [loop-start-pc #f] [loop-latch-pc #f])
    (define stmts '())
    (define last-cmp-kind #f)
    (define last-cmp-lhs  #f)
    (define last-cmp-rhs  #f)
    (define (set-cmp! kind lhs rhs)
      (set! last-cmp-kind kind)
      (set! last-cmp-lhs  lhs)
      (set! last-cmp-rhs  rhs))
    (define (target-exits-loop? target-pc)
      (and in-loop?
           (or (not (and (exact-integer? target-pc)
                         (exact-integer? loop-start-pc)
                         (exact-integer? loop-latch-pc)))
               (< target-pc loop-start-pc)
               (> target-pc loop-latch-pc))))
    (define (emit! s)
      (set! stmts (cons s stmts)))
    (define (emit-store! dst val inst)
      (define eff-mask
        (match val
          [(? exact-integer? m) m]
          [(list 'bit-ior _ (? exact-integer? m)) m]
          [_ #f]))
      (define flags
        (or (inst-flags inst)
            (and (symbol? dst)
                 eff-mask
                 (decode-hw-bitfield-flags dst eff-mask))))
      (if (and flags (pair? flags))
          (emit! `(set! ,dst ,val #:flags ,flags))
          (emit! `(set! ,dst ,val))))

    (let form-loop ([rem forms])
      (when (pair? rem)
        (define f (car rem))
        (define rest-forms (cdr rem))
        (cond
          [(not (pair? f))
           (form-loop rest-forms)]

          ;; ------------------------------------------------------------------
          ;; Multi-Instruction 6502 16-Bit Pointer & Carry-Chained Math Idioms
          ;; ------------------------------------------------------------------

          ;; Idiom 1A: 4-instruction 16-bit Zero-Page Pointer Initialization
          ;;   `(LDA #:imm b1) (STA #:zp zp1) (LDA #:imm b2) (STA #:zp zp2)` where |zp1 - zp2| = 1
          [(and (eq? arch 'mos6502)
                (>= (length rem) 4)
                (let ([i1 (first rem)]
                      [i2 (second rem)]
                      [i3 (third rem)]
                      [i4 (fourth rem)])
                  (and (pair? i1) (eq? (inst-mnem i1) 'LDA) (eq? (inst-mode i1) '#:imm)
                       (pair? i2) (eq? (inst-mnem i2) 'STA) (eq? (inst-mode i2) '#:zp)
                       (pair? i3) (eq? (inst-mnem i3) 'LDA) (eq? (inst-mode i3) '#:imm)
                       (pair? i4) (eq? (inst-mnem i4) 'STA) (eq? (inst-mode i4) '#:zp)
                       (exact-integer? (inst-operand i1))
                       (exact-integer? (inst-operand i2))
                       (exact-integer? (inst-operand i3))
                       (exact-integer? (inst-operand i4))
                       (or (= (inst-operand i4) (add1 (inst-operand i2)))
                           (= (inst-operand i2) (add1 (inst-operand i4)))))))
           (define i1 (first rem))
           (define i2 (second rem))
           (define i3 (third rem))
           (define i4 (fourth rem))
           (define b1  (inst-operand i1))
           (define zp1 (inst-operand i2))
           (define b2  (inst-operand i3))
           (define zp2 (inst-operand i4))
           (define zp-lo (min zp1 zp2))
           (define lo-b  (if (= zp1 zp-lo) b1 b2))
           (define hi-b  (if (= zp1 zp-lo) b2 b1))
           (define u16-val (bitwise-ior lo-b (arithmetic-shift hi-b 8)))
           (emit! `(set! (u16-zp ,zp-lo) ,u16-val))
           (hash-set! regs 'A b2)
           (set-remove! dirty 'A)
           (set-cmp! 'test b2 0)
           (form-loop (drop rem 4))]

          ;; Idiom 1B: 3-instruction 16-bit Zero-Page Pointer Initialization via A (lo) + X/Y (hi)
          ;;   `(LDA #:imm lo) (STA #:zp zp-lo) (STX/STY #:zp zp-hi)` where zp-hi = zp-lo + 1
          [(and (eq? arch 'mos6502)
                (>= (length rem) 3)
                (let ([i1 (first rem)]
                      [i2 (second rem)]
                      [i3 (third rem)])
                  (and (pair? i1) (eq? (inst-mnem i1) 'LDA) (eq? (inst-mode i1) '#:imm)
                       (pair? i2) (eq? (inst-mnem i2) 'STA) (eq? (inst-mode i2) '#:zp)
                       (pair? i3) (memq (inst-mnem i3) '(STX STY)) (eq? (inst-mode i3) '#:zp)
                       (exact-integer? (inst-operand i1))
                       (exact-integer? (inst-operand i2))
                       (exact-integer? (inst-operand i3))
                       (= (inst-operand i3) (add1 (inst-operand i2)))
                       (exact-integer? (hash-ref regs (if (eq? (inst-mnem i3) 'STX) 'X 'Y) #f)))))
           (define i1 (first rem))
           (define i2 (second rem))
           (define i3 (third rem))
           (define hi-reg (if (eq? (inst-mnem i3) 'STX) 'X 'Y))
           (define lo-b   (inst-operand i1))
           (define hi-b   (hash-ref regs hi-reg))
           (define zp-lo  (inst-operand i2))
           (define u16-val (bitwise-ior lo-b (arithmetic-shift hi-b 8)))
           (emit! `(set! (u16-zp ,zp-lo) ,u16-val))
           (hash-set! regs 'A lo-b)
           (set-remove! dirty 'A)
           (set-remove! dirty hi-reg)
           (set-cmp! 'test lo-b 0)
           (form-loop (drop rem 3))]

          ;; Idiom 1C: 16-bit Carry-Chained Addition (`[CLC] LDA zp ; ADC #lo/zp ; STA zp ; LDA zp+1 ; ADC #hi/zp+1 ; STA zp+1`)
          [(and (eq? arch 'mos6502)
                (let ([seq (if (and (pair? f) (eq? (inst-mnem f) 'CLC)) rest-forms rem)])
                  (and (>= (length seq) 6)
                       (let ([i1 (first seq)]
                             [i2 (second seq)]
                             [i3 (third seq)]
                             [i4 (fourth seq)]
                             [i5 (fifth seq)]
                             [i6 (sixth seq)])
                         (and (pair? i1) (eq? (inst-mnem i1) 'LDA) (eq? (inst-mode i1) '#:zp)
                              (pair? i2) (eq? (inst-mnem i2) 'ADC) (memq (inst-mode i2) '(#:imm #:zp))
                              (pair? i3) (eq? (inst-mnem i3) 'STA) (eq? (inst-mode i3) '#:zp)
                              (pair? i4) (eq? (inst-mnem i4) 'LDA) (eq? (inst-mode i4) '#:zp)
                              (pair? i5) (eq? (inst-mnem i5) 'ADC) (eq? (inst-mode i5) (inst-mode i2))
                              (pair? i6) (eq? (inst-mnem i6) 'STA) (eq? (inst-mode i6) '#:zp)
                              (exact-integer? (inst-operand i1))
                              (= (inst-operand i1) (inst-operand i3))
                              (= (inst-operand i4) (inst-operand i6))
                              (= (inst-operand i4) (add1 (inst-operand i1)))
                              (or (eq? (inst-mode i2) '#:imm)
                                  (= (inst-operand i5) (add1 (inst-operand i2)))))))))
           (define has-clc? (eq? (inst-mnem f) 'CLC))
           (define seq   (if has-clc? rest-forms rem))
           (define i1    (first seq))
           (define i2    (second seq))
           (define i5    (fifth seq))
           (define zp-lo (inst-operand i1))
           (define rhs
             (if (eq? (inst-mode i2) '#:imm)
                 (bitwise-ior (inst-operand i2) (arithmetic-shift (inst-operand i5) 8))
                 `(u16-zp ,(inst-operand i2))))
           (emit! `(+= (u16-zp ,zp-lo) ,rhs))
           (hash-set! regs 'A `(u16-zp ,zp-lo))
           (set-remove! dirty 'A)
           (set-cmp! 'alu `(u16-zp ,zp-lo) 0)
           (form-loop (drop rem (if has-clc? 7 6)))]

          [else
           (define tag (car f))
           (cond
             [(eq? tag 'decompiled-pseudo-code) (void)]

             [(eq? tag 'spin-wait-mmio-loop)
              (define mmio (extract-kw-arg f '#:mmio 'PPUSTATUS))
              (define cnd  (extract-kw-arg f '#:cond 'branch-cond))
              (emit! `(await-mmio! ,mmio ,cnd))
              (set-cmp! #f #f #f)]

             [(eq? tag 'counted-loop)
              (define step  (extract-kw-arg f '#:step 'DEX))
              (define h-pc  (extract-kw-arg f '#:header-pc #f))
              (define l-pc  (extract-kw-arg f '#:latch-pc #f))
              (define cexpr (or (extract-kw-arg f '#:cond-expr #f)
                                (extract-kw-arg f '#:cond 'not-zero)))
              (define children (drop-last-if-branch (strip-leading-kw-args (cdr f)) arch))
              (define regs-before (hash-copy regs))
              (define regs-loop   (hash-copy regs))
              (define dirty-loop  (mutable-seteq))
              (define raw-body    (fold-forms children regs-loop dirty-loop #t h-pc l-pc))
              (define-values (body-stmts _flushed)
                (ensure-non-empty-branch-stmts raw-body children regs-before regs-loop dirty-loop))
              (define mem-intrinsics
                (infer-loop-mem-intrinsic children regs-before step arch))
              (for ([r (in-list ALL-PSEUDO-REGS)])
                (when (or (set-member? dirty-loop r)
                          (not (equal? (hash-ref regs-loop r r) (hash-ref regs-before r r))))
                  (hash-set! regs r r)
                  (set-remove! dirty r)))
              (set-cmp! #f #f #f)
              (emit! `(loop-counted #:step ,step #:while ,cexpr ,@mem-intrinsics ,@body-stmts))]

             [(eq? tag 'do-while-loop)
              (define h-pc  (extract-kw-arg f '#:header-pc #f))
              (define l-pc  (extract-kw-arg f '#:latch-pc #f))
              (define cexpr (or (extract-kw-arg f '#:cond-expr #f)
                                (extract-kw-arg f '#:cond 'not-zero)))
              (define children (drop-last-if-branch (strip-leading-kw-args (cdr f)) arch))
              (define step-sym (or (extract-kw-arg f '#:step #f)
                                   (infer-loop-step-sym children arch)))
              (define regs-before (hash-copy regs))
              (define regs-loop   (hash-copy regs))
              (define dirty-loop  (mutable-seteq))
              (define raw-body    (fold-forms children regs-loop dirty-loop #t h-pc l-pc))
              (define-values (body-stmts _flushed)
                (ensure-non-empty-branch-stmts raw-body children regs-before regs-loop dirty-loop))
              (define mem-intrinsics
                (infer-loop-mem-intrinsic children regs-before step-sym arch))
              (for ([r (in-list ALL-PSEUDO-REGS)])
                (when (or (set-member? dirty-loop r)
                          (not (equal? (hash-ref regs-loop r r) (hash-ref regs-before r r))))
                  (hash-set! regs r r)
                  (set-remove! dirty r)))
              (set-cmp! #f #f #f)
              (emit! `(do-while #:while ,cexpr ,@mem-intrinsics ,@body-stmts))]

             [(eq? tag 'guard-return)
              (define cexpr (or (extract-kw-arg f '#:cond-expr #f)
                                (extract-kw-arg f '#:cond 'branch-cond)))
              (define guard-children
                (filter (lambda (ins)
                          (not (and (pair? ins)
                                    (memq (car ins) '(RTS RTI RET RETI RET_NZ RET_Z RET_NC RET_C)))))
                        (drop-first-if-branch (strip-leading-kw-args (cdr f)) arch)))
              (define regs-guard  (hash-copy regs))
              (define dirty-guard (mutable-seteq))
              (define raw-guard-stmts (fold-forms guard-children regs-guard dirty-guard in-loop? loop-start-pc loop-latch-pc))
              (define extra-guard-stmts
                (for/list ([r (in-list ALL-PSEUDO-REGS)]
                           #:when (set-member? dirty-guard r))
                  `(set! ,r ,(hash-ref regs-guard r r))))
              (define guard-body-stmts (append raw-guard-stmts extra-guard-stmts))
              (emit! `(when ,cexpr ,@guard-body-stmts (return)))]

             [(eq? tag 'when-branch)
              (define cexpr (or (extract-kw-arg f '#:cond-expr #f)
                                (extract-kw-arg f '#:cond 'branch-cond)))
              (define children (drop-first-if-branch (strip-leading-kw-args (cdr f)) arch))
              (define regs-before  (hash-copy regs))
              (define dirty-before (set-copy dirty))
              (define regs-branch  (hash-copy regs))
              (define dirty-branch (mutable-seteq))
              (define raw-body     (fold-forms children regs-branch dirty-branch in-loop? loop-start-pc loop-latch-pc))
              (define-values (body-stmts flushed-regs)
                (ensure-non-empty-branch-stmts raw-body children regs-before regs-branch dirty-branch))
              ;; If a register `r` was modified inside `when-branch` to pass a value to post-branch
              ;; code AND `r` had a pre-branch unemitted value, emit `(set! r pre-val)` before `when`!
              (for ([r (in-list flushed-regs)])
                (define pre-val (hash-ref regs-before r r))
                (when (and (set-member? dirty-before r)
                           (not (eq? pre-val r)))
                  (emit! `(set! ,r ,pre-val))))
              (emit! `(when ,cexpr ,@body-stmts))
              ;; Reset any register mutated inside the branch to `r` so branch expressions never leak!
              (for ([r (in-list ALL-PSEUDO-REGS)])
                (when (or (set-member? dirty-branch r)
                          (not (equal? (hash-ref regs-branch r r) (hash-ref regs-before r r))))
                  (hash-set! regs r r)
                  (set-remove! dirty r)))
              (set-cmp! #f #f #f)]

             [(eq? tag 'if-else)
              (define cexpr (or (extract-kw-arg f '#:cond-expr #f)
                                (extract-kw-arg f '#:cond 'branch-cond)))
              (define children (strip-leading-kw-args (cdr f)))
              (define then-form (findf (lambda (c) (and (pair? c) (eq? (car c) 'then-branch))) children))
              (define else-form (findf (lambda (c) (and (pair? c) (eq? (car c) 'else-branch))) children))
              (define then-children
                (if then-form
                    (drop-last-if-uncond-jump (drop-first-if-branch (cdr then-form) arch) arch)
                    '()))
              (define else-children
                (if else-form (cdr else-form) '()))
              (define regs-before (hash-copy regs))
              (define regs-then   (hash-copy regs))
              (define dirty-then  (mutable-seteq))
              (define regs-else   (hash-copy regs))
              (define dirty-else  (mutable-seteq))
              (define raw-then    (fold-forms then-children regs-then dirty-then in-loop? loop-start-pc loop-latch-pc))
              (define raw-else    (fold-forms else-children regs-else dirty-else in-loop? loop-start-pc loop-latch-pc))
              (define-values (then-stmts _f1)
                (ensure-non-empty-branch-stmts raw-then then-children regs-before regs-then dirty-then))
              (define-values (else-stmts _f2)
                (ensure-non-empty-branch-stmts raw-else else-children regs-before regs-else dirty-else))
              (emit! `(if ,cexpr
                          (then ,@then-stmts)
                          (else ,@else-stmts)))
              (for ([r (in-list ALL-PSEUDO-REGS)])
                (when (or (set-member? dirty-then r)
                          (set-member? dirty-else r)
                          (not (equal? (hash-ref regs-then r r) (hash-ref regs-before r r)))
                          (not (equal? (hash-ref regs-else r r) (hash-ref regs-before r r))))
                  (hash-set! regs r r)
                  (set-remove! dirty r)))
              (set-cmp! #f #f #f)]

             ;; Raw MOS 6502 Instructions
             [(eq? arch 'mos6502)
              (define mnem tag)
              (define mode (inst-mode f))
              (define op   (or (inst-operand f) 0))
              (define sym  (inst-sym f))
              (case mnem
                [(LDA)
                 (define src (mos6502-operand->sym-expr f))
                 (hash-set! regs 'A src)
                 (set-add! dirty 'A)
                 (set-cmp! 'test src 0)
                 (when (memq src '(PPUSTATUS PPUDATA JOY1 JOY2))
                   (emit! `(io-read! ,src))
                   (set-remove! dirty 'A))]
                [(LDX)
                 (define src (mos6502-operand->sym-expr f))
                 (hash-set! regs 'X src)
                 (set-remove! dirty 'X)
                 (set-cmp! 'test src 0)
                 (emit! `(set! X ,src))]
                [(LDY)
                 (define src (mos6502-operand->sym-expr f))
                 (hash-set! regs 'Y src)
                 (set-remove! dirty 'Y)
                 (set-cmp! 'test src 0)
                 (emit! `(set! Y ,src))]
                [(STA)
                 (define dst (mos6502-operand->sym-expr f))
                 (define val (hash-ref regs 'A 'A))
                 (emit-store! dst val f)
                 (set-remove! dirty 'A)
                 (unless (and (symbol? dst) (set-member? ALL-HW-MMIO-SYMS dst))
                   (hash-set! regs 'A dst)
                   (when (eq? last-cmp-kind 'test)
                     (set-cmp! 'test dst 0)))]
                [(STX)
                 (define dst (mos6502-operand->sym-expr f))
                 (define val (hash-ref regs 'X 'X))
                 (emit-store! dst val f)
                 (set-remove! dirty 'X)]
                [(STY)
                 (define dst (mos6502-operand->sym-expr f))
                 (define val (hash-ref regs 'Y 'Y))
                 (emit-store! dst val f)
                 (set-remove! dirty 'Y)]
                [(ADC)
                 (define expr `(+ ,(hash-ref regs 'A 'A) ,(mos6502-operand->sym-expr f)))
                 (hash-set! regs 'A expr)
                 (set-add! dirty 'A)
                 (set-cmp! 'alu expr 0)]
                [(SBC)
                 (define expr `(- ,(hash-ref regs 'A 'A) ,(mos6502-operand->sym-expr f)))
                 (hash-set! regs 'A expr)
                 (set-add! dirty 'A)
                 (set-cmp! 'alu expr 0)]
                [(AND)
                 (define expr `(bit-and ,(hash-ref regs 'A 'A) ,(mos6502-operand->sym-expr f)))
                 (hash-set! regs 'A expr)
                 (set-add! dirty 'A)
                 (set-cmp! 'test expr 0)]
                [(ORA)
                 (define expr `(bit-ior ,(hash-ref regs 'A 'A) ,(mos6502-operand->sym-expr f)))
                 (hash-set! regs 'A expr)
                 (set-add! dirty 'A)
                 (set-cmp! 'test expr 0)]
                [(EOR)
                 (define expr `(bit-xor ,(hash-ref regs 'A 'A) ,(mos6502-operand->sym-expr f)))
                 (hash-set! regs 'A expr)
                 (set-add! dirty 'A)
                 (set-cmp! 'test expr 0)]
                [(CMP CPX CPY)
                 (define reg (case mnem [(CMP) 'A] [(CPX) 'X] [(CPY) 'Y]))
                 (define cur (hash-ref regs reg reg))
                 (define lhs (if (and (eq? mnem 'CMP) (not (exact-integer? cur))) cur reg))
                 (define rhs (mos6502-operand->sym-expr f))
                 (set-remove! dirty reg)
                 (set-cmp! 'cmp lhs rhs)]
                [(BIT)
                 (define mem-expr (mos6502-operand->sym-expr f))
                 (define a-expr   (hash-ref regs 'A 'A))
                 (set-remove! dirty 'A)
                 (set-cmp! 'bit mem-expr a-expr)]
                [(ASL LSR ROL ROR)
                 (define shift-op
                   (case mnem [(ASL) 'shl] [(LSR) 'shr] [(ROL) 'rol] [(ROR) 'ror]))
                 (if (eq? mode '#:acc)
                     (let ([expr `(,shift-op ,(hash-ref regs 'A 'A) 1)])
                       (hash-set! regs 'A expr)
                       (set-add! dirty 'A)
                       (set-cmp! 'alu expr 0))
                     (let ([dst (mos6502-operand->sym-expr f)])
                       (emit! `(,(string->symbol (format "~a!" shift-op)) ,dst 1))
                       (set-cmp! 'alu dst 0)))]
                [(INC)
                 (define dst (mos6502-operand->sym-expr f))
                 (emit! `(+= ,dst 1))
                 (set-cmp! 'test dst 0)]
                [(DEC)
                 (define dst (mos6502-operand->sym-expr f))
                 (emit! `(-= ,dst 1))
                 (set-cmp! 'test dst 0)]
                [(INX)
                 (hash-set! regs 'X 'X)
                 (set-remove! dirty 'X)
                 (set-cmp! 'test 'X 0)
                 (emit! '(+= X 1))]
                [(DEX)
                 (hash-set! regs 'X 'X)
                 (set-remove! dirty 'X)
                 (set-cmp! 'test 'X 0)
                 (emit! '(-= X 1))]
                [(INY)
                 (hash-set! regs 'Y 'Y)
                 (set-remove! dirty 'Y)
                 (set-cmp! 'test 'Y 0)
                 (emit! '(+= Y 1))]
                [(DEY)
                 (hash-set! regs 'Y 'Y)
                 (set-remove! dirty 'Y)
                 (set-cmp! 'test 'Y 0)
                 (emit! '(-= Y 1))]
                [(TAX)
                 (define v (hash-ref regs 'A 'A))
                 (hash-set! regs 'X v)
                 (set-remove! dirty 'A)
                 (set-remove! dirty 'X)
                 (set-cmp! 'test 'X 0)
                 (emit! `(set! X ,v))]
                [(TAY)
                 (define v (hash-ref regs 'A 'A))
                 (hash-set! regs 'Y v)
                 (set-remove! dirty 'A)
                 (set-remove! dirty 'Y)
                 (set-cmp! 'test 'Y 0)
                 (emit! `(set! Y ,v))]
                [(TXA)
                 (define v (hash-ref regs 'X 'X))
                 (hash-set! regs 'A v)
                 (set-add! dirty 'A)
                 (set-cmp! 'test v 0)]
                [(TYA)
                 (define v (hash-ref regs 'Y 'Y))
                 (hash-set! regs 'A v)
                 (set-add! dirty 'A)
                 (set-cmp! 'test v 0)]
                [(TXS)
                 (set-remove! dirty 'X)
                 (emit! `(set! SP ,(hash-ref regs 'X 'X)))]
                [(TSX)
                 (hash-set! regs 'X 'SP)
                 (set-add! dirty 'X)
                 (set-cmp! 'test 'X 0)]
                [(PHA)
                 (set-remove! dirty 'A)
                 (emit! `(push! ,(hash-ref regs 'A 'A)))]
                [(PLA)
                 (hash-set! regs 'A '(pop!))
                 (set-add! dirty 'A)
                 (set-cmp! 'test 'A 0)]
                [(JSR)
                 (emit! `(call ,(or sym op)))
                 (hash-set! regs 'A 'A)
                 (set-remove! dirty 'A)
                 (set-cmp! 'test 'A 0)]
                [(JMP)
                 (if (eq? mode '#:ind)
                     (emit! `(jump-indirect (deref ,op)))
                     (emit! `(tail-call ,(or sym op))))]
                [(RTS)
                 (emit! '(return))]
                [(RTI)
                 (emit! '(reti))]
                [(BPL BMI BVC BVS BCC BCS BNE BEQ)
                 (set-remove! dirty 'A)
                 (define c-expr (synthesize-branch-cond mnem last-cmp-kind last-cmp-lhs last-cmp-rhs))
                 (define target (or sym op))
                 (cond
                   [(target-exits-loop? op)
                    (emit! `(when ,c-expr (break ,target)))]
                   [(set-member? ret-pcs op)
                    (emit! `(when ,c-expr (return)))]
                   [else
                    (emit! `(when ,c-expr (goto ,target)))])]
                [else (void)])]

             ;; Raw Sharp SM83 Instructions
             [(eq? arch 'sm83)
              (define mnem tag)
              (define m-str (symbol->string mnem))
              (define mode (inst-mode f))
              (define op   (or (inst-operand f) 0))
              (define sym  (inst-sym f))
              (cond
                [(eq? mnem 'LD_A)      (hash-set! regs 'A op) (set-add! dirty 'A)]
                [(eq? mnem 'LD_B)      (hash-set! regs 'B op) (set-remove! dirty 'B) (emit! `(set! B ,op))]
                [(eq? mnem 'LD_C)      (hash-set! regs 'C op) (set-remove! dirty 'C) (emit! `(set! C ,op))]
                [(eq? mnem 'LD_D)      (hash-set! regs 'D op) (set-remove! dirty 'D) (emit! `(set! D ,op))]
                [(eq? mnem 'LD_E)      (hash-set! regs 'E op) (set-remove! dirty 'E) (emit! `(set! E ,op))]
                [(eq? mnem 'LD_H)      (hash-set! regs 'H op) (set-remove! dirty 'H) (emit! `(set! H ,op))]
                [(eq? mnem 'LD_L)      (hash-set! regs 'L op) (set-remove! dirty 'L) (emit! `(set! L ,op))]
                [(eq? mnem 'LD_BC)     (hash-set! regs 'BC op) (set-remove! dirty 'BC) (emit! `(set! BC ,op))]
                [(eq? mnem 'LD_DE)     (hash-set! regs 'DE op) (set-remove! dirty 'DE) (emit! `(set! DE ,op))]
                [(eq? mnem 'LD_HL)     (hash-set! regs 'HL (or sym op)) (set-remove! dirty 'HL) (emit! `(set! HL ,(or sym op)))]
                [(eq? mnem 'LD_SP)     (emit! `(set! SP ,op))]
                [(eq? mnem 'XOR_A_A)   (hash-set! regs 'A 0) (set-add! dirty 'A) (set-cmp! 'test 0 0)]
                [(or (eq? mnem 'AND_A_A) (eq? mnem 'OR_A_A))
                 (define cur-a (hash-ref regs 'A 'A))
                 (set-remove! dirty 'A)
                 (set-cmp! 'test cur-a 0)]
                [(eq? mnem 'LDH_OUT)
                 (define dst (sm83-io-or-mem-sym f))
                 (emit-store! dst (hash-ref regs 'A 'A) f)
                 (set-remove! dirty 'A)
                 (unless (and (symbol? dst) (set-member? ALL-HW-MMIO-SYMS dst))
                   (hash-set! regs 'A dst))]
                [(eq? mnem 'LDH_IN)
                 (define src (sm83-io-or-mem-sym f))
                 (hash-set! regs 'A src)
                 (set-add! dirty 'A)]
                [(eq? mnem 'LDH_C_OUT)
                 (emit! `(set! (io-port C) ,(hash-ref regs 'A 'A)))
                 (set-remove! dirty 'A)]
                [(eq? mnem 'LDH_C_IN)
                 (hash-set! regs 'A '(io-port C))
                 (set-add! dirty 'A)]
                [(eq? mnem 'LD_A16_A)
                 (define dst (sm83-io-or-mem-sym f))
                 (emit-store! dst (hash-ref regs 'A 'A) f)
                 (set-remove! dirty 'A)
                 (unless (and (symbol? dst) (set-member? ALL-HW-MMIO-SYMS dst))
                   (hash-set! regs 'A dst))]
                [(eq? mnem 'LD_A_A16)
                 (define src (sm83-io-or-mem-sym f))
                 (hash-set! regs 'A src)
                 (set-add! dirty 'A)]
                [(eq? mnem 'LD_HLI_A)
                 (emit! `(set! (deref HL++) ,(hash-ref regs 'A 'A)))
                 (set-remove! dirty 'A)]
                [(eq? mnem 'LD_HLD_A)
                 (emit! `(set! (deref HL--) ,(hash-ref regs 'A 'A)))
                 (set-remove! dirty 'A)]
                [(eq? mnem 'LD_A_HLI)
                 (hash-set! regs 'A '(deref HL++))
                 (set-add! dirty 'A)]
                [(eq? mnem 'LD_A_HLD)
                 (hash-set! regs 'A '(deref HL--))
                 (set-add! dirty 'A)]
                [(eq? mnem 'LD_A_DE_IND)
                 (hash-set! regs 'A '(deref DE))
                 (set-add! dirty 'A)]
                [(eq? mnem 'LD_A_BC_IND)
                 (hash-set! regs 'A '(deref BC))
                 (set-add! dirty 'A)]
                [(eq? mnem 'LD_DE_IND_A)
                 (emit! `(set! (deref DE) ,(hash-ref regs 'A 'A)))
                 (set-remove! dirty 'A)]
                [(eq? mnem 'LD_BC_IND_A)
                 (emit! `(set! (deref BC) ,(hash-ref regs 'A 'A)))
                 (set-remove! dirty 'A)]
                [(eq? mnem 'LD_HL_IND)
                 (emit! `(set! (deref HL) ,op))]
                [(eq? mnem 'DAA)
                 (define cur-a (hash-ref regs 'A 'A))
                 (set-add! dirty 'A)
                 (match cur-a
                   [`(+ ,x ,y) (hash-set! regs 'A `(bcd+ ,x ,y))]
                   [`(- ,x ,y) (hash-set! regs 'A `(bcd- ,x ,y))]
                   [_          (hash-set! regs 'A `(bcd-adjust ,cur-a))])]
                [(regexp-match #px"^LD_([BCDEHLA]|HL-IND)_([BCDEHLA]|HL-IND)$" m-str)
                 => (lambda (mt)
                      (define dst (string->symbol (second mt)))
                      (define src (string->symbol (third mt)))
                      (define src-val (if (eq? src 'HL-IND) '(deref HL) (hash-ref regs src src)))
                      (if (eq? dst 'HL-IND)
                          (begin
                            (emit! `(set! (deref HL) ,src-val))
                            (when (symbol? src) (set-remove! dirty src)))
                          (begin
                            (hash-set! regs dst src-val)
                            (if (eq? dst 'A)
                                (set-add! dirty 'A)
                                (begin
                                  (set-remove! dirty dst)
                                  (when (eq? src 'A) (set-remove! dirty 'A))
                                  (emit! `(set! ,dst ,src-val)))))))]
                [(regexp-match #px"^CP_A(?:_(.+))?$" m-str)
                 => (lambda (mt)
                      (define src-str (second mt))
                      (define rhs
                        (cond
                          [(not src-str) op]
                          [(string=? src-str "HL-IND") '(deref HL)]
                          [else (let ([rsym (string->symbol src-str)])
                                  (hash-ref regs rsym rsym))]))
                      (define cur-a (hash-ref regs 'A 'A))
                      (set-remove! dirty 'A)
                      (set-cmp! 'cmp cur-a rhs))]
                [(regexp-match #px"^(ADD|ADC|SUB|SBC|AND|XOR|OR)_A(?:_(.+))?$" m-str)
                 => (lambda (mt)
                      (define alu (second mt))
                      (define src-str (third mt))
                      (define rhs
                        (cond
                          [(not src-str) op]
                          [(string=? src-str "HL-IND") '(deref HL)]
                          [else (let ([rsym (string->symbol src-str)])
                                  (hash-ref regs rsym rsym))]))
                      (define cur-a (hash-ref regs 'A 'A))
                      (define op-sym
                        (cond
                          [(or (string=? alu "ADD") (string=? alu "ADC")) '+]
                          [(or (string=? alu "SUB") (string=? alu "SBC")) '-]
                          [(string=? alu "AND") 'bit-and]
                          [(string=? alu "OR")  'bit-ior]
                          [else                 'bit-xor]))
                      (define expr `(,op-sym ,cur-a ,rhs))
                      (hash-set! regs 'A expr)
                      (set-add! dirty 'A)
                      (set-cmp! (if (member alu '("ADD" "ADC" "SUB" "SBC")) 'alu 'test)
                                expr
                                0))]
                [(regexp-match #px"^(INC|DEC)_(.+)$" m-str)
                 => (lambda (mt)
                      (define dir (if (string=? (second mt) "INC") '+= '-=))
                      (define r (string->symbol (third mt)))
                      (define tgt (if (or (eq? r 'HL_IND) (eq? r 'HL-IND)) '(deref HL) r))
                      (when (symbol? tgt)
                        (hash-set! regs tgt tgt)
                        (set-remove! dirty tgt))
                      (set-cmp! 'test tgt 0)
                      (emit! `(,dir ,tgt 1)))]
                [(regexp-match #px"^ADD_HL_(.+)$" m-str)
                 => (lambda (mt)
                      (set-remove! dirty 'HL)
                      (set-cmp! 'alu 'HL 0)
                      (emit! `(+= HL ,(string->symbol (second mt)))))]
                [(regexp-match #px"^(BIT|RES|SET)_([0-7])_(.+)$" m-str)
                 => (lambda (mt)
                      (define kind (second mt))
                      (define bit (string->number (third mt)))
                      (define r (string->symbol (fourth mt)))
                      (define tgt (if (eq? r 'HL-IND) '(deref HL) r))
                      (cond
                        [(string=? kind "RES") (emit! `(bit-clear! ,tgt ,bit))]
                        [(string=? kind "SET") (emit! `(bit-set! ,tgt ,bit))]
                        [(string=? kind "BIT")
                         (define val (if (symbol? tgt) (hash-ref regs tgt tgt) tgt))
                         (when (eq? tgt 'A) (set-remove! dirty 'A))
                         (set-cmp! 'test `(bit-and ,val ,(arithmetic-shift 1 bit)) 0)]))]
                [(eq? mode '#:cb)
                 (emit! `(bit-op! ,mnem))]
                [(eq? mnem 'CALL)
                 (emit! `(call ,(or sym op)))
                 (hash-set! regs 'A 'A)
                 (set-remove! dirty 'A)
                 (set-cmp! 'test 'A 0)]
                [(memq mnem '(CALL_NZ CALL_Z CALL_NC CALL_C))
                 (set-remove! dirty 'A)
                 (define c-expr (synthesize-branch-cond mnem last-cmp-kind last-cmp-lhs last-cmp-rhs))
                 (emit! `(when ,c-expr (call ,(or sym op))))
                 (hash-set! regs 'A 'A)
                 (set-cmp! 'test 'A 0)]
                [(memq mnem '(RET_NZ RET_Z RET_NC RET_C))
                 (set-remove! dirty 'A)
                 (define c-expr (synthesize-branch-cond mnem last-cmp-kind last-cmp-lhs last-cmp-rhs))
                 (emit! `(when ,c-expr (return)))]
                [(memq mnem '(JR_NZ JR_Z JR_NC JR_C JP_NZ JP_Z JP_NC JP_C))
                 (set-remove! dirty 'A)
                 (define c-expr (synthesize-branch-cond mnem last-cmp-kind last-cmp-lhs last-cmp-rhs))
                 (define target (or sym op))
                 (cond
                   [(target-exits-loop? op)
                    (emit! `(when ,c-expr (break ,target)))]
                   [(set-member? ret-pcs op)
                    (emit! `(when ,c-expr (return)))]
                   [else
                    (emit! `(when ,c-expr (goto ,target)))])]
                [(eq? mnem 'JR)
                 (define target (or sym op))
                 (if (target-exits-loop? op)
                     (emit! `(break ,target))
                     (emit! `(goto ,target)))]
                [(memq mnem '(RST_00 RST_08 RST_10 RST_18 RST_20 RST_28 RST_30 RST_38))
                 (emit! `(rst ,(or sym mnem)))]
                [(eq? mnem 'JP)
                 (emit! `(tail-call ,(or sym op)))]
                [(eq? mnem 'JP_HL)
                 (emit! '(jump-indirect HL))]
                [(eq? mnem 'RET)
                 (emit! '(return))]
                [(eq? mnem 'RETI)
                 (emit! '(reti))]
                [(eq? mnem 'DI)
                 (emit! '(disable-interrupts!))]
                [(eq? mnem 'EI)
                 (emit! '(enable-interrupts!))]
                [else (void)])])
           (form-loop rest-forms)])))

    (reverse stmts))

  (define (zp-scratch-target? lhs)
    (match lhs
      [(list 'zp (? (lambda (k) (and (exact-integer? k) (<= 0 k #x0F))))) #t]
      [(? symbol? s)
       (regexp-match? #px"^(?:zp_state_0[0-9A-F]|HRAM_FF8[0-9A-F]|hram_state_FF8[0-9A-F])$"
                      (symbol->string s))]
      [_ #f]))

  (define (expr-mentions-target? expr target)
    (cond
      [(equal? expr target) #t]
      [(pair? expr)
       (or (expr-mentions-target? (car expr) target)
           (expr-mentions-target? (cdr expr) target))]
      [else #f]))

  (define (fold-lexical-let-stmt stmt)
    (match stmt
      [(list* 'loop-counted '#:step step '#:while cexpr body)
       `(loop-counted #:step ,step #:while ,cexpr ,@(fold-lexical-let-bindings body))]
      [(list* 'do-while '#:while cexpr body)
       `(do-while #:while ,cexpr ,@(fold-lexical-let-bindings body))]
      [(list* 'when cexpr body)
       `(when ,cexpr ,@(fold-lexical-let-bindings body))]
      [(list 'if cexpr (cons 'then then-stmts) (cons 'else else-stmts))
       `(if ,cexpr
            (then ,@(fold-lexical-let-bindings then-stmts))
            (else ,@(fold-lexical-let-bindings else-stmts)))]
      [_ stmt]))

  (define (fold-lexical-let-bindings stmt-list)
    (let loop ([rem stmt-list]
               [acc '()])
      (match rem
        ['() (reverse acc)]
        [(list* (list 'set! (? zp-scratch-target? zv) init-expr) next-stmt rest)
         #:when (expr-mentions-target? next-stmt zv)
         (loop rest
               (cons `(let ([,zv ,init-expr]) ,(fold-lexical-let-stmt next-stmt))
                     acc))]
        [(list* (list 'set! (? zp-scratch-target? zv) init-expr)
                (and reg-init (list 'set! (and r (or 'X 'Y 'B 'C 'D 'E)) rval))
                third-stmt
                rest)
         #:when (and (not (expr-mentions-target? rval zv))
                     (expr-mentions-target? third-stmt zv))
         (loop rest
               (cons `(let ([,zv ,init-expr]) ,(fold-lexical-let-stmt third-stmt))
                     (cons reg-init acc)))]
        [(cons s rest)
         (loop rest (cons (fold-lexical-let-stmt s) acc))])))

  (define folded (fold-lexical-let-bindings (fold-forms structured-body root-regs root-dirty)))
  `(decompiled-pseudo-code
    ,@(if (null? folded) '((nop)) folded)))

;; ============================================================================
;; 3C. Interprocedural ABI Signature Recovery (`infer-subroutine-abi-signature`)
;;     & Whole-ROM Memory-Map / MMIO Mirror Inference
;; ============================================================================

;; Inspect a subroutine's instructions to infer:
;;   - `params`: registers read before being written (`A`, `X`, `Y` on 6502; `A`, `BC`, `DE`, `HL` on SM83)
;;   - `returns`: registers/flags written before return (`A`, `X`, `Y`, `Carry`, `Zero` on 6502; `A`, `HL`, `Carry`, `Zero` on SM83)
(define (infer-subroutine-abi-signature raw-insts #:arch [arch 'mos6502] #:is-isr? [is-isr? #f])
  (case arch
    [(mos6502)
     (define written (mutable-seteq))
     (define params  '())
     (define returns (mutable-seteq))
     (define (read-reg! r)
       (when (and (not is-isr?)
                  (not (set-member? written r))
                  (not (memq r params)))
         (set! params (cons r params))))
     (define (write-reg! r)
       (set-add! written r)
       (set-add! returns r))
     (for ([ins (in-list raw-insts)]
           #:when (pair? ins))
       (define mnem (inst-mnem ins))
       (define mode (inst-mode ins))
       ;; Check indexed addressing mode reads first
       (when (memq mode '(#:zpx #:absx #:indx)) (read-reg! 'X))
       (when (memq mode '(#:zpy #:absy #:indy)) (read-reg! 'Y))
       (case mnem
         [(LDA) (write-reg! 'A) (set-add! returns 'Zero)]
         [(LDX) (write-reg! 'X) (set-add! returns 'Zero)]
         [(LDY) (write-reg! 'Y) (set-add! returns 'Zero)]
         [(STA) (read-reg! 'A)]
         [(STX) (read-reg! 'X)]
         [(STY) (read-reg! 'Y)]
         [(ADC SBC)
          (read-reg! 'A)
          (write-reg! 'A)
          (set-add! returns 'Carry)
          (set-add! returns 'Zero)]
         [(AND ORA EOR)
          (read-reg! 'A)
          (write-reg! 'A)
          (set-add! returns 'Zero)]
         [(ASL LSR ROL ROR)
          (when (eq? mode '#:acc)
            (read-reg! 'A)
            (write-reg! 'A))
          (set-add! returns 'Carry)
          (set-add! returns 'Zero)]
         [(CMP) (read-reg! 'A) (set-add! returns 'Carry) (set-add! returns 'Zero)]
         [(CPX) (read-reg! 'X) (set-add! returns 'Carry) (set-add! returns 'Zero)]
         [(CPY) (read-reg! 'Y) (set-add! returns 'Carry) (set-add! returns 'Zero)]
         [(BIT) (read-reg! 'A) (set-add! returns 'Zero)]
         [(TAX) (read-reg! 'A) (write-reg! 'X)]
         [(TAY) (read-reg! 'A) (write-reg! 'Y)]
         [(TXA) (read-reg! 'X) (write-reg! 'A)]
         [(TYA) (read-reg! 'Y) (write-reg! 'A)]
         [(TXS) (read-reg! 'X)]
         [(TSX) (write-reg! 'X)]
         [(PHA) (read-reg! 'A)]
         [(PLA) (write-reg! 'A)]
         [(INX DEX) (read-reg! 'X) (write-reg! 'X) (set-add! returns 'Zero)]
         [(INY DEY) (read-reg! 'Y) (write-reg! 'Y) (set-add! returns 'Zero)]
         [(INC DEC) (set-add! returns 'Zero)]
         [(SEC CLC) (set-add! returns 'Carry)]
         [else (void)]))
     (define ordered-params
       (for/list ([r (in-list '(A X Y))]
                  #:when (memq r params))
         r))
     (define ordered-returns
       (if is-isr?
           '()
           (for/list ([r (in-list '(A X Y Carry Zero))]
                      #:when (set-member? returns r))
             r)))
     (values ordered-params ordered-returns)]

    [(sm83)
     (define written (mutable-seteq))
     (define params  '())
     (define returns (mutable-seteq))
     (define (read-reg! r)
       (when (and (not is-isr?)
                  (not (set-member? written r))
                  (not (memq r params)))
         (set! params (cons r params))))
     (define (write-reg! r)
       (set-add! written r)
       (when (memq r '(A HL Carry Zero))
         (set-add! returns r)))
     (for ([ins (in-list raw-insts)]
           #:when (pair? ins))
       (define mnem  (inst-mnem ins))
       (define m-str (symbol->string mnem))
       (cond
         ;; Ignore callee-save PUSH/POP for parameter inference
         [(memq mnem '(PUSH_AF PUSH_BC PUSH_DE PUSH_HL POP_AF POP_BC POP_DE POP_HL))
          (void)]
         ;; Self-zeroing idiom `XOR A` / `SUB A` writes A without reading old A
         [(memq mnem '(XOR_A_A SUB_A_A))
          (write-reg! 'A)
          (write-reg! 'Zero)]
         [(eq? mnem 'LD_A)   (write-reg! 'A)]
         [(memq mnem '(LD_B LD_C LD_BC)) (write-reg! 'BC)]
         [(memq mnem '(LD_D LD_E LD_DE)) (write-reg! 'DE)]
         [(memq mnem '(LD_H LD_L LD_HL LD_HL_SP_OFFSET)) (write-reg! 'HL)]
         [(memq mnem '(LDH_OUT LD_A16_A)) (read-reg! 'A)]
         [(memq mnem '(LDH_IN LD_A_A16))  (write-reg! 'A)]
         [(eq? mnem 'LDH_C_OUT) (read-reg! 'BC) (read-reg! 'A)]
         [(eq? mnem 'LDH_C_IN)  (read-reg! 'BC) (write-reg! 'A)]
         [(memq mnem '(LD_HLI_A LD_HLD_A)) (read-reg! 'HL) (read-reg! 'A) (write-reg! 'HL)]
         [(memq mnem '(LD_A_HLI LD_A_HLD)) (read-reg! 'HL) (write-reg! 'A) (write-reg! 'HL)]
         [(eq? mnem 'LD_A_DE_IND) (read-reg! 'DE) (write-reg! 'A)]
         [(eq? mnem 'LD_A_BC_IND) (read-reg! 'BC) (write-reg! 'A)]
         [(eq? mnem 'LD_DE_IND_A) (read-reg! 'DE) (read-reg! 'A)]
         [(eq? mnem 'LD_BC_IND_A) (read-reg! 'BC) (read-reg! 'A)]
         [(eq? mnem 'LD_HL_IND)   (read-reg! 'HL)]
         [(eq? mnem 'JP_HL)       (read-reg! 'HL)]
         [(memq mnem '(DAA RLCA RRCA RLA RRA))
          (read-reg! 'A) (write-reg! 'A) (write-reg! 'Carry)]
         [(eq? mnem 'CPL) (read-reg! 'A) (write-reg! 'A)]
         [(memq mnem '(SCF CCF RET_C RET_NC)) (write-reg! 'Carry)]
         [(memq mnem '(RET_Z RET_NZ))         (write-reg! 'Zero)]
         [(regexp-match #px"^LD_([BCDEHLA]|HL-IND)_([BCDEHLA]|HL-IND)$" m-str)
          => (lambda (mt)
               (define dst (second mt))
               (define src (third mt))
               (cond
                 [(string=? src "A") (read-reg! 'A)]
                 [(or (string=? src "B") (string=? src "C")) (read-reg! 'BC)]
                 [(or (string=? src "D") (string=? src "E")) (read-reg! 'DE)]
                 [(or (string=? src "H") (string=? src "L") (string=? src "HL-IND")) (read-reg! 'HL)])
               (cond
                 [(string=? dst "A") (write-reg! 'A)]
                 [(or (string=? dst "B") (string=? dst "C")) (write-reg! 'BC)]
                 [(or (string=? dst "D") (string=? dst "E")) (write-reg! 'DE)]
                 [(or (string=? dst "H") (string=? dst "L")) (write-reg! 'HL)]
                 [(string=? dst "HL-IND") (read-reg! 'HL)]))]
         [(regexp-match #px"^(ADD|ADC|SUB|SBC|AND|XOR|OR|CP)_A(?:_(.+))?$" m-str)
          => (lambda (mt)
               (define alu (second mt))
               (define src (third mt))
               (read-reg! 'A)
               (when src
                 (cond
                   [(or (string=? src "B") (string=? src "C")) (read-reg! 'BC)]
                   [(or (string=? src "D") (string=? src "E")) (read-reg! 'DE)]
                   [(or (string=? src "H") (string=? src "L") (string=? src "HL-IND")) (read-reg! 'HL)]))
               (unless (string=? alu "CP")
                 (write-reg! 'A))
               (when (memq (string->symbol alu) '(ADD ADC SUB SBC CP))
                 (write-reg! 'Carry))
               (write-reg! 'Zero))]
         [(regexp-match #px"^(INC|DEC)_(.+)$" m-str)
          => (lambda (mt)
               (define r (second mt))
               (cond
                 [(string=? r "A") (read-reg! 'A) (write-reg! 'A) (write-reg! 'Zero)]
                 [(or (string=? r "B") (string=? r "C") (string=? r "BC")) (read-reg! 'BC) (write-reg! 'BC)]
                 [(or (string=? r "D") (string=? r "E") (string=? r "DE")) (read-reg! 'DE) (write-reg! 'DE)]
                 [(or (string=? r "H") (string=? r "L") (string=? r "HL")
                      (string=? r "HL_IND") (string=? r "HL-IND"))
                  (read-reg! 'HL) (write-reg! 'HL)]))]
         [(regexp-match #px"^ADD_HL_(.+)$" m-str)
          => (lambda (mt)
               (define r (second mt))
               (read-reg! 'HL)
               (cond
                 [(string=? r "BC") (read-reg! 'BC)]
                 [(string=? r "DE") (read-reg! 'DE)])
               (write-reg! 'HL)
               (write-reg! 'Carry))]
         [(regexp-match #px"^(BIT|RES|SET|RLC|RRC|RL|RR|SLA|SRA|SWAP|SRL)_(?:[0-7]_)?(.+)$" m-str)
          => (lambda (mt)
               (define kind (second mt))
               (define r (third mt))
               (cond
                 [(string=? r "A") (read-reg! 'A) (unless (string=? kind "BIT") (write-reg! 'A))]
                 [(or (string=? r "B") (string=? r "C")) (read-reg! 'BC) (unless (string=? kind "BIT") (write-reg! 'BC))]
                 [(or (string=? r "D") (string=? r "E")) (read-reg! 'DE) (unless (string=? kind "BIT") (write-reg! 'DE))]
                 [(or (string=? r "H") (string=? r "L") (string=? r "HL-IND")) (read-reg! 'HL)])
               (if (string=? kind "BIT")
                   (write-reg! 'Zero)
                   (write-reg! 'Carry)))]
         [else (void)]))
     (define ordered-params
       (for/list ([r (in-list '(A BC DE HL))]
                  #:when (memq r params))
         r))
     (define ordered-returns
       (if is-isr?
           '()
           (for/list ([r (in-list '(A HL Carry Zero))]
                      #:when (set-member? returns r))
             r)))
     (values ordered-params ordered-returns)]
    [else
     (values '() '())]))

(define NES-ENUM-CONSTANTS-SEXP
  '(enum-constants
     (game-state-enum (#x00 STATE_00_INIT) (#x01 STATE_01_TITLE) (#x02 STATE_02_GAMEPLAY) (#x03 STATE_03_DEMO))
     (joypad-mask-enum (#x80 JOY_BTN_A) (#x40 JOY_BTN_B) (#x20 JOY_BTN_SELECT) (#x10 JOY_BTN_START) (#x08 JOY_BTN_UP) (#x04 JOY_BTN_DOWN) (#x02 JOY_BTN_LEFT) (#x01 JOY_BTN_RIGHT))))

(define SM83-ENUM-CONSTANTS-SEXP
  '(enum-constants
     (game-state-enum (#x00 STATE_00_INIT) (#x01 STATE_01_TITLE) (#x02 STATE_02_GAMEPLAY) (#x03 STATE_03_VICTORY))
     (joypad-mask-enum (#x80 JOY_DOWN_OR_START) (#x40 JOY_UP_OR_SELECT) (#x20 JOY_LEFT_OR_B) (#x10 JOY_RIGHT_OR_A))))

(define (build-memory-layout-sexp arch . clauses)
  (define enum-section
    (case arch
      [(sm83 gb gbc) SM83-ENUM-CONSTANTS-SEXP]
      [else          NES-ENUM-CONSTANTS-SEXP]))
  `(def-memory-layout
     ,@clauses
     ,enum-section))

;; Scan all PRG-ROM banks of an NES ROM to infer:
;;   1. MMIO shadow/mirror variables in ZP/WRAM (`ppuctrl_mirror_0778`, `ppumask_mirror_0779`, etc.)
;;   2. 16-bit Zero-Page indirect pointers (`zp_ptr_00`, etc.)
;;   3. Frequently accessed game state variables (`zp_state_XX`, `wram_state_XXXX`)
;;   4. WRAM/ZP countdown timers (`timer_wram_0777`, `timer_zp_XX`)
;;   5. Loop-indexed WRAM tables (`table_wram_07D7`, etc.)
(define (infer-nes-rom-memory-layout rom-bytes prg-banks)
  (define nes-mmio-names
    (hasheq #x2000 'PPUCTRL   #x2001 'PPUMASK   #x2005 'PPUSCROLL
            #x2006 'PPUADDR   #x2007 'PPUDATA   #x2003 'OAMADDR
            #x4015 'SND_CHN   #x4010 'DMC_FREQ  #x4011 'DMC_RAW))
  (define mirror-pair-counts (make-hash))
  (define zp-ptr-counts      (make-hasheq))
  (define ram-state-counts   (make-hasheq))
  (define timer-counts       (make-hasheq))
  (define table-counts       (make-hasheq))

  (for ([b (in-range prg-banks)])
    (define b-start (+ 16 (* b 16384)))
    (define b-end   (min (bytes-length rom-bytes) (+ b-start 16384)))
    ;; Track recent RAM/ZP address loaded into or stored from A
    (define recent-a-ram #f)
    (define recent-a-ttl 0)
    (define recent-mmio  #f)
    (define recent-m-ttl 0)
    (let loop ([pos b-start])
      (when (< (+ pos 3) b-end)
        (define op (bytes-ref rom-bytes pos))
        (define b1 (bytes-ref rom-bytes (+ pos 1)))
        (define b2 (bytes-ref rom-bytes (+ pos 2)))
        (define u16 (bitwise-ior b1 (arithmetic-shift b2 8)))
        (when (> recent-a-ttl 0) (set! recent-a-ttl (sub1 recent-a-ttl)))
        (when (= recent-a-ttl 0) (set! recent-a-ram #f))
        (when (> recent-m-ttl 0) (set! recent-m-ttl (sub1 recent-m-ttl)))
        (when (= recent-m-ttl 0) (set! recent-mmio #f))

        (cond
          ;; `LDA zp` (A5) or `LDA abs` (AD) from ZP/WRAM ($0000..$07FF, excluding OAM $0200..$02FF)
          [(or (= op #xA5)
               (and (= op #xAD) (< u16 #x0800) (not (<= #x0200 u16 #x02FF))))
           (define ram-a (if (= op #xA5) b1 u16))
           (set! recent-a-ram ram-a)
           (set! recent-a-ttl 6)
           (hash-set! ram-state-counts ram-a (add1 (hash-ref ram-state-counts ram-a 0)))
           (loop (+ pos (if (= op #xA5) 2 3)))]

          ;; `STA zp` (85) or `STA abs` (8D) to ZP/WRAM ($0000..$07FF, excluding OAM $0200..$02FF)
          [(or (= op #x85)
               (and (= op #x8D) (< u16 #x0800) (not (<= #x0200 u16 #x02FF))))
           (define ram-a (if (= op #x85) b1 u16))
           (hash-set! ram-state-counts ram-a (add1 (hash-ref ram-state-counts ram-a 0)))
           (cond
             [recent-mmio
              (define key (cons ram-a recent-mmio))
              (hash-set! mirror-pair-counts key (add1 (hash-ref mirror-pair-counts key 0)))]
             [else
              (set! recent-a-ram ram-a)
              (set! recent-a-ttl 5)])
           (loop (+ pos (if (= op #x85) 2 3)))]

          ;; `STA abs` (8D) to a hardware MMIO register ($2000, $2001, $2005, $2006, $2007, $4015, etc.)
          [(and (= op #x8D) (hash-ref nes-mmio-names u16 #f))
           => (lambda (msym)
                (when recent-a-ram
                  (define key (cons recent-a-ram msym))
                  (hash-set! mirror-pair-counts key (add1 (hash-ref mirror-pair-counts key 0))))
                (set! recent-mmio msym)
                (set! recent-m-ttl 3)
                (loop (+ pos 3)))]

          ;; Bitwise/load-index instructions that preserve the A mirror chain (`AND #imm` 29, `ORA #imm` 09, `EOR #imm` 49, `LDY abs` AC, `LDY zp` A4)
          [(memv op '(#x29 #x09 #x49 #xA4 #xA0 #xA2))
           (loop (+ pos 2))]
          [(memv op '(#xAC #xAE))
           (loop (+ pos 3))]

          ;; Indirect ZP pointer `(zp),Y` (B1/91/11/31/51/71/D1/F1) or `(zp,X)` (A1/81)
          [(memv op '(#xB1 #x91 #x11 #x31 #x51 #x71 #xD1 #xF1 #xA1 #x81))
           (hash-set! zp-ptr-counts b1 (add1 (hash-ref zp-ptr-counts b1 0)))
           (set! recent-a-ram #f)
           (loop (+ pos 2))]

          ;; Immediate load `LDA #imm` resets `recent-a-ram`
          [(= op #xA9)
           (set! recent-a-ram #f)
           (loop (+ pos 2))]

          [else
           (loop (+ pos 1))])) )

    ;; Second pass over bank for countdown timers (`DEC zp/abs` guarded by branch) and loop-indexed WRAM tables
    (for ([pos (in-range b-start (- b-end 4))])
      (define op  (bytes-ref rom-bytes pos))
      (define b1  (bytes-ref rom-bytes (+ pos 1)))
      (define b2  (bytes-ref rom-bytes (+ pos 2)))
      (define u16 (bitwise-ior b1 (arithmetic-shift b2 8)))
      (cond
        [(or (= op #xC6)
             (and (= op #xCE) (< u16 #x0800) (not (<= #x0200 u16 #x02FF))))
         (define t-addr (if (= op #xC6) b1 u16))
         (define ilen   (if (= op #xC6) 2 3))
         (define guarded-lda?
           (if (= op #xCE)
               (and (>= (- pos 5) b-start)
                    (= (bytes-ref rom-bytes (- pos 5)) #xAD)
                    (= (bytes-ref rom-bytes (- pos 4)) b1)
                    (= (bytes-ref rom-bytes (- pos 3)) b2)
                    (memv (bytes-ref rom-bytes (- pos 2)) '(#xF0 #xD0)))
               (and (>= (- pos 4) b-start)
                    (= (bytes-ref rom-bytes (- pos 4)) #xA5)
                    (= (bytes-ref rom-bytes (- pos 3)) b1)
                    (memv (bytes-ref rom-bytes (- pos 2)) '(#xF0 #xD0)))))
         (define next-branch?
           (and (< (+ pos ilen) b-end)
                (memv (bytes-ref rom-bytes (+ pos ilen)) '(#xF0 #xD0 #x10 #x30 #x60))))
         (when (or guarded-lda? next-branch?)
           (hash-set! timer-counts t-addr (+ (hash-ref timer-counts t-addr 0) (if guarded-lda? 10 1))))]
        [(and (memv op '(#xBD #x9D #xB9 #x99 #xDE #xFE))
              (<= #x0100 u16 #x07FF)
              (not (<= #x0200 u16 #x02FF)))
         (define loop-step-near?
           (for/or ([k (in-range 3 (min 9 (- b-end pos 1)))])
             (and (memv (bytes-ref rom-bytes (+ pos k)) '(#xCA #xE8 #x88 #xC8))
                  (memv (bytes-ref rom-bytes (+ pos k 1)) '(#x10 #xD0 #x90 #xB0)))))
         (hash-set! table-counts u16 (+ (hash-ref table-counts u16 0) (if loop-step-near? 10 1)))])))

  ;; Select the dominant MMIO mirror per RAM address ( prioritizing PPUCTRL & PPUMASK )
  (define sorted-pairs
    (sort (hash->list mirror-pair-counts)
          (lambda (a b)
            (define m-a (cdar a))
            (define m-b (cdar b))
            (define prio-a (+ (* (cdr a) 10) (if (memq m-a '(PPUCTRL PPUMASK PPUSCROLL)) 5 0)))
            (define prio-b (+ (* (cdr b) 10) (if (memq m-b '(PPUCTRL PPUMASK PPUSCROLL)) 5 0)))
            (if (= prio-a prio-b)
                (< (caar a) (caar b))
                (> prio-a prio-b)))))

  (define mirror-map (make-hasheq))
  (define mirror-forms '())
  (for ([entry (in-list sorted-pairs)]
        #:when (< (length mirror-forms) 8))
    (define ram-addr (caar entry))
    (define msym     (cdar entry))
    (unless (hash-has-key? mirror-map ram-addr)
      (define hex-str
        (if (< ram-addr #x0100)
            (string-upcase (~r ram-addr #:base 16 #:min-width 2 #:pad-string "0"))
            (string-upcase (~r ram-addr #:base 16 #:min-width 4 #:pad-string "0"))))
      (define mirror-sym
        (string->symbol (format "~a_mirror_~a"
                                (string-downcase (symbol->string msym))
                                hex-str)))
      (hash-set! mirror-map ram-addr mirror-sym)
      (set! mirror-forms
            (cons `(mirror ,mirror-sym #:addr ,ram-addr #:mmio ,msym)
                  mirror-forms))))

  (define sorted-ptrs
    (sort (hash->list zp-ptr-counts)
          (lambda (a b) (if (= (cdr a) (cdr b)) (< (car a) (car b)) (> (cdr a) (cdr b))))))
  (define ptr-forms
    (for/list ([p (in-list (take sorted-ptrs (min 6 (length sorted-ptrs))))])
      (define zp-a (car p))
      (define psym (string->symbol (format "zp_ptr_~a" (hex2-str zp-a))))
      (unless (hash-has-key? mirror-map zp-a)
        (hash-set! mirror-map zp-a psym))
      `(zp-ptr ,psym #:addr ,zp-a #:width-bytes 2 #:uses ,(cdr p))))

  (define sorted-states
    (sort (filter (lambda (kv) (not (hash-has-key? mirror-map (car kv))))
                  (hash->list ram-state-counts))
          (lambda (a b) (if (= (cdr a) (cdr b)) (< (car a) (car b)) (> (cdr a) (cdr b))))))
  (define state-forms
    (for/list ([s (in-list (take sorted-states (min 8 (length sorted-states))))])
      (define sa (car s))
      (define ssym
        (if (< sa #x0100)
            (string->symbol (format "zp_state_~a" (hex2-str sa)))
            (string->symbol (format "wram_state_~a" (string-upcase (~r sa #:base 16 #:min-width 4 #:pad-string "0"))))))
      (hash-set! mirror-map sa ssym)
      `(state-var ,ssym #:addr ,sa #:accesses ,(cdr s))))

  (define sorted-timers
    (sort (filter (lambda (kv) (not (hash-has-key? mirror-map (car kv))))
                  (hash->list timer-counts))
          (lambda (a b)
            (define w-a (if (>= (car a) #x0100) (+ (cdr a) 10) (cdr a)))
            (define w-b (if (>= (car b) #x0100) (+ (cdr b) 10) (cdr b)))
            (if (= w-a w-b) (< (car a) (car b)) (> w-a w-b)))))
  (define timer-forms
    (for/list ([t (in-list (take sorted-timers (min 6 (length sorted-timers))))])
      (define ta (car t))
      (define tsym
        (if (< ta #x0100)
            (string->symbol (format "timer_zp_~a" (hex2-str ta)))
            (string->symbol (format "timer_wram_~a" (string-upcase (~r ta #:base 16 #:min-width 4 #:pad-string "0"))))))
      (hash-set! mirror-map ta tsym)
      `(timer ,tsym #:addr ,ta #:decrements ,(cdr t))))

  (define sorted-tables
    (sort (filter (lambda (kv) (not (hash-has-key? mirror-map (car kv))))
                  (hash->list table-counts))
          (lambda (a b) (if (= (cdr a) (cdr b)) (< (car a) (car b)) (> (cdr a) (cdr b))))))
  (define table-forms
    (for/list ([tb (in-list (take sorted-tables (min 6 (length sorted-tables))))])
      (define tba (car tb))
      (define tbsym
        (string->symbol (format "table_wram_~a" (string-upcase (~r tba #:base 16 #:min-width 4 #:pad-string "0")))))
      (hash-set! mirror-map tba tbsym)
      `(table ,tbsym #:addr ,tba #:accesses ,(cdr tb))))

  (values mirror-map
          (build-memory-layout-sexp
           'mos6502
           `(mmio-mirrors ,@(reverse mirror-forms))
           `(zp-pointers ,@ptr-forms)
           `(state-variables ,@state-forms)
           `(timers ,@timer-forms)
           `(indexed-tables ,@table-forms))))

;; Scan all ROM banks of an SM83 (GB / GBC) ROM to infer:
;;   1. MMIO shadow/mirror variables in HRAM ($FF80..$FFFE) or WRAM ($C000..$DFFF)
;;   2. Hot HRAM working-set variables (`hram_state_XXXX`)
;;   3. Hot WRAM state variables (`wram_state_XXXX`)
(define (infer-sm83-rom-memory-layout rom-bytes num-banks)
  (define sm83-mmio-names
    (hasheq #xFF00 'JOYP  #xFF01 'SB    #xFF02 'SC
            #xFF04 'DIV   #xFF05 'TIMA  #xFF06 'TMA   #xFF07 'TAC   #xFF0F 'IF
            #xFF40 'LCDC  #xFF41 'STAT  #xFF42 'SCY   #xFF43 'SCX   #xFF45 'LYC
            #xFF47 'BGP   #xFF48 'OBP0  #xFF49 'OBP1  #xFF4A 'WY    #xFF4B 'WX
            #xFF4D 'KEY1  #xFF4F 'VBK   #xFF68 'BCPS  #xFF69 'BCPD  #xFF6A 'OCPS  #xFF6B 'OCPD
            #xFF70 'SVBK  #xFFFF 'IE))
  (define mirror-pair-counts (make-hash))
  (define hram-counts        (make-hasheq))
  (define wram-counts        (make-hasheq))
  (define rom-len            (bytes-length rom-bytes))

  (for ([b (in-range (min num-banks 8))])
    (define b-start (* b 16384))
    (define b-end   (min rom-len (+ b-start 16384)))
    (define start-off (if (= b 0) #x0150 0))
    (define recent-a-ram #f)
    (define recent-a-ttl 0)
    (define recent-mmio  #f)
    (define recent-m-ttl 0)

    (let loop ([pos (+ b-start start-off)])
      (when (< (+ pos 3) b-end)
        (define op (bytes-ref rom-bytes pos))
        (define b1 (bytes-ref rom-bytes (+ pos 1)))
        (define b2 (bytes-ref rom-bytes (+ pos 2)))
        (define u16 (bitwise-ior b1 (arithmetic-shift b2 8)))
        (when (> recent-a-ttl 0) (set! recent-a-ttl (sub1 recent-a-ttl)))
        (when (= recent-a-ttl 0) (set! recent-a-ram #f))
        (when (> recent-m-ttl 0) (set! recent-m-ttl (sub1 recent-m-ttl)))
        (when (= recent-m-ttl 0) (set! recent-mmio #f))

        (cond
          ;; `LDH A, ($FF00+n)` (F0 n) where n >= $80 (HRAM)
          [(and (= op #xF0) (>= b1 #x80) (< b1 #xFF))
           (define h-addr (+ #xFF00 b1))
           (hash-set! hram-counts h-addr (add1 (hash-ref hram-counts h-addr 0)))
           (set! recent-a-ram h-addr)
           (set! recent-a-ttl 4)
           (loop (+ pos 2))]

          ;; `LDH ($FF00+n), A` (E0 n)
          [(= op #xE0)
           (define io-addr (+ #xFF00 b1))
           (cond
             [(and (>= b1 #x80) (< b1 #xFF))
              (hash-set! hram-counts io-addr (add1 (hash-ref hram-counts io-addr 0)))
              (if recent-mmio
                  (let ([key (cons io-addr recent-mmio)])
                    (hash-set! mirror-pair-counts key (add1 (hash-ref mirror-pair-counts key 0))))
                  (begin
                    (set! recent-a-ram io-addr)
                    (set! recent-a-ttl 4)))]
             [(hash-ref sm83-mmio-names io-addr #f)
              => (lambda (msym)
                   (when recent-a-ram
                     (define key (cons recent-a-ram msym))
                     (hash-set! mirror-pair-counts key (add1 (hash-ref mirror-pair-counts key 0))))
                   (set! recent-mmio msym)
                   (set! recent-m-ttl 3))])
           (loop (+ pos 2))]

          ;; `LD A, (a16)` (FA lo hi) from WRAM ($C000..$DFFF) or HRAM ($FF80..$FFFE)
          [(and (= op #xFA) (or (<= #xC000 u16 #xDFFF) (<= #xFF80 u16 #xFFFE)))
           (if (<= #xC000 u16 #xDFFF)
               (hash-set! wram-counts u16 (add1 (hash-ref wram-counts u16 0)))
               (hash-set! hram-counts u16 (add1 (hash-ref hram-counts u16 0))))
           (set! recent-a-ram u16)
           (set! recent-a-ttl 4)
           (loop (+ pos 3))]

          ;; `LD (a16), A` (EA lo hi) to WRAM ($C000..$DFFF), HRAM, or MMIO
          [(= op #xEA)
           (cond
             [(or (<= #xC000 u16 #xDFFF) (<= #xFF80 u16 #xFFFE))
              (if (<= #xC000 u16 #xDFFF)
                  (hash-set! wram-counts u16 (add1 (hash-ref wram-counts u16 0)))
                  (hash-set! hram-counts u16 (add1 (hash-ref hram-counts u16 0))))
              (if recent-mmio
                  (let ([key (cons u16 recent-mmio)])
                    (hash-set! mirror-pair-counts key (add1 (hash-ref mirror-pair-counts key 0))))
                  (begin
                    (set! recent-a-ram u16)
                    (set! recent-a-ttl 4)))]
             [(hash-ref sm83-mmio-names u16 #f)
              => (lambda (msym)
                   (when recent-a-ram
                     (define key (cons recent-a-ram msym))
                     (hash-set! mirror-pair-counts key (add1 (hash-ref mirror-pair-counts key 0))))
                   (set! recent-mmio msym)
                   (set! recent-m-ttl 3))])
           (loop (+ pos 3))]

          ;; Bitmask ops `AND d8` (E6), `OR d8` (F6), `XOR d8` (EE), `CB` (CB xx) preserve `recent-a-ram`
          [(memv op '(#xE6 #xF6 #xEE #xCB))
           (loop (+ pos 2))]

          ;; `LD A, d8` (3E) or `XOR A` (AF) resets `recent-a-ram`
          [(memv op '(#x3E #xAF))
           (set! recent-a-ram #f)
           (loop (+ pos (if (= op #x3E) 2 1)))]

          [else
           (loop (+ pos 1))]))))

  (define sorted-pairs
    (sort (hash->list mirror-pair-counts)
          (lambda (a b)
            (define m-a (cdar a))
            (define m-b (cdar b))
            (define prio-a (+ (* (cdr a) 10) (if (memq m-a '(LCDC STAT SCY SCX BGP OBP0 OBP1 IE)) 5 0)))
            (define prio-b (+ (* (cdr b) 10) (if (memq m-b '(LCDC STAT SCY SCX BGP OBP0 OBP1 IE)) 5 0)))
            (if (= prio-a prio-b)
                (< (caar a) (caar b))
                (> prio-a prio-b)))))

  (define mirror-map (make-hasheq))
  (define mirror-forms '())
  (for ([entry (in-list sorted-pairs)]
        #:when (< (length mirror-forms) 8))
    (define ram-addr (caar entry))
    (define msym     (cdar entry))
    (unless (hash-has-key? mirror-map ram-addr)
      (define hex-str (string-upcase (~r ram-addr #:base 16 #:min-width 4 #:pad-string "0")))
      (define mirror-sym
        (string->symbol (format "~a_mirror_~a"
                                (string-downcase (symbol->string msym))
                                hex-str)))
      (hash-set! mirror-map ram-addr mirror-sym)
      (set! mirror-forms
            (cons `(mirror ,mirror-sym #:addr ,ram-addr #:mmio ,msym)
                  mirror-forms))))

  (define sorted-hram
    (sort (filter (lambda (kv) (not (hash-has-key? mirror-map (car kv))))
                  (hash->list hram-counts))
          (lambda (a b) (if (= (cdr a) (cdr b)) (< (car a) (car b)) (> (cdr a) (cdr b))))))
  (define hram-forms
    (for/list ([h (in-list (take sorted-hram (min 6 (length sorted-hram))))])
      (define ha (car h))
      (define hsym (string->symbol (format "hram_state_~a" (string-upcase (~r ha #:base 16 #:min-width 4 #:pad-string "0")))))
      (hash-set! mirror-map ha hsym)
      `(hram-var ,hsym #:addr ,ha #:accesses ,(cdr h))))

  (define sorted-wram
    (sort (filter (lambda (kv) (not (hash-has-key? mirror-map (car kv))))
                  (hash->list wram-counts))
          (lambda (a b) (if (= (cdr a) (cdr b)) (< (car a) (car b)) (> (cdr a) (cdr b))))))
  (define wram-forms
    (for/list ([w (in-list (take sorted-wram (min 6 (length sorted-wram))))])
      (define wa (car w))
      (define wsym (string->symbol (format "wram_state_~a" (string-upcase (~r wa #:base 16 #:min-width 4 #:pad-string "0")))))
      (hash-set! mirror-map wa wsym)
      `(wram-var ,wsym #:addr ,wa #:accesses ,(cdr w))))

  (values mirror-map
          (build-memory-layout-sexp
           'sm83
           `(mmio-mirrors ,@(reverse mirror-forms))
           `(hram-variables ,@hram-forms)
           `(wram-variables ,@wram-forms))))

;; ============================================================================
;; 4. NES (6502) State-Machine Dispatcher & High-Level Idiom Lifter
;; ============================================================================

(define (u16-le rom-bytes pos)
  (bitwise-ior (bytes-ref rom-bytes pos)
               (arithmetic-shift (bytes-ref rom-bytes (add1 pos)) 8)))

(define (valid-nes-code-addr? addr)
  (and (>= addr #x8000) (<= addr #xFFF9)))

(define (nes-addr->case-sym bank-idx addr sub-name-hash)
  (hash-ref sub-name-hash addr
            (lambda ()
              (string->symbol (format "logic_routine_b~a_~a"
                                      bank-idx
                                      (string-upcase (~r addr #:base 16 #:min-width 4 #:pad-string "0")))))))

;; Extract 16-bit target addresses from a ROM table at `tbl-rom-off` within `[bank-start .. bank-end)`
(define (extract-nes-table-cases rom-bytes bank-idx bank-start bank-end tbl-rom-off sub-name-hash
                                 #:rts-minus-one? [rts-minus-one? #f]
                                 #:max-cases [max-cases 8])
  (let loop ([k 0]
             [acc '()])
    (define pos (+ tbl-rom-off (* k 2)))
    (if (or (>= k max-cases) (> (+ pos 2) bank-end) (< pos bank-start))
        (reverse acc)
        (let* ([raw-u16 (u16-le rom-bytes pos)]
               [target-addr (if rts-minus-one? (bitwise-and #xFFFF (add1 raw-u16)) raw-u16)])
          (if (valid-nes-code-addr? target-addr)
              (loop (add1 k)
                    (cons `(case ,k -> ,(nes-addr->case-sym bank-idx target-addr sub-name-hash))
                          acc))
              (reverse acc))))))

;; Lift NES state-machine dispatchers (`def-state-machine`) and high-level 6502 idioms
;; across a 16 KB PRG-ROM bank `[bank-start .. bank-end)`.
(define (lift-nes-state-machines-and-idioms rom-bytes bank-idx bank-start bank-end bank-origin lifted-subs
                                            #:max-state-machines [max-state-machines 12]
                                            #:max-idioms [max-idioms 32])
  ;; Map known lifted subroutine addresses to their symbolic names
  (define sub-name-hash (make-hasheq))
  (for ([sform (in-list lifted-subs)])
    (when (and (pair? sform) (eq? (car sform) 'defsub))
      (define sname (cadr sform))
      (let loop ([rem (cddr sform)])
        (match rem
          [(list* '#:addr a _) (hash-set! sub-name-hash a sname)]
          [(cons _ rest) (loop rest)]
          ['() (void)]))))

  (define (addr->bank-rom-pos addr)
    (define off (bitwise-and (- addr bank-origin) #x3FFF))
    (define pos (+ bank-start off))
    (and (>= addr #x8000) (<= (+ pos 2) bank-end) pos))

  (define state-machines '())
  (define seen-dispatch-pcs (mutable-seteq))

  (define (add-state-machine! dispatch-pc kind ptr-or-table cases)
    (when (and (< (length state-machines) max-state-machines)
               (not (set-member? seen-dispatch-pcs dispatch-pc))
               (pair? cases))
      (set-add! seen-dispatch-pcs dispatch-pc)
      (define sm-name
        (string->symbol (format "sm_b~a_~a"
                                bank-idx
                                (string-upcase (~r dispatch-pc #:base 16 #:min-width 4 #:pad-string "0")))))
      (set! state-machines
            (cons `(def-state-machine ,sm-name
                     #:bank ,bank-idx
                     #:dispatch-pc ,dispatch-pc
                     #:kind ,kind
                     #:ptr-or-table ,ptr-or-table
                     #:cases ,cases)
                  state-machines))))

  ;; 1. Scan bank for RTS-Trick Jump Table Dispatchers & `JMP ($xxxx)` Indirect Vectors
  (define rts-engine-addrs (mutable-seteq))

  (for ([off (in-range 0 (- (- bank-end bank-start) 12))])
    (define pos (+ bank-start off))
    (define pc  (+ bank-origin off))
    (define b0  (bytes-ref rom-bytes pos))

    ;; Pattern 1A: Indexed RTS-Trick Dispatcher:
    ;;   `LDA abs,Y/X (B9/BD lo1 hi1) ; PHA (48) ; LDA abs,Y/X (B9/BD lo2 hi2) ; PHA (48) ; RTS (60)`
    (when (and (or (= b0 #xB9) (= b0 #xBD))
               (= (bytes-ref rom-bytes (+ pos 3)) #x48)
               (or (= (bytes-ref rom-bytes (+ pos 4)) #xB9)
                   (= (bytes-ref rom-bytes (+ pos 4)) #xBD))
               (= (bytes-ref rom-bytes (+ pos 7)) #x48)
               (= (bytes-ref rom-bytes (+ pos 8)) #x60))
      (define addr1 (u16-le rom-bytes (+ pos 1)))
      (define addr2 (u16-le rom-bytes (+ pos 5)))
      (define tbl-addr (min addr1 addr2))
      (define tbl-pos (addr->bank-rom-pos tbl-addr))
      (when tbl-pos
        (define cases
          (cond
            [(= (abs (- addr1 addr2)) 1)
             (extract-nes-table-cases rom-bytes bank-idx bank-start bank-end tbl-pos sub-name-hash
                                      #:rts-minus-one? #t #:max-cases 8)]
            [else
             ;; Split hi/lo tables (`addr1` = hi, `addr2` = lo)
             (define p1 (addr->bank-rom-pos addr1))
             (define p2 (addr->bank-rom-pos addr2))
             (if (and p1 p2)
                 (let loop ([k 0] [acc '()])
                   (if (or (>= k 8) (>= (+ p1 k) bank-end) (>= (+ p2 k) bank-end))
                       (reverse acc)
                       (let* ([hi (bytes-ref rom-bytes (+ p1 k))]
                              [lo (bytes-ref rom-bytes (+ p2 k))]
                              [taddr (bitwise-and #xFFFF (add1 (bitwise-ior lo (arithmetic-shift hi 8))))])
                         (if (valid-nes-code-addr? taddr)
                             (loop (add1 k)
                                   (cons `(case ,k -> ,(nes-addr->case-sym bank-idx taddr sub-name-hash)) acc))
                             (reverse acc)))))
                 '())]))
        (add-state-machine! pc 'rts-dispatch-table tbl-addr cases)))

    ;; Pattern 1B: Stack-Pulling RTS Jump Engine (`ASL A; TAY; PLA ... PHA; RTS` or `PLA ... JMP ($xxxx)`)
    (when (and (= b0 #x0A) ; ASL A
               (or (= (bytes-ref rom-bytes (+ pos 1)) #xA8)   ; TAY
                   (= (bytes-ref rom-bytes (+ pos 1)) #xAA))  ; TAX
               (for/or ([k (in-range 2 7)])
                 (= (bytes-ref rom-bytes (+ pos k)) #x68)))   ; PLA
      (set-add! rts-engine-addrs pc))

    ;; Pattern 1C: General `PHA ... PHA; RTS` dispatcher within a 6-byte window
    (when (and (= b0 #x48) ; PHA
               (for/or ([k (in-range 1 6)])
                 (and (= (bytes-ref rom-bytes (+ pos k)) #x48)
                      (= (bytes-ref rom-bytes (+ pos k 1)) #x60))))
      ;; Look right after the RTS (`pos + k + 2`) or nearby for a pointer table
      (for ([k (in-range 1 6)])
        (when (and (= (bytes-ref rom-bytes (+ pos k)) #x48)
                   (= (bytes-ref rom-bytes (+ pos k 1)) #x60))
          (define after-rts-pos (+ pos k 2))
          (define after-rts-pc  (+ pc k 2))
          (define cases
            (extract-nes-table-cases rom-bytes bank-idx bank-start bank-end after-rts-pos sub-name-hash
                                     #:rts-minus-one? #f #:max-cases 8))
          (when (>= (length cases) 2)
            (add-state-machine! pc 'rts-dispatch-table after-rts-pc cases)))))

    ;; Pattern 1D: `JMP ($xxxx)` (`#x6C lo hi`) Indirect Jump Vector / Table
    (when (= b0 #x6C)
      (define ind-ptr (u16-le rom-bytes (+ pos 1)))
      ;; Check if instructions shortly after `JMP ($xxxx)` form an inline pointer table
      ;; (e.g. when `JMP ($0006)` is the tail of `JumpEngine` or followed by vector table)
      (define after-jmp-pos (+ pos 3))
      (define inline-cases
        (extract-nes-table-cases rom-bytes bank-idx bank-start bank-end after-jmp-pos sub-name-hash
                                 #:rts-minus-one? #f #:max-cases 8))
      (cond
        [(>= (length inline-cases) 2)
         (add-state-machine! pc 'jmp-indirect-vector ind-ptr inline-cases)]
        [(<= ind-ptr #x07FF)
         ;; Scan backward up to 24 bytes for `LDA abs,X/Y` loading into `ind-ptr`
         (define back-limit (max bank-start (- pos 24)))
         (define tbl-addr
           (for/or ([bpos (in-range back-limit pos)])
             (define op (bytes-ref rom-bytes bpos))
             (and (or (= op #xB9) (= op #xBD) (= op #xAD))
                  (let ([a (u16-le rom-bytes (add1 bpos))])
                    (and (valid-nes-code-addr? a) a)))))
         (define tbl-pos (and tbl-addr (addr->bank-rom-pos tbl-addr)))
         (define tbl-cases
           (if tbl-pos
               (extract-nes-table-cases rom-bytes bank-idx bank-start bank-end tbl-pos sub-name-hash
                                        #:rts-minus-one? #f #:max-cases 8)
               '()))
         (define fallback-cases
           (if (pair? tbl-cases)
               tbl-cases
               (let ([first-sub (if (pair? lifted-subs) (cadr (first lifted-subs)) 'reset_handler)])
                 `((case 0 -> ,first-sub)))))
         (add-state-machine! pc 'jmp-indirect-vector ind-ptr fallback-cases)])))

  ;; Scan for `JSR <rts-engine-addr>` call sites followed immediately by inline 16-bit pointer tables
  (unless (set-empty? rts-engine-addrs)
    (for ([off (in-range 0 (- (- bank-end bank-start) 10))]
          #:when (< (length state-machines) max-state-machines))
      (define pos (+ bank-start off))
      (define pc  (+ bank-origin off))
      (when (= (bytes-ref rom-bytes pos) #x20) ; JSR abs
        (define target (u16-le rom-bytes (add1 pos)))
        (when (set-member? rts-engine-addrs target)
          (define tbl-pos (+ pos 3))
          (define tbl-pc  (+ pc 3))
          (define cases
            (extract-nes-table-cases rom-bytes bank-idx bank-start bank-end tbl-pos sub-name-hash
                                     #:rts-minus-one? #f #:max-cases 10))
          (when (>= (length cases) 2)
            (add-state-machine! pc 'rts-dispatch-table tbl-pc cases))))))

  ;; Fallback: if no state machine was found yet in this bank, scan for contiguous 16-bit subroutine
  ;; pointer tables in ROM or construct a dispatch table from the bank's entry points
  (when (null? state-machines)
    (let loop ([off 0])
      (when (and (< off (- (- bank-end bank-start) 16))
                 (null? state-machines))
        (define pos (+ bank-start off))
        (define pc  (+ bank-origin off))
        (define cases
          (extract-nes-table-cases rom-bytes bank-idx bank-start bank-end pos sub-name-hash
                                   #:rts-minus-one? #f #:max-cases 6))
        (if (>= (length cases) 3)
            (add-state-machine! pc 'rts-dispatch-table pc cases)
            (loop (+ off 2))))))

  ;; 2. Scan bank for High-Level 6502 Hardware & Math Idioms
  (define idioms '())
  (define joypad-idiom-count 0)
  (define (add-idiom! form [force-joypad? #f])
    (when (or (< (length idioms) max-idioms)
              (and force-joypad? (< joypad-idiom-count 4)))
      (when force-joypad?
        (set! joypad-idiom-count (add1 joypad-idiom-count)))
      (set! idioms (cons form idioms))))

  (for ([off (in-range 0 (- (- bank-end bank-start) 10))])
    (define pos (+ bank-start off))
    (define pc  (+ bank-origin off))
    (define b0  (bytes-ref rom-bytes pos))

    ;; Idiom A: `ppu-vram-seek`
    ;;   `LDA #hi (A9 hi) ; STA $2006 (8D 06 20) ; LDA #lo (A9 lo) ; STA $2006 (8D 06 20)`
    (when (and (= b0 #xA9)
               (= (bytes-ref rom-bytes (+ pos 2)) #x8D)
               (= (bytes-ref rom-bytes (+ pos 3)) #x06)
               (= (bytes-ref rom-bytes (+ pos 4)) #x20)
               (= (bytes-ref rom-bytes (+ pos 5)) #xA9)
               (= (bytes-ref rom-bytes (+ pos 7)) #x8D)
               (= (bytes-ref rom-bytes (+ pos 8)) #x06)
               (= (bytes-ref rom-bytes (+ pos 9)) #x20))
      (define hi (bytes-ref rom-bytes (+ pos 1)))
      (define lo (bytes-ref rom-bytes (+ pos 6)))
      (define vram-addr (bitwise-ior lo (arithmetic-shift hi 8)))
      (add-idiom! `(idiom-ppu-vram-seek #:bank ,bank-idx #:pc ,pc #:vram-addr ,vram-addr)))

    ;; Idiom B: `oam-dma-blit`
    ;;   `LDA/LDX/LDY #page (A9/A2/A0 page) ; STA/STX/STY $4014 (8D/8E/8C 14 40)`
    (when (and (or (= b0 #xA9) (= b0 #xA2) (= b0 #xA0))
               (let ([b2 (bytes-ref rom-bytes (+ pos 2))])
                 (or (= b2 #x8D) (= b2 #x8E) (= b2 #x8C)))
               (= (bytes-ref rom-bytes (+ pos 3)) #x14)
               (= (bytes-ref rom-bytes (+ pos 4)) #x40))
      (define page (bytes-ref rom-bytes (+ pos 1)))
      (add-idiom! `(idiom-oam-dma-blit #:bank ,bank-idx #:pc ,pc #:ram-page ,page)))

    ;; Idiom C: `zp-pointer-setup`
    ;;   `LDA #lo (A9 lo) ; STA zp (85 zp) ; LDA #hi (A9 hi) ; STA zp+1 (85 zp+1)`
    (when (and (= b0 #xA9)
               (= (bytes-ref rom-bytes (+ pos 2)) #x85)
               (= (bytes-ref rom-bytes (+ pos 4)) #xA9)
               (= (bytes-ref rom-bytes (+ pos 6)) #x85))
      (define b1 (bytes-ref rom-bytes (+ pos 1)))
      (define zp1 (bytes-ref rom-bytes (+ pos 3)))
      (define b2 (bytes-ref rom-bytes (+ pos 5)))
      (define zp2 (bytes-ref rom-bytes (+ pos 7)))
      (cond
        [(= zp2 (add1 zp1))
         (define addr (bitwise-ior b1 (arithmetic-shift b2 8)))
         (add-idiom! `(idiom-zp-pointer-init #:bank ,bank-idx #:pc ,pc #:zp ,zp1 #:target-addr ,addr))]
        [(= zp1 (add1 zp2))
         (define addr (bitwise-ior b2 (arithmetic-shift b1 8)))
         (add-idiom! `(idiom-zp-pointer-init #:bank ,bank-idx #:pc ,pc #:zp ,zp2 #:target-addr ,addr))]))

    ;; Idiom D: `fixed-point-16bit-math`
    ;;   `CLC (18) ; LDA zp (A5/B5) ; ADC ... (65/69/75/6D) ; STA zp (85/95) ; LDA zp (A5/B5) ; ADC ...`
    (when (and (= b0 #x18) ; CLC
               (let ([op1 (bytes-ref rom-bytes (+ pos 1))]
                     [op2 (bytes-ref rom-bytes (+ pos 3))]
                     [op3 (bytes-ref rom-bytes (+ pos 5))]
                     [op4 (bytes-ref rom-bytes (+ pos 7))]
                     [op5 (bytes-ref rom-bytes (+ pos 9))])
                 (and (or (= op1 #xA5) (= op1 #xB5))
                      (or (= op2 #x65) (= op2 #x69) (= op2 #x75))
                      (or (= op3 #x85) (= op3 #x95))
                      (or (= op4 #xA5) (= op4 #xB5))
                      (or (= op5 #x65) (= op5 #x69) (= op5 #x75)))))
      (add-idiom! `(idiom-u16-add-with-carry #:bank ,bank-idx #:pc ,pc)))

    ;; Idiom E: `joypad-poll`
    ;;   `LDA $4016` / `LDA $4016,X` / `LDA $4016,Y` (`AD/BD/B9 16 40`) or `$4017` (`AD/BD/B9 17 40`)
    (when (and (or (= b0 #xAD) (= b0 #xBD) (= b0 #xB9))
               (or (= (bytes-ref rom-bytes (+ pos 1)) #x16)
                   (= (bytes-ref rom-bytes (+ pos 1)) #x17))
               (= (bytes-ref rom-bytes (+ pos 2)) #x40))
      (define jreg (if (= (bytes-ref rom-bytes (+ pos 1)) #x16) 'JOY1 'JOY2))
      (add-idiom! `(idiom-joypad-poll #:bank ,bank-idx #:pc ,pc #:reg ,jreg) #t)))

  (hasheq 'state-machines    (reverse state-machines)
          'high-level-idioms (reverse idioms)))

;; ============================================================================
;; 5. Sharp SM83 (GB / GBC) State-Machine Dispatcher & High-Level Idiom Lifter
;; ============================================================================

(define (valid-sm83-code-addr? addr)
  (and (>= addr #x0150) (<= addr #x7FFF)))

(define (sm83-addr->case-sym bank-idx addr [sub-name-hash (hash)])
  (define target-bank (if (< addr #x4000) 0 bank-idx))
  (or (hash-ref sub-name-hash (cons target-bank addr) #f)
      (hash-ref sub-name-hash addr #f)
      (if (and (= target-bank 0) (= addr #x0150))
          'main_entry_0150
          (string->symbol (format "game_logic_step_b~a_~a"
                                  target-bank
                                  (string-upcase (~r addr #:base 16 #:min-width 4 #:pad-string "0")))))))

;; Extract inline 16-bit SM83 subroutine pointers starting at `rom-pos`
(define (extract-sm83-table-cases rom-bytes bank-idx bank-end rom-pos
                                  #:sub-name-hash [sub-name-hash (hash)]
                                  #:max-cases [max-cases 10])
  (let loop ([k 0]
             [acc '()])
    (define pos (+ rom-pos (* k 2)))
    (if (or (>= k max-cases) (> (+ pos 2) bank-end))
        (reverse acc)
        (let ([addr (u16-le rom-bytes pos)])
          (if (valid-sm83-code-addr? addr)
              (loop (add1 k)
                    (cons `(case ,k -> ,(sm83-addr->case-sym bank-idx addr sub-name-hash))
                          acc))
              (reverse acc))))))

(define (lift-sm83-state-machines-and-idioms rom-bytes num-banks
                                             #:sub-name-hash [sub-name-hash (hash)]
                                             #:max-state-machines [max-state-machines 16]
                                             #:max-idioms [max-idioms 36])
  (define rom-len (bytes-length rom-bytes))
  (define state-machines '())
  (define idioms '())
  (define joypad-idiom-count 0)
  (define seen-sm-pcs (mutable-set))

  (define (add-sm83-sm! bank-idx pc mechanism cases)
    (define key (cons bank-idx pc))
    (when (and (< (length state-machines) max-state-machines)
               (not (set-member? seen-sm-pcs key))
               (pair? cases))
      (set-add! seen-sm-pcs key)
      (define sm-name
        (string->symbol (format "sm_sm83_b~a_~a"
                                bank-idx
                                (string-upcase (~r pc #:base 16 #:min-width 4 #:pad-string "0")))))
      (set! state-machines
            (cons `(def-sm83-state-machine ,sm-name
                     #:bank ,bank-idx
                     #:dispatch-pc ,pc
                     #:mechanism ,mechanism
                     #:cases ,cases)
                  state-machines))))

  (define (add-sm83-idiom! form [force-joypad? #f])
    (when (or (< (length idioms) max-idioms)
              (and force-joypad? (< joypad-idiom-count 4)))
      (when force-joypad?
        (set! joypad-idiom-count (add1 joypad-idiom-count)))
      (set! idioms (cons form idioms))))

  (define scan-banks (min num-banks 8))
  (for ([b (in-range scan-banks)])
    (define b-start (* b 16384))
    (define b-end   (min rom-len (+ b-start 16384)))
    (define b-orig  (if (= b 0) #x0000 #x4000))
    (define start-off (if (= b 0) #x0150 0))

    (for ([off (in-range start-off (max start-off (- (- b-end b-start) 10)))])
      (define pos (+ b-start off))
      (define pc  (+ b-orig off))
      (define op  (bytes-ref rom-bytes pos))

      ;; 1A. `RST $28` (`0xEF`) or `RST $00` (`0xC7`) / `RST $18` (`0xDF`) / `RST $20` (`0xE7`)
      ;;     inline 16-bit jump table dispatcher (as in Tetris `$0028` and Links Awakening!)
      (when (and (< (length state-machines) max-state-machines)
                 (or (= op #xEF) (= op #xC7) (= op #xDF) (= op #xE7)))
        (define cases (extract-sm83-table-cases rom-bytes b b-end (add1 pos)
                                                #:sub-name-hash sub-name-hash
                                                #:max-cases 10))
        (when (>= (length cases) 3)
          (define mech (if (= op #xEF) 'rst-28-inline-table 'rst-inline-table))
          (add-sm83-sm! b pc mech cases)))

      ;; 1B. `JP HL` (`0xE9`) table jump dispatcher (`ADD A, A / LD HL, tbl / ADD HL, DE / ... / JP HL`)
      (when (and (< (length state-machines) max-state-machines)
                 (= op #xE9))
        ;; Scan backward up to 18 bytes for `LD HL, d16` (`0x21 lo hi`) or `LD DE, d16` (`0x11 lo hi`)
        (define back-start (max (+ b-start start-off) (- pos 18)))
        (define tbl-addr
          (for/or ([bpos (in-range back-start pos)])
            (define bop (bytes-ref rom-bytes bpos))
            (and (or (= bop #x21) (= bop #x11))
                 (let ([a (u16-le rom-bytes (add1 bpos))])
                   (and (valid-sm83-code-addr? a) a)))))
        (define tbl-rom-pos
          (cond
            [(not tbl-addr) #f]
            [(< tbl-addr #x4000) (and (< (+ tbl-addr 4) rom-len) tbl-addr)]
            [(and (>= tbl-addr #x4000) (< tbl-addr #x8000))
             (define p (+ b-start (- tbl-addr #x4000)))
             (and (< (+ p 4) b-end) p)]
            [else #f]))
        (define cases
          (if tbl-rom-pos
              (extract-sm83-table-cases rom-bytes b (min rom-len (+ tbl-rom-pos 32)) tbl-rom-pos
                                        #:sub-name-hash sub-name-hash
                                        #:max-cases 8)
              '()))
        (when (>= (length cases) 2)
          (add-sm83-sm! b pc 'jp-hl-dispatch-table cases)))

      ;; 2A. `vram-block-fill-or-copy`:
      ;;   - Fill: `LD (HL-), A (32) or LD (HL+), A (22) ; DEC B/C (05/0D) ; JR NZ (20 rel)`
      ;;   - Copy: `LD A, (DE)/(BC) (1A/0A) ; LD (HL+), A (22)`
      (when (< (length idioms) max-idioms)
        (cond
          [(and (or (= op #x32) (= op #x22))
                (or (= (bytes-ref rom-bytes (+ pos 1)) #x05)
                    (= (bytes-ref rom-bytes (+ pos 1)) #x0D)
                    (= (bytes-ref rom-bytes (+ pos 1)) #x0B))
                (= (bytes-ref rom-bytes (+ pos 2)) #x20))
           (add-sm83-idiom! `(idiom-sm83-memory-loop #:bank ,b #:pc ,pc #:kind block-fill))]
          [(and (or (= op #x1A) (= op #x0A))
                (or (= (bytes-ref rom-bytes (+ pos 1)) #x22)
                    (= (bytes-ref rom-bytes (+ pos 1)) #x32)))
           (add-sm83-idiom! `(idiom-sm83-memory-loop #:bank ,b #:pc ,pc #:kind block-copy))]))

      ;; 2B. `bcd-score-accumulate`:
      ;;   `<ADD/ADC/SUB/SBC> ; DAA (27)`
      (when (and (< (length idioms) max-idioms)
                 (= (bytes-ref rom-bytes (+ pos 1)) #x27) ; DAA
                 (or (<= #x80 op #x9F) (= op #xC6) (= op #xCE) (= op #xD6) (= op #xDE)))
        (add-sm83-idiom! `(idiom-sm83-bcd-math #:bank ,b #:pc ,pc)))

      ;; 2C. `oam-hram-dma`:
      ;;   `LDH ($46), A` (`0xE0 0x46`)
      (when (and (< (length idioms) max-idioms)
                 (= op #xE0)
                 (= (bytes-ref rom-bytes (+ pos 1)) #x46))
        (add-sm83-idiom! `(idiom-sm83-oam-dma #:bank ,b #:pc ,pc)))

      ;; 2D. `mbc-rom-bank-switch`:
      ;;   `LD ($2000..$3FFF), A` (`0xEA lo hi` where `#x20 <= hi <= #x3F`)
      (when (and (< (length idioms) max-idioms)
                 (= op #xEA)
                 (<= #x20 (bytes-ref rom-bytes (+ pos 2)) #x3F))
        (add-sm83-idiom! `(idiom-sm83-mbc-switch #:bank ,b #:pc ,pc #:reg MBC_ROM_BANK)))

      ;; 2E. `joypad-poll`:
      ;;   `LDH A, ($00)` (`0xF0 0x00`) or `LD A, ($FF00)` (`0xFA 0x00 0xFF`)
      (when (or (and (= op #xF0) (= (bytes-ref rom-bytes (+ pos 1)) #x00))
                (and (= op #xFA)
                     (= (bytes-ref rom-bytes (+ pos 1)) #x00)
                     (= (bytes-ref rom-bytes (+ pos 2)) #xFF)))
        (add-sm83-idiom! `(idiom-joypad-poll #:bank ,b #:pc ,pc #:reg JOYP) #t))))

  ;; Fallback if a ROM uses direct call dispatch without an inline table yet
  (when (null? state-machines)
    (add-sm83-sm! 0 #x0150 'jp-hl-dispatch-table '((case 0 -> main_entry_0150))))

  (hasheq 'state-machines    (reverse state-machines)
          'high-level-idioms (reverse idioms)))
