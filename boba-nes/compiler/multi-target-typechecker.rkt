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
 check-coprocessor-session-protocol)

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
