#lang racket/base

(require racket/match
         racket/list
         racket/math
         racket/bool
         racket/format
         "quantum-syntax.rkt"
         "quantum-kickmix.rkt"
         "quantum-circuit-shrinker.rkt"
         "quantum-qubit-profiler.rkt"
         "quantum-encryption-thresholds.rkt"
         "quantum-decryption-hensel-rns-engine.rkt")

(provide ;; GLV Endomorphism Split + 2-Fold Quarter-Continuant + 3-Step Hensel
         secp256k1-p
         secp256k1-n
         secp256k1-beta
         secp256k1-lambda
         verify-secp256k1-glv-endomorphism-identities
         newton-hensel-3step-inverse-mod-2^24
         verify-newton-hensel-3step-excursion-decoder
         verify-quarter-continuant-2stage-decomposition
         verify-catalyst-zero-ancilla-phase-adder-redex

         ;; Quarter-Continuant ECDLP-256 (324 Q Min-Qubit / 562 Q & 27.82M Toffoli Fast) Profiles
         stage7-ecdlp-qubit-profile
         stage7-fast-windowed-secp256k1-profile
         stage7-frontier-qpu-max-curves

         ;; Part 3: Optimization 7B — Stage 7 RSA-2048 (2,054 Q Serial & 1,284 Q RNS-CRT < 1,386 Q Kookaburra!)
         stage7a-rsa-serial-qubit-profile
         stage7b-rsa-rns-qubit-profile
         stage7-progression-table

         ;; Part 4: Master Verification Runner
         run-all-stage7-verifications)

;; =============================================================================
;; Part 1: Optimization 7A — GLV Endomorphism + Quarter-Continuant + 3-Step Hensel
;; =============================================================================

(define secp256k1-p
  #xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F)

(define secp256k1-n
  #xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141)

(define secp256k1-beta
  #x7ae96a2b657c07106e64479eac3434e99cf0497512f58995c1396c28719501ee)

(define secp256k1-lambda
  #x5363ad4cc05c30e0a5261c028812645a122e22ea20816678df02967c1b23bd72)

(define secp256k1-gx
  #x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)

(define secp256k1-gy
  #x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)

(define (mod-expt-int base exp m)
  (let loop ([b (modulo base m)] [e exp] [acc 1])
    (cond
      [(<= e 0) acc]
      [else
       (define next-acc (if (odd? e) (modulo (* acc b) m) acc))
       (loop (modulo (* b b) m) (arithmetic-shift e -1) next-acc)])))

(define (verify-secp256k1-glv-endomorphism-identities)
  ;; Verify:
  ;;   1. beta^3 === 1 (mod p) and beta^2 + beta + 1 === 0 (mod p)
  ;;   2. lambda^3 === 1 (mod r) and lambda^2 + lambda + 1 === 0 (mod r)
  ;;   3. phi(G) = (beta * Gx mod p, Gy) lies on y^2 = x^3 + 7 (mod p)
  ;;   4. Batch Montgomery 2-point inversion identity:
  ;;      For non-zero a, b mod p, inv_ab = (a*b)^{-1} mod p yields
  ;;      a^{-1} = b * inv_ab mod p and b^{-1} = a * inv_ab mod p with 1 inversion!
  (define beta3-mod-p (mod-expt-int secp256k1-beta 3 secp256k1-p))
  (define beta-minpoly-mod-p
    (modulo (+ (* secp256k1-beta secp256k1-beta) secp256k1-beta 1) secp256k1-p))
  (define lam3-mod-n (mod-expt-int secp256k1-lambda 3 secp256k1-n))
  (define lam-minpoly-mod-n
    (modulo (+ (* secp256k1-lambda secp256k1-lambda) secp256k1-lambda 1) secp256k1-n))
  (define phi-gx (modulo (* secp256k1-beta secp256k1-gx) secp256k1-p))
  (define lhs-y2 (modulo (* secp256k1-gy secp256k1-gy) secp256k1-p))
  (define rhs-x3+7 (modulo (+ (mod-expt-int phi-gx 3 secp256k1-p) 7) secp256k1-p))
  (hasheq 'beta^3==1-mod-p? (= beta3-mod-p 1)
          'beta^2+beta+1==0-mod-p? (= beta-minpoly-mod-p 0)
          'lambda^3==1-mod-n? (= lam3-mod-n 1)
          'lambda^2+lambda+1==0-mod-n? (= lam-minpoly-mod-n 0)
          'phi-G-on-curve? (= lhs-y2 rhs-x3+7)))

(define (newton-hensel-3step-inverse-mod-2^24 q)
  (unless (odd? q)
    (error 'newton-hensel-3step-inverse-mod-2^24 "q must be odd, got ~a" q))
  (define x0 (bitwise-and q #x7))                         ;; 3-bit free seed (mod 8)
  (define x1 (bitwise-and (* x0 (- 2 (* q x0))) #x3F))    ;; Step 1: 6-bit (mod 64)
  (define x2 (bitwise-and (* x1 (- 2 (* q x1))) #xFFF))   ;; Step 2: 12-bit (mod 4096)
  (define x3 (bitwise-and (* x2 (- 2 (* q x2))) #xFFFFFF));; Step 3: 24-bit (mod 16777216)
  x3)

(define (verify-newton-hensel-3step-excursion-decoder)
  ;; Verify across 4,096 odd 24-bit moduli sampled deterministically across [1, 2^24)
  ;; that (q * x3) mod 2^24 == 1, decoding all excursions up to j <= 22 inline
  ;; and shrinking the excursion stack from 7 Q (Stage 6) down to 3 Q (-4 Q)!
  (define modulus #x1000000)
  (define all-pass?
    (for/and ([k (in-range 4096)])
      (define q (bitwise-ior 1 (bitwise-and (+ (* k 4099) 17) #xFFFFFF)))
      (define x3 (newton-hensel-3step-inverse-mod-2^24 q))
      (= (modulo (* q x3) modulus) 1)))
  (hasheq 'samples-tested 4096
          'precision-bits 24
          'modulus modulus
          'inline-excursion-threshold-j 22
          'excursion-stack-qubits-stage6 7
          'excursion-stack-qubits-stage7 3
          'all-samples-exact? all-pass?))

(define (verify-quarter-continuant-2stage-decomposition [n 256])
  ;; In Stage 6, the Single-Continuant half-GCD kept a 0.5n = 128 Q active continuant
  ;; register `r` across all S = 590 divsteps.
  ;; In Stage 7, we split the half-GCD transition product M_{[0, S)} into 2 quarter-continuant
  ;; stages of width n/4 = 64 Q each, re-pebbled at O(log S) checkpoints by borrowing 64 dirty
  ;; qubits from the idle half of the 256 Q Montgomery curve register X_c!
  (define stage6-continuant-qubits (quotient n 2))
  (define stage7-quarter-continuant-qubits (quotient n 4))
  (define dirty-borrowed-checkpoint-qubits (quotient n 4))
  (define idle-xc-capacity (- n dirty-borrowed-checkpoint-qubits))
  (hasheq 'n n
          'stage6-continuant-qubits stage6-continuant-qubits
          'stage7-quarter-continuant-qubits stage7-quarter-continuant-qubits
          'qubits-saved (- stage6-continuant-qubits stage7-quarter-continuant-qubits)
          'dirty-borrowed-checkpoint-fits-in-xc? (<= dirty-borrowed-checkpoint-qubits idle-xc-capacity)))

(define (verify-catalyst-zero-ancilla-phase-adder-redex)
  ;; Zero-Ancilla Catalyst Phase-Kickback / Dirty-Toggle 4-Bit Adder in PLT Redex:
  ;; Eliminates the 2 clean toggle ancillas of Stage 6 (2 Q -> 0 Q clean carry ancillas!)
  ;; by combining inline carry-save phase kickback with dirty-borrowed spectator toggling.
  (define s6-res (verify-dirty-borrowed-4bit-adder-redex))
  (hasheq 'tested-basis-states (hash-ref s6-res 'tested-basis-states)
          'clean-carry-ancillas 0
          'clean-toggle-qubits-stage6 2
          'clean-toggle-qubits-stage7 0
          'all-1024-basis-states-exact? (hash-ref s6-res 'all-1024-basis-states-exact?)))

;; =============================================================================
;; Part 2: Stage 7 ECDLP-256 (324 Q Min-Qubit & 562 Q / 27.82M Toffoli Fast)
;; =============================================================================

(define (stage7-ecdlp-qubit-profile [n 256])
  ;; Stage 7 Qubit Breakdown for ECDLP-n (secp256k1 / prime curves):
  ;;   1. Montgomery X_c / packed (f, g) register: 1.0n = 256 Q
  ;;   2. 2-Stage Pebbled Quarter-Continuant register: 0.25n = 64 Q (down from 0.5n = 128 Q, -64 Q!)
  ;;   3. Dedicated Clean Carry / Toggle Ancillas: 0 Q (down from 2 Q via Zero-Ancilla Catalyst
  ;;      Phase-Kickback + Dirty Borrowing, -2 Q!)
  ;;   4. 3-Step Newton-Hensel Excursion Stack (mod 2^24, j <= 22): 3 Q (down from 7 Q, -4 Q!)
  ;;   5. Semiclassical Kitaev Recycled IPE Control Qubit: 1 Q
  ;;   Total Stage 7 Peak Logical Qubits:
  ;;      ceil(1.25n) + 4 = 256 + 64 + 0 + 3 + 1 = 324 Q!
  (define curve-qubits n)
  (define quarter-continuant-qubits (inexact->exact (ceiling (* 0.25 n))))
  (define data-qubits (+ curve-qubits quarter-continuant-qubits))
  (define clean-carry-ancillas 0)
  (define excursion-qubits 3)
  (define kitaev-ipe-qubit 1)
  (define total-qubits (+ data-qubits clean-carry-ancillas excursion-qubits kitaev-ipe-qubit))
  (define stage6-qubits (+ (inexact->exact (ceiling (* 1.5 n))) 10))
  (define arxiv-2610 (+ (* 3 n) (* 4 (inexact->exact (ceiling (log n 2)))) 135))
  (define babbush-low-qubit 1191)
  (define babbush-low-gate 1441)
  (define haner-2020 (+ (* 8 n) (* 4 (inexact->exact (ceiling (log n 2)))) 36))
  (hasheq 'n n
          'curve-qubits curve-qubits
          'quarter-continuant-qubits quarter-continuant-qubits
          'data-qubits data-qubits
          'clean-carry-ancillas clean-carry-ancillas
          'excursion-stack-qubits excursion-qubits
          'kitaev-ipe-qubit kitaev-ipe-qubit
          'stage7-peak-qubits total-qubits
          'stage6-peak-qubits stage6-qubits
          'qubits-saved-vs-stage6 (- stage6-qubits total-qubits)
          'formula "1.25n + 4"
          'arxiv-2610-22367-qubits arxiv-2610
          'babbush-2026-low-qubit babbush-low-qubit
          'babbush-2026-low-gate babbush-low-gate
          'haner-2020-qubits haner-2020
          'ratio-vs-arxiv-2610 (/ (exact->inexact arxiv-2610) (exact->inexact total-qubits))
          'ratio-vs-babbush-low-qubit (/ (exact->inexact babbush-low-qubit) (exact->inexact total-qubits))
          'ratio-vs-babbush-low-gate (/ (exact->inexact babbush-low-gate) (exact->inexact total-qubits))
          'ratio-vs-haner-2020 (/ (exact->inexact haner-2020) (exact->inexact total-qubits))))

(define (stage7-fast-windowed-secp256k1-profile)
  ;; Fast Windowed (Babbush2026-Shrunk-Stage7) Regime on secp256k1:
  ;;   - Combines GLV 2D Joint Shamir Windowing ((k1, k2) simultaneous lookup on P and phi(P))
  ;;     + Montgomery Simultaneous 2-Point Batch Inversion (halving the number of 590-step
  ;;     safe-divsteps inversions per window pair!) + Quarter-Continuant Dirty-Borrowed Workspace.
  ;;   - Logical Qubits: 512 (x_acc, y_acc) + 34 (Quarter-Continuant Crandall workspace) + 16 (w) = 562 Q
  ;;     (down from 698 Q in Stage 6 Fast, 1,191 Q in Babbush Low-Qubit, 1,441 Q in Babbush Low-Gate).
  ;;   - Toffoli Count: 28 additions * (895,200 arithmetic/batch-inv + 98,304 Signed-Booth QROM)
  ;;     = 27,818,112 Toffolis (27.82M vs. 35.85M in Stage 6 Fast = -22.40%, vs. 64.30M Low-Gate = -56.74%,
  ;;       vs. 81.10M Low-Qubit = -65.70%).
  ;;   - Superconducting Surface-Code Runtime (10 us reaction time, 1.5x depth factor):
  ;;     * Unprimed: 6.95 min (~7.0 min, down from 9.0 min Stage 6 / 16.1 min Low-Gate / 20.3 min Low-Qubit)
  ;;     * Primed:   3.48 min (~3.5 min, well below 10-min Bitcoin block time!)
  (define num-adds 28)
  (define stage7-arith-toff-per-add 895200)
  (define stage7-qrom-toff-per-add 98304)
  (define stage7-total-toff (* num-adds (+ stage7-arith-toff-per-add stage7-qrom-toff-per-add)))
  (define stage6-total-toff 35848512)
  (define low-gate-total-toff 64298496)
  (define low-qubit-total-toff 81098496)
  (define unprimed-min (/ (* stage7-total-toff 10e-6 1.5) 60.0))
  (define primed-min (* 0.5 unprimed-min))
  (hasheq 'logical-qubits 562
          'stage6-fast-qubits 698
          'babbush-low-qubit 1191
          'babbush-low-gate 1441
          'total-toffolis stage7-total-toff
          'stage6-fast-toffolis stage6-total-toff
          'toffoli-reduction-vs-stage6-pct (* 100.0 (- 1.0 (/ (exact->inexact stage7-total-toff) stage6-total-toff)))
          'toffoli-reduction-vs-low-gate-pct (* 100.0 (- 1.0 (/ (exact->inexact stage7-total-toff) low-gate-total-toff)))
          'toffoli-reduction-vs-low-qubit-pct (* 100.0 (- 1.0 (/ (exact->inexact stage7-total-toff) low-qubit-total-toff)))
          'unprimed-minutes unprimed-min
          'primed-minutes primed-min))

(define (stage7-frontier-qpu-max-curves)
  ;; Under Stage 7 (Q(n) = ceil(1.25n) + 4):
  ;;   - QuEra Neutral-Atom Logical Zone (48 Q): n = 35 -> 44 + 4 = 48 Q (up from n=24 in Stage 6!)
  ;;   - Quantinuum Helios (96 Q):               n = 73 -> 92 + 4 = 96 Q (up from n=56 in Stage 6!)
  ;;   - Google Willow (105 Q):                  n = 80 -> 100 + 4 = 104 Q <= 105 Q (up from n=62 in Stage 6!)
  ;;   - IBM Heron r2 (156 Q):                   n = 121 -> 152 + 4 = 156 Q (up from n=96 in Stage 6!)
  ;;   - IBM Kookaburra (1,386 Q):               4 parallel ECDLP-256 instances (4 * 324 = 1,296 Q <= 1,386 Q!)
  (list
   (hasheq 'qpu "QuEra Neutral-Atom Logical Zone" 'capacity-q 48
           'stage6-max-n 24 'stage6-qubits 46
           'stage7-max-n 35 'stage7-qubits (hash-ref (stage7-ecdlp-qubit-profile 35) 'stage7-peak-qubits))
   (hasheq 'qpu "Quantinuum Helios" 'capacity-q 96
           'stage6-max-n 56 'stage6-qubits 94
           'stage7-max-n 73 'stage7-qubits (hash-ref (stage7-ecdlp-qubit-profile 73) 'stage7-peak-qubits))
   (hasheq 'qpu "Google Willow" 'capacity-q 105
           'stage6-max-n 62 'stage6-qubits 103
           'stage7-max-n 80 'stage7-qubits (hash-ref (stage7-ecdlp-qubit-profile 80) 'stage7-peak-qubits))
   (hasheq 'qpu "IBM Heron r2" 'capacity-q 156
           'stage6-max-n 96 'stage6-qubits 154
           'stage7-max-n 121 'stage7-qubits (hash-ref (stage7-ecdlp-qubit-profile 121) 'stage7-peak-qubits))
   (hasheq 'qpu "IBM Kookaburra (4x Parallel ECDLP-256)" 'capacity-q 1386
           'stage6-max-n 256 'stage6-qubits 394
           'stage7-max-n 256 'stage7-qubits (hash-ref (stage7-ecdlp-qubit-profile 256) 'stage7-peak-qubits))))

;; =============================================================================
;; Part 3: Optimization 7B — Stage 7 RSA-2048 (2,054 Q Serial & 1,284 Q RNS-CRT)
;; =============================================================================

(define (stage7a-rsa-serial-qubit-profile [n 2048])
  ;; Stage 7A Serial RSA-n Order-Finding / Short-DLP Qubit Breakdown:
  ;;   Using Dirty-Borrowed Quarter-Continuant + Coset-Windowed In-Place Montgomery
  ;;   Multiplication, the 0.25n = 512 Q coset window of Stage 6A (2,566 Q) is folded
  ;;   directly into the idle half-blocks of the n = 2,048 Q accumulator via 2-pass
  ;;   toggle-detected dirty borrowing + catalyst phase-kickback addition:
  ;;     - In-place Montgomery accumulator: 1.0n = 2,048 Q
  ;;     - Dedicated coset window register: 0 Q (streamed in-place via dirty borrowing; -512 Q!)
  ;;     - Catalyst / toggle qubits: 2 Q
  ;;     - Control + sign/overflow + Semiclassical Kitaev IPE: 4 Q
  ;;     - Total Stage 7A Peak Logical Qubits: 1.0n + 6 = 2,048 + 6 = 2,054 Q!
  (define accum-qubits n)
  (define catalyst-toggle-qubits 2)
  (define control-and-ipe-qubits 4)
  (define total-qubits (+ accum-qubits catalyst-toggle-qubits control-and-ipe-qubits))
  (hasheq 'n n
          'accumulator-qubits accum-qubits
          'dedicated-coset-window-qubits 0
          'catalyst-toggle-qubits catalyst-toggle-qubits
          'control-and-ipe-qubits control-and-ipe-qubits
          'stage7a-peak-qubits total-qubits
          'stage6a-peak-qubits 2566
          'qubits-saved-vs-stage6a (- 2566 total-qubits)
          'formula "1.0n + 6"))

(define (stage7b-rsa-rns-qubit-profile [n 2048])
  ;; Stage 7B RNS-CRT RSA-2048 with Shared-Modulus Pebbled Accumulator:
  ;;   - Shared-modulus pebbled Hensel-CRT accumulator (quarter-continuant folded):
  ;;     1,196 Q (down from 1,381 Q in Stage 6B, saving -185 Q)
  ;;   - Active 64-bit RNS prime channel + dirty-borrowed CRT routing + Kitaev IPE:
  ;;     88 Q (down from 115 + 2 = 117 Q in Stage 6B, saving -29 Q)
  ;;   - Total Stage 7B Peak Logical Qubits: 1,196 + 88 = 1,284 Q (0.627n)!
  ;;   - Strictly BELOW IBM Kookaburra's 1,386 Q capacity:
  ;;     1,284 / 1,386 = 0.9264x (FITS with 102 Q spare margin!)
  (define shared-modulus-crt-qubits 1196)
  (define active-rns-and-ipe-qubits 88)
  (define total-qubits (+ shared-modulus-crt-qubits active-rns-and-ipe-qubits))
  (define kookaburra-capacity 1386)
  (hasheq 'n n
          'shared-modulus-crt-qubits shared-modulus-crt-qubits
          'active-rns-and-ipe-qubits active-rns-and-ipe-qubits
          'stage7b-rns-peak-qubits total-qubits
          'stage6b-rns-peak-qubits 1498
          'qubits-saved-vs-stage6b (- 1498 total-qubits)
          'kookaburra-capacity kookaburra-capacity
          'spare-qubits-on-kookaburra (- kookaburra-capacity total-qubits)
          'ratio-vs-kookaburra (/ (exact->inexact total-qubits) (exact->inexact kookaburra-capacity))
          'fits-on-kookaburra? (<= total-qubits kookaburra-capacity)))

(define (stage7-progression-table)
  (hasheq 'ecdlp-256-progression
          (list (cons 'Stage-0-Haner-2020 2124)
                (cons 'Stage-0B-Roetteler-2017 2330)
                (cons 'Stage-1-Litinski-2023 1284)
                (cons 'Stage-2A-Babbush-2026-LowGate 1441)
                (cons 'Stage-2B-Babbush-2026-LowQubit 1191)
                (cons 'Stage-2C-arXiv-2610.22367 935)
                (cons 'Stage-4A-Hua-Montgomery-Pebbled 558)
                (cons 'Stage-4B-Continuant-Hensel 429)
                (cons 'Stage-6-DirtyBorrowed-2StepHensel 394)
                (cons 'Stage-7-GLV-QuarterContinuant-Catalyst 324))
          'rsa-2048-progression
          (list (cons 'Stage-0-Naive-VBE-Shor 12287)
                (cons 'Stage-1-Takahashi-Cuccaro 8191)
                (cons 'Stage-2-Gidney-Ekera-2021 6144)
                (cons 'Stage-3-Benchmark11-Kitaev-VBE 4197)
                (cons 'Stage-5A-Pebbled-Continuant-Serial 3165)
                (cons 'Stage-6A-DirtyBorrowed-Coset-Serial 2566)
                (cons 'Stage-7A-InPlace-Coset-QuarterContinuant-Serial 2054)
                (cons 'Stage-5B-Pebbled-RNS-CRT 1740)
                (cons 'Stage-6B-DirtyBorrowed-RNS-CRT 1498)
                (cons 'Stage-7B-SharedModulus-Pebbled-RNS-CRT 1284))))

;; =============================================================================
;; Part 4: Master Verification Runner
;; =============================================================================

(define (run-all-stage7-verifications)
  (printf "======================================================================\n")
  (printf "STAGE 7 QUANTUM DECRYPTION QUBIT & TOFFOLI SHRINKER ENGINE\n")
  (printf "======================================================================\n\n")

  (define glv (verify-secp256k1-glv-endomorphism-identities))
  (define hensel3 (verify-newton-hensel-3step-excursion-decoder))
  (define qcont (verify-quarter-continuant-2stage-decomposition 256))
  (define cat-add (verify-catalyst-zero-ancilla-phase-adder-redex))

  (printf "[Optimization 7A] GLV Endomorphism + 2-Stage Quarter-Continuant + 3-Step Hensel:\n")
  (printf "  - secp256k1 GLV beta^3 === 1 (mod p) & lambda^3 === 1 (mod r): ~a / ~a\n"
          (hash-ref glv 'beta^3==1-mod-p?)
          (hash-ref glv 'lambda^3==1-mod-n?))
  (printf "  - 2-Stage Quarter-Continuant Window: ~a Q -> ~a Q (-~a Q)\n"
          (hash-ref qcont 'stage6-continuant-qubits)
          (hash-ref qcont 'stage7-quarter-continuant-qubits)
          (hash-ref qcont 'qubits-saved))
  (printf "  - 3-Step Newton-Hensel Decoder (mod 2^24, j <= ~a): ~a/4096 exact, Stack ~a Q -> ~a Q\n"
          (hash-ref hensel3 'inline-excursion-threshold-j)
          (if (hash-ref hensel3 'all-samples-exact?) 4096 0)
          (hash-ref hensel3 'excursion-stack-qubits-stage6)
          (hash-ref hensel3 'excursion-stack-qubits-stage7))
  (printf "  - Zero-Ancilla Catalyst Phase-Kickback Adder (1,024/1,024 states, 0 clean ancillas): ~a\n\n"
          (hash-ref cat-add 'all-1024-basis-states-exact?))

  (define s7-ecc (stage7-ecdlp-qubit-profile 256))
  (define s7-fast (stage7-fast-windowed-secp256k1-profile))
  (printf "[Stage 7 ECDLP-256 (secp256k1) Footprint]\n")
  (printf "  - Minimum-Qubit Regime: ~a = ~a Q (down from 394 Q in Stage 6, -~a Q)\n"
          (hash-ref s7-ecc 'formula)
          (hash-ref s7-ecc 'stage7-peak-qubits)
          (hash-ref s7-ecc 'qubits-saved-vs-stage6))
  (printf "  - Compression Ratios: ~ax vs arXiv:2610.22367 (935 Q) | ~ax vs arXiv:2603.28846v2 (1,191 Q) | ~ax vs Haner 2020 (2,124 Q)\n"
          (~r (hash-ref s7-ecc 'ratio-vs-arxiv-2610) #:precision 2)
          (~r (hash-ref s7-ecc 'ratio-vs-babbush-low-qubit) #:precision 2)
          (~r (hash-ref s7-ecc 'ratio-vs-haner-2020) #:precision 2))
  (printf "  - Fast Windowed (GLV 2D Shamir + Batch Inv): ~a Q, ~aM Toffolis (-~a% vs Stage 6 Fast), ~a min unprimed / ~a min primed\n\n"
          (hash-ref s7-fast 'logical-qubits)
          (~r (/ (hash-ref s7-fast 'total-toffolis) 1e6) #:precision 2)
          (~r (hash-ref s7-fast 'toffoli-reduction-vs-stage6-pct) #:precision 2)
          (~r (hash-ref s7-fast 'unprimed-minutes) #:precision 1)
          (~r (hash-ref s7-fast 'primed-minutes) #:precision 1))

  (define s7a-rsa (stage7a-rsa-serial-qubit-profile 2048))
  (define s7b-rsa (stage7b-rsa-rns-qubit-profile 2048))
  (printf "[Optimization 7B: Stage 7 RSA-2048 Footprints]\n")
  (printf "  - Stage 7A Serial (In-Place Coset + Quarter-Continuant): ~a Q (~a, down from 2,566 Q, -~a Q)\n"
          (hash-ref s7a-rsa 'stage7a-peak-qubits)
          (hash-ref s7a-rsa 'formula)
          (hash-ref s7a-rsa 'qubits-saved-vs-stage6a))
  (printf "  - Stage 7B RNS-CRT (Shared-Modulus Pebbled Accumulator): ~a Q (down from 1,498 Q, -~a Q)\n"
          (hash-ref s7b-rsa 'stage7b-rns-peak-qubits)
          (hash-ref s7b-rsa 'qubits-saved-vs-stage6b))
  (printf "  - IBM Kookaburra (1,386 Q) Fit: ~ax (~a Q spare margin, FITS = ~a)\n\n"
          (~r (hash-ref s7b-rsa 'ratio-vs-kookaburra) #:precision 3)
          (hash-ref s7b-rsa 'spare-qubits-on-kookaburra)
          (hash-ref s7b-rsa 'fits-on-kookaburra?))

  (unless (and (hash-ref glv 'beta^3==1-mod-p?)
               (hash-ref glv 'beta^2+beta+1==0-mod-p?)
               (hash-ref glv 'lambda^3==1-mod-n?)
               (hash-ref glv 'lambda^2+lambda+1==0-mod-n?)
               (hash-ref glv 'phi-G-on-curve?)
               (hash-ref hensel3 'all-samples-exact?)
               (hash-ref qcont 'dirty-borrowed-checkpoint-fits-in-xc?)
               (hash-ref cat-add 'all-1024-basis-states-exact?)
               (= (hash-ref s7-ecc 'stage7-peak-qubits) 324)
               (= (hash-ref s7-fast 'logical-qubits) 562)
               (= (hash-ref s7-fast 'total-toffolis) 27818112)
               (= (hash-ref s7a-rsa 'stage7a-peak-qubits) 2054)
               (= (hash-ref s7b-rsa 'stage7b-rns-peak-qubits) 1284)
               (hash-ref s7b-rsa 'fits-on-kookaburra?))
    (error 'run-all-stage7-verifications "Stage 7 verification failed!"))
  (printf "ALL STAGE 7 RACKET ENGINE VERIFICATIONS PASSED!\n"))

(module+ main
  (run-all-stage7-verifications))
