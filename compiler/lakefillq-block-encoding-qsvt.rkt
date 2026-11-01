#lang racket/base

;; =============================================================================
;; compiler/lakefillq-block-encoding-qsvt.rkt
;;
;; Block-Encoded Linear Algebra (`QBlock`: `LCU` / `QSVT` / `Qubitization`) with
;; Subnormalization Tracking (`alpha`), Chebyshev Reflection Fusion (`e-Graph`),
;; and `Law U4` Berry-Gidney `PREP-dagger` Uncomputation for `LakefillQ`.
;;
;; Unifies discrete `QSub` (`Laws U1-U4`) and `QPhysGrade` (`Grades Phi1-Phi3`)
;; with continuous/linear-algebraic block encodings:
;;
;;   Gamma |- U_A : QBlock(A, alpha, m_anc, eps_block, Phi_X)
;;   (<0^{m_anc}| x I) * U_A * (|0^{m_anc}> x I) = A / alpha
;;
;; Enforces:
;;   1. `LCU` sum `A + B`: `(alpha_A + alpha_B, max(m_A, m_B) + 1)` requiring
;;      canonical `NestedDyadicWalkerAliasBox` `PREP` (`Law U2`), exhaustive
;;      `SELECT` partition (`Law U3`), clean scratch restoration (`Law U1`),
;;      and zero residual `M_X` quantum phase kickback (`Law U4`).
;;   2. Naive block product `A * B`: `(alpha_A * alpha_B, m_A + m_B)`.
;;   3. Chebyshev `T_d(A / alpha)` QSVT reflection fusion (`e-graph` rewrite
;;      `(chebyshev-naive d U_A) -> (qsvt-reflection-fused d U_A phi_angles)`):
;;      compresses ancillas from `d * m_anc` down to `m_anc + 1` (`1` signal
;;      qubit + `m_anc` shared block ancillas) with `alpha_out = 1`.
;;   4. `Law U4` Berry-Gidney `PREP-dagger` uncomputation inside Qubitization:
;;      collapses `W`-bit QROAM table uncomputation from `L - 2` `CCX` to a
;;      1-bit phase-table lookup costing `61 TempAND`s at `L = 1024, W = 32`
;;      (`16.75x` vs `1,022 CCX`) and `91 TempAND`s at `L = 2048` `FeMoCo`-scale
;;      terms (`22.48x` vs `2,046 CCX`), strictly independent of `W`!
;; =============================================================================

(require racket/cmdline
         racket/format
         racket/list
         racket/match
         racket/math
         racket/runtime-path
         racket/set
         json
         lakefillq
         "lakefillqc.rkt")

(define-runtime-path hubbard-example-lfq-path
  "../examples/hubbard_lcu_qsvt_block.lfq")

(provide (struct-out qblock-type)
         (struct-out qb-enode)
         (struct-out qb-egraph)
         sawtooth-unitary-prep-dag-ccx
         berry-gidney-prep-dag-temp-ands
         verify-differential-f2-phase-bank-truth-table
         infer-qblock-type
         make-qb-egraph
         qb-egraph-add!
         qb-egraph-saturate!
         qb-egraph-extract-optimal
         audit-negative-qblock-programs
         run-qblock-qsvt-compiler-verification)

;; =============================================================================
;; 1. `QBlock` Type Representation & Subnormalization Rules
;; =============================================================================

(struct qblock-type
  (op-expr            ;; S-expression describing the encoded linear operator A
   alpha              ;; positive real/rational subnormalization factor (> 0)
   m-anc              ;; exact nonnegative integer persistent block-encoding ancillas
   sys-qubits         ;; exact positive integer system register width
   eps-block          ;; nonnegative real/rational block-encoding error bound
   hermitian-walk?    ;; boolean: #t if U_A = U_A^dag and U_A^2 = I on walk subspace
   prep-uncomp-kind   ;; 'none | 'unitary-sawtooth | 'berry-gidney-mx-u4
   temp-and-cost      ;; exact nonnegative integer forward TempAND + CCX count
   qphys-grade        ;; qphys-semiring-grade (`Grades Phi1-Phi3`)
   well-typed?        ;; boolean certifying BlockOrthogonality + Laws U1-U4 + Phi1-Phi3
   violations)        ;; list of structured violation hashes
  #:transparent)

(define qphys-zero-grade
  (qphys-semiring-grade 0 0 0 0 0 '() #f 0 (seteqv) 0))

(define (combine-qphys-seq g1 g2)
  (qphys-semiring-grade
   (+ (qphys-semiring-grade-qubit-ns g1) (qphys-semiring-grade-qubit-ns g2))
   (+ (qphys-semiring-grade-gate-milli g1) (qphys-semiring-grade-gate-milli g2))
   (+ (qphys-semiring-grade-mbu-excess-ns g1) (qphys-semiring-grade-mbu-excess-ns g2))
   (+ (qphys-semiring-grade-routing-excess-cx g1) (qphys-semiring-grade-routing-excess-cx g2))
   (+ (qphys-semiring-grade-exclusion-collisions g1) (qphys-semiring-grade-exclusion-collisions g2))
   (append (qphys-semiring-grade-colliding-pairs g1) (qphys-semiring-grade-colliding-pairs g2))
   (let ([d1 (qphys-semiring-grade-eff-fault-dist g1)]
         [d2 (qphys-semiring-grade-eff-fault-dist g2)])
     (cond [(not d1) d2] [(not d2) d1] [else (min d1 d2)]))
   (max (qphys-semiring-grade-req-fault-dist g1) (qphys-semiring-grade-req-fault-dist g2))
   (set-union (qphys-semiring-grade-support-wires g1) (qphys-semiring-grade-support-wires g2))
   (+ (qphys-semiring-grade-duration-ns g1) (qphys-semiring-grade-duration-ns g2))))

(define (scale-qphys-grade k g)
  (if (<= k 0)
      qphys-zero-grade
      (for/fold ([acc qphys-zero-grade]) ([_ (in-range k)])
        (combine-qphys-seq acc g))))

(define (multishot-qphys-grade shots-k g)
  (if (<= shots-k 1)
      g
      (struct-copy qphys-semiring-grade g
                   [qubit-ns (quotient (qphys-semiring-grade-qubit-ns g) shots-k)]
                   [gate-milli (quotient (qphys-semiring-grade-gate-milli g) shots-k)]
                   [duration-ns (quotient (qphys-semiring-grade-duration-ns g) shots-k)])))

;; =============================================================================
;; 2. `Law U4` Berry-Gidney `PREP-dagger` Table Uncomputation Cost & Soundness
;; =============================================================================
;; Standard unitary sawtooth `PREP-dagger` uncomputation over `L` Hamiltonian
;; terms (`W`-bit keep/alias word):
;;   `sawtooth_ccx(L) = L - 2` (for L >= 2).
;;
;; `Law U4` Berry-Gidney `M_X` uncomputation measures all `W` keep/alias wires in
;; the Hadamard `X`-basis (`m in {0, 1}^W`), reducing `W`-bit data uncomputation
;; to a 1-bit quantum phase lookup `P_m[l] = parity(m & T[l])` (`0` dependence on `W`!):
;;   - Even `log2(L)` (`L = 2^{2s}`, e.g. `L = 16, 64, 256, 1024`):
;;       `lambda_uncomp = sqrt(L) = 2^s`, `Q = L / lambda_uncomp = 2^s`:
;;       `TempANDs = (lambda_uncomp - 1) + (Q - 2) = 2 * sqrt(L) - 3`
;;       (`L = 1024 -> 31 + 30 = 61 TempANDs` vs `1,022 CCX` = `16.75x`!).
;;   - Odd `log2(L)` (`L = 2^{2s+1}`, e.g. `L = 32, 128, 512, 2048` `FeMoCo` scale):
;;       Pure-dyadic differential `F_2` phase-bank decomposition over MSB `a_{2s}`:
;;       `P[a_{2s}, q', r] = P_0[q', r] XOR (a_{2s} AND (P_0[q', r] XOR P_1[q', r]))`
;;       with shared root-free unary fanout `lambda_uncomp = 2^s` (`2^s - 2` TempANDs),
;;       uncontrolled Pass-1 sawtooth over `Q_0 = 2^s` (`2^s - 2` TempANDs), and
;;       `a_{2s}`-controlled Pass-2 sawtooth over `Q_0 = 2^s` (`2^s - 1` TempANDs):
;;       `TempANDs = (2^s - 2) + (2^s - 2) + (2^s - 1) = 3 * 2^s - 5`
;;       (`L = 2048, 2^s = 32 -> 30 + 30 + 31 = 91 TempANDs` vs `2,046 CCX` = `22.48x`!).
;;       (Note: mixed-radix `Select-SWAP` at `lambda = 35, Q = ceil(2048/35) = 59`
;;       also yields `(35 - 1) + (59 - 2) = 34 + 57 = 91 TempANDs`!)

(define (exact-power-of-two-exponent n)
  (let loop ([v n] [e 0])
    (cond
      [(= v 1) e]
      [(and (> v 1) (even? v)) (loop (quotient v 2) (add1 e))]
      [else #f])))

(define (sawtooth-unitary-prep-dag-ccx L-terms _w-bits)
  (if (<= L-terms 2)
      0
      (- L-terms 2)))

(define (berry-gidney-prep-dag-temp-ands L-terms _w-bits)
  (cond
    [(<= L-terms 2) 0]
    [else
     (define exp-k (exact-power-of-two-exponent L-terms))
     (cond
       [(and exp-k (even? exp-k))
        (define half-pow (arithmetic-shift 1 (quotient exp-k 2)))
        (- (* 2 half-pow) 3)]
       [(and exp-k (odd? exp-k))
        (define s-pow (arithmetic-shift 1 (quotient (sub1 exp-k) 2)))
        (if (= s-pow 1)
            1
            (- (* 3 s-pow) 5))]
       [else
        ;; General mixed-radix Select-SWAP minimum over lambda in [1..L]:
        (for/fold ([best (* 2 L-terms)]) ([lam (in-range 1 (add1 L-terms))])
          (define q-blocks (exact-ceiling (/ L-terms lam)))
          (define c (+ (max 0 (sub1 lam)) (max 0 (- q-blocks 2))))
          (min best c))])]))

;; Exhaustive truth-table & small-scale (`L = 32, W = 8`) parity check of the
;; pure-dyadic differential `F_2` phase-bank identity `p0 XOR (msb AND (p0 XOR p1))`:
(define (verify-differential-f2-phase-bank-truth-table)
  ;; 1. Boolean identity check over all 8 `(msb, p0, p1)` triples:
  (for* ([msb (in-list '(0 1))]
         [p0 (in-list '(0 1))]
         [p1 (in-list '(0 1))])
    (define delta (bitwise-xor p0 p1))
    (define reconstructed (bitwise-xor p0 (bitwise-and msb delta)))
    (define expected (if (= msb 0) p0 p1))
    (unless (= reconstructed expected)
      (error 'verify-differential-f2-phase-bank-truth-table
             "Differential F2 phase bank mismatch at msb=~a p0=~a p1=~a"
             msb p0 p1)))

  ;; 2. Exhaustive `L = 32, W = 8` (`2^5 * 2^8 = 8,192` `(addr, m_mask)` pairs)
  ;;    verifying `7 TempAND` (`(4-2)+(4-2)+(4-1) = 7` vs `30` sawtooth CCX)
  ;;    1-bit phase-bank reconstruction of `parity(m_mask & T[addr])`:
  (define table32
    (for/list ([i (in-range 32)])
      (bitwise-and (+ (* 73 i) 19 (arithmetic-shift i 3)) #xFF)))
  (define (popcount-parity v)
    (let loop ([x v] [p 0])
      (if (zero? x) p (loop (arithmetic-shift x -1) (bitwise-xor p (bitwise-and x 1))))))
  (define checked-pairs 0)
  (for* ([m-mask (in-range 256)]
         [addr (in-range 32)])
    (define r (bitwise-and addr 3))
    (define q-low (bitwise-and (arithmetic-shift addr -2) 3))
    (define msb (bitwise-and (arithmetic-shift addr -4) 1))
    (define p0 (popcount-parity (bitwise-and m-mask (list-ref table32 (+ (* 4 q-low) r)))))
    (define p1 (popcount-parity (bitwise-and m-mask (list-ref table32 (+ 16 (* 4 q-low) r)))))
    (define bank-phase (bitwise-xor p0 (bitwise-and msb (bitwise-xor p0 p1))))
    (define direct-phase (popcount-parity (bitwise-and m-mask (list-ref table32 addr))))
    (unless (= bank-phase direct-phase)
      (error 'verify-differential-f2-phase-bank-truth-table
             "Phase mismatch at addr=~a mask=~a" addr m-mask))
    (set! checked-pairs (add1 checked-pairs)))
  checked-pairs)

;; Helper extracting an approximate qphys-semiring-grade from a compiled circuit:
(define (compilation-result->approx-grade res hw)
  (define act (compilation-result-decoherence-action-milli res))
  (define col (compilation-result-exclusion-collisions res))
  (define eff-d
    (let ([d (compilation-result-effective-fault-distance res)])
      (if (eq? d 'unbounded) #f d)))
  (define req-d (compilation-result-required-fault-distance res))
  (define dur (* (compilation-result-isa-gate-count res)
                 (target-hw-profile-gate-2q-ns hw)))
  (qphys-semiring-grade
   (* (compilation-result-physical-qubits res) dur)
   act
   0
   0
   col
   '()
   eff-d
   req-d
   (list->seteqv (range (compilation-result-physical-qubits res)))
   dur))

;; =============================================================================
;; 3. Compositional `QBlock` Typechecker (`infer-qblock-type`)
;; =============================================================================

(define (chebyshev-monomial-l1-norm d)
  ;; Sum of absolute Chebyshev coefficients `T_d(i) / i^d` (`1, 1, 3, 7, 17, ...` = Pell-Lucas):
  (cond
    [(= d 0) 1]
    [(= d 1) 1]
    [else
     (let loop ([k 2] [prev2 1] [prev1 1])
       (if (= k d)
           (+ (* 2 prev1) prev2)
           (loop (add1 k) prev1 (+ (* 2 prev1) prev2))))]))

(define (infer-qblock-type block-ast #:target [target-sym 'heron-r2])
  (define hw (lookup-target-profile target-sym))
  (match block-ast
    ;; 1. Unitary Pauli / base operator `P`: `alpha = 1, m_anc = 0, eps = 0`
    [`(qblock-pauli ,op-sym ,sys-q ,lfq-decl)
     (define comp-res
       (if lfq-decl
           (compile-lfq-circuit lfq-decl target-sym)
           #f))
     (define viols (if comp-res (compilation-result-violations comp-res) '()))
     (define grade (if comp-res (compilation-result->approx-grade comp-res hw) qphys-zero-grade))
     (define tand (if comp-res
                      (+ (compilation-result-forward-temp-and-count comp-res)
                         (compilation-result-uncompute-ccx-count comp-res))
                      0))
     (qblock-type op-sym 1.0 0 sys-q 0.0 #t 'none tand grade (null? viols) viols)]

    ;; 2. `LCU` Hamiltonian block encoding `H = sum_{l=0}^{L-1} c_l P_l`:
    [`(qblock-lcu ,op-sym ,coeffs ,m-anc ,sys-q ,w-bits ,prep-kind ,uncomp-kind ,lfq-decl)
     (define alpha (for/sum ([c (in-list coeffs)]) (abs c)))
     (define L-terms (length coeffs))
     (define viols '())
     (define (add-viol! cat code msg wit)
       (set! viols (append viols (list (hasheq 'category cat
                                               'code code
                                               'message msg
                                               'witness wit)))))
     (unless (> alpha 0)
       (add-viol! "QBlock" "InvalidSubnormalization"
                  "LCU Hamiltonian must have strictly positive L1 subnormalization alpha > 0"
                  (hasheq 'alpha alpha)))
     (unless (eq? prep-kind 'nested-dyadic-walker-alias)
       (add-viol! "QBlock" "U2-NonCanonicalWalkerAliasPrep"
                  (format "LCU PREP requires canonical NestedDyadicWalkerAliasBox (Law U2), got ~a"
                          prep-kind)
                  (hasheq 'prep_kind (symbol->string prep-kind))))
     (define comp-res
       (if lfq-decl
           (compile-lfq-circuit lfq-decl target-sym)
           #f))
     (when comp-res
       (for ([v (in-list (compilation-result-violations comp-res))])
         (add-viol! "BlockOrthogonality"
                    (format "BlockProjectionCorrupted-~a" (hash-ref v 'code "QSub"))
                    (format "Off-block ancilla/phase violation corrupts <0^m|U_H|0^m> = H/alpha: ~a"
                            (hash-ref v 'message ""))
                    v)))
     (define fwd-prep-ands (+ (max 0 (- L-terms 2)) (* w-bits 2)))
     (define bwd-prep-ands
       (match uncomp-kind
         ['unitary-sawtooth (sawtooth-unitary-prep-dag-ccx L-terms w-bits)]
         ['berry-gidney-mx-u4 (berry-gidney-prep-dag-temp-ands L-terms w-bits)]
         ['unfixed-mx-violation
          (add-viol! "BlockOrthogonality" "U4-UnfixedBerryGidneyPrepDag"
                     "Berry-Gidney M_X PREP-dagger omits 1-bit quantum phase lookup, flipping LCU signs in <0^m|"
                     (hasheq 'L_terms L-terms 'w_bits w-bits))
          0]
         [_
          (add-viol! "QBlock" "UnknownPrepDagMode"
                     (format "Unsupported PREP-dagger mode ~a" uncomp-kind)
                     (hasheq))
          0]))
     (define select-ands (max 0 (- L-terms 1)))
     (define total-ands
       (if comp-res
           (+ (compilation-result-forward-temp-and-count comp-res)
              (compilation-result-uncompute-ccx-count comp-res))
           (+ fwd-prep-ands select-ands bwd-prep-ands)))
     (define grade
       (if comp-res
           (compilation-result->approx-grade comp-res hw)
           (let ([dur (* total-ands 4 (target-hw-profile-gate-2q-ns hw))])
             (qphys-semiring-grade (* (+ sys-q m-anc) dur)
                                   (* total-ands 4 (target-hw-profile-p2q-permil hw))
                                   0 0 0 '() #f 0
                                   (list->seteqv (range (+ sys-q m-anc)))
                                   dur))))
     (qblock-type op-sym
                  (exact->inexact alpha)
                  m-anc
                  sys-q
                  0.0
                  #t
                  uncomp-kind
                  total-ands
                  grade
                  (null? viols)
                  viols)]

    ;; 3. Binary `LCU` sum `wA * A + wB * B`: `(alpha_A*|wA| + alpha_B*|wB|, max(m_A, m_B) + 1)`
    [`(qblock-sum ,wA ,subA ,wB ,subB)
     (define tA (infer-qblock-type subA #:target target-sym))
     (define tB (infer-qblock-type subB #:target target-sym))
     (define viols (append (qblock-type-violations tA) (qblock-type-violations tB)))
     (unless (= (qblock-type-sys-qubits tA) (qblock-type-sys-qubits tB))
       (set! viols
             (append viols
                     (list (hasheq 'category "QBlock"
                                   'code "DimensionMismatch"
                                   'message "LCU sum requires matching system qubit counts"
                                   'witness (hasheq 'sys_A (qblock-type-sys-qubits tA)
                                                    'sys_B (qblock-type-sys-qubits tB)))))))
     (define alpha-sum (+ (* (abs wA) (qblock-type-alpha tA))
                          (* (abs wB) (qblock-type-alpha tB))))
     (define m-sum (add1 (max (qblock-type-m-anc tA) (qblock-type-m-anc tB))))
     (define eps-sum (+ (* (abs wA) (qblock-type-eps-block tA))
                        (* (abs wB) (qblock-type-eps-block tB))))
     (qblock-type `(lcu-add (,wA ,(qblock-type-op-expr tA)) (,wB ,(qblock-type-op-expr tB)))
                  alpha-sum
                  m-sum
                  (qblock-type-sys-qubits tA)
                  eps-sum
                  (and (qblock-type-hermitian-walk? tA) (qblock-type-hermitian-walk? tB))
                  'berry-gidney-mx-u4
                  (+ (qblock-type-temp-and-cost tA) (qblock-type-temp-and-cost tB) 2)
                  (combine-qphys-seq (qblock-type-qphys-grade tA) (qblock-type-qphys-grade tB))
                  (null? viols)
                  viols)]

    ;; 4. Naive block product `A * B`: `(alpha_A * alpha_B, m_A + m_B)`
    [`(qblock-product ,subA ,subB)
     (define tA (infer-qblock-type subA #:target target-sym))
     (define tB (infer-qblock-type subB #:target target-sym))
     (define viols (append (qblock-type-violations tA) (qblock-type-violations tB)))
     (define aA (qblock-type-alpha tA))
     (define aB (qblock-type-alpha tB))
     (define alpha-prod (* aA aB))
     (define m-prod (+ (qblock-type-m-anc tA) (qblock-type-m-anc tB)))
     (define eps-prod (+ (* aA (qblock-type-eps-block tB))
                         (* aB (qblock-type-eps-block tA))))
     (qblock-type `(mat-mul ,(qblock-type-op-expr tA) ,(qblock-type-op-expr tB))
                  alpha-prod
                  m-prod
                  (qblock-type-sys-qubits tA)
                  eps-prod
                  #f
                  (qblock-type-prep-uncomp-kind tA)
                  (+ (qblock-type-temp-and-cost tA) (qblock-type-temp-and-cost tB))
                  (combine-qphys-seq (qblock-type-qphys-grade tA) (qblock-type-qphys-grade tB))
                  (null? viols)
                  viols)]

    ;; 5. Naive Chebyshev polynomial `T_d(A / alpha)` without QSVT reflection fusion:
    ;;    Allocates `d * m_anc` disjoint product ancillas (and `chebyshev-monomial-l1-norm(d)`
    ;;    monomial LCU subnormalization if summed term-by-term without Szegedy walk reflections!).
    [`(chebyshev-naive ,d ,subA)
     (define tA (infer-qblock-type subA #:target target-sym))
     (define viols (qblock-type-violations tA))
     (define m-naive (* d (qblock-type-m-anc tA)))
     (define alpha-naive (exact->inexact (chebyshev-monomial-l1-norm d)))
     (define eps-naive (* d (chebyshev-monomial-l1-norm d) (qblock-type-eps-block tA)))
     (define refl-ands (* (max 0 (sub1 d)) (max 1 (qblock-type-m-anc tA))))
     (qblock-type `(chebyshev-T ,d (norm-div ,(qblock-type-op-expr tA) ,(qblock-type-alpha tA)))
                  alpha-naive
                  m-naive
                  (qblock-type-sys-qubits tA)
                  eps-naive
                  (and (= d 1) (qblock-type-hermitian-walk? tA))
                  (qblock-type-prep-uncomp-kind tA)
                  (+ (* d (qblock-type-temp-and-cost tA)) refl-ands)
                  (scale-qphys-grade d (qblock-type-qphys-grade tA))
                  (null? viols)
                  viols)]

    ;; 6. Fused QSVT Chebyshev reflection `T_d(A / alpha)`:
    ;;    Compresses ancillas to `m_anc + 1` (`1` signal-processing qubit + `m_anc` shared
    ;;    block ancillas) with exact subnormalization `alpha_out = 1.0` (`|T_d(x)| <= 1`)!
    [`(qsvt-reflection-fused ,d ,subA ,phi-angles)
     (define tA (infer-qblock-type subA #:target target-sym))
     (define viols (qblock-type-violations tA))
     (unless (qblock-type-hermitian-walk? tA)
       (set! viols
             (append viols
                     (list (hasheq 'category "QBlock"
                                   'code "NonHermitianWalkBase"
                                   'message "QSVT Chebyshev reflection fusion requires Hermitian/walk-compatible block encoding"
                                   'witness (hasheq 'expected_angles d
                                                    'provided_angles (length phi-angles)))))))
     (define m-fused (add1 (qblock-type-m-anc tA)))
     (define refl-ands (* (max 0 (sub1 d)) (max 1 (sub1 (qblock-type-m-anc tA)))))
     (qblock-type `(chebyshev-T ,d (norm-div ,(qblock-type-op-expr tA) ,(qblock-type-alpha tA)))
                  1.0
                  m-fused
                  (qblock-type-sys-qubits tA)
                  (* d (qblock-type-eps-block tA))
                  #t
                  (qblock-type-prep-uncomp-kind tA)
                  (+ (* d (qblock-type-temp-and-cost tA)) refl-ands)
                  (scale-qphys-grade d (qblock-type-qphys-grade tA))
                  (null? viols)
                  viols)]

    ;; 7. Lin-Tong `1`-ancilla Hadamard-test Serial Multishot QPE (`reset_all` between shots):
    [`(lin-tong-serial-multishot ,shots-k ,max-cheb-order ,subA)
     (define fused-sub
       `(qsvt-reflection-fused ,max-cheb-order ,subA ,(make-list max-cheb-order (/ pi 2.0))))
     (define tf (infer-qblock-type fused-sub #:target target-sym))
     (qblock-type `(lin-tong-serial-qpe ,shots-k ,(qblock-type-op-expr tf))
                  1.0
                  (qblock-type-m-anc tf)
                  (qblock-type-sys-qubits tf)
                  (qblock-type-eps-block tf)
                  #t
                  (qblock-type-prep-uncomp-kind tf)
                  (qblock-type-temp-and-cost tf)
                  (multishot-qphys-grade shots-k (qblock-type-qphys-grade tf))
                  (qblock-type-well-typed? tf)
                  (qblock-type-violations tf))]

    [_ (error 'infer-qblock-type "Unrecognized QBlock AST form: ~a" block-ast)]))

;; =============================================================================
;; 4. Congruence-Closed `QBlock` `e-Graph` Saturation & Optimal Extraction
;; =============================================================================
;; Saturates:
;;   - `(chebyshev-naive d U_A)` <-> `(qsvt-reflection-fused d U_A phi_Td)`
;;   - `(qblock-lcu ... unitary-sawtooth ...)` <-> `(qblock-lcu ... berry-gidney-mx-u4 ...)`
;; and extracts the minimum-cost `(m_anc, alpha, temp_and_cost)` valid `QBlock` AST!

(struct qb-enode (op children attrs) #:transparent)
(struct qb-egraph (uf hashcons classes next-id merges) #:mutable #:transparent)

(define (make-qb-egraph)
  (qb-egraph (make-hash) (make-hash) (make-hash) 0 0))

(define (qb-find! eg id)
  (define p (hash-ref (qb-egraph-uf eg) id id))
  (if (= p id)
      id
      (let ([r (qb-find! eg p)])
        (hash-set! (qb-egraph-uf eg) id r)
        r)))

(define (qb-canon eg nd)
  (qb-enode (qb-enode-op nd)
            (map (lambda (c) (qb-find! eg c)) (qb-enode-children nd))
            (qb-enode-attrs nd)))

(define (qb-add-enode! eg raw-nd)
  (define nd (qb-canon eg raw-nd))
  (cond
    [(hash-has-key? (qb-egraph-hashcons eg) nd)
     (qb-find! eg (hash-ref (qb-egraph-hashcons eg) nd))]
    [else
     (define id (qb-egraph-next-id eg))
     (set-qb-egraph-next-id! eg (add1 id))
     (hash-set! (qb-egraph-uf eg) id id)
     (hash-set! (qb-egraph-hashcons eg) nd id)
     (hash-set! (qb-egraph-classes eg) id (set nd))
     id]))

(define (qb-merge! eg id1 id2)
  (define r1 (qb-find! eg id1))
  (define r2 (qb-find! eg id2))
  (unless (= r1 r2)
    (hash-set! (qb-egraph-uf eg) r2 r1)
    (define s1 (hash-ref (qb-egraph-classes eg) r1 (set)))
    (define s2 (hash-ref (qb-egraph-classes eg) r2 (set)))
    (hash-set! (qb-egraph-classes eg) r1 (set-union s1 s2))
    (hash-remove! (qb-egraph-classes eg) r2)
    (set-qb-egraph-merges! eg (add1 (qb-egraph-merges eg))))
  r1)

(define (qb-rebuild! eg)
  (let loop ()
    (define changed? #f)
    (for ([(cid nds) (in-hash (hash-copy (qb-egraph-classes eg)))])
      (define root (qb-find! eg cid))
      (define rebuilt
        (for/set ([nd (in-set nds)])
          (define cnd (qb-canon eg nd))
          (when (hash-has-key? (qb-egraph-hashcons eg) cnd)
            (define prev-id (qb-find! eg (hash-ref (qb-egraph-hashcons eg) cnd)))
            (unless (= prev-id root)
              (qb-merge! eg root prev-id)
              (set! changed? #t)))
          (hash-set! (qb-egraph-hashcons eg) cnd (qb-find! eg root))
          cnd))
      (hash-set! (qb-egraph-classes eg) (qb-find! eg root) rebuilt))
    (when changed? (loop))))

(define (qb-egraph-add! eg expr)
  (match expr
    [`(qblock-pauli ,sym ,sq ,decl)
     (qb-add-enode! eg (qb-enode 'qblock-pauli '() (list sym sq decl)))]
    [`(qblock-lcu ,sym ,coeffs ,m-anc ,sq ,wb ,pk ,uk ,decl)
     (qb-add-enode! eg (qb-enode 'qblock-lcu '() (list sym coeffs m-anc sq wb pk uk decl)))]
    [`(qblock-sum ,wA ,a ,wB ,b)
     (qb-add-enode! eg (qb-enode 'qblock-sum
                                 (list (qb-egraph-add! eg a) (qb-egraph-add! eg b))
                                 (list wA wB)))]
    [`(qblock-product ,a ,b)
     (qb-add-enode! eg (qb-enode 'qblock-product
                                 (list (qb-egraph-add! eg a) (qb-egraph-add! eg b))
                                 '()))]
    [`(chebyshev-naive ,d ,a)
     (qb-add-enode! eg (qb-enode 'chebyshev-naive
                                 (list (qb-egraph-add! eg a))
                                 (list d)))]
    [`(qsvt-reflection-fused ,d ,a ,phis)
     (qb-add-enode! eg (qb-enode 'qsvt-reflection-fused
                                 (list (qb-egraph-add! eg a))
                                 (list d phis)))]))

(define (qb-egraph-saturate! eg [max-iters 8])
  (for ([_ (in-range max-iters)])
    (define snapshot (hash-copy (qb-egraph-classes eg)))
    (for ([(cid nds) (in-hash snapshot)])
      (define root (qb-find! eg cid))
      (for ([nd (in-set nds)])
        (match nd
          ;; Rule 1: `Law U4` Berry-Gidney `PREP-dagger` table uncomputation
          [(qb-enode 'qblock-lcu '() (list sym coeffs m-anc sq wb 'nested-dyadic-walker-alias 'unitary-sawtooth decl))
           (define bg-id
             (qb-add-enode! eg (qb-enode 'qblock-lcu '()
                                         (list sym coeffs m-anc sq wb
                                               'nested-dyadic-walker-alias
                                               'berry-gidney-mx-u4
                                               decl))))
           (qb-merge! eg root bg-id)]
          ;; Rule 2: Chebyshev QSVT reflection fusion (`d * m_anc -> m_anc + 1`, `alpha -> 1`)
          [(qb-enode 'chebyshev-naive (list sub-cid) (list d))
           (define phis (cons 0.0 (make-list (max 0 (sub1 d)) (/ pi 2.0))))
           (define fused-id
             (qb-add-enode! eg (qb-enode 'qsvt-reflection-fused
                                         (list (qb-find! eg sub-cid))
                                         (list d phis))))
           (qb-merge! eg root fused-id)]
          [_ (void)])))
    (qb-rebuild! eg)))

;; Lexicographic optimality over `(m_anc, alpha, temp_and_cost)`:
(define (qblock-cost-tuple qt)
  (list (if (qblock-type-well-typed? qt) 0 1)
        (qblock-type-m-anc qt)
        (inexact->exact (round (* 1000000 (qblock-type-alpha qt))))
        (qblock-type-temp-and-cost qt)))

(define (tuple<? a b)
  (cond
    [(null? a) #f]
    [(< (car a) (car b)) #t]
    [(> (car a) (car b)) #f]
    [else (tuple<? (cdr a) (cdr b))]))

(define (qb-egraph-extract-optimal eg root-id #:target [target-sym 'heron-r2])
  (define best-ast (make-hash))
  (define best-type (make-hash))
  (let fixpoint ()
    (define updated? #f)
    (for ([(cid nds) (in-hash (qb-egraph-classes eg))])
      (define r (qb-find! eg cid))
      (for ([nd (in-set nds)])
        (define children-ready?
          (for/and ([ch (in-list (qb-enode-children nd))])
            (hash-has-key? best-ast (qb-find! eg ch))))
        (when children-ready?
          (define ch-asts
            (map (lambda (ch) (hash-ref best-ast (qb-find! eg ch)))
                 (qb-enode-children nd)))
          (define cand-ast
            (match nd
              [(qb-enode 'qblock-pauli '() (list sym sq decl))
               `(qblock-pauli ,sym ,sq ,decl)]
              [(qb-enode 'qblock-lcu '() (list sym coeffs m-anc sq wb pk uk decl))
               `(qblock-lcu ,sym ,coeffs ,m-anc ,sq ,wb ,pk ,uk ,decl)]
              [(qb-enode 'qblock-sum _ (list wA wB))
               `(qblock-sum ,wA ,(first ch-asts) ,wB ,(second ch-asts))]
              [(qb-enode 'qblock-product _ '())
               `(qblock-product ,(first ch-asts) ,(second ch-asts))]
              [(qb-enode 'chebyshev-naive _ (list d))
               `(chebyshev-naive ,d ,(first ch-asts))]
              [(qb-enode 'qsvt-reflection-fused _ (list d phis))
               `(qsvt-reflection-fused ,d ,(first ch-asts) ,phis)]))
          (define cand-t (infer-qblock-type cand-ast #:target target-sym))
          (when (or (not (hash-has-key? best-type r))
                    (tuple<? (qblock-cost-tuple cand-t)
                             (qblock-cost-tuple (hash-ref best-type r))))
            (hash-set! best-ast r cand-ast)
            (hash-set! best-type r cand-t)
            (set! updated? #t)))))
    (when updated? (fixpoint)))
  (define rr (qb-find! eg root-id))
  (values (hash-ref best-ast rr) (hash-ref best-type rr)))

;; =============================================================================
;; 5. Negative Soundness Audit (`Laws U1, U2, U4` Block-Encoding Rejections)
;; =============================================================================

(define (audit-negative-qblock-programs)
  ;; Negative Program 1 (`Law U1` dirty `SELECT` scratch ancilla):
  ;; `s_dirty` (`q[5]`) is computed via `temp-and` inside `SELECT` and NOT erased!
  (define dirty-select-decl
    (lfq-circuit-decl
     'ill-typed-dirty-select-u1
     'defq
     '((sys . (0 1)) (blk . (2 3)))
     '((s_dirty . (4)))
     '(0 1 2 3)
     '(4)
     'all
     '(seq
       (h 2) (h 3)
       (temp-and 2 3 4)
       (cx 4 0)
       (h 2) (h 3))))
  (define bad-u1-type
    (infer-qblock-type
     `(qblock-lcu H_dirty_u1 (0.75 0.50 0.50 0.25) 2 2 1
                  nested-dyadic-walker-alias berry-gidney-mx-u4 ,dirty-select-decl)))

  ;; Negative Program 2 (`Law U4` unfixed Berry-Gidney `M_X` `PREP-dagger` kickback):
  ;; Measures Walker table scratch `q[4]` in `mid-meas-x` (`m_tbl_unfixed`) and
  ;; omits `(cond-cz 'm_tbl_unfixed 2 3)` before `PREP-dagger` Hadamards!
  (define unfixed-mx-decl
    (lfq-circuit-decl
     'ill-typed-unfixed-mx-prep-dag-u4
     'defq
     '((sys . (0 1)) (blk . (2 3)))
     '((tbl . (4)))
     '(0 1 2 3)
     '(4)
     'all
     '(seq
       (h 2) (h 3)
       (temp-and 2 3 4)
       (cz 4 0)
       (mid-meas-x 4 m_tbl_unfixed #t)
       ;; MISSING: `(cond-cz 'm_tbl_unfixed 2 3)`!
       (h 2) (h 3))))
  (define bad-u4-type
    (infer-qblock-type
     `(qblock-lcu H_unfixed_u4 (0.75 0.50 0.50 0.25) 2 2 1
                  nested-dyadic-walker-alias berry-gidney-mx-u4 ,unfixed-mx-decl)))

  ;; Negative Program 3 (`Law U2` non-canonical `PREP` box):
  (define bad-u2-type
    (infer-qblock-type
     `(qblock-lcu H_noncanonical_u2 (0.75 0.50 0.50 0.25) 2 2 1
                  noncanonical-raw-alias berry-gidney-mx-u4 #f)))

  (when (or (qblock-type-well-typed? bad-u1-type)
            (qblock-type-well-typed? bad-u4-type)
            (qblock-type-well-typed? bad-u2-type))
    (error 'audit-negative-qblock-programs
           "Expected all 3 ill-typed QBlock programs (U1, U4, U2) to be statically rejected!"))

  (hasheq
   'dirty_select_u1_rejected (not (qblock-type-well-typed? bad-u1-type))
   'dirty_select_u1_violations (qblock-type-violations bad-u1-type)
   'unfixed_berry_gidney_u4_rejected (not (qblock-type-well-typed? bad-u4-type))
   'unfixed_berry_gidney_u4_violations (qblock-type-violations bad-u4-type)
   'noncanonical_walker_u2_rejected (not (qblock-type-well-typed? bad-u2-type))
   'noncanonical_walker_u2_violations (qblock-type-violations bad-u2-type)))

;; =============================================================================
;; 6. Full End-to-End Verification & JSON Summary Bundle
;; =============================================================================

(define (run-qblock-qsvt-compiler-verification)
  ;; 1. Compile runnable `#lang lakefillq` example `examples/hubbard_lcu_qsvt_block.lfq`:
  (define hubbard-prog (load-lfq-program-from-file hubbard-example-lfq-path))
  (define hubbard-decls (lfq-program-circuits hubbard-prog))
  (define uh-decl (first hubbard-decls))
  (define t2-decl (second hubbard-decls))
  (define uh-res (compile-lfq-circuit uh-decl 'heron-r2))
  (define t2-res (compile-lfq-circuit t2-decl 'heron-r2))
  (unless (and (compilation-result-well-typed? uh-res)
               (compilation-result-well-typed? t2-res))
    (error 'run-qblock-qsvt-compiler-verification
           "examples/hubbard_lcu_qsvt_block.lfq failed QSub/QPhysGrade verification!"))

  ;; 2. Verify `QBlock` LCU sum, naive product, & `e-graph` Chebyshev QSVT fusion
  ;;    for d in {1, 2, 3} on 2-qubit (`m_anc = 2`) Hubbard LCU Hamiltonian (`alpha = 2.0`):
  (define base-hubbard-sawtooth
    '(qblock-lcu H_hubbard_2site (0.75 0.50 0.50 0.25) 2 2 4
                 nested-dyadic-walker-alias unitary-sawtooth #f))
  (define base-hubbard-bg
    '(qblock-lcu H_hubbard_2site (0.75 0.50 0.50 0.25) 2 2 4
                 nested-dyadic-walker-alias berry-gidney-mx-u4 #f))
  (define sum-type
    (infer-qblock-type `(qblock-sum 1.0 ,base-hubbard-bg 1.0 ,base-hubbard-bg) #:target 'heron-r2))
  (define prod-type
    (infer-qblock-type `(qblock-product ,base-hubbard-bg ,base-hubbard-bg) #:target 'heron-r2))
  (unless (and (= (qblock-type-alpha sum-type) 4.0)
               (= (qblock-type-m-anc sum-type) 3)
               (= (qblock-type-alpha prod-type) 4.0)
               (= (qblock-type-m-anc prod-type) 4))
    (error 'run-qblock-qsvt-compiler-verification
           "LCU sum or naive product subnormalization / m_anc rule failed!"))

  (define cheb-fusion-table
    (for/list ([d (in-list '(1 2 3))])
      (define naive-expr `(chebyshev-naive ,d ,base-hubbard-sawtooth))
      (define naive-t (infer-qblock-type naive-expr #:target 'heron-r2))
      (define fused-direct-t
        (infer-qblock-type
         `(qsvt-reflection-fused ,d ,base-hubbard-bg ,(cons 0.0 (make-list (sub1 d) (/ pi 2.0))))
         #:target 'heron-r2))
      (define eg (make-qb-egraph))
      (define rid (qb-egraph-add! eg naive-expr))
      (qb-egraph-saturate! eg)
      (define-values (opt-ast opt-t)
        (qb-egraph-extract-optimal eg rid #:target 'heron-r2))
      (unless (and (qblock-type-well-typed? opt-t)
                   (= (qblock-type-m-anc fused-direct-t) 3)
                   (= (qblock-type-m-anc opt-t) (if (= d 1) 2 3))
                   (= (qblock-type-alpha opt-t) 1.0)
                   (eq? (qblock-type-prep-uncomp-kind opt-t) 'berry-gidney-mx-u4))
        (error 'run-qblock-qsvt-compiler-verification
               "Unexpected QSVT extraction for d=~a: ~a" d opt-t))
      (hasheq 'degree_d d
              'naive_m_anc (qblock-type-m-anc naive-t)
              'qsvt_bus_m_anc (qblock-type-m-anc fused-direct-t)
              'egraph_optimal_m_anc (qblock-type-m-anc opt-t)
              'naive_alpha (qblock-type-alpha naive-t)
              'fused_qsvt_alpha (qblock-type-alpha opt-t)
              'naive_temp_ands (qblock-type-temp-and-cost naive-t)
              'fused_temp_ands (qblock-type-temp-and-cost opt-t)
              'extracted_ast (format "~s" opt-ast))))

  ;; 3. Verify `Law U4` Berry-Gidney `PREP-dagger` scaling across `L in {16, 64, 256, 1024, 2048}` (`W = 32`):
  (define checked-diff-pairs (verify-differential-f2-phase-bank-truth-table))
  (define prep-dag-scaling
    (for/list ([L-terms (in-list '(16 64 256 1024 2048))])
      (define saw-ccx (sawtooth-unitary-prep-dag-ccx L-terms 32))
      (define bg-ands (berry-gidney-prep-dag-temp-ands L-terms 32))
      (define bg-w64  (berry-gidney-prep-dag-temp-ands L-terms 64))
      (define bg-w128 (berry-gidney-prep-dag-temp-ands L-terms 128))
      (unless (= bg-ands bg-w64 bg-w128)
        (error 'run-qblock-qsvt-compiler-verification
               "Berry-Gidney TempAND count depended on word width W at L=~a" L-terms))
      (define ratio (/ (exact->inexact saw-ccx) (exact->inexact bg-ands)))
      (hasheq 'L_terms L-terms
              'word_width_W 32
              'unitary_sawtooth_ccx saw-ccx
              'berry_gidney_u4_temp_ands bg-ands
              'reduction_factor (/ (round (* ratio 100.0)) 100.0)
              'width_independent_across_32_64_128 #t)))

  ;; Exact `L = 1024 -> 61` (`16.75x`) and `L = 2048 -> 91` (`22.48x`) assertions:
  (unless (and (= (sawtooth-unitary-prep-dag-ccx 1024 32) 1022)
               (= (berry-gidney-prep-dag-temp-ands 1024 32) 61)
               (= (sawtooth-unitary-prep-dag-ccx 2048 32) 2046)
               (= (berry-gidney-prep-dag-temp-ands 2048 32) 91))
    (error 'run-qblock-qsvt-compiler-verification
           "Exact L=1024 (61 vs 1022) or L=2048 (91 vs 2046) TempAND milestone failed!"))

  ;; 4. Verify `FeMoCo` (`L = 2048, alpha = 1500 Ha, eps = 1e-3 Ha, m_anc = 12`) QBlock e-Graph fusion:
  (define femoco-sawtooth
    `(qblock-lcu H_FeMoCo ,(make-list 2048 (/ 1500.0 2048.0)) 12 76 32
                 nested-dyadic-walker-alias unitary-sawtooth #f))
  (define femoco-eg (make-qb-egraph))
  (define femoco-rid (qb-egraph-add! femoco-eg `(chebyshev-naive 16 ,femoco-sawtooth)))
  (qb-egraph-saturate! femoco-eg)
  (define-values (_femoco-ast femoco-opt-t)
    (qb-egraph-extract-optimal femoco-eg femoco-rid #:target 'bb-qldpc))
  (unless (and (= (qblock-type-m-anc femoco-opt-t) 13)
               (= (qblock-type-alpha femoco-opt-t) 1.0)
               (eq? (qblock-type-prep-uncomp-kind femoco-opt-t) 'berry-gidney-mx-u4))
    (error 'run-qblock-qsvt-compiler-verification "FeMoCo QBlock extraction failed!"))

  ;; 5. Verify negative soundness rejections (`U1`, `U4`, `U2`):
  (define neg-audit (audit-negative-qblock-programs))

  (hasheq
   'status "PASS"
   'example_lfq_path "examples/hubbard_lcu_qsvt_block.lfq"
   'hubbard_uh_compilation (compilation-result->jsexpr uh-res)
   'hubbard_qsvt_t2_compilation (compilation-result->jsexpr t2-res)
   'chebyshev_qsvt_egraph_fusion cheb-fusion-table
   'berry_gidney_prep_dag_scaling prep-dag-scaling
   'differential_f2_phase_bank_pairs_verified checked-diff-pairs
   'femoco_d16_qsvt_extraction
   (hasheq 'naive_m_anc (* 16 12)
           'fused_qsvt_m_anc (qblock-type-m-anc femoco-opt-t)
           'fused_alpha (qblock-type-alpha femoco-opt-t)
           'prep_dag_mode (symbol->string (qblock-type-prep-uncomp-kind femoco-opt-t)))
   'negative_soundness_audit neg-audit))

(module+ main
  (define emit-json? #f)
  (command-line
   #:program "lakefillq-block-encoding-qsvt"
   #:once-each
   [("--emit-json") "Emit structured QBlock + QSVT verification JSON to stdout"
    (set! emit-json? #t)])
  (define summary (run-qblock-qsvt-compiler-verification))
  (when emit-json?
    (write-json summary)
    (newline)))
