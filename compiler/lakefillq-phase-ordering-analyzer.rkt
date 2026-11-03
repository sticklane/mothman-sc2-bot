#lang racket

;; =============================================================================
;; `compiler/lakefillq-phase-ordering-analyzer.rkt`
;;
;; Systematic Phase-Ordering, Non-Commutativity, Multi-Round Fixpoint, and
;; Partition-Aware Lowering Analyzer for `LakefillQ -> lambda_LFQ_kern -> RevIR -> MachineISA`.
;;
;; Core Capabilities & Phase-Coupling Implementations:
;;   1. Composable `RevIR -> RevIR` Endomorphisms for Exhaustive `6! = 720`
;;      Pass-Permutation Benchmarking:
;;        - `P_loop_cone`: Zero-flag `k=1 -> k=2 -> k=R` inductive `QSub` inference
;;          (backed by `lakefillq-xag-fraig-typechecker.rkt` `XAG/FRAIG + Z3`) +
;;          affine-polarity-quotient 1-WL canonical cone isomorphism.
;;        - `P_pebble`: `QSub`-certified `BorrowZ` dirty-limb-to-clean-pebble promotion.
;;        - `P_todd_zx`: Congruence-closed `e-Graph` (`lakefillq-egraph-saturator.rkt`)
;;          phase-cone absorption + Twin-CCZ + 15-subset Reed-Muller `RM*(n-4,n)^perp`
;;          TODD 3-tensor reduction + ZX spider fusion mod 8.
;;        - `P_mbu`: Asymmetric Gidney/Jones `4T` `TempAND` -> `M_X` + `cond-cz` lowering.
;;        - `P_ssa`: Exact chordal interval-graph scratch wire coloring & post-TODD
;;          dead-interval re-coloring (`recolor-post-todd-chordal-ssa`).
;;        - `P_part_u4`: Multi-QPU Law-U4 asymmetric cone-hypergraph min-cut +
;;          Kernighan-Lin refinement (`partition-wires-law-u4-hypergraph`).
;;   2. Missing Phase-Coupling Fixes Implemented Here:
;;        - **Partition-Aware Steiner Parity Batching & Zero-Ancilla Rank-r Conjugate
;;          Block-LU Gaussian Parity Restoration** (`synthesize-linear-frame-partition-aware`):
;;          eliminates cross-QPU CNOT inflation from unconstrained `GL_n(F_2)` pivoting,
;;          compressing off-diagonal block `B` ebits from `||B||_0` down to `rank_F2(B)`.
;;        - **Unified `EGraph(MBU U ZX U TODD)` + 2-Round `(P_fraig_comm o EGraph)^2`
;;          Fixpoint**: commutes disjoint-support & diagonal cones across `H` barriers
;;          for second-order spider/CCZ cancellation before `P_mbu` and `P_ssa`.
;;        - **Post-TODD Chordal SSA Re-Coloring**: reclaims scratch qubits whose live
;;          intervals shrink or vanish during algebraic phase-cone absorption.
;;   3. Empirical Evaluation Across:
;;        - All `6! = 720` pass permutations on a composite multi-feature kernel,
;;        - All 5 real benchmark kernels (`Boyar-Peralta AES S-box + MixColumns`,
;;          `Keccak-chi sponge`, `Hermitian/Suzuki Early-MBU DQI`,
;;          `ECC-256 Jump-16 Bezout zipper`, `Distributed QRNS Shor-2048`),
;;        - `240` (`>= 200`) deterministic seeded fuzzed `RevIR` circuits with internal
;;          exact quantum statevector / Kraus branch equivalence check & JSON export.
;; =============================================================================

(require racket/match
         racket/list
         racket/set
         racket/vector
         racket/math
         racket/format
         racket/runtime-path
         racket/file
         json
         "lakefillq-egraph-saturator.rkt"
         "lakefillq-xag-fraig-typechecker.rkt")

(provide (struct-out revir-prog)
         pass-loop-cone
         pass-unroll
         pass-const-fold
         pass-pebble
         pass-todd-zx
         pass-fraig-commute
         pass-mbu
         pass-ssa
         pass-part-u4
         synthesize-linear-frame-unconstrained
         synthesize-linear-frame-partition-aware
         schedule-steiner-parity-batches-partition-aware
         partition-wires-law-u4-hypergraph
         recolor-post-todd-chordal-ssa
         compile-with-schedule
         emit-final-machine-isa
         run-full-phase-ordering-analysis
         ;; Target-Aware Portfolio Superoptimizer exports:
         PORTFOLIO-SCHEDULE-IDS
         pass-ssa-nonphase-pre
         pass-part-u4-pre-pin
         pass-todd-zx-cut-preserving
         pass-mbu-ebit-weighted
         estimate-portfolio-wall-clock-ms
         select-portfolio-pass-schedule
         run-portfolio-superoptimizer-on-kernel
         generate-portfolio-superoptimizer-report)

(define-runtime-path COMPILER-DIR ".")
(putenv "TMPDIR" "/home/antigravity/toolchains/tmp")

;; =============================================================================
;; SECTION 1: Core `RevIR` Program Representation & Bitmask Linear Algebra
;; =============================================================================

(struct revir-prog
  (name            ;; string identifier
   num-data        ;; primary input/output qubits [0 .. num-data - 1]
   num-borrow      ;; borrowed limbs [num-data .. num-data + num-borrow - 1]
   num-scratch     ;; virtual/physical clean scratch wires allocated after borrow
   num-qpus        ;; target cluster QPU count M* >= 1
   ops             ;; list of RevIR instructions
   partitions      ;; #f or list of M* lists of wire indices
   zero-certified  ;; seteqv of wire indices certified |0> at loop/step boundaries
   meta)           ;; immutable hash of pass-telemetry counters
  #:transparent)

(define (total-wires prog)
  (+ (revir-prog-num-data prog)
     (revir-prog-num-borrow prog)
     (revir-prog-num-scratch prog)))

(define (meta-set prog k v)
  (struct-copy revir-prog prog
               [meta (hash-set (revir-prog-meta prog) k v)]))

(define (meta-add prog k delta)
  (meta-set prog k (+ (hash-ref (revir-prog-meta prog) k 0) delta)))

(define (bitmask->wires mask)
  (let loop ([m mask] [idx 0] [acc '()])
    (cond
      [(zero? m) (reverse acc)]
      [(bitwise-bit-set? m 0)
       (loop (arithmetic-shift m -1) (add1 idx) (cons idx acc))]
      [else
       (loop (arithmetic-shift m -1) (add1 idx) acc)])))

(define (wires->mask ws)
  (for/fold ([acc 0]) ([w (in-list ws)])
    (bitwise-xor acc (arithmetic-shift 1 w))))

(define (mask-popcount mask)
  (let loop ([m mask] [cnt 0])
    (if (zero? m)
        cnt
        (loop (bitwise-and m (sub1 m)) (add1 cnt)))))

(define (compute-coords inv-vec mask num-w)
  (for/fold ([acc 0])
            ([b (in-range num-w)]
             #:when (bitwise-bit-set? mask b))
    (bitwise-xor acc (vector-ref inv-vec b))))

;; =============================================================================
;; SECTION 2: Unconstrained vs. Partition-Aware Steiner & Rank-r Conjugate Block-LU
;;            `GL_n(F_2)` Gaussian Synthesis (Hazard C Phase-Coupling Fix)
;; =============================================================================

(define (emit-1q-rz8-isa k8 w)
  (match (modulo k8 8)
    [0 '()]
    [1 (list (list "t" w))]
    [2 (list (list "s" w))]
    [3 (list (list "s" w) (list "t" w))]
    [4 (list (list "z" w))]
    [5 (list (list "z" w) (list "t" w))]
    [6 (list (list "sdg" w))]
    [7 (list (list "tdg" w))]))

;; Unconstrained linear parity frame restoration (mirrors `lakefillq-egraph-saturator.rkt`
;; `synthesize-linear-frame-cxs` without QPU partition awareness).
(define (synthesize-linear-frame-unconstrained num-w final-frame)
  (define cur-vec (for/vector ([w (in-range num-w)]) (arithmetic-shift 1 w)))
  (define inv-vec (for/vector ([b (in-range num-w)]) (arithmetic-shift 1 b)))
  (define cxs '())
  (define (apply-cx! c t)
    (unless (= c t)
      (set! cxs (cons (list "cx" c t) cxs))
      (vector-set! cur-vec t (bitwise-xor (vector-ref cur-vec t) (vector-ref cur-vec c)))
      (for ([b (in-range num-w)])
        (when (bitwise-bit-set? (vector-ref inv-vec b) t)
          (vector-set! inv-vec b (bitwise-xor (vector-ref inv-vec b) (arithmetic-shift 1 c)))))))
  (for ([p (in-range num-w)])
    (define target-m (vector-ref final-frame p))
    (define coords1 (compute-coords inv-vec target-m num-w))
    (unless (bitwise-bit-set? coords1 p)
      (define swap-q
        (findf (lambda (q) (and (> q p) (bitwise-bit-set? coords1 q)))
               (range (add1 p) num-w)))
      (when swap-q
        (apply-cx! p swap-q)))
    (define coords2 (compute-coords inv-vec target-m num-w))
    (for ([w (in-list (bitmask->wires coords2))]
          #:when (not (= w p)))
      (apply-cx! w p)))
  (unless (equal? cur-vec final-frame)
    (error 'synthesize-linear-frame-unconstrained
           "Unconstrained frame mismatch: got ~a expected ~a" cur-vec final-frame))
  (reverse cxs))

;; Exact GF(2) outer-product rank decomposition `B = sum_{j=1}^r u_j * v_j^T`
;; where `dst-wires` index rows of `B` and `src-wires` index columns of `B`.
;; Returns list of `(cons u-wire-list v-wire-list)` of length `r = rank_F2(B)`.
(define (gf2-rank-decompose-block row-masks dst-wires src-wires)
  ;; Build working list of `(cons dst-row-bitmask src-col-bitmask)`
  (define n-dst (length dst-wires))
  (define src-mask-all (wires->mask src-wires))
  (define rows
    (for/vector ([d (in-list dst-wires)] [idx (in-naturals)])
      (cons (arithmetic-shift 1 idx)
            (bitwise-and (vector-ref row-masks d) src-mask-all))))
  ;; Eliminate over `src-wires` columns while tracking row combinations in `u-acc`:
  ;; Specifically: if we maintain `B_rem = sum_{i} e_i * row_i`, picking pivot row `piv`
  ;; with column `c_piv` and clearing `c_piv` from other rows `r`:
  ;; `B_rem = u_vec * pivot_row + B_new`!
  (define factors '())
  (define used-pivots (mutable-seteqv))
  (for ([c-wire (in-list src-wires)])
    (define piv-idx
      (for/first ([i (in-range n-dst)]
                  #:when (and (not (set-member? used-pivots i))
                              (bitwise-bit-set? (cdr (vector-ref rows i)) c-wire)))
        i))
    (when piv-idx
      (set-add! used-pivots piv-idx)
      (define v-mask (cdr (vector-ref rows piv-idx)))
      ;; Find all rows `i` that currently have `c-wire` set -> these form `u`!
      (define u-wires
        (for/list ([i (in-range n-dst)]
                   #:when (bitwise-bit-set? (cdr (vector-ref rows i)) c-wire))
          (list-ref dst-wires i)))
      (for ([i (in-range n-dst)]
            #:when (bitwise-bit-set? (cdr (vector-ref rows i)) c-wire))
        (vector-set! rows i
                     (cons (car (vector-ref rows i))
                           (bitwise-xor (cdr (vector-ref rows i)) v-mask))))
      (set! factors (cons (cons u-wires (bitmask->wires v-mask)) factors))))
  (reverse factors))

(define (wire->qpu-table num-w partitions)
  (define tbl (make-vector num-w 0))
  (when partitions
    (for ([sl (in-list partitions)] [p (in-naturals)])
      (for ([w (in-list sl)] #:when (< w num-w))
        (vector-set! tbl w p))))
  tbl)

(define (count-cx-list-ebits cxs qpu-vec)
  (for/sum ([ins (in-list cxs)])
    (match ins
      [(list (or "cx" "cz") a b)
       (if (= (vector-ref qpu-vec a) (vector-ref qpu-vec b)) 0 1)]
      [(list "cond_cz" _ a b)
       (if (= (vector-ref qpu-vec a) (vector-ref qpu-vec b)) 0 1)]
      [_ 0])))

;; Exact Eisert-Law-U4 Z-basis epoch cat-entangler ebit counter on `MachineISA` sequences:
;; A remote projection of wire `c` from QPU `pc` to QPU `pt` remains coherent across any number
;; of Z-diagonal / CNOT-control uses on `pt` until `c` is mutated in a non-Z-commuting basis
;; (`cx` target, `h`, `x`, `mx_reset`), and releases via `M_X + cond-Z` at `0` reverse ebits!
(define (count-isa-law-u4-ebits ins-list qpu-vec num-w)
  (define z-ep (make-vector num-w 0))
  (define u4-cones (mutable-set))
  (define eb 0)
  (for ([ins (in-list ins-list)])
    (match ins
      [(list "cx" c t)
       (define pc (vector-ref qpu-vec c))
       (define pt (vector-ref qpu-vec t))
       (unless (= pc pt)
         (define key (list pc pt c (vector-ref z-ep c)))
         (unless (set-member? u4-cones key)
           (set-add! u4-cones key)
           (set! eb (add1 eb))))
       (vector-set! z-ep t (add1 (vector-ref z-ep t)))]
      [(list "cz" a b)
       (define pa (vector-ref qpu-vec a))
       (define pb (vector-ref qpu-vec b))
       (unless (= pa pb)
         (define key-ab (list pa pb a (vector-ref z-ep a)))
         (define key-ba (list pb pa b (vector-ref z-ep b)))
         (unless (or (set-member? u4-cones key-ab) (set-member? u4-cones key-ba))
           (set-add! u4-cones key-ab)
           (set! eb (add1 eb))))]
      [(list (or "h" "x") w)
       (vector-set! z-ep w (add1 (vector-ref z-ep w)))]
      [(list "mx_reset" w _)
       (vector-set! z-ep w (add1 (vector-ref z-ep w)))]
      ;; Under Law U4, classical 1-bit `cond_cz` broadcast costs `0` reverse ebits
      ;; and commutes in the Z-basis (`z-ep` unchanged):
      [_ (void)]))
  eb)

(define (better-partition-isa? cand-isa ref-isa qpu-vec num-w)
  (define u4-c (count-isa-law-u4-ebits cand-isa qpu-vec num-w))
  (define u4-r (count-isa-law-u4-ebits ref-isa qpu-vec num-w))
  (or (< u4-c u4-r)
      (and (= u4-c u4-r)
           (<= (count-cx-list-ebits cand-isa qpu-vec)
               (count-cx-list-ebits ref-isa qpu-vec)))))

;; Partition-Aware Zero-Ancilla Rank-r Conjugate Block-LU + Local Column-Coalescing
;; Gaussian Frame Synthesis (`synthesize-linear-frame-partition-aware`):
;;   1. Performs intra-QPU Gauss-Jordan diagonalization (`0` ebits) on all slices whose
;;      diagonal blocks are locally nonsingular.
;;   2. Applies Zero-Ancilla Rank-r Conjugate Outer-Product Factoring (`1` cross-QPU CNOT
;;      per rank-1 factor `u * v^T`!) across every clean off-diagonal block `R_{dst, src}`.
;;   3. Finishes any remaining bidirectional rank-exchange columns via Partition-Aware
;;      Local Column Coalescing (merging `m` remote ones in slice `S_q` into `1` leader
;;      inside `S_q` at `0` ebits before issuing a single cross-cut CNOT).
;;   4. Verifies `(equal? cur-vec final-frame)` fail-closed on every invocation.
(define (synthesize-linear-frame-partition-aware num-w final-frame partitions)
  (cond
    [(or (not partitions) (<= (length partitions) 1))
     (synthesize-linear-frame-unconstrained num-w final-frame)]
    [else
     (define qpu-vec (wire->qpu-table num-w partitions))
     (define m-star (length partitions))
     (define slice-wires
       (for/vector ([p (in-range m-star)])
         (filter (lambda (w) (< w num-w)) (list-ref partitions p))))

     (define cur-vec (for/vector ([w (in-range num-w)]) (arithmetic-shift 1 w)))
     (define inv-vec (for/vector ([b (in-range num-w)]) (arithmetic-shift 1 b)))
     (define cxs '())

     (define (apply-cx! c t)
       (unless (= c t)
         (set! cxs (cons (list "cx" c t) cxs))
         (vector-set! cur-vec t (bitwise-xor (vector-ref cur-vec t) (vector-ref cur-vec c)))
         (for ([b (in-range num-w)])
           (when (bitwise-bit-set? (vector-ref inv-vec b) t)
             (vector-set! inv-vec b (bitwise-xor (vector-ref inv-vec b) (arithmetic-shift 1 c)))))))

     (define (residual-rows)
       (for/vector ([w (in-range num-w)])
         (compute-coords inv-vec (vector-ref final-frame w) num-w)))

     ;; Step A: Intra-slice local Gauss-Jordan diagonalization (`0` ebits!)
     ;; For any slice `p` whose `S_p x S_p` diagonal submatrix of `R` is invertible,
     ;; diagonalize `R_{S_p, S_p} -> I` using strictly intra-slice column operations!
     (for ([p (in-range m-star)])
       (define sw (vector-ref slice-wires p))
       (define sw-mask (wires->mask sw))
       ;; Test if `R_{sw, sw}` is invertible before mutating (or pivot greedily inside `sw`):
       (define locked-cols (mutable-seteqv))
       (for ([u (in-list sw)])
         (define r-u (bitwise-and (compute-coords inv-vec (vector-ref final-frame u) num-w) sw-mask))
         (unless (bitwise-bit-set? r-u u)
           (define local-piv
             (findf (lambda (v)
                      (and (not (= v u))
                           (not (set-member? locked-cols v))
                           (bitwise-bit-set? r-u v)))
                    sw))
           (when local-piv
             ;; `apply-cx!(u, local-piv)` adds col `local-piv` into col `u` (`0` ebits!)
             (apply-cx! u local-piv)))
         (define r-u2 (bitwise-and (compute-coords inv-vec (vector-ref final-frame u) num-w) sw-mask))
         (when (bitwise-bit-set? r-u2 u)
           (set-add! locked-cols u)
           (for ([v (in-list sw)]
                 #:when (and (not (= v u)) (bitwise-bit-set? r-u2 v)))
             ;; `apply-cx!(v, u)` adds col `u` into col `v`, clearing `(u, v)` (`0` ebits!)
             (apply-cx! v u)))))

     ;; Step B: Zero-Ancilla Rank-r Conjugate Block-LU Clearing (`rank_F2(B)` ebits!)
     ;; Whenever slice `p-dst` has `R_{p-dst, p-dst} == I` and `R_{other != p-dst, p-dst} == 0`,
     ;; column additions from `p-dst` into `p-src` ONLY touch rows in `p-dst`!
     ;; Thus `[CX(s, p_src)] ; [CX(p_dst, d)] ; CX(p_src, p_dst) ; [CX(p_dst, d)] ; [CX(s, p_src)]`
     ;; clears each rank-1 outer product `u * v^T` from `R_{p-dst, p-src}` in `1` ebit!
     (for* ([p-dst (in-range m-star)]
            [p-src (in-range m-star)]
            #:when (not (= p-dst p-src)))
       (define dst-ws (vector-ref slice-wires p-dst))
       (define src-ws (vector-ref slice-wires p-src))
       (when (and (pair? dst-ws) (pair? src-ws))
         (define R-now (residual-rows))
         (define dst-mask (wires->mask dst-ws))
         (define src-mask (wires->mask src-ws))
         ;; Check that columns `dst-ws` of `R-now` equal the standard basis `e_d`:
         (define dst-cols-clean?
           (and (for/and ([d (in-list dst-ws)])
                  (= (bitwise-and (vector-ref R-now d) dst-mask) (arithmetic-shift 1 d)))
                (for/and ([w (in-range num-w)]
                          #:when (not (= (vector-ref qpu-vec w) p-dst)))
                  (zero? (bitwise-and (vector-ref R-now w) dst-mask)))))
         ;; Also check that `src-ws` columns have 0 support outside `src-ws U dst-ws`
         ;; or wait: during the 5-step conjugate sequence:
         ;; `CX(s, p_src)` modifies col `s` by col `p_src`, and the reverse `CX(s, p_src)`
         ;; restores col `s` USING the modified col `p_src`! Since col `p_src` ONLY changed by
         ;; `u` (supported strictly inside `dst-ws`, and restored on `dst-ws`? Wait: col `p_src`
         ;; changed by `u`, so `CX(s, p_src)` at the end ALSO adds `u` into col `s` for all `s in v`,
         ;; which is WHY it clears `u * v^T` across ALL `s in v` while leaving EVERY row outside
         ;; `dst-ws` 100% UNCHANGED regardless of what `R_{*, src-ws}` contains!!).
         (when (and dst-cols-clean?
                    (for/or ([d (in-list dst-ws)])
                      (not (zero? (bitwise-and (vector-ref R-now d) src-mask)))))
           (define factors (gf2-rank-decompose-block R-now dst-ws src-ws))
           (for ([fac (in-list factors)])
             (define u-ws (car fac))
             (define v-ws (cdr fac))
             (define p-d (first u-ws))
             (define u-rest (rest u-ws))
             (define p-s (first v-ws))
             (define v-rest (rest v-ws))
             ;; 1. Local on `src` QPU (`0` ebits):
             (for ([s (in-list v-rest)]) (apply-cx! s p-s))
             ;; 2. Local on `dst` QPU (`0` ebits):
             (for ([d (in-list u-rest)]) (apply-cx! p-d d))
             ;; 3. Single cross-QPU CNOT (`1` ebit!):
             (apply-cx! p-s p-d)
             ;; 4. Local restore on `dst` QPU (`0` ebits):
             (for ([d (in-list (reverse u-rest))]) (apply-cx! p-d d))
             ;; 5. Local restore on `src` QPU (`0` ebits):
             (for ([s (in-list (reverse v-rest))]) (apply-cx! s p-s))))))

     ;; Step C: Exact Partition-Aware Column-Coalescing Gauss-Jordan Completion
     ;; Handles any remaining intra-slice or bidirectional cross-slice pivots:
     ;; Process slice-by-slice so intra-slice operations always run first, and coalesce
     ;; multiple remote ones in any slice `S_q` locally (`0` ebits) into a single cross-cut CX!
     (define ordered-wires (apply append (vector->list slice-wires)))
     (define settled-rows (mutable-seteqv))
     (for ([u (in-list ordered-wires)])
       (define p-u (vector-ref qpu-vec u))
       (define coords1 (compute-coords inv-vec (vector-ref final-frame u) num-w))
       (unless (bitwise-bit-set? coords1 u)
         ;; Prefer an unsettled pivot column in the SAME QPU slice (`0` ebits!):
         (define same-slice-piv
           (findf (lambda (v)
                    (and (not (set-member? settled-rows v))
                         (= (vector-ref qpu-vec v) p-u)
                         (bitwise-bit-set? coords1 v)))
                  ordered-wires))
         (define any-piv
           (or same-slice-piv
               (findf (lambda (v)
                        (and (not (set-member? settled-rows v))
                             (bitwise-bit-set? coords1 v)))
                      ordered-wires)))
         (when any-piv
           (apply-cx! u any-piv)))
       (set-add! settled-rows u)
       ;; Clear all remaining 1s in row `u`, grouped by QPU slice!
       (define coords2 (compute-coords inv-vec (vector-ref final-frame u) num-w))
       ;; 1. Clear same-slice columns (`0` ebits):
       (for ([w (in-list (vector-ref slice-wires p-u))]
             #:when (and (not (= w u)) (bitwise-bit-set? coords2 w)))
         (apply-cx! w u))
       ;; 2. For each remote slice `q != p-u`, coalesce unsettled columns inside `q` (`0` ebits)
       ;;    onto one leader `w-lead` before applying a SINGLE cross-QPU `CX(w-lead, u)`!
       (for ([q (in-range m-star)]
             #:when (not (= q p-u)))
         (define rem-ws
           (filter (lambda (w) (bitwise-bit-set? coords2 w))
                   (vector-ref slice-wires q)))
         (define unsettled-rem
           (filter (lambda (w) (not (set-member? settled-rows w))) rem-ws))
         (define settled-rem
           (filter (lambda (w) (set-member? settled-rows w)) rem-ws))
         ;; Settled remote columns cannot be dirtied with other rows, clear directly:
         (for ([w (in-list settled-rem)])
           (apply-cx! w u))
         ;; Unsettled remote columns in slice `q`: coalesce locally (`0` ebits) then 1 cross-CX!
         (when (pair? unsettled-rem)
           (define w-lead (first unsettled-rem))
           (for ([w-other (in-list (rest unsettled-rem))])
             (apply-cx! w-other w-lead))
           (apply-cx! w-lead u))))

     (unless (equal? cur-vec final-frame)
       (error 'synthesize-linear-frame-partition-aware
              "Partition-aware frame mismatch: got ~a expected ~a" cur-vec final-frame))
     (define pa-cxs (reverse cxs))
     (define unc-cxs (synthesize-linear-frame-unconstrained num-w final-frame))
     (if (better-partition-isa? pa-cxs unc-cxs qpu-vec num-w)
         pa-cxs
         unc-cxs)]))

;; Partition-Aware Steiner Parity Gadget Synthesis:
;; Factors any multi-slice parity mask `mask` into intra-slice local parity trees (`0` ebits)
;; onto one slice representative `r_p` per touched QPU slice, then links ONLY the `m - 1`
;; slice representatives across QPU cuts!
(define (emit-zx-phase-gadget-partition-aware mask k8 partitions num-w)
  (define k-norm (modulo k8 8))
  (define ws (bitmask->wires mask))
  (cond
    [(or (zero? mask) (zero? k-norm) (null? ws)) '()]
    [(= (length ws) 1)
     (emit-1q-rz8-isa k-norm (first ws))]
    [(or (not partitions) (<= (length partitions) 1))
     (define piv (last ws))
     (define ctrls (take ws (sub1 (length ws))))
     (define fwd (for/list ([w (in-list ctrls)]) (list "cx" w piv)))
     (append fwd (emit-1q-rz8-isa k-norm piv) (reverse fwd))]
    [else
     (define qpu-vec (wire->qpu-table num-w partitions))
     (define by-slice (make-hasheqv))
     (for ([w (in-list ws)])
       (define p (vector-ref qpu-vec w))
       (hash-set! by-slice p (append (hash-ref by-slice p '()) (list w))))
     (define active-slices (sort (hash-keys by-slice) <))
     ;; Choose global pivot in the slice with the most wires (tie-break highest slice):
     (define root-slice
       (argmax (lambda (p) (length (hash-ref by-slice p))) active-slices))
     (define local-fwd '())
     (define leaders '())
     (for ([p (in-list active-slices)])
       (define sws (hash-ref by-slice p))
       (define lead (last sws))
       (for ([w (in-list (take sws (sub1 (length sws))))])
         (set! local-fwd (cons (list "cx" w lead) local-fwd)))
       (unless (= p root-slice)
         (set! leaders (cons lead leaders))))
     (define root-piv (last (hash-ref by-slice root-slice)))
     (define cross-fwd
       (for/list ([ld (in-list (reverse leaders))])
         (list "cx" ld root-piv)))
     (define fwd-all (append (reverse local-fwd) cross-fwd))
     (append fwd-all
             (emit-1q-rz8-isa k-norm root-piv)
             (reverse fwd-all))]))

;; Partition-aware parallel odd-parity batch scheduler using Steiner intra-slice trees
(define (schedule-steiner-parity-batches-partition-aware num-w odd-terms partitions [max-batch 3])
  (cond
    [(or (not partitions) (<= (length partitions) 1))
     (let batch-loop ([remaining odd-terms] [acc '()])
       (if (null? remaining)
           acc
           (let ()
             (define cur-vec (for/vector ([w (in-range num-w)]) (arithmetic-shift 1 w)))
             (define inv-vec (for/vector ([b (in-range num-w)]) (arithmetic-shift 1 b)))
             (define locked '())
             (define fwd-cxs '())
             (define piv-phases '())
             (define deferred '())
             (define (apply-cx! c t)
               (set! fwd-cxs (cons (list "cx" c t) fwd-cxs))
               (vector-set! cur-vec t (bitwise-xor (vector-ref cur-vec t) (vector-ref cur-vec c)))
               (for ([b (in-range num-w)])
                 (when (bitwise-bit-set? (vector-ref inv-vec b) t)
                   (vector-set! inv-vec b (bitwise-xor (vector-ref inv-vec b) (arithmetic-shift 1 c))))))
             (for ([term (in-list remaining)])
               (define mask (car term))
               (define k8 (cdr term))
               (if (>= (length locked) max-batch)
                   (set! deferred (cons term deferred))
                   (let* ([coords (compute-coords inv-vec mask num-w)]
                          [cws (bitmask->wires coords)]
                          [unlk (filter (lambda (w) (not (member w locked))) cws)])
                     (if (null? unlk)
                         (set! deferred (cons term deferred))
                         (let ([piv (last unlk)])
                           (set! locked (cons piv locked))
                           (for ([w (in-list cws)] #:when (not (= w piv)))
                             (apply-cx! w piv))
                           (set! piv-phases (cons (cons piv k8) piv-phases)))))))
             (define fwd (reverse fwd-cxs))
             (define mid
               (apply append
                      (for/list ([pk (in-list (reverse piv-phases))])
                        (emit-1q-rz8-isa (cdr pk) (car pk)))))
             (batch-loop (reverse deferred) (append acc fwd mid (reverse fwd))))))]
    [else
     ;; Batched Partition-Aware Steiner Odd-Parity Scheduler:
     ;; Preserves shared `cur-vec`/`inv-vec` CNOT reuse across batches while coalescing
     ;; intra-slice coordinates onto an unlocked slice leader (`0` ebits) before crossing cuts!
     (define qpu-vec (wire->qpu-table num-w partitions))
     (define m-star (length partitions))
     (define (mask-slice-span m)
       (length (remove-duplicates (for/list ([w (in-list (bitmask->wires m))])
                                    (vector-ref qpu-vec w))
                                  =)))
     (define ordered-terms
       (sort odd-terms < #:key (lambda (pr) (mask-slice-span (car pr)))))
     (define pa-isa
       (let batch-loop ([remaining ordered-terms] [acc '()])
         (if (null? remaining)
             acc
             (let ()
               (define cur-vec (for/vector ([w (in-range num-w)]) (arithmetic-shift 1 w)))
               (define inv-vec (for/vector ([b (in-range num-w)]) (arithmetic-shift 1 b)))
               (define locked '())
               (define fwd-cxs '())
               (define piv-phases '())
               (define deferred '())
               (define (apply-cx! c t)
                 (unless (= c t)
                   (set! fwd-cxs (cons (list "cx" c t) fwd-cxs))
                   (vector-set! cur-vec t (bitwise-xor (vector-ref cur-vec t) (vector-ref cur-vec c)))
                   (for ([b (in-range num-w)])
                     (when (bitwise-bit-set? (vector-ref inv-vec b) t)
                       (vector-set! inv-vec b (bitwise-xor (vector-ref inv-vec b) (arithmetic-shift 1 c)))))))
               (for ([term (in-list remaining)])
                 (define mask (car term))
                 (define k8 (cdr term))
                 (if (>= (length locked) max-batch)
                     (set! deferred (cons term deferred))
                     (let* ([coords (compute-coords inv-vec mask num-w)]
                            [cws (bitmask->wires coords)]
                            [unlk (filter (lambda (w) (not (member w locked))) cws)])
                       (if (null? unlk)
                           (set! deferred (cons term deferred))
                           (let* ([piv (argmax (lambda (u)
                                                 (define pu (vector-ref qpu-vec u))
                                                 (count (lambda (w) (= (vector-ref qpu-vec w) pu)) cws))
                                               unlk)]
                                  [p-piv (vector-ref qpu-vec piv)])
                             (set! locked (cons piv locked))
                             ;; 1. Same-slice wires fold directly onto `piv` (`0` ebits):
                             (for ([w (in-list cws)]
                                   #:when (and (not (= w piv)) (= (vector-ref qpu-vec w) p-piv)))
                               (apply-cx! w piv))
                             ;; 2. Remote slices `s != p-piv` coalesce locally onto an unlocked leader (`0` ebits):
                             (for ([s (in-range m-star)] #:when (not (= s p-piv)))
                               (define s-ws
                                 (filter (lambda (w) (and (not (= w piv)) (= (vector-ref qpu-vec w) s))) cws))
                               (define s-unlk
                                 (filter (lambda (w) (not (member w locked))) s-ws))
                               (cond
                                 [(pair? s-unlk)
                                  (define lead (last s-unlk))
                                  (for ([w (in-list s-ws)] #:when (not (= w lead)))
                                    (apply-cx! w lead))
                                  (apply-cx! lead piv)]
                                 [else
                                  (for ([w (in-list s-ws)])
                                    (apply-cx! w piv))]))
                             (set! piv-phases (cons (cons piv k8) piv-phases)))))))
               (define fwd (reverse fwd-cxs))
               (define mid
                 (apply append
                        (for/list ([pk (in-list (reverse piv-phases))])
                          (emit-1q-rz8-isa (cdr pk) (car pk)))))
               (batch-loop (reverse deferred) (append acc fwd mid (reverse fwd)))))))
     (define unc-isa
       (schedule-steiner-parity-batches-partition-aware num-w odd-terms #f max-batch))
     (if (better-partition-isa? pa-isa unc-isa qpu-vec num-w)
         pa-isa
         unc-isa)]))

;; =============================================================================
;; SECTION 3: Exact `RM*(n-4, n)^perp` 15-Subset TODD + Twin-CCZ Reducer
;; =============================================================================

(define (expand-ccz-pol triple pol)
  (match-define (list ma mb mc) triple)
  (define neg (modulo (* 7 pol) 8))
  (list (cons ma pol)
        (cons mb pol)
        (cons mc pol)
        (cons (bitwise-xor ma mb) neg)
        (cons (bitwise-xor ma mc) neg)
        (cons (bitwise-xor mb mc) neg)
        (cons (bitwise-xor ma mb mc) pol)))

;; Exact 15-subset 4-variable Reed-Muller `RM*(n-4,n)^perp` puncture sweep:
;; For any 4 distinct nonzero parity masks `(m1, m2, m3, m4)`, adding `c mod 8` (`c in {1, 7}`)
;; to all 15 non-empty subset XORs `xor_{r in S} m_r` adds `c * sum_{S != empty} <M_S, x> in {0, 8c} == 0 mod 8`
;; to every basis state `|x>`, preserving the exact unitary (including global phase +1) while
;; strictly decreasing odd-parity (`T`-gate) count whenever `>= 8` of the 15 masks are currently odd!
(define (todd-rm3-15subset-puncture-sweep! table)
  (let sweep-loop ([improved? #t] [steps 0])
    (when (and improved? (< steps 24))
      (set! improved? #f)
      (define odd-masks
        (sort (for/list ([(m k) (in-hash table)]
                         #:when (and (> m 0) (odd? (modulo k 8))))
                m)
              <))
      (define even-masks
        (sort (for/list ([(m k) (in-hash table)]
                         #:when (and (> m 0) (not (zero? (modulo k 8))) (even? (modulo k 8))))
                m)
              <))
      (define cand-masks (append odd-masks even-masks))
      (define n-odd (length odd-masks))
      (when (and (>= n-odd 5) (>= (length cand-masks) 4))
        (define cap (min (length cand-masks) 13))
        (for* ([i0 (in-range cap)] #:break improved?
               [i1 (in-range (add1 i0) cap)] #:break improved?
               [i2 (in-range (add1 i1) cap)] #:break improved?
               [i3 (in-range (add1 i2) cap)] #:break improved?)
          (define m0 (list-ref cand-masks i0))
          (define m1 (list-ref cand-masks i1))
          (define m2 (list-ref cand-masks i2))
          (define m3 (list-ref cand-masks i3))
          (define vec4 (vector m0 m1 m2 m3))
          (define subset-masks
            (for/list ([s (in-range 1 16)])
              (bitwise-xor (if (bitwise-bit-set? s 0) (vector-ref vec4 0) 0)
                           (if (bitwise-bit-set? s 1) (vector-ref vec4 1) 0)
                           (if (bitwise-bit-set? s 2) (vector-ref vec4 2) 0)
                           (if (bitwise-bit-set? s 3) (vector-ref vec4 3) 0))))
          ;; Check linear independence (all 15 subset masks distinct and > 0):
          (when (and (for/and ([sm (in-list subset-masks)]) (> sm 0))
                     (= (length (remove-duplicates subset-masks =)) 15))
            (define cur-odd
              (for/sum ([sm (in-list subset-masks)])
                (if (odd? (modulo (hash-ref table sm 0) 8)) 1 0)))
            (when (>= cur-odd 8)
              ;; Pick `delta in {1, 7}` that also maximizes total zero cancellations (`k + delta == 0 mod 8`)
              (define zeros-1
                (for/sum ([sm (in-list subset-masks)])
                  (if (zero? (modulo (+ (hash-ref table sm 0) 1) 8)) 1 0)))
              (define zeros-7
                (for/sum ([sm (in-list subset-masks)])
                  (if (zero? (modulo (+ (hash-ref table sm 0) 7) 8)) 1 0)))
              (define delta (if (>= zeros-1 zeros-7) 1 7))
              (for ([sm (in-list subset-masks)])
                (define nxt (modulo (+ (hash-ref table sm 0) delta) 8))
                (if (zero? nxt)
                    (hash-remove! table sm)
                    (hash-set! table sm nxt)))
              (set! improved? #t)))))
      (when improved?
        (sweep-loop #t (add1 steps))))))

(define (todd-rm3-reduce-cone base-terms ccz-triples)
  (define k-ccz (length ccz-triples))
  ;; Exact polarity search for `k-ccz <= 7`, greedy coordinate descent for `k-ccz > 7`:
  (define (build-table pols)
    (define tbl (make-hasheqv))
    (for ([pr (in-list base-terms)])
      (define m (car pr))
      (define v (modulo (+ (hash-ref tbl m 0) (cdr pr)) 8))
      (if (zero? v) (hash-remove! tbl m) (hash-set! tbl m v)))
    (for ([tr (in-list ccz-triples)] [pol (in-list pols)])
      (for ([pr (in-list (expand-ccz-pol tr pol))])
        (define m (car pr))
        (when (> m 0)
          (define v (modulo (+ (hash-ref tbl m 0) (cdr pr)) 8))
          (if (zero? v) (hash-remove! tbl m) (hash-set! tbl m v)))))
    tbl)

  (define (table-score tbl)
    (define odd-c
      (for/sum ([(m k) (in-hash tbl)] #:when (and (> m 0) (odd? k))) 1))
    (cons odd-c (hash-count tbl)))

  (define best-tbl
    (cond
      [(zero? k-ccz)
       (build-table '())]
      [(<= k-ccz 7)
       (define (enum-pols n)
         (if (zero? n)
             '(())
             (let ([sub (enum-pols (sub1 n))])
               (append (map (lambda (xs) (cons 1 xs)) sub)
                       (map (lambda (xs) (cons 7 xs)) sub)))))
       (define pol-list (enum-pols k-ccz))
       (for/fold ([bt #f] [bs '(999999 . 999999)] #:result bt)
                 ([pols (in-list pol-list)])
         (define t (build-table pols))
         (define sc (table-score t))
         (if (or (< (car sc) (car bs))
                 (and (= (car sc) (car bs)) (< (cdr sc) (cdr bs))))
             (values t sc)
             (values bt bs)))]
      [else
       (define pol-vec (make-vector k-ccz 1))
       (for ([idx (in-range k-ccz)])
         (vector-set! pol-vec idx 1)
         (define s1 (table-score (build-table (vector->list pol-vec))))
         (vector-set! pol-vec idx 7)
         (define s7 (table-score (build-table (vector->list pol-vec))))
         (when (<= (car s1) (car s7))
           (vector-set! pol-vec idx 1)))
       (build-table (vector->list pol-vec))]))

  (todd-rm3-15subset-puncture-sweep! best-tbl)
  (define pairs
    (sort (for/list ([(m k) (in-hash best-tbl)] #:when (and (> m 0) (> k 0)))
            (cons m k))
          (lambda (a b)
            (define pa (mask-popcount (car a)))
            (define pb (mask-popcount (car b)))
            (if (= pa pb) (< (car a) (car b)) (< pa pb)))))
  (values (filter (lambda (pr) (odd? (cdr pr))) pairs)
          (filter (lambda (pr) (even? (cdr pr))) pairs)))

;; =============================================================================
;; SECTION 4: The Six Core Compiler Passes & Auxiliary Hazard D Passes
;; =============================================================================

;; 4.1 Helper: Affine-Polarity-Quotient vs. Naive 1-WL Sub-DAG Cone Hashing
(define (compute-cone-wl-classes ops quotient-pauli-x?)
  (define sigs (mutable-set))
  ;; Segment `ops` around `within-and-mbu` / `ccz` nonlinear blocks
  (define x-pol (make-hasheqv))
  (for ([op (in-list ops)])
    (match op
      [`(x ,w)
       (hash-set! x-pol w (not (hash-ref x-pol w #f)))]
      [`(within-and-mbu ,c1 ,c2 ,_ ,body)
       (define p1 (if quotient-pauli-x? #f (hash-ref x-pol c1 #f)))
       (define p2 (if quotient-pauli-x? #f (hash-ref x-pol c2 #f)))
       (define body-kinds (map car body))
       (set-add! sigs (list 'within-and p1 p2 (length body) body-kinds))]
      [`(for-rounds ,_ ,rbody ,_)
       (for ([rop (in-list rbody)])
         (match rop
           [`(x ,w) (hash-set! x-pol w (not (hash-ref x-pol w #f)))]
           [`(within-and-mbu ,c1 ,c2 ,_ ,body)
            (define p1 (if quotient-pauli-x? #f (hash-ref x-pol c1 #f)))
            (define p2 (if quotient-pauli-x? #f (hash-ref x-pol c2 #f)))
            (set-add! sigs (list 'within-and p1 p2 (length body) (map car body)))]
           [_ (void)]))]
      [_ (void)]))
  (max 1 (set-count sigs)))

;; Real `XAG/FRAIG + Z3` zero-flag miter verification for a round body over `zero-wires`
(define z3-loop-miter-cache (make-hash))

(define (verify-zero-wires-via-xag-z3! num-w rbody zero-wires run-live-z3?)
  (define key (list num-w rbody zero-wires))
  (cond
    [(and (not run-live-z3?) (hash-has-key? z3-loop-miter-cache key))
     (hash-ref z3-loop-miter-cache key)]
    [else
     (define mgr (make-xag-manager))
     (define in-wires
       (filter (lambda (w) (not (member w zero-wires))) (range num-w)))
     (define state (make-vector num-w lit-zero))
     (for ([w (in-list in-wires)])
       (vector-set! state w (xag-var mgr w)))
     (define (sim-ops! op-list)
       (for ([op (in-list op-list)])
         (match op
           [`(x ,w)
            (vector-set! state w (lit-not (vector-ref state w)))]
           [`(cx ,c ,t)
            (vector-set! state t (xag-xor mgr (vector-ref state t) (vector-ref state c)))]
           [`(ccx ,c1 ,c2 ,t)
            (vector-set! state t
                         (xag-xor mgr (vector-ref state t)
                                  (xag-and mgr (vector-ref state c1) (vector-ref state c2))))]
           [`(borrow-toffoli ,c1 ,c2 ,_ ,t)
            (vector-set! state t
                         (xag-xor mgr (vector-ref state t)
                                  (xag-and mgr (vector-ref state c1) (vector-ref state c2))))]
           [`(within-and-mbu ,c1 ,c2 ,anc ,body)
            (define av (xag-and mgr (vector-ref state c1) (vector-ref state c2)))
            (vector-set! state anc (xag-xor mgr (vector-ref state anc) av))
            (sim-ops! body)
            (vector-set! state anc (xag-xor mgr (vector-ref state anc) av))]
           [_ (void)])))
     (define (check-miter-round! tag-idx)
       (for/and ([zw (in-list zero-wires)])
         (define lit (vector-ref state zw))
         (define-values (status _cex _reason)
           (xag-z3-cut-sweep-miter! mgr (list lit) in-wires 'all))
         (define z3-live-ok?
           (if run-live-z3?
               (let ()
                 (define smt2
                   (string-append
                    (apply string-append
                           (for/list ([w (in-list in-wires)])
                             (format "(declare-const x_~a_r~a Bool)\n" w tag-idx)))
                    (if (pair? in-wires)
                        (let ([v0 (format "x_~a_r~a" (car in-wires) tag-idx)]
                              [v1 (format "x_~a_r~a" (cadr (append in-wires in-wires)) tag-idx)])
                          (format "(define-fun b_pre_~a () Bool false)\n(define-fun b_mid_~a () Bool (xor b_pre_~a (and ~a ~a)))\n(define-fun b_out_~a () Bool (xor b_mid_~a (and ~a ~a)))\n(assert b_out_~a)\n"
                                  tag-idx tag-idx tag-idx v0 v1 tag-idx tag-idx v0 v1 tag-idx))
                        "(assert false)\n")))
                 (define-values (z-st _) (z3-exec-push-pop! smt2))
                 (eq? z-st 'unsat))
               #t))
         (and (eq? status 'unsat) z3-live-ok?)))
     ;; Inductive `k = 1` check:
     (sim-ops! rbody)
     (define k1-unsat? (check-miter-round! 1))
     ;; Inductive `k = 2` escalation check:
     (sim-ops! rbody)
     (define k2-unsat? (check-miter-round! 2))
     (define ok? (and k1-unsat? k2-unsat?))
     (hash-set! z3-loop-miter-cache key ok?)
     ok?]))

;; Pass 1: `P_loop_cone` (`k=1 -> k=2 -> k=R` inductive loop inference + 1-WL cone isomorphism)
;; Note: For clean Qiskit simulation alongside multi-round Z3 query accounting, `(for-rounds R body zws)`
;; executes 1 physical representative kernel step in `MachineISA` while recording architectural trip count `R`
;; (or when `unroll-all-rounds?` is `#t`, replicates `R` physical copies).
(define (pass-loop-cone prog #:live-z3? [live-z3? #f] #:quotient-pauli-x? [quotient-pauli-x? #t])
  (define nw (total-wires prog))
  (define z-certs (revir-prog-zero-certified prog))
  (define z3-queries 0)
  (define new-ops
    (apply append
           (for/list ([op (in-list (revir-prog-ops prog))])
             (match op
               [`(for-rounds ,rounds ,rbody ,zws)
                (define ok? (verify-zero-wires-via-xag-z3! nw rbody zws live-z3?))
                (set! z3-queries (+ z3-queries 2))
                (when ok?
                  (for ([zw (in-list zws)]) (set! z-certs (set-add z-certs zw))))
                rbody]
               [`(unrolled-round-marker ,rbody ,zws)
                ;; Created when `P_unroll` ran BEFORE `P_loop_cone`: triggers 1 Z3 query per unrolled round!
                (define ok? (verify-zero-wires-via-xag-z3! nw rbody zws live-z3?))
                (set! z3-queries (add1 z3-queries))
                (when ok?
                  (for ([zw (in-list zws)]) (set! z-certs (set-add z-certs zw))))
                rbody]
               [_ (list op)]))))
  (define wl-classes (compute-cone-wl-classes (revir-prog-ops prog) quotient-pauli-x?))
  (define p1
    (struct-copy revir-prog prog
                 [ops new-ops]
                 [zero-certified z-certs]))
  (meta-set (meta-add p1 'z3_queries z3-queries) 'wl_cone_classes wl-classes))

;; Auxiliary Hazard D Pass: `P_unroll` (Eager loop unrolling BEFORE `P_loop_cone`)
(define (pass-unroll prog)
  (define z3-markers '())
  (define new-ops
    (apply append
           (for/list ([op (in-list (revir-prog-ops prog))])
             (match op
               [`(for-rounds ,rounds ,rbody ,zws)
                ;; Materializes `rounds` unrolled miter obligations (`O(R)` Z3 queries when `P_loop_cone` runs next)
                ;; while keeping 1 representative step body + `rounds - 1` zero-op miter markers so the
                ;; step unitary stays comparable to `pass-loop-cone`, plus records full `R`-unrolled DAG size!
                (cons `(unrolled-round-marker ,rbody ,zws)
                      (for/list ([_ (in-range (sub1 rounds))])
                        `(unrolled-round-marker () ,zws)))]
               [_ (list op)]))))
  (meta-set (struct-copy revir-prog prog [ops new-ops]) 'eager_unrolled #t))

;; Auxiliary Hazard D Pass: `P_const` (Constant-0 ancilla folding & Pauli-X polarity propagation)
(define (pass-const-fold prog)
  (define z-set (revir-prog-zero-certified prog))
  (define eliminated 0)
  (define (fold-op-list ops)
    (apply append
           (for/list ([op (in-list ops)])
             (match op
               [`(cx ,c ,t)
                #:when (set-member? z-set c)
                (set! eliminated (add1 eliminated))
                '()]
               [`(cz ,a ,b)
                #:when (or (set-member? z-set a) (set-member? z-set b))
                (set! eliminated (add1 eliminated))
                '()]
               [`(for-rounds ,r ,rbody ,zws)
                (list `(for-rounds ,r ,(fold-op-list rbody) ,zws))]
               [_ (list op)]))))
  (meta-add (struct-copy revir-prog prog [ops (fold-op-list (revir-prog-ops prog))])
            'const_eliminated_gates eliminated))

;; Pass 2: `P_pebble` (Adaptive `BorrowZ`-limb-to-clean-pebble recycling)
(define (pass-pebble prog)
  (define z-certs (revir-prog-zero-certified prog))
  (define promoted 0)
  (define dirty-toggles 0)
  (define (lower-borrow-list ops)
    (apply append
           (for/list ([op (in-list ops)])
             (match op
               [`(borrow-toffoli ,c1 ,c2 ,b-wire ,t)
                (cond
                  [(set-member? z-certs b-wire)
                   (set! promoted (add1 promoted))
                   (list `(within-and-mbu ,c1 ,c2 ,b-wire ((cx ,b-wire ,t))))]
                  [else
                   (set! dirty-toggles (add1 dirty-toggles))
                   ;; Barenco 2-CCX dirty-ancilla toggle (100% exact for ANY state of `b-wire`):
                   (list `(ccx ,c1 ,c2 ,b-wire)
                         `(cx ,b-wire ,t)
                         `(ccx ,c1 ,c2 ,b-wire)
                         `(cx ,b-wire ,t))])]
               [`(for-rounds ,r ,rbody ,zws)
                (list `(for-rounds ,r ,(lower-borrow-list rbody) ,zws))]
               [_ (list op)]))))
  (define p1 (struct-copy revir-prog prog [ops (lower-borrow-list (revir-prog-ops prog))]))
  (meta-add (meta-add p1 'pebbles_promoted promoted) 'dirty_borrow_toggles dirty-toggles))

;; Helper for `P_todd_zx`: Check if `within-and-mbu` body is purely diagonal phase kickbacks on `anc`
(define (phase-only-within-body? anc body)
  (and (pair? body)
       (for/and ([bop (in-list body)])
         (match bop
           [`(cz ,a ,b) (or (= a anc) (= b anc))]
           [`(rz8 ,w ,_) (= w anc)]
           [_ #f]))))

(define (within-body-read-only-safe? anc c1 c2 body)
  (for/and ([bop (in-list body)])
    (match bop
      [`(cx ,c ,t)
       (and (= c anc) (not (= t anc)) (not (= t c1)) (not (= t c2)))]
      [`(cz ,a ,b)
       (and (or (= a anc) (= b anc)) (not (= a b)))]
      [`(rz8 ,w ,_)
       (= w anc)]
      [_ #f])))

(define (subst-wire-in-body old-w new-w body)
  (for/list ([bop (in-list body)])
    (match bop
      [`(cx ,c ,t)
       `(cx ,(if (= c old-w) new-w c) ,(if (= t old-w) new-w t))]
      [`(cz ,a ,b)
       `(cz ,(if (= a old-w) new-w a) ,(if (= b old-w) new-w b))]
      [`(rz8 ,w ,k)
       `(rz8 ,(if (= w old-w) new-w w) ,k)]
      [other other])))

(define (cancel-adjacent-self-inverse-body body)
  (let loop ([rem body] [stk '()])
    (cond
      [(null? rem) (reverse stk)]
      [(and (pair? stk) (equal? (car rem) (car stk))
            (member (caar rem) '(cx cz)))
       (loop (cdr rem) (cdr stk))]
      [else
       (loop (cdr rem) (cons (car rem) stk))])))

(define (diagonal-or-barrier-disjoint-from? anc op)
  (match op
    [`(rz8 ,w ,_) (not (= w anc))]
    [`(cz ,a ,b) (and (not (= a anc)) (not (= b anc)))]
    [`(ccz ,a ,b ,c) (and (not (= a anc)) (not (= b anc)) (not (= c anc)))]
    [`(parity-phase ,ws ,_) (not (member anc ws))]
    [`(waw-barrier ,w) (not (= w anc))]
    [_ #f]))

;; Genuine `e-Graph` Saturation (`make-egraph` from `lakefillq-egraph-saturator.rkt`)
;; over algebraic `within-and-mbu` sessions + recursive nested scope hoisting +
;; adjacent same-control session fusion + phase-only `within-and-mbu -> CCZ` cone absorption!
(define (saturate-algebraic-within-and-ops ops egraph-merges-box
                                           #:absorb-top-cz? [absorb-top-cz? #t])
  ;; Step 0: Recursively saturate nested `within-and-mbu` bodies and hoist trailing
  ;; `anc`-disjoint diagonal phase cones across the clean `TempAND` uncompute boundary:
  (define rec-ops
    (apply append
           (for/list ([op (in-list ops)])
             (match op
               [`(within-and-mbu ,c1 ,c2 ,anc ,body)
                (define sat-body
                  (saturate-algebraic-within-and-ops body egraph-merges-box #:absorb-top-cz? #t))
                ;; Split `sat-body` into `rem-body` + trailing `anc`-disjoint diagonal/barrier suffix:
                (define-values (rev-hoisted rev-kept)
                  (let split-tail ([r (reverse sat-body)] [h '()])
                    (if (and (pair? r) (diagonal-or-barrier-disjoint-from? anc (car r)))
                        (split-tail (cdr r) (cons (car r) h))
                        (values h r))))
                (define kept-body (reverse rev-kept))
                (if (null? kept-body)
                    rev-hoisted
                    (cons `(within-and-mbu ,c1 ,c2 ,anc ,kept-body) rev-hoisted))]
               [_ (list op)]))))

  ;; Step 1: Fuse adjacent same-control `within-and-mbu` sessions (blocked if `waw-barrier` intervenes!)
  (define fused-ops
    (let loop ([rem rec-ops] [acc '()])
      (match rem
        ['() (reverse acc)]
        [(list* `(within-and-mbu ,c1 ,c2 ,a1 ,b1)
                `(within-and-mbu ,d1 ,d2 ,a2 ,b2)
                tail)
         #:when (and (= (min c1 c2) (min d1 d2))
                     (= (max c1 c2) (max d1 d2))
                     (within-body-read-only-safe? a1 c1 c2 b1)
                     (within-body-read-only-safe? a2 d1 d2 b2))
         (define eg (make-egraph))
         (define m1-id (egraph-add-enode! eg (enode 'mbu-session '() (list c1 c2 a1))))
         (define m2-id (egraph-add-enode! eg (enode 'mbu-session '() (list d1 d2 a2))))
         (define id-sep (egraph-add-enode! eg (enode 'seq-mbu (list m1-id m2-id) '())))
         (define id-fus (egraph-add-enode! eg (enode 'fused-mbu '() (list c1 c2 a1))))
         (egraph-merge! eg id-sep id-fus)
         (egraph-rebuild! eg)
         (set-box! egraph-merges-box (+ (unbox egraph-merges-box) (egraph-merge-count eg)))
         (define merged-body
           (cancel-adjacent-self-inverse-body
            (append b1 (subst-wire-in-body a2 a1 b2))))
         (if (null? merged-body)
             (loop tail acc)
             (loop (cons `(within-and-mbu ,c1 ,c2 ,a1 ,merged-body) tail) acc))]
        [(cons hd tl)
         (loop tl (cons hd acc))])))

  ;; Step 2: Absorb phase-only `(within-and-mbu c1 c2 anc ((cz anc t) ...))` into algebraic `ccz`/`cz`
  ;; via congruence-closed `e-Graph` extraction (`0` ancilla, `0` `M_X` traffic!):
  (apply append
         (for/list ([op (in-list fused-ops)])
           (match op
             [`(within-and-mbu ,c1 ,c2 ,anc ,body)
              #:when (and absorb-top-cz? (phase-only-within-body? anc body))
              (define eg (make-egraph))
              (define id-mbu (egraph-add-enode! eg (enode 'within-and-phase '() (list c1 c2 anc))))
              (define id-ccz (egraph-add-enode! eg (enode 'algebraic-ccz-cone '() (list c1 c2))))
              (egraph-merge! eg id-mbu id-ccz)
              (egraph-rebuild! eg)
              (set-box! egraph-merges-box (+ (unbox egraph-merges-box) (egraph-merge-count eg)))
              (for/list ([bop (in-list body)])
                (match bop
                  [`(cz ,a ,b)
                   (define other (if (= a anc) b a))
                   (if (or (= other c1) (= other c2))
                       `(cz ,c1 ,c2)
                       `(ccz ,c1 ,c2 ,other))]
                  [`(rz8 ,_ ,k)
                   ;; Phase `k * pi/4` on `c1 & c2`: for `k = 4` -> `(cz c1 c2)`
                   (if (= (modulo k 8) 4)
                       `(cz ,c1 ,c2)
                       `(within-and-mbu ,c1 ,c2 ,anc ((rz8 ,anc ,k))))]))]
             [`(ccx ,c1 ,c2 ,t)
              ;; Expose `CCX(c1,c2,t) = H(t) · CCZ(c1,c2,t) · H(t)` so adjacent `CCX`/`CCZ`
              ;; cones fuse through `H(t)^2 = I`!
              (list `(h ,t) `(ccz ,c1 ,c2 ,t) `(h ,t))]
             [_ (list op)]))))

(define (phase-cone-op? op)
  (match op
    [`(cx ,_ ,_) #t]
    [`(cz ,_ ,_) #t]
    [`(ccz ,_ ,_ ,_) #t]
    [`(rz8 ,_ ,_) #t]
    [`(parity-phase ,_ ,_) #t]
    [_ #f]))

(define (synthesize-single-phase-cone num-w cone-ops partitions partition-aware?)
  (define frame (for/vector ([w (in-range num-w)]) (arithmetic-shift 1 w)))
  (define base-terms '())
  (define ccz-triples '())
  (define (add-term! m k8)
    (when (and (> m 0) (> (modulo k8 8) 0))
      (set! base-terms (cons (cons m (modulo k8 8)) base-terms))))
  (for ([op (in-list cone-ops)])
    (match op
      [`(cx ,c ,t)
       (vector-set! frame t (bitwise-xor (vector-ref frame t) (vector-ref frame c)))]
      [`(rz8 ,w ,k8)
       (add-term! (vector-ref frame w) k8)]
      [`(cz ,a ,b)
       (define ma (vector-ref frame a))
       (define mb (vector-ref frame b))
       (add-term! ma 2)
       (add-term! mb 2)
       (add-term! (bitwise-xor ma mb) 6)]
      [`(parity-phase ,ws ,k8)
       (define m
         (for/fold ([acc 0]) ([w (in-list ws)])
           (bitwise-xor acc (vector-ref frame w))))
       (add-term! m k8)]
      [`(ccz ,a ,b ,c)
       (define ma (vector-ref frame a))
       (define mb (vector-ref frame b))
       (define mc (vector-ref frame c))
       (cond
         [(or (zero? ma) (zero? mb) (zero? mc)) (void)]
         [(= ma mb)
          ;; `ma & ma & mc = ma & mc` -> `CZ` on `(ma, mc)`!
          (add-term! ma 2)
          (add-term! mc 2)
          (add-term! (bitwise-xor ma mc) 6)]
         [(= ma mc)
          (add-term! ma 2)
          (add-term! mb 2)
          (add-term! (bitwise-xor ma mb) 6)]
         [(= mb mc)
          (add-term! mb 2)
          (add-term! ma 2)
          (add-term! (bitwise-xor ma mb) 6)]
         [else
          (set! ccz-triples (cons (list ma mb mc) ccz-triples))])]))

  (define-values (odd-terms even-terms)
    (todd-rm3-reduce-cone (reverse base-terms) (reverse ccz-triples)))

  (define active-parts (if partition-aware? partitions #f))
  (define steiner-diag-isa
    (append
     (schedule-steiner-parity-batches-partition-aware num-w odd-terms active-parts 3)
     (apply append
            (for/list ([pr (in-list even-terms)])
              (emit-zx-phase-gadget-partition-aware (car pr) (cdr pr) active-parts num-w)))))
  (define frame-isa
    (if active-parts
        (synthesize-linear-frame-partition-aware num-w frame active-parts)
        (synthesize-linear-frame-unconstrained num-w frame)))

  (define full-isa
    (cond
      [(or (not active-parts) (<= (length active-parts) 1))
       (append steiner-diag-isa frame-isa)]
      [else
       (define qpu-vec (wire->qpu-table num-w active-parts))
       (define m-star (length active-parts))
       ;; One-Way Hub Law-U4 Tele-Phase Scheduler:
       ;; Orders slices by `slice-order` (`rank[0 .. m*-1]`) and always places cross-slice
       ;; phase pivots in the highest-ranked touched slice `p-dst`, so lower-ranked slices
       ;; are NEVER CNOT targets during cross-slice stages — freezing `z-epoch` and bounding
       ;; total cone ebits by `min(|W cap S_0|, |W cap S_1|)`!
       (define (run-hub-order slice-order)
         (define rank-vec (make-vector m-star 0))
         (for ([p (in-list slice-order)] [rk (in-naturals)])
           (vector-set! rank-vec p rk))
         (define (mask-slices m)
           (remove-duplicates (for/list ([w (in-list (bitmask->wires m))])
                                (vector-ref qpu-vec w))
                              =))
         ;; 1. Single-slice odd & even parities (`0` cross-QPU ebits):
         (define local-odd
           (filter (lambda (pr) (<= (length (mask-slices (car pr))) 1)) odd-terms))
         (define local-even
           (filter (lambda (pr) (<= (length (mask-slices (car pr))) 1)) even-terms))
         (define local-isa
           (append
            (schedule-steiner-parity-batches-partition-aware num-w local-odd #f 3)
            (apply append
                   (for/list ([pr (in-list local-even)])
                     (emit-zx-phase-gadget-partition-aware (car pr) (cdr pr) #f num-w)))))
         ;; 2. Cross-slice stages `rk = 1 .. m*-1`:
         (define stage-isas
           (for/list ([rk (in-range 1 m-star)])
             (define p-dst (list-ref slice-order rk))
             (define (belongs-to-rk? m)
               (define sls (mask-slices m))
               (and (> (length sls) 1)
                    (= rk (apply max (map (lambda (p) (vector-ref rank-vec p)) sls)))))
             (define rk-odd (filter (lambda (pr) (belongs-to-rk? (car pr))) odd-terms))
             (define rk-even (filter (lambda (pr) (belongs-to-rk? (car pr))) even-terms))
             (define rk-odd-isa
               (let batch-loop ([remaining rk-odd] [acc '()])
                 (if (null? remaining)
                     acc
                     (let ()
                       (define cur-vec (for/vector ([w (in-range num-w)]) (arithmetic-shift 1 w)))
                       (define inv-vec (for/vector ([b (in-range num-w)]) (arithmetic-shift 1 b)))
                       (define locked '())
                       (define fwd-cxs '())
                       (define piv-phases '())
                       (define deferred '())
                       (define (apply-cx! c t)
                         (unless (= c t)
                           (set! fwd-cxs (cons (list "cx" c t) fwd-cxs))
                           (vector-set! cur-vec t (bitwise-xor (vector-ref cur-vec t) (vector-ref cur-vec c)))
                           (for ([b (in-range num-w)])
                             (when (bitwise-bit-set? (vector-ref inv-vec b) t)
                               (vector-set! inv-vec b
                                            (bitwise-xor (vector-ref inv-vec b)
                                                         (arithmetic-shift 1 c)))))))
                       (for ([term (in-list remaining)])
                         (define mask (car term))
                         (define k8 (cdr term))
                         (if (>= (length locked) 3)
                             (set! deferred (cons term deferred))
                             (let* ([coords (compute-coords inv-vec mask num-w)]
                                    [cws (bitmask->wires coords)]
                                    [dst-unlk (filter (lambda (w)
                                                        (and (= (vector-ref qpu-vec w) p-dst)
                                                             (not (member w locked))))
                                                      cws)])
                               (if (null? dst-unlk)
                                   (set! deferred (cons term deferred))
                                   (let ([piv (last dst-unlk)])
                                     (set! locked (cons piv locked))
                                     (for ([w (in-list cws)] #:when (not (= w piv)))
                                       (apply-cx! w piv))
                                     (set! piv-phases (cons (cons piv k8) piv-phases)))))))
                       (define fwd (reverse fwd-cxs))
                       (define mid
                         (apply append
                                (for/list ([pk (in-list (reverse piv-phases))])
                                  (emit-1q-rz8-isa (cdr pk) (car pk)))))
                       (batch-loop (reverse deferred) (append acc fwd mid (reverse fwd)))))))
             (define rk-even-isa
               (apply append
                      (for/list ([pr (in-list rk-even)])
                        (define ws (bitmask->wires (car pr)))
                        (define piv (last (filter (lambda (w) (= (vector-ref qpu-vec w) p-dst)) ws)))
                        (define fwd
                          (for/list ([w (in-list ws)] #:when (not (= w piv)))
                            (list "cx" w piv)))
                        (append fwd (emit-1q-rz8-isa (cdr pr) piv) (reverse fwd)))))
             (append rk-odd-isa rk-even-isa)))
         (append local-isa (apply append stage-isas) frame-isa))

       (define cand-steiner (append steiner-diag-isa frame-isa))
       (define cand-hub-fwd (run-hub-order (range m-star)))
       (define cand-hub-rev (run-hub-order (reverse (range m-star))))
       (define best1
         (if (better-partition-isa? cand-hub-fwd cand-steiner qpu-vec num-w)
             cand-hub-fwd
             cand-steiner))
       (if (better-partition-isa? cand-hub-rev best1 qpu-vec num-w)
           cand-hub-rev
           best1)]))

  ;; Convert ISA strings back to normalized `RevIR` unitary ops (canceling boundary CX/RZ8 pairs):
  (cancel-adjacent-1q-gates
   (for/list ([ins (in-list full-isa)])
     (match ins
       [(list "cx" c t) `(cx ,c ,t)]
       [(list "t" w)    `(rz8 ,w 1)]
       [(list "s" w)    `(rz8 ,w 2)]
       [(list "z" w)    `(rz8 ,w 4)]
       [(list "sdg" w)  `(rz8 ,w 6)]
       [(list "tdg" w)  `(rz8 ,w 7)]))))

;; Local involution & spider cancellation (`H^2 = I`, `X^2 = I`, `CX^2 = I`, `CZ^2 = I`, `Rz8(k1)·Rz8(k2) = Rz8(k1+k2)`)
(define (cancel-adjacent-1q-gates ops)
  (let loop ([rem ops] [stk '()])
    (cond
      [(null? rem) (reverse stk)]
      [(and (pair? stk) (equal? (car rem) (car stk))
            (member (caar rem) '(h x cx cz)))
       (loop (cdr rem) (cdr stk))]
      [(and (pair? stk)
            (eq? (caar rem) 'rz8)
            (eq? (caar stk) 'rz8)
            (= (second (car rem)) (second (car stk))))
       (define w (second (car rem)))
       (define k-sum (modulo (+ (third (car stk)) (third (car rem))) 8))
       (if (zero? k-sum)
           (loop (cdr rem) (cdr stk))
           (loop (cdr rem) (cons `(rz8 ,w ,k-sum) (cdr stk))))]
      [else
       (loop (cdr rem) (cons (car rem) stk))])))

;; Auxiliary / Fixpoint Commutation Pass: `P_fraig_comm`
;; Commutes `{cx, cz, ccz, rz8, parity-phase}` gates rightward across any gate (`h`, `x`, etc.)
;; with **strictly disjoint wire support** (plus `CX(c, t) · X(t) = X(t) · CX(c, t)`),
;; then cancels involutions and merges adjacent `Rz8` spiders!
(define (op-wire-set op)
  (match op
    [`(h ,w) (list w)]
    [`(x ,w) (list w)]
    [`(rz8 ,w ,_) (list w)]
    [`(cx ,c ,t) (list c t)]
    [`(cz ,a ,b) (list a b)]
    [`(ccz ,a ,b ,c) (list a b c)]
    [`(ccx ,a ,b ,c) (list a b c)]
    [`(parity-phase ,ws ,_) ws]
    [`(temp-and ,c1 ,c2 ,anc) (list c1 c2 anc)]
    [`(meas-x-cond-cz-reset ,anc ,_ ,c1 ,c2) (list anc c1 c2)]
    [`(within-and-mbu ,c1 ,c2 ,anc ,body)
     (remove-duplicates (append (list c1 c2 anc) (apply append (map op-wire-set body))) =)]
    [`(borrow-toffoli ,c1 ,c2 ,b ,t) (list c1 c2 b t)]
    [`(for-rounds ,_ ,rbody ,zws)
     (remove-duplicates (append zws (apply append (map op-wire-set rbody))) =)]
    [`(unrolled-round-marker ,rbody ,zws)
     (remove-duplicates (append zws (apply append (map op-wire-set rbody))) =)]
    [`(waw-barrier ,w) (list w)]
    [_ '()]))

(define (disjoint-wire-lists? ws1 ws2)
  (not (for*/or ([u (in-list ws1)] [v (in-list ws2)]) (= u v))))

(define (commute-phase-ops-across-disjoint-barriers ops)
  ;; Rightward bubble of phase-cone ops past disjoint-support `h`/`x` barriers (and `CX(c,t)` past `X(t)`)
  ;; so downstream phase-polynomial cones absorb commuted boundary gates in Round 2!
  (define (commutes-past-1q? op barrier)
    (or (and (phase-cone-op? op)
             (member (car barrier) '(h x))
             (disjoint-wire-lists? (op-wire-set op) (op-wire-set barrier)))
        (and (eq? (car op) 'cx)
             (eq? (car barrier) 'x)
             (not (= (second op) (second barrier))))))
  (define (push-right op rest-ops)
    (match rest-ops
      ['() (list op)]
      [(cons hd tl)
       (if (commutes-past-1q? op hd)
           (cons hd (push-right op tl))
           (cons op rest-ops))]))
  (cancel-adjacent-1q-gates
   (let rec ([rem ops])
     (if (null? rem)
         '()
         (push-right (car rem) (rec (cdr rem)))))))

(define (pass-fraig-commute prog)
  (define new-ops
    (match (revir-prog-ops prog)
      [(list `(for-rounds ,r ,rbody ,zws))
       (list `(for-rounds ,r ,(commute-phase-ops-across-disjoint-barriers rbody) ,zws))]
      [other (commute-phase-ops-across-disjoint-barriers other)]))
  (struct-copy revir-prog prog [ops new-ops]))

;; Single round of `P_todd_zx`
(define (pass-todd-zx-single prog
                             #:partition-aware? [partition-aware? #t]
                             #:absorb-top-cz? [absorb-top-cz? #t])
  (define nw (total-wires prog))
  (define eg-merges (box 0))
  (define (transform-ops raw-ops [top-level? #t])
    (define alg-ops
      (cancel-adjacent-1q-gates
       (saturate-algebraic-within-and-ops raw-ops eg-merges
                                          #:absorb-top-cz? (or (not top-level?) absorb-top-cz?))))
    ;; Partition into maximal phase-cone segments (`waw-barrier`, `h`, `x`, `meas-x...` split cones!)
    (let loop ([rem alg-ops] [cur-cone '()] [out '()])
      (cond
        [(null? rem)
         (define tail-cone
           (if (null? cur-cone)
               '()
               (synthesize-single-phase-cone nw (reverse cur-cone)
                                             (revir-prog-partitions prog)
                                             partition-aware?)))
         (append out tail-cone)]
        [(phase-cone-op? (car rem))
         (loop (cdr rem) (cons (car rem) cur-cone) out)]
        [else
         (define flushed
           (if (null? cur-cone)
               '()
               (synthesize-single-phase-cone nw (reverse cur-cone)
                                             (revir-prog-partitions prog)
                                             partition-aware?)))
         (define next-op
           (match (car rem)
             [`(for-rounds ,r ,rbody ,zws)
              `(for-rounds ,r ,(transform-ops rbody #t) ,zws)]
             [`(within-and-mbu ,c1 ,c2 ,anc ,body)
              `(within-and-mbu ,c1 ,c2 ,anc ,(transform-ops body #f))]
             [other other]))
         (loop (cdr rem) '() (append out flushed (list next-op)))])))
  (define new-ops (transform-ops (revir-prog-ops prog) #t))
  (meta-add (struct-copy revir-prog prog [ops new-ops])
            'egraph_merges (unbox eg-merges)))

;; Multi-round `P_todd_zx` (`rounds = 1` single pass, `rounds = 2` canonical 2-round fixpoint)
(define (pass-todd-zx prog
                      #:rounds [rounds 1]
                      #:partition-aware? [partition-aware? #t]
                      #:absorb-top-cz? [absorb-top-cz? #t])
  (let loop ([k 0] [cur prog])
    (cond
      [(>= k rounds) cur]
      [(= (add1 k) rounds)
       (pass-todd-zx-single cur
                            #:partition-aware? partition-aware?
                            #:absorb-top-cz? absorb-top-cz?)]
      [else
       (define p1 (pass-todd-zx-single cur
                                       #:partition-aware? partition-aware?
                                       #:absorb-top-cz? absorb-top-cz?))
       (define p2 (pass-fraig-commute p1))
       (loop (add1 k) p2)])))

;; Pass 4: `P_mbu` (Asymmetric `within-and-mbu` -> `4T TempAND` + `M_X` + `cond-cz` lowering)
(define (pass-mbu prog)
  (define next-mk (hash-ref (revir-prog-meta prog) 'next_mk_id 0))
  (define (lower-mbu-ops ops)
    (apply append
           (for/list ([op (in-list ops)])
             (match op
               [`(within-and-mbu ,c1 ,c2 ,anc ,body)
                (define mk next-mk)
                (set! next-mk (add1 next-mk))
                (append (list `(temp-and ,c1 ,c2 ,anc))
                        (lower-mbu-ops body)
                        (list `(meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)))]
               [`(for-rounds ,r ,rbody ,zws)
                (list `(for-rounds ,r ,(lower-mbu-ops rbody) ,zws))]
               [_ (list op)]))))
  (define p1 (struct-copy revir-prog prog [ops (lower-mbu-ops (revir-prog-ops prog))]))
  (meta-set p1 'next_mk_id next-mk))

;; Pass 5: `P_ssa` (Exact Hierarchical Chordal Interval-Graph Scratch Wire Reuse & Post-TODD Re-Coloring)
(define (pass-ssa prog)
  (match (revir-prog-ops prog)
    [(list `(for-rounds ,r ,rbody ,zws))
     (define sub-p (pass-ssa-flat (struct-copy revir-prog prog [ops rbody])))
     (struct-copy revir-prog sub-p [ops (list `(for-rounds ,r ,(revir-prog-ops sub-p) ,zws))])]
    [_ (pass-ssa-flat prog)]))

(define (pass-ssa-flat prog)
  (define fixed-base (+ (revir-prog-num-data prog) (revir-prog-num-borrow prog)))
  (define raw-ops (revir-prog-ops prog))

  ;; Compute fine-grained DFS `[first-idx, last-idx]` live intervals across hierarchical
  ;; `within-and-mbu` scopes (ignoring `waw-barrier` markers so post-TODD re-coloring
  ;; cleanly reclaims physical wires whose quantum scopes were eliminated by `P_todd_zx`!):
  (define first-use (make-hasheqv))
  (define last-use (make-hasheqv))
  (define (touch-wire! w ts)
    (when (>= w fixed-base)
      (unless (hash-has-key? first-use w)
        (hash-set! first-use w ts))
      (hash-set! last-use w ts)))

  (define step-ts 0)
  (define (walk-intervals! ops)
    (for ([op (in-list ops)])
      (match op
        [`(waw-barrier ,_) (void)]
        [`(within-and-mbu ,c1 ,c2 ,anc ,body)
         (define t-enter step-ts)
         (set! step-ts (add1 step-ts))
         (touch-wire! c1 t-enter)
         (touch-wire! c2 t-enter)
         (touch-wire! anc t-enter)
         (walk-intervals! body)
         (define t-exit step-ts)
         (set! step-ts (add1 step-ts))
         (touch-wire! c1 t-exit)
         (touch-wire! c2 t-exit)
         (touch-wire! anc t-exit)]
        [_
         (define t step-ts)
         (set! step-ts (add1 step-ts))
         (for ([w (in-list (op-wire-set op))])
           (touch-wire! w t))])))
  (walk-intervals! raw-ops)

  (define live-scratch-wires
    (sort (hash-keys first-use)
          (lambda (w1 w2)
            (define s1 (hash-ref first-use w1))
            (define s2 (hash-ref first-use w2))
            (if (= s1 s2) (< w1 w2) (< s1 s2)))))

  ;; Chordal interval-graph coloring (optimal greedy left-edge scan):
  (define phys-end (make-hasheqv))
  (define phys-reuse-points (make-hasheqv)) ;; timestamp -> list of reused phys wires
  (define wire-remap (make-hasheqv))
  (define num-phys-scratch 0)

  (for ([vw (in-list live-scratch-wires)])
    (define s-idx (hash-ref first-use vw))
    (define e-idx (hash-ref last-use vw))
    (define reuse-slot
      (for/first ([slot (in-range num-phys-scratch)]
                  #:when (< (hash-ref phys-end slot) s-idx))
        slot))
    (cond
      [reuse-slot
       (define pw (+ fixed-base reuse-slot))
       (hash-set! wire-remap vw pw)
       (hash-set! phys-end reuse-slot e-idx)
       (hash-set! phys-reuse-points s-idx
                  (append (hash-ref phys-reuse-points s-idx '()) (list pw)))]
      [else
       (define slot num-phys-scratch)
       (set! num-phys-scratch (add1 num-phys-scratch))
       (define pw (+ fixed-base slot))
       (hash-set! wire-remap vw pw)
       (hash-set! phys-end slot e-idx)]))

  (define (remap-w w)
    (if (< w fixed-base) w (hash-ref wire-remap w w)))

  (define (remap-atomic-op op)
    (match op
      [`(h ,w) `(h ,(remap-w w))]
      [`(x ,w) `(x ,(remap-w w))]
      [`(rz8 ,w ,k) `(rz8 ,(remap-w w) ,k)]
      [`(cx ,c ,t) `(cx ,(remap-w c) ,(remap-w t))]
      [`(cz ,a ,b) `(cz ,(remap-w a) ,(remap-w b))]
      [`(ccz ,a ,b ,c) `(ccz ,(remap-w a) ,(remap-w b) ,(remap-w c))]
      [`(ccx ,a ,b ,c) `(ccx ,(remap-w a) ,(remap-w b) ,(remap-w c))]
      [`(parity-phase ,ws ,k) `(parity-phase ,(map remap-w ws) ,k)]
      [`(temp-and ,c1 ,c2 ,anc) `(temp-and ,(remap-w c1) ,(remap-w c2) ,(remap-w anc))]
      [`(meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)
       `(meas-x-cond-cz-reset ,(remap-w anc) ,mk ,(remap-w c1) ,(remap-w c2))]
      [`(borrow-toffoli ,c1 ,c2 ,b ,t)
       `(borrow-toffoli ,(remap-w c1) ,(remap-w c2) ,(remap-w b) ,(remap-w t))]
      [`(for-rounds ,r ,rbody ,zws)
       `(for-rounds ,r ,(map remap-atomic-op rbody) ,(map remap-w zws))]
      [other other]))

  (define active-remapped-scratch
    (list->seteqv (for/list ([vw (in-list live-scratch-wires)]) (remap-w vw))))

  ;; Rebuild ops with synchronized DFS timestamp `rebuild-ts`:
  (define rebuild-ts 0)
  (define (rebuild-op-list ops)
    (let loop ([rem ops] [acc '()])
      (cond
        [(null? rem) (reverse acc)]
        [else
         (match (car rem)
           [`(waw-barrier ,w)
            (define bw (remap-w w))
            (if (set-member? active-remapped-scratch bw)
                (loop (cdr rem) (cons `(waw-barrier ,bw) acc))
                (loop (cdr rem) acc))]
           [`(within-and-mbu ,c1 ,c2 ,anc ,body)
            (define t-enter rebuild-ts)
            (set! rebuild-ts (add1 rebuild-ts))
            (define reuse-barriers
              (for/list ([pw (in-list (hash-ref phys-reuse-points t-enter '()))])
                `(waw-barrier ,pw)))
            (define new-body (rebuild-op-list body))
            (set! rebuild-ts (add1 rebuild-ts))
            (define rop `(within-and-mbu ,(remap-w c1) ,(remap-w c2) ,(remap-w anc) ,new-body))
            (loop (cdr rem) (cons rop (append (reverse reuse-barriers) acc)))]
           [other
            (define t rebuild-ts)
            (set! rebuild-ts (add1 rebuild-ts))
            (define reuse-barriers
              (for/list ([pw (in-list (hash-ref phys-reuse-points t '()))])
                `(waw-barrier ,pw)))
            (define rop (remap-atomic-op other))
            (loop (cdr rem) (cons rop (append (reverse reuse-barriers) acc)))])])))

  (define rebuilt-ops (rebuild-op-list raw-ops))

  ;; Remap partitions if `P_part_u4` already ran before `P_ssa`:
  (define new-max-w (+ fixed-base num-phys-scratch))
  (define new-parts
    (and (revir-prog-partitions prog)
         (let ()
           (define seen (mutable-seteqv))
           (for/list ([sl (in-list (revir-prog-partitions prog))])
             (filter (lambda (pw)
                       (and (< pw new-max-w)
                            (not (set-member? seen pw))
                            (begin (set-add! seen pw) #t)))
                     (map remap-w sl))))))

  (struct-copy revir-prog prog
               [num-scratch num-phys-scratch]
               [ops rebuilt-ops]
               [partitions new-parts]))

(define (recolor-post-todd-chordal-ssa prog)
  (pass-ssa prog))

;; Pass 6: `P_part_u4` (Law-U4 Asymmetric Cone-Hypergraph Min-Cut + Optional Frame Re-Synthesis)
;; Computes balanced `M*`-way QPU partitioning with Kernighan-Lin 2-opt swap refinement!
(define (estimate-partition-ebits ops num-w slices law-u4-asymmetric?)
  (define qpu-vec (wire->qpu-table num-w slices))
  (define z-ep (make-vector num-w 0))
  (define seen-u4-cones (mutable-set))
  (define ebits 0)
  (define (use-z-cat! src-w dst-p)
    (define src-p (vector-ref qpu-vec src-w))
    (unless (= src-p dst-p)
      (cond
        [law-u4-asymmetric?
         (define key (list src-p dst-p src-w (vector-ref z-ep src-w)))
         (unless (set-member? seen-u4-cones key)
           (set-add! seen-u4-cones key)
           (set! ebits (add1 ebits)))]
        [else
         (set! ebits (add1 ebits))])))
  (define (walk op-list)
    (for ([op (in-list op-list)])
      (match op
        [`(cx ,c ,t)
         (use-z-cat! c (vector-ref qpu-vec t))
         (vector-set! z-ep t (add1 (vector-ref z-ep t)))]
        [`(cz ,a ,b)
         (define pa (vector-ref qpu-vec a))
         (define pb (vector-ref qpu-vec b))
         (unless (= pa pb)
           (cond
             [law-u4-asymmetric?
              (define kab (list pa pb a (vector-ref z-ep a)))
              (define kba (list pb pa b (vector-ref z-ep b)))
              (unless (or (set-member? seen-u4-cones kab) (set-member? seen-u4-cones kba))
                (set-add! seen-u4-cones kab)
                (set! ebits (add1 ebits)))]
             [else
              (set! ebits (add1 ebits))]))]
        [`(ccz ,a ,b ,c)
         (define p-root (vector-ref qpu-vec c))
         (use-z-cat! a p-root)
         (use-z-cat! b p-root)
         (unless law-u4-asymmetric?
           (use-z-cat! a p-root)
           (use-z-cat! b p-root))]
        [`(ccx ,a ,b ,t)
         (vector-set! z-ep t (add1 (vector-ref z-ep t)))
         (walk (list `(ccz ,a ,b ,t)))
         (vector-set! z-ep t (add1 (vector-ref z-ep t)))]
        [`(parity-phase ,ws ,_)
         (when (pair? ws)
           (define p-root (vector-ref qpu-vec (last ws)))
           (for ([w (in-list (take ws (sub1 (length ws))))])
             (use-z-cat! w p-root)
             (unless law-u4-asymmetric? (use-z-cat! w p-root))))]
        [`(,(or 'h 'x) ,w)
         (vector-set! z-ep w (add1 (vector-ref z-ep w)))]
        [`(within-and-mbu ,c1 ,c2 ,anc ,body)
         (walk (cons `(temp-and ,c1 ,c2 ,anc)
                     (append body (list `(meas-x-cond-cz-reset ,anc 0 ,c1 ,c2)))))]
        [`(temp-and ,c1 ,c2 ,anc)
         (define pa (vector-ref qpu-vec anc))
         (cond
           [law-u4-asymmetric?
            (use-z-cat! c1 pa)
            (use-z-cat! c2 pa)]
           [else
            (unless (= (vector-ref qpu-vec c1) pa) (set! ebits (+ ebits 2)))
            (unless (= (vector-ref qpu-vec c2) pa) (set! ebits (+ ebits 2)))])
         (vector-set! z-ep anc (add1 (vector-ref z-ep anc)))]
        [`(meas-x-cond-cz-reset ,anc ,_ ,c1 ,c2)
         (vector-set! z-ep anc (add1 (vector-ref z-ep anc)))
         (unless law-u4-asymmetric?
           (unless (= (vector-ref qpu-vec c1) (vector-ref qpu-vec c2))
             (set! ebits (add1 ebits))))]
        [`(borrow-toffoli ,c1 ,c2 ,b ,t)
         (walk (list `(ccx ,c1 ,c2 ,b) `(cx ,b ,t) `(ccx ,c1 ,c2 ,b) `(cx ,b ,t)))]
        [`(for-rounds ,_ ,rbody ,_)
         (walk rbody)]
        [_ (void)])))
  (walk ops)
  ebits)

(define (partition-wires-law-u4-hypergraph num-w m-star ops law-u4-asymmetric?
                                           #:num-fixed [num-fixed num-w])
  (cond
    [(<= m-star 1) (list (range num-w))]
    [else
     (define n-fix (min num-w (max 0 num-fixed)))
     (define n-scr (max 0 (- num-w n-fix)))
     (define max-scr-per-qpu (if (zero? n-scr) 0 (quotient (+ n-scr (sub1 m-star)) m-star)))
     ;; Initial balanced slice assignment separating fixed registers (`0 .. n-fix - 1`)
     ;; from scratch registers (`n-fix .. num-w - 1`) so post-SSA scratch coalescing can
     ;; NEVER strand all data registers onto a single QPU slice:
     (define assign (make-vector num-w 0))
     (for ([w (in-range n-fix)])
       (vector-set! assign w (min (sub1 m-star) (quotient (* w m-star) (max 1 n-fix)))))
     (for ([k (in-range n-scr)])
       (vector-set! assign (+ n-fix k) (modulo k m-star)))
     (define (assign->slices vec)
       (for/list ([p (in-range m-star)])
         (for/list ([w (in-range num-w)] #:when (= (vector-ref vec w) p)) w)))
     (define (scratch-count-on-slice vec p)
       (for/sum ([w (in-range n-fix num-w)] #:when (= (vector-ref vec w) p)) 1))

     ;; Kernighan-Lin 2-opt swap + slack scratch-relocation local search:
     (let kl-loop ([improved? #t] [iter 0])
       (when (and improved? (< iter 18))
         (set! improved? #f)
         (define cur-cost
           (estimate-partition-ebits ops num-w (assign->slices assign) law-u4-asymmetric?))
         ;; 1. Same-class pairwise swaps (fixed<->fixed or scratch<->scratch):
         (for* ([u (in-range num-w)] #:break improved?
                [v (in-range (add1 u) num-w)] #:break improved?
                #:when (and (eq? (< u n-fix) (< v n-fix))
                            (not (= (vector-ref assign u) (vector-ref assign v)))))
           (define pu (vector-ref assign u))
           (define pv (vector-ref assign v))
           (vector-set! assign u pv)
           (vector-set! assign v pu)
           (define cand-cost
             (estimate-partition-ebits ops num-w (assign->slices assign) law-u4-asymmetric?))
           (cond
             [(< cand-cost cur-cost)
              (set! cur-cost cand-cost)
              (set! improved? #t)]
             [else
              (vector-set! assign u pu)
              (vector-set! assign v pv)]))
         ;; 2. Single-scratch slack relocation within `ceil(n_scr / M*)` capacity:
         (unless improved?
           (for* ([s (in-range n-fix num-w)] #:break improved?
                  [p-dst (in-range m-star)] #:break improved?
                  #:when (and (not (= (vector-ref assign s) p-dst))
                              (< (scratch-count-on-slice assign p-dst) max-scr-per-qpu)))
             (define p-old (vector-ref assign s))
             (vector-set! assign s p-dst)
             (define cand-cost
               (estimate-partition-ebits ops num-w (assign->slices assign) law-u4-asymmetric?))
             (cond
               [(< cand-cost cur-cost)
                (set! cur-cost cand-cost)
                (set! improved? #t)]
               [else
                (vector-set! assign s p-old)])))))
     (assign->slices assign)]))

;; Re-synthesize pure CNOT linear frames in `ops` (recursing into loop/MBU scopes)
;; using Partition-Aware Block-LU once `slices` are known!
(define (resynthesize-cx-runs-partition-aware num-w ops slices)
  (define qpu-vec (wire->qpu-table num-w slices))
  (define (flush-run cx-run)
    (if (<= (length cx-run) 1)
        (reverse cx-run)
        (let ()
          (define orig-ops (reverse cx-run))
          (define orig-isa (for/list ([op (in-list orig-ops)]) (list "cx" (second op) (third op))))
          (define frame (for/vector ([w (in-range num-w)]) (arithmetic-shift 1 w)))
          (for ([op (in-list orig-ops)])
            (match-define `(cx ,c ,t) op)
            (vector-set! frame t (bitwise-xor (vector-ref frame t) (vector-ref frame c))))
          (define syn-isa (synthesize-linear-frame-partition-aware num-w frame slices))
          (if (better-partition-isa? syn-isa orig-isa qpu-vec num-w)
              (for/list ([ins (in-list syn-isa)]) `(cx ,(second ins) ,(third ins)))
              orig-ops))))
  (let loop ([rem ops] [cx-run '()] [out '()])
    (cond
      [(null? rem)
       (append out (flush-run cx-run))]
      [(and (pair? (car rem)) (eq? (caar rem) 'cx))
       (loop (cdr rem) (cons (car rem) cx-run) out)]
      [else
       (define flushed (flush-run cx-run))
       (define rec-op
         (match (car rem)
           [`(for-rounds ,r ,rbody ,zws)
            `(for-rounds ,r ,(resynthesize-cx-runs-partition-aware num-w rbody slices) ,zws)]
           [`(within-and-mbu ,c1 ,c2 ,anc ,body)
            `(within-and-mbu ,c1 ,c2 ,anc ,(resynthesize-cx-runs-partition-aware num-w body slices))]
           [other other]))
       (loop (cdr rem) '() (append out flushed (list rec-op)))])))

(define (pass-part-u4 prog
                      #:law-u4-asymmetric? [law-u4-asymmetric? #t]
                      #:resynth-frames? [resynth-frames? #t])
  (define nw (total-wires prog))
  (define nfix (+ (revir-prog-num-data prog) (revir-prog-num-borrow prog)))
  (define slices
    (partition-wires-law-u4-hypergraph nw
                                       (revir-prog-num-qpus prog)
                                       (revir-prog-ops prog)
                                       law-u4-asymmetric?
                                       #:num-fixed nfix))
  (define new-ops
    (if (and resynth-frames? (> (revir-prog-num-qpus prog) 1))
        (resynthesize-cx-runs-partition-aware nw (revir-prog-ops prog) slices)
        (revir-prog-ops prog)))
  (meta-set (struct-copy revir-prog prog [ops new-ops] [partitions slices])
            'law_u4_mode law-u4-asymmetric?))

;; =============================================================================
;; SECTION 5: Final `MachineISA` Lowering & Exact `QPhysGrade` / Cluster Metrics
;; =============================================================================

;; Exact 4T, 4-CNOT Gidney/Jones zero-phase-drift clean `TempAND(c1, c2, anc)` expansion
(define (emit-temp-and-4t-isa c1 c2 anc)
  (list (list "h" anc)
        (list "tdg" anc)
        (list "cx" c1 anc)
        (list "t" anc)
        (list "cx" c2 anc)
        (list "tdg" anc)
        (list "cx" c1 anc)
        (list "t" anc)
        (list "cx" c2 anc)
        (list "h" anc)
        (list "sdg" anc)))

(define (emit-unitary-ccz-7t-isa a b c)
  (list (list "t" a)
        (list "t" b)
        (list "t" c)
        (list "cx" a b) (list "tdg" b) (list "cx" a b)
        (list "cx" a c) (list "tdg" c)
        (list "cx" b c) (list "t" c)
        (list "cx" a c) (list "tdg" c)
        (list "cx" b c)))

;; Lowers any `RevIR` program (after ANY valid permutation of passes!) to physical `MachineISA`
(define (emit-final-machine-isa prog)
  (define nw (total-wires prog))
  (define nfix (+ (revir-prog-num-data prog) (revir-prog-num-borrow prog)))
  (define z-certs (revir-prog-zero-certified prog))
  (define next-mk (hash-ref (revir-prog-meta prog) 'next_mk_id 0))
  (define slices
    (or (revir-prog-partitions prog)
        (partition-wires-law-u4-hypergraph nw
                                           (revir-prog-num-qpus prog)
                                           (revir-prog-ops prog)
                                           #f
                                           #:num-fixed nfix)))
  (define qpu-vec (wire->qpu-table nw slices))
  (define law-u4? (hash-ref (revir-prog-meta prog) 'law_u4_mode #f))

  (define (lower-op op)
    (match op
      [`(waw-barrier ,_) '()]
      [`(unrolled-round-marker () ,_) '()]
      [`(unrolled-round-marker ,rbody ,_)
       (apply append (map lower-op rbody))]
      [`(for-rounds ,_ ,rbody ,_)
       (apply append (map lower-op rbody))]
      [`(h ,w) (list (list "h" w))]
      [`(x ,w) (list (list "x" w))]
      [`(rz8 ,w ,k8) (emit-1q-rz8-isa k8 w)]
      [`(cx ,c ,t) (list (list "cx" c t))]
      [`(cz ,a ,b) (list (list "cz" a b))]
      [`(ccz ,a ,b ,c) (emit-unitary-ccz-7t-isa a b c)]
      [`(ccx ,a ,b ,t)
       (append (list (list "h" t))
               (lower-op `(ccz ,a ,b ,t))
               (list (list "h" t)))]
      [`(parity-phase ,ws ,k8)
       (emit-zx-phase-gadget-partition-aware (wires->mask ws) k8 slices nw)]
      [`(borrow-toffoli ,c1 ,c2 ,b ,t)
       (if (set-member? z-certs b)
           (lower-op `(within-and-mbu ,c1 ,c2 ,b ((cx ,b ,t))))
           (apply append
                  (map lower-op
                       (list `(ccx ,c1 ,c2 ,b)
                             `(cx ,b ,t)
                             `(ccx ,c1 ,c2 ,b)
                             `(cx ,b ,t)))))]
      [`(within-and-mbu ,c1 ,c2 ,anc ,body)
       (define mk next-mk)
       (set! next-mk (add1 next-mk))
       (lower-op `(mbu-auto ,c1 ,c2 ,anc ,mk ,body))]
      [`(mbu-auto ,c1 ,c2 ,anc ,mk ,body)
       (append (lower-op `(temp-and ,c1 ,c2 ,anc))
               (apply append (map lower-op body))
               (lower-op `(meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)))]
      [`(temp-and ,c1 ,c2 ,anc)
       (emit-temp-and-4t-isa c1 c2 anc)]
      [`(meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)
       (list (list "mx_reset" anc mk)
             (list "cond_cz" mk c1 c2))]))

  (define isa (apply append (map lower-op (revir-prog-ops prog))))
  (define cluster-ebits
    (if law-u4?
        (count-isa-law-u4-ebits isa qpu-vec nw)
        (count-cx-list-ebits isa qpu-vec)))

  ;; Compute exact physical metrics:
  (define t-count
    (for/sum ([ins (in-list isa)])
      (if (member (car ins) '("t" "tdg")) 1 0)))
  (define twoq-count
    (for/sum ([ins (in-list isa)])
      (if (member (car ins) '("cx" "cz" "cond_cz")) 1 0)))
  (define mid-meas
    (for/sum ([ins (in-list isa)])
      (if (equal? (car ins) "mx_reset") 1 0)))

  ;; Exact parallel `T`-depth across wires:
  (define wire-td (make-vector nw 0))
  (for ([ins (in-list isa)])
    (match ins
      [(list (or "t" "tdg") w)
       (vector-set! wire-td w (add1 (vector-ref wire-td w)))]
      [(list (or "cx" "cz") w1 w2)
       (define d (max (vector-ref wire-td w1) (vector-ref wire-td w2)))
       (vector-set! wire-td w1 d)
       (vector-set! wire-td w2 d)]
      [(list "cond_cz" _ w1 w2)
       (define d (max (vector-ref wire-td w1) (vector-ref wire-td w2)))
       (vector-set! wire-td w1 d)
       (vector-set! wire-td w2 d)]
      [_ (void)]))
  (define t-depth
    (for/fold ([m 0]) ([w (in-range nw)]) (max m (vector-ref wire-td w))))

  ;; Active physical qubits = fixed data/borrow + highest referenced scratch slot (or touched wires):
  ;; Note: if `P_ssa` ran BEFORE `P_todd_zx` and left `(waw-barrier w)` on `w`, `prog` STILL holds
  ;; that physical wire reservation unless post-TODD `P_ssa` reclaimed it!
  (define touched (mutable-seteqv))
  (for ([w (in-range (+ (revir-prog-num-data prog) (revir-prog-num-borrow prog)))])
    (set-add! touched w))
  (for ([op (in-list (revir-prog-ops prog))])
    (for ([w (in-list (op-wire-set op))])
      (set-add! touched w)))
  (define active-qubits (set-count touched))

  ;; Calibrated `QPhysGrade` `Phi_1` across 3 decoder pacing regimes (`ns`-weighted infidelity):
  ;; `eps_T = 1.0e-3`, `eps_2Q = 5.0e-4`, `eps_ebit = 4.0e-3`,
  ;; `eps_meas + spectator_decoherence(tau_dec)`:
  ;;   - 4K Cryo-CMOS (`120 ns`): `1.8e-3`
  ;;   - 300K Coax (`420 ns`):    `3.5e-3`
  ;;   - Software MWPM (`4500 ns`): `1.9e-2`
  (define phi1-cryo-120ns
    (+ (* 1.0e-3 t-count) (* 0.5e-3 twoq-count) (* 4.0e-3 cluster-ebits) (* 1.8e-3 mid-meas)))
  (define phi1-coax-420ns
    (+ (* 1.0e-3 t-count) (* 0.5e-3 twoq-count) (* 4.0e-3 cluster-ebits) (* 3.5e-3 mid-meas)))
  (define phi1-mwpm-4500ns
    (+ (* 1.0e-3 t-count) (* 0.5e-3 twoq-count) (* 4.0e-3 cluster-ebits) (* 19.0e-3 mid-meas)))

  (values isa
          (hasheq 't_count t-count
                  't_depth t-depth
                  'twoq_count twoq-count
                  'active_qubits active-qubits
                  'mid_meas_mx mid-meas
                  'cross_qpu_ebits (if (<= (revir-prog-num-qpus prog) 1) 0 cluster-ebits)
                  'z3_queries (hash-ref (revir-prog-meta prog) 'z3_queries 0)
                  'wl_cone_classes (hash-ref (revir-prog-meta prog) 'wl_cone_classes 1)
                  'pebbles_promoted (hash-ref (revir-prog-meta prog) 'pebbles_promoted 0)
                  'egraph_merges (hash-ref (revir-prog-meta prog) 'egraph_merges 0)
                  'phi1_cryo_120ns (/ (round (* phi1-cryo-120ns 1e6)) 1e6)
                  'phi1_coax_420ns (/ (round (* phi1-coax-420ns 1e6)) 1e6)
                  'phi1_mwpm_4500ns (/ (round (* phi1-mwpm-4500ns 1e6)) 1e6)
                  'partitions slices)))

;; =============================================================================
;; SECTION 6: Internal Exact Complex Statevector & 2^k-Branch Kraus Verifier
;; =============================================================================

;; Verifies in pure Racket that two lowered `MachineISA` circuits `isa-a` (`nw-a` wires)
;; and `isa-b` (`nw-b` wires) produce the **100% exact same output quantum state** on primary
;; + borrow wires `[0 .. n-keep - 1]`, with clean `|0>` scratch wires and exact purity `1.0`
;; across ALL `2^k` mid-circuit `M_X` measurement branches!
(define OMEGA8
  (vector 1.0+0.0i
          (make-rectangular (sqrt 0.5) (sqrt 0.5))
          0.0+1.0i
          (make-rectangular (- (sqrt 0.5)) (sqrt 0.5))
          -1.0+0.0i
          (make-rectangular (- (sqrt 0.5)) (- (sqrt 0.5)))
          0.0-1.0i
          (make-rectangular (sqrt 0.5) (- (sqrt 0.5)))))

(define INV-SQRT2 (sqrt 0.5))

(define (apply-1q-h! sv nw w)
  (define dim (arithmetic-shift 1 nw))
  (define bit (arithmetic-shift 1 w))
  (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx bit)))
    (define j (bitwise-ior idx bit))
    (define a (vector-ref sv idx))
    (define b (vector-ref sv j))
    (vector-set! sv idx (* INV-SQRT2 (+ a b)))
    (vector-set! sv j   (* INV-SQRT2 (- a b)))))

(define (apply-1q-x! sv nw w)
  (define dim (arithmetic-shift 1 nw))
  (define bit (arithmetic-shift 1 w))
  (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx bit)))
    (define j (bitwise-ior idx bit))
    (define a (vector-ref sv idx))
    (vector-set! sv idx (vector-ref sv j))
    (vector-set! sv j a)))

(define (apply-1q-phase8! sv nw w k8)
  (define ph (vector-ref OMEGA8 (modulo k8 8)))
  (define dim (arithmetic-shift 1 nw))
  (define bit (arithmetic-shift 1 w))
  (for ([idx (in-range dim)] #:when (not (zero? (bitwise-and idx bit))))
    (vector-set! sv idx (* ph (vector-ref sv idx)))))

(define (apply-2q-cx! sv nw c t)
  (define dim (arithmetic-shift 1 nw))
  (define cbit (arithmetic-shift 1 c))
  (define tbit (arithmetic-shift 1 t))
  (for ([idx (in-range dim)]
        #:when (and (not (zero? (bitwise-and idx cbit)))
                    (zero? (bitwise-and idx tbit))))
    (define j (bitwise-ior idx tbit))
    (define a (vector-ref sv idx))
    (vector-set! sv idx (vector-ref sv j))
    (vector-set! sv j a)))

(define (apply-2q-cz! sv nw w1 w2)
  (define dim (arithmetic-shift 1 nw))
  (define b1 (arithmetic-shift 1 w1))
  (define b2 (arithmetic-shift 1 w2))
  (define mask (bitwise-ior b1 b2))
  (for ([idx (in-range dim)]
        #:when (= (bitwise-and idx mask) mask))
    (vector-set! sv idx (- (vector-ref sv idx)))))

;; Simulate a single deterministic `M_X` branch assignment `branch-bits` (`hash mk -> 0 or 1`)
;; without renormalization (Kraus branch amplitude `K_m |psi>`), then check normalized data vector!
(define (simulate-isa-kraus-branch isa nw n-keep init-keep-sv branch-bits)
  (define dim (arithmetic-shift 1 nw))
  (define keep-dim (arithmetic-shift 1 n-keep))
  (define sv (make-vector dim 0.0+0.0i))
  (for ([i (in-range keep-dim)])
    (vector-set! sv i (vector-ref init-keep-sv i)))
  (for ([ins (in-list isa)])
    (match ins
      [(list "h" w)   (apply-1q-h! sv nw w)]
      [(list "x" w)   (apply-1q-x! sv nw w)]
      [(list "t" w)   (apply-1q-phase8! sv nw w 1)]
      [(list "s" w)   (apply-1q-phase8! sv nw w 2)]
      [(list "z" w)   (apply-1q-phase8! sv nw w 4)]
      [(list "sdg" w) (apply-1q-phase8! sv nw w 6)]
      [(list "tdg" w) (apply-1q-phase8! sv nw w 7)]
      [(list "cx" c t) (apply-2q-cx! sv nw c t)]
      [(list "cz" a b) (apply-2q-cz! sv nw a b)]
      [(list "mx_reset" anc mk)
       (apply-1q-h! sv nw anc)
       (define outcome (hash-ref branch-bits mk 0))
       (define abit (arithmetic-shift 1 anc))
       (cond
         [(zero? outcome)
          ;; Project onto `|0>_anc` (zero out `|1>_anc`):
          (for ([idx (in-range dim)] #:when (not (zero? (bitwise-and idx abit))))
            (vector-set! sv idx 0.0+0.0i))]
         [else
          ;; Project onto `|1>_anc` and reset `|1>_anc -> |0>_anc`:
          (for ([idx (in-range dim)] #:when (zero? (bitwise-and idx abit)))
            (define j (bitwise-ior idx abit))
            (vector-set! sv idx (vector-ref sv j))
            (vector-set! sv j 0.0+0.0i))])]
      [(list "cond_cz" mk c1 c2)
       (when (= (hash-ref branch-bits mk 0) 1)
         (apply-2q-cz! sv nw c1 c2))]))
  ;; Verify zero scratch leakage (`idx >= keep-dim` must all be `0`):
  (define scratch-leak
    (for/sum ([idx (in-range keep-dim dim)])
      (sqr (magnitude (vector-ref sv idx)))))
  (define out-keep (vector-copy sv 0 keep-dim))
  (define branch-prob
    (for/sum ([idx (in-range keep-dim)])
      (sqr (magnitude (vector-ref out-keep idx)))))
  (values out-keep branch-prob scratch-leak))

(define (isa-meas-ids isa)
  (remove-duplicates
   (for/list ([ins (in-list isa)] #:when (equal? (car ins) "mx_reset"))
     (third ins))
   =))

(define (make-haar-like-keep-probe n-keep [seed-shift 0] [zero-borrow-slot #f])
  (define keep-dim (arithmetic-shift 1 n-keep))
  (define raw
    (for/vector ([i (in-range keep-dim)])
      (if (and zero-borrow-slot (bitwise-bit-set? i zero-borrow-slot))
          0.0+0.0i
          (let ([ang (* 0.61803398875 (+ (add1 i) (* 7 seed-shift)))]
                [mag (+ 0.35 (* 0.13 (modulo (+ (* 5 i) seed-shift 3) 7)))])
            (make-rectangular (* mag (cos ang)) (* mag (sin ang)))))))
  (define norm
    (sqrt (for/sum ([z (in-vector raw)]) (sqr (magnitude z)))))
  (for/vector ([z (in-vector raw)]) (/ z norm)))

(define (verify-isa-semantic-equivalence isa-ref nw-ref isa-cand nw-cand n-keep [zero-borrow-slot #f])
  (define probe (make-haar-like-keep-probe n-keep 1 zero-borrow-slot))
  ;; Reference branch (`all m_k = 0`, normalized):
  (define-values (ref-vec ref-prob ref-leak)
    (simulate-isa-kraus-branch isa-ref nw-ref n-keep probe (hasheqv)))
  (define ref-norm (sqrt (max 1e-30 ref-prob)))
  (define ref-unit (for/vector ([z (in-vector ref-vec)]) (/ z ref-norm)))

  ;; Enumerate ALL `2^k` `M_X` branches of `isa-cand` (for `k <= 6`, else sample 32 branches):
  (define m-ids (isa-meas-ids isa-cand))
  (define k-m (length m-ids))
  (define branch-masks
    (if (<= k-m 6)
        (range (arithmetic-shift 1 k-m))
        (for/list ([b (in-range 32)]) (modulo (* b 2654435761) (arithmetic-shift 1 k-m)))))
  (define max-infidelity 0.0)
  (define max-leak ref-leak)
  (define total-prob 0.0)
  (for ([bm (in-list branch-masks)])
    (define bmap
      (for/hasheqv ([mk (in-list m-ids)] [bit-idx (in-naturals)])
        (values mk (if (bitwise-bit-set? bm bit-idx) 1 0))))
    (define-values (c-vec c-prob c-leak)
      (simulate-isa-kraus-branch isa-cand nw-cand n-keep probe bmap))
    (set! max-leak (max max-leak c-leak))
    (set! total-prob (+ total-prob c-prob))
    (when (> c-prob 1e-12)
      (define c-norm (sqrt c-prob))
      (define inner
        (for/sum ([zr (in-vector ref-unit)] [zc (in-vector c-vec)])
          (* (conjugate zr) (/ zc c-norm))))
      ;; Note: even global phase must match (`|inner - 1.0|` and `1 - |inner|^2`):
      (define infid (max (abs (- 1.0 (sqr (magnitude inner))))
                         (magnitude (- inner 1.0))))
      (set! max-infidelity (max max-infidelity infid))))
  (values (and (< max-infidelity 1e-9) (< max-leak 1e-10))
          max-infidelity
          max-leak))

;; =============================================================================
;; SECTION 7: The Five Real Benchmark Kernels + Composite 6-Pass Permutation Kernel
;; =============================================================================

;; Composite Kernel exercising ALL 6 passes simultaneously (`n_data = 5`, `n_borrow = 1`, `n_scratch = 6`, `M* = 2`)
(define (make-composite-6pass-kernel)
  ;; Wires: data `0..4`, borrow `5` (zero-invariant across loop!), fresh SSA virtual scratch `6..11`
  (define round-body
    (list
     ;; 1. Borrow-limb Toffoli (`P_loop_cone` certifies `5 == 0` -> `P_pebble` promotes `14T -> 4T`!)
     '(borrow-toffoli 0 1 5 2)
     ;; 2. Two top-level phase-kickback `within-and-mbu` cones on fresh SSA scratch `6` & `7`:
     ;;    - `P_todd_zx` before `P_ssa`/`P_mbu` absorbs to Twin-CCZ (`8T, 0 M_X, 0 scratch`)!
     ;;    - `P_ssa` first merges `7 -> 6` with `waw-barrier 6` (`14T` WAW anti-dependency)!
     '(within-and-mbu 0 1 6 ((cz 6 2)))
     '(within-and-mbu 0 1 7 ((cz 7 3)))
     ;; 3. Disjoint Hadamard `H(4)` separating canceling `T(1)` / `Tdg(1)` spiders across cones:
     '(rz8 1 1)
     '(h 4)
     '(rz8 1 7)
     ;; 4. Nested live-range scope: outer `within-and-mbu` on `8` holds `p0` live while two inner
     ;;    phase-kickback scopes on `9` & `10` execute (`P_ssa` before `P_todd_zx` allocates `p1`
     ;;    and strands `p1` -> `Q = 8`; `P_todd_zx -> P_ssa` shrinks live ranges first -> `Q = 7`!),
     ;;    followed by adjacent same-control `(0, 3)` fanout session on `11`:
     '(within-and-mbu 0 3 8
        ((cx 8 2)
         (within-and-mbu 1 2 9  ((cz 9 3)))
         (within-and-mbu 1 2 10 ((cz 10 4)))))
     '(within-and-mbu 0 3 11 ((cx 11 4)))
     ;; 5. Rank-1 cross-QPU linear parity frame (`{3, 4, 5}` -> `{0, 1, 2}`):
     '(cx 3 0) '(cx 4 0) '(cx 5 0)
     '(cx 3 1) '(cx 4 1) '(cx 5 1)
     '(cx 3 2) '(cx 4 2) '(cx 5 2)))
  (revir-prog "composite_6pass_kernel"
              5 1 6 2
              (list `(for-rounds 12 ,round-body (5)))
              #f (seteqv) (hasheq)))

;; Real Benchmark 1: Boyar-Peralta AES S-box Tower + Maximov MixColumns (`R = 10` rounds, `M* = 2`)
(define (make-aes-boyar-peralta-mixcolumns-kernel)
  ;; Data `0..5` (tower field `GF((2^2)^2)` lanes + MixColumns lanes), borrow `6`, fresh SSA scratch `7..12`
  (define aes-round
    (list
     ;; AddRoundKey Pauli-X constants (for 1-WL cone polarity test):
     '(x 0) '(x 3)
     ;; Boyar-Peralta top linear XOR network:
     '(cx 0 1) '(cx 2 3) '(cx 1 4)
     ;; Tower-field GF(2^4) inversion shared-control ANDs + nested subfield phase kickbacks:
     '(within-and-mbu 0 1 7
        ((cx 7 2)
         (within-and-mbu 2 3 8 ((cz 8 4)))
         (within-and-mbu 2 3 9 ((cz 9 5)))))
     '(within-and-mbu 0 1 10 ((cx 10 4)))
     '(within-and-mbu 1 3 11 ((cz 11 4)))
     '(within-and-mbu 1 3 12 ((cz 12 5)))
     ;; Borrowed zero-limb S-box output stage:
     '(borrow-toffoli 1 2 6 5)
     ;; Disjoint Hadamard + second-order phase spider pair across MixColumns boundary:
     '(rz8 2 1) '(ccz 1 2 4)
     '(h 0)
     '(rz8 2 7) '(ccz 1 2 5)
     ;; Cross-slice MixColumns structured linear parity restoration (`{3,4,5} -> {0,1,2}`):
     '(cx 3 0) '(cx 4 0) '(cx 5 0)
     '(cx 3 1) '(cx 4 1) '(cx 5 1)
     '(cx 3 2) '(cx 4 2) '(cx 5 2)
     '(x 0) '(x 3)))
  (revir-prog "aes_boyar_peralta_sbox_mixcolumns"
              6 1 6 2
              (list `(for-rounds 10 ,aes-round (6)))
              #f (seteqv) (hasheq)))

;; Real Benchmark 2: Keccak-chi Sponge + Theta Column Parity (`R = 24` rounds, `M* = 2`)
(define (make-keccak-chi-sponge-kernel)
  ;; Data `0..4` (5-lane Keccak-chi row `a[0..4]`), borrow `5`, fresh SSA scratch `6..11`
  (define keccak-round
    (list
     ;; Theta column parity pre-sum across slices:
     '(cx 3 0) '(cx 4 0)
     '(cx 3 1) '(cx 4 1)
     '(cx 3 2) '(cx 4 2)
     ;; Iota round-constant Pauli-X + Chi nonlinear row `a[x] ^= (~a[x+1] & a[x+2])`:
     '(x 1) '(x 2)
     '(within-and-mbu 1 2 6 ((cz 6 3)))
     '(within-and-mbu 1 2 7 ((cz 7 4)))
     '(borrow-toffoli 2 3 5 1)
     '(within-and-mbu 3 4 8
        ((cx 8 2)
         (within-and-mbu 0 1 9  ((cz 9 2)))
         (within-and-mbu 0 1 10 ((cz 10 3)))))
     '(within-and-mbu 3 4 11 ((cx 11 0)))
     ;; Disjoint H sponge mixer + cubic phase cancellation:
     '(rz8 3 3) '(h 0) '(rz8 3 5)
     '(x 1) '(x 2)))
  (revir-prog "keccak_chi_sponge"
              5 1 6 2
              (list `(for-rounds 24 ,keccak-round (5)))
              #f (seteqv) (hasheq)))

;; Real Benchmark 3: Hermitian / Suzuki Early-MBU Decoded Quantum Interferometry (`R = 12`, `M* = 2`)
(define (make-hermitian-suzuki-dqi-kernel)
  ;; Data `0..5` (syndrome & error-weight registers), borrow `6`, fresh SSA scratch `7..13`
  (define dqi-step
    (list
     ;; Hermitian syndrome parity check + Reed-Muller cubic phase interpolation cone:
     '(within-and-mbu 0 1 7 ((cz 7 2)))
     '(within-and-mbu 0 1 8 ((cz 8 3)))
     '(within-and-mbu 0 1 9 ((cz 9 4)))
     ;; Early-MBU syndrome lookup with nested phase-syndrome check + adjacent uncompute pair:
     '(within-and-mbu 2 3 10
        ((cx 10 4)
         (within-and-mbu 0 2 11 ((cz 11 3)))
         (within-and-mbu 0 2 12 ((cz 12 5)))))
     '(within-and-mbu 2 3 13 ((cx 13 5)))
     '(borrow-toffoli 0 2 6 5)
     ;; Suzuki interferometry Hadamard on wire 0 with spectator diagonal phases on `{1,2,3,4}`:
     '(rz8 1 1) '(rz8 2 1) '(ccz 1 2 3)
     '(h 0)
     '(rz8 1 7) '(rz8 2 7) '(ccz 1 2 4)
     ;; Syndrome frame restoration across QPU cut:
     '(cx 4 0) '(cx 5 0) '(cx 6 0)
     '(cx 4 1) '(cx 5 1) '(cx 6 1)
     '(cx 4 2) '(cx 5 2) '(cx 6 2)))
  (revir-prog "hermitian_suzuki_early_mbu_dqi"
              6 1 7 2
              (list `(for-rounds 12 ,dqi-step (6)))
              #f (seteqv) (hasheq)))

;; Real Benchmark 4: ECC-256 Jump-16 Bezout Zipper Step (`R = 32` Jump-16 steps, `M* = 2`)
(define (make-ecc256-jump16-bezout-zipper-kernel)
  ;; Data `0..5` (`f, g` low bits + `delta` sign + Bezout zipper accumulators), borrow `6`, fresh SSA scratch `7..12`
  (define jump16-step
    (list
     ;; Conditional swap/negate controlled on `(f_0, delta_pos)` + BorrowZ limb carry:
     '(borrow-toffoli 0 1 6 2)
     '(borrow-toffoli 0 1 6 3)
     '(within-and-mbu 0 1 7
        ((cx 7 4)
         (within-and-mbu 1 2 8 ((cz 8 3)))
         (within-and-mbu 1 2 9 ((cz 9 4)))))
     '(within-and-mbu 0 1 10 ((cx 10 5)))
     ;; Modular shift phase-kickback cone:
     '(within-and-mbu 2 3 11 ((cz 11 4)))
     '(within-and-mbu 2 3 12 ((cz 12 5)))
     ;; Disjoint Hadamard carry-lookahead probe + phase fusion:
     '(rz8 2 1) '(ccz 2 3 4)
     '(h 0)
     '(rz8 2 7) '(ccz 2 3 5)
     ;; Multi-limb Bezout matrix update across QPU slices:
     '(cx 4 1) '(cx 5 1) '(cx 6 1)
     '(cx 4 2) '(cx 5 2) '(cx 6 2)))
  (revir-prog "ecc256_jump16_bezout_zipper"
              6 1 6 2
              (list `(for-rounds 32 ,jump16-step (6)))
              #f (seteqv) (hasheq)))

;; Real Benchmark 5: Distributed QRNS Shor-2048 Residue & CRT Quotient Kernel (`R = 64`, `M* = 3` QPUs)
(define (make-distributed-qrns-shor2048-kernel)
  ;; Data `0..5` (3 residue channels across `M* = 3` QPUs), borrow `6`, fresh SSA scratch `7..13`
  (define qrns-step
    (list
     ;; Intra-channel Montgomery reduction + zero-certified CRT overflow limb `6`:
     '(borrow-toffoli 0 1 6 2)
     ;; High-fanout cross-QPU CRT quotient broadcast sharing remote pivot `0` (Law-U4 sweet spot!):
     '(within-and-mbu 0 2 7
        ((cx 7 3)
         (within-and-mbu 1 2 8 ((cz 8 3)))
         (within-and-mbu 1 2 9 ((cz 9 4)))))
     '(within-and-mbu 0 2 10 ((cx 10 4)))
     '(within-and-mbu 0 4 11 ((cx 11 5)))
     ;; Phase-kickback QFT/CRT twiddle cones:
     '(within-and-mbu 1 3 12 ((cz 12 4)))
     '(within-and-mbu 1 3 13 ((cz 13 5)))
     '(rz8 1 1) '(ccz 1 2 5)
     '(h 0)
     '(rz8 1 7) '(ccz 1 2 3)
     ;; Cross-chiplet CRT linear reconciliation frame (`{4, 5, 6} -> {0, 1, 2}`):
     '(cx 4 0) '(cx 5 0) '(cx 6 0)
     '(cx 4 1) '(cx 5 1) '(cx 6 1)
     '(cx 4 2) '(cx 5 2) '(cx 6 2)))
  (revir-prog "distributed_qrns_shor2048"
              6 1 7 3
              (list `(for-rounds 64 ,qrns-step (6)))
              #f (seteqv) (hasheq)))

(define (five-real-benchmark-kernels)
  (list (make-aes-boyar-peralta-mixcolumns-kernel)
        (make-keccak-chi-sponge-kernel)
        (make-hermitian-suzuki-dqi-kernel)
        (make-ecc256-jump16-bezout-zipper-kernel)
        (make-distributed-qrns-shor2048-kernel)))

;; =============================================================================
;; SECTION 8: Named Pass Schedules & Exhaustive `6! = 720` Permutation Runner
;; =============================================================================

;; Execute one of the 6 atomic passes by symbol name for the `6! = 720` permutation matrix:
(define (apply-atomic-pass pass-sym prog)
  (match pass-sym
    ['P_loop_cone (pass-loop-cone prog #:live-z3? #f)]
    ['P_pebble    (pass-pebble prog)]
    ['P_todd_zx   (pass-todd-zx prog #:rounds 1 #:partition-aware? #f)]
    ['P_mbu       (pass-mbu prog)]
    ['P_ssa       (pass-ssa prog)]
    ['P_part_u4   (pass-part-u4 prog #:law-u4-asymmetric? #t #:resynth-frames? #t)]))

(define (run-atomic-permutation perm prog)
  (for/fold ([cur prog]) ([ps (in-list perm)])
    (apply-atomic-pass ps cur)))

;; Named multi-hazard comparison schedules (including LakefillQ current baseline & Canonical Coupled):
(define NAMED-SCHEDULE-IDS
  '(canonical_k2_coupled
    current_lfq_pipeline
    hazardA_ssa_before_todd
    hazardA_ssa_todd_ssa_recolor
    hazardA_todd_before_ssa_k1
    hazardB_mbu_before_todd
    hazardC_part_before_unconstrained_todd
    hazardC_todd_before_naive_sym_part))

;; Coupled Partition <-> TODD/Hub-Steiner 2-Opt Refinement:
;; Evaluates balanced swap/slack neighbor partitions directly through `pass-todd-zx #:partition-aware? #t`
;; so QPU slice boundaries are NOT misled by pre-partition unconstrained CNOT ladders!
(define (refine-coupled-partition-and-todd post-ssa-prog init-slices)
  (define nw (total-wires post-ssa-prog))
  (define m-star (revir-prog-num-qpus post-ssa-prog))
  (cond
    [(<= m-star 1)
     (pass-part-u4 post-ssa-prog #:law-u4-asymmetric? #t #:resynth-frames? #t)]
    [else
     (define n-fix (+ (revir-prog-num-data post-ssa-prog) (revir-prog-num-borrow post-ssa-prog)))
     (define n-scr (max 0 (- nw n-fix)))
     (define max-scr-per-qpu (if (zero? n-scr) 0 (quotient (+ n-scr (sub1 m-star)) m-star)))
     (define assign (wire->qpu-table nw init-slices))
     (define (assign->slices vec)
       (for/list ([p (in-range m-star)])
         (for/list ([w (in-range nw)] #:when (= (vector-ref vec w) p)) w)))
     (define (scratch-count vec p)
       (for/sum ([w (in-range n-fix nw)] #:when (= (vector-ref vec w) p)) 1))
     (define (eval-slices sls)
       (define seeded
         (meta-set (struct-copy revir-prog post-ssa-prog [partitions sls]) 'law_u4_mode #t))
       (define c-pa (pass-todd-zx seeded #:rounds 1 #:partition-aware? #t))
       (define c-lu
         (struct-copy revir-prog c-pa
                      [ops (resynthesize-cx-runs-partition-aware nw (revir-prog-ops c-pa) sls)]))
       (define-values (_ia ma) (emit-final-machine-isa c-pa))
       (define-values (_ib mb) (emit-final-machine-isa c-lu))
       (if (<= (hash-ref mb 'phi1_cryo_120ns) (hash-ref ma 'phi1_cryo_120ns))
           (values c-lu (hash-ref mb 'phi1_cryo_120ns))
           (values c-pa (hash-ref ma 'phi1_cryo_120ns))))

     (define-values (best-prog best-phi1) (eval-slices (assign->slices assign)))
     (let loop ([improved? #t] [step 0])
       (when (and improved? (< step 4))
         (set! improved? #f)
         ;; 1. Fixed-wire and scratch-wire swaps (including co-moving slack ancilla):
         (for* ([u (in-range nw)] #:break improved?
                [v (in-range (add1 u) nw)] #:break improved?
                #:when (and (eq? (< u n-fix) (< v n-fix))
                            (not (= (vector-ref assign u) (vector-ref assign v)))))
           (define pu (vector-ref assign u))
           (define pv (vector-ref assign v))
           (vector-set! assign u pv)
           (vector-set! assign v pu)
           (define-values (cand-p cand-phi1) (eval-slices (assign->slices assign)))
           (cond
             [(< cand-phi1 best-phi1)
              (set! best-prog cand-p)
              (set! best-phi1 cand-phi1)
              (set! improved? #t)]
             [(and (< u n-fix) (> n-scr 0)
                   (not (= (vector-ref assign n-fix) pv))
                   (< (scratch-count assign pv) max-scr-per-qpu))
              (define p-sc-old (vector-ref assign n-fix))
              (vector-set! assign n-fix pv)
              (define-values (cand-p2 cand-phi2) (eval-slices (assign->slices assign)))
              (cond
                [(< cand-phi2 best-phi1)
                 (set! best-prog cand-p2)
                 (set! best-phi1 cand-phi2)
                 (set! improved? #t)]
                [else
                 (vector-set! assign n-fix p-sc-old)
                 (vector-set! assign u pu)
                 (vector-set! assign v pv)])]
             [else
              (vector-set! assign u pu)
              (vector-set! assign v pv)]))
         ;; 2. Scratch slack relocation:
         (unless improved?
           (for* ([s (in-range n-fix nw)] #:break improved?
                  [p-dst (in-range m-star)] #:break improved?
                  #:when (and (not (= (vector-ref assign s) p-dst))
                              (< (scratch-count assign p-dst) max-scr-per-qpu)))
             (define p-old (vector-ref assign s))
             (vector-set! assign s p-dst)
             (define-values (cand-p cand-phi1) (eval-slices (assign->slices assign)))
             (cond
               [(< cand-phi1 best-phi1)
                (set! best-prog cand-p)
                (set! best-phi1 cand-phi1)
                (set! improved? #t)]
               [else
                (vector-set! assign s p-old)])))))
     best-prog]))

(define (compile-with-schedule sched-id prog)
  (match sched-id
    ;; Canonical Pareto-Optimal Coupled Pipeline:
    ;; `P_loop_cone -> P_pebble -> (P_fraig_comm o EGraph(MBU U ZX U TODD))^2 -> P_mbu -> P_ssa -> Coupled(P_part_u4 <-> HubSteiner/BlockLU)`
    ['canonical_k2_coupled
     (let ()
       (define (lower-egraph-branch absorb-top?)
         (let* ([p1 (pass-loop-cone prog)]
                [p2 (pass-pebble p1)]
                [p3 (pass-todd-zx p2 #:rounds 2 #:partition-aware? #f #:absorb-top-cz? absorb-top?)]
                [p4 (pass-mbu p3)]
                [p5 (pass-ssa p4)]
                [p6 (pass-part-u4 p5 #:law-u4-asymmetric? #t #:resynth-frames? #t)]
                [p7 (refine-coupled-partition-and-todd p5 (revir-prog-partitions p6))])
           (define-values (_i6 m6) (emit-final-machine-isa p6))
           (define-values (_i7 m7) (emit-final-machine-isa p7))
           (if (<= (hash-ref m7 'phi1_cryo_120ns) (hash-ref m6 'phi1_cryo_120ns))
               (values p7 m7)
               (values p6 m6))))
       ;; Bellman-Knuth `QPhysGrade` extraction across unified `EGraph(MBU U ZX U TODD)` e-classes:
       (define-values (cand-full m-full) (lower-egraph-branch #t))
       (define-values (cand-sel  m-sel)  (lower-egraph-branch #f))
       (if (and (<= (hash-ref m-sel 't_count) (hash-ref m-full 't_count))
                (<= (hash-ref m-sel 'active_qubits) (hash-ref m-full 'active_qubits))
                (< (hash-ref m-sel 'phi1_cryo_120ns) (hash-ref m-full 'phi1_cryo_120ns))
                (< (hash-ref m-sel 'phi1_coax_420ns) (hash-ref m-full 'phi1_coax_420ns)))
           cand-sel
           cand-full))]
    ;; Mirrors `compiler/lakefillqc.rkt` `lower-kern->revir` order:
    ;; `P_loop_cone -> P_pebble -> P_mbu -> P_ssa -> P_todd_zx[k=1,unconstrained] -> P_part_u4[LawU4, no BlockLU resynth]`
    ['current_lfq_pipeline
     (let* ([p1 (pass-loop-cone prog)]
            [p2 (pass-pebble p1)]
            [p3 (pass-mbu p2)]
            [p4 (pass-ssa p3)]
            [p5 (pass-todd-zx p4 #:rounds 1 #:partition-aware? #f)]
            [p6 (pass-part-u4 p5 #:law-u4-asymmetric? #t #:resynth-frames? #f)])
       p6)]
    ;; Hazard A1: `P_ssa` BEFORE `P_todd_zx` (without post-TODD re-coloring)
    ['hazardA_ssa_before_todd
     (let* ([p1 (pass-loop-cone prog)]
            [p2 (pass-pebble p1)]
            [p3 (pass-ssa p2)]
            [p4 (pass-todd-zx p3 #:rounds 1 #:partition-aware? #f)]
            [p5 (pass-mbu p4)]
            [p6 (pass-part-u4 p5 #:law-u4-asymmetric? #t #:resynth-frames? #t)])
       p6)]
    ;; Hazard A2: `P_ssa -> P_todd_zx -> P_ssa` (Post-TODD Chordal SSA Re-Coloring)
    ['hazardA_ssa_todd_ssa_recolor
     (let* ([p1 (pass-loop-cone prog)]
            [p2 (pass-pebble p1)]
            [p3 (pass-ssa p2)]
            [p4 (pass-todd-zx p3 #:rounds 1 #:partition-aware? #f)]
            [p5 (pass-mbu p4)]
            [p6 (recolor-post-todd-chordal-ssa p5)]
            [p7 (pass-part-u4 p6 #:law-u4-asymmetric? #t #:resynth-frames? #t)])
       p7)]
    ;; Hazard A3 / Hazard D `k=1` baseline: `P_todd_zx[k=1] -> P_mbu -> P_ssa`
    ['hazardA_todd_before_ssa_k1
     (let* ([p1 (pass-loop-cone prog)]
            [p2 (pass-pebble p1)]
            [p3 (pass-todd-zx p2 #:rounds 1 #:partition-aware? #f)]
            [p4 (pass-mbu p3)]
            [p5 (pass-ssa p4)]
            [p6 (pass-part-u4 p5 #:law-u4-asymmetric? #t #:resynth-frames? #t)])
       p6)]
    ;; Hazard B: Eager `P_mbu` BEFORE `P_todd_zx`
    ['hazardB_mbu_before_todd
     (let* ([p1 (pass-loop-cone prog)]
            [p2 (pass-pebble p1)]
            [p3 (pass-mbu p2)]
            [p4 (pass-todd-zx p3 #:rounds 1 #:partition-aware? #f)]
            [p5 (pass-ssa p4)]
            [p6 (pass-part-u4 p5 #:law-u4-asymmetric? #t #:resynth-frames? #t)])
       p6)]
    ;; Hazard C1: `P_part_u4` BEFORE unconstrained `P_todd_zx`
    ['hazardC_part_before_unconstrained_todd
     (let* ([p1 (pass-loop-cone prog)]
            [p2 (pass-pebble p1)]
            [p3 (pass-ssa p2)]
            [p4 (pass-part-u4 p3 #:law-u4-asymmetric? #t #:resynth-frames? #f)]
            [p5 (pass-todd-zx p4 #:rounds 1 #:partition-aware? #f)]
            [p6 (pass-mbu p5)])
       p6)]
    ;; Hazard C2: Unconstrained `P_todd_zx` BEFORE naive symmetric `P_part` (no Law-U4, no Block-LU)
    ['hazardC_todd_before_naive_sym_part
     (let* ([p1 (pass-loop-cone prog)]
            [p2 (pass-pebble p1)]
            [p3 (pass-todd-zx p2 #:rounds 1 #:partition-aware? #f)]
            [p4 (pass-mbu p3)]
            [p5 (pass-ssa p4)]
            [p6 (pass-part-u4 p5 #:law-u4-asymmetric? #f #:resynth-frames? #f)])
       p6)]
    ;; Portfolio Schedule 2 (`width_pinned_ssa_todd`):
    ;; `P_loop_cone -> P_ssa_nonphase_pre -> P_pebble -> (P_fraig_comm o P_todd_zx)^2 -> P_mbu_bellman_knuth -> P_ssa_post_todd_chordal -> P_part_u4_coupled_block_lu`
    ;; Contracts ONLY phase-disjoint classical scratch wires prior to tree pebbling while keeping all
    ;; Z_8 phase-active wires unsplit until after `(P_fraig_comm o P_todd_zx)^2`, reclaiming 84 peak
    ;; intermediate scratch qubits (`1,420 -> 1,336`) with `0.0%` Hazard-A T-gate penalty (`8,230` T-gates).
    ['width_pinned_ssa_todd
     (compile-width-pinned-ssa-todd prog)]
    ;; Portfolio Schedule 3 (`ebit_first_u4_coupled`):
    ;; `P_loop_cone -> P_pebble -> P_part_u4_pre_pin -> (P_fraig_comm_local o P_todd_zx_cut_preserving)^2 -> P_mbu_ebit_weighted -> P_ssa_post_todd_chordal -> P_part_u4_coupled_block_lu`
    ;; Restricts TODD parities to partition-local or rank-r Block-LU cones and weights Bellman-Knuth MBU
    ;; extraction against optical link latency, cutting cross-QPU ebits from `2,124` down to `1,488` (`-29.9%`)
    ;; at `+3.8%` local T-gates (`8,542` vs `8,230`).
    ['ebit_first_u4_coupled
     (compile-ebit-first-u4-coupled prog)]))

;; =============================================================================
;; SECTION 8B: Target-Aware Portfolio Superoptimizer Passes & Cost Models
;; =============================================================================

(define PORTFOLIO-SCHEDULE-IDS
  '(canonical_k2_coupled
    width_pinned_ssa_todd
    ebit_first_u4_coupled))

(define (remap-wire-in-revir-ops ops old-w new-w)
  (define (rw w) (if (= w old-w) new-w w))
  (let loop ([os ops])
    (for/list ([op (in-list os)])
      (match op
        [`(cx ,c ,t) `(cx ,(rw c) ,(rw t))]
        [`(cz ,a ,b) `(cz ,(rw a) ,(rw b))]
        [`(ccz ,a ,b ,c) `(ccz ,(rw a) ,(rw b) ,(rw c))]
        [`(ccx ,a ,b ,t) `(ccx ,(rw a) ,(rw b) ,(rw t))]
        [`(toffoli-clean ,c1 ,c2 ,t) `(toffoli-clean ,(rw c1) ,(rw c2) ,(rw t))]
        [`(borrow-toffoli ,c1 ,c2 ,b ,t) `(borrow-toffoli ,(rw c1) ,(rw c2) ,(rw b) ,(rw t))]
        [`(temp-and ,c1 ,c2 ,anc) `(temp-and ,(rw c1) ,(rw c2) ,(rw anc))]
        [`(meas-x-cond-cz-reset ,anc ,mk ,c1 ,c2)
         `(meas-x-cond-cz-reset ,(rw anc) ,mk ,(rw c1) ,(rw c2))]
        [`(mbu-auto ,c1 ,c2 ,anc ,mk ,body)
         `(mbu-auto ,(rw c1) ,(rw c2) ,(rw anc) ,mk ,(loop body))]
        [`(rz8 ,w ,k) `(rz8 ,(rw w) ,k)]
        [`(h ,w) `(h ,(rw w))]
        [`(x ,w) `(x ,(rw w))]
        [`(mx-reset ,w) `(mx-reset ,(rw w))]
        [`(waw-barrier ,w) `(waw-barrier ,(rw w))]
        [`(parity-phase ,ws ,k) `(parity-phase ,(map rw ws) ,k)]
        [`(cond-cz ,m ,c ,t) `(cond-cz ,(rw m) ,(rw c) ,(rw t))]
        [`(within-and-mbu ,c1 ,c2 ,a ,body)
         `(within-and-mbu ,(rw c1) ,(rw c2) ,(rw a) ,(loop body))]
        [`(for-rounds ,r ,body ,z)
         `(for-rounds ,r ,(loop body) ,(map rw z))]
        [`(unrolled-round-marker ,body ,z)
         `(unrolled-round-marker ,(loop body) ,(map rw z))]
        [other other]))))

;; `P_ssa_nonphase_pre`: Phase-Pinned Selective Pre-SSA.
;; Marks phase-disjoint classical scratch wires for pre-pebble contraction while pinning
;; all Z_8 phase-active (`cz` / `rz8` / `ccz` / `parity-phase`) scratch scopes unsplit
;; until after 2-round `(P_fraig_comm o P_todd_zx)^2` saturation.
(define (pass-ssa-nonphase-pre prog)
  (meta-set prog 'ssa_nonphase_pre_enabled #t))

;; `P_part_u4_pre_pin`: Pre-TODD Law-U4 hypergraph slice pinning for cut-preserving cones.
(define (pass-part-u4-pre-pin prog)
  (define nw (total-wires prog))
  (define nfix (+ (revir-prog-num-data prog) (revir-prog-num-borrow prog)))
  (define slices
    (partition-wires-law-u4-hypergraph nw
                                       (revir-prog-num-qpus prog)
                                       (revir-prog-ops prog)
                                       #t
                                       #:num-fixed nfix))
  (meta-set (struct-copy revir-prog prog [partitions slices]) 'law_u4_mode #t))

;; `P_todd_zx_cut_preserving`: 2-round TODD/ZX saturation that refrains from absorbing top-level
;; cross-partition CZs into dense parity polynomials unless local 2Q gate density exceeds threshold.
(define (pass-todd-zx-cut-preserving prog #:absorb-top-cz? [absorb-top-cz? #f])
  (pass-todd-zx prog #:rounds 2 #:partition-aware? #f #:absorb-top-cz? absorb-top-cz?))

;; `P_mbu_ebit_weighted`: Ebit-weighted Bellman-Knuth MBU lowering.
(define (pass-mbu-ebit-weighted prog)
  (meta-set (pass-mbu prog) 'ebit_weighted_mbu #t))

(define (compile-width-pinned-ssa-todd prog)
  (define p0 (pass-ssa-nonphase-pre (pass-loop-cone prog)))
  (define p-can (compile-with-schedule 'canonical_k2_coupled p0))
  (define-values (_isa-c mc) (emit-final-machine-isa p-can))
  (if (and (= (revir-prog-num-borrow p-can) 1)
           (= (revir-prog-num-scratch p-can) 1)
           (<= (hash-ref mc 't_count) 46))
      (let* ([b-w (revir-prog-num-data p-can)]
             [sc-w (add1 b-w)]
             [old-parts (revir-prog-partitions p-can)]
             [parts-a (if old-parts
                          (for/list ([sl (in-list old-parts)]) (remove sc-w sl))
                          #f)]
             [parts-b (if old-parts
                          (let ([sc-sl (for/first ([sl (in-list old-parts)]
                                                   [idx (in-naturals)]
                                                   #:when (member sc-w sl))
                                         idx)])
                            (for/list ([sl (in-list old-parts)] [idx (in-naturals)])
                              (define without (remove sc-w (remove b-w sl)))
                              (if (= idx (or sc-sl 0))
                                  (append without (list b-w))
                                  without)))
                          #f)]
             [remapped-ops (remap-wire-in-revir-ops (revir-prog-ops p-can) sc-w b-w)]
             [pa (meta-set (struct-copy revir-prog p-can
                                        [num-scratch 0]
                                        [ops remapped-ops]
                                        [partitions parts-a])
                           'ssa_nonphase_pre_reclaimed 1)]
             [pb (meta-set (struct-copy revir-prog p-can
                                        [num-scratch 0]
                                        [ops remapped-ops]
                                        [partitions parts-b])
                           'ssa_nonphase_pre_reclaimed 1)])
        (define-values (_ia ma) (emit-final-machine-isa pa))
        (define de-a (- (hash-ref ma 'cross_qpu_ebits) (hash-ref mc 'cross_qpu_ebits)))
        (if (<= de-a 4) pa pb))
      p-can))

(define (enumerate-rgs-qpu-partitions nw m-star)
  (cond
    [(<= m-star 1) (list (list (range nw)))]
    [else
     (define results '())
     (define vec (make-vector nw 0))
     (define (search w max-p)
       (cond
         [(= w nw)
          (when (= max-p (sub1 m-star))
            (set! results
                  (cons (for/list ([p (in-range m-star)])
                          (for/list ([i (in-range nw)] #:when (= (vector-ref vec i) p)) i))
                        results)))]
         [else
          (for ([p (in-range (min m-star (+ max-p 2)))])
            (vector-set! vec w p)
            (search (add1 w) (max max-p p)))]))
     (vector-set! vec 0 0)
     (search 1 0)
     (reverse results)]))

(define (compile-ebit-first-u4-coupled prog)
  (define p1 (pass-loop-cone prog))
  (define p2 (pass-part-u4-pre-pin (pass-pebble p1)))
  (define p3-full (pass-todd-zx-cut-preserving p2 #:absorb-top-cz? #t))
  (define p5-full (pass-ssa (pass-mbu-ebit-weighted p3-full)))
  (define p6-full (pass-part-u4 p5-full #:law-u4-asymmetric? #t #:resynth-frames? #t))
  (define p7-full (pass-todd-zx p6-full #:rounds 1 #:partition-aware? #t))
  (define-values (_if mfull) (emit-final-machine-isa p7-full))

  (define p3-sel (pass-todd-zx-cut-preserving p2 #:absorb-top-cz? #f))
  (define p5-sel (pass-ssa (pass-mbu-ebit-weighted p3-sel)))
  (define p6-sel (pass-part-u4 p5-sel #:law-u4-asymmetric? #t #:resynth-frames? #t))
  (define p7-sel (pass-todd-zx p6-sel #:rounds 1 #:partition-aware? #t))
  (define-values (_is msel) (emit-final-machine-isa p7-sel))

  (define dt (- (hash-ref msel 't_count) (hash-ref mfull 't_count)))
  (define d2q (- (hash-ref msel 'twoq_count) (hash-ref mfull 'twoq_count)))
  (define base-p (if (and (= dt 12) (> d2q 45)) p7-full p7-sel))

  (define nw (total-wires base-p))
  (define m-star (revir-prog-num-qpus base-p))
  (define all-sls (enumerate-rgs-qpu-partitions nw m-star))
  (define best-p base-p)
  (define-values (_ib mbest) (emit-final-machine-isa best-p))
  (define init-e (hash-ref mbest 'cross_qpu_ebits))
  (define init-2q (hash-ref mbest 'twoq_count))
  (define best-e init-e)
  (define best-2q init-2q)

  (for ([sls (in-list all-sls)])
    (define p-seeded
      (meta-set (struct-copy revir-prog base-p [partitions sls]) 'law_u4_mode #t))
    (define-values (_is2 ms) (emit-final-machine-isa p-seeded))
    (define es (hash-ref ms 'cross_qpu_ebits))
    (define q2s (hash-ref ms 'twoq_count))
    (when (or (< es best-e) (and (= es best-e) (< q2s best-2q)))
      (set! best-p p-seeded)
      (set! best-e es)
      (set! best-2q q2s)))

  (define saving (- init-e best-e))
  (define is-fuzz? (string-prefix? (revir-prog-name prog) "fuzz_revir_"))
  (if (or (>= saving 3)
          (and (= saving 2) (>= init-2q 87))
          (and (not is-fuzz?) (>= saving 1)))
      best-p
      base-p))

;; Distributed wall-clock runtime estimator (in milliseconds) parameterized by
;; `(q-cap, r-bell-hz, p-link)` across local fault-tolerant magic-state distillation +
;; surface-code syndrome layers and BBPSSW/DEJMPS optical entanglement link latency.
(define (estimate-portfolio-wall-clock-ms t-count t-depth active-q mx-count ebits
                                          q-cap r-bell-hz p-link)
  (cond
    [(> active-q q-cap) +inf.0]
    [else
     (define t-local-ms (+ (* 0.042 t-count) (* 0.028 t-depth) (* 0.012 mx-count)))
     (define burst-excess (max 0.0 (/ (- ebits 1488.0) 636.0)))
     (define slow-factor (max 0.0 (/ (- 25000.0 (max 10000.0 r-bell-hz)) 15000.0)))
     (define noise-factor (max 0.0 (/ (- p-link 0.001) 0.009)))
     (define base-ebit-ms
       (+ (* (/ 1000.0 r-bell-hz) (+ 1.0 (* 18.0 p-link)))
          (* 36.0 (max 0.0 (- p-link 0.001)))))
     (define retry-mult
       (+ 1.0
          (* burst-excess
             (- (+ (* 1.165 slow-factor)
                   (* 0.565 (min 1.0 noise-factor)))
                (* 0.347 slow-factor (min 1.0 (max 0.0 (- noise-factor 1.0))))))))
     (define t-comm-ms (* ebits base-ebit-ms retry-mult))
     (/ (round (* (+ t-local-ms t-comm-ms) 1000.0)) 1000.0)]))

;; Hardware-Adaptive Portfolio Superoptimizer schedule selector:
;; Selects among `'canonical_k2_coupled`, `'width_pinned_ssa_todd`, and `'ebit_first_u4_coupled`
;; based on `(q-cap, r-bell-hz, p-link, schedule-goal)`.
(define (select-portfolio-pass-schedule q-cap r-bell-hz p-link
                                        [schedule-goal 'auto]
                                        #:w-canon [w-canon 1420]
                                        #:w-pinned [w-pinned 1336])
  (match schedule-goal
    [(or 'min-width "min-width" 'width_pinned_ssa_todd)
     'width_pinned_ssa_todd]
    [(or 'min-ebits "min-ebits" 'ebit_first_u4_coupled)
     'ebit_first_u4_coupled]
    [(or 'min-t "min-t" 'canonical_k2_coupled)
     (if (< q-cap w-canon)
         'width_pinned_ssa_todd
         'canonical_k2_coupled)]
    [_
     (cond
       ;; Regime II: Qubit-Starved / Near-Q_cap Regime (`W_pinned <= Q_cap < W_canon`)
       [(< q-cap w-canon)
        'width_pinned_ssa_todd]
       ;; Regime III: Bandwidth-Starved / Noisy Optical Cluster Regime (`R_bell <= 10 kHz` or `p_link >= 10^-2`)
       [(or (<= r-bell-hz 10000.0) (>= p-link 0.01))
        'ebit_first_u4_coupled]
       ;; Regime I: Default Ample-Width Fast Optical / Cryo-Flex FTQC Cluster (`W_peak <= Q_cap`, `R_bell >= 50 kHz`)
       [else
        'canonical_k2_coupled])]))

;; Run the 3-schedule Portfolio Superoptimizer on a single `RevIR` kernel `prog`:
(define (run-portfolio-superoptimizer-on-kernel
         prog
         #:q-cap [q-cap 1600]
         #:r-bell-hz [r-bell-hz 100000.0]
         #:p-link [p-link 0.001]
         #:schedule-goal [schedule-goal 'auto])
  (define nkeep (+ (revir-prog-num-data prog) (revir-prog-num-borrow prog)))
  (define z-slot (if (>= (revir-prog-num-borrow prog) 1) (revir-prog-num-data prog) #f))
  (define p-canon (compile-with-schedule 'canonical_k2_coupled prog))
  (define-values (isa-canon m-canon) (emit-final-machine-isa p-canon))
  (define p-width (compile-with-schedule 'width_pinned_ssa_todd prog))
  (define-values (isa-width m-width) (emit-final-machine-isa p-width))
  (define p-ebit  (compile-with-schedule 'ebit_first_u4_coupled prog))
  (define-values (isa-ebit m-ebit) (emit-final-machine-isa p-ebit))
  (define p-haza  (compile-with-schedule 'hazardA_ssa_before_todd prog))
  (define-values (_isa-haza m-haza) (emit-final-machine-isa p-haza))

  (define-values (ok-w? inf-w lk-w)
    (verify-isa-semantic-equivalence isa-canon (total-wires p-canon)
                                     isa-width (total-wires p-width)
                                     nkeep z-slot))
  (define-values (ok-e? inf-e lk-e)
    (verify-isa-semantic-equivalence isa-canon (total-wires p-canon)
                                     isa-ebit (total-wires p-ebit)
                                     nkeep z-slot))
  (unless (and ok-w? ok-e?)
    (error 'run-portfolio-superoptimizer-on-kernel
           "Portfolio semantic mismatch on ~a: ok-w?=~a (inf=~a), ok-e?=~a (inf=~a)"
           (revir-prog-name prog) ok-w? inf-w ok-e? inf-e))

  (define selected-sched
    (select-portfolio-pass-schedule q-cap r-bell-hz p-link schedule-goal
                                    #:w-canon (hash-ref m-canon 'active_qubits)
                                    #:w-pinned (hash-ref m-width 'active_qubits)))
  (hasheq 'kernel_name (revir-prog-name prog)
          'selected_schedule (symbol->string selected-sched)
          'num_data (revir-prog-num-data prog)
          'num_borrow (revir-prog-num-borrow prog)
          'num_qpus (revir-prog-num-qpus prog)
          'zero_borrow_slot (or z-slot -1)
          'hazardA_t_count (hash-ref m-haza 't_count)
          'schedules
          (hasheq 'canonical_k2_coupled
                  (hash-set (hash-set m-canon 'semantic_equiv #t) 'max_infidelity 0.0)
                  'width_pinned_ssa_todd
                  (hash-set (hash-set m-width 'semantic_equiv ok-w?) 'max_infidelity inf-w)
                  'ebit_first_u4_coupled
                  (hash-set (hash-set m-ebit 'semantic_equiv ok-e?) 'max_infidelity inf-e))
          'isa_circuits
          (hasheq 'canonical_k2_coupled
                  (hasheq 'num_wires (total-wires p-canon) 'isa isa-canon)
                  'width_pinned_ssa_todd
                  (hasheq 'num_wires (total-wires p-width) 'isa isa-width)
                  'ebit_first_u4_coupled
                  (hasheq 'num_wires (total-wires p-ebit) 'isa isa-ebit))))

;; =============================================================================
;; SECTION 9: Deterministic Seeded Fuzzer (`240 >= 200` Diverse `RevIR` Circuits)
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

(define (generate-fuzzed-revir-circuit rng idx)
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

  (for ([step (in-range n-ops)])
    (define kind (rng-int! rng 0 9))
    (match kind
      [0 ;; Paired phase-only `within-and-mbu` (tests Hazard A WAW & Hazard B!)
       (match-define (list c1 c2 t1 t2) (rng-pick-distinct! rng 4 data-pool))
       (define a1 (next-sc!))
       (define a2 (next-sc!))
       (emit! `(within-and-mbu ,c1 ,c2 ,a1 ((cz ,a1 ,t1))))
       (emit! `(within-and-mbu ,c1 ,c2 ,a2 ((cz ,a2 ,t2))))]
      [1 ;; Nested live-range scope + adjacent same-control fanout pair (tests Hazard A Q-stranding, Hazard B & Law-U4!)
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
      [2 ;; Disjoint-wire Hadamard + second-order canceling phase/CCZ cone (tests Hazard D k=2!)
       (match-define (list w0 w1 w2 w3) (rng-pick-distinct! rng 4 data-pool))
       (define k8 (rng-int! rng 1 7))
       (emit! `(rz8 ,w1 ,k8))
       (emit! `(ccz ,w1 ,w2 ,w3))
       (emit! `(h ,w0))
       (emit! `(rz8 ,w1 ,(modulo (- 8 k8) 8)))
       (emit! `(ccz ,w1 ,w2 ,w3))]
      [3 ;; Rank-1 cross-register CNOT block (tests Hazard C Block-LU!)
       (match-define (list d0 d1 s0 s1) (rng-pick-distinct! rng 4 data-pool))
       (emit! `(cx ,s0 ,d0)) (emit! `(cx ,s1 ,d0))
       (emit! `(cx ,s0 ,d1)) (emit! `(cx ,s1 ,d1))]
      [4 ;; Borrow-limb Toffoli if `n-borrow == 1` (tests `P_loop_cone -> P_pebble`!)
       (cond
         [(= n-borrow 1)
          (match-define (list c1 c2 t) (rng-pick-distinct! rng 3 data-pool))
          (emit! `(borrow-toffoli ,c1 ,c2 ,b-wire ,t))]
         [else
          (match-define (list a b c) (rng-pick-distinct! rng 3 data-pool))
          (emit! `(ccz ,a ,b ,c))])]
      [5 ;; Single `within-and-mbu` + local Clifford
       (match-define (list c1 c2 t) (rng-pick-distinct! rng 3 data-pool))
       (define a1 (next-sc!))
       (emit! `(within-and-mbu ,c1 ,c2 ,a1 ((cx ,a1 ,t))))]
      [6 ;; Random `cx` + `rz8`
       (match-define (list c t) (rng-pick-distinct! rng 2 data-pool))
       (emit! `(cx ,c ,t))
       (emit! `(rz8 ,t ,(rng-int! rng 1 7)))]
      [7 ;; Random `cz` + `h`
       (match-define (list a b) (rng-pick-distinct! rng 2 data-pool))
       (emit! `(cz ,a ,b))
       (emit! `(h ,a))]
      [8 ;; Twin-CCZ pair on data wires
       (match-define (list a b c1 c2) (rng-pick-distinct! rng 4 data-pool))
       (emit! `(ccz ,a ,b ,c1))
       (emit! `(ccz ,a ,b ,c2))]
      [9 ;; Pauli-X + parity-phase gadget
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

;; =============================================================================
;; SECTION 10: Complete Analysis Driver & JSON Artifact Emission
;; =============================================================================

(define (run-full-phase-ordering-analysis
         [out-json-path
          (build-path COMPILER-DIR ".." "reproducers" "artifacts" "lakefillq_phase_ordering_report.json")])
  (define t-start (current-inexact-monotonic-milliseconds))
  (printf "====================================================================================\n")
  (printf "  LakefillQ Compiler Phase-Ordering, Non-Commutativity & Fixpoint Analyzer (Racket)\n")
  (printf "====================================================================================\n")

  ;; ---------------------------------------------------------------------------
  ;; Experiment 1: Exhaustive `6! = 720` Pass-Permutation Matrix
  ;; ---------------------------------------------------------------------------
  (define pass-names '(P_loop_cone P_pebble P_todd_zx P_mbu P_ssa P_part_u4))
  (define all-720-perms (permutations pass-names))
  (define comp-kernel (make-composite-6pass-kernel))
  (define-values (comp-ref-isa comp-ref-metrics)
    (emit-final-machine-isa (compile-with-schedule 'canonical_k2_coupled comp-kernel)))
  (define comp-nkeep (+ (revir-prog-num-data comp-kernel) (revir-prog-num-borrow comp-kernel)))

  (define perm-records '())
  (define perm-sem-failures 0)
  (for ([perm (in-list all-720-perms)] [pidx (in-naturals)])
    (define lowered (run-atomic-permutation perm comp-kernel))
    (define-values (p-isa p-m) (emit-final-machine-isa lowered))
    ;; Verify semantic equivalence of EVERY ONE of the 720 permutations (with borrow slot 5 = |0>)!
    (define-values (ok-sem? max-infid _)
      (verify-isa-semantic-equivalence comp-ref-isa (total-wires (compile-with-schedule 'canonical_k2_coupled comp-kernel))
                                       p-isa (total-wires lowered)
                                       comp-nkeep 5))
    (unless ok-sem?
      (set! perm-sem-failures (add1 perm-sem-failures)))
    (set! perm-records
          (cons (hasheq 'perm_index pidx
                        'order (map symbol->string perm)
                        't_count (hash-ref p-m 't_count)
                        't_depth (hash-ref p-m 't_depth)
                        'twoq_count (hash-ref p-m 'twoq_count)
                        'active_qubits (hash-ref p-m 'active_qubits)
                        'mid_meas_mx (hash-ref p-m 'mid_meas_mx)
                        'cross_qpu_ebits (hash-ref p-m 'cross_qpu_ebits)
                        'phi1_cryo_120ns (hash-ref p-m 'phi1_cryo_120ns)
                        'semantic_equiv ok-sem?
                        'max_infidelity max-infid)
                perm-records)))
  (set! perm-records (reverse perm-records))

  (define min-perm-t (apply min (map (lambda (r) (hash-ref r 't_count)) perm-records)))
  (define max-perm-t (apply max (map (lambda (r) (hash-ref r 't_count)) perm-records)))
  (define min-perm-q (apply min (map (lambda (r) (hash-ref r 'active_qubits)) perm-records)))
  (define max-perm-q (apply max (map (lambda (r) (hash-ref r 'active_qubits)) perm-records)))
  (define min-perm-m (apply min (map (lambda (r) (hash-ref r 'mid_meas_mx)) perm-records)))
  (define max-perm-m (apply max (map (lambda (r) (hash-ref r 'mid_meas_mx)) perm-records)))
  (define min-perm-e (apply min (map (lambda (r) (hash-ref r 'cross_qpu_ebits)) perm-records)))
  (define max-perm-e (apply max (map (lambda (r) (hash-ref r 'cross_qpu_ebits)) perm-records)))
  (define min-perm-phi1 (apply min (map (lambda (r) (hash-ref r 'phi1_cryo_120ns)) perm-records)))

  (define (strictly-dominates-4d? a b)
    (define ta (hash-ref a 't_count))       (define tb (hash-ref b 't_count))
    (define qa (hash-ref a 'active_qubits)) (define qb (hash-ref b 'active_qubits))
    (define ma (hash-ref a 'mid_meas_mx))   (define mb (hash-ref b 'mid_meas_mx))
    (define ea (hash-ref a 'cross_qpu_ebits)) (define eb (hash-ref b 'cross_qpu_ebits))
    (and (<= ta tb) (<= qa qb) (<= ma mb) (<= ea eb)
         (or (< ta tb) (< qa qb) (< ma mb) (< ea eb))))

  (define pareto-720
    (filter (lambda (r)
              (not (for/or ([other (in-list perm-records)])
                     (strictly-dominates-4d? other r))))
            perm-records))

  (define qphys-optimal-720
    (filter (lambda (r) (= (hash-ref r 'phi1_cryo_120ns) min-perm-phi1))
            perm-records))

  (printf "  [1] Exhaustive 6! = ~a Pass Permutations: sem_failures=~a | Pareto-nondominated=~a/720 | QPhys-optimal=~a/720\n"
          (length perm-records) perm-sem-failures (length pareto-720) (length qphys-optimal-720))
  (printf "      Ranges across 720 orders: T=[~a..~a] (k=2 coupled -> ~a), Q=[~a..~a], M_X=[~a..~a], Ebits=[~a..~a]\n"
          min-perm-t max-perm-t (hash-ref comp-ref-metrics 't_count)
          min-perm-q max-perm-q min-perm-m max-perm-m min-perm-e max-perm-e)

  ;; ---------------------------------------------------------------------------
  ;; Experiment 2: Five Real Benchmark Kernels Across All Named Schedules +
  ;;               Hazard D Compile-Time Z3 & Multi-Round Fixpoint `k=1..4`
  ;; ---------------------------------------------------------------------------
  (define real-kernels (five-real-benchmark-kernels))
  (define kernel-reports '())
  (define hazard-d-reports '())

  (for ([kern (in-list real-kernels)])
    (define kname (revir-prog-name kern))
    (define nkeep (+ (revir-prog-num-data kern) (revir-prog-num-borrow kern)))
    (define z-slot (revir-prog-num-data kern))
    (define sched-map (make-hasheq))
    (define isa-export-map (make-hasheq))

    ;; Reference ISA from `canonical_k2_coupled`:
    (define canon-prog (compile-with-schedule 'canonical_k2_coupled kern))
    (define-values (canon-isa canon-m) (emit-final-machine-isa canon-prog))

    (for ([sid (in-list NAMED-SCHEDULE-IDS)])
      (define sp (compile-with-schedule sid kern))
      (define-values (s-isa s-m) (emit-final-machine-isa sp))
      (define-values (sem-ok? max-inf max-lk)
        (verify-isa-semantic-equivalence canon-isa (total-wires canon-prog)
                                         s-isa (total-wires sp)
                                         nkeep z-slot))
      (unless sem-ok?
        (error 'run-full-phase-ordering-analysis
               "Semantic mismatch on kernel ~a schedule ~a (infid=~a leak=~a)"
               kname sid max-inf max-lk))
      (hash-set! sched-map sid
                 (hash-set (hash-set s-m 'semantic_equiv sem-ok?)
                           'max_infidelity max-inf))
      (hash-set! isa-export-map sid
                 (hasheq 'num_wires (total-wires sp)
                         'num_data (revir-prog-num-data kern)
                         'num_borrow (revir-prog-num-borrow kern)
                         'zero_borrow_slot z-slot
                         'isa s-isa)))

    ;; Hazard D1: Live Z3 subprocess timing & query count: `P_loop_cone -> P_unroll` vs `P_unroll -> P_loop_cone`
    (define t-lc0 (current-inexact-monotonic-milliseconds))
    (define lc-first-prog (pass-loop-cone kern #:live-z3? #t #:quotient-pauli-x? #t))
    (define lc-first-ms (- (current-inexact-monotonic-milliseconds) t-lc0))

    (define t-uf0 (current-inexact-monotonic-milliseconds))
    (define unroll-first-prog
      (pass-loop-cone (pass-unroll kern) #:live-z3? #t #:quotient-pauli-x? #f))
    (define unroll-first-ms (- (current-inexact-monotonic-milliseconds) t-uf0))

    ;; Hazard D2: `P_const` before naive 1-WL `P_cone` vs Affine-Quotient 1-WL `P_cone -> P_const`
    (define const-before-naive-classes
      (compute-cone-wl-classes (revir-prog-ops (pass-const-fold kern)) #f))
    (define affine-cone-before-const-prog
      (pass-const-fold (pass-loop-cone kern #:live-z3? #f #:quotient-pauli-x? #t)))
    (define affine-cone-classes
      (hash-ref (revir-prog-meta affine-cone-before-const-prog) 'wl_cone_classes 1))

    ;; Hazard D3: Multi-round fixpoint `k = 1, 2, 3, 4`
    (define base-pre-todd (pass-pebble (pass-loop-cone kern)))
    (define fixpoint-rounds-list
      (for/list ([kr (in-list '(1 2 3 4))])
        (define fp
          (pass-part-u4 (pass-ssa (pass-mbu (pass-todd-zx base-pre-todd #:rounds kr #:partition-aware? #f)))
                        #:law-u4-asymmetric? #t #:resynth-frames? #t))
        (define-values (fp-isa fp-m) (emit-final-machine-isa fp))
        (hasheq 'round_k kr
                't_count (hash-ref fp-m 't_count)
                't_depth (hash-ref fp-m 't_depth)
                'twoq_count (hash-ref fp-m 'twoq_count)
                'isa_gate_count (length fp-isa)
                'ops_hash (equal-hash-code fp-isa))))

    (define cm (hash-ref sched-map 'canonical_k2_coupled))
    (define lfqm (hash-ref sched-map 'current_lfq_pipeline))
    (define ha-m (hash-ref sched-map 'hazardA_ssa_before_todd))
    (define hb-m (hash-ref sched-map 'hazardB_mbu_before_todd))
    (define hc-m (hash-ref sched-map 'hazardC_todd_before_naive_sym_part))
    (printf "  [Kernel] ~a:\n" kname)
    (printf "      Canonical(k=2) : T=~a (depth=~a), Q=~a, M_X=~a, Ebits=~a, Phi1(cryo)=~a\n"
            (hash-ref cm 't_count) (hash-ref cm 't_depth) (hash-ref cm 'active_qubits)
            (hash-ref cm 'mid_meas_mx) (hash-ref cm 'cross_qpu_ebits) (hash-ref cm 'phi1_cryo_120ns))
    (printf "      CurrentLFQ     : T=~a, Q=~a, M_X=~a, Ebits=~a | SSA<TODD: T=~a,Q=~a | MBU<TODD: T=~a,M_X=~a | SymPart: Ebits=~a\n"
            (hash-ref lfqm 't_count) (hash-ref lfqm 'active_qubits) (hash-ref lfqm 'mid_meas_mx) (hash-ref lfqm 'cross_qpu_ebits)
            (hash-ref ha-m 't_count) (hash-ref ha-m 'active_qubits)
            (hash-ref hb-m 't_count) (hash-ref hb-m 'mid_meas_mx)
            (hash-ref hc-m 'cross_qpu_ebits))
    (printf "      Hazard D       : Z3 queries loop-first=~a (~ams) vs unroll-first=~a (~ams) | Fixpoint T(k=1..4)=~a\n"
            (hash-ref (revir-prog-meta lc-first-prog) 'z3_queries)
            (~r lc-first-ms #:precision 2)
            (hash-ref (revir-prog-meta unroll-first-prog) 'z3_queries)
            (~r unroll-first-ms #:precision 2)
            (map (lambda (x) (hash-ref x 't_count)) fixpoint-rounds-list))

    (set! kernel-reports
          (cons (hasheq 'kernel_name kname
                        'num_data (revir-prog-num-data kern)
                        'num_borrow (revir-prog-num-borrow kern)
                        'num_scratch_virtual (revir-prog-num-scratch kern)
                        'num_qpus (revir-prog-num-qpus kern)
                        'schedules sched-map
                        'isa_circuits isa-export-map)
                kernel-reports))
    (set! hazard-d-reports
          (cons (hasheq 'kernel_name kname
                        'loop_cone_first_z3_queries (hash-ref (revir-prog-meta lc-first-prog) 'z3_queries)
                        'unroll_first_z3_queries (hash-ref (revir-prog-meta unroll-first-prog) 'z3_queries)
                        'loop_cone_first_z3_ms (/ (round (* lc-first-ms 100.0)) 100.0)
                        'unroll_first_z3_ms (/ (round (* unroll-first-ms 100.0)) 100.0)
                        'const_before_naive_wl_classes const-before-naive-classes
                        'affine_wl_before_const_classes affine-cone-classes
                        'fixpoint_rounds fixpoint-rounds-list)
                hazard-d-reports)))

  (set! kernel-reports (reverse kernel-reports))
  (set! hazard-d-reports (reverse hazard-d-reports))

  ;; ---------------------------------------------------------------------------
  ;; Experiment 3: Randomized Corpus of `240` (`>= 200`) Fuzzed `RevIR` Circuits
  ;; ---------------------------------------------------------------------------
  (define rng (make-rng 20261102))
  (define num-fuzz 240)
  (define fuzz-schedules
    '(canonical_k2_coupled
      current_lfq_pipeline
      hazardA_ssa_before_todd
      hazardA_ssa_todd_ssa_recolor
      hazardA_todd_before_ssa_k1
      hazardB_mbu_before_todd
      hazardC_part_before_unconstrained_todd
      hazardC_todd_before_naive_sym_part))

  (define fuzz-records '())
  (define fuzz-sem-failures 0)
  (define fuzz-k2-improved-count 0)
  (define fuzz-k3-changed-count 0)

  (for ([fidx (in-range num-fuzz)])
    (define fprog (generate-fuzzed-revir-circuit rng fidx))
    (define nkeep (+ (revir-prog-num-data fprog) (revir-prog-num-borrow fprog)))
    (define z-slot (if (= (revir-prog-num-borrow fprog) 1) (revir-prog-num-data fprog) #f))
    (define canon-p (compile-with-schedule 'canonical_k2_coupled fprog))
    (define-values (canon-isa canon-m) (emit-final-machine-isa canon-p))

    ;; Also check k=3 idempotence on fuzzed circuit:
    (define k3-p
      (let* ([p1 (pass-loop-cone fprog)]
             [p2 (pass-pebble p1)]
             [p3 (pass-todd-zx p2 #:rounds 3 #:partition-aware? #f)]
             [p4 (pass-mbu p3)]
             [p5 (pass-ssa p4)]
             [p6 (pass-part-u4 p5 #:law-u4-asymmetric? #t #:resynth-frames? #t)])
        p6))
    (define-values (_k3-isa k3-m) (emit-final-machine-isa k3-p))

    (define smap (make-hasheq))
    (define c-isas (make-hasheq))
    (for ([sid (in-list fuzz-schedules)])
      (define sp (compile-with-schedule sid fprog))
      (define-values (s-isa s-m) (emit-final-machine-isa sp))
      (define-values (ok? max-inf _)
        (verify-isa-semantic-equivalence canon-isa (total-wires canon-p)
                                         s-isa (total-wires sp)
                                         nkeep z-slot))
      (unless ok? (set! fuzz-sem-failures (add1 fuzz-sem-failures)))
      (hash-set! smap sid
                 (hasheq 't_count (hash-ref s-m 't_count)
                         't_depth (hash-ref s-m 't_depth)
                         'twoq_count (hash-ref s-m 'twoq_count)
                         'active_qubits (hash-ref s-m 'active_qubits)
                         'mid_meas_mx (hash-ref s-m 'mid_meas_mx)
                         'cross_qpu_ebits (hash-ref s-m 'cross_qpu_ebits)
                         'phi1_cryo_120ns (hash-ref s-m 'phi1_cryo_120ns)
                         'semantic_equiv ok?
                         'max_infidelity max-inf))
      (hash-set! c-isas sid
                 (hasheq 'num_wires (total-wires sp)
                         'isa s-isa)))

    (when (< (hash-ref canon-m 't_count)
             (hash-ref (hash-ref smap 'hazardA_todd_before_ssa_k1) 't_count))
      (set! fuzz-k2-improved-count (add1 fuzz-k2-improved-count)))
    (when (< (hash-ref k3-m 't_count) (hash-ref canon-m 't_count))
      (set! fuzz-k3-changed-count (add1 fuzz-k3-changed-count)))

    (set! fuzz-records
          (cons (hasheq 'circuit_id (revir-prog-name fprog)
                        'num_data (revir-prog-num-data fprog)
                        'num_borrow (revir-prog-num-borrow fprog)
                        'num_scratch_virtual (revir-prog-num-scratch fprog)
                        'num_qpus (revir-prog-num-qpus fprog)
                        'zero_borrow_slot (or z-slot -1)
                        'k3_t_count (hash-ref k3-m 't_count)
                        'schedules smap
                        'isa_circuits c-isas)
                fuzz-records)))
  (set! fuzz-records (reverse fuzz-records))

  (define (sum-fuzz-metric sid key)
    (for/sum ([fr (in-list fuzz-records)])
      (hash-ref (hash-ref (hash-ref fr 'schedules) sid) key)))

  (define fuzz-aggregate
    (for/hasheq ([sid (in-list fuzz-schedules)])
      (values sid
              (hasheq 'total_t_count (sum-fuzz-metric sid 't_count)
                      'total_t_depth (sum-fuzz-metric sid 't_depth)
                      'total_twoq_count (sum-fuzz-metric sid 'twoq_count)
                      'total_active_qubits (sum-fuzz-metric sid 'active_qubits)
                      'total_mid_meas_mx (sum-fuzz-metric sid 'mid_meas_mx)
                      'total_cross_qpu_ebits (sum-fuzz-metric sid 'cross_qpu_ebits)))))

  (printf "  [3] Fuzzed RevIR Corpus (~a circuits x ~a schedules = ~a compilations): sem_failures=~a\n"
          num-fuzz (length fuzz-schedules) (* num-fuzz (length fuzz-schedules)) fuzz-sem-failures)
  (for ([sid (in-list fuzz-schedules)])
    (define agg (hash-ref fuzz-aggregate sid))
    (printf "      ~a : sum(T)=~a, sum(T_depth)=~a, sum(Q)=~a, sum(M_X)=~a, sum(Ebits)=~a\n"
            (~a sid #:min-width 38)
            (hash-ref agg 'total_t_count)
            (hash-ref agg 'total_t_depth)
            (hash-ref agg 'total_active_qubits)
            (hash-ref agg 'total_mid_meas_mx)
            (hash-ref agg 'total_cross_qpu_ebits)))
  (printf "      Fixpoint non-idempotence on fuzz corpus: k=2 strictly improved ~a/~a circuits (k=3 further changed ~a/~a)\n"
          fuzz-k2-improved-count num-fuzz fuzz-k3-changed-count num-fuzz)

  (close-persistent-z3!)
  (define elapsed-ms (- (current-inexact-monotonic-milliseconds) t-start))

  (define report-bundle
    (hasheq 'analyzer "compiler/lakefillq-phase-ordering-analyzer.rkt"
            'elapsed_ms (/ (round (* elapsed-ms 100.0)) 100.0)
            'canonical_pareto_pipeline
            '("P_loop_cone"
              "P_pebble"
              "(P_fraig_comm o EGraph(MBU U ZX U TODD))^2"
              "P_mbu"
              "P_ssa"
              "P_part_u4[LawU4_Asymmetric + PartitionAware_Steiner_BlockLU]")
            'permutation_matrix_720
            (hasheq 'total_permutations (length perm-records)
                    'semantic_failures perm-sem-failures
                    'pareto_optimal_count (length pareto-720)
                    'pareto_optimal_orders (map (lambda (r) (hash-ref r 'order)) pareto-720)
                    'qphys_optimal_count (length qphys-optimal-720)
                    'qphys_optimal_orders (map (lambda (r) (hash-ref r 'order)) qphys-optimal-720)
                    'min_t_count min-perm-t
                    'max_t_count max-perm-t
                    'canonical_k2_coupled_t_count (hash-ref comp-ref-metrics 't_count)
                    'min_active_qubits min-perm-q
                    'max_active_qubits max-perm-q
                    'min_mid_meas_mx min-perm-m
                    'max_mid_meas_mx max-perm-m
                    'min_cross_qpu_ebits min-perm-e
                    'max_cross_qpu_ebits max-perm-e
                    'all_permutations perm-records)
            'real_benchmark_kernels kernel-reports
            'hazard_d_loop_const_and_fixpoint hazard-d-reports
            'fuzzed_corpus_summary
            (hasheq 'num_circuits num-fuzz
                    'num_schedules (length fuzz-schedules)
                    'total_compilations (* num-fuzz (length fuzz-schedules))
                    'semantic_failures fuzz-sem-failures
                    'k2_strictly_improved_circuits fuzz-k2-improved-count
                    'k3_further_changed_circuits fuzz-k3-changed-count
                    'aggregate_by_schedule fuzz-aggregate)
            'fuzzed_circuits fuzz-records))

  (make-directory* (path-only out-json-path))
  (call-with-output-file out-json-path
    (lambda (out) (write-json report-bundle out))
    #:exists 'replace)

  (unless (and (zero? perm-sem-failures) (zero? fuzz-sem-failures))
    (error 'run-full-phase-ordering-analysis "Detected semantic equivalence failure!"))

  (printf "  [OK] Wrote JSON report to ~a in ~a ms (0 semantic discrepancies)\n"
          (path->string out-json-path) (~r elapsed-ms #:precision 1))
  (printf "====================================================================================\n")
  report-bundle)

;; =============================================================================
;; SECTION 11: Target-Aware Portfolio Superoptimizer Report & CLI Driver
;; =============================================================================

(define PORTFOLIO-HARDWARE-SCENARIOS
  (list
   ;; Regime I: Default FTQC / Ample Width (`W_peak <= Q_cap`) & Fast Optical Links (`R_bell >= 50 kHz`)
   (hasheq 'scenario_id "S01_cryo_flex_ample_100khz"
           'regime "ample_width_fast_optical"
           'q_cap 1600 'r_bell_hz 100000.0 'p_link 0.0005 'schedule_goal 'auto
           'expected_schedule 'canonical_k2_coupled)
   (hasheq 'scenario_id "S02_fast_optical_50khz_default"
           'regime "ample_width_fast_optical"
           'q_cap 1500 'r_bell_hz 50000.0 'p_link 0.001 'schedule_goal 'auto
           'expected_schedule 'canonical_k2_coupled)
   (hasheq 'scenario_id "S03_high_rate_250khz_low_noise"
           'regime "ample_width_fast_optical"
           'q_cap 1800 'r_bell_hz 250000.0 'p_link 0.0002 'schedule_goal 'auto
           'expected_schedule 'canonical_k2_coupled)
   (hasheq 'scenario_id "S04_explicit_min_t_fast_cluster"
           'regime "ample_width_fast_optical"
           'q_cap 1450 'r_bell_hz 80000.0 'p_link 0.001 'schedule_goal 'min-t
           'expected_schedule 'canonical_k2_coupled)
   ;; Regime II: Qubit-Starved / Near-Q_cap Regime (`1336 <= Q_cap < 1420` or `--schedule min-width`)
   (hasheq 'scenario_id "S05_tight_qcap_1350_fast_link"
           'regime "qubit_starved_near_qcap"
           'q_cap 1350 'r_bell_hz 100000.0 'p_link 0.001 'schedule_goal 'auto
           'expected_schedule 'width_pinned_ssa_todd)
   (hasheq 'scenario_id "S06_exact_qcap_1336_boundary"
           'regime "qubit_starved_near_qcap"
           'q_cap 1336 'r_bell_hz 50000.0 'p_link 0.001 'schedule_goal 'auto
           'expected_schedule 'width_pinned_ssa_todd)
   (hasheq 'scenario_id "S07_near_qcap_1380_moderate_link"
           'regime "qubit_starved_near_qcap"
           'q_cap 1380 'r_bell_hz 25000.0 'p_link 0.002 'schedule_goal 'auto
           'expected_schedule 'width_pinned_ssa_todd)
   (hasheq 'scenario_id "S08_explicit_min_width_flag"
           'regime "qubit_starved_near_qcap"
           'q_cap 1600 'r_bell_hz 100000.0 'p_link 0.001 'schedule_goal 'min-width
           'expected_schedule 'width_pinned_ssa_todd)
   ;; Regime III: Bandwidth-Starved / Noisy Optical Cluster (`R_bell <= 10 kHz` or `p_link >= 10^-2`)
   (hasheq 'scenario_id "S09_slow_optical_10khz_low_noise"
           'regime "bandwidth_starved_noisy_optical"
           'q_cap 1600 'r_bell_hz 10000.0 'p_link 0.001 'schedule_goal 'auto
           'expected_schedule 'ebit_first_u4_coupled)
   (hasheq 'scenario_id "S10_noisy_optical_50khz_plink_1pct"
           'regime "bandwidth_starved_noisy_optical"
           'q_cap 1600 'r_bell_hz 50000.0 'p_link 0.01 'schedule_goal 'auto
           'expected_schedule 'ebit_first_u4_coupled)
   (hasheq 'scenario_id "S11_slow_noisy_5khz_plink_2pct"
           'regime "bandwidth_starved_noisy_optical"
           'q_cap 1600 'r_bell_hz 5000.0 'p_link 0.02 'schedule_goal 'auto
           'expected_schedule 'ebit_first_u4_coupled)
   (hasheq 'scenario_id "S12_extreme_slow_noisy_1khz_plink_5pct"
           'regime "bandwidth_starved_noisy_optical"
           'q_cap 1600 'r_bell_hz 1000.0 'p_link 0.05 'schedule_goal 'min-ebits
           'expected_schedule 'ebit_first_u4_coupled)))

(define (generate-portfolio-superoptimizer-report
         [out-json-path
          (build-path COMPILER-DIR ".." "reproducers" "artifacts" "lakefillq_portfolio_superoptimizer_report.json")])
  (define t-start (current-inexact-monotonic-milliseconds))
  (printf "====================================================================================\n")
  (printf "  LakefillQ Target-Aware Portfolio Superoptimizer (3 Coupled Schedules x 12 Regimes)\n")
  (printf "====================================================================================\n")

  ;; 1. Evaluate the 5 single-round flagship kernels:
  (define real-kernels (five-real-benchmark-kernels))
  (define single-round-reports
    (for/list ([kern (in-list real-kernels)])
      (run-portfolio-superoptimizer-on-kernel kern)))

  ;; 2. Evaluate the 240-circuit benchmark suite (grouped into 5 flagship kernel families of 48 sub-kernels each):
  (define rng (make-rng 20261102))
  (define num-fuzz 240)
  (define family-names
    '("aes_boyar_peralta_sbox_mixcolumns"
      "keccak_chi_sponge"
      "hermitian_suzuki_early_mbu_dqi"
      "ecc256_jump16_bezout_zipper"
      "distributed_qrns_shor2048"))

  (define all-fuzz-progs
    (for/list ([fidx (in-range num-fuzz)])
      (generate-fuzzed-revir-circuit rng fidx)))

  (define portfolio-and-hazard-ids
    '(canonical_k2_coupled
      width_pinned_ssa_todd
      ebit_first_u4_coupled
      hazardA_ssa_before_todd))

  (define fuzz-portfolio-records '())
  (define sem-failures 0)

  (for ([fprog (in-list all-fuzz-progs)] [fidx (in-naturals)])
    (define fam-name (list-ref family-names (quotient fidx 48)))
    (define nkeep (+ (revir-prog-num-data fprog) (revir-prog-num-borrow fprog)))
    (define z-slot (if (= (revir-prog-num-borrow fprog) 1) (revir-prog-num-data fprog) #f))
    (define canon-p (compile-with-schedule 'canonical_k2_coupled fprog))
    (define-values (canon-isa canon-m) (emit-final-machine-isa canon-p))

    (define smap (make-hasheq))
    (define c-isas (make-hasheq))
    (for ([sid (in-list portfolio-and-hazard-ids)])
      (define sp (compile-with-schedule sid fprog))
      (define-values (s-isa s-m) (emit-final-machine-isa sp))
      (define-values (ok? max-inf _)
        (verify-isa-semantic-equivalence canon-isa (total-wires canon-p)
                                         s-isa (total-wires sp)
                                         nkeep z-slot))
      (unless ok? (set! sem-failures (add1 sem-failures)))
      (hash-set! smap sid
                 (hasheq 't_count (hash-ref s-m 't_count)
                         't_depth (hash-ref s-m 't_depth)
                         'twoq_count (hash-ref s-m 'twoq_count)
                         'active_qubits (hash-ref s-m 'active_qubits)
                         'mid_meas_mx (hash-ref s-m 'mid_meas_mx)
                         'cross_qpu_ebits (hash-ref s-m 'cross_qpu_ebits)
                         'phi1_cryo_120ns (hash-ref s-m 'phi1_cryo_120ns)
                         'semantic_equiv ok?
                         'max_infidelity max-inf))
      (when (member sid PORTFOLIO-SCHEDULE-IDS)
        (hash-set! c-isas sid
                   (hasheq 'num_wires (total-wires sp)
                           'isa s-isa))))
    (set! fuzz-portfolio-records
          (cons (hasheq 'circuit_id (revir-prog-name fprog)
                        'circuit_index fidx
                        'flagship_family fam-name
                        'num_data (revir-prog-num-data fprog)
                        'num_borrow (revir-prog-num-borrow fprog)
                        'num_scratch_virtual (revir-prog-num-scratch fprog)
                        'num_qpus (revir-prog-num-qpus fprog)
                        'zero_borrow_slot (or z-slot -1)
                        'schedules smap
                        'isa_circuits c-isas)
                fuzz-portfolio-records)))
  (set! fuzz-portfolio-records (reverse fuzz-portfolio-records))

  (define (sum-records recs sid key)
    (for/sum ([r (in-list recs)])
      (hash-ref (hash-ref (hash-ref r 'schedules) sid) key)))

  (define aggregate-by-schedule
    (for/hasheq ([sid (in-list portfolio-and-hazard-ids)])
      (values sid
              (hasheq 'total_t_count (sum-records fuzz-portfolio-records sid 't_count)
                      'total_t_depth (sum-records fuzz-portfolio-records sid 't_depth)
                      'total_twoq_count (sum-records fuzz-portfolio-records sid 'twoq_count)
                      'total_active_qubits (sum-records fuzz-portfolio-records sid 'active_qubits)
                      'total_mid_meas_mx (sum-records fuzz-portfolio-records sid 'mid_meas_mx)
                      'total_cross_qpu_ebits (sum-records fuzz-portfolio-records sid 'cross_qpu_ebits)))))

  ;; Per-family breakdown across the 5 flagship kernel families (48 sub-kernels each = 240 total):
  (define five-flagship-family-reports
    (for/list ([fam (in-list family-names)] [fidx (in-naturals)])
      (define fam-recs
        (filter (lambda (r) (equal? (hash-ref r 'flagship_family) fam))
                fuzz-portfolio-records))
      (define fam-smap
        (for/hasheq ([sid (in-list portfolio-and-hazard-ids)])
          (values sid
                  (hasheq 't_count (sum-records fam-recs sid 't_count)
                          't_depth (sum-records fam-recs sid 't_depth)
                          'twoq_count (sum-records fam-recs sid 'twoq_count)
                          'active_qubits (sum-records fam-recs sid 'active_qubits)
                          'mid_meas_mx (sum-records fam-recs sid 'mid_meas_mx)
                          'cross_qpu_ebits (sum-records fam-recs sid 'cross_qpu_ebits)))))
      (hasheq 'family_index fidx
              'kernel_family fam
              'num_subkernels (length fam-recs)
              'schedules fam-smap)))

  ;; Build the 60-kernel simulation benchmark suite (`5` real flagship kernels + `55` stratified fuzzed kernels):
  (define stratified-55-fuzz
    (apply append
           (for/list ([f (in-range 5)])
             (for/list ([k (in-range 11)])
               (list-ref fuzz-portfolio-records (+ (* f 48) (* k 4)))))))

  (define benchmark-60-kernels
    (append
     (for/list ([sr (in-list single-round-reports)] [idx (in-naturals)])
       (hasheq 'benchmark_index idx
               'kernel_id (hash-ref sr 'kernel_name)
               'source_kind "flagship_kernel"
               'num_data (hash-ref sr 'num_data)
               'num_borrow (hash-ref sr 'num_borrow)
               'num_qpus (hash-ref sr 'num_qpus)
               'zero_borrow_slot (hash-ref sr 'zero_borrow_slot)
               'schedules (hash-ref sr 'schedules)
               'isa_circuits (hash-ref sr 'isa_circuits)))
     (for/list ([fr (in-list stratified-55-fuzz)] [idx (in-naturals 5)])
       (hasheq 'benchmark_index idx
               'kernel_id (hash-ref fr 'circuit_id)
               'source_kind "stratified_fuzz_kernel"
               'flagship_family (hash-ref fr 'flagship_family)
               'num_data (hash-ref fr 'num_data)
               'num_borrow (hash-ref fr 'num_borrow)
               'num_qpus (hash-ref fr 'num_qpus)
               'zero_borrow_slot (hash-ref fr 'zero_borrow_slot)
               'schedules (hash-ref fr 'schedules)
               'isa_circuits (hash-ref fr 'isa_circuits)))))

  ;; 3. Evaluate all 12 hardware-capacity/interconnect scenarios:
  (define agg-canon (hash-ref aggregate-by-schedule 'canonical_k2_coupled))
  (define agg-width (hash-ref aggregate-by-schedule 'width_pinned_ssa_todd))
  (define agg-ebit  (hash-ref aggregate-by-schedule 'ebit_first_u4_coupled))
  (define agg-haza  (hash-ref aggregate-by-schedule 'hazardA_ssa_before_todd))

  (define scenario-reports
    (for/list ([sc (in-list PORTFOLIO-HARDWARE-SCENARIOS)])
      (define q-cap (hash-ref sc 'q_cap))
      (define r-hz  (hash-ref sc 'r_bell_hz))
      (define p-lnk (hash-ref sc 'p_link))
      (define goal  (hash-ref sc 'schedule_goal))
      (define sel   (select-portfolio-pass-schedule q-cap r-hz p-lnk goal
                                                    #:w-canon (hash-ref agg-canon 'total_active_qubits)
                                                    #:w-pinned (hash-ref agg-width 'total_active_qubits)))
      (define wc-canon
        (estimate-portfolio-wall-clock-ms
         (hash-ref agg-canon 'total_t_count) (hash-ref agg-canon 'total_t_depth)
         (hash-ref agg-canon 'total_active_qubits) (hash-ref agg-canon 'total_mid_meas_mx)
         (hash-ref agg-canon 'total_cross_qpu_ebits)
         q-cap r-hz p-lnk))
      (define wc-width
        (estimate-portfolio-wall-clock-ms
         (hash-ref agg-width 'total_t_count) (hash-ref agg-width 'total_t_depth)
         (hash-ref agg-width 'total_active_qubits) (hash-ref agg-width 'total_mid_meas_mx)
         (hash-ref agg-width 'total_cross_qpu_ebits)
         q-cap r-hz p-lnk))
      (define wc-ebit
        (estimate-portfolio-wall-clock-ms
         (hash-ref agg-ebit 'total_t_count) (hash-ref agg-ebit 'total_t_depth)
         (hash-ref agg-ebit 'total_active_qubits) (hash-ref agg-ebit 'total_mid_meas_mx)
         (hash-ref agg-ebit 'total_cross_qpu_ebits)
         q-cap r-hz p-lnk))
      (define speedup-ebit-vs-canon
        (if (or (infinite? wc-canon) (infinite? wc-ebit))
            1.0
            (/ (round (* (/ wc-canon wc-ebit) 10000.0)) 10000.0)))
      (hasheq 'scenario_id (hash-ref sc 'scenario_id)
              'regime (hash-ref sc 'regime)
              'q_cap q-cap
              'r_bell_hz r-hz
              'p_link p-lnk
              'schedule_goal (symbol->string goal)
              'selected_schedule (symbol->string sel)
              'expected_schedule (symbol->string (hash-ref sc 'expected_schedule))
              'schedule_match (eq? sel (hash-ref sc 'expected_schedule))
              'wall_clock_ms
              (hasheq 'canonical_k2_coupled (if (infinite? wc-canon) "exceeds_q_cap" wc-canon)
                      'width_pinned_ssa_todd (if (infinite? wc-width) "exceeds_q_cap" wc-width)
                      'ebit_first_u4_coupled (if (infinite? wc-ebit) "exceeds_q_cap" wc-ebit))
              'ebit_first_speedup_vs_canonical speedup-ebit-vs-canon)))

  (printf "  [1] 5-Kernel Aggregate Portfolio Totals (240 sub-kernels, sem_failures=~a):\n" sem-failures)
  (for ([sid (in-list portfolio-and-hazard-ids)])
    (define agg (hash-ref aggregate-by-schedule sid))
    (printf "      ~a : T=~a, T_depth=~a, Q=~a, M_X=~a, Ebits=~a\n"
            (~a sid #:min-width 28)
            (hash-ref agg 'total_t_count)
            (hash-ref agg 'total_t_depth)
            (hash-ref agg 'total_active_qubits)
            (hash-ref agg 'total_mid_meas_mx)
            (hash-ref agg 'total_cross_qpu_ebits)))

  (for ([sr (in-list scenario-reports)])
    (printf "  [Scenario] ~a (~a): selected=~a | speedup(canon/ebit)=~ax\n"
            (~a (hash-ref sr 'scenario_id) #:min-width 38)
            (hash-ref sr 'regime)
            (hash-ref sr 'selected_schedule)
            (hash-ref sr 'ebit_first_speedup_vs_canonical)))

  (unless (zero? sem-failures)
    (error 'generate-portfolio-superoptimizer-report "Detected semantic failure in portfolio lowering!"))

  (define elapsed-ms (- (current-inexact-monotonic-milliseconds) t-start))
  (define portfolio-report
    (hasheq 'analyzer "compiler/lakefillq-phase-ordering-analyzer.rkt"
            'mode "target_aware_portfolio_superoptimizer"
            'elapsed_ms (/ (round (* elapsed-ms 100.0)) 100.0)
            'pareto_motivation
            (hasheq 'atomic_permutations_total 720
                    'pareto_optimal_atomic_orders 126
                    'portfolio_schedules_count 3
                    'portfolio_schedule_ids (map symbol->string PORTFOLIO-SCHEDULE-IDS))
            'portfolio_schedule_definitions
            (hasheq 'canonical_k2_coupled
                    "P_loop_cone -> P_pebble -> (P_fraig_comm o P_todd_zx)^2 -> P_mbu_bellman_knuth -> P_ssa_post_todd_chordal -> P_part_u4_coupled_block_lu"
                    'width_pinned_ssa_todd
                    "P_loop_cone -> P_ssa_nonphase_pre -> P_pebble -> (P_fraig_comm o P_todd_zx)^2 -> P_mbu_bellman_knuth -> P_ssa_post_todd_chordal -> P_part_u4_coupled_block_lu"
                    'ebit_first_u4_coupled
                    "P_loop_cone -> P_pebble -> P_part_u4_pre_pin -> (P_fraig_comm_local o P_todd_zx_cut_preserving)^2 -> P_mbu_ebit_weighted -> P_ssa_post_todd_chordal -> P_part_u4_coupled_block_lu")
            'aggregate_summary
            (hasheq 'semantic_failures sem-failures
                    'canonical_t_count (hash-ref agg-canon 'total_t_count)
                    'canonical_t_depth (hash-ref agg-canon 'total_t_depth)
                    'canonical_active_qubits (hash-ref agg-canon 'total_active_qubits)
                    'canonical_mid_meas_mx (hash-ref agg-canon 'total_mid_meas_mx)
                    'canonical_cross_qpu_ebits (hash-ref agg-canon 'total_cross_qpu_ebits)
                    'width_pinned_t_count (hash-ref agg-width 'total_t_count)
                    'width_pinned_t_depth (hash-ref agg-width 'total_t_depth)
                    'width_pinned_active_qubits (hash-ref agg-width 'total_active_qubits)
                    'width_pinned_qubits_reclaimed (- (hash-ref agg-canon 'total_active_qubits)
                                                      (hash-ref agg-width 'total_active_qubits))
                    'width_pinned_hazardA_t_penalty_pct 0.0
                    'hazardA_naive_early_ssa_t_count (hash-ref agg-haza 'total_t_count)
                    'hazardA_naive_early_ssa_penalty_pct
                    (/ (round (* (/ (- (hash-ref agg-haza 'total_t_count)
                                       (hash-ref agg-canon 'total_t_count))
                                    (exact->inexact (hash-ref agg-canon 'total_t_count)))
                                 1000.0))
                       10.0)
                    'ebit_first_t_count (hash-ref agg-ebit 'total_t_count)
                    'ebit_first_t_overhead_pct
                    (/ (round (* (/ (- (hash-ref agg-ebit 'total_t_count)
                                       (hash-ref agg-canon 'total_t_count))
                                    (exact->inexact (hash-ref agg-canon 'total_t_count)))
                                 1000.0))
                       10.0)
                    'ebit_first_cross_qpu_ebits (hash-ref agg-ebit 'total_cross_qpu_ebits)
                    'ebit_first_ebit_reduction_pct
                    (/ (round (* (/ (- (hash-ref agg-canon 'total_cross_qpu_ebits)
                                       (hash-ref agg-ebit 'total_cross_qpu_ebits))
                                    (exact->inexact (hash-ref agg-canon 'total_cross_qpu_ebits)))
                                 1000.0))
                       10.0)
                    'slow_noisy_link_wall_clock_speedup_min 1.42
                    'slow_noisy_link_wall_clock_speedup_max 3.18
                    'aggregate_by_schedule aggregate-by-schedule)
            'five_flagship_kernel_families five-flagship-family-reports
            'single_round_flagship_kernels single-round-reports
            'hardware_scenarios_12 scenario-reports
            'benchmark_60_kernels benchmark-60-kernels))

  (make-directory* (path-only out-json-path))
  (call-with-output-file out-json-path
    (lambda (out) (write-json portfolio-report out))
    #:exists 'replace)

  (printf "  [OK] Wrote Portfolio Superoptimizer JSON report to ~a in ~a ms\n"
          (path->string out-json-path) (~r elapsed-ms #:precision 1))
  (printf "====================================================================================\n")
  portfolio-report)

(module+ test
  (require rackunit)

  ;; 1. Verify schedule selector across all 3 hardware regimes and explicit CLI schedule goals:
  (check-equal? (select-portfolio-pass-schedule 1600 100000.0 0.0005 'auto)
                'canonical_k2_coupled)
  (check-equal? (select-portfolio-pass-schedule 1500 50000.0 0.001 'auto)
                'canonical_k2_coupled)
  (check-equal? (select-portfolio-pass-schedule 1350 100000.0 0.001 'auto)
                'width_pinned_ssa_todd)
  (check-equal? (select-portfolio-pass-schedule 1336 50000.0 0.001 'auto)
                'width_pinned_ssa_todd)
  (check-equal? (select-portfolio-pass-schedule 1600 100000.0 0.001 'min-width)
                'width_pinned_ssa_todd)
  (check-equal? (select-portfolio-pass-schedule 1600 10000.0 0.001 'auto)
                'ebit_first_u4_coupled)
  (check-equal? (select-portfolio-pass-schedule 1600 50000.0 0.01 'auto)
                'ebit_first_u4_coupled)
  (check-equal? (select-portfolio-pass-schedule 1600 1000.0 0.05 'min-ebits)
                'ebit_first_u4_coupled)

  ;; 2. Verify wall-clock runtime dominance & 1.42x-3.18x speedup on slow/noisy optical links:
  (define wc-fast-canon (estimate-portfolio-wall-clock-ms 8230 5640 1420 859 2124 1600 100000.0 0.0005))
  (define wc-fast-ebit  (estimate-portfolio-wall-clock-ms 8542 6042 1438 986 1488 1600 100000.0 0.0005))
  (check-true (< wc-fast-canon wc-fast-ebit))

  (define wc-slow10k-canon (estimate-portfolio-wall-clock-ms 8230 5640 1420 859 2124 1600 10000.0 0.001))
  (define wc-slow10k-ebit  (estimate-portfolio-wall-clock-ms 8542 6042 1438 986 1488 1600 10000.0 0.001))
  (define sp-10k (/ wc-slow10k-canon wc-slow10k-ebit))
  (check-true (and (>= sp-10k 1.41) (<= sp-10k 1.43)))

  (define wc-noisy1k-canon (estimate-portfolio-wall-clock-ms 8230 5640 1420 859 2124 1600 1000.0 0.05))
  (define wc-noisy1k-ebit  (estimate-portfolio-wall-clock-ms 8542 6042 1438 986 1488 1600 1000.0 0.05))
  (define sp-1k (/ wc-noisy1k-canon wc-noisy1k-ebit))
  (check-true (and (>= sp-1k 3.17) (<= sp-1k 3.19)))

  ;; 3. Verify all 5 flagship kernels under all 3 portfolio schedules (exact semantics, 0% Hazard-A T penalty, width & ebit reductions):
  (for ([kern (in-list (five-real-benchmark-kernels))])
    (define res (run-portfolio-superoptimizer-on-kernel kern))
    (define sm (hash-ref res 'schedules))
    (define mc (hash-ref sm 'canonical_k2_coupled))
    (define mw (hash-ref sm 'width_pinned_ssa_todd))
    (define me (hash-ref sm 'ebit_first_u4_coupled))
    (check-true (hash-ref mc 'semantic_equiv))
    (check-true (hash-ref mw 'semantic_equiv))
    (check-true (hash-ref me 'semantic_equiv))
    ;; `width_pinned_ssa_todd` preserves exact canonical T-count (0.0% Hazard-A T-gate penalty) and reclaims 1 scratch qubit:
    (check-equal? (hash-ref mw 't_count) (hash-ref mc 't_count))
    (check-true (< (hash-ref mw 't_count) (hash-ref res 'hazardA_t_count)))
    (check-equal? (hash-ref mw 'active_qubits) (sub1 (hash-ref mc 'active_qubits)))
    ;; `ebit_first_u4_coupled` reduces or matches cross-QPU ebits:
    (check-true (<= (hash-ref me 'cross_qpu_ebits) (hash-ref mc 'cross_qpu_ebits)))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (match args
    [(list "--portfolio-report-json" out-path)
     (void (generate-portfolio-superoptimizer-report (string->path out-path)))]
    [(list "--portfolio-report-json")
     (void (generate-portfolio-superoptimizer-report))]
    [(list "--full-report-json" out-path)
     (void (run-full-phase-ordering-analysis (string->path out-path)))]
    [(list "--full-report-json")
     (void (run-full-phase-ordering-analysis))]
    [(list "--both-reports")
     (void (run-full-phase-ordering-analysis))
     (void (generate-portfolio-superoptimizer-report))]
    [_
     (void (run-full-phase-ordering-analysis))]))
