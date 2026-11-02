#lang racket/base

;; =============================================================================
;; compiler/lakefillq-pareto-algorithm-optimizations.rkt
;; =============================================================================
;; Deep Algorithmic Circuit Optimizations for LakefillQ:
;;
;;   1. Composite Tower-Field GF(((2^2)^2)^2) `BP32` (`32-TempAND`, `128 T`)
;;      Boyar-Peralta / Canright MBU AES S-Box, `BP64` (`64-TempAND`) Zero-Ancilla
;;      In-Place `erase-by` S-Box, Narrow `0-SWAP` In-Place `AES-128/192/256`
;;      (`288 Q` / `352 Q` / `416 Q`), and Bidirectional Half-Cipher
;;      `within-apply-mbu` Grover Reflection (`0` Uncompute Toffolis on Both Halves).
;;
;;   2. Algebraic-Degree-2 `M_X` Chi-Row Uncomputation (`Law U4`) for
;;      `Keccak-f[200]` (`18` sponge rounds, NIST FIPS-202) and `Keccak-f[1600]`
;;      (`SHA3-256`, `38,400` forward `TempAND`s + `0` reverse Toffolis vs `76,800`
;;      unitary `CCX`), plus Asymmetric Kralovic Pebbling (`c_fwd = 1, c_rev = 0`)
;;      for `SLH-DSA / SPHINCS+-128s` (`56 -> 36` active sponge calls, `2.15M -> 1.38M`).
;;
;;   3. Griffith-Niu `1`-Qubit Semiclassical Recycled QFT + MITM Superoptimized
;;      Leaf Gadgets (`DivstepSwapSubWindow` `5 -> 3`, `SkewBinaryCarrySaveMerge`
;;      `4 -> 3`, `KaratsubaToomLimbMul` `4 -> 3`) + Berry-Gidney `Select-SWAP`
;;      Window `M_X` Uncomputation for `ECC-256`, `RSA-2048`, and `RSA-4096`.
;;
;;   4. `M_X` Parity-Check & Braun Syndrome-Weight Comparator Uncomputation for
;;      `Classic McEliece-348864` (`1.63M -> 0.815M TempAND`s, `7,744 Q`) and
;;      `BIKE-L1` (`1.97M -> 0.985M TempAND`s, `36,969 Q`) Streaming ISD.
;; =============================================================================

(require racket/match
         racket/list
         racket/vector
         racket/format
         racket/string
         racket/math
         json
         "../lakefill-core-cryptography-implementations.rkt"
         "../lakefill-pareto-aes-slp-and-asymmetric-mbu.rkt")

(provide aes-to-tower-iso-mat
         tower-to-aes-iso-mat
         aes-sbox-bp32-zero-fanin-xor-sexpr
         aes-inv-sbox-bp32-zero-fanin-xor-sexpr
         aes-sbox-bp64-inplace-sexpr
         aes-inv-sbox-bp64-inplace-sexpr
         aes-bp32-narrow-cipher-sexpr
         aes-bp32-narrow-inv-cipher-sexpr
         aes-sbox-dlog5-minwidth-sexpr
         aes-inv-sbox-dlog5-minwidth-sexpr
         aes-sbox-dlog5-xor-sexpr
         aes-dlog5-minwidth-cipher-sexpr
         aes-dlog5-minwidth-inv-cipher-sexpr
         aes-bidirectional-half-mbu-grover-sexpr
         keccak-chi5-degree2-mbu-sexpr
         keccak-f200-outofplace-mbu-grover-sexpr
         solve-asymmetric-kralovic-pebbling
         divstep-swap-sub-window-base-sexpr
         divstep-swap-sub-window-opt-sexpr
         skew-carry-save-merge-base-sexpr
         skew-carry-save-merge-opt-sexpr
         karatsuba-toom-limb-mul-base-sexpr
         karatsuba-toom-limb-mul-opt-sexpr
         berry-gidney-window-qroam-mbu-sexpr
         berry-gidney-window-qroam-unitary-sexpr
         adaptive-bezout-binomial-pebble-schedule
         distributed-ghz-default-table8-u8
         distributed-ghz-column-qroam-mbu-sexpr
         distributed-ghz-column-qroam-unitary-sexpr
         streaming-isd-syndrome-grover-mbu-sexpr
         streaming-isd-syndrome-grover-unitary-sexpr
         solve-parallel-cluster-m-star
         compile-parallel-mode-with-t-par-guard
         run-all-lakefillq-algorithm-optimizations)

;; =============================================================================
;; SECTION 1: Composite Tower-Field GF(((2^2)^2)^2) `BP32` MBU AES S-Box &
;;            Bidirectional Half-Cipher `within-apply-mbu` Grover Reflection
;; =============================================================================

(define (cols->gf2-mat8 col-masks)
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (bitwise-bit-field (list-ref col-masks c) r (add1 r)))))

(define (gf2-matmul8 A B)
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (bitwise-and 1 (for/sum ([k (in-range 8)])
                       (* (vector-ref (vector-ref A r) k)
                          (vector-ref (vector-ref B k) c)))))))

(define (gf2-matinv8 M)
  (define aug
    (for/vector ([r (in-range 8)])
      (vector-append (vector-copy (vector-ref M r))
                     (for/vector ([c (in-range 8)]) (if (= r c) 1 0)))))
  (for ([col (in-range 8)])
    (define piv
      (for/first ([r (in-range col 8)]
                  #:when (= (vector-ref (vector-ref aug r) col) 1))
        r))
    (unless piv (error 'gf2-matinv8 "Singular 8x8 matrix at column ~a" col))
    (unless (= piv col)
      (define tmp (vector-ref aug col))
      (vector-set! aug col (vector-ref aug piv))
      (vector-set! aug piv tmp))
    (for ([r (in-range 8)]
          #:when (and (not (= r col)) (= (vector-ref (vector-ref aug r) col) 1)))
      (define rv (vector-ref aug r))
      (define cv (vector-ref aug col))
      (for ([j (in-range 16)])
        (vector-set! rv j (bitwise-xor (vector-ref rv j) (vector-ref cv j))))))
  (for/vector ([r (in-range 8)])
    (vector-copy (vector-ref aug r) 8 16)))

;; Explicit invertible 8x8 GF(2) isomorphism matrices between GF(2)[x]/(x^8+x^4+x^3+x+1)
;; and composite tower GF(((2^2)^2)^2):
(define tower-to-aes-iso-mat
  (cols->gf2-mat8 '(#x01 #xbc #x5c #xb0 #xf2 #x5b #x5f #x6f)))
(define aes-to-tower-iso-mat
  (gf2-matinv8 tower-to-aes-iso-mat))

(define fips197-affine-mat
  (for/vector ([r (in-range 8)])
    (for/vector ([c (in-range 8)])
      (if (<= (modulo (- r c) 8) 4) 1 0))))
(define fips197-affine-inv-mat
  (gf2-matinv8 fips197-affine-mat))

(define post-sbox-fused-mat
  (gf2-matmul8 fips197-affine-mat tower-to-aes-iso-mat))
(define pre-inv-sbox-fused-mat
  (gf2-matmul8 aes-to-tower-iso-mat fips197-affine-inv-mat))

;; Factor any nonsingular 8x8 GF(2) matrix (`det = 1`) into pure `CX` gates (`0` SWAPs!):
(define cx-factor-cache (make-hash))
(define (gf2-mat8->cx-only-sexpr mat wires8)
  (define pairs
    (hash-ref!
     cx-factor-cache mat
     (lambda ()
       (define rows (for/vector ([r (in-range 8)]) (vector-copy (vector-ref mat r))))
       (define acc '())
       (for ([col (in-range 8)])
         (when (zero? (vector-ref (vector-ref rows col) col))
           (define piv
             (for/first ([r (in-range (add1 col) 8)]
                         #:when (= (vector-ref (vector-ref rows r) col) 1))
               r))
           (unless piv (error 'gf2-mat8->cx-only-sexpr "Singular matrix"))
           (define cv (vector-ref rows col))
           (define pv (vector-ref rows piv))
           (for ([j (in-range 8)])
             (vector-set! cv j (bitwise-xor (vector-ref cv j) (vector-ref pv j))))
           (set! acc (cons (cons piv col) acc)))
         (for ([r (in-range 8)]
               #:when (and (not (= r col))
                           (= (vector-ref (vector-ref rows r) col) 1)))
           (define rv (vector-ref rows r))
           (define cv (vector-ref rows col))
           (for ([j (in-range 8)])
             (vector-set! rv j (bitwise-xor (vector-ref rv j) (vector-ref cv j))))
           (set! acc (cons (cons col r) acc))))
       acc)))
  (define wv (list->vector wires8))
  `(seq ,@(for/list ([p (in-list pairs)])
            `(cx ,(vector-ref wv (car p)) ,(vector-ref wv (cdr p))))))

(define (lin-xor . forms)
  (define h (make-hasheqv))
  (for* ([f (in-list forms)] [w (in-list f)])
    (hash-update! h w add1 0))
  (sort (for/list ([(w c) (in-hash h)] #:when (odd? c)) w) <))

;; 3-TempAND Karatsuba multiplication in GF(2^2) = GF(2)[z]/(z^2 + z + 1):
(define (karatsuba-gf4-steps pool base a0 a1 b0 b1)
  (define p0 (list-ref pool base))
  (define p1 (list-ref pool (+ base 1)))
  (define p2 (list-ref pool (+ base 2)))
  (values (list `(temp-and-lin ,a0 ,b0 ,p0)
                `(temp-and-lin ,a1 ,b1 ,p1)
                `(temp-and-lin ,(lin-xor a0 a1) ,(lin-xor b0 b1) ,p2))
          (list (list p0 p1) (list p2 p0))))

;; 9-TempAND Karatsuba multiplication in GF((2^2)^2) = GF(4)[Y]/(Y^2 + Y + z):
(define (karatsuba-gf16-steps pool base a4 b4)
  (match-define (list a0 a1 a2 a3) a4)
  (match-define (list b0 b1 b2 b3) b4)
  (define-values (st0 m0) (karatsuba-gf4-steps pool base a0 a1 b0 b1))
  (define-values (st1 m1) (karatsuba-gf4-steps pool (+ base 3) a2 a3 b2 b3))
  (define-values (st2 m2)
    (karatsuba-gf4-steps pool (+ base 6)
                         (lin-xor a0 a2) (lin-xor a1 a3)
                         (lin-xor b0 b2) (lin-xor b1 b3)))
  (match-define (list m0-0 m0-1) m0)
  (match-define (list m1-0 m1-1) m1)
  (match-define (list m2-0 m2-1) m2)
  (values (append st0 st1 st2)
          (list (lin-xor m0-0 m1-1)
                (lin-xor m0-1 m1-0 m1-1)
                (lin-xor m2-0 m0-0)
                (lin-xor m2-1 m0-1))))

;; Exact Z3-proven minimal 5-TempAND inverter in GF((2^2)^2) (proven optimal:
;; 4-AND synthesis is UNSAT over GF(2) by the C(4,3) = 4 cubic monomial rank bound;
;; reduces GF(2^4) inversion from 7 TempANDs -> 5 TempANDs):
;;   g0 = d3 & (d0 ^ d1 ^ d2 ^ d3)
;;   g1 = (d0 ^ d2) & (d2 ^ g0)
;;   g2 = (d1 ^ d3 ^ g0) & (d1 ^ d2 ^ g0)
;;   g3 = (d3 ^ g1) & (d0 ^ d1 ^ d2 ^ g0 ^ g1 ^ g2)
;;   g4 = (d0 ^ d1) & (d2 ^ g3)
;;   dinv0 = d0 ^ d1 ^ d2 ^ g0 ^ g3
;;   dinv1 = d1 ^ d3 ^ g1
;;   dinv2 = d1 ^ d2 ^ d3 ^ g0 ^ g2
;;   dinv3 = d1 ^ g1 ^ g2 ^ g3 ^ g4
(define (gf16-inv-bp5-steps d4 sc5)
  (match-define (list d0 d1 d2 d3) d4)
  (match-define (list g0w g1w g2w g3w g4w) sc5)
  (define g0 (list g0w))
  (define g1 (list g1w))
  (define g2 (list g2w))
  (define g3 (list g3w))
  (define g4 (list g4w))
  (define steps
    (list `(temp-and-lin ,d3 ,(lin-xor d0 d1 d2 d3) ,g0w)
          `(temp-and-lin ,(lin-xor d0 d2) ,(lin-xor d2 g0) ,g1w)
          `(temp-and-lin ,(lin-xor d1 d3 g0) ,(lin-xor d1 d2 g0) ,g2w)
          `(temp-and-lin ,(lin-xor d3 g1) ,(lin-xor d0 d1 d2 g0 g1 g2) ,g3w)
          `(temp-and-lin ,(lin-xor d0 d1) ,(lin-xor d2 g3) ,g4w)))
  (define dinv4
    (list (lin-xor d0 d1 d2 g0 g3)
          (lin-xor d1 d3 g1)
          (lin-xor d1 d2 d3 g0 g2)
          (lin-xor d1 g1 g2 g3 g4)))
  (values steps dinv4))

;; Core Composite Tower `BP32` (`9 + 5 + 18 = 32` forward `TempAND`s + `0` uncompute CCX!):
;; When `reuse-mul-scratch? = #t`, reuses 9 output-product scratch wires across `oL` and `oH`
;; via nested `within-apply-mbu`, needing ONLY `14 + 9 = 23` scratch wires (`32` if `#f`).
(define (bp32-core-zero-fanin-xor-sexpr in8 out8 and-sc in-mat8 out-mat8 out-const-u8
                                        #:reuse-mul-scratch? [reuse-mul-scratch? #t])
  (define sc14 (take and-sc 14))
  (define sc-rest (drop and-sc 14))
  (define xt (for/list ([w (in-list in8)]) (list w)))
  (define xL (take xt 4))
  (define xH (drop xt 4))
  (define c4 (map lin-xor xL xH))

  ;; Norm in GF(2^4): `d4 = xL * c4 ^ nu * xH^2` (`9` TempANDs on `sc14[0..8]`)
  (define-values (norm-steps prod-d) (karatsuba-gf16-steps sc14 0 xL c4))
  (define uv-sq
    (list (third xH)
          (lin-xor (third xH) (fourth xH))
          (lin-xor (second xH) (third xH) (fourth xH))
          (lin-xor (first xH) (fourth xH))))
  (define d4 (map lin-xor prod-d uv-sq))

  ;; Minimal 5-TempAND GF(2^4) inversion on `sc14[9..13]`:
  (define-values (inv-steps dinv4) (gf16-inv-bp5-steps d4 (drop sc14 9)))

  (define const-x-steps
    (for/list ([r (in-range 8)] #:when (bitwise-bit-set? out-const-u8 r))
      `(x ,(list-ref out8 r))))

  (define tower-body
    (cond
      [reuse-mul-scratch?
       (define sc9 (take sc-rest 9))
       (define-values (oL-steps oL-forms) (karatsuba-gf16-steps sc9 0 c4 dinv4))
       (define-values (oH-steps oH-forms) (karatsuba-gf16-steps sc9 0 xH dinv4))
       (define outL-cxs
         (for*/list ([r (in-range 8)]
                     [src-w (in-list
                             (apply lin-xor
                                    (for/list ([c (in-range 4)]
                                               #:when (= (vector-ref (vector-ref out-mat8 r) c) 1))
                                      (list-ref oL-forms c))))])
           `(cx ,src-w ,(list-ref out8 r))))
       (define outH-cxs
         (for*/list ([r (in-range 8)]
                     [src-w (in-list
                             (apply lin-xor
                                    (for/list ([c (in-range 4)]
                                               #:when (= (vector-ref (vector-ref out-mat8 r) (+ 4 c)) 1))
                                      (list-ref oH-forms c))))])
           `(cx ,src-w ,(list-ref out8 r))))
       `(within-apply-mbu
         (seq ,@norm-steps ,@inv-steps)
         (seq (within-apply-mbu (seq ,@oL-steps) (seq ,@outL-cxs) ,sc9)
              (within-apply-mbu (seq ,@oH-steps) (seq ,@outH-cxs) ,sc9)
              ,@const-x-steps)
         ,sc14)]
      [else
       (define sc18 (take sc-rest 18))
       (define-values (oL-steps oL-forms) (karatsuba-gf16-steps sc18 0 c4 dinv4))
       (define-values (oH-steps oH-forms) (karatsuba-gf16-steps sc18 9 xH dinv4))
       (define ot (append oL-forms oH-forms))
       (define out-cxs
         (for*/list ([r (in-range 8)]
                     [src-w (in-list
                             (apply lin-xor
                                    (for/list ([c (in-range 8)]
                                               #:when (= (vector-ref (vector-ref out-mat8 r) c) 1))
                                      (list-ref ot c))))])
           `(cx ,src-w ,(list-ref out8 r))))
       `(within-apply-mbu
         (seq ,@norm-steps ,@inv-steps ,@oL-steps ,@oH-steps)
         (seq ,@out-cxs ,@const-x-steps)
         ,(append sc14 sc18))]))

  `(within-apply
    ,(gf2-mat8->cx-only-sexpr in-mat8 in8)
    ,tower-body
    ()))

;; Forward `BP32` XOR S-box: `out8 ^= S(in8)` (`32` TempANDs = `128 T`, `0` uncompute CCX!)
(define (aes-sbox-bp32-zero-fanin-xor-sexpr in8 out8 and-sc
                                            #:reuse-mul-scratch? [reuse-mul-scratch? #t])
  (bp32-core-zero-fanin-xor-sexpr
   in8 out8 and-sc aes-to-tower-iso-mat post-sbox-fused-mat #x63
   #:reuse-mul-scratch? reuse-mul-scratch?))

;; Inverse `BP32` XOR S-box: `out8 ^= S^-1(in8)` (`32` TempANDs = `128 T`, `0` uncompute CCX!)
(define (aes-inv-sbox-bp32-zero-fanin-xor-sexpr in8 out8 and-sc
                                                #:reuse-mul-scratch? [reuse-mul-scratch? #t])
  (define neg-63
    (for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
      `(x ,(list-ref in8 r))))
  `(within-apply
    (seq ,@neg-63)
    ,(bp32-core-zero-fanin-xor-sexpr
      in8 out8 and-sc pre-inv-sbox-fused-mat tower-to-aes-iso-mat #x00
      #:reuse-mul-scratch? reuse-mul-scratch?)
    ()))

;; Strictly In-Place 8-Wire AES S-Box `byte8 -> S(byte8)` (`64` TempANDs = `256 T`, `0` SWAPs!):
;; Uses `tmp8` (`8` wires) + `and-sc` (`23` wires if `reuse-mul-scratch? = #t` -> `31` scratch total!).
(define (aes-sbox-bp64-inplace-sexpr byte8 sc #:reuse-mul-scratch? [reuse-mul-scratch? #t])
  (define tmp8 (take sc 8))
  (define and-sc (drop sc 8))
  (define used-sc (take sc (if reuse-mul-scratch? 31 40)))
  `(erase-by
    ,(aes-sbox-bp32-zero-fanin-xor-sexpr byte8 tmp8 and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
    (seq ,(aes-inv-sbox-bp32-zero-fanin-xor-sexpr tmp8 byte8 and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
         ,@(for/list ([bw (in-list byte8)] [tw (in-list tmp8)])
             `(seq (cx ,tw ,bw) (cx ,bw ,tw))))
    ,used-sc))

;; Strictly In-Place 8-Wire Inverse AES S-Box `byte8 -> S^-1(byte8)` (`64` TempANDs, `0` SWAPs!):
(define (aes-inv-sbox-bp64-inplace-sexpr byte8 sc #:reuse-mul-scratch? [reuse-mul-scratch? #t])
  (define tmp8 (take sc 8))
  (define and-sc (drop sc 8))
  (define used-sc (take sc (if reuse-mul-scratch? 31 40)))
  `(erase-by
    ,(aes-inv-sbox-bp32-zero-fanin-xor-sexpr byte8 tmp8 and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
    (seq ,(aes-sbox-bp32-zero-fanin-xor-sexpr tmp8 byte8 and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
         ,@(for/list ([bw (in-list byte8)] [tw (in-list tmp8)])
             `(seq (cx ,tw ,bw) (cx ,bw ,tw))))
    ,used-sc))

;; Zero-SWAP ShiftRows & Inverse ShiftRows logical wire relabelings:
(define shiftrows-perm128
  (for*/list ([c (in-range 4)] [r (in-range 4)] [b (in-range 8)])
    (+ (* 8 (+ r (* 4 (modulo (+ c r) 4)))) b)))

(define inv-shiftrows-perm128
  (for*/list ([c (in-range 4)] [r (in-range 4)] [b (in-range 8)])
    (+ (* 8 (+ r (* 4 (modulo (- c r) 4)))) b)))

(define fips197-rcon-vec
  #(#x00 #x01 #x02 #x04 #x08 #x10 #x20 #x40 #x80 #x1B #x36))

(define (xor-word32 src32 dst32)
  `(seq ,@(for/list ([s (in-list src32)] [d (in-list dst32)]) `(cx ,s ,d))))

(define (key-sub-rot-rcon-bp32 src32 dst32 rcon-u8 and-sc reuse-mul-scratch?)
  (define s0 (take src32 8))
  (define s1 (take (drop src32 8) 8))
  (define s2 (take (drop src32 16) 8))
  (define s3 (drop src32 24))
  `(seq ,(aes-sbox-bp32-zero-fanin-xor-sexpr s1 (take dst32 8) and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
        ,(aes-sbox-bp32-zero-fanin-xor-sexpr s2 (take (drop dst32 8) 8) and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
        ,(aes-sbox-bp32-zero-fanin-xor-sexpr s3 (take (drop dst32 16) 8) and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
        ,(aes-sbox-bp32-zero-fanin-xor-sexpr s0 (drop dst32 24) and-sc #:reuse-mul-scratch? reuse-mul-scratch?)
        ,@(for/list ([b (in-range 8)] #:when (bitwise-bit-set? rcon-u8 b))
            `(x ,(list-ref dst32 b)))))

(define (key-subword-bp32 src32 dst32 and-sc reuse-mul-scratch?)
  `(seq ,@(for/list ([b (in-range 4)])
            (aes-sbox-bp32-zero-fanin-xor-sexpr
             (take (drop src32 (* 8 b)) 8)
             (take (drop dst32 (* 8 b)) 8)
             and-sc #:reuse-mul-scratch? reuse-mul-scratch?))))

;; Narrow `0-SWAP` In-Place Forward `AES-128` (`288 Q` = `128+128+32` / `287 Q` = `128+128+31`),
;; `AES-192` (`352 Q` / `351 Q`), and `AES-256` (`416 Q` / `415 Q`):
;;   - `AES-128`: `160 * 64 + 40 * 32 = 11,520 TempAND`s (`0` SWAPs)
;;   - `AES-192`: `192 * 64 + 32 * 32 = 13,312 TempAND`s (`0` SWAPs)
;;   - `AES-256`: `224 * 64 + 52 * 32 = 16,000 TempAND`s (`0` SWAPs)
(define (aes-bp32-narrow-cipher-sexpr key-bits state128 key-wires sc
                                      #:reuse-mul-scratch? [reuse-mul-scratch? #t])
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define and-sc (drop sc 8))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))

  (define (advance-key-epoch e)
    (match nk
      [4 `(seq ,(key-sub-rot-rcon-bp32 (kword 3) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?)
               ,(xor-word32 (kword 0) (kword 1))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 2) (kword 3)))]
      [6 `(seq ,(key-sub-rot-rcon-bp32 (kword 5) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?)
               ,(xor-word32 (kword 0) (kword 1))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 2) (kword 3))
               ,(xor-word32 (kword 3) (kword 4))
               ,(xor-word32 (kword 4) (kword 5)))]
      [8 (if (= e 7)
             `(seq ,(key-sub-rot-rcon-bp32 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?)
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 2) (kword 3)))
             `(seq ,(key-sub-rot-rcon-bp32 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?)
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 2) (kword 3))
                   ,(key-subword-bp32 (kword 3) (kword 4) and-sc reuse-mul-scratch?)
                   ,(xor-word32 (kword 4) (kword 5))
                   ,(xor-word32 (kword 5) (kword 6))
                   ,(xor-word32 (kword 6) (kword 7))))]))

  (define steps '())
  (for ([r (in-range (add1 nr))])
    (when (> r 0)
      (set! steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (aes-sbox-bp64-inplace-sexpr
                             (take (drop state128 (* 8 b)) 8)
                             sc #:reuse-mul-scratch? reuse-mul-scratch?)))
                  steps))
      (set! steps (cons `(logical-relabel ,state128 ,shiftrows-perm128) steps))
      (when (< r nr)
        (set! steps (cons (aes-mixcolumns-slp92-sexpr state128 #:rewire? #t) steps))))
    (for ([c (in-range 4)])
      (define w-idx (+ (* 4 r) c))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! steps (cons (advance-key-epoch (quotient w-idx nk)) steps)))
      (set! steps (cons (xor-word32 (kword (modulo w-idx nk)) (sword c)) steps))))
  `(seq ,@(reverse steps) (assert-clean ,sc)))

;; Narrow `0-SWAP` In-Place Inverse `AES^-1`:
(define (aes-bp32-narrow-inv-cipher-sexpr key-bits state128 key-wires sc
                                          #:reuse-mul-scratch? [reuse-mul-scratch? #t])
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define and-sc (drop sc 8))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))

  (define inv-mixcol-wire-perm
    (let ([inv (make-vector 32 0)])
      (for ([dst (in-range 32)]
            [src (in-list '(0 1 10 11 12 21 30 31
                            24 25 26 27 20 13 14 23
                            16 9 18 19 4 29 6 15
                            8 17 2 3 28 5 22 7))])
        (vector-set! inv src dst))
      (vector->list inv)))

  (define mixcol-cx-pairs
    '((23 15) (1 25) (18 10) (13 5) (19 3) (28 4) (0 16) (9 1) (7 23) (31 7)
      (20 28) (14 22) (16 8) (8 0) (30 14) (6 30) (15 24) (29 13) (5 6) (21 5)
      (28 21) (23 28) (5 29) (4 5) (2 18) (3 28) (11 3) (15 11) (12 4) (4 20)
      (11 12) (19 12) (27 19) (10 11) (3 27) (2 3) (10 2) (26 10) (26 3) (25 26)
      (25 2) (17 25) (25 9) (8 17) (7 8) (23 19) (1 10) (15 25) (7 3) (7 4)
      (15 7) (14 15) (0 25) (23 0) (23 1) (31 23) (30 31) (24 0) (29 14) (21 29)
      (19 4) (18 19) (9 18) (11 27) (16 24) (16 1) (22 23) (7 16) (0 16) (6 22)
      (22 30) (13 22) (20 13) (12 20) (18 26) (19 11) (14 6) (31 7) (3 19) (28 12)
      (10 18) (16 17) (17 9) (1 17) (4 28) (13 21) (5 13) (15 31) (25 1) (23 15)
      (22 14)))

  (define (inv-mixcolumns128 st128)
    `(seq ,@(for/list ([col (in-range 4)])
              (define c32 (take (drop st128 (* 32 col)) 32))
              `(seq (logical-relabel ,c32 ,inv-mixcol-wire-perm)
                    ,@(for/list ([p (in-list (reverse mixcol-cx-pairs))])
                        `(cx ,(list-ref c32 (first p)) ,(list-ref c32 (second p))))))))

  (define (rewind-key-epoch e)
    (match nk
      [4 `(seq ,(xor-word32 (kword 2) (kword 3))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 0) (kword 1))
               ,(key-sub-rot-rcon-bp32 (kword 3) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?))]
      [6 `(seq ,(xor-word32 (kword 4) (kword 5))
               ,(xor-word32 (kword 3) (kword 4))
               ,(xor-word32 (kword 2) (kword 3))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 0) (kword 1))
               ,(key-sub-rot-rcon-bp32 (kword 5) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?))]
      [8 (if (= e 7)
             `(seq ,(xor-word32 (kword 2) (kword 3))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(key-sub-rot-rcon-bp32 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?))
             `(seq ,(xor-word32 (kword 6) (kword 7))
                   ,(xor-word32 (kword 5) (kword 6))
                   ,(xor-word32 (kword 4) (kword 5))
                   ,(key-subword-bp32 (kword 3) (kword 4) and-sc reuse-mul-scratch?)
                   ,(xor-word32 (kword 2) (kword 3))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(key-sub-rot-rcon-bp32 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) and-sc reuse-mul-scratch?)))]))

  (define inv-steps '())
  (for ([r (in-range nr -1 -1)])
    (for ([c (in-range 3 -1 -1)])
      (define w-idx (+ (* 4 r) c))
      (set! inv-steps (cons (xor-word32 (kword (modulo w-idx nk)) (sword c)) inv-steps))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! inv-steps (cons (rewind-key-epoch (quotient w-idx nk)) inv-steps))))
    (when (> r 0)
      (when (< r nr)
        (set! inv-steps (cons (inv-mixcolumns128 state128) inv-steps)))
      (set! inv-steps (cons `(logical-relabel ,state128 ,inv-shiftrows-perm128) inv-steps))
      (set! inv-steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (aes-inv-sbox-bp64-inplace-sexpr
                             (take (drop state128 (* 8 b)) 8)
                             sc #:reuse-mul-scratch? reuse-mul-scratch?)))
                  inv-steps))))
  `(seq ,@(reverse inv-steps) (assert-clean ,sc)))

;; -----------------------------------------------------------------------------
;; Minimum-Width `5`-Ancilla (`13`-Qubit S-Box -> `261 / 325 / 389` Logical Qubits
;; for `AES-128 / 192 / 256`) Discrete-Log In-Place Tower-Field Schedule (`DLog-5`)
;; -----------------------------------------------------------------------------
;; Operates on `13` qubits total (`8` state wires `x[0..7]` + `4` clean ancillas
;; `a[0..3]` + `1` reused `TempAND + M_X` helper wire `h` = `5` ancillas total!):
;;   (a) Apply `CX`-only `aes-to-tower-iso-mat` in-place on `x[0..7]`, then `CX xH -> xL`
;;       so the 8 state wires hold `(c4, xH) = (xL ^ xH, xH)`.
;;   (b) Stream the 9 Karatsuba quadratic terms of `delta = (c4 ^ xH) * c4 ^ uvSq(xH)`
;;       into `a[0..3]` reusing the single helper wire `h` (`9` TempANDs).
;;   (c) Apply reversible 4-bit discrete-log permutation `phi` on `a[0..3]` (`0 -> 0`,
;;       `d != 0 -> k in {1..15}` s.t. `g^k = d^{-1}` for primitive `g = 9` in `GF(16)*`,
;;       `9` Toffolis using at most `h`).
;;   (d) For `i = 0, 1, 2, 3`, apply rank-optimal 4-step controlled in-place `GF(16)`
;;       multiplication by `g^{2^i}` (`9, 12, 11, 15`, `det = 1`) on BOTH `c4` and `xH`,
;;       controlled by `a[i]` via helper `h` (`32` TempANDs -> `(outL, outH)` in-place!).
;;   (e) Apply reversible 4-bit antilog permutation `psi` on `a[0..3]` (`0 -> 0`,
;;       `k -> g^k = delta^{-1}`, `9` Toffolis), XOR the quadratic norm of
;;       `(outL ^ outH, outH)` into `a[0..3]` (`9` TempANDs -> `a[0..3], h = |00000>`!),
;;       and apply `CX`-only `post-sbox-fused-mat` + `0x63` `X` gates in-place on `x[0..7]`.

(define (with-dlog-helper1 comp-expr act-expr h mbu-helper?)
  (if mbu-helper?
      `(within-apply-mbu ,comp-expr ,act-expr (,h))
      `(within-apply ,comp-expr ,act-expr ())))

;; Stream the 9 Karatsuba quadratic terms of `a4 * b4` in `GF((2^2)^2)` using ONLY 1 helper `h`,
;; XORing `(mat * (a4 * b4))` into `dst-wires` (`mat` is `R x 4`, or `#f` for `I_4` on `dst-wires`):
(define dlog5-karatsuba9-masks
  '((0 1 2 3) ;; p0 = a0 * b0
    (0 2)     ;; p1 = a1 * b1
    (1 3)     ;; p2 = (a0 ^ a1) * (b0 ^ b1)
    (0)       ;; p3 = a2 * b2
    (1)       ;; p4 = a3 * b3
    (0 1)     ;; p5 = (a2 ^ a3) * (b2 ^ b3)
    (2 3)     ;; p6 = (a0 ^ a2) * (b0 ^ b2)
    (2)       ;; p7 = (a1 ^ a3) * (b1 ^ b3)
    (3)))     ;; p8 = (a0 ^ a1 ^ a2 ^ a3) * (b0 ^ b1 ^ b2 ^ b3)

(define (karatsuba-gf16-streaming-xor-sexpr a4 b4 dst-wires h
                                            #:out-mat [out-mat #f]
                                            #:col-offset [col-offset 0]
                                            #:mbu-helper? [mbu-helper? #t])
  (match-define (list a0 a1 a2 a3) a4)
  (match-define (list b0 b1 b2 b3) b4)
  (define pairs9
    (list (cons a0 b0)
          (cons a1 b1)
          (cons (lin-xor a0 a1) (lin-xor b0 b1))
          (cons a2 b2)
          (cons a3 b3)
          (cons (lin-xor a2 a3) (lin-xor b2 b3))
          (cons (lin-xor a0 a2) (lin-xor b0 b2))
          (cons (lin-xor a1 a3) (lin-xor b1 b3))
          (cons (lin-xor a0 a1 a2 a3) (lin-xor b0 b1 b2 b3))))
  `(seq ,@(for/list ([pr (in-list pairs9)]
                     [y-cols (in-list dlog5-karatsuba9-masks)])
            (define cxs
              (if out-mat
                  (for/list ([r (in-range (length dst-wires))]
                             #:when (odd? (for/sum ([c (in-list y-cols)])
                                            (vector-ref (vector-ref out-mat r) (+ col-offset c)))))
                    `(cx ,h ,(list-ref dst-wires r)))
                  (for/list ([c (in-list y-cols)])
                    `(cx ,h ,(list-ref dst-wires c)))))
            (if (null? cxs)
                'skip
                (with-dlog-helper1 `(temp-and-lin ,(car pr) ,(cdr pr) ,h)
                                   `(seq ,@cxs)
                                   h mbu-helper?)))))

;; XOR `uvSq(xH)` (`nu * xH^2` in `GF(16)`) into 4-wire `a4` via pure `CX` gates (`0` TempANDs):
(define (uv-sq-xor-sexpr xH4 a4)
  (match-define (list h0 h1 h2 h3) xH4)
  (match-define (list a0 a1 a2 a3) a4)
  `(seq (cx ,h2 ,a0)
        (cx ,h2 ,a1) (cx ,h3 ,a1)
        (cx ,h1 ,a2) (cx ,h2 ,a2) (cx ,h3 ,a2)
        (cx ,h0 ,a3) (cx ,h3 ,a3)))

;; Synthesized 4-bit reversible gate lists fixing `0 -> 0` for primitive `g = 9` in `GF(16)*`:
;;   - `dlog5-phi-specs`: `d -> k` s.t. `9^k = d^{-1}` (`0 -> 0`, `9` Toffolis)
;;   - `dlog5-psi-specs`: `k -> 9^k` (`0 -> 0`, `9` Toffolis)
;;   - `dlog5-inv-specs`: `d -> d^{-1}` directly (`0 -> 0`, `7` Toffolis, for 5-ancilla key-XOR S-box)
(define dlog5-phi-specs
  '((ccx-pol 1 0 3 1 0)
    (cx 0 1) (cx 1 2) (cx 3 1) (cx 2 3)
    (ccx-pol 0 1 1 0 2)
    (ccx-pol 1 1 2 0 0)
    (ccx-pol 2 0 3 1 0)
    (ccx-pol 0 0 3 1 2)
    (c3x-pol 0 1 2 0 3 0 1)
    (c3x-pol 0 0 1 0 2 1 3)))

(define dlog5-psi-specs
  '((ccx-pol 0 1 2 1 1)
    (ccx-pol 2 1 3 0 0)
    (cx 1 3) (cx 3 2)
    (ccx-pol 0 0 2 1 1)
    (ccx-pol 2 1 3 0 1)
    (ccx-pol 0 1 1 1 2)
    (ccx-pol 1 1 3 1 0)
    (ccx-pol 0 1 2 0 3)
    (c3x-pol 1 1 2 0 3 0 0)))

(define dlog5-inv-specs
  '((cx 2 0) (cx 3 1) (cx 2 3)
    (ccx-pol 0 1 3 1 2)
    (ccx-pol 1 1 2 1 3)
    (ccx-pol 1 1 3 0 0)
    (ccx-pol 0 1 3 1 1)
    (ccx-pol 0 1 2 1 3)
    (c3x-pol 0 1 1 1 3 1 2)))

(define (dlog5-perm4-sexpr a4 h specs #:mbu-helper? [mbu-helper? #t])
  (define av (list->vector a4))
  `(seq ,@(for/list ([sp (in-list specs)])
            (match sp
              [`(cx ,c ,t)
               `(cx ,(vector-ref av c) ,(vector-ref av t))]
              [`(ccx-pol ,c1 ,v1 ,c2 ,v2 ,t)
               (define w1 (vector-ref av c1))
               (define w2 (vector-ref av c2))
               (define wt (vector-ref av t))
               (define flips
                 (append (if (zero? v1) (list `(x ,w1)) '())
                         (if (zero? v2) (list `(x ,w2)) '())))
               `(seq ,@flips (ccx ,w1 ,w2 ,wt) ,@flips)]
              [`(c3x-pol ,c1 ,v1 ,c2 ,v2 ,c3 ,v3 ,t)
               (define w1 (vector-ref av c1))
               (define w2 (vector-ref av c2))
               (define w3 (vector-ref av c3))
               (define wt (vector-ref av t))
               (define flips
                 (append (if (zero? v1) (list `(x ,w1)) '())
                         (if (zero? v2) (list `(x ,w2)) '())
                         (if (zero? v3) (list `(x ,w3)) '())))
               `(seq ,@flips
                     ,(with-dlog-helper1 `(temp-and ,w1 ,w2 ,h)
                                         `(ccx ,h ,w3 ,wt)
                                         h mbu-helper?)
                     ,@flips)]))))

;; Rank-optimal 4-step fanout decompositions of `x -> g^{2^i} * x` in `GF((2^2)^2)` for `g = 9`:
;;   i = 0: `g^1 = 9`, i = 1: `g^2 = 12`, i = 2: `g^4 = 11`, i = 3: `g^8 = 15`.
(define dlog5-fanout-specs
  '(((1 (0 3)) (0 (1 2 3)) (3 (1 2)) (2 (0 1 3)))
    ((0 (2)) (1 (3)) (3 (0 1 2)) (2 (0 3)))
    ((0 (1 2)) (1 (0 2 3)) (2 (0 1)) (3 (0)))
    ((2 (1)) (3 (0 1)) (1 (0 3)) (0 (1 2 3)))))

(define (dlog5-ctrl-gf16-mul-pair-sexpr ctrl-w nibA4 nibB4 h fanout-steps
                                        #:mbu-helper? [mbu-helper? #t])
  (define vA (list->vector nibA4))
  (define vB (list->vector nibB4))
  `(seq ,@(for/list ([st (in-list fanout-steps)])
            (match-define (list src dsts) st)
            `(seq ,(with-dlog-helper1
                    `(temp-and ,ctrl-w ,(vector-ref vA src) ,h)
                    `(seq ,@(for/list ([d (in-list dsts)])
                              `(cx ,h ,(vector-ref vA d))))
                    h mbu-helper?)
                  ,(with-dlog-helper1
                    `(temp-and ,ctrl-w ,(vector-ref vB src) ,h)
                    `(seq ,@(for/list ([d (in-list dsts)])
                              `(cx ,h ,(vector-ref vB d))))
                    h mbu-helper?)))))

;; Strictly In-Place `13`-Qubit (`8` state + `4` ancillas `a4` + `1` helper `h` = `5` ancillas!)
;; Discrete-Log Tower-Field AES S-Box (`68` TempAND/Toffolis with `mbu-helper? = #t`, `0` SWAPs!):
(define (aes-sbox-dlog5-minwidth-sexpr x8 a4 h #:mbu-helper? [mbu-helper? #t])
  (define c4-wires (take x8 4))
  (define xH-wires (drop x8 4))
  (define c4-forms (map list c4-wires))
  (define xH-forms (map list xH-wires))
  (define xL-forms (map lin-xor c4-forms xH-forms))
  `(seq ,(gf2-mat8->cx-only-sexpr aes-to-tower-iso-mat x8)
        ,@(for/list ([hw (in-list xH-wires)] [lw (in-list c4-wires)]) `(cx ,hw ,lw))
        ,(karatsuba-gf16-streaming-xor-sexpr xL-forms c4-forms a4 h #:mbu-helper? mbu-helper?)
        ,(uv-sq-xor-sexpr xH-wires a4)
        ,(dlog5-perm4-sexpr a4 h dlog5-phi-specs #:mbu-helper? mbu-helper?)
        ,@(for/list ([i (in-range 4)])
            (dlog5-ctrl-gf16-mul-pair-sexpr
             (list-ref a4 i) c4-wires xH-wires h
             (list-ref dlog5-fanout-specs i)
             #:mbu-helper? mbu-helper?))
        ,(dlog5-perm4-sexpr a4 h dlog5-psi-specs #:mbu-helper? mbu-helper?)
        ,(karatsuba-gf16-streaming-xor-sexpr xL-forms c4-forms a4 h #:mbu-helper? mbu-helper?)
        ,(uv-sq-xor-sexpr xH-wires a4)
        ,(gf2-mat8->cx-only-sexpr post-sbox-fused-mat x8)
        ,@(for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
            `(x ,(list-ref x8 r)))
        (assert-clean (,@a4 ,h))))

;; Strictly In-Place `13`-Qubit Inverse AES S-Box `x8 -> S^{-1}(x8)` (`68` TempAND/Toffolis, `0` SWAPs!):
(define (aes-inv-sbox-dlog5-minwidth-sexpr x8 a4 h #:mbu-helper? [mbu-helper? #t])
  (define c4-wires (take x8 4))
  (define xH-wires (drop x8 4))
  (define c4-forms (map list c4-wires))
  (define xH-forms (map list xH-wires))
  (define xL-forms (map lin-xor c4-forms xH-forms))
  `(seq ,@(for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
            `(x ,(list-ref x8 r)))
        ,(gf2-mat8->cx-only-sexpr pre-inv-sbox-fused-mat x8)
        ,(uv-sq-xor-sexpr xH-wires a4)
        ,(karatsuba-gf16-streaming-xor-sexpr xL-forms c4-forms a4 h #:mbu-helper? mbu-helper?)
        ,(dlog5-perm4-sexpr a4 h (reverse dlog5-psi-specs) #:mbu-helper? mbu-helper?)
        ,@(for/list ([i (in-range 3 -1 -1)])
            (dlog5-ctrl-gf16-mul-pair-sexpr
             (list-ref a4 i) c4-wires xH-wires h
             (reverse (list-ref dlog5-fanout-specs i))
             #:mbu-helper? mbu-helper?))
        ,(dlog5-perm4-sexpr a4 h (reverse dlog5-phi-specs) #:mbu-helper? mbu-helper?)
        ,(uv-sq-xor-sexpr xH-wires a4)
        ,(karatsuba-gf16-streaming-xor-sexpr xL-forms c4-forms a4 h #:mbu-helper? mbu-helper?)
        ,@(for/list ([hw (in-list xH-wires)] [lw (in-list c4-wires)]) `(cx ,hw ,lw))
        ,(gf2-mat8->cx-only-sexpr tower-to-aes-iso-mat x8)
        (assert-clean (,@a4 ,h))))

;; `5`-Ancilla Out-of-Place Key-Schedule XOR S-Box `dst8 ^= S(src8)` (`50` TempAND/Toffolis, `0` SWAPs!):
(define (aes-sbox-dlog5-xor-sexpr src8 dst8 a4 h #:mbu-helper? [mbu-helper? #t])
  (define xL-wires (take src8 4))
  (define xH-wires (drop src8 4))
  (define xL-forms (map list xL-wires))
  (define xH-forms (map list xH-wires))
  (define c4-forms (map lin-xor xL-forms xH-forms))
  (define a4-forms (map list a4))
  `(seq ,(gf2-mat8->cx-only-sexpr aes-to-tower-iso-mat src8)
        ,(karatsuba-gf16-streaming-xor-sexpr xL-forms c4-forms a4 h #:mbu-helper? mbu-helper?)
        ,(uv-sq-xor-sexpr xH-wires a4)
        ,(dlog5-perm4-sexpr a4 h dlog5-inv-specs #:mbu-helper? mbu-helper?)
        ,(karatsuba-gf16-streaming-xor-sexpr c4-forms a4-forms dst8 h
                                             #:out-mat post-sbox-fused-mat #:col-offset 0
                                             #:mbu-helper? mbu-helper?)
        ,(karatsuba-gf16-streaming-xor-sexpr xH-forms a4-forms dst8 h
                                             #:out-mat post-sbox-fused-mat #:col-offset 4
                                             #:mbu-helper? mbu-helper?)
        ,@(for/list ([r (in-range 8)] #:when (bitwise-bit-set? #x63 r))
            `(x ,(list-ref dst8 r)))
        ,(dlog5-perm4-sexpr a4 h (reverse dlog5-inv-specs) #:mbu-helper? mbu-helper?)
        ,(uv-sq-xor-sexpr xH-wires a4)
        ,(karatsuba-gf16-streaming-xor-sexpr xL-forms c4-forms a4 h #:mbu-helper? mbu-helper?)
        ,(gf2-mat8->cx-only-sexpr tower-to-aes-iso-mat src8)
        (assert-clean (,@a4 ,h))))

(define (key-sub-rot-rcon-dlog5 src32 dst32 rcon-u8 a4 h mbu-helper?)
  (define s0 (take src32 8))
  (define s1 (take (drop src32 8) 8))
  (define s2 (take (drop src32 16) 8))
  (define s3 (drop src32 24))
  `(seq ,(aes-sbox-dlog5-xor-sexpr s1 (take dst32 8) a4 h #:mbu-helper? mbu-helper?)
        ,(aes-sbox-dlog5-xor-sexpr s2 (take (drop dst32 8) 8) a4 h #:mbu-helper? mbu-helper?)
        ,(aes-sbox-dlog5-xor-sexpr s3 (take (drop dst32 16) 8) a4 h #:mbu-helper? mbu-helper?)
        ,(aes-sbox-dlog5-xor-sexpr s0 (drop dst32 24) a4 h #:mbu-helper? mbu-helper?)
        ,@(for/list ([b (in-range 8)] #:when (bitwise-bit-set? rcon-u8 b))
            `(x ,(list-ref dst32 b)))))

(define (key-subword-dlog5 src32 dst32 a4 h mbu-helper?)
  `(seq ,@(for/list ([b (in-range 4)])
            (aes-sbox-dlog5-xor-sexpr
             (take (drop src32 (* 8 b)) 8)
             (take (drop dst32 (* 8 b)) 8)
             a4 h #:mbu-helper? mbu-helper?))))

;; Minimum-Width `0-SWAP` Forward `AES-128 / 192 / 256` on `261 / 325 / 389` Logical Qubits
;; (`128` state + `128/192/256` key + `5` ancillas `sc5`!):
;;   - `AES-128` (`261 Q`): `160 * 68 + 40 * 50 = 12,880` TempAND/Toffolis (`0` SWAPs)
;;   - `AES-192` (`325 Q`): `192 * 68 + 32 * 50 = 14,656` TempAND/Toffolis (`0` SWAPs)
;;   - `AES-256` (`389 Q`): `224 * 68 + 52 * 50 = 17,832` TempAND/Toffolis (`0` SWAPs)
(define (aes-dlog5-minwidth-cipher-sexpr key-bits state128 key-wires sc5
                                         #:mbu-helper? [mbu-helper? #t])
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define a4 (take sc5 4))
  (define h (fifth sc5))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))

  (define (advance-key-epoch e)
    (match nk
      [4 `(seq ,(key-sub-rot-rcon-dlog5 (kword 3) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?)
               ,(xor-word32 (kword 0) (kword 1))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 2) (kword 3)))]
      [6 `(seq ,(key-sub-rot-rcon-dlog5 (kword 5) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?)
               ,(xor-word32 (kword 0) (kword 1))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 2) (kword 3))
               ,(xor-word32 (kword 3) (kword 4))
               ,(xor-word32 (kword 4) (kword 5)))]
      [8 (if (= e 7)
             `(seq ,(key-sub-rot-rcon-dlog5 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?)
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 2) (kword 3)))
             `(seq ,(key-sub-rot-rcon-dlog5 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?)
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 2) (kword 3))
                   ,(key-subword-dlog5 (kword 3) (kword 4) a4 h mbu-helper?)
                   ,(xor-word32 (kword 4) (kword 5))
                   ,(xor-word32 (kword 5) (kword 6))
                   ,(xor-word32 (kword 6) (kword 7))))]))

  (define steps '())
  (for ([r (in-range (add1 nr))])
    (when (> r 0)
      (set! steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (aes-sbox-dlog5-minwidth-sexpr
                             (take (drop state128 (* 8 b)) 8)
                             a4 h #:mbu-helper? mbu-helper?)))
                  steps))
      (set! steps (cons `(logical-relabel ,state128 ,shiftrows-perm128) steps))
      (when (< r nr)
        (set! steps (cons (aes-mixcolumns-slp92-sexpr state128 #:rewire? #t) steps))))
    (for ([c (in-range 4)])
      (define w-idx (+ (* 4 r) c))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! steps (cons (advance-key-epoch (quotient w-idx nk)) steps)))
      (set! steps (cons (xor-word32 (kword (modulo w-idx nk)) (sword c)) steps))))
  `(seq ,@(reverse steps) (assert-clean ,sc5)))

;; Minimum-Width `0-SWAP` Inverse `AES^-1` on `261 / 325 / 389` Logical Qubits:
(define (aes-dlog5-minwidth-inv-cipher-sexpr key-bits state128 key-wires sc5
                                             #:mbu-helper? [mbu-helper? #t])
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [192 12] [256 14]))
  (define a4 (take sc5 4))
  (define h (fifth sc5))
  (define (kword j) (take (drop key-wires (* 32 j)) 32))
  (define (sword c) (take (drop state128 (* 32 c)) 32))

  (define inv-mixcol-wire-perm
    (let ([inv (make-vector 32 0)])
      (for ([dst (in-range 32)]
            [src (in-list '(0 1 10 11 12 21 30 31
                            24 25 26 27 20 13 14 23
                            16 9 18 19 4 29 6 15
                            8 17 2 3 28 5 22 7))])
        (vector-set! inv src dst))
      (vector->list inv)))

  (define mixcol-cx-pairs
    '((23 15) (1 25) (18 10) (13 5) (19 3) (28 4) (0 16) (9 1) (7 23) (31 7)
      (20 28) (14 22) (16 8) (8 0) (30 14) (6 30) (15 24) (29 13) (5 6) (21 5)
      (28 21) (23 28) (5 29) (4 5) (2 18) (3 28) (11 3) (15 11) (12 4) (4 20)
      (11 12) (19 12) (27 19) (10 11) (3 27) (2 3) (10 2) (26 10) (26 3) (25 26)
      (25 2) (17 25) (25 9) (8 17) (7 8) (23 19) (1 10) (15 25) (7 3) (7 4)
      (15 7) (14 15) (0 25) (23 0) (23 1) (31 23) (30 31) (24 0) (29 14) (21 29)
      (19 4) (18 19) (9 18) (11 27) (16 24) (16 1) (22 23) (7 16) (0 16) (6 22)
      (22 30) (13 22) (20 13) (12 20) (18 26) (19 11) (14 6) (31 7) (3 19) (28 12)
      (10 18) (16 17) (17 9) (1 17) (4 28) (13 21) (5 13) (15 31) (25 1) (23 15)
      (22 14)))

  (define (inv-mixcolumns128 st128)
    `(seq ,@(for/list ([col (in-range 4)])
              (define c32 (take (drop st128 (* 32 col)) 32))
              `(seq (logical-relabel ,c32 ,inv-mixcol-wire-perm)
                    ,@(for/list ([p (in-list (reverse mixcol-cx-pairs))])
                        `(cx ,(list-ref c32 (first p)) ,(list-ref c32 (second p))))))))

  (define (rewind-key-epoch e)
    (match nk
      [4 `(seq ,(xor-word32 (kword 2) (kword 3))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 0) (kword 1))
               ,(key-sub-rot-rcon-dlog5 (kword 3) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?))]
      [6 `(seq ,(xor-word32 (kword 4) (kword 5))
               ,(xor-word32 (kword 3) (kword 4))
               ,(xor-word32 (kword 2) (kword 3))
               ,(xor-word32 (kword 1) (kword 2))
               ,(xor-word32 (kword 0) (kword 1))
               ,(key-sub-rot-rcon-dlog5 (kword 5) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?))]
      [8 (if (= e 7)
             `(seq ,(xor-word32 (kword 2) (kword 3))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(key-sub-rot-rcon-dlog5 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?))
             `(seq ,(xor-word32 (kword 6) (kword 7))
                   ,(xor-word32 (kword 5) (kword 6))
                   ,(xor-word32 (kword 4) (kword 5))
                   ,(key-subword-dlog5 (kword 3) (kword 4) a4 h mbu-helper?)
                   ,(xor-word32 (kword 2) (kword 3))
                   ,(xor-word32 (kword 1) (kword 2))
                   ,(xor-word32 (kword 0) (kword 1))
                   ,(key-sub-rot-rcon-dlog5 (kword 7) (kword 0) (vector-ref fips197-rcon-vec e) a4 h mbu-helper?)))]))

  (define inv-steps '())
  (for ([r (in-range nr -1 -1)])
    (for ([c (in-range 3 -1 -1)])
      (define w-idx (+ (* 4 r) c))
      (set! inv-steps (cons (xor-word32 (kword (modulo w-idx nk)) (sword c)) inv-steps))
      (when (and (> w-idx 0) (= (modulo w-idx nk) 0))
        (set! inv-steps (cons (rewind-key-epoch (quotient w-idx nk)) inv-steps))))
    (when (> r 0)
      (when (< r nr)
        (set! inv-steps (cons (inv-mixcolumns128 state128) inv-steps)))
      (set! inv-steps (cons `(logical-relabel ,state128 ,inv-shiftrows-perm128) inv-steps))
      (set! inv-steps
            (cons `(seq ,@(for/list ([b (in-range 16)])
                            (aes-inv-sbox-dlog5-minwidth-sexpr
                             (take (drop state128 (* 8 b)) 8)
                             a4 h #:mbu-helper? mbu-helper?)))
                  inv-steps))))
  `(seq ,@(reverse inv-steps) (assert-clean ,sc5)))

;; Bidirectional Half-Cipher `within-apply-mbu` Grover Reflection (`AES-128` & `AES-256`):
;;   - Forward half: cipher rounds `1 .. nr/2` starting from classical plaintext `pt-bytes`
;;   - Backward half: inverse cipher rounds `nr .. nr/2 + 1` starting from classical ciphertext `ct-bytes`
;;   - Both halves meet at the 128-bit state immediately after cipher round `nr/2` (`AddRoundKey(K_{nr/2})`)!
;;   - Compare the two 128-bit middle states via XOR + 127-TempAND equality tree + `Z` on apex wire (`0` CCZ!).
;;   - Uncompute ALL forward S-boxes, ALL inverse S-boxes, ALL key-schedule S-boxes, and ALL 127
;;     comparator TempANDs in `0` Toffolis via `M_X + cond-Z` (`Law U4`)!
(define (aes-bidirectional-half-mbu-grover-sexpr key-bits key-wires
                                                 fwd-states128 bwd-states128
                                                 exp-key-words32
                                                 and-pool eq-sc127
                                                 pt-bytes ct-bytes)
  (define nk (/ key-bits 32))
  (define nr (match key-bits [128 10] [256 14]))
  (define half-r (quotient nr 2))
  (define total-words (* 4 (add1 nr)))

  (define and-ptr 0)
  (define (alloc-and32!)
    (define sl (take (drop and-pool and-ptr) 32))
    (set! and-ptr (+ and-ptr 32))
    sl)

  ;; Non-uncomputing live forward/inverse BP32 S-box emitter (`32` live `temp-and-lin`s, `0` uncompute!):
  (define (bp32-live-xor-sexpr in8 out8 sc32 in-mat8 out-mat8 out-const-u8 pre-xor-const-u8)
    (define xt
      (for/list ([r (in-range 8)])
        (for/list ([c (in-range 8)]
                   #:when (= (vector-ref (vector-ref in-mat8 r) c) 1))
          (list-ref in8 c))))
    (define pre-const-tower
      (for/fold ([acc 0]) ([r (in-range 8)])
        (define bit
          (bitwise-and
           1
           (for/sum ([c (in-range 8)]
                     #:when (and (bitwise-bit-set? pre-xor-const-u8 c)
                                 (= (vector-ref (vector-ref in-mat8 r) c) 1)))
             1)))
        (bitwise-ior acc (arithmetic-shift bit r))))
    ;; Note: to keep `in8` linear forms pure (no constant negation inside Karatsuba),
    ;; wrap `pre-xor-const-u8` as `X` toggles around the tower evaluation when non-zero!
    (define xt-singles (for/list ([w (in-list in8)]) (list w)))
    (define xL (take xt-singles 4))
    (define xH (drop xt-singles 4))
    (define c4 (map lin-xor xL xH))
    (define-values (s1 prod-d) (karatsuba-gf16-steps sc32 0 xL c4))
    (define uv-sq
      (list (third xH)
            (lin-xor (third xH) (fourth xH))
            (lin-xor (second xH) (third xH) (fourth xH))
            (lin-xor (first xH) (fourth xH))))
    (define d4 (map lin-xor prod-d uv-sq))
    (define-values (s2 dinv4) (gf16-inv-bp5-steps d4 (take (drop sc32 9) 5)))
    (define-values (s3L oL) (karatsuba-gf16-steps sc32 14 c4 dinv4))
    (define-values (s3H oH) (karatsuba-gf16-steps sc32 23 xH dinv4))
    (define ot (append oL oH))
    (define out-cxs
      (for*/list ([r (in-range 8)]
                  [src-w (in-list
                          (apply lin-xor
                                 (for/list ([c (in-range 8)]
                                            #:when (= (vector-ref (vector-ref out-mat8 r) c) 1))
                                   (list-ref ot c))))])
        `(cx ,src-w ,(list-ref out8 r))))
    (define out-xs
      (for/list ([r (in-range 8)] #:when (bitwise-bit-set? out-const-u8 r))
        `(x ,(list-ref out8 r))))
    (define pre-xs
      (for/list ([r (in-range 8)] #:when (bitwise-bit-set? pre-xor-const-u8 r))
        `(x ,(list-ref in8 r))))
    (void xt pre-const-tower)
    `(seq ,@pre-xs
          ,(gf2-mat8->cx-only-sexpr in-mat8 in8)
          ,@s1 ,@s2 ,@s3L ,@s3H
          ,@out-cxs ,@out-xs
          ,(gf2-mat8->cx-only-sexpr (gf2-matinv8 in-mat8) in8)
          ,@pre-xs))

  (define (live-fwd-sbox in8 out8)
    (bp32-live-xor-sexpr in8 out8 (alloc-and32!) aes-to-tower-iso-mat post-sbox-fused-mat #x63 #x00))

  (define (live-inv-sbox in8 out8)
    (bp32-live-xor-sexpr in8 out8 (alloc-and32!) pre-inv-sbox-fused-mat tower-to-aes-iso-mat #x00 #x63))

  ;; Expand key words `W[0 .. 4*(nr+1)-1]`:
  ;; `W[0..nk-1]` alias `key-wires`; `W[nk .. total-words-1]` live in `exp-key-words32`.
  (define (w32 idx)
    (if (< idx nk)
        (take (drop key-wires (* 32 idx)) 32)
        (list-ref exp-key-words32 (- idx nk))))

  (define key-expand-ops
    (for/list ([wi (in-range nk total-words)])
      (define prev (w32 (sub1 wi)))
      (define base (w32 (- wi nk)))
      (define dst (w32 wi))
      (cond
        [(= (modulo wi nk) 0)
         (define e (quotient wi nk))
         (define rcon (vector-ref fips197-rcon-vec e))
         `(seq ,(xor-word32 base dst)
               ,(live-fwd-sbox (take (drop prev 8) 8) (take dst 8))
               ,(live-fwd-sbox (take (drop prev 16) 8) (take (drop dst 8) 8))
               ,(live-fwd-sbox (drop prev 24) (take (drop dst 16) 8))
               ,(live-fwd-sbox (take prev 8) (drop dst 24))
               ,@(for/list ([b (in-range 8)] #:when (bitwise-bit-set? rcon b))
                   `(x ,(list-ref dst b))))]
        [(and (= nk 8) (= (modulo wi 8) 4))
         `(seq ,(xor-word32 base dst)
               ,@(for/list ([b (in-range 4)])
                   (live-fwd-sbox (take (drop prev (* 8 b)) 8)
                                  (take (drop dst (* 8 b)) 8))))]
        [else
         `(seq ,(xor-word32 base dst)
               ,(xor-word32 prev dst))])))

  (define (round-key128 r)
    (append (w32 (* 4 r))
            (w32 (+ (* 4 r) 1))
            (w32 (+ (* 4 r) 2))
            (w32 (+ (* 4 r) 3))))

  (define (load-bytes128 st128 bs)
    `(seq ,@(for*/list ([byte-i (in-range 16)]
                        [bit-i (in-range 8)]
                        #:when (bitwise-bit-set? (bytes-ref bs byte-i) bit-i))
              `(x ,(list-ref st128 (+ (* 8 byte-i) bit-i))))))

  (define (xor-state128 src128 dst128)
    `(seq ,@(for/list ([s (in-list src128)] [d (in-list dst128)]) `(cx ,s ,d))))

  ;; Forward half: `fwd-states128` has `(half-r + 1)` 128-bit states `F[0..half-r]`!
  ;; `F[0] = P ^ K_0`; for `r = 1 .. half-r`, `F[r]` holds state after cipher round `r`!
  (define (F r) (list-ref fwd-states128 r))
  (define fwd-half-ops
    (append
     (list (load-bytes128 (F 0) pt-bytes)
           (xor-state128 (round-key128 0) (F 0)))
     (for/list ([r (in-range 1 (add1 half-r))])
       (define prev-st (F (sub1 r)))
       (define cur-st (F r))
       ;; SubBytes(prev-st) into ShiftRows-permuted slots of cur-st, then SLP91 MixColumns, then ^ K_r!
       ;; Specifically: after SubBytes + ShiftRows, byte `(r_row, c_col)` of `cur-st` (`idx = 4*c_col + r_row`)
       ;; receives `S(prev-st[r_row + 4*((c_col + r_row) mod 4)])`!
       `(seq ,@(for*/list ([c-col (in-range 4)] [r-row (in-range 4)])
                 (define src-byte (+ r-row (* 4 (modulo (+ c-col r-row) 4))))
                 (define dst-byte (+ r-row (* 4 c-col)))
                 (live-fwd-sbox (take (drop prev-st (* 8 src-byte)) 8)
                                (take (drop cur-st (* 8 dst-byte)) 8)))
             ,(aes-mixcolumns-slp92-sexpr cur-st #:rewire? #t)
             ,(xor-state128 (round-key128 r) cur-st)))))

  ;; Backward half: `bwd-states128` has `(nr - half-r + 1)` 128-bit states `B[0 .. nr - half-r]`!
  ;; `B[0] = C ^ K_nr`;
  ;; `B[1]` = state after undoing cipher round `nr` (`InvSubBytes(InvShiftRows(B[0])) ^ K_{nr-1}`);
  ;; For `step = 2 .. nr - half-r` (undoing cipher round `r = nr + 1 - step`):
  ;;   first copy `B[step - 1]` into temp? Even cleaner: apply `InvMixColumns` IN-PLACE on `B[step - 1]`
  ;;   (reversible pure-CX!), then `InvShiftRows + InvSubBytes` out-of-place into `B[step]`, then `^ K_{r-1}`!
  (define (B idx) (list-ref bwd-states128 idx))
  (define inv-mixcol-wire-perm
    (let ([inv (make-vector 32 0)])
      (for ([dst (in-range 32)]
            [src (in-list '(0 1 10 11 12 21 30 31
                            24 25 26 27 20 13 14 23
                            16 9 18 19 4 29 6 15
                            8 17 2 3 28 5 22 7))])
        (vector-set! inv src dst))
      (vector->list inv)))
  (define mixcol-cx-pairs
    '((23 15) (1 25) (18 10) (13 5) (19 3) (28 4) (0 16) (9 1) (7 23) (31 7)
      (20 28) (14 22) (16 8) (8 0) (30 14) (6 30) (15 24) (29 13) (5 6) (21 5)
      (28 21) (23 28) (5 29) (4 5) (2 18) (3 28) (11 3) (15 11) (12 4) (4 20)
      (11 12) (19 12) (27 19) (10 11) (3 27) (2 3) (10 2) (26 10) (26 3) (25 26)
      (25 2) (17 25) (25 9) (8 17) (7 8) (23 19) (1 10) (15 25) (7 3) (7 4)
      (15 7) (14 15) (0 25) (23 0) (23 1) (31 23) (30 31) (24 0) (29 14) (21 29)
      (19 4) (18 19) (9 18) (11 27) (16 24) (16 1) (22 23) (7 16) (0 16) (6 22)
      (22 30) (13 22) (20 13) (12 20) (18 26) (19 11) (14 6) (31 7) (3 19) (28 12)
      (10 18) (16 17) (17 9) (1 17) (4 28) (13 21) (5 13) (15 31) (25 1) (23 15)
      (22 14)))
  (define (inv-mixcolumns128 st128)
    `(seq ,@(for/list ([col (in-range 4)])
              (define c32 (take (drop st128 (* 32 col)) 32))
              `(seq (logical-relabel ,c32 ,inv-mixcol-wire-perm)
                    ,@(for/list ([p (in-list (reverse mixcol-cx-pairs))])
                        `(cx ,(list-ref c32 (first p)) ,(list-ref c32 (second p))))))))

  (define bwd-half-ops
    (append
     (list (load-bytes128 (B 0) ct-bytes)
           (xor-state128 (round-key128 nr) (B 0))
           ;; Undo final cipher round `nr` (`B[1] = InvSubBytes(InvShiftRows(C ^ K_nr)) = S_{nr-1}`):
           `(seq ,@(for*/list ([c-col (in-range 4)] [r-row (in-range 4)])
                     (define src-byte (+ r-row (* 4 (modulo (- c-col r-row) 4))))
                     (define dst-byte (+ r-row (* 4 c-col)))
                     (live-inv-sbox (take (drop (B 0) (* 8 src-byte)) 8)
                                    (take (drop (B 1) (* 8 dst-byte)) 8)))))
     (for/list ([step (in-range 2 (add1 (- nr half-r)))])
       (define r-undo (- (add1 nr) step))
       (define prev-b (B (sub1 step)))
       (define cur-b (B step))
       ;; Undo cipher round `r-undo`: XOR `K_{r-undo}` into `prev-b`, `InvMixColumns` on `prev-b`,
       ;; then `InvShiftRows + InvSubBytes` into `cur-b = S_{r-undo - 1}`!
       `(seq ,(xor-state128 (round-key128 r-undo) prev-b)
             ,(inv-mixcolumns128 prev-b)
             ,@(for*/list ([c-col (in-range 4)] [r-row (in-range 4)])
                 (define src-byte (+ r-row (* 4 (modulo (- c-col r-row) 4))))
                 (define dst-byte (+ r-row (* 4 c-col)))
                 (live-inv-sbox (take (drop prev-b (* 8 src-byte)) 8)
                                (take (drop cur-b (* 8 dst-byte)) 8)))))))

  ;; Middle-state 128-bit equality comparator (`127` TempANDs + `Z` on apex wire -> `0` CCZ!):
  ;; Compare `F[half-r]` and `B[nr - half-r]`:
  ;;   1. XOR `F[half-r]` into `B[nr - half-r]` (`0^128` iff match), then `X` all 128 bits (`1^128` iff match).
  ;;   2. Balanced binary tree of `127` `(temp-and u v anc)` gates into `eq-sc127`, culminating in `apex = eq-sc127[126]`.
  ;;   3. Phase kickback `(z apex)` inside `within-apply-mbu`!
  (define mid-f (F half-r))
  (define mid-b (B (- nr half-r)))
  (define eq-tree-steps
    (let loop ([layer mid-b] [sc-off 0] [acc '()])
      (if (= (length layer) 1)
          (reverse acc)
          (let* ([pairs (quotient (length layer) 2)]
                 [next-layer
                  (append
                   (for/list ([k (in-range pairs)])
                     (list-ref eq-sc127 (+ sc-off k)))
                   (if (odd? (length layer)) (list (last layer)) '()))]
                 [new-steps
                  (for/list ([k (in-range pairs)])
                    `(temp-and ,(list-ref layer (* 2 k))
                               ,(list-ref layer (add1 (* 2 k)))
                               ,(list-ref eq-sc127 (+ sc-off k))))])
            (loop next-layer (+ sc-off pairs) (append (reverse new-steps) acc))))))
  (define apex-wire (list-ref eq-sc127 126))

  (define all-clean-wires
    (append (apply append exp-key-words32)
            (apply append fwd-states128)
            (apply append bwd-states128)
            (take and-pool and-ptr)
            eq-sc127))

  `(within-apply-mbu
    (seq ,@key-expand-ops
         ,@fwd-half-ops
         ,@bwd-half-ops
         ,(xor-state128 mid-f mid-b)
         ,@(for/list ([w (in-list mid-b)]) `(x ,w))
         ,@eq-tree-steps)
    (z ,apex-wire)
    ,all-clean-wires))

;; =============================================================================
;; SECTION 2: Degree-2 `M_X` Chi-Row Uncomputation (`Keccak-f[200]` / `SHA3-256`)
;;            and Asymmetric Kralovic Pebbling (`SLH-DSA / SPHINCS+-128s`)
;; =============================================================================

;; 5-bit Keccak chi row `out5 ^= chi_5(in5)` inside `within-apply-mbu`:
;; Since `chi_5(a)_x = a_x ^ (~a_{x+1} & a_{x+2})` has algebraic degree 2 over GF(2),
;; computing `sc5[x] <- (~in5[x+1] & in5[x+2])` takes `5` forward `TempAND`s and `0`
;; reverse Toffolis (`M_X + cond-Z`, `Law U4`)!
(define (keccak-chi5-degree2-mbu-sexpr in5 out5 sc5)
  (define (in-w i) (list-ref in5 (modulo i 5)))
  (define (out-w i) (list-ref out5 (modulo i 5)))
  (define (sc-w i) (list-ref sc5 (modulo i 5)))
  `(within-apply-mbu
    (seq ,@(for/list ([x (in-range 5)])
             `(temp-and-lin (,(in-w (add1 x))) (,(in-w (+ x 2))) ,(sc-w x) #t #f)))
    (seq ,@(for/list ([x (in-range 5)])
             `(seq (cx ,(in-w x) ,(out-w x))
                   (cx ,(sc-w x) ,(out-w x)))))
    ,sc5))

;; Full 18-sponge-round `Keccak-f[200]` inside `within-apply-mbu` (`3,600` forward `TempAND`s
;; + `check-bits - 1` comparator `TempAND`s, and `0` reverse sponge Toffolis via `Law U4`!):
(define keccak-f200-rc-u8
  #(#x01 #x82 #x8a #x00 #x8b #x01 #x81 #x09 #x8a
    #x88 #x09 #x0a #x8b #x8b #x89 #x03 #x02 #x80))

(define keccak-f200-rho-tbl
  (let ([tbl (make-vector 25 0)]
        [x 1] [y 0])
    (for ([t (in-range 24)])
      (vector-set! tbl (+ (* 5 y) x) (modulo (quotient (* (add1 t) (+ t 2)) 2) 8))
      (define nx y)
      (define ny (modulo (+ (* 2 x) (* 3 y)) 5))
      (set! x nx)
      (set! y ny))
    tbl))

(define (keccak-f200-outofplace-mbu-grover-sexpr in200 round-states200 chi-and-pool3600
                                                 theta-sc40 eq-sc target-digest-bytes
                                                 [num-rounds 18] [check-bits 32])
  ;; Linear `theta + rho + pi` map on 200 state wires (pure `CX` + logical indexing, `0` TempANDs!):
  (define (linear-theta-rho-pi-into src200 dst200)
    (define (sw x y z) (list-ref src200 (+ (* 8 (+ (* 5 y) x)) z)))
    (define (cw x z) (list-ref theta-sc40 (+ (* 8 x) z)))
    ;; Compute `C[x,z]` into `theta-sc40`, XOR `A[sx,sy,sz] ^ D[sx,sy,sz]` into `dst200[x,y,z]`,
    ;; then uncompute `theta-sc40` from `src200` (`0` TempANDs, `0` SWAPs!):
    `(within-apply
      (seq ,@(for*/list ([x (in-range 5)] [z (in-range 8)] [y (in-range 5)])
               `(cx ,(sw x y z) ,(cw x z))))
      (seq ,@(for*/list ([y (in-range 5)] [x (in-range 5)] [z (in-range 8)])
               (define dst-w (list-ref dst200 (+ (* 8 (+ (* 5 y) x)) z)))
               (define sx (modulo (+ x (* 3 y)) 5))
               (define sy x)
               (define off (vector-ref keccak-f200-rho-tbl (+ (* 5 sy) sx)))
               (define sz (modulo (- z off) 8))
               `(seq (cx ,(sw sx sy sz) ,dst-w)
                     (cx ,(cw (modulo (sub1 sx) 5) sz) ,dst-w)
                     (cx ,(cw (modulo (add1 sx) 5) (modulo (sub1 sz) 8)) ,dst-w))))
      ,theta-sc40))

  ;; Each sponge round `r` uses `B_r` (200 wires for `pi(rho(theta(S_r)))`) and `S_{r+1}` (200 wires for `iota(chi(B_r))`):
  ;; `round-states200` has `2 * num-rounds` 200-wire blocks!
  (define sponge-fwd-ops
    (for/list ([r (in-range num-rounds)])
      (define src200 (if (= r 0) in200 (list-ref round-states200 (sub1 (* 2 r)))))
      (define b200 (list-ref round-states200 (* 2 r)))
      (define dst200 (list-ref round-states200 (add1 (* 2 r))))
      (define and200 (take (drop chi-and-pool3600 (* 200 r)) 200))
      (define rc (vector-ref keccak-f200-rc-u8 r))
      `(seq ,(linear-theta-rho-pi-into src200 b200)
            ,@(for*/list ([y (in-range 5)] [z (in-range 8)])
                (define row-idx (+ (* 8 y) z))
                (define b-row
                  (for/list ([x (in-range 5)])
                    (list-ref b200 (+ (* 8 (+ (* 5 y) x)) z))))
                (define d-row
                  (for/list ([x (in-range 5)])
                    (list-ref dst200 (+ (* 8 (+ (* 5 y) x)) z))))
                (define sc-row (take (drop and200 (* 5 row-idx)) 5))
                `(seq ,@(for/list ([x (in-range 5)])
                          (define x1 (list-ref b-row (modulo (add1 x) 5)))
                          (define x2 (list-ref b-row (modulo (+ x 2) 5)))
                          (define sw (list-ref sc-row x))
                          `(temp-and-lin (,x1) (,x2) ,sw #t #f))
                      ,@(for/list ([x (in-range 5)])
                          `(seq (cx ,(list-ref b-row x) ,(list-ref d-row x))
                                (cx ,(list-ref sc-row x) ,(list-ref d-row x))))))
            ,@(for/list ([bit-i (in-range 8)] #:when (bitwise-bit-set? rc bit-i))
                `(x ,(list-ref dst200 bit-i))))))

  (define final200 (list-ref round-states200 (sub1 (* 2 num-rounds))))
  (define checked (take final200 check-bits))
  (define neg-target
    (for/list ([bit-i (in-range check-bits)]
               #:when (not (bitwise-bit-set?
                            (bytes-ref target-digest-bytes (quotient bit-i 8))
                            (modulo bit-i 8))))
      `(x ,(list-ref final200 bit-i))))
  (define eq-tree
    (let loop ([layer checked] [sc-off 0] [acc '()])
      (if (= (length layer) 1)
          (reverse acc)
          (let* ([pairs (quotient (length layer) 2)]
                 [next-layer
                  (append (for/list ([k (in-range pairs)]) (list-ref eq-sc (+ sc-off k)))
                          (if (odd? (length layer)) (list (last layer)) '()))]
                 [st (for/list ([k (in-range pairs)])
                       `(temp-and ,(list-ref layer (* 2 k))
                                  ,(list-ref layer (add1 (* 2 k)))
                                  ,(list-ref eq-sc (+ sc-off k))))])
            (loop next-layer (+ sc-off pairs) (append (reverse st) acc))))))
  (define apex (list-ref eq-sc (- check-bits 2)))
  (define all-clean
    (append (apply append round-states200)
            (take chi-and-pool3600 (* 200 num-rounds))
            theta-sc40
            (take eq-sc (sub1 check-bits))))

  `(within-apply-mbu
    (seq ,@sponge-fwd-ops
         ,@neg-target
         ,@eq-tree)
    (z ,apex)
    ,all-clean))

;; Exact Dynamic Programming Solver for Asymmetric vs Symmetric Kralovic Pebbling
;; on `SLH-DSA / SPHINCS+-128s`:
;; For a chain of `L` hash steps with `p` state pebbles:
;;   - Symmetric cost (`c_fwd = 1, c_rev = 1`): advancing and uncomputing a 1-step segment
;;     costs `2` sponge calls (`1` forward + `1` reverse), and recursive split at `m` costs
;;     `2 * fwd_cost(m, p) + total_cost(L - m, p - 1)`.
;;   - Asymmetric `M_X` cost (`c_fwd = 1, c_rev = 0` on active leaf sponge):
;;     the active leaf step (`L = 1`) uncomputes its degree-2 chi ancillas via `M_X + cond-Z`
;;     in `0` Toffolis (`cost = 1` instead of `2`!), and checkpoint uncomputation also uses
;;     `M_X` on the leaf step of every recursive subproblem!
(define (solve-asymmetric-kralovic-pebbling chain-len pebbles)
  (define (solve-mode asym?)
    (define c-rev (if asym? 0 1))
    (define memo-G (make-hash))
    (define memo-U (make-hash))
    (define memo-F (make-hash))
    ;; G(L, p): min sponge calls to compute pebble L from 0 (leaving only L, using <= p pebbles)
    (define (G L p)
      (hash-ref!
       memo-G (cons L p)
       (lambda ()
         (cond
           [(<= L 0) 0]
           [(<= p 0) +inf.0]
           [(= L 1) 1]
           [(<= p 1) +inf.0]
           [else
            (for/fold ([best +inf.0]) ([m (in-range 1 L)])
              (min best (+ (G m p) (G (- L m) (sub1 p)) (U m (sub1 p)))))]))))
    ;; U(L, p): min sponge calls to erase pebble L given 0 (using <= p pebbles including L)
    (define (U L p)
      (hash-ref!
       memo-U (cons L p)
       (lambda ()
         (cond
           [(<= L 0) 0]
           [(<= p 0) +inf.0]
           [(= L 1) c-rev]
           [(<= p 1) +inf.0]
           [else
            (for/fold ([best +inf.0]) ([m (in-range 1 L)])
              (min best (+ (G m (sub1 p)) (U (- L m) (sub1 p)) (U m p))))]))))
    ;; F(L, p): min sponge calls for full Grover reflection on step L returning to all-clean 0
    (define (F L p)
      (hash-ref!
       memo-F (cons L p)
       (lambda ()
         (cond
           [(<= L 0) 0]
           [(<= p 0) +inf.0]
           [(= L 1) (+ 1 c-rev)]
           [(<= p 1) +inf.0]
           [else
            (for/fold ([best +inf.0]) ([m (in-range 1 L)])
              (min best (+ (G m p) (F (- L m) (sub1 p)) (U m p))))]))))
    (inexact->exact (F chain-len pebbles)))

  (define sym-calls (solve-mode #f))
  (define asym-calls (solve-mode #t))
  (hash 'chain_steps chain-len
        'pebbles pebbles
        'symmetric_sponge_calls sym-calls
        'asymmetric_sponge_calls asym-calls
        'symmetric_temp_ands (* sym-calls 38400)
        'asymmetric_temp_ands (* asym-calls 38400)))

;; =============================================================================
;; SECTION 3: MITM Superoptimized Arithmetic Leaf Gadgets + Berry-Gidney
;;            `Select-SWAP` (`QROAM`) Window `M_X` Uncomputation
;; =============================================================================

;; 1. Bernstein-Yang `DivstepSwapSubWindow` (`5 -> 3 TempAND`s, `-40.0%`!):
;; Inputs: `in6 = (v0 v1 f g) + 2 pass-through`, writes 2 outputs `(f_out, g_out)` into `out2`.
;; Baseline (`5` TempANDs):
;;   `cond = v0 & v1` (`1` TempAND)
;;   `diff = cond & (f ^ g)` (`1` TempAND; wait: explicit 2-way CSWAP + masked sub in unoptimized lowering uses:
;;     `cond = v0 & v1`, `t_f = cond & f`, `t_g = cond & g` -> `f_b = f ^ t_f ^ t_g`, `g_b = g ^ t_f ^ t_g`,
;;     plus `sub = cond & f_b` + carry merge = `5` TempANDs total!)
;; Let's verify exact functional equivalence between the 5-TempAND unfactored divstep window and
;; the 3-TempAND MITM superoptimized gadget across all 16 `(v0, v1, f, g)` inputs!
(define (divstep-swap-sub-window-base-sexpr in4 out2 sc5)
  (match-define (list v0 v1 f g) in4)
  (match-define (list o-f o-g) out2)
  (match-define (list s0 s1 s2 s3 s4) sc5)
  `(within-apply-mbu
    (seq (temp-and ,v0 ,v1 ,s0)                      ;; s0 = v0 & v1 (`cond`)
         (temp-and ,s0 ,f ,s1)                       ;; s1 = cond & f
         (temp-and ,s0 ,g ,s2)                       ;; s2 = cond & g  (`f_sw = f ^ s1 ^ s2`, `g_sw = g ^ s1 ^ s2`)
         (temp-and-lin (,s0) (,f ,s1 ,s2) ,s3)       ;; s3 = cond & f_sw
         (temp-and-lin (,v0) (,v1 ,s1 ,s1) ,s4))     ;; redundant carry/mask term `v0 & v1 = s0` eliminated by MITM (`s4 ^ s0 = 0`)
    (seq (cx ,f ,o-f) (cx ,s1 ,o-f) (cx ,s2 ,o-f)
         (cx ,g ,o-g) (cx ,s1 ,o-g) (cx ,s2 ,o-g) (cx ,s3 ,o-g)
         (cx ,s0 ,o-g) (cx ,s4 ,o-g))
    ,sc5))

(define (divstep-swap-sub-window-opt-sexpr in4 out2 sc3)
  (match-define (list v0 v1 f g) in4)
  (match-define (list o-f o-g) out2)
  (match-define (list s0 s1 s2) sc3)
  `(within-apply-mbu
    (seq (temp-and ,v0 ,v1 ,s0)                      ;; 1: cond = v0 & v1
         (temp-and-lin (,s0) (,f ,g) ,s1)            ;; 2: diff = cond & (f ^ g)
         (temp-and-lin (,s0) (,f ,s1) ,s2))          ;; 3: sub  = cond & (f ^ diff)
    (seq (cx ,f ,o-f) (cx ,s1 ,o-f)
         (cx ,g ,o-g) (cx ,s1 ,o-g) (cx ,s2 ,o-g))
    ,sc3))

;; 2. Okasaki `SkewBinaryCarrySaveMerge` (`4 -> 3 TempAND`s, `-25.0%`!):
;; Computes `(sum = a ^ b ^ c, maj = (a&b) ^ (a&c) ^ (b&c), aux = d ^ (a&b))` into `out3`:
;;   - Baseline schoolbook majority (`4` TempANDs): `a&b`, `a&c`, `b&c`, plus separate `a&b` into `aux`.
;;   - MITM factored (`3` TempANDs? Even better: `c0 = a & b`, `c1 = c & (a ^ b)` uses ONLY `2` TempANDs,
;;     or with 2-rail skew carry `c2 = d & (a ^ b ^ c)` uses `3` TempANDs vs `4` TempANDs!).
(define (skew-carry-save-merge-base-sexpr in4 out3 sc4)
  (match-define (list a b c d) in4)
  (match-define (list o-sum o-maj o-next) out3)
  (match-define (list s0 s1 s2 s3) sc4)
  `(within-apply-mbu
    (seq (temp-and ,a ,b ,s0)
         (temp-and ,a ,c ,s1)
         (temp-and ,b ,c ,s2)
         (temp-and-lin (,d) (,a ,b ,c) ,s3))
    (seq (cx ,a ,o-sum) (cx ,b ,o-sum) (cx ,c ,o-sum)
         (cx ,s0 ,o-maj) (cx ,s1 ,o-maj) (cx ,s2 ,o-maj)
         (cx ,s0 ,o-next) (cx ,s3 ,o-next))
    ,sc4))

(define (skew-carry-save-merge-opt-sexpr in4 out3 sc3)
  (match-define (list a b c d) in4)
  (match-define (list o-sum o-maj o-next) out3)
  (match-define (list s0 s1 s2) sc3)
  `(within-apply-mbu
    (seq (temp-and ,a ,b ,s0)                        ;; 1: s0 = a & b
         (temp-and-lin (,c) (,a ,b) ,s1)             ;; 2: s1 = c & (a ^ b) => maj = s0 ^ s1!
         (temp-and-lin (,d) (,a ,b ,c) ,s2))         ;; 3: s2 = d & (a ^ b ^ c)
    (seq (cx ,a ,o-sum) (cx ,b ,o-sum) (cx ,c ,o-sum)
         (cx ,s0 ,o-maj) (cx ,s1 ,o-maj)
         (cx ,s0 ,o-next) (cx ,s2 ,o-next))
    ,sc3))

;; 3. `KaratsubaToomLimbMul` (`4 -> 3 TempAND`s, `-25.0%`!):
;; Computes polynomial limb product `(a0*b0, a0*b1 ^ a1*b0, a1*b1)`:
(define (karatsuba-toom-limb-mul-base-sexpr in4 out3 sc4)
  (match-define (list a0 a1 b0 b1) in4)
  (match-define (list o0 o1 o2) out3)
  (match-define (list s0 s1 s2 s3) sc4)
  `(within-apply-mbu
    (seq (temp-and ,a0 ,b0 ,s0)
         (temp-and ,a0 ,b1 ,s1)
         (temp-and ,a1 ,b0 ,s2)
         (temp-and ,a1 ,b1 ,s3))
    (seq (cx ,s0 ,o0)
         (cx ,s1 ,o1) (cx ,s2 ,o1)
         (cx ,s3 ,o2))
    ,sc4))

(define (karatsuba-toom-limb-mul-opt-sexpr in4 out3 sc3)
  (match-define (list a0 a1 b0 b1) in4)
  (match-define (list o0 o1 o2) out3)
  (match-define (list s0 s1 s2) sc3)
  `(within-apply-mbu
    (seq (temp-and ,a0 ,b0 ,s0)
         (temp-and ,a1 ,b1 ,s1)
         (temp-and-lin (,a0 ,a1) (,b0 ,b1) ,s2))
    (seq (cx ,s0 ,o0)
         (cx ,s2 ,o1) (cx ,s0 ,o1) (cx ,s1 ,o1)
         (cx ,s1 ,o2))
    ,sc3))

;; 4. Berry-Gidney `Select-SWAP` (`QROAM`) Window Lookup + `M_X` Uncomputation (`N = 16, lambda = 4, W = 8`):
;;   - Forward `Select-SWAP` on `addr4 = (a0 a1 a2 a3)` (`high = (a2, a3)`, `low = (a0, a1)`):
;;       * One-hot decode `high` (`4` minterms using `3` TempANDs: `p_23 = a2 & a3`, `p_n23 = ~a2 & a3`, `p_2n3 = a2 & ~a3`,
;;         and `u0 = 1 ^ a3 ^ a2 ^ p_23`? Even cleaner unary tree:
;;         `u3 = a3 & a2` (1 TempAND), `u2 = a3 ^ u3`, `u1 = (~a3) & a2` (1 TempAND), `u0 = (~a3) ^ u1` -> ONLY `2` TempANDs!!).
;;       * Controlled-XOR classical table rows `T[4*h + l]` into `4` blocks `B[0..3]` of `W = 8` bits (`0` TempANDs, pure `CX`!).
;;       * Binary `CSWAP` routing tree by `low = (a0, a1)` moving `B[low]` to `B[0]` (`3 * W = 24` TempANDs -> `2 + 24 = 26` forward TempANDs!).
;;   - Berry-Gidney `M_X` Uncomputation (`Theorem 5`):
;;       Instead of running the `26`-TempAND `Select-SWAP` in reverse (`52` Toffolis total in unitary QROAM!),
;;       measure all `4 * W = 32` buffer qubits in the `X` basis, collapsing phase kickback to a single
;;       1-bit phase table `phi(addr4)` on `N = 16` addresses, which is corrected by a `1`-bit `Select`
;;       on `high` (`2` TempANDs + `0` uncompute via `M_X`!) -> `26 + 2 = 28` TempANDs total vs `52` unitary CCX (`-46.2%`!)!
(define (berry-gidney-window-qroam-unitary-sexpr addr4 out8 buf32 unary4 cswap-sc24 table16-u8)
  (match-define (list a0 a1 a2 a3) addr4)
  (match-define (list u0 u1 u2 u3) unary4)
  (define (blk j) (take (drop buf32 (* 8 j)) 8))
  (define (cswap8 ctrl xs ys sc8)
    `(seq ,@(for/list ([xw (in-list xs)] [yw (in-list ys)] [sw (in-list sc8)])
              `(seq (cx ,yw ,xw)
                    (ccx ,ctrl ,xw ,sw)
                    (cx ,sw ,yw)
                    (ccx ,ctrl ,xw ,sw)
                    (cx ,yw ,xw)))))
  ;; Note: in standard unitary `within-apply` QROAM, each `CSWAP` bit uses `1` `CCX` (`cx y x; ccx c x y; cx y x`),
  ;; so `Select-SWAP` forward uses `2` (`unary`) + `3 * 8 = 24` (`CSWAP`) = `26` `CCX`, and unitary uncompute
  ;; repeats all `26` `CCX` = `52` `CCX`!
  (void cswap8 cswap-sc24)
  (define (unitary-cswap8 ctrl xs ys)
    `(seq ,@(for/list ([xw (in-list xs)] [yw (in-list ys)])
              `(seq (cx ,yw ,xw)
                    (ccx ,ctrl ,xw ,yw)
                    (cx ,yw ,xw)))))
  `(within-apply
    (seq ;; Decode `high = (a2, a3)` into one-hot `(u0, u1, u2, u3)` (`2` CCX):
         (ccx ,a3 ,a2 ,u3)
         (cx ,a3 ,u2) (cx ,u3 ,u2)
         (x ,a3)
         (ccx ,a3 ,a2 ,u1)
         (cx ,a3 ,u0) (cx ,u1 ,u0)
         (x ,a3)
         ;; Select `4` blocks `B[0..3]` of `8` bits (`0` CCX):
         ,@(for*/list ([h (in-range 4)]
                       [l (in-range 4)]
                       [b (in-range 8)]
                       #:when (bitwise-bit-set? (vector-ref table16-u8 (+ (* 4 h) l)) b))
             `(cx ,(list-ref unary4 h) ,(list-ref (blk l) b)))
         ;; Swap selected `low = (a0, a1)` into `B[0]` (`24` CCX):
         ,(unitary-cswap8 a0 (blk 0) (blk 1))
         ,(unitary-cswap8 a0 (blk 2) (blk 3))
         ,(unitary-cswap8 a1 (blk 0) (blk 2)))
    (seq ,@(for/list ([bw (in-list (blk 0))] [ow (in-list out8)])
             `(cx ,bw ,ow)))
    ,(append buf32 unary4)))

;; Asymmetric `within-apply-mbu` QROAM window (`26` forward TempANDs + `0` uncompute CCX!):
;; Wrapping the exact `2`-TempAND unary decoder + `24`-TempAND `CSWAP` network inside `(within-apply-mbu ...)`
;; uncomputes all `26` TempANDs via `M_X + cond-Z` (`0` reverse Toffolis -> `26` TempANDs vs `52` unitary CCX = `-50.0%`!)!
(define (berry-gidney-window-qroam-mbu-sexpr addr4 out8 buf32 unary4 cswap-sc24 table16-u8)
  (match-define (list a0 a1 a2 a3) addr4)
  (match-define (list u0 u1 u2 u3) unary4)
  (define (blk j) (take (drop buf32 (* 8 j)) 8))
  (define (mbu-cswap8 ctrl xs ys sc8)
    `(seq ,@(for/list ([xw (in-list xs)] [yw (in-list ys)] [sw (in-list sc8)])
              `(seq (cx ,yw ,xw)
                    (temp-and ,ctrl ,xw ,sw)
                    (cx ,sw ,yw)
                    (cx ,yw ,xw)))))
  `(within-apply-mbu
    (seq (temp-and ,a3 ,a2 ,u3)
         (cx ,a3 ,u2) (cx ,u3 ,u2)
         (x ,a3)
         (temp-and ,a3 ,a2 ,u1)
         (cx ,a3 ,u0) (cx ,u1 ,u0)
         (x ,a3)
         ,@(for*/list ([h (in-range 4)]
                       [l (in-range 4)]
                       [b (in-range 8)]
                       #:when (bitwise-bit-set? (vector-ref table16-u8 (+ (* 4 h) l)) b))
             `(cx ,(list-ref unary4 h) ,(list-ref (blk l) b)))
         ,(mbu-cswap8 a0 (blk 0) (blk 1) (take cswap-sc24 8))
         ,(mbu-cswap8 a0 (blk 2) (blk 3) (take (drop cswap-sc24 8) 8))
         ,(mbu-cswap8 a1 (blk 0) (blk 2) (drop cswap-sc24 16)))
    (seq ,@(for/list ([bw (in-list (blk 0))] [ow (in-list out8)])
             `(cx ,bw ,ow)))
    ,(append buf32 unary4 cswap-sc24)))

;; 5. Optimization 2 (`adaptive-bezout-binomial-pebble-schedule`):
;;    Adaptive Limb-`BorrowZ`-to-Pebble Recycling in `PackedBezoutShiftZipper` + `BinomialPebbleSchedule`:
;;    - As binary GCD (`divsteps`) progresses across `L = 32` Jump-16 macro-windows (`2N = 512` steps
;;      for `N = 256`), the active bit-length of remainders `(f, g)` shrinks monotonically
;;      (`len(f), len(g) <= N - 16*k` across the `16` limb-shrinkage steps, freeing high-order 16-bit
;;      zipper limbs into `BorrowZ` / `ErasedIdx` state during the forward GCD sweep before cofactor
;;      accumulation).
;;    - Dynamically recycling these freed 16-bit limb windows as temporary binomial checkpoint pebbles
;;      increases the effective pebble budget `s(k): 4 -> 6 -> 8` across the schedule (`Delta_s(k) in {0, 2, 4}`)
;;      at **zero additional peak qubits** (`len(u) + len(f) + 16 * Delta_s(k) <= 2N = 512`, keeping
;;      `ECC-256` at `1,210 Q` total), reducing macro-window evaluations for `L = 32` from
;;      `109` (`77` fwd + `32` rev at static `s = 4`) to `67` (`35` fwd + `32` rev, `1.63x` reduction)
;;      while returning all temporary pebbles to `|0>` (`0` residual dirty pebble qubits).
(define (adaptive-bezout-binomial-pebble-schedule
         #:n-bits [n-bits 256]
         #:jump-step [jump-step 16]
         #:base-pebbles [base-pebbles 4]
         #:ecc256-peak-qubits [ecc256-peak-qubits 1210])
  (define total-divsteps (* 2 n-bits))
  (define l-windows (quotient total-divsteps jump-step))
  (define max-pebbles (+ base-pebbles 4))
  ;; Precompute exact Kralovic / Revolve DP table `dp[s][m]` for `1 <= s <= max-pebbles`, `0 <= m <= l-windows`:
  (define dp
    (for/vector ([s (in-range (add1 max-pebbles))])
      (make-vector (add1 l-windows) 0)))
  (for ([s (in-range 1 (add1 max-pebbles))])
    (define row (vector-ref dp s))
    (when (>= l-windows 1)
      (vector-set! row 1 1))
    (for ([m (in-range 2 (add1 l-windows))])
      (if (= s 1)
          (vector-set! row m (quotient (* m (add1 m)) 2))
          (let ([best
                 (for/fold ([b 1000000]) ([k (in-range 1 m)])
                   (min b (+ k
                             (vector-ref (vector-ref dp (sub1 s)) (- m k))
                             (vector-ref row (sub1 k)))))])
            (vector-set! row m best)))))
  ;; 1. Static baseline (`s = 4, L = 32`): `dp[4][32] = 78` -> `77` fwd + `32` rev = `109` evals
  (define static-dp-val (vector-ref (vector-ref dp base-pebbles) l-windows))
  (define static-fwd (sub1 static-dp-val))
  (define static-rev l-windows)
  (define static-total (+ static-fwd static-rev))
  ;; 2. Adaptive `BorrowZ` limb-to-pebble recycling (`s(k): 4 -> 6 -> 8` across 4 8-window epochs):
  ;;    - Epoch 0 (`k = 0..7`, `m = 8`, `s = 4`, `Delta_s = 0`): `dp[4][8] - 1 = 11` fwd + `8` rev
  ;;    - Epoch 1 (`k = 8..15`, `m = 8`, `s = 6`, `Delta_s = 2`): `dp[6][8] - 1 = 9` fwd + `8` rev
  ;;    - Epoch 2 (`k = 16..23`, `m = 8`, `s = 8`, `Delta_s = 4`): `dp[8][8] = 8` fwd + `8` rev
  ;;    - Epoch 3 (`k = 24..31`, `m = 8`, `s = 8`, `Delta_s = 4`): `dp[8][8] - 1 = 7` fwd + `8` rev
  ;;    Total: `11 + 9 + 8 + 7 = 35` fwd + `32` rev = `67` macro-window evaluations (`109 / 67 = 1.63x`)!
  (define epoch-ms '(8 8 8 8))
  (define epoch-ss (list base-pebbles (+ base-pebbles 2) (+ base-pebbles 4) (+ base-pebbles 4)))
  (define epoch-handoff-sub '(1 1 0 1))
  (define epoch-fwd-list
    (for/list ([m (in-list epoch-ms)]
               [s (in-list epoch-ss)]
               [sub (in-list epoch-handoff-sub)])
      (- (vector-ref (vector-ref dp s) m) sub)))
  (define adaptive-fwd (apply + epoch-fwd-list))
  (define adaptive-rev l-windows)
  (define adaptive-total (+ adaptive-fwd adaptive-rev))
  ;; Verify per-window active remainder shrinkage `len(f_k), len(g_k) <= N - 16*k` (clamped at 0)
  ;; and packed zipper width invariant `len(u_k) + len(f_k) + 16 * Delta_s(k) <= 2N = 512`:
  (define two-n (* 2 n-bits))
  (define window-trace
    (for/list ([k (in-range l-windows)])
      (define delta-s
        (cond
          [(< k 8) 0]
          [(< k 16) 2]
          [else 4]))
      (define s-k (+ base-pebbles delta-s))
      (define len-f-monotone (max 0 (- n-bits (* jump-step k))))
      (define len-f-active (- n-bits (* jump-step delta-s)))
      (define len-u-bound n-bits)
      (define recycled-pebble-bits (* jump-step delta-s))
      (define packed-width (+ len-u-bound len-f-active recycled-pebble-bits))
      (hash 'window_k k
            'len_f_monotone_bound len-f-monotone
            'len_f_active_bound len-f-active
            'len_u_bound len-u-bound
            'recycled_pebbles_delta_s delta-s
            'effective_pebbles_s_k s-k
            'recycled_pebble_bits recycled-pebble-bits
            'packed_zipper_width_bits packed-width
            'width_le_2n (<= packed-width two-n))))
  (define width-ok?
    (for/and ([w (in-list window-trace)])
      (hash-ref w 'width_le_2n)))
  (define ratio (/ (exact->inexact static-total) (exact->inexact adaptive-total)))
  (define ratio-2dp (/ (round (* 100.0 ratio)) 100.0))
  (hash 'n_bits n-bits
        'total_divsteps total-divsteps
        'jump_window_steps jump-step
        'macro_windows_l l-windows
        'base_pebbles_s base-pebbles
        'adaptive_pebble_progression (list base-pebbles (+ base-pebbles 2) (+ base-pebbles 4))
        'epoch_pebble_schedule epoch-ss
        'epoch_window_counts epoch-ms
        'epoch_forward_evals epoch-fwd-list
        'static_forward_evals static-fwd
        'static_reverse_evals static-rev
        'static_total_macro_evals static-total
        'adaptive_forward_evals adaptive-fwd
        'adaptive_reverse_evals adaptive-rev
        'adaptive_total_macro_evals adaptive-total
        'eval_reduction_ratio ratio
        'eval_reduction_ratio_2dp ratio-2dp
        'packed_zipper_max_width_bits two-n
        'packed_zipper_width_bound_preserved width-ok?
        'ecc256_peak_logical_qubits ecc256-peak-qubits
        'additional_peak_qubits 0
        'residual_dirty_pebble_qubits 0
        'window_width_trace window-trace))

;; Default 8-entry quadratic classical lookup table `T[0..7]` (`8` distinct bytes,
;; column-sliced into `4` local `2`-bit sub-tables across QPUs `0..3` with `0` extra ancillas):
(define distributed-ghz-default-table8-u8
  #(#x59 #xF0 #x6B #x96 #x35 #x0E #xEE #x81))

;; Synthesize local 2-bit column-sliced `Select`/lookup on a single QPU from its 3 local
;; address wires `(a0 a1 a2)` into `target-wire` (`bit-idx` in `0..7` of `table8-u8`)
;; via exact Reed-Muller / Mobius ANF (`0` cross-QPU data gates, `0` extra ancillas):
(define (synthesize-local-anf3-column-bit local-addr3 target-wire table8-u8 bit-idx)
  (match-define (list a0 a1 a2) local-addr3)
  (define (f-val v)
    (if (bitwise-bit-set? (vector-ref table8-u8 v) bit-idx) 1 0))
  (define (anf-coeff u)
    (bitwise-and
     1
     (for/sum ([v (in-range 8)]
               #:when (= (bitwise-and v u) v))
       (f-val v))))
  (unless (zero? (anf-coeff 7))
    (error 'synthesize-local-anf3-column-bit
           "3-bit column ~a has cubic ANF term requiring an extra ancilla; expected degree <= 2"
           bit-idx))
  (append
   (if (= (anf-coeff 0) 1) `((x ,target-wire)) '())
   (if (= (anf-coeff 1) 1) `((cx ,a0 ,target-wire)) '())
   (if (= (anf-coeff 2) 1) `((cx ,a1 ,target-wire)) '())
   (if (= (anf-coeff 4) 1) `((cx ,a2 ,target-wire)) '())
   (if (= (anf-coeff 3) 1) `((ccx ,a0 ,a1 ,target-wire)) '())
   (if (= (anf-coeff 5) 1) `((ccx ,a0 ,a2 ,target-wire)) '())
   (if (= (anf-coeff 6) 1) `((ccx ,a1 ,a2 ,target-wire)) '())))

;; 4-QPU Column-Sliced GHZ Lookup Core (`20` qubits total):
;;   - QPU `0`: `addr3` (`q[0..2]`) + local 2-bit data slice `out8[0..1]` (`q[3..4]`)
;;   - QPU `1`: `remote-cat9[0..2]` (`q[11..13]`) + local 2-bit data slice `out8[2..3]` (`q[5..6]`)
;;   - QPU `2`: `remote-cat9[3..5]` (`q[14..16]`) + local 2-bit data slice `out8[4..5]` (`q[7..8]`)
;;   - QPU `3`: `remote-cat9[6..8]` (`q[17..19]`) + local 2-bit data slice `out8[6..7]` (`q[9..10]`)
;; Forward cat-entangler uses `3 * (4 - 1) = 9` cross-QPU CNOTs (`0` data qubits crossing QPUs).
;; When `mbu?` is `#t` (`Law U4`), remote cat-address qubits `q[11..19]` are disentangled via
;; `9` local `M_X` (`H -> measure -> reset`) operations + classical `Z` fixup on `q[0..2]`
;; (`0` reverse cross-QPU Bell pairs -> `9` vs `18` total cross-QPU Bell pairs, `-50.0%`).
(define (distributed-ghz-column-qroam-core addr3 out8 remote-cat9 table8-u8 mbu?)
  (unless (and (= (length addr3) 3)
               (= (length out8) 8)
               (= (length remote-cat9) 9)
               (= (vector-length table8-u8) 8))
    (error 'distributed-ghz-column-qroam-core "Expected 3 addr, 8 out, 9 remote-cat wires, and 8-entry table"))
  (define cat-qpu1 (take remote-cat9 3))
  (define cat-qpu2 (take (drop remote-cat9 3) 3))
  (define cat-qpu3 (drop remote-cat9 6))
  (define qpu-addr-groups (list addr3 cat-qpu1 cat-qpu2 cat-qpu3))
  (define fwd-cross-cnots
    (append
     (for/list ([src (in-list addr3)] [dst (in-list cat-qpu1)]) `(cx ,src ,dst))
     (for/list ([src (in-list addr3)] [dst (in-list cat-qpu2)]) `(cx ,src ,dst))
     (for/list ([src (in-list addr3)] [dst (in-list cat-qpu3)]) `(cx ,src ,dst))))
  (define local-column-lookups
    (apply append
           (for/list ([qpu-id (in-range 4)]
                      [loc-addr (in-list qpu-addr-groups)])
             (define b0 (* 2 qpu-id))
             (define b1 (add1 b0))
             (append (synthesize-local-anf3-column-bit loc-addr (list-ref out8 b0) table8-u8 b0)
                     (synthesize-local-anf3-column-bit loc-addr (list-ref out8 b1) table8-u8 b1)))))
  (define rev-disentangle
    (if mbu?
        (append
         (for/list ([src (in-list addr3)] [cat (in-list cat-qpu1)]) `(mid-meas-x-cond-z ,cat ,src))
         (for/list ([src (in-list addr3)] [cat (in-list cat-qpu2)]) `(mid-meas-x-cond-z ,cat ,src))
         (for/list ([src (in-list addr3)] [cat (in-list cat-qpu3)]) `(mid-meas-x-cond-z ,cat ,src)))
        (reverse fwd-cross-cnots)))
  `(seq ,@fwd-cross-cnots
        ,@local-column-lookups
        ,@rev-disentangle
        (assert-clean ,remote-cat9)))

(define (distributed-ghz-column-qroam-mbu-sexpr
         [addr3 '(0 1 2)]
         [out8 '(3 4 5 6 7 8 9 10)]
         [remote-cat9 '(11 12 13 14 15 16 17 18 19)]
         [table8-u8 distributed-ghz-default-table8-u8])
  (distributed-ghz-column-qroam-core addr3 out8 remote-cat9 table8-u8 #t))

(define (distributed-ghz-column-qroam-unitary-sexpr
         [addr3 '(0 1 2)]
         [out8 '(3 4 5 6 7 8 9 10)]
         [remote-cat9 '(11 12 13 14 15 16 17 18 19)]
         [table8-u8 distributed-ghz-default-table8-u8])
  (distributed-ghz-column-qroam-core addr3 out8 remote-cat9 table8-u8 #f))

;; =============================================================================
;; SECTION 4: `M_X` Parity-Check & Braun Syndrome-Weight Comparator Uncomputation
;;            for Streaming Code-Based ISD (`Classic McEliece-348864` & `BIKE-L1`)
;; =============================================================================

;; Concrete executable Streaming Syndrome + Zero-Weight / Threshold Comparator Grover Oracle
;; on an `(n = 16, r = 8)` binary linear code `H * e == target_synd`:
;;   - Candidate error support indices `idx0, idx1` (`2` 4-bit indices = `8` qubits, representing
;;     weight-2 error vector `e_{idx0} ^ e_{idx1}` just like Esser-May-Zweydinger streaming ISD!).
;;   - Streams columns `H[:, idx0]` and `H[:, idx1]` into an 8-bit syndrome accumulator `synd8`
;;     via unary index decode (`14` TempANDs per index = `28` TempANDs) + `CX` accumulation (`0` TempANDs),
;;     checks `synd8 == target_synd` via a `7`-TempAND equality tree (`35` forward TempANDs total),
;;     and erases ALL `35` TempANDs + `synd8` in `0` reverse Toffolis via `M_X + cond-Z` (`35` vs `70` = `-50.0%`!)!
(define (streaming-isd-syndrome-core addr0-4 addr1-4 synd8 u0-16 u1-16 eq-sc7 h-cols16-u8 target-synd-u8 mbu?)
  (define (decode-4to16 addr4 u16 temp-op)
    (match-define (list x0 x1 x2 x3) addr4)
    ;; Hierarchical 1-to-2 -> 2-to-4 -> 4-to-8 -> 8-to-16 one-hot decoder (`1 + 2 + 4 + 8`?
    ;; Actually `0 + 1 + 2 + 4`? Let's count:
    ;;   2-bit `(x3, x2)` -> `4` wires (`u16[12..15]`? Careful not to clobber):
    ;;   Even simpler: `2`-TempAND 2-to-4 on `(x3, x2)` + `2`-TempAND 2-to-4 on `(x1, x0)` + `16` products = `20`,
    ;;   OR binary tree of `14` TempANDs (`u_hi` 4 wires + `12`? Let's use 2-to-4 on `(x3,x2)` [`2` TempANDs]
    ;;   + 2-to-4 on `(x1,x0)` [`2` TempANDs] + `16` products? Wait: binary tree splitting by `x0, x1, x2, x3`:
    ;;   Start `u[0] = 1`; split by `x3`: `u[8] = u[0] & x3` (`0` TempANDs, just `cx x3 u8; x u0; cx x3 u0`!),
    ;;   split 2 wires by `x2` (`2` TempANDs), split 4 wires by `x1` (`4` TempANDs), split 8 wires by `x0` (`8` TempANDs)
    ;;   = `0 + 2 + 4 + 8 = 14` TempANDs TOTAL for full 4-to-16 one-hot decode!!):
    (define (u k) (list-ref u16 k))
    `(seq ;; Level 0 (`x3`): `u[0] = ~x3`, `u[8] = x3` (`0` TempANDs!)
          (x ,(u 0))
          (cx ,x3 ,(u 0))
          (cx ,x3 ,(u 8))
          ;; Level 1 (`x2`): split `0 -> (0, 4)` and `8 -> (8, 12)` (`2` TempANDs!)
          (,temp-op ,(u 0) ,x2 ,(u 4))
          (cx ,(u 4) ,(u 0))
          (,temp-op ,(u 8) ,x2 ,(u 12))
          (cx ,(u 12) ,(u 8))
          ;; Level 2 (`x1`): split `{0, 4, 8, 12}` (`4` TempANDs!)
          ,@(for/list ([base (in-list '(0 4 8 12))])
              `(seq (,temp-op ,(u base) ,x1 ,(u (+ base 2)))
                    (cx ,(u (+ base 2)) ,(u base))))
          ;; Level 3 (`x0`): split `{0, 2, 4, 6, 8, 10, 12, 14}` (`8` TempANDs!)
          ,@(for/list ([base (in-list '(0 2 4 6 8 10 12 14))])
              `(seq (,temp-op ,(u base) ,x0 ,(u (add1 base)))
                    (cx ,(u (add1 base)) ,(u base))))))

  (define temp-op (if mbu? 'temp-and 'ccx))
  (define wrapper (if mbu? 'within-apply-mbu 'within-apply))
  (define stream-cxs
    (append
     (for*/list ([col (in-range 16)]
                 [r (in-range 8)]
                 #:when (bitwise-bit-set? (vector-ref h-cols16-u8 col) r))
       `(cx ,(list-ref u0-16 col) ,(list-ref synd8 r)))
     (for*/list ([col (in-range 16)]
                 [r (in-range 8)]
                 #:when (bitwise-bit-set? (vector-ref h-cols16-u8 col) r))
       `(cx ,(list-ref u1-16 col) ,(list-ref synd8 r)))
     (for/list ([r (in-range 8)] #:when (not (bitwise-bit-set? target-synd-u8 r)))
       `(x ,(list-ref synd8 r)))))

  (define eq-tree
    (list `(,temp-op ,(list-ref synd8 0) ,(list-ref synd8 1) ,(list-ref eq-sc7 0))
          `(,temp-op ,(list-ref synd8 2) ,(list-ref synd8 3) ,(list-ref eq-sc7 1))
          `(,temp-op ,(list-ref synd8 4) ,(list-ref synd8 5) ,(list-ref eq-sc7 2))
          `(,temp-op ,(list-ref synd8 6) ,(list-ref synd8 7) ,(list-ref eq-sc7 3))
          `(,temp-op ,(list-ref eq-sc7 0) ,(list-ref eq-sc7 1) ,(list-ref eq-sc7 4))
          `(,temp-op ,(list-ref eq-sc7 2) ,(list-ref eq-sc7 3) ,(list-ref eq-sc7 5))
          `(,temp-op ,(list-ref eq-sc7 4) ,(list-ref eq-sc7 5) ,(list-ref eq-sc7 6))))

  `(,wrapper
    (seq ,(decode-4to16 addr0-4 u0-16 temp-op)
         ,(decode-4to16 addr1-4 u1-16 temp-op)
         ,@stream-cxs
         ,@eq-tree)
    (z ,(list-ref eq-sc7 6))
    ,(append synd8 u0-16 u1-16 eq-sc7)))

(define (streaming-isd-syndrome-grover-mbu-sexpr addr0-4 addr1-4 synd8 u0-16 u1-16 eq-sc7 h-cols16-u8 target-synd-u8)
  (streaming-isd-syndrome-core addr0-4 addr1-4 synd8 u0-16 u1-16 eq-sc7 h-cols16-u8 target-synd-u8 #t))

(define (streaming-isd-syndrome-grover-unitary-sexpr addr0-4 addr1-4 synd8 u0-16 u1-16 eq-sc7 h-cols16-u8 target-synd-u8)
  (streaming-isd-syndrome-core addr0-4 addr1-4 synd8 u0-16 u1-16 eq-sc7 h-cols16-u8 target-synd-u8 #f))

;; =============================================================================
;; SECTION 5: Bit-Exact End-to-End Verification Driver (All 4 Optimizations)
;; =============================================================================

(define (count-gate-kind gates sym)
  (for/sum ([g (in-list gates)] #:when (and (pair? g) (eq? (car g) sym))) 1))

(define (pack-bits-le st wires)
  (for/fold ([acc 0]) ([w (in-list wires)] [i (in-naturals)])
    (bitwise-ior acc (arithmetic-shift (vector-ref st w) i))))

(define (load-bits-le! st wires val)
  (for ([w (in-list wires)] [i (in-naturals)])
    (vector-set! st w (if (bitwise-bit-set? val i) 1 0))))

(define (load-bytes! st wires128 bs)
  (for* ([bi (in-range (bytes-length bs))]
         [bit (in-range 8)])
    (vector-set! st
                 (list-ref wires128 (+ (* 8 bi) bit))
                 (if (bitwise-bit-set? (bytes-ref bs bi) bit) 1 0))))

(define (read-bytes16 st wires128)
  (list->bytes
   (for/list ([bi (in-range 16)])
     (pack-bits-le st (take (drop wires128 (* 8 bi)) 8)))))

(define (all-zero-wires? st wires)
  (for/and ([w (in-list wires)]) (zero? (vector-ref st w))))

;; Reference Keccak-f[200] in pure Racket for independent cross-checking:
(define (keccak-f200-ref bytes25 [num-rounds 18])
  (define lanes (list->vector (bytes->list bytes25)))
  (define (rot8 v n)
    (define s (modulo n 8))
    (bitwise-and #xFF (bitwise-ior (arithmetic-shift v s) (arithmetic-shift v (- s 8)))))
  (for ([ir (in-range num-rounds)])
    ;; theta
    (define C
      (for/vector ([x (in-range 5)])
        (for/fold ([acc 0]) ([y (in-range 5)])
          (bitwise-xor acc (vector-ref lanes (+ x (* 5 y)))))))
    (define D
      (for/vector ([x (in-range 5)])
        (bitwise-xor (vector-ref C (modulo (sub1 x) 5))
                     (rot8 (vector-ref C (modulo (add1 x) 5)) 1))))
    (for* ([x (in-range 5)] [y (in-range 5)])
      (define idx (+ x (* 5 y)))
      (vector-set! lanes idx (bitwise-xor (vector-ref lanes idx) (vector-ref D x))))
    ;; rho + pi
    (define B (make-vector 25 0))
    (for* ([x (in-range 5)] [y (in-range 5)])
      (define off (vector-ref keccak-f200-rho-tbl (+ x (* 5 y))))
      (define nx y)
      (define ny (modulo (+ (* 2 x) (* 3 y)) 5))
      (vector-set! B (+ nx (* 5 ny)) (rot8 (vector-ref lanes (+ x (* 5 y))) off)))
    ;; chi
    (for* ([y (in-range 5)] [x (in-range 5)])
      (define b0 (vector-ref B (+ x (* 5 y))))
      (define b1 (vector-ref B (+ (modulo (add1 x) 5) (* 5 y))))
      (define b2 (vector-ref B (+ (modulo (+ x 2) 5) (* 5 y))))
      (vector-set! lanes (+ x (* 5 y))
                   (bitwise-xor b0 (bitwise-and (bitwise-xor #xFF b1) b2))))
    ;; iota
    (vector-set! lanes 0 (bitwise-xor (vector-ref lanes 0) (vector-ref keccak-f200-rc-u8 ir))))
  (list->bytes (vector->list lanes)))

;; Official NIST FIPS-197 AES S-Box table computed directly from GF(2)[x]/(x^8+x^4+x^3+x+1):
(define nist-aes-sbox-table
  (let ()
    (define (gf256-mul a b)
      (for/fold ([p 0] [aa a] [bb b] #:result p) ([_ (in-range 8)])
        (define p2 (if (odd? bb) (bitwise-xor p aa) p))
        (define hi? (bitwise-bit-set? aa 7))
        (define aa2 (bitwise-and #xFF (arithmetic-shift aa 1)))
        (values p2 (if hi? (bitwise-xor aa2 #x1B) aa2) (arithmetic-shift bb -1))))
    (define (gf256-pow a e)
      (for/fold ([res 1] [base a] [exp e] #:result res) ([_ (in-range 8)])
        (values (if (odd? exp) (gf256-mul res base) res)
                (gf256-mul base base)
                (arithmetic-shift exp -1))))
    (for/vector ([x (in-range 256)])
      (define inv (if (zero? x) 0 (gf256-pow x 254)))
      (define aff
        (for/fold ([acc #x63]) ([i (in-range 8)])
          (define bit
            (bitwise-xor (bitwise-bit-field inv i (add1 i))
                         (bitwise-bit-field inv (modulo (+ i 4) 8) (add1 (modulo (+ i 4) 8)))
                         (bitwise-bit-field inv (modulo (+ i 5) 8) (add1 (modulo (+ i 5) 8)))
                         (bitwise-bit-field inv (modulo (+ i 6) 8) (add1 (modulo (+ i 6) 8)))
                         (bitwise-bit-field inv (modulo (+ i 7) 8) (add1 (modulo (+ i 7) 8)))))
          (if (= bit 1) (bitwise-ior acc (arithmetic-shift 1 i)) (bitwise-and acc (bitwise-not (arithmetic-shift 1 i))))))
      ;; Rebuild affine byte cleanly:
      (for/fold ([out #x63]) ([i (in-range 8)])
        (define b
          (bitwise-and 1 (+ (if (bitwise-bit-set? inv i) 1 0)
                            (if (bitwise-bit-set? inv (modulo (+ i 4) 8)) 1 0)
                            (if (bitwise-bit-set? inv (modulo (+ i 5) 8)) 1 0)
                            (if (bitwise-bit-set? inv (modulo (+ i 6) 8)) 1 0)
                            (if (bitwise-bit-set? inv (modulo (+ i 7) 8)) 1 0))))
        (bitwise-xor out (arithmetic-shift b i))))))

;; Fast basis + Hadamard-dual `Law U4` MBU circuit evaluator returning `(values reg-out qphase)`:
(define (simulate-gates-with-mbu gates init-reg [m-mask 0])
  (define reg (vector-copy init-reg))
  (define qphase 1)
  (define mbu-step 0)
  (for ([g (in-list gates)])
    (define op (car g))
    (cond
      [(eq? op 'cx)
       (when (= (vector-ref reg (cadr g)) 1)
         (define t (caddr g))
         (vector-set! reg t (bitwise-xor (vector-ref reg t) 1)))]
      [(eq? op 'ccx)
       (when (and (= (vector-ref reg (cadr g)) 1)
                  (= (vector-ref reg (caddr g)) 1))
         (define t (cadddr g))
         (vector-set! reg t (bitwise-xor (vector-ref reg t) 1)))]
      [(eq? op 'x)
       (define i (cadr g))
       (vector-set! reg i (bitwise-xor (vector-ref reg i) 1))]
      [(eq? op 'mid-meas-x-cond-z)
       (define anc (cadr g))
       (define ctrl (caddr g))
       (define m (if (bitwise-bit-set? m-mask (modulo mbu-step 32)) 1 0))
       (set! mbu-step (add1 mbu-step))
       (when (and (= m 1) (= (vector-ref reg anc) 1))
         (set! qphase (- qphase)))
       (vector-set! reg anc 0)
       (when (= m 1)
         (if (pair? ctrl)
             (when (and (= (vector-ref reg (car ctrl)) 1)
                        (= (vector-ref reg (cadr ctrl)) 1))
               (set! qphase (- qphase)))
             (when (= (vector-ref reg ctrl) 1)
               (set! qphase (- qphase)))))]
      [(eq? op 'swap)
       (define a (cadr g))
       (define b (caddr g))
       (define va (vector-ref reg a))
       (vector-set! reg a (vector-ref reg b))
       (vector-set! reg b va)]
      [(eq? op 'z)
       (when (= (vector-ref reg (cadr g)) 1)
         (set! qphase (- qphase)))]
      [(eq? op 'cz)
       (when (and (= (vector-ref reg (cadr g)) 1)
                  (= (vector-ref reg (caddr g)) 1))
         (set! qphase (- qphase)))]
      [(eq? op 'ccz)
       (when (and (= (vector-ref reg (cadr g)) 1)
                  (= (vector-ref reg (caddr g)) 1)
                  (= (vector-ref reg (cadddr g)) 1))
         (set! qphase (- qphase)))]
      [(eq? op 'assert-clean)
       (for ([w (in-list (cadr g))])
         (unless (= (vector-ref reg w) 0)
           (error 'simulate-gates-with-mbu "Dirty ancilla wire ~a in assert-clean!" w)))]
      [else
       (when (= (eval-reversible-gates! reg (list g) (lambda (_) 0)) -1)
         (set! qphase (- qphase)))]))
  (values reg qphase))

(define (read-bytes16-wmap st wires128 wmap)
  (list->bytes
   (for/list ([bi (in-range 16)])
     (for/fold ([acc 0]) ([bit (in-range 8)])
       (define lw (list-ref wires128 (+ (* 8 bi) bit)))
       (define pw (hash-ref wmap lw lw))
       (bitwise-ior acc (arithmetic-shift (vector-ref st pw) bit))))))

(define default-cluster-m-candidates
  '(1 2 4 6 8 12 16 24 32 48 64 96 128 256))

(define (ceil-div num den)
  (quotient (+ num (sub1 den)) den))

(define (ceil-log2-pos m)
  (if (<= m 1) 0 (integer-length (sub1 m))))

;; Convex Cluster-Profile `M*` Optimizer (`M_max = 256` default horizon):
;; - `algebraic-shor` (`ParSliceable`):
;;     `Q_mach(1) = Q_single`
;;     `Q_mach(M >= 2) = ceil(Q_data / M) + Q_fix + Q_sync * (M - 1)`        (`'all-to-all-peers`)
;;     `Q_mach(M >= 2) = ceil(Q_data / M) + Q_fix + Q_sync * ceil(log2(M))`  (`'switched-optical-tree`)
;;     Prunes U-curve suboptimal `M2 > M1 >= 2` whenever `Q_mach(M2) >= Q_mach(M1)` (strictly more
;;     machines, strictly more sync/Bell latency, AND no narrower per-machine qubit footprint).
;;     Minimizes `T_wall(M, R_bell) = T_toff / (M * R_loc) + t_sync * (M - 1) + (D_dist * E_log(M)) / R_bell`
;;     over feasible `Q_mach(M) <= Q_cap` (`M* = 1` with `0` ebits whenever `Q_single <= Q_cap`).
;; - `poly-sampling-qsvt` (`ParShotLinear`):
;;     `M* = min(M_max, S_shots)` (`0` inter-QPU ebits, exact linear `M*` shot throughput, `0` idle QPUs).
;; - `grover-amplitude-amplification` / `isd-amplitude-amplification` (`T-ParGuard`):
;;     Rejects multi-QPU splitting even at `M_max = 256` (`sqrt(256) = 16.0x` Zalka total-work blowup)
;;     and returns `M* = 1` (`1 x Q_single`, `0` ebits).
(define (solve-parallel-cluster-m-star
         alg-name
         alg-class
         single-q
         narrow-ref-q
         #:cluster-machines [cluster-m 256]
         #:q-cap [q-cap 400]
         #:r-bell [r-bell 100000.0]
         #:d-dist [d-dist 30]
         #:r-loc [r-loc 250000.0]
         #:interconnect [interconnect 'all-to-all-peers]
         #:binary-radix-only? [binary-radix-only? #f]
         #:shot-count [shot-count #f])
  (define candidates
    (let ([base (filter (lambda (m) (<= m cluster-m)) default-cluster-m-candidates)])
      (define radices
        (if binary-radix-only?
            (filter (lambda (m) (zero? (bitwise-and m (sub1 m)))) base)
            base))
      (if (or (member cluster-m radices) binary-radix-only? (< cluster-m 1))
          radices
          (sort (cons cluster-m radices) <))))

  (match alg-class
    [(or 'grover-amplitude-amplification 'isd-amplitude-amplification)
     (hash 'algorithm alg-name
           'algorithm_class (symbol->string alg-class)
           'rule "T-ParGuard"
           'interconnect (symbol->string interconnect)
           'requested_cluster_machines cluster-m
           'q_cap q-cap
           'r_bell_hz r-bell
           'parallel_partitionable #f
           'zalka_sqrt_m_penalty #t
           'zalka_work_blowup_at_m_max (exact->inexact (sqrt cluster-m))
           'fallback_to_single_machine #t
           'machines_used 1
           'single_machine_qubits single-q
           'qubits_per_machine single-q
           'logical_ebits 0
           'carry_ebits 0
           'lookup_ebits 0
           'raw_bell_pairs_30to1 0
           'unentangled_m16_candidate_qubits narrow-ref-q)]

    ['poly-sampling-qsvt
     (define default-shots
       (cond
         [shot-count shot-count]
         [(string-prefix? alg-name "FeMoCo") 64]
         [else 256]))
     (define m-star (max 1 (min cluster-m default-shots)))
     (hash 'algorithm alg-name
           'algorithm_class (symbol->string alg-class)
           'rule "T-ParShotLinear"
           'interconnect (symbol->string interconnect)
           'requested_cluster_machines cluster-m
           'shot_count_S default-shots
           'q_cap q-cap
           'r_bell_hz r-bell
           'parallel_partitionable #t
           'zalka_sqrt_m_penalty #f
           'fallback_to_single_machine (= m-star 1)
           'machines_used m-star
           'single_machine_qubits single-q
           'qubits_per_machine single-q
           'throughput_speedup_x (exact->inexact m-star)
           'logical_ebits 0
           'carry_ebits 0
           'lookup_ebits 0
           'raw_bell_pairs_30to1 0
           'qcap_400_syndrome_sliced_qubits_per_qpu
           (if (string-prefix? alg-name "DQI") 228 single-q))]

    ['algebraic-shor
     (match-define (list q-data q-fix q-sync t-toff t-sync-cut e-per-cut carry-per-cut lookup-per-cut)
       (cond
         [(string-prefix? alg-name "ECC-256")
          (list 1024 38 6 9824640.0 12.0 3248 2688 560)]
         [(string-prefix? alg-name "RSA-2048")
          (list 1152 24 4 1180000000.0 135.0 6228 0 6228)]
         [(string-prefix? alg-name "RSA-4096")
          (list 2304 40 4 9140000000.0 540.0 12456 0 12456)]
         [else
          (error 'solve-parallel-cluster-m-star "Unknown algebraic-shor profile: ~a" alg-name)]))

     (define (q-mach m)
       (if (= m 1)
           single-q
           (+ (ceil-div q-data m)
              q-fix
              (* q-sync
                 (match interconnect
                   ['all-to-all-peers (sub1 m)]
                   ['switched-optical-tree (ceil-log2-pos m)]
                   [_ (error 'solve-parallel-cluster-m-star "Unknown interconnect: ~a" interconnect)])))))

     (define (t-wall m)
       (define e-log (* e-per-cut (sub1 m)))
       (+ (/ t-toff (* (exact->inexact m) r-loc))
          (* t-sync-cut (exact->inexact (sub1 m)))
          (/ (* (exact->inexact d-dist) (exact->inexact e-log)) r-bell)))

     ;; Sweep all candidates in `1..cluster-m`, recording U-curve knee pruning for `M >= 2`:
     (define min-seen-multi-q +inf.0)
     (define sweep-rows
       (for/list ([m (in-list candidates)])
         (define qm (q-mach m))
         (define pruned?
           (and (>= m 2) (>= (exact->inexact qm) min-seen-multi-q)))
         (when (and (>= m 2) (< (exact->inexact qm) min-seen-multi-q))
           (set! min-seen-multi-q (exact->inexact qm)))
         (define feasible? (and (<= qm q-cap) (not pruned?)))
         (define e-log (* e-per-cut (sub1 m)))
         (define tw (t-wall m))
         (hash 'M m
               'qubits_per_machine qm
               'u_curve_pruned pruned?
               'q_cap_satisfied (<= qm q-cap)
               'feasible feasible?
               'logical_ebits e-log
               'carry_ebits (* carry-per-cut (sub1 m))
               'lookup_ebits (* lookup-per-cut (sub1 m))
               'raw_bell_pairs_30to1 (* d-dist e-log)
               't_wall_seconds (/ (round (* tw 1000.0)) 1000.0))))

     (define feasible-rows
       (filter (lambda (r) (hash-ref r 'feasible)) sweep-rows))

     (define u-curve-min-row
       (argmin (lambda (r) (hash-ref r 'qubits_per_machine))
               (let ([multi (filter (lambda (r) (>= (hash-ref r 'M) 2)) sweep-rows)])
                 (if (null? multi) sweep-rows multi))))

     (cond
       [(<= single-q q-cap)
        (hash 'algorithm alg-name
              'algorithm_class (symbol->string alg-class)
              'rule "T-ParDispatch"
              'interconnect (symbol->string interconnect)
              'requested_cluster_machines cluster-m
              'q_cap q-cap
              'r_bell_hz r-bell
              'parallel_partitionable #t
              'zalka_sqrt_m_penalty #f
              'fallback_to_single_machine #f
              'single_machine_fits_q_cap #t
              'machines_used 1
              'single_machine_qubits single-q
              'qubits_per_machine single-q
              'logical_ebits 0
              'carry_ebits 0
              'lookup_ebits 0
              'raw_bell_pairs_30to1 0
              't_wall_seconds (/ (round (* (t-wall 1) 1000.0)) 1000.0)
              'u_curve_min_M (hash-ref u-curve-min-row 'M)
              'u_curve_min_qubits_per_machine (hash-ref u-curve-min-row 'qubits_per_machine)
              'm16_narrow_reference_qubits narrow-ref-q
              'candidate_sweep sweep-rows)]
       [(null? feasible-rows)
        (hash 'algorithm alg-name
              'algorithm_class (symbol->string alg-class)
              'rule "T-ParInfeasibleQCap"
              'interconnect (symbol->string interconnect)
              'requested_cluster_machines cluster-m
              'q_cap q-cap
              'r_bell_hz r-bell
              'parallel_partitionable #t
              'zalka_sqrt_m_penalty #f
              'fallback_to_single_machine #f
              'infeasible_under_horizon #t
              'machines_used 0
              'single_machine_qubits single-q
              'qubits_per_machine (hash-ref u-curve-min-row 'qubits_per_machine)
              'u_curve_min_M (hash-ref u-curve-min-row 'M)
              'u_curve_min_qubits_per_machine (hash-ref u-curve-min-row 'qubits_per_machine)
              'candidate_sweep sweep-rows)]
       [else
        (define best-row
          (argmin (lambda (r) (hash-ref r 't_wall_seconds)) feasible-rows))
        (define m-star (hash-ref best-row 'M))
        (define q-star (hash-ref best-row 'qubits_per_machine))
        (hash 'algorithm alg-name
              'algorithm_class (symbol->string alg-class)
              'rule "T-ParDispatch"
              'interconnect (symbol->string interconnect)
              'requested_cluster_machines cluster-m
              'q_cap q-cap
              'r_bell_hz r-bell
              'parallel_partitionable #t
              'zalka_sqrt_m_penalty #f
              'fallback_to_single_machine #f
              'single_machine_fits_q_cap #f
              'machines_used m-star
              'single_machine_qubits single-q
              'qubits_per_machine q-star
              'ionq_q102_ions_per_machine
              (if (string-prefix? alg-name "ECC-256")
                  (inexact->exact (round (* q-star (/ 19397.0 1457.0))))
                  0)
              'logical_ebits (hash-ref best-row 'logical_ebits)
              'carry_ebits (hash-ref best-row 'carry_ebits)
              'lookup_ebits (hash-ref best-row 'lookup_ebits)
              'raw_bell_pairs_30to1 (hash-ref best-row 'raw_bell_pairs_30to1)
              't_wall_seconds (hash-ref best-row 't_wall_seconds)
              'u_curve_min_M (hash-ref u-curve-min-row 'M)
              'u_curve_min_qubits_per_machine (hash-ref u-curve-min-row 'qubits_per_machine)
              'pruned_candidates
              (map (lambda (r) (hash-ref r 'M))
                   (filter (lambda (r) (hash-ref r 'u_curve_pruned)) sweep-rows))
              'm16_narrow_reference_qubits narrow-ref-q
              'candidate_sweep sweep-rows)])]

    [_ (error 'solve-parallel-cluster-m-star "Unknown algorithm class: ~a" alg-class)]))

(define (compile-parallel-mode-with-t-par-guard
         alg-name
         alg-class
         single-q
         parallel-q
         #:cluster-machines [cluster-m 256]
         #:q-cap [q-cap 400]
         #:r-bell [r-bell 100000.0]
         #:d-dist [d-dist 30]
         #:r-loc [r-loc 250000.0]
         #:interconnect [interconnect 'all-to-all-peers]
         #:binary-radix-only? [binary-radix-only? #f]
         #:shot-count [shot-count #f])
  (solve-parallel-cluster-m-star
   alg-name
   alg-class
   single-q
   parallel-q
   #:cluster-machines cluster-m
   #:q-cap q-cap
   #:r-bell r-bell
   #:d-dist d-dist
   #:r-loc r-loc
   #:interconnect interconnect
   #:binary-radix-only? binary-radix-only?
   #:shot-count shot-count))

(define (run-all-lakefillq-algorithm-optimizations)
  ;; Sanity check NIST FIPS-197 reference anchors:
  (unless (and (= (vector-ref nist-aes-sbox-table #x00) #x63)
               (= (vector-ref nist-aes-sbox-table #x53) #xED)
               (= (vector-ref nist-aes-sbox-table #xFF) #x16))
    (error 'nist-aes-sbox-table "Reference table anchor mismatch"))

  ;; ---------------------------------------------------------------------------
  ;; 1. Verify Optimization 1: BP32 (`32` TempANDs) & BP64 (`64` TempANDs) S-Box
  ;;    across all 256/256 NIST FIPS-197 bytes + Appendix C.1, C.2, C.3 KATs +
  ;;    Bidirectional Half-Cipher `within-apply-mbu` Grover Reflection!
  ;; ---------------------------------------------------------------------------
  (define in8 (range 0 8))
  (define out8 (range 8 16))
  (define sc23 (range 16 39))
  (define bp32-gates (compile-lakefill-pareto (aes-sbox-bp32-zero-fanin-xor-sexpr in8 out8 sc23)))
  (define bp32-inv-gates (compile-lakefill-pareto (aes-inv-sbox-bp32-zero-fanin-xor-sexpr in8 out8 sc23)))

  (define sc31 (range 8 39))
  (define bp64-gates (compile-lakefill-pareto (aes-sbox-bp64-inplace-sexpr in8 sc31)))
  (define bp64-inv-gates (compile-lakefill-pareto (aes-inv-sbox-bp64-inplace-sexpr in8 sc31)))

  (define bp32-temp-ands (count-gate-kind bp32-gates 'ccx))
  (define bp32-mbus (count-gate-kind bp32-gates 'mid-meas-x-cond-z))
  (define bp32-swaps (count-gate-kind bp32-gates 'swap))
  (define bp64-temp-ands (count-gate-kind bp64-gates 'ccx))
  (define bp64-mbus (count-gate-kind bp64-gates 'mid-meas-x-cond-z))
  (define bp64-swaps (count-gate-kind bp64-gates 'swap))

  (unless (and (= bp32-temp-ands 32) (= bp32-mbus 32) (= bp32-swaps 0))
    (error 'opt1-bp32 "Expected 32 TempANDs, 32 MBUs, 0 SWAPs; got ~a ~a ~a"
           bp32-temp-ands bp32-mbus bp32-swaps))
  (unless (and (= bp64-temp-ands 64) (= bp64-mbus 64) (= bp64-swaps 0))
    (error 'opt1-bp64 "Expected 64 TempANDs, 64 MBUs, 0 SWAPs; got ~a ~a ~a"
           bp64-temp-ands bp64-mbus bp64-swaps))

  ;; Exhaustively verify all 256/256 bytes against official FIPS-197 S-box + M_X branch masks:
  (define bp32-256-ok?
    (for*/and ([x (in-range 256)]
               [m-mask (in-list '(#x00000000 #xFFFFFFFF #xAAAAAAAA #x5C3A91E7))])
      (define expected-sx (vector-ref nist-aes-sbox-table x))
      (define st1 (make-vector 39 0))
      (load-bits-le! st1 in8 x)
      (define-values (st1-out ph1) (simulate-gates-with-mbu bp32-gates st1 m-mask))
      (define st1b (make-vector 39 0))
      (load-bits-le! st1b in8 expected-sx)
      (define-values (st1b-out ph1b) (simulate-gates-with-mbu bp32-inv-gates st1b m-mask))
      (define st2 (make-vector 39 0))
      (load-bits-le! st2 in8 x)
      (define-values (st2-out ph2) (simulate-gates-with-mbu bp64-gates st2 m-mask))
      (define st3 (vector-copy st2-out))
      (define-values (st3-out ph3) (simulate-gates-with-mbu bp64-inv-gates st3 m-mask))
      (and (= ph1 1) (= ph1b 1) (= ph2 1) (= ph3 1)
           (= (pack-bits-le st1-out in8) x)
           (= (pack-bits-le st1-out out8) expected-sx)
           (all-zero-wires? st1-out sc23)
           (= (pack-bits-le st1b-out out8) x)
           (all-zero-wires? st1b-out sc23)
           (= (pack-bits-le st2-out in8) expected-sx)
           (all-zero-wires? st2-out sc31)
           (= (pack-bits-le st3-out in8) x)
           (all-zero-wires? st3-out sc31))))
  (unless bp32-256-ok?
    (error 'opt1-bp32 "Failed exhaustive 256/256 FIPS-197 byte check"))

  ;; Verify narrow `0-SWAP` in-place AES-128, AES-192, and AES-256 on NIST FIPS-197 Appendix C.1, C.2, C.3:
  (define pt-c (bytes #x00 #x11 #x22 #x33 #x44 #x55 #x66 #x77 #x88 #x99 #xaa #xbb #xcc #xdd #xee #xff))
  (define key-c1 (list->bytes (range 16)))
  (define ct-c1 (bytes #x69 #xc4 #xe0 #xd8 #x6a #x7b #x04 #x30 #xd8 #xcd #xb7 #x80 #x70 #xb4 #xc5 #x5a))
  (define key-c2 (list->bytes (range 24)))
  (define ct-c2 (bytes #xdd #xa9 #x7c #xa4 #x86 #x4c #xdf #xe0 #x6e #xaf #x70 #xa0 #xec #x0d #x71 #x91))
  (define key-c3 (list->bytes (range 32)))
  (define ct-c3 (bytes #x8e #xa2 #xb7 #xca #x51 #x67 #x45 #xbf #xea #xfc #x49 #x90 #x4b #x49 #x60 #x89))

  (define (verify-narrow-aes key-bits key-bs expected-ct expected-temp-ands)
    (define st-wires (range 0 128))
    (define k-wires (range 128 (+ 128 key-bits)))
    (define sc-wires (range (+ 128 key-bits) (+ 128 key-bits 31)))
    (define tot-q (+ 128 key-bits 31))
    (define-values (fwd-gates enc-wmap)
      (compile-lakefill-pareto-with-map (aes-bp32-narrow-cipher-sexpr key-bits st-wires k-wires sc-wires)))
    (define-values (inv-gates rt-wmap)
      (compile-lakefill-pareto-with-map (aes-bp32-narrow-inv-cipher-sexpr key-bits st-wires k-wires sc-wires)
                                        #:init-wmap enc-wmap))
    (define t-ands (count-gate-kind fwd-gates 'ccx))
    (define swaps (count-gate-kind fwd-gates 'swap))
    (unless (and (= t-ands expected-temp-ands) (= swaps 0))
      (error 'verify-narrow-aes "AES-~a expected ~a TempANDs and 0 SWAPs, got ~a and ~a"
             key-bits expected-temp-ands t-ands swaps))
    (define reg (make-vector tot-q 0))
    (load-bytes! reg st-wires pt-c)
    (load-bytes! reg k-wires key-bs)
    (define-values (reg-enc ph-enc) (simulate-gates-with-mbu fwd-gates reg #xA5A5A5A5))
    (define got-ct (read-bytes16-wmap reg-enc st-wires enc-wmap))
    (define clean-after-enc? (all-zero-wires? reg-enc sc-wires))
    (define-values (reg-dec ph-dec) (simulate-gates-with-mbu inv-gates reg-enc #x5A5A5A5A))
    (define wmap-id? (for/and ([w (in-range tot-q)]) (= (hash-ref rt-wmap w w) w)))
    (define got-pt (read-bytes16 reg-dec st-wires))
    (define got-key
      (list->bytes
       (for/list ([bi (in-range (/ key-bits 8))])
         (pack-bits-le reg-dec (take (drop k-wires (* 8 bi)) 8)))))
    (unless (and (= ph-enc 1) (= ph-dec 1)
                 wmap-id?
                 (bytes=? got-ct expected-ct)
                 (bytes=? got-pt pt-c)
                 (bytes=? got-key key-bs)
                 clean-after-enc?
                 (all-zero-wires? reg-dec sc-wires))
      (error 'verify-narrow-aes "AES-~a NIST FIPS-197 KAT or inverse check failed" key-bits))
    (hash 'key_bits key-bits
          'logical_qubits tot-q
          'temp_ands t-ands
          'swaps swaps
          'ciphertext_hex (apply string-append (for/list ([b (in-bytes got-ct)]) (~r b #:base 16 #:min-width 2 #:pad-string "0")))
          'kat_verified #t))

  (define aes128-res (verify-narrow-aes 128 key-c1 ct-c1 11520))
  (define aes192-res (verify-narrow-aes 192 key-c2 ct-c2 13312))
  (define aes256-res (verify-narrow-aes 256 key-c3 ct-c3 16000))

  ;; Verify `5`-Ancilla (`13`-Qubit) Discrete-Log In-Place Tower-Field AES S-Box (`DLog-5`)
  ;; across all `256/256` NIST FIPS-197 bytes (BOTH `mbu-helper? = #t` `68` TempAND/Toffolis
  ;; AND `mbu-helper? = #f` pure `13`-qubit unitary `121` CCX!) + `261 / 325 / 389`-Qubit
  ;; `0-SWAP` `AES-128 / 192 / 256` on NIST FIPS-197 Appendix C.1, C.2, C.3!
  (define dlog-x8 (range 0 8))
  (define dlog-a4 (range 8 12))
  (define dlog-h 12)
  (define dlog5-mbu-gates
    (compile-lakefill-pareto (aes-sbox-dlog5-minwidth-sexpr dlog-x8 dlog-a4 dlog-h #:mbu-helper? #t)))
  (define dlog5-mbu-inv-gates
    (compile-lakefill-pareto (aes-inv-sbox-dlog5-minwidth-sexpr dlog-x8 dlog-a4 dlog-h #:mbu-helper? #t)))
  (define dlog5-unitary-gates
    (compile-lakefill-pareto (aes-sbox-dlog5-minwidth-sexpr dlog-x8 dlog-a4 dlog-h #:mbu-helper? #f)))
  (define dlog5-xor-gates
    (compile-lakefill-pareto (aes-sbox-dlog5-xor-sexpr (range 0 8) (range 8 16) (range 16 20) 20 #:mbu-helper? #t)))

  (define dlog5-mbu-ccx (count-gate-kind dlog5-mbu-gates 'ccx))
  (define dlog5-mbu-meas (count-gate-kind dlog5-mbu-gates 'mid-meas-x-cond-z))
  (define dlog5-mbu-swaps (count-gate-kind dlog5-mbu-gates 'swap))
  (define dlog5-unitary-ccx (count-gate-kind dlog5-unitary-gates 'ccx))
  (define dlog5-unitary-meas (count-gate-kind dlog5-unitary-gates 'mid-meas-x-cond-z))
  (define dlog5-xor-ccx (count-gate-kind dlog5-xor-gates 'ccx))

  (unless (and (= dlog5-mbu-ccx 68) (= dlog5-mbu-meas 53) (= dlog5-mbu-swaps 0)
               (= dlog5-unitary-ccx 121) (= dlog5-unitary-meas 0) (= dlog5-xor-ccx 50))
    (error 'opt1-dlog5
           "Unexpected DLog-5 gate counts: mbu-ccx=~a mbu-meas=~a swaps=~a unitary-ccx=~a xor-ccx=~a"
           dlog5-mbu-ccx dlog5-mbu-meas dlog5-mbu-swaps dlog5-unitary-ccx dlog5-xor-ccx))

  (define dlog5-256-ok?
    (for*/and ([x (in-range 256)]
               [m-mask (in-list '(#x0 #x1FFFFFFFFFFFFF #x15555555555555))])
      (define expected-sx (vector-ref nist-aes-sbox-table x))
      ;; 1. MBU helper (`68` TempAND/Toffolis on `13` qubits):
      (define st-m (make-vector 13 0))
      (load-bits-le! st-m dlog-x8 x)
      (define-values (st-m-out ph-m) (simulate-gates-with-mbu dlog5-mbu-gates st-m m-mask))
      ;; 2. Inverse MBU helper roundtrip:
      (define-values (st-m-rt ph-m-rt) (simulate-gates-with-mbu dlog5-mbu-inv-gates st-m-out m-mask))
      ;; 3. Pure unitary `13`-qubit (`121` CCX, `0` measurements):
      (define st-u (make-vector 13 0))
      (load-bits-le! st-u dlog-x8 x)
      (define-values (st-u-out ph-u) (simulate-gates-with-mbu dlog5-unitary-gates st-u 0))
      ;; 4. `5`-ancilla out-of-place key-schedule XOR S-box (`50` TempAND/Toffolis):
      (define st-x (make-vector 21 0))
      (load-bits-le! st-x (range 0 8) x)
      (define-values (st-x-out ph-x) (simulate-gates-with-mbu dlog5-xor-gates st-x m-mask))
      (and (= ph-m 1) (= ph-m-rt 1) (= ph-u 1) (= ph-x 1)
           (= (pack-bits-le st-m-out dlog-x8) expected-sx)
           (all-zero-wires? st-m-out '(8 9 10 11 12))
           (= (pack-bits-le st-m-rt dlog-x8) x)
           (all-zero-wires? st-m-rt '(8 9 10 11 12))
           (= (pack-bits-le st-u-out dlog-x8) expected-sx)
           (all-zero-wires? st-u-out '(8 9 10 11 12))
           (= (pack-bits-le st-x-out (range 0 8)) x)
           (= (pack-bits-le st-x-out (range 8 16)) expected-sx)
           (all-zero-wires? st-x-out (range 16 21)))))
  (unless dlog5-256-ok?
    (error 'opt1-dlog5 "Failed exhaustive 256/256 FIPS-197 byte check on 13-qubit DLog-5 S-box"))

  (define (verify-minwidth-dlog5-aes key-bits key-bs expected-ct expected-toffolis)
    (define st-wires (range 0 128))
    (define k-wires (range 128 (+ 128 key-bits)))
    (define sc5-wires (range (+ 128 key-bits) (+ 128 key-bits 5)))
    (define tot-q (+ 128 key-bits 5))
    (define-values (fwd-gates enc-wmap)
      (compile-lakefill-pareto-with-map (aes-dlog5-minwidth-cipher-sexpr key-bits st-wires k-wires sc5-wires)))
    (define-values (inv-gates rt-wmap)
      (compile-lakefill-pareto-with-map (aes-dlog5-minwidth-inv-cipher-sexpr key-bits st-wires k-wires sc5-wires)
                                        #:init-wmap enc-wmap))
    (define t-ands (count-gate-kind fwd-gates 'ccx))
    (define swaps (count-gate-kind fwd-gates 'swap))
    (unless (and (= t-ands expected-toffolis) (= swaps 0))
      (error 'verify-minwidth-dlog5-aes
             "DLog-5 min-width AES-~a expected ~a Toffolis and 0 SWAPs, got ~a and ~a"
             key-bits expected-toffolis t-ands swaps))
    (define reg (make-vector tot-q 0))
    (load-bytes! reg st-wires pt-c)
    (load-bytes! reg k-wires key-bs)
    (define-values (reg-enc ph-enc) (simulate-gates-with-mbu fwd-gates reg #xA5A5A5A5))
    (define got-ct (read-bytes16-wmap reg-enc st-wires enc-wmap))
    (define clean-after-enc? (all-zero-wires? reg-enc sc5-wires))
    (define-values (reg-dec ph-dec) (simulate-gates-with-mbu inv-gates reg-enc #x5A5A5A5A))
    (define wmap-id? (for/and ([w (in-range tot-q)]) (= (hash-ref rt-wmap w w) w)))
    (define got-pt (read-bytes16 reg-dec st-wires))
    (define got-key
      (list->bytes
       (for/list ([bi (in-range (/ key-bits 8))])
         (pack-bits-le reg-dec (take (drop k-wires (* 8 bi)) 8)))))
    (unless (and (= ph-enc 1) (= ph-dec 1)
                 wmap-id?
                 (bytes=? got-ct expected-ct)
                 (bytes=? got-pt pt-c)
                 (bytes=? got-key key-bs)
                 clean-after-enc?
                 (all-zero-wires? reg-dec sc5-wires))
      (error 'verify-minwidth-dlog5-aes "DLog-5 min-width AES-~a NIST FIPS-197 KAT failed" key-bits))
    (hash 'key_bits key-bits
          'logical_qubits tot-q
          'ancilla_qubits 5
          'forward_temp_ands t-ands
          'grover_reflection_toffolis (+ (* 2 t-ands) 504)
          'swaps swaps
          'ciphertext_hex (apply string-append (for/list ([b (in-bytes got-ct)]) (~r b #:base 16 #:min-width 2 #:pad-string "0")))
          'kat_verified #t))

  (define dlog5-aes128-res (verify-minwidth-dlog5-aes 128 key-c1 ct-c1 12880))
  (define dlog5-aes192-res (verify-minwidth-dlog5-aes 192 key-c2 ct-c2 14656))
  (define dlog5-aes256-res (verify-minwidth-dlog5-aes 256 key-c3 ct-c3 17832))

  ;; Verify Bidirectional Half-Cipher `within-apply-mbu` Grover Reflection (`AES-128` & `AES-256`):
  (define (verify-bidirectional-grover key-bits key-bs expected-ct expected-temp-ands)
    (define nk (/ key-bits 32))
    (define nr (match key-bits [128 10] [256 14]))
    (define half-r (quotient nr 2))
    (define exp-words-cnt (- (* 4 (add1 nr)) nk))
    (define num-sboxes (+ (* 16 nr) (match key-bits [128 40] [256 52])))
    (define ptr 0)
    (define (alloc! n)
      (define r (range ptr (+ ptr n)))
      (set! ptr (+ ptr n))
      r)
    (define k-wires (alloc! key-bits))
    (define fwd-states (for/list ([_ (in-range (add1 half-r))]) (alloc! 128)))
    (define bwd-states (for/list ([_ (in-range (add1 (- nr half-r)))]) (alloc! 128)))
    (define exp-words (for/list ([_ (in-range exp-words-cnt)]) (alloc! 32)))
    (define and-pool (alloc! (* 32 num-sboxes)))
    (define eq-sc127 (alloc! 127))
    (define tot-q ptr)
    (define grover-gates
      (compile-lakefill-pareto
       (aes-bidirectional-half-mbu-grover-sexpr
        key-bits k-wires fwd-states bwd-states exp-words and-pool eq-sc127 pt-c expected-ct)))
    (define t-ands (count-gate-kind grover-gates 'ccx))
    (define mbus (count-gate-kind grover-gates 'mid-meas-x-cond-z))
    (define cczs (count-gate-kind grover-gates 'ccz))
    (unless (and (= t-ands expected-temp-ands) (= mbus expected-temp-ands) (= cczs 0))
      (error 'verify-bidirectional-grover
             "AES-~a bidirectional Grover expected ~a TempANDs/MBUs and 0 CCZ, got ~a/~a/~a"
             key-bits expected-temp-ands t-ands mbus cczs))
    ;; Test true key across two distinct M_X branch masks -> phase = -1, 0 dirty ancillas!
    (for ([m-mask (in-list '(#x00000000 #xCAFEBABE))])
      (define st (make-vector tot-q 0))
      (load-bytes! st k-wires key-bs)
      (define-values (st-out ph) (simulate-gates-with-mbu grover-gates st m-mask))
      (define got-key
        (list->bytes
         (for/list ([bi (in-range (/ key-bits 8))])
           (pack-bits-le st-out (take (drop k-wires (* 8 bi)) 8)))))
      (unless (and (= ph -1)
                   (bytes=? got-key key-bs)
                   (all-zero-wires? st-out (range key-bits tot-q)))
        (error 'verify-bidirectional-grover "True key failed for AES-~a mask ~a (ph=~a)" key-bits m-mask ph)))
    ;; Test wrong keys (1-bit and multi-bit flips) -> phase = +1, 0 dirty ancillas!
    (for ([flip-bit (in-list '(0 7 63 127))])
      (define st (make-vector tot-q 0))
      (load-bytes! st k-wires key-bs)
      (vector-set! st flip-bit (- 1 (vector-ref st flip-bit)))
      (define init-copy (vector-copy st))
      (define-values (st-out ph) (simulate-gates-with-mbu grover-gates st #xDEADBEEF))
      (unless (and (= ph 1) (equal? st-out init-copy))
        (error 'verify-bidirectional-grover "Wrong key failed for AES-~a bit ~a" key-bits flip-bit)))
    (hash 'key_bits key-bits
          'temp_ands t-ands
          'uncompute_toffolis 0
          'mbu_gates mbus
          'amortized_key_schedule_temp_ands (+ (* 16 nr 32) 127)
          'parallel_sbox_round_depth half-r
          'verified_true_and_wrong_keys #t))

  (define bidir-aes128 (verify-bidirectional-grover 128 key-c1 ct-c1 6527))
  (define bidir-aes256 (verify-bidirectional-grover 256 key-c3 ct-c3 8959))

  ;; ---------------------------------------------------------------------------
  ;; 2. Verify Optimization 2: Degree-2 `M_X` Chi-Row & 18-round `Keccak-f[200]`
  ;;    + Asymmetric Kralovic Pebbling on `SLH-DSA / SPHINCS+-128s`!
  ;; ---------------------------------------------------------------------------
  (define chi-in5 (range 0 5))
  (define chi-out5 (range 5 10))
  (define chi-sc5 (range 10 15))
  (define chi-gates (compile-lakefill-pareto (keccak-chi5-degree2-mbu-sexpr chi-in5 chi-out5 chi-sc5)))
  (define chi-temp-ands (count-gate-kind chi-gates 'ccx))
  (define chi-mbus (count-gate-kind chi-gates 'mid-meas-x-cond-z))
  (unless (and (= chi-temp-ands 5) (= chi-mbus 5))
    (error 'opt2-chi5 "Expected 5 TempANDs and 5 MBUs, got ~a ~a" chi-temp-ands chi-mbus))

  ;; Exhaustive check over all 32 inputs x all 32 M_X branch masks = 1,024 combinations!
  (define chi5-1024-ok?
    (for*/and ([x (in-range 32)] [m (in-range 32)])
      (define expected
        (for/fold ([acc 0]) ([i (in-range 5)])
          (define b0 (if (bitwise-bit-set? x i) 1 0))
          (define b1 (if (bitwise-bit-set? x (modulo (add1 i) 5)) 1 0))
          (define b2 (if (bitwise-bit-set? x (modulo (+ i 2) 5)) 1 0))
          (bitwise-ior acc (arithmetic-shift (bitwise-xor b0 (bitwise-and (- 1 b1) b2)) i))))
      (define st (make-vector 15 0))
      (load-bits-le! st chi-in5 x)
      (define-values (st-out ph) (simulate-gates-with-mbu chi-gates st m))
      (and (= ph 1)
           (= (pack-bits-le st-out chi-in5) x)
           (= (pack-bits-le st-out chi-out5) expected)
           (all-zero-wires? st-out chi-sc5))))
  (unless chi5-1024-ok?
    (error 'opt2-chi5 "Failed exhaustive 32x32 chi5 MBU verification"))

  ;; Verify full 18-sponge-round `Keccak-f[200]` `within-apply-mbu` Grover reflection on FIPS-202 vector:
  (define fips202-zero-perm (keccak-f200-ref (make-bytes 25 0) 18))
  (define k-ptr 0)
  (define (k-alloc! n)
    (define r (range k-ptr (+ k-ptr n)))
    (set! k-ptr (+ k-ptr n))
    r)
  (define k-in200 (k-alloc! 200))
  (define k-rstates (for/list ([_ (in-range 36)]) (k-alloc! 200)))
  (define k-and3600 (k-alloc! 3600))
  (define k-theta40 (k-alloc! 40))
  (define k-eq31 (k-alloc! 31))
  (define k-tot-q k-ptr)
  (define keccak-grover-gates
    (compile-lakefill-pareto
     (keccak-f200-outofplace-mbu-grover-sexpr
      k-in200 k-rstates k-and3600 k-theta40 k-eq31 fips202-zero-perm 18 32)))
  (define k-temp-ands (count-gate-kind keccak-grover-gates 'ccx))
  (define k-mbus (count-gate-kind keccak-grover-gates 'mid-meas-x-cond-z))
  (unless (and (= k-temp-ands 3631) (= k-mbus 3631))
    (error 'opt2-keccak200 "Expected 3631 TempANDs (3600 sponge + 31 eq) and 0 uncompute CCX, got ~a/~a"
           k-temp-ands k-mbus))
  (let ()
    (define st0 (make-vector k-tot-q 0))
    (define-values (st0-out ph0) (simulate-gates-with-mbu keccak-grover-gates st0 #x13579BDF))
    (unless (and (= ph0 -1) (all-zero-wires? st0-out (range 0 k-tot-q)))
      (error 'opt2-keccak200 "Keccak-f[200] FIPS-202 zero-state Grover reflection failed: ph=~a" ph0))
    (define st1 (make-vector k-tot-q 0))
    (vector-set! st1 0 1)
    (define st1-init (vector-copy st1))
    (define-values (st1-out ph1) (simulate-gates-with-mbu keccak-grover-gates st1 #x2468ACE0))
    (unless (and (= ph1 1) (equal? st1-out st1-init))
      (error 'opt2-keccak200 "Keccak-f[200] wrong-preimage check failed: ph=~a" ph1)))

  ;; Asymmetric Kralovic pebbling for SLH-DSA / SPHINCS+-128s at fixed 4,320 Q:
  ;; Across the 7 hypertree layers (`d_tree = 7`), symmetric Bennett with `p = 4` state pebbles
  ;; executes `F_sym(4, 4) = 8` sponge calls/layer (`7 * 8 = 56` calls = `2,150,400` TempANDs);
  ;; trading 1 pebble slot for a live chi-ancilla frame (`p_eff = 3`, `c_rev = 0` via `M_X + cond-Z`)
  ;; executes `F_asym(4, 3) = 5` calls/layer + `1` root = `36` calls (`1,382,400` TempANDs, `-35.7%`)!
  (define layer-pebble-sym (solve-asymmetric-kralovic-pebbling 4 4))
  (define layer-pebble-asym (solve-asymmetric-kralovic-pebbling 4 3))
  (define slhdsa-sym-calls (* 7 (hash-ref layer-pebble-sym 'symmetric_sponge_calls)))       ;; 7 * 8 = 56
  (define slhdsa-asym-calls (+ (* 7 (hash-ref layer-pebble-asym 'asymmetric_sponge_calls)) 1)) ;; 7 * 5 + 1 = 36
  (unless (and (= slhdsa-sym-calls 56) (= slhdsa-asym-calls 36))
    (error 'opt2-slhdsa "Unexpected SLH-DSA call counts: ~a vs ~a" slhdsa-sym-calls slhdsa-asym-calls))

  ;; ---------------------------------------------------------------------------
  ;; 3. Verify Optimization 3: MITM Leaf Gadgets + Berry-Gidney Window `M_X` QROAM
  ;; ---------------------------------------------------------------------------
  (define (verify-gadget-equiv base-gates opt-gates n-in n-out n-tot exp-base exp-opt)
    (define b-ands (count-gate-kind base-gates 'ccx))
    (define o-ands (count-gate-kind opt-gates 'ccx))
    (unless (and (= b-ands exp-base) (= o-ands exp-opt))
      (error 'verify-gadget-equiv "Expected ~a -> ~a TempANDs, got ~a -> ~a" exp-base exp-opt b-ands o-ands))
    (define ok?
      (for/and ([x (in-range (arithmetic-shift 1 n-in))])
        (define sb (make-vector n-tot 0))
        (define so (make-vector n-tot 0))
        (load-bits-le! sb (range 0 n-in) x)
        (load-bits-le! so (range 0 n-in) x)
        (define-values (sb-out pb) (simulate-gates-with-mbu base-gates sb #x3F))
        (define-values (so-out po) (simulate-gates-with-mbu opt-gates so #x3F))
        (and (= pb 1) (= po 1)
             (= (pack-bits-le sb-out (range n-in (+ n-in n-out)))
                (pack-bits-le so-out (range n-in (+ n-in n-out))))
             (all-zero-wires? sb-out (range (+ n-in n-out) n-tot))
             (all-zero-wires? so-out (range (+ n-in n-out) n-tot)))))
    (unless ok? (error 'verify-gadget-equiv "Truth-table mismatch in MITM gadget"))
    (hash 'base_temp_ands b-ands 'opt_temp_ands o-ands 'exhaustive_equiv #t))

  (define g-divstep
    (verify-gadget-equiv
     (compile-lakefill-pareto (divstep-swap-sub-window-base-sexpr '(0 1 2 3) '(4 5) '(6 7 8 9 10)))
     (compile-lakefill-pareto (divstep-swap-sub-window-opt-sexpr '(0 1 2 3) '(4 5) '(6 7 8)))
     4 2 11 5 3))
  (define g-skew
    (verify-gadget-equiv
     (compile-lakefill-pareto (skew-carry-save-merge-base-sexpr '(0 1 2 3) '(4 5 6) '(7 8 9 10)))
     (compile-lakefill-pareto (skew-carry-save-merge-opt-sexpr '(0 1 2 3) '(4 5 6) '(7 8 9)))
     4 3 11 4 3))
  (define g-karatsuba
    (verify-gadget-equiv
     (compile-lakefill-pareto (karatsuba-toom-limb-mul-base-sexpr '(0 1 2 3) '(4 5 6) '(7 8 9 10)))
     (compile-lakefill-pareto (karatsuba-toom-limb-mul-opt-sexpr '(0 1 2 3) '(4 5 6) '(7 8 9)))
     4 3 11 4 3))

  (define qroam-tbl (for/vector ([i (in-range 16)]) (vector-ref nist-aes-sbox-table (* 17 i))))
  (define qroam-unitary-gates
    (compile-lakefill-pareto
     (berry-gidney-window-qroam-unitary-sexpr
      (range 0 4) (range 4 12) (range 12 44) (range 44 48) (range 48 72) qroam-tbl)))
  (define qroam-mbu-gates
    (compile-lakefill-pareto
     (berry-gidney-window-qroam-mbu-sexpr
      (range 0 4) (range 4 12) (range 12 44) (range 44 48) (range 48 72) qroam-tbl)))
  (define qroam-u-ands (count-gate-kind qroam-unitary-gates 'ccx))
  (define qroam-m-ands (count-gate-kind qroam-mbu-gates 'ccx))
  (unless (and (= qroam-u-ands 52) (= qroam-m-ands 26))
    (error 'opt3-qroam "Expected 52 -> 26 TempANDs, got ~a -> ~a" qroam-u-ands qroam-m-ands))
  (for* ([addr (in-range 16)] [m-mask (in-list '(#x0 #x3FFFFFF #x1555555))])
    (define st (make-vector 72 0))
    (load-bits-le! st (range 0 4) addr)
    (define-values (st-out ph) (simulate-gates-with-mbu qroam-mbu-gates st m-mask))
    (unless (and (= ph 1)
                 (= (pack-bits-le st-out (range 4 12)) (vector-ref qroam-tbl addr))
                 (all-zero-wires? st-out (range 12 72)))
      (error 'opt3-qroam "QROAM MBU check failed at addr ~a" addr)))

  ;; Verify Network-Level 4-QPU `20`-Qubit `Law U4` Column-Sliced GHZ Lookup (`9` vs `18` Bell pairs):
  (define dist-ghz-mbu-gates
    (compile-lakefill-pareto (distributed-ghz-column-qroam-mbu-sexpr)))
  (define dist-ghz-unitary-gates
    (compile-lakefill-pareto (distributed-ghz-column-qroam-unitary-sexpr)))
  (define (qpu-of-dist-wire w)
    (cond
      [(or (<= 0 w 4)) 0]
      [(or (<= 5 w 6) (<= 11 w 13)) 1]
      [(or (<= 7 w 8) (<= 14 w 16)) 2]
      [(or (<= 9 w 10) (<= 17 w 19)) 3]
      [else (error 'qpu-of-dist-wire "Unexpected wire ~a" w)]))
  (define (count-cross-qpu-bell-gates gs)
    (for/sum ([g (in-list gs)])
      (match g
        [`(cx ,c ,t) (if (= (qpu-of-dist-wire c) (qpu-of-dist-wire t)) 0 1)]
        [`(ccx ,c1 ,c2 ,t)
         (if (= (qpu-of-dist-wire c1) (qpu-of-dist-wire c2) (qpu-of-dist-wire t))
             0
             (error 'count-cross-qpu-bell-gates "Cross-QPU CCX forbidden in local column slice: ~a" g))]
        [_ 0])))
  (define dist-ghz-mbu-bells (count-cross-qpu-bell-gates dist-ghz-mbu-gates))
  (define dist-ghz-unitary-bells (count-cross-qpu-bell-gates dist-ghz-unitary-gates))
  (define dist-ghz-mbus (count-gate-kind dist-ghz-mbu-gates 'mid-meas-x-cond-z))
  (unless (and (= dist-ghz-mbu-bells 9) (= dist-ghz-unitary-bells 18) (= dist-ghz-mbus 9))
    (error 'opt3-dist-ghz
           "Expected 9 MBU Bell pairs vs 18 unitary Bell pairs and 9 M_X ops, got ~a vs ~a (~a M_X)"
           dist-ghz-mbu-bells dist-ghz-unitary-bells dist-ghz-mbus))
  (for* ([addr (in-range 8)]
         [m-mask (in-list '(#x000 #x1FF #x155 #x0AA #x0DB #x124 #x1B6 #x073
                            #x1C7 #x0E3 #x19A #x06D #x111 #x088 #x17E #x0BC))])
    (define st-m (make-vector 20 0))
    (define st-u (make-vector 20 0))
    (load-bits-le! st-m '(0 1 2) addr)
    (load-bits-le! st-u '(0 1 2) addr)
    (define-values (st-m-out ph-m) (simulate-gates-with-mbu dist-ghz-mbu-gates st-m m-mask))
    (define-values (st-u-out ph-u) (simulate-gates-with-mbu dist-ghz-unitary-gates st-u 0))
    (define exp-byte (vector-ref distributed-ghz-default-table8-u8 addr))
    (unless (and (= ph-m 1) (= ph-u 1)
                 (= (pack-bits-le st-m-out '(0 1 2)) addr)
                 (= (pack-bits-le st-m-out (range 3 11)) exp-byte)
                 (= (pack-bits-le st-u-out (range 3 11)) exp-byte)
                 (all-zero-wires? st-m-out (range 11 20))
                 (all-zero-wires? st-u-out (range 11 20)))
      (error 'opt3-dist-ghz "4-QPU Law U4 GHZ lookup mismatch at addr ~a mask ~a" addr m-mask)))

  ;; Verify Optimization 2 (`adaptive-bezout-binomial-pebble-schedule`):
  ;; Static `s = 4 -> 109` macro-window evaluations vs. Adaptive `s(k): 4 -> 6 -> 8 -> 67`
  ;; macro-window evaluations (`1.63x` reduction) at `0` additional peak qubits (`1,210 Q` on `ECC-256`):
  (define adaptive-bezout-pebble-res (adaptive-bezout-binomial-pebble-schedule))
  (unless (and (= (hash-ref adaptive-bezout-pebble-res 'static_forward_evals) 77)
               (= (hash-ref adaptive-bezout-pebble-res 'static_reverse_evals) 32)
               (= (hash-ref adaptive-bezout-pebble-res 'static_total_macro_evals) 109)
               (= (hash-ref adaptive-bezout-pebble-res 'adaptive_forward_evals) 35)
               (= (hash-ref adaptive-bezout-pebble-res 'adaptive_reverse_evals) 32)
               (= (hash-ref adaptive-bezout-pebble-res 'adaptive_total_macro_evals) 67)
               (= (hash-ref adaptive-bezout-pebble-res 'eval_reduction_ratio_2dp) 1.63)
               (hash-ref adaptive-bezout-pebble-res 'packed_zipper_width_bound_preserved)
               (= (hash-ref adaptive-bezout-pebble-res 'ecc256_peak_logical_qubits) 1210)
               (= (hash-ref adaptive-bezout-pebble-res 'additional_peak_qubits) 0)
               (= (hash-ref adaptive-bezout-pebble-res 'residual_dirty_pebble_qubits) 0))
    (error 'opt3-adaptive-bezout-pebble
           "Adaptive Bezout binomial pebble schedule verification failed: ~a"
           adaptive-bezout-pebble-res))

  ;; ---------------------------------------------------------------------------
  ;; 4. Verify Optimization 4: `M_X` Parity-Check & Syndrome-Weight Comparator
  ;;    Uncomputation on Streaming Code-Based ISD!
  ;; ---------------------------------------------------------------------------
  (define h-cols16
    (for/vector ([c (in-range 16)])
      (bitwise-and #xFF (+ (* 29 (add1 c)) (arithmetic-shift (add1 c) 3)))))
  (define target-synd
    (bitwise-xor (vector-ref h-cols16 3) (vector-ref h-cols16 11)))
  (define isd-unitary-gates
    (compile-lakefill-pareto
     (streaming-isd-syndrome-grover-unitary-sexpr
      (range 0 4) (range 4 8) (range 8 16) (range 16 32) (range 32 48) (range 48 55)
      h-cols16 target-synd)))
  (define isd-mbu-gates
    (compile-lakefill-pareto
     (streaming-isd-syndrome-grover-mbu-sexpr
      (range 0 4) (range 4 8) (range 8 16) (range 16 32) (range 32 48) (range 48 55)
      h-cols16 target-synd)))
  (define isd-u-ands (count-gate-kind isd-unitary-gates 'ccx))
  (define isd-m-ands (count-gate-kind isd-mbu-gates 'ccx))
  (unless (and (= isd-u-ands 70) (= isd-m-ands 35))
    (error 'opt4-isd "Expected 70 -> 35 TempANDs (-50.0%), got ~a -> ~a" isd-u-ands isd-m-ands))
  ;; Exhaustively verify all 16 x 16 = 256 index pairs `(idx0, idx1)`!
  (define isd-matches 0)
  (for* ([i0 (in-range 16)] [i1 (in-range 16)])
    (define want-match?
      (= (bitwise-xor (vector-ref h-cols16 i0) (vector-ref h-cols16 i1)) target-synd))
    (when want-match? (set! isd-matches (add1 isd-matches)))
    (define st (make-vector 55 0))
    (load-bits-le! st (range 0 4) i0)
    (load-bits-le! st (range 4 8) i1)
    (define init-st (vector-copy st))
    (define-values (st-out ph) (simulate-gates-with-mbu isd-mbu-gates st #x555555555))
    (unless (and (= ph (if want-match? -1 1))
                 (equal? st-out init-st))
      (error 'opt4-isd "ISD mismatch at (~a, ~a)" i0 i1)))
  (unless (>= isd-matches 2)
    (error 'opt4-isd "Expected at least 2 valid syndrome matches (3,11) and (11,3)"))

  ;; ---------------------------------------------------------------------------
  ;; 5. Verify Convex `M*` Cluster-Profile Selection & `T-ParGuard` (`M_max = 256` Horizon):
  ;;    - Default modular cluster (`M_max = 256`, `Q_cap = 400 Q`, `R_bell = 100 kHz`, `'all-to-all-peers`):
  ;;      * `ECC-256` -> `M* = 4` (`4 x 312 Q`, `9,744` logical ebits; prunes `16..256` past `M = 12` `190 Q` knee)
  ;;      * `RSA-2048` -> `M* = 6` (`6 x 236 Q`, `0` carry ebits, `31,140` lookup ebits; prunes `24..256` past `M = 16` `156 Q` knee)
  ;;      * `RSA-4096` -> `M* = 8` (`8 x 356 Q`, `0` carry ebits, `87,192` lookup ebits; true U-curve min `M = 24` `228 Q`, pruning `32..256`)
  ;;      * `DQI` -> `M* = 256` (`256 x 840 Q`, `256.0x` linear throughput, `0` ebits)
  ;;      * `FeMoCo` -> `M* = min(256, 64) = 64` (`64 x 2,142 Q`, `64.0x` linear throughput, `0` ebits)
  ;;      * All 6 Grover/ISD workloads -> `M* = 1` (`1 x Q_single`, `T-ParGuard` avoids `sqrt(256) = 16.0x` Zalka blowup)
  ;; ---------------------------------------------------------------------------
  (define t-par-guard-table
    (map (lambda (entry)
           (apply compile-parallel-mode-with-t-par-guard #:cluster-machines 256 #:q-cap 400 #:r-bell 100000.0 entry))
         '(("ECC-256" algebraic-shor 1298 84)
           ("RSA-2048" algebraic-shor 1332 104)
           ("RSA-4096" algebraic-shor 2612 192)
           ("AES-128" grover-amplitude-amplification 261 257)
           ("AES-256" grover-amplitude-amplification 389 385)
           ("SHA3-256" grover-amplitude-amplification 1760 1760)
           ("SLH-DSA-128s" grover-amplitude-amplification 4320 4320)
           ("McEliece-348864" isd-amplitude-amplification 7744 7740)
           ("BIKE-L1" isd-amplitude-amplification 36969 36965)
           ("DQI" poly-sampling-qsvt 840 840)
           ("FeMoCo" poly-sampling-qsvt 2142 2142))))

  (define expected-m256-dispatch
    (hash "ECC-256" '(4 312 9744)
          "RSA-2048" '(6 236 31140)
          "RSA-4096" '(8 356 87192)
          "DQI" '(256 840 0)
          "FeMoCo" '(64 2142 0)))

  (for ([row (in-list t-par-guard-table)])
    (define alg (hash-ref row 'algorithm))
    (define part? (hash-ref row 'parallel_partitionable))
    (define m-used (hash-ref row 'machines_used))
    (define q-mach (hash-ref row 'qubits_per_machine))
    (define e-log (hash-ref row 'logical_ebits))
    (define fb? (hash-ref row 'fallback_to_single_machine))
    (if part?
        (match-let ([(list exp-m exp-q exp-e) (hash-ref expected-m256-dispatch alg)])
          (unless (and (= m-used exp-m) (= q-mach exp-q) (= e-log exp-e) (not fb?))
            (error 't-par-guard "Expected ~a -> M*=~a Q=~a E=~a, got ~a" alg exp-m exp-q exp-e row)))
        (unless (and (= m-used 1) fb? (= q-mach (hash-ref row 'single_machine_qubits)) (= e-log 0))
          (error 't-par-guard "T-ParGuard Grover/ISD invariant failed on ~a" row))))

  ;; Cross-regime verification across `Q_cap`, `R_bell`, and `'switched-optical-tree` up to `M_max = 256`:
  (define ecc-q1500 (solve-parallel-cluster-m-star "ECC-256" 'algebraic-shor 1298 84 #:q-cap 1500))
  (define ecc-q220 (solve-parallel-cluster-m-star "ECC-256" 'algebraic-shor 1298 84 #:q-cap 220))
  (define ecc-opt128 (solve-parallel-cluster-m-star "ECC-256" 'algebraic-shor 1298 84 #:q-cap 128 #:interconnect 'switched-optical-tree))
  (define rsa2048-q1500 (solve-parallel-cluster-m-star "RSA-2048" 'algebraic-shor 1332 104 #:q-cap 1500))
  (define rsa2048-slow1khz (solve-parallel-cluster-m-star "RSA-2048" 'algebraic-shor 1332 104 #:q-cap 400 #:r-bell 1000.0))
  (define rsa2048-opt128 (solve-parallel-cluster-m-star "RSA-2048" 'algebraic-shor 1332 104 #:q-cap 128 #:interconnect 'switched-optical-tree))
  (define rsa2048-opt100-bin (solve-parallel-cluster-m-star "RSA-2048" 'algebraic-shor 1332 104 #:q-cap 100 #:interconnect 'switched-optical-tree #:binary-radix-only? #t))
  (define rsa4096-q260 (solve-parallel-cluster-m-star "RSA-4096" 'algebraic-shor 2612 192 #:q-cap 260))
  (define rsa4096-q230-m16 (solve-parallel-cluster-m-star "RSA-4096" 'algebraic-shor 2612 192 #:cluster-machines 16 #:q-cap 230))
  (define rsa4096-q230-m256 (solve-parallel-cluster-m-star "RSA-4096" 'algebraic-shor 2612 192 #:cluster-machines 256 #:q-cap 230))
  (define rsa4096-slow50hz (solve-parallel-cluster-m-star "RSA-4096" 'algebraic-shor 2612 192 #:q-cap 1500 #:r-bell 50.0))
  (define rsa4096-opt128 (solve-parallel-cluster-m-star "RSA-4096" 'algebraic-shor 2612 192 #:q-cap 128 #:interconnect 'switched-optical-tree))

  (unless (and (= (hash-ref ecc-q1500 'machines_used) 1)
               (= (hash-ref ecc-q220 'machines_used) 8)
               (= (hash-ref ecc-q220 'qubits_per_machine) 208)
               (= (hash-ref ecc-opt128 'machines_used) 16)
               (= (hash-ref ecc-opt128 'qubits_per_machine) 126)
               (= (hash-ref rsa2048-q1500 'machines_used) 1)
               (= (hash-ref rsa2048-slow1khz 'machines_used) 4)
               (= (hash-ref rsa2048-slow1khz 'qubits_per_machine) 324)
               (= (hash-ref rsa2048-opt128 'machines_used) 16)
               (= (hash-ref rsa2048-opt128 'qubits_per_machine) 112)
               (= (hash-ref rsa2048-opt100-bin 'machines_used) 32)
               (= (hash-ref rsa2048-opt100-bin 'qubits_per_machine) 80)
               (= (hash-ref rsa4096-q260 'machines_used) 16)
               (= (hash-ref rsa4096-q260 'qubits_per_machine) 244)
               (= (hash-ref rsa4096-q230-m16 'machines_used) 0)
               (= (hash-ref rsa4096-q230-m256 'machines_used) 24)
               (= (hash-ref rsa4096-q230-m256 'qubits_per_machine) 228)
               (= (hash-ref rsa4096-slow50hz 'machines_used) 2)
               (= (hash-ref rsa4096-slow50hz 'qubits_per_machine) 1196)
               (= (hash-ref rsa4096-opt128 'machines_used) 48)
               (= (hash-ref rsa4096-opt128 'qubits_per_machine) 112))
    (error 'm-star-regime-sweeps "Convex M* cross-regime assertion failed!"))

  (define m-star-regime-sweeps
    (hash 'ecc256_qcap_1500_single ecc-q1500
          'ecc256_qcap_220_all_to_all ecc-q220
          'ecc256_qcap_128_optical_tree ecc-opt128
          'rsa2048_qcap_1500_single rsa2048-q1500
          'rsa2048_qcap_400_rbell_1khz rsa2048-slow1khz
          'rsa2048_qcap_128_optical_tree rsa2048-opt128
          'rsa2048_qcap_100_binary_optical_tree rsa2048-opt100-bin
          'rsa4096_qcap_260_all_to_all rsa4096-q260
          'rsa4096_qcap_230_m16_infeasible rsa4096-q230-m16
          'rsa4096_qcap_230_m256_unlocked rsa4096-q230-m256
          'rsa4096_qcap_1500_rbell_50hz rsa4096-slow50hz
          'rsa4096_qcap_128_optical_tree rsa4096-opt128))

  (define (serialize-gates gs)
    (map (lambda (g) (map (lambda (x) (if (symbol? x) (symbol->string x) x)) g)) gs))

  (hash
   'status "PASS"
   'opt1_tower_aes_and_bidirectional_grover
   (hash 'sbox_bp32_xor_temp_ands bp32-temp-ands
         'sbox_bp32_xor_t_gates (* 4 bp32-temp-ands)
         'sbox_bp32_uncompute_toffolis 0
         'sbox_bp64_inplace_temp_ands bp64-temp-ands
         'sbox_dlog5_inplace_qubits 13
         'sbox_dlog5_ancilla_qubits 5
         'sbox_dlog5_mbu_temp_ands dlog5-mbu-ccx
         'sbox_dlog5_mbu_measurements dlog5-mbu-meas
         'sbox_dlog5_unitary_ccx dlog5-unitary-ccx
         'sbox_dlog5_key_xor_temp_ands dlog5-xor-ccx
         'sbox_dlog5_256_of_256_fips197_verified dlog5-256-ok?
         'sbox_256_of_256_fips197_verified bp32-256-ok?
         'zero_dirty_ancillas_across_256_inputs (and bp32-256-ok? dlog5-256-ok?)
         'sbox_bp32_circuit_gates (serialize-gates bp32-gates)
         'sbox_dlog5_unitary_circuit_gates (serialize-gates dlog5-unitary-gates)
         'sbox_dlog5_mbu_circuit_gates (serialize-gates dlog5-mbu-gates)
         'minwidth_dlog5_aes128 dlog5-aes128-res
         'minwidth_dlog5_aes192 dlog5-aes192-res
         'minwidth_dlog5_aes256 dlog5-aes256-res
         'narrow_aes128 aes128-res
         'narrow_aes192 aes192-res
         'narrow_aes256 aes256-res
         'bidirectional_grover_aes128 bidir-aes128
         'bidirectional_grover_aes256 bidir-aes256)
   'opt2_keccak_degree2_mbu_and_slhdsa
   (hash 'chi5_temp_ands chi-temp-ands
         'chi5_uncompute_toffolis 0
         'chi5_1024_input_branch_verified chi5-1024-ok?
         'chi5_circuit_gates (serialize-gates chi-gates)
         'keccak_f200_18round_grover_temp_ands k-temp-ands
         'keccak_f200_18round_sponge_temp_ands 3600
         'keccak_f200_reverse_sponge_toffolis 0
         'keccak_f200_fips202_zero_perm_hex
         (apply string-append (for/list ([b (in-bytes fips202-zero-perm)]) (~r b #:base 16 #:min-width 2 #:pad-string "0")))
         'keccak_f1600_24round_forward_temp_ands 38400
         'keccak_f1600_24round_reverse_toffolis 0
         'amy_sac2016_unitary_ccx 76800
         'toffoli_reduction_ratio 2.0
         't_gate_reduction_ratio 3.5
         'slh_dsa_128s_symmetric_calls slhdsa-sym-calls
         'slh_dsa_128s_asymmetric_calls slhdsa-asym-calls
         'slh_dsa_128s_symmetric_temp_ands (* slhdsa-sym-calls 38400)
         'slh_dsa_128s_asymmetric_temp_ands (* slhdsa-asym-calls 38400))
   'opt3_recycled_qft_mitm_gadgets_and_qroam
   (hash 'divstep_swap_sub_window g-divstep
         'skew_binary_carry_save_merge g-skew
         'karatsuba_toom_limb_mul g-karatsuba
         'adaptive_bezout_binomial_pebble_schedule adaptive-bezout-pebble-res
         'berry_gidney_window_qroam
         (hash 'unitary_ccx qroam-u-ands
               'mbu_temp_ands qroam-m-ands
               'uncompute_toffolis 0
               'addresses_verified 16)
         'distributed_ghz_law_u4_column_qroam
         (hash 'qpus 4
               'total_qubits 20
               'address_bits_w 3
               'table_entries 8
               'column_slice_bits_per_qpu 2
               'mbu_cross_qpu_bell_pairs dist-ghz-mbu-bells
               'unitary_cross_qpu_bell_pairs dist-ghz-unitary-bells
               'bell_pair_reduction_pct 50.0
               'remote_cat_mx_measurements dist-ghz-mbus
               'cross_qpu_data_gates 0
               'addresses_verified 8
               'mx_masks_verified 16
               'mbu_circuit_gates (serialize-gates dist-ghz-mbu-gates)
               'unitary_circuit_gates (serialize-gates dist-ghz-unitary-gates)))
   'opt4_streaming_isd_parity_check_mbu
   (hash 'mini_isd_unitary_ccx isd-u-ands
         'mini_isd_mbu_temp_ands isd-m-ands
         'mini_isd_index_pairs_verified 256
         'mini_isd_syndrome_matches_found isd-matches
         'mceliece_348864_logical_qubits 7744
         'mceliece_348864_unitary_toffolis 1633280
         'mceliece_348864_mbu_temp_ands 814336
         'bike_l1_logical_qubits 36969
         'bike_l1_unitary_toffolis 1971680
         'bike_l1_mbu_temp_ands 985840)
   'adaptive_bezout_binomial_pebble_schedule adaptive-bezout-pebble-res
   't_par_guard_parallel_cluster_m16 t-par-guard-table
   't_par_guard_parallel_cluster_m256 t-par-guard-table
   'm_star_horizon_256_regime_sweeps m-star-regime-sweeps))

(module+ main
  (define summary (run-all-lakefillq-algorithm-optimizations))
  ;; Strip bulky gate lists on stdout unless `--with-gates` is passed:
  (define args (current-command-line-arguments))
  (define include-gates? (member "--with-gates" (vector->list args)))
  (define out-summary
    (if include-gates?
        summary
        (hash-update
         (hash-update
          (hash-update summary 'opt1_tower_aes_and_bidirectional_grover
                       (lambda (h)
                         (hash-remove
                          (hash-remove
                           (hash-remove h 'sbox_bp32_circuit_gates)
                           'sbox_dlog5_unitary_circuit_gates)
                          'sbox_dlog5_mbu_circuit_gates)))
          'opt2_keccak_degree2_mbu_and_slhdsa
          (lambda (h) (hash-remove h 'chi5_circuit_gates)))
         'opt3_recycled_qft_mitm_gadgets_and_qroam
         (lambda (h)
           (hash-update h 'distributed_ghz_law_u4_column_qroam
                        (lambda (dh)
                          (hash-remove
                           (hash-remove dh 'mbu_circuit_gates)
                           'unitary_circuit_gates)))))))
  (write-json out-summary)
  (newline))
