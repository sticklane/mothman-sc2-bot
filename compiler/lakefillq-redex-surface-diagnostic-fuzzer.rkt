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
               (h WExpr)
               (ry AngleTag WExpr)
               (rz-dyadic WExpr DyadicK)
               (cx WExpr WExpr)
               (cz WExpr WExpr)
               (ccx WExpr WExpr WExpr)
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
               (call-q variable RegId ...))
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

  (close-bug-prevention-z3!)
  (define elapsed-ms (- (current-inexact-monotonic-milliseconds) t0))

  (hasheq
   'status "PASS"
   'total_surface_modules (+ c1-passed c2-passed c3-rejected-correctly)
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
   'racket_runtime_ms elapsed-ms))

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
  (check-true (valid-violation-hygiene? (first (hash-ref js1 'violations)) h1)))

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
     (printf "[PASS] LakefillQ PLT Redex Surface & Diagnostic Hygiene Fuzzer: ~a surface modules (~a unitary/adjoint, ~a MBU/modular, ~a ill-typed across ~a codes) in ~a ms\n"
             (hash-ref report 'total_surface_modules)
             (hash-ref (hash-ref report 'campaign1_unitary_adjoint) 'total_modules)
             (hash-ref (hash-ref report 'campaign2_mbu_chordal_modular) 'total_modules)
             (hash-ref (hash-ref report 'campaign3_diagnostic_hygiene) 'total_modules)
             (hash-ref (hash-ref report 'campaign3_diagnostic_hygiene) 'distinct_diagnostic_codes)
             (~r (hash-ref report 'racket_runtime_ms) #:precision 1))]))
