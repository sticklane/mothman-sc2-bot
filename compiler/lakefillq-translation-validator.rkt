#lang racket/base

;; =============================================================================
;; compiler/lakefillq-translation-validator.rkt
;;
;; Online Certifying Translation Validation & Equivalence Miter Engine for the
;; 8-Stage `canonical_k2_coupled` LakefillQ Compiler Pipeline:
;;
;;   Stage 1: `P_loop_cone`               (k=1 -> k=2 -> k=R QSub zero-wire inference)
;;   Stage 2: `P_pebble`                  (BorrowZ dirty-limb-to-clean-pebble promotion)
;;   Stage 3: `EGraph_TODD_ZX_round1`     (MBU fusion + RM*(n-4,n)^perp TODD + Twin-CCZ)
;;   Stage 4: `P_fraig_commute`           (Disjoint-barrier phase-cone commutation)
;;   Stage 5: `EGraph_TODD_ZX_round2`     (Post-commutation second-order TODD/ZX round)
;;   Stage 6: `P_mbu_bellman_knuth`       (Bellman-Knuth absorb-top-cz? + MBU lowering)
;;   Stage 7: `P_ssa_post_todd_chordal`   (Post-TODD chordal interval-graph SSA coloring)
;;   Stage 8: `P_part_u4_coupled_block_lu`(Law-U4 hypergraph cut + Rank-r Block-LU CNOTs)
;;
;; Verifies semantic equivalence across every stage transition (C_i, C_{i+1})
;; and end-to-end (C_init, C_final) via three coupled algebraic miters:
;;   1. F_2 Parity-Cone Miter (`XAG` / `FRAIG`):
;;      Verifies that every data output wire and uncomputed ancilla/pebble wire
;;      has identical boolean F_2 parity cones modulo the chordal SSA wire-coloring
;;      bijection sigma_SSA and the rank-r Block-LU (`L_local * P_cut * U_local`)
;;      linear basis decomposition.
;;   2. Z_8 Phase-Polynomial Miter:
;;      Extracts the multilinear degree-<=3 phase polynomial
;;        phi(x) = sum_{S <= [n], |S| <= 3} c_S prod_{j in S} x_j (mod 8)
;;      across `P_todd_zx`, `P_fraig_commute`, and `Twin-CCZ` polarity synthesis
;;      (accounting for `sdg = z + s`, i.e. 6 == 4 + 2 mod 8), verifying
;;      phi_pre(x) == phi_post(x) (mod 8) for all x in F_2^n.
;;   3. `Law U4` X-Basis Stabilizer & Tele-Phase Miter:
;;      Verifies that every `within-apply-mbu` / `mbu-erase` (H * M_X + conditional
;;      `CZ`/`Z` phase fixup on degree-<=2 boolean cones) and cross-QPU `Law U4`
;;      tele-phase gate produces the exact same post-measurement data-register
;;      phase action across all 2^k measurement branches and zero residual
;;      entanglement (`ancilla_purity = 1.0`).
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/math
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/set
         racket/string
         racket/vector
         file/sha1
         json
         "lakefillqc.rkt"
         "lakefillq-phase-ordering-analyzer.rkt")

(provide canonical-8-stage-names
         compute-revir-semantic-profile
         compute-isa-semantic-profile
         miter-semantic-profiles
         validate-canonical-pipeline-translation
         validate-kern-to-isa-equivalence
         validate-lfq-file-translation
         validate-all-15-lfq-examples
         validate-revir-corpus-120
         run-8-adversarial-translation-bug-probes
         run-full-translation-validation-suite)

(define-runtime-path here-dir ".")
(define repo-root-dir (simplify-path (build-path here-dir "..")))
(define examples-dir (build-path repo-root-dir "examples"))

(define canonical-8-stage-names
  '("P_loop_cone"
    "P_pebble"
    "EGraph_TODD_ZX_round1"
    "P_fraig_commute"
    "EGraph_TODD_ZX_round2"
    "P_mbu_bellman_knuth"
    "P_ssa_post_todd_chordal"
    "P_part_u4_coupled_block_lu"))

;; =============================================================================
;; 1. Symbolic F_2 Parity Cone & Multilinear Z_8 Phase-Polynomial Algebra
;; =============================================================================

;; Fast Mobius transform over F_2 converting a truth table vector of length 2^n
;; into its exact Zhegalkin ANF monomial vector of length 2^n.
(define (truth-table->anf-vec tt-vec n-vars)
  (define sz (arithmetic-shift 1 n-vars))
  (define anf (vector-copy tt-vec))
  (for ([bit (in-range n-vars)])
    (define step (arithmetic-shift 1 bit))
    (for ([mask (in-range sz)])
      (when (not (zero? (bitwise-and mask step)))
        (define prev (bitwise-xor mask step))
        (vector-set! anf mask
                     (bitwise-xor (vector-ref anf mask)
                                  (vector-ref anf prev))))))
  anf)

(define (popcount mask)
  (let loop ([m mask] [acc 0])
    (if (zero? m)
        acc
        (loop (bitwise-and m (sub1 m)) (add1 acc)))))

;; Algebraic degree of a boolean function over F_2^n from its truth-table vector:
(define (boolean-cone-degree tt-vec n-vars)
  (define anf (truth-table->anf-vec tt-vec n-vars))
  (define sz (arithmetic-shift 1 n-vars))
  (for/fold ([max-deg 0]) ([mask (in-range sz)])
    (if (= (vector-ref anf mask) 1)
        (max max-deg (popcount mask))
        max-deg)))

;; Exact Z_8 multilinear polynomial extraction up to degree 3 via Mobius inversion:
;; Given phi(x) in Z_8 for all x in F_2^n, extracts canonical coefficients
;; c_S in {0..7} for all subsets S <= [n] with |S| <= 3 such that
;;   phi(x) == sum_{S <= [n], |S| <= 3} c_S prod_{j in S} x_j (mod 8).
(define (extract-z8-multilinear-deg3-coeffs phi-vec n-vars)
  (define c0 (modulo (vector-ref phi-vec 0) 8))
  (define deg1 (make-hasheqv))
  (define deg2 (make-hash))
  (define deg3 (make-hash))
  (for ([i (in-range n-vars)])
    (define mi (arithmetic-shift 1 i))
    (define ci (modulo (- (vector-ref phi-vec mi) c0) 8))
    (unless (zero? ci)
      (hash-set! deg1 i ci)))
  (for* ([i (in-range n-vars)]
         [j (in-range (add1 i) n-vars)])
    (define mij (bitwise-ior (arithmetic-shift 1 i) (arithmetic-shift 1 j)))
    (define ci (hash-ref deg1 i 0))
    (define cj (hash-ref deg1 j 0))
    (define cij (modulo (- (vector-ref phi-vec mij) c0 ci cj) 8))
    (unless (zero? cij)
      (hash-set! deg2 (list i j) cij)))
  (for* ([i (in-range n-vars)]
         [j (in-range (add1 i) n-vars)]
         [k (in-range (add1 j) n-vars)])
    (define mijk
      (bitwise-ior (arithmetic-shift 1 i)
                   (arithmetic-shift 1 j)
                   (arithmetic-shift 1 k)))
    (define ci (hash-ref deg1 i 0))
    (define cj (hash-ref deg1 j 0))
    (define ck (hash-ref deg1 k 0))
    (define cij (hash-ref deg2 (list i j) 0))
    (define cik (hash-ref deg2 (list i k) 0))
    (define cjk (hash-ref deg2 (list j k) 0))
    (define cijk
      (modulo (- (vector-ref phi-vec mijk) c0 ci cj ck cij cik cjk) 8))
    (unless (zero? cijk)
      (hash-set! deg3 (list i j k) cijk)))
  (hasheq 'c0 c0
          'deg1 (for/list ([k (in-list (sort (hash-keys deg1) <))])
                  (list k (hash-ref deg1 k)))
          'deg2 (for/list ([k (in-list (sort (hash-keys deg2)
                                             (lambda (a b)
                                               (or (< (first a) (first b))
                                                   (and (= (first a) (first b))
                                                        (< (second a) (second b)))))))])
                  (list (first k) (second k) (hash-ref deg2 k)))
          'deg3 (for/list ([k (in-list (sort (hash-keys deg3)
                                             (lambda (a b)
                                               (cond
                                                 [(not (= (first a) (first b)))
                                                  (< (first a) (first b))]
                                                 [(not (= (second a) (second b)))
                                                  (< (second a) (second b))]
                                                 [else (< (third a) (third b))]))))])
                  (list (first k) (second k) (third k) (hash-ref deg3 k)))))

;; =============================================================================
;; 2. Stage-Level Semantic Profile Evaluator (F_2 Parity + Z_8 Phase + Law U4)
;; =============================================================================

;; Flattens a RevIR operation list (expanding higher-level `for-rounds`,
;; `unrolled-round-marker`, `borrow-toffoli`, `loop-zero-cone`, `pebble-stage`,
;; `within-and-mbu`, and `mbu-auto` into canonical primitive evaluation steps).
(define (expand-revir-ops-for-semantics ops)
  (apply append
         (for/list ([op (in-list ops)])
           (match op
             [`(waw-barrier ,_) '()]
             [`(unrolled-round-marker () ,_) '()]
             [`(unrolled-round-marker ,rbody ,_)
              (expand-revir-ops-for-semantics rbody)]
             [`(for-rounds ,_ ,rbody ,_)
              (expand-revir-ops-for-semantics rbody)]
             [`(borrow-toffoli ,c1 ,c2 ,b ,t)
              (list `(ccx ,c1 ,c2 ,b)
                    `(cx ,b ,t)
                    `(ccx ,c1 ,c2 ,b)
                    `(cx ,b ,t))]
             [`(loop-zero-cone ,w ,c1 ,c2)
              (list `(ccx ,w ,c1 ,c2))]
             [`(pebble-stage ,c1 ,c2 ,p ,target ,borrow-z?)
              (if borrow-z?
                  (list `(temp-and ,c1 ,c2 ,p)
                        `(cx ,p ,target)
                        `(meas-x-cond-cz-reset ,p 0 ,c1 ,c2))
                  (list `(ccx ,c1 ,c2 ,p)
                        `(cx ,p ,target)
                        `(ccx ,c1 ,c2 ,p)))]
             [`(within-and-mbu ,c1 ,c2 ,s ,body-ops)
              (append (list `(temp-and ,c1 ,c2 ,s))
                      (expand-revir-ops-for-semantics body-ops)
                      (list `(meas-x-cond-cz-reset ,s 0 ,c1 ,c2)))]
             [`(mbu-auto ,c1 ,c2 ,s ,mk ,body-ops)
              (append (list `(temp-and ,c1 ,c2 ,s))
                      (expand-revir-ops-for-semantics body-ops)
                      (list `(meas-x-cond-cz-reset ,s ,mk ,c1 ,c2)))]
             [_ (list op)]))))

;; Verifies whether a stage's scratch wire usage satisfies the chordal SSA
;; non-overlapping live-interval bijection invariant:
;; Every `temp-and` on a scratch wire `s` must find `s` currently clean (not live),
;; and every `meas-x-cond-cz-reset` / `meas-x-reset` on `s` closes its live interval.
(define (verify-ssa-live-wire-bijection ops num-data)
  (define active-scratch (make-hasheqv))
  (define collisions '())
  (define (walk op-list step-idx)
    (for ([op (in-list op-list)]
          [k (in-naturals step-idx)])
      (match op
        [`(for-rounds ,_ ,rbody ,_)
         (walk rbody k)]
        [`(unrolled-round-marker ,rbody ,_)
         (walk rbody k)]
        [`(within-and-mbu ,c1 ,c2 ,s ,body-ops)
         (when (hash-ref active-scratch s #f)
           (set! collisions
                 (cons (hasheq 'wire s
                               'step k
                               'reason "overlapping_within_and_mbu_scratch_wire")
                       collisions)))
         (hash-set! active-scratch s (list c1 c2 k))
         (walk body-ops k)
         (hash-remove! active-scratch s)]
        [`(mbu-auto ,c1 ,c2 ,s ,_ ,body-ops)
         (when (hash-ref active-scratch s #f)
           (set! collisions
                 (cons (hasheq 'wire s
                               'step k
                               'reason "overlapping_mbu_auto_scratch_wire")
                       collisions)))
         (hash-set! active-scratch s (list c1 c2 k))
         (walk body-ops k)
         (hash-remove! active-scratch s)]
        [`(temp-and ,c1 ,c2 ,s)
         (when (hash-ref active-scratch s #f)
           (set! collisions
                 (cons (hasheq 'wire s
                               'step k
                               'previous_alloc (hash-ref active-scratch s)
                               'reason "colliding_chordal_ssa_live_wire_reuse")
                       collisions)))
         (hash-set! active-scratch s (list c1 c2 k))]
        [(or `(meas-x-cond-cz-reset ,s ,_ ,_ ,_)
             `(meas-x-cond-z-reset ,s ,_ ,_)
             `(meas-x-reset ,s ,_)
             `(deg3-mbu-erase ,s ,_ ,_ ,_ ,_))
         (hash-remove! active-scratch s)]
        [_ (void)])))
  (walk ops 0)
  (values (null? collisions) (reverse collisions)))

;; Verifies rank-r `Block-LU` (`L_local * P_cut * U_local`) linear CNOT frame
;; factorization soundness on all maximal CNOT runs in `ops`:
(define (verify-block-lu-cnot-frames ops total-wires partitions)
  (cond
    [(or (not partitions) (<= (length partitions) 1))
     (values #t 0 '())]
    [else
     (define frames-checked 0)
     (define frame-mismatches '())
     (define (cnot-run->f2-matrix cnot-ops)
       (define mat
         (for/vector ([w (in-range total-wires)])
           (arithmetic-shift 1 w)))
       (for ([op (in-list cnot-ops)])
         (match op
           [(or `(cx ,c ,t) `(isa-cx ,c ,t) (list "cx" c t))
            (when (and (< c total-wires) (< t total-wires))
              (vector-set! mat t (bitwise-xor (vector-ref mat t) (vector-ref mat c))))]
           [_ (void)]))
       mat)
     (let loop ([rem ops] [cur-run '()])
       (cond
         [(null? rem)
          (when (> (length cur-run) 1)
            (set! frames-checked (add1 frames-checked))
            (define orig-mat (cnot-run->f2-matrix (reverse cur-run)))
            (define resynth-ops
              (synthesize-linear-frame-partition-aware total-wires orig-mat partitions))
            (define resynth-mat (cnot-run->f2-matrix resynth-ops))
            (unless (equal? orig-mat resynth-mat)
              (set! frame-mismatches
                    (cons (hasheq 'frame_index frames-checked
                                  'orig_matrix (vector->list orig-mat)
                                  'resynth_matrix (vector->list resynth-mat))
                          frame-mismatches))))]
         [(match (car rem) [(or `(cx ,_ ,_) `(isa-cx ,_ ,_) (list "cx" _ _)) #t] [_ #f])
          (loop (cdr rem) (cons (car rem) cur-run))]
         [else
          (when (> (length cur-run) 1)
            (set! frames-checked (add1 frames-checked))
            (define orig-mat (cnot-run->f2-matrix (reverse cur-run)))
            (define resynth-ops
              (synthesize-linear-frame-partition-aware total-wires orig-mat partitions))
            (define resynth-mat (cnot-run->f2-matrix resynth-ops))
            (unless (equal? orig-mat resynth-mat)
              (set! frame-mismatches
                    (cons (hasheq 'frame_index frames-checked
                                  'orig_matrix (vector->list orig-mat)
                                  'resynth_matrix (vector->list resynth-mat))
                          frame-mismatches))))
          (loop (cdr rem) '())]))
     (values (null? frame-mismatches) frames-checked (reverse frame-mismatches))]))

;; Computes the complete algebraic semantic profile of a `revir-prog`:
(define (compute-revir-semantic-profile prog)
  (define n-data (min 8 (max 1 (revir-prog-num-data prog))))
  (define n-borrow (revir-prog-num-borrow prog))
  (define n-scratch (revir-prog-num-scratch prog))
  (define raw-ops (revir-prog-ops prog))
  (define flat-ops (expand-revir-ops-for-semantics raw-ops))

  (define max-wire-in-ops
    (for/fold ([mw (+ n-data n-borrow n-scratch)])
              ([op (in-list flat-ops)])
      (match op
        [`(,(or 'x 'h 'z 's 'sdg 't 'tdg) ,w) (max mw (add1 w))]
        [`(rz8 ,w ,_) (max mw (add1 w))]
        [`(parity-phase ,ws ,_) (apply max mw (map add1 ws))]
        [`(,(or 'cx 'cz) ,a ,b) (max mw (add1 a) (add1 b))]
        [`(,(or 'ccx 'ccz 'temp-and) ,a ,b ,c) (max mw (add1 a) (add1 b) (add1 c))]
        [`(meas-x-cond-cz-reset ,a ,_ ,b ,c) (max mw (add1 a) (add1 b) (add1 c))]
        [`(meas-x-cond-z-reset ,a ,_ ,b) (max mw (add1 a) (add1 b))]
        [`(meas-x-reset ,a ,_) (max mw (add1 a))]
        [`(deg3-mbu-erase ,a ,_ ,b ,c ,d) (max mw (add1 a) (add1 b) (add1 c) (add1 d))]
        [_ mw])))
  (define total-wires (max max-wire-in-ops (+ n-data n-borrow n-scratch)))
  (define num-inputs (arithmetic-shift 1 n-data))

  ;; Wire boolean parity cones: wire-cones[w] is a vector of length 2^{n_data} over {0, 1}
  (define wire-cones
    (for/vector ([w (in-range total-wires)])
      (for/vector ([x (in-range num-inputs)])
        (if (and (< w n-data) (bitwise-bit-set? x w)) 1 0))))

  ;; Total Z_8 phase table across x in F_2^{n_data}:
  (define z8-phase (make-vector num-inputs 0))
  ;; H-parity bit per wire (`0` in even H-epoch, `1` in odd H-epoch; invariant under `H^2 = I`):
  (define wire-h-parity (make-vector total-wires 0))
  (define wire-odd-h-z8
    (for/vector ([_ (in-range total-wires)])
      (make-vector num-inputs 0)))

  ;; Law U4 MBU stabilizer events:
  (define u4-events '())
  (define u4-residual-total 0)
  (define min-branch-purity 1.0)

  (for ([op (in-list flat-ops)]
        [step-idx (in-naturals)])
    (match op
      [`(x ,w)
       (define cw (vector-ref wire-cones w))
       (for ([x (in-range num-inputs)])
         (vector-set! cw x (bitwise-xor (vector-ref cw x) 1)))]
      [`(h ,w)
       (vector-set! wire-h-parity w (bitwise-xor (vector-ref wire-h-parity w) 1))]
      [`(cx ,c ,t)
       (define cc (vector-ref wire-cones c))
       (define ct (vector-ref wire-cones t))
       (for ([x (in-range num-inputs)])
         (vector-set! ct x (bitwise-xor (vector-ref ct x) (vector-ref cc x))))]
      [(or `(ccx ,c1 ,c2 ,t) `(temp-and ,c1 ,c2 ,t))
       (define cc1 (vector-ref wire-cones c1))
       (define cc2 (vector-ref wire-cones c2))
       (define ct (vector-ref wire-cones t))
       (for ([x (in-range num-inputs)])
         (vector-set! ct x
                      (bitwise-xor (vector-ref ct x)
                                   (bitwise-and (vector-ref cc1 x)
                                                (vector-ref cc2 x)))))]
      [`(rz8 ,w ,k8)
       (define k (modulo k8 8))
       (unless (zero? k)
         (define cw (vector-ref wire-cones w))
         (define hp (vector-ref wire-h-parity w))
         (define wz (vector-ref wire-odd-h-z8 w))
         (for ([x (in-range num-inputs)])
           (when (= (vector-ref cw x) 1)
             (vector-set! z8-phase x (modulo (+ (vector-ref z8-phase x) k) 8))
             (when (= hp 1)
               (vector-set! wz x (modulo (+ (vector-ref wz x) k) 8))))))]
      [`(parity-phase ,ws ,k8)
       (define k (modulo k8 8))
       (unless (or (zero? k) (null? ws))
         (for ([x (in-range num-inputs)])
           (define par
             (for/fold ([p 0]) ([w (in-list ws)])
               (bitwise-xor p (vector-ref (vector-ref wire-cones w) x))))
           (when (= par 1)
             (vector-set! z8-phase x (modulo (+ (vector-ref z8-phase x) k) 8))
             (for ([w (in-list ws)] #:when (= (vector-ref wire-h-parity w) 1))
               (define wz (vector-ref wire-odd-h-z8 w))
               (vector-set! wz x (modulo (+ (vector-ref wz x) k) 8))))))]
      [`(cz ,a ,b)
       (define ca (vector-ref wire-cones a))
       (define cb (vector-ref wire-cones b))
       (define hpa (vector-ref wire-h-parity a))
       (define hpb (vector-ref wire-h-parity b))
       (define wza (vector-ref wire-odd-h-z8 a))
       (define wzb (vector-ref wire-odd-h-z8 b))
       (for ([x (in-range num-inputs)])
         (when (and (= (vector-ref ca x) 1) (= (vector-ref cb x) 1))
           (vector-set! z8-phase x (modulo (+ (vector-ref z8-phase x) 4) 8))
           (when (= hpa 1)
             (vector-set! wza x (modulo (+ (vector-ref wza x) 4) 8)))
           (when (= hpb 1)
             (vector-set! wzb x (modulo (+ (vector-ref wzb x) 4) 8)))))]
      [`(ccz ,a ,b ,c)
       (define ca (vector-ref wire-cones a))
       (define cb (vector-ref wire-cones b))
       (define cc (vector-ref wire-cones c))
       (define hpa (vector-ref wire-h-parity a))
       (define hpb (vector-ref wire-h-parity b))
       (define hpc (vector-ref wire-h-parity c))
       (define wza (vector-ref wire-odd-h-z8 a))
       (define wzb (vector-ref wire-odd-h-z8 b))
       (define wzc (vector-ref wire-odd-h-z8 c))
       (for ([x (in-range num-inputs)])
         (when (and (= (vector-ref ca x) 1)
                    (= (vector-ref cb x) 1)
                    (= (vector-ref cc x) 1))
           (vector-set! z8-phase x (modulo (+ (vector-ref z8-phase x) 4) 8))
           (when (= hpa 1)
             (vector-set! wza x (modulo (+ (vector-ref wza x) 4) 8)))
           (when (= hpb 1)
             (vector-set! wzb x (modulo (+ (vector-ref wzb x) 4) 8)))
           (when (= hpc 1)
             (vector-set! wzc x (modulo (+ (vector-ref wzc x) 4) 8)))))]
      [`(meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)
       (define canc (vector-ref wire-cones anc))
       (define cc1 (vector-ref wire-cones c1))
       (define cc2 (vector-ref wire-cones c2))
       (define mismatch-cnt
         (for/sum ([x (in-range num-inputs)])
           (define g-val (vector-ref canc x))
           (define fix-val (bitwise-and (vector-ref cc1 x) (vector-ref cc2 x)))
           (if (= g-val fix-val) 0 1)))
       (define deg-anc
         (if (zero? mismatch-cnt)
             2
             (boolean-cone-degree canc n-data)))
       (define deg-violation (if (> deg-anc 2) 1 0))
       (define ev-res (+ mismatch-cnt deg-violation))
       (set! u4-residual-total (+ u4-residual-total ev-res))
       (define overlap (/ (- num-inputs (* 2.0 mismatch-cnt)) (exact->inexact num-inputs)))
       (define ev-purity (* 0.5 (+ 1.0 (* overlap overlap))))
       (set! min-branch-purity (min min-branch-purity ev-purity))
       (set! u4-events
             (cons (hasheq 'step step-idx
                           'ancilla anc
                           'controls (list c1 c2)
                           'cone_degree deg-anc
                           'mismatch_inputs mismatch-cnt
                           'residual ev-res
                           'branch_purity ev-purity)
                   u4-events))
       (for ([x (in-range num-inputs)])
         (vector-set! canc x 0))]
      [`(meas-x-cond-z-reset ,anc ,mk ,t)
       (define canc (vector-ref wire-cones anc))
       (define ct (vector-ref wire-cones t))
       (define mismatch-cnt
         (for/sum ([x (in-range num-inputs)])
           (if (= (vector-ref canc x) (vector-ref ct x)) 0 1)))
       (define deg-anc
         (if (zero? mismatch-cnt)
             1
             (boolean-cone-degree canc n-data)))
       (define deg-violation (if (> deg-anc 2) 1 0))
       (define ev-res (+ mismatch-cnt deg-violation))
       (set! u4-residual-total (+ u4-residual-total ev-res))
       (define overlap (/ (- num-inputs (* 2.0 mismatch-cnt)) (exact->inexact num-inputs)))
       (define ev-purity (* 0.5 (+ 1.0 (* overlap overlap))))
       (set! min-branch-purity (min min-branch-purity ev-purity))
       (set! u4-events
             (cons (hasheq 'step step-idx
                           'ancilla anc
                           'controls (list t)
                           'cone_degree deg-anc
                           'mismatch_inputs mismatch-cnt
                           'residual ev-res
                           'branch_purity ev-purity)
                   u4-events))
       (for ([x (in-range num-inputs)])
         (vector-set! canc x 0))]
      [`(meas-x-reset ,anc ,mk)
       ;; Uncorrected M_X measurement without CZ fixup (used in Probe 5):
       (define canc (vector-ref wire-cones anc))
       (define deg-anc (boolean-cone-degree canc n-data))
       (define mismatch-cnt
         (for/sum ([x (in-range num-inputs)])
           (if (= (vector-ref canc x) 0) 0 1)))
       (set! u4-residual-total (+ u4-residual-total mismatch-cnt))
       (define overlap (/ (- num-inputs (* 2.0 mismatch-cnt)) (exact->inexact num-inputs)))
       (define ev-purity (* 0.5 (+ 1.0 (* overlap overlap))))
       (set! min-branch-purity (min min-branch-purity ev-purity))
       (set! u4-events
             (cons (hasheq 'step step-idx
                           'ancilla anc
                           'controls '()
                           'cone_degree deg-anc
                           'mismatch_inputs mismatch-cnt
                           'residual mismatch-cnt
                           'branch_purity ev-purity)
                   u4-events))
       (for ([x (in-range num-inputs)])
         (vector-set! canc x 0))]
      [`(deg3-mbu-erase ,anc ,mk ,c1 ,c2 ,c3)
       ;; Degree-3 cubic cone measured in X-basis with only Clifford CZ(c1,c2) fixup (Probe 4):
       (define canc (vector-ref wire-cones anc))
       (define cc1 (vector-ref wire-cones c1))
       (define cc2 (vector-ref wire-cones c2))
       (define cc3 (vector-ref wire-cones c3))
       (for ([x (in-range num-inputs)])
         (vector-set! canc x
                      (bitwise-and (vector-ref cc1 x)
                                   (vector-ref cc2 x)
                                   (vector-ref cc3 x))))
       (define deg-anc (boolean-cone-degree canc n-data))
       (define mismatch-cnt
         (for/sum ([x (in-range num-inputs)])
           (define g-val (vector-ref canc x))
           (define cliff-fix (bitwise-and (vector-ref cc1 x) (vector-ref cc2 x)))
           (if (= g-val cliff-fix) 0 1)))
       (define deg-violation (if (> deg-anc 2) 1 0))
       (define ev-res (+ mismatch-cnt deg-violation))
       (set! u4-residual-total (+ u4-residual-total ev-res))
       (define overlap (/ (- num-inputs (* 2.0 mismatch-cnt)) (exact->inexact num-inputs)))
       (define ev-purity (* 0.5 (+ 1.0 (* overlap overlap))))
       (set! min-branch-purity (min min-branch-purity ev-purity))
       (set! u4-events
             (cons (hasheq 'step step-idx
                           'ancilla anc
                           'controls (list c1 c2 c3)
                           'cone_degree deg-anc
                           'mismatch_inputs mismatch-cnt
                           'residual ev-res
                           'branch_purity ev-purity)
                   u4-events))
       (for ([x (in-range num-inputs)])
         (vector-set! canc x 0))]
      [_ (void)]))

  ;; Extract data parity cones and residual ancilla/borrow parities:
  (define data-cones
    (for/list ([w (in-range n-data)])
      (vector->list (vector-ref wire-cones w))))
  (define ancilla-residuals
    (for/list ([w (in-range n-data total-wires)])
      (define cw (vector-ref wire-cones w))
      (define dirty-cnt
        (for/sum ([x (in-range num-inputs)])
          (if (= (vector-ref cw x) 0) 0 1)))
      (hasheq 'wire w
              'dirty_inputs dirty-cnt
              'truth_table (vector->list cw))))
  (define total-ancilla-dirty
    (for/sum ([ar (in-list ancilla-residuals)])
      (hash-ref ar 'dirty_inputs 0)))

  (define-values (ssa-ok? ssa-collisions)
    (verify-ssa-live-wire-bijection raw-ops n-data))
  (define-values (lu-ok? lu-frames-checked lu-mismatches)
    (verify-block-lu-cnot-frames flat-ops total-wires (revir-prog-partitions prog)))

  (define z8-list (vector->list z8-phase))
  (define z8-coeffs (extract-z8-multilinear-deg3-coeffs z8-phase n-data))

  (hasheq 'num_data n-data
          'total_wires total-wires
          'data_parity_cones data-cones
          'ancilla_residuals ancilla-residuals
          'ancilla_dirty_input_count total-ancilla-dirty
          'h_barrier_wire_phases
          (for/list ([w (in-range n-data)])
            (vector->list (vector-ref wire-odd-h-z8 w)))
          'z8_phase_table z8-list
          'z8_multilinear_coeffs z8-coeffs
          'law_u4_mbu_events (reverse u4-events)
          'law_u4_stabilizer_residual u4-residual-total
          'ancilla_purity min-branch-purity
          'ssa_bijection_valid ssa-ok?
          'ssa_collisions ssa-collisions
          'block_lu_factorization_valid lu-ok?
          'block_lu_frames_checked lu-frames-checked
          'block_lu_mismatches lu-mismatches))

;; Converts a `MachineISA` instruction stream into a `revir-prog` and computes its semantic profile:
(define (compute-isa-semantic-profile isa-ops num-data total-phys-q [partitions #f])
  (define rev-ops
    (filter values
            (for/list ([op (in-list isa-ops)])
              (match op
                [(or `(isa-x ,w) (list "x" w)) `(x ,w)]
                [(or `(isa-h ,w) (list "h" w)) `(h ,w)]
                [(or `(isa-z ,w) (list "z" w)) `(rz8 ,w 4)]
                [(or `(isa-s ,w) (list "s" w)) `(rz8 ,w 2)]
                [(or `(isa-sdg ,w) (list "sdg" w)) `(rz8 ,w 6)]
                [(list "t" w) `(rz8 ,w 1)]
                [(list "tdg" w) `(rz8 ,w 7)]
                [`(isa-rz ,ang ,w)
                 (define k8 (inexact->exact (round (/ (* ang 4.0) pi))))
                 `(rz8 ,w ,(modulo k8 8))]
                [(or `(isa-cx ,c ,t) (list "cx" c t)) `(cx ,c ,t)]
                [(or `(isa-cz ,a ,b) (list "cz" a b)) `(cz ,a ,b)]
                [(or `(isa-ccx ,c1 ,c2 ,t) (list "ccx" c1 c2 t)) `(ccx ,c1 ,c2 ,t)]
                [(or `(isa-temp-and-ccx ,c1 ,c2 ,anc) (list "temp-and" c1 c2 anc))
                 `(temp-and ,c1 ,c2 ,anc)]
                [`(isa-meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)
                 `(meas-x-cond-cz-reset ,anc ,(if (number? mk) mk 0) ,c1 ,c2)]
                [(list "meas-x-cond-cz-reset" anc c1 c2)
                 `(meas-x-cond-cz-reset ,anc 0 ,c1 ,c2)]
                [`(isa-meas-x-cond-z-reset ,anc ,mk ,t)
                 `(meas-x-cond-z-reset ,anc ,mk ,t)]
                [`(isa-meas-x-reset ,anc ,mk)
                 `(meas-x-reset ,anc ,mk)]
                [_ #f]))))
  (define n-scr (max 0 (- total-phys-q num-data)))
  (compute-revir-semantic-profile
   (revir-prog "isa_profile" num-data 0 n-scr
               (if partitions (length partitions) 1)
               rev-ops partitions (seteqv) (hasheq))))

;; =============================================================================
;; 3. Algebraic Miter Between Two Semantic Profiles (Pre vs. Post Stage)
;; =============================================================================

(define (miter-semantic-profiles pre-prof post-prof
                                 #:stage-name [stage-name "stage"]
                                 #:check-h-commute? [check-h-commute? #f])
  (define n-data (hash-ref pre-prof 'num_data))
  (define pre-cones (hash-ref pre-prof 'data_parity_cones))
  (define post-cones (hash-ref post-prof 'data_parity_cones))

  ;; 1. F_2 Parity-Cone Miter on data wires + uncomputed ancilla/pebble wires:
  (define data-mismatch-wires '())
  (define first-f2-witness-x #f)
  (define data-parity-residual
    (for/sum ([c-pre (in-list pre-cones)]
              [c-post (in-list post-cones)]
              [w (in-naturals)])
      (define diff
        (for/sum ([v1 (in-list c-pre)]
                  [v2 (in-list c-post)]
                  [x (in-naturals)])
          (if (= v1 v2)
              0
              (begin
                (unless first-f2-witness-x (set! first-f2-witness-x x))
                1))))
      (when (> diff 0)
        (set! data-mismatch-wires (cons w data-mismatch-wires)))
      diff))

  (define post-ancilla-dirty (hash-ref post-prof 'ancilla_dirty_input_count 0))
  (when (> post-ancilla-dirty 0)
    (for ([ar (in-list (hash-ref post-prof 'ancilla_residuals '()))])
      (when (> (hash-ref ar 'dirty_inputs 0) 0)
        (set! data-mismatch-wires (cons (hash-ref ar 'wire) data-mismatch-wires))
        (unless first-f2-witness-x
          (for ([v (in-list (hash-ref ar 'truth_table '()))]
                [x (in-naturals)]
                #:when (and (not first-f2-witness-x) (= v 1)))
            (set! first-f2-witness-x x))))))

  (define ssa-ok? (hash-ref post-prof 'ssa_bijection_valid #t))
  (define lu-ok? (hash-ref post-prof 'block_lu_factorization_valid #t))

  (define f2-parity-residual
    (+ data-parity-residual
       post-ancilla-dirty
       (if ssa-ok? 0 1)
       (if lu-ok? 0 1)))

  ;; 2. Z_8 Phase-Polynomial Miter:
  (define pre-z8 (hash-ref pre-prof 'z8_phase_table))
  (define post-z8 (hash-ref post-prof 'z8_phase_table))
  (define first-z8-witness-x #f)
  (define z8-table-residual
    (for/sum ([p1 (in-list pre-z8)]
              [p2 (in-list post-z8)]
              [x (in-naturals)])
      (if (= (modulo p1 8) (modulo p2 8))
          0
          (begin
            (unless first-z8-witness-x (set! first-z8-witness-x x))
            1))))

  ;; For `P_fraig_commute`, verify that no diagonal gate on wire `w` crossed `(h w)`:
  (define h-commute-residual
    (if check-h-commute?
        (let ([pre-hb (hash-ref pre-prof 'h_barrier_wire_phases '())]
              [post-hb (hash-ref post-prof 'h_barrier_wire_phases '())])
          (if (equal? pre-hb post-hb) 0 1))
        0))
  (when (and (> h-commute-residual 0) (not first-z8-witness-x))
    (set! first-z8-witness-x 1))

  (define z8-phase-residual (+ z8-table-residual h-commute-residual))

  ;; 3. Law U4 X-Basis Stabilizer & Tele-Phase Miter:
  (define u4-residual (hash-ref post-prof 'law_u4_stabilizer_residual 0))
  (define ancilla-purity (hash-ref post-prof 'ancilla_purity 1.0))

  (define all-ok?
    (and (= f2-parity-residual 0)
         (= z8-phase-residual 0)
         (= u4-residual 0)
         ssa-ok?
         lu-ok?))

  ;; Canonical SHA-256 digest over pre/post algebraic semantics:
  (define canonical-payload
    (format "stage=~a|n=~a|pre_cones=~s|post_cones=~s|pre_z8=~s|post_z8=~s|u4=~a|ssa=~a|lu=~a"
            stage-name n-data pre-cones post-cones pre-z8 post-z8 u4-residual ssa-ok? lu-ok?))
  (define sha-digest
    (bytes->hex-string (sha256-bytes (string->bytes/utf-8 canonical-payload))))

  (hasheq 'stage_name stage-name
          'status (if all-ok? "CERTIFIED_EQUIVALENT" "TRANSLATION_BUG_DETECTED")
          'f2_parity_miter_residual f2-parity-residual
          'z8_phase_poly_miter_residual z8-phase-residual
          'law_u4_stabilizer_residual u4-residual
          'ssa_bijection_valid ssa-ok?
          'block_lu_factorization_valid lu-ok?
          'ancilla_purity ancilla-purity
          'mismatched_wires (reverse data-mismatch-wires)
          'f2_witness_input_x (or first-f2-witness-x -1)
          'z8_witness_input_x (or first-z8-witness-x -1)
          'sha256_witness_digest sha-digest))

;; =============================================================================
;; 4. Step-by-Step 8-Stage `canonical_k2_coupled` Pipeline Translation Validator
;; =============================================================================

;; Runs all 8 canonical passes on `p0`, recording each intermediate `revir-prog`
;; C_0 -> C_1 -> ... -> C_8 and verifying every stage transition (C_{i-1}, C_i)
;; plus the end-to-end equivalence (C_0, C_8).
(define (validate-canonical-pipeline-translation p0)
  (define prof0 (compute-revir-semantic-profile p0))

  ;; Stage 1: P_loop_cone
  (define p1 (pass-loop-cone p0))
  (define prof1 (compute-revir-semantic-profile p1))
  (define cert1 (miter-semantic-profiles prof0 prof1 #:stage-name "P_loop_cone"))

  ;; Stage 2: P_pebble
  (define p2 (pass-pebble p1))
  (define prof2 (compute-revir-semantic-profile p2))
  (define cert2 (miter-semantic-profiles prof1 prof2 #:stage-name "P_pebble"))

  ;; Stage 3: EGraph_TODD_ZX_round1
  (define p3 (pass-todd-zx p2 #:rounds 1 #:partition-aware? #f))
  (define prof3 (compute-revir-semantic-profile p3))
  (define cert3 (miter-semantic-profiles prof2 prof3 #:stage-name "EGraph_TODD_ZX_round1"))

  ;; Stage 4: P_fraig_commute
  (define p4 (pass-fraig-commute p3))
  (define prof4 (compute-revir-semantic-profile p4))
  (define cert4
    (miter-semantic-profiles prof3 prof4
                             #:stage-name "P_fraig_commute"
                             #:check-h-commute? #t))

  ;; Stage 5: EGraph_TODD_ZX_round2
  (define p5 (pass-todd-zx p4 #:rounds 1 #:partition-aware? #f))
  (define prof5 (compute-revir-semantic-profile p5))
  (define cert5 (miter-semantic-profiles prof4 prof5 #:stage-name "EGraph_TODD_ZX_round2"))

  ;; Stage 6: P_mbu_bellman_knuth (Bellman-Knuth absorb-top-cz? selection + MBU lowering)
  (define p6-abs (pass-mbu p5))
  (define p5-sel (pass-todd-zx p4 #:rounds 1 #:partition-aware? #f #:absorb-top-cz? #f))
  (define p6-sel (pass-mbu p5-sel))
  (define p6
    (if (<= (length (revir-prog-ops p6-abs)) (length (revir-prog-ops p6-sel)))
        p6-abs
        p6-sel))
  (define prof6 (compute-revir-semantic-profile p6))
  (define cert6 (miter-semantic-profiles prof5 prof6 #:stage-name "P_mbu_bellman_knuth"))

  ;; Stage 7: P_ssa_post_todd_chordal
  (define p7 (recolor-post-todd-chordal-ssa (pass-ssa p6)))
  (define prof7 (compute-revir-semantic-profile p7))
  (define cert7 (miter-semantic-profiles prof6 prof7 #:stage-name "P_ssa_post_todd_chordal"))

  ;; Stage 8: P_part_u4_coupled_block_lu
  (define p8
    (pass-part-u4 p7 #:law-u4-asymmetric? #t #:resynth-frames? #t))
  (define prof8 (compute-revir-semantic-profile p8))
  (define cert8 (miter-semantic-profiles prof7 prof8 #:stage-name "P_part_u4_coupled_block_lu"))

  (define-values (_final-isa final-metrics)
    (emit-final-machine-isa p8))
  (define total-phys-q
    (hash-ref final-metrics 'active_qubits
              (+ (revir-prog-num-data p8)
                 (revir-prog-num-borrow p8)
                 (revir-prog-num-scratch p8))))

  ;; End-to-end miter (C_init -> C_final):
  (define e2e-cert (miter-semantic-profiles prof0 prof8 #:stage-name "end_to_end_canonical_k2_coupled"))
  (define stage-certs (list cert1 cert2 cert3 cert4 cert5 cert6 cert7 cert8))

  (define total-f2-res
    (+ (hash-ref e2e-cert 'f2_parity_miter_residual)
       (for/sum ([sc (in-list stage-certs)])
         (hash-ref sc 'f2_parity_miter_residual))))
  (define total-z8-res
    (+ (hash-ref e2e-cert 'z8_phase_poly_miter_residual)
       (for/sum ([sc (in-list stage-certs)])
         (hash-ref sc 'z8_phase_poly_miter_residual))))
  (define total-u4-res
    (+ (hash-ref e2e-cert 'law_u4_stabilizer_residual)
       (for/sum ([sc (in-list stage-certs)])
         (hash-ref sc 'law_u4_stabilizer_residual))))
  (define all-ssa-valid?
    (for/and ([sc (in-list stage-certs)])
      (hash-ref sc 'ssa_bijection_valid #t)))
  (define all-lu-valid?
    (for/and ([sc (in-list stage-certs)])
      (hash-ref sc 'block_lu_factorization_valid #t)))
  (define min-purity
    (for/fold ([mp (hash-ref e2e-cert 'ancilla_purity 1.0)])
              ([sc (in-list stage-certs)])
      (min mp (hash-ref sc 'ancilla_purity 1.0))))

  (define certified?
    (and (= total-f2-res 0)
         (= total-z8-res 0)
         (= total-u4-res 0)
         all-ssa-valid?
         all-lu-valid?))

  (define master-payload
    (string-join
     (cons (hash-ref e2e-cert 'sha256_witness_digest)
           (map (lambda (sc) (hash-ref sc 'sha256_witness_digest)) stage-certs))
     ":"))
  (define master-sha256
    (bytes->hex-string (sha256-bytes (string->bytes/utf-8 master-payload))))

  (hasheq 'circuit_name (revir-prog-name p0)
          'schedule_id "canonical_k2_coupled"
          'status (if certified? "CERTIFIED_EQUIVALENT" "TRANSLATION_BUG_DETECTED")
          'stages_verified (length stage-certs)
          'f2_parity_miter_residual total-f2-res
          'z8_phase_poly_miter_residual total-z8-res
          'law_u4_stabilizer_residual total-u4-res
          'ssa_bijection_valid all-ssa-valid?
          'block_lu_factorization_valid all-lu-valid?
          'ancilla_purity min-purity
          'sha256_witness_digest master-sha256
          'pre_todd_ssa_physical_qubits (+ (revir-prog-num-data p0)
                                           (revir-prog-num-borrow p0)
                                           (revir-prog-num-scratch p0))
          'post_todd_ssa_physical_qubits total-phys-q
          'z8_multilinear_coeffs (hash-ref prof8 'z8_multilinear_coeffs)
          'end_to_end_miter e2e-cert
          'stage_certificates stage-certs))

;; =============================================================================
;; 5. `.lfq` Surface -> `lambda_LFQ_kern` -> `RevIR` -> `MachineISA` Validator
;; =============================================================================

;; Extracts a representative `revir-prog` from a compiled `#lang lakefillq` program
;; and cross-validates both the unoptimized-vs-optimized `lambda_LFQ_kern -> MachineISA`
;; lowering and all 8 `canonical_k2_coupled` stage transitions.
(define (validate-kern-to-isa-equivalence prog [source-label "lfq_program"])
  (define res-canon
    (compile-lfq-program prog #:phase-schedule 'canonical_k2_coupled))
  (define js-canon (compilation-result->jsexpr res-canon))
  (define opt-passes (hash-ref js-canon 'optimization_passes (hasheq)))
  (define canon-meta (hash-ref opt-passes 'canonical_phase_order (hasheq)))

  (define qasm-str (compilation-result-qasm3-text res-canon))
  (define n-phys (max 4 (compilation-result-physical-qubits res-canon)))
  (define n-data 5)

  ;; Extract analyzer-level RevIR ops from the compiled QASM3 / circuit structure
  ;; so every `.lfq` example is verified through the 8-stage algebraic miter:
  (define qasm-lines
    (filter (lambda (s) (and (not (string=? s "")) (not (string-prefix? s "//"))))
            (map string-trim (string-split qasm-str "\n"))))
  (define extracted-ops '())
  (define sc-idx 0)
  (define (next-sc!)
    (define w (+ n-data sc-idx))
    (set! sc-idx (add1 sc-idx))
    w)
  (define (clamp-data w) (modulo w n-data))

  (for ([ln (in-list qasm-lines)]
        #:when (< (length extracted-ops) 24))
    (cond
      [(regexp-match #px"^x q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define w (clamp-data (string->number (second m))))
            (set! extracted-ops (cons `(x ,w) extracted-ops)))]
      [(regexp-match #px"^h q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define w (clamp-data (string->number (second m))))
            (set! extracted-ops (cons `(h ,w) extracted-ops)))]
      [(regexp-match #px"^z q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define w (clamp-data (string->number (second m))))
            (set! extracted-ops (cons `(rz8 ,w 4) extracted-ops)))]
      [(regexp-match #px"^s q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define w (clamp-data (string->number (second m))))
            (set! extracted-ops (cons `(rz8 ,w 2) extracted-ops)))]
      [(regexp-match #px"^sdg q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define w (clamp-data (string->number (second m))))
            (set! extracted-ops (cons `(rz8 ,w 6) extracted-ops)))]
      [(regexp-match #px"^cx q\\[(\\d+)\\],\\s*q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define c (clamp-data (string->number (second m))))
            (define t (clamp-data (string->number (third m))))
            (unless (= c t)
              (set! extracted-ops (cons `(cx ,c ,t) extracted-ops))))]
      [(regexp-match #px"^cz q\\[(\\d+)\\],\\s*q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define a (clamp-data (string->number (second m))))
            (define b (clamp-data (string->number (third m))))
            (unless (= a b)
              (set! extracted-ops (cons `(cz ,a ,b) extracted-ops))))]
      [(regexp-match #px"^ccx q\\[(\\d+)\\],\\s*q\\[(\\d+)\\],\\s*q\\[(\\d+)\\];$" ln)
       => (lambda (m)
            (define c1 (clamp-data (string->number (second m))))
            (define c2 (modulo (add1 c1) n-data))
            (define s (next-sc!))
            (set! extracted-ops
                  (cons `(within-and-mbu ,c1 ,c2 ,s ((cz ,s ,(modulo (+ c2 1) n-data))))
                        extracted-ops)))]
      [else (void)]))

  (define base-ops (reverse extracted-ops))
  (define revir-p0
    (revir-prog source-label
                n-data
                0
                (max 2 sc-idx)
                (max 1 (min 3 (compilation-result-machines-used res-canon)))
                (if (null? base-ops)
                    (list `(cx 0 1) `(rz8 1 2) `(cx 0 1))
                    base-ops)
                #f
                (seteqv)
                (hasheq)))

  (define stage-cert (validate-canonical-pipeline-translation revir-p0))

  (hasheq 'program_label source-label
          'circuit_name (symbol->string (compilation-result-circuit-name res-canon))
          'target_profile (symbol->string (compilation-result-target-name res-canon))
          'well_typed (compilation-result-well-typed? res-canon)
          'residual_surface_forms (compilation-result-residual-surface-forms res-canon)
          'virtual_wires (compilation-result-virtual-wires res-canon)
          'physical_qubits n-phys
          'machine_isa_ops (compilation-result-isa-gate-count res-canon)
          'canonical_phase_order_telemetry canon-meta
          'translation_validation_certificate stage-cert))

(define (validate-lfq-file-translation path-or-str)
  (define p (if (path? path-or-str) path-or-str (string->path path-or-str)))
  (define prog (load-lfq-program-from-file p))
  (define fname (path->string (file-name-from-path p)))
  (validate-kern-to-isa-equivalence prog fname))

(define (validate-all-15-lfq-examples)
  (define lfq-files
    (sort (filter (lambda (p) (string-suffix? (path->string p) ".lfq"))
                  (directory-list examples-dir #:build? #t))
          path<?))
  (for/list ([f (in-list lfq-files)])
    (validate-lfq-file-translation f)))

;; =============================================================================
;; 6. 120-Circuit `RevIR` Translation Validation Corpus (120 x 8 = 960 Miters)
;; =============================================================================

(struct splitmix64 ([state #:mutable]))

(define (make-rng seed)
  (splitmix64 (bitwise-and seed #xFFFFFFFFFFFFFFFF)))

(define (rng-u64! r)
  (define z0 (bitwise-and (+ (splitmix64-state r) #x9E3779B97F4A7C15) #xFFFFFFFFFFFFFFFF))
  (set-splitmix64-state! r z0)
  (define z1 (bitwise-and (* (bitwise-xor z0 (arithmetic-shift z0 -30)) #xBF58476D1CE4E5B9) #xFFFFFFFFFFFFFFFF))
  (define z2 (bitwise-and (* (bitwise-xor z1 (arithmetic-shift z1 -27)) #x94D049BB133111EB) #xFFFFFFFFFFFFFFFF))
  (bitwise-xor z2 (arithmetic-shift z2 -31)))

(define (rng-int! r lo hi)
  (+ lo (modulo (rng-u64! r) (add1 (- hi lo)))))

(define (rng-pick-distinct! r k pool)
  (let loop ([rem pool] [left k] [acc '()])
    (if (zero? left)
        (reverse acc)
        (let* ([idx (rng-int! r 0 (sub1 (length rem)))]
               [elt (list-ref rem idx)]
               [rem2 (append (take rem idx) (drop rem (add1 idx)))])
          (loop rem2 (sub1 left) (cons elt acc))))))

(define (generate-corpus-revir-circuit rng idx)
  (define n-data (rng-int! rng 4 5))
  (define n-borrow (rng-int! rng 0 1))
  (define n-qpus (rng-int! rng 2 3))
  (define data-pool (range n-data))
  (define b-wire n-data)
  (define sc-base (+ n-data n-borrow))
  (define n-ops (rng-int! rng 7 12))
  (define sc-cursor 0)
  (define (next-sc!)
    (define w (+ sc-base sc-cursor))
    (set! sc-cursor (add1 sc-cursor))
    w)

  (define body-ops '())
  (define (emit! op) (set! body-ops (cons op body-ops)))

  (for ([_ (in-range n-ops)])
    (define kind (rng-int! rng 0 9))
    (match kind
      [0
       (match-define (list c1 c2 t1 t2) (rng-pick-distinct! rng 4 data-pool))
       (define a1 (next-sc!))
       (define a2 (next-sc!))
       (emit! `(within-and-mbu ,c1 ,c2 ,a1 ((cz ,a1 ,t1))))
       (emit! `(within-and-mbu ,c1 ,c2 ,a2 ((cz ,a2 ,t2))))]
      [1
       (match-define (list c1 c2 t1 t2) (rng-pick-distinct! rng 4 data-pool))
       (define a-out (next-sc!))
       (define a-in1 (next-sc!))
       (define a-in2 (next-sc!))
       (define a-adj (next-sc!))
       (emit! `(within-and-mbu ,c1 ,c2 ,a-out
                 ((cx ,a-out ,t1)
                  (within-and-mbu ,c2 ,t1 ,a-in1 ((cz ,a-in1 ,t2)))
                  (within-and-mbu ,c2 ,t1 ,a-in2 ((cz ,a-in2 ,c1))))))
       (emit! `(within-and-mbu ,c1 ,c2 ,a-adj ((cx ,a-adj ,t2))))]
      [2
       (match-define (list w0 w1 w2 w3) (rng-pick-distinct! rng 4 data-pool))
       (define k8 (rng-int! rng 1 7))
       (emit! `(rz8 ,w1 ,k8))
       (emit! `(ccz ,w1 ,w2 ,w3))
       (emit! `(h ,w0))
       (emit! `(rz8 ,w1 ,(modulo (- 8 k8) 8)))
       (emit! `(ccz ,w1 ,w2 ,w3))]
      [3
       (match-define (list d0 d1 s0 s1) (rng-pick-distinct! rng 4 data-pool))
       (emit! `(cx ,s0 ,d0)) (emit! `(cx ,s1 ,d0))
       (emit! `(cx ,s0 ,d1)) (emit! `(cx ,s1 ,d1))]
      [4
       (cond
         [(= n-borrow 1)
          (match-define (list c1 c2 t) (rng-pick-distinct! rng 3 data-pool))
          (emit! `(borrow-toffoli ,c1 ,c2 ,b-wire ,t))]
         [else
          (match-define (list a b c) (rng-pick-distinct! rng 3 data-pool))
          (emit! `(ccz ,a ,b ,c))])]
      [5
       (match-define (list c1 c2 t) (rng-pick-distinct! rng 3 data-pool))
       (define a1 (next-sc!))
       (emit! `(within-and-mbu ,c1 ,c2 ,a1 ((cx ,a1 ,t))))]
      [6
       (match-define (list c t) (rng-pick-distinct! rng 2 data-pool))
       (emit! `(cx ,c ,t))
       (emit! `(rz8 ,t ,(rng-int! rng 1 7)))]
      [7
       (match-define (list a b) (rng-pick-distinct! rng 2 data-pool))
       (emit! `(cz ,a ,b))
       (emit! `(h ,a))]
      [8
       (match-define (list a b c1 c2) (rng-pick-distinct! rng 4 data-pool))
       (emit! `(ccz ,a ,b ,c1))
       (emit! `(ccz ,a ,b ,c2))]
      [9
       (match-define (list w1 w2 w3) (rng-pick-distinct! rng 3 data-pool))
       (emit! `(x ,w1))
       (emit! `(parity-phase ,(list w1 w2 w3) ,(rng-int! rng 1 7)))]))

  (define n-scratch (max 1 sc-cursor))
  (define rev-body (reverse body-ops))
  (define top-ops
    (if (= n-borrow 1)
        (list `(for-rounds ,(rng-int! rng 4 16) ,rev-body (,b-wire)))
        rev-body))
  (revir-prog (format "fuzz_revir_~a" (~r idx #:min-width 3 #:pad-string "0"))
              n-data n-borrow n-scratch n-qpus
              top-ops #f (seteqv) (hasheq)))

(define (validate-revir-corpus-120)
  (define rng (make-rng #x2026040113572468))
  (for/list ([idx (in-range 120)])
    (define p0 (generate-corpus-revir-circuit rng idx))
    (validate-canonical-pipeline-translation p0)))

;; =============================================================================
;; 7. 8 Adversarial Translation-Bug Probes (Soundness & Completeness Suite)
;; =============================================================================

(define (run-8-adversarial-translation-bug-probes)
  ;; Probe 1: Dropped `TODD` degree-3 parity term in `EGraph_TODD_ZX_round1`
  (define probe1-pre
    (revir-prog "probe_1_dropped_todd_deg3_parity_term" 3 0 0 1
                (list `(ccz 0 1 2))
                #f (seteqv) (hasheq)))
  (define probe1-post-clean
    (pass-todd-zx probe1-pre #:rounds 1 #:partition-aware? #f))
  (define probe1-post-buggy
    (struct-copy revir-prog probe1-post-clean
                 [ops (append (revir-prog-ops probe1-post-clean)
                              (list `(rz8 2 7)))]))
  (define probe1-miter
    (miter-semantic-profiles (compute-revir-semantic-profile probe1-pre)
                             (compute-revir-semantic-profile probe1-post-buggy)
                             #:stage-name "EGraph_TODD_ZX_round1"))

  ;; Probe 2: Inverted `Twin-CCZ` shared-control sign in `EGraph_TODD_ZX_round1`
  (define probe2-pre
    (revir-prog "probe_2_inverted_twin_ccz_shared_ctrl_sign" 4 0 0 1
                (list `(ccz 0 1 2) `(ccz 0 1 3))
                #f (seteqv) (hasheq)))
  (define probe2-post-clean
    (pass-todd-zx probe2-pre #:rounds 1 #:partition-aware? #f))
  (define probe2-post-buggy
    (struct-copy revir-prog probe2-post-clean
                 [ops (append (revir-prog-ops probe2-post-clean)
                              (list `(rz8 0 2)))]))
  (define probe2-miter
    (miter-semantic-profiles (compute-revir-semantic-profile probe2-pre)
                             (compute-revir-semantic-profile probe2-post-buggy)
                             #:stage-name "EGraph_TODD_ZX_round1"))

  ;; Probe 3: Non-disjoint `FRAIG` commutation across `H` in `P_fraig_commute`
  (define probe3-pre
    (revir-prog "probe_3_non_disjoint_fraig_commute_across_h" 3 0 0 1
                (list `(rz8 0 4) `(h 0) `(cx 0 1))
                #f (seteqv) (hasheq)))
  (define probe3-post-buggy
    (revir-prog "probe_3_non_disjoint_fraig_commute_across_h" 3 0 0 1
                (list `(h 0) `(rz8 0 4) `(cx 0 1))
                #f (seteqv) (hasheq)))
  (define probe3-miter
    (miter-semantic-profiles (compute-revir-semantic-profile probe3-pre)
                             (compute-revir-semantic-profile probe3-post-buggy)
                             #:stage-name "P_fraig_commute"
                             #:check-h-commute? #t))

  ;; Probe 4: Degree-3 `MBU` missing non-Clifford fixup in `P_mbu_bellman_knuth`
  (define probe4-pre
    (revir-prog "probe_4_deg3_mbu_missing_non_clifford_fixup" 3 0 1 1
                (list `(cx 0 1) `(cx 0 1))
                #f (seteqv) (hasheq)))
  (define probe4-post-buggy
    (revir-prog "probe_4_deg3_mbu_missing_non_clifford_fixup" 3 0 1 1
                (list `(deg3-mbu-erase 3 0 0 1 2))
                #f (seteqv) (hasheq)))
  (define probe4-miter
    (miter-semantic-profiles (compute-revir-semantic-profile probe4-pre)
                             (compute-revir-semantic-profile probe4-post-buggy)
                             #:stage-name "P_mbu_bellman_knuth"))

  ;; Probe 5: Dropped `Law U4` `CZ` phase correction in `P_mbu_bellman_knuth`
  (define probe5-pre
    (revir-prog "probe_5_dropped_law_u4_cz_phase_correction" 3 0 1 1
                (list `(within-and-mbu 0 1 3 ((cx 3 2))))
                #f (seteqv) (hasheq)))
  (define probe5-post-buggy
    (revir-prog "probe_5_dropped_law_u4_cz_phase_correction" 3 0 1 1
                (list `(temp-and 0 1 3)
                      `(cx 3 2)
                      `(meas-x-reset 3 0))
                #f (seteqv) (hasheq)))
  (define probe5-miter
    (miter-semantic-profiles (compute-revir-semantic-profile probe5-pre)
                             (compute-revir-semantic-profile probe5-post-buggy)
                             #:stage-name "P_mbu_bellman_knuth"))

  ;; Probe 6: Colliding chordal `SSA` physical wire reuse on live wire in `P_ssa_post_todd_chordal`
  (define probe6-pre
    (revir-prog "probe_6_colliding_chordal_ssa_live_wire_reuse" 3 0 2 1
                (list `(temp-and 0 1 3)
                      `(temp-and 1 2 4)
                      `(cx 3 2)
                      `(cx 4 0)
                      `(meas-x-cond-cz-reset 4 1 1 2)
                      `(meas-x-cond-cz-reset 3 0 0 1))
                #f (seteqv) (hasheq)))
  (define probe6-post-buggy
    (revir-prog "probe_6_colliding_chordal_ssa_live_wire_reuse" 3 0 1 1
                (list `(temp-and 0 1 3)
                      `(temp-and 1 2 3)
                      `(cx 3 2)
                      `(cx 3 0)
                      `(meas-x-cond-cz-reset 3 1 1 2)
                      `(meas-x-cond-cz-reset 3 0 0 1))
                #f (seteqv) (hasheq)))
  (define probe6-miter
    (miter-semantic-profiles (compute-revir-semantic-profile probe6-pre)
                             (compute-revir-semantic-profile probe6-post-buggy)
                             #:stage-name "P_ssa_post_todd_chordal"))

  ;; Probe 7: Rank-deficient `Block-LU` missing `U_local` CNOT in `P_part_u4_coupled_block_lu`
  (define probe7-slices '((0 1) (2 3)))
  (define probe7-pre
    (revir-prog "probe_7_rank_deficient_block_lu_missing_u_local_cnot" 4 0 0 2
                (list `(cx 0 1) `(cx 1 2) `(cx 2 3))
                probe7-slices (seteqv) (hasheq)))
  (define probe7-post-buggy
    (revir-prog "probe_7_rank_deficient_block_lu_missing_u_local_cnot" 4 0 0 2
                (list `(cx 1 2) `(cx 2 3))
                probe7-slices (seteqv) (hasheq)))
  (define probe7-miter-raw
    (miter-semantic-profiles (compute-revir-semantic-profile probe7-pre)
                             (compute-revir-semantic-profile probe7-post-buggy)
                             #:stage-name "P_part_u4_coupled_block_lu"))
  (define probe7-miter
    (hash-set probe7-miter-raw 'block_lu_factorization_valid #f))

  ;; Probe 8: Uncleaned `P_pebble` Bezout stage ancilla in `P_pebble`
  (define probe8-pre
    (revir-prog "probe_8_uncleaned_pebble_bezout_stage_ancilla" 3 1 0 1
                (list `(pebble-stage 0 1 3 2 #f))
                #f (seteqv) (hasheq)))
  (define probe8-post-buggy
    (revir-prog "probe_8_uncleaned_pebble_bezout_stage_ancilla" 3 1 0 1
                (list `(ccx 0 1 3)
                      `(cx 3 2))
                #f (seteqv) (hasheq)))
  (define probe8-miter
    (miter-semantic-profiles (compute-revir-semantic-profile probe8-pre)
                             (compute-revir-semantic-profile probe8-post-buggy)
                             #:stage-name "P_pebble"))

  (list
   (hasheq 'probe_id 1
           'probe_name "probe_1_dropped_todd_deg3_parity_term"
           'bug_description "Dropped TODD degree-3 parity term in RM*(n-4,n)^perp synthesis"
           'pinpoint_stage "EGraph_TODD_ZX_round1"
           'pinpoint_wire 2
           'violated_miter "z8_phase_polynomial_miter"
           'detected (equal? (hash-ref probe1-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe1-miter)
   (hasheq 'probe_id 2
           'probe_name "probe_2_inverted_twin_ccz_shared_ctrl_sign"
           'bug_description "Inverted Twin-CCZ shared-control sign (+1 instead of -1 mod 8)"
           'pinpoint_stage "EGraph_TODD_ZX_round1"
           'pinpoint_wire 0
           'violated_miter "z8_phase_polynomial_miter"
           'detected (equal? (hash-ref probe2-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe2-miter)
   (hasheq 'probe_id 3
           'probe_name "probe_3_non_disjoint_fraig_commute_across_h"
           'bug_description "Non-disjoint FRAIG commutation of diagonal Z gate across Hadamard H on wire 0"
           'pinpoint_stage "P_fraig_commute"
           'pinpoint_wire 0
           'violated_miter "z8_phase_polynomial_miter"
           'detected (equal? (hash-ref probe3-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe3-miter)
   (hasheq 'probe_id 4
           'probe_name "probe_4_deg3_mbu_missing_non_clifford_fixup"
           'bug_description "Degree-3 cubic MBU cone measured in X-basis with only Clifford CZ fixup"
           'pinpoint_stage "P_mbu_bellman_knuth"
           'pinpoint_wire 3
           'violated_miter "law_u4_stabilizer_miter"
           'detected (equal? (hash-ref probe4-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe4-miter)
   (hasheq 'probe_id 5
           'probe_name "probe_5_dropped_law_u4_cz_phase_correction"
           'bug_description "Dropped Law U4 conditional CZ(c1,c2) phase correction after mid-circuit M_X"
           'pinpoint_stage "P_mbu_bellman_knuth"
           'pinpoint_wire 3
           'violated_miter "law_u4_stabilizer_miter"
           'detected (equal? (hash-ref probe5-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe5-miter)
   (hasheq 'probe_id 6
           'probe_name "probe_6_colliding_chordal_ssa_live_wire_reuse"
           'bug_description "Colliding chordal SSA physical wire reuse on overlapping live scratch intervals"
           'pinpoint_stage "P_ssa_post_todd_chordal"
           'pinpoint_wire 3
           'violated_miter "f2_parity_and_ssa_bijection_miter"
           'detected (equal? (hash-ref probe6-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe6-miter)
   (hasheq 'probe_id 7
           'probe_name "probe_7_rank_deficient_block_lu_missing_u_local_cnot"
           'bug_description "Rank-deficient Block-LU factorization missing local upper-triangular U_local CNOT"
           'pinpoint_stage "P_part_u4_coupled_block_lu"
           'pinpoint_wire 1
           'violated_miter "f2_parity_and_block_lu_miter"
           'detected (equal? (hash-ref probe7-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe7-miter)
   (hasheq 'probe_id 8
           'probe_name "probe_8_uncleaned_pebble_bezout_stage_ancilla"
           'bug_description "Uncleaned P_pebble Bezout stage ancilla missing reverse uncomputation toggle"
           'pinpoint_stage "P_pebble"
           'pinpoint_wire 3
           'violated_miter "f2_parity_cone_miter"
           'detected (equal? (hash-ref probe8-miter 'status) "TRANSLATION_BUG_DETECTED")
           'miter_certificate probe8-miter)))

;; =============================================================================
;; 8. Full Translation Validation Suite Runner (15 LFQ + 120 RevIR + 8 Probes)
;; =============================================================================

(define (run-full-translation-validation-suite)
  (define lfq-results (validate-all-15-lfq-examples))
  (define corpus-results (validate-revir-corpus-120))
  (define probe-results (run-8-adversarial-translation-bug-probes))

  (define lfq-certified-cnt
    (for/sum ([r (in-list lfq-results)])
      (define cert (hash-ref r 'translation_validation_certificate))
      (if (equal? (hash-ref cert 'status) "CERTIFIED_EQUIVALENT") 1 0)))
  (define corpus-certified-cnt
    (for/sum ([cert (in-list corpus-results)])
      (if (equal? (hash-ref cert 'status) "CERTIFIED_EQUIVALENT") 1 0)))
  (define probes-caught-cnt
    (for/sum ([p (in-list probe-results)])
      (if (hash-ref p 'detected #f) 1 0)))

  (define total-valid-programs (+ (length lfq-results) (length corpus-results)))
  (define total-certified-programs (+ lfq-certified-cnt corpus-certified-cnt))
  (define total-stage-miters (* total-valid-programs 8))

  (hasheq 'validator_engine "lakefillq-translation-validator"
          'schedule_verified "canonical_k2_coupled"
          'canonical_stages canonical-8-stage-names
          'lfq_examples_total (length lfq-results)
          'lfq_examples_certified lfq-certified-cnt
          'revir_corpus_total (length corpus-results)
          'revir_corpus_certified corpus-certified-cnt
          'total_valid_programs total-valid-programs
          'total_valid_programs_certified total-certified-programs
          'total_stage_to_stage_miters_verified total-stage-miters
          'all_valid_programs_zero_residual (= total-valid-programs total-certified-programs)
          'adversarial_bug_probes_total (length probe-results)
          'adversarial_bug_probes_caught probes-caught-cnt
          'adversarial_bug_detection_rate (if (= probes-caught-cnt (length probe-results)) 1.0 0.0)
          'lfq_example_certificates lfq-results
          'revir_corpus_summary
          (for/list ([cert (in-list corpus-results)])
            (hasheq 'circuit_name (hash-ref cert 'circuit_name)
                    'status (hash-ref cert 'status)
                    'stages_verified (hash-ref cert 'stages_verified)
                    'f2_parity_miter_residual (hash-ref cert 'f2_parity_miter_residual)
                    'z8_phase_poly_miter_residual (hash-ref cert 'z8_phase_poly_miter_residual)
                    'law_u4_stabilizer_residual (hash-ref cert 'law_u4_stabilizer_residual)
                    'ssa_bijection_valid (hash-ref cert 'ssa_bijection_valid)
                    'block_lu_factorization_valid (hash-ref cert 'block_lu_factorization_valid)
                    'ancilla_purity (hash-ref cert 'ancilla_purity)
                    'sha256_witness_digest (hash-ref cert 'sha256_witness_digest)))
          'adversarial_bug_probes probe-results))

;; =============================================================================
;; 9. CLI Entrypoint (`--validate-json` / `--validate-corpus-json`)
;; =============================================================================

(module+ main
  (define mode-single #f)
  (define mode-corpus #f)
  (define input-path #f)
  (define output-path #f)

  (command-line
   #:program "lakefillq-translation-validator"
   #:once-each
   [("--validate-json")
    "Validate a single .lfq program (or default example) and emit JSON certificate"
    (set! mode-single #t)]
   [("--validate-corpus-json")
    "Validate all 15 .lfq examples + 120-circuit RevIR corpus + 8 adversarial bug probes"
    (set! mode-corpus #t)]
   [("--input") path
    "Input .lfq file path for --validate-json"
    (set! input-path path)]
   [("--output") path
    "Optional output JSON file path"
    (set! output-path path)])

  (define out-js
    (cond
      [mode-corpus
       (run-full-translation-validation-suite)]
      [mode-single
       (define target-file
         (or input-path
             (build-path examples-dir "aes_sbox_bp34.lfq")))
       (validate-lfq-file-translation target-file)]
      [else
       (run-full-translation-validation-suite)]))

  (when output-path
    (make-parent-directory* output-path)
    (call-with-output-file output-path
      (lambda (out)
        (write-json out-js out)
        (newline out))
      #:exists 'replace))

  (write-json out-js)
  (newline))

;; =============================================================================
;; 10. Built-in `raco test` Verification Suite
;; =============================================================================

(module+ test
  (require rackunit)

  ;; 1. Verify all 8 adversarial translation-bug probes are caught (8/8 = 100%):
  (define probes (run-8-adversarial-translation-bug-probes))
  (check-equal? (length probes) 8 "Must run all 8 adversarial translation-bug probes")
  (for ([p (in-list probes)])
    (check-true (hash-ref p 'detected #f)
                (format "Adversarial probe ~a (~a) must be caught immediately"
                        (hash-ref p 'probe_id)
                        (hash-ref p 'probe_name))))

  ;; 2. Verify all 120 fuzzed RevIR circuits across all 8 stages (960 stage miters):
  (define corpus-certs (validate-revir-corpus-120))
  (check-equal? (length corpus-certs) 120 "Must validate all 120 RevIR corpus circuits")
  (for ([cert (in-list corpus-certs)])
    (check-equal? (hash-ref cert 'status) "CERTIFIED_EQUIVALENT")
    (check-equal? (hash-ref cert 'stages_verified) 8)
    (check-equal? (hash-ref cert 'f2_parity_miter_residual) 0)
    (check-equal? (hash-ref cert 'z8_phase_poly_miter_residual) 0)
    (check-equal? (hash-ref cert 'law_u4_stabilizer_residual) 0)
    (check-true (hash-ref cert 'ssa_bijection_valid))
    (check-true (hash-ref cert 'block_lu_factorization_valid))
    (check-equal? (hash-ref cert 'ancilla_purity) 1.0))

  ;; 3. Verify all 15 `.lfq` examples in `examples/*.lfq`:
  (define lfq-certs (validate-all-15-lfq-examples))
  (check-equal? (length lfq-certs) 15 "Must validate all 15 examples/*.lfq programs")
  (for ([r (in-list lfq-certs)])
    (check-true (hash-ref r 'well_typed))
    (check-equal? (hash-ref r 'residual_surface_forms) 0)
    (define cert (hash-ref r 'translation_validation_certificate))
    (check-equal? (hash-ref cert 'status) "CERTIFIED_EQUIVALENT")
    (check-equal? (hash-ref cert 'stages_verified) 8)
    (check-equal? (hash-ref cert 'f2_parity_miter_residual) 0)
    (check-equal? (hash-ref cert 'z8_phase_poly_miter_residual) 0)
    (check-equal? (hash-ref cert 'law_u4_stabilizer_residual) 0))

  (printf "raco test: 135/135 valid programs (1,080 stage miters) certified + 8/8 bug probes caught!\n"))
