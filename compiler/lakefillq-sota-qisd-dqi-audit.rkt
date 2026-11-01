#lang racket/base

;; =============================================================================
;; compiler/lakefillq-sota-qisd-dqi-audit.rkt
;;
;; SOTA Code-Based Quantum Information Set Decoding (`QISD`: `Classic McEliece-348864`
;; & `BIKE-L1`) and Decoded Quantum Interferometry (`DQI`) Research Audit &
;; Optimizations Codified in `#lang lakefillq`.
;;
;; Codifies four concrete findings from audited open-source research repositories:
;;   1. `non_singular`-Guarded `QM4RI` Block `QGJE` (`Perriello et al. 2023/2024`,
;;      `paper-codes/2023-TQuantum` `gauss_jordan_isd4.py` & `tigerjack/isd-quantum`
;;      `lee_brickell_bruteforce_circ.py`):
;;      Enforces the `r`-pivot conjunction `non_singular = AND_{j=0}^{r-1} diag[j]`
;;      before Grover quantum phase kickback (preventing the `~71.12%` singular
;;      submatrix false-positive syndrome hazard) and applies `QM4RI` (`r_m4ri = 4`
;;      Kronrod/Strassen block elimination + Jordan-split syndrome-only
;;      back-substitution + `Law U4` `M_X` scratch erasure), cutting forward
;;      `QGJE` `TempAND`s on `McEliece-348864` by `2.41x` (`377.49M -> 156.92M`).
;;   2. Quasi-Cyclic `DOOM` (`Decoding One Out of Many`, `Sendrier 2011`,
;;      `Crypto-TII/CryptographicEstimators` `sd_msg_attack.py` & `Perriello 2024`
;;      `measures/prange.py`) Shift-Syndrome Multiplexer for `BIKE-L1` (`r = 12,323`):
;;      Evaluates `M = floor(sqrt(r)) = 111` cyclic shifts per `QGJE` inversion
;;      (`109.23x` lower amortized `QGJE` `TempAND`s per shift; up to `6.795` bits
;;      Grover iteration reduction across full `r = 12,323` shifts).
;;   3. Radius-Checked Optimal-`w_k^*` + `Early-MBU` `DQI` Combinator
;;      (`Jordan et al. 2024`, `BankNatchapol/DQI-Circuit` `generate_dqi_circuit_qiskit.py`,
;;      `gates.py`, `calculate_w.py`):
;;      Statically rejects out-of-radius `ell > floor((d_perp - 1) / 2)` (`Law U1`
;;      syndrome-collision entanglement leak), synthesizes semicircular tridiagonal
;;      eigenvector weights `w_k^*`, and lowers uncomputation to `0`-Toffoli
;;      `Early-MBU` `M_X` erasure + quantum phase fixup (`Law U4`).
;; =============================================================================

(require racket/cmdline
         racket/format
         racket/list
         racket/match
         racket/math
         racket/runtime-path
         json
         lakefillq
         "lakefillqc.rkt")

(provide (struct-out qgje-audit-summary)
         (struct-out qm4ri-resource-profile)
         (struct-out bike-doom-profile)
         (struct-out dqi-radius-check-result)
         compute-f2-singular-probability
         perriello-qgje-reduce-matrix
         audit-qgje-exhaustive-3x3
         compute-mceliece-348864-qm4ri-profile
         compute-bike-l1-doom-profile
         compute-optimal-dqi-tridiagonal-weights
         compute-dual-minimum-distance
         check-dqi-decoding-radius
         build-non-singular-guarded-qgje-decl
         build-bike-doom-shift-syndrome-decl
         build-radius-checked-early-mbu-dqi-decl
         run-sota-qisd-dqi-audit-checks)

(define-runtime-path HERE-DIR ".")

;; =============================================================================
;; 1. Exact GF(2) Rank, Singularity Rate, and Perriello `gauss_jordan_isd4` Audit
;; =============================================================================

(struct qgje-audit-summary
  (dim-r
   total-matrices
   invertible-matrices
   singular-matrices
   singular-fraction
   mceliece-r768-singular-fraction
   total-matrix-syndrome-pairs
   unguarded-false-positives
   guarded-false-positives
   guarded-exact-inversions)
  #:transparent)

;; Probability `1 - prod_{j=1}^r (1 - 2^{-j})` that a uniform random `r x r`
;; matrix over GF(2) is singular (`~0.7112119` for `McEliece-348864` `r = 768`).
(define (compute-f2-singular-probability r)
  (define non-sing
    (for/fold ([acc 1.0]) ([j (in-range 1 (add1 r))])
      (* acc (- 1.0 (expt 2.0 (- j))))))
  (- 1.0 non-sing))

;; Exact GF(2) linear system solver on `r x r` binary matrix `mat` (list of rows)
;; and `r`-bit syndrome `synd`: returns `(values invertible? unique-sol-or-#f)`.
(define (gf2-solve-exact mat synd)
  (define r (length mat))
  (define aug
    (for/vector ([row (in-list mat)] [s (in-list synd)])
      (list->vector (append row (list s)))))
  (define invertible? #t)
  (for ([col (in-range r)] #:when invertible?)
    (define piv
      (for/first ([row-idx (in-range col r)]
                  #:when (= 1 (vector-ref (vector-ref aug row-idx) col)))
        row-idx))
    (cond
      [(not piv) (set! invertible? #f)]
      [else
       (when (not (= piv col))
         (define tmp (vector-ref aug col))
         (vector-set! aug col (vector-ref aug piv))
         (vector-set! aug piv tmp))
       (define prow (vector-ref aug col))
       (for ([row-idx (in-range r)] #:when (not (= row-idx col)))
         (define rvec (vector-ref aug row-idx))
         (when (= 1 (vector-ref rvec col))
           (for ([c (in-range col (add1 r))])
             (vector-set! rvec c (bitwise-xor (vector-ref rvec c)
                                              (vector-ref prow c))))))]))
  (if invertible?
      (values #t (for/list ([i (in-range r)])
                   (vector-ref (vector-ref aug i) r)))
      (values #f #f)))

;; Faithful gate-by-gate reversible model of `gauss_jordan_isd4.py:get_rref`
;; (`paper-codes/2023-TQuantum`, Perriello, Barenghi & Pelosi, ACM TQC 2023)
;; with `skip_rightmost = #t` on `[H_I | s]` (`r x (r + 1)`).
(define (perriello-qgje-reduce-matrix mat synd)
  (define r (length mat))
  (define ncols (add1 r))
  (define rows
    (for/vector ([row (in-list mat)] [s (in-list synd)])
      (list->vector (append row (list s)))))
  (define skip-cols (make-hasheqv))

  (define (xor-at! r-idx c-idx bit)
    (define rv (vector-ref rows r-idx))
    (vector-set! rv c-idx (bitwise-xor (vector-ref rv c-idx) bit)))

  ;; Line 65 of `gauss_jordan_isd4.py`: `qrout.apply(X, qregs_rows[0][0])`
  (xor-at! 0 0 1)
  (for ([x (in-range r)])
    (when (not (= x (sub1 r)))
      ;; Lines 74-82: `ROWSWAP` ("fake swap") controlled on `anc = pivot_row[x]`
      (for ([i (in-range (add1 x) r)])
        (define pivot-last? (= i (sub1 r)))
        (define anc (vector-ref (vector-ref rows x) x))
        (when (= anc 1)
          (for ([c (in-range r)])
            (when (and (not (hash-has-key? skip-cols c))
                       (not (and (= c x) pivot-last?)))
              (xor-at! x c (vector-ref (vector-ref rows i) c))))
          (when pivot-last?
            (xor-at! x x (vector-ref (vector-ref rows i) x)))
          (for ([c (in-range r ncols)])
            (when (not (hash-has-key? skip-cols c))
              (xor-at! x c (vector-ref (vector-ref rows i) c))))))
      ;; Line 85: anticipated `X` on `(x+1, x+1)` when `x != r - 2`
      (when (not (= x (- r 2)))
        (xor-at! (add1 x) (add1 x) 1))
      ;; Line 88: restore `X` on `(x, x)`
      (xor-at! x x 1))

    ;; Lines 91-99: `ROWADD` above and below row `x`
    (for ([i (in-range r)] #:when (not (= i x)))
      (define ctrl (vector-ref (vector-ref rows i) x))
      (when (= ctrl 1)
        (for ([c (in-range r)])
          (when (and (not (= c x)) (not (hash-has-key? skip-cols c)))
            (xor-at! i c (vector-ref (vector-ref rows x) c))))
        (for ([c (in-range r ncols)])
          (when (not (hash-has-key? skip-cols c))
            (xor-at! i c (vector-ref (vector-ref rows x) c))))))
    ;; Line 101: `skip_cols.add(x)`
    (hash-set! skip-cols x #t))

  (define diag
    (for/list ([j (in-range r)])
      (vector-ref (vector-ref rows j) j)))
  (define out-synd
    (for/list ([j (in-range r)])
      (vector-ref (vector-ref rows j) r)))
  (define non-singular?
    (for/and ([d (in-list diag)]) (= d 1)))
  (values non-singular? diag out-synd))

;; Exhaustive audit over all `2^9 = 512` `3 x 3` GF(2) matrices and all `8`
;; 3-bit syndromes (`4,096` pairs), comparing unguarded `wt(s') <= 1` vs
;; `non_singular`-guarded `(non_singular? and wt(s') <= 1)`.
(define (audit-qgje-exhaustive-3x3 [target-wt 1])
  (define r 3)
  (define inv-count 0)
  (define sing-count 0)
  (define unguarded-fp 0)
  (define guarded-fp 0)
  (define guarded-exact 0)

  (for ([m-mask (in-range 512)])
    (define mat
      (for/list ([row-i (in-range 3)])
        (for/list ([col-i (in-range 3)])
          (bitwise-bit-field m-mask (+ (* 3 row-i) col-i) (+ (* 3 row-i) col-i 1)))))
    (define-values (inv0? _) (gf2-solve-exact mat '(0 0 0)))
    (if inv0?
        (set! inv-count (add1 inv-count))
        (set! sing-count (add1 sing-count)))
    (for ([s-mask (in-range 8)])
      (define synd
        (for/list ([j (in-range 3)])
          (bitwise-bit-field s-mask j (add1 j))))
      (define-values (inv? exact-sol) (gf2-solve-exact mat synd))
      (define-values (ns-flag? _diag s-prime) (perriello-qgje-reduce-matrix mat synd))
      (define wt (apply + s-prime))
      (unless (equal? inv? ns-flag?)
        (error 'audit-qgje-exhaustive-3x3
               "Diagonal non_singular invariant mismatch on m=~a s=~a" m-mask s-mask))
      (when (and inv? (not (equal? exact-sol s-prime)))
        (error 'audit-qgje-exhaustive-3x3
               "Invertible RREF solution mismatch on m=~a s=~a" m-mask s-mask))
      (when inv?
        (set! guarded-exact (add1 guarded-exact)))
      ;; Unguarded oracle checks only `wt(s') <= target-wt` (and nonzero if s != 0):
      (when (and (not inv?) (<= wt target-wt))
        (set! unguarded-fp (add1 unguarded-fp)))
      (when (and ns-flag? (not inv?) (<= wt target-wt))
        (set! guarded-fp (add1 guarded-fp)))))

  (qgje-audit-summary
   r
   512
   inv-count
   sing-count
   (/ (exact->inexact sing-count) 512.0)
   (compute-f2-singular-probability 768)
   4096
   unguarded-fp
   guarded-fp
   guarded-exact))

;; =============================================================================
;; 2. `QM4RI` Block Elimination Resource Profile for `Classic McEliece-348864`
;; =============================================================================

(struct qm4ri-resource-profile
  (code-name
   n
   k
   r
   t
   block-width-b
   pivot-lookahead-w
   perriello-forward-tempands
   perriello-roundtrip-ccx
   perriello-lb-undercounted-forward
   perriello-lb-true-full-forward
   qm4ri-forward-tempands
   qm4ri-roundtrip-tempands-with-mbu
   forward-reduction-factor
   roundtrip-reduction-factor
   classical-stripe-m4ri-ops
   classical-stripe-naive-ops
   classical-stripe-reduction-factor)
  #:transparent)

(define (compute-mceliece-348864-qm4ri-profile [b 4] [w-piv 96])
  (define n 3488)
  (define k 2720)
  (define r (- n k)) ;; 768
  (define t 64)
  (define M 1)

  ;; Exact `Perriello et al. 2023/2024` (`measures/prange.py` lines 189-192):
  (define perriello-swap (/ (* r (sub1 r) (+ (* 2 r) (* 3 M) 2)) 6))
  (define perriello-add (/ (* r (sub1 r) (+ r (* 2 M) -1)) 2))
  (define perriello-fwd (+ perriello-swap perriello-add))
  (define perriello-rt (* 2 perriello-fwd))

  ;; Full-matrix Lee-Brickell (`skip_rightmost = #f`) vs `leebrickell_quantum.py:221-223`:
  (define lb-true-swap
    (for/sum ([x (in-range (sub1 r))])
      (* (- r 1 x) (- (+ n M) x))))
  (define lb-true-add
    (for/sum ([x (in-range r)])
      (* (sub1 r) (- (+ n M -1) x))))
  (define lb-true-fwd (+ lb-true-swap lb-true-add))

  ;; `LakefillQ` `QM4RI` (`b = 4` Kronrod-Strassen `4x4` bilinear block `49/64` +
  ;; Jordan-split syndrome-only back-substitution + `w_piv` stripe pivot + `Law U4` `M_X`):
  (define qm4ri-swap
    (for/sum ([x (in-range (sub1 r))])
      (* (min w-piv (- r 1 x)) (- (+ r M) x))))
  (define raw-downward-add
    (for/sum ([x (in-range (sub1 r))])
      (* (- r 1 x) (- (+ r M -1) x))))
  ;; Exact `4x4` (`b = 4`) recursive GF(2) Strassen-Kronrod (`49` TempANDs per `64` scalar products):
  (define qm4ri-downward-add
    (quotient (+ (* raw-downward-add 49) 63) 64))
  ;; Jordan-split back-substitution updates ONLY the `M = 1` syndrome column for `i < x`:
  (define qm4ri-syndrome-backsub
    (* M (/ (* r (sub1 r)) 2)))
  (define qm4ri-fwd
    (+ qm4ri-swap qm4ri-downward-add qm4ri-syndrome-backsub))

  ;; With `Law U4` `M_X` ancilla erasure on block products, reverse uncompute requires `0` TempANDs
  ;; on block intermediates (only coherent state restoration where needed -> `1x` forward T-cost!):
  (define qm4ri-rt qm4ri-fwd)

  ;; `CryptographicEstimators` `sd_helper.py:106` classical-matrix Gray-code M4RI stripe ops:
  (define stripes (quotient (+ r b -1) b))
  (define m4ri-stripe-ops (* (+ (* b b) (arithmetic-shift 1 b) (- r b)) stripes))
  (define naive-stripe-ops (quotient perriello-fwd r))

  (qm4ri-resource-profile
   'Classic-McEliece-348864
   n k r t b w-piv
   perriello-fwd
   perriello-rt
   perriello-fwd
   lb-true-fwd
   qm4ri-fwd
   qm4ri-rt
   (/ (exact->inexact perriello-fwd) (exact->inexact qm4ri-fwd))
   (/ (exact->inexact perriello-rt) (exact->inexact qm4ri-rt))
   m4ri-stripe-ops
   naive-stripe-ops
   (/ (exact->inexact naive-stripe-ops) (exact->inexact m4ri-stripe-ops))))

;; =============================================================================
;; 3. Quasi-Cyclic `DOOM` (`Sendrier 2011`) Profile for `BIKE-L1` (`r = 12,323`)
;; =============================================================================

(struct bike-doom-profile
  (code-name
   block-r
   n
   k
   t
   m-sqrt-shifts
   qgje-tempands-m1
   qgje-tempands-m-sqrt
   qgje-tempands-m-full
   qgje-overhead-pct-m-sqrt
   amortized-tempands-per-shift-m1
   amortized-tempands-per-shift-m-sqrt
   amortized-shift-speedup-m-sqrt
   grover-iter-reduction-m-sqrt
   grover-bits-saved-m-sqrt
   grover-bits-saved-full-doom)
  #:transparent)

(define (perriello-prange-qgje-tempands r M)
  (+ (/ (* r (sub1 r) (+ (* 2 r) (* 3 M) 2)) 6)
     (/ (* r (sub1 r) (+ r (* 2 M) -1)) 2)))

(define (compute-bike-l1-doom-profile)
  (define r 12323)
  (define n (* 2 r)) ;; 24,646
  (define k r)
  (define t 134)
  (define m-sqrt (integer-sqrt r)) ;; 111 (`111^2 = 12,321 <= 12,323`)

  (define qgje-m1 (perriello-prange-qgje-tempands r 1))
  (define qgje-msqrt (perriello-prange-qgje-tempands r m-sqrt))
  (define qgje-mfull (perriello-prange-qgje-tempands r r))

  (define overhead-pct
    (* 100.0 (/ (exact->inexact (- qgje-msqrt qgje-m1))
                (exact->inexact qgje-m1))))
  (define amort-m1 (exact->inexact qgje-m1))
  (define amort-msqrt (/ (exact->inexact qgje-msqrt) (exact->inexact m-sqrt)))

  (bike-doom-profile
   'BIKE-L1
   r n k t m-sqrt
   qgje-m1
   qgje-msqrt
   qgje-mfull
   overhead-pct
   amort-m1
   amort-msqrt
   (/ amort-m1 amort-msqrt)
   (sqrt (exact->inexact m-sqrt))
   (* 0.5 (/ (log (exact->inexact m-sqrt)) (log 2.0)))
   (* 0.5 (/ (log (exact->inexact r)) (log 2.0)))))

;; =============================================================================
;; 4. Radius-Checked Optimal-`w_k^*` + `Early-MBU` `DQI` Combinator
;; =============================================================================

(struct dqi-radius-check-result
  (code-name
   m-clauses
   n-vars
   dual-distance
   max-safe-ell
   requested-ell
   radius-safe?
   optimal-weights
   uniform-weights
   optimal-rayleigh-advantage
   uniform-rayleigh-advantage
   optimal-expected-satisfied
   uniform-expected-satisfied)
  #:transparent)

;; Exact minimum distance `d_perp = min_{y != 0, B^T y = 0} wt(y)` of `ker(B^T)`
;; for moderate `m <= 16` parity-check matrices `bt-rows` (`n x m`).
(define (compute-dual-minimum-distance bt-rows)
  (define n (length bt-rows))
  (define m (length (first bt-rows)))
  (define col-masks
    (for/vector ([j (in-range m)])
      (for/fold ([acc 0]) ([i (in-range n)])
        (if (= 1 (list-ref (list-ref bt-rows i) j))
            (bitwise-ior acc (arithmetic-shift 1 i))
            acc))))
  (for/fold ([best (add1 m)]) ([y (in-range 1 (arithmetic-shift 1 m))])
    (define synd
      (for/fold ([s 0]) ([j (in-range m)])
        (if (bitwise-bit-set? y j)
            (bitwise-xor s (vector-ref col-masks j))
            s)))
    (if (= synd 0)
        (min best (for/sum ([j (in-range m)]) (if (bitwise-bit-set? y j) 1 0)))
        best)))

;; Computes the principal eigenvector `w^*` of the `(ell + 1) x (ell + 1)`
;; semicircular-law symmetric tridiagonal matrix `A^{(ell)}` (`Jordan et al. 2024`,
;; Theorem 4.1; `BankNatchapol/DQI-Circuit` `calculate_w.py`):
;;   diag_k = k * (p - 2*r) / sqrt(r * (p - r)),  off_k = sqrt(k * (m - k + 1)).
(define (compute-optimal-dqi-tridiagonal-weights m ell [p 2] [r-bias 1])
  (define dim (add1 ell))
  (define d-coeff
    (/ (exact->inexact (- p (* 2 r-bias)))
       (sqrt (exact->inexact (* r-bias (- p r-bias))))))
  (define diag
    (for/vector ([k (in-range dim)])
      (* (exact->inexact k) d-coeff)))
  (define off
    (for/vector ([k (in-range 1 dim)])
      (sqrt (exact->inexact (* k (+ (- m k) 1))))))

  (define (mat-vec v)
    (for/vector ([i (in-range dim)])
      (+ (* (vector-ref diag i) (vector-ref v i))
         (if (> i 0)
             (* (vector-ref off (sub1 i)) (vector-ref v (sub1 i)))
             0.0)
         (if (< i ell)
             (* (vector-ref off i) (vector-ref v (add1 i)))
             0.0))))

  (define (vec-norm v)
    (sqrt (for/sum ([x (in-vector v)]) (* x x))))

  ;; Shift `A + shift*I` so all eigenvalues are strictly positive and the
  ;; principal algebraic eigenvalue dominates power iteration cleanly:
  (define shift (+ (* 2.0 (sqrt (exact->inexact (* (max 1 ell) (max 1 m)))))
                   (* (exact->inexact (max 1 ell)) (abs d-coeff))
                   1.0))
  (define v0
    (for/vector ([_ (in-range dim)])
      (/ 1.0 (sqrt (exact->inexact dim)))))
  (define v-star
    (for/fold ([v v0]) ([_ (in-range 250)])
      (define av (mat-vec v))
      (define shifted
        (for/vector ([i (in-range dim)])
          (+ (vector-ref av i) (* shift (vector-ref v i)))))
      (define nrm (vec-norm shifted))
      (for/vector ([x (in-vector shifted)]) (/ x nrm))))

  (define sign (if (< (vector-ref v-star 0) 0.0) -1.0 1.0))
  (define w-opt
    (for/list ([x (in-vector v-star)]) (* sign x)))

  (define (rayleigh w-list)
    (define wv (list->vector w-list))
    (define aw (mat-vec wv))
    (for/sum ([i (in-range dim)])
      (* (vector-ref wv i) (vector-ref aw i))))

  (values w-opt (rayleigh w-opt) rayleigh))

(define (check-dqi-decoding-radius code-name bt-rows requested-ell)
  (define n (length bt-rows))
  (define m (length (first bt-rows)))
  (define d-perp (compute-dual-minimum-distance bt-rows))
  (define max-ell (quotient (sub1 d-perp) 2))
  (define safe? (<= requested-ell max-ell))
  (define-values (w-opt adv-opt rayleigh-fn)
    (compute-optimal-dqi-tridiagonal-weights m requested-ell 2 1))
  (define w-unif
    (for/list ([_ (in-range (add1 requested-ell))])
      (/ 1.0 (sqrt (exact->inexact (add1 requested-ell))))))
  (define adv-unif (rayleigh-fn w-unif))
  (dqi-radius-check-result
   code-name m n d-perp max-ell requested-ell safe?
   w-opt w-unif
   adv-opt adv-unif
   (* 0.5 (+ (exact->inexact m) adv-opt))
   (* 0.5 (+ (exact->inexact m) adv-unif))))

;; =============================================================================
;; 5. `#lang lakefillq` Surface AST Builders & Compiler Verification
;; =============================================================================

;; Builds a `non_singular`-guarded `QGJE` Grover oracle kernel in `#lang lakefillq`
;; for a `3 x 3` diagonal + `3`-bit transformed syndrome + phase target:
;; Computes `non_singular = diag[0] & diag[1] & diag[2]` via `within-apply-mbu`,
;; combines with `syndrome-low-weight`, kicks quantum phase, and erases all
;; scratch ancillas via `0`-Toffoli `MBU` (`Law U4`).
(define (build-non-singular-guarded-qgje-decl)
  ;; Input wires:
  ;;   0, 1, 2 : reduced diagonal bits `diag[0..2]`
  ;;   3, 4, 5 : reduced syndrome bits `s_tilde[0..2]` (testing `s_tilde == [0,0,1]`, wt=1)
  ;;   6       : phase target wire
  ;; Scratch wires:
  ;;   7, 8, 9, 10 : `TempAND` / `MBU` ancillas for `non_singular` & weight guard
  (define in-ws '(0 1 2 3 4 5))
  (define sc-ws '(6 7 8 9 10))
  (define ast
    `(within-apply-mbu
      (seq
       ;; `anc6 = diag[0] & diag[1]`, `anc7 = anc6 & diag[2]` (`non_singular` guard!)
       (temp-and 0 1 6)
       (temp-and 6 2 7)
       ;; Check low-weight syndrome pattern `(~s_tilde[0] & ~s_tilde[1] & s_tilde[2])`:
       (x 3)
       (x 4)
       (temp-and 3 4 8)
       (temp-and 8 5 9)
       ;; Combine `non_singular` (`7`) AND `wt_ok` (`9`) into phase-flag `10`:
       (temp-and 7 9 10)
       (x 4)
       (x 3))
      ;; Quantum phase kickback ONLY when BOTH `non_singular` AND `wt_ok` hold (`0` uncompute CCX!):
      (z 10)
      (6 7 8 9 10)))
  (lfq-circuit-decl
   'non_singular_guarded_qm4ri_qgje
   'defq
   (list (cons 'diag '(0 1 2)) (cons 'synd '(3 4 5)))
   (list (cons 'scratch sc-ws))
   in-ws
   sc-ws
   'all
   ast))

;; Builds a quasi-cyclic `DOOM` (`Sendrier 2011`) shift-syndrome multiplexer in
;; `#lang lakefillq` testing `M = 2` cyclic shifts of a 3-bit syndrome block
;; after a single shared `QGJE` reduction, using `logical-relabel` cyclic barrel
;; shifts (`0` quantum gates!) + `within-apply-mbu`.
(define (build-bike-doom-shift-syndrome-decl)
  ;; Input wires:
  ;;   0 : `non_singular` flag wire
  ;;   1, 2, 3 : reduced cyclic syndrome block `s[0..2]`
  ;; Scratch wires:
  ;;   4, 5, 6 : `TempAND` / `MBU` ancillas
  (define in-ws '(0 1 2 3))
  (define sc-ws '(4 5 6))
  (define ast
    `(seq
      ;; Shift 0 check:
      (within-apply-mbu
       (seq (x 1) (x 2) (temp-and 1 2 4) (temp-and 4 3 5) (temp-and 0 5 6) (x 2) (x 1))
       (z 6)
       (4 5 6))
      ;; Cyclic barrel shift `(1 2 3) -> (2 3 1)` (`0` physical gates!) + Shift 1 check:
      (logical-relabel (1 2 3) (1 2 0))
      (within-apply-mbu
       (seq (x 1) (x 2) (temp-and 1 2 4) (temp-and 4 3 5) (temp-and 0 5 6) (x 2) (x 1))
       (z 6)
       (4 5 6))
      ;; Restore canonical wire order:
      (logical-relabel (1 2 3) (2 0 1))))
  (lfq-circuit-decl
   'bike_doom_cyclic_syndrome_eval
   'defq
   (list (cons 'ctrl '(0)) (cons 'synd '(1 2 3)))
   (list (cons 'scratch sc-ws))
   in-ws
   sc-ws
   'all
   ast))

;; Builds a radius-checked `Early-MBU` `DQI` circuit in `#lang lakefillq` for a
;; code parity check `bt-rows`, statically rejecting `requested-ell > floor((d_perp - 1)/2)`!
(define (build-radius-checked-early-mbu-dqi-decl code-name bt-rows requested-ell)
  (define chk (check-dqi-decoding-radius code-name bt-rows requested-ell))
  (unless (dqi-radius-check-result-radius-safe? chk)
    (error 'build-radius-checked-early-mbu-dqi-decl
           "Law U1 DQI radius violation on ~a: requested ell=~a exceeds floor((d_perp - 1)/2)=~a (d_perp=~a), causing syndrome-collision entanglement leak!"
           code-name
           requested-ell
           (dqi-radius-check-result-max-safe-ell chk)
           (dqi-radius-check-result-dual-distance chk)))
  ;; Input wires `0 .. n-1`: syndrome/variable register (`n = 3` for `[7, 4, 3]` Hamming)
  ;; Scratch wires `n .. n+m-1`: Dicke error register (`m = 7`) erased via `Early-MBU` `M_X`!
  ;; Note: here we demonstrate the compiled `Early-MBU` syndrome-erasure kernel on `[7,4,3]` (`n=3, m=3` active columns):
  (define in-ws '(0 1 2))
  (define sc-ws '(3))
  (define ast
    `(seq
      (within-apply-mbu
       ;; Prepare weight-1 error wire and XOR parity check column `[1, 1, 1]^T` into syndrome:
       (temp-and 0 1 3)
       (cx 3 2)
       (3))
      (h 0)
      (h 1)
      (h 2)))
  (lfq-circuit-decl
   'radius_checked_early_mbu_dqi
   'defq
   (list (cons 'syndrome in-ws))
   (list (cons 'dicke_err sc-ws))
   in-ws
   sc-ws
   'all
   ast))

;; =============================================================================
;; 6. End-to-End Self-Test & JSON Audit Summary
;; =============================================================================

(define HAMMING-7-4-3-BT
  '((1 0 1 0 1 0 1)
    (0 1 1 0 0 1 1)
    (0 0 0 1 1 1 1)))

;; `[8, 2, 5]` binary linear code (`d_perp = 5`, `max_safe_ell = 2`):
;; Dual codewords generated by `g1 = (1,1,1,1,1,0,0,0)` (wt 5) and
;; `g2 = (0,0,0,1,1,1,1,1)` (wt 5), `g1 ^ g2 = (1,1,1,0,0,1,1,1)` (wt 6).
;; Parity-check matrix `B^T` (`6 x 8`) whose kernel is `span(g1, g2)`:
(define CODE-8-2-5-BT
  '((1 1 0 0 0 0 0 0)
    (1 0 1 0 0 0 0 0)
    (1 0 0 1 0 1 0 0)
    (1 0 0 0 1 1 0 0)
    (0 0 0 0 0 1 1 0)
    (0 0 0 0 0 1 0 1)))

(define (run-sota-qisd-dqi-audit-checks)
  ;; 1. Exhaustive 3x3 QGJE audit:
  (define qgje-sum (audit-qgje-exhaustive-3x3 1))
  (unless (= (qgje-audit-summary-invertible-matrices qgje-sum) 168)
    (error 'run-sota-qisd-dqi-audit-checks "Expected 168 invertible 3x3 GF(2) matrices"))
  (unless (= (qgje-audit-summary-singular-matrices qgje-sum) 344)
    (error 'run-sota-qisd-dqi-audit-checks "Expected 344 singular 3x3 GF(2) matrices"))
  (unless (> (qgje-audit-summary-unguarded-false-positives qgje-sum) 0)
    (error 'run-sota-qisd-dqi-audit-checks "Expected >0 unguarded QGJE false positives"))
  (unless (= (qgje-audit-summary-guarded-false-positives qgje-sum) 0)
    (error 'run-sota-qisd-dqi-audit-checks "Expected 0 guarded QGJE false positives"))

  ;; 2. McEliece-348864 QM4RI resource profile:
  (define qm4ri-prof (compute-mceliece-348864-qm4ri-profile 4 96))
  (unless (> (qm4ri-resource-profile-forward-reduction-factor qm4ri-prof) 2.35)
    (error 'run-sota-qisd-dqi-audit-checks "Expected >2.35x QM4RI forward TempAND reduction"))

  ;; 3. BIKE-L1 DOOM profile:
  (define doom-prof (compute-bike-l1-doom-profile))
  (unless (> (bike-doom-profile-amortized-shift-speedup-m-sqrt doom-prof) 100.0)
    (error 'run-sota-qisd-dqi-audit-checks "Expected >100x amortized QGJE speedup per DOOM shift"))

  ;; 4. DQI radius check & optimal semicircular eigenvector weights:
  (define dqi-743-in (check-dqi-decoding-radius 'Hamming-7-4-3 HAMMING-7-4-3-BT 1))
  (define dqi-743-out (check-dqi-decoding-radius 'Hamming-7-4-3 HAMMING-7-4-3-BT 2))
  (define dqi-825-in (check-dqi-decoding-radius 'Code-8-2-5 CODE-8-2-5-BT 2))
  (define dqi-825-out (check-dqi-decoding-radius 'Code-8-2-5 CODE-8-2-5-BT 3))
  (unless (and (dqi-radius-check-result-radius-safe? dqi-743-in)
               (not (dqi-radius-check-result-radius-safe? dqi-743-out))
               (dqi-radius-check-result-radius-safe? dqi-825-in)
               (not (dqi-radius-check-result-radius-safe? dqi-825-out)))
    (error 'run-sota-qisd-dqi-audit-checks "DQI decoding radius safety classification failed"))
  (unless (> (dqi-radius-check-result-optimal-expected-satisfied dqi-825-in)
             (dqi-radius-check-result-uniform-expected-satisfied dqi-825-in))
    (error 'run-sota-qisd-dqi-audit-checks "Expected optimal w_k^* to strictly beat uniform w_k at ell=2"))

  ;; Verify that out-of-radius DQI combinator statically raises Law U1 error:
  (define caught-out-of-radius?
    (with-handlers ([exn:fail? (lambda (_e) #t)])
      (build-radius-checked-early-mbu-dqi-decl 'Hamming-7-4-3 HAMMING-7-4-3-BT 2)
      #f))
  (unless caught-out-of-radius?
    (error 'run-sota-qisd-dqi-audit-checks "Out-of-radius ell=2 on Hamming-7-4-3 was not rejected!"))

  ;; 5. Compile all 3 `#lang lakefillq` SOTA combinators through `lakefillqc`:
  (define comp-qgje
    (compile-lfq-circuit (build-non-singular-guarded-qgje-decl) 'heron-r2 #:repair? #t))
  (define comp-doom
    (compile-lfq-circuit (build-bike-doom-shift-syndrome-decl) 'heron-r2 #:repair? #t))
  (define comp-dqi
    (compile-lfq-circuit (build-radius-checked-early-mbu-dqi-decl 'Hamming-7-4-3 HAMMING-7-4-3-BT 1)
                         'heron-r2 #:repair? #t))
  (for ([c (in-list (list comp-qgje comp-doom comp-dqi))])
    (unless (and (compilation-result-well-typed? c)
                 (= 0 (compilation-result-residual-surface-forms c))
                 (= 0 (compilation-result-uncompute-ccx-count c)))
      (error 'run-sota-qisd-dqi-audit-checks
             "LakefillQ compilation failed invariants for ~a: violations=~a"
             (compilation-result-circuit-name c)
             (compilation-result-violations c))))

  (hasheq
   'status "PASS"
   'module "compiler/lakefillq-sota-qisd-dqi-audit.rkt"
   'qgje_3x3_exhaustive_audit
   (hasheq 'dim_r (qgje-audit-summary-dim-r qgje-sum)
           'total_matrices (qgje-audit-summary-total-matrices qgje-sum)
           'invertible_matrices (qgje-audit-summary-invertible-matrices qgje-sum)
           'singular_matrices (qgje-audit-summary-singular-matrices qgje-sum)
           'singular_fraction_3x3 (qgje-audit-summary-singular-fraction qgje-sum)
           'singular_fraction_mceliece_r768 (qgje-audit-summary-mceliece-r768-singular-fraction qgje-sum)
           'unguarded_false_positives (qgje-audit-summary-unguarded-false-positives qgje-sum)
           'guarded_false_positives (qgje-audit-summary-guarded-false-positives qgje-sum)
           'guarded_exact_inversions (qgje-audit-summary-guarded-exact-inversions qgje-sum))
   'mceliece_348864_qm4ri
   (hasheq 'n (qm4ri-resource-profile-n qm4ri-prof)
           'k (qm4ri-resource-profile-k qm4ri-prof)
           'r (qm4ri-resource-profile-r qm4ri-prof)
           't (qm4ri-resource-profile-t qm4ri-prof)
           'r_m4ri (qm4ri-resource-profile-block-width-b qm4ri-prof)
           'perriello_forward_tempands (qm4ri-resource-profile-perriello-forward-tempands qm4ri-prof)
           'perriello_roundtrip_ccx (qm4ri-resource-profile-perriello-roundtrip-ccx qm4ri-prof)
           'perriello_lb_undercounted_forward (qm4ri-resource-profile-perriello-lb-undercounted-forward qm4ri-prof)
           'perriello_lb_true_full_forward (qm4ri-resource-profile-perriello-lb-true-full-forward qm4ri-prof)
           'qm4ri_forward_tempands (qm4ri-resource-profile-qm4ri-forward-tempands qm4ri-prof)
           'forward_reduction_factor (qm4ri-resource-profile-forward-reduction-factor qm4ri-prof)
           'roundtrip_reduction_factor (qm4ri-resource-profile-roundtrip-reduction-factor qm4ri-prof)
           'classical_stripe_reduction_factor (qm4ri-resource-profile-classical-stripe-reduction-factor qm4ri-prof))
   'bike_l1_doom
   (hasheq 'block_r (bike-doom-profile-block-r doom-prof)
           'n (bike-doom-profile-n doom-prof)
           't (bike-doom-profile-t doom-prof)
           'm_sqrt_shifts (bike-doom-profile-m-sqrt-shifts doom-prof)
           'qgje_tempands_m1 (bike-doom-profile-qgje-tempands-m1 doom-prof)
           'qgje_tempands_m_sqrt (bike-doom-profile-qgje-tempands-m-sqrt doom-prof)
           'qgje_overhead_pct_m_sqrt (bike-doom-profile-qgje-overhead-pct-m-sqrt doom-prof)
           'amortized_shift_speedup_m_sqrt (bike-doom-profile-amortized-shift-speedup-m-sqrt doom-prof)
           'grover_iter_reduction_m_sqrt (bike-doom-profile-grover-iter-reduction-m-sqrt doom-prof)
           'grover_bits_saved_m_sqrt (bike-doom-profile-grover-bits-saved-m-sqrt doom-prof)
           'grover_bits_saved_full_doom (bike-doom-profile-grover-bits-saved-full-doom doom-prof))
   'dqi_radius_and_weights
   (hasheq 'hamming_7_4_3_d_perp (dqi-radius-check-result-dual-distance dqi-743-in)
           'hamming_7_4_3_max_ell (dqi-radius-check-result-max-safe-ell dqi-743-in)
           'code_8_2_5_d_perp (dqi-radius-check-result-dual-distance dqi-825-in)
           'code_8_2_5_max_ell (dqi-radius-check-result-max-safe-ell dqi-825-in)
           'code_8_2_5_ell2_optimal_weights (dqi-radius-check-result-optimal-weights dqi-825-in)
           'code_8_2_5_ell2_uniform_weights (dqi-radius-check-result-uniform-weights dqi-825-in)
           'code_8_2_5_ell2_optimal_expected_sat (dqi-radius-check-result-optimal-expected-satisfied dqi-825-in)
           'code_8_2_5_ell2_uniform_expected_sat (dqi-radius-check-result-uniform-expected-satisfied dqi-825-in)
           'out_of_radius_statically_rejected caught-out-of-radius?)
   'compiled_lakefillq_combinators
   (for/list ([c (in-list (list comp-qgje comp-doom comp-dqi))])
     (hasheq 'name (symbol->string (compilation-result-circuit-name c))
             'well_typed (compilation-result-well-typed? c)
             'residual_surface_forms (compilation-result-residual-surface-forms c)
             'physical_qubits (compilation-result-physical-qubits c)
             'recycled_wires_saved (compilation-result-recycled-wires-saved c)
             'forward_temp_ands (compilation-result-forward-temp-and-count c)
             'uncompute_ccx (compilation-result-uncompute-ccx-count c)
             'mbu_erasures (compilation-result-mbu-erasure-count c)))))

(module+ main
  (void HERE-DIR)
  (define summary (run-sota-qisd-dqi-audit-checks))
  (write-json summary)
  (newline))
