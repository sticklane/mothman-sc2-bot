#lang racket/base

;; =============================================================================
;; Pure Racket `#lang sc-bot` Replay Corpus & Recursive Mirror-Mind Evaluator
;; (`tools/evaluate-replays-racket.rkt`)
;;
;; Evaluates the ACTUAL Racket `#lang sc-bot` brain (`lib/mirror-mind-predictor.rkt`,
;; `lib/econ-ledger.rkt`, `lib/bot-runtime.rkt`, `lib/zerospace-mastermind.rkt`)
;; across the unpacked `.SC2Replay` corpus checkpoints (`replays/corpus_checkpoints.sexp`).
;;
;; All brain modeling, Shadow Economy inference, Implied Tech & Zero-Sum Exclusions,
;; Spatio-Temporal Reachability Cone modeling, Recursive Depth Hierarchy (`d = 0..5`),
;; Fog-of-War Causal Online Multi-Depth Selection (`d*`), and 4-Metric Causal
;; Prediction Scoring execute 100% in Racket using the live bot's own modules!
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/hash
         racket/port
         racket/file
         json
         "../lib/mirror-mind-predictor.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/bot-runtime.rkt"
         "../lib/zerospace-mastermind.rkt")

(define D-KEYS '(0 1 2 3 4 5 d*))

(define (d-key->json-sym dk)
  (case dk
    [(0)  'd0]
    [(1)  'd1]
    [(2)  'd2]
    [(3)  'd3]
    [(4)  'd4]
    [(5)  'd5]
    [(d*) 'd_star]
    [else 'd2]))

(define (sexp-unit->hash u-sexp)
  (match u-sexp
    [(list tag sym x10 y10)
     (hash 'id tag 'type sym 'x (quotient x10 10) 'y (quotient y10 10) 'hp 100 'max-hp 100 'alive? #t)]
    [(list tag sym x10 y10 alive-flag)
     (hash 'id tag 'type sym 'x (quotient x10 10) 'y (quotient y10 10) 'hp 100 'max-hp 100 'alive? (= alive-flag 1))]
    [(list tag sym x10 y10 alive-flag last-gl)
     (hash 'id tag 'type sym 'x (quotient x10 10) 'y (quotient y10 10) 'hp 100 'max-hp 100 'alive? (= alive-flag 1) 'last-seen-gl last-gl)]
    [_ (hash 'id 0 'type 'unknown 'x 100 'y 100 'hp 100)]))

(define (make-cohort-bucket)
  (make-hash
   (list (cons 'replays (make-hash))
         (cons 'evals 0)
         (cons 'transitions 0)
         (cons 'reach-evals 0)
         (cons 'reach-hits 0)
         (cons 'legacy-set (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'causal-weighted (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'transition-pivot (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'counter-payoff (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS))))))

(define (make-player-bucket race cohort)
  (make-hash
   (list (cons 'race (format "~a" race))
         (cons 'cohort cohort)
         (cons 'evals 0)
         (cons 'transitions 0)
         (cons 'legacy-set (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'causal-weighted (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'transition-pivot (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS)))
         (cons 'counter-payoff (make-hash (map (lambda (k) (cons k 0.0)) D-KEYS))))))

(define (round1 x)
  (/ (round (* 10.0 (exact->inexact x))) 10.0))

(define (round2 x)
  (/ (round (* 100.0 (exact->inexact x))) 100.0))

(define (evaluate-corpus-sexp sexp-path)
  (define cohorts (make-hash))
  (for ([ck '("pro_tournament" "pro_corpus" "pro_all" "aiarena_ladder" "external_gauntlet" "bots_all" "all")])
    (hash-set! cohorts ck (make-cohort-bucket)))

  (define players (make-hash))
  ;; Per-(replay, obs-p) persistent Racket `mirror-mind-state` and online accuracy tracker
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
                   ally-u-list ally-b-list opp-u-list opp-b-list fut-syms)
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
             (define standard-lotv-checkpoint?
               (ormap (lambda (s) (not (eq? (unit-to-archetype s) 'early-rush)))
                      (append fut-syms (map (lambda (u) (hash-ref u 'type 'unknown)) alive-opp-u))))
             (when standard-lotv-checkpoint?

             ;; 1. Fog-of-War Causal Online Multi-Depth Update in Racket (`score-depth-predictions`)
             ;;    Compares previous checkpoint's Racket `depth-node` predictions against ONLY the
             ;;    newly observed / newly implied fog-of-war enemy units & tech at `frame`!
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

             ;; 2. Run the REAL Racket `#lang sc-bot` Shadow Ledger & Implied Tech Engine
             (define ledger
               (compute-opponent-shadow-ledger mstate frame all-seen-opp-u all-seen-opp-b
                                               #:enemy-workers-killed opp-wk))
             (define reading
               (interpret-opponent-actions mstate frame alive-opp-u alive-opp-b ledger))
             (define tech-obs (mirror-mind-state-last-tech-observation mstate))
             (define zs-reading
               (evaluate-zero-sum-negative-exclusions frame alive-opp-u alive-opp-b tech-obs ledger))
             (set-mirror-mind-state-last-zero-sum-reading! mstate zs-reading)

             ;; 3. Run the REAL Racket Spatio-Temporal Reachability Cone Model
             (define reach-model
               (evaluate-enemy-army-spatio-temporal-reachability
                frame ally-units alive-opp-u tech-obs ledger #:lookahead-sec 15.0))
             (set-mirror-mind-state-last-reachability-model! mstate reach-model)

             ;; Check reachability cone containment against ground-truth enemy army centroid
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
                          [dist (sqrt (+ (sqr (- tcx scx)) (sqr (- tcy scy))))])
                     (<= dist cone-r))
                   #f))

             ;; 4. Select active online depth `d*` in Racket (`choose-optimal-mirror-depth`)
             ;;    and build the full Racket recursive depth hierarchy (`d = 0..5`)!
             ;;    When dark-matter gas banking or bluffing is detected by the Shadow Ledger,
             ;;    apply a causal transition-readiness boost to deeper depths (`d >= 1`)!
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

             ;; Save state for next checkpoint's causal online update
             (hash-set! perspective-states p-key
                        (hash 'mstate mstate
                              'online-acc online-acc
                              'prev-nodes nodes
                              'prev-enemy-units alive-opp-u))

             ;; 5. Record Shadow Economy MAE (Old uncalibrated vs Racket Calibrated Shadow Ledger)
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

             ;; 6. Score Racket Depth Predictions (`d = 0..5` + `d*`) in Pure Racket across all 4 metrics
             (define future-units
               (map (lambda (s) (hash 'type s)) fut-syms))
             (define metrics
               (evaluate-causal-depth-prediction-metrics nodes
                                                         future-units
                                                         alive-opp-u
                                                         #:active-depth active-d))
             (define transition? (hash-ref metrics 'transition? #f))
             (define leg-map (hash-ref metrics 'legacy-set))
             (define cw-map (hash-ref metrics 'causal-weighted))
             (define tr-map (hash-ref metrics 'transition-pivot))
             (define cp-map (hash-ref metrics 'counter-payoff))

             (define target-cohorts
               (append (list cohort-str "all")
                       (if (member cohort-str '("pro_tournament" "pro_corpus")) '("pro_all") '())
                       (if (member cohort-str '("aiarena_ladder" "external_gauntlet")) '("bots_all") '())))

             (for ([ck (in-list target-cohorts)])
               (define cb (hash-ref cohorts ck))
               (hash-set! (hash-ref cb 'replays) replay-id #t)
               (hash-set! cb 'evals (add1 (hash-ref cb 'evals)))
               (when transition?
                 (hash-set! cb 'transitions (add1 (hash-ref cb 'transitions))))
               (when reach-valid?
                 (hash-set! cb 'reach-evals (add1 (hash-ref cb 'reach-evals)))
                 (when reach-hit?
                   (hash-set! cb 'reach-hits (add1 (hash-ref cb 'reach-hits)))))
               (for ([dk (in-list D-KEYS)])
                 (hash-update! (hash-ref cb 'legacy-set) dk (lambda (v) (+ v (hash-ref leg-map dk 0.0))))
                 (hash-update! (hash-ref cb 'causal-weighted) dk (lambda (v) (+ v (hash-ref cw-map dk 0.0))))
                 (when transition?
                   (hash-update! (hash-ref cb 'transition-pivot) dk (lambda (v) (+ v (hash-ref tr-map dk 0.0)))))
                 (hash-update! (hash-ref cb 'counter-payoff) dk (lambda (v) (+ v (hash-ref cp-map dk 0.0))))))

             (define pb
               (hash-ref! players opp-name (lambda () (make-player-bucket opp-race cohort-str))))
             (hash-set! pb 'evals (add1 (hash-ref pb 'evals)))
             (when transition?
               (hash-set! pb 'transitions (add1 (hash-ref pb 'transitions))))
             (for ([dk (in-list D-KEYS)])
               (hash-update! (hash-ref pb 'legacy-set) dk (lambda (v) (+ v (hash-ref leg-map dk 0.0))))
               (hash-update! (hash-ref pb 'causal-weighted) dk (lambda (v) (+ v (hash-ref cw-map dk 0.0))))
               (when transition?
                 (hash-update! (hash-ref pb 'transition-pivot) dk (lambda (v) (+ v (hash-ref tr-map dk 0.0)))))
               (hash-update! (hash-ref pb 'counter-payoff) dk (lambda (v) (+ v (hash-ref cp-map dk 0.0))))))]
            [_ (void)])
          (loop)))))

  (define (format-cohort-json cb)
    (define ev (max 1 (hash-ref cb 'evals)))
    (define tr (max 1 (hash-ref cb 'transitions)))
    (define re (max 1 (hash-ref cb 'reach-evals)))
    (define (map->pct-hash m denom)
      (for/hash ([dk (in-list D-KEYS)])
        (values (d-key->json-sym dk)
                (round1 (* 100.0 (/ (hash-ref m dk 0.0) denom))))))
    (hash 'replays (hash-count (hash-ref cb 'replays))
          'checkpoints (hash-ref cb 'evals)
          'transition_checkpoints (hash-ref cb 'transitions)
          'reachability_cone_accuracy_pct (round1 (* 100.0 (/ (hash-ref cb 'reach-hits) re)))
          'legacy_set_accuracy_pct (map->pct-hash (hash-ref cb 'legacy-set) ev)
          'causal_weighted_spend_pct (map->pct-hash (hash-ref cb 'causal-weighted) ev)
          'tech_transition_pivot_pct (map->pct-hash (hash-ref cb 'transition-pivot) tr)
          'counter_payoff_utility_pct (map->pct-hash (hash-ref cb 'counter-payoff) ev)))

  (define sorted-players
    (sort (hash->list players)
          (lambda (a b) (> (hash-ref (cdr a) 'evals) (hash-ref (cdr b) 'evals)))))

  (define top-players-json
    (for/hash ([pair (in-list (take sorted-players (min 60 (length sorted-players))))])
      (define pname (car pair))
      (define pb (cdr pair))
      (define ev (max 1 (hash-ref pb 'evals)))
      (define tr (max 1 (hash-ref pb 'transitions)))
      (define (map->pct-hash m denom)
        (for/hash ([dk (in-list D-KEYS)])
          (values (d-key->json-sym dk)
                  (round1 (* 100.0 (/ (hash-ref m dk 0.0) denom))))))
      (values (string->symbol pname)
              (hash 'race (hash-ref pb 'race)
                    'cohort (hash-ref pb 'cohort)
                    'checkpoints (hash-ref pb 'evals)
                    'transitions (hash-ref pb 'transitions)
                    'legacy_set_pct (map->pct-hash (hash-ref pb 'legacy-set) ev)
                    'causal_weighted_pct (map->pct-hash (hash-ref pb 'causal-weighted) ev)
                    'transition_pivot_pct (map->pct-hash (hash-ref pb 'transition-pivot) tr)
                    'counter_payoff_pct (map->pct-hash (hash-ref pb 'counter-payoff) ev)))))

  (define all-cb (hash-ref cohorts "all"))
  (define summary
    (hash 'evaluated_by "Pure Racket #lang sc-bot Brain (lib/mirror-mind-predictor.rkt + lib/zerospace-mastermind.rkt)"
          'total_replays_evaluated (hash-count (hash-ref all-cb 'replays))
          'total_perspective_checkpoints (hash-ref all-cb 'evals)
          'total_transition_checkpoints (hash-ref all-cb 'transitions)
          'worker_mae_old (round2 (/ (apply + old-w-errs) (max 1 (length old-w-errs))))
          'worker_mae_calibrated (round2 (/ (apply + cal-w-errs) (max 1 (length cal-w-errs))))
          'minerals_mae_old (round1 (/ (apply + old-m-errs) (max 1 (length old-m-errs))))
          'minerals_mae_calibrated (round1 (/ (apply + cal-m-errs) (max 1 (length cal-m-errs))))
          'gas_mae_old (round1 (/ (apply + old-g-errs) (max 1 (length old-g-errs))))
          'gas_mae_calibrated (round1 (/ (apply + cal-g-errs) (max 1 (length cal-g-errs))))
          'cohorts (for/hash ([ck (in-list '("pro_tournament" "pro_corpus" "pro_all" "aiarena_ladder" "external_gauntlet" "bots_all" "all"))]
                              #:when (> (hash-ref (hash-ref cohorts ck) 'evals) 0))
                     (values (string->symbol ck) (format-cohort-json (hash-ref cohorts ck))))
          'top_players top-players-json))

  (call-with-output-file "replays/racket_pro_mirror_perspective_audit.json"
    #:exists 'replace
    (lambda (out) (write-json summary out)))
  (call-with-output-file "replays/pro_mirror_perspective_audit.json"
    #:exists 'replace
    (lambda (out) (write-json summary out)))

  (write-json (hash-remove summary 'top_players))
  (newline))

(module+ main
  (evaluate-corpus-sexp "replays/corpus_checkpoints.sexp"))
