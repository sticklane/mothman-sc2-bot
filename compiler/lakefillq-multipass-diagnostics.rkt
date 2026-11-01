#lang racket/base

;; =============================================================================
;; compiler/lakefillq-multipass-diagnostics.rkt
;;
;; Provenance-Preserving Multipass Type-Error Resugaring & Multi-Span Diagnostics
;; for `#lang lakefillq` (`LakefillQ -> lambda_LFQ_kern -> RevIR -> MachineISA`).
;;
;; Connects every compiler diagnostic directly to the single unified judgment:
;;
;;     Gamma_in |- t : Q_e(A) -| Gamma_out
;;
;; via a 3-span causal provenance chain:
;;   1. `origin_span`   (`Gamma_in`): where the clean scratch wire, quotient
;;      domain invariant, or mid-circuit `M_X` taint capability entered scope;
;;   2. `mutating_span` (`e`)       : the surface statement (`file:line:col`)
;;      that last entangled the wire or contributed the dominant physical
;;      resource grade excess (`Phi1`, `Phi2`, `Phi3`);
;;   3. `failure_span`  (`Gamma_out`): the `erase-by`, `canonicalize-quotient`,
;;      `qmatch`, interference gate, or `defq` exit boundary where the
;;      postcondition failed.
;;
;; Eliminates multipass abstraction leaks across Pass 1 (`elaborate-surface->kern`),
;; Pass 2 (`lower-kern->revir` + chordal SSA live-range wire recycling), and
;; Pass 3 (`infer-revir-qsub-and-qphys`):
;;   - Inverts chordal SSA wire coloring (`q[p] -> active virtual wire v ->
;;     surface group name s2[0]`, noting prior recycled owners `s1[0]`);
;;   - Resugars Zhegalkin ANF polynomials and `NanoMaLy`-style basis witnesses
;;     from internal variables (`x0*x1`, `q0_in=1`) to surface registers
;;     (`a[0]*a[1]`, `|a[0]=1, a[1]=1, out[0]=0>`);
;;   - Resugars compiler-synthesized measurement gensyms (`__u4_mx_k`, `__mbu_k`)
;;     back to the surface measurement/session form that introduced them.
;; =============================================================================

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/set
         racket/string
         (only-in lakefillq
                  lfq-circuit-decl?
                  lfq-circuit-decl-name
                  lfq-circuit-decl-kind
                  lfq-circuit-decl-wire-groups
                  lfq-circuit-decl-scratch-groups
                  lfq-circuit-decl-input-wires
                  lfq-circuit-decl-scratch-wires
                  lfq-surface-span
                  lfq-surface-span?
                  lfq-surface-span-file
                  lfq-surface-span-line
                  lfq-surface-span-col
                  lfq-surface-span-form-str
                  lfq-surface-span-pass-tag
                  lookup-surface-span))

(provide (struct-out lfq-wire-resugarer)
         (struct-out lfq-resolved-wire)
         record-chordal-owner-intervals!
         lookup-chordal-owner-intervals
         build-wire-resugarer
         resolve-physical-wire
         compiler-gensym-symbol?
         resugar-measurement-symbol
         resugar-anf->string
         resugar-counterexample-witness
         span->jsexpr
         unified-judgment-obligation-for-code
         default-repair-hint-for-code
         enrich-revir-violation
         enrich-surface-guard-violations
         format-violations-human)

;; =============================================================================
;; 1. Weak Side-Table for Chordal SSA Interval Ownership (`color-map -> owners`)
;; =============================================================================
;; Maps `color-map` (returned by `lower-kern->revir`) to a hash:
;;   `phys-wire -> list of (list start-step end-step virt-wire)` sorted by `start-step`.

(define chordal-owners-side-table (make-weak-hasheq))

(define (record-chordal-owner-intervals! cmap phys->owner-intervals)
  (when (hash? cmap)
    (hash-set! chordal-owners-side-table cmap phys->owner-intervals))
  cmap)

(define (lookup-chordal-owner-intervals cmap)
  (and (hash? cmap)
       (hash-ref chordal-owners-side-table cmap #f)))

;; =============================================================================
;; 2. Surface Wire-Group & Chordal SSA Inverse Resugaring
;; =============================================================================

(struct lfq-wire-resugarer
  (decl                  ;; #f or lfq-circuit-decl
   virt->surface-name    ;; hasheqv: virt-wire -> "sc[0]"
   virt->group-name      ;; hasheqv: virt-wire -> "sc"
   color-map             ;; #f or hasheqv: virt-wire -> phys-wire
   phys->owner-intervals);; hasheqv: phys-wire -> list of (list start end virt)
  #:transparent)

(struct lfq-resolved-wire
  (surface-name   ;; string ("s2[0]")
   group-name     ;; string ("s2")
   virtual-wire   ;; exact integer
   physical-wire  ;; exact integer
   recycled-from) ;; list of string ("s1[0]") for earlier chordal intervals on same q[p]
  #:transparent)

(define (build-wire-resugarer decl [color-map #f] [explicit-owners #f] [extra-virt-names #f])
  (define v->surf (make-hasheqv))
  (define v->grp (make-hasheqv))

  (when (lfq-circuit-decl? decl)
    (for ([grp (in-list (append (lfq-circuit-decl-wire-groups decl)
                                (lfq-circuit-decl-scratch-groups decl)))])
      (define g-sym (car grp))
      (define g-str (symbol->string g-sym))
      (for ([v (in-list (cdr grp))] [idx (in-naturals)])
        (unless (hash-has-key? v->surf v)
          (hash-set! v->surf v (format "~a[~a]" g-str idx))
          (hash-set! v->grp v g-str))))
    ;; Fallback for programmatic declarations with empty `wire-groups` / `scratch-groups`:
    (for ([v (in-list (lfq-circuit-decl-input-wires decl))] [idx (in-naturals)])
      (unless (hash-has-key? v->surf v)
        (hash-set! v->surf v (format "in[~a]" idx))
        (hash-set! v->grp v "in")))
    (for ([v (in-list (lfq-circuit-decl-scratch-wires decl))] [idx (in-naturals)])
      (unless (hash-has-key? v->surf v)
        (hash-set! v->surf v (format "scratch[~a]" idx))
        (hash-set! v->grp v "scratch"))))

  (when (hash? extra-virt-names)
    (for ([(v info) (in-hash extra-virt-names)])
      (match info
        [(cons s-str g-str)
         (hash-set! v->surf v s-str)
         (hash-set! v->grp v g-str)]
        [(? string? s-str)
         (hash-set! v->surf v s-str)
         (hash-set! v->grp v s-str)]
        [_ (void)])))

  (define owners
    (or explicit-owners
        (lookup-chordal-owner-intervals color-map)
        (let ([h (make-hasheqv)])
          (when (hash? color-map)
            (for ([(v p) (in-hash color-map)])
              (hash-update! h p (lambda (xs) (append xs (list (list 0 0 v)))) '())))
          h)))

  (lfq-wire-resugarer decl v->surf v->grp color-map owners))

(define (virtual-wire->surface-name resugarer v)
  (hash-ref (lfq-wire-resugarer-virt->surface-name resugarer)
            v
            (format "q[~a]" v)))

(define (virtual-wire->group-name resugarer v)
  (hash-ref (lfq-wire-resugarer-virt->group-name resugarer)
            v
            "q"))

;; Resolves physical qubit `p` at `step-idx` (`#f` = circuit exit -> latest owner interval)
;; back to the unique active virtual wire `v` and its declared `#lang lakefillq` register!
(define (resolve-physical-wire resugarer p [step-idx #f])
  (define intervals
    (sort (hash-ref (lfq-wire-resugarer-phys->owner-intervals resugarer) p '())
          (lambda (a b) (< (first a) (first b)))))
  (cond
    [(null? intervals)
     (lfq-resolved-wire (virtual-wire->surface-name resugarer p)
                        (virtual-wire->group-name resugarer p)
                        p
                        p
                        '())]
    [else
     (define chosen-iv
       (cond
         [(not step-idx)
          (last intervals)]
         [else
          (or (for/first ([iv (in-list intervals)]
                          #:when (and (<= (first iv) step-idx)
                                      (<= step-idx (second iv))))
                iv)
              (let ([le-ivs (filter (lambda (iv) (<= (first iv) step-idx)) intervals)])
                (if (null? le-ivs) (first intervals) (last le-ivs))))]))
     (define chosen-v (third chosen-iv))
     (define chosen-start (first chosen-iv))
     (define surf (virtual-wire->surface-name resugarer chosen-v))
     (define grp (virtual-wire->group-name resugarer chosen-v))
     (define prior-names
       (remove-duplicates
        (for/list ([iv (in-list intervals)]
                   #:when (and (< (first iv) chosen-start)
                               (not (= (third iv) chosen-v))))
          (virtual-wire->surface-name resugarer (third iv)))))
     (lfq-resolved-wire surf grp chosen-v p prior-names)]))

;; =============================================================================
;; 3. Gensym, ANF, and Basis Counterexample Resugaring
;; =============================================================================

(define (compiler-gensym-symbol? sym)
  (define s (if (symbol? sym) (symbol->string sym) (format "~a" sym)))
  (or (string-prefix? s "__u4_mx_")
      (string-prefix? s "__mbu_")))

(define (resugar-measurement-symbol sym [meas-wire-surface #f])
  (define s (if (symbol? sym) (symbol->string sym) (format "~a" sym)))
  (cond
    [(string-prefix? s "__mbu_")
     (if meas-wire-surface
         (format "auto-MBU erasure on ~a" meas-wire-surface)
         "auto-MBU TempAND erasure")]
    [(string-prefix? s "__u4_mx_")
     (if meas-wire-surface
         (format "mid-meas-x on ~a" meas-wire-surface)
         "mid-meas-x phase erasure")]
    [meas-wire-surface
     (format "measurement `~a` on ~a" s meas-wire-surface)]
    [else
     (format "measurement `~a`" s)]))

(define (resugar-anf->string p var-surface-names)
  (if (null? p)
      "0"
      (string-join
       (for/list ([m (in-list p)])
         (if (null? m)
             "1"
             (string-join
              (map (lambda (v)
                     (hash-ref var-surface-names v (format "x~a" v)))
                   m)
              "*")))
       " ^ ")))

(define (resugar-counterexample-witness reduced-p var-surface-names)
  (match reduced-p
    ['() #f]
    [(cons m-min _)
     (define ones (list->seteqv m-min))
     (define sorted-vids (sort (hash-keys var-surface-names) <))
     (define assign-hash
       (for/hasheq ([v-id (in-list sorted-vids)])
         (define lbl (hash-ref var-surface-names v-id (format "x~a" v-id)))
         (values (string->symbol lbl)
                 (if (set-member? ones v-id) 1 0))))
     (define ket-parts
       (for/list ([v-id (in-list sorted-vids)])
         (define lbl (hash-ref var-surface-names v-id (format "x~a" v-id)))
         (format "~a=~a" lbl (if (set-member? ones v-id) 1 0))))
     (hasheq 'basis_ket (format "|~a>" (string-join ket-parts ", "))
             'surface_assignments assign-hash)]))

;; =============================================================================
;; 4. Unified Judgment Obligation Mapping & 3-Span Provenance Serialization
;; =============================================================================

(define (span->jsexpr sp role-str)
  (cond
    [(lfq-surface-span? sp)
     (hasheq 'role role-str
             'file (or (lfq-surface-span-file sp) "<memory>")
             'line (max 1 (or (lfq-surface-span-line sp) 1))
             'column (max 0 (or (lfq-surface-span-col sp) 0))
             'surface_form (or (lfq-surface-span-form-str sp) "<synthesized>")
             'captured_at_pass (symbol->string (or (lfq-surface-span-pass-tag sp) 'LakefillQ)))]
    [else
     (hasheq 'role role-str
             'file "<unknown>"
             'line 1
             'column 0
             'surface_form "<synthesized>"
             'captured_at_pass "LakefillQ")]))

(define (unified-judgment-obligation-for-code code-str)
  (match code-str
    ["U1-EraseBy"
     "Gamma_out[scratch = |0>] (Law U1 EraseBy postcondition in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["U2-Canonical"
     "Gamma_out[quotient = |0>] (Law U2 Canonical history-independence in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["U3-TotalOn"
     "Gamma_in -> Q_e(A) (Law U3 TotalOn orthogonal qmatch partition in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["U4-QTainted"
     "Gamma_out[phase_taint = 0] (Law U4 QTainted M_X phase cancellation in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["Phi1-DecoherenceAction"
     "e.Phi1 <= 693 milli-nats (QPhysGrade Lindblad decoherence action in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["Phi2-ExclusionGraph"
     "e.Phi2 == 0 collisions (QPhysGrade hardware coupler/blockade disjointness in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["Phi3-FaultExponent"
     "e.Phi3 >= d_req (QPhysGrade fault-distance & dyadic-angle exponent in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [(? (lambda (s) (string-prefix? s "E-DOMIMG")))
     "Gamma_in <-> Gamma_out (T-DomImg support-injective bijection in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [(? (lambda (s) (string-prefix? s "E-VALIDIF")))
     "Gamma_in[ValidIf] (T-ValidIf validity-witness guard in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [(? (lambda (s) (string-prefix? s "E-ALGPHASE")))
     "e.omega in Z_4 (T-AlgPhase involutory/global-phase index in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [(? (lambda (s) (string-prefix? s "E-WIREBASIS")))
     "Gamma_in -> Gamma_out[Perm, Basis] (T-WireBasis logical frame coherence in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [(? (lambda (s) (string-prefix? s "E-DRIFTEPS")))
     "e.eps_drift (T-DriftEps carry-runway & Lipschitz error grade in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [(? (lambda (s) (string-prefix? s "E-SINGLEIR")))
     "Q_e(A) == Spec(A) (T-SingleIR unified IR & oracle margin in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [(? (lambda (s) (string-prefix? s "E-PARGUARD")))
     "e.QParGrade (T-ParGuard convex cluster partitionability in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-WIRE-ALIAS"
     "Gamma_in[disjoint wire allocation] (RWire disjointness in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-CALL-ALIAS"
     "Gamma_in[r_1 (x) r_2 != Conflict] (Ordered partial duoidal RWire port non-aliasing at call-q in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-CLUSTER-COST-DRIFT"
     "Q_e(A).cost == ClusterProfile.cost (T-SingleIR AST-derived cluster resource consistency in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-QFREE-BASIS"
     "e.qfree == #t (Basis-preserving Uniq1/BorrowZ discipline in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-GATE-ALIAS"
     "Gamma_in[distinct gate operands] (Linear multi-qubit no-cloning in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-UNDECLARED-WIRE"
     "w in dom(Gamma_in) (Lexical wire-scope discipline in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-NONUNITARY-INVERT"
     "e.meas == 0 (Unitary syntactic adjoint precondition in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-REGISTER-BOUNDS"
     "0 <= idx < width(reg) (Static register bounds in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-TARGET-PROFILE"
     "target in {ideal, heron-r2, bluvstein-aod, bb-qldpc} (Hardware grade semiring profile in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-GUARD-SPEC"
     "Spec(A) well-formed (Static guard specification grammar in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    ["LFQ-E-SURFACE-ELAB"
     "t well-formed in #lang lakefillq (Surface syntax & lexical elaboration in Gamma_in |- t : Q_e(A) -| Gamma_out)"]
    [_
     "Gamma_in |- t : Q_e(A) -| Gamma_out"]))

(define (default-repair-hint-for-code code-str [surface-wire #f])
  (define w-txt (or surface-wire "the affected wire"))
  (match code-str
    ["U1-EraseBy"
     (format "Uncompute `~a` in the backward arm of `erase-by`, or replace manual `erase-by` with `(within-apply-mbu ...)` / `(with-and-session ...)` so `~a` returns to |0>."
             w-txt w-txt)]
    ["U2-Canonical"
     (format "Supply a residue-determined cleanup circuit in `(canonicalize-quotient ...)` that resets quotient register `~a` to |0> before interference or exit."
             w-txt)]
    ["U3-TotalOn"
     "Make `qmatch` guards pairwise disjoint and exhaustive over `#:domain`, and keep guard wires read-only inside each arm."]
    ["U4-QTainted"
     "Pair `mid-meas-x` with matching classical phase feedforward (`cond-z` for 1-control GHZ fanout or `cond-cz` for 2-control TempAND) before applying Hadamard/interference gates."]
    ["Phi1-DecoherenceAction"
     "Replace `mid-meas-x-unshielded` with XY4-shielded `(mid-meas-x ...)` or pass `--repair` to insert dynamical decoupling / `multishot-reset` checkpoints."]
    ["Phi2-ExclusionGraph"
     "Separate colliding parallel `par-wires` gates beyond the Rydberg blockade / coupler exclusion radius, or pass `--repair` to 2-color the schedule."]
    ["Phi3-FaultExponent"
     "Use `#:schedule 'nzsw-orthogonal` on `syndrome-plaquette` and `#:precision 'exact-dyadic` on `rz-dyadic` (or pass `--repair`)."]
    [(? (lambda (s) (string-prefix? s "E-DOMIMG")))
     "Restrict `#:dom-f` to the exact support where `g(f(x)) = x` and `res(x) = 0`, or widen the uncompute witness so `f` is injective."]
    [(? (lambda (s) (string-prefix? s "E-VALIDIF")))
     "Include the validity witness qubit from `bind-partial-op` inside the control set of `phase-flip-if` and keep it immutable across `with-valid`."]
    [(? (lambda (s) (string-prefix? s "E-ALGPHASE")))
     "Ensure reflection operators satisfy `U^2 = I` and `U^dag = U`, and track `Z_4` global phase shifts `(-i)^d` before controlled LCU composition."]
    [(? (lambda (s) (string-prefix? s "E-WIREBASIS")))
     "Apply an explicit basis/permutation isomorphism (`logical-relabel` or `basis-convert`) so both operands share identical `(Perm, BasisTag)` frames."]
    [(? (lambda (s) (string-prefix? s "E-DRIFTEPS")))
     "Increase coset padding `c_pad` so `K_steps * 2^{s_safety} < 2^{c_pad}` (or widen `QRNS` prime moduli / alias precision `mu`)."]
    [(? (lambda (s) (string-prefix? s "E-SINGLEIR")))
     "Bind all state slices in the single `RevIR` cost/codegen pipeline and supply enough ciphertext/hash constraint bits to suppress spurious Grover keys."]
    [(? (lambda (s) (string-prefix? s "E-PARGUARD")))
     "Omit `#:strict-parallel? #t` to allow safe `M* = 1` single-machine fallback, or increase `--q-cap` / switch `--topology switched-optical-tree`."]
    ["LFQ-E-WIRE-ALIAS"
     "Replace manual overlapping integer wire lists with symbolic `(qvec n)` allocators in `#:wires` and `#:scratch` so every register receives disjoint qubits."]
    ["LFQ-E-CALL-ALIAS"
     "Pass disjoint wire slices for mutated `Lin1` / `Uniq1` ports in `(call-q ...)`; only read-only diagonal `BorrowZ` or `ErasedIdx` ports may share wires simultaneously."]
    ["LFQ-E-CLUSTER-COST-DRIFT"
     "Omit manual `#:q-single` and `#:local-toffolis` (or set them to `'auto`) in `define-cluster-profile` so cluster partition costs derive directly from the compiled `RevIR` / `MachineISA` circuit."]
    ["LFQ-E-QFREE-BASIS"
     "Change `defqfree` to `defq` if superposition or phase gates are intended (`Lin1` capability), or restrict the body to basis-preserving reversible gates (`x`, `cx`, `ccx`, `swap`, `temp-and`)."]
    ["LFQ-E-GATE-ALIAS"
     "Pass distinct qubits to multi-qubit gates (`cx`, `cz`, `ccx`, `temp-and`); control and target operands cannot alias the same wire."]
    ["LFQ-E-UNDECLARED-WIRE"
     "Declare all input and ancilla registers in `#:wires` or `#:scratch` via `(qvec n)` and index them with `(wref reg i)` rather than raw undeclared wire integers."]
    ["LFQ-E-NONUNITARY-INVERT"
     "Only unitary subcircuits (`e.meas == 0`) admit `(invert ...)`; use `(within-apply-mbu compute action scratch)` or `(with-and-session ...)` for measurement-based uncomputation."]
    ["LFQ-E-REGISTER-BOUNDS"
     "Increase the `(qvec n)` width in `#:wires` / `#:scratch` or choose a register index `0 <= idx < n`."]
    ["LFQ-E-TARGET-PROFILE"
     "Choose one of the calibrated hardware profiles: `ideal`, `heron-r2`, `bluvstein-aod`, or `bb-qldpc`."]
    ["LFQ-E-GUARD-SPEC"
     "Supply a well-formed static guard specification matching the surface rule grammar (e.g., `(par-cluster-opt-spec ...)` or quoted `part-bij` key-value pairs)."]
    ["LFQ-E-SURFACE-ELAB"
     "Verify `#lang lakefillq` surface syntax, balanced parentheses, and quoted symbol tags (e.g., `'m0`)."]
    [_
     "Inspect the origin, mutating, and boundary spans to restore the unified typing obligation."]))

(define (enrich-revir-violation base-violation
                                #:resugared-message resugared-msg
                                #:origin-span [origin-span #f]
                                #:mutating-span [mutating-span #f]
                                #:failure-span [failure-span #f]
                                #:surface-wire [surface-wire #f]
                                #:chordal-recycled-from [recycled-from '()]
                                #:resugared-anf [resugared-anf #f]
                                #:resugared-witness [resugared-witness #f]
                                #:repair-hint [repair-hint #f])
  (define code-str (hash-ref base-violation 'code ""))
  (define eff-origin (or origin-span mutating-span failure-span))
  (define eff-mut (or mutating-span failure-span origin-span))
  (define eff-fail (or failure-span mutating-span origin-span))
  (define prov-hash
    (hasheq 'origin_span (span->jsexpr eff-origin "Gamma_in (capability/wire origin)")
            'mutating_span (span->jsexpr eff-mut "e (causal mutation / grade accumulation)")
            'failure_span (span->jsexpr eff-fail "Gamma_out (postcondition boundary)")
            'pass_trace '("LakefillQ" "lambda_LFQ_kern" "RevIR")))
  (define pairs
    (append
     (list 'unified_judgment_obligation (unified-judgment-obligation-for-code code-str)
           'resugared_message resugared-msg
           'provenance_spans prov-hash
           'repair_hint (or repair-hint (default-repair-hint-for-code code-str surface-wire)))
     (if surface-wire (list 'surface_wire surface-wire) '())
     (if (not (null? recycled-from))
         (list 'chordal_recycled_from recycled-from)
         '())
     (if resugared-anf (list 'resugared_anf resugared-anf) '())
     (if resugared-witness (list 'resugared_witness resugared-witness) '())))
  (let loop ([h base-violation] [kvs pairs])
    (match kvs
      ['() h]
      [(list k v rest ...) (loop (hash-set h k v) rest)])))

(define (enrich-surface-guard-violations guard-violations surface-ast decl)
  (define decl-sp
    (or (and decl (lookup-surface-span decl))
        (and decl
             (lfq-surface-span (format "<~a>" (lfq-circuit-decl-name decl))
                               1
                               0
                               (format "(~a ~a ...)"
                                       (lfq-circuit-decl-kind decl)
                                       (lfq-circuit-decl-name decl))
                               'LakefillQ))))
  ;; Map each guard head to its surface span for crisp localization:
  (define head->spans (make-hasheq))
  (let walk ([e surface-ast])
    (when (pair? e)
      (define sp (lookup-surface-span e))
      (when (and sp (symbol? (car e)))
        (hash-update! head->spans (car e) (lambda (xs) (append xs (list sp))) '()))
      (for ([sub (in-list (cdr e))] #:when (pair? sub))
        (walk sub))))
  (define (pick-guard-span rule-str)
    (define heads
      (match rule-str
        ["T-DomImg" '(erase-by-part-bij)]
        ["T-ValidIf" '(guard-valid-if)]
        ["T-AlgPhase" '(guard-involutory guard-qblock-lcu-phase)]
        ["T-WireBasis" '(guard-wire-basis)]
        ["T-DriftEps" '(guard-drift-eps)]
        ["T-SingleIR" '(guard-single-ir)]
        ["T-ParGuard" '(guard-par-partition)]
        [_ '()]))
    (or (for*/first ([h (in-list heads)]
                     [sp (in-list (hash-ref head->spans h '()))])
          sp)
        (lookup-surface-span surface-ast)
        decl-sp))

  (for/list ([v (in-list guard-violations)])
    (define code-str (hash-ref v 'code ""))
    (define rule-str (hash-ref v 'rule ""))
    (define g-sp (pick-guard-span rule-str))
    (define orig-sp (or decl-sp g-sp))
    (define prov
      (hasheq 'origin_span (span->jsexpr orig-sp "Gamma_in (circuit declaration)")
              'mutating_span (span->jsexpr g-sp "e (surface static guard obligation)")
              'failure_span (span->jsexpr g-sp "Gamma_out (rejected surface guard)")
              'pass_trace '("LakefillQ")))
    (hash-set* v
               'unified_judgment_obligation (unified-judgment-obligation-for-code code-str)
               'resugared_message (hash-ref v 'message "")
               'provenance_spans prov
               'repair_hint (default-repair-hint-for-code code-str #f))))

;; =============================================================================
;; 5. Rust / Elm-Style Multi-Span Human CLI Diagnostic Renderer
;; =============================================================================

(define (read-source-line-safe file-str line-num)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (cond
      [(or (not (string? file-str))
           (string-prefix? file-str "<")
           (not (file-exists? file-str))
           (<= line-num 0))
       #f]
      [else
       (define lines (file->lines file-str))
       (and (<= line-num (length lines))
            (list-ref lines (sub1 line-num)))])))

(define (balanced-sexpr-len-on-line src-ln col)
  (define n (string-length src-ln))
  (cond
    [(or (< col 0) (>= col n)) 1]
    [(memv (string-ref src-ln col) '(#\( #\[))
     (let loop ([i col] [depth 0])
       (cond
         [(>= i n) (- n col)]
         [else
          (define ch (string-ref src-ln i))
          (define d2
            (cond
              [(or (char=? ch #\() (char=? ch #\[)) (add1 depth)]
              [(or (char=? ch #\)) (char=? ch #\])) (sub1 depth)]
              [else depth]))
          (if (<= d2 0)
              (add1 (- i col))
              (loop (add1 i) d2))]))]
    [else
     (min 36 (- n col))]))

(define (format-span-snippet label-tag span-hash)
  (define f (hash-ref span-hash 'file "<memory>"))
  (define ln (hash-ref span-hash 'line 1))
  (define col (hash-ref span-hash 'column 0))
  (define role (hash-ref span-hash 'role ""))
  (define frm (hash-ref span-hash 'surface_form ""))
  (define src-ln (read-source-line-safe f ln))
  (define header
    (format "  --> ~a (~a) at ~a:~a:~a" label-tag role f ln col))
  (if src-ln
      (let* ([pad (make-string (max 0 col) #\space)]
             [caret-len (max 1 (min 56 (balanced-sexpr-len-on-line src-ln col)))]
             [carets (string-append "^" (make-string (max 0 (sub1 caret-len)) #\~))])
        (string-join
         (list header
               (format "   ~a | ~a" ln src-ln)
               (format "   ~a | ~a~a" (make-string (string-length (number->string ln)) #\space) pad carets))
         "\n"))
      (string-join
       (list header
             (format "     form: ~a" frm))
       "\n")))

(define (same-span-loc? a b)
  (and (hash? a)
       (hash? b)
       (equal? (hash-ref a 'file #f) (hash-ref b 'file #f))
       (equal? (hash-ref a 'line #f) (hash-ref b 'line #f))
       (equal? (hash-ref a 'column #f) (hash-ref b 'column #f))))

(define (format-violations-human circuit-name target-name violations)
  (define blocks
    (for/list ([v (in-list violations)] [idx (in-naturals 1)])
      (define cat (hash-ref v 'category "TypeError"))
      (define code (hash-ref v 'code "Unknown"))
      (define msg (hash-ref v 'resugared_message (hash-ref v 'message "")))
      (define oblig (hash-ref v 'unified_judgment_obligation "Gamma_in |- t : Q_e(A) -| Gamma_out"))
      (define prov (hash-ref v 'provenance_spans #f))
      (define rw (hash-ref v 'resugared_witness #f))
      (define recycled (hash-ref v 'chordal_recycled_from '()))
      (define hint (hash-ref v 'repair_hint #f))

      (define span-lines
        (if (hash? prov)
            (let* ([o-sp (hash-ref prov 'origin_span #f)]
                   [m-sp (hash-ref prov 'mutating_span #f)]
                   [f-sp (hash-ref prov 'failure_span #f)]
                   [same-om? (same-span-loc? o-sp m-sp)]
                   [same-mf? (same-span-loc? m-sp f-sp)]
                   [same-of? (same-span-loc? o-sp f-sp)])
              (filter values
                      (list (and o-sp (format-span-snippet "origin" o-sp))
                            (and m-sp (not same-om?) (format-span-snippet "cause " m-sp))
                            (and f-sp (not same-mf?) (not same-of?) (format-span-snippet "exit  " f-sp)))))
            '()))

      (define witness-line
        (cond
          [(and (hash? rw) (hash-has-key? rw 'basis_ket))
           (format "  = counterexample basis: ~a" (hash-ref rw 'basis_ket))]
          [else #f]))

      (define recycle-line
        (if (null? recycled)
            #f
            (format "  = note (chordal SSA wire recycling): physical qubit shared earlier with ~a"
                    (string-join recycled ", "))))

      (define hint-line
        (and hint (format "  = help: ~a" hint)))

      (define v-circ (hash-ref v 'circuit_name circuit-name))

      (string-join
       (filter values
               (append
                (list (format "error[~a::~a] (#~a in `~a`, target `~a`): ~a"
                              cat code idx v-circ target-name msg)
                      (format "  = judgment: ~a" oblig))
                span-lines
                (list witness-line recycle-line hint-line)))
       "\n")))
  (string-join blocks "\n\n"))

;; =============================================================================
;; Unit Tests (`raco test compiler/lakefillq-multipass-diagnostics.rkt`)
;; =============================================================================

(module+ test
  (require rackunit
           (only-in lakefillq lfq-circuit-decl))

  ;; Verify chordal SSA wire-recycling inverse resolution distinguishes
  ;; earlier clean `s1[0]` (interval [0, 2]) from leaked `s2[0]` (interval [3, 5])
  ;; when both map to physical qubit `q[2]`!
  (define dummy-decl
    (lfq-circuit-decl 'recycle-demo
                      'defqfree
                      '((a . (0 1)))
                      '((s1 . (2)) (s2 . (3)))
                      '(0 1)
                      '(2 3)
                      'all
                      'skip))
  (define cmap (make-hasheqv '((0 . 0) (1 . 1) (2 . 2) (3 . 2))))
  (define owners
    (make-hasheqv
     (list (cons 0 '((0 6 0)))
           (cons 1 '((0 6 1)))
           (cons 2 '((0 2 2) (3 5 3))))))
  (record-chordal-owner-intervals! cmap owners)
  (define resug (build-wire-resugarer dummy-decl cmap))

  ;; At step 1, physical `q[2]` belongs to `s1[0]`:
  (define r-early (resolve-physical-wire resug 2 1))
  (check-equal? (lfq-resolved-wire-surface-name r-early) "s1[0]")
  (check-equal? (lfq-resolved-wire-recycled-from r-early) '())

  ;; At exit (`#f`) or step 4, physical `q[2]` belongs to `s2[0]` (recycled from `s1[0]`):
  (define r-exit (resolve-physical-wire resug 2 #f))
  (check-equal? (lfq-resolved-wire-surface-name r-exit) "s2[0]")
  (check-equal? (lfq-resolved-wire-virtual-wire r-exit) 3)
  (check-equal? (lfq-resolved-wire-recycled-from r-exit) '("s1[0]"))

  ;; Verify ANF + basis counterexample resugaring:
  (define var-surf (make-hasheqv '((0 . "a[0]") (1 . "a[1]"))))
  (check-equal? (resugar-anf->string '((0 1)) var-surf) "a[0]*a[1]")
  (define rw (resugar-counterexample-witness '((0 1)) var-surf))
  (check-equal? (hash-ref rw 'basis_ket) "|a[0]=1, a[1]=1>")

  ;; Verify compiler gensym detection & resugaring:
  (check-true (compiler-gensym-symbol? '__u4_mx_0))
  (check-true (compiler-gensym-symbol? '__mbu_2))
  (check-false (compiler-gensym-symbol? 'm_user))
  (check-equal? (resugar-measurement-symbol '__u4_mx_0 "anc[0]")
                "mid-meas-x on anc[0]"))
