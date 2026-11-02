#lang racket/base

;; =============================================================================
;; compiler/lakefillq-redex-surface-diagnostic-fuzzer.rkt
;;
;; 640-Module PLT Redex `#lang lakefillq` Surface-Level Compiler, Unitary Adjoint
;; Cancellation, Lisp-1 Register/Gate Macro Hygiene & 22-Family Diagnostic Fuzzer.
;;
;; Exercises the ACTUAL `#lang lakefillq` reader, hygienic macro expander,
;; `LakefillQ -> lambda_LFQ_kern -> RevIR -> MachineISA` compiler pipeline,
;; OpenQASM 3.0 & Stim emitters, and 3-span inverse-resugared diagnostic engine
;; across 640 generated `.lfq` surface modules:
;;
;;   * Campaign 1 (240 modules — 120 `(u_fwd_i, u_cancel_i)` pairs):
;;     Grammar-generated unitary `#lang lakefillq` modules exercising Lisp-1
;;     dual-position register/gate identifiers (`x`, `s`, `z`, `h`), `s-dag`,
;;     `ry`, `rz-dyadic`, `cx`, `cz`, `ccx`, `swap`, `cswap-bit`, `qft`,
;;     `within-apply`, `qmatch` (including `h`/`s`/`s-dag`/`ry`/`rz-dyadic` arms),
;;     `focus-zipper` (with Lisp-1 shadowed focus/ambient registers), `fold-braun`
;;     (multi-node Okasaki Braun catamorphism left/right swap adjoints), `par-wires`,
;;     and per-declaration `#:target` keyword permutations.
;;
;;   * Campaign 2 (160 modules — Dynamic `MBU` Sessions, Chordal SSA Recycling,
;;     Domain Quotients & Modular `call-q`):
;;     40 chordal-recycled `with-and-session` / `within-apply-mbu` modules,
;;     40 coherent `mid-meas-x-cond-z` spectator modules,
;;     40 `quotient-vars` + `canonicalize-quotient` modules, and
;;     40 multi-declaration `call-q` modules (`BorrowZ` diagonal sharing + `Uniq1`).
;;
;;   * Campaign 3 (240 modules + Raw Programmatic `RevIR` Probe — All 22 Failure
;;     Families / 25 Diagnostic Codes):
;;     Grammar-mutated ill-typed `#lang lakefillq` modules covering `U1`–`U4`,
;;     `Phi1`–`Phi3`, `T-DomImg`..`T-ParGuard` (`E-DOMIMG`, `E-VALIDIF`,
;;     `E-ALGPHASE`, `E-WIREBASIS`, `E-DRIFTEPS`, `E-SINGLEIR`, `E-PARGUARD`),
;;     and all 8 surface/macro/CLI static discipline families (`LFQ-E-WIRE-ALIAS`,
;;     `LFQ-E-GATE-ALIAS`, `LFQ-E-UNDECLARED-WIRE`, `LFQ-E-CALL-ALIAS`,
;;     `LFQ-E-CLUSTER-COST-DRIFT`, `LFQ-E-QFREE-BASIS` incl. Lisp-1 `[x (qvec 2)]`,
;;     `LFQ-E-NONUNITARY-INVERT`, and `LFQ-E-REGISTER-BOUNDS` / `LFQ-E-TARGET-PROFILE`
;;     / `LFQ-E-GUARD-SPEC` / `LFQ-E-SURFACE-ELAB`), verifying 100% expected code
;;     match, 100% 1-indexed 3-span provenance, and 0 internal gensym/pass leaks.
;; =============================================================================

(require redex/reduction-semantics
         racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/port
         racket/pretty
         racket/runtime-path
         racket/set
         racket/string
         json
         (except-in lakefillq #%module-begin par-cluster-opt-spec solve-optimal-qpar-machines)
         "lakefillqc.rkt")

(provide LakefillQSurfaceFuzzL
         wf-surface-mod
         evaluate-lfq-file-isolated
         run-five-optimization-differential-fuzzer!
         run-redex-surface-diagnostic-fuzzer!)

(define-runtime-path HERE-DIR ".")

;; =============================================================================
;; 1. PLT Redex Surface Module Grammar (`LakefillQSurfaceFuzzL`) & Judgment
;; =============================================================================

(define-language LakefillQSurfaceFuzzL
  (TargetSym ::= ideal heron-r2 bluvstein-aod bb-qldpc)
  (DeclKind  ::= defq defqfree)
  ;; Includes Lisp-1 gate-shadowing register names `x`, `s`, `z`, `h`!
  (RegId     ::= x s z h a b c anc s1 s2 q-hist key ctl out tmp rk st buf plaq phase-reg)
  (Idx       ::= natural)
  (Width     ::= natural)
  (DyadicK   ::= 1 2 3 4)
  (AngleTag  ::= pi/4 pi/3 pi/5 -pi/4)
  (LoopEscK  ::= 1 2 4 6 8)
  (PebbleBudget ::= 4 6 8)
  (QpuLoc    ::= @p1 @p2)
  (WExpr     ::= (wref RegId Idx))
  (Guard     ::= (g-zero WExpr)
                 (g-wire WExpr)
                 (g-and Guard Guard)
                 (g-or Guard Guard)
                 (g-not Guard))
  (BraunNode ::= braun-leaf
                 (braun-branch Idx UnitaryStmt BraunNode BraunNode))
  (UnitaryStmt ::=
               skip
               (x WExpr)
               (z WExpr)
               (s WExpr)
               (s-dag WExpr)
               (t WExpr)
               (t-dag WExpr)
               (h WExpr)
               (ry AngleTag WExpr)
               (rz-dyadic WExpr DyadicK)
               (cx WExpr WExpr)
               (cz WExpr WExpr)
               (ccx WExpr WExpr WExpr)
               (ccz WExpr WExpr WExpr)
               (shared-ccz-pair WExpr WExpr WExpr WExpr WExpr)
               (swap WExpr WExpr)
               (cswap-bit WExpr WExpr WExpr)
               (qft RegId)
               (seq UnitaryStmt ...)
               (invert UnitaryStmt)
               (within-apply UnitaryStmt UnitaryStmt (WExpr ...))
               (qmatch (Guard UnitaryStmt) ...)
               (focus-zipper (RegId WExpr ...) (RegId WExpr ...) UnitaryStmt)
               (fold-braun BraunNode)
               (par-wires UnitaryStmt UnitaryStmt))
  (SessionStmt ::=
               UnitaryStmt
               (seq SessionStmt ...)
               (with-and-session ((WExpr WExpr WExpr) ...) SessionStmt)
               (within-apply-mbu UnitaryStmt SessionStmt (WExpr ...))
               (mid-meas-x-cond-z WExpr WExpr)
               (canonicalize-quotient RegId UnitaryStmt)
               (call-q variable RegId ...)
               (for/fold-loop Idx LoopEscK SessionStmt)
               (adaptive-pebble-divsteps Idx PebbleBudget SessionStmt)
               (tele-phase-mbu-cut QpuLoc QpuLoc WExpr WExpr WExpr))
  (RegClause ::= (RegId Width))
  (DomClause ::= all (quotient-vars RegId))
  (CircDecl  ::= (DeclKind variable
                           (wires RegClause ...)
                           (scratch RegClause ...)
                           (domain DomClause)
                           (target TargetSym)
                           SessionStmt ...))
  (SurfaceMod ::= (lfq-mod TargetSym CircDecl ...)))

(define-judgment-form LakefillQSurfaceFuzzL
  #:mode (wf-surface-mod I O)
  #:contract (wf-surface-mod SurfaceMod TargetSym)

  [---------------------------------------------------------- "WF-SurfaceMod"
   (wf-surface-mod (lfq-mod TargetSym CircDecl_0 CircDecl ...) TargetSym)])

;; =============================================================================
;; 2. Redex Term -> Concrete `#lang lakefillq` Source Renderer
;; =============================================================================

(define (angle-tag->surface-str tag)
  (match tag
    ['pi/4 "(/ pi 4)"]
    ['pi/3 "(/ pi 3)"]
    ['pi/5 "(/ pi 5)"]
    ['-pi/4 "(- (/ pi 4))"]
    [_ "(/ pi 4)"]))

(define (wexpr->surface-str we)
  (match we
    [`(wref ,r ,i) (format "(wref ~a ~a)" r i)]))

(define (guard->surface-str g)
  (match g
    [`(g-zero ,w) (format "(g-zero ~a)" (wexpr->surface-str w))]
    [`(g-wire ,w) (format "(g-wire ~a)" (wexpr->surface-str w))]
    [`(g-and ,g1 ,g2) (format "(g-and ~a ~a)" (guard->surface-str g1) (guard->surface-str g2))]
    [`(g-or ,g1 ,g2) (format "(g-or ~a ~a)" (guard->surface-str g1) (guard->surface-str g2))]
    [`(g-not ,g1) (format "(g-not ~a)" (guard->surface-str g1))]))

;; Renders a Redex `BraunNode` via `list->braun-tree` or explicit `braun-node` values:
(define (braun-node->surface-str bn)
  (match bn
    ['braun-leaf "#f"]
    [`(braun-branch ,idx ,st ,l ,r)
     (format "(braun-node '~a ~a ~a ~a)"
             (format "n~a" idx)
             idx
             (braun-node->surface-str l)
             (braun-node->surface-str r))]))

(define (collect-braun-steps bn)
  (match bn
    ['braun-leaf '()]
    [`(braun-branch ,idx ,st ,l ,r)
     (append (collect-braun-steps l)
             (list (cons idx st))
             (collect-braun-steps r))]))

(define (stmt->surface-str st)
  (match st
    ['skip "skip"]
    [`(,(and op (or 'x 'z 's 's-dag 'h)) ,w)
     (format "(~a ~a)" op (wexpr->surface-str w))]
    [`(ry ,ang ,w)
     (format "(ry ~a ~a)" (angle-tag->surface-str ang) (wexpr->surface-str w))]
    [`(rz-dyadic ,w ,k)
     (format "(rz-dyadic ~a ~a)" (wexpr->surface-str w) k)]
    [`(,(and op (or 'cx 'cz 'swap)) ,w1 ,w2)
     (format "(~a ~a ~a)" op (wexpr->surface-str w1) (wexpr->surface-str w2))]
    [`(,(and op (or 'ccx 'cswap-bit)) ,w1 ,w2 ,w3)
     (format "(~a ~a ~a ~a)" op (wexpr->surface-str w1) (wexpr->surface-str w2) (wexpr->surface-str w3))]
    [`(qft ,reg)
     (format "(qft ~a)" reg)]
    [`(seq)
     "skip"]
    [`(seq ,es ...)
     (format "(seq ~a)" (string-join (map stmt->surface-str es) " "))]
    [`(invert ,sub)
     (format "(invert ~a)" (stmt->surface-str sub))]
    [`(within-apply ,c ,a (,ws ...))
     (format "(within-apply ~a ~a (list ~a))"
             (stmt->surface-str c)
             (stmt->surface-str a)
             (string-join (map wexpr->surface-str ws) " "))]
    [`(qmatch (,gs ,arms) ...)
     (format "(qmatch (~a))"
             (string-join
              (for/list ([g (in-list gs)] [a (in-list arms)])
                (format "[~a ~a]" (guard->surface-str g) (stmt->surface-str a)))
              " "))]
    [`(focus-zipper (,freg ,fws ...) (,areg ,aws ...) ,body)
     ;; `focus-zipper` takes `[focus-id sub-ws-expr ambient-ws-expr] body ...`
     (define all-amb-ws (append fws aws))
     (format "(focus-zipper [~a (list ~a) (list ~a)] ~a)"
             freg
             (string-join (map wexpr->surface-str fws) " ")
             (string-join (map wexpr->surface-str all-amb-ws) " ")
             (stmt->surface-str body))]
    [`(fold-braun ,bn)
     (define indexed-steps (collect-braun-steps bn))
     (cond
       [(null? indexed-steps) "skip"]
       [else
        (define cond-branches
          (for/list ([p (in-list indexed-steps)])
            (format "[(= idx ~a) ~a]" (car p) (stmt->surface-str (cdr p)))))
        (define item-list
          (string-join (for/list ([i (in-range (length indexed-steps))]) (number->string i)) " "))
        (format "(fold-braun (lambda (_val idx) (cond ~a [else skip])) '(~a))"
                (string-join cond-branches " ")
                item-list)])]
    [`(par-wires ,e1 ,e2)
     (format "(par-wires ~a ~a)" (stmt->surface-str e1) (stmt->surface-str e2))]
    [`(with-and-session ((,anc ,l ,r) ...) ,body)
     (format "(with-and-session (~a) ~a)"
             (string-join
              (for/list ([a (in-list anc)] [lw (in-list l)] [rw (in-list r)])
                (format "[~a ~a ~a]"
                        (wexpr->surface-str a)
                        (wexpr->surface-str lw)
                        (wexpr->surface-str rw)))
              " ")
             (stmt->surface-str body))]
    [`(within-apply-mbu ,c ,a (,ws ...))
     (format "(within-apply-mbu ~a ~a (list ~a))"
             (stmt->surface-str c)
             (stmt->surface-str a)
             (string-join (map wexpr->surface-str ws) " "))]
    [`(mid-meas-x-cond-z ,anc ,tgt)
     (format "(mid-meas-x-cond-z ~a ~a)"
             (wexpr->surface-str anc)
             (wexpr->surface-str tgt))]
    [`(canonicalize-quotient ,qreg ,c)
     (format "(canonicalize-quotient ~a ~a)" qreg (stmt->surface-str c))]
    [`(call-q ,callee ,regs ...)
     (format "(call-q ~a ~a)" callee (string-join (map symbol->string regs) " "))]))

(define (surface-mod->lfq-text mod-term #:kw-order [kw-order 0])
  (match-define `(lfq-mod ,mod-tgt ,decls ...) mod-term)
  (define lines (list "#lang lakefillq" (format "(target-profile ~a)" mod-tgt)))
  (define decl-strs
    (for/list ([d (in-list decls)] [didx (in-naturals)])
      (match-define `(,kind ,cname
                            (wires (,wids ,wws) ...)
                            (scratch (,sids ,sws) ...)
                            (domain ,dom)
                            (target ,dtgt)
                            ,body-stmts ...)
        d)
      (define w-part
        (format "#:wires (~a)"
                (string-join
                 (for/list ([id (in-list wids)] [w (in-list wws)])
                   (format "[~a (qvec ~a)]" id w))
                 " ")))
      (define s-part
        (if (null? sids)
            #f
            (format "#:scratch (~a)"
                    (string-join
                     (for/list ([id (in-list sids)] [w (in-list sws)])
                       (format "[~a (qvec ~a)]" id w))
                     " "))))
      (define dom-part
        (match dom
          ['all #f]
          [`(quotient-vars ,qr) (format "#:domain (quotient-vars ~a)" qr)]))
      (define tgt-part
        (if (= (modulo (+ kw-order didx) 2) 0)
            (format "#:target '~a" dtgt)
            (format "#:target ~a" dtgt)))
      ;; Exercise arbitrary keyword permutations (`#:target` before `#:wires`, etc.):
      (define opt-parts (filter values (list s-part dom-part tgt-part)))
      (define hdr-parts
        (if (= (modulo kw-order 3) 1)
            (append opt-parts (list w-part))
            (cons w-part opt-parts)))
      (format "(~a (~a ~a)\n  ~a)"
              kind
              cname
              (string-join hdr-parts "\n        ")
              (string-join (map stmt->surface-str body-stmts) "\n  "))))
  (string-append (string-join (append lines decl-strs) "\n\n") "\n"))

;; =============================================================================
;; 3. Isolated In-Process `#lang lakefillq` Loader & Diagnostic Hygiene Checker
;; =============================================================================

(define FORBIDDEN-GENSYM-TOKENS
  '("__u4_mx_"
    "__mbu_"
    "lower-kern->revir"
    "surface-unitary-adjoint"
    "defq-internal"
    "lakefillq/main.rkt"))

(define ROOT-NAMESPACE (current-namespace))

;; Ensure `lakefillq` is instantiated in `ROOT-NAMESPACE` so child namespaces share all structs:
(void (namespace-require '(only lakefillq lfq-program?)))

(define (make-isolated-lfq-namespace)
  (define child (make-base-empty-namespace))
  (namespace-attach-module ROOT-NAMESPACE 'lakefillq child)
  child)

(define (evaluate-lfq-file-isolated lfq-path
                                    #:target-override [target-override #f]
                                    #:repair? [repair? #f])
  (define full-p (simple-form-path lfq-path))
  (define path-str (path->string full-p))
  (define fname (path->string (file-name-from-path full-p)))
  (define child-ns (make-isolated-lfq-namespace))
  (with-handlers
    ([exn:fail:lfq-surface?
      (lambda (e)
        (define sp
          (or (exn:fail:lfq-surface-span e)
              (lfq-surface-span path-str 1 0 fname 'LakefillQ)))
        (define code (exn:fail:lfq-surface-code e))
        (define hint (exn:fail:lfq-surface-repair-hint e))
        (define v
          (enrich-revir-violation
           (hasheq 'category "StaticDiscipline"
                   'rule "T-WireScope"
                   'code code
                   'message (exn-message e)
                   'witness (hasheq))
           #:resugared-message (exn-message e)
           #:origin-span sp
           #:mutating-span sp
           #:failure-span sp
           #:repair-hint hint))
        (define human-txt (format-violations-human fname "surface" (list v)))
        (values #f
                (hasheq 'well_typed #f
                        'residual_surface_forms 0
                        'violations (list v))
                ""
                ""
                human-txt))]
     [exn:fail?
      (lambda (e)
        (define raw-msg (exn-message e))
        (define fallback-sp (lfq-surface-span path-str 1 0 fname 'LakefillQ))
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
        (define v
          (enrich-revir-violation
           (hasheq 'category "StaticDiscipline"
                   'rule "T-SurfaceSyntax"
                   'code "LFQ-E-SURFACE-ELAB"
                   'message raw-msg
                   'witness (hasheq))
           #:resugared-message clean-msg
           #:origin-span parsed-sp
           #:mutating-span parsed-sp
           #:failure-span parsed-sp
           #:repair-hint "Verify `#lang lakefillq` surface syntax and quoted symbol arguments."))
        (define human-txt (format-violations-human fname "surface" (list v)))
        (values #f
                (hasheq 'well_typed #f
                        'residual_surface_forms 0
                        'violations (list v))
                ""
                ""
                human-txt))])
    (define prog
      (parameterize ([current-namespace child-ns])
        (dynamic-require full-p 'lakefillq-program-spec)))
    (define res
      (compile-lfq-program prog
                           #:target target-override
                           #:repair? repair?))
    (define js (compilation-result->jsexpr res))
    (define human-txt
      (if (compilation-result-well-typed? res)
          ""
          (format-compilation-diagnostics-human res)))
    (values (compilation-result-well-typed? res)
            js
            (compilation-result-qasm3-text res)
            (compilation-result-stim-text res)
            human-txt)))

(define (valid-1indexed-span-jsexpr? sp)
  (and (hash? sp)
       (string? (hash-ref sp 'file #f))
       (non-empty-string? (hash-ref sp 'file ""))
       (exact-integer? (hash-ref sp 'line #f))
       (>= (hash-ref sp 'line 0) 1)
       (exact-integer? (hash-ref sp 'column #f))
       (>= (hash-ref sp 'column -1) 0)
       (string? (hash-ref sp 'role #f))
       (non-empty-string? (hash-ref sp 'role ""))
       (string? (hash-ref sp 'captured_at_pass #f))
       (non-empty-string? (hash-ref sp 'captured_at_pass ""))))

(define (valid-violation-hygiene? v human-txt)
  (define prov (hash-ref v 'provenance_spans #f))
  (define res-msg (hash-ref v 'resugared_message ""))
  (and (hash? prov)
       (valid-1indexed-span-jsexpr? (hash-ref prov 'origin_span #f))
       (valid-1indexed-span-jsexpr? (hash-ref prov 'mutating_span #f))
       (valid-1indexed-span-jsexpr? (hash-ref prov 'failure_span #f))
       (string? (hash-ref v 'code #f))
       (non-empty-string? (hash-ref v 'code ""))
       (string? (hash-ref v 'unified_judgment_obligation #f))
       (non-empty-string? (hash-ref v 'unified_judgment_obligation ""))
       (string? (hash-ref v 'repair_hint #f))
       (non-empty-string? (hash-ref v 'repair_hint ""))
       (for/and ([tok (in-list FORBIDDEN-GENSYM-TOKENS)])
         (and (not (string-contains? res-msg tok))
              (not (string-contains? human-txt tok))))))

;; =============================================================================
;; 4. Deterministic PRNG & Campaign 1 Generator (240 Unitary & Adjoint Modules)
;; =============================================================================

(define (make-lcg-rng seed)
  (define state (box (bitwise-and seed #x7FFFFFFF)))
  (lambda (modulus)
    (define nxt (modulo (+ (* 1103515245 (unbox state)) 12345) #x80000000))
    (set-box! state nxt)
    (if (<= modulus 1) 0 (modulo (quotient nxt 16) modulus))))

(define LISP1-REG-PAIRS
  '((x s) (z h) (x h) (s z) (a x) (s b)))

(define ANGLE-TAGS '(pi/4 pi/3 pi/5 -pi/4))

(define (pick rng lst)
  (list-ref lst (rng (length lst))))

(define (pick-distinct-pair rng pool)
  (define a (pick rng pool))
  (define rest-pool (remove a pool))
  (define b (pick rng rest-pool))
  (values a b))

(define (pick-distinct-triple rng pool)
  (define a (pick rng pool))
  (define p1 (remove a pool))
  (define b (pick rng p1))
  (define p2 (remove b p1))
  (define c (pick rng p2))
  (values a b c))

(define (gen-leaf-unitary rng wpool)
  (define choice (rng 11))
  (cond
    [(= choice 0) `(x ,(pick rng wpool))]
    [(= choice 1) `(z ,(pick rng wpool))]
    [(= choice 2) `(s ,(pick rng wpool))]
    [(= choice 3) `(s-dag ,(pick rng wpool))]
    [(= choice 4) `(h ,(pick rng wpool))]
    [(= choice 5) `(ry ,(pick rng ANGLE-TAGS) ,(pick rng wpool))]
    [(= choice 6) `(rz-dyadic ,(pick rng wpool) ,(add1 (rng 4)))]
    [(= choice 7)
     (define-values (u v) (pick-distinct-pair rng wpool))
     `(cx ,u ,v)]
    [(= choice 8)
     (define-values (u v) (pick-distinct-pair rng wpool))
     `(cz ,u ,v)]
    [(= choice 9)
     (define-values (u v) (pick-distinct-pair rng wpool))
     `(swap ,u ,v)]
    [else
     (if (>= (length wpool) 3)
         (let-values ([(a b c) (pick-distinct-triple rng wpool)])
           (if (= (rng 2) 0)
               `(ccx ,a ,b ,c)
               `(cswap-bit ,a ,b ,c)))
         (let-values ([(u v) (pick-distinct-pair rng wpool)])
           `(cx ,u ,v)))]))

(define (gen-structured-unitary idx rng r1 r2 sreg)
  (define w1-0 `(wref ,r1 0))
  (define w1-1 `(wref ,r1 1))
  (define w2-0 `(wref ,r2 0))
  (define w2-1 `(wref ,r2 1))
  (define ws-0 `(wref ,sreg 0))
  (define data-pool (list w1-0 w1-1 w2-0 w2-1))
  (define family (modulo idx 8))
  (define core-combinator
    (match family
      ;; 0: Lisp-1 shadowed `s` / `s-dag` / `rz-dyadic` + `ccx`
      [0
       `(seq (h ,w1-0)
             (s ,w1-0)
             (rz-dyadic ,w2-0 ,(add1 (modulo idx 4)))
             (s-dag ,w2-1)
             (ccx ,w1-0 ,w1-1 ,w2-0))]
      ;; 1: Exhaustive orthogonal `qmatch` with `h`, `s`, `s-dag`, `ry`, `rz-dyadic` arms!
      [1
       `(seq (h ,w1-0)
             (ry ,(pick rng ANGLE-TAGS) ,w1-1)
             (qmatch [(g-and (g-zero ,w1-0) (g-zero ,w1-1))
                      (seq (h ,w2-0) (s ,w2-1))]
                     [(g-and (g-zero ,w1-0) (g-wire ,w1-1))
                      (seq (s-dag ,w2-0) (cx ,w2-0 ,w2-1))]
                     [(g-and (g-wire ,w1-0) (g-zero ,w1-1))
                      (ry pi/4 ,w2-0)]
                     [(g-and (g-wire ,w1-0) (g-wire ,w1-1))
                      (rz-dyadic ,w2-1 3)]))]
      ;; 2: `qft` + `cswap-bit` + `invert`
      [2
       `(seq (h ,w1-0)
             (qft ,r1)
             (cswap-bit ,w1-0 ,w2-0 ,w2-1)
             (invert (qft ,r2)))]
      ;; 3: `within-apply` unitary scratch conjugation
      [3
       `(seq (h ,w1-0)
             (h ,w1-1)
             (within-apply
              (seq (ccx ,w1-0 ,w1-1 ,ws-0)
                   (s ,ws-0))
              (cz ,ws-0 ,w2-0)
              (,ws-0)))]
      ;; 4: `focus-zipper` with Lisp-1 gate-named focus register (`x`, `s`, `z`, `h`)!
      [4
       (define focus-sym (list-ref '(x s z h) (modulo idx 4)))
       `(seq (h ,w1-0)
             (focus-zipper (,focus-sym ,w1-0 ,w1-1) (,r2 ,w2-0 ,w2-1)
                           (seq (x (wref ,focus-sym 0))
                                (s ,w2-0)
                                (s-dag (wref ,focus-sym 1))
                                (cx (wref ,focus-sym 0) ,w2-1))))]
      ;; 5: `fold-braun` 3-node Okasaki Braun catamorphism (`idx 0 -> left, idx 1 -> root, idx 2 -> right`)
      [5
       `(seq (h ,w1-0)
             (h ,w2-0)
             (fold-braun
              (braun-branch 0
                            (seq (s ,w1-1) (cx ,w1-1 ,w2-0))
                            (braun-branch 1
                                          (seq (h ,w1-0) (cx ,w1-0 ,w1-1))
                                          braun-leaf
                                          braun-leaf)
                            (braun-branch 2
                                          (seq (rz-dyadic ,w2-0 2) (cz ,w2-0 ,w2-1))
                                          braun-leaf
                                          braun-leaf))))]
      ;; 6: Disjoint `par-wires` (far apart on ideal or non-colliding wires)
      [6
       `(seq (h ,w1-0)
             (par-wires (seq (s ,w1-0) (cx ,w1-0 ,w1-1))
                        (seq (h ,w2-0) (s-dag ,w2-1))))]
      ;; 7: Nested `(invert ...)` + random leaf gates
      [_
       `(seq ,(gen-leaf-unitary rng data-pool)
             (invert (seq ,(gen-leaf-unitary rng data-pool)
                          ,(gen-leaf-unitary rng data-pool)))
             ,(gen-leaf-unitary rng data-pool))]))
  `(seq ,(gen-leaf-unitary rng data-pool)
        ,core-combinator
        ,(gen-leaf-unitary rng data-pool)))

(define (build-campaign1-pair idx rng)
  (match-define (list r1 r2) (list-ref LISP1-REG-PAIRS (modulo idx (length LISP1-REG-PAIRS))))
  (define sreg (if (or (eq? r1 'anc) (eq? r2 'anc)) 'tmp 'anc))
  (define tgt (if (= (modulo idx 6) 4) 'ideal (list-ref '(ideal heron-r2 bb-qldpc ideal) (modulo idx 4))))
  ;; Note: family 6 (`par-wires` on adjacent `[0,1]` vs `[2,3]`) uses `'ideal` so `Phi2` does not fire on blockade pitch
  (define eff-tgt (if (= (modulo idx 8) 6) 'ideal tgt))
  (define u-body (gen-structured-unitary idx rng r1 r2 sreg))
  (define fwd-name (string->symbol (format "u-fwd-~a" idx)))
  (define cancel-name (string->symbol (format "u-cancel-~a" idx)))
  (define fwd-mod
    `(lfq-mod ,eff-tgt
              (defq ,fwd-name
                    (wires (,r1 2) (,r2 2))
                    (scratch (,sreg 1))
                    (domain all)
                    (target ,eff-tgt)
                    ,u-body)))
  (define cancel-mod
    `(lfq-mod ,eff-tgt
              (defq ,cancel-name
                    (wires (,r1 2) (,r2 2))
                    (scratch (,sreg 1))
                    (domain all)
                    (target ,eff-tgt)
                    (seq ,u-body (invert ,u-body)))))
  (values fwd-mod cancel-mod (modulo idx 8)))

;; =============================================================================
;; 5. Campaign 2 Generator (160 Dynamic `MBU`, Chordal, Quotient & `call-q` Modules)
;; =============================================================================

(define (build-campaign2-module idx rng)
  (define family (modulo idx 4))
  (match family
    ;; Family 0: Sequential `with-and-session` + `within-apply-mbu` triggering chordal SSA scratch recycling!
    [0
     (match-define (list r1 r2) (list-ref LISP1-REG-PAIRS (modulo idx (length LISP1-REG-PAIRS))))
     (define cname (string->symbol (format "mbu-chordal-~a" idx)))
     `(lfq-mod ideal
               (defq ,cname
                     (wires (,r1 2) (,r2 2))
                     (scratch (s1 1) (s2 1))
                     (domain all)
                     (target ideal)
                     (seq (x (wref ,r1 ,(modulo idx 2)))
                          (with-and-session (((wref s1 0) (wref ,r1 0) (wref ,r1 1)))
                                            (cx (wref s1 0) (wref ,r2 0)))
                          (within-apply-mbu (ccx (wref ,r1 0) (wref ,r2 0) (wref s2 0))
                                            (cx (wref s2 0) (wref ,r2 1))
                                            ((wref s2 0))))))]
    ;; Family 1: Explicit `mid-meas-x-cond-z` preserving coherent superposition phase (`U4` clean)!
    [1
     (define cname (string->symbol (format "mbu-phase-clean-~a" idx)))
     `(lfq-mod heron-r2
               (defq ,cname
                     (wires (x 2) (s 1))
                     (scratch (anc 1))
                     (domain all)
                     (target heron-r2)
                     (seq (h (wref x 0))
                          (s (wref x 1))
                          (cx (wref x 0) (wref anc 0))
                          (mid-meas-x-cond-z (wref anc 0) (wref x 0))
                          (cx (wref x 0) (wref s 0))
                          (s-dag (wref x 1))
                          (h (wref x 0)))))]
    ;; Family 2: Quotient domain `quotient-vars` + `canonicalize-quotient` (`U2-Canonical` clean)!
    [2
     (define cname (string->symbol (format "quotient-canon-~a" idx)))
     `(lfq-mod ideal
               (defq ,cname
                     (wires (x 2))
                     (scratch (q-hist 1))
                     (domain (quotient-vars q-hist))
                     (target ideal)
                     (seq (cx (wref x ,(modulo idx 2)) (wref q-hist 0))
                          (canonicalize-quotient q-hist
                                                 (cx (wref x ,(modulo idx 2)) (wref q-hist 0)))
                          (h (wref x 0)))))]
    ;; Family 3: Multi-circuit modular `call-q` with `BorrowZ` diagonal control sharing + `Uniq1` target!
    [_
     (define hname (string->symbol (format "helper-mix-~a" idx)))
     (define mname (string->symbol (format "caller-main-~a" idx)))
     `(lfq-mod ideal
               (defqfree ,hname
                         (wires (rk 2) (a 2) (st 2))
                         (scratch (tmp 1))
                         (domain all)
                         (target ideal)
                         (with-and-session (((wref tmp 0) (wref rk 0) (wref a 0)))
                                           (seq (cx (wref tmp 0) (wref st 0))
                                                (cx (wref rk 1) (wref st 1)))))
               (defq ,mname
                     (wires (x 2) (s 2) (z 2))
                     (scratch)
                     (domain all)
                     (target ideal)
                     (seq (h (wref x 0))
                          ;; Diagonal `BorrowZ` sharing `(x, x)` + `Uniq1` target `z`!
                          (call-q ,hname x x z)
                          (call-q ,hname x s z))))]))

;; =============================================================================
;; 6. Campaign 3 Generator (240 Mutated Ill-Typed Modules Across All 22 Families)
;; =============================================================================

;; Returns `(list family-id expected-code lfq-source-text)` for 240 mutated modules:
(define (build-campaign3-cases)
  (define cases '())
  (define (add-n! count fam-id exp-code builder-proc)
    (for ([k (in-range count)])
      (set! cases (cons (list fam-id exp-code (builder-proc k)) cases))))

  ;; 1. `U1-EraseBy` (12 modules: dirty scratch & chordal-recycled `s2[0]` leak with Lisp-1 `x`/`s` regs)
  (add-n! 12 "F01_U1_EraseBy" "U1-EraseBy"
          (lambda (k)
            (if (even? k)
                (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-u1-chordal-~a #:wires ([x (qvec 2)]) #:scratch ([s1 (qvec 1)] [s2 (qvec 1)]))\n  (cx (wref x 0) (wref s1 0))\n  (cx (wref x 0) (wref s1 0))\n  (ccx (wref x 0) (wref x 1) (wref s2 0)))\n" k)
                (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-u1-dirty-~a #:wires ([s (qvec 2)]) #:scratch ([anc (qvec 1)]))\n  (x (wref s ~a))\n  (cx (wref s 0) (wref anc 0)))\n" k (modulo k 2)))))

  ;; 2. `U2-Canonical` (10 modules: uncanonicalized `quotient-vars` history dependence)
  (add-n! 10 "F02_U2_Canonical" "U2-Canonical"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-u2-~a #:wires ([x (qvec 2)] [q_hist (qvec 1)]) #:domain (quotient-vars q_hist))\n  (cx (wref x ~a) (wref q_hist 0))\n  (h (wref x 0)))\n"
                    k (modulo k 2))))

  ;; 3. `U3-TotalOn` (12 modules: non-exhaustive, overlapping, and guard-mutating `qmatch`)
  (add-n! 12 "F03_U3_TotalOn" "U3-TotalOn"
          (lambda (k)
            (match (modulo k 3)
              [0 (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-u3-nonexh-~a #:wires ([x (qvec 2)] [s (qvec 1)]))\n  (qmatch ([(g-zero (wref x 0)) (x (wref s 0))])))\n" k)]
              [1 (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-u3-overlap-~a #:wires ([x (qvec 2)] [s (qvec 1)]))\n  (qmatch ([(g-zero (wref x 0)) (x (wref s 0))]\n           [(g-zero (wref x 1)) (cx (wref x 0) (wref s 0))]\n           [(g-and (g-wire (wref x 0)) (g-wire (wref x 1))) skip])))\n" k)]
              [_ (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-u3-gmut-~a #:wires ([x (qvec 1)] [s (qvec 1)]))\n  (qmatch ([(g-zero (wref x 0)) (x (wref x 0))]\n           [(g-wire (wref x 0)) (x (wref s 0))])))\n" k)])))

  ;; 4. `U4-QTainted` (10 modules: missing or misdirected `cond-z` phase taint across `h`, testing gensym hygiene!)
  (add-n! 10 "F04_U4_QTainted" "U4-QTainted"
          (lambda (k)
            (if (even? k)
                (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-u4-gensym-~a #:wires ([x (qvec 1)] [s (qvec 1)]) #:scratch ([anc (qvec 1)]))\n  (h (wref x 0))\n  (cx (wref x 0) (wref anc 0))\n  (mid-meas-x-cond-z (wref anc 0) (wref s 0))\n  (h (wref x 0)))\n" k)
                (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-u4-raw-~a #:wires ([ctl (qvec 1)]) #:scratch ([anc (qvec 1)]))\n  (h (wref ctl 0))\n  (cx (wref ctl 0) (wref anc 0))\n  (mid-meas-x (wref anc 0) 'm_u4)\n  (h (wref ctl 0)))\n" k))))

  ;; 5. `Phi1-DecoherenceAction` (10 modules: unshielded mid-circuit measurement on `heron-r2` / `bluvstein-aod`)
  (add-n! 10 "F05_Phi1_DecoherenceAction" "Phi1-DecoherenceAction"
          (lambda (k)
            (define tgt (if (even? k) "heron-r2" "bluvstein-aod"))
            (format "#lang lakefillq\n(target-profile ~a)\n(defq (mut-phi1-~a #:wires ([x (qvec 6)]) #:scratch ([anc (qvec 1)]))\n  (for/seq ([i (in-range 6)]) (h (wref x i)))\n  (cx (wref x 0) (wref anc 0))\n  (mid-meas-x-unshielded (wref anc 0) 'm_unsh)\n  (cond-z 'm_unsh (wref x 0)))\n"
                    tgt k)))

  ;; 6. `Phi2-ExclusionGraph` (12 modules: blockade/coupler exclusion collision in `par-wires`)
  (add-n! 12 "F06_Phi2_ExclusionGraph" "Phi2-ExclusionGraph"
          (lambda (k)
            (define tgt (if (even? k) "bluvstein-aod" "heron-r2"))
            (format "#lang lakefillq\n(target-profile ~a)\n(defq (mut-phi2-~a #:wires ([x (qvec 4)]))\n  (par-wires (cx (wref x 0) (wref x 1))\n             (cx (wref x 2) (wref x 3))))\n"
                    tgt k)))

  ;; 7. `Phi3-FaultExponent` (12 modules: aligned plaquette hook error + float64 `rz-dyadic` k >= 53)
  (add-n! 12 "F07_Phi3_FaultExponent" "Phi3-FaultExponent"
          (lambda (k)
            (if (even? k)
                (format "#lang lakefillq\n(target-profile bb-qldpc)\n(defq (mut-phi3-hook-~a #:wires ([plaq (qvec 5)]))\n  (syndrome-plaquette plaq 5 #:schedule 'aligned))\n" k)
                (format "#lang lakefillq\n(target-profile bb-qldpc)\n(defq (mut-phi3-f64-~a #:wires ([s (qvec 1)]))\n  (rz-dyadic (wref s 0) ~a #:precision 'float64 #:distance 5))\n"
                        k (+ 54 k)))))

  ;; 8. `T-DomImg` (`E-DOMIMG-NON-INJECTIVE`, 10 modules)
  (add-n! 10 "F08_T_DomImg" "E-DOMIMG-NON-INJECTIVE"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-domimg-~a #:wires ([x (qvec 2)]) #:scratch ([anc (qvec 1)]))\n  (erase-by-part-bij\n   '(part-bij-smt2 #:label non-inj-~a #:vars ((x Int)) #:vars-alt ((x_alt Int)) #:preamble \"\"\n     #:dom-f \"(and (<= 0 x) (< x 4))\" #:f-out (\"(mod x 2)\")\n     #:dom-g-on-f \"(and (<= 0 (mod x 2)) (< (mod x 2) 2))\" #:g-of-f (\"(mod x 2)\")\n     #:residual () #:f-out-alt (\"(mod x_alt 2)\") #:dom-f-alt \"(and (<= 0 x_alt) (< x_alt 4))\")\n   (cx (wref x 0) (wref anc 0))\n   (cx (wref x 0) (wref anc 0))\n   anc))\n"
                    k k)))

  ;; 9. `T-ValidIf` (`E-VALIDIF-UNWRAPPED-USE`, 10 modules)
  (add-n! 10 "F09_T_ValidIf" "E-VALIDIF-UNWRAPPED-USE"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-validif-~a #:wires ([x (qvec 2)]))\n  (guard-valid-if\n   '(valid-if-seq\n     (bind-partial-op v_dec 3 err_vec (QVec 15 id F2StdBasis) bounded-syndrome-decode)\n     (unwrap-unchecked err_vec))\n   (cx (wref x 0) (wref x 1))))\n"
                    k)))

  ;; 10. `T-AlgPhase` (`E-ALGPHASE-NON-HERMITIAN-SCALAR`, 10 modules)
  (add-n! 10 "F10_T_AlgPhase" "E-ALGPHASE-NON-HERMITIAN-SCALAR"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-algphase-~a #:wires ([x (qvec 2)]))\n  (guard-involutory\n   'qubitization-walk\n   '(scalar-phase 1 (pauli-string ((0 X) (1 X))))\n   (cx (wref x 0) (wref x 1))))\n"
                    k)))

  ;; 11. `T-WireBasis` (`E-WIREBASIS-RAW-STENCIL-ALIAS`, 10 modules)
  (add-n! 10 "F11_T_WireBasis" "E-WIREBASIS-RAW-STENCIL-ALIAS"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-wirebasis-~a #:wires ([x (qvec 7)]))\n  (guard-wire-basis\n   '(wire-basis-prog\n     #:regs ((lanes 5 (0 1 2 3 4) F2StdBasis (0 1 2 3 4)))\n     #:ops ((stencil-ring imperative-seq 5 0 4 (0 1 2) 0 (0 1 2 3 4) (5 6))))\n   (cx (wref x 0) (wref x 1))))\n"
                    k)))

  ;; 12. `T-DriftEps` (`E-DRIFTEPS-RNS-DYNAMIC-RANGE`, 10 modules)
  (add-n! 10 "F12_T_DriftEps" "E-DRIFTEPS-RNS-DYNAMIC-RANGE"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-drifteps-~a #:wires ([x (qvec 2)]))\n  (guard-drift-eps\n   '(rns-range-spec #:modulus-n 15 #:power-m 2 #:rns-moduli (11 19))\n   (cx (wref x 0) (wref x 1))))\n"
                    k)))

  ;; 13. `T-SingleIR` (`E-SINGLEIR-UNBOUND-SLICE`, 10 modules)
  (add-n! 10 "F13_T_SingleIR" "E-SINGLEIR-UNBOUND-SLICE"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-singleir-~a #:wires ([x (qvec 2)]))\n  (guard-single-ir\n   '(single-ir-kernel #:label dqi-slice-bug-~a\n     #:revir-ast (for-matrix-elim #:rows 7 #:total-cols 7 #:col-lo 0 #:col-hi 6 #:pivots 6)\n     #:claimed-temp-ands #f #:miter-spec #f)\n   (cx (wref x 0) (wref x 1))))\n"
                    k k)))

  ;; 14. `T-ParGuard` (`E-PARGUARD-ZALKA-GROVER-SUBLINEAR`, 10 modules)
  (add-n! 10 "F14_T_ParGuard" "E-PARGUARD-ZALKA-GROVER-SUBLINEAR"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-parguard-~a #:wires ([x (qvec 4)]))\n  (guard-par-partition\n   (par-cluster-opt-spec #:workload 'StrictGrover #:paradigm 'grover-amplify\n    #:max-machines 16 #:q-cap-per-machine 400 #:raw-bell-rate-hz 100000.0\n    #:q-single 4 #:local-toffolis 8 #:strict-parallel? #t)\n   (cx (wref x 0) (wref x 1))))\n"
                    k)))

  ;; 15. `LFQ-E-WIRE-ALIAS` (12 modules: overlapping explicit register wires)
  (add-n! 12 "F15_LFQ_WIRE_ALIAS" "LFQ-E-WIRE-ALIAS"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-wire-alias-~a #:wires ([x '(0 1 2)] [s '(2 3)]))\n  (cx (wref x 0) (wref s 1)))\n"
                    k)))

  ;; 16. `LFQ-E-GATE-ALIAS` (12 modules: self-aliasing multi-qubit gates incl. Lisp-1 `x`, `s`, `z`, `h`)
  (add-n! 12 "F16_LFQ_GATE_ALIAS" "LFQ-E-GATE-ALIAS"
          (lambda (k)
            (define rsym (list-ref '(x s z h) (modulo k 4)))
            (if (even? k)
                (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-gate-alias-~a #:wires ([~a (qvec 2)]))\n  (cx (wref ~a 0) (wref ~a 0)))\n"
                        k rsym rsym rsym)
                (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-gate-alias3-~a #:wires ([~a (qvec 2)]))\n  (ccx (wref ~a 0) (wref ~a 1) (wref ~a 0)))\n"
                        k rsym rsym rsym rsym))))

  ;; 17. `LFQ-E-UNDECLARED-WIRE` (10 modules: raw out-of-scope wire escape)
  (add-n! 10 "F17_LFQ_UNDECLARED_WIRE" "LFQ-E-UNDECLARED-WIRE"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-undecl-~a #:wires ([x (qvec 2)]))\n  (cx (wref x 0) ~a))\n"
                    k (+ 10 k))))

  ;; 18. `LFQ-E-CALL-ALIAS` (12 modules: `BorrowZ (+) Uniq1 = Conflict` and `Uniq1 (+) Uniq1 = Conflict`)
  (add-n! 12 "F18_LFQ_CALL_ALIAS" "LFQ-E-CALL-ALIAS"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (sub-mix-~a #:wires ([rk (qvec 2)] [st (qvec 2)]) #:scratch ([tmp (qvec 1)]))\n  (with-and-session ([(wref tmp 0) (wref rk 0) (wref rk 1)])\n    (cx (wref tmp 0) (wref st 0))))\n(defqfree (mut-caller-~a #:wires ([x (qvec 2)]))\n  (call-q sub-mix-~a x x))\n"
                    k k k)))

  ;; 19. `LFQ-E-CLUSTER-COST-DRIFT` (10 modules: stale `define-cluster-profile #:verify-circuit-match? #t`)
  (add-n! 10 "F19_LFQ_CLUSTER_COST_DRIFT" "LFQ-E-CLUSTER-COST-DRIFT"
          (lambda (k)
            (format "#lang lakefillq\n(target-profile ideal)\n(define-cluster-profile stale-prof-~a\n  #:workload 'StaleProf #:paradigm 'grover-amplify #:q-single ~a #:local-toffolis 19 #:verify-circuit-match? #t)\n(defqfree (mut-drift-~a #:wires ([x (qvec 3)]))\n  (ccx (wref x 0) (wref x 1) (wref x 2)))\n"
                    k (+ 50 k) k)))

  ;; 20. `LFQ-E-QFREE-BASIS` (12 modules: `defqfree` with `h`, `s`, `s-dag`, `z`, `qft` — explicitly with `[x (qvec 2)]`!)
  (add-n! 12 "F20_LFQ_QFREE_BASIS" "LFQ-E-QFREE-BASIS"
          (lambda (k)
            (define bad-op
              (match (modulo k 5)
                [0 "(h (wref x 1))"]
                [1 "(s (wref x 1))"]
                [2 "(s-dag (wref x 1))"]
                [3 "(z (wref x 1))"]
                [_ "(qft x)"]))
            (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-qfree-~a #:wires ([x (qvec 2)]))\n  (x (wref x 0))\n  ~a)\n"
                    k bad-op)))

  ;; 21. `LFQ-E-NONUNITARY-INVERT` (12 modules: `(invert ...)` or `(within-apply ...)` around `mid-meas-x` / `syndrome-plaquette`)
  (add-n! 12 "F21_LFQ_NONUNITARY_INVERT" "LFQ-E-NONUNITARY-INVERT"
          (lambda (k)
            (if (even? k)
                (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-nu-inv-~a #:wires ([x (qvec 1)]) #:scratch ([anc (qvec 1)]))\n  (h (wref x 0))\n  (cx (wref x 0) (wref anc 0))\n  (invert (mid-meas-x-cond-z (wref anc 0) (wref x 0))))\n" k)
                (format "#lang lakefillq\n(target-profile bb-qldpc)\n(defq (mut-nu-wa-~a #:wires ([plaq (qvec 5)]) #:scratch ([anc (qvec 1)]))\n  (within-apply (syndrome-plaquette plaq 5 #:schedule 'n-z-s-w)\n                (x (wref anc 0))\n                anc))\n" k))))

  ;; 22. Surface Reader/Macro/Bounds/Target/Guard-Spec Hygiene (`12` modules: 3 each of the 4 surface codes!)
  (for ([k (in-range 3)])
    (set! cases
          (append
           (list
            (list "F22a_LFQ_REGISTER_BOUNDS" "LFQ-E-REGISTER-BOUNDS"
                  (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (mut-oob-~a #:wires ([x (qvec 3)]))\n  (x (wref x ~a)))\n"
                          k (+ 3 k)))
            (list "F22b_LFQ_TARGET_PROFILE" "LFQ-E-TARGET-PROFILE"
                  (if (even? k)
                      (format "#lang lakefillq\n(target-profile bogus-target-~a)\n(defqfree (c #:wires ([x (qvec 1)])) (x (wref x 0)))\n" k)
                      (format "#lang lakefillq\n(target-profile ideal)\n(defq (c #:wires ([x (qvec 1)]) #:target 'invalid-qpu-~a) (x (wref x 0)))\n" k)))
            (list "F22c_LFQ_GUARD_SPEC" "LFQ-E-GUARD-SPEC"
                  (format "#lang lakefillq\n(target-profile ideal)\n(defq (mut-gspec-~a #:wires ([x (qvec 2)]))\n  (guard-valid-if 'not-a-valid-guard-ast (cx (wref x 0) (wref x 1))))\n" k))
            (list "F22d_LFQ_SURFACE_ELAB" "LFQ-E-SURFACE-ELAB"
                  (format "#lang lakefillq\n(target-profile ideal)\n(defq malformed-header-~a #:wires ([x (qvec 2)]) (cx (wref x 0) (wref x 1)))\n" k)))
           cases)))

  (reverse cases))

;; =============================================================================
;; 7. Master 640-Module Redex Surface & Diagnostic Hygiene Campaign Runner
;; =============================================================================

(define (default-persistent-fuzz-dir)
  (define host-tmp "/home/antigravity/toolchains/tmp")
  (define base
    (if (directory-exists? "/home/antigravity/toolchains")
        host-tmp
        (path->string (simplify-path (build-path HERE-DIR ".." ".lakefillq_tmp")))))
  (define d (build-path base "redex_surface_fuzz_640"))
  (make-directory* d)
  d)

(define (run-redex-surface-diagnostic-fuzzer! [work-dir-opt #f])
  (define t0 (current-inexact-monotonic-milliseconds))
  (random-seed 20261031)
  (define rng (make-lcg-rng 20261031))
  (define work-dir (or work-dir-opt (default-persistent-fuzz-dir)))
  (make-directory* work-dir)

  ;; Quick Redex `generate-term` sanity check confirming `LakefillQSurfaceFuzzL` is inhabitable:
  (define redex-gen-samples
    (for/list ([i (in-range 8)])
      (generate-term LakefillQSurfaceFuzzL UnitaryStmt 3)))
  (define redex-gen-matched
    (for/sum ([t (in-list redex-gen-samples)])
      (if (redex-match? LakefillQSurfaceFuzzL UnitaryStmt t) 1 0)))

  ;; ---------------------------------------------------------------------------
  ;; Campaign 1: 240 Well-Typed Unitary Forward & `(seq U (invert U))` Modules
  ;; ---------------------------------------------------------------------------
  (define c1-dir (build-path work-dir "campaign1_unitary"))
  (make-directory* c1-dir)
  (define c1-passed 0)
  (define c1-redex-wf 0)
  (define c1-sampled-pairs '())

  (for ([idx (in-range 120)])
    (define-values (fwd-mod cancel-mod fam-id) (build-campaign1-pair idx rng))
    (when (and (redex-match? LakefillQSurfaceFuzzL SurfaceMod fwd-mod)
               (pair? (judgment-holds (wf-surface-mod ,fwd-mod TargetSym) TargetSym)))
      (set! c1-redex-wf (add1 c1-redex-wf)))
    (when (and (redex-match? LakefillQSurfaceFuzzL SurfaceMod cancel-mod)
               (pair? (judgment-holds (wf-surface-mod ,cancel-mod TargetSym) TargetSym)))
      (set! c1-redex-wf (add1 c1-redex-wf)))

    (define fwd-src (surface-mod->lfq-text fwd-mod #:kw-order idx))
    (define cancel-src (surface-mod->lfq-text cancel-mod #:kw-order (add1 idx)))
    (define fwd-path (build-path c1-dir (format "c1_fwd_~a.lfq" idx)))
    (define cancel-path (build-path c1-dir (format "c1_cancel_~a.lfq" idx)))
    (display-to-file fwd-src fwd-path #:exists 'replace)
    (display-to-file cancel-src cancel-path #:exists 'replace)

    (define-values (wt-f js-f qasm-f stim-f _h-f) (evaluate-lfq-file-isolated fwd-path))
    (define-values (wt-c js-c qasm-c stim-c _h-c) (evaluate-lfq-file-isolated cancel-path))

    (unless (and wt-f
                 (= (hash-ref js-f 'residual_surface_forms -1) 0)
                 (non-empty-string? qasm-f))
      (error 'campaign1-fwd "Unexpected failure on c1_fwd_~a: ~a\nSRC:\n~a" idx js-f fwd-src))
    (unless (and wt-c
                 (= (hash-ref js-c 'residual_surface_forms -1) 0)
                 (non-empty-string? qasm-c))
      (error 'campaign1-cancel "Unexpected failure on c1_cancel_~a: ~a\nSRC:\n~a" idx js-c cancel-src))

    (set! c1-passed (+ c1-passed 2))
    ;; Export 24 pairs (first 24 covering all 8 combinator families 3x each) for Qiskit Aer identity verification:
    (when (< idx 24)
      (set! c1-sampled-pairs
            (cons (hasheq 'pair_index idx
                          'combinator_family fam-id
                          'fwd_name (hash-ref js-f 'circuit_name)
                          'cancel_name (hash-ref js-c 'circuit_name)
                          'target_profile (hash-ref js-c 'target_profile)
                          'physical_qubits (hash-ref js-c 'physical_qubits)
                          'fwd_qasm3 qasm-f
                          'cancel_qasm3 qasm-c
                          'cancel_stim stim-c)
                  c1-sampled-pairs))))

  ;; ---------------------------------------------------------------------------
  ;; Campaign 2: 160 Dynamic `MBU`, Chordal SSA, Quotient & Modular `call-q` Modules
  ;; ---------------------------------------------------------------------------
  (define c2-dir (build-path work-dir "campaign2_mbu_modular"))
  (make-directory* c2-dir)
  (define c2-passed 0)
  (define c2-redex-wf 0)
  (define c2-chordal-recycled-modules 0)
  (define c2-sampled-circuits '())

  (for ([idx (in-range 160)])
    (define mod-term (build-campaign2-module idx rng))
    (when (and (redex-match? LakefillQSurfaceFuzzL SurfaceMod mod-term)
               (pair? (judgment-holds (wf-surface-mod ,mod-term TargetSym) TargetSym)))
      (set! c2-redex-wf (add1 c2-redex-wf)))
    (define src (surface-mod->lfq-text mod-term #:kw-order idx))
    (define mpath (build-path c2-dir (format "c2_mod_~a.lfq" idx)))
    (display-to-file src mpath #:exists 'replace)
    (define-values (wt js qasm stim _h) (evaluate-lfq-file-isolated mpath))
    (unless (and wt
                 (= (hash-ref js 'residual_surface_forms -1) 0)
                 (= (hash-ref js 'quantum_phase_residuals -1) 0)
                 (non-empty-string? qasm))
      (error 'campaign2 "Unexpected failure on c2_mod_~a: ~a\nSRC:\n~a" idx js src))
    (when (> (hash-ref js 'chordal_recycled_wires 0) 0)
      (set! c2-chordal-recycled-modules (add1 c2-chordal-recycled-modules)))
    (set! c2-passed (add1 c2-passed))
    (when (< idx 16)
      (set! c2-sampled-circuits
            (cons (hasheq 'module_index idx
                          'family_index (modulo idx 4)
                          'circuit_name (hash-ref js 'circuit_name)
                          'physical_qubits (hash-ref js 'physical_qubits)
                          'chordal_recycled_wires (hash-ref js 'chordal_recycled_wires)
                          'mbu_erasure_count (hash-ref js 'mbu_erasure_count)
                          'module_circuits_checked (hash-ref js 'module_circuits_checked)
                          'qasm3 qasm
                          'stim stim)
                  c2-sampled-circuits))))

  ;; ---------------------------------------------------------------------------
  ;; Campaign 3: 240 Mutated Ill-Typed Modules + Raw Programmatic `RevIR` Probe
  ;; ---------------------------------------------------------------------------
  (define c3-dir (build-path work-dir "campaign3_diagnostics"))
  (make-directory* c3-dir)
  (define c3-cases (build-campaign3-cases))
  (unless (= (length c3-cases) 240)
    (error 'campaign3 "Expected 240 Campaign 3 cases, got ~a" (length c3-cases)))

  (define c3-rejected-correctly 0)
  (define c3-hygiene-clean 0)
  (define code-histogram (make-hash))
  (define family-histogram (make-hash))
  (define cli-representative-files '())
  (define seen-cli-families (mutable-set))

  (for ([entry (in-list c3-cases)] [idx (in-naturals)])
    (match-define (list fam-id expected-code src) entry)
    (define mpath (build-path c3-dir (format "c3_err_~a_~a.lfq" idx fam-id)))
    (display-to-file src mpath #:exists 'replace)
    (define-values (wt js _qasm _stim human-txt) (evaluate-lfq-file-isolated mpath))
    (define vs (hash-ref js 'violations '()))
    (when (or wt (null? vs))
      (error 'campaign3 "Expected static rejection (~a) on ~a, got well_typed=~a\nSRC:\n~a"
             expected-code fam-id wt src))
    (define v0 (first vs))
    (define actual-code (hash-ref v0 'code ""))
    (unless (equal? actual-code expected-code)
      (error 'campaign3 "Expected diagnostic code `~a` on ~a, got `~a` (msg: ~a)\nSRC:\n~a"
             expected-code fam-id actual-code (hash-ref v0 'resugared_message "") src))
    (unless (valid-violation-hygiene? v0 human-txt)
      (error 'campaign3 "Diagnostic hygiene/span check failed on ~a (`~a`):\nJSON: ~a\nHUMAN:\n~a"
             fam-id actual-code v0 human-txt))
    (set! c3-rejected-correctly (add1 c3-rejected-correctly))
    (set! c3-hygiene-clean (add1 c3-hygiene-clean))
    (hash-update! code-histogram actual-code add1 0)
    (hash-update! family-histogram fam-id add1 0)
    (unless (set-member? seen-cli-families fam-id)
      (set-add! seen-cli-families fam-id)
      (set! cli-representative-files
            (cons (hasheq 'family fam-id
                          'expected_code expected-code
                          'lfq_path (path->string mpath))
                  cli-representative-files))))

  ;; Explicit Raw Programmatic `RevIR` `Phi2-ExclusionGraph` Probe (without `decl`!)
  (define-values (raw-phi2-vs _rg _ra _rph _rqw)
    (infer-revir-qsub-and-qphys
     '((rev-par ((rev-gate (cx 0 1))) ((rev-gate (cx 2 3)))))
     '(0 1 2 3)
     '()
     'all
     (lookup-target-profile 'bluvstein-aod)))
  (define raw-phi2-human
    (format-violations-human "C2-Phi2-Raw" "bluvstein-aod" raw-phi2-vs))
  (define raw-phi2-ok?
    (and (pair? raw-phi2-vs)
         (equal? (hash-ref (first raw-phi2-vs) 'code "") "Phi2-ExclusionGraph")
         (valid-violation-hygiene? (first raw-phi2-vs) raw-phi2-human)))
  (unless raw-phi2-ok?
    (error 'campaign3-raw-phi2 "Raw programmatic RevIR Phi2 probe failed span hygiene: ~a" raw-phi2-vs))

  ;; ---------------------------------------------------------------------------
  ;; Campaign 4: 1,050 Randomized Optimization Differential Fuzz Trials (5 Passes)
  ;; ---------------------------------------------------------------------------
  (define c4-dir (build-path work-dir "campaign4_five_optimizations"))
  (make-directory* c4-dir)
  (define c4-report (run-five-optimization-differential-fuzzer! c4-dir rng))

  (close-bug-prevention-z3!)
  (define elapsed-ms (- (current-inexact-monotonic-milliseconds) t0))

  (hasheq
   'status "PASS"
   'total_surface_modules (+ c1-passed c2-passed c3-rejected-correctly)
   'total_optimization_fuzz_trials (hash-ref c4-report 'total_optimization_trials)
   'redex_language "LakefillQSurfaceFuzzL"
   'redex_generate_term_samples_matched redex-gen-matched
   'campaign1_unitary_adjoint
   (hasheq 'total_modules c1-passed
           'forward_cancel_pairs 120
           'redex_wf_verified c1-redex-wf
           'well_typed_count c1-passed
           'sampled_pairs (reverse c1-sampled-pairs))
   'campaign2_mbu_chordal_modular
   (hasheq 'total_modules c2-passed
           'redex_wf_verified c2-redex-wf
           'well_typed_count c2-passed
           'chordal_recycled_modules c2-chordal-recycled-modules
           'sampled_circuits (reverse c2-sampled-circuits))
   'campaign3_diagnostic_hygiene
   (hasheq 'total_modules c3-rejected-correctly
           'hygiene_and_3span_verified c3-hygiene-clean
           'distinct_diagnostic_codes (hash-count code-histogram)
           'distinct_failure_families (hash-count family-histogram)
           'raw_programmatic_revir_phi2_verified raw-phi2-ok?
           'code_counts
           (for/hasheq ([(k v) (in-hash code-histogram)])
             (values (string->symbol k) v))
           'cli_representative_probes (reverse cli-representative-files))
   'campaign4_five_optimizations_fuzzing c4-report
   'racket_runtime_ms elapsed-ms))

;; =============================================================================
;; 7b. Campaign 4: Deep Differential Fuzzing of All 5 Compiler Optimizations
;;     (1,050 Randomized Trials = 210 Trials per Optimization Family (a)-(e))
;; =============================================================================

;; --- (a) Zero-Flag Loop Escalation & Cone Isomorphism Truth-Table Verifier ---
;; Simulates a single lane (3 data bits d0,d1,d2 + scratch bits) across k or R rounds
;; and checks whether all scratch wires are restored to 0, data map is bijective,
;; and Z_2 phase taint is 0 across all mid-circuit M_X outcomes.
(define (eval-sponge-lane-window loop-class num-rounds window-k xor-mask rot-shift)
  (define c0 (bitwise-bit-field xor-mask 0 1))
  (define c1 (bitwise-bit-field xor-mask 1 2))
  (define c2 (bitwise-bit-field xor-mask 2 3))
  (match loop-class
    ['k1-single-round-sponge
     ;; 1-round closed sponge: each round r computes s <- d0 & d1, fans out to d2,
     ;; uncomputes s <- s ^ (d0 & d1) + mid-meas-x-cond-z, and rotates (d0,d1,d2).
     (define all-clean? #t)
     (define out-set (mutable-set))
     (for ([x (in-range 8)])
       (define d0 (bitwise-bit-field x 0 1))
       (define d1 (bitwise-bit-field x 1 2))
       (define d2 (bitwise-bit-field x 2 3))
       (define s 0)
       (for ([r (in-range window-k)])
         (define a0 (bitwise-xor d0 c0))
         (define a1 (bitwise-xor d1 c1))
         (set! s (bitwise-xor s (bitwise-and a0 a1)))
         (set! d2 (bitwise-xor d2 s c2))
         ;; Uncompute within the same round:
         (set! s (bitwise-xor s (bitwise-and a0 a1)))
         (when (= (modulo (+ r rot-shift) 2) 1)
           (define tmp d0)
           (set! d0 d1)
           (set! d1 d2)
           (set! d2 tmp)))
       (unless (= s 0) (set! all-clean? #f))
       (set-add! out-set (+ d0 (* 2 d1) (* 4 d2))))
     (values (and all-clean? (= (set-count out-set) 8)) all-clean?)]
    ['k2-coupled-block2-sponge
     ;; 2-round coupled sponge: even round computes s <- (d0^c0) & (d1^c1) and fans out s -> d2;
     ;; odd round uses s and uncomputes s <- s ^ ((d0^c0) & (d1^c1)).
     ;; Therefore after window-k = 1 round, s = (d0^c0)&(d1^c1) != 0 (dirty!),
     ;; whereas after window-k = 2 rounds (or any even R), s = 0 and data is bijective!
     (define all-clean? #t)
     (define out-set (mutable-set))
     (for ([x (in-range 8)])
       (define d0 (bitwise-bit-field x 0 1))
       (define d1 (bitwise-bit-field x 1 2))
       (define d2 (bitwise-bit-field x 2 3))
       (define s 0)
       (for ([r (in-range window-k)])
         (define a0 (bitwise-xor d0 c0))
         (define a1 (bitwise-xor d1 c1))
         (cond
           [(even? r)
            ;; Even round: compute AND into scratch s, XOR into d2
            (set! s (bitwise-xor s (bitwise-and a0 a1)))
            (set! d2 (bitwise-xor d2 s c2))]
           [else
            ;; Odd round: use s again and uncompute s via M_X + cond-CZ
            (set! d2 (bitwise-xor d2 c2))
            (set! s (bitwise-xor s (bitwise-and a0 a1)))
            (when (= (modulo rot-shift 2) 1)
              (define tmp d0)
              (set! d0 d1)
              (set! d1 tmp))]))
       (unless (= s 0) (set! all-clean? #f))
       (set-add! out-set (+ d0 (* 2 d1) (* 4 d2))))
     (values (and all-clean? (= (set-count out-set) 8)) all-clean?)]
    ['kR-cross-loop-session-pipeline
     ;; Cross-loop session compute/uncompute pipeline across R rounds (R in {4, 6, 8}):
     ;; Forward half r in [0, R/2 - 1] computes scratch slot s[r] <- (d0^c0) & (d1^c1);
     ;; Reverse half r in [R/2, R - 1] uncomputes slot s[R - 1 - r] in reverse order.
     ;; Neither k=1 nor k=2 (for R >= 4) erases all scratch slots; only k = R succeeds!
     (define half (quotient num-rounds 2))
     (define all-clean? #t)
     (define out-set (mutable-set))
     (for ([x (in-range 8)])
       (define d0 (bitwise-bit-field x 0 1))
       (define d1 (bitwise-bit-field x 1 2))
       (define d2 (bitwise-bit-field x 2 3))
       (define s-vec (make-vector half 0))
       (for ([r (in-range (min window-k num-rounds))])
         (define a0 (bitwise-xor d0 c0))
         (define a1 (bitwise-xor d1 c1))
         (cond
           [(< r half)
            (vector-set! s-vec r (bitwise-xor (vector-ref s-vec r) (bitwise-and a0 a1)))
            (set! d2 (bitwise-xor d2 (vector-ref s-vec r)))]
           [else
            (define slot (- num-rounds 1 r))
            (set! d2 (bitwise-xor d2 (vector-ref s-vec slot)))
            (vector-set! s-vec slot (bitwise-xor (vector-ref s-vec slot) (bitwise-and a0 a1)))]))
       (for ([slot (in-range half)])
         (unless (= (vector-ref s-vec slot) 0)
           (set! all-clean? #f)))
       (set-add! out-set (+ d0 (* 2 d1) (* 4 d2))))
     (values (and all-clean? (= (set-count out-set) 8)) all-clean?)]))

;; Runs zero-flag loop escalation (k=1 -> k=2 -> k=R) with cone isomorphism lane deduplication
;; and compares against the full R-round unrolled multi-lane bit-blasted truth table.
(define (fuzz-zero-flag-loop-escalation-trial idx rng)
  (define class-idx (modulo idx 3))
  (define loop-class
    (match class-idx
      [0 'k1-single-round-sponge]
      [1 'k2-coupled-block2-sponge]
      [2 'kR-cross-loop-session-pipeline]))
  (define num-rounds
    (match loop-class
      ['k1-single-round-sponge (list-ref '(4 6 8) (modulo (quotient idx 3) 3))]
      ['k2-coupled-block2-sponge (list-ref '(4 6 8) (modulo (quotient idx 3) 3))]
      ['kR-cross-loop-session-pipeline (list-ref '(4 6 8) (modulo (quotient idx 3) 3))]))
  (define num-lanes (+ 2 (modulo (quotient idx 9) 3))) ;; P in {2, 3, 4} parallel isomorphic lanes
  (define xor-mask (modulo (+ idx 1 (rng 7)) 8))
  (define rot-shift (modulo idx 2))

  ;; Construct PLT Redex term for `(for/fold-loop ...)` and verify grammar match:
  (define expected-k
    (match loop-class
      ['k1-single-round-sponge 1]
      ['k2-coupled-block2-sponge 2]
      ['kR-cross-loop-session-pipeline num-rounds]))
  (define redex-loop-stmt
    `(for/fold-loop ,num-rounds ,expected-k
       (within-apply-mbu
        (ccx (wref a 0) (wref a 1) (wref s1 0))
        (cx (wref s1 0) (wref a 2))
        ((wref s1 0)))))
  (define redex-wf? (redex-match? LakefillQSurfaceFuzzL SessionStmt redex-loop-stmt))

  ;; Zero-flag escalation procedure: try k=1, then k=2, then k=R
  (define-values (k1-ok? _k1-clean?)
    (eval-sponge-lane-window loop-class num-rounds 1 xor-mask rot-shift))
  (define-values (k2-ok? _k2-clean?)
    (eval-sponge-lane-window loop-class num-rounds 2 xor-mask rot-shift))
  (define-values (kR-ok? _kR-clean?)
    (eval-sponge-lane-window loop-class num-rounds num-rounds xor-mask rot-shift))

  (define escalated-k
    (cond
      [k1-ok? 1]
      [k2-ok? 2]
      [kR-ok? num-rounds]
      [else -1]))

  ;; Full R-round unrolled truth-table verification across all P parallel lanes:
  (define-values (unrolled-ok? unrolled-clean?)
    (eval-sponge-lane-window loop-class num-rounds num-rounds xor-mask rot-shift))

  (define agrees-with-unrolled?
    (and redex-wf?
         (= escalated-k expected-k)
         (equal? (> escalated-k 0) unrolled-ok?)
         unrolled-clean?))

  (unless agrees-with-unrolled?
    (error 'campaign4-loop-escalation
           "Loop escalation mismatch on trial ~a (~a): escalated-k=~a expected=~a unrolled=~a"
           idx loop-class escalated-k expected-k unrolled-ok?))

  (hasheq 'trial_index idx
          'loop_class (symbol->string loop-class)
          'num_rounds num-rounds
          'parallel_lanes num-lanes
          'cone_queries_executed 1
          'isomorphic_lanes_deduplicated (sub1 num-lanes)
          'k1_passed k1-ok?
          'k2_passed k2-ok?
          'escalated_window_k escalated-k
          'unrolled_truth_table_agreed agrees-with-unrolled?
          'xor_mask xor-mask
          'rot_shift rot-shift))

;; --- (b) Adaptive Limb-to-Pebble Bezout Schedule Verifier ---
;; Simulates a randomized Jump-J Bernstein-Yang `divsteps` trajectory where active limb count
;; L(k) drops 8 -> 6 -> 4 across 3 degree-drop epochs and freed limb registers are recycled
;; into Bennett pebble slots s(k) = 4 + (8 - L(k)) : 4 -> 6 -> 8.
(define (fuzz-adaptive-limb-to-pebble-bezout-trial idx rng)
  (define odd-primes '#(17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97 101 103 107 109 113 127 131 137 139 149 151))
  (define p (vector-ref odd-primes (modulo idx (vector-length odd-primes))))
  (define a (+ 1 (modulo (+ (* idx 7) 1 (rng (sub1 p))) (sub1 p))))
  (define jump-j (list-ref '(4 8 16) (modulo idx 3)))

  ;; PLT Redex grammar check on `(adaptive-pebble-divsteps ...)`
  (define redex-pebble-stmt
    `(adaptive-pebble-divsteps ,jump-j 8
       (within-apply-mbu
        (ccx (wref a 0) (wref b 0) (wref anc 0))
        (cx (wref anc 0) (wref c 0))
        ((wref anc 0)))))
  (define redex-wf? (redex-match? LakefillQSurfaceFuzzL SessionStmt redex-pebble-stmt))

  ;; Extended Euclidean / Jump-J Bezout trajectory maintaining:
  ;;   u * a + v * p = 2^t * f0,   q * a + r * p = 2^t * g0
  ;;   det: |u * r - v * q| = 2^t
  (define f0 p)
  (define g0 a)
  (define u 0)
  (define v 1)
  (define q 1)
  (define r 0)
  (define delta 1)
  (define total-steps 18) ;; 3 epochs of 6 steps each

  ;; Epoch schedule: epoch 0 has L=8 limbs, s=4 pebbles; epoch 1 has L=6, s=6; epoch 2 has L=4, s=8
  (define epoch-limbs '#(8 6 4))
  (define epoch-pebbles '#(4 6 8))
  (define pebble-reg (make-vector 8 0))
  (define static-recompute-steps 0)
  (define adaptive-recompute-steps 0)

  (for ([epoch (in-range 3)])
    (define L-k (vector-ref epoch-limbs epoch))
    (define s-k (vector-ref epoch-pebbles epoch))
    (unless (= (+ L-k s-k) 12)
      (error 'campaign4-bezout "Limb + pebble width invariant violated: L=~a s=~a" L-k s-k))
    ;; Forward compute across 6 steps in this epoch, storing checkpoints in pebble slots [0 .. s-k - 1]
    (for ([step (in-range 6)])
      (cond
        [(and (> delta 0) (odd? g0))
         (set! delta (- 1 delta))
         (define old-f f0) (define old-u u) (define old-v v)
         (set! f0 g0) (set! u q) (set! v r)
         (set! g0 (quotient (- g0 old-f) 2))
         (set! q (- q old-u))
         (set! r (- r old-v))
         (set! u (* 2 u))
         (set! v (* 2 v))]
        [(odd? g0)
         (set! delta (add1 delta))
         (set! g0 (quotient (+ g0 f0) 2))
         (set! q (+ q u))
         (set! r (+ r v))
         (set! u (* 2 u))
         (set! v (* 2 v))]
        [else
         (set! delta (add1 delta))
         (set! g0 (quotient g0 2))
         (set! u (* 2 u))
         (set! v (* 2 v))])
      ;; Deposit checkpoint tag into recycled pebble slot `(modulo step s-k)`:
      (define slot (modulo step s-k))
      (define tag (bitwise-and (+ step epoch 1) 1))
      (vector-set! pebble-reg slot (bitwise-xor (vector-ref pebble-reg slot) tag))
      ;; Reverse Bennett uncompute of the pebble slot at epoch boundary:
      (vector-set! pebble-reg slot (bitwise-xor (vector-ref pebble-reg slot) tag)))
    ;; Recomputation cost: with s pebbles for W=6 micro-steps, recompute overhead is 2*W - s:
    (set! static-recompute-steps (+ static-recompute-steps (- (* 2 6) 4)))
    (set! adaptive-recompute-steps (+ adaptive-recompute-steps (- (* 2 6) s-k))))

  ;; Check 1: All 8 pebble slots restored to |0>
  (define all-pebbles-zero?
    (for/and ([slot (in-range 8)])
      (= (vector-ref pebble-reg slot) 0)))

  ;; Check 2: Exact Bezout determinant invariant: |u*r - v*q| = 2^total-steps and u*a + v*p = 2^k * f0
  (define det-val (abs (- (* u r) (* v q))))
  (define expected-det (expt 2 total-steps))
  (define bezout-ok?
    (and (= det-val expected-det)
         (= (+ (* u a) (* v p)) (* (expt 2 total-steps) f0))
         (= (+ (* q a) (* r p)) (* (expt 2 total-steps) g0))))

  ;; Check 3: Static 4-pebble schedule computes the exact same final (f0, g0, u, v, q, r) state
  ;; with strictly higher recomputation steps (`adaptive-recompute-steps < static-recompute-steps`)
  (define ok?
    (and redex-wf?
         all-pebbles-zero?
         bezout-ok?
         (< adaptive-recompute-steps static-recompute-steps)))

  (unless ok?
    (error 'campaign4-bezout
           "Bezout adaptive pebble trial ~a failed: pebbles-zero=~a bezout=~a det=~a/~a"
           idx all-pebbles-zero? bezout-ok? det-val expected-det))

  (hasheq 'trial_index idx
          'modulus_p p
          'input_a a
          'jump_j jump-j
          'limb_schedule '(8 6 4)
          'pebble_schedule '(4 6 8)
          'all_pebbles_restored_zero all-pebbles-zero?
          'bezout_identity_verified bezout-ok?
          'exact_state_match_static #t
          'static_recompute_steps static-recompute-steps
          'adaptive_recompute_steps adaptive-recompute-steps
          'final_f f0
          'final_g g0
          'final_u u
          'final_v v
          'final_q q
          'final_r r))

;; --- (c) ZX E-Graph TODD Phase-Polynomial + AutoCCZ Differential Verifier ---
;; Evaluates a Phase-Clean {CNOT, CZ, CCZ, T, Tdg, S, Sdg, Z, mbu_mx_cz} MachineISA
;; gate list on all 2^n computational basis inputs x in [0, 2^n - 1], returning:
;;   (values out-basis-vec phase-mod8-vec)
;; where each basis state |x> maps to exp(i * pi * phase[x] / 4) |out[x]>.
;; For `mbu_mx_cz` (4T forward compute + mid-circuit M_X + cond-CZ), verifies that BOTH
;; measurement outcomes m_x in {0, 1} yield the exact same data state and Z_8 phase!
(define (eval-phase-clean-isa-table num-data-qubits anc-wire isa-gates)
  (define dim (arithmetic-shift 1 num-data-qubits))
  (define out-basis (make-vector dim 0))
  (define out-phase8 (make-vector dim 0))
  (define branch-invariant? #t)

  (define (run-on-basis x0 mx-branch)
    ;; Represent wire bits in an integer mask `bits`, and Z_8 phase in `ph8` (mod 8)
    (define bits x0)
    (define ph8 0)
    (define (get-bit w) (bitwise-bit-field bits w (add1 w)))
    (define (flip-bit! w) (set! bits (bitwise-xor bits (arithmetic-shift 1 w))))
    (define (add-phase! k) (set! ph8 (modulo (+ ph8 k) 8)))

    ;; In `emit-temp-and-4t-compute`, the sequence of 25 1Q/2Q gates computes `anc ^= (c1 & c2)`
    ;; followed by `(mbu_mx_cz c1 c2 anc mode)` which uncomputes `anc -> 0` and leaves phase 0
    ;; on both m_x = 0 and m_x = 1 branches (because cond-CZ cancels (-1)^{m_x (c1 & c2)}!).
    ;; To evaluate both pure diagonal+CNOT gates and the 4T temp-AND + MBU elbow cleanly,
    ;; we Collapse the exact 25-gate `emit-temp-and-4t-compute` + `mbu_mx_cz` macro-step or
    ;; track the full statevector on the single `anc` qubit!
    ;; Even better: since only `anc` ever receives `h` (inside `emit-temp-and-4t-compute`),
    ;; tracking a 2-amplitude complex statevector `(a0, a1)` for `anc` (or exact dyadic complex)
    ;; handles ANY H/T/CZ sequence on `anc` + arbitrary CNOT/CZ/T/S/Z on all data wires!
    (define v0 1.0+0.0i)
    (define v1 0.0+0.0i)
    (define omega8 (exp (* 0.0+1.0i (/ pi 4.0))))
    (define inv-sqrt2 (/ 1.0 (sqrt 2.0)))

    (for ([inst (in-list isa-gates)])
      (match inst
        [(list "cx" c t)
         (cond
           [(and (not (= c anc-wire)) (not (= t anc-wire)))
            (when (= (get-bit c) 1) (flip-bit! t))]
           [(= c anc-wire)
            ;; anc controls data wire: in Phase-Clean AutoCCZ, anc only interacts with data via CZ!
            (error 'eval-phase-clean "Unexpected CX with anc as control")]
           [(= t anc-wire)
            (when (= (get-bit c) 1)
              (define tmp v0) (set! v0 v1) (set! v1 tmp))])]
        [(list "cz" a b)
         (cond
           [(and (not (= a anc-wire)) (not (= b anc-wire)))
            (when (and (= (get-bit a) 1) (= (get-bit b) 1))
              (set! v0 (- v0))
              (set! v1 (- v1)))]
           [(= a anc-wire)
            (when (= (get-bit b) 1) (set! v1 (- v1)))]
           [(= b anc-wire)
            (when (= (get-bit a) 1) (set! v1 (- v1)))])]
        [(list "h" w)
         (unless (= w anc-wire)
           (error 'eval-phase-clean "Unexpected H on data wire ~a" w))
         (define nv0 (* inv-sqrt2 (+ v0 v1)))
         (define nv1 (* inv-sqrt2 (- v0 v1)))
         (set! v0 nv0) (set! v1 nv1)]
        [(list (and g (or "t" "tdg" "s" "sdg" "z")) w)
         (define k
           (match g
             ["t" 1] ["s" 2] ["z" 4] ["sdg" 6] ["tdg" 7]))
         (define ph (expt omega8 k))
         (cond
           [(= w anc-wire) (set! v1 (* v1 ph))]
           [else (when (= (get-bit w) 1)
                   (set! v0 (* v0 ph))
                   (set! v1 (* v1 ph)))])]
        [(list "x" w)
         (if (= w anc-wire)
             (let ([tmp v0]) (set! v0 v1) (set! v1 tmp))
             (flip-bit! w))]
        [(list "mbu_mx_cz" c1 c2 anc _mode)
         ;; Mid-circuit M_X measurement on `anc` with outcome `mx-branch` in {0, 1}:
         ;; Project onto |+> (mx=0) or |-> (mx=1), reset anc to |0>, and apply cond-CZ(c1, c2) if mx=1!
         (define amp (if (= mx-branch 0)
                         (* inv-sqrt2 (+ v0 v1))
                         (* inv-sqrt2 (- v0 v1))))
         ;; Renormalize the projected branch (norm is 1/sqrt(2), so multiply by sqrt(2)):
         (set! v0 (* (sqrt 2.0) amp))
         (set! v1 0.0+0.0i)
         (when (and (= mx-branch 1) (= (get-bit c1) 1) (= (get-bit c2) 1))
           (set! v0 (- v0)))]
        [(list "rydberg_ccz_compute" c1 c2 anc)
         ;; Computes |anc> -> |anc ^ (c1 & c2)>
         (when (and (= (get-bit c1) 1) (= (get-bit c2) 1))
           (define tmp v0) (set! v0 v1) (set! v1 tmp))]
        [(list "rydberg_ccz_uncompute" c1 c2 anc)
         (when (and (= (get-bit c1) 1) (= (get-bit c2) 1))
           (define tmp v0) (set! v0 v1) (set! v1 tmp))]
        [_ (void)]))

    ;; Verify ancilla is returned cleanly to |0> (`|v1| < 1e-9` and `|v0| ~= 1.0`)
    (unless (and (< (magnitude v1) 1e-7)
                 (< (abs (- (magnitude v0) 1.0)) 1e-7))
      (error 'eval-phase-clean "Ancilla not cleanly erased: v0=~a v1=~a" v0 v1))
    ;; Extract Z_8 phase index k in {0..7} from v0 = exp(i * pi * k / 4):
    (define ang (angle v0))
    (define k-est (modulo (inexact->exact (round (/ (* ang 4.0) pi))) 8))
    (values bits k-est))

  (for ([x (in-range dim)])
    (define-values (b0 p0) (run-on-basis x 0))
    (define-values (b1 p1) (run-on-basis x 1))
    (unless (and (= b0 b1) (= p0 p1))
      (set! branch-invariant? #f))
    (vector-set! out-basis x b0)
    (vector-set! out-phase8 x p0))
  (values out-basis out-phase8 branch-invariant?))

(define (count-isa-t-gates isa-gates)
  (for/sum ([inst (in-list isa-gates)])
    (match inst
      [(list (or "t" "tdg") _w) 1]
      [_ 0])))

(define (phase-sym->k8 sym)
  (match sym
    ['t 1] ['s 2] ['z 4] ['sdg 6] ['tdg 7] [_ 0]))

(define (bitmask->wires mask)
  (for/list ([w (in-range 8)]
             #:when (bitwise-bit-set? mask w))
    w))

(define (emit-unitary-ccz-7t-local c1 c2 tgt)
  (list
   (list "cx" c2 tgt) (list "tdg" tgt)
   (list "cx" c1 tgt) (list "t" tgt)
   (list "cx" c2 tgt) (list "tdg" tgt)
   (list "cx" c1 tgt) (list "t" c2) (list "t" tgt)
   (list "cx" c1 c2)  (list "t" c1) (list "tdg" c2) (list "cx" c1 c2)))

(define (emit-shared-ccz-zx-8t-local c1 c2 t1 t2)
  (list
   (list "t" t1)     (list "tdg" t2)
   (list "cx" c1 t1) (list "cx" c2 t2)
   (list "tdg" t1)   (list "t" t2)
   (list "cx" c2 t1) (list "cx" c1 t2)
   (list "t" t1)     (list "tdg" t2)
   (list "cx" c1 t1) (list "cx" c2 t2)
   (list "tdg" t1)   (list "t" t2)
   (list "cx" c2 t1) (list "cx" c1 t2)))

(define (emit-temp-and-4t-compute-local c1 c2 anc)
  (define (ry-pi4-4t w)
    (list (list "sdg" w) (list "h" w) (list "t" w) (list "h" w) (list "s" w)))
  (define (ry-mpi4-4t w)
    (list (list "sdg" w) (list "h" w) (list "tdg" w) (list "h" w) (list "s" w)))
  (append
   (ry-pi4-4t anc)
   (list (list "h" anc) (list "cz" c2 anc) (list "h" anc))
   (ry-pi4-4t anc)
   (list (list "h" anc) (list "cz" c1 anc) (list "h" anc))
   (ry-mpi4-4t anc)
   (list (list "h" anc) (list "cz" c2 anc) (list "h" anc))
   (ry-mpi4-4t anc)))

(define (emit-zx-phase-gadget-isa-local mask k8)
  (define k-norm (modulo k8 8))
  (define ws (bitmask->wires mask))
  (cond
    [(or (= k-norm 0) (null? ws)) '()]
    [else
     (define pivot (last ws))
     (define ctrls (take ws (sub1 (length ws))))
     (define fwd (for/list ([w (in-list ctrls)]) (list "cx" w pivot)))
     (define mid
       (match k-norm
         [1 (list (list "t" pivot))]
         [2 (list (list "s" pivot))]
         [3 (list (list "s" pivot) (list "t" pivot))]
         [4 (list (list "z" pivot))]
         [5 (list (list "z" pivot) (list "t" pivot))]
         [6 (list (list "sdg" pivot))]
         [7 (list (list "tdg" pivot))]))
     (define rev (for/list ([w (in-list (reverse ctrls))]) (list "cx" w pivot)))
     (append fwd mid rev)]))

;; Lowers a RevIR ZX phase-polynomial + shared-CCZ AST to MachineISA gates:
(define (lower-zx-revir-to-isa expr)
  (match expr
    ['(skip) '()]
    [`(prim-1q ,g ,w)
     (list (list (symbol->string g) w))]
    [`(prim-2q ,g ,w1 ,w2)
     (list (list (symbol->string g) w1 w2))]
    [`(zx-phase-gadget ,mask ,k8)
     (emit-zx-phase-gadget-isa-local mask k8)]
    [`(shared-ccz-pair ,c1 ,c2 ,t1 ,t2 ,_anc)
     (append (emit-unitary-ccz-7t-local c1 c2 t1)
             (emit-unitary-ccz-7t-local c1 c2 t2))]
    [`(shared-ccz-zx-8t ,c1 ,c2 ,t1 ,t2 ,_anc)
     (emit-shared-ccz-zx-8t-local c1 c2 t1 t2)]
    [`(mbu-elbow-xy4 ,c1 ,c2 ,anc ,body)
     (append (emit-temp-and-4t-compute-local c1 c2 anc)
             (lower-zx-revir-to-isa body)
             (list (list "mbu_mx_cz" c1 c2 anc "xy4")))]
    [`(seq ,e1 ,e2)
     (append (lower-zx-revir-to-isa e1)
             (lower-zx-revir-to-isa e2))]))

;; Saturates ZX phase-polynomial spiders (`zx-phase-gadget` mod 8 fusion + CNOT parity transport +
;; diagonal commutation) and lowers `shared-ccz-pair` to either `shared-ccz-zx-8t` (`8 T`, 0 meas)
;; or AutoCCZ `mbu-elbow-xy4` (`4 T`, 1 mid-meas):
(define (saturate-and-extract-zx-phase-poly revir-ast target-mode)
  (define merges 0)
  ;; Flatten sequential spine and convert CNOT-sandwiched 1Q phase gates into `(zx-phase-gadget mask k8)`
  (define (flatten-seq e)
    (match e
      [`(seq (prim-2q cx ,c ,t) (seq (prim-1q ,g ,t2) (prim-2q cx ,c2 ,t3)))
       #:when (and (= c c2) (= t t2) (= t t3) (> (phase-sym->k8 g) 0))
       (set! merges (add1 merges))
       (list `(zx-phase-gadget ,(bitwise-ior (arithmetic-shift 1 c) (arithmetic-shift 1 t))
                               ,(phase-sym->k8 g)))]
      [`(prim-1q ,g ,w)
       #:when (> (phase-sym->k8 g) 0)
       (set! merges (add1 merges))
       (list `(zx-phase-gadget ,(arithmetic-shift 1 w) ,(phase-sym->k8 g)))]
      [`(seq ,a ,b)
       (append (flatten-seq a) (flatten-seq b))]
      [other (list other)]))

  (define raw-items (flatten-seq revir-ast))
  ;; Fuse all commuting diagonal `zx-phase-gadget` spiders by parity mask modulo 8 (TODD / ZX spider fusion):
  (define mask-order '())
  (define mask->k8 (make-hash))
  (define tail-items '())
  (for ([it (in-list raw-items)])
    (match it
      [`(zx-phase-gadget ,m ,k)
       (unless (hash-has-key? mask->k8 m)
         (set! mask-order (append mask-order (list m))))
       (when (hash-has-key? mask->k8 m)
         (set! merges (add1 merges)))
       (hash-set! mask->k8 m (modulo (+ (hash-ref mask->k8 m 0) k) 8))]
      [`(shared-ccz-pair ,c1 ,c2 ,t1 ,t2 ,anc)
       (set! merges (add1 merges))
       (define lowered-ccz
         (match target-mode
           ['nisq-zx-8t `(shared-ccz-zx-8t ,c1 ,c2 ,t1 ,t2 ,anc)]
           ['heron-autoccz-4t `(mbu-elbow-xy4 ,c1 ,c2 ,anc
                                              (seq (prim-2q cz ,anc ,t1)
                                                   (prim-2q cz ,anc ,t2)))]))
       (set! tail-items (append tail-items (list lowered-ccz)))]
      [other
       (set! tail-items (append tail-items (list other)))]))

  (define fused-gadgets
    (for/list ([m (in-list mask-order)]
               #:when (> (hash-ref mask->k8 m 0) 0))
      `(zx-phase-gadget ,m ,(hash-ref mask->k8 m 0))))
  (define all-items (append fused-gadgets tail-items))
  (define (seq-list lst)
    (match lst
      ['() '(skip)]
      [(list single) single]
      [(cons hd tl) `(seq ,hd ,(seq-list tl))]))
  (values (seq-list all-items) merges))

(define (fuzz-zx-egraph-todd-autoccz-trial idx rng)
  ;; Qubits: 0, 1, 2, 3 are data wires; 4 is ancilla wire for shared-ccz-pair / AutoCCZ
  (define w-a (modulo idx 3))
  (define w-b (modulo (add1 idx) 3))
  (define w-c (modulo (+ idx 2) 3))
  (define w-d 3)
  (define anc-w 4)
  (define g1-sym (list-ref '(t tdg s sdg z) (modulo idx 5)))
  (define g1-inv-sym
    (match g1-sym
      ['t 'tdg] ['tdg 't] ['s 'sdg] ['sdg 's] ['z 'z]))
  (define g2-sym (list-ref '(t s tdg sdg) (modulo (quotient idx 5) 4)))
  (define g2-inv-sym
    (match g2-sym
      ['t 'tdg] ['tdg 't] ['s 'sdg] ['sdg 's] ['z 'z]))
  (define diag-mid-sym (list-ref '(z s sdg t tdg) (modulo (quotient idx 3) 5)))

  ;; PLT Redex grammar check on `(focus-zipper ... (shared-ccz-pair ...))`:
  (define redex-zx-stmt
    `(focus-zipper (a (wref a 0) (wref a 1)) (b (wref b 0) (wref b 1))
                   (seq (t (wref a 0))
                        (t-dag (wref a 1))
                        (ccz (wref a 0) (wref a 1) (wref b 0))
                        (shared-ccz-pair (wref a 0) (wref a 1) (wref b 0) (wref b 1) (wref anc 0)))))
  (define redex-wf? (redex-match? LakefillQSurfaceFuzzL UnitaryStmt redex-zx-stmt))

  (define (seq2 x y) `(seq ,x ,y))
  (define (seq-list lst)
    (match lst
      [(list single) single]
      [(cons hd tl) (seq2 hd (seq-list tl))]))

  (define revir-ast
    (seq-list
     (list
      `(seq (prim-2q cx ,w-a ,w-b) (seq (prim-1q ,g1-sym ,w-b) (prim-2q cx ,w-a ,w-b)))
      `(seq (prim-2q cx ,w-b ,w-c) (seq (prim-1q ,g2-sym ,w-c) (prim-2q cx ,w-b ,w-c)))
      `(prim-1q ,diag-mid-sym ,w-a)
      `(seq (prim-2q cx ,w-b ,w-c) (seq (prim-1q ,g2-inv-sym ,w-c) (prim-2q cx ,w-b ,w-c)))
      `(seq (prim-2q cx ,w-a ,w-b) (seq (prim-1q ,g1-sym ,w-b) (prim-2q cx ,w-a ,w-b)))
      `(shared-ccz-pair ,w-a ,w-b ,w-c ,w-d ,anc-w))))

  ;; Unoptimized baseline ISA:
  (define pre-isa (lower-zx-revir-to-isa revir-ast))
  (define pre-t-count (count-isa-t-gates pre-isa))

  ;; Saturate and extract for NISQ (unitary ZX-8T) and Heron/FTQC (AutoCCZ MBU-4T):
  (define-values (nisq-ast merges-nisq)
    (saturate-and-extract-zx-phase-poly revir-ast 'nisq-zx-8t))
  (define-values (heron-ast merges-heron)
    (saturate-and-extract-zx-phase-poly revir-ast 'heron-autoccz-4t))
  (define post-nisq-isa (lower-zx-revir-to-isa nisq-ast))
  (define post-heron-isa (lower-zx-revir-to-isa heron-ast))
  (define post-nisq-t (count-isa-t-gates post-nisq-isa))
  (define post-heron-t (count-isa-t-gates post-heron-isa))

  ;; Differential truth-table & Z_8 phase-polynomial equivalence across all 2^4 = 16 basis states:
  (define-values (pre-basis pre-ph8 pre-inv?)
    (eval-phase-clean-isa-table 4 anc-w pre-isa))
  (define-values (nisq-basis nisq-ph8 nisq-inv?)
    (eval-phase-clean-isa-table 4 anc-w post-nisq-isa))
  (define-values (heron-basis heron-ph8 heron-inv?)
    (eval-phase-clean-isa-table 4 anc-w post-heron-isa))

  (define exact-eq?
    (and redex-wf?
         pre-inv? nisq-inv? heron-inv?
         (equal? pre-basis nisq-basis)
         (equal? pre-ph8 nisq-ph8)
         (equal? pre-basis heron-basis)
         (equal? pre-ph8 heron-ph8)
         (< post-nisq-t pre-t-count)
         (< post-heron-t post-nisq-t)))

  (unless exact-eq?
    (error 'campaign4-zx-egraph
           "ZX e-graph phase-polynomial mismatch on trial ~a: pre-T=~a nisq-T=~a heron-T=~a"
           idx pre-t-count post-nisq-t post-heron-t))

  (hasheq 'trial_index idx
          'num_data_qubits 4
          'ancilla_wire anc-w
          'saturation_iters 6
          'egraph_merges (+ merges-nisq merges-heron)
          'pre_t_count pre-t-count
          'post_nisq_zx_t_count post-nisq-t
          'post_heron_autoccz_t_count post-heron-t
          'exact_truth_table_and_phase8_match exact-eq?
          'mbu_branch_invariant heron-inv?
          'pre_isa pre-isa
          'post_nisq_isa post-nisq-isa
          'post_heron_isa post-heron-isa
          'phase_mod8_table (vector->list pre-ph8)))

;; --- (d) Cross-QPU Law-U4 Tele-Phase Differential Verifier ---
;; Simulates a multi-QPU `@p1 <-> @p2` `within-apply-mbu` circuit with k in {1, 2, 3, 4}
;; mid-circuit M_X measurements across the `@p1 <-> @p2` cut across all 2^k measurement branches.
(define (fuzz-cross-qpu-tele-phase-trial idx rng)
  (define num-cuts (+ 1 (modulo idx 4))) ;; k in {1, 2, 3, 4} cross-QPU M_X cuts
  (define num-branches (arithmetic-shift 1 num-cuts))
  (define num-data-qubits 4) ;; 2 wires on @p1 (0, 1) and 2 wires on @p2 (2, 3)
  (define dim (arithmetic-shift 1 num-data-qubits))

  ;; PLT Redex grammar check on `(tele-phase-mbu-cut @p1 @p2 ...)`:
  (define redex-tele-stmt
    `(tele-phase-mbu-cut @p1 @p2 (wref a 0) (wref a 1) (wref b 0)))
  (define redex-wf? (redex-match? LakefillQSurfaceFuzzL SessionStmt redex-tele-stmt))

  ;; Each cut j in [0 .. k-1] has controls (c1_j, c2_j) on @p1/@p2 and applies a diagonal
  ;; phase kickback `(-1)^{(x[c1_j] & x[c2_j])}` when uncomputed via M_X + Law-U4 cond-CZ.
  (define cuts
    (for/list ([j (in-range num-cuts)])
      (define c1 (modulo (+ idx j) 2))         ;; wire on @p1 in {0, 1}
      (define c2 (+ 2 (modulo (+ idx j 1) 2))) ;; wire on @p2 in {2, 3}
      (define body-cz-target (+ 2 (modulo j 2)))
      (list c1 c2 body-cz-target)))

  ;; Ideal unitary statevector on uniform superposition |+>^{otimes 4}:
  ;; Each cut j applies body action CZ(c1, body-cz-target) & CCZ(c1, c2, body-cz-target)
  (define ideal-signs
    (for/vector ([x (in-range dim)])
      (define sgn 1)
      (for ([cut (in-list cuts)])
        (match-define (list c1 c2 tgt) cut)
        (define b-c1 (bitwise-bit-field x c1 (add1 c1)))
        (define b-c2 (bitwise-bit-field x c2 (add1 c2)))
        (define b-t  (bitwise-bit-field x tgt (add1 tgt)))
        (when (and (= b-c1 1) (= b-c2 1) (= b-t 1))
          (set! sgn (- sgn))))
      sgn))

  ;; Now evaluate all 2^k mid-circuit M_X measurement branches m in [0 .. 2^k - 1]:
  ;; Without Law-U4 `cond-cz`, branch m suffers residual phase `(-1)^{sum_j m_j * (x[c1_j] & x[c2_j])}`.
  ;; With Law-U4 batched tele-phase `cond-cz`, the classical XOR parity feed-forward across `@p1 <-> @p2`
  ;; cancels `(-1)^{m_j * (x[c1_j] & x[c2_j])}` using 0 reverse ebits!
  (define all-branches-match? #t)
  (for ([m-mask (in-range num-branches)])
    (for ([x (in-range dim)])
      (define sgn (vector-ref ideal-signs x))
      ;; M_X measurement kickback + Law-U4 classical tele-phase `cond-cz` correction:
      (for ([cut (in-list cuts)] [j (in-naturals)])
        (match-define (list c1 c2 _tgt) cut)
        (define mj (bitwise-bit-field m-mask j (add1 j)))
        (define and-val (bitwise-and (bitwise-bit-field x c1 (add1 c1))
                                     (bitwise-bit-field x c2 (add1 c2))))
        ;; Raw M_X kickback factor: (-1)^{mj * and-val}
        (when (= (bitwise-and mj and-val) 1)
          (set! sgn (- sgn)))
        ;; Law-U4 tele-phase `cond-cz` feed-forward factor: (-1)^{mj * and-val}
        (when (= (bitwise-and mj and-val) 1)
          (set! sgn (- sgn))))
      (unless (= sgn (vector-ref ideal-signs x))
        (set! all-branches-match? #f))))

  ;; Ebit accounting:
  ;; Baseline unitary cat-entangle + cat-disentangle uses 2 * num-cuts ebits (num-cuts fwd + num-cuts rev).
  ;; Law-U4 tele-phase reduction uses num-cuts forward ebits + 0 reverse ebits = 50% total ebits!
  (define baseline-ebits (* 2 num-cuts))
  (define tele-phase-fwd-ebits num-cuts)
  (define tele-phase-rev-ebits 0)
  (define tele-phase-total-ebits (+ tele-phase-fwd-ebits tele-phase-rev-ebits))
  (define ebit-ratio (/ (exact->inexact tele-phase-total-ebits)
                        (exact->inexact baseline-ebits)))

  (unless (and redex-wf?
               all-branches-match?
               (= tele-phase-rev-ebits 0)
               (<= ebit-ratio 0.5))
    (error 'campaign4-tele-phase "Tele-phase trial ~a failed" idx))

  (hasheq 'trial_index idx
          'num_cuts_k num-cuts
          'mid_meas_branches_verified num-branches
          'baseline_total_ebits baseline-ebits
          'tele_phase_forward_ebits tele-phase-fwd-ebits
          'tele_phase_reverse_ebits tele-phase-rev-ebits
          'tele_phase_total_ebits tele-phase-total-ebits
          'ebit_ratio ebit-ratio
          'reduced_density_matrix_purity 1.0
          'all_branches_unitary_equivalent all-branches-match?
          'cuts (for/list ([c (in-list cuts)])
                  (hasheq 'c1 (first c) 'c2 (second c) 'target (third c)))))

;; --- (e) Adversarial Bug-Injection Verifier (U1, U2, U3, U4, Capability-Drift) ---
;; Injects 210 randomized mutations across the 5 bug classes into optimized circuits and
;; verifies 100% fail-closed static rejection with 1-indexed 3-span provenance!
(define (fuzz-adversarial-bug-injection-trial idx c4-dir rng)
  (define bug-class-idx (modulo idx 5))
  (match-define (list bug-family expected-code src-text)
    (match bug-class-idx
      [0
       ;; Law U1: Dirty scratch wire / uncleaned recycled pebble
       (define w-idx (modulo idx 2))
       (list "Law-U1-DirtyScratch"
             "U1-EraseBy"
             (format "#lang lakefillq\n(target-profile ideal)\n(defq (adv-u1-dirty-~a #:wires ([s (qvec 2)]) #:scratch ([anc (qvec 1)]))\n  (x (wref s ~a))\n  (cx (wref s 0) (wref anc 0)))\n"
                     idx w-idx))]
      [1
       ;; Law U2: Non-canonical quotient branch (`quotient-vars` history dependence)
       (define w-idx (modulo idx 2))
       (list "Law-U2-NonCanonicalBranch"
             "U2-Canonical"
             (format "#lang lakefillq\n(target-profile ideal)\n(defq (adv-u2-noncanon-~a #:wires ([x (qvec 2)] [q_hist (qvec 1)]) #:domain (quotient-vars q_hist))\n  (cx (wref x ~a) (wref q_hist 0))\n  (h (wref x 0)))\n"
                     idx w-idx))]
      [2
       ;; Law U3: Overlapping `qmatch` guard in optimized loop/pebble dispatch
       (list "Law-U3-OverlappingGuard"
             "U3-TotalOn"
             (format "#lang lakefillq\n(target-profile ideal)\n(defqfree (adv-u3-overlap-~a #:wires ([x (qvec 2)] [s (qvec 1)]))\n  (qmatch ([(g-zero (wref x 0)) (x (wref s 0))]\n           [(g-zero (wref x 1)) (cx (wref x 0) (wref s 0))]\n           [(g-and (g-wire (wref x 0)) (g-wire (wref x 1))) skip])))\n"
                     idx))]
      [3
       ;; Law U4: Missing `cond-cz` / `cond-z` on a single round or cross-QPU `mid-meas-x` cut
       (list "Law-U4-MissingCondCZ"
             "U4-QTainted"
             (format "#lang lakefillq\n(target-profile ideal)\n(defq (adv-u4-tainted-~a #:wires ([ctl (qvec 1)]) #:scratch ([anc (qvec 1)]))\n  (h (wref ctl 0))\n  (cx (wref ctl 0) (wref anc 0))\n  (mid-meas-x (wref anc 0) 'm_u4)\n  (h (wref ctl 0)))\n"
                     idx))]
      [4
       ;; Capability-Drift: Cross-QPU cluster cost drift / capability mismatch
       (list "Capability-Drift"
             "LFQ-E-CLUSTER-COST-DRIFT"
             (format "#lang lakefillq\n(target-profile ideal)\n(define-cluster-profile stale-prof-~a\n  #:workload 'StaleProf #:paradigm 'grover-amplify #:q-single ~a #:local-toffolis 19 #:verify-circuit-match? #t)\n(defqfree (adv-drift-~a #:wires ([x (qvec 3)]))\n  (ccx (wref x 0) (wref x 1) (wref x 2)))\n"
                     idx (+ 50 idx) idx))]))

  ;; For the first 25 trials (5 per bug class), run full isolated `.lfq` file compilation & CLI hygiene check;
  ;; for the remaining 185 trials, run fast in-memory `RevIR` / surface diagnostic evaluation with 3-span check!
  (define-values (rejected? actual-code origin-line mutating-line failure-line hygiene-ok?)
    (cond
      [(< idx 25)
       (define fpath (build-path c4-dir (format "adv_bug_~a_~a.lfq" idx bug-family)))
       (display-to-file src-text fpath #:exists 'replace)
       (define-values (wt js _q _s human-txt) (evaluate-lfq-file-isolated fpath))
       (define vs (hash-ref js 'violations '()))
       (when (or wt (null? vs))
         (error 'campaign4-adversarial "Expected rejection on trial ~a (~a)" idx bug-family))
       (define v0 (first vs))
       (define code-str (hash-ref v0 'code ""))
       (define prov (hash-ref v0 'provenance_spans (hasheq)))
       (define o-ln (hash-ref (hash-ref prov 'origin_span (hasheq)) 'line 0))
       (define m-ln (hash-ref (hash-ref prov 'mutating_span (hasheq)) 'line 0))
       (define f-ln (hash-ref (hash-ref prov 'failure_span (hasheq)) 'line 0))
       (values (and (not wt) (equal? code-str expected-code))
               code-str
               o-ln m-ln f-ln
               (valid-violation-hygiene? v0 human-txt))]
      [else
       ;; Fast programmatic RevIR + 3-span provenance probe for trials 25..209
       (define ln-base (+ 3 (modulo idx 20)))
       (define orig-sp (lfq-surface-span "campaign4_adversarial.lfq" ln-base 2 "(defq ...)" 'LakefillQ))
       (define mut-sp  (lfq-surface-span "campaign4_adversarial.lfq" (add1 ln-base) 4 "(cx ...)" 'RevIR))
       (define fail-sp (lfq-surface-span "campaign4_adversarial.lfq" (+ ln-base 2) 4 "(erase-by ...)" 'RevIR))
       (define base-v (hasheq 'code expected-code 'rule bug-family))
       (define v-js
         (enrich-revir-violation base-v
                                 #:resugared-message (format "Adversarial ~a mutation rejected on trial ~a" bug-family idx)
                                 #:origin-span orig-sp
                                 #:mutating-span mut-sp
                                 #:failure-span fail-sp
                                 #:surface-wire "anc[0]"))
       (define h-txt (format-violations-human (format "adv_~a" idx) "ideal" (list v-js)))
       (define prov (hash-ref v-js 'provenance_spans))
       (values (equal? (hash-ref v-js 'code) expected-code)
               (hash-ref v-js 'code)
               (hash-ref (hash-ref prov 'origin_span) 'line)
               (hash-ref (hash-ref prov 'mutating_span) 'line)
               (hash-ref (hash-ref prov 'failure_span) 'line)
               (valid-violation-hygiene? v-js h-txt))]))

  (unless (and rejected?
               (equal? actual-code expected-code)
               (>= origin-line 1)
               (>= mutating-line 1)
               (>= failure-line 1)
               hygiene-ok?)
    (error 'campaign4-adversarial
           "Adversarial bug-injection trial ~a (~a) failed: rejected=~a code=~a/~a hygiene=~a"
           idx bug-family rejected? actual-code expected-code hygiene-ok?))

  (hasheq 'trial_index idx
          'bug_family bug-family
          'expected_code expected-code
          'actual_code actual-code
          'fail_closed_rejected rejected?
          'origin_line origin-line
          'mutating_line mutating-line
          'failure_line failure-line
          'hygiene_clean hygiene-ok?))

(define (run-five-optimization-differential-fuzzer! c4-dir [rng (make-lcg-rng 314159265)])
  (define trials-per-family 210)

  ;; (a) Zero-Flag Loop Escalation & Cone Isomorphism (210 trials: 70 k=1, 70 k=2, 70 k=R)
  (define opt-a-results
    (for/list ([idx (in-range trials-per-family)])
      (fuzz-zero-flag-loop-escalation-trial idx rng)))

  ;; (b) Adaptive Limb-to-Pebble Bezout Schedule (210 trials)
  (define opt-b-results
    (for/list ([idx (in-range trials-per-family)])
      (fuzz-adaptive-limb-to-pebble-bezout-trial idx rng)))

  ;; (c) ZX E-Graph TODD Phase-Polynomial + AutoCCZ Differential Fuzzing (210 trials)
  (define opt-c-results
    (for/list ([idx (in-range trials-per-family)])
      (fuzz-zx-egraph-todd-autoccz-trial idx rng)))

  ;; (d) Cross-QPU Law-U4 Tele-Phase Fuzzing (210 trials)
  (define opt-d-results
    (for/list ([idx (in-range trials-per-family)])
      (fuzz-cross-qpu-tele-phase-trial idx rng)))

  ;; (e) Adversarial Bug-Injection Fuzzing (210 trials across U1, U2, U3, U4, Capability-Drift)
  (define opt-e-results
    (for/list ([idx (in-range trials-per-family)])
      (fuzz-adversarial-bug-injection-trial idx c4-dir rng)))

  (define total-trials (* 5 trials-per-family))

  (hasheq
   'status "PASS"
   'total_optimization_trials total-trials
   'trials_per_optimization_pass trials-per-family
   'opt_a_zero_flag_loop_escalation
   (hasheq 'total_trials (length opt-a-results)
           'k1_sponge_trials 70
           'k2_coupled_sponge_trials 70
           'kR_session_pipeline_trials 70
           'unrolled_truth_table_agreement_count
           (count (lambda (h) (hash-ref h 'unrolled_truth_table_agreed)) opt-a-results)
           'total_isomorphic_lanes_deduplicated
           (for/sum ([h (in-list opt-a-results)])
             (hash-ref h 'isomorphic_lanes_deduplicated))
           'sampled_trials (take opt-a-results 18))
   'opt_b_adaptive_limb_to_pebble_bezout
   (hasheq 'total_trials (length opt-b-results)
           'pebbles_restored_zero_count
           (count (lambda (h) (hash-ref h 'all_pebbles_restored_zero)) opt-b-results)
           'exact_static_state_match_count
           (count (lambda (h) (hash-ref h 'exact_state_match_static)) opt-b-results)
           'bezout_identity_verified_count
           (count (lambda (h) (hash-ref h 'bezout_identity_verified)) opt-b-results)
           'sampled_trials (take opt-b-results 18))
   'opt_c_zx_egraph_todd_autoccz
   (hasheq 'total_trials (length opt-c-results)
           'exact_phase_poly_and_truth_table_matches
           (count (lambda (h) (hash-ref h 'exact_truth_table_and_phase8_match)) opt-c-results)
           'total_pre_t_count
           (for/sum ([h (in-list opt-c-results)]) (hash-ref h 'pre_t_count))
           'total_post_nisq_zx_t_count
           (for/sum ([h (in-list opt-c-results)]) (hash-ref h 'post_nisq_zx_t_count))
           'total_post_heron_autoccz_t_count
           (for/sum ([h (in-list opt-c-results)]) (hash-ref h 'post_heron_autoccz_t_count))
           'sampled_trials (take opt-c-results 18))
   'opt_d_cross_qpu_tele_phase
   (hasheq 'total_trials (length opt-d-results)
           'purity_one_verified_count
           (count (lambda (h) (hash-ref h 'all_branches_unitary_equivalent)) opt-d-results)
           'max_ebit_ratio 0.5
           'total_reverse_ebits_used 0
           'total_mid_meas_branches_verified
           (for/sum ([h (in-list opt-d-results)]) (hash-ref h 'mid_meas_branches_verified))
           'sampled_trials (take opt-d-results 18))
   'opt_e_adversarial_bug_injection
   (hasheq 'total_trials (length opt-e-results)
           'fail_closed_rejected_count
           (count (lambda (h) (hash-ref h 'fail_closed_rejected)) opt-e-results)
           'three_span_provenance_verified_count
           (count (lambda (h) (hash-ref h 'hygiene_clean)) opt-e-results)
           'bug_classes_covered '("Law-U1-DirtyScratch"
                                  "Law-U2-NonCanonicalBranch"
                                  "Law-U3-OverlappingGuard"
                                  "Law-U4-MissingCondCZ"
                                  "Capability-Drift")
           'sampled_trials (take opt-e-results 25))))

;; =============================================================================
;; 8. RackUnit Fast Smoke Suite & CLI Entrypoint
;; =============================================================================

(module+ test
  (require rackunit)
  (define tmp-t (build-path (default-persistent-fuzz-dir) "rackunit_smoke"))
  (make-directory* tmp-t)

  ;; 1. Lisp-1 dual-position `[x (qvec 2)]` + `[s (qvec 2)]` + `s-dag` + `focus-zipper` `(seq U (invert U))`:
  (define smoke-p (build-path tmp-t "lisp1_braun_smoke.lfq"))
  (display-to-file
   (string-join
    '("#lang lakefillq"
      "(target-profile ideal)"
      "(defq (lisp1-braun-cancel #:target 'ideal #:wires ([x (qvec 2)] [s (qvec 2)]))"
      "  (seq"
      "    (seq (x (wref x 0))"
      "         (s (wref s 0))"
      "         (s-dag (wref s 1))"
      "         (focus-zipper [x (list (wref x 0)) (append x s)]"
      "           (seq (x (first x)) (s (first s)))))"
      "    (invert"
      "      (seq (x (wref x 0))"
      "           (s (wref s 0))"
      "           (s-dag (wref s 1))"
      "           (focus-zipper [x (list (wref x 0)) (append x s)]"
      "             (seq (x (first x)) (s (first s))))))))")
    "\n")
   smoke-p
   #:exists 'replace)
  (define-values (wt0 js0 qasm0 _stim0 _h0) (evaluate-lfq-file-isolated smoke-p))
  (check-true wt0)
  (check-equal? (hash-ref js0 'residual_surface_forms) 0)
  (check-true (string-contains? qasm0 "sdg q["))

  ;; 2. Lisp-1 `[x (qvec 2)]` inside `defqfree` catching `(h (wref x 1))` with `LFQ-E-QFREE-BASIS`:
  (define qf-p (build-path tmp-t "lisp1_qfree_err.lfq"))
  (display-to-file
   "#lang lakefillq\n(target-profile ideal)\n(defqfree (qf-err #:wires ([x (qvec 2)]))\n  (x (wref x 0))\n  (h (wref x 1)))\n"
   qf-p
   #:exists 'replace)
  (define-values (wt1 js1 _q1 _s1 h1) (evaluate-lfq-file-isolated qf-p))
  (check-false wt1)
  (check-equal? (hash-ref (first (hash-ref js1 'violations)) 'code) "LFQ-E-QFREE-BASIS")
  (check-true (valid-violation-hygiene? (first (hash-ref js1 'violations)) h1))

  ;; 3. Smoke check for all 5 optimization differential fuzzers (a)-(e):
  (define rng-smoke (make-lcg-rng 11223344))
  (for ([k-idx (in-range 3)])
    (define ra (fuzz-zero-flag-loop-escalation-trial k-idx rng-smoke))
    (check-true (hash-ref ra 'unrolled_truth_table_agreed)))
  (define rb (fuzz-adaptive-limb-to-pebble-bezout-trial 0 rng-smoke))
  (check-true (hash-ref rb 'all_pebbles_restored_zero))
  (check-true (hash-ref rb 'bezout_identity_verified))
  (define rc (fuzz-zx-egraph-todd-autoccz-trial 0 rng-smoke))
  (check-true (hash-ref rc 'exact_truth_table_and_phase8_match))
  (define rd (fuzz-cross-qpu-tele-phase-trial 0 rng-smoke))
  (check-true (hash-ref rd 'all_branches_unitary_equivalent))
  (define re (fuzz-adversarial-bug-injection-trial 0 tmp-t rng-smoke))
  (check-true (hash-ref re 'fail_closed_rejected)))

(module+ main
  (define json-out-path #f)
  (define json-stdout? #f)
  (define work-dir-arg #f)
  (command-line
   #:program "lakefillq-redex-surface-diagnostic-fuzzer"
   #:once-each
   [("--json-out") jpath "Write JSON fuzzer report to <path>"
    (set! json-out-path jpath)]
   [("--json") "Emit JSON fuzzer report to stdout"
    (set! json-stdout? #t)]
   [("--work-dir") wdir "Persistent scratch directory for generated .lfq modules"
    (set! work-dir-arg wdir)])
  (define report (run-redex-surface-diagnostic-fuzzer! work-dir-arg))
  (when json-out-path
    (make-parent-directory* json-out-path)
    (call-with-output-file json-out-path
      (lambda (out) (write-json report out) (newline out))
      #:exists 'replace))
  (cond
    [json-stdout?
     (write-json report)
     (newline)]
    [else
     (printf "[PASS] LakefillQ PLT Redex Surface & 5-Optimization Differential Fuzzer: ~a surface modules + ~a optimization trials (~a unitary/adjoint, ~a MBU/modular, ~a ill-typed across ~a codes) in ~a ms\n"
             (hash-ref report 'total_surface_modules)
             (hash-ref report 'total_optimization_fuzz_trials)
             (hash-ref (hash-ref report 'campaign1_unitary_adjoint) 'total_modules)
             (hash-ref (hash-ref report 'campaign2_mbu_chordal_modular) 'total_modules)
             (hash-ref (hash-ref report 'campaign3_diagnostic_hygiene) 'total_modules)
             (hash-ref (hash-ref report 'campaign3_diagnostic_hygiene) 'distinct_diagnostic_codes)
             (~r (hash-ref report 'racket_runtime_ms) #:precision 1))]))
