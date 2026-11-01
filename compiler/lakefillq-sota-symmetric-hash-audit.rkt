#lang racket
;; =============================================================================
;; LakefillQ SOTA Symmetric & Hash-Based Quantum Cryptanalysis Audit Module
;; (`compiler/lakefillq-sota-symmetric-hash-audit.rkt`)
;;
;; Codifies concrete correctness hazards and circuit optimizations discovered by
;; auditing open-source SOTA quantum cryptanalysis repositories:
;;   1. `microsoft/grover-blocks` (`Quantum-NC` / Eurocrypt 2020 Q# `AES` & `LowMC`:
;;      `aes/QAES.qs`, `aes/MaximovMixColumn.qs`, `aes/BoyarPeralta12.qs`,
;;      `aes/LPS19.qs`, `lowmc/plu_decomposition.py`, `parallel_grover.py`)
;;   2. `lzq192921/T-typeAES` (`T-aes/QAES.qs`) & `Huang & Sun 2022` / `Zou et al. 2020`
;;   3. `msr-quarc/ReVerC` (`reverc/Examples.fs`: `keccakf`, `keccakfInPlace`, `SHA2`)
;;   4. `meamy/feynman` (`benchmarks/gf2^8_mult.qasm`) & `starj1023/SHA-2-and-SHA-3`
;;      (`SHA-3/AND_Implementation/Shallow_SHA-3.py`), plus `FIPS 205` (`SLH-DSA` /
;;      `SPHINCS+-128s`).
;; =============================================================================

(require racket/match
         racket/list
         racket/vector
         racket/set
         racket/math
         racket/format
         racket/runtime-path
         json
         "../lakefill-core-cryptography-implementations.rkt"
         "../lakefill-pareto-aes-slp-and-asymmetric-mbu.rkt"
         "lakefillq-xag-fraig-typechecker.rkt")

(provide
 ;; Optimization 1: Compile-time 0-gate wire-permutation tracking
 aes-shiftrows-wire-perm-128
 keccak-rho-pi-wire-perm-1600
 compile-zero-gate-wire-perm-demo
 ;; Correctness 1: MixColumns PLU / SLP wire-permutation & L/U order Z3 miter
 audit-mixcolumns-plu-miter!
 ;; Correctness 2 & Optimization 2A: Spurious keys & 2-step 4-byte shifted-column filter
 aes-spurious-key-table
 aes-two-step-shifted-col0-cone-audit!
 ;; Correctness 3: Keccak chi_5 sequential overwrite & ReVerC hazards vs M_X / 2-ancilla
 audit-keccak-chi5-hazards-and-mbu!
 ;; Correctness 4: Tower-field GF(((2^2)^2)^2) endianness & 0x00 -> 0x63 blind spot
 audit-tower-field-endianness-miter!
 ;; Optimization 2B: SPHINCS+-128s PK.seed + ADRS XAG constant-lane specialization
 audit-sphincs-shake256-constant-lane-xag!
 ;; Full SOTA audit runner
 run-all-sota-symmetric-hash-audits!)

;; =============================================================================
;; SECTION 1: Optimization Finding 1 — Compile-Time Logical Wire-Permutation
;;            Tracking (`0` Physical `SWAP` / `CNOT` Gates)
;; =============================================================================

;; AES ShiftRows byte permutation `[0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11]`
;; expanded to 128 bit-wires (`src-for-dst` convention matching `logical-relabel`).
(define aes-shiftrows-byte-perm
  '(0 5 10 15 4 9 14 3 8 13 2 7 12 1 6 11))

(define aes-shiftrows-wire-perm-128
  (append*
   (for/list ([dst-byte (in-range 16)])
     (define src-byte (list-ref aes-shiftrows-byte-perm dst-byte))
     (for/list ([b (in-range 8)])
       (+ (* 8 src-byte) b)))))

;; FIPS 202 Keccak-f[1600] rotation offsets `rho[x, y]` for `x, y in 0..4`.
(define keccak-rho-offsets
  #(#(0 36 3 41 18)
    #(1 44 10 45 2)
    #(62 6 43 15 61)
    #(28 55 25 21 56)
    #(27 20 39 8 14)))

(define (keccak-lane-idx x y)
  (+ x (* 5 y)))

;; Combined `rho o pi` 1600-bit permutation (`src-for-dst`):
;; In FIPS 202:
;;   `B[y, (2x + 3y) mod 5][z] = A[x, y][(z - rho[x, y]) mod 64]`.
;; So destination lane `(dx, dy)` with `dx = y`, `dy = (2x + 3y) mod 5` receives from
;; source `(x, y)` where `y = dx` and `2x == dy - 3*dx (mod 5)` -> `x = 3*(dy - 3*dx) mod 5`.
(define keccak-rho-pi-wire-perm-1600
  (let ([src-vec (make-vector 1600 0)])
    (for* ([x (in-range 5)]
           [y (in-range 5)]
           [z (in-range 64)])
      (define rot (vector-ref (vector-ref keccak-rho-offsets x) y))
      (define dx y)
      (define dy (modulo (+ (* 2 x) (* 3 y)) 5))
      (define dst-z (modulo (+ z rot) 64))
      (define src-wire (+ (* 64 (keccak-lane-idx x y)) z))
      (define dst-wire (+ (* 64 (keccak-lane-idx dx dy)) dst-z))
      (vector-set! src-vec dst-wire src-wire))
    (vector->list src-vec)))

(define (count-gate-ops gates)
  (define cx-cnt 0)
  (define swap-cnt 0)
  (define ccx-cnt 0)
  (define mbu-cnt 0)
  (for ([g (in-list gates)])
    (match g
      [`(cx ,_ ,_) (set! cx-cnt (add1 cx-cnt))]
      [`(swap ,_ ,_) (set! swap-cnt (add1 swap-cnt))]
      [`(ccx ,_ ,_ ,_) (set! ccx-cnt (add1 ccx-cnt))]
      [`(mid-meas-x-cond-z . ,_) (set! mbu-cnt (add1 mbu-cnt))]
      [_ (void)]))
  (hasheq 'total_gates (length gates)
          'cx cx-cnt
          'swap swap-cnt
          'ccx ccx-cnt
          'mbu mbu-cnt))

(define-values (sota-slp91-gates sota-slp91-wmap-hash)
  (compile-lakefill-pareto-with-map
   (aes-mixcolumn-slp92-col-sexpr (range 32) #:rewire? #t)))

(define sota-slp91-cx-pairs
  (for/list ([g (in-list sota-slp91-gates)])
    (match-define `(cx ,c ,t) g)
    (list c t)))

(define sota-slp91-wire-perm
  (for/list ([w (in-range 32)])
    (hash-ref sota-slp91-wmap-hash w w)))

(define (compile-zero-gate-wire-perm-demo)
  (define wires128 (range 128))
  (define wires32 (range 32))
  (define wires1600 (range 1600))
  (define-values (sr-gates sr-wmap)
    (compile-lakefill-pareto-with-map
     `(logical-relabel ,wires128 ,aes-shiftrows-wire-perm-128)))
  (define-values (plu-p-gates plu-p-wmap)
    (compile-lakefill-pareto-with-map
     `(logical-relabel ,wires32 ,sota-slp91-wire-perm)))
  (define-values (rhopi-gates rhopi-wmap)
    (compile-lakefill-pareto-with-map
     `(logical-relabel ,wires1600 ,keccak-rho-pi-wire-perm-1600)))
  ;; Verify `within-apply-mbu` automatically restores `wmap` to identity with `0` SWAP gates!
  (define-values (roundtrip-gates roundtrip-wmap)
    (compile-lakefill-pareto-with-map
     `(within-apply-mbu
       (logical-relabel ,wires128 ,aes-shiftrows-wire-perm-128)
       (cx 0 8)
       ())))
  (define wmap-restored?
    (for/and ([w (in-range 128)])
      (= (hash-ref roundtrip-wmap w w) w)))
  (unless (and (null? sr-gates)
               (null? plu-p-gates)
               (null? rhopi-gates)
               wmap-restored?
               (equal? roundtrip-gates (list `(cx ,(list-ref aes-shiftrows-wire-perm-128 0)
                                                  ,(list-ref aes-shiftrows-wire-perm-128 8)))))
    (error 'compile-zero-gate-wire-perm-demo "Zero-gate wire permutation check failed"))
  (hasheq 'shiftrows_128_physical_gates (length sr-gates)
          'mixcolumns_plu_p_32_physical_gates (length plu-p-gates)
          'keccak_rho_pi_1600_physical_gates (length rhopi-gates)
          'within_apply_wmap_restored wmap-restored?
          'within_apply_retargeted_cx (format "~a" (first roundtrip-gates))
          'bijection_sizes_verified (list (set-count (list->set (hash-values sr-wmap)))
                                          (set-count (list->set (hash-values plu-p-wmap)))
                                          (set-count (list->set (hash-values rhopi-wmap))))))

;; =============================================================================
;; SECTION 2: Correctness Finding 1 — In-Place `MixColumns` `PLU` / `SLP`
;;            Wire-Permutation & `L`/`U` Transposition Miter (`XAG + Z3`)
;; =============================================================================

;; Exact GF(2^8) xtime (`0x02 * b` modulo `x^8 + x^4 + x^3 + x + 1`) on 8 XAG literals.
(define (xag-gf256-xtime mgr b8)
  (match-define (list b0 b1 b2 b3 b4 b5 b6 b7) b8)
  (list b7
        (xag-xor mgr b0 b7)
        b1
        (xag-xor mgr b2 b7)
        (xag-xor mgr b3 b7)
        b4
        b5
        b6))

(define (xag-vec-xor mgr a-lits b-lits)
  (for/list ([a (in-list a-lits)] [b (in-list b-lits)])
    (xag-xor mgr a b)))

;; Reference FIPS-197 MixColumns single column on 32 XAG input literals.
(define (xag-ref-mixcolumn-32 mgr col32-lits)
  (define s0 (take col32-lits 8))
  (define s1 (take (drop col32-lits 8) 8))
  (define s2 (take (drop col32-lits 16) 8))
  (define s3 (drop col32-lits 24))
  (define all-xor (xag-vec-xor mgr (xag-vec-xor mgr s0 s1) (xag-vec-xor mgr s2 s3)))
  (define y0 (xag-vec-xor mgr s0 (xag-vec-xor mgr all-xor (xag-gf256-xtime mgr (xag-vec-xor mgr s0 s1)))))
  (define y1 (xag-vec-xor mgr s1 (xag-vec-xor mgr all-xor (xag-gf256-xtime mgr (xag-vec-xor mgr s1 s2)))))
  (define y2 (xag-vec-xor mgr s2 (xag-vec-xor mgr all-xor (xag-gf256-xtime mgr (xag-vec-xor mgr s2 s3)))))
  (define y3 (xag-vec-xor mgr s3 (xag-vec-xor mgr all-xor (xag-gf256-xtime mgr (xag-vec-xor mgr s3 s0)))))
  (append y0 y1 y2 y3))

;; Evaluate pure linear/Toffoli gate list symbolically in `XAG` with final `wmap`.
(define (xag-sim-gates-with-wmap mgr init-lits gates final-wmap)
  (define phys-vec (list->vector init-lits))
  (for ([g (in-list gates)])
    (match g
      [`(x ,i)
       (vector-set! phys-vec i (lit-not (vector-ref phys-vec i)))]
      [`(cx ,c ,t)
       (vector-set! phys-vec t (xag-xor mgr (vector-ref phys-vec t) (vector-ref phys-vec c)))]
      [`(ccx ,c1 ,c2 ,t)
       (vector-set! phys-vec t
                    (xag-xor mgr
                             (vector-ref phys-vec t)
                             (xag-and mgr (vector-ref phys-vec c1) (vector-ref phys-vec c2))))]
      [`(swap ,a ,b)
       (define tmp (vector-ref phys-vec a))
       (vector-set! phys-vec a (vector-ref phys-vec b))
       (vector-set! phys-vec b tmp)]
      [_ (void)]))
  (for/list ([logical-w (in-range (vector-length phys-vec))])
    (vector-ref phys-vec (hash-ref final-wmap logical-w logical-w))))

(define (audit-mixcolumns-plu-miter!)
  (define wires32 (range 32))
  (define mgr (make-xag-manager 2048))
  (define in-lits (for/list ([i (in-range 32)]) (xag-var mgr i)))
  (define ref-lits (xag-ref-mixcolumn-32 mgr in-lits))

  (define warm-mgr (make-xag-manager 16))
  (define-values (_ws _wc _wm)
    (xag-z3-cut-sweep-miter! warm-mgr (list (xag-var warm-mgr 0)) '(0) 'all))

  ;; 1. Exact `91-CX` (`<= 92-CX`) `0-SWAP` SLP with tracked logical wire permutation `P`
  (define t0 (current-inexact-monotonic-milliseconds))
  (define-values (exact-gates exact-wmap)
    (compile-lakefill-pareto-with-map (aes-mixcolumn-slp92-col-sexpr wires32 #:rewire? #t)))
  (define exact-lits (xag-sim-gates-with-wmap mgr in-lits exact-gates exact-wmap))
  (define exact-diff (xag-vec-xor mgr ref-lits exact-lits))
  (define-values (exact-status _exact-cex _exact-mode)
    (xag-z3-cut-sweep-miter! mgr exact-diff wires32 'all))
  (define exact-ms (- (current-inexact-monotonic-milliseconds) t0))

  ;; 2. Bug Class A: 1-transposition wire-permutation bug in `P` (swapping output wires 2 & 10)
  (define buggy-perm
    (let ([v (list->vector sota-slp91-wire-perm)])
      (define tmp (vector-ref v 2))
      (vector-set! v 2 (vector-ref v 10))
      (vector-set! v 10 tmp)
      (vector->list v)))
  (define mgr-bug1 (make-xag-manager 2048))
  (define in-b1 (for/list ([i (in-range 32)]) (xag-var mgr-bug1 i)))
  (define ref-b1 (xag-ref-mixcolumn-32 mgr-bug1 in-b1))
  (define t1 (current-inexact-monotonic-milliseconds))
  (define-values (b1-gates b1-wmap)
    (compile-lakefill-pareto-with-map
     `(seq ,@(for/list ([p (in-list sota-slp91-cx-pairs)])
               `(cx ,(first p) ,(second p)))
           (logical-relabel ,wires32 ,buggy-perm))))
  (define b1-lits (xag-sim-gates-with-wmap mgr-bug1 in-b1 b1-gates b1-wmap))
  (define b1-diff (xag-vec-xor mgr-bug1 ref-b1 b1-lits))
  (define-values (b1-status b1-cex _b1-mode)
    (xag-z3-cut-sweep-miter! mgr-bug1 b1-diff wires32 'all))
  (define b1-ms (- (current-inexact-monotonic-milliseconds) t1))

  ;; 3. Bug Class B: Omitting `MixedColumn` wire permutation altogether (`rewire? = #f`,
  ;;    as in `lzq192921/T-typeAES/T-aes/QAES.qs:142` calling `InPlace.MixColumn` without `MixedColumn`)
  (define mgr-bug2 (make-xag-manager 2048))
  (define in-b2 (for/list ([i (in-range 32)]) (xag-var mgr-bug2 i)))
  (define ref-b2 (xag-ref-mixcolumn-32 mgr-bug2 in-b2))
  (define t2 (current-inexact-monotonic-milliseconds))
  (define-values (b2-gates b2-wmap)
    (compile-lakefill-pareto-with-map (aes-mixcolumn-slp92-col-sexpr wires32 #:rewire? #f)))
  (define b2-lits (xag-sim-gates-with-wmap mgr-bug2 in-b2 b2-gates b2-wmap))
  (define b2-diff (xag-vec-xor mgr-bug2 ref-b2 b2-lits))
  (define-values (b2-status b2-cex _b2-mode)
    (xag-z3-cut-sweep-miter! mgr-bug2 b2-diff wires32 'all))
  (define b2-ms (- (current-inexact-monotonic-milliseconds) t2))

  ;; 4. Bug Class C: Reversed `L` / `U` factor order (`reverse cx-pairs` + `P`)
  (define mgr-bug3 (make-xag-manager 2048))
  (define in-b3 (for/list ([i (in-range 32)]) (xag-var mgr-bug3 i)))
  (define ref-b3 (xag-ref-mixcolumn-32 mgr-bug3 in-b3))
  (define t3 (current-inexact-monotonic-milliseconds))
  (define-values (b3-gates b3-wmap)
    (compile-lakefill-pareto-with-map
     `(seq ,@(for/list ([p (in-list (reverse sota-slp91-cx-pairs))])
               `(cx ,(first p) ,(second p)))
           (logical-relabel ,wires32 ,sota-slp91-wire-perm))))
  (define b3-lits (xag-sim-gates-with-wmap mgr-bug3 in-b3 b3-gates b3-wmap))
  (define b3-diff (xag-vec-xor mgr-bug3 ref-b3 b3-lits))
  (define-values (b3-status b3-cex _b3-mode)
    (xag-z3-cut-sweep-miter! mgr-bug3 b3-diff wires32 'all))
  (define b3-ms (- (current-inexact-monotonic-milliseconds) t3))

  (unless (and (eq? exact-status 'unsat)
               (eq? b1-status 'sat)
               (eq? b2-status 'sat)
               (eq? b3-status 'sat))
    (error 'audit-mixcolumns-plu-miter! "Unexpected MixColumns Z3 miter status"))

  (hasheq 'sota_quantum_nc_plu_cx_per_col 277
          'sota_maximov_oos_cx_per_col 376
          'sota_maximov_ancillas_per_col 62
          'lakefillq_slp_cx_per_col (hash-ref (count-gate-ops exact-gates) 'cx)
          'lakefillq_slp_swaps_per_col (hash-ref (count-gate-ops exact-gates) 'swap)
          'lakefillq_slp_ancillas_per_col 0
          'exact_miter_status (symbol->string exact-status)
          'exact_miter_ms exact-ms
          'single_wire_perm_bug_status (symbol->string b1-status)
          'single_wire_perm_bug_ms b1-ms
          'single_wire_perm_bug_cex b1-cex
          'missing_mixedword_perm_bug_status (symbol->string b2-status)
          'missing_mixedword_perm_bug_ms b2-ms
          'missing_mixedword_perm_bug_cex b2-cex
          'transposed_lu_order_bug_status (symbol->string b3-status)
          'transposed_lu_order_bug_ms b3-ms
          'transposed_lu_order_bug_cex b3-cex))

;; =============================================================================
;; SECTION 3: Correctness Finding 2 & Optimization 2A — Spurious Keys &
;;            Grover `AES` 2-Step 4-Byte Shifted-Column Early-Abort Filter
;; =============================================================================

(define (aes-spurious-key-table)
  ;; Matches `microsoft/grover-blocks/parallel_grover.py` (`spurious_keys_probability(k, 128, r, 1)`)
  (for/list ([spec (in-list '((AES-128 128) (AES-192 192) (AES-256 256)))])
    (match-define (list name k) spec)
    (hasheq 'cipher (symbol->string name)
            'key_bits k
            'pairs_analysis
            (for/list ([r (in-list '(1 2 3))])
              (define exp-diff (- k (* 128 r)))
              (define expected-false (expt 2.0 exp-diff))
              (define p-unique (exp (- expected-false)))
              (hasheq 'r r
                      'log2_expected_spurious_keys exp-diff
                      'expected_spurious_keys expected-false
                      'unique_key_probability p-unique
                      'spurious_key_probability (- 1.0 p-unique))))))

;; Classical reference AES S-box via exact tower-field matrices for testbench cross-check
(define (gf2-mat-eval-u8 mat x)
  (for/fold ([acc 0]) ([r (in-range 8)])
    (define row (vector-ref mat r))
    (define bit
      (bitwise-and 1
                   (for/sum ([c (in-range 8)])
                     (* (vector-ref row c) (if (bitwise-bit-set? x c) 1 0)))))
    (bitwise-ior acc (arithmetic-shift bit r))))

(define (gf256-aes-mul a b)
  (let loop ([i 0] [aa a] [bb b] [res 0])
    (if (= i 8)
        res
        (let* ([res2 (if (bitwise-bit-set? bb 0) (bitwise-xor res aa) res)]
               [hi? (bitwise-bit-set? aa 7)]
               [aa2 (bitwise-and #xff (arithmetic-shift aa 1))]
               [aa3 (if hi? (bitwise-xor aa2 #x1b) aa2)])
          (loop (add1 i) aa3 (arithmetic-shift bb -1) res2)))))

(define (gf256-aes-inv x)
  (if (zero? x)
      0
      ;; x^254 in GF(2^8)
      (for/fold ([acc 1] [base x] #:result acc) ([i (in-range 8)])
        (values (if (bitwise-bit-set? 254 i) (gf256-aes-mul acc base) acc)
                (gf256-aes-mul base base)))))

(define sota-aes-affine-mat
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (if (<= (modulo (- r c) 8) 4) 1 0))))

(define aes-ref-sbox-vec
  (for/vector ([x (in-range 256)])
    (bitwise-xor #x63 (gf2-mat-eval-u8 sota-aes-affine-mat (gf256-aes-inv x)))))

(define (aes-ref-subbytes state16)
  (map (lambda (b) (vector-ref aes-ref-sbox-vec b)) state16))

(define (aes-ref-shiftrows state16)
  (for/list ([idx (in-list aes-shiftrows-byte-perm)])
    (list-ref state16 idx)))

(define (aes-ref-mixcol4 col4)
  (match-define (list a0 a1 a2 a3) col4)
  (define allx (bitwise-xor a0 a1 a2 a3))
  (list (bitwise-xor a0 allx (gf256-aes-mul 2 (bitwise-xor a0 a1)))
        (bitwise-xor a1 allx (gf256-aes-mul 2 (bitwise-xor a1 a2)))
        (bitwise-xor a2 allx (gf256-aes-mul 2 (bitwise-xor a2 a3)))
        (bitwise-xor a3 allx (gf256-aes-mul 2 (bitwise-xor a3 a0)))))

(define (aes-ref-mixcolumns state16)
  (append* (for/list ([c (in-range 4)])
             (aes-ref-mixcol4 (take (drop state16 (* 4 c)) 4)))))

;; Verify the 2-step backward-cone 4-byte shifted-column early-abort filter on Block 2:
;; Target ciphertext byte positions `{0, 7, 10, 13}` of `C_2` are the exact ShiftRows image
;; of Column 0 `(bytes 0, 1, 2, 3)` entering the final AES step!
;; Consequently:
;;   - Penultimate step needs ONLY the 4 S-boxes at `{0, 5, 10, 15}` + Column 0 MixColumns (`12` S-boxes saved!)
;;   - Final step needs ONLY the 4 S-boxes at `{0, 1, 2, 3}` (`12` S-boxes saved!)
;;   - Total saved in Block 2 = `24` S-boxes (`360 -> 336` S-boxes across shared-key `r=2` `AES-128`)!
(define (aes-two-step-shifted-col0-cone-audit!)
  ;; Test across 64 deterministic pseudo-random `(state_after_step8, k9, k10)` triples
  (for ([trial (in-range 64)])
    (define s8
      (for/list ([j (in-range 16)])
        (bitwise-and #xff (+ (* 37 (+ trial 1)) (* 73 j) (* j j)))))
    (define k9
      (for/list ([j (in-range 16)])
        (bitwise-and #xff (+ (* 53 (+ trial 3)) (* 19 j)))))
    (define k10
      (for/list ([j (in-range 16)])
        (bitwise-and #xff (+ (* 97 (+ trial 5)) (* 41 j)))))

    ;; Full 2-step reference (`32` S-boxes + `4` MixColumns)
    (define full-s9-ark
      (map bitwise-xor
           (aes-ref-mixcolumns (aes-ref-shiftrows (aes-ref-subbytes s8)))
           k9))
    (define full-c2
      (map bitwise-xor
           (aes-ref-shiftrows (aes-ref-subbytes full-s9-ark))
           k10))

    ;; Pruned 2-step cone (`8` S-boxes instead of `32` -> `24` S-boxes saved, `1` MixColumn!)
    (define col0-after-sr9
      (for/list ([src-idx (in-list '(0 5 10 15))])
        (vector-ref aes-ref-sbox-vec (list-ref s8 src-idx))))
    (define col0-mc9 (aes-ref-mixcol4 col0-after-sr9))
    (define col0-s9-ark
      (for/list ([b (in-list col0-mc9)] [j (in-range 4)])
        (bitwise-xor b (list-ref k9 j))))
    (define col0-sub10 (map (lambda (b) (vector-ref aes-ref-sbox-vec b)) col0-s9-ark))
    ;; Under final ShiftRows:
    ;;   row 0 (`col0-sub10[0]`) -> byte `0`  (row 0, col 0)
    ;;   row 1 (`col0-sub10[1]`) -> byte `13` (row 1, col 3 = 4*3 + 1)
    ;;   row 2 (`col0-sub10[2]`) -> byte `10` (row 2, col 2 = 4*2 + 2)
    ;;   row 3 (`col0-sub10[3]`) -> byte `7`  (row 3, col 1 = 4*1 + 3)
    (define pruned-0  (bitwise-xor (list-ref col0-sub10 0) (list-ref k10 0)))
    (define pruned-7  (bitwise-xor (list-ref col0-sub10 3) (list-ref k10 7)))
    (define pruned-10 (bitwise-xor (list-ref col0-sub10 2) (list-ref k10 10)))
    (define pruned-13 (bitwise-xor (list-ref col0-sub10 1) (list-ref k10 13)))

    (unless (and (= pruned-0  (list-ref full-c2 0))
                 (= pruned-7  (list-ref full-c2 7))
                 (= pruned-10 (list-ref full-c2 10))
                 (= pruned-13 (list-ref full-c2 13)))
      (error 'aes-two-step-shifted-col0-cone-audit! "2-step cone mismatch on trial ~a" trial)))

  (define baseline-sboxes 360)   ;; 40 key + 160 block1 + 160 block2
  (define saved-sboxes 24)       ;; 12 in penultimate step + 12 in final step of block 2
  (define opt-sboxes (- baseline-sboxes saved-sboxes)) ;; 336

  (hasheq 'target_ciphertext_bytes '(0 7 10 13)
          'penultimate_step_active_sbox_bytes '(0 5 10 15)
          'final_step_active_sbox_bytes '(0 1 2 3)
          'trials_verified 64
          'spurious_key_reduction_factor (expt 2.0 -32)
          'aes128_r2_shared_key_baseline_sboxes baseline-sboxes
          'aes128_r2_shared_key_optimized_sboxes opt-sboxes
          'sboxes_saved saved-sboxes
          'tempand_model_22and_baseline (* baseline-sboxes 22)
          'tempand_model_22and_optimized (* opt-sboxes 22)
          'tempand_model_22and_saved (* saved-sboxes 22)
          'tempand_circuit_bp34_baseline (* baseline-sboxes 34)
          'tempand_circuit_bp34_optimized (* opt-sboxes 34)
          'tempand_circuit_bp34_saved (* saved-sboxes 34)
          'inverse_key_schedule_toffolis_with_mbu 0))

;; =============================================================================
;; SECTION 4: Correctness Finding 3 — `Keccak` `chi_5` Sequential Overwrite &
;;            `ReVerC` Non-Involution Hazards vs `LakefillQ` `M_X` & 2-Ancilla
;; =============================================================================

(define (ref-chi5-u5 mask)
  (for/fold ([out 0]) ([i (in-range 5)])
    (define ai  (if (bitwise-bit-set? mask i) 1 0))
    (define ai1 (if (bitwise-bit-set? mask (modulo (+ i 1) 5)) 1 0))
    (define ai2 (if (bitwise-bit-set? mask (modulo (+ i 2) 5)) 1 0))
    (define yi  (bitwise-xor ai (bitwise-and (- 1 ai1) ai2)))
    (bitwise-ior out (arithmetic-shift yi i))))

;; Buggy sequential in-place update: `for i = 0..4: a[i] ^= (~a[(i+1)%5] & a[(i+2)%5])`
(define (buggy-seq-inplace-chi5-u5 mask)
  (define a (for/vector ([i (in-range 5)]) (if (bitwise-bit-set? mask i) 1 0)))
  (for ([i (in-range 5)])
    (define a1 (vector-ref a (modulo (+ i 1) 5)))
    (define a2 (vector-ref a (modulo (+ i 2) 5)))
    (vector-set! a i (bitwise-xor (vector-ref a i) (bitwise-and (- 1 a1) a2))))
  (for/fold ([out 0]) ([i (in-range 5)])
    (bitwise-ior out (arithmetic-shift (vector-ref a i) i))))

;; LakefillQ `within-apply-mbu` degree-2 `chi_5`:
;; Uses `5` clean ancillas `anc5`, `5` `TempAND`s forward, `5` `0T` `M_X + cond-CZ` backward!
;; Wait: to update `a[0..4]` IN-PLACE using `5` clean ancillas:
;;   1. Compute `t[i] <- (~a[i+1] & a[i+2])` (`5` `TempAND`s) AND XOR `a[i] ^= t[i]`?
;;      Hold on: if we modify `a[i]` in the action, `t[i]` cannot be uncomputed from the OLD `a`
;;      unless `t` holds `a_old` (`copy` `5` `CX`s: `old[i] <- a[i]`, compute `a[i] ^= (~old[i+1] & old[i+2])`,
;;      then uncompute `old` via algebraic degree-3 inverse of `chi_5`, OR in out-of-place `y ^= chi_5(a)`
;;      `within-apply-mbu` uses `5` `TempAND`s + `5` `M_X` with `0` reverse Toffolis!).
;; Let's build BOTH:
;;   (A) Out-of-place `y5 ^= chi_5(a5)` via `within-apply-mbu` (`5` `TempAND`s + `5` `M_X`, `0` reverse Toffolis!)
;;   (B) Strictly IN-PLACE `a5 <- chi_5(a5)` using ONLY `2` clean ancillas (`sc0 = a0_old`, `sc1 = a1_old`)!
;;       Let's derive the exact 2-ancilla in-place `chi_5` schedule + algebraic uncompute of `(sc0, sc1)`:
;;         1. Backup `sc0 ^= a0`, `sc1 ^= a1` (`2` `CX`s).
;;         2. Update in-place sequentially reading `sc0, sc1` where `a0, a1` were overwritten:
;;              `a0 ^= (~a1 & a2)`
;;              `a1 ^= (~a2 & a3)`
;;              `a2 ^= (~a3 & a4)`
;;              `a3 ^= (~a4 & sc0)`
;;              `a4 ^= (~sc0 & sc1)`
;;            Now `a[0..4]` holds exact `y[0..4] = chi_5(a_old)`!
;;         3. Uncompute `sc0, sc1` from `y[0..4]` using the exact algebraic inverse of `chi_5`:
;;            Over GF(2), for ANY `chi_5`:
;;              `a_old[i] = y[i] ^ (~y[i+1] & (y[i+2] ^ (~y[i+3] & y[i+4])))`!
;;            Check! If `y[i+1] == 1`, `a[i] = y[i]`.
;;            If `y[i+1] == 0`, then either `a[i+1] == 0` ( Wait: if `a[i+1] == 1` and `~a[i+2] & a[i+3] == 1`, then `a[i+2] == 0`, so `~a[i+1] & a[i+2] = 0 & 0 = 0`! Let's check the exact degree-3 inverse of `chi_5` over all 32 inputs!).

(define (chi5-out-of-place-mbu-sexpr a5 y5 anc5)
  (define (a i) (list-ref a5 (modulo i 5)))
  (define (y i) (list-ref y5 i))
  (define (t i) (list-ref anc5 i))
  `(within-apply-mbu
    (seq ,@(for/list ([i (in-range 5)])
             `(temp-and-lin (,(a (+ i 1))) (,(a (+ i 2))) ,(t i) #t #f)))
    (seq ,@(for/list ([i (in-range 5)])
             `(seq (cx ,(a i) ,(y i))
                   (cx ,(t i) ,(y i)))))
    ,anc5))

;; Exact 2-ancilla + 1 TempAND-ancilla (`3` ancillas, or `2` backup ancillas with `within-apply-mbu`!)
;; Let's check exact algebraic inverse of 5-bit `chi_5`:
;; Known identity for `5`-bit Keccak `chi_5` (`Daemen & Rijmen`, `Examples.fs:622-640` modulo loop bug):
;; Let's verify `x_i = y_i ^ (~y_{i+1} & y_{i+2}) ^ (~y_{i+1} & y_{i+3} & y_{i+4})`?
;; Let's test `y_i ^ (~y_{i+1} & (y_{i+2} ^ (~y_{i+3} & y_{i+4})))` on all 32 inputs!
;; Wait: if `x = 00100` (`x2 = 1`):
;;   `y0 = 0 ^ (1 & 1) = 1`, `y1 = 0 ^ (0 & 0) = 0`, `y2 = 1 ^ (1 & 0) = 1`, `y3 = 0`, `y4 = 0` -> `y = 00101`.
;;   Formula at `i = 0`: `y0 ^ (~y1 & (y2 ^ (~y3 & y4))) = 1 ^ (1 & (1 ^ (1 & 0))) = 1 ^ 1 = 0 = x0`!
;;   What if `x = 01010` (`x1=1, x3=1`):
;;   `y0 = 0 ^ (0 & 0) = 0`, `y1 = 1 ^ (1 & 1) = 0`, `y2 = 0 ^ (0 & 0) = 0`, `y3 = 1 ^ (1 & 0) = 1`, `y4 = 0 ^ (1 & 1) = 1` -> `y = 11000` (`y3=1, y4=1`).
;;   Check formula at `i = 1`: `y1 ^ (~y2 & (y3 ^ (~y4 & y0))) = 0 ^ (1 & (1 ^ (0 & 0))) = 1 = x1`!
;;   Check formula at `i = 0`: `y0 ^ (~y1 & (y2 ^ (~y3 & y4))) = 0 ^ (1 & (0 ^ (0 & 1))) = 0 = x0`!
;; IT IS AN EXACT ALGEBRAIC IDENTITY FOR ALL 32 INPUTS!
;; Proof: `x_{i+2} = y_{i+2} ^ (~x_{i+3} & x_{i+4})`. When `~y_{i+1} == 1`, if `x_{i+1} == 1` then
;; `~x_{i+2} & x_{i+3} == 1`, so `x_{i+2} == 0, x_{i+3} == 1`, which forces `y_{i+2} = 0 ^ (~1 & x_{i+4}) = 0`
;; AND `y_{i+3} = 1 ^ (~x_{i+4} & x_i)`. Wait — let's check `x = 01011` (`x0=1, x1=1, x3=1`) in Racket!

(define (chi5-inv-bit yvec i)
  (define y0 (vector-ref yvec (modulo i 5)))
  (define y1 (vector-ref yvec (modulo (+ i 1) 5)))
  (define y2 (vector-ref yvec (modulo (+ i 2) 5)))
  (define y3 (vector-ref yvec (modulo (+ i 3) 5)))
  (define y4 (vector-ref yvec (modulo (+ i 4) 5)))
  ;; Wait: let's check both candidate degree-3 expressions in `audit-keccak-chi5-hazards-and-mbu!`!
  (bitwise-xor y0 (bitwise-and (- 1 y1) (bitwise-xor y2 (bitwise-and (- 1 y3) y4)))))

;; Exact 2-backup-ancilla + 1 MBU-ancilla (`sc0, sc1, mbu0`) in-place `chi_5`:
;; Uses `within-apply-mbu` to erase the inner product `(~y3 & y4)` for `sc0` and `(~y4 & y0)` for `sc1`!
(define (chi5-two-backup-inplace-mbu-sexpr a5 sc0 sc1 mbu0)
  (match-define (list a0 a1 a2 a3 a4) a5)
  `(seq ;; 1. Copy `a0 -> sc0`, `a1 -> sc1`
        (cx ,a0 ,sc0)
        (cx ,a1 ,sc1)
        ;; 2. Sequential update reading `sc0, sc1` in place of overwritten `a0, a1`
        (x ,a1) (ccx ,a1 ,a2 ,a0) (x ,a1)
        (x ,a2) (ccx ,a2 ,a3 ,a1) (x ,a2)
        (x ,a3) (ccx ,a3 ,a4 ,a2) (x ,a3)
        (x ,a4) (ccx ,a4 ,sc0 ,a3) (x ,a4)
        (x ,sc0) (ccx ,sc0 ,sc1 ,a4) (x ,sc0)
        ;; 3. Uncompute `sc0 = a0_old = y0 ^ (~y1 & (y2 ^ (y3 & ~y4)? OR (~y3 & y4)?))`
        ;; Wait: let's check exact ANF of `chi_5^-1`!
        ;; Recall `ReVerC/reverc/Examples.fs:622`:
        ;; `B[j] ^= A[j] ^ ((A[j+1] ^^ true) && (A[j+2] ^^ ((A[j+3] ^^ true) && A[j+4])))`?
        ;; No: if `x = 01011` (`x0=1, x1=1, x2=0, x3=1, x4=0`):
        ;;   `y0 = 1 ^ (0 & 0) = 1`
        ;;   `y1 = 1 ^ (1 & 1) = 0`
        ;;   `y2 = 0 ^ (0 & 0) = 0`
        ;;   `y3 = 1 ^ (1 & 1) = 0`
        ;;   `y4 = 0 ^ (0 & 1) = 0` -> `y = 00001` (`y0 = 1`, others `0`)!
        ;;   Look! At `y = 00001`, `x1 = 1`, so `x1` at `i=1` needs `1`:
        ;;   `y1=0, y2=0, y3=0, y4=0, y0=1`:
        ;;   `y1 ^ (~y2 & (y3 ^ (~y4 & y0)))` = `0 ^ (1 & (0 ^ (1 & 1)))` = `1 = x1`!!
        ;;   And at `i=0` (`x0 = 1`):
        ;;   `y0 ^ (~y1 & (y2 ^ (~y3 & y4)))` = `1 ^ (1 & (0 ^ (1 & 0)))` = `1 = x0`!!
        ;;   IT MATCHES EVEN `x = 01011`! Because `chi_5^-1` has algebraic degree 3:
        ;;   `x_i = y_i ^ (~y_{i+1} & (y_{i+2} ^ (~y_{i+3} & y_{i+4})))`!
        (cx ,a0 ,sc0)
        (within-apply-mbu
         (seq (temp-and-lin (,a3) (,a4) ,mbu0 #t #f)
              (cx ,a2 ,mbu0))
         (seq (x ,a1) (ccx ,a1 ,mbu0 ,sc0) (x ,a1))
         (,mbu0))
        (cx ,a1 ,sc1)
        (within-apply-mbu
         (seq (temp-and-lin (,a4) (,a0) ,mbu0 #t #f)
              (cx ,a3 ,mbu0))
         (seq (x ,a2) (ccx ,a2 ,mbu0 ,sc1) (x ,a2))
         (,mbu0))
        (assert-clean (,sc0 ,sc1 ,mbu0))))

(define (audit-keccak-chi5-hazards-and-mbu!)
  ;; 1. Exhaustive 32-input audit of sequential overwrite hazard & ReVerC non-involution hazard
  (define seq-failures 0)
  (define non-involution-failures 0)
  (for ([mask (in-range 32)])
    (define spec (ref-chi5-u5 mask))
    (define seq-out (buggy-seq-inplace-chi5-u5 mask))
    (define double-chi (ref-chi5-u5 spec))
    ;; Also verify the degree-3 inverse formula on all 32 inputs
    (define yvec (for/vector ([i (in-range 5)]) (if (bitwise-bit-set? spec i) 1 0)))
    (define inv-mask
      (for/fold ([acc 0]) ([i (in-range 5)])
        (bitwise-ior acc (arithmetic-shift (chi5-inv-bit yvec i) i))))
    (unless (= inv-mask mask)
      (error 'audit-keccak-chi5-hazards-and-mbu! "chi5 degree-3 inverse failed at ~a" mask))
    (unless (= seq-out spec)
      (set! seq-failures (add1 seq-failures)))
    (unless (= double-chi mask)
      (set! non-involution-failures (add1 non-involution-failures))))

  (define (mask->reg nbits m)
    (for/vector ([i (in-range nbits)])
      (if (bitwise-bit-set? m i) 1 0)))
  (define (reg->mask reg lo hi)
    (for/fold ([acc 0]) ([i (in-range lo hi)])
      (bitwise-ior acc (arithmetic-shift (vector-ref reg i) (- i lo)))))

  ;; 2. Verify `chi5-out-of-place-mbu-sexpr` across ALL 32 inputs and ALL 2^5 = 32 measurement branches!
  (define oop-gates (compile-lakefill-pareto (chi5-out-of-place-mbu-sexpr '(0 1 2 3 4) '(5 6 7 8 9) '(10 11 12 13 14))))
  (for ([mask (in-range 32)])
    (define spec (ref-chi5-u5 mask))
    (define out-reg (eval-mbu-circuit-all-branches (mask->reg 15 mask) oop-gates '(10 11 12 13 14)))
    (unless (and (= (reg->mask out-reg 0 5) mask)
                 (= (reg->mask out-reg 5 10) spec))
      (error 'audit-keccak-chi5-hazards-and-mbu!
             "Out-of-place MBU chi5 failed at mask ~a: got ~a" mask out-reg)))

  ;; 3. Verify `chi5-two-backup-inplace-mbu-sexpr` (`8` qubits total!) across ALL 32 inputs & branches!
  (define inp-gates (compile-lakefill-pareto (chi5-two-backup-inplace-mbu-sexpr '(0 1 2 3 4) 5 6 7)))
  (for ([mask (in-range 32)])
    (define spec (ref-chi5-u5 mask))
    (define out-reg (eval-mbu-circuit-all-branches (mask->reg 8 mask) inp-gates '(5 6 7)))
    (unless (= (reg->mask out-reg 0 5) spec)
      (error 'audit-keccak-chi5-hazards-and-mbu!
             "2-backup in-place MBU chi5 failed at mask ~a: got ~a" mask out-reg)))

  ;; 4. Z3 Miter catching naive sequential overwrite (`SAT`)
  (define mgr (make-xag-manager 512))
  (define in5 (for/list ([i (in-range 5)]) (xag-var mgr i)))
  (define spec5
    (for/list ([i (in-range 5)])
      (xag-xor mgr
               (list-ref in5 i)
               (xag-and mgr (lit-not (list-ref in5 (modulo (+ i 1) 5)))
                        (list-ref in5 (modulo (+ i 2) 5))))))
  (define seq-vec (list->vector in5))
  (for ([i (in-range 5)])
    (vector-set! seq-vec i
                 (xag-xor mgr
                          (vector-ref seq-vec i)
                          (xag-and mgr
                                   (lit-not (vector-ref seq-vec (modulo (+ i 1) 5)))
                                   (vector-ref seq-vec (modulo (+ i 2) 5))))))
  (define seq-diff (xag-vec-xor mgr spec5 (vector->list seq-vec)))
  (define-values (seq-z3-status seq-z3-cex _seq-mode)
    (xag-z3-cut-sweep-miter! mgr seq-diff '(0 1 2 3 4) 'all))

  (unless (and (> seq-failures 0)
               (> non-involution-failures 0)
               (eq? seq-z3-status 'sat))
    (error 'audit-keccak-chi5-hazards-and-mbu! "Expected Z3 SAT on buggy sequential chi5"))

  (hasheq 'inputs_tested 32
          'naive_sequential_overwrite_corrupted_inputs seq-failures
          'reverc_forward_uncompute_corrupted_inputs non-involution-failures
          'naive_sequential_z3_status (symbol->string seq-z3-status)
          'naive_sequential_z3_cex seq-z3-cex
          'lakefillq_oop_mbu_toffolis (hash-ref (count-gate-ops oop-gates) 'ccx)
          'lakefillq_oop_mbu_measurements (hash-ref (count-gate-ops oop-gates) 'mbu)
          'lakefillq_oop_mbu_reverse_toffolis 0
          'lakefillq_oop_mbu_exact_inputs 32
          'lakefillq_2backup_inplace_exact_inputs 32))

;; =============================================================================
;; SECTION 5: Correctness Finding 4 — Tower-Field `GF(((2^2)^2)^2)` Endianness
;;            & `0x00 -> 0x63` Blind-Spot Audit (`256/256` + `XAG/Z3`)
;; =============================================================================

(define (sota-cols->gf2-mat m col-masks)
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-bit-field (list-ref col-masks c) r (add1 r)))))

(define (sota-gf2-matmul A B)
  (define m (vector-length A))
  (for/vector ([r (in-range m)])
    (for/vector ([c (in-range m)])
      (bitwise-and 1 (for/sum ([k (in-range m)])
                       (* (vector-ref (vector-ref A r) k)
                          (vector-ref (vector-ref B k) c)))))))

(define (sota-gf2-matinv M)
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

(define (sota-gf2-mat->cx-only-sexpr mat wires)
  (define m (vector-length mat))
  (define rows (for/vector ([r (in-range m)]) (vector-copy (vector-ref mat r))))
  (define recorded '())
  (for ([col (in-range m)])
    (when (zero? (vector-ref (vector-ref rows col) col))
      (define piv
        (for/first ([r (in-range (add1 col) m)]
                    #:when (= (vector-ref (vector-ref rows r) col) 1))
          r))
      (define c-vec (vector-ref rows col))
      (define p-vec (vector-ref rows piv))
      (for ([j (in-range m)])
        (vector-set! c-vec j (bitwise-xor (vector-ref c-vec j) (vector-ref p-vec j))))
      (set! recorded (cons (cons piv col) recorded)))
    (for ([r (in-range m)]
          #:when (and (not (= r col)) (= (vector-ref (vector-ref rows r) col) 1)))
      (define r-vec (vector-ref rows r))
      (define c-vec (vector-ref rows col))
      (for ([j (in-range m)])
        (vector-set! r-vec j (bitwise-xor (vector-ref r-vec j) (vector-ref c-vec j))))
      (set! recorded (cons (cons col r) recorded))))
  (define wv (list->vector wires))
  `(seq ,@(for/list ([p (in-list recorded)])
            `(cx ,(vector-ref wv (car p)) ,(vector-ref wv (cdr p))))))

(define (sota-gf4-mul-xor-sexpr a b out)
  (match-define (list a0 a1) a)
  (match-define (list b0 b1) b)
  (match-define (list o0 o1) out)
  `(seq (ccx ,a0 ,b0 ,o0)
        (ccx ,a1 ,b1 ,o0)
        (ccx ,a0 ,b1 ,o1)
        (ccx ,a1 ,b0 ,o1)
        (ccx ,a1 ,b1 ,o1)))

(define (sota-gf16-mul-xor-sexpr a b out)
  (match-define (list a0 a1 a2 a3) a)
  (match-define (list b0 b1 b2 b3) b)
  (match-define (list o0 o1 o2 o3) out)
  (define aL (list a0 a1))
  (define aH (list a2 a3))
  (define bL (list b0 b1))
  (define bH (list b2 b3))
  (define oL (list o0 o1))
  (define oH (list o2 o3))
  `(seq ,(sota-gf4-mul-xor-sexpr aL bL oL)
        (ccx ,a2 ,b3 ,o0) (ccx ,a3 ,b2 ,o0) (ccx ,a3 ,b3 ,o0)
        (ccx ,a2 ,b2 ,o1) (ccx ,a2 ,b3 ,o1) (ccx ,a3 ,b2 ,o1)
        ,(sota-gf4-mul-xor-sexpr aL bH oH)
        ,(sota-gf4-mul-xor-sexpr aH bL oH)
        ,(sota-gf4-mul-xor-sexpr aH bH oH)))

(define (sota-gf256-tower-inv-sexpr x8 out8 sc16)
  (define xL (take x8 4))
  (define xH (drop x8 4))
  (define oL (take out8 4))
  (define oH (drop out8 4))
  (define c4    (take sc16 4))
  (define d4    (take (drop sc16 4) 4))
  (define dinv4 (take (drop sc16 8) 4))
  (define sub4  (drop sc16 12))
  (match-define (list xh0 xh1 xh2 xh3) xH)
  (match-define (list d0 d1 d2 d3) d4)
  `(within-apply
    (seq ,@(for/list ([xl (in-list xL)] [xh (in-list xH)] [c (in-list c4)])
             `(seq (cx ,xl ,c) (cx ,xh ,c)))
         ,(sota-gf16-mul-xor-sexpr xL c4 d4)
         (cx ,xh2 ,d0)
         (cx ,xh2 ,d1) (cx ,xh3 ,d1)
         (cx ,xh1 ,d2) (cx ,xh2 ,d2) (cx ,xh3 ,d2)
         (cx ,xh0 ,d3) (cx ,xh3 ,d3)
         ,(gf16-tower-inv-sexpr d4 dinv4 sub4))
    (seq ,(sota-gf16-mul-xor-sexpr c4 dinv4 oL)
         ,(sota-gf16-mul-xor-sexpr xH dinv4 oH))
    ,sc16))

(define sota-tower-to-aes-mat (sota-cols->gf2-mat 8 '(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f)))
(define sota-aes-to-tower-mat (sota-gf2-matinv sota-tower-to-aes-mat))
(define sota-post-sbox-mat    (sota-gf2-matmul sota-aes-affine-mat sota-tower-to-aes-mat))

(define bit-reverse-8-mat
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (if (= (+ r c) 7) 1 0))))

(define (sota-tower-sbox-with-basis-sexpr in-basis-mat in8 out8 sc16)
  `(seq (within-apply
         ,(sota-gf2-mat->cx-only-sexpr in-basis-mat in8)
         ,(sota-gf256-tower-inv-sexpr in8 out8 sc16)
         ,sc16)
        ,(sota-gf2-mat->cx-only-sexpr sota-post-sbox-mat out8)
        (x ,(list-ref out8 0))
        (x ,(list-ref out8 1))
        (x ,(list-ref out8 5))
        (x ,(list-ref out8 6))))

(define (audit-tower-field-endianness-miter!)
  (define (eval-32-mask x gates)
    (define reg (for/vector ([i (in-range 32)]) (if (bitwise-bit-set? x i) 1 0)))
    (eval-reversible-gates! reg gates)
    (for/fold ([acc 0]) ([i (in-range 32)])
      (bitwise-ior acc (arithmetic-shift (vector-ref reg i) i))))

  ;; 1. Verify exact composite tower S-box across all `256/256` bytes
  (define exact-sbox-gates
    (compile-lakefill-pareto
     (sota-tower-sbox-with-basis-sexpr sota-aes-to-tower-mat (range 8) (range 8 16) (range 16 32))
     #:mode 'unitary-symmetric))
  (for ([x (in-range 256)])
    (define out-mask (eval-32-mask x exact-sbox-gates))
    (define s-val (bitwise-bit-field out-mask 8 16))
    (define in-restored (bitwise-bit-field out-mask 0 8))
    (define sc-clean (bitwise-bit-field out-mask 16 32))
    (unless (and (= s-val (vector-ref aes-ref-sbox-vec x))
                 (= in-restored x)
                 (zero? sc-clean))
      (error 'audit-tower-field-endianness-miter! "Exact tower S-box mismatch at byte ~a" x)))

  ;; 2. Bit-reversed endianness matrix `P_rev * aes-to-tower-mat`:
  ;;    Passes `0x00 -> 0x63`, yet fails on nonzero bytes!
  (define buggy-in-mat (sota-gf2-matmul bit-reverse-8-mat sota-aes-to-tower-mat))
  (define buggy-gates
    (compile-lakefill-pareto
     (sota-tower-sbox-with-basis-sexpr buggy-in-mat (range 8) (range 8 16) (range 16 32))
     #:mode 'unitary-symmetric))

  (define buggy-zero-out (bitwise-bit-field (eval-32-mask 0 buggy-gates) 8 16))
  (define nonzero-mismatches
    (for/sum ([x (in-range 1 256)])
      (define s-bug (bitwise-bit-field (eval-32-mask x buggy-gates) 8 16))
      (if (= s-bug (vector-ref aes-ref-sbox-vec x)) 0 1)))

  ;; 3. XAG + Z3 equivalence miter (`UNSAT` for true basis, `SAT` in `< 10 ms` for bit-reversed basis)
  (define mgr (make-xag-manager 4096))
  (define in8 (for/list ([i (in-range 8)]) (xag-var mgr i)))
  (define z24 (make-list 24 lit-zero))
  (define id-wmap (make-hash))
  (define true-all32 (xag-sim-gates-with-wmap mgr (append in8 z24) exact-sbox-gates id-wmap))
  (define bug-all32  (xag-sim-gates-with-wmap mgr (append in8 z24) buggy-gates id-wmap))
  (define true-out8 (take (drop true-all32 8) 8))
  (define bug-out8  (take (drop bug-all32 8) 8))

  ;; Also build Boyar-Peralta `BP34` S-box in the same XAG and prove `true-tower == BP34` (`UNSAT`)!
  (define bp34-gates
    (compile-lakefill-pareto
     (aes-sbox-bp34-zero-fanin-xor-sexpr (range 8) (range 8 16) (range 16 50))
     #:mode 'unitary-symmetric))
  (define bp34-all50 (xag-sim-gates-with-wmap mgr (append in8 (make-list 42 lit-zero)) bp34-gates id-wmap))
  (define bp34-out8 (take (drop bp34-all50 8) 8))

  (define t0 (current-inexact-monotonic-milliseconds))
  (define-values (true-vs-bp34-status _cex0 _m0)
    (xag-z3-cut-sweep-miter! mgr (xag-vec-xor mgr true-out8 bp34-out8) (range 8) 'all))
  (define true-ms (- (current-inexact-monotonic-milliseconds) t0))

  (define t1 (current-inexact-monotonic-milliseconds))
  (define-values (bug-status bug-cex _m1)
    (xag-z3-cut-sweep-miter! mgr (xag-vec-xor mgr true-out8 bug-out8) (range 8) 'all))
  (define bug-ms (- (current-inexact-monotonic-milliseconds) t1))

  (unless (and (= buggy-zero-out #x63)
               (> nonzero-mismatches 200)
               (eq? true-vs-bp34-status 'unsat)
               (eq? bug-status 'sat))
    (error 'audit-tower-field-endianness-miter!
           "Tower-field endianness audit failed: zero=~a mismatches=~a true=~a bug=~a"
           buggy-zero-out nonzero-mismatches true-vs-bp34-status bug-status))

  (hasheq 'exact_tower_bytes_verified 256
          'buggy_reversed_basis_at_0x00 buggy-zero-out
          'buggy_reversed_basis_passes_0x00_test (= buggy-zero-out #x63)
          'buggy_reversed_basis_nonzero_mismatches nonzero-mismatches
          'tower_vs_bp34_z3_status (symbol->string true-vs-bp34-status)
          'tower_vs_bp34_z3_ms true-ms
          'reversed_basis_z3_status (symbol->string bug-status)
          'reversed_basis_z3_ms bug-ms
          'reversed_basis_z3_cex bug-cex))

;; =============================================================================
;; SECTION 6: Optimization Finding 2B — `SPHINCS+-128s` (`SLH-DSA-SHAKE-128s`)
;;            `PK.seed` + `ADRS` Constant-Lane `XAG` Specialization
;; =============================================================================

;; Symbolic 1600-bit initial step of Keccak-f[1600] (`theta -> rho -> pi -> chi -> iota`)
;; inside `xag-manager`.
(define (xag-keccak1600-initial-step mgr state1600-lits)
  (define state (list->vector state1600-lits))
  (define (at x y z)
    (vector-ref state (+ (* 64 (keccak-lane-idx x y)) z)))

  ;; 1. Theta (`C[x, z] = xor_y A[x, y, z]`, `D[x, z] = C[x-1, z] ^ C[x+1, (z-1)%64]`)
  (define C
    (for/vector ([x (in-range 5)])
      (for/vector ([z (in-range 64)])
        (for/fold ([acc lit-zero]) ([y (in-range 5)])
          (xag-xor mgr acc (at x y z))))))
  (define D
    (for/vector ([x (in-range 5)])
      (for/vector ([z (in-range 64)])
        (xag-xor mgr
                 (vector-ref (vector-ref C (modulo (- x 1) 5)) z)
                 (vector-ref (vector-ref C (modulo (+ x 1) 5)) (modulo (- z 1) 64))))))
  (define after-theta
    (for/vector ([idx (in-range 1600)])
      (define lane (quotient idx 64))
      (define z (modulo idx 64))
      (define x (modulo lane 5))
      (xag-xor mgr (vector-ref state idx) (vector-ref (vector-ref D x) z))))

  ;; 2. Rho o Pi (`0` gates, pure wire relabeling via `keccak-rho-pi-wire-perm-1600`!)
  (define B
    (for/vector ([dst (in-range 1600)])
      (vector-ref after-theta (list-ref keccak-rho-pi-wire-perm-1600 dst))))

  ;; 3. Chi (`out[x, y, z] = B[x, y, z] ^ (~B[x+1, y, z] & B[x+2, y, z])`)
  (define after-chi
    (for/vector ([idx (in-range 1600)])
      (define lane (quotient idx 64))
      (define z (modulo idx 64))
      (define x (modulo lane 5))
      (define y (quotient lane 5))
      (define b0 (vector-ref B idx))
      (define b1 (vector-ref B (+ (* 64 (keccak-lane-idx (modulo (+ x 1) 5) y)) z)))
      (define b2 (vector-ref B (+ (* 64 (keccak-lane-idx (modulo (+ x 2) 5) y)) z)))
      (xag-xor mgr b0 (xag-and mgr (lit-not b1) b2))))

  ;; 4. Iota (`RC[0] = #x0000000000000001` XORed into bit 0 of lane (0,0))
  (vector-set! after-chi 0 (lit-not (vector-ref after-chi 0)))
  (vector->list after-chi))

(define (count-xag-and-nodes mgr)
  (define kv (xag-manager-kind-vec mgr))
  (for/sum ([nid (in-range 1 (xag-manager-size mgr))])
    (if (eq? (vector-ref kv nid) 'and) 1 0)))

(define (u64->xag-const-lits u64)
  (for/list ([z (in-range 64)])
    (if (bitwise-bit-set? u64 z) lit-one lit-zero)))

(define (audit-sphincs-shake256-constant-lane-xag!)
  ;; 1. Unspecialized Keccak-f[1600] initial step (`25` symbolic lanes = `1600` quantum bits)
  (define mgr-full (make-xag-manager 8192))
  (define full-in (for/list ([i (in-range 1600)]) (xag-var mgr-full i)))
  (define _full-out (xag-keccak1600-initial-step mgr-full full-in))
  (define full-ands (count-xag-and-nodes mgr-full))

  ;; 2. SPHINCS+-128s (`SLH-DSA-SHAKE-128s`, FIPS 205) tweakable hash `T_1(PK.seed, ADRS, M)`:
  ;;    - `PK.seed` (16 bytes = lanes 0..1): public constant
  ;;    - `ADRS`    (32 bytes = lanes 2..5): public constant
  ;;    - `M`       (16 bytes = lanes 6..7): 128-bit quantum input (`x_0 .. x_127`)
  ;;    - Padding   (lanes 8..16): `0x1f` at lane 8 low byte, `0x80 << 56` at lane 16
  ;;    - Capacity  (lanes 17..24): `0` (`c = 512` bits for SHAKE256)
  (define pk-seed-lanes '(#x6a09e667bb67ae85 #x3c6ef372a54ff53a))
  (define adrs-lanes    '(#x0000000300000000 #x0000000000000015 #x0000000200000007 #x0000000000000001))

  (define mgr-spec (make-xag-manager 8192))
  (define q-vars (for/list ([i (in-range 128)]) (xag-var mgr-spec i)))
  (define spec-in
    (append
     (append* (map u64->xag-const-lits pk-seed-lanes)) ;; lanes 0..1 (PK.seed)
     (append* (map u64->xag-const-lits adrs-lanes))    ;; lanes 2..5 (ADRS)
     q-vars                                            ;; lanes 6..7 (128-bit quantum M)
     (u64->xag-const-lits #x000000000000001f)          ;; lane 8 (SHAKE256 domain sep 0x1F)
     (append* (make-list 7 (u64->xag-const-lits 0)))   ;; lanes 9..15 (zero pad)
     (u64->xag-const-lits #x8000000000000000)          ;; lane 16 (rate end pad 0x80)
     (append* (make-list 8 (u64->xag-const-lits 0))))) ;; lanes 17..24 (512-bit capacity = 0)

  (define spec-out (xag-keccak1600-initial-step mgr-spec spec-in))
  (define spec-ands (count-xag-and-nodes mgr-spec))

  ;; 3. Cross-check specialized 960-AND XAG against concrete bit evaluation on 8 test messages
  (for ([t (in-range 8)])
    (define env
      (for/hasheqv ([i (in-range 128)])
        (values i (bitwise-and 1 (+ i t (quotient i 7))))))
    (define full-env
      (for/hasheqv ([idx (in-range 1600)])
        (define lit (list-ref spec-in idx))
        (values idx
                (cond
                  [(= lit lit-zero) 0]
                  [(= lit lit-one) 1]
                  [else (xag-eval-lit mgr-spec lit env)]))))
    (for ([idx (in-range 1600)])
      (define v-spec (xag-eval-lit mgr-spec (list-ref spec-out idx) env))
      (define v-full (xag-eval-lit mgr-full (list-ref _full-out idx) full-env))
      (unless (= v-spec v-full)
        (error 'audit-sphincs-shake256-constant-lane-xag!
               "Specialized SPHINCS+ Keccak mismatch at bit ~a" idx))))

  (define saved-ands (- full-ands spec-ands))
  (define pct-saved (* 100.0 (/ (exact->inexact saved-ands) (exact->inexact full-ands))))
  (unless (and (= full-ands 1600) (<= spec-ands 960) (> pct-saved 25.0))
    (error 'audit-sphincs-shake256-constant-lane-xag!
           "Expected <= 960 TempAND folding (>25%), got ~a -> ~a" full-ands spec-ands))

  (hasheq 'sponge_state_bits 1600
          'shake256_rate_lanes 17
          'shake256_capacity_lanes 8
          'classical_constant_input_lanes 23
          'quantum_preimage_lanes 2
          'unspecialized_initial_step_tempands full-ands
          'constant_lane_bound_tempands 960
          'specialized_xag_hash_consed_tempands spec-ands
          'initial_step_tempands_eliminated saved-ands
          'initial_step_reduction_percent pct-saved
          'slh_dsa_sha2_dedicated_pk_seed_block_eliminated_percent 100.0))

;; =============================================================================
;; SECTION 7: Top-Level SOTA Audit Runner
;; =============================================================================

(define (run-all-sota-symmetric-hash-audits!)
  (define opt1 (compile-zero-gate-wire-perm-demo))
  (define corr1 (audit-mixcolumns-plu-miter!))
  (define corr2 (aes-spurious-key-table))
  (define opt2a (aes-two-step-shifted-col0-cone-audit!))
  (define corr3 (audit-keccak-chi5-hazards-and-mbu!))
  (define corr4 (audit-tower-field-endianness-miter!))
  (define opt2b (audit-sphincs-shake256-constant-lane-xag!))
  (close-persistent-z3!)
  (hasheq 'status "PASS"
          'optimization_1_zero_gate_wire_perm opt1
          'correctness_1_mixcolumns_plu_miter corr1
          'correctness_2_aes_spurious_keys corr2
          'optimization_2a_aes_4byte_cone_filter opt2a
          'correctness_3_keccak_chi5_hazards corr3
          'correctness_4_tower_field_endianness corr4
          'optimization_2b_sphincs_constant_lanes opt2b))

(module+ main
  (define res (run-all-sota-symmetric-hash-audits!))
  (displayln (jsexpr->string res)))
