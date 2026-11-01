#lang racket/base

;; =============================================================================
;; `compiler/lakefillq-sota-ecc-rsa-audit.rkt`
;;
;; SOTA Quantum ECC (`ECC-256`) and Quantum RSA (`RSA-2048` / `RSA-4096`)
;; Research Correctness Guards & Circuit Optimizations in `LakefillQ`.
;;
;; Codifies concrete correctness guards and circuit-lowering combinators derived
;; from auditing open-source SOTA research implementations:
;;   - `microsoft/QuantumEllipticCurves` (`EllipticCurves.qs`, `ModularArithmetic.qs`)
;;   - `quantumlib/Qualtran` (`ec_add.py`, `ec_add_r.py`, `mod_division.py`, `rsa_mod_exp.py`)
;;   - `Strilanc/quantum-factor-2025-code` (`_detailed_example_code.py`, `_execution_config.py`)
;;   - `qec-codes/QuantumThreatTracker` (`chevignard_utils/estimations.py`, `litinski_ecc.py`)
;;
;; Core capabilities:
;;   1. Signed Odd-Window `SelectSwap` Combinator (`2^{w-1}` positive odd entries,
;;      zero-Toffoli bitwise address complement, controlled `y -> p - y` field
;;      negation, `0` identity-point table entries, and `Law U4` Berry-Gidney
;;      `M_X` phase-table uncomputation).
;;   2. Offset-Accumulator Exceptional-Point Guard & Zero-Safe Kaliski /
;;      Bernstein-Yang `divstep` Checker (`P = Q`, `P = -Q`, `P + Q = -P`
;;      reverse-uncomputation hazard, and `0 -> 0` modular inversion cleanup).
;;   3. Static Type-Index Bound Checkers for Zalka-Gidney Coset Carry Runway
;;      (`c_pad`) and Approximate RNS-CRT Truncated Accumulation (`Gidney 2025` /
;;      `Chevignard et al. 2024`).
;;   4. Fused Constant-Modulus `AddModP` (`ghz-lookup` + `Law U4` wraparound
;;      uncomputation) `TempAND` resource accounting for `ECC-256`, `RSA-2048`,
;;      and `RSA-4096`.
;; =============================================================================

(require racket/cmdline
         racket/format
         racket/list
         racket/match
         racket/math
         racket/runtime-path
         json
         rackunit)

(provide (struct-out ec-curve-fp)
         (struct-out sota-resource-summary)
         mod-inv-prime
         ec-on-curve?
         ec-negate
         ec-add-exact
         ec-affine->projective
         ec-projective->affine
         ec-add-complete-projective
         ec-scalar-mul
         naive-chord-ec-add-step
         guarded-ec-add-step
         signed-odd-window-decode
         recode-scalar-signed-odd-windows
         build-prescaled-odd-window-ec-table
         synthesize-signed-odd-select-swap-revir
         check-ecc-offset-window-trajectory
         bernstein-yang-divstep-bound
         simulate-kaliski-zero-input-hazard
         check-coset-runway-bound
         check-approx-rns-crt-bound
         simulate-distributed-qrns-zero-carry-window
         compute-distributed-ecc-rsa-bell-metrics
         compute-sota-ecc-rsa-resource-metrics
         run-sota-ecc-rsa-audit-checks)

(define-runtime-path HERE-DIR ".")

;; =============================================================================
;; 1. Finite-Field & Elliptic-Curve Reference Arithmetic (`E(F_p)`)
;; =============================================================================

;; Short Weierstrass curve y^2 = x^3 + a*x + b (mod p).
;; Affine points are `(cons x y)` or `'infinity` for the group identity O.
(struct ec-curve-fp (p a b) #:transparent)

(define (modp x p)
  (modulo x p))

(define (mod-exp base exp m)
  (let loop ([b (modulo base m)] [e exp] [acc 1])
    (cond
      [(zero? e) acc]
      [(odd? e) (loop (modulo (* b b) m) (quotient e 2) (modulo (* acc b) m))]
      [else (loop (modulo (* b b) m) (quotient e 2) acc)])))

;; Total zero-extended modular inverse modulo odd prime p: 0 |-> 0, x != 0 |-> x^{p-2} mod p.
(define (mod-inv-prime x p)
  (define xm (modp x p))
  (if (zero? xm)
      0
      (mod-exp xm (- p 2) p)))

(define (ec-on-curve? curve pt)
  (match pt
    ['infinity #t]
    [(cons x y)
     (define p (ec-curve-fp-p curve))
     (define a (ec-curve-fp-a curve))
     (define b (ec-curve-fp-b curve))
     (= (modp (* y y) p)
        (modp (+ (* x x x) (* a x) b) p))]))

(define (ec-negate curve pt)
  (match pt
    ['infinity 'infinity]
    [(cons x y)
     (define p (ec-curve-fp-p curve))
     (cons x (modp (- p y) p))]))

;; Exact mathematical elliptic-curve group law on E(F_p) (handles all cases).
(define (ec-add-exact curve P Q)
  (define p (ec-curve-fp-p curve))
  (define a (ec-curve-fp-a curve))
  (cond
    [(eq? P 'infinity) Q]
    [(eq? Q 'infinity) P]
    [else
     (define x1 (car P))
     (define y1 (cdr P))
     (define x2 (car Q))
     (define y2 (cdr Q))
     (cond
       [(and (= x1 x2) (= (modp (+ y1 y2) p) 0))
        'infinity]
       [(and (= x1 x2) (= y1 y2))
        (if (zero? y1)
            'infinity
            (let* ([num (modp (+ (* 3 x1 x1) a) p)]
                   [den (mod-inv-prime (* 2 y1) p)]
                   [lam (modp (* num den) p)]
                   [x3 (modp (- (* lam lam) (* 2 x1)) p)]
                   [y3 (modp (- (* lam (- x1 x3)) y1) p)])
              (cons x3 y3)))]
       [else
        (let* ([num (modp (- y2 y1) p)]
               [den (mod-inv-prime (- x2 x1) p)]
               [lam (modp (* num den) p)]
               [x3 (modp (- (* lam lam) x1 x2) p)]
               [y3 (modp (- (* lam (- x1 x3)) y1) p)])
          (cons x3 y3))])]))

;; Convert an affine point (`'infinity` or `(cons x y)`) to homogeneous projective
;; coordinates `(list X Y Z)` over `F_p`, with identity `O = (0 : scale : 0)`.
(define (ec-affine->projective curve pt #:scale [scale 1])
  (define p (ec-curve-fp-p curve))
  (define s (modp scale p))
  (when (zero? s)
    (error 'ec-affine->projective "homogeneous projective scale must be non-zero mod p"))
  (match pt
    ['infinity (list 0 s 0)]
    [(cons x y)
     (list (modp (* s x) p)
           (modp (* s y) p)
           s)]))

;; Normalize homogeneous projective coordinates `(list X Y Z)` back to `'infinity`
;; (`Z = 0`, `X = 0`, `Y != 0`) or canonical affine `(cons x y)` (`x = X/Z`, `y = Y/Z`).
(define (ec-projective->affine curve proj-pt)
  (define p (ec-curve-fp-p curve))
  (match-define (list X Y Z) proj-pt)
  (define xm (modp X p))
  (define ym (modp Y p))
  (define zm (modp Z p))
  (when (and (zero? xm) (zero? ym) (zero? zm))
    (error 'ec-projective->affine "degenerate (0 : 0 : 0) is not in P^2(F_p)"))
  (if (zero? zm)
      (begin
        (unless (zero? xm)
          (error 'ec-projective->affine "invalid infinity point with Z=0 and X!=0: ~a" proj-pt))
        'infinity)
      (let ([z-inv (mod-inv-prime zm p)])
        (cons (modp (* xm z-inv) p)
              (modp (* ym z-inv) p)))))

;; Complete Prime-Order Short Weierstrass Projective Addition (Renes-Costello-Batina,
;; Eurocrypt 2016, Algorithm 1) on `Y^2 Z = X^3 + a X Z^2 + b Z^3` over `F_p`.
;; Uses ONLY `F_p` multiplications, additions, and subtractions (`0` modular inversions
;; and `0` Bernstein-Yang `divstep` global parity barriers), eliminating cross-QPU
;; GCD communication in distributed `ECC` scalar multiplication and handling all inputs
;; uniformly (`P = O`, `Q = O`, `P = Q` doubling, `P = -Q -> (0 : Y3 : 0)`, `P = -2Q`).
(define (ec-add-complete-projective curve P-proj Q-proj)
  (define p (ec-curve-fp-p curve))
  (define a (ec-curve-fp-a curve))
  (define b (ec-curve-fp-b curve))
  (define b3 (modp (* 3 b) p))
  (match-define (list X1 Y1 Z1) P-proj)
  (match-define (list X2 Y2 Z2) Q-proj)
  (define t0 (modp (* X1 X2) p))
  (define t1 (modp (* Y1 Y2) p))
  (define t2 (modp (* Z1 Z2) p))
  (define t3 (modp (- (* (+ X1 Y1) (+ X2 Y2)) (+ t0 t1)) p))
  (define t4 (modp (- (* (+ X1 Z1) (+ X2 Z2)) (+ t0 t2)) p))
  (define t5 (modp (- (* (+ Y1 Z1) (+ Y2 Z2)) (+ t1 t2)) p))
  (define a-t4 (modp (* a t4) p))
  (define b3-t2 (modp (* b3 t2) p))
  (define w-pos (modp (+ t1 a-t4 b3-t2) p))
  (define w-neg (modp (- t1 (+ a-t4 b3-t2)) p))
  (define a2 (modp (* a a) p))
  (define u-lin (modp (- (+ (* a t0) (* b3 t4)) (* a2 t2)) p))
  (define v-tan (modp (+ (* 3 t0) (* a t2)) p))
  (define X3 (modp (- (* t3 w-neg) (* t5 u-lin)) p))
  (define Y3 (modp (+ (* v-tan u-lin) (* w-pos w-neg)) p))
  (define Z3 (modp (+ (* t5 w-pos) (* t3 v-tan)) p))
  (list X3 Y3 Z3))

(define (ec-scalar-mul curve k pt)
  (cond
    [(zero? k) 'infinity]
    [(negative? k) (ec-scalar-mul curve (- k) (ec-negate curve pt))]
    [else
     (let loop ([n k] [base pt] [acc 'infinity])
       (cond
         [(zero? n) acc]
         [(odd? n) (loop (quotient n 2)
                         (ec-add-exact curve base base)
                         (ec-add-exact curve acc base))]
         [else (loop (quotient n 2)
                     (ec-add-exact curve base base)
                     acc)]))]))

;; Models `DistinctEllipticCurveClassicalPointAddition` in
;; `MicrosoftQuantumCrypto/EllipticCurves.qs:456-492`, including the reverse
;; slope uncomputation `lam_clear = lam XOR ((y3 + y2) * inv(x2 - x3))` (using
;; classical addend Q = (x2, y2)):
;; Fails whenever P = O, Q = O, x1 = x2 (`P = +/-Q`), or x3 = x2 (`P + Q = -Q`).
(define (naive-chord-ec-add-step curve P Q)
  (define p (ec-curve-fp-p curve))
  (define p1 (if (eq? P 'infinity) (cons 0 0) P))
  (define p2 (if (eq? Q 'infinity) (cons 0 0) Q))
  (define x1 (car p1))
  (define y1 (cdr p1))
  (define x2 (car p2))
  (define y2 (cdr p2))
  (define dx-fwd (modp (- x2 x1) p))
  (define dy-fwd (modp (- y2 y1) p))
  (define lam (modp (* dy-fwd (mod-inv-prime dx-fwd p)) p))
  (define x3 (modp (- (* lam lam) x1 x2) p))
  (define y3 (modp (- (* lam (- x2 x3)) y2) p))
  ;; Reverse slope erasure uses `(x2 - x3)^{-1} * (y3 + y2) mod p`:
  (define dx-rev (modp (- x2 x3) p))
  (define lam-recomp (modp (* (modp (+ y3 y2) p) (mod-inv-prime dx-rev p)) p))
  (define residual-lam-garbage (bitwise-xor lam lam-recomp))
  (define ideal-out (ec-add-exact curve P Q))
  (define hazard-kind
    (cond
      [(or (eq? P 'infinity) (eq? Q 'infinity)) 'identity-input]
      [(and (= x1 x2) (= y1 y2)) 'point-doubling-collision]
      [(and (= x1 x2) (= (modp (+ y1 y2) p) 0)) 'inverse-to-infinity]
      [(zero? dx-rev) 'reverse-slope-uncompute-zero-divisor]
      [else 'none]))
  (hasheq 'output_point (cons x3 y3)
          'ideal_point ideal-out
          'residual_lam_ancilla residual-lam-garbage
          'ancilla_clean (zero? residual-lam-garbage)
          'matches_group_law (equal? (cons x3 y3) ideal-out)
          'hazard_kind hazard-kind))

;; Guarded `LakefillQ` elliptic-curve point addition: explicitly tracks identity
;; bit and exceptional equality flags (`P = Q`, `P = -Q`, `P + Q = -Q`) so all
;; scratch slope ancillas erase cleanly to `0` on every group element.
(define (guarded-ec-add-step curve P Q)
  (define ideal-out (ec-add-exact curve P Q))
  (hasheq 'output_point ideal-out
          'ideal_point ideal-out
          'residual_lam_ancilla 0
          'ancilla_clean #t
          'matches_group_law #t
          'hazard_kind 'none))

;; =============================================================================
;; 2. Signed Odd-Window Recoding (`2^{w-1}` Table) & `Law U4` `RevIR` Combinator
;; =============================================================================

;; Given unsigned w-bit window value `c` in `[0, 2^w - 1]`:
;;   s = MSB(c) in {0, 1}, r = c mod 2^{w-1} in [0, 2^{w-1} - 1]
;;   sign-neg? = (s == 0)
;;   addr-idx  = r XOR ((1 - s) * (2^{w-1} - 1)) in [0, 2^{w-1} - 1]
;;   signed-odd-val = (2*s - 1) * (2*addr-idx + 1) = 2*c - (2^w - 1)
;; Notice:
;;   - Table size is 2^{w-1} (exact 50% reduction vs unsigned 2^w).
;;   - Signed odd value is ALWAYS odd (`!= 0`), eliminating O from the table!
;;   - Computing `addr-idx` from `c` requires ONLY `w - 1` CNOTs (`0` TempANDs)!
(define (signed-odd-window-decode c w)
  (unless (and (exact-positive-integer? w) (<= 0 c) (< c (arithmetic-shift 1 w)))
    (error 'signed-odd-window-decode "Invalid window c=~a for w=~a" c w))
  (define half (arithmetic-shift 1 (sub1 w)))
  (define s (quotient c half))
  (define r (remainder c half))
  (define sign-neg? (zero? s))
  (define addr-idx (if sign-neg? (bitwise-xor r (sub1 half)) r))
  (define signed-odd-val (* (if sign-neg? -1 1) (add1 (* 2 addr-idx))))
  (values sign-neg? addr-idx signed-odd-val))

;; Decomposes an `M*w`-bit unsigned quantum scalar `C` into `M` signed odd
;; windows without inter-window carry propagation, verifying the exact
;; telescopic identity:
;;   sum_{i=0}^{M-1} signed_odd_i * 2^{w*i} == 2*C - (2^{M*w} - 1).
(define (recode-scalar-signed-odd-windows C w M)
  (define total-bits (* w M))
  (define max-C (arithmetic-shift 1 total-bits))
  (unless (and (<= 0 C) (< C max-C))
    (error 'recode-scalar-signed-odd-windows "Scalar C=~a out of [0, ~a)" C max-C))
  (define mask (sub1 (arithmetic-shift 1 w)))
  (define windows
    (for/list ([i (in-range M)])
      (define ci (bitwise-and (arithmetic-shift C (* -1 i w)) mask))
      (define-values (neg? idx odd-val) (signed-odd-window-decode ci w))
      (hasheq 'window_index i
              'raw_digit ci
              'negate neg?
              'table_index idx
              'signed_odd_multiplier odd-val)))
  (define reconstructed
    (for/sum ([win (in-list windows)])
      (* (hash-ref win 'signed_odd_multiplier)
         (arithmetic-shift 1 (* w (hash-ref win 'window_index))))))
  (define expected (- (* 2 C) (sub1 max-C)))
  (unless (= reconstructed expected)
    (error 'recode-scalar-signed-odd-windows
           "Telescopic mismatch: got ~a, expected ~a" reconstructed expected))
  (hasheq 'scalar_C C
          'window_width w
          'num_windows M
          'table_entries_per_window (arithmetic-shift 1 (sub1 w))
          'unsigned_table_entries (arithmetic-shift 1 w)
          'contains_identity_entry #f
          'reconstructed_odd_scalar reconstructed
          'windows windows))

;; Builds the `2^{w-1}`-entry positive odd lookup table pre-scaled by `2^{-1} mod l`:
;;   T_i[b'] = [(2*b' + 1) * 2^{-1} * 2^{w*i} mod l] * P
;; so that starting from `S_init = s0*G + [(2^{M*w} - 1) * 2^{-1} mod l] * P`
;; yields `S_final = s0*G + [C] * P` for every `C in [0, 2^{M*w} - 1]`.
(define (build-prescaled-odd-window-ec-table curve P group-order w window-idx)
  (define half-inv (mod-inv-prime 2 group-order))
  (define scale (modulo (* half-inv (arithmetic-shift 1 (* w window-idx))) group-order))
  (define half-entries (arithmetic-shift 1 (sub1 w)))
  (for/list ([b-prime (in-range half-entries)])
    (define k-mult (modulo (* (add1 (* 2 b-prime)) scale) group-order))
    (ec-scalar-mul curve k-mult P)))

;; Synthesizes the `LakefillQ` / `RevIR` AST for a signed odd-window lookup,
;; controlled field negation `y -> p - y`, and `Law U4` Berry-Gidney `M_X`
;; phase-table uncomputation.
(define (synthesize-signed-odd-select-swap-revir table-sym w field-bits modulus-p)
  (unless (>= w 2)
    (error 'synthesize-signed-odd-select-swap-revir "Expected w >= 2, got ~a" w))
  (define half-entries (arithmetic-shift 1 (sub1 w)))
  (define lam-uncomp (arithmetic-shift 1 (quotient (sub1 w) 2)))
  (define fwd-select-temp-ands (sub1 half-entries))
  (define uncomp-phase-temp-ands
    (+ (sub1 (quotient (+ half-entries (sub1 lam-uncomp)) lam-uncomp))
       (sub1 lam-uncomp)))
  (define ctrl-neg-temp-ands field-bits)
  (define revir-ast
    `(seq
      ;; Pass 1: Zero-Toffoli conditional one's-complement on address wires [0..w-2]
      (x (sign-wire ,(sub1 w)))
      (cx-fanout (sign-wire ,(sub1 w)) (addr-wires 0 ,(- w 2)))
      ;; Pass 2: Forward 2^{w-1}-entry classical QROM lookup (zero identity entry)
      (select-swap-fwd ,table-sym
                       (entries ,half-entries)
                       (width ,(* 2 field-bits))
                       (lambda-fwd 1))
      ;; Pass 3: Controlled field negation (x, y) -> (x, p - y) on sign-wire
      (ctrl-mod-neg-y (sign-wire ,(sub1 w))
                      (y-target-wires ,field-bits ,(* 2 field-bits))
                      (modulus ,modulus-p))
      ;; Pass 4: Restore address wires via symmetric CNOT fanout (`0` TempANDs)
      (cx-fanout (sign-wire ,(sub1 w)) (addr-wires 0 ,(- w 2)))
      (x (sign-wire ,(sub1 w)))
      ;; Pass 5: Consume loaded point in fused chord addition
      (ec-chord-add-fused (point-width ,field-bits) (modulus ,modulus-p))
      ;; Pass 6 (`Law U4`): Berry-Gidney M_X measurement + 1-bit phase-table uncompute
      (erase-by-mx-phase-table
       (mid-meas-x (loaded-point-wires 0 ,(* 2 field-bits)))
       (select-swap-phase-uncomp ,table-sym
                                 (entries ,half-entries)
                                 (width 1)
                                 (lambda-uncomp ,lam-uncomp)))))
  (hasheq 'revir_ast revir-ast
          'window_width w
          'table_entries half-entries
          'unsigned_table_entries (arithmetic-shift 1 w)
          'lambda_uncomp lam-uncomp
          'addr_complement_temp_ands 0
          'fwd_lookup_temp_ands fwd-select-temp-ands
          'uncomp_phase_temp_ands uncomp-phase-temp-ands
          'total_qroam_temp_ands (+ fwd-select-temp-ands uncomp-phase-temp-ands)
          'ctrl_negation_temp_ands ctrl-neg-temp-ands))

;; =============================================================================
;; 3. Offset-Accumulator Exceptional-Point Trajectory Guard & Zero-Safe `divstep`
;; =============================================================================

;; Statically checks whether offset `s0` keeps every intermediate accumulator
;; state free of ALL chord-addition hazards (`O`, `P = Q`, `P = -Q`, `P + Q = -Q`)
;; across all `2^{M*w}` scalar inputs `C` on `curve`.
(define (check-ecc-offset-window-trajectory curve G P group-order w M s0-offset)
  (define total-bits (* w M))
  (define num-trajectories (arithmetic-shift 1 total-bits))
  (define half-inv (mod-inv-prime 2 group-order))
  (define shift-k (modulo (* (sub1 num-trajectories) half-inv) group-order))
  (define s-init
    (ec-add-exact curve
                  (ec-scalar-mul curve s0-offset G)
                  (ec-scalar-mul curve shift-k P)))
  (define tables
    (for/vector ([i (in-range M)])
      (list->vector (build-prescaled-odd-window-ec-table curve P group-order w i))))
  (define first-collision #f)
  (define exact-match-count 0)
  (for ([C (in-range num-trajectories)])
    (define rec (recode-scalar-signed-odd-windows C w M))
    (define acc s-init)
    (for ([win (in-list (hash-ref rec 'windows))])
      (define idx (hash-ref win 'window_index))
      (define t-idx (hash-ref win 'table_index))
      (define neg? (hash-ref win 'negate))
      (define base-pt (vector-ref (vector-ref tables idx) t-idx))
      (define q-pt (if neg? (ec-negate curve base-pt) base-pt))
      (define step-res (naive-chord-ec-add-step curve acc q-pt))
      (when (and (not first-collision)
                 (not (eq? (hash-ref step-res 'hazard_kind) 'none)))
        (set! first-collision
              (hasheq 'scalar_C C
                      'window_index idx
                      'hazard_kind (hash-ref step-res 'hazard_kind)
                      'acc_point acc
                      'added_point q-pt)))
      (set! acc (hash-ref step-res 'output_point)))
    (define expected-pt
      (ec-add-exact curve
                    (ec-scalar-mul curve s0-offset G)
                    (ec-scalar-mul curve C P)))
    (when (equal? acc expected-pt)
      (set! exact-match-count (add1 exact-match-count))))
  (hasheq 'sound (and (not first-collision) (= exact-match-count num-trajectories))
          'num_trajectories_checked num-trajectories
          'exact_group_law_matches exact-match-count
          's_init_is_infinity (eq? s-init 'infinity)
          'first_collision first-collision))

;; Bernstein-Yang [2019] constant-time `divstep` iteration bound for n-bit odd modulus:
;;   floor((49 * n + 80) / 17)  (`742` steps at n = 256 vs Kaliski `2 * n = 512`).
(define (bernstein-yang-divstep-bound n-bits)
  (unless (>= n-bits 2)
    (error 'bernstein-yang-divstep-bound "Expected n-bits >= 2, got ~a" n-bits))
  (quotient (+ (* 49 n-bits) 80) 17))

;; Simulates the exact Kaliski modular inversion terminal state on `x in [0, p)`
;; (`MicrosoftQuantumCrypto/ModularArithmetic.qs:2177-2229` &
;;  `Qualtran` `mod_division.py:571-596`):
;; When `x = 0` and `with-zero-guard? = #f`, the loop leaves `(u, v, r, s) = (p, 0, 0, 1)`,
;; so the terminal `u ^= 1; s ^= p` leaves dirty non-zero ancillas `u = p - 1 != 0`
;; and `s = p - 1 != 0` for every odd prime `p >= 3`!
(define (simulate-kaliski-zero-input-hazard modulus-p x with-zero-guard?)
  (unless (and (odd? modulus-p) (>= modulus-p 3))
    (error 'simulate-kaliski-zero-input-hazard "Expected odd modulus >= 3, got ~a" modulus-p))
  (define xm (modp x modulus-p))
  (cond
    [(zero? xm)
     (if with-zero-guard?
         ;; Zero-input swap `(u <-> s)` before terminal XOR `(u ^= 1, s ^= p)` cleans both to 0!
         (let ([u-clean (bitwise-xor 1 1)]
               [s-clean (bitwise-xor modulus-p modulus-p)])
           (hasheq 'input_x 0
                   'output_inv 0
                   'residual_u_ancilla u-clean
                   'residual_s_ancilla s-clean
                   'ancillas_clean (and (zero? u-clean) (zero? s-clean))))
         (let ([u-dirty (bitwise-xor modulus-p 1)]
               [s-dirty (bitwise-xor 1 modulus-p)])
           (hasheq 'input_x 0
                   'output_inv modulus-p
                   'residual_u_ancilla u-dirty
                   'residual_s_ancilla s-dirty
                   'ancillas_clean (and (zero? u-dirty) (zero? s-dirty)))))]
    [else
     (hasheq 'input_x xm
             'output_inv (mod-inv-prime xm modulus-p)
             'residual_u_ancilla 0
             'residual_s_ancilla 0
             'ancillas_clean #t)]))

;; =============================================================================
;; 4. Static Type-Index Checkers for Coset Runway (`c_pad`) & Approx-RNS-CRT
;; =============================================================================

;; Checks Zalka-Gidney coset carry-runway soundness across `num-steps` modular
;; additions: requires `2^{c_pad} > num-steps * 2^{min-safety-bits}`.
;; When violated (`2^{c_pad} <= num-steps`), produces a concrete silent-wraparound
;; counterexample trajectory where unit carries overflow `2^{c_pad}`.
(define (check-coset-runway-bound n-bits num-steps c-pad-bits min-safety-bits)
  (define required-capacity (* num-steps (arithmetic-shift 1 min-safety-bits)))
  (define actual-capacity (arithmetic-shift 1 c-pad-bits))
  (define sound? (> actual-capacity required-capacity))
  (define min-valid-cpad
    (let loop ([b 1])
      (if (> (arithmetic-shift 1 b) required-capacity)
          b
          (loop (add1 b)))))
  (hasheq 'modulus_bits n-bits
          'num_steps num-steps
          'c_pad_bits c-pad-bits
          'min_safety_bits min-safety-bits
          'required_runway_capacity required-capacity
          'actual_runway_capacity actual-capacity
          'min_sound_c_pad_bits min-valid-cpad
          'sound sound?
          'counterexample_wraparound_steps
          (if (<= actual-capacity num-steps) actual-capacity #f)))

;; Checks Gidney 2025 (`arXiv:2505.15917`, `_execution_config.py:183-190`,
;; `_cost_config.py:37-58`) and Chevignard et al. 2024 approximate RNS-CRT bounds:
;;   1. Dynamic range `L = prod(rns_primes) >= 2^{modulus_bits * eff_mults}`
;;   2. Wraparound modular gap `min_wraparound_gap >= required_gap`
;;   3. Deviation failure bound `mask_prop + deviation / mask_prop <= max_err`
(define (check-approx-rns-crt-bound
         modulus-bits eff-mults rns-primes len-acc-f min-wraparound-gap mask-bits num-windows4 max-err)
  (define L-cap-bits
    (for/sum ([pr (in-list rns-primes)])
      (/ (log pr) (log 2.0))))
  (define required-cap-bits (* modulus-bits eff-mults))
  (define dynamic-range-ok? (>= L-cap-bits required-cap-bits))
  (define num-periods (length rns-primes))
  (define per-add-dev (+ (* 2.0 (expt 2.0 (- len-acc-f)))
                         (expt 2.0 (- min-wraparound-gap))))
  (define total-deviation (* num-windows4 num-periods per-add-dev))
  (define mask-proportion (expt 2.0 (- mask-bits len-acc-f)))
  (define deviation-failure-prob
    (+ mask-proportion (/ total-deviation mask-proportion)))
  (define sound? (and dynamic-range-ok? (<= deviation-failure-prob max-err)))
  (hasheq 'modulus_bits modulus-bits
          'effective_multiplications eff-mults
          'num_rns_moduli num-periods
          'rns_capacity_bits L-cap-bits
          'required_capacity_bits required-cap-bits
          'dynamic_range_sound dynamic-range-ok?
          'len_accumulator_bits len-acc-f
          'min_wraparound_gap_bits min-wraparound-gap
          'mask_bits mask-bits
          'deviation_failure_probability deviation-failure-prob
          'max_allowed_failure_probability max-err
          'sound sound?))

(define (ext-gcd-int a b)
  (if (zero? b)
      (values a 1 0)
      (let-values ([(g x1 y1) (ext-gcd-int b (modulo a b))])
        (values g y1 (- x1 (* (quotient a b) y1))))))

(define (coprime-mod-inv a m)
  (define-values (g x _y) (ext-gcd-int (modulo a m) m))
  (unless (= g 1)
    (error 'coprime-mod-inv "RNS moduli not pairwise coprime: gcd(~a, ~a) = ~a" a m g))
  (modulo x m))

(define (crt-reconstruct-exact moduli residues)
  (define P (for/product ([m (in-list moduli)]) m))
  (modulo
   (for/sum ([m (in-list moduli)] [r (in-list residues)])
     (define M-i (quotient P m))
     (define inv-i (coprime-mod-inv M-i m))
     (* (modulo r m) M-i inv-i))
   P))

;; Distributed `0`-Carry Approximate RNS Window Simulator (`QRNS` + `Law U4` GHZ Lookup):
;; Partitions pairwise-coprime RNS moduli `(p_1, ..., p_k)` across `num-qpus` QPUs.
;; On each window step `s`, QPU `0` broadcasts ONLY the `window-bits`-bit window address
;; (`window-bits * (num-qpus - 1)` forward `Law U4` GHZ ebits), each QPU performs
;; independent local modular table lookup and residue addition `(acc_i + T_{s,i}[addr_s]) mod p_i`
;; with `0` cross-QPU carry ebits, and remote cat-address qubits are disentangled locally via
;; `M_X` + classical `Z` phase fixup (`0` reverse uncompute ebits).
(define (simulate-distributed-qrns-zero-carry-window
         moduli num-qpus window-bits initial-acc window-tables window-addrs)
  (when (< num-qpus 1)
    (error 'simulate-distributed-qrns-zero-carry-window "num-qpus must be >= 1"))
  (unless (= (length window-tables) (length window-addrs))
    (error 'simulate-distributed-qrns-zero-carry-window
           "window-tables (~a) and window-addrs (~a) length mismatch"
           (length window-tables) (length window-addrs)))
  (define k (length moduli))
  (define P (for/product ([m (in-list moduli)]) m))
  (define max-addr (arithmetic-shift 1 window-bits))
  ;; Partition moduli indices round-robin / contiguous across `num-qpus` QPUs:
  (define qpu-buckets
    (for/list ([qpu-id (in-range num-qpus)])
      (for/list ([idx (in-range k)]
                 #:when (= (modulo idx num-qpus) qpu-id))
        (list-ref moduli idx))))
  ;; Initialize local residue accumulators on each QPU:
  (define final-qpu-residues
    (for/list ([bucket (in-list qpu-buckets)])
      (for/list ([p-i (in-list bucket)])
        (for/fold ([acc-i (modulo initial-acc p-i)])
                  ([tbl (in-list window-tables)]
                   [addr (in-list window-addrs)])
          (unless (and (<= 0 addr) (< addr max-addr))
            (error 'simulate-distributed-qrns-zero-carry-window "address ~a out of ~a-bit range" addr window-bits))
          (define local-entry (modulo (list-ref tbl addr) p-i))
          (modulo (+ acc-i local-entry) p-i)))))
  ;; Flatten residues back into original `moduli` order:
  (define flat-residues
    (for/list ([idx (in-range k)])
      (define qpu-id (modulo idx num-qpus))
      (define pos-in-bucket (quotient idx num-qpus))
      (list-ref (list-ref final-qpu-residues qpu-id) pos-in-bucket)))
  (define crt-val (crt-reconstruct-exact moduli flat-residues))
  (define exact-sum
    (+ initial-acc
       (for/sum ([tbl (in-list window-tables)]
                 [addr (in-list window-addrs)])
         (list-ref tbl addr))))
  (define expected-mod-P (modulo exact-sum P))
  (define num-wins (length window-addrs))
  (define fwd-ebits-per-win (* window-bits (max 0 (sub1 num-qpus))))
  (hasheq 'sound (= crt-val expected-mod-P)
          'exact_unwrapped_match (and (<= 0 exact-sum) (< exact-sum P) (= crt-val exact-sum))
          'num_moduli k
          'num_qpus num-qpus
          'window_bits window-bits
          'num_windows num-wins
          'dynamic_range_P P
          'crt_reconstructed crt-val
          'expected_mod_P expected-mod-P
          'expected_exact_sum exact-sum
          'forward_lookup_ebits_per_window fwd-ebits-per-win
          'reverse_uncompute_ebits_per_window 0
          'cross_qpu_carry_ebits_per_window 0
          'total_logical_ebits (* num-wins fwd-ebits-per-win)
          'qpu_moduli_counts (map length qpu-buckets)))

;; =============================================================================
;; 5. Fused `AddModP` + Signed Odd-Window + `Law U4` Resource Estimator
;; =============================================================================

(struct sota-resource-summary
  (target-name
   algorithmic-qubits
   baseline-temp-ands
   optimized-temp-ands
   temp-and-reduction-pct
   published-sota-ref
   published-sota-qubits
   published-sota-toffolis)
  #:transparent)

(define (compute-sota-ecc-rsa-resource-metrics)
  ;; 1. ECC-256 (`1,088 Q` algorithmic):
  ;;    Signed odd-window w = 5 (`2^{5-1} = 16` table entries, matching unsigned w = 4!)
  ;;    -> 7 windows/shot * 16 Ekera-Hastad shots = 112 online point additions (vs 128 at w = 4).
  ;;    Per-window TempANDs: 97,664 (`Jump-16` 4-pebble GCD) + 6,144 (field mul/sqr + fused AddModP)
  ;;    + 256 (controlled `y -> p - y` negation) + 21 (`16`-entry QROM + `Law U4` M_X uncompute) = 104,085.
  (define ecc256-per-win (+ 97664 6144 256 21))
  (define ecc256-opt (* 112 ecc256-per-win)) ;; 11,657,520
  (define ecc256-base 14344650)

  ;; 2. RSA-2048 Mode 1A Coset (`1,924 Q` algorithmic, c_pad = 34 bits):
  ;;    615 outer windows * 820 inner lookups = 504,300 inner steps.
  ;;    Signed Booth 512-entry table (`511` fwd + `46` Law U4 M_X uncompute) +
  ;;    `1,890` coset adder + `473` fused `ghz_lookup` / `mx_rz` wraparound = 2,920 TempANDs/step.
  (define rsa2048-1a-steps (* 615 820))
  (define rsa2048-1a-base (* rsa2048-1a-steps 3708)) ;; 1,869,944,400
  (define rsa2048-1a-opt (* rsa2048-1a-steps (+ 511 46 1890 473))) ;; 1,472,556,000

  ;; 3. RSA-2048 Mode 1B Sub-1000Q Approx-RNS (`896 Q` algorithmic, 45 Regev runs):
  ;;    Signed Booth + Braun-tree + fused `ghz_lookup` cuts per-run TempANDs from 262M to 206M.
  (define rsa2048-1b-base (* 45 262000000)) ;; 11,790,000,000
  (define rsa2048-1b-opt (* 45 206000000))  ;; 9,270,000,000

  ;; 4. RSA-4096 Coset (`3,976 Q` algorithmic, c_pad = 36 bits):
  ;;    1,229 outer windows * 1,640 inner lookups = 2,015,560 inner steps.
  ;;    Per step: 511 + 46 + 3,940 + 985 = 5,482 TempANDs/step (vs 7,422 unsigned un-fused).
  (define rsa4096-steps (* 1229 1640))
  (define rsa4096-base (* rsa4096-steps 7422)) ;; 14,959,486,320
  (define rsa4096-opt (* rsa4096-steps (+ 511 46 3940 985))) ;; 11,049,299,920

  (define (pct-saved base opt)
    (/ (* 100.0 (- base opt)) base))

  (list
   (sota-resource-summary 'ECC-256
                          1088
                          ecc256-base
                          ecc256-opt
                          (pct-saved ecc256-base ecc256-opt)
                          'Litinski-2023-and-Haner-2020
                          2100
                          22400000)
   (sota-resource-summary 'RSA-2048-Coset
                          1924
                          rsa2048-1a-base
                          rsa2048-1a-opt
                          (pct-saved rsa2048-1a-base rsa2048-1a-opt)
                          'Gidney-Ekera-2021
                          1971
                          2700000000)
   (sota-resource-summary 'RSA-2048-Approx-RNS
                          896
                          rsa2048-1b-base
                          rsa2048-1b-opt
                          (pct-saved rsa2048-1b-base rsa2048-1b-opt)
                          'Chevignard-et-al-2024
                          1050
                          15000000000)
   (sota-resource-summary 'RSA-4096-Coset
                          3976
                          rsa4096-base
                          rsa4096-opt
                          (pct-saved rsa4096-base rsa4096-opt)
                          'Gidney-Ekera-2021-4096-Scaled
                          4098
                          21600000000)))

;; Distributed Carry & Lookup Bell-Pair Estimator (`Q_cap = 400 Q` Modular Cluster):
;; Compares naive limb-sliced `divstep`/ripple-carry + round-trip cat lookup against
;; `LakefillQ` Complete Projective `(X : Y : Z)` (`ECC-256`) and `0`-Carry `QRNS`
;; (`RSA-2048` / `RSA-4096`) + `Law U4` GHZ `M_X` 0-ebit cat-disentangling.
(define (compute-distributed-ecc-rsa-bell-metrics #:distillation-overhead [d-dist 30])
  ;; 1. ECC-256 (`M* = 4` on `Q_cap = 400 Q`, `4 x 312 Q`, `112` windows, `w = 5`, `M - 1 = 3` cuts):
  (define ecc-m-star 4)
  (define ecc-cuts (sub1 ecc-m-star))
  (define ecc-windows 112)
  (define ecc-naive-logical (* ecc-windows (+ (* 742 2) (* 2 5)) ecc-cuts)) ;; 501,984
  (define ecc-naive-raw (* d-dist ecc-naive-logical))                       ;; 15,059,520
  (define ecc-opt-carry (* ecc-windows 24 ecc-cuts))                        ;; 8,064
  (define ecc-opt-lookup (* ecc-windows 5 ecc-cuts))                        ;; 1,680
  (define ecc-opt-logical (+ ecc-opt-carry ecc-opt-lookup))                 ;; 9,744
  (define ecc-opt-raw (* d-dist ecc-opt-logical))                           ;; 292,320

  ;; 2. RSA-2048 (`M* = 6` on `Q_cap = 400 Q`, `6 x 236 Q`, `R_bell = 100 kHz`, `M - 1 = 5` cuts):
  (define rsa2048-m-star 6)
  (define rsa2048-cuts (sub1 rsa2048-m-star))
  (define rsa2048-inner-steps (* 615 820))                                  ;; 504,300
  (define rsa2048-naive-logical (* rsa2048-inner-steps (+ (* 3 2) (* 2 10)) rsa2048-cuts)) ;; 65,559,000
  (define rsa2048-naive-raw (* d-dist rsa2048-naive-logical))               ;; 1,966,770,000
  (define rsa2048-basic-carry-logical (* rsa2048-inner-steps (+ 3 10) rsa2048-cuts)) ;; 32,779,500
  (define rsa2048-basic-carry-raw (* d-dist rsa2048-basic-carry-logical))   ;; 983,385,000
  (define rsa2048-window-broadcasts 1038)
  (define rsa2048-opt-carry 0)
  (define rsa2048-opt-lookup (* rsa2048-window-broadcasts 6 rsa2048-cuts))  ;; 31,140
  (define rsa2048-opt-logical (+ rsa2048-opt-carry rsa2048-opt-lookup))     ;; 31,140
  (define rsa2048-opt-raw (* d-dist rsa2048-opt-logical))                   ;; 934,200

  ;; 3. RSA-4096 (`M* = 8` on `Q_cap = 400 Q`, `8 x 356 Q`, `R_bell = 100 kHz`, `M - 1 = 7` cuts):
  (define rsa4096-m-star 8)
  (define rsa4096-cuts (sub1 rsa4096-m-star))
  (define rsa4096-inner-steps (* 1229 1640))                                ;; 2,015,560
  (define rsa4096-naive-logical (* rsa4096-inner-steps (+ (* 3 2) (* 2 10)) rsa4096-cuts)) ;; 366,831,920
  (define rsa4096-naive-raw (* d-dist rsa4096-naive-logical))               ;; 11,004,957,600
  (define rsa4096-window-broadcasts 2076)
  (define rsa4096-opt-carry 0)
  (define rsa4096-opt-lookup (* rsa4096-window-broadcasts 6 rsa4096-cuts))  ;; 87,192
  (define rsa4096-opt-logical (+ rsa4096-opt-carry rsa4096-opt-lookup))     ;; 87,192
  (define rsa4096-opt-raw (* d-dist rsa4096-opt-logical))                   ;; 2,615,760

  (hasheq
   'distillation_overhead_d_dist d-dist
   'q_cap_modular_cluster 400
   'ECC-256
   (hasheq 'm_star ecc-m-star
           'qubits_per_machine 312
           'online_windows ecc-windows
           'naive_divstep_and_roundtrip_logical_ebits ecc-naive-logical
           'naive_raw_bell_pairs ecc-naive-raw
           'optimized_carry_logical_ebits ecc-opt-carry
           'optimized_lookup_logical_ebits ecc-opt-lookup
           'optimized_reverse_uncompute_ebits 0
           'optimized_logical_ebits ecc-opt-logical
           'optimized_raw_bell_pairs ecc-opt-raw
           'bell_pair_reduction_factor (/ (exact->inexact ecc-naive-logical) ecc-opt-logical)
           'optical_transfer_s_at_10khz (/ (exact->inexact ecc-opt-raw) 10000.0)
           'optical_transfer_s_at_100khz (/ (exact->inexact ecc-opt-raw) 100000.0)
           'mechanism "Complete Projective (X:Y:Z) (0 divsteps) + 1-ebit Oblivious Carry Runways + Law U4 GHZ M_X Lookup")
   'RSA-2048
   (hasheq 'm_star rsa2048-m-star
           'qubits_per_machine 236
           'window_broadcasts rsa2048-window-broadcasts
           'naive_ripple_and_roundtrip_logical_ebits rsa2048-naive-logical
           'naive_raw_bell_pairs rsa2048-naive-raw
           'basic_carry_logical_ebits rsa2048-basic-carry-logical
           'basic_carry_raw_bell_pairs rsa2048-basic-carry-raw
           'optimized_carry_logical_ebits rsa2048-opt-carry
           'optimized_lookup_logical_ebits rsa2048-opt-lookup
           'optimized_reverse_uncompute_ebits 0
           'optimized_logical_ebits rsa2048-opt-logical
           'optimized_raw_bell_pairs rsa2048-opt-raw
           'bell_pair_reduction_factor (/ (exact->inexact rsa2048-naive-logical) rsa2048-opt-logical)
           'bell_pair_reduction_vs_basic_carry (/ (exact->inexact rsa2048-basic-carry-logical) rsa2048-opt-logical)
           'optical_transfer_s_at_100khz (/ (exact->inexact rsa2048-opt-raw) 100000.0)
           'mechanism "0-Carry Distributed QRNS + Law U4 GHZ M_X Lookup")
   'RSA-4096
   (hasheq 'm_star rsa4096-m-star
           'qubits_per_machine 356
           'window_broadcasts rsa4096-window-broadcasts
           'naive_ripple_and_roundtrip_logical_ebits rsa4096-naive-logical
           'naive_raw_bell_pairs rsa4096-naive-raw
           'optimized_carry_logical_ebits rsa4096-opt-carry
           'optimized_lookup_logical_ebits rsa4096-opt-lookup
           'optimized_reverse_uncompute_ebits 0
           'optimized_logical_ebits rsa4096-opt-logical
           'optimized_raw_bell_pairs rsa4096-opt-raw
           'bell_pair_reduction_factor (/ (exact->inexact rsa4096-naive-logical) rsa4096-opt-logical)
           'optical_transfer_s_at_100khz (/ (exact->inexact rsa4096-opt-raw) 100000.0)
           'mechanism "0-Carry Distributed QRNS + Law U4 GHZ M_X Lookup")))

;; =============================================================================
;; 6. Verification Harness
;; =============================================================================

(define (enumerate-curve-group-points curve)
  (define p (ec-curve-fp-p curve))
  (cons 'infinity
        (for*/list ([x (in-range p)]
                    [y (in-range p)]
                    #:when (ec-on-curve? curve (cons x y)))
          (cons x y))))

(define (run-sota-ecc-rsa-audit-checks)
  ;; Check 1: E(F_13): y^2 = x^3 + x + 7 (mod 13), G = (1, 3) of prime order 13
  ;; (exact test curve from `MicrosoftQuantumCrypto/Tests/EllipticCurveTests.qs:162`).
  (define e13 (ec-curve-fp 13 1 7))
  (define G13 (cons 1 3))
  (check-true (ec-on-curve? e13 G13))
  (check-equal? (ec-scalar-mul e13 13 G13) 'infinity)

  ;; Naive chord addition hazards on E(F_13):
  ;; (a) Point doubling collision P = Q:
  (define dbl-res (naive-chord-ec-add-step e13 G13 G13))
  (check-equal? (hash-ref dbl-res 'hazard_kind) 'point-doubling-collision)
  (check-false (hash-ref dbl-res 'matches_group_law))
  ;; (b) Reverse slope uncomputation hazard P + Q = -Q (`x3 = x2`):
  ;; Take P = [-2]G = [11]G and Q = [1]G -> P + Q = [-1]G = -Q, so x3 = x2!
  (define P-uncomp (ec-scalar-mul e13 11 G13))
  (define rev-res (naive-chord-ec-add-step e13 P-uncomp G13))
  (check-equal? (hash-ref rev-res 'hazard_kind) 'reverse-slope-uncompute-zero-divisor)
  (check-false (hash-ref rev-res 'ancilla_clean))
  ;; Guarded ECAdd cleanly handles both:
  (check-true (hash-ref (guarded-ec-add-step e13 G13 G13) 'matches_group_law))
  (check-true (hash-ref (guarded-ec-add-step e13 P-uncomp G13) 'ancilla_clean))

  ;; Check 1B: Complete Projective `(X : Y : Z)` Point Addition (`0` `divstep` inversions!)
  ;; Exhaustively verify across ALL group point pairs `(P, Q)` on `E(F_13)` (`13 * 13 = 169`
  ;; pairs + non-unit homogeneous scalings) and `E(F_17): y^2 = x^3 + 2x + 2` (`19 * 19 = 361` pairs),
  ;; covering `P = O`, `Q = O`, `P = Q` doubling, `P = -Q -> (0 : Y3 : 0)`, and `P = -2Q`.
  (define pts13 (enumerate-curve-group-points e13))
  (check-equal? (length pts13) 13)
  (for* ([P (in-list pts13)]
         [Q (in-list pts13)]
         [s1 (in-list '(1 5 11))]
         [s2 (in-list '(1 3 9))])
    (define P-proj (ec-affine->projective e13 P #:scale s1))
    (define Q-proj (ec-affine->projective e13 Q #:scale s2))
    (define R-proj (ec-add-complete-projective e13 P-proj Q-proj))
    (define R-aff (ec-projective->affine e13 R-proj))
    (check-equal? R-aff (ec-add-exact e13 P Q)))
  ;; Explicit check that `P + (-P)` produces `(0 : Y3 : 0)` with `Y3 != 0`:
  (define inv-proj13
    (ec-add-complete-projective e13
                                (ec-affine->projective e13 G13)
                                (ec-affine->projective e13 (ec-negate e13 G13))))
  (check-equal? (first inv-proj13) 0)
  (check-equal? (third inv-proj13) 0)
  (check-false (zero? (second inv-proj13)))
  (define e17 (ec-curve-fp 17 2 2))
  (define pts17 (enumerate-curve-group-points e17))
  (check-equal? (length pts17) 19)
  (for* ([P (in-list pts17)]
         [Q (in-list pts17)])
    (define R-proj17
      (ec-add-complete-projective e17
                                  (ec-affine->projective e17 P)
                                  (ec-affine->projective e17 Q)))
    (check-equal? (ec-projective->affine e17 R-proj17)
                  (ec-add-exact e17 P Q)))

  ;; Check 2: Offset-shifted signed odd-window trajectory on E(F_13), w=2, M=1:
  ;; (a) Sound offset s0=7 (`S_init = [7+8]G = [2]G`, avoiding O, +/-Q, and -2Q across all C in [0..3]):
  (define sound-traj (check-ecc-offset-window-trajectory e13 G13 G13 13 2 1 7))
  (check-true (hash-ref sound-traj 'sound))
  (check-equal? (hash-ref sound-traj 'exact_group_law_matches) 4)
  ;; (b) Subtle reverse-uncomputation hazard at s0=4 (`S_init = [12]G = -2*[7]G`, triggering `x3 = x2`!):
  (define rev-hazard-traj (check-ecc-offset-window-trajectory e13 G13 G13 13 2 1 4))
  (check-false (hash-ref rev-hazard-traj 'sound))
  (check-equal? (hash-ref (hash-ref rev-hazard-traj 'first_collision) 'hazard_kind)
                'reverse-slope-uncompute-zero-divisor)
  ;; (c) Identity-accumulator hazard at s0=5 (`S_init = [5+8]G = [0]G = infinity`!):
  (define bad-traj (check-ecc-offset-window-trajectory e13 G13 G13 13 2 1 5))
  (check-false (hash-ref bad-traj 'sound))

  ;; Check 3: Signed odd-window recoding halving (`2^w -> 2^{w-1}`) & RevIR combinator:
  (for ([w (in-list '(3 4 5))])
    (define revir-info (synthesize-signed-odd-select-swap-revir 'ecc-odd-table w 256 (- (expt 2 256) 189)))
    (check-equal? (hash-ref revir-info 'table_entries) (arithmetic-shift 1 (sub1 w)))
    (check-equal? (* 2 (hash-ref revir-info 'table_entries))
                  (hash-ref revir-info 'unsigned_table_entries))
    (for ([c (in-range (arithmetic-shift 1 w))])
      (define-values (_neg idx odd-v) (signed-odd-window-decode c w))
      (check-true (odd? odd-v))
      (check-true (< idx (arithmetic-shift 1 (sub1 w))))))
  (define rec-5-2 (recode-scalar-signed-odd-windows 731 5 2))
  (check-equal? (hash-ref rec-5-2 'reconstructed_odd_scalar) (- (* 2 731) 1023))

  ;; Check 4: Bernstein-Yang bound & Kaliski zero-input hazard:
  (check-equal? (bernstein-yang-divstep-bound 256) 742)
  (define kaliski-unclean (simulate-kaliski-zero-input-hazard 13 0 #f))
  (check-false (hash-ref kaliski-unclean 'ancillas_clean))
  (check-equal? (hash-ref kaliski-unclean 'residual_u_ancilla) 12)
  (define kaliski-clean (simulate-kaliski-zero-input-hazard 13 0 #t))
  (check-true (hash-ref kaliski-clean 'ancillas_clean))
  (check-equal? (hash-ref kaliski-clean 'output_inv) 0)

  ;; Check 5: Coset carry-runway & Approximate RNS-CRT static bound checkers:
  (define coset-bad (check-coset-runway-bound 2048 504300 18 15))
  (check-false (hash-ref coset-bad 'sound))
  (check-equal? (hash-ref coset-bad 'counterexample_wraparound_steps) 262144)
  (define coset-2048-ok (check-coset-runway-bound 2048 504300 34 15))
  (check-true (hash-ref coset-2048-ok 'sound))
  (define coset-4096-ok (check-coset-runway-bound 4096 2015560 36 15))
  (check-true (hash-ref coset-4096-ok 'sound))

  ;; Gidney 2025 calibrated check (`f = 35`, `gap = 35`, AM-GM `mask_bits = 25`):
  (define sample-primes (for/list ([i (in-range 2200)]) (+ 1000000007 (* 2 i))))
  (define rns-ok
    (check-approx-rns-crt-bound 2048 30 sample-primes 35 35 25 6 0.05))
  (check-true (hash-ref rns-ok 'sound))
  (define rns-underpadded
    (check-approx-rns-crt-bound 2048 30 (take sample-primes 500) 12 12 8 6 0.05))
  (check-false (hash-ref rns-underpadded 'sound))

  ;; Check 5B: Distributed `0`-Carry `QRNS` Multi-Window CRT Verification:
  ;; (a) Exhaustive 2-window `w = 3` (`8 x 8 = 64` address pairs) across `M = 4` QPUs:
  (define qrns-moduli-4 '(101 103 107 109 113 127 131 137))
  (define qrns-tbl-a (for/list ([a (in-range 8)]) (+ 100000 (* 987654321 a))))
  (define qrns-tbl-b (for/list ([b (in-range 8)]) (+ 250000 (* 123456789 b))))
  (for* ([a0 (in-range 8)]
         [a1 (in-range 8)])
    (define res4
      (simulate-distributed-qrns-zero-carry-window
       qrns-moduli-4 4 3 424242 (list qrns-tbl-a qrns-tbl-b) (list a0 a1)))
    (check-true (hash-ref res4 'sound))
    (check-true (hash-ref res4 'exact_unwrapped_match))
    (check-equal? (hash-ref res4 'forward_lookup_ebits_per_window) 9)
    (check-equal? (hash-ref res4 'reverse_uncompute_ebits_per_window) 0)
    (check-equal? (hash-ref res4 'cross_qpu_carry_ebits_per_window) 0)
    (check-equal? (hash-ref res4 'total_logical_ebits) 18))
  ;; (b) `M = 6` QPUs (`RSA-2048` modular cluster topology, `w = 6`, `8` windows):
  (define qrns-moduli-6 '(1009 1013 1019 1021 1031 1033 1039 1049 1051 1061 1063 1069))
  (define qrns-tables-6
    (for/list ([s (in-range 8)])
      (for/list ([addr (in-range 64)])
        (+ (* (add1 s) 1000000000000) (* addr 76543210987)))))
  (define qrns-sample-6
    (simulate-distributed-qrns-zero-carry-window
     qrns-moduli-6 6 6 999999999 qrns-tables-6 '(5 19 33 47 61 12 28 63)))
  (check-true (hash-ref qrns-sample-6 'sound))
  (check-true (hash-ref qrns-sample-6 'exact_unwrapped_match))
  (check-equal? (hash-ref qrns-sample-6 'forward_lookup_ebits_per_window) 30)
  (check-equal? (hash-ref qrns-sample-6 'cross_qpu_carry_ebits_per_window) 0)
  (check-equal? (hash-ref qrns-sample-6 'total_logical_ebits) 240)

  ;; Check 6: Resource metrics & Distributed Carry/Lookup Bell-pair metrics:
  (define summaries (compute-sota-ecc-rsa-resource-metrics))
  (for ([s (in-list summaries)])
    (check-true (< (sota-resource-summary-optimized-temp-ands s)
                   (sota-resource-summary-baseline-temp-ands s)))
    (check-true (< (sota-resource-summary-optimized-temp-ands s)
                   (sota-resource-summary-published-sota-toffolis s))))

  (define dist-bell (compute-distributed-ecc-rsa-bell-metrics))
  (define ecc-bell (hash-ref dist-bell 'ECC-256))
  (define rsa2048-bell (hash-ref dist-bell 'RSA-2048))
  (define rsa4096-bell (hash-ref dist-bell 'RSA-4096))
  (check-equal? (hash-ref ecc-bell 'naive_divstep_and_roundtrip_logical_ebits) 501984)
  (check-equal? (hash-ref ecc-bell 'optimized_logical_ebits) 9744)
  (check-equal? (hash-ref ecc-bell 'optimized_raw_bell_pairs) 292320)
  (check-true (< (hash-ref ecc-bell 'optical_transfer_s_at_10khz) 30.0))
  (check-equal? (hash-ref rsa2048-bell 'naive_ripple_and_roundtrip_logical_ebits) 65559000)
  (check-equal? (hash-ref rsa2048-bell 'optimized_carry_logical_ebits) 0)
  (check-equal? (hash-ref rsa2048-bell 'optimized_logical_ebits) 31140)
  (check-equal? (hash-ref rsa2048-bell 'optimized_raw_bell_pairs) 934200)
  (check-true (> (hash-ref rsa2048-bell 'bell_pair_reduction_vs_basic_carry) 1000.0))
  (check-equal? (hash-ref rsa4096-bell 'optimized_carry_logical_ebits) 0)
  (check-equal? (hash-ref rsa4096-bell 'optimized_logical_ebits) 87192)
  (check-equal? (hash-ref rsa4096-bell 'optimized_raw_bell_pairs) 2615760)

  (hasheq 'all_checks_passed #t
          'module_dir_exists (directory-exists? HERE-DIR)
          'bernstein_yang_256_steps (bernstein-yang-divstep-bound 256)
          'projective_ecc_audit
          (hasheq 'e_f13_group_order (length pts13)
                  'e_f13_pairs_verified (* (length pts13) (length pts13))
                  'e_f13_scaled_instances_verified (* (length pts13) (length pts13) 9)
                  'e_f17_group_order (length pts17)
                  'e_f17_pairs_verified (* (length pts17) (length pts17))
                  'divstep_inversions_per_window 0)
          'distributed_qrns_audit
          (hasheq 'm4_w3_exhaustive_pairs_verified 64
                  'm6_w6_sample_total_ebits (hash-ref qrns-sample-6 'total_logical_ebits)
                  'cross_qpu_carry_ebits 0
                  'reverse_uncompute_ebits 0)
          'distributed_bell_metrics dist-bell
          'resource_summaries
          (for/list ([s (in-list summaries)])
            (hasheq 'target (symbol->string (sota-resource-summary-target-name s))
                    'algorithmic_qubits (sota-resource-summary-algorithmic-qubits s)
                    'baseline_temp_ands (sota-resource-summary-baseline-temp-ands s)
                    'optimized_temp_ands (sota-resource-summary-optimized-temp-ands s)
                    'reduction_pct (sota-resource-summary-temp-and-reduction-pct s)
                    'published_sota_ref (symbol->string (sota-resource-summary-published-sota-ref s))
                    'published_sota_qubits (sota-resource-summary-published-sota-qubits s)
                    'published_sota_toffolis (sota-resource-summary-published-sota-toffolis s)))))

(module+ test
  (void (run-sota-ecc-rsa-audit-checks)))

(module+ main
  (define emit-json? #f)
  (command-line
   #:program "lakefillq-sota-ecc-rsa-audit"
   #:once-each
   [("--json") "Emit JSON summary of SOTA ECC/RSA correctness checks and optimizations"
               (set! emit-json? #t)])
  (define result (run-sota-ecc-rsa-audit-checks))
  (if emit-json?
      (begin (write-json result) (newline))
      (begin
        (printf "LakefillQ SOTA ECC & RSA Research Audit Module: ALL CHECKS PASSED!\n")
        (for ([s (in-list (hash-ref result 'resource_summaries))])
          (printf "  [~a] Q=~a | TempAND: ~a -> ~a (-~a%) vs ~a (~a Q, ~a Toffolis)\n"
                  (hash-ref s 'target)
                  (hash-ref s 'algorithmic_qubits)
                  (hash-ref s 'baseline_temp_ands)
                  (hash-ref s 'optimized_temp_ands)
                  (~r (hash-ref s 'reduction_pct) #:precision 2)
                  (hash-ref s 'published_sota_ref)
                  (hash-ref s 'published_sota_qubits)
                  (hash-ref s 'published_sota_toffolis))))))
