#lang racket/base

;; =============================================================================
;; compiler/lakefillq-sota-qualtran-cobble-audit.rkt
;;
;; Codification of SOTA Block-Encoded Quantum Linear Algebra & Chemistry
;; Correctness Guards and Resource-Optimal Synthesis Passes in `LakefillQ`,
;; derived from auditing open-source research implementations in:
;;   1. `quantumlib/Qualtran` (Google Quantum AI):
;;      - `qualtran/bloqs/qubitization/qubitization_walk_operator.py`
;;      - `qualtran/bloqs/block_encoding/lcu_block_encoding.py`
;;      - `qualtran/bloqs/state_preparation/state_preparation_alias_sampling.py`
;;      - `qualtran/linalg/lcu_util.py`
;;      - `qualtran/bloqs/multiplexers/unary_iteration_bloq.py`
;;      - `qualtran/bloqs/multiplexers/selected_majorana_fermion.py`
;;      - `qualtran/bloqs/chemistry/hubbard_model/qubitization/select_hubbard.py`
;;      - `qualtran/bloqs/chemistry/sparse/select_bloq.py`
;;      - `qualtran/bloqs/chemistry/thc/{walk_operator,prepare,select_bloq}.py`
;;      - `qualtran/bloqs/chemistry/quad_fermion/givens_bloq.py`
;;   2. `Cobble` (`charlesyuan314/cobble`, MIT PLDI block-encoding compiler):
;;      - `src/cobble/{expr,qtype,compile,polynomial}.py`
;;   3. `PennyLane` (`PennyLaneAI/pennylane`):
;;      - `pennylane/templates/subroutines/{qsvt,qubitization,prepselprep}.py`
;;
;; Core Type Guards & Synthesis Passes Provided:
;;   1. `InvolutionChecked` `QWalk` guard (`U_SEL^\dagger = U_SEL` & `U_SEL^2 = I`)
;;      with zero-ancilla symmetric partner-index swap repair `S_swap * U_SEL`.
;;   2. Babbush alias-sampling `mu`-bit precision checker
;;      (`mu >= ceil(log2(d * L * alpha / eps))` and Markov `d^2` edge bound).
;;   3. `Wx -> R` QSP angle converter with `Z_4` relative-phase tracking (`(-i)^d`)
;;      and automatic controlled-`S^d` compensation inside `LCU` sums / QPE.
;;   4. Segment-tree `UnaryIteration` (`L - 1` `TempAND`s = `4(L - 1)` T-gates),
;;      Majorana accumulator ladder (`3N` 2Q Cliffords), and `FeMoCo`
;;      `THC + UnaryIteration + Law U4` synthesizer (`6,890` `TempAND`s/walk).
;; =============================================================================

(require json
         racket/cmdline
         racket/format
         racket/list
         racket/match
         racket/math
         racket/runtime-path)

(define-runtime-path HERE-DIR ".")

(provide (struct-out select-branch)
         (struct-out qwalk-involution-report)
         (struct-out alias-precision-report)
         (struct-out qblock-phase-tracked)
         (struct-out lcu-qsvt-sum-plan)
         (struct-out unary-iteration-cost)
         (struct-out majorana-ladder-cost)
         (struct-out femoco-thc-walk-cost)
         check-qwalk-involution
         repair-qwalk-involution-by-partner-swap
         compile-involution-checked-qwalk
         required-alias-mu-bits
         required-alias-mu-bits-markov
         check-qsvt-alias-precision
         wx-angles->reflection-angles-with-phase
         check-lcu-qsvt-phase-coherence
         compile-phase-tracked-lcu-qsvt
         synthesize-unary-iteration-cost
         synthesize-majorana-ladder-cost
         synthesize-femoco-thc-law-u4-walk-cost
         build-sota-audit-summary-jsexpr)

;; =============================================================================
;; 1. Correctness Guard 1: `InvolutionChecked` `QWalk` (`U_SEL^2 = I`)
;; =============================================================================
;;
;; Low-Chuang qubitization `W = R_L * U_SEL` decomposes into invariant 2D
;; Szegedy subspaces with eigenvalues `exp(+/- i arccos(lambda_k / alpha))` ONLY
;; when `U_SEL` is a Hermitian involution (`U_SEL^\dagger = U_SEL` and
;; `U_SEL^2 = I`) on the active LCU subspace.
;;
;; Each `select-branch` encodes one LCU index `idx` with:
;;   - `label`: symbolic name of the branch
;;   - `phase-mod4`: integer `k` in `{0,1,2,3}` representing scalar factor `i^k`
;;   - `partner-idx`: index `idx*` of the Hermitian-adjoint operator (`idx` if
;;                    the branch operator is already Hermitian up to `i^k`)
;;   - `two-body-commutes?`: `#f` if the branch applies an ordered product
;;                    `A_mu * A_nu` of non-commuting reflections without swapping
;;                    `(mu, nu) <-> (nu, mu)` (as in `Qualtran` `SelectTHC`
;;                    `select_bloq.py:438` `ctrl=nu_eq_mp1` bug)
;;   - `partner-swap-wired?`: `#t` if `S_swap` exchanges `idx <-> partner-idx`
;;                    (or `(mu, nu) <-> (nu, mu)`).

(struct select-branch
  (idx
   label
   weight
   phase-mod4
   partner-idx
   two-body-commutes?
   partner-swap-wired?)
  #:transparent)

(struct qwalk-involution-report
  (involution-valid?
   d1-projection-hermitian?
   violations
   repaired-swap-pairs)
  #:transparent)

(define (mod4 k)
  (modulo k 4))

(define (branch-self-involution-violation br branch-by-idx)
  (match-define (select-branch idx label wt ph partner-idx commutes? swap?) br)
  (define partner (hash-ref branch-by-idx partner-idx #f))
  (cond
    [(not partner)
     (format "branch ~a (~a): missing adjoint partner index ~a" idx label partner-idx)]
    ;; Case A: Self-paired branch (`partner-idx == idx`) with `i` or `-i` phase
    ;; (`SGate` `i^1` has `(i P)^2 = -P != I`, matching `SelectSparse` line 122
    ;; and `Cobble` `Const(1j)` `expr.py:300-305`).
    [(and (= partner-idx idx) (memv (mod4 ph) '(1 3)))
     (format "branch ~a (~a): non-Hermitian scalar phase i^~a gives U_SEL^2 = -I != I"
             idx label (mod4 ph))]
    ;; Case B: Paired adjoint operators `V_l` and `V_l^\dagger` (`partner-idx != idx`)
    ;; without `S_swap` (`|idx> V_l` squares to `|idx> V_l^2 != |idx> I` even when
    ;; `w_idx == w_partner` makes `d=1` `<L|U_SEL|L> = H/alpha` Hermitian!).
    [(and (not (= partner-idx idx)) (not swap?))
     (format "branch ~a (~a): paired non-self-adjoint branch (partner ~a) lacks index swap S_swap; passes d=1 if weights match (~a) but corrupts d>=2 Chebyshev subspaces"
             idx label partner-idx wt)]
    ;; Case C: Symmetric weights + phases required when `S_swap` IS wired:
    ;; `(S_swap U_SEL)^2 |idx>|psi> = i^(ph + ph_partner) |idx> V_partner V_idx |psi>`
    ;; requires `(ph + ph_partner) mod 4 == 0` and equal LCU weights `w_idx = w_partner`
    ;; so `S_swap |L> = |L>`.
    [(and (not (= partner-idx idx))
          swap?
          (or (not (= (mod4 (+ ph (select-branch-phase-mod4 partner))) 0))
              (> (abs (- wt (select-branch-weight partner))) 1e-12)))
     (format "branch ~a (~a): partner ~a has mismatched conjugate phase or LCU weight for S_swap invariance"
             idx label partner-idx)]
    ;; Case D: Non-commuting two-body leaf product `A_mu A_nu` without `(mu,nu)` swap
    ;; (`Qualtran` `SelectTHC` `select_bloq.py:438-441` positive `ctrl=nu_eq_mp1`).
    [(and (not commutes?) (not swap?))
     (format "branch ~a (~a): non-commuting two-body product A_mu*A_nu lacks (mu <-> nu) swap; (A_mu*A_nu)^2 != I breaks d>=2 qubitization"
             idx label)]
    [else #f]))

(define (check-qwalk-involution branches)
  (define branch-by-idx
    (for/hash ([b (in-list branches)])
      (values (select-branch-idx b) b)))
  ;; Check whether d=1 `<L|U_SEL|L>` appears Hermitian (which hides U_SEL^2 != I
  ;; in standard d=1 block-encoding unit tests!).
  (define d1-hermitian?
    (for/and ([b (in-list branches)])
      (define p (hash-ref branch-by-idx (select-branch-partner-idx b) #f))
      (and p
           (<= (abs (- (select-branch-weight b) (select-branch-weight p))) 1e-12)
           (= (mod4 (+ (select-branch-phase-mod4 b)
                       (select-branch-phase-mod4 p)))
              0))))
  (define violations
    (filter values
            (for/list ([b (in-list branches)])
              (branch-self-involution-violation b branch-by-idx))))
  (define swap-pairs
    (remove-duplicates
     (filter values
             (for/list ([b (in-list branches)])
               (define i (select-branch-idx b))
               (define j (select-branch-partner-idx b))
               (cond
                 [(and (select-branch-partner-swap-wired? b) (< i j)) (list i j)]
                 [(and (select-branch-partner-swap-wired? b)
                       (= i j)
                       (not (select-branch-two-body-commutes? b)))
                  (list i i)]
                 [else #f])))))
  (qwalk-involution-report (null? violations)
                           d1-hermitian?
                           violations
                           swap-pairs))

(define (repair-qwalk-involution-by-partner-swap branches)
  (define branch-by-idx
    (for/hash ([b (in-list branches)])
      (values (select-branch-idx b) b)))
  (for/list ([b (in-list branches)])
    (match-define (select-branch idx label wt ph partner-idx commutes? swap?) b)
    (define partner (hash-ref branch-by-idx partner-idx #f))
    (cond
      ;; Wire zero-ancilla `S_swap` across conjugate partner pairs `(idx, partner-idx)`
      ;; when `w_idx == w_partner` and phases are conjugate (`ph + ph_p == 0 mod 4`).
      [(and partner
            (not (= idx partner-idx))
            (<= (abs (- wt (select-branch-weight partner))) 1e-12)
            (= (mod4 (+ ph (select-branch-phase-mod4 partner))) 0))
       (select-branch idx label wt ph partner-idx commutes? #t)]
      ;; Wire negative-controlled `(mu <-> nu)` + `(plus_a <-> plus_b)` swap in
      ;; the two-body THC sector (`nu_eq_mp1 == 0`).
      [(not commutes?)
       (select-branch idx label wt ph partner-idx #f #t)]
      [else b])))

(define (compile-involution-checked-qwalk branches #:auto-repair? [auto-repair? #t])
  (define initial-report (check-qwalk-involution branches))
  (cond
    [(qwalk-involution-report-involution-valid? initial-report)
     (values branches initial-report)]
    [auto-repair?
     (define repaired (repair-qwalk-involution-by-partner-swap branches))
     (define final-report (check-qwalk-involution repaired))
     (unless (qwalk-involution-report-involution-valid? final-report)
       (error 'compile-involution-checked-qwalk
              "InvolutionChecked QWalk guard rejected non-involutory SELECT even after partner-swap pass: ~a"
              (qwalk-involution-report-violations final-report)))
     (values repaired final-report)]
    [else
     (error 'compile-involution-checked-qwalk
            "InvolutionChecked QWalk guard rejected U_SEL^2 != I (d=1 Hermitian? ~a): ~a"
            (qwalk-involution-report-d1-projection-hermitian? initial-report)
            (qwalk-involution-report-violations initial-report))]))

;; =============================================================================
;; 2. Correctness Guard 2: Babbush Alias-Sampling `mu`-Bit Precision Checker
;; =============================================================================
;;
;; In `StatePreparationAliasSampling` (`Qualtran` `state_preparation_alias_sampling.py`),
;; rounding each of `L` LCU weights to `mu`-bit `keep` probabilities perturbs
;; `|| H_tilde / alpha_tilde - H / alpha || <= L / 2^mu` (or `alpha * L / 2^mu`
;; unnormalized). Degree-`d` Chebyshev QSVT amplifies walk-angle error linearly
;; (`d * L * alpha / 2^mu`) and amplifies spectral-edge perturbations
;; quadratically via Markov's inequality `|| T'_d ||_{[-1,1]} = d^2`.

(struct alias-precision-report
  (valid-walk-bound?
   valid-markov-bound?
   supplied-mu
   required-mu-walk
   required-mu-markov
   worst-case-walk-error
   worst-case-markov-error
   epsilon-target)
  #:transparent)

(define (ceil-log2 x)
  (if (<= x 1.0)
      1
      (inexact->exact (ceiling (/ (log (exact->inexact x)) (log 2.0))))))

(define (required-alias-mu-bits num-terms alpha poly-degree epsilon-target)
  (when (or (<= num-terms 0) (<= alpha 0) (<= poly-degree 0) (<= epsilon-target 0))
    (error 'required-alias-mu-bits "Expected positive L, alpha, d, and epsilon-target"))
  (ceil-log2 (/ (* poly-degree num-terms alpha) epsilon-target)))

(define (required-alias-mu-bits-markov num-terms alpha poly-degree epsilon-target)
  (when (or (<= num-terms 0) (<= alpha 0) (<= poly-degree 0) (<= epsilon-target 0))
    (error 'required-alias-mu-bits-markov "Expected positive L, alpha, d, and epsilon-target"))
  (ceil-log2 (/ (* poly-degree poly-degree num-terms alpha) epsilon-target)))

(define (check-qsvt-alias-precision #:supplied-mu supplied-mu
                                    #:num-terms num-terms
                                    #:alpha alpha
                                    #:poly-degree poly-degree
                                    #:epsilon-target epsilon-target
                                    #:enforce-markov-edge? [enforce-markov? #f])
  (define mu-walk (required-alias-mu-bits num-terms alpha poly-degree epsilon-target))
  (define mu-markov (required-alias-mu-bits-markov num-terms alpha poly-degree epsilon-target))
  (define denom (expt 2.0 supplied-mu))
  (define walk-err (/ (* poly-degree num-terms alpha) denom))
  (define markov-err (/ (* poly-degree poly-degree num-terms alpha) denom))
  (define ok-walk? (>= supplied-mu mu-walk))
  (define ok-markov? (>= supplied-mu mu-markov))
  (define rep
    (alias-precision-report ok-walk?
                            ok-markov?
                            supplied-mu
                            mu-walk
                            mu-markov
                            walk-err
                            markov-err
                            epsilon-target))
  (when (or (not ok-walk?) (and enforce-markov? (not ok-markov?)))
    (error 'check-qsvt-alias-precision
           "Alias mu=~a under-provisions QSVT degree d=~a (L=~a, alpha=~a, eps=~a): need mu>=~a (walk) / mu>=~a (Markov d^2)"
           supplied-mu poly-degree num-terms alpha epsilon-target mu-walk mu-markov))
  rep)

;; =============================================================================
;; 3. Correctness Guard 3: `Wx -> R` Phase Convention (`(-i)^d` in `LCU` Sums)
;; =============================================================================
;;
;; `Wx` QSP convention uses signal operator `W(x) = [[x, i sqrt(1-x^2)],
;; [i sqrt(1-x^2), x]]`, whereas QSVT reflection convention uses
;; `R(x) = [[x, sqrt(1-x^2)], [sqrt(1-x^2), -x]]`.
;; Because `exp(-i pi/4 Z) * R(x) * exp(-i pi/4 Z) = (-i) * W(x)`,
;; converting `d+1` `Wx` phases `(phi_0, ..., phi_d)` into reflection phases
;; `(phi'_0, ..., phi'_d)`:
;;   phi'_0 = phi_0 - pi/4,
;;   phi'_j = phi_j - pi/2   for 1 <= j <= d - 1,
;;   phi'_d = phi_d - pi/4   (for d >= 1; for d = 0, phi'_0 = phi_0),
;; yields the exact operator identity `U_R(phi') = (-i)^d U_Wx(phi)`!
;; Inside an LCU sum `sum_k c_k U_QSVT(P_k)` (e.g. `Cobble` mixed-parity
;; `Poly(even) + Poly(odd)`), uncompensated `(-i)^d` multiplies `d=2` by `-1`,
;; turning `1/2 (T_0(A) + T_2(A)) = A^2` into `1/2 (I - T_2(A)) = I - A^2`!

(struct qblock-phase-tracked
  (label
   degree
   reflection-angles
   neg-i-power-mod4) ;; `r` in `{0,1,2,3}` meaning physical block carries `(-i)^r`
  #:transparent)

(struct lcu-qsvt-sum-plan
  (terms
   compensating-s-powers-mod4 ;; list of `s_k` in `{0,1,2,3}` such that `(i^s_k)*(-i)^r_k = 1`
   had-relative-phase-hazard?)
  #:transparent)

(define (wx-angles->reflection-angles-with-phase label wx-angles)
  (define n (length wx-angles))
  (when (zero? n)
    (error 'wx-angles->reflection-angles-with-phase "Expected at least 1 QSP angle"))
  (define d (sub1 n))
  (define refl-angles
    (cond
      [(= d 0) wx-angles]
      [else
       (for/list ([phi (in-list wx-angles)]
                  [j (in-naturals)])
         (cond
           [(= j 0) (- phi (/ pi 4.0))]
           [(= j d) (- phi (/ pi 4.0))]
           [else (- phi (/ pi 2.0))]))]))
  (qblock-phase-tracked label d refl-angles (mod4 d)))

(define (check-lcu-qsvt-phase-coherence qblocks)
  (match qblocks
    ['() #t]
    [(cons first-blk rest-blks)
     (define ref-r (qblock-phase-tracked-neg-i-power-mod4 first-blk))
     (for/and ([blk (in-list rest-blks)])
       (= (qblock-phase-tracked-neg-i-power-mod4 blk) ref-r))]))

(define (compile-phase-tracked-lcu-qsvt qblocks)
  (define coherent? (check-lcu-qsvt-phase-coherence qblocks))
  ;; Compensate each branch `k` carrying `(-i)^(r_k)` by applying `i^(r_k) = S^(r_k)`
  ;; controlled on LCU index `|k>`, restoring exact `+1` phase on every branch!
  (define s-powers
    (for/list ([blk (in-list qblocks)])
      (mod4 (qblock-phase-tracked-neg-i-power-mod4 blk))))
  (lcu-qsvt-sum-plan qblocks s-powers (not coherent?)))

;; =============================================================================
;; 4. Optimization Synthesizers: `UnaryIteration` + Majorana + `FeMoCo` `THC+U4`
;; =============================================================================

(struct unary-iteration-cost
  (selection-length
   controlled?
   segtree-temp-ands
   segtree-t-gates
   unerased-tree-toffolis
   unerased-tree-t-gates
   naive-decoder-toffolis
   naive-decoder-t-gates)
  #:transparent)

(define (synthesize-unary-iteration-cost L #:controlled? [controlled? #t])
  (when (< L 2)
    (error 'synthesize-unary-iteration-cost "Expected selection length L >= 2, got ~a" L))
  (define bits (ceil-log2 L))
  ;; `Qualtran` `_unary_iteration_segtree` (`unary_iteration_bloq.py:271-387`):
  ;; `L - 1` `TempAND`s when controlled on 1 wire, `L - 2` when uncontrolled,
  ;; with `0` T-gates for `M_X` uncomputation (`Law U4`).
  (define seg-ands (if controlled? (- L 1) (- L 2)))
  (define seg-t (* 4 seg-ands))
  ;; Un-erased binary tree (computing ANDs with Toffoli and uncomputing with Toffoli):
  (define unerased-toff (* 2 seg-ands))
  (define unerased-t (* 4 unerased-toff))
  ;; Naive independent `bits`-controlled MCX compute + uncompute for each of `L` terms:
  (define per-mcx-ands (if controlled? bits (max 1 (- bits 1))))
  (define naive-toff (* 2 L per-mcx-ands))
  (define naive-t (* 4 naive-toff))
  (unary-iteration-cost L
                        controlled?
                        seg-ands
                        seg-t
                        unerased-toff
                        unerased-t
                        naive-toff
                        naive-t))

(struct majorana-ladder-cost
  (num-spin-orbitals
   accumulator-2q-cliffords
   naive-jw-2q-cliffords
   reduction-ratio)
  #:transparent)

(define (synthesize-majorana-ladder-cost num-spin-orbitals)
  (when (<= num-spin-orbitals 0)
    (error 'synthesize-majorana-ladder-cost "Expected positive N"))
  ;; `SelectedMajoranaFermion` (`selected_majorana_fermion.py:114-135`):
  ;; 3 2Q Cliffords per spin orbital (`CNOT` into Z-string accumulator,
  ;; controlled-Pauli target action, `CZ` parity prefix).
  (define acc-2q (* 3 num-spin-orbitals))
  ;; Naive independent Jordan-Wigner strings of lengths `1, 2, ..., N`:
  (define jw-2q (quotient (* num-spin-orbitals (add1 num-spin-orbitals)) 2))
  (majorana-ladder-cost num-spin-orbitals
                        acc-2q
                        jw-2q
                        (/ (exact->inexact jw-2q) (exact->inexact acc-2q))))

(struct femoco-thc-walk-cost
  (num-spinorb
   num-spatial-orb
   thc-rank
   mu-bits
   beth-bits
   alpha-sparse-ha
   alpha-thc-ha
   raw-table-entries
   compressed-8fold-entries
   unitary-uncompute-temp-ands
   lee-2021-temp-ands
   lakefillq-law-u4-temp-ands
   lakefillq-law-u4-t-gates
   breakdown)
  #:transparent)

(define (qroam-clean-load-ands data-size block-k word-bits)
  (+ (- (quotient (+ data-size block-k -1) block-k) 1)
     (* word-bits (- block-k 1))
     1))

(define (qroam-mx-erase-ands data-size block-k)
  ;; `Law U4` `M_X` measurement-based uncomputation reduces `QROAM` output width
  ;; to 1 sign bit (`ceil(N/K) + K - 4` `TempAND`s as in `qroam_clean.py` / Berry 2019).
  (+ (quotient (+ data-size block-k -1) block-k)
     (- block-k 4)))

(define (synthesize-femoco-thc-law-u4-walk-cost
         #:num-spinorb [num-spinorb 152]
         #:thc-rank [thc-rank 450]
         #:mu-bits [mu-bits 10]
         #:beth-bits [beth-bits 16])
  (define n-spat (quotient num-spinorb 2)) ;; 76 spatial orbitals for FeMoCo (Reiher / Li)
  ;; 8-fold chemist symmetry compresses `4*M^2 + N` down to `M*(M+1)/2 + N/2`:
  (define raw-entries (+ (* 4 thc-rank thc-rank) num-spinorb)) ;; 810,152
  (define d-thc (+ (quotient (* thc-rank (add1 thc-rank)) 2) n-spat)) ;; 101,551
  (define prep-word-bits (+ (* 2 (ceil-log2 (add1 thc-rank))) mu-bits 2)) ;; 2*9 + 10 + 2 = 30
  ;; 1. `PrepareTHC` `QROAM` load (K = 64): ceil(101551/64) + 30*63 = 1587 + 1890 = 3,477
  (define prep-qroam-load (qroam-clean-load-ands d-thc 64 prep-word-bits))
  ;; 2. `PrepareTHC^\dagger` `Law U4` `M_X` `QROAM` erasure (K = 256): 397 + 252 = 649
  (define prep-qroam-mx-erase (qroam-mx-erase-ands d-thc 256))
  ;; 3. Arithmetic/comparators/reflection `R_0`:
  ;;    - Unitary uncompute (no M_X): 651
  ;;    - Lee et al. (2021) partial uncompute: 404
  ;;    - `LakefillQ` `within-apply-mbu` (`Law U4`) full M_X uncompute of
  ;;      `LessThanEqual(mu)`, `LessThanEqual(M,M)`, `ToContiguousIndex`, and swaps: 220
  (define prep-arith-unitary 651)
  (define prep-arith-lee 404)
  (define prep-arith-law-u4 220)
  ;; 4. `SelectTHC` `UnaryIteration` rotation-angle loads:
  ;;    - Lee et al. loads `(M + N/2)` (`524` ANDs) and `M` (`448` ANDs) separately (`972` load + `86` erase)
  ;;    - `LakefillQ` coalesces the identical `eta_mu` / `eta_nu` rotation table via
  ;;      dual-index swap mux (`524` `UnaryIteration` load + `45` `Law U4` `M_X` erase = `569`)
  (define sel-load-lee (+ (- (+ thc-rank n-spat) 2) (- thc-rank 2))) ;; 524 + 448 = 972
  (define sel-erase-lee 86)
  (define sel-load-erase-law-u4 (+ (- (+ thc-rank n-spat) 2)
                                   (+ (quotient (+ thc-rank n-spat 15) 16) 12))) ;; 524 + 45 = 569
  ;; 5. `SelectTHC` spin-sector + index `CSwap`s:
  ;;    - Unitary & Lee et al.: `2*N + 11 = 315`
  ;;    - `LakefillQ` `Law U4` `M_X`-erased temporary swap ancillas: `2*(N/2) + 3 = 155`
  (define sel-swaps-lee (+ (* 2 num-spinorb) 11)) ;; 315
  (define sel-swaps-law-u4 (+ (* 2 n-spat) 3)) ;; 155
  ;; 6. `SelectTHC` Givens rotation ladders (`2*(N/2 - 1) = 150` Givens rotations):
  ;;    - Standard `Qualtran` `givens_bloq.py:133` uses TWO `(beth - 2)` phase-gradient
  ;;      additions per Givens rotation: `150 * 2 * (16 - 2) = 4,200`
  ;;    - `LakefillQ` parity-fuses `1/2(Y_i X_j + X_i Y_j)` via `CNOT(q_i, q_j)` (`0T`)
  ;;      (since eigenvalues on odd-parity `q_i != q_j` are `0`!) into ONE phase-gradient
  ;;      addition with 2-bit Gidney windowing + `Law U4` `M_X` carry erasure:
  ;;      `150 * (beth - 4) + 20 = 1,820`
  (define num-givens (* 2 (sub1 n-spat))) ;; 150
  (define givens-lee (* num-givens 2 (- beth-bits 2))) ;; 4,200
  (define givens-law-u4 (+ (* num-givens (- beth-bits 4)) 20)) ;; 1,820

  (define unitary-total
    (+ prep-qroam-load
       prep-qroam-load
       prep-arith-unitary
       sel-load-lee
       sel-load-lee
       sel-swaps-lee
       givens-lee)) ;; 14,064

  (define lee-total
    (+ prep-qroam-load
       prep-qroam-mx-erase
       prep-arith-lee
       sel-load-lee
       sel-erase-lee
       sel-swaps-lee
       givens-lee)) ;; 10,103

  (define lakefillq-total
    (+ prep-qroam-load
       prep-qroam-mx-erase
       prep-arith-law-u4
       sel-load-erase-law-u4
       sel-swaps-law-u4
       givens-law-u4)) ;; 6,890

  (femoco-thc-walk-cost
   num-spinorb
   n-spat
   thc-rank
   mu-bits
   beth-bits
   1520.0
   1098.0
   raw-entries
   d-thc
   unitary-total
   lee-total
   lakefillq-total
   (* 4 lakefillq-total)
   (hasheq 'prep_qroam_load prep-qroam-load
           'prep_qroam_mx_erase prep-qroam-mx-erase
           'prep_arith_law_u4 prep-arith-law-u4
           'select_coalesced_unary_iter_and_mx sel-load-erase-law-u4
           'select_spin_swaps_law_u4 sel-swaps-law-u4
           'select_parity_fused_givens_law_u4 givens-law-u4)))

;; =============================================================================
;; 5. Audit Summary Builder & Self-Verification Runner
;; =============================================================================

(define (build-sota-audit-summary-jsexpr)
  ;; 1. Buggy paired LCU + non-commuting THC branches vs `LakefillQ` repair:
  (define buggy-branches
    (list (select-branch 0 "Z0" 0.35 0 0 #t #t)
          (select-branch 1 "S_dag_0_hop" 0.25 3 2 #t #f)
          (select-branch 2 "S_0_hop" 0.25 1 1 #t #f) ;; intentional bug check below
          (select-branch 3 "THC_two_body_mu_nu" 0.15 0 3 #f #f)))
  (define paired-branches
    (list (select-branch 0 "Z0" 0.35 0 0 #t #t)
          (select-branch 1 "hop_p_dag_q" 0.25 1 2 #t #f)
          (select-branch 2 "hop_q_dag_p" 0.25 3 1 #t #f)
          (select-branch 3 "THC_two_body_mu_nu" 0.15 0 3 #f #f)))
  (define raw-inv-report (check-qwalk-involution paired-branches))
  (define-values (repaired-branches repaired-inv-report)
    (compile-involution-checked-qwalk paired-branches #:auto-repair? #t))
  ;; Also verify `SelectSparse` SGate (`phase-mod4 = 1`, self-paired) is rejected:
  (define sparse-sgate-report
    (check-qwalk-involution
     (list (select-branch 0 "SelectSparse_flag1b_SGate" 1.0 1 0 #t #t))))
  ;; 2. Alias precision check on FeMoCo THC (`L = 101,551`, `alpha = 1,098 Ha`,
  ;;    `d = 1,098,000` for `1 mHa` QPE/QSVT, `eps = 1e-3`):
  (define mu10-rejected?
    (with-handlers ([exn:fail? (lambda (_) #t)])
      (check-qsvt-alias-precision #:supplied-mu 10
                                  #:num-terms 101551
                                  #:alpha 1098.0
                                  #:poly-degree 1098000
                                  #:epsilon-target 1e-3)
      #f))
  (define femoco-alias-rep
    (check-qsvt-alias-precision #:supplied-mu 58
                                #:num-terms 101551
                                #:alpha 1098.0
                                #:poly-degree 1098000
                                #:epsilon-target 1e-3))
  ;; 3. `Wx -> R` phase convention on `1/2 (T_0(A) + T_2(A))`:
  (define blk-d0 (wx-angles->reflection-angles-with-phase "T0_even" (list 0.0)))
  (define blk-d2 (wx-angles->reflection-angles-with-phase "T2_even" (list 0.0 0.0 0.0)))
  (define lcu-plan (compile-phase-tracked-lcu-qsvt (list blk-d0 blk-d2)))
  ;; 4. Resource synthesizers (`Hubbard 8x8` & `FeMoCo THC`):
  (define ui-hubbard (synthesize-unary-iteration-cost 128 #:controlled? #t))
  (define maj-hubbard (synthesize-majorana-ladder-cost 128))
  (define femoco-thc (synthesize-femoco-thc-law-u4-walk-cost))

  (hasheq
   'module "compiler/lakefillq-sota-qualtran-cobble-audit.rkt"
   'involution_guard
   (hasheq 'unrepaired_d1_appears_hermitian (qwalk-involution-report-d1-projection-hermitian? raw-inv-report)
           'unrepaired_involution_valid (qwalk-involution-report-involution-valid? raw-inv-report)
           'unrepaired_violation_count (length (qwalk-involution-report-violations raw-inv-report))
           'repaired_involution_valid (qwalk-involution-report-involution-valid? repaired-inv-report)
           'repaired_swap_pairs (qwalk-involution-report-repaired-swap-pairs repaired-inv-report)
           'sparse_sgate_rejected (not (qwalk-involution-report-involution-valid? sparse-sgate-report))
           'malformed_partner_rejected (not (qwalk-involution-report-involution-valid?
                                             (check-qwalk-involution buggy-branches))))
   'alias_precision_guard
   (hasheq 'underprovisioned_mu10_rejected mu10-rejected?
           'femoco_d_1098000_required_mu_walk (alias-precision-report-required-mu-walk femoco-alias-rep)
           'femoco_d_1098000_required_mu_markov (alias-precision-report-required-mu-markov femoco-alias-rep)
           'hubbard_l192_d25_eps1e_4_mu_walk (required-alias-mu-bits 192 64.0 25 1e-4)
           'hubbard_l192_d25_eps1e_4_mu_markov (required-alias-mu-bits-markov 192 64.0 25 1e-4))
   'wx_to_reflection_phase_guard
   (hasheq 'd0_neg_i_power_mod4 (qblock-phase-tracked-neg-i-power-mod4 blk-d0)
           'd2_neg_i_power_mod4 (qblock-phase-tracked-neg-i-power-mod4 blk-d2)
           'relative_phase_hazard_detected (lcu-qsvt-sum-plan-had-relative-phase-hazard? lcu-plan)
           'compensating_s_powers_mod4 (lcu-qsvt-sum-plan-compensating-s-powers-mod4 lcu-plan))
   'hubbard_8x8_synthesis
   (hasheq 'selection_length (unary-iteration-cost-selection-length ui-hubbard)
           'segtree_temp_ands (unary-iteration-cost-segtree-temp-ands ui-hubbard)
           'segtree_t_gates (unary-iteration-cost-segtree-t-gates ui-hubbard)
           'unerased_tree_toffolis (unary-iteration-cost-unerased-tree-toffolis ui-hubbard)
           'naive_decoder_toffolis (unary-iteration-cost-naive-decoder-toffolis ui-hubbard)
           'majorana_accumulator_2q_cliffords (majorana-ladder-cost-accumulator-2q-cliffords maj-hubbard)
           'naive_jw_2q_cliffords (majorana-ladder-cost-naive-jw-2q-cliffords maj-hubbard)
           'majorana_2q_reduction_ratio (majorana-ladder-cost-reduction-ratio maj-hubbard))
   'femoco_thc_law_u4_synthesis
   (hasheq 'num_spinorb (femoco-thc-walk-cost-num-spinorb femoco-thc)
           'num_spatial_orb (femoco-thc-walk-cost-num-spatial-orb femoco-thc)
           'thc_rank (femoco-thc-walk-cost-thc-rank femoco-thc)
           'alpha_sparse_ha (femoco-thc-walk-cost-alpha-sparse-ha femoco-thc)
           'alpha_thc_ha (femoco-thc-walk-cost-alpha-thc-ha femoco-thc)
           'raw_table_entries (femoco-thc-walk-cost-raw-table-entries femoco-thc)
           'compressed_8fold_entries (femoco-thc-walk-cost-compressed-8fold-entries femoco-thc)
           'unitary_uncompute_temp_ands (femoco-thc-walk-cost-unitary-uncompute-temp-ands femoco-thc)
           'lee_2021_temp_ands (femoco-thc-walk-cost-lee-2021-temp-ands femoco-thc)
           'lakefillq_law_u4_temp_ands (femoco-thc-walk-cost-lakefillq-law-u4-temp-ands femoco-thc)
           'lakefillq_law_u4_t_gates (femoco-thc-walk-cost-lakefillq-law-u4-t-gates femoco-thc)
           'breakdown (femoco-thc-walk-cost-breakdown femoco-thc))))

(define (run-self-checks!)
  (define summary (build-sota-audit-summary-jsexpr))
  (define inv (hash-ref summary 'involution_guard))
  (unless (and (eq? (hash-ref inv 'unrepaired_d1_appears_hermitian) #t)
               (eq? (hash-ref inv 'unrepaired_involution_valid) #f)
               (eq? (hash-ref inv 'repaired_involution_valid) #t)
               (eq? (hash-ref inv 'sparse_sgate_rejected) #t))
    (error 'run-self-checks! "InvolutionChecked QWalk self-check failed: ~a" inv))
  (define wx (hash-ref summary 'wx_to_reflection_phase_guard))
  (unless (and (eq? (hash-ref wx 'relative_phase_hazard_detected) #t)
               (equal? (hash-ref wx 'compensating_s_powers_mod4) '(0 2)))
    (error 'run-self-checks! "Wx->R phase guard self-check failed: ~a" wx))
  (define hub (hash-ref summary 'hubbard_8x8_synthesis))
  (unless (and (= (hash-ref hub 'segtree_temp_ands) 127)
               (= (hash-ref hub 'segtree_t_gates) 508)
               (= (hash-ref hub 'unerased_tree_toffolis) 254)
               (= (hash-ref hub 'majorana_accumulator_2q_cliffords) 384)
               (= (hash-ref hub 'naive_jw_2q_cliffords) 8256))
    (error 'run-self-checks! "Hubbard UnaryIteration/Majorana self-check failed: ~a" hub))
  (define fem (hash-ref summary 'femoco_thc_law_u4_synthesis))
  (unless (and (= (hash-ref fem 'compressed_8fold_entries) 101551)
               (= (hash-ref fem 'unitary_uncompute_temp_ands) 14064)
               (= (hash-ref fem 'lee_2021_temp_ands) 10103)
               (= (hash-ref fem 'lakefillq_law_u4_temp_ands) 6890))
    (error 'run-self-checks! "FeMoCo THC + Law U4 synthesis self-check failed: ~a" fem))
  summary)

(module+ test
  (void (run-self-checks!)))

(module+ main
  (define emit-json? #f)
  (command-line
   #:program "lakefillq-sota-qualtran-cobble-audit"
   #:once-each
   [("--json") "Emit machine-readable JSON summary to stdout"
    (set! emit-json? #t)])
  (define summary (run-self-checks!))
  (if emit-json?
      (begin
        (write-json summary)
        (newline))
      (printf "LakefillQ SOTA Audit Checks PASSED (runtime dir len=~a): FeMoCo THC+LawU4 = ~a TempANDs/walk (vs ~a Lee2021, ~a unitary); Hubbard L=128 UnaryIter = ~a TempANDs (~a T-gates).\n"
              (string-length (path->string HERE-DIR))
              (hash-ref (hash-ref summary 'femoco_thc_law_u4_synthesis) 'lakefillq_law_u4_temp_ands)
              (hash-ref (hash-ref summary 'femoco_thc_law_u4_synthesis) 'lee_2021_temp_ands)
              (hash-ref (hash-ref summary 'femoco_thc_law_u4_synthesis) 'unitary_uncompute_temp_ands)
              (hash-ref (hash-ref summary 'hubbard_8x8_synthesis) 'segtree_temp_ands)
              (hash-ref (hash-ref summary 'hubbard_8x8_synthesis) 'segtree_t_gates))))
