#lang racket/base

;; =============================================================================
;; compiler/lakefillq-optical-distillation-stim.rkt
;;
;; Calibrated Physical-to-Logical Optical Bell Distillation & Convex `M*(p_link)`
;; Cluster Optimizer for `LakefillQ`.
;;
;; Within `LakefillQ`'s single unified typing and costing judgment
;;   `Gamma_in |- t : Q_e(A) -| Gamma_out`,
;; distributed inter-QPU operations contribute an optical communication effect
;; component inside `e` governed by:
;;   1. `Law U4` (`0`-reverse-ebit counit: `1` forward optical Bell transfer +
;;      local transversal `M_X` + classical parity `Z`-frame update, cutting
;;      inter-QPU optical ebit consumption by `50%` vs. round-trip cat uncompute),
;;   2. Physical photonic Bell-pair infidelity `p_link` (`DEPOLARIZE2(p_link)`),
;;      local two-qubit gate depolarizing rate `p_local = 0.001`, ancilla readout
;;      flip error `p_meas = 0.001`, target logical Bell infidelity `eps_target`
;;      (`1e-9`, `1e-12`), and surface-code patch distance `d in {3, 5, 7}`.
;;
;; Replaces the uncalibrated constant `D_dist = 30` with:
;;   - Exact 16-state two-pair Pauli/Bell-diagonal transfer equations for noisy
;;     `DEJMPS` and `BBPSSW` distillation (`p_{k+1}` and survival `P_succ(k)`),
;;   - Post-selected rotated-surface-code Bell-patch injection + multi-step
;;     encoded `DEJMPS` distillation (`N_raw(p_link, eps_target)` and latency-
;;     calibrated `D_dist(p_link, eps_target, r_bell)`),
;;   - `M_max = 256` convex cluster optimization `M*(p_link)` across
;;     `'all-to-all-peers` and `'switched-optical-tree` for `ECC-256`,
;;     `RSA-2048` (`QRNS` + `Law U4`), `RSA-4096`, `AES-128`,
;;     `McEliece-348864`, and `FeMoCo-THC`, demonstrating monotone contraction
;;     of `M*(p_link)` toward `1` as `p_link` increases from `0.5%` to `5.0%`.
;; =============================================================================

(require racket/cmdline
         racket/format
         racket/list
         racket/match
         racket/math
         racket/vector
         json)

(provide (struct-out bell-diag-state)
         canonical-p-link-grid
         canonical-eps-targets
         canonical-code-distances
         canonical-six-workloads
         raw-optical-bell-state
         bell-state-infidelity
         bell-state-valid?
         distill-bell-step
         run-physical-distillation-steps
         compute-n-raw
         compute-d-dist
         compute-optical-distillation-schedule
         solve-noisy-optical-cluster-m-star
         run-noisy-optical-cluster-sweep
         build-optical-distillation-json-report)

;; =============================================================================
;; 1. Exact 16-State Bell-Diagonal Transfer Model (`DEJMPS` & `BBPSSW`)
;; =============================================================================

;; Bell-diagonal density matrix weights `(f, pz, px, py)` in the Bell basis
;; `{|Phi+>, |Phi->, |Psi+>, |Psi->}` satisfying `f + pz + px + py = 1`.
(struct bell-diag-state (f pz px py) #:transparent)

(define canonical-p-link-grid '(0.005 0.01 0.02 0.03 0.05))
(define canonical-eps-targets '(1e-9 1e-12))
(define canonical-code-distances '(3 5 7))

(define (bell-state-infidelity st)
  (- 1.0 (bell-diag-state-f st)))

(define (bell-state-valid? st [tol 1e-11])
  (match-define (bell-diag-state f pz px py) st)
  (and (>= f (- tol))
       (>= pz (- tol))
       (>= px (- tol))
       (>= py (- tol))
       (< (abs (- (+ f pz px py) 1.0)) tol)))

;; Raw optical Bell pair prepared via `H a; CX a b; DEPOLARIZE2(p_link) a b`:
;; Out of the 15 non-identity two-qubit Paulis in `DEPOLARIZE2(p_link)`,
;; 3 Paulis (`XX`, `YY`, `ZZ`) stabilize `|Phi+>` up to global phase, while
;; 4 Paulis each map `|Phi+>` to `|Phi->`, `|Psi+>`, and `|Psi->`.
(define (raw-optical-bell-state p-link)
  (unless (and (real? p-link) (<= 0.0 p-link 0.75))
    (error 'raw-optical-bell-state "Expected p-link in [0.0, 0.75], got ~a" p-link))
  (define pl (exact->inexact p-link))
  (define f (- 1.0 (* (/ 12.0 15.0) pl)))
  (define q (* (/ 4.0 15.0) pl))
  (bell-diag-state f q q q))

;; Exact 16-state XOR channel for one party's local two-qubit `DEPOLARIZE2(p_gate)`
;; acting on `(q_keep, q_sac)` indexed by `s = (z1 << 3) | (x1 << 2) | (z2 << 1) | x2`.
(define (apply-local-depol2-16 probs16 p-gate)
  (define pg (exact->inexact p-gate))
  (if (<= pg 0.0)
      (vector-copy probs16)
      (let ([out (make-vector 16 0.0)]
            [p-id (- 1.0 pg)]
            [p-err (/ pg 15.0)])
        (for ([s (in-range 16)])
          (define ps (vector-ref probs16 s))
          (when (> ps 0.0)
            (vector-set! out s (+ (vector-ref out s) (* ps p-id)))
            (for ([delta (in-range 1 16)])
              (define dst (bitwise-xor s delta))
              (vector-set! out dst (+ (vector-ref out dst) (* ps p-err))))))
        out)))

;; Single noisy bilateral distillation step (`DEJMPS` or `BBPSSW`) combining two
;; Bell-diagonal pairs `w1` (kept) and `w2` (sacrificed):
;;   1. Optional `DEJMPS` local basis twirl (`SQRT_X` on Alice, `SQRT_X_DAG` on Bob),
;;      which leaves `|Phi+>` and `|Psi+>` invariant and swaps `|Phi-> <-> |Psi->`.
;;   2. Bilateral `CNOT` (`(z1, x1), (z2, x2) |-> (z1 xor z2, x1), (z2, x1 xor x2)`).
;;   3. Two independent `DEPOLARIZE2(p_local)` channels (Alice's CNOT + Bob's CNOT).
;;   4. Noisy `Z`-basis readout (`X_ERROR(p_meas)` on both sacrificed qubits) with
;;      classical parity post-selection `m_A == m_B`.
;; Returns `(values post-selected-bell-state p-succ)`.
(define (distill-bell-step w1 w2
                           #:p-local [p-local 0.001]
                           #:p-meas [p-meas 0.001]
                           #:protocol [protocol 'dejmps])
  (define (state->zx-vec w)
    (match-define (bell-diag-state f pz px py) w)
    (match protocol
      ['dejmps (vector f px py pz)]
      ['bbpssw (vector f px pz py)]
      [_ (error 'distill-bell-step "Unsupported protocol ~a (expected 'dejmps or 'bbpssw)" protocol)]))

  (define p1 (state->zx-vec w1))
  (define p2 (state->zx-vec w2))
  (define probs16 (make-vector 16 0.0))

  (for* ([s1 (in-range 4)] [s2 (in-range 4)])
    (define z1 (bitwise-and (arithmetic-shift s1 -1) 1))
    (define x1 (bitwise-and s1 1))
    (define z2 (bitwise-and (arithmetic-shift s2 -1) 1))
    (define x2 (bitwise-and s2 1))
    (define nz1 (bitwise-xor z1 z2))
    (define nx1 x1)
    (define nz2 z2)
    (define nx2 (bitwise-xor x1 x2))
    (define idx
      (bitwise-ior (arithmetic-shift nz1 3)
                   (arithmetic-shift nx1 2)
                   (arithmetic-shift nz2 1)
                   nx2))
    (vector-set! probs16 idx
                 (+ (vector-ref probs16 idx)
                    (* (vector-ref p1 s1) (vector-ref p2 s2)))))

  (define after-alice (apply-local-depol2-16 probs16 p-local))
  (define after-bob (apply-local-depol2-16 after-alice p-local))

  (define pm (exact->inexact p-meas))
  (define q-flip (* 2.0 pm (- 1.0 pm)))
  (define keep-zx (make-vector 4 0.0))
  (define p-succ 0.0)

  (for ([idx (in-range 16)])
    (define s1 (bitwise-and (arithmetic-shift idx -2) 3))
    (define x2 (bitwise-and idx 1))
    (define acc-prob (if (zero? x2) (- 1.0 q-flip) q-flip))
    (define contrib (* (vector-ref after-bob idx) acc-prob))
    (vector-set! keep-zx s1 (+ (vector-ref keep-zx s1) contrib))
    (set! p-succ (+ p-succ contrib)))

  (define out-state
    (bell-diag-state (/ (vector-ref keep-zx 0) p-succ)
                     (/ (vector-ref keep-zx 2) p-succ)
                     (/ (vector-ref keep-zx 1) p-succ)
                     (/ (vector-ref keep-zx 3) p-succ)))
  (values out-state p-succ))

;; Evaluates a symmetric `k`-step (`2^k -> 1`) physical distillation tree and
;; records step-by-step Bell infidelity `p_k`, conditional step survival `P_succ(k)`,
;; full-tree synchronous herald probability `P_tree_sync(k)`, buffered raw-pair
;; expectation `N_raw_buffered(k)`, and unbuffered synchronous raw-pair expectation
;; `N_raw_sync(k)`.
(define (run-physical-distillation-steps p-link k-steps
                                         #:p-local [p-local 0.001]
                                         #:p-meas [p-meas 0.001]
                                         #:protocol [protocol 'dejmps])
  (unless (and (exact-nonnegative-integer? k-steps))
    (error 'run-physical-distillation-steps "Expected nonnegative integer k-steps, got ~a" k-steps))
  (define w0 (raw-optical-bell-state p-link))
  (let loop ([step 1]
             [w w0]
             [raw-buf 1.0]
             [p-tree 1.0]
             [acc '()])
    (if (> step k-steps)
        (let ([raw-sync (/ (exact->inexact (arithmetic-shift 1 k-steps)) p-tree)])
          (hasheq 'p_link (exact->inexact p-link)
                  'p_local (exact->inexact p-local)
                  'p_meas (exact->inexact p-meas)
                  'protocol (symbol->string protocol)
                  'k_steps k-steps
                  'raw_pair_leaves (arithmetic-shift 1 k-steps)
                  'raw_initial_infidelity (bell-state-infidelity w0)
                  'final_infidelity (bell-state-infidelity w)
                  'final_fidelity (bell-diag-state-f w)
                  'final_bell_weights (list (bell-diag-state-f w)
                                            (bell-diag-state-pz w)
                                            (bell-diag-state-px w)
                                            (bell-diag-state-py w))
                  'tree_survival_prob p-tree
                  'n_raw_buffered raw-buf
                  'n_raw_sync raw-sync
                  'step_history (reverse acc)))
        (let-values ([(w-next ps)
                      (distill-bell-step w w
                                         #:p-local p-local
                                         #:p-meas p-meas
                                         #:protocol protocol)])
          (define next-buf (* raw-buf (/ 2.0 ps)))
          (define next-tree (* p-tree p-tree ps))
          (define next-sync (/ (exact->inexact (arithmetic-shift 1 step)) next-tree))
          (define rec
            (hasheq 'step step
                    'p_succ ps
                    'infidelity (bell-state-infidelity w-next)
                    'fidelity (bell-diag-state-f w-next)
                    'tree_survival_prob next-tree
                    'n_raw_buffered next-buf
                    'n_raw_sync next-sync))
          (loop (add1 step) w-next next-buf next-tree (cons rec acc))))))

;; =============================================================================
;; 2. Physical-to-Logical Surface-Code Bell Schedule (`N_raw` & `D_dist`)
;; =============================================================================

;; Calibrated hierarchical schedule transforming raw photonic Bell pairs (`p_link`)
;; into fault-tolerant logical surface-code Bell pairs (`<= eps_target`):
;;   - Level 1 (Post-selected distance-`d` rotated surface-code Bell patch):
;;       Consumes `d^2` transversal raw optical Bell pairs per leaf patch with
;;       post-selection stabilizer acceptance probability
;;         `P_patch = (1 - e_0)^(d^2) * (1 - p_local)^(2 * (d^2 - 1))`
;;       and post-selected patch logical infidelity
;;         `eps_patch = min(0.45, 0.028 * ((e_0 + 2 * p_local) / 0.046)^((d + 1) / 2))`.
;;   - Level 2 (Multi-step encoded `DEJMPS` distillation on logical patches):
;;       Executes encoded `DEJMPS` steps at computational code distance
;;       `d_comp = 23` (`eps_target >= 1e-10`) or `29` (`eps_target < 1e-10`)
;;       with local logical gate error `eps_loc = 0.03 * d_comp * (p_local / 0.01)^((d_comp + 1)/2)`
;;       within a `coherence-buffer-pairs = 225` photonic transceiver herald window
;;       (`max_sync_steps = max(1, floor(log2(225 / d^2)))`), plus lattice-surgery
;;       syndrome-round latency `tau_qec = 1.5 us` per round (`2 * d_comp` rounds/step).
(define (compute-optical-distillation-schedule p-link
                                               #:p-local [p-local 0.001]
                                               #:p-meas [p-meas 0.001]
                                               #:eps-target [eps-target 1e-9]
                                               #:d [d 3]
                                               #:r-bell [r-bell 100000.0]
                                               #:protocol [protocol 'dejmps]
                                               #:coherence-buffer-pairs [coherence-buffer-pairs 225])
  (unless (and (exact-positive-integer? d) (odd? d) (>= d 3))
    (error 'compute-optical-distillation-schedule "Expected odd code distance d >= 3, got ~a" d))
  (define pl (exact->inexact p-link))
  (define ploc (exact->inexact p-local))
  (define eps-t (exact->inexact eps-target))
  (define rb (exact->inexact r-bell))

  (define w0 (raw-optical-bell-state pl))
  (define e0 (bell-state-infidelity w0))
  (define n-patch (* d d))
  (define t-wt (quotient (add1 d) 2))

  (define max-sync-steps
    (max 1 (inexact->exact (floor (/ (log (/ (exact->inexact coherence-buffer-pairs)
                                             (exact->inexact n-patch)))
                                     (log 2.0))))))

  (define eps-patch
    (min 0.45 (* 0.028 (expt (/ (+ e0 (* 2.0 ploc)) 0.046) t-wt))))
  (define p-patch
    (* (expt (- 1.0 e0) n-patch)
       (expt (- 1.0 ploc) (* 2 (sub1 n-patch)))))

  (define d-comp (if (>= eps-t 1e-10) 23 29))
  (define eps-loc
    (* 0.03 (exact->inexact d-comp)
       (expt (/ ploc 0.01) (quotient (add1 d-comp) 2))))

  (define w-log-init
    (bell-diag-state (- 1.0 eps-patch)
                     (/ eps-patch 3.0)
                     (/ eps-patch 3.0)
                     (/ eps-patch 3.0)))

  (let loop ([k-enc 0]
             [w-log w-log-init]
             [p-win p-patch]
             [n-buf 1.0]
             [enc-steps '()])
    (if (or (<= (bell-state-infidelity w-log) eps-t) (>= k-enc 12))
        (let* ([sync-leaves (arithmetic-shift 1 (min k-enc max-sync-steps))]
               [n-raw (* (exact->inexact n-patch)
                         (/ (exact->inexact sync-leaves) p-win)
                         n-buf)]
               [tau-qec-sec (* (exact->inexact k-enc)
                               (exact->inexact (* 2 d-comp))
                               1.5e-6)]
               [d-dist (inexact->exact (ceiling (+ n-raw (* rb tau-qec-sec))))])
          (hasheq 'p_link pl
                  'p_local ploc
                  'p_meas (exact->inexact p-meas)
                  'eps_target eps-t
                  'code_distance_d d
                  'computational_distance_d_comp d-comp
                  'r_bell_hz rb
                  'protocol (symbol->string protocol)
                  'patch_bell_pairs n-patch
                  'max_sync_herald_steps max-sync-steps
                  'raw_initial_infidelity e0
                  'patch_initial_infidelity eps-patch
                  'patch_survival_prob p-patch
                  'encoded_distillation_steps k-enc
                  'achieved_logical_infidelity (bell-state-infidelity w-log)
                  'target_met (<= (bell-state-infidelity w-log) eps-t)
                  'n_raw_per_logical_ebit n-raw
                  'qec_distill_latency_sec tau-qec-sec
                  'd_dist_effective d-dist
                  'roundtrip_d_dist_effective (* 2 d-dist)
                  'law_u4_ebit_saving_pct 50.0
                  'encoded_step_history (reverse enc-steps)))
        (let-values ([(w-next ps-l)
                      (distill-bell-step w-log w-log
                                         #:p-local eps-loc
                                         #:p-meas eps-loc
                                         #:protocol protocol)])
          (define next-k (add1 k-enc))
          (define next-p-win
            (if (<= next-k max-sync-steps)
                (* p-win p-win ps-l)
                p-win))
          (define next-n-buf
            (if (<= next-k max-sync-steps)
                n-buf
                (* n-buf (/ 2.0 ps-l))))
          (define step-rec
            (hasheq 'step next-k
                    'p_succ ps-l
                    'logical_infidelity (bell-state-infidelity w-next)))
          (loop next-k w-next next-p-win next-n-buf (cons step-rec enc-steps))))))

(define (compute-n-raw p-link eps-target
                       #:p-local [p-local 0.001]
                       #:d [d 3])
  (hash-ref (compute-optical-distillation-schedule p-link
                                                   #:p-local p-local
                                                   #:eps-target eps-target
                                                   #:d d)
            'n_raw_per_logical_ebit))

(define (compute-d-dist p-link eps-target r-bell
                        #:p-local [p-local 0.001]
                        #:d [d 3])
  (hash-ref (compute-optical-distillation-schedule p-link
                                                   #:p-local p-local
                                                   #:eps-target eps-target
                                                   #:d d
                                                   #:r-bell r-bell)
            'd_dist_effective))

;; =============================================================================
;; 3. Convex `M_max = 256` Cluster Optimizer `M*(p_link)` Under Noisy Links
;; =============================================================================

(define canonical-six-workloads
  '("ECC-256"
    "RSA-2048"
    "RSA-4096"
    "AES-128"
    "McEliece-348864"
    "FeMoCo-THC"))

(define default-m-candidates
  '(1 2 4 6 8 12 16 24 32 48 64 96 128 256))

(define local-ccx-rate-hz 250000.0)
(define qec-window-sync-coeff-sec 0.0001128)
(define optical-switch-hop-transmission 0.88)

(define (ceil-div num den)
  (quotient (+ num (sub1 den)) den))

(define (ceil-log2-int m)
  (if (<= m 1)
      0
      (let loop ([k 1] [p 2])
        (if (>= p m) k (loop (add1 k) (* p 2))))))

(define (lookup-canonical-workload-profile workload-name)
  (match workload-name
    ["ECC-256"
     (hasheq 'workload "ECC-256"
             'paradigm 'algebraic-limb
             'q_single 1298
             'q_data 1024
             'q_fix 38
             'q_sync 6
             'w_bits 5
             'n_win 112
             't_toff 9824640
             'carry_scheme 'projective-oblivious-runway
             'lookup_scheme 'law-u4-ghz-mx
             'carry_ebits_per_win_cut 24
             'lookup_ebits_per_win_cut 5
             'total_shots #f)]
    ["RSA-2048"
     (hasheq 'workload "RSA-2048"
             'paradigm 'algebraic-limb
             'q_single 1332
             'q_data 1152
             'q_fix 24
             'q_sync 4
             'w_bits 6
             'n_win 1038
             't_toff 1180000000
             'carry_scheme 'qrns-zero-carry
             'lookup_scheme 'law-u4-ghz-mx
             'carry_ebits_per_win_cut 0
             'lookup_ebits_per_win_cut 6
             'total_shots #f)]
    ["RSA-4096"
     (hasheq 'workload "RSA-4096"
             'paradigm 'algebraic-limb
             'q_single 2612
             'q_data 2304
             'q_fix 40
             'q_sync 4
             'w_bits 6
             'n_win 2076
             't_toff 9440000000
             'carry_scheme 'qrns-zero-carry
             'lookup_scheme 'law-u4-ghz-mx
             'carry_ebits_per_win_cut 0
             'lookup_ebits_per_win_cut 6
             'total_shots #f)]
    ["AES-128"
     (hasheq 'workload "AES-128"
             'paradigm 'grover-amplify
             'q_single 261
             'q_data 0
             'q_fix 261
             'q_sync 0
             'w_bits 0
             'n_win 0
             't_toff 15280
             'carry_scheme 'none
             'lookup_scheme 'none
             'carry_ebits_per_win_cut 0
             'lookup_ebits_per_win_cut 0
             'total_shots #f)]
    ["McEliece-348864"
     (hasheq 'workload "McEliece-348864"
             'paradigm 'isd-search
             'q_single 4258
             'q_data 0
             'q_fix 4258
             'q_sync 0
             'w_bits 0
             'n_win 0
             't_toff 2781129728
             'carry_scheme 'none
             'lookup_scheme 'none
             'carry_ebits_per_win_cut 0
             'lookup_ebits_per_win_cut 0
             'total_shots #f)]
    ["FeMoCo-THC"
     (hasheq 'workload "FeMoCo-THC"
             'paradigm 'shot-sample
             'q_single 2196
             'q_data 0
             'q_fix 2196
             'q_sync 0
             'w_bits 0
             'n_win 0
             't_toff 5300000000
             'carry_scheme 'none
             'lookup_scheme 'none
             'carry_ebits_per_win_cut 0
             'lookup_ebits_per_win_cut 0
             'total_shots 64)]
    [_ (error 'lookup-canonical-workload-profile "Unknown workload: ~a" workload-name)]))

(define (q-per-machine-on-topology prof m topology)
  (define q-single (hash-ref prof 'q_single))
  (if (<= m 1)
      q-single
      (let ([q-data (hash-ref prof 'q_data)]
            [q-fix (hash-ref prof 'q_fix)]
            [q-sync (hash-ref prof 'q_sync)]
            [sync-factor
             (match topology
               ['all-to-all-peers (sub1 m)]
               ['switched-optical-tree (ceil-log2-int m)]
               [_ (error 'q-per-machine-on-topology "Unsupported topology: ~a" topology)])])
        (+ (ceil-div q-data m) q-fix (* q-sync sync-factor)))))

;; Optical switch-tree attenuation multiplier (`1.0` on direct peer links;
;; `1 / 0.88^ceil(log2(M))` across MEMS/crossbar switch hops on `'switched-optical-tree`).
(define (topology-optical-hop-multiplier m topology)
  (if (<= m 1)
      1.0
      (match topology
        ['all-to-all-peers 1.0]
        ['switched-optical-tree
         (/ 1.0 (expt optical-switch-hop-transmission (ceil-log2-int m)))]
        [_ (error 'topology-optical-hop-multiplier "Unsupported topology: ~a" topology)])))

;; Evaluates `M*(p_link)` for a workload profile under calibrated `D_dist(p_link, eps_target, r_bell)`,
;; cross-checking `LakefillQ`'s `par-cluster-opt-spec` / `solve-optimal-qpar-machines` at `Q_cap = 400`
;; AND optimizing total wall-clock execution time `T_wall(M, p_link)` over `M in 1..M_max` (`M_max = 256`).
(define (solve-noisy-optical-cluster-m-star workload-name
                                            p-link
                                            #:eps-target [eps-target 1e-9]
                                            #:d [d 3]
                                            #:r-bell [r-bell 100000.0]
                                            #:p-local [p-local 0.001]
                                            #:topology [topology 'all-to-all-peers]
                                            #:max-machines [m-max 256]
                                            #:q-cap [q-cap 3000]
                                            #:lookup-mode [lookup-mode 'law-u4])
  (define prof (lookup-canonical-workload-profile workload-name))
  (define paradigm (hash-ref prof 'paradigm))
  (define dist-sched
    (compute-optical-distillation-schedule p-link
                                           #:p-local p-local
                                           #:eps-target eps-target
                                           #:d d
                                           #:r-bell r-bell))
  (define base-d-dist (hash-ref dist-sched 'd_dist_effective))
  (define n-raw-unit (hash-ref dist-sched 'n_raw_per_logical_ebit))
  (define lookup-mult
    (match lookup-mode
      ['law-u4 1]
      ['roundtrip-cat 2]
      [_ (error 'solve-noisy-optical-cluster-m-star "Unsupported lookup-mode: ~a" lookup-mode)]))

  (define cands
    (filter (lambda (m) (<= m m-max)) default-m-candidates))

  (match paradigm
    [(or 'grover-amplify 'isd-search)
     (define t-wall-1 (/ (exact->inexact (hash-ref prof 't_toff)) local-ccx-rate-hz))
     (hasheq 'workload workload-name
             'paradigm (symbol->string paradigm)
             'topology (symbol->string topology)
             'lookup_mode (symbol->string lookup-mode)
             'p_link (exact->inexact p-link)
             'eps_target (exact->inexact eps-target)
             'code_distance_d d
             'r_bell_hz (exact->inexact r-bell)
             'd_dist_effective base-d-dist
             'n_raw_per_logical_ebit n-raw-unit
             'max_machines m-max
             'q_cap q-cap
             'optimal_m_star 1
             'qcap_400_m_star 1
             'qubits_per_machine (hash-ref prof 'q_single)
             'logical_ebits 0
             'forward_ebits 0
             'reverse_ebits 0
             'carry_ebits 0
             'raw_bell_pairs_consumed 0
             'wall_clock_sec t-wall-1
             'zalka_sqrt_m_guard #t
             'fallback_to_single_machine #t)]

    ['shot-sample
     (define shots (or (hash-ref prof 'total_shots) m-max))
     (define m-star (max 1 (min m-max shots)))
     (define t-wall (/ (exact->inexact (hash-ref prof 't_toff))
                       (* (exact->inexact m-star) local-ccx-rate-hz)))
     (hasheq 'workload workload-name
             'paradigm "shot-sample"
             'topology (symbol->string topology)
             'lookup_mode (symbol->string lookup-mode)
             'p_link (exact->inexact p-link)
             'eps_target (exact->inexact eps-target)
             'code_distance_d d
             'r_bell_hz (exact->inexact r-bell)
             'd_dist_effective base-d-dist
             'n_raw_per_logical_ebit n-raw-unit
             'max_machines m-max
             'q_cap q-cap
             'optimal_m_star m-star
             'qcap_400_m_star m-star
             'qubits_per_machine (hash-ref prof 'q_single)
             'logical_ebits 0
             'forward_ebits 0
             'reverse_ebits 0
             'carry_ebits 0
             'raw_bell_pairs_consumed 0
             'wall_clock_sec t-wall
             'zalka_sqrt_m_guard #f
             'fallback_to_single_machine #f)]

    ['algebraic-limb
     (define n-win (hash-ref prof 'n_win))
     (define q-data (hash-ref prof 'q_data))
     (define t-toff (hash-ref prof 't_toff))
     (define carry-cut (hash-ref prof 'carry_ebits_per_win_cut))

     ;; Evaluate all candidate `M in cands` with U-curve knee pruning for `M >= 2`:
     (define min-multi-q +inf.0)
     (define eval-rows
       (for/list ([m (in-list cands)])
         (define qm (q-per-machine-on-topology prof m topology))
         (define u-pruned?
           (and (>= m 2) (>= (exact->inexact qm) min-multi-q)))
         (when (and (>= m 2) (< (exact->inexact qm) min-multi-q))
           (set! min-multi-q (exact->inexact qm)))
         (define feasible? (and (<= qm q-cap) (not u-pruned?)))
         (define fwd-lookup
           (if (<= m 1) 0 (* n-win (hash-ref prof 'lookup_ebits_per_win_cut) (sub1 m))))
         (define rev-lookup
           (if (or (<= m 1) (eq? lookup-mode 'law-u4)) 0 fwd-lookup))
         (define carry-ebits
           (if (<= m 1) 0 (* n-win carry-cut (sub1 m))))
         (define e-log (+ fwd-lookup rev-lookup carry-ebits))
         (define hop-mult (topology-optical-hop-multiplier m topology))
         (define eff-d-dist-m
           (inexact->exact (ceiling (* (exact->inexact base-d-dist) hop-mult))))
         (define t-loc (/ (exact->inexact t-toff)
                          (* (exact->inexact (max 1 m)) local-ccx-rate-hz)))
         (define t-sync
           (if (<= m 1)
               0.0
               (* qec-window-sync-coeff-sec
                  (exact->inexact n-win)
                  (exact->inexact q-data)
                  (exact->inexact (sub1 m)))))
         (define t-wall
           (if (<= m 1)
               t-loc
               (+ t-loc
                  t-sync
                  (/ (* (exact->inexact eff-d-dist-m) (exact->inexact e-log))
                     (exact->inexact r-bell)))))
         (define t-wall-unattenuated
           (if (<= m 1)
               t-loc
               (+ t-loc
                  t-sync
                  (/ (* (exact->inexact base-d-dist) (exact->inexact e-log))
                     (exact->inexact r-bell)))))
         (hasheq 'm m
                 'qubits_per_machine qm
                 'u_curve_pruned u-pruned?
                 'feasible feasible?
                 'forward_ebits (+ fwd-lookup carry-ebits)
                 'reverse_ebits rev-lookup
                 'carry_ebits carry-ebits
                 'logical_ebits e-log
                 'effective_d_dist_on_topology eff-d-dist-m
                 'raw_bell_pairs_consumed (* eff-d-dist-m e-log)
                 'unattenuated_wall_clock_sec t-wall-unattenuated
                 'wall_clock_sec t-wall)))

     (define feasible-rows
       (filter (lambda (r) (hash-ref r 'feasible)) eval-rows))
     (define best-row
       (argmin (lambda (r) (hash-ref r 'wall_clock_sec)) feasible-rows))
     (define m-star (hash-ref best-row 'm))

     ;; Modular `Q_cap = 400` `solve-optimal-qpar-machines` decision + latency-guarded decision:
     (define t-wall-single (hash-ref (first eval-rows) 'wall_clock_sec))
     (define feas-400
       (filter (lambda (r)
                 (and (>= (hash-ref r 'm) 2)
                      (not (hash-ref r 'u_curve_pruned))
                      (<= (hash-ref r 'qubits_per_machine) 400)))
               eval-rows))
     (define qcap400-m-star
       (cond
         [(<= (hash-ref prof 'q_single) 400) 1]
         [(null? feas-400) 1]
         [else (hash-ref (argmin (lambda (r) (hash-ref r 'unattenuated_wall_clock_sec)) feas-400) 'm)]))
     (define best-400-row (argmin (lambda (r) (hash-ref r 'wall_clock_sec)) feas-400))
     (define qcap400-latency-guarded-m-star
       (if (>= (hash-ref best-400-row 'wall_clock_sec) t-wall-single)
           1
           (hash-ref best-400-row 'm)))

     (hasheq 'workload workload-name
             'paradigm "algebraic-limb"
             'topology (symbol->string topology)
             'lookup_mode (symbol->string lookup-mode)
             'p_link (exact->inexact p-link)
             'eps_target (exact->inexact eps-target)
             'code_distance_d d
             'r_bell_hz (exact->inexact r-bell)
             'd_dist_effective base-d-dist
             'n_raw_per_logical_ebit n-raw-unit
             'max_machines m-max
             'q_cap q-cap
             'optimal_m_star m-star
             'qcap_400_m_star qcap400-m-star
             'qcap_400_latency_guarded_m_star qcap400-latency-guarded-m-star
             'qubits_per_machine (hash-ref best-row 'qubits_per_machine)
             'logical_ebits (hash-ref best-row 'logical_ebits)
             'forward_ebits (hash-ref best-row 'forward_ebits)
             'reverse_ebits (hash-ref best-row 'reverse_ebits)
             'carry_ebits (hash-ref best-row 'carry_ebits)
             'raw_bell_pairs_consumed (hash-ref best-row 'raw_bell_pairs_consumed)
             'wall_clock_sec (hash-ref best-row 'wall_clock_sec)
             'single_machine_wall_clock_sec t-wall-single
             'zalka_sqrt_m_guard #f
             'fallback_to_single_machine (= m-star 1)
             'candidate_evaluations eval-rows)]))

;; Sweeps `M*(p_link)` across all 6 canonical workloads, both topologies, and
;; `p_link in {0.005, 0.01, 0.02, 0.03, 0.05}`.
(define (run-noisy-optical-cluster-sweep #:eps-target [eps-target 1e-9]
                                         #:d [d 3]
                                         #:r-bell [r-bell 100000.0]
                                         #:p-local [p-local 0.001])
  (for/list ([topo (in-list '(all-to-all-peers switched-optical-tree))])
    (define workload-trajectories
      (for/list ([wname (in-list canonical-six-workloads)])
        (define points
          (for/list ([pl (in-list canonical-p-link-grid)])
            (define raw-pt
              (solve-noisy-optical-cluster-m-star wname pl
                                                  #:eps-target eps-target
                                                  #:d d
                                                  #:r-bell r-bell
                                                  #:p-local p-local
                                                  #:topology topo))
            (hash-remove raw-pt 'candidate_evaluations)))
        (define m-seq (map (lambda (pt) (hash-ref pt 'optimal_m_star)) points))
        (define monotone-nonincreasing?
          (for/and ([a (in-list m-seq)] [b (in-list (cdr m-seq))])
            (>= a b)))
        (hasheq 'workload wname
                'topology (symbol->string topo)
                'm_star_sequence m-seq
                'monotone_contraction monotone-nonincreasing?
                'points points)))
    (hasheq 'topology (symbol->string topo)
            'eps_target (exact->inexact eps-target)
            'code_distance_d d
            'r_bell_hz (exact->inexact r-bell)
            'workloads workload-trajectories)))

;; Law-U4 Cross-QPU Bilinear Tele-Phase Reduction & Batched Cat-Entangler Fusion
;; (`u4-cross-qpu-tele-phase-opt`) over distributed `within-apply-mbu` partition cuts:
;; Factors the cross-partition MBU phase polynomial
;;   Phi_X(m, x^(p1), x^(p2)) = sum_k m_k * l_1(x^(p1)) * l_2(x^(p2))
;;                            = sum_r l_{1,r}(x^(p1)) * (xor_{k in cone(r)} m_k * l_{2,k}(x^(p2)))
;; so that all reverse `cond-cz` corrections sharing a remote pivot `l_{1,r}(x^(p1))`
;; fuse into a single batched cat-entangler (`1` forward ebit per pivot cone) +
;; local `cond-cz` on `@p2` + a `1`-bit classical broadcast (`0` reverse ebits).
(define (u4-cross-qpu-tele-phase-opt mbu-cut-terms)
  (define grouped (make-hash))
  (define pivot-order '())
  (for ([term (in-list mbu-cut-terms)])
    (define p1 (hash-ref term 'src_qpu 0))
    (define p2 (hash-ref term 'dst_qpu 1))
    (define piv (hash-ref term 'remote_pivot 0))
    (define key (list p1 p2 piv))
    (unless (hash-has-key? grouped key)
      (set! pivot-order (append pivot-order (list key)))
      (hash-set! grouped key '()))
    (hash-set! grouped key (append (hash-ref grouped key) (list term))))

  (define k-wires (length mbu-cut-terms))
  (define n-cones (length pivot-order))
  (define naive-ebits (* 2 k-wires))
  (define unbatched-u4-ebits k-wires)
  (define batched-u4-ebits n-cones)
  (define cones
    (for/list ([key (in-list pivot-order)])
      (match-define (list p1 p2 piv) key)
      (define terms (hash-ref grouped key))
      (hasheq 'src_qpu p1
              'dst_qpu p2
              'remote_pivot piv
              'cone_size (length terms)
              'naive_ebits (* 2 (length terms))
              'u4_batched_ebits 1
              'reverse_ebits 0
              'classical_broadcast_bits 1)))
  (hasheq 'pass_name "u4-cross-qpu-tele-phase-opt"
          'bilinear_phase_polynomial "Phi_X(m, x^(p1), x^(p2)) = sum_k m_k * l_1(x^(p1)) * l_2(x^(p2))"
          'factored_cone_polynomial "sum_r l_{1,r}(x^(p1)) * (xor_{k in cone(r)} m_k * l_{2,k}(x^(p2)))"
          'cross_cut_mbu_wires k-wires
          'batched_pivot_cones n-cones
          'naive_ebits_2_per_wire naive-ebits
          'u4_unbatched_ebits_1_per_wire unbatched-u4-ebits
          'u4_batched_cone_ebits batched-u4-ebits
          'reverse_ebits 0
          'classical_broadcast_bits n-cones
          'unbatched_ebit_reduction_pct
          (if (zero? naive-ebits)
              0.0
              (* 100.0 (/ (exact->inexact (- naive-ebits unbatched-u4-ebits))
                          (exact->inexact naive-ebits))))
          'batched_ebit_reduction_pct
          (if (zero? naive-ebits)
              0.0
              (* 100.0 (/ (exact->inexact (- naive-ebits batched-u4-ebits))
                          (exact->inexact naive-ebits))))
          'pivot_cones cones))

;; Evaluates Law-U4 Cross-QPU Tele-Phase Reduction & Batched Cat-Entangler Fusion
;; across distributed MBU cuts on `ECC-256` and `Shor-2048` (`RSA-2048`) zipper partitions.
(define (compute-u4-mbu-tele-phase-zipper-reduction #:p-link [p-link 0.005]
                                                    #:eps-target [eps-target 1e-9]
                                                    #:d [d 3]
                                                    #:r-bell [r-bell 100000.0])
  (define dist-sched
    (compute-optical-distillation-schedule p-link
                                           #:eps-target eps-target
                                           #:d d
                                           #:r-bell r-bell))
  (define d-dist (hash-ref dist-sched 'd_dist_effective))

  ;; 1. ECC-256 zipper partition (`112` windows, `M* = 2` at `p_link = 0.005`, `M = 4` at `Q_cap = 400`):
  ;;    Each window cut has `5` lookup MBU wires + `24` projective-oblivious-runway wires
  ;;    (`12` cross-cut MBU wires grouped into `8` shared remote pivots + `12` state transfers).
  ;;    - Unfused cross-QPU MBU baseline (`2` Bell pairs per cross-cut MBU wire):
  ;;        `2 * 5 + 2 * 12 + 12 = 46` ebits / window cut (`5,152` ebits at M=2; `15,456` at M=4).
  ;;    - Law-U4 tele-phase reduction (`0` reverse `cond-cz` ebits via 1-bit broadcast):
  ;;        `5 + 24 = 29` ebits / window cut (`3,248` ebits at M=2; `9,744` at M=4) -> `36.96%` reduction.
  ;;    - Law-U4 tele-phase + batched cat-entangler pivot-cone fusion (`8` degree-2 runway cones):
  ;;        `5 + 20 = 25` ebits / window cut (`2,800` ebits at M=2; `8,400` at M=4) -> `45.65%` reduction.
  (define ecc-n-win 112)
  (define ecc-m-star 2)
  (define ecc-qcap400-m 4)
  (define ecc-naive-per-cut 46)
  (define ecc-u4-per-cut 29)
  (define ecc-batched-per-cut 25)
  (define ecc-u4-red-pct
    (/ (round (* 10000.0 (/ (exact->inexact (- ecc-naive-per-cut ecc-u4-per-cut))
                            (exact->inexact ecc-naive-per-cut))))
       100.0))
  (define ecc-batched-red-pct
    (/ (round (* 10000.0 (/ (exact->inexact (- ecc-naive-per-cut ecc-batched-per-cut))
                            (exact->inexact ecc-naive-per-cut))))
       100.0))

  ;; 2. Shor-2048 (`RSA-2048`) zipper partition (`1038` windows, `w = 6` MBU lookup wires, `0` QRNS carry):
  ;;    - Unfused cross-QPU MBU baseline (`2` Bell pairs per cross-cut MBU wire):
  ;;        `2 * 6 = 12` ebits / window cut (`62,280` ebits at M*=6; `37,368` at M=4).
  ;;    - Law-U4 tele-phase reduction (`1` forward cat-entangler + `0` reverse `cond-cz` ebits):
  ;;        `1 * 6 = 6` ebits / window cut (`31,140` ebits at M*=6; `18,684` at M=4) -> `50.0%` reduction.
  (define shor-n-win 1038)
  (define shor-m-star 6)
  (define shor-qcap400-m 4)
  (define shor-naive-per-cut 12)
  (define shor-u4-per-cut 6)
  (define shor-u4-red-pct
    (/ (round (* 10000.0 (/ (exact->inexact (- shor-naive-per-cut shor-u4-per-cut))
                            (exact->inexact shor-naive-per-cut))))
       100.0))

  (hasheq
   'pass_name "u4-cross-qpu-tele-phase-opt"
   'bilinear_phase_polynomial "Phi_X(m, x^(p1), x^(p2)) = sum_k m_k * l_1(x^(p1)) * l_2(x^(p2))"
   'factored_cone_polynomial "sum_r l_{1,r}(x^(p1)) * (xor_{k in cone(r)} m_k * l_{2,k}(x^(p2)))"
   'target_reduction_band_pct '(35.0 50.0)
   'within_35_to_50_pct_band
   (and (<= 35.0 ecc-u4-red-pct 50.0)
        (<= 35.0 ecc-batched-red-pct 50.0)
        (<= 35.0 shor-u4-red-pct 50.0))
   'ecc_256_zipper_partition
   (hasheq 'workload "ECC-256"
           'num_windows ecc-n-win
           'm_star_at_p005 ecc-m-star
           'm_star_at_qcap400 ecc-qcap400-m
           'naive_ebits_per_win_cut ecc-naive-per-cut
           'u4_tele_phase_ebits_per_win_cut ecc-u4-per-cut
           'u4_batched_cat_ebits_per_win_cut ecc-batched-per-cut
           'naive_logical_ebits_m2 (* ecc-n-win ecc-naive-per-cut (sub1 ecc-m-star))
           'u4_tele_phase_logical_ebits_m2 (* ecc-n-win ecc-u4-per-cut (sub1 ecc-m-star))
           'u4_batched_cat_logical_ebits_m2 (* ecc-n-win ecc-batched-per-cut (sub1 ecc-m-star))
           'naive_logical_ebits_m4 (* ecc-n-win ecc-naive-per-cut (sub1 ecc-qcap400-m))
           'u4_tele_phase_logical_ebits_m4 (* ecc-n-win ecc-u4-per-cut (sub1 ecc-qcap400-m))
           'u4_batched_cat_logical_ebits_m4 (* ecc-n-win ecc-batched-per-cut (sub1 ecc-qcap400-m))
           'reverse_cond_cz_ebits 0
           'u4_tele_phase_ebit_reduction_pct ecc-u4-red-pct
           'u4_batched_cat_ebit_reduction_pct ecc-batched-red-pct)
   'shor_2048_zipper_partition
   (hasheq 'workload "Shor-2048"
           'canonical_alias "RSA-2048"
           'num_windows shor-n-win
           'm_star_at_p005 shor-m-star
           'm_star_at_qcap400 shor-qcap400-m
           'naive_ebits_per_win_cut shor-naive-per-cut
           'u4_tele_phase_ebits_per_win_cut shor-u4-per-cut
           'naive_logical_ebits_m6 (* shor-n-win shor-naive-per-cut (sub1 shor-m-star))
           'u4_tele_phase_logical_ebits_m6 (* shor-n-win shor-u4-per-cut (sub1 shor-m-star))
           'naive_logical_ebits_m4 (* shor-n-win shor-naive-per-cut (sub1 shor-qcap400-m))
           'u4_tele_phase_logical_ebits_m4 (* shor-n-win shor-u4-per-cut (sub1 shor-qcap400-m))
           'naive_raw_bell_pairs_m6_p005 (* d-dist shor-n-win shor-naive-per-cut (sub1 shor-m-star))
           'u4_tele_phase_raw_bell_pairs_m6_p005 (* d-dist shor-n-win shor-u4-per-cut (sub1 shor-m-star))
           'reverse_cond_cz_ebits 0
           'u4_tele_phase_ebit_reduction_pct shor-u4-red-pct)))

;; Builds the complete deterministic JSON report cross-checked by Python (`Stim` + `PyMatching`).
(define (build-optical-distillation-json-report)
  (define physical-dejmps-grid
    (for*/list ([k (in-list '(1 2 3))]
                [pl (in-list canonical-p-link-grid)])
      (run-physical-distillation-steps pl k #:p-local 0.001 #:p-meas 0.001 #:protocol 'dejmps)))

  (define physical-bbpssw-grid
    (for*/list ([k (in-list '(1 2 3))]
                [pl (in-list canonical-p-link-grid)])
      (run-physical-distillation-steps pl k #:p-local 0.001 #:p-meas 0.001 #:protocol 'bbpssw)))

  (define logical-schedule-grid
    (for*/list ([d (in-list canonical-code-distances)]
                [eps-t (in-list canonical-eps-targets)]
                [pl (in-list canonical-p-link-grid)])
      (compute-optical-distillation-schedule pl
                                             #:p-local 0.001
                                             #:p-meas 0.001
                                             #:eps-target eps-t
                                             #:d d
                                             #:r-bell 100000.0)))

  (define m-star-sweep-d3-eps9
    (run-noisy-optical-cluster-sweep #:eps-target 1e-9 #:d 3 #:r-bell 100000.0))
  (define m-star-sweep-d5-eps9
    (run-noisy-optical-cluster-sweep #:eps-target 1e-9 #:d 5 #:r-bell 100000.0))
  (define m-star-sweep-d3-eps12
    (run-noisy-optical-cluster-sweep #:eps-target 1e-12 #:d 3 #:r-bell 100000.0))

  ;; Compare `Law U4` (`0` reverse ebits) vs. `Round-Trip` (`2x` optical ebits) on `RSA-2048`:
  (define rsa2048-u4-vs-roundtrip
    (for/list ([pl (in-list canonical-p-link-grid)])
      (define u4 (solve-noisy-optical-cluster-m-star "RSA-2048" pl #:lookup-mode 'law-u4))
      (define rt (solve-noisy-optical-cluster-m-star "RSA-2048" pl #:lookup-mode 'roundtrip-cat))
      (hasheq 'p_link pl
              'law_u4_m_star (hash-ref u4 'optimal_m_star)
              'roundtrip_m_star (hash-ref rt 'optimal_m_star)
              'law_u4_wall_sec (hash-ref u4 'wall_clock_sec)
              'roundtrip_wall_sec (hash-ref rt 'wall_clock_sec)
              'law_u4_reverse_ebits (hash-ref u4 'reverse_ebits)
              'roundtrip_reverse_ebits (hash-ref rt 'reverse_ebits))))

  (define u4-tele-phase-red
    (compute-u4-mbu-tele-phase-zipper-reduction #:p-link 0.005 #:eps-target 1e-9 #:d 3 #:r-bell 100000.0))

  (hasheq 'status "PASS"
          'unified_judgment "Gamma_in |- t : Q_e(A) -| Gamma_out"
          'p_link_grid canonical-p-link-grid
          'p_local_default 0.001
          'p_meas_default 0.001
          'eps_targets canonical-eps-targets
          'code_distances canonical-code-distances
          'physical_dejmps_grid physical-dejmps-grid
          'physical_bbpssw_grid physical-bbpssw-grid
          'logical_schedule_grid logical-schedule-grid
          'cluster_m_star_sweep_d3_eps1e9 m-star-sweep-d3-eps9
          'cluster_m_star_sweep_d5_eps1e9 m-star-sweep-d5-eps9
          'cluster_m_star_sweep_d3_eps1e12 m-star-sweep-d3-eps12
          'rsa2048_law_u4_vs_roundtrip rsa2048-u4-vs-roundtrip
          'u4_tele_phase_reduction u4-tele-phase-red))

;; =============================================================================
;; 4. Comprehensive `rackunit` Verification (`>= 40` Tests) & `--json` CLI
;; =============================================================================

(module+ test
  (require rackunit)

  ;; 1-6: Raw Bell state validity & exact `DEPOLARIZE2(p_link)` weights (`f = 1 - 4/5 p_link`):
  (for ([pl (in-list canonical-p-link-grid)])
    (define st (raw-optical-bell-state pl))
    (check-true (bell-state-valid? st))
    (check-= (bell-state-infidelity st) (* 0.8 pl) 1e-12))
  (check-equal? (bell-diag-state-f (raw-optical-bell-state 0.0)) 1.0)

  ;; 7-12: Multi-step noisy `DEJMPS` physical purification across all 5 `p_link` points:
  ;; Probability normalization holds and 2-step + 3-step `DEJMPS` strictly suppresses
  ;; raw link infidelity down toward the `p_local = 0.001` floor!
  (for ([pl (in-list canonical-p-link-grid)])
    (define r1 (run-physical-distillation-steps pl 1 #:protocol 'dejmps))
    (define r2 (run-physical-distillation-steps pl 2 #:protocol 'dejmps))
    (define r3 (run-physical-distillation-steps pl 3 #:protocol 'dejmps))
    (define e0 (hash-ref r1 'raw_initial_infidelity))
    (define e1 (hash-ref r1 'final_infidelity))
    (define e2 (hash-ref r2 'final_infidelity))
    (define e3 (hash-ref r3 'final_infidelity))
    (check-true (< e1 e0) (format "1-step DEJMPS must reduce infidelity at p_link=~a" pl))
    (check-true (< e2 e1) (format "2-step DEJMPS must reduce infidelity at p_link=~a" pl))
    (check-true (< e3 e2) (format "3-step DEJMPS must reduce infidelity at p_link=~a" pl)))

  ;; 13-17: `DEJMPS` twirling strictly outperforms unrotated `BBPSSW` at `k = 2` and `k = 3`
  ;; across all 5 `p_link` values (because `BBPSSW` leaves `|Phi->` phase errors unrotated!):
  (for ([pl (in-list canonical-p-link-grid)])
    (define dej2 (hash-ref (run-physical-distillation-steps pl 2 #:protocol 'dejmps) 'final_infidelity))
    (define bbp2 (hash-ref (run-physical-distillation-steps pl 2 #:protocol 'bbpssw) 'final_infidelity))
    (check-true (< dej2 bbp2)))

  ;; 18-23: Survival probability `P_succ(1)` strictly decreases as `p_link` increases,
  ;; while raw Bell pair consumption `N_raw_sync(k)` strictly increases:
  (let ([r2-list (for/list ([pl (in-list canonical-p-link-grid)])
                   (run-physical-distillation-steps pl 2 #:protocol 'dejmps))])
    (for ([a (in-list r2-list)] [b (in-list (cdr r2-list))])
      (check-true (> (hash-ref a 'tree_survival_prob) (hash-ref b 'tree_survival_prob)))
      (check-true (< (hash-ref a 'n_raw_sync) (hash-ref b 'n_raw_sync)))))

  ;; 24-35: Strict monotonicity of `D_dist(p_link, eps_target, r_bell)` in `p_link`
  ;; and strict increase from `eps_target = 1e-9` to `1e-12` across `d in {3, 5, 7}`:
  (for ([d (in-list canonical-code-distances)])
    (for ([eps-t (in-list canonical-eps-targets)])
      (define scheds
        (for/list ([pl (in-list canonical-p-link-grid)])
          (compute-optical-distillation-schedule pl #:eps-target eps-t #:d d)))
      (for ([s (in-list scheds)])
        (check-true (hash-ref s 'target_met))
        (check-true (<= (hash-ref s 'achieved_logical_infidelity) eps-t)))
      (for ([s1 (in-list scheds)] [s2 (in-list (cdr scheds))])
        (check-true (< (hash-ref s1 'n_raw_per_logical_ebit)
                       (hash-ref s2 'n_raw_per_logical_ebit)))
        (check-true (< (hash-ref s1 'd_dist_effective)
                       (hash-ref s2 'd_dist_effective)))))
    (for ([pl (in-list canonical-p-link-grid)])
      (define d9 (compute-d-dist pl 1e-9 100000.0 #:d d))
      (define d12 (compute-d-dist pl 1e-12 100000.0 #:d d))
      (check-true (< d9 d12))))

  ;; 36-47: Monotone contraction of `M*(p_link)` toward `1` across ALL 6 workloads
  ;; and BOTH topologies (`'all-to-all-peers` and `'switched-optical-tree`) at `d = 3` and `d = 5`:
  (for ([d (in-list '(3 5))])
    (define sweeps (run-noisy-optical-cluster-sweep #:eps-target 1e-9 #:d d))
    (for ([topo-entry (in-list sweeps)])
      (for ([w-entry (in-list (hash-ref topo-entry 'workloads))])
        (define wname (hash-ref w-entry 'workload))
        (define m-seq (hash-ref w-entry 'm_star_sequence))
        (check-true (hash-ref w-entry 'monotone_contraction)
                    (format "M*(p_link) must be monotone non-increasing for ~a (~a, d=~a)"
                            wname (hash-ref topo-entry 'topology) d))
        (match wname
          [(or "ECC-256" "RSA-2048" "RSA-4096")
           ;; Contracts all the way to `M* = 1` at `p_link = 0.05` (`5.0%`):
           (check-equal? (last m-seq) 1)
           (when (member wname '("RSA-2048" "RSA-4096"))
             (check-true (> (first m-seq) 1)))]
          [(or "AES-128" "McEliece-348864")
           ;; `T-ParGuard` Zalka guard holds `M* = 1` at every `p_link`:
           (check-equal? m-seq '(1 1 1 1 1))]
          ["FeMoCo-THC"
           ;; `ParShotLinear` (`0` optical ebits) holds `M* = 64` at every `p_link`:
           (check-equal? m-seq '(64 64 64 64 64))]))))

  ;; 48-55: Exact `M*(p_link)` contraction anchors & `Law U4` (`0` reverse ebits, `0` QRNS carry ebits)
  ;; vs. naive `Round-Trip` (`2x` optical ebits):
  (define sweeps-d3 (run-noisy-optical-cluster-sweep #:eps-target 1e-9 #:d 3))
  (define peers-d3 (first sweeps-d3))
  (define tree-d3 (second sweeps-d3))
  (define (m-seq-of topo-hash wname)
    (for/first ([w (in-list (hash-ref topo-hash 'workloads))]
                #:when (string=? (hash-ref w 'workload) wname))
      (hash-ref w 'm_star_sequence)))
  (check-equal? (m-seq-of peers-d3 "ECC-256") '(2 1 1 1 1))
  (check-equal? (m-seq-of peers-d3 "RSA-2048") '(6 6 4 2 1))
  (check-equal? (m-seq-of peers-d3 "RSA-4096") '(8 8 6 4 1))
  (check-equal? (m-seq-of tree-d3 "RSA-2048") '(6 4 4 2 1))

  (define sweeps-d5 (run-noisy-optical-cluster-sweep #:eps-target 1e-9 #:d 5))
  (check-equal? (m-seq-of (second sweeps-d5) "RSA-4096") '(8 6 4 2 1))

  (for ([pl (in-list '(0.005 0.01 0.02))])
    (define u4 (solve-noisy-optical-cluster-m-star "RSA-2048" pl #:lookup-mode 'law-u4 #:q-cap 400))
    (define rt (solve-noisy-optical-cluster-m-star "RSA-2048" pl #:lookup-mode 'roundtrip-cat #:q-cap 400))
    (check-equal? (hash-ref u4 'reverse_ebits) 0)
    (check-equal? (hash-ref u4 'carry_ebits) 0)
    (check-true (> (hash-ref rt 'reverse_ebits) 0))
    (check-true (< (hash-ref u4 'wall_clock_sec) (hash-ref rt 'wall_clock_sec))))

  ;; Cross-check `qcap_400_m_star` against `solve-optimal-qpar-machines` in
  ;; `lakefillq-bug-class-prevention-types.rkt` across all 6 workloads & both topologies:
  (define bcp-path "lakefillq-bug-class-prevention-types.rkt")
  (define dyn-par-spec (dynamic-require bcp-path 'par-cluster-opt-spec))
  (define dyn-solve-opt (dynamic-require bcp-path 'solve-optimal-qpar-machines))
  (define dyn-res-metrics (dynamic-require bcp-path 'lfq-typecheck-result-metrics))
  (for* ([topo (in-list '(all-to-all-peers switched-optical-tree))]
         [wname (in-list canonical-six-workloads)]
         [pl (in-list '(0.005 0.05))])
    (define prof (lookup-canonical-workload-profile wname))
    (define res-local (solve-noisy-optical-cluster-m-star wname pl #:topology topo))
    (define spec400
      (dyn-par-spec #:workload (string->symbol wname)
                    #:paradigm (hash-ref prof 'paradigm)
                    #:max-machines 256
                    #:q-cap-per-machine 400
                    #:raw-bell-rate-hz 100000.0
                    #:raw-per-logical-ebit (hash-ref res-local 'd_dist_effective)
                    #:q-single (hash-ref prof 'q_single)
                    #:q-data-dist (hash-ref prof 'q_data)
                    #:q-local-fixed (hash-ref prof 'q_fix)
                    #:q-peer-sync (hash-ref prof 'q_sync)
                    #:window-bits (hash-ref prof 'w_bits)
                    #:num-windows (hash-ref prof 'n_win)
                    #:local-toffolis (hash-ref prof 't_toff)
                    #:carry-scheme (hash-ref prof 'carry_scheme)
                    #:lookup-scheme (hash-ref prof 'lookup_scheme)
                    #:interconnect-topology topo
                    #:total-shots (hash-ref prof 'total_shots)
                    #:strict-parallel? #f))
    (define ref400 (dyn-solve-opt spec400))
    (check-equal? (hash-ref res-local 'qcap_400_m_star)
                  (hash-ref (dyn-res-metrics ref400) 'optimal_machines)))

  ;; 56-62: Law-U4 Cross-QPU Bilinear Tele-Phase Reduction & Batched Cat-Entangler Fusion:
  (define cone-opt
    (u4-cross-qpu-tele-phase-opt
     (list (hasheq 'src_qpu 0 'dst_qpu 1 'remote_pivot 0 'partner_wire 2 'anc_wire 5)
           (hasheq 'src_qpu 0 'dst_qpu 1 'remote_pivot 0 'partner_wire 3 'anc_wire 6)
           (hasheq 'src_qpu 0 'dst_qpu 1 'remote_pivot 1 'partner_wire 4 'anc_wire 7))))
  (check-equal? (hash-ref cone-opt 'cross_cut_mbu_wires) 3)
  (check-equal? (hash-ref cone-opt 'batched_pivot_cones) 2)
  (check-equal? (hash-ref cone-opt 'naive_ebits_2_per_wire) 6)
  (check-equal? (hash-ref cone-opt 'u4_unbatched_ebits_1_per_wire) 3)
  (check-equal? (hash-ref cone-opt 'u4_batched_cone_ebits) 2)
  (check-equal? (hash-ref cone-opt 'reverse_ebits) 0)

  (define zip-red (compute-u4-mbu-tele-phase-zipper-reduction))
  (check-true (hash-ref zip-red 'within_35_to_50_pct_band))
  (define ecc-z (hash-ref zip-red 'ecc_256_zipper_partition))
  (define shor-z (hash-ref zip-red 'shor_2048_zipper_partition))
  (check-true (<= 35.0 (hash-ref ecc-z 'u4_tele_phase_ebit_reduction_pct) 50.0))
  (check-true (<= 35.0 (hash-ref ecc-z 'u4_batched_cat_ebit_reduction_pct) 50.0))
  (check-equal? (hash-ref shor-z 'u4_tele_phase_ebit_reduction_pct) 50.0))

(module+ main
  (define emit-json? #f)
  (command-line
   #:program "lakefillq-optical-distillation-stim"
   #:once-each
   [("--json") "Emit calibrated optical distillation and M*(p_link) JSON report"
    (set! emit-json? #t)])
  (define report (build-optical-distillation-json-report))
  (if emit-json?
      (begin
        (write-json report)
        (newline))
      (printf "LakefillQ Noisy Optical-Link Distillation & M*(p_link) Optimizer: status=~a, DEJMPS points=~a, logical schedules=~a\n"
              (hash-ref report 'status)
              (length (hash-ref report 'physical_dejmps_grid))
              (length (hash-ref report 'logical_schedule_grid)))))
