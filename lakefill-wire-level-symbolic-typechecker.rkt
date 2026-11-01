#lang racket

;; =============================================================================
;; `lakefill-wire-level-symbolic-typechecker.rkt`
;;
;; Unifying Unannotated Wire-Level Circuits with Static Type & Grade Synthesis:
;; Annotation-Free Wire-Level Symbolic ANF Type, Taint, `QuRA` Peak-Width, and
;; `QPhysGrade (Φ1–Φ3)` Inference Engine Operating Directly on Raw Wire-Level
;; Lakefill ASTs with ZERO Manual Boolean Witness Flags!
;;
;; Core Capabilities:
;;   1. Canonical Symbolic ANF over F_2[x_0, ..., x_{n-1}] / I(S):
;;      - Exact multilinear polynomial ring (`anf-zero`, `anf-one`, `anf-var`,
;;        `anf-xor`, `anf-not`, `anf-and`, `anf-deriv`) with exact Boolean
;;        monomial-ideal quotienting for Hamming-ball subspaces `wt(e) <= t`.
;;   2. Automatic `Law U1` (`erase-by-raw`, `within-apply-raw`):
;;      - Symbolically proves every erased/scratch wire reduces to `0` on domain
;;        `S` (accepting Boyar-Peralta `34-AND` S-box, Daemen `15`-wire `Keccak`
;;        `chi_5`, and `BCH(15,7,5)` `wt <= 2` Peterson-Berlekamp uncomputation,
;;        and rejecting `BCH(15,7,5)` + Hamming `wt <= 1` stub with concrete
;;        minimal weight-2 counterexample `e`!).
;;   3. Automatic `Law U2` (`canon-quotient-raw` before `h` / `qft`):
;;      - Symbolically checks residual ANF dependence on non-canonical quotient
;;        wires `q_CRT` and history/insertion-order bits `(x, q_1) ~ (x, q_2)`
;;        before Hadamard / QFT interference!
;;   4. Automatic `Law U3` (`match-wires-raw` orthogonal partition):
;;      - Symbolically checks `sum_i P_i(x) == 1 (mod 2)` and `P_i(x)*P_j(x) == 0`
;;        over `S` (catching incomplete chord-only ECC branching when `P == Q`!).
;;   5. Automatic `Law U4` (wire-level `QTainted` bilinear phase polynomial):
;;      - `(temp-and c1 c2 anc)` sets `anc = c1 * c2`; `(mid-meas-x anc -> m)`
;;        frees `anc` (`0` live width!) and adds symbolic phase taint `m * P_anc`;
;;        statically rejects `h`/`qft`/scope-exit unless subsequent `cond-cz` or
;;        algebraically equivalent `cond-z` + `cond-cz` sequence cancels `T[m] == 0`!
;;   6. Automatic `QuRA` Affine Peak-Width + `QPhysGrade (Φ1–Φ3)` Inference:
;;      - Tracks live vs. freed (`mid-meas-x` / `erase-by-raw` / `within-apply-raw`)
;;        wire sets to infer exact recycled peak logical qubit width alongside
;;        `Φ1` Lindblad action, `Φ2` coupler/Rydberg `par-wires` collisions, and
;;        `Φ3` monotone fault/dyadic exponent!
;; =============================================================================

(require racket/match
         racket/list
         racket/set
         racket/math
         racket/format
         json)

(provide (struct-out hw-spec)
         (struct-out qphys-grade)
         (struct-out qura-width-summary)
         (struct-out wire-inference-result)
         default-wire-aod-ryst-hw-spec
         planar-superconducting-ryst-hw-spec
         anf-zero
         anf-one
         anf-var
         anf-zero?
         anf-xor
         anf-not
         anf-and
         anf-deriv
         anf-eval
         infer-wire-circuit
         sexpr->json-ast
         build-wire-level-16-benchmark-circuits
         run-wire-level-symbolic-typechecker-suite)

;; =============================================================================
;; SECTION 1: Hardware Calibration & `QPhysGrade (Φ1–Φ3)` Resource Semiring
;; =============================================================================

(struct hw-spec
  (name
   t2-ns
   1q-ns
   2q-ns
   p2q-permil
   t-meas-reset-ns
   unitary-budget-ns
   blockade-radius-um
   target-code-dist
   xy4-dd-enabled?
   wire-coords
   coupling-dist-fn
   par-coupler-dist-fn)
  #:transparent)

;; Calibrated neutral-atom / zoned-AOD + planar coupler lattice (`hw-spec`):
;; - Sequential 2Q gates use zoned AOD shuttling (`coupling-dist = 1` for `u != v`)
;; - Parallel simultaneous gates `(par-wires e1 e2)` check BOTH physical 1D/2D trap
;;   pitch (`5 um` per wire index vs `blockade-radius-um = 8 um`) AND coupler graph
;;   distance `|u - v| >= 2`!
(define (default-wire-aod-ryst-hw-spec)
  (define coords
    (for/hash ([q (in-range 64)])
      (values q (list (* 5 q) 0))))
  (define (seq-dist u v)
    (if (= u v) 0 1))
  (define (par-dist u v)
    (if (= u v) 0 (abs (- u v))))
  (hw-spec 'calibrated-zoned-aod-ryst-64q
           500000  ;; T2 = 500,000 ns (calibrated logical/hyperfine coherence window)
           24      ;; 1Q gate = 24 ns
           68      ;; 2Q gate = 68 ns
           1       ;; logical/mitigated p_2Q = 1 permil
           650     ;; mid-circuit MBU meas+reset = 650 ns
           1500    ;; unshielded unitary budget = 1500 ns
           8       ;; Rydberg blockade radius r_b = 8 um (pitch = 5 um -> |u-v|=1 collides!)
           5       ;; target fault distance d_target = 5
           #t      ;; XY4 dynamical decoupling active on spectators during mid-meas-x
           coords
           seq-dist
           par-dist))

(define (planar-superconducting-ryst-hw-spec)
  (define base (default-wire-aod-ryst-hw-spec))
  (define (grid-dist u v) (if (= u v) 0 (abs (- u v))))
  (struct-copy hw-spec base
               [name 'calibrated-planar-coupler-64q]
               [t2-ns 80000]
               [p2q-permil 3]
               [coupling-dist-fn grid-dist]))

(struct qphys-grade
  (idle-milli
   gate-milli
   mbu-excess-ns
   routing-excess-cx
   exclusion-collisions
   eff-fault-dist
   req-target-dist
   support-wires
   duration-ns)
  #:transparent)

(struct qura-width-summary
  (initial-width
   final-live-width
   peak-live-width
   unrecycled-ssa-width
   recycled-wire-reuses
   width-saved)
  #:transparent)

(struct wire-inference-result
  (well-typed?
   logical-well-typed?
   u1-ok?
   u2-ok?
   u3-ok?
   u4-ok?
   phi1-ok?
   phi2-ok?
   phi3-ok?
   u1-violations
   u2-violations
   u3-violations
   u4-violations
   phi2-collision-pairs
   qura-width
   phys-grade
   effective-lindblad-milli
   wire-anf-stats
   final-wire-anf)
  #:transparent)

(define (nat-sub a b)
  (max 0 (- a b)))

(define (min-fault-dist a b)
  (cond
    [(not a) b]
    [(not b) a]
    [else (min a b)]))

(define qphys-zero
  (qphys-grade 0 0 0 0 0 #f 0 (set) 0))

(define (idle-milli-for hw n-wires dur-ns)
  (define t2 (hw-spec-t2-ns hw))
  (if (= t2 0) 999999 (quotient (* n-wires dur-ns 1000) t2)))

(define (euclidean-dist-um hw u v)
  (define cu (hash-ref (hw-spec-wire-coords hw) u (list (* 5 u) 0)))
  (define cv (hash-ref (hw-spec-wire-coords hw) v (list (* 5 v) 0)))
  (define dx (- (first cu) (first cv)))
  (define dy (- (second cu) (second cv)))
  (exact-floor (sqrt (+ (* dx dx) (* dy dy)))))

(define (exclusion-collision-pairs hw s1 s2)
  (define dist-fn (hw-spec-par-coupler-dist-fn hw))
  (define rb (hw-spec-blockade-radius-um hw))
  (for*/list ([u (in-list (sort (set->list s1) <))]
              [v (in-list (sort (set->list s2) <))]
              #:when (or (= u v)
                         (< (dist-fn u v) 2)
                         (< (euclidean-dist-um hw u v) rb)))
    (list u v)))

(define (qphys-seq g1 g2)
  (qphys-grade (+ (qphys-grade-idle-milli g1) (qphys-grade-idle-milli g2))
               (+ (qphys-grade-gate-milli g1) (qphys-grade-gate-milli g2))
               (+ (qphys-grade-mbu-excess-ns g1) (qphys-grade-mbu-excess-ns g2))
               (+ (qphys-grade-routing-excess-cx g1) (qphys-grade-routing-excess-cx g2))
               (+ (qphys-grade-exclusion-collisions g1) (qphys-grade-exclusion-collisions g2))
               (min-fault-dist (qphys-grade-eff-fault-dist g1) (qphys-grade-eff-fault-dist g2))
               (max (qphys-grade-req-target-dist g1) (qphys-grade-req-target-dist g2))
               (set-union (qphys-grade-support-wires g1) (qphys-grade-support-wires g2))
               (+ (qphys-grade-duration-ns g1) (qphys-grade-duration-ns g2))))

(define (qphys-join g1 g2)
  (qphys-grade (max (qphys-grade-idle-milli g1) (qphys-grade-idle-milli g2))
               (max (qphys-grade-gate-milli g1) (qphys-grade-gate-milli g2))
               (max (qphys-grade-mbu-excess-ns g1) (qphys-grade-mbu-excess-ns g2))
               (max (qphys-grade-routing-excess-cx g1) (qphys-grade-routing-excess-cx g2))
               (max (qphys-grade-exclusion-collisions g1) (qphys-grade-exclusion-collisions g2))
               (min-fault-dist (qphys-grade-eff-fault-dist g1) (qphys-grade-eff-fault-dist g2))
               (max (qphys-grade-req-target-dist g1) (qphys-grade-req-target-dist g2))
               (set-union (qphys-grade-support-wires g1) (qphys-grade-support-wires g2))
               (max (qphys-grade-duration-ns g1) (qphys-grade-duration-ns g2))))

(define (qphys-par hw g1 g2)
  (define s1 (qphys-grade-support-wires g1))
  (define s2 (qphys-grade-support-wires g2))
  (define s-union (set-union s1 s2))
  (define pairs (exclusion-collision-pairs hw s1 s2))
  (define cross-hits (length pairs))
  (define par-dur (max (qphys-grade-duration-ns g1) (qphys-grade-duration-ns g2)))
  (define computed-idle
    (if (and (> par-dur 0) (> (set-count s-union) 0))
        (idle-milli-for hw (set-count s-union) par-dur)
        (max (qphys-grade-idle-milli g1) (qphys-grade-idle-milli g2))))
  (values
   (qphys-grade computed-idle
                (+ (qphys-grade-gate-milli g1) (qphys-grade-gate-milli g2))
                (max (qphys-grade-mbu-excess-ns g1) (qphys-grade-mbu-excess-ns g2))
                (+ (qphys-grade-routing-excess-cx g1) (qphys-grade-routing-excess-cx g2))
                (+ (qphys-grade-exclusion-collisions g1)
                   (qphys-grade-exclusion-collisions g2)
                   cross-hits)
                (min-fault-dist (qphys-grade-eff-fault-dist g1) (qphys-grade-eff-fault-dist g2))
                (max (qphys-grade-req-target-dist g1) (qphys-grade-req-target-dist g2))
                s-union
                par-dur)
   pairs))

(define (qphys-multishot shots-k g)
  (if (<= shots-k 1)
      g
      (struct-copy qphys-grade g
                   [idle-milli (quotient (qphys-grade-idle-milli g) shots-k)]
                   [gate-milli (quotient (qphys-grade-gate-milli g) shots-k)]
                   [duration-ns (quotient (qphys-grade-duration-ns g) shots-k)])))

(define (effective-lindblad-action-milli g)
  (+ (qphys-grade-idle-milli g)
     (qphys-grade-gate-milli g)
     (* 700 (+ (qphys-grade-mbu-excess-ns g)
               (qphys-grade-routing-excess-cx g)))))

(define (check-phi1? g)
  (<= (effective-lindblad-action-milli g) 693))

(define (check-phi2? g)
  (= (qphys-grade-exclusion-collisions g) 0))

(define (check-phi3? g)
  (define d-eff (qphys-grade-eff-fault-dist g))
  (define d-req (qphys-grade-req-target-dist g))
  (if (not d-eff)
      (= d-req 0)
      (and (>= d-eff 3) (>= d-eff d-req))))

;; =============================================================================
;; SECTION 2: Canonical Symbolic ANF Engine over F_2[x_0, ..., x_{n-1}] / I(S)
;; =============================================================================

;; Each canonical ANF polynomial is a strictly increasing list of non-negative
;; integer monomial bitmasks `m` (`0` = constant `1`, `2^i` = variable `x_i`).
(define anf-zero '())
(define anf-one  '(0))

(define (anf-var i)
  (list (arithmetic-shift 1 i)))

(define (anf-zero? p)
  (null? p))

(define (popcount n)
  (let loop ([x n] [acc 0])
    (if (= x 0)
        acc
        (loop (bitwise-and x (sub1 x)) (add1 acc)))))

(define (anf-degree p)
  (if (null? p)
      0
      (for/fold ([mx 0]) ([m (in-list p)])
        (max mx (popcount m)))))

;; Symmetric difference of strictly sorted integer lists in O(|p| + |q|).
(define (anf-xor p q)
  (let loop ([a p] [b q] [acc '()])
    (cond
      [(null? a) (append (reverse acc) b)]
      [(null? b) (append (reverse acc) a)]
      [else
       (define ma (car a))
       (define mb (car b))
       (cond
         [(< ma mb) (loop (cdr a) b (cons ma acc))]
         [(> ma mb) (loop a (cdr b) (cons mb acc))]
         [else      (loop (cdr a) (cdr b) acc)])])))

(define (anf-not p)
  (anf-xor anf-one p))

;; Multilinear product in F_2[x_0, ..., x_{n-1}] / <x_i^2 - x_i, wt(x_in) > max-wt>.
;; `input-mask` masks the input variables subject to Hamming-ball constraint `max-wt`
;; (or `#f` when unconstrained).
(define (anf-and p q [max-wt #f] [input-mask -1])
  (cond
    [(or (null? p) (null? q)) anf-zero]
    [(equal? p anf-one) q]
    [(equal? q anf-one) p]
    [else
     (define table (make-hasheqv))
     (for* ([m1 (in-list p)]
            [m2 (in-list q)])
       (define prod (bitwise-ior m1 m2))
       (when (or (not max-wt)
                 (<= (popcount (bitwise-and prod input-mask)) max-wt))
         (define cur (hash-ref table prod 0))
         (hash-set! table prod (bitwise-xor cur 1))))
     (sort (for/list ([(m bit) (in-hash table)] #:when (= bit 1)) m) <)]))

;; Symbolic Boolean partial derivative dP / dx_v = P|_{x_v=0} ^ P|_{x_v=1}.
;; In canonical ANF, this is obtained by selecting monomials containing bit `v`
;; and clearing bit `v`!
(define (anf-deriv p var-idx)
  (define bit (arithmetic-shift 1 var-idx))
  (define mask-clear (bitwise-not bit))
  (sort (for/list ([m (in-list p)]
                   #:when (not (= (bitwise-and m bit) 0)))
          (bitwise-and m mask-clear))
        <))

;; Evaluate ANF polynomial `p` on integer assignment bitmask `assign-mask`.
(define (anf-eval p assign-mask)
  (for/fold ([acc 0]) ([m (in-list p)])
    (if (= (bitwise-and m assign-mask) m)
        (bitwise-xor acc 1)
        acc)))

;; Parse domain specification:
;;   'all
;;   `(wt-le ,t)
;;   `(quotient-vars ,q-wires)
(define (parse-domain-spec domain-pred num-inputs)
  (define input-mask (sub1 (arithmetic-shift 1 num-inputs)))
  (match domain-pred
    ['all (values #f input-mask '())]
    [`(wt-le ,t) (values t input-mask '())]
    [`(quotient-vars ,qws) (values #f input-mask qws)]
    [_ (error 'parse-domain-spec "Unsupported domain-pred: ~a" domain-pred)]))

;; Find minimal-Hamming-weight counterexample `x* in S` where `P(x*) == 1`,
;; returning `#f` iff `P` is identically `0` across all `x in S`.
;; Because `p` is already reduced modulo `I(S)` (`x_i^2 = x_i` and `wt <= t`),
;; `p == '()` iff `P|_S == 0`, and the minimum-popcount monomial mask `m*` in `p`
;; satisfies `wt(m*) <= t` and `P(m*) = 1` with minimal Hamming weight!
(define (anf-domain-counterexample p input-wires max-wt input-mask)
  (define reduced
    (if max-wt
        (for/list ([m (in-list p)]
                   #:when (<= (popcount (bitwise-and m input-mask)) max-wt))
          m)
        p))
  (if (null? reduced)
      #f
      (let ()
        (define best-m
          (argmin (lambda (m) (+ (* 100000 (popcount m)) m)) reduced))
        (unless (= (anf-eval reduced best-m) 1)
          (error 'anf-domain-counterexample "Internal ANF minimality invariant failed"))
        (define active-in-wires
          (for/list ([w (in-list input-wires)]
                     [idx (in-naturals)]
                     #:when (bitwise-bit-set? best-m idx))
            w))
        (hasheq 'assign_mask best-m
                'active_input_wires active-in-wires
                'hamming_weight (length active-in-wires)))))

;; =============================================================================
;; SECTION 3: Syntactic Inversion of Unitary Raw Wire ASTs (for `within-apply-raw`)
;; =============================================================================

(define (invert-raw-expr expr)
  (match expr
    ['skip 'skip]
    [`(x ,w) `(x ,w)]
    [`(cx ,c ,t) `(cx ,c ,t)]
    [`(cx ,c ,t ,s) `(cx ,c ,t ,s)]
    [`(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t)]
    [`(ccx ,c1 ,c2 ,t ,s) `(ccx ,c1 ,c2 ,t ,s)]
    [`(swap ,a ,b) `(swap ,a ,b)]
    [`(h ,w) `(h ,w)]
    [`(z ,w) `(z ,w)]
    [`(cz ,a ,b) `(cz ,a ,b)]
    [`(seq ,es ...) `(seq ,@(map invert-raw-expr (reverse es)))]
    [`(par-wires ,e1 ,e2) `(par-wires ,(invert-raw-expr e1) ,(invert-raw-expr e2))]
    [`(within-apply-raw ,u ,b ,erased)
     `(within-apply-raw ,u ,(invert-raw-expr b) ,erased)]
    [`(within-apply-raw ,u ,b)
     `(within-apply-raw ,u ,(invert-raw-expr b))]
    [`(mcx-raw ,ctrls ,target ,scratch)
     `(mcx-raw ,ctrls ,target ,scratch)]
    [(or `(temp-and . ,_) `(mid-meas-x . ,_) `(cond-z . ,_) `(cond-cz . ,_))
     (error 'invert-raw-expr
            "Cannot syntactically invert non-unitary session/MBU form: ~a" expr)]
    [_ (error 'invert-raw-expr "Unsupported form in invert-raw-expr: ~a" expr)]))

;; Lower `(mcx-raw ctrls target scratch)` into pure wire-level `within-apply-raw` + `ccx`!
(define (expand-mcx-raw ctrls target scratch)
  (define k (length ctrls))
  (cond
    [(= k 0) `(x ,target)]
    [(= k 1) `(cx ,(first ctrls) ,target)]
    [(= k 2) `(ccx ,(first ctrls) ,(second ctrls) ,target)]
    [else
     (when (< (length scratch) (- k 2))
       (error 'expand-mcx-raw "mcx-raw needs ~a scratch wires, got ~a" (- k 2) (length scratch)))
     (define used (take scratch (- k 2)))
     (define steps
       (cons `(ccx ,(first ctrls) ,(second ctrls) ,(first used))
             (for/list ([idx (in-range 2 (- k 1))])
               `(ccx ,(list-ref ctrls idx)
                     ,(list-ref used (- idx 2))
                     ,(list-ref used (- idx 1))))))
     `(within-apply-raw (seq ,@steps)
                        (ccx ,(last ctrls) ,(last used) ,target)
                        ,used)]))

;; =============================================================================
;; SECTION 4: Annotation-Free Wire-Level Symbolic Type & `QPhysGrade` Inference
;; =============================================================================

;; Evaluate a raw wire-level Boolean guard formula into its symbolic ANF polynomial!
(define (eval-wire-guard guard-sexpr wire-anf max-wt input-mask)
  (define (get-w w) (hash-ref wire-anf w anf-zero))
  (let eval-g ([g guard-sexpr])
    (match g
      ['true anf-one]
      ['false anf-zero]
      [`(wire ,w) (get-w w)]
      [`(zero ,w) (anf-not (get-w w))]
      [`(not ,sub) (anf-not (eval-g sub))]
      [`(xor ,subs ...)
       (foldl (lambda (s acc) (anf-xor acc (eval-g s))) anf-zero subs)]
      [`(and ,subs ...)
       (foldl (lambda (s acc) (anf-and acc (eval-g s) max-wt input-mask)) anf-one subs)]
      [`(or ,subs ...)
       (anf-not
        (foldl (lambda (s acc)
                 (anf-and acc (anf-not (eval-g s)) max-wt input-mask))
               anf-one
               subs))]
      [`(all-zero ,ws)
       (foldl (lambda (w acc) (anf-and acc (anf-not (get-w w)) max-wt input-mask))
              anf-one
              ws)]
      [`(non-zero ,ws)
       (anf-not (eval-g `(all-zero ,ws)))]
      [`(eq-wires ,ws1 ,ws2)
       (foldl (lambda (w1 w2 acc)
                (define eq-bit (anf-not (anf-xor (get-w w1) (get-w w2))))
                (anf-and acc eq-bit max-wt input-mask))
              anf-one
              ws1
              ws2)]
      [_ (error 'eval-wire-guard "Unrecognized wire guard formula: ~a" g)])))

;; Core engine: `(infer-wire-circuit hw input-wires scratch-wires domain-pred raw-sexpr)`
(define (infer-wire-circuit hw input-wires scratch-wires domain-pred raw-sexpr)
  (define num-inputs (length input-wires))
  (define-values (max-wt input-mask domain-quot-wires)
    (parse-domain-spec domain-pred num-inputs))

  (define input-var-map
    (for/hasheqv ([w (in-list input-wires)] [idx (in-naturals)])
      (values w idx)))

  ;; Mutable symbolic state threaded sequentially (cloned on `match-wires-raw` arms)
  (define wire-anf (make-hasheqv))
  (for ([w (in-list input-wires)] [idx (in-naturals)])
    (hash-set! wire-anf w (anf-var idx)))
  (for ([w (in-list scratch-wires)])
    (unless (hash-has-key? wire-anf w)
      (hash-set! wire-anf w anf-zero)))

  (define next-fresh-var num-inputs)
  (define live-wires (list->set input-wires))
  (define freed-ever (set))
  (define peak-live (set-count live-wires))
  (define unrecycled-allocs 0)
  (define recycled-reuses 0)

  ;; Tracked quotient wires (`canon-quotient-raw`) & history input variables (`quotient-vars`) for Law U2
  (define tracked-quotient-wires (set))
  (define tracked-history-vars
    (for/set ([qw (in-list domain-quot-wires)]
              #:when (hash-has-key? input-var-map qw))
      (hash-ref input-var-map qw)))

  ;; Symbolic phase-taint table: meas-symbol -> ANF polynomial `T_m(x)` over F_2
  (define phase-taints (make-hasheq))

  ;; Accumulated violations
  (define u1-viols '())
  (define u2-viols '())
  (define u3-viols '())
  (define u4-viols '())
  (define phi2-pairs '())

  (define (touch-wire! w [count-ssa-alloc? #f])
    (when (not (set-member? live-wires w))
      (when (set-member? freed-ever w)
        (set! recycled-reuses (add1 recycled-reuses)))
      (when count-ssa-alloc?
        (set! unrecycled-allocs (add1 unrecycled-allocs)))
      (set! live-wires (set-add live-wires w))
      (when (> (set-count live-wires) peak-live)
        (set! peak-live (set-count live-wires)))))

  (define (free-wire! w)
    (when (set-member? live-wires w)
      (set! live-wires (set-remove live-wires w))
      (set! freed-ever (set-add freed-ever w)))
    (hash-set! wire-anf w anf-zero))

  (define (get-anf w)
    (hash-ref wire-anf w anf-zero))

  ;; Check Law U2 & Law U4 before Hadamard / QFT interference on wire(s) `ws`
  (define (check-interference-barriers! gate-tag ws)
    ;; 1. Law U2: check all tracked quotient wires reduce to `0` on `S`
    (for ([qw (in-list (sort (set->list tracked-quotient-wires) <))])
      (define qp (get-anf qw))
      (define cex (anf-domain-counterexample qp input-wires max-wt input-mask))
      (when cex
        (set! u2-viols
              (cons (hasheq 'kind "residual_quotient_wire_before_interference"
                            'gate (format "~a" gate-tag)
                            'quotient_wire qw
                            'residual_monomials (length qp)
                            'residual_degree (anf-degree qp)
                            'counterexample cex)
                    u2-viols))))
    ;; 2. Law U2: check history-variable independence `dP_w / dq_hist == 0` on interfered wires `ws`
    (for* ([hv (in-list (sort (set->list tracked-history-vars) <))]
           [lw (in-list ws)])
      (define dp (anf-deriv (get-anf lw) hv))
      (define cex (anf-domain-counterexample dp input-wires max-wt input-mask))
      (when cex
        (set! u2-viols
              (cons (hasheq 'kind "history_variable_dependence_before_interference"
                            'gate (format "~a" gate-tag)
                            'live_wire lw
                            'history_var_idx hv
                            'residual_monomials (length dp)
                            'counterexample cex)
                    u2-viols))))
    ;; 3. Law U4: check all active measurement phase-taint polynomials vanish on `S`
    (for ([(m-sym tpoly) (in-hash phase-taints)])
      (define cex (anf-domain-counterexample tpoly input-wires max-wt input-mask))
      (when cex
        (set! u4-viols
              (cons (hasheq 'trigger (format "interference_~a" gate-tag)
                            'meas_var (symbol->string m-sym)
                            'residual_monomials (length tpoly)
                            'residual_degree (anf-degree tpoly)
                            'counterexample cex)
                    u4-viols))
        ;; Clear reported taint so we don't duplicate the exact same m-sym at exit
        (hash-set! phase-taints m-sym anf-zero))))

  ;; Check Law U1 on `erased-wires` after `erase-by-raw` or `within-apply-raw`
  (define (verify-and-free-erased-wires! construct-tag erased-wires)
    (for ([ew (in-list erased-wires)])
      (define ep (get-anf ew))
      (define cex (anf-domain-counterexample ep input-wires max-wt input-mask))
      (cond
        [cex
         (set! u1-viols
               (cons (hasheq 'construct (symbol->string construct-tag)
                             'wire ew
                             'residual_monomials (length ep)
                             'residual_degree (anf-degree ep)
                             'counterexample cex)
                     u1-viols))]
        [else
         (free-wire! ew)])))

  ;; Recursive symbolic abstract interpreter returning `qphys-grade`
  (define (step-expr! expr)
    (match expr
      ['skip qphys-zero]

      [`(x ,w)
       (touch-wire! w #t)
       (hash-set! wire-anf w (anf-not (get-anf w)))
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli-for hw 1 dur) 0 0 0 0 #f 0 (set w) dur)]

      [(or `(z ,w) `(s ,w))
       (touch-wire! w #f)
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli-for hw 1 dur) 0 0 0 0 #f 0 (set w) dur)]

      [`(h ,w)
       (touch-wire! w #f)
       (check-interference-barriers! `(h ,w) (list w))
       (define fresh-idx next-fresh-var)
       (set! next-fresh-var (add1 next-fresh-var))
       (hash-set! wire-anf w (anf-var fresh-idx))
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli-for hw 1 dur) 0 0 0 0 #f 0 (set w) dur)]

      [`(qft ,ws)
       (for ([w (in-list ws)]) (touch-wire! w #f))
       (check-interference-barriers! `(qft ,ws) ws)
       (for ([w (in-list ws)])
         (define fresh-idx next-fresh-var)
         (set! next-fresh-var (add1 next-fresh-var))
         (hash-set! wire-anf w (anf-var fresh-idx)))
       (define n-q (max 1 (length ws)))
       (define n-2q (quotient (* n-q (sub1 n-q)) 2))
       (define dur (+ (* n-q (hw-spec-1q-ns hw)) (* n-2q (hw-spec-2q-ns hw))))
       (qphys-grade (idle-milli-for hw n-q dur)
                    (* n-2q (hw-spec-p2q-permil hw))
                    0 0 0 #f 0 (list->set ws) dur)]

      [`(swap ,a ,b)
       (cond
         [(= a b) qphys-zero]
         [else
          (touch-wire! a #f)
          (touch-wire! b #f)
          (define pa (get-anf a))
          (define pb (get-anf b))
          (hash-set! wire-anf a pb)
          (hash-set! wire-anf b pa)
          (define dur (* 3 (hw-spec-2q-ns hw)))
          (qphys-grade (idle-milli-for hw 2 dur)
                       (* 3 (hw-spec-p2q-permil hw))
                       0 0 0 #f 0 (set a b) dur)])]

      [(or `(cx ,c ,t) `(cx ,c ,t ,_))
       (when (= c t)
         (error 'infer-wire-circuit "cx control and target must be distinct: ~a" expr))
       (define saved (match expr [`(cx ,_ ,_ ,s) s] [_ 0]))
       (touch-wire! c #f)
       (touch-wire! t #t)
       (hash-set! wire-anf t (anf-xor (get-anf t) (get-anf c)))
       (define d-edge ((hw-spec-coupling-dist-fn hw) c t))
       (define swap-cx (if (<= d-edge 1) 0 (* 3 (- d-edge 1))))
       (define rt-exc (+ (if (= d-edge 0) 1 0) (nat-sub swap-cx saved)))
       (define total-2q (+ 1 swap-cx))
       (define dur (* total-2q (hw-spec-2q-ns hw)))
       (qphys-grade (idle-milli-for hw 2 dur)
                    (* total-2q (hw-spec-p2q-permil hw))
                    0 rt-exc 0 #f 0 (set c t) dur)]

      [`(cz ,a ,b)
       (when (= a b)
         (error 'infer-wire-circuit "cz wires must be distinct: ~a" expr))
       (touch-wire! a #f)
       (touch-wire! b #f)
       (define d-edge ((hw-spec-coupling-dist-fn hw) a b))
       (define swap-cx (if (<= d-edge 1) 0 (* 3 (- d-edge 1))))
       (define total-2q (+ 1 swap-cx))
       (define dur (* total-2q (hw-spec-2q-ns hw)))
       (qphys-grade (idle-milli-for hw 2 dur)
                    (* total-2q (hw-spec-p2q-permil hw))
                    0 swap-cx 0 #f 0 (set a b) dur)]

      [(or `(ccx ,c1 ,c2 ,t) `(ccx ,c1 ,c2 ,t ,_))
       (when (or (= c1 c2) (= c1 t) (= c2 t))
         (error 'infer-wire-circuit "ccx wires must be pairwise distinct: ~a" expr))
       (define saved (match expr [`(ccx ,_ ,_ ,_ ,s) s] [_ 0]))
       (touch-wire! c1 #f)
       (touch-wire! c2 #f)
       (touch-wire! t #t)
       (define prod (anf-and (get-anf c1) (get-anf c2) max-wt input-mask))
       (hash-set! wire-anf t (anf-xor (get-anf t) prod))
       (define d12 ((hw-spec-coupling-dist-fn hw) c1 c2))
       (define d2t ((hw-spec-coupling-dist-fn hw) c2 t))
       (define max-d (max d12 d2t))
       (define swap-cx (if (<= max-d 1) 0 (* 3 (- max-d 1))))
       (define rt-exc (nat-sub swap-cx saved))
       (define total-2q (+ 6 swap-cx))
       (define dur (* total-2q (hw-spec-2q-ns hw)))
       (qphys-grade (idle-milli-for hw 3 dur)
                    (* total-2q (hw-spec-p2q-permil hw))
                    0 rt-exc 0 #f 0 (set c1 c2 t) dur)]

      ;; Gidney temporary-AND `(temp-and c1 c2 anc)`:
      ;; Requires `anc` to be clean (`0` on `S`), allocates `anc` into `live-wires`,
      ;; and computes `anc = P[c1] * P[c2]` using 4 T-gates (2Q equiv = 4 CX).
      [`(temp-and ,c1 ,c2 ,anc)
       (when (or (= c1 c2) (= c1 anc) (= c2 anc))
         (error 'infer-wire-circuit "temp-and wires must be pairwise distinct: ~a" expr))
       (define pre-anc (get-anf anc))
       (define dirty-cex (anf-domain-counterexample pre-anc input-wires max-wt input-mask))
       (when dirty-cex
         (set! u1-viols
               (cons (hasheq 'construct "temp-and-preclean-check"
                             'wire anc
                             'residual_monomials (length pre-anc)
                             'residual_degree (anf-degree pre-anc)
                             'counterexample dirty-cex)
                     u1-viols)))
       (touch-wire! c1 #f)
       (touch-wire! c2 #f)
       (touch-wire! anc #t)
       (define prod (anf-and (get-anf c1) (get-anf c2) max-wt input-mask))
       (hash-set! wire-anf anc (anf-xor pre-anc prod))
       (define d12 ((hw-spec-coupling-dist-fn hw) c1 c2))
       (define d2a ((hw-spec-coupling-dist-fn hw) c2 anc))
       (define swap-cx (if (<= (max d12 d2a) 1) 0 (* 3 (- (max d12 d2a) 1))))
       (define total-2q (+ 4 swap-cx))
       (define dur (* total-2q (hw-spec-2q-ns hw)))
       (qphys-grade (idle-milli-for hw 3 dur)
                    (* total-2q (hw-spec-p2q-permil hw))
                    0 swap-cx 0 #f 0 (set c1 c2 anc) dur)]

      ;; Hadamard-dual X-basis measurement `(mid-meas-x anc -> m)`:
      ;; Frees `anc` (`0` live width -> recyclable immediately!) and records
      ;; bilinear phase-taint `T[m] ^= P[anc](x)`!
      [(or `(mid-meas-x ,anc -> ,m-sym)
           `(mid-meas-x ,anc ,m-sym))
       (define p-anc (get-anf anc))
       (define prev-taint (hash-ref phase-taints m-sym anf-zero))
       (hash-set! phase-taints m-sym (anf-xor prev-taint p-anc))
       (free-wire! anc)
       (define n-spec (max 0 (set-count live-wires)))
       (define t-meas (hw-spec-t-meas-reset-ns hw))
       (define u-bud (hw-spec-unitary-budget-ns hw))
       (define mbu-exc
         (if (hw-spec-xy4-dd-enabled? hw)
             0
             (nat-sub (* (+ 2 n-spec) t-meas) u-bud)))
       (qphys-grade (idle-milli-for hw (add1 n-spec) t-meas)
                    (hw-spec-p2q-permil hw)
                    mbu-exc 0 0 #f 0 (set anc) t-meas)]

      ;; Classical feed-forward Z fixup `(cond-z m t)`:
      ;; Adds `m * P[t](x)` (mod 2) to `T[m]`!
      [`(cond-z ,m-sym ,t)
       (touch-wire! t #f)
       (define pt (get-anf t))
       (hash-set! phase-taints m-sym
                  (anf-xor (hash-ref phase-taints m-sym anf-zero) pt))
       (define dur (hw-spec-1q-ns hw))
       (qphys-grade (idle-milli-for hw 1 dur) 0 0 0 0 #f 0 (set t) dur)]

      ;; Classical feed-forward CZ fixup `(cond-cz m c1 c2)`:
      ;; Adds `m * (P[c1](x) * P[c2](x))` (mod 2) to `T[m]`!
      [`(cond-cz ,m-sym ,c1 ,c2)
       (when (= c1 c2)
         (error 'infer-wire-circuit "cond-cz wires must be distinct: ~a" expr))
       (touch-wire! c1 #f)
       (touch-wire! c2 #f)
       (define prod (anf-and (get-anf c1) (get-anf c2) max-wt input-mask))
       (hash-set! phase-taints m-sym
                  (anf-xor (hash-ref phase-taints m-sym anf-zero) prod))
       (define dur (hw-spec-2q-ns hw))
       (qphys-grade (idle-milli-for hw 2 dur)
                    (hw-spec-p2q-permil hw)
                    0 0 0 #f 0 (set c1 c2) dur)]

      ;; Multi-controlled X lowered to pure wire-level `within-apply-raw` + `ccx`
      [`(mcx-raw ,ctrls ,target ,scratch)
       (step-expr! (expand-mcx-raw ctrls target scratch))]

      ;; Fault-distance / exact dyadic angle primitives (`Φ3`)
      [`(rz-dyadic ,q ,exp-k ,uses-float64? ,code-dist)
       (touch-wire! q #f)
       (define dur (hw-spec-1q-ns hw))
       (define exact-prec? (or (not uses-float64?) (< exp-k 53)))
       (define d-eff (if exact-prec? code-dist 0))
       (qphys-grade (idle-milli-for hw 1 dur)
                    0 0 0 0 d-eff (max 3 code-dist) (set q) dur)]

      [`(syndrome-plaquette ,ws ,code-dist ,hook-aligned?)
       (for ([w (in-list ws)]) (touch-wire! w #f))
       (define n-2q (max 1 (sub1 (length ws))))
       (define dur (* n-2q (hw-spec-2q-ns hw)))
       (define d-eff (if hook-aligned? (quotient (add1 code-dist) 2) code-dist))
       (qphys-grade (idle-milli-for hw (max 1 (length ws)) dur)
                    (* n-2q (hw-spec-p2q-permil hw))
                    0 0 0 d-eff (max 3 code-dist) (list->set ws) dur)]

      ;; Sequential composition
      [`(seq ,es ...)
       (for/fold ([g-acc qphys-zero]) ([e (in-list es)])
         (qphys-seq g-acc (step-expr! e)))]

      ;; Simultaneous parallel composition `(par-wires e1 e2)`:
      ;; Checks disjointness + hardware coupler/Rydberg exclusion neighborhood!
      [`(par-wires ,e1 ,e2)
       (define g1 (step-expr! e1))
       (define g2 (step-expr! e2))
       (define-values (g-par pairs) (qphys-par hw g1 g2))
       (when (not (null? pairs))
         (set! phi2-pairs (append phi2-pairs pairs)))
       g-par]

      ;; Annotation-free `within-apply-raw`:
      ;; Runs `compute-expr`, `action-expr`, `(invert-raw-expr compute-expr)`,
      ;; and automatically proves via ANF that `erased-wires` reduce to `0` on `S`!
      [`(within-apply-raw ,compute-expr ,action-expr ,erased-wires)
       (define g-u1 (step-expr! compute-expr))
       (define g-b  (step-expr! action-expr))
       (define g-u2 (step-expr! (invert-raw-expr compute-expr)))
       (verify-and-free-erased-wires! 'within-apply-raw erased-wires)
       (qphys-seq g-u1 (qphys-seq g-b g-u2))]

      [`(within-apply-raw ,compute-expr ,action-expr)
       (define pre-live live-wires)
       (define g-u1 (step-expr! compute-expr))
       (define newly-live (set->list (set-subtract live-wires pre-live)))
       (define g-b  (step-expr! action-expr))
       (define g-u2 (step-expr! (invert-raw-expr compute-expr)))
       (verify-and-free-erased-wires! 'within-apply-raw newly-live)
       (qphys-seq g-u1 (qphys-seq g-b g-u2))]

      ;; Annotation-free `erase-by-raw` (`Law U1`):
      ;; NO manual `(2 2 #t)` boolean flags! Proves `erased-wires == 0` symbolically!
      [`(erase-by-raw ,fwd-expr ,bwd-expr ,erased-wires)
       (define g-fwd (step-expr! fwd-expr))
       (define g-bwd (step-expr! bwd-expr))
       (verify-and-free-erased-wires! 'erase-by-raw erased-wires)
       (qphys-seq g-fwd g-bwd)]

      ;; Annotation-free `canon-quotient-raw` (`Law U2`):
      ;; Registers `q-wires` as non-canonical quotient wires, runs `cleanup-expr`,
      ;; and checks whether `q-wires` canonicalize to `0` (also enforced before `h`/`qft`!).
      [`(canon-quotient-raw ,q-wires ,cleanup-expr)
       (for ([qw (in-list q-wires)])
         (set! tracked-quotient-wires (set-add tracked-quotient-wires qw)))
       (define g-clean (step-expr! cleanup-expr))
       (for ([qw (in-list q-wires)])
         (define qp (get-anf qw))
         (unless (anf-domain-counterexample qp input-wires max-wt input-mask)
           (free-wire! qw)))
       g-clean]

      ;; Annotation-free `match-wires-raw` (`Law U3`):
      ;; Evaluates guard ANFs `P_i(x)`, proves pairwise orthogonality `P_i * P_j == 0`
      ;; and partition totality `1 ^ sum_i P_i == 0` on `S`, evaluates arms on cloned
      ;; symbolic states, and multiplexes output ANFs `sum_i P_i(x) * ANF_i(x)`!
      [`(match-wires-raw ,arms)
       (define guard-polys
         (for/list ([arm (in-list arms)])
           (eval-wire-guard (first arm) wire-anf max-wt input-mask)))
       ;; 1. Pairwise orthogonality check `P_i * P_j == 0` on `S`
       (for* ([i (in-range (length guard-polys))]
              [j (in-range (add1 i) (length guard-polys))])
         (define overlap
           (anf-and (list-ref guard-polys i) (list-ref guard-polys j) max-wt input-mask))
         (define cex (anf-domain-counterexample overlap input-wires max-wt input-mask))
         (when cex
           (set! u3-viols
                 (cons (hasheq 'kind "branch_overlap_non_orthogonal"
                               'branch_i i
                               'branch_j j
                               'residual_monomials (length overlap)
                               'counterexample cex)
                       u3-viols))))
       ;; 2. Partition totality check `1 ^ xor_i P_i == 0` on `S`
       (define xor-sum
         (foldl (lambda (gp acc) (anf-xor acc gp)) anf-zero guard-polys))
       (define uncovered (anf-not xor-sum))
       (define uncovered-cex
         (anf-domain-counterexample uncovered input-wires max-wt input-mask))
       (when uncovered-cex
         (set! u3-viols
               (cons (hasheq 'kind "incomplete_partition_uncovered_singular_locus"
                             'num_arms (length arms)
                             'residual_monomials (length uncovered)
                             'counterexample uncovered-cex)
                     u3-viols)))
       ;; 3. Symbolically execute each arm from a snapshot of `wire-anf` and multiplex!
       (define base-anf (hash-copy wire-anf))
       (define base-live live-wires)
       (define arm-anfs '())
       (define arm-lives '())
       (define joined-grade qphys-zero)
       (for ([arm (in-list arms)])
         (set! wire-anf (hash-copy base-anf))
         (set! live-wires base-live)
         (define g-arm (step-expr! (second arm)))
         (set! joined-grade (qphys-join joined-grade g-arm))
         (set! arm-anfs (cons (hash-copy wire-anf) arm-anfs))
         (set! arm-lives (cons live-wires arm-lives)))
       (set! arm-anfs (reverse arm-anfs))
       (set! arm-lives (reverse arm-lives))
       (define all-touched-wires
         (remove-duplicates
          (append (hash-keys base-anf)
                  (append-map hash-keys arm-anfs))))
       (define merged-anf (make-hasheqv))
       (for ([w (in-list all-touched-wires)])
         (define mux-poly
           (for/fold ([acc (anf-and uncovered (hash-ref base-anf w anf-zero) max-wt input-mask)])
                     ([gp (in-list guard-polys)]
                      [a-map (in-list arm-anfs)])
             (anf-xor acc
                      (anf-and gp (hash-ref a-map w anf-zero) max-wt input-mask))))
         (hash-set! merged-anf w mux-poly))
       (set! wire-anf merged-anf)
       (set! live-wires (foldl set-union base-live arm-lives))
       joined-grade]

      ;; Multi-shot / checkpoint reset (`multishot-reset-raw K body`)
      [`(multishot-reset-raw ,shots-k ,body)
       (qphys-multishot shots-k (step-expr! body))]

      [_ (error 'infer-wire-circuit "Unrecognized raw Lakefill wire AST: ~a" expr)]))

  (define final-grade (step-expr! raw-sexpr))

  ;; Scope-exit Law U4 check: any remaining uncancelled measurement phase taint!
  (for ([(m-sym tpoly) (in-hash phase-taints)])
    (define cex (anf-domain-counterexample tpoly input-wires max-wt input-mask))
    (when cex
      (set! u4-viols
            (cons (hasheq 'trigger "scope_exit_uncancelled_phase_taint"
                          'meas_var (symbol->string m-sym)
                          'residual_monomials (length tpoly)
                          'residual_degree (anf-degree tpoly)
                          'counterexample cex)
                  u4-viols))))

  (define u1-ok? (null? u1-viols))
  (define u2-ok? (null? u2-viols))
  (define u3-ok? (null? u3-viols))
  (define u4-ok? (null? u4-viols))
  (define logical-ok? (and u1-ok? u2-ok? u3-ok? u4-ok?))

  (define phi1-ok? (check-phi1? final-grade))
  (define phi2-ok? (check-phi2? final-grade))
  (define phi3-ok? (check-phi3? final-grade))
  (define all-ok? (and logical-ok? phi1-ok? phi2-ok? phi3-ok?))

  (define init-w (length input-wires))
  (define final-w (set-count live-wires))
  (define unrecycled-w (+ init-w unrecycled-allocs))
  (define qura-summary
    (qura-width-summary init-w
                        final-w
                        peak-live
                        (max peak-live unrecycled-w)
                        recycled-reuses
                        (max 0 (- (max peak-live unrecycled-w) peak-live))))

  (define max-deg-final
    (for/fold ([d 0]) ([(w p) (in-hash wire-anf)])
      (max d (anf-degree p))))
  (define total-monomials-final
    (for/sum ([(w p) (in-hash wire-anf)])
      (length p)))

  (wire-inference-result
   all-ok?
   logical-ok?
   u1-ok?
   u2-ok?
   u3-ok?
   u4-ok?
   phi1-ok?
   phi2-ok?
   phi3-ok?
   (reverse u1-viols)
   (reverse u2-viols)
   (reverse u3-viols)
   (reverse u4-viols)
   phi2-pairs
   qura-summary
   final-grade
   (effective-lindblad-action-milli final-grade)
   (hasheq 'max_final_anf_degree max-deg-final
           'total_final_monomials total-monomials-final)
   wire-anf))

;; =============================================================================
;; SECTION 5: Real Cryptographic & Algebraic Wire-Level Benchmark Builders (`16`)
;; =============================================================================

;; GF(2) matrix helpers for Boyar-Peralta S-Box and BCH(15, 7, 5)
(define (cols->gf2-mat m col-masks)
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-bit-field (list-ref col-masks c) r (add1 r)))))

(define (gf2-matmul A B)
  (define m (vector-length A))
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-and 1 (for/sum ([k (in-range m)])
                       (* (vector-ref (vector-ref A r) k)
                          (vector-ref (vector-ref B k) c)))))))

(define (gf2-matinv M)
  (define m (vector-length M))
  (define aug
    (for/vector ([r (in-range m)])
      (vector-append (vector-copy (vector-ref M r))
                     (for/vector ([c (in-range m)]) (if (= r c) 1 0)))))
  (for ([col (in-range m)])
    (define piv
      (for/first ([r (in-range col m)]
                  #:when (= (vector-ref (vector-ref aug r) col) 1))
        r))
    (when (not (= piv col))
      (define tmp (vector-ref aug col))
      (vector-set! aug col (vector-ref aug piv))
      (vector-set! aug piv tmp))
    (for ([r (in-range m)]
          #:when (and (not (= r col)) (= (vector-ref (vector-ref aug r) col) 1)))
      (define rv (vector-ref aug r))
      (define cv (vector-ref aug col))
      (for ([j (in-range (* 2 m))])
        (vector-set! rv j (bitwise-xor (vector-ref rv j) (vector-ref cv j))))))
  (for/vector ([r (in-range m)])
    (vector-copy (vector-ref aug r) m (* 2 m))))

(define (gf2-matrix->raw-sexpr mat wires)
  (define m (length wires))
  (define rows (for/vector ([r (in-range m)]) (vector-copy (vector-ref mat r))))
  (define ops '())
  (for ([col (in-range m)])
    (define piv
      (for/first ([r (in-range col m)] #:when (= (vector-ref (vector-ref rows r) col) 1)) r))
    (when (not (= piv col))
      (define tmp (vector-ref rows col))
      (vector-set! rows col (vector-ref rows piv))
      (vector-set! rows piv tmp)
      (set! ops (cons `(swap ,(list-ref wires col) ,(list-ref wires piv)) ops)))
    (for ([r (in-range m)]
          #:when (and (not (= r col)) (= (vector-ref (vector-ref rows r) col) 1)))
      (define rv (vector-ref rows r))
      (define cv (vector-ref rows col))
      (for ([j (in-range m)])
        (vector-set! rv j (bitwise-xor (vector-ref rv j) (vector-ref cv j))))
      (set! ops (cons `(cx ,(list-ref wires col) ,(list-ref wires r)) ops))))
  `(seq ,@ops))

(define tower-to-aes-mat (cols->gf2-mat 8 '(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f)))
(define aes-to-tower-mat (gf2-matinv tower-to-aes-mat))
(define aes-affine-mat
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (if (<= (modulo (- r c) 8) 4) 1 0))))
(define post-sbox-mat (gf2-matmul aes-affine-mat tower-to-aes-mat))

(define (lin-xor . forms)
  (define counts (make-hash))
  (for* ([f (in-list forms)] [w (in-list f)])
    (hash-update! counts w add1 0))
  (sort (for/list ([(w c) (in-hash counts)] #:when (odd? c)) w) <))

;; Helper emitting raw `(temp-and lw rw anc)` and `(mid-meas-x anc -> m)` + `(cond-cz m lw rw)`
;; wrapped in `within-apply-raw` linear fan-in on `lin-pair2 = (la lb)`.
(define (emit-temp-and-step anc lhs-ws rhs-ws lin-pair2)
  (match-define (list la lb) lin-pair2)
  (define-values (lw l-prep l-clean)
    (if (= (length lhs-ws) 1)
        (values (first lhs-ws) 'skip '())
        (values la `(seq ,@(for/list ([w (in-list lhs-ws)]) `(cx ,w ,la))) (list la))))
  (define-values (rw r-prep r-clean)
    (if (= (length rhs-ws) 1)
        (values (first rhs-ws) 'skip '())
        (values lb `(seq ,@(for/list ([w (in-list rhs-ws)]) `(cx ,w ,lb))) (list lb))))
  (define clean (append l-clean r-clean))
  (if (null? clean)
      `(temp-and ,lw ,rw ,anc)
      `(within-apply-raw (seq ,l-prep ,r-prep) (temp-and ,lw ,rw ,anc) ,clean)))

(define (emit-mbu-free-step anc m-sym lhs-ws rhs-ws lin-pair2 [omit-fixup? #f])
  (match-define (list la lb) lin-pair2)
  (define-values (lw l-prep l-clean)
    (if (= (length lhs-ws) 1)
        (values (first lhs-ws) 'skip '())
        (values la `(seq ,@(for/list ([w (in-list lhs-ws)]) `(cx ,w ,la))) (list la))))
  (define-values (rw r-prep r-clean)
    (if (= (length rhs-ws) 1)
        (values (first rhs-ws) 'skip '())
        (values lb `(seq ,@(for/list ([w (in-list rhs-ws)]) `(cx ,w ,lb))) (list lb))))
  (define clean (append l-clean r-clean))
  (define body
    (if omit-fixup?
        `(mid-meas-x ,anc -> ,m-sym)
        `(seq (mid-meas-x ,anc -> ,m-sym)
              (cond-cz ,m-sym ,lw ,rw))))
  (if (null? clean)
      body
      `(within-apply-raw (seq ,l-prep ,r-prep) ,body ,clean)))

;; -----------------------------------------------------------------------------
;; 1. `S1` & `B1`: Boyar-Peralta `34-AND` AES S-Box with `QuRA` Stage-3 Recycling!
;;    Uses ONLY `27` scratch wires (`16` Stage 1+2 + `9` recycled Stage-3 + `2` fan-in
;;    = `43` peak wires instead of `52` unrecycled!) and `34` `temp-and` + `mid-meas-x`.
;; -----------------------------------------------------------------------------
(define (build-bp34-sbox-raw-sexpr in8 out8 sc27 #:omit-last-cond-cz? [omit-last? #f])
  (define stage12-16 (take sc27 16))
  (define pool9      (take (drop sc27 16) 9))
  (define lin2       (drop sc27 25))

  (define s12-idx 0)
  (define s12-bindings '())
  (define (alloc-s12! lhs rhs)
    (define w (list-ref stage12-16 s12-idx))
    (set! s12-idx (add1 s12-idx))
    (set! s12-bindings (cons (list w lhs rhs) s12-bindings))
    (list w))

  (define (karatsuba-gf4-with alloc-fn a0 a1 b0 b1)
    (define p0 (alloc-fn a0 b0))
    (define p1 (alloc-fn a1 b1))
    (define p2 (alloc-fn (lin-xor a0 a1) (lin-xor b0 b1)))
    (list (lin-xor p0 p1) (lin-xor p2 p0)))

  (define (karatsuba-gf16-with alloc-fn a4 b4)
    (match-define (list a0 a1 a2 a3) a4)
    (match-define (list b0 b1 b2 b3) b4)
    (match-define (list m0-0 m0-1) (karatsuba-gf4-with alloc-fn a0 a1 b0 b1))
    (match-define (list m1-0 m1-1) (karatsuba-gf4-with alloc-fn a2 a3 b2 b3))
    (match-define (list m2-0 m2-1)
      (karatsuba-gf4-with alloc-fn
                          (lin-xor a0 a2) (lin-xor a1 a3)
                          (lin-xor b0 b2) (lin-xor b1 b3)))
    (list (lin-xor m0-0 m1-1)
          (lin-xor m0-1 m1-0 m1-1)
          (lin-xor m2-0 m0-0)
          (lin-xor m2-1 m0-1)))

  (define xt
    (for/list ([r (in-range 8)])
      (for/list ([c (in-range 8)]
                 #:when (= (vector-ref (vector-ref aes-to-tower-mat r) c) 1))
        (list-ref in8 c))))
  (define xL (take xt 4))
  (define xH (drop xt 4))
  (define c4 (map lin-xor xL xH))

  ;; Stage 1 (`9` TempANDs) + Stage 2 (`7` TempANDs) = `16` TempANDs
  (define prod-d (karatsuba-gf16-with alloc-s12! xL c4))
  (define uv-sq
    (list (third xH)
          (lin-xor (third xH) (fourth xH))
          (lin-xor (second xH) (third xH) (fourth xH))
          (lin-xor (first xH) (fourth xH))))
  (define d4 (map lin-xor prod-d uv-sq))
  (match-define (list d0 d1 d2 d3) d4)
  (define g0 (alloc-s12! d1 d2))
  (define g1 (alloc-s12! d0 d3))
  (define g2 (alloc-s12! d0 d2))
  (define g3 (alloc-s12! g0 d3))
  (define g4 (alloc-s12! g1 d2))
  (define g5 (alloc-s12! g1 d1))
  (define g6 (alloc-s12! d1 (lin-xor d3 g2)))
  (define dinv4
    (list (lin-xor d0 d1 d2 g0 g1 g6 g5 g4 g3)
          (lin-xor d1 d2 d3 g2 g5 g3)
          (lin-xor d2 g0 g1 g4 g3)
          (lin-xor d2 d3 g1 g3)))

  ;; Stage 3A (`9` TempANDs on `pool9`): `oL = c4 * dinv4`, XOR into `out8`, then MBU free `pool9`!
  (define p9-idx-a 0)
  (define oL-bindings '())
  (define oL
    (karatsuba-gf16-with
     (lambda (lhs rhs)
       (define w (list-ref pool9 p9-idx-a))
       (set! p9-idx-a (add1 p9-idx-a))
       (set! oL-bindings (cons (list w lhs rhs) oL-bindings))
       (list w))
     c4 dinv4))

  ;; Stage 3B (`9` TempANDs RECYCLING `pool9`!): `oH = xH * dinv4`, XOR into `out8`, then MBU free `pool9`!
  (define p9-idx-b 0)
  (define oH-bindings '())
  (define oH
    (karatsuba-gf16-with
     (lambda (lhs rhs)
       (define w (list-ref pool9 p9-idx-b))
       (set! p9-idx-b (add1 p9-idx-b))
       (set! oH-bindings (cons (list w lhs rhs) oH-bindings))
       (list w))
     xH dinv4))

  (define m-counter 0)
  (define (fresh-m!)
    (begin0 (string->symbol (format "m_bp_~a" m-counter))
      (set! m-counter (add1 m-counter))))

  (define s12-ordered (reverse s12-bindings))
  (define oL-ordered  (reverse oL-bindings))
  (define oH-ordered  (reverse oH-bindings))

  (define out-oL-forms
    (for/list ([r (in-range 8)])
      (apply lin-xor
             (for/list ([c (in-range 4)]
                        #:when (= (vector-ref (vector-ref post-sbox-mat r) c) 1))
               (list-ref oL c)))))
  (define out-oH-forms
    (for/list ([r (in-range 8)])
      (apply lin-xor
             (for/list ([c (in-range 4)]
                        #:when (= (vector-ref (vector-ref post-sbox-mat r) (+ c 4)) 1))
               (list-ref oH c)))))

  `(multishot-reset-raw
    8
    (seq ;; 1. Compute Stage 1 + Stage 2 (`16` TempANDs)
         ,@(for/list ([b (in-list s12-ordered)])
             (emit-temp-and-step (first b) (second b) (third b) lin2))
         ;; 2. Compute Stage 3A `oL` (`9` TempANDs on `pool9`), XOR to `out8`, and MBU-free `pool9`!
         ,@(for/list ([b (in-list oL-ordered)])
             (emit-temp-and-step (first b) (second b) (third b) lin2))
         ,@(for*/list ([r (in-range 8)] [src (in-list (list-ref out-oL-forms r))])
             `(cx ,src ,(list-ref out8 r)))
         ,@(for/list ([b (in-list (reverse oL-ordered))])
             (emit-mbu-free-step (first b) (fresh-m!) (second b) (third b) lin2 #f))
         ;; 3. Recycle `pool9` for Stage 3B `oH` (`9` TempANDs), XOR to `out8` + `0x63`, MBU-free `pool9`!
         ,@(for/list ([b (in-list oH-ordered)])
             (emit-temp-and-step (first b) (second b) (third b) lin2))
         ,@(for*/list ([r (in-range 8)] [src (in-list (list-ref out-oH-forms r))])
             `(cx ,src ,(list-ref out8 r)))
         ,@(for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
             `(x ,(list-ref out8 r)))
         ,@(for/list ([b (in-list (reverse oH-ordered))])
             (emit-mbu-free-step (first b) (fresh-m!) (second b) (third b) lin2 #f))
         ;; 4. Reverse MBU-free Stage 2 + Stage 1 (`16` TempANDs)
         ,@(for/list ([b (in-list (reverse s12-ordered))]
                      [idx (in-naturals)])
             (define is-last? (= idx (sub1 (length s12-ordered))))
             (emit-mbu-free-step (first b) (fresh-m!) (second b) (third b) lin2
                                 (and omit-last? is-last?))))))

;; -----------------------------------------------------------------------------
;; 2. `S2` & `B2`: Daemen `15`-Wire `Keccak` `chi_5` In-Place `erase-by-raw`
;; -----------------------------------------------------------------------------
(define (build-keccak-chi5-raw-sexpr row5 sc10 #:buggy-quadratic-uncompute? [buggy? #f])
  (define s5 (take sc10 5))
  (define t5 (drop sc10 5))
  (define (r i) (list-ref row5 (modulo i 5)))
  (define (s i) (list-ref s5   (modulo i 5)))
  (define (t i) (list-ref t5   (modulo i 5)))
  (define fwd-expr
    `(seq ,@(for/list ([x (in-range 5)])
              `(seq (cx ,(r x) ,(s x))
                    (x ,(r (add1 x)))
                    (ccx ,(r (add1 x)) ,(r (+ x 2)) ,(s x))
                    (x ,(r (add1 x)))))))
  (define bwd-expr
    (if buggy?
        ;; Subtle bug: uncomputes `r` using quadratic forward formula instead of degree-3 inverse!
        `(seq ,@(for/list ([x (in-range 5)])
                  `(seq (cx ,(s x) ,(r x))
                        (x ,(s (add1 x)))
                        (ccx ,(s (add1 x)) ,(s (+ x 2)) ,(r x))
                        (x ,(s (add1 x)))))
              ,@(for/list ([x (in-range 5)])
                  `(swap ,(r x) ,(s x))))
        ;; Sound degree-3 algebraic inverse `chi_5^-1` on `GF(2)^5`!
        `(seq (within-apply-raw
               (seq ,@(for/list ([x (in-range 5)])
                        `(seq (cx ,(s (+ x 2)) ,(t x))
                              (x ,(s (+ x 3)))
                              (ccx ,(s (+ x 3)) ,(s (+ x 4)) ,(t x))
                              (x ,(s (+ x 3))))))
               (seq ,@(for/list ([x (in-range 5)])
                        `(seq (cx ,(s x) ,(r x))
                              (x ,(s (add1 x)))
                              (ccx ,(s (add1 x)) ,(t x) ,(r x))
                              (x ,(s (add1 x))))))
               ,t5)
              ,@(for/list ([x (in-range 5)])
                  `(swap ,(r x) ,(s x))))))
  `(erase-by-raw ,fwd-expr ,bwd-expr ,sc10))

;; -----------------------------------------------------------------------------
;; 3. `S3` & `B3`: `BCH(15, 7, 5)` Peterson-Berlekamp vs Hamming `wt <= 1` Stub
;; -----------------------------------------------------------------------------
(define (gf16-poly-mul a b)
  (for/fold ([res 0]) ([k (in-range 4)])
    (define term
      (for/fold ([x a]) ([_ (in-range k)])
        (define sh (bitwise-and (arithmetic-shift x 1) #xF))
        (if (bitwise-bit-set? x 3) (bitwise-xor sh #x3) sh)))
    (if (bitwise-bit-set? b k) (bitwise-xor res term) res)))

(define (gf16-poly-pow a e)
  (for/fold ([r 1]) ([_ (in-range (modulo e 15))])
    (gf16-poly-mul r a)))

(define gf16-tower-to-poly-mat (cols->gf2-mat 4 '(#x1 #x6 #x2 #xc)))
(define gf16-poly-to-tower-mat (gf2-matinv gf16-tower-to-poly-mat))

(define (gf4-mul-xor-raw a b out)
  (match-define (list a0 a1) a)
  (match-define (list b0 b1) b)
  (match-define (list o0 o1) out)
  `(seq (ccx ,a0 ,b0 ,o0)
        (ccx ,a1 ,b1 ,o0)
        (ccx ,a0 ,b1 ,o1)
        (ccx ,a1 ,b0 ,o1)
        (ccx ,a1 ,b1 ,o1)))

(define (gf4-mul-u-xor-raw a out)
  (match-define (list a0 a1) a)
  (match-define (list o0 o1) out)
  `(seq (cx ,a1 ,o0)
        (cx ,a0 ,o1)
        (cx ,a1 ,o1)))

(define (gf16-tower-inv-raw x out sc4)
  (match-define (list x0 x1 x2 x3) x)
  (match-define (list o0 o1 o2 o3) out)
  (match-define (list c0 c1 d0 d1) sc4)
  `(within-apply-raw
    (seq (cx ,x0 ,c0) (cx ,x2 ,c0)
         (cx ,x1 ,c1) (cx ,x3 ,c1)
         ,(gf4-mul-xor-raw (list x0 x1) (list c0 c1) (list d0 d1))
         (cx ,x3 ,d0)
         (cx ,x2 ,d1)
         ;; gf4-inv-inplace: `(cx d1 d0)`
         (cx ,d1 ,d0))
    (seq ,(gf4-mul-xor-raw (list c0 c1) (list d0 d1) (list o0 o1))
         ,(gf4-mul-xor-raw (list x2 x3) (list d0 d1) (list o2 o3)))
    ,sc4))

(define (gf16-poly-mul-xor-raw a4 b4 out4)
  (define terms '())
  (for* ([i (in-range 4)] [j (in-range 4)])
    (define prod (gf16-poly-pow 2 (+ i j)))
    (for ([bit (in-range 4)]
          #:when (bitwise-bit-set? prod bit))
      (set! terms (cons `(ccx ,(list-ref a4 i) ,(list-ref b4 j) ,(list-ref out4 bit))
                        terms))))
  `(seq ,@(reverse terms)))

(define (gf16-poly-const-mul-xor-raw const-val x4 out4)
  (define terms '())
  (for ([i (in-range 4)])
    (define prod (gf16-poly-mul const-val (arithmetic-shift 1 i)))
    (for ([bit (in-range 4)]
          #:when (bitwise-bit-set? prod bit))
      (set! terms (cons `(cx ,(list-ref x4 i) ,(list-ref out4 bit)) terms))))
  `(seq ,@(reverse terms)))

(define (gf16-poly-inv-xor-raw x4 out4 sc4)
  `(seq (within-apply-raw
         ,(gf2-matrix->raw-sexpr gf16-poly-to-tower-mat x4)
         ,(gf16-tower-inv-raw x4 out4 sc4)
         ,sc4)
        ,(gf2-matrix->raw-sexpr gf16-tower-to-poly-mat out4)))

(define (bch15-syndrome-parity-raw e15 syn8)
  (define s1-wires (take syn8 4))
  (define s3-wires (drop syn8 4))
  (define steps '())
  (for ([i (in-range 15)])
    (define p1 (gf16-poly-pow 2 i))
    (define p3 (gf16-poly-pow 2 (* 3 i)))
    (for ([b (in-range 4)])
      (when (bitwise-bit-set? p1 b)
        (set! steps (cons `(cx ,(list-ref e15 i) ,(list-ref s1-wires b)) steps)))
      (when (bitwise-bit-set? p3 b)
        (set! steps (cons `(cx ,(list-ref e15 i) ,(list-ref s3-wires b)) steps)))))
  `(seq ,@(reverse steps)))

;; DQI `BCH(15, 7, 5)` error-register uncomputation over `wt(e15) <= 2`:
;; Forward computes `syn8 ^= H^perp(e15)`; backward decodes `syn8` via Peterson-Berlekamp
;; (`hamming-wt1-stub? = #f`) or Hamming `wt <= 1` stub (`hamming-wt1-stub? = #t`) to erase `e15 -> 0^15`!
(define (build-bch-15-7-5-dqi-erase-raw-sexpr e15 syn8 sc26 #:hamming-wt1-stub? [stub? #f])
  (define s1      (take syn8 4))
  (define s3      (drop syn8 4))
  (define s1-sq   (take sc26 4))
  (define num     (take (drop sc26 4) 4))
  (define s1-inv  (take (drop sc26 8) 4))
  (define sigma2  (take (drop sc26 12) 4))
  (define lam     (take (drop sc26 16) 4))
  (define sub-sc  (take (drop sc26 20) 4))
  (define mcx-sc  (drop sc26 24))
  (define sq-mat
    (cols->gf2-mat
     4
     (for/list ([b (in-range 4)])
       (define v (arithmetic-shift 1 b))
       (gf16-poly-mul v v))))

  (define bwd-decode
    (if stub?
        ;; Buggy Hamming wt<=1 stub: omits `sigma2 = (S_3 ^ S_1^3) * S_1^-1`, testing only `1 ^ S_1 * a^{-i} == 0`!
        `(seq ,@(for/list ([i (in-range 15)])
                  (define x-inv (gf16-poly-pow 2 (- 15 (modulo i 15))))
                  `(within-apply-raw
                    (seq (x ,(first lam))
                         ,(gf16-poly-const-mul-xor-raw x-inv s1 lam)
                         ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
                    (mcx-raw ,lam ,(list-ref e15 i) ,mcx-sc)
                    ,(append lam mcx-sc))))
        ;; Complete Peterson-Berlekamp wt<=2 decoder!
        `(within-apply-raw
          (seq ,@(for/list ([w (in-list s1)] [dst (in-list s1-sq)]) `(cx ,w ,dst))
               ,(gf2-matrix->raw-sexpr sq-mat s1-sq)
               ,@(for/list ([w (in-list s3)] [dst (in-list num)]) `(cx ,w ,dst))
               ,(gf16-poly-mul-xor-raw s1-sq s1 num)
               ,(gf16-poly-inv-xor-raw s1 s1-inv sub-sc)
               ,(gf16-poly-mul-xor-raw num s1-inv sigma2))
          (seq ,@(for/list ([i (in-range 15)])
                   (define x-inv (gf16-poly-pow 2 (- 15 (modulo i 15))))
                   (define x-inv-sq (gf16-poly-mul x-inv x-inv))
                   `(within-apply-raw
                     (seq (x ,(first lam))
                          ,(gf16-poly-const-mul-xor-raw x-inv s1 lam)
                          ,(gf16-poly-const-mul-xor-raw x-inv-sq sigma2 lam)
                          ,@(for/list ([lw (in-list lam)]) `(x ,lw)))
                     (mcx-raw ,lam ,(list-ref e15 i) ,mcx-sc)
                     ,(append lam mcx-sc))))
          ,sc26)))

  `(multishot-reset-raw
    16
    (erase-by-raw
     ,(bch15-syndrome-parity-raw e15 syn8)
     ,bwd-decode
     ,(append e15 sc26))))

;; -----------------------------------------------------------------------------
;; 4. `S4` & `B4`: Gidney `4`-Bit Ripple-Carry Temporary-AND Adder (`11` wires)
;; -----------------------------------------------------------------------------
(define (build-gidney-4bit-adder-raw-sexpr a4 b4 c3 #:premature-carry-bug? [buggy? #f])
  (define (a i) (list-ref a4 i))
  (define (b i) (list-ref b4 i))
  (define (c i) (list-ref c3 i))
  `(seq ;; Forward carry sweep (`3` temp-and gates)
        (temp-and ,(a 0) ,(b 0) ,(c 0))
        (cx ,(c 0) ,(a 1))
        (cx ,(c 0) ,(b 1))
        (temp-and ,(a 1) ,(b 1) ,(c 1))
        (cx ,(c 0) ,(c 1))
        (cx ,(c 1) ,(a 2))
        (cx ,(c 1) ,(b 2))
        (temp-and ,(a 2) ,(b 2) ,(c 2))
        (cx ,(c 1) ,(c 2))
        ;; MSB sum bit (`i = 3`)
        (cx ,(c 2) ,(b 3))
        (cx ,(a 3) ,(b 3))
        ;; Reverse carry MBU uncomputation (`0` Toffolis!)
        (cx ,(c 1) ,(c 2))
        (mid-meas-x ,(c 2) -> m_c2)
        (cond-cz m_c2 ,(a 2) ,(b 2))
        (cx ,(c 1) ,(a 2))
        (cx ,(a 2) ,(b 2))
        ;; Step `i = 1`: in `B4`, `(cx c0 c1)` is accidentally omitted before `mid-meas-x c1`,
        ;; leaving `c1` clean (`|0>`) after `mid-meas-x` (so runtime `assert-clean` passes!)
        ;; while injecting residual phase taint `m_c1 * (a0 * b0)`!
        ,(if buggy? 'skip `(cx ,(c 0) ,(c 1)))
        (mid-meas-x ,(c 1) -> m_c1)
        (cond-cz m_c1 ,(a 1) ,(b 1))
        (cx ,(c 0) ,(a 1))
        (cx ,(a 1) ,(b 1))
        ;; Step `i = 0`
        (mid-meas-x ,(c 0) -> m_c0)
        (cond-cz m_c0 ,(a 0) ,(b 0))
        (cx ,(a 0) ,(b 0))))

;; -----------------------------------------------------------------------------
;; 5. `S5` & `B5`: Kawamura RNS-CRT Quotient Cleanup Before `H` Interference
;; -----------------------------------------------------------------------------
;; Inputs `a[0..1] = (0 1)`, `b[0..1] = (2 3)`, CRT overflow quotient wire `q_crt = 4`,
;; carry scratch `c0 = 5`. Extended addition computes `(b <- (a + b) mod 4, q_crt <- floor((a+b)/4))`.
;; Before applying Hadamard interference `(h 2)` on sum LSB, `canon-quotient-raw` must erase `q_crt`!
;; `S5` uncomputes exact carry quotient `c1 = a1*b1 ^ a0*b0*(a1 ^ b1)`; `B5` uses truncated MSB
;; approximation `a1*b1` (passes `13/16` pairs, fails on `(a=1, b=3)` with residual `q_crt = 1`!).
(define (build-kawamura-crt-raw-sexpr #:inexact-msb-approx? [buggy? #f])
  `(seq ;; Extended 2-bit sum into `(b0=2, b1=3, q_crt=4)` using scratch `c0=5`:
        (within-apply-raw
         (ccx 0 2 5)
         (seq ;; `q_crt ^= a1*b1 ^ c0*(a1 ^ b1)` (where `b1` still holds `b1_in`)
              (ccx 1 3 4)
              (cx 1 3)
              (ccx 5 3 4)
              (cx 5 3))
         (5))
        (cx 0 2)
        ;; Now `b = (a + b) mod 4` and `q_crt = [(a + b) >= 4]`.
        ;; Note `b ^ a` recovers original `b_in`, so exact quotient cleanup reconstructs
        ;; `b_in` inside `within-apply-raw` and erases `q_crt -> 0`!
        (canon-quotient-raw
         (4)
         ,(if buggy?
              ;; Buggy MSB-only Kawamura estimate (ignores carry from bit 0!):
              `(within-apply-raw
                (seq (cx 0 2) (ccx 0 2 5) (cx 5 3) (cx 1 3))
                (ccx 1 3 4)
                (5))
              ;; Exact Kawamura carry-corrected quotient erasure:
              `(within-apply-raw
                (seq (cx 0 2) (ccx 0 2 5) (cx 5 3) (cx 1 3))
                (seq (ccx 1 3 4)
                     (cx 1 3)
                     (ccx 5 3 4)
                     (cx 1 3))
                (5))))
        ;; Hadamard interference test on canonicalized sum wire `2`!
        (h 2)))

;; -----------------------------------------------------------------------------
;; 6. `S6` & `B6`: `4-Way` Orthogonal ECC Point-Addition Partition (`match-wires-raw`)
;; -----------------------------------------------------------------------------
;; Subgroup encoding `P = (p0=0, p1=1)`, `Q = (q0=2, q1=3)`, output `R = (r0=4, r1=5)`:
;; `00 = O` (infinity), `01 = G`, `10 = 2G` (`-2G = 2G`), `11 = 3G = -G`.
;; Exact group addition `R ^= (P + Q) mod 4` split across the 4 algebraic Weierstrass regimes:
;;   1. `identity`: `P == O || Q == O` (`R ^= P ^ Q`)
;;   2. `inverse-infinity`: `P != O && Q != O && P + Q == O` (`R ^= 00`, i.e., `skip`)
;;   3. `point-doubling`: `P != O && Q != O && P == Q && P != 2G` (`01+01 -> 10`, `11+11 -> 10`)
;;   4. `general-chord`: `P != O && Q != O && P != Q && P + Q != O`
(define (build-ecc-4way-partition-raw-sexpr #:omit-doubling-arm? [omit-dbl? #f])
  (define p-zero `(all-zero (0 1)))
  (define q-zero `(all-zero (2 3)))
  (define both-nz `(and (non-zero (0 1)) (non-zero (2 3))))
  ;; `P + Q == 0 mod 4` for nonzero `P, Q` holds iff `(p0 == q0) && (p1 ^ q1 == p0)`!
  ;; Check: `(01,11)` -> p0=q0=1, p1^q1=1=p0; `(11,01)` -> 1=1; `(10,10)` -> p0=q0=0, p1^q1=0=p0!
  (define is-inv
    `(and ,both-nz
          (not (xor (wire 0) (wire 2)))
          (not (xor (xor (wire 1) (wire 3)) (wire 0)))))
  ;; `point-doubling` (`P == Q` and `P + Q != O`, i.e., `P in {01, 11}`, so `p0 == 1` and `P == Q`):
  (define is-dbl
    `(and ,both-nz
          (eq-wires (0 1) (2 3))
          (wire 0)))
  ;; `general-chord` (`P != O && Q != O && P != Q && P + Q != O`):
  (define is-chord
    `(and ,both-nz
          (not (eq-wires (0 1) (2 3)))
          (not ,is-inv)))

  (define id-arm    `(,`(or ,p-zero ,q-zero) (seq (cx 0 4) (cx 2 4) (cx 1 5) (cx 3 5))))
  (define inv-arm   `(,is-inv skip))
  (define dbl-arm   `(,is-dbl (x 5))) ;; `01+01 = 10` and `11+11 = 10`!
  ;; On `general-chord` (`(01,10)->11`, `(10,01)->11`, `(10,11)->01`, `(11,10)->01`):
  ;; Notice `r0 = 1` always (`x 4`), and `r1 = ~(p1 & q1)` (`x 5 ; ccx 1 3 5`)!
  ;; Verify: `(01,10)` (`p1=0,q1=1`) -> `r0=1, r1=1` (`11` = 3G)!
  ;;         `(11,10)` (`p1=1,q1=1`) -> `r0=1, r1=0` (`01` = G)! Exact!!
  (define chord-arm `(,is-chord (seq (x 4) (x 5) (ccx 1 3 5))))

  (define arms
    (if omit-dbl?
        (list id-arm inv-arm chord-arm)
        (list id-arm inv-arm dbl-arm chord-arm)))
  `(match-wires-raw ,arms))

;; -----------------------------------------------------------------------------
;; 7. `S7` & `B7`: Sawtooth Unary-Iteration `QROM` with Algebraic `cond-z + cond-cz`
;; -----------------------------------------------------------------------------
;; Controlled 4-entry Sawtooth QROM (`ctrl = 0`, `addr = (1 2)`, `out = (3 4 5 6)`,
;; `hot = (7 8)`) looking up table `'(5 11 14 3)`:
;; Demonstrates BOTH standard sawtooth `(cx parent child) + (cond-cz m parent a0)` AND
;; an algebraically equivalent negated-branch `(cond-z m ctrl) + (cond-cz m ctrl a1)`
;; cancelling `m * ctrl * (1 ^ a1) = m*ctrl ^ m*ctrl*a1`!
;; In `B7`, `(cond-z m_root 0)` is omitted on the negated branch, leaving `T[m_root] = ctrl`!
(define (build-sawtooth-qrom-algebraic-raw-sexpr #:omit-linear-cond-z? [buggy? #f])
  ;; Table: T[0]=5 (#b0101), T[1]=11 (#b1011), T[2]=14 (#b1110), T[3]=3 (#b0011)
  `(seq ;; 1. Negated MSB branch `h1 = ctrl & ~a1` (`wire 7 = w0 * (1 ^ w2)`)
        (x 2)
        (temp-and 0 2 7)
        (x 2)
        ;; Leaf `a1=0, a0=0` (`T[0] = 5 = #b0101`) & `a1=0, a0=1` (`T[1] = 11 = #b1011`) via sawtooth on `h0 = 8`:
        (x 1)
        (temp-and 7 1 8)
        (x 1)
        (cx 8 3) (cx 8 5)                   ;; T[0] = 5
        (cx 7 8)                            ;; sawtooth toggle: `h0 = h1 * a0`
        (cx 8 3) (cx 8 4) (cx 8 6)          ;; T[1] = 11
        (mid-meas-x 8 -> m_qrom_l)
        (cond-cz m_qrom_l 7 1)
        ;; Free `h1 = 7` directly from `ctrl * (1 ^ a1)` via ALGEBRAIC `cond-z + cond-cz`!
        (mid-meas-x 7 -> m_qrom_root0)
        ,(if buggy? 'skip `(cond-z m_qrom_root0 0))
        (cond-cz m_qrom_root0 0 2)
        ;; 2. Recycle `h1 = 7` and `h0 = 8` (`0` new wires!) for `a1 == 1` (`h1 = ctrl & a1`):
        (temp-and 0 2 7)
        (x 1)
        (temp-and 7 1 8)
        (x 1)
        (cx 8 4) (cx 8 5) (cx 8 6)          ;; T[2] = 14
        (cx 7 8)                            ;; sawtooth toggle: `h0 = h1 * a0`
        (cx 8 3) (cx 8 4)                   ;; T[3] = 3
        (mid-meas-x 8 -> m_qrom_r)
        (cond-cz m_qrom_r 7 1)
        (mid-meas-x 7 -> m_qrom_root1)
        (cond-cz m_qrom_root1 0 2)))

;; -----------------------------------------------------------------------------
;; 8. `S8` & `B8`: `QuRA` Recycled Double `GF(2^4)` Session + `par-wires` `Φ2` Check
;; -----------------------------------------------------------------------------
;; `S8`: Runs two sequential `GF(2^4)` Karatsuba multipliers (`3` TempANDs on `GF(2^2)` / `7`
;; TempANDs) recycling the SAME scratch ancillas via `mid-meas-x + cond-cz`, followed by
;; spatially separated `(par-wires (cx 0 1) (cx 4 5))` (`d_edge(1,4) = 3 >= 2`, `d_um = 15 >= 8`)
;; + zig-zag `syndrome-plaquette` + exact `rz-dyadic` (`k = 12 < 53`).
;; `B8`: Runs `(par-wires (cx 0 1) (cx 2 3))` on adjacent coupler/Rydberg neighbors
;; (`d_edge(1,2) = 1 < 2`, `d_um(1,2) = 5 um < 8 um = r_b`), caught by `Φ2` (`χ > 0`)!
(define (build-qura-recycled-session-and-par-raw-sexpr #:adjacent-par-collision? [collide? #f])
  (if collide?
      `(seq (par-wires (cx 0 1) (cx 2 3))
            (syndrome-plaquette (0 2 4) 5 #f)
            (rz-dyadic 0 12 #t 5))
      `(seq ;; Round 1: GF(2^2) Karatsuba product `(a0,a1)*(b0,b1)` into `(out0=4, out1=5)` using `sc=(6 7 8)` + fanin `(9 10)`
            (temp-and 0 2 6)
            (temp-and 1 3 7)
            (within-apply-raw (seq (cx 0 9) (cx 1 9) (cx 2 10) (cx 3 10))
                              (temp-and 9 10 8)
                              (9 10))
            (cx 6 4) (cx 7 4)
            (cx 8 5) (cx 6 5)
            ;; MBU-free `8, 7, 6` in reverse topological order (`peak = 11` wires!)
            (within-apply-raw (seq (cx 0 9) (cx 1 9) (cx 2 10) (cx 3 10))
                              (seq (mid-meas-x 8 -> m_r1_2) (cond-cz m_r1_2 9 10))
                              (9 10))
            (mid-meas-x 7 -> m_r1_1) (cond-cz m_r1_1 1 3)
            (mid-meas-x 6 -> m_r1_0) (cond-cz m_r1_0 0 2)
            ;; Round 2: RECYCLE the exact same ancillas `(6 7 8)` + `(9 10)` for `(out0,out1)*(a0,a1)` -> `(out2=11, out3=12)`
            ;; (`peak = 13` wires vs `16` unrecycled!)
            (temp-and 4 0 6)
            (temp-and 5 1 7)
            (within-apply-raw (seq (cx 4 9) (cx 5 9) (cx 0 10) (cx 1 10))
                              (temp-and 9 10 8)
                              (9 10))
            (cx 6 11) (cx 7 11)
            (cx 8 12) (cx 6 12)
            (within-apply-raw (seq (cx 4 9) (cx 5 9) (cx 0 10) (cx 1 10))
                              (seq (mid-meas-x 8 -> m_r2_2) (cond-cz m_r2_2 9 10))
                              (9 10))
            (mid-meas-x 7 -> m_r2_1) (cond-cz m_r2_1 5 1)
            (mid-meas-x 6 -> m_r2_0) (cond-cz m_r2_0 4 0)
            ;; Spatially separated parallel CNOTs (`d_edge(1,4) = 3 >= 2`, `d_um = 15 >= 8`) + `Φ3` FT checks:
            (par-wires (cx 0 1) (cx 4 5))
            (syndrome-plaquette (0 2 4) 5 #f)
            (rz-dyadic 0 12 #t 5))))

;; Convert any raw S-expression into JSON-serializable nested lists/strings/ints/booleans
(define (sexpr->json-ast s)
  (cond
    [(boolean? s) s]
    [(exact-integer? s) s]
    [(symbol? s) (symbol->string s)]
    [(string? s) s]
    [(list? s) (map sexpr->json-ast s)]
    [else (format "~a" s)]))

(define (build-wire-level-16-benchmark-circuits)
  (list
   ;; === 8 Sound Unannotated Wire-Level Circuits (`S1`–`S8`) ===
   (hasheq 'id "S1_bp34_aes_sbox_mbu_recycled"
           'category "sound_wire_level"
           'target_laws '("U1" "U4" "QuRA_Width" "Phi1_Phi3")
           'input_wires (range 0 8)
           'scratch_wires (range 8 43)
           'domain 'all
           'expected_well_typed #t
           'sexpr (build-bp34-sbox-raw-sexpr (range 0 8) (range 8 16) (range 16 43) #:omit-last-cond-cz? #f))
   (hasheq 'id "S2_keccak_chi5_erase_by_deg3"
           'category "sound_wire_level"
           'target_laws '("U1" "QuRA_Width" "Phi1_Phi3")
           'input_wires (range 0 5)
           'scratch_wires (range 5 15)
           'domain 'all
           'expected_well_typed #t
           'sexpr (build-keccak-chi5-raw-sexpr (range 0 5) (range 5 15) #:buggy-quadratic-uncompute? #f))
   (hasheq 'id "S3_bch_15_7_5_pb_wt2_uncompute"
           'category "sound_wire_level"
           'target_laws '("U1_Subspace" "QuRA_Width" "Phi1_Phi3")
           'input_wires (range 0 15)
           'scratch_wires (range 15 49)
           'domain '(wt-le 2)
           'expected_well_typed #t
           'sexpr (build-bch-15-7-5-dqi-erase-raw-sexpr (range 0 15) (range 15 23) (range 23 49) #:hamming-wt1-stub? #f))
   (hasheq 'id "S4_gidney_4bit_adder_mbu"
           'category "sound_wire_level"
           'target_laws '("U1" "U4" "QuRA_Width" "Phi1_Phi3")
           'input_wires (range 0 8)
           'scratch_wires (range 8 11)
           'domain 'all
           'expected_well_typed #t
           'sexpr (build-gidney-4bit-adder-raw-sexpr (range 0 4) (range 4 8) (range 8 11) #:premature-carry-bug? #f))
   (hasheq 'id "S5_kawamura_crt_quotient_cleanup"
           'category "sound_wire_level"
           'target_laws '("U1" "U2" "Phi1_Phi3")
           'input_wires (range 0 4)
           'scratch_wires '(4 5)
           'domain 'all
           'expected_well_typed #t
           'sexpr (build-kawamura-crt-raw-sexpr #:inexact-msb-approx? #f))
   (hasheq 'id "S6_ecc_4way_complete_partition"
           'category "sound_wire_level"
           'target_laws '("U3" "Phi1_Phi3")
           'input_wires (range 0 4)
           'scratch_wires '(4 5)
           'domain 'all
           'expected_well_typed #t
           'sexpr (build-ecc-4way-partition-raw-sexpr #:omit-doubling-arm? #f))
   (hasheq 'id "S7_sawtooth_qrom_algebraic_cond_z"
           'category "sound_wire_level"
           'target_laws '("U1" "U4_Algebraic" "QuRA_Width" "Phi1_Phi3")
           'input_wires '(0 1 2)
           'scratch_wires '(3 4 5 6 7 8)
           'domain 'all
           'expected_well_typed #t
           'sexpr (build-sawtooth-qrom-algebraic-raw-sexpr #:omit-linear-cond-z? #f))
   (hasheq 'id "S8_qura_recycled_gf16_and_disjoint_par"
           'category "sound_wire_level"
           'target_laws '("U1" "U4" "QuRA_Width" "Phi1" "Phi2" "Phi3")
           'input_wires '(0 1 2 3)
           'scratch_wires '(4 5 6 7 8 9 10 11 12)
           'domain 'all
           'expected_well_typed #t
           'sexpr (build-qura-recycled-session-and-par-raw-sexpr #:adjacent-par-collision? #f))

   ;; === 8 Subtle Unannotated Bug Circuits (`B1`–`B8`) ===
   (hasheq 'id "B1_bp34_sbox_missing_last_cond_cz"
           'category "buggy_unannotated"
           'target_laws '("U4")
           'input_wires (range 0 8)
           'scratch_wires (range 8 43)
           'domain 'all
           'expected_well_typed #f
           'sexpr (build-bp34-sbox-raw-sexpr (range 0 8) (range 8 16) (range 16 43) #:omit-last-cond-cz? #t))
   (hasheq 'id "B2_keccak_chi5_quadratic_uncompute_bug"
           'category "buggy_unannotated"
           'target_laws '("U1")
           'input_wires (range 0 5)
           'scratch_wires (range 5 15)
           'domain 'all
           'expected_well_typed #f
           'sexpr (build-keccak-chi5-raw-sexpr (range 0 5) (range 5 15) #:buggy-quadratic-uncompute? #t))
   (hasheq 'id "B3_bch_15_7_5_hamming_wt1_stub_bug"
           'category "buggy_unannotated"
           'target_laws '("U1_Subspace")
           'input_wires (range 0 15)
           'scratch_wires (range 15 49)
           'domain '(wt-le 2)
           'expected_well_typed #f
           'sexpr (build-bch-15-7-5-dqi-erase-raw-sexpr (range 0 15) (range 15 23) (range 23 49) #:hamming-wt1-stub? #t))
   (hasheq 'id "B4_gidney_adder_premature_carry_mbu_bug"
           'category "buggy_unannotated"
           'target_laws '("U4")
           'input_wires (range 0 8)
           'scratch_wires (range 8 11)
           'domain 'all
           'expected_well_typed #f
           'sexpr (build-gidney-4bit-adder-raw-sexpr (range 0 4) (range 4 8) (range 8 11) #:premature-carry-bug? #t))
   (hasheq 'id "B5_kawamura_crt_inexact_msb_quotient_bug"
           'category "buggy_unannotated"
           'target_laws '("U2")
           'input_wires (range 0 4)
           'scratch_wires '(4 5)
           'domain 'all
           'expected_well_typed #f
           'sexpr (build-kawamura-crt-raw-sexpr #:inexact-msb-approx? #t))
   (hasheq 'id "B6_ecc_chord_only_missing_doubling_bug"
           'category "buggy_unannotated"
           'target_laws '("U3")
           'input_wires (range 0 4)
           'scratch_wires '(4 5)
           'domain 'all
           'expected_well_typed #f
           'sexpr (build-ecc-4way-partition-raw-sexpr #:omit-doubling-arm? #t))
   (hasheq 'id "B7_sawtooth_qrom_missing_linear_cond_z_bug"
           'category "buggy_unannotated"
           'target_laws '("U4_Algebraic")
           'input_wires '(0 1 2)
           'scratch_wires '(3 4 5 6 7 8)
           'domain 'all
           'expected_well_typed #f
           'sexpr (build-sawtooth-qrom-algebraic-raw-sexpr #:omit-linear-cond-z? #t))
   (hasheq 'id "B8_par_wires_coupler_blockade_collision_bug"
           'category "buggy_unannotated"
           'target_laws '("Phi2")
           'input_wires '(0 1 2 3 4)
           'scratch_wires '()
           'domain 'all
           'expected_well_typed #f
           'sexpr (build-qura-recycled-session-and-par-raw-sexpr #:adjacent-par-collision? #t))))

(define (result->json-hash spec res elapsed-ms)
  (define qw (wire-inference-result-qura-width res))
  (define pg (wire-inference-result-phys-grade res))
  (hasheq
   'id (hash-ref spec 'id)
   'category (hash-ref spec 'category)
   'target_laws (hash-ref spec 'target_laws)
   'input_wires (hash-ref spec 'input_wires)
   'scratch_wires (hash-ref spec 'scratch_wires)
   'domain (sexpr->json-ast (hash-ref spec 'domain))
   'expected_well_typed (hash-ref spec 'expected_well_typed)
   'inferred_well_typed (wire-inference-result-well-typed? res)
   'logical_well_typed (wire-inference-result-logical-well-typed? res)
   'u1_ok (wire-inference-result-u1-ok? res)
   'u2_ok (wire-inference-result-u2-ok? res)
   'u3_ok (wire-inference-result-u3-ok? res)
   'u4_ok (wire-inference-result-u4-ok? res)
   'phi1_ok (wire-inference-result-phi1-ok? res)
   'phi2_ok (wire-inference-result-phi2-ok? res)
   'phi3_ok (wire-inference-result-phi3-ok? res)
   'u1_violations (wire-inference-result-u1-violations res)
   'u2_violations (wire-inference-result-u2-violations res)
   'u3_violations (wire-inference-result-u3-violations res)
   'u4_violations (wire-inference-result-u4-violations res)
   'phi2_collision_pairs (wire-inference-result-phi2-collision-pairs res)
   'qura_width (hasheq
                'initial_width (qura-width-summary-initial-width qw)
                'final_live_width (qura-width-summary-final-live-width qw)
                'peak_live_width (qura-width-summary-peak-live-width qw)
                'unrecycled_ssa_width (qura-width-summary-unrecycled-ssa-width qw)
                'recycled_wire_reuses (qura-width-summary-recycled-wire-reuses qw)
                'width_saved (qura-width-summary-width-saved qw))
   'phys_grade (hasheq
                'idle_milli (qphys-grade-idle-milli pg)
                'gate_milli (qphys-grade-gate-milli pg)
                'mbu_excess_ns (qphys-grade-mbu-excess-ns pg)
                'routing_excess_cx (qphys-grade-routing-excess-cx pg)
                'exclusion_collisions (qphys-grade-exclusion-collisions pg)
                'eff_fault_dist (or (qphys-grade-eff-fault-dist pg) "top_inf")
                'req_target_dist (qphys-grade-req-target-dist pg)
                'support_wire_count (set-count (qphys-grade-support-wires pg))
                'duration_ns (qphys-grade-duration-ns pg)
                'effective_lindblad_milli (wire-inference-result-effective-lindblad-milli res))
   'wire_anf_stats (wire-inference-result-wire-anf-stats res)
   'inference_time_ms (real->decimal-string elapsed-ms 3)
   'raw_ast (sexpr->json-ast (hash-ref spec 'sexpr))))

(define (run-wire-level-symbolic-typechecker-suite)
  (define t0 (current-inexact-milliseconds))
  (define hw (default-wire-aod-ryst-hw-spec))
  (define specs (build-wire-level-16-benchmark-circuits))

  (define circuit-reports
    (for/list ([sp (in-list specs)])
      (define c-t0 (current-inexact-milliseconds))
      (define res
        (infer-wire-circuit hw
                            (hash-ref sp 'input_wires)
                            (hash-ref sp 'scratch_wires)
                            (hash-ref sp 'domain)
                            (hash-ref sp 'sexpr)))
      (define c-ms (- (current-inexact-milliseconds) c-t0))
      (define expected? (hash-ref sp 'expected_well_typed))
      (unless (equal? (wire-inference-result-well-typed? res) expected?)
        (error 'run-wire-level-symbolic-typechecker-suite
               "Circuit ~a expected well-typed?=~a, got ~a (u1=~a u2=~a u3=~a u4=~a phi1=~a phi2=~a phi3=~a, lindblad=~a)"
               (hash-ref sp 'id)
               expected?
               (wire-inference-result-well-typed? res)
               (wire-inference-result-u1-ok? res)
               (wire-inference-result-u2-ok? res)
               (wire-inference-result-u3-ok? res)
               (wire-inference-result-u4-ok? res)
               (wire-inference-result-phi1-ok? res)
               (wire-inference-result-phi2-ok? res)
               (wire-inference-result-phi3-ok? res)
               (wire-inference-result-effective-lindblad-milli res)))
      (result->json-hash sp res c-ms)))

  ;; Extra self-checks:
  ;; 1. BCH(15,7,5) Hamming wt<=1 stub MUST be rejected with a concrete weight-2 counterexample!
  (define b3-rep
    (findf (lambda (r) (equal? (hash-ref r 'id) "B3_bch_15_7_5_hamming_wt1_stub_bug"))
           circuit-reports))
  (define b3-first-cex
    (hash-ref (first (hash-ref b3-rep 'u1_violations)) 'counterexample))
  (unless (= (hash-ref b3-first-cex 'hamming_weight) 2)
    (error 'bch-hamming-stub-check
           "Expected minimal counterexample of Hamming weight 2, got ~a" b3-first-cex))

  ;; 2. Verify history-variable U2 derivative check `(quotient-vars ...)` on insertion-order bit!
  (define hist-ok-res
    (infer-wire-circuit hw '(0 1) '(2) '(quotient-vars (1))
                        '(seq (cx 0 2) (h 2))))
  (define hist-bad-res
    (infer-wire-circuit hw '(0 1) '(2) '(quotient-vars (1))
                        '(seq (cx 0 2) (cx 1 2) (h 2))))
  (unless (and (wire-inference-result-u2-ok? hist-ok-res)
               (not (wire-inference-result-u2-ok? hist-bad-res)))
    (error 'history-u2-check "Expected history-independent pass and history-dependent fail"))

  ;; 3. Verify `S1` (`BP34` recycled 34-AND S-box) inferred ANF on `out8 = 8..15`
  ;;    evaluates to the exact bijective NIST FIPS-197 AES S-Box (`S(0x00)=0x63`, `S(0x53)=0xed`)!
  (define s1-spec (first specs))
  (define s1-res
    (infer-wire-circuit hw
                        (hash-ref s1-spec 'input_wires)
                        (hash-ref s1-spec 'scratch_wires)
                        (hash-ref s1-spec 'domain)
                        (hash-ref s1-spec 'sexpr)))
  (define s1-anf-map (wire-inference-result-final-wire-anf s1-res))
  (define (eval-s1-byte x)
    (for/sum ([b (in-range 8)])
      (arithmetic-shift (anf-eval (hash-ref s1-anf-map (+ 8 b)) x) b)))
  (define s1-seen (for/set ([x (in-range 256)]) (eval-s1-byte x)))
  (unless (and (= (eval-s1-byte #x00) #x63)
               (= (eval-s1-byte #x53) #xed)
               (= (set-count s1-seen) 256))
    (error 'bp34-fips197-anf-check
           "BP34 recycled S-box ANF mismatch: S(0)=~x S(0x53)=~x card=~a"
           (eval-s1-byte #x00) (eval-s1-byte #x53) (set-count s1-seen)))

  (define elapsed-ms (- (current-inexact-milliseconds) t0))
  (hasheq
   'suite "Wire-Level Symbolic ANF Type, Taint, QuRA Width & QPhysGrade Inference"
   'status "PASS"
   'manual_boolean_witness_flags 0
   'total_circuits (length circuit-reports)
   'sound_circuits_accepted 8
   'buggy_circuits_rejected 8
   'bch_15_7_5_hamming_stub_min_cex_weight (hash-ref b3-first-cex 'hamming_weight)
   'bch_15_7_5_hamming_stub_min_cex_wires (hash-ref b3-first-cex 'active_input_wires)
   'wall_time_ms (real->decimal-string elapsed-ms 2)
   'circuits circuit-reports))

(module+ main
  (write-json (run-wire-level-symbolic-typechecker-suite))
  (newline))
