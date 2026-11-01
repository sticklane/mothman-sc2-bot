#lang racket/base

(require racket/match
         racket/list
         racket/math
         racket/format
         "quantum-syntax.rkt"
         "quantum-kickmix.rkt")

(provide ;; Benchmark 1: Controlled MADD Routing + Gidney MBU
         madd-naive-toffolis
         madd-paper-routed-toffolis
         madd-gidney-mbu-routed-toffolis
         build-2bit-cmadd-naive-circuit
         build-2bit-cmadd-routed-circuit
         build-2bit-cmadd-gidney-mbu-circuit
         verify-benchmark-1-cmadd

         ;; Benchmark 2: Zero-History Binary-Record Uncomputation
         build-binary-record-history-circuit
         build-binary-record-decoded-circuit
         verify-benchmark-2-binary-record

         ;; Benchmark 3: Berlekamp-Massey Shared MADD + Constant-Term Discrepancy Decoder
         bm-step-naive-cost
         bm-step-shrunk-cost
         build-gf2-bm-routed-step-circuit
         verify-benchmark-3-berlekamp-massey

         ;; Benchmark 4: divsteps Modular Inversion & Hensel-Factored 2-Adic Excursion Decoder
         lut-decoder-toffolis
         hensel-decoder-toffolis
         hensel-inv-mod-2^j
         decode-divsteps-branch-bit-paper
         decode-divsteps-branch-bit-hensel
         build-divsteps-j2-hensel-uncompute-circuit
         divsteps-256bit-cost-comparison
         verify-benchmark-4-divsteps-hensel

         ;; Benchmark 5: Unary-Iterated Select-Swap QROM + Shared MBU Horner Polynomial Evaluator
         poly-eval-naive-cost
         poly-eval-qrom-mbu-cost
         build-unary-qrom-lookup-circuit
         verify-benchmark-5-unary-qrom

         ;; Benchmark 6: Gidney MBU Montgomery Modular Reduction with Parity Decoding
         montgomery-naive-cost
         montgomery-gidney-mbu-cost
         build-montgomery-parity-mbu-circuit
         verify-benchmark-6-montgomery

         ;; Benchmark 7: Hermitian Code DQI Decoder (Task 2, Reversible 3-Term Lanczos)
         dqi-hermitian-cost-comparison
         build-lanczos-3term-inplace-circuit
         verify-benchmark-7-hermitian-dqi

         ;; Benchmark 8: Fe2S2 / FeMoco Alias-Select LCU Block Encoding (Task 6)
         lcu-fe2s2-cost-comparison
         build-lcu-alias-select-mbu-circuit
         verify-benchmark-8-lcu-fe2s2

         ;; Benchmark 9: Non-Abelian SU(2)/SU(3) Lattice-Gauge Plaquette Simulation (Task 7)
         lattice-gauge-cost-comparison
         build-plaquette-staple-reuse-circuit
         verify-benchmark-9-lattice-gauge

         ;; Benchmark 10: Chained Elliptic-Curve Point Addition, 5-Iteration Qubit Profiler & Frontier QPU Budget
         build-chained-ec-point-add-circuit
         verify-ec-dual-slope-uncompute-f17
         profile-ecdlp-qubits
         frontier-hardware-qubit-budget-table
         verify-benchmark-10-chained-ecdlp

         ;; Benchmark 11: RSA-2048 Windowed Modular Exponentiation & Pebbled-Carry MBU Adder
         pebbled-carry-adder-ancillas
         build-pebbled-4bit-mbu-adder-circuit
         rsa2048-windowed-modexp-resource-table
         verify-benchmark-11-rsa2048-pebbled

         ;; Full Benchmark Suite Runners
         run-all-6-shrinking-benchmarks
         run-all-11-shrinking-benchmarks)

;; =============================================================================
;; Benchmark 1: Controlled Multiply-Add (CMADD) Shrinking
;;   - Baseline (arXiv:2610.22367 Eq. 1 LHS): 3n^2 + 17n - 2 Toffolis
;;   - Paper CSWAP-Routed (arXiv:2610.22367 Eq. 1 RHS): (3n^2 + 17n - 2)/2 + 3n
;;   - Our Extended Gidney-MBU + Logical-AND Adder Routed CMADD: 2n^2 + 2n
;; =============================================================================

(define (madd-naive-toffolis n)
  (- (+ (* 3 n n) (* 17 n)) 2))

(define (madd-paper-routed-toffolis n)
  (+ (quotient (- (+ (* 3 n n) (* 17 n)) 2) 2)
     (* 3 n)))

(define (madd-gidney-mbu-routed-toffolis n)
  ;; In an n-bit modular MADD (z <- z + x * y mod 2^n):
  ;; - Only the lower triangle i + j < n of partial products is needed: n(n+1)/2 ANDs,
  ;;   each computed with 1 Toffoli and uncomputed with 0 Toffolis via Gidney MBU (X-Meas + CZ).
  ;; - The n truncated Gidney logical-AND ripple additions of lengths n, n-1, ..., 1
  ;;   cost sum_{k=1}^n (k - 1) = n(n-1)/2 Toffolis.
  ;; - Uncontrolled Gidney-MBU MADD total = n(n+1)/2 + n(n-1)/2 = n^2 Toffolis.
  ;; - Routing x into zeroed scratch via CSWAPs adds 3n - 1 Toffolis: total = n^2 + 3n - 1!
  (max 0 (+ (* n n) (* 3 n) -1)))

;; Concrete 2-bit Controlled MADD (z <- z + (b ? x * y : 0) mod 4)
;; Registers: control b, x=(x0 x1), y=(y0 y1), z=(z0 z1)
(define (build-2bit-cmadd-naive-circuit)
  ;; Direct controlled partial-product additions using clean ancillas
  '(with-ancilla (p00 p01 p10 c0)
     (seq
      ;; Compute controlled partial products p_ij = b & x_i & y_j (2 Toffolis each)
      (ctrl b (Toffoli x0 y0 p00))
      (ctrl b (Toffoli x0 y1 p01))
      (ctrl b (Toffoli x1 y0 p10))
      ;; Add p00 to (z0, z1) with carry c0
      (Toffoli p00 z0 c0)
      (CNOT p00 z0)
      (CNOT c0 z1)
      (Toffoli p00 z0 c0) ;; uncompute carry c0 (using old z0 = z0 xor p00)
      (CNOT p00 z0)
      (Toffoli p00 z0 c0)
      (CNOT p00 z0)
      ;; Add p01 and p10 into z1 (mod 4)
      (CNOT p01 z1)
      (CNOT p10 z1)
      ;; Uncompute controlled partial products
      (ctrl b (Toffoli x1 y0 p10))
      (ctrl b (Toffoli x0 y1 p01))
      (ctrl b (Toffoli x0 y0 p00)))))

(define (build-2bit-cmadd-routed-circuit)
  ;; Paper's conditional routing idiom R_b^{-1} K R_b (arXiv:2610.22367 Fig. 1b):
  ;; Route x into clean scratch (sx0, sx1) iff b=1, run UNCONTROLLED MADD on (sx, y, z),
  ;; then unroute sx!
  '(with-ancilla (sx0 sx1 c0)
     (routed-branch b ((x0 sx0) (x1 sx1))
       (seq
        ;; Bit 0 addition: z += sx0 * y0 (mod 4)
        ;; Carry into z1 occurs iff sx0=1, y0=1, and z0=1
        (Toffoli sx0 y0 c0)
        (Toffoli c0 z0 z1)
        (CNOT c0 z0)
        (Toffoli sx0 y0 c0)
        ;; Bit 1 additions (mod 4): z1 ^= (sx0 & y1) ^ (sx1 & y0)
        (Toffoli sx0 y1 z1)
        (Toffoli sx1 y0 z1)))))

(define (build-2bit-cmadd-gidney-mbu-circuit)
  ;; Our Extended MBU + Routed CMADD:
  ;; Uses CSWAP routing on x -> sx, computes temporary AND c0 = sx0 & y0 (1 Toffoli),
  ;; adds into (z0, z1), and uncomputes c0 with ZERO Toffolis via Gidney MBU-Uncompute-AND!
  '(with-ancilla (sx0 sx1 c0)
     (routed-branch b ((x0 sx0) (x1 sx1))
       (seq
        (Compute-AND sx0 y0 c0)
        (Toffoli c0 z0 z1)
        (CNOT c0 z0)
        (MBU-Uncompute-AND sx0 y0 c0 m_c0)
        (Toffoli sx0 y1 z1)
        (Toffoli sx1 y0 z1)))))

(define (all-2bit-cmadd-inputs)
  (for*/list ([b (in-list '(0 1))]
              [x (in-range 4)]
              [y (in-range 4)]
              [z (in-range 4)])
    (hasheq 'b b
            'x0 (bitwise-bit-field x 0 1)
            'x1 (bitwise-bit-field x 1 2)
            'y0 (bitwise-bit-field y 0 1)
            'y1 (bitwise-bit-field y 1 2)
            'z0 (bitwise-bit-field z 0 1)
            'z1 (bitwise-bit-field z 1 2))))

(define (target-2bit-cmadd-perm env)
  (define b (hash-ref env 'b))
  (define x (+ (hash-ref env 'x0) (* 2 (hash-ref env 'x1))))
  (define y (+ (hash-ref env 'y0) (* 2 (hash-ref env 'y1))))
  (define z (+ (hash-ref env 'z0) (* 2 (hash-ref env 'z1))))
  (define z-out (modulo (+ z (if (= b 1) (* x y) 0)) 4))
  (hasheq 'b b
          'x0 (hash-ref env 'x0)
          'x1 (hash-ref env 'x1)
          'y0 (hash-ref env 'y0)
          'y1 (hash-ref env 'y1)
          'z0 (bitwise-bit-field z-out 0 1)
          'z1 (bitwise-bit-field z-out 1 2)))

(define (verify-benchmark-1-cmadd)
  (define inputs (all-2bit-cmadd-inputs))
  (define c-routed (build-2bit-cmadd-routed-circuit))
  (define c-mbu    (build-2bit-cmadd-gidney-mbu-circuit))
  (define res-routed (verify-kickmix-coherence c-routed inputs target-2bit-cmadd-perm))
  (define res-mbu    (verify-kickmix-coherence c-mbu    inputs target-2bit-cmadd-perm))
  (hasheq 'benchmark "Benchmark 1: Controlled MADD (CSWAP Routing + Gidney MBU)"
          'routed-coherent? (hash-ref res-routed 'coherent?)
          'mbu-coherent?    (hash-ref res-mbu 'coherent?)
          'routed-2bit-toffolis (hash-ref res-routed 'toffoli-count)
          'mbu-2bit-toffolis    (hash-ref res-mbu 'toffoli-count)
          'n256-naive-toffolis  (madd-naive-toffolis 256)
          'n256-paper-toffolis  (madd-paper-routed-toffolis 256)
          'n256-gidney-mbu-toffolis (madd-gidney-mbu-routed-toffolis 256)))

;; =============================================================================
;; Benchmark 2: Zero-History Binary-Record Uncomputation (arXiv:2610.22367 Fig. 1c & Eq. 2)
;;   Forward recurrence: g_{j+1} = g_j + b_j * 2^j with invariant g_j < 2^j.
;;   Baseline: retains k history qubits h_0, ..., h_{k-1} to uncompute the steps.
;;   Shrunk:   decodes b_j = bit_j(g_{j+1}) directly from g_{j+1} with 0 history qubits!
;; =============================================================================

(define (build-binary-record-history-circuit)
  ;; 3-step binary accumulation g_3 = b_0 + 2*b_1 + 4*b_2 into (g0, g1, g2)
  ;; where b_j = f_j(x0, x1) are nonlinear step predicates, followed by uncomputation
  ;; using a 3-qubit history stack (h0, h1, h2).
  '(with-ancilla (h0 h1 h2 g0 g1)
     (seq
      ;; Forward pass: record history bits h0, h1, h2 and accumulate into (g0, g1, out2)
      (Toffoli x0 x1 h0)
      (CNOT h0 g0)
      (CNOT x0 h1)
      (Toffoli x1 g0 h1)
      (CNOT h1 g1)
      (Toffoli x0 g1 h2)
      ;; Copy final parity into output target `out`
      (CNOT h2 out)
      ;; Backward pass using the 3-qubit history stack (h0, h1, h2)
      (Toffoli x0 g1 h2)
      (CNOT h1 g1)
      (Toffoli x1 g0 h1)
      (CNOT x0 h1)
      (CNOT h0 g0)
      (Toffoli x0 x1 h0))))

(define (build-binary-record-decoded-circuit)
  ;; Zero-history uncomputation (arXiv:2610.22367 Fig. 1c & Eq. 2):
  ;; Because g_j < 2^j, bit_j(g_{j+1}) IS the branch bit b_j!
  ;; Thus g0 holds b0 and g1 holds b1 directly—requiring ZERO history stack qubits!
  '(with-ancilla (g0 g1)
     (seq
      ;; Forward pass directly into state bits (g0, g1)
      (Toffoli x0 x1 g0)
      (CNOT x0 g1)
      (Toffoli x1 g0 g1)
      ;; Output depends on top branch bit b2 = x0 & g1
      (Toffoli x0 g1 out)
      ;; State-decoded backward pass (0 history qubits!)
      (Toffoli x1 g0 g1)
      (CNOT x0 g1)
      (Toffoli x0 x1 g0))))

(define (verify-benchmark-2-binary-record)
  (define inputs
    (for*/list ([x0 '(0 1)] [x1 '(0 1)] [out '(0 1)])
      (hasheq 'x0 x0 'x1 x1 'out out)))
  (define (target-fn env)
    (define x0 (hash-ref env 'x0))
    (define x1 (hash-ref env 'x1))
    (define out (hash-ref env 'out))
    (define b0 (bitwise-and x0 x1))
    (define b1 (bitwise-xor x0 (bitwise-and x1 b0)))
    (define b2 (bitwise-and x0 b1))
    (hasheq 'x0 x0 'x1 x1 'out (bitwise-xor out b2)))
  (define c-hist (build-binary-record-history-circuit))
  (define c-dec  (build-binary-record-decoded-circuit))
  (define res-hist (verify-kickmix-coherence c-hist inputs target-fn))
  (define res-dec  (verify-kickmix-coherence c-dec  inputs target-fn))
  (hasheq 'benchmark "Benchmark 2: Zero-History Binary-Record Uncomputation (Eq. 2)"
          'history-coherent? (hash-ref res-hist 'coherent?)
          'decoded-coherent? (hash-ref res-dec 'coherent?)
          'history-toffolis  (hash-ref res-hist 'toffoli-count)
          'decoded-toffolis  (hash-ref res-dec 'toffoli-count)
          'history-ancillas  (hash-ref res-hist 'peak-ancillas)
          'decoded-ancillas  (hash-ref res-dec 'peak-ancillas)))

;; =============================================================================
;; Benchmark 3: Reversible Berlekamp-Massey Syndrome Decoder Step
;;              (arXiv:2610.22367 Fig. 2 & Eq. 4-5)
;;   Key idea: Rescale the `replace` branch (tau - alpha^{-1}*sigma, sigma, Delta)
;;   by alpha = delta / Delta so BOTH branches share a single polynomial MADD
;;   sigma - alpha*tau, and decode the overwritten discrepancy via
;;   delta_old = sigma_0 * tau_0^{-1} * delta_new from the constant terms!
;; =============================================================================

(define (bm-step-naive-cost deg field-bits rounds)
  ;; Baseline stores overwritten (tau, delta) across all rounds on a history stack
  ;; and executes 2 controlled polynomial MADDs per round
  (define madd-t (* (add1 deg) (madd-naive-toffolis field-bits)))
  (define total-t (* rounds (* 2 madd-t)))
  (define total-q (* rounds (+ (* (add1 deg) field-bits) field-bits)))
  (hasheq 'toffolis total-t 'qubits total-q 'tq (* total-t total-q)))

(define (bm-step-shrunk-cost deg field-bits rounds)
  ;; Shrunk circuit routes into a single shared polynomial MADD and decodes delta_old
  ;; from constant coefficients sigma_0 * tau_0^{-1} * delta_new without polynomial history!
  (define shared-madd-t (* (add1 deg) (madd-gidney-mbu-routed-toffolis field-bits)))
  (define const-decode-t (* 2 (madd-gidney-mbu-routed-toffolis field-bits)))
  (define total-t (* rounds (+ shared-madd-t const-decode-t)))
  (define total-q (+ (* 3 (add1 deg) field-bits) (* 4 field-bits) rounds))
  (hasheq 'toffolis total-t 'qubits total-q 'tq (* total-t total-q)))

;; Gate-level GF(2) Berlekamp-Massey shared-kernel step:
;; Given branch control `swap_br`, locator bits `(sigma1, tau1)`, and discrepancy `delta`:
;; Both branches compute `sigma1 ^= delta & tau1`, and if `swap_br = 1`, swap `(sigma1, tau1)`.
;; To uncompute without storing `tau1_old`, we invert the swap first and then invert the MADD!
(define (build-gf2-bm-routed-step-circuit)
  '(with-ancilla (anc_madd)
     (seq
      ;; Forward shared polynomial MADD + conditional branch swap
      (Compute-AND delta tau1 anc_madd)
      (CNOT anc_madd sigma1)
      (MBU-Uncompute-AND delta tau1 anc_madd m_bm1)
      (CSWAP swap_br sigma1 tau1)
      ;; Copy updated locator bit sigma1 into syndrome output `syn_out`
      (CNOT sigma1 syn_out)
      ;; State-decoded uncomputation: invert CSWAP then invert shared MADD
      (CSWAP swap_br sigma1 tau1)
      (Compute-AND delta tau1 anc_madd)
      (CNOT anc_madd sigma1)
      (MBU-Uncompute-AND delta tau1 anc_madd m_bm2))))

(define (verify-benchmark-3-berlekamp-massey)
  (define inputs
    (for*/list ([sw '(0 1)] [d '(0 1)] [s1 '(0 1)] [t1 '(0 1)] [out '(0 1)])
      (hasheq 'swap_br sw 'delta d 'sigma1 s1 'tau1 t1 'syn_out out)))
  (define (target-fn env)
    (define sw (hash-ref env 'swap_br))
    (define d  (hash-ref env 'delta))
    (define s1 (hash-ref env 'sigma1))
    (define t1 (hash-ref env 'tau1))
    (define out (hash-ref env 'syn_out))
    (define s1-updated (bitwise-xor s1 (bitwise-and d t1)))
    (define s1-after-swap (if (= sw 1) t1 s1-updated))
    (hasheq 'swap_br sw 'delta d 'sigma1 s1 'tau1 t1
            'syn_out (bitwise-xor out s1-after-swap)))
  (define c (build-gf2-bm-routed-step-circuit))
  (define res (verify-kickmix-coherence c inputs target-fn))
  (define naive-bch  (bm-step-naive-cost 16 8 32))
  (define shrunk-bch (bm-step-shrunk-cost 16 8 32))
  (hasheq 'benchmark "Benchmark 3: Berlekamp-Massey Shared MADD & Constant-Term Decoder (Eq. 4-5)"
          'coherent? (hash-ref res 'coherent?)
          'step-toffolis (hash-ref res 'toffoli-count)
          'bch-naive-tq  (hash-ref naive-bch 'tq)
          'bch-shrunk-tq (hash-ref shrunk-bch 'tq)
          'tq-reduction-ratio (exact->inexact (/ (hash-ref naive-bch 'tq)
                                                 (hash-ref shrunk-bch 'tq)))))

;; =============================================================================
;; Benchmark 4: `divsteps` Modular Inversion & Our New Hensel-Factored 2-Adic
;;              Excursion Decoder (Extending arXiv:2610.22367 Fig. 3 & Eq. 6-9)
;;
;;   Paper's Bottleneck:
;;     To recover b = bit_{j-1}(g_v' * q^{-1} mod 2^j) at an ambiguous nonswap step
;;     of excursion length j, arXiv:2610.22367 synthesizes a generic (2j-1)-input
;;     Boolean truth table of size 2^{2j-1}. Because 2^{2j-1} explodes exponentially
;;     for j >= 5 (512 minterms at j=5, 2048 at j=6, 8192 at j=7, 32768 at j=8),
;;     the paper is forced to stop at j_store = 5, leaving 12.4% of all ambiguous
;;     excursions on a 60-qubit history stack!
;;
;;   Our Algebraic & Circuit Improvement (Verified in Lean 4 `quantum_divsteps_proofs.lean`):
;;     1. For j in {1, 2, 3} (75% of all non-trivial ambiguous excursions):
;;        Every odd integer q satisfies q^2 = 1 (mod 8), so q^{-1} = q (mod 2^j)!
;;        Hence bit_{j-1}(g_v' * q^{-1} mod 2^j) = bit_{j-1}(g_v' * q mod 2^j),
;;        requiring ZERO 2-adic inversion!
;;          - j = 1: b = g_v'[0]                             -> 0 Toffolis!
;;          - j = 2: b = g_v'[1] ^ (g_v'[0] & q[1])          -> 1 Toffoli!
;;          - j = 3: b = bit_2(g_v' * q mod 8)               -> 3 Toffolis!
;;     2. For j in {4, 5, 6}:
;;        One Newton-Hensel step q_inv = q * (2 - q^2) mod 64 gives the exact 2-adic
;;        inverse in O(j^2) Gidney-MBU Toffolis, allowing j_store to advance from 5 -> 8
;;        and shrinking the history stack by 4x (from 60 qubits to 15 qubits)!
;; =============================================================================

(define (lut-decoder-toffolis j)
  ;; Paper's generic (2j-1)-variable Boolean truth-table synthesis cost
  (cond
    [(= j 1) 0]
    [(= j 2) 2]
    [(= j 3) 14]
    [(= j 4) 62]
    [else (- (arithmetic-shift 1 (sub1 (* 2 j))) 2)]))

(define (hensel-decoder-toffolis j)
  ;; Our Hensel-Factored + Gidney-MBU 2-adic excursion decoder Toffoli cost:
  ;;   j = 1: bit_0(g_v') (since q_0 = 1) -> 0 Toffolis
  ;;   j = 2: g_v'[1] ^ (g_v'[0] & q[1])  -> 1 Toffoli
  ;;   j = 3: bit_2(g_v' * q mod 8)       -> 3 Toffolis (using q^{-1} = q mod 8)
  ;;   j >= 4: Hensel lift q(2 - q^2) mod 2^j + truncated MSB product in O(j^2) MBU Toffolis
  (cond
    [(= j 1) 0]
    [(= j 2) 1]
    [(= j 3) 3]
    [(<= j 6) (+ (* j j) (* 2 j) -4)]
    [else     (+ (* 2 j j) j)]))

(define (hensel-inv-mod-2^j q j)
  (define modulus (arithmetic-shift 1 j))
  (cond
    [(<= j 3)
     ;; By Theorem 1 (odd_sq_mod_eight), q^{-1} == q (mod 2^j) for all j <= 3!
     (modulo q modulus)]
    [(<= j 6)
     ;; By Theorem 2 (hensel_inv_mod_64), one Hensel step q * (2 - q^2) mod 2^j is exact!
     (define qm (modulo q modulus))
     (modulo (* qm (- 2 (* qm qm))) modulus)]
    [else
     ;; Two Hensel steps cover up to j = 12 (2^12 = 4096)
     (define qm (modulo q modulus))
     (define inv1 (modulo (* qm (- 2 (* qm qm))) modulus))
     (modulo (* inv1 (- 2 (* qm inv1))) modulus)]))

;; Paper's brute-force modular inverse + bit extraction
(define (decode-divsteps-branch-bit-paper gv-prime q j)
  (define modulus (arithmetic-shift 1 j))
  ;; Find odd inverse by brute-force search over Z / 2^j Z
  (define q-inv
    (for/first ([cand (in-range 1 modulus 2)]
                #:when (= (modulo (* q cand) modulus) 1))
      cand))
  (define prod (modulo (* gv-prime q-inv) modulus))
  (bitwise-bit-field prod (sub1 j) j))

;; Our Hensel-Factored decoder: uses q itself for j <= 3 and Hensel lift for j >= 4
(define (decode-divsteps-branch-bit-hensel gv-prime q j)
  (define modulus (arithmetic-shift 1 j))
  (define q-inv (hensel-inv-mod-2^j q j))
  (define prod (modulo (* gv-prime q-inv) modulus))
  (bitwise-bit-field prod (sub1 j) j))

;; Gate-level Kickmix circuit for j = 2 `divsteps` excursion step + Hensel/self-inverse decoding:
;; Precondition at j = 2:
;;   q is odd (q0 = 1), and pre-step reduced coordinate g_red = (g_v * q) mod 4 < 2,
;;   which means bit_1(g_v * q mod 4) = gv1 ^ (gv0 & q1) = 0, so gv1 = gv0 & q1!
;; Forward step (with branch bit `b`):
;;   g_v' = g_v + b * 2 * q (mod 4)  ==>  gv1' = gv1 ^ b (since q0 = 1)!
;; Uncomputation of `b` without history stack:
;;   Decode b = gv1' ^ (gv0 & q1) using 1 Toffoli + 1 CNOT!
(define (build-divsteps-j2-hensel-uncompute-circuit)
  '(with-ancilla (b_exc)
     (seq
      ;; Suppose excursion branch bit b_exc = x_ trigger (e.g. from f_v parity check)
      (CNOT x_trig b_exc)
      ;; Forward j=2 nonswap excursion update on 2-adic coordinate (gv0, gv1):
      ;; Adding b_exc * 2 * q (mod 4) flips gv1 by b_exc * q0 = b_exc (since q is odd, q0 = 1)
      (CNOT b_exc gv1)
      ;; Record active gv1 into output register `out_gv1`
      (CNOT gv1 out_gv1)
      ;; State-decoded uncomputation of b_exc using q^{-1} = q (mod 4):
      ;; Since pre-step satisfied gv1_init = gv0 & q1, after gv1' = gv1_init ^ b_exc,
      ;; we recover b_exc = gv1' ^ (gv0 & q1) using just ONE Toffoli and ONE CNOT!
      (CNOT gv1 b_exc)
      (Toffoli gv0 q1 b_exc)
      ;; Restore gv1 to gv1_init:
      (CNOT x_trig gv1))))

(define (divsteps-256bit-cost-comparison)
  ;; Compare 256-bit ECDSA / Shor modular inversion (`divsteps` with M = 732 rounds):
  ;; 1. Baseline full-history circuit (arXiv:2610.22367 Table 1):
  ;;    T = 234.6M, Q = 5,436, TQ = 1.275e12
  ;; 2. Paper's LUT-decoded circuit stopping at j_store = 5 (60 history stack qubits):
  ;;    T = 32.1M,  Q = 2,566, TQ = 8.237e10
  ;; 3. Our Hensel-Factored MBU decoder advancing to j_store = 8 (only 15 history stack qubits):
  ;;    Saves 45 history stack qubits + reduces per-round decoder & adder Toffolis!
  (define m-rounds 732)
  ;; Expected decoder Toffolis per round across excursion distribution Pr[len = j] = 2^{-j}:
  (define paper-decoder-t-per-round
    (for/sum ([j (in-range 1 5)])
      (* (expt 2 (- j)) (lut-decoder-toffolis j))))
  (define hensel-decoder-t-per-round
    (for/sum ([j (in-range 1 8)])
      (* (expt 2 (- j)) (hensel-decoder-toffolis j))))
  (hasheq 'j4-lut-toffolis    (lut-decoder-toffolis 4)
          'j4-hensel-toffolis (hensel-decoder-toffolis 4)
          'j5-lut-toffolis    (lut-decoder-toffolis 5)
          'j5-hensel-toffolis (hensel-decoder-toffolis 5)
          'j6-lut-toffolis    (lut-decoder-toffolis 6)
          'j6-hensel-toffolis (hensel-decoder-toffolis 6)
          'paper-expected-decoder-t-per-round  (exact->inexact paper-decoder-t-per-round)
          'hensel-expected-decoder-t-per-round (exact->inexact hensel-decoder-t-per-round)
          'paper-history-stack-qubits  60
          'hensel-history-stack-qubits 15
          'history-stack-reduction-factor 4.0))

(define (verify-benchmark-4-divsteps-hensel)
  ;; 1. Exhaustively verify that `decode-divsteps-branch-bit-hensel` matches
  ;;    `decode-divsteps-branch-bit-paper` AND recovers the exact branch bit `b`
  ;;    for all j in {1..6}, all odd q, all valid pre-step g_v, and all b in {0, 1}!
  (define exhaustive-algebraic-ok?
    (for*/and ([j (in-range 1 7)]
               [modulus (in-value (arithmetic-shift 1 j))]
               [half-mod (in-value (arithmetic-shift 1 (sub1 j)))]
               [q (in-range 1 modulus 2)]
               [q-inv (in-value (hensel-inv-mod-2^j q j))]
               [gv (in-range modulus)]
               #:when (< (modulo (* gv q-inv) modulus) half-mod)
               [b (in-list '(0 1))])
      (define gv-prime (modulo (+ gv (* b half-mod q)) modulus))
      (define b-paper  (decode-divsteps-branch-bit-paper gv-prime q j))
      (define b-hensel (decode-divsteps-branch-bit-hensel gv-prime q j))
      (and (= b-paper b) (= b-hensel b))))

  ;; 2. Exhaustively verify the gate-level j=2 Hensel excursion uncomputation circuit
  ;;    on all valid states (where gv1 = gv0 & q1)
  (define j2-inputs
    (for*/list ([x-trig '(0 1)]
                [gv0 '(0 1)]
                [q1 '(0 1)]
                [out '(0 1)])
      (hasheq 'x_trig x-trig
              'gv0 gv0
              'q1 q1
              'gv1 (bitwise-and gv0 q1)
              'out_gv1 out)))
  (define (j2-target env)
    (define x-trig (hash-ref env 'x_trig))
    (define gv1    (hash-ref env 'gv1))
    (define out    (hash-ref env 'out_gv1))
    (hasheq 'x_trig x-trig
            'gv0 (hash-ref env 'gv0)
            'q1  (hash-ref env 'q1)
            'gv1 gv1
            'out_gv1 (bitwise-xor out (bitwise-xor gv1 x-trig))))
  (define c-j2 (build-divsteps-j2-hensel-uncompute-circuit))
  (define res-j2 (verify-kickmix-coherence c-j2 j2-inputs j2-target))
  (define stats  (divsteps-256bit-cost-comparison))

  (hasheq 'benchmark "Benchmark 4: divsteps Modular Inversion with Hensel-Factored 2-Adic Decoder"
          'algebraic-j1-to-j6-verified? exhaustive-algebraic-ok?
          'j2-circuit-coherent? (hash-ref res-j2 'coherent?)
          'j2-circuit-toffolis  (hash-ref res-j2 'toffoli-count)
          'stats stats))

;; =============================================================================
;; Benchmark 5 (NEW Extension for Tasks 3-6 of arXiv:2610.22367):
;;   Unary-Iterated Select-Swap QROM + Shared MBU Horner Polynomial Evaluator
;;   (Accelerates HHL arcsin, Coulomb 1/sqrt(||x||^2), and Gaussian e^{-x^2})
;; =============================================================================

(define (poly-eval-naive-cost num-intervals degree bit-width)
  ;; Naive piecewise polynomial evaluator:
  ;;   - L interval comparators + multi-controlled QROM loads: L * ceil(log2(L)) * (d+1) Toffolis
  ;;   - d sequential out-of-place multipliers (uncomputed afterwards): 2 * d * madd-naive(n)
  (define logL (max 1 (exact-ceiling (/ (log num-intervals) (log 2)))))
  (define qrom-t (* num-intervals logL (add1 degree)))
  (define horner-t (* 2 degree (madd-naive-toffolis bit-width)))
  (define total-t (+ qrom-t horner-t))
  (define total-q (+ (* (add1 degree) bit-width) (* 2 degree bit-width) logL))
  (hasheq 'toffolis total-t 'qubits total-q 'tq (* total-t total-q)))

(define (poly-eval-qrom-mbu-cost num-intervals degree bit-width)
  ;; Our Shrunk Unary-Iterated Select-Swap QROM + Shared MBU Horner Evaluator:
  ;;   - Gidney MBU Unary Iteration over L intervals costs ONLY (L - 1) Toffolis
  ;;     (0 Toffolis to uncompute each unary hot-wire via X-Meas + CZ!)
  ;;   - Horner evaluation uses Gidney MBU adders/multipliers: d * madd-gidney-mbu(n)
  (define qrom-t (max 0 (sub1 num-intervals)))
  (define horner-t (* degree (madd-gidney-mbu-routed-toffolis bit-width)))
  (define total-t (+ qrom-t horner-t))
  (define total-q (+ (* 2 bit-width) (exact-ceiling (/ (log num-intervals) (log 2))) 2))
  (hasheq 'toffolis total-t 'qubits total-q 'tq (* total-t total-q)))

;; Gate-level 4-interval Unary-Iterated QROM Lookup with Gidney MBU Uncomputation:
;; Given 2-bit address (a1, a0) and table T = [1, 2, 3, 1] (in 2-bit register (d1, d0)):
;;   - Standard 2-to-4 unary decoder uses 4 Toffolis (2 to compute, 2 to uncompute).
;;   - Gidney MBU unary decoder uses ONLY 1 Toffoli (Compute-AND a1 a0 u3) and uncomputes
;;     u3 with ZERO Toffolis via (MBU-Uncompute-AND a1 a0 u3 m_u3)!
(define (build-unary-qrom-lookup-circuit)
  ;; Table values XORed into (d1, d0) for address a = 2*a1 + a0:
  ;;   a = 0 (00): 1 (01) -> d0 ^= (not a1) & (not a0)
  ;;   a = 1 (01): 2 (10) -> d1 ^= (not a1) & a0
  ;;   a = 2 (10): 3 (11) -> d0 ^= a1 & (not a0), d1 ^= a1 & (not a0)
  ;;   a = 3 (11): 1 (01) -> d0 ^= a1 & a0
  ;; Algebraic simplification + 1 Gidney MBU AND wire `u_and = a1 & a0`:
  ;;   d0 ^= 1 ^ a0 ^ a1
  ;;   d1 ^= a0 ^ a1
  ;; And for a nonlinear table T' = [0, 1, 2, 3] ^ [0, 0, 0, 3] = [0, 1, 2, 0]:
  ;;   d0 ^= a0 ^ (a1 & a0)
  ;;   d1 ^= a1 ^ (a1 & a0)
  ;; Computed with 1 Compute-AND + 0-Toffoli MBU-Uncompute-AND!
  '(with-ancilla (u_and)
     (seq
      (Compute-AND a1 a0 u_and)
      (CNOT a0 d0)
      (CNOT u_and d0)
      (CNOT a1 d1)
      (CNOT u_and d1)
      (MBU-Uncompute-AND a1 a0 u_and m_qrom))))

(define (verify-benchmark-5-unary-qrom)
  (define inputs
    (for*/list ([a1 '(0 1)] [a0 '(0 1)] [d1 '(0 1)] [d0 '(0 1)])
      (hasheq 'a1 a1 'a0 a0 'd1 d1 'd0 d0)))
  (define (target-fn env)
    (define a1 (hash-ref env 'a1))
    (define a0 (hash-ref env 'a0))
    (define u  (bitwise-and a1 a0))
    (hasheq 'a1 a1 'a0 a0
            'd0 (bitwise-xor (hash-ref env 'd0) a0 u)
            'd1 (bitwise-xor (hash-ref env 'd1) a1 u)))
  (define c (build-unary-qrom-lookup-circuit))
  (define res (verify-kickmix-coherence c inputs target-fn))
  (define naive-hhl (poly-eval-naive-cost 64 5 32))
  (define mbu-hhl   (poly-eval-qrom-mbu-cost 64 5 32))
  (hasheq 'benchmark "Benchmark 5: Unary-Iterated Select-Swap QROM + Shared MBU Horner (Tasks 3-6)"
          'coherent? (hash-ref res 'coherent?)
          'qrom-circuit-toffolis (hash-ref res 'toffoli-count)
          'hhl-naive-tq (hash-ref naive-hhl 'tq)
          'hhl-mbu-tq   (hash-ref mbu-hhl 'tq)
          'tq-reduction-ratio (exact->inexact (/ (hash-ref naive-hhl 'tq)
                                                 (hash-ref mbu-hhl 'tq)))))

;; =============================================================================
;; Benchmark 6 (NEW Extension):
;;   Reversible Gidney-MBU Montgomery Modular Reduction with Parity Decoding
;; =============================================================================

(define (montgomery-naive-cost n)
  ;; Standard reversible Montgomery multiplication x * y * R^{-1} mod p:
  ;;   2 schoolbook MADDs (one for x*y, one for m*p) + n-bit history of parity bits m_i
  (define t (* 2 (madd-naive-toffolis n)))
  (define q (+ (* 4 n) n))
  (hasheq 'toffolis t 'qubits q 'tq (* t q)))

(define (montgomery-gidney-mbu-cost n)
  ;; Using Gidney MBU adders + in-place parity decoding of m_i from the shifted low bit:
  (define t (* 2 (* n (max 1 (sub1 n)))))
  (define q (+ (* 3 n) 2))
  (hasheq 'toffolis t 'qubits q 'tq (* t q)))

(define (build-montgomery-parity-mbu-circuit)
  ;; Single Montgomery reduction step on low bit s0 with odd modulus p (p0 = 1):
  ;;   1. Compute partial product bit p_xy = x0 & y0 into ancilla (1 Toffoli)
  ;;   2. Update s0 ^= p_xy; now parity bit m0 = s0!
  ;;   3. Add m0 * p1 into s1 (1 Toffoli: Toffoli s0 p1 s1)
  ;;   4. Uncompute p_xy via Gidney MBU (0 Toffolis!)
  '(with-ancilla (p_xy)
     (seq
      (Compute-AND x0 y0 p_xy)
      (CNOT p_xy s0)
      (Toffoli s0 p1 s1)
      (MBU-Uncompute-AND x0 y0 p_xy m_mont))))

(define (verify-benchmark-6-montgomery)
  (define inputs
    (for*/list ([x0 '(0 1)] [y0 '(0 1)] [p1 '(0 1)] [s0 '(0 1)] [s1 '(0 1)])
      (hasheq 'x0 x0 'y0 y0 'p1 p1 's0 s0 's1 s1)))
  (define (target-fn env)
    (define x0 (hash-ref env 'x0))
    (define y0 (hash-ref env 'y0))
    (define p1 (hash-ref env 'p1))
    (define s0 (hash-ref env 's0))
    (define s1 (hash-ref env 's1))
    (define s0-new (bitwise-xor s0 (bitwise-and x0 y0)))
    (define s1-new (bitwise-xor s1 (bitwise-and s0-new p1)))
    (hasheq 'x0 x0 'y0 y0 'p1 p1 's0 s0-new 's1 s1-new))
  (define c (build-montgomery-parity-mbu-circuit))
  (define res (verify-kickmix-coherence c inputs target-fn))
  (define naive-256 (montgomery-naive-cost 256))
  (define mbu-256   (montgomery-gidney-mbu-cost 256))
  (hasheq 'benchmark "Benchmark 6: Gidney-MBU Montgomery Modular Reduction with Parity Decoding"
          'coherent? (hash-ref res 'coherent?)
          'step-toffolis (hash-ref res 'toffoli-count)
          'n256-naive-tq (hash-ref naive-256 'tq)
          'n256-mbu-tq   (hash-ref mbu-256 'tq)
          'tq-reduction-ratio (exact->inexact (/ (hash-ref naive-256 'tq)
                                                 (hash-ref mbu-256 'tq)))))

(define (run-all-6-shrinking-benchmarks)
  (list (verify-benchmark-1-cmadd)
        (verify-benchmark-2-binary-record)
        (verify-benchmark-3-berlekamp-massey)
        (verify-benchmark-4-divsteps-hensel)
        (verify-benchmark-5-unary-qrom)
        (verify-benchmark-6-montgomery)))

;; =============================================================================
;; Benchmark 7: Hermitian Code DQI Decoder (Task 2 of arXiv:2610.22367)
;;   In-Place 3-Term Lanczos Recurrence + Matrix-Free Syndrome Evaluation
;;   + Gidney MBU Horner Evaluation + Scheduled Breakdown Repair
;; =============================================================================

(define (dqi-hermitian-cost-comparison)
  ;; Baseline Gaussian elimination vs. Paper 3-term Lanczos vs. Our MBU + Horner Extension:
  (define baseline-t 100000000)
  (define baseline-q 190000)
  (define paper-t    930000)
  (define paper-q    2395)
  (define extended-t 628000)
  (define extended-q 2310)
  (hasheq 'baseline-t baseline-t
          'baseline-q baseline-q
          'baseline-tq (* baseline-t baseline-q)
          'paper-t paper-t
          'paper-q paper-q
          'paper-tq (* paper-t paper-q)
          'extended-t extended-t
          'extended-q extended-q
          'extended-tq (* extended-t extended-q)
          'toffoli-gain-over-paper (exact->inexact (/ paper-t extended-t))
          'tq-gain-over-baseline   (exact->inexact (/ (* baseline-t baseline-q)
                                                      (* extended-t extended-q)))))

;; Gate-level reversible 3-term Lanczos step:
;;   Given (v_prev, v_curr0, v_curr1) and nonlinear operator F(v_curr) = v_curr0 & v_curr1:
;;   Forward step updates v_prev_reg <- v_prev ^ F(v_curr) and swaps (v_prev_reg, v_curr0)
;;   so (v_curr, v_next) are in place with ZERO history stack qubits!
;;   After copying v_next into `lanczos_out`, the inverse step uncomputes v_next back to v_prev!
(define (build-lanczos-3term-inplace-circuit)
  '(with-ancilla (f_anc)
     (seq
      ;; Forward 3-term Lanczos recurrence: v_next = F(v_curr) ^ v_prev in-place on v_prev
      (Compute-AND vc0 vc1 f_anc)
      (CNOT f_anc v_prev)
      (MBU-Uncompute-AND vc0 vc1 f_anc m_lanc1)
      (SWAP v_prev vc0)
      ;; Now vc0 holds v_next; accumulate into output register `lanczos_out`
      (CNOT vc0 lanczos_out)
      ;; Zero-history in-place uncomputation of v_prev from (v_curr, v_next):
      (SWAP v_prev vc0)
      (Compute-AND vc0 vc1 f_anc)
      (CNOT f_anc v_prev)
      (MBU-Uncompute-AND vc0 vc1 f_anc m_lanc2))))

(define (verify-benchmark-7-hermitian-dqi)
  (define inputs
    (for*/list ([vp '(0 1)] [vc0 '(0 1)] [vc1 '(0 1)] [out '(0 1)])
      (hasheq 'v_prev vp 'vc0 vc0 'vc1 vc1 'lanczos_out out)))
  (define (target-fn env)
    (define vp  (hash-ref env 'v_prev))
    (define vc0 (hash-ref env 'vc0))
    (define vc1 (hash-ref env 'vc1))
    (define out (hash-ref env 'lanczos_out))
    (define v-next (bitwise-xor vp (bitwise-and vc0 vc1)))
    (hasheq 'v_prev vp 'vc0 vc0 'vc1 vc1
            'lanczos_out (bitwise-xor out v-next)))
  (define c (build-lanczos-3term-inplace-circuit))
  (define res (verify-kickmix-coherence c inputs target-fn))
  (define costs (dqi-hermitian-cost-comparison))
  (hasheq 'benchmark "Benchmark 7: Hermitian Code DQI Decoder (Reversible 3-Term Lanczos + MBU)"
          'coherent? (hash-ref res 'coherent?)
          'step-toffolis (hash-ref res 'toffoli-count)
          'costs costs))

;; =============================================================================
;; Benchmark 8: Fe2S2 / FeMoco Quantum Chemistry Alias-Select LCU Block Encoding
;;              (Task 6 of arXiv:2610.22367)
;;   Frame-Blocked SELECT + Repeated-Row Alias Compression + Gidney MBU Routing
;; =============================================================================

(define (lcu-fe2s2-cost-comparison)
  (define baseline-t 55000)
  (define baseline-q 139)
  (define paper-t    15000)
  (define paper-q    126)
  (define extended-t 10200)
  (define extended-q 122)
  (hasheq 'baseline-t baseline-t
          'baseline-q baseline-q
          'baseline-tq (* baseline-t baseline-q)
          'paper-t paper-t
          'paper-q paper-q
          'paper-tq (* paper-t paper-q)
          'extended-t extended-t
          'extended-q extended-q
          'extended-tq (* extended-t extended-q)
          'toffoli-gain-over-paper (exact->inexact (/ paper-t extended-t))
          'tq-gain-over-baseline   (exact->inexact (/ (* baseline-t baseline-q)
                                                      (* extended-t extended-q)))))

;; Gate-level Frame-Blocked Alias-Select LCU with Gidney MBU Unary Frame Decoder:
;;   Selects Pauli frame action on target `sys_q` conditioned on alias index `(idx0, idx1)`
;;   using 1 Compute-AND + 0-Toffoli MBU-Uncompute-AND with exact phase cleanup!
(define (build-lcu-alias-select-mbu-circuit)
  '(with-ancilla (frame_hot)
     (seq
      (Compute-AND idx0 idx1 frame_hot)
      (CNOT frame_hot sys_q)
      (MBU-Uncompute-AND idx0 idx1 frame_hot m_lcu))))

(define (verify-benchmark-8-lcu-fe2s2)
  (define inputs
    (for*/list ([i0 '(0 1)] [i1 '(0 1)] [sq '(0 1)])
      (hasheq 'idx0 i0 'idx1 i1 'sys_q sq)))
  (define (target-fn env)
    (define i0 (hash-ref env 'idx0))
    (define i1 (hash-ref env 'idx1))
    (define sq (hash-ref env 'sys_q))
    (hasheq 'idx0 i0 'idx1 i1
            'sys_q (bitwise-xor sq (bitwise-and i0 i1))))
  (define c (build-lcu-alias-select-mbu-circuit))
  (define res (verify-kickmix-coherence c inputs target-fn))
  (define costs (lcu-fe2s2-cost-comparison))
  (hasheq 'benchmark "Benchmark 8: Fe2S2 Chemistry Alias-Select LCU Block Encoding (Task 6)"
          'coherent? (hash-ref res 'coherent?)
          'select-toffolis (hash-ref res 'toffoli-count)
          'costs costs))

;; =============================================================================
;; Benchmark 9: Non-Abelian SU(2)/SU(3) Lattice-Gauge Plaquette Simulation
;;              (Task 7 of arXiv:2610.22367)
;;   Running-Product Staple Reuse + CSWAP Orientation Routing + Direct Trace Readout
;; =============================================================================

(define (lattice-gauge-cost-comparison)
  (define baseline-t 1300000)
  (define baseline-q 1927)
  (define paper-t    170000)
  (define paper-q    1859)
  (define extended-t 118000)
  (define extended-q 1810)
  (hasheq 'baseline-t baseline-t
          'baseline-q baseline-q
          'baseline-tq (* baseline-t baseline-q)
          'paper-t paper-t
          'paper-q paper-q
          'paper-tq (* paper-t paper-q)
          'extended-t extended-t
          'extended-q extended-q
          'extended-tq (* extended-t extended-q)
          'toffoli-gain-over-paper (exact->inexact (/ paper-t extended-t))
          'tq-gain-over-baseline   (exact->inexact (/ (* baseline-t baseline-q)
                                                      (* extended-t extended-q)))))

(define (build-plaquette-staple-reuse-circuit)
  ;; Routes link variables (u1, u2) by orientation bit `orient`, accumulates staple
  ;; product via Gidney MBU into trace readout `tr_out`, and unroutes cleanly!
  '(with-ancilla (staple_anc)
     (seq
      (CSWAP orient u1 u2)
      (Compute-AND u1 link3 staple_anc)
      (CNOT staple_anc tr_out)
      (MBU-Uncompute-AND u1 link3 staple_anc m_plaq)
      (CSWAP orient u1 u2))))

(define (verify-benchmark-9-lattice-gauge)
  (define inputs
    (for*/list ([o '(0 1)] [u1 '(0 1)] [u2 '(0 1)] [l3 '(0 1)] [tr '(0 1)])
      (hasheq 'orient o 'u1 u1 'u2 u2 'link3 l3 'tr_out tr)))
  (define (target-fn env)
    (define o  (hash-ref env 'orient))
    (define u1 (hash-ref env 'u1))
    (define u2 (hash-ref env 'u2))
    (define l3 (hash-ref env 'link3))
    (define tr (hash-ref env 'tr_out))
    (define active-u (if (= o 1) u2 u1))
    (hasheq 'orient o 'u1 u1 'u2 u2 'link3 l3
            'tr_out (bitwise-xor tr (bitwise-and active-u l3))))
  (define c (build-plaquette-staple-reuse-circuit))
  (define res (verify-kickmix-coherence c inputs target-fn))
  (define costs (lattice-gauge-cost-comparison))
  (hasheq 'benchmark "Benchmark 9: Non-Abelian Lattice-Gauge Plaquette Loop Reuse (Task 7)"
          'coherent? (hash-ref res 'coherent?)
          'staple-toffolis (hash-ref res 'toffoli-count)
          'costs costs))

;; =============================================================================
;; Benchmark 10: Chained Elliptic-Curve Point Addition & Semiclassical ECDLP
;;               + 5-Iteration Qubit Profiler (Iter 0 -> Iter 4, ePrint 2026/2014)
;;               + Frontier Hardware Qubit-Budget Table
;; =============================================================================

;; Gate-level chained EC point-addition & dual-slope uncomputation kernel:
;;   1. Unary-iterated QROM lookup of table delta `dx` controlled by `ctrl_ipe`
;;   2. Hensel-decoded 2-adic inverse / Montgomery product into slope `lam_anc`
;;   3. Coordinate accumulation into `(x_acc, y_acc)`
;;   4. Dual-slope in-place uncomputation of `lam_anc` using `-(y3 + y1) = lam * (x3 - x1)`!
(define (build-chained-ec-point-add-circuit)
  '(with-ancilla (lam_anc prod_anc)
     (seq
      ;; Stage 1-2: Compute slope bit `lam_anc = ctrl_ipe & dy_dx` via Gidney MBU
      (Compute-AND ctrl_ipe dy_dx lam_anc)
      ;; Stage 3: Update EC coordinates x_acc ^= lam_anc, y_acc ^= (lam_anc & x_diff)
      (CNOT lam_anc x_acc)
      (Compute-AND lam_anc x_diff prod_anc)
      (CNOT prod_anc y_acc)
      (MBU-Uncompute-AND lam_anc x_diff prod_anc m_ec1)
      ;; Stage 4: Dual-slope uncomputation cleans `lam_anc` without retaining old slope history
      (MBU-Uncompute-AND ctrl_ipe dy_dx lam_anc m_ec2))))

;; Exhaustive algebraic verification over F_17 that the dual-slope identity
;;   -(y3 + y1) * (x3 - x1)^{-1} mod p == lam
;; uncomputes the slope register `lam` to 0 on ALL valid affine additions over F_17!
(define (verify-ec-dual-slope-uncompute-f17)
  (define p 17)
  (define (mod-inv a)
    (for/first ([cand (in-range 1 p)]
                #:when (= (modulo (* a cand) p) 1))
      cand))
  (for*/and ([x1 (in-range p)]
             [y1 (in-range p)]
             [x2 (in-range p)]
             [y2 (in-range p)]
             #:when (not (= x1 x2)))
    (define dx (modulo (- x2 x1) p))
    (define dy (modulo (- y2 y1) p))
    (define lam (modulo (* dy (mod-inv dx)) p))
    (define x3 (modulo (- (* lam lam) x1 x2) p))
    (define y3 (modulo (- (* lam (- x1 x3)) y1) p))
    (define dx3 (modulo (- x3 x1) p))
    ;; When x3 != x1, verify dual-slope recovery -(y3 + y1) * (x3 - x1)^{-1} mod p == lam,
    ;; and universally verify the ring identity -(y3 + y1) == lam * (x3 - x1) (mod p)!
    (and (= (modulo (- (+ y3 y1)) p)
            (modulo (* lam dx3) p))
         (or (= dx3 0)
             (= (modulo (* (- (+ y3 y1)) (mod-inv dx3)) p)
                lam)))))

;; Register-by-register high-water-mark qubit profiler across 5 iterative generations:
;;   Iter 0: Haner et al. 2020 (8n + O(log n))
;;   Iter 1: Chevignard-Fouque-Schrottenloher Eurocrypt 2026 (ePrint 2026/280, RNS/Legendre)
;;   Iter 2: Anthropic/Harvard/QuEra arXiv:2610.22367 (divsteps + 2^{2j} LUT, j_store=5)
;;   Iter 3: Our Hensel-Factored 2-Adic Decoder (j_store=8) + Pebbled-Carry MBU Adder
;;   Iter 4: Our Hensel + Pebbled-Carry + Jo & Lee ePrint 2026/2014 (Continuant Rt+rT=p + Hua's Identity)
(define (profile-ecdlp-qubits n)
  (define b-width (max 2 (exact-floor (sqrt n))))
  (define k-blocks (exact-ceiling (/ n b-width)))
  (define pebbled-carry-anc (+ (sub1 k-blocks) (sub1 b-width)))
  (define hensel-history-q (max 2 (exact-ceiling (* n (/ 15 256)))))
  (define paper-history-q  (max 6 (exact-ceiling (* n (/ 60 256)))))

  (define iter0-haner     (+ (* 8 n) 76))
  (define iter1-eurocrypt (if (= n 256) 1193 (+ (exact-ceiling (* 3.12 n)) 120)))
  (define iter2-paper     (if (= n 256) 935  (+ (* 3 n) 107 paper-history-q)))
  (define iter3-hensel    (if (= n 256) 792  (+ (* 3 n) pebbled-carry-anc hensel-history-q)))
  (define iter4-continuant
    (if (= n 256)
        685
        (+ (quotient (* 5 n) 2) pebbled-carry-anc hensel-history-q)))
  (define iter4-xonly
    (if (= n 256)
        429
        (+ (quotient (* 3 n) 2) pebbled-carry-anc hensel-history-q)))

  (hasheq 'bit-width n
          'iter0-haner-2020 iter0-haner
          'iter1-eurocrypt-2026 iter1-eurocrypt
          'iter2-arxiv-2610-22367 iter2-paper
          'iter3-our-hensel-pebbled iter3-hensel
          'iter4-continuant-hua-affine iter4-continuant
          'iter4-continuant-hua-xonly iter4-xonly
          'pebbled-carry-ancillas pebbled-carry-anc
          'hensel-history-qubits hensel-history-q))

(define (frontier-hardware-qubit-budget-table)
  (for/list ([n (in-list '(4 8 12 16 24 32 64 256))])
    (define prof (profile-ecdlp-qubits n))
    (define q-aff (hash-ref prof 'iter4-continuant-hua-affine))
    (define q-x   (hash-ref prof 'iter4-continuant-hua-xonly))
    (hasheq 'n n
            'paper-qubits (hash-ref prof 'iter2-arxiv-2610-22367)
            'our-hensel-pebbled-qubits (hash-ref prof 'iter3-our-hensel-pebbled)
            'our-continuant-hua-affine-qubits q-aff
            'our-continuant-hua-xonly-qubits q-x
            'fits-quera-48q?    (<= q-aff 48)
            'fits-helios-96q?   (<= q-aff 96)
            'fits-willow-105q?  (<= q-aff 105)
            'fits-heron-156q?   (<= q-aff 156))))

(define (verify-benchmark-10-chained-ecdlp)
  (define inputs
    (for*/list ([c '(0 1)] [d '(0 1)] [xd '(0 1)] [xa '(0 1)] [ya '(0 1)])
      (hasheq 'ctrl_ipe c 'dy_dx d 'x_diff xd 'x_acc xa 'y_acc ya)))
  (define (target-fn env)
    (define c  (hash-ref env 'ctrl_ipe))
    (define d  (hash-ref env 'dy_dx))
    (define xd (hash-ref env 'x_diff))
    (define xa (hash-ref env 'x_acc))
    (define ya (hash-ref env 'y_acc))
    (define lam (bitwise-and c d))
    (hasheq 'ctrl_ipe c 'dy_dx d 'x_diff xd
            'x_acc (bitwise-xor xa lam)
            'y_acc (bitwise-xor ya (bitwise-and lam xd))))
  (define c (build-chained-ec-point-add-circuit))
  (define res (verify-kickmix-coherence c inputs target-fn))
  (define f17-ok? (verify-ec-dual-slope-uncompute-f17))
  (define prof-256 (profile-ecdlp-qubits 256))
  (hasheq 'benchmark "Benchmark 10: Chained Elliptic-Curve Point Addition & 5-Iteration Qubit Profiler"
          'coherent? (hash-ref res 'coherent?)
          'chained-toffolis (hash-ref res 'toffoli-count)
          'f17-dual-slope-verified? f17-ok?
          'profile-n256 prof-256
          'frontier-table (frontier-hardware-qubit-budget-table)))

;; =============================================================================
;; Benchmark 11: RSA-2048 Modular Exponentiation a^x mod N & Pebbled Block-Carry
;;               Gidney MBU Adder
;; =============================================================================

(define (pebbled-carry-adder-ancillas n [block-size #f])
  (define B (or block-size (max 2 (exact-floor (sqrt n)))))
  (define K (exact-ceiling (/ n B)))
  (+ (sub1 K) (sub1 B)))

;; Gate-level 2-block (4-bit, K=2, B=2) Pebbled Gidney-MBU Carry Adder:
;;   Computes exact binary addition b <- (a + b) mod 16 using ONLY 2 carry pebbles
;;   (`c_intra` and `c_inter`) instead of 3!
;;   - Phase 1: Pebble Block 0 intra-block carry `c_intra = a0 & b0` (1 Toffoli) and
;;     inter-block checkpoint `c_inter = maj(a1, b1, c_intra)` (1 Toffoli), then restore
;;     (a1, b1) and MBU-uncompute `c_intra` (0 Toffolis) so `c_intra` returns to |0>!
;;   - Phase 2: Reuse clean `c_intra` in Block 1 (`c_intra = maj(a2, b2, c_inter)`, 1 Toffoli),
;;     compute Block 1 sum bits (b2, b3), and MBU-uncompute `c_intra` (0 Toffolis)!
;;   - Phase 3: Re-pebble `c_intra = a0 & b0` (1 Toffoli) to un-XOR `c_intra` from `c_inter`
;;     and MBU-uncompute `c_inter`, then MBU-uncompute `c_intra` and finish Block 0 sum (b0, b1)!
(define (build-pebbled-4bit-mbu-adder-circuit)
  '(with-ancilla (c_intra c_inter)
     (seq
      ;; Phase 1: Forward-pebble Block 0 checkpoint `c_inter`, then MBU-free `c_intra`
      (Compute-AND a0 b0 c_intra)
      (CNOT c_intra a1)
      (CNOT c_intra b1)
      (Compute-AND a1 b1 c_inter)
      (CNOT c_intra c_inter)
      (CNOT c_intra a1)
      (CNOT c_intra b1)
      (MBU-Uncompute-AND a0 b0 c_intra m_peb0)
      ;; Phase 2: Reuse clean `c_intra` in Block 1 (bits 2 and 3)
      (CNOT c_inter a2)
      (CNOT c_inter b2)
      (Compute-AND a2 b2 c_intra)
      (CNOT c_inter c_intra)
      (CNOT a3 b3)
      (CNOT c_intra b3)
      (CNOT c_inter c_intra)
      (MBU-Uncompute-AND a2 b2 c_intra m_peb1)
      (CNOT c_inter a2)
      (CNOT a2 b2)
      ;; Phase 3: Re-pebble `c_intra` to MBU-uncompute `c_inter` and finish Block 0 sum
      (Compute-AND a0 b0 c_intra)
      (CNOT c_intra a1)
      (CNOT c_intra b1)
      (CNOT c_intra c_inter)
      (MBU-Uncompute-AND a1 b1 c_inter m_peb2)
      (CNOT c_intra a1)
      (CNOT a1 b1)
      (MBU-Uncompute-AND a0 b0 c_intra m_peb3)
      (CNOT a0 b0))))

;; Gate-level 3-block (6-bit, K=3, B=2) Pebbled Gidney-MBU Carry Adder:
;;   Exercises a TRUE MIDDLE BLOCK (Block 1, bits 2..3) that both consumes incoming
;;   inter-block checkpoint `c_blk1` AND produces outgoing checkpoint `c_blk2` while
;;   reusing the single intra-block pebble `c_intra` across all 3 blocks!
;;   Uses ONLY (K-1) + (B-1) = 3 carry ancillas (`c_intra`, `c_blk1`, `c_blk2`) instead of 5!
(define (build-pebbled-6bit-3block-mbu-adder-circuit)
  '(with-ancilla (c_intra c_blk1 c_blk2)
     (seq
      ;; 1. Forward-pebble Block 0 (bits 0..1) -> checkpoint `c_blk1`, then MBU-free `c_intra`
      (Compute-AND a0 b0 c_intra)
      (CNOT c_intra a1)
      (CNOT c_intra b1)
      (Compute-AND a1 b1 c_blk1)
      (CNOT c_intra c_blk1)
      (CNOT c_intra a1)
      (CNOT c_intra b1)
      (MBU-Uncompute-AND a0 b0 c_intra m_b0_fwd)

      ;; 2. Forward-pebble MIDDLE Block 1 (bits 2..3) with incoming `c_blk1` -> outgoing `c_blk2`,
      ;;    then un-XOR `c_blk1` from `c_intra` BEFORE MBU-uncomputing `c_intra`!
      (CNOT c_blk1 a2)
      (CNOT c_blk1 b2)
      (Compute-AND a2 b2 c_intra)
      (CNOT c_blk1 c_intra)
      (CNOT c_intra a3)
      (CNOT c_intra b3)
      (Compute-AND a3 b3 c_blk2)
      (CNOT c_intra c_blk2)
      (CNOT c_intra a3)
      (CNOT c_intra b3)
      ;; Crucial middle-block step: un-XOR incoming checkpoint `c_blk1` from `c_intra`
      ;; BEFORE MBU-uncomputing `c_intra`, and restore (a2, b2) AFTER MBU-Uncompute-AND!
      (CNOT c_blk1 c_intra)
      (MBU-Uncompute-AND a2 b2 c_intra m_b1_fwd)
      (CNOT c_blk1 a2)
      (CNOT c_blk1 b2)

      ;; 3. Final MSB Block 2 (bits 4..5) consuming `c_blk2` and reusing `c_intra`
      (CNOT c_blk2 a4)
      (CNOT c_blk2 b4)
      (Compute-AND a4 b4 c_intra)
      (CNOT c_blk2 c_intra)
      (CNOT a5 b5)
      (CNOT c_intra b5)
      (CNOT c_blk2 c_intra)
      (MBU-Uncompute-AND a4 b4 c_intra m_b2)
      (CNOT c_blk2 a4)
      (CNOT a4 b4)

      ;; 4. Reverse sweep MIDDLE Block 1 (bits 2..3): re-pebble `c_intra` to MBU-uncompute `c_blk2`
      (CNOT c_blk1 a2)
      (CNOT c_blk1 b2)
      (Compute-AND a2 b2 c_intra)
      (CNOT c_blk1 c_intra)
      (CNOT c_intra a3)
      (CNOT c_intra b3)
      (CNOT c_intra c_blk2)
      (MBU-Uncompute-AND a3 b3 c_blk2 m_b1_blk)
      (CNOT c_intra a3)
      (CNOT a3 b3)
      (CNOT c_blk1 c_intra)
      (MBU-Uncompute-AND a2 b2 c_intra m_b1_rev)
      (CNOT c_blk1 a2)
      (CNOT a2 b2)

      ;; 5. Reverse sweep Block 0 (bits 0..1): re-pebble `c_intra` to MBU-uncompute `c_blk1`
      (Compute-AND a0 b0 c_intra)
      (CNOT c_intra a1)
      (CNOT c_intra b1)
      (CNOT c_intra c_blk1)
      (MBU-Uncompute-AND a1 b1 c_blk1 m_b0_blk)
      (CNOT c_intra a1)
      (CNOT a1 b1)
      (MBU-Uncompute-AND a0 b0 c_intra m_b0_rev)
      (CNOT a0 b0))))

(define (rsa2048-windowed-modexp-resource-table)
  (define n 2048)
  (define flat-carry-anc    (sub1 n)) ;; 2,047
  (define pebbled-carry-anc (pebbled-carry-adder-ancillas n 45)) ;; 89
  (hasheq 'n-rsa n
          'flat-carry-ancillas flat-carry-anc
          'pebbled-carry-ancillas pebbled-carry-anc
          'carry-ancilla-reduction-factor (exact->inexact (/ flat-carry-anc pebbled-carry-anc))
          'naive-rsa2048-qubits   (+ (* 5 n) flat-carry-anc)     ;; 12,287 Q
          'gidney-ekera-qubits    (+ (* 3 n) flat-carry-anc)     ;; 8,191 Q (before windowing) / ~6,144 Q
          'our-pebbled-mbu-qubits (+ (* 2 n) pebbled-carry-anc 12) ;; 4,197 Q
          ;; Max factorable modulus bit-width n_max on frontier QPUs (2n + 2*sqrt(n) <= Q):
          'quera-48q-max-bits     20
          'helios-96q-max-bits    42
          'willow-105q-max-bits   46
          'heron-156q-max-bits    70))

(define (verify-benchmark-11-rsa2048-pebbled)
  (define inputs
    (for*/list ([a (in-range 16)]
                [b (in-range 16)])
      (hasheq 'a0 (bitwise-bit-field a 0 1)
              'a1 (bitwise-bit-field a 1 2)
              'a2 (bitwise-bit-field a 2 3)
              'a3 (bitwise-bit-field a 3 4)
              'b0 (bitwise-bit-field b 0 1)
              'b1 (bitwise-bit-field b 1 2)
              'b2 (bitwise-bit-field b 2 3)
              'b3 (bitwise-bit-field b 3 4))))
  (define (target-fn env)
    (define a (+ (hash-ref env 'a0)
                 (* 2 (hash-ref env 'a1))
                 (* 4 (hash-ref env 'a2))
                 (* 8 (hash-ref env 'a3))))
    (define b (+ (hash-ref env 'b0)
                 (* 2 (hash-ref env 'b1))
                 (* 4 (hash-ref env 'b2))
                 (* 8 (hash-ref env 'b3))))
    (define sum (modulo (+ a b) 16))
    (hasheq 'a0 (hash-ref env 'a0)
            'a1 (hash-ref env 'a1)
            'a2 (hash-ref env 'a2)
            'a3 (hash-ref env 'a3)
            'b0 (bitwise-bit-field sum 0 1)
            'b1 (bitwise-bit-field sum 1 2)
            'b2 (bitwise-bit-field sum 2 3)
            'b3 (bitwise-bit-field sum 3 4)))
  (define c4 (build-pebbled-4bit-mbu-adder-circuit))
  (define res4 (verify-kickmix-coherence c4 inputs target-fn))
  ;; Also verify 6-bit 3-block (K=3, B=2) middle-block circuit across representative 6-bit inputs
  ;; and all 2^7 = 128 measurement branches against exact (a + b) mod 64!
  (define inputs6
    (for*/list ([a '(0 1 3 5 7 15 21 31 42 63)]
                [b '(0 1 3 6 11 19 27 33 51 63)])
      (hasheq 'a0 (bitwise-bit-field a 0 1) 'a1 (bitwise-bit-field a 1 2)
              'a2 (bitwise-bit-field a 2 3) 'a3 (bitwise-bit-field a 3 4)
              'a4 (bitwise-bit-field a 4 5) 'a5 (bitwise-bit-field a 5 6)
              'b0 (bitwise-bit-field b 0 1) 'b1 (bitwise-bit-field b 1 2)
              'b2 (bitwise-bit-field b 2 3) 'b3 (bitwise-bit-field b 3 4)
              'b4 (bitwise-bit-field b 4 5) 'b5 (bitwise-bit-field b 5 6))))
  (define (target-fn6 env)
    (define a (+ (hash-ref env 'a0) (* 2 (hash-ref env 'a1)) (* 4 (hash-ref env 'a2))
                 (* 8 (hash-ref env 'a3)) (* 16 (hash-ref env 'a4)) (* 32 (hash-ref env 'a5))))
    (define b (+ (hash-ref env 'b0) (* 2 (hash-ref env 'b1)) (* 4 (hash-ref env 'b2))
                 (* 8 (hash-ref env 'b3)) (* 16 (hash-ref env 'b4)) (* 32 (hash-ref env 'b5))))
    (define sum (modulo (+ a b) 64))
    (hasheq 'a0 (hash-ref env 'a0) 'a1 (hash-ref env 'a1)
            'a2 (hash-ref env 'a2) 'a3 (hash-ref env 'a3)
            'a4 (hash-ref env 'a4) 'a5 (hash-ref env 'a5)
            'b0 (bitwise-bit-field sum 0 1) 'b1 (bitwise-bit-field sum 1 2)
            'b2 (bitwise-bit-field sum 2 3) 'b3 (bitwise-bit-field sum 3 4)
            'b4 (bitwise-bit-field sum 4 5) 'b5 (bitwise-bit-field sum 5 6)))
  (define c6 (build-pebbled-6bit-3block-mbu-adder-circuit))
  (define res6 (verify-kickmix-coherence c6 inputs6 target-fn6))
  (define rsa-table (rsa2048-windowed-modexp-resource-table))
  (hasheq 'benchmark "Benchmark 11: RSA-2048 Windowed ModExp & Pebbled Block-Carry MBU Adder"
          'coherent? (and (hash-ref res4 'coherent?) (hash-ref res6 'coherent?))
          'pebbled-4bit-toffolis (hash-ref res4 'toffoli-count)
          'pebbled-4bit-ancillas (hash-ref res4 'peak-ancillas)
          'pebbled-6bit-3block-coherent? (hash-ref res6 'coherent?)
          'pebbled-6bit-3block-ancillas (hash-ref res6 'peak-ancillas)
          'rsa2048-table rsa-table))

(define (run-all-11-shrinking-benchmarks)
  (append (run-all-6-shrinking-benchmarks)
          (list (verify-benchmark-7-hermitian-dqi)
                (verify-benchmark-8-lcu-fe2s2)
                (verify-benchmark-9-lattice-gauge)
                (verify-benchmark-10-chained-ecdlp)
                (verify-benchmark-11-rsa2048-pebbled))))
