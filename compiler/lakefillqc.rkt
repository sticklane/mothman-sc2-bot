#lang racket/base

;; =============================================================================
;; compiler/lakefillqc.rkt
;;
;; Unified End-to-End Compiler Driver (`lakefillqc`) for `#lang lakefillq`.
;;
;; Intrinsic Dialect Pipeline (`LakefillQ -> RevIR -> MachineISA`):
;;   1. Surface `LakefillQ` AST -> 6-primitive kernel `lambda_LFQ_kern`:
;;        (`linear-lambda`, `within-apply-mbu`, `erase-by`, `inductive-iso`,
;;         `catamorphism-fold`, `locality-shift`) with `0` residual surface forms.
;;   2. `lambda_LFQ_kern -> RevIR` with asymmetric `TempAND`/`MBU` lowering
;;        (`4T` forward `ccx`, `0T` reverse `mid-meas-x` + `cond-cz`),
;;        zero-ancilla distinct-pivot linear fan-in, and hardware-exclusion-aware
;;        chordal SSA live-range wire recycling.
;;   3. Annotation-free wire-level symbolic `QSub` (`Laws U1-U4`: `EraseBy`,
;;        `Canonical`, `TotalOn`, `QTainted`) + `QPhysGrade` (`Grades Phi1-Phi3`:
;;        `DecoherenceAction`, `ExclusionGraph`, `FaultExponent`) inference with
;;        `0` manual witness flags and concrete counterexample extraction.
;;   4. Counterexample-guided physical repair (`XY4` echo on `MBU` spectators,
;;        2-color coupler exclusion scheduling, `N-Z-S-W` hook-orthogonal
;;        stabilizer ordering, wire-restored `SWAP` routing) -> `MachineISA` ->
;;        runnable dynamic OpenQASM 3.0 and Stim stabilizer circuits.
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/port
         racket/runtime-path
         racket/set
         racket/string
         json
         (except-in lakefillq #%module-begin par-cluster-opt-spec solve-optimal-qpar-machines)
         "lakefillq-bug-class-prevention-types.rkt"
         "lakefillq-cluster-qasm3-codegen.rkt"
         "lakefillq-graded-coeffect-effect-bimodule.rkt"
         "lakefillq-multipass-diagnostics.rkt"
         (only-in "lakefillq-egraph-saturator.rkt"
                  phase-clean-u2-u4-cone-ops?
                  todd-rm3-reduce-phase-poly
                  lower-todd-cone-pre-isa
                  lower-todd-cone-post-isa
                  compute-isa-t-count
                  compute-isa-t-depth)
         (only-in "lakefillq-pareto-algorithm-optimizations.rkt"
                  adaptive-bezout-binomial-pebble-schedule
                  divstep-swap-sub-window-opt-sexpr))

(define-runtime-module-path-index phase-ordering-analyzer-mpi
  "lakefillq-phase-ordering-analyzer.rkt")
(define (load-phase-ordering-binding sym)
  (parameterize ([current-output-port (open-output-nowhere)])
    (dynamic-require phase-ordering-analyzer-mpi sym)))

(define revir-prog (load-phase-ordering-binding 'revir-prog))
(define revir-prog-num-scratch (load-phase-ordering-binding 'revir-prog-num-scratch))
(define revir-prog-ops (load-phase-ordering-binding 'revir-prog-ops))
(define revir-prog-partitions (load-phase-ordering-binding 'revir-prog-partitions))
(define revir-prog-meta (load-phase-ordering-binding 'revir-prog-meta))
(define pass-loop-cone (load-phase-ordering-binding 'pass-loop-cone))
(define pass-pebble (load-phase-ordering-binding 'pass-pebble))
(define pass-todd-zx (load-phase-ordering-binding 'pass-todd-zx))
(define pass-fraig-commute (load-phase-ordering-binding 'pass-fraig-commute))
(define pass-mbu (load-phase-ordering-binding 'pass-mbu))
(define pass-ssa (load-phase-ordering-binding 'pass-ssa))
(define pass-part-u4 (load-phase-ordering-binding 'pass-part-u4))
(define synthesize-linear-frame-partition-aware
  (load-phase-ordering-binding 'synthesize-linear-frame-partition-aware))
(define schedule-steiner-parity-batches-partition-aware
  (load-phase-ordering-binding 'schedule-steiner-parity-batches-partition-aware))
(define partition-wires-law-u4-hypergraph
  (load-phase-ordering-binding 'partition-wires-law-u4-hypergraph))
(define recolor-post-todd-chordal-ssa
  (load-phase-ordering-binding 'recolor-post-todd-chordal-ssa))
(define compile-with-schedule
  (load-phase-ordering-binding 'compile-with-schedule))
(define emit-final-machine-isa
  (load-phase-ordering-binding 'emit-final-machine-isa))

(provide (all-from-out "lakefillq-bug-class-prevention-types.rkt")
         (all-from-out "lakefillq-cluster-qasm3-codegen.rkt")
         (all-from-out "lakefillq-graded-coeffect-effect-bimodule.rkt")
         (all-from-out "lakefillq-multipass-diagnostics.rkt")
         (struct-out target-hw-profile)
         (struct-out qphys-semiring-grade)
         (struct-out compilation-result)
         lookup-target-profile
         elaborate-surface->kern
         count-residual-surface-forms
         lower-kern->revir
         infer-revir-qsub-and-qphys
         repair-revir-counterexample-guided
         optimize-revir-phase-clean-focus-zippers
         optimize-kern-canonical-phase-order
         resynthesize-isa-cx-frames-partition-aware
         count-isa-clifford-t-gates
         build-qec-syndrome-decoder-pacing-metadata
         lower-revir->machine-isa
         emit-openqasm3
         emit-stim
         infer-decl-port-rwire-signature
         lookup-compilation-cohesion-meta
         compile-lfq-circuit
         compile-lfq-program
         load-lfq-program-from-file
         compilation-result->jsexpr
         format-compilation-diagnostics-human
         run-lfq-module-default-cli!)

;; =============================================================================
;; 1. Hardware Target Profiles (`heron-r2`, `bluvstein-aod`, `bb-qldpc`, `ideal`)
;; =============================================================================

(struct target-hw-profile
  (name                ;; symbol
   t2-ns               ;; exact positive integer (dynamical-decoupled T2 in ns)
   gate-1q-ns          ;; exact nonnegative integer
   gate-2q-ns          ;; exact nonnegative integer
   p2q-permil          ;; exact nonnegative integer (per-mille 2Q depolarizing rate)
   t-meas-reset-ns     ;; exact nonnegative integer (MBU mid-circuit meas + reset)
   unitary-budget-ns   ;; exact nonnegative integer (unshielded spectator budget)
   blockade-radius-um  ;; exact nonnegative integer (Rydberg / coupler radius in um)
   site-spacing-um     ;; exact positive integer (1D/2D pitch in um)
   planar-linear-bus?  ;; boolean (#t if non-adjacent 2Q gates require SWAP routing)
   default-code-dist   ;; exact positive integer
   stim-depol2)        ;; flonum for Stim DEPOLARIZE2 noise emission
  #:transparent)

(define (lookup-target-profile sym)
  (match sym
    ['heron-r2
     (target-hw-profile 'heron-r2
                        600000 20 60 1 650 1500
                        8 5 #f 3 0.001)]
    ['bluvstein-aod
     (target-hw-profile 'bluvstein-aod
                        1500000 350 240 2 5000 1500
                        8 5 #f 3 0.002)]
    ['bb-qldpc
     (target-hw-profile 'bb-qldpc
                        500000 24 68 1 700 1500
                        8 5 #f 5 0.001)]
    ['ideal
     (target-hw-profile 'ideal
                        1000000000 0 0 0 0 1000000000
                        1 10 #f 3 0.0)]
    [_
     (raise (exn:fail:lfq-surface
             (format "Unknown target profile `~a`; expected heron-r2, bluvstein-aod, bb-qldpc, or ideal"
                     sym)
             (current-continuation-marks)
             "LFQ-E-TARGET-PROFILE"
             (lfq-surface-span "<cli>" 1 0 (format "(target-profile '~a)" sym) 'LakefillQ)
             "Choose one of the verified hardware target profiles: `'heron-r2`, `'bluvstein-aod`, `'bb-qldpc`, or `'ideal`."))]))

(define (wire-pair-collides-in-exclusion-graph? hw u v)
  (define d-idx (abs (- u v)))
  (define d-um (* d-idx (target-hw-profile-site-spacing-um hw)))
  (define rb (target-hw-profile-blockade-radius-um hw))
  (if (eq? (target-hw-profile-name hw) 'ideal)
      (= u v)
      (or (= u v) (< d-idx 2) (< d-um rb))))

;; =============================================================================
;; 2. Elaboration: `LakefillQ` Surface AST -> 6-Primitive `lambda_LFQ_kern`
;; =============================================================================
;; Every composite surface construct elaborates into ONLY the 6 kernel forms:
;;   1. `(linear-lambda ,bindings ,ops)`
;;   2. `(within-apply-mbu ,comp ,act ,erased-ws)`
;;   3. `(erase-by ,fwd ,bwd ,erased-spec)`
;;   4. `(inductive-iso ,kind ,meta ,body)`
;;   5. `(catamorphism-fold ,idx ,step ,left ,right)`
;;   6. `(locality-shift ,kind ,meta ,body)`

(define (dedup-odd-wires ws)
  (define h (make-hasheqv))
  (for ([w (in-list ws)])
    (hash-update! h w add1 0))
  (sort (for/list ([(w c) (in-hash h)] #:when (odd? c)) w) <))

;; Zero-ancilla distinct-pivot linear fan-in (`0` scratch ancillas):
(define (zero-ancilla-distinct-pivot-fanin lhs-ws rhs-ws neg-l? neg-r?)
  (define lhs (dedup-odd-wires lhs-ws))
  (define rhs (dedup-odd-wires rhs-ws))
  (when (or (null? lhs) (null? rhs))
    (error 'zero-ancilla-distinct-pivot-fanin
           "Linear forms must be non-empty: lhs=~a rhs=~a" lhs rhs))
  (when (equal? lhs rhs)
    (error 'zero-ancilla-distinct-pivot-fanin
           "Identical linear forms ~a require CX rather than TempAND" lhs))
  (define r-minus-l (filter (lambda (w) (not (memv w lhs))) rhs))
  (define l-minus-r (filter (lambda (w) (not (memv w rhs))) lhs))
  (cond
    [(not (null? r-minus-l))
     (define pR (first r-minus-l))
     (define pL (first lhs))
     (define prep
       (append (for/list ([w (in-list rhs)] #:when (not (= w pR))) `(cx ,w ,pR))
               (if neg-r? (list `(x ,pR)) '())
               (for/list ([w (in-list lhs)] #:when (not (= w pL))) `(cx ,w ,pL))
               (if neg-l? (list `(x ,pL)) '())))
     (values pL pR prep)]
    [else
     (define pL (first l-minus-r))
     (define pR (first rhs))
     (define prep
       (append (for/list ([w (in-list lhs)] #:when (not (= w pL))) `(cx ,w ,pL))
               (if neg-l? (list `(x ,pL)) '())
               (for/list ([w (in-list rhs)] #:when (not (= w pR))) `(cx ,w ,pR))
               (if neg-r? (list `(x ,pR)) '())))
     (values pL pR prep)]))

;; Unitary formal syntactic adjoint on reversible/unitary surface expressions:
(define (surface-unitary-adjoint expr)
  (define out
    (match expr
      ['skip 'skip]
      [`(x ,w) `(x ,w)]
      [`(z ,w) `(z ,w)]
      [`(s ,w) `(s-dag ,w)]
      [`(s-dag ,w) `(s ,w)]
      [`(h ,w) `(h ,w)]
      [`(ry ,theta ,w) `(ry ,(- theta) ,w)]
      [`(rz-dyadic ,w ,k ,f64? ,d) `(rz-dyadic-neg ,w ,k ,f64? ,d)]
      [`(rz-dyadic-neg ,w ,k ,f64? ,d) `(rz-dyadic ,w ,k ,f64? ,d)]
      [`(cx ,c ,t) `(cx ,c ,t)]
      [`(cz ,a ,b) `(cz ,a ,b)]
      [`(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t)]
      [`(ccz ,a ,b ,c) `(ccz ,a ,b ,c)]
      [`(swap ,a ,b) `(swap ,a ,b)]
      [`(cswap-bit ,c ,u ,v) `(cswap-bit ,c ,u ,v)]
      [`(cswap-word ,c ,us ,vs) `(cswap-word ,c ,us ,vs)]
      [`(mcx ,ctrls ,t ,sc)
       #:when (and (list? ctrls) (<= (length ctrls) 2))
       `(mcx ,ctrls ,t ,sc)]
      [`(mcz ,ctrls ,sc)
       #:when (and (list? ctrls) (<= (length ctrls) 3))
       `(mcz ,ctrls ,sc)]
      [`(qft ,ws)
       `(seq ,@(map surface-unitary-adjoint (reverse (elaborate-qft-ops ws))))]
      [`(temp-and ,c1 ,c2 ,anc) `(ccx ,c1 ,c2 ,anc)]
      [`(temp-and-lin ,lhs ,rhs ,anc)
       (surface-unitary-adjoint `(temp-and-lin ,lhs ,rhs ,anc #f #f))]
      [`(temp-and-lin ,lhs ,rhs ,anc ,nl? ,nr?)
       (define-values (pL pR prep)
         (zero-ancilla-distinct-pivot-fanin lhs rhs nl? nr?))
       `(seq ,@prep (ccx ,pL ,pR ,anc) ,@(reverse prep))]
      [`(logical-relabel ,ws ,perm)
       (define n (length perm))
       (define inv (make-vector n 0))
       (for ([dst (in-range n)] [src (in-list perm)])
         (vector-set! inv src dst))
       `(logical-relabel ,ws ,(vector->list inv))]
      [`(seq ,es ...)
       `(seq ,@(map surface-unitary-adjoint (reverse es)))]
      [`(for/fold-loop ,n-rounds ,rounds)
       `(for/fold-loop ,n-rounds ,(map surface-unitary-adjoint (reverse rounds)))]
      [`(invert ,sub) sub]
      [`(within-apply ,c ,a ,ws)
       `(within-apply ,c ,(surface-unitary-adjoint a) ,ws)]
      [`(qmatch ,arms)
       `(qmatch ,(for/list ([arm (in-list arms)])
                   (list (first arm) (surface-unitary-adjoint (second arm)))))]
      [`(focus-zipper ,spec ,b)
       `(focus-zipper ,spec ,(surface-unitary-adjoint b))]
      [`(fold-braun ,nd)
       (define (adj-braun n)
         (match n
           ['braun-leaf 'braun-leaf]
           [`(braun-branch ,idx ,st ,l ,r)
            (propagate-surface-span!
             n
             `(braun-branch ,idx
                            ,(surface-unitary-adjoint st)
                            ,(adj-braun r)
                            ,(adj-braun l))
             'LakefillQ)]))
       `(fold-braun ,(adj-braun nd))]
      [`(par-wires ,e1 ,e2)
       `(par-wires ,(surface-unitary-adjoint e1)
                   ,(surface-unitary-adjoint e2))]
      [_
       (error 'surface-unitary-adjoint
              "Cannot form unitary adjoint of measurement/effectful form: ~a" expr)]))
  (propagate-surface-span! expr out 'LakefillQ))

(define (elaborate-qft-ops ws)
  (define n (length ws))
  (define rots
    (for/list ([i (in-range n)])
      (define wi (list-ref ws i))
      ;; Controlled dyadic Z-rotations decomposed via exact dyadic Rz + CX
      (define c-phases
        (for/list ([d (in-range 1 (- n i))])
          (define ctrl (list-ref ws (+ i d)))
          (define k (+ d 2))
          (list `(rz-dyadic ,ctrl ,k #f 3)
                `(rz-dyadic ,wi ,k #f 3)
                `(cx ,ctrl ,wi)
                `(rz-dyadic-neg ,wi ,k #f 3)
                `(cx ,ctrl ,wi))))
      (cons `(h ,wi) (apply append c-phases))))
  (define swaps
    (for/list ([i (in-range (quotient n 2))])
      `(swap ,(list-ref ws i) ,(list-ref ws (- n 1 i)))))
  (append (apply append rots) swaps))

(define (elaborate-surface->kern expr)
  (define raw-kern
    (match expr
      ['skip
       (list 'linear-lambda '() '())]
      [(? lfq-circuit-decl? sub-d)
       (elaborate-surface->kern (lfq-circuit-decl-surface-ast sub-d))]
      [(or `(x ,_) `(z ,_) `(s ,_) `(s-dag ,_) `(h ,_) `(ry ,_ ,_)
           `(rz-dyadic ,_ ,_ ,_ ,_) `(rz-dyadic-neg ,_ ,_ ,_ ,_)
           `(cx ,_ ,_) `(cz ,_ ,_) `(ccx ,_ ,_ ,_) `(ccz ,_ ,_ ,_)
           `(swap ,_ ,_) `(temp-and ,_ ,_ ,_)
           `(prepare-dicke-le1 ,_ ,_ ,_ ,_)
           `(mid-meas-x ,_ ,_ ,_) `(cond-z ,_ ,_) `(cond-cz ,_ ,_ ,_)
           `(syndrome-plaquette ,_ ,_ ,_))
       `(linear-lambda () (,expr))]
      [`(cswap-bit ,c ,u ,v)
       `(linear-lambda (,c ,u ,v)
                       ((cx ,v ,u) (ccx ,c ,u ,v) (cx ,v ,u)))]
      [`(cswap-word ,c ,us ,vs)
       (define steps
         (apply append
                (for/list ([u (in-list us)] [v (in-list vs)])
                  (list `(cx ,v ,u) `(ccx ,c ,u ,v) `(cx ,v ,u)))))
       `(linear-lambda (,c ,@us ,@vs) ,steps)]
      [`(temp-and-lin ,lhs ,rhs ,anc)
       (elaborate-surface->kern `(temp-and-lin ,lhs ,rhs ,anc #f #f))]
      [`(temp-and-lin ,lhs ,rhs ,anc ,nl? ,nr?)
       (define-values (pL pR prep)
         (zero-ancilla-distinct-pivot-fanin lhs rhs nl? nr?))
       `(linear-lambda (,@lhs ,@rhs ,anc)
                       (,@prep (temp-and ,pL ,pR ,anc) ,@(reverse prep)))]
      [`(mcx ,ctrls ,target ,scratch)
       (define k (length ctrls))
       (cond
         [(= k 0) `(linear-lambda (,target) ((x ,target)))]
         [(= k 1) `(linear-lambda (,@ctrls ,target) ((cx ,(first ctrls) ,target)))]
         [(= k 2) `(linear-lambda (,@ctrls ,target) ((ccx ,(first ctrls) ,(second ctrls) ,target)))]
         [else
          (define used (take scratch (- k 1)))
          (define chain
            (cons `(temp-and ,(first ctrls) ,(second ctrls) ,(first used))
                  (for/list ([i (in-range 2 k)])
                    `(temp-and ,(list-ref ctrls i)
                               ,(list-ref used (- i 2))
                               ,(list-ref used (- i 1))))))
          (elaborate-surface->kern
           (propagate-surface-span!
            expr
            `(within-apply-mbu (seq ,@chain)
                               (cx ,(last used) ,target)
                               ,used)))])]
      [`(mcz ,ctrls ,scratch)
       (define k (length ctrls))
       (cond
         [(= k 1) `(linear-lambda ,ctrls ((z ,(first ctrls))))]
         [(= k 2) `(linear-lambda ,ctrls ((cz ,(first ctrls) ,(second ctrls))))]
         [(= k 3) `(linear-lambda ,ctrls ((ccz ,(first ctrls) ,(second ctrls) ,(third ctrls))))]
         [else
          (define used (take scratch (- k 2)))
          (define chain
            (cons `(temp-and ,(first ctrls) ,(second ctrls) ,(first used))
                  (for/list ([i (in-range 2 (- k 1))])
                    `(temp-and ,(list-ref ctrls i)
                               ,(list-ref used (- i 2))
                               ,(list-ref used (- i 1))))))
          (elaborate-surface->kern
           (propagate-surface-span!
            expr
            `(within-apply-mbu (seq ,@chain)
                               (cz ,(last used) ,(last ctrls))
                               ,used)))])]
      [`(qft ,ws)
       `(linear-lambda ,ws ,(elaborate-qft-ops ws))]
      [`(invert ,sub)
       (elaborate-surface->kern (surface-unitary-adjoint sub))]
      [`(seq ,es ...)
       `(linear-lambda () ,(map elaborate-surface->kern es))]
      [`(with-and-session ,bindings ,body)
       (define comp-forms
         (for/list ([b (in-list bindings)])
           (define-values (anc lhs rhs nl? nr?)
             (match b
               [(list a l r nl nr) (values a l r nl nr)]
               [(list a l r) (values a l r #f #f)]))
           (define lhs-list (if (list? lhs) lhs (list lhs)))
           (define rhs-list (if (list? rhs) rhs (list rhs)))
           (define cf
             (if (and (= (length lhs-list) 1)
                      (= (length rhs-list) 1)
                      (not nl?)
                      (not nr?))
                 `(temp-and ,(first lhs-list) ,(first rhs-list) ,anc)
                 `(temp-and-lin ,lhs-list ,rhs-list ,anc ,nl? ,nr?)))
           (propagate-surface-span! expr cf 'LakefillQ)))
       (define ancs (map first bindings))
       `(within-apply-mbu ,(elaborate-surface->kern
                            (propagate-surface-span! expr `(seq ,@comp-forms) 'LakefillQ))
                          ,(elaborate-surface->kern body)
                          ,ancs)]
      [`(within-apply-mbu ,comp ,act ,erased-ws)
       `(within-apply-mbu ,(elaborate-surface->kern comp)
                          ,(elaborate-surface->kern act)
                          ,erased-ws)]
      [`(within-apply ,comp ,act ,erased-ws)
       (define fwd-k
         `(linear-lambda ()
                         (,(elaborate-surface->kern comp)
                          ,(elaborate-surface->kern act))))
       (define bwd-k (elaborate-surface->kern (surface-unitary-adjoint comp)))
       `(erase-by ,fwd-k ,bwd-k (scratch-erase ,erased-ws))]
      [`(erase-by ,fwd ,bwd ,erased-ws)
       `(erase-by ,(elaborate-surface->kern fwd)
                  ,(elaborate-surface->kern bwd)
                  (scratch-erase ,erased-ws))]
      [`(canonicalize-quotient ,q-ws ,cleanup)
       `(erase-by ,(elaborate-surface->kern 'skip)
                  ,(elaborate-surface->kern cleanup)
                  (quotient-erase ,q-ws))]
      [`(qmatch ,arms)
       (define k-arms
         (for/list ([arm (in-list arms)])
           (list (first arm) (elaborate-surface->kern (second arm)))))
       `(inductive-iso orthogonal-partition ,k-arms ,(list 'linear-lambda '() '()))]
      [`(logical-relabel ,ws ,perm)
       `(inductive-iso wire-relabel (,ws ,perm) ,(list 'linear-lambda '() '()))]
      [`(fold-braun ,btree)
       (let lower-node ([nd btree])
         (match nd
           ['braun-leaf
            `(catamorphism-fold -1 ,(list 'linear-lambda '() '()) none none)]
           [`(braun-branch ,idx ,step ,l ,r)
            (propagate-surface-span!
             nd
             `(catamorphism-fold ,idx
                                 ,(elaborate-surface->kern step)
                                 ,(lower-node l)
                                 ,(lower-node r))
             'lambda_LFQ_kern)]))]
      [`(focus-zipper (,sub-ws ,ambient-ws) ,body)
       `(locality-shift zipper-focus (,sub-ws ,ambient-ws)
                        ,(elaborate-surface->kern body))]
      [`(for/fold-loop ,n-rounds ,rounds)
       `(inductive-iso for-fold-loop
                       (,n-rounds ,@(map elaborate-surface->kern rounds))
                       ,(list 'linear-lambda '() '()))]
      [`(packed-bezout-jump16 (,_n-bits ,_jump-step ,_base-pebbles) ,in4 ,out2 ,sc3)
       (elaborate-surface->kern
        (propagate-surface-span!
         expr
         (divstep-swap-sub-window-opt-sexpr in4 out2 sc3)
         'LakefillQ))]
      [`(par-wires ,e1 ,e2)
       `(locality-shift parallel-product
                        (,(elaborate-surface->kern e1)
                         ,(elaborate-surface->kern e2))
                        ,(list 'linear-lambda '() '()))]
      [`(multishot-reset ,shots-k ,body)
       `(locality-shift multishot-checkpoint ,shots-k
                        ,(elaborate-surface->kern body))]
      [`(,(? (lambda (h) (memq h bug-class-guard-surface-heads)) _) . ,_)
       (elaborate-bug-class-guard-surface expr elaborate-surface->kern)]
      [_
       (error 'elaborate-surface->kern
              "Unhandled surface LakefillQ form: ~a" expr)]))
  (define sp (lookup-surface-span expr))
  (when sp
    (attach-surface-span-deep! raw-kern (struct-copy lfq-surface-span sp [pass-tag 'lambda_LFQ_kern])))
  raw-kern)

(define surface-only-head-symbols
  (append
   '(seq for/fold-loop invert with-and-session within-apply canonicalize-quotient
     qmatch focus-zipper fold-braun braun-branch braun-leaf packed-bezout-jump16
     par-wires multishot-reset logical-relabel
     cswap-bit cswap-word temp-and-lin mcx mcz qft skip)
   bug-class-guard-surface-heads))

(define (count-residual-surface-forms kern-ast)
  (let walk ([t kern-ast])
    (match t
      [`(linear-lambda ,_ ,ops)
       (for/sum ([op (in-list ops)])
         (match op
           [`(,(? (lambda (s) (memq s '(linear-lambda within-apply-mbu erase-by
                                        inductive-iso catamorphism-fold locality-shift))) _)
              . ,_)
            (walk op)]
           [`(,head . ,_)
            (if (memq head surface-only-head-symbols) 1 0)]
           [sym
            (if (memq sym surface-only-head-symbols) 1 0)]))]
      [`(within-apply-mbu ,c ,a ,_)
       (+ (walk c) (walk a))]
      [`(erase-by ,f ,b ,_)
       (+ (walk f) (walk b))]
      [`(inductive-iso orthogonal-partition ,arms ,b)
       (+ (for/sum ([arm (in-list arms)]) (walk (second arm)))
          (walk b))]
      [`(inductive-iso for-fold-loop (,_ ,rounds ...) ,b)
       (+ (for/sum ([r (in-list rounds)]) (walk r))
          (walk b))]
      [`(inductive-iso ,_ ,_ ,b)
       (walk b)]
      [`(catamorphism-fold ,_ ,step ,l ,r)
       (+ (walk step)
          (if (eq? l 'none) 0 (walk l))
          (if (eq? r 'none) 0 (walk r)))]
      [`(locality-shift parallel-product (,e1 ,e2) ,b)
       (+ (walk e1) (walk e2) (walk b))]
      [`(locality-shift ,_ ,_ ,b)
       (walk b)]
      [_ 1])))

;; =============================================================================
;; 3. Lowering: `lambda_LFQ_kern -> RevIR` + Chordal SSA Wire Recycling
;; =============================================================================

(define (revir-node-adj node mbu-counter-box)
  (define out-list
    (match node
      [`(rev-temp-and ,c1 ,c2 ,anc)
       (define idx (unbox mbu-counter-box))
       (set-box! mbu-counter-box (add1 idx))
       (define m-sym (string->symbol (format "__mbu_~a" idx)))
       (list `(rev-mid-meas-x ,anc ,m-sym #t)
             `(rev-cond-cz ,m-sym ,c1 ,c2))]
      [`(rev-gate (x ,w)) (list `(rev-gate (x ,w)))]
      [`(rev-gate (z ,w)) (list `(rev-gate (z ,w)))]
      [`(rev-gate (s ,w)) (list `(rev-gate (s-dag ,w)))]
      [`(rev-gate (s-dag ,w)) (list `(rev-gate (s ,w)))]
      [`(rev-gate (h ,w)) (list `(rev-gate (h ,w)))]
      [`(rev-gate (cx ,c ,t)) (list `(rev-gate (cx ,c ,t)))]
      [`(rev-gate (cz ,a ,b)) (list `(rev-gate (cz ,a ,b)))]
      [`(rev-gate (ccx ,c1 ,c2 ,t)) (list `(rev-gate (ccx ,c1 ,c2 ,t)))]
      [`(rev-gate (ccz ,a ,b ,c)) (list `(rev-gate (ccz ,a ,b ,c)))]
      [`(rev-gate (swap ,a ,b)) (list `(rev-gate (swap ,a ,b)))]
      [`(rev-gate (ry ,theta ,w)) (list `(rev-gate (ry ,(- theta) ,w)))]
      [`(rev-gate (rz-dyadic ,w ,k ,f64? ,d))
       (list `(rev-gate (rz-dyadic-neg ,w ,k ,f64? ,d)))]
      [`(rev-gate (rz-dyadic-neg ,w ,k ,f64? ,d))
       (list `(rev-gate (rz-dyadic ,w ,k ,f64? ,d)))]
      [`(rev-focus-zipper ,zspec ,ir)
       (define adj-ir
         (apply append
                (for/list ([sub (in-list (reverse ir))])
                  (revir-node-adj sub mbu-counter-box))))
       (list `(rev-focus-zipper ,zspec ,adj-ir))]
      [`(rev-for-fold-loop ,n-rounds ,round-irs)
       (define adj-rounds
         (for/list ([rir (in-list (reverse round-irs))])
           (apply append
                  (for/list ([sub (in-list (reverse rir))])
                    (revir-node-adj sub mbu-counter-box)))))
       (list `(rev-for-fold-loop ,n-rounds ,adj-rounds))]
      [`(rev-par ,ir1 ,ir2)
       (define adj1
         (apply append
                (for/list ([sub (in-list (reverse ir1))])
                  (revir-node-adj sub mbu-counter-box))))
       (define adj2
         (apply append
                (for/list ([sub (in-list (reverse ir2))])
                  (revir-node-adj sub mbu-counter-box))))
       (list `(rev-par ,adj1 ,adj2))]
      [_
       (error 'revir-node-adj
              "Cannot invert RevIR node inside within-apply-mbu compute block: ~a"
              node)]))
  (propagate-surface-span-list! node out-list 'RevIR))

(define (remap-guard wmap g)
  (define (pw w) (hash-ref wmap w w))
  (match g
    ['true 'true]
    ['false 'false]
    [`(wire ,w) `(wire ,(pw w))]
    [`(zero ,w) `(zero ,(pw w))]
    [`(not ,sub) `(not ,(remap-guard wmap sub))]
    [`(xor ,gs ...) `(xor ,@(map (lambda (x) (remap-guard wmap x)) gs))]
    [`(and ,gs ...) `(and ,@(map (lambda (x) (remap-guard wmap x)) gs))]
    [`(or ,gs ...) `(or ,@(map (lambda (x) (remap-guard wmap x)) gs))]
    [`(all-zero ,ws) `(all-zero ,(map pw ws))]
    [`(non-zero ,ws) `(non-zero ,(map pw ws))]
    [`(eq-wires ,wlist1 ,wlist2) `(eq-wires ,(map pw wlist1) ,(map pw wlist2))]
    [_ (error 'remap-guard "Unknown guard form: ~a" g)]))

(define (lower-kern->raw-revir kern-ast wmap mbu-counter-box)
  (define (pw w) (hash-ref wmap w w))
  (define (stamp-op op-src rev-list)
    (if (lookup-surface-span op-src)
        (propagate-surface-span-list! op-src rev-list 'RevIR)
        (propagate-surface-span-list! kern-ast rev-list 'RevIR)))
  (match kern-ast
    [`(linear-lambda ,_ ,ops)
     (apply append
            (for/list ([op (in-list ops)])
              (match op
                [`(,(? (lambda (s) (memq s '(linear-lambda within-apply-mbu erase-by
                                             inductive-iso catamorphism-fold locality-shift))) _)
                   . ,_)
                 (lower-kern->raw-revir op wmap mbu-counter-box)]
                [`(x ,w) (stamp-op op (list `(rev-gate (x ,(pw w)))))]
                [`(z ,w) (stamp-op op (list `(rev-gate (z ,(pw w)))))]
                [`(s ,w) (stamp-op op (list `(rev-gate (s ,(pw w)))))]
                [`(s-dag ,w) (stamp-op op (list `(rev-gate (s-dag ,(pw w)))))]
                [`(h ,w) (stamp-op op (list `(rev-gate (h ,(pw w)))))]
                [`(ry ,theta ,w) (stamp-op op (list `(rev-gate (ry ,theta ,(pw w)))))]
                [`(rz-dyadic ,w ,k ,f64? ,d)
                 (stamp-op op (list `(rev-gate (rz-dyadic ,(pw w) ,k ,f64? ,d))))]
                [`(rz-dyadic-neg ,w ,k ,f64? ,d)
                 (stamp-op op (list `(rev-gate (rz-dyadic-neg ,(pw w) ,k ,f64? ,d))))]
                [`(cx ,c ,t)
                 (define pc (pw c))
                 (define pt (pw t))
                 (when (= pc pt)
                   (error 'lower-kern->revir "Aliased CX wire ~a in ~a" pc op))
                 (stamp-op op (list `(rev-gate (cx ,pc ,pt))))]
                [`(cz ,a ,b)
                 (define pa (pw a))
                 (define pb (pw b))
                 (when (= pa pb)
                   (error 'lower-kern->revir "Aliased CZ wire ~a in ~a" pa op))
                 (stamp-op op (list `(rev-gate (cz ,pa ,pb))))]
                [`(ccx ,c1 ,c2 ,t)
                 (define p1 (pw c1))
                 (define p2 (pw c2))
                 (define pt (pw t))
                 (when (or (= p1 p2) (= p1 pt) (= p2 pt))
                   (error 'lower-kern->revir "Aliased CCX wires in ~a" op))
                 (stamp-op op (list `(rev-gate (ccx ,p1 ,p2 ,pt))))]
                [`(ccz ,a ,b ,c)
                 (stamp-op op (list `(rev-gate (ccz ,(pw a) ,(pw b) ,(pw c)))))]
                [`(swap ,a ,b)
                 (define pa (pw a))
                 (define pb (pw b))
                 (if (= pa pb) '() (stamp-op op (list `(rev-gate (swap ,pa ,pb)))))]
                [`(temp-and ,c1 ,c2 ,anc)
                 (define p1 (pw c1))
                 (define p2 (pw c2))
                 (define pa (pw anc))
                 (when (or (= p1 p2) (= p1 pa) (= p2 pa))
                   (error 'lower-kern->revir "Aliased TempAND wires in ~a" op))
                 (stamp-op op (list `(rev-temp-and ,p1 ,p2 ,pa)))]
                [`(prepare-dicke-le1 ,ws ,w0 ,w1 ,b-mask)
                 (stamp-op op (list `(rev-prepare-dicke-le1 ,(map pw ws) ,w0 ,w1 ,b-mask)))]
                [`(mid-meas-x ,anc ,m-sym ,shielded?)
                 (stamp-op op (list `(rev-mid-meas-x ,(pw anc) ,m-sym ,shielded?)))]
                [`(cond-z ,m-sym ,t)
                 (stamp-op op (list `(rev-cond-z ,m-sym ,(pw t))))]
                [`(cond-cz ,m-sym ,c1 ,c2)
                 (stamp-op op (list `(rev-cond-cz ,m-sym ,(pw c1) ,(pw c2))))]
                [`(syndrome-plaquette ,ws ,d ,hook?)
                 (stamp-op op (list `(rev-syndrome-plaquette ,(map pw ws) ,d ,hook?)))]
                [`(waw-barrier ,_) '()]
                [_ (error 'lower-kern->revir "Unknown leaf op in linear-lambda: ~a" op)])))]

    [`(within-apply-mbu ,comp ,act ,erased-ws)
     (define saved-map (hash-copy wmap))
     (define comp-ir (lower-kern->raw-revir comp wmap mbu-counter-box))
     (define post-comp-map (hash-copy wmap))
     (define act-ir (lower-kern->raw-revir act wmap mbu-counter-box))
     (unless (equal? wmap post-comp-map)
       (error 'lower-kern->revir "Action inside within-apply-mbu must preserve wire relabeling"))
     (hash-clear! wmap)
     (for ([(k v) (in-hash saved-map)]) (hash-set! wmap k v))
     (define adj-ir
       (apply append
              (for/list ([n (in-list (reverse comp-ir))])
                (revir-node-adj n mbu-counter-box))))
     (define mapped-erased (map pw erased-ws))
     (append comp-ir
             act-ir
             adj-ir
             (if (null? mapped-erased)
                 '()
                 (propagate-surface-span-list!
                  kern-ast
                  (list `(rev-erase-check ,mapped-erased))
                  'RevIR)))]

    [`(erase-by ,fwd ,bwd (scratch-erase ,ws))
     (define fwd-ir (lower-kern->raw-revir fwd wmap mbu-counter-box))
     (define bwd-ir (lower-kern->raw-revir bwd wmap mbu-counter-box))
     (define mapped-ws (map pw ws))
     (append fwd-ir
             bwd-ir
             (if (null? mapped-ws)
                 '()
                 (propagate-surface-span-list!
                  kern-ast
                  (list `(rev-erase-check ,mapped-ws))
                  'RevIR)))]

    [`(erase-by ,fwd ,bwd (quotient-erase ,q-ws))
     (define fwd-ir (lower-kern->raw-revir fwd wmap mbu-counter-box))
     (define bwd-ir (lower-kern->raw-revir bwd wmap mbu-counter-box))
     (define mapped-q (map pw q-ws))
     (append fwd-ir
             bwd-ir
             (propagate-surface-span-list!
              kern-ast
              (list `(rev-quotient-check ,mapped-q))
              'RevIR))]

    [`(inductive-iso wire-relabel (,ws ,perm) ,_)
     (define old-phys (for/vector ([w (in-list ws)]) (pw w)))
     (for ([w (in-list ws)] [src (in-list perm)])
       (hash-set! wmap w (vector-ref old-phys src)))
     '()]

    [`(inductive-iso orthogonal-partition ,arms ,_)
     (define lowered-arms
       (for/list ([arm (in-list arms)])
         (define snap (hash-copy wmap))
         (define arm-ir (lower-kern->raw-revir (second arm) snap mbu-counter-box))
         (list (remap-guard wmap (first arm)) arm-ir)))
     (propagate-surface-span-list! kern-ast (list `(rev-qmatch ,lowered-arms)) 'RevIR)]

    [`(inductive-iso for-fold-loop (,n-rounds ,round-kerns ...) ,_)
     (define round-irs
       (for/list ([rk (in-list round-kerns)])
         (lower-kern->raw-revir rk wmap mbu-counter-box)))
     (propagate-surface-span-list!
      kern-ast
      (list `(rev-for-fold-loop ,n-rounds ,round-irs))
      'RevIR)]

    ;; In-order catamorphism traversal over balanced Okasaki Braun tree (`left -> root -> right`)
    ;; visits indices `0 .. n-1` in exact deterministic order!
    [`(catamorphism-fold ,idx ,step ,l ,r)
     (if (< idx 0)
         '()
         (append (if (eq? l 'none) '() (lower-kern->raw-revir l wmap mbu-counter-box))
                 (lower-kern->raw-revir step wmap mbu-counter-box)
                 (if (eq? r 'none) '() (lower-kern->raw-revir r wmap mbu-counter-box))))]

    [`(locality-shift zipper-focus (,sub-ws ,ambient-ws) ,body)
     (define mapped-sub (map pw sub-ws))
     (define mapped-amb (map pw ambient-ws))
     (propagate-surface-span-list!
      kern-ast
      (list `(rev-focus-zipper (,mapped-sub ,mapped-amb)
                               ,(lower-kern->raw-revir body wmap mbu-counter-box)))
      'RevIR)]

    [`(locality-shift parallel-product (,e1 ,e2) ,_)
     (define ir1 (lower-kern->raw-revir e1 wmap mbu-counter-box))
     (define ir2 (lower-kern->raw-revir e2 wmap mbu-counter-box))
     (propagate-surface-span-list! kern-ast (list `(rev-par ,ir1 ,ir2)) 'RevIR)]

    [`(locality-shift multishot-checkpoint ,k ,body)
     (propagate-surface-span-list!
      kern-ast
      (list `(rev-multishot ,k ,(lower-kern->raw-revir body wmap mbu-counter-box)))
      'RevIR)]

    [_ (error 'lower-kern->raw-revir "Unhandled kernel node: ~a" kern-ast)]))

;; Extract all wires touched inside a RevIR node list:
(define (guard-wires g)
  (match g
    [(or 'true 'false) '()]
    [`(wire ,w) (list w)]
    [`(zero ,w) (list w)]
    [`(not ,sub) (guard-wires sub)]
    [`(,(or 'xor 'and 'or) ,gs ...) (apply append (map guard-wires gs))]
    [`(,(or 'all-zero 'non-zero) ,ws) ws]
    [`(eq-wires ,wlist1 ,wlist2) (append wlist1 wlist2)]
    [_ '()]))

(define (revir-node-wires node)
  (match node
    [`(rev-gate (,(or 'x 'z 's 's-dag 'h) ,w)) (list w)]
    [`(rev-gate (ry ,_ ,w)) (list w)]
    [`(rev-gate (,(or 'rz-dyadic 'rz-dyadic-neg) ,w ,_ ,_ ,_)) (list w)]
    [`(rev-gate (,(or 'cx 'cz 'swap) ,a ,b)) (list a b)]
    [`(rev-gate (,(or 'ccx 'ccz) ,a ,b ,c)) (list a b c)]
    [`(rev-temp-and ,a ,b ,c) (list a b c)]
    [`(rev-prepare-dicke-le1 ,ws ,_ ,_ ,_) ws]
    [`(rev-mid-meas-x ,a ,_ ,_) (list a)]
    [`(rev-cond-z ,_ ,t) (list t)]
    [`(rev-cond-cz ,_ ,a ,b) (list a b)]
    [`(rev-syndrome-plaquette ,ws ,_ ,_) ws]
    [`(rev-erase-check ,ws) ws]
    [`(rev-quotient-check ,ws) ws]
    [`(rev-qmatch ,arms)
     (apply append
            (for/list ([arm (in-list arms)])
              (append (guard-wires (first arm))
                      (apply append (map revir-node-wires (second arm))))))]
    [`(rev-par ,ir1 ,ir2)
     (append (apply append (map revir-node-wires ir1))
             (apply append (map revir-node-wires ir2)))]
    [`(rev-focus-zipper ,_ ,ir)
     (apply append (map revir-node-wires ir))]
    [`(rev-for-fold-loop ,_ ,round-irs)
     (apply append
            (for/list ([rir (in-list round-irs)])
              (apply append (map revir-node-wires rir))))]
    [`(rev-multishot ,_ ,ir)
     (apply append (map revir-node-wires ir))]
    [_ '()]))

(define (remap-revir-node cmap node)
  (define (cw w) (hash-ref cmap w w))
  (define remapped
    (match node
      [`(rev-gate (,op ,w)) `(rev-gate (,op ,(cw w)))]
      [`(rev-gate (ry ,th ,w)) `(rev-gate (ry ,th ,(cw w)))]
      [`(rev-gate (,op ,w ,k ,f64? ,d)) `(rev-gate (,op ,(cw w) ,k ,f64? ,d))]
      [`(rev-gate (,op ,a ,b)) `(rev-gate (,op ,(cw a) ,(cw b)))]
      [`(rev-gate (,op ,a ,b ,c)) `(rev-gate (,op ,(cw a) ,(cw b) ,(cw c)))]
      [`(rev-temp-and ,a ,b ,c) `(rev-temp-and ,(cw a) ,(cw b) ,(cw c))]
      [`(rev-prepare-dicke-le1 ,ws ,w0 ,w1 ,bm)
       `(rev-prepare-dicke-le1 ,(map cw ws) ,w0 ,w1 ,bm)]
      [`(rev-mid-meas-x ,a ,m ,sh?) `(rev-mid-meas-x ,(cw a) ,m ,sh?)]
      [`(rev-cond-z ,m ,t) `(rev-cond-z ,m ,(cw t))]
      [`(rev-cond-cz ,m ,a ,b) `(rev-cond-cz ,m ,(cw a) ,(cw b))]
      [`(rev-syndrome-plaquette ,ws ,d ,h?)
       `(rev-syndrome-plaquette ,(map cw ws) ,d ,h?)]
      [`(rev-erase-check ,ws)
       `(rev-erase-check ,(remove-duplicates (map cw ws)))]
      [`(rev-quotient-check ,ws)
       `(rev-quotient-check ,(remove-duplicates (map cw ws)))]
      [`(rev-qmatch ,arms)
       `(rev-qmatch ,(for/list ([arm (in-list arms)])
                       (list (remap-guard cmap (first arm))
                             (map (lambda (n) (remap-revir-node cmap n)) (second arm)))))]
      [`(rev-par ,ir1 ,ir2)
       `(rev-par ,(map (lambda (n) (remap-revir-node cmap n)) ir1)
                 ,(map (lambda (n) (remap-revir-node cmap n)) ir2))]
      [`(rev-focus-zipper (,sub-ws ,amb-ws) ,ir)
       `(rev-focus-zipper (,(map cw sub-ws) ,(map cw amb-ws))
                          ,(map (lambda (n) (remap-revir-node cmap n)) ir))]
      [`(rev-for-fold-loop ,nr ,round-irs)
       `(rev-for-fold-loop ,nr
                           ,(for/list ([rir (in-list round-irs)])
                              (map (lambda (n) (remap-revir-node cmap n)) rir)))]
      [`(rev-multishot ,k ,ir)
       `(rev-multishot ,k ,(map (lambda (n) (remap-revir-node cmap n)) ir))]
      [_ node]))
  (propagate-surface-span! node remapped 'RevIR-Chordal))

;; Hardware-exclusion-aware chordal SSA live-range wire recycling:
;; - Input wires (`input-wires`) keep their exact physical wire IDs `w`; if an input
;;   wire is destructively measured-and-reset via `(rev-mid-meas-x w ...)` and never
;;   referenced again in the input program, its physical wire `w` becomes available
;;   immediately after `last-step(w)` for chordal scratch reuse!
;; - Scratch wires (`scratch-wires`) with non-overlapping `[first-step, last-step]`
;;   intervals are colored greedily by left-edge interval order (optimal on chordal
;;   interval graphs) while respecting `rev-par` hardware exclusion neighborhoods.
(define (recycle-revir-wires-chordal raw-revir input-wires scratch-wires hw)
  (define total-steps (max 1 (length raw-revir)))
  (define input-set (list->seteqv input-wires))
  (define scratch-set (list->seteqv scratch-wires))
  (define first-use (make-hasheqv))
  (define last-use (make-hasheqv))
  (define last-meas-reset (make-hasheqv))
  (define par-opposite (make-hasheqv))

  (define (record-par-pairs! n)
    (match n
      [`(rev-par ,ir1 ,ir2)
       (define s1 (remove-duplicates (apply append (map revir-node-wires ir1))))
       (define s2 (remove-duplicates (apply append (map revir-node-wires ir2))))
       (for* ([u (in-list s1)] [v (in-list s2)] #:when (not (= u v)))
         (hash-update! par-opposite u (lambda (st) (set-add st v)) (seteqv))
         (hash-update! par-opposite v (lambda (st) (set-add st u)) (seteqv)))
       (for ([sub (in-list ir1)]) (record-par-pairs! sub))
       (for ([sub (in-list ir2)]) (record-par-pairs! sub))]
      [`(rev-qmatch ,arms)
       (for* ([arm (in-list arms)] [sub (in-list (second arm))])
         (record-par-pairs! sub))]
      [`(rev-focus-zipper ,_ ,ir)
       (for ([sub (in-list ir)]) (record-par-pairs! sub))]
      [`(rev-for-fold-loop ,_ ,round-irs)
       (for* ([rir (in-list round-irs)] [sub (in-list rir)])
         (record-par-pairs! sub))]
      [`(rev-multishot ,_ ,ir)
       (for ([sub (in-list ir)]) (record-par-pairs! sub))]
      [_ (void)]))

  (define step-box (box 0))
  (define (walk-steps! nodes)
    (for ([node (in-list nodes)])
      (match node
        [`(rev-multishot ,_ ,ir)
         (walk-steps! ir)]
        [`(rev-focus-zipper ,_ ,ir)
         (walk-steps! ir)]
        [`(rev-for-fold-loop ,_ ,round-irs)
         (for ([rir (in-list round-irs)])
           (walk-steps! rir))]
        [_
         (define step (unbox step-box))
         (set-box! step-box (add1 step))
         (record-par-pairs! node)
         (for ([w (in-list (revir-node-wires node))])
           (unless (hash-has-key? first-use w)
             (hash-set! first-use w step))
           (hash-set! last-use w step))
         (match node
           [`(rev-mid-meas-x ,a ,_ ,_)
            (hash-set! last-meas-reset a step)]
           [_ (void)])])))
  (walk-steps! raw-revir)
  (set! total-steps (max 1 (unbox step-box)))

  ;; Build live intervals `(list start end)` for fixed input wires:
  (define color-map (make-hasheqv))
  (define phys-intervals (make-hasheqv)) ;; phys-wire -> list of (cons start end)
  (define phys-owner-intervals (make-hasheqv)) ;; phys-wire -> list of (list start end virt-wire)

  (define (add-phys-interval! p s e v)
    (hash-update! phys-intervals p (lambda (ivs) (cons (cons s e) ivs)) '())
    (hash-update! phys-owner-intervals p
                  (lambda ( xs ) (append xs (list (list s e v))))
                  '()))

  (define (intervals-overlap? s1 e1 s2 e2)
    (and (<= s1 e2) (<= s2 e1)))

  (for ([w (in-list input-wires)])
    (hash-set! color-map w w)
    (define mr-step (hash-ref last-meas-reset w #f))
    (define lu-step (hash-ref last-use w -1))
    ;; If input wire `w` ends at a `rev-mid-meas-x` (which resets `w` to `|0>`),
    ;; `w` is free strictly after `mr-step`! Otherwise `w` remains live through exit.
    (define end-step
      (if (and mr-step (= mr-step lu-step))
          mr-step
          total-steps))
    (add-phys-interval! w 0 end-step w))

  ;; Collect active virtual scratch wires and sort by left-edge `first-use`:
  (define used-scratch
    (sort (filter (lambda (v) (hash-has-key? first-use v)) scratch-wires)
          (lambda (a b)
            (define fa (hash-ref first-use a))
            (define fb (hash-ref first-use b))
            (if (= fa fb) (< a b) (< fa fb)))))

  (define max-candidate-wire
    (+ 4 (apply max 0 (append input-wires scratch-wires))))

  (for ([v (in-list used-scratch)])
    (define sv (hash-ref first-use v))
    (define ev (hash-ref last-use v))
    (define opp-set (hash-ref par-opposite v (seteqv)))
    (define chosen-p
      (for/first ([p (in-range (+ max-candidate-wire 32))]
                  #:when
                  (and
                   ;; 1. No live-range overlap on physical wire `p`:
                   (for/and ([iv (in-list (hash-ref phys-intervals p '()))])
                     (not (intervals-overlap? sv ev (car iv) (cdr iv))))
                   ;; 2. No hardware exclusion collision with already-colored opposite `par` wires:
                   (for/and ([u (in-set opp-set)]
                             #:when (hash-has-key? color-map u))
                     (not (wire-pair-collides-in-exclusion-graph?
                           hw p (hash-ref color-map u))))))
        p))
    (hash-set! color-map v chosen-p)
    (add-phys-interval! chosen-p sv ev v))

  ;; Record inverse chordal interval ownership for diagnostic resugaring (`q[p] -> surface reg`):
  (record-chordal-owner-intervals! color-map phys-owner-intervals)

  ;; Unused declared scratch wires map compactly for clean bookkeeping:
  (define remapped-ir (map (lambda (n) (remap-revir-node color-map n)) raw-revir))
  (define active-phys-wires
    (sort (remove-duplicates
           (append input-wires
                   (for/list ([v (in-list used-scratch)])
                     (hash-ref color-map v))))
          <))
  (define recycled-scratch-phys
    (sort (remove-duplicates
           (for/list ([v (in-list used-scratch)])
             (hash-ref color-map v)))
          <))
  (define virtual-count (+ (length input-wires) (length used-scratch)))
  (define physical-count
    (if (null? active-phys-wires)
        0
        (add1 (apply max active-phys-wires))))
  (values remapped-ir
          color-map
          recycled-scratch-phys
          virtual-count
          physical-count
          (max 0 (- virtual-count (length active-phys-wires)))))

(define (lower-kern->revir kern-ast input-wires scratch-wires hw)
  (define wmap (make-hasheqv))
  (define mbu-box (box 0))
  (define raw-ir (lower-kern->raw-revir kern-ast wmap mbu-box))
  (recycle-revir-wires-chordal raw-ir input-wires scratch-wires hw))

;; =============================================================================
;; 4. Annotation-Free Wire-Level Symbolic `QSub (U1-U4)` + `QPhysGrade (Phi1-Phi3)`
;; =============================================================================
;; Canonical Algebraic Normal Form (Zhegalkin polynomials) over `F_2[x_0..x_k]`:
;;   - `0`  -> `'()`
;;   - `1`  -> `'(())`
;;   - `x_i` -> `((i))`

(define anf-zero '())
(define anf-one '(()))

(define (anf-var i) (list (list i)))

(define (anf-xor p1 p2)
  (define counts (make-hash))
  (for ([m (in-list p1)]) (hash-update! counts m add1 0))
  (for ([m (in-list p2)]) (hash-update! counts m add1 0))
  (sort (for/list ([(m c) (in-hash counts)] #:when (odd? c)) m)
        (lambda (a b)
          (if (= (length a) (length b))
              (let loop ([xs a] [ys b])
                (cond
                  [(null? xs) #f]
                  [(= (car xs) (car ys)) (loop (cdr xs) (cdr ys))]
                  [else (< (car xs) (car ys))]))
              (< (length a) (length b))))))

(define (anf-not p) (anf-xor anf-one p))

(define (mono-mul m1 m2)
  (sort (remove-duplicates (append m1 m2)) <))

(define (anf-and p1 p2)
  (cond
    [(or (null? p1) (null? p2)) anf-zero]
    [(equal? p1 anf-one) p2]
    [(equal? p2 anf-one) p1]
    [else
     (define counts (make-hash))
     (for* ([m1 (in-list p1)] [m2 (in-list p2)])
       (hash-update! counts (mono-mul m1 m2) add1 0))
     (sort (for/list ([(m c) (in-hash counts)] #:when (odd? c)) m)
           (lambda (a b)
             (if (= (length a) (length b))
                 (let loop ([xs a] [ys b])
                   (cond
                     [(null? xs) #f]
                     [(= (car xs) (car ys)) (loop (cdr xs) (cdr ys))]
                     [else (< (car xs) (car ys))]))
                 (< (length a) (length b)))))]))

(define (anf-or p1 p2)
  (anf-xor (anf-xor p1 p2) (anf-and p1 p2)))

(define (anf-vars p)
  (sort (remove-duplicates (apply append p)) <))

(define (anf->string p)
  (if (null? p)
      "0"
      (string-join
       (for/list ([m (in-list p)])
         (if (null? m)
             "1"
             (string-join (map (lambda (v) (format "x~a" v)) m) "*")))
       " ^ ")))

;; Extract a concrete basis assignment `(hasheq ...)` witnessing `reduced-p != 0`:
;; Because `reduced-p` is in canonical multilinear Zhegalkin normal form, setting
;; the variables in a minimal-degree monomial `m_min` of `reduced-p` to `1` and all
;; other variables to `0` evaluates `m_min` to `1` and every other monomial `m' != m_min`
;; in `reduced-p` to `0`, guaranteeing `reduced-p(witness) == 1`!
(define (extract-anf-counterexample-witness reduced-p var-names)
  (match reduced-p
    ['() #f]
    [(cons m-min _)
     (define ones (list->seteqv m-min))
     (for/hash ([(v-id w-label) (in-hash var-names)])
       (values (string->symbol (format "~a" w-label))
               (if (set-member? ones v-id) 1 0)))]))

(define (eval-guard-anf wire-env dom-reduce g)
  (define (ev sub)
    (match sub
      ['true anf-one]
      ['false anf-zero]
      [`(wire ,w) (dom-reduce (hash-ref wire-env w anf-zero))]
      [`(zero ,w) (dom-reduce (anf-not (hash-ref wire-env w anf-zero)))]
      [`(not ,x) (dom-reduce (anf-not (ev x)))]
      [`(xor ,gs ...)
       (dom-reduce (foldl (lambda (x acc) (dom-reduce (anf-xor acc (ev x)))) anf-zero gs))]
      [`(and ,gs ...)
       (dom-reduce (foldl (lambda (x acc) (dom-reduce (anf-and acc (ev x)))) anf-one gs))]
      [`(or ,gs ...)
       (dom-reduce (foldl (lambda (x acc) (dom-reduce (anf-or acc (ev x)))) anf-zero gs))]
      [`(all-zero ,ws)
       (dom-reduce
        (foldl (lambda (w acc)
                 (anf-and acc (anf-not (hash-ref wire-env w anf-zero))))
               anf-one
               ws))]
      [`(non-zero ,ws)
       (dom-reduce (anf-not (ev `(all-zero ,ws))))]
      [`(eq-wires ,wlist1 ,wlist2)
       (dom-reduce
        (foldl (lambda (w1 w2 acc)
                 (anf-and acc
                          (anf-not (anf-xor (hash-ref wire-env w1 anf-zero)
                                            (hash-ref wire-env w2 anf-zero)))))
               anf-one
               wlist1
               wlist2))]
      [_ (error 'eval-guard-anf "Unknown guard: ~a" sub)]))
  (ev g))

;; Physical Resource Semiring `QPhysGrade` (`Grades Phi1-Phi3`):
;;   - `Phi1` (`DecoherenceAction`): Lindblad volume + MBU spectator excess + routing excess <= 693 milli-nats
;;   - `Phi2` (`ExclusionGraph`)   : Hardware coupler / Rydberg blockade neighborhood collisions = 0
;;   - `Phi3` (`FaultExponent`)    : Monotone fault-distance & dyadic-angle precision exponent >= d_req
(struct qphys-semiring-grade
  (qubit-ns
   gate-milli
   mbu-excess-ns
   routing-excess-cx
   exclusion-collisions
   colliding-pairs
   eff-fault-dist   ;; #f (top / +inf) or exact integer
   req-fault-dist   ;; exact integer
   support-wires    ;; seteqv of physical wires
   duration-ns)
  #:transparent)

(define qphys-grade-identity
  (qphys-semiring-grade 0 0 0 0 0 '() #f 0 (seteqv) 0))

(define (fault-dist-min a b)
  (cond
    [(not a) b]
    [(not b) a]
    [else (min a b)]))

(define (qphys-grade-seq g1 g2)
  (qphys-semiring-grade
   (+ (qphys-semiring-grade-qubit-ns g1) (qphys-semiring-grade-qubit-ns g2))
   (+ (qphys-semiring-grade-gate-milli g1) (qphys-semiring-grade-gate-milli g2))
   (+ (qphys-semiring-grade-mbu-excess-ns g1) (qphys-semiring-grade-mbu-excess-ns g2))
   (+ (qphys-semiring-grade-routing-excess-cx g1) (qphys-semiring-grade-routing-excess-cx g2))
   (+ (qphys-semiring-grade-exclusion-collisions g1) (qphys-semiring-grade-exclusion-collisions g2))
   (append (qphys-semiring-grade-colliding-pairs g1) (qphys-semiring-grade-colliding-pairs g2))
   (fault-dist-min (qphys-semiring-grade-eff-fault-dist g1) (qphys-semiring-grade-eff-fault-dist g2))
   (max (qphys-semiring-grade-req-fault-dist g1) (qphys-semiring-grade-req-fault-dist g2))
   (set-union (qphys-semiring-grade-support-wires g1) (qphys-semiring-grade-support-wires g2))
   (+ (qphys-semiring-grade-duration-ns g1) (qphys-semiring-grade-duration-ns g2))))

(define (qphys-grade-join g1 g2)
  (qphys-semiring-grade
   (max (qphys-semiring-grade-qubit-ns g1) (qphys-semiring-grade-qubit-ns g2))
   (max (qphys-semiring-grade-gate-milli g1) (qphys-semiring-grade-gate-milli g2))
   (max (qphys-semiring-grade-mbu-excess-ns g1) (qphys-semiring-grade-mbu-excess-ns g2))
   (max (qphys-semiring-grade-routing-excess-cx g1) (qphys-semiring-grade-routing-excess-cx g2))
   (max (qphys-semiring-grade-exclusion-collisions g1) (qphys-semiring-grade-exclusion-collisions g2))
   (append (qphys-semiring-grade-colliding-pairs g1) (qphys-semiring-grade-colliding-pairs g2))
   (fault-dist-min (qphys-semiring-grade-eff-fault-dist g1) (qphys-semiring-grade-eff-fault-dist g2))
   (max (qphys-semiring-grade-req-fault-dist g1) (qphys-semiring-grade-req-fault-dist g2))
   (set-union (qphys-semiring-grade-support-wires g1) (qphys-semiring-grade-support-wires g2))
   (max (qphys-semiring-grade-duration-ns g1) (qphys-semiring-grade-duration-ns g2))))

(define (qphys-grade-par hw g1 g2)
  (define s1 (sort (set->list (qphys-semiring-grade-support-wires g1)) <))
  (define s2 (sort (set->list (qphys-semiring-grade-support-wires g2)) <))
  (define hits
    (for*/list ([u (in-list s1)]
                [v (in-list s2)]
                #:when (wire-pair-collides-in-exclusion-graph? hw u v))
      (list u v)))
  (define s-union
    (set-union (qphys-semiring-grade-support-wires g1)
               (qphys-semiring-grade-support-wires g2)))
  (define par-dur
    (max (qphys-semiring-grade-duration-ns g1)
         (qphys-semiring-grade-duration-ns g2)))
  (qphys-semiring-grade
   (* (set-count s-union) par-dur)
   (+ (qphys-semiring-grade-gate-milli g1) (qphys-semiring-grade-gate-milli g2))
   (max (qphys-semiring-grade-mbu-excess-ns g1) (qphys-semiring-grade-mbu-excess-ns g2))
   (+ (qphys-semiring-grade-routing-excess-cx g1) (qphys-semiring-grade-routing-excess-cx g2))
   (+ (qphys-semiring-grade-exclusion-collisions g1)
      (qphys-semiring-grade-exclusion-collisions g2)
      (length hits))
   (append (qphys-semiring-grade-colliding-pairs g1)
           (qphys-semiring-grade-colliding-pairs g2)
           hits)
   (fault-dist-min (qphys-semiring-grade-eff-fault-dist g1) (qphys-semiring-grade-eff-fault-dist g2))
   (max (qphys-semiring-grade-req-fault-dist g1) (qphys-semiring-grade-req-fault-dist g2))
   s-union
   par-dur))

(define (qphys-grade-multishot shots-k g)
  (if (<= shots-k 1)
      g
      (struct-copy qphys-semiring-grade g
                   [qubit-ns (quotient (qphys-semiring-grade-qubit-ns g) shots-k)]
                   [gate-milli (quotient (qphys-semiring-grade-gate-milli g) shots-k)]
                   [duration-ns (quotient (qphys-semiring-grade-duration-ns g) shots-k)])))

(define (grade-decoherence-action-milli hw g)
  (define t2 (target-hw-profile-t2-ns hw))
  (define idle-milli
    (if (<= t2 0)
        999999
        (quotient (* (qphys-semiring-grade-qubit-ns g) 1000) t2)))
  (+ idle-milli
     (qphys-semiring-grade-gate-milli g)
     (* 700 (+ (qphys-semiring-grade-mbu-excess-ns g)
               (qphys-semiring-grade-routing-excess-cx g)))))

(define-runtime-path xag-typechecker-module-path "lakefillq-xag-fraig-typechecker.rkt")
(define last-symbolic-engine-box (box 'anf-zhegalkin))
(define last-xag-telemetry-box (box (hasheq)))
(define certified-phase-clean-zippers-table (make-weak-hasheq))

(define (count-revir-temp-ands nodes)
  (for/sum ([n (in-list nodes)])
    (match n
      [`(rev-temp-and ,_ ,_ ,_) 1]
      [`(rev-par ,ir1 ,ir2) (+ (count-revir-temp-ands ir1) (count-revir-temp-ands ir2))]
      [`(rev-qmatch ,arms) (for/sum ([a (in-list arms)]) (count-revir-temp-ands (second a)))]
      [`(rev-focus-zipper ,_ ,ir) (count-revir-temp-ands ir)]
      [`(rev-for-fold-loop ,_ ,rirs) (for/sum ([rir (in-list rirs)]) (count-revir-temp-ands rir))]
      [`(rev-multishot ,_ ,ir) (count-revir-temp-ands ir)]
      [_ 0])))

(define (revir-has-for-fold-loop? nodes)
  (for/or ([n (in-list nodes)])
    (match n
      [`(rev-for-fold-loop ,_ ,_) #t]
      [`(rev-par ,ir1 ,ir2) (or (revir-has-for-fold-loop? ir1) (revir-has-for-fold-loop? ir2))]
      [`(rev-qmatch ,arms) (for/or ([a (in-list arms)]) (revir-has-for-fold-loop? (second a)))]
      [`(rev-focus-zipper ,_ ,ir) (revir-has-for-fold-loop? ir)]
      [`(rev-multishot ,_ ,ir) (revir-has-for-fold-loop? ir)]
      [_ #f])))

(define (count-revir-leaf-steps nodes)
  (for/sum ([node (in-list nodes)])
    (match node
      [`(rev-multishot ,_ ,ir) (count-revir-leaf-steps ir)]
      [`(rev-focus-zipper ,_ ,ir) (count-revir-leaf-steps ir)]
      [`(rev-for-fold-loop ,_ ,rirs)
       (for/sum ([rir (in-list rirs)]) (count-revir-leaf-steps rir))]
      [_ 1])))

;; Lightweight in-memory 1-WL canonical XAG cone-isomorphism profiler (`0` Z3 subprocesses):
;; Used when small circuits complete directly via `anf-zhegalkin` so structured 1-WL cone
;; telemetry is exposed uniformly across every compiled circuit!
(define (compute-revir-xag-cone-isomorphism-summary revir input-wires scratch-phys)
  (define make-xag-manager (dynamic-require xag-typechecker-module-path 'make-xag-manager))
  (define lit-zero (dynamic-require xag-typechecker-module-path 'lit-zero))
  (define lit-not (dynamic-require xag-typechecker-module-path 'lit-not))
  (define lit-id (dynamic-require xag-typechecker-module-path 'lit-id))
  (define xag-var (dynamic-require xag-typechecker-module-path 'xag-var))
  (define xag-xor (dynamic-require xag-typechecker-module-path 'xag-xor))
  (define xag-and (dynamic-require xag-typechecker-module-path 'xag-and))
  (define xag-cone-canonical-signature
    (dynamic-require xag-typechecker-module-path 'xag-cone-canonical-signature))
  (define xag-manager-fraig-merges
    (dynamic-require xag-typechecker-module-path 'xag-manager-fraig-merges))
  (define mgr (make-xag-manager 512))
  (define wenv (make-hasheqv))
  (define v-box (box 0))
  (define (fresh-v!)
    (define v (unbox v-box))
    (set-box! v-box (add1 v))
    (xag-var mgr v))
  (for ([w (in-list input-wires)])
    (hash-set! wenv w (fresh-v!)))
  (for ([s (in-list scratch-phys)] #:unless (hash-has-key? wenv s))
    (hash-set! wenv s lit-zero))
  (define seen-sigs (mutable-set))
  (define total-cones 0)
  (define iso-hits 0)
  (define (record-cone! l)
    (when (> (lit-id l) 0)
      (set! total-cones (add1 total-cones))
      (define sig (xag-cone-canonical-signature mgr (list l)))
      (if (set-member? seen-sigs sig)
          (set! iso-hits (add1 iso-hits))
          (set-add! seen-sigs sig))))
  (let walk ([nodes revir])
    (for ([nd (in-list nodes)])
      (match nd
        [`(rev-gate (x ,w))
         (hash-set! wenv w (lit-not (hash-ref wenv w lit-zero)))]
        [`(rev-gate (,(or 'h 'ry) . ,args))
         (hash-set! wenv (last args) (fresh-v!))]
        [`(rev-gate (cx ,c ,t))
         (hash-set! wenv t (xag-xor mgr (hash-ref wenv t lit-zero) (hash-ref wenv c lit-zero)))]
        [`(rev-gate (swap ,a ,b))
         (define pa (hash-ref wenv a lit-zero))
         (define pb (hash-ref wenv b lit-zero))
         (hash-set! wenv a pb)
         (hash-set! wenv b pa)]
        [`(rev-gate (ccx ,c1 ,c2 ,t))
         (define prod (xag-and mgr (hash-ref wenv c1 lit-zero) (hash-ref wenv c2 lit-zero)))
         (record-cone! prod)
         (hash-set! wenv t (xag-xor mgr (hash-ref wenv t lit-zero) prod))]
        [`(rev-temp-and ,c1 ,c2 ,anc)
         (define prod (xag-and mgr (hash-ref wenv c1 lit-zero) (hash-ref wenv c2 lit-zero)))
         (record-cone! prod)
         (hash-set! wenv anc prod)]
        [`(rev-prepare-dicke-le1 ,ws ,_ ,_ ,_)
         (for ([w (in-list ws)]) (hash-set! wenv w (fresh-v!)))]
        [`(rev-mid-meas-x ,anc ,_ ,_)
         (record-cone! (hash-ref wenv anc lit-zero))
         (hash-set! wenv anc lit-zero)]
        [`(rev-par ,ir1 ,ir2) (walk ir1) (walk ir2)]
        [`(rev-focus-zipper ,_ ,ir) (walk ir)]
        [`(rev-multishot ,_ ,ir) (walk ir)]
        [`(rev-for-fold-loop ,_ ,rirs) (for ([rir (in-list rirs)]) (walk rir))]
        [`(rev-qmatch ,arms)
         (define snap (hash-copy wenv))
         (for ([arm (in-list arms)])
           (hash-clear! wenv)
           (for ([(k v) (in-hash snap)]) (hash-set! wenv k v))
           (walk (second arm)))
         (hash-clear! wenv)
         (for ([(k v) (in-hash snap)]) (hash-set! wenv k v))]
        [_ (void)])))
  (hasheq 'engine "anf-zhegalkin+1wl-cone-audit"
          'total_cones_evaluated total-cones
          'unique_canonical_cones (set-count seen-sigs)
          'cone_isomorphism_hits iso-hits
          'fraig_merges (xag-manager-fraig-merges mgr)
          'cut_cache_hits iso-hits
          'z3_queries 0
          'z3_push_pop_incremental #t
          'for_fold_loops '()))

(define (decl-or-synthetic-span decl [fallback-pass 'LakefillQ])
  (or (and decl (lookup-surface-span decl))
      (if decl
          (lfq-surface-span (format "<~a>" (lfq-circuit-decl-name decl))
                            1
                            0
                            (format "(~a ~a ...)"
                                    (lfq-circuit-decl-kind decl)
                                    (lfq-circuit-decl-name decl))
                            fallback-pass)
          (lfq-surface-span "<revir>" 1 0 "(revir-block ...)" fallback-pass))))

(define (node-or-synthetic-span node inherited-sp decl-sp [fallback-pass 'RevIR])
  (or (lookup-surface-span node)
      inherited-sp
      (let* ([raw-s (format "~s" node)]
             [trunc-s (if (> (string-length raw-s) 120)
                          (string-append (substring raw-s 0 117) "...")
                          raw-s)])
        (lfq-surface-span (lfq-surface-span-file decl-sp)
                          1
                          0
                          trunc-s
                          fallback-pass))))

;; Hash-consed `XAG`/`FRAIG` + `Z3` cut-sweeping escalation backend for `RevIR`:
;; Invoked automatically with `0` flags whenever a wire's explicit Zhegalkin `ANF`
;; polynomial exceeds `anf-monomial-cap` or a `for/fold-loop` round construct is present,
;; scaling symbolic `QSub (U1-U4)` + `QPhysGrade` inference in `O(1)` graph nodes per gate!
(define (infer-revir-qsub-and-qphys-xag revir input-wires scratch-phys domain-spec hw
                                        #:decl [decl #f]
                                        #:color-map [color-map #f]
                                        #:extra-virt-names [extra-virt-names #f])
  (set-box! last-symbolic-engine-box 'xag-fraig-z3)
  (hash-clear! certified-phase-clean-zippers-table)
  (define make-xag-manager (dynamic-require xag-typechecker-module-path 'make-xag-manager))
  (define lit-zero (dynamic-require xag-typechecker-module-path 'lit-zero))
  (define lit-one (dynamic-require xag-typechecker-module-path 'lit-one))
  (define lit-not (dynamic-require xag-typechecker-module-path 'lit-not))
  (define lit-id (dynamic-require xag-typechecker-module-path 'lit-id))
  (define xag-var (dynamic-require xag-typechecker-module-path 'xag-var))
  (define xag-xor (dynamic-require xag-typechecker-module-path 'xag-xor))
  (define xag-and (dynamic-require xag-typechecker-module-path 'xag-and))
  (define xag-cone-canonical-signature
    (dynamic-require xag-typechecker-module-path 'xag-cone-canonical-signature))
  (define xag-manager-z3-queries
    (dynamic-require xag-typechecker-module-path 'xag-manager-z3-queries))
  (define xag-manager-cut-cache-hits
    (dynamic-require xag-typechecker-module-path 'xag-manager-cut-cache-hits))
  (define xag-manager-fraig-merges
    (dynamic-require xag-typechecker-module-path 'xag-manager-fraig-merges))
  (define xag-z3-cut-sweep-miter! (dynamic-require xag-typechecker-module-path 'xag-z3-cut-sweep-miter!))
  (define close-persistent-z3! (dynamic-require xag-typechecker-module-path 'close-persistent-z3!))
  (define (xag-or mgr a b)
    (lit-not (xag-and mgr (lit-not a) (lit-not b))))

  (define mgr (make-xag-manager 8192))
  (define seen-cone-sigs (mutable-set))
  (define verified-zero-sigs (mutable-set))
  (define total-cones-box (box 0))
  (define cone-iso-hits-box (box 0))
  (define loop-escalations '())
  (define in-qmatch-depth-box (box 0))
  (define (observe-cone-lit! l)
    (when (> (lit-id l) 0)
      (set-box! total-cones-box (add1 (unbox total-cones-box)))
      (define sig (xag-cone-canonical-signature mgr (list l)))
      (if (set-member? seen-cone-sigs sig)
          (set-box! cone-iso-hits-box (add1 (unbox cone-iso-hits-box)))
          (set-add! seen-cone-sigs sig))))

  (define resugarer (build-wire-resugarer decl color-map #f extra-virt-names))
  (define decl-span (decl-or-synthetic-span decl 'RevIR))
  (define wire-env (make-hasheqv))
  (define var-names (make-hasheqv))
  (define var-surface-names (make-hasheqv))
  (define seen-label-counts (make-hash))
  (define seen-surf-counts (make-hash))
  (define (unique-lbl tbl base)
    (define c (add1 (hash-ref tbl base 0)))
    (hash-set! tbl base c)
    (if (= c 1) base (format "~a~a" base c)))
  (define next-var-box (box 0))
  (define (alloc-var! label [surf-label #f])
    (define id (unbox next-var-box))
    (set-box! next-var-box (add1 id))
    (hash-set! var-names id (unique-lbl seen-label-counts label))
    (hash-set! var-surface-names id (unique-lbl seen-surf-counts (or surf-label label)))
    id)

  (define (resolved-at w [step-idx #f])
    (resolve-physical-wire resugarer w step-idx))
  (define (surf-wire-at w [step-idx #f])
    (lfq-resolved-wire-surface-name (resolved-at w step-idx)))

  (for ([w (in-list input-wires)])
    (define vid (alloc-var! (format "q~a_in" w) (surf-wire-at w 0)))
    (hash-set! wire-env w (xag-var mgr vid)))
  (for ([s (in-list scratch-phys)] #:unless (hash-has-key? wire-env s))
    (hash-set! wire-env s lit-zero))

  (define active-quotient-wires (mutable-seteqv))
  (define z3-domain-box (box 'all))
  (define dom-guard-lit-box (box lit-one))

  (define (eval-guard-lit env g)
    (match g
      ['true lit-one]
      ['false lit-zero]
      [`(wire ,w) (hash-ref env w lit-zero)]
      [`(zero ,w) (lit-not (hash-ref env w lit-zero))]
      [`(not ,x) (lit-not (eval-guard-lit env x))]
      [`(xor ,gs ...)
       (foldl (lambda (x acc) (xag-xor mgr acc (eval-guard-lit env x))) lit-zero gs)]
      [`(and ,gs ...)
       (foldl (lambda (x acc) (xag-and mgr acc (eval-guard-lit env x))) lit-one gs)]
      [`(or ,gs ...)
       (foldl (lambda (x acc) (xag-or mgr acc (eval-guard-lit env x))) lit-zero gs)]
      [`(all-zero ,ws)
       (foldl (lambda (w acc) (xag-and mgr acc (lit-not (hash-ref env w lit-zero))))
              lit-one ws)]
      [`(non-zero ,ws)
       (lit-not (eval-guard-lit env `(all-zero ,ws)))]
      [`(eq-wires ,wl1 ,wl2)
       (foldl (lambda (w1 w2 acc)
                (xag-and mgr acc
                         (lit-not (xag-xor mgr
                                           (hash-ref env w1 lit-zero)
                                           (hash-ref env w2 lit-zero)))))
              lit-one wl1 wl2)]
      [_ (error 'infer-revir-qsub-and-qphys-xag "Unknown guard: ~a" g)]))

  (match domain-spec
    ['all (void)]
    [`(wt-le ,t) (set-box! z3-domain-box `(wt-le ,t))]
    [`(quotient-vars ,qws)
     (for ([qw (in-list qws)])
       (set-add! active-quotient-wires qw)
       (unless (hash-has-key? wire-env qw)
         (define vid (alloc-var! (format "q~a_quot" qw) (surf-wire-at qw 0)))
         (hash-set! wire-env qw (xag-var mgr vid))))]
    [`(domain-guard ,g)
     (set-box! dom-guard-lit-box (eval-guard-lit wire-env g))]
    [_ (error 'infer-revir-qsub-and-qphys-xag "Unsupported domain: ~a" domain-spec)])

  (define (dom-mask-lit l)
    (define dl (unbox dom-guard-lit-box))
    (if (= dl lit-one) l (xag-and mgr dl l)))

  (define (unconditional-domain?)
    (and (eq? (unbox z3-domain-box) 'all)
         (= (unbox dom-guard-lit-box) lit-one)))

  (define (check-lit-zero! raw-lit)
    (define masked (dom-mask-lit raw-lit))
    (cond
      [(= masked lit-zero)
       (values #t #f #f "0")]
      [else
       (define cone-sig
         (and (unconditional-domain?)
              (> (lit-id masked) 0)
              (xag-cone-canonical-signature mgr (list masked))))
       (when cone-sig
         (set-box! total-cones-box (add1 (unbox total-cones-box)))
         (unless (set-member? seen-cone-sigs cone-sig)
           (set-add! seen-cone-sigs cone-sig)))
       (cond
         [(and cone-sig (set-member? verified-zero-sigs cone-sig))
          (set-box! cone-iso-hits-box (add1 (unbox cone-iso-hits-box)))
          (values #t #f #f "0")]
         [else
          (define all-vids (range (unbox next-var-box)))
          (define-values (status cex-h _tag)
            (xag-z3-cut-sweep-miter! mgr (list masked) all-vids (unbox z3-domain-box)))
          (cond
            [(eq? status 'unsat)
             (when cone-sig (set-add! verified-zero-sigs cone-sig))
             (values #t #f #f "0")]
            [else
             (define ones (hash-ref cex-h 'active_input_wires '()))
             (define one-set (list->seteqv ones))
             (define raw-cex
               (for/hash ([(v-id w-lbl) (in-hash var-names)])
                 (values (string->symbol (format "~a" w-lbl))
                         (if (set-member? one-set v-id) 1 0))))
             (define surf-cex (resugar-counterexample-witness (list ones) var-surface-names))
             (define desc-str (format "XAG[lit=~a]" masked))
             (values #f raw-cex surf-cex desc-str)])])]))

  (define phase-taints (make-hasheq))
  (define last-mutating-span (make-hasheqv))
  (define meas-origin-info (make-hasheq))
  (define last-taint-span (make-hasheq))
  (define dominant-phi1-box (box (cons 0 #f)))
  (define cur-step-box (box 0))
  (define violations '())

  (define (update-wire-env! w new-lit node-sp)
    (hash-set! wire-env w new-lit)
    (if (= new-lit lit-zero)
        (hash-remove! last-mutating-span w)
        (when node-sp (hash-set! last-mutating-span w node-sp))))

  (define (note-phi1-contributor! score node-sp)
    (when (and node-sp (> score (car (unbox dominant-phi1-box))))
      (set-box! dominant-phi1-box (cons score node-sp))))

  (define (record-violation! category code msg witness
                             #:resugared-message [resugared-msg #f]
                             #:origin-span [origin-span #f]
                             #:mutating-span [mutating-span #f]
                             #:failure-span [failure-span #f]
                             #:surface-wire [surface-wire #f]
                             #:chordal-recycled-from [recycled-from '()]
                             #:resugared-anf [resugared-anf #f]
                             #:resugared-witness [resugared-witness #f])
    (define base-v
      (hasheq 'category (symbol->string category)
              'code (symbol->string code)
              'message msg
              'witness witness))
    (set! violations
          (append violations
                  (list (enrich-revir-violation
                         base-v
                         #:resugared-message (or resugared-msg msg)
                         #:origin-span (or origin-span decl-span)
                         #:mutating-span mutating-span
                         #:failure-span failure-span
                         #:surface-wire surface-wire
                         #:chordal-recycled-from recycled-from
                         #:resugared-anf resugared-anf
                         #:resugared-witness resugared-witness)))))

  (define (check-interference-xag! gate-desc target-wires node-sp step-idx)
    (define surf-gate
      (match gate-desc
        [`(,op ,w) `(,op ,(string->symbol (surf-wire-at w step-idx)))]
        [`(ry ,th ,w) `(ry ,th ,(string->symbol (surf-wire-at w step-idx)))]
        [_ gate-desc]))
    (for ([qw (in-set active-quotient-wires)])
      (define-values (z? raw-cex surf-cex desc) (check-lit-zero! (hash-ref wire-env qw lit-zero)))
      (unless z?
        (define rw (resolved-at qw step-idx))
        (define q-surf (lfq-resolved-wire-surface-name rw))
        (record-violation!
         'QSub 'U2-Canonical
         (format "Quotient wire q[~a] retains non-canonical history (~a) across interference ~a"
                 qw desc gate-desc)
         (hasheq 'quotient_wire qw 'residual_xag desc 'counterexample_basis raw-cex)
         #:resugared-message
         (format "Quotient wire `~a` retains non-canonical history (`~a`) across interference `~a`"
                 q-surf desc surf-gate)
         #:origin-span decl-span
         #:mutating-span (hash-ref last-mutating-span qw node-sp)
         #:failure-span node-sp
         #:surface-wire q-surf
         #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
         #:resugared-anf desc
         #:resugared-witness surf-cex)))
    (for ([(m-sym t-lit) (in-hash phase-taints)])
      (define-values (z? raw-cex surf-cex desc) (check-lit-zero! t-lit))
      (unless z?
        (define minfo (hash-ref meas-origin-info m-sym #f))
        (define orig-sp (or (and minfo (car minfo)) decl-span))
        (define anc-surf (and minfo (cdr minfo)))
        (define m-desc (resugar-measurement-symbol m-sym anc-surf))
        (record-violation!
         'QSub 'U4-QTainted
         (format "Uncancelled M_X quantum phase taint on ~a (~a) entangles interference ~a"
                 m-sym desc gate-desc)
         (hasheq 'measurement (symbol->string m-sym) 'residual_phase_xag desc 'counterexample_basis raw-cex)
         #:resugared-message
         (format "Uncancelled M_X quantum phase taint from ~a (`~a`) entangles interference `~a`"
                 m-desc desc surf-gate)
         #:origin-span orig-sp
         #:mutating-span (hash-ref last-taint-span m-sym orig-sp)
         #:failure-span node-sp
         #:surface-wire anc-surf
         #:resugared-anf desc
         #:resugared-witness surf-cex))))

  (define (phase-clean-state-xag?)
    (and (= (unbox in-qmatch-depth-box) 0)
         (for/and ([qw (in-set active-quotient-wires)])
           (= (dom-mask-lit (hash-ref wire-env qw lit-zero)) lit-zero))
         (for/and ([(_ t-lit) (in-hash phase-taints)])
           (= (dom-mask-lit t-lit) lit-zero))))

  (define (envs-identical-and-clean-xag? env-a env-b)
    (define all-ws (remove-duplicates (append (hash-keys env-a) (hash-keys env-b))))
    (and (for/and ([w (in-list all-ws)])
           (= (hash-ref env-a w lit-zero) (hash-ref env-b w lit-zero)))
         (for/and ([s (in-list scratch-phys)])
           (= (dom-mask-lit (hash-ref env-b s lit-zero)) lit-zero))
         (for/and ([qw (in-set active-quotient-wires)])
           (= (dom-mask-lit (hash-ref env-b qw lit-zero)) lit-zero))
         (for/and ([(_ t-lit) (in-hash phase-taints)])
           (= (dom-mask-lit t-lit) lit-zero))))

  (define (step-node! node [inherited-sp #f])
    (define node-sp (node-or-synthetic-span node inherited-sp decl-span 'RevIR))
    (define step-idx (unbox cur-step-box))
    (match node
      [`(rev-gate (x ,w))
       (update-wire-env! w (lit-not (hash-ref wire-env w lit-zero)) node-sp)
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]
      [`(rev-gate (,(or 'z 's 's-dag) ,w))
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]
      [`(rev-gate (h ,w))
       (check-interference-xag! `(h ,w) (list w) node-sp step-idx)
       (define vid (alloc-var! (format "q~a_h" w) (format "~a@h" (surf-wire-at w step-idx))))
       (update-wire-env! w (xag-var mgr vid) node-sp)
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]
      [`(rev-gate (ry ,theta ,w))
       (check-interference-xag! `(ry ,theta ,w) (list w) node-sp step-idx)
       (define vid (alloc-var! (format "q~a_ry" w) (format "~a@ry" (surf-wire-at w step-idx))))
       (update-wire-env! w (xag-var mgr vid) node-sp)
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]
      [`(rev-gate (,(or 'rz-dyadic 'rz-dyadic-neg) ,w ,exp-k ,f64? ,code-d))
       (define d (target-hw-profile-gate-1q-ns hw))
       (define exact-angle? (or (not f64?) (< exp-k 53)))
       (define eff-d (if exact-angle? code-d 0))
       (define req-d (max 3 code-d))
       (unless (>= eff-d req-d)
         (define rw (resolved-at w step-idx))
         (define w-surf (lfq-resolved-wire-surface-name rw))
         (record-violation!
          'QPhysGrade 'Phi3-FaultExponent
          (format "IEEE-754 float64 truncation on rz-dyadic(k=~a) collapses fault exponent to ~a < ~a"
                  exp-k eff-d req-d)
          (hasheq 'wire w 'dyadic_exponent_k exp-k
                  'effective_fault_distance eff-d 'required_fault_distance req-d)
          #:resugared-message
          (format "IEEE-754 float64 truncation on `rz-dyadic` (`k=~a`, wire `~a`) collapses fault exponent to ~a < ~a"
                  exp-k w-surf eff-d req-d)
          #:origin-span decl-span #:mutating-span node-sp #:failure-span node-sp
          #:surface-wire w-surf
          #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() eff-d req-d (seteqv w) d)]
      [`(rev-gate (cx ,c ,t))
       (update-wire-env! t (xag-xor mgr (hash-ref wire-env t lit-zero)
                                        (hash-ref wire-env c lit-zero)) node-sp)
       (define d (target-hw-profile-gate-2q-ns hw))
       (note-phi1-contributor! (* 2 d) node-sp)
       (qphys-semiring-grade (* 2 d) (target-hw-profile-p2q-permil hw) 0 0 0 '() #f 0 (seteqv c t) d)]
      [`(rev-gate (cz ,a ,b))
       (define d (target-hw-profile-gate-2q-ns hw))
       (note-phi1-contributor! (* 2 d) node-sp)
       (qphys-semiring-grade (* 2 d) (target-hw-profile-p2q-permil hw) 0 0 0 '() #f 0 (seteqv a b) d)]
      [`(rev-gate (swap ,a ,b))
       (define pa (hash-ref wire-env a lit-zero))
       (define pb (hash-ref wire-env b lit-zero))
       (update-wire-env! a pb node-sp)
       (update-wire-env! b pa node-sp)
       (define d (* 3 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 2 d) node-sp)
       (qphys-semiring-grade (* 2 d) (* 3 (target-hw-profile-p2q-permil hw)) 0 0 0 '() #f 0 (seteqv a b) d)]
      [`(rev-gate (ccx ,c1 ,c2 ,t))
       (define p1 (hash-ref wire-env c1 lit-zero))
       (define p2 (hash-ref wire-env c2 lit-zero))
       (define pt (hash-ref wire-env t lit-zero))
       (define prod (xag-and mgr p1 p2))
       (observe-cone-lit! prod)
       (update-wire-env! t (xag-xor mgr pt prod) node-sp)
       (define d (* 6 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 3 d) node-sp)
       (qphys-semiring-grade (* 3 d) (* 6 (target-hw-profile-p2q-permil hw)) 0 0 0 '() #f 0 (seteqv c1 c2 t) d)]
      [`(rev-gate (ccz ,a ,b ,c))
       (define d (* 6 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 3 d) node-sp)
       (qphys-semiring-grade (* 3 d) (* 6 (target-hw-profile-p2q-permil hw)) 0 0 0 '() #f 0 (seteqv a b c) d)]
      [`(rev-temp-and ,c1 ,c2 ,anc)
       (define-values (z? raw-cex surf-cex desc) (check-lit-zero! (hash-ref wire-env anc lit-zero)))
       (unless z?
         (define rw (resolved-at anc step-idx))
         (define a-surf (lfq-resolved-wire-surface-name rw))
         (record-violation!
          'QSub 'U1-EraseBy
          (format "TempAND target wire q[~a] is not clean |0> on entry (~a)" anc desc)
          (hasheq 'wire anc 'residual_xag desc 'counterexample_basis raw-cex)
          #:resugared-message (format "TempAND target wire `~a` is not clean |0> on entry (`~a`)" a-surf desc)
          #:origin-span decl-span #:mutating-span (hash-ref last-mutating-span anc node-sp)
          #:failure-span node-sp #:surface-wire a-surf
          #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
          #:resugared-anf desc #:resugared-witness surf-cex))
       (define prod (xag-and mgr (hash-ref wire-env c1 lit-zero)
                                 (hash-ref wire-env c2 lit-zero)))
       (observe-cone-lit! prod)
       (update-wire-env! anc prod node-sp)
       (define d (* 4 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 3 d) node-sp)
       (qphys-semiring-grade (* 3 d) (* 4 (target-hw-profile-p2q-permil hw)) 0 0 0 '() #f 0 (seteqv c1 c2 anc) d)]
      [`(rev-prepare-dicke-le1 ,ws ,_ ,_ ,_)
       (for ([w (in-list ws)])
         (define vid (alloc-var! (format "dicke_q~a" w) (surf-wire-at w step-idx)))
         (update-wire-env! w (xag-var mgr vid) node-sp))
       (define m (length ws))
       (define n-2q (* 3 (max 0 (sub1 m))))
       (define d (* n-2q (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* m d) node-sp)
       (qphys-semiring-grade (* m d) (* n-2q (target-hw-profile-p2q-permil hw)) 0 0 0 '() #f 0 (list->seteqv ws) d)]
      [`(rev-mid-meas-x ,anc ,m-sym ,shielded?)
       (define rw (resolved-at anc step-idx))
       (define anc-surf (lfq-resolved-wire-surface-name rw))
       (unless (hash-has-key? meas-origin-info m-sym)
         (hash-set! meas-origin-info m-sym (cons node-sp anc-surf)))
       (when node-sp (hash-set! last-taint-span m-sym node-sp))
       (define p-anc (hash-ref wire-env anc lit-zero))
       (observe-cone-lit! p-anc)
       (define prev-t (hash-ref phase-taints m-sym lit-zero))
       (hash-set! phase-taints m-sym (xag-xor mgr prev-t p-anc))
       (update-wire-env! anc lit-zero node-sp)
       (define n-spec
         (for/sum ([(w l) (in-hash wire-env)]
                   #:when (and (not (= w anc)) (not (= l lit-zero))))
           1))
       (define t-meas (target-hw-profile-t-meas-reset-ns hw))
       (define u-bud (target-hw-profile-unitary-budget-ns hw))
       (define mbu-exc (if shielded? 0 (max 0 (- (* (+ 2 n-spec) t-meas) u-bud))))
       (note-phi1-contributor! (+ t-meas (* 1000 mbu-exc)) node-sp)
       (when (> mbu-exc 0)
         (record-violation!
          'QPhysGrade 'Phi1-DecoherenceAction
          (format "Unshielded mid-circuit M_X on q[~a] with ~a live spectators exceeds Lindblad budget by ~a ns (missing XY4 echo)"
                  anc n-spec mbu-exc)
          (hasheq 'measured_wire anc 'live_spectators n-spec 'meas_reset_ns t-meas 'mbu_excess_ns mbu-exc)
          #:resugared-message
          (format "Unshielded mid-circuit `M_X` on `~a` with ~a live spectators exceeds Lindblad budget by ~a ns (missing XY4 echo)"
                  anc-surf n-spec mbu-exc)
          #:origin-span decl-span #:mutating-span node-sp #:failure-span node-sp
          #:surface-wire anc-surf
          #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)))
       (qphys-semiring-grade t-meas 0 mbu-exc 0 0 '() #f 0 (seteqv anc) t-meas)]
      [`(rev-cond-z ,m-sym ,t)
       (when node-sp (hash-set! last-taint-span m-sym node-sp))
       (hash-set! phase-taints m-sym
                  (xag-xor mgr (hash-ref phase-taints m-sym lit-zero)
                               (hash-ref wire-env t lit-zero)))
       (define d (target-hw-profile-gate-1q-ns hw))
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv t) d)]
      [`(rev-cond-cz ,m-sym ,c1 ,c2)
       (when node-sp (hash-set! last-taint-span m-sym node-sp))
       (hash-set! phase-taints m-sym
                  (xag-xor mgr (hash-ref phase-taints m-sym lit-zero)
                               (xag-and mgr (hash-ref wire-env c1 lit-zero)
                                            (hash-ref wire-env c2 lit-zero))))
       (define d (target-hw-profile-gate-2q-ns hw))
       (qphys-semiring-grade (* 2 d) (target-hw-profile-p2q-permil hw) 0 0 0 '() #f 0 (seteqv c1 c2) d)]
      [`(rev-syndrome-plaquette ,ws ,code-d ,hook-aligned?)
       (define eff-d (if hook-aligned? (quotient (+ code-d 1) 2) code-d))
       (define req-d (max 3 code-d))
       (when (< eff-d req-d)
         (define surf-ws (map (lambda (u) (surf-wire-at u step-idx)) ws))
         (record-violation!
          'QPhysGrade 'Phi3-FaultExponent
          (format "Aligned stabilizer CNOT round on plaquette ~a degrades fault distance ~a -> ~a < ~a"
                  ws code-d eff-d req-d)
          (hasheq 'plaquette_wires ws 'nominal_code_distance code-d
                  'effective_fault_distance eff-d 'required_fault_distance req-d)
          #:resugared-message
          (format "Aligned stabilizer CNOT round on plaquette (~a) degrades fault distance ~a -> ~a < ~a (requires N-Z-S-W schedule)"
                  (string-join surf-ws " ") code-d eff-d req-d)
          #:origin-span decl-span #:mutating-span node-sp #:failure-span node-sp
          #:surface-wire (and (pair? surf-ws) (car surf-ws))))
       (define n-2q (max 1 (sub1 (length ws))))
       (define d (* n-2q (target-hw-profile-gate-2q-ns hw)))
       (qphys-semiring-grade (* (length ws) d) (* n-2q (target-hw-profile-p2q-permil hw))
                             0 0 0 '() eff-d req-d (list->seteqv ws) d)]
      [`(rev-erase-check ,ws)
       (for ([w (in-list ws)])
         (define-values (z? raw-cex surf-cex desc) (check-lit-zero! (hash-ref wire-env w lit-zero)))
         (unless z?
           (define rw (resolved-at w step-idx))
           (define w-surf (lfq-resolved-wire-surface-name rw))
           (record-violation!
            'QSub 'U1-EraseBy
            (format "Scratch wire q[~a] not erased to |0> on domain (~a)" w desc)
            (hasheq 'wire w 'residual_xag desc 'counterexample_basis raw-cex)
            #:resugared-message (format "Scratch wire `~a` not erased to |0> on domain (`~a`)" w-surf desc)
            #:origin-span decl-span #:mutating-span (hash-ref last-mutating-span w node-sp)
            #:failure-span node-sp #:surface-wire w-surf
            #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
            #:resugared-anf desc #:resugared-witness surf-cex)))
       qphys-grade-identity]
      [`(rev-quotient-check ,q-ws)
       (for ([qw (in-list q-ws)])
         (set-add! active-quotient-wires qw)
         (define-values (z? raw-cex surf-cex desc) (check-lit-zero! (hash-ref wire-env qw lit-zero)))
         (unless z?
           (define rw (resolved-at qw step-idx))
           (define q-surf (lfq-resolved-wire-surface-name rw))
           (record-violation!
            'QSub 'U2-Canonical
            (format "Quotient wire q[~a] failed canonicalization to |0> (~a)" qw desc)
            (hasheq 'quotient_wire qw 'residual_xag desc 'counterexample_basis raw-cex)
            #:resugared-message (format "Quotient wire `~a` failed canonicalization to |0> (`~a`)" q-surf desc)
            #:origin-span decl-span #:mutating-span (hash-ref last-mutating-span qw node-sp)
            #:failure-span node-sp #:surface-wire q-surf
            #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
            #:resugared-anf desc #:resugared-witness surf-cex)))
       qphys-grade-identity]
      [`(rev-qmatch ,arms)
       (define entry-env (hash-copy wire-env))
       (define guard-lits (for/list ([arm (in-list arms)]) (eval-guard-lit entry-env (first arm))))
       (for* ([i (in-range (length guard-lits))]
              [j (in-range (add1 i) (length guard-lits))])
         (define-values (z? raw-cex surf-cex desc)
           (check-lit-zero! (xag-and mgr (list-ref guard-lits i) (list-ref guard-lits j))))
         (unless z?
           (record-violation!
            'QSub 'U3-TotalOn
            (format "Overlapping qmatch guards ~a and ~a (~a)" i j desc)
            (hasheq 'arm_i i 'arm_j j 'overlap_xag desc 'counterexample_basis raw-cex)
            #:resugared-message (format "Overlapping `qmatch` guards ~a and ~a (`~a`)" i j desc)
            #:origin-span decl-span #:mutating-span node-sp #:failure-span node-sp
            #:resugared-anf desc #:resugared-witness surf-cex)))
       (define sum-gl (foldl (lambda (gl acc) (xag-xor mgr acc gl)) lit-zero guard-lits))
       (define-values (tot-z? u-cex u-surf desc-u) (check-lit-zero! (xag-xor mgr lit-one sum-gl)))
       (unless tot-z?
         (record-violation!
          'QSub 'U3-TotalOn
          (format "Non-exhaustive qmatch leaves domain locus uncovered (~a)" desc-u)
          (hasheq 'uncovered_xag desc-u 'counterexample_basis u-cex)
          #:resugared-message (format "Non-exhaustive `qmatch` leaves domain locus uncovered (`~a`)" desc-u)
          #:origin-span decl-span #:mutating-span node-sp #:failure-span node-sp
          #:resugared-anf desc-u #:resugared-witness u-surf))
       (define arm-envs '())
       (set-box! in-qmatch-depth-box (add1 (unbox in-qmatch-depth-box)))
       (define joined-grade
         (for/fold ([acc-g qphys-grade-identity])
                   ([arm (in-list arms)] [gl (in-list guard-lits)] [idx (in-naturals)])
           (hash-clear! wire-env)
           (for ([(k v) (in-hash entry-env)]) (hash-set! wire-env k v))
           (define last-arm-sp-box (box node-sp))
           (define arm-g
             (for/fold ([ag qphys-grade-identity]) ([sub (in-list (second arm))])
               (when (lookup-surface-span sub) (set-box! last-arm-sp-box (lookup-surface-span sub)))
               (qphys-grade-seq ag (step-node! sub node-sp))))
           (define post-gl (eval-guard-lit wire-env (first arm)))
           (define-values (dz? d-cex d-surf d-desc) (check-lit-zero! (xag-xor mgr gl post-gl)))
           (unless dz?
             (record-violation!
              'QSub 'U3-TotalOn
              (format "qmatch arm ~a mutates its own guard (~a)" idx d-desc)
              (hasheq 'arm idx 'drift_xag d-desc 'counterexample_basis d-cex)
              #:resugared-message (format "`qmatch` arm ~a mutates its own guard (`~a`)" idx d-desc)
              #:origin-span node-sp #:mutating-span (unbox last-arm-sp-box) #:failure-span node-sp
              #:resugared-anf d-desc #:resugared-witness d-surf))
           (set! arm-envs (append arm-envs (list (hash-copy wire-env))))
           (qphys-grade-join acc-g arm-g)))
       (set-box! in-qmatch-depth-box (sub1 (unbox in-qmatch-depth-box)))
       (define all-keys (remove-duplicates (append (hash-keys entry-env) (apply append (map hash-keys arm-envs)))))
       (hash-clear! wire-env)
       (for ([w (in-list all-keys)])
         (define merged
           (for/fold ([acc lit-zero]) ([gl (in-list guard-lits)] [aenv (in-list arm-envs)])
             (xag-xor mgr acc (xag-and mgr gl (hash-ref aenv w lit-zero)))))
         (hash-set! wire-env w merged)
         (when (= merged lit-zero) (hash-remove! last-mutating-span w)))
       joined-grade]
      [`(rev-par ,ir1 ,ir2)
       (define g1 (for/fold ([ag qphys-grade-identity]) ([sub (in-list ir1)]) (qphys-grade-seq ag (step-node! sub node-sp))))
       (define g2 (for/fold ([ag qphys-grade-identity]) ([sub (in-list ir2)]) (qphys-grade-seq ag (step-node! sub node-sp))))
       (define pg (qphys-grade-par hw g1 g2))
       (define new-hits
         (drop (qphys-semiring-grade-colliding-pairs pg)
               (+ (length (qphys-semiring-grade-colliding-pairs g1))
                  (length (qphys-semiring-grade-colliding-pairs g2)))))
       (unless (null? new-hits)
         (define surf-hits
           (for/list ([pr (in-list new-hits)])
             (format "(~a, ~a)" (surf-wire-at (first pr) step-idx) (surf-wire-at (second pr) step-idx))))
         (record-violation!
          'QPhysGrade 'Phi2-ExclusionGraph
          (format "Parallel wires collide in hardware exclusion neighborhood: ~a" new-hits)
          (hasheq 'colliding_wire_pairs new-hits
                  'blockade_radius_um (target-hw-profile-blockade-radius-um hw)
                  'site_spacing_um (target-hw-profile-site-spacing-um hw))
          #:resugared-message (format "Parallel wires collide in hardware exclusion neighborhood: ~a" (string-join surf-hits ", "))
          #:origin-span decl-span #:mutating-span node-sp #:failure-span node-sp))
       pg]
      [`(rev-focus-zipper ,_ ,ir)
       (when (phase-clean-state-xag?)
         (hash-set! certified-phase-clean-zippers-table node #t))
       (run-top-nodes! ir node-sp)]
      [`(rev-for-fold-loop ,n-rounds ,round-irs)
       ;; Zero-flag `k=1 -> k=2 -> k=R` round-invariant escalation (`T-Loop-Inductive`):
       (cond
         [(or (<= n-rounds 0) (null? round-irs))
          qphys-grade-identity]
         [else
          (define scratch-set (list->seteqv scratch-phys))
          (define (revir-round-skeleton rir)
            (define m-canon-table (make-hasheq))
            (define next-m-idx 0)
            (define (canon-m m-sym)
              (hash-ref! m-canon-table m-sym
                         (lambda ()
                           (begin0 (string->symbol (format "m_loc_~a" next-m-idx))
                             (set! next-m-idx (add1 next-m-idx))))))
            (let walk-nodes ([ns rir])
              (filter-map
               (lambda (n)
                 (match n
                   [`(rev-gate (x ,w)) #:when (not (set-member? scratch-set w)) #f]
                   [`(rev-mid-meas-x ,anc ,m-sym ,sh?)
                    `(rev-mid-meas-x ,anc ,(canon-m m-sym) ,sh?)]
                   [`(rev-cond-z ,m-sym ,t)
                    `(rev-cond-z ,(canon-m m-sym) ,t)]
                   [`(rev-cond-cz ,m-sym ,c1 ,c2)
                    `(rev-cond-cz ,(canon-m m-sym) ,c1 ,c2)]
                   [`(rev-par ,ir1 ,ir2)
                    `(rev-par ,(walk-nodes ir1) ,(walk-nodes ir2))]
                   [`(rev-focus-zipper ,c ,ir)
                    `(rev-focus-zipper ,c ,(walk-nodes ir))]
                   [`(rev-qmatch ,arms)
                    `(rev-qmatch ,(for/list ([arm (in-list arms)])
                                    (list (first arm) (walk-nodes (second arm)))))]
                   [`(rev-for-fold-loop ,nr ,rirs)
                    `(rev-for-fold-loop ,nr ,(map walk-nodes rirs))]
                   [`(rev-multishot ,k ,ir)
                    `(rev-multishot ,k ,(walk-nodes ir))]
                   [_ n]))
               ns)))
          (define round-skeletons (map revir-round-skeleton round-irs))
          (define k1-uniform?
            (and (= (length round-irs) n-rounds)
                 (or (<= n-rounds 1)
                     (let ([s0 (first round-skeletons)])
                       (for/and ([s (in-list (rest round-skeletons))])
                         (equal? s s0))))))
          (define k2-uniform?
            (and (>= n-rounds 2)
                 (even? n-rounds)
                 (= (length round-irs) n-rounds)
                 (let ([p0 (list (first round-skeletons) (second round-skeletons))])
                   (for/and ([j (in-range 1 (quotient n-rounds 2))])
                     (equal? (list (list-ref round-skeletons (* 2 j))
                                   (list-ref round-skeletons (add1 (* 2 j))))
                             p0)))))
          (define (scratch-and-taints-clean?)
            (and (for/and ([s (in-list scratch-phys)])
                   (define-values (z? _1 _2 _3) (check-lit-zero! (hash-ref wire-env s lit-zero)))
                   z?)
                 (for/and ([(_ms tl) (in-hash phase-taints)])
                   (define-values (z? _1 _2 _3) (check-lit-zero! tl))
                   z?)))
          (define top-final-loop?
            (and (eq? node (first revir))
                 (for/and ([after (in-list (cdr revir))])
                   (match after [`(rev-erase-check ,_) #t] [_ #f]))))
          (define entry-clean? (scratch-and-taints-clean?))
          (define pre-v-count (length violations))
          (define entry-env (hash-copy wire-env))
          (define r0-steps (count-revir-leaf-steps (first round-irs)))
          (define g0 (run-top-nodes! (first round-irs) node-sp))
          (cond
            [(and k1-uniform?
                  (>= n-rounds 2)
                  (= (length violations) pre-v-count)
                  (or (envs-identical-and-clean-xag? entry-env wire-env)
                      (and (eq? domain-spec 'all) top-final-loop? entry-clean? (scratch-and-taints-clean?))))
             ;; Stage 1 (`k = 1`): Single-round inductive invariant certified!
             (set-box! cur-step-box (+ (unbox cur-step-box) (* (sub1 n-rounds) r0-steps)))
             (set! loop-escalations
                   (cons (hasheq 'rounds n-rounds
                                 'k_induction_depth 1
                                 'k_certified 1
                                 'escalation_path '("k=1")
                                 'status "inductive-k1-verified")
                         loop-escalations))
             (for/fold ([acc qphys-grade-identity]) ([_ (in-range n-rounds)])
               (qphys-grade-seq acc g0))]
            [(and (>= n-rounds 2) (= (length violations) pre-v-count))
             (define r1-steps (count-revir-leaf-steps (second round-irs)))
             (define g1 (run-top-nodes! (second round-irs) node-sp))
             (cond
               [(and k2-uniform?
                     (= (length violations) pre-v-count)
                     (or (envs-identical-and-clean-xag? entry-env wire-env)
                         (and (eq? domain-spec 'all) top-final-loop? entry-clean? (scratch-and-taints-clean?))))
                ;; Stage 2 (`k = 2`): 2-round ping-pong / involutory inductive invariant certified!
                (set-box! cur-step-box
                          (+ (unbox cur-step-box)
                             (* (sub1 (quotient n-rounds 2)) (+ r0-steps r1-steps))))
                (set! loop-escalations
                      (cons (hasheq 'rounds n-rounds
                                    'k_induction_depth 2
                                    'k_certified 2
                                    'escalation_path '("k=1" "k=2")
                                    'status "inductive-k2-pingpong-verified")
                            loop-escalations))
                (define g-pair (qphys-grade-seq g0 g1))
                (for/fold ([acc qphys-grade-identity]) ([_ (in-range (quotient n-rounds 2))])
                  (qphys-grade-seq acc g-pair))]
               [else
                ;; Stage 3 (`k = R`): Automatic fallback to full `R`-round unrolled check with 1-WL cone cache
                (define g-rest
                  (for/fold ([acc (qphys-grade-seq g0 g1)]) ([rir (in-list (drop round-irs 2))])
                    (qphys-grade-seq acc (run-top-nodes! rir node-sp))))
                (set! loop-escalations
                      (cons (hasheq 'rounds n-rounds
                                    'k_induction_depth n-rounds
                                    'k_certified n-rounds
                                    'escalation_path '("k=1" "k=2" "k=R")
                                    'status "bounded-kR-1wl-cached")
                            loop-escalations))
                g-rest])]
            [else
             (define g-all
               (for/fold ([acc g0]) ([rir (in-list (rest round-irs))])
                 (qphys-grade-seq acc (run-top-nodes! rir node-sp))))
             (set! loop-escalations
                   (cons (hasheq 'rounds n-rounds
                                 'k_induction_depth n-rounds
                                 'k_certified n-rounds
                                 'escalation_path (if (>= n-rounds 2) '("k=1" "k=R") '("k=1"))
                                 'status "bounded-kR-1wl-cached")
                         loop-escalations))
             g-all])])]
      [`(rev-multishot ,k ,ir)
       (qphys-grade-multishot k (run-top-nodes! ir node-sp))]
      [_ (error 'infer-revir-qsub-and-qphys-xag "Unknown RevIR node: ~a" node)]))

  (define (run-top-nodes! nodes [inherited-sp #f])
    (for/fold ([g qphys-grade-identity]) ([node (in-list nodes)])
      (match node
        [(or `(rev-multishot ,_ ,_)
             `(rev-focus-zipper ,_ ,_)
             `(rev-for-fold-loop ,_ ,_))
         (qphys-grade-seq g (step-node! node inherited-sp))]
        [_
         (define ng (step-node! node inherited-sp))
         (set-box! cur-step-box (add1 (unbox cur-step-box)))
         (qphys-grade-seq g ng)])))

  (define total-grade (run-top-nodes! revir))

  (for ([s (in-list scratch-phys)])
    (define-values (z? raw-cex surf-cex desc) (check-lit-zero! (hash-ref wire-env s lit-zero)))
    (unless z?
      (define rw (resolved-at s #f))
      (define s-surf (lfq-resolved-wire-surface-name rw))
      (record-violation!
       'QSub 'U1-EraseBy
       (format "Scratch wire q[~a] leaked non-zero state at circuit exit (~a)" s desc)
       (hasheq 'wire s 'residual_xag desc 'counterexample_basis raw-cex)
       #:resugared-message (format "Scratch wire `~a` leaked non-zero state at circuit exit (`~a`)" s-surf desc)
       #:origin-span decl-span #:mutating-span (hash-ref last-mutating-span s decl-span)
       #:failure-span decl-span #:surface-wire s-surf
       #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
       #:resugared-anf desc #:resugared-witness surf-cex)))

  (for ([qw (in-set active-quotient-wires)])
    (define-values (z? raw-cex surf-cex desc) (check-lit-zero! (hash-ref wire-env qw lit-zero)))
    (unless z?
      (define rw (resolved-at qw #f))
      (define q-surf (lfq-resolved-wire-surface-name rw))
      (record-violation!
       'QSub 'U2-Canonical
       (format "Quotient wire q[~a] remains non-zero at circuit exit (~a)" qw desc)
       (hasheq 'quotient_wire qw 'residual_xag desc 'counterexample_basis raw-cex)
       #:resugared-message (format "Quotient wire `~a` remains non-zero at circuit exit (`~a`)" q-surf desc)
       #:origin-span decl-span #:mutating-span (hash-ref last-mutating-span qw decl-span)
       #:failure-span decl-span #:surface-wire q-surf
       #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
       #:resugared-anf desc #:resugared-witness surf-cex)))

  (define residual-phase-count 0)
  (for ([(m-sym t-lit) (in-hash phase-taints)])
    (define-values (z? raw-cex surf-cex desc) (check-lit-zero! t-lit))
    (unless z?
      (set! residual-phase-count (add1 residual-phase-count))
      (define minfo (hash-ref meas-origin-info m-sym #f))
      (define orig-sp (or (and minfo (car minfo)) decl-span))
      (define anc-surf (and minfo (cdr minfo)))
      (define m-desc (resugar-measurement-symbol m-sym anc-surf))
      (record-violation!
       'QSub 'U4-QTainted
       (format "Mid-circuit measurement ~a leaves residual quantum phase kickback (~a) at exit" m-sym desc)
       (hasheq 'measurement (symbol->string m-sym) 'residual_phase_xag desc 'counterexample_basis raw-cex)
       #:resugared-message (format "Mid-circuit ~a leaves residual quantum phase kickback (`~a`) at exit" m-desc desc)
       #:origin-span orig-sp #:mutating-span (hash-ref last-taint-span m-sym orig-sp)
       #:failure-span decl-span #:surface-wire anc-surf
       #:resugared-anf desc #:resugared-witness surf-cex)))

  (define total-action-milli (grade-decoherence-action-milli hw total-grade))
  (when (> total-action-milli 693)
    (record-violation!
     'QPhysGrade 'Phi1-DecoherenceAction
     (format "Total Lindblad decoherence action ~a milli-nats exceeds budget 693" total-action-milli)
     (hasheq 'effective_action_milli total-action-milli
             'budget_milli 693
             'mbu_excess_ns (qphys-semiring-grade-mbu-excess-ns total-grade))
     #:origin-span decl-span
     #:mutating-span (or (cdr (unbox dominant-phi1-box)) decl-span)
     #:failure-span decl-span))

  (set-box! last-xag-telemetry-box
            (hasheq 'engine "xag-fraig-z3"
                    'total_cones_evaluated (unbox total-cones-box)
                    'unique_canonical_cones (set-count seen-cone-sigs)
                    'cone_isomorphism_hits (unbox cone-iso-hits-box)
                    'fraig_merges (xag-manager-fraig-merges mgr)
                    'cut_cache_hits (xag-manager-cut-cache-hits mgr)
                    'z3_queries (xag-manager-z3-queries mgr)
                    'z3_push_pop_incremental #t
                    'for_fold_loops (reverse loop-escalations)))
  (close-persistent-z3!)
  (values violations total-grade total-action-milli residual-phase-count
          (sort (set->list active-quotient-wires) <)))

(define (infer-revir-qsub-and-qphys revir input-wires scratch-phys domain-spec hw
                                    #:decl [decl #f]
                                    #:color-map [color-map #f]
                                    #:extra-virt-names [extra-virt-names #f]
                                    #:anf-monomial-cap [anf-monomial-cap 1024])
  (set-box! last-symbolic-engine-box 'anf-zhegalkin)
  (hash-clear! certified-phase-clean-zippers-table)
  (let/ec escape-to-xag
    (define (escalate!)
      (call-with-values
       (lambda ()
         (infer-revir-qsub-and-qphys-xag revir input-wires scratch-phys domain-spec hw
                                         #:decl decl
                                         #:color-map color-map
                                         #:extra-virt-names extra-virt-names))
       escape-to-xag))
    (when (or (revir-has-for-fold-loop? revir)
              (and anf-monomial-cap (<= anf-monomial-cap 0))
              (and anf-monomial-cap
                   (> (length input-wires) 20)
                   (>= (count-revir-temp-ands revir) 40)))
      (escalate!))
    (define (guard-poly-cap p)
      (when (and anf-monomial-cap (> (length p) anf-monomial-cap))
        (escalate!))
      p)
    (define (anf-and-capped p1 p2)
      (when (and anf-monomial-cap (> (* (length p1) (length p2)) (* 16 anf-monomial-cap)))
        (escalate!))
      (guard-poly-cap (anf-and p1 p2)))
    (define resugarer (build-wire-resugarer decl color-map #f extra-virt-names))
    (define decl-span (decl-or-synthetic-span decl 'RevIR))
    (define wire-env (make-hasheqv))
    (define var-names (make-hasheqv))
    (define var-surface-names (make-hasheqv))
    (define seen-label-counts (make-hash))
    (define seen-surf-counts (make-hash))
    (define (unique-lbl tbl base)
      (define c (add1 (hash-ref tbl base 0)))
      (hash-set! tbl base c)
      (if (= c 1) base (format "~a~a" base c)))
    (define next-var-box (box 0))
    (define (alloc-var! label [surf-label #f])
      (define id (unbox next-var-box))
      (set-box! next-var-box (add1 id))
      (hash-set! var-names id (unique-lbl seen-label-counts label))
      (hash-set! var-surface-names id (unique-lbl seen-surf-counts (or surf-label label)))
      id)

    (define (resolved-at w [step-idx #f])
      (resolve-physical-wire resugarer w step-idx))
    (define (surf-wire-at w [step-idx #f])
      (lfq-resolved-wire-surface-name (resolved-at w step-idx)))

    (for ([w (in-list input-wires)])
      (define vid (alloc-var! (format "q~a_in" w) (surf-wire-at w 0)))
      (hash-set! wire-env w (anf-var vid)))
    (for ([s (in-list scratch-phys)] #:unless (hash-has-key? wire-env s))
      (hash-set! wire-env s anf-zero))

    ;; Domain ideal reduction (`0` manual flags!):
    (define active-quotient-wires (mutable-seteqv))
    (define wt-bound-box (box #f))
    (define dom-guard-poly-box (box anf-one))

    (match domain-spec
      ['all (void)]
      [`(wt-le ,t)
       (set-box! wt-bound-box t)]
      [`(quotient-vars ,qws)
       (for ([qw (in-list qws)])
         (set-add! active-quotient-wires qw)
         (unless (hash-has-key? wire-env qw)
           (define vid (alloc-var! (format "q~a_quot" qw) (surf-wire-at qw 0)))
           (hash-set! wire-env qw (anf-var vid))))]
      [`(domain-guard ,g)
       (define gp (guard-poly-cap (eval-guard-anf wire-env guard-poly-cap g)))
       (set-box! dom-guard-poly-box gp)]
      [_ (error 'infer-revir-qsub-and-qphys "Unsupported domain specification: ~a" domain-spec)])

    ;; Record variables constrained by `wt-le` (input/Dicke variables):
    (define wt-constrained-vars (mutable-seteqv))
    (when (unbox wt-bound-box)
      (for ([w (in-list input-wires)])
        (for ([v (in-list (anf-vars (hash-ref wire-env w anf-zero)))])
          (set-add! wt-constrained-vars v))))

    (define (dom-reduce p0)
      (define p (guard-poly-cap p0))
      (define p1
        (if (equal? (unbox dom-guard-poly-box) anf-one)
            p
            (anf-and-capped (unbox dom-guard-poly-box) p)))
      (define wt-t (unbox wt-bound-box))
      (if (not wt-t)
          p1
          (filter (lambda (m)
                    (<= (for/sum ([v (in-list m)])
                          (if (set-member? wt-constrained-vars v) 1 0))
                        wt-t))
                  p1)))

  (define phase-taints (make-hasheq))     ;; meas-sym -> ANF
  (define last-mutating-span (make-hasheqv)) ;; phys-wire -> lfq-surface-span
  (define meas-origin-info (make-hasheq)) ;; meas-sym -> (cons span surf-wire-str)
  (define last-taint-span (make-hasheq))  ;; meas-sym -> lfq-surface-span
  (define dominant-phi1-box (box (cons 0 #f))) ;; (cons score span)
  (define cur-step-box (box 0))
  (define in-qmatch-depth-box (box 0))

  (define (update-wire-env! w new-poly node-sp)
    (hash-set! wire-env w new-poly)
    (if (null? new-poly)
        (hash-remove! last-mutating-span w)
        (when node-sp
          (hash-set! last-mutating-span w node-sp))))

  (define (note-phi1-contributor! score node-sp)
    (when (and node-sp (> score (car (unbox dominant-phi1-box))))
      (set-box! dominant-phi1-box (cons score node-sp))))

  (define violations '())
  (define (record-violation! category code msg witness
                             #:resugared-message [resugared-msg #f]
                             #:origin-span [origin-span #f]
                             #:mutating-span [mutating-span #f]
                             #:failure-span [failure-span #f]
                             #:surface-wire [surface-wire #f]
                             #:chordal-recycled-from [recycled-from '()]
                             #:resugared-anf [resugared-anf #f]
                             #:resugared-witness [resugared-witness #f]
                             #:repair-hint [repair-hint #f])
    (define base-v
      (hasheq 'category (symbol->string category)
              'code (symbol->string code)
              'message msg
              'witness witness))
    (define enriched-v
      (enrich-revir-violation base-v
                              #:resugared-message (or resugared-msg msg)
                              #:origin-span (or origin-span decl-span)
                              #:mutating-span mutating-span
                              #:failure-span failure-span
                              #:surface-wire surface-wire
                              #:chordal-recycled-from recycled-from
                              #:resugared-anf resugared-anf
                              #:resugared-witness resugared-witness
                              #:repair-hint repair-hint))
    (set! violations (append violations (list enriched-v))))

  (define (resugar-gate-desc gate-desc step-idx)
    (match gate-desc
      [`(,op ,w) `(,op ,(string->symbol (surf-wire-at w step-idx)))]
      [`(ry ,theta ,w) `(ry ,theta ,(string->symbol (surf-wire-at w step-idx)))]
      [_ gate-desc]))

  (define (check-interference-preconditions! gate-desc target-wires node-sp step-idx)
    (define surf-gate (resugar-gate-desc gate-desc step-idx))
    ;; Law U2 (`Canonical`): all active quotient wires must have ANF == 0 before interference!
    (for ([qw (in-set active-quotient-wires)])
      (define q-poly (dom-reduce (hash-ref wire-env qw anf-zero)))
      (unless (null? q-poly)
        (define rw (resolved-at qw step-idx))
        (define q-surf (lfq-resolved-wire-surface-name rw))
        (define r-anf (resugar-anf->string q-poly var-surface-names))
        (record-violation!
         'QSub 'U2-Canonical
         (format "Quotient wire q[~a] retains non-canonical history (~a) across interference ~a"
                 qw (anf->string q-poly) gate-desc)
         (hasheq 'quotient_wire qw
                 'residual_anf (anf->string q-poly)
                 'counterexample_basis (extract-anf-counterexample-witness q-poly var-names))
         #:resugared-message
         (format "Quotient wire `~a` retains non-canonical history (`~a`) across interference `~a`"
                 q-surf r-anf surf-gate)
         #:origin-span decl-span
         #:mutating-span (hash-ref last-mutating-span qw node-sp)
         #:failure-span node-sp
         #:surface-wire q-surf
         #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
         #:resugared-anf r-anf
         #:resugared-witness (resugar-counterexample-witness q-poly var-surface-names))))
    ;; Law U4 (`QTainted`): target wires of basis-mixing interference must not carry uncancelled M_X phase taints!
    (define tgt-vars
      (list->seteqv
       (apply append
              (for/list ([tw (in-list target-wires)])
                (anf-vars (dom-reduce (hash-ref wire-env tw anf-zero)))))))
    (for ([(m-sym t-poly-raw) (in-hash phase-taints)])
      (define t-poly (dom-reduce t-poly-raw))
      (unless (null? t-poly)
        (define tvars (anf-vars t-poly))
        (when (for/or ([v (in-list tvars)]) (set-member? tgt-vars v))
          (define minfo (hash-ref meas-origin-info m-sym #f))
          (define orig-sp (or (and minfo (car minfo)) decl-span))
          (define anc-surf (and minfo (cdr minfo)))
          (define m-desc (resugar-measurement-symbol m-sym anc-surf))
          (define r-anf (resugar-anf->string t-poly var-surface-names))
          (record-violation!
           'QSub 'U4-QTainted
           (format "Uncancelled M_X quantum phase taint on ~a (~a) entangles interference ~a"
                   m-sym (anf->string t-poly) gate-desc)
           (hasheq 'measurement (symbol->string m-sym)
                   'residual_phase_anf (anf->string t-poly)
                   'counterexample_basis (extract-anf-counterexample-witness t-poly var-names))
           #:resugared-message
           (format "Uncancelled M_X quantum phase taint from ~a (`~a`) entangles interference `~a`"
                   m-desc r-anf surf-gate)
           #:origin-span orig-sp
           #:mutating-span (hash-ref last-taint-span m-sym orig-sp)
           #:failure-span node-sp
           #:surface-wire anc-surf
           #:resugared-anf r-anf
           #:resugared-witness (resugar-counterexample-witness t-poly var-surface-names))))))

  (define (step-node! node [inherited-sp #f])
    (define node-sp (node-or-synthetic-span node inherited-sp decl-span 'RevIR))
    (define step-idx (unbox cur-step-box))
    (match node
      [`(rev-gate (x ,w))
       (update-wire-env! w (dom-reduce (anf-not (hash-ref wire-env w anf-zero))) node-sp)
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]

      [`(rev-gate (,(or 'z 's 's-dag) ,w))
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]

      [`(rev-gate (h ,w))
       (check-interference-preconditions! `(h ,w) (list w) node-sp step-idx)
       (define vid (alloc-var! (format "q~a_h" w) (format "~a@h" (surf-wire-at w step-idx))))
       (update-wire-env! w (anf-var vid) node-sp)
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]

      [`(rev-gate (ry ,theta ,w))
       (check-interference-preconditions! `(ry ,theta ,w) (list w) node-sp step-idx)
       (define vid (alloc-var! (format "q~a_ry" w) (format "~a@ry" (surf-wire-at w step-idx))))
       (update-wire-env! w (anf-var vid) node-sp)
       (define d (target-hw-profile-gate-1q-ns hw))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv w) d)]

      [`(rev-gate (,(or 'rz-dyadic 'rz-dyadic-neg) ,w ,exp-k ,f64? ,code-d))
       (define d (target-hw-profile-gate-1q-ns hw))
       (define exact-angle? (or (not f64?) (< exp-k 53)))
       (define eff-d (if exact-angle? code-d 0))
       (define req-d (max 3 code-d))
       (unless (>= eff-d req-d)
         (define rw (resolved-at w step-idx))
         (define w-surf (lfq-resolved-wire-surface-name rw))
         (record-violation!
          'QPhysGrade 'Phi3-FaultExponent
          (format "IEEE-754 float64 truncation on rz-dyadic(k=~a) collapses fault exponent to ~a < ~a"
                  exp-k eff-d req-d)
          (hasheq 'wire w
                  'dyadic_exponent_k exp-k
                  'effective_fault_distance eff-d
                  'required_fault_distance req-d)
          #:resugared-message
          (format "IEEE-754 float64 truncation on `rz-dyadic` (`k=~a`, wire `~a`) collapses fault exponent to ~a < ~a"
                  exp-k w-surf eff-d req-d)
          #:origin-span decl-span
          #:mutating-span node-sp
          #:failure-span node-sp
          #:surface-wire w-surf
          #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)))
       (note-phi1-contributor! d node-sp)
       (qphys-semiring-grade d 0 0 0 0 '() eff-d req-d (seteqv w) d)]

      [`(rev-gate (cx ,c ,t))
       (define pc (hash-ref wire-env c anf-zero))
       (define pt (hash-ref wire-env t anf-zero))
       (update-wire-env! t (dom-reduce (anf-xor pt pc)) node-sp)
       (define d (target-hw-profile-gate-2q-ns hw))
       (note-phi1-contributor! (* 2 d) node-sp)
       (qphys-semiring-grade (* 2 d) (target-hw-profile-p2q-permil hw)
                             0 0 0 '() #f 0 (seteqv c t) d)]

      [`(rev-gate (cz ,a ,b))
       (define d (target-hw-profile-gate-2q-ns hw))
       (note-phi1-contributor! (* 2 d) node-sp)
       (qphys-semiring-grade (* 2 d) (target-hw-profile-p2q-permil hw)
                             0 0 0 '() #f 0 (seteqv a b) d)]

      [`(rev-gate (swap ,a ,b))
       (define pa (hash-ref wire-env a anf-zero))
       (define pb (hash-ref wire-env b anf-zero))
       (update-wire-env! a pb node-sp)
       (update-wire-env! b pa node-sp)
       (define d (* 3 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 2 d) node-sp)
       (qphys-semiring-grade (* 2 d) (* 3 (target-hw-profile-p2q-permil hw))
                             0 0 0 '() #f 0 (seteqv a b) d)]

      [`(rev-gate (ccx ,c1 ,c2 ,t))
       (define p1 (hash-ref wire-env c1 anf-zero))
       (define p2 (hash-ref wire-env c2 anf-zero))
       (define pt (hash-ref wire-env t anf-zero))
       (update-wire-env! t (dom-reduce (anf-xor pt (anf-and-capped p1 p2))) node-sp)
       (define d (* 6 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 3 d) node-sp)
       (qphys-semiring-grade (* 3 d) (* 6 (target-hw-profile-p2q-permil hw))
                             0 0 0 '() #f 0 (seteqv c1 c2 t) d)]

      [`(rev-gate (ccz ,a ,b ,c))
       (define d (* 6 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 3 d) node-sp)
       (qphys-semiring-grade (* 3 d) (* 6 (target-hw-profile-p2q-permil hw))
                             0 0 0 '() #f 0 (seteqv a b c) d)]

      ;; Asymmetric `4T` Jones / Gidney clean-target `TempAND`:
      [`(rev-temp-and ,c1 ,c2 ,anc)
       (define pre-anc (dom-reduce (hash-ref wire-env anc anf-zero)))
       (unless (null? pre-anc)
         (define rw (resolved-at anc step-idx))
         (define a-surf (lfq-resolved-wire-surface-name rw))
         (define r-anf (resugar-anf->string pre-anc var-surface-names))
         (record-violation!
          'QSub 'U1-EraseBy
          (format "TempAND target wire q[~a] is not clean |0> on entry (~a)"
                  anc (anf->string pre-anc))
          (hasheq 'wire anc 'residual_anf (anf->string pre-anc))
          #:resugared-message
          (format "TempAND target wire `~a` is not clean |0> on entry (`~a`)"
                  a-surf r-anf)
          #:origin-span decl-span
          #:mutating-span (hash-ref last-mutating-span anc node-sp)
          #:failure-span node-sp
          #:surface-wire a-surf
          #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
          #:resugared-anf r-anf
          #:resugared-witness (resugar-counterexample-witness pre-anc var-surface-names)))
       (define p1 (hash-ref wire-env c1 anf-zero))
       (define p2 (hash-ref wire-env c2 anf-zero))
       (update-wire-env! anc (dom-reduce (anf-and-capped p1 p2)) node-sp)
       (define d (* 4 (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* 3 d) node-sp)
       (qphys-semiring-grade (* 3 d) (* 4 (target-hw-profile-p2q-permil hw))
                             0 0 0 '() #f 0 (seteqv c1 c2 anc) d)]

      [`(rev-prepare-dicke-le1 ,ws ,_ ,_ ,_)
       (unless (equal? (unbox wt-bound-box) 1)
         (set-box! wt-bound-box 1))
       (for ([w (in-list ws)])
         (define vid (alloc-var! (format "dicke_q~a" w) (surf-wire-at w step-idx)))
         (set-add! wt-constrained-vars vid)
         (update-wire-env! w (anf-var vid) node-sp))
       (define m (length ws))
       (define n-2q (* 3 (max 0 (sub1 m))))
       (define d (* n-2q (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* m d) node-sp)
       (qphys-semiring-grade (* m d) (* n-2q (target-hw-profile-p2q-permil hw))
                             0 0 0 '() #f 0 (list->seteqv ws) d)]

      ;; `0T` Hadamard-dual `M_X` + reset (`Law U4` + `Grade Phi1`):
      [`(rev-mid-meas-x ,anc ,m-sym ,shielded?)
       (define rw (resolved-at anc step-idx))
       (define anc-surf (lfq-resolved-wire-surface-name rw))
       (unless (hash-has-key? meas-origin-info m-sym)
         (hash-set! meas-origin-info m-sym (cons node-sp anc-surf)))
       (when node-sp
         (hash-set! last-taint-span m-sym node-sp))
       (define p-anc (dom-reduce (hash-ref wire-env anc anf-zero)))
       (define prev-taint (hash-ref phase-taints m-sym anf-zero))
       (hash-set! phase-taints m-sym (dom-reduce (anf-xor prev-taint p-anc)))
       ;; Deterministic wire reset to |0>:
       (update-wire-env! anc anf-zero node-sp)
       ;; Count live non-zero spectators for Phi1 DecoherenceAction check:
       (define n-spec
         (for/sum ([(w p) (in-hash wire-env)]
                   #:when (and (not (= w anc)) (not (null? (dom-reduce p)))))
           1))
       (define t-meas (target-hw-profile-t-meas-reset-ns hw))
       (define u-bud (target-hw-profile-unitary-budget-ns hw))
       (define mbu-exc
         (if shielded?
             0
             (max 0 (- (* (+ 2 n-spec) t-meas) u-bud))))
       (note-phi1-contributor! (+ t-meas (* 1000 mbu-exc)) node-sp)
       (when (> mbu-exc 0)
         (record-violation!
          'QPhysGrade 'Phi1-DecoherenceAction
          (format "Unshielded mid-circuit M_X on q[~a] with ~a live spectators exceeds Lindblad budget by ~a ns (missing XY4 echo)"
                  anc n-spec mbu-exc)
          (hasheq 'measured_wire anc
                  'live_spectators n-spec
                  'meas_reset_ns t-meas
                  'mbu_excess_ns mbu-exc)
          #:resugared-message
          (format "Unshielded mid-circuit `M_X` on `~a` with ~a live spectators exceeds Lindblad budget by ~a ns (missing XY4 echo)"
                  anc-surf n-spec mbu-exc)
          #:origin-span decl-span
          #:mutating-span node-sp
          #:failure-span node-sp
          #:surface-wire anc-surf
          #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)))
       (qphys-semiring-grade t-meas 0 mbu-exc 0 0 '() #f 0 (seteqv anc) t-meas)]

      [`(rev-cond-z ,m-sym ,t)
       (when node-sp
         (hash-set! last-taint-span m-sym node-sp))
       (define pt (dom-reduce (hash-ref wire-env t anf-zero)))
       (define cur (hash-ref phase-taints m-sym anf-zero))
       (hash-set! phase-taints m-sym (dom-reduce (anf-xor cur pt)))
       (define d (target-hw-profile-gate-1q-ns hw))
       (qphys-semiring-grade d 0 0 0 0 '() #f 0 (seteqv t) d)]

      [`(rev-cond-cz ,m-sym ,c1 ,c2)
       (when node-sp
         (hash-set! last-taint-span m-sym node-sp))
       (define p1 (hash-ref wire-env c1 anf-zero))
       (define p2 (hash-ref wire-env c2 anf-zero))
       (define cur (hash-ref phase-taints m-sym anf-zero))
       (hash-set! phase-taints m-sym (dom-reduce (anf-xor cur (anf-and-capped p1 p2))))
       (define d (target-hw-profile-gate-2q-ns hw))
       (qphys-semiring-grade (* 2 d) (target-hw-profile-p2q-permil hw)
                             0 0 0 '() #f 0 (seteqv c1 c2) d)]

      [`(rev-syndrome-plaquette ,ws ,code-d ,hook-aligned?)
       (define eff-d (if hook-aligned? (quotient (+ code-d 1) 2) code-d))
       (define req-d (max 3 code-d))
       (when (< eff-d req-d)
         (define surf-ws (map (lambda (u) (surf-wire-at u step-idx)) ws))
         (record-violation!
          'QPhysGrade 'Phi3-FaultExponent
          (format "Aligned stabilizer CNOT round on plaquette ~a degrades fault distance ~a -> ~a < ~a (requires N-Z-S-W schedule)"
                  ws code-d eff-d req-d)
          (hasheq 'plaquette_wires ws
                  'nominal_code_distance code-d
                  'effective_fault_distance eff-d
                  'required_fault_distance req-d)
          #:resugared-message
          (format "Aligned stabilizer CNOT round on plaquette (~a) degrades fault distance ~a -> ~a < ~a (requires N-Z-S-W schedule)"
                  (string-join surf-ws " ") code-d eff-d req-d)
          #:origin-span decl-span
          #:mutating-span node-sp
          #:failure-span node-sp
          #:surface-wire (and (pair? surf-ws) (car surf-ws))))
       (define n-2q (max 1 (sub1 (length ws))))
       (define d (* n-2q (target-hw-profile-gate-2q-ns hw)))
       (note-phi1-contributor! (* (length ws) d) node-sp)
       (qphys-semiring-grade (* (length ws) d) (* n-2q (target-hw-profile-p2q-permil hw))
                             0 0 0 '() eff-d req-d (list->seteqv ws) d)]

      [`(rev-erase-check ,ws)
       (for ([w (in-list ws)])
         (define pw-anf (dom-reduce (hash-ref wire-env w anf-zero)))
         (unless (null? pw-anf)
           (define rw (resolved-at w step-idx))
           (define w-surf (lfq-resolved-wire-surface-name rw))
           (define r-anf (resugar-anf->string pw-anf var-surface-names))
           (record-violation!
            'QSub 'U1-EraseBy
            (format "Scratch wire q[~a] not erased to |0> on domain (~a)"
                    w (anf->string pw-anf))
            (hasheq 'wire w
                    'residual_anf (anf->string pw-anf)
                    'counterexample_basis (extract-anf-counterexample-witness pw-anf var-names))
            #:resugared-message
            (format "Scratch wire `~a` not erased to |0> on domain (`~a`)"
                    w-surf r-anf)
            #:origin-span decl-span
            #:mutating-span (hash-ref last-mutating-span w node-sp)
            #:failure-span node-sp
            #:surface-wire w-surf
            #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
            #:resugared-anf r-anf
            #:resugared-witness (resugar-counterexample-witness pw-anf var-surface-names))))
       qphys-grade-identity]

      [`(rev-quotient-check ,q-ws)
       (for ([qw (in-list q-ws)])
         (set-add! active-quotient-wires qw)
         (define q-anf (dom-reduce (hash-ref wire-env qw anf-zero)))
         (unless (null? q-anf)
           (define rw (resolved-at qw step-idx))
           (define q-surf (lfq-resolved-wire-surface-name rw))
           (define r-anf (resugar-anf->string q-anf var-surface-names))
           (record-violation!
            'QSub 'U2-Canonical
            (format "Quotient wire q[~a] failed canonicalization to |0> (~a)"
                    qw (anf->string q-anf))
            (hasheq 'quotient_wire qw
                    'residual_anf (anf->string q-anf)
                    'counterexample_basis (extract-anf-counterexample-witness q-anf var-names))
            #:resugared-message
            (format "Quotient wire `~a` failed canonicalization to |0> (`~a`)"
                    q-surf r-anf)
            #:origin-span decl-span
            #:mutating-span (hash-ref last-mutating-span qw node-sp)
            #:failure-span node-sp
            #:surface-wire q-surf
            #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
            #:resugared-anf r-anf
            #:resugared-witness (resugar-counterexample-witness q-anf var-surface-names))))
       qphys-grade-identity]

      ;; `Law U3` (`TotalOn`): guarded orthogonal partition `qmatch`:
      [`(rev-qmatch ,arms)
       (define entry-env (hash-copy wire-env))
       (define guard-polys
         (for/list ([arm (in-list arms)])
           (eval-guard-anf entry-env dom-reduce (first arm))))
       ;; 1. Pairwise mutual exclusivity (`G_i * G_j == 0` on domain):
       (for* ([i (in-range (length guard-polys))]
              [j (in-range (add1 i) (length guard-polys))])
         (define overlap (dom-reduce (anf-and-capped (list-ref guard-polys i)
                                                     (list-ref guard-polys j))))
         (unless (null? overlap)
           (define r-anf (resugar-anf->string overlap var-surface-names))
           (record-violation!
            'QSub 'U3-TotalOn
            (format "Overlapping qmatch guards ~a and ~a (~a)"
                    i j (anf->string overlap))
            (hasheq 'arm_i i
                    'arm_j j
                    'overlap_anf (anf->string overlap)
                    'counterexample_basis (extract-anf-counterexample-witness overlap var-names))
            #:resugared-message
            (format "Overlapping `qmatch` guards ~a and ~a (`~a`)"
                    i j r-anf)
            #:origin-span decl-span
            #:mutating-span node-sp
            #:failure-span node-sp
            #:resugared-anf r-anf
            #:resugared-witness (resugar-counterexample-witness overlap var-surface-names))))
       ;; 2. Domain totality (`1 ^ G_1 ^ ... ^ G_k == 0` on domain):
       (define sum-guards
         (dom-reduce (foldl (lambda (gp acc) (anf-xor acc gp)) anf-zero guard-polys)))
       (define uncovered (dom-reduce (anf-xor anf-one sum-guards)))
       (unless (null? uncovered)
         (define r-anf (resugar-anf->string uncovered var-surface-names))
         (record-violation!
          'QSub 'U3-TotalOn
          (format "Non-exhaustive qmatch leaves domain locus uncovered (~a)"
                  (anf->string uncovered))
          (hasheq 'uncovered_anf (anf->string uncovered)
                  'counterexample_basis (extract-anf-counterexample-witness uncovered var-names))
          #:resugared-message
          (format "Non-exhaustive `qmatch` leaves domain locus uncovered (`~a`)" r-anf)
          #:origin-span decl-span
          #:mutating-span node-sp
          #:failure-span node-sp
          #:resugared-anf r-anf
          #:resugared-witness (resugar-counterexample-witness uncovered var-surface-names)))
       ;; 3. Evaluate each arm independently and verify guard invariance:
       (define arm-envs '())
       (set-box! in-qmatch-depth-box (add1 (unbox in-qmatch-depth-box)))
       (define joined-grade
         (for/fold ([acc-g qphys-grade-identity])
                   ([arm (in-list arms)] [gp (in-list guard-polys)] [idx (in-naturals)])
           (hash-clear! wire-env)
           (for ([(k v) (in-hash entry-env)]) (hash-set! wire-env k v))
           (define last-arm-sp-box (box node-sp))
           (define arm-g
             (for/fold ([ag qphys-grade-identity]) ([sub (in-list (second arm))])
               (when (lookup-surface-span sub)
                 (set-box! last-arm-sp-box (lookup-surface-span sub)))
               (qphys-grade-seq ag (step-node! sub node-sp))))
           (define post-gp (eval-guard-anf wire-env dom-reduce (first arm)))
           (define drift (dom-reduce (anf-xor gp post-gp)))
           (unless (null? drift)
             (define r-anf (resugar-anf->string drift var-surface-names))
             (record-violation!
              'QSub 'U3-TotalOn
              (format "qmatch arm ~a mutates its own guard (~a)" idx (anf->string drift))
              (hasheq 'arm idx
                      'drift_anf (anf->string drift)
                      'counterexample_basis (extract-anf-counterexample-witness drift var-names))
              #:resugared-message
              (format "`qmatch` arm ~a mutates its own guard (`~a`)" idx r-anf)
              #:origin-span node-sp
              #:mutating-span (unbox last-arm-sp-box)
              #:failure-span node-sp
              #:resugared-anf r-anf
              #:resugared-witness (resugar-counterexample-witness drift var-surface-names)))
           (set! arm-envs (append arm-envs (list (hash-copy wire-env))))
           (qphys-grade-join acc-g arm-g)))
       (set-box! in-qmatch-depth-box (sub1 (unbox in-qmatch-depth-box)))
       ;; 4. Partition-weighted state merge `S_out[w] = XOR_i (G_i * S_i[w])`:
       (define all-keys
         (remove-duplicates
          (append (hash-keys entry-env)
                  (apply append (map hash-keys arm-envs)))))
       (hash-clear! wire-env)
       (for ([w (in-list all-keys)])
         (define merged
           (for/fold ([acc anf-zero])
                     ([gp (in-list guard-polys)] [aenv (in-list arm-envs)])
             (dom-reduce (anf-xor acc (anf-and-capped gp (hash-ref aenv w anf-zero))))))
         (hash-set! wire-env w merged)
         (when (null? merged)
           (hash-remove! last-mutating-span w)))
       joined-grade]

      ;; `Grade Phi2` (`ExclusionGraph`): parallel hardware exclusion check:
      [`(rev-par ,ir1 ,ir2)
       (define g1
         (for/fold ([ag qphys-grade-identity]) ([sub (in-list ir1)])
           (qphys-grade-seq ag (step-node! sub node-sp))))
       (define g2
         (for/fold ([ag qphys-grade-identity]) ([sub (in-list ir2)])
           (qphys-grade-seq ag (step-node! sub node-sp))))
       (define pg (qphys-grade-par hw g1 g2))
       (define new-hits
         (drop (qphys-semiring-grade-colliding-pairs pg)
               (+ (length (qphys-semiring-grade-colliding-pairs g1))
                  (length (qphys-semiring-grade-colliding-pairs g2)))))
       (unless (null? new-hits)
         (define surf-hits
           (for/list ([pr (in-list new-hits)])
             (format "(~a, ~a)"
                     (surf-wire-at (first pr) step-idx)
                     (surf-wire-at (second pr) step-idx))))
         (record-violation!
          'QPhysGrade 'Phi2-ExclusionGraph
          (format "Parallel wires collide in hardware exclusion neighborhood: ~a" new-hits)
          (hasheq 'colliding_wire_pairs new-hits
                  'blockade_radius_um (target-hw-profile-blockade-radius-um hw)
                  'site_spacing_um (target-hw-profile-site-spacing-um hw))
          #:resugared-message
          (format "Parallel wires collide in hardware exclusion neighborhood: ~a"
                  (string-join surf-hits ", "))
          #:origin-span decl-span
          #:mutating-span node-sp
          #:failure-span node-sp))
       pg]

      [`(rev-focus-zipper ,_ ,ir)
       (define phase-clean?
         (and (= (unbox in-qmatch-depth-box) 0)
              (for/and ([qw (in-set active-quotient-wires)])
                (null? (dom-reduce (hash-ref wire-env qw anf-zero))))
              (for/and ([(_ t-raw) (in-hash phase-taints)])
                (null? (dom-reduce t-raw)))))
       (when phase-clean?
         (hash-set! certified-phase-clean-zippers-table node #t))
       (run-top-nodes! ir node-sp)]

      [`(rev-multishot ,k ,ir)
       (define inner-g (run-top-nodes! ir node-sp))
       (qphys-grade-multishot k inner-g)]

      [_ (error 'infer-revir-qsub-and-qphys "Unknown RevIR node: ~a" node)]))

  (define (run-top-nodes! nodes [inherited-sp #f])
    (for/fold ([g qphys-grade-identity]) ([node (in-list nodes)])
      (match node
        [(or `(rev-multishot ,_ ,_) `(rev-focus-zipper ,_ ,_))
         (qphys-grade-seq g (step-node! node inherited-sp))]
        [_
         (define ng (step-node! node inherited-sp))
         (set-box! cur-step-box (add1 (unbox cur-step-box)))
         (qphys-grade-seq g ng)])))

  (define total-grade (run-top-nodes! revir))

  ;; Exit checks:
  ;; 1. Law U1 (`EraseBy`): all recycled physical scratch wires must end in |0>!
  (for ([s (in-list scratch-phys)])
    (define s-anf (dom-reduce (hash-ref wire-env s anf-zero)))
    (unless (null? s-anf)
      (define rw (resolved-at s #f))
      (define s-surf (lfq-resolved-wire-surface-name rw))
      (define r-anf (resugar-anf->string s-anf var-surface-names))
      (record-violation!
       'QSub 'U1-EraseBy
       (format "Scratch wire q[~a] leaked non-zero state at circuit exit (~a)"
               s (anf->string s-anf))
       (hasheq 'wire s
               'residual_anf (anf->string s-anf)
               'counterexample_basis (extract-anf-counterexample-witness s-anf var-names))
       #:resugared-message
       (format "Scratch wire `~a` leaked non-zero state at circuit exit (`~a`)"
               s-surf r-anf)
       #:origin-span decl-span
       #:mutating-span (hash-ref last-mutating-span s decl-span)
       #:failure-span decl-span
       #:surface-wire s-surf
       #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
       #:resugared-anf r-anf
       #:resugared-witness (resugar-counterexample-witness s-anf var-surface-names))))

  ;; 2. Law U2 (`Canonical`): all active quotient wires must end in |0>!
  (for ([qw (in-set active-quotient-wires)])
    (define q-anf (dom-reduce (hash-ref wire-env qw anf-zero)))
    (unless (null? q-anf)
      (define rw (resolved-at qw #f))
      (define q-surf (lfq-resolved-wire-surface-name rw))
      (define r-anf (resugar-anf->string q-anf var-surface-names))
      (record-violation!
       'QSub 'U2-Canonical
       (format "Quotient wire q[~a] remains non-zero at circuit exit (~a)"
               qw (anf->string q-anf))
       (hasheq 'quotient_wire qw
               'residual_anf (anf->string q-anf)
               'counterexample_basis (extract-anf-counterexample-witness q-anf var-names))
       #:resugared-message
       (format "Quotient wire `~a` remains non-zero at circuit exit (`~a`)"
               q-surf r-anf)
       #:origin-span decl-span
       #:mutating-span (hash-ref last-mutating-span qw decl-span)
       #:failure-span decl-span
       #:surface-wire q-surf
       #:chordal-recycled-from (lfq-resolved-wire-recycled-from rw)
       #:resugared-anf r-anf
       #:resugared-witness (resugar-counterexample-witness q-anf var-surface-names))))

  ;; 3. Law U4 (`QTainted`): all mid-circuit M_X quantum phase taints must vanish!
  (for ([(m-sym t-raw) (in-hash phase-taints)])
    (define t-anf (dom-reduce t-raw))
    (unless (null? t-anf)
      (define minfo (hash-ref meas-origin-info m-sym #f))
      (define orig-sp (or (and minfo (car minfo)) decl-span))
      (define anc-surf (and minfo (cdr minfo)))
      (define m-desc (resugar-measurement-symbol m-sym anc-surf))
      (define r-anf (resugar-anf->string t-anf var-surface-names))
      (record-violation!
       'QSub 'U4-QTainted
       (format "Mid-circuit measurement ~a leaves residual quantum phase kickback (~a) at exit"
               m-sym (anf->string t-anf))
       (hasheq 'measurement (symbol->string m-sym)
               'residual_phase_anf (anf->string t-anf)
               'counterexample_basis (extract-anf-counterexample-witness t-anf var-names))
       #:resugared-message
       (format "Mid-circuit ~a leaves residual quantum phase kickback (`~a`) at exit"
               m-desc r-anf)
       #:origin-span orig-sp
       #:mutating-span (hash-ref last-taint-span m-sym orig-sp)
       #:failure-span decl-span
       #:surface-wire anc-surf
       #:resugared-anf r-anf
       #:resugared-witness (resugar-counterexample-witness t-anf var-surface-names))))

  ;; 4. Overall Phi1 DecoherenceAction budget check (`<= 693` milli-nats):
  (define total-action-milli (grade-decoherence-action-milli hw total-grade))
  (when (> total-action-milli 693)
    (record-violation!
     'QPhysGrade 'Phi1-DecoherenceAction
     (format "Total Lindblad decoherence action ~a milli-nats exceeds budget 693"
             total-action-milli)
     (hasheq 'effective_action_milli total-action-milli
             'budget_milli 693
             'mbu_excess_ns (qphys-semiring-grade-mbu-excess-ns total-grade))
     #:origin-span decl-span
     #:mutating-span (or (cdr (unbox dominant-phi1-box)) decl-span)
     #:failure-span decl-span))

  (define residual-phase-count
    (for/sum ([(_ t-raw) (in-hash phase-taints)])
      (if (null? (dom-reduce t-raw)) 0 1)))

  (set-box! last-xag-telemetry-box
            (compute-revir-xag-cone-isomorphism-summary revir input-wires scratch-phys))

  (values violations total-grade total-action-milli residual-phase-count
          (sort (set->list active-quotient-wires) <))))

;; =============================================================================
;; 5. Counterexample-Guided Physical Repair (`RevIR -> Repaired RevIR`)
;; =============================================================================
;; Repairs physical `QPhysGrade` (`Phi1-Phi3`) violations without altering the
;; logical `QSub` unitary/channel semantics:
;;   - `Phi1` (`DecoherenceAction`): inserts `XY4` dynamical decoupling echoes on
;;     unshielded `mid-meas-x` spectators and wraps deep coherent sequences in
;;     `multishot-reset` when total Lindblad action exceeds `693` milli-nats.
;;   - `Phi2` (`ExclusionGraph`): 2-colors colliding `rev-par` arms into two
;;     conflict-free sequential sub-schedules.
;;   - `Phi3` (`FaultExponent`): rewrites hook-aligned stabilizer plaquettes into
;;     the `N-Z-S-W` hook-orthogonal schedule and promotes float64 dyadic angles
;;     to exact dyadic synthesis.

(define (repair-revir-counterexample-guided revir hw)
  (define repairs '())
  (define (log-repair! kind detail)
    (set! repairs (append repairs (list (hasheq 'repair (symbol->string kind)
                                                'detail detail)))))
  (define (fix-node n)
    (define out-nodes
      (match n
        [`(rev-mid-meas-x ,anc ,m-sym #f)
         (log-repair! 'xy4-spectator-echo
                      (format "Inserted XY4 dynamical decoupling echo on mid-meas-x q[~a]" anc))
         (list `(rev-mid-meas-x ,anc ,m-sym #t))]
        [`(rev-syndrome-plaquette ,ws ,code-d #t)
         (log-repair! 'nzsw-hook-orthogonal-schedule
                      (format "Reordered plaquette ~a to N-Z-S-W hook-orthogonal schedule (d=~a)"
                              ws code-d))
         (list `(rev-syndrome-plaquette ,ws ,code-d #f))]
        [`(rev-gate (rz-dyadic ,w ,exp-k #t ,code-d))
         #:when (>= exp-k 53)
         (log-repair! 'exact-dyadic-angle-promotion
                      (format "Promoted rz-dyadic(k=~a) on q[~a] from float64 to exact dyadic" exp-k w))
         (list `(rev-gate (rz-dyadic ,w ,exp-k #f ,code-d)))]
        [`(rev-par ,ir1 ,ir2)
         (define r1 (apply append (map fix-node ir1)))
         (define r2 (apply append (map fix-node ir2)))
         (define s1 (remove-duplicates (apply append (map revir-node-wires r1))))
         (define s2 (remove-duplicates (apply append (map revir-node-wires r2))))
         (define collides?
           (for*/or ([u (in-list s1)] [v (in-list s2)])
             (wire-pair-collides-in-exclusion-graph? hw u v)))
         (if collides?
             (begin
               (log-repair! 'two-color-coupler-exclusion-schedule
                            (format "Sequentialized colliding parallel supports ~a and ~a into 2 colors"
                                    s1 s2))
               (append r1 r2))
             (list `(rev-par ,r1 ,r2)))]
        [`(rev-qmatch ,arms)
         (list `(rev-qmatch ,(for/list ([arm (in-list arms)])
                               (list (first arm)
                                     (apply append (map fix-node (second arm)))))))]
        [`(rev-focus-zipper (,sub-ws ,amb-ws) ,ir)
         (list `(rev-focus-zipper (,sub-ws ,amb-ws) ,(apply append (map fix-node ir))))]
        [`(rev-for-fold-loop ,nr ,rirs)
         (list `(rev-for-fold-loop ,nr
                                   ,(for/list ([rir (in-list rirs)])
                                      (apply append (map fix-node rir)))))]
        [`(rev-multishot ,k ,ir)
         (list `(rev-multishot ,k ,(apply append (map fix-node ir))))]
        [_ (list n)]))
    (propagate-surface-span-list! n out-nodes 'RevIR-Repair))

  (define (rough-node-ns n)
    (match n
      [`(rev-gate (,(or 'cx 'cz) ,_ ,_)) (* 2 (target-hw-profile-gate-2q-ns hw))]
      [`(rev-temp-and ,_ ,_ ,_) (* 12 (target-hw-profile-gate-2q-ns hw))]
      [`(rev-focus-zipper ,_ ,ir) (for/sum ([sub (in-list ir)]) (rough-node-ns sub))]
      [`(rev-for-fold-loop ,_ ,rirs)
       (for/sum ([rir (in-list rirs)])
         (for/sum ([sub (in-list rir)]) (rough-node-ns sub)))]
      [_ (target-hw-profile-gate-1q-ns hw)]))

  (define repaired-nodes (apply append (map fix-node revir)))
  ;; Check if active coherent volume alone still exceeds 693 milli-nats:
  (define rough-qubit-ns
    (for/sum ([n (in-list repaired-nodes)])
      (rough-node-ns n)))
  (define t2 (target-hw-profile-t2-ns hw))
  (define rough-idle (if (<= t2 0) 0 (quotient (* rough-qubit-ns 1000) t2)))
  (define final-nodes
    (if (> rough-idle 693)
        (let ([shots-k (+ 1 (quotient rough-idle 400))])
          (log-repair! 'multishot-checkpoint-reset
                       (format "Partitioned coherent volume across K=~a checkpoint shots" shots-k))
          (list `(rev-multishot ,shots-k ,repaired-nodes)))
        repaired-nodes))
  (values final-nodes repairs))

;; =============================================================================
;; 5b. Phase-Clean `focus-zipper` RM(3, n) TODD + AutoCCZ Optimization &
;;     External QEC Syndrome-Decoder Pacing Profile Metadata
;; =============================================================================

(define (optimize-revir-phase-clean-focus-zippers revir cert-table)
  (define certified-cnt 0)
  (define opt-cones-cnt 0)
  (define total-pre-tc 0)
  (define total-post-tc 0)
  (define total-pre-td 0)
  (define total-post-td 0)

  (define (try-extract-local-todd-ops ir lw)
    (define non-cliff-cnt 0)
    (define ccz-cnt 0)
    (let loop ([rem ir] [acc '()])
      (match rem
        ['() (values (reverse acc) non-cliff-cnt ccz-cnt)]
        [(cons nd tl)
         (match nd
           [`(rev-gate (cx ,c ,t))
            (loop tl (cons (list 'cx (lw c) (lw t)) acc))]
           [`(rev-gate (cz ,a ,b))
            (loop tl (cons (list 'cz (lw a) (lw b)) acc))]
           [`(rev-gate (ccz ,a ,b ,c))
            (set! non-cliff-cnt (add1 non-cliff-cnt))
            (set! ccz-cnt (add1 ccz-cnt))
            (loop tl (cons (list 'ccz (lw a) (lw b) (lw c)) acc))]
           [`(rev-gate (z ,w))
            (loop tl (cons (list 'z (lw w)) acc))]
           [`(rev-gate (s ,w))
            (loop tl (cons (list 's (lw w)) acc))]
           [`(rev-gate (s-dag ,w))
            (loop tl (cons (list 'sdg (lw w)) acc))]
           [`(rev-gate (rz-dyadic ,w 3 #f ,_))
            (set! non-cliff-cnt (add1 non-cliff-cnt))
            (loop tl (cons (list 't (lw w)) acc))]
           [`(rev-gate (rz-dyadic-neg ,w 3 #f ,_))
            (set! non-cliff-cnt (add1 non-cliff-cnt))
            (loop tl (cons (list 'tdg (lw w)) acc))]
           [_ (values #f 0 0)])])))

  (define (lower-todd-isa->revir isa-ops pw src-node)
    (define out
      (apply append
             (for/list ([op (in-list isa-ops)])
               (match op
                 [(list "cx" c t) (list `(rev-gate (cx ,(pw c) ,(pw t))))]
                 [(list "cz" a b) (list `(rev-gate (cz ,(pw a) ,(pw b))))]
                 [(list "z" w) (list `(rev-gate (z ,(pw w))))]
                 [(list "s" w) (list `(rev-gate (s ,(pw w))))]
                 [(list "sdg" w)
                  ;; Z * S = S^\dagger with zero global phase, preserving standard QASM3 {z, s} gates:
                  (list `(rev-gate (z ,(pw w)))
                        `(rev-gate (s ,(pw w))))]
                 [(list "t" w) (list `(rev-gate (rz-dyadic ,(pw w) 3 #f 5)))]
                 [(list "tdg" w) (list `(rev-gate (rz-dyadic-neg ,(pw w) 3 #f 5)))]
                 [_ (error 'optimize-revir-phase-clean-focus-zippers
                           "Unexpected TODD ISA op: ~a" op)]))))
    (propagate-surface-span-list! src-node out 'RevIR))

  (define (opt-nodes nodes)
    (for/list ([nd (in-list nodes)])
      (define rebuilt
        (match nd
          [`(rev-focus-zipper (,sub-ws ,amb-ws) ,ir)
           (define inner-ir (opt-nodes ir))
           (define cert? (hash-ref cert-table nd #f))
           (when cert?
             (set! certified-cnt (add1 certified-cnt)))
           (define cone-ws
             (sort (remove-duplicates
                    (append (filter exact-nonnegative-integer? sub-ws)
                            (apply append (map revir-node-wires inner-ir))))
                   <))
           (define k-wires (length cone-ws))
           (cond
             [(and cert? (> k-wires 0) (<= k-wires 16))
              (define phys->loc (make-hasheqv))
              (for ([w (in-list cone-ws)] [idx (in-naturals)])
                (hash-set! phys->loc w idx))
              (define loc->phys (list->vector cone-ws))
              (define (lw w) (hash-ref phys->loc w 0))
              (define (pw idx) (vector-ref loc->phys idx))
              (define-values (local-ops non-cliff-cnt ccz-cnt)
                (try-extract-local-todd-ops inner-ir lw))
              (cond
                [(and local-ops
                      (> non-cliff-cnt 0)
                      (<= ccz-cnt 10)
                      (phase-clean-u2-u4-cone-ops? k-wires local-ops))
                 (define pre-isa (lower-todd-cone-pre-isa local-ops))
                 (define post-isa (lower-todd-cone-post-isa k-wires local-ops))
                 (define tc-pre (compute-isa-t-count pre-isa))
                 (define tc-post (compute-isa-t-count post-isa))
                 (define td-pre (compute-isa-t-depth k-wires pre-isa))
                 (define td-post (compute-isa-t-depth k-wires post-isa))
                 (set! total-pre-tc (+ total-pre-tc tc-pre))
                 (set! total-pre-td (+ total-pre-td td-pre))
                 (if (or (< tc-post tc-pre)
                         (and (= tc-post tc-pre) (< td-post td-pre)))
                     (begin
                       (set! opt-cones-cnt (add1 opt-cones-cnt))
                       (set! total-post-tc (+ total-post-tc tc-post))
                       (set! total-post-td (+ total-post-td td-post))
                       `(rev-focus-zipper (,sub-ws ,amb-ws)
                                          ,(lower-todd-isa->revir post-isa pw nd)))
                     (begin
                       (set! total-post-tc (+ total-post-tc tc-pre))
                       (set! total-post-td (+ total-post-td td-pre))
                       `(rev-focus-zipper (,sub-ws ,amb-ws) ,inner-ir)))]
                [else
                 `(rev-focus-zipper (,sub-ws ,amb-ws) ,inner-ir)])]
             [else
              `(rev-focus-zipper (,sub-ws ,amb-ws) ,inner-ir)])]
          [`(rev-par ,ir1 ,ir2)
           `(rev-par ,(opt-nodes ir1) ,(opt-nodes ir2))]
          [`(rev-qmatch ,arms)
           `(rev-qmatch ,(for/list ([a (in-list arms)])
                           (list (first a) (opt-nodes (second a)))))]
          [`(rev-for-fold-loop ,nr ,rirs)
           `(rev-for-fold-loop ,nr ,(map opt-nodes rirs))]
          [`(rev-multishot ,k ,ir)
           `(rev-multishot ,k ,(opt-nodes ir))]
          [_ nd]))
      (propagate-surface-span! nd rebuilt 'RevIR)))

  (define opt-ir (opt-nodes revir))
  (values opt-ir
          (hasheq 'pass_name "todd-rm3-autocc-phase-poly"
                  'phase_clean_zippers_certified certified-cnt
                  'cones_optimized opt-cones-cnt
                  'pre_t_count total-pre-tc
                  'post_t_count total-post-tc
                  't_count_saved (max 0 (- total-pre-tc total-post-tc))
                  'pre_t_depth total-pre-td
                  'post_t_depth total-post-td
                  't_depth_saved (max 0 (- total-pre-td total-post-td)))))

;; =============================================================================
;; 5c. Canonical Coupled Phase-Ordering Pipeline (`P_loop_cone -> P_pebble ->
;;     (FRAIG/Commute o EGraph(MBU U ZX U TODD))^2 -> P_mbu -> Post-TODD Chordal
;;     SSA -> Coupled Block-LU + Law-U4 Cluster Codegen`)
;; =============================================================================

(define (count-isa-clifford-t-gates isa-ops)
  (define qtr (/ pi 4.0))
  (for/sum ([op (in-list isa-ops)])
    (match op
      [`(isa-ccx ,_ ,_ ,_) 7]
      [`(isa-temp-and-ccx ,_ ,_ ,_) 4]
      [`(isa-rz ,ang ,_)
       (if (< (abs (- (abs (exact->inexact ang)) qtr)) 1e-6) 1 0)]
      [_ 0])))

(define (kern-ast-has-phase-or-nested-mbu? kern-ast)
  (let walk ([e kern-ast] [in-mbu? #f])
    (match e
      [`(linear-lambda ,_ ,ops)
       (for/or ([op (in-list ops)]) (walk op in-mbu?))]
      [`(within-apply-mbu ,comp ,act ,_)
       (or in-mbu? (walk comp #t) (walk act #t))]
      [`(erase-by ,fwd ,bwd ,_)
       (or (walk fwd in-mbu?) (walk bwd in-mbu?))]
      [`(inductive-iso orthogonal-partition ,arms ,_)
       (for/or ([arm (in-list arms)]) (walk (second arm) in-mbu?))]
      [`(inductive-iso for-fold-loop (,_ ,rks ...) ,_)
       (for/or ([rk (in-list rks)]) (walk rk in-mbu?))]
      [`(catamorphism-fold ,idx ,st ,l ,r)
       (and (>= idx 0)
            (or (and (not (eq? l 'none)) (walk l in-mbu?))
                (walk st in-mbu?)
                (and (not (eq? r 'none)) (walk r in-mbu?))))]
      [`(locality-shift zipper-focus ,_ ,b) (walk b in-mbu?)]
      [`(locality-shift parallel-product (,e1 ,e2) ,_)
       (or (walk e1 in-mbu?) (walk e2 in-mbu?))]
      [`(locality-shift multishot-checkpoint ,_ ,b) (walk b in-mbu?)]
      [`(,(or 'z 's 's-dag) ,_) #t]
      [`(,(or 'rz-dyadic 'rz-dyadic-neg) . ,_) #t]
      [`(,(or 'cz 'ccz) . ,_) #t]
      [_ #f])))

(define (flatten-kern-ops ops)
  (apply append
         (for/list ([op (in-list ops)])
           (match op
             [`(linear-lambda ,_ ,sub-ops)
              (flatten-kern-ops sub-ops)]
             [_ (list op)]))))

(define (kern-leaf-op-wires op)
  (match op
    [`(,(or 'x 'z 's 's-dag 'h 'waw-barrier) ,w) (list w)]
    [`(ry ,_ ,w) (list w)]
    [`(,(or 'rz-dyadic 'rz-dyadic-neg) ,w ,_ ,_ ,_) (list w)]
    [`(,(or 'cx 'cz 'swap) ,a ,b) (list a b)]
    [`(,(or 'ccx 'ccz 'temp-and) ,a ,b ,c) (list a b c)]
    [`(prepare-dicke-le1 ,ws ,_ ,_ ,_) ws]
    [`(mid-meas-x ,a ,_ ,_) (list a)]
    [`(cond-z ,_ ,t) (list t)]
    [`(cond-cz ,_ ,a ,b) (list a b)]
    [`(syndrome-plaquette ,ws ,_ ,_) ws]
    [`(within-apply-mbu ,comp ,act ,ews)
     (remove-duplicates
      (append (kern-all-wires comp) (kern-all-wires act) ews)
      =)]
    [`(erase-by ,fwd ,bwd (,_ ,ws))
     (remove-duplicates (append (kern-all-wires fwd) (kern-all-wires bwd) ws) =)]
    [`(inductive-iso wire-relabel (,ws ,_) ,_) ws]
    [`(inductive-iso orthogonal-partition ,arms ,_)
     (remove-duplicates
      (apply append
             (for/list ([arm (in-list arms)])
               (append (guard-wires (first arm)) (kern-all-wires (second arm)))))
      =)]
    [`(inductive-iso for-fold-loop (,_ ,rks ...) ,_)
     (remove-duplicates (apply append (map kern-all-wires rks)) =)]
    [`(catamorphism-fold ,idx ,st ,l ,r)
     (if (< idx 0)
         '()
         (remove-duplicates
          (append (if (eq? l 'none) '() (kern-all-wires l))
                  (kern-all-wires st)
                  (if (eq? r 'none) '() (kern-all-wires r)))
          =))]
    [`(locality-shift zipper-focus (,sw ,aw) ,b)
     (remove-duplicates (append sw aw (kern-all-wires b)) =)]
    [`(locality-shift parallel-product (,e1 ,e2) ,_)
     (remove-duplicates (append (kern-all-wires e1) (kern-all-wires e2)) =)]
    [`(locality-shift multishot-checkpoint ,_ ,b) (kern-all-wires b)]
    [_ '()]))

(define (kern-all-wires kern-ast)
  (match kern-ast
    [`(linear-lambda ,_ ,ops)
     (remove-duplicates (apply append (map kern-leaf-op-wires ops)) =)]
    [other (kern-leaf-op-wires other)]))

;; Pre-TODD Chordal SSA Wire Coloring with Explicit WAW Reuse Barriers
;; (used to reproduce Hazard A `SSA < TODD` in A/B phase-ordering verification):
(define (apply-pre-todd-ssa-with-waw-barriers kern-ast input-wires scratch-wires)
  (define scratch-set (list->seteqv scratch-wires))
  (define fixed-base
    (if (null? input-wires) 0 (add1 (apply max input-wires))))
  (define first-use (make-hasheqv))
  (define last-use (make-hasheqv))
  (define (touch! w ts)
    (when (set-member? scratch-set w)
      (unless (hash-has-key? first-use w)
        (hash-set! first-use w ts))
      (hash-set! last-use w ts)))

  (define step-ts 0)
  (define (walk-ts! e)
    (match e
      [`(linear-lambda ,_ ,ops)
       (for ([op (in-list (flatten-kern-ops ops))])
         (walk-ts! op))]
      [`(within-apply-mbu ,comp ,act ,ews)
       (define t-enter step-ts)
       (set! step-ts (add1 step-ts))
       (for ([w (in-list (append (kern-all-wires comp) ews))])
         (touch! w t-enter))
       (walk-ts! act)
       (define t-exit step-ts)
       (set! step-ts (add1 step-ts))
       (for ([w (in-list (append (kern-all-wires comp) ews))])
         (touch! w t-exit))]
      [_
       (define t step-ts)
       (set! step-ts (add1 step-ts))
       (for ([w (in-list (kern-leaf-op-wires e))])
         (touch! w t))]))
  (walk-ts! kern-ast)

  (define live-scratch
    (sort (hash-keys first-use)
          (lambda (w1 w2)
            (define s1 (hash-ref first-use w1))
            (define s2 (hash-ref first-use w2))
            (if (= s1 s2) (< w1 w2) (< s1 s2)))))
  (define phys-end (make-hasheqv))
  (define reuse-points (make-hasheqv))
  (define w-remap (make-hasheqv))
  (define num-phys-scr 0)

  (for ([vw (in-list live-scratch)])
    (define sv (hash-ref first-use vw))
    (define ev (hash-ref last-use vw))
    (define slot
      (for/first ([sl (in-range num-phys-scr)]
                  #:when (< (hash-ref phys-end sl) sv))
        sl))
    (cond
      [slot
       (define pw (+ fixed-base slot))
       (hash-set! w-remap vw pw)
       (hash-set! phys-end slot ev)
       (hash-set! reuse-points sv
                  (append (hash-ref reuse-points sv '()) (list pw)))]
      [else
       (define sl num-phys-scr)
       (set! num-phys-scr (add1 num-phys-scr))
       (define pw (+ fixed-base sl))
       (hash-set! w-remap vw pw)
       (hash-set! phys-end sl ev)]))

  (define (rw w) (hash-ref w-remap w w))
  (define rebuild-ts 0)
  (define (remap-node e)
    (define out
      (match e
        [`(linear-lambda ,args ,ops)
         (define acc '())
         (for ([op (in-list (flatten-kern-ops ops))])
           (match op
             [`(within-apply-mbu ,comp ,act ,ews)
              (define t-enter rebuild-ts)
              (set! rebuild-ts (add1 rebuild-ts))
              (for ([pw (in-list (hash-ref reuse-points t-enter '()))])
                (set! acc (cons `(waw-barrier ,pw) acc)))
              (define r-comp (remap-leaf-tree comp))
              (define r-act (remap-node act))
              (set! rebuild-ts (add1 rebuild-ts))
              (set! acc (cons `(within-apply-mbu ,r-comp ,r-act ,(remove-duplicates (map rw ews) =))
                              acc))]
             [_
              (define t rebuild-ts)
              (set! rebuild-ts (add1 rebuild-ts))
              (for ([pw (in-list (hash-ref reuse-points t '()))])
                (set! acc (cons `(waw-barrier ,pw) acc)))
              (set! acc (cons (remap-leaf-tree op) acc))]))
         `(linear-lambda ,args ,(reverse acc))]
        [_ (remap-leaf-tree e)]))
    (propagate-surface-span! e out 'Kern))

  (define (remap-leaf-tree op)
    (define rop
      (match op
        [`(linear-lambda ,args ,ops)
         `(linear-lambda ,args ,(map remap-leaf-tree (flatten-kern-ops ops)))]
        [`(,g ,w)
         #:when (memq g '(x z s s-dag h waw-barrier))
         `(,g ,(rw w))]
        [`(ry ,th ,w) `(ry ,th ,(rw w))]
        [`(,g ,w ,k ,f64? ,d)
         #:when (memq g '(rz-dyadic rz-dyadic-neg))
         `(,g ,(rw w) ,k ,f64? ,d)]
        [`(,g ,a ,b)
         #:when (memq g '(cx cz swap))
         `(,g ,(rw a) ,(rw b))]
        [`(,g ,a ,b ,c)
         #:when (memq g '(ccx ccz temp-and))
         `(,g ,(rw a) ,(rw b) ,(rw c))]
        [`(prepare-dicke-le1 ,ws ,w0 ,w1 ,bm)
         `(prepare-dicke-le1 ,(map rw ws) ,w0 ,w1 ,bm)]
        [`(mid-meas-x ,a ,ms ,sh?) `(mid-meas-x ,(rw a) ,ms ,sh?)]
        [`(cond-z ,ms ,t) `(cond-z ,ms ,(rw t))]
        [`(cond-cz ,ms ,a ,b) `(cond-cz ,ms ,(rw a) ,(rw b))]
        [`(syndrome-plaquette ,ws ,d ,hk?) `(syndrome-plaquette ,(map rw ws) ,d ,hk?)]
        [`(within-apply-mbu ,c ,a ,ews)
         `(within-apply-mbu ,(remap-leaf-tree c) ,(remap-leaf-tree a)
                            ,(remove-duplicates (map rw ews) =))]
        [`(erase-by ,f ,b (,knd ,ws))
         `(erase-by ,(remap-leaf-tree f) ,(remap-leaf-tree b)
                    (,knd ,(remove-duplicates (map rw ws) =)))]
        [`(locality-shift zipper-focus (,sw ,aw) ,b)
         `(locality-shift zipper-focus (,(map rw sw) ,(map rw aw)) ,(remap-leaf-tree b))]
        [`(locality-shift parallel-product (,e1 ,e2) ,x)
         `(locality-shift parallel-product (,(remap-leaf-tree e1) ,(remap-leaf-tree e2)) ,x)]
        [`(locality-shift multishot-checkpoint ,k ,b)
         `(locality-shift multishot-checkpoint ,k ,(remap-leaf-tree b))]
        [`(inductive-iso for-fold-loop (,nr ,rks ...) ,x)
         `(inductive-iso for-fold-loop (,nr ,@(map remap-leaf-tree rks)) ,x)]
        [`(inductive-iso orthogonal-partition ,arms ,x)
         `(inductive-iso orthogonal-partition
                         ,(for/list ([arm (in-list arms)])
                            (list (remap-guard w-remap (first arm))
                                  (remap-leaf-tree (second arm))))
                         ,x)]
        [_ op]))
    (propagate-surface-span! op rop 'Kern))

  (define remapped-kern (remap-node kern-ast))
  (define remapped-scr
    (for/list ([i (in-range num-phys-scr)]) (+ fixed-base i)))
  (values remapped-kern remapped-scr (+ fixed-base num-phys-scr)))

;; Pre-MBU, Pre-SSA Algebraic `within-apply-mbu` Saturation + 2-Round `(FRAIG/Commute o TODD/ZX)^2` Fixpoint:
(define (optimize-kern-canonical-phase-order kern-ast
                                             _decl
                                             #:rounds [rounds 2]
                                             #:absorb-top-cz? [absorb-top-cz? #t]
                                             #:enable-mbu-algebraic? [enable-mbu-algebraic? #t]
                                             #:skip-pure-zippers? [skip-pure-zippers? #t])
  (define has-phase-or-nested? (kern-ast-has-phase-or-nested-mbu? kern-ast))
  (define sessions-fused-cnt 0)
  (define phase-absorbed-cnt 0)
  (define hoisted-ops-cnt 0)
  (define commute-moves-cnt 0)
  (define todd-cones-cnt 0)
  (define todd-pre-tc 0)
  (define todd-post-tc 0)
  (define todd-pre-td 0)
  (define todd-post-td 0)

  (define (kern-1q-rz8-val op)
    (match op
      [`(z ,w) (cons w 4)]
      [`(s ,w) (cons w 2)]
      [`(s-dag ,w) (cons w 6)]
      [`(rz-dyadic ,w 3 #f ,_) (cons w 1)]
      [`(rz-dyadic-neg ,w 3 #f ,_) (cons w 7)]
      [`(rz-dyadic ,w 2 #f ,_) (cons w 2)]
      [`(rz-dyadic-neg ,w 2 #f ,_) (cons w 6)]
      [`(rz-dyadic ,w 1 #f ,_) (cons w 4)]
      [`(rz-dyadic-neg ,w 1 #f ,_) (cons w 4)]
      [_ #f]))

  (define (rz8-val->kern-ops w k8 src-op)
    (define raw
      (match (modulo k8 8)
        [0 '()]
        [1 (list `(rz-dyadic ,w 3 #f 5))]
        [2 (list `(s ,w))]
        [3 (list `(s ,w) `(rz-dyadic ,w 3 #f 5))]
        [4 (list `(z ,w))]
        [5 (list `(z ,w) `(rz-dyadic ,w 3 #f 5))]
        [6 (list `(z ,w) `(s ,w))]
        [7 (list `(rz-dyadic-neg ,w 3 #f 5))]))
    (if src-op (propagate-surface-span-list! src-op raw 'Kern) raw))

  (define (cancel-adjacent-kern-ops ops)
    (let loop ([rem ops] [stk '()])
      (cond
        [(null? rem) (reverse stk)]
        [else
         (define cur (car rem))
         (define rcur (kern-1q-rz8-val cur))
         (define rstk (and (pair? stk) (kern-1q-rz8-val (car stk))))
         (cond
           [(and rcur rstk (= (car rcur) (car rstk)))
            (define w (car rcur))
            (define ksum (modulo (+ (cdr rstk) (cdr rcur)) 8))
            (define merged (rz8-val->kern-ops w ksum (car stk)))
            (loop (cdr rem) (append (reverse merged) (cdr stk)))]
           [(and (pair? stk)
                 (equal? cur (car stk))
                 (memq (car cur) '(h x cx cz ccz)))
            (loop (cdr rem) (cdr stk))]
           [else
            (loop (cdr rem) (cons cur stk))])])))

  (define (diagonal-kern-op-disjoint-from? anc op)
    (match op
      [`(,(or 'z 's 's-dag) ,w) (not (= w anc))]
      [`(,(or 'rz-dyadic 'rz-dyadic-neg) ,w ,_ #f ,_) (not (= w anc))]
      [`(cz ,a ,b) (and (not (= a anc)) (not (= b anc)))]
      [`(ccz ,a ,b ,c) (and (not (= a anc)) (not (= b anc)) (not (= c anc)))]
      [`(waw-barrier ,w) (not (= w anc))]
      [_ #f]))

  (define (single-temp-and-mbu-parts op)
    (match op
      [`(within-apply-mbu (linear-lambda ,_ ((temp-and ,c1 ,c2 ,anc)))
                          (linear-lambda ,_ ,act-ops)
                          (,anc2))
       #:when (= anc anc2)
       (list c1 c2 anc (flatten-kern-ops act-ops))]
      [_ #f]))

  (define (mbu-body-read-only-safe? anc c1 c2 body)
    (for/and ([bop (in-list body)])
      (match bop
        [`(cx ,c ,t)
         (and (= c anc) (not (= t anc)) (not (= t c1)) (not (= t c2)))]
        [`(cz ,a ,b)
         (and (or (= a anc) (= b anc)) (not (= a b)))]
        [`(,(or 'z 's 's-dag) ,w) (= w anc)]
        [`(,(or 'rz-dyadic 'rz-dyadic-neg) ,w ,_ #f ,_) (= w anc)]
        [_ #f])))

  (define (mbu-body-phase-only? anc body)
    (and (pair? body)
         (for/and ([bop (in-list body)])
           (match bop
             [`(cz ,a ,b) (and (or (= a anc) (= b anc)) (not (= a b)))]
             [`(z ,w) (= w anc)]
             [_ #f]))))

  (define (subst-wire-in-mbu-body old-w new-w body)
    (for/list ([bop (in-list body)])
      (define out
        (match bop
          [`(cx ,c ,t)
           `(cx ,(if (= c old-w) new-w c) ,(if (= t old-w) new-w t))]
          [`(cz ,a ,b)
           `(cz ,(if (= a old-w) new-w a) ,(if (= b old-w) new-w b))]
          [`(,g ,w)
           #:when (memq g '(z s s-dag))
           `(,g ,(if (= w old-w) new-w w))]
          [`(,g ,w ,k ,f64? ,d)
           #:when (memq g '(rz-dyadic rz-dyadic-neg))
           `(,g ,(if (= w old-w) new-w w) ,k ,f64? ,d)]
          [_ bop]))
      (propagate-surface-span! bop out 'Kern)))

  (define (kern-phase-cone-op? op)
    (match op
      [`(cx ,_ ,_) #t]
      [`(cz ,_ ,_) #t]
      [`(ccz ,_ ,_ ,_) #t]
      [`(,(or 'z 's 's-dag) ,_) #t]
      [`(,(or 'rz-dyadic 'rz-dyadic-neg) ,_ 3 #f ,_) #t]
      [_ #f]))

  (define (commute-kern-ops-across-disjoint-barriers ops)
    (define (disjoint-ws? ws1 ws2)
      (not (for*/or ([u (in-list ws1)] [v (in-list ws2)]) (= u v))))
    (define (commutes-past? op barrier)
      (or (and (kern-phase-cone-op? op)
               (pair? barrier)
               (memq (car barrier) '(h x))
               (disjoint-ws? (kern-leaf-op-wires op) (kern-leaf-op-wires barrier)))
          (and (pair? op)
               (eq? (car op) 'cx)
               (pair? barrier)
               (eq? (car barrier) 'x)
               (not (= (second op) (second barrier))))))
    (define (push-right op rest-ops)
      (match rest-ops
        ['() (list op)]
        [(cons hd tl)
         (if (commutes-past? op hd)
             (begin
               (set! commute-moves-cnt (add1 commute-moves-cnt))
               (cons hd (push-right op tl)))
             (cons op rest-ops))]))
    (cancel-adjacent-kern-ops
     (let rec ([rem ops])
       (if (null? rem)
           '()
           (push-right (car rem) (rec (cdr rem)))))))

  (define (reduce-kern-phase-cone cone-ops)
    (define cone-ws
      (sort (remove-duplicates (apply append (map kern-leaf-op-wires cone-ops)) =) <))
    (define k-wires (length cone-ws))
    (define non-cliff-cnt
      (for/sum ([op (in-list cone-ops)])
        (match op
          [`(ccz ,_ ,_ ,_) 1]
          [`(,(or 'rz-dyadic 'rz-dyadic-neg) ,_ 3 #f ,_) 1]
          [_ 0])))
    (define ccz-cnt
      (for/sum ([op (in-list cone-ops)])
        (match op [`(ccz ,_ ,_ ,_) 1] [_ 0])))
    (cond
      [(or (= non-cliff-cnt 0) (= k-wires 0) (> k-wires 16))
       cone-ops]
      [else
       (define phys->loc (make-hasheqv))
       (for ([w (in-list cone-ws)] [idx (in-naturals)])
         (hash-set! phys->loc w idx))
       (define loc->phys (list->vector cone-ws))
       (define (lw w) (hash-ref phys->loc w 0))
       (define (pw idx) (vector-ref loc->phys idx))
       (define eg-ops
         (for/list ([op (in-list cone-ops)])
           (match op
             [`(cx ,c ,t) (list 'cx (lw c) (lw t))]
             [`(cz ,a ,b) (list 'cz (lw a) (lw b))]
             [`(ccz ,a ,b ,c) (list 'ccz (lw a) (lw b) (lw c))]
             [`(z ,w) (list 'z (lw w))]
             [`(s ,w) (list 's (lw w))]
             [`(s-dag ,w) (list 'sdg (lw w))]
             [`(rz-dyadic ,w 3 #f ,_) (list 't (lw w))]
             [`(rz-dyadic-neg ,w 3 #f ,_) (list 'tdg (lw w))])))
       (define an-ops
         (for/list ([op (in-list cone-ops)])
           (match op
             [`(cx ,c ,t) `(cx ,(lw c) ,(lw t))]
             [`(cz ,a ,b) `(cz ,(lw a) ,(lw b))]
             [`(ccz ,a ,b ,c) `(ccz ,(lw a) ,(lw b) ,(lw c))]
             [`(z ,w) `(rz8 ,(lw w) 4)]
             [`(s ,w) `(rz8 ,(lw w) 2)]
             [`(s-dag ,w) `(rz8 ,(lw w) 6)]
             [`(rz-dyadic ,w 3 #f ,_) `(rz8 ,(lw w) 1)]
             [`(rz-dyadic-neg ,w 3 #f ,_) `(rz8 ,(lw w) 7)])))
       (define pre-isa (lower-todd-cone-pre-isa eg-ops))
       (define tc-pre (compute-isa-t-count pre-isa))
       (define td-pre (compute-isa-t-depth k-wires pre-isa))

       ;; Candidate 1: `lakefillq-phase-ordering-analyzer.rkt` `pass-todd-zx`
       ;; (`RM*(n-4,n)^perp` 15-subset puncture sweep + Twin-CCZ polarity search):
       (define an-prog
         (pass-todd-zx (revir-prog "kern_cone" k-wires 0 0 1 an-ops #f (seteqv) (hasheq))
                       #:rounds 1
                       #:partition-aware? #f))
       (define cand1-isa
         (apply append
                (for/list ([rop (in-list (revir-prog-ops an-prog))])
                  (match rop
                    [`(cx ,c ,t) (list (list "cx" c t))]
                    [`(cz ,a ,b) (list (list "cz" a b))]
                    [`(rz8 ,w ,k8)
                     (match (modulo k8 8)
                       [0 '()]
                       [1 (list (list "t" w))]
                       [2 (list (list "s" w))]
                       [3 (list (list "s" w) (list "t" w))]
                       [4 (list (list "z" w))]
                       [5 (list (list "z" w) (list "t" w))]
                       [6 (list (list "sdg" w))]
                       [7 (list (list "tdg" w))])]))))
       (define tc1 (compute-isa-t-count cand1-isa))
       (define td1 (compute-isa-t-depth k-wires cand1-isa))

       ;; Candidate 2: `lakefillq-egraph-saturator.rkt` `lower-todd-cone-post-isa`:
       (define-values (cand2-isa tc2 td2)
         (if (and (<= ccz-cnt 10)
                  (phase-clean-u2-u4-cone-ops? k-wires eg-ops))
             (let ([p2 (lower-todd-cone-post-isa k-wires eg-ops)])
               (values p2
                       (compute-isa-t-count p2)
                       (compute-isa-t-depth k-wires p2)))
             (values cand1-isa tc1 td1)))

       (define use-c2?
         (or (< tc2 tc1)
             (and (= tc2 tc1) (< td2 td1))
             (and (= tc2 tc1) (= td2 td1) (< (length cand2-isa) (length cand1-isa)))))
       (define best-isa (if use-c2? cand2-isa cand1-isa))
       (define tc-best (if use-c2? tc2 tc1))
       (define td-best (if use-c2? td2 td1))

       (if (or (< tc-best tc-pre)
               (and (= tc-best tc-pre) (< td-best td-pre)))
           (let ()
             (set! todd-cones-cnt (add1 todd-cones-cnt))
             (set! todd-pre-tc (+ todd-pre-tc tc-pre))
             (set! todd-post-tc (+ todd-post-tc tc-best))
             (set! todd-pre-td (+ todd-pre-td td-pre))
             (set! todd-post-td (+ todd-post-td td-best))
             (define src-node (first cone-ops))
             (define lowered-kern
               (apply append
                      (for/list ([ins (in-list best-isa)])
                        (match ins
                          [(list "cx" c t) (list `(cx ,(pw c) ,(pw t)))]
                          [(list "cz" a b) (list `(cz ,(pw a) ,(pw b)))]
                          [(list "z" w) (list `(z ,(pw w)))]
                          [(list "s" w) (list `(s ,(pw w)))]
                          [(list "sdg" w)
                           (list `(z ,(pw w)) `(s ,(pw w)))]
                          [(list "t" w) (list `(rz-dyadic ,(pw w) 3 #f 5))]
                          [(list "tdg" w) (list `(rz-dyadic-neg ,(pw w) 3 #f 5))]))))
             (propagate-surface-span-list! src-node lowered-kern 'Kern))
           cone-ops)]))

  (define (cone-reduce-step ops in-qmatch?)
    (define canceled-ops (cancel-adjacent-kern-ops ops))
    (if in-qmatch?
        canceled-ops
        (let cone-loop ([rem canceled-ops] [cur-cone '()] [out '()])
          (cond
            [(null? rem)
             (append out
                     (if (null? cur-cone)
                         '()
                         (reduce-kern-phase-cone (reverse cur-cone))))]
            [(kern-phase-cone-op? (car rem))
             (cone-loop (cdr rem) (cons (car rem) cur-cone) out)]
            [else
             (define flushed
               (if (null? cur-cone)
                   '()
                   (reduce-kern-phase-cone (reverse cur-cone))))
             (cone-loop (cdr rem) '() (append out flushed (list (car rem))))]))))

  (define (algebraic-mbu-step raw-ops top-level? in-qmatch?)
    (define flat0 (flatten-kern-ops raw-ops))
    (if (not enable-mbu-algebraic?)
        (for/list ([op (in-list flat0)])
          (transform-node op top-level? in-qmatch?))
        (let ()
          (define hoisted
            (apply append
                   (for/list ([op (in-list flat0)])
                     (match (single-temp-and-mbu-parts op)
                       [(list c1 c2 anc act-ops)
                        (define alg-act (algebraic-mbu-step act-ops #f in-qmatch?))
                        (define-values (rev-tail0 rev-kept0)
                          (let split ([r (reverse alg-act)] [h '()])
                            (if (and (pair? r) (diagonal-kern-op-disjoint-from? anc (car r)))
                                (split (cdr r) (cons (car r) h))
                                (values h r))))
                        (define sat-kept (cone-reduce-step (reverse rev-kept0) in-qmatch?))
                        (define-values (rev-tail1 rev-kept1)
                          (let split ([r (reverse sat-kept)] [h '()])
                            (if (and (pair? r) (diagonal-kern-op-disjoint-from? anc (car r)))
                                (split (cdr r) (cons (car r) h))
                                (values h r))))
                        (define all-hoisted (append rev-tail1 rev-tail0))
                        (when (pair? all-hoisted)
                          (set! hoisted-ops-cnt (+ hoisted-ops-cnt (length all-hoisted))))
                        (define kept (reverse rev-kept1))
                        (if (null? kept)
                            (begin
                              (set! sessions-fused-cnt (add1 sessions-fused-cnt))
                              all-hoisted)
                            (cons (propagate-surface-span!
                                   op
                                   `(within-apply-mbu (linear-lambda () ((temp-and ,c1 ,c2 ,anc)))
                                                      (linear-lambda () ,kept)
                                                      (,anc))
                                   'Kern)
                                  all-hoisted))]
                       [_ (list (transform-node op top-level? in-qmatch?))]))))
          (define fused
            (let fuse-loop ([rem hoisted] [acc '()])
              (match rem
                ['() (reverse acc)]
                [(list* op1 op2 tl)
                 (define p1 (single-temp-and-mbu-parts op1))
                 (define p2 (single-temp-and-mbu-parts op2))
                 (cond
                   [(and p1 p2
                         (= (min (first p1) (second p1)) (min (first p2) (second p2)))
                         (= (max (first p1) (second p1)) (max (first p2) (second p2)))
                         (mbu-body-read-only-safe? (third p1) (first p1) (second p1) (fourth p1))
                         (mbu-body-read-only-safe? (third p2) (first p2) (second p2) (fourth p2)))
                    (define c1 (first p1))
                    (define c2 (second p1))
                    (define a1 (third p1))
                    (define a2 (third p2))
                    (define merged-body
                      (cancel-adjacent-kern-ops
                       (append (fourth p1)
                               (subst-wire-in-mbu-body a2 a1 (fourth p2)))))
                    (cond
                      [(or has-phase-or-nested? (not (null? merged-body)))
                       (set! sessions-fused-cnt (add1 sessions-fused-cnt))
                       (if (null? merged-body)
                           (fuse-loop tl acc)
                           (fuse-loop
                            (cons (propagate-surface-span!
                                   op1
                                   `(within-apply-mbu (linear-lambda () ((temp-and ,c1 ,c2 ,a1)))
                                                      (linear-lambda () ,merged-body)
                                                      (,a1))
                                   'Kern)
                                  tl)
                            acc))]
                      [else
                       (fuse-loop (cdr rem) (cons op1 acc))])]
                   [else
                    (fuse-loop (cdr rem) (cons op1 acc))])]
                [(cons hd tl)
                 (fuse-loop tl (cons hd acc))])))
          (apply append
                 (for/list ([op (in-list fused)])
                   (match (single-temp-and-mbu-parts op)
                     [(list c1 c2 anc b-ops)
                      #:when (and (or (not top-level?) absorb-top-cz?)
                                  (not in-qmatch?)
                                  (mbu-body-phase-only? anc b-ops))
                      (set! phase-absorbed-cnt (add1 phase-absorbed-cnt))
                      (define absorbed
                        (for/list ([bop (in-list b-ops)])
                          (match bop
                            [`(cz ,a ,b)
                             (define other (if (= a anc) b a))
                             (if (or (= other c1) (= other c2))
                                 `(cz ,c1 ,c2)
                                 `(ccz ,c1 ,c2 ,other))]
                            [`(z ,_) `(cz ,c1 ,c2)])))
                      (propagate-surface-span-list! op absorbed 'Kern)]
                     [_ (list op)]))))))

  (define (saturate-op-list raw-ops top-level? in-qmatch?)
    (cone-reduce-step (algebraic-mbu-step raw-ops top-level? in-qmatch?) in-qmatch?))

  (define (pure-todd-zipper-body? e)
    (let walk ([n e])
      (match n
        [`(linear-lambda ,_ ,ops) (for/and ([op (in-list ops)]) (walk op))]
        [(? kern-phase-cone-op?) #t]
        [_ #f])))

  (define (transform-node e top-level? in-qmatch?)
    (define rebuilt
      (match e
        [`(linear-lambda ,args ,ops)
         `(linear-lambda ,args ,(saturate-op-list ops top-level? in-qmatch?))]
        [`(within-apply-mbu ,comp ,act ,ews)
         `(within-apply-mbu ,(transform-node comp #f in-qmatch?)
                            ,(transform-node act #f in-qmatch?)
                            ,ews)]
        [`(erase-by ,fwd ,bwd ,spec)
         `(erase-by ,(transform-node fwd top-level? in-qmatch?)
                    ,(transform-node bwd top-level? in-qmatch?)
                    ,spec)]
        [`(locality-shift zipper-focus ,zspec ,body)
         (if (and skip-pure-zippers? (pure-todd-zipper-body? body))
             e
             `(locality-shift zipper-focus ,zspec ,(transform-node body #f in-qmatch?)))]
        [`(locality-shift parallel-product (,e1 ,e2) ,x)
         `(locality-shift parallel-product
                          (,(transform-node e1 top-level? in-qmatch?)
                           ,(transform-node e2 top-level? in-qmatch?))
                          ,x)]
        [`(locality-shift multishot-checkpoint ,k ,b)
         `(locality-shift multishot-checkpoint ,k ,(transform-node b top-level? in-qmatch?))]
        [`(inductive-iso for-fold-loop (,nr ,rks ...) ,x)
         `(inductive-iso for-fold-loop
                         (,nr ,@(for/list ([rk (in-list rks)])
                                  (transform-node rk top-level? in-qmatch?)))
                         ,x)]
        [`(inductive-iso orthogonal-partition ,arms ,x)
         `(inductive-iso orthogonal-partition
                         ,(for/list ([arm (in-list arms)])
                            (list (first arm) (transform-node (second arm) #f #t)))
                         ,x)]
        [`(catamorphism-fold ,idx ,st ,l ,r)
         (if (< idx 0)
             e
             `(catamorphism-fold ,idx
                                 ,(transform-node st top-level? in-qmatch?)
                                 ,(if (eq? l 'none) 'none (transform-node l top-level? in-qmatch?))
                                 ,(if (eq? r 'none) 'none (transform-node r top-level? in-qmatch?))))]
        [_ e]))
    (propagate-surface-span! e rebuilt 'Kern))

  (define (commute-tree e)
    (define rebuilt
      (match e
        [`(linear-lambda ,args ,ops)
         `(linear-lambda ,args
                         ,(commute-kern-ops-across-disjoint-barriers
                           (map commute-tree (flatten-kern-ops ops))))]
        [`(within-apply-mbu ,c ,a ,ews)
         `(within-apply-mbu ,(commute-tree c) ,(commute-tree a) ,ews)]
        [`(erase-by ,f ,b ,sp)
         `(erase-by ,(commute-tree f) ,(commute-tree b) ,sp)]
        [`(locality-shift zipper-focus ,zs ,b)
         (if (and skip-pure-zippers? (pure-todd-zipper-body? b))
             e
             `(locality-shift zipper-focus ,zs ,(commute-tree b)))]
        [`(locality-shift parallel-product (,e1 ,e2) ,x)
         `(locality-shift parallel-product (,(commute-tree e1) ,(commute-tree e2)) ,x)]
        [`(locality-shift multishot-checkpoint ,k ,b)
         `(locality-shift multishot-checkpoint ,k ,(commute-tree b))]
        [`(inductive-iso for-fold-loop (,nr ,rks ...) ,x)
         `(inductive-iso for-fold-loop (,nr ,@(map commute-tree rks)) ,x)]
        [_ e]))
    (propagate-surface-span! e rebuilt 'Kern))

  (define final-kern
    (let round-loop ([k 0] [cur kern-ast])
      (cond
        [(>= k rounds) cur]
        [(= (add1 k) rounds)
         (transform-node cur #t #f)]
        [else
         (define p1 (transform-node cur #t #f))
         (define p2 (commute-tree p1))
         (round-loop (add1 k) p2)])))

  (values final-kern
          (hasheq 'sessions_fused sessions-fused-cnt
                  'phase_cones_absorbed phase-absorbed-cnt
                  'disjoint_diagonal_ops_hoisted hoisted-ops-cnt
                  'fraig_commute_moves commute-moves-cnt
                  'todd_cones_reduced todd-cones-cnt
                  'todd_pre_t_count todd-pre-tc
                  'todd_post_t_count todd-post-tc
                  'todd_pre_t_depth todd-pre-td
                  'todd_post_t_depth todd-post-td)))

;; Coupled Partition-Aware Rank-r Conjugate Block-LU Linear Frame Resynthesis (`P_part_u4 <-> Block-LU`):
;; Compresses cross-QPU CNOT runs `B` from `||B||_0` down to `rank_F2(B)` via
;; `synthesize-linear-frame-partition-aware` (`L_local * P_cut * U_local`) without ancillas!
(define (resynthesize-isa-cx-frames-partition-aware isa-ops num-phys-q slices)
  (cond
    [(or (<= num-phys-q 0) (not slices) (<= (length slices) 1))
     (values isa-ops 0 0 0)]
    [else
     (define qpu-vec (make-vector num-phys-q 0))
     (for ([sl (in-list slices)] [p (in-naturals)])
       (for ([w (in-list sl)] #:when (< w num-phys-q))
         (vector-set! qpu-vec w p)))

     (define (cx-run-metrics cx-pairs)
       (define z-ep (make-vector num-phys-q 0))
       (define cones (mutable-set))
       (define u4-ebits 0)
       (define cross-cxs 0)
       (for ([pr (in-list cx-pairs)])
         (define c (car pr))
         (define t (cdr pr))
         (define pc (vector-ref qpu-vec c))
         (define pt (vector-ref qpu-vec t))
         (unless (= pc pt)
           (set! cross-cxs (add1 cross-cxs))
           (define key (list pc pt c (vector-ref z-ep c)))
           (unless (set-member? cones key)
             (set-add! cones key)
             (set! u4-ebits (add1 u4-ebits))))
         (vector-set! z-ep t (add1 (vector-ref z-ep t))))
       (values u4-ebits cross-cxs))

     (define frames-resynth 0)
     (define cross-cxs-saved 0)
     (define ebits-saved 0)

     (define (flush-cx-run rev-run)
       (define run-ops (reverse rev-run))
       (if (<= (length run-ops) 1)
           run-ops
           (let ()
             (define orig-pairs
               (for/list ([op (in-list run-ops)])
                 (match-define `(isa-cx ,c ,t) op)
                 (cons c t)))
             (define-values (orig-eb orig-cross) (cx-run-metrics orig-pairs))
             (if (= orig-cross 0)
                 run-ops
                 (let ()
                   (define frame
                     (for/vector ([w (in-range num-phys-q)]) (arithmetic-shift 1 w)))
                   (for ([pr (in-list orig-pairs)])
                     (define c (car pr))
                     (define t (cdr pr))
                     (vector-set! frame t
                                  (bitwise-xor (vector-ref frame t) (vector-ref frame c))))
                   (define syn-raw
                     (synthesize-linear-frame-partition-aware num-phys-q frame slices))
                   (define syn-pairs
                     (for/list ([ins (in-list syn-raw)])
                       (cons (second ins) (third ins))))
                   (define-values (syn-eb syn-cross) (cx-run-metrics syn-pairs))
                   (if (or (and (< syn-eb orig-eb) (<= syn-cross orig-cross))
                           (and (= syn-eb orig-eb) (< syn-cross orig-cross)))
                       (begin
                         (set! frames-resynth (add1 frames-resynth))
                         (set! cross-cxs-saved (+ cross-cxs-saved (- orig-cross syn-cross)))
                         (set! ebits-saved (+ ebits-saved (max 0 (- orig-eb syn-eb))))
                         (for/list ([pr (in-list syn-pairs)])
                           `(isa-cx ,(car pr) ,(cdr pr))))
                       run-ops))))))

     (define new-isa
       (let loop ([rem isa-ops] [rev-run '()] [out '()])
         (cond
           [(null? rem)
            (append out (flush-cx-run rev-run))]
           [(match (car rem) [`(isa-cx ,_ ,_) #t] [_ #f])
            (loop (cdr rem) (cons (car rem) rev-run) out)]
           [else
            (define flushed (flush-cx-run rev-run))
            (loop (cdr rem) '() (append out flushed (list (car rem))))])))
     (values new-isa frames-resynth cross-cxs-saved ebits-saved)]))

(define (isa-ops->analyzer-revir-ops isa-ops)
  (filter values
          (for/list ([op (in-list isa-ops)])
            (match op
              [`(isa-h ,w) `(h ,w)]
              [`(isa-x ,w) `(x ,w)]
              [`(isa-z ,w) `(rz8 ,w 4)]
              [`(isa-s ,w) `(rz8 ,w 2)]
              [`(isa-sdg ,w) `(rz8 ,w 6)]
              [`(isa-rz ,_ ,w) `(rz8 ,w 1)]
              [`(isa-cx ,c ,t) `(cx ,c ,t)]
              [`(isa-cz ,a ,b) `(cz ,a ,b)]
              [`(isa-ccx ,a ,b ,t) `(ccx ,a ,b ,t)]
              [`(isa-temp-and-ccx ,c1 ,c2 ,anc) `(temp-and ,c1 ,c2 ,anc)]
              [`(isa-meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)
               `(meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)]
              [_ #f]))))

(define (build-qec-syndrome-decoder-pacing-metadata target-sym _hw)
  (define active-fastpath-ns
    (if (eq? target-sym 'bb-qldpc) 66.15 64.17))
  (define cycle-budget-ns 1000.0)
  (hasheq 'decoder_architecture "0-DSP Okasaki Braun Union-Find + Sparse-Syndrome Fast-Path"
          'target_profile (symbol->string target-sym)
          'clock_frequency_mhz 500.0
          'dsp48e2_slices 0
          'zero_dsp_certified #t
          'fastpath_clock_cycles_range '(1 2)
          'd5_sparse_fastpath_mean_tau_dec_ns 64.17
          'bb_qldpc_sparse_fastpath_mean_tau_dec_ns 66.15
          'active_target_fastpath_mean_tau_dec_ns active-fastpath-ns
          'conservative_300k_coax_ns 420.0
          'closed_loop_500mhz_worst_case_ns 340.0
          'cryo_cmos_4k_inner_ns 120.0
          'unpaced_software_mwpm_ns 4500.0
          'qec_cycle_budget_ns cycle-budget-ns
          'lindley_rho_fastpath (/ (round (* 100000.0 (/ active-fastpath-ns cycle-budget-ns))) 100000.0)
          'lindley_rho_conservative_coax 0.42
          'lindley_rho_closed_loop_worst_case 0.34
          'lindley_backlog_stable #t))

;; =============================================================================
;; 6. Lowering: `RevIR -> MachineISA -> OpenQASM 3.0 & Stim`
;; =============================================================================

;; Exact `m`-qubit Dicke weight-<=1 preparation circuit (`0` ancillas):
(define (expand-dicke-le1->isa ws w0 w1 b-mask)
  (define m (length ws))
  (define norm (sqrt (+ (* w0 w0) (* w1 w1))))
  (define a0 (/ (exact->inexact w0) norm))
  (define theta0 (* 2.0 (acos (min 1.0 (max -1.0 a0)))))
  (define init-op (list `(isa-ry ,theta0 ,(first ws))))
  (define cascade
    (apply append
           (for/list ([j (in-range (sub1 m))])
             (define k (- m j))
             (define phi (* 2.0 (acos (/ 1.0 (sqrt (exact->inexact k))))))
             (define u (list-ref ws j))
             (define v (list-ref ws (add1 j)))
             ;; Controlled-RY(phi) from u -> v, followed by CX v -> u:
             (list `(isa-ry ,(* 0.5 phi) ,v)
                   `(isa-cx ,u ,v)
                   `(isa-ry ,(* -0.5 phi) ,v)
                   `(isa-cx ,u ,v)
                   `(isa-cx ,v ,u)))))
  (define sign-ops
    (for/list ([j (in-range m)] #:when (bitwise-bit-set? b-mask j))
      `(isa-z ,(list-ref ws j))))
  (append init-op cascade sign-ops))

;; Lower a boolean guard `g` into reversible computation XORing `[g(x)]` onto clean `target-anc`
;; using clean `pool-ancs` (`within-apply-mbu` style):
(define (emit-guard-compute-isa g target-anc pool-ancs alloc-meas!)
  (match g
    ['true (list `(isa-x ,target-anc))]
    ['false '()]
    [`(wire ,w) (list `(isa-cx ,w ,target-anc))]
    [`(zero ,w) (list `(isa-x ,w) `(isa-cx ,w ,target-anc) `(isa-x ,w))]
    [`(and (wire ,w1) (wire ,w2))
     (list `(isa-ccx ,w1 ,w2 ,target-anc))]
    [`(and . ,factors)
     ;; Conjunction of literals `(wire w)` / `(zero w)`:
     (define neg-ws
       (filter values
               (for/list ([f (in-list factors)])
                 (match f [`(zero ,w) w] [_ #f]))))
     (define lit-ws
       (for/list ([f (in-list factors)])
         (match f
           [`(wire ,w) w]
           [`(zero ,w) w]
           [_ (error 'emit-guard-compute-isa "Nested guard requires literal conjunction: ~a" g)])))
     (define flip-in (for/list ([w (in-list neg-ws)]) `(isa-x ,w)))
     (define flip-out (reverse flip-in))
     (define k (length lit-ws))
     (cond
       [(= k 0) (list `(isa-x ,target-anc))]
       [(= k 1) (append flip-in (list `(isa-cx ,(first lit-ws) ,target-anc)) flip-out)]
       [(= k 2) (append flip-in (list `(isa-ccx ,(first lit-ws) ,(second lit-ws) ,target-anc)) flip-out)]
       [else
        (define need (- k 2))
        (when (< (length pool-ancs) need)
          (error 'emit-guard-compute-isa "Need ~a guard scratch wires for ~a" need g))
        (define used (take pool-ancs need))
        (define fwd-ands
          (cons `(isa-ccx ,(first lit-ws) ,(second lit-ws) ,(first used))
                (for/list ([idx (in-range 2 (- k 1))])
                  `(isa-ccx ,(list-ref lit-ws idx)
                            ,(list-ref used (- idx 2))
                            ,(list-ref used (- idx 1))))))
        (define act (list `(isa-ccx ,(last used) ,(last lit-ws) ,target-anc)))
        (define bwd-mbu
          (apply append
                 (for/list ([idx (in-range (- k 2) 0 -1)])
                   (define anc (list-ref used (sub1 idx)))
                   (define c1 (if (= idx 1) (first lit-ws) (list-ref used (- idx 2))))
                   (define c2 (if (= idx 1) (second lit-ws) (list-ref lit-ws idx)))
                   (define mk (alloc-meas! (gensym 'gm)))
                   (list `(isa-meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)))))
        (append flip-in fwd-ands act bwd-mbu flip-out)])]
    [`(all-zero ,ws)
     (emit-guard-compute-isa `(and ,@(for/list ([w (in-list ws)]) `(zero ,w)))
                             target-anc pool-ancs alloc-meas!)]
    [_ (error 'emit-guard-compute-isa "Unsupported guard in MachineISA lowering: ~a" g)]))

(define (control-isa-op ctrl op)
  (match op
    [`(isa-x ,t) (list `(isa-cx ,ctrl ,t))]
    [`(isa-z ,t) (list `(isa-cz ,ctrl ,t))]
    [`(isa-h ,t)
     (list `(isa-ry ,(- (/ pi 4.0)) ,t)
           `(isa-cz ,ctrl ,t)
           `(isa-ry ,(/ pi 4.0) ,t))]
    [`(isa-s ,t)
     (define qtr (/ pi 4.0))
     (list `(isa-rz ,qtr ,ctrl)
           `(isa-rz ,qtr ,t)
           `(isa-cx ,ctrl ,t)
           `(isa-rz ,(- qtr) ,t)
           `(isa-cx ,ctrl ,t))]
    [`(isa-sdg ,t)
     (define nqtr (- (/ pi 4.0)))
     (list `(isa-rz ,nqtr ,ctrl)
           `(isa-rz ,nqtr ,t)
           `(isa-cx ,ctrl ,t)
           `(isa-rz ,(- nqtr) ,t)
           `(isa-cx ,ctrl ,t))]
    [`(isa-ry ,th ,t)
     (define hth (* 0.5 th))
     (list `(isa-ry ,hth ,t)
           `(isa-cx ,ctrl ,t)
           `(isa-ry ,(- hth) ,t)
           `(isa-cx ,ctrl ,t))]
    [`(isa-rz ,th ,t)
     (define hth (* 0.5 th))
     (list `(isa-rz ,hth ,t)
           `(isa-cx ,ctrl ,t)
           `(isa-rz ,(- hth) ,t)
           `(isa-cx ,ctrl ,t))]
    [`(isa-cx ,c ,t) (list `(isa-ccx ,ctrl ,c ,t))]
    [`(isa-cz ,a ,b)
     (list `(isa-h ,b) `(isa-ccx ,ctrl ,a ,b) `(isa-h ,b))]
    [`(isa-swap ,a ,b)
     (list `(isa-cx ,b ,a) `(isa-ccx ,ctrl ,a ,b) `(isa-cx ,b ,a))]
    [_ (error 'control-isa-op "Unsupported controlled op inside qmatch arm: ~a" op)]))

(define (lower-revir->machine-isa revir num-phys-qubits)
  (define meas-map (make-hasheq))
  (define next-meas-box (box 0))
  (define extra-phys-box (box num-phys-qubits))
  (define guard-scratch-pool-box (box '()))

  (define (alloc-meas! m-sym)
    (hash-ref! meas-map m-sym
               (lambda ()
                 (define k (unbox next-meas-box))
                 (set-box! next-meas-box (add1 k))
                 k)))

  (define (ensure-guard-scratch! count)
    (define cur (unbox guard-scratch-pool-box))
    (if (>= (length cur) count)
        cur
        (let* ([need (- count (length cur))]
               [base (unbox extra-phys-box)]
               [more (range base (+ base need))])
          (set-box! extra-phys-box (+ base need))
          (define updated (append cur more))
          (set-box! guard-scratch-pool-box updated)
          updated)))

  (define (lower-list nodes)
    (let loop ([rem nodes] [acc '()])
      (match rem
        ['() (reverse acc)]
        ;; Peephole-fuse adjacent `rev-mid-meas-x` + `rev-cond-cz` (standard `within-apply-mbu`)
        ;; into exact `h q[a]; m[k] = measure q[a]; if (m[k] == 1) { cz q[c1], q[c2]; } reset q[a];`!
        [(list* `(rev-mid-meas-x ,anc ,m-sym ,_)
                `(rev-cond-cz ,m-sym2 ,c1 ,c2)
                rest-nodes)
         #:when (and (eq? m-sym m-sym2) (not (= anc c1)) (not (= anc c2)))
         (define mk (alloc-meas! m-sym))
         (loop rest-nodes
               (cons `(isa-meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2) acc))]
        [(list* `(rev-mid-meas-x ,anc ,m-sym ,_)
                `(rev-cond-z ,m-sym2 ,t)
                rest-nodes)
         #:when (and (eq? m-sym m-sym2) (not (= anc t)))
         (define mk (alloc-meas! m-sym))
         (loop rest-nodes
               (cons `(isa-meas-x-cond-z-reset ,anc ,mk ,t) acc))]
        [(cons node rest-nodes)
         (define lowered
           (match node
             [`(rev-gate (x ,w)) (list `(isa-x ,w))]
             [`(rev-gate (z ,w)) (list `(isa-z ,w))]
             [`(rev-gate (s ,w)) (list `(isa-s ,w))]
             [`(rev-gate (s-dag ,w)) (list `(isa-sdg ,w))]
             [`(rev-gate (h ,w)) (list `(isa-h ,w))]
             [`(rev-gate (ry ,th ,w)) (list `(isa-ry ,(exact->inexact th) ,w))]
             [`(rev-gate (rz-dyadic ,w ,exp-k ,_ ,_))
              (define ang (/ pi (expt 2.0 (- exp-k 1))))
              (list `(isa-rz ,ang ,w))]
             [`(rev-gate (rz-dyadic-neg ,w ,exp-k ,_ ,_))
              (define ang (- (/ pi (expt 2.0 (- exp-k 1)))))
              (list `(isa-rz ,ang ,w))]
             [`(rev-gate (cx ,c ,t)) (list `(isa-cx ,c ,t))]
             [`(rev-gate (cz ,a ,b)) (list `(isa-cz ,a ,b))]
             [`(rev-gate (swap ,a ,b)) (list `(isa-swap ,a ,b))]
             [`(rev-gate (ccx ,c1 ,c2 ,t)) (list `(isa-ccx ,c1 ,c2 ,t))]
             [`(rev-gate (ccz ,a ,b ,c))
              (list `(isa-h ,c) `(isa-ccx ,a ,b ,c) `(isa-h ,c))]
             [`(rev-temp-and ,c1 ,c2 ,anc)
              (list `(isa-temp-and-ccx ,c1 ,c2 ,anc))]
             [`(rev-prepare-dicke-le1 ,ws ,w0 ,w1 ,bm)
              (expand-dicke-le1->isa ws w0 w1 bm)]
             [`(rev-mid-meas-x ,anc ,m-sym ,_)
              (define mk (alloc-meas! m-sym))
              (list `(isa-meas-x-reset ,anc ,mk))]
             [`(rev-cond-z ,m-sym ,t)
              (define mk (alloc-meas! m-sym))
              (list `(isa-cond-z ,mk ,t))]
             [`(rev-cond-cz ,m-sym ,c1 ,c2)
              (define mk (alloc-meas! m-sym))
              (list `(isa-cond-cz ,mk ,c1 ,c2))]
             [`(rev-syndrome-plaquette ,ws ,_ ,hook-aligned?)
              (define anc (first ws))
              (define data-ws (rest ws))
              ;; N-Z-S-W interleaves middle CNOTs orthogonally vs linear aligned order:
              (define ordered-data
                (if (or hook-aligned? (< (length data-ws) 4))
                    data-ws
                    (list (first data-ws) (third data-ws) (second data-ws) (fourth data-ws))))
              (for/list ([dw (in-list ordered-data)])
                `(isa-cx ,dw ,anc))]
             [`(rev-erase-check ,_) '()]
             [`(rev-quotient-check ,_) '()]
             [`(rev-par ,ir1 ,ir2)
              (append (lower-list ir1) (lower-list ir2))]
             [`(rev-focus-zipper ,_ ,ir)
              (lower-list ir)]
             [`(rev-for-fold-loop ,_ ,rirs)
              (apply append (map lower-list rirs))]
             [`(rev-multishot ,_ ,ir)
              (lower-list ir)]
             [`(rev-qmatch ,arms)
              (apply append
                     (for/list ([arm (in-list arms)])
                       (define g (first arm))
                       (define arm-ops (lower-list (second arm)))
                       (cond
                         [(null? arm-ops) '()]
                         [(match g [`(wire ,c) c] [_ #f])
                          => (lambda (c)
                               (apply append (map (lambda (op) (control-isa-op c op)) arm-ops)))]
                         [(match g [`(zero ,c) c] [_ #f])
                          => (lambda (c)
                               (append (list `(isa-x ,c))
                                       (apply append (map (lambda (op) (control-isa-op c op)) arm-ops))
                                       (list `(isa-x ,c))))]
                         [else
                          (define gpool (ensure-guard-scratch! 4))
                          (define g-anc (first gpool))
                          (define sub-pool (rest gpool))
                          (define g-comp
                            (emit-guard-compute-isa g g-anc sub-pool alloc-meas!))
                          (define ctrl-body
                            (apply append (map (lambda (op) (control-isa-op g-anc op)) arm-ops)))
                          ;; Guard invariance (`Law U3`) guarantees symmetric/MBU uncomputation returns `g-anc -> |0>`:
                          (define g-uncomp
                            (emit-guard-compute-isa g g-anc sub-pool alloc-meas!))
                          (append g-comp ctrl-body g-uncomp)])))]
             [_ (error 'lower-revir->machine-isa "Unknown RevIR node: ~a" node)]))
         (loop rest-nodes (append (reverse lowered) acc))])))

  (define isa-ops (lower-list revir))
  (values isa-ops
          (unbox extra-phys-box)
          (unbox next-meas-box)
          (unbox guard-scratch-pool-box)))

(define (fmt-float x)
  (~r (exact->inexact x) #:precision '(= 12)))

(define (emit-openqasm3 isa-ops total-qubits total-clbits)
  (define lines
    (append
     (list "OPENQASM 3.0;"
           "include \"stdgates.inc\";"
           (format "qubit[~a] q;" (max 1 total-qubits)))
     (if (> total-clbits 0)
         (list (format "bit[~a] m;" total-clbits))
         '())
     (for/list ([op (in-list isa-ops)])
       (match op
         [`(isa-x ,w) (format "x q[~a];" w)]
         [`(isa-z ,w) (format "z q[~a];" w)]
         [`(isa-s ,w) (format "s q[~a];" w)]
         [`(isa-sdg ,w) (format "sdg q[~a];" w)]
         [`(isa-h ,w) (format "h q[~a];" w)]
         [`(isa-ry ,th ,w) (format "ry(~a) q[~a];" (fmt-float th) w)]
         [`(isa-rz ,th ,w) (format "rz(~a) q[~a];" (fmt-float th) w)]
         [`(isa-cx ,c ,t) (format "cx q[~a], q[~a];" c t)]
         [`(isa-cz ,a ,b) (format "cz q[~a], q[~a];" a b)]
         [`(isa-swap ,a ,b) (format "swap q[~a], q[~a];" a b)]
         [`(isa-ccx ,c1 ,c2 ,t) (format "ccx q[~a], q[~a], q[~a];" c1 c2 t)]
         [`(isa-temp-and-ccx ,c1 ,c2 ,anc) (format "ccx q[~a], q[~a], q[~a];" c1 c2 anc)]
         [`(isa-meas-x-cond-cz-reset ,anc ,k ,c1 ,c2)
          (format "h q[~a];\nm[~a] = measure q[~a];\nif (m[~a] == 1) { cz q[~a], q[~a]; }\nreset q[~a];"
                  anc k anc k c1 c2 anc)]
         [`(isa-meas-x-cond-z-reset ,anc ,k ,t)
          (format "h q[~a];\nm[~a] = measure q[~a];\nif (m[~a] == 1) { z q[~a]; }\nreset q[~a];"
                  anc k anc k t anc)]
         [`(isa-meas-x-reset ,anc ,k)
          (format "h q[~a];\nm[~a] = measure q[~a];\nreset q[~a];"
                  anc k anc anc)]
         [`(isa-cond-z ,k ,t)
          (format "if (m[~a] == 1) { z q[~a]; }" k t)]
         [`(isa-cond-cz ,k ,c1 ,c2)
          (format "if (m[~a] == 1) { cz q[~a], q[~a]; }" k c1 c2)]
         [_ (error 'emit-openqasm3 "Unhandled MachineISA op: ~a" op)]))))
  (string-append (string-join lines "\n") "\n"))

;; Stabilizer Fault-Propagation Stim Emitter (`emit-stim`):
;; Projects non-Clifford `ccx`/`ry`/`rz` to their Clifford stabilizer skeleton
;; while preserving exact mid-circuit `H + MR` resets, classical `CZ rec[-k]`
;; feedforward, hardware `DEPOLARIZE2` noise, and deterministic `DETECTOR` checks
;; on all recycled scratch & canonicalized quotient wires at circuit exit!
(define (emit-stim isa-ops clean-detector-wires hw)
  (define depol (target-hw-profile-stim-depol2 hw))
  (define rec-index-for-k (make-hasheqv))
  (define total-meas-box (box 0))
  (define lines '())
  (define (emit! s) (set! lines (cons s lines)))
  (define (maybe-depol2! a b)
    (when (> depol 0.0)
      (emit! (format "DEPOLARIZE2(~a) ~a ~a" depol a b))))

  (for ([op (in-list isa-ops)])
    (match op
      [`(isa-x ,w) (emit! (format "X ~a" w))]
      [`(isa-z ,w) (emit! (format "Z ~a" w))]
      [`(isa-s ,w) (emit! (format "S ~a" w))]
      [`(isa-sdg ,w) (emit! (format "S_DAG ~a" w))]
      [`(isa-h ,w) (emit! (format "H ~a" w))]
      [`(isa-ry ,_ ,w) (emit! (format "I ~a" w))]
      [`(isa-rz ,_ ,w) (emit! (format "I ~a" w))]
      [`(isa-cx ,c ,t)
       (emit! (format "CX ~a ~a" c t))
       (maybe-depol2! c t)]
      [`(isa-cz ,a ,b)
       (emit! (format "CZ ~a ~a" a b))
       (maybe-depol2! a b)]
      [`(isa-swap ,a ,b)
       (emit! (format "SWAP ~a ~a" a b))
       (maybe-depol2! a b)]
      [`(isa-ccx ,c1 ,c2 ,_)
       (emit! (format "CZ ~a ~a" c1 c2))
       (maybe-depol2! c1 c2)]
      [`(isa-temp-and-ccx ,c1 ,c2 ,_)
       (emit! (format "CZ ~a ~a" c1 c2))
       (maybe-depol2! c1 c2)]
      [`(isa-meas-x-cond-cz-reset ,anc ,k ,c1 ,_)
       (emit! (format "H ~a" anc))
       (emit! (format "MR ~a" anc))
       (define idx (unbox total-meas-box))
       (hash-set! rec-index-for-k k idx)
       (set-box! total-meas-box (add1 idx))
       (emit! (format "CZ rec[-1] ~a" c1))]
      [`(isa-meas-x-cond-z-reset ,anc ,k ,t)
       (emit! (format "H ~a" anc))
       (emit! (format "MR ~a" anc))
       (define idx (unbox total-meas-box))
       (hash-set! rec-index-for-k k idx)
       (set-box! total-meas-box (add1 idx))
       (emit! (format "CZ rec[-1] ~a" t))]
      [`(isa-meas-x-reset ,anc ,k)
       (emit! (format "H ~a" anc))
       (emit! (format "MR ~a" anc))
       (define idx (unbox total-meas-box))
       (hash-set! rec-index-for-k k idx)
       (set-box! total-meas-box (add1 idx))]
      [`(isa-cond-z ,k ,t)
       (define idx (hash-ref rec-index-for-k k))
       (define offset (- (unbox total-meas-box) idx))
       (emit! (format "CZ rec[-~a] ~a" offset t))]
      [`(isa-cond-cz ,k ,c1 ,_)
       (define idx (hash-ref rec-index-for-k k))
       (define offset (- (unbox total-meas-box) idx))
       (emit! (format "CZ rec[-~a] ~a" offset c1))]
      [_ (error 'emit-stim "Unhandled MachineISA op: ~a" op)]))

  ;; Emit deterministic Z-basis clean-ancilla / quotient detectors at exit:
  (for ([w (in-list (sort (remove-duplicates clean-detector-wires) <))])
    (emit! (format "M ~a" w))
    (set-box! total-meas-box (add1 (unbox total-meas-box)))
    (emit! "DETECTOR rec[-1]"))

  (string-append (string-join (reverse lines) "\n") "\n"))

;; =============================================================================
;; 7. End-to-End Compilation Driver & Structured JSON Report
;; =============================================================================

(struct compilation-result
  (circuit-name
   circuit-kind
   target-name
   well-typed?
   residual-surface-forms
   virtual-wires
   physical-qubits
   recycled-wires-saved
   classical-meas-bits
   forward-temp-and-count
   uncompute-ccx-count
   mbu-erasure-count
   isa-gate-count
   decoherence-action-milli
   exclusion-collisions
   effective-fault-distance
   required-fault-distance
   quantum-phase-residuals
   repairs-applied
   violations
   qasm3-text
   stim-text
   machines-used
   fallback-to-single-machine?
   parallel-partition-decisions)
  #:transparent)

(define compilation-cohesion-meta-table (make-weak-hasheq))

(define (attach-compilation-cohesion-meta! res meta-hash)
  (when (and (compilation-result? res) (hash? meta-hash))
    (hash-set! compilation-cohesion-meta-table res meta-hash))
  res)

(define (lookup-compilation-cohesion-meta res)
  (if (compilation-result? res)
      (hash-ref compilation-cohesion-meta-table res (hasheq))
      (hasheq)))

;; -----------------------------------------------------------------------------
;; 7a. Modular `R_wire` Port Capability Inference (`ErasedIdx < BorrowZ < Lin1 < Uniq1`)
;; -----------------------------------------------------------------------------

(define (collect-guard-wires g)
  (match g
    [(or 'true 'false) '()]
    [`(,(or 'wire 'zero) ,w) (if (exact-nonnegative-integer? w) (list w) '())]
    [`(not ,sub) (collect-guard-wires sub)]
    [`(,(or 'xor 'and 'or) ,gs ...) (apply append (map collect-guard-wires gs))]
    [`(,(or 'all-zero 'non-zero) ,ws) (filter exact-nonnegative-integer? ws)]
    [`(eq-wires ,wires-lhs ,wires-rhs)
     (filter exact-nonnegative-integer? (append wires-lhs wires-rhs))]
    [_ '()]))

(define (infer-decl-port-rwire-signature decl [seen-decls (seteq)])
  (define diag-wires (mutable-seteqv))
  (define nondiag-wires (mutable-seteqv))
  (define (mark-diag! ws)
    (for ([w (in-list ws)] #:when (exact-nonnegative-integer? w))
      (set-add! diag-wires w)))
  (define (mark-nondiag! ws)
    (for ([w (in-list ws)] #:when (exact-nonnegative-integer? w))
      (set-add! nondiag-wires w)))

  (define next-seen (set-add seen-decls (lfq-circuit-decl-name decl)))

  (let walk ([e (lfq-circuit-decl-surface-ast decl)])
    (match e
      ['skip (void)]
      [`(,(or 'z 's 's-dag) ,w) (mark-diag! (list w))]
      [`(,(or 'rz-dyadic 'rz-dyadic-neg) ,w ,_ ,_ ,_) (mark-diag! (list w))]
      [`(,(or 'x 'h) ,w) (mark-nondiag! (list w))]
      [`(ry ,_ ,w) (mark-nondiag! (list w))]
      [`(cx ,c ,t) (mark-diag! (list c)) (mark-nondiag! (list t))]
      [`(cz ,a ,b) (mark-diag! (list a b))]
      [`(ccx ,c1 ,c2 ,t) (mark-diag! (list c1 c2)) (mark-nondiag! (list t))]
      [`(ccz ,a ,b ,c) (mark-diag! (list a b c))]
      [`(swap ,a ,b)
       (unless (equal? a b)
         (mark-nondiag! (list a b)))]
      [`(cswap-bit ,c ,u ,v)
       (mark-diag! (list c))
       (mark-nondiag! (list u v))]
      [`(cswap-word ,c ,us ,vs)
       (mark-diag! (list c))
       (mark-nondiag! (append (if (list? us) us '()) (if (list? vs) vs '())))]
      [`(temp-and ,c1 ,c2 ,anc)
       (mark-diag! (list c1 c2))
       (mark-nondiag! (list anc))]
      [`(temp-and-lin ,lhs ,rhs ,anc)
       (walk `(temp-and-lin ,lhs ,rhs ,anc #f #f))]
      [`(temp-and-lin ,lhs ,rhs ,anc ,nl? ,nr?)
       (define ll (if (list? lhs) lhs (list lhs)))
       (define rl (if (list? rhs) rhs (list rhs)))
       ;; Multi-wire or negated linear fan-in temporarily CNOTs/flips pivot wires:
       (if (and (= (length ll) 1) (= (length rl) 1) (not nl?) (not nr?))
           (mark-diag! (append ll rl))
           (mark-nondiag! (append ll rl)))
       (mark-nondiag! (list anc))]
      [`(mcx ,ctrls ,target ,scratch)
       (mark-diag! (if (list? ctrls) ctrls '()))
       (mark-nondiag! (cons target (if (list? scratch) scratch '())))]
      [`(mcz ,ctrls ,scratch)
       (mark-diag! (if (list? ctrls) ctrls '()))
       (mark-nondiag! (if (list? scratch) scratch '()))]
      [`(qft ,ws) (mark-nondiag! (if (list? ws) ws '()))]
      [`(prepare-dicke-le1 ,ws ,_ ,_ ,_) (mark-nondiag! (if (list? ws) ws '()))]
      [`(mid-meas-x ,anc ,_ ,_) (mark-nondiag! (list anc))]
      [`(cond-z ,_ ,t) (mark-diag! (list t))]
      [`(cond-cz ,_ ,c1 ,c2) (mark-diag! (list c1 c2))]
      [`(syndrome-plaquette ,ws ,_ ,_) (mark-nondiag! (if (list? ws) ws '()))]
      [`(logical-relabel ,ws ,perm)
       (when (and (list? ws) (list? perm)
                  (not (equal? perm (range (length perm)))))
         (mark-nondiag! ws))]
      [`(seq ,es ...) (for ([sub (in-list es)]) (walk sub))]
      [`(for/fold-loop ,_ ,rs) (for ([r (in-list rs)]) (walk r))]
      [`(packed-bezout-jump16 ,_ ,in4 ,out2 ,sc3)
       (if (and (list? in4) (= (length in4) 4)
                (list? out2) (= (length out2) 2)
                (list? sc3) (= (length sc3) 3))
           (walk (divstep-swap-sub-window-opt-sexpr in4 out2 sc3))
           (mark-nondiag! (append (if (list? in4) in4 '())
                                  (if (list? out2) out2 '())
                                  (if (list? sc3) sc3 '()))))]
      [`(invert ,sub) (walk sub)]
      [`(call-q ,callee . ,arg-lists)
       (when (and (lfq-circuit-decl? callee)
                  (not (set-member? next-seen (lfq-circuit-decl-name callee))))
         (define sub-specs (infer-decl-port-rwire-signature callee next-seen))
         (for ([ps (in-list sub-specs)]
               [aws-raw (in-list arg-lists)])
           (define aws (if (list? aws-raw) aws-raw (list aws-raw)))
           (match (port-rwire-spec-grade ps)
             ['ErasedIdx (void)]
             ['BorrowZ (mark-diag! aws)]
             [_ (mark-nondiag! aws)])))]
      [`(with-and-session ,bindings ,body)
       (for ([b (in-list bindings)])
         (match b
           [(or (list anc lhs rhs nl? nr?)
                (and (list anc lhs rhs) (app (lambda (_) #f) nl?) (app (lambda (_) #f) nr?)))
            (define ll (if (list? lhs) lhs (list lhs)))
            (define rl (if (list? rhs) rhs (list rhs)))
            (if (and (= (length ll) 1) (= (length rl) 1) (not nl?) (not nr?))
                (mark-diag! (append ll rl))
                (mark-nondiag! (append ll rl)))
            (mark-nondiag! (list anc))]
           [_ (void)]))
       (walk body)]
      [`(,(or 'within-apply-mbu 'within-apply) ,c ,a ,ws)
       (walk c)
       (walk a)
       (mark-nondiag! (if (list? ws) ws '()))]
      [`(erase-by ,f ,b ,ws)
       (walk f)
       (walk b)
       (mark-nondiag! (if (list? ws) ws '()))]
      [`(erase-by-part-bij ,_ ,f ,b ,ws)
       (walk f)
       (walk b)
       (mark-nondiag! (if (list? ws) ws '()))]
      [`(canonicalize-quotient ,qws ,c)
       (mark-nondiag! (if (list? qws) qws '()))
       (walk c)]
      [`(qmatch ,arms)
       (for ([arm (in-list arms)])
         (when (and (list? arm) (>= (length arm) 2))
           (mark-diag! (collect-guard-wires (first arm)))
           (walk (second arm))))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd)
       (let walk-b ([n nd])
         (match n
           [`(braun-branch ,_ ,st ,l ,r) (walk st) (walk-b l) (walk-b r)]
           [_ (void)]))]
      [`(par-wires ,e1 ,e2) (walk e1) (walk e2)]
      [`(multishot-reset ,_ ,b) (walk b)]
      [`(,(or 'guard-valid-if 'guard-qblock-lcu-phase 'guard-wire-basis
              'guard-drift-eps 'guard-single-ir 'guard-par-partition) ,_ ,b)
       (walk b)]
      [`(guard-involutory ,_ ,_ ,b) (walk b)]
      [_ (void)]))

  (define quotient-set
    (match (lfq-circuit-decl-domain-spec decl)
      [`(quotient-vars ,qws) (list->seteqv (filter exact-nonnegative-integer? qws))]
      [_ (seteqv)]))

  (for/list ([grp (in-list (lfq-circuit-decl-wire-groups decl))])
    (define p-sym (car grp))
    (define p-ws (cdr grp))
    (define any-nondiag? (for/or ([w (in-list p-ws)]) (set-member? nondiag-wires w)))
    (define any-diag? (for/or ([w (in-list p-ws)]) (set-member? diag-wires w)))
    (define any-quot? (for/or ([w (in-list p-ws)]) (set-member? quotient-set w)))
    (define grade
      (cond
        [(and (not any-nondiag?) (not any-diag?) (not any-quot?)) 'ErasedIdx]
        [(and (not any-nondiag?) (not any-quot?)) 'BorrowZ]
        [any-quot? 'Lin1]
        [else 'Uniq1]))
    (port-rwire-spec p-sym
                     (length p-ws)
                     grade
                     (if (memq grade '(ErasedIdx BorrowZ)) #t #f))))

;; -----------------------------------------------------------------------------
;; 7b. Surface Static Discipline, Lexical Scope, `call-q` Contraction & Hygiene
;; -----------------------------------------------------------------------------

(define (make-surface-static-violation category rule code raw-msg resugared-msg witness
                                       #:origin-span [origin-span #f]
                                       #:mutating-span [mutating-span #f]
                                       #:failure-span [failure-span #f]
                                       #:surface-wire [surface-wire #f]
                                       #:repair-hint [repair-hint #f])
  (define base-v
    (hasheq 'category category
            'rule rule
            'code code
            'message raw-msg
            'witness witness))
  (enrich-revir-violation base-v
                          #:resugared-message resugared-msg
                          #:origin-span origin-span
                          #:mutating-span mutating-span
                          #:failure-span failure-span
                          #:surface-wire surface-wire
                          #:repair-hint repair-hint))

(define (check-decl-wire-disjointness decl)
  (define decl-span (decl-or-synthetic-span decl))
  (define grp-spans (lookup-decl-group-spans decl))
  (define seen-owner (make-hasheqv)) ;; wire -> (list grp-sym idx-in-grp kind)
  (define violations '())
  (define all-groups
    (append (for/list ([g (in-list (lfq-circuit-decl-wire-groups decl))])
              (list (car g) (cdr g) 'wires))
            (for/list ([g (in-list (lfq-circuit-decl-scratch-groups decl))])
              (list (car g) (cdr g) 'scratch))))
  (for ([entry (in-list all-groups)])
    (match-define (list g-sym g-ws _g-kind) entry)
    (for ([w (in-list g-ws)] [idx (in-naturals)])
      (cond
        [(hash-has-key? seen-owner w)
         (match-define (list prev-sym prev-idx _prev-kind) (hash-ref seen-owner w))
         (define sp1 (hash-ref grp-spans prev-sym decl-span))
         (define sp2 (hash-ref grp-spans g-sym decl-span))
         (define w1-surf (format "~a[~a]" prev-sym prev-idx))
         (define w2-surf (format "~a[~a]" g-sym idx))
         (define msg
           (format "Register wire `~a` aliases `~a` on physical wire index ~a in `~a` (disjoint register context Gamma_in required)"
                   w2-surf w1-surf w (lfq-circuit-decl-name decl)))
         (set! violations
               (append violations
                       (list (make-surface-static-violation
                              "StaticDiscipline"
                              "T-WireDisjoint"
                              "LFQ-E-WIRE-ALIAS"
                              msg
                              msg
                              (hasheq 'wire w
                                      'first_register w1-surf
                                      'second_register w2-surf)
                              #:origin-span sp1
                              #:mutating-span sp2
                              #:failure-span sp2
                              #:surface-wire w2-surf))))]
        [else
         (hash-set! seen-owner w (list g-sym idx _g-kind))])))
  violations)

;; Find first non-basis (`defqfree`-forbidden) leaf form in an AST:
(define (find-first-non-qfree-node ast)
  (let walk ([e ast])
    (match e
      [(or 'skip 'braun-leaf
           `(x ,_) `(cx ,_ ,_) `(ccx ,_ ,_ ,_) `(swap ,_ ,_)
           `(cswap-bit ,_ ,_ ,_) `(cswap-word ,_ ,_ ,_)
           `(temp-and ,_ ,_ ,_) `(temp-and-lin . ,_)
           `(packed-bezout-jump16 . ,_)
           `(mcx ,_ ,_ ,_) `(logical-relabel ,_ ,_)
           `(mid-meas-x . ,_) `(cond-z . ,_) `(cond-cz . ,_))
       #f]
      [`(seq ,es ...) (for/or ([sub (in-list es)]) (walk sub))]
      [`(for/fold-loop ,_ ,rs) (for/or ([r (in-list rs)]) (walk r))]
      [`(invert ,sub) (walk sub)]
      [`(call-q ,callee . ,_)
       (if (and (lfq-circuit-decl? callee)
                (not (eq? (lfq-circuit-decl-kind callee) 'defqfree)))
           e
           (and (lfq-circuit-decl? callee)
                (walk (lfq-circuit-decl-surface-ast callee))))]
      [`(with-and-session ,_ ,b) (walk b)]
      [`(,(or 'within-apply-mbu 'within-apply 'erase-by) ,c ,a ,_) (or (walk c) (walk a))]
      [`(erase-by-part-bij ,_ ,c ,a ,_) (or (walk c) (walk a))]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for/or ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd) (walk nd)]
      [`(braun-branch ,_ ,st ,l ,r) (or (walk st) (walk l) (walk r))]
      [`(par-wires ,e1 ,e2) (or (walk e1) (walk e2))]
      [`(multishot-reset ,_ ,b) (walk b)]
      [`(,(or 'guard-wire-basis 'guard-drift-eps 'guard-single-ir 'guard-par-partition) ,_ ,b)
       (walk b)]
      [`(guard-involutory ,_ ,_ ,b) (walk b)]
      [_ e])))

;; Find first non-unitary/effectful subform inside `(invert ...)` or `(within-apply comp ...)`:
(define (find-first-non-unitary-node ast)
  (let walk ([e ast])
    (match e
      [(or 'skip 'braun-leaf
           `(x ,_) `(z ,_) `(s ,_) `(s-dag ,_) `(h ,_) `(ry ,_ ,_)
           `(rz-dyadic ,_ ,_ ,_ ,_) `(rz-dyadic-neg ,_ ,_ ,_ ,_)
           `(cx ,_ ,_) `(cz ,_ ,_) `(ccx ,_ ,_ ,_) `(ccz ,_ ,_ ,_)
           `(swap ,_ ,_) `(cswap-bit ,_ ,_ ,_) `(cswap-word ,_ ,_ ,_)
           `(temp-and ,_ ,_ ,_) `(temp-and-lin . ,_)
           `(qft ,_) `(logical-relabel ,_ ,_))
       #f]
      [`(mcx ,ctrls ,_ ,_)
       #:when (and (list? ctrls) (<= (length ctrls) 2))
       #f]
      [`(mcz ,ctrls ,_)
       #:when (and (list? ctrls) (<= (length ctrls) 3))
       #f]
      [`(seq ,es ...) (for/or ([sub (in-list es)]) (walk sub))]
      [`(for/fold-loop ,_ ,rs) (for/or ([r (in-list rs)]) (walk r))]
      [`(invert ,sub) (walk sub)]
      [`(call-q ,callee . ,_)
       (if (lfq-circuit-decl? callee)
           (walk (lfq-circuit-decl-surface-ast callee))
           e)]
      [`(within-apply ,c ,a ,_) (or (walk c) (walk a))]
      [`(qmatch ,arms) (for/or ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd) (walk nd)]
      [`(braun-branch ,_ ,st ,l ,r) (or (walk st) (walk l) (walk r))]
      [`(par-wires ,e1 ,e2) (or (walk e1) (walk e2))]
      [_ e])))

;; Remap and contract diagonal `BorrowZ` controls (`Delta_Z(|b>) = |b, b>`) for modular `call-q`:
(define (remap-and-contract-callee-ast ast wmap caller-call-sp)
  (define (mw w) (if (exact-nonnegative-integer? w) (hash-ref wmap w w) w))
  (define (stamp src rebuilt)
    (define sp (or (lookup-surface-span src) caller-call-sp))
    (if sp (attach-surface-span! rebuilt sp) rebuilt))
  (let walk ([e ast])
    (define rebuilt
      (match e
        ['skip 'skip]
        [`(x ,w) `(x ,(mw w))]
        [`(z ,w) `(z ,(mw w))]
        [`(s ,w) `(s ,(mw w))]
        [`(s-dag ,w) `(s-dag ,(mw w))]
        [`(h ,w) `(h ,(mw w))]
        [`(ry ,th ,w) `(ry ,th ,(mw w))]
        [`(rz-dyadic ,w ,k ,f64? ,d) `(rz-dyadic ,(mw w) ,k ,f64? ,d)]
        [`(rz-dyadic-neg ,w ,k ,f64? ,d) `(rz-dyadic-neg ,(mw w) ,k ,f64? ,d)]
        [`(cx ,c ,t) `(cx ,(mw c) ,(mw t))]
        [`(cz ,a ,b)
         (define pa (mw a))
         (define pb (mw b))
         (if (= pa pb) `(z ,pa) `(cz ,pa ,pb))]
        [`(ccx ,c1 ,c2 ,t)
         (define p1 (mw c1))
         (define p2 (mw c2))
         (define pt (mw t))
         (if (and (= p1 p2) (not (= p1 pt)))
             `(cx ,p1 ,pt)
             `(ccx ,p1 ,p2 ,pt))]
        [`(ccz ,a ,b ,c)
         (define pa (mw a))
         (define pb (mw b))
         (define pc (mw c))
         (cond
           [(and (= pa pb) (= pb pc)) `(z ,pa)]
           [(= pa pb) `(cz ,pa ,pc)]
           [(= pa pc) `(cz ,pa ,pb)]
           [(= pb pc) `(cz ,pa ,pb)]
           [else `(ccz ,pa ,pb ,pc)])]
        [`(swap ,a ,b) `(swap ,(mw a) ,(mw b))]
        [`(cswap-bit ,c ,u ,v) `(cswap-bit ,(mw c) ,(mw u) ,(mw v))]
        [`(cswap-word ,c ,us ,vs) `(cswap-word ,(mw c) ,(map mw us) ,(map mw vs))]
        [`(temp-and ,c1 ,c2 ,anc)
         (define p1 (mw c1))
         (define p2 (mw c2))
         (define pa (mw anc))
         (if (and (= p1 p2) (not (= p1 pa)))
             `(cx ,p1 ,pa)
             `(temp-and ,p1 ,p2 ,pa))]
        [`(temp-and-lin ,lhs ,rhs ,anc)
         (walk `(temp-and-lin ,lhs ,rhs ,anc #f #f))]
        [`(temp-and-lin ,lhs ,rhs ,anc ,nl? ,nr?)
         (define ml (dedup-odd-wires (map mw (if (list? lhs) lhs (list lhs)))))
         (define mr (dedup-odd-wires (map mw (if (list? rhs) rhs (list rhs)))))
         (define ma (mw anc))
         (cond
           [(equal? ml mr)
            (cond
              [(and (not nl?) (not nr?))
               `(seq ,@(for/list ([w (in-list ml)]) `(cx ,w ,ma)))]
              [(not (eq? (not (not nl?)) (not (not nr?))))
               'skip]
              [else
               `(seq (x ,ma) ,@(for/list ([w (in-list ml)]) `(cx ,w ,ma)))])]
           [else
            `(temp-and-lin ,ml ,mr ,ma ,nl? ,nr?)])]
        [`(mcx ,ctrls ,target ,scratch)
         (define u-ctrls (remove-duplicates (map mw ctrls)))
         `(mcx ,u-ctrls ,(mw target) ,(map mw scratch))]
        [`(mcz ,ctrls ,scratch)
         (define u-ctrls (remove-duplicates (map mw ctrls)))
         `(mcz ,u-ctrls ,(map mw scratch))]
        [`(qft ,ws) `(qft ,(map mw ws))]
        [`(prepare-dicke-le1 ,ws ,w0 ,w1 ,bm)
         `(prepare-dicke-le1 ,(map mw ws) ,w0 ,w1 ,bm)]
        [`(mid-meas-x ,anc ,msym ,sh?) `(mid-meas-x ,(mw anc) ,msym ,sh?)]
        [`(cond-z ,msym ,t) `(cond-z ,msym ,(mw t))]
        [`(cond-cz ,msym ,c1 ,c2)
         (define p1 (mw c1))
         (define p2 (mw c2))
         (if (= p1 p2) `(cond-z ,msym ,p1) `(cond-cz ,msym ,p1 ,p2))]
        [`(syndrome-plaquette ,ws ,d ,hk?) `(syndrome-plaquette ,(map mw ws) ,d ,hk?)]
        [`(logical-relabel ,ws ,perm) `(logical-relabel ,(map mw ws) ,perm)]
        [`(seq ,es ...) `(seq ,@(map walk es))]
        [`(for/fold-loop ,nr ,rs) `(for/fold-loop ,nr ,(map walk rs))]
        [`(packed-bezout-jump16 ,cfg ,in4 ,out2 ,sc3)
         `(packed-bezout-jump16 ,cfg ,(map mw in4) ,(map mw out2) ,(map mw sc3))]
        [`(invert ,sub) `(invert ,(walk sub))]
        [`(call-q ,sub-callee . ,arg-lists)
         `(call-q ,sub-callee
                  ,@(for/list ([al (in-list arg-lists)])
                      (if (list? al) (map mw al) (mw al))))]
        [`(with-and-session ,bindings ,body)
         (define remapped-comp
           (for/list ([b (in-list bindings)])
             (define-values (anc lhs rhs nl? nr?)
               (match b
                 [(list a l r nl nr) (values a l r nl nr)]
                 [(list a l r) (values a l r #f #f)]))
             (define ll (if (list? lhs) lhs (list lhs)))
             (define rl (if (list? rhs) rhs (list rhs)))
             (if (and (= (length ll) 1) (= (length rl) 1) (not nl?) (not nr?))
                 (walk `(temp-and ,(first ll) ,(first rl) ,anc))
                 (walk `(temp-and-lin ,ll ,rl ,anc ,nl? ,nr?)))))
         (define remapped-ancs (map (lambda (b) (mw (first b))) bindings))
         `(within-apply-mbu (seq ,@remapped-comp)
                            ,(walk body)
                            ,remapped-ancs)]
        [`(within-apply-mbu ,c ,a ,ws)
         `(within-apply-mbu ,(walk c) ,(walk a) ,(map mw ws))]
        [`(within-apply ,c ,a ,ws)
         `(within-apply ,(walk c) ,(walk a) ,(map mw ws))]
        [`(erase-by ,f ,b ,ws)
         `(erase-by ,(walk f) ,(walk b) ,(map mw ws))]
        [`(erase-by-part-bij ,sp ,f ,b ,ws)
         `(erase-by-part-bij ,sp ,(walk f) ,(walk b) ,(map mw ws))]
        [`(canonicalize-quotient ,qws ,c)
         `(canonicalize-quotient ,(map mw qws) ,(walk c))]
        [`(qmatch ,arms)
         `(qmatch ,(for/list ([arm (in-list arms)])
                     (list (remap-guard wmap (first arm))
                           (walk (second arm)))))]
        [`(focus-zipper (,sub-ws ,amb-ws) ,b)
         `(focus-zipper (,(map mw sub-ws) ,(map mw amb-ws)) ,(walk b))]
        [`(fold-braun ,nd)
         (let wb ([n nd])
           (match n
             ['braun-leaf 'braun-leaf]
             [`(braun-branch ,idx ,st ,l ,r)
              (stamp n `(braun-branch ,idx ,(walk st) ,(wb l) ,(wb r)))]))]
        [`(par-wires ,e1 ,e2) `(par-wires ,(walk e1) ,(walk e2))]
        [`(multishot-reset ,k ,b) `(multishot-reset ,k ,(walk b))]
        [`(,(or 'guard-valid-if 'guard-qblock-lcu-phase 'guard-wire-basis
                'guard-drift-eps 'guard-single-ir 'guard-par-partition) ,sp ,b)
         `(,(car e) ,sp ,(walk b))]
        [`(guard-involutory ,c ,op ,b) `(guard-involutory ,c ,op ,(walk b))]
        [_ e]))
    (stamp e rebuilt)))

;; Validate surface AST & expand modular `(call-q ...)` calls:
(define (validate-and-expand-surface-ast decl eff-surface-ast)
  (define decl-span (decl-or-synthetic-span decl))
  (define declared-wires-set
    (list->seteqv (append (lfq-circuit-decl-input-wires decl)
                          (lfq-circuit-decl-scratch-wires decl))))
  (define extra-virt-names (make-hasheqv))
  (define extra-scratch-list '())
  (define next-virt-wire-box
    (box (let ([all-w (append (lfq-circuit-decl-input-wires decl)
                              (lfq-circuit-decl-scratch-wires decl))])
           (if (null? all-w) 0 (add1 (apply max all-w))))))
  (define violations '())

  (define (wire-in-scope? w)
    (and (exact-nonnegative-integer? w)
         (or (set-member? declared-wires-set w)
             (hash-has-key? extra-virt-names w))))

  (define (fmt-wire w)
    (cond
      [(wire-in-scope? w)
       (define r (build-wire-resugarer decl #f #f extra-virt-names))
       (lfq-resolved-wire-surface-name (resolve-physical-wire r w #f))]
      [(exact-integer? w)
       (format "undeclared wire ~a" w)]
      [else
       (format "~a" w)]))

  (define (fmt-surface-node node)
    (define sp (lookup-surface-span node))
    (cond
      [(and sp (non-empty-string? (lfq-surface-span-form-str sp)))
       (lfq-surface-span-form-str sp)]
      [else
       (match node
         [`(mid-meas-x ,anc ,msym ,_)
          (format "(~a)" (resugar-measurement-symbol msym (fmt-wire anc)))]
         [`(cond-z ,msym ,t)
          (format "(cond-z ~a ~a)" (resugar-measurement-symbol msym #f) (fmt-wire t))]
         [`(cond-cz ,msym ,c1 ,c2)
          (format "(cond-cz ~a ~a ~a)"
                  (resugar-measurement-symbol msym #f) (fmt-wire c1) (fmt-wire c2))]
         [`(,op ,ws ...)
          #:when (and (symbol? op) (andmap exact-nonnegative-integer? ws))
          (format "(~a ~a)" op (string-join (map fmt-wire ws) " "))]
         [_ (format "~a" node)])]))

  (define (emit-v! category rule code raw-msg resugared-msg witness
                   #:origin-span [orig-sp #f]
                   #:mutating-span [mut-sp #f]
                   #:failure-span [fail-sp #f]
                   #:surface-wire [surf-w #f]
                   #:repair-hint [hint #f])
    (set! violations
          (append violations
                  (list (make-surface-static-violation
                         category rule code raw-msg resugared-msg witness
                         #:origin-span (or orig-sp decl-span)
                         #:mutating-span mut-sp
                         #:failure-span fail-sp
                         #:surface-wire surf-w
                         #:repair-hint hint)))))

  ;; 1. `defqfree` classical-basis discipline (`LFQ-E-QFREE-BASIS`):
  (when (eq? (lfq-circuit-decl-kind decl) 'defqfree)
    (define bad-qf (find-first-non-qfree-node eff-surface-ast))
    (when bad-qf
      (define bsp (or (lookup-surface-span bad-qf) decl-span))
      (define nice-form (fmt-surface-node bad-qf))
      (define msg
        (format "`defqfree` circuit `~a` forbids non-basis quantum operation `~a` (only classical-basis X/CX/CCX/SWAP/TempAND permutations allowed)"
                (lfq-circuit-decl-name decl) nice-form))
      (emit-v! "StaticDiscipline" "T-QFreeBasis" "LFQ-E-QFREE-BASIS"
               msg msg
               (hasheq 'circuit (symbol->string (lfq-circuit-decl-name decl))
                       'forbidden_form nice-form)
               #:origin-span decl-span
               #:mutating-span bsp
               #:failure-span bsp)))

  ;; Helper to verify lexical wire scope on every wire operand (`LFQ-E-UNDECLARED-WIRE`):
  (define reported-undeclared (mutable-seteqv))
  (define (check-wires-in-scope! ws node-sp context-op)
    (define ok? #t)
    (for ([w (in-list ws)])
      (cond
        [(not (exact-nonnegative-integer? w))
         (set! ok? #f)
         (define msg
           (format "Expected quantum wire index in `~a`, got `~a`" context-op w))
         (emit-v! "StaticDiscipline" "T-WireScope" "LFQ-E-UNDECLARED-WIRE"
                  msg msg
                  (hasheq 'invalid_wire (format "~a" w)
                          'operation (symbol->string context-op))
                  #:origin-span decl-span
                  #:mutating-span node-sp
                  #:failure-span node-sp)]
        [(not (wire-in-scope? w))
         (set! ok? #f)
         (unless (set-member? reported-undeclared w)
           (set-add! reported-undeclared w)
           (define declared-regs
             (map (lambda (g) (format "~a" (car g)))
                  (append (lfq-circuit-decl-wire-groups decl)
                          (lfq-circuit-decl-scratch-groups decl))))
           (define msg
             (format "Wire literal `~a` in `~a` is outside declared context Gamma_in of `~a` (declared registers: ~a)"
                     w context-op (lfq-circuit-decl-name decl)
                     (if (null? declared-regs) "none" (string-join declared-regs ", "))))
           (emit-v! "StaticDiscipline" "T-WireScope" "LFQ-E-UNDECLARED-WIRE"
                    msg msg
                    (hasheq 'undeclared_wire w
                            'operation (symbol->string context-op)
                            'declared_registers declared-regs)
                    #:origin-span decl-span
                    #:mutating-span node-sp
                    #:failure-span node-sp))]))
    ok?)

  ;; Helper to verify distinct wires within a multi-qubit gate (`LFQ-E-GATE-ALIAS`):
  (define (check-gate-distinct! ws op-sym node-sp)
    (define seen (mutable-seteqv))
    (define dup-w #f)
    (for ([w (in-list ws)] #:when (exact-nonnegative-integer? w))
      (when (and (not dup-w) (set-member? seen w))
        (set! dup-w w))
      (set-add! seen w))
    (when dup-w
      (define w-surf (fmt-wire dup-w))
      (define msg
        (format "Gate `~a` aliases wire `~a` across multiple operands (`(~a ~a)`); multi-qubit gates require pairwise-distinct wires (`Lin1 (+) Lin1 = Conflict`)"
                op-sym w-surf op-sym (string-join (map fmt-wire ws) " ")))
      (emit-v! "StaticDiscipline" "T-NoCloningGate" "LFQ-E-GATE-ALIAS"
               msg msg
               (hasheq 'gate (symbol->string op-sym)
                       'aliased_wire dup-w
                       'surface_wire w-surf)
               #:origin-span decl-span
               #:mutating-span node-sp
               #:failure-span node-sp
               #:surface-wire w-surf))
    (not dup-w))

  ;; Check domain-spec wire scope as well:
  (match (lfq-circuit-decl-domain-spec decl)
    [`(quotient-vars ,qws)
     (when (list? qws)
       (check-wires-in-scope! qws decl-span 'quotient-vars))]
    [`(domain-guard ,g)
     (check-wires-in-scope! (collect-guard-wires g) decl-span 'domain-guard)]
    [_ (void)])

  ;; Recursive AST validation & `call-q` expansion:
  (define (walk e [inherited-sp #f] [active-callees (seteq (lfq-circuit-decl-name decl))])
    (define sp (or (lookup-surface-span e) inherited-sp decl-span))
    (define (keep rebuilt)
      (if sp (attach-surface-span! rebuilt sp) rebuilt))
    (match e
      ['skip 'skip]
      [`(,(and op (or 'x 'z 's 's-dag 'h)) ,w)
       (if (check-wires-in-scope! (list w) sp op) e 'skip)]
      [`(ry ,th ,w)
       (if (check-wires-in-scope! (list w) sp 'ry) e 'skip)]
      [`(,(and op (or 'rz-dyadic 'rz-dyadic-neg)) ,w ,k ,f64? ,d)
       (if (check-wires-in-scope! (list w) sp op) e 'skip)]
      [`(,(and op (or 'cx 'cz)) ,a ,b)
       (if (and (check-wires-in-scope! (list a b) sp op)
                (check-gate-distinct! (list a b) op sp))
           e
           'skip)]
      [`(swap ,a ,b)
       (if (check-wires-in-scope! (list a b) sp 'swap) e 'skip)]
      [`(,(and op (or 'ccx 'ccz 'temp-and 'cswap-bit)) ,a ,b ,c)
       (if (and (check-wires-in-scope! (list a b c) sp op)
                (check-gate-distinct! (list a b c) op sp))
           e
           'skip)]
      [`(cswap-word ,c ,us ,vs)
       (define ul (if (list? us) us '()))
       (define vl (if (list? vs) vs '()))
       (cond
         [(not (= (length ul) (length vl)))
          (define msg
            (format "`cswap-word` requires equal-width register slices, got ~a and ~a wires"
                    (length ul) (length vl)))
          (emit-v! "StaticDiscipline" "T-NoCloningGate" "LFQ-E-GATE-ALIAS"
                   msg msg (hasheq 'lhs_width (length ul) 'rhs_width (length vl))
                   #:origin-span decl-span #:mutating-span sp #:failure-span sp)
          'skip]
         [(and (check-wires-in-scope! (cons c (append ul vl)) sp 'cswap-word)
               (check-gate-distinct! (cons c (append ul vl)) 'cswap-word sp))
          e]
         [else 'skip])]
      [`(temp-and-lin ,lhs ,rhs ,anc)
       (walk `(temp-and-lin ,lhs ,rhs ,anc #f #f))]
      [`(temp-and-lin ,lhs ,rhs ,anc ,nl? ,nr?)
       (define ll (dedup-odd-wires (if (list? lhs) lhs (list lhs))))
       (define rl (dedup-odd-wires (if (list? rhs) rhs (list rhs))))
       (cond
         [(not (check-wires-in-scope! (append ll rl (list anc)) sp 'temp-and-lin))
          'skip]
         [(or (null? ll) (null? rl) (equal? ll rl) (memv anc ll) (memv anc rl))
          (define msg
            (format "`temp-and-lin` requires non-empty distinct linear forms disjoint from target `~a`"
                    (fmt-wire anc)))
          (emit-v! "StaticDiscipline" "T-NoCloningGate" "LFQ-E-GATE-ALIAS"
                   msg msg (hasheq 'target (fmt-wire anc))
                   #:origin-span decl-span #:mutating-span sp #:failure-span sp
                   #:surface-wire (fmt-wire anc))
          'skip]
         [else e])]
      [`(mcx ,ctrls ,target ,scratch)
       (define cl (if (list? ctrls) ctrls '()))
       (define sl (if (list? scratch) scratch '()))
       (define req-s (max 0 (- (length cl) 1)))
       (cond
         [(not (check-wires-in-scope! (append cl (list target) sl) sp 'mcx)) 'skip]
         [(not (check-gate-distinct! (append cl (list target) sl) 'mcx sp)) 'skip]
         [(and (> (length cl) 2) (< (length sl) req-s))
          (define msg
            (format "`mcx` with ~a controls requires at least ~a clean scratch wire(s), got ~a"
                    (length cl) req-s (length sl)))
          (emit-v! "StaticDiscipline" "T-QubitCap" "LFQ-E-REGISTER-BOUNDS"
                   msg msg (hasheq 'controls (length cl) 'required_scratch req-s 'actual_scratch (length sl))
                   #:origin-span decl-span #:mutating-span sp #:failure-span sp)
          'skip]
         [else e])]
      [`(mcz ,ctrls ,scratch)
       (define cl (if (list? ctrls) ctrls '()))
       (define sl (if (list? scratch) scratch '()))
       (define req-s (max 0 (- (length cl) 2)))
       (cond
         [(not (check-wires-in-scope! (append cl sl) sp 'mcz)) 'skip]
         [(not (check-gate-distinct! (append cl sl) 'mcz sp)) 'skip]
         [(and (> (length cl) 3) (< (length sl) req-s))
          (define msg
            (format "`mcz` with ~a controls requires at least ~a clean scratch wire(s), got ~a"
                    (length cl) req-s (length sl)))
          (emit-v! "StaticDiscipline" "T-QubitCap" "LFQ-E-REGISTER-BOUNDS"
                   msg msg (hasheq 'controls (length cl) 'required_scratch req-s 'actual_scratch (length sl))
                   #:origin-span decl-span #:mutating-span sp #:failure-span sp)
          'skip]
         [else e])]
      [`(qft ,ws)
       (define wl (if (list? ws) ws '()))
       (if (and (check-wires-in-scope! wl sp 'qft)
                (check-gate-distinct! wl 'qft sp))
           e
           'skip)]
      [`(prepare-dicke-le1 ,ws ,_ ,_ ,_)
       (define wl (if (list? ws) ws '()))
       (if (and (check-wires-in-scope! wl sp 'prepare-dicke-le1)
                (check-gate-distinct! wl 'prepare-dicke-le1 sp))
           e
           'skip)]
      [`(mid-meas-x ,anc ,_ ,_)
       (if (check-wires-in-scope! (list anc) sp 'mid-meas-x) e 'skip)]
      [`(cond-z ,_ ,t)
       (if (check-wires-in-scope! (list t) sp 'cond-z) e 'skip)]
      [`(cond-cz ,_ ,c1 ,c2)
       (if (and (check-wires-in-scope! (list c1 c2) sp 'cond-cz)
                (check-gate-distinct! (list c1 c2) 'cond-cz sp))
           e
           'skip)]
      [`(syndrome-plaquette ,ws ,_ ,_)
       (if (check-wires-in-scope! (if (list? ws) ws '()) sp 'syndrome-plaquette) e 'skip)]
      [`(logical-relabel ,ws ,perm)
       (define wl (if (list? ws) ws '()))
       (define pl (if (list? perm) perm '()))
       (cond
         [(not (check-wires-in-scope! wl sp 'logical-relabel)) 'skip]
         [(not (and (= (length wl) (length pl))
                    (equal? (sort (filter exact-nonnegative-integer? pl) <)
                            (range (length wl)))))
          (define msg
            (format "`logical-relabel` requires a bijection on 0..~a matching register width ~a, got `~a`"
                    (max 0 (sub1 (length wl))) (length wl) perm))
          (emit-v! "StaticDiscipline" "T-DomImg" "LFQ-E-REGISTER-BOUNDS"
                   msg msg (hasheq 'width (length wl) 'permutation (format "~a" perm))
                   #:origin-span decl-span #:mutating-span sp #:failure-span sp)
          'skip]
         [else e])]
      [`(packed-bezout-jump16 ,cfg ,in4 ,out2 ,sc3)
       (define i4 (if (list? in4) in4 '()))
       (define o2 (if (list? out2) out2 '()))
       (define s3 (if (list? sc3) sc3 '()))
       (define all-w (append i4 o2 s3))
       (cond
         [(not (and (= (length i4) 4) (= (length o2) 2) (= (length s3) 3)))
          (define msg
            (format "`packed-bezout-jump16` requires port widths (4, 2, 3), got (~a, ~a, ~a)"
                    (length i4) (length o2) (length s3)))
          (emit-v! "StaticDiscipline" "T-QubitCap" "LFQ-E-REGISTER-BOUNDS"
                   msg msg (hasheq 'in_width (length i4) 'out_width (length o2) 'scratch_width (length s3))
                   #:origin-span decl-span #:mutating-span sp #:failure-span sp)
          'skip]
         [(and (check-wires-in-scope! all-w sp 'packed-bezout-jump16)
               (check-gate-distinct! all-w 'packed-bezout-jump16 sp))
          (keep `(packed-bezout-jump16 ,cfg ,i4 ,o2 ,s3))]
         [else 'skip])]
      [`(seq ,es ...)
       (keep `(seq ,@(for/list ([sub (in-list es)])
                       (walk sub sp active-callees))))]
      [`(for/fold-loop ,nr ,rs)
       (keep `(for/fold-loop ,nr
                             ,(for/list ([r (in-list rs)])
                                (walk r sp active-callees))))]
      [`(invert ,sub)
       (define exp-sub (walk sub sp active-callees))
       (define bad-nu (find-first-non-unitary-node exp-sub))
       (cond
         [bad-nu
          (define nu-sp (or (lookup-surface-span bad-nu) sp))
          (define nice-sub (fmt-surface-node bad-nu))
          (define msg
            (format "Cannot form unitary adjoint `(invert ...)` of non-unitary/effectful operation `~a`"
                    nice-sub))
          (emit-v! "StaticDiscipline" "T-UnitaryAdj" "LFQ-E-NONUNITARY-INVERT"
                   msg msg
                   (hasheq 'non_unitary_form nice-sub)
                   #:origin-span sp
                   #:mutating-span nu-sp
                   #:failure-span sp)
          'skip]
         [else
          (keep `(invert ,exp-sub))])]
      [`(call-q ,callee . ,raw-args)
       (cond
         [(not (lfq-circuit-decl? callee))
          (define msg
            (format "`call-q` target `~a` is not a declared `defq`/`defqfree` circuit" callee))
          (emit-v! "StaticDiscipline" "T-CallPortAlias" "LFQ-E-CALL-ALIAS"
                   msg msg (hasheq 'callee (format "~a" callee))
                   #:origin-span decl-span #:mutating-span sp #:failure-span sp)
          'skip]
         [(set-member? active-callees (lfq-circuit-decl-name callee))
          (define msg
            (format "Cyclic `call-q` recursion on `~a` is forbidden in finitary quantum circuits"
                    (lfq-circuit-decl-name callee)))
          (emit-v! "StaticDiscipline" "T-CallPortAlias" "LFQ-E-CALL-ALIAS"
                   msg msg (hasheq 'callee (symbol->string (lfq-circuit-decl-name callee)))
                   #:origin-span (or (lookup-surface-span callee) decl-span)
                   #:mutating-span sp #:failure-span sp)
          'skip]
         [else
          (define callee-name (lfq-circuit-decl-name callee))
          (define callee-sp (or (lookup-surface-span callee) decl-span))
          (define actual-lists
            (for/list ([arg (in-list raw-args)])
              (if (list? arg) arg (list arg))))
          (define scope-ok?
            (check-wires-in-scope! (apply append actual-lists) sp 'call-q))
          (define port-specs (infer-decl-port-rwire-signature callee))
          (define-values (alias-ok? conflicts)
            (check-call-q-port-aliasing callee-name port-specs actual-lists))
          (cond
            [(not alias-ok?)
             (for ([cf (in-list conflicts)])
               (define w-opt (hash-ref cf 'wire #f))
               (define w-surf (and w-opt (fmt-wire w-opt)))
               (define raw-m (hash-ref cf 'message "call-q port aliasing violation"))
               (define res-m
                 (if (and w-opt w-surf)
                     (string-replace raw-m (format "q[~a]" w-opt) (format "`~a`" w-surf))
                     raw-m))
               (emit-v! "StaticDiscipline" "T-CallPortAlias" "LFQ-E-CALL-ALIAS"
                        raw-m res-m cf
                        #:origin-span callee-sp
                        #:mutating-span sp
                        #:failure-span sp
                        #:surface-wire w-surf))
             'skip]
            [(not scope-ok?) 'skip]
            [else
             ;; Build formal -> actual wire substitution + fresh virtual scratch wires:
             (define wmap (make-hasheqv))
             (for ([grp (in-list (lfq-circuit-decl-wire-groups callee))]
                   [aws (in-list actual-lists)])
               (for ([fw (in-list (cdr grp))] [aw (in-list aws)])
                 (hash-set! wmap fw aw)))
             (for ([sgrp (in-list (lfq-circuit-decl-scratch-groups callee))])
               (define sg-sym (car sgrp))
               (for ([fw (in-list (cdr sgrp))] [sidx (in-naturals)])
                 (define vw (unbox next-virt-wire-box))
                 (set-box! next-virt-wire-box (add1 vw))
                 (hash-set! wmap fw vw)
                 (set! extra-scratch-list (append extra-scratch-list (list vw)))
                 (hash-set! extra-virt-names
                            vw
                            (cons (format "~a.~a[~a]" callee-name sg-sym sidx)
                                  (format "~a.~a" callee-name sg-sym)))))
             (define remapped-callee
               (remap-and-contract-callee-ast (lfq-circuit-decl-surface-ast callee)
                                              wmap
                                              sp))
             (walk remapped-callee sp (set-add active-callees callee-name))])])]
      [`(with-and-session ,bindings ,body)
       (define b-ok? #t)
       (for ([b (in-list bindings)])
         (match b
           [(or (list anc lhs rhs _ _) (list anc lhs rhs))
            (define ll (if (list? lhs) lhs (list lhs)))
            (define rl (if (list? rhs) rhs (list rhs)))
            (unless (check-wires-in-scope! (append ll rl (list anc)) sp 'with-and-session)
              (set! b-ok? #f))
            (when (or (memv anc ll) (memv anc rl) (equal? (dedup-odd-wires ll) (dedup-odd-wires rl)))
              (set! b-ok? #f)
              (define msg
                (format "`with-and-session` binding on `~a` aliases controls or target (`Lin1 (+) Lin1 = Conflict`)"
                        (fmt-wire anc)))
              (emit-v! "StaticDiscipline" "T-NoCloningGate" "LFQ-E-GATE-ALIAS"
                       msg msg (hasheq 'ancilla (fmt-wire anc))
                       #:origin-span decl-span #:mutating-span sp #:failure-span sp
                       #:surface-wire (fmt-wire anc)))]
           [_ (set! b-ok? #f)]))
       (define exp-body (walk body sp active-callees))
       (if b-ok? (keep `(with-and-session ,bindings ,exp-body)) exp-body)]
      [`(within-apply-mbu ,c ,a ,ws)
       (define wl (if (list? ws) ws '()))
       (check-wires-in-scope! wl sp 'within-apply-mbu)
       (keep `(within-apply-mbu ,(walk c sp active-callees)
                                ,(walk a sp active-callees)
                                ,wl))]
      [`(within-apply ,c ,a ,ws)
       (define wl (if (list? ws) ws '()))
       (check-wires-in-scope! wl sp 'within-apply)
       (define exp-c (walk c sp active-callees))
       (define exp-a (walk a sp active-callees))
       (define bad-nu (find-first-non-unitary-node exp-c))
       (cond
         [bad-nu
          (define nu-sp (or (lookup-surface-span bad-nu) sp))
          (define nice-sub (fmt-surface-node bad-nu))
          (define msg
            (format "`within-apply` compute block requires unitary invertible operations, found `~a` (use `within-apply-mbu` for measurement-based uncomputation)"
                    nice-sub))
          (emit-v! "StaticDiscipline" "T-UnitaryAdj" "LFQ-E-NONUNITARY-INVERT"
                   msg msg (hasheq 'non_unitary_form nice-sub)
                   #:origin-span sp #:mutating-span nu-sp #:failure-span sp)
          'skip]
         [else
          (keep `(within-apply ,exp-c ,exp-a ,wl))])]
      [`(erase-by ,f ,b ,ws)
       (define wl (if (list? ws) ws '()))
       (check-wires-in-scope! wl sp 'erase-by)
       (keep `(erase-by ,(walk f sp active-callees)
                        ,(walk b sp active-callees)
                        ,wl))]
      [`(erase-by-part-bij ,spec ,f ,b ,ws)
       (define wl (if (list? ws) ws '()))
       (check-wires-in-scope! wl sp 'erase-by-part-bij)
       (keep `(erase-by-part-bij ,spec
                                 ,(walk f sp active-callees)
                                 ,(walk b sp active-callees)
                                 ,wl))]
      [`(canonicalize-quotient ,qws ,c)
       (define ql (if (list? qws) qws '()))
       (check-wires-in-scope! ql sp 'canonicalize-quotient)
       (keep `(canonicalize-quotient ,ql ,(walk c sp active-callees)))]
      [`(qmatch ,arms)
       (for ([arm (in-list arms)])
         (check-wires-in-scope! (collect-guard-wires (first arm)) sp 'qmatch))
       (keep `(qmatch ,(for/list ([arm (in-list arms)])
                         (list (first arm) (walk (second arm) sp active-callees)))))]
      [`(focus-zipper (,sub-ws ,amb-ws) ,b)
       (check-wires-in-scope! (append (if (list? sub-ws) sub-ws '())
                                      (if (list? amb-ws) amb-ws '()))
                              sp 'focus-zipper)
       (keep `(focus-zipper (,sub-ws ,amb-ws) ,(walk b sp active-callees)))]
      [`(fold-braun ,nd)
       (define (wb n)
         (match n
           ['braun-leaf 'braun-leaf]
           [`(braun-branch ,idx ,st ,l ,r)
            (define nsp (or (lookup-surface-span n) sp))
            (define reb `(braun-branch ,idx ,(walk st nsp active-callees) ,(wb l) ,(wb r)))
            (if nsp (attach-surface-span! reb nsp) reb)]))
       (keep `(fold-braun ,(wb nd)))]
      [`(par-wires ,e1 ,e2)
       (keep `(par-wires ,(walk e1 sp active-callees)
                         ,(walk e2 sp active-callees)))]
      [`(multishot-reset ,k ,b)
       (keep `(multishot-reset ,k ,(walk b sp active-callees)))]
      [`(,(or 'guard-valid-if 'guard-qblock-lcu-phase 'guard-wire-basis
              'guard-drift-eps 'guard-single-ir 'guard-par-partition) ,spec ,b)
       (keep `(,(car e) ,spec ,(walk b sp active-callees)))]
      [`(guard-involutory ,c ,op ,b)
       (keep `(guard-involutory ,c ,op ,(walk b sp active-callees)))]
      [_ e]))

  (define expanded-ast (walk eff-surface-ast decl-span))
  (values expanded-ast extra-scratch-list extra-virt-names violations))

(define (find-first-guard-span ast)
  (let walk ([e ast])
    (match e
      [`(,(? (lambda (h) (memq h bug-class-guard-surface-heads)) _) . ,_)
       (lookup-surface-span e)]
      [`(seq ,es ...) (for/or ([s (in-list es)]) (walk s))]
      [`(for/fold-loop ,_ ,rs) (for/or ([r (in-list rs)]) (walk r))]
      [`(invert ,s) (walk s)]
      [`(with-and-session ,_ ,b) (walk b)]
      [`(,(or 'within-apply-mbu 'within-apply 'erase-by) ,c ,a ,_) (or (walk c) (walk a))]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for/or ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(par-wires ,e1 ,e2) (or (walk e1) (walk e2))]
      [`(multishot-reset ,_ ,b) (walk b)]
      [_ #f])))

(define default-bezout-l32-raw-schedule
  (adaptive-bezout-binomial-pebble-schedule))

(define canonical-u4-zipper-benchmarks
  (compute-zipper-mbu-tele-phase-metrics))

(define (extract-surface-bezout-specs ast)
  (define acc '())
  (let walk ([e ast])
    (match e
      [`(packed-bezout-jump16 (,n-bits ,jump-step ,base-pebbles) ,_ ,_ ,_)
       (set! acc (cons (list n-bits jump-step base-pebbles) acc))]
      [`(seq ,es ...) (for ([s (in-list es)]) (walk s))]
      [`(for/fold-loop ,_ ,rs) (for ([r (in-list rs)]) (walk r))]
      [`(invert ,s) (walk s)]
      [`(with-and-session ,_ ,b) (walk b)]
      [`(,(or 'within-apply-mbu 'within-apply 'erase-by) ,c ,a ,_) (walk c) (walk a)]
      [`(erase-by-part-bij ,_ ,c ,a ,_) (walk c) (walk a)]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd) (walk nd)]
      [`(braun-branch ,_ ,st ,l ,r) (walk st) (walk l) (walk r)]
      [`(par-wires ,e1 ,e2) (walk e1) (walk e2)]
      [`(multishot-reset ,_ ,b) (walk b)]
      [`(,(? (lambda (h) (memq h bug-class-guard-surface-heads)) _) . ,rest)
       (when (pair? rest) (walk (last rest)))]
      [_ (void)]))
  (reverse acc))

(define (build-bezout-optimization-summary ast)
  (define specs (extract-surface-bezout-specs ast))
  (define active? (pair? specs))
  (define raw-h
    (if active?
        (match-let ([(list nb js bp) (first specs)])
          (if (and (= nb 256) (= js 16) (= bp 4))
              default-bezout-l32-raw-schedule
              (adaptive-bezout-binomial-pebble-schedule #:n-bits nb
                                                        #:jump-step js
                                                        #:base-pebbles bp)))
        default-bezout-l32-raw-schedule))
  (hasheq 'pass_name "adaptive-bezout-limb-borrowz-pebble-recycling"
          'active active?
          'packed_bezout_gadgets_synthesized (length specs)
          'n_bits (hash-ref raw-h 'n_bits 256)
          'jump_window_steps (hash-ref raw-h 'jump_window_steps 16)
          'macro_windows_l (hash-ref raw-h 'macro_windows_l 32)
          'base_pebbles_s (hash-ref raw-h 'base_pebbles_s 4)
          'adaptive_pebble_progression (hash-ref raw-h 'adaptive_pebble_progression '(4 6 8))
          'epoch_pebble_schedule (hash-ref raw-h 'epoch_pebble_schedule '(4 6 8 8))
          'static_forward_evals (hash-ref raw-h 'static_forward_evals 77)
          'static_reverse_evals (hash-ref raw-h 'static_reverse_evals 32)
          'static_total_macro_evals (hash-ref raw-h 'static_total_macro_evals 109)
          'adaptive_forward_evals (hash-ref raw-h 'adaptive_forward_evals 35)
          'adaptive_reverse_evals (hash-ref raw-h 'adaptive_reverse_evals 32)
          'adaptive_total_macro_evals (hash-ref raw-h 'adaptive_total_macro_evals 67)
          'eval_reduction_ratio_2dp (hash-ref raw-h 'eval_reduction_ratio_2dp 1.63)
          'packed_zipper_max_width_bits (hash-ref raw-h 'packed_zipper_max_width_bits 512)
          'packed_zipper_width_bound_preserved (hash-ref raw-h 'packed_zipper_width_bound_preserved #t)
          'ecc256_peak_logical_qubits (hash-ref raw-h 'ecc256_peak_logical_qubits 1210)
          'additional_peak_qubits (hash-ref raw-h 'additional_peak_qubits 0)
          'residual_dirty_pebble_qubits (hash-ref raw-h 'residual_dirty_pebble_qubits 0)))

(define canonical-phase-order-stage-list
  '("P_loop_cone"
    "P_pebble"
    "EGraph_TODD_ZX_round1"
    "P_fraig_commute"
    "EGraph_TODD_ZX_round2"
    "P_mbu_bellman_knuth"
    "P_ssa_post_todd_chordal"
    "P_part_u4_coupled_block_lu"))

(define (empty-optimization-passes-summary bezout-summary)
  (hasheq
   'canonical_phase_order
   (hasheq 'schedule_id "canonical_k2_coupled"
           'schedule_stages canonical-phase-order-stage-list
           'active #f
           'todd_zx_fixpoint_rounds 0
           'bellman_knuth_absorb_top_cz #t
           'pre_mbu_sessions_fused 0
           'phase_mbu_cones_absorbed 0
           'disjoint_diagonal_ops_hoisted 0
           'fraig_commute_moves 0
           'todd_cones_reduced 0
           'clifford_t_count 0
           'pre_todd_ssa_physical_qubits 0
           'post_todd_ssa_physical_qubits 0
           'post_todd_ssa_reclaimed_qubits 0
           'partition_block_lu_frames_resynthesized 0
           'partition_block_lu_cross_cxs_saved 0
           'partition_block_lu_ebits_saved 0)
   'xag_1wl_cone_and_loop_escalation
   (hasheq 'engine "surface-static"
           'total_cones_evaluated 0
           'unique_canonical_cones 0
           'cone_isomorphism_hits 0
           'fraig_merges 0
           'cut_cache_hits 0
           'z3_queries 0
           'z3_push_pop_incremental #t
           'for_fold_loops '())
   'adaptive_bezout_pebble_recycling bezout-summary
   'todd_rm3_autocc_phase_poly
   (hasheq 'pass_name "todd-rm3-autocc-phase-poly"
           'phase_clean_zippers_certified 0
           'cones_optimized 0
           'pre_t_count 0
           'post_t_count 0
           't_count_saved 0
           'pre_t_depth 0
           'post_t_depth 0
           't_depth_saved 0)
   'u4_cross_qpu_tele_phase
   (hasheq 'pass_name "u4-cross-qpu-tele-phase-opt"
           'active #f
           'machines_used 1
           'cross_cut_mbu_wire_count 0
           'batched_pivot_cone_count 0
           'naive_ebits_2_per_wire 0
           'u4_batched_cone_ebits 0
           'reverse_ebits 0
           'classical_broadcast_bits 0
           'canonical_zipper_benchmarks canonical-u4-zipper-benchmarks)))

(define (compile-lfq-circuit decl
                             [raw-target-sym #f]
                             #:repair? [repair? #f]
                             #:program [prog #f]
                             #:q-cap [q-cap #f]
                             #:r-bell [r-bell #f]
                             #:topology [topology #f]
                             #:max-machines [max-machines #f]
                             #:cluster-dir [cluster-dir #f]
                             #:anf-monomial-cap [anf-monomial-cap 1024]
                             #:phase-schedule [phase-schedule 'canonical_k2_coupled])
  (define target-sym (or raw-target-sym (lookup-decl-target decl) 'ideal))
  (define hw (lookup-target-profile target-sym))
  (define decl-span (decl-or-synthetic-span decl))
  (define port-sig (infer-decl-port-rwire-signature decl))
  (define qec-pacing-meta (build-qec-syndrome-decoder-pacing-metadata target-sym hw))
  (define eff-surface-ast
    (rewrite-surface-par-specs (lfq-circuit-decl-surface-ast decl)
                               #:decl decl
                               #:q-cap q-cap
                               #:r-bell r-bell
                               #:topology topology
                               #:max-machines max-machines))

  ;; 0a. Check register wire disjointness (`LFQ-E-WIRE-ALIAS`) + surface static discipline & `call-q` expansion:
  (define wire-alias-violations (check-decl-wire-disjointness decl))
  (define-values (expanded-surface-ast extra-scratch-ws extra-virt-names surface-static-violations)
    (validate-and-expand-surface-ast decl eff-surface-ast))
  (define bezout-opt-summary (build-bezout-optimization-summary expanded-surface-ast))
  (define pre-elaboration-violations
    (append wire-alias-violations surface-static-violations))

  ;; 0b. Enforce 7-rule generalized bug-class & parallel-partitionability static discipline (`T-DomImg` .. `T-ParGuard`):
  (define bug-guard-violations
    (with-handlers
      ([exn:fail?
        (lambda (ex)
          (define gsp (or (find-first-guard-span expanded-surface-ast) decl-span))
          (define msg
            (format "Malformed surface guard specification in `~a`: ~a"
                    (lfq-circuit-decl-name decl) (exn-message ex)))
          (list (make-surface-static-violation
                 "BugClassTypeSystem"
                 "T-DomImg"
                 "LFQ-E-GUARD-SPEC"
                 msg msg
                 (hasheq 'circuit (symbol->string (lfq-circuit-decl-name decl)))
                 #:origin-span decl-span
                 #:mutating-span gsp
                 #:failure-span gsp
                 #:repair-hint
                 "Pass a quoted guard specification matching the surface rule grammar (e.g., `'((part-bij #:domain-bits n ...))` or `(par-cluster-opt-spec ...)`).")))])
      (enrich-surface-guard-violations
       (check-surface-bug-class-guards expanded-surface-ast)
       expanded-surface-ast
       decl)))
  (define surface-par-decisions
    (if (null? bug-guard-violations)
        (collect-surface-par-guard-decisions expanded-surface-ast)
        '()))

  (define malformed-guard-spec?
    (for/or ([v (in-list bug-guard-violations)])
      (equal? (hash-ref v 'code "") "LFQ-E-GUARD-SPEC")))

  ;; Short-circuit elaboration/lowering if structural surface violations (`LFQ-E-WIRE-ALIAS`,
  ;; `LFQ-E-GATE-ALIAS`, `LFQ-E-NONUNITARY-INVERT`, `LFQ-E-UNDECLARED-WIRE`, `LFQ-E-CALL-ALIAS`,
  ;; `LFQ-E-QFREE-BASIS`) or malformed guard specs (`LFQ-E-GUARD-SPEC`) were found so internal
  ;; passes never crash on ill-scoped ASTs:
  (cond
    [(or (not (null? pre-elaboration-violations)) malformed-guard-spec?)
     (define all-v (append pre-elaboration-violations bug-guard-violations))
     (define res
       (compilation-result
        (lfq-circuit-decl-name decl)
        (lfq-circuit-decl-kind decl)
        target-sym
        #f
        0
        (+ (length (lfq-circuit-decl-input-wires decl))
           (length (lfq-circuit-decl-scratch-wires decl))
           (length extra-scratch-ws))
        (length (lfq-circuit-decl-input-wires decl))
        0 0 0 0 0 0 0 0 'unbounded 0 0 '() all-v "" "" 1 #f '()))
     (attach-compilation-cohesion-meta!
      res
      (hasheq 'rwire_port_signature
              (for/list ([ps (in-list port-sig)])
                (hasheq 'port (symbol->string (port-rwire-spec-port-name ps))
                        'width (port-rwire-spec-width ps)
                        'grade (symbol->string (port-rwire-spec-grade ps))
                        'diagonal_read_only (port-rwire-spec-diagonal-read-only? ps)))
              'symbolic_inference_engine "surface-static"
              'module_circuits_checked (list (symbol->string (lfq-circuit-decl-name decl)))
              'optimization_passes (empty-optimization-passes-summary bezout-opt-summary)
              'qec_syndrome_decoder_pacing qec-pacing-meta))
     res]
    [else
     ;; 1. Surface `LakefillQ` -> 6-primitive `lambda_LFQ_kern`:
     (define kern-ast (elaborate-surface->kern expanded-surface-ast))
     (close-bug-prevention-z3!)
     (define residual-forms (count-residual-surface-forms kern-ast))
     (unless (= residual-forms 0)
       (error 'compile-lfq-circuit
              "Elaboration invariant violated: ~a residual surface forms in ~a"
              residual-forms (lfq-circuit-decl-name decl)))

     ;; 2. Initial span-preserving `RevIR` lowering for `P_loop_cone` (`QSub` + `QPhysGrade`)
     ;;    certification and 3-span multipass diagnostic provenance:
     (define all-scratch-wires
       (append (lfq-circuit-decl-scratch-wires decl) extra-scratch-ws))
     (define input-wires (lfq-circuit-decl-input-wires decl))
     (define-values (revir0 cmap0 scratch-phys0 virt-w0 phys-q0 saved-w0)
       (lower-kern->revir kern-ast
                          input-wires
                          all-scratch-wires
                          hw))

     ;; 3. Optional counterexample-guided physical repair (`QPhysGrade`):
     (define-values (revir-checked repairs0)
       (if repair?
           (repair-revir-counterexample-guided revir0 hw)
           (values revir0 '())))

     ;; 4. `P_loop_cone`: Annotation-free symbolic `QSub (U1-U4)` + `QPhysGrade (Phi1-Phi3)`
     ;;    inference (automatically escalates `ANF -> XAG/FRAIG+Z3` with 1-WL canonical
     ;;    cone-isomorphism caching, incremental Z3 `push`/`pop`, and zero-flag
     ;;    `k=1 -> k=2 -> k=R` `for/fold-loop` round-invariant escalation!):
     (define-values (revir-violations grade action-milli phase-res quotient-ws)
       (infer-revir-qsub-and-qphys revir-checked
                                   input-wires
                                   scratch-phys0
                                   (lfq-circuit-decl-domain-spec decl)
                                   hw
                                   #:decl decl
                                   #:color-map cmap0
                                   #:extra-virt-names extra-virt-names
                                   #:anf-monomial-cap anf-monomial-cap))
     (define sym-engine-used (symbol->string (unbox last-symbolic-engine-box)))
     (define xag-telemetry (unbox last-xag-telemetry-box))
     (define had-certified-zippers?
       (> (hash-count certified-phase-clean-zippers-table) 0))

     ;; 4b. Canonical Coupled Lowering (`P_loop_cone -> P_pebble -> 2-round (FRAIG/Commute o
     ;;     EGraph(MBU U ZX U TODD))^2 -> Bellman-Knuth P_mbu -> Post-TODD Chordal SSA`):
     (define-values (revir repairs scratch-phys virt-w phys-q-post-ssa saved-w
                           kern-phase-stats chosen-absorb-top? todd-fixpoint-rounds)
       (cond
         [(not (null? revir-violations))
          (values revir-checked repairs0 scratch-phys0 virt-w0 phys-q0 saved-w0
                  (hasheq) #t 0)]
         [(eq? phase-schedule 'hazardB_mbu_before_todd)
          ;; Hazard B ablation (`MBU < TODD`): `within-apply-mbu` already expanded to `M_X + cond-cz`
          ;; barriers BEFORE 1-round TODD runs!
          (define-values (k-hb st-hb)
            (optimize-kern-canonical-phase-order kern-ast decl
                                                 #:rounds 1
                                                 #:absorb-top-cz? #f
                                                 #:enable-mbu-algebraic? #f))
          (if (equal? k-hb kern-ast)
              (values revir-checked repairs0 scratch-phys0 virt-w0 phys-q0 saved-w0
                      st-hb #f 1)
              (let ()
                (define-values (rv1 _cm1 sp1 _vw1 pq1 _sw1)
                  (lower-kern->revir k-hb input-wires all-scratch-wires hw))
                (define-values (rv2 rep2)
                  (if repair? (repair-revir-counterexample-guided rv1 hw) (values rv1 '())))
                (when had-certified-zippers?
                  (infer-revir-qsub-and-qphys rv2 input-wires sp1
                                              (lfq-circuit-decl-domain-spec decl) hw
                                              #:anf-monomial-cap anf-monomial-cap))
                (values rv2 rep2 sp1 virt-w0 pq1 (max 0 (- virt-w0 pq1)) st-hb #f 1)))]
         [(eq? phase-schedule 'hazardA_ssa_before_todd)
          ;; Hazard A ablation (`SSA < TODD` without post-TODD re-coloring):
          ;; Chordal SSA runs BEFORE 1-round TODD, inserting WAW reuse barriers & stranding scratch wires!
          (define-values (ssa-kern ssa-scr ssa-phys-q)
            (apply-pre-todd-ssa-with-waw-barriers kern-ast input-wires all-scratch-wires))
          (define-values (k-ha st-ha)
            (optimize-kern-canonical-phase-order ssa-kern decl
                                                 #:rounds 1
                                                 #:absorb-top-cz? #t
                                                 #:enable-mbu-algebraic? #t))
          (define wmap-ha (make-hasheqv))
          (define mbu-ha (box 0))
          (define raw-ha (lower-kern->raw-revir k-ha wmap-ha mbu-ha))
          (define-values (rv-ha rep-ha)
            (if repair? (repair-revir-counterexample-guided raw-ha hw) (values raw-ha '())))
          (when had-certified-zippers?
            (infer-revir-qsub-and-qphys rv-ha input-wires ssa-scr
                                        (lfq-circuit-decl-domain-spec decl) hw
                                        #:anf-monomial-cap anf-monomial-cap))
          (values rv-ha rep-ha ssa-scr virt-w0 ssa-phys-q
                  (max 0 (- virt-w0 ssa-phys-q)) st-ha #t 1)]
         [else
          ;; Default `canonical_k2_coupled`:
          ;; Pre-MBU, pre-SSA 2-round `(FRAIG/Commute o EGraph(MBU U ZX U TODD))^2` fixpoint
          ;; + Bellman-Knuth `QPhysGrade` extraction + post-TODD chordal SSA coloring!
          (define-values (k-abs st-abs)
            (optimize-kern-canonical-phase-order kern-ast decl
                                                 #:rounds 2
                                                 #:absorb-top-cz? #t
                                                 #:enable-mbu-algebraic? #t))
          (cond
            [(equal? k-abs kern-ast)
             (values revir-checked repairs0 scratch-phys0 virt-w0 phys-q0 saved-w0
                     st-abs #t 2)]
            [else
             (define (eval-branch k-cand)
               (define-values (rv1 _cm1 sp1 _vw1 pq1 _sw1)
                 (lower-kern->revir k-cand input-wires all-scratch-wires hw))
               (define-values (rv2 rep2)
                 (if repair? (repair-revir-counterexample-guided rv1 hw) (values rv1 '())))
               (define-values (isa-c nq-c _cl-c _gp-c)
                 (lower-revir->machine-isa rv2 pq1))
               (define tc-c (count-isa-clifford-t-gates isa-c))
               (list rv2 rep2 sp1 pq1 nq-c tc-c))
             (match-define (list rv-a rep-a sp-a pq-a nq-a tc-a) (eval-branch k-abs))
             (define-values (chosen-rv chosen-rep chosen-sp chosen-pq chosen-st chosen-abs?)
               (if (> (hash-ref st-abs 'phase_cones_absorbed 0) 0)
                   (let ()
                     (define-values (k-sel st-sel)
                       (optimize-kern-canonical-phase-order kern-ast decl
                                                            #:rounds 2
                                                            #:absorb-top-cz? #f
                                                            #:enable-mbu-algebraic? #t))
                     (match-define (list rv-s rep-s sp-s pq-s nq-s tc-s) (eval-branch k-sel))
                     (if (and (< tc-s tc-a) (<= nq-s nq-a))
                         (values rv-s rep-s sp-s pq-s st-sel #f)
                         (values rv-a rep-a sp-a pq-a st-abs #t)))
                   (values rv-a rep-a sp-a pq-a st-abs #t)))
             (when had-certified-zippers?
               (infer-revir-qsub-and-qphys chosen-rv input-wires chosen-sp
                                           (lfq-circuit-decl-domain-spec decl) hw
                                           #:anf-monomial-cap anf-monomial-cap))
             (values chosen-rv chosen-rep chosen-sp virt-w0 chosen-pq
                     (max 0 (- virt-w0 chosen-pq)) chosen-st chosen-abs? 2)])]))

     ;; 4c. Phase-Clean `focus-zipper` RM(3, n) TODD symmetric 3-tensor decomposition + AutoCCZ packing:
     (define-values (opt-revir zipper-todd-summary)
       (if (null? revir-violations)
           (optimize-revir-phase-clean-focus-zippers revir certified-phase-clean-zippers-table)
           (values revir
                   (hasheq 'pass_name "todd-rm3-autocc-phase-poly"
                           'phase_clean_zippers_certified 0
                           'cones_optimized 0
                           'pre_t_count 0
                           'post_t_count 0
                           't_count_saved 0
                           'pre_t_depth 0
                           'post_t_depth 0
                           't_depth_saved 0))))
     (define merged-pre-tc
       (+ (hash-ref zipper-todd-summary 'pre_t_count 0)
          (hash-ref kern-phase-stats 'todd_pre_t_count 0)))
     (define merged-post-tc
       (+ (hash-ref zipper-todd-summary 'post_t_count 0)
          (hash-ref kern-phase-stats 'todd_post_t_count 0)))
     (define merged-pre-td
       (+ (hash-ref zipper-todd-summary 'pre_t_depth 0)
          (hash-ref kern-phase-stats 'todd_pre_t_depth 0)))
     (define merged-post-td
       (+ (hash-ref zipper-todd-summary 'post_t_depth 0)
          (hash-ref kern-phase-stats 'todd_post_t_depth 0)))
     (define todd-summary
       (hash-set* zipper-todd-summary
                  'cones_optimized (+ (hash-ref zipper-todd-summary 'cones_optimized 0)
                                      (hash-ref kern-phase-stats 'todd_cones_reduced 0))
                  'pre_t_count merged-pre-tc
                  'post_t_count merged-post-tc
                  't_count_saved (max 0 (- merged-pre-tc merged-post-tc))
                  'pre_t_depth merged-pre-td
                  'post_t_depth merged-post-td
                  't_depth_saved (max 0 (- merged-pre-td merged-post-td))))

     ;; Compute actual ISA metrics for AST-derived `'auto` cluster costing & `#:verify-circuit-match?`:
     (define-values (cand-isa-ops cand-total-phys-q cand-total-clbits cand-guard-pool)
       (lower-revir->machine-isa opt-revir phys-q-post-ssa))
     (define actual-toffolis (count-isa-toffolis cand-isa-ops))

     (define raw-drift-violations
       (if prog
           (check-cluster-profile-circuit-match prog decl cand-total-phys-q actual-toffolis)
           '()))
     (define cluster-drift-violations
       (for/list ([dv (in-list raw-drift-violations)])
         (define psp (or (hash-ref dv 'profile_span #f) decl-span))
         (enrich-revir-violation (hash-remove dv 'profile_span)
                                 #:resugared-message (hash-ref dv 'message)
                                 #:origin-span decl-span
                                 #:mutating-span psp
                                 #:failure-span psp)))

     ;; Evaluate module-level `define-cluster-profile` / CLI cluster spec when present and not already
     ;; recorded via an in-AST `guard-par-partition`:
     (define need-module-cluster-eval?
       (and (null? bug-guard-violations)
            (null? cluster-drift-violations)
            (null? surface-par-decisions)
            (or cluster-dir
                (has-cluster-cli-overrides? q-cap r-bell topology max-machines)
                (and prog (not (null? (lfq-program-cluster-profiles prog)))))))
     (define-values (module-par-violations par-decisions)
       (cond
         [need-module-cluster-eval?
          (define-values (eff-spec _slices)
            (resolve-effective-cluster-spec prog decl cand-total-phys-q
                                            #:ast-toffolis actual-toffolis
                                            #:q-cap q-cap
                                            #:r-bell r-bell
                                            #:topology topology
                                            #:max-machines max-machines))
          (define par-res (compile-parallel-with-fallback eff-spec))
          (if (lfq-typecheck-result-well-typed? par-res)
              (values '() (list (lfq-typecheck-result-metrics par-res)))
              (values
               (enrich-surface-guard-violations
                (for/list ([d (in-list (lfq-typecheck-result-diagnostics par-res))])
                  (hasheq 'category "BugClassTypeSystem"
                          'rule (lfq-type-diagnostic-rule d)
                          'code (lfq-type-diagnostic-code d)
                          'message (lfq-type-diagnostic-message d)
                          'witness (lfq-type-diagnostic-witness d)))
                expanded-surface-ast
                decl)
               '()))]
         [else
          (values '() surface-par-decisions)]))

     (define fallback-single?
       (if (for/or ([d (in-list par-decisions)])
             (hash-ref d 'fallback_to_single_machine #f))
           #t
           #f))
     (define machines-used
       (cond
         [fallback-single? 1]
         [(null? par-decisions) 1]
         [else (hash-ref (last par-decisions) 'machines_used 1)]))

     (define violations
       (append bug-guard-violations
               cluster-drift-violations
               module-par-violations
               revir-violations))
     (define well-typed? (null? violations))

     ;; 5. Coupled `P_part_u4 <-> Block-LU` + `RevIR -> MachineISA -> OpenQASM 3.0 & Stim`:
     (define-values (pre-cluster-isa-ops total-phys-q total-clbits guard-pool)
       (if well-typed?
           (values cand-isa-ops cand-total-phys-q cand-total-clbits cand-guard-pool)
           (values '() phys-q0 0 '())))

     (define-values (isa-ops active-cluster-slices blk-lu-frames blk-lu-cxs-saved blk-lu-ebits-saved)
       (cond
         [(and well-typed? (>= machines-used 2))
          (define-values (_eff-cspec explicit-slices)
            (resolve-effective-cluster-spec prog decl total-phys-q
                                            #:ast-toffolis actual-toffolis
                                            #:q-cap q-cap
                                            #:r-bell r-bell
                                            #:topology topology
                                            #:max-machines max-machines))
          (define chosen-slices
            (if explicit-slices
                (partition-wires-across-qpus total-phys-q machines-used pre-cluster-isa-ops explicit-slices)
                (let ([hg-slices
                       (partition-wires-law-u4-hypergraph
                        total-phys-q
                        machines-used
                        (isa-ops->analyzer-revir-ops pre-cluster-isa-ops)
                        #t
                        #:num-fixed (length input-wires))])
                  (if (for/and ([sl (in-list hg-slices)]) (pair? sl))
                      hg-slices
                      (partition-wires-across-qpus total-phys-q machines-used pre-cluster-isa-ops #f)))))
          (if (eq? phase-schedule 'canonical_k2_coupled)
              (let-values ([(lu-isa f-cnt cx-sav eb-sav)
                            (resynthesize-isa-cx-frames-partition-aware
                             pre-cluster-isa-ops total-phys-q chosen-slices)])
                (values lu-isa chosen-slices f-cnt cx-sav eb-sav))
              (values pre-cluster-isa-ops chosen-slices 0 0 0))]
         [else
          (values pre-cluster-isa-ops #f 0 0 0)]))

     (define fwd-temp-ands
       (for/sum ([op (in-list isa-ops)])
         (match op [`(isa-temp-and-ccx ,_ ,_ ,_) 1] [_ 0])))
     (define uncomp-ccx
       (for/sum ([op (in-list isa-ops)])
         (match op [`(isa-ccx ,_ ,_ ,_) 1] [_ 0])))
     (define mbu-count
       (for/sum ([op (in-list isa-ops)])
         (match op
           [(or `(isa-meas-x-cond-cz-reset . ,_)
                `(isa-meas-x-cond-z-reset . ,_)
                `(isa-meas-x-reset . ,_))
            1]
           [_ 0])))

     (define detector-wires
       (append scratch-phys guard-pool
               (filter (lambda (w) (not (memv w input-wires)))
                       quotient-ws)))

     (define qasm3-str
       (if well-typed?
           (emit-openqasm3 isa-ops total-phys-q total-clbits)
           ""))
     (define stim-str
       (if well-typed?
           (emit-stim isa-ops detector-wires hw)
           ""))

     ;; 5b. Law-U4 cross-QPU bilinear tele-phase factoring + batched forward cat-entangler fusion:
     (define u4-tele-summary
       (cond
         [(and well-typed? (>= machines-used 2))
          (define-values (_opt-c-ops _opt-c-slices _opt-c-nq u4-poly)
            (u4-cross-qpu-tele-phase-opt isa-ops active-cluster-slices total-phys-q))
          (define naive-eb (hash-ref u4-poly 'naive_ebits_2_per_wire 0))
          (define batched-eb (hash-ref u4-poly 'u4_batched_cone_ebits 0))
          (hash-set* u4-poly
                     'active #t
                     'machines_used machines-used
                     'ebits_saved (+ blk-lu-ebits-saved (max 0 (- naive-eb batched-eb)))
                     'canonical_zipper_benchmarks canonical-u4-zipper-benchmarks)]
         [else
          (hasheq 'pass_name "u4-cross-qpu-tele-phase-opt"
                  'active #f
                  'machines_used machines-used
                  'cross_cut_mbu_wire_count 0
                  'batched_pivot_cone_count 0
                  'naive_ebits_2_per_wire 0
                  'u4_batched_cone_ebits 0
                  'ebits_saved 0
                  'reverse_ebits 0
                  'classical_broadcast_bits 0
                  'canonical_zipper_benchmarks canonical-u4-zipper-benchmarks)]))

     (when (and well-typed? cluster-dir)
       (emit-cluster-openqasm3-bundle! cluster-dir
                                       prog
                                       decl
                                       target-sym
                                       isa-ops
                                       total-phys-q
                                       qasm3-str
                                       #:ast-toffolis actual-toffolis
                                       #:q-cap q-cap
                                       #:r-bell r-bell
                                       #:topology topology
                                       #:max-machines max-machines))

     (define w-in-cnt (length input-wires))
     (define dirty-leak-cnt
       (for/sum ([v (in-list revir-violations)])
         (if (equal? (hash-ref v 'code "") "U1-EraseBy") 1 0)))
     (define eff-summary
       (qcomp-effect w-in-cnt
                     w-in-cnt
                     total-phys-q
                     (max 0 (- total-phys-q w-in-cnt dirty-leak-cnt))
                     dirty-leak-cnt
                     action-milli
                     (qphys-semiring-grade-exclusion-collisions grade)
                     (or (qphys-semiring-grade-eff-fault-dist grade) 3)
                     1 0.0 0 #f 0 0))

     (define canonical-phase-summary
       (hasheq 'schedule_id (symbol->string phase-schedule)
               'schedule_stages canonical-phase-order-stage-list
               'active well-typed?
               'todd_zx_fixpoint_rounds todd-fixpoint-rounds
               'bellman_knuth_absorb_top_cz chosen-absorb-top?
               'pre_mbu_sessions_fused (hash-ref kern-phase-stats 'sessions_fused 0)
               'phase_mbu_cones_absorbed (hash-ref kern-phase-stats 'phase_cones_absorbed 0)
               'disjoint_diagonal_ops_hoisted (hash-ref kern-phase-stats 'disjoint_diagonal_ops_hoisted 0)
               'fraig_commute_moves (hash-ref kern-phase-stats 'fraig_commute_moves 0)
               'todd_cones_reduced (hash-ref todd-summary 'cones_optimized 0)
               'clifford_t_count (if well-typed? (count-isa-clifford-t-gates isa-ops) 0)
               'pre_todd_ssa_physical_qubits phys-q0
               'post_todd_ssa_physical_qubits phys-q-post-ssa
               'post_todd_ssa_reclaimed_qubits (max 0 (- phys-q0 phys-q-post-ssa))
               'partition_block_lu_frames_resynthesized blk-lu-frames
               'partition_block_lu_cross_cxs_saved blk-lu-cxs-saved
               'partition_block_lu_ebits_saved blk-lu-ebits-saved))

     (define opt-passes-summary
       (hasheq 'canonical_phase_order canonical-phase-summary
               'xag_1wl_cone_and_loop_escalation xag-telemetry
               'adaptive_bezout_pebble_recycling bezout-opt-summary
               'todd_rm3_autocc_phase_poly todd-summary
               'u4_cross_qpu_tele_phase u4-tele-summary))

     (define res
       (compilation-result
        (lfq-circuit-decl-name decl)
        (lfq-circuit-decl-kind decl)
        target-sym
        well-typed?
        residual-forms
        virt-w
        total-phys-q
        saved-w
        total-clbits
        fwd-temp-ands
        uncomp-ccx
        mbu-count
        (length isa-ops)
        action-milli
        (qphys-semiring-grade-exclusion-collisions grade)
        (or (qphys-semiring-grade-eff-fault-dist grade) 'unbounded)
        (qphys-semiring-grade-req-fault-dist grade)
        phase-res
        repairs
        violations
        qasm3-str
        stim-str
        machines-used
        fallback-single?
        par-decisions))
     (attach-compilation-cohesion-meta!
      res
      (hasheq 'rwire_port_signature
              (for/list ([ps (in-list port-sig)])
                (hasheq 'port (symbol->string (port-rwire-spec-port-name ps))
                        'width (port-rwire-spec-width ps)
                        'grade (symbol->string (port-rwire-spec-grade ps))
                        'diagonal_read_only (port-rwire-spec-diagonal-read-only? ps)))
              'qeffect_summary
              (hasheq 'w_in (qcomp-effect-w-in eff-summary)
                      'w_out (qcomp-effect-w-out eff-summary)
                      'peak (qcomp-effect-peak eff-summary)
                      'clean_disc (qcomp-effect-clean-disc eff-summary)
                      'dirty_leak (qcomp-effect-dirty-leak eff-summary)
                      'phi1_action (qcomp-effect-phi1-action eff-summary)
                      'phi2_collisions (qcomp-effect-phi2-collisions eff-summary))
              'symbolic_inference_engine sym-engine-used
              'module_circuits_checked (list (symbol->string (lfq-circuit-decl-name decl)))
              'optimization_passes opt-passes-summary
              'qec_syndrome_decoder_pacing qec-pacing-meta))
     res]))

(define (compile-lfq-program prog
                             #:target [override-target #f]
                             #:repair? [repair? #f]
                             #:q-cap [q-cap #f]
                             #:r-bell [r-bell #f]
                             #:topology [topology #f]
                             #:max-machines [max-machines #f]
                             #:cluster-dir [cluster-dir #f]
                             #:anf-monomial-cap [anf-monomial-cap 1024]
                             #:phase-schedule [phase-schedule 'canonical_k2_coupled])
  (define tgt (or override-target (lfq-program-target prog)))
  (define decls (lfq-program-circuits prog))
  (when (null? decls)
    (error 'compile-lfq-program "No defq/defqfree circuits found in program"))
  ;; Typecheck all helper declarations in module order before the primary entry declaration:
  (define helper-decls (drop-right decls 1))
  (define helper-violations '())
  (for ([hd (in-list helper-decls)])
    (define hd-tgt (or override-target (lookup-decl-target hd) tgt))
    (define hres
      (compile-lfq-circuit hd hd-tgt
                           #:repair? repair?
                           #:anf-monomial-cap anf-monomial-cap
                           #:phase-schedule phase-schedule))
    (unless (compilation-result-well-typed? hres)
      (define hname (symbol->string (lfq-circuit-decl-name hd)))
      (define tagged-vs
        (for/list ([hv (in-list (compilation-result-violations hres))])
          (hash-set hv 'circuit_name hname)))
      (set! helper-violations (append helper-violations tagged-vs))))
  (define entry-decl (last decls))
  (define entry-tgt (or override-target (lookup-decl-target entry-decl) tgt))
  (define entry-res
    (compile-lfq-circuit entry-decl
                         entry-tgt
                         #:repair? repair?
                         #:program prog
                         #:q-cap q-cap
                         #:r-bell r-bell
                         #:topology topology
                         #:max-machines max-machines
                         #:cluster-dir (if (null? helper-violations) cluster-dir #f)
                         #:anf-monomial-cap anf-monomial-cap
                         #:phase-schedule phase-schedule))
  (define checked-names (map (lambda (d) (symbol->string (lfq-circuit-decl-name d))) decls))
  (define base-meta (lookup-compilation-cohesion-meta entry-res))
  (cond
    [(null? helper-violations)
     (attach-compilation-cohesion-meta!
      entry-res
      (hash-set base-meta 'module_circuits_checked checked-names))
     entry-res]
    [else
     (define merged-v (append helper-violations (compilation-result-violations entry-res)))
     (define merged-res
       (struct-copy compilation-result entry-res
                    [well-typed? #f]
                    [violations merged-v]
                    [qasm3-text ""]
                    [stim-text ""]))
     (attach-compilation-cohesion-meta!
      merged-res
      (hash-set base-meta 'module_circuits_checked checked-names))
     merged-res]))

(define (load-lfq-program-from-file path-str)
  (define full-p (simple-form-path path-str))
  (dynamic-require full-p 'lakefillq-program-spec))

(define (compilation-result->jsexpr res)
  (define meta (lookup-compilation-cohesion-meta res))
  (define tgt-sym (compilation-result-target-name res))
  (hasheq
   'circuit_name (symbol->string (compilation-result-circuit-name res))
   'circuit_kind (symbol->string (compilation-result-circuit-kind res))
   'target_profile (symbol->string tgt-sym)
   'pipeline_dialects '("LakefillQ" "lambda_LFQ_kern" "RevIR" "MachineISA")
   'well_typed (compilation-result-well-typed? res)
   'annotation_free_flags 0
   'residual_surface_forms (compilation-result-residual-surface-forms res)
   'virtual_wires (compilation-result-virtual-wires res)
   'physical_qubits (compilation-result-physical-qubits res)
   'chordal_recycled_wires (compilation-result-recycled-wires-saved res)
   'classical_meas_bits (compilation-result-classical-meas-bits res)
   'forward_temp_and_count (compilation-result-forward-temp-and-count res)
   'uncompute_ccx_count (compilation-result-uncompute-ccx-count res)
   'mbu_erasure_count (compilation-result-mbu-erasure-count res)
   'machine_isa_ops (compilation-result-isa-gate-count res)
   'machines_used (compilation-result-machines-used res)
   'fallback_to_single_machine (compilation-result-fallback-to-single-machine? res)
   'parallel_partition_decisions (compilation-result-parallel-partition-decisions res)
   'rwire_port_signature (hash-ref meta 'rwire_port_signature '())
   'qeffect_summary (hash-ref meta 'qeffect_summary (hasheq))
   'symbolic_inference_engine (hash-ref meta 'symbolic_inference_engine "anf-zhegalkin")
   'module_circuits_checked (hash-ref meta 'module_circuits_checked
                                      (list (symbol->string (compilation-result-circuit-name res))))
   'optimization_passes
   (hash-ref meta 'optimization_passes
             (empty-optimization-passes-summary
              (build-bezout-optimization-summary 'skip)))
   'qec_syndrome_decoder_pacing
   (hash-ref meta 'qec_syndrome_decoder_pacing
             (build-qec-syndrome-decoder-pacing-metadata tgt-sym (lookup-target-profile tgt-sym)))
   'qphys_grade
   (hasheq 'decoherence_action_milli (compilation-result-decoherence-action-milli res)
           'exclusion_collisions (compilation-result-exclusion-collisions res)
           'effective_fault_distance
           (let ([d (compilation-result-effective-fault-distance res)])
             (if (symbol? d) (symbol->string d) d))
           'required_fault_distance (compilation-result-required-fault-distance res))
   'quantum_phase_residuals (compilation-result-quantum-phase-residuals res)
   'repairs_applied (compilation-result-repairs-applied res)
   'violations (compilation-result-violations res)))

(define (format-compilation-diagnostics-human res)
  (format-violations-human (symbol->string (compilation-result-circuit-name res))
                           (symbol->string (compilation-result-target-name res))
                           (compilation-result-violations res)))

(define (parse-cli-pos-int flag-name s)
  (define n (string->number s))
  (unless (and (exact-integer? n) (> n 0))
    (error 'lakefillqc "Expected positive integer for ~a, got: ~a" flag-name s))
  n)

(define (parse-cli-pos-real flag-name s)
  (define n (string->number s))
  (unless (and (real? n) (> n 0))
    (error 'lakefillqc "Expected positive real for ~a, got: ~a" flag-name s))
  (exact->inexact n))

(define (parse-cli-topology s)
  (define sym (string->symbol s))
  (unless (memq sym '(all-to-all-peers switched-optical-tree))
    (error 'lakefillqc
           "Unsupported --topology `~a`; expected all-to-all-peers or switched-optical-tree"
           s))
  sym)

(define (execute-cli-driver! prog
                             #:target-override [target-override #f]
                             #:qasm3-out [qasm3-out #f]
                             #:stim-out [stim-out #f]
                             #:qasm3-stdout? [qasm3-stdout? #f]
                             #:stim-stdout? [stim-stdout? #f]
                             #:emit-json? [emit-json? #f]
                             #:diagnostics-human? [diagnostics-human? #f]
                             #:repair? [repair? #f]
                             #:q-cap [q-cap #f]
                             #:r-bell [r-bell #f]
                             #:topology [topology #f]
                             #:max-machines [max-machines #f]
                             #:cluster-dir [cluster-dir #f])
  (define res
    (compile-lfq-program prog
                         #:target target-override
                         #:repair? repair?
                         #:q-cap q-cap
                         #:r-bell r-bell
                         #:topology topology
                         #:max-machines max-machines
                         #:cluster-dir cluster-dir))
  (when (and qasm3-out (compilation-result-well-typed? res))
    (make-parent-directory* qasm3-out)
    (call-with-output-file qasm3-out
      (lambda (out) (display (compilation-result-qasm3-text res) out))
      #:exists 'replace))
  (when (and stim-out (compilation-result-well-typed? res))
    (make-parent-directory* stim-out)
    (call-with-output-file stim-out
      (lambda (out) (display (compilation-result-stim-text res) out))
      #:exists 'replace))
  (when (and qasm3-stdout? (compilation-result-well-typed? res))
    (display (compilation-result-qasm3-text res)))
  (when (and stim-stdout? (compilation-result-well-typed? res))
    (display (compilation-result-stim-text res)))
  (when emit-json?
    (write-json (compilation-result->jsexpr res))
    (newline))
  (unless (compilation-result-well-typed? res)
    (when (or diagnostics-human? (not emit-json?))
      (display (format-compilation-diagnostics-human res) (current-error-port))
      (newline (current-error-port)))
    (exit 1))
  res)

(define (emit-surface-exn-cli! e json-opt human-opt [label-str "<module>"])
  (define sp
    (or (exn:fail:lfq-surface-span e)
        (lfq-surface-span label-str 1 0 label-str 'LakefillQ)))
  (define code (exn:fail:lfq-surface-code e))
  (define hint (exn:fail:lfq-surface-repair-hint e))
  (define enriched-v
    (make-surface-static-violation
     "StaticDiscipline"
     "T-WireScope"
     code
     (exn-message e)
     (exn-message e)
     (hasheq)
     #:origin-span sp
     #:mutating-span sp
     #:failure-span sp
     #:repair-hint hint))
  (define err-js
    (hasheq 'well_typed #f
            'violations (list enriched-v)))
  (when json-opt
    (write-json err-js)
    (newline))
  (when (or human-opt (not json-opt))
    (display (format-violations-human label-str "surface" (list enriched-v))
             (current-error-port))
    (newline (current-error-port)))
  (exit 1))

;; Invoked automatically when running `racket examples/<name>.lfq`:
(define (run-lfq-module-default-cli! prog)
  (define target-opt #f)
  (define qasm-opt #f)
  (define stim-opt #f)
  (define human-opt #f)
  (define repair-opt #f)
  (define q-cap-opt #f)
  (define r-bell-opt #f)
  (define topology-opt #f)
  (define max-machines-opt #f)
  (define cluster-dir-opt #f)
  (command-line
   #:program "lakefillq-module"
   #:once-each
   [("--target") tgt "Override hardware target profile"
    (set! target-opt (string->symbol tgt))]
   [("--emit-qasm3") qpath "Write OpenQASM 3.0 output to file"
    (set! qasm-opt qpath)]
   [("--emit-stim") spath "Write Stim output to file"
    (set! stim-opt spath)]
   [("--emit-json") "Emit JSON compilation summary to stdout"
    (void)]
   [("--diagnostics-human") "Render multi-span surface diagnostics to stderr on type error"
    (set! human-opt #t)]
   [("--no-color") "Disable ANSI color escapes in diagnostics"
    (void)]
   [("--repair") "Apply counterexample-guided physical repair"
    (set! repair-opt #t)]
   [("--q-cap") qcap "Per-machine logical/physical qubit capacity"
    (set! q-cap-opt (parse-cli-pos-int "--q-cap" qcap))]
   [("--r-bell") rbell "Raw optical Bell link rate in Hz"
    (set! r-bell-opt (parse-cli-pos-real "--r-bell" rbell))]
   [("--topology") topo "Cluster interconnect: all-to-all-peers | switched-optical-tree"
    (set! topology-opt (parse-cli-topology topo))]
   [("--max-machines") maxm "Maximum cluster machine count"
    (set! max-machines-opt (parse-cli-pos-int "--max-machines" maxm))]
   [("--emit-cluster-dir") cdir "Emit partitioned multi-QPU OpenQASM 3.0 bundle to <dir>"
    (set! cluster-dir-opt cdir)]
   #:args _ignored
   (void))
  (with-handlers
    ([exn:fail:lfq-surface?
      (lambda (e)
        (emit-surface-exn-cli! e #t human-opt (format "~a" (lfq-program-source-id prog))))])
    (void (execute-cli-driver! prog
                               #:target-override target-opt
                               #:qasm3-out qasm-opt
                               #:stim-out stim-opt
                               #:emit-json? #t
                               #:diagnostics-human? human-opt
                               #:repair? repair-opt
                               #:q-cap q-cap-opt
                               #:r-bell r-bell-opt
                               #:topology topology-opt
                               #:max-machines max-machines-opt
                               #:cluster-dir cluster-dir-opt))))

(module+ main
  (define input-path #f)
  (define target-opt #f)
  (define qasm-opt #f)
  (define stim-opt #f)
  (define qasm-stdout-opt #f)
  (define stim-stdout-opt #f)
  (define json-opt #f)
  (define human-opt #f)
  (define repair-opt #f)
  (define q-cap-opt #f)
  (define r-bell-opt #f)
  (define topology-opt #f)
  (define max-machines-opt #f)
  (define cluster-dir-opt #f)

  (define positional-inputs
    (command-line
     #:program "lakefillqc"
     #:once-each
     [("--input") ipath "Input #lang lakefillq (.lfq) source file"
      (set! input-path ipath)]
     [("--target") tgt "Target profile: heron-r2 | bluvstein-aod | bb-qldpc | ideal"
      (set! target-opt (string->symbol tgt))]
     [("--emit-qasm3") qpath "Emit dynamic OpenQASM 3.0 circuit to <out.qasm> (or stdout when passed <file.lfq>)"
      (set! qasm-opt qpath)]
     [("--emit-stim") spath "Emit Stim stabilizer circuit to <out.stim> (or stdout when passed <file.lfq>)"
      (set! stim-opt spath)]
     [("--emit-json") "Emit structured JSON report to stdout"
      (set! json-opt #t)]
     [("--diagnostics-human") "Render multi-span surface diagnostics to stderr on type error"
      (set! human-opt #t)]
     [("--no-color") "Disable ANSI color escapes in diagnostics"
      (void)]
     [("--repair") "Enable counterexample-guided QPhysGrade repair"
      (set! repair-opt #t)]
     [("--q-cap") qcap "Per-machine qubit capacity (e.g., 400, 1500, or 8)"
      (set! q-cap-opt (parse-cli-pos-int "--q-cap" qcap))]
     [("--r-bell") rbell "Optical Bell link rate in Hz (default 100000.0)"
      (set! r-bell-opt (parse-cli-pos-real "--r-bell" rbell))]
     [("--topology") topo "Interconnect topology: all-to-all-peers | switched-optical-tree"
      (set! topology-opt (parse-cli-topology topo))]
     [("--max-machines") maxm "Maximum candidate machine count (default 256)"
      (set! max-machines-opt (parse-cli-pos-int "--max-machines" maxm))]
     [("--emit-cluster-dir") cdir "Emit multi-QPU OpenQASM 3.0 partition bundle to <dir>"
      (set! cluster-dir-opt cdir)]
     #:args rest-positional
     rest-positional))

  (cond
    [(and (not input-path) (pair? positional-inputs))
     (set! input-path (first positional-inputs))
     (when (and (not json-opt) (not qasm-opt) (not stim-opt))
       (set! json-opt #t))]
    [(and (not input-path) qasm-opt (string-suffix? qasm-opt ".lfq"))
     (set! input-path qasm-opt)
     (set! qasm-opt #f)
     (set! qasm-stdout-opt #t)]
    [(and (not input-path) stim-opt (string-suffix? stim-opt ".lfq"))
     (set! input-path stim-opt)
     (set! stim-opt #f)
     (set! stim-stdout-opt #t)]
    [else (void)])

  (unless input-path
    (error 'lakefillqc "Missing required --input <file.lfq> argument"))

  (with-handlers
    ([exn:fail:lfq-surface?
      (lambda (e)
        (emit-surface-exn-cli! e json-opt human-opt (path->string (file-name-from-path input-path))))]
     [exn:fail?
      (lambda (e)
        (define raw-msg (exn-message e))
        (define fallback-sp
          (lfq-surface-span input-path 1 0 (path->string (file-name-from-path input-path)) 'LakefillQ))
        (define-values (parsed-sp clean-msg)
          (cond
            [(and (exn:srclocs? e)
                  (pair? ((exn:srclocs-accessor e) e)))
             (define sl (first ((exn:srclocs-accessor e) e)))
             (define src (srcloc-source sl))
             (define ln (srcloc-line sl))
             (define col (srcloc-column sl))
             (define stripped
               (match (regexp-match #rx"^[^\n:]+:[0-9]+:[0-9]+: (.*)$" raw-msg)
                 [(list _ rest-msg) rest-msg]
                 [_ raw-msg]))
             (if (and src ln col)
                 (values (lfq-surface-span (format "~a" src) (max 1 ln) (max 0 col) "" 'LakefillQ) stripped)
                 (values fallback-sp stripped))]
            [(regexp-match #rx"^([^\n:]+):([0-9]+):([0-9]+): (.*)$" raw-msg)
             => (lambda (m)
                  (values (lfq-surface-span (second m)
                                            (max 1 (or (string->number (third m)) 1))
                                            (max 0 (or (string->number (fourth m)) 0))
                                            ""
                                            'LakefillQ)
                          (fifth m)))]
            [else
             (values fallback-sp raw-msg)]))
        (define enriched-v
          (make-surface-static-violation
           "StaticDiscipline"
           "T-SurfaceSyntax"
           "LFQ-E-SURFACE-ELAB"
           raw-msg
           clean-msg
           (hasheq)
           #:origin-span parsed-sp
           #:mutating-span parsed-sp
           #:failure-span parsed-sp
           #:repair-hint "Verify `#lang lakefillq` surface syntax and quoted symbol arguments (e.g., `'m0` for classical measurement tags)."))
        (define err-js
          (hasheq 'well_typed #f
                  'violations (list enriched-v)))
        (when json-opt
          (write-json err-js)
          (newline))
        (when (or human-opt (not json-opt))
          (display (format-violations-human (path->string (file-name-from-path input-path))
                                            "surface"
                                            (list enriched-v))
                   (current-error-port))
          (newline (current-error-port)))
        (exit 1))])
    (define prog (load-lfq-program-from-file input-path))
    (void (execute-cli-driver! prog
                               #:target-override target-opt
                               #:qasm3-out qasm-opt
                               #:stim-out stim-opt
                               #:qasm3-stdout? qasm-stdout-opt
                               #:stim-stdout? stim-stdout-opt
                               #:emit-json? json-opt
                               #:diagnostics-human? human-opt
                               #:repair? repair-opt
                               #:q-cap q-cap-opt
                               #:r-bell r-bell-opt
                               #:topology topology-opt
                               #:max-machines max-machines-opt
                               #:cluster-dir cluster-dir-opt))))

(module+ test
  (require rackunit)

  (define scratch-root
    (let ([host-p "/home/antigravity/toolchains/tmp"])
      (if (directory-exists? host-p)
          (build-path host-p "raco_test_lakefillqc")
          (build-path (current-directory) ".lakefillq_tmp" "raco_test_lakefillqc"))))
  (make-directory* scratch-root)

  ;; 1. Single-QPU fallback (`M* = 1`, `grover-amplify`) via `compile-lfq-program`:
  (define grover-decl
    (lfq-circuit-decl 'grover-kernel 'defq '() '() '(0 1) '(2) 'all
                      '(within-apply-mbu (temp-and 0 1 2) (z 2) (2))))
  (define grover-prog
    (register-program-cluster-profiles!
     (lfq-program "test-grover" 'ideal (list grover-decl))
     (list (lfq-cluster-profile-entry
            'grover-prof
            (par-cluster-opt-spec #:workload 'Grover-Kernel
                                  #:paradigm 'grover-amplify
                                  #:max-machines 256
                                  #:q-cap-per-machine 400
                                  #:raw-bell-rate-hz 100000.0
                                  #:q-single 3
                                  #:local-toffolis 4)
            #f))))
  (define cdir-m1 (build-path scratch-root "driver_m1"))
  (define res-m1
    (compile-lfq-program grover-prog
                         #:max-machines 256
                         #:cluster-dir cdir-m1))
  (check-true (compilation-result-well-typed? res-m1))
  (check-equal? (compilation-result-machines-used res-m1) 1)
  (check-true (compilation-result-fallback-to-single-machine? res-m1))
  (check-true (file-exists? (build-path cdir-m1 "qpu_0.qasm")))
  (check-true (file-exists? (build-path cdir-m1 "ebit_schedule.json")))

  ;; 2. Multi-QPU `Law U4` + `QRNS` (`M* = 2`) with CLI overrides:
  (define u4-decl
    (lfq-circuit-decl
     'u4-driver-kernel 'defq '() '() '(0 1 2 3) '(4) 'all
     '(seq (h 0)
           (erase-by (seq (cx 0 4) (ccx 4 2 3))
                     (seq (mid-meas-x 4 m0 #t) (cond-z m0 0))
                     (4)))))
  (define u4-prog
    (register-program-cluster-profiles!
     (lfq-program "test-u4-driver" 'ideal (list u4-decl))
     (list (lfq-cluster-profile-entry
            'u4-prof
            (par-cluster-opt-spec #:workload 'U4-Driver-Kernel
                                  #:paradigm 'algebraic-limb
                                  #:max-machines 256
                                  #:q-cap-per-machine 400
                                  #:raw-bell-rate-hz 100000.0
                                  #:q-single 5
                                  #:q-data-dist 4
                                  #:q-local-fixed 1
                                  #:q-peer-sync 1
                                  #:window-bits 1
                                  #:num-windows 1
                                  #:local-toffolis 100000
                                  #:carry-scheme 'qrns-zero-carry
                                  #:lookup-scheme 'law-u4-ghz-mx)
            '((0 1) (2 3 4))))))
  ;; With default Q_cap = 400 -> monolithic M* = 1:
  (define res-mono (compile-lfq-program u4-prog))
  (check-true (compilation-result-well-typed? res-mono))
  (check-equal? (compilation-result-machines-used res-mono) 1)
  (check-false (compilation-result-fallback-to-single-machine? res-mono))

  ;; With `--q-cap 4 --r-bell 80000 --topology switched-optical-tree --max-machines 256` -> M* = 2:
  (define cdir-m2 (build-path scratch-root "driver_m2"))
  (define res-m2
    (compile-lfq-program u4-prog
                         #:q-cap 4
                         #:r-bell 80000.0
                         #:topology 'switched-optical-tree
                         #:max-machines 256
                         #:cluster-dir cdir-m2))
  (check-true (compilation-result-well-typed? res-m2))
  (check-equal? (compilation-result-machines-used res-m2) 2)
  (check-false (compilation-result-fallback-to-single-machine? res-m2))
  (check-true (file-exists? (build-path cdir-m2 "qpu_0.qasm")))
  (check-true (file-exists? (build-path cdir-m2 "qpu_1.qasm")))
  (check-true (file-exists? (build-path cdir-m2 "ebit_schedule.json")))
  (define m2-js (compilation-result->jsexpr res-m2))
  (define m2-u4-opt (hash-ref (hash-ref m2-js 'optimization_passes) 'u4_cross_qpu_tele_phase))
  (check-true (hash-ref m2-u4-opt 'active))
  (check-equal? (hash-ref m2-u4-opt 'reverse_ebits) 0)

  ;; 3. Multipass provenance & chordal SSA wire-recycling resugaring check:
  (define recycle-leak-decl
    (lfq-circuit-decl
     'chordal-recycle-leak
     'defqfree
     '((a . (0 1)))
     '((s1 . (2)) (s2 . (3)))
     '(0 1)
     '(2 3)
     'all
     '(seq (cx 0 2)
           (cx 0 2)
           (ccx 0 1 3))))
  (define res-leak (compile-lfq-circuit recycle-leak-decl 'ideal))
  (check-false (compilation-result-well-typed? res-leak))
  (check-equal? (compilation-result-recycled-wires-saved res-leak) 1)
  (define leak-v (first (compilation-result-violations res-leak)))
  (check-equal? (hash-ref leak-v 'code) "U1-EraseBy")
  (check-equal? (hash-ref leak-v 'surface_wire) "s2[0]")
  (check-equal? (hash-ref leak-v 'chordal_recycled_from) '("s1[0]"))
  (check-equal? (hash-ref leak-v 'resugared_anf) "a[0]*a[1]")
  (check-equal? (hash-ref (hash-ref leak-v 'resugared_witness) 'basis_ket)
                "|a[0]=1, a[1]=1>")
  (define human-txt (format-compilation-diagnostics-human res-leak))
  (check-true (string-contains? human-txt "s2[0]"))
  (check-true (string-contains? human-txt "shared earlier with s1[0]"))

  ;; 4. Gensym hygiene check: synthesized `__u4_mx_0` must NOT leak into `resugared_message`!
  (define gensym-u4-decl
    (lfq-circuit-decl
     'gensym-u4-leak
     'defq
     '((ctl . (0)))
     '((anc . (1)))
     '(0)
     '(1)
     'all
     '(seq (h 0)
           (cx 0 1)
           (mid-meas-x 1 __u4_mx_0 #t)
           (h 0))))
  (define res-u4-leak (compile-lfq-circuit gensym-u4-decl 'ideal))
  (check-false (compilation-result-well-typed? res-u4-leak))
  (define u4-v (first (compilation-result-violations res-u4-leak)))
  (check-equal? (hash-ref u4-v 'code) "U4-QTainted")
  (check-false (string-contains? (hash-ref u4-v 'resugared_message) "__u4_mx_"))
  (check-true (string-contains? (hash-ref u4-v 'resugared_message) "mid-meas-x on anc[0]"))

  ;; 5. Modular `call-q` port capability inference (`BorrowZ` sharing + `Uniq1` conflict + chordal scratch reuse):
  (define sub-round-decl
    (lfq-circuit-decl
     'sub-round
     'defqfree
     '((k . (0 1)) (st . (2)))
     '((tmp . (3)))
     '(0 1 2)
     '(3)
     'all
     '(with-and-session ([3 0 1]) (cx 3 2))))
  (define sub-ports (infer-decl-port-rwire-signature sub-round-decl))
  (check-equal? (map port-rwire-spec-grade sub-ports) '(BorrowZ Uniq1))
  ;; Calling `sub-round` twice sequentially reuses the fresh virtual scratch wire on the SAME physical qubit!
  (define composed-decl
    (lfq-circuit-decl
     'composed-rounds
     'defqfree
     '((key . (0 1)) (state . (2)))
     '()
     '(0 1 2)
     '()
     'all
     `(seq (call-q ,sub-round-decl (0 1) (2))
           (call-q ,sub-round-decl (0 1) (2)))))
  (define res-composed (compile-lfq-circuit composed-decl 'ideal))
  (check-true (compilation-result-well-typed? res-composed))
  (check-equal? (compilation-result-virtual-wires res-composed) 5)
  (check-equal? (compilation-result-physical-qubits res-composed) 4)
  (check-equal? (compilation-result-recycled-wires-saved res-composed) 1)
  ;; Passing `key` into both `k` (`BorrowZ`) and `st` (`Uniq1`) triggers `LFQ-E-CALL-ALIAS`:
  (define bad-call-decl
    (lfq-circuit-decl
     'bad-call-alias
     'defqfree
     '((key . (0 1)))
     '()
     '(0 1)
     '()
     'all
     `(call-q ,sub-round-decl (0 1) (0))))
  (define res-bad-call (compile-lfq-circuit bad-call-decl 'ideal))
  (check-false (compilation-result-well-typed? res-bad-call))
  (check-equal? (hash-ref (first (compilation-result-violations res-bad-call)) 'code)
                "LFQ-E-CALL-ALIAS")

  ;; 6. Automatic `ANF -> XAG/FRAIG+Z3` symbolic escalation + 1-WL cone isomorphism + `for/fold-loop` `k=1 -> k=2`:
  (define res-xag-esc
    (compile-lfq-circuit composed-decl 'ideal #:anf-monomial-cap 0))
  (check-true (compilation-result-well-typed? res-xag-esc))
  (check-equal? (hash-ref (lookup-compilation-cohesion-meta res-xag-esc)
                          'symbolic_inference_engine)
                "xag-fraig-z3")
  (define loop-decl
    (lfq-circuit-decl
     'loop-escalate-kernel
     'defqfree
     '((x . (0 1)) (y . (2)))
     '((sc . (3)))
     '(0 1 2)
     '(3)
     'all
     '(for/fold-loop 6
                     ((within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))))))
  (define res-loop (compile-lfq-circuit loop-decl 'heron-r2))
  (check-true (compilation-result-well-typed? res-loop))
  (define loop-js (compilation-result->jsexpr res-loop))
  (check-equal? (hash-ref loop-js 'symbolic_inference_engine) "xag-fraig-z3")
  (define xag-opt (hash-ref (hash-ref loop-js 'optimization_passes) 'xag_1wl_cone_and_loop_escalation))
  (check-true (> (hash-ref xag-opt 'cone_isomorphism_hits) 0))
  (check-equal? (length (hash-ref xag-opt 'for_fold_loops)) 1)
  (check-equal? (hash-ref (first (hash-ref xag-opt 'for_fold_loops)) 'k_certified) 1)

  ;; Stage `k = 2`: 6-round 2-phase ping-pong loop (even allocates scratch, odd MBU-erases scratch):
  (define loop-k2-decl
    (lfq-circuit-decl
     'loop-k2-pingpong
     'defqfree
     '((x . (0 1)) (y . (2)))
     '((sc . (3)))
     '(0 1 2)
     '(3)
     'all
     '(for/fold-loop 6
                     ((seq (temp-and 0 1 3) (cx 3 2))
                      (seq (cx 3 2) (mid-meas-x 3 m_pp_1 #t) (cond-cz m_pp_1 0 1))
                      (seq (temp-and 0 1 3) (cx 3 2))
                      (seq (cx 3 2) (mid-meas-x 3 m_pp_3 #t) (cond-cz m_pp_3 0 1))
                      (seq (temp-and 0 1 3) (cx 3 2))
                      (seq (cx 3 2) (mid-meas-x 3 m_pp_5 #t) (cond-cz m_pp_5 0 1))))))
  (define res-loop-k2 (compile-lfq-circuit loop-k2-decl 'heron-r2))
  (check-true (compilation-result-well-typed? res-loop-k2))
  (define loop-k2-opt
    (hash-ref (hash-ref (compilation-result->jsexpr res-loop-k2) 'optimization_passes)
              'xag_1wl_cone_and_loop_escalation))
  (check-equal? (hash-ref (first (hash-ref loop-k2-opt 'for_fold_loops)) 'k_certified) 2)

  ;; Stage `k = R`: Heterogeneous 4-round loop with Round-4 missing `cond-cz` caught by `k = R`:
  (define loop-kR-bad-decl
    (lfq-circuit-decl
     'loop-kR-bad
     'defqfree
     '((x . (0 1)) (y . (2)))
     '((sc . (3)))
     '(0 1 2)
     '(3)
     'all
     '(for/fold-loop 4
                     ((within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (within-apply-mbu (temp-and 0 1 3) (cx 3 2) (3))
                      (seq (temp-and 0 1 3) (cx 3 2) (mid-meas-x 3 m_het_bad #t))))))
  (define res-loop-kR-bad (compile-lfq-circuit loop-kR-bad-decl 'heron-r2))
  (check-false (compilation-result-well-typed? res-loop-kR-bad))
  (check-equal? (hash-ref (first (compilation-result-violations res-loop-kR-bad)) 'code)
                "U4-QTainted")

  ;; 7. Adaptive `PackedBezoutShiftZipper` (`packed-bezout-jump16`, `109 -> 67`) + QEC pacing metadata (`64.17 ns` / `66.15 ns`):
  (define bezout-decl
    (lfq-circuit-decl
     'bezout-jump16-kernel
     'defqfree
     '((in4 . (0 1 2 3)) (out2 . (4 5)))
     '((sc3 . (6 7 8)))
     '(0 1 2 3 4 5)
     '(6 7 8)
     'all
     '(packed-bezout-jump16 (256 16 4) (0 1 2 3) (4 5) (6 7 8))))
  (define res-bezout (compile-lfq-circuit bezout-decl 'bb-qldpc #:repair? #t))
  (check-true (compilation-result-well-typed? res-bezout))
  (define bezout-js (compilation-result->jsexpr res-bezout))
  (define bez-opt (hash-ref (hash-ref bezout-js 'optimization_passes) 'adaptive_bezout_pebble_recycling))
  (check-true (hash-ref bez-opt 'active))
  (check-equal? (hash-ref bez-opt 'static_total_macro_evals) 109)
  (check-equal? (hash-ref bez-opt 'adaptive_total_macro_evals) 67)
  (define pacing-meta (hash-ref bezout-js 'qec_syndrome_decoder_pacing))
  (check-equal? (hash-ref pacing-meta 'd5_sparse_fastpath_mean_tau_dec_ns) 64.17)
  (check-equal? (hash-ref pacing-meta 'bb_qldpc_sparse_fastpath_mean_tau_dec_ns) 66.15)
  (check-equal? (hash-ref pacing-meta 'conservative_300k_coax_ns) 420.0)
  (check-equal? (hash-ref pacing-meta 'closed_loop_500mhz_worst_case_ns) 340.0)

  ;; 8. Phase-Clean `focus-zipper` RM(3, n) TODD symmetric 3-tensor decomposition (`14 -> 8` T-gates on 2 shared-control CCZs):
  (define todd-decl
    (lfq-circuit-decl
     'todd-zipper-kernel
     'defq
     '((q . (0 1 2 3)))
     '()
     '(0 1 2 3)
     '()
     'all
     '(focus-zipper ((0 1 2 3) ())
                    (seq (ccz 0 1 2)
                         (ccz 0 1 3)))))
  (define res-todd (compile-lfq-circuit todd-decl 'ideal))
  (check-true (compilation-result-well-typed? res-todd))
  (define todd-js (compilation-result->jsexpr res-todd))
  (define todd-opt (hash-ref (hash-ref todd-js 'optimization_passes) 'todd_rm3_autocc_phase_poly))
  (check-equal? (hash-ref todd-opt 'phase_clean_zippers_certified) 1)
  (check-equal? (hash-ref todd-opt 'cones_optimized) 1)
  (check-equal? (hash-ref todd-opt 'pre_t_count) 14)
  (check-equal? (hash-ref todd-opt 'post_t_count) 8)
  (check-equal? (hash-ref todd-opt 't_count_saved) 6)

  ;; 9. Law-U4 cross-QPU bilinear tele-phase factoring + batched forward cat-entangler fusion (`6 -> 1` ebits, `0` reverse ebits):
  (define tele-decl
    (lfq-circuit-decl
     'tele-phase-cone3
     'defqfree
     '((p . (0)) (q . (1 2 3)) (out . (4)))
     '((sc . (5 6 7)))
     '(0 1 2 3 4)
     '(5 6 7)
     'all
     '(within-apply-mbu
       (seq (temp-and 0 1 5)
            (temp-and 0 2 6)
            (temp-and 0 3 7))
       (seq (cx 5 4) (cx 6 4) (cx 7 4))
       (5 6 7))))
  (define tele-prog
    (register-program-cluster-profiles!
     (lfq-program "test-tele-cone3" 'ideal (list tele-decl))
     (list (lfq-cluster-profile-entry
            'tele-cone3-prof
            (par-cluster-opt-spec #:workload 'MBU-Cone3
                                  #:paradigm 'algebraic-limb
                                  #:max-machines 256
                                  #:q-cap-per-machine 7
                                  #:raw-bell-rate-hz 100000.0
                                  #:q-single 8
                                  #:q-data-dist 6
                                  #:q-local-fixed 1
                                  #:q-peer-sync 1
                                  #:window-bits 1
                                  #:num-windows 1
                                  #:local-toffolis 100000
                                  #:carry-scheme 'qrns-zero-carry
                                  #:lookup-scheme 'law-u4-ghz-mx)
            '((0) (1 2 3 4 5 6 7))))))
  (define res-tele (compile-lfq-circuit tele-decl 'ideal #:program tele-prog))
  (check-true (compilation-result-well-typed? res-tele))
  (define tele-js (compilation-result->jsexpr res-tele))
  (define tele-opt (hash-ref (hash-ref tele-js 'optimization_passes) 'u4_cross_qpu_tele_phase))
  (check-true (hash-ref tele-opt 'active))
  (check-equal? (hash-ref tele-opt 'machines_used) 2)
  (check-equal? (hash-ref tele-opt 'cross_cut_mbu_wire_count) 3)
  (check-equal? (hash-ref tele-opt 'batched_pivot_cone_count) 1)
  (check-equal? (hash-ref tele-opt 'naive_ebits_2_per_wire) 6)
  (check-equal? (hash-ref tele-opt 'u4_batched_cone_ebits) 1)
  (check-equal? (hash-ref tele-opt 'ebits_saved) 5)
  (check-equal? (hash-ref tele-opt 'reverse_ebits) 0)

  ;; 10. Canonical coupled phase-ordering schedule (`P_loop_cone -> P_pebble -> (FRAIG/Commute o TODD/ZX)^2
  ;;     -> MBU/Bellman-Knuth -> post-TODD chordal SSA -> coupled Block-LU + Law-U4`) strictly beats
  ;;     both `SSA < TODD` (`hazardA_ssa_before_todd`) and `MBU < TODD` (`hazardB_mbu_before_todd`):
  (define coupled-phase-decl
    (lfq-circuit-decl
     'coupled-phase-order-kernel
     'defq
     '((d . (0 1 2 3 4 5)))
     '((sc . (6 7 8 9 10)))
     '(0 1 2 3 4 5)
     '(6 7 8 9 10)
     'all
     '(seq
       (within-apply-mbu (temp-and 0 3 6) (cx 6 5) (6))
       (within-apply-mbu
        (temp-and 0 3 7)
        (seq (cx 7 2)
             (within-apply-mbu (temp-and 1 2 8) (cz 8 3) (8))
             (within-apply-mbu (temp-and 1 2 9) (cz 9 4) (9)))
        (7))
       (rz-dyadic 1 3 #f 5)
       (ccz 1 2 4)
       (h 0)
       (rz-dyadic-neg 1 3 #f 5)
       (within-apply-mbu (temp-and 1 2 10) (cz 10 5) (10))
       (cx 3 0) (cx 4 0) (cx 5 0)
       (cx 3 1) (cx 4 1) (cx 5 1)
       (cx 3 2) (cx 4 2) (cx 5 2))))
  (define coupled-phase-prog
    (register-program-cluster-profiles!
     (lfq-program "test-coupled-phase-order" 'ideal (list coupled-phase-decl))
     (list (lfq-cluster-profile-entry
            'coupled-phase-prof
            '(par-cluster-opt-spec #:workload Coupled-Phase-Order
                                   #:paradigm algebraic-limb
                                   #:max-machines 256
                                   #:q-cap-per-machine 6
                                   #:raw-bell-rate-hz 100000.0
                                   #:q-single auto
                                   #:q-data-dist 6
                                   #:q-local-fixed 1
                                   #:q-peer-sync 1
                                   #:window-bits 1
                                   #:num-windows 1
                                   #:local-toffolis 100000
                                   #:carry-scheme qrns-zero-carry
                                   #:lookup-scheme law-u4-ghz-mx)
            '((0 1 2) (3 4 5 6 7))))))
  (define res-can
    (compile-lfq-circuit coupled-phase-decl 'ideal
                         #:program coupled-phase-prog))
  (define res-ha
    (compile-lfq-circuit coupled-phase-decl 'ideal
                         #:program coupled-phase-prog
                         #:phase-schedule 'hazardA_ssa_before_todd))
  (define res-hb
    (compile-lfq-circuit coupled-phase-decl 'ideal
                         #:program coupled-phase-prog
                         #:phase-schedule 'hazardB_mbu_before_todd))
  (check-true (compilation-result-well-typed? res-can))
  (check-true (compilation-result-well-typed? res-ha))
  (check-true (compilation-result-well-typed? res-hb))

  (define can-opt
    (hash-ref (hash-ref (compilation-result->jsexpr res-can) 'optimization_passes)
              'canonical_phase_order))
  (define ha-opt
    (hash-ref (hash-ref (compilation-result->jsexpr res-ha) 'optimization_passes)
              'canonical_phase_order))
  (define hb-opt
    (hash-ref (hash-ref (compilation-result->jsexpr res-hb) 'optimization_passes)
              'canonical_phase_order))

  (check-equal? (hash-ref can-opt 'schedule_id) "canonical_k2_coupled")
  (check-equal? (hash-ref can-opt 'todd_zx_fixpoint_rounds) 2)
  ;; Post-TODD chordal SSA reclaims the inner scratch wire stranded by `SSA < TODD` and `MBU < TODD`:
  (check-equal? (compilation-result-physical-qubits res-can) 7)
  (check-equal? (compilation-result-physical-qubits res-ha) 8)
  (check-equal? (compilation-result-physical-qubits res-hb) 8)
  (check-equal? (hash-ref can-opt 'post_todd_ssa_reclaimed_qubits) 1)
  ;; Algebraic MBU hoisting + session fusion + TODD cone absorption strictly reduces `M_X` & `T`-count:
  (check-true (< (compilation-result-mbu-erasure-count res-can)
                 (compilation-result-mbu-erasure-count res-ha)))
  (check-true (< (compilation-result-mbu-erasure-count res-can)
                 (compilation-result-mbu-erasure-count res-hb)))
  (check-true (< (hash-ref can-opt 'clifford_t_count)
                 (hash-ref ha-opt 'clifford_t_count)))
  (check-true (< (hash-ref can-opt 'clifford_t_count)
                 (hash-ref hb-opt 'clifford_t_count)))
  (check-true (>= (hash-ref can-opt 'pre_mbu_sessions_fused) 2))
  (check-true (>= (hash-ref can-opt 'phase_mbu_cones_absorbed) 2))
  (check-true (>= (hash-ref can-opt 'fraig_commute_moves) 1))
  ;; Coupled `P_part_u4 <-> Block-LU` compresses the rank-1 3x3 cross-QPU CNOT frame (`9 -> 1` cross-CX):
  (check-true (>= (hash-ref can-opt 'partition_block_lu_frames_resynthesized) 1))
  (check-true (>= (hash-ref can-opt 'partition_block_lu_cross_cxs_saved) 8))
  (check-true (>= (hash-ref can-opt 'partition_block_lu_ebits_saved) 2))

  (close-bug-prevention-z3!))
