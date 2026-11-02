#lang racket/base

;; ============================================================================
;; #lang boba-nes : MOS 6502 Two-Pass Assembler, 2bpp CHR Compiler,
;;                  iNES 1.0 (.nes) ROM Linker & Cycle-Accurate 6502/2C02 VM
;; ============================================================================

(require racket/match
         racket/list
         racket/format
         racket/string
         racket/bytes
         racket/math)

(provide
 ;; 6502 Two-Pass Assembler & ca65 Emitter
 (struct-out asm-result)
 assemble-6502
 emit-ca65-asm

 ;; 2bpp CHR-ROM Tile Compiler & iNES 1.0 Binary ROM Builder
 compile-chr-tile
 build-chr-rom
 build-ines-rom
 write-ines-rom-file!

 ;; Cycle-Accurate MOS 6502 + Ricoh 2C02 PPU/OAM/Joypad Verification Emulator
 (struct-out nes-emulator)
 make-nes-emulator-from-rom
 nes-reset!
 nes-set-joypad1!
 nes-step!
 nes-run-until-rts!
 nes-run-nmi!
 nes-step-frame!
 nes-zp-ref
 nes-zp-set!
 nes-ram-ref
 nes-ram-set!
 nes-vram-ref
 nes-palette-ref
 nes-oam-sprite-ref

 ;; Controller 1 Button Bitmasks
 BTN-A
 BTN-B
 BTN-SELECT
 BTN-START
 BTN-UP
 BTN-DOWN
 BTN-LEFT
 BTN-RIGHT)

;; ============================================================================
;; 1. Official MOS 6502 Opcode Table (Opcode, Byte Length, Base Cycles)
;; ============================================================================
;; Addressing modes:
;;   'imp  : Implied (1B)
;;   'acc  : Accumulator A (1B)
;;   'imm  : Immediate #v (2B)
;;   'zp   : Zero-Page $zp (2B)
;;   'zpx  : Zero-Page,X $zp,X (2B)
;;   'zpy  : Zero-Page,Y $zp,Y (2B)
;;   'rel  : Relative branch target (2B)
;;   'abs  : Absolute $aaaa (3B)
;;   'absx : Absolute,X $aaaa,X (3B)
;;   'absy : Absolute,Y $aaaa,Y (3B)
;;   'ind  : Indirect ($aaaa) (3B)
;;   'indx : Indexed Indirect ($zp,X) (2B)
;;   'indy : Indirect Indexed ($zp),Y (2B)

(define OPCODE-TABLE
  (hash
   ;; Load / Store
   'LDA (hash 'imm '(#xA9 2 2) 'zp '(#xA5 2 3) 'zpx '(#xB5 2 4)
              'abs '(#xAD 3 4) 'absx '(#xBD 3 4) 'absy '(#xB9 3 4)
              'indx '(#xA1 2 6) 'indy '(#xB1 2 5))
   'LDX (hash 'imm '(#xA2 2 2) 'zp '(#xA6 2 3) 'zpy '(#xB6 2 4)
              'abs '(#xAE 3 4) 'absy '(#xBE 3 4))
   'LDY (hash 'imm '(#xA0 2 2) 'zp '(#xA4 2 3) 'zpx '(#xB4 2 4)
              'abs '(#xAC 3 4) 'absx '(#xBC 3 4))
   'STA (hash 'zp '(#x85 2 3) 'zpx '(#x95 2 4)
              'abs '(#x8D 3 4) 'absx '(#x9D 3 5) 'absy '(#x99 3 5)
              'indx '(#x81 2 6) 'indy '(#x91 2 6))
   'STX (hash 'zp '(#x86 2 3) 'zpy '(#x96 2 4) 'abs '(#x8E 3 4))
   'STY (hash 'zp '(#x84 2 3) 'zpx '(#x94 2 4) 'abs '(#x8C 3 4))

   ;; Register Transfers & Stack
   'TAX (hash 'imp '(#xAA 1 2))
   'TAY (hash 'imp '(#xA8 1 2))
   'TXA (hash 'imp '(#x8A 1 2))
   'TYA (hash 'imp '(#x98 1 2))
   'TSX (hash 'imp '(#xBA 1 2))
   'TXS (hash 'imp '(#x9A 1 2))
   'PHA (hash 'imp '(#x48 1 3))
   'PHP (hash 'imp '(#x08 1 3))
   'PLA (hash 'imp '(#x68 1 4))
   'PLP (hash 'imp '(#x28 1 4))

   ;; Logical & Bitwise
   'AND (hash 'imm '(#x29 2 2) 'zp '(#x25 2 3) 'zpx '(#x35 2 4)
              'abs '(#x2D 3 4) 'absx '(#x3D 3 4) 'absy '(#x39 3 4)
              'indx '(#x21 2 6) 'indy '(#x31 2 5))
   'EOR (hash 'imm '(#x49 2 2) 'zp '(#x45 2 3) 'zpx '(#x55 2 4)
              'abs '(#x4D 3 4) 'absx '(#x5D 3 4) 'absy '(#x59 3 4)
              'indx '(#x41 2 6) 'indy '(#x51 2 5))
   'ORA (hash 'imm '(#x09 2 2) 'zp '(#x05 2 3) 'zpx '(#x15 2 4)
              'abs '(#x0D 3 4) 'absx '(#x1D 3 4) 'absy '(#x19 3 4)
              'indx '(#x01 2 6) 'indy '(#x11 2 5))
   'BIT (hash 'zp '(#x24 2 3) 'abs '(#x2C 3 4))

   ;; Arithmetic & Compare
   'ADC (hash 'imm '(#x69 2 2) 'zp '(#x65 2 3) 'zpx '(#x75 2 4)
              'abs '(#x6D 3 4) 'absx '(#x7D 3 4) 'absy '(#x79 3 4)
              'indx '(#x61 2 6) 'indy '(#x71 2 5))
   'SBC (hash 'imm '(#xE9 2 2) 'zp '(#xE5 2 3) 'zpx '(#xF5 2 4)
              'abs '(#xED 3 4) 'absx '(#xFD 3 4) 'absy '(#xF9 3 4)
              'indx '(#xE1 2 6) 'indy '(#xF1 2 5))
   'CMP (hash 'imm '(#xC9 2 2) 'zp '(#xC5 2 3) 'zpx '(#xD5 2 4)
              'abs '(#xCD 3 4) 'absx '(#xDD 3 4) 'absy '(#xD9 3 4)
              'indx '(#xC1 2 6) 'indy '(#xD1 2 5))
   'CPX (hash 'imm '(#xE0 2 2) 'zp '(#xE4 2 3) 'abs '(#xEC 3 4))
   'CPY (hash 'imm '(#xC0 2 2) 'zp '(#xC4 2 3) 'abs '(#xCC 3 4))

   ;; Increment / Decrement
   'INC (hash 'zp '(#xE6 2 5) 'zpx '(#xF6 2 6) 'abs '(#xEE 3 6) 'absx '(#xFE 3 7))
   'INX (hash 'imp '(#xE8 1 2))
   'INY (hash 'imp '(#xC8 1 2))
   'DEC (hash 'zp '(#xC6 2 5) 'zpx '(#xD6 2 6) 'abs '(#xCE 3 6) 'absx '(#xDE 3 7))
   'DEX (hash 'imp '(#xCA 1 2))
   'DEY (hash 'imp '(#x88 1 2))

   ;; Shifts & Rotates
   'ASL (hash 'acc '(#x0A 1 2) 'zp '(#x06 2 5) 'zpx '(#x16 2 6)
              'abs '(#x0E 3 6) 'absx '(#x1E 3 7))
   'LSR (hash 'acc '(#x4A 1 2) 'zp '(#x46 2 5) 'zpx '(#x56 2 6)
              'abs '(#x4E 3 6) 'absx '(#x5E 3 7))
   'ROL (hash 'acc '(#x2A 1 2) 'zp '(#x26 2 5) 'zpx '(#x36 2 6)
              'abs '(#x2E 3 6) 'absx '(#x3E 3 7))
   'ROR (hash 'acc '(#x6A 1 2) 'zp '(#x66 2 5) 'zpx '(#x76 2 6)
              'abs '(#x6E 3 6) 'absx '(#x7E 3 7))

   ;; Jumps, Calls & Returns
   'JMP (hash 'abs '(#x4C 3 3) 'ind '(#x6C 3 5))
   'JSR (hash 'abs '(#x20 3 6))
   'RTS (hash 'imp '(#x60 1 6))
   'RTI (hash 'imp '(#x40 1 6))

   ;; Conditional Branches
   'BCC (hash 'rel '(#x90 2 2))
   'BCS (hash 'rel '(#xB0 2 2))
   'BEQ (hash 'rel '(#xF0 2 2))
   'BMI (hash 'rel '(#x30 2 2))
   'BNE (hash 'rel '(#xD0 2 2))
   'BPL (hash 'rel '(#x10 2 2))
   'BVC (hash 'rel '(#x50 2 2))
   'BVS (hash 'rel '(#x70 2 2))

   ;; Flags & System
   'CLC (hash 'imp '(#x18 1 2))
   'CLD (hash 'imp '(#xD8 1 2))
   'CLI (hash 'imp '(#x58 1 2))
   'CLV (hash 'imp '(#xB8 1 2))
   'SEC (hash 'imp '(#x38 1 2))
   'SED (hash 'imp '(#xF8 1 2))
   'SEI (hash 'imp '(#x78 1 2))
   'BRK (hash 'imp '(#x00 1 7))
   'NOP (hash 'imp '(#xEA 1 2))))

(define BRANCH-MNEMONICS
  '(BCC BCS BEQ BMI BNE BPL BVC BVS))

;; ============================================================================
;; 2. Two-Pass MOS 6502 Assembler
;; ============================================================================
;; S-expression instruction syntax:
;;   (label 'loop)
;;   (LDA #:imm #x00) | (LDA #:zp #x10) | (LDA #:abs 'table) | (LDA #:absx 'table)
;;   (STA #:abs #x2007) | (BNE 'loop) | (JSR 'sub) | (RTS) | (INX)
;;   (.byte b1 b2 ...) | (.word w1 w2 ...) | (.align 256)

(struct asm-result
  (bytes          ; bytevector of assembled machine code
   origin         ; starting address (e.g., #x8000)
   labels         ; hash: symbol -> 16-bit address
   static-cycles  ; sum of static instruction cycles
   page-crossings ; number of branch/table page crossings detected
   )
  #:transparent)

(define (eval-asm-expr expr labels [allow-unresolved? #f])
  (match expr
    [(? exact-integer? n) n]
    [(? symbol? sym)
     (cond
       [(hash-has-key? labels sym) (hash-ref labels sym)]
       [allow-unresolved? #x8000]
       [else (error 'eval-asm-expr "Undefined 6502 label: ~a" sym)])]
    [`(lo ,e)
     (bitwise-and #xFF (eval-asm-expr e labels allow-unresolved?))]
    [`(hi ,e)
     (bitwise-and #xFF (arithmetic-shift (eval-asm-expr e labels allow-unresolved?) -8))]
    [`(+ ,a ,b)
     (+ (eval-asm-expr a labels allow-unresolved?)
        (eval-asm-expr b labels allow-unresolved?))]
    [`(- ,a ,b)
     (- (eval-asm-expr a labels allow-unresolved?)
        (eval-asm-expr b labels allow-unresolved?))]
    [else
     (error 'eval-asm-expr "Unsupported assembler expression: ~v" expr)]))

;; Parse an instruction form into (values mnemonic mode operand-expr)
(define (parse-inst form)
  (match form
    [`(,mnem)
     #:when (hash-has-key? OPCODE-TABLE mnem)
     (define m-table (hash-ref OPCODE-TABLE mnem))
     (if (hash-has-key? m-table 'imp)
         (values mnem 'imp #f)
         (values mnem 'acc #f))]
    [`(,mnem ,target)
     #:when (memq mnem BRANCH-MNEMONICS)
     (values mnem 'rel target)]
    [`(,mnem ,target)
     #:when (memq mnem '(JMP JSR))
     (values mnem 'abs target)]
    [`(,mnem ,kw ,op)
     #:when (and (hash-has-key? OPCODE-TABLE mnem) (keyword? kw))
     (define mode (string->symbol (keyword->string kw)))
     (values mnem mode op)]
    [`(,mnem ,mode-sym ,op)
     #:when (and (hash-has-key? OPCODE-TABLE mnem) (symbol? mode-sym))
     (values mnem mode-sym op)]
    [else
     (error 'parse-inst "Unrecognized 6502 instruction form: ~v" form)]))

(define (assemble-6502 forms #:origin [origin #x8000])
  ;; Pass 1: Compute label addresses and instruction sizes
  (define labels (make-hash))
  (define pc origin)

  (for ([form (in-list forms)])
    (match form
      [`(label ,sym)
       (hash-set! labels sym pc)]
      [`(.equ ,sym ,val)
       (hash-set! labels sym (eval-asm-expr val labels #f))]
      [`(.byte . ,vals)
       (set! pc (+ pc (length vals)))]
      [`(.word . ,vals)
       (set! pc (+ pc (* 2 (length vals))))]
      [`(.align ,boundary)
       (define rem (modulo pc boundary))
       (unless (zero? rem)
         (set! pc (+ pc (- boundary rem))))]
      [else
       (define-values (mnem mode _op) (parse-inst form))
       (define m-table (hash-ref OPCODE-TABLE mnem))
       (unless (hash-has-key? m-table mode)
         (error 'assemble-6502 "Invalid addressing mode ~a for ~a in ~v" mode mnem form))
       (define info (hash-ref m-table mode))
       (set! pc (+ pc (second info)))]))

  ;; Pass 2: Emit machine code bytes, compute static cycles & page crossings
  (define out-bytes '())
  (define cur-pc origin)
  (define total-cycles 0)
  (define crossings 0)

  (define (emit-u8! b)
    (set! out-bytes (cons (bitwise-and #xFF b) out-bytes))
    (set! cur-pc (add1 cur-pc)))

  (define (emit-u16! w)
    (emit-u8! (bitwise-and #xFF w))
    (emit-u8! (bitwise-and #xFF (arithmetic-shift w -8))))

  (for ([form (in-list forms)])
    (match form
      [`(label ,_sym) (void)]
      [`(.equ ,_sym ,_val) (void)]
      [`(.byte . ,vals)
       (for ([v (in-list vals)])
         (emit-u8! (eval-asm-expr v labels #f)))]
      [`(.word . ,vals)
       (for ([v (in-list vals)])
         (emit-u16! (eval-asm-expr v labels #f)))]
      [`(.align ,boundary)
       (define rem (modulo cur-pc boundary))
       (unless (zero? rem)
         (for ([_ (in-range (- boundary rem))])
           (emit-u8! #xEA)))] ; Fill alignment padding with NOP ($EA)
      [else
       (define-values (mnem mode op) (parse-inst form))
       (define info (hash-ref (hash-ref OPCODE-TABLE mnem) mode))
       (define opcode (first info))
       (define len    (second info))
       (define cyc    (third info))
       (set! total-cycles (+ total-cycles cyc))
       (emit-u8! opcode)
       (case len
         [(1) (void)]
         [(2)
          (if (eq? mode 'rel)
              (let* ([target-addr (eval-asm-expr op labels #f)]
                     [next-pc     (add1 cur-pc)]
                     [offset      (- target-addr next-pc)])
                (when (or (< offset -128) (> offset 127))
                  (error 'assemble-6502
                         "Relative branch (~a ~a) out of range: offset ~a at PC $~x"
                         mnem op offset (sub1 cur-pc)))
                (unless (= (quotient next-pc 256) (quotient target-addr 256))
                  (set! crossings (add1 crossings)))
                (emit-u8! (bitwise-and #xFF offset)))
              (emit-u8! (eval-asm-expr op labels #f)))]
         [(3)
          (emit-u16! (eval-asm-expr op labels #f))])]))

  (asm-result
   (list->bytes (reverse out-bytes))
   origin
   labels
   total-cycles
   crossings))

;; Emit readable ca65-compatible assembly source
(define (emit-ca65-asm forms #:origin [origin #x8000])
  (define lines
    (list
     ";; ============================================================================"
     ";; Generated by #lang boba-nes Graded MOS 6502 / Ricoh 2C02 Compiler"
     ";; ============================================================================"
     (format ".org $~a" (~r origin #:base 16 #:min-width 4 #:pad-string "0"))))

  (define (fmt-val v)
    (match v
      [(? exact-integer? n)
       (if (< n 256)
           (format "$~a" (~r (bitwise-and #xFF n) #:base 16 #:min-width 2 #:pad-string "0"))
           (format "$~a" (~r (bitwise-and #xFFFF n) #:base 16 #:min-width 4 #:pad-string "0")))]
      [(? symbol? s) (symbol->string s)]
      [`(lo ,e) (format "<(~a)" (fmt-val e))]
      [`(hi ,e) (format ">(~a)" (fmt-val e))]
      [`(+ ,a ,b) (format "(~a + ~a)" (fmt-val a) (fmt-val b))]
      [`(- ,a ,b) (format "(~a - ~a)" (fmt-val a) (fmt-val b))]
      [else (format "~a" v)]))

  (define body-lines
    (for/list ([form (in-list forms)])
      (match form
        [`(label ,sym)
         (format "~a:" sym)]
        [`(.equ ,sym ,val)
         (format "~a = ~a" sym (fmt-val val))]
        [`(.byte . ,vals)
         (format "  .byte ~a" (string-join (map fmt-val vals) ", "))]
        [`(.word . ,vals)
         (format "  .word ~a" (string-join (map fmt-val vals) ", "))]
        [`(.align ,b)
         (format "  .align ~a" b)]
        [else
         (define-values (mnem mode op) (parse-inst form))
         (case mode
           [(imp)  (format "  ~a" mnem)]
           [(acc)  (format "  ~a A" mnem)]
           [(imm)  (format "  ~a #~a" mnem (fmt-val op))]
           [(zp)   (format "  ~a ~a" mnem (fmt-val op))]
           [(zpx)  (format "  ~a ~a, X" mnem (fmt-val op))]
           [(zpy)  (format "  ~a ~a, Y" mnem (fmt-val op))]
           [(abs)  (format "  ~a ~a" mnem (fmt-val op))]
           [(absx) (format "  ~a ~a, X" mnem (fmt-val op))]
           [(absy) (format "  ~a ~a, Y" mnem (fmt-val op))]
           [(ind)  (format "  ~a (~a)" mnem (fmt-val op))]
           [(indx) (format "  ~a (~a, X)" mnem (fmt-val op))]
           [(indy) (format "  ~a (~a), Y" mnem (fmt-val op))]
           [(rel)  (format "  ~a ~a" mnem (fmt-val op))])])))

  (string-join (append lines body-lines (list "")) "\n"))

;; ============================================================================
;; 3. 2bpp NES CHR-ROM Tile Compiler & iNES 1.0 (.nes) ROM Linker
;; ============================================================================
;; Each 8x8 NES CHR tile is 16 bytes:
;;   - Bytes 0..7  : Bitplane 0 (bit 0 of each pixel's 2-bit color index 0..3)
;;   - Bytes 8..15 : Bitplane 1 (bit 1 of each pixel's 2-bit color index 0..3)
;; A tile specification is a list of 8 strings (each 8 chars from '(#\. #\1 #\2 #\3)
;; or #\'0..#\'3) or a list of 8 lists of 8 integers in 0..3.

(define (char->pixel ch)
  (case ch
    [(#\. #\space #\0) 0]
    [(#\1) 1]
    [(#\2) 2]
    [(#\3 #\#) 3]
    [else 0]))

(define (compile-chr-tile rows)
  (unless (= (length rows) 8)
    (error 'compile-chr-tile "CHR tile must have 8 rows, got ~a" (length rows)))
  (define plane0 (make-bytes 8 0))
  (define plane1 (make-bytes 8 0))
  (for ([row (in-list rows)]
        [y   (in-range 8)])
    (define pixels
      (cond
        [(string? row) (map char->pixel (string->list row))]
        [(list? row)   row]
        [else (error 'compile-chr-tile "Invalid row: ~v" row)]))
    (define b0 0)
    (define b1 0)
    (for ([px (in-list pixels)]
          [x  (in-range 8)])
      (define shift (- 7 x))
      (set! b0 (bitwise-ior b0 (arithmetic-shift (bitwise-and px 1) shift)))
      (set! b1 (bitwise-ior b1 (arithmetic-shift (bitwise-and (arithmetic-shift px -1) 1) shift))))
    (bytes-set! plane0 y b0)
    (bytes-set! plane1 y b1))
  (bytes-append plane0 plane1))

;; Build a complete 8,192-byte (512-tile) CHR-ROM bank from a hash or alist of (tile-id . rows)
(define (build-chr-rom tile-alist)
  (define chr (make-bytes 8192 0))
  (for ([entry (in-list tile-alist)])
    (define tile-id (car entry))
    (define tile-bytes
      (if (bytes? (cdr entry))
          (cdr entry)
          (compile-chr-tile (cdr entry))))
    (define offset (* tile-id 16))
    (when (and (>= offset 0) (<= (+ offset 16) 8192))
      (bytes-copy! chr offset tile-bytes 0 16)))
  chr)

;; Build an iNES 1.0 (.nes) binary ROM image:
;; - 16-byte iNES header:
;;     Bytes 0..3 : "NES\x1A" (#x4E #x45 #x53 #x1A)
;;     Byte 4     : Number of 16 KB PRG-ROM banks (2 = 32 KB NROM-256)
;;     Byte 5     : Number of 8 KB CHR-ROM banks (1 = 8 KB CHR-ROM)
;;     Byte 6     : Flags 6 (Mapper low nibble + vertical/horizontal mirroring)
;;     Byte 7..15 : Flags 7..15 (0)
;; - 32,768-byte PRG-ROM ($8000-$FFFF) with vectors at $FFFA-$FFFF:
;;     $FFFA-$FFFB : NMI vector
;;     $FFFC-$FFFD : RESET vector
;;     $FFFE-$FFFF : IRQ/BRK vector
;; - 8,192-byte CHR-ROM ($0000-$1FFF)
(define (build-ines-rom asm-res chr-rom-bytes
                        #:nmi-label   [nmi-label 'nmi_handler]
                        #:reset-label [reset-label 'reset_handler]
                        #:irq-label   [irq-label 'irq_handler]
                        #:mirroring   [mirroring 'vertical])
  (define header (make-bytes 16 0))
  (bytes-set! header 0 #x4E) ; 'N'
  (bytes-set! header 1 #x45) ; 'E'
  (bytes-set! header 2 #x53) ; 'S'
  (bytes-set! header 3 #x1A) ; EOF
  (bytes-set! header 4 2)    ; 2 x 16 KB = 32 KB PRG-ROM (NROM-256)
  (bytes-set! header 5 1)    ; 1 x 8 KB = 8 KB CHR-ROM
  (bytes-set! header 6 (if (eq? mirroring 'vertical) 1 0))

  (define prg (make-bytes 32768 #xFF))
  (define code (asm-result-bytes asm-res))
  (define org  (asm-result-origin asm-res))
  (define offset (- org #x8000))
  (bytes-copy! prg offset code 0 (min (bytes-length code) (- 32768 offset)))

  ;; Patch 6502 hardware vectors at $FFFA, $FFFC, $FFFE (offsets #x7FFA, #x7FFC, #x7FFE)
  (define labels (asm-result-labels asm-res))
  (define nmi-addr   (hash-ref labels nmi-label   #x8000))
  (define reset-addr (hash-ref labels reset-label #x8000))
  (define irq-addr   (hash-ref labels irq-label   reset-addr))

  (define (put-u16! off val)
    (bytes-set! prg off       (bitwise-and #xFF val))
    (bytes-set! prg (add1 off) (bitwise-and #xFF (arithmetic-shift val -8))))

  (put-u16! #x7FFA nmi-addr)
  (put-u16! #x7FFC reset-addr)
  (put-u16! #x7FFE irq-addr)

  (define chr
    (if (= (bytes-length chr-rom-bytes) 8192)
        chr-rom-bytes
        (let ([b (make-bytes 8192 0)])
          (bytes-copy! b 0 chr-rom-bytes 0 (min 8192 (bytes-length chr-rom-bytes)))
          b)))

  (bytes-append header prg chr))

(define (write-ines-rom-file! path rom-bytes)
  (call-with-output-file path
    (lambda (out)
      (write-bytes rom-bytes out))
    #:exists 'truncate/replace))

;; ============================================================================
;; 4. Cycle-Accurate MOS 6502 + Ricoh 2C02 PPU/OAM/Joypad Verification Emulator
;; ============================================================================
;; Executes real iNES (.nes) binary ROMs to verify game physics, rule engines,
;; VBlank cycle budgets, OAM DMA transfers, and PPU scroll latch discipline.

(define BTN-A      #x01)
(define BTN-B      #x02)
(define BTN-SELECT #x04)
(define BTN-START  #x08)
(define BTN-UP     #x10)
(define BTN-DOWN   #x20)
(define BTN-LEFT   #x40)
(define BTN-RIGHT  #x80)

(struct nes-emulator
  ([a          #:mutable] ; 8-bit Accumulator
   [x          #:mutable] ; 8-bit Index X
   [y          #:mutable] ; 8-bit Index Y
   [sp         #:mutable] ; 8-bit Stack Pointer ($0100 + sp)
   [pc         #:mutable] ; 16-bit Program Counter
   [status     #:mutable] ; P flags: N(7) V(6) -(5) B(4) D(3) I(2) Z(1) C(0)
   [cycles     #:mutable] ; Total elapsed CPU cycles
   ram                    ; 2048-byte internal Work RAM ($0000-$07FF)
   prg-rom                ; 32768-byte PRG-ROM ($8000-$FFFF)
   chr-rom                ; 8192-byte CHR-ROM ($0000-$1FFF)
   vram                   ; 4096-byte PPU Nametable VRAM ($2000-$2FFF)
   palette                ; 32-byte PPU Palette RAM ($3F00-$3F1F)
   oam                    ; 256-byte Hardware OAM (64 sprites x 4 bytes)
   apu-regs               ; 24-byte 2A03 APU registers ($4000-$4017)
   ;; Ricoh 2C02 internal latches
   [ppu-ctrl   #:mutable] ; $2000
   [ppu-mask   #:mutable] ; $2001
   [ppu-status #:mutable] ; $2002 (bit 7 = VBlank flag)
   [oam-addr   #:mutable] ; $2003
   [ppu-latch-w #:mutable] ; Shared 1st/2nd write toggle (0 or 1)
   [ppu-vram-addr #:mutable] ; 15-bit v register ($2006)
   [ppu-scroll-x #:mutable]
   [ppu-scroll-y #:mutable]
   [ppu-read-buf #:mutable]
   [ppu-tainted? #:mutable] ; #t if $2006/$2007 written without $2005 scroll restore
   ;; Controller 1 serial shift state
   [joypad1-buttons #:mutable]
   [joypad1-shift   #:mutable]
   [joypad1-strobe  #:mutable])
  #:transparent)

(define (make-nes-emulator-from-rom rom-bytes)
  (unless (and (>= (bytes-length rom-bytes) (+ 16 32768 8192))
               (= (bytes-ref rom-bytes 0) #x4E)
               (= (bytes-ref rom-bytes 1) #x45)
               (= (bytes-ref rom-bytes 2) #x53)
               (= (bytes-ref rom-bytes 3) #x1A))
    (error 'make-nes-emulator-from-rom "Invalid iNES 1.0 ROM header"))
  (define prg (subbytes rom-bytes 16 (+ 16 32768)))
  (define chr (subbytes rom-bytes (+ 16 32768) (+ 16 32768 8192)))
  (define emu
    (nes-emulator
     0 0 0 #xFD #x8000 #x24 0
     (make-bytes 2048 0)
     prg
     chr
     (make-bytes 4096 0)
     (make-bytes 32 0)
     (make-bytes 256 #xFF)
     (make-bytes 24 0)
     0 0 #x80 0 0 0 0 0 0 #f
     0 0 0))
  (nes-reset! emu)
  emu)

;; Memory bus read/write with 2C02 PPU & 2A03 APU/DMA/Joypad MMIO
(define (bus-read emu addr)
  (define a (bitwise-and #xFFFF addr))
  (cond
    [(< a #x2000)
     (bytes-ref (nes-emulator-ram emu) (bitwise-and a #x07FF))]
    [(< a #x4000)
     (define reg (+ #x2000 (bitwise-and a #x0007)))
     (case reg
       [(#x2002)
        ;; Reading $2002 returns status and clears bit 7 (VBlank) AND resets w latch to 0!
        (define st (nes-emulator-ppu-status emu))
        (set-nes-emulator-ppu-status! emu (bitwise-and st #x7F))
        (set-nes-emulator-ppu-latch-w! emu 0)
        st]
       [(#x2004)
        (bytes-ref (nes-emulator-oam emu) (nes-emulator-oam-addr emu))]
       [(#x2007)
        (define v (bitwise-and #x3FFF (nes-emulator-ppu-vram-addr emu)))
        (define inc (if (bitwise-bit-set? (nes-emulator-ppu-ctrl emu) 2) 32 1))
        (set-nes-emulator-ppu-vram-addr! emu (bitwise-and #x3FFF (+ v inc)))
        (cond
          [(< v #x2000) (bytes-ref (nes-emulator-chr-rom emu) v)]
          [(< v #x3F00)
           (define prev (nes-emulator-ppu-read-buf emu))
           (set-nes-emulator-ppu-read-buf!
            emu (bytes-ref (nes-emulator-vram emu) (bitwise-and v #x0FFF)))
           prev]
          [else
           (bytes-ref (nes-emulator-palette emu) (bitwise-and v #x1F))])]
       [else 0])]
    [(= a #x4016)
     ;; Controller 1 serial read: returns bit 0 of shift register and shifts right
     (when (= (bitwise-and (nes-emulator-joypad1-strobe emu) 1) 1)
       (set-nes-emulator-joypad1-shift! emu (nes-emulator-joypad1-buttons emu)))
     (define bit (bitwise-and (nes-emulator-joypad1-shift emu) 1))
     (set-nes-emulator-joypad1-shift!
      emu (arithmetic-shift (nes-emulator-joypad1-shift emu) -1))
     (bitwise-ior #x40 bit)]
    [(>= a #x8000)
     (bytes-ref (nes-emulator-prg-rom emu) (- a #x8000))]
    [else 0]))

(define (bus-write! emu addr val)
  (define a (bitwise-and #xFFFF addr))
  (define v (bitwise-and #xFF val))
  (cond
    [(< a #x2000)
     (bytes-set! (nes-emulator-ram emu) (bitwise-and a #x07FF) v)]
    [(< a #x4000)
     (define reg (+ #x2000 (bitwise-and a #x0007)))
     (case reg
       [(#x2000)
        (set-nes-emulator-ppu-ctrl! emu v)]
       [(#x2001)
        (set-nes-emulator-ppu-mask! emu v)]
       [(#x2003)
        (set-nes-emulator-oam-addr! emu v)]
       [(#x2004)
        (define oa (nes-emulator-oam-addr emu))
        (bytes-set! (nes-emulator-oam emu) oa v)
        (set-nes-emulator-oam-addr! emu (bitwise-and #xFF (add1 oa)))]
       [(#x2005)
        (if (zero? (nes-emulator-ppu-latch-w emu))
            (begin
              (set-nes-emulator-ppu-scroll-x! emu v)
              (set-nes-emulator-ppu-latch-w! emu 1))
            (begin
              (set-nes-emulator-ppu-scroll-y! emu v)
              (set-nes-emulator-ppu-latch-w! emu 0)
              ;; Completing both $2005 writes after $2002 reset discharges PpuTaint!
              (set-nes-emulator-ppu-tainted?! emu #f)))]
       [(#x2006)
        (if (zero? (nes-emulator-ppu-latch-w emu))
            (begin
              (set-nes-emulator-ppu-vram-addr!
               emu
               (bitwise-ior (arithmetic-shift (bitwise-and v #x3F) 8)
                            (bitwise-and (nes-emulator-ppu-vram-addr emu) #x00FF)))
              (set-nes-emulator-ppu-latch-w! emu 1)
              (set-nes-emulator-ppu-tainted?! emu #t))
            (begin
              (set-nes-emulator-ppu-vram-addr!
               emu
               (bitwise-ior (bitwise-and (nes-emulator-ppu-vram-addr emu) #x3F00)
                            v))
              (set-nes-emulator-ppu-latch-w! emu 0)
              (set-nes-emulator-ppu-tainted?! emu #t)))]
       [(#x2007)
        (define va (bitwise-and #x3FFF (nes-emulator-ppu-vram-addr emu)))
        (cond
          [(and (>= va #x2000) (< va #x3F00))
           (bytes-set! (nes-emulator-vram emu) (bitwise-and va #x0FFF) v)]
          [(>= va #x3F00)
           (define pa (bitwise-and va #x1F))
           ;; Mirror universal backdrop colors $3F10/$3F14/$3F18/$3F1C to $3F00..$3F0C
           (define eff-pa
             (if (and (>= pa #x10) (zero? (modulo pa 4)))
                 (- pa #x10)
                 pa))
           (bytes-set! (nes-emulator-palette emu) eff-pa v)
           (bytes-set! (nes-emulator-palette emu) pa v)])
        (define inc (if (bitwise-bit-set? (nes-emulator-ppu-ctrl emu) 2) 32 1))
        (set-nes-emulator-ppu-vram-addr! emu (bitwise-and #x3FFF (+ va inc)))
        (set-nes-emulator-ppu-tainted?! emu #t)])]
    [(= a #x4014)
     ;; $4014 OAMDMA: Copy 256 bytes from page ($XX00-$XXFF) to OAM and charge 514 cycles!
     (define base (arithmetic-shift v 8))
     (for ([i (in-range 256)])
       (bytes-set! (nes-emulator-oam emu) i (bus-read emu (+ base i))))
     (set-nes-emulator-cycles! emu (+ (nes-emulator-cycles emu) 514))]
    [(= a #x4016)
     (set-nes-emulator-joypad1-strobe! emu v)
     (when (= (bitwise-and v 1) 1)
       (set-nes-emulator-joypad1-shift! emu (nes-emulator-joypad1-buttons emu)))]
    [(and (>= a #x4000) (<= a #x4017))
     (bytes-set! (nes-emulator-apu-regs emu) (- a #x4000) v)]
    [else (void)]))

(define (bus-read-u16 emu addr)
  (bitwise-ior (bus-read emu addr)
               (arithmetic-shift (bus-read emu (add1 addr)) 8)))

;; Reset CPU to vector at $FFFC
(define (nes-reset! emu)
  (set-nes-emulator-sp! emu #xFD)
  (set-nes-emulator-status! emu #x24)
  (set-nes-emulator-pc! emu (bus-read-u16 emu #xFFFC))
  (set-nes-emulator-cycles! emu 0))

(define (nes-set-joypad1! emu mask)
  (set-nes-emulator-joypad1-buttons! emu (bitwise-and #xFF mask)))

(define (nes-zp-ref emu zp-addr)
  (bytes-ref (nes-emulator-ram emu) (bitwise-and #xFF zp-addr)))

(define (nes-zp-set! emu zp-addr val)
  (bytes-set! (nes-emulator-ram emu) (bitwise-and #xFF zp-addr) (bitwise-and #xFF val)))

(define (nes-ram-ref emu addr)
  (bytes-ref (nes-emulator-ram emu) (bitwise-and #x07FF addr)))

(define (nes-ram-set! emu addr val)
  (bytes-set! (nes-emulator-ram emu) (bitwise-and #x07FF addr) (bitwise-and #xFF val)))

(define (nes-vram-ref emu vram-addr)
  (bytes-ref (nes-emulator-vram emu) (bitwise-and #x0FFF vram-addr)))

(define (nes-palette-ref emu idx)
  (bytes-ref (nes-emulator-palette emu) (bitwise-and #x1F idx)))

(define (nes-oam-sprite-ref emu slot)
  (define base (* 4 (bitwise-and #x3F slot)))
  (define oam (nes-emulator-oam emu))
  (hasheq 'y    (bytes-ref oam base)
          'tile (bytes-ref oam (+ base 1))
          'attr (bytes-ref oam (+ base 2))
          'x    (bytes-ref oam (+ base 3))))

;; Status flag helpers (C=0, Z=1, I=2, D=3, B=4, U=5, V=6, N=7)
(define (flag-set? emu bit)
  (bitwise-bit-set? (nes-emulator-status emu) bit))

(define (set-flag! emu bit on?)
  (define s (nes-emulator-status emu))
  (set-nes-emulator-status!
   emu
   (if on?
       (bitwise-ior s (arithmetic-shift 1 bit))
       (bitwise-and s (bitwise-not (arithmetic-shift 1 bit))))))

(define (update-nz! emu val)
  (define v (bitwise-and #xFF val))
  (set-flag! emu 1 (zero? v))
  (set-flag! emu 7 (bitwise-bit-set? v 7))
  v)

(define (push-u8! emu val)
  (define sp (nes-emulator-sp emu))
  (bus-write! emu (+ #x0100 sp) val)
  (set-nes-emulator-sp! emu (bitwise-and #xFF (sub1 sp))))

(define (pull-u8! emu)
  (define sp (bitwise-and #xFF (add1 (nes-emulator-sp emu))))
  (set-nes-emulator-sp! emu sp)
  (bus-read emu (+ #x0100 sp)))

(define (push-u16! emu val)
  (push-u8! emu (bitwise-and #xFF (arithmetic-shift val -8)))
  (push-u8! emu (bitwise-and #xFF val)))

(define (pull-u16! emu)
  (define lo (pull-u8! emu))
  (define hi (pull-u8! emu))
  (bitwise-ior lo (arithmetic-shift hi 8)))

;; Build reverse lookup table from opcode byte -> (list mnem mode len cyc)
(define REVERSE-OPCODE-VEC (make-vector 256 #f))
(for ([(mnem m-hash) (in-hash OPCODE-TABLE)])
  (for ([(mode info) (in-hash m-hash)])
    (vector-set! REVERSE-OPCODE-VEC
                 (first info)
                 (list mnem mode (second info) (third info)))))

;; Resolve effective address for an operand mode at current PC+1
(define (resolve-operand-addr emu mode pc)
  (case mode
    [(imm)  (+ pc 1)]
    [(zp)   (bus-read emu (+ pc 1))]
    [(zpx)  (bitwise-and #xFF (+ (bus-read emu (+ pc 1)) (nes-emulator-x emu)))]
    [(zpy)  (bitwise-and #xFF (+ (bus-read emu (+ pc 1)) (nes-emulator-y emu)))]
    [(abs)  (bus-read-u16 emu (+ pc 1))]
    [(absx) (bitwise-and #xFFFF (+ (bus-read-u16 emu (+ pc 1)) (nes-emulator-x emu)))]
    [(absy) (bitwise-and #xFFFF (+ (bus-read-u16 emu (+ pc 1)) (nes-emulator-y emu)))]
    [(ind)
     (define ptr (bus-read-u16 emu (+ pc 1)))
     ;; Authentic 6502 page-wrap bug on JMP ($xxFF)
     (define hi-addr
       (if (= (bitwise-and ptr #xFF) #xFF)
           (bitwise-and ptr #xFF00)
           (add1 ptr)))
     (bitwise-ior (bus-read emu ptr)
                  (arithmetic-shift (bus-read emu hi-addr) 8))]
    [(indx)
     (define zp-ptr (bitwise-and #xFF (+ (bus-read emu (+ pc 1)) (nes-emulator-x emu))))
     (bitwise-ior (bus-read emu zp-ptr)
                  (arithmetic-shift (bus-read emu (bitwise-and #xFF (add1 zp-ptr))) 8))]
    [(indy)
     (define zp-ptr (bus-read emu (+ pc 1)))
     (define base (bitwise-ior (bus-read emu zp-ptr)
                               (arithmetic-shift (bus-read emu (bitwise-and #xFF (add1 zp-ptr))) 8)))
     (bitwise-and #xFFFF (+ base (nes-emulator-y emu)))]
    [(rel)
     (define raw (bus-read emu (+ pc 1)))
     (define signed (if (>= raw 128) (- raw 256) raw))
     (bitwise-and #xFFFF (+ pc 2 signed))]
    [else 0]))

;; Execute a single MOS 6502 instruction and return the mnemonic executed
(define (nes-step! emu)
  (define pc (nes-emulator-pc emu))
  (define op (bus-read emu pc))
  (define decoded (vector-ref REVERSE-OPCODE-VEC op))
  (unless decoded
    (error 'nes-step! "Illegal/unimplemented 6502 opcode $~x at PC $~x" op pc))

  (match-define (list mnem mode len base-cyc) decoded)
  (define eff-addr (resolve-operand-addr emu mode pc))
  (set-nes-emulator-pc! emu (bitwise-and #xFFFF (+ pc len)))
  (set-nes-emulator-cycles! emu (+ (nes-emulator-cycles emu) base-cyc))

  (define (take-branch!)
    (set-nes-emulator-cycles! emu (add1 (nes-emulator-cycles emu)))
    (set-nes-emulator-pc! emu eff-addr))

  (define (do-cmp reg-val mem-val)
    (define diff (- reg-val mem-val))
    (set-flag! emu 0 (>= reg-val mem-val))
    (update-nz! emu diff))

  (case mnem
    ;; Loads & Stores
    [(LDA) (set-nes-emulator-a! emu (update-nz! emu (bus-read emu eff-addr)))]
    [(LDX) (set-nes-emulator-x! emu (update-nz! emu (bus-read emu eff-addr)))]
    [(LDY) (set-nes-emulator-y! emu (update-nz! emu (bus-read emu eff-addr)))]
    [(STA) (bus-write! emu eff-addr (nes-emulator-a emu))]
    [(STX) (bus-write! emu eff-addr (nes-emulator-x emu))]
    [(STY) (bus-write! emu eff-addr (nes-emulator-y emu))]

    ;; Transfers
    [(TAX) (set-nes-emulator-x! emu (update-nz! emu (nes-emulator-a emu)))]
    [(TAY) (set-nes-emulator-y! emu (update-nz! emu (nes-emulator-a emu)))]
    [(TXA) (set-nes-emulator-a! emu (update-nz! emu (nes-emulator-x emu)))]
    [(TYA) (set-nes-emulator-a! emu (update-nz! emu (nes-emulator-y emu)))]
    [(TSX) (set-nes-emulator-x! emu (update-nz! emu (nes-emulator-sp emu)))]
    [(TXS) (set-nes-emulator-sp! emu (nes-emulator-x emu))]

    ;; Stack
    [(PHA) (push-u8! emu (nes-emulator-a emu))]
    [(PHP) (push-u8! emu (bitwise-ior (nes-emulator-status emu) #x30))]
    [(PLA) (set-nes-emulator-a! emu (update-nz! emu (pull-u8! emu)))]
    [(PLP) (set-nes-emulator-status!
            emu (bitwise-ior (bitwise-and (pull-u8! emu) #xEF) #x20))]

    ;; Bitwise
    [(AND) (set-nes-emulator-a!
            emu (update-nz! emu (bitwise-and (nes-emulator-a emu) (bus-read emu eff-addr))))]
    [(EOR) (set-nes-emulator-a!
            emu (update-nz! emu (bitwise-xor (nes-emulator-a emu) (bus-read emu eff-addr))))]
    [(ORA) (set-nes-emulator-a!
            emu (update-nz! emu (bitwise-ior (nes-emulator-a emu) (bus-read emu eff-addr))))]
    [(BIT)
     (define m (bus-read emu eff-addr))
     (set-flag! emu 1 (zero? (bitwise-and (nes-emulator-a emu) m)))
     (set-flag! emu 6 (bitwise-bit-set? m 6))
     (set-flag! emu 7 (bitwise-bit-set? m 7))]

    ;; Arithmetic (2A03 has no BCD mode; ADC/SBC are always binary)
    [(ADC)
     (define a (nes-emulator-a emu))
     (define m (bus-read emu eff-addr))
     (define c (if (flag-set? emu 0) 1 0))
     (define sum (+ a m c))
     (set-flag! emu 0 (> sum #xFF))
     (set-flag! emu 6 (not (zero? (bitwise-and (bitwise-not (bitwise-xor a m))
                                               (bitwise-xor a sum)
                                               #x80))))
     (set-nes-emulator-a! emu (update-nz! emu sum))]
    [(SBC)
     (define a (nes-emulator-a emu))
     (define m (bitwise-xor (bus-read emu eff-addr) #xFF))
     (define c (if (flag-set? emu 0) 1 0))
     (define sum (+ a m c))
     (set-flag! emu 0 (> sum #xFF))
     (set-flag! emu 6 (not (zero? (bitwise-and (bitwise-not (bitwise-xor a m))
                                               (bitwise-xor a sum)
                                               #x80))))
     (set-nes-emulator-a! emu (update-nz! emu sum))]

    ;; Comparisons
    [(CMP) (do-cmp (nes-emulator-a emu) (bus-read emu eff-addr))]
    [(CPX) (do-cmp (nes-emulator-x emu) (bus-read emu eff-addr))]
    [(CPY) (do-cmp (nes-emulator-y emu) (bus-read emu eff-addr))]

    ;; Inc / Dec
    [(INC)
     (define v (update-nz! emu (add1 (bus-read emu eff-addr))))
     (bus-write! emu eff-addr v)]
    [(DEC)
     (define v (update-nz! emu (sub1 (bus-read emu eff-addr))))
     (bus-write! emu eff-addr v)]
    [(INX) (set-nes-emulator-x! emu (update-nz! emu (add1 (nes-emulator-x emu))))]
    [(DEX) (set-nes-emulator-x! emu (update-nz! emu (sub1 (nes-emulator-x emu))))]
    [(INY) (set-nes-emulator-y! emu (update-nz! emu (add1 (nes-emulator-y emu))))]
    [(DEY) (set-nes-emulator-y! emu (update-nz! emu (sub1 (nes-emulator-y emu))))]

    ;; Shifts & Rotates
    [(ASL)
     (define v (if (eq? mode 'acc) (nes-emulator-a emu) (bus-read emu eff-addr)))
     (set-flag! emu 0 (bitwise-bit-set? v 7))
     (define res (update-nz! emu (arithmetic-shift v 1)))
     (if (eq? mode 'acc)
         (set-nes-emulator-a! emu res)
         (bus-write! emu eff-addr res))]
    [(LSR)
     (define v (if (eq? mode 'acc) (nes-emulator-a emu) (bus-read emu eff-addr)))
     (set-flag! emu 0 (bitwise-bit-set? v 0))
     (define res (update-nz! emu (arithmetic-shift v -1)))
     (if (eq? mode 'acc)
         (set-nes-emulator-a! emu res)
         (bus-write! emu eff-addr res))]
    [(ROL)
     (define v (if (eq? mode 'acc) (nes-emulator-a emu) (bus-read emu eff-addr)))
     (define old-c (if (flag-set? emu 0) 1 0))
     (set-flag! emu 0 (bitwise-bit-set? v 7))
     (define res (update-nz! emu (bitwise-ior (arithmetic-shift v 1) old-c)))
     (if (eq? mode 'acc)
         (set-nes-emulator-a! emu res)
         (bus-write! emu eff-addr res))]
    [(ROR)
     (define v (if (eq? mode 'acc) (nes-emulator-a emu) (bus-read emu eff-addr)))
     (define old-c (if (flag-set? emu 0) #x80 0))
     (set-flag! emu 0 (bitwise-bit-set? v 0))
     (define res (update-nz! emu (bitwise-ior (arithmetic-shift v -1) old-c)))
     (if (eq? mode 'acc)
         (set-nes-emulator-a! emu res)
         (bus-write! emu eff-addr res))]

    ;; Jumps & Subroutines
    [(JMP) (set-nes-emulator-pc! emu eff-addr)]
    [(JSR)
     (push-u16! emu (sub1 (nes-emulator-pc emu)))
     (set-nes-emulator-pc! emu eff-addr)]
    [(RTS)
     (set-nes-emulator-pc! emu (bitwise-and #xFFFF (add1 (pull-u16! emu))))]
    [(RTI)
     (set-nes-emulator-status!
      emu (bitwise-ior (bitwise-and (pull-u8! emu) #xEF) #x20))
     (set-nes-emulator-pc! emu (pull-u16! emu))]

    ;; Branches
    [(BCC) (unless (flag-set? emu 0) (take-branch!))]
    [(BCS) (when   (flag-set? emu 0) (take-branch!))]
    [(BEQ) (when   (flag-set? emu 1) (take-branch!))]
    [(BNE) (unless (flag-set? emu 1) (take-branch!))]
    [(BMI) (when   (flag-set? emu 7) (take-branch!))]
    [(BPL) (unless (flag-set? emu 7) (take-branch!))]
    [(BVC) (unless (flag-set? emu 6) (take-branch!))]
    [(BVS) (when   (flag-set? emu 6) (take-branch!))]

    ;; Flags
    [(CLC) (set-flag! emu 0 #f)]
    [(SEC) (set-flag! emu 0 #t)]
    [(CLI) (set-flag! emu 2 #f)]
    [(SEI) (set-flag! emu 2 #t)]
    [(CLV) (set-flag! emu 6 #f)]
    [(CLD) (set-flag! emu 3 #f)]
    [(SED) (set-flag! emu 3 #t)]
    [(NOP) (void)]
    [(BRK)
     (push-u16! emu (add1 (nes-emulator-pc emu)))
     (push-u8! emu (bitwise-ior (nes-emulator-status emu) #x30))
     (set-flag! emu 2 #t)
     (set-nes-emulator-pc! emu (bus-read-u16 emu #xFFFE))])

  mnem)

;; Run a subroutine at target-addr until its matching top-level RTS/RTI
(define (nes-run-until-rts! emu [target-addr #f] #:max-steps [max-steps 50000])
  (define start-cyc (nes-emulator-cycles emu))
  (define base-sp (nes-emulator-sp emu))
  (when target-addr
    ;; Push sentinel return address (#xFFFF - 1) so RTS returns cleanly
    (push-u16! emu #xFFFE)
    (set-nes-emulator-pc! emu target-addr))
  (let loop ([steps 0])
    (when (>= steps max-steps)
      (error 'nes-run-until-rts! "Exceeded ~a instruction steps without RTS/RTI" max-steps))
    (define mnem (nes-step! emu))
    (cond
      [(and (memq mnem '(RTS RTI))
            (equal? (nes-emulator-sp emu) base-sp))
       (- (nes-emulator-cycles emu) start-cyc)]
      [else
       (loop (add1 steps))])))

;; Trigger hardware NMI ($FFFA) and run until RTI, returning elapsed VBlank cycles
(define (nes-run-nmi! emu #:max-steps [max-steps 20000])
  (define start-cyc (nes-emulator-cycles emu))
  (define base-sp (nes-emulator-sp emu))
  ;; Set VBlank status flag (bit 7 of $2002)
  (set-nes-emulator-ppu-status!
   emu (bitwise-ior (nes-emulator-ppu-status emu) #x80))
  (push-u16! emu (nes-emulator-pc emu))
  (push-u8! emu (nes-emulator-status emu))
  (set-flag! emu 2 #t)
  (set-nes-emulator-pc! emu (bus-read-u16 emu #xFFFA))
  (let loop ([steps 0])
    (when (>= steps max-steps)
      (error 'nes-run-nmi! "NMI handler exceeded ~a steps without RTI" max-steps))
    (define mnem (nes-step! emu))
    (if (and (eq? mnem 'RTI)
             (equal? (nes-emulator-sp emu) base-sp))
        (- (nes-emulator-cycles emu) start-cyc)
        (loop (add1 steps)))))

;; Run one complete frame (ActiveFrame logic subroutine + VBlank NMI)
(define (nes-step-frame! emu frame-sub-addr [buttons 0])
  (nes-set-joypad1! emu buttons)
  (define active-cyc (nes-run-until-rts! emu frame-sub-addr))
  (define vblank-cyc (nes-run-nmi! emu))
  (values active-cyc vblank-cyc))
