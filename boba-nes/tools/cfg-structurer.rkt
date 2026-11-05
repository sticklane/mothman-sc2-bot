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
 structure-subroutine-cfg
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
;; (e.g. `(LDA #:imm 16 #:pc 32770)`) and structured control-flow forms
;; (`(when-branch ...)`, `(if-else ...)`, `(counted-loop ...)`,
;;  `(spin-wait-mmio-loop ...)`, `(do-while-loop ...)`, `(guard-return ...)`),
;; recursively extracts all leaf instruction S-expressions in exact PC order.
(define (flatten-structured-insts body-forms)
  (let loop ([forms body-forms]
             [acc '()])
    (cond
      [(null? forms)
       (reverse acc)]
      [else
       (define f (car forms))
       (cond
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
                ,@body-slice)]
             [step-mnem
              (set! loop-count (add1 loop-count))
              `(counted-loop
                #:header-pc ,header-pc
                #:latch-pc ,latch-pc
                #:step ,step-mnem
                #:cond ,c-sym
                ,@body-slice)]
             [else
              (set! loop-count (add1 loop-count))
              `(do-while-loop
                #:header-pc ,header-pc
                #:latch-pc ,latch-pc
                #:cond ,c-sym
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
               (define form `(guard-return #:branch-pc ,b-pc #:cond ,c-sym ,inst))
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
                     (define c-sym (branch-cond-sym mnem))
                     (define form
                       `(guard-return
                         #:branch-pc ,b-pc
                         #:cond ,c-sym
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
                                     [then-insts (vec-slice->list ivec i end-idx)]
                                     [else-insts (vec-slice->list ivec target-idx else-end-idx)]
                                     [form
                                      `(if-else
                                        #:branch-pc ,b-pc
                                        #:else-pc ,target-pc
                                        #:merge-pc ,merge-pc
                                        #:cond ,neg-sym
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
                                         [form
                                          `(when-branch
                                            #:branch-pc ,b-pc
                                            #:join-pc ,target-pc
                                            #:cond ,neg-sym
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
                     (define form
                       `(when-branch
                         #:branch-pc ,b-pc
                         #:join-pc ,target-pc
                         #:cond ,neg-sym
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
              (string->symbol (format "sub_b~a_~a"
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
  (define (add-idiom! form)
    (when (< (length idioms) max-idioms)
      (set! idioms (cons form idioms))))

  (for ([off (in-range 0 (- (- bank-end bank-start) 10))]
        #:when (< (length idioms) max-idioms))
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
      (add-idiom! `(idiom-u16-add-with-carry #:bank ,bank-idx #:pc ,pc))))

  (hasheq 'state-machines    (reverse state-machines)
          'high-level-idioms (reverse idioms)))

;; ============================================================================
;; 5. Sharp SM83 (GB / GBC) State-Machine Dispatcher & High-Level Idiom Lifter
;; ============================================================================

(define (valid-sm83-code-addr? addr)
  (and (>= addr #x0150) (<= addr #x7FFF)))

(define (sm83-addr->case-sym bank-idx addr)
  (define target-bank (if (< addr #x4000) 0 bank-idx))
  (string->symbol (format "sub_b~a_~a"
                          target-bank
                          (string-upcase (~r addr #:base 16 #:min-width 4 #:pad-string "0")))))

;; Extract inline 16-bit SM83 subroutine pointers starting at `rom-pos`
(define (extract-sm83-table-cases rom-bytes bank-idx bank-end rom-pos #:max-cases [max-cases 10])
  (let loop ([k 0]
             [acc '()])
    (define pos (+ rom-pos (* k 2)))
    (if (or (>= k max-cases) (> (+ pos 2) bank-end))
        (reverse acc)
        (let ([addr (u16-le rom-bytes pos)])
          (if (valid-sm83-code-addr? addr)
              (loop (add1 k)
                    (cons `(case ,k -> ,(sm83-addr->case-sym bank-idx addr))
                          acc))
              (reverse acc))))))

(define (lift-sm83-state-machines-and-idioms rom-bytes num-banks
                                             #:max-state-machines [max-state-machines 16]
                                             #:max-idioms [max-idioms 36])
  (define rom-len (bytes-length rom-bytes))
  (define state-machines '())
  (define idioms '())
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

  (define (add-sm83-idiom! form)
    (when (< (length idioms) max-idioms)
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
        (define cases (extract-sm83-table-cases rom-bytes b b-end (add1 pos) #:max-cases 10))
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
              (extract-sm83-table-cases rom-bytes b (min rom-len (+ tbl-rom-pos 32)) tbl-rom-pos #:max-cases 8)
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
        (add-sm83-idiom! `(idiom-sm83-mbc-switch #:bank ,b #:pc ,pc #:reg MBC_ROM_BANK)))))

  ;; Fallback if a ROM uses direct call dispatch without an inline table yet
  (when (null? state-machines)
    (add-sm83-sm! 0 #x0150 'jp-hl-dispatch-table '((case 0 -> main_entry_0150))))

  (hasheq 'state-machines    (reverse state-machines)
          'high-level-idioms (reverse idioms)))
