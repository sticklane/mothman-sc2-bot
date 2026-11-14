#lang racket/base

;; =============================================================================
;; Full Replay Corpus Multi-Horizon Curve Evaluator
;; (`tools/evaluate-full-corpus-multi-horizon.rkt`)
;;
;; Evaluates the ACTUAL Racket `#lang sc-bot` Mirror-Mind brain
;; (`lib/mirror-mind-predictor.rkt`) across EVERY replay and checkpoint in
;; `replays/corpus_checkpoints.sexp` at all 8 lookahead horizons:
;;   Δt ∈ {15, 30, 45, 60, 75, 90, 105, 130} seconds
;;   Δf ∈ {336, 672, 1008, 1344, 1680, 2016, 2352, 2912} frames
;;
;; Compares:
;;   - Individual recursive cognitive depths: d = 0, 1, 2, 3, 4, 5
;;   - Online Fog-of-War Adaptive Depth: d*
;;   - Build-Order-Tree + Bayesian Posterior + Horizon-Matched Depth: tree_bayesian_d_star
;; across all 4 causal metrics (Legacy Set Accuracy, Causal Spend-Weighted Accuracy,
;; Tech Transition Pivot Accuracy, Counter-Payoff Utility) and across all cohorts
;; (`all`, `pro_all`, `aiarena_ladder`, `local_real_matches`).
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/hash
         racket/file
         json
         "../lib/sc2-common.rkt"
         "../lib/mirror-mind-predictor.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/bot-runtime.rkt"
         "../lib/zerospace-mastermind.rkt")

(define HORIZONS '(15 30 45 60 75 90 105 130))
(define D-KEYS '(0 1 2 3 4 5 d* tree_bayesian))

(define (d-key->json-sym dk)
  (case dk
    [(0)             'd0]
    [(1)             'd1]
    [(2)             'd2]
    [(3)             'd3]
    [(4)             'd4]
    [(5)             'd5]
    [(d*)            'd_star]
    [(tree_bayesian) 'tree_bayesian_d_star]
    [else            'd2]))

(define (sexp-unit->hash u-sexp)
  (match u-sexp
    [(list tag sym x10 y10)
     (hash 'id tag 'type sym 'x (quotient x10 10) 'y (quotient y10 10) 'hp 100 'max-hp 100 'alive? #t)]
    [(list tag sym x10 y10 alive-flag)
     (hash 'id tag 'type sym 'x (quotient x10 10) 'y (quotient y10 10) 'hp 100 'max-hp 100 'alive? (= alive-flag 1))]
    [(list tag sym x10 y10 alive-flag last-gl)
     (hash 'id tag 'type sym 'x (quotient x10 10) 'y (quotient y10 10) 'hp 100 'max-hp 100 'alive? (= alive-flag 1) 'last-seen-gl last-gl)]
    [_ (hash 'id 0 'type 'unknown 'x 100 'y 100 'hp 100)]))

(define (make-horizon-bucket)
  (make-hash
   (list (cons 'evals 0)
         (cons 'transitions 0)
         (cons 'certainty-sum 0.0)
         (cons 'legacy-set (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'causal-weighted (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'transition-pivot (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'counter-payoff (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS))))))

(define (make-cohort-multi-horizon-bucket)
  (make-hash
   (list (cons 'replays (make-hash))
         (cons 'checkpoints 0)
         (cons 'reach-evals 0)
         (cons 'reach-hits 0)
         (cons 'horizons
               (for/hash ([h (in-list HORIZONS)])
                 (values h (make-horizon-bucket)))))))

;; Select the Build-Order-Tree + Bayesian Posterior + Horizon-Matched Depth unit prediction
;; for lookahead horizon `h-sec` (in seconds), using `horizon-snapshot-forecast` from
;; `predict-multi-horizon-snapshots` in `lib/mirror-mind-predictor.rkt` combined with
;; online per-depth accuracy across d = 0..5.
(define (predict-tree-bayesian-horizon-unit h-sec snap mstate obs nodes active-d eff-online-acc ledger zs-reading)
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define rem-gas (shadow-ledger-unaccounted-gas ledger))
  (define snap-unit
    (if snap (horizon-snapshot-forecast-predicted-enemy-unit snap) 'roach))
  (define snap-cert
    (if snap (horizon-snapshot-forecast-certainty-level snap) (horizon-sec->calibrated-certainty h-sec)))
  (define reachable-units
    (if snap (horizon-snapshot-forecast-reachable-units snap) '()))

  (define (node-unit d)
    (define nd (findf (lambda (n) (= (depth-node-depth n) d)) nodes))
    (if nd (depth-node-predicted-enemy-unit nd) snap-unit))

  (define d0-u (node-unit 0))
  (define d1-u (node-unit 1))
  (define d4-u (node-unit 4))
  (define dstar-u (node-unit active-d))

  (define noncombat '(drone probe scv overlord observer larva egg))
  (define visible-combat
    (filter (lambda (u) (not (memq (hash-ref u 'type 'unknown) noncombat))) enemy-units))
  (define strong-pivot-signal?
    (or (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)
        (and (<= (length visible-combat) 2) (>= rem-gas 150))))

  (define pred-u
    (cond
      ;; Ultra-short horizon (15s = 336 frames): 0/1-hop immediate production queue
      [(<= h-sec 15)
       (cond
         [(null? visible-combat) d1-u]
         [(>= active-d 1)
          (if (>= (hash-ref eff-online-acc 1 0.60) (- (hash-ref eff-online-acc active-d 0.60) 0.04))
              d1-u
              dstar-u)]
         [else d0-u])]
      ;; Short horizon (30s = 672 frames): 1-hop immediate production + d1/d2/d*
      [(<= h-sec 30)
       (cond
         [(null? visible-combat) d1-u]
         [(>= active-d 1)
          (if (>= (hash-ref eff-online-acc 1 0.60) (hash-ref eff-online-acc active-d 0.60))
              d1-u
              dstar-u)]
         [strong-pivot-signal? d1-u]
         [else d0-u])]
      ;; Medium tactical/tech-switch horizons (45s - 60s): 1-hop Build-Order Tree + d* / d4 / snap
      [(<= h-sec 60)
       (cond
         [(and (= active-d 0) strong-pivot-signal? (memq d4-u reachable-units)) d4-u]
         [(and (>= active-d 1) (> (hash-ref eff-online-acc 4 0.60) (hash-ref eff-online-acc active-d 0.60))) d4-u]
         [else dstar-u])]
      ;; Mid-long & macro strategic horizons (75s - 130s): 2-hop Build-Order Tree + d4 / d2 / d*
      [else
       (cond
         [(and (= active-d 0) strong-pivot-signal?) d4-u]
         [(and (>= active-d 1)
               (or (>= (hash-ref eff-online-acc 4 0.60) (- (hash-ref eff-online-acc active-d 0.60) 0.008))
                   (and (>= h-sec 105) (<= (length visible-combat) 4))))
          d4-u]
         [else dstar-u])]))

  (values pred-u snap-cert))

(define (score-single-unit-against-metrics pred-u metrics)
  (define d0-arch (hash-ref metrics 'd0-arch 'early-rush))
  (define dom-arch (hash-ref metrics 'dominant-future-arch 'early-rush))
  (define transition? (hash-ref metrics 'transition? #f))
  (define pred-arch (unit-to-archetype pred-u))
  ;; Find matching depth if any depth predicted the same archetype, or compute directly
  (values pred-arch transition? d0-arch dom-arch))

(define (evaluate-full-corpus-multi-horizon sexp-path)
  (define cohorts (make-hash))
  (for ([ck '("pro_tournament" "pro_corpus" "pro_all" "aiarena_ladder" "local_real_matches" "external_gauntlet" "bots_all" "all")])
    (hash-set! cohorts ck (make-cohort-multi-horizon-bucket)))

  (define perspective-states (make-hash))
  (define old-w-errs '())
  (define cal-w-errs '())
  (define old-m-errs '())
  (define cal-m-errs '())
  (define old-g-errs '())
  (define cal-g-errs '())

  (call-with-input-file sexp-path
    (lambda (in)
      (let loop ()
        (define rec (read in))
        (unless (eof-object? rec)
          (match rec
            [(list 'checkpoint cohort-str replay-id obs-p obs-name our-race
                   opp-name opp-race frame true-w true-min true-gas
                   opp-wk tcx10 tcy10
                   ally-u-list ally-b-list opp-u-list opp-b-list fut-syms rest ...)
             (define fut-horizons-alist
               (if (and (not (null? rest)) (list? (first rest)))
                   (first rest)
                   (map (lambda (h) (list h fut-syms)) HORIZONS)))

             (define p-key (cons replay-id obs-p))
             (define p-state
               (hash-ref! perspective-states p-key
                          (lambda ()
                            (define mm (make-mirror-mind-state #:our-race our-race #:enemy-race opp-race #:depth 2))
                            (hash 'mstate mm
                                  'online-acc (make-hash (list (cons 0 0.60)
                                                               (cons 1 0.61)
                                                               (cons 2 0.60)
                                                               (cons 3 0.59)
                                                               (cons 4 0.59)
                                                               (cons 5 0.58)))
                                  'prev-nodes #f
                                  'prev-enemy-units '()))))
             (define mstate (hash-ref p-state 'mstate))
             (define online-acc (hash-ref p-state 'online-acc))
             (define prev-nodes (hash-ref p-state 'prev-nodes))
             (define prev-enemy-units (hash-ref p-state 'prev-enemy-units))

             (define ally-units (map sexp-unit->hash ally-u-list))
             (define ally-bldgs (map sexp-unit->hash ally-b-list))
             (define all-seen-opp-u (map sexp-unit->hash opp-u-list))
             (define all-seen-opp-b (map sexp-unit->hash opp-b-list))
             (define alive-opp-u (filter (lambda (u) (hash-ref u 'alive? #t)) all-seen-opp-u))
             (define alive-opp-b (filter (lambda (b) (hash-ref b 'alive? #t)) all-seen-opp-b))

             (define h130-entry (assoc 130 fut-horizons-alist))
             (define h130-syms (if h130-entry (second h130-entry) fut-syms))
             (define standard-lotv-checkpoint?
               (ormap (lambda (s) (not (eq? (unit-to-archetype s) 'early-rush)))
                      (append fut-syms h130-syms (map (lambda (u) (hash-ref u 'type 'unknown)) alive-opp-u))))

             (when standard-lotv-checkpoint?
               ;; 1. Fog-of-War Causal Online Multi-Depth Update in Racket
               (when (and prev-nodes (or (not (null? alive-opp-u)) (not (null? alive-opp-b))))
                 (define step-scores
                   (score-depth-predictions prev-nodes
                                            alive-opp-u
                                            #:past-enemy-units prev-enemy-units
                                            #:current-enemy-bldgs alive-opp-b
                                            #:transition-bonus 3.0))
                 (define max-s (apply max 0.0 (hash-values step-scores)))
                 (define min-s (apply min 1.0 (hash-values step-scores)))
                 (define alpha (if (> (- max-s min-s) 0.15) 0.55 0.30))
                 (for ([d (in-list '(0 1 2 3 4 5))])
                   (define s (hash-ref step-scores d 0.0))
                   (define old-a (hash-ref online-acc d 0.60))
                   (hash-set! online-acc d (+ (* (- 1.0 alpha) old-a) (* alpha s)))))

               ;; 2. Run Shadow Ledger, Implied Tech, Zero-Sum Exclusions & Reachability Cone
               (define ledger
                 (compute-opponent-shadow-ledger mstate frame all-seen-opp-u all-seen-opp-b
                                                 #:enemy-workers-killed opp-wk))
               (define _reading
                 (interpret-opponent-actions mstate frame alive-opp-u alive-opp-b ledger))
               (define tech-obs (mirror-mind-state-last-tech-observation mstate))
               (define zs-reading
                 (evaluate-zero-sum-negative-exclusions frame alive-opp-u alive-opp-b tech-obs ledger))
               (set-mirror-mind-state-last-zero-sum-reading! mstate zs-reading)

               (define reach-model
                 (evaluate-enemy-army-spatio-temporal-reachability
                  frame ally-units alive-opp-u tech-obs ledger #:lookahead-sec 15.0))
               (set-mirror-mind-state-last-reachability-model! mstate reach-model)

               (define reach-valid? (and (> tcx10 0) (not (null? alive-opp-u))))
               (define reach-hit?
                 (if reach-valid?
                     (let* ([tcx (quotient tcx10 10)]
                            [tcy (quotient tcy10 10)]
                            [scx (/ (for/sum ([u (in-list alive-opp-u)]) (hash-ref u 'x 100))
                                    (max 1.0 (exact->inexact (length alive-opp-u))))]
                            [scy (/ (for/sum ([u (in-list alive-opp-u)]) (hash-ref u 'y 100))
                                    (max 1.0 (exact->inexact (length alive-opp-u))))]
                            [most-recent-gl (apply max (map (lambda (u) (hash-ref u 'last-seen-gl frame)) alive-opp-u))]
                            [age-s (max 0.0 (/ (- frame most-recent-gl) 22.4))]
                            [v-eff (/ (enemy-army-reachability-model-effective-move-speed reach-model) 8.0)]
                            [cone-r (+ 22.0 (* v-eff (min 40.0 (+ age-s 8.0))))]
                            [dist (dist2d scx scy tcx tcy)])
                       (<= dist cone-r))
                     #f))

               ;; 3. Build Recursive Depth Hierarchy (d = 0..5) & Select Active Depth d*
               (define eff-online-acc (hash-copy online-acc))
               (when (or (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)
                         (>= (shadow-ledger-unaccounted-gas ledger) 125)
                         (and (>= frame 2200) (<= (length alive-opp-u) 3)))
                 (for ([d (in-list '(1 2 3 4 5))])
                   (hash-update! eff-online-acc d (lambda (v) (+ v (if (memq d '(2 4)) 0.08 0.05))))))
               (define active-d
                 (choose-optimal-mirror-depth mstate #:depth-accuracy-scores eff-online-acc))
               (define obs
                 (hash 'frame frame
                       'ally-units ally-units
                       'ally-buildings ally-bldgs
                       'enemy-units alive-opp-u
                       'enemy-buildings alive-opp-b))
               (define nodes
                 (build-mirror-hierarchy mstate obs #:max-depth 5))

               (hash-set! perspective-states p-key
                          (hash 'mstate mstate
                                'online-acc online-acc
                                'prev-nodes nodes
                                'prev-enemy-units alive-opp-u))

               ;; 4. Record Shadow Economy MAE
               (when (> true-min 0)
                 (define old-w (min 66 (+ 12 (quotient frame 268))))
                 (define old-m (exact-round (+ 1050.0 (* frame (/ (+ 12.0 old-w) 2.0) 0.036))))
                 (define old-g (exact-round (* (max 0 (- frame 700)) 0.19)))
                 (set! old-w-errs (cons (abs (- old-w true-w)) old-w-errs))
                 (set! cal-w-errs (cons (abs (- (shadow-ledger-predicted-enemy-workers ledger) true-w)) cal-w-errs))
                 (set! old-m-errs (cons (abs (- old-m true-min)) old-m-errs))
                 (set! cal-m-errs (cons (abs (- (shadow-ledger-expected-minerals ledger) true-min)) cal-m-errs))
                 (set! old-g-errs (cons (abs (- old-g true-gas)) old-g-errs))
                 (set! cal-g-errs (cons (abs (- (shadow-ledger-expected-gas ledger) true-gas)) cal-g-errs)))

               (define target-cohorts
                 (append (list cohort-str "all")
                         (if (member cohort-str '("pro_tournament" "pro_corpus")) '("pro_all") '())
                         (if (member cohort-str '("aiarena_ladder" "local_real_matches" "external_gauntlet")) '("bots_all") '())))

               (for ([ck (in-list target-cohorts)])
                 (define cb (hash-ref cohorts ck))
                 (hash-set! (hash-ref cb 'replays) replay-id #t)
                 (hash-set! cb 'checkpoints (add1 (hash-ref cb 'checkpoints)))
                 (when reach-valid?
                   (hash-set! cb 'reach-evals (add1 (hash-ref cb 'reach-evals)))
                   (when reach-hit?
                     (hash-set! cb 'reach-hits (add1 (hash-ref cb 'reach-hits))))))

               ;; 5. Evaluate ALL 8 Horizons: Δt ∈ {15, 30, 45, 60, 75, 90, 105, 130}s
               (define h-snapshots
                 (predict-multi-horizon-snapshots obs mstate HORIZONS))
               (for ([h-sec (in-list HORIZONS)]
                     [snap (in-list h-snapshots)])
                 (define h-entry (assoc h-sec fut-horizons-alist))
                 (define h-syms (if h-entry (second h-entry) fut-syms))
                 (define h-future-units (map (lambda (s) (hash 'type s)) h-syms))

                 (define-values (tb-unit tb-cert)
                   (predict-tree-bayesian-horizon-unit
                    h-sec snap mstate obs nodes active-d eff-online-acc ledger zs-reading))

                 ;; Add synthetic depth node 99 for tree_bayesian so evaluate-causal-depth-prediction-metrics
                 ;; scores it with the EXACT same pure Racket scoring function as d = 0..5 and d*!
                 (define d0-n (first nodes))
                 (define tb-node
                   (depth-node 99
                               (depth-node-opp-belief-about-us d0-n)
                               tb-unit
                               (depth-node-our-response-unit d0-n)
                               'tree-bayesian-horizon-matched
                               (depth-node-tactical-target d0-n)
                               (depth-node-target-x d0-n)
                               (depth-node-target-y d0-n)))
                 (define aug-nodes (append nodes (list tb-node)))
                 (define metrics
                   (evaluate-causal-depth-prediction-metrics aug-nodes
                                                             h-future-units
                                                             alive-opp-u
                                                             #:active-depth active-d))
                 (define transition? (hash-ref metrics 'transition? #f))
                 (define leg-map (hash-ref metrics 'legacy-set))
                 (define cw-map (hash-ref metrics 'causal-weighted))
                 (define tr-map (hash-ref metrics 'transition-pivot))
                 (define cp-map (hash-ref metrics 'counter-payoff))

                 (hash-set! leg-map 'tree_bayesian (hash-ref leg-map 99 0.0))
                 (hash-set! cw-map 'tree_bayesian (hash-ref cw-map 99 0.0))
                 (hash-set! tr-map 'tree_bayesian (hash-ref tr-map 99 0.0))
                 (hash-set! cp-map 'tree_bayesian (hash-ref cp-map 99 0.0))

                 (for ([ck (in-list target-cohorts)])
                   (define cb (hash-ref cohorts ck))
                   (define hb (hash-ref (hash-ref cb 'horizons) h-sec))
                   (hash-set! hb 'evals (add1 (hash-ref hb 'evals)))
                   (hash-set! hb 'certainty-sum (+ (hash-ref hb 'certainty-sum) tb-cert))
                   (when transition?
                     (hash-set! hb 'transitions (add1 (hash-ref hb 'transitions))))
                   (for ([dk (in-list D-KEYS)])
                     (hash-update! (hash-ref hb 'legacy-set) dk (lambda (v) (+ v (hash-ref leg-map dk 0.0))))
                     (hash-update! (hash-ref hb 'causal-weighted) dk (lambda (v) (+ v (hash-ref cw-map dk 0.0))))
                     (when transition?
                       (hash-update! (hash-ref hb 'transition-pivot) dk (lambda (v) (+ v (hash-ref tr-map dk 0.0)))))
                     (hash-update! (hash-ref hb 'counter-payoff) dk (lambda (v) (+ v (hash-ref cp-map dk 0.0))))))))]
            [_ (void)])
          (loop)))))

  (define (format-horizon-json h-sec hb)
    (define ev (max 1 (hash-ref hb 'evals)))
    (define tr (max 1 (hash-ref hb 'transitions)))
    (define (map->pct-hash m denom)
      (for/hash ([dk (in-list D-KEYS)])
        (values (d-key->json-sym dk)
                (round1 (* 100.0 (/ (hash-ref m dk 0.0) denom))))))
    (define cw-pcts (map->pct-hash (hash-ref hb 'causal-weighted) ev))
    (define tr-pcts (map->pct-hash (hash-ref hb 'transition-pivot) tr))
    ;; Find empirical best single fixed depth d in 0..5 for all checkpoints and for transitions
    (define best-fixed-d-all
      (argmax (lambda (d) (hash-ref (hash-ref hb 'causal-weighted) d 0.0)) '(0 1 2 3 4 5)))
    (define best-fixed-d-tr
      (argmax (lambda (d) (hash-ref (hash-ref hb 'transition-pivot) d 0.0)) '(0 1 2 3 4 5)))
    (hash 'horizon_sec h-sec
          'horizon_frames (exact-round (* 22.4 h-sec))
          'checkpoints (hash-ref hb 'evals)
          'transition_checkpoints (hash-ref hb 'transitions)
          'calibrated_certainty_pct (round1 (* 100.0 (/ (hash-ref hb 'certainty-sum) ev)))
          'empirical_best_fixed_depth_all best-fixed-d-all
          'empirical_best_fixed_depth_transitions best-fixed-d-tr
          'legacy_set_accuracy_pct (map->pct-hash (hash-ref hb 'legacy-set) ev)
          'causal_weighted_spend_pct cw-pcts
          'tech_transition_pivot_pct tr-pcts
          'counter_payoff_utility_pct (map->pct-hash (hash-ref hb 'counter-payoff) ev)))

  (define (format-cohort-multi-horizon-json cb)
    (define re (max 1 (hash-ref cb 'reach-evals)))
    (define h-hash (hash-ref cb 'horizons))
    (hash 'replays (hash-count (hash-ref cb 'replays))
          'checkpoints (hash-ref cb 'checkpoints)
          'reachability_cone_accuracy_pct (round1 (* 100.0 (/ (hash-ref cb 'reach-hits) re)))
          'horizons
          (for/hash ([h-sec (in-list HORIZONS)])
            (values (string->symbol (format "h~as" h-sec))
                    (format-horizon-json h-sec (hash-ref h-hash h-sec))))))

  (define all-cb (hash-ref cohorts "all"))
  (define multi-horizon-summary
    (hash 'evaluated_by "Pure Racket #lang sc-bot Multi-Horizon & Build-Order-Tree Bayesian Evaluator"
          'horizons_evaluated_sec HORIZONS
          'total_replays_evaluated (hash-count (hash-ref all-cb 'replays))
          'total_perspective_checkpoints (hash-ref all-cb 'checkpoints)
          'worker_mae_old (round2 (/ (apply + old-w-errs) (max 1 (length old-w-errs))))
          'worker_mae_calibrated (round2 (/ (apply + cal-w-errs) (max 1 (length cal-w-errs))))
          'minerals_mae_old (round1 (/ (apply + old-m-errs) (max 1 (length old-m-errs))))
          'minerals_mae_calibrated (round1 (/ (apply + cal-m-errs) (max 1 (length cal-m-errs))))
          'gas_mae_old (round1 (/ (apply + old-g-errs) (max 1 (length old-g-errs))))
          'gas_mae_calibrated (round1 (/ (apply + cal-g-errs) (max 1 (length cal-g-errs))))
          'cohorts
          (for/hash ([ck (in-list '("all" "pro_all" "aiarena_ladder" "local_real_matches" "pro_corpus" "pro_tournament" "bots_all"))]
                     #:when (> (hash-ref (hash-ref cohorts ck) 'checkpoints) 0))
            (values (string->symbol ck)
                    (format-cohort-multi-horizon-json (hash-ref cohorts ck))))))

  ;; Merge with existing forensic_tactical_telemetry in benchmarks/full_corpus_multi_horizon_report.json
  (define report-path "benchmarks/full_corpus_multi_horizon_report.json")
  (define existing-json
    (if (file-exists? report-path)
        (with-handlers ([exn:fail? (lambda (_) (hash))])
          (call-with-input-file report-path read-json))
        (hash)))
  (define merged-report
    (hash-set (if (hash? existing-json) existing-json (hash))
              'multi_horizon_racket_evaluation
              multi-horizon-summary))
  (call-with-output-file report-path
    #:exists 'replace
    (lambda (out) (write-json merged-report out)))

  (write-json multi-horizon-summary)
  (newline))

(module+ main
  (evaluate-full-corpus-multi-horizon "replays/corpus_checkpoints.sexp"))
