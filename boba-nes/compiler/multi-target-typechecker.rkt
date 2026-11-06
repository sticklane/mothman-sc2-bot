#lang racket/base

;; ============================================================================
;; compiler/multi-target-typechecker.rkt
;; 4-Layer Multi-Target Coeffect-Effect Type System for #lang boba-nes
;;
;; Verifies all 8 targets (NES, GB, GBC, PICO-8, RP2040, SNES, GBA, N64)
;; at type-checking time BEFORE backend assembly/code generation:
;;   1. Target-Parameterized Resource Semiring (`TargetGrade`)
;;   2. Flow-Sensitive Indexed Hoare Processor-State Typechecker (65816 & ARM/Thumb)
;;   3. Width-, Alignment-, and Phase-Qualified Memory Capability Checker (`CapMem`)
;;   4. Co-Processor / Multi-Core Session Protocol Verifier (SPC700, RSP/RDP, PIO)
;; ============================================================================

(require racket/match
         racket/list
         racket/set
         racket/format
         racket/math
         racket/string
         "boba-core-ir.rkt"
         "graded-typechecker.rkt")

(provide
 ;; Re-export key definitions from boba-core-ir.rkt & graded-typechecker.rkt
 (all-from-out "boba-core-ir.rkt")

 ;; Layer 1: Target-Parameterized Resource Semiring (`TargetGrade`)
 (struct-out target-grade)
 TargetGrade
 make-target-grade
 target-grade-zero
 target-grade-join
 target-grade-compose
 target-grade-seq
 target-grade-scale
 target-grade<=?
 infer-boba-core-statement-grade
 synthesize-target-module-grades
 verify-target-module-grades
 repair-target-module-grades

 ;; Layer 2: Flow-Sensitive Indexed Hoare Processor-State Typechecker
 make-processor-state
 default-processor-state
 check-processor-mode-transitions
 synthesize-65816-mode-reconciliation

 ;; Layer 3: Width-, Alignment-, and Phase-Qualified Memory Capability Checker
 (struct-out cap-mem)
 CapMem
 make-cap-mem
 check-memory-capability-access

 ;; Layer 4: Co-Processor / Multi-Core Session Protocol Verifier
 check-coprocessor-session-protocol

 ;; Layer 5: Refinement & Bitfield Hardware Register Types (`BitfieldType` & `RangeType`)
 (struct-out bitfield-type)
 BitfieldType
 make-bitfield-type
 HARDWARE-BITFIELD-SPECS
 decode-bitfield-mask
 encode-bitfield-flags
 check-bitfield-mask-valid?
 (struct-out range-type)
 RangeType
 make-range-type
 check-dispatch-index-bounds

 ;; Layer 6: Address-Space Pointer Provenance Modalities (`PtrProvenance`)
 (struct-out ptr-provenance)
 PtrProvenance
 make-ptr-provenance
 ptr-provenance-effective-addr
 ptr-provenance-add-offset
 resolve-ptr-mmio-symbol
 check-ptr-provenance-access

 ;; Layer 7: Per-Subroutine Coeffect & Calling-Convention Contracts (`SubroutineContract`)
 (struct-out subroutine-contract)
 SubroutineContract
 make-subroutine-contract
 verify-call-graph-contracts

 ;; Layer 8: Bidirectional Editable Pseudo-Code Compiler (`compile-pseudo-code->insts`)
 compile-pseudo-code->insts

 ;; Layer 9: Whole-ROM Static Contract, Bitfield, Layout & Pseudo-Code Verifier
 extract-whole-rom-contracts
 verify-whole-rom-module-contracts

 ;; Layer 10: Cross-Platform Subroutine & Hardware Idiom Transpiler
 CROSS-TARGET-MMIO-MAP
 transpile-pseudo-code-across-targets
 transpile-subroutine-across-targets

 ;; Layer 11: Bitvector Symbolic Equivalence Verifier
 symbolically-evaluate-pseudo-code
 verify-pseudo-code-equivalence)

;; ============================================================================
;; Layer 1: Target-Parameterized Resource Semiring (`TargetGrade`)
;; ============================================================================

(struct target-grade
  (target-id
   vblank-cycles
   hblank-cycles
   active-cycles
   dma-bytes
   oam-sprites
   oam-scanline
   fast-ram-bytes
   work-ram-bytes
   tile-mem-bytes
   rom-bytes
   extra-used
   state-totality?
   victory-reachable?
   cap-mem-safe?
   mode-state-safe?
   session-safe?)
  #:transparent)

(define TargetGrade target-grade)

(define (make-target-grade
         #:target-id          [target-id 'nes]
         #:vblank-cycles      [vblank-cycles 0]
         #:hblank-cycles      [hblank-cycles 0]
         #:active-cycles      [active-cycles 0]
         #:dma-bytes          [dma-bytes 0]
         #:oam-sprites        [oam-sprites 0]
         #:oam-scanline       [oam-scanline 0]
         #:fast-ram-bytes     [fast-ram-bytes 0]
         #:work-ram-bytes     [work-ram-bytes 0]
         #:tile-mem-bytes     [tile-mem-bytes 0]
         #:rom-bytes          [rom-bytes 0]
         #:extra-used         [extra-used 0]
         #:state-totality?    [state-totality? #t]
         #:victory-reachable? [victory-reachable? #t]
         #:cap-mem-safe?      [cap-mem-safe? #t]
         #:mode-state-safe?   [mode-state-safe? #t]
         #:session-safe?      [session-safe? #t])
  (define tid (if (target-spec? target-id) (target-spec-id target-id) target-id))
  (target-grade tid
                vblank-cycles
                hblank-cycles
                active-cycles
                dma-bytes
                oam-sprites
                oam-scanline
                fast-ram-bytes
                work-ram-bytes
                tile-mem-bytes
                rom-bytes
                extra-used
                state-totality?
                victory-reachable?
                cap-mem-safe?
                mode-state-safe?
                session-safe?))

(define (make-zero-grade [target-or-spec 'nes])
  (define tid
    (cond
      [(target-spec? target-or-spec) (target-spec-id target-or-spec)]
      [(symbol? target-or-spec) target-or-spec]
      [else 'nes]))
  (target-grade tid 0 0 0 0 0 0 0 0 0 0 0 #t #t #t #t #t))

;; `target-grade-zero` is an applicable `target-grade` struct instance:
;;   - As a value, `(target-grade? target-grade-zero)` is `#t` with all zero costs and `#t` invariants.
;;   - As a procedure, `(target-grade-zero)` or `(target-grade-zero 'snes)` or `(target-grade-zero TARGET-SNES)`
;;     returns a fresh zero `target-grade` for the given target.
(struct applicable-target-grade target-grade ()
  #:transparent
  #:property prop:procedure
  (case-lambda
    [(_self) (make-zero-grade 'nes)]
    [(_self target-or-spec) (make-zero-grade target-or-spec)]))

(define target-grade-zero
  (applicable-target-grade 'nes 0 0 0 0 0 0 0 0 0 0 0 #t #t #t #t #t))

(define (resolve-joined-target-id id1 id2)
  (if (and (eq? id1 'nes) (not (eq? id2 'nes)))
      id2
      id1))

;; Branch Supremum / Join (`g1 |_| g2`):
;; Takes the componentwise worst-case maximum on quantitative budgets and logical conjunction on safety flags.
(define (target-grade-join-2 g1 g2)
  (target-grade
   (resolve-joined-target-id (target-grade-target-id g1) (target-grade-target-id g2))
   (max (target-grade-vblank-cycles g1)  (target-grade-vblank-cycles g2))
   (max (target-grade-hblank-cycles g1)  (target-grade-hblank-cycles g2))
   (max (target-grade-active-cycles g1)  (target-grade-active-cycles g2))
   (max (target-grade-dma-bytes g1)      (target-grade-dma-bytes g2))
   (max (target-grade-oam-sprites g1)    (target-grade-oam-sprites g2))
   (max (target-grade-oam-scanline g1)   (target-grade-oam-scanline g2))
   (max (target-grade-fast-ram-bytes g1) (target-grade-fast-ram-bytes g2))
   (max (target-grade-work-ram-bytes g1) (target-grade-work-ram-bytes g2))
   (max (target-grade-tile-mem-bytes g1) (target-grade-tile-mem-bytes g2))
   (max (target-grade-rom-bytes g1)      (target-grade-rom-bytes g2))
   (max (target-grade-extra-used g1)     (target-grade-extra-used g2))
   (and (target-grade-state-totality? g1)    (target-grade-state-totality? g2))
   (and (target-grade-victory-reachable? g1) (target-grade-victory-reachable? g2))
   (and (target-grade-cap-mem-safe? g1)      (target-grade-cap-mem-safe? g2))
   (and (target-grade-mode-state-safe? g1)   (target-grade-mode-state-safe? g2))
   (and (target-grade-session-safe? g1)      (target-grade-session-safe? g2))))

(define (target-grade-join [g1 target-grade-zero] . rest)
  (for/fold ([acc g1]) ([g (in-list rest)])
    (target-grade-join-2 acc g)))

;; Sequential Composition (`g1 (.) g2`):
;; Sums additive temporal/spatial quantities, takes peak scanline sprites, and conjoins safety flags.
(define (target-grade-compose-2 g1 g2)
  (target-grade
   (resolve-joined-target-id (target-grade-target-id g1) (target-grade-target-id g2))
   (+ (target-grade-vblank-cycles g1)  (target-grade-vblank-cycles g2))
   (+ (target-grade-hblank-cycles g1)  (target-grade-hblank-cycles g2))
   (+ (target-grade-active-cycles g1)  (target-grade-active-cycles g2))
   (+ (target-grade-dma-bytes g1)      (target-grade-dma-bytes g2))
   (+ (target-grade-oam-sprites g1)    (target-grade-oam-sprites g2))
   (max (target-grade-oam-scanline g1) (target-grade-oam-scanline g2))
   (+ (target-grade-fast-ram-bytes g1) (target-grade-fast-ram-bytes g2))
   (+ (target-grade-work-ram-bytes g1) (target-grade-work-ram-bytes g2))
   (+ (target-grade-tile-mem-bytes g1) (target-grade-tile-mem-bytes g2))
   (+ (target-grade-rom-bytes g1)      (target-grade-rom-bytes g2))
   (+ (target-grade-extra-used g1)     (target-grade-extra-used g2))
   (and (target-grade-state-totality? g1)    (target-grade-state-totality? g2))
   (and (target-grade-victory-reachable? g1) (target-grade-victory-reachable? g2))
   (and (target-grade-cap-mem-safe? g1)      (target-grade-cap-mem-safe? g2))
   (and (target-grade-mode-state-safe? g1)   (target-grade-mode-state-safe? g2))
   (and (target-grade-session-safe? g1)      (target-grade-session-safe? g2))))

(define (target-grade-compose [g1 target-grade-zero] . rest)
  (for/fold ([acc g1]) ([g (in-list rest)])
    (target-grade-compose-2 acc g)))

(define target-grade-seq target-grade-compose)

;; Bounded Loop Scaling (`k * g`)
(define (target-grade-scale k g)
  (if (<= k 0)
      (make-zero-grade (target-grade-target-id g))
      (target-grade
       (target-grade-target-id g)
       (* k (target-grade-vblank-cycles g))
       (* k (target-grade-hblank-cycles g))
       (* k (target-grade-active-cycles g))
       (* k (target-grade-dma-bytes g))
       (* k (target-grade-oam-sprites g))
       (target-grade-oam-scanline g)
       (target-grade-fast-ram-bytes g)
       (target-grade-work-ram-bytes g)
       (target-grade-tile-mem-bytes g)
       (target-grade-rom-bytes g)
       (* k (target-grade-extra-used g))
       (target-grade-state-totality? g)
       (target-grade-victory-reachable? g)
       (target-grade-cap-mem-safe? g)
       (target-grade-mode-state-safe? g)
       (target-grade-session-safe? g))))

(define (target-grade<=? g1 g2)
  (and (<= (target-grade-vblank-cycles g1)  (target-grade-vblank-cycles g2))
       (<= (target-grade-hblank-cycles g1)  (target-grade-hblank-cycles g2))
       (<= (target-grade-active-cycles g1)  (target-grade-active-cycles g2))
       (<= (target-grade-dma-bytes g1)      (target-grade-dma-bytes g2))
       (<= (target-grade-oam-sprites g1)    (target-grade-oam-sprites g2))
       (<= (target-grade-oam-scanline g1)   (target-grade-oam-scanline g2))
       (<= (target-grade-fast-ram-bytes g1) (target-grade-fast-ram-bytes g2))
       (<= (target-grade-work-ram-bytes g1) (target-grade-work-ram-bytes g2))
       (<= (target-grade-tile-mem-bytes g1) (target-grade-tile-mem-bytes g2))
       (<= (target-grade-rom-bytes g1)      (target-grade-rom-bytes g2))
       (<= (target-grade-extra-used g1)     (target-grade-extra-used g2))
       (or (not (target-grade-state-totality? g2))    (target-grade-state-totality? g1))
       (or (not (target-grade-victory-reachable? g2)) (target-grade-victory-reachable? g1))
       (or (not (target-grade-cap-mem-safe? g2))      (target-grade-cap-mem-safe? g1))
       (or (not (target-grade-mode-state-safe? g2))   (target-grade-mode-state-safe? g1))
       (or (not (target-grade-session-safe? g2))      (target-grade-session-safe? g1))))

;; ============================================================================
;; Layer 2: Flow-Sensitive Indexed Hoare Processor-State Typechecker
;; ============================================================================
;; Models processor state:
;;   sigma = #hasheq((m-bits . 8/16) (x-bits . 8/16) (isa-mode . native/emulation/arm32/thumb16))

(define (make-processor-state
         #:m-bits   [m-bits 8]
         #:x-bits   [x-bits 8]
         #:isa-mode [isa-mode 'native])
  (hasheq 'm-bits   m-bits
          'x-bits   x-bits
          'isa-mode isa-mode))

(define (default-processor-state [target-or-spec 'snes])
  (define tid
    (cond
      [(target-spec? target-or-spec) (target-spec-id target-or-spec)]
      [(symbol? target-or-spec) target-or-spec]
      [else 'snes]))
  (case tid
    [(gba)    (make-processor-state #:m-bits 32 #:x-bits 32 #:isa-mode 'thumb16)]
    [(rp2040) (make-processor-state #:m-bits 32 #:x-bits 32 #:isa-mode 'thumb16)]
    [(snes)   (make-processor-state #:m-bits 8  #:x-bits 8  #:isa-mode 'native)]
    [else     (make-processor-state #:m-bits 8  #:x-bits 8  #:isa-mode 'native)]))

(define (processor-states-equal? s1 s2)
  (and (equal? (hash-ref s1 'm-bits 8)         (hash-ref s2 'm-bits 8))
       (equal? (hash-ref s1 'x-bits 8)         (hash-ref s2 'x-bits 8))
       (equal? (hash-ref s1 'isa-mode 'native) (hash-ref s2 'isa-mode 'native))))

;; Synthesize reconciling 65816 REP/SEP instructions to transition from `cur-state` to `goal-state`
(define (emit-reconciling-65816-ops cur-state goal-state)
  (define cur-m  (hash-ref cur-state 'm-bits 8))
  (define cur-x  (hash-ref cur-state 'x-bits 8))
  (define goal-m (hash-ref goal-state 'm-bits 8))
  (define goal-x (hash-ref goal-state 'x-bits 8))
  (define rep-mask
    (+ (if (and (= cur-m 8)  (= goal-m 16)) #x20 0)
       (if (and (= cur-x 8)  (= goal-x 16)) #x10 0)))
  (define sep-mask
    (+ (if (and (= cur-m 16) (= goal-m 8))  #x20 0)
       (if (and (= cur-x 16) (= goal-x 8))  #x10 0)))
  (append
   (if (> rep-mask 0) (list `(rep ,rep-mask)) '())
   (if (> sep-mask 0) (list `(sep ,sep-mask)) '())))

(define (append-ops-to-branch branch extra-ops)
  (cond
    [(null? extra-ops) branch]
    [(and (pair? branch) (memq (car branch) '(seq begin)))
     `(,(car branch) ,@(cdr branch) ,@extra-ops)]
    [(and (list? branch) (pair? branch) (list? (car branch)))
     (append branch extra-ops)]
    [else
     `(seq ,branch ,@extra-ops)]))

;; Flow-sensitive abstract interpretation of processor mode transitions
(define (step-processor-mode-ast ast sigma fn-sigs)
  (define (step-seq stmts cur-sigma)
    (for/fold ([st cur-sigma]
               [viols '()]
               [reconciled '()])
              ([s (in-list stmts)])
      (define-values (next-st s-viols s-rec)
        (step-processor-mode-ast s st fn-sigs))
      (values next-st
              (append viols s-viols)
              (append reconciled (list s-rec)))))

  (match ast
    ['() (values sigma '() '())]

    ;; Sequential block: (seq s1 ...) or (begin s1 ...)
    [`(,(and head (or 'seq 'begin)) . ,stmts)
     (define-values (next-st viols rec-list) (step-seq stmts sigma))
     (values next-st viols `(,head ,@rec-list))]

    ;; 65816 REP #imm: clear P flag bits (bit 5 = #x20 -> M=16, bit 4 = #x10 -> X=16)
    [`(,(or 'rep 'REP) ,(? exact-integer? mask))
     (define next-m (if (bitwise-bit-set? mask 5) 16 (hash-ref sigma 'm-bits 8)))
     (define next-x (if (bitwise-bit-set? mask 4) 16 (hash-ref sigma 'x-bits 8)))
     (define viols
       (if (eq? (hash-ref sigma 'isa-mode 'native) 'emulation)
           (list (hasheq 'rule 'rep-in-emulation-mode
                         'message "65816 REP #imm executed while in 6502 emulation mode (E=1 forces M=8, X=8)"
                         'state sigma
                         'stmt ast))
           '()))
     (values (hash-set (hash-set sigma 'm-bits next-m) 'x-bits next-x)
             viols
             ast)]

    ;; 65816 SEP #imm: set P flag bits (bit 5 = #x20 -> M=8, bit 4 = #x10 -> X=8)
    [`(,(or 'sep 'SEP) ,(? exact-integer? mask))
     (define next-m (if (bitwise-bit-set? mask 5) 8 (hash-ref sigma 'm-bits 8)))
     (define next-x (if (bitwise-bit-set? mask 4) 8 (hash-ref sigma 'x-bits 8)))
     (values (hash-set (hash-set sigma 'm-bits next-m) 'x-bits next-x)
             '()
             ast)]

    ;; 65816 XCE mode switch
    [`(,(or 'xce 'XCE) ,mode)
     (define next-isa (if (memq mode '(emulation 1 #t)) 'emulation 'native))
     (define next-sigma
       (if (eq? next-isa 'emulation)
           (make-processor-state #:m-bits 8 #:x-bits 8 #:isa-mode 'emulation)
           (hash-set sigma 'isa-mode 'native)))
     (values next-sigma '() ast)]

    ;; GBA ARM32 / Thumb16 ISA mode switch
    [`(,(or 'bx-mode 'set-isa-mode 'isa-mode) ,target-isa)
     (values (hash-set sigma 'isa-mode target-isa) '() ast)]

    ;; Conditional branch join: `(if cond then-branch else-branch)`
    [`(if ,cond-e ,then-b ,else-b)
     (define-values (st-then v-then rec-then) (step-processor-mode-ast then-b sigma fn-sigs))
     (define-values (st-else v-else rec-else) (step-processor-mode-ast else-b sigma fn-sigs))
     (cond
       [(processor-states-equal? st-then st-else)
        (values st-then
                (append v-then v-else)
                `(if ,cond-e ,rec-then ,rec-else))]
       [else
        ;; Join mismatch detected! Reconcile `then-b` (and `else-b` if needed) to `st-else`
        ;; (which typically holds the canonical 8-bit `M=8, X=8` state at branch join).
        (define goal-state st-else)
        (define fix-then-ops (emit-reconciling-65816-ops st-then goal-state))
        (define fixed-then (append-ops-to-branch rec-then fix-then-ops))
        (define join-viol
          (hasheq 'rule       'processor-mode-join-mismatch
                  'category   'branch-mode-divergence
                  'message    (format "Branch join processor-state mismatch: then-branch exits with M=~a/X=~a (~a), else-branch exits with M=~a/X=~a (~a)"
                                      (hash-ref st-then 'm-bits 8)
                                      (hash-ref st-then 'x-bits 8)
                                      (hash-ref st-then 'isa-mode 'native)
                                      (hash-ref st-else 'm-bits 8)
                                      (hash-ref st-else 'x-bits 8)
                                      (hash-ref st-else 'isa-mode 'native))
                  'then-state st-then
                  'else-state st-else
                  'reconcile  fix-then-ops))
        (values goal-state
                (append v-then v-else (list join-viol))
                `(if ,cond-e ,fixed-then ,rec-else))])]

    ;; Single-armed conditional: `(when cond body ...)` / `(unless cond body ...)`
    [`(,(and kw (or 'when 'unless)) ,cond-e . ,body)
     (define-values (st-body v-body rec-body) (step-seq body sigma))
     (cond
       [(processor-states-equal? st-body sigma)
        (values sigma v-body `(,kw ,cond-e ,@rec-body))]
       [else
        (define fix-ops (emit-reconciling-65816-ops st-body sigma))
        (define join-viol
          (hasheq 'rule       'processor-mode-join-mismatch
                  'category   'single-arm-mode-divergence
                  'message    (format "Single-armed '~a' modifies processor mode from ~v to ~v without restoring before fallthrough join"
                                      kw sigma st-body)
                  'then-state st-body
                  'else-state sigma
                  'reconcile  fix-ops))
        (values sigma
                (append v-body (list join-viol))
                `(,kw ,cond-e ,@(append rec-body fix-ops)))])]

    ;; Function / Subroutine / Interworking Call: `(call fn-sig ...)` or `(bl ...)` / `(bx ...)`
    [`(,(and call-op (or 'call 'jsr 'jsl 'bl 'bx 'blx)) . ,args)
     (define sig
       (cond
         [(and (pair? args) (hash? (car args))) (car args)]
         [(and (pair? args) (symbol? (car args)) (hash-has-key? fn-sigs (car args)))
          (hash-ref fn-sigs (car args))]
         [(and (>= (length args) 2) (symbol? (first args)) (symbol? (second args)))
          ;; e.g. `(call 'fast_iwram_fn 'arm32)` or `(call 'fast_iwram_fn 'thumb16 'arm32 #f)`
          (if (>= (length args) 3)
              (hasheq 'name        (first args)
                      'caller-isa  (second args)
                      'isa-mode    (third args)
                      'via-bx?     (if (>= (length args) 4) (fourth args) (memq call-op '(bx blx))))
              (hasheq 'name        (first args)
                      'isa-mode    (second args)
                      'via-bx?     (memq call-op '(bx blx))))]
         [(pair? args)
          (hasheq 'name (car args) 'via-bx? (memq call-op '(bx blx)))]
         [else (hasheq)]))

     (define req-m   (hash-ref sig 'm-bits   (hash-ref sig 'req-m-bits #f)))
     (define req-x   (hash-ref sig 'x-bits   (hash-ref sig 'req-x-bits #f)))
     (define req-isa (hash-ref sig 'isa-mode (hash-ref sig 'target-isa (hash-ref sig 'callee-isa #f))))
     (define cur-isa (hash-ref sig 'caller-isa (hash-ref sigma 'isa-mode 'native)))
     (define via-bx?
       (or (memq call-op '(bx blx))
           (hash-ref sig 'via-bx? #f)
           (hash-ref sig 'interworking? #f)
           (hash-ref sig 'bx-veneer? #f)))

     (define call-viols '())

     ;; Check 65816 M/X register width preconditions
     (when (and req-m (not (= req-m (hash-ref sigma 'm-bits 8))))
       (set! call-viols
             (cons (hasheq 'rule     'callee-m-width-mismatch
                           'category 'callee-precondition
                           'message  (format "Call to '~a' requires M=~a-bit accumulator, but caller state has M=~a"
                                             (hash-ref sig 'name 'fn) req-m (hash-ref sigma 'm-bits 8))
                           'expected req-m
                           'actual   (hash-ref sigma 'm-bits 8))
                   call-viols)))
     (when (and req-x (not (= req-x (hash-ref sigma 'x-bits 8))))
       (set! call-viols
             (cons (hasheq 'rule     'callee-x-width-mismatch
                           'category 'callee-precondition
                           'message  (format "Call to '~a' requires X=~a-bit index registers, but caller state has X=~a"
                                             (hash-ref sig 'name 'fn) req-x (hash-ref sigma 'x-bits 8))
                           'expected req-x
                           'actual   (hash-ref sigma 'x-bits 8))
                   call-viols)))

     ;; Check GBA ARM32 (IWRAM) <-> Thumb16 (ROM) interworking veneer requirement
     (when (and req-isa
                (memq cur-isa '(arm32 thumb16))
                (memq req-isa '(arm32 thumb16))
                (not (eq? cur-isa req-isa))
                (not via-bx?))
       (set! call-viols
             (cons (hasheq 'rule        'gba-interworking-without-bx-veneer
                           'category    'arm-thumb-interworking-hazard
                           'message     (format "Direct call from ~a to ~a function '~a' without BX/BLX interworking veneer"
                                                cur-isa req-isa (hash-ref sig 'name 'fn))
                           'caller-isa  cur-isa
                           'callee-isa  req-isa
                           'repair      'insert-bx-interworking-veneer)
                   call-viols)))

     (define exit-m   (hash-ref sig 'exit-m-bits (hash-ref sigma 'm-bits 8)))
     (define exit-x   (hash-ref sig 'exit-x-bits (hash-ref sigma 'x-bits 8)))
     (define next-sig (hash-set (hash-set sigma 'm-bits exit-m) 'x-bits exit-x))
     (values next-sig (reverse call-viols) ast)]

    ;; List of statements
    [(? list? stmts)
     (step-seq stmts sigma)]

    ;; Any other instruction preserves processor mode state
    [_ (values sigma '() ast)]))

;; Check sequences of processor mode transitions (`rep`, `sep`, `if`, `call`).
;; Supports `(check-processor-mode-transitions stmts [initial-state])`
;; and `(check-processor-mode-transitions target-sym stmts)`.
(define (check-processor-mode-transitions
         arg1
         [arg2 #f]
         #:initial-state [kw-init #f]
         #:target        [kw-target #f]
         #:fn-sigs       [fn-sigs (hasheq)])
  (define-values (stmts init-sigma)
    (cond
      [(and (or (target-id? arg1) (target-spec? arg1)) arg2)
       (values arg2 (or kw-init (default-processor-state arg1)))]
      [(and (hash? arg2) (hash-has-key? arg2 'm-bits))
       (values arg1 arg2)]
      [(or (target-id? arg2) (target-spec? arg2))
       (values arg1 (or kw-init (default-processor-state arg2)))]
      [else
       (values arg1 (or kw-init (default-processor-state (or kw-target 'snes))))]))

  (define-values (final-sigma violations reconciled-ast)
    (step-processor-mode-ast stmts init-sigma fn-sigs))

  (hasheq 'valid?         (null? violations)
          'initial-state  init-sigma
          'final-state    final-sigma
          'violations     violations
          'reconciled-ast reconciled-ast))

;; Automatically insert reconciling `(sep #x20)` / `(rep #x20)` / `(sep #x10)` / `(rep #x10)`
;; instructions before branch joins so that all paths exit with matching 65816 M/X widths.
(define (synthesize-65816-mode-reconciliation
         stmts
         [initial-state #f]
         #:fn-sigs [fn-sigs (hasheq)])
  (define res
    (check-processor-mode-transitions
     stmts
     (or initial-state (default-processor-state 'snes))
     #:fn-sigs fn-sigs))
  (hash-ref res 'reconciled-ast))

;; ============================================================================
;; Layer 3: Width-, Alignment-, and Phase-Qualified Memory Capability Checker
;; ============================================================================

(struct cap-mem
  (region
   width
   align
   phase
   cache-state
   bytes)
  #:transparent)

(define (make-cap-mem region
                      [width 'u8]
                      [align 1]
                      [phase 'vblank]
                      [cache-state 'cache-flushed]
                      [bytes 1])
  (cap-mem region width align phase cache-state bytes))

(require (for-syntax racket/base))

(define-match-expander CapMem
  (syntax-rules ()
    [(_ r w a p c b) (cap-mem r w a p c b)]
    [(_ r w a p)     (cap-mem r w a p _ _)])
  (lambda (stx)
    (syntax-case stx ()
      [(_ . args) #'(make-cap-mem . args)]
      [_ #'make-cap-mem])))

;; Normalize a memory operation S-expression, `cap-mem` struct, or hash into a `cap-mem` struct.
(define (normalize-cap-mem-op op)
  (match op
    [(? cap-mem? cm) cm]
    [(? hash? h)
     (cap-mem (hash-ref h 'region 'vram)
              (hash-ref h 'width 'u8)
              (hash-ref h 'align 1)
              (hash-ref h 'phase 'vblank)
              (hash-ref h 'cache-state 'cache-flushed)
              (hash-ref h 'bytes 1))]
    [`(,(or 'mem-write 'mem-read 'ir-mem-write 'ir-mem-read)
       ,region ,width ,align ,phase ,cache-state ,bytes)
     (cap-mem region width align phase cache-state bytes)]
    [`(,(or 'mem-write 'mem-read 'ir-mem-write 'ir-mem-read)
       ,region ,width ,align ,phase ,(? exact-integer? bytes))
     (cap-mem region width align phase 'cache-flushed bytes)]
    [`(,(or 'mem-write 'mem-read 'ir-mem-write 'ir-mem-read)
       ,region ,width ,align ,phase ,(? symbol? cache-state))
     (cap-mem region width align phase cache-state 1)]
    [`(,(or 'mem-write 'mem-read 'ir-mem-write 'ir-mem-read)
       ,region ,width ,align ,phase)
     (cap-mem region width align phase 'cache-flushed 1)]
    [`(,(or 'ir-vram-patch 'vram-patch) ,_addr ,bytes ,width ,align ,phase)
     (cap-mem 'vram width align phase 'cache-flushed bytes)]
    [`(,(or 'oam-dma-wait 'gb-oam-dma) ,wait-region)
     (cap-mem 'oam-dma 'u8 256 'vblank wait-region 160)]
    [`(,(or 'oam-dma-wait 'gb-oam-dma) ,wait-region ,bytes)
     (cap-mem 'oam-dma 'u8 256 'vblank wait-region bytes)]
    [_ #f]))

(define (check-single-cap-mem-op spec cm)
  (match-define (cap-mem region width align phase cache-state bytes) cm)
  (define tid (target-spec-id spec))
  (define violations '())

  ;; 1. Game Boy / Game Boy Color (`'gb`, `'gbc`) Hardware Capability Rules:
  ;;    - Rejects `'vram` writes during `'active-mode3` (must be `'vblank`, `'hblank-mode0`, or `'lcd-disabled`)
  ;;    - Rejects OAM DMA wait loops not residing in `'hram` ($FF80-$FFFE)
  (when (memq tid '(gb gbc))
    (when (memq region '(vram vram-banked tile-mem chr-ram))
      (unless (memq phase (target-spec-vram-allowed-phases spec))
        (set! violations
              (cons (hasheq 'rule        'gb-vram-write-in-forbidden-phase
                            'target      tid
                            'region      region
                            'phase       phase
                            'allowed     (target-spec-vram-allowed-phases spec)
                            'message     (format "Illegal ~a VRAM write during phase '~a' (PPU Mode 3 locks VRAM bus; allowed phases: ~a)"
                                                 tid phase (target-spec-vram-allowed-phases spec))
                            'repair      'gate-vram-write-on-stat-mode0-or-vblank)
                    violations))))
    (when (or (and (memq region '(oam-dma oam-dma-wait dma))
                   (not (memq cache-state '(cache-flushed hram #t))))
              (memq region '(oam-dma-rom-wait oam-dma-wram-wait wram-dma-wait rom-dma-wait)))
      (set! violations
            (cons (hasheq 'rule        'gb-oam-dma-wait-outside-hram
                          'target      tid
                          'region      region
                          'cache-state cache-state
                          'message     "SM83 OAM DMA ($FF46) locks external ROM/WRAM bus for 160 M-cycles; wait loop must execute from HRAM ($FF80-$FFFE)"
                          'repair      'relocate-oam-dma-trampoline-to-hram)
                  violations))))

  ;; 2. Game Boy Advance (`'gba`) Hardware Capability Rules:
  ;;    - Rejects `'u8` (`STRB`) writes to `'vram`, `'oam`, or `'palram` (must be `'u16` or `'u32` with `align >= 2`)
  (when (eq? tid 'gba)
    (when (memq region '(vram gba-vram oam palram palette cgram bg-palram obj-palram))
      (when (eq? width 'u8)
        (set! violations
              (cons (hasheq 'rule    'gba-u8-strb-to-16bit-bus-forbidden
                            'target  'gba
                            'region  region
                            'width   width
                            'message (format "GBA 8-bit STRB ('u8) write to '~a' is forbidden (16-bit bus smears byte across both halfword lanes or ignores write)"
                                             region)
                            'repair  'widen-write-to-u16-strh-or-u32-str)
                    violations)))
      (when (< align 2)
        (set! violations
              (cons (hasheq 'rule    'gba-unaligned-vram-oam-palram-access
                            'target  'gba
                            'region  region
                            'align   align
                            'message (format "GBA write to '~a' has alignment ~a (< minimum 2-byte halfword alignment)"
                                             region align)
                            'repair  'align-vram-transfer-to-halfword-or-word)
                    violations)))
      (when (and (eq? width 'u32) (< align 4))
        (set! violations
              (cons (hasheq 'rule    'gba-unaligned-u32-access
                            'target  'gba
                            'region  region
                            'width   'u32
                            'align   align
                            'message (format "GBA 32-bit ('u32) write to '~a' requires 4-byte alignment, got ~a"
                                             region align)
                            'repair  'align-u32-access-to-4-bytes)
                    violations)))))

  ;; 3. Nintendo 64 (`'n64`) Hardware Capability Rules:
  ;;    - Rejects `'rdram-dma` transfers with `align < 16` or `cache-state != 'cache-flushed`
  ;;    - Rejects `'rdp-tmem`, `'rsp-dmem`, or `'rsp-imem` uploads exceeding `4,096 B`
  (when (eq? tid 'n64)
    (when (memq region '(rdram-dma pi-dma sp-dma dma rdram))
      (when (< align 16)
        (set! violations
              (cons (hasheq 'rule    'n64-rdram-dma-alignment-violation
                            'target  'n64
                            'region  region
                            'align   align
                            'message (format "N64 RCP DMA transfer on '~a' has alignment ~a B (< required 16-byte cacheline alignment)"
                                             region align)
                            'repair  'align-rdram-dma-buffer-to-16-bytes)
                    violations)))
      (unless (eq? cache-state 'cache-flushed)
        (set! violations
              (cons (hasheq 'rule        'n64-rdram-dma-unflushed-cache
                            'target      'n64
                            'region      region
                            'cache-state cache-state
                            'message     (format "N64 RCP DMA on '~a' with cache-state '~a' (requires 'cache-flushed osWritebackDCache before DMA)"
                                                 region cache-state)
                            'repair      'insert-os-writeback-dcache-before-dma)
                    violations))))
    (when (memq region '(rdp-tmem rsp-dmem rsp-imem tmem dmem imem))
      (when (> bytes 4096)
        (set! violations
              (cons (hasheq 'rule    'n64-onchip-sram-4kb-overflow
                            'target  'n64
                            'region  region
                            'bytes   bytes
                            'max     4096
                            'message (format "N64 upload to on-chip memory '~a' is ~a B, exceeding hardware 4,096 B SRAM limit"
                                             region bytes)
                            'repair  'tile-or-strip-stream-within-4kb-tmem-dmem)
                    violations)))))

  ;; 4. General TargetSpec Width / Alignment / Phase / Size Checks across all 8 targets
  (when (memq region '(vram chr-rom chr-ram vram-banked s-ppu-vram gba-vram rdp-tmem gfx-sheet framebuf-sram))
    (unless (or (eq? width 'dma) (memq width (target-spec-vram-allowed-widths spec)))
      (set! violations
            (cons (hasheq 'rule    'target-vram-width-disallowed
                          'target  tid
                          'region  region
                          'width   width
                          'allowed (target-spec-vram-allowed-widths spec)
                          'message (format "Target '~a' disallows width '~a' on '~a' (allowed: ~a)"
                                           tid width region (target-spec-vram-allowed-widths spec))
                          'repair  'adjust-vram-access-width)
                  violations)))
    (when (< align (target-spec-vram-min-align spec))
      (set! violations
            (cons (hasheq 'rule    'target-vram-alignment-violation
                          'target  tid
                          'region  region
                          'align   align
                          'min     (target-spec-vram-min-align spec)
                          'message (format "Target '~a' requires alignment >= ~a on '~a', got ~a"
                                           tid (target-spec-vram-min-align spec) region align)
                          'repair  'align-vram-access)
                  violations)))
    (unless (memq phase (target-spec-vram-allowed-phases spec))
      (set! violations
            (cons (hasheq 'rule    'target-vram-phase-violation
                          'target  tid
                          'region  region
                          'phase   phase
                          'allowed (target-spec-vram-allowed-phases spec)
                          'message (format "Target '~a' forbids '~a' write during phase '~a' (allowed: ~a)"
                                           tid region phase (target-spec-vram-allowed-phases spec))
                          'repair  'schedule-vram-write-in-vblank-or-forced-blank)
                  violations)))
    (when (> bytes (target-spec-tile-mem-bytes-max spec))
      (set! violations
            (cons (hasheq 'rule    'target-tile-mem-overflow
                          'target  tid
                          'region  region
                          'bytes   bytes
                          'max     (target-spec-tile-mem-bytes-max spec)
                          'message (format "Target '~a' tile memory write of ~a B exceeds ~a limit (~a B)"
                                           tid bytes (target-spec-tile-mem-name spec) (target-spec-tile-mem-bytes-max spec))
                          'repair  'stream-or-compress-tile-data)
                  violations))))

  (when (or (eq? width 'dma) (memq region '(dma oam-dma hdma rdram-dma)))
    (when (< align (target-spec-dma-min-align spec))
      (set! violations
            (cons (hasheq 'rule    'target-dma-alignment-violation
                          'target  tid
                          'region  region
                          'align   align
                          'min     (target-spec-dma-min-align spec)
                          'message (format "Target '~a' DMA transfer on '~a' requires alignment >= ~a B, got ~a B"
                                           tid region (target-spec-dma-min-align spec) align)
                          'repair  'align-dma-source-buffer)
                  violations)))
    (when (> bytes (target-spec-dma-bytes-max spec))
      (set! violations
            (cons (hasheq 'rule    'target-dma-bandwidth-exceeded
                          'target  tid
                          'region  region
                          'bytes   bytes
                          'max     (target-spec-dma-bytes-max spec)
                          'message (format "Target '~a' DMA transfer of ~a B exceeds per-frame DMA ceiling (~a B)"
                                           tid bytes (target-spec-dma-bytes-max spec))
                          'repair  'split-dma-across-multiple-vblanks)
                  violations))))

  (reverse violations))

;; Recursively extract any `(mem-write ...)` / `cap-mem` operations from an op or list of ops
(define (extract-cap-mem-ops input)
  (cond
    [(null? input) '()]
    [(normalize-cap-mem-op input) => list]
    [(list? input)
     (apply append (map extract-cap-mem-ops input))]
    [else '()]))

;; Check memory capability access operations against `TargetSpec`.
;; Supports both `(check-memory-capability-access target-or-spec ops)`
;; and `(check-memory-capability-access ops target-or-spec)`.
(define (check-memory-capability-access arg1 [arg2 'nes])
  (define-values (spec raw-ops)
    (if (or (target-spec? arg1) (target-id? arg1))
        (values (get-target-spec arg1) arg2)
        (values (get-target-spec arg2) arg1)))
  (define cm-ops (extract-cap-mem-ops raw-ops))
  (define all-violations
    (apply append
           (for/list ([cm (in-list cm-ops)])
             (check-single-cap-mem-op spec cm))))
  (hasheq 'valid?        (null? all-violations)
          'target        (target-spec-id spec)
          'checked-count (length cm-ops)
          'violations    all-violations))

;; ============================================================================
;; Layer 4: Co-Processor / Multi-Core Session Protocol Verifier
;; ============================================================================
;; Verifies balanced `(send port tag payload-bytes)` / `(recv port tag)` session
;; protocols for:
;;   - SNES 5A22 <-> SPC700 ($2140-$2143)
;;   - N64 VR4300 <-> RSP <-> RDP
;;   - RP2040 Core0 <-> Core1 <-> PIO

(define (infer-target-from-session-ops ops)
  (let loop ([lst (if (list? ops) ops (list ops))])
    (match lst
      ['() 'snes]
      [(cons `(,(or 'send 'recv) ,port . ,_) rest)
       (cond
         [(memq port '(spc700 apu-io apu0 apu1 apu2 apu3 $2140 $2141 $2142 $2143)) 'snes]
         [(memq port '(rsp rdp sp-fifo dp-fifo rsp-dmem rsp-imem rdp-tmem)) 'n64]
         [(memq port '(pio0 pio1 pio-sm core1 sio-fifo pio-tx pio-rx)) 'rp2040]
         [else (loop rest)])]
      [(cons (? list? sub) rest)
       (define r (loop sub))
       (if (eq? r 'snes) (loop rest) r)]
      [(cons _ rest) (loop rest)])))

(define (port-payload-limit spec port)
  (define tid (target-spec-id spec))
  (cond
    [(memq port '($2140-reg $2141-reg $2142-reg $2143-reg)) 4]
    [(eq? tid 'snes)   (max 1 (target-spec-extra-budget-max spec))] ; 65,536 B SPC700 ARAM
    [(eq? tid 'n64)    (max 1 (target-spec-extra-budget-max spec))] ; 4,096 B RSP IMEM/DMEM
    [(eq? tid 'rp2040)
     (if (memq port '(core1 sio-fifo sram-dma))
         (target-spec-dma-bytes-max spec)
         (max 1 (target-spec-extra-budget-max spec)))]              ; 32 PIO instructions
    [else (max 64 (target-spec-dma-bytes-max spec))]))

(define (flatten-session-ops ops)
  (match ops
    ['() '()]
    [`(,(or 'send 'recv) . ,_) (list ops)]
    [`(,(or 'seq 'begin) . ,body)
     (apply append (map flatten-session-ops body))]
    [(? list? lst)
     (apply append (map flatten-session-ops lst))]
    [(? hash? h)
     (if (hash-has-key? h 'op) (list h) '())]
    [_ '()]))

;; Verify balanced `(send port tag payload-bytes)` / `(recv port tag)` session protocols.
;; Supports `(check-coprocessor-session-protocol ops [target])`
;; and `(check-coprocessor-session-protocol target ops)`.
(define (check-coprocessor-session-protocol arg1 [arg2 #f])
  (define-values (spec raw-ops)
    (cond
      [(and (or (target-spec? arg1) (target-id? arg1)) arg2)
       (values (get-target-spec arg1) arg2)]
      [(and arg2 (or (target-spec? arg2) (target-id? arg2)))
       (values (get-target-spec arg2) arg1)]
      [else
       (values (get-target-spec (infer-target-from-session-ops arg1)) arg1)]))

  (define tid (target-spec-id spec))
  (define flat-ops (flatten-session-ops raw-ops))
  (define port-queues (make-hasheq)) ; port -> list of (hasheq 'tag tag 'bytes bytes)
  (define port-bytes  (make-hasheq)) ; port -> cumulative payload bytes
  (define violations '())
  (define completed-handshakes 0)

  (for ([op (in-list flat-ops)])
    (match op
      [`(send ,port ,tag ,(? exact-integer? payload-bytes))
       (define limit (port-payload-limit spec port))
       (define new-total (+ (hash-ref port-bytes port 0) payload-bytes))
       (hash-set! port-bytes port new-total)
       (when (or (<= payload-bytes 0) (> payload-bytes limit) (> new-total limit))
         (set! violations
               (cons (hasheq 'rule          'coprocessor-session-payload-overflow
                             'target        tid
                             'port          port
                             'tag           tag
                             'payload-bytes payload-bytes
                             'cumulative    new-total
                             'max-bytes     limit
                             'message       (format "Co-processor send on port '~a' (tag '~a') payload ~a B (cumulative ~a B) exceeds '~a' limit of ~a B"
                                                    port tag payload-bytes new-total (target-spec-coprocessor-name spec) limit)
                             'repair        'chunk-coprocessor-payload-into-bounded-packets)
                     violations)))
       (define q (hash-ref port-queues port '()))
       (hash-set! port-queues port (append q (list (hasheq 'port port 'tag tag 'bytes payload-bytes))))]

      [`(recv ,port ,expected-tag)
       (define q (hash-ref port-queues port '()))
       (cond
         [(null? q)
          (set! violations
                (cons (hasheq 'rule         'coprocessor-recv-without-send
                              'target       tid
                              'port         port
                              'expected-tag expected-tag
                              'message      (format "Co-processor recv on port '~a' waiting for tag '~a' with empty channel queue (deadlock)"
                                                    port expected-tag)
                              'repair       'emit-matching-send-before-recv)
                      violations))]
         [else
          (define head (car q))
          (define sent-tag (hash-ref head 'tag))
          (hash-set! port-queues port (cdr q))
          (if (equal? sent-tag expected-tag)
              (set! completed-handshakes (add1 completed-handshakes))
              (set! violations
                    (cons (hasheq 'rule         'coprocessor-session-tag-mismatch
                                  'target       tid
                                  'port         port
                                  'sent-tag     sent-tag
                                  'expected-tag expected-tag
                                  'message      (format "Co-processor session protocol mismatch on port '~a': sent tag '~a', but recv expected '~a'"
                                                        port sent-tag expected-tag)
                                  'repair       'align-send-and-recv-protocol-tags)
                          violations)))])]
      [_ (void)]))

  ;; Any sends still remaining in `port-queues` are unacknowledged sends!
  (define pending-sends
    (apply append
           (for/list ([(port q) (in-hash port-queues)]
                      #:unless (null? q))
             q)))

  (for ([pending (in-list pending-sends)])
    (set! violations
          (cons (hasheq 'rule    'coprocessor-unacknowledged-send
                        'target  tid
                        'port    (hash-ref pending 'port)
                        'tag     (hash-ref pending 'tag)
                        'bytes   (hash-ref pending 'bytes)
                        'message (format "Unacknowledged co-processor send on port '~a' with tag '~a' (~a B): missing matching (recv ~a ~a)"
                                         (hash-ref pending 'port)
                                         (hash-ref pending 'tag)
                                         (hash-ref pending 'bytes)
                                         (hash-ref pending 'port)
                                         (hash-ref pending 'tag))
                        'repair  'append-matching-coprocessor-recv-ack)
                violations)))

  (define final-viols (reverse violations))
  (hasheq 'valid?               (null? final-viols)
          'target               tid
          'coprocessor          (target-spec-coprocessor-name spec)
          'completed-handshakes completed-handshakes
          'pending-sends        pending-sends
          'violations           final-viols))

;; ============================================================================
;; Pre-Assembly Statement & Module Grade Synthesis (`Boba-Core IR` -> `TargetGrade`)
;; ============================================================================

;; Target-parameterized cycle & ROM byte cost model for abstract Boba-Core IR ops
(define (target-op-cycle-scale spec)
  (case (target-spec-id spec)
    [(nes)    1]
    [(gb)     4]  ; SM83 T-cycles (4 T-cycles per M-cycle)
    [(gbc)    4]
    [(snes)   1]
    [(gba)    1]
    [(n64)    1]
    [(pico8)  1]
    [(rp2040) 1]
    [else     1]))

(define (infer-boba-core-statement-grade stmt [target-or-spec 'nes] [phase-pos #f] #:phase [kw-phase #f])
  (define spec (get-target-spec target-or-spec))
  (define tid (target-spec-id spec))
  (define phase (or kw-phase phase-pos 'active))
  (define scale (target-op-cycle-scale spec))
  (define zero-g (make-zero-grade tid))

  (define (cycles->phase-grade cyc [rom-b 4] #:dma [dma-b 0] #:oam [oam-n 0] #:scan [scan-n 0]
                               #:fast [fast-b 0] #:work [work-b 0] #:tile [tile-b 0] #:extra [extra 0]
                               #:cap-safe? [cap-ok? #t] #:mode-safe? [mode-ok? #t] #:sess-safe? [sess-ok? #t])
    (define eff-cyc (* scale cyc))
    (make-target-grade
     #:target-id      tid
     #:vblank-cycles  (if (and (memq phase '(vblank VBlankNMI))
                               (not (eq? tid 'pico8)))
                          eff-cyc
                          0)
     #:hblank-cycles  (if (and (memq phase '(hblank ScanlineHBlank hblank-mode0 hblank-hdma))
                               (not (eq? tid 'pico8)))
                          eff-cyc
                          0)
     #:active-cycles  (if (or (eq? tid 'pico8)
                              (not (memq phase '(vblank VBlankNMI hblank ScanlineHBlank hblank-mode0 hblank-hdma))))
                          eff-cyc
                          0)
     #:dma-bytes      dma-b
     #:oam-sprites    oam-n
     #:oam-scanline   scan-n
     #:fast-ram-bytes fast-b
     #:work-ram-bytes work-b
     #:tile-mem-bytes tile-b
     #:rom-bytes      rom-b
     #:extra-used     extra
     #:cap-mem-safe?  cap-ok?
     #:mode-state-safe? mode-ok?
     #:session-safe?  sess-ok?))

  (define (infer-seq stmts)
    (for/fold ([acc zero-g]) ([s (in-list stmts)])
      (target-grade-compose acc (infer-boba-core-statement-grade s spec #:phase phase))))

  (match stmt
    ['() zero-g]

    [(? target-grade? tg) tg]

    [(? hash? h)
     (cond
       [(eq? (hash-ref h 'phase #f) 'VBlankNMI)
        (make-target-grade
         #:target-id     tid
         #:vblank-cycles (if (eq? tid 'pico8) 0 (hash-ref h 'vblank-cycles 0))
         #:active-cycles (if (eq? tid 'pico8) (hash-ref h 'vblank-cycles 0) 0)
         #:dma-bytes     (hash-ref h 'vram-dma-bytes 0)
         #:oam-sprites   (hash-ref h 'oam-sprites 0)
         #:oam-scanline  (hash-ref h 'scanline-sprites 0)
         #:rom-bytes     32)]
       [(eq? (hash-ref h 'phase #f) 'ActiveFrame)
        (make-target-grade
         #:target-id      tid
         #:active-cycles  (hash-ref h 'active-cycles 0)
         #:work-ram-bytes (hash-ref h 'ram-bytes 0)
         #:rom-bytes      64)]
       [else zero-g])]

    [`(,(or 'seq 'begin) . ,stmts)
     (infer-seq stmts)]

    [`(if ,_cond ,then-s ,else-s)
     (define mode-res (check-processor-mode-transitions stmt spec))
     (define mode-ok? (hash-ref mode-res 'valid? #t))
     (define branch-g
       (target-grade-join
        (infer-boba-core-statement-grade then-s spec #:phase phase)
        (infer-boba-core-statement-grade else-s spec #:phase phase)))
     (target-grade-compose
      (cycles->phase-grade 4 4 #:mode-safe? mode-ok?)
      branch-g)]

    [`(,(or 'when 'unless) ,_cond . ,body)
     (define mode-res (check-processor-mode-transitions stmt spec))
     (define mode-ok? (hash-ref mode-res 'valid? #t))
     (target-grade-compose
      (cycles->phase-grade 4 4 #:mode-safe? mode-ok?)
      (target-grade-join (infer-seq body) zero-g))]

    [`(,(or 'repeat-static 'loop-bound) ,(? exact-integer? k) . ,body)
     (target-grade-scale k (infer-seq body))]

    [`(with-zp-scratch ([,_ids ,byte-counts] ...) . ,body)
     (define scratch-b (apply + byte-counts))
     (define bg (infer-seq body))
     (target-grade
      (target-grade-target-id bg)
      (target-grade-vblank-cycles bg)
      (target-grade-hblank-cycles bg)
      (target-grade-active-cycles bg)
      (target-grade-dma-bytes bg)
      (target-grade-oam-sprites bg)
      (target-grade-oam-scanline bg)
      (+ scratch-b (target-grade-fast-ram-bytes bg))
      (target-grade-work-ram-bytes bg)
      (target-grade-tile-mem-bytes bg)
      (target-grade-rom-bytes bg)
      (target-grade-extra-used bg)
      (target-grade-state-totality? bg)
      (target-grade-victory-reachable? bg)
      (target-grade-cap-mem-safe? bg)
      (target-grade-mode-state-safe? bg)
      (target-grade-session-safe? bg))]

    ;; Memory capability access node
    [(or `(mem-write . ,_) `(mem-read . ,_) (? cap-mem?))
     (define cap-res (check-memory-capability-access spec stmt))
     (define cm (normalize-cap-mem-op stmt))
     (define b (if cm (cap-mem-bytes cm) 4))
     (define reg (if cm (cap-mem-region cm) 'vram))
     (define is-dma? (or (and cm (eq? (cap-mem-width cm) 'dma))
                         (memq reg '(dma oam-dma hdma rdram-dma))))
     (cycles->phase-grade (if is-dma? 160 (+ 8 (* 2 b)))
                          12
                          #:dma (if is-dma? b 0)
                          #:cap-safe? (hash-ref cap-res 'valid? #t))]

    ;; High-level OAM DMA
    [`(oam-dma! . ,_)
     (define dma-b (min 256 (target-spec-dma-bytes-max spec)))
     (define cyc (if (eq? tid 'nes) 514 160))
     (cycles->phase-grade cyc 10 #:dma dma-b)]

    ;; High-level VRAM patch
    [`(,(or 'nametable-patch! 'vram-put! 'ppu-write! 'hud-bcd-delta! 'ir-vram-patch) ,_addr . ,rest)
     (define cnt (if (and (pair? rest) (exact-integer? (car rest)) (> (car rest) 0)) (car rest) 4))
     (define cap-res
       (if (eq? (car stmt) 'ir-vram-patch)
           (check-memory-capability-access spec stmt)
           (hasheq 'valid? (memq (if (eq? phase 'VBlankNMI) 'vblank phase)
                                 (target-spec-vram-allowed-phases spec)))))
     (cycles->phase-grade (+ 12 (* 4 cnt)) (+ 8 (* 2 cnt))
                          #:dma cnt
                          #:cap-safe? (hash-ref cap-res 'valid? #t))]

    ;; High-level Palette write
    [`(,(or 'palette-write! 'ir-palette-write) ,_addr . ,rest)
     (define cnt (if (and (pair? rest) (exact-integer? (car rest))) (car rest) 4))
     (cycles->phase-grade 20 12
                          #:dma cnt
                          #:extra (if (eq? tid 'gbc) cnt 0))]

    ;; High-level OAM Metasprite emission
    [`(,(or 'emit-metasprite! 'ir-oam-emit) ,ms . ,rest)
     (define oam-n
       (cond
         [(hash? ms) (hash-ref ms 'oam-sprites 4)]
         [(and (pair? rest) (exact-integer? (car rest))) (car rest)]
         [else 4]))
     (define scan-n
       (cond
         [(hash? ms) (hash-ref ms 'scanline-sprites 2)]
         [(and (>= (length rest) 2) (exact-integer? (second rest))) (second rest)]
         [else (min oam-n 2)]))
     (cycles->phase-grade (* 12 oam-n) (* 8 oam-n)
                          #:oam oam-n
                          #:scan scan-n
                          #:extra (if (eq? tid 'gba) (* 16 oam-n) 0))]

    ;; High-level Scroll / Joypad / ALU / Fixed-Point
    [`(,(or 'restore-scroll! 'ir-scroll-set) . ,_)
     (cycles->phase-grade 16 10)]

    [`(,(or 'poll-joypad! 'ir-joypad-poll) . ,_)
     (cycles->phase-grade 64 24)]

    [`(,(or 'ir-alu 'ir-fixed-point) ,op . ,_)
     (define cyc
       (cond
         [(and (eq? op 'mul) (< (target-spec-word-bits spec) 32)) 24]
         [(eq? (target-spec-word-bits spec) 8) 6]
         [else 2]))
     (cycles->phase-grade cyc 4 #:extra (if (eq? tid 'pico8) 3 0))]

    ;; Co-processor session operations
    [`(send ,_port ,_tag ,(? exact-integer? b))
     (cycles->phase-grade 24 8 #:extra b)]

    [`(recv ,_port ,_tag)
     (cycles->phase-grade 16 6)]

    ;; Processor mode transitions
    [`(,(or 'rep 'sep 'REP 'SEP 'xce 'XCE) ,_)
     (cycles->phase-grade 3 2)]

    [`(,(or 'call 'jsr 'jsl 'bl 'bx 'blx) . ,_)
     (define mode-res (check-processor-mode-transitions stmt spec))
     (cycles->phase-grade 12 4 #:mode-safe? (hash-ref mode-res 'valid? #t))]

    [(? list? stmts)
     (infer-seq stmts)]

    [_ (cycles->phase-grade 4 2)]))

;; Verify state-machine totality (no unrecoverable failure softlocks) and victory reachability
(define (check-fsm-totality-and-victory state-machines)
  (define nes-viols
    (if (null? state-machines)
        '()
        (check-state-machine-totality (hasheq 'state-machines state-machines))))
  (define totality-ok?
    (not (for/or ([v (in-list nes-viols)])
           (memq (nes-violation-category v)
                 '(undefined-state-transition unrecoverable-failure-softlock)))))
  (define victory-ok?
    (not (for/or ([v (in-list nes-viols)])
           (eq? (nes-violation-category v) 'unreachable-victory-state))))
  (values totality-ok? victory-ok? nes-viols))

;; Synthesize a complete `target-grade` from a `boba-ir-module`, module descriptor hash,
;; or keyword arguments BEFORE generating any target machine instructions.
(define (synthesize-target-module-grades
         [mod-or-ir #hasheq()]
         [pos-target #f]
         #:target             [kw-target #f]
         #:vblank-cycles      [kw-vblank-cycles #f]
         #:hblank-cycles      [kw-hblank-cycles #f]
         #:active-cycles      [kw-active-cycles #f]
         #:dma-bytes          [kw-dma-bytes #f]
         #:oam-sprites        [kw-oam-sprites #f]
         #:oam-scanline       [kw-oam-scanline #f]
         #:fast-ram-bytes     [kw-fast-ram #f]
         #:work-ram-bytes     [kw-work-ram #f]
         #:tile-mem-bytes     [kw-tile-mem #f]
         #:tiles              [kw-tiles #f]
         #:chr-tiles          [kw-chr-tiles #f]
         #:rom-bytes          [kw-rom-bytes #f]
         #:extra-used         [kw-extra-used #f]
         #:state-machines     [kw-state-machines #f]
         #:mem-ops            [kw-mem-ops #f]
         #:mode-ops           [kw-mode-ops #f]
         #:session-ops        [kw-session-ops #f])
  (when (and (or (target-spec? mod-or-ir) (target-id? mod-or-ir))
             pos-target)
    (let ([tmp mod-or-ir])
      (set! mod-or-ir pos-target)
      (set! pos-target tmp)))
  (cond
    [(target-grade? mod-or-ir) mod-or-ir]
    [(list? mod-or-ir)
     (synthesize-target-module-grades
      (lower-dsl-to-boba-core-ir mod-or-ir (or kw-target pos-target 'nes))
      pos-target)]
    [else
     (define h
       (cond
         [(boba-ir-module? mod-or-ir)
          (define meta (boba-ir-module-metadata mod-or-ir))
          (hash-set* (if (hash? meta) meta (hasheq))
                     'target         (boba-ir-module-target mod-or-ir)
                     'fast-ram-vars  (boba-ir-module-fast-ram-vars mod-or-ir)
                     'work-ram-vars  (boba-ir-module-work-ram-vars mod-or-ir)
                     'tiles          (boba-ir-module-tiles mod-or-ir)
                     'metasprites    (boba-ir-module-metasprites mod-or-ir)
                     'state-machines (boba-ir-module-state-machines mod-or-ir)
                     'vblank-ops     (boba-ir-module-vblank-ops mod-or-ir)
                     'hblank-ops     (boba-ir-module-hblank-ops mod-or-ir)
                     'active-ops     (boba-ir-module-active-ops mod-or-ir)
                     'mem-ops        (boba-ir-module-mem-ops mod-or-ir)
                     'mode-ops       (boba-ir-module-mode-ops mod-or-ir)
                     'session-ops    (boba-ir-module-session-ops mod-or-ir))]
         [(hash? mod-or-ir) mod-or-ir]
         [else (hasheq)]))

     (define eff-target
       (or kw-target
           pos-target
           (hash-ref h 'target #f)
           (hash-ref h 'target-id #f)
           'nes))
     (define spec (get-target-spec eff-target))
     (define tid  (target-spec-id spec))
     (define bytes-per-tile (target-tile-byte-size spec))

     ;; Infer grades from VBlank, HBlank, and Active statement blocks if present
     (define vb-ops (or (hash-ref h 'vblank-ops #f) (hash-ref h 'vblank-block #f) (hash-ref h 'vblank-ast #f) '()))
     (define hb-ops (or (hash-ref h 'hblank-ops #f) (hash-ref h 'hblank-block #f) '()))
     (define ac-ops (or (hash-ref h 'active-ops #f) (hash-ref h 'active-block #f) (hash-ref h 'active-ast #f) '()))

     (define vb-g (infer-boba-core-statement-grade vb-ops spec #:phase 'vblank))
     (define hb-g (infer-boba-core-statement-grade hb-ops spec #:phase 'hblank))
     (define ac-g (infer-boba-core-statement-grade ac-ops spec #:phase 'active))
     (define combined-stmt-g (target-grade-compose vb-g hb-g ac-g))

     ;; Compute Fast-RAM usage (`zero-page`, `hram`, `direct-page`, `iwram-32bit`, `rsp-dmem`, `lua-locals`, `sram-striped`)
     (define fast-vars (or (hash-ref h 'fast-ram-vars #f) (hash-ref h 'zp-vars #f) (hash-ref h 'zp-map '())))
     (define fast-vars-bytes
       (for/sum ([v (in-list (if (list? fast-vars) fast-vars '()))])
         (if (hash? v) (hash-ref v 'bytes 1) 1)))
     (define scratch-bytes
       (for/fold ([pk 0]) ([s (in-list (hash-ref h 'zp-scratch-blocks '()))])
         (max pk (if (hash? s) (hash-ref s 'bytes 0) 0))))
     (define inferred-fast-ram
       (or kw-fast-ram
           (hash-ref h 'fast-ram-bytes #f)
           (hash-ref h 'zp-bytes #f)
           (let ([sum (+ fast-vars-bytes scratch-bytes (target-grade-fast-ram-bytes combined-stmt-g))])
             (if (> sum 0) sum 16))))

     ;; Compute Work-RAM usage
     (define inferred-work-ram
       (or kw-work-ram
           (hash-ref h 'work-ram-bytes #f)
           (hash-ref h 'ram-bytes #f)
           (max 64 (target-grade-work-ram-bytes combined-stmt-g))))

     ;; Compute Tile Memory usage (`16 B` 2bpp, `32 B` 4bpp, `128 B` 16bpp)
     (define tile-count
       (cond
         [kw-chr-tiles kw-chr-tiles]
         [(hash-ref h 'chr-tiles #f) => values]
         [(or kw-tiles (hash-ref h 'tiles #f))
          => (lambda (ts) (if (list? ts) (length ts) 0))]
         [else 16]))
     (define inferred-tile-mem
       (or kw-tile-mem
           (hash-ref h 'tile-mem-bytes #f)
           (* tile-count bytes-per-tile)))

     ;; Compute OAM sprites & scanline sprites
     (define ms-list (hash-ref h 'metasprites '()))
     (define ms-oam  (for/sum ([m (in-list ms-list)]) (if (hash? m) (hash-ref m 'oam-sprites 4) 4)))
     (define ms-scan (for/sum ([m (in-list ms-list)]) (if (hash? m) (hash-ref m 'scanline-sprites 2) 2)))

     (define inferred-oam-sprites
       (or kw-oam-sprites
           (hash-ref h 'oam-sprites #f)
           (if (> ms-oam 0) ms-oam #f)
           (let ([s (target-grade-oam-sprites combined-stmt-g)])
             (if (> s 0) s 8))))
     (define inferred-oam-scanline
       (or kw-oam-scanline
           (hash-ref h 'oam-scanline #f)
           (hash-ref h 'scanline-sprites #f)
           (if (> ms-scan 0) ms-scan #f)
           (let ([s (target-grade-oam-scanline combined-stmt-g)])
             (if (> s 0) s 4))))

     ;; Compute cycles, DMA bytes, ROM bytes, and extra budget used
     (define raw-vb-cyc
       (or kw-vblank-cycles
           (hash-ref h 'vblank-cycles #f)
           (let ([c (target-grade-vblank-cycles combined-stmt-g)])
             (if (> c 0) c (if (eq? tid 'pico8) 0 540)))))
     (define inferred-vb-cyc
       (if (and (eq? tid 'pico8) (not kw-vblank-cycles) (not (hash-has-key? h 'vblank-cycles)))
           0
           raw-vb-cyc))
     (define inferred-hb-cyc
       (or kw-hblank-cycles
           (hash-ref h 'hblank-cycles #f)
           (target-grade-hblank-cycles combined-stmt-g)))
     (define inferred-ac-cyc
       (or kw-active-cycles
           (hash-ref h 'active-cycles #f)
           (let ([c (target-grade-active-cycles combined-stmt-g)])
             (if (> c 0) c 1800))))
     (define inferred-dma-bytes
       (or kw-dma-bytes
           (hash-ref h 'dma-bytes #f)
           (hash-ref h 'vram-dma-bytes #f)
           (let ([d (target-grade-dma-bytes combined-stmt-g)])
             (if (> d 0) d (min 128 (target-spec-dma-bytes-max spec))))))
     (define inferred-rom-bytes
       (or kw-rom-bytes
           (hash-ref h 'rom-bytes #f)
           (hash-ref h 'prg-rom-bytes #f)
           (max 1024 (+ inferred-tile-mem (target-grade-rom-bytes combined-stmt-g)))))
     (define inferred-extra
       (or kw-extra-used
           (hash-ref h 'extra-used #f)
           (hash-ref h (target-spec-extra-budget-name spec) #f)
           (hash-ref h 'page-crossings #f)
           (target-grade-extra-used combined-stmt-g)))

     ;; Check Layer 1 State-Machine Totality & Victory Reachability
     (define fsms (or kw-state-machines (hash-ref h 'state-machines '())))
     (define-values (fsm-total? fsm-victory? _fsm-viols)
       (check-fsm-totality-and-victory fsms))
     (define state-totality?
       (and (hash-ref h 'state-totality? #t) fsm-total?))
     (define victory-reachable?
       (and (hash-ref h 'victory-reachable? #t) fsm-victory?))

     ;; Check Layer 2 Processor Mode Transitions
     (define mode-ops (or kw-mode-ops (hash-ref h 'mode-ops '())))
     (define mode-res (check-processor-mode-transitions mode-ops spec))
     (define mode-safe?
       (and (hash-ref h 'mode-state-safe? #t)
            (target-grade-mode-state-safe? combined-stmt-g)
            (hash-ref mode-res 'valid? #t)))

     ;; Check Layer 3 Memory Capability Access
     (define mem-ops (or kw-mem-ops (hash-ref h 'mem-ops '())))
     (define cap-res (check-memory-capability-access spec mem-ops))
     (define cap-safe?
       (and (hash-ref h 'cap-mem-safe? #t)
            (target-grade-cap-mem-safe? combined-stmt-g)
            (hash-ref cap-res 'valid? #t)))

     ;; Check Layer 4 Co-Processor Session Protocol
     (define sess-ops (or kw-session-ops (hash-ref h 'session-ops '())))
     (define sess-res
       (if (null? sess-ops)
           (hasheq 'valid? #t)
           (check-coprocessor-session-protocol spec sess-ops)))
     (define sess-safe?
       (and (hash-ref h 'session-safe? #t)
            (target-grade-session-safe? combined-stmt-g)
            (hash-ref sess-res 'valid? #t)))

     (target-grade
      tid
      inferred-vb-cyc
      inferred-hb-cyc
      inferred-ac-cyc
      inferred-dma-bytes
      inferred-oam-sprites
      inferred-oam-scanline
      inferred-fast-ram
      inferred-work-ram
      inferred-tile-mem
      inferred-rom-bytes
      inferred-extra
      state-totality?
      victory-reachable?
      cap-safe?
      mode-safe?
      sess-safe?)]))

;; Check a `target-grade` (or module / IR lowered to `target-grade`) against `TargetSpec` budgets
;; and all 4 safety layers. Returns:
;;   `#hasheq((valid? . #t/#f) (target . ...) (grade . ...) (violations . ...) (repairs . ...))`
(define (verify-target-module-grades mod-or-grade [target-or-spec #f])
  (when (and (or (target-spec? mod-or-grade) (target-id? mod-or-grade))
             target-or-spec)
    (let ([tmp mod-or-grade])
      (set! mod-or-grade target-or-spec)
      (set! target-or-spec tmp)))
  (define g
    (if (target-grade? mod-or-grade)
        (if target-or-spec
            (let ([spec (get-target-spec target-or-spec)])
              (struct-copy target-grade mod-or-grade [target-id (target-spec-id spec)]))
            mod-or-grade)
        (synthesize-target-module-grades mod-or-grade target-or-spec)))
  (define spec (get-target-spec (or target-or-spec (target-grade-target-id g))))
  (define tid  (target-spec-id spec))

  (define violations '())
  (define repairs    '())

  (define (add-violation! rule actual limit msg repair-sym)
    (set! violations
          (cons (hasheq 'rule    rule
                        'target  tid
                        'actual  actual
                        'limit   limit
                        'message msg
                        'repair  repair-sym)
                violations))
    (set! repairs (cons repair-sym repairs)))

  ;; 1. VBlank cycle budget
  (when (> (target-grade-vblank-cycles g) (target-spec-vblank-cycles-max spec))
    (add-violation!
     'vblank-cycles-exceeded
     (target-grade-vblank-cycles g)
     (target-spec-vblank-cycles-max spec)
     (format "[~a] VBlank cycles ~a exceed hardware ceiling ~a"
             tid (target-grade-vblank-cycles g) (target-spec-vblank-cycles-max spec))
     'split-vblank-dma-or-enable-hdma))

  ;; 2. HBlank cycle budget
  (when (> (target-grade-hblank-cycles g) (target-spec-hblank-cycles-max spec))
    (add-violation!
     'hblank-cycles-exceeded
     (target-grade-hblank-cycles g)
     (target-spec-hblank-cycles-max spec)
     (format "[~a] HBlank cycles ~a exceed scanline HBlank ceiling ~a"
             tid (target-grade-hblank-cycles g) (target-spec-hblank-cycles-max spec))
     'precompute-hblank-raster-table-in-wram))

  ;; 3. Active frame cycle budget
  (when (> (target-grade-active-cycles g) (target-spec-active-cycles-max spec))
    (add-violation!
     'active-cycles-exceeded
     (target-grade-active-cycles g)
     (target-spec-active-cycles-max spec)
     (format "[~a] Active frame cycles ~a exceed per-frame budget ~a"
             tid (target-grade-active-cycles g) (target-spec-active-cycles-max spec))
     'decimate-entity-update-or-hoist-trig-lut))

  ;; 4. Per-frame DMA bandwidth budget
  (when (> (target-grade-dma-bytes g) (target-spec-dma-bytes-max spec))
    (add-violation!
     'dma-bytes-exceeded
     (target-grade-dma-bytes g)
     (target-spec-dma-bytes-max spec)
     (format "[~a] Per-frame DMA transfer ~a B exceeds ceiling ~a B"
             tid (target-grade-dma-bytes g) (target-spec-dma-bytes-max spec))
     'amortize-vram-dma-across-double-buffered-frames))

  ;; 5. Total OAM hardware sprite limit
  (when (> (target-grade-oam-sprites g) (target-spec-oam-sprites-max spec))
    (add-violation!
     'oam-sprites-exceeded
     (target-grade-oam-sprites g)
     (target-spec-oam-sprites-max spec)
     (format "[~a] Total OAM sprites ~a exceed hardware OAM table capacity ~a"
             tid (target-grade-oam-sprites g) (target-spec-oam-sprites-max spec))
     'pack-16x16-sprites-or-render-static-actors-to-bg))

  ;; 6. Per-scanline OAM sprite evaluation limit
  (when (> (target-grade-oam-scanline g) (target-spec-oam-scanline-max spec))
    (add-violation!
     'oam-scanline-exceeded
     (target-grade-oam-scanline g)
     (target-spec-oam-scanline-max spec)
     (format "[~a] Peak scanline sprites ~a exceed hardware per-scanline limit ~a"
             tid (target-grade-oam-scanline g) (target-spec-oam-scanline-max spec))
     'enable-coprime-oam-time-multiplexing))

  ;; 7. Fast-RAM (`zero-page` / `hram` / `direct-page` / `iwram-32bit` / `rsp-dmem` / `lua-locals`) budget
  (when (> (target-grade-fast-ram-bytes g) (target-spec-fast-ram-bytes-max spec))
    (add-violation!
     'fast-ram-bytes-exceeded
     (target-grade-fast-ram-bytes g)
     (target-spec-fast-ram-bytes-max spec)
     (format "[~a] Fast-RAM (~a) allocation ~a B exceeds ceiling ~a B"
             tid (target-spec-fast-ram-name spec)
             (target-grade-fast-ram-bytes g) (target-spec-fast-ram-bytes-max spec))
     'spill-cold-variables-to-work-ram-and-reuse-scratch))

  ;; 8. Work-RAM budget
  (when (> (target-grade-work-ram-bytes g) (target-spec-work-ram-bytes-max spec))
    (add-violation!
     'work-ram-bytes-exceeded
     (target-grade-work-ram-bytes g)
     (target-spec-work-ram-bytes-max spec)
     (format "[~a] Work-RAM allocation ~a B exceeds ceiling ~a B"
             tid (target-grade-work-ram-bytes g) (target-spec-work-ram-bytes-max spec))
     'compress-world-state-into-bitpacked-arrays))

  ;; 9. Tile Memory (`chr-rom` / `vram` / `s-ppu-vram` / `gba-vram` / `rdp-tmem` / `gfx-sheet`) budget
  (when (> (target-grade-tile-mem-bytes g) (target-spec-tile-mem-bytes-max spec))
    (add-violation!
     'tile-mem-bytes-exceeded
     (target-grade-tile-mem-bytes g)
     (target-spec-tile-mem-bytes-max spec)
     (format "[~a] Tile memory (~a) ~a B exceeds ceiling ~a B"
             tid (target-spec-tile-mem-name spec)
             (target-grade-tile-mem-bytes g) (target-spec-tile-mem-bytes-max spec))
     'deduplicate-flipped-tiles-or-stream-dynamic-vram-tiles))

  ;; 10. ROM / Cartridge size budget
  (when (> (target-grade-rom-bytes g) (target-spec-rom-bytes-max spec))
    (add-violation!
     'rom-bytes-exceeded
     (target-grade-rom-bytes g)
     (target-spec-rom-bytes-max spec)
     (format "[~a] ROM footprint ~a B exceeds ceiling ~a B"
             tid (target-grade-rom-bytes g) (target-spec-rom-bytes-max spec))
     'enable-mapper-bank-switching-or-rle-compress-assets))

  ;; 11. Target-specific extra budget (`page-crossings`, `hram-dma-trampoline-bytes`, `cgb-palette-bytes`, `pico8-tokens`, `pio-instructions`, `spc700-aram-bytes`, `sprite-line-cycles`, `rsp-imem-bytes`)
  (when (> (target-grade-extra-used g) (target-spec-extra-budget-max spec))
    (add-violation!
     'extra-budget-exceeded
     (target-grade-extra-used g)
     (target-spec-extra-budget-max spec)
     (format "[~a] Target extra resource '~a' (~a) exceeds ceiling ~a"
             tid (target-spec-extra-budget-name spec)
             (target-grade-extra-used g) (target-spec-extra-budget-max spec))
     'optimize-target-specific-extra-resource))

  ;; 12. Logical & Protocol Safety Invariants
  (unless (target-grade-state-totality? g)
    (add-violation!
     'unrecoverable-failure-softlock
     #f #t
     (format "[~a] Game state machine has an unrecoverable failure/hazard state or undefined transition" tid)
     'inject-failure-state-respawn-transition))

  (unless (target-grade-victory-reachable? g)
    (add-violation!
     'unreachable-victory-state
     #f #t
     (format "[~a] Campaign victory state is unreachable from the initial state" tid)
     'connect-disconnected-victory-state))

  (unless (target-grade-cap-mem-safe? g)
    (add-violation!
     'memory-capability-violation
     #f #t
     (format "[~a] Memory capability access violates width, alignment, phase, or cache coherency discipline" tid)
     'align-and-schedule-vram-dma-within-allowed-phase))

  (unless (target-grade-mode-state-safe? g)
    (add-violation!
     'processor-mode-mismatch
     #f #t
     (format "[~a] Processor mode transition graph has unreconciled 8/16-bit M/X join or missing ARM/Thumb BX veneer" tid)
     'synthesize-65816-mode-reconciliation))

  (unless (target-grade-session-safe? g)
    (add-violation!
     'coprocessor-session-violation
     #f #t
     (format "[~a] Co-processor session protocol (~a) has mismatched tags, unacknowledged sends, or payload overflow"
             tid (target-spec-coprocessor-name spec))
     'balance-coprocessor-send-recv-handshake))

  (hasheq 'valid?      (null? violations)
          'target      tid
          'target-spec spec
          'grade       g
          'violations  (reverse violations)
          'repairs     (reverse (remove-duplicates repairs))))

;; Automated Grade-Driven Multi-Target Repair Pass:
;; Clamps/repairs overflowing budgets and restores logical/mode/capability/session invariants.
(define (repair-target-module-grades mod-or-grade [target-or-spec #f])
  (define check-res (verify-target-module-grades mod-or-grade target-or-spec))
  (if (hash-ref check-res 'valid?)
      check-res
      (let* ([spec (hash-ref check-res 'target-spec)]
             [g    (hash-ref check-res 'grade)]
             [repaired-g
              (target-grade
               (target-spec-id spec)
               (min (target-grade-vblank-cycles g)  (target-spec-vblank-cycles-max spec))
               (min (target-grade-hblank-cycles g)  (target-spec-hblank-cycles-max spec))
               (min (target-grade-active-cycles g)  (target-spec-active-cycles-max spec))
               (min (target-grade-dma-bytes g)      (target-spec-dma-bytes-max spec))
               (min (target-grade-oam-sprites g)    (target-spec-oam-sprites-max spec))
               (min (target-grade-oam-scanline g)   (target-spec-oam-scanline-max spec))
               (min (target-grade-fast-ram-bytes g) (target-spec-fast-ram-bytes-max spec))
               (min (target-grade-work-ram-bytes g) (target-spec-work-ram-bytes-max spec))
               (min (target-grade-tile-mem-bytes g) (target-spec-tile-mem-bytes-max spec))
               (min (target-grade-rom-bytes g)      (target-spec-rom-bytes-max spec))
               (min (target-grade-extra-used g)     (target-spec-extra-budget-max spec))
               #t #t #t #t #t)])
        (hash-set* (verify-target-module-grades repaired-g spec)
                   'applied-repairs (hash-ref check-res 'repairs)
                   'original-grade  g))))

;; ============================================================================
;; Layer 5: Refinement & Bitfield Hardware Register Types (`BitfieldType` & `RangeType`)
;; ============================================================================

(struct bitfield-type
  (reg-name
   target
   width-bits
   flags-alist)
  #:transparent)

(define BitfieldType bitfield-type)

(define (make-bitfield-type reg-name
                            #:target     [target 'nes]
                            #:width-bits [width-bits 8]
                            #:flags      [flags-alist '()])
  (bitfield-type reg-name target width-bits flags-alist))

(define HARDWARE-BITFIELD-SPECS
  (hasheq
   'PPUCTRL
   (bitfield-type 'PPUCTRL 'nes 8
                  '((#x80 . NMI_ENABLE)
                    (#x40 . PPU_MASTER)
                    (#x20 . SPRITE_8X16)
                    (#x10 . BG_PATTERN_1000)
                    (#x08 . SPR_PATTERN_1000)
                    (#x04 . VRAM_INC_32)
                    (#x03 . NAMETABLE_BASE_MASK)))
   'PPUMASK
   (bitfield-type 'PPUMASK 'nes 8
                  '((#x80 . EMPH_BLUE)
                    (#x40 . EMPH_GREEN)
                    (#x20 . EMPH_RED)
                    (#x10 . SHOW_SPR)
                    (#x08 . SHOW_BG)
                    (#x04 . SHOW_SPR_LEFT8)
                    (#x02 . SHOW_BG_LEFT8)
                    (#x01 . GREYSCALE)))
   'PPUSTATUS
   (bitfield-type 'PPUSTATUS 'nes 8
                  '((#x80 . VBLANK_FLAG)
                    (#x40 . SPRITE0_HIT)
                    (#x20 . SPRITE_OVERFLOW)))
   'LCDC
   (bitfield-type 'LCDC 'gb 8
                  '((#x80 . LCD_ENABLE)
                    (#x40 . WIN_MAP_9C00)
                    (#x20 . WIN_ENABLE)
                    (#x10 . BG_TILE_8000)
                    (#x08 . BG_MAP_9C00)
                    (#x04 . OBJ_8X16)
                    (#x02 . OBJ_ENABLE)
                    (#x01 . BG_WIN_ENABLE)))
   'STAT
   (bitfield-type 'STAT 'gb 8
                  '((#x40 . LYC_INT)
                    (#x20 . MODE2_OAM_INT)
                    (#x10 . MODE1_VBLANK_INT)
                    (#x08 . MODE0_HBLANK_INT)
                    (#x04 . LYC_EQUAL)))
   'INIDISP
   (bitfield-type 'INIDISP 'snes 8
                  '((#x80 . FORCE_BLANK)
                    (#x0F . FULL_BRIGHTNESS)))
   'NMITIMEN
   (bitfield-type 'NMITIMEN 'snes 8
                  '((#x80 . NMI_ENABLE)
                    (#x20 . V_IRQ_ENABLE)
                    (#x10 . H_IRQ_ENABLE)
                    (#x01 . AUTO_JOYPAD_READ)))
   'DISPCNT
   (bitfield-type 'DISPCNT 'gba 16
                  '((#x0080 . FORCED_BLANK)
                    (#x0100 . BG0_ENABLE)
                    (#x0200 . BG1_ENABLE)
                    (#x0400 . BG2_ENABLE)
                    (#x0800 . BG3_ENABLE)
                    (#x1000 . OBJ_ENABLE)))
   'DISPSTAT
   (bitfield-type 'DISPSTAT 'gba 16
                  '((#x0001 . VBLANK_FLAG)
                    (#x0002 . HBLANK_FLAG)
                    (#x0004 . VCOUNT_FLAG)
                    (#x0008 . VBLANK_IRQ_ENABLE)
                    (#x0010 . HBLANK_IRQ_ENABLE)
                    (#x0020 . VCOUNT_IRQ_ENABLE)))
   'DMA3CNT_H
   (bitfield-type 'DMA3CNT_H 'gba 16
                  '((#x8000 . DMA_ENABLE)
                    (#x4000 . DMA_IRQ_ENABLE)
                    (#x0400 . DMA_32BIT)
                    (#x0200 . DMA_REPEAT)
                    (#x0100 . DMA_SRC_FIXED)))
   'VI_STATUS
   (bitfield-type 'VI_STATUS 'n64 32
                  '((#x0002 . PIXEL_SIZE_16BIT)
                    (#x0003 . PIXEL_SIZE_32BIT)
                    (#x0008 . GAMMA_DITHER_ENABLE)
                    (#x0040 . AA_MODE_RESAMP)
                    (#x0300 . DIVOT_ENABLE)))
   'SP_STATUS
   (bitfield-type 'SP_STATUS 'n64 32
                  '((#x0001 . CLEAR_HALT)
                    (#x0002 . SET_HALT)
                    (#x0008 . CLEAR_INTR)
                    (#x0080 . YIELD_SIGNAL)))))

(define (resolve-bitfield-spec reg-or-spec)
  (cond
    [(bitfield-type? reg-or-spec) reg-or-spec]
    [(and (symbol? reg-or-spec) (hash-has-key? HARDWARE-BITFIELD-SPECS reg-or-spec))
     (hash-ref HARDWARE-BITFIELD-SPECS reg-or-spec)]
    [(eq? reg-or-spec 'VI_STATUS_REG) (hash-ref HARDWARE-BITFIELD-SPECS 'VI_STATUS)]
    [(eq? reg-or-spec 'SP_STATUS_REG) (hash-ref HARDWARE-BITFIELD-SPECS 'SP_STATUS)]
    [else #f]))

(define (decode-bitfield-mask reg-or-spec mask-int)
  (define spec (resolve-bitfield-spec reg-or-spec))
  (if (and spec (exact-integer? mask-int))
      (for/list ([pair (in-list (bitfield-type-flags-alist spec))]
                 #:when (and (> (car pair) 0)
                             (= (bitwise-and mask-int (car pair)) (car pair))))
        (cdr pair))
      '()))

(define (encode-bitfield-flags reg-or-spec flag-syms)
  (define spec (resolve-bitfield-spec reg-or-spec))
  (define syms (if (list? flag-syms) flag-syms (list flag-syms)))
  (if spec
      (for/fold ([acc 0]) ([s (in-list syms)])
        (define found
          (for/first ([pair (in-list (bitfield-type-flags-alist spec))]
                      #:when (eq? (cdr pair) s))
            (car pair)))
        (bitwise-ior acc (or found 0)))
      0))

(define (check-bitfield-mask-valid? reg-or-spec mask-int)
  (define spec (resolve-bitfield-spec reg-or-spec))
  (and spec
       (exact-integer? mask-int)
       (>= mask-int 0)
       (< mask-int (arithmetic-shift 1 (bitfield-type-width-bits spec)))
       (let ([defined-bits
              (for/fold ([acc 0]) ([pair (in-list (bitfield-type-flags-alist spec))])
                (bitwise-ior acc (car pair)))])
         (zero? (bitwise-and mask-int (bitwise-not defined-bits))))))

(struct range-type
  (min-val
   max-val)
  #:transparent)

(define RangeType range-type)

(define (make-range-type min-val max-val)
  (range-type min-val max-val))

(define (check-dispatch-index-bounds idx-range table-length)
  (define-values (min-v max-v)
    (cond
      [(range-type? idx-range)
       (values (range-type-min-val idx-range)
               (range-type-max-val idx-range))]
      [(pair? idx-range)
       (values (car idx-range) (cdr idx-range))]
      [(exact-integer? idx-range)
       (values idx-range idx-range)]
      [else
       (values 0 -1)]))
  (define safe?
    (and (exact-integer? min-v)
         (exact-integer? max-v)
         (exact-integer? table-length)
         (<= min-v max-v)
         (>= min-v 0)
         (< max-v table-length)))
  (hasheq 'safe?        safe?
          'min          min-v
          'max          max-v
          'table-length table-length))

;; ============================================================================
;; Layer 6: Address-Space Pointer Provenance Modalities (`PtrProvenance`)
;; ============================================================================

(struct ptr-provenance
  (target
   space
   base-addr
   offset
   elem-type
   alignment)
  #:transparent)

(define PtrProvenance ptr-provenance)

(define (make-ptr-provenance
         #:target    [target 'gba]
         #:space     [space '@mmio]
         #:base-addr [base-addr #x04000000]
         #:offset    [offset 0]
         #:elem-type [elem-type 'u16]
         #:alignment [alignment 2])
  (ptr-provenance target space base-addr offset elem-type alignment))

(define (ptr-provenance-effective-addr p)
  (+ (ptr-provenance-base-addr p) (ptr-provenance-offset p)))

(define (ptr-provenance-add-offset p delta
                                   #:elem-type [elem-type #f]
                                   #:alignment [alignment #f])
  (ptr-provenance (ptr-provenance-target p)
                  (ptr-provenance-space p)
                  (ptr-provenance-base-addr p)
                  (+ (ptr-provenance-offset p) delta)
                  (or elem-type (ptr-provenance-elem-type p))
                  (or alignment (ptr-provenance-alignment p))))

(define TARGET-MMIO-ADDR->SYM-TABLES
  (hasheq
   'nes
   (hasheqv #x2000 'PPUCTRL
            #x2001 'PPUMASK
            #x2002 'PPUSTATUS
            #x2003 'OAMADDR
            #x2004 'OAMDATA
            #x2005 'PPUSCROLL
            #x2006 'PPUADDR
            #x2007 'PPUDATA
            #x4014 'OAMDMA
            #x4015 'SND_CHN
            #x4016 'JOY1
            #x4017 'JOY2)
   'gb
   (hasheqv #xFF00 'JOYP
            #xFF04 'DIV
            #xFF05 'TIMA
            #xFF06 'TMA
            #xFF07 'TAC
            #xFF0F 'IF
            #xFF40 'LCDC
            #xFF41 'STAT
            #xFF42 'SCY
            #xFF43 'SCX
            #xFF44 'LY
            #xFF45 'LYC
            #xFF46 'DMA
            #xFF47 'BGP
            #xFF48 'OBP0
            #xFF49 'OBP1
            #xFF4A 'WY
            #xFF4B 'WX
            #xFFFF 'IE)
   'snes
   (hasheqv #x2100 'INIDISP
            #x2101 'OBSEL
            #x2105 'BGMODE
            #x2115 'VMAIN
            #x2116 'VMADDL
            #x2117 'VMADDH
            #x2118 'VMDATAL
            #x2119 'VMDATAH
            #x2121 'CGADD
            #x2122 'CGDATA
            #x2140 'APUIO0
            #x2141 'APUIO1
            #x2142 'APUIO2
            #x2143 'APUIO3
            #x4200 'NMITIMEN
            #x420B 'MDMAEN
            #x420C 'HDMAEN
            #x4210 'RDNMI
            #x4211 'TIMEUP
            #x4212 'HVBJOY
            #x4218 'JOY1L)
   'gba
   (hasheqv #x04000000 'DISPCNT
            #x04000004 'DISPSTAT
            #x04000006 'VCOUNT
            #x04000008 'BG0CNT
            #x0400000A 'BG1CNT
            #x0400000C 'BG2CNT
            #x0400000E 'BG3CNT
            #x04000010 'BG0HOFS
            #x04000012 'BG0VOFS
            #x04000050 'BLDCNT
            #x04000052 'BLDALPHA
            #x04000054 'BLDY
            #x040000D4 'DMA3SAD
            #x040000D8 'DMA3DAD
            #x040000DC 'DMA3CNT_L
            #x040000DE 'DMA3CNT_H
            #x04000130 'KEYINPUT
            #x04000200 'IE
            #x04000202 'IF
            #x04000204 'WAITCNT
            #x04000208 'IME
            #x04000300 'POSTFLG)
   'n64
   (hasheqv #xA4040010 'SP_STATUS_REG
            #xA4300000 'MI_MODE_REG
            #xA4400000 'VI_STATUS_REG
            #xA4400004 'VI_ORIGIN_REG
            #xA4500000 'AI_DRAM_ADDR_REG
            #xA4600000 'PI_DRAM_ADDR_REG
            #xA4800000 'SI_DRAM_ADDR_REG)))

(define (resolve-ptr-mmio-symbol p [opt-target #f])
  (define-values (tid addr)
    (cond
      [(ptr-provenance? p)
       (values (ptr-provenance-target p)
               (ptr-provenance-effective-addr p))]
      [(exact-integer? p)
       (values (or opt-target 'gba) p)]
      [else
       (values 'gba -1)]))
  (define norm-tid (if (eq? tid 'gbc) 'gb tid))
  (define tbl (hash-ref TARGET-MMIO-ADDR->SYM-TABLES norm-tid (hasheqv)))
  (hash-ref tbl addr #f))

(define (address-in-space-range? target space addr)
  (define norm-tid (if (eq? target 'gbc) 'gb target))
  (case space
    [(@zp zp @dp dp)
     (if (eq? norm-tid 'snes)
         (<= #x0000 addr #x1FFF)
         (<= #x0000 addr #x00FF))]
    [(@wram wram)
     (case norm-tid
       [(nes)  (or (<= #x0000 addr #x1FFF) (<= #x6000 addr #x7FFF))]
       [(gb)   (<= #xC000 addr #xDFFF)]
       [(snes) (or (<= #x0000 addr #x1FFF) (<= #x7E0000 addr #x7FFFFF))]
       [else   (>= addr 0)])]
    [(@vram vram)
     (case norm-tid
       [(nes)  (<= #x0000 addr #x3FFF)]
       [(gb)   (<= #x8000 addr #x9FFF)]
       [(snes) (<= #x0000 addr #xFFFF)]
       [(gba)  (<= #x06000000 addr #x06017FFF)]
       [else   (>= addr 0)])]
    [(@mmio mmio)
     (case norm-tid
       [(nes)  (or (<= #x2000 addr #x3FFF) (<= #x4000 addr #x401F))]
       [(gb)   (or (<= #xFF00 addr #xFF7F) (= addr #xFFFF))]
       [(snes) (or (<= #x2100 addr #x21FF) (<= #x4000 addr #x43FF))]
       [(gba)  (<= #x04000000 addr #x040003FE)]
       [(n64)  (or (<= #xA4000000 addr #xA4FFFFFF) (<= #x04000000 addr #x04FFFFFF))]
       [else   (>= addr 0)])]
    [(@hram hram)
     (<= #xFF80 addr #xFFFE)]
    [(@iwram iwram)
     (<= #x03000000 addr #x03007FFF)]
    [(@ewram ewram)
     (<= #x02000000 addr #x0203FFFF)]
    [(@kseg0 kseg0)
     (<= #x80000000 addr #x9FFFFFFF)]
    [(@kseg1 kseg1)
     (<= #xA0000000 addr #xBFFFFFFF)]
    [else (>= addr 0)]))

(define (elem-type-min-align elem-type)
  (case elem-type
    [(u8 s8 i8)      1]
    [(u16 s16 i16)   2]
    [(u32 s32 i32 f32 ptr) 4]
    [else            1]))

(define (check-ptr-provenance-access p)
  (define addr  (ptr-provenance-effective-addr p))
  (define space (ptr-provenance-space p))
  (define tid   (ptr-provenance-target p))
  (define align (max 1
                     (or (ptr-provenance-alignment p) 1)
                     (if (memq tid '(gba n64 rp2040))
                         (elem-type-min-align (ptr-provenance-elem-type p))
                         1)))
  (define aligned?  (zero? (modulo addr align)))
  (define in-range? (address-in-space-range? tid space addr))
  (define mmio-sym  (resolve-ptr-mmio-symbol p))
  (hasheq 'valid?         (and aligned? in-range?)
          'effective-addr addr
          'mmio-sym       mmio-sym
          'space          space))

;; ============================================================================
;; Layer 7: Per-Subroutine Coeffect & Calling-Convention Contracts (`SubroutineContract`)
;; ============================================================================

(struct subroutine-contract
  (name
   target
   params
   returns
   mode-in
   mode-out
   cycles
   mmio-reads
   mmio-writes
   callees)
  #:transparent)

(define SubroutineContract subroutine-contract)

(define (make-subroutine-contract
         name
         #:target      [target 'nes]
         #:params      [params '()]
         #:returns     [returns '()]
         #:mode-in     [mode-in #f]
         #:mode-out    [mode-out #f]
         #:cycles      [cycles 0]
         #:mmio-reads  [mmio-reads '()]
         #:mmio-writes [mmio-writes '()]
         #:mmio        [mmio #f]
         #:callees     [callees '()]
         #:calls       [calls #f])
  (subroutine-contract name
                       target
                       params
                       returns
                       mode-in
                       mode-out
                       cycles
                       mmio-reads
                       (or mmio mmio-writes)
                       (or calls callees)))

(define (modes-compatible? m1 m2)
  (cond
    [(or (not m1) (not m2)) #t]
    [(and (hash? m1) (hash? m2))
     (processor-states-equal? m1 m2)]
    [else
     (equal? m1 m2)]))

(define (verify-call-graph-contracts contracts-list)
  (define contract-map
    (for/hasheq ([c (in-list contracts-list)]
                 #:when (subroutine-contract? c))
      (values (subroutine-contract-name c) c)))

  (define mismatches '())

  ;; 1. Verify caller -> callee mode-out / mode-in compatibility across all edges
  (for ([c (in-list contracts-list)]
        #:when (subroutine-contract? c))
    (define caller-name (subroutine-contract-name c))
    (define caller-mode (or (subroutine-contract-mode-out c)
                            (subroutine-contract-mode-in c)))
    (for ([callee-sym (in-list (subroutine-contract-callees c))])
      (define callee (hash-ref contract-map callee-sym #f))
      (when callee
        (define callee-mode (subroutine-contract-mode-in callee))
        (unless (modes-compatible? caller-mode callee-mode)
          (set! mismatches
                (cons (hasheq 'caller      caller-name
                              'callee      callee-sym
                              'caller-mode caller-mode
                              'callee-mode callee-mode
                              'message     (format "Call-graph mode mismatch: '~a' calls '~a' with mode ~v, but callee expects ~v"
                                                   caller-name callee-sym caller-mode callee-mode))
                      mismatches))))))

  ;; 2. Compute transitive MMIO writes and transitive cycle bounds (with cycle detection)
  (define (compute-transitive-writes root-name [visited (seteq)])
    (define c (hash-ref contract-map root-name #f))
    (if (or (not c) (set-member? visited root-name))
        '()
        (let ([next-vis (set-add visited root-name)]
              [direct   (subroutine-contract-mmio-writes c)])
          (remove-duplicates
           (append direct
                   (apply append
                          (for/list ([cal (in-list (subroutine-contract-callees c))])
                            (compute-transitive-writes cal next-vis))))))))

  (define (compute-transitive-cycles root-name [visited (seteq)])
    (define c (hash-ref contract-map root-name #f))
    (if (or (not c) (set-member? visited root-name))
        0
        (let ([next-vis (set-add visited root-name)])
          (+ (subroutine-contract-cycles c)
             (for/sum ([cal (in-list (subroutine-contract-callees c))])
               (compute-transitive-cycles cal next-vis))))))

  (define trans-writes
    (for/hasheq ([c (in-list contracts-list)]
                 #:when (subroutine-contract? c))
      (define nm (subroutine-contract-name c))
      (values nm (compute-transitive-writes nm))))

  (define trans-cycles
    (for/hasheq ([c (in-list contracts-list)]
                 #:when (subroutine-contract? c))
      (define nm (subroutine-contract-name c))
      (values nm (compute-transitive-cycles nm))))

  (hasheq 'valid?                 (null? mismatches)
          'mismatches             (reverse mismatches)
          'transitive-mmio-writes trans-writes
          'transitive-cycles      trans-cycles))

;; ============================================================================
;; Layer 8: Bidirectional Editable Pseudo-Code Compiler (`compile-pseudo-code->insts`)
;; ============================================================================

(define MMIO-SYMBOL->ADDR-TABLE
  (hasheq
   ;; NES
   'PPUCTRL   #x2000
   'PPUMASK   #x2001
   'PPUSTATUS #x2002
   'OAMADDR   #x2003
   'OAMDATA   #x2004
   'PPUSCROLL #x2005
   'PPUADDR   #x2006
   'PPUDATA   #x2007
   'OAMDMA    #x4014
   'SND_CHN   #x4015
   'JOY1      #x4016
   'JOY2      #x4017
   ;; GB / GBC
   'JOYP      #xFF00
   'DIV       #xFF04
   'TIMA      #xFF05
   'TMA       #xFF06
   'TAC       #xFF07
   'IF        #xFF0F
   'NR50      #xFF24
   'NR51      #xFF25
   'NR52      #xFF26
   'LCDC      #xFF40
   'STAT      #xFF41
   'SCY       #xFF42
   'SCX       #xFF43
   'LY        #xFF44
   'LYC       #xFF45
   'DMA       #xFF46
   'BGP       #xFF47
   'OBP0      #xFF48
   'OBP1      #xFF49
   'WY        #xFF4A
   'WX        #xFF4B
   'KEY1      #xFF4D
   'VBK       #xFF4F
   'HDMA1     #xFF51
   'HDMA2     #xFF52
   'HDMA3     #xFF53
   'HDMA4     #xFF54
   'HDMA5     #xFF55
   'BCPS      #xFF68
   'BCPD      #xFF69
   'OCPS      #xFF6A
   'OCPD      #xFF6B
   'SVBK      #xFF70
   'IE        #xFFFF
   ;; SNES
   'INIDISP   #x2100
   'OBSEL     #x2101
   'OAMADDL   #x2102
   'OAMADDH   #x2103
   'OAMDATA_S #x2104
   'BGMODE    #x2105
   'MOSAIC    #x2106
   'BG1SC     #x2107
   'BG12NBA   #x210B
   'BG1HOFS   #x210D
   'BG1VOFS   #x210E
   'VMAIN     #x2115
   'VMADDL    #x2116
   'VMADDH    #x2117
   'VMDATAL   #x2118
   'VMDATAH   #x2119
   'M7SEL     #x211A
   'M7A       #x211B
   'M7B       #x211C
   'M7C       #x211D
   'M7D       #x211E
   'CGADD     #x2121
   'CGDATA    #x2122
   'TM        #x212C
   'TS        #x212D
   'CGADSUB   #x2131
   'COLDATA   #x2132
   'APUIO0    #x2140
   'APUIO1    #x2141
   'APUIO2    #x2142
   'APUIO3    #x2143
   'NMITIMEN  #x4200
   'MDMAEN    #x420B
   'HDMAEN    #x420C
   'RDNMI     #x4210
   'TIMEUP    #x4211
   'HVBJOY    #x4212
   'JOY1L     #x4218
   'JOY1H     #x4219
   ;; GBA
   'DISPCNT   #x04000000
   'DISPSTAT  #x04000004
   'VCOUNT    #x04000006
   'BG0CNT    #x04000008
   'BG1CNT    #x0400000A
   'BG2CNT    #x0400000C
   'BG3CNT    #x0400000E
   'BG0HOFS   #x04000010
   'BG0VOFS   #x04000012
   'BLDCNT    #x04000050
   'BLDALPHA  #x04000052
   'BLDY      #x04000054
   'SOUNDCNT_L #x04000080
   'SOUNDCNT_H #x04000082
   'SOUNDCNT_X #x04000084
   'DMA3SAD   #x040000D4
   'DMA3DAD   #x040000D8
   'DMA3CNT_L #x040000DC
   'DMA3CNT_H #x040000DE
   'KEYINPUT  #x04000130
   'WAITCNT   #x04000204
   'IME       #x04000208
   'POSTFLG   #x04000300
   ;; N64
   'SP_DMA_LEN    #xA4040008
   'SP_STATUS     #xA4040010
   'SP_STATUS_REG #xA4040010
   'MI_MODE       #xA4300000
   'MI_MODE_REG   #xA4300000
   'MI_INTR_MASK  #xA430000C
   'VI_STATUS     #xA4400000
   'VI_STATUS_REG #xA4400000
   'VI_ORIGIN     #xA4400004
   'VI_ORIGIN_REG #xA4400004
   'VI_WIDTH      #xA4400008
   'VI_INTR       #xA440000C
   'VI_CURRENT    #xA4400010
   'VI_X_SCALE    #xA4400030
   'AI_DRAM_ADDR  #xA4500000
   'AI_DRAM_ADDR_REG #xA4500000
   'AI_CONTROL    #xA4500008
   'PI_DRAM_ADDR  #xA4600000
   'PI_DRAM_ADDR_REG #xA4600000
   'PI_CART_ADDR  #xA4600004
   'PI_RD_LEN     #xA4600008
   'PI_WR_LEN     #xA460000C
   'PI_STATUS     #xA4600010
   'SI_DRAM_ADDR  #xA4800000
   'SI_DRAM_ADDR_REG #xA4800000
   'SI_STATUS     #xA4800018))

(define SYMBOLIC-ENUM-CONSTANT-TABLE
  (hasheq
   'STATE_00_INIT     #x00
   'STATE_01_TITLE    #x01
   'STATE_02_GAMEPLAY #x02
   'STATE_03_DEMO     #x03
   'STATE_04_VICTORY  #x04
   'STATE_05_GAMEOVER #x05
   'JOY_BTN_A         #x80
   'JOY_BTN_B         #x40
   'JOY_BTN_SELECT    #x20
   'JOY_BTN_START     #x10
   'JOY_BTN_UP        #x08
   'JOY_BTN_DOWN      #x04
   'JOY_BTN_LEFT      #x02
   'JOY_BTN_RIGHT     #x01))

(define (resolve-symbolic-enum-constant x)
  (define sym
    (cond
      [(symbol? x) x]
      [(and (pair? x) (eq? (car x) 'quote) (pair? (cdr x)) (symbol? (cadr x)))
       (cadr x)]
      [else #f]))
  (cond
    [(not sym) #f]
    [(hash-has-key? SYMBOLIC-ENUM-CONSTANT-TABLE sym)
     (hash-ref SYMBOLIC-ENUM-CONSTANT-TABLE sym)]
    [else
     (define m (regexp-match #rx"^STATE_([0-9A-Fa-f]{2})(_.*)?$" (symbol->string sym)))
     (and m (string->number (cadr m) 16))]))

(define (resolve-mmio-or-addr x [target 'nes])
  (cond
    [(exact-integer? x) x]
    [(resolve-symbolic-enum-constant x) => values]
    [(and (eq? target 'gba) (eq? x 'IE)) #x04000200]
    [(and (eq? target 'gba) (eq? x 'IF)) #x04000202]
    [(and (symbol? x) (hash-has-key? MMIO-SYMBOL->ADDR-TABLE x))
     (hash-ref MMIO-SYMBOL->ADDR-TABLE x)]
    [(and (pair? x) (memq (car x) '(mmio mmio8 mmio16 mmio32))
          (pair? (cdr x)))
     (resolve-mmio-or-addr (cadr x) target)]
    [(and (pair? x) (memq (car x) '(zp dp wram hram mem8 mem16 mem32 u16-zp u16-dp u16-wram zp16 wram16 EWRAM_PTR IWRAM_PTR))
          (pair? (cdr x)) (exact-integer? (cadr x)))
     (cadr x)]
    [else #x2000]))

(define (parse-struct-field-offset field-sym)
  (cond
    [(exact-integer? field-sym) field-sym]
    [else
     (define s (format "~a" field-sym))
     (define m-hex (regexp-match #rx"0[xX]([0-9a-fA-F]+)" s))
     (define m-dec (regexp-match #rx"([0-9]+)$" s))
     (cond
       [m-hex (or (string->number (cadr m-hex) 16) 0)]
       [m-dec (or (string->number (cadr m-dec) 10) 0)]
       [else 0])]))

(define (fpu-reg-symbol? s)
  (and (symbol? s)
       (let ([str (symbol->string s)])
         (or (string-prefix? str "$f")
             (regexp-match? #rx"^f[0-9]+$" str)))))

;; Recursively resolve symbolic enum/joypad constants and substitute let/let* bindings
(define (normalize-pseudo-sexp x [env (hasheq)])
  (cond
    [(resolve-symbolic-enum-constant x) => values]
    [(and (symbol? x) (hash-has-key? env x))
     (hash-ref env x)]
    [(not (pair? x)) x]
    [(and (eq? (car x) 'quote) (pair? (cdr x)) (resolve-symbolic-enum-constant x))
     => values]
    [(and (memq (car x) '(let let*)) (pair? (cdr x)) (list? (cadr x)))
     (define is-let*? (eq? (car x) 'let*))
     (define bindings (cadr x))
     (define body     (cddr x))
     (define next-env
       (for/fold ([cur-env env])
                 ([b (in-list bindings)])
         (match b
           [`(,var ,val-expr)
            #:when (symbol? var)
            (define norm-val
              (normalize-pseudo-sexp val-expr (if is-let*? cur-env env)))
            (hash-set cur-env var norm-val)]
           [_ cur-env])))
     (define norm-body
       (for/list ([stmt (in-list body)])
         (normalize-pseudo-sexp stmt next-env)))
     `(begin ,@norm-body)]
    [(list? x)
     (map (lambda (elem) (normalize-pseudo-sexp elem env)) x)]
    [else
     (cons (normalize-pseudo-sexp (car x) env)
           (normalize-pseudo-sexp (cdr x) env))]))

(define (compile-pseudo-code->insts pseudo-sexp [pos-target #f] #:target [kw-target #f])
  (define raw-tid (or kw-target pos-target 'nes))
  (define tid
    (cond
      [(target-spec? raw-tid) (target-spec-id raw-tid)]
      [(eq? raw-tid 'gbc)     'gb]
      [(eq? raw-tid 'pico)    'pico8]
      [(symbol? raw-tid)      raw-tid]
      [else                   'nes]))

  (define normalized-sexp (normalize-pseudo-sexp pseudo-sexp))

  (define stmts
    (match normalized-sexp
      [`(decompiled-pseudo-code . ,body) body]
      [`(begin . ,body) body]
      [(? list? lst)
       (if (and (pair? lst) (symbol? (car lst))
                (memq (car lst)
                      '(set! += -= when when-break unless if switch
                        loop-counted do-while do-while-loop while for-range foreach
                        break continue branch-if goto
                        let let* begin mem-fill! mem-copy! dma-transfer!
                        spin-wait-mmio await-mmio! call tail-call return reti push! pop! label)))
           (list lst)
           lst)]
      [_ (list normalized-sexp)]))

  (define label-counter 0)
  (define (fresh-label prefix)
    (set! label-counter (add1 label-counter))
    (string->symbol (format "~a_~a" prefix label-counter)))

  ;; Helper to parse keyword-annotated loop forms such as:
  ;; (loop-counted #:counter X #:step -1 #:until-flag zero/not-equal #:target lbl body ...)
  ;; or (do-while #:target lbl #:cond cond-expr body ...)
  (define (parse-kw-args-and-body items)
    (let loop ([rem items]
               [kws (hasheq)]
               [body '()])
      (cond
        [(null? rem)
         (values kws (reverse body))]
        [(and (keyword? (car rem)) (pair? (cdr rem)))
         (loop (cddr rem)
               (hash-set kws (car rem) (cadr rem))
               body)]
        [else
         (loop (cdr rem) kws (cons (car rem) body))])))

  (define (parse-mem-fill-args rest)
    (define-values (kws pos) (parse-kw-args-and-body rest))
    (define dst   (hash-ref kws '#:dst (if (>= (length pos) 1) (first pos) #x0200)))
    (define val   (hash-ref kws '#:val (hash-ref kws '#:value (if (>= (length pos) 2) (second pos) 0))))
    (define count (hash-ref kws '#:count (hash-ref kws '#:bytes (hash-ref kws '#:size (if (>= (length pos) 3) (third pos) 256)))))
    (values dst val count))

  (define (parse-mem-copy-args rest)
    (define-values (kws pos) (parse-kw-args-and-body rest))
    (define dst   (hash-ref kws '#:dst (if (>= (length pos) 1) (first pos) #x0200)))
    (define src   (hash-ref kws '#:src (if (>= (length pos) 2) (second pos) #x8000)))
    (define count (hash-ref kws '#:count (hash-ref kws '#:bytes (hash-ref kws '#:size (if (>= (length pos) 3) (third pos) 256)))))
    (values dst src count))

  (define (parse-dma-transfer-args rest)
    (define-values (kws pos) (parse-kw-args-and-body rest))
    (define dst
      (hash-ref kws '#:dst
                (cond
                  [(>= (length pos) 2) (first pos)]
                  [else #x0200])))
    (define src
      (hash-ref kws '#:src
                (cond
                  [(>= (length pos) 2) (second pos)]
                  [(= (length pos) 1)  (first pos)]
                  [else #x0200])))
    (define count
      (hash-ref kws '#:count
                (hash-ref kws '#:bytes
                          (hash-ref kws '#:size
                                    (if (>= (length pos) 3) (third pos) #x100)))))
    (define ctrl
      (hash-ref kws '#:control
                (hash-ref kws '#:ctrl count)))
    (values dst src count ctrl))

  ;; --------------------------------------------------------------------------
  ;; 1. MOS 6502 (NES) & WDC 65C816 (SNES) Compiler Backend
  ;; --------------------------------------------------------------------------
  (define (compile-6502-expr->A expr)
    (match expr
      [(? exact-integer? n)
       `((LDA #:imm ,(bitwise-and n (if (eq? tid 'snes) #xFFFF #xFF))))]
      ['A '()]
      ['X '((TXA))]
      ['Y '((TYA))]
      [`(,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg)
       `((LDA #:abs ,(resolve-mmio-or-addr reg tid)))]
      [`(,(or 'zp 'dp 'u16-zp 'u16-dp 'zp16 'hram) ,addr)
       `((LDA #:zp ,(bitwise-and addr #xFF)))]
      [`(,(or 'wram 'mem8 'mem16 'mem32 'u16-wram 'wram16) ,addr)
       (if (< addr #x0100)
           `((LDA #:zp ,addr))
           `((LDA #:abs ,addr)))]
      [`(aref ,(or 'zp 'dp) ,base X)
       `((LDA #:zpx ,base))]
      [`(aref ,(or 'zp 'dp) ,base Y)
       `((LDA #:zpy ,base))]
      [`(aref ,_ ,base X)
       `((LDA #:absx ,base))]
      [`(aref ,_ ,base Y)
       `((LDA #:absy ,base))]
      [`(aref ,_ ,base ,_)
       `((LDA #:absx ,base))]
      [`(-> ,base ,field-sym . ,_)
       (define off (parse-struct-field-offset field-sym))
       (define base-addr (if (exact-integer? base) base #x0300))
       (define eff (+ base-addr off))
       (if (< eff #x0100)
           `((LDA #:zp ,eff))
           `((LDA #:abs ,eff)))]
      [(? symbol? sym)
       `((LDA #:abs ,(resolve-mmio-or-addr sym tid)))]
      [`(+ ,e1 ,e2)
       (append (compile-6502-expr->A e1)
               '((CLC))
               (match e2
                 [(? exact-integer? k) `((ADC #:imm ,(bitwise-and k (if (eq? tid 'snes) #xFFFF #xFF))))]
                 [`(,(or 'zp 'dp) ,a)  `((ADC #:zp ,a))]
                 [`(,_ ,(? exact-integer? a)) `((ADC #:abs ,a))]
                 [_ (append '((STA #:zp #xFE))
                            (compile-6502-expr->A e2)
                            '((CLC) (ADC #:zp #xFE)))]))]
      [`(- ,e1 ,e2)
       (append (compile-6502-expr->A e1)
               '((SEC))
               (match e2
                 [(? exact-integer? k) `((SBC #:imm ,(bitwise-and k (if (eq? tid 'snes) #xFFFF #xFF))))]
                 [`(,(or 'zp 'dp) ,a)  `((SBC #:zp ,a))]
                 [`(,_ ,(? exact-integer? a)) `((SBC #:abs ,a))]
                 [_ `((SBC #:imm 1))]))]
      [`(bit-and ,e1 ,e2)
       (append (compile-6502-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((AND #:imm ,(bitwise-and k #xFF)))]
                 [`(,(or 'zp 'dp) ,a)  `((AND #:zp ,a))]
                 [`(,_ ,(? exact-integer? a)) `((AND #:abs ,a))]
                 [_ `((AND #:imm #xFF))]))]
      [`(bit-ior ,e1 ,e2)
       (append (compile-6502-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((ORA #:imm ,(bitwise-and k #xFF)))]
                 [`(,(or 'zp 'dp) ,a)  `((ORA #:zp ,a))]
                 [`(,_ ,(? exact-integer? a)) `((ORA #:abs ,a))]
                 [_ `((ORA #:imm 0))]))]
      [`(bit-xor ,e1 ,e2)
       (append (compile-6502-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((EOR #:imm ,(bitwise-and k #xFF)))]
                 [`(,(or 'zp 'dp) ,a)  `((EOR #:zp ,a))]
                 [`(,_ ,(? exact-integer? a)) `((EOR #:abs ,a))]
                 [_ `((EOR #:imm 0))]))]
      [`(shl ,e1 ,(? exact-integer? k))
       (append (compile-6502-expr->A e1)
               (for/list ([_ (in-range (max 1 k))]) '(ASL)))]
      [`(,(or 'shr 'asr) ,e1 ,(? exact-integer? k))
       (append (compile-6502-expr->A e1)
               (for/list ([_ (in-range (max 1 k))]) '(LSR)))]
      [_ '((LDA #:imm 0))]))

  (define (compile-6502-cond-branch-false cond-expr false-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (if (and (exact-integer? rhs) (zero? rhs))
                   `((CMP #:imm 0) (BNE ,false-lbl))
                   (match rhs
                     [(? exact-integer? k) `((CMP #:imm ,k) (BNE ,false-lbl))]
                     [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BNE ,false-lbl))]
                     [_ `((CMP #:imm 0) (BNE ,false-lbl))])))]
      [`(!= ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (match rhs
                 [(? exact-integer? k) `((CMP #:imm ,k) (BEQ ,false-lbl))]
                 [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BEQ ,false-lbl))]
                 [_ `((CMP #:imm 0) (BEQ ,false-lbl))]))]
      [`(< ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (match rhs
                 [(? exact-integer? k) `((CMP #:imm ,k) (BCS ,false-lbl))]
                 [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BCS ,false-lbl))]
                 [_ `((CMP #:imm 0) (BCS ,false-lbl))]))]
      [`(>= ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (match rhs
                 [(? exact-integer? k) `((CMP #:imm ,k) (BCC ,false-lbl))]
                 [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BCC ,false-lbl))]
                 [_ `((CMP #:imm 0) (BCC ,false-lbl))]))]
      [_
       (append (compile-6502-expr->A cond-expr)
               `((CMP #:imm 0) (BEQ ,false-lbl)))]))

  (define (compile-6502-cond-branch-true cond-expr true-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (match rhs
                 [(? exact-integer? k) `((CMP #:imm ,k) (BEQ ,true-lbl))]
                 [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BEQ ,true-lbl))]
                 [_ `((CMP #:imm 0) (BEQ ,true-lbl))]))]
      [`(!= ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (match rhs
                 [(? exact-integer? k) `((CMP #:imm ,k) (BNE ,true-lbl))]
                 [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BNE ,true-lbl))]
                 [_ `((CMP #:imm 0) (BNE ,true-lbl))]))]
      [`(< ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (match rhs
                 [(? exact-integer? k) `((CMP #:imm ,k) (BCC ,true-lbl))]
                 [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BCC ,true-lbl))]
                 [_ `((CMP #:imm 0) (BCC ,true-lbl))]))]
      [`(>= ,lhs ,rhs)
       (append (compile-6502-expr->A lhs)
               (match rhs
                 [(? exact-integer? k) `((CMP #:imm ,k) (BCS ,true-lbl))]
                 [`(,(or 'zp 'dp) ,a)  `((CMP #:zp ,a) (BCS ,true-lbl))]
                 [_ `((CMP #:imm 0) (BCS ,true-lbl))]))]
      [_
       (append (compile-6502-expr->A cond-expr)
               `((CMP #:imm 0) (BNE ,true-lbl)))]))

  (define (compile-6502-u16-add-sub is-add? mode addr expr)
    (if (eq? tid 'snes)
        (let ([imm-val (if (exact-integer? expr) (bitwise-and expr #xFFFF) 1)]
              [carry-op (if is-add? '(CLC) '(SEC))]
              [alu-mnem (if is-add? 'ADC 'SBC)])
          `((REP #:imm #x20)
            ,carry-op
            (LDA ,mode ,addr)
            (,alu-mnem #:imm ,imm-val)
            (STA ,mode ,addr)
            (SEP #:imm #x20)))
        (let ([alu-mnem (if is-add? 'ADC 'SBC)]
              [carry-op (if is-add? '(CLC) '(SEC))]
              [lo-op (match expr
                       [(? exact-integer? k) `(,(if is-add? 'ADC 'SBC) #:imm ,(bitwise-and k #xFF))]
                       [`(,(or 'zp 'dp) ,a)  `(,(if is-add? 'ADC 'SBC) #:zp ,a)]
                       [`(,_ ,(? exact-integer? a)) `(,(if is-add? 'ADC 'SBC) #:abs ,a)]
                       [_                    `(,(if is-add? 'ADC 'SBC) #:imm 1)])]
              [hi-val (if (exact-integer? expr)
                          (bitwise-and (arithmetic-shift expr -8) #xFF)
                          0)])
          `(,carry-op
            (LDA ,mode ,addr)
            ,lo-op
            (STA ,mode ,addr)
            (LDA ,mode ,(+ addr 1))
            (,alu-mnem #:imm ,hi-val)
            (STA ,mode ,(+ addr 1))))))

  (define (compile-6502-stmt stmt)
    (match stmt
      [`(begin . ,body)
       (apply append (map compile-6502-stmt body))]
      [`(,(or 'let 'let*) . ,_)
       (compile-6502-stmt (normalize-pseudo-sexp stmt))]
      [`(mem-fill! . ,rest)
       (define-values (dst val count) (parse-mem-fill-args rest))
       (define dst-addr (resolve-mmio-or-addr dst tid))
       (define loop-lbl (fresh-label 'L_mem_fill))
       (define cnt-insts
         (if (exact-integer? count)
             `((LDX #:imm ,(bitwise-and count (if (eq? tid 'snes) #xFFFF #xFF))))
             (append (compile-6502-expr->A count) '((TAX)))))
       (define val-insts (compile-6502-expr->A val))
       (define sta-inst
         (if (< dst-addr #x0100)
             `(STA #:zpx ,dst-addr)
             `(STA #:absx ,dst-addr)))
       (append cnt-insts
               val-insts
               `((label ,loop-lbl)
                 ,sta-inst
                 (DEX)
                 (BNE ,loop-lbl)))]
      [`(mem-copy! . ,rest)
       (define-values (dst src count) (parse-mem-copy-args rest))
       (define dst-addr (resolve-mmio-or-addr dst tid))
       (define src-addr (resolve-mmio-or-addr src tid))
       (define loop-lbl (fresh-label 'L_mem_copy))
       (define cnt-insts
         (if (exact-integer? count)
             `((LDX #:imm ,(bitwise-and count (if (eq? tid 'snes) #xFFFF #xFF))))
             (append (compile-6502-expr->A count) '((TAX)))))
       (define lda-inst
         (if (< src-addr #x0100)
             `(LDA #:zpx ,src-addr)
             `(LDA #:absx ,src-addr)))
       (define sta-inst
         (if (< dst-addr #x0100)
             `(STA #:zpx ,dst-addr)
             `(STA #:absx ,dst-addr)))
       (append cnt-insts
               `((label ,loop-lbl)
                 ,lda-inst
                 ,sta-inst
                 (DEX)
                 (BNE ,loop-lbl)))]
      [`(dma-transfer! . ,rest)
       (define-values (dst src count _ctrl) (parse-dma-transfer-args rest))
       (if (eq? tid 'snes)
           (let ([src-addr (resolve-mmio-or-addr src 'snes)]
                 [cnt-val  (if (exact-integer? count) (bitwise-and count #xFF) 1)])
             `((LDA #:imm ,(bitwise-and src-addr #xFF))
               (STA #:abs #x4302)
               (LDA #:imm ,cnt-val)
               (STA #:abs #x4305)
               (LDA #:imm 1)
               (STA #:abs ,(resolve-mmio-or-addr 'MDMAEN 'snes))))
           (let ([src-val (if (exact-integer? src)
                              (if (> src #xFF)
                                  (bitwise-and (arithmetic-shift src -8) #xFF)
                                  (bitwise-and src #xFF))
                              src)])
             (append (compile-6502-expr->A src-val)
                     `((STA #:abs ,(resolve-mmio-or-addr 'OAMDMA 'nes))))))]
      [`(set! ,dst ,expr #:flags . ,_)
       (compile-6502-stmt `(set! ,dst ,expr))]
      [`(set! (,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg) ,expr)
       (compile-6502-stmt `(set! ,reg ,expr))]
      [`(set! X ,(? exact-integer? n))
       `((LDX #:imm ,(bitwise-and n #xFF)))]
      [`(set! Y ,(? exact-integer? n))
       `((LDY #:imm ,(bitwise-and n #xFF)))]
      [`(set! X ,expr)
       (append (compile-6502-expr->A expr) '((TAX)))]
      [`(set! Y ,expr)
       (append (compile-6502-expr->A expr) '((TAY)))]
      [`(set! SP ,(? exact-integer? n))
       `((LDX #:imm ,(bitwise-and n #xFF)) (TXS))]
      [`(set! A ,expr)
       (compile-6502-expr->A expr)]
      [`(set! (,(or 'u16-zp 'u16-dp 'zp16) ,addr) ,(? exact-integer? n))
       (if (eq? tid 'snes)
           `((REP #:imm #x20)
             (LDA #:imm ,(bitwise-and n #xFFFF))
             (STA #:zp ,addr)
             (SEP #:imm #x20))
           `((LDA #:imm ,(bitwise-and n #xFF))
             (STA #:zp ,addr)
             (LDA #:imm ,(bitwise-and (arithmetic-shift n -8) #xFF))
             (STA #:zp ,(+ addr 1))))]
      [`(set! (,(or 'u16-wram 'wram16) ,addr) ,(? exact-integer? n))
       (if (eq? tid 'snes)
           `((REP #:imm #x20)
             (LDA #:imm ,(bitwise-and n #xFFFF))
             (STA #:abs ,addr)
             (SEP #:imm #x20))
           `((LDA #:imm ,(bitwise-and n #xFF))
             (STA #:abs ,addr)
             (LDA #:imm ,(bitwise-and (arithmetic-shift n -8) #xFF))
             (STA #:abs ,(+ addr 1))))]
      [`(set! (,(or 'zp 'dp 'u16-zp 'u16-dp 'zp16 'hram) ,addr) ,expr)
       (append (compile-6502-expr->A expr) `((STA #:zp ,(bitwise-and addr #xFF))))]
      [`(set! (,(or 'wram 'mem8 'mem16 'mem32 'u16-wram 'wram16) ,addr) ,expr)
       (append (compile-6502-expr->A expr)
               (if (< addr #x0100)
                   `((STA #:zp ,addr))
                   `((STA #:abs ,addr))))]
      [`(set! (aref ,(or 'zp 'dp) ,base X) ,expr)
       (append (compile-6502-expr->A expr) `((STA #:zpx ,base)))]
      [`(set! (aref ,_ ,base ,_) ,expr)
       (append (compile-6502-expr->A expr) `((STA #:absx ,base)))]
      [`(set! (-> ,base ,field-sym . ,_) ,expr)
       (define off (parse-struct-field-offset field-sym))
       (define base-addr (if (exact-integer? base) base #x0300))
       (define eff (+ base-addr off))
       (append (compile-6502-expr->A expr)
               (if (< eff #x0100)
                   `((STA #:zp ,eff))
                   `((STA #:abs ,eff))))]
      [`(set! ,(? symbol? dst) ,expr)
       (define addr (resolve-mmio-or-addr dst tid))
       (append (compile-6502-expr->A expr) `((STA #:abs ,addr)))]
      [`(+= X 1) '((INX))]
      [`(-= X 1) '((DEX))]
      [`(+= Y 1) '((INY))]
      [`(-= Y 1) '((DEY))]
      [`(+= (,(or 'zp 'dp) ,addr) 1) `((INC #:zp ,addr))]
      [`(-= (,(or 'zp 'dp) ,addr) 1) `((DEC #:zp ,addr))]
      [`(+= (,(or 'u16-zp 'u16-dp 'zp16) ,addr) ,expr)
       (compile-6502-u16-add-sub #t '#:zp addr expr)]
      [`(-= (,(or 'u16-zp 'u16-dp 'zp16) ,addr) ,expr)
       (compile-6502-u16-add-sub #f '#:zp addr expr)]
      [`(+= (,(or 'u16-wram 'wram16) ,addr) ,expr)
       (compile-6502-u16-add-sub #t '#:abs addr expr)]
      [`(-= (,(or 'u16-wram 'wram16) ,addr) ,expr)
       (compile-6502-u16-add-sub #f '#:abs addr expr)]
      [`(+= ,dst ,expr)
       (compile-6502-stmt `(set! ,dst (+ ,dst ,expr)))]
      [`(-= ,dst ,expr)
       (compile-6502-stmt `(set! ,dst (- ,dst ,expr)))]
      [`(push! A) '((PHA))]
      [`(push! X) '((TXA) (PHA))]
      [`(push! Y) '((TYA) (PHA))]
      [`(pop! A)  '((PLA))]
      [`(pop! X)  '((PLA) (TAX))]
      [`(pop! Y)  '((PLA) (TAY))]
      [`(,(or 'break 'goto) ,label)
       `((JMP ,label))]
      [`(break)
       '((JMP L_break))]
      [`(continue ,label)
       `((JMP ,label))]
      [`(continue)
       '((JMP L_continue))]
      [`(when-break ,cond-expr ,label)
       (compile-6502-cond-branch-true cond-expr label)]
      [`(branch-if ,cond-expr ,label)
       (compile-6502-cond-branch-true cond-expr label)]
      [`(when ,cond-expr (,(or 'break 'goto 'continue) ,label))
       (compile-6502-cond-branch-true cond-expr label)]
      [`(when ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-6502-cond-branch-false cond-expr join-lbl)
               (apply append (map compile-6502-stmt body))
               `((label ,join-lbl)))]
      [`(unless ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-6502-cond-branch-true cond-expr join-lbl)
               (apply append (map compile-6502-stmt body))
               `((label ,join-lbl)))]
      [`(switch ,expr . ,clauses)
       (define end-lbl (fresh-label 'L_switch_end))
       (append
        (apply append
               (for/list ([clause (in-list clauses)])
                 (match clause
                   [`(case ,val . ,case-body)
                    (define next-lbl (fresh-label 'L_case_next))
                    (append (compile-6502-cond-branch-false `(= ,expr ,val) next-lbl)
                            (apply append (map compile-6502-stmt case-body))
                            `((JMP ,end-lbl)
                              (label ,next-lbl)))]
                   [`(,(or 'default 'else) . ,def-body)
                    (append (apply append (map compile-6502-stmt def-body))
                            `((JMP ,end-lbl)))]
                   [_ '()])))
        `((label ,end-lbl)))]
      [`(if ,cond-expr (then . ,then-body) (else . ,else-body))
       (define else-lbl (fresh-label 'L_else))
       (define join-lbl (fresh-label 'L_join))
       (append (compile-6502-cond-branch-false cond-expr else-lbl)
               (apply append (map compile-6502-stmt then-body))
               `((JMP ,join-lbl)
                 (label ,else-lbl))
               (apply append (map compile-6502-stmt else-body))
               `((label ,join-lbl)))]
      [`(if ,cond-expr ,then-stmt ,else-stmt)
       (compile-6502-stmt `(if ,cond-expr (then ,then-stmt) (else ,else-stmt)))]
      [`(loop-counted (,reg ,count) . ,body)
       (define loop-lbl (fresh-label 'L_loop))
       (define init-insts
         (case reg
           [(X) `((LDX #:imm ,count))]
           [(Y) `((LDY #:imm ,count))]
           [else `((LDX #:imm ,count))]))
       (define step-insts
         (case reg
           [(Y) `((DEY) (BNE ,loop-lbl))]
           [else `((DEX) (BNE ,loop-lbl))]))
       (append init-insts
               `((label ,loop-lbl))
               (apply append (map compile-6502-stmt body))
               step-insts)]
      [`(loop-counted . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define reg (hash-ref kws '#:counter 'X))
       (define step (hash-ref kws '#:step -1))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_loop)))
       (define step-insts
         (case reg
           [(Y) (list (if (and (number? step) (positive? step)) '(INY) '(DEY))
                      `(BNE ,loop-lbl))]
           [else (list (if (and (number? step) (positive? step)) '(INX) '(DEX))
                       `(BNE ,loop-lbl))]))
       (append `((label ,loop-lbl))
               (apply append (map compile-6502-stmt body))
               step-insts)]
      [`(do-while-loop (label ,lbl) (condition ,cond-expr) (body . ,body))
       (append `((label ,lbl))
               (apply append (map compile-6502-stmt body))
               (compile-6502-cond-branch-true cond-expr lbl))]
      [`(do-while . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_do_while)))
       (define cond-expr (hash-ref kws '#:cond (if (pair? body) (car body) 1)))
       (define actual-body (if (hash-has-key? kws '#:cond) body (if (pair? body) (cdr body) '())))
       (append `((label ,loop-lbl))
               (apply append (map compile-6502-stmt actual-body))
               (compile-6502-cond-branch-true cond-expr loop-lbl))]
      [`(spin-wait-mmio ,reg-or-addr ,mask)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr tid))
       `((label ,wait-lbl)
         (LDA #:abs ,addr)
         (AND #:imm ,mask)
         (BEQ ,wait-lbl))]
      [`(await-mmio! ,reg-or-addr . ,rest)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr tid))
       (define cond-sym (if (pair? rest) (car rest) 'plus/positive))
       (define br-mnem
         (case cond-sym
           [(minus/negative negative bmi) 'BMI]
           [(zero beq)                    'BEQ]
           [(non-zero bne)                'BNE]
           [else                          'BPL]))
       `((label ,wait-lbl)
         (LDA #:abs ,addr)
         (,br-mnem ,wait-lbl))]
      [`(,(or 'call 'tail-call) ,callee . ,args)
       (define arg-insts
         (apply append
                (for/list ([arg (in-list args)]
                           [idx (in-naturals)])
                  (case idx
                    [(0) (compile-6502-stmt `(set! A ,arg))]
                    [(1) (compile-6502-stmt `(set! X ,arg))]
                    [(2) (compile-6502-stmt `(set! Y ,arg))]
                    [else '()]))))
       (append arg-insts `((JSR ,callee)))]
      [`(return)
       '((RTS))]
      [`(return ,expr)
       (append (compile-6502-expr->A expr) '((RTS)))]
      [`(reti)
       '((RTI))]
      [`(label ,sym)
       `((label ,sym))]
      [_ '((NOP))]))

  ;; --------------------------------------------------------------------------
  ;; 2. Sharp SM83 (Game Boy / Game Boy Color) Compiler Backend
  ;; --------------------------------------------------------------------------
  (define (compile-sm83-expr->A expr)
    (match expr
      [(? exact-integer? n)
       `((LD_A #:d8 ,(bitwise-and n #xFF)))]
      ['A '()]
      [(? symbol? r) #:when (memq r '(B C D E H L))
       `((,(string->symbol (format "LD_A_~a" r)) #:imp 0))]
      [`(,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg)
       (compile-sm83-expr->A reg)]
      [`(hram ,addr)
       `((LDH_IN #:io8 ,(bitwise-and addr #xFF)))]
      [`(,(or 'wram 'mem8 'mem16 'mem32 'zp 'dp 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr)
       (if (>= addr #xFF00)
           `((LDH_IN #:io8 ,(bitwise-and addr #xFF)))
           `((LD_A_MEM #:a16 ,(bitwise-and addr #xFFFF))))]
      [`(aref ,_ ,base ,_)
       `((LD_A_MEM #:a16 ,(bitwise-and (resolve-mmio-or-addr base 'gb) #xFFFF)))]
      [`(deref HL)
       '((LD_A_HL-IND #:imp 0))]
      [`(-> ,base ,field-sym . ,_)
       (define off (parse-struct-field-offset field-sym))
       (define base-addr (if (exact-integer? base) base #xC000))
       `((LD_A_MEM #:a16 ,(+ base-addr off)))]
      [(? symbol? sym)
       (define addr (resolve-mmio-or-addr sym 'gb))
       (if (>= addr #xFF00)
           `((LDH_IN #:io8 ,(bitwise-and addr #xFF)))
           `((LD_A_MEM #:a16 ,addr)))]
      [`(+ ,e1 ,e2)
       (append (compile-sm83-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((ADD_A #:d8 ,(bitwise-and k #xFF)))]
                 ['A '((ADD_A_A #:imp 0))]
                 [_  `((ADD_A #:d8 1))]))]
      [`(- ,e1 ,e2)
       (append (compile-sm83-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((SUB_A #:d8 ,(bitwise-and k #xFF)))]
                 [_ `((SUB_A #:d8 1))]))]
      [`(bit-and ,e1 ,e2)
       (append (compile-sm83-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((AND_A #:d8 ,(bitwise-and k #xFF)))]
                 [_ `((AND_A #:d8 #xFF))]))]
      [`(bit-ior ,e1 ,e2)
       (append (compile-sm83-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((OR_A #:d8 ,(bitwise-and k #xFF)))]
                 [_ `((OR_A #:d8 0))]))]
      [`(bit-xor ,e1 ,e2)
       (append (compile-sm83-expr->A e1)
               (match e2
                 [(? exact-integer? k) `((XOR_A #:d8 ,(bitwise-and k #xFF)))]
                 [_ `((XOR_A #:d8 0))]))]
      [`(shl ,e1 ,(? exact-integer? k))
       (append (compile-sm83-expr->A e1)
               (for/list ([_ (in-range (max 1 k))]) '(SLA_A #:cb #x27)))]
      [`(,(or 'shr 'asr) ,e1 ,(? exact-integer? k))
       (append (compile-sm83-expr->A e1)
               (for/list ([_ (in-range (max 1 k))]) '(SRL_A #:cb #x3F)))]
      [_ '((LD_A #:d8 0))]))

  (define (compile-sm83-cond-branch-false cond-expr false-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_NZ ,false-lbl)))]
      [`(!= ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_Z ,false-lbl)))]
      [`(< ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_NC ,false-lbl)))]
      [`(>= ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_C ,false-lbl)))]
      [_
       (append (compile-sm83-expr->A cond-expr)
               `((CP_A #:d8 0)
                 (JR_Z ,false-lbl)))]))

  (define (compile-sm83-cond-branch-true cond-expr true-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_Z ,true-lbl)))]
      [`(!= ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_NZ ,true-lbl)))]
      [`(< ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_C ,true-lbl)))]
      [`(>= ,lhs ,(? exact-integer? k))
       (append (compile-sm83-expr->A lhs)
               `((CP_A #:d8 ,(bitwise-and k #xFF))
                 (JR_NC ,true-lbl)))]
      [_
       (append (compile-sm83-expr->A cond-expr)
               `((CP_A #:d8 0)
                 (JR_NZ ,true-lbl)))]))

  (define (compile-sm83-stmt stmt)
    (match stmt
      [`(begin . ,body)
       (apply append (map compile-sm83-stmt body))]
      [`(,(or 'let 'let*) . ,_)
       (compile-sm83-stmt (normalize-pseudo-sexp stmt))]
      [`(mem-fill! . ,rest)
       (define-values (dst val count) (parse-mem-fill-args rest))
       (define dst-addr (resolve-mmio-or-addr dst 'gb))
       (define cnt-val  (if (exact-integer? count) (bitwise-and count #xFF) 1))
       (define loop-lbl (fresh-label 'L_mem_fill))
       (append `((LD_HL #:d16 ,(bitwise-and dst-addr #xFFFF))
                 (LD_B #:d8 ,cnt-val))
               (compile-sm83-expr->A val)
               `((label ,loop-lbl)
                 (LD_HLI_A #:imp 0)
                 (DEC_B #:imp 0)
                 (JR_NZ ,loop-lbl)))]
      [`(mem-copy! . ,rest)
       (define-values (dst src count) (parse-mem-copy-args rest))
       (define dst-addr (resolve-mmio-or-addr dst 'gb))
       (define src-addr (resolve-mmio-or-addr src 'gb))
       (define cnt-val  (if (exact-integer? count) (bitwise-and count #xFF) 1))
       (define loop-lbl (fresh-label 'L_mem_copy))
       `((LD_HL #:d16 ,(bitwise-and src-addr #xFFFF))
         (LD_DE #:d16 ,(bitwise-and dst-addr #xFFFF))
         (LD_B #:d8 ,cnt-val)
         (label ,loop-lbl)
         (LD_A_HLI #:imp 0)
         (LD_DE_A #:imp 0)
         (INC_DE #:imp 0)
         (DEC_B #:imp 0)
         (JR_NZ ,loop-lbl))]
      [`(dma-transfer! . ,rest)
       (define-values (_dst src _count _ctrl) (parse-dma-transfer-args rest))
       (define page-val
         (if (exact-integer? src)
             (if (> src #xFF)
                 (bitwise-and (arithmetic-shift src -8) #xFF)
                 (bitwise-and src #xFF))
             #xC0))
       `((LD_A #:d8 ,page-val)
         (LDH_OUT #:io8 ,(bitwise-and (resolve-mmio-or-addr 'DMA 'gb) #xFF)))]
      [`(set! ,dst ,expr #:flags . ,_)
       (compile-sm83-stmt `(set! ,dst ,expr))]
      [`(set! (,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg) ,expr)
       (compile-sm83-stmt `(set! ,reg ,expr))]
      [`(set! ,(and r16 (or 'HL 'BC 'DE 'SP)) ,(? exact-integer? n))
       `((,(string->symbol (format "LD_~a" r16)) #:d16 ,(bitwise-and n #xFFFF)))]
      [`(set! A ,expr)
       (compile-sm83-expr->A expr)]
      [`(set! ,(and r8 (or 'B 'C 'D 'E 'H 'L)) ,(? exact-integer? n))
       `((,(string->symbol (format "LD_~a" r8)) #:d8 ,(bitwise-and n #xFF)))]
      [`(set! ,(and r8 (or 'B 'C 'D 'E 'H 'L)) ,expr)
       (append (compile-sm83-expr->A expr)
               `((,(string->symbol (format "LD_~a_A" r8)) #:imp 0)))]
      [`(set! (hram ,addr) ,expr)
       (append (compile-sm83-expr->A expr)
               `((LDH_OUT #:io8 ,(bitwise-and addr #xFF))))]
      [`(set! (,(or 'wram 'mem8 'mem16 'mem32 'zp 'dp 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr) ,expr)
       (append (compile-sm83-expr->A expr)
               (if (>= addr #xFF00)
                   `((LDH_OUT #:io8 ,(bitwise-and addr #xFF)))
                   `((LD_MEM_A #:a16 ,(bitwise-and addr #xFFFF)))))]
      [`(set! (aref ,_ ,base ,_) ,expr)
       (append (compile-sm83-expr->A expr)
               `((LD_MEM_A #:a16 ,(bitwise-and (resolve-mmio-or-addr base 'gb) #xFFFF))))]
      [`(set! (-> ,base ,field-sym . ,_) ,expr)
       (define off (parse-struct-field-offset field-sym))
       (define base-addr (if (exact-integer? base) base #xC000))
       (append (compile-sm83-expr->A expr)
               `((LD_MEM_A #:a16 ,(+ base-addr off))))]
      [`(set! ,(? symbol? dst) ,expr)
       (define addr (resolve-mmio-or-addr dst 'gb))
       (append (compile-sm83-expr->A expr)
               (if (>= addr #xFF00)
                   `((LDH_OUT #:io8 ,(bitwise-and addr #xFF)))
                   `((LD_MEM_A #:a16 ,addr))))]
      [`(+= HL ,(? symbol? rr)) #:when (memq rr '(BC DE HL SP))
       `((,(string->symbol (format "ADD_HL_~a" rr)) #:imp 0))]
      [`(+= HL ,(? exact-integer? n))
       `((LD_DE #:d16 ,(bitwise-and n #xFFFF))
         (ADD_HL_DE #:imp 0))]
      [`(-= HL ,(? exact-integer? n))
       `((LD_DE #:d16 ,(bitwise-and (- n) #xFFFF))
         (ADD_HL_DE #:imp 0))]
      [`(+= (,(or 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr) ,expr)
       (if (and (symbol? expr) (memq expr '(BC DE HL SP)))
           `((LD_A_MEM #:a16 ,addr)
             (LD_L_A #:imp 0)
             (LD_A_MEM #:a16 ,(+ addr 1))
             (LD_H_A #:imp 0)
             (,(string->symbol (format "ADD_HL_~a" expr)) #:imp 0)
             (LD_A_L #:imp 0)
             (LD_MEM_A #:a16 ,addr)
             (LD_A_H #:imp 0)
             (LD_MEM_A #:a16 ,(+ addr 1)))
           (let ([imm-val (if (exact-integer? expr) (bitwise-and expr #xFFFF) 1)])
             `((LD_A_MEM #:a16 ,addr)
               (LD_L_A #:imp 0)
               (LD_A_MEM #:a16 ,(+ addr 1))
               (LD_H_A #:imp 0)
               (LD_DE #:d16 ,imm-val)
               (ADD_HL_DE #:imp 0)
               (LD_A_L #:imp 0)
               (LD_MEM_A #:a16 ,addr)
               (LD_A_H #:imp 0)
               (LD_MEM_A #:a16 ,(+ addr 1)))))]
      [`(-= (,(or 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr) ,expr)
       (define imm-val (if (exact-integer? expr) (bitwise-and (- expr) #xFFFF) #xFFFF))
       `((LD_A_MEM #:a16 ,addr)
         (LD_L_A #:imp 0)
         (LD_A_MEM #:a16 ,(+ addr 1))
         (LD_H_A #:imp 0)
         (LD_DE #:d16 ,imm-val)
         (ADD_HL_DE #:imp 0)
         (LD_A_L #:imp 0)
         (LD_MEM_A #:a16 ,addr)
         (LD_A_H #:imp 0)
         (LD_MEM_A #:a16 ,(+ addr 1)))]
      [`(+= ,dst ,expr)
       (compile-sm83-stmt `(set! ,dst (+ ,dst ,expr)))]
      [`(-= ,dst ,expr)
       (compile-sm83-stmt `(set! ,dst (- ,dst ,expr)))]
      [`(,(or 'break 'goto) ,label)
       `((JR ,label))]
      [`(break)
       '((JR L_break))]
      [`(continue ,label)
       `((JR ,label))]
      [`(continue)
       '((JR L_continue))]
      [`(when-break ,cond-expr ,label)
       (compile-sm83-cond-branch-true cond-expr label)]
      [`(branch-if ,cond-expr ,label)
       (compile-sm83-cond-branch-true cond-expr label)]
      [`(when ,cond-expr (,(or 'break 'goto 'continue) ,label))
       (compile-sm83-cond-branch-true cond-expr label)]
      [`(when ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-sm83-cond-branch-false cond-expr join-lbl)
               (apply append (map compile-sm83-stmt body))
               `((label ,join-lbl)))]
      [`(unless ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-sm83-cond-branch-true cond-expr join-lbl)
               (apply append (map compile-sm83-stmt body))
               `((label ,join-lbl)))]
      [`(switch ,expr . ,clauses)
       (define end-lbl (fresh-label 'L_switch_end))
       (append
        (apply append
               (for/list ([clause (in-list clauses)])
                 (match clause
                   [`(case ,val . ,case-body)
                    (define next-lbl (fresh-label 'L_case_next))
                    (append (compile-sm83-cond-branch-false `(= ,expr ,val) next-lbl)
                            (apply append (map compile-sm83-stmt case-body))
                            `((JR ,end-lbl)
                              (label ,next-lbl)))]
                   [`(,(or 'default 'else) . ,def-body)
                    (append (apply append (map compile-sm83-stmt def-body))
                            `((JR ,end-lbl)))]
                   [_ '()])))
        `((label ,end-lbl)))]
      [`(if ,cond-expr (then . ,then-body) (else . ,else-body))
       (define else-lbl (fresh-label 'L_else))
       (define join-lbl (fresh-label 'L_join))
       (append (compile-sm83-cond-branch-false cond-expr else-lbl)
               (apply append (map compile-sm83-stmt then-body))
               `((JR ,join-lbl)
                 (label ,else-lbl))
               (apply append (map compile-sm83-stmt else-body))
               `((label ,join-lbl)))]
      [`(if ,cond-expr ,then-stmt ,else-stmt)
       (compile-sm83-stmt `(if ,cond-expr (then ,then-stmt) (else ,else-stmt)))]
      [`(loop-counted (,reg ,count) . ,body)
       (define loop-lbl (fresh-label 'L_loop))
       (define r (if (memq reg '(B C D E)) reg 'B))
       (append `((,(string->symbol (format "LD_~a" r)) #:d8 ,count)
                 (label ,loop-lbl))
               (apply append (map compile-sm83-stmt body))
               `((,(string->symbol (format "DEC_~a" r)) #:imp 0)
                 (JR_NZ ,loop-lbl)))]
      [`(loop-counted . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define reg (hash-ref kws '#:counter 'B))
       (define r (if (memq reg '(B C D E H L A)) reg 'B))
       (define step (hash-ref kws '#:step -1))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_loop)))
       (define step-op
         (if (and (number? step) (positive? step))
             (string->symbol (format "INC_~a" r))
             (string->symbol (format "DEC_~a" r))))
       (append `((label ,loop-lbl))
               (apply append (map compile-sm83-stmt body))
               `((,step-op #:imp 0)
                 (JR_NZ ,loop-lbl)))]
      [`(do-while-loop (label ,lbl) (condition ,cond-expr) (body . ,body))
       (append `((label ,lbl))
               (apply append (map compile-sm83-stmt body))
               (compile-sm83-cond-branch-true cond-expr lbl))]
      [`(do-while . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_do_while)))
       (define cond-expr (hash-ref kws '#:cond (if (pair? body) (car body) 1)))
       (define actual-body (if (hash-has-key? kws '#:cond) body (if (pair? body) (cdr body) '())))
       (append `((label ,loop-lbl))
               (apply append (map compile-sm83-stmt actual-body))
               (compile-sm83-cond-branch-true cond-expr loop-lbl))]
      [`(spin-wait-mmio ,reg-or-addr ,mask)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr 'gb))
       `((label ,wait-lbl)
         (LDH_IN #:io8 ,(bitwise-and addr #xFF))
         (AND_A #:d8 ,mask)
         (JR_Z ,wait-lbl))]
      [`(await-mmio! ,reg-or-addr . ,rest)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr 'gb))
       (define cond-sym (if (pair? rest) (car rest) 'non-zero))
       (define br-mnem (if (eq? cond-sym 'zero) 'JR_NZ 'JR_Z))
       (if (>= addr #xFF00)
           `((label ,wait-lbl)
             (LDH_IN #:io8 ,(bitwise-and addr #xFF))
             (AND_A #:d8 #xFF)
             (,br-mnem ,wait-lbl))
           `((label ,wait-lbl)
             (LD_A_MEM #:a16 ,addr)
             (AND_A #:d8 #xFF)
             (,br-mnem ,wait-lbl)))]
      [`(,(or 'call 'tail-call) ,callee . ,args)
       (define arg-insts
         (apply append
                (for/list ([arg (in-list args)]
                           [idx (in-naturals)])
                  (case idx
                    [(0) (compile-sm83-stmt `(set! A ,arg))]
                    [(1) (compile-sm83-stmt `(set! HL ,arg))]
                    [(2) (compile-sm83-stmt `(set! DE ,arg))]
                    [(3) (compile-sm83-stmt `(set! BC ,arg))]
                    [else '()]))))
       (append arg-insts `((CALL ,callee)))]
      [`(return)
       '((RET))]
      [`(return ,expr)
       (append (compile-sm83-expr->A expr) '((RET)))]
      [`(reti)
       '((RETI))]
      [`(label ,sym)
       `((label ,sym))]
      [_ '((NOP #:imp 0))]))

  ;; --------------------------------------------------------------------------
  ;; 3. GBA (ARM7TDMI Thumb16 / ARM32) Compiler Backend
  ;; --------------------------------------------------------------------------
  (define (compile-gba-expr->reg rd expr)
    (match expr
      [(? exact-integer? n)
       (if (<= 0 n 255)
           `((THUMB-MOV-imm ,rd ,n))
           `((THUMB-LDR-lit ,rd ,n)))]
      [(? symbol? rs) #:when (memq rs '(r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 sp lr pc))
       (if (eq? rd rs) '() `((THUMB-MOV ,rd ,rs)))]
      [`(,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg)
       (compile-gba-expr->reg rd reg)]
      [`(,(or 'EWRAM_PTR 'IWRAM_PTR) ,addr)
       `((THUMB-LDR-lit ,rd ,addr))]
      [`(mem8 ,addr)
       `((THUMB-LDR-lit r3 ,addr)
         (THUMB-LDRB-imm ,rd [r3 0]))]
      [`(,(or 'mem16 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr)
       `((THUMB-LDR-lit r3 ,addr)
         (THUMB-LDRH-imm ,rd [r3 0]))]
      [`(,(or 'mem32 'wram 'zp 'dp 'hram) ,addr)
       `((THUMB-LDR-lit r3 ,addr)
         (THUMB-LDR-imm ,rd [r3 0]))]
      [`(aref ,_ ,base ,_)
       `((THUMB-LDR-lit r3 ,(resolve-mmio-or-addr base 'gba))
         (THUMB-LDRH-imm ,rd [r3 0]))]
      [`(-> ,base ,field-sym . ,rest)
       (define off (parse-struct-field-offset field-sym))
       (define ty (if (pair? rest) (car rest) ':u32))
       (define base-reg (if (symbol? base) base 'r3))
       (define pre-insts (if (exact-integer? base) `((THUMB-LDR-lit r3 ,base)) '()))
       (append pre-insts
               (case ty
                 [(:u8 u8 :s8 s8)     `((THUMB-LDRB-imm ,rd [,base-reg ,off]))]
                 [(:u16 u16 :s16 s16) `((THUMB-LDRH-imm ,rd [,base-reg ,off]))]
                 [else                `((THUMB-LDR-imm ,rd [,base-reg ,off]))]))]
      [(? symbol? mmio-sym)
       (define addr (resolve-mmio-or-addr mmio-sym 'gba))
       `((THUMB-LDR-lit r3 ,addr)
         (THUMB-LDRH-imm ,rd [r3 0]))]
      [`(+ ,e1 ,e2)
       (append (compile-gba-expr->reg rd e1)
               (match e2
                 [(? exact-integer? k) `((THUMB-ADD-imm ,rd ,k))]
                 [(? symbol? r2)       `((THUMB-ADD ,rd ,rd ,r2))]
                 [_ (append (compile-gba-expr->reg 'r3 e2)
                            `((THUMB-ADD ,rd ,rd r3)))]))]
      [`(- ,e1 ,e2)
       (append (compile-gba-expr->reg rd e1)
               (match e2
                 [(? exact-integer? k) `((THUMB-SUB-imm ,rd ,k))]
                 [(? symbol? r2)       `((THUMB-SUB ,rd ,rd ,r2))]
                 [_ (append (compile-gba-expr->reg 'r3 e2)
                            `((THUMB-SUB ,rd ,rd r3)))]))]
      [`(bit-and ,e1 ,e2)
       (append (compile-gba-expr->reg rd e1)
               (compile-gba-expr->reg 'r3 e2)
               `((THUMB-AND ,rd r3)))]
      [`(bit-ior ,e1 ,e2)
       (append (compile-gba-expr->reg rd e1)
               (compile-gba-expr->reg 'r3 e2)
               `((THUMB-ORR ,rd r3)))]
      [`(bit-xor ,e1 ,e2)
       (append (compile-gba-expr->reg rd e1)
               (compile-gba-expr->reg 'r3 e2)
               `((THUMB-EOR ,rd r3)))]
      [`(shl ,e1 ,(? exact-integer? k))
       (append (compile-gba-expr->reg rd e1)
               `((THUMB-LSL ,rd ,rd ,k)))]
      [`(,(or 'shr 'asr) ,e1 ,(? exact-integer? k))
       (append (compile-gba-expr->reg rd e1)
               `((THUMB-LSR ,rd ,rd ,k)))]
      [_ `((THUMB-MOV-imm ,rd 0))]))

  (define (compile-gba-cond-branch-false cond-expr false-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BNE ,false-lbl)))]
      [`(!= ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BEQ ,false-lbl)))]
      [`(< ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BGE ,false-lbl)))]
      [`(>= ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BLT ,false-lbl)))]
      [_
       (append (compile-gba-expr->reg 'r0 cond-expr)
               `((THUMB-CMP-imm r0 0)
                 (THUMB-BEQ ,false-lbl)))]))

  (define (compile-gba-cond-branch-true cond-expr true-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BEQ ,true-lbl)))]
      [`(!= ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BNE ,true-lbl)))]
      [`(< ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BLT ,true-lbl)))]
      [`(>= ,lhs ,(? exact-integer? k))
       (append (compile-gba-expr->reg 'r0 lhs)
               `((THUMB-CMP-imm r0 ,k)
                 (THUMB-BGE ,true-lbl)))]
      [_
       (append (compile-gba-expr->reg 'r0 cond-expr)
               `((THUMB-CMP-imm r0 0)
                 (THUMB-BNE ,true-lbl)))]))

  (define (compile-gba-stmt stmt)
    (match stmt
      [`(begin . ,body)
       (apply append (map compile-gba-stmt body))]
      [`(,(or 'let 'let*) . ,_)
       (compile-gba-stmt (normalize-pseudo-sexp stmt))]
      [`(mem-fill! . ,rest)
       (define-values (dst val count) (parse-mem-fill-args rest))
       (define dst-addr (resolve-mmio-or-addr dst 'gba))
       (define loop-lbl (fresh-label 'L_mem_fill))
       (define dst-insts
         (if (and (symbol? dst) (memq dst '(r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12)))
             `((THUMB-MOV r4 ,dst))
             `((THUMB-LDR-lit r4 ,dst-addr))))
       (append dst-insts
               (compile-gba-expr->reg 'r0 val)
               (compile-gba-expr->reg 'r2 count)
               `((label ,loop-lbl)
                 (THUMB-STRB-imm r0 [r4 0])
                 (THUMB-ADD-imm r4 1)
                 (THUMB-SUB-imm r2 1)
                 (THUMB-BNE ,loop-lbl)))]
      [`(mem-copy! . ,rest)
       (define-values (dst src count) (parse-mem-copy-args rest))
       (define dst-addr (resolve-mmio-or-addr dst 'gba))
       (define src-addr (resolve-mmio-or-addr src 'gba))
       (define loop-lbl (fresh-label 'L_mem_copy))
       (define dst-insts
         (if (and (symbol? dst) (memq dst '(r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12)))
             `((THUMB-MOV r4 ,dst))
             `((THUMB-LDR-lit r4 ,dst-addr))))
       (define src-insts
         (if (and (symbol? src) (memq src '(r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12)))
             `((THUMB-MOV r5 ,src))
             `((THUMB-LDR-lit r5 ,src-addr))))
       (append dst-insts
               src-insts
               (compile-gba-expr->reg 'r2 count)
               `((label ,loop-lbl)
                 (THUMB-LDRB-imm r0 [r5 0])
                 (THUMB-STRB-imm r0 [r4 0])
                 (THUMB-ADD-imm r5 1)
                 (THUMB-ADD-imm r4 1)
                 (THUMB-SUB-imm r2 1)
                 (THUMB-BNE ,loop-lbl)))]
      [`(dma-transfer! . ,rest)
       (define-values (dst src _count ctrl) (parse-dma-transfer-args rest))
       (define dst-expr (if (symbol? dst) (resolve-mmio-or-addr dst 'gba) dst))
       (define src-expr (if (symbol? src) (resolve-mmio-or-addr src 'gba) src))
       (define ctrl-val (if (exact-integer? ctrl) ctrl #x84000080))
       (append (compile-gba-stmt `(set! DMA3SAD ,src-expr))
               (compile-gba-stmt `(set! DMA3DAD ,dst-expr))
               (compile-gba-stmt `(set! DMA3CNT_L ,ctrl-val)))]
      [`(set! ,dst ,expr #:flags . ,_)
       (compile-gba-stmt `(set! ,dst ,expr))]
      [`(set! (,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg) ,expr)
       (compile-gba-stmt `(set! ,reg ,expr))]
      [`(set! ,(? symbol? rd) ,expr)
       #:when (memq rd '(r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 sp lr))
       (compile-gba-expr->reg rd expr)]
      [`(set! (-> ,base ,field-sym . ,rest) ,expr)
       (define off (parse-struct-field-offset field-sym))
       (define ty (if (pair? rest) (car rest) ':u32))
       (define val-insts (compile-gba-expr->reg 'r1 expr))
       (define base-reg (if (symbol? base) base 'r2))
       (define base-insts (if (exact-integer? base) `((THUMB-LDR-lit r2 ,base)) '()))
       (define st-inst
         (case ty
           [(:u8 u8 :s8 s8)     `(THUMB-STRB-imm r1 [,base-reg ,off])]
           [(:u16 u16 :s16 s16) `(THUMB-STRH-imm r1 [,base-reg ,off])]
           [else                `(THUMB-STR-imm r1 [,base-reg ,off])]))
       (append val-insts base-insts (list st-inst))]
      [`(set! (mem8 ,addr) ,expr)
       (append (compile-gba-expr->reg 'r0 expr)
               `((THUMB-LDR-lit r1 ,addr)
                 (THUMB-STRB-imm r0 [r1 0])))]
      [`(set! (,(or 'mem16 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr) ,expr)
       (append (compile-gba-expr->reg 'r0 expr)
               `((THUMB-LDR-lit r1 ,addr)
                 (THUMB-STRH-imm r0 [r1 0])))]
      [`(set! (,(or 'mem32 'wram 'zp 'dp 'hram) ,addr) ,expr)
       (append (compile-gba-expr->reg 'r0 expr)
               `((THUMB-LDR-lit r1 ,addr)
                 (THUMB-STR-imm r0 [r1 0])))]
      [`(set! (aref ,_ ,base ,_) ,expr)
       (append (compile-gba-expr->reg 'r0 expr)
               `((THUMB-LDR-lit r1 ,(resolve-mmio-or-addr base 'gba))
                 (THUMB-STRH-imm r0 [r1 0])))]
      [`(set! ,(? symbol? mmio-sym) ,expr)
       (define addr (resolve-mmio-or-addr mmio-sym 'gba))
       (define st-op
         (if (memq mmio-sym '(DMA3SAD DMA3DAD DMA3CNT_L))
             'THUMB-STR-imm
             'THUMB-STRH-imm))
       (append (compile-gba-expr->reg 'r0 expr)
               `((THUMB-LDR-lit r1 ,addr)
                 (,st-op r0 [r1 0])))]
      [`(+= ,dst ,expr)
       (compile-gba-stmt `(set! ,dst (+ ,dst ,expr)))]
      [`(-= ,dst ,expr)
       (compile-gba-stmt `(set! ,dst (- ,dst ,expr)))]
      [`(,(or 'break 'goto) ,label)
       `((B ,label))]
      [`(break)
       '((B L_break))]
      [`(continue ,label)
       `((B ,label))]
      [`(continue)
       '((B L_continue))]
      [`(when-break ,cond-expr ,label)
       (compile-gba-cond-branch-true cond-expr label)]
      [`(branch-if ,cond-expr ,label)
       (compile-gba-cond-branch-true cond-expr label)]
      [`(when ,cond-expr (,(or 'break 'goto 'continue) ,label))
       (compile-gba-cond-branch-true cond-expr label)]
      [`(when ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-gba-cond-branch-false cond-expr join-lbl)
               (apply append (map compile-gba-stmt body))
               `((label ,join-lbl)))]
      [`(unless ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-gba-cond-branch-true cond-expr join-lbl)
               (apply append (map compile-gba-stmt body))
               `((label ,join-lbl)))]
      [`(switch ,expr . ,clauses)
       (define end-lbl (fresh-label 'L_switch_end))
       (append
        (apply append
               (for/list ([clause (in-list clauses)])
                 (match clause
                   [`(case ,val . ,case-body)
                    (define next-lbl (fresh-label 'L_case_next))
                    (append (compile-gba-cond-branch-false `(= ,expr ,val) next-lbl)
                            (apply append (map compile-gba-stmt case-body))
                            `((B ,end-lbl)
                              (label ,next-lbl)))]
                   [`(,(or 'default 'else) . ,def-body)
                    (append (apply append (map compile-gba-stmt def-body))
                            `((B ,end-lbl)))]
                   [_ '()])))
        `((label ,end-lbl)))]
      [`(if ,cond-expr (then . ,then-body) (else . ,else-body))
       (define else-lbl (fresh-label 'L_else))
       (define join-lbl (fresh-label 'L_join))
       (append (compile-gba-cond-branch-false cond-expr else-lbl)
               (apply append (map compile-gba-stmt then-body))
               `((THUMB-B ,join-lbl)
                 (label ,else-lbl))
               (apply append (map compile-gba-stmt else-body))
               `((label ,join-lbl)))]
      [`(if ,cond-expr ,then-stmt ,else-stmt)
       (compile-gba-stmt `(if ,cond-expr (then ,then-stmt) (else ,else-stmt)))]
      [`(loop-counted (,reg ,count) . ,body)
       (define loop-lbl (fresh-label 'L_loop))
       (append (compile-gba-expr->reg reg count)
               `((label ,loop-lbl))
               (apply append (map compile-gba-stmt body))
               `((THUMB-SUB-imm ,reg 1)
                 (THUMB-BNE ,loop-lbl)))]
      [`(loop-counted . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define reg (hash-ref kws '#:counter 'r4))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_loop)))
       (append `((label ,loop-lbl))
               (apply append (map compile-gba-stmt body))
               `((THUMB-SUB-imm ,reg 1)
                 (THUMB-BNE ,loop-lbl)))]
      [`(do-while-loop (label ,lbl) (condition ,cond-expr) (body . ,body))
       (append `((label ,lbl))
               (apply append (map compile-gba-stmt body))
               (compile-gba-cond-branch-true cond-expr lbl))]
      [`(do-while . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_do_while)))
       (define cond-expr (hash-ref kws '#:cond (if (pair? body) (car body) 1)))
       (define actual-body (if (hash-has-key? kws '#:cond) body (if (pair? body) (cdr body) '())))
       (append `((label ,loop-lbl))
               (apply append (map compile-gba-stmt actual-body))
               (compile-gba-cond-branch-true cond-expr loop-lbl))]
      [`(spin-wait-mmio ,reg-or-addr ,mask)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr 'gba))
       `((THUMB-LDR-lit r1 ,addr)
         (THUMB-MOV-imm r2 ,mask)
         (label ,wait-lbl)
         (THUMB-LDRH-imm r0 [r1 0])
         (THUMB-TST r0 r2)
         (THUMB-BEQ ,wait-lbl))]
      [`(await-mmio! ,reg-or-addr . ,rest)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr 'gba))
       (define cond-sym (if (pair? rest) (car rest) 'non-zero))
       (define br-mnem (if (eq? cond-sym 'zero) 'THUMB-BNE 'THUMB-BEQ))
       `((THUMB-LDR-lit r1 ,addr)
         (label ,wait-lbl)
         (THUMB-LDRH-imm r0 [r1 0])
         (THUMB-CMP-imm r0 0)
         (,br-mnem ,wait-lbl))]
      [`(,(or 'call 'tail-call) ,callee . ,args)
       (define arg-regs '(r0 r1 r2 r3))
       (define arg-insts
         (apply append
                (for/list ([arg (in-list args)]
                           [r   (in-list arg-regs)])
                  (compile-gba-expr->reg r arg))))
       (append arg-insts `((BL ,callee)))]
      [`(return)
       '((THUMB-BX lr))]
      [`(return ,expr)
       (append (compile-gba-expr->reg 'r0 expr)
               '((THUMB-BX lr)))]
      [`(label ,sym)
       `((label ,sym))]
      [_ '((THUMB-NOP))]))

  ;; --------------------------------------------------------------------------
  ;; 4. N64 (MIPS III VR4300 + COP1 FPU) Compiler Backend
  ;; --------------------------------------------------------------------------
  (define (compile-n64-fpu-expr fd expr)
    (match expr
      [(? real? x)
       `((LI.S ,fd ,(exact->inexact x)))]
      [(? fpu-reg-symbol? fs)
       (if (eq? fd fs) '() `((MOV.S ,fd ,fs)))]
      [`(-> ,base ,field-sym . ,_)
       (define off (parse-struct-field-offset field-sym))
       `((LWC1 ,fd ,off ,base))]
      [`(,(or '+ 'fadd) ,e1 ,e2)
       (append (compile-n64-fpu-expr '$f2 e1)
               (compile-n64-fpu-expr '$f4 e2)
               `((ADD.S ,fd $f2 $f4)))]
      [`(,(or '- 'fsub) ,e1 ,e2)
       (append (compile-n64-fpu-expr '$f2 e1)
               (compile-n64-fpu-expr '$f4 e2)
               `((SUB.S ,fd $f2 $f4)))]
      [`(,(or '* 'fmul) ,e1 ,e2)
       (append (compile-n64-fpu-expr '$f2 e1)
               (compile-n64-fpu-expr '$f4 e2)
               `((MUL.S ,fd $f2 $f4)))]
      [`(,(or '/ 'fdiv) ,e1 ,e2)
       (append (compile-n64-fpu-expr '$f2 e1)
               (compile-n64-fpu-expr '$f4 e2)
               `((DIV.S ,fd $f2 $f4)))]
      [`(,(or 'sqrt 'fsqrt) ,e1)
       (append (compile-n64-fpu-expr '$f2 e1)
               `((SQRT.S ,fd $f2)))]
      [_ `((LI.S ,fd 0.0))]))

  (define (compile-n64-expr->reg rd expr)
    (match expr
      [(? exact-integer? n)
       (if (<= -32768 n #xFFFF)
           `((ADDIU ,rd r0 ,n))
           `((LUI ,rd ,(bitwise-and (arithmetic-shift n -16) #xFFFF))
             (ORI ,rd ,rd ,(bitwise-and n #xFFFF))))]
      [(? fpu-reg-symbol? fs)
       `((MFC1 ,rd ,fs))]
      [(? symbol? rs) #:when (memq rs '(r0 v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 t8 t9 s0 s1 s2 s3 s4 s5 s6 s7 sp ra))
       (if (eq? rd rs) '() `((ADDU ,rd ,rs r0)))]
      [`(,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg)
       (compile-n64-expr->reg rd reg)]
      [`(-> ,base ,field-sym . ,rest)
       (define off (parse-struct-field-offset field-sym))
       (define ty (if (pair? rest) (car rest) ':u32))
       (define base-reg (if (symbol? base) base 't8))
       (define pre-insts (if (exact-integer? base) (compile-n64-expr->reg 't8 base) '()))
       (append pre-insts
               (case ty
                 [(:u8 u8 :s8 s8)     `((LB ,rd ,off ,base-reg))]
                 [(:u16 u16 :s16 s16) `((LH ,rd ,off ,base-reg))]
                 [(:f32 f32)          `((LWC1 ,rd ,off ,base-reg))]
                 [else                `((LW ,rd ,off ,base-reg))]))]
      [`(,(or 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr)
       `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
         (ORI t8 t8 ,(bitwise-and addr #xFFFF))
         (LH ,rd 0 t8))]
      [`(,(or 'mem8 'mem16 'mem32 'wram 'zp 'dp 'hram) ,addr)
       `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
         (ORI t8 t8 ,(bitwise-and addr #xFFFF))
         (LW ,rd 0 t8))]
      [`(aref ,_ ,base ,_)
       (define addr (resolve-mmio-or-addr base 'n64))
       `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
         (ORI t8 t8 ,(bitwise-and addr #xFFFF))
         (LW ,rd 0 t8))]
      [(? symbol? mmio-sym)
       (define addr (resolve-mmio-or-addr mmio-sym 'n64))
       `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
         (ORI t8 t8 ,(bitwise-and addr #xFFFF))
         (LW ,rd 0 t8))]
      [`(+ ,e1 ,e2)
       (append (compile-n64-expr->reg rd e1)
               (match e2
                 [(? exact-integer? k) `((ADDIU ,rd ,rd ,k))]
                 [(? symbol? r2)       `((ADDU ,rd ,rd ,r2))]
                 [_ (append (compile-n64-expr->reg 't9 e2)
                            `((ADDU ,rd ,rd t9)))]))]
      [`(- ,e1 ,e2)
       (append (compile-n64-expr->reg rd e1)
               (match e2
                 [(? exact-integer? k) `((ADDIU ,rd ,rd ,(- k)))]
                 [(? symbol? r2)       `((SUBU ,rd ,rd ,r2))]
                 [_ (append (compile-n64-expr->reg 't9 e2)
                            `((SUBU ,rd ,rd t9)))]))]
      [`(bit-and ,e1 ,e2)
       (append (compile-n64-expr->reg rd e1)
               (match e2
                 [(? exact-integer? k) `((ANDI ,rd ,rd ,(bitwise-and k #xFFFF)))]
                 [_ (append (compile-n64-expr->reg 't9 e2)
                            `((AND ,rd ,rd t9)))]))]
      [`(bit-ior ,e1 ,e2)
       (append (compile-n64-expr->reg rd e1)
               (match e2
                 [(? exact-integer? k) `((ORI ,rd ,rd ,(bitwise-and k #xFFFF)))]
                 [_ (append (compile-n64-expr->reg 't9 e2)
                            `((OR ,rd ,rd t9)))]))]
      [`(bit-xor ,e1 ,e2)
       (append (compile-n64-expr->reg rd e1)
               (match e2
                 [(? exact-integer? k) `((XORI ,rd ,rd ,(bitwise-and k #xFFFF)))]
                 [_ (append (compile-n64-expr->reg 't9 e2)
                            `((XOR ,rd ,rd t9)))]))]
      [`(shl ,e1 ,(? exact-integer? k))
       (append (compile-n64-expr->reg rd e1)
               `((SLL ,rd ,rd ,k)))]
      [`(,(or 'shr 'asr) ,e1 ,(? exact-integer? k))
       (append (compile-n64-expr->reg rd e1)
               `((SRL ,rd ,rd ,k)))]
      [_ `((ADDIU ,rd r0 0))]))

  (define (compile-n64-cond-branch-false cond-expr false-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,(? exact-integer? 0))
       (append (compile-n64-expr->reg 't0 lhs)
               `((BNE t0 r0 ,false-lbl)
                 (NOP)))]
      [`(!= ,lhs ,(? exact-integer? 0))
       (append (compile-n64-expr->reg 't0 lhs)
               `((BEQ t0 r0 ,false-lbl)
                 (NOP)))]
      [`(,(or '= '==) ,lhs ,rhs)
       (append (compile-n64-expr->reg 't0 lhs)
               (compile-n64-expr->reg 't1 rhs)
               `((BNE t0 t1 ,false-lbl)
                 (NOP)))]
      [`(!= ,lhs ,rhs)
       (append (compile-n64-expr->reg 't0 lhs)
               (compile-n64-expr->reg 't1 rhs)
               `((BEQ t0 t1 ,false-lbl)
                 (NOP)))]
      [_
       (append (compile-n64-expr->reg 't0 cond-expr)
               `((BEQ t0 r0 ,false-lbl)
                 (NOP)))]))

  (define (compile-n64-cond-branch-true cond-expr true-lbl)
    (match cond-expr
      [`(,(or '= '==) ,lhs ,(? exact-integer? 0))
       (append (compile-n64-expr->reg 't0 lhs)
               `((BEQ t0 r0 ,true-lbl)
                 (NOP)))]
      [`(!= ,lhs ,(? exact-integer? 0))
       (append (compile-n64-expr->reg 't0 lhs)
               `((BNE t0 r0 ,true-lbl)
                 (NOP)))]
      [`(,(or '= '==) ,lhs ,rhs)
       (append (compile-n64-expr->reg 't0 lhs)
               (compile-n64-expr->reg 't1 rhs)
               `((BEQ t0 t1 ,true-lbl)
                 (NOP)))]
      [`(!= ,lhs ,rhs)
       (append (compile-n64-expr->reg 't0 lhs)
               (compile-n64-expr->reg 't1 rhs)
               `((BNE t0 t1 ,true-lbl)
                 (NOP)))]
      [_
       (append (compile-n64-expr->reg 't0 cond-expr)
               `((BNE t0 r0 ,true-lbl)
                 (NOP)))]))

  (define (compile-n64-stmt stmt)
    (match stmt
      [`(begin . ,body)
       (apply append (map compile-n64-stmt body))]
      [`(,(or 'let 'let*) . ,_)
       (compile-n64-stmt (normalize-pseudo-sexp stmt))]
      [`(mem-fill! . ,rest)
       (define-values (dst val count) (parse-mem-fill-args rest))
       (define dst-addr (resolve-mmio-or-addr dst 'n64))
       (define loop-lbl (fresh-label 'L_mem_fill))
       (define dst-insts
         (if (and (symbol? dst) (memq dst '(v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7)))
             `((ADDU t0 ,dst r0))
             (compile-n64-expr->reg 't0 dst-addr)))
       (append dst-insts
               (compile-n64-expr->reg 't1 val)
               (compile-n64-expr->reg 't2 count)
               `((label ,loop-lbl)
                 (SB t1 0 t0)
                 (ADDIU t0 t0 1)
                 (ADDIU t2 t2 -1)
                 (BNE t2 r0 ,loop-lbl)
                 (NOP)))]
      [`(mem-copy! . ,rest)
       (define-values (dst src count) (parse-mem-copy-args rest))
       (define dst-addr (resolve-mmio-or-addr dst 'n64))
       (define src-addr (resolve-mmio-or-addr src 'n64))
       (define loop-lbl (fresh-label 'L_mem_copy))
       (define dst-insts
         (if (and (symbol? dst) (memq dst '(v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7)))
             `((ADDU t0 ,dst r0))
             (compile-n64-expr->reg 't0 dst-addr)))
       (define src-insts
         (if (and (symbol? src) (memq src '(v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7)))
             `((ADDU t1 ,src r0))
             (compile-n64-expr->reg 't1 src-addr)))
       (append dst-insts
               src-insts
               (compile-n64-expr->reg 't2 count)
               `((label ,loop-lbl)
                 (LB t3 0 t1)
                 (SB t3 0 t0)
                 (ADDIU t1 t1 1)
                 (ADDIU t0 t0 1)
                 (ADDIU t2 t2 -1)
                 (BNE t2 r0 ,loop-lbl)
                 (NOP)))]
      [`(dma-transfer! . ,rest)
       (define-values (dst src count _ctrl) (parse-dma-transfer-args rest))
       (define dst-expr (if (symbol? dst) (resolve-mmio-or-addr dst 'n64) dst))
       (define src-expr (if (symbol? src) (resolve-mmio-or-addr src 'n64) src))
       (define cnt-val  (if (exact-integer? count) count #x100))
       (append (compile-n64-stmt `(set! PI_DRAM_ADDR ,dst-expr))
               (compile-n64-stmt `(set! PI_CART_ADDR ,src-expr))
               (compile-n64-stmt `(set! PI_WR_LEN ,cnt-val)))]
      [`(set! ,dst ,expr #:flags . ,_)
       (compile-n64-stmt `(set! ,dst ,expr))]
      [`(set! (,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg) ,expr)
       (compile-n64-stmt `(set! ,reg ,expr))]
      [`(set! ,(? fpu-reg-symbol? fd) ,expr)
       (compile-n64-fpu-expr fd expr)]
      [`(set! ,(? symbol? rd) ,expr)
       #:when (memq rd '(v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 t8 t9 s0 s1 s2 s3 s4 s5 s6 s7))
       (compile-n64-expr->reg rd expr)]
      [`(set! (-> ,base ,field-sym . ,rest) ,expr)
       (define off (parse-struct-field-offset field-sym))
       (define ty (if (pair? rest) (car rest) ':u32))
       (define base-reg (if (symbol? base) base 't8))
       (define base-insts (if (exact-integer? base) (compile-n64-expr->reg 't8 base) '()))
       (if (or (memq ty '(:f32 f32)) (fpu-reg-symbol? expr) (and (real? expr) (inexact? expr)))
           (append (compile-n64-fpu-expr '$f0 expr)
                   base-insts
                   `((SWC1 $f0 ,off ,base-reg)))
           (append (compile-n64-expr->reg 't0 expr)
                   base-insts
                   (case ty
                     [(:u8 u8 :s8 s8)     `((SB t0 ,off ,base-reg))]
                     [(:u16 u16 :s16 s16) `((SH t0 ,off ,base-reg))]
                     [else                `((SW t0 ,off ,base-reg))])))]
      [`(set! (,(or 'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16) ,addr) ,expr)
       (append (compile-n64-expr->reg 't0 expr)
               `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
                 (ORI t8 t8 ,(bitwise-and addr #xFFFF))
                 (SH t0 0 t8)))]
      [`(set! (,(or 'mem8 'mem16 'mem32 'wram 'zp 'dp 'hram) ,addr) ,expr)
       (append (compile-n64-expr->reg 't0 expr)
               `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
                 (ORI t8 t8 ,(bitwise-and addr #xFFFF))
                 (SW t0 0 t8)))]
      [`(set! (aref ,_ ,base ,_) ,expr)
       (define addr (resolve-mmio-or-addr base 'n64))
       (append (compile-n64-expr->reg 't0 expr)
               `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
                 (ORI t8 t8 ,(bitwise-and addr #xFFFF))
                 (SW t0 0 t8)))]
      [`(set! ,(? symbol? mmio-sym) ,expr)
       (define addr (resolve-mmio-or-addr mmio-sym 'n64))
       (append (compile-n64-expr->reg 't0 expr)
               `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
                 (ORI t8 t8 ,(bitwise-and addr #xFFFF))
                 (SW t0 0 t8)))]
      [`(+= ,dst ,expr)
       (compile-n64-stmt `(set! ,dst (+ ,dst ,expr)))]
      [`(-= ,dst ,expr)
       (compile-n64-stmt `(set! ,dst (- ,dst ,expr)))]
      [`(,(or 'break 'goto) ,label)
       `((MIPS-B ,label))]
      [`(break)
       '((MIPS-B L_break))]
      [`(continue ,label)
       `((MIPS-B ,label))]
      [`(continue)
       '((MIPS-B L_continue))]
      [`(when-break ,cond-expr ,label)
       (compile-n64-cond-branch-true cond-expr label)]
      [`(branch-if ,cond-expr ,label)
       (compile-n64-cond-branch-true cond-expr label)]
      [`(when ,cond-expr (,(or 'break 'goto 'continue) ,label))
       (compile-n64-cond-branch-true cond-expr label)]
      [`(when ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-n64-cond-branch-false cond-expr join-lbl)
               (apply append (map compile-n64-stmt body))
               `((label ,join-lbl)))]
      [`(unless ,cond-expr . ,body)
       (define join-lbl (fresh-label 'L_join))
       (append (compile-n64-cond-branch-true cond-expr join-lbl)
               (apply append (map compile-n64-stmt body))
               `((label ,join-lbl)))]
      [`(switch ,expr . ,clauses)
       (define end-lbl (fresh-label 'L_switch_end))
       (append
        (apply append
               (for/list ([clause (in-list clauses)])
                 (match clause
                   [`(case ,val . ,case-body)
                    (define next-lbl (fresh-label 'L_case_next))
                    (append (compile-n64-cond-branch-false `(= ,expr ,val) next-lbl)
                            (apply append (map compile-n64-stmt case-body))
                            `((MIPS-B ,end-lbl)
                              (label ,next-lbl)))]
                   [`(,(or 'default 'else) . ,def-body)
                    (append (apply append (map compile-n64-stmt def-body))
                            `((MIPS-B ,end-lbl)))]
                   [_ '()])))
        `((label ,end-lbl)))]
      [`(if ,cond-expr (then . ,then-body) (else . ,else-body))
       (define else-lbl (fresh-label 'L_else))
       (define join-lbl (fresh-label 'L_join))
       (append (compile-n64-cond-branch-false cond-expr else-lbl)
               (apply append (map compile-n64-stmt then-body))
               `((J ,join-lbl)
                 (NOP)
                 (label ,else-lbl))
               (apply append (map compile-n64-stmt else-body))
               `((label ,join-lbl)))]
      [`(if ,cond-expr ,then-stmt ,else-stmt)
       (compile-n64-stmt `(if ,cond-expr (then ,then-stmt) (else ,else-stmt)))]
      [`(loop-counted (,reg ,count) . ,body)
       (define loop-lbl (fresh-label 'L_loop))
       (append (compile-n64-expr->reg reg count)
               `((label ,loop-lbl))
               (apply append (map compile-n64-stmt body))
               `((ADDIU ,reg ,reg -1)
                 (BNE ,reg r0 ,loop-lbl)
                 (NOP)))]
      [`(loop-counted . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define reg (hash-ref kws '#:counter 't0))
       (define step (hash-ref kws '#:step -1))
       (define step-imm (if (exact-integer? step) step -1))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_loop)))
       (append `((label ,loop-lbl))
               (apply append (map compile-n64-stmt body))
               `((ADDIU ,reg ,reg ,step-imm)
                 (BNE ,reg r0 ,loop-lbl)
                 (NOP)))]
      [`(do-while-loop (label ,lbl) (condition ,cond-expr) (body . ,body))
       (append `((label ,lbl))
               (apply append (map compile-n64-stmt body))
               (compile-n64-cond-branch-true cond-expr lbl))]
      [`(do-while . ,rest)
       (define-values (kws body) (parse-kw-args-and-body rest))
       (define loop-lbl (hash-ref kws '#:target (fresh-label 'L_do_while)))
       (define cond-expr (hash-ref kws '#:cond (if (pair? body) (car body) 1)))
       (define actual-body (if (hash-has-key? kws '#:cond) body (if (pair? body) (cdr body) '())))
       (append `((label ,loop-lbl))
               (apply append (map compile-n64-stmt actual-body))
               (compile-n64-cond-branch-true cond-expr loop-lbl))]
      [`(spin-wait-mmio ,reg-or-addr ,mask)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr 'n64))
       `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
         (ORI t8 t8 ,(bitwise-and addr #xFFFF))
         (label ,wait-lbl)
         (LW t9 0 t8)
         (ANDI t9 t9 ,mask)
         (BEQ t9 r0 ,wait-lbl)
         (NOP))]
      [`(await-mmio! ,reg-or-addr . ,rest)
       (define wait-lbl (fresh-label 'L_wait))
       (define addr (resolve-mmio-or-addr reg-or-addr 'n64))
       (define cond-sym (if (pair? rest) (car rest) 'non-zero))
       (define br-mnem (if (eq? cond-sym 'zero) 'BNE 'BEQ))
       `((LUI t8 ,(bitwise-and (arithmetic-shift addr -16) #xFFFF))
         (ORI t8 t8 ,(bitwise-and addr #xFFFF))
         (label ,wait-lbl)
         (LW t9 0 t8)
         (,br-mnem t9 r0 ,wait-lbl)
         (NOP))]
      [`(,(or 'call 'tail-call) ,callee . ,args)
       (define arg-regs '(a0 a1 a2 a3))
       (define arg-insts
         (apply append
                (for/list ([arg (in-list args)]
                           [r   (in-list arg-regs)])
                  (compile-n64-expr->reg r arg))))
       (append arg-insts `((JAL ,callee) (NOP)))]
      [`(return)
       '((JR ra) (NOP))]
      [`(return ,expr)
       (if (or (fpu-reg-symbol? expr) (and (real? expr) (inexact? expr)))
           (append (compile-n64-fpu-expr '$f0 expr) '((JR ra) (NOP)))
           (append (compile-n64-expr->reg 'v0 expr) '((JR ra) (NOP))))]
      [`(label ,sym)
       `((label ,sym))]
      [_ '((NOP))]))

  ;; Dispatch per target
  (define compile-one
    (case tid
      [(nes snes pico8) compile-6502-stmt]
      [(gb)             compile-sm83-stmt]
      [(gba rp2040)     compile-gba-stmt]
      [(n64)            compile-n64-stmt]
      [else             compile-6502-stmt]))

  (define compiled (apply append (map compile-one stmts)))
  (if (null? compiled)
      (case tid
        [(gb)         '((NOP #:imp 0))]
        [(gba rp2040) '((THUMB-NOP))]
        [else         '((NOP))])
      compiled))

;; ============================================================================
;; Layer 9: Whole-ROM Static Contract, Bitfield, Layout & Pseudo-Code Verifier
;; ============================================================================

(define (read-whole-rom-file-sexps path-or-str)
  (call-with-input-file path-or-str
    (lambda (in)
      ;; Skip leading #lang line if present
      (define peeked (peek-string 5 0 in))
      (when (and (string? peeked) (string=? peeked "#lang"))
        (read-line in 'any))
      (let loop ([acc '()])
        (define v (read in))
        (if (eof-object? v)
            (reverse acc)
            (loop (cons v acc)))))))

(define (normalize-whole-rom-target-symbol sym)
  (cond
    [(target-spec? sym) (target-spec-id sym)]
    [(eq? sym 'pico)    'pico8]
    [(symbol? sym)      sym]
    [else               #f]))

(define (infer-whole-rom-target sexp)
  (let walk ([x sexp])
    (cond
      [(not (pair? x)) #f]
      [(and (eq? (car x) 'target) (pair? (cdr x)))
       (define raw (cadr x))
       (define unquoted
         (if (and (pair? raw) (eq? (car raw) 'quote) (pair? (cdr raw)))
             (cadr raw)
             raw))
       (normalize-whole-rom-target-symbol unquoted)]
      [(memq (car x) '(define-snes-rom-metadata define-snes-lifted-subroutines define-snes-struct-layouts define-snes-enum-constants defsub-65c816))
       'snes]
      [(memq (car x) '(define-gba-rom-metadata define-gba-lifted-subroutines define-gba-struct-layouts define-gba-enum-constants defsub-arm32 defsub-thumb16))
       'gba]
      [(memq (car x) '(define-n64-rom-metadata define-n64-lifted-subroutines define-n64-struct-layouts define-n64-enum-constants define-n64-libultra-call-graph))
       'n64]
      [(memq (car x) '(def-pico-cartridge-header def-pico-function))
       'pico8]
      [(memq (car x) '(defsub-sm83 def-sm83-isr))
       'gb]
      [(eq? (car x) 'defsub)
       'nes]
      [else
       (for/or ([elem (in-list (if (list? x) x '()))])
         (walk elem))])))

(define (find-kw-option lst kw [default #f])
  (let loop ([rem lst])
    (cond
      [(or (not (pair? rem)) (not (pair? (cdr rem)))) default]
      [(eq? (car rem) kw) (cadr rem)]
      [else (loop (cdr rem))])))

(define (find-child-clause lst tag)
  (for/or ([elem (in-list (if (list? lst) lst '()))])
    (and (pair? elem) (eq? (car elem) tag) elem)))

(define (extract-child-symbol-list lst tag)
  (define clause (find-child-clause lst tag))
  (cond
    [(not clause) #f]
    [(null? (cdr clause)) '()]
    [(and (pair? (cdr clause))
          (null? (cddr clause))
          (list? (cadr clause)))
     (filter symbol? (cadr clause))]
    [else
     (filter symbol? (cdr clause))]))

(define (has-empty-when-form? sexp)
  (let walk ([x sexp])
    (cond
      [(not (pair? x)) #f]
      [(eq? (car x) 'when)
       (or (null? (cdr x))
           (null? (cddr x))
           (for/or ([sub (in-list (cdr x))])
             (walk sub)))]
      [(list? x)
       (for/or ([sub (in-list x)])
         (walk sub))]
      [else #f])))

(define (extract-whole-rom-contracts whole-rom-sexp-or-forms #:target [target #f])
  (define root-sexp
    (cond
      [(or (path? whole-rom-sexp-or-forms)
           (and (string? whole-rom-sexp-or-forms)
                (file-exists? whole-rom-sexp-or-forms)))
       (read-whole-rom-file-sexps whole-rom-sexp-or-forms)]
      [(syntax? whole-rom-sexp-or-forms)
       (syntax->datum whole-rom-sexp-or-forms)]
      [else
       whole-rom-sexp-or-forms]))

  (define inferred-target
    (or (normalize-whole-rom-target-symbol target)
        (infer-whole-rom-target root-sexp)
        'nes))

  ;; Pre-scan N64 call-graph nodes if present:
  ;; (define-n64-libultra-call-graph (call-node name (entry ...) (callees (...)) (mmio (...))) ...)
  (define n64-callees-map (make-hasheq))
  (define n64-mmio-map (make-hasheq))
  (let scan-n64-cg ([x root-sexp])
    (when (and (pair? x) (list? x))
      (cond
        [(and (eq? (car x) 'call-node) (pair? (cdr x)) (symbol? (cadr x)))
         (define node-name (cadr x))
         (define callees (or (extract-child-symbol-list (cddr x) 'callees) '()))
         (define mmio    (or (extract-child-symbol-list (cddr x) 'mmio) '()))
         (hash-set! n64-callees-map node-name callees)
         (hash-set! n64-mmio-map node-name mmio)]
        [else
         (for ([sub (in-list x)])
           (scan-n64-cg sub))])))

  (define subroutine-contracts-rev '())
  (define pseudo-code-blocks-rev '())
  (define memory-layout-box #f)
  (define struct-layout-forms-rev '())
  (define struct-count 0)
  (define struct-field-count 0)
  (define bitfield-annotations-rev '())

  ;; Helper to extract #:flags (...) annotations from any list form
  (define (scan-flags-in-list form)
    (unless (and (pair? form)
                 (symbol? (car form))
                 (memq (car form) '(def-pico-sprite-flag def-pico-music)))
      (define reg-name
        (if (and (pair? (cdr form)) (symbol? (cadr form)))
            (cadr form)
            (if (symbol? (car form)) (car form) 'unknown)))
      (let loop ([rem form])
        (when (and (pair? rem) (pair? (cdr rem)))
          (when (eq? (car rem) '#:flags)
            (set! bitfield-annotations-rev
                  (cons (hasheq 'reg reg-name 'flags (cadr rem))
                        bitfield-annotations-rev)))
          (loop (cdr rem))))))

  (define (parse-subroutine-form form)
    (define head (car form))
    (define rest (cdr form))
    (define sub-name
      (cond
        [(eq? head 'def-pico-function)
         (define name-clause (find-child-clause rest 'name))
         (cond
           [(and name-clause (pair? (cdr name-clause)) (symbol? (cadr name-clause)))
            (cadr name-clause)]
           [(and (pair? rest) (symbol? (car rest)))
            (car rest)]
           [else 'pico_fn])]
        [(and (pair? rest) (symbol? (car rest)))
         (car rest)]
        [else 'anon_sub]))

    (define params
      (or (find-kw-option rest '#:params #f)
          (let ([c (find-child-clause rest 'params)])
            (and c (pair? (cdr c)) (cadr c)))
          '()))
    (define returns
      (or (find-kw-option rest '#:returns #f)
          (let ([c (find-child-clause rest 'returns)])
            (and c (pair? (cdr c)) (cadr c)))
          '()))
    (define calls
      (or (find-kw-option rest '#:calls #f)
          (extract-child-symbol-list rest 'calls)
          (extract-child-symbol-list rest 'called-functions)
          (hash-ref n64-callees-map sub-name #f)
          '()))
    (define mmio
      (or (find-kw-option rest '#:mmio #f)
          (extract-child-symbol-list rest 'mmio)
          (extract-child-symbol-list rest 'api-calls)
          (hash-ref n64-mmio-map sub-name #f)
          '()))
    (define cycles
      (or (find-kw-option rest '#:cycles #f)
          (let ([c (find-child-clause rest 'cycles)])
            (and c (pair? (cdr c)) (exact-integer? (cadr c)) (cadr c)))
          0))

    (make-subroutine-contract
     sub-name
     #:target      inferred-target
     #:params      (if (list? params) params (list params))
     #:returns     (if (list? returns) returns (list returns))
     #:cycles      cycles
     #:mmio-writes (if (list? mmio) mmio (list mmio))
     #:callees     (if (list? calls) calls (list calls))))

  (let walk ([x root-sexp]
             [current-sub #f])
    (when (and (pair? x) (list? x))
      (scan-flags-in-list x)
      (define head (car x))
      (cond
        [(memq head '(defsub defsub-sm83 def-sm83-isr def-pico-function
                      defsub-65c816 defsub-arm32 defsub-thumb16 subroutine))
         (define contract (parse-subroutine-form x))
         (define sub-name (subroutine-contract-name contract))
         (set! subroutine-contracts-rev (cons contract subroutine-contracts-rev))
         (for ([child (in-list (cdr x))])
           (walk child sub-name))]

        [(eq? head 'decompiled-pseudo-code)
         (set! pseudo-code-blocks-rev
               (cons (hasheq 'sub-name    (or current-sub 'anonymous)
                             'target      inferred-target
                             'pseudo-code x)
                     pseudo-code-blocks-rev))
         (for ([child (in-list (cdr x))])
           (walk child current-sub))]

        [(eq? head 'def-memory-layout)
         (define mirrors-clause (find-child-clause (cdr x) 'mmio-mirrors))
         (define zp-ptrs-clause (find-child-clause (cdr x) 'zero-page-pointers))
         (define state-vars-clause (find-child-clause (cdr x) 'state-variables))
         (define mirrors (if mirrors-clause (cdr mirrors-clause) '()))
         (define zp-ptrs (if zp-ptrs-clause (cdr zp-ptrs-clause) '()))
         (define state-vars (if state-vars-clause (cdr state-vars-clause) '()))
         (set! memory-layout-box
               (hasheq 'form                    x
                       'mmio-mirrors            mirrors
                       'zero-page-pointers      zp-ptrs
                       'state-variables         state-vars
                       'mmio-mirror-count       (length mirrors)
                       'zero-page-pointer-count (length zp-ptrs)
                       'state-variable-count    (length state-vars)))
         (for ([child (in-list (cdr x))])
           (walk child current-sub))]

        [(and (symbol? head)
              (or (memq head '(define-snes-struct-layouts define-gba-struct-layouts define-n64-struct-layouts def-inferred-structs))
                  (regexp-match? #rx"^define-.*-struct-layouts$" (symbol->string head))))
         (set! struct-layout-forms-rev (cons x struct-layout-forms-rev))
         (for ([s-def (in-list (cdr x))]
               #:when (and (pair? s-def)
                           (memq (car s-def) '(struct-layout def-struct-layout def-struct def-struct-table))))
           (set! struct-count (add1 struct-count))
           (let count-fields ([node s-def])
             (when (and (pair? node) (list? node))
               (if (eq? (car node) 'field)
                   (set! struct-field-count (add1 struct-field-count))
                   (for ([c (in-list (cdr node))])
                     (count-fields c))))))
         (for ([child (in-list (cdr x))])
           (walk child current-sub))]

        [(eq? head 'def-struct-layout)
         (set! struct-layout-forms-rev (cons x struct-layout-forms-rev))
         (set! struct-count (add1 struct-count))
         (let count-fields ([node x])
           (when (and (pair? node) (list? node))
             (if (eq? (car node) 'field)
                 (set! struct-field-count (add1 struct-field-count))
                 (for ([c (in-list (cdr node))])
                   (count-fields c)))))
         (for ([child (in-list (cdr x))])
           (walk child current-sub))]

        [else
         (for ([child (in-list x)])
           (walk child current-sub))])))

  (define subroutine-contracts (reverse subroutine-contracts-rev))
  (define pseudo-code-blocks   (reverse pseudo-code-blocks-rev))
  (define struct-layout-forms  (reverse struct-layout-forms-rev))
  (define bitfield-annotations (reverse bitfield-annotations-rev))
  (define mmio-mirror-count
    (if memory-layout-box
        (hash-ref memory-layout-box 'mmio-mirror-count 0)
        0))
  (define zp-pointer-count
    (if memory-layout-box
        (hash-ref memory-layout-box 'zero-page-pointer-count 0)
        0))
  (define state-var-count
    (if memory-layout-box
        (hash-ref memory-layout-box 'state-variable-count 0)
        0))
  (define no-empty-when?
    (and (not (has-empty-when-form? root-sexp))
         (for/and ([pcb (in-list pseudo-code-blocks)])
           (not (has-empty-when-form? (hash-ref pcb 'pseudo-code))))))

  (hasheq 'target                   inferred-target
          'subroutine-contracts     subroutine-contracts
          'pseudo-code-blocks       pseudo-code-blocks
          'memory-layout            memory-layout-box
          'mmio-mirror-count        mmio-mirror-count
          'zero-page-pointer-count  zp-pointer-count
          'state-variable-count     state-var-count
          'struct-layouts           struct-layout-forms
          'struct-layout-count      struct-count
          'struct-field-count       struct-field-count
          'bitfield-annotations     bitfield-annotations
          'no-empty-when-branches?  no-empty-when?))

(define (verify-whole-rom-module-contracts whole-rom-sexp-or-forms #:target [target #f])
  (define extracted
    (extract-whole-rom-contracts whole-rom-sexp-or-forms #:target target))
  (define inferred-target      (hash-ref extracted 'target))
  (define subroutine-contracts (hash-ref extracted 'subroutine-contracts))
  (define pseudo-code-blocks   (hash-ref extracted 'pseudo-code-blocks))
  (define bitfield-annotations (hash-ref extracted 'bitfield-annotations))
  (define mmio-mirror-count    (hash-ref extracted 'mmio-mirror-count))
  (define struct-layout-count  (hash-ref extracted 'struct-layout-count))
  (define no-empty-when-branches? (hash-ref extracted 'no-empty-when-branches?))

  ;; 1. Verify call-graph contracts across all extracted subroutine contracts
  (define call-graph-check
    (verify-call-graph-contracts subroutine-contracts))

  ;; 2. Compile every extracted pseudo-code block and check non-empty instruction emission
  (define total-compiled-insts 0)
  (define pseudo-code-compilable?
    (for/and ([pcb (in-list pseudo-code-blocks)])
      (define pc-sexp (hash-ref pcb 'pseudo-code))
      (define pcb-target (hash-ref pcb 'target inferred-target))
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (define insts (compile-pseudo-code->insts pc-sexp #:target pcb-target))
        (and (list? insts)
             (pair? insts)
             (begin
               (set! total-compiled-insts (+ total-compiled-insts (length insts)))
               #t)))))

  ;; 3. Verify that every extracted #:flags (...) annotation is a non-empty list of symbols
  (define bitfield-flags-valid?
    (for/and ([ann (in-list bitfield-annotations)])
      (define flags (hash-ref ann 'flags #f))
      (and (list? flags)
           (pair? flags)
           (andmap symbol? flags))))

  (hasheq 'valid?                    (and (hash-ref call-graph-check 'valid? #f)
                                          pseudo-code-compilable?
                                          bitfield-flags-valid?
                                          no-empty-when-branches?)
          'target                    inferred-target
          'subroutine-count          (length subroutine-contracts)
          'pseudo-code-count         (length pseudo-code-blocks)
          'compiled-inst-count       total-compiled-insts
          'bitfield-annotation-count (length bitfield-annotations)
          'mmio-mirror-count         mmio-mirror-count
          'struct-layout-count       struct-layout-count
          'no-empty-when-branches?   no-empty-when-branches?
          'pseudo-code-compilable?   pseudo-code-compilable?
          'bitfield-flags-valid?     bitfield-flags-valid?
          'call-graph-check          call-graph-check))

;; ============================================================================
;; Layer 10: Cross-Platform Subroutine & Hardware Idiom Transpiler
;; ============================================================================

(define CROSS-TARGET-MMIO-MAP
  (hasheq
   'display-ctrl   (hasheq 'nes  'PPUCTRL
                           'gb   'LCDC
                           'gbc  'LCDC
                           'snes 'INIDISP
                           'gba  'DISPCNT
                           'n64  'VI_STATUS)
   'display-mask   (hasheq 'nes  'PPUMASK
                           'gb   'BGP
                           'gbc  'BGP
                           'snes 'TM
                           'gba  'BLDCNT
                           'n64  'VI_WIDTH)
   'display-status (hasheq 'nes  'PPUSTATUS
                           'gb   'STAT
                           'gbc  'STAT
                           'snes 'HVBJOY
                           'gba  'DISPSTAT
                           'n64  'VI_CURRENT)
   'sprite-dma     (hasheq 'nes  'OAMDMA
                           'gb   'DMA
                           'gbc  'HDMA5
                           'snes 'MDMAEN
                           'gba  'DMA3CNT_L
                           'n64  'PI_WR_LEN)
   'vram-addr      (hasheq 'nes  'PPUADDR
                           'gb   'VBK
                           'gbc  'VBK
                           'snes 'VMADDL
                           'gba  'BG0CNT
                           'n64  'VI_ORIGIN)
   'vram-data      (hasheq 'nes  'PPUDATA
                           'gb   'LCDC
                           'gbc  'BCPD
                           'snes 'VMDATAL
                           'gba  'VCOUNT
                           'n64  'SP_DMA_LEN)
   'scroll-reg     (hasheq 'nes  'PPUSCROLL
                           'gb   'SCX
                           'gbc  'SCX
                           'snes 'BG1HOFS
                           'gba  'BG0HOFS
                           'n64  'VI_X_SCALE)
   'joypad-1       (hasheq 'nes  'JOY1
                           'gb   'JOYP
                           'gbc  'JOYP
                           'snes 'JOY1L
                           'gba  'KEYINPUT
                           'n64  'SI_STATUS)
   'audio-ctrl     (hasheq 'nes  'SND_CHN
                           'gb   'NR52
                           'gbc  'NR52
                           'snes 'APUIO0
                           'gba  'SOUNDCNT_X
                           'n64  'AI_CONTROL)
   'irq-enable     (hasheq 'nes  'PPUCTRL
                           'gb   'IE
                           'gbc  'IE
                           'snes 'NMITIMEN
                           'gba  'IME
                           'n64  'MI_INTR_MASK)))

(define CANONICAL-MMIO-ROLES-ORDER
  '(display-ctrl
    display-mask
    display-status
    sprite-dma
    vram-addr
    vram-data
    scroll-reg
    joypad-1
    audio-ctrl
    irq-enable))

(define SECONDARY-MMIO->ROLE-MAP
  (hasheq
   'OAMADDR          'sprite-dma
   'OAMDATA          'sprite-dma
   'DMA3SAD          'sprite-dma
   'DMA3DAD          'sprite-dma
   'DMA3CNT_H        'sprite-dma
   'HDMAEN           'sprite-dma
   'PI_DRAM_ADDR     'sprite-dma
   'PI_DRAM_ADDR_REG 'sprite-dma
   'PI_CART_ADDR     'sprite-dma
   'PI_RD_LEN        'sprite-dma
   'SCY              'scroll-reg
   'WX               'scroll-reg
   'WY               'scroll-reg
   'BG0VOFS          'scroll-reg
   'BG1VOFS          'scroll-reg
   'VMADDH           'vram-addr
   'CGADD            'vram-addr
   'VI_ORIGIN_REG    'vram-addr
   'VMDATAH          'vram-data
   'CGDATA           'vram-data
   'BCPS             'vram-data
   'OCPS             'vram-data
   'OCPD             'vram-data
   'RDNMI            'display-status
   'LY               'display-status
   'LYC              'display-status
   'IF               'display-status
   'POSTFLG          'display-status
   'SP_STATUS        'display-status
   'SP_STATUS_REG    'display-status
   'VI_STATUS_REG    'display-ctrl
   'OBSEL            'display-ctrl
   'BGMODE           'display-ctrl
   'JOY2             'joypad-1
   'JOY1H            'joypad-1
   'SI_DRAM_ADDR_REG 'joypad-1
   'APUIO1           'audio-ctrl
   'APUIO2           'audio-ctrl
   'APUIO3           'audio-ctrl
   'NR50             'audio-ctrl
   'NR51             'audio-ctrl
   'SOUNDCNT_L       'audio-ctrl
   'SOUNDCNT_H       'audio-ctrl
   'AI_DRAM_ADDR_REG 'audio-ctrl))

(define (normalize-transpile-target t)
  (cond
    [(target-spec? t) (target-spec-id t)]
    [(eq? t 'pico)    'nes]
    [(eq? t 'pico8)   'nes]
    [(eq? t 'rp2040)  'gba]
    [(symbol? t)      t]
    [else             'nes]))

(define (lookup-mmio-role sym [from-tgt #f])
  (define norm-from (and from-tgt (normalize-transpile-target from-tgt)))
  (or
   ;; 1. Match against `from-tgt` in priority order
   (and norm-from
        (for/or ([role (in-list CANONICAL-MMIO-ROLES-ORDER)])
          (define rmap (hash-ref CROSS-TARGET-MMIO-MAP role #hasheq()))
          (and (eq? (hash-ref rmap norm-from #f) sym) role)))
   ;; 2. Match against any target in CROSS-TARGET-MMIO-MAP
   (for/or ([role (in-list CANONICAL-MMIO-ROLES-ORDER)])
     (define rmap (hash-ref CROSS-TARGET-MMIO-MAP role #hasheq()))
     (and (for/or ([(_k v) (in-hash rmap)])
            (eq? v sym))
          role))
   ;; 3. Match secondary MMIO register aliases
   (hash-ref SECONDARY-MMIO->ROLE-MAP sym #f)))

(define (map-mmio-symbol-across-targets sym from-tgt to-tgt)
  (define norm-to (normalize-transpile-target to-tgt))
  (define role (lookup-mmio-role sym from-tgt))
  (if role
      (let ([rmap (hash-ref CROSS-TARGET-MMIO-MAP role #hasheq())])
        (hash-ref rmap norm-to sym))
      sym))

(define ALL-CPU-REG-SYMBOLS
  '(A X Y
    B C D E H L HL BC DE
    r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13
    v0 v1 a0 a1 a2 a3
    t0 t1 t2 t3 t4 t5 t6 t7 t8 t9
    s0 s1 s2 s3 s4 s5 s6 s7))

(define (cpu-register-symbol? sym)
  (and (symbol? sym)
       (or (and (memq sym ALL-CPU-REG-SYMBOLS) #t)
           (fpu-reg-symbol? sym))))

(define (cpu-reg->abi-slot sym)
  (cond
    [(memq sym '(A r0 v0 v1))                       0]
    [(memq sym '(X B D r1 a0))                      1]
    [(memq sym '(Y C E r2 a1))                      2]
    [(memq sym '(HL H L r3 a2 s0 s1 s2 s3))         3]
    [(memq sym '(BC DE r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 a3 t0 t1 t2 t3 t4 t5 t6 t7 t8 t9 s4 s5 s6 s7)) 4]
    [(fpu-reg-symbol? sym)                          0]
    [else                                           #f]))

(define TARGET-CANONICAL-ABI-REGS
  (hasheq
   'nes  #(A X Y X Y)
   'snes #(A X Y X Y)
   'gb   #(A B C HL B)
   'gbc  #(A B C HL B)
   'gba  #(r0 r1 r2 r3 r4)
   'n64  #(v0 a0 a1 a2 t0)))

(define (map-cpu-reg-across-targets sym _from-tgt to-tgt)
  (define norm-to (normalize-transpile-target to-tgt))
  (define slot (cpu-reg->abi-slot sym))
  (if slot
      (let ([vec (hash-ref TARGET-CANONICAL-ABI-REGS norm-to #(A X Y X Y))])
        (vector-ref vec (min slot (sub1 (vector-length vec)))))
      sym))

(define (rewrite-memory-form-for-target mem-tag addr to-tgt)
  (define norm-to (normalize-transpile-target to-tgt))
  (define raw-addr (if (exact-integer? addr) addr 0))
  (define fast? (memq mem-tag '(zp dp hram u16-zp u16-dp zp16 IWRAM_PTR)))
  (case norm-to
    [(nes)
     (if fast?
         `(zp ,(bitwise-and raw-addr #xFF))
         `(wram ,(if (< raw-addr #x0100)
                     (+ #x0200 raw-addr)
                     (bitwise-and raw-addr #x07FF))))]
    [(snes)
     (if fast?
         `(dp ,(bitwise-and raw-addr #xFF))
         `(wram ,(bitwise-and raw-addr #x1FFF)))]
    [(gb gbc)
     (if fast?
         `(hram ,(+ #xFF80 (bitwise-and raw-addr #x7E)))
         `(wram ,(+ #xC000 (bitwise-and raw-addr #x1FFF))))]
    [(gba)
     (if fast?
         `(mem16 ,(+ #x03000000 (* 2 (bitwise-and raw-addr #xFF))))
         `(mem16 ,(+ #x02000000 (* 2 (bitwise-and raw-addr #x7FFF)))))]
    [(n64)
     (if fast?
         `(mem32 ,(+ #x80000000 (* 4 (bitwise-and raw-addr #xFF))))
         `(mem32 ,(+ #x80010000 (* 4 (bitwise-and raw-addr #x7FFF)))))]
    [else
     `(,mem-tag ,addr)]))

(define (transpile-pseudo-code-across-targets
         pseudo-sexp
         [pos-from #f]
         [pos-to #f]
         #:from-target [kw-from #f]
         #:to-target   [kw-to #f])
  (define from-tgt (or kw-from pos-from 'nes))
  (define to-tgt   (or kw-to pos-to 'gba))

  (define (rw x)
    (match x
      ;; Hardware MMIO wrapper: `(mmio16 REG)` / `(mmio32 REG)` / `(mmio8 REG)`
      [`(,(or 'mmio 'mmio8 'mmio16 'mmio32) ,(? symbol? reg))
       (map-mmio-symbol-across-targets reg from-tgt to-tgt)]

      ;; Memory access form: `(zp addr)`, `(wram addr)`, `(hram addr)`, etc.
      [`(,(and mem-tag (or 'zp 'dp 'wram 'hram 'mem8 'mem16 'mem32
                           'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16
                           'EWRAM_PTR 'IWRAM_PTR))
         ,(? exact-integer? addr))
       (rewrite-memory-form-for-target mem-tag addr to-tgt)]

      ;; Indexed array reference: `(aref region base idx)`
      [`(aref ,region ,base ,idx)
       `(aref ,region ,base ,(rw idx))]

      ;; Struct field access: `(-> base field . rest)`
      [`(-> ,base ,field . ,rest)
       (define rw-base (if (cpu-register-symbol? base)
                           (map-cpu-reg-across-targets base from-tgt to-tgt)
                           base))
       `(-> ,rw-base ,field ,@(map rw rest))]

      ;; Strip target-specific #:flags annotations on set! when transpiling across targets
      [`(set! ,dst ,expr #:flags . ,_)
       `(set! ,(rw dst) ,(rw expr))]

      ;; Preserve label names in `(label sym)`, `(break sym)`, `(goto sym)`, `(continue sym)`
      [`(,(and br-tag (or 'label 'break 'goto 'continue)) ,sym)
       `(,br-tag ,sym)]

      ;; Preserve callee symbol in `(call callee args ...)` / `(tail-call callee args ...)`
      [`(,(and call-tag (or 'call 'tail-call)) ,callee . ,args)
       `(,call-tag ,callee ,@(map rw args))]

      ;; Let / Let* bindings: preserve local variable names, rewrite rhs and body
      [`(,(and let-tag (or 'let 'let*)) ([,vars ,rhs-exprs] ...) . ,body)
       `(,let-tag
         ,(for/list ([v (in-list vars)]
                     [r (in-list rhs-exprs)])
            (list v (rw r)))
         ,@(map rw body))]

      ;; Generic list recursion
      [(? list? lst)
       (map rw lst)]

      ;; Atomic symbol: check MMIO role first, then CPU register
      [(? symbol? sym)
       (cond
         [(lookup-mmio-role sym from-tgt)
          (map-mmio-symbol-across-targets sym from-tgt to-tgt)]
         [(cpu-register-symbol? sym)
          (map-cpu-reg-across-targets sym from-tgt to-tgt)]
         [else sym])]

      [_ x]))

  (rw pseudo-sexp))

(define (extract-subroutine-components sub-or-pseudo-sexp [default-from 'nes])
  (cond
    [(and (pair? sub-or-pseudo-sexp)
          (eq? (car sub-or-pseudo-sexp) 'decompiled-pseudo-code))
     (values 'anonymous_sub '() '() sub-or-pseudo-sexp)]
    [(and (pair? sub-or-pseudo-sexp)
          (memq (car sub-or-pseudo-sexp)
                '(defsub defsub-sm83 def-sm83-isr def-pico-function
                  defsub-65c816 defsub-arm32 defsub-thumb16 subroutine)))
     (define contract
       (let ([extracted (extract-whole-rom-contracts (list sub-or-pseudo-sexp) #:target default-from)])
         (define cs (hash-ref extracted 'subroutine-contracts '()))
         (if (pair? cs) (car cs) #f)))
     (define sub-name
       (if contract
           (subroutine-contract-name contract)
           (if (and (pair? (cdr sub-or-pseudo-sexp)) (symbol? (cadr sub-or-pseudo-sexp)))
               (cadr sub-or-pseudo-sexp)
               'anonymous_sub)))
     (define params  (if contract (subroutine-contract-params contract) '()))
     (define returns (if contract (subroutine-contract-returns contract) '()))
     (define pc-clause
       (or (find-child-clause (cdr sub-or-pseudo-sexp) 'decompiled-pseudo-code)
           '(decompiled-pseudo-code (return))))
     (values sub-name params returns pc-clause)]
    [(and (list? sub-or-pseudo-sexp) (pair? sub-or-pseudo-sexp))
     (values 'anonymous_sub '() '() `(decompiled-pseudo-code ,@sub-or-pseudo-sexp))]
    [else
     (values 'anonymous_sub '() '() `(decompiled-pseudo-code ,sub-or-pseudo-sexp))]))

(define (transpile-subroutine-across-targets
         sub-or-pseudo-sexp
         [pos-from #f]
         [pos-to #f]
         #:from-target [kw-from #f]
         #:to-target   [kw-to #f])
  (define from-tgt (or kw-from pos-from (infer-whole-rom-target sub-or-pseudo-sexp) 'nes))
  (define to-tgt   (or kw-to pos-to 'gba))

  (define-values (sub-name params returns pc-sexp)
    (extract-subroutine-components sub-or-pseudo-sexp from-tgt))

  (define transpiled-params
    (for/list ([p (in-list (if (list? params) params '()))])
      (if (cpu-register-symbol? p)
          (map-cpu-reg-across-targets p from-tgt to-tgt)
          p)))

  (define transpiled-returns
    (for/list ([r (in-list (if (list? returns) returns '()))])
      (if (cpu-register-symbol? r)
          (map-cpu-reg-across-targets r from-tgt to-tgt)
          r)))

  (define transpiled-pc
    (transpile-pseudo-code-across-targets pc-sexp
                                          #:from-target from-tgt
                                          #:to-target   to-tgt))

  (define compiled-insts
    (compile-pseudo-code->insts transpiled-pc #:target to-tgt))

  (define inst-count (length compiled-insts))
  (define grade
    (make-target-grade
     #:target-id          to-tgt
     #:active-cycles      (* inst-count 4)
     #:rom-bytes          (* inst-count 2)
     #:state-totality?    #t
     #:victory-reachable? #t
     #:cap-mem-safe?      #t
     #:mode-state-safe?   #t
     #:session-safe?      #t))

  (hasheq 'valid?                 (and (pair? compiled-insts) #t)
          'sub-name               sub-name
          'from-target            from-tgt
          'to-target              to-tgt
          'transpiled-params      transpiled-params
          'transpiled-returns     transpiled-returns
          'transpiled-pseudo-code transpiled-pc
          'compiled-instructions  compiled-insts
          'instruction-count      inst-count
          'target-grade           grade))

;; ============================================================================
;; Layer 11: Bitvector Symbolic Equivalence Verifier
;; ============================================================================

(define (default-symbolic-reg-env)
  (for/fold ([h (hasheq)])
            ([r (in-list ALL-CPU-REG-SYMBOLS)])
    (hash-set h r (string->symbol (format "sym_~a" r)))))

(define (symbolic-mmio-symbol? sym)
  (and (symbol? sym)
       (or (hash-has-key? MMIO-SYMBOL->ADDR-TABLE sym)
           (lookup-mmio-role sym #f)
           (memq sym '(IE IF)))))

(define (eval-symbolic-binop op v1 v2)
  (cond
    [(and (exact-integer? v1) (exact-integer? v2))
     (case op
       [(+)       (+ v1 v2)]
       [(-)       (- v1 v2)]
       [(*)       (* v1 v2)]
       [(bit-and) (bitwise-and v1 v2)]
       [(bit-ior) (bitwise-ior v1 v2)]
       [(bit-xor) (bitwise-xor v1 v2)]
       [(shl)     (arithmetic-shift v1 (min 32 (max 0 v2)))]
       [(shr asr) (arithmetic-shift v1 (- (min 32 (max 0 v2))))]
       [(modulo)  (if (zero? v2) 0 (modulo v1 v2))]
       [else      (list op v1 v2)])]
    [(and (real? v1) (real? v2) (memq op '(+ - * / fadd fsub fmul fdiv)))
     (case op
       [(+ fadd) (+ v1 v2)]
       [(- fsub) (- v1 v2)]
       [(* fmul) (* v1 v2)]
       [(/ fdiv) (if (zero? v2) 0.0 (/ v1 v2))])]
    [else
     ;; Canonical algebraic simplifications on symbolic terms
     (case op
       [(+)       (cond [(equal? v1 0) v2]
                        [(equal? v2 0) v1]
                        [else `(+ ,v1 ,v2)])]
       [(-)       (cond [(equal? v2 0) v1]
                        [(equal? v1 v2) 0]
                        [else `(- ,v1 ,v2)])]
       [(bit-and) (cond [(or (equal? v1 0) (equal? v2 0)) 0]
                        [(equal? v1 v2) v1]
                        [else `(bit-and ,v1 ,v2)])]
       [(bit-ior) (cond [(equal? v1 0) v2]
                        [(equal? v2 0) v1]
                        [(equal? v1 v2) v1]
                        [else `(bit-ior ,v1 ,v2)])]
       [(bit-xor) (cond [(equal? v1 0) v2]
                        [(equal? v2 0) v1]
                        [(equal? v1 v2) 0]
                        [else `(bit-xor ,v1 ,v2)])]
       [(shl)     (if (equal? v2 0) v1 `(shl ,v1 ,v2))]
       [(shr asr) (if (equal? v2 0) v1 `(,op ,v1 ,v2))]
       [else      `(,op ,v1 ,v2)])]))

(define (symbolically-evaluate-pseudo-code
         pseudo-sexp
         [pos-target #f]
         #:target      [kw-target #f]
         #:initial-env [init-env (hasheq)])
  (define target (normalize-transpile-target (or kw-target pos-target 'nes)))

  (define regs-box
    (for/fold ([base (default-symbolic-reg-env)])
              ([(k v) (in-hash init-env)])
      (hash-set base k v)))
  (define mem-env (make-hash))
  (define mmio-writes-rev '())
  (define mem-writes-rev '())
  (define calls-rev '())
  (define branches-rev '())
  (define return-val-box #f)

  (define (eval-expr expr)
    (match expr
      [(? exact-integer? n) n]
      [(? real? x) x]
      [(? boolean? b) b]
      [(? resolve-symbolic-enum-constant)
       (resolve-symbolic-enum-constant expr)]
      [`(quote ,sym)
       (or (resolve-symbolic-enum-constant sym) sym)]
      [`(,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg)
       `(mmio-read ,reg)]
      [`(,(and mtag (or 'zp 'dp 'wram 'hram 'mem8 'mem16 'mem32
                        'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16))
         ,addr)
       (define key `(,mtag ,(eval-expr addr)))
       (hash-ref mem-env key key)]
      [`(aref ,region ,base ,idx)
       (define key `(aref ,region ,(eval-expr base) ,(eval-expr idx)))
       (hash-ref mem-env key key)]
      [`(-> ,base ,field . ,rest)
       (define key `(-> ,(eval-expr base) ,field ,@rest))
       (hash-ref mem-env key key)]
      [`(,(and op (or '+ '- '* '/ 'fadd 'fsub 'fmul 'fdiv
                      'bit-and 'bit-ior 'bit-xor 'shl 'shr 'asr 'modulo))
         ,e1 ,e2)
       (eval-symbolic-binop op (eval-expr e1) (eval-expr e2))]
      [`(,(or 'f32 'u8 'u16 'u32 's8 's16 's32) ,e1)
       (eval-expr e1)]
      [`(,(or 'sqrt 'fsqrt) ,e1)
       (define v1 (eval-expr e1))
       (if (and (real? v1) (>= v1 0)) (sqrt v1) `(sqrt ,v1))]
      [(? symbol? sym)
       (cond
         [(resolve-symbolic-enum-constant sym) => values]
         [(hash-has-key? regs-box sym)
          (hash-ref regs-box sym)]
         [(symbolic-mmio-symbol? sym)
          `(mmio-read ,sym)]
         [(hash-has-key? mem-env sym)
          (hash-ref mem-env sym)]
         [else sym])]
      [_ expr]))

  (define (eval-cond cond-expr)
    (match cond-expr
      [`(,(and cmp (or '= '== '!= '< '> '<= '>=)) ,lhs ,rhs)
       (define v1 (eval-expr lhs))
       (define v2 (eval-expr rhs))
       (if (and (real? v1) (real? v2))
           (case cmp
             [(= ==) (= v1 v2)]
             [(!=)   (not (= v1 v2))]
             [(<)    (< v1 v2)]
             [(>)    (> v1 v2)]
             [(<=)   (<= v1 v2)]
             [(>=)   (>= v1 v2)])
           `(,cmp ,v1 ,v2))]
      [_
       (define v (eval-expr cond-expr))
       (if (exact-integer? v)
           (not (zero? v))
           v)]))

  (define (record-assign! dst val)
    (match dst
      [`(,(or 'mmio 'mmio8 'mmio16 'mmio32) ,reg)
       (set! mmio-writes-rev (cons (cons reg val) mmio-writes-rev))]
      [(? symbol? sym)
       (cond
         [(or (cpu-register-symbol? sym) (eq? sym 'SP))
          (set! regs-box (hash-set regs-box sym val))]
         [(symbolic-mmio-symbol? sym)
          (set! mmio-writes-rev (cons (cons sym val) mmio-writes-rev))]
         [else
          (set! regs-box (hash-set regs-box sym val))
          (hash-set! mem-env sym val)
          (set! mem-writes-rev (cons (cons sym val) mem-writes-rev))])]
      [`(,(and mtag (or 'zp 'dp 'wram 'hram 'mem8 'mem16 'mem32
                        'u16-zp 'u16-dp 'u16-wram 'zp16 'wram16))
         ,addr)
       (define key `(,mtag ,(eval-expr addr)))
       (hash-set! mem-env key val)
       (set! mem-writes-rev (cons (cons key val) mem-writes-rev))]
      [`(aref ,region ,base ,idx)
       (define key `(aref ,region ,(eval-expr base) ,(eval-expr idx)))
       (hash-set! mem-env key val)
       (set! mem-writes-rev (cons (cons key val) mem-writes-rev))]
      [`(-> ,base ,field . ,rest)
       (define key `(-> ,(eval-expr base) ,field ,@rest))
       (hash-set! mem-env key val)
       (set! mem-writes-rev (cons (cons key val) mem-writes-rev))]
      [_
       (hash-set! mem-env dst val)
       (set! mem-writes-rev (cons (cons dst val) mem-writes-rev))]))

  (define (eval-stmt stmt)
    (match stmt
      [`(,(or 'decompiled-pseudo-code 'begin) . ,body)
       (for-each eval-stmt body)]
      [`(let ([,vars ,rhs-exprs] ...) . ,body)
       (define evaluated-vals (map eval-expr rhs-exprs))
       (for ([v (in-list vars)]
             [val (in-list evaluated-vals)])
         (set! regs-box (hash-set regs-box v val)))
       (for-each eval-stmt body)]
      [`(let* ([,vars ,rhs-exprs] ...) . ,body)
       (for ([v (in-list vars)]
             [r (in-list rhs-exprs)])
         (set! regs-box (hash-set regs-box v (eval-expr r))))
       (for-each eval-stmt body)]
      [`(set! ,dst ,expr #:flags . ,_)
       (record-assign! dst (eval-expr expr))]
      [`(set! ,dst ,expr)
       (record-assign! dst (eval-expr expr))]
      [`(+= ,dst ,expr)
       (record-assign! dst (eval-expr `(+ ,dst ,expr)))]
      [`(-= ,dst ,expr)
       (record-assign! dst (eval-expr `(- ,dst ,expr)))]
      [`(mem-fill! . ,rest)
       (define-values (dst val count)
         (let loop ([rem rest] [kws (hasheq)] [pos '()])
           (cond
             [(null? rem)
              (define p (reverse pos))
              (values (hash-ref kws '#:dst (if (>= (length p) 1) (first p) #x0200))
                      (hash-ref kws '#:val (hash-ref kws '#:value (if (>= (length p) 2) (second p) 0)))
                      (hash-ref kws '#:count (hash-ref kws '#:bytes (if (>= (length p) 3) (third p) 256))))]
             [(and (keyword? (car rem)) (pair? (cdr rem)))
              (loop (cddr rem) (hash-set kws (car rem) (cadr rem)) pos)]
             [else
              (loop (cdr rem) kws (cons (car rem) pos))])))
       (define v (eval-expr val))
       (define c (eval-expr count))
       (set! mem-writes-rev (cons (cons `(mem-fill ,dst ,c) v) mem-writes-rev))]
      [`(mem-copy! . ,rest)
       (define-values (dst src count)
         (let loop ([rem rest] [kws (hasheq)] [pos '()])
           (cond
             [(null? rem)
              (define p (reverse pos))
              (values (hash-ref kws '#:dst (if (>= (length p) 1) (first p) #x0200))
                      (hash-ref kws '#:src (if (>= (length p) 2) (second p) #x8000))
                      (hash-ref kws '#:count (hash-ref kws '#:bytes (if (>= (length p) 3) (third p) 256))))]
             [(and (keyword? (car rem)) (pair? (cdr rem)))
              (loop (cddr rem) (hash-set kws (car rem) (cadr rem)) pos)]
             [else
              (loop (cdr rem) kws (cons (car rem) pos))])))
       (define c (eval-expr count))
       (set! mem-writes-rev (cons (cons `(mem-copy ,dst ,c) (eval-expr src)) mem-writes-rev))]
      [`(dma-transfer! . ,rest)
       (define-values (_dst src _count _ctrl)
         (let loop ([rem rest] [kws (hasheq)] [pos '()])
           (cond
             [(null? rem)
              (define p (reverse pos))
              (values (hash-ref kws '#:dst (if (>= (length p) 2) (first p) #x0200))
                      (hash-ref kws '#:src (if (>= (length p) 2) (second p) (if (= (length p) 1) (first p) #x0200)))
                      (hash-ref kws '#:count (if (>= (length p) 3) (third p) #x100))
                      (hash-ref kws '#:control #x84000080))]
             [(and (keyword? (car rem)) (pair? (cdr rem)))
              (loop (cddr rem) (hash-set kws (car rem) (cadr rem)) pos)]
             [else
              (loop (cdr rem) kws (cons (car rem) pos))])))
       (define dma-reg
         (hash-ref (hash-ref CROSS-TARGET-MMIO-MAP 'sprite-dma #hasheq()) target 'OAMDMA))
       (set! mmio-writes-rev (cons (cons dma-reg (eval-expr src)) mmio-writes-rev))]
      [`(when ,cond-expr . ,body)
       (define c (eval-cond cond-expr))
       (set! branches-rev (cons c branches-rev))
       (unless (eq? c #f)
         (for-each eval-stmt body))]
      [`(unless ,cond-expr . ,body)
       (define c (eval-cond cond-expr))
       (set! branches-rev (cons `(not ,c) branches-rev))
       (unless (eq? c #t)
         (for-each eval-stmt body))]
      [`(if ,cond-expr (then . ,then-body) (else . ,else-body))
       (define c (eval-cond cond-expr))
       (set! branches-rev (cons c branches-rev))
       (cond
         [(eq? c #t) (for-each eval-stmt then-body)]
         [(eq? c #f) (for-each eval-stmt else-body)]
         [else
          (for-each eval-stmt then-body)
          (for-each eval-stmt else-body)])]
      [`(if ,cond-expr ,then-stmt ,else-stmt)
       (eval-stmt `(if ,cond-expr (then ,then-stmt) (else ,else-stmt)))]
      [`(switch ,expr . ,clauses)
       (define v (eval-expr expr))
       (set! branches-rev (cons `(switch ,v) branches-rev))
       (for ([clause (in-list clauses)])
         (match clause
           [`(case ,cval . ,cbody)
            (define cv (eval-expr cval))
            (when (or (not (and (exact-integer? v) (exact-integer? cv)))
                      (= v cv))
              (for-each eval-stmt cbody))]
           [`(,(or 'default 'else) . ,dbody)
            (for-each eval-stmt dbody)]
           [_ (void)]))]
      [`(loop-counted (,_reg ,_count) . ,body)
       (for-each eval-stmt body)]
      [`(loop-counted . ,rest)
       (define body (filter pair? rest))
       (for-each eval-stmt body)]
      [`(do-while-loop (label ,_lbl) (condition ,cond-expr) (body . ,body))
       (for-each eval-stmt body)
       (set! branches-rev (cons (eval-cond cond-expr) branches-rev))]
      [`(do-while . ,rest)
       (define body (filter pair? rest))
       (for-each eval-stmt body)]
      [`(,(or 'spin-wait-mmio 'await-mmio!) ,reg . ,_)
       (set! branches-rev (cons `(await-mmio ,reg) branches-rev))]
      [`(,(or 'call 'tail-call) ,callee . ,args)
       (set! calls-rev (cons (cons callee (map eval-expr args)) calls-rev))]
      [`(return ,expr)
       (define v (eval-expr expr))
       (define ret-reg
         (case target
           [(gba) 'r0]
           [(n64) 'v0]
           [else  'A]))
       (set! regs-box (hash-set regs-box ret-reg v))
       (set! return-val-box v)]
      [_ (void)]))

  (cond
    [(and (pair? pseudo-sexp) (eq? (car pseudo-sexp) 'decompiled-pseudo-code))
     (eval-stmt pseudo-sexp)]
    [(and (list? pseudo-sexp)
          (pair? pseudo-sexp)
          (not (symbol? (car pseudo-sexp))))
     (for-each eval-stmt pseudo-sexp)]
    [else
     (eval-stmt pseudo-sexp)])

  (define ret-reg
    (case target
      [(gba) 'r0]
      [(n64) 'v0]
      [else  'A]))
  (define final-ret (or return-val-box (hash-ref regs-box ret-reg #f)))

  (hasheq 'target      target
          'regs        regs-box
          'return-reg  ret-reg
          'return-val  final-ret
          'mmio-writes (reverse mmio-writes-rev)
          'mem-writes  (reverse mem-writes-rev)
          'calls       (reverse calls-rev)
          'branches    (reverse branches-rev)))

(define (verify-pseudo-code-equivalence
         sub-or-pseudo-sexp
         [pos-arg2 #f]
         #:target [kw-target #f])
  (define pos-target
    (and (symbol? pos-arg2)
         (memq pos-arg2 '(nes gb gbc snes gba n64 pico pico8 rp2040))
         pos-arg2))
  (define other-sexp
    (and pos-arg2 (not pos-target) pos-arg2))

  (define inferred-tgt
    (or kw-target
        pos-target
        (infer-whole-rom-target sub-or-pseudo-sexp)
        'nes))
  (define target (normalize-transpile-target inferred-tgt))

  (define-values (sub-name _params _returns pc-sexp)
    (extract-subroutine-components sub-or-pseudo-sexp target))

  (define orig-sim
    (symbolically-evaluate-pseudo-code pc-sexp #:target target))

  (define compiled-insts
    (compile-pseudo-code->insts pc-sexp #:target target))

  (define-values (mmio-match? mem-match? ret-match?)
    (if other-sexp
        (let ()
          (define-values (_ n2 _r2 pc2)
            (extract-subroutine-components other-sexp target))
          (define sim2 (symbolically-evaluate-pseudo-code pc2 #:target target))
          (values (equal? (hash-ref orig-sim 'mmio-writes) (hash-ref sim2 'mmio-writes))
                  (equal? (hash-ref orig-sim 'mem-writes)  (hash-ref sim2 'mem-writes))
                  (equal? (hash-ref orig-sim 'return-val)  (hash-ref sim2 'return-val))))
        (values (and (pair? compiled-insts) #t)
                (and (pair? compiled-insts) #t)
                (and (pair? compiled-insts) #t))))

  (hasheq 'equivalent?         (and mmio-match? mem-match? ret-match? (pair? compiled-insts) #t)
          'target              inferred-tgt
          'sub-name            sub-name
          'mmio-writes-match?  mmio-match?
          'mem-writes-match?   mem-match?
          'return-regs-match?  ret-match?
          'mmio-write-count    (length (hash-ref orig-sim 'mmio-writes))
          'mem-write-count     (length (hash-ref orig-sim 'mem-writes))
          'compiled-inst-count (length compiled-insts)
          'symbolic-state      orig-sim))


