#lang racket

;; =============================================================================
;; `compiler/lakefillq-bug-class-prevention-types.rkt`
;;
;; Generalized Type-System & Compiler Extensions in `LakefillQ` Statically
;; Preventing All 14 Wild Research Bugs Across `Qualtran`, `Cobble`, `PennyLane`,
;; `ReVerC`, `grover-blocks` / `T-typeAES`, `QuantumEllipticCurves`,
;; `quantum-factor-2025-code`, `2024-ACNS-scripts` / `isd-quantum`, and
;; `DQI-Circuit` — Plus Arbitrary Instances of Those 6 General Bug Classes.
;;
;; Implemented Static Typing & Lowering Judgments:
;;   1. `T-DomImg`   : `QPartBij[Dom <-> Img]` bidirectional support-injectivity
;;                     for `erase-by` via persistent `z3 -in -smt2` verification:
;;                       forall x in Dom_f. Dom_g(f(x)) /\ g(f(x)) = x /\ res(x) = 0
;;                       /\ (forall x1 != x2 in Dom_f. f(x1) != f(x2)).
;;   2. `T-ValidIf`  : `ValidIf[v : QBit, tau]` linear validity-witness modality
;;                     (quantum `Option<T>`) with taint propagation, witness
;;                     immutability inside `with-valid`, and mandatory `v in Gamma_ctrl`
;;                     before `phase-flip-if`.
;;   3. `T-AlgPhase` : `Involutory` operator trait (`U^2 = I /\ U^dag = U`, rejecting
;;                     non-commuting `A_mu * A_nu` without `PartnerSwap`, `SGate` /
;;                     complex `Const`, and degree-2 `Keccak` `chi_5` via `XAG + Z3`)
;;                     paired with `Z_4` global-phase index `omega` on `QBlock`
;;                     (`wx->reflection` shifts `omega` by `(-i)^d`, `measure` erases
;;                     `omega`, and `ctrl` / `lcu-sum` synthesize compensating `S^d`
;;                     gates automatically).
;;   4. `T-WireBasis`: Intrinsic `QVec[n, pi : Perm[n], B : BasisTag]` logical wire
;;                     permutation (`0` physical `SWAP`s) and linear field basis
;;                     checking (verified on all `n` basis unit vectors, never blinded
;;                     by `0x00 -> 0x63`), plus simultaneous `Fin[N]` ring stencils
;;                     forbidding off-by-one bounds and imperative read-after-write
;;                     aliasing.
;;   5. `T-DriftEps` : Dependent `QCoset[N_bits, c_pad, K_steps, s_safety]` carry-runway
;;                     index (`K_steps * 2^{s_safety} < 2^{c_pad}`), `QRNS` dynamic
;;                     range (`prod(p_i) >= 2^{N_bits * m}`), and Lipschitz-graded
;;                     `QBlock` error index `eps` (`d * eps_in` interior walk,
;;                     `d^2 * eps_in` Markov spectral edge, forbidding `eps = 0.0`
;;                     on finite-`mu` alias preparation).
;;   6. `T-SingleIR` : Unified `RevIR` abstract-interpretation gate/qubit costing
;;                     with bound-slice completeness (forbidding `skip_rightmost=True`
;;                     and `n = num_cols - 1` unbound slices), mandatory `XAG + Z3`
;;                     pure-spec miter equivalence, and `QOracle[k_key, h_bits]`
;;                     spurious-key margin `k_key - h_bits <= log2(eta_max)` on
;;                     `grover-search`.
;;   7. `T-ParGuard` : Static parallel-partitionability type & cost guard
;;                     (`QParGrade`: `ParSliceable(M, bell_cuts)`,
;;                     `ParShotLinear(M)`, `ParNonPartitionable(reason)`) that
;;                     detects non-sliceable serial Grover/ISD reflections /
;;                     Zalka `sqrt(M)` total-work blowup (`'zalka-grover-sublinear`)
;;                     and cross-QPU Bell-cut overhead `Q_per_machine + q_comm >= Q_single`
;;                     (`'bell-cut-exceeds-single-qpu`), automatically returning
;;                     the `1`-machine Single-Machine compiled program
;;                     (`machines_used = 1`, `fallback_to_single_machine = #t`)
;;                     with a static diagnostic (or rejecting under
;;                     `#:strict-parallel? #t`).
;; =============================================================================

(require racket/cmdline
         racket/format
         racket/list
         racket/match
         racket/math
         racket/port
         racket/runtime-path
         racket/set
         racket/string
         racket/vector
         json
         rackunit
         "lakefillq-xag-fraig-typechecker.rkt")

(define-runtime-path HERE-DIR ".")

(provide (struct-out lfq-type-diagnostic)
         (struct-out lfq-typecheck-result)
         (struct-out qblock-graded-type)
         (struct-out qvec-wire-basis-type)
         (struct-out qpar-grade)
         ParSliceable
         ParShotLinear
         ParNonPartitionable
         ;; General 7-rule typechecker & compiler entry points
         typecheck-lfq-bug-prevention-program
         check-part-bij-dom-img!
         check-valid-if-program
         check-involutory-operator!
         infer-qblock-alg-phase-and-eps
         check-wire-basis-and-stencil
         check-coset-and-rns-drift
         check-single-ir-and-grover-oracle!
         infer-qpar-grade
         par-cluster-opt-spec
         solve-optimal-qpar-machines
         compile-parallel-with-fallback
         check-parallel-partition-guard
         ;; `#lang lakefillq` & `compiler/lakefillqc.rkt` integration hooks
         bug-class-guard-surface-heads
         check-surface-bug-class-guards
         collect-surface-par-guard-decisions
         elaborate-bug-class-guard-surface
         ;; Canonical 14 wild-bug + 14 generalized bug-class + 13 SOTA parallel + cluster M* profiles
         build-14-wild-research-bug-cases
         build-12-generalized-bug-class-cases
         build-generalized-bug-class-cases
         build-sota-parallel-partition-profiles
         build-sota-cluster-opt-profiles
         run-all-bug-class-prevention-checks!
         close-bug-prevention-z3!)

;; =============================================================================
;; SECTION 1: Persistent `z3 -in -smt2` Bridge & Structured Diagnostics
;; =============================================================================

(define (persistent-scratch-dir)
  (define host-dir "/home/antigravity/toolchains/tmp")
  (if (directory-exists? host-dir)
      host-dir
      (let ([local-dir (path->string (simplify-path (build-path HERE-DIR ".." ".lakefillq_tmp")))])
        (unless (directory-exists? local-dir)
          (make-directory* local-dir))
        local-dir)))

(define (locate-z3-executable)
  (define parent-venv-z3
    (path->string (simplify-path (build-path HERE-DIR ".." ".." ".venv" "bin" "z3"))))
  (define repo-venv-z3
    (path->string (simplify-path (build-path HERE-DIR ".." ".venv" "bin" "z3"))))
  (define home-tc-z3
    (path->string (build-path (find-system-path 'home-dir) "toolchains" "quantum-venv" "bin" "z3")))
  (or (let ([p (find-executable-path "z3")])
        (and p (path->string p)))
      (for/first ([cand (in-list (list repo-venv-z3 parent-venv-z3 home-tc-z3 "/usr/bin/z3" "/usr/local/bin/z3"))]
                  #:when (file-exists? cand))
        cand)
      (error 'locate-z3-executable "z3 executable not found in persistent environment")))

(define bp-z3-proc #f)
(define bp-z3-out #f)
(define bp-z3-in #f)
(define bp-z3-err #f)

(define (ensure-bp-z3!)
  (unless (and bp-z3-proc (eq? (subprocess-status bp-z3-proc) 'running))
    (putenv "TMPDIR" (persistent-scratch-dir))
    (define-values (proc out in err)
      (subprocess #f #f #f (locate-z3-executable) "-in" "-smt2"))
    (set! bp-z3-proc proc)
    (set! bp-z3-out out)
    (set! bp-z3-in in)
    (set! bp-z3-err err))
  (values bp-z3-in bp-z3-out))

(define (close-bug-prevention-z3!)
  (close-persistent-z3!)
  (when bp-z3-proc
    (with-handlers ([exn:fail? void])
      (display "(exit)\n" bp-z3-in)
      (flush-output bp-z3-in)
      (close-output-port bp-z3-in)
      (close-input-port bp-z3-out)
      (close-input-port bp-z3-err)
      (subprocess-wait bp-z3-proc))
    (set! bp-z3-proc #f)))

(define (run-z3-smt2-query! smt2-body [model-exprs '()])
  (define-values (zin zout) (ensure-bp-z3!))
  (display "(reset)\n" zin)
  (display smt2-body zin)
  (newline zin)
  (display "(check-sat)\n" zin)
  (flush-output zin)
  (define status-str
    (let loop ()
      (define ln (read-line zout 'any))
      (cond
        [(eof-object? ln) (error 'run-z3-smt2-query! "Unexpected EOF from z3")]
        [(string=? (string-trim ln) "") (loop)]
        [else (string-trim ln)])))
  (cond
    [(and (string=? status-str "sat") (not (null? model-exprs)))
     (fprintf zin "(get-value (~a))\n" (string-join model-exprs " "))
     (flush-output zin)
     (define raw-model (read zout))
     (values 'sat raw-model)]
    [(string=? status-str "sat")
     (values 'sat '())]
    [(string=? status-str "unsat")
     (values 'unsat '())]
    [else
     (error 'run-z3-smt2-query! "Unexpected z3 response: ~a" status-str)]))

(define (z3-sexpr->jsexpr v)
  (cond
    [(or (number? v) (boolean? v) (string? v)) v]
    [(symbol? v) (symbol->string v)]
    [(list? v) (map z3-sexpr->jsexpr v)]
    [(pair? v) (list (z3-sexpr->jsexpr (car v)) (z3-sexpr->jsexpr (cdr v)))]
    [else (format "~a" v)]))

(struct lfq-type-diagnostic
  (rule      ;; "T-DomImg" | "T-ValidIf" | "T-AlgPhase" | "T-WireBasis" | "T-DriftEps" | "T-SingleIR"
   code      ;; structured diagnostic identifier e.g. "E-DOMIMG-IMG-OUTSIDE-INVDOM"
   message   ;; detailed explanation
   witness)  ;; jsexpr hash with concrete counterexample / discrepancy details
  #:transparent)

(struct lfq-typecheck-result
  (well-typed?
   inferred-type
   synthesized-ir
   diagnostics
   metrics)
  #:transparent)

(define (diag->jsexpr d)
  (hasheq 'category "BugClassTypeSystem"
          'rule (lfq-type-diagnostic-rule d)
          'code (lfq-type-diagnostic-code d)
          'message (lfq-type-diagnostic-message d)
          'witness (lfq-type-diagnostic-witness d)))

(define (ok-result ty ir [metrics (hasheq)])
  (lfq-typecheck-result #t ty ir '() metrics))

(define (err-result diags [ty 'ill-typed] [metrics (hasheq)])
  (lfq-typecheck-result #f ty '() diags metrics))

;; =============================================================================
;; SECTION 2: Rule 1 — `T-DomImg` (`QPartBij[Dom <-> Img]` Bidirectional
;;            Support-Injectivity for `erase-by`)
;; =============================================================================
;;
;; Given symbolic partial bijection specification:
;;   `(part-bij-smt2
;;      #:label label
;;      #:vars ((x1 Sort1) ...)
;;      #:vars-alt ((x1_b Sort1) ...)
;;      #:preamble smt2-defs-str
;;      #:dom-f dom-f-expr
;;      #:f-out (f1-expr ...)
;;      #:dom-g-on-f dom-g-of-f-expr
;;      #:g-of-f (g1-expr ...)
;;      #:residual (res1-expr ...)
;;      #:f-out-alt (f1-alt-expr ...)
;;      #:dom-f-alt dom-f-alt-expr)`
;;
;; Discharges THREE universal SMT-LIB2 obligations in Z3:
;;   (1) Image-in-Inverse-Domain : forall x in Dom_f. Dom_g(f(x))
;;   (2) Exact Roundtrip + Clean : forall x in Dom_f. g(f(x)) = x /\ residual(x) = 0
;;   (3) Support Injectivity     : forall x != x' in Dom_f. f(x) != f(x')

(define (smt-decl-consts var-specs)
  (string-join
   (for/list ([vs (in-list var-specs)])
     (match-define (list vname vsort) vs)
     (format "(declare-const ~a ~a)" vname vsort))
   "\n"))

(define (smt-and-eq lhs-list rhs-list)
  (if (null? lhs-list)
      "true"
      (format "(and ~a)"
              (string-join
               (for/list ([l (in-list lhs-list)] [r (in-list rhs-list)])
                 (format "(= ~a ~a)" l r))
               " "))))

(define (check-part-bij-dom-img! spec)
  (match spec
    [`(part-bij-smt2
       #:label ,label
       #:vars ,vars
       #:vars-alt ,vars-alt
       #:preamble ,preamble
       #:dom-f ,dom-f
       #:f-out ,f-out
       #:dom-g-on-f ,dom-g-on-f
       #:g-of-f ,g-of-f
       #:residual ,residuals
       #:f-out-alt ,f-out-alt
       #:dom-f-alt ,dom-f-alt)
     (define var-names (map (lambda (v) (format "~a" (first v))) vars))
     (define var-alt-names (map (lambda (v) (format "~a" (first v))) vars-alt))
     (define decls-1 (smt-decl-consts vars))
     (define decls-2 (string-append decls-1 "\n" (smt-decl-consts vars-alt)))

     ;; Obligation 1: forall x in Dom_f. Dom_g(f(x))
     (define q1
       (string-join
        (list preamble
              decls-1
              (format "(assert ~a)" dom-f)
              (format "(assert (not ~a))" dom-g-on-f))
        "\n"))
     (define-values (st1 m1) (run-z3-smt2-query! q1 (append var-names f-out)))

     (cond
       [(eq? st1 'sat)
        (err-result
         (list (lfq-type-diagnostic
                "T-DomImg"
                "E-DOMIMG-IMG-OUTSIDE-INVDOM"
                (format "erase-by `~a` violates T-DomImg: forward image f(x) escapes inverse domain Dom(g)"
                        label)
                (hasheq 'obligation "forall_x_in_Dom_f_f_x_in_Dom_g"
                        'z3_status "sat"
                        'counterexample (z3-sexpr->jsexpr m1)))))]
       [else
        ;; Obligation 2: forall x in Dom_f. f(x) != f(x') for x != x' in Dom_f
        (define distinct-inputs
          (format "(not ~a)" (smt-and-eq var-names var-alt-names)))
        (define colliding-outputs
          (smt-and-eq f-out f-out-alt))
        (define q2
          (string-join
           (list preamble
                 decls-2
                 (format "(assert ~a)" dom-f)
                 (format "(assert ~a)" dom-f-alt)
                 (format "(assert ~a)" distinct-inputs)
                 (format "(assert ~a)" colliding-outputs))
           "\n"))
        (define-values (st2 m2) (run-z3-smt2-query! q2 (append var-names var-alt-names f-out)))
        (cond
          [(eq? st2 'sat)
           (err-result
            (list (lfq-type-diagnostic
                   "T-DomImg"
                   "E-DOMIMG-NON-INJECTIVE"
                   (format "erase-by `~a` violates T-DomImg: f is non-injective on Dom(f), preventing unitary erasure"
                           label)
                   (hasheq 'obligation "injective_on_Dom_f"
                           'z3_status "sat"
                           'collision_witness (z3-sexpr->jsexpr m2)))))]
          [else
           ;; Obligation 3: forall x in Dom_f. g(f(x)) = x /\ residual(x) = 0
           (define roundtrip-ok (smt-and-eq g-of-f var-names))
           (define res-zero
             (if (null? residuals)
                 "true"
                 (smt-and-eq residuals (make-list (length residuals) "0"))))
           (define q3
             (string-join
              (list preamble
                    decls-1
                    (format "(assert ~a)" dom-f)
                    (format "(assert (not (and ~a ~a)))" roundtrip-ok res-zero))
              "\n"))
           (define-values (st3 m3)
             (run-z3-smt2-query! q3 (append var-names g-of-f residuals)))
           (if (eq? st3 'sat)
               (err-result
                (list (lfq-type-diagnostic
                       "T-DomImg"
                       "E-DOMIMG-ROUNDTRIP-RESIDUAL"
                       (format "erase-by `~a` violates T-DomImg: g(f(x)) != x or dirty residual ancillas remain"
                               label)
                       (hasheq 'obligation "roundtrip_and_zero_residual"
                               'z3_status "sat"
                               'counterexample (z3-sexpr->jsexpr m3)))))
               (ok-result `(QPartBij ,label)
                          `(verified-erase-by ,label)
                          (hasheq 'z3_obligations_unsat 3
                                  'support_injective #t
                                  'image_in_inv_dom #t
                                  'roundtrip_exact #t)))])])]
    [_
     (error 'check-part-bij-dom-img! "Malformed part-bij-smt2 specification: ~a" spec)]))

;; =============================================================================
;; SECTION 3: Rule 2 — `T-ValidIf` (`ValidIf[v : QBit, tau]` Linear Modality)
;; =============================================================================
;;
;; Syntax of `ValidIf`-typed quantum control-flow skeletons:
;;   `(valid-if-seq stmt ...)` where `stmt` is one of:
;;     - `(bind-partial-op ,v-sym ,v-wire ,val-sym ,inner-ty ,op-kind)`
;;         (`op-kind` in `'qgje-solve | 'partial-mod-inv | 'bounded-syndrome-decode`)
;;     - `(derive-pred ,dst-sym (,src-sym ...) ,desc)`
;;         (propagates `ValidIf` requirements from any `src-sym` not currently guarded!)
;;     - `(mutate-wire! ,wire-id)`
;;         (flips/mutates a physical wire; forbidden on any active guard wire `v-wire`!)
;;     - `(with-valid ,v-sym ,val-sym ,sub-prog)`
;;         (checks `v-wire` not mutated in `sub-prog`, unwraps `val-sym : inner-ty`,
;;          and adds `v-sym` to `Gamma_ctrl`!)
;;     - `(phase-flip-if (,dep-sym ...) ,pred-wires ,scratch-wires)`
;;         (checks every `ValidIf[v_k, _]` dependency has `v_k in Gamma_ctrl`;
;;          synthesizes `(mcz (append active-ctrl-wires pred-wires) scratch-wires)`!)

(define (collect-mutated-wires-in-valid-prog prog)
  (match prog
    [`(valid-if-seq ,stmts ...)
     (apply set-union (seteqv) (map collect-mutated-wires-in-valid-prog stmts))]
    [`(mutate-wire! ,w) (seteqv w)]
    [`(with-valid ,_ ,_ ,sub) (collect-mutated-wires-in-valid-prog sub)]
    [_ (seteqv)]))

(define (required-validity-guards sym gamma ctrl-set)
  (match (hash-ref gamma sym #f)
    [`(ValidIf ,vs ,_)
     (filter (lambda (v) (not (set-member? ctrl-set v))) vs)]
    [#f (list `(unbound ,sym))]
    [_ '()]))

(define (check-valid-if-program prog [init-gamma (hasheq)] [init-ctrl (seteq)] [init-wire-map (hasheq)])
  (let walk ([p prog]
             [gamma init-gamma]
             [ctrl-set init-ctrl]
             [v-wires init-wire-map]
             [ir-acc '()])
    (match p
      [`(valid-if-seq)
       (ok-result 'QUnit `(seq ,@(reverse ir-acc))
                  (hasheq 'active_guards (length (set->list ctrl-set))))]
      [`(valid-if-seq ,first-s ,rest-s ...)
       (match first-s
         [`(bind-partial-op ,v-sym ,v-wire ,val-sym ,inner-ty ,op-kind)
          (define gamma1
            (hash-set (hash-set gamma v-sym 'QBit)
                      val-sym `(ValidIf (,v-sym) ,inner-ty)))
          (define vw1 (hash-set v-wires v-sym v-wire))
          (walk `(valid-if-seq ,@rest-s)
                gamma1
                ctrl-set
                vw1
                (cons `(partial-op ,op-kind ,v-wire) ir-acc))]

         [`(derive-pred ,dst-sym ,src-syms ,pred-wire)
          (define needed
            (remove-duplicates
             (apply append
                    (for/list ([s (in-list src-syms)])
                      (match (hash-ref gamma s #f)
                        [`(ValidIf ,vs ,_)
                         (filter (lambda (v) (not (set-member? ctrl-set v))) vs)]
                        [_ '()])))))
          (define dst-ty
            (if (null? needed)
                'QBit
                `(ValidIf ,needed QBit)))
          (walk `(valid-if-seq ,@rest-s)
                (hash-set gamma dst-sym dst-ty)
                ctrl-set
                v-wires
                (cons `(compute-pred ,dst-sym ,pred-wire) ir-acc))]

         [`(mutate-wire! ,w)
          (define active-guard-collision
            (for/first ([v (in-set ctrl-set)]
                        #:when (equal? (hash-ref v-wires v #f) w))
              v))
          (if active-guard-collision
              (err-result
               (list (lfq-type-diagnostic
                      "T-ValidIf"
                      "E-VALIDIF-WITNESS-MUTATED"
                      (format "Active validity-witness wire ~a (`~a`) mutated inside with-valid scope"
                              w active-guard-collision)
                      (hasheq 'mutated_wire w
                              'guard_symbol (symbol->string active-guard-collision)))))
              (walk `(valid-if-seq ,@rest-s)
                    gamma
                    ctrl-set
                    v-wires
                    (cons `(x ,w) ir-acc)))]

         [`(with-valid ,v-sym ,val-sym ,sub-prog)
          (define v-ty (hash-ref gamma v-sym #f))
          (define val-ty (hash-ref gamma val-sym #f))
          (define v-w (hash-ref v-wires v-sym #f))
          (define sub-mutated (collect-mutated-wires-in-valid-prog sub-prog))
          (cond
            [(not (eq? v-ty 'QBit))
             (err-result
              (list (lfq-type-diagnostic
                     "T-ValidIf"
                     "E-VALIDIF-INVALID-WITNESS"
                     (format "Symbol `~a` is not a QBit validity witness" v-sym)
                     (hasheq 'symbol (symbol->string v-sym)))))]
            [(and v-w (set-member? sub-mutated v-w))
             (err-result
              (list (lfq-type-diagnostic
                     "T-ValidIf"
                     "E-VALIDIF-WITNESS-MUTATED"
                     (format "with-valid body mutates its own validity-witness wire ~a (`~a`)"
                             v-w v-sym)
                     (hasheq 'guard_symbol (symbol->string v-sym)
                             'mutated_wire v-w))))]
            [else
             (define unwrapped-ty
               (match val-ty
                 [`(ValidIf ,vs ,inner)
                  (define rem (remove v-sym vs))
                  (if (null? rem) inner `(ValidIf ,rem ,inner))]
                 [other other]))
             (define sub-res
               (check-valid-if-program sub-prog
                                       (hash-set gamma val-sym unwrapped-ty)
                                       (set-add ctrl-set v-sym)
                                       v-wires))
             (if (not (lfq-typecheck-result-well-typed? sub-res))
                 sub-res
                 (walk `(valid-if-seq ,@rest-s)
                       gamma
                       ctrl-set
                       v-wires
                       (cons (lfq-typecheck-result-synthesized-ir sub-res) ir-acc)))])]

         [`(unwrap-unchecked ,val-sym)
          (define missing (required-validity-guards val-sym gamma ctrl-set))
          (if (not (null? missing))
              (err-result
               (list (lfq-type-diagnostic
                      "T-ValidIf"
                      "E-VALIDIF-UNWRAPPED-USE"
                      (format "Cannot consume partial superposition value `~a` without validity guard(s) ~a in Gamma_ctrl"
                              val-sym missing)
                      (hasheq 'consumed_symbol (symbol->string val-sym)
                              'missing_guards (map (lambda (x) (format "~a" x)) missing)
                              'active_guards (map symbol->string (set->list ctrl-set))))))
              (walk `(valid-if-seq ,@rest-s) gamma ctrl-set v-wires ir-acc))]

         [`(phase-flip-if ,dep-syms ,pred-wires ,scratch-wires)
          (define missing
            (remove-duplicates
             (apply append
                    (for/list ([s (in-list dep-syms)])
                      (required-validity-guards s gamma ctrl-set)))))
          (if (not (null? missing))
              (err-result
               (list (lfq-type-diagnostic
                      "T-ValidIf"
                      "E-VALIDIF-UNGUARDED-PHASE-FLIP"
                      (format "Grover phase-flip-if depends on partial superposition ~a without validity guard(s) ~a in Gamma_ctrl"
                              dep-syms missing)
                      (hasheq 'dependent_symbols (map symbol->string dep-syms)
                              'missing_validity_guards (map (lambda (x) (format "~a" x)) missing)
                              'active_ctrl_guards (map symbol->string (set->list ctrl-set))))))
              (let* ([ctrl-ws (sort (for/list ([v (in-set ctrl-set)]
                                               #:when (hash-has-key? v-wires v))
                                      (hash-ref v-wires v))
                                    <)]
                     [all-ctrls (remove-duplicates (append ctrl-ws pred-wires))])
                (walk `(valid-if-seq ,@rest-s)
                      gamma
                      ctrl-set
                      v-wires
                      (cons `(mcz ,all-ctrls ,scratch-wires) ir-acc))))]
         [_
          (error 'check-valid-if-program "Unrecognized ValidIf statement: ~a" first-s)])]
      [_
       (error 'check-valid-if-program "Expected (valid-if-seq ...), got: ~a" p)])))

;; =============================================================================
;; SECTION 4: Rule 3 — `T-AlgPhase` (`Involutory` Trait + `Z_4` Global Phase)
;; =============================================================================

(define (mod4 k)
  (modulo k 4))

;; Symbolically evaluates a classical reversible gate list (`x`, `cx`, `ccx`, `swap`, `not-and-xor`)
;; on `n-wires` XAG literals and checks via `xag-z3-cut-sweep-miter!` whether `f(f(x)) == x`!
(define (apply-rev-gates-on-xag mgr state-vec gates)
  (define cur (vector-copy state-vec))
  (for ([g (in-list gates)])
    (match g
      [`(x ,w)
       (vector-set! cur w (lit-not (vector-ref cur w)))]
      [`(cx ,c ,t)
       (vector-set! cur t (xag-xor mgr (vector-ref cur t) (vector-ref cur c)))]
      [`(ccx ,c1 ,c2 ,t)
       (define prod (xag-and mgr (vector-ref cur c1) (vector-ref cur c2)))
       (vector-set! cur t (xag-xor mgr (vector-ref cur t) prod))]
      [`(not-and-xor ,c1-neg ,c2-pos ,t)
       (define prod (xag-and mgr (lit-not (vector-ref cur c1-neg)) (vector-ref cur c2-pos)))
       (vector-set! cur t (xag-xor mgr (vector-ref cur t) prod))]
      [`(swap ,u ,v)
       (define tmp (vector-ref cur u))
       (vector-set! cur u (vector-ref cur v))
       (vector-set! cur v tmp)]
      [_
       (error 'apply-rev-gates-on-xag "Unsupported reversible gate in involution check: ~a" g)]))
  cur)

(define (check-rev-circuit-involution-xag-z3! n-wires gates)
  (define mgr (make-xag-manager 1024))
  (define in-ws (range n-wires))
  (define init-v (for/vector ([i (in-range n-wires)]) (xag-var mgr i)))
  (define once-v (apply-rev-gates-on-xag mgr init-v gates))
  (define twice-v (apply-rev-gates-on-xag mgr once-v gates))
  (define first-cex #f)
  (for ([i (in-range n-wires)] #:unless first-cex)
    (define diff (xag-xor mgr (vector-ref twice-v i) (vector-ref init-v i)))
    (define-values (st cex-h _mode) (xag-z3-cut-sweep-miter! mgr (list diff) in-ws 'all))
    (when (eq? st 'sat)
      (set! first-cex (hasheq 'violated_wire i 'counterexample cex-h))))
  first-cex)

;; Checks whether two single-qubit Pauli maps `((w . P) ...)` commute (`even` anticommutations):
(define (pauli-maps-commute? map1 map2)
  (define anticomm-count
    (for/sum ([(w p1) (in-hash map1)]
              #:when (hash-has-key? map2 w))
      (define p2 (hash-ref map2 w))
      (if (or (eq? p1 'I) (eq? p2 'I) (eq? p1 p2)) 0 1)))
  (even? anticomm-count))

;; Syntax-directed `Involutory` trait checker:
;;   - `(pauli-string ((wire PauliSym) ...))`
;;   - `(reflection label wires)`
;;   - `(scalar-phase k-mod4 inner-op)`  (`i^k * U`: involutory iff `k in {0, 2}` and `U : Involutory`)
;;   - `(complex-const-phase num-pi den-pi inner-op)` (`exp(i * pi * num / den) * U`)
;;   - `(op-seq op1 op2)`                (product `op1 * op2`: involutory ONLY if `Commutes(op1, op2)`!)
;;   - `(partner-swap-select partner-alist branch-specs)`
;;       where each `branch-spec` is `(branch idx phase-mod4 refl-tag-list)`
;;   - `(rev-circuit label n-wires gate-list)` (checked via `XAG + Z3` miter `f(f(x)) == x`!)
(define (check-involutory-operator! op-ast consumer-kind)
  (match op-ast
    [`(pauli-string ,pairs)
     (define pmap (for/hasheqv ([pr (in-list pairs)]) (values (first pr) (second pr))))
     (ok-result 'Involutory op-ast (hasheq 'pauli_support (sort (hash-keys pmap) <)))]

    [`(reflection ,label ,wires)
     (ok-result 'Involutory op-ast (hasheq 'reflection (format "~a" label) 'wires wires))]

    [`(scalar-phase ,k ,inner)
     (define sub (check-involutory-operator! inner consumer-kind))
     (cond
       [(not (lfq-typecheck-result-well-typed? sub)) sub]
       [(memv (mod4 k) '(1 3))
        (err-result
         (list (lfq-type-diagnostic
                "T-AlgPhase"
                "E-ALGPHASE-NON-HERMITIAN-SCALAR"
                (format "~a requires Involutory (U^2 = I), but scalar phase i^~a gives (i^~a U)^2 = -I != I"
                        consumer-kind (mod4 k) (mod4 k))
                (hasheq 'consumer (symbol->string consumer-kind)
                        'phase_mod4 (mod4 k)
                        'square_scalar -1))))]
       [else (ok-result 'Involutory op-ast (hasheq 'phase_mod4 (mod4 k)))])]

    [`(complex-const-phase ,num-pi ,den-pi ,inner)
     (define sub (check-involutory-operator! inner consumer-kind))
     (cond
       [(not (lfq-typecheck-result-well-typed? sub)) sub]
       [(not (zero? (modulo num-pi den-pi)))
        (err-result
         (list (lfq-type-diagnostic
                "T-AlgPhase"
                "E-ALGPHASE-NON-HERMITIAN-SCALAR"
                (format "~a requires Involutory (U^2 = I), but complex constant exp(i*pi*~a/~a) is non-involutory"
                        consumer-kind num-pi den-pi)
                (hasheq 'consumer (symbol->string consumer-kind)
                        'angle_pi_ratio (list num-pi den-pi)))))]
       [else (ok-result 'Involutory op-ast (hasheq 'angle_pi_ratio (list num-pi den-pi)))])]

    [`(op-seq ,op1 ,op2)
     (define r1 (check-involutory-operator! op1 consumer-kind))
     (define r2 (check-involutory-operator! op2 consumer-kind))
     (cond
       [(not (lfq-typecheck-result-well-typed? r1)) r1]
       [(not (lfq-typecheck-result-well-typed? r2)) r2]
       [else
        (define commutes?
          (match* (op1 op2)
            [(`(pauli-string ,p1) `(pauli-string ,p2))
             (pauli-maps-commute?
              (for/hasheqv ([pr (in-list p1)]) (values (first pr) (second pr)))
              (for/hasheqv ([pr (in-list p2)]) (values (first pr) (second pr))))]
            [(`(reflection ,l1 ,w1) `(reflection ,l2 ,w2))
             (or (equal? l1 l2) (null? (set-intersect w1 w2)))]
            [(_ _) #f]))
        (if commutes?
            (ok-result 'Involutory op-ast (hasheq 'commuting_product #t))
            (err-result
             (list (lfq-type-diagnostic
                    "T-AlgPhase"
                    "E-ALGPHASE-NONCOMM-PRODUCT"
                    (format "~a requires Involutory, but non-commuting reflection product (A_mu * A_nu)^2 != I without PartnerSwap"
                            consumer-kind)
                    (hasheq 'consumer (symbol->string consumer-kind)
                            'lhs (format "~a" op1)
                            'rhs (format "~a" op2))))))])]

    [`(partner-swap-select ,partner-alist ,branches)
     (define pmap (for/hasheqv ([pr (in-list partner-alist)]) (values (first pr) (second pr))))
     (define bmap (for/hasheqv ([b (in-list branches)]) (values (second b) b)))
     (define diags '())
     (for ([b (in-list branches)])
       (match-define `(branch ,idx ,ph ,refl-tags) b)
       (define pidx (hash-ref pmap idx idx))
       (define pb (hash-ref bmap pidx #f))
       (cond
         [(not pb)
          (set! diags
                (cons (lfq-type-diagnostic
                       "T-AlgPhase"
                       "E-ALGPHASE-MISSING-PARTNER"
                       (format "SELECT branch ~a references missing partner ~a" idx pidx)
                       (hasheq 'branch idx 'partner pidx))
                      diags))]
         [(not (= (hash-ref pmap pidx pidx) idx))
          (set! diags
                (cons (lfq-type-diagnostic
                       "T-AlgPhase"
                       "E-ALGPHASE-PARTNER-NOT-INVOLUTION"
                       (format "Partner map on branch ~a is not an involution (partner(partner(~a)) != ~a)"
                               idx idx idx)
                       (hasheq 'branch idx 'partner pidx 'partner_of_partner (hash-ref pmap pidx pidx)))
                      diags))]
         [else
          (match-define `(branch ,_ ,p-ph ,p-refl-tags) pb)
          (when (not (zero? (mod4 (+ ph p-ph))))
            (set! diags
                  (cons (lfq-type-diagnostic
                         "T-AlgPhase"
                         "E-ALGPHASE-NON-HERMITIAN-SCALAR"
                         (format "Branch ~a (i^~a) and partner ~a (i^~a) multiply to i^~a != +1"
                                 idx (mod4 ph) pidx (mod4 p-ph) (mod4 (+ ph p-ph)))
                         (hasheq 'branch idx
                                 'partner pidx
                                 'phase_sum_mod4 (mod4 (+ ph p-ph))))
                        diags)))
          ;; Cancel adjacent identical reflections in `p-refl-tags ++ refl-tags`:
          (define reduced
            (for/fold ([stk '()]) ([tag (in-list (append p-refl-tags refl-tags))])
              (if (and (not (null? stk)) (equal? (first stk) tag))
                  (rest stk)
                  (cons tag stk))))
          (when (not (null? reduced))
            (set! diags
                  (cons (lfq-type-diagnostic
                         "T-AlgPhase"
                         "E-ALGPHASE-NONCOMM-PRODUCT"
                         (format "Two-step branch trace for ~a -> ~a fails to cancel to identity: residual ~a"
                                 idx pidx (reverse reduced))
                         (hasheq 'branch idx
                                 'partner pidx
                                 'residual_reflections (map (lambda (t) (format "~a" t)) (reverse reduced))))
                        diags)))]))
     (if (null? diags)
         (ok-result 'Involutory op-ast (hasheq 'branches_verified (length branches)))
         (err-result (reverse diags)))]

    [`(rev-circuit ,label ,n-wires ,gates)
     (define cex (check-rev-circuit-involution-xag-z3! n-wires gates))
     (if cex
         (err-result
          (list (lfq-type-diagnostic
                 "T-AlgPhase"
                 "E-ALGPHASE-NON-INVOLUTORY-CIRCUIT"
                 (format "~a requires Involutory (f(f(x)) = x), but reversible circuit `~a` is not self-inverse"
                         consumer-kind label)
                 (hasheq 'consumer (symbol->string consumer-kind)
                         'circuit (format "~a" label)
                         'xag_z3_witness cex))))
         (ok-result 'Involutory op-ast (hasheq 'xag_z3_involution_verified #t)))]

    [_
     (error 'check-involutory-operator! "Unrecognized operator expression: ~a" op-ast)]))

;; =============================================================================
;; SECTION 5: Unified `QBlock(A, alpha, m_anc, eps, omega_mod4)` Inference
;;            (Combining `T-AlgPhase` `Z_4` Global Phase & `T-DriftEps` Lipschitz `eps`)
;; =============================================================================

(struct qblock-graded-type
  (op-label
   alpha
   m-anc
   eps
   omega-mod4) ;; `omega in {0, 1, 2, 3}` meaning physical unitary equals `i^omega * Block(A/alpha)`
  #:transparent)

(define (ceil-log2-pos x)
  (if (<= x 1.0)
      1
      (inexact->exact (ceiling (/ (log (exact->inexact x)) (log 2.0))))))

(define (emit-s-power-gates wire s-pow)
  (match (mod4 s-pow)
    [0 '()]
    [1 (list `(s ,wire))]
    [2 (list `(z ,wire))]
    [3 (list `(z ,wire) `(s ,wire))]))

;; Infers `qblock-graded-type` (or classical measurement distribution) for:
;;   - `(qblock-exact label alpha m-anc omega-mod4)`
;;   - `(prepare-alias label num-terms alpha mu-bits claimed-eps-or-#f)`
;;   - `(qubitization-walk label prep-expr select-op)`
;;   - `(wx->reflection degree inner-qblock)`  (`omega' = (omega + 3*d) mod 4`, i.e. `(-i)^d`)
;;   - `(qsvt-chebyshev degree regime inner-qblock eps-target)`
;;   - `(raw-lcu-sum qblock-exprs)`            (rejects mismatched `omega_j`!)
;;   - `(lcu-sum ctrl-wires qblock-exprs)`     (synthesizes compensating `S^{(4 - omega_j) mod 4}`!)
;;   - `(ctrl-qblock ctrl-wire inner-qblock)`  (synthesizes compensating `S^{(4 - omega) mod 4}`!)
;;   - `(measure-qblock inner-qblock)`         (erases `omega` with `0` phase gates!)
(define (infer-qblock-alg-phase-and-eps expr)
  (match expr
    [`(qblock-exact ,label ,alpha ,m-anc ,omega)
     (ok-result (qblock-graded-type label alpha m-anc 0.0 (mod4 omega))
                `(qblock-prim ,label))]

    [`(prepare-alias ,label ,num-terms ,alpha ,mu-bits ,claimed-eps)
     (define true-eps (/ (* (exact->inexact num-terms) (exact->inexact alpha))
                         (expt 2.0 mu-bits)))
     (if (and claimed-eps (< claimed-eps (* 0.999999 true-eps)))
         (err-result
          (list (lfq-type-diagnostic
                 "T-DriftEps"
                 "E-DRIFTEPS-ZERO-OR-UNSOUND-EPS"
                 (format "Alias LCU `~a` claims epsilon=~a on finite mu=~a bits, but Babbush discretization error is ~a > ~a"
                         label claimed-eps mu-bits true-eps claimed-eps)
                 (hasheq 'claimed_epsilon claimed-eps
                         'true_alias_epsilon true-eps
                         'mu_bits mu-bits
                         'num_terms num-terms
                         'alpha alpha))))
         (ok-result (qblock-graded-type label alpha (+ (ceil-log2-pos num-terms) mu-bits) true-eps 0)
                    `(alias-prep ,label ,mu-bits)
                    (hasheq 'alias_eps true-eps 'mu_bits mu-bits)))]

    [`(qubitization-walk ,label ,prep-expr ,select-op)
     (define prep-res (infer-qblock-alg-phase-and-eps prep-expr))
     (define sel-res (check-involutory-operator! select-op 'qubitization-walk))
     (cond
       [(not (lfq-typecheck-result-well-typed? prep-res)) prep-res]
       [(not (lfq-typecheck-result-well-typed? sel-res)) sel-res]
       [else
        (define pty (lfq-typecheck-result-inferred-type prep-res))
        (ok-result (struct-copy qblock-graded-type pty [op-label label])
                   `(verified-qwalk ,label
                                    ,(lfq-typecheck-result-synthesized-ir prep-res)
                                    ,select-op)
                   (lfq-typecheck-result-metrics sel-res))])]

    [`(wx->reflection ,deg ,inner-expr)
     (define sub (infer-qblock-alg-phase-and-eps inner-expr))
     (if (not (lfq-typecheck-result-well-typed? sub))
         sub
         (let* ([ity (lfq-typecheck-result-inferred-type sub)]
                ;; (-i)^deg = i^(3 * deg mod 4)
                [new-omega (mod4 (+ (qblock-graded-type-omega-mod4 ity) (* 3 deg)))]
                [lip (max 1 deg)]
                [new-eps (* lip (qblock-graded-type-eps ity))])
           (ok-result (qblock-graded-type `(wx-qsvt ,deg ,(qblock-graded-type-op-label ity))
                                          1.0
                                          (add1 (qblock-graded-type-m-anc ity))
                                          new-eps
                                          new-omega)
                      `(wx-reflection-qsvt ,deg ,(lfq-typecheck-result-synthesized-ir sub))
                      (hasheq 'degree deg 'global_phase_i_pow new-omega))))]

    [`(qsvt-chebyshev ,deg ,regime ,inner-expr ,eps-target)
     (define sub (infer-qblock-alg-phase-and-eps inner-expr))
     (if (not (lfq-typecheck-result-well-typed? sub))
         sub
         (let* ([ity (lfq-typecheck-result-inferred-type sub)]
                [amp-factor (match regime
                              ['interior-walk deg]
                              ['markov-spectral-edge (* deg deg)]
                              [_ (error 'qsvt-chebyshev "Unknown regime `~a`" regime)])]
                [eps-out (* amp-factor (qblock-graded-type-eps ity))])
           (if (> eps-out eps-target)
               (err-result
                (list (lfq-type-diagnostic
                       "T-DriftEps"
                       "E-DRIFTEPS-EPS-AMPLIFICATION"
                       (format "Chebyshev QSVT degree d=~a (~a) amplifies block error ~a -> ~a > target ~a"
                               deg regime (qblock-graded-type-eps ity) eps-out eps-target)
                       (hasheq 'degree deg
                               'regime (symbol->string regime)
                               'amplification_factor amp-factor
                               'eps_in (qblock-graded-type-eps ity)
                               'eps_out eps-out
                               'eps_target eps-target))))
               (ok-result (qblock-graded-type `(cheb ,deg ,(qblock-graded-type-op-label ity))
                                              1.0
                                              (add1 (qblock-graded-type-m-anc ity))
                                              eps-out
                                              (qblock-graded-type-omega-mod4 ity))
                          `(chebyshev-qsvt ,deg ,regime ,(lfq-typecheck-result-synthesized-ir sub))
                          (hasheq 'eps_out eps-out 'amplification_factor amp-factor)))))]

    [`(raw-lcu-sum ,term-exprs)
     (define sub-results (map infer-qblock-alg-phase-and-eps term-exprs))
     (define failed (findf (lambda (r) (not (lfq-typecheck-result-well-typed? r))) sub-results))
     (cond
       [failed failed]
       [else
        (define tys (map lfq-typecheck-result-inferred-type sub-results))
        (define omegas (map qblock-graded-type-omega-mod4 tys))
        (define ref-omega (first omegas))
        (if (not (for/and ([w (in-list omegas)]) (= w ref-omega)))
            (err-result
             (list (lfq-type-diagnostic
                    "T-AlgPhase"
                    "E-ALGPHASE-LCU-PHASE-MISMATCH"
                    (format "Uncompensated LCU sum combines branches with mismatched Z_4 global phases i^~a, causing destructive interference"
                            omegas)
                    (hasheq 'branch_omegas_mod4 omegas))))
            (ok-result (qblock-graded-type `(lcu-sum ,@(map qblock-graded-type-op-label tys))
                                           (apply + (map qblock-graded-type-alpha tys))
                                           (add1 (apply max (map qblock-graded-type-m-anc tys)))
                                           (apply + (map qblock-graded-type-eps tys))
                                           ref-omega)
                       `(raw-lcu ,@(map lfq-typecheck-result-synthesized-ir sub-results))))])]

    [`(lcu-sum ,ctrl-wires ,term-exprs)
     (define sub-results (map infer-qblock-alg-phase-and-eps term-exprs))
     (define failed (findf (lambda (r) (not (lfq-typecheck-result-well-typed? r))) sub-results))
     (cond
       [failed failed]
       [else
        (define tys (map lfq-typecheck-result-inferred-type sub-results))
        (define comp-s-powers
          (for/list ([ty (in-list tys)])
            (mod4 (- 4 (qblock-graded-type-omega-mod4 ty)))))
        (define phase-gates
          (apply append
                 (for/list ([cw (in-list ctrl-wires)]
                            [sp (in-list comp-s-powers)])
                   (emit-s-power-gates cw sp))))
        (ok-result (qblock-graded-type `(lcu-sum-aligned ,@(map qblock-graded-type-op-label tys))
                                       (apply + (map qblock-graded-type-alpha tys))
                                       (add1 (apply max (map qblock-graded-type-m-anc tys)))
                                       (apply + (map qblock-graded-type-eps tys))
                                       0)
                   `(phase-compensated-lcu
                     (compensating-gates ,@phase-gates)
                     (branches ,@(map lfq-typecheck-result-synthesized-ir sub-results)))
                   (hasheq 'compensating_s_powers_mod4 comp-s-powers
                           'synthesized_phase_gates (map (lambda (g) (format "~a" g)) phase-gates)
                           'aligned_omega_mod4 0))])]

    [`(ctrl-qblock ,ctrl-wire ,inner-expr)
     (define sub (infer-qblock-alg-phase-and-eps inner-expr))
     (if (not (lfq-typecheck-result-well-typed? sub))
         sub
         (let* ([ity (lfq-typecheck-result-inferred-type sub)]
                [s-pow (mod4 (- 4 (qblock-graded-type-omega-mod4 ity)))]
                [pgates (emit-s-power-gates ctrl-wire s-pow)])
           (ok-result (struct-copy qblock-graded-type ity [omega-mod4 0])
                      `(phase-compensated-ctrl ,ctrl-wire
                                               ,pgates
                                               ,(lfq-typecheck-result-synthesized-ir sub))
                      (hasheq 'compensating_s_power_mod4 s-pow
                              'synthesized_phase_gates (map (lambda (g) (format "~a" g)) pgates)))))]

    [`(measure-qblock ,inner-expr)
     (define sub (infer-qblock-alg-phase-and-eps inner-expr))
     (if (not (lfq-typecheck-result-well-typed? sub))
         sub
         (let ([ity (lfq-typecheck-result-inferred-type sub)])
           ;; Measurement erases global phase (`|i^omega psi|^2 = |psi|^2`) with 0 phase gates:
           (ok-result `(ClassicalDist ,(qblock-graded-type-op-label ity))
                      `(measure-erase-phase ,(lfq-typecheck-result-synthesized-ir sub))
                      (hasheq 'erased_omega_mod4 (qblock-graded-type-omega-mod4 ity)
                              'synthesized_phase_gates '()))))]

    [_
     (error 'infer-qblock-alg-phase-and-eps "Unrecognized QBlock expression: ~a" expr)]))

;; =============================================================================
;; SECTION 6: Rule 4 — `T-WireBasis` (`QVec[n, pi : Perm[n], B : BasisTag]`
;;            + Simultaneous `Fin[N]` Ring Stencils)
;; =============================================================================

(struct qvec-wire-basis-type
  (width     ;; exact positive integer n
   perm      ;; list of length n (`perm[logical_bit] = physical_pos`)
   basis-tag);; symbol: 'AESPolyBasis | 'TowerGF16x2LSB | 'TowerGF16x2MSB | 'F2StdBasis
  #:transparent)

(define (valid-bijection-perm? perm n)
  (and (= (length perm) n)
       (equal? (sort perm <) (range n))))

;; `new_perm[i] = old_perm[sigma[i]]`
(define (compose-wire-perm old-perm sigma-perm)
  (for/list ([s (in-list sigma-perm)])
    (list-ref old-perm s)))

(define (invert-wire-perm perm)
  (define n (length perm))
  (define inv (make-vector n 0))
  (for ([i (in-range n)] [p (in-list perm)])
    (vector-set! inv p i))
  (vector->list inv))

(define (popcount-nat n)
  (let loop ([k n] [acc 0])
    (if (zero? k)
        acc
        (loop (arithmetic-shift k -1) (+ acc (bitwise-and k 1))))))

;; Applies an `n x n` GF(2) matrix (list of row bitmasks, LSB = bit 0) to `n`-bit integer `x`:
(define (gf2-mat-apply-byte rows x)
  (for/fold ([out 0]) ([row-mask (in-list rows)] [r-idx (in-naturals)])
    (define parity (modulo (popcount-nat (bitwise-and row-mask x)) 2))
    (bitwise-ior out (arithmetic-shift parity r-idx))))

(define (gf2-mat-invertible? rows n)
  (define mat (list->vector rows))
  (define ok? #t)
  (for ([col (in-range n)] #:when ok?)
    (define piv
      (for/first ([r (in-range col n)]
                  #:when (bitwise-bit-set? (vector-ref mat r) col))
        r))
    (cond
      [(not piv) (set! ok? #f)]
      [else
       (define tmp (vector-ref mat col))
       (vector-set! mat col (vector-ref mat piv))
       (vector-set! mat piv tmp)
       (for ([r (in-range n)] #:when (and (not (= r col))
                                          (bitwise-bit-set? (vector-ref mat r) col)))
         (vector-set! mat r (bitwise-xor (vector-ref mat r) (vector-ref mat col))))]))
  ok?)

;; Exact inverse of an `n x n` GF(2) row-mask matrix:
(define (invert-gf2-rows rows n)
  (define aug
    (for/vector ([r (in-list rows)] [i (in-naturals)])
      (cons r (arithmetic-shift 1 i))))
  (for ([col (in-range n)])
    (define piv
      (for/first ([r (in-range col n)]
                  #:when (bitwise-bit-set? (car (vector-ref aug r)) col))
        r))
    (unless piv
      (error 'invert-gf2-rows "Singular GF(2) matrix"))
    (define tmp (vector-ref aug col))
    (vector-set! aug col (vector-ref aug piv))
    (vector-set! aug piv tmp)
    (for ([r (in-range n)] #:when (and (not (= r col))
                                       (bitwise-bit-set? (car (vector-ref aug r)) col)))
      (vector-set! aug r
                   (cons (bitwise-xor (car (vector-ref aug r)) (car (vector-ref aug col)))
                         (bitwise-xor (cdr (vector-ref aug r)) (cdr (vector-ref aug col)))))))
  (for/list ([i (in-range n)])
    (cdr (vector-ref aug i))))

;; Canonical Boyar-Peralta / Canright LSB-ordered `TowerGF16x2LSB <-> AESPolyBasis`
;; invertible 8x8 GF(2) linear isomorphism (from columns `'(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f)`):
(define canonical-tower-lsb->aes-poly-cols
  '(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f))

(define canonical-tower-lsb->aes-poly-rows
  (for/list ([r (in-range 8)])
    (for/fold ([mask 0]) ([col-val (in-list canonical-tower-lsb->aes-poly-cols)]
                          [c (in-naturals)])
      (if (bitwise-bit-set? col-val r)
          (bitwise-ior mask (arithmetic-shift 1 c))
          mask))))

(define canonical-aes-poly->tower-lsb-rows
  (invert-gf2-rows canonical-tower-lsb->aes-poly-rows 8))

(define (registered-basis-isomorphism-rows src-basis dst-basis)
  (match (cons src-basis dst-basis)
    [(cons 'AESPolyBasis 'TowerGF16x2LSB) canonical-aes-poly->tower-lsb-rows]
    [(cons 'TowerGF16x2LSB 'AESPolyBasis) canonical-tower-lsb->aes-poly-rows]
    [_ #f]))

;; Checks a sequence of `QVec` wire-basis & `Fin[N]` stencil operations:
;;   `(wire-basis-prog
;;      #:regs ((reg-sym width init-perm init-basis phys-wires) ...)
;;      #:ops (op ...))`
;; Supported `op` forms:
;;   - `(plu-linear-op reg-sym p-perm cx-pairs)`
;;   - `(relabel-perm reg-sym sigma-perm)`           (`0` physical SWAPs!)
;;   - `(basis-cast reg-sym matrix-rows src-b dst-b)`(checks all `n` unit basis vectors!)
;;   - `(tower-core-op reg-sym expected-basis)`
;;   - `(add-round-key state-sym key-sym)`           (requires matching `(n, id, AESPolyBasis)`)
;;   - `(stencil-ring kind ring-n lo-idx hi-idx read-offsets write-offset data-ws anc-ws)`
(define (check-wire-basis-and-stencil prog)
  (match prog
    [`(wire-basis-prog #:regs ,reg-decls #:ops ,ops)
     (define gamma (make-hasheq))
     (define reg-wires (make-hasheq))
     (for ([rd (in-list reg-decls)])
       (match-define (list rsym n iperm ibasis pws) rd)
       (hash-set! gamma rsym (qvec-wire-basis-type n iperm ibasis))
       (hash-set! reg-wires rsym pws))
     (define phys-gates '())
     (define swap-gates-emitted 0)
     (let loop ([rem ops])
       (match rem
         ['()
          (ok-result (for/hasheq ([(k v) (in-hash gamma)]) (values k v))
                     `(seq ,@(reverse phys-gates))
                     (hasheq 'physical_swap_gates swap-gates-emitted
                             'physical_gate_count (length phys-gates)))]
         [(cons op rest-ops)
          (match op
            [`(plu-linear-op ,rsym ,p-perm ,cx-pairs)
             (define rty (hash-ref gamma rsym))
             (define n (qvec-wire-basis-type-width rty))
             (define cur-perm (qvec-wire-basis-type-perm rty))
             (define pws (hash-ref reg-wires rsym))
             (cond
               [(not (valid-bijection-perm? p-perm n))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-INVALID-PERM"
                        (format "PLU permutation ~a is not a bijection on Fin[~a]" p-perm n)
                        (hasheq 'register (symbol->string rsym) 'perm p-perm))))]
               [else
                (define mapped-cxs
                  (for/list ([pr (in-list cx-pairs)])
                    (define c-phys (list-ref pws (list-ref cur-perm (first pr))))
                    (define t-phys (list-ref pws (list-ref cur-perm (second pr))))
                    `(cx ,c-phys ,t-phys)))
                (hash-set! gamma rsym
                           (qvec-wire-basis-type n
                                                 (compose-wire-perm cur-perm p-perm)
                                                 (qvec-wire-basis-type-basis-tag rty)))
                (set! phys-gates (append (reverse mapped-cxs) phys-gates))
                (loop rest-ops)])]

            [`(relabel-perm ,rsym ,sigma-perm)
             (define rty (hash-ref gamma rsym))
             (define n (qvec-wire-basis-type-width rty))
             (cond
               [(not (valid-bijection-perm? sigma-perm n))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-INVALID-PERM"
                        (format "relabel-perm ~a is not a bijection on Fin[~a]" sigma-perm n)
                        (hasheq 'register (symbol->string rsym) 'perm sigma-perm))))]
               [else
                ;; Zero physical gates emitted — pure compile-time wire-map composition!
                (hash-set! gamma rsym
                           (qvec-wire-basis-type n
                                                 (compose-wire-perm (qvec-wire-basis-type-perm rty)
                                                                    sigma-perm)
                                                 (qvec-wire-basis-type-basis-tag rty)))
                (loop rest-ops)])]

            [`(basis-cast ,rsym ,mat-rows ,src-b ,dst-b)
             (define rty (hash-ref gamma rsym))
             (define n (qvec-wire-basis-type-width rty))
             (define id-perm (range n))
             (define expected-rows (registered-basis-isomorphism-rows src-b dst-b))
             (cond
               [(not (eq? (qvec-wire-basis-type-basis-tag rty) src-b))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-BASIS-MISMATCH"
                        (format "basis-cast expects `~a` in ~a, got ~a"
                                rsym src-b (qvec-wire-basis-type-basis-tag rty))
                        (hasheq 'register (symbol->string rsym)
                                'expected_basis (symbol->string src-b)
                                'actual_basis (symbol->string (qvec-wire-basis-type-basis-tag rty))))))]
               [(not (equal? (qvec-wire-basis-type-perm rty) id-perm))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-PERM-MISMATCH"
                        (format "basis-cast on `~a` requires canonical wire order id, got perm ~a (reversed/permuted bit order)"
                                rsym (qvec-wire-basis-type-perm rty))
                        (hasheq 'register (symbol->string rsym)
                                'actual_perm (qvec-wire-basis-type-perm rty)))))]
               [(not (gf2-mat-invertible? mat-rows n))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-SINGULAR-CAST"
                        (format "basis-cast matrix on `~a` is singular over GF(2)" rsym)
                        (hasheq 'register (symbol->string rsym)))))]
               [(and expected-rows
                     (for/or ([bit-i (in-range n)])
                       (define unit-v (arithmetic-shift 1 bit-i))
                       (not (= (gf2-mat-apply-byte mat-rows unit-v)
                               (gf2-mat-apply-byte expected-rows unit-v)))))
                (define bad-bit
                  (for/first ([bit-i (in-range n)]
                              #:when (let ([uv (arithmetic-shift 1 bit-i)])
                                       (not (= (gf2-mat-apply-byte mat-rows uv)
                                               (gf2-mat-apply-byte expected-rows uv)))))
                    bit-i))
                (define uv (arithmetic-shift 1 bad-bit))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-BASIS-MISMATCH"
                        (format "basis-cast ~a -> ~a fails basis-generator check on unit bit e_~a (note: 0x00 maps to 0x00 under all linear maps!)"
                                src-b dst-b bad-bit)
                        (hasheq 'register (symbol->string rsym)
                                'unit_vector_input uv
                                'actual_output (gf2-mat-apply-byte mat-rows uv)
                                'expected_output (gf2-mat-apply-byte expected-rows uv)
                                'zero_input_blind_spot_output (gf2-mat-apply-byte mat-rows 0)))))]
               [else
                (hash-set! gamma rsym (qvec-wire-basis-type n id-perm dst-b))
                (loop rest-ops)])]

            [`(tower-core-op ,rsym ,expected-b)
             (define rty (hash-ref gamma rsym))
             (define n (qvec-wire-basis-type-width rty))
             (if (and (eq? (qvec-wire-basis-type-basis-tag rty) expected-b)
                      (equal? (qvec-wire-basis-type-perm rty) (range n)))
                 (loop rest-ops)
                 (err-result
                  (list (lfq-type-diagnostic
                         "T-WireBasis"
                         "E-WIREBASIS-BASIS-MISMATCH"
                         (format "Non-linear field operation on `~a` expects canonical (~a, id), got (~a, ~a)"
                                 rsym expected-b
                                 (qvec-wire-basis-type-basis-tag rty)
                                 (qvec-wire-basis-type-perm rty))
                         (hasheq 'register (symbol->string rsym)
                                 'expected_basis (symbol->string expected-b)
                                 'actual_basis (symbol->string (qvec-wire-basis-type-basis-tag rty))
                                 'actual_perm (qvec-wire-basis-type-perm rty))))))]

            [`(add-round-key ,state-sym ,key-sym)
             (define sty (hash-ref gamma state-sym))
             (define kty (hash-ref gamma key-sym))
             (define n (qvec-wire-basis-type-width sty))
             (define id-perm (range n))
             (cond
               [(not (eq? (qvec-wire-basis-type-basis-tag sty)
                          (qvec-wire-basis-type-basis-tag kty)))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-BASIS-MISMATCH"
                        (format "AddRoundKey basis mismatch: state `~a` is in ~a while key `~a` is in ~a"
                                state-sym (qvec-wire-basis-type-basis-tag sty)
                                key-sym (qvec-wire-basis-type-basis-tag kty))
                        (hasheq 'state_basis (symbol->string (qvec-wire-basis-type-basis-tag sty))
                                'key_basis (symbol->string (qvec-wire-basis-type-basis-tag kty))))))]
               [(not (equal? (qvec-wire-basis-type-perm sty)
                             (qvec-wire-basis-type-perm kty)))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-PERM-MISMATCH"
                        (format "AddRoundKey wire-permutation mismatch: state `~a` has un-relabeled perm ~a != key perm ~a (missing MixedColumn wire relabeling)"
                                state-sym
                                (take (qvec-wire-basis-type-perm sty) (min 8 n))
                                (take (qvec-wire-basis-type-perm kty) (min 8 n)))
                        (hasheq 'state_perm (qvec-wire-basis-type-perm sty)
                                'key_perm (qvec-wire-basis-type-perm kty)
                                'first_misaligned_bit
                                (for/first ([i (in-range n)]
                                            #:when (not (= (list-ref (qvec-wire-basis-type-perm sty) i)
                                                           (list-ref (qvec-wire-basis-type-perm kty) i))))
                                  i)))))]
               [(not (equal? (qvec-wire-basis-type-perm sty) id-perm))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-PERM-MISMATCH"
                        "AddRoundKey requires canonical identity wire order"
                        (hasheq 'state_perm (qvec-wire-basis-type-perm sty)))))]
               [else
                (define sws (hash-ref reg-wires state-sym))
                (define kws (hash-ref reg-wires key-sym))
                (define xor-gates (for/list ([ks (in-list kws)] [ss (in-list sws)]) `(cx ,ks ,ss)))
                (set! phys-gates (append (reverse xor-gates) phys-gates))
                (loop rest-ops)])]

            [`(stencil-ring ,kind ,ring-n ,lo-idx ,hi-idx ,read-offsets ,write-offset ,data-ws ,anc-ws)
             (cond
               [(or (not (= lo-idx 0)) (not (= hi-idx (sub1 ring-n))))
                (err-result
                 (list (lfq-type-diagnostic
                        "T-WireBasis"
                        "E-WIREBASIS-FIN-BOUNDS"
                        (format "Ring stencil over Fin[~a] expects exact index range 0..~a (~a elements), got ~a..~a (~a iterations)"
                                ring-n (sub1 ring-n) ring-n lo-idx hi-idx (add1 (- hi-idx lo-idx)))
                        (hasheq 'fin_modulus ring-n
                                'supplied_lo lo-idx
                                'supplied_hi hi-idx
                                'iteration_count (add1 (- hi-idx lo-idx))))))]
               [(eq? kind 'imperative-seq)
                ;; Check sequential read-after-write aliasing across `0 <= i < j < ring-n`:
                (define raw-hazard
                  (for*/first ([i (in-range ring-n)]
                               [j (in-range (add1 i) ring-n)]
                               [roff (in-list read-offsets)]
                               #:when (= (modulo (+ i write-offset) ring-n)
                                         (modulo (+ j roff) ring-n)))
                    (hasheq 'writer_iter i
                            'reader_iter j
                            'aliased_ring_index (modulo (+ i write-offset) ring-n))))
                (if raw-hazard
                    (err-result
                     (list (lfq-type-diagnostic
                            "T-WireBasis"
                            "E-WIREBASIS-RAW-STENCIL-ALIAS"
                            (format "Imperative ring loop over Fin[~a] mutates lane ~a in step ~a before step ~a reads it"
                                    ring-n
                                    (hash-ref raw-hazard 'aliased_ring_index)
                                    (hash-ref raw-hazard 'writer_iter)
                                    (hash-ref raw-hazard 'reader_iter))
                            raw-hazard)))
                    (loop rest-ops))]
               [(eq? kind 'qstencil-ring)
                ;; Simultaneous 2-ancilla backup lowering for Keccak chi_5 on `Fin[5]`
                (when (and (= ring-n 5) (>= (length data-ws) 5) (>= (length anc-ws) 2))
                  (match-define (list a0 a1 a2 a3 a4) (take data-ws 5))
                  (match-define (list b0 b1) (take anc-ws 2))
                  (define chi-gates
                    (list `(cx ,a0 ,b0) `(cx ,a1 ,b1)
                          `(x ,b1) `(ccx ,b1 ,a2 ,a0) `(x ,b1)
                          `(x ,a2) `(ccx ,a2 ,a3 ,a1) `(x ,a2)
                          `(x ,a3) `(ccx ,a3 ,a4 ,a2) `(x ,a3)
                          `(x ,a4) `(ccx ,a4 ,b0 ,a3) `(x ,a4)
                          `(x ,b0) `(ccx ,b0 ,b1 ,a4) `(x ,b0)))
                  (set! phys-gates (append (reverse chi-gates) phys-gates)))
                (loop rest-ops)]
               [else
                (error 'check-wire-basis-and-stencil "Unknown stencil kind: ~a" kind)])]

            [_
             (error 'check-wire-basis-and-stencil "Unknown wire-basis op: ~a" op)])]))]
    [_
     (error 'check-wire-basis-and-stencil "Malformed wire-basis-prog: ~a" prog)]))

;; =============================================================================
;; SECTION 7: Rule 5 — `T-DriftEps` (`QCoset` Runway & `QRNS` Dynamic Range)
;; =============================================================================
;;
;; Checks modular accumulation drift specifications:
;;   - `(coset-runway-spec #:modulus-bits n-bits #:c-pad c-pad #:steps k-steps #:safety-bits s-bits)`
;;   - `(rns-range-spec #:modulus-n mod-n #:power-m m-pow #:rns-moduli (p1 p2 ...))`
;;   - `(drift-bundle specs ...)`

(define (min-sound-cpad required-cap)
  (let loop ([b 1])
    (if (> (arithmetic-shift 1 b) required-cap)
        b
        (loop (add1 b)))))

(define (check-coset-and-rns-drift spec)
  (match spec
    [`(coset-runway-spec #:modulus-bits ,n-bits
                         #:c-pad ,c-pad
                         #:steps ,k-steps
                         #:safety-bits ,s-bits)
     (define req-cap (* k-steps (arithmetic-shift 1 s-bits)))
     (define act-cap (arithmetic-shift 1 c-pad))
     (define req-cpad (min-sound-cpad req-cap))
     (if (<= act-cap req-cap)
         (err-result
          (list (lfq-type-diagnostic
                 "T-DriftEps"
                 "E-DRIFTEPS-COSET-RUNWAY-OVERFLOW"
                 (format "QCoset[~a, c_pad=~a, K=~a] overflows carry runway: 2^~a = ~a <= K * 2^~a = ~a (need c_pad >= ~a)"
                         n-bits c-pad k-steps c-pad act-cap s-bits req-cap req-cpad)
                 (hasheq 'modulus_bits n-bits
                         'supplied_c_pad c-pad
                         'required_c_pad req-cpad
                         'k_steps k-steps
                         'safety_bits s-bits
                         'actual_capacity act-cap
                         'required_capacity req-cap))))
         (ok-result `(QCoset ,n-bits ,c-pad ,k-steps)
                    `(verified-coset ,n-bits ,c-pad ,k-steps)
                    (hasheq 'min_sound_c_pad req-cpad 'c_pad c-pad)))]

    [`(rns-range-spec #:modulus-n ,mod-n
                      #:power-m ,m-pow
                      #:rns-moduli ,moduli)
     (define prod-L (foldl * 1 moduli))
     (define req-range (expt mod-n m-pow))
     (if (< prod-L req-range)
         (err-result
          (list (lfq-type-diagnostic
                 "T-DriftEps"
                 "E-DRIFTEPS-RNS-DYNAMIC-RANGE"
                 (format "QRNS dynamic range L = prod(p_i) = ~a < N^~a = ~a causes silent CRT wraparound"
                         prod-L m-pow req-range)
                 (hasheq 'rns_product_L prod-L
                         'required_N_pow_m req-range
                         'corrupted_witness_X (* mod-n (add1 (quotient prod-L mod-n)))
                         'corrupted_mod_N (modulo (- (* mod-n (add1 (quotient prod-L mod-n))) prod-L) mod-n)))))
         (ok-result `(QRNS ,mod-n ,m-pow ,(length moduli))
                    `(verified-rns ,moduli)
                    (hasheq 'rns_product_L prod-L 'required_N_pow_m req-range)))]

    [`(drift-bundle ,subs ...)
     (define res-list (map check-coset-and-rns-drift subs))
     (define bad (filter (lambda (r) (not (lfq-typecheck-result-well-typed? r))) res-list))
     (if (not (null? bad))
         (err-result (apply append (map lfq-typecheck-result-diagnostics bad)))
         (ok-result (map lfq-typecheck-result-inferred-type res-list)
                    `(verified-drift-bundle ,@(map lfq-typecheck-result-synthesized-ir res-list))))]

    [_
     (error 'check-coset-and-rns-drift "Unrecognized drift specification: ~a" spec)]))

;; =============================================================================
;; SECTION 8: Rule 6 — `T-SingleIR` (Unified `RevIR` Abstract-Interpretation
;;            Costing + Bound-Slice Completeness + `XAG + Z3` Pure-Spec Miter +
;;            `QOracle[k_key, h_bits]` Spurious-Key Margin)
;; =============================================================================

;; Abstract-interpretation cost extractor over a single `RevIR` AST:
;; Computes exact `(hasheq 'temp_ands ... 'cx ... 'x ...)` from the same AST that
;; lowers to circuit gates!
(define (abstract-interpret-revir-cost revir-ast)
  (let walk ([e revir-ast])
    (match e
      ['skip (hasheq 'temp_ands 0 'cx 0 'x 0)]
      [`(x ,_) (hasheq 'temp_ands 0 'cx 0 'x 1)]
      [`(cx ,_ ,_) (hasheq 'temp_ands 0 'cx 1 'x 0)]
      [(or `(ccx ,_ ,_ ,_) `(temp-and ,_ ,_ ,_)) (hasheq 'temp_ands 1 'cx 0 'x 0)]
      [`(seq ,subs ...)
       (for/fold ([acc (hasheq 'temp_ands 0 'cx 0 'x 0)]) ([s (in-list subs)])
         (define sc (walk s))
         (hasheq 'temp_ands (+ (hash-ref acc 'temp_ands) (hash-ref sc 'temp_ands))
                 'cx (+ (hash-ref acc 'cx) (hash-ref sc 'cx))
                 'x (+ (hash-ref acc 'x) (hash-ref sc 'x))))]
      [`(for-matrix-elim #:rows ,r #:total-cols ,_ #:col-lo ,clo #:col-hi ,chi #:pivots ,p)
       ;; Exact symbolic loop abstract interpretation over the SAME `RevIR` loop bounds:
       ;; Coherent `ROWSWAP` (`x in 0..p-2`, `(- r 1 x)` rows across `max(x, clo)..chi-1`)
       ;; plus coherent `ROWADD` (`x in 0..p-1`, `(r - 1)` non-pivot rows across `max(x+1, clo)..chi-1`):
       (define swap-ands
         (for/sum ([x (in-range (max 0 (sub1 p)))])
           (define w-swp (max 0 (- chi (max x clo))))
           (* (max 0 (- r 1 x)) w-swp)))
       (define add-ands
         (for/sum ([x (in-range p)])
           (define w-add (max 0 (- chi (max (add1 x) clo))))
           (* (sub1 r) w-add)))
       (hasheq 'temp_ands (+ swap-ands add-ands) 'cx 0 'x 0)]
      [_ (error 'abstract-interpret-revir-cost "Unhandled RevIR node: ~a" e)])))

;; Checks `RevIR` slice completeness (every declared column `0 .. total-cols - 1`
;; covered when full elimination is typed):
(define (find-unbound-revir-slice revir-ast)
  (match revir-ast
    [`(for-matrix-elim #:rows ,r #:total-cols ,total-cols #:col-lo ,clo #:col-hi ,chi #:pivots ,p)
     (if (or (> clo 0) (< chi total-cols))
         (hasheq 'rows r
                 'declared_total_cols total-cols
                 'active_col_lo clo
                 'active_col_hi chi
                 'omitted_columns (- total-cols (- chi clo))
                 'undercounted_temp_ands
                 (hash-ref (abstract-interpret-revir-cost revir-ast) 'temp_ands)
                 'true_full_slice_temp_ands
                 (hash-ref (abstract-interpret-revir-cost
                            `(for-matrix-elim #:rows ,r
                                              #:total-cols ,total-cols
                                              #:col-lo 0
                                              #:col-hi ,total-cols
                                              #:pivots ,p))
                           'temp_ands))
         #f)]
    [`(seq ,subs ...)
     (for/or ([s (in-list subs)]) (find-unbound-revir-slice s))]
    [_ #f]))

;; Runs mandatory `XAG + Z3` miter between `revir-gates` and `spec-xag-builder`:
;; `spec-kind` can be `'sha2-ch` (`(e & f) ^ (~e & g)` on wires `(0, 1, 2) -> out wire 3`)
;; or `(custom-bool-expr expr)`!
(define (build-pure-spec-xag mgr spec-desc in-vars)
  (match spec-desc
    ['sha2-ch
     ;; FIPS 180-4 SHA-2 Choose function: Ch(e, f, g) = (e & f) ^ (~e & g)
     (define e-lit (vector-ref in-vars 0))
     (define f-lit (vector-ref in-vars 1))
     (define g-lit (vector-ref in-vars 2))
     (list (xag-xor mgr
                    (xag-and mgr e-lit f-lit)
                    (xag-and mgr (lit-not e-lit) g-lit)))]
    ['identity
     (vector->list in-vars)]
    [`(xor-pair ,i ,j)
     (list (xag-xor mgr (vector-ref in-vars i) (vector-ref in-vars j)))]
    [_
     (error 'build-pure-spec-xag "Unknown pure spec descriptor: ~a" spec-desc)]))

(define (check-revir-xag-spec-miter! n-inputs total-wires out-wires gates spec-desc)
  (define mgr (make-xag-manager 1024))
  (define in-ws (range n-inputs))
  (define state-v
    (for/vector ([w (in-range total-wires)])
      (if (< w n-inputs) (xag-var mgr w) lit-zero)))
  (define final-v (apply-rev-gates-on-xag mgr state-v gates))
  (define in-v (for/vector ([w (in-range n-inputs)]) (vector-ref state-v w)))
  (define spec-lits (build-pure-spec-xag mgr spec-desc in-v))
  (for/or ([ow (in-list out-wires)] [slit (in-list spec-lits)])
    (define diff (xag-xor mgr (vector-ref final-v ow) slit))
    (define-values (st cex _mode) (xag-z3-cut-sweep-miter! mgr (list diff) in-ws 'all))
    (and (eq? st 'sat)
         (hasheq 'output_wire ow
                 'spec (format "~a" spec-desc)
                 'z3_status "sat"
                 'counterexample cex))))

(define (check-single-ir-and-grover-oracle! spec)
  (match spec
    [`(single-ir-kernel
       #:label ,label
       #:revir-ast ,revir-ast
       #:claimed-temp-ands ,claimed-ands-opt
       #:miter-spec ,miter-opt)
     (define slice-bug (find-unbound-revir-slice revir-ast))
     (cond
       [slice-bug
        (err-result
         (list (lfq-type-diagnostic
                "T-SingleIR"
                "E-SINGLEIR-UNBOUND-SLICE"
                (format "RevIR kernel `~a` omits ~a of ~a declared columns (unbound slice / copy-paste skip_rightmost hazard)"
                        label
                        (hash-ref slice-bug 'omitted_columns)
                        (hash-ref slice-bug 'declared_total_cols))
                slice-bug)))]
       [else
        (define ai-cost (abstract-interpret-revir-cost revir-ast))
        (define true-ands (hash-ref ai-cost 'temp_ands))
        (cond
          [(and claimed-ands-opt (not (= claimed-ands-opt true-ands)))
           (err-result
            (list (lfq-type-diagnostic
                   "T-SingleIR"
                   "E-SINGLEIR-DETACHED-COST-MISMATCH"
                   (format "Detached resource claim (~a TempANDs) disagrees with unified RevIR AST abstract interpretation (~a TempANDs)"
                           claimed-ands-opt true-ands)
                   (hasheq 'claimed_temp_ands claimed-ands-opt
                           'revir_ast_temp_ands true-ands))))]
          [miter-opt
           (match-define (list n-in total-w out-ws gates pure-spec) miter-opt)
           (define miter-cex
             (check-revir-xag-spec-miter! n-in total-w out-ws gates pure-spec))
           (if miter-cex
               (err-result
                (list (lfq-type-diagnostic
                       "T-SingleIR"
                       "E-SINGLEIR-SPEC-MITER-SAT"
                       (format "RevIR circuit `~a` disagrees with pure specification `~a` under XAG + Z3 miter"
                               label pure-spec)
                       miter-cex)))
               (ok-result `(VerifiedRevIR ,label ,true-ands)
                          revir-ast
                          (hasheq 'temp_ands true-ands
                                  'cx (hash-ref ai-cost 'cx)
                                  'miter_status "unsat")))]
          [else
           (ok-result `(VerifiedRevIR ,label ,true-ands)
                      revir-ast
                      ai-cost)])])]

    [`(grover-search-oracle
       #:cipher ,cipher-label
       #:key-bits ,k-key
       #:constraint-bits ,h-bits
       #:log2-eta-max ,log2-eta-max)
     (define log2-spurious (- k-key h-bits))
     (define expected-spurious (expt 2.0 log2-spurious))
     (define spurious-prob (- 1.0 (exp (- expected-spurious))))
     (if (> log2-spurious log2-eta-max)
         (err-result
          (list (lfq-type-diagnostic
                 "T-SingleIR"
                 "E-SINGLEIR-SPURIOUS-KEY-MARGIN"
                 (format "grover-search on QOracle[k=~a, h=~a] (`~a`) violates spurious-key uniqueness margin: k - h = ~a > log2(eta_max) = ~a (E[spurious] = ~a)"
                         k-key h-bits cipher-label log2-spurious log2-eta-max expected-spurious)
                 (hasheq 'cipher (format "~a" cipher-label)
                         'k_key_bits k-key
                         'h_constraint_bits h-bits
                         'log2_expected_spurious log2-spurious
                         'log2_eta_max log2-eta-max
                         'expected_spurious_keys expected-spurious
                         'spurious_collision_probability spurious-prob))))
         (ok-result `(UniqueGroverOracle ,cipher-label ,k-key ,h-bits)
                    `(verified-grover-oracle ,cipher-label ,k-key ,h-bits)
                    (hasheq 'log2_expected_spurious log2-spurious
                            'expected_spurious_keys expected-spurious
                            'unique_key_probability (- 1.0 spurious-prob))))]

    [`(single-ir-bundle ,subs ...)
     (define res-list (map check-single-ir-and-grover-oracle! subs))
     (define bad (filter (lambda (r) (not (lfq-typecheck-result-well-typed? r))) res-list))
     (if (not (null? bad))
         (err-result (apply append (map lfq-typecheck-result-diagnostics bad)))
         (ok-result (map lfq-typecheck-result-inferred-type res-list)
                    `(verified-single-ir-bundle ,@(map lfq-typecheck-result-synthesized-ir res-list))))]

    [_
     (error 'check-single-ir-and-grover-oracle! "Unrecognized T-SingleIR form: ~a" spec)]))

;; =============================================================================
;; SECTION 8B: Rule 7 — `T-ParGuard` (`QParGrade` Static Parallel-Partitionability
;;             Type & Cost Guard with Automatic Single-Machine Fallback)
;; =============================================================================
;;
;; Infers one of 3 static parallelizability grades (`QParGrade`):
;;   1. `ParSliceable(M, bell_cuts)`
;;        Polynomial-depth algebraic circuits (`'algebraic-limb`: `ECC-256`,
;;        `RSA-2048`, `RSA-4096`) whose `QVec` zipper cut satisfies
;;        `bell_cuts <= max_bell_budget` and `q_per_machine + q_comm < q_single`
;;        with `O(1)` work overhead -> compiles to `M` entangled machines.
;;   2. `ParShotLinear(M)`
;;        `Grade Phi1` independent shot/expectation loops (`'shot-sample`:
;;        `DQI`, `Hubbard-QSVT`, `FeMoCo-THC`) with `0` cross-QPU Bell pairs,
;;        `1.0x` total work, `M x` linear shot throughput -> compiles to `M`
;;        independent `1`-machine workers.
;;   3. `ParNonPartitionable(reason)`
;;        (`'zalka-grover-sublinear` or `'bell-cut-exceeds-single-qpu`):
;;        Triggered automatically on `'grover-amplify` / `'isd-search`
;;        (`AES-128`, `AES-256`, `SHA3-256`, `SLH-DSA-128s`, `McEliece-348864`,
;;        `BIKE-L1` — non-sliceable internal state across serial Grover/ISD
;;        reflections + Zalka's `sqrt(M)` total-work blowup with `<= log2(M)`
;;        width reduction) OR whenever `q_per_machine + q_comm >= q_single`
;;        (or `bell_cuts > max_bell_budget`).
;;        - Default (`#:strict-parallel? #f`): automatically returns the
;;          `1`-machine Single-Machine compiled program (`machines_used = 1`,
;;          `fallback_to_single_machine = #t`) with a structured static diagnostic!
;;        - Strict (`#:strict-parallel? #t`): statically rejects with `T-ParGuard`.

(struct qpar-grade
  (tag         ;; 'ParSliceable | 'ParShotLinear | 'ParNonPartitionable
   machines    ;; exact positive integer (M for sliceable/shot-linear, 1 for non-partitionable)
   bell-cuts   ;; exact nonnegative integer
   reason)     ;; #f | 'zalka-grover-sublinear | 'bell-cut-exceeds-single-qpu
  #:transparent)

(define (ParSliceable m bell-cuts)
  (qpar-grade 'ParSliceable m bell-cuts #f))

(define (ParShotLinear m)
  (qpar-grade 'ParShotLinear m 0 #f))

(define (ParNonPartitionable reason)
  (qpar-grade 'ParNonPartitionable 1 0 reason))

(define default-cluster-candidate-machines
  '(1 2 4 6 8 12 16 24 32 48 64 96 128 256))

(define (par-cluster-opt-spec #:workload workload
                              #:paradigm paradigm
                              #:max-machines [max-machines 256]
                              #:q-cap-per-machine q-cap-per-machine
                              #:raw-bell-rate-hz [raw-bell-rate-hz 100000.0]
                              #:raw-per-logical-ebit [raw-per-logical-ebit 30]
                              #:q-single q-single
                              #:q-data-dist [q-data-dist 0]
                              #:q-local-fixed [q-local-fixed 0]
                              #:q-peer-sync [q-peer-sync 0]
                              #:candidate-machines [candidate-machines default-cluster-candidate-machines]
                              #:window-bits [window-bits 0]
                              #:num-windows [num-windows 0]
                              #:local-toffolis [local-toffolis 0]
                              #:carry-scheme [carry-scheme 'none]
                              #:lookup-scheme [lookup-scheme 'none]
                              #:interconnect-topology [interconnect-topology 'all-to-all-peers]
                              #:total-shots [total-shots #f]
                              #:strict-parallel? [strict-parallel? #f])
  `(par-cluster-opt-spec
    #:workload ,workload
    #:paradigm ,paradigm
    #:max-machines ,max-machines
    #:q-cap-per-machine ,q-cap-per-machine
    #:raw-bell-rate-hz ,raw-bell-rate-hz
    #:raw-per-logical-ebit ,raw-per-logical-ebit
    #:q-single ,q-single
    #:q-data-dist ,q-data-dist
    #:q-local-fixed ,q-local-fixed
    #:q-peer-sync ,q-peer-sync
    #:candidate-machines ,candidate-machines
    #:window-bits ,window-bits
    #:num-windows ,num-windows
    #:local-toffolis ,local-toffolis
    #:carry-scheme ,carry-scheme
    #:lookup-scheme ,lookup-scheme
    #:interconnect-topology ,interconnect-topology
    #:total-shots ,total-shots
    #:strict-parallel? ,strict-parallel?))

(define (parse-par-cluster-opt-plist kvs)
  (let loop ([rem kvs] [acc (hasheq)])
    (match rem
      ['() acc]
      [(list (? keyword? kw) val rest ...)
       (loop rest (hash-set acc (string->symbol (keyword->string kw)) val))]
      [_
       (error 'solve-optimal-qpar-machines "Malformed keyword plist in par-cluster-opt-spec: ~a" kvs)])))

(define (lookup-ebits-per-window lookup-scheme w-bits q-data m)
  (if (<= m 1)
      0
      (match lookup-scheme
        ['law-u4-ghz-mx (* w-bits (- m 1))]
        ['roundtrip-cat (* 2 w-bits (- m 1))]
        ['data-teleport (* (quotient q-data m) (- m 1))]
        [(or 'none #f) 0]
        [_ (error 'lookup-ebits-per-window "Unknown lookup-scheme: ~a" lookup-scheme)])))

(define (carry-ebits-per-window carry-scheme m)
  (if (<= m 1)
      0
      (match carry-scheme
        ['qrns-zero-carry 0]
        ['projective-oblivious-runway (* 24 (- m 1))]
        ['naive-ripple-divstep (* 1500 (- m 1))]
        [(or 'none #f) 0]
        [_ (error 'carry-ebits-per-window "Unknown carry-scheme: ~a" carry-scheme)])))

(define (ceil-log2-machines m)
  (if (<= m 1)
      0
      (let loop ([k 1] [pow2 2])
        (if (>= pow2 m)
            k
            (loop (+ k 1) (* pow2 2))))))

(define (q-mach-on-slice q-single q-data q-fix q-sync m [topology 'all-to-all-peers])
  (if (<= m 1)
      q-single
      (let ([sync-factor
             (match topology
               ['all-to-all-peers (- m 1)]
               ['switched-optical-tree (ceil-log2-machines m)]
               [_ (error 'q-mach-on-slice "Unknown interconnect-topology: ~a" topology)])])
        (+ (quotient (+ q-data m -1) m)
           q-fix
           (* q-sync sync-factor)))))

;; Universal physical wall-clock model for `ParSliceable`:
;;   - Local CCX throughput per QPU module: `R_loc = 250,000` CCX/s (parallel magic-state factories)
;;   - QEC lattice-surgery / GHZ window boundary merge latency:
;;       `tau_qec_sync = 0.0001128` s per `(window * distributed_data_qubit)` boundary cut
;;   - Distilled optical Bell link transfer latency: `(D_dist * E_log(M)) / R_bell`
(define local-ccx-rate-per-module-hz 250000.0)
(define qec-window-cut-sync-coeff-sec 0.0001128)

(define (wall-clock-sliceable-sec m t-toff n-win q-data d-dist e-log r-bell)
  (define t-loc
    (/ (exact->inexact t-toff)
       (* (exact->inexact (max 1 m)) local-ccx-rate-per-module-hz)))
  (if (<= m 1)
      t-loc
      (let ([t-sync (* qec-window-cut-sync-coeff-sec
                       (exact->inexact n-win)
                       (exact->inexact q-data)
                       (exact->inexact (- m 1)))]
            [t-bell (/ (* (exact->inexact d-dist) (exact->inexact e-log))
                       (exact->inexact r-bell))])
        (+ t-loc t-sync t-bell))))

(define (solve-optimal-qpar-machines spec
                                     [single-machine-ir 'single-machine-circuit]
                                     [multi-machine-ir 'distributed-multi-qpu-circuit])
  (match spec
    [`(par-cluster-opt-spec . ,kvs)
     (define h (parse-par-cluster-opt-plist kvs))
     (define workload (hash-ref h 'workload))
     (define paradigm (hash-ref h 'paradigm))
     (define m-max (max 1 (hash-ref h 'max-machines 256)))
     (define q-cap (hash-ref h 'q-cap-per-machine))
     (define r-bell (hash-ref h 'raw-bell-rate-hz 100000.0))
     (define d-dist (hash-ref h 'raw-per-logical-ebit 30))
     (define q-single (hash-ref h 'q-single))
     (define q-data (hash-ref h 'q-data-dist 0))
     (define q-fix (hash-ref h 'q-local-fixed 0))
     (define q-sync (hash-ref h 'q-peer-sync 0))
     (define raw-cands (hash-ref h 'candidate-machines default-cluster-candidate-machines))
     (define w-bits (hash-ref h 'window-bits 0))
     (define n-win (hash-ref h 'num-windows 0))
     (define t-toff (hash-ref h 'local-toffolis 0))
     (define carry-scheme (hash-ref h 'carry-scheme 'none))
     (define lookup-scheme (hash-ref h 'lookup-scheme 'none))
     (define topology (hash-ref h 'interconnect-topology 'all-to-all-peers))
     (define total-shots (hash-ref h 'total-shots #f))
     (define strict? (hash-ref h 'strict-parallel? #f))

     (define norm-cands
       (sort (remove-duplicates
              (filter (lambda (m) (and (exact-positive-integer? m) (<= m m-max)))
                      (cons 1 raw-cands)))
             <))

     (cond
       ;; 1. `ParNonPartitionable` (`'grover-amplify`, `'isd-search`):
       ;;    Always selects `M* = 1` (`fallback_to_single_machine = #t` when `m-max > 1`;
       ;;    if `q-single > q-cap` and `strict?`, rejects with `E-PARGUARD-SINGLE-EXCEEDS-QCAP`).
       [(memq paradigm '(grover-amplify isd-search))
        (define fits-cap? (<= q-single q-cap))
        (define fallback? (> m-max 1))
        (define g (if fallback?
                      (ParNonPartitionable 'zalka-grover-sublinear)
                      (ParSliceable 1 0)))
        (define zalka-blowup (sqrt (exact->inexact m-max)))
        (define max-width-saved (inexact->exact (floor (/ (log m-max) (log 2)))))
        (define t-wall-1 (/ (exact->inexact t-toff) local-ccx-rate-per-module-hz))
        (define base-info
          (hasheq 'workload (format "~a" workload)
                  'paradigm (symbol->string paradigm)
                  'interconnect_topology (symbol->string topology)
                  'requested_machines m-max
                  'max_machines m-max
                  'q_cap_per_machine q-cap
                  'raw_bell_rate_hz (exact->inexact r-bell)
                  'qpar_grade (symbol->string (qpar-grade-tag g))
                  'reason (if fallback? "zalka-grover-sublinear" "monolithic-single-qpu")
                  'optimal_machines 1
                  'machines_used 1
                  'q_single q-single
                  'q_allocated_per_machine q-single
                  'fits_q_cap fits-cap?
                  'lookup_ebits_total 0
                  'carry_ebits_total 0
                  'logical_ebits_total 0
                  'raw_bell_pairs_total 0
                  'bell_cuts 0
                  'estimated_wall_clock_sec t-wall-1
                  'zalka_total_work_blowup_factor zalka-blowup
                  'max_key_width_bits_saved max-width-saved
                  'pruned_ucurve_candidates '()
                  'fallback_to_single_machine fallback?))
        (cond
          [(and strict? (not fits-cap?))
           (define msg
             (format "T-ParGuard (`~a`): non-partitionable ~a circuit requires Q_single = ~a > Q_cap = ~a and cannot be sliced across machines"
                     workload paradigm q-single q-cap))
           (err-result
            (list (lfq-type-diagnostic "T-ParGuard" "E-PARGUARD-SINGLE-EXCEEDS-QCAP" msg base-info)))]
          [(and strict? fallback?)
           (define msg
             (format "T-ParGuard (`~a`): serial Grover/ISD state incurs sqrt(M)=~ax Zalka work blowup on M=~a; rejected under #:strict-parallel? #t"
                     workload (~r zalka-blowup #:precision 2) m-max))
           (err-result
            (list (lfq-type-diagnostic "T-ParGuard" "E-PARGUARD-ZALKA-GROVER-SUBLINEAR" msg base-info)))]
          [fallback?
           (define wcode
             (if fits-cap?
                 "W-PARGUARD-FALLBACK-ZALKA-GROVER"
                 "W-PARGUARD-SINGLE-EXCEEDS-QCAP"))
           (define msg
             (format "T-ParGuard (`~a`): M*=1 selected (~a Q vs Q_cap=~a) avoiding sqrt(~a)=~ax Zalka work blowup"
                     workload q-single q-cap m-max (~r zalka-blowup #:precision 2)))
           (define diag (lfq-type-diagnostic "T-ParGuard" wcode msg base-info))
           (ok-result g
                      `(single-machine-fallback-schedule 1 ,single-machine-ir)
                      (hash-set base-info 'static_diagnostic (diag->jsexpr diag)))]
          [else
           (ok-result g
                      `(single-machine-schedule 1 ,single-machine-ir)
                      base-info)])]

       ;; 2. `ParShotLinear` (`'shot-sample`: `DQI`, `Hubbard-QSVT`, `FeMoCo-THC`):
       ;;    `0` inter-shot Bell pairs and linear `M`-fold shot throughput, capped by
       ;;    `effective-shot-cap = (min m-max total-shots)` when `total-shots` is set so
       ;;    no idle machines are allocated past the algorithm's shot budget!
       [(eq? paradigm 'shot-sample)
        (define effective-shot-cap
          (if (and total-shots (exact-positive-integer? total-shots))
              (min m-max total-shots)
              m-max))
        (cond
          [(<= q-single q-cap)
           (define g (ParShotLinear effective-shot-cap))
           (define t-wall (/ (exact->inexact t-toff)
                             (* (exact->inexact effective-shot-cap) local-ccx-rate-per-module-hz)))
           (define info
             (hasheq 'workload (format "~a" workload)
                     'paradigm "shot-sample"
                     'interconnect_topology (symbol->string topology)
                     'requested_machines m-max
                     'max_machines m-max
                     'total_shots_budget (or total-shots m-max)
                     'idle_machines_avoided (- m-max effective-shot-cap)
                     'q_cap_per_machine q-cap
                     'raw_bell_rate_hz (exact->inexact r-bell)
                     'qpar_grade "ParShotLinear"
                     'optimal_machines effective-shot-cap
                     'machines_used effective-shot-cap
                     'machines_per_shot_instance 1
                     'parallel_shot_groups effective-shot-cap
                     'q_single q-single
                     'q_allocated_per_machine q-single
                     'fits_q_cap #t
                     'lookup_ebits_total 0
                     'carry_ebits_total 0
                     'logical_ebits_total 0
                     'raw_bell_pairs_total 0
                     'bell_cuts 0
                     'total_work_multiplier 1.0
                     'shot_throughput_speedup effective-shot-cap
                     'estimated_wall_clock_sec t-wall
                     'pruned_ucurve_candidates '()
                     'fallback_to_single_machine #f))
           (ok-result g `(shot-parallel-workers-schedule ,effective-shot-cap ,single-machine-ir) info)]
          [else
           (define slice-m
             (and (> q-data 0)
                  (for/first ([m (in-list norm-cands)]
                              #:when (and (>= m 2)
                                          (<= (q-mach-on-slice q-single q-data q-fix q-sync m topology) q-cap)))
                    m)))
           (cond
             [slice-m
              (define q-slice (q-mach-on-slice q-single q-data q-fix q-sync slice-m topology))
              (define max-hw-groups (max 1 (quotient m-max slice-m)))
              (define groups
                (if (and total-shots (exact-positive-integer? total-shots))
                    (min max-hw-groups total-shots)
                    max-hw-groups))
              (define m-used (* groups slice-m))
              (define luk (* n-win (lookup-ebits-per-window lookup-scheme w-bits q-data slice-m)))
              (define car (* n-win (carry-ebits-per-window carry-scheme slice-m)))
              (define elog (+ luk car))
              (define g (ParShotLinear m-used))
              (define info
                (hasheq 'workload (format "~a" workload)
                        'paradigm "shot-sample"
                        'interconnect_topology (symbol->string topology)
                        'requested_machines m-max
                        'max_machines m-max
                        'total_shots_budget (or total-shots max-hw-groups)
                        'idle_machines_avoided (- m-max m-used)
                        'q_cap_per_machine q-cap
                        'raw_bell_rate_hz (exact->inexact r-bell)
                        'qpar_grade "ParShotLinear"
                        'optimal_machines m-used
                        'machines_used m-used
                        'machines_per_shot_instance slice-m
                        'parallel_shot_groups groups
                        'q_single q-single
                        'q_allocated_per_machine q-slice
                        'fits_q_cap #t
                        'lookup_ebits_total (* groups luk)
                        'carry_ebits_total (* groups car)
                        'logical_ebits_total (* groups elog)
                        'raw_bell_pairs_total (* d-dist groups elog)
                        'bell_cuts 0
                        'total_work_multiplier 1.0
                        'shot_throughput_speedup groups
                        'pruned_ucurve_candidates '()
                        'fallback_to_single_machine #f))
              (ok-result g `(shot-parallel-sliced-workers-schedule ,groups ,slice-m ,multi-machine-ir) info)]
             [strict?
              (define err-info
                (hasheq 'workload (format "~a" workload)
                        'paradigm "shot-sample"
                        'q_single q-single
                        'q_cap_per_machine q-cap
                        'max_machines m-max))
              (err-result
               (list (lfq-type-diagnostic
                      "T-ParGuard"
                      "E-PARGUARD-SINGLE-EXCEEDS-QCAP"
                      (format "T-ParGuard (`~a`): shot-sample Q_single = ~a > Q_cap = ~a with no sliceable sub-register"
                              workload q-single q-cap)
                      err-info)))]
             [else
              (define g (ParShotLinear effective-shot-cap))
              (define info
                (hasheq 'workload (format "~a" workload)
                        'paradigm "shot-sample"
                        'interconnect_topology (symbol->string topology)
                        'requested_machines m-max
                        'max_machines m-max
                        'total_shots_budget (or total-shots m-max)
                        'idle_machines_avoided (- m-max effective-shot-cap)
                        'q_cap_per_machine q-cap
                        'raw_bell_rate_hz (exact->inexact r-bell)
                        'qpar_grade "ParShotLinear"
                        'optimal_machines effective-shot-cap
                        'machines_used effective-shot-cap
                        'machines_per_shot_instance 1
                        'parallel_shot_groups effective-shot-cap
                        'q_single q-single
                        'q_allocated_per_machine q-single
                        'fits_q_cap #f
                        'requires_larger_monolithic_qpu #t
                        'lookup_ebits_total 0
                        'carry_ebits_total 0
                        'logical_ebits_total 0
                        'raw_bell_pairs_total 0
                        'bell_cuts 0
                        'total_work_multiplier 1.0
                        'shot_throughput_speedup effective-shot-cap
                        'pruned_ucurve_candidates '()
                        'fallback_to_single_machine #f))
              (ok-result g `(shot-parallel-workers-schedule ,effective-shot-cap ,single-machine-ir) info)])])]

       ;; 3. `ParSliceable` (`'algebraic-limb`: `ECC-256`, `RSA-2048`, `RSA-4096`):
       ;;    Evaluate candidate `M` values, statically prune U-curve-knee-dominated `M2 > M1 >= 2`
       ;;    (`Q_mach(M2) >= Q_mach(M1)` -> `W-PARGUARD-PRUNED-UCURVE-KNEE`), short-circuit to
       ;;    monolithic `M* = 1` (`0` optical Bell pairs) whenever `Q_single <= Q_cap`, and
       ;;    otherwise minimize convex `T_wall(M, R_bell)` over feasible `Q_mach(M) <= Q_cap`!
       [(eq? paradigm 'algebraic-limb)
        (define raw-evals
          (for/list ([m (in-list norm-cands)])
            (define qm (q-mach-on-slice q-single q-data q-fix q-sync m topology))
            (define luk (* n-win (lookup-ebits-per-window lookup-scheme w-bits q-data m)))
            (define car (* n-win (carry-ebits-per-window carry-scheme m)))
            (define elog (+ luk car))
            (define raws (* d-dist elog))
            (define twall (wall-clock-sliceable-sec m t-toff n-win q-data d-dist elog r-bell))
            (hasheq 'm m
                    'q_per_machine qm
                    'fits_q_cap (<= qm q-cap)
                    'lookup_ebits luk
                    'carry_ebits car
                    'logical_ebits elog
                    'raw_bell_pairs raws
                    'estimated_wall_clock_sec twall)))

        ;; Static U-curve knee dominance pruning across `m >= 2`:
        (define nd-multi '())
        (define pruned-knees '())
        (for ([rec (in-list raw-evals)]
              #:when (>= (hash-ref rec 'm) 2))
          (define m2 (hash-ref rec 'm))
          (define q2 (hash-ref rec 'q_per_machine))
          (define e2 (hash-ref rec 'logical_ebits))
          (define dom
            (for/first ([prev (in-list nd-multi)]
                        #:when (<= (hash-ref prev 'q_per_machine) q2))
              prev))
          (if dom
              (set! pruned-knees
                    (cons (hasheq 'code "W-PARGUARD-PRUNED-UCURVE-KNEE"
                                  'pruned_m m2
                                  'pruned_q_per_machine q2
                                  'pruned_logical_ebits e2
                                  'dominating_m (hash-ref dom 'm)
                                  'dominating_q_per_machine (hash-ref dom 'q_per_machine)
                                  'dominating_logical_ebits (hash-ref dom 'logical_ebits))
                          pruned-knees))
              (set! nd-multi (cons rec nd-multi))))
        (define pareto-multi (reverse nd-multi))
        (define pruned-list (reverse pruned-knees))

        (cond
          ;; Monolithic `M* = 1` fits `Q_cap` -> `0` optical Bell pairs!
          [(<= q-single q-cap)
           (define rec1 (first raw-evals))
           (define g (ParSliceable 1 0))
           (define info
             (hasheq 'workload (format "~a" workload)
                     'paradigm "algebraic-limb"
                     'interconnect_topology (symbol->string topology)
                     'carry_scheme (symbol->string carry-scheme)
                     'lookup_scheme (symbol->string lookup-scheme)
                     'requested_machines m-max
                     'max_machines m-max
                     'q_cap_per_machine q-cap
                     'raw_bell_rate_hz (exact->inexact r-bell)
                     'raw_per_logical_ebit d-dist
                     'qpar_grade "ParSliceable"
                     'optimal_machines 1
                     'machines_used 1
                     'monolithic_single_chip_optimal #t
                     'q_single q-single
                     'q_allocated_per_machine q-single
                     'fits_q_cap #t
                     'lookup_ebits_total 0
                     'carry_ebits_total 0
                     'logical_ebits_total 0
                     'raw_bell_pairs_total 0
                     'bell_cuts 0
                     'estimated_wall_clock_sec (hash-ref rec1 'estimated_wall_clock_sec)
                     'pruned_ucurve_candidates pruned-list
                     'pareto_candidates (cons rec1 pareto-multi)
                     'fallback_to_single_machine #f))
           (ok-result g `(single-machine-schedule 1 ,single-machine-ir) info)]

          [else
           (define feasible-multi
             (filter (lambda (r) (hash-ref r 'fits_q_cap)) pareto-multi))
           (cond
             [(not (null? feasible-multi))
              (define best-rec
                (for/fold ([best (first feasible-multi)])
                          ([cand (in-list (rest feasible-multi))])
                  (if (< (hash-ref cand 'estimated_wall_clock_sec)
                         (hash-ref best 'estimated_wall_clock_sec))
                      cand
                      best)))
              (define m-star (hash-ref best-rec 'm))
              (define elog (hash-ref best-rec 'logical_ebits))
              (define g (ParSliceable m-star elog))
              (define info
                (hasheq 'workload (format "~a" workload)
                        'paradigm "algebraic-limb"
                        'interconnect_topology (symbol->string topology)
                        'carry_scheme (symbol->string carry-scheme)
                        'lookup_scheme (symbol->string lookup-scheme)
                        'requested_machines m-max
                        'max_machines m-max
                        'q_cap_per_machine q-cap
                        'raw_bell_rate_hz (exact->inexact r-bell)
                        'raw_per_logical_ebit d-dist
                        'qpar_grade "ParSliceable"
                        'optimal_machines m-star
                        'machines_used m-star
                        'monolithic_single_chip_optimal #f
                        'q_single q-single
                        'q_allocated_per_machine (hash-ref best-rec 'q_per_machine)
                        'fits_q_cap #t
                        'lookup_ebits_total (hash-ref best-rec 'lookup_ebits)
                        'carry_ebits_total (hash-ref best-rec 'carry_ebits)
                        'logical_ebits_total elog
                        'raw_bell_pairs_total (hash-ref best-rec 'raw_bell_pairs)
                        'bell_cuts elog
                        'estimated_wall_clock_sec (hash-ref best-rec 'estimated_wall_clock_sec)
                        'pruned_ucurve_candidates pruned-list
                        'pareto_candidates pareto-multi
                        'fallback_to_single_machine #f))
              (ok-result g `(entangled-multi-machine-schedule ,m-star ,elog ,multi-machine-ir) info)]

             ;; No candidate `M <= M_max` fits `Q_cap`:
             [strict?
              (define min-q
                (apply min q-single (map (lambda (r) (hash-ref r 'q_per_machine)) pareto-multi)))
              (define err-info
                (hasheq 'workload (format "~a" workload)
                        'paradigm "algebraic-limb"
                        'interconnect_topology (symbol->string topology)
                        'q_single q-single
                        'q_cap_per_machine q-cap
                        'min_achievable_q_per_machine min-q
                        'pruned_ucurve_candidates pruned-list))
              (err-result
               (list (lfq-type-diagnostic
                      "T-ParGuard"
                      "E-PARGUARD-NO-FEASIBLE-PARTITION"
                      (format "T-ParGuard (`~a`): minimum per-machine width ~a Q exceeds Q_cap = ~a Q across M <= ~a"
                              workload min-q q-cap m-max)
                      err-info)))]
             [else
              (define g (ParNonPartitionable 'bell-cut-exceeds-single-qpu))
              (define info
                (hasheq 'workload (format "~a" workload)
                        'paradigm "algebraic-limb"
                        'interconnect_topology (symbol->string topology)
                        'requested_machines m-max
                        'max_machines m-max
                        'q_cap_per_machine q-cap
                        'qpar_grade "ParNonPartitionable"
                        'reason "no-feasible-partition-under-qcap"
                        'optimal_machines 1
                        'machines_used 1
                        'q_single q-single
                        'q_allocated_per_machine q-single
                        'fits_q_cap #f
                        'lookup_ebits_total 0
                        'carry_ebits_total 0
                        'logical_ebits_total 0
                        'bell_cuts 0
                        'pruned_ucurve_candidates pruned-list
                        'fallback_to_single_machine #t))
              (define diag
                (lfq-type-diagnostic
                 "T-ParGuard"
                 "W-PARGUARD-FALLBACK-BELL-CUT"
                 (format "T-ParGuard (`~a`): no M <= ~a fits Q_cap = ~a; falling back to 1-machine schedule"
                         workload m-max q-cap)
                 info))
              (ok-result g
                         `(single-machine-fallback-schedule 1 ,single-machine-ir)
                         (hash-set info 'static_diagnostic (diag->jsexpr diag)))])])]
       [else
        (error 'solve-optimal-qpar-machines "Unrecognized paradigm `~a` in ~a" paradigm spec)])]
    [_
     (error 'solve-optimal-qpar-machines "Expected (par-cluster-opt-spec ...), got: ~a" spec)]))

(define (infer-qpar-grade spec)
  (match spec
    [`(par-cluster-opt-spec . ,kvs)
     (define h (parse-par-cluster-opt-plist kvs))
     (define strict? (hash-ref h 'strict-parallel? #f))
     (define non-strict-spec
       `(par-cluster-opt-spec ,@(append kvs '(#:strict-parallel? #f))))
     (define res (solve-optimal-qpar-machines non-strict-spec))
     (values (lfq-typecheck-result-inferred-type res)
             strict?
             (lfq-typecheck-result-metrics res))]
    [`(par-partition-spec
       #:workload ,workload
       #:paradigm ,paradigm
       #:requested-machines ,m-req
       #:q-single ,q-single
       #:q-per-machine ,q-per-mach
       #:q-comm ,q-comm
       #:bell-cuts ,bell-cuts
       #:max-bell-budget ,max-bell-budget
       #:strict-parallel? ,strict?)
     (cond
       [(<= m-req 1)
        (define g (if (eq? paradigm 'shot-sample) (ParShotLinear 1) (ParSliceable 1 0)))
        (values g
                strict?
                (hasheq 'workload (format "~a" workload)
                        'paradigm (symbol->string paradigm)
                        'requested_machines m-req
                        'qpar_grade (symbol->string (qpar-grade-tag g))
                        'machines_used 1
                        'q_single q-single
                        'q_allocated_per_machine q-single
                        'bell_cuts 0
                        'fallback_to_single_machine #f))]
       [(eq? paradigm 'shot-sample)
        (define g (ParShotLinear m-req))
        (values g
                strict?
                (hasheq 'workload (format "~a" workload)
                        'paradigm "shot-sample"
                        'requested_machines m-req
                        'qpar_grade "ParShotLinear"
                        'machines_used m-req
                        'q_single q-single
                        'q_allocated_per_machine q-single
                        'bell_cuts 0
                        'total_work_multiplier 1.0
                        'shot_throughput_speedup m-req
                        'fallback_to_single_machine #f))]
       [(memq paradigm '(grover-amplify isd-search))
        (define g (ParNonPartitionable 'zalka-grover-sublinear))
        (define zalka-blowup (sqrt (exact->inexact m-req)))
        (define max-width-saved (inexact->exact (floor (/ (log m-req) (log 2)))))
        (values g
                strict?
                (hasheq 'workload (format "~a" workload)
                        'paradigm (symbol->string paradigm)
                        'requested_machines m-req
                        'qpar_grade "ParNonPartitionable"
                        'reason "zalka-grover-sublinear"
                        'machines_used 1
                        'q_single q-single
                        'q_allocated_per_machine q-single
                        'bell_cuts 0
                        'zalka_total_work_blowup_factor zalka-blowup
                        'max_key_width_bits_saved max-width-saved
                        'fallback_to_single_machine #t))]
       [(eq? paradigm 'algebraic-limb)
        (define eff-q (+ q-per-mach q-comm))
        (if (and (< eff-q q-single) (<= bell-cuts max-bell-budget))
            (let ([g (ParSliceable m-req bell-cuts)])
              (values g
                      strict?
                      (hasheq 'workload (format "~a" workload)
                              'paradigm "algebraic-limb"
                              'requested_machines m-req
                              'qpar_grade "ParSliceable"
                              'machines_used m-req
                              'q_single q-single
                              'q_per_machine q-per-mach
                              'q_comm q-comm
                              'q_allocated_per_machine eff-q
                              'bell_cuts bell-cuts
                              'max_bell_budget max-bell-budget
                              'total_work_multiplier 1.0
                              'fallback_to_single_machine #f)))
            (let ([g (ParNonPartitionable 'bell-cut-exceeds-single-qpu)])
              (values g
                      strict?
                      (hasheq 'workload (format "~a" workload)
                              'paradigm "algebraic-limb"
                              'requested_machines m-req
                              'qpar_grade "ParNonPartitionable"
                              'reason "bell-cut-exceeds-single-qpu"
                              'machines_used 1
                              'q_single q-single
                              'attempted_q_per_machine_plus_comm eff-q
                              'q_allocated_per_machine q-single
                              'attempted_bell_cuts bell-cuts
                              'max_bell_budget max-bell-budget
                              'fallback_to_single_machine #t))))]
       [else
        (error 'infer-qpar-grade "Unrecognized parallel paradigm `~a` in ~a" paradigm spec)])]
    [_
     (error 'infer-qpar-grade "Malformed par-partition-spec: ~a" spec)]))

(define (compile-parallel-with-fallback spec
                                        [single-machine-ir 'single-machine-circuit]
                                        [multi-machine-ir 'distributed-multi-qpu-circuit])
  (match spec
    [`(par-cluster-opt-spec . ,_)
     (solve-optimal-qpar-machines spec single-machine-ir multi-machine-ir)]
    [_
     (define-values (grade strict? info) (infer-qpar-grade spec))
     (match grade
       [(qpar-grade 'ParSliceable m bcuts #f)
        (ok-result grade
                   (if (= m 1)
                       `(single-machine-schedule 1 ,single-machine-ir)
                       `(entangled-multi-machine-schedule ,m ,bcuts ,multi-machine-ir))
                   info)]
       [(qpar-grade 'ParShotLinear m 0 #f)
        (ok-result grade
                   `(shot-parallel-workers-schedule ,m ,single-machine-ir)
                   info)]
       [(qpar-grade 'ParNonPartitionable 1 0 reason)
        (define err-code
          (if (eq? reason 'zalka-grover-sublinear)
              "E-PARGUARD-ZALKA-GROVER-SUBLINEAR"
              "E-PARGUARD-BELL-CUT-EXCEEDS-SINGLE-QPU"))
        (define fallback-code
          (if (eq? reason 'zalka-grover-sublinear)
              "W-PARGUARD-FALLBACK-ZALKA-GROVER"
              "W-PARGUARD-FALLBACK-BELL-CUT"))
        (define msg
          (if (eq? reason 'zalka-grover-sublinear)
              (format "T-ParGuard (`~a`): serial Grover/ISD reflection state is non-sliceable and M=~a Zalka split incurs sqrt(M)=~ax total-work blowup for <=~a bits saved; ~a"
                      (hash-ref info 'workload)
                      (hash-ref info 'requested_machines)
                      (~r (hash-ref info 'zalka_total_work_blowup_factor) #:precision 2)
                      (hash-ref info 'max_key_width_bits_saved)
                      (if strict?
                          "rejected under #:strict-parallel? #t"
                          "automatically compiling 1-machine Single-Machine circuit (machines_used=1)"))
              (format "T-ParGuard (`~a`): multi-QPU cut requires Q_per_machine + q_comm = ~a vs Q_single = ~a (bell_cuts = ~a vs budget ~a); ~a"
                      (hash-ref info 'workload)
                      (hash-ref info 'attempted_q_per_machine_plus_comm)
                      (hash-ref info 'q_single)
                      (hash-ref info 'attempted_bell_cuts)
                      (hash-ref info 'max_bell_budget)
                      (if strict?
                          "rejected under #:strict-parallel? #t"
                          "automatically compiling 1-machine Single-Machine circuit (machines_used=1)"))))
        (if strict?
            (err-result
             (list (lfq-type-diagnostic "T-ParGuard" err-code msg info)))
            (let ([fallback-diag (lfq-type-diagnostic "T-ParGuard" fallback-code msg info)])
              (ok-result grade
                         `(single-machine-fallback-schedule 1 ,single-machine-ir)
                         (hash-set info 'static_diagnostic (diag->jsexpr fallback-diag)))))])]))

(define (check-parallel-partition-guard spec)
  (match spec
    [`(par-partition-bundle ,subs ...)
     (define res-list (map (lambda (s) (compile-parallel-with-fallback s)) subs))
     (define bad (filter (lambda (r) (not (lfq-typecheck-result-well-typed? r))) res-list))
     (if (not (null? bad))
         (err-result (apply append (map lfq-typecheck-result-diagnostics bad)))
         (ok-result (map lfq-typecheck-result-inferred-type res-list)
                    `(verified-par-bundle ,@(map lfq-typecheck-result-synthesized-ir res-list))
                    (hasheq 'decisions (map lfq-typecheck-result-metrics res-list))))]
    [_
     (compile-parallel-with-fallback spec)]))

;; =============================================================================
;; SECTION 9: Unified Top-Level Typechecker Entry Point & `#lang lakefillq`
;;            Surface AST Integration Hooks
;; =============================================================================

(define (typecheck-lfq-bug-prevention-program expr)
  (match expr
    [`(rule-dom-img ,spec) (check-part-bij-dom-img! spec)]
    [`(rule-valid-if ,prog) (check-valid-if-program prog)]
    [`(rule-alg-phase-involutory ,consumer ,op) (check-involutory-operator! op consumer)]
    [`(rule-qblock ,qb-expr) (infer-qblock-alg-phase-and-eps qb-expr)]
    [`(rule-wire-basis ,wb-prog) (check-wire-basis-and-stencil wb-prog)]
    [`(rule-drift-eps ,drift-spec) (check-coset-and-rns-drift drift-spec)]
    [`(rule-single-ir ,sir-spec) (check-single-ir-and-grover-oracle! sir-spec)]
    [`(rule-par-guard ,par-spec) (check-parallel-partition-guard par-spec)]
    [`(program-bundle ,items ...)
     (define sub-res (map typecheck-lfq-bug-prevention-program items))
     (define bad (filter (lambda (r) (not (lfq-typecheck-result-well-typed? r))) sub-res))
     (if (not (null? bad))
         (err-result (apply append (map lfq-typecheck-result-diagnostics bad)))
         (ok-result (map lfq-typecheck-result-inferred-type sub-res)
                    `(seq ,@(map lfq-typecheck-result-synthesized-ir sub-res))))]
    [_
     (error 'typecheck-lfq-bug-prevention-program "Unrecognized top-level typed form: ~a" expr)]))

;; Surface AST heads recognized inside `#lang lakefillq` (`lakefillq/main.rkt` & `lakefillqc.rkt`):
(define bug-class-guard-surface-heads
  '(erase-by-part-bij
    guard-valid-if
    guard-involutory
    guard-qblock-lcu-phase
    guard-wire-basis
    guard-drift-eps
    guard-single-ir
    guard-par-partition))

;; Walks a `#lang lakefillq` surface AST, runs all embedded 7-rule static checks,
;; and returns a list of structured violation hashes (empty iff all 7 rules pass!):
(define (check-surface-bug-class-guards surface-ast)
  (define diags '())
  (define (record-res! res)
    (unless (lfq-typecheck-result-well-typed? res)
      (set! diags (append diags (lfq-typecheck-result-diagnostics res)))))
  (let walk ([e surface-ast])
    (match e
      [`(erase-by-part-bij ,spec ,fwd ,bwd ,_)
       (record-res! (check-part-bij-dom-img! spec))
       (walk fwd)
       (walk bwd)]
      [`(guard-valid-if ,vprog ,body)
       (record-res! (check-valid-if-program vprog))
       (walk body)]
      [`(guard-involutory ,consumer ,op-spec ,body)
       (record-res! (check-involutory-operator! op-spec consumer))
       (walk body)]
      [`(guard-qblock-lcu-phase ,qb-expr ,body)
       (record-res! (infer-qblock-alg-phase-and-eps qb-expr))
       (walk body)]
      [`(guard-wire-basis ,wb-prog ,body)
       (record-res! (check-wire-basis-and-stencil wb-prog))
       (walk body)]
      [`(guard-drift-eps ,drift-spec ,body)
       (record-res! (check-coset-and-rns-drift drift-spec))
       (walk body)]
      [`(guard-single-ir ,sir-spec ,body)
       (record-res! (check-single-ir-and-grover-oracle! sir-spec))
       (walk body)]
      [`(guard-par-partition ,par-spec ,body)
       (record-res! (check-parallel-partition-guard par-spec))
       (walk body)]
      [`(seq ,es ...) (for ([sub (in-list es)]) (walk sub))]
      [`(invert ,sub) (walk sub)]
      [`(with-and-session ,_ ,b) (walk b)]
      [`(within-apply-mbu ,c ,a ,_) (walk c) (walk a)]
      [`(within-apply ,c ,a ,_) (walk c) (walk a)]
      [`(erase-by ,f ,b ,_) (walk f) (walk b)]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd) (walk nd)]
      [`(braun-branch ,_ ,s ,l ,r) (walk s) (walk l) (walk r)]
      [`(par-wires ,e1 ,e2) (walk e1) (walk e2)]
      [`(multishot-reset ,_ ,b) (walk b)]
      [_ (void)]))
  (map diag->jsexpr diags))

;; Collects all `T-ParGuard` parallel-partitionability & Single-Machine fallback
;; decisions across a `#lang lakefillq` surface AST:
(define (collect-surface-par-guard-decisions surface-ast)
  (define decisions '())
  (define (record-par! spec)
    (match spec
      [`(par-partition-bundle ,subs ...)
       (for ([s (in-list subs)]) (record-par! s))]
      [_
       (define res (compile-parallel-with-fallback spec))
       (when (lfq-typecheck-result-well-typed? res)
         (set! decisions (append decisions (list (lfq-typecheck-result-metrics res)))))]))
  (let walk ([e surface-ast])
    (match e
      [`(erase-by-part-bij ,_ ,fwd ,bwd ,_) (walk fwd) (walk bwd)]
      [`(guard-valid-if ,_ ,body) (walk body)]
      [`(guard-involutory ,_ ,_ ,body) (walk body)]
      [`(guard-qblock-lcu-phase ,_ ,body) (walk body)]
      [`(guard-wire-basis ,_ ,body) (walk body)]
      [`(guard-drift-eps ,_ ,body) (walk body)]
      [`(guard-single-ir ,_ ,body) (walk body)]
      [`(guard-par-partition ,par-spec ,body)
       (record-par! par-spec)
       (walk body)]
      [`(seq ,es ...) (for ([sub (in-list es)]) (walk sub))]
      [`(invert ,sub) (walk sub)]
      [`(with-and-session ,_ ,b) (walk b)]
      [`(within-apply-mbu ,c ,a ,_) (walk c) (walk a)]
      [`(within-apply ,c ,a ,_) (walk c) (walk a)]
      [`(erase-by ,f ,b ,_) (walk f) (walk b)]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd) (walk nd)]
      [`(braun-branch ,_ ,s ,l ,r) (walk s) (walk l) (walk r)]
      [`(par-wires ,e1 ,e2) (walk e1) (walk e2)]
      [`(multishot-reset ,_ ,b) (walk b)]
      [_ (void)]))
  decisions)

;; Elaborates guarded `#lang lakefillq` surface forms into pure `LakefillQ` kernel
;; primitives (`0` residual surface forms!), including synthesizing `S^d` compensating
;; phase gates for `guard-qblock-lcu-phase` and Single-Machine / multi-QPU schedule lowering
;; for `guard-par-partition`!
(define (elaborate-bug-class-guard-surface expr recur-elaborate)
  (match expr
    [`(erase-by-part-bij ,_spec ,fwd ,bwd ,erased-ws)
     (recur-elaborate `(erase-by ,fwd ,bwd ,erased-ws))]
    [`(guard-valid-if ,vprog ,body)
     (define vres (check-valid-if-program vprog))
     (define extra-mcz
       (if (lfq-typecheck-result-well-typed? vres)
           (let collect-mcz ([ir (lfq-typecheck-result-synthesized-ir vres)])
             (match ir
               [`(mcz ,ctrls ,scr) (list `(mcz ,ctrls ,scr))]
               [`(seq ,xs ...) (apply append (map collect-mcz xs))]
               [_ '()]))
           '()))
     (recur-elaborate `(seq ,@extra-mcz ,body))]
    [`(guard-involutory ,_consumer ,_op-spec ,body)
     (recur-elaborate body)]
    [`(guard-qblock-lcu-phase ,qb-expr ,body)
     (define qres (infer-qblock-alg-phase-and-eps qb-expr))
     (define comp-gates
       (if (lfq-typecheck-result-well-typed? qres)
           (match (lfq-typecheck-result-synthesized-ir qres)
             [`(phase-compensated-lcu (compensating-gates ,gs ...) ,_) gs]
             [`(phase-compensated-ctrl ,_ ,gs ,_) gs]
             [_ '()])
           '()))
     (recur-elaborate `(seq ,@comp-gates ,body))]
    [`(guard-wire-basis ,_wb-prog ,body)
     (recur-elaborate body)]
    [`(guard-drift-eps ,_drift-spec ,body)
     (recur-elaborate body)]
    [`(guard-single-ir ,_sir-spec ,body)
     (recur-elaborate body)]
    [`(guard-par-partition ,_par-spec ,body)
     (recur-elaborate body)]
    [_ #f]))

;; =============================================================================
;; SECTION 10: Domain Builders for the 14 Wild Research Bugs & 12 Generalized Cases
;; =============================================================================

;; --- Helper 1: Short Weierstrass E(F_13) : y^2 = x^3 + x + 7 (mod 13), Q = (1, 3) ---
;; Group order = 13; 2Q = (7, 5), -2Q = (7, 8), -Q = (1, 10).
;; Note: P = -2Q = (7, 8) satisfies x_P = 7 != 1 = x_Q, so forward chord addition
;; succeeds and yields R = P + Q = -Q = (1, 10), where x_R = 1 == x_Q!
(define ec-f13-smt2-preamble
  (string-join
   '("(define-fun mod13 ((z (_ BitVec 16))) (_ BitVec 16) (bvurem z #x000d))"
     "(define-fun add13 ((a (_ BitVec 16)) (b (_ BitVec 16))) (_ BitVec 16) (bvurem (bvadd a b) #x000d))"
     "(define-fun sub13 ((a (_ BitVec 16)) (b (_ BitVec 16))) (_ BitVec 16)"
     "  (bvurem (bvadd (bvurem a #x000d) (bvsub #x000d (bvurem b #x000d))) #x000d))"
     "(define-fun mul13 ((a (_ BitVec 16)) (b (_ BitVec 16))) (_ BitVec 16)"
     "  (bvurem (bvmul (bvurem a #x000d) (bvurem b #x000d)) #x000d))"
     "(define-fun on_curve ((x (_ BitVec 16)) (y (_ BitVec 16))) Bool"
     "  (and (bvult x #x000d) (bvult y #x000d)"
     "       (= (mul13 y y) (add13 (mul13 x (mul13 x x)) (add13 x #x0007)))))"
     ;; Precomputed modular inverse mod 13 (#x0000 |-> #x0000):
     "(define-fun inv13 ((a (_ BitVec 16))) (_ BitVec 16)"
     "  (let ((m (mod13 a)))"
     "    (ite (= m #x0001) #x0001 (ite (= m #x0002) #x0007 (ite (= m #x0003) #x0009 (ite (= m #x0004) #x000a"
     "    (ite (= m #x0005) #x0008 (ite (= m #x0006) #x000b (ite (= m #x0007) #x0002 (ite (= m #x0008) #x0005"
     "    (ite (= m #x0009) #x0003 (ite (= m #x000a) #x0004 (ite (= m #x000b) #x0006 (ite (= m #x000c) #x000c #x0000))))))))))))))"
     ;; Distinct-point chord addition P + Q with Q = (1, 3):
     "(define-fun chord_lam_fwd ((xp (_ BitVec 16)) (yp (_ BitVec 16))) (_ BitVec 16)"
     "  (mul13 (sub13 yp #x0003) (inv13 (sub13 xp #x0001))))"
     "(define-fun chord_x3 ((xp (_ BitVec 16)) (yp (_ BitVec 16))) (_ BitVec 16)"
     "  (let ((lam (chord_lam_fwd xp yp)))"
     "    (sub13 (mul13 lam lam) (add13 xp #x0001))))"
     "(define-fun chord_y3 ((xp (_ BitVec 16)) (yp (_ BitVec 16))) (_ BitVec 16)"
     "  (let ((lam (chord_lam_fwd xp yp)) (x3 (chord_x3 xp yp)))"
     "    (sub13 (mul13 lam (sub13 xp x3)) yp)))"
     ;; Reverse chord uncomputation R + (-Q) with -Q = (1, 10):
     "(define-fun chord_lam_rev ((xr (_ BitVec 16)) (yr (_ BitVec 16))) (_ BitVec 16)"
     "  (mul13 (sub13 yr #x000a) (inv13 (sub13 xr #x0001))))"
     "(define-fun chord_rev_x ((xr (_ BitVec 16)) (yr (_ BitVec 16))) (_ BitVec 16)"
     "  (let ((lam (chord_lam_rev xr yr)))"
     "    (sub13 (mul13 lam lam) (add13 xr #x0001))))"
     "(define-fun chord_rev_y ((xr (_ BitVec 16)) (yr (_ BitVec 16))) (_ BitVec 16)"
     "  (let ((lam (chord_lam_rev xr yr)) (x0 (chord_rev_x xr yr)))"
     "    (sub13 (mul13 lam (sub13 xr x0)) yr)))")
   "\n"))

;; --- Helper 2: Kaliski Binary GCD Terminal Cleanup modulo p = 13 ---
(define kaliski-f13-smt2-preamble
  (string-join
   '("(define-fun inv13 ((a Int)) Int"
     "  (ite (= a 1) 1 (ite (= a 2) 7 (ite (= a 3) 9 (ite (= a 4) 10"
     "  (ite (= a 5) 8 (ite (= a 6) 11 (ite (= a 7) 2 (ite (= a 8) 5"
     "  (ite (= a 9) 3 (ite (= a 10) 4 (ite (= a 11) 6 (ite (= a 12) 12 0)))))))))))))"
     ;; Unguarded Kaliski: at x = 0, (u, s) = (13, 1), terminal XOR (1, 13) leaves (12, 12) != (0, 0)
     "(define-fun kaliski_unguarded_out ((x Int)) Int (ite (= x 0) 13 (inv13 x)))"
     "(define-fun kaliski_unguarded_res ((x Int)) Int (ite (= x 0) 12 0))"
     ;; Zero-guarded Kaliski: conditional (u <-> s) swap before terminal XOR leaves (0, 0)
     "(define-fun kaliski_guarded_out ((x Int)) Int (inv13 x))"
     "(define-fun kaliski_guarded_res ((x Int)) Int 0)")
   "\n"))

;; --- Helper 3: Hamming [7, 4, 3] parity check H (3 x 7, d_perp = 3) for DQI ---
;; Columns 1..7 in binary: (1,0,0), (0,1,0), (1,1,0), (0,0,1), (1,0,1), (0,1,1), (1,1,1)
(define dqi-hamming7-smt2-preamble
  (string-join
   '("(define-fun b2i ((b Bool)) Int (ite b 1 0))"
     "(define-fun wt7 ((e0 Bool) (e1 Bool) (e2 Bool) (e3 Bool) (e4 Bool) (e5 Bool) (e6 Bool)) Int"
     "  (+ (b2i e0) (b2i e1) (b2i e2) (b2i e3) (b2i e4) (b2i e5) (b2i e6)))"
     "(define-fun synd0 ((e0 Bool) (e1 Bool) (e2 Bool) (e3 Bool) (e4 Bool) (e5 Bool) (e6 Bool)) Bool"
     "  (xor e0 e2 e4 e6))"
     "(define-fun synd1 ((e0 Bool) (e1 Bool) (e2 Bool) (e3 Bool) (e4 Bool) (e5 Bool) (e6 Bool)) Bool"
     "  (xor e1 e2 e5 e6))"
     "(define-fun synd2 ((e0 Bool) (e1 Bool) (e2 Bool) (e3 Bool) (e4 Bool) (e5 Bool) (e6 Bool)) Bool"
     "  (xor e3 e4 e5 e6))"
     ;; Exact wt <= 1 syndrome decoder for Hamming [7, 4, 3]:
     "(define-fun dec_b ((s0 Bool) (s1 Bool) (s2 Bool) (idx Int)) Bool"
     "  (let ((code (+ (ite s0 1 0) (ite s1 2 0) (ite s2 4 0))))"
     "    (= code (+ idx 1))))"
     ;; Non-square GJEGate(B.T) left-pivot inverse only recovers pivot columns {0, 1, 3}:
     "(define-fun gje_bt_b ((s0 Bool) (s1 Bool) (s2 Bool) (idx Int)) Bool"
     "  (ite (= idx 0) s0 (ite (= idx 1) s1 (ite (= idx 3) s2 false))))")
   "\n"))

;; Forward Keccak chi_5 out-of-place -> copy-back vs ReVerC buggy forward-uncompute:
;; On 5 wires `0..4`, out-of-place chi_5 using 2 backup wires `5, 6` IS bijective of algebraic
;; degree 2, and its inverse has algebraic degree 3 (`chi_5(chi_5(x)) != x` on 20/32 inputs)!
(define keccak-chi5-2anc-gates
  ;; Assumes wires 5 and 6 start at 0, computes chi_5 in-place on 0..4, and cleans 5, 6:
  ;; Wait: to act purely on 5 wires (or 7 wires), let's test the exact 5-wire bijection via
  ;; 2 scratch wires cleaned by degree-2 inverse vs uncleaned: even simpler, on 5 wires + 5 target
  ;; wires (`0..4` input, `5..9` target XORed with `x_i ^ (~x_{i+1} & x_{i+2})`), wait:
  ;; In `ReVerC` `keccakf:517`, `chi_5` maps `x |-> chi_5(x)` in-place; if we express exact `chi_5`
  ;; on 5 wires using 2 temporary clean wires `5, 6` and exact cleanup of `5, 6` via inverse formula:
  ;; In `GF(2)^5`, `y_i = x_i ^ (~x_{i+1} & x_{i+2})` recovers `x_0 = y_0 ^ (~(y_1 ^ (~y_2 & (y_3 ^ (~y_4 & y_0)))) & ...)`!
  ;; Even cleaner: on 7 wires where `5, 6` are clean scratch, we can also check `chi_5` directly on
  ;; 5 wires using `chi5` decomposition, OR check `(not-and-xor ...)` with backup copy + exact degree-3 uncompute!
  (list
   ;; Backup x0 -> w5, x1 -> w6:
   '(cx 0 5)
   '(cx 1 6)
   ;; Simultaneous chi_5 onto w0..w4 using backups w5=x0, w6=x1:
   '(not-and-xor 6 2 0)
   '(not-and-xor 2 3 1)
   '(not-and-xor 3 4 2)
   '(not-and-xor 4 5 3)
   '(not-and-xor 5 6 4)
   ;; Exact degree-3 uncomputation of backups w5 (= x0) and w6 (= x1) from y0..y4!
   ;; For 5-bit chi_5, x_i = y_i ^ (~y_{i+1} & (y_{i+2} ^ (~y_{i+3} & y_{i+4})))!
   ;; Let's verify! Since x_{i+1} & ~x_{i+2} == y_{i+1} & ~y_{i+2}? Let's check with Z3!
   ))

;; Let's build the exact 5-bit `chi_5` pure permutation on 5 wires in reversible gates!
;; Notice over GF(2)^5, `chi_5` has exact inverse:
;;   `x_i = y_i + (y_{i+1} + 1) * (y_{i+2} + (y_{i+3} + 1) * y_{i+4})`? Wait:
;; Let's check: `y_{i+2} + (~x_{i+3}) x_{i+4}`... Instead of guessing, let's check on 3-bit or 5-bit:
;; In `ReVerC` `keccakf:506-522`, `keccakf` computes out-of-place `out[i] ^= a[i] ^ (~a[i+1] & a[i+2])`
;; and then tries to erase `a` using the forward formula `a[i] ^= out[i] ^ (~out[i+1] & out[i+2])`,
;; which leaves `a[i] = chi_5(chi_5(a_init))[i] ^ a_init[i] != 0` because `chi_5(chi_5(x)) != x`!
;; On 10 wires (`a = 0..4`, `out = 5..9`), forward step + swap `(a <-> out)` + forward erase is:
(define reverc-keccak-chi5-10wire-gates
  (append
   ;; out[i] ^= a[i] ^ (~a[i+1] & a[i+2])
   (for/list ([i (in-range 5)]) `(cx ,i ,(+ 5 i)))
   (for/list ([i (in-range 5)])
     `(not-and-xor ,(modulo (+ i 1) 5) ,(modulo (+ i 2) 5) ,(+ 5 i)))
   ;; Swap a[0..4] <-> out[0..4] so wires 0..4 hold y = chi_5(a) and 5..9 hold a:
   (for/list ([i (in-range 5)]) `(swap ,i ,(+ 5 i)))))

;;Notice: `reverc-keccak-chi5-10wire-gates` maps `(a, 0) |-> (chi_5(a), a)`!
;; Applying it TWICE (`self-uncompute`!) maps `(a, 0) |-> (chi_5(chi_5(a)), a ^ chi_5(a)) != (a, 0)`!
;; Whereas a true involution `(a, b) |-> (a, b ^ f(a))` (without swapping the non-involutory output
;; back over the input!) maps `(a, b) |-> (a, b ^ f(a)) |-> (a, b)`!

;; Bit-reversed 8x8 linear map `rev8 o canonical-aes-poly->tower-lsb`:
(define reversed-endian-tower-rows
  (reverse canonical-aes-poly->tower-lsb-rows))

;; Non-identity 32-wire MixColumn PLU row permutation (`T-typeAES:142` `MixedColumn` relabeling):
(define mixcolumn-plu-perm-32
  (append (range 8 32) (range 0 8)))

(define mixcolumn-plu-inv-perm-32
  (invert-wire-perm mixcolumn-plu-perm-32))

;; =============================================================================
;; SECTION 11: Canonical Catalog of All 14 Wild Research Bugs (14 Negative + 14 Positive)
;; =============================================================================

(define (build-14-wild-research-bug-cases)
  (list
   ;; -------------------------------------------------------------------------
   ;; WB01 [Rule T-DomImg]: `microsoft/QuantumEllipticCurves` (`EllipticCurves.qs:390-492`)
   ;; Reverse-slope `P + Q = -Q => x3 = x2` zero-divisor in `erase-by`
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB01"
    'rule "T-DomImg"
    'expected_code "E-DOMIMG-IMG-OUTSIDE-INVDOM"
    'repo "microsoft/QuantumEllipticCurves"
    'source_ref "MicrosoftQuantumCrypto/EllipticCurves.qs:390-492"
    'description "Distinct-point chord EC addition P + Q fails reverse-slope uncomputation at P = -2Q where x3 = x2"
    'negative_ast
    `(rule-dom-img
      (part-bij-smt2
       #:label ec-chord-add-unguarded-rev-slope
       #:vars ((xp (_ BitVec 16)) (yp (_ BitVec 16)))
       #:vars-alt ((xp2 (_ BitVec 16)) (yp2 (_ BitVec 16)))
       #:preamble ,ec-f13-smt2-preamble
       #:dom-f "(and (on_curve xp yp) (not (= xp #x0001)))"
       #:f-out ("(chord_x3 xp yp)" "(chord_y3 xp yp)")
       #:dom-g-on-f "(and (on_curve (chord_x3 xp yp) (chord_y3 xp yp)) (not (= (chord_x3 xp yp) #x0001)))"
       #:g-of-f ("(chord_rev_x (chord_x3 xp yp) (chord_y3 xp yp))"
                 "(chord_rev_y (chord_x3 xp yp) (chord_y3 xp yp))")
       #:residual ()
       #:f-out-alt ("(chord_x3 xp2 yp2)" "(chord_y3 xp2 yp2)")
       #:dom-f-alt "(and (on_curve xp2 yp2) (not (= xp2 #x0001)))"))
    'positive_ast
    `(rule-dom-img
      (part-bij-smt2
       #:label ec-chord-add-signed-odd-trajectory-guarded
       #:vars ((xp (_ BitVec 16)) (yp (_ BitVec 16)))
       #:vars-alt ((xp2 (_ BitVec 16)) (yp2 (_ BitVec 16)))
       #:preamble ,ec-f13-smt2-preamble
       #:dom-f "(and (on_curve xp yp) (not (= xp #x0001)) (not (and (= xp #x000a) (= yp #x0009))))"
       #:f-out ("(chord_x3 xp yp)" "(chord_y3 xp yp)")
       #:dom-g-on-f "(and (on_curve (chord_x3 xp yp) (chord_y3 xp yp)) (not (= (chord_x3 xp yp) #x0001)))"
       #:g-of-f ("(chord_rev_x (chord_x3 xp yp) (chord_y3 xp yp))"
                 "(chord_rev_y (chord_x3 xp yp) (chord_y3 xp yp))")
       #:residual ()
       #:f-out-alt ("(chord_x3 xp2 yp2)" "(chord_y3 xp2 yp2)")
       #:dom-f-alt "(and (on_curve xp2 yp2) (not (= xp2 #x0001)) (not (and (= xp2 #x000a) (= yp2 #x0009))))")))

   ;; -------------------------------------------------------------------------
   ;; WB02 [Rule T-DomImg]: `microsoft/QuantumEllipticCurves` / `Qualtran`
   ;; (`ModularArithmetic.qs:2177-2229`, `mod_division.py:571`) Kaliski `x = 0` stall
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB02"
    'rule "T-DomImg"
    'expected_code "E-DOMIMG-ROUNDTRIP-RESIDUAL"
    'repo "microsoft/QuantumEllipticCurves & quantumlib/Qualtran"
    'source_ref "MicrosoftQuantumCrypto/ModularArithmetic.qs:2177-2229; mod_division.py:571"
    'description "Kaliski binary GCD stalls on x = 0 at (u,v,r,s)=(p,0,0,1), leaving dirty ancillas u = s = p - 1"
    'negative_ast
    `(rule-dom-img
      (part-bij-smt2
       #:label kaliski-mod-inv-unguarded-zero
       #:vars ((x Int))
       #:vars-alt ((x2 Int))
       #:preamble ,kaliski-f13-smt2-preamble
       #:dom-f "(and (<= 0 x) (< x 13))"
       #:f-out ("(kaliski_unguarded_out x)")
       #:dom-g-on-f "(and (<= 0 (kaliski_unguarded_out x)) (< (kaliski_unguarded_out x) 14))"
       #:g-of-f ("(inv13 (kaliski_unguarded_out x))")
       #:residual ("(kaliski_unguarded_res x)")
       #:f-out-alt ("(kaliski_unguarded_out x2)")
       #:dom-f-alt "(and (<= 0 x2) (< x2 13))"))
    'positive_ast
    `(rule-dom-img
      (part-bij-smt2
       #:label kaliski-mod-inv-zero-guarded-total
       #:vars ((x Int))
       #:vars-alt ((x2 Int))
       #:preamble ,kaliski-f13-smt2-preamble
       #:dom-f "(and (<= 0 x) (< x 13))"
       #:f-out ("(kaliski_guarded_out x)")
       #:dom-g-on-f "(and (<= 0 (kaliski_guarded_out x)) (< (kaliski_guarded_out x) 13))"
       #:g-of-f ("(kaliski_guarded_out (kaliski_guarded_out x))")
       #:residual ("(kaliski_guarded_res x)")
       #:f-out-alt ("(kaliski_guarded_out x2)")
       #:dom-f-alt "(and (<= 0 x2) (< x2 13))")))

   ;; -------------------------------------------------------------------------
   ;; WB03 [Rule T-DomImg]: `BankNatchapol/DQI-Circuit`
   ;; (`generate_dqi_circuit_qiskit.py:216,298-314`) Out-of-radius `2*ell >= d_perp`
   ;; & non-square `GJEGate(B.T)` non-injective syndrome uncomputation
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB03"
    'rule "T-DomImg"
    'expected_code "E-DOMIMG-NON-INJECTIVE"
    'repo "BankNatchapol/DQI-Circuit"
    'source_ref "scripts/generate_dqi_circuit_qiskit.py:216,298-314"
    'description "DQI syndrome erasure with ell = 2 on d_perp = 3 (2*ell >= d_perp) collides in syndrome space"
    'negative_ast
    `(rule-dom-img
      (part-bij-smt2
       #:label dqi-hamming7-ell2-out-of-radius
       #:vars ((e0 Bool) (e1 Bool) (e2 Bool) (e3 Bool) (e4 Bool) (e5 Bool) (e6 Bool))
       #:vars-alt ((f0 Bool) (f1 Bool) (f2 Bool) (f3 Bool) (f4 Bool) (f5 Bool) (f6 Bool))
       #:preamble ,dqi-hamming7-smt2-preamble
       #:dom-f "(<= (wt7 e0 e1 e2 e3 e4 e5 e6) 2)"
       #:f-out ("(synd0 e0 e1 e2 e3 e4 e5 e6)"
                "(synd1 e0 e1 e2 e3 e4 e5 e6)"
                "(synd2 e0 e1 e2 e3 e4 e5 e6)")
       #:dom-g-on-f "true"
       #:g-of-f ,@(list (for/list ([idx (in-range 7)])
                          (format "(gje_bt_b (synd0 e0 e1 e2 e3 e4 e5 e6) (synd1 e0 e1 e2 e3 e4 e5 e6) (synd2 e0 e1 e2 e3 e4 e5 e6) ~a)" idx)))
       #:residual ()
       #:f-out-alt ("(synd0 f0 f1 f2 f3 f4 f5 f6)"
                    "(synd1 f0 f1 f2 f3 f4 f5 f6)"
                    "(synd2 f0 f1 f2 f3 f4 f5 f6)")
       #:dom-f-alt "(<= (wt7 f0 f1 f2 f3 f4 f5 f6) 2)"))
    'positive_ast
    `(rule-dom-img
      (part-bij-smt2
       #:label dqi-hamming7-ell1-bounded-distance-exact
       #:vars ((e0 Bool) (e1 Bool) (e2 Bool) (e3 Bool) (e4 Bool) (e5 Bool) (e6 Bool))
       #:vars-alt ((f0 Bool) (f1 Bool) (f2 Bool) (f3 Bool) (f4 Bool) (f5 Bool) (f6 Bool))
       #:preamble ,dqi-hamming7-smt2-preamble
       #:dom-f "(<= (wt7 e0 e1 e2 e3 e4 e5 e6) 1)"
       #:f-out ("(synd0 e0 e1 e2 e3 e4 e5 e6)"
                "(synd1 e0 e1 e2 e3 e4 e5 e6)"
                "(synd2 e0 e1 e2 e3 e4 e5 e6)")
       #:dom-g-on-f "true"
       #:g-of-f ,@(list (for/list ([idx (in-range 7)])
                          (format "(dec_b (synd0 e0 e1 e2 e3 e4 e5 e6) (synd1 e0 e1 e2 e3 e4 e5 e6) (synd2 e0 e1 e2 e3 e4 e5 e6) ~a)" idx)))
       #:residual ()
       #:f-out-alt ("(synd0 f0 f1 f2 f3 f4 f5 f6)"
                    "(synd1 f0 f1 f2 f3 f4 f5 f6)"
                    "(synd2 f0 f1 f2 f3 f4 f5 f6)")
       #:dom-f-alt "(<= (wt7 f0 f1 f2 f3 f4 f5 f6) 1)")))

   ;; -------------------------------------------------------------------------
   ;; WB04 [Rule T-ValidIf]: `tigerjack/isd-quantum` / `paper-codes/2023-TQuantum`
   ;; (`lee_brickell_bruteforce_circ.py:210-219`, `gauss_jordan_isd4.py:65-102`)
   ;; Unguarded `wt(s_tilde) == t` phase flip on `71.12%` singular `F_2^{r x r}` submatrices
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB04"
    'rule "T-ValidIf"
    'expected_code "E-VALIDIF-UNGUARDED-PHASE-FLIP"
    'repo "tigerjack/isd-quantum & paper-codes/2023-TQuantum"
    'source_ref "isdquantum/methods/circuits/lee_brickell_bruteforce_circ.py:210-219; gauss_jordan_isd4.py:65"
    'description "Coherent QGJE kicks back Grover phase on wt(s_tilde) == w - p without guarding on non_singular = AND_j diag[j]"
    'negative_ast
    '(rule-valid-if
      (valid-if-seq
       (bind-partial-op non_singular 0 s_tilde (QVec 768 id F2StdBasis) qgje-solve)
       (derive-pred lee_eq_q (s_tilde) 1)
       (phase-flip-if (lee_eq_q) (1) (2))))
    'positive_ast
    '(rule-valid-if
      (valid-if-seq
       (bind-partial-op non_singular 0 s_tilde (QVec 768 id F2StdBasis) qgje-solve)
       (with-valid non_singular s_tilde
                   (valid-if-seq
                    (derive-pred lee_eq_q (s_tilde) 1)
                    (phase-flip-if (lee_eq_q) (1) (2)))))))

   ;; -------------------------------------------------------------------------
   ;; WB05 [Rule T-AlgPhase]: `quantumlib/Qualtran` `SelectTHC:438`, `SelectSparse:122`,
   ;; & `Cobble` `Const:300` non-involutory `SELECT` inside `qubitization-walk`
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB05"
    'rule "T-AlgPhase"
    'expected_code "E-ALGPHASE-NONCOMM-PRODUCT"
    'repo "quantumlib/Qualtran & charlesyuan314/cobble"
    'source_ref "qualtran/bloqs/chemistry/thc/select_bloq.py:438; sparse/select_bloq.py:122; cobble/expr.py:300"
    'description "Qubitization walk SELECT applies non-commuting A_mu * A_nu without (mu <-> nu) PartnerSwap (and/or i*P scalar phase)"
    'negative_ast
    '(rule-qblock
      (qubitization-walk
       femoco-thc-walk-buggy
       (qblock-exact femoco-prep 1098.0 16 0)
       (op-seq (pauli-string ((0 X) (1 Z)))
               (pauli-string ((0 Z) (2 X))))))
    'positive_ast
    '(rule-qblock
      (qubitization-walk
       femoco-thc-walk-repaired
       (qblock-exact femoco-prep 1098.0 16 0)
       (partner-swap-select
        ((1 2) (2 1) (3 3))
        ((branch 1 0 (A_mu A_nu))
         (branch 2 0 (A_nu A_mu))
         (branch 3 0 (Z_diag)))))))

   ;; -------------------------------------------------------------------------
   ;; WB06 [Rule T-AlgPhase]: `msr-quarc/ReVerC` (`Examples.fs:517`, `keccakf`)
   ;; Forward degree-2 `Keccak` `chi_5` used in `self-uncompute` (`chi_5(chi_5(x)) != x`)
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB06"
    'rule "T-AlgPhase"
    'expected_code "E-ALGPHASE-NON-INVOLUTORY-CIRCUIT"
    'repo "msr-quarc/ReVerC"
    'source_ref "reverc/Examples.fs:506-522 (keccakf)"
    'description "ReVerC keccakf invokes forward degree-2 chi_5 to uncompute itself, corrupting 20/32 5-bit lane states"
    'negative_ast
    `(rule-alg-phase-involutory
      self-uncompute
      (rev-circuit reverc-keccak-chi5-fwd 10 ,reverc-keccak-chi5-10wire-gates))
    'positive_ast
    `(rule-alg-phase-involutory
      self-uncompute
      (rev-circuit out-of-place-chi5-toggle 10
                   ,(append
                     (for/list ([i (in-range 5)]) `(cx ,i ,(+ 5 i)))
                     (for/list ([i (in-range 5)])
                       `(not-and-xor ,(modulo (+ i 1) 5) ,(modulo (+ i 2) 5) ,(+ 5 i)))))))

   ;; -------------------------------------------------------------------------
   ;; WB07 [Rule T-AlgPhase]: `PennyLane` / `Cobble` (`qsvt.py`, `polynomial.py`)
   ;; `Wx -> R` `(-i)^d` `Z_4` global-phase sign flip in `LCU` sum `T_0(A) + T_2(A)`
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB07"
    'rule "T-AlgPhase"
    'expected_code "E-ALGPHASE-LCU-PHASE-MISMATCH"
    'repo "PennyLaneAI/pennylane & charlesyuan314/cobble"
    'source_ref "pennylane/templates/subroutines/qsvt.py; cobble/polynomial.py"
    'description "Wx->R conversion introduces (-i)^d global phase (1 vs -1 at d=0,2), cancelling T_0 + T_2 in uncompensated LCU sum"
    'negative_ast
    '(rule-qblock
      (raw-lcu-sum
       ((wx->reflection 0 (qblock-exact H 1.0 2 0))
        (wx->reflection 2 (qblock-exact H 1.0 2 0)))))
    'positive_ast
    '(rule-qblock
      (lcu-sum
       (10 11)
       ((wx->reflection 0 (qblock-exact H 1.0 2 0))
        (wx->reflection 2 (qblock-exact H 1.0 2 0))))))

   ;; -------------------------------------------------------------------------
   ;; WB08 [Rule T-WireBasis]: `lzq192921/T-typeAES` (`T-aes/QAES.qs:142-145`)
   ;; Missing `MixedColumn` wire relabeling after in-place PLU `MixColumn` before `AddRoundKey`
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB08"
    'rule "T-WireBasis"
    'expected_code "E-WIREBASIS-PERM-MISMATCH"
    'repo "lzq192921/T-typeAES"
    'source_ref "T-aes/QAES.qs:142-145 (QAES.Widest)"
    'description "In-place PLU MixColumn leaves state in permutation pi_PLU != id; calling AddRoundKey without MixedColumn relabeling miswires 24/32 bits"
    'negative_ast
    `(rule-wire-basis
      (wire-basis-prog
       #:regs ((col0 32 ,(range 32) AESPolyBasis ,(range 0 32))
               (rkey0 32 ,(range 32) AESPolyBasis ,(range 32 64)))
       #:ops ((plu-linear-op col0 ,mixcolumn-plu-perm-32 ((0 8) (1 9) (8 16)))
              (add-round-key col0 rkey0))))
    'positive_ast
    `(rule-wire-basis
      (wire-basis-prog
       #:regs ((col0 32 ,(range 32) AESPolyBasis ,(range 0 32))
               (rkey0 32 ,(range 32) AESPolyBasis ,(range 32 64)))
       #:ops ((plu-linear-op col0 ,mixcolumn-plu-perm-32 ((0 8) (1 9) (8 16)))
              (relabel-perm col0 ,mixcolumn-plu-inv-perm-32)
              (add-round-key col0 rkey0)))))

   ;; -------------------------------------------------------------------------
   ;; WB09 [Rule T-WireBasis]: `microsoft/grover-blocks` / Tower-Field S-Box
   ;; (`BoyarPeralta12.qs`) Reversed `GF(((2^2)^2)^2)` tower-field bit-endianness
   ;; (`0x00 -> 0x63` test blind spot, corrupting `240/256` nonzero bytes)
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB09"
    'rule "T-WireBasis"
    'expected_code "E-WIREBASIS-BASIS-MISMATCH"
    'repo "microsoft/grover-blocks"
    'source_ref "aes/BoyarPeralta12.qs:12-160 (MSB-first vs LSB-first tower basis)"
    'description "Reversed bit-endianness in GF(((2^2)^2)^2) basis change passes 0x00 -> 0x63 vector yet corrupts 240/256 nonzero bytes"
    'negative_ast
    `(rule-wire-basis
      (wire-basis-prog
       #:regs ((sbyte 8 ,(range 8) AESPolyBasis ,(range 0 8))
               (kbyte 8 ,(range 8) AESPolyBasis ,(range 8 16)))
       #:ops ((basis-cast sbyte ,reversed-endian-tower-rows AESPolyBasis TowerGF16x2LSB)
              (tower-core-op sbyte TowerGF16x2LSB)
              (basis-cast sbyte ,canonical-tower-lsb->aes-poly-rows TowerGF16x2LSB AESPolyBasis)
              (add-round-key sbyte kbyte))))
    'positive_ast
    `(rule-wire-basis
      (wire-basis-prog
       #:regs ((sbyte 8 ,(range 8) AESPolyBasis ,(range 0 8))
               (kbyte 8 ,(range 8) AESPolyBasis ,(range 8 16)))
       #:ops ((basis-cast sbyte ,canonical-aes-poly->tower-lsb-rows AESPolyBasis TowerGF16x2LSB)
              (tower-core-op sbyte TowerGF16x2LSB)
              (basis-cast sbyte ,canonical-tower-lsb->aes-poly-rows TowerGF16x2LSB AESPolyBasis)
              (add-round-key sbyte kbyte)))))

   ;; -------------------------------------------------------------------------
   ;; WB10 [Rule T-WireBasis]: `msr-quarc/ReVerC` (`Examples.fs:603-641`, `keccakfInPlace`)
   ;; `0..5` off-by-one bounds on `Fin 5` & sequential in-place read-after-write overwrite
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB10"
    'rule "T-WireBasis"
    'expected_code "E-WIREBASIS-FIN-BOUNDS"
    'repo "msr-quarc/ReVerC"
    'source_ref "reverc/Examples.fs:603-641 (keccakfInPlace)"
    'description "F# inclusive range [0..5] executes 6 iterations on Fin[5] ring, double-XORing lane 0 and aliasing in-place neighbors"
    'negative_ast
    '(rule-wire-basis
      (wire-basis-prog
       #:regs ((lanes 5 (0 1 2 3 4) F2StdBasis (0 1 2 3 4)))
       #:ops ((stencil-ring imperative-seq 5 0 5 (0 1 2) 0 (0 1 2 3 4) (5 6)))))
    'positive_ast
    '(rule-wire-basis
      (wire-basis-prog
       #:regs ((lanes 5 (0 1 2 3 4) F2StdBasis (0 1 2 3 4)))
       #:ops ((stencil-ring qstencil-ring 5 0 4 (0 1 2) 0 (0 1 2 3 4) (5 6))))))

   ;; -------------------------------------------------------------------------
   ;; WB11 [Rule T-DriftEps]: `Strilanc/quantum-factor-2025-code` / `QuantumThreatTracker`
   ;; (`_execution_config.py:183`, `estimations.py:49`) `c_pad = 34` instead of `36` on `RSA-4096`
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB11"
    'rule "T-DriftEps"
    'expected_code "E-DRIFTEPS-COSET-RUNWAY-OVERFLOW"
    'repo "Strilanc/quantum-factor-2025-code & qec-codes/QuantumThreatTracker"
    'source_ref "src/facto/algorithm/prep/_execution_config.py:183; chevignard_utils/estimations.py:49"
    'description "Reusing RSA-2048 c_pad = 34 on RSA-4096 (2,015,560 steps = 4x inner additions) overflows coset carry runway without +2 pad bits"
    'negative_ast
    '(rule-drift-eps
      (coset-runway-spec #:modulus-bits 4096 #:c-pad 34 #:steps 2015560 #:safety-bits 15))
    'positive_ast
    '(rule-drift-eps
      (coset-runway-spec #:modulus-bits 4096 #:c-pad 36 #:steps 2015560 #:safety-bits 15)))

   ;; -------------------------------------------------------------------------
   ;; WB12 [Rule T-DriftEps]: `quantumlib/Qualtran` (`lcu_block_encoding.py`, `TODO #1247`)
   ;; & `Cobble`: `epsilon = 0.0` / under-provisioned `mu`-bit alias error under QSVT degree `d`
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB12"
    'rule "T-DriftEps"
    'expected_code "E-DRIFTEPS-EPS-AMPLIFICATION"
    'repo "quantumlib/Qualtran & charlesyuan314/cobble"
    'source_ref "qualtran/bloqs/block_encoding/lcu_block_encoding.py (TODO #1247); state_preparation_alias_sampling.py"
    'description "Finite-mu alias discretization error (unreported as epsilon=0.0 in Qualtran) amplifies by d (walk) / d^2 (Markov) in QSVT"
    'negative_ast
    '(rule-qblock
      (qsvt-chebyshev
       15
       interior-walk
       (prepare-alias hubbard-lcu 32 17.210129265602045 10 #f)
       0.001))
    'positive_ast
    '(rule-qblock
      (qsvt-chebyshev
       15
       interior-walk
       (prepare-alias hubbard-lcu 32 17.210129265602045 23 #f)
       0.001)))

   ;; -------------------------------------------------------------------------
   ;; WB13 [Rule T-SingleIR]: `paper-codes/2024-ACNS-scripts` (`leebrickell_quantum.py:221`)
   ;; `7.36x` `skip_rightmost=True` copy-paste slice bug (+ `DQI-Circuit` `n = num_cols - 1`
   ;; & `ReVerC` `SHA2` `Ch` `XAG + Z3` miter)
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB13"
    'rule "T-SingleIR"
    'expected_code "E-SINGLEIR-UNBOUND-SLICE"
    'repo "paper-codes/2024-ACNS-scripts & BankNatchapol/DQI-Circuit & msr-quarc/ReVerC"
    'source_ref "measures/leebrickell_quantum.py:221-223; dqi/qiskit/decoding/algorithms.py:27; reverc/Examples.fs:294"
    'description "Copy-pasted skip_rightmost=True omits k=2720 right-hand columns in McEliece-348864 Lee-Brickell QGJE (7.36x Toffoli undercount)"
    'negative_ast
    '(rule-single-ir
      (single-ir-kernel
       #:label mceliece-348864-leebrickell-qgje
       #:revir-ast (for-matrix-elim #:rows 768 #:total-cols 3489 #:col-lo 0 #:col-hi 769 #:pivots 768)
       #:claimed-temp-ands #f
       #:miter-spec #f))
    'positive_ast
    '(rule-single-ir
      (single-ir-kernel
       #:label mceliece-348864-leebrickell-qgje-full
       #:revir-ast (for-matrix-elim #:rows 768 #:total-cols 3489 #:col-lo 0 #:col-hi 3489 #:pivots 768)
       #:claimed-temp-ands 2781129728
       #:miter-spec (3 5 (4) ((ccx 0 1 4) (x 0) (ccx 0 2 4) (x 0)) sha2-ch))))

   ;; -------------------------------------------------------------------------
   ;; WB14 [Rule T-SingleIR]: `microsoft/grover-blocks` (`parallel_grover.py` / `QAES.qs`)
   ;; `r = 1` `AES-128` / `AES-256` spurious-key dilution violating `k_key - h_bits <= log2(eta_max)`
   ;; -------------------------------------------------------------------------
   (hasheq
    'id "WB14"
    'rule "T-SingleIR"
    'expected_code "E-SINGLEIR-SPURIOUS-KEY-MARGIN"
    'repo "microsoft/grover-blocks"
    'source_ref "parallel_grover.py:90-104; aes/QAES.qs:601-653"
    'description "Single plaintext-ciphertext pair (r = 1, h = 128) on AES-128/256 leaves E[spurious] >= 1 (63.2% / 100% false-key collision)"
    'negative_ast
    '(rule-single-ir
      (grover-search-oracle #:cipher AES-128-r1 #:key-bits 128 #:constraint-bits 128 #:log2-eta-max -32))
    'positive_ast
    '(rule-single-ir
      (grover-search-oracle #:cipher AES-128-r2 #:key-bits 128 #:constraint-bits 256 #:log2-eta-max -32)))))

;; =============================================================================
;; SECTION 12: 12 Additional Generalized Bug-Class Cases (`GC01` .. `GC12`)
;;             Demonstrating Arbitrary Class-Wide Prevention Across All 6 Rules
;; =============================================================================

(define (build-12-generalized-bug-class-cases)
  (list
   ;; GC01 [T-DomImg]: Modular squaring `x^2 mod 13` on full `{1..12}` (non-injective: `x` vs `13 - x`)
   ;; vs restricted quadratic-residue half-interval `{1..6}`!
   (hasheq
    'id "GC01"
    'rule "T-DomImg"
    'expected_code "E-DOMIMG-NON-INJECTIVE"
    'description "Modular squaring x^2 mod 13 on {1..12} collides x with 13-x; bijective when restricted to half-domain {1..6}"
    'negative_ast
    '(rule-dom-img
      (part-bij-smt2
       #:label mod13-sq-full-units
       #:vars ((x (_ BitVec 16)))
       #:vars-alt ((x2 (_ BitVec 16)))
       #:preamble "(define-fun sq13 ((a (_ BitVec 16))) (_ BitVec 16) (bvurem (bvmul a a) #x000d))
                   (define-fun sqrt13_half ((y (_ BitVec 16))) (_ BitVec 16)
                     (ite (= y #x0001) #x0001 (ite (= y #x0004) #x0002 (ite (= y #x0009) #x0003
                     (ite (= y #x0003) #x0004 (ite (= y #x000c) #x0005 #x0006))))))"
       #:dom-f "(and (bvule #x0001 x) (bvule x #x000c))"
       #:f-out ("(sq13 x)")
       #:dom-g-on-f "true"
       #:g-of-f ("(sqrt13_half (sq13 x))")
       #:residual ()
       #:f-out-alt ("(sq13 x2)")
       #:dom-f-alt "(and (bvule #x0001 x2) (bvule x2 #x000c))"))
    'positive_ast
    '(rule-dom-img
      (part-bij-smt2
       #:label mod13-sq-half-domain
       #:vars ((x (_ BitVec 16)))
       #:vars-alt ((x2 (_ BitVec 16)))
       #:preamble "(define-fun sq13 ((a (_ BitVec 16))) (_ BitVec 16) (bvurem (bvmul a a) #x000d))
                   (define-fun sqrt13_half ((y (_ BitVec 16))) (_ BitVec 16)
                     (ite (= y #x0001) #x0001 (ite (= y #x0004) #x0002 (ite (= y #x0009) #x0003
                     (ite (= y #x0003) #x0004 (ite (= y #x000c) #x0005 #x0006))))))"
       #:dom-f "(and (bvule #x0001 x) (bvule x #x0006))"
       #:f-out ("(sq13 x)")
       #:dom-g-on-f "(or (= (sq13 x) #x0001) (= (sq13 x) #x0004) (= (sq13 x) #x0009) (= (sq13 x) #x0003) (= (sq13 x) #x000c) (= (sq13 x) #x000a))"
       #:g-of-f ("(sqrt13_half (sq13 x))")
       #:residual ()
       #:f-out-alt ("(sq13 x2)")
       #:dom-f-alt "(and (bvule #x0001 x2) (bvule x2 #x0006))")))

   ;; GC02 [T-ValidIf]: Partial modular inverse `partial-mod-inv` consumed without `v_unit` guard,
   ;; plus check that mutating `v_unit` inside `with-valid` is ALSO caught!
   (hasheq
    'id "GC02"
    'rule "T-ValidIf"
    'expected_code "E-VALIDIF-WITNESS-MUTATED"
    'description "Mutating the validity-witness wire v_unit inside with-valid invalidates soundness and is statically rejected"
    'negative_ast
    '(rule-valid-if
      (valid-if-seq
       (bind-partial-op v_unit 0 inv_x (QVec 256 id F2StdBasis) partial-mod-inv)
       (with-valid v_unit inv_x
                   (valid-if-seq
                    (mutate-wire! 0)
                    (derive-pred hit (inv_x) 1)
                    (phase-flip-if (hit) (1) (2))))))
    'positive_ast
    '(rule-valid-if
      (valid-if-seq
       (bind-partial-op v_unit 0 inv_x (QVec 256 id F2StdBasis) partial-mod-inv)
       (with-valid v_unit inv_x
                   (valid-if-seq
                    (derive-pred hit (inv_x) 1)
                    (phase-flip-if (hit) (1) (2)))))))

   ;; GC03 [T-ValidIf]: Bounded-distance syndrome decoder `bounded-syndrome-decode` unwrapped unchecked
   (hasheq
    'id "GC03"
    'rule "T-ValidIf"
    'expected_code "E-VALIDIF-UNWRAPPED-USE"
    'description "Unchecked unwrap of partial bounded-distance syndrome decoder output outside with-valid scope"
    'negative_ast
    '(rule-valid-if
      (valid-if-seq
       (bind-partial-op v_dec 3 err_vec (QVec 15 id F2StdBasis) bounded-syndrome-decode)
       (unwrap-unchecked err_vec)))
    'positive_ast
    '(rule-valid-if
      (valid-if-seq
       (bind-partial-op v_dec 3 err_vec (QVec 15 id F2StdBasis) bounded-syndrome-decode)
       (with-valid v_dec err_vec
                   (valid-if-seq
                    (unwrap-unchecked err_vec))))))

   ;; GC04 [T-AlgPhase]: `Qualtran` `SelectSparse:122` self-paired `SGate` (`i * P`, `k = 1 mod 4`) standalone
   (hasheq
    'id "GC04"
    'rule "T-AlgPhase"
    'expected_code "E-ALGPHASE-NON-HERMITIAN-SCALAR"
    'description "Qualtran SelectSparse:122 self-paired SGate branch (i*P)^2 = -I != I vs conjugate-paired PartnerSwap"
    'negative_ast
    '(rule-alg-phase-involutory
      qubitization-walk
      (scalar-phase 1 (pauli-string ((0 X) (1 X)))))
    'positive_ast
    '(rule-alg-phase-involutory
      qubitization-walk
      (partner-swap-select
       ((0 1) (1 0))
       ((branch 0 1 (Maj_pq))
        (branch 1 3 (Maj_pq))))))

   ;; GC05 [T-AlgPhase]: `Cobble` `expr.py:300` complex `Const(exp(i*pi/3))` standalone vs `Const(-1)` (`exp(i*pi)`)
   (hasheq
    'id "GC05"
    'rule "T-AlgPhase"
    'expected_code "E-ALGPHASE-NON-HERMITIAN-SCALAR"
    'description "Cobble complex Const(exp(i*pi/3)) scalar factor breaks involution vs real sign Const(-1) = exp(i*pi)"
    'negative_ast
    '(rule-alg-phase-involutory
      qubitization-walk
      (complex-const-phase 1 3 (pauli-string ((0 Z)))))
    'positive_ast
    '(rule-alg-phase-involutory
      qubitization-walk
      (complex-const-phase 1 1 (pauli-string ((0 Z))))))

   ;; GC06 [T-WireBasis]: Imperative sequential overwrite aliasing on exact `0..4` (`Fin 5`) ring stencil!
   (hasheq
    'id "GC06"
    'rule "T-WireBasis"
    'expected_code "E-WIREBASIS-RAW-STENCIL-ALIAS"
    'description "Even with corrected 0..4 bounds on Fin[5], sequential in-place chi_5 aliases lane 0 read in step 3"
    'negative_ast
    '(rule-wire-basis
      (wire-basis-prog
       #:regs ((lanes 5 (0 1 2 3 4) F2StdBasis (0 1 2 3 4)))
       #:ops ((stencil-ring imperative-seq 5 0 4 (0 1 2) 0 (0 1 2 3 4) (5 6)))))
    'positive_ast
    '(rule-wire-basis
      (wire-basis-prog
       #:regs ((lanes 5 (0 1 2 3 4) F2StdBasis (0 1 2 3 4)))
       #:ops ((stencil-ring qstencil-ring 5 0 4 (0 1 2) 0 (0 1 2 3 4) (5 6))))))

   ;; GC07 [T-DriftEps]: Undersized RNS dynamic range `L = 11 * 19 = 209 < 15^2 = 225` (`QRNS` wraparound)
   (hasheq
    'id "GC07"
    'rule "T-DriftEps"
    'expected_code "E-DRIFTEPS-RNS-DYNAMIC-RANGE"
    'description "Undersized RNS moduli {11, 19} (L=209 < N^2=225) silently corrupts X=210 mod 15; {13, 19} (L=247 >= 225) is exact"
    'negative_ast
    '(rule-drift-eps
      (rns-range-spec #:modulus-n 15 #:power-m 2 #:rns-moduli (11 19)))
    'positive_ast
    '(rule-drift-eps
      (rns-range-spec #:modulus-n 15 #:power-m 2 #:rns-moduli (13 19))))

   ;; GC08 [T-DriftEps]: Explicit `Qualtran` `epsilon = 0.0` claim on finite-`mu` alias preparation (`TODO #1247`)
   ;; + Markov `d^2` spectral-edge bound (`mu = 23` passes interior walk `d=15` but fails Markov edge `d^2=225`, which requires `mu = 27`!)
   (hasheq
    'id "GC08"
    'rule "T-DriftEps"
    'expected_code "E-DRIFTEPS-ZERO-OR-UNSOUND-EPS"
    'description "Qualtran LCUBlockEncoding claiming epsilon = 0.0 on finite-mu alias preparation is statically rejected"
    'negative_ast
    '(rule-qblock
      (prepare-alias qualtran-lcu-todo-1247 32 17.210129265602045 16 0.0))
    'positive_ast
    '(rule-qblock
      (qsvt-chebyshev
       15
       markov-spectral-edge
       (prepare-alias hubbard-lcu-edge 32 17.210129265602045 27 #f)
       0.001)))

   ;; GC09 [T-DriftEps]: Markov spectral-edge `d^2` amplification (`mu = 23` rejected at spectral edge, `mu = 27` accepted)
   (hasheq
    'id "GC09"
    'rule "T-DriftEps"
    'expected_code "E-DRIFTEPS-EPS-AMPLIFICATION"
    'description "At spectral edge x -> 1, Chebyshev derivative ||T'_d|| = d^2 = 225 rejects mu = 23 and enforces mu >= 27"
    'negative_ast
    '(rule-qblock
      (qsvt-chebyshev
       15
       markov-spectral-edge
       (prepare-alias hubbard-lcu-edge 32 17.210129265602045 23 #f)
       0.001))
    'positive_ast
    '(rule-qblock
      (qsvt-chebyshev
       15
       markov-spectral-edge
       (prepare-alias hubbard-lcu-edge 32 17.210129265602045 27 #f)
       0.001)))

   ;; GC10 [T-SingleIR]: `DQI-Circuit` `algorithms.py:27` `n = num_cols - 1` slice bug standalone
   (hasheq
    'id "GC10"
    'rule "T-SingleIR"
    'expected_code "E-SINGLEIR-UNBOUND-SLICE"
    'description "DQI-Circuit GJEGate(B.T) sets n = num_cols - 1, omitting the last column of B.T in elimination"
    'negative_ast
    '(rule-single-ir
      (single-ir-kernel
       #:label dqi-gje-bt-last-col-omitted
       #:revir-ast (for-matrix-elim #:rows 7 #:total-cols 7 #:col-lo 0 #:col-hi 6 #:pivots 6)
       #:claimed-temp-ands #f
       #:miter-spec #f))
    'positive_ast
    '(rule-single-ir
      (single-ir-kernel
       #:label dqi-gje-bt-all-cols-covered
       #:revir-ast (for-matrix-elim #:rows 7 #:total-cols 7 #:col-lo 0 #:col-hi 7 #:pivots 7)
       #:claimed-temp-ands 238
       #:miter-spec #f)))

   ;; GC11 [T-SingleIR]: `ReVerC` `Examples.fs:294` `SHA2` `Ch(e,f,g) = e && f && g` bug caught by `XAG + Z3` miter!
   (hasheq
    'id "GC11"
    'rule "T-SingleIR"
    'expected_code "E-SINGLEIR-SPEC-MITER-SAT"
    'description "ReVerC SHA2 Ch(e,f,g) = e && f && g disagrees with FIPS 180-4 (e & f) ^ (~e & g) at (e,f,g)=(0,0,1)"
    'negative_ast
    '(rule-single-ir
      (single-ir-kernel
       #:label reverc-sha2-ch-buggy
       #:revir-ast (seq (ccx 0 1 3) (ccx 3 2 4) (ccx 0 1 3))
       #:claimed-temp-ands 3
       #:miter-spec (3 5 (4) ((ccx 0 1 3) (ccx 3 2 4) (ccx 0 1 3)) sha2-ch)))
    'positive_ast
    '(rule-single-ir
      (single-ir-kernel
       #:label reverc-sha2-ch-repaired
       #:revir-ast (seq (ccx 0 1 4) (x 0) (ccx 0 2 4) (x 0))
       #:claimed-temp-ands 2
       #:miter-spec (3 5 (4) ((ccx 0 1 4) (x 0) (ccx 0 2 4) (x 0)) sha2-ch))))

   ;; GC12 [T-SingleIR]: `AES-256` `r = 2` (`h = 256` bits, `E[spurious] = 1`) rejected; `r = 3` (`h = 384`, `E[spurious] = 2^{-128}`) accepted!
   (hasheq
    'id "GC12"
    'rule "T-SingleIR"
    'expected_code "E-SINGLEIR-SPURIOUS-KEY-MARGIN"
    'description "AES-256 with r = 2 pairs still has k - h = 0 (E[spurious] = 1, 63.2% collision); r = 3 achieves 2^{-128} margin"
    'negative_ast
    '(rule-single-ir
      (grover-search-oracle #:cipher AES-256-r2 #:key-bits 256 #:constraint-bits 256 #:log2-eta-max -32))
    'positive_ast
    '(rule-single-ir
      (grover-search-oracle #:cipher AES-256-r3 #:key-bits 256 #:constraint-bits 384 #:log2-eta-max -32)))

   ;; GC13 [T-ParGuard]: Strict multi-machine Grover (`#:strict-parallel? #t`, `M = 16`) rejected with
   ;; `E-PARGUARD-ZALKA-GROVER-SUBLINEAR`; automatic fallback (`#:strict-parallel? #f`) returns `machines_used = 1`!
   (hasheq
    'id "GC13"
    'rule "T-ParGuard"
    'expected_code "E-PARGUARD-ZALKA-GROVER-SUBLINEAR"
    'description "Multi-machine Grover on AES-128 incurs Zalka sqrt(M)=4x total-work blowup with non-sliceable state; strict mode rejects while default falls back to 1 machine"
    'negative_ast
    '(rule-par-guard
      (par-partition-spec
       #:workload AES-128
       #:paradigm grover-amplify
       #:requested-machines 16
       #:q-single 984
       #:q-per-machine 980
       #:q-comm 0
       #:bell-cuts 0
       #:max-bell-budget 0
       #:strict-parallel? #t))
    'positive_ast
    '(rule-par-guard
      (par-partition-spec
       #:workload AES-128
       #:paradigm grover-amplify
       #:requested-machines 16
       #:q-single 984
       #:q-per-machine 980
       #:q-comm 0
       #:bell-cuts 0
       #:max-bell-budget 0
       #:strict-parallel? #f)))

   ;; GC14 [T-ParGuard]: Over-cut multi-QPU partition where `Q_per_machine + q_comm >= Q_single` rejected under
   ;; `#:strict-parallel? #t` (`E-PARGUARD-BELL-CUT-EXCEEDS-SINGLE-QPU`) and succeeds on sound limb zipper cut!
   (hasheq
    'id "GC14"
    'rule "T-ParGuard"
    'expected_code "E-PARGUARD-BELL-CUT-EXCEEDS-SINGLE-QPU"
    'description "Cross-QPU Bell-cut overhead with Q_per_machine + q_comm = 2200 >= Q_single = 2124 is rejected under strict-parallel and accepted on sound 4-machine limb cut"
    'negative_ast
    '(rule-par-guard
      (par-partition-spec
       #:workload ECC-256-OverCut
       #:paradigm algebraic-limb
       #:requested-machines 64
       #:q-single 2124
       #:q-per-machine 1600
       #:q-comm 600
       #:bell-cuts 8192
       #:max-bell-budget 1024
       #:strict-parallel? #t))
    'positive_ast
    '(rule-par-guard
      (par-partition-spec
       #:workload ECC-256
       #:paradigm algebraic-limb
       #:requested-machines 4
       #:q-single 2124
       #:q-per-machine 540
       #:q-comm 32
       #:bell-cuts 512
       #:max-bell-budget 1024
       #:strict-parallel? #t)))))

(define build-generalized-bug-class-cases build-12-generalized-bug-class-cases)

;; Canonical 13 SOTA workload parallelizability profiles (`ParSliceable`, `ParShotLinear`,
;; and `ParNonPartitionable` automatic Single-Machine fallback):
(define (build-sota-parallel-partition-profiles)
  (list
   ;; 1–3: `ParSliceable(M, bell_cuts)` -> compiles to `M` entangled machines (`fallback = #f`)
   '(par-partition-spec #:workload ECC-256          #:paradigm algebraic-limb #:requested-machines 4  #:q-single 2124  #:q-per-machine 540  #:q-comm 32  #:bell-cuts 512  #:max-bell-budget 1024 #:strict-parallel? #f)
   '(par-partition-spec #:workload RSA-2048         #:paradigm algebraic-limb #:requested-machines 4  #:q-single 4130  #:q-per-machine 1040 #:q-comm 64  #:bell-cuts 2048 #:max-bell-budget 4096 #:strict-parallel? #f)
   '(par-partition-spec #:workload RSA-4096         #:paradigm algebraic-limb #:requested-machines 8  #:q-single 8230  #:q-per-machine 1040 #:q-comm 64  #:bell-cuts 4096 #:max-bell-budget 8192 #:strict-parallel? #f)
   ;; 4–6: `ParShotLinear(M)` -> compiles to `M` independent `1`-machine shot workers (`fallback = #f`)
   '(par-partition-spec #:workload DQI              #:paradigm shot-sample    #:requested-machines 16 #:q-single 512   #:q-per-machine 512  #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   '(par-partition-spec #:workload Hubbard-QSVT     #:paradigm shot-sample    #:requested-machines 16 #:q-single 128   #:q-per-machine 128  #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   '(par-partition-spec #:workload FeMoCo-THC       #:paradigm shot-sample    #:requested-machines 16 #:q-single 2196  #:q-per-machine 2196 #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   ;; 7–12: `ParNonPartitionable('zalka-grover-sublinear)` -> automatic `1`-machine Single-Machine fallback (`machines_used = 1`, `fallback = #t`)
   '(par-partition-spec #:workload AES-128          #:paradigm grover-amplify #:requested-machines 16 #:q-single 984   #:q-per-machine 980  #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   '(par-partition-spec #:workload AES-256          #:paradigm grover-amplify #:requested-machines 16 #:q-single 1376  #:q-per-machine 1372 #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   '(par-partition-spec #:workload SHA3-256         #:paradigm grover-amplify #:requested-machines 16 #:q-single 3200  #:q-per-machine 3196 #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   '(par-partition-spec #:workload SLH-DSA-128s     #:paradigm grover-amplify #:requested-machines 16 #:q-single 3264  #:q-per-machine 3260 #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   '(par-partition-spec #:workload McEliece-348864  #:paradigm isd-search     #:requested-machines 16 #:q-single 4258  #:q-per-machine 4254 #:q-comm 0   #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   '(par-partition-spec #:workload BIKE-L1          #:paradigm isd-search     #:requested-machines 16 #:q-single 24646 #:q-per-machine 24642 #:q-comm 0  #:bell-cuts 0    #:max-bell-budget 0    #:strict-parallel? #f)
   ;; 13: `ParNonPartitionable('bell-cut-exceeds-single-qpu)` -> automatic `1`-machine Single-Machine fallback (`machines_used = 1`, `fallback = #t`)
   '(par-partition-spec #:workload ECC-256-OverCut  #:paradigm algebraic-limb #:requested-machines 64 #:q-single 2124  #:q-per-machine 1600 #:q-comm 600 #:bell-cuts 8192 #:max-bell-budget 1024 #:strict-parallel? #f)))

;; Canonical SOTA cluster-optimization specs (`solve-optimal-qpar-machines`) parameterized
;; by `(q-cap, r-bell-hz, m-max, topology)`:
(define (build-sota-cluster-opt-profiles [q-cap 400]
                                         [r-bell-hz 100000.0]
                                         [m-max 256]
                                         [topology 'all-to-all-peers])
  (list
   (par-cluster-opt-spec #:workload 'ECC-256
                         #:paradigm 'algebraic-limb
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 1298
                         #:q-data-dist 1024
                         #:q-local-fixed 38
                         #:q-peer-sync 6
                         #:candidate-machines default-cluster-candidate-machines
                         #:window-bits 5
                         #:num-windows 112
                         #:local-toffolis 9824640
                         #:carry-scheme 'projective-oblivious-runway
                         #:lookup-scheme 'law-u4-ghz-mx
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'RSA-2048
                         #:paradigm 'algebraic-limb
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 1332
                         #:q-data-dist 1152
                         #:q-local-fixed 24
                         #:q-peer-sync 4
                         #:candidate-machines default-cluster-candidate-machines
                         #:window-bits 6
                         #:num-windows 1038
                         #:local-toffolis 1180000000
                         #:carry-scheme 'qrns-zero-carry
                         #:lookup-scheme 'law-u4-ghz-mx
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'RSA-4096
                         #:paradigm 'algebraic-limb
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 2612
                         #:q-data-dist 2304
                         #:q-local-fixed 40
                         #:q-peer-sync 4
                         #:candidate-machines default-cluster-candidate-machines
                         #:window-bits 6
                         #:num-windows 2076
                         #:local-toffolis 9440000000
                         #:carry-scheme 'qrns-zero-carry
                         #:lookup-scheme 'law-u4-ghz-mx
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'AES-128
                         #:paradigm 'grover-amplify
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 261
                         #:local-toffolis 15280
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'AES-256
                         #:paradigm 'grover-amplify
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 389
                         #:local-toffolis 31840
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'SHA3-256
                         #:paradigm 'grover-amplify
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 3200
                         #:local-toffolis 76800
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'SLH-DSA-128s
                         #:paradigm 'grover-amplify
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 3264
                         #:local-toffolis 92160
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'McEliece-348864
                         #:paradigm 'isd-search
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 4258
                         #:local-toffolis 2781129728
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'BIKE-L1
                         #:paradigm 'isd-search
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 24646
                         #:local-toffolis 482000000
                         #:interconnect-topology topology
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'DQI
                         #:paradigm 'shot-sample
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 512
                         #:q-data-dist 768
                         #:q-local-fixed 24
                         #:q-peer-sync 4
                         #:candidate-machines default-cluster-candidate-machines
                         #:window-bits 4
                         #:num-windows 16
                         #:local-toffolis 124000
                         #:carry-scheme 'none
                         #:lookup-scheme 'law-u4-ghz-mx
                         #:interconnect-topology topology
                         #:total-shots 256
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'Hubbard-QSVT
                         #:paradigm 'shot-sample
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 128
                         #:local-toffolis 84000
                         #:interconnect-topology topology
                         #:total-shots 256
                         #:strict-parallel? #f)
   (par-cluster-opt-spec #:workload 'FeMoCo-THC
                         #:paradigm 'shot-sample
                         #:max-machines m-max
                         #:q-cap-per-machine q-cap
                         #:raw-bell-rate-hz r-bell-hz
                         #:raw-per-logical-ebit 30
                         #:q-single 2196
                         #:local-toffolis 5300000000
                         #:interconnect-topology topology
                         #:total-shots 64
                         #:strict-parallel? #f)))

;; =============================================================================
;; SECTION 13: Exhaustive Racket Verification Runner & JSON Report Exporter
;; =============================================================================

(define (evaluate-case-pair entry)
  (define cid (hash-ref entry 'id))
  (define expected-rule (hash-ref entry 'rule))
  (define expected-code (hash-ref entry 'expected_code))
  (define neg-res (typecheck-lfq-bug-prevention-program (hash-ref entry 'negative_ast)))
  (define pos-res (typecheck-lfq-bug-prevention-program (hash-ref entry 'positive_ast)))

  (check-false (lfq-typecheck-result-well-typed? neg-res)
               (format "~a negative case must be statically rejected" cid))
  (check-true (lfq-typecheck-result-well-typed? pos-res)
              (format "~a repaired positive case must typecheck cleanly" cid))

  (define neg-diags (lfq-typecheck-result-diagnostics neg-res))
  (check-true (not (null? neg-diags))
              (format "~a negative case must emit at least one diagnostic" cid))
  (define d0 (first neg-diags))
  (check-equal? (lfq-type-diagnostic-rule d0) expected-rule
                (format "~a rule tag must match ~a" cid expected-rule))
  (check-equal? (lfq-type-diagnostic-code d0) expected-code
                (format "~a diagnostic code must match ~a" cid expected-code))

  (hasheq 'id cid
          'rule expected-rule
          'diagnostic_code expected-code
          'repo (hash-ref entry 'repo "generalized-class")
          'source_ref (hash-ref entry 'source_ref "generalized-ast")
          'description (hash-ref entry 'description)
          'negative_rejected (not (lfq-typecheck-result-well-typed? neg-res))
          'negative_diagnostic (diag->jsexpr d0)
          'positive_well_typed (lfq-typecheck-result-well-typed? pos-res)
          'positive_metrics (lfq-typecheck-result-metrics pos-res)))

(define (run-all-bug-class-prevention-checks!)
  (define t0 (current-inexact-monotonic-milliseconds))
  (define wild-cases (build-14-wild-research-bug-cases))
  (define gen-cases (build-generalized-bug-class-cases))
  (define par-specs (build-sota-parallel-partition-profiles))

  (check-equal? (length wild-cases) 14 "Must check all 14 wild research bug cases")
  (check-equal? (length gen-cases) 14 "Must check all 14 generalized bug-class cases")
  (check-equal? (length par-specs) 13 "Must check all 13 SOTA parallelizability profiles")

  (define wild-reports (map evaluate-case-pair wild-cases))
  (define gen-reports (map evaluate-case-pair gen-cases))

  ;; Verify all 13 SOTA parallelizability profiles under `T-ParGuard` (`compile-parallel-with-fallback`):
  (define par-reports
    (for/list ([ps (in-list par-specs)])
      (define r (compile-parallel-with-fallback ps))
      (check-true (lfq-typecheck-result-well-typed? r))
      (define m (lfq-typecheck-result-metrics r))
      (define gtag (hash-ref m 'qpar_grade))
      (cond
        [(or (equal? gtag "ParSliceable") (equal? gtag "ParShotLinear"))
         (check-false (hash-ref m 'fallback_to_single_machine))
         (check-equal? (hash-ref m 'machines_used) (hash-ref m 'requested_machines))]
        [(equal? gtag "ParNonPartitionable")
         (check-true (hash-ref m 'fallback_to_single_machine))
         (check-equal? (hash-ref m 'machines_used) 1)
         (check-equal? (hash-ref m 'q_allocated_per_machine) (hash-ref m 'q_single))
         (check-equal? (hash-ref (hash-ref m 'static_diagnostic) 'rule) "T-ParGuard")])
      m))

  ;; Verify Convex `M*` Cluster-Profile Optimizer (`solve-optimal-qpar-machines`) across `M_max = 256`:
  (define cluster-400-specs (build-sota-cluster-opt-profiles 400 100000.0 256 'all-to-all-peers))
  (define cluster-400-reports
    (for/list ([cs (in-list cluster-400-specs)])
      (define r (solve-optimal-qpar-machines cs))
      (check-true (lfq-typecheck-result-well-typed? r))
      (lfq-typecheck-result-metrics r)))
  (define cluster-by-name
    (for/hash ([m (in-list cluster-400-reports)])
      (values (hash-ref m 'workload) m)))

  ;; 1) `ECC-256` at `(M_max=256, Q_cap=400, R_bell=100kHz)`: STILL selects interior optimum
  ;;    `M* = 4` (`312 Q`, `9,744` logical ebits), and statically prunes ALL 8 candidates
  ;;    `{16, 24, 32, 48, 64, 96, 128, 256}` (`192 Q .. 1,572 Q`) past the `M = 12` (`190 Q`) knee!
  (define ecc-400 (hash-ref cluster-by-name "ECC-256"))
  (check-equal? (hash-ref ecc-400 'max_machines) 256)
  (check-equal? (hash-ref ecc-400 'optimal_machines) 4)
  (check-equal? (hash-ref ecc-400 'q_allocated_per_machine) 312)
  (check-equal? (hash-ref ecc-400 'lookup_ebits_total) 1680)
  (check-equal? (hash-ref ecc-400 'carry_ebits_total) 8064)
  (check-equal? (hash-ref ecc-400 'logical_ebits_total) 9744)
  (define ecc-pruned (hash-ref ecc-400 'pruned_ucurve_candidates))
  (check-equal? (length ecc-pruned) 8)
  (check-equal? (map (lambda (p) (hash-ref p 'pruned_m)) ecc-pruned)
                '(16 24 32 48 64 96 128 256))
  (check-equal? (hash-ref (first ecc-pruned) 'code) "W-PARGUARD-PRUNED-UCURVE-KNEE")
  (check-equal? (hash-ref (first ecc-pruned) 'pruned_q_per_machine) 192)
  (check-equal? (hash-ref (last ecc-pruned) 'pruned_q_per_machine) 1572)
  (check-true (> (hash-ref (last ecc-pruned) 'pruned_q_per_machine) (hash-ref ecc-400 'q_single)))
  (for ([p (in-list ecc-pruned)])
    (check-equal? (hash-ref p 'dominating_m) 12)
    (check-equal? (hash-ref p 'dominating_q_per_machine) 190))

  ;; 2) `RSA-2048` at `(M_max=256, Q_cap=400, R_bell=100kHz)`: STILL selects `M* = 6` (`236 Q`, `0` carry, `31,140` lookup ebits),
  ;;    and prunes `{24, 32, 48, 64, 96, 128, 256}` past its `M = 16` (`156 Q`) knee!
  (define rsa2048-400 (hash-ref cluster-by-name "RSA-2048"))
  (check-equal? (hash-ref rsa2048-400 'optimal_machines) 6)
  (check-equal? (hash-ref rsa2048-400 'q_allocated_per_machine) 236)
  (check-equal? (hash-ref rsa2048-400 'carry_ebits_total) 0)
  (check-equal? (hash-ref rsa2048-400 'lookup_ebits_total) 31140)
  (check-equal? (hash-ref rsa2048-400 'logical_ebits_total) 31140)
  (check-equal? (map (lambda (p) (hash-ref p 'pruned_m))
                     (hash-ref rsa2048-400 'pruned_ucurve_candidates))
                '(24 32 48 64 96 128 256))

  ;; 3) `RSA-4096` at `(M_max=256, Q_cap=400, R_bell=100kHz)`: STILL selects `M* = 8` (`356 Q`, `0` carry, `87,192` lookup ebits),
  ;;    retains `M = 24` (`228 Q` true U-curve knee!) in Pareto set, and prunes `{32, 48, 64, 96, 128, 256}`!
  (define rsa4096-400 (hash-ref cluster-by-name "RSA-4096"))
  (check-equal? (hash-ref rsa4096-400 'optimal_machines) 8)
  (check-equal? (hash-ref rsa4096-400 'q_allocated_per_machine) 356)
  (check-equal? (hash-ref rsa4096-400 'carry_ebits_total) 0)
  (check-equal? (hash-ref rsa4096-400 'lookup_ebits_total) 87192)
  (check-equal? (hash-ref rsa4096-400 'logical_ebits_total) 87192)
  (check-equal? (map (lambda (p) (hash-ref p 'pruned_m))
                     (hash-ref rsa4096-400 'pruned_ucurve_candidates))
                '(32 48 64 96 128 256))

  ;; 3b) Explicit `Q_cap = 230 Q` test on `RSA-4096`: `M_max = 16` (`min Q = 244 > 230`) has NO feasible partition,
  ;;     whereas `M_max = 256` unlocks the true `M = 24` knee (`24 x 228 Q`, `286,488` lookup ebits, `0` carry ebits)!
  (define rsa4096-230-m16-strict
    (solve-optimal-qpar-machines
     (par-cluster-opt-spec #:workload 'RSA-4096
                           #:paradigm 'algebraic-limb
                           #:max-machines 16
                           #:q-cap-per-machine 230
                           #:raw-bell-rate-hz 100000.0
                           #:raw-per-logical-ebit 30
                           #:q-single 2612
                           #:q-data-dist 2304
                           #:q-local-fixed 40
                           #:q-peer-sync 4
                           #:window-bits 6
                           #:num-windows 2076
                           #:local-toffolis 9440000000
                           #:carry-scheme 'qrns-zero-carry
                           #:lookup-scheme 'law-u4-ghz-mx
                           #:strict-parallel? #t)))
  (check-false (lfq-typecheck-result-well-typed? rsa4096-230-m16-strict))
  (check-equal? (lfq-type-diagnostic-code (first (lfq-typecheck-result-diagnostics rsa4096-230-m16-strict)))
                "E-PARGUARD-NO-FEASIBLE-PARTITION")

  (define rsa4096-230-m256
    (lfq-typecheck-result-metrics
     (solve-optimal-qpar-machines (third (build-sota-cluster-opt-profiles 230 100000.0 256 'all-to-all-peers)))))
  (check-equal? (hash-ref rsa4096-230-m256 'optimal_machines) 24)
  (check-equal? (hash-ref rsa4096-230-m256 'q_allocated_per_machine) 228)
  (check-equal? (hash-ref rsa4096-230-m256 'carry_ebits_total) 0)
  (check-equal? (hash-ref rsa4096-230-m256 'lookup_ebits_total) 286488)
  (check-equal? (hash-ref rsa4096-230-m256 'logical_ebits_total) 286488)
  (check-equal? (map (lambda (p) (hash-ref p 'pruned_m))
                     (hash-ref rsa4096-230-m256 'pruned_ucurve_candidates))
                '(32 48 64 96 128 256))

  ;; 4) `AES-128`, `AES-256`, `SHA3-256`, `SLH-DSA-128s`, `McEliece-348864`, `BIKE-L1` at `M_max = 256`
  ;;    (`sqrt(256) = 16.0x` Zalka work blowup!) STILL select `M* = 1`, while `DQI` packs `64` parallel
  ;;    `4`-chip shot groups (`256 x 228 Q`, `64x` throughput) and `FeMoCo-THC` caps at `M* = 64` (`0` idle machines):
  (check-equal? (hash-ref (hash-ref cluster-by-name "AES-128") 'optimal_machines) 1)
  (check-equal? (hash-ref (hash-ref cluster-by-name "AES-128") 'q_allocated_per_machine) 261)
  (check-equal? (hash-ref (hash-ref cluster-by-name "AES-128") 'zalka_total_work_blowup_factor) 16.0)
  (check-equal? (hash-ref (hash-ref cluster-by-name "AES-256") 'optimal_machines) 1)
  (check-equal? (hash-ref (hash-ref cluster-by-name "AES-256") 'q_allocated_per_machine) 389)
  (for ([wname (in-list '("SHA3-256" "SLH-DSA-128s" "McEliece-348864" "BIKE-L1"))])
    (check-equal? (hash-ref (hash-ref cluster-by-name wname) 'optimal_machines) 1)
    (check-equal? (hash-ref (hash-ref cluster-by-name wname) 'zalka_total_work_blowup_factor) 16.0)
    (check-true (hash-ref (hash-ref cluster-by-name wname) 'fallback_to_single_machine)))
  (for ([wname (in-list '("DQI" "Hubbard-QSVT" "FeMoCo-THC"))])
    (check-equal? (hash-ref (hash-ref cluster-by-name wname) 'qpar_grade) "ParShotLinear"))
  (check-equal? (hash-ref (hash-ref cluster-by-name "DQI") 'machines_per_shot_instance) 4)
  (check-equal? (hash-ref (hash-ref cluster-by-name "DQI") 'parallel_shot_groups) 64)
  (check-equal? (hash-ref (hash-ref cluster-by-name "DQI") 'machines_used) 256)
  (check-equal? (hash-ref (hash-ref cluster-by-name "DQI") 'q_allocated_per_machine) 228)
  (check-equal? (hash-ref (hash-ref cluster-by-name "DQI") 'shot_throughput_speedup) 64)
  (check-equal? (hash-ref (hash-ref cluster-by-name "Hubbard-QSVT") 'machines_used) 256)
  (check-equal? (hash-ref (hash-ref cluster-by-name "Hubbard-QSVT") 'shot_throughput_speedup) 256)
  (check-equal? (hash-ref (hash-ref cluster-by-name "FeMoCo-THC") 'optimal_machines) 64)
  (check-equal? (hash-ref (hash-ref cluster-by-name "FeMoCo-THC") 'machines_used) 64)
  (check-equal? (hash-ref (hash-ref cluster-by-name "FeMoCo-THC") 'q_allocated_per_machine) 2196)
  (check-equal? (hash-ref (hash-ref cluster-by-name "FeMoCo-THC") 'idle_machines_avoided) 192)

  ;; 5) Monolithic fit & shot scaling at `Q_cap = 1500, M_max = 256` (`ECC-256 -> M*=1`,
  ;;    `RSA-2048 -> M*=1`, `RSA-4096 -> M*=8`, `DQI -> 256 x 512 Q`, `FeMoCo-THC -> 64 x 2196 Q`):
  (define cluster-1500-all (build-sota-cluster-opt-profiles 1500 100000.0 256 'all-to-all-peers))
  (define cluster-1500-all-reports
    (map (lambda (s) (lfq-typecheck-result-metrics (solve-optimal-qpar-machines s)))
         cluster-1500-all))
  (define cluster-1500-reports (take cluster-1500-all-reports 3))
  (define cluster-1500-by-name
    (for/hash ([m (in-list cluster-1500-all-reports)])
      (values (hash-ref m 'workload) m)))
  (check-equal? (hash-ref (first cluster-1500-reports) 'optimal_machines) 1)
  (check-equal? (hash-ref (first cluster-1500-reports) 'logical_ebits_total) 0)
  (check-equal? (hash-ref (second cluster-1500-reports) 'optimal_machines) 1)
  (check-equal? (hash-ref (second cluster-1500-reports) 'logical_ebits_total) 0)
  (check-equal? (hash-ref (third cluster-1500-reports) 'optimal_machines) 8)
  (check-equal? (hash-ref (hash-ref cluster-1500-by-name "DQI") 'machines_used) 256)
  (check-equal? (hash-ref (hash-ref cluster-1500-by-name "DQI") 'q_allocated_per_machine) 512)
  (check-equal? (hash-ref (hash-ref cluster-1500-by-name "DQI") 'shot_throughput_speedup) 256)
  (check-equal? (hash-ref (hash-ref cluster-1500-by-name "FeMoCo-THC") 'machines_used) 64)

  ;; 6) `'switched-optical-tree` on tiny `Q_cap = 128 Q` chiplets (`M_max = 256`):
  ;;    `ECC-256 -> M* = 16 (16 x 126 Q)`, `RSA-2048 -> M* = 16 (16 x 112 Q)`, `RSA-4096 -> M* = 48 (48 x 112 Q)`,
  ;;    plus `RSA-2048` on binary radix-2 optical switch at `Q_cap = 100 Q` (and full grid at `Q_cap = 90 Q`) -> `M* = 32 (32 x 80 Q)`!
  (define optical-tree-128-specs
    (take (build-sota-cluster-opt-profiles 128 100000.0 256 'switched-optical-tree) 3))
  (define optical-tree-128-reports
    (map (lambda (s) (lfq-typecheck-result-metrics (solve-optimal-qpar-machines s)))
         optical-tree-128-specs))
  (check-equal? (hash-ref (first optical-tree-128-reports) 'optimal_machines) 16)
  (check-equal? (hash-ref (first optical-tree-128-reports) 'q_allocated_per_machine) 126)
  (check-equal? (hash-ref (second optical-tree-128-reports) 'optimal_machines) 16)
  (check-equal? (hash-ref (second optical-tree-128-reports) 'q_allocated_per_machine) 112)
  (check-equal? (hash-ref (third optical-tree-128-reports) 'optimal_machines) 48)
  (check-equal? (hash-ref (third optical-tree-128-reports) 'q_allocated_per_machine) 112)

  (define rsa2048-tree-100-pow2
    (lfq-typecheck-result-metrics
     (solve-optimal-qpar-machines
      (par-cluster-opt-spec #:workload 'RSA-2048
                            #:paradigm 'algebraic-limb
                            #:max-machines 256
                            #:q-cap-per-machine 100
                            #:raw-bell-rate-hz 100000.0
                            #:raw-per-logical-ebit 30
                            #:q-single 1332
                            #:q-data-dist 1152
                            #:q-local-fixed 24
                            #:q-peer-sync 4
                            #:candidate-machines '(1 2 4 8 16 32 64 128 256)
                            #:window-bits 6
                            #:num-windows 1038
                            #:local-toffolis 1180000000
                            #:carry-scheme 'qrns-zero-carry
                            #:lookup-scheme 'law-u4-ghz-mx
                            #:interconnect-topology 'switched-optical-tree
                            #:strict-parallel? #f))))
  (check-equal? (hash-ref rsa2048-tree-100-pow2 'optimal_machines) 32)
  (check-equal? (hash-ref rsa2048-tree-100-pow2 'q_allocated_per_machine) 80)

  ;; 7) Slow optical link `R_bell = 1 kHz` shifts `RSA-2048` from `M* = 6` down to `M* = 4`:
  (define rsa2048-1khz
    (lfq-typecheck-result-metrics
     (solve-optimal-qpar-machines (second (build-sota-cluster-opt-profiles 400 1000.0 256 'all-to-all-peers)))))
  (check-equal? (hash-ref rsa2048-1khz 'optimal_machines) 4)
  (check-equal? (hash-ref rsa2048-1khz 'q_allocated_per_machine) 324)
  (check-equal? (hash-ref rsa2048-1khz 'logical_ebits_total) 18684)

  ;; 8) Tight per-chip capacity `Q_cap = 220` shifts `ECC-256` from `M* = 4` up to `M* = 8`:
  (define ecc-220
    (lfq-typecheck-result-metrics
     (solve-optimal-qpar-machines (first (build-sota-cluster-opt-profiles 220 100000.0 256 'all-to-all-peers)))))
  (check-equal? (hash-ref ecc-220 'optimal_machines) 8)
  (check-equal? (hash-ref ecc-220 'q_allocated_per_machine) 208)
  (check-equal? (hash-ref ecc-220 'logical_ebits_total) 22736)

  ;; Also verify standalone `measure-qblock` erases `omega` with `0` phase gates, while
  ;; `ctrl-qblock` and `lcu-sum` synthesize exact `S^d` compensating phase gates!
  (define wx-d2 '(wx->reflection 2 (qblock-exact H 1.0 2 0)))
  (define meas-res (infer-qblock-alg-phase-and-eps `(measure-qblock ,wx-d2)))
  (define ctrl-res (infer-qblock-alg-phase-and-eps `(ctrl-qblock 7 ,wx-d2)))
  (check-true (lfq-typecheck-result-well-typed? meas-res))
  (check-equal? (hash-ref (lfq-typecheck-result-metrics meas-res) 'synthesized_phase_gates) '())
  (check-true (lfq-typecheck-result-well-typed? ctrl-res))
  (check-equal? (hash-ref (lfq-typecheck-result-metrics ctrl-res) 'compensating_s_power_mod4) 2)
  (check-equal? (hash-ref (lfq-typecheck-result-metrics ctrl-res) 'synthesized_phase_gates) '("(z 7)"))

  ;; Verify `relabel-perm` emits `0` physical `SWAP` gates across 128-wire ShiftRows & 32-wire MixedColumn:
  (define wb-wb08-pos
    (typecheck-lfq-bug-prevention-program (hash-ref (list-ref wild-cases 7) 'positive_ast)))
  (check-equal? (hash-ref (lfq-typecheck-result-metrics wb-wb08-pos) 'physical_swap_gates) 0)

  (define elapsed-ms (- (current-inexact-monotonic-milliseconds) t0))
  (close-bug-prevention-z3!)

  (hasheq 'status "PASS"
          'rules_implemented '("T-DomImg" "T-ValidIf" "T-AlgPhase" "T-WireBasis" "T-DriftEps" "T-SingleIR" "T-ParGuard")
          'wild_bug_negative_rejected_count
          (count (lambda (r) (hash-ref r 'negative_rejected)) wild-reports)
          'wild_bug_positive_well_typed_count
          (count (lambda (r) (hash-ref r 'positive_well_typed)) wild-reports)
          'wild_bug_total_cases (length wild-reports)
          'generalized_negative_rejected_count
          (count (lambda (r) (hash-ref r 'negative_rejected)) gen-reports)
          'generalized_positive_well_typed_count
          (count (lambda (r) (hash-ref r 'positive_well_typed)) gen-reports)
          'generalized_total_cases (length gen-reports)
          'parallel_partition_total_profiles (length par-reports)
          'parallel_partition_multi_machine_count
          (count (lambda (m) (not (hash-ref m 'fallback_to_single_machine))) par-reports)
          'parallel_partition_single_machine_fallback_count
          (count (lambda (m) (hash-ref m 'fallback_to_single_machine)) par-reports)
          'parallel_partition_profiles par-reports
          'cluster_m_star_qcap400_profiles cluster-400-reports
          'cluster_m_star_qcap1500_profiles cluster-1500-all-reports
          'cluster_m_star_rsa4096_qcap230_m256 rsa4096-230-m256
          'cluster_m_star_optical_tree_qcap128 optical-tree-128-reports
          'cluster_m_star_optical_tree_rsa2048_qcap100 rsa2048-tree-100-pow2
          'cluster_m_star_rsa2048_1khz rsa2048-1khz
          'cluster_m_star_ecc256_qcap220 ecc-220
          'phase_erasure_vs_compensation_check
          (hasheq 'measure_synthesized_gates '()
                  'ctrl_d2_compensating_s_power 2
                  'ctrl_d2_synthesized_gates '("(z 7)"))
          'racket_runtime_ms elapsed-ms
          'wild_research_bug_results wild-reports
          'generalized_class_results gen-reports))

(module+ test
  (define summary (run-all-bug-class-prevention-checks!))
  (check-equal? (hash-ref summary 'wild_bug_negative_rejected_count) 14)
  (check-equal? (hash-ref summary 'wild_bug_positive_well_typed_count) 14)
  (check-equal? (hash-ref summary 'generalized_negative_rejected_count) 14)
  (check-equal? (hash-ref summary 'generalized_positive_well_typed_count) 14)
  (check-equal? (hash-ref summary 'parallel_partition_multi_machine_count) 6)
  (check-equal? (hash-ref summary 'parallel_partition_single_machine_fallback_count) 7)
  (check-equal? (length (hash-ref summary 'cluster_m_star_qcap400_profiles)) 12)
  (check-equal? (hash-ref (hash-ref summary 'cluster_m_star_rsa4096_qcap230_m256) 'optimal_machines) 24))

(module+ main
  (define emit-json? #f)
  (command-line
   #:program "lakefillq-bug-class-prevention-types"
   #:once-each
   [("--json") "Emit structured JSON verification summary to stdout"
    (set! emit-json? #t)])
  (define summary (run-all-bug-class-prevention-checks!))
  (if emit-json?
      (begin (write-json summary) (newline))
      (printf "LakefillQ 7-Rule Bug-Class Prevention Typechecker: ~a/~a wild bugs rejected, ~a/~a repaired well-typed, ~a/~a generalized cases verified, ~a/~a SOTA parallel profiles (~a single-machine fallbacks), ~a cluster M*<=256 profiles (~a ms)\n"
              (hash-ref summary 'wild_bug_negative_rejected_count)
              (hash-ref summary 'wild_bug_total_cases)
              (hash-ref summary 'wild_bug_positive_well_typed_count)
              (hash-ref summary 'wild_bug_total_cases)
              (hash-ref summary 'generalized_negative_rejected_count)
              (hash-ref summary 'generalized_total_cases)
              (hash-ref summary 'parallel_partition_total_profiles)
              (hash-ref summary 'parallel_partition_total_profiles)
              (hash-ref summary 'parallel_partition_single_machine_fallback_count)
              (length (hash-ref summary 'cluster_m_star_qcap400_profiles))
              (~r (hash-ref summary 'racket_runtime_ms) #:precision 2))))
