#lang racket/base

;; =============================================================================
;; compiler/lakefillq-cluster-qasm3-codegen.rkt
;;
;; Multi-QPU OpenQASM 3.0 Partition Codegen & Bell-Schedule Synthesis for `lakefillqc`.
;;
;; Evaluates `solve-optimal-qpar-machines` (`T-ParGuard` / `QParGrade`) over
;; module-level `(define-cluster-profile ...)` or surface `(guard-par-partition ...)`
;; specifications with optional CLI hardware overrides (`--q-cap`, `--r-bell`,
;; `--topology`, `--max-machines`), and lowers `MachineISA` streams into:
;;   - `M* = 1` (either `ParNonPartitionable` Grover fallback or monolithic
;;     `ParSliceable` when `Q_single <= Q_cap`):
;;       * `qpu_0.qasm`
;;       * `cluster_manifest.json` (`optimal_m_star: 1`, `logical_ebits: 0`,
;;         `fallback_or_monolithic: #t`)
;;   - `M* >= 2` (column-sliced `Law U4` GHZ window lookup + zero-carry `QRNS`
;;     when `Q_single > Q_cap`):
;;       * `qpu_0.qasm .. qpu_{M*-1}.qasm` (per-QPU OpenQASM 3.0 with explicit
;;         `ghz_cat_tx` / `ghz_cat_rx` Bell link gates, local `M_X` measurement,
;;         and classical `feedforward_cond_z` statements + `@lakefillq.*` annotations)
;;       * `ebit_schedule.json` (`forward_ebits = w * (M* - 1)`, `reverse_ebits = 0`,
;;         `carry_ebits = 0`)
;;       * `joint_cluster_aer.qasm` (stitched multi-QPU dynamic OpenQASM 3.0
;;         Bell-teleported circuit for exact `Qiskit Aer` statevector equivalence)
;;       * `cluster_manifest.json`
;; =============================================================================

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/set
         racket/string
         json
         (except-in lakefillq #%module-begin par-cluster-opt-spec solve-optimal-qpar-machines)
         "lakefillq-bug-class-prevention-types.rkt")

(provide has-cluster-cli-overrides?
         override-par-cluster-spec
         resolve-auto-par-cluster-spec
         count-isa-toffolis
         check-cluster-profile-circuit-match
         rewrite-surface-par-specs
         resolve-effective-cluster-spec
         partition-wires-across-qpus
         emit-cluster-openqasm3-bundle!)

;; =============================================================================
;; 1. Cluster Spec Overrides, `'auto` AST Cost Derivation & Drift Verification
;; =============================================================================

(define (has-cluster-cli-overrides? q-cap r-bell topology max-machines)
  (or (and q-cap #t)
      (and r-bell #t)
      (and topology #t)
      (and max-machines #t)))

(define (plist-replace kws key new-val)
  (let loop ([rem kws] [acc '()] [replaced? #f])
    (match rem
      ['()
       (if replaced?
           (reverse acc)
           (append (reverse acc) (list key new-val)))]
      [(list single)
       (reverse (cons single acc))]
      [(list* k v rest-kws)
       (if (equal? k key)
           (loop rest-kws (cons new-val (cons k acc)) #t)
           (loop rest-kws (cons v (cons k acc)) replaced?))])))

(define (plist-ref kws key [default #f])
  (let loop ([rem kws])
    (match rem
      [(list* k v rest-kws)
       (if (equal? k key) v (loop rest-kws))]
      [_ default])))

(define (count-isa-toffolis isa-ops)
  (for/sum ([op (in-list isa-ops)])
    (match op
      [(or `(isa-ccx ,_ ,_ ,_) `(isa-temp-and-ccx ,_ ,_ ,_)) 1]
      [_ 0])))

(define (resolve-auto-par-cluster-spec spec decl total-phys-q [ast-toffolis #f])
  (match spec
    [`(par-cluster-opt-spec . ,kws)
     (define paradigm (plist-ref kws '#:paradigm 'algebraic-limb))
     (define raw-q-single (plist-ref kws '#:q-single 'auto))
     (define raw-q-data (plist-ref kws '#:q-data-dist 'auto))
     (define raw-toff (plist-ref kws '#:local-toffolis 'auto))
     (define eff-q-single
       (if (or (eq? raw-q-single 'auto) (not raw-q-single))
           (max 1 total-phys-q)
           raw-q-single))
     (define eff-q-data
       (if (or (eq? raw-q-data 'auto) (not raw-q-data))
           (if (eq? paradigm 'grover-amplify)
               0
               (max 1 (if (lfq-circuit-decl? decl)
                          (length (lfq-circuit-decl-input-wires decl))
                          total-phys-q)))
           raw-q-data))
     (define eff-toff
       (if (or (eq? raw-toff 'auto) (not raw-toff))
           (if ast-toffolis ast-toffolis 16)
           raw-toff))
     (define kws1 (plist-replace kws '#:q-single eff-q-single))
     (define kws2 (plist-replace kws1 '#:q-data-dist eff-q-data))
     (define kws3 (plist-replace kws2 '#:local-toffolis eff-toff))
     `(par-cluster-opt-spec ,@kws3)]
    [`(par-partition-bundle ,subs ...)
     `(par-partition-bundle
       ,@(for/list ([s (in-list subs)])
           (resolve-auto-par-cluster-spec s decl total-phys-q ast-toffolis)))]
    [_ spec]))

(define (check-cluster-profile-circuit-match prog decl actual-phys-q actual-toffolis)
  (define profiles (if prog (lfq-program-cluster-profiles prog) '()))
  (cond
    [(null? profiles) '()]
    [else
     (define selected-entry (last profiles))
     (define meta (lookup-cluster-profile-meta selected-entry))
     (define verify? (hash-ref meta 'verify_circuit_match #f))
     (define prof-span (hash-ref meta 'surface_span #f))
     (define raw-spec (lfq-cluster-profile-entry-spec selected-entry))
     (match raw-spec
       [`(par-cluster-opt-spec . ,kws)
        #:when verify?
        (define raw-q-single (plist-ref kws '#:q-single 'auto))
        (define raw-toff (plist-ref kws '#:local-toffolis 'auto))
        (define q-mismatch?
          (and (exact-integer? raw-q-single)
               (not (= raw-q-single actual-phys-q))))
        (define toff-mismatch?
          (and (exact-integer? raw-toff)
               actual-toffolis
               (not (= raw-toff actual-toffolis))))
        (if (or q-mismatch? toff-mismatch?)
            (list
             (hasheq
              'category "SingleIR"
              'rule "T-SingleIR"
              'code "LFQ-E-CLUSTER-COST-DRIFT"
              'profile_name (symbol->string (lfq-cluster-profile-entry-name selected-entry))
              'profile_span prof-span
              'message
              (format "Cluster profile `~a` hard-codes ~a, which drifts from compiled circuit `~a` (~a physical qubits, ~a local Toffolis)."
                      (lfq-cluster-profile-entry-name selected-entry)
                      (string-join
                       (filter values
                               (list (and q-mismatch? (format "#:q-single ~a" raw-q-single))
                                     (and toff-mismatch? (format "#:local-toffolis ~a" raw-toff))))
                       " and ")
                      (lfq-circuit-decl-name decl)
                      actual-phys-q
                      (or actual-toffolis 0))
              'witness
              (hasheq 'declared_q_single (if (symbol? raw-q-single) (symbol->string raw-q-single) raw-q-single)
                      'compiled_physical_qubits actual-phys-q
                      'declared_local_toffolis (if (symbol? raw-toff) (symbol->string raw-toff) raw-toff)
                      'compiled_local_toffolis (or actual-toffolis 0))))
            '())]
       [_ '()])]))

(define (override-par-cluster-spec spec
                                   #:q-cap [q-cap #f]
                                   #:r-bell [r-bell #f]
                                   #:topology [topology #f]
                                   #:max-machines [max-machines #f])
  (match spec
    [`(par-cluster-opt-spec . ,kws)
     (define kws1 (if q-cap (plist-replace kws '#:q-cap-per-machine q-cap) kws))
     (define kws2 (if r-bell (plist-replace kws1 '#:raw-bell-rate-hz (exact->inexact r-bell)) kws1))
     (define kws3 (if topology (plist-replace kws2 '#:interconnect-topology topology) kws2))
     (define kws4 (if max-machines (plist-replace kws3 '#:max-machines max-machines) kws3))
     `(par-cluster-opt-spec ,@kws4)]
    [`(par-partition-bundle ,subs ...)
     `(par-partition-bundle
       ,@(for/list ([s (in-list subs)])
           (override-par-cluster-spec s
                                      #:q-cap q-cap
                                      #:r-bell r-bell
                                      #:topology topology
                                      #:max-machines max-machines)))]
    [_ spec]))

(define (estimate-surface-toffolis ast)
  (let walk ([e ast])
    (match e
      [(or `(ccx ,_ ,_ ,_) `(temp-and ,_ ,_ ,_) `(temp-and-lin . ,_)) 1]
      [`(cswap-bit ,_ ,_ ,_) 1]
      [`(cswap-word ,_ ,us ,_) (if (list? us) (length us) 1)]
      [`(mcx ,cs ,_ ,_) (max 0 (sub1 (if (list? cs) (length cs) 1)))]
      [`(with-and-session ,bs ,b) (+ (length bs) (walk b))]
      [`(within-apply-mbu ,c ,a ,_) (+ (walk c) (walk a))]
      [`(within-apply ,c ,a ,_) (+ (* 2 (walk c)) (walk a))]
      [`(erase-by ,f ,b ,_) (+ (walk f) (walk b))]
      [`(erase-by-part-bij ,_ ,f ,b ,_) (+ (walk f) (walk b))]
      [`(seq ,es ...) (for/sum ([s (in-list es)]) (walk s))]
      [`(invert ,s) (walk s)]
      [`(call-q ,callee . ,_)
       (if (lfq-circuit-decl? callee)
           (walk (lfq-circuit-decl-surface-ast callee))
           0)]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for/sum ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd) (walk nd)]
      [`(braun-branch ,_ ,st ,l ,r) (+ (walk st) (walk l) (walk r))]
      [`(par-wires ,e1 ,e2) (+ (walk e1) (walk e2))]
      [`(multishot-reset ,_ ,b) (walk b)]
      [`(,(or 'guard-par-partition 'guard-valid-if 'guard-qblock-lcu-phase
              'guard-wire-basis 'guard-drift-eps 'guard-single-ir) ,_ ,b)
       (walk b)]
      [`(guard-involutory ,_ ,_ ,b) (walk b)]
      [_ 0])))

(define (spec-has-auto? spec)
  (match spec
    [`(par-cluster-opt-spec . ,kws)
     (or (eq? (plist-ref kws '#:q-single #f) 'auto)
         (eq? (plist-ref kws '#:q-data-dist #f) 'auto)
         (eq? (plist-ref kws '#:local-toffolis #f) 'auto))]
    [`(par-partition-bundle ,subs ...)
     (for/or ([s (in-list subs)]) (spec-has-auto? s))]
    [_ #f]))

(define (rewrite-surface-par-specs ast
                                   #:decl [decl #f]
                                   #:q-cap [q-cap #f]
                                   #:r-bell [r-bell #f]
                                   #:topology [topology #f]
                                   #:max-machines [max-machines #f])
  (define decl-q
    (if (lfq-circuit-decl? decl)
        (max 1 (+ (length (lfq-circuit-decl-input-wires decl))
                  (length (lfq-circuit-decl-scratch-wires decl))))
        1))
  (define surf-toffs (estimate-surface-toffolis ast))
  (let walk ([e ast])
    (define rebuilt
      (match e
        [`(guard-par-partition ,spec ,body)
         (define resolved-spec
           (if (spec-has-auto? spec)
               (resolve-auto-par-cluster-spec spec decl decl-q surf-toffs)
               spec))
         (define final-spec
           (if (has-cluster-cli-overrides? q-cap r-bell topology max-machines)
               (override-par-cluster-spec resolved-spec
                                          #:q-cap q-cap
                                          #:r-bell r-bell
                                          #:topology topology
                                          #:max-machines max-machines)
               resolved-spec))
         `(guard-par-partition ,final-spec ,(walk body))]
        [`(seq ,es ...) `(seq ,@(map walk es))]
        [`(invert ,sub) `(invert ,(walk sub))]
        [`(call-q ,callee . ,args) `(call-q ,callee ,@args)]
        [`(with-and-session ,bs ,b) `(with-and-session ,bs ,(walk b))]
        [`(within-apply-mbu ,c ,a ,ws) `(within-apply-mbu ,(walk c) ,(walk a) ,ws)]
        [`(within-apply ,c ,a ,ws) `(within-apply ,(walk c) ,(walk a) ,ws)]
        [`(erase-by ,f ,b ,ws) `(erase-by ,(walk f) ,(walk b) ,ws)]
        [`(erase-by-part-bij ,sp ,f ,b ,ws) `(erase-by-part-bij ,sp ,(walk f) ,(walk b) ,ws)]
        [`(guard-valid-if ,vp ,b) `(guard-valid-if ,vp ,(walk b))]
        [`(guard-involutory ,c ,op ,b) `(guard-involutory ,c ,op ,(walk b))]
        [`(guard-qblock-lcu-phase ,qb ,b) `(guard-qblock-lcu-phase ,qb ,(walk b))]
        [`(guard-wire-basis ,wb ,b) `(guard-wire-basis ,wb ,(walk b))]
        [`(guard-drift-eps ,ds ,b) `(guard-drift-eps ,ds ,(walk b))]
        [`(guard-single-ir ,ss ,b) `(guard-single-ir ,ss ,(walk b))]
        [`(canonicalize-quotient ,qws ,c) `(canonicalize-quotient ,qws ,(walk c))]
        [`(qmatch ,arms)
         `(qmatch ,(for/list ([arm (in-list arms)])
                     (list (first arm) (walk (second arm)))))]
        [`(focus-zipper ,sp ,b) `(focus-zipper ,sp ,(walk b))]
        [`(fold-braun ,nd) `(fold-braun ,(walk nd))]
        [`(braun-branch ,idx ,st ,l ,r)
         `(braun-branch ,idx ,(walk st) ,(walk l) ,(walk r))]
        [`(par-wires ,e1 ,e2) `(par-wires ,(walk e1) ,(walk e2))]
        [`(multishot-reset ,k ,b) `(multishot-reset ,k ,(walk b))]
        [_ e]))
    (propagate-surface-span! e rebuilt)))

(define (extract-first-surface-par-spec ast)
  (let walk ([e ast])
    (match e
      [`(guard-par-partition ,spec ,body)
       (or spec (walk body))]
      [`(seq ,es ...) (for/or ([sub (in-list es)]) (walk sub))]
      [`(invert ,sub) (walk sub)]
      [`(call-q ,callee . ,_)
       (and (lfq-circuit-decl? callee)
            (walk (lfq-circuit-decl-surface-ast callee)))]
      [`(with-and-session ,_ ,b) (walk b)]
      [`(within-apply-mbu ,c ,a ,_) (or (walk c) (walk a))]
      [`(within-apply ,c ,a ,_) (or (walk c) (walk a))]
      [`(erase-by ,f ,b ,_) (or (walk f) (walk b))]
      [`(erase-by-part-bij ,_ ,f ,b ,_) (or (walk f) (walk b))]
      [`(guard-valid-if ,_ ,b) (walk b)]
      [`(guard-involutory ,_ ,_ ,b) (walk b)]
      [`(guard-qblock-lcu-phase ,_ ,b) (walk b)]
      [`(guard-wire-basis ,_ ,b) (walk b)]
      [`(guard-drift-eps ,_ ,b) (walk b)]
      [`(guard-single-ir ,_ ,b) (walk b)]
      [`(canonicalize-quotient ,_ ,c) (walk c)]
      [`(qmatch ,arms) (for/or ([arm (in-list arms)]) (walk (second arm)))]
      [`(focus-zipper ,_ ,b) (walk b)]
      [`(fold-braun ,nd) (walk nd)]
      [`(braun-branch ,_ ,st ,l ,r) (or (walk st) (walk l) (walk r))]
      [`(par-wires ,e1 ,e2) (or (walk e1) (walk e2))]
      [`(multishot-reset ,_ ,b) (walk b)]
      [_ #f])))

(define (resolve-effective-cluster-spec prog decl total-phys-q
                                        #:ast-toffolis [ast-toffolis #f]
                                        #:q-cap [q-cap #f]
                                        #:r-bell [r-bell #f]
                                        #:topology [topology #f]
                                        #:max-machines [max-machines #f])
  (define profiles (if prog (lfq-program-cluster-profiles prog) '()))
  (define selected-entry (if (null? profiles) #f (last profiles)))
  (define explicit-slices
    (and selected-entry (lfq-cluster-profile-entry-qpu-wire-slices selected-entry)))
  (define raw-surface-spec
    (extract-first-surface-par-spec (lfq-circuit-decl-surface-ast decl)))
  (define surface-spec
    (match raw-surface-spec
      [`(par-partition-bundle ,subs ...)
       (if (null? subs) #f (last subs))]
      [_ raw-surface-spec]))
  (define base-spec
    (cond
      [selected-entry (lfq-cluster-profile-entry-spec selected-entry)]
      [surface-spec surface-spec]
      [else
       (define default-paradigm
         (if (eq? (lfq-circuit-decl-kind decl) 'defqfree)
             'grover-amplify
             'algebraic-limb))
       (par-cluster-opt-spec
        #:workload (lfq-circuit-decl-name decl)
        #:paradigm default-paradigm
        #:max-machines (or max-machines 256)
        #:q-cap-per-machine (or q-cap 400)
        #:raw-bell-rate-hz (or r-bell 100000.0)
        #:q-single 'auto
        #:q-data-dist 'auto
        #:q-local-fixed 2
        #:q-peer-sync 1
        #:window-bits 3
        #:num-windows 1
        #:local-toffolis 'auto
        #:carry-scheme 'qrns-zero-carry
        #:lookup-scheme 'law-u4-ghz-mx
        #:interconnect-topology (or topology 'all-to-all-peers))]))
  (define resolved-spec
    (resolve-auto-par-cluster-spec base-spec decl total-phys-q ast-toffolis))
  (define eff-spec
    (override-par-cluster-spec resolved-spec
                               #:q-cap q-cap
                               #:r-bell r-bell
                               #:topology topology
                               #:max-machines max-machines))
  (values eff-spec explicit-slices))

;; =============================================================================
;; 2. Disjoint Wire Partitioning Across `M*` QPUs
;; =============================================================================

(define (isa-op-wires op)
  (match op
    [`(,(or 'isa-x 'isa-z 'isa-s 'isa-sdg 'isa-h) ,w) (list w)]
    [`(,(or 'isa-ry 'isa-rz) ,_ ,w) (list w)]
    [`(,(or 'isa-cx 'isa-cz 'isa-swap) ,a ,b) (list a b)]
    [`(,(or 'isa-ccx 'isa-temp-and-ccx) ,a ,b ,c) (list a b c)]
    [`(isa-meas-x-cond-cz-reset ,anc ,_ ,c1 ,c2) (list anc c1 c2)]
    [`(isa-meas-x-cond-z-reset ,anc ,_ ,t) (list anc t)]
    [`(isa-meas-x-reset ,anc ,_) (list anc)]
    [`(isa-cond-z ,_ ,t) (list t)]
    [`(isa-cond-cz ,_ ,c1 ,c2) (list c1 c2)]
    [_ '()]))

(define (validate-and-complete-slices raw-slices total-phys-q m-star)
  (define seen (mutable-seteqv))
  (define cleaned
    (for/list ([sl (in-list raw-slices)])
      (for/list ([w (in-list sl)] #:when (< w total-phys-q))
        (when (set-member? seen w)
          (error 'partition-wires-across-qpus
                 "Duplicate wire q[~a] across QPU slices ~a" w raw-slices))
        (set-add! seen w)
        w)))
  (define unassigned
    (for/list ([w (in-range total-phys-q)]
               #:when (not (set-member? seen w)))
      w))
  (cond
    [(null? unassigned) cleaned]
    [else
     (define vec (list->vector cleaned))
     (for ([w (in-list unassigned)] [idx (in-naturals)])
       (define p (modulo idx m-star))
       (vector-set! vec p (append (vector-ref vec p) (list w))))
     (vector->list vec)]))

;; Automatic QPU wire partitioning when `M* >= 2` and no explicit `M*`-slice map is supplied:
;; Groups local 3-qubit Toffoli clusters (`ccx`), local `cz`/`swap`, and `MBU` `cond-cz`
;; clusters together first so non-Bell multi-qubit gates remain strictly QPU-local, then
;; balances components evenly across `0 .. M*-1`.
(define (auto-partition-wires total-phys-q m-star isa-ops)
  (define parent (for/vector ([i (in-range total-phys-q)]) i))
  (define (uf-find x)
    (define p (vector-ref parent x))
    (if (= p x)
        x
        (let ([r (uf-find p)])
          (vector-set! parent x r)
          r)))
  (define (uf-union! a b)
    (when (and (< a total-phys-q) (< b total-phys-q))
      (define ra (uf-find a))
      (define rb (uf-find b))
      (unless (= ra rb)
        (vector-set! parent (max ra rb) (min ra rb)))))

  (define meas-wire-map (make-hasheqv))
  (for ([op (in-list isa-ops)])
    (match op
      [`(isa-meas-x-reset ,anc ,mk) (hash-set! meas-wire-map mk anc)]
      [_ (void)]))

  ;; Co-locate wires that share QPU-local operations:
  (for ([op (in-list isa-ops)])
    (match op
      [`(,(or 'isa-ccx 'isa-temp-and-ccx) ,a ,b ,c)
       (uf-union! a b)
       (uf-union! b c)]
      [`(,(or 'isa-cz 'isa-swap) ,a ,b)
       (uf-union! a b)]
      [`(isa-meas-x-cond-cz-reset ,anc ,_ ,c1 ,c2)
       (uf-union! anc c1)
       (uf-union! c1 c2)]
      [`(isa-cond-cz ,mk ,c1 ,c2)
       (uf-union! c1 c2)
       (when (hash-has-key? meas-wire-map mk)
         (uf-union! (hash-ref meas-wire-map mk) c1))]
      [_ (void)]))

  (define comp-table (make-hasheqv))
  (for ([w (in-range total-phys-q)])
    (define r (uf-find w))
    (hash-set! comp-table r (append (hash-ref comp-table r '()) (list w))))

  (define comps
    (sort (for/list ([(_ ws) (in-hash comp-table)]) ws)
          (lambda (a b)
            (if (= (length a) (length b))
                (< (first a) (first b))
                (> (length a) (length b))))))

  (define bins (make-vector m-star '()))
  (for ([comp (in-list comps)])
    ;; Place component into the lightest QPU bin:
    (define best-p
      (for/fold ([bp 0] [best-len (length (vector-ref bins 0))] #:result bp)
                ([p (in-range 1 m-star)])
        (define lp (length (vector-ref bins p)))
        (if (< lp best-len) (values p lp) (values bp best-len))))
    (vector-set! bins best-p (append (vector-ref bins best-p) comp)))

  (for/list ([p (in-range m-star)])
    (sort (vector-ref bins p) <)))

(define (partition-wires-across-qpus total-phys-q m-star isa-ops [explicit-slices #f])
  (define n-q (max 1 total-phys-q))
  (cond
    [(<= m-star 1)
     (list (range n-q))]
    [(and explicit-slices (= (length explicit-slices) m-star))
     (validate-and-complete-slices explicit-slices n-q m-star)]
    [else
     (auto-partition-wires n-q m-star isa-ops)]))

;; =============================================================================
;; 3. Multi-QPU `MachineISA` Slicing, Per-QPU OpenQASM 3.0 & Joint Aer Emission
;; =============================================================================

(define (fmt-qasm-float x)
  (~r (exact->inexact x) #:precision '(= 12)))

(define (effective-slice-machines opt-info)
  (cond
    [(hash-has-key? opt-info 'machines_per_shot_instance)
     (hash-ref opt-info 'machines_per_shot_instance 1)]
    [(equal? (hash-ref opt-info 'qpar_grade "") "ParShotLinear")
     1]
    [else
     (hash-ref opt-info 'optimal_machines
               (hash-ref opt-info 'machines_used 1))]))

(define (emit-partitioned-cluster-qasm3! out-dir
                                         circ-name
                                         target-sym
                                         eff-spec
                                         opt-res
                                         isa-ops
                                         total-phys-q
                                         explicit-slices)
  (define m-star (effective-slice-machines opt-res))
  (define slices (partition-wires-across-qpus total-phys-q m-star isa-ops explicit-slices))

  ;; Map each global wire `w` -> `(cons qpu_id local_idx)`:
  (define wire->qpu (make-hasheqv))
  (define wire->loc (make-hasheqv))
  (for ([sl (in-list slices)] [p (in-naturals)])
    (for ([w (in-list sl)] [loc-i (in-naturals)])
      (hash-set! wire->qpu w p)
      (hash-set! wire->loc w loc-i)))

  (define (qpu-of w) (hash-ref wire->qpu w 0))
  (define (loc-of w) (hash-ref wire->loc w 0))

  ;; Pre-scan unfused `isa-meas-x-reset` + `isa-cond-z` pairs to identify cross-QPU vs local consumers:
  (define prescan-origin-qpu (make-hasheqv))
  (define cross-qpu-meas-syms (mutable-set))
  (define local-qpu-meas-syms (mutable-set))
  (for ([op (in-list isa-ops)])
    (match op
      [`(isa-meas-x-reset ,anc ,mk)
       (hash-set! prescan-origin-qpu mk (qpu-of anc))]
      [`(isa-cond-z ,mk ,t)
       (when (hash-has-key? prescan-origin-qpu mk)
         (if (= (hash-ref prescan-origin-qpu mk) (qpu-of t))
             (set-add! local-qpu-meas-syms mk)
             (set-add! cross-qpu-meas-syms mk)))]
      [`(isa-cond-cz ,mk ,_ ,_)
       (set-add! local-qpu-meas-syms mk)]
      [_ (void)]))

  ;; Per-QPU instruction buffers & classical/link register counters:
  (define qpu-stmts (make-vector m-star '()))
  (define (push-qpu! p . lines)
    (vector-set! qpu-stmts p (append (vector-ref qpu-stmts p) lines)))

  (define qpu-has-bell-tx? (make-vector m-star #f))
  (define qpu-has-bell-rx? (make-vector m-star #f))
  (define qpu-has-ff-z? (make-vector m-star #f))
  (define qpu-bell-tx-bits (make-vector m-star 0))
  (define qpu-bell-rx-bits (make-vector m-star 0))
  (define qpu-u4-tx-bits (make-vector m-star 0))
  (define qpu-u4-rx-bits (make-vector m-star 0))
  (define qpu-local-mbits (make-vector m-star 0))

  (define (alloc-vec-counter! vec p)
    (define k (vector-ref vec p))
    (vector-set! vec p (add1 k))
    k)

  ;; Track `isa-meas-x-reset` measurements that might later trigger `isa-cond-z`:
  (define meas-k->origin-qpu (make-hasheqv))
  (define meas-k->origin-wire (make-hasheqv))
  (define meas-k->local-bit (make-hasheqv))
  (define meas-k->u4-tx-bit (make-hasheqv))

  ;; Track active cat-entangled `(cons src dst)` wire pairs to distinguish forward vs reverse ebits:
  (define active-cat-pairs (mutable-set))

  ;; Joint multi-QPU Aer circuit buffer (`qubit[total-phys-q + 1] q;`, where `q[bell-tx-wire]`
  ;; is the optical Bell transceiver buffer qubit, deterministically reset to `|0>` after each ebit):
  (define n-base-q (max 1 total-phys-q))
  (define bell-tx-wire n-base-q)
  (define joint-clbit-box (box 0))
  (define (alloc-joint-clbit!)
    (define c (unbox joint-clbit-box))
    (set-box! joint-clbit-box (add1 c))
    c)
  (define joint-lines '())
  (define (push-joint! . lines)
    (set! joint-lines (append joint-lines lines)))

  ;; Structured Bell-pair & classical feedforward schedules:
  (define bell-events '())
  (define ff-events '())
  (define forward-ebits-box (box 0))
  (define reverse-ebits-box (box 0))
  (define carry-ebits-box (box 0))

  (define spec-kws (match eff-spec [`(par-cluster-opt-spec . ,kws) kws] [_ '()]))
  (define carry-scheme (plist-ref spec-kws '#:carry-scheme 'qrns-zero-carry))
  (define lookup-scheme (plist-ref spec-kws '#:lookup-scheme 'law-u4-ghz-mx))
  (define window-bits (plist-ref spec-kws '#:window-bits 0))
  (define num-windows (plist-ref spec-kws '#:num-windows 0))
  (define topology (plist-ref spec-kws '#:interconnect-topology 'all-to-all-peers))
  (define q-cap-val (plist-ref spec-kws '#:q-cap-per-machine 400))

  (define (record-bell-cx! src dst)
    (define p-src (qpu-of src))
    (define p-dst (qpu-of dst))
    (define pair-key (cons src dst))
    (define is-reverse? (set-member? active-cat-pairs pair-key))
    (define ebit-id (length bell-events))
    (cond
      [is-reverse?
       (set-remove! active-cat-pairs pair-key)
       (set-box! reverse-ebits-box (add1 (unbox reverse-ebits-box)))]
      [else
       (set-add! active-cat-pairs pair-key)
       (set-box! forward-ebits-box (add1 (unbox forward-ebits-box)))])
    (vector-set! qpu-has-bell-tx? p-src #t)
    (vector-set! qpu-has-bell-rx? p-dst #t)
    (define tx-b (alloc-vec-counter! qpu-bell-tx-bits p-src))
    (define rx-b (alloc-vec-counter! qpu-bell-rx-bits p-dst))
    (push-qpu! p-src
               (format "// Ebit #~a (~a): QPU ~a q[~a] -> QPU ~a q[~a]"
                       ebit-id (if is-reverse? "reverse" "forward")
                       p-src (loc-of src) p-dst (loc-of dst))
               "@lakefillq.ghz_cat_tx"
               (format "ghz_cat_tx q[~a], ebit[0];" (loc-of src))
               (format "m_bell_tx[~a] = measure ebit[0];" tx-b)
               "reset ebit[0];")
    (push-qpu! p-dst
               (format "// Ebit #~a (~a): receive optical Bell half from QPU ~a"
                       ebit-id (if is-reverse? "reverse" "forward") p-src)
               "@lakefillq.ghz_cat_rx"
               (format "ghz_cat_rx q[~a];" (loc-of dst))
               (format "if (rx_bell[~a] == true) { x q[~a]; }" rx-b (loc-of dst)))
    (cond
      [(not is-reverse?)
       (define jc (alloc-joint-clbit!))
       (push-joint!
        (format "// Forward Bell pair #~a (QPU ~a q[~a] -> QPU ~a q[~a])"
                ebit-id p-src src p-dst dst)
        (format "h q[~a];" bell-tx-wire)
        (format "cx q[~a], q[~a];" bell-tx-wire dst)
        (format "cx q[~a], q[~a];" src bell-tx-wire)
        (format "m[~a] = measure q[~a];" jc bell-tx-wire)
        (format "reset q[~a];" bell-tx-wire)
        (format "if (m[~a] == true) { x q[~a]; }" jc dst))]
      [else
       (push-joint!
        (format "// Reverse cross-QPU CNOT #~a (QPU ~a q[~a] -> QPU ~a q[~a])"
                ebit-id p-src src p-dst dst)
        (format "cx q[~a], q[~a];" src dst))])
    (set! bell-events
          (append bell-events
                  (list (hasheq 'ebit_id ebit-id
                                'direction (if is-reverse? "reverse" "forward")
                                'kind "ghz_cat_entangle"
                                'src_qpu p-src
                                'dst_qpu p-dst
                                'src_global_wire src
                                'dst_global_wire dst
                                'src_local_wire (loc-of src)
                                'dst_local_wire (loc-of dst)
                                'tx_bit_index tx-b
                                'rx_bit_index rx-b
                                'ebits_consumed 1)))))

  (define (record-u4-cross-disentangle! cat-w mk target-w)
    (define p-cat (qpu-of cat-w))
    (define p-tgt (qpu-of target-w))
    (set-remove! active-cat-pairs (cons target-w cat-w))
    (vector-set! qpu-has-ff-z? p-tgt #t)
    (define tx-u (alloc-vec-counter! qpu-u4-tx-bits p-cat))
    (define rx-u (alloc-vec-counter! qpu-u4-rx-bits p-tgt))
    (define ff-id (length ff-events))
    (push-qpu! p-cat
               (format "// Law U4 M_X disentangle #~a (0 ebits): QPU ~a q[~a] -> QPU ~a q[~a]"
                       ff-id p-cat (loc-of cat-w) p-tgt (loc-of target-w))
               "@lakefillq.u4_mx_disentangle"
               (format "h q[~a];" (loc-of cat-w))
               (format "m_u4_tx[~a] = measure q[~a];" tx-u (loc-of cat-w))
               (format "reset q[~a];" (loc-of cat-w)))
    (push-qpu! p-tgt
               (format "// Law U4 classical Z fixup #~a from QPU ~a (0 ebits)"
                       ff-id p-cat)
               "@lakefillq.feedforward_cond_z"
               (format "if (rx_u4[~a] == true) { feedforward_cond_z q[~a]; }"
                       rx-u (loc-of target-w)))
    (define jc (alloc-joint-clbit!))
    (push-joint!
     (format "// Law U4 zero-ebit M_X disentanglement #~a (QPU ~a q[~a] -> QPU ~a q[~a])"
             ff-id p-cat cat-w p-tgt target-w)
     (format "h q[~a];" cat-w)
     (format "m[~a] = measure q[~a];" jc cat-w)
     (format "if (m[~a] == true) { z q[~a]; }" jc target-w)
     (format "reset q[~a];" cat-w))
    (set! ff-events
          (append ff-events
                  (list (hasheq 'feedforward_id ff-id
                                'meas_clbit (if (symbol? mk) (symbol->string mk) mk)
                                'law "U4-QTainted-MX"
                                'src_qpu p-cat
                                'dst_qpu p-tgt
                                'cat_global_wire cat-w
                                'target_global_wire target-w
                                'cat_local_wire (loc-of cat-w)
                                'target_local_wire (loc-of target-w)
                                'tx_u4_bit_index tx-u
                                'rx_u4_bit_index rx-u
                                'ebits_consumed 0)))))

  ;; Walk `isa-ops` and slice across `qpu_0 .. qpu_{M*-1}`:
  (for ([op (in-list isa-ops)])
    (match op
      [`(isa-x ,w)
       (push-qpu! (qpu-of w) (format "x q[~a];" (loc-of w)))
       (push-joint! (format "x q[~a];" w))]
      [`(isa-z ,w)
       (push-qpu! (qpu-of w) (format "z q[~a];" (loc-of w)))
       (push-joint! (format "z q[~a];" w))]
      [`(isa-s ,w)
       (push-qpu! (qpu-of w) (format "s q[~a];" (loc-of w)))
       (push-joint! (format "s q[~a];" w))]
      [`(isa-sdg ,w)
       (push-qpu! (qpu-of w) (format "sdg q[~a];" (loc-of w)))
       (push-joint! (format "sdg q[~a];" w))]
      [`(isa-h ,w)
       (push-qpu! (qpu-of w) (format "h q[~a];" (loc-of w)))
       (push-joint! (format "h q[~a];" w))]
      [`(isa-ry ,th ,w)
       (push-qpu! (qpu-of w) (format "ry(~a) q[~a];" (fmt-qasm-float th) (loc-of w)))
       (push-joint! (format "ry(~a) q[~a];" (fmt-qasm-float th) w))]
      [`(isa-rz ,th ,w)
       (push-qpu! (qpu-of w) (format "rz(~a) q[~a];" (fmt-qasm-float th) (loc-of w)))
       (push-joint! (format "rz(~a) q[~a];" (fmt-qasm-float th) w))]
      [`(isa-cx ,c ,t)
       (if (= (qpu-of c) (qpu-of t))
           (begin
             (push-qpu! (qpu-of c) (format "cx q[~a], q[~a];" (loc-of c) (loc-of t)))
             (push-joint! (format "cx q[~a], q[~a];" c t)))
           (record-bell-cx! c t))]
      [`(isa-cz ,a ,b)
       (unless (= (qpu-of a) (qpu-of b))
         (error 'emit-cluster-openqasm3-bundle!
                "Cross-QPU CZ (~a, ~a) encountered outside Bell schedule" a b))
       (push-qpu! (qpu-of a) (format "cz q[~a], q[~a];" (loc-of a) (loc-of b)))
       (push-joint! (format "cz q[~a], q[~a];" a b))]
      [`(isa-swap ,a ,b)
       (unless (= (qpu-of a) (qpu-of b))
         (error 'emit-cluster-openqasm3-bundle!
                "Cross-QPU SWAP (~a, ~a) forbidden in zero-carry QPU partition" a b))
       (push-qpu! (qpu-of a) (format "swap q[~a], q[~a];" (loc-of a) (loc-of b)))
       (push-joint! (format "swap q[~a], q[~a];" a b))]
      [`(,(or 'isa-ccx 'isa-temp-and-ccx) ,c1 ,c2 ,t)
       (unless (and (= (qpu-of c1) (qpu-of c2))
                    (= (qpu-of c2) (qpu-of t)))
         (error 'emit-cluster-openqasm3-bundle!
                "Cross-QPU Toffoli (~a, ~a, ~a) violates wire-disjoint QPU slice closure"
                c1 c2 t))
       (push-qpu! (qpu-of t)
                  (format "ccx q[~a], q[~a], q[~a];" (loc-of c1) (loc-of c2) (loc-of t)))
       (push-joint! (format "ccx q[~a], q[~a], q[~a];" c1 c2 t))]
      [`(isa-meas-x-cond-z-reset ,anc ,mk ,t)
       (if (= (qpu-of anc) (qpu-of t))
           (let ([p (qpu-of anc)]
                 [lb (alloc-vec-counter! qpu-local-mbits (qpu-of anc))]
                 [jc (alloc-joint-clbit!)])
             (push-qpu! p
                        (format "h q[~a];" (loc-of anc))
                        (format "m_local[~a] = measure q[~a];" lb (loc-of anc))
                        (format "if (m_local[~a] == true) { z q[~a]; }" lb (loc-of t))
                        (format "reset q[~a];" (loc-of anc)))
             (push-joint! (format "h q[~a];" anc)
                          (format "m[~a] = measure q[~a];" jc anc)
                          (format "if (m[~a] == true) { z q[~a]; }" jc t)
                          (format "reset q[~a];" anc)))
           (record-u4-cross-disentangle! anc mk t))]
      [`(isa-meas-x-cond-cz-reset ,anc ,_ ,c1 ,c2)
       (unless (and (= (qpu-of anc) (qpu-of c1))
                    (= (qpu-of c1) (qpu-of c2)))
         (error 'emit-cluster-openqasm3-bundle!
                "Cross-QPU MBU cond-CZ (~a -> ~a, ~a) unsupported across slices" anc c1 c2))
       (define p (qpu-of anc))
       (define lb (alloc-vec-counter! qpu-local-mbits p))
       (define jc (alloc-joint-clbit!))
       (push-qpu! p
                  (format "h q[~a];" (loc-of anc))
                  (format "m_local[~a] = measure q[~a];" lb (loc-of anc))
                  (format "if (m_local[~a] == true) { cz q[~a], q[~a]; }"
                          lb (loc-of c1) (loc-of c2))
                  (format "reset q[~a];" (loc-of anc)))
       (push-joint! (format "h q[~a];" anc)
                    (format "m[~a] = measure q[~a];" jc anc)
                    (format "if (m[~a] == true) { cz q[~a], q[~a]; }" jc c1 c2)
                    (format "reset q[~a];" anc))]
      [`(isa-meas-x-reset ,anc ,mk)
       (define p (qpu-of anc))
       (define jc (alloc-joint-clbit!))
       (define is-cross? (set-member? cross-qpu-meas-syms mk))
       (define is-local? (or (not is-cross?) (set-member? local-qpu-meas-syms mk)))
       (define lb (if is-local? (alloc-vec-counter! qpu-local-mbits p) 0))
       (hash-set! meas-k->origin-qpu mk p)
       (hash-set! meas-k->origin-wire mk anc)
       (hash-set! meas-k->local-bit mk (cons lb jc))
       (cond
         [(and is-cross? is-local?)
          (define tx-u (alloc-vec-counter! qpu-u4-tx-bits p))
          (hash-set! meas-k->u4-tx-bit mk tx-u)
          (push-qpu! p
                     "@lakefillq.u4_mx_disentangle"
                     (format "h q[~a];" (loc-of anc))
                     (format "m_u4_tx[~a] = measure q[~a];" tx-u (loc-of anc))
                     (format "m_local[~a] = m_u4_tx[~a];" lb tx-u)
                     (format "reset q[~a];" (loc-of anc)))]
         [is-cross?
          (define tx-u (alloc-vec-counter! qpu-u4-tx-bits p))
          (hash-set! meas-k->u4-tx-bit mk tx-u)
          (push-qpu! p
                     "@lakefillq.u4_mx_disentangle"
                     (format "h q[~a];" (loc-of anc))
                     (format "m_u4_tx[~a] = measure q[~a];" tx-u (loc-of anc))
                     (format "reset q[~a];" (loc-of anc)))]
         [else
          (push-qpu! p
                     (format "h q[~a];" (loc-of anc))
                     (format "m_local[~a] = measure q[~a];" lb (loc-of anc))
                     (format "reset q[~a];" (loc-of anc)))])
       (push-joint! (format "h q[~a];" anc)
                    (format "m[~a] = measure q[~a];" jc anc)
                    (format "reset q[~a];" anc))]
      [`(isa-cond-z ,mk ,t)
       (define p-orig (hash-ref meas-k->origin-qpu mk (qpu-of t)))
       (define pair-bj (hash-ref meas-k->local-bit mk (cons 0 0)))
       (define p-tgt (qpu-of t))
       (cond
         [(= p-orig p-tgt)
          (push-qpu! p-tgt
                     (format "if (m_local[~a] == true) { z q[~a]; }"
                             (car pair-bj) (loc-of t)))
          (push-joint! (format "if (m[~a] == true) { z q[~a]; }" (cdr pair-bj) t))]
         [else
          (vector-set! qpu-has-ff-z? p-tgt #t)
          (define rx-u (alloc-vec-counter! qpu-u4-rx-bits p-tgt))
          (define tx-u (hash-ref meas-k->u4-tx-bit mk 0))
          (define orig-w (hash-ref meas-k->origin-wire mk 0))
          (set-remove! active-cat-pairs (cons t orig-w))
          (push-qpu! p-tgt
                     "@lakefillq.feedforward_cond_z"
                     (format "if (rx_u4[~a] == true) { feedforward_cond_z q[~a]; }"
                             rx-u (loc-of t)))
          (push-joint! (format "if (m[~a] == true) { z q[~a]; }" (cdr pair-bj) t))
          (set! ff-events
                (append ff-events
                        (list (hasheq 'feedforward_id (length ff-events)
                                      'meas_clbit (if (symbol? mk) (symbol->string mk) mk)
                                      'law "U4-QTainted-MX"
                                      'src_qpu p-orig
                                      'dst_qpu p-tgt
                                      'cat_global_wire orig-w
                                      'target_global_wire t
                                      'cat_local_wire (loc-of orig-w)
                                      'target_local_wire (loc-of t)
                                      'tx_u4_bit_index tx-u
                                      'rx_u4_bit_index rx-u
                                      'ebits_consumed 0))))])]
      [`(isa-cond-cz ,mk ,c1 ,c2)
       (define pair-bj (hash-ref meas-k->local-bit mk (cons 0 0)))
       (define p (qpu-of c1))
       (push-qpu! p
                  (format "if (m_local[~a] == true) { cz q[~a], q[~a]; }"
                          (car pair-bj) (loc-of c1) (loc-of c2)))
       (push-joint! (format "if (m[~a] == true) { cz q[~a], q[~a]; }"
                            (cdr pair-bj) c1 c2))]
      [_ (error 'emit-cluster-openqasm3-bundle! "Unhandled MachineISA op: ~a" op)]))

  ;; Write `qpu_0.qasm .. qpu_{M*-1}.qasm`:
  (define qpu-files '())
  (define qpu-alloc-qubits '())
  (for ([p (in-range m-star)]
        [sl (in-list slices)])
    (define fname (format "qpu_~a.qasm" p))
    (define fpath (build-path out-dir fname))
    (define n-loc (max 1 (length sl)))
    (define has-tx? (vector-ref qpu-has-bell-tx? p))
    (define has-rx? (vector-ref qpu-has-bell-rx? p))
    (define has-ff? (vector-ref qpu-has-ff-z? p))
    (define n-btx (vector-ref qpu-bell-tx-bits p))
    (define n-brx (vector-ref qpu-bell-rx-bits p))
    (define n-utx (vector-ref qpu-u4-tx-bits p))
    (define n-urx (vector-ref qpu-u4-rx-bits p))
    (define n-loc-m (vector-ref qpu-local-mbits p))
    (define phys-on-qpu (+ n-loc (if has-tx? 1 0)))

    (define header-lines
      (append
       (list "OPENQASM 3.0;"
             "include \"stdgates.inc\";"
             (format "// Circuit: ~a | QPU ~a of ~a | Global wires: ~a"
                     circ-name p m-star sl))
       (if has-tx?
           (list "gate ghz_cat_tx src_q, link_ebit { cx src_q, link_ebit; }")
           '())
       (if has-rx?
           (list "gate ghz_cat_rx cat_wire { id cat_wire; }")
           '())
       (if has-ff?
           (list "gate feedforward_cond_z tgt_q { z tgt_q; }")
           '())
       (list (format "qubit[~a] q;" n-loc))
       (if has-tx? (list "qubit[1] ebit;") '())
       (if (> n-btx 0) (list (format "bit[~a] m_bell_tx;" n-btx)) '())
       (if (> n-brx 0) (list (format "bit[~a] rx_bell;" n-brx)) '())
       (if (> n-utx 0) (list (format "bit[~a] m_u4_tx;" n-utx)) '())
       (if (> n-urx 0) (list (format "bit[~a] rx_u4;" n-urx)) '())
       (if (> n-loc-m 0) (list (format "bit[~a] m_local;" n-loc-m)) '())))

    (define qasm-body
      (string-append (string-join (append header-lines (vector-ref qpu-stmts p)) "\n") "\n"))
    (call-with-output-file fpath
      (lambda (out) (display qasm-body out))
      #:exists 'replace)
    (set! qpu-files (append qpu-files (list fname)))
    (set! qpu-alloc-qubits (append qpu-alloc-qubits (list phys-on-qpu))))

  ;; Write `joint_cluster_aer.qasm`:
  (define joint-total-q (+ n-base-q (if (> (unbox forward-ebits-box) 0) 1 0)))
  (define joint-total-c (unbox joint-clbit-box))
  (define joint-header
    (append
     (list "OPENQASM 3.0;"
           "include \"stdgates.inc\";"
           (format "// Stitched Multi-QPU Aer Verification Circuit (~a QPUs, ~a base wires)"
                   m-star n-base-q))
     (for/list ([sl (in-list slices)] [p (in-naturals)])
       (format "// QPU ~a slice wires: ~a" p sl))
     (if (> (unbox forward-ebits-box) 0)
         (list (format "// Optical Bell transceiver wire: q[~a] (reset to |0> after every ebit)"
                       bell-tx-wire))
         '())
     (list (format "qubit[~a] q;" joint-total-q))
     (if (> joint-total-c 0)
         (list (format "bit[~a] m;" joint-total-c))
         '())))
  (define joint-path (build-path out-dir "joint_cluster_aer.qasm"))
  (call-with-output-file joint-path
    (lambda (out)
      (display (string-append (string-join (append joint-header joint-lines) "\n") "\n") out))
    #:exists 'replace)

  ;; Write `ebit_schedule.json`:
  (define fwd-ebits (unbox forward-ebits-box))
  (define rev-ebits (unbox reverse-ebits-box))
  (define car-ebits (unbox carry-ebits-box))
  (define tot-ebits (+ fwd-ebits rev-ebits car-ebits))
  (define solver-lookup-ebits (hash-ref opt-res 'lookup_ebits_total 0))
  (define solver-carry-ebits (hash-ref opt-res 'carry_ebits_total 0))
  (define expected-u4-fwd
    (if (and (eq? lookup-scheme 'law-u4-ghz-mx) (> window-bits 0) (> num-windows 0))
        (* num-windows window-bits (sub1 m-star))
        fwd-ebits))

  (define ebit-sched-js
    (hasheq
     'circuit_name (symbol->string circ-name)
     'm_star m-star
     'optimal_m_star m-star
     'interconnect_topology (symbol->string topology)
     'carry_scheme (symbol->string carry-scheme)
     'lookup_scheme (symbol->string lookup-scheme)
     'window_bits window-bits
     'num_windows num-windows
     'forward_ebits fwd-ebits
     'reverse_ebits rev-ebits
     'carry_ebits car-ebits
     'total_logical_ebits tot-ebits
     'expected_law_u4_forward_ebits expected-u4-fwd
     'solver_lookup_ebits_total solver-lookup-ebits
     'solver_carry_ebits_total solver-carry-ebits
     'fallback_to_single_qpu #f
     'fallback_to_single_machine #f
     'monolithic_single_chip_optimal #f
     'law_u4_forward_only_verified (and (= rev-ebits 0)
                                        (= car-ebits 0)
                                        (set-empty? active-cat-pairs)
                                        (= fwd-ebits (length ff-events)))
     'classical_feedforward_count (length ff-events)
     'qpu_wire_slices slices
     'qpu_qubit_counts qpu-alloc-qubits
     'bell_pair_events bell-events
     'classical_feedforward_events ff-events))

  (call-with-output-file (build-path out-dir "ebit_schedule.json")
    (lambda (out) (write-json ebit-sched-js out) (newline out))
    #:exists 'replace)

  ;; Write `cluster_manifest.json`:
  (define manifest-js
    (hasheq
     'circuit_name (symbol->string circ-name)
     'target_profile (symbol->string target-sym)
     'paradigm (hash-ref opt-res 'paradigm "algebraic-limb")
     'interconnect_topology (symbol->string topology)
     'q_cap_per_machine q-cap-val
     'm_star m-star
     'optimal_m_star m-star
     'logical_ebits tot-ebits
     'forward_ebits fwd-ebits
     'reverse_ebits rev-ebits
     'carry_ebits car-ebits
     'fallback_or_monolithic #f
     'fallback_to_single_qpu #f
     'fallback_to_single_machine #f
     'monolithic_single_chip_optimal #f
     'qpu_files qpu-files
     'qpu_wire_slices slices
     'qpu_qubit_counts qpu-alloc-qubits
     'ebit_schedule_file "ebit_schedule.json"
     'joint_cluster_aer_file "joint_cluster_aer.qasm"
     'solver_decision opt-res))

  (call-with-output-file (build-path out-dir "cluster_manifest.json")
    (lambda (out) (write-json manifest-js out) (newline out))
    #:exists 'replace)

  manifest-js)

(define (emit-cluster-openqasm3-bundle! out-dir
                                        prog
                                        decl
                                        target-sym
                                        isa-ops
                                        total-phys-q
                                        monolithic-qasm3-text
                                        #:ast-toffolis [ast-toffolis #f]
                                        #:q-cap [q-cap #f]
                                        #:r-bell [r-bell #f]
                                        #:topology [topology #f]
                                        #:max-machines [max-machines #f])
  (make-directory* out-dir)
  (define eff-toffolis (or ast-toffolis (count-isa-toffolis isa-ops)))
  (define-values (eff-spec explicit-slices)
    (resolve-effective-cluster-spec prog decl total-phys-q
                                    #:ast-toffolis eff-toffolis
                                    #:q-cap q-cap
                                    #:r-bell r-bell
                                    #:topology topology
                                    #:max-machines max-machines))
  (define par-res (compile-parallel-with-fallback eff-spec))
  (unless (lfq-typecheck-result-well-typed? par-res)
    (error 'emit-cluster-openqasm3-bundle!
           "T-ParGuard rejected cluster configuration: ~a"
           (lfq-typecheck-result-diagnostics par-res)))

  (define opt-res (lfq-typecheck-result-metrics par-res))
  (define m-star (effective-slice-machines opt-res))
  (define spec-kws (match eff-spec [`(par-cluster-opt-spec . ,kws) kws] [_ '()]))
  (define topology-sym (plist-ref spec-kws '#:interconnect-topology 'all-to-all-peers))
  (define carry-scheme (plist-ref spec-kws '#:carry-scheme 'none))
  (define lookup-scheme (plist-ref spec-kws '#:lookup-scheme 'none))
  (define window-bits (plist-ref spec-kws '#:window-bits 0))
  (define num-windows (plist-ref spec-kws '#:num-windows 0))
  (define q-cap-val (plist-ref spec-kws '#:q-cap-per-machine 400))

  (cond
    [(<= m-star 1)
     (define qpu0-path (build-path out-dir "qpu_0.qasm"))
     (define qpu0-strict-qasm3
       (regexp-replace* #rx"== 1\\)" monolithic-qasm3-text "== true)"))
     (call-with-output-file qpu0-path
       (lambda (out) (display qpu0-strict-qasm3 out))
       #:exists 'replace)
     (define fb-mach? (if (hash-ref opt-res 'fallback_to_single_machine #f) #t #f))
     (define mono-opt? (if (hash-ref opt-res 'monolithic_single_chip_optimal #f) #t #f))
     (define ebit-sched-js
       (hasheq
        'circuit_name (symbol->string (lfq-circuit-decl-name decl))
        'm_star 1
        'optimal_m_star 1
        'interconnect_topology (symbol->string topology-sym)
        'carry_scheme (symbol->string carry-scheme)
        'lookup_scheme (symbol->string lookup-scheme)
        'window_bits window-bits
        'num_windows num-windows
        'forward_ebits 0
        'reverse_ebits 0
        'carry_ebits 0
        'total_logical_ebits 0
        'expected_law_u4_forward_ebits 0
        'solver_lookup_ebits_total 0
        'solver_carry_ebits_total 0
        'fallback_to_single_qpu #t
        'fallback_to_single_machine fb-mach?
        'monolithic_single_chip_optimal mono-opt?
        'law_u4_forward_only_verified #t
        'classical_feedforward_count 0
        'qpu_wire_slices (list (range (max 1 total-phys-q)))
        'qpu_qubit_counts (list (max 1 total-phys-q))
        'bell_pair_events '()
        'classical_feedforward_events '()))
     (call-with-output-file (build-path out-dir "ebit_schedule.json")
       (lambda (out) (write-json ebit-sched-js out) (newline out))
       #:exists 'replace)
     (define manifest-js
       (hasheq
        'circuit_name (symbol->string (lfq-circuit-decl-name decl))
        'target_profile (symbol->string target-sym)
        'paradigm (hash-ref opt-res 'paradigm "grover-amplify")
        'interconnect_topology (symbol->string topology-sym)
        'q_cap_per_machine q-cap-val
        'm_star 1
        'optimal_m_star 1
        'logical_ebits 0
        'forward_ebits 0
        'reverse_ebits 0
        'carry_ebits 0
        'fallback_or_monolithic #t
        'fallback_to_single_qpu #t
        'fallback_to_single_machine fb-mach?
        'monolithic_single_chip_optimal mono-opt?
        'qpu_files '("qpu_0.qasm")
        'qpu_wire_slices (list (range (max 1 total-phys-q)))
        'qpu_qubit_counts (list (max 1 total-phys-q))
        'ebit_schedule_file "ebit_schedule.json"
        'solver_decision opt-res))
     (call-with-output-file (build-path out-dir "cluster_manifest.json")
       (lambda (out) (write-json manifest-js out) (newline out))
       #:exists 'replace)
     manifest-js]
    [else
     (emit-partitioned-cluster-qasm3! out-dir
                                      (lfq-circuit-decl-name decl)
                                      target-sym
                                      eff-spec
                                      opt-res
                                      isa-ops
                                      total-phys-q
                                      explicit-slices)]))

(module+ test
  (require rackunit)

  (define scratch-root
    (let ([host-p "/home/antigravity/toolchains/tmp"])
      (if (directory-exists? host-p)
          (build-path host-p "raco_test_cluster_qasm3_codegen")
          (build-path (current-directory) ".lakefillq_tmp" "raco_test_cluster_qasm3_codegen"))))
  (make-directory* scratch-root)

  ;; 1. Override & bundle spec rewriting:
  (define base-spec
    (par-cluster-opt-spec #:workload 'Mini-Shor
                          #:paradigm 'algebraic-limb
                          #:max-machines 64
                          #:q-cap-per-machine 400
                          #:raw-bell-rate-hz 100000.0
                          #:q-single 18
                          #:q-data-dist 12
                          #:q-local-fixed 2
                          #:q-peer-sync 1
                          #:window-bits 2
                          #:num-windows 2
                          #:local-toffolis 6400000
                          #:carry-scheme 'qrns-zero-carry
                          #:lookup-scheme 'law-u4-ghz-mx
                          #:interconnect-topology 'all-to-all-peers))
  (define overridden
    (override-par-cluster-spec base-spec
                               #:q-cap 8
                               #:r-bell 50000.0
                               #:topology 'switched-optical-tree
                               #:max-machines 256))
  (define ov-res (compile-parallel-with-fallback overridden))
  (check-true (lfq-typecheck-result-well-typed? ov-res))
  (check-equal? (hash-ref (lfq-typecheck-result-metrics ov-res) 'optimal_machines) 4)
  (check-equal? (hash-ref (lfq-typecheck-result-metrics ov-res) 'interconnect_topology)
                "switched-optical-tree")

  ;; 2. M* = 1 fallback emission (Grover / sequential dependency chain):
  (define seq-decl
    (lfq-circuit-decl 'seq-oracle 'defqfree '() '() '(0 1 2) '(3) 'all '(ccx 0 1 3)))
  (define seq-prog
    (register-program-cluster-profiles!
     (lfq-program "test-seq" 'ideal (list seq-decl))
     (list (lfq-cluster-profile-entry
            'seq-prof
            (par-cluster-opt-spec #:workload 'Seq-Oracle
                                  #:paradigm 'grover-amplify
                                  #:max-machines 256
                                  #:q-cap-per-machine 400
                                  #:raw-bell-rate-hz 100000.0
                                  #:q-single 4
                                  #:local-toffolis 8)
            #f))))
  (define m1-dir (build-path scratch-root "m1_fallback"))
  (define m1-manifest
    (emit-cluster-openqasm3-bundle!
     m1-dir seq-prog seq-decl 'ideal
     '((isa-ccx 0 1 3)) 4
     "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[4] q;\nccx q[0], q[1], q[3];\n"))
  (check-equal? (hash-ref m1-manifest 'm_star) 1)
  (check-equal? (hash-ref m1-manifest 'forward_ebits) 0)
  (check-equal? (hash-ref m1-manifest 'reverse_ebits) 0)
  (check-true (hash-ref m1-manifest 'fallback_to_single_qpu))
  (check-true (file-exists? (build-path m1-dir "qpu_0.qasm")))
  (check-true (file-exists? (build-path m1-dir "ebit_schedule.json")))

  ;; 3. M* = 2 Law U4 + zero-carry QRNS emission:
  (define u4-decl
    (lfq-circuit-decl 'mini-u4 'defq '() '() '(0 1 2 3) '(4) 'all '(seq (h 0) (cx 0 4))))
  (define u4-prog
    (register-program-cluster-profiles!
     (lfq-program "test-u4" 'ideal (list u4-decl))
     (list (lfq-cluster-profile-entry
            'u4-prof
            (par-cluster-opt-spec #:workload 'Mini-U4
                                  #:paradigm 'algebraic-limb
                                  #:max-machines 256
                                  #:q-cap-per-machine 4
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
  (define m2-dir (build-path scratch-root "m2_u4"))
  (define m2-manifest
    (emit-cluster-openqasm3-bundle!
     m2-dir u4-prog u4-decl 'ideal
     '((isa-h 0)
       (isa-cx 0 4)
       (isa-ccx 4 2 3)
       (isa-meas-x-cond-z-reset 4 m0 0))
     5
     "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[5] q;\n"))
  (check-equal? (hash-ref m2-manifest 'm_star) 2)
  (check-equal? (hash-ref m2-manifest 'forward_ebits) 1)
  (check-equal? (hash-ref m2-manifest 'reverse_ebits) 0)
  (check-equal? (hash-ref m2-manifest 'carry_ebits) 0)
  (check-false (hash-ref m2-manifest 'fallback_to_single_qpu))
  (check-true (file-exists? (build-path m2-dir "qpu_0.qasm")))
  (check-true (file-exists? (build-path m2-dir "qpu_1.qasm")))
  (check-true (file-exists? (build-path m2-dir "ebit_schedule.json")))
  (close-bug-prevention-z3!))
