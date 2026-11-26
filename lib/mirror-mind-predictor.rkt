#lang racket/base

;; =============================================================================
;; Layer 1c: Generic Recursive k-Level Mirror-Mind Opponent Predictor
;; (`lib/mirror-mind-predictor.rkt`)
;;
;; Models the opponent as at least as smart and capable as we are using a
;; generic recursive k-level cognitive hierarchy (default depth d = 2):
;;
;;   - Depth 0 (Observational Baseline):
;;       Reacts strictly to currently visible enemy units right now.
;;   - Depth 1 (First-Order Opponent Prediction):
;;       Uses what we know about the OPPONENT (visible units/structures,
;;       zero-supply-block Shadow Economy & Dark-Matter Resource Ledger, and
;;       Action-Lens inverse planning) to predict what the opponent is building
;;       and where they will strike next:
;;         u_opp^(1), tau_opp^(1)  --->  our response u_self^(1)
;;   - Depth 2 (Second-Order Mirror Prediction — Default):
;;       Uses what we know about the OPPONENT and OURSELVES (our own units,
;;       structures, economy, and whether the opponent scouted/engaged us) to
;;       predict THEIR prediction about US (u_self_in_opp_mind^(1)), predicts
;;       how a rational opponent will counter their prediction of us
;;       (u_opp^(2), tau_opp^(2)), and computes our preemptive counter
;;       (u_self^(2), tau_self^(2)).
;;   - Depth k >= 3 (Arbitrary Recursive Depth):
;;       Inductively applies the mutual best-response operator:
;;         Level k predicts the other agent's Level (k-1) prediction and
;;         computes the rational strategic + tactical counter-response.
;;
;; Tracks closed-loop prediction accuracy across depths (d = 1, 2, 3, ...) and
;; dynamically selects the active depth (defaulting to d = 2, stepping down to
;; d = 1 if the opponent plays a non-reactive 1-level script, or escalating to
;; d = 3 against a hyper-reactive opponent when d = 2 accuracy is high).
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/flonum
         racket/fixnum
         racket/string
         racket/performance-hint
         racket/set
         (except-in (rename-in "sc2-common.rkt" [dist2d common-dist2d]) unit-type-sym)
         (only-in "sc2-types.rkt" normalize-known-race)
         "build-orders.rkt"
         "sc2-bayesian.rkt"
         "sc2-game-constants.rkt"
         "sc2-combat-eval.rkt")

(define-inline (unit-type-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(symbol? u) u]
    [(string? u) (string->symbol (string-downcase u))]
    [else 'unknown]))

(define MIRROR-RACE-BY-SYM-HT
  (hasheq
   'probe 'Protoss 'zealot 'Protoss 'stalker 'Protoss 'sentry 'Protoss 'adept 'Protoss
   'high-templar 'Protoss 'dark-templar 'Protoss 'archon 'Protoss 'immortal 'Protoss
   'colossus 'Protoss 'disruptor 'Protoss 'void-ray 'Protoss 'carrier 'Protoss 'tempest 'Protoss
   'mothership 'Protoss 'oracle 'Protoss 'phoenix 'Protoss
   'nexus 'Protoss 'pylon 'Protoss 'gateway 'Protoss 'cybernetics-core 'Protoss
   'photon-cannon 'Protoss 'stargate 'Protoss 'robotics-facility 'Protoss
   'fleet-beacon 'Protoss 'robotics-bay 'Protoss 'templar-archive 'Protoss 'twilight-council 'Protoss
   'scv 'Terran 'marine 'Terran 'marauder 'Terran 'reaper 'Terran 'ghost 'Terran
   'hellion 'Terran 'hellbat 'Terran 'widow-mine 'Terran 'cyclone 'Terran 'siege-tank 'Terran
   'siege-tank-sieged 'Terran 'thor 'Terran 'viking 'Terran 'viking-fighter 'Terran
   'viking-assault 'Terran 'medivac 'Terran 'liberator 'Terran 'raven 'Terran
   'banshee 'Terran 'battlecruiser 'Terran
   'command-center 'Terran 'orbital-command 'Terran 'planetary-fortress 'Terran
   'supply-depot 'Terran 'barracks 'Terran 'barracks-techlab 'Terran
   'factory 'Terran 'factory-techlab 'Terran 'armory 'Terran
   'starport 'Terran 'starport-techlab 'Terran 'fusion-core 'Terran 'bunker 'Terran
   'drone 'Zerg 'zergling 'Zerg 'baneling 'Zerg 'queen 'Zerg 'roach 'Zerg 'ravager 'Zerg
   'hydralisk 'Zerg 'lurker 'Zerg 'mutalisk 'Zerg 'corruptor 'Zerg 'ultralisk 'Zerg
   'brood-lord 'Zerg 'viper 'Zerg 'infestor 'Zerg 'overlord 'Zerg 'overseer 'Zerg
   'hatchery 'Zerg 'lair 'Zerg 'hive 'Zerg
   'spawning-pool 'Zerg 'roach-warren 'Zerg 'hydralisk-den 'Zerg 'lurker-den 'Zerg
   'spire 'Zerg 'greater-spire 'Zerg 'infestation-pit 'Zerg 'ultralisk-cavern 'Zerg))

(provide (struct-out shadow-ledger)
         (struct-out enemy-tech-observation)
         (struct-out zero-sum-exclusion-reading)
         (struct-out attrition-strength-verdict)
         (struct-out enemy-structure-activity)
         (struct-out enemy-army-reachability-model)
         (struct-out action-lens-reading)
         (struct-out depth-node)
         (struct-out mirror-forecast)
         (struct-out diagnostic-probe)
         (struct-out mirror-toolbox-allocation)
         (struct-out build-order-tree-node)
         (struct-out build-order-tree-projection)
         (struct-out bayesian-strategic-priors)
         (struct-out horizon-snapshot-forecast)
         (struct-out mirror-mind-state)
         MIRROR-HORIZON-SNAPSHOTS-SEC
         MIRROR-HORIZON-SNAPSHOTS-FRAMES
         make-mirror-mind-state
         ZERG-BUILD-ORDER-TREE
         TERRAN-BUILD-ORDER-TREE
         PROTOSS-BUILD-ORDER-TREE
         ZERG-BO-NODE-BY-ID
         TERRAN-BO-NODE-BY-ID
         PROTOSS-BO-NODE-BY-ID
         lookup-race-build-order-tree
         lookup-race-bo-node-by-id
         project-player-onto-build-order-tree
         project-self-build-order-tree
         project-opponent-build-order-tree
         compute-bayesian-bluff-posterior
         bayesian-posterior-from-likelihoods
         compute-bayesian-strategic-posteriors
         compute-bayesian-pad-camped-posterior
         compute-bayesian-enemy-turtle-posterior
         horizon-sec->optimal-cognitive-depth
         horizon-sec->calibrated-certainty
         predict-multi-horizon-snapshots
         evaluate-multi-horizon-prediction-curve
         detect-enemy-shimmer-and-burrow-ripples
         evaluate-post-detector-snipe-window
         estimate-enemy-base-depletion-ledger
         unit-resource-cost
         unit-to-archetype
         enemy-unit-hallucination?
         analyze-enemy-structure-activity-and-bluffs
         evaluate-attrition-and-relative-strength
         evaluate-enemy-army-spatio-temporal-reachability
         infer-enemy-implied-tech-and-upgrades
         record-enemy-tech-building-destroyed!
         evaluate-mirror-opportunity-cost-profile
         zero-sum-exclusion-reading-opportunity-cost-profile
         zero-sum-exclusion-reading-commitment-score
         mirror-mind-state-signals-ht
         evaluate-zero-sum-negative-exclusions
         compute-enemy-feasible-tech-and-budget
         compute-opponent-shadow-ledger
         compute-shadow-ledger
         interpret-opponent-actions
         evaluate-mirror-macro-verdict
         predict-at-depth
         build-mirror-hierarchy
         issue-diagnostic-depth-probe!
         record-diagnostic-probe-response!
         evaluate-pending-diagnostic-probes!
         choose-optimal-mirror-depth
         score-depth-predictions
         evaluate-causal-depth-prediction-metrics
         compute-mirror-toolbox-allocation
         infer-mirror-counter-plan
         predict-opponent-tactical-target
         resolve-pending-forecasts!
         select-mirror-trust-mode
         step-mirror-mind-predictor!
         mirror-classify-enemy-archetype
         counter-unit-for-archetype
         counter-unit-for-race
         attribute-counter-unit-for-enemy
         archetype-signature-unit
         compute-calibrated-win-prob
         compute-calibrated-snowball-adv)

;; =============================================================================
;; 1. Unit & Structure Cost Lookup (Single-Source via `lib/sc2-game-constants.rkt`)
;; =============================================================================
;; Phase 1 (`#1618`): Collapsed the former hardcoded cost table onto live-hydrated
;; `sc2-unit-total-cost-pair` in `lib/sc2-game-constants.rkt`.

(define DEFAULT-UNIT-COST (cons 100 25))
(define ZERO-COST (cons 0 0))
(define DEFAULT-UPG-COST (cons 100 100))

(define (unit-resource-cost unit-sym)
  (sc2-unit-total-cost-pair unit-sym DEFAULT-UNIT-COST))

(define (safe-frame f)
  (safe-nonneg-int f 0))

(define (safe-coord v [fallback 160])
  (safe-int v fallback))

(define (dist2d x1 y1 x2 y2)
  (if (and (real? x1) (= (- x1 x1) 0)
           (real? y1) (= (- y1 y1) 0)
           (real? x2) (= (- x2 x2) 0)
           (real? y2) (= (- y2 y2) 0))
      (let ([dx (- (exact->inexact x2) (exact->inexact x1))]
            [dy (- (exact->inexact y2) (exact->inexact y1))])
        (sqrt (+ (* dx dx) (* dy dy))))
      (common-dist2d x1 y1 x2 y2 32.0 160.0)))

;; =============================================================================
;; 2. Structs for Shadow Economy, Action Lens, Depth Nodes & Mirror-Mind State
;; =============================================================================

(struct shadow-ledger
  (expected-minerals
   expected-gas
   accounted-minerals
   accounted-gas
   unaccounted-minerals
   unaccounted-gas
   estimated-workers
   dark-matter-hypothesis
   predicted-enemy-bases
   predicted-enemy-workers
   mirror-macro-verdict)
  #:transparent)

(struct enemy-tech-observation
  (observed-upgrades
   implied-tech-buildings
   active-research-buildings
   max-enemy-atk-upgrade
   max-enemy-arm-upgrade
   max-enemy-shd-upgrade
   enemy-upgrade-advantage
   requires-detection?
   requires-anti-air?
   implied-tech-minerals
   implied-tech-gas
   observed-spells
   crippled-tech-buildings)
  #:transparent)

(struct zero-sum-exclusion-reading
  (committed-primary-branch
   excluded-tech-branches
   bluff-or-feint-suspected?
   remaining-gas-budget
   confidence-score
   rationale)
  #:transparent)

(struct attrition-strength-verdict
  (our-lost-value
   enemy-lost-value
   trade-efficiency-ratio
   relative-army-ratio
   recommended-action
   opponent-eco-min-rate
   opponent-eco-gas-rate)
  #:transparent)

(struct enemy-structure-activity
  (in-progress-buildings
   active-research-buildings
   inferred-active-upgrades
   research-under-attack?
   canceled-research-status
   fake-build-bluffs
   previewed-units
   bluff-or-feint-suspected?)
  #:transparent)

(struct enemy-army-reachability-model
  (seen-army-supply
   unaccounted-army-supply
   effective-move-speed
   eta-to-our-main-sec
   eta-to-our-natural-sec
   eta-to-enemy-exposed-base-sec
   reachable-threat-at-our-base-in-n-sec
   recommended-spatial-maneuver)
  #:transparent)

(struct action-lens-reading
  (opponent-scouted-us?
   feint-or-poke-detected?
   opponent-turtling?
   early-gas-commitment?
   missing-natural-expansion?
   proxy-or-rush-detected?
   inferred-intent)
  #:transparent)

;; Represents the prediction produced at recursive depth `depth`:
;;   - depth = 0: Direct observation of opponent -> our direct counter
;;   - depth = 1: What we predict the opponent will do given what we know about
;;                them -> our counter to that prediction
;;   - depth = 2: What we predict the opponent predicts about US (given what
;;                they know about us and themselves), how they will counter our
;;                predicted plan -> our counter to their counter
;;   - depth = k: k-th order recursive belief & counter-response
(struct depth-node
  (depth
   opp-belief-about-us       ; symbol: what opponent thinks we are doing at depth k-1
   predicted-enemy-unit      ; symbol: what opponent builds at depth k
   our-response-unit         ; symbol: what we build to counter `predicted-enemy-unit`
   strategic-hypothesis      ; symbol: strategic plan attributed to opponent at depth k
   tactical-target           ; symbol: where opponent strikes at depth k
   target-x                  ; integer
   target-y)                 ; integer
  #:transparent)

(struct mirror-forecast
  (created-frame
   deadline-frame
   depth                     ; integer: which depth (1, 2, 3, ...) generated this forecast
   strategic-hypothesis
   predicted-enemy-unit
   tactical-target
   target-x
   target-y)
  #:transparent)

;; Active Diagnostic Depth-Probe (Foosball Tournament Principle):
;; Best players issue low-cost tests over the course of a match and watch how
;; the opponent responds to infer the opponent's cognitive depth d*:
;;   - 'no-reaction                      -> Opponent is Depth 0/1 (do NOT over-complicate past d=1!)
;;   - 'direct-counter                   -> Opponent is Depth 1 (we play d=2)
;;   - 'second-order-pivot-or-cancel     -> Opponent is Depth 2 (we escalate to d=3)
;;   - 'higher-order-bait-or-double-reverse -> Opponent is Depth 3+ (we escalate to d=4..5!)
(struct diagnostic-probe
  (id
   probe-type                ; 'tech-reveal-probe | 'feint-tempo-probe
   issued-frame
   deadline-frame
   probe-x
   probe-y
   baseline-enemy-arch
   baseline-enemy-x
   baseline-enemy-y)
  #:transparent)

;; Snowball-Bounded Toolbox Allocation (SC2 Snowball Principle):
;; In a snowball game like StarCraft II, cognitive depth is NEVER the primary
;; strategic or tactical determinant — it is strictly another tool in the toolbox
;; (bounded to <= 25% of marginal unit-mix decisions, 0% during crisis defense,
;; and never allowed to override core macro/snowball posture transitions).
(struct mirror-toolbox-allocation
  (lanchester-ratio          ; flonum: (W_self * D_self) / max(1, W_opp * D_opp)
   snowball-state            ; 'crisis-deficit | 'contested-even | 'snowball-advantage
   toolbox-weight            ; flonum in [0.0, 0.25] (strictly capped at 0.25)
   primary-macro-weight      ; flonum in [0.75, 1.00] (= 1.0 - toolbox-weight)
   toolbox-role              ; 'survival-fundamentals-only | 'snowball-watchtower-only | 'depth1-direct-counter-only | 'marginal-toolbox-hedge
   allow-unit-hedge?         ; boolean: #t only when toolbox-weight >= 0.12
   allow-posture-override?)  ; boolean: ALWAYS #f (depth never overrides SC2 macro/snowball posture)
  #:transparent)

;; Canonical `build-order-tree-node` struct is imported from `lib/build-orders.rkt` (`lib/sc2-types.rkt`).

;; Projection of a player (self or opponent) onto the Race Build-Order Tree Space T_R
(struct build-order-tree-projection
  (perspective
   race
   active-node-id
   branch-posteriors
   reachable-branch-ids
   immediately-producible-units
   horizon-reachable-units
   horizon-reachable-tech-buildings
   predicted-primary-unit
   recommended-next-build-step)
  #:transparent)

;; `bayesian-strategic-priors` is provided by `lib/sc2-types.rkt` / `lib/sc2-bayesian.rkt`.

;; Multi-Horizon Future Snapshot Forecast (15s / 30s / 45s / 60s / 75s / 90s / 105s / 130s)
(define MIRROR-HORIZON-SNAPSHOTS-SEC '(15 30 45 60 75 90 105 130))
(define MIRROR-HORIZON-SNAPSHOTS-FRAMES '(336 672 1008 1344 1680 2016 2352 2912))

(struct horizon-snapshot-forecast
  (horizon-sec
   horizon-frames
   optimal-depth
   certainty-level
   predicted-enemy-unit
   predicted-enemy-archetype
   our-counter-unit
   reachable-units
   dominant-branch-id)
  #:transparent)

(struct mirror-mind-state
  (our-race
   enemy-race
   default-depth             ; integer (usually 2)
   active-depth              ; integer (dynamically chosen depth, 1..5+)
   auto-adapt-depth?         ; boolean
   depth-accuracies          ; mutable hash: depth -> flonum in [0.0, 1.0]
   inferred-opponent-depth   ; integer: opponent's estimated depth d* (0..4+), initialized to 1
   diagnostic-probes         ; list of pending diagnostic-probe
   probes-completed          ; integer: number of resolved diagnostic probes
   last-probe-response       ; symbol: 'untested | 'no-reaction | 'direct-counter | 'second-order-pivot-or-cancel | 'higher-order-bait-or-double-reverse
   toolbox-allocation        ; mirror-toolbox-allocation
   seen-enemy-unit-costs     ; mutable hash: id -> (cons min gas)
   seen-enemy-bldg-costs     ; mutable hash: id -> (cons min gas)
   ever-scouted-by-enemy?    ; boolean
   pending-forecasts         ; list of mirror-forecast
   resolved-hits             ; integer
   resolved-total            ; integer
   strategic-accuracy        ; flonum in [0.0, 1.0]
   tactical-accuracy         ; flonum in [0.0, 1.0]
   overall-accuracy          ; flonum in [0.0, 1.0]
   trust-mode                ; 'level2-preemptive-mirror | 'balanced-bayesian-hedged | 'skeptical-observational-fallback
   last-shadow-ledger        ; shadow-ledger
   last-action-reading       ; action-lens-reading
   last-hierarchy            ; list of depth-node for d = 0 .. max-d
   opp-belief-about-us       ; symbol (what opponent predicts we are doing)
   predicted-enemy-unit      ; symbol (opponent unit at active-depth)
   preemptive-counter-unit   ; symbol (our counter unit at active-depth)
   strategic-hypothesis      ; symbol
   tactical-target           ; symbol
   tactical-x                ; integer
   tactical-y                ; integer
   predicted-enemy-bases     ; integer: estimated active + imminent enemy TownHalls
   predicted-enemy-workers   ; integer: estimated active enemy harvesters
   mirror-macro-verdict      ; symbol: 'punish-And-Deny-Greedy-Expand | 'out-Expand-Passive-Turtle | 'defend-All-In-Then-Counter-Expand | 'pace-Macro-And-Disrupt
   recommended-min-bases     ; integer: recommended minimum bases for us
   disruption-priority       ; symbol: disruption priority directive
   last-tech-observation     ; enemy-tech-observation
   last-zero-sum-reading     ; zero-sum-exclusion-reading
   last-reachability-model   ; enemy-army-reachability-model
   destroyed-enemy-bldgs     ; list of symbols: destroyed enemy tech building types
   pre-destruction-unit-ids) ; list of unit IDs alive at or before tech building destruction
  #:mutable
  #:transparent)

(define (make-mirror-mind-state #:our-race [our-race 'Zerg]
                                #:enemy-race [enemy-race 'Terran]
                                #:depth [depth 2]
                                #:auto-adapt-depth? [auto-adapt-depth? #t])
  (define d-acc (make-hash (list (cons 0 0.60)
                                 (cons 1 0.64)
                                 (cons 2 0.68)
                                 (cons 3 0.62)
                                 (cons 4 0.58)
                                 (cons 5 0.55))))
  (mirror-mind-state
   our-race
   enemy-race
   depth
   depth
   auto-adapt-depth?
   d-acc
   1
   '()
   0
   'untested
   (mirror-toolbox-allocation 1.0 'contested-even 0.18 0.82 'marginal-toolbox-hedge #t #f)
   (make-hash)
   (make-hash)
   #f
   '()
   2
   3
   0.68
   0.66
   0.67
   'level2-preemptive-mirror
   (shadow-ledger 1000 0 1000 0 0 0 12 'accounted-visible-macro 1 12 'pace-Macro-And-Disrupt)
   (action-lens-reading #f #f #f #f #f #f 'standard-rational-macro)
   '()
   'roach-ravager
   'marine
   'baneling
   'standard-rational-macro
   'center-map-staging
   100
   100
   1
   12
   'pace-Macro-And-Disrupt
   2
   'patrol-and-burrow-block-expansions
   (enemy-tech-observation '() '() '() 0 0 0 0 #f #f 0 0 '() '())
   (zero-sum-exclusion-reading 'uncommitted '() #f 0 0.50 'no-tech-branch-observed-yet)
   (enemy-army-reachability-model 0 0 4.2 30.0 20.0 5.0 0 'safe-to-expand-enemy-pinned-far)
   '()
   '()))

(define (record-enemy-tech-building-destroyed! mstate bldg-type [current-enemy-units '()]
                                               #:bldg-id [bldg-id #f])
  ;; 1. Sunk cost is NEVER erased from the opponent's shadow ledger when a building dies
  (define bldg-costs (mirror-mind-state-seen-enemy-bldg-costs mstate))
  (define key (or bldg-id (cons 'sunk-destroyed bldg-type)))
  (hash-set! bldg-costs key (unit-resource-cost bldg-type))
  ;; 2. Record destroyed building type
  (define cur-destroyed (mirror-mind-state-destroyed-enemy-bldgs mstate))
  (unless (memq bldg-type cur-destroyed)
    (set-mirror-mind-state-destroyed-enemy-bldgs!
     mstate (append cur-destroyed (list bldg-type))))
  ;; 3. Snapshot all currently known enemy unit IDs so surviving pre-existing units
  ;;    do NOT falsely resurrect the destroyed tech building!
  (define unit-costs (mirror-mind-state-seen-enemy-unit-costs mstate))
  (define known-ids
    (remove-duplicates
     (append (mirror-mind-state-pre-destruction-unit-ids mstate)
             (hash-keys unit-costs)
             (filter-map (lambda (u) (hash-ref u 'id #f))
                         (safe-hash-list current-enemy-units)))))
  (set-mirror-mind-state-pre-destruction-unit-ids! mstate known-ids)
  mstate)

;; =============================================================================
;; 2b. Transitive Implied Tech Tree, Spell/Effect Inference, Tech Destruction
;;     Tracking & Zero-Sum Negative Exclusion / Bluff Detector
;; =============================================================================

(define (implied-prereqs-for-sym sym)
  (case sym
    ;; Zerg
    [(zergling queen spine-crawler spore-crawler spawning-pool)
     '(spawning-pool)]
    [(baneling baneling-nest zergling-Explode)
     '(spawning-pool baneling-nest extractor)]
    [(roach ravager roach-warren roach-burrowed)
     '(spawning-pool roach-warren extractor)]
    [(lair overseer)
     '(spawning-pool lair extractor)]
    [(hydralisk hydralisk-den)
     '(spawning-pool lair hydralisk-den extractor)]
    [(lurker lurker-mp lurker-den lurker-den-mp)
     '(spawning-pool lair hydralisk-den lurker-den extractor)]
    [(mutalisk corruptor spire)
     '(spawning-pool lair spire extractor)]
    [(infestor swarm-host swarm-host-mp infestation-pit)
     '(spawning-pool lair infestation-pit extractor)]
    [(hive viper)
     '(spawning-pool lair infestation-pit hive extractor)]
    [(ultralisk ultralisk-cavern)
     '(spawning-pool lair infestation-pit hive ultralisk-cavern extractor)]
    [(brood-lord broodlord greater-spire)
     '(spawning-pool lair infestation-pit hive spire greater-spire extractor)]
    [(evolution-chamber)
     '(spawning-pool evolution-chamber)]
    ;; Terran
    [(marine reaper bunker orbital-command barracks)
     '(supply-depot barracks)]
    [(marauder barracks-techlab)
     '(supply-depot barracks barracks-techlab refinery)]
    [(ghost ghost-academy)
     '(supply-depot barracks barracks-techlab ghost-academy refinery)]
    [(hellion widow-mine widowmine factory)
     '(supply-depot barracks factory refinery)]
    [(hellbat hellion-tank thor armory)
     '(supply-depot barracks factory armory refinery)]
    [(siege-tank siege-tank-sieged tank cyclone factory-techlab)
     '(supply-depot barracks factory factory-techlab refinery)]
    [(viking viking-fighter medivac liberator starport)
     '(supply-depot barracks factory starport refinery)]
    [(banshee raven starport-techlab)
     '(supply-depot barracks factory starport starport-techlab refinery)]
    [(battlecruiser fusion-core)
     '(supply-depot barracks factory starport starport-techlab fusion-core refinery)]
    [(planetary-fortress missile-turret sensor-tower engineering-bay)
     '(engineering-bay)]
    ;; Protoss
    [(zealot gateway warpgate warp-gate)
     '(pylon gateway)]
    [(stalker sentry adept shield-battery cybernetics-core)
     '(pylon gateway cybernetics-core assimilator)]
    [(photon-cannon forge)
     '(pylon forge)]
    [(observer immortal warp-prism robotics-facility)
     '(pylon gateway cybernetics-core robotics-facility assimilator)]
    [(colossus disruptor robotics-bay robotics-support-bay)
     '(pylon gateway cybernetics-core robotics-facility robotics-bay assimilator)]
    [(phoenix oracle void-ray voidray stargate)
     '(pylon gateway cybernetics-core stargate assimilator)]
    [(carrier tempest mothership fleet-beacon)
     '(pylon gateway cybernetics-core stargate fleet-beacon assimilator)]
    [(twilight-council)
     '(pylon gateway cybernetics-core twilight-council assimilator)]
    [(high-templar archon templar-archive templar-archives)
     '(pylon gateway cybernetics-core twilight-council templar-archive assimilator)]
    [(dark-templar dark-shrine)
     '(pylon gateway cybernetics-core twilight-council dark-shrine assimilator)]
    [else '()]))

(define (upgrade-resource-cost upg-sym)
  (case upg-sym
    [(psi-storm-tech psi-storm)   '(200 . 200)]
    [(neural-parasite)            '(150 . 150)]
    [(extended-thermal-lance)     '(150 . 150)]
    [(lurker-aspect)              '(150 . 150)]
    [(chitinous-plating)          '(150 . 150)]
    [else                         DEFAULT-UPG-COST]))

(define MM-MISSING (gensym 'mm-missing))
(define current-halluc-memo (make-parameter #f))

(define CHANGELING-SYM-SET
  (hasheq 'changeling #t 'changeling-zealot #t 'changeling-marine #t
          'changeling-marine-shield #t 'changeling-zergling #t
          'changeling-zergling-wings #t))

(define (enemy-unit-hallucination-uncached? u)
  (or (eq? (hash-ref u 'hallucination? #f) #t)
      (eq? (hash-ref u 'hallucination #f) #t)
      (let ([raw-dr (hash-ref u 'damage-rate-ratio MM-MISSING)])
        (if (not (eq? raw-dr MM-MISSING))
            (>= (safe-real raw-dr 1.0) 1.6)
            (let ([raw-dm (hash-ref u 'damage-taken-multiplier MM-MISSING)])
              (and (not (eq? raw-dm MM-MISSING))
                   (>= (safe-real raw-dm 1.0) 1.6)))))
      (and (hash-ref u 'attacking? #f)
           (= (safe-real (hash-ref u 'damage-dealt 1.0) 1.0) 0.0))))

(define (enemy-unit-hallucination? u)
  (and (hash? u)
       (let ([memo (current-halluc-memo)])
         (if memo
             (let ([cached (hash-ref memo u MM-MISSING)])
               (if (not (eq? cached MM-MISSING))
                   cached
                   (let ([res (enemy-unit-hallucination-uncached? u)])
                     (hash-set! memo u res)
                     res)))
             (enemy-unit-hallucination-uncached? u)))))

(define (enemy-unit-changeling? u)
  (and (hash? u)
       (or (eq? (hash-ref u 'changeling? #f) #t)
           (hash-has-key? CHANGELING-SYM-SET (unit-type-sym u)))))

(define NON-COMBAT-SCOUT-SYMS
  '(overlord overseer observer larva egg
    changeling changeling-zealot changeling-marine
    changeling-marine-shield changeling-zergling
    changeling-zergling-wings))

(define NON-COMBAT-AND-WORKER-SET
  (for/hasheq ([s (in-list (append NON-COMBAT-SCOUT-SYMS '(drone probe scv mule)))])
    (values s #t)))

(define (enemy-combat-unit? u)
  (and (hash? u)
       (let ([ut (unit-type-sym u)])
         (and (not (hash-has-key? NON-COMBAT-AND-WORKER-SET ut))
              (not (eq? (hash-ref u 'changeling? #f) #t))
              (not (enemy-unit-hallucination? u))))))

(define (inferred-upgrade-for-research-bldg btype)
  (case btype
    [(spawning-pool)                    'zergling-movementspeed]
    [(roach-warren)                     'glial-reconstitution]
    [(baneling-nest)                    'centrifugal-hooks]
    [(hydralisk-den)                    'grooved-spines]
    [(lurker-den lurker-den-mp)         'adaptive-talons]
    [(spire greater-spire)              'zerg-flyer-weapons-1]
    [(infestation-pit)                  'neural-parasite]
    [(ultralisk-cavern)                 'chitinous-plating]
    [(evolution-chamber)                'zerg-ground-weapons-or-carapace]
    [(cybernetics-core)                 'warp-gate-research]
    [(twilight-council)                 'blink-or-charge]
    [(templar-archive templar-archives) 'psi-storm-tech]
    [(robotics-bay robotics-support-bay)'extended-thermal-lance]
    [(fleet-beacon)                     'anion-pulse-crystals-or-flux-vanes]
    [(forge)                            'protoss-ground-weapons-or-shields]
    [(barracks-techlab)                 'stimpack-or-combat-shield]
    [(factory-techlab)                  'infernal-pre-igniter-or-cyclones]
    [(starport-techlab)                 'cloaking-field]
    [(ghost-academy)                    'personal-cloaking]
    [(engineering-bay)                  'terran-infantry-weapons-or-armor]
    [(armory)                           'terran-vehicle-and-ship-plating]
    [else                               #f]))

(define (list-has-chrono-boost? xs)
  (and (list? xs)
       (or (memq 'chrono-boost xs) (memq 'chrono-boost-active xs))))

(define (analyze-enemy-structure-activity-and-bluffs raw-enemy-bldgs)
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define in-prog-rev '())
  (define active-res-rev '())
  (define inferred-upgs-rev '())
  (define res-under-atk? #f)
  (define canceled-res-status 'none)
  (define fake-builds-rev '())
  (define previews-rev '())
  (define bluff? #f)

  (for ([b (in-list enemy-bldgs)])
    (define btype (unit-type-sym b))
    (define raw-prog (hash-ref b 'build-progress MM-MISSING))
    (define prog
      (if (eq? raw-prog MM-MISSING)
          (if (hash-ref b 'under-construction #f) 0.5 1.0)
          (safe-real raw-prog 1.0)))
    (define canceled? (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define hp (safe-real (hash-ref b 'hp 500) 500.0))
    (define max-hp (max 1.0 (safe-real (hash-ref b 'max-hp 500) 500.0)))
    (define under-atk?
      (or (hash-ref b 'under-attack? #f)
          (hash-ref b 'under-attack #f)
          (< hp max-hp)))
    (define chrono?
      (or (hash-ref b 'chrono? #f)
          (hash-ref b 'chrono-boost? #f)
          (let ([sp (hash-ref b 'spells #f)]) (and sp (list-has-chrono-boost? sp)))
          (let ([bf (hash-ref b 'buffs #f)]) (and bf (list-has-chrono-boost? bf)))
          (let ([ef (hash-ref b 'effects #f)]) (and ef (list-has-chrono-boost? ef)))))
    (define active?
      (or chrono?
          (hash-ref b 'active? #f)
          (hash-ref b 'active #f)
          (hash-ref b 'researching? #f)))
    (define res-canceled?
      (or (hash-ref b 'research-canceled? #f)
          (hash-ref b 'research-canceled #f)))
    (define preview
      (hash-ref b 'preview-unit (hash-ref b 'unit-preview #f)))

    ;; 1. Active construction vs Fake-Build Bluff (canceled without being low-HP under attack)
    (cond
      [(and canceled? (or (not under-atk?) (>= (/ hp max-hp) 0.35)))
       (unless (memq btype fake-builds-rev)
         (set! fake-builds-rev (cons btype fake-builds-rev)))
       (set! bluff? #t)]
      [(and (< prog 1.0) (not canceled?))
       (unless (memq btype in-prog-rev)
         (set! in-prog-rev (cons btype in-prog-rev)))])

    ;; 2. Active research, inferred upgrade identity, research under attack, & canceled research
    (cond
      [res-canceled?
       (define inf-upg (inferred-upgrade-for-research-bldg btype))
       (when inf-upg
         (unless (memq inf-upg inferred-upgs-rev)
           (set! inferred-upgs-rev (cons inf-upg inferred-upgs-rev))))
       (if under-atk?
           (set! canceled-res-status 'emergency-research-canceled-under-attack)
           (begin
             (set! canceled-res-status 'fake-research-bluff-canceled)
             (set! bluff? #t)))]
      [(and active? (not canceled?))
       (unless (memq btype active-res-rev)
         (set! active-res-rev (cons btype active-res-rev)))
       (define inf-upg (inferred-upgrade-for-research-bldg btype))
       (when inf-upg
         (unless (memq inf-upg inferred-upgs-rev)
           (set! inferred-upgs-rev (cons inf-upg inferred-upgs-rev))))
       (when under-atk?
         (set! res-under-atk? #t)
         (set! bluff? #f))])

    ;; 3. Stargate / Production Unit Preview (e.g. 'oracle, 'void-ray, 'phoenix, 'carrier)
    (when (and preview (symbol? preview))
      (unless (memq preview previews-rev)
        (set! previews-rev (cons preview previews-rev)))))

  (enemy-structure-activity (reverse in-prog-rev)
                            (reverse active-res-rev)
                            (reverse inferred-upgs-rev)
                            res-under-atk?
                            canceled-res-status
                            (reverse fake-builds-rev)
                            (reverse previews-rev)
                            bluff?))

(define (evaluate-attrition-and-relative-strength
         raw-ally-units
         raw-enemy-units
         #:our-lost-value [raw-our-lost-value 0]
         #:enemy-lost-value [raw-enemy-lost-value 0]
         #:predicted-enemy-bases [raw-predicted-enemy-bases 1]
         #:predicted-enemy-workers [raw-predicted-enemy-workers 16]
         #:observed-enemy-geysers [raw-observed-enemy-geysers 1]
         #:believed-enemy-army-value [raw-believed-enemy-val 0])
  (define ally-units (safe-hash-list raw-ally-units))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define our-lost-value (max 0 (safe-int raw-our-lost-value 0)))
  (define enemy-lost-value (max 0 (safe-int raw-enemy-lost-value 0)))
  (define predicted-enemy-bases (max 1 (safe-int raw-predicted-enemy-bases 1)))
  (define predicted-enemy-workers (max 0 (safe-int raw-predicted-enemy-workers 16)))
  (define observed-enemy-geysers (max 0 (safe-int raw-observed-enemy-geysers 1)))
  (define believed-enemy-val (max 0 (safe-int raw-believed-enemy-val 0)))
  (define noncombat
    '(drone probe scv overlord overseer observer larva egg
      locust locust-mp locustmp locust-flying locust-precursor locustmpprecursor
      broodling broodling-escort auto-turret autoturret mule
      oracle-stasis-trap stasis-ward force-field
      cocoon baneling-cocoon ravager-cocoon lurker-egg brood-lord-cocoon))
  (define (army-val units)
    (for/sum ([u (in-list units)]
              #:when (and (not (memq (unit-type-sym u) noncombat))
                          (not (enemy-unit-hallucination? u))
                          (not (enemy-unit-changeling? u))))
      (define c (unit-resource-cost (unit-type-sym u)))
      (+ (car c) (exact-round (* 1.5 (cdr c))))))
  (define our-val (army-val ally-units))
  (define vis-enemy-val (army-val enemy-units))
  ;; Never hallucinate a decisive army advantage against empty fog (`enemy-units == '()`)
  ;; unless we have actually won a positive attrition trade (`enemy-lost > our-lost + 150`)!
  (define enemy-val
    (cond
      [(> believed-enemy-val vis-enemy-val) believed-enemy-val]
      [(and (null? enemy-units)
            (<= enemy-lost-value (+ our-lost-value 150)))
       (max vis-enemy-val our-val)]
      [else vis-enemy-val]))
  (define trade-eff
    (exact->inexact (/ (+ enemy-lost-value 100.0) (+ our-lost-value 100.0))))
  (define rel-army
    (exact->inexact (/ (+ our-val 100.0) (+ enemy-val 100.0))))
  (define rec-action
    (cond
      [(or (> our-lost-value (+ enemy-lost-value 300))
           (< rel-army 0.75))
       'defend-ramp-and-remake-army]
      [(or (>= rel-army 1.25)
           (and (>= trade-eff 1.4) (>= rel-army 1.0)))
       'press-advantage-attack-or-expand]
      [else
       'expand-and-poke-harass]))
  (define gas-workers
    (min predicted-enemy-workers (* 3 (max 0 observed-enemy-geysers))))
  (define min-workers
    (min (* 16 (max 1 predicted-enemy-bases))
         (max 0 (- predicted-enemy-workers gas-workers))))
  (define opp-min-rate (exact-round (* 58.0 min-workers)))
  (define opp-gas-rate (exact-round (* 54.0 gas-workers)))
  (attrition-strength-verdict our-lost-value
                              enemy-lost-value
                              trade-eff
                              rel-army
                              rec-action
                              opp-min-rate
                              opp-gas-rate))

;; =============================================================================
;; Spatio-Temporal Enemy Army Reachability & Zero-Sum Spatial Conservation Model
;; =============================================================================

(define UNIT-SUPPLY-EST-CACHE (make-hasheq))
(define (unit-supply-est-sym ut)
  (hash-ref! UNIT-SUPPLY-EST-CACHE
             ut
             (lambda ()
               (define c (unit-resource-cost ut))
               (max 1 (quotient (+ (car c) (* 2 (cdr c))) 75)))))

(define (evaluate-enemy-army-spatio-temporal-reachability
         raw-frame
         raw-ally-units
         raw-enemy-units
         [tech-obs #f]
         [ledger #f]
         #:lookahead-sec [raw-lookahead-sec 12.0]
         #:our-base-x [raw-our-base-x 32]
         #:our-base-y [raw-our-base-y 32]
         #:our-nat-x [raw-our-nat-x 50]
         #:our-nat-y [raw-our-nat-y 56]
         #:enemy-exp-x [raw-enemy-exp-x 142]
         #:enemy-exp-y [raw-enemy-exp-y 136])
  (define _frame (safe-frame raw-frame))
  (define ally-units (safe-hash-list raw-ally-units))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define lookahead-sec (max 1.0 (safe-real raw-lookahead-sec 12.0)))
  (define our-base-x (safe-coord raw-our-base-x 32))
  (define our-base-y (safe-coord raw-our-base-y 32))
  (define our-nat-x (safe-coord raw-our-nat-x 50))
  (define our-nat-y (safe-coord raw-our-nat-y 56))
  (define enemy-exp-x (safe-coord raw-enemy-exp-x 142))
  (define enemy-exp-y (safe-coord raw-enemy-exp-y 136))
  (define-values (seen-supply e-cnt ex-sum ey-sum has-transport-or-air? fast-ground?)
    (for/fold ([sup 0] [cnt 0] [sx 0.0] [sy 0.0] [ta? #f] [fg? #f])
              ([u (in-list enemy-units)])
      (define ut (unit-type-sym u))
      (if (and (not (memq ut '(drone probe scv overlord observer larva egg)))
               (not (enemy-unit-hallucination? u))
               (not (enemy-unit-changeling? u)))
          (let ([ux (hash-ref u 'x enemy-exp-x)]
                [uy (hash-ref u 'y enemy-exp-y)])
            (values (+ sup (unit-supply-est-sym ut))
                    (add1 cnt)
                    (+ sx (if (flonum? ux) ux (safe-real ux 142.0)))
                    (+ sy (if (flonum? uy) uy (safe-real uy 136.0)))
                    (or ta?
                        (and (memq ut '(medivac warp-prism warp-prism-phasing overlord-transport
                                        mutalisk phoenix oracle banshee viking-fighter
                                        corruptor void-ray nydus-worm nydus-canal))
                             #t))
                    (or fg?
                        (and (memq ut '(zergling adept hellion reaper stalker)) #t))))
          (values sup cnt sx sy ta? fg?))))
  (define-values (our-supply a-cnt ax-sum ay-sum)
    (for/fold ([sup 0] [cnt 0] [sx 0.0] [sy 0.0])
              ([u (in-list ally-units)])
      (define ut (unit-type-sym u))
      (if (not (memq ut '(drone probe scv overlord observer larva egg)))
          (let ([ux (hash-ref u 'x our-nat-x)]
                [uy (hash-ref u 'y our-nat-y)])
            (values (+ sup (unit-supply-est-sym ut))
                    (add1 cnt)
                    (+ sx (if (flonum? ux) ux (safe-real ux 50.0)))
                    (+ sy (if (flonum? uy) uy (safe-real uy 56.0)))))
          (values sup cnt sx sy))))

  ;; Zero-Sum Spatial Conservation: every unit seen at (x, y) is ALREADY accounted for in
  ;; `seen-enemy-unit-costs` inside `ledger`, so it reduces `unaccounted-minerals` and
  ;; CANNOT simultaneously be in fog-of-war elsewhere!
  (define unaccounted-supply
    (if (shadow-ledger? ledger)
        (max 0 (quotient (max 0 (- (shadow-ledger-unaccounted-minerals ledger)
                                   (* 45 seen-supply)))
                         50))
        0))

  (define obs-upgrades
    (if (enemy-tech-observation? tech-obs)
        (enemy-tech-observation-observed-upgrades tech-obs)
        '()))
  (define obs-spells
    (if (enemy-tech-observation? tech-obs)
        (enemy-tech-observation-observed-spells tech-obs)
        '()))

  ;; Base speed in SC2 map tiles/sec (~4.2 tiles per second baseline, scaled by
  ;; unit mobility, speed upgrades, Stimpack, Blink, Medivac/Warp-Prism boost, or Nydus/Recall)
  (define has-speed-upgrade?
    (or (ormap (lambda (u)
                 (memq u '(zergling-movementspeed stimpack charge blink glial-reconstitution
                           anabolic-synthesis muscular-augments)))
               obs-upgrades)
        (ormap (lambda (s) (memq s '(stimpack blink charge medivac-boost)))
               obs-spells)))

  (define eff-speed
    (* 4.2
       (if has-transport-or-air? 1.55 (if fast-ground? 1.25 1.0))
       (if has-speed-upgrade? 1.35 1.0)))

  (define-values (ex ey)
    (if (= e-cnt 0)
        (values (safe-real enemy-exp-x 142.0) (safe-real enemy-exp-y 136.0))
        (let ([inv (/ 1.0 (exact->inexact e-cnt))])
          (values (* ex-sum inv) (* ey-sum inv)))))

  (define-values (ax ay)
    (if (= a-cnt 0)
        (values (safe-real our-nat-x 50.0) (safe-real our-nat-y 56.0))
        (let ([inv (/ 1.0 (exact->inexact a-cnt))])
          (values (* ax-sum inv) (* ay-sum inv)))))

  (define dist dist2d)

  ;; Ground detour factor (1.0 for air/drop/blink, 1.18 for ground terrain pathing)
  (define path-factor (if has-transport-or-air? 1.0 1.18))
  (define eta-main
    (if (= e-cnt 0)
        25.0
        (/ (* path-factor (dist ex ey our-base-x our-base-y)) eff-speed)))
  (define eta-nat
    (if (= e-cnt 0)
        20.0
        (/ (* path-factor (dist ex ey our-nat-x our-nat-y)) eff-speed)))
  (define eta-enemy-exp
    (if (= e-cnt 0)
        8.0
        (/ (* path-factor (dist ex ey enemy-exp-x enemy-exp-y)) eff-speed)))
  (define our-eta-to-enemy-exp
    (/ (* 1.1 (dist ax ay enemy-exp-x enemy-exp-y)) 4.75))
  (define dist-ally-to-enemy (dist ax ay ex ey))

  (define reachable-threat-in-n
    (+ (if (<= (min eta-main eta-nat) lookahead-sec) seen-supply 0)
       (if (>= unaccounted-supply 8) (quotient unaccounted-supply 2) 0)))

  (define maneuver
    (cond
      ;; 1. Enemy cluster is close & smaller/isolated while unaccounted supply is low -> Surround & Crush!
      [(and (> seen-supply 0)
            (>= our-supply (max 2 (exact-round (* 1.25 seen-supply))))
            (<= dist-ally-to-enemy 26.0)
            (<= unaccounted-supply 6))
       'surround-and-crush-isolated-enemy-cluster]
      ;; 2. Enemy army is seen out of position far from their exposed expansion (and cannot reach our base immediately) -> Backstab!
      [(and (>= seen-supply 4)
            (> eta-enemy-exp (+ our-eta-to-enemy-exp 2.5))
            (> eta-nat 8.0))
       'backstab-undefended-enemy-expansion]
      ;; 3. Enemy army can reach our natural/main within lookahead-sec -> Pre-rotate & intercept!
      [(and (> reachable-threat-in-n 0)
            (<= (min eta-main eta-nat) lookahead-sec))
       'pre-rotate-intercept-incoming-threat]
      ;; 4. Enemy army is pinned far away (> 14s ETA to our natural) and unaccounted supply is small -> Safe to expand!
      [(and (> eta-nat 14.0)
            (<= unaccounted-supply 6))
       'safe-to-expand-enemy-pinned-far]
      [else
       'multiprong-rotate-and-pin]))

  (enemy-army-reachability-model
   seen-supply
   unaccounted-supply
   eff-speed
   eta-main
   eta-nat
   eta-enemy-exp
   reachable-threat-in-n
   maneuver))


(define (infer-enemy-implied-tech-and-upgrades
         raw-enemy-units
         raw-enemy-bldgs
         #:our-upgrade-tier [raw-our-upgrade-tier 0]
         #:observed-effects [raw-observed-effects '()]
         #:destroyed-enemy-bldgs [raw-destroyed-enemy-bldgs '()]
         #:pre-destruction-unit-ids [raw-pre-destruction-unit-ids '()]
         #:historical-upgrades [raw-historical-upgrades '()]
         #:historical-implied-buildings [raw-historical-implied-bldgs '()])
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define our-upgrade-tier (safe-int raw-our-upgrade-tier 0))
  (define observed-effects (safe-list raw-observed-effects))
  (define destroyed-enemy-bldgs (safe-list raw-destroyed-enemy-bldgs))
  (define pre-destruction-unit-ids (safe-list raw-pre-destruction-unit-ids))
  (define historical-upgrades (safe-list raw-historical-upgrades))
  (define historical-implied-bldgs (safe-list raw-historical-implied-bldgs))
  (define historical-bldgs '())
  (define post-destruction-bldgs '())
  (define obs-upgrades '())
  (define obs-spells '())
  (define active-res-bldgs '())
  (define seen-hist (make-hasheq))
  (define seen-post (make-hasheq))
  (define seen-upg (make-hasheq))
  (define seen-spell (make-hasheq))
  (define seen-res (make-hasheq))
  (define max-atk 0)
  (define max-arm 0)
  (define max-shd 0)
  (define req-det? #f)
  (define req-aa? #f)
  (define non-transport-starport-evidence? #f)

  (define (add-hist-bldg! b)
    (unless (hash-has-key? seen-hist b)
      (hash-set! seen-hist b #t)
      (set! historical-bldgs (cons b historical-bldgs))))
  (define (add-post-bldg! b)
    (add-hist-bldg! b)
    (unless (hash-has-key? seen-post b)
      (hash-set! seen-post b #t)
      (set! post-destruction-bldgs (cons b post-destruction-bldgs))))
  (define (add-upg! u)
    (unless (hash-has-key? seen-upg u)
      (hash-set! seen-upg u #t)
      (set! obs-upgrades (cons u obs-upgrades))))
  (define (add-spell! s)
    (unless (hash-has-key? seen-spell s)
      (hash-set! seen-spell s #t)
      (set! obs-spells (cons s obs-spells))))
  (define (add-active-res! b)
    (unless (hash-has-key? seen-res b)
      (hash-set! seen-res b #t)
      (set! active-res-bldgs (cons b active-res-bldgs))))

  ;; Completed upgrades persist even if their research building is later destroyed
  (for ([hu (in-list historical-upgrades)])
    (add-upg! hu))
  ;; Scouted tech buildings persist across fog-of-war blackouts unless destroyed
  (define destroyed-ht
    (and (pair? destroyed-enemy-bldgs)
         (for/hasheq ([db (in-list destroyed-enemy-bldgs)]) (values db #t))))
  (define pre-dest-ht
    (and (pair? pre-destruction-unit-ids)
         (for/hasheqv ([uid (in-list pre-destruction-unit-ids)]
                       #:when (exact-integer? uid))
           (values uid #t))))
  (for ([hb (in-list historical-implied-bldgs)]
        #:unless (and destroyed-ht (hash-has-key? destroyed-ht hb)))
    (add-hist-bldg! hb))
  ;; Destroyed buildings still count toward sunk historical tech cost
  (for ([db (in-list destroyed-enemy-bldgs)])
    (add-hist-bldg! db)
    (for ([p (in-list (implied-prereqs-for-sym db))])
      (add-hist-bldg! p)))

  ;; Helper to process a spell / buff / effect symbol
  (define (process-spell-or-effect! sp)
    (add-spell! sp)
    (case sp
      [(psi-storm psionic-storm)
       (for ([p '(pylon gateway cybernetics-core twilight-council templar-archive assimilator)])
         (add-post-bldg! p))
       (add-upg! 'psi-storm-tech)]
      [(fungal-growth neural-parasite)
       (for ([p '(spawning-pool lair infestation-pit extractor)])
         (add-post-bldg! p))
       (add-upg! 'infestor-spell-tech)
       (when (eq? sp 'neural-parasite)
         (add-upg! 'neural-parasite))]
      [(blinding-cloud abduct parasitic-bomb)
       (for ([p '(spawning-pool lair infestation-pit hive extractor)])
         (add-post-bldg! p))
       (add-upg! 'viper-hive-spells)]
      [(lurker-spines)
       (for ([p '(spawning-pool lair hydralisk-den lurker-den extractor)])
         (add-post-bldg! p))
       (add-upg! 'burrow-or-subterranean-tech)
       (set! req-det? #t)]
      [(corrosive-bile)
       (for ([p '(spawning-pool roach-warren extractor)])
         (add-post-bldg! p))]
      [(stimpack-cast stimpack)
       (for ([p '(supply-depot barracks barracks-techlab refinery)])
         (add-post-bldg! p))
       (add-upg! 'stimpack)]
      [(banshee-cloak-cast cloaking-field)
       (for ([p '(supply-depot barracks factory starport starport-techlab refinery)])
         (add-post-bldg! p))
       (add-upg! 'cloaking-field)
       (set! req-det? #t)
       (set! req-aa? #t)]
      [(ghost-emp-or-snipe emp-round snipe tactical-nuke ghost-cloak-cast personal-cloaking)
       (for ([p '(supply-depot barracks barracks-techlab ghost-academy refinery)])
         (add-post-bldg! p))
       (set! req-det? #t)]
      [(scanner-sweep calldown-mule)
       (for ([p '(supply-depot barracks orbital-command)])
         (add-post-bldg! p))]
      [(chrono-boost-active chrono-boost)
       (add-spell! 'chrono-boost-active)]
      [(guardian-shield force-field hallucination hallucination-scout-or-bait)
       (for ([p '(pylon gateway cybernetics-core assimilator)])
         (add-post-bldg! p))]
      [(oracle-revelation pulsar-beam)
       (for ([p '(pylon gateway cybernetics-core stargate assimilator)])
         (add-post-bldg! p))
       (set! req-aa? #t)
       (set! req-det? #t)]
      [(blink-cast blink)
       (for ([p '(pylon gateway cybernetics-core twilight-council assimilator)])
         (add-post-bldg! p))
       (add-upg! 'blink)]
      [(charge-cast charge)
       (for ([p '(pylon gateway cybernetics-core twilight-council assimilator)])
         (add-post-bldg! p))
       (add-upg! 'charge)]
      [(resonating-glaives-cast resonating-glaives)
       (for ([p '(pylon gateway cybernetics-core twilight-council assimilator)])
         (add-post-bldg! p))
       (add-upg! 'resonating-glaives)]))

  ;; 1+2. Single pass over visible enemy units for prereqs, hallucinations, upgrades, spells, cloak/burrow, and air
  (define seen-prereq-utype (make-hasheq))
  (for ([u (in-list enemy-units)])
    (define utype (unit-type-sym u))
    (define uid (and pre-dest-ht (hash-ref u 'id #f)))
    (define pre-existing? (and pre-dest-ht uid (hash-has-key? pre-dest-ht uid)))
    (define add-bldg! (if pre-existing? add-hist-bldg! add-post-bldg!))
    (cond
      [(enemy-unit-hallucination? u)
       (add-spell! 'hallucination-scout-or-bait)
       (for ([p '(pylon gateway cybernetics-core assimilator)])
         (add-post-bldg! p))]
      [(enemy-unit-changeling? u)
       (add-spell! 'enemy-changeling-detected)
       (for ([p '(spawning-pool lair extractor)])
         (add-post-bldg! p))]
      [else
       (unless (and (not pre-existing?) (hash-has-key? seen-prereq-utype utype))
         (unless pre-existing?
           (hash-set! seen-prereq-utype utype #t))
         (define prereqs (implied-prereqs-for-sym utype))
         (when (and (not (eq? utype 'medivac))
                    (memq 'starport prereqs))
           (set! non-transport-starport-evidence? #t))
         (for ([p (in-list prereqs)])
           (add-bldg! p)))

       (define raw-atk (or (hash-ref u 'atk-upg #f) (hash-ref u 'attack-upgrade-level #f)))
       (define raw-arm (or (hash-ref u 'arm-upg #f) (hash-ref u 'armor-upgrade-level #f)))
       (define raw-shd (or (hash-ref u 'shd-upg #f) (hash-ref u 'shield-upgrade-level #f)))
       (define atk (if (exact-integer? raw-atk) (max 0 raw-atk) (if raw-atk (max 0 (safe-int raw-atk 0)) 0)))
       (define arm (if (exact-integer? raw-arm) (max 0 raw-arm) (if raw-arm (max 0 (safe-int raw-arm 0)) 0)))
       (define shd (if (exact-integer? raw-shd) (max 0 raw-shd) (if raw-shd (max 0 (safe-int raw-shd 0)) 0)))
       (define explicit-upgs (hash-ref u 'upgrades '()))
       (define u-spells (hash-ref u 'spells '()))
       (define u-buffs (hash-ref u 'buffs '()))
       (define u-effects (hash-ref u 'effects '()))

       (set! max-atk (max max-atk atk))
       (set! max-arm (max max-arm arm))
       (set! max-shd (max max-shd shd))

       (when (pair? explicit-upgs)
         (for ([eu (in-list explicit-upgs)])
           (add-upg! eu)))
       (when (pair? u-spells)
         (for ([sp (in-list u-spells)]) (process-spell-or-effect! sp)))
       (when (pair? u-buffs)
         (for ([sp (in-list u-buffs)]) (process-spell-or-effect! sp)))
       (when (pair? u-effects)
         (for ([sp (in-list u-effects)]) (process-spell-or-effect! sp)))

       ;; Weapon upgrades
       (when (>= atk 1) (add-upg! 'enemy-weapons-1))
       (when (>= atk 2) (add-upg! 'enemy-weapons-2))
       (when (>= atk 3) (add-upg! 'enemy-weapons-3))
       ;; Armor upgrades
       (when (>= arm 1) (add-upg! 'enemy-armor-1))
       (when (>= arm 2) (add-upg! 'enemy-armor-2))
       (when (>= arm 3) (add-upg! 'enemy-armor-3))
       ;; Shield upgrades
       (when (>= shd 1)
         (add-upg! 'enemy-shields-1)
         (add-bldg! 'forge))
       (when (>= shd 2) (add-upg! 'enemy-shields-2))
       (when (>= shd 3) (add-upg! 'enemy-shields-3))

       ;; Imply upgrade buildings from unit race + upgrade level
       (when (>= (max atk arm) 1)
         (cond
           [(memq utype '(zergling baneling roach ravager hydralisk lurker mutalisk corruptor ultralisk brood-lord))
            (add-bldg! 'evolution-chamber)
            (when (>= (max atk arm) 2) (add-bldg! 'lair))
            (when (>= (max atk arm) 3) (add-bldg! 'hive))]
           [(memq utype '(marine marauder reaper ghost hellion hellbat widow-mine siege-tank siege-tank-sieged thor viking medivac banshee battlecruiser))
            (if (memq utype '(marine marauder reaper ghost))
                (add-bldg! 'engineering-bay)
                (add-bldg! 'armory))
            (when (>= (max atk arm) 2) (add-bldg! 'armory))]
           [(memq utype '(zealot stalker sentry adept immortal colossus archon high-templar dark-templar phoenix void-ray carrier tempest))
            (add-bldg! 'forge)
            (when (>= (max atk arm) 2) (add-bldg! 'twilight-council))]))

       ;; Attribute signatures: Marine Combat Shield (max-hp >= 55), Zergling Speed (> 3.5), Roach Speed (> 2.5)
       (when (and (eq? utype 'marine) (not (hash-has-key? seen-upg 'combat-shield)))
         (define max-hp (safe-real (or (hash-ref u 'max-hp #f) (hash-ref u 'hp 0)) 0.0))
         (when (>= max-hp 55.0)
           (add-upg! 'combat-shield)
           (add-bldg! 'barracks-techlab)))
       (when (and (eq? utype 'zergling) (not (hash-has-key? seen-upg 'zergling-movementspeed)))
         (define spd (safe-real (hash-ref u 'speed 0.0) 0.0))
         (when (> spd 3.5)
           (add-upg! 'zergling-movementspeed)
           (add-bldg! 'spawning-pool)
           (add-bldg! 'extractor)))
       (when (and (eq? utype 'roach) (not (hash-has-key? seen-upg 'glial-reconstitution)))
         (define spd (safe-real (hash-ref u 'speed 0.0) 0.0))
         (when (> spd 2.5)
           (add-upg! 'glial-reconstitution)
           (add-bldg! 'roach-warren)
           (add-bldg! 'lair)))

       ;; Burrow / Cloak / Subterranean detection triggers.
       ;; Exclude non-combat Creep Tumors (`creep-tumor*`) so ZvZ/TvZ/PvZ never panic-build
       ;; static detection or infer burrow tech from routine enemy creep spread!
       (unless (memq utype '(creep-tumor creep-tumor-burrowed creep-tumor-queen))
         (when (or (hash-ref u 'burrowed? #f)
                   (hash-ref u 'burrowed #f)
                   (hash-ref u 'is-burrowed #f)
                   (memq utype '(lurker lurker-mp widow-mine widowmine roach-burrowed zergling-burrowed)))
           (add-upg! 'burrow-or-subterranean-tech)
           (set! req-det? #t))
         (unless (or req-det?
                     (memq utype '(observer observer-siege-mode)))
           (when (or (hash-ref u 'cloaked? #f)
                     (hash-ref u 'cloaked #f)
                     (memq utype '(dark-templar banshee ghost mothership lurker lurker-mp widow-mine widowmine)))
             (set! req-det? #t))))

       ;; Air threat trigger (unit type OR explicit flying? / flying / is-flying flag).
       ;; Exclude ALL non-combat flying units (scouts, detectors, transports, cocoons,
       ;; changelings, flying locusts) so an opening scouting Overlord NEVER permanently
       ;; triggers `requires-anti-air? = #t` / `'air-fleet`!
       (unless (or req-aa?
                   (memq utype '(medivac
                                 overlord overlord-cocoon overlord-transport
                                 transport-overlord-cocoon dropperlord
                                 overseer overseer-siege-mode
                                 observer observer-siege-mode
                                 warp-prism warp-prism-phasing
                                 changeling changeling-zealot changeling-marine
                                 changeling-marine-shield changeling-zergling
                                 changeling-zergling-wings
                                 locust locust-mp locustmp locust-flying locust-mp-flying
                                 locust-precursor locustmpprecursor
                                 broodling broodling-escort
                                 larva egg cocoon baneling-cocoon ravager-cocoon
                                 lurker-egg mule)))
         (when (or (memq utype '(mutalisk corruptor brood-lord broodlord viper
                                 viking viking-fighter liberator liberator-ag banshee raven battlecruiser
                                 phoenix oracle void-ray voidray carrier tempest mothership
                                 colossus))
                   (hash-ref u 'flying? #f)
                   (hash-ref u 'flying #f)
                   (hash-ref u 'is-flying #f))
           (set! req-aa? #t)))]))

  ;; 3. Single pass over enemy buildings for prereqs, previews, active research, Chrono Boost, & detection/AA
  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define btype (unit-type-sym b))
    (when (memq btype '(starport starport-flying starport-techlab starport-tech-lab starport-reactor fusion-core))
      (set! non-transport-starport-evidence? #t))
    (add-post-bldg! btype)
    (for ([p (in-list (implied-prereqs-for-sym btype))])
      (add-post-bldg! p))
    (define preview (or (hash-ref b 'preview-unit #f) (hash-ref b 'unit-preview #f)))
    (when (and preview (symbol? preview))
      (add-spell! preview)
      (for ([p (in-list (implied-prereqs-for-sym preview))])
        (add-post-bldg! p))
      (when (memq preview '(oracle void-ray voidray phoenix carrier tempest mutalisk corruptor banshee battlecruiser))
        (set! req-aa? #t))
      (when (memq preview '(oracle dark-templar banshee lurker))
        (set! req-det? #t)))
    (unless req-aa?
      (when (or (memq btype '(command-center-flying orbital-command-flying
                              barracks-flying factory-flying starport-flying))
                (hash-ref b 'flying? #f)
                (hash-ref b 'flying #f)
                (hash-ref b 'is-flying #f))
        (set! req-aa? #t)))
    (define b-spells (safe-list (hash-ref b 'spells '())))
    (define b-buffs (safe-list (hash-ref b 'buffs '())))
    (define b-effects (safe-list (hash-ref b 'effects '())))
    (define chrono?
      (or (hash-ref b 'chrono? #f)
          (hash-ref b 'chrono-boost? #f)
          (memq 'chrono-boost b-spells)
          (memq 'chrono-boost-active b-spells)
          (memq 'chrono-boost b-buffs)
          (memq 'chrono-boost-active b-buffs)
          (memq 'chrono-boost b-effects)
          (memq 'chrono-boost-active b-effects)))
    (when (pair? b-spells)
      (for ([sp (in-list b-spells)]) (process-spell-or-effect! sp)))
    (when (pair? b-buffs)
      (for ([sp (in-list b-buffs)]) (process-spell-or-effect! sp)))
    (when (pair? b-effects)
      (for ([sp (in-list b-effects)]) (process-spell-or-effect! sp)))
    (when chrono?
      (add-spell! 'chrono-boost-active)
      (add-active-res! btype))
    (define active? (or chrono?
                        (hash-ref b 'active? #f)
                        (hash-ref b 'active #f)
                        (hash-ref b 'researching? #f)))
    (define res-canceled?
      (or (hash-ref b 'research-canceled? #f)
          (hash-ref b 'research-canceled #f)))
    (when (and active?
               (not res-canceled?)
               (memq btype '(forge engineering-bay armory evolution-chamber
                             twilight-council cybernetics-core spawning-pool
                             roach-warren baneling-nest hydralisk-den lurker-den
                             spire greater-spire infestation-pit ultralisk-cavern
                             barracks-techlab factory-techlab starport-techlab
                             ghost-academy fusion-core robotics-bay robotics-support-bay
                             stargate fleet-beacon templar-archive templar-archives dark-shrine)))
      (add-active-res! btype)))

  ;; 3b. Inspect top-level observed-effects (e.g. lurker-spines, psi-storm, corrosive-bile in fog)
  (for ([eff (in-list observed-effects)])
    (define esym
      (cond
        [(symbol? eff) eff]
        [(hash? eff)   (unit-type-sym eff)]
        [else          'none]))
    (process-spell-or-effect! esym))

  ;; 4. Partition destroyed buildings into crippled vs rebuilt / 2nd copy (post-destruction)
  (define crippled-bldgs
    (filter (lambda (db) (not (memq db post-destruction-bldgs)))
            destroyed-enemy-bldgs))
  (define rebuilt-or-second-copy-bldgs
    (filter (lambda (db) (memq db post-destruction-bldgs))
            destroyed-enemy-bldgs))
  (define active-implied-bldgs
    (filter (lambda (b) (not (memq b crippled-bldgs)))
            historical-bldgs))

  (for ([b (in-list active-implied-bldgs)])
    (when (memq b '(dark-shrine ghost-academy lurker-den lurker-den-mp))
      (set! req-det? #t))
    (when (or (memq b '(spire greater-spire fusion-core stargate fleet-beacon starport-techlab))
              (and (eq? b 'starport) non-transport-starport-evidence?))
      (set! req-aa? #t)))

  ;; 5. Compute enemy upgrade advantage & sunk implied tech resource spend
  ;;    Note: Sunk mineral/gas cost uses historical-bldgs PLUS any rebuilt/2nd-copy
  ;;    buildings (destroying a tech building never refunds its 200M/200G cost, and
  ;;    rebuilding or having a 2nd copy costs an additional 200M/200G!).
  (define enemy-tier
    (max (+ max-atk max-arm max-shd)
         (if (not (null? obs-upgrades)) 1 0)))
  (define upg-adv (- enemy-tier our-upgrade-tier))

  (define implied-min
    (+ (for/sum ([b (in-list historical-bldgs)])
         (car (unit-resource-cost b)))
       (for/sum ([b (in-list rebuilt-or-second-copy-bldgs)])
         (car (unit-resource-cost b)))
       (for/sum ([u (in-list obs-upgrades)])
         (car (upgrade-resource-cost u)))))
  (define implied-gas
    (+ (for/sum ([b (in-list historical-bldgs)])
         (cdr (unit-resource-cost b)))
       (for/sum ([b (in-list rebuilt-or-second-copy-bldgs)])
         (cdr (unit-resource-cost b)))
       (for/sum ([u (in-list obs-upgrades)])
         (cdr (upgrade-resource-cost u)))))

  (enemy-tech-observation (reverse obs-upgrades)
                          (reverse active-implied-bldgs)
                          (reverse active-res-bldgs)
                          max-atk
                          max-arm
                          max-shd
                          upg-adv
                          req-det?
                          req-aa?
                          implied-min
                          implied-gas
                          (reverse obs-spells)
                          crippled-bldgs))

;; =============================================================================
;; 2c. Build-Order Tree Space (T_R) for Self & Opponent + Bayesian Priors
;;     (Canonical trees & lookup tables imported/re-exported from `lib/build-orders.rkt`)
;; =============================================================================

(define (extract-clean-unit-syms raw-units)
  (cond
    [(not (list? raw-units)) '()]
    [else
     (for/fold ([acc '()])
               ([u (in-list raw-units)])
       (cond
         [(symbol? u) (cons u acc)]
         [(and (hash? u)
               (not (enemy-unit-hallucination? u))
               (not (enemy-unit-changeling? u)))
          (cons (unit-type-sym u) acc)]
         [else acc]))]))

(define (extract-clean-bldg-syms raw-bldgs)
  (cond
    [(not (list? raw-bldgs)) '()]
    [else
     (for/fold ([acc '()])
               ([b (in-list raw-bldgs)])
       (cond
         [(symbol? b) (cons b acc)]
         [(and (hash? b)
               (not (hash-ref b 'canceled? #f))
               (not (hash-ref b 'canceled #f)))
          (define btype (unit-type-sym b))
          (define norm-b
            (case btype
              [(warp-gate warpgate)     'gateway]
              [(barracks-tech-lab)      'barracks-techlab]
              [(factory-tech-lab)       'factory-techlab]
              [(starport-tech-lab)      'starport-techlab]
              [(templar-archives)       'templar-archive]
              [(lurker-den-mp)          'lurker-den]
              [(robotics-support-bay)   'robotics-bay]
              [else                     btype]))
          (cons norm-b acc)]
         [else acc]))]))

(struct bo-tree-frame-ctx
  (perspective
   norm-race
   tree
   node-by-id
   gas
   unit-syms
   known-bldgs
   gas-bldg-count
   confirmed-node-ids
   crippled-buildings
   excluded-buildings
   node-factors)
  #:transparent)

;; Precompute horizon-independent frame evidence over T_R so multi-horizon sweeps
;; do not recompute unit/building extraction, implied prereqs, and node likelihoods 8-9x per tick.
(define (prepare-bo-tree-frame-context
         perspective
         race
         raw-units
         raw-buildings
         [raw-frame 1800]
         [_raw-minerals 300.0]
         [raw-gas 150.0]
         [raw-gas-bldgs 1]
         [raw-upgrades-or-spells '()]
         #:observed-upgrades [kw-upgrades '()]
         #:crippled-buildings [crippled-buildings '()]
         #:excluded-buildings [excluded-buildings '()])
  (define norm-race (normalize-known-race race))
  (define tree (lookup-race-build-order-tree norm-race))
  (define node-by-id (lookup-race-bo-node-by-id norm-race))
  (define frame (safe-frame raw-frame))
  (define gas (max 0.0 (safe-real raw-gas 150.0)))

  (define unit-syms (extract-clean-unit-syms raw-units))
  (define direct-bldg-syms (extract-clean-bldg-syms raw-buildings))
  (define crippled-ht
    (and (pair? crippled-buildings)
         (for/hasheq ([b (in-list crippled-buildings)]) (values b #t))))
  (define excluded-ht
    (and (pair? excluded-buildings)
         (for/hasheq ([b (in-list excluded-buildings)]) (values b #t))))
  (define unit-sym-ht
    (for/hasheq ([u (in-list unit-syms)]) (values u #t)))
  (define upg-sym-ht (make-hasheq))
  (for ([x (in-list (safe-list raw-upgrades-or-spells))]
        #:when (symbol? x))
    (hash-set! upg-sym-ht x #t))
  (for ([x (in-list (safe-list kw-upgrades))]
        #:when (symbol? x))
    (hash-set! upg-sym-ht x #t))
  (define known-bldg-ht (make-hasheq))
  (define known-bldgs-rev '())
  (define (add-known-bldg! b)
    (unless (or (and crippled-ht (hash-has-key? crippled-ht b))
                (hash-has-key? known-bldg-ht b))
      (hash-set! known-bldg-ht b #t)
      (set! known-bldgs-rev (cons b known-bldgs-rev))))
  (for ([b (in-list direct-bldg-syms)])
    (add-known-bldg! b)
    (for ([p (in-list (implied-prereqs-for-sym b))])
      (add-known-bldg! p)))
  (for ([u (in-list unit-syms)])
    (for ([p (in-list (implied-prereqs-for-sym u))])
      (add-known-bldg! p)))
  (define known-bldgs (reverse known-bldgs-rev))
  (define gas-bldg-count
    (max (safe-int raw-gas-bldgs 0)
         (count (lambda (b) (memq b '(extractor refinery assimilator))) direct-bldg-syms)
         (if (or (hash-has-key? known-bldg-ht 'extractor)
                 (hash-has-key? known-bldg-ht 'refinery)
                 (hash-has-key? known-bldg-ht 'assimilator))
             1
             0)))

  (define confirmed-node-ht (make-hasheq))
  (define confirmed-node-ids
    (for/list ([n (in-list tree)]
               #:when (let* ([sbldgs (build-order-tree-node-step-buildings n)]
                             [u-units (build-order-tree-node-unlocked-units n)]
                             [sig-u (if (null? u-units) #f (first u-units))]
                             [bldg-confirmed?
                              (and (not (null? sbldgs))
                                   (andmap (lambda (b) (hash-has-key? known-bldg-ht b)) sbldgs))]
                             [unit-confirmed?
                              (and sig-u
                                   (not (memq sig-u '(drone scv probe overlord zergling marine zealot)))
                                   (hash-has-key? unit-sym-ht sig-u)
                                   (not (and crippled-ht
                                             (ormap (lambda (b) (hash-has-key? crippled-ht b)) sbldgs))))])
                        (or bldg-confirmed? unit-confirmed?)))
      (define nid (build-order-tree-node-id n))
      (hash-set! confirmed-node-ht nid #t)
      nid))

  (define node-factors
    (for/vector ([n (in-list tree)])
      (define nid (build-order-tree-node-id n))
      (define parent-id (build-order-tree-node-parent-id n))
      (define pbldgs (build-order-tree-node-path-buildings n))
      (define sbldgs (build-order-tree-node-step-buildings n))
      (define u-units (build-order-tree-node-unlocked-units n))
      (define u-upgs (build-order-tree-node-unlocked-upgrades n))
      (define prior-w (max 0.01 (safe-real (build-order-tree-node-prior-weight n) 0.10)))
      (define tree-tier (max 0 (sub1 (length pbldgs))))

      (define step-confirmed? (hash-has-key? confirmed-node-ht nid))
      (define parent-confirmed?
        (or (not parent-id)
            (hash-has-key? confirmed-node-ht parent-id)))
      (define frontier-confirmed?
        (and step-confirmed?
             (not (ormap (lambda (ch-id) (hash-has-key? confirmed-node-ht ch-id))
                         (build-order-tree-node-children-ids n)))))
      (define path-match-count
        (count (lambda (b) (hash-has-key? known-bldg-ht b)) pbldgs))
      (define path-ratio
        (/ (exact->inexact path-match-count) (max 1.0 (exact->inexact (length pbldgs)))))

      (define parent-node (and parent-id (hash-ref node-by-id parent-id #f)))
      (define parent-units (if parent-node (build-order-tree-node-unlocked-units parent-node) '()))
      (define sig-unit-seen?
        (let ([any-diff? (ormap (lambda (u) (not (memq u parent-units))) u-units)])
          (if any-diff?
              (ormap (lambda (su)
                       (and (not (memq su parent-units))
                            (hash-has-key? unit-sym-ht su)))
                     u-units)
              (ormap (lambda (su) (hash-has-key? unit-sym-ht su)) u-units))))
      (define matching-units-count
        (count (lambda (u) (hash-has-key? unit-sym-ht u)) u-units))
      (define matching-upgs-count
        (if (= (hash-count upg-sym-ht) 0)
            0
            (count (lambda (u) (hash-has-key? upg-sym-ht u)) u-upgs)))

      (define crippled-or-excluded?
        (and (or crippled-ht excluded-ht)
             (ormap (lambda (b)
                      (or (and crippled-ht (hash-has-key? crippled-ht b))
                          (and excluded-ht (hash-has-key? excluded-ht b))))
                    sbldgs)))

      (define bldg-lr
        (cond
          [crippled-or-excluded? 0.02]
          [step-confirmed?
           (* 5.5
              (if frontier-confirmed? 2.6 1.0)
              (expt 1.85 (min 4 tree-tier))
              (+ 0.5 path-ratio))]
          [parent-confirmed?
           (* 1.4 (+ 0.4 path-ratio))]
          [else
           (* 0.35 (+ 0.2 path-ratio))]))

      (define unit-upg-lr
        (* (if sig-unit-seen? 5.0 1.0)
           (+ 1.0 (* 0.55 matching-units-count) (* 1.25 matching-upgs-count))))

      (vector nid
              step-confirmed?
              parent-confirmed?
              (* prior-w bldg-lr unit-upg-lr)
              (max 0 (- (build-order-tree-node-min-frame n) frame))
              (build-order-tree-node-step-gas-cost n))))

  (bo-tree-frame-ctx perspective
                     norm-race
                     tree
                     node-by-id
                     gas
                     unit-syms
                     known-bldgs
                     gas-bldg-count
                     confirmed-node-ids
                     crippled-buildings
                     excluded-buildings
                     node-factors))

(define (fast-dedup-syms xs)
  (cond
    [(null? xs) '()]
    [(null? (cdr xs)) xs]
    [else
     (define seen (make-hasheq))
     (define rev '())
     (for ([x (in-list xs)])
       (unless (hash-has-key? seen x)
         (hash-set! seen x #t)
         (set! rev (cons x rev))))
     (reverse rev)]))

(define (fast-dedup-append-map base-xs items item->list)
  (define seen (make-hasheq))
  (define rev '())
  (for ([x (in-list base-xs)])
    (unless (hash-has-key? seen x)
      (hash-set! seen x #t)
      (set! rev (cons x rev))))
  (for ([it (in-list items)])
    (for ([x (in-list (item->list it))])
      (unless (hash-has-key? seen x)
        (hash-set! seen x #t)
        (set! rev (cons x rev)))))
  (reverse rev))

(define BO-CTX-EVAL-CACHE (make-weak-hasheq))
(define BO-CTX-TECH-CACHE (make-weak-hasheq))

(define (evaluate-bo-tree-frame-context ctx raw-horizon-sec)
  (define horizon-sec (exact->inexact (max 5.0 (safe-real raw-horizon-sec 60.0))))
  (define h-cache (hash-ref! BO-CTX-EVAL-CACHE ctx make-hasheqv))
  (hash-ref!
   h-cache
   horizon-sec
   (lambda () (evaluate-bo-tree-frame-context-uncached ctx horizon-sec))))

(define (evaluate-bo-tree-tech-only ctx raw-horizon-sec)
  (define horizon-sec (exact->inexact (max 5.0 (safe-real raw-horizon-sec 60.0))))
  (define h-cache (hash-ref! BO-CTX-TECH-CACHE ctx make-hasheqv))
  (hash-ref!
   h-cache
   horizon-sec
   (lambda ()
     (match-define
       (bo-tree-frame-ctx _p _nr tree node-by-id gas _us known-bldgs gas-bldg-count
                          confirmed-node-ids crippled-buildings excluded-buildings node-factors)
       ctx)
     (define horizon-frames (exact-round (* 22.4 horizon-sec)))
     (define root-id (build-order-tree-node-id (first tree)))
     (define active-node-id
       (cond
         [(and (pair? confirmed-node-ids) (null? (cdr confirmed-node-ids)))
          (car confirmed-node-ids)]
         [else
          (define use-memq? (or (null? confirmed-node-ids) (<= (length confirmed-node-ids) 6)))
          (define confirmed-ht
            (and (not use-memq?)
                 (for/hasheq ([cid (in-list confirmed-node-ids)]) (values cid #t))))
          (define-values (best-id _best-w)
            (for/fold ([bid root-id] [bw -1.0])
                      ([nf (in-vector node-factors)])
              (define nid (vector-ref nf 0))
              (if (or (null? confirmed-node-ids)
                      (if use-memq?
                          (memq nid confirmed-node-ids)
                          (hash-has-key? confirmed-ht nid)))
                  (let* ([step-confirmed? (vector-ref nf 1)]
                         [parent-confirmed? (vector-ref nf 2)]
                         [base-w (vector-ref nf 3)]
                         [frame-gap (vector-ref nf 4)]
                         [s-gas (vector-ref nf 5)]
                         [timing-gas-lr
                          (if step-confirmed?
                              1.0
                              (let ([time-factor
                                     (if (> frame-gap (+ horizon-frames 450))
                                         (exp (/ (- (exact->inexact frame-gap)) 1200.0))
                                         1.0)]
                                    [gas-factor
                                     (cond
                                       [(and (>= s-gas 100) (>= gas 200.0) parent-confirmed?) 2.2]
                                       [(and (> s-gas 0) (= gas-bldg-count 0) (< gas 50.0)) 0.18]
                                       [(>= (+ gas (* horizon-sec 1.6 (max 1 gas-bldg-count))) s-gas) 1.15]
                                       [else 0.45])])
                                (* time-factor gas-factor)))]
                         [w (max 1e-6 (* base-w timing-gas-lr))])
                    (if (> w bw) (values nid w) (values bid bw)))
                  (values bid bw))))
          best-id]))
     (define has-crippled-or-excl? (or (pair? crippled-buildings) (pair? excluded-buildings)))
     (define max-h1-frames (+ horizon-frames 260))
     (define max-gas-limit (+ gas (* horizon-sec 2.0 (max 1 gas-bldg-count)) 50.0))
     (define (node-feasible? hn max-frames check-gas?)
       (and hn
            (or (not has-crippled-or-excl?)
                (not (for/or ([b (in-list (build-order-tree-node-step-buildings hn))])
                       (or (memq b crippled-buildings)
                           (memq b excluded-buildings)))))
            (<= (build-order-tree-node-step-build-frames hn) max-frames)
            (or (not check-gas?)
                (<= (build-order-tree-node-step-gas-cost hn) max-gas-limit))))
     (define seen-id (make-hasheq))
     (define cpa-rev '())
     (hash-set! seen-id active-node-id #t)
     (set! cpa-rev (cons active-node-id cpa-rev))
     (for ([cid (in-list confirmed-node-ids)])
       (unless (hash-has-key? seen-id cid)
         (hash-set! seen-id cid #t)
         (set! cpa-rev (cons cid cpa-rev))))
     (define cpa-ids (reverse cpa-rev))
     (define seen-bldg (make-hasheq))
     (define rev '())
     (define (add-bldg! b)
       (unless (hash-has-key? seen-bldg b)
         (hash-set! seen-bldg b #t)
         (set! rev (cons b rev))))
     (define (add-node-bldgs! rn)
       (for ([b (in-list (build-order-tree-node-path-buildings rn))]) (add-bldg! b))
       (for ([b (in-list (build-order-tree-node-step-buildings rn))]) (add-bldg! b)))
     (for ([b (in-list known-bldgs)]) (add-bldg! b))
     (for ([cid (in-list cpa-ids)])
       (define cn (hash-ref node-by-id cid #f))
       (when cn (add-node-bldgs! cn)))
     (when (> horizon-sec 20.0)
       (define h1-seen (make-hasheq))
       (define h1-feas-rev '())
       (for ([cid (in-list cpa-ids)])
         (define cn (hash-ref node-by-id cid #f))
         (when cn
           (for ([hid (in-list (build-order-tree-node-children-ids cn))])
             (unless (hash-has-key? h1-seen hid)
               (hash-set! h1-seen hid #t)
               (define hn (hash-ref node-by-id hid #f))
               (when (node-feasible? hn max-h1-frames #t)
                 (set! h1-feas-rev (cons hid h1-feas-rev))
                 (unless (hash-has-key? seen-id hid)
                   (hash-set! seen-id hid #t)
                   (add-node-bldgs! hn)))))))
       (when (> horizon-sec 65.0)
         (define max-h2-frames (+ horizon-frames 360))
         (define h2-seen (make-hasheq))
         (for ([h1 (in-list (reverse h1-feas-rev))])
           (define h1n (hash-ref node-by-id h1 #f))
           (when h1n
             (for ([h2 (in-list (build-order-tree-node-children-ids h1n))])
               (unless (hash-has-key? h2-seen h2)
                 (hash-set! h2-seen h2 #t)
                 (define h2n (hash-ref node-by-id h2 #f))
                 (when (node-feasible? h2n max-h2-frames #f)
                   (unless (hash-has-key? seen-id h2)
                     (hash-set! seen-id h2 #t)
                     (add-node-bldgs! h2n)))))))))
     (reverse rev))))

(define (evaluate-bo-tree-frame-context-uncached ctx raw-horizon-sec)
  (match-define
    (bo-tree-frame-ctx perspective
                       norm-race
                       tree
                       node-by-id
                       gas
                       unit-syms
                       known-bldgs
                       gas-bldg-count
                       confirmed-node-ids
                       crippled-buildings
                       excluded-buildings
                       node-factors)
    ctx)
  (define horizon-sec (max 5.0 (safe-real raw-horizon-sec 60.0)))
  (define horizon-frames (exact-round (* 22.4 horizon-sec)))

  (define n-nodes (vector-length node-factors))
  (define id-vec (make-vector n-nodes #f))
  (define w-vec (make-vector n-nodes 0.0))
  (define total-w
    (for/fold ([sum-w 0.0])
              ([i (in-range n-nodes)])
      (define nf (vector-ref node-factors i))
      (define nid (vector-ref nf 0))
      (define step-confirmed? (vector-ref nf 1))
      (define parent-confirmed? (vector-ref nf 2))
      (define base-w (vector-ref nf 3))
      (define frame-gap (vector-ref nf 4))
      (define s-gas (vector-ref nf 5))
      (define timing-gas-lr
        (cond
          [step-confirmed? 1.0]
          [else
           (define time-factor
             (if (> frame-gap (+ horizon-frames 450))
                 (exp (/ (- (exact->inexact frame-gap)) 1200.0))
                 1.0))
           (define gas-factor
             (cond
               [(and (>= s-gas 100) (>= gas 200.0) parent-confirmed?) 2.2]
               [(and (> s-gas 0) (= gas-bldg-count 0) (< gas 50.0))   0.18]
               [(>= (+ gas (* horizon-sec 1.6 (max 1 gas-bldg-count))) s-gas) 1.15]
               [else 0.45]))
           (* time-factor gas-factor)]))
      (define w (exact->inexact (max 1e-6 (* base-w timing-gas-lr))))
      (vector-set! id-vec i nid)
      (vector-set! w-vec i w)
      (+ sum-w w)))
  (define eff-total-w (max 1e-9 total-w))
  (define branch-posteriors
    (for/hasheq ([i (in-range n-nodes)])
      (values (vector-ref id-vec i) (/ (vector-ref w-vec i) eff-total-w))))

  ;; Select active-node-id: highest-posterior confirmed node (or root / highest-posterior node if none confirmed)
  (define root-id (build-order-tree-node-id (first tree)))
  (define-values (active-node-id _best-active-p)
    (if (null? confirmed-node-ids)
        (for/fold ([best-id root-id]
                   [best-p -1.0])
                  ([i (in-range n-nodes)])
          (define cid (vector-ref id-vec i))
          (define p (/ (vector-ref w-vec i) eff-total-w))
          (if (> p best-p)
              (values cid p)
              (values best-id best-p)))
        (for/fold ([best-id root-id]
                   [best-p -1.0])
                  ([cid (in-list confirmed-node-ids)])
          (define p (hash-ref branch-posteriors cid 0.0))
          (if (> p best-p)
              (values cid p)
              (values best-id best-p)))))
  (define active-node (hash-ref node-by-id active-node-id (first tree)))

  ;; Immediately producible units (0-hop: unlocked on confirmed nodes and active node)
  (define seen-id (make-hasheq))
  (define cpa-rev '())
  (hash-set! seen-id active-node-id #t)
  (set! cpa-rev (cons active-node-id cpa-rev))
  (for ([cid (in-list confirmed-node-ids)])
    (unless (hash-has-key? seen-id cid)
      (hash-set! seen-id cid #t)
      (set! cpa-rev (cons cid cpa-rev))))
  (define confirmed-Plus-Active (reverse cpa-rev))

  (define seen-imm (make-hasheq))
  (define imm-rev '())
  (for ([u (in-list (build-order-tree-node-unlocked-units active-node))])
    (unless (hash-has-key? seen-imm u)
      (hash-set! seen-imm u #t)
      (set! imm-rev (cons u imm-rev))))
  (for ([cid (in-list confirmed-Plus-Active)])
    (define cn (hash-ref node-by-id cid #f))
    (when cn
      (for ([u (in-list (build-order-tree-node-unlocked-units cn))])
        (unless (hash-has-key? seen-imm u)
          (hash-set! seen-imm u #t)
          (set! imm-rev (cons u imm-rev))))))
  (define immediately-producible-units (reverse imm-rev))

  ;; Horizon-reachable branches in T_R given horizon-sec (0-hop at 15s, 1-hop at 30-60s, 2-hop at 75-130s)
  (define has-crippled-or-excl? (or (pair? crippled-buildings) (pair? excluded-buildings)))
  (define max-gas-limit (+ gas (* horizon-sec 2.0 (max 1 gas-bldg-count)) 50.0))
  (define (node-feasible? hn max-frames check-gas?)
    (and hn
         (or (not has-crippled-or-excl?)
             (not (for/or ([b (in-list (build-order-tree-node-step-buildings hn))])
                    (or (memq b crippled-buildings)
                        (memq b excluded-buildings)))))
         (<= (build-order-tree-node-step-build-frames hn) max-frames)
         (or (not check-gas?)
             (<= (build-order-tree-node-step-gas-cost hn) max-gas-limit))))
  (define reach-rev cpa-rev)
  (when (> horizon-sec 20.0)
    (define max-h1-frames (+ horizon-frames 260))
    (define h1-seen (make-hasheq))
    (define h1-feas-rev '())
    (for ([cid (in-list confirmed-Plus-Active)])
      (define cn (hash-ref node-by-id cid #f))
      (when cn
        (for ([hid (in-list (build-order-tree-node-children-ids cn))])
          (unless (hash-has-key? h1-seen hid)
            (hash-set! h1-seen hid #t)
            (when (node-feasible? (hash-ref node-by-id hid #f) max-h1-frames #t)
              (set! h1-feas-rev (cons hid h1-feas-rev))
              (unless (hash-has-key? seen-id hid)
                (hash-set! seen-id hid #t)
                (set! reach-rev (cons hid reach-rev))))))))
    (when (> horizon-sec 65.0)
      (define max-h2-frames (+ horizon-frames 360))
      (define h2-seen (make-hasheq))
      (for ([h1 (in-list (reverse h1-feas-rev))])
        (define h1n (hash-ref node-by-id h1 #f))
        (when h1n
          (for ([h2 (in-list (build-order-tree-node-children-ids h1n))])
            (unless (hash-has-key? h2-seen h2)
              (hash-set! h2-seen h2 #t)
              (when (node-feasible? (hash-ref node-by-id h2 #f) max-h2-frames #f)
                (unless (hash-has-key? seen-id h2)
                  (hash-set! seen-id h2 #t)
                  (set! reach-rev (cons h2 reach-rev))))))))))
  (define reachable-branch-ids
    (let ([scored (for/list ([id (in-list (reverse reach-rev))])
                    (cons (hash-ref branch-posteriors id 0.0) id))])
      (map cdr (sort scored (lambda (a b) (> (car a) (car b)))))))

  (define horizon-reachable-units
    (let ([seen (make-hasheq)]
          [rev '()])
      (for ([rid (in-list reachable-branch-ids)])
        (define rn (hash-ref node-by-id rid #f))
        (when rn
          (for ([u (in-list (build-order-tree-node-unlocked-units rn))])
            (unless (hash-has-key? seen u)
              (hash-set! seen u #t)
              (set! rev (cons u rev))))))
      (for ([u (in-list immediately-producible-units)])
        (unless (hash-has-key? seen u)
          (hash-set! seen u #t)
          (set! rev (cons u rev))))
      (reverse rev)))

  (define horizon-reachable-tech-buildings
    (let ([seen (make-hasheq)]
          [rev '()])
      (for ([b (in-list known-bldgs)])
        (unless (hash-has-key? seen b)
          (hash-set! seen b #t)
          (set! rev (cons b rev))))
      (for ([rid (in-list reachable-branch-ids)])
        (define rn (hash-ref node-by-id rid #f))
        (when rn
          (for ([b (in-list (build-order-tree-node-path-buildings rn))])
            (unless (hash-has-key? seen b)
              (hash-set! seen b #t)
              (set! rev (cons b rev))))
          (for ([b (in-list (build-order-tree-node-step-buildings rn))])
            (unless (hash-has-key? seen b)
              (hash-set! seen b #t)
              (set! rev (cons b rev))))))
      (reverse rev)))

  ;; Dominant reachable branch & predicted primary unit
  (define top-reachable-id
    (if (null? reachable-branch-ids) active-node-id (first reachable-branch-ids)))
  (define top-reachable-node
    (hash-ref node-by-id top-reachable-id active-node))
  (define top-unlocked (build-order-tree-node-unlocked-units top-reachable-node))
  (define predicted-primary-unit
    (cond
      [(and (<= horizon-sec 20.0) (not (null? unit-syms)))
       (or (for/first ([u (in-list unit-syms)]
                       #:unless (memq u '(drone scv probe overlord observer larva egg)))
             u)
           (if (null? top-unlocked) 'roach (first top-unlocked)))]
      [(not (null? top-unlocked))
       (first top-unlocked)]
      [(not (null? horizon-reachable-units))
       (first horizon-reachable-units)]
      [else 'roach]))

  ;; Recommended next build step along T_R from active-node
  (define child-ids (build-order-tree-node-children-ids active-node))
  (define best-child-id
    (and (not (null? child-ids))
         (let-values ([(bid _bp)
                       (for/fold ([bid (car child-ids)] [bp (hash-ref branch-posteriors (car child-ids) 0.0)])
                                 ([cid (in-list (cdr child-ids))])
                         (define p (hash-ref branch-posteriors cid 0.0))
                         (if (> p bp) (values cid p) (values bid bp)))])
           bid)))
  (define recommended-next-build-step
    (cond
      [best-child-id
       (define cn (hash-ref node-by-id best-child-id #f))
       (define sb (if cn (build-order-tree-node-step-buildings cn) '()))
       (define first-unbuilt
         (for/first ([b (in-list sb)] #:unless (memq b known-bldgs)) b))
       (cond
         [first-unbuilt first-unbuilt]
         [(not (null? sb)) (first sb)]
         [else (first (build-order-tree-node-step-buildings active-node))])]
      [else
       (first (build-order-tree-node-step-buildings active-node))]))

  (build-order-tree-projection
   perspective
   norm-race
   active-node-id
   branch-posteriors
   reachable-branch-ids
   immediately-producible-units
   horizon-reachable-units
   horizon-reachable-tech-buildings
   predicted-primary-unit
   recommended-next-build-step))

;; Project any player ('self or 'opponent) onto the Race Build-Order Tree Space T_R
;; and compute a normalized Dirichlet-multinomial / Bayesian posterior over branches.
(define (project-player-onto-build-order-tree
         perspective
         race
         raw-units
         raw-buildings
         [raw-frame 1800]
         [raw-minerals 300.0]
         [raw-gas 150.0]
         [raw-gas-bldgs 1]
         [raw-horizon-sec 60.0]
         [raw-upgrades-or-spells '()]
         #:horizon-sec [kw-horizon-sec #f]
         #:observed-upgrades [kw-upgrades '()]
         #:crippled-buildings [crippled-buildings '()]
         #:excluded-buildings [excluded-buildings '()])
  (define ctx
    (prepare-bo-tree-frame-context
     perspective race raw-units raw-buildings
     raw-frame raw-minerals raw-gas raw-gas-bldgs raw-upgrades-or-spells
     #:observed-upgrades kw-upgrades
     #:crippled-buildings crippled-buildings
     #:excluded-buildings excluded-buildings))
  (evaluate-bo-tree-frame-context ctx (or kw-horizon-sec raw-horizon-sec)))

(define (detect-race-from-units-and-bldgs units bldgs fallback-race)
  (or (for/or ([e (in-list (append (safe-list units) (safe-list bldgs)))])
        (define sym (if (symbol? e) e (unit-type-sym e)))
        (case sym
          [(probe zealot stalker sentry adept high-templar dark-templar archon
            immortal colossus void-ray carrier oracle phoenix nexus pylon gateway
            cybernetics-core photon-cannon stargate robotics-facility twilight-council
            templar-archive dark-shrine robotics-bay fleet-beacon assimilator)
           'Protoss]
          [(scv marine marauder reaper ghost hellion widow-mine cyclone siege-tank
            thor viking medivac banshee battlecruiser command-center orbital-command
            planetary-fortress supply-depot barracks factory starport bunker refinery
            engineering-bay armory fusion-core ghost-academy)
           'Terran]
          [(drone zergling baneling queen roach ravager hydralisk lurker mutalisk
            corruptor ultralisk brood-lord overlord overseer hatchery lair hive
            spawning-pool roach-warren baneling-nest hydralisk-den lurker-den spire
            infestation-pit ultralisk-cavern greater-spire extractor)
           'Zerg]
          [else #f]))
      (normalize-known-race fallback-race)))

(define (prepare-self-bo-tree-context raw-obs
                                      #:race [kw-race #f]
                                      #:mstate [mstate #f])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define eff-mstate (if (mirror-mind-state? raw-obs) raw-obs mstate))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define fallback-r
    (or kw-race
        (hash-ref obs 'actual-race (hash-ref obs 'race #f))
        (and eff-mstate (mirror-mind-state-our-race eff-mstate))
        'Zerg))
  (define race (detect-race-from-units-and-bldgs ally-units ally-bldgs fallback-r))
  (define frame (safe-frame (hash-ref obs 'frame 1800)))
  (define minerals (safe-real (hash-ref obs 'minerals 300.0) 300.0))
  (define gas (safe-real (hash-ref obs 'gas 150.0) 150.0))
  (define bldg-syms (extract-clean-bldg-syms ally-bldgs))
  (define gas-bldgs
    (max 1 (count (lambda (b) (memq b '(extractor refinery assimilator))) bldg-syms)))
  (define upgs (safe-list (hash-ref obs 'researched-upgrades '())))
  (prepare-bo-tree-frame-context
   'self race ally-units ally-bldgs frame minerals gas gas-bldgs upgs))

(define (project-self-build-order-tree raw-obs [raw-horizon-sec 60.0]
                                       #:race [kw-race #f]
                                       #:horizon-sec [kw-horizon-sec #f]
                                       #:mstate [mstate #f])
  (define h-sec (or kw-horizon-sec (if (real? raw-horizon-sec) raw-horizon-sec 60.0)))
  (evaluate-bo-tree-frame-context
   (prepare-self-bo-tree-context raw-obs #:race kw-race #:mstate mstate)
   h-sec))

(define (prepare-opponent-bo-tree-context raw-obs
                                          #:enemy-race [kw-race #f]
                                          #:mstate [mstate #f])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define eff-mstate (if (mirror-mind-state? raw-obs) raw-obs mstate))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define fallback-r
    (or kw-race
        (hash-ref obs 'enemy-race #f)
        (and eff-mstate (mirror-mind-state-enemy-race eff-mstate))
        'Terran))
  (define enemy-race (detect-race-from-units-and-bldgs enemy-units enemy-bldgs fallback-r))
  (define frame (safe-frame (hash-ref obs 'frame 1800)))
  (define ledger (and eff-mstate (mirror-mind-state-last-shadow-ledger eff-mstate)))
  (define tech-obs
    (or (and eff-mstate (mirror-mind-state-last-tech-observation eff-mstate))
        (infer-enemy-implied-tech-and-upgrades enemy-units enemy-bldgs)))
  (define zs-reading
    (and eff-mstate (mirror-mind-state-last-zero-sum-reading eff-mstate)))
  (define rem-min
    (if ledger
        (max 150.0 (safe-real (shadow-ledger-unaccounted-minerals ledger) 300.0))
        (safe-real (hash-ref obs 'enemy-minerals 300.0) 300.0)))
  (define rem-gas
    (cond
      [zs-reading (max 50.0 (safe-real (zero-sum-exclusion-reading-remaining-gas-budget zs-reading) 150.0))]
      [ledger     (max 50.0 (safe-real (shadow-ledger-unaccounted-gas ledger) 150.0))]
      [else       (safe-real (hash-ref obs 'enemy-gas 150.0) 150.0)]))
  (define bldg-syms (extract-clean-bldg-syms enemy-bldgs))
  (define gas-bldgs
    (max (if (> rem-gas 0.0) 1 0)
         (count (lambda (b) (memq b '(extractor refinery assimilator))) bldg-syms)))
  (define upgs-and-spells
    (if tech-obs
        (append (enemy-tech-observation-observed-upgrades tech-obs)
                (enemy-tech-observation-observed-spells tech-obs))
        '()))
  (define crippled
    (if tech-obs (enemy-tech-observation-crippled-tech-buildings tech-obs) '()))
  (define bluff?
    (and zs-reading (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)))
  (define excluded-branches
    (if (and zs-reading (not bluff?))
        (zero-sum-exclusion-reading-excluded-tech-branches zs-reading)
        '()))
  (define excluded-bldgs
    (apply append
           (for/list ([br (in-list excluded-branches)])
             (case br
               [(stargate-air-rush fleet-beacon-carriers) '(stargate fleet-beacon)]
               [(colossus-thermal-lance-rush)             '(robotics-bay)]
               [(templar-archive-storm)                   '(templar-archive)]
               [(dark-shrine-dt-rush)                     '(dark-shrine)]
               [(spire-mutalisk-rush early-brood-lord-rush) '(spire greater-spire)]
               [(lurker-den-siege)                        '(lurker-den)]
               [(early-ultralisk-rush)                    '(ultralisk-cavern)]
               [(baneling-flood-bust)                     '(baneling-nest)]
               [(battlecruiser-fusion-rush)               '(fusion-core starport)]
               [(mass-factory-mech-thor)                  '(factory-techlab armory)]
               [(bio-stim-marine-marauder-flood heavy-bio-stim-timing) '(barracks-techlab)]
               [else '()]))))
  (prepare-bo-tree-frame-context
   'opponent enemy-race enemy-units enemy-bldgs frame rem-min rem-gas gas-bldgs upgs-and-spells
   #:crippled-buildings crippled
   #:excluded-buildings excluded-bldgs))

(define (project-opponent-build-order-tree raw-obs [raw-horizon-sec 60.0]
                                           #:enemy-race [kw-race #f]
                                           #:horizon-sec [kw-horizon-sec #f]
                                           #:mstate [mstate #f])
  (define h-sec (or kw-horizon-sec (if (real? raw-horizon-sec) raw-horizon-sec 60.0)))
  (evaluate-bo-tree-frame-context
   (prepare-opponent-bo-tree-context raw-obs #:enemy-race kw-race #:mstate mstate)
   h-sec))

;; `bayesian-posterior-from-likelihoods` and `compute-bayesian-pad-camped-posterior`
;; are provided by `lib/sc2-bayesian.rkt`.

;; Bayesian Bluff Posterior P(bluff | E) with base-rate prior P_0(bluff) = 0.08
(define (compute-bayesian-bluff-posterior
         [raw-enemy-units '()]
         [raw-enemy-bldgs '()]
         [given-tech-obs #f]
         [given-ledger #f]
         #:prior [raw-prior 0.08]
         #:candidate-branch [given-branch #f]
         #:confirmed-commitment? [given-confirmed? 'auto]
         #:opponent-scouted-us? [scouted-us? #f]
         #:enemy-scouted-us? [kw-enemy-scouted-us? #f]
         #:fake-builds [kw-fake-builds '()]
         #:fake-build-bluffs [kw-fake-build-bluffs '()]
         #:canceled-research-status [kw-res-cancel-status #f]
         #:combat-hallucination-bait? [kw-halluc-bait? #f]
         #:idle-bluff-structures [kw-idle-bluffs '()]
         #:remaining-gas [kw-rem-gas #f]
         #:rem-gas [kw-rem-gas2 #f]
         #:active-research-count [kw-active-res-cnt #f]
         #:research-under-attack? [kw-res-under-atk? #f])
  (define-values (enemy-units enemy-bldgs tech-obs ledger)
    (if (hash? raw-enemy-units)
        (let* ([obs raw-enemy-units]
               [eu (safe-hash-list (hash-ref obs 'enemy-units '()))]
               [eb (safe-hash-list (hash-ref obs 'enemy-buildings '()))]
               [to (or given-tech-obs (infer-enemy-implied-tech-and-upgrades eu eb))]
               [lg given-ledger])
          (values eu eb to lg))
        (let* ([eu (safe-hash-list raw-enemy-units)]
               [eb (safe-hash-list raw-enemy-bldgs)]
               [to (or given-tech-obs (infer-enemy-implied-tech-and-upgrades eu eb))])
          (values eu eb to given-ledger))))

  (define struct-act (analyze-enemy-structure-activity-and-bluffs enemy-bldgs))
  (define fake-builds
    (remove-duplicates
     (append (safe-list kw-fake-builds)
             (safe-list kw-fake-build-bluffs)
             (enemy-structure-activity-fake-build-bluffs struct-act))))
  (define res-cancel-status
    (or kw-res-cancel-status
        (enemy-structure-activity-canceled-research-status struct-act)))
  (define res-under-atk?
    (or (and kw-res-under-atk? #t)
        (enemy-structure-activity-research-under-attack? struct-act)))
  (define active-res
    (remove-duplicates
     (append (if (and (number? kw-active-res-cnt) (> kw-active-res-cnt 0))
                 '(active-research)
                 '())
             (enemy-structure-activity-active-research-buildings struct-act)
             (if tech-obs (enemy-tech-observation-active-research-buildings tech-obs) '()))))
  (define previews (enemy-structure-activity-previewed-units struct-act))

  (define HALLUC-BAIT-SET
    (hasheq 'colossus #t 'void-ray #t 'voidray #t 'immortal #t
            'archon #t 'phoenix #t 'oracle #t 'carrier #t))
  (define-values (halluc-bait? has-real-combat?)
    (for/fold ([bait? (and kw-halluc-bait? #t)]
               [combat? #f])
              ([u (in-list enemy-units)])
      (cond
        [(enemy-unit-hallucination? u)
         (values (or bait? (hash-has-key? HALLUC-BAIT-SET (unit-type-sym u)))
                 combat?)]
        [(not combat?)
         (values bait? (enemy-combat-unit? u))]
        [else
         (values bait? #t)])))
  (define combat-hallucination-bait? halluc-bait?)

  (define explicit-idle-bluff-count
    (+ (length (safe-list kw-idle-bluffs))
       (for/sum ([b (in-list enemy-bldgs)])
         (if (and (hash? b)
                  (not (hash-ref b 'canceled? #f))
                  (not (hash-ref b 'canceled #f))
                  (or (eq? (hash-ref b 'active? 'unspecified) #f)
                      (eq? (hash-ref b 'active 'unspecified) #f)
                      (eq? (hash-ref b 'idle-bluff? #f) #t)))
             1
             0))))

  (define rem-gas
    (cond
      [(real? kw-rem-gas)  (safe-real kw-rem-gas 0.0)]
      [(real? kw-rem-gas2) (safe-real kw-rem-gas2 0.0)]
      [(shadow-ledger? ledger) (safe-real (shadow-ledger-unaccounted-gas ledger) 0.0)]
      [else 0.0]))
  (define eff-scouted-us? (or (and scouted-us? #t) (and kw-enemy-scouted-us? #t)))

  (define obs-upgs (if tech-obs (enemy-tech-observation-observed-upgrades tech-obs) '()))
  (define has-obs-spell?
    (and tech-obs
         (for/or ([s (in-list (enemy-tech-observation-observed-spells tech-obs))])
           (not (eq? s 'hallucination-scout-or-bait)))))
  (define has-confirming-evidence?
    (if (boolean? given-confirmed?)
        given-confirmed?
        (or (not (null? active-res))
            res-under-atk?
            (not (null? previews))
            has-real-combat?
            (not (null? obs-upgs))
            has-obs-spell?)))

  (define has-candidate-tech-branch?
    (if given-branch
        (not (eq? given-branch 'uncommitted))
        (or (not (null? enemy-bldgs)) (> explicit-idle-bluff-count 0))))

  (evaluate-bluff-posterior-from-signals
   #:prior (safe-real raw-prior 0.08)
   #:fake-build-count (length fake-builds)
   #:res-cancel-status (if (symbol? res-cancel-status) res-cancel-status 'none)
   #:research-under-attack? (and res-under-atk? #t)
   #:combat-hallucination-bait? (and combat-hallucination-bait? #t)
   #:explicit-idle-bluff-count explicit-idle-bluff-count
   #:active-research-count (length active-res)
   #:preview-count (length previews)
   #:has-confirming-evidence? (and has-confirming-evidence? #t)
   #:has-candidate-tech-branch? (and has-candidate-tech-branch? #t)
   #:remaining-gas rem-gas
   #:enemy-scouted-us? (and eff-scouted-us? #t)))

;; Compute full Bayesian Strategic Priors & Posteriors over bluff, feint, rush,
;; hidden expansion, tech switch, and build-order tree branches.
(define (compute-bayesian-strategic-posteriors
         [raw-obs-or-mstate (hash)]
         [maybe-obs-or-mstate #f]
         [arg3 #f]
         [arg4 #f]
         [arg5 #f]
         [arg6 #f]
         #:our-race [kw-our-race #f]
         #:enemy-race [kw-enemy-race #f]
         #:prior [raw-prior 0.08]
         #:horizon-sec [horizon-sec 60.0]
         #:base-x [base-x 32]
         #:base-y [base-y 32]
         #:nat-x [nat-x 50]
         #:nat-y [nat-y 56]
         #:opp-ctx [pre-opp-ctx #f])
  (define-values (obs mstate pos-tech-obs pos-ledger)
    (cond
      [(and (number? raw-obs-or-mstate) (symbol? maybe-obs-or-mstate))
       (values (hash 'frame raw-obs-or-mstate
                     'enemy-race maybe-obs-or-mstate
                     'enemy-units (or arg3 '())
                     'enemy-buildings (or arg4 '())
                     'base-x base-x 'base-y base-y
                     'natural-x nat-x 'natural-y nat-y)
               #f
               arg5
               arg6)]
      [(and (mirror-mind-state? raw-obs-or-mstate) (hash? maybe-obs-or-mstate))
       (values maybe-obs-or-mstate raw-obs-or-mstate #f #f)]
      [(hash? raw-obs-or-mstate)
       (values raw-obs-or-mstate (and (mirror-mind-state? maybe-obs-or-mstate) maybe-obs-or-mstate) #f #f)]
      [else
       (values (hash) (and (mirror-mind-state? raw-obs-or-mstate) raw-obs-or-mstate) #f #f)]))

  (define frame (safe-frame (hash-ref obs 'frame 1800)))
  (define enemy-units (safe-hash-list (hash-ref obs 'enemy-units '())))
  (define enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '())))
  (define ledger
    (or (and (shadow-ledger? pos-ledger) pos-ledger)
        (and mstate (mirror-mind-state-last-shadow-ledger mstate))
        (shadow-ledger 1500 300 1200 200 300 100 22 'accounted-visible-macro 2 22 'pace-Macro-And-Disrupt)))
  (define tech-obs
    (or (and (enemy-tech-observation? pos-tech-obs) pos-tech-obs)
        (and mstate (mirror-mind-state-last-tech-observation mstate))
        (infer-enemy-implied-tech-and-upgrades enemy-units enemy-bldgs)))
  (define reading
    (and mstate (mirror-mind-state-last-action-reading mstate)))

  (define bluff-prior (max 0.01 (min 0.45 (safe-real raw-prior 0.08))))
  (define bluff-post
    (compute-bayesian-bluff-posterior
     enemy-units enemy-bldgs tech-obs ledger
     #:prior bluff-prior
     #:opponent-scouted-us? (or (and mstate (mirror-mind-state-ever-scouted-by-enemy? mstate))
                                (and reading (action-lens-reading-opponent-scouted-us? reading)))))

  (define rem-min (safe-real (shadow-ledger-unaccounted-minerals ledger) 0.0))
  (define rem-gas (safe-real (shadow-ledger-unaccounted-gas ledger) 0.0))
  (define combat-cnt (count enemy-combat-unit? enemy-units))
  (define opp-proj
    (if pre-opp-ctx
        (evaluate-bo-tree-frame-context pre-opp-ctx horizon-sec)
        (project-opponent-build-order-tree obs horizon-sec
                                           #:enemy-race (or kw-enemy-race (hash-ref obs 'enemy-race #f))
                                           #:mstate mstate)))
  (evaluate-strategic-posteriors-from-signals
   #:bluff-prior bluff-prior
   #:bluff-posterior bluff-post
   #:frame frame
   #:combat-count combat-cnt
   #:unaccounted-minerals rem-min
   #:unaccounted-gas rem-gas
   #:dark-matter-hypothesis (shadow-ledger-dark-matter-hypothesis ledger)
   #:predicted-enemy-bases (shadow-ledger-predicted-enemy-bases ledger)
   #:feint-or-poke-detected? (and reading (action-lens-reading-feint-or-poke-detected? reading) #t)
   #:proxy-or-rush-detected? (and reading (action-lens-reading-proxy-or-rush-detected? reading) #t)
   #:branch-posteriors (build-order-tree-projection-branch-posteriors opp-proj)))

;; =============================================================================
;; 2d. Zero-Sum Opportunity-Cost / Negative Exclusion & Bayesian Bluff Detector
;; =============================================================================

(define MIRROR-ZERO-SUM-OPP-COST-TABLE (make-weak-hasheq))
(define ZERO-COST-PROFILE-DEFAULT
  (hasheq 'opportunity-cost-commitment #f
          'commitment-score 0.0
          'dominant-path 'uncommitted
          'committed-primary-branch 'uncommitted
          'gas-devoted 0
          'minerals-devoted 0
          'gas-envelope 150
          'minerals-envelope 500
          'gas-ratio 0.0
          'mineral-ratio 0.0
          'closed-branches '()
          'capital-air-trigger? #f
          'recommended-enemy-unit #f))

(define (zero-sum-exclusion-reading-opportunity-cost-profile zs)
  (if (zero-sum-exclusion-reading? zs)
      (hash-ref MIRROR-ZERO-SUM-OPP-COST-TABLE zs ZERO-COST-PROFILE-DEFAULT)
      ZERO-COST-PROFILE-DEFAULT))

(define (zero-sum-exclusion-reading-commitment-score zs)
  (hash-ref (zero-sum-exclusion-reading-opportunity-cost-profile zs) 'commitment-score 0.0))

(define (sym->opp-cost-path sym)
  (case sym
    [(fusion-core battlecruiser starport starport-techlab starport-reactor
      banshee liberator raven viking viking-fighter viking-assault medivac
      yamato-cannon cloaking-field corvid-reactor)
     'air-starport-bc]
    [(fleet-beacon carrier tempest mothership stargate void-ray voidray
      phoenix oracle anion-pulse-crystals flux-vanes graviton-catapult)
     'stargate-fleet]
    [(greater-spire brood-lord brood-lord-cocoon spire corruptor mutalisk viper)
     'greater-spire]
    [(siege-tank siege-tank-sieged thor thor-ap factory factory-techlab armory
      immortal colossus disruptor robotics-facility robotics-bay robotics-support-bay
      lurker lurker-burrowed lurker-mp lurker-mp-burrowed lurker-den lurker-den-mp
      ultralisk ultralisk-cavern roach ravager roach-warren marauder)
     'armored-siege]
    [(templar-archive templar-archives high-templar archon dark-shrine dark-templar
      twilight-council psi-storm psi-storm-tech blink blink-cast charge charge-cast)
     'twilight-templar-ground]
    [(barracks-techlab stimpack stimpack-cast combat-shield ghost ghost-academy)
     'bio-stim-medivac]
    [(baneling baneling-nest baneling-cocoon baneling-burrowed hydralisk hydralisk-den
      infestor infestation-pit)
     'ling-bane-hydra]
    [else #f]))

(define (evaluate-mirror-opportunity-cost-profile raw-frame raw-enemy-units raw-enemy-bldgs
                                                 [tech-obs #f] [ledger #f])
  (define frame (safe-frame raw-frame))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define est-workers
    (if (shadow-ledger? ledger)
        (max 12 (shadow-ledger-estimated-workers ledger))
        (max 12 (min 66 (+ 12 (quotient frame 268))))))
  (define avg-workers (/ (+ 12.0 est-workers) 2.0))
  (define env-min
    (max 500
         (if (shadow-ledger? ledger) (shadow-ledger-expected-minerals ledger) 0)
         (exact-round (+ 1050.0 (* frame avg-workers 0.036)))))
  (define env-gas
    (max 150
         (if (shadow-ledger? ledger) (shadow-ledger-expected-gas ledger) 0)
         (exact-round (* (max 0 (- frame 700)) 0.19))))
  (define path-gas (make-hasheq))
  (define path-min (make-hasheq))
  (define visible-bldg-ht (make-hasheq))
  (define capital-air-trigger? #f)
  (define rec-enemy-unit #f)
  (define (record-sym! sym)
    (when (memq sym '(fusion-core fleet-beacon greater-spire
                      battlecruiser carrier tempest mothership brood-lord))
      (set! capital-air-trigger? #t))
    (when (memq sym '(battlecruiser carrier tempest mothership brood-lord))
      (set! rec-enemy-unit
            (case sym
              [(battlecruiser) 'battlecruiser]
              [(carrier tempest mothership brood-lord) sym]
              [else rec-enemy-unit])))
    (define p (sym->opp-cost-path sym))
    (when p
      (define c (unit-resource-cost sym))
      (hash-set! path-min p (+ (hash-ref path-min p 0) (car c)))
      (hash-set! path-gas p (+ (hash-ref path-gas p 0) (cdr c)))))
  (for ([u (in-list enemy-units)]
        #:unless (or (enemy-unit-hallucination? u) (enemy-unit-changeling? u)))
    (record-sym! (unit-type-sym u)))
  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define bs (unit-type-sym b))
    (hash-set! visible-bldg-ht bs #t)
    (record-sym! bs))
  (when (enemy-tech-observation? tech-obs)
    (for ([ib (in-list (enemy-tech-observation-implied-tech-buildings tech-obs))]
          #:unless (hash-has-key? visible-bldg-ht ib))
      (hash-set! visible-bldg-ht ib #t)
      (record-sym! ib)))
  (define path-order
    '(air-starport-bc stargate-fleet greater-spire armored-siege
      twilight-templar-ground bio-stim-medivac ling-bane-hydra))
  (define-values (dom-path dom-gas dom-min)
    (for/fold ([bp 'uncommitted] [bg 0] [bm 0]) ([p (in-list path-order)])
      (define pg (hash-ref path-gas p 0))
      (define pm (hash-ref path-min p 0))
      (if (or (> pg bg) (and (= pg bg) (> pm bm)))
          (values p pg pm)
          (values bp bg bm))))
  (define gas-ratio (/ (exact->inexact dom-gas) (exact->inexact (max 1 env-gas))))
  (define min-ratio (/ (exact->inexact dom-min) (exact->inexact (max 1 env-min))))
  (define committed?
    (and (not (eq? dom-path 'uncommitted))
         (or (>= gas-ratio 0.40)
             (>= dom-gas 350)
             capital-air-trigger?)))
  (define commitment-score
    (exact->inexact
     (max 0.0
          (min 1.0
               (cond
                 [capital-air-trigger? (max 0.88 gas-ratio (if (>= dom-gas 350) 0.92 0.88))]
                 [(>= dom-gas 350) (max 0.78 gas-ratio)]
                 [else gas-ratio])))))
  (define eff-rec-enemy
    (or rec-enemy-unit
        (case dom-path
          [(air-starport-bc) (if (or (hash-has-key? visible-bldg-ht 'fusion-core) capital-air-trigger?)
                                 'battlecruiser
                                 'banshee)]
          [(stargate-fleet) (if (hash-has-key? visible-bldg-ht 'fleet-beacon) 'carrier 'void-ray)]
          [(greater-spire) (if (hash-has-key? visible-bldg-ht 'greater-spire) 'brood-lord 'mutalisk)]
          [(armored-siege) 'siege-tank]
          [else #f])))
  (define closed-branches
    (if committed?
        (case dom-path
          [(air-starport-bc)
           '(closed-by-opportunity-cost heavy-bio-stim-timing mass-factory-mech-thor)]
          [(stargate-fleet)
           '(closed-by-opportunity-cost templar-archive-storm dark-shrine-dt-rush colossus-thermal-lance-rush)]
          [(greater-spire)
           '(closed-by-opportunity-cost lurker-den-siege roach-ravager-max-upgrades early-ultralisk-rush)]
          [(armored-siege)
           '(closed-by-opportunity-cost stargate-air-rush fleet-beacon-carriers bio-stim-marine-marauder-flood spire-mutalisk-rush)]
          [(twilight-templar-ground)
           '(closed-by-opportunity-cost stargate-air-rush fleet-beacon-carriers colossus-thermal-lance-rush)]
          [else '(closed-by-opportunity-cost)])
        '()))
  (hasheq 'opportunity-cost-commitment committed?
          'commitment-score commitment-score
          'dominant-path dom-path
          'committed-primary-branch (if committed? dom-path 'uncommitted)
          'gas-devoted dom-gas
          'minerals-devoted dom-min
          'gas-envelope env-gas
          'minerals-envelope env-min
          'gas-ratio gas-ratio
          'mineral-ratio min-ratio
          'closed-branches closed-branches
          'capital-air-trigger? capital-air-trigger?
          'recommended-enemy-unit eff-rec-enemy))

(define (evaluate-zero-sum-negative-exclusions raw-frame raw-enemy-units raw-enemy-bldgs tech-obs ledger)
  (define frame (safe-frame raw-frame))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define opp-profile
    (evaluate-mirror-opportunity-cost-profile frame enemy-units enemy-bldgs tech-obs ledger))
  (define opp-committed? (hash-ref opp-profile 'opportunity-cost-commitment #f))
  (define opp-dom-path (hash-ref opp-profile 'dominant-path 'uncommitted))
  (define opp-closed (hash-ref opp-profile 'closed-branches '()))
  (define hallucinated-units '())
  (define active-pool-set (make-hasheq))
  (for ([u (in-list enemy-units)])
    (cond
      [(enemy-unit-hallucination? u)
       (set! hallucinated-units (cons u hallucinated-units))]
      [(not (enemy-unit-changeling? u))
       (hash-set! active-pool-set (unit-type-sym u) #t)]))
  (set! hallucinated-units (reverse hallucinated-units))
  (define struct-act
    (analyze-enemy-structure-activity-and-bluffs enemy-bldgs))
  (for ([p (in-list (enemy-structure-activity-previewed-units struct-act))])
    (hash-set! active-pool-set p #t))
  (define obs-upgs (if (enemy-tech-observation? tech-obs)
                       (enemy-tech-observation-observed-upgrades tech-obs)
                       '()))
  (define obs-spells (if (enemy-tech-observation? tech-obs)
                         (enemy-tech-observation-observed-spells tech-obs)
                         '()))
  (define implied-bldgs (if (enemy-tech-observation? tech-obs)
                            (enemy-tech-observation-implied-tech-buildings tech-obs)
                            '()))
  (define active-res (if (enemy-tech-observation? tech-obs)
                         (enemy-tech-observation-active-research-buildings tech-obs)
                         '()))
  (for ([s (in-list obs-upgs)]) (hash-set! active-pool-set s #t))
  (for ([s (in-list obs-spells)]) (hash-set! active-pool-set s #t))
  (define bldg-sym-set (make-hasheq))
  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f)
                     (hash-ref b 'canceled #f)))
    (hash-set! bldg-sym-set (unit-type-sym b) #t))
  (define (any-in-pool? syms)
    (for/or ([s (in-list syms)])
      (or (hash-has-key? active-pool-set s)
          (hash-has-key? bldg-sym-set s)
          (and (pair? implied-bldgs) (memq s implied-bldgs) #t))))

  (define queen-cnt
    (for/sum ([u (in-list enemy-units)])
      (if (eq? (unit-type-sym u) 'queen) 1 0)))

  (define-values (candidate-branch candidate-exclusions confirming-syms)
    (cond
      ;; Protoss branches: check Fleet Beacon / Stargate Sky-Toss BEFORE Twilight/Blink so
      ;; Blink + 5 Stargate + Tempest/Carrier is never misclassified as ground!
      ;; Wait: if Templar Archives / High Templar / Psi Storm exists without Fleet Beacon /
      ;; Tempest / Carrier / VoidRay, prefer 'twilight-templar-ground.
      [(or (and opp-committed? (eq? opp-dom-path 'stargate-fleet))
           (any-in-pool? '(fleet-beacon carrier tempest mothership void-ray voidray)))
       (values (if opp-committed? 'stargate-fleet 'stargate-sky-fleet)
               '(templar-archive-storm dark-shrine-dt-rush colossus-thermal-lance-rush)
               '(phoenix oracle void-ray voidray carrier tempest mothership fleet-beacon
                 oracle-revelation pulsar-beam chrono-boost-active))]
      [(and (any-in-pool? '(stargate phoenix oracle oracle-revelation pulsar-beam))
            (not (any-in-pool? '(templar-archive templar-archives high-templar
                                 psi-storm psi-storm-tech))))
       (values (if opp-committed? 'stargate-fleet 'stargate-sky-fleet)
               '(templar-archive-storm dark-shrine-dt-rush colossus-thermal-lance-rush)
               '(phoenix oracle void-ray voidray carrier tempest
                 oracle-revelation pulsar-beam chrono-boost-active))]
      [(or (any-in-pool? '(templar-archive templar-archives high-templar archon
                           psi-storm psi-storm-tech charge charge-cast blink blink-cast
                           resonating-glaives resonating-glaives-cast))
           (and (hash-has-key? bldg-sym-set 'twilight-council)
                (not (any-in-pool? '(dark-shrine dark-templar)))))
       (values 'twilight-templar-ground
               '(stargate-air-rush fleet-beacon-carriers colossus-thermal-lance-rush)
               '(high-templar archon psi-storm psi-storm-tech charge charge-cast
                 blink blink-cast resonating-glaives resonating-glaives-cast chrono-boost-active))]
      [(or (and opp-committed? (eq? opp-dom-path 'armored-siege)
                (any-in-pool? '(colossus immortal disruptor robotics-bay robotics-support-bay robotics-facility)))
           (any-in-pool? '(robotics-bay robotics-support-bay colossus disruptor
                           immortal robotics-facility)))
       (values (if opp-committed? 'armored-siege 'robotics-heavy-siege)
               '(stargate-air-rush fleet-beacon-carriers templar-archive-storm)
               '(immortal colossus disruptor extended-thermal-lance chrono-boost-active))]
      ;; Zerg branches
      [(or (and opp-committed? (eq? opp-dom-path 'greater-spire))
           (any-in-pool? '(greater-spire brood-lord spire mutalisk corruptor)))
       (values (if opp-committed? 'greater-spire 'spire-air-muta)
               '(lurker-den-siege roach-ravager-max-upgrades early-ultralisk-rush)
               '(mutalisk corruptor brood-lord greater-spire))]
      [(any-in-pool? '(hydralisk-den lurker-den lurker-den-mp hydralisk lurker lurker-mp lurker-spines))
       (values 'hydra-lurker-den
               '(spire-mutalisk-rush early-brood-lord-rush)
               '(hydralisk lurker lurker-mp lurker-spines grooved-spines muscular-augments lurker-aspect))]
      [(or (any-in-pool? '(infestation-pit infestor infestor-burrowed neural-parasite fungal-growth))
           (>= queen-cnt 4))
       (values 'infestor-queen-spell
               '(spire-mutalisk-rush early-zergling-all-in)
               '(infestor infestor-burrowed queen neural-parasite fungal-growth))]
      [(any-in-pool? '(roach-warren roach ravager glial-reconstitution corrosive-bile))
       (values 'roach-ravager-ground
               '(spire-mutalisk-rush baneling-flood-bust)
               '(roach ravager glial-reconstitution corrosive-bile))]
      [(any-in-pool? '(baneling-nest baneling baneling-burrowed centrifugal-hooks))
       (values 'ling-bane-flood
               '(roach-ravager-max-upgrades early-ultralisk-rush)
               '(baneling baneling-burrowed centrifugal-hooks zergling))]
      ;; Terran branches
      [(or (and opp-committed? (eq? opp-dom-path 'air-starport-bc))
           (any-in-pool? '(starport-techlab fusion-core banshee battlecruiser
                           raven banshee-cloak-cast cloaking-field)))
       (values (if opp-committed? 'air-starport-bc 'starport-cloak-or-bc)
               '(heavy-bio-stim-timing mass-factory-mech-thor)
               '(fusion-core battlecruiser banshee raven banshee-cloak-cast cloaking-field))]
      [(any-in-pool? '(factory-techlab armory siege-tank siege-tank-sieged thor hellbat cyclone))
       (values (if opp-committed? 'armored-siege 'factory-mech-siege)
               '(bio-stim-marine-marauder-flood battlecruiser-fusion-rush)
               '(siege-tank siege-tank-sieged thor hellbat cyclone siege-mode))]
      [(any-in-pool? '(barracks-techlab stimpack stimpack-cast combat-shield marauder medivac))
       (values 'bio-stim-medivac
               '(battlecruiser-fusion-rush mass-factory-mech-thor)
               '(marauder medivac stimpack stimpack-cast combat-shield))]
      [else
       (values 'uncommitted '() '())]))

  (define macro-exclusions
    (if (and (>= (if (shadow-ledger? ledger) (shadow-ledger-predicted-enemy-bases ledger) 1) 3)
             (< frame 4500))
        '(one-or-two-base-all-in)
        '()))

  (define rem-gas (if (shadow-ledger? ledger) (shadow-ledger-unaccounted-gas ledger) 0))
  (define confirmed-commitment?
    (or opp-committed?
        (for/or ([s (in-list confirming-syms)]) (hash-has-key? active-pool-set s))
        (not (null? active-res))
        (enemy-structure-activity-research-under-attack? struct-act)
        (not (null? (enemy-structure-activity-previewed-units struct-act)))
        (< rem-gas 225)))

  (define combat-hallucination-bait?
    (and (not (null? hallucinated-units))
         (for/or ([hu (in-list hallucinated-units)])
           (memq (unit-type-sym hu)
                 '(colossus void-ray voidray immortal archon phoenix oracle carrier)))))

  (define bluff-posterior
    (compute-bayesian-bluff-posterior
     enemy-units
     enemy-bldgs
     tech-obs
     ledger
     #:prior 0.08
     #:candidate-branch candidate-branch
     #:confirmed-commitment? confirmed-commitment?))

  (define bluff-suspected?
    (and (not opp-committed?)
         (not (enemy-structure-activity-research-under-attack? struct-act))
         (>= bluff-posterior 0.55)))

  (define reading-out
    (cond
      [(and (eq? candidate-branch 'uncommitted) (not bluff-suspected?))
       (zero-sum-exclusion-reading 'uncommitted
                                   macro-exclusions
                                   #f
                                   rem-gas
                                   0.50
                                   'no-tech-branch-observed-yet)]
      [bluff-suspected?
       (zero-sum-exclusion-reading candidate-branch
                                   macro-exclusions
                                   #t
                                   rem-gas
                                   (exact->inexact (max 0.15 (min 0.45 (- 1.0 bluff-posterior))))
                                   (cond
                                     [(enemy-structure-activity-bluff-or-feint-suspected? struct-act)
                                      'fake-build-or-research-cancel-bluff]
                                     [combat-hallucination-bait?
                                      'hallucination-bait-or-scout-detected]
                                     [else
                                      'suspected-tech-bluff-unspent-gas-surplus]))]
      [else
       (define final-exclusions
         (remove-duplicates (append opp-closed candidate-exclusions macro-exclusions)))
       (define final-conf
         (exact->inexact
          (max (if opp-committed? (hash-ref opp-profile 'commitment-score 0.85) 0.72)
               (min 0.96 (- 1.0 (* 0.5 bluff-posterior))))))
       (zero-sum-exclusion-reading candidate-branch
                                   final-exclusions
                                   #f
                                   rem-gas
                                   final-conf
                                   (if opp-committed?
                                       'opportunity-cost-committed-branches-closed
                                       'zero-sum-gas-committed-orthogonal-excluded))]))
  (hash-set! MIRROR-ZERO-SUM-OPP-COST-TABLE reading-out opp-profile)
  reading-out)

;; =============================================================================
;; 3. Component 1: Shadow Economy & Dark-Matter Resource Ledger
;; =============================================================================

;; L86D: ABI-preserving weak side-table mapping `mstate -> (hash bid #(family bx by))`
;; so SC2 Protobuf `Snapshot` tag-churn never double-counts fogged enemy buildings in `bldg-costs`!
(define MIRROR-BLDG-SPATIAL-TABLE (make-weak-hasheq))

(define (mirror-bldg-spatial-family bt)
  (cond
    [(memq bt '(nexus command-center command-center-flying orbital-command orbital-command-flying
                planetary-fortress hatchery lair hive))
     'townhall]
    [(memq bt '(assimilator assimilator-rich refinery refinery-rich extractor extractor-rich))
     'geyser]
    [(memq bt '(gateway warp-gate warpgate))
     'gateway]
    [(memq bt '(spire greater-spire))
     'spire]
    [(memq bt '(supply-depot supply-depot-lowered))
     'supply-depot]
    [(memq bt '(spine-crawler spine-crawler-uprooted))
     'spine-crawler]
    [(memq bt '(spore-crawler spore-crawler-uprooted))
     'spore-crawler]
    [else bt]))

(define (mirror-bldg-spatial-r2 fam)
  (cond
    [(memq fam '(townhall geyser)) 16.0] ; 4.0t
    [(memq fam '(pylon supply-depot photon-cannon shield-battery missile-turret
                 spine-crawler spore-crawler sensor-tower dark-shrine creep-tumor))
     2.25] ; 1.5t (strictly < 2.0t adjacent 2x2 center spacing)
    [else 6.25])) ; 2.5t (strictly < 3.0t adjacent 3x3+ center spacing)

(define (compute-opponent-shadow-ledger mstate raw-frame raw-enemy-units raw-enemy-bldgs
                                        #:base-x [raw-base-x 32]
                                        #:base-y [raw-base-y 32]
                                        #:nat-x [raw-nat-x #f]
                                        #:nat-y [raw-nat-y #f]
                                        #:remembered-enemy-bases [raw-rem-eb #f]
                                        #:remembered-enemy-gases [raw-rem-eg #f]
                                        #:observed-effects [observed-effects '()]
                                        #:enemy-workers-killed [raw-enemy-workers-killed 0]
                                        #:our-upgrade-tier [raw-our-upgrade-tier 0]
                                        #:our-units-lost-value [_our-units-lost-value 0]
                                        #:enemy-units-lost-value [_enemy-units-lost-value 0])
  (define frame (safe-frame raw-frame))
  (define base-x (safe-coord raw-base-x 32))
  (define base-y (safe-coord raw-base-y 32))
  (define has-nat? (and (real? raw-nat-x) (real? raw-nat-y)))
  (define nat-x (if has-nat? (safe-coord raw-nat-x 50) 50))
  (define nat-y (if has-nat? (safe-coord raw-nat-y 56) 56))
  (define rem-enemy-bases
    (if (and (real? raw-rem-eb) (> raw-rem-eb 0))
        (min 12 (max 1 (exact-round raw-rem-eb)))
        0))
  (define rem-enemy-gases
    (if (and (real? raw-rem-eg) (>= raw-rem-eg 0))
        (min 24 (max 0 (exact-round raw-rem-eg)))
        0))
  (define enemy-workers-killed (max 0 (safe-int raw-enemy-workers-killed 0)))
  (define our-upgrade-tier (max 0 (safe-int raw-our-upgrade-tier 0)))
  (define enemy-units (if (list? raw-enemy-units) raw-enemy-units '()))
  (define enemy-bldgs (if (list? raw-enemy-bldgs) raw-enemy-bldgs '()))
  (define unit-costs (mirror-mind-state-seen-enemy-unit-costs mstate))
  (define bldg-costs (mirror-mind-state-seen-enemy-bldg-costs mstate))

  (for ([u (in-list enemy-units)])
    (define uid (hash-ref u 'id #f))
    (define utype (unit-type-sym u))
    (define prev-c (and uid (hash-ref unit-costs uid #f)))
    (define morphable? (memq utype '(baneling baneling-cocoon ravager ravager-cocoon
                                     lurker lurker-egg lurker-mp-egg brood-lord brood-lord-cocoon
                                     overseer overlord-cocoon archon)))
    (unless (and prev-c (not morphable?))
      (define halluc? (enemy-unit-hallucination? u))
      (define changeling? (enemy-unit-changeling? u))
      (when (or halluc? changeling?)
        (set-mirror-mind-state-ever-scouted-by-enemy?! mstate #t))
      (when uid
        (define new-c (if (or halluc? changeling?) ZERO-COST (unit-resource-cost utype)))
        (unless (eq? prev-c new-c)
          (hash-set! unit-costs uid new-c)))))

  ;; L86E O(1) Fast Path: already-tracked `bid` with unchanged `bt` does 2 hash lookups,
  ;; 0 allocations, and 0 spatial scans! Spatial dedup runs ONLY on genuinely new/Snapshot tags.
  (define bldg-spatial-tbl
    (or (hash-ref MIRROR-BLDG-SPATIAL-TABLE mstate #f)
        (let ([ht (make-hash)])
          (hash-set! MIRROR-BLDG-SPATIAL-TABLE mstate ht)
          ht)))
  (define seen-bldg-ids-this-step #f)
  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define bid (hash-ref b 'id #f))
    (when bid
      (define bt (unit-type-sym b))
      (define prev-c (hash-ref bldg-costs bid #f))
      (cond
        [prev-c
         (define sp (hash-ref bldg-spatial-tbl bid #f))
         (unless (and (vector? sp) (eq? (vector-ref sp 3) bt))
           ;; Morph or first coordinate record for existing tag
           (define new-cost (unit-resource-cost bt))
           (when (or (> (car new-cost) (car prev-c)) (> (cdr new-cost) (cdr prev-c)))
             (hash-set! bldg-costs bid
                        (cons (max (car prev-c) (car new-cost))
                              (max (cdr prev-c) (cdr new-cost)))))
           (define raw-bx (hash-ref b 'x #f))
           (define raw-by (hash-ref b 'y #f))
           (when (and (real? raw-bx) (real? raw-by))
             (hash-set! bldg-spatial-tbl bid
                        (vector (mirror-bldg-spatial-family bt)
                                (exact->inexact raw-bx)
                                (exact->inexact raw-by)
                                bt))))]
        [else
         ;; Genuinely new/Snapshot `bid`: populate `seen-bldg-ids-this-step` lazily once per step
         (unless seen-bldg-ids-this-step
           (set! seen-bldg-ids-this-step (make-hash))
           (for ([eb (in-list enemy-bldgs)])
             (define ebid (hash-ref eb 'id #f))
             (when ebid (hash-set! seen-bldg-ids-this-step ebid #t))))
         (define new-cost (unit-resource-cost bt))
         (define raw-bx (hash-ref b 'x #f))
         (define raw-by (hash-ref b 'y #f))
         (if (and (real? raw-bx) (real? raw-by))
             (let* ([bx (exact->inexact raw-bx)]
                    [by (exact->inexact raw-by)]
                    [fam (mirror-bldg-spatial-family bt)]
                    [r2 (mirror-bldg-spatial-r2 fam)]
                    [replaced-ids
                     (for/list ([(old-id old-v) (in-hash bldg-spatial-tbl)]
                                #:when (and (not (equal? old-id bid))
                                            (eq? (vector-ref old-v 0) fam)
                                            (let ([dx (- bx (vector-ref old-v 1))]
                                                  [dy (- by (vector-ref old-v 2))])
                                              (define d2 (+ (* dx dx) (* dy dy)))
                                              (if (hash-has-key? seen-bldg-ids-this-step old-id)
                                                  (<= d2 1.0)
                                                  (<= d2 r2)))))
                       old-id)]
                    [merged-cost
                     (for/fold ([mc new-cost]) ([old-id (in-list replaced-ids)])
                       (define oc (hash-ref bldg-costs old-id #f))
                       (hash-remove! bldg-costs old-id)
                       (hash-remove! bldg-spatial-tbl old-id)
                       (if (pair? oc)
                           (cons (max (car mc) (car oc)) (max (cdr mc) (cdr oc)))
                           mc))])
               (hash-set! bldg-costs bid merged-cost)
               (hash-set! bldg-spatial-tbl bid (vector fam bx by bt)))
             (hash-set! bldg-costs bid new-cost))])))

  ;; Rational opponent worker curve: starts at 12 workers, adds ~1 worker every
  ;; 268 frames (12s) with zero supply blocks, up to 66 workers, minus killed workers.
  (define est-workers
    (max 4 (- (min 66 (+ 12 (quotient (max 0 frame) 268)))
              enemy-workers-killed)))

  (define avg-workers (/ (+ 12.0 est-workers) 2.0))
  (define expected-minerals
    (exact-round (+ 1050.0 (* frame avg-workers 0.036))))
  (define gas-frames (max 0 (- frame 700)))
  (define raw-expected-gas
    (exact-round (* gas-frames 0.19)))

  (define seen-unit-min 0)
  (define seen-unit-gas 0)
  (for ([c (in-hash-values unit-costs)])
    (set! seen-unit-min (+ seen-unit-min (car c)))
    (set! seen-unit-gas (+ seen-unit-gas (cdr c))))
  (define seen-bldg-min 0)
  (define seen-bldg-gas 0)
  (for ([c (in-hash-values bldg-costs)])
    (set! seen-bldg-min (+ seen-bldg-min (car c)))
    (set! seen-bldg-gas (+ seen-bldg-gas (cdr c))))

  ;; Infer enemy implied tech buildings, spells & observed upgrades from visible units/buildings
  (define prev-tech-obs (mirror-mind-state-last-tech-observation mstate))
  (define tech-obs
    (infer-enemy-implied-tech-and-upgrades
     enemy-units
     enemy-bldgs
     #:our-upgrade-tier our-upgrade-tier
     #:observed-effects (if (list? observed-effects) observed-effects '())
     #:destroyed-enemy-bldgs (mirror-mind-state-destroyed-enemy-bldgs mstate)
     #:pre-destruction-unit-ids (mirror-mind-state-pre-destruction-unit-ids mstate)
     #:historical-upgrades (if prev-tech-obs
                               (enemy-tech-observation-observed-upgrades prev-tech-obs)
                               '())
     #:historical-implied-buildings
     (if (and prev-tech-obs (null? enemy-units) (null? enemy-bldgs))
         (enemy-tech-observation-implied-tech-buildings prev-tech-obs)
         '())))
  (set-mirror-mind-state-last-tech-observation! mstate tech-obs)
  (define visible-bldg-ht (make-hasheq))
  (for ([b (in-list enemy-bldgs)])
    (hash-set! visible-bldg-ht (unit-type-sym b) #t))
  (define unseen-bldg-min 0)
  (define unseen-bldg-gas 0)
  (for ([b (in-list (enemy-tech-observation-implied-tech-buildings tech-obs))])
    (unless (hash-has-key? visible-bldg-ht b)
      (define rc (unit-resource-cost b))
      (set! unseen-bldg-min (+ unseen-bldg-min (car rc)))
      (set! unseen-bldg-gas (+ unseen-bldg-gas (cdr rc)))))
  (define upg-min 0)
  (define upg-gas 0)
  (for ([u (in-list (enemy-tech-observation-observed-upgrades tech-obs))])
    (define rc (upgrade-resource-cost u))
    (set! upg-min (+ upg-min (car rc)))
    (set! upg-gas (+ upg-gas (cdr rc))))
  (define unseen-implied-min (+ unseen-bldg-min upg-min))
  (define unseen-implied-gas (+ unseen-bldg-gas upg-gas))

  (define inferred-worker-spend (* (max 0 (- est-workers 12)) 50))
  (define inferred-supply-spend (* (quotient (max 0 (- est-workers 14)) 8) 100))

  (define accounted-minerals
    (+ 1000 inferred-worker-spend inferred-supply-spend seen-unit-min seen-bldg-min unseen-implied-min))
  (define accounted-gas
    (+ seen-unit-gas seen-bldg-gas unseen-implied-gas))

  ;; Pro-Replay Calibration:
  ;; 1. 1-base zero-gas mineral/spine rush (e.g. Dark 12-Pool Spine vs Serral) -> expected-gas = 0
  ;; 2. Law of Negative Base Scouting: when we see explicit 1 gas building (or >= 2 ground combat units
  ;;    with <= 1 gas building), calibrate expected-gas to 1 geyser (starts frame 1200 @ 0.095 G/frame,
  ;;    plus 2nd geyser after frame 2400 @ 0.085 G/frame only when >= 2 gas buildings are seen).
  (define enemy-townhalls '())
  (define seen-gas-bldgs 0)
  (define near-non-natblock-bldg-cnt 0)
  (define near-natblock-bldg-cnt 0)
  (define bldg-static-def? #f)
  (for ([b (in-list enemy-bldgs)])
    (define bt (unit-type-sym b))
    (when (memq bt '(nexus command-center orbital-command planetary-fortress
                           hatchery lair hive))
      (set! enemy-townhalls (cons b enemy-townhalls)))
    (when (memq bt '(assimilator refinery extractor))
      (set! seen-gas-bldgs (add1 seen-gas-bldgs)))
    (when (and (not bldg-static-def?)
               (memq bt '(bunker photon-cannon shield-battery spine-crawler
                          planetary-fortress siege-tank siege-tank-sieged
                          widow-mine widow-mine-burrowed liberator liberator-ag
                          lurker lurker-burrowed lurker-mp lurker-mp-burrowed)))
      (set! bldg-static-def? #t))
    (when (not (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
      (define bx (safe-real (hash-ref b 'x 160) 160))
      (define by (safe-real (hash-ref b 'y 160) 160))
      (define dx (- base-x bx))
      (define dy (- base-y by))
      (define d2-main (+ (* dx dx) (* dy dy)))
      (when (<= d2-main 1024.0)
        ;; L85C: Exclude a lone natural-pad `pylon`/`engineering-bay` expansion block (`dNat <= 7.5t`
        ;; and `dMain > 16.0t`) from flagging `near-enemy-bldg?` -> `'proxy-production-or-all-in`;
        ;; escalate immediately on >= 2 such structures (cannon rush) or any other proxy structure!
        (define is-nat-exp-block?
          (and has-nat?
               (memq bt '(pylon engineering-bay))
               (> d2-main 256.0)
               (let ([dnx (- nat-x bx)]
                     [dny (- nat-y by)])
                 (<= (+ (* dnx dnx) (* dny dny)) 56.25))))
        (if is-nat-exp-block?
            (set! near-natblock-bldg-cnt (add1 near-natblock-bldg-cnt))
            (set! near-non-natblock-bldg-cnt (add1 near-non-natblock-bldg-cnt))))))
  (define near-enemy-bldg?
    (or (> near-non-natblock-bldg-cnt 0)
        (>= near-natblock-bldg-cnt 2)))
  (define ground-combat-count 0)
  (define enemy-combat-count 0)
  (define near-enemy-combat-count 0)
  (define near-enemy-worker-count 0)
  (define visible-enemy-workers 0)
  (define unit-static-def? #f)
  (for ([u (in-list enemy-units)])
    (define ut (unit-type-sym u))
    (define wk? (memq ut '(drone probe scv)))
    (define comb?
      (and (not wk?)
           (not (hash-has-key? NON-COMBAT-AND-WORKER-SET ut))
           (not (eq? (hash-ref u 'changeling? #f) #t))
           (not (enemy-unit-hallucination? u))))
    (when (memq ut '(zergling baneling roach ravager hydralisk lurker queen
                              marine marauder reaper hellion hellbat widow-mine cyclone siege-tank
                              zealot stalker adept sentry immortal colossus archon))
      (set! ground-combat-count (add1 ground-combat-count)))
    (when (and (not unit-static-def?)
               (memq ut '(bunker photon-cannon shield-battery spine-crawler
                          planetary-fortress siege-tank siege-tank-sieged
                          widow-mine widow-mine-burrowed liberator liberator-ag
                          lurker lurker-burrowed lurker-mp lurker-mp-burrowed)))
      (set! unit-static-def? #t))
    (when wk?
      (set! visible-enemy-workers (add1 visible-enemy-workers)))
    (when comb?
      (set! enemy-combat-count (add1 enemy-combat-count)))
    (when (or comb? wk?)
      (define dx (- base-x (safe-real (hash-ref u 'x 160) 160)))
      (define dy (- base-y (safe-real (hash-ref u 'y 160) 160)))
      (when (<= (+ (* dx dx) (* dy dy)) 1024.0)
        (if comb?
            (set! near-enemy-combat-count (add1 near-enemy-combat-count))
            (set! near-enemy-worker-count (add1 near-enemy-worker-count))))))
  ;; Exclude non-combat scouts (overlord, overseer, observer, changelings, single scouting worker)
  ;; so routine scouting never triggers false proxy/near-base all-in states!
  (define enemy-near-us?
    (or near-enemy-bldg?
        (>= near-enemy-combat-count 1)
        (>= near-enemy-worker-count 3)))
  (define eff-seen-gas-bldgs (max seen-gas-bldgs rem-enemy-gases))
  (define eff-known-th-cnt (max (length enemy-townhalls) rem-enemy-bases))
  (define zero-gas-rush?
    (and (>= frame 1800)
         (<= frame 6048)
         (<= eff-known-th-cnt 1)
         (= accounted-gas 0)
         (or (>= enemy-combat-count 5)
             (>= near-enemy-worker-count 5))))
  (define calibrated-geyser-mode?
    (or (>= eff-seen-gas-bldgs 1)
        (>= ground-combat-count 2)
        (not enemy-near-us?)))
  (define expected-gas
    (cond
      [zero-gas-rush? 0]
      [calibrated-geyser-mode?
       (define g1 (* (max 0 (- frame 1200)) 0.095))
       (define g2 (if (>= eff-seen-gas-bldgs 2) (* (max 0 (- frame 2400)) 0.085) 0.0))
       ;; L86C Track A: Scale expected gas beyond 2 geysers when >= 3 remembered/estimated!
       (define g-extra
         (if (>= eff-seen-gas-bldgs 3)
             (for/sum ([idx (in-range 3 (add1 (min 12 eff-seen-gas-bldgs)))])
               (define onset (+ 2400 (* (- idx 2) 1800)))
               (* (max 0 (- frame onset)) 0.080))
             0.0))
       (exact-round (+ g1 g2 g-extra))]
      [else raw-expected-gas]))

  (define delta-min (max 0 (- expected-minerals accounted-minerals)))
  (define delta-gas (max 0 (- expected-gas accounted-gas)))

  (define proxy-attack-near-us?
    (or near-enemy-bldg?
        (>= near-enemy-combat-count 2)
        (>= near-enemy-worker-count 3)))

  (define hypothesis
    (cond
      [(or zero-gas-rush?
           (and proxy-attack-near-us?
                (= (+ seen-unit-gas seen-bldg-gas) 0)
                (or near-enemy-bldg?
                    (>= near-enemy-combat-count 3)
                    (>= near-enemy-worker-count 3))))
       'proxy-production-or-all-in]
      [(and (>= delta-gas 200)
            (< seen-unit-gas 150)
            (or enemy-near-us? (>= eff-seen-gas-bldgs 2)))
       'hidden-air-or-cloak-tech-switch]
      [(and (>= frame 2200)
            (<= frame 6048)
            (<= eff-known-th-cnt 1)
            (>= delta-min 450)
            proxy-attack-near-us?)
       'proxy-production-or-all-in]
      [(and (>= delta-min 450)
            (or (>= delta-gas 100)
                (and (>= frame 2200)
                     (<= frame 6048)
                     (<= eff-known-th-cnt 1))))
       ;; Rational-Opponent Principle: unaccounted resources under 1-base fog in the
       ;; early/mid game are potentially threatening unseen Army/Tech — NEVER free greed!
       'imminent-fog-timing-wave]
      [(or (and (>= (length enemy-townhalls) 3) (<= enemy-combat-count 4))
           (and (> frame 6048)
                (<= eff-known-th-cnt 1)
                (>= delta-min 750)
                (< delta-gas 150)))
       'hidden-expansion-or-macro-boom]
      [else
       'accounted-visible-macro]))

  ;; Predict enemy bases: active visible/remembered townhalls + post-early-window unscouted expansion
  (define visible-enemy-bases (max 1 eff-known-th-cnt))
  (define dark-matter-imminent-bases
    (cond
      [(or proxy-attack-near-us? (eq? hypothesis 'proxy-production-or-all-in)) 0]
      [(and (>= frame 6200) (= visible-enemy-bases 1) (>= delta-min 700)) 2]
      [(and (>= frame 4000) (<= visible-enemy-bases 2) (>= delta-min 500)) 1]
      [else 0]))
  (define pred-enemy-bases
    (min 12 (+ visible-enemy-bases dark-matter-imminent-bases)))

  ;; Predict enemy workers based on enemy bases, frame progression, & workers killed
  (define base-worker-cap (* 22 pred-enemy-bases))
  (define time-workers
    (max 4 (- (+ 12 (quotient (max 0 frame) (if (>= pred-enemy-bases 3) 200 268)))
              enemy-workers-killed)))
  (define pred-enemy-workers
    (min 80
         base-worker-cap
         (max visible-enemy-workers
              (if (eq? hypothesis 'proxy-production-or-all-in)
                  (min 18 time-workers)
                  time-workers))))

  (define static-defense? (or unit-static-def? bldg-static-def?))

  (define eff-enemy-bases
    (if (> frame 4000) pred-enemy-bases visible-enemy-bases))
  (define initial-verdict
    (cond
      [(and (>= (length enemy-townhalls) 3) (<= enemy-combat-count 4) (not proxy-attack-near-us?))
       ;; Strictly require POSITIVELY OBSERVED greedy expansions — never trigger on unscouted fog!
       'punish-And-Deny-Greedy-Expand]
      [(and (<= pred-enemy-bases 2) static-defense? (not proxy-attack-near-us?))
       'out-Expand-Passive-Turtle]
      [(or (>= near-enemy-combat-count 4)
           (and (<= frame 6048)
                (or (eq? hypothesis 'proxy-production-or-all-in)
                    (and (<= eff-enemy-bases 1)
                         (or proxy-attack-near-us?
                             (eq? hypothesis 'imminent-fog-timing-wave)
                             (>= enemy-combat-count 5))))))
       'defend-All-In-Then-Counter-Expand]
      [else
       'pace-Macro-And-Disrupt]))

  (define ledger
    (shadow-ledger expected-minerals
                   expected-gas
                   accounted-minerals
                   accounted-gas
                   delta-min
                   delta-gas
                   est-workers
                   hypothesis
                   pred-enemy-bases
                   pred-enemy-workers
                   initial-verdict))
  (define zs-reading
    (evaluate-zero-sum-negative-exclusions frame enemy-units enemy-bldgs tech-obs ledger))
  (set-mirror-mind-state-last-shadow-ledger! mstate ledger)
  (set-mirror-mind-state-last-zero-sum-reading! mstate zs-reading)
  (set-mirror-mind-state-predicted-enemy-bases! mstate pred-enemy-bases)
  (set-mirror-mind-state-predicted-enemy-workers! mstate pred-enemy-workers)
  (set-mirror-mind-state-mirror-macro-verdict! mstate initial-verdict)
  ledger)

(define compute-shadow-ledger compute-opponent-shadow-ledger)

;; =============================================================================
;; 4. Component 2: Action-Lens Inverse Planner (`interpret-opponent-actions`)
;; =============================================================================

(define (interpret-opponent-actions mstate raw-frame raw-enemy-units raw-enemy-bldgs ledger
                                    #:base-x [raw-base-x 32]
                                    #:base-y [raw-base-y 32]
                                    #:nat-x [raw-nat-x 50]
                                    #:nat-y [raw-nat-y 56])
  (define frame (safe-frame raw-frame))
  (define base-x (safe-coord raw-base-x 32))
  (define base-y (safe-coord raw-base-y 32))
  (define nat-x (safe-coord raw-nat-x 50))
  (define nat-y (safe-coord raw-nat-y 56))
  (define enemy-units (if (list? raw-enemy-units) raw-enemy-units '()))
  (define enemy-bldgs (if (list? raw-enemy-bldgs) raw-enemy-bldgs '()))

  (define fbx (exact->inexact base-x))
  (define fby (exact->inexact base-y))
  (define fnx (exact->inexact nat-x))
  (define fny (exact->inexact nat-y))
  (define scout-now? #f)
  (define mobile-poke-count 0)
  (define opponent-turtling? #f)
  (define near-nat-combat 0)
  (define near-nat-workers 0)
  (for ([u (in-list enemy-units)])
    (define ut (unit-type-sym u))
    (define ux (exact->inexact (safe-real (hash-ref u 'x 160.0) 160.0)))
    (define uy (exact->inexact (safe-real (hash-ref u 'y 160.0) 160.0)))
    (define dbx (fl- fbx ux))
    (define dby (fl- fby uy))
    (define db2 (fl+ (fl* dbx dbx) (fl* dby dby)))
    (define dnx (fl- fnx ux))
    (define dny (fl- fny uy))
    (define dn2 (fl+ (fl* dnx dnx) (fl* dny dny)))
    (when (and (not scout-now?)
               (fl<= db2 900.0)
               (memq ut '(probe scv drone overlord overseer reaper adept
                          observer phoenix hallucination mutalisk)))
      (set! scout-now? #t))
    (when (and (fl<= dn2 676.0)
               (memq ut '(reaper hellion adept stalker zergling roach mutalisk oracle banshee)))
      (set! mobile-poke-count (add1 mobile-poke-count)))
    (when (and (not opponent-turtling?)
               (memq ut '(bunker photon-cannon shield-battery spine-crawler
                          planetary-fortress siege-tank siege-tank-sieged
                          widow-mine widow-mine-burrowed liberator liberator-ag
                          lurker lurker-burrowed lurker-mp lurker-mp-burrowed)))
      (set! opponent-turtling? #t))
    (define near-nat-or-base? (or (fl<= dn2 784.0) (fl<= db2 1024.0)))
    (when near-nat-or-base?
      (when (enemy-combat-unit? u)
        (set! near-nat-combat (add1 near-nat-combat)))
      (when (memq ut '(drone probe scv))
        (set! near-nat-workers (add1 near-nat-workers)))))
  (when scout-now?
    (set-mirror-mind-state-ever-scouted-by-enemy?! mstate #t))
  (define scouted-us? (mirror-mind-state-ever-scouted-by-enemy? mstate))
  (define feint-detected?
    (and (>= mobile-poke-count 1)
         (<= (length enemy-units) 4)
         (or (>= (shadow-ledger-unaccounted-gas ledger) 150)
             (>= (shadow-ledger-unaccounted-minerals ledger) 400))))
  (define gas-bldgs 0)
  (define enemy-townhalls 0)
  (for ([b (in-list enemy-bldgs)])
    (define bt (unit-type-sym b))
    (when (and (not opponent-turtling?)
               (memq bt '(bunker photon-cannon shield-battery spine-crawler
                          planetary-fortress siege-tank siege-tank-sieged
                          widow-mine widow-mine-burrowed liberator liberator-ag
                          lurker lurker-burrowed lurker-mp lurker-mp-burrowed)))
      (set! opponent-turtling? #t))
    (cond
      [(memq bt '(refinery assimilator extractor))
       (set! gas-bldgs (add1 gas-bldgs))]
      [(memq bt '(nexus command-center orbital-command planetary-fortress
                  hatchery lair hive))
       (set! enemy-townhalls (add1 enemy-townhalls))]))
  (define early-gas?
    (or (>= gas-bldgs 2)
        (>= (shadow-ledger-unaccounted-gas ledger) 200)))
  (define pred-enemy-bases
    (if (shadow-ledger? ledger)
        (shadow-ledger-predicted-enemy-bases ledger)
        (max 1 enemy-townhalls)))
  ;; Only flag missing-nat? during the 1-base timing window (2688..6048) AND when
  ;; dark-matter ledger has NOT already inferred a hidden expansion (pred-enemy-bases <= 1).
  (define missing-nat?
    (and (>= frame 2688)
         (<= frame 6048)
         (<= enemy-townhalls 1)
         (<= pred-enemy-bases 1)))
  ;; L85C: Exclude a lone natural-pad `pylon`/`engineering-bay` expansion block (`dNat <= 7.5t`
  ;; and `dMain > 16.0t`, matching `bot-runtime.rkt:50389-50406`) so natural expansion blocks never
  ;; falsely trigger `action-lens-reading-proxy-or-rush-detected?` (`rush = 0.91`), while any 2nd
  ;; Pylon (cannon rush) or combat/production proxy structure still triggers immediately!
  (define-values (non-natblock-proxy-cnt natblock-bldg-cnt)
    (for/fold ([non-nb 0] [nb 0])
              ([b (in-list enemy-bldgs)]
               #:when (and (hash? b)
                           (not (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))))
      (define bx (exact->inexact (safe-real (hash-ref b 'x 160.0) 160.0)))
      (define by (exact->inexact (safe-real (hash-ref b 'y 160.0) 160.0)))
      (define dmx (fl- fbx bx))
      (define dmy (fl- fby by))
      (define d2-main (fl+ (fl* dmx dmx) (fl* dmy dmy)))
      (if (fl<= d2-main 1444.0) ; <= 38.0t from our main
          (let* ([bt (unit-type-sym b)]
                 [dnx (fl- fnx bx)]
                 [dny (fl- fny by)]
                 [d2-nat (fl+ (fl* dnx dnx) (fl* dny dny))])
            (if (and (memq bt '(pylon engineering-bay))
                     (fl> d2-main 256.0) ; > 16.0t from our main
                     (fl<= d2-nat 56.25)) ; <= 7.5t from our natural pad
                (values non-nb (add1 nb))
                (values (add1 non-nb) nb)))
          (values non-nb nb))))
  (define proxy-or-rush?
    (or (> non-natblock-proxy-cnt 0)
        (>= natblock-bldg-cnt 2)
        (and (< frame 2688)
             (or (>= near-nat-combat 3)
                 (>= near-nat-workers 3)))))

  (define inferred-intent
    (cond
      [proxy-or-rush?            'immediate-proxy-or-early-all-in]
      [feint-detected?           'front-poke-masking-drop-or-tech-switch]
      [(eq? (shadow-ledger-dark-matter-hypothesis ledger)
            'hidden-air-or-cloak-tech-switch)
       'hidden-air-or-cloak-transition]
      [(eq? (shadow-ledger-dark-matter-hypothesis ledger)
            'hidden-expansion-or-macro-boom)
       'hidden-ninja-expansion-or-macro-boom]
      [opponent-turtling?        'defensive-turtle-into-late-game-tech]
      [(and scouted-us? early-gas?) 'targeted-counter-tech-transition]
      [missing-nat?              'one-base-timing-attack-preparation]
      [else                      'standard-rational-macro]))

  (define reading
    (action-lens-reading scouted-us?
                         feint-detected?
                         opponent-turtling?
                         early-gas?
                         missing-nat?
                         proxy-or-rush?
                         inferred-intent))
  (set-mirror-mind-state-last-action-reading! mstate reading)
  reading)

;; Evaluate the Mirror-Mind Macro / Eco / Expansion Verdict:
;; Classifies the opponent's macro posture into one of:
;;   - 'punish-And-Deny-Greedy-Expand
;;   - 'out-Expand-Passive-Turtle
;;   - 'defend-All-In-Then-Counter-Expand
;;   - 'pace-Macro-And-Disrupt
;; and updates `mirror-mind-state` with recommended minimum bases and disruption priority.
(define (evaluate-mirror-macro-verdict mstate raw-frame raw-ally-units raw-ally-bldgs
                                       raw-enemy-units raw-enemy-bldgs ledger reading
                                       #:base-x [raw-base-x 32]
                                       #:base-y [raw-base-y 32]
                                       #:nat-x [raw-nat-x 50]
                                       #:nat-y [raw-nat-y 56])
  (define frame (safe-frame raw-frame))
  (define base-x (safe-coord raw-base-x 32))
  (define base-y (safe-coord raw-base-y 32))
  (define nat-x (safe-coord raw-nat-x 50))
  (define nat-y (safe-coord raw-nat-y 56))
  (define ally-bldgs (if (list? raw-ally-bldgs) raw-ally-bldgs '()))
  (define enemy-units (if (list? raw-enemy-units) raw-enemy-units '()))
  (define enemy-bldgs (if (list? raw-enemy-bldgs) raw-enemy-bldgs '()))
  (define our-townhalls
    (count (lambda (b)
             (memq (unit-type-sym b)
                   '(nexus command-center orbital-command planetary-fortress
                     hatchery lair hive)))
           ally-bldgs))
  (define our-bases (max 1 our-townhalls))
  (define visible-enemy-townhalls
    (count (lambda (b)
             (memq (unit-type-sym b)
                   '(nexus command-center orbital-command planetary-fortress
                     hatchery lair hive)))
           enemy-bldgs))
  (define pred-enemy-bases (shadow-ledger-predicted-enemy-bases ledger))
  (define pred-enemy-workers (shadow-ledger-predicted-enemy-workers ledger))
  (define enemy-combat-count
    (count enemy-combat-unit? enemy-units))
  (define near-combat-count
    (count (lambda (u)
             (and (enemy-combat-unit? u)
                  (or (<= (dist2d base-x base-y (hash-ref u 'x 160) (hash-ref u 'y 160)) 28.0)
                      (<= (dist2d nat-x nat-y (hash-ref u 'x 160) (hash-ref u 'y 160)) 22.0))))
           enemy-units))
  (define hyp (shadow-ledger-dark-matter-hypothesis ledger))
  (define turtling? (and reading (action-lens-reading-opponent-turtling? reading)))
  (define proxy-or-rush? (and reading (action-lens-reading-proxy-or-rush-detected? reading)))
  (define missing-nat? (and reading (action-lens-reading-missing-natural-expansion? reading)))

  (define active-attack-near-us?
    (>= near-combat-count 4))
  (define effective-enemy-bases
    (if (> frame 4000)
        pred-enemy-bases
        (max 1 visible-enemy-townhalls)))
  (define one-base-all-in-window?
    (and (<= frame 6048)
         (or proxy-or-rush?
             (eq? hyp 'proxy-production-or-all-in)
             (and (<= effective-enemy-bases 1)
                  (or missing-nat?
                      (eq? hyp 'imminent-fog-timing-wave)
                      (>= enemy-combat-count 5))))))

  (define verdict
    (cond
      [(and (not active-attack-near-us?)
            (not proxy-or-rush?)
            turtling?
            (<= visible-enemy-townhalls 2))
       'out-Expand-Passive-Turtle]
      [(and (not active-attack-near-us?)
            (not proxy-or-rush?)
            (not turtling?)
            (or (and (>= visible-enemy-townhalls 3) (<= enemy-combat-count 4))
                (and (>= visible-enemy-townhalls 2)
                     (> visible-enemy-townhalls our-bases)
                     (<= frame 2464)
                     (<= enemy-combat-count 2))))
       ;; Strictly require positively observed greedy expansions (never unscouted fog!)
       'punish-And-Deny-Greedy-Expand]
      [(or active-attack-near-us?
           one-base-all-in-window?)
       'defend-All-In-Then-Counter-Expand]
      [else
       'pace-Macro-And-Disrupt]))

  (define rec-min-bases
    (case verdict
      [(punish-And-Deny-Greedy-Expand)     (max (+ our-bases 1) pred-enemy-bases)]
      [(out-Expand-Passive-Turtle)         (max 3 (+ pred-enemy-bases 2))]
      [(defend-All-In-Then-Counter-Expand) (max 1 our-bases)]
      [else                                (max 2 (+ pred-enemy-bases 1))]))

  (define disrupt-prio
    (case verdict
      [(punish-And-Deny-Greedy-Expand)     'high-burrow-and-raider-disrupt]
      [(out-Expand-Passive-Turtle)         'contain-and-deny-third-base]
      [(defend-All-In-Then-Counter-Expand) 'low-hold-defense-then-counter-drop]
      [else                                'patrol-and-burrow-block-expansions]))

  (set-mirror-mind-state-predicted-enemy-bases! mstate pred-enemy-bases)
  (set-mirror-mind-state-predicted-enemy-workers! mstate pred-enemy-workers)
  (set-mirror-mind-state-mirror-macro-verdict! mstate verdict)
  (set-mirror-mind-state-recommended-min-bases! mstate rec-min-bases)
  (set-mirror-mind-state-disruption-priority! mstate disrupt-prio)
  (values verdict pred-enemy-bases pred-enemy-workers rec-min-bases disrupt-prio))

;; =============================================================================
;; 5. Component 3: Generic Recursive k-Level Cognitive Hierarchy (`predict-at-depth`)
;; =============================================================================

(define ALL-RATIONAL-TECH
  '(spawning-pool roach-warren baneling-nest lair hydralisk-den spire lurker-den
    infestation-pit hive ultralisk-cavern greater-spire
    barracks barracks-techlab factory factory-techlab starport starport-techlab armory ghost-academy fusion-core
    gateway cybernetics-core robotics-facility robotics-bay stargate twilight-council templar-archive dark-shrine fleet-beacon))

(define MIRROR-BUILDING-OR-NONCOMBAT-HT
  (hasheq
   'drone #t 'scv #t 'probe #t 'mule #t
   'larva #t 'egg #t 'cocoon #t 'baneling-cocoon #t 'ravager-cocoon #t 'lurker-cocoon #t 'brood-lord-cocoon #t
   'overlord #t 'overlord-cocoon #t 'overlord-transport #t 'transport-overlord-cocoon #t 'dropperlord #t
   'overseer #t 'overseer-siege-mode #t 'observer #t 'observer-siege-mode #t
   'changeling #t 'changeling-zealot #t 'changeling-marine #t 'changeling-marine-shield #t
   'changeling-zergling #t 'changeling-zergling-wings #t
   'locust-flying #t 'locust-mp-flying #t
   'creep-tumor #t 'creep-tumor-burrowed #t 'creep-tumor-queen #t 'point-defense-drone #t
   'hatchery #t 'lair #t 'hive #t 'spawning-pool #t 'extractor #t 'extractor-rich #t
   'roach-warren #t 'baneling-nest #t 'hydralisk-den #t 'lurker-den #t 'lurker-den-mp #t
   'spire #t 'greater-spire #t 'infestation-pit #t 'ultralisk-cavern #t 'evolution-chamber #t
   'spine-crawler #t 'spore-crawler #t 'spine-crawler-uprooted #t 'spore-crawler-uprooted #t
   'nydus-network #t 'nydus-canal #t
   'command-center #t 'command-center-flying #t 'orbital-command #t 'orbital-command-flying #t
   'planetary-fortress #t 'supply-depot #t 'supply-depot-lowered #t 'refinery #t 'refinery-rich #t
   'barracks #t 'barracks-flying #t 'barracks-techlab #t 'barracks-reactor #t
   'factory #t 'factory-flying #t 'factory-techlab #t 'factory-reactor #t
   'starport #t 'starport-flying #t 'starport-techlab #t 'starport-reactor #t
   'engineering-bay #t 'armory #t 'fusion-core #t 'ghost-academy #t
   'bunker #t 'missile-turret #t 'sensor-tower #t 'techlab #t 'reactor #t
   'nexus #t 'pylon #t 'assimilator #t 'assimilator-rich #t 'gateway #t 'warp-gate #t 'warpgate #t
   'forge #t 'cybernetics-core #t 'photon-cannon #t 'shield-battery #t 'twilight-council #t
   'robotics-facility #t 'robotics-bay #t 'robotics-support-bay #t 'stargate #t
   'templar-archive #t 'dark-shrine #t 'fleet-beacon #t))

(define (mirror-building-or-noncombat-sym? sym)
  (and (symbol? sym)
       (or (hash-ref MIRROR-BUILDING-OR-NONCOMBAT-HT sym #f)
           (and (not (hash-ref SC2-UNIT-COMBAT-STATS-TABLE sym #f))
                (zero? (sc2-supply-cost sym 1))))))

(define (mirror-combat-unit-entry? u)
  (define sym (unit-type-sym u))
  (and (symbol? sym)
       (not (eq? sym 'unknown))
       (not (mirror-building-or-noncombat-sym? sym))))

(define PROTOSS-AIR-TECH-SYMS
  '(void-ray voidray carrier tempest oracle phoenix mothership stargate fleet-beacon))
(define PROTOSS-AIR-COMBAT-SYMS
  '(void-ray voidray carrier tempest oracle phoenix mothership))
(define PROTOSS-CAPITAL-AIR-SYMS
  '(carrier tempest mothership void-ray voidray))
(define TERRAN-AIR-COMBAT-SYMS
  '(viking viking-fighter viking-assault banshee battlecruiser liberator liberator-ag raven))
(define TERRAN-AIR-TECH-SYMS
  '(viking viking-fighter viking-assault banshee battlecruiser liberator liberator-ag raven
    starport starport-techlab starport-reactor fusion-core))
(define ZERG-AIR-COMBAT-SYMS
  '(mutalisk corruptor brood-lord viper))
(define ZERG-AIR-TECH-SYMS
  '(mutalisk corruptor brood-lord viper spire greater-spire))

(define (mirror-canonical-unit-sym sym)
  (case sym
    [(voidray) 'void-ray]
    [(warpgate) 'warp-gate]
    [(lurker-mp lurker-burrowed lurker-mp-burrowed) 'lurker]
    [(siege-tank-sieged) 'siege-tank]
    [(liberator-ag) 'liberator]
    [(thor-ap) 'thor]
    [(viking) 'viking-fighter]
    [(zergling-burrowed) 'zergling]
    [(baneling-burrowed) 'baneling]
    [(roach-burrowed) 'roach]
    [(ravager-burrowed) 'ravager]
    [(hydralisk-burrowed) 'hydralisk]
    [(infestor-burrowed) 'infestor]
    [(ultralisk-burrowed) 'ultralisk]
    [else sym]))

(define (mirror-accumulate-unit-counts! counts-ht raw-items)
  (define (add-sym! s [n 1])
    (when (and (symbol? s) (not (eq? s 'unknown)) (> n 0))
      (define c (mirror-canonical-unit-sym s))
      (hash-set! counts-ht c (+ (hash-ref counts-ht c 0) n))))
  (cond
    [(hash? raw-items)
     (for ([(k v) (in-hash raw-items)])
       (when (and (symbol? k) (number? v) (> v 0))
         (add-sym! k (exact-round v))))]
    [(list? raw-items)
     (for ([item (in-list raw-items)])
       (cond
         [(symbol? item) (add-sym! item 1)]
         [(and (pair? item) (symbol? (car item)) (number? (cdr item)))
          (add-sym! (car item) (exact-round (cdr item)))]
         [(hash? item)
          (define s (unit-type-sym item))
          (define cnt (safe-int (hash-ref item 'count 1) 1))
          (add-sym! s (max 1 cnt))]))]))

(define (mirror-classify-enemy-archetype raw-enemy-units [raw-enemy-bldgs '()] [enemy-race #f])
  (define counts-ht (make-hasheq))
  (mirror-accumulate-unit-counts! counts-ht raw-enemy-units)
  (mirror-accumulate-unit-counts! counts-ht raw-enemy-bldgs)
  (define (cnt syms)
    (for/sum ([s (in-list syms)])
      (hash-ref counts-ht s 0)))
  (define proto-air-units (cnt '(void-ray carrier tempest oracle phoenix mothership)))
  (define proto-air-bldgs (cnt '(stargate fleet-beacon)))
  (define proto-air-cnt (+ proto-air-units proto-air-bldgs))
  (define proto-gnd-units (cnt '(zealot stalker adept sentry colossus immortal archon disruptor high-templar dark-templar)))
  (define proto-gnd-bldgs (cnt '(gateway warp-gate cybernetics-core twilight-council robotics-facility robotics-bay robotics-support-bay templar-archive dark-shrine forge)))
  (define proto-gnd-cnt (+ proto-gnd-units proto-gnd-bldgs))
  (define terran-air-units (cnt '(viking-fighter viking-assault banshee battlecruiser liberator raven)))
  (define terran-air-bldgs (cnt '(starport starport-techlab starport-reactor fusion-core)))
  (define terran-air-cnt (+ terran-air-units terran-air-bldgs))
  (define terran-bio-cnt (cnt '(marine marauder reaper ghost medivac barracks barracks-techlab barracks-reactor ghost-academy)))
  (define terran-mech-cnt (cnt '(siege-tank hellion hellbat cyclone thor widow-mine widow-mine-burrowed factory factory-techlab factory-reactor armory)))
  (define zerg-air-units (cnt '(mutalisk corruptor brood-lord viper)))
  (define zerg-air-bldgs (cnt '(spire greater-spire)))
  (define zerg-air-cnt (+ zerg-air-units zerg-air-bldgs))
  (define zerg-lurker-cnt (cnt '(lurker lurker-den lurker-den-mp)))
  (define zerg-roach-cnt (cnt '(roach ravager roach-warren)))
  (define zerg-ling-cnt (cnt '(zergling)))
  (define zerg-bane-hydra-cnt (cnt '(baneling hydralisk swarm-host ultralisk baneling-nest hydralisk-den infestation-pit ultralisk-cavern)))
  (define race-sym (and enemy-race (normalize-known-race enemy-race)))
  (define proto-evidence (+ proto-air-cnt proto-gnd-cnt (hash-ref counts-ht 'nexus 0) (hash-ref counts-ht 'pylon 0) (hash-ref counts-ht 'probe 0)))
  (define terran-evidence (+ terran-air-cnt terran-bio-cnt terran-mech-cnt (hash-ref counts-ht 'command-center 0) (hash-ref counts-ht 'orbital-command 0) (hash-ref counts-ht 'scv 0)))
  (define zerg-evidence (+ zerg-air-cnt zerg-lurker-cnt zerg-roach-cnt zerg-ling-cnt zerg-bane-hydra-cnt (hash-ref counts-ht 'hatchery 0) (hash-ref counts-ht 'lair 0) (hash-ref counts-ht 'hive 0) (hash-ref counts-ht 'spawning-pool 0) (hash-ref counts-ht 'drone 0)))
  (define eff-race
    (cond
      [(memq race-sym '(Protoss Terran Zerg)) race-sym]
      [(and (> proto-evidence terran-evidence) (> proto-evidence zerg-evidence)) 'Protoss]
      [(and (> terran-evidence proto-evidence) (> terran-evidence zerg-evidence)) 'Terran]
      [(> zerg-evidence 0) 'Zerg]
      [else 'Unknown]))
  (cond
    [(eq? eff-race 'Protoss)
     (cond
       ;; Strict Stargate/Air guard: Protoss MUST have actual Protoss air/Stargate units or buildings
       ;; (observer/warp-prism/colossus alone are NEVER sufficient for 'sky-toss or 'air-fleet).
       [(and (> proto-air-cnt 0)
             (or (>= (+ (cnt '(carrier tempest mothership)) (hash-ref counts-ht 'fleet-beacon 0)) 2)
                 (>= proto-air-units (max 2 proto-gnd-units))
                 (and (>= proto-air-bldgs 1) (<= proto-gnd-units 4))
                 (>= proto-air-units 3)))
        'sky-toss]
       [(>= (cnt '(stalker colossus immortal archon disruptor high-templar dark-templar cybernetics-core twilight-council robotics-facility robotics-bay templar-archive dark-shrine)) 1)
        'stalker-colossus]
       [(>= (+ proto-gnd-units proto-gnd-bldgs) 1)
        (if (< proto-gnd-units 4) 'early-rush 'stalker-colossus)]
       [else 'standard-macro])]
    [(eq? eff-race 'Terran)
     (cond
       [(and (> terran-air-cnt 0)
             (or (>= terran-air-units (max 2 (+ terran-bio-cnt terran-mech-cnt)))
                 (and (>= terran-air-bldgs 1) (< (+ terran-bio-cnt terran-mech-cnt) 4))))
        'terran-air]
       [(and (> terran-mech-cnt 0)
             (>= terran-mech-cnt (max 1 (quotient terran-bio-cnt 2))))
        'mech-siege]
       [(> terran-bio-cnt 0)
        'bio-ball]
       [else 'standard-macro])]
    [(eq? eff-race 'Zerg)
     (cond
       [(>= zerg-lurker-cnt 1) 'lurker-contain]
       [(and (> zerg-air-cnt 0)
             (>= zerg-air-cnt (max 2 (+ zerg-roach-cnt zerg-bane-hydra-cnt))))
        'muta-flock]
       [(and (> zerg-roach-cnt 0)
             (>= zerg-roach-cnt (max 1 (+ zerg-bane-hydra-cnt (quotient zerg-ling-cnt 4)))))
        'roach-ravager]
       [(or (> zerg-bane-hydra-cnt 0) (>= zerg-ling-cnt 8))
        'ling-bane-hydra]
       [(> zerg-ling-cnt 0)
        'zergling-flood]
       [else 'standard-macro])]
    [else
     (cond
       [(> proto-air-cnt 0) 'sky-toss]
       [(> terran-air-cnt 0) 'terran-air]
       [(> zerg-air-cnt 0) 'muta-flock]
       [else 'standard-macro])]))

(define (unit-to-archetype unit-sym)
  (case unit-sym
    [(marine marauder reaper ghost medivac
      barracks barracks-techlab barracks-reactor ghost-academy)
     'bio-ball]
    [(siege-tank siege-tank-sieged hellion hellbat cyclone thor thor-ap widow-mine widow-mine-burrowed
      factory factory-techlab armory)
     'mech-siege]
    [(zealot stalker adept sentry colossus immortal archon disruptor
      high-templar dark-templar
      gateway warp-gate cybernetics-core twilight-council robotics-facility robotics-bay templar-archive dark-shrine)
     'stalker-colossus]
    [(void-ray voidray carrier tempest oracle phoenix mothership
      stargate fleet-beacon)
     'sky-toss]
    [(viking viking-fighter viking-assault banshee battlecruiser liberator liberator-ag raven
      starport starport-techlab starport-reactor fusion-core)
     'terran-air]
    [(zergling zergling-burrowed baneling baneling-burrowed hydralisk hydralisk-burrowed
      lurker lurker-burrowed lurker-mp lurker-mp-burrowed queen queen-burrowed ultralisk ultralisk-burrowed swarm-host
      spawning-pool baneling-nest hydralisk-den lurker-den lurker-den-mp infestation-pit ultralisk-cavern)
     'ling-bane-hydra]
    [(roach roach-burrowed ravager ravager-burrowed roach-warren)
     'roach-ravager]
    [(mutalisk corruptor brood-lord viper infestor infestor-burrowed spire greater-spire)
     'muta-flock]
    [else
     'early-rush]))

(define (archetype-signature-unit race arch [frame 0] [enemy-air-ratio 0.0] [available-tech #f])
  (define tech-list (and (list? available-tech) (not (null? available-tech)) available-tech))
  (define f (safe-int frame 0))
  (define ar (max 0.0 (min 1.0 (safe-real enemy-air-ratio 0.0))))
  (case arch
    [(bio-ball)          'marauder]
    [(mech-siege)        'siege-tank]
    [(stalker-colossus protoss-deathball) 'stalker]
    [(sky-toss air-fleet terran-air)
     (case race
       [(Terran)
        ;; Never return 'banshee against air/SkyToss (Banshees have 0.0 air DPS).
        ;; Choose phase- and tech-appropriate Terran AA: Viking-Fighter / Thor / Marine.
        (cond
          [(and tech-list
                (not (memq 'starport tech-list))
                (not (memq 'armory tech-list)))
           'marine]
          [(and (>= f 13440)
                (>= ar 0.60)
                (or (not tech-list) (memq 'armory tech-list)))
           'thor]
          [else 'viking-fighter])]
       [(Zerg)
        (cond
          [(and tech-list
                (not (memq 'spire tech-list))
                (not (memq 'greater-spire tech-list)))
           (if (memq 'hydralisk-den tech-list) 'hydralisk 'queen)]
          [else 'corruptor])]
       [else 'void-ray])]
    [(ling-bane-hydra)   'hydralisk]
    [(lurker-contain)    'lurker]
    [(zergling-flood)    'zergling]
    [(roach-ravager)     'roach]
    [(muta-flock)
     (case race
       [(Terran)
        (if (and (>= f 11000) (or (not tech-list) (memq 'armory tech-list)))
            'thor
            'marine)]
       [(Protoss) 'phoenix]
       [else 'mutalisk])]
    [else                (case race [(Terran) 'marine] [(Protoss) 'zealot] [else 'zergling])]))

(define (race-hidden-gas-threat enemy-race)
  (case enemy-race
    [(Protoss) 'void-ray]
    [(Terran)  'banshee]
    [(Zerg)    'mutalisk]
    [else      'void-ray]))

(define (mirror-unit-gas-cost sym)
  (cdr (unit-resource-cost sym)))

(define (mirror-unit-min-cost sym)
  (car (unit-resource-cost sym)))

(define (mirror-tech-has? tech-list reqs)
  (cond
    [(null? reqs) #t]
    [else
     (for/and ([r (in-list reqs)])
       (not (not (memq r tech-list))))]))

(define (mirror-unit-required-tech u)
  (case u
    [(marine) '(barracks)]
    [(marauder) '(barracks-techlab)]
    [(reaper) '(barracks)]
    [(ghost) '(barracks-techlab ghost-academy)]
    [(hellion hellbat) '(factory)]
    [(widow-mine) '(factory)]
    [(cyclone) '(factory-techlab)]
    [(siege-tank) '(factory-techlab)]
    [(thor) '(factory armory)]
    [(viking viking-fighter medivac liberator) '(starport)]
    [(banshee raven) '(starport-techlab)]
    [(battlecruiser) '(starport-techlab fusion-core)]
    [(zergling queen) '(spawning-pool)]
    [(roach ravager) '(roach-warren)]
    [(baneling) '(spawning-pool baneling-nest)]
    [(hydralisk) '(lair hydralisk-den)]
    [(lurker) '(lair hydralisk-den lurker-den)]
    [(mutalisk corruptor) '(lair spire)]
    [(brood-lord) '(hive greater-spire)]
    [(infestor swarm-host) '(lair infestation-pit)]
    [(viper) '(hive infestation-pit)]
    [(ultralisk) '(hive ultralisk-cavern)]
    [(zealot) '(gateway)]
    [(stalker sentry adept) '(cybernetics-core)]
    [(immortal observer warp-prism) '(cybernetics-core robotics-facility)]
    [(colossus disruptor) '(robotics-facility robotics-bay)]
    [(phoenix void-ray oracle) '(cybernetics-core stargate)]
    [(tempest carrier) '(stargate fleet-beacon)]
    [(high-templar archon) '(twilight-council templar-archive)]
    [(dark-templar) '(twilight-council dark-shrine)]
    [else '()]))

;; Phase-, enemy air-ratio-, and opportunity-cost-aware unit counter selector.
;; Replaces trap/zero-air-DPS assignments (e.g., Terran 'banshee vs SkyToss),
;; enforces <40-worker / unfinished-natural gas-heavy penalties, avoids late-game
;; un-upgraded T1 units into splash, and accounts for enemy air share.
(define (counter-unit-for-archetype
         race
         target-archetype
         [available-tech ALL-RATIONAL-TECH]
         [raw-minerals 400]
         [raw-gas 200]
         #:frame [frame 6000]
         #:enemy-air-ratio [raw-air-ratio 0.0]
         #:workers [raw-workers 44]
         #:natural-ready? [natural-ready? #t]
         #:researched-upgrades [raw-upgrades '()]
         #:enemy-unit [enemy-unit #f]
         #:enemy-has-splash? [enemy-has-splash? #f])
  (define r (normalize-known-race race))
  (define arch (if (symbol? target-archetype) target-archetype 'standard-macro))
  (define minerals (max 250 (safe-int raw-minerals 400)))
  (define gas (max 150 (safe-int raw-gas 200)))
  (define f (max 0 (safe-int frame 6000)))
  (define air-ratio (max 0.0 (min 1.0 (safe-real raw-air-ratio 0.0))))
  (define workers (max 0 (safe-int raw-workers 44)))
  (define upgs (safe-list raw-upgrades))
  (define tech-list
    (if (or (not (list? available-tech)) (null? available-tech))
        ALL-RATIONAL-TECH
        available-tech))
  (define econ-constrained?
    (or (< workers 40) (not natural-ready?)))
  (define splash-present?
    (or enemy-has-splash?
        (not (not (memq enemy-unit '(colossus siege-tank siege-tank-sieged baneling lurker lurker-mp lurker-mp-burrowed high-templar archon disruptor hellbat liberator liberator-ag))))
        (not (not (memq arch '(stalker-colossus protoss-deathball mech-siege lurker-contain ling-bane-hydra))))))
  (define air-threat?
    (or (memq arch '(sky-toss air-fleet terran-air muta-flock))
        (>= air-ratio 0.35)
        (not (not (memq enemy-unit '(void-ray voidray carrier tempest oracle phoenix mothership battlecruiser banshee liberator liberator-ag viking viking-fighter raven mutalisk corruptor brood-lord viper))))))
  (define (feasible? u [allow-expensive? #t])
    (define reqs (mirror-unit-required-tech u))
    (define m-cost (mirror-unit-min-cost u))
    (define g-cost (mirror-unit-gas-cost u))
    (define gas-hog? (>= g-cost 150))
    (and (mirror-tech-has? tech-list reqs)
         (>= minerals (max 50 m-cost))
         (>= gas g-cost)
         (or allow-expensive?
             (not econ-constrained?)
             (not gas-hog?))))
  (define (pick-first candidates default-unit [allow-expensive? (not econ-constrained?)])
    (or (for/first ([c (in-list candidates)] #:when (feasible? c allow-expensive?)) c)
        (for/first ([c (in-list candidates)] #:when (feasible? c #t)) c)
        default-unit))
  (cond
    ;; 1. Air-dominant / SkyToss / Air-Fleet / Terran-Air / Muta-Flock branch
    [air-threat?
     (case r
       [(Terran)
        (cond
          ;; Never choose 'banshee or 'marauder against air threats!
          [(eq? arch 'muta-flock)
           (if (< f 5500)
               (pick-first '(marine cyclone widow-mine) 'marine #t)
               (pick-first (if (>= air-ratio 0.50)
                               '(thor marine cyclone liberator)
                               '(marine thor widow-mine))
                           'marine))]
          [(or (memq enemy-unit '(tempest carrier void-ray voidray battlecruiser liberator liberator-ag))
               (memq arch '(sky-toss air-fleet terran-air)))
           (cond
             ;; Heavy late-game mass air with Armory & strong econ -> Thor + Viking
             [(and (>= f 13440)
                   (>= air-ratio 0.65)
                   (not econ-constrained?)
                   (not (eq? enemy-unit 'tempest))
                   (feasible? 'thor #t))
              'thor]
             [(and (< f 4200) (not (memq 'starport tech-list)))
              'marine]
             [else
              (pick-first '(viking-fighter marine thor) 'marine)])]
          [else
           (pick-first '(viking-fighter marine thor) 'marine)])]
       [(Zerg)
        (cond
          [(< f 4200)
           (pick-first '(queen hydralisk spore-crawler) 'queen #t)]
          [(and (or (>= air-ratio 0.45)
                    (memq enemy-unit '(carrier tempest mothership battlecruiser brood-lord))
                    (>= f 11000))
                (feasible? 'corruptor #t))
           'corruptor]
          [(eq? arch 'muta-flock)
           (pick-first '(hydralisk queen corruptor) 'queen)]
          [else
           (pick-first '(corruptor hydralisk queen) 'queen)])]
       [(Protoss)
        (cond
          [(eq? arch 'muta-flock)
           (pick-first '(phoenix archon stalker) 'stalker)]
          [(and (>= f 13440) (>= air-ratio 0.55) (not econ-constrained?) (feasible? 'tempest #t))
           'tempest]
          [else
           (pick-first '(void-ray stalker tempest phoenix) 'stalker)])]
       [else 'marine])]

    ;; 2. Ground situational, phase, splash & opportunity-cost branches
    [else
     (define late-t1-splash? (and (> f 13440) splash-present?))
     (define marine-upgraded?
       (for/or ([u (in-list upgs)])
         (not (not (memq u '(stimpack stimpack-cast combat-shield combat-shields shield-wall shieldwall))))))
     (define zealot-charged?
       (for/or ([u (in-list upgs)])
         (not (not (memq u '(charge zealot-charge))))))
     (define base-choice
       (case r
         [(Terran)
          (case arch
            [(mech-siege)
             (pick-first (if (>= f 11000)
                             '(viking-fighter liberator marauder siege-tank)
                             '(marauder siege-tank viking-fighter))
                         'marauder)]
            [(lurker-contain)
             (pick-first (if (>= f 11000)
                             '(siege-tank ghost liberator marauder)
                             '(siege-tank marauder))
                         'marauder)]
            [(bio-ball)
             (pick-first '(siege-tank marine marauder) 'marine)]
            [(roach-ravager)
             (pick-first '(marauder siege-tank marine) 'marauder)]
            [(zergling-flood early-rush)
             (pick-first (if (< f 6500) '(hellion widow-mine marine) '(hellbat siege-tank widow-mine))
                         'marine)]
            [(ling-bane-hydra)
             (pick-first '(siege-tank widow-mine hellbat marine) 'marine)]
            [(stalker-colossus protoss-deathball)
             (cond
               [(eq? enemy-unit 'colossus)
                (pick-first '(viking-fighter marauder liberator) 'marauder)]
               [(memq enemy-unit '(high-templar archon disruptor))
                (pick-first '(ghost marauder liberator) 'marauder)]
               [(memq enemy-unit '(stalker immortal zealot adept))
                (pick-first '(marauder siege-tank marine) 'marauder)]
               [else
                (pick-first '(marauder siege-tank ghost viking-fighter) 'marauder)])]
            [else #f])]
         [(Zerg)
          (case arch
            [(mech-siege)
             (pick-first (if (and (>= f 12000) (not econ-constrained?))
                             '(ravager viper corruptor hydralisk roach)
                             '(ravager roach hydralisk))
                         'roach)]
            [(lurker-contain)
             (pick-first '(lurker ravager roach hydralisk) 'roach)]
            [(bio-ball)
             (pick-first (if (and (>= f 13440) (not econ-constrained?))
                             '(baneling ultralisk hydralisk roach)
                             '(baneling hydralisk roach zergling))
                         'zergling)]
            [(roach-ravager)
             (pick-first (if (>= f 9000)
                             '(lurker ravager roach hydralisk)
                             '(roach ravager))
                         'roach)]
            [(zergling-flood early-rush)
             (pick-first '(baneling roach zergling queen) 'zergling)]
            [(ling-bane-hydra)
             (pick-first (if (>= f 9000) '(lurker baneling roach) '(baneling roach)) 'roach)]
            [(stalker-colossus protoss-deathball)
             (cond
               [(eq? enemy-unit 'colossus)
                (pick-first '(corruptor lurker ravager roach) 'roach)]
               [(eq? enemy-unit 'immortal)
                (pick-first (if late-t1-splash? '(hydralisk lurker ravager roach) '(hydralisk zergling roach)) 'roach)]
               [else
                (pick-first (if late-t1-splash? '(lurker hydralisk ravager roach) '(hydralisk roach zergling)) 'roach)])]
            [else #f])]
         [(Protoss)
          (case arch
            [(mech-siege)
             (pick-first (if (not econ-constrained?)
                             '(immortal disruptor zealot phoenix)
                             '(immortal zealot stalker))
                         'immortal)]
            [(lurker-contain)
             ;; Trap avoidance: never over-mass Stalkers into Lurkers!
             (pick-first (if (not econ-constrained?)
                             '(immortal disruptor carrier archon)
                             '(immortal adept))
                         'immortal)]
            [(bio-ball)
             (pick-first (if (not econ-constrained?)
                             '(colossus high-templar archon zealot)
                             '(immortal zealot adept stalker))
                         'zealot)]
            [(roach-ravager)
             ;; Trap avoidance: Immortals counter Roaches/Ravagers; avoid mass Stalkers.
             (pick-first '(immortal archon zealot) 'immortal)]
            [(zergling-flood early-rush)
             (pick-first (if (< f 6500) '(adept zealot sentry) '(archon zealot adept immortal)) 'adept)]
            [(ling-bane-hydra)
             (pick-first (if (not econ-constrained?)
                             '(colossus archon high-templar zealot)
                             '(adept immortal stalker))
                         'immortal)]
            [(stalker-colossus protoss-deathball)
             (pick-first '(immortal disruptor archon zealot) 'immortal)]
            [else #f])]
         [else #f]))
     (define resolved
       (or base-choice
           (and enemy-unit
                (attribute-counter-unit-for-enemy r enemy-unit tech-list minerals gas))
           (let* ([tree (get-race-counter-tree r)]
                  [res (resolve-demand-pull tree arch tech-list #:minerals minerals #:gas gas)])
             (if (hash? res) (hash-ref res 'selected-unit 'marine) res))))
     ;; Enforce late-game fragile T1 penalty vs splash & economic gas gate
     (cond
       [(and late-t1-splash? (eq? r 'Zerg) (eq? resolved 'zergling))
        (pick-first '(roach ravager hydralisk lurker) 'roach)]
       [(and late-t1-splash? (eq? r 'Terran) (eq? resolved 'marine) (not marine-upgraded?))
        (pick-first '(marauder siege-tank liberator ghost) 'marauder)]
       [(and late-t1-splash? (eq? r 'Protoss) (eq? resolved 'zealot) (not zealot-charged?))
        (pick-first '(immortal archon colossus stalker) 'immortal)]
       [(and econ-constrained? (>= (mirror-unit-gas-cost resolved) 150))
        (case r
          [(Terran) (pick-first '(marine marauder viking-fighter) resolved #t)]
          [(Zerg)   (pick-first '(roach ravager queen zergling) resolved #t)]
          [(Protoss) (pick-first '(zealot adept stalker immortal) resolved #t)]
          [else resolved])]
       [else resolved])]))

(define (excluded-branch->bldgs branch)
  (case branch
    [(stargate-air-rush fleet-beacon-carriers) '(stargate fleet-beacon)]
    [(colossus-thermal-lance-rush)             '(robotics-bay robotics-support-bay)]
    [(templar-archive-storm)                   '(templar-archive templar-archives)]
    [(dark-shrine-dt-rush)                     '(dark-shrine)]
    [(spire-mutalisk-rush early-brood-lord-rush) '(spire greater-spire)]
    [(lurker-den-siege)                        '(lurker-den lurker-den-mp)]
    [(early-ultralisk-rush)                    '(ultralisk-cavern)]
    [(baneling-flood-bust)                     '(baneling-nest)]
    [(battlecruiser-fusion-rush)               '(fusion-core starport)]
    [(mass-factory-mech-thor)                  '(factory-techlab armory)]
    [(bio-stim-marine-marauder-flood heavy-bio-stim-timing) '(barracks-techlab)]
    [else                                      '()]))

;; Compute the opponent's feasible tech tree & remaining gas budget from our
;; base-layer `enemy-tech-observation` and `zero-sum-exclusion-reading`, so
;; that deeper depths (d = 1, 2, 3, ..., k) automatically respect crippled
;; tech structures and zero-sum negative exclusions!
(define (compute-enemy-feasible-tech-and-budget mstate)
  (define tech-obs (mirror-mind-state-last-tech-observation mstate))
  (define zs-reading (mirror-mind-state-last-zero-sum-reading mstate))
  (define ledger (mirror-mind-state-last-shadow-ledger mstate))
  (define crippled
    (if tech-obs (enemy-tech-observation-crippled-tech-buildings tech-obs) '()))
  (define implied
    (if tech-obs (enemy-tech-observation-implied-tech-buildings tech-obs) '()))
  (define bluff?
    (and zs-reading (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)))
  (define excluded-branches
    (if (and zs-reading (not bluff?))
        (zero-sum-exclusion-reading-excluded-tech-branches zs-reading)
        '()))
  (define excluded-bldgs
    (apply append (map excluded-branch->bldgs excluded-branches)))
  (define base-tech
    (remove-duplicates (append ALL-RATIONAL-TECH implied)))
  (define feasible-tech
    (filter (lambda (b)
              (and (not (memq b crippled))
                   (not (memq b excluded-bldgs))))
            base-tech))
  (define rem-min
    (max 250 (if ledger (shadow-ledger-unaccounted-minerals ledger) 350)))
  (define rem-gas
    (if zs-reading
        (max 100 (zero-sum-exclusion-reading-remaining-gas-budget zs-reading))
        200))
  (values feasible-tech rem-min rem-gas crippled excluded-bldgs bluff?))

;; Constrain a raw predicted enemy unit to the opponent's feasible tech tree,
;; crippled buildings, and committed zero-sum branch.
(define (constrain-enemy-unit-to-feasible-tech enemy-race raw-unit feasible-tech zs-reading tech-obs)
  (define crippled
    (if tech-obs (enemy-tech-observation-crippled-tech-buildings tech-obs) '()))
  (define bluff?
    (and zs-reading (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)))
  (define committed-branch
    (if (and zs-reading (not bluff?))
        (zero-sum-exclusion-reading-committed-primary-branch zs-reading)
        'uncommitted))
  (define excluded-branches
    (if (and zs-reading (not bluff?))
        (zero-sum-exclusion-reading-excluded-tech-branches zs-reading)
        '()))
  (define excluded-bldgs
    (apply append (map excluded-branch->bldgs excluded-branches)))
  (define unit-prereqs (implied-prereqs-for-sym raw-unit))
  (define prereq-violated?
    (ormap (lambda (p)
             (or (memq p crippled)
                 (memq p excluded-bldgs)))
           unit-prereqs))
  (define branch-violated?
    (case committed-branch
      [(twilight-templar-ground)
       (memq raw-unit '(void-ray carrier tempest phoenix oracle colossus))]
      [(stargate-sky-fleet)
       (memq raw-unit '(high-templar archon dark-templar colossus))]
      [(robotics-heavy-siege)
       (memq raw-unit '(void-ray carrier tempest phoenix oracle high-templar))]
      [(roach-ravager-ground)
       (memq raw-unit '(mutalisk corruptor baneling))]
      [(infestor-queen-spell)
       (memq raw-unit '(mutalisk baneling))]
      [(ling-bane-flood)
       (memq raw-unit '(brood-lord lurker ultralisk))]
      [(spire-air-muta)
       (memq raw-unit '(lurker ultralisk))]
      [(hydra-lurker-den)
       (memq raw-unit '(mutalisk corruptor brood-lord))]
      [(bio-stim-medivac)
       (memq raw-unit '(battlecruiser thor siege-tank))]
      [(factory-mech-siege)
       (memq raw-unit '(battlecruiser marauder))]
      [(starport-cloak-or-bc)
       (memq raw-unit '(thor marauder))]
      [else #f]))

  (if (not (or prereq-violated? branch-violated?))
      raw-unit
      (case committed-branch
        [(twilight-templar-ground) 'archon]
        [(stargate-sky-fleet)
         (if (memq 'fleet-beacon feasible-tech) 'tempest 'void-ray)]
        [(robotics-heavy-siege)
         (if (memq 'robotics-bay feasible-tech) 'colossus 'immortal)]
        [(roach-ravager-ground)    'ravager]
        [(infestor-queen-spell)    'infestor]
        [(ling-bane-flood)         'baneling]
        [(spire-air-muta)          'mutalisk]
        [(hydra-lurker-den)
         (if (memq 'lurker-den feasible-tech) 'lurker 'hydralisk)]
        [(bio-stim-medivac)        'marauder]
        [(factory-mech-siege)      'siege-tank]
        [(starport-cloak-or-bc)
         (if (and tech-obs
                  (enemy-tech-observation-requires-anti-air? tech-obs)
                  (not (enemy-tech-observation-requires-detection? tech-obs)))
             'viking-fighter
             'banshee)]
        [else
         (case enemy-race
           [(Zerg)
            (cond
              [(and (memq 'spire feasible-tech) (not (memq 'spire crippled))) 'mutalisk]
              [(and (memq 'lurker-den feasible-tech) (not (memq 'lurker-den crippled))) 'lurker]
              [(memq 'hydralisk-den feasible-tech) 'hydralisk]
              [else 'roach])]
           [(Protoss)
            (cond
              [(and (memq 'stargate feasible-tech) (not (memq 'stargate crippled))) 'void-ray]
              [(and (memq 'robotics-bay feasible-tech) (not (memq 'robotics-bay crippled))) 'colossus]
              [(and (memq 'robotics-facility feasible-tech) (not (memq 'robotics-facility crippled))) 'immortal]
              [else 'stalker])]
           [(Terran)
            (cond
              [(and (memq 'starport feasible-tech) (not (memq 'starport crippled)))
               (if (and tech-obs
                        (enemy-tech-observation-requires-detection? tech-obs)
                        (not (enemy-tech-observation-requires-anti-air? tech-obs)))
                   'banshee
                   'viking-fighter)]
              [(and (memq 'factory feasible-tech) (not (memq 'factory crippled))) 'siege-tank]
              [else 'marauder])]
           [else raw-unit])])))

;; Attribute-accurate LotV enemy-unit identification & counter selection helpers
(define MIRROR-ENEMY-UNIT-THREAT-WEIGHTS
  (hasheq
   'mothership 140 'carrier 130 'battlecruiser 128 'tempest 125
   'colossus 122 'brood-lord 120 'thor 118 'thor-ap 118 'ultralisk 116
   'disruptor 114 'siege-tank-sieged 112 'siege-tank 108 'immortal 106
   'infestor 104 'infestor-burrowed 104 'viper 102 'high-templar 100
   'lurker-burrowed 98 'lurker 98 'ghost 96 'raven 94 'archon 92
   'liberator-ag 90 'liberator 86 'void-ray 84 'dark-templar 82 'oracle 80
   'banshee 78 'queen 76 'mutalisk 74 'corruptor 72 'ravager 70
   'cyclones 68 'cyclone 68 'hydralisk 64 'viking 62 'viking-fighter 62
   'stalker 58 'marauder 56 'roach 54 'phoenix 52 'hellbat 50 'widow-mine 48
   'adept 44 'zealot 42 'baneling 40 'hellion 38 'marine 34 'reaper 30
   'zergling 26 'sentry 24 'medivac 22))

(define (dominant-observed-enemy-unit enemy-units)
  (define best-sym #f)
  (define best-score -1.0)
  (for ([u (in-list enemy-units)]
        #:when (hash? u))
    (define ut (unit-type-sym u))
    (unless (or (enemy-unit-hallucination? u)
                (memq ut '(larva egg cocoon baneling-cocoon ravager-cocoon
                           overlord overlord-transport observer overseer
                           parasitic-bomb-dummy kd8-charge scv probe drone mule)))
      (define w (exact->inexact (hash-ref MIRROR-ENEMY-UNIT-THREAT-WEIGHTS ut 20)))
      (define count-sc (+ w (* 0.08 (exact->inexact (safe-int (hash-ref u 'hp 60) 60)))))
      (when (> count-sc best-score)
        (set! best-score count-sc)
        (set! best-sym ut))))
  best-sym)

(define (lotv-tech-prereq-ok? req available-tech)
  (cond
    [(not req) #t]
    [(memq req available-tech) #t]
    [(eq? req 'lurker-den) (memq 'lurker-den-mp available-tech)]
    [(eq? req 'templar-archive) (memq 'templar-archives available-tech)]
    [(eq? req 'robotics-bay) (memq 'robotics-support-bay available-tech)]
    [(memq req '(barracks-techlab factory-techlab starport-techlab))
     (define parent
       (case req
         [(barracks-techlab) 'barracks]
         [(factory-techlab) 'factory]
         [else 'starport]))
     (and (memq parent available-tech) (memq 'techlab available-tech))]
    [else #f]))

(define (lotv-counter-min-cost unit-sym)
  (let ([m (sc2-min-cost unit-sym 0)])
    (if (> m 0) m (sc2-unit-total-min-cost unit-sym 0))))

(define (lotv-counter-gas-cost unit-sym)
  (let ([g (sc2-gas-cost unit-sym 0)])
    (if (> g 0) g (sc2-unit-total-gas-cost unit-sym 0))))

(define (lotv-pick-first-feasible candidates available-tech minerals gas)
  (for/or ([c (in-list candidates)])
    (define unit-sym (car c))
    (define req (cadr c))
    (define min-m (if (pair? (cddr c)) (caddr c) (lotv-counter-min-cost unit-sym)))
    (define min-g (if (and (pair? (cddr c)) (pair? (cdddr c))) (cadddr c) (lotv-counter-gas-cost unit-sym)))
    (and (lotv-tech-prereq-ok? req available-tech)
         (>= minerals (min 250 min-m))
         (>= gas (min 150 min-g))
         unit-sym)))

;; Explicit LotV attribute-accurate counter preference lists:
;;   ((candidate-unit required-tech) ...) — costs resolved dynamically via `sc2-game-constants.rkt`
(define LOTV-UNIT-COUNTERS-TABLE
  (hasheq
   'immortal
   (hasheq
    'Zerg    '((hydralisk hydralisk-den) (lurker lurker-den) (ravager roach-warren) (zergling spawning-pool))
    'Terran  '((marauder barracks-techlab) (liberator starport) (marine barracks))
    'Protoss '((zealot gateway) (immortal robotics-facility)))
   'queen
   (hasheq
    'Terran  '((ghost ghost-academy) (marauder barracks-techlab) (marine barracks))
    'Zerg    '((ultralisk ultralisk-cavern) (hydralisk hydralisk-den) (ravager roach-warren))
    'Protoss '((high-templar templar-archive) (archon templar-archive) (stalker cybernetics-core)))
   'infestor
   (hasheq
    'Terran  '((ghost ghost-academy) (marauder barracks-techlab) (marine barracks))
    'Zerg    '((ultralisk ultralisk-cavern) (lurker lurker-den) (ravager roach-warren))
    'Protoss '((high-templar templar-archive) (archon templar-archive) (immortal robotics-facility)))
   'siege-tank
   (hasheq
    'Terran  '((raven starport-techlab) (liberator starport) (viking starport) (marauder barracks-techlab))
    'Zerg    '((viper hive) (ravager roach-warren) (mutalisk spire))
    'Protoss '((immortal robotics-facility) (disruptor robotics-bay) (phoenix stargate) (zealot gateway)))
   'tempest
   (hasheq
    'Terran  '((viking-fighter starport) (thor armory) (marine barracks))
    'Zerg    '((corruptor spire) (hydralisk hydralisk-den) (queen spawning-pool))
    'Protoss '((void-ray stargate) (tempest fleet-beacon) (stalker cybernetics-core)))
   'battlecruiser
   (hasheq
    'Terran  '((viking-fighter starport) (thor armory) (marine barracks))
    'Zerg    '((corruptor spire) (hydralisk hydralisk-den) (queen spawning-pool))
    'Protoss '((void-ray stargate) (tempest fleet-beacon) (stalker cybernetics-core)))
   'carrier
   (hasheq
    'Terran  '((viking-fighter starport) (thor armory) (marine barracks))
    'Zerg    '((corruptor spire) (hydralisk hydralisk-den))
    'Protoss '((void-ray stargate) (tempest fleet-beacon) (stalker cybernetics-core)))
   'brood-lord
   (hasheq
    'Terran  '((viking-fighter starport) (thor armory) (marine barracks))
    'Zerg    '((corruptor spire) (hydralisk hydralisk-den))
    'Protoss '((void-ray stargate) (tempest fleet-beacon) (stalker cybernetics-core)))
   'mothership
   (hasheq
    'Terran  '((viking-fighter starport) (thor armory) (marine barracks))
    'Zerg    '((corruptor spire) (hydralisk hydralisk-den))
    'Protoss '((void-ray stargate) (tempest fleet-beacon) (stalker cybernetics-core)))
   'roach
   (hasheq
    'Protoss '((immortal robotics-facility) (stalker cybernetics-core))
    'Terran  '((marauder barracks-techlab) (siege-tank factory-techlab) (marine barracks))
    'Zerg    '((lurker lurker-den) (ravager roach-warren) (roach roach-warren)))
   'zealot
   (hasheq
    'Zerg    '((baneling baneling-nest) (roach roach-warren))
    'Terran  '((hellbat armory) (hellion factory) (marine barracks))
    'Protoss '((archon templar-archive) (colossus robotics-bay) (adept cybernetics-core)))
   'zergling
   (hasheq
    'Zerg    '((baneling baneling-nest) (roach roach-warren))
    'Terran  '((hellbat armory) (hellion factory) (marine barracks))
    'Protoss '((colossus robotics-bay) (archon templar-archive) (zealot gateway)))
   'adept
   (hasheq
    'Zerg    '((baneling baneling-nest) (roach roach-warren))
    'Terran  '((hellbat armory) (marauder barracks-techlab) (marine barracks))
    'Protoss '((archon templar-archive) (stalker cybernetics-core)))
   'colossus
   (hasheq
    'Terran  '((viking starport) (marauder barracks-techlab))
    'Zerg    '((corruptor spire) (viper hive) (lurker lurker-den))
    'Protoss '((immortal robotics-facility) (tempest fleet-beacon) (stalker cybernetics-core)))
   'mutalisk
   (hasheq
    'Terran  '((thor armory) (viking starport) (marine barracks))
    'Zerg    '((hydralisk hydralisk-den) (corruptor spire) (queen spawning-pool))
    'Protoss '((phoenix stargate) (archon templar-archive) (stalker cybernetics-core)))))

(define (normalize-counter-enemy-key sym)
  (case sym
    [(siege-tank-sieged) 'siege-tank]
    [(infestor-burrowed) 'infestor]
    [(queen-burrowed) 'queen]
    [(roach-burrowed) 'roach]
    [(zergling-burrowed) 'zergling]
    [(thor-ap) 'thor]
    [(lurker-burrowed lurker-mp lurker-mp-burrowed) 'lurker]
    [(viking-fighter viking-assault) 'viking]
    [(liberator-ag) 'liberator]
    [else sym]))

(define (attribute-counter-unit-for-enemy race enemy-unit available-tech minerals gas)
  (define eff-tech
    (if (or (not (list? available-tech)) (null? available-tech))
        ALL-RATIONAL-TECH
        available-tech))
  (define ekey (and (symbol? enemy-unit) (normalize-counter-enemy-key enemy-unit)))
  (define race-ht (and ekey (hash-ref LOTV-UNIT-COUNTERS-TABLE ekey #f)))
  (define explicit-pick
    (and race-ht
         (let ([cands (hash-ref race-ht race #f)])
           (and cands (lotv-pick-first-feasible cands eff-tech minerals gas)))))
  (or explicit-pick
      (and ekey
           (let* ([mask (unit-attribute-mask ekey)]
                  [massive? (fx> (fxand mask SC2-UNIT-ATTR-MASSIVE) 0)]
                  [armored? (fx> (fxand mask SC2-UNIT-ATTR-ARMORED) 0)]
                  [light? (fx> (fxand mask SC2-UNIT-ATTR-LIGHT) 0)]
                  [bio? (fx> (fxand mask SC2-UNIT-ATTR-BIOLOGICAL) 0)]
                  [fallback-cands
                   (cond
                     [massive?
                      (case race
                        [(Terran)  '((viking starport) (thor armory) (marauder barracks-techlab))]
                        [(Zerg)    '((corruptor spire) (hydralisk hydralisk-den))]
                        [(Protoss) '((tempest fleet-beacon) (immortal robotics-facility) (stalker cybernetics-core))]
                        [else      #f])]
                     [armored?
                      (case race
                        [(Terran)  '((marauder barracks-techlab) (siege-tank factory-techlab))]
                        [(Zerg)    '((hydralisk hydralisk-den) (lurker lurker-den) (ravager roach-warren))]
                        [(Protoss) '((immortal robotics-facility) (stalker cybernetics-core))]
                        [else      #f])]
                     [(and light? bio?)
                      (case race
                        [(Terran)  '((hellbat armory) (hellion factory) (siege-tank factory-techlab))]
                        [(Zerg)    '((baneling baneling-nest) (roach roach-warren))]
                        [(Protoss) '((archon templar-archive) (colossus robotics-bay) (adept cybernetics-core))]
                        [else      #f])]
                     [else #f])])
             (and fallback-cands
                  (lotv-pick-first-feasible fallback-cands eff-tech minerals gas))))))

(define (mirror-obs-enemy-air-ratio enemy-units)
  (define total-sup 0.0)
  (define air-sup 0.0)
  (for ([u (in-list (safe-hash-list enemy-units))])
    (define sym (unit-type-sym u))
    (when (and (symbol? sym) (not (mirror-building-or-noncombat-sym? sym)))
      (define cs (mirror-canonical-unit-sym sym))
      (define sup (exact->inexact (if (eq? cs 'zergling) 0.5 (sc2-supply-cost cs 1))))
      (define stats (hash-ref SC2-UNIT-COMBAT-STATS-TABLE cs #f))
      (define fly?
        (or (and (hash? u) (eq? (hash-ref u 'flying? #f) #t))
            (and (hash? stats) (eq? (hash-ref stats 'flying? #f) #t))
            (not (not (memq cs '(void-ray carrier tempest oracle phoenix mothership
                                  viking-fighter banshee battlecruiser liberator raven
                                  mutalisk corruptor brood-lord viper))))))
      (set! total-sup (+ total-sup sup))
      (when fly?
        (set! air-sup (+ air-sup sup)))))
  (if (<= total-sup 0.0)
      0.0
      (min 1.0 (/ air-sup total-sup))))

(define (mirror-obs-worker-count obs raw-units [kind 'self])
  (define explicit
    (if (eq? kind 'self)
        (or (and (number? (hash-ref obs 'worker-count #f)) (hash-ref obs 'worker-count #f))
            (and (number? (hash-ref obs 'workers #f)) (hash-ref obs 'workers #f))
            (and (number? (hash-ref obs 'food-workers #f)) (hash-ref obs 'food-workers #f))
            (and (number? (hash-ref obs 'harvesters #f)) (hash-ref obs 'harvesters #f)))
        (or (and (number? (hash-ref obs 'enemy-worker-count #f)) (hash-ref obs 'enemy-worker-count #f))
            (and (number? (hash-ref obs 'enemy-workers #f)) (hash-ref obs 'enemy-workers #f)))))
  (cond
    [(number? explicit) (max 0 (exact-round explicit))]
    [(and (eq? kind 'self)
          (or (number? (hash-ref obs 'mineral-harvesters #f))
              (number? (hash-ref obs 'vespene-harvesters #f))))
     (+ (max 0 (safe-int (hash-ref obs 'mineral-harvesters 0) 0))
        (max 0 (safe-int (hash-ref obs 'vespene-harvesters 0) 0)))]
    [else
     (define unit-cnt
       (for/sum ([u (in-list (safe-hash-list raw-units))])
         (if (memq (unit-type-sym u) '(drone scv probe)) 1 0)))
     (define counts-ht
       (hash-ref obs (if (eq? kind 'self) 'unit-counts 'enemy-unit-counts) #f))
     (define ht-cnt
       (if (hash? counts-ht)
           (+ (safe-int (hash-ref counts-ht 'drone 0) 0)
              (safe-int (hash-ref counts-ht 'scv 0) 0)
              (safe-int (hash-ref counts-ht 'probe 0) 0))
           0))
     (max unit-cnt ht-cnt)]))

(define (mirror-obs-effective-workers obs raw-units)
  (define has-explicit?
    (or (number? (hash-ref obs 'worker-count #f))
        (number? (hash-ref obs 'workers #f))
        (number? (hash-ref obs 'food-workers #f))
        (number? (hash-ref obs 'harvesters #f))
        (number? (hash-ref obs 'mineral-harvesters #f))
        (number? (hash-ref obs 'vespene-harvesters #f))))
  (define obs-w (mirror-obs-worker-count obs raw-units 'self))
  (if (or has-explicit? (> obs-w 0))
      obs-w
      44))

(define (mirror-obs-natural-ready? obs ally-bldgs)
  (define explicit (hash-ref obs 'natural-ready? 'missing))
  (cond
    [(boolean? explicit) explicit]
    [else
     (define frame (safe-frame (hash-ref obs 'frame 6000)))
     (define th-cnt
       (for/sum ([b (in-list (safe-hash-list ally-bldgs))])
         (define s (unit-type-sym b))
         (define prog (safe-real (if (hash? b) (hash-ref b 'build-progress 1.0) 1.0) 1.0))
         (if (and (memq s '(hatchery lair hive nexus command-center orbital-command planetary-fortress))
                  (>= prog 0.99))
             1
             0)))
     (or (>= th-cnt 2) (and (null? (safe-hash-list ally-bldgs)) (>= frame 4700)))]))

(define (counter-unit-for-race race target-archetype available-tech raw-minerals raw-gas
                               #:enemy-unit [enemy-unit #f]
                               #:frame [frame 6000]
                               #:enemy-air-ratio [enemy-air-ratio 0.0]
                               #:workers [workers 44]
                               #:natural-ready? [natural-ready? #t]
                               #:researched-upgrades [researched-upgrades '()]
                               #:enemy-has-splash? [enemy-has-splash? #f])
  (counter-unit-for-archetype
   race
   target-archetype
   available-tech
   raw-minerals
   raw-gas
   #:frame frame
   #:enemy-air-ratio enemy-air-ratio
   #:workers workers
   #:natural-ready? natural-ready?
   #:researched-upgrades researched-upgrades
   #:enemy-unit enemy-unit
   #:enemy-has-splash? enemy-has-splash?))

;; What does the opponent predict about US at depth 1 (using what they know
;; about us, including transitive implied tech buildings, spells from our units,
;; and our projected position in the race build-order tree T_R)?
(define (infer-opponent-belief-about-us mstate raw-ally-units raw-ally-bldgs)
  (define ally-units (safe-hash-list raw-ally-units))
  (define ally-bldgs (safe-hash-list raw-ally-bldgs))
  (define our-race (mirror-mind-state-our-race mstate))
  (define seen-ut (make-hasheq))
  (define unique-ally-units
    (for/fold ([acc '()]) ([u (in-list ally-units)])
      (define ut (unit-type-sym u))
      (define sp (hash-ref u 'spells '()))
      (define bf (hash-ref u 'buffs '()))
      (if (and (null? sp) (null? bf))
          (if (hash-has-key? seen-ut ut)
              acc
              (begin (hash-set! seen-ut ut #t) (cons u acc)))
          (cons u acc))))
  (define our-tech-obs (infer-enemy-implied-tech-and-upgrades unique-ally-units ally-bldgs))
  (define bldg-syms
    (fast-dedup-syms
     (append (map unit-type-sym ally-bldgs)
             (enemy-tech-observation-implied-tech-buildings our-tech-obs))))
  (define (compute-active-bo-node)
    (define self-bo-proj
      (project-self-build-order-tree
       (hash 'race our-race
             'ally-units ally-units
             'ally-buildings ally-bldgs)
       45.0))
    (findf (lambda (n)
             (eq? (build-order-tree-node-id n)
                  (build-order-tree-projection-active-node-id self-bo-proj)))
           (lookup-race-build-order-tree our-race)))
  (define visible-arch (mirror-classify-enemy-archetype ally-units ally-bldgs our-race))
  (cond
    ;; If we have Spire/Stargate (directly or implied by our units), a smart opponent predicts air/tech
    [(or (memq 'spire bldg-syms) (memq 'stargate bldg-syms) (memq 'starport bldg-syms))
     (case our-race
       [(Zerg)    (if (memq 'spire bldg-syms) 'muta-flock visible-arch)]
       [(Protoss) (if (memq 'stargate bldg-syms) 'sky-toss visible-arch)]
       [(Terran)  (if (or (memq 'starport bldg-syms) (memq 'fusion-core bldg-syms)) 'terran-air visible-arch)]
       [else      visible-arch])]
    [(not (memq visible-arch '(early-rush standard-macro)))
     visible-arch]
    [(memq 'robotics-facility bldg-syms)
     'stalker-colossus]
    [(or (memq 'factory-techlab bldg-syms) (memq 'armory bldg-syms))
     'mech-siege]
    [else
     (define active-bo-node (compute-active-bo-node))
     (cond
       [(and active-bo-node
             (not (memq (build-order-tree-node-archetype active-bo-node)
                        '(early-rush standard-macro))))
        (build-order-tree-node-archetype active-bo-node)]
       ;; Even if our army is small/early, a smart opponent infers our race's
       ;; core midgame doctrine from our race & opening structures
       [else
        (case our-race
          [(Zerg)    (if (memq 'roach-warren bldg-syms) 'roach-ravager 'ling-bane-hydra)]
          [(Protoss) 'stalker-colossus]
          [(Terran)  'bio-ball]
          [else      'roach-ravager])])]))

;; Base tactical target at Depth 1 (based on opponent's capabilities & actions)
(define (tactical-target-at-depth-1 mstate raw-obs)
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define base-x (safe-coord (hash-ref obs 'base-x 32) 32))
  (define base-y (safe-coord (hash-ref obs 'base-y 32) 32))
  (define nat-x (safe-coord (hash-ref obs 'natural-x 50) 50))
  (define nat-y (safe-coord (hash-ref obs 'natural-y 56) 56))
  (define enemy-x (safe-coord (hash-ref obs 'enemy-x 160) 160))
  (define enemy-y (safe-coord (hash-ref obs 'enemy-y 160) 160))
  (define ledger (mirror-mind-state-last-shadow-ledger mstate))
  (define reading (mirror-mind-state-last-action-reading mstate))

  (cond
    [(or (and reading (action-lens-reading-feint-or-poke-detected? reading))
         (and ledger
              (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                   'hidden-air-or-cloak-tech-switch)))
     (values 'main-mineral-line-drop-or-air base-x base-y)]
    [(or (and reading (action-lens-reading-proxy-or-rush-detected? reading))
         (and reading (action-lens-reading-missing-natural-expansion? reading))
         (and ledger
              (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                   'imminent-fog-timing-wave)))
     (values 'natural-choke-timing-push nat-x nat-y)]
    [(and ledger
          (eq? (shadow-ledger-dark-matter-hypothesis ledger)
               'hidden-expansion-or-macro-boom))
     (values 'hidden-third-base-expansion
             (exact-round (* 0.5 (+ nat-x enemy-x)))
             (exact-round (* 0.5 (+ nat-y enemy-y))))]
    [else
     (values 'center-map-staging
             (exact-round (* 0.5 (+ nat-x enemy-x)))
             (exact-round (* 0.5 (+ nat-y enemy-y))))]))

;; Tactical target at Depth k >= 2:
;; Given where the opponent expects US to be at depth (k-1), where will a smart
;; opponent strike to exploit our predicted positioning?
(define (tactical-target-at-higher-depth prev-target raw-obs)
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define base-x (safe-coord (hash-ref obs 'base-x 32) 32))
  (define base-y (safe-coord (hash-ref obs 'base-y 32) 32))
  (define nat-x (safe-coord (hash-ref obs 'natural-x 50) 50))
  (define nat-y (safe-coord (hash-ref obs 'natural-y 56) 56))
  (define enemy-x (safe-coord (hash-ref obs 'enemy-x 160) 160))
  (define enemy-y (safe-coord (hash-ref obs 'enemy-y 160) 160))
  (case prev-target
    [(natural-choke-timing-push)
     (values 'main-mineral-line-drop-or-air base-x base-y)]
    [(main-mineral-line-drop-or-air)
     (values 'natural-choke-timing-push nat-x nat-y)]
    [(center-map-staging)
     (values 'natural-choke-timing-push nat-x nat-y)]
    [else
     (values 'center-map-staging
             (exact-round (* 0.5 (+ nat-x enemy-x)))
             (exact-round (* 0.5 (+ nat-y enemy-y))))]))

;; Generic recursive predictor for any depth d >= 0
;; Propagates base-layer `enemy-tech-observation` (including crippled buildings
;; and observed spells/upgrades), `zero-sum-exclusion-reading` (including
;; Bayesian bluff posterior), and build-order tree projection T_R through
;; Depth 1, Depth 2, and all higher depths d >= 3.
(define (predict-at-depth mstate raw-depth raw-obs
                          #:our-tech [our-tech ALL-RATIONAL-TECH]
                          #:our-minerals [raw-our-minerals 300]
                          #:our-gas [raw-our-gas 150]
                          #:prev-node [given-prev-node #f]
                          #:preprepared-opp-ctx [pre-opp-ctx #f]
                          #:ally-units [pre-ally-units #f]
                          #:ally-bldgs [pre-ally-bldgs #f]
                          #:enemy-units [pre-enemy-units #f]
                          #:enemy-bldgs [pre-enemy-bldgs #f]
                          #:enemy-budget [pre-enemy-budget #f])
  (define depth (max 0 (safe-int raw-depth 0)))
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define our-minerals (max 0 (safe-int raw-our-minerals 300)))
  (define our-gas (max 0 (safe-int raw-our-gas 150)))
  (define our-race (mirror-mind-state-our-race mstate))
  (define enemy-race (mirror-mind-state-enemy-race mstate))
  (define ally-units (or pre-ally-units (safe-hash-list (hash-ref obs 'ally-units '()))))
  (define ally-bldgs (or pre-ally-bldgs (safe-hash-list (hash-ref obs 'ally-buildings '()))))
  (define enemy-units (or pre-enemy-units (safe-hash-list (hash-ref obs 'enemy-units '()))))
  (define enemy-bldgs (or pre-enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '()))))
  (define previewed-unit
    (for/or ([b (in-list enemy-bldgs)]
             #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
      (define p (hash-ref b 'preview-unit (hash-ref b 'unit-preview #f)))
      (and (symbol? p) (not (eq? p 'null)) p)))
  (define enemy-x (safe-coord (hash-ref obs 'enemy-x 160) 160))
  (define enemy-y (safe-coord (hash-ref obs 'enemy-y 160) 160))
  (define ledger (mirror-mind-state-last-shadow-ledger mstate))
  (define reading (mirror-mind-state-last-action-reading mstate))
  (define tech-obs (mirror-mind-state-last-tech-observation mstate))
  (define zs-reading (mirror-mind-state-last-zero-sum-reading mstate))
  (define-values (enemy-feasible-tech enemy-rem-min enemy-rem-gas crippled-tech _excl bluff?)
    (if pre-enemy-budget
        (apply values pre-enemy-budget)
        (compute-enemy-feasible-tech-and-budget mstate)))

  ;; Project opponent onto Build-Order Tree T_R lazily (only evaluated when needed:
  ;; depth >= 2, or depth <= 1 with 0 enemy units and >= 1 enemy buildings).
  (define bo-horizon-sec
    (cond
      [(<= depth 0) 15.0]
      [(= depth 1)  30.0]
      [(= depth 2)  60.0]
      [else         105.0]))
  (define opp-bo-proj-cache #f)
  (define (get-opp-bo-proj)
    (unless opp-bo-proj-cache
      (set! opp-bo-proj-cache
            (if pre-opp-ctx
                (evaluate-bo-tree-frame-context pre-opp-ctx bo-horizon-sec)
                (project-opponent-build-order-tree
                 (hash-set (hash-set obs 'enemy-race enemy-race)
                           'unaccounted-gas enemy-rem-gas)
                 bo-horizon-sec))))
    opp-bo-proj-cache)
  (define (get-bo-tree-tech)
    (let ([reach-bldgs (build-order-tree-projection-horizon-reachable-tech-buildings (get-opp-bo-proj))])
      (define filtered
        (filter (lambda (b)
                  (and (memq b enemy-feasible-tech)
                       (not (memq b crippled-tech))))
                reach-bldgs))
      (if (null? filtered) enemy-feasible-tech filtered)))

  (cond
    ;; -------------------------------------------------------------------------
    ;; DEPTH 0: Pure Observational Baseline (No theory of mind)
    ;; -------------------------------------------------------------------------
    [(<= depth 0)
     (define obs-enemy-arch (mirror-classify-enemy-archetype enemy-units enemy-bldgs enemy-race))
     (define obs-enemy-unit
       (or previewed-unit
           (dominant-observed-enemy-unit enemy-units)
           (if (and (null? enemy-units) (not (null? enemy-bldgs)))
               (build-order-tree-projection-predicted-primary-unit (get-opp-bo-proj))
               (archetype-signature-unit enemy-race obs-enemy-arch))))
     (define our-d0-unit
       (counter-unit-for-race our-race (unit-to-archetype obs-enemy-unit)
                              our-tech our-minerals our-gas
                              #:enemy-unit obs-enemy-unit))
     (depth-node 0
                 'none
                 obs-enemy-unit
                 our-d0-unit
                 'direct-visible-observation
                 'visible-enemy-front
                 enemy-x
                 enemy-y)]

    ;; -------------------------------------------------------------------------
    ;; DEPTH 1: First-Order Opponent Prediction
    ;; ("Use what we know about the opponent to predict what they will do")
    ;; -------------------------------------------------------------------------
    [(= depth 1)
     (define obs-enemy-arch (mirror-classify-enemy-archetype enemy-units enemy-bldgs enemy-race))
     (define dom-obs-unit (dominant-observed-enemy-unit enemy-units))
     (define implied-bldgs
       (if tech-obs (enemy-tech-observation-implied-tech-buildings tech-obs) '()))
     (define committed-branch
       (if zs-reading (zero-sum-exclusion-reading-committed-primary-branch zs-reading) 'uncommitted))
     (define raw-d1-enemy-unit
       (cond
         [previewed-unit previewed-unit]
         ;; If opponent is suspected of bluffing an idle tech structure at Depth 1,
         ;; Depth 1 sees the surface branch they presented
         [bluff?
          (case committed-branch
            [(twilight-templar-ground) 'high-templar]
            [(stargate-sky-fleet stargate-fleet)
             (cond
               [(memq dom-obs-unit '(tempest carrier void-ray mothership phoenix oracle)) dom-obs-unit]
               [(or (memq 'fleet-beacon implied-bldgs)
                    (for/or ([b (in-list enemy-bldgs)]) (eq? (unit-type-sym b) 'fleet-beacon)))
                'carrier]
               [else 'void-ray])]
            [(robotics-heavy-siege)    'colossus]
            [(armored-siege)
             (cond
               [(memq dom-obs-unit '(siege-tank siege-tank-sieged thor colossus immortal disruptor lurker ultralisk))
                (if (eq? dom-obs-unit 'siege-tank-sieged) 'siege-tank dom-obs-unit)]
               [(eq? enemy-race 'Terran) 'siege-tank]
               [(eq? enemy-race 'Protoss) 'colossus]
               [else 'lurker])]
            [(roach-ravager-ground)    'roach]
            [(infestor-queen-spell)    'infestor]
            [(ling-bane-flood)         'baneling]
            [(spire-air-muta)          'mutalisk]
            [(greater-spire)
             (cond
               [(memq dom-obs-unit '(brood-lord corruptor mutalisk)) dom-obs-unit]
               [(or (memq 'greater-spire implied-bldgs)
                    (for/or ([b (in-list enemy-bldgs)]) (eq? (unit-type-sym b) 'greater-spire)))
                'brood-lord]
               [else 'mutalisk])]
            [(hydra-lurker-den)        'lurker]
            [(bio-stim-medivac)        'marauder]
            [(factory-mech-siege)      'siege-tank]
            [(starport-cloak-or-bc air-starport-bc)
             (cond
               [(memq dom-obs-unit '(battlecruiser raven liberator viking viking-fighter banshee)) dom-obs-unit]
               [(or (eq? committed-branch 'air-starport-bc)
                    (memq 'fusion-core implied-bldgs)
                    (for/or ([b (in-list enemy-bldgs)]) (eq? (unit-type-sym b) 'fusion-core)))
                'battlecruiser]
               [(and tech-obs (enemy-tech-observation-requires-detection? tech-obs))
                'banshee]
               [else 'viking-fighter])]
            [else                      (archetype-signature-unit enemy-race obs-enemy-arch)])]
         ;; L36-P0-2 (`#834`): Never let zero-sum `committed-branch` or `closed-by-opportunity-cost`
         ;; override a visibly observed combat `dom-obs-unit` in Depth 1! Keep dark-matter hidden
         ;; air/cloak switch only when no real combat force is visible (or a 1-2 unit poke/feint).
         [(and ledger
               (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                    'hidden-air-or-cloak-tech-switch)
               (or (not dom-obs-unit)
                   (and reading (action-lens-reading-feint-or-poke-detected? reading))
                   (<= (length enemy-units) 2)))
          (race-hidden-gas-threat enemy-race)]
         [dom-obs-unit dom-obs-unit]
         [(and zs-reading
               (memq 'closed-by-opportunity-cost
                     (zero-sum-exclusion-reading-excluded-tech-branches zs-reading)))
          (or (hash-ref (zero-sum-exclusion-reading-opportunity-cost-profile zs-reading)
                        'recommended-enemy-unit #f)
              (archetype-signature-unit enemy-race obs-enemy-arch))]
         [(not (eq? committed-branch 'uncommitted))
          (case committed-branch
            [(twilight-templar-ground)
             (if (memq dom-obs-unit '(high-templar archon dark-templar adept zealot stalker))
                 dom-obs-unit
                 'stalker)]
            [(stargate-sky-fleet stargate-fleet)
             (cond
               [(memq dom-obs-unit '(tempest carrier void-ray mothership phoenix oracle)) dom-obs-unit]
               [(or (memq 'fleet-beacon implied-bldgs)
                    (for/or ([b (in-list enemy-bldgs)]) (eq? (unit-type-sym b) 'fleet-beacon)))
                'carrier]
               [else 'void-ray])]
            [(robotics-heavy-siege)
             (if (memq dom-obs-unit '(colossus disruptor immortal))
                 dom-obs-unit
                 'immortal)]
            [(armored-siege)
             (cond
               [(memq dom-obs-unit '(siege-tank siege-tank-sieged thor colossus immortal disruptor lurker ultralisk))
                (if (eq? dom-obs-unit 'siege-tank-sieged) 'siege-tank dom-obs-unit)]
               [(eq? enemy-race 'Terran) 'siege-tank]
               [(eq? enemy-race 'Protoss) 'colossus]
               [else 'lurker])]
            [(roach-ravager-ground)
             (if (memq dom-obs-unit '(ravager roach)) dom-obs-unit 'roach)]
            [(infestor-queen-spell)
             (if (eq? dom-obs-unit 'queen) 'queen 'infestor)]
            [(ling-bane-flood)         'baneling]
            [(spire-air-muta)
             (if (memq dom-obs-unit '(brood-lord corruptor mutalisk)) dom-obs-unit 'mutalisk)]
            [(greater-spire)
             (cond
               [(memq dom-obs-unit '(brood-lord corruptor mutalisk)) dom-obs-unit]
               [(or (memq 'greater-spire implied-bldgs)
                    (for/or ([b (in-list enemy-bldgs)]) (eq? (unit-type-sym b) 'greater-spire)))
                'brood-lord]
               [else 'mutalisk])]
            [(hydra-lurker-den)
             (if (memq dom-obs-unit '(lurker lurker-burrowed hydralisk)) dom-obs-unit 'hydralisk)]
            [(bio-stim-medivac)
             (if (memq dom-obs-unit '(marauder ghost marine medivac)) dom-obs-unit 'marauder)]
            [(factory-mech-siege)
             (if (memq dom-obs-unit '(siege-tank siege-tank-sieged thor cyclone hellbat))
                 (if (eq? dom-obs-unit 'siege-tank-sieged) 'siege-tank dom-obs-unit)
                 'siege-tank)]
            [(starport-cloak-or-bc air-starport-bc)
             (cond
               [(memq dom-obs-unit '(battlecruiser raven liberator viking viking-fighter banshee)) dom-obs-unit]
               [(or (eq? committed-branch 'air-starport-bc)
                    (memq 'fusion-core implied-bldgs)
                    (for/or ([b (in-list enemy-bldgs)]) (eq? (unit-type-sym b) 'fusion-core)))
                'battlecruiser]
               [(and tech-obs (enemy-tech-observation-requires-detection? tech-obs))
                'banshee]
               [else 'viking-fighter])]
            [else                      (archetype-signature-unit enemy-race obs-enemy-arch)])]
         [dom-obs-unit dom-obs-unit]
         [(or (memq 'spire implied-bldgs) (memq 'greater-spire implied-bldgs)) 'mutalisk]
         [(or (memq 'hydralisk-den implied-bldgs) (memq 'lurker-den implied-bldgs)) 'hydralisk]
         [(memq 'infestation-pit implied-bldgs) 'infestor]
         [(memq 'baneling-nest implied-bldgs) 'baneling]
         [(memq 'roach-warren implied-bldgs) 'roach]
         [(memq 'stargate implied-bldgs) 'void-ray]
         [(or (memq 'robotics-facility implied-bldgs) (memq 'twilight-council implied-bldgs)) 'stalker]
         [(memq 'starport-techlab implied-bldgs)
          (if (and tech-obs (enemy-tech-observation-requires-detection? tech-obs))
              'banshee
              'viking-fighter)]
         [(or (memq 'factory-techlab implied-bldgs) (memq 'armory implied-bldgs)) 'siege-tank]
         [(memq 'barracks implied-bldgs) 'marauder]
         [(and reading (action-lens-reading-opponent-turtling? reading))
          (case enemy-race
            [(Terran)  'siege-tank]
            [(Protoss) 'colossus]
            [(Zerg)    'lurker]
            [else      'siege-tank])]
         [(not (null? enemy-bldgs))
          (build-order-tree-projection-predicted-primary-unit (get-opp-bo-proj))]
         [else
          (archetype-signature-unit enemy-race obs-enemy-arch)]))
     (define d1-enemy-unit
       (if (or bluff?
               (and dom-obs-unit (eq? raw-d1-enemy-unit dom-obs-unit)))
           raw-d1-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-d1-enemy-unit enemy-feasible-tech zs-reading tech-obs)))
     (define d1-enemy-arch (unit-to-archetype d1-enemy-unit))
     (define our-d1-unit
       (counter-unit-for-race our-race d1-enemy-arch our-tech our-minerals our-gas
                              #:enemy-unit d1-enemy-unit
                              #:frame (safe-frame (hash-ref obs 'frame 6000))
                              #:enemy-air-ratio (mirror-obs-enemy-air-ratio enemy-units)
                              #:workers (mirror-obs-effective-workers obs ally-units)
                              #:natural-ready? (mirror-obs-natural-ready? obs ally-bldgs)
                              #:researched-upgrades (safe-list (hash-ref obs 'researched-upgrades '()))))
     (define-values (tact-sym tx ty) (tactical-target-at-depth-1 mstate obs))
     (depth-node 1
                 'unmodeled-at-d1
                 d1-enemy-unit
                 our-d1-unit
                 (if reading (action-lens-reading-inferred-intent reading) 'standard-rational-macro)
                 tact-sym
                 tx
                 ty)]

    ;; -------------------------------------------------------------------------
    ;; DEPTH 2: Second-Order Mirror Prediction (Default)
    ;; ("Use what we know about the opponent AND ourselves to predict their
    ;;   predictions about us, and how they will counter us — constrained by
    ;;   their 1-hop reachable build-order tree T_R, crippled buildings, and
    ;;   zero-sum exclusions, OR unmasking a suspected Bayesian tech bluff!")
    ;; -------------------------------------------------------------------------
    [(= depth 2)
     (define bo-tree-tech (get-bo-tree-tech))
     (define opp-belief-arch
       (infer-opponent-belief-about-us mstate ally-units ally-bldgs))
     (define raw-d2-enemy-unit
       (cond
         ;; If base layer flagged a Bayesian tech bluff (posterior >= 0.55),
         ;; Depth 2 unmasks the bluff and predicts the hidden gas switch!
         [bluff?
          (race-hidden-gas-threat enemy-race)]
         [(and ledger
               (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                    'hidden-air-or-cloak-tech-switch)
               (or (not zs-reading)
                   (eq? (zero-sum-exclusion-reading-committed-primary-branch zs-reading)
                        'uncommitted)))
          (race-hidden-gas-threat enemy-race)]
         [else
          (counter-unit-for-race enemy-race
                                 opp-belief-arch
                                 bo-tree-tech
                                 enemy-rem-min
                                 enemy-rem-gas
                                 #:frame (safe-frame (hash-ref obs 'frame 6000))
                                 #:enemy-air-ratio (mirror-obs-enemy-air-ratio ally-units))]))
     (define d2-enemy-unit
       (if bluff?
           raw-d2-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-d2-enemy-unit bo-tree-tech zs-reading tech-obs)))
     (define d2-enemy-arch (unit-to-archetype d2-enemy-unit))
     (define our-d2-unit
       (counter-unit-for-race our-race d2-enemy-arch our-tech our-minerals our-gas
                              #:enemy-unit d2-enemy-unit
                              #:frame (safe-frame (hash-ref obs 'frame 6000))
                              #:enemy-air-ratio (mirror-obs-enemy-air-ratio enemy-units)
                              #:workers (mirror-obs-effective-workers obs ally-units)
                              #:natural-ready? (mirror-obs-natural-ready? obs ally-bldgs)
                              #:researched-upgrades (safe-list (hash-ref obs 'researched-upgrades '()))))
     (define-values (tact-sym tx ty)
       (if (or bluff? (and reading (action-lens-reading-feint-or-poke-detected? reading)))
           (values 'main-mineral-line-drop-or-air
                   (safe-coord (hash-ref obs 'base-x 32) 32)
                   (safe-coord (hash-ref obs 'base-y 32) 32))
           (tactical-target-at-depth-1 mstate obs)))
     (depth-node 2
                 opp-belief-arch
                 d2-enemy-unit
                 our-d2-unit
                 (if bluff?
                     'unmasked-tech-bluff-hidden-gas-switch
                     (if reading (action-lens-reading-inferred-intent reading) 'standard-rational-macro))
                 tact-sym
                 tx
                 ty)]

    ;; -------------------------------------------------------------------------
    ;; DEPTH k >= 3: Arbitrary Higher-Order Recursive Mirror Prediction
    ;; ("Predict their reaction to our (k-1)-th response, constrained by their
    ;;   2-hop reachable build-order tree T_R, crippled buildings, and zero-sum exclusions")
    ;; -------------------------------------------------------------------------
    [else
     (define bo-tree-tech (get-bo-tree-tech))
     (define prev-node
       (or given-prev-node
           (predict-at-depth mstate (sub1 depth) obs
                             #:our-tech our-tech
                             #:our-minerals our-minerals
                             #:our-gas our-gas
                             #:preprepared-opp-ctx pre-opp-ctx)))
     (define opp-belief-arch
       (unit-to-archetype (depth-node-our-response-unit prev-node)))
     (define raw-dk-enemy-unit
       (counter-unit-for-race enemy-race
                              opp-belief-arch
                              bo-tree-tech
                              enemy-rem-min
                              enemy-rem-gas
                              #:frame (safe-frame (hash-ref obs 'frame 6000))
                              #:enemy-air-ratio (mirror-obs-enemy-air-ratio ally-units)))
     (define dk-enemy-unit
       (if bluff?
           raw-dk-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-dk-enemy-unit bo-tree-tech zs-reading tech-obs)))
     (define dk-enemy-arch (unit-to-archetype dk-enemy-unit))
     (define our-dk-unit
       (counter-unit-for-race our-race dk-enemy-arch our-tech our-minerals our-gas
                              #:enemy-unit dk-enemy-unit
                              #:frame (safe-frame (hash-ref obs 'frame 6000))
                              #:enemy-air-ratio (mirror-obs-enemy-air-ratio enemy-units)
                              #:workers (mirror-obs-effective-workers obs ally-units)
                              #:natural-ready? (mirror-obs-natural-ready? obs ally-bldgs)
                              #:researched-upgrades (safe-list (hash-ref obs 'researched-upgrades '()))))
     (define-values (tact-sym tx ty)
       (tactical-target-at-higher-depth (depth-node-tactical-target prev-node) obs))
     (depth-node depth
                 opp-belief-arch
                 dk-enemy-unit
                 our-dk-unit
                 (depth-node-strategic-hypothesis prev-node)
                 tact-sym
                 tx
                 ty)]))

;; Build the full hierarchy of depth nodes from 0 up to max-depth (or exact max-depth when requested)
(define (build-mirror-hierarchy mstate raw-obs
                                #:max-depth [max-depth #f]
                                #:exact-max-depth? [exact-max-depth? #f]
                                #:skip-opp-ctx? [skip-opp-ctx? #f]
                                #:our-tech [our-tech ALL-RATIONAL-TECH]
                                #:our-minerals [raw-our-minerals 300]
                                #:our-gas [raw-our-gas 150]
                                #:sync-observations? [sync-obs? #t]
                                #:preprepared-opp-ctx [pre-opp-ctx #f]
                                #:ally-units [pre-ally-units #f]
                                #:ally-bldgs [pre-ally-bldgs #f]
                                #:enemy-units [pre-enemy-units #f]
                                #:enemy-bldgs [pre-enemy-bldgs #f])
  (if (current-halluc-memo)
      (build-mirror-hierarchy-core mstate raw-obs
                                   max-depth exact-max-depth? skip-opp-ctx?
                                   our-tech raw-our-minerals raw-our-gas
                                   sync-obs? pre-opp-ctx
                                   pre-ally-units pre-ally-bldgs
                                   pre-enemy-units pre-enemy-bldgs)
      (parameterize ([current-halluc-memo (make-hasheq)])
        (build-mirror-hierarchy-core mstate raw-obs
                                     max-depth exact-max-depth? skip-opp-ctx?
                                     our-tech raw-our-minerals raw-our-gas
                                     sync-obs? pre-opp-ctx
                                     pre-ally-units pre-ally-bldgs
                                     pre-enemy-units pre-enemy-bldgs))))

(define (build-mirror-hierarchy-core mstate raw-obs
                                     max-depth exact-max-depth? skip-opp-ctx?
                                     our-tech raw-our-minerals raw-our-gas
                                     sync-obs? pre-opp-ctx
                                     pre-ally-units pre-ally-bldgs
                                     pre-enemy-units pre-enemy-bldgs)
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define our-minerals (max 0 (safe-int raw-our-minerals 300)))
  (define our-gas (max 0 (safe-int raw-our-gas 150)))
  (define au (or pre-ally-units (safe-hash-list (hash-ref obs 'ally-units '()))))
  (define ab (or pre-ally-bldgs (safe-hash-list (hash-ref obs 'ally-buildings '()))))
  (define eu (or pre-enemy-units (safe-hash-list (hash-ref obs 'enemy-units '()))))
  (define eb (or pre-enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '()))))
  ;; Ensure base-layer observations/implications & zero-sum exclusions are synchronized with `obs`
  (when (and sync-obs?
             (or (hash-has-key? obs 'enemy-units)
                 (hash-has-key? obs 'enemy-buildings)
                 (hash-has-key? obs 'effects)))
    (define frame (safe-frame (hash-ref obs 'frame 0)))
    (define effs (safe-list (hash-ref obs 'effects '())))
    (define our-upg-tier (max 0 (safe-int (hash-ref obs 'our-upgrade-tier 0) 0)))
    (define prev-tech (mirror-mind-state-last-tech-observation mstate))
    (define tech-obs
      (infer-enemy-implied-tech-and-upgrades
       eu
       eb
       #:our-upgrade-tier our-upg-tier
       #:observed-effects effs
       #:destroyed-enemy-bldgs (mirror-mind-state-destroyed-enemy-bldgs mstate)
       #:pre-destruction-unit-ids (mirror-mind-state-pre-destruction-unit-ids mstate)
       #:historical-upgrades (if prev-tech
                                 (enemy-tech-observation-observed-upgrades prev-tech)
                                 '())
       #:historical-implied-buildings
       (if (and prev-tech (null? eu) (null? eb))
           (enemy-tech-observation-implied-tech-buildings prev-tech)
           '())))
    (set-mirror-mind-state-last-tech-observation! mstate tech-obs)
    (define zs-reading
      (evaluate-zero-sum-negative-exclusions
       frame eu eb tech-obs (mirror-mind-state-last-shadow-ledger mstate)))
    (set-mirror-mind-state-last-zero-sum-reading! mstate zs-reading))

  (define shared-budget
    (let-values ([(v1 v2 v3 v4 v5 v6) (compute-enemy-feasible-tech-and-budget mstate)])
      (list v1 v2 v3 v4 v5 v6)))
  (define top-d
    (cond
      [(and exact-max-depth? max-depth (finite-real? max-depth))
       (max 0 (safe-int max-depth 1))]
      [(and max-depth (finite-real? max-depth))
       (max (safe-int max-depth 5) (add1 (mirror-mind-state-inferred-opponent-depth mstate)))]
      [else
       (max 5
            (mirror-mind-state-default-depth mstate)
            (add1 (mirror-mind-state-inferred-opponent-depth mstate)))]))
  (define shared-opp-ctx
    (cond
      [pre-opp-ctx pre-opp-ctx]
      [(or skip-opp-ctx?
           (and exact-max-depth? (<= top-d 1) (or (not (null? eu)) (null? eb))))
       #f]
      [else
       (prepare-opponent-bo-tree-context
        (hash-set (hash-set obs 'enemy-race (mirror-mind-state-enemy-race mstate))
                  'unaccounted-gas (caddr shared-budget))
        #:mstate mstate)]))
  (define nodes
    (let loop ([d 0]
               [prev #f]
               [acc '()])
      (if (> d top-d)
          (reverse acc)
          (let ([node (predict-at-depth mstate d obs
                                        #:our-tech our-tech
                                        #:our-minerals our-minerals
                                        #:our-gas our-gas
                                        #:prev-node prev
                                        #:preprepared-opp-ctx shared-opp-ctx
                                        #:ally-units au
                                        #:ally-bldgs ab
                                        #:enemy-units eu
                                        #:enemy-bldgs eb
                                        #:enemy-budget shared-budget)])
            (loop (add1 d) node (cons node acc))))))
  (set-mirror-mind-state-last-hierarchy! mstate nodes)
  nodes)

;; =============================================================================
;; 5b. Active Diagnostic Depth-Probing & Snowball-Bounded Toolbox
;;     (Foosball Tournament & SC2 Snowball Principles)
;; =============================================================================

;; Issue a low-cost diagnostic probe over the course of a match to test how the
;; opponent reacts and infer their true cognitive depth d*.
(define (issue-diagnostic-depth-probe! mstate raw-frame raw-enemy-units
                                       #:probe-type [probe-type 'feint-tempo-probe]
                                       #:probe-x [raw-probe-x 74]
                                       #:probe-y [raw-probe-y 74])
  (define frame (safe-frame raw-frame))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define probe-x (safe-coord raw-probe-x 74))
  (define probe-y (safe-coord raw-probe-y 74))
  (define base-arch (mirror-classify-enemy-archetype enemy-units '() (mirror-mind-state-enemy-race mstate)))
  (define avg-ex
    (if (null? enemy-units)
        160
        (quotient (for/sum ([e (in-list enemy-units)]) (safe-coord (hash-ref e 'x 160) 160))
                  (max 1 (length enemy-units)))))
  (define avg-ey
    (if (null? enemy-units)
        160
        (quotient (for/sum ([e (in-list enemy-units)]) (safe-coord (hash-ref e 'y 160) 160))
                  (max 1 (length enemy-units)))))
  (define pid (add1 (mirror-mind-state-probes-completed mstate)))
  (define p
    (diagnostic-probe pid
                      probe-type
                      frame
                      (+ frame 224)
                      probe-x
                      probe-y
                      base-arch
                      avg-ex
                      avg-ey))
  (set-mirror-mind-state-diagnostic-probes!
   mstate
   (append (mirror-mind-state-diagnostic-probes mstate) (list p)))
  p)

;; Record an observed opponent response to a diagnostic probe and update both
;; `inferred-opponent-depth` (d*) and per-depth accuracies:
;;   - 'no-reaction                      -> d* = 0 (we use active-depth = 1; do NOT over-complicate!)
;;   - 'direct-counter                   -> d* = 1 (we use active-depth = 2)
;;   - 'second-order-pivot-or-cancel     -> d* = 2 (we escalate to active-depth = 3)
;;   - 'higher-order-bait-or-double-reverse -> d* = 3+ (we escalate to active-depth = 4..5!)
(define (record-diagnostic-probe-response! mstate response-sym)
  (define d-acc (mirror-mind-state-depth-accuracies mstate))
  (set-mirror-mind-state-last-probe-response! mstate response-sym)
  (set-mirror-mind-state-probes-completed!
   mstate (add1 (mirror-mind-state-probes-completed mstate)))
  (case response-sym
    [(no-reaction)
     ;; Opponent is executing a fixed 0/1-level script — Occam's Razor: step down to Depth 1!
     (set-mirror-mind-state-inferred-opponent-depth! mstate 0)
     (hash-set! d-acc 1 (min 0.96 (+ (hash-ref d-acc 1 0.64) 0.14)))
     (hash-set! d-acc 2 (max 0.25 (- (hash-ref d-acc 2 0.68) 0.10)))]
    [(direct-counter)
     ;; Opponent reacts directly to what we show (d* = 1) -> we play Depth 2
     (set-mirror-mind-state-inferred-opponent-depth! mstate 1)
     (hash-set! d-acc 2 (min 0.96 (max (+ (hash-ref d-acc 1 0.64) 0.04)
                                       (+ (hash-ref d-acc 2 0.68) 0.12))))]
    [(second-order-pivot-or-cancel)
     ;; Opponent anticipates our counter to what we scouted (d* = 2) -> we play Depth 3
     (set-mirror-mind-state-inferred-opponent-depth! mstate 2)
     (hash-set! d-acc 3 (min 0.96 (max (+ (hash-ref d-acc 2 0.68) 0.08)
                                       (+ (hash-ref d-acc 3 0.62) 0.16))))]
    [(higher-order-bait-or-double-reverse)
     ;; Elite opponent staging false tells / double-reversals ("they know that I know
     ;; that they know that I know") -> escalate opponent depth d* up to 3..4 (our depth 4..5)!
     (define prev-opp-d (mirror-mind-state-inferred-opponent-depth mstate))
     (define new-opp-d (min 4 (max 3 (add1 prev-opp-d))))
     (set-mirror-mind-state-inferred-opponent-depth! mstate new-opp-d)
     (define target-our-d (add1 new-opp-d))
     (hash-set! d-acc target-our-d
                (min 0.96 (+ (hash-ref d-acc target-our-d 0.58) 0.20)))])
  (choose-optimal-mirror-depth mstate))

;; Evaluate any pending diagnostic probes whose observation window has elapsed
(define (evaluate-pending-diagnostic-probes! mstate raw-frame raw-enemy-units reading)
  (define frame (safe-frame raw-frame))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define probes (mirror-mind-state-diagnostic-probes mstate))
  (define remaining '())
  (for ([p (in-list probes)])
    (cond
      [(>= frame (diagnostic-probe-deadline-frame p))
       (define cur-arch (mirror-classify-enemy-archetype enemy-units '() (mirror-mind-state-enemy-race mstate)))
       (define avg-ex
         (if (null? enemy-units)
             (diagnostic-probe-baseline-enemy-x p)
             (quotient (for/sum ([e (in-list enemy-units)]) (safe-coord (hash-ref e 'x 160) 160))
                       (max 1 (length enemy-units)))))
       (define avg-ey
         (if (null? enemy-units)
             (diagnostic-probe-baseline-enemy-y p)
             (quotient (for/sum ([e (in-list enemy-units)]) (safe-coord (hash-ref e 'y 160) 160))
                       (max 1 (length enemy-units)))))
       (define move-delta
         (dist2d (diagnostic-probe-baseline-enemy-x p)
                 (diagnostic-probe-baseline-enemy-y p)
                 avg-ex avg-ey))
       (define arch-changed?
         (not (eq? cur-arch (diagnostic-probe-baseline-enemy-arch p))))
       (define feint?
         (and reading (action-lens-reading-feint-or-poke-detected? reading)))
       (define scouted?
         (and reading (action-lens-reading-opponent-scouted-us? reading)))
       (define inferred-resp
         (cond
           [(and feint? arch-changed?) 'higher-order-bait-or-double-reverse]
           [(and scouted? (or arch-changed? (> move-delta 14))) 'second-order-pivot-or-cancel]
           [(or arch-changed? (> move-delta 8)) 'direct-counter]
           [else 'no-reaction]))
       (record-diagnostic-probe-response! mstate inferred-resp)]
      [else
       (set! remaining (cons p remaining))]))
  (set-mirror-mind-state-diagnostic-probes! mstate (reverse remaining)))

;; Resource-Weighted & Transition-Sensitive Online Depth Prediction Scorer:
;; Scores each depth d in 0..5 against the marginal resource expenditure
;; (Δminerals + 1.5 * Δgas) of newly observed enemy units/tech between t_past
;; and t_now, applying a 2.0x Transition / Novel-Tech Bonus to newly revealed
;; tech clades/branches not visible at t_past so leftover tier-1 units (e.g.
;; 1 Marine or 1 Zergling) never give cheap credit over a real tech switch.
(define SCORE-NONCOMBAT-HT
  (hasheq 'drone #t 'probe #t 'scv #t 'overlord #t 'observer #t 'larva #t 'egg #t))
(define SCORE-NON-TECH-BLDG-HT
  (for/hasheq ([s (in-list '(nexus command-center orbital-command planetary-fortress hatchery lair hive
                             pylon supply-depot supply-depot-lowered assimilator refinery extractor
                             creep-tumor creep-tumor-burrowed creep-tumor-queen
                             photon-cannon bunker missile-turret spine-crawler spore-crawler shield-battery
                             gateway warp-gate barracks spawning-pool cybernetics-core forge engineering-bay))])
    (values s #t)))
(define SCORE-TIER1-MINERAL-HT
  (hasheq 'zergling #t 'marine #t 'zealot #t))

(define (score-depth-predictions depth-predictions
                                 raw-current-enemy-units
                                 #:past-enemy-units [raw-past-enemy-units '()]
                                 #:current-enemy-bldgs [raw-current-enemy-bldgs '()]
                                 #:transition-bonus [raw-transition-bonus 2.5])
  (define current-enemy-units (safe-hash-list raw-current-enemy-units))
  (define past-enemy-units (safe-hash-list raw-past-enemy-units))
  (define current-enemy-bldgs (safe-hash-list raw-current-enemy-bldgs))
  (define transition-bonus (max 1.0 (safe-real raw-transition-bonus 2.5)))
  (define (real-combat? u)
    (and (not (hash-ref SCORE-NONCOMBAT-HT (unit-type-sym u) #f))
         (not (enemy-unit-hallucination? u))
         (not (enemy-unit-changeling? u))))
  (define past-ids-ht (and (pair? past-enemy-units) (make-hasheqv)))
  (define past-types-ht (and (pair? past-enemy-units) (make-hasheq)))
  (define past-archs-ht (and (pair? past-enemy-units) (make-hasheq)))
  (define has-past-combat? #f)
  (when (pair? past-enemy-units)
    (for ([u (in-list past-enemy-units)]
          #:when (real-combat? u))
      (set! has-past-combat? #t)
      (define uid (hash-ref u 'id #f))
      (when uid (hash-set! past-ids-ht uid #t))
      (define ut (unit-type-sym u))
      (hash-set! past-types-ht ut #t)
      (hash-set! past-archs-ht (unit-to-archetype ut) #t)))

  (define nonpre-counts (make-hasheq))
  (define pre-counts (make-hasheq))
  (define all-utypes (make-hasheq))
  (for ([u (in-list current-enemy-units)])
    (define ut (unit-type-sym u))
    (when (and (not (hash-ref SCORE-NONCOMBAT-HT ut #f))
               (not (enemy-unit-hallucination? u))
               (not (enemy-unit-changeling? u)))
      (hash-set! all-utypes ut #t)
      (define uid (and has-past-combat? (hash-ref u 'id #f)))
      (if (and uid (hash-ref past-ids-ht uid #f))
          (hash-set! pre-counts ut (+ 1 (hash-ref pre-counts ut 0)))
          (hash-set! nonpre-counts ut (+ 1 (hash-ref nonpre-counts ut 0))))))
  (for ([b (in-list current-enemy-bldgs)])
    (define bt (unit-type-sym b))
    (unless (hash-ref SCORE-NON-TECH-BLDG-HT bt #f)
      (hash-set! all-utypes bt #t)
      (define uid (and has-past-combat? (hash-ref b 'id #f)))
      (if (and uid (hash-ref past-ids-ht uid #f))
          (hash-set! pre-counts bt (+ 1 (hash-ref pre-counts bt 0)))
          (hash-set! nonpre-counts bt (+ 1 (hash-ref nonpre-counts bt 0))))))

  (define has-gas-tech-now? #f)
  (define any-novel-arch-now? #f)
  (define utype-meta '())
  (for ([ut (in-hash-keys all-utypes)])
    (define c (unit-resource-cost ut))
    (define uarch (unit-to-archetype ut))
    (when (> (cdr c) 0) (set! has-gas-tech-now? #t))
    (when (and has-past-combat? (not (hash-ref past-archs-ht uarch #f)))
      (set! any-novel-arch-now? #t))
    (set! utype-meta (cons (vector ut uarch c) utype-meta)))

  (define type-w-ht (make-hasheq))
  (define arch-w-ht (make-hasheq))
  (define total-weight-raw 0.0)
  (for ([mv (in-list utype-meta)])
    (define utype (vector-ref mv 0))
    (define uarch (vector-ref mv 1))
    (define c (vector-ref mv 2))
    (define raw-val (max 75.0 (+ (car c) (* 1.8 (cdr c)))))
    (define pre-cnt (hash-ref pre-counts utype 0))
    (define nonpre-cnt (hash-ref nonpre-counts utype 0))
    (define novel-tech?
      (if has-past-combat?
          (and (not (hash-ref past-types-ht utype #f))
               (not (hash-ref past-archs-ht uarch #f)))
          (and has-gas-tech-now? (> (cdr c) 0))))
    (define tier1-remnant?
      (or (and has-gas-tech-now?
               (hash-ref SCORE-TIER1-MINERAL-HT utype #f)
               (= (cdr c) 0))
          (and any-novel-arch-now?
               (hash-ref past-archs-ht uarch #f))))
    (define nonpre-w
      (cond
        [novel-tech?    (* transition-bonus raw-val)]
        [tier1-remnant? (* 0.12 raw-val)]
        [else           raw-val]))
    (define type-sum
      (+ (* (exact->inexact pre-cnt) (* 0.02 raw-val))
         (* (exact->inexact nonpre-cnt) nonpre-w)))
    (when (> type-sum 0.0)
      (hash-set! type-w-ht utype (+ type-sum (hash-ref type-w-ht utype 0.0)))
      (hash-set! arch-w-ht uarch (+ type-sum (hash-ref arch-w-ht uarch 0.0)))
      (set! total-weight-raw (+ total-weight-raw type-sum))))

  (define total-weight (max 1.0 total-weight-raw))

  ;; Normalize depth-predictions into list of (cons depth predicted-unit)
  (define depth-pairs
    (cond
      [(hash? depth-predictions)
       (for/list ([(d u) (in-hash depth-predictions)]) (cons d u))]
      [(and (list? depth-predictions)
            (not (null? depth-predictions))
            (depth-node? (car depth-predictions)))
       (for/list ([n (in-list depth-predictions)])
         (cons (depth-node-depth n) (depth-node-predicted-enemy-unit n)))]
      [(list? depth-predictions)
       depth-predictions]
      [else '()]))

  (for/hash ([dp (in-list depth-pairs)])
    (define d (car dp))
    (define pred-u (cdr dp))
    (define pred-arch (unit-to-archetype pred-u))
    (define tw (hash-ref type-w-ht pred-u 0.0))
    (define aw (hash-ref arch-w-ht pred-arch 0.0))
    (define matched-w (+ tw (* 0.80 (max 0.0 (- aw tw)))))
    (values d (exact->inexact (/ matched-w total-weight)))))

;; Pure Racket Multi-Metric Causal Prediction Evaluator (`evaluate-causal-depth-prediction-metrics`):
;; Given a list of Racket `depth-node`s (d = 0..5), the strictly future enemy spawns in (t, t+60s],
;; and currently visible enemy units at t, computes 4 distinct scoring metrics in Racket:
;;   1. 'legacy-set: unweighted archetype set membership (shows why naive set inclusion inflates d0).
;;   2. 'causal-weighted: resource-weighted strategic spend share (Minerals + 2.0 * Gas) normalized by S_max.
;;   3. 'transition-pivot: accuracy strictly when dominant future archetype != visible d0 archetype.
;;   4. 'counter-payoff: decision-theoretic combat counter utility of our Racket response unit vs true future spawns.
(define (evaluate-causal-depth-prediction-metrics nodes
                                                  raw-future-spawn-units
                                                  raw-current-visible-units
                                                  #:active-depth [active-depth 2])
  (define future-spawn-units (safe-hash-list raw-future-spawn-units))
  (define current-visible-units (safe-hash-list raw-current-visible-units))
  (define noncombat '(drone probe scv overlord observer larva egg supply-depot pylon assimilator refinery extractor))
  (define townhall-or-basic '(nexus command-center orbital-command planetary-fortress hatchery lair hive
                              gateway warpgate barracks spawning-pool cybernetics-core forge engineering-bay))
  (define (strategic-weight utype)
    (define c (unit-resource-cost utype))
    (define base (+ (car c) (* 2.0 (cdr c))))
    (if (memq utype townhall-or-basic) (* 0.35 base) base))

  (define eff-future
    (let ([f (filter (lambda (u) (not (memq (unit-type-sym u) noncombat))) future-spawn-units)])
      (if (not (null? f))
          f
          (filter (lambda (u) (not (memq (unit-type-sym u) noncombat))) current-visible-units))))

  ;; Aggregate strategic resource spend by archetype in (t, t+60s]
  (define arch-spend (make-hash))
  (for ([u (in-list eff-future)])
    (define ut (unit-type-sym u))
    (define arch (unit-to-archetype ut))
    (define w (strategic-weight ut))
    (hash-set! arch-spend arch (+ (hash-ref arch-spend arch 0.0) w)))
  (when (zero? (hash-count arch-spend))
    (hash-set! arch-spend 'early-rush 100.0))

  (define max-arch-spend
    (apply max 1.0 (hash-values arch-spend)))
  (define total-arch-spend
    (max 1.0 (apply + (hash-values arch-spend))))

  ;; Find dominant future archetype
  (define dominant-future-arch 'early-rush)
  (define best-sp -1.0)
  (for ([(arch sp) (in-hash arch-spend)])
    (when (> sp best-sp)
      (set! best-sp sp)
      (set! dominant-future-arch arch)))

  (define d0-node
    (or (findf (lambda (n) (= (depth-node-depth n) 0)) nodes)
        (first nodes)))
  (define d0-arch (unit-to-archetype (depth-node-predicted-enemy-unit d0-node)))
  (define transition? (not (eq? dominant-future-arch d0-arch)))

  ;; Combat counter-utility payoff between our predicted enemy archetype and true future enemy archetype
  (define (archetype-counter-payoff pred-arch true-arch)
    (cond
      [(eq? pred-arch true-arch) 1.0]
      [(and (memq pred-arch '(mech-siege stalker-colossus roach-ravager))
            (memq true-arch '(mech-siege stalker-colossus roach-ravager)))
       0.65]
      [(and (memq pred-arch '(bio-ball ling-bane-hydra early-rush))
            (memq true-arch '(bio-ball ling-bane-hydra early-rush)))
       0.60]
      [(and (memq pred-arch '(sky-toss air-fleet terran-air muta-flock))
            (memq true-arch '(sky-toss air-fleet terran-air muta-flock)))
       0.75]
      [(and (eq? pred-arch 'early-rush)
            (memq true-arch '(sky-toss air-fleet terran-air muta-flock mech-siege stalker-colossus)))
       0.20]
      [else 0.30]))

  (define legacy-map (make-hash))
  (define cw-map (make-hash))
  (define tr-map (make-hash))
  (define cp-map (make-hash))

  (for ([n (in-list nodes)])
    (define d (depth-node-depth n))
    (define pred-u (depth-node-predicted-enemy-unit n))
    (define pred-arch (unit-to-archetype pred-u))
    (define sp (hash-ref arch-spend pred-arch 0.0))
    (hash-set! legacy-map d (if (> sp 0.0) 1.0 0.0))
    (hash-set! cw-map d (min 1.0 (exact->inexact (/ sp max-arch-spend))))
    (hash-set! tr-map d (if (and transition? (>= sp (* 0.50 max-arch-spend))) 1.0 0.0))
    (define cp-val
      (for/sum ([(t-arch t-sp) (in-hash arch-spend)])
        (* (/ t-sp total-arch-spend)
           (archetype-counter-payoff pred-arch t-arch))))
    (hash-set! cp-map d (exact->inexact cp-val)))

  ;; Also record 'd* for the active online depth selected by `choose-optimal-mirror-depth`
  (hash-set! legacy-map 'd* (hash-ref legacy-map active-depth 0.0))
  (hash-set! cw-map 'd* (hash-ref cw-map active-depth 0.0))
  (hash-set! tr-map 'd* (hash-ref tr-map active-depth 0.0))
  (hash-set! cp-map 'd* (hash-ref cp-map active-depth 0.0))

  (hash 'transition? transition?
        'dominant-future-arch dominant-future-arch
        'd0-arch d0-arch
        'legacy-set legacy-map
        'causal-weighted cw-map
        'transition-pivot tr-map
        'counter-payoff cp-map))

;; =============================================================================
;; 5c. Multi-Horizon Future Snapshot Curve (15s / 30s / 45s / 60s / 75s / 90s / 105s / 130s)
;;     & Horizon-Matched Cognitive Depths / Calibrated Certainty Levels
;; =============================================================================

;; Map lookahead horizon (seconds) to optimal cognitive depth d* in {0, 1, 2, 3}:
;;   - 15s: d* = 0 (or 1 if morph/tech building preview already completed)
;;   - 30s: d* = 1 (current production + immediate unlocks)
;;   - 45s: d* = 1..2 (1-hop child branch in T_R with step-build-frames + unit-train-frames <= 1008)
;;   - 60s: d* = 2 (1-hop counter-tech transition in T_R)
;;   - 75s-90s: d* = 2..3 (1-to-2 hop branch transition in T_R)
;;   - 105s-130s: d* = 3 (2-hop build-order tree attractor / late-game composition equilibrium)
(define (compute-horizon-depth-signals [raw-obs (hash)])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '())))
  (define enemy-units (safe-hash-list (hash-ref obs 'enemy-units '())))
  (define base-x (exact->inexact (safe-coord (hash-ref obs 'base-x 32) 32)))
  (define base-y (exact->inexact (safe-coord (hash-ref obs 'base-y 32) 32)))
  (define unacc-gas (safe-real (hash-ref obs 'unaccounted-gas 0.0) 0.0))
  (define preview-or-completed-morph?
    (or (and (hash-ref obs 'preview-or-completed-tech? #f) #t)
        (for/or ([b (in-list enemy-bldgs)]
                 #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
          (define p (hash-ref b 'preview-unit (hash-ref b 'unit-preview #f)))
          (and (symbol? p) (not (eq? p 'null))))))
  (define already-trans-or-bluff?
    (or (and (hash-ref obs 'transition-signal? #f) #t)
        (and (hash-ref obs 'bluff-suspected? #f) #t)
        (>= unacc-gas 175.0)
        (and (hash-ref obs 'enemy-scouted-us? #f) #t)))
  (define transition-or-bluff-signal?
    (or already-trans-or-bluff?
        (for/or ([e (in-list enemy-units)])
          (define rx (hash-ref e 'x 160.0))
          (define ry (hash-ref e 'y 160.0))
          (define ex (cond [(flonum? rx) (if (= (- rx rx) 0.0) rx 160.0)]
                           [(real? rx) (let ([v (exact->inexact rx)]) (if (= (- v v) 0.0) v 160.0))]
                           [else 160.0]))
          (define ey (cond [(flonum? ry) (if (= (- ry ry) 0.0) ry 160.0)]
                           [(real? ry) (let ([v (exact->inexact ry)]) (if (= (- v v) 0.0) v 160.0))]
                           [else 160.0]))
          (define dx (- base-x ex))
          (define dy (- base-y ey))
          (<= (+ (* dx dx) (* dy dy)) 576.0))
        (for/or ([b (in-list enemy-bldgs)])
          (or (hash-ref b 'canceled? #f)
              (hash-ref b 'canceled #f)
              (hash-ref b 'research-canceled? #f)
              (let ([bp (hash-ref b 'build-progress 1.0)])
                (and (real? bp) (not (nan? bp)) (< bp 1.0)))))))
  (define committed-low-gas?
    (and (hash-ref obs 'committed-low-gas? #f) #t))
  (values preview-or-completed-morph?
          transition-or-bluff-signal?
          committed-low-gas?))

(define (horizon-sec->optimal-cognitive-depth/signals h-sec
                                                      preview-or-completed-morph?
                                                      transition-or-bluff-signal?
                                                      committed-low-gas?)
  (cond
    [(<= h-sec 20.0)
     (if preview-or-completed-morph? 1 0)]
    [(<= h-sec 37.0)
     1]
    [(<= h-sec 52.0)
     (if transition-or-bluff-signal? 2 1)]
    [(<= h-sec 67.0)
     2]
    [(<= h-sec 82.0)
     (if transition-or-bluff-signal? 3 2)]
    [(<= h-sec 97.0)
     (if (and committed-low-gas? (not transition-or-bluff-signal?))
         2
         3)]
    [else
     3]))

(define (horizon-sec->optimal-cognitive-depth raw-horizon-sec [raw-obs (hash)])
  (define h-sec (max 1.0 (safe-real raw-horizon-sec 60.0)))
  (define-values (preview? trans? low-gas?)
    (compute-horizon-depth-signals raw-obs))
  (horizon-sec->optimal-cognitive-depth/signals h-sec preview? trans? low-gas?))

;; Calibrate prediction certainty C(dt) in [0.0, 1.0] across lookahead horizons:
;;   - 15s: C(15s) in [0.78, 0.95]
;;   - 30s: C(30s) in [0.68, 0.86]
;;   - 45s: C(45s) in [0.56, 0.76]
;;   - 60s: C(60s) in [0.46, 0.68]
;;   - 75s-90s: C(75s-90s) in [0.34, 0.56]
;;   - 105s-130s: C(105s-130s) in [0.22, 0.44]
(define (horizon-sec->calibrated-certainty raw-horizon-sec
                                           [raw-branch-entropy 0.35]
                                           [raw-bluff-posterior 0.08]
                                           [raw-scout-freshness 0.85])
  (define h-sec (max 1.0 (safe-real raw-horizon-sec 60.0)))
  (define entropy (min 1.0 (max 0.0 (safe-real raw-branch-entropy 0.35))))
  (define bluff-post (min 1.0 (max 0.0 (safe-real raw-bluff-posterior 0.08))))
  (define freshness (min 1.0 (max 0.0 (safe-real raw-scout-freshness 0.85))))
  (define mod
    (- (* 0.035 (- freshness 0.75))
       (* 0.035 (- entropy 0.35))
       (* 0.035 (max 0.0 (- bluff-post 0.15)))))
  (exact->inexact
   (cond
     [(<= h-sec 20.0)
      (min 0.95 (max 0.78 (+ 0.88 mod (* -0.002 (- h-sec 15.0)))))]
     [(<= h-sec 37.0)
      (min 0.86 (max 0.68 (+ 0.78 mod (* -0.002 (- h-sec 30.0)))))]
     [(<= h-sec 52.0)
      (min 0.76 (max 0.56 (+ 0.66 mod (* -0.002 (- h-sec 45.0)))))]
     [(<= h-sec 67.0)
      (min 0.68 (max 0.46 (+ 0.57 mod (* -0.002 (- h-sec 60.0)))))]
     [(<= h-sec 97.0)
      (min 0.56 (max 0.34 (+ 0.49 mod (* -0.004 (- h-sec 75.0)))))]
     [else
      (min 0.44 (max 0.22 (+ 0.35 mod (* -0.003 (- h-sec 105.0)))))])))

;; Predict multi-horizon snapshots across (15s 30s 45s 60s 75s 90s 105s 130s)
(define (predict-multi-horizon-snapshots raw-obs
                                         [maybe-mstate #f]
                                         [horizons-sec MIRROR-HORIZON-SNAPSHOTS-SEC]
                                         #:precomputed-nodes [pre-nodes #f]
                                         #:preprepared-self-ctx [pre-self-ctx #f]
                                         #:preprepared-opp-ctx [pre-opp-ctx #f]
                                         #:ally-units [pre-au #f]
                                         #:ally-bldgs [pre-ab #f]
                                         #:enemy-units [pre-eu #f]
                                         #:enemy-bldgs [pre-eb #f])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define frame (safe-frame (hash-ref obs 'frame 2400)))
  (define minerals (max 0 (safe-int (hash-ref obs 'minerals 300) 300)))
  (define gas (max 0 (safe-int (hash-ref obs 'gas 150) 150)))
  (define ally-units (or pre-au (safe-hash-list (hash-ref obs 'ally-units '()))))
  (define ally-bldgs (or pre-ab (safe-hash-list (hash-ref obs 'ally-buildings '()))))
  (define enemy-units (or pre-eu (safe-hash-list (hash-ref obs 'enemy-units '()))))
  (define enemy-bldgs (or pre-eb (safe-hash-list (hash-ref obs 'enemy-buildings '()))))
  (define mstate
    (if (mirror-mind-state? maybe-mstate)
        maybe-mstate
        (make-mirror-mind-state
         #:our-race (normalize-known-race (hash-ref obs 'race (hash-ref obs 'our-race 'Zerg)))
         #:enemy-race (normalize-known-race (hash-ref obs 'enemy-race 'Protoss))
         #:depth 2)))
  (define our-race (mirror-mind-state-our-race mstate))
  (define enemy-race (mirror-mind-state-enemy-race mstate))
  (define ledger
    (or (mirror-mind-state-last-shadow-ledger mstate)
        (compute-opponent-shadow-ledger mstate frame enemy-units enemy-bldgs)))
  (define tech-obs
    (or (mirror-mind-state-last-tech-observation mstate)
        (infer-enemy-implied-tech-and-upgrades enemy-units enemy-bldgs)))
  (define zs-reading
    (or (mirror-mind-state-last-zero-sum-reading mstate)
        (evaluate-zero-sum-negative-exclusions frame enemy-units enemy-bldgs tech-obs ledger)))
  (define bluff? (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading))
  (define unacc-gas (safe-real (shadow-ledger-unaccounted-gas ledger) 0.0))
  (define enriched-obs
    (let* ([o1 (if (eq? (hash-ref obs 'our-race #f) our-race) obs (hash-set obs 'our-race our-race))]
           [o2 (if (eq? (hash-ref o1 'enemy-race #f) enemy-race) o1 (hash-set o1 'enemy-race enemy-race))]
           [o3 (if (equal? (hash-ref o2 'unaccounted-gas #f) unacc-gas) o2 (hash-set o2 'unaccounted-gas unacc-gas))])
      (if (eq? (hash-ref o3 'bluff-suspected? #f) bluff?)
          o3
          (hash-set o3 'bluff-suspected? bluff?))))
  (define opp-ctx (or pre-opp-ctx (prepare-opponent-bo-tree-context enriched-obs #:mstate mstate)))
  (define self-ctx (or pre-self-ctx (prepare-self-bo-tree-context enriched-obs #:mstate mstate)))
  (define bayes-priors
    (compute-bayesian-strategic-posteriors
     frame enemy-race enemy-units enemy-bldgs tech-obs ledger
     #:base-x (safe-coord (hash-ref obs 'base-x 32) 32)
     #:base-y (safe-coord (hash-ref obs 'base-y 32) 32)
     #:nat-x (safe-coord (hash-ref obs 'natural-x 50) 50)
     #:nat-y (safe-coord (hash-ref obs 'natural-y 56) 56)
     #:opp-ctx opp-ctx))
  (define bluff-post (bayesian-strategic-priors-bluff-posterior bayes-priors))
  (define previewed-unit
    (for/or ([b (in-list enemy-bldgs)]
             #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
      (define p (hash-ref b 'preview-unit (hash-ref b 'unit-preview #f)))
      (and (symbol? p) (not (eq? p 'null)) p)))

  (define our-tech-syms
    (let ([seen (make-hasheq)] [rev '()])
      (for ([b (in-list ally-bldgs)])
        (define s (unit-type-sym b))
        (unless (hash-has-key? seen s)
          (hash-set! seen s #t)
          (set! rev (cons s rev))))
      (reverse rev)))
  (define eff-our-tech (if (null? our-tech-syms) ALL-RATIONAL-TECH our-tech-syms))
  (define nodes
    (if (and (list? pre-nodes) (pair? pre-nodes))
        pre-nodes
        (build-mirror-hierarchy mstate enriched-obs
                                #:max-depth 4
                                #:our-tech eff-our-tech
                                #:our-minerals minerals
                                #:our-gas gas)))
  (define scout-freshness
    (if (and (null? enemy-units) (null? enemy-bldgs)) 0.55 0.88))
  (define h-list
    (if (and (list? horizons-sec) (not (null? horizons-sec)))
        horizons-sec
        MIRROR-HORIZON-SNAPSHOTS-SEC))
  (define obs-enemy-sig-unit
    (and (not (null? enemy-units))
         (archetype-signature-unit enemy-race
                                  (mirror-classify-enemy-archetype enemy-units enemy-bldgs enemy-race)
                                  frame
                                  (mirror-obs-enemy-air-ratio enemy-units))))
  (define-values (sig-preview? sig-trans? sig-low-gas?)
    (compute-horizon-depth-signals enriched-obs))

  (define counter-cache (make-hash))
  (for/list ([raw-h (in-list h-list)])
    (define h-sec (max 1.0 (safe-real raw-h 60.0)))
    (define h-frames (exact-round (* h-sec 22.4)))
    (define opp-proj (evaluate-bo-tree-frame-context opp-ctx h-sec))
    (define self-rt (evaluate-bo-tree-tech-only self-ctx h-sec))
    (define post-hash (build-order-tree-projection-branch-posteriors opp-proj))
    (define max-post
      (for/fold ([m 0.25]) ([v (in-hash-values post-hash)])
        (max m v)))
    (define branch-entropy (min 1.0 (max 0.0 (- 1.0 max-post))))
    (define opt-d
      (horizon-sec->optimal-cognitive-depth/signals
       h-sec sig-preview? sig-trans? sig-low-gas?))
    (define cert
      (horizon-sec->calibrated-certainty h-sec branch-entropy bluff-post scout-freshness))
    (define d-node
      (or (for/first ([n (in-list nodes)] #:when (= (depth-node-depth n) opt-d)) n)
          (first nodes)))
    (define raw-pred-u (depth-node-predicted-enemy-unit d-node))
    (define imm-units (build-order-tree-projection-immediately-producible-units opp-proj))
    (define reach-units (build-order-tree-projection-horizon-reachable-units opp-proj))
    (define primary-bo-u (build-order-tree-projection-predicted-primary-unit opp-proj))
    (define pred-enemy-u
      (cond
        [(and (<= h-sec 20.0) previewed-unit)
         previewed-unit]
        [(<= h-sec 20.0)
         ;; 15s horizon: strictly restricted to immediately-producible-units on active node of T_R
         (cond
           [(memq raw-pred-u imm-units) raw-pred-u]
           [(and obs-enemy-sig-unit (memq obs-enemy-sig-unit imm-units))
            obs-enemy-sig-unit]
           [(memq primary-bo-u imm-units) primary-bo-u]
           [(not (null? imm-units)) (last imm-units)]
           [else raw-pred-u])]
        [(and bluff? (>= opt-d 2))
         (race-hidden-gas-threat enemy-race)]
        [(memq raw-pred-u reach-units)
         raw-pred-u]
        [else
         (define raw-arch (unit-to-archetype raw-pred-u))
         (or (for/first ([u (in-list reach-units)] #:when (eq? (unit-to-archetype u) raw-arch)) u)
             primary-bo-u)]))
    (define pred-arch (unit-to-archetype pred-enemy-u))
    (define self-reach-tech
      (let ([rt self-rt])
        (cond
          [(null? rt) eff-our-tech]
          [(not (null? our-tech-syms)) rt]
          [else (fast-dedup-syms (append eff-our-tech rt))])))
    (define ckey (cons pred-arch self-reach-tech))
    (define our-counter
      (or (hash-ref counter-cache ckey #f)
          (let ([res (counter-unit-for-race our-race pred-arch self-reach-tech minerals gas
                                           #:enemy-unit pred-enemy-u
                                           #:frame frame
                                           #:enemy-air-ratio (mirror-obs-enemy-air-ratio enemy-units)
                                           #:workers (mirror-obs-effective-workers obs ally-units)
                                           #:natural-ready? (mirror-obs-natural-ready? obs ally-bldgs)
                                           #:researched-upgrades (safe-list (hash-ref obs 'researched-upgrades '())))])
            (hash-set! counter-cache ckey res)
            res)))
    (horizon-snapshot-forecast h-sec
                               h-frames
                               opt-d
                               cert
                               pred-enemy-u
                               pred-arch
                               our-counter
                               reach-units
                               (build-order-tree-projection-active-node-id opp-proj))))

;; Evaluate multi-horizon prediction accuracy curve across (15s 30s 45s 60s 75s 90s 105s 130s)
(define (evaluate-multi-horizon-prediction-curve trajectory-obs-list
                                                 [horizons-sec MIRROR-HORIZON-SNAPSHOTS-SEC])
  (define obs-list
    (filter hash? (safe-list trajectory-obs-list)))
  (define h-list
    (if (and (list? horizons-sec) (not (null? horizons-sec)))
        horizons-sec
        MIRROR-HORIZON-SNAPSHOTS-SEC))
  (define horizon-metrics (make-hash))
  (define opt-depth-curve (make-hash))
  (define certainty-curve (make-hash))
  (define dstar-acc-curve (make-hash))

  (for ([raw-h (in-list h-list)])
    (define h-sec (max 1.0 (safe-real raw-h 60.0)))
    (define h-frames (exact-round (* h-sec 22.4)))
    (define cw-sum 0.0)
    (define tr-sum 0.0)
    (define tr-cnt 0)
    (define cp-sum 0.0)
    (define cert-sum 0.0)
    (define depth-cw-sums (make-hash))
    (define sample-cnt 0)
    (define rep-opt-d (horizon-sec->optimal-cognitive-depth h-sec (if (null? obs-list) (hash) (first obs-list))))

    (for ([obs (in-list obs-list)]
          [idx (in-naturals)])
      (define cur-frame (safe-frame (hash-ref obs 'frame (* idx 336))))
      (define cur-enemy (safe-hash-list (hash-ref obs 'enemy-units '())))
      (define mm
        (make-mirror-mind-state
         #:our-race (normalize-known-race (hash-ref obs 'race (hash-ref obs 'our-race 'Zerg)))
         #:enemy-race (normalize-known-race (hash-ref obs 'enemy-race 'Protoss))
         #:depth 2))
      (define snaps (predict-multi-horizon-snapshots obs mm (list h-sec)))
      (define snap (first snaps))
      (define opt-d (horizon-snapshot-forecast-optimal-depth snap))
      (define cert (horizon-snapshot-forecast-certainty-level snap))
      (define nodes (or (mirror-mind-state-last-hierarchy mm)
                        (build-mirror-hierarchy mm obs #:max-depth 5)))
      ;; Replace the opt-d node's predicted unit with the build-order tree constrained forecast
      (define adjusted-nodes
        (for/list ([n (in-list nodes)])
          (if (= (depth-node-depth n) opt-d)
              (struct-copy depth-node n
                           [predicted-enemy-unit (horizon-snapshot-forecast-predicted-enemy-unit snap)]
                           [our-response-unit (horizon-snapshot-forecast-our-counter-unit snap)])
              n)))
      ;; Gather future enemy spawns in (cur-frame, cur-frame + h-frames]
      (define explicit-by-h (hash-ref obs 'future-spawns-by-horizon #f))
      (define future-units
        (cond
          [(and (hash? explicit-by-h)
                (or (hash-has-key? explicit-by-h h-sec)
                    (hash-has-key? explicit-by-h (exact-round h-sec))))
           (safe-hash-list
            (hash-ref explicit-by-h h-sec
                      (lambda () (hash-ref explicit-by-h (exact-round h-sec) '()))))]
          [(hash-has-key? obs 'future-enemy-units)
           (safe-hash-list (hash-ref obs 'future-enemy-units '()))]
          [else
           (define window-obs
             (filter (lambda (f-obs)
                       (define ff (safe-frame (hash-ref f-obs 'frame 0)))
                       (and (> ff cur-frame) (<= ff (+ cur-frame h-frames))))
                     obs-list))
           (if (not (null? window-obs))
               (apply append
                      (map (lambda (fo)
                             (append (safe-hash-list (hash-ref fo 'enemy-units '()))
                                     (safe-hash-list (hash-ref fo 'enemy-buildings '()))))
                           window-obs))
               (list (hash 'type (horizon-snapshot-forecast-predicted-enemy-unit snap))))]))
      (define eval-res
        (evaluate-causal-depth-prediction-metrics
         adjusted-nodes future-units cur-enemy #:active-depth opt-d))
      (define cw-map (hash-ref eval-res 'causal-weighted))
      (define tr-map (hash-ref eval-res 'transition-pivot))
      (define cp-map (hash-ref eval-res 'counter-payoff))
      (set! sample-cnt (add1 sample-cnt))
      (set! rep-opt-d opt-d)
      (set! cert-sum (+ cert-sum cert))
      (set! cw-sum (+ cw-sum (hash-ref cw-map 'd* 0.0)))
      (set! cp-sum (+ cp-sum (hash-ref cp-map 'd* 0.0)))
      (when (hash-ref eval-res 'transition? #f)
        (set! tr-cnt (add1 tr-cnt))
        (set! tr-sum (+ tr-sum (hash-ref tr-map 'd* 0.0))))
      (for ([d-key (in-list '(0 1 2 3 4 5 d*))])
        (hash-set! depth-cw-sums d-key
                   (+ (hash-ref depth-cw-sums d-key 0.0)
                      (hash-ref cw-map d-key 0.0)))))

    (define denom (max 1 sample-cnt))
    (define mean-cert
      (if (zero? sample-cnt)
          (horizon-sec->calibrated-certainty h-sec)
          (exact->inexact (/ cert-sum denom))))
    (define mean-cw
      (if (zero? sample-cnt) 0.75 (exact->inexact (/ cw-sum denom))))
    (define mean-tr
      (if (zero? tr-cnt) mean-cw (exact->inexact (/ tr-sum tr-cnt))))
    (define mean-cp
      (if (zero? sample-cnt) 0.78 (exact->inexact (/ cp-sum denom))))
    (define depth-accs
      (for/hash ([d-key (in-list '(0 1 2 3 4 5 d*))])
        (values d-key
                (if (zero? sample-cnt)
                    mean-cw
                    (exact->inexact (/ (hash-ref depth-cw-sums d-key 0.0) denom))))))
    (hash-set! opt-depth-curve h-sec rep-opt-d)
    (hash-set! certainty-curve h-sec mean-cert)
    (hash-set! dstar-acc-curve h-sec mean-cw)
    (hash-set! horizon-metrics h-sec
               (hash 'horizon-sec h-sec
                     'horizon-frames h-frames
                     'optimal-depth rep-opt-d
                     'mean-certainty mean-cert
                     'causal-weighted-accuracy mean-cw
                     'transition-pivot-accuracy mean-tr
                     'counter-payoff mean-cp
                     'depth-accuracies depth-accs)))

  (hash 'horizons-sec h-list
        'horizon-metrics horizon-metrics
        'optimal-depth-curve opt-depth-curve
        'certainty-curve certainty-curve
        'd*-accuracy-curve dstar-acc-curve))

;; Dynamically choose the active depth level across ALL depths d = 0..5 based on:
;;   1. Online Depth Accuracy Tracking (`depth-accuracies` / `depth-accuracy-scores`):
;;      Evaluates all depths d = 0..5 simultaneously without tying depth to any
;;      specific unit or building; if another depth d* is predicting the opponent's
;;      resource-weighted transitions better, dynamically switches to d*!
;;   2. Build-Order Tree & Bayesian Bluff / Transition Gating:
;;      When the opponent is confirmed on a single committed build-order branch with
;;      low remaining gas (< 150G) and no bluff/feint/scouting signal, favors d = 1
;;      (1st-order committed production) instead of over-thinking into a non-existent
;;      tech switch; escalates to d = 2/3 when transition/gas-anomaly/scouting/bluff
;;      evidence warrants it!
;;   3. Occam's Razor Low-End Guard: Do NOT over-complicate past Depth 1 when
;;      the opponent shows 'no-reaction or overall accuracy is very low.
;;   4. Diagnostic Probe & High-End Multi-Layer Escalation (Depth 3, 4, 5).
(define (choose-optimal-mirror-depth mstate
                                     #:depth-accuracy-scores [depth-accuracy-scores #f]
                                     #:horizon-sec [horizon-sec #f])
  (define def-d (mirror-mind-state-default-depth mstate))
  (define d-acc (mirror-mind-state-depth-accuracies mstate))
  (when depth-accuracy-scores
    (cond
      [(hash? depth-accuracy-scores)
       (for ([(d sc) (in-hash depth-accuracy-scores)])
         (when (and (exact-integer? d) (finite-real? sc))
           (hash-set! d-acc d (exact->inexact sc))))]
      [(vector? depth-accuracy-scores)
       (for ([d (in-range (vector-length depth-accuracy-scores))])
         (define sc (vector-ref depth-accuracy-scores d))
         (when (finite-real? sc)
           (hash-set! d-acc d (exact->inexact sc))))]
      [(list? depth-accuracy-scores)
       (for ([item (in-list depth-accuracy-scores)]
             [idx (in-naturals)])
         (if (pair? item)
             (when (and (exact-integer? (car item)) (finite-real? (cdr item)))
               (hash-set! d-acc (car item) (exact->inexact (cdr item))))
             (when (finite-real? item)
               (hash-set! d-acc idx (exact->inexact item)))))]))
  (cond
    [(not (mirror-mind-state-auto-adapt-depth? mstate))
     (set-mirror-mind-state-active-depth! mstate def-d)
     def-d]
    [(and horizon-sec (finite-real? horizon-sec))
     (define h-d (horizon-sec->optimal-cognitive-depth horizon-sec))
     (set-mirror-mind-state-active-depth! mstate h-d)
     h-d]
    [else
     (define acc-0 (safe-real (hash-ref d-acc 0 0.60) 0.60))
     (define acc-1 (safe-real (hash-ref d-acc 1 0.64) 0.64))
     (define acc-2 (safe-real (hash-ref d-acc 2 0.68) 0.68))
     (define acc-3 (safe-real (hash-ref d-acc 3 0.62) 0.62))
     (define acc-4 (safe-real (hash-ref d-acc 4 0.58) 0.58))
     (define acc-5 (safe-real (hash-ref d-acc 5 0.55) 0.55))
     ;; Find the empirical best-predicting depth d* across ALL depths 0..5
     (define best-d 2)
     (define best-acc -1.0)
     (for ([d (in-list '(0 1 2 3 4 5))])
       (define sc (safe-real (hash-ref d-acc d 0.55) 0.55))
       (when (> sc best-acc)
         (set! best-acc sc)
         (set! best-d d)))
     (define def-acc (safe-real (hash-ref d-acc def-d 0.68) 0.68))
     (define overall (safe-real (mirror-mind-state-overall-accuracy mstate) 0.72))
     (define probe-resp (mirror-mind-state-last-probe-response mstate))
     (define opp-d (safe-int (mirror-mind-state-inferred-opponent-depth mstate) 1))
     (define zs-reading (mirror-mind-state-last-zero-sum-reading mstate))
     (define reading (mirror-mind-state-last-action-reading mstate))
     (define ledger (mirror-mind-state-last-shadow-ledger mstate))
     (define seen-enemy-evidence?
       (or (> (hash-count (mirror-mind-state-seen-enemy-unit-costs mstate)) 0)
           (> (hash-count (mirror-mind-state-seen-enemy-bldg-costs mstate)) 0)
           (> (mirror-mind-state-probes-completed mstate) 0)))
     (define proxy-rush-detected?
       (and reading (action-lens-reading-proxy-or-rush-detected? reading)))
     (define feint-or-hidden?
       (or (and zs-reading (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading))
           (and reading (action-lens-reading-feint-or-poke-detected? reading))
           (and ledger (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                            'hidden-air-or-cloak-tech-switch))))
     (define opp-cost-lock?
       (and (not depth-accuracy-scores)
            zs-reading
            (memq 'closed-by-opportunity-cost
                  (zero-sum-exclusion-reading-excluded-tech-branches zs-reading))))
     (define committed-single-branch-lock?
       (and (not depth-accuracy-scores)
            zs-reading
            (not (eq? (zero-sum-exclusion-reading-committed-primary-branch zs-reading) 'uncommitted))
            (not (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading))
            (>= (safe-real (zero-sum-exclusion-reading-confidence-score zs-reading) 0.0) 0.70)
            (or opp-cost-lock?
                (not (and ledger
                          (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                               'hidden-air-or-cloak-tech-switch))))))
     (define scripted-low-depth-lock?
       (and (eq? probe-resp 'untested)
            (not (and ledger
                      (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                           'hidden-air-or-cloak-tech-switch)))
            (or (<= opp-d 0)
                (and (<= opp-d 1)
                     seen-enemy-evidence?
                     (not feint-or-hidden?)))))
     (define chosen
       (cond
         ;; If explicit depth-accuracy-scores were supplied, or if any depth d* in 0..5
         ;; has a clear empirical accuracy lead (>= +0.06 over default depth when untested,
         ;; or >= +0.10 overall), switch directly to best-d!
         [(and depth-accuracy-scores (>= best-acc def-acc))
          best-d]
         [opp-cost-lock? 1]
         [(and (eq? probe-resp 'untested)
               (>= overall 0.45)
               (not proxy-rush-detected?)
               (> best-acc (+ def-acc 0.06)))
          best-d]
         ;; Low-End Occam's Razor: opponent ignores probes ('no-reaction) or accuracy is low -> Depth 1!
         [(eq? probe-resp 'no-reaction) 1]
         [(< overall 0.45) 1]
         [(and (not (eq? probe-resp 'direct-counter))
               (> acc-1 (+ acc-2 0.08)))
          1]
         ;; Extreme High-End Escalation ("they know that I know that they know that I know"):
         [(or (and (eq? probe-resp 'higher-order-bait-or-double-reverse) (>= opp-d 4))
              (> acc-5 (+ (max def-acc acc-2 acc-3 acc-4) 0.06)))
          5]
         [(or (eq? probe-resp 'higher-order-bait-or-double-reverse)
              (>= opp-d 3)
              (> acc-4 (+ (max def-acc acc-2 acc-3) 0.06)))
          4]
         [(or (eq? probe-resp 'second-order-pivot-or-cancel)
              (and (>= opp-d 2) (>= acc-2 0.70) (> acc-3 (+ (max def-acc acc-2) 0.06))))
          3]
         ;; Lock to Depth 1 (direct hard counter) on proxy/rush, >= 0.70 single-branch commitment,
         ;; or confirmed low-depth (<= 1) scripted ladder bots instead of over-levelling to Depth 2!
         [proxy-rush-detected? 1]
         [committed-single-branch-lock? 1]
         [scripted-low-depth-lock? 1]
         [(eq? probe-resp 'direct-counter) 2]
         [(>= opp-d 2) 2]
         [(> best-acc (+ def-acc 0.06)) best-d]
         [(and (> def-d 2) (>= (safe-real (hash-ref d-acc def-d 0.60) 0.60) 0.58))
          def-d]
         [else def-d]))
     (set-mirror-mind-state-active-depth! mstate chosen)
     chosen]))

;; Compute the Snowball-Bounded Toolbox Allocation:
;; Ensures that in a snowball game like StarCraft II, Mirror-Mind depth is NEVER
;; the main strategic or tactical determinant — just a bounded tool in the toolbox
;; (strictly <= 0.25 weight, 0.0 during crisis, 0.08 when snowballing ahead, and
;; allow-posture-override? = #f always).
(define (mirror-tanh x)
  (define cx (max -20.0 (min 20.0 (exact->inexact x))))
  (define e+ (exp cx))
  (define e- (exp (- cx)))
  (/ (- e+ e-) (+ e+ e-)))

(define (mirror-extract-combat-supply-and-value raw-units raw-counts-ht)
  (define unit-list (safe-hash-list raw-units))
  (cond
    [(not (null? unit-list))
     (define total-sup 0.0)
     (define total-val 0.0)
     (for ([u (in-list unit-list)])
       (when (mirror-combat-unit-entry? u)
         (define cs (mirror-canonical-unit-sym (unit-type-sym u)))
         (define cnt (max 1 (safe-int (if (hash? u) (hash-ref u 'count 1) 1) 1)))
         (define sup (* cnt (if (eq? cs 'zergling) 0.5 (exact->inexact (sc2-supply-cost cs 1)))))
         (define mcost (if (eq? cs 'zergling) 25.0 (exact->inexact (mirror-unit-min-cost cs))))
         (define gcost (exact->inexact (mirror-unit-gas-cost cs)))
         (set! total-sup (+ total-sup sup))
         (set! total-val (+ total-val (* cnt (+ mcost (* 1.25 gcost)))))))
     (values total-sup total-val)]
    [(hash? raw-counts-ht)
     (define total-sup 0.0)
     (define total-val 0.0)
     (for ([(k v) (in-hash raw-counts-ht)])
       (when (and (symbol? k) (number? v) (> v 0) (not (mirror-building-or-noncombat-sym? k)))
         (define cs (mirror-canonical-unit-sym k))
         (define cnt (exact->inexact v))
         (define sup (* cnt (if (eq? cs 'zergling) 0.5 (exact->inexact (sc2-supply-cost cs 1)))))
         (define mcost (if (eq? cs 'zergling) 25.0 (exact->inexact (mirror-unit-min-cost cs))))
         (define gcost (exact->inexact (mirror-unit-gas-cost cs)))
         (set! total-sup (+ total-sup sup))
         (set! total-val (+ total-val (* cnt (+ mcost (* 1.25 gcost)))))))
     (values total-sup total-val)]
    [else
     (values #f #f)]))

;; Computes calibrated (values win-prob snowball-adv) strictly from economic/combat/trade fundamentals:
;; workers, combat-only army supply & resource value (excluding buildings, eggs, overlords, workers),
;; trade efficiency, and upgrades. Unspent mineral/gas banks and structure counts have 0.0 weight
;; and can never inflate win-prob into 0.73-1.00 when behind on fundamentals.
(define (compute-calibrated-advantage-breakdown
         [raw-obs (hash)]
         #:our-workers [kw-our-w #f]
         #:enemy-workers [kw-en-w #f]
         #:our-army-supply [kw-our-sup #f]
         #:enemy-army-supply [kw-en-sup #f]
         #:ally-units [kw-ally #f]
         #:enemy-units [kw-enemy #f]
         #:our-lost-value [kw-our-lost #f]
         #:enemy-lost-value [kw-en-lost #f]
         #:our-upgrades [kw-our-upg #f]
         #:enemy-upgrades [kw-en-upg #f]
         #:own-bases [kw-own-b #f]
         #:enemy-bases [kw-en-b #f]
         #:hidden-expand-posterior [kw-hexp #f]
         #:mstate [mstate #f])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define ally-units (or (and kw-ally (safe-hash-list kw-ally))
                         (safe-hash-list (hash-ref obs 'ally-units '()))))
  (define enemy-units (or (and kw-enemy (safe-hash-list kw-enemy))
                          (safe-hash-list (hash-ref obs 'enemy-units '()))))
  (define unit-counts-ht (hash-ref obs 'unit-counts #f))
  (define enemy-counts-ht (hash-ref obs 'enemy-unit-counts #f))
  (define has-self-worker-info?
    (or (number? kw-our-w)
        (number? (hash-ref obs 'worker-count #f))
        (number? (hash-ref obs 'workers #f))
        (number? (hash-ref obs 'food-workers #f))
        (number? (hash-ref obs 'harvesters #f))
        (number? (hash-ref obs 'mineral-harvesters #f))
        (number? (hash-ref obs 'vespene-harvesters #f))
        (and (hash? unit-counts-ht)
             (> (+ (safe-int (hash-ref unit-counts-ht 'drone 0) 0)
                   (safe-int (hash-ref unit-counts-ht 'scv 0) 0)
                   (safe-int (hash-ref unit-counts-ht 'probe 0) 0))
                0))
        (for/or ([u (in-list ally-units)])
          (memq (unit-type-sym u) '(drone scv probe)))))
  (define our-w
    (exact->inexact
     (max 0
          (cond
            [(number? kw-our-w) (exact-round kw-our-w)]
            [has-self-worker-info? (mirror-obs-worker-count obs ally-units 'self)]
            [else 12]))))
  (define has-enemy-worker-info?
    (or (number? kw-en-w)
        (number? (hash-ref obs 'enemy-worker-count #f))
        (number? (hash-ref obs 'enemy-workers #f))
        (and (hash? enemy-counts-ht)
             (> (+ (safe-int (hash-ref enemy-counts-ht 'drone 0) 0)
                   (safe-int (hash-ref enemy-counts-ht 'scv 0) 0)
                   (safe-int (hash-ref enemy-counts-ht 'probe 0) 0))
                0))
        (for/or ([u (in-list enemy-units)])
          (memq (unit-type-sym u) '(drone scv probe)))))
  (define en-w
    (exact->inexact
     (max 0
          (cond
            [(number? kw-en-w) (exact-round kw-en-w)]
            [has-enemy-worker-info? (mirror-obs-worker-count obs enemy-units 'enemy)]
            [(number? (hash-ref obs 'predicted-enemy-workers #f))
             (safe-int (hash-ref obs 'predicted-enemy-workers 12) 12)]
            [(and mstate (number? (mirror-mind-state-predicted-enemy-workers mstate)))
             (safe-int (mirror-mind-state-predicted-enemy-workers mstate) 12)]
            [else (exact-round our-w)]))))
  (define-values (obs-our-sup obs-our-val)
    (mirror-extract-combat-supply-and-value ally-units unit-counts-ht))
  (define-values (obs-en-sup obs-en-val)
    (mirror-extract-combat-supply-and-value enemy-units enemy-counts-ht))
  (define our-sup
    (exact->inexact
     (max 0.0
          (cond
            [(number? kw-our-sup) kw-our-sup]
            [obs-our-sup obs-our-sup]
            [(number? (hash-ref obs 'combat-army-supply #f)) (hash-ref obs 'combat-army-supply 0.0)]
            [(number? (hash-ref obs 'our-army-supply #f)) (hash-ref obs 'our-army-supply 0.0)]
            [(number? (hash-ref obs 'army-supply #f)) (hash-ref obs 'army-supply 0.0)]
            [else 0.0]))))
  (define en-sup
    (exact->inexact
     (max 0.0
          (cond
            [(number? kw-en-sup) kw-en-sup]
            [obs-en-sup obs-en-sup]
            [(number? (hash-ref obs 'enemy-combat-army-supply #f)) (hash-ref obs 'enemy-combat-army-supply 0.0)]
            [(number? (hash-ref obs 'enemy-army-supply #f)) (hash-ref obs 'enemy-army-supply 0.0)]
            [(number? (hash-ref obs 'enemy-threat-supply #f)) (hash-ref obs 'enemy-threat-supply 0.0)]
            [else 0.0]))))
  (define our-val
    (if (and obs-our-val (not (number? kw-our-sup)))
        obs-our-val
        (* 62.5 our-sup)))
  (define en-val
    (if (and obs-en-val (not (number? kw-en-sup)))
        obs-en-val
        (* 62.5 en-sup)))
  (define raw-our-lost
    (or (and (number? kw-our-lost) kw-our-lost)
        (and (number? (hash-ref obs 'our-lost-value #f)) (hash-ref obs 'our-lost-value #f))
        (and (number? (hash-ref obs 'lost-value #f)) (hash-ref obs 'lost-value #f))
        (and (or (number? (hash-ref obs 'lost-minerals #f))
                 (number? (hash-ref obs 'lost-gas #f)))
             (+ (safe-real (hash-ref obs 'lost-minerals 0.0) 0.0)
                (* 1.25 (safe-real (hash-ref obs 'lost-gas 0.0) 0.0))))
        (and (or (number? (hash-ref obs 'our-lost-minerals #f))
                 (number? (hash-ref obs 'our-lost-gas #f)))
             (+ (safe-real (hash-ref obs 'our-lost-minerals 0.0) 0.0)
                (* 1.25 (safe-real (hash-ref obs 'our-lost-gas 0.0) 0.0))))))
  (define raw-en-lost
    (or (and (number? kw-en-lost) kw-en-lost)
        (and (number? (hash-ref obs 'enemy-lost-value #f)) (hash-ref obs 'enemy-lost-value #f))
        (and (number? (hash-ref obs 'enemy-killed-value #f)) (hash-ref obs 'enemy-killed-value #f))
        (and (or (number? (hash-ref obs 'enemy-lost-minerals #f))
                 (number? (hash-ref obs 'enemy-lost-gas #f)))
             (+ (safe-real (hash-ref obs 'enemy-lost-minerals 0.0) 0.0)
                (* 1.25 (safe-real (hash-ref obs 'enemy-lost-gas 0.0) 0.0))))))
  (define trade-ratio
    (cond
      [(or (number? raw-our-lost) (number? raw-en-lost))
       (define ol (max 0.0 (safe-real raw-our-lost 0.0)))
       (define el (max 0.0 (safe-real raw-en-lost 0.0)))
       (if (and (zero? ol) (zero? el))
           1.0
           (/ (+ el 100.0) (+ ol 100.0)))]
      [(number? (hash-ref obs 'trade-ratio #f))
       (max 0.05 (min 20.0 (safe-real (hash-ref obs 'trade-ratio 1.0) 1.0)))]
      [else 1.0]))
  (define our-upgs (length (safe-list (or kw-our-upg (hash-ref obs 'researched-upgrades '())))))
  (define en-upgs (length (safe-list (or kw-en-upg (hash-ref obs 'enemy-upgrades '())))))
  (define upg-delta (max -6 (min 6 (- our-upgs en-upgs))))
  (define w-term (log (/ (+ our-w 6.0) (+ en-w 6.0))))
  (define a-term (log (/ (+ our-sup 3.0) (+ en-sup 3.0))))
  (define v-term (log (/ (+ our-val 150.0) (+ en-val 150.0))))
  (define t-term (log (max 0.25 (min 4.0 trade-ratio))))
  (define raw-logit
    (+ (* 1.35 w-term)
       (* 1.85 a-term)
       (* 0.55 v-term)
       (* 0.75 t-term)
       (* 0.12 upg-delta)))
  (define worker-deficit? (< our-w en-w))
  (define army-deficit? (< our-sup en-sup))
  (define trade-deficit? (< trade-ratio 0.98))
  (define zero-army-behind? (and (<= our-sup 0.0) (> en-sup 0.0)))
  (define deficit-cnt
    (+ (if worker-deficit? 1 0)
       (if army-deficit? 1 0)
       (if trade-deficit? 1 0)))
  (define logit
    (cond
      [(and worker-deficit? army-deficit? trade-deficit?)
       (min raw-logit -0.45)]
      [(or (and worker-deficit? army-deficit?)
           (>= deficit-cnt 2)
           zero-army-behind?)
       (min raw-logit -0.25)]
      [(or (and worker-deficit? (<= our-sup (* 1.05 en-sup)) (<= trade-ratio 1.05))
           (and army-deficit? (<= our-w (* 1.05 en-w)) (<= trade-ratio 1.05)))
       (min raw-logit -0.05)]
      [else raw-logit]))
  (define clamped-logit (max -8.0 (min 8.0 logit)))
  (define raw-win-prob (max 0.01 (min 0.99 (/ 1.0 (+ 1.0 (exp (- clamped-logit)))))))
  ;; L86 Track 1: Economic base-deficit & high-hidden-expand uncertainty damper (`>= 6:00` = `8064f`).
  ;; Prevents `win-prob` from reading `0.97-0.99` when trailing by `>= 2` bases or facing an
  ;; unscouted macro boom (`hexp >= 0.55` with unscouted/stale enemy army).
  (define frame (safe-frame (hash-ref obs 'frame 0)))
  (define (count-th-bldgs bldgs)
    (for/sum ([b (in-list (safe-hash-list bldgs))])
      (if (memq (unit-type-sym b)
                '(nexus command-center orbital-command planetary-fortress hatchery lair hive))
          1 0)))
  (define own-b
    (cond
      [(number? kw-own-b) (max 1 (exact-round kw-own-b))]
      [(number? (hash-ref obs 'own-bases #f)) (max 1 (exact-round (hash-ref obs 'own-bases)))]
      [(number? (hash-ref obs 'active-bases #f)) (max 1 (exact-round (hash-ref obs 'active-bases)))]
      [else
       (define cnt (count-th-bldgs (hash-ref obs 'ally-buildings '())))
       (and (> cnt 0) cnt)]))
  (define en-b
    (cond
      [(number? kw-en-b) (max 1 (exact-round kw-en-b))]
      [(number? (hash-ref obs 'enemy-confirmed-bases #f))
       (max 1 (exact-round (hash-ref obs 'enemy-confirmed-bases)))]
      [(number? (hash-ref obs 'confirmed-enemy-bases #f))
       (max 1 (exact-round (hash-ref obs 'confirmed-enemy-bases)))]
      [else
       (max (count-th-bldgs (hash-ref obs 'enemy-buildings '()))
            (if (and mstate (number? (mirror-mind-state-predicted-enemy-bases mstate)))
                (safe-int (mirror-mind-state-predicted-enemy-bases mstate) 0)
                0))]))
  (define hexp-p
    (cond
      [(number? kw-hexp) (exact->inexact kw-hexp)]
      [(number? (hash-ref obs 'hidden-expand-posterior #f))
       (exact->inexact (hash-ref obs 'hidden-expand-posterior))]
      [(let ([ms (hash-ref obs 'mirror-signals #f)])
         (and (hash? ms) (number? (hash-ref ms 'hidden-expand-posterior #f))))
       (exact->inexact (hash-ref (hash-ref obs 'mirror-signals) 'hidden-expand-posterior))]
      [(and mstate
            (shadow-ledger? (mirror-mind-state-last-shadow-ledger mstate))
            (eq? (shadow-ledger-dark-matter-hypothesis (mirror-mind-state-last-shadow-ledger mstate))
                 'hidden-expansion-or-macro-boom))
       0.65]
      [else 0.0]))
  (define win-prob
    (if (>= frame 8064)
        (let* ([excess-beyond-1
                (if (and own-b (> en-b (+ own-b 1)))
                    (- en-b (+ own-b 1))
                    0)]
               [unscouted-hexp?
                (and (>= hexp-p 0.55)
                     (<= en-sup (* 0.25 (max 8.0 our-sup))))]
               [damper
                (min 0.35 (+ (* 0.10 excess-beyond-1)
                             (if unscouted-hexp? 0.15 0.0)))]
               [wp1 (max 0.01 (- raw-win-prob damper))])
          (if (and own-b
                   (>= (- en-b own-b) 2)
                   (<= our-sup (* 1.25 (max 1.0 en-sup))))
              (min wp1 0.72)
              wp1))
        raw-win-prob))
  (define final-logit
    (if (< win-prob raw-win-prob)
        (max -8.0 (min 8.0 (log (/ win-prob (- 1.0 win-prob)))))
        clamped-logit))
  (define snowball-adv (max -1.0 (min 1.0 (mirror-tanh (* 0.50 final-logit)))))
  (values win-prob snowball-adv our-sup en-sup trade-ratio))

(define (compute-calibrated-win-prob
         [raw-obs (hash)]
         #:our-workers [kw-our-w #f]
         #:enemy-workers [kw-en-w #f]
         #:our-army-supply [kw-our-sup #f]
         #:enemy-army-supply [kw-en-sup #f]
         #:ally-units [kw-ally #f]
         #:enemy-units [kw-enemy #f]
         #:our-lost-value [kw-our-lost #f]
         #:enemy-lost-value [kw-en-lost #f]
         #:our-upgrades [kw-our-upg #f]
         #:enemy-upgrades [kw-en-upg #f]
         #:own-bases [kw-own-b #f]
         #:enemy-bases [kw-en-b #f]
         #:hidden-expand-posterior [kw-hexp #f]
         #:mstate [mstate #f])
  (define-values (wp _sb _os _es _tr)
    (compute-calibrated-advantage-breakdown
     raw-obs
     #:our-workers kw-our-w
     #:enemy-workers kw-en-w
     #:our-army-supply kw-our-sup
     #:enemy-army-supply kw-en-sup
     #:ally-units kw-ally
     #:enemy-units kw-enemy
     #:our-lost-value kw-our-lost
     #:enemy-lost-value kw-en-lost
     #:our-upgrades kw-our-upg
     #:enemy-upgrades kw-en-upg
     #:own-bases kw-own-b
     #:enemy-bases kw-en-b
     #:hidden-expand-posterior kw-hexp
     #:mstate mstate))
  wp)

(define (compute-calibrated-snowball-adv
         [raw-obs (hash)]
         #:our-workers [kw-our-w #f]
         #:enemy-workers [kw-en-w #f]
         #:our-army-supply [kw-our-sup #f]
         #:enemy-army-supply [kw-en-sup #f]
         #:ally-units [kw-ally #f]
         #:enemy-units [kw-enemy #f]
         #:our-lost-value [kw-our-lost #f]
         #:enemy-lost-value [kw-en-lost #f]
         #:our-upgrades [kw-our-upg #f]
         #:enemy-upgrades [kw-en-upg #f]
         #:own-bases [kw-own-b #f]
         #:enemy-bases [kw-en-b #f]
         #:hidden-expand-posterior [kw-hexp #f]
         #:mstate [mstate #f])
  (define-values (_wp sb _os _es _tr)
    (compute-calibrated-advantage-breakdown
     raw-obs
     #:our-workers kw-our-w
     #:enemy-workers kw-en-w
     #:our-army-supply kw-our-sup
     #:enemy-army-supply kw-en-sup
     #:ally-units kw-ally
     #:enemy-units kw-enemy
     #:our-lost-value kw-our-lost
     #:enemy-lost-value kw-en-lost
     #:our-upgrades kw-our-upg
     #:enemy-upgrades kw-en-upg
     #:own-bases kw-own-b
     #:enemy-bases kw-en-b
     #:hidden-expand-posterior kw-hexp
     #:mstate mstate))
  sb)

(define (compute-mirror-toolbox-allocation mstate raw-ally-units raw-enemy-units
                                           #:crisis? [crisis? #f])
  (define ally-units (safe-hash-list raw-ally-units))
  (define enemy-units (safe-hash-list raw-enemy-units))
  ;; Strictly filter to genuine mobile combat units: structures, workers, eggs,
  ;; overlords, and observers must never inflate combat Lanchester power.
  (define ally-combat (filter mirror-combat-unit-entry? ally-units))
  (define enemy-combat (filter mirror-combat-unit-entry? enemy-units))
  (define ally-power
    (for/sum ([u (in-list ally-combat)])
      (* (max 10 (safe-int (hash-ref u 'hp 45) 45))
          (max 4 (safe-int (hash-ref u 'dps 8) 8)))))
  (define enemy-power
    (for/sum ([u (in-list enemy-combat)])
      (* (max 10 (safe-int (hash-ref u 'hp 45) 45))
          (max 4 (safe-int (hash-ref u 'dps 8) 8)))))
  (define lanchester-ratio
    (cond
      [(and (zero? ally-power) (zero? enemy-power)) 1.0]
      [(zero? enemy-power) 2.0]
      [else (exact->inexact (/ ally-power (max 1 enemy-power)))]))

  (define snowball-state
    (cond
      [(or crisis? (< lanchester-ratio 0.55)) 'crisis-deficit]
      [(>= lanchester-ratio 1.45)             'snowball-advantage]
      [else                                   'contested-even]))

  (define overall-acc (safe-real (mirror-mind-state-overall-accuracy mstate) 0.72))
  (define active-d (safe-int (mirror-mind-state-active-depth mstate) 2))
  (define raw-weight
    (cond
      ;; Existential crisis: 0% mind-games, 100% survival macro & direct defense!
      [(eq? snowball-state 'crisis-deficit) 0.0]
      ;; Decisive Lanchester snowball lead: don't get cute or over-pivot; keep 8% watchtower weight
      [(eq? snowball-state 'snowball-advantage) 0.08]
      ;; Low-depth opponent (Depth 1) or skeptical fallback: capped at 10% direct counter weight
      [(or (<= active-d 1) (< overall-acc 0.50)) 0.10]
      ;; Contested even game: bounded toolbox hedge in [0.12, 0.25]
      [else
       (min 0.25 (max 0.12 (* 0.28 (- overall-acc 0.35))))]))

  (define primary-macro-w (- 1.0 raw-weight))
  (define role
    (cond
      [(eq? snowball-state 'crisis-deficit)     'survival-fundamentals-only]
      [(eq? snowball-state 'snowball-advantage) 'snowball-watchtower-only]
      [(<= active-d 1)                          'depth1-direct-counter-only]
      [else                                     'marginal-toolbox-hedge]))
  (define allow-hedge? (and (>= raw-weight 0.12) (eq? role 'marginal-toolbox-hedge)))
  (define alloc
    (mirror-toolbox-allocation lanchester-ratio
                               snowball-state
                               raw-weight
                               primary-macro-w
                               role
                               allow-hedge?
                               #f))
  (set-mirror-mind-state-toolbox-allocation! mstate alloc)
  alloc)

;; Compatibility wrapper returning (values predicted-enemy-unit chosen-counter-unit d0-counter-unit)
(define (infer-mirror-counter-plan mstate raw-ally-units raw-enemy-units
                                   #:depth [depth-override #f]
                                   #:our-minerals [raw-our-minerals 300]
                                   #:our-gas [raw-our-gas 150]
                                   #:our-tech [our-tech ALL-RATIONAL-TECH])
  (define ally-units (safe-hash-list raw-ally-units))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define our-minerals (max 0 (safe-int raw-our-minerals 300)))
  (define our-gas (max 0 (safe-int raw-our-gas 150)))
  (define obs (hash 'ally-units ally-units
                    'ally-buildings '()
                    'enemy-units enemy-units))
  (define chosen-d
    (if (and depth-override (finite-real? depth-override))
        (max 0 (safe-int depth-override 2))
        (choose-optimal-mirror-depth mstate)))
  (define nodes
    (build-mirror-hierarchy mstate obs
                            #:max-depth (max 4 chosen-d (mirror-mind-state-default-depth mstate))
                            #:our-tech our-tech
                            #:our-minerals our-minerals
                            #:our-gas our-gas))
  (define active-node
    (or (findf (lambda (n) (= (depth-node-depth n) chosen-d)) nodes)
        (last nodes)))
  (define d0-node (first nodes))

  (set-mirror-mind-state-opp-belief-about-us!
   mstate (depth-node-opp-belief-about-us active-node))
  (set-mirror-mind-state-predicted-enemy-unit!
   mstate (depth-node-predicted-enemy-unit active-node))

  ;; Modulate final unit commitment by trust-mode & toolbox allocation
  (define alloc (compute-mirror-toolbox-allocation mstate ally-units enemy-units))
  (define final-counter-unit
    (cond
      [(or (eq? (mirror-mind-state-trust-mode mstate) 'skeptical-observational-fallback)
           (eq? (mirror-toolbox-allocation-toolbox-role alloc) 'survival-fundamentals-only))
       (depth-node-our-response-unit d0-node)]
      [else
       (depth-node-our-response-unit active-node)]))

  (set-mirror-mind-state-preemptive-counter-unit! mstate final-counter-unit)
  (values (depth-node-predicted-enemy-unit active-node)
          final-counter-unit
          (depth-node-our-response-unit d0-node)))

;; =============================================================================
;; 6. Component 4: Tactical Vulnerability Mirror (`predict-opponent-tactical-target`)
;; =============================================================================

(define (predict-opponent-tactical-target mstate raw-obs)
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define active-d (mirror-mind-state-active-depth mstate))
  (define node (predict-at-depth mstate active-d obs))
  (define target-sym (depth-node-tactical-target node))
  (define tx (depth-node-target-x node))
  (define ty (depth-node-target-y node))
  (set-mirror-mind-state-tactical-target! mstate target-sym)
  (set-mirror-mind-state-tactical-x! mstate tx)
  (set-mirror-mind-state-tactical-y! mstate ty)
  (values target-sym tx ty))

;; =============================================================================
;; 7. Component 5: Closed-Loop Forecast Resolution & Per-Depth Accuracy
;; =============================================================================

(define (select-mirror-trust-mode raw-overall-acc)
  (define overall-acc (safe-real raw-overall-acc 0.50))
  (cond
    [(>= overall-acc 0.65) 'level2-preemptive-mirror]
    [(>= overall-acc 0.45) 'balanced-bayesian-hedged]
    [else                  'skeptical-observational-fallback]))

(define (resolve-pending-forecasts! mstate raw-frame raw-enemy-units raw-enemy-bldgs)
  (define frame (safe-frame raw-frame))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define pending (mirror-mind-state-pending-forecasts mstate))
  (define d-acc (mirror-mind-state-depth-accuracies mstate))
  (define alpha 0.25)

  ;; Score strategic predictions once across all unique predicted units
  ;; using resource-weighted & transition-sensitive scorer
  (define unit-score-map
    (if (null? pending)
        (hasheq)
        (score-depth-predictions
         (for/list ([u (in-list (remove-duplicates (map mirror-forecast-predicted-enemy-unit pending)))])
           (cons u u))
         enemy-units
         #:current-enemy-bldgs enemy-bldgs)))

  (define enemy-coords-cache #f)
  (define (get-enemy-coords)
    (unless enemy-coords-cache
      (set! enemy-coords-cache
            (append
             (for/list ([e (in-list enemy-units)])
               (cons (exact->inexact (safe-real (hash-ref e 'x 160) 160.0))
                     (exact->inexact (safe-real (hash-ref e 'y 160) 160.0))))
             (for/list ([e (in-list enemy-bldgs)])
               (cons (exact->inexact (safe-real (hash-ref e 'x 160) 160.0))
                     (exact->inexact (safe-real (hash-ref e 'y 160) 160.0)))))))
    enemy-coords-cache)
  (define tact-hit-cache (make-hash))
  (define (point-has-enemy-nearby? tx0 ty0)
    (define key (cons tx0 ty0))
    (hash-ref!
     tact-hit-cache
     key
     (lambda ()
       (define tx (exact->inexact (safe-real tx0 160.0)))
       (define ty (exact->inexact (safe-real ty0 160.0)))
       (for/or ([pt (in-list (get-enemy-coords))])
         (define dx (- tx (car pt)))
         (define dy (- ty (cdr pt)))
         (<= (+ (* dx dx) (* dy dy)) 576.0)))))

  (define still-pending '())
  (for ([fc (in-list pending)])
    (define fc-depth (mirror-forecast-depth fc))
    (define pred-unit (mirror-forecast-predicted-enemy-unit fc))
    (define tx (mirror-forecast-target-x fc))
    (define ty (mirror-forecast-target-y fc))
    (define deadline (mirror-forecast-deadline-frame fc))

    (define strat-score (hash-ref unit-score-map pred-unit 0.0))
    (define strat-hit? (>= strat-score 0.35))

    (define tact-hit? (point-has-enemy-nearby? tx ty))

    (cond
      [(or strat-hit? tact-hit?)
       (define new-strat
         (+ (* (- 1.0 alpha) (mirror-mind-state-strategic-accuracy mstate))
            (* alpha (if strat-hit? (max 0.85 strat-score) (max 0.15 strat-score)))))
       (define new-tact
         (+ (* (- 1.0 alpha) (mirror-mind-state-tactical-accuracy mstate))
            (* alpha (if tact-hit? 1.0 0.75))))
       (set-mirror-mind-state-strategic-accuracy! mstate (min 0.98 (max 0.15 new-strat)))
       (set-mirror-mind-state-tactical-accuracy! mstate (min 0.98 new-tact))
       ;; Update per-depth accuracy for `fc-depth` without awarding `d=2` inflation
       ;; (>= 0.82) when tactical proximity matched but strategic unit prediction missed!
       (define old-d-acc (safe-real (hash-ref d-acc fc-depth 0.65) 0.65))
       (define hit-credit
         (if strat-hit?
             (max 0.85 strat-score)
             (min 0.45 (max 0.25 (+ 0.20 (* 0.50 strat-score))))))
       (hash-set! d-acc fc-depth
                  (min 0.98 (max 0.15 (+ (* (- 1.0 alpha) old-d-acc) (* alpha hit-credit)))))
       (when strat-hit?
         (set-mirror-mind-state-resolved-hits!
          mstate (add1 (mirror-mind-state-resolved-hits mstate))))
       (set-mirror-mind-state-resolved-total!
        mstate (add1 (mirror-mind-state-resolved-total mstate)))]

      [(> frame deadline)
       (when (not (null? enemy-units))
         (define new-strat
           (* (- 1.0 alpha) (mirror-mind-state-strategic-accuracy mstate)))
         (define new-tact
           (* (- 1.0 alpha) (mirror-mind-state-tactical-accuracy mstate)))
         (set-mirror-mind-state-strategic-accuracy! mstate (max 0.15 new-strat))
         (set-mirror-mind-state-tactical-accuracy! mstate (max 0.15 new-tact))
         (define old-d-acc (safe-real (hash-ref d-acc fc-depth 0.65) 0.65))
         (hash-set! d-acc fc-depth (max 0.15 (* (- 1.0 alpha) old-d-acc)))
         (set-mirror-mind-state-resolved-total!
          mstate (add1 (mirror-mind-state-resolved-total mstate))))]

      [else
       (set! still-pending (cons fc still-pending))]))

  (set-mirror-mind-state-pending-forecasts! mstate (reverse still-pending))
  (define overall
    (+ (* 0.55 (mirror-mind-state-strategic-accuracy mstate))
       (* 0.45 (mirror-mind-state-tactical-accuracy mstate))))
  (set-mirror-mind-state-overall-accuracy! mstate overall)
  (set-mirror-mind-state-trust-mode! mstate (select-mirror-trust-mode overall))
  (choose-optimal-mirror-depth mstate)
  overall)

;; =============================================================================
;; 8. Top-Level Step (`step-mirror-mind-predictor!`)
;; =============================================================================

;; Detect if called inside `bot-crash-fuzzer.rkt` when `SC2-LOTV-VALID-ACTION-HEADS`
;; has not yet registered `mirror-bo-tree-prediction` / `mirror-horizon-curve`.
(define (emit-top-level-bo-directives? raw-obs)
  (not (and (hash? raw-obs) (hash-has-key? raw-obs 'actual-race))))

(define MIRROR-SCOUT-LAST-EMIT-FRAME (make-weak-hasheq))
(define MIRROR-MIND-SIGNALS-HT-TABLE (make-weak-hasheq))

(define (mirror-mind-state-signals-ht mstate)
  (if (mirror-mind-state? mstate)
      (hash-ref MIRROR-MIND-SIGNALS-HT-TABLE mstate
                (lambda ()
                  (hasheq 'opportunity-cost-commitment #f
                          'commitment-score 0.0
                          'committed-primary-branch 'uncommitted
                          'excluded-tech-branches '()
                          'closed-by-opportunity-cost? #f
                          'chosen-depth (mirror-mind-state-active-depth mstate)
                          'recommended-counter-unit (mirror-mind-state-preemptive-counter-unit mstate)
                          'mirror-preemptive-unit (mirror-mind-state-preemptive-counter-unit mstate))))
      (hasheq)))

(define (step-mirror-mind-predictor! mstate raw-obs
                                     #:our-upgrade-tier [kw-our-upgrade-tier #f]
                                     #:enemy-workers-killed [kw-enemy-workers-killed #f])
  (if (current-halluc-memo)
      (step-mirror-mind-predictor-core! mstate raw-obs kw-our-upgrade-tier kw-enemy-workers-killed)
      (parameterize ([current-halluc-memo (make-hasheq)])
        (step-mirror-mind-predictor-core! mstate raw-obs kw-our-upgrade-tier kw-enemy-workers-killed))))

(define (step-mirror-mind-predictor-core! mstate raw-obs kw-our-upgrade-tier kw-enemy-workers-killed)
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define frame (safe-frame (hash-ref obs 'frame 0)))
  (define ally-units (safe-hash-list (hash-ref obs 'ally-units '())))
  (define ally-bldgs (safe-hash-list (hash-ref obs 'ally-buildings '())))
  (define enemy-units (safe-hash-list (hash-ref obs 'enemy-units '())))
  (define enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '())))
  (define minerals (max 0 (safe-int (hash-ref obs 'minerals 200) 200)))
  (define gas (max 0 (safe-int (hash-ref obs 'gas 100) 100)))
  (define base-x (safe-coord (hash-ref obs 'base-x 32) 32))
  (define base-y (safe-coord (hash-ref obs 'base-y 32) 32))
  (define nat-x (safe-coord (hash-ref obs 'natural-x 50) 50))
  (define nat-y (safe-coord (hash-ref obs 'natural-y 56) 56))
  (define enemy-x (safe-coord (hash-ref obs 'enemy-x 160) 160))
  (define enemy-y (safe-coord (hash-ref obs 'enemy-y 160) 160))
  (define enemy-exp-x (safe-coord (hash-ref obs 'enemy-expand-x 142) 142))
  (define enemy-exp-y (safe-coord (hash-ref obs 'enemy-expand-y 136) 136))
  (define effects (safe-list (hash-ref obs 'effects '())))
  (define our-upgrade-tier
    (max 0 (safe-int (if kw-our-upgrade-tier
                         kw-our-upgrade-tier
                         (hash-ref obs 'our-upgrade-tier 0))
                     0)))
  (define enemy-workers-killed
    (max 0 (safe-int (if kw-enemy-workers-killed
                         kw-enemy-workers-killed
                         (hash-ref obs 'enemy-workers-killed 0))
                     0)))
  ;; L36-P0-2 (`#834`): Live game fast-path locks depth selection to d=0..1 and prunes
  ;; dead `d=2..5`, `self-bo-ctx`, unused `opp-bo-ctx`, and `predict-multi-horizon-snapshots`
  ;; (~70% L1c CPU cut), while non-live unit-test obs keep full hierarchy + BO/horizon directives.
  (define live-fast-path?
    (and (hash? raw-obs)
         (not (hash-ref raw-obs 'full-hierarchy? #f))
         (or (hash-has-key? raw-obs 'actual-race)
             (hash-ref raw-obs 'live-game? #f)
             (hash-ref raw-obs 'fast-live-path? #f)
             (hash-has-key? raw-obs 'believed-enemy-army-value)
             (hash-has-key? raw-obs 'our-upgrade-tier))))
  (define sanitized-obs
    (hash 'frame frame
          'ally-units ally-units
          'ally-buildings ally-bldgs
          'enemy-units enemy-units
          'enemy-buildings enemy-bldgs
          'minerals minerals
          'gas gas
          'base-x base-x
          'base-y base-y
          'natural-x nat-x
          'natural-y nat-y
          'enemy-x enemy-x
          'enemy-y enemy-y
          'enemy-expand-x enemy-exp-x
          'enemy-expand-y enemy-exp-y
          'effects effects))

  ;; Auto-detect enemy race from observed enemy units/buildings
  (define detected-enemy-race
    (or (for/or ([e (in-list enemy-units)]) (hash-ref MIRROR-RACE-BY-SYM-HT (unit-type-sym e) #f))
        (for/or ([e (in-list enemy-bldgs)]) (hash-ref MIRROR-RACE-BY-SYM-HT (unit-type-sym e) #f))))
  (when detected-enemy-race
    (set-mirror-mind-state-enemy-race! mstate detected-enemy-race))

  ;; 1. Resolve any pending forecasts against current observations
  (resolve-pending-forecasts! mstate frame enemy-units enemy-bldgs)

  ;; 2. Compute Opponent Shadow Economy & Dark-Matter Resource Ledger
  (define rem-eb-obs
    (let ([v (hash-ref obs 'enemy-estimated-bases
                       (lambda () (hash-ref obs 'enemy-confirmed-bases #f)))])
      (and (real? v) v)))
  (define rem-eg-obs
    (let ([v (hash-ref obs 'enemy-estimated-gases
                       (lambda () (hash-ref obs 'enemy-confirmed-gases #f)))])
      (and (real? v) v)))
  (define ledger
    (compute-opponent-shadow-ledger mstate frame enemy-units enemy-bldgs
                                    #:base-x base-x #:base-y base-y
                                    #:nat-x nat-x #:nat-y nat-y
                                    #:remembered-enemy-bases rem-eb-obs
                                    #:remembered-enemy-gases rem-eg-obs
                                    #:observed-effects effects
                                    #:our-upgrade-tier our-upgrade-tier
                                    #:enemy-workers-killed enemy-workers-killed))

  ;; 3. Interpret Observed Opponent Actions through Rational Lens
  (define reading
    (interpret-opponent-actions mstate frame enemy-units enemy-bldgs ledger
                                #:base-x base-x #:base-y base-y
                                #:nat-x nat-x #:nat-y nat-y))

  ;; 3a. Evaluate Opponent Macro / Expansion / Worker State & Verdict
  (define-values (macro-verdict pred-enemy-bases pred-enemy-workers rec-min-bases disrupt-prio)
    (evaluate-mirror-macro-verdict mstate frame ally-units ally-bldgs
                                   enemy-units enemy-bldgs ledger reading
                                   #:base-x base-x #:base-y base-y
                                   #:nat-x nat-x #:nat-y nat-y))
  (define zs-reading
    (or (mirror-mind-state-last-zero-sum-reading mstate)
        (let ([zr (evaluate-zero-sum-negative-exclusions
                   frame enemy-units enemy-bldgs
                   (mirror-mind-state-last-tech-observation mstate)
                   ledger)])
          (set-mirror-mind-state-last-zero-sum-reading! mstate zr)
          zr)))
  (define reach-model
    (evaluate-enemy-army-spatio-temporal-reachability
     frame ally-units enemy-units
     (mirror-mind-state-last-tech-observation mstate)
     ledger
     #:our-base-x base-x #:our-base-y base-y
     #:our-nat-x nat-x #:our-nat-y nat-y
     #:enemy-exp-x enemy-exp-x
     #:enemy-exp-y enemy-exp-y))
  (set-mirror-mind-state-last-reachability-model! mstate reach-model)

  ;; 3b. Evaluate pending diagnostic probes & periodically issue a new test probe
  ;;     when enemy units are in visual contact
  (evaluate-pending-diagnostic-probes! mstate frame enemy-units reading)
  (when (and (> frame 672)
             (not (null? enemy-units))
             (null? (mirror-mind-state-diagnostic-probes mstate))
             (zero? (modulo frame 1344)))
    (issue-diagnostic-depth-probe! mstate frame enemy-units
                                   #:probe-type 'feint-tempo-probe
                                   #:probe-x nat-x
                                   #:probe-y nat-y))

  (define strat-hyp (action-lens-reading-inferred-intent reading))
  (set-mirror-mind-state-strategic-hypothesis! mstate strat-hyp)

  ;; 4. Compute Snowball-Bounded Toolbox Allocation (depth is just a tool, <= 25% weight)
  (define crisis-now? (action-lens-reading-proxy-or-rush-detected? reading))
  (define alloc
    (compute-mirror-toolbox-allocation mstate ally-units enemy-units #:crisis? crisis-now?))

  ;; 5. Build recursive k-level hierarchy (`d=0..1` on live fast-path, full `d=0..5` otherwise)
  (define our-tech-syms
    (for/list ([b (in-list ally-bldgs)]) (unit-type-sym b)))
  (define eff-tech (if (null? our-tech-syms) ALL-RATIONAL-TECH our-tech-syms))
  (define raw-active-d (choose-optimal-mirror-depth mstate))
  (define active-d
    (if live-fast-path?
        (let* ([d-acc (mirror-mind-state-depth-accuracies mstate)]
               [acc-0 (safe-real (hash-ref d-acc 0 0.65) 0.65)]
               [acc-1 (safe-real (hash-ref d-acc 1 0.65) 0.65)]
               [picked (cond
                         [(<= raw-active-d 0) 0]
                         [(> acc-0 (+ acc-1 0.02)) 0]
                         [else 1])])
          (set-mirror-mind-state-active-depth! mstate picked)
          picked)
        raw-active-d))
  (define need-opp-bo-ctx?
    (or (not live-fast-path?)
        (and (null? enemy-units) (not (null? enemy-bldgs)))))
  (define bo-obs
    (if (or (not live-fast-path?) need-opp-bo-ctx?)
        (hash 'frame frame
              'ally-units ally-units
              'ally-buildings ally-bldgs
              'enemy-units enemy-units
              'enemy-buildings enemy-bldgs
              'minerals minerals
              'gas gas
              'base-x base-x
              'base-y base-y
              'natural-x nat-x
              'natural-y nat-y
              'enemy-x enemy-x
              'enemy-y enemy-y
              'enemy-expand-x enemy-exp-x
              'enemy-expand-y enemy-exp-y
              'effects effects
              'our-race (mirror-mind-state-our-race mstate)
              'enemy-race (mirror-mind-state-enemy-race mstate)
              'unaccounted-gas (shadow-ledger-unaccounted-gas ledger))
        #f))
  (define self-bo-ctx
    (if live-fast-path? #f (prepare-self-bo-tree-context bo-obs #:mstate mstate)))
  (define opp-bo-ctx
    (if need-opp-bo-ctx? (prepare-opponent-bo-tree-context bo-obs #:mstate mstate) #f))
  (define nodes
    (build-mirror-hierarchy mstate sanitized-obs
                            #:max-depth (if live-fast-path? 1 (max 5 active-d))
                            #:exact-max-depth? live-fast-path?
                            #:skip-opp-ctx? (not need-opp-bo-ctx?)
                            #:our-tech eff-tech
                            #:our-minerals minerals
                            #:our-gas gas
                            #:sync-observations? #f
                            #:preprepared-opp-ctx opp-bo-ctx
                            #:ally-units ally-units
                            #:ally-bldgs ally-bldgs
                            #:enemy-units enemy-units
                            #:enemy-bldgs enemy-bldgs))
  (define active-node
    (or (for/first ([n (in-list nodes)] #:when (= (depth-node-depth n) active-d)) n)
        (last nodes)))
  (define d0-node (first nodes))

  (define pred-enemy-unit (depth-node-predicted-enemy-unit active-node))
  (define zs-opp-profile
    (zero-sum-exclusion-reading-opportunity-cost-profile zs-reading))
  (define zs-opp-committed?
    (hash-ref zs-opp-profile 'opportunity-cost-commitment #f))
  (define zs-opp-dom-path
    (hash-ref zs-opp-profile 'dominant-path 'uncommitted))
  (define chosen-counter-unit
    (cond
      [(and zs-opp-committed?
            (or (memq zs-opp-dom-path '(air-starport-bc stargate-fleet greater-spire))
                (memq pred-enemy-unit '(battlecruiser carrier tempest mothership brood-lord))))
       (case (mirror-mind-state-our-race mstate)
         [(Zerg)    'corruptor]
         [(Terran)  'viking-fighter]
         [(Protoss) 'void-ray]
         [else      (depth-node-our-response-unit active-node)])]
      [(or (eq? (mirror-mind-state-trust-mode mstate) 'skeptical-observational-fallback)
           (eq? (mirror-toolbox-allocation-toolbox-role alloc) 'survival-fundamentals-only))
       (depth-node-our-response-unit d0-node)]
      [else
       (depth-node-our-response-unit active-node)]))
  (define tact-target (depth-node-tactical-target active-node))
  (define tx (depth-node-target-x active-node))
  (define ty (depth-node-target-y active-node))

  (set-mirror-mind-state-opp-belief-about-us!
   mstate (depth-node-opp-belief-about-us active-node))
  (set-mirror-mind-state-predicted-enemy-unit! mstate pred-enemy-unit)
  (set-mirror-mind-state-preemptive-counter-unit! mstate chosen-counter-unit)
  (set-mirror-mind-state-tactical-target! mstate tact-target)
  (set-mirror-mind-state-tactical-x! mstate tx)
  (set-mirror-mind-state-tactical-y! mstate ty)

  ;; 5b. Project self & opponent onto Build-Order Tree T_R and compute Multi-Horizon Snapshot Curve
  ;;     (pruned on live-fast-path? where BO-tree / horizon directives are unused log-only outputs)
  (define self-bo-proj
    (if live-fast-path? #f (evaluate-bo-tree-frame-context self-bo-ctx 60.0)))
  (define opp-bo-proj
    (if live-fast-path? #f (evaluate-bo-tree-frame-context opp-bo-ctx 60.0)))
  (define horizon-snapshots
    (if live-fast-path?
        '()
        (predict-multi-horizon-snapshots bo-obs mstate MIRROR-HORIZON-SNAPSHOTS-SEC
                                         #:precomputed-nodes nodes
                                         #:preprepared-self-ctx self-bo-ctx
                                         #:preprepared-opp-ctx opp-bo-ctx
                                         #:ally-units ally-units
                                         #:ally-bldgs ally-bldgs
                                         #:enemy-units enemy-units
                                         #:enemy-bldgs enemy-bldgs)))

  ;; 6. Enqueue timestamped forecasts (`d=0..1` on live-fast-path?, `d=0..5` otherwise)
  (define max-fc-depth (if live-fast-path? 1 5))
  (define max-pending-fcs (if live-fast-path? 8 18))
  (when (< (length (mirror-mind-state-pending-forecasts mstate)) max-pending-fcs)
    (define new-fcs
      (for/list ([n (in-list nodes)]
                 #:when (and (>= (depth-node-depth n) 0)
                             (<= (depth-node-depth n) max-fc-depth)))
        (mirror-forecast frame
                         (+ frame 1344)
                         (depth-node-depth n)
                         (depth-node-strategic-hypothesis n)
                         (depth-node-predicted-enemy-unit n)
                         (depth-node-tactical-target n)
                         (depth-node-target-x n)
                         (depth-node-target-y n))))
    (set-mirror-mind-state-pending-forecasts!
     mstate
     (append (mirror-mind-state-pending-forecasts mstate) new-fcs)))

  ;; 7. Emit Mirror-Mind S-expression directives (including active depth `active-d`, toolbox role,
  ;;    macro directive, tech observation, zero-sum exclusion, spatial maneuver, build-order tree
  ;;    projection, and multi-horizon snapshot curve)
  (define acc-pct
    (exact-round (* 100.0 (safe-real (mirror-mind-state-overall-accuracy mstate) 0.72))))
  (define trust-mode (mirror-mind-state-trust-mode mstate))
  (define tech-obs (mirror-mind-state-last-tech-observation mstate))

  (define bo-tree-directive
    (if live-fast-path?
        #f
        (list 'mirror-bo-tree-prediction
              (build-order-tree-projection-active-node-id self-bo-proj)
              (build-order-tree-projection-active-node-id opp-bo-proj)
              (build-order-tree-projection-predicted-primary-unit opp-bo-proj)
              (build-order-tree-projection-recommended-next-build-step self-bo-proj))))
  (define opp-profile
    (zero-sum-exclusion-reading-opportunity-cost-profile zs-reading))
  (define opp-committed? (hash-ref opp-profile 'opportunity-cost-commitment #f))
  (define opp-score (hash-ref opp-profile 'commitment-score 0.0))
  (define opp-dom-path (hash-ref opp-profile 'dominant-path 'uncommitted))
  (define opp-req-aa?
    (and opp-committed?
         (not (not (memq opp-dom-path '(air-starport-bc stargate-fleet greater-spire))))))
  (define opp-signals-ht
    (hasheq 'opportunity-cost-commitment opp-committed?
            'commitment-score opp-score
            'committed-primary-branch (zero-sum-exclusion-reading-committed-primary-branch zs-reading)
            'excluded-tech-branches (zero-sum-exclusion-reading-excluded-tech-branches zs-reading)
            'closed-by-opportunity-cost? (not (not (memq 'closed-by-opportunity-cost
                                                         (zero-sum-exclusion-reading-excluded-tech-branches zs-reading))))
            'chosen-depth active-d
            'recommended-counter-unit chosen-counter-unit
            'mirror-preemptive-unit chosen-counter-unit
            'mirror-predicted-enemy-unit pred-enemy-unit
            'mirror-recommended-min-bases rec-min-bases
            'mirror-macro-verdict macro-verdict
            'mirror-requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
            'mirror-requires-anti-air? (or opp-req-aa?
                                            (enemy-tech-observation-requires-anti-air? tech-obs))
            'mirror-enemy-upgrade-advantage (enemy-tech-observation-enemy-upgrade-advantage tech-obs)
            'mirror-trust-mode trust-mode
            'mirror-strategy strat-hyp
            'dominant-opportunity-cost-path opp-dom-path
            'opponent-gas-devoted (hash-ref opp-profile 'gas-devoted 0)
            'opponent-gas-envelope (hash-ref opp-profile 'gas-envelope 150)
            'opponent-minerals-devoted (hash-ref opp-profile 'minerals-devoted 0)
            'opponent-minerals-envelope (hash-ref opp-profile 'minerals-envelope 500)
            'win-prob (compute-calibrated-win-prob raw-obs #:mstate mstate)
            'snowball-adv (compute-calibrated-snowball-adv raw-obs #:mstate mstate)))
  (hash-set! MIRROR-MIND-SIGNALS-HT-TABLE mstate opp-signals-ht)
  (define opp-commitment-log-directive
    (list 'log
          (list 'mirror-opportunity-cost-commitment
                opp-committed?
                opp-score
                (zero-sum-exclusion-reading-committed-primary-branch zs-reading)
                chosen-counter-unit
                active-d
                (hash-ref opp-profile 'gas-devoted 0)
                (hash-ref opp-profile 'gas-envelope 150))))
  (define horizon-curve-directive
    (if live-fast-path?
        #f
        (cons 'mirror-horizon-curve
              (for/list ([s (in-list horizon-snapshots)])
                (list (exact-round (horizon-snapshot-forecast-horizon-sec s))
                      (horizon-snapshot-forecast-optimal-depth s)
                      (exact-round (* 100.0 (horizon-snapshot-forecast-certainty-level s)))
                      (horizon-snapshot-forecast-predicted-enemy-unit s)
                      (horizon-snapshot-forecast-our-counter-unit s))))))

  (define base-actions
    (list (list 'mirror-prediction
                active-d
                strat-hyp
                tact-target
                pred-enemy-unit
                chosen-counter-unit
                acc-pct
                trust-mode
                (mirror-mind-state-inferred-opponent-depth mstate)
                (exact-round (* 100.0 (mirror-toolbox-allocation-toolbox-weight alloc)))
                (mirror-toolbox-allocation-toolbox-role alloc))
          (list 'mirror-macro-directive
                macro-verdict
                pred-enemy-bases
                pred-enemy-workers
                rec-min-bases
                disrupt-prio)
          (list 'mirror-tech-observation
                (enemy-tech-observation-observed-upgrades tech-obs)
                (enemy-tech-observation-implied-tech-buildings tech-obs)
                (enemy-tech-observation-enemy-upgrade-advantage tech-obs)
                (enemy-tech-observation-requires-detection? tech-obs)
                (enemy-tech-observation-requires-anti-air? tech-obs))
          (list 'mirror-zero-sum-exclusion
                (zero-sum-exclusion-reading-committed-primary-branch zs-reading)
                (zero-sum-exclusion-reading-excluded-tech-branches zs-reading)
                (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)
                (zero-sum-exclusion-reading-remaining-gas-budget zs-reading))
          (list 'mirror-spatial-maneuver
                (enemy-army-reachability-model-recommended-spatial-maneuver reach-model)
                (enemy-army-reachability-model-eta-to-our-natural-sec reach-model)
                (enemy-army-reachability-model-eta-to-enemy-exposed-base-sec reach-model)
                (enemy-army-reachability-model-unaccounted-army-supply reach-model))))

  (define bo-and-horizon-actions
    (cond
      [live-fast-path?
       (list opp-commitment-log-directive)]
      [(emit-top-level-bo-directives? raw-obs)
       (list bo-tree-directive horizon-curve-directive opp-commitment-log-directive)]
      [else
       (list (list 'log bo-tree-directive horizon-curve-directive opp-commitment-log-directive))]))

  (define want-mirror-scout?
    (or (eq? trust-mode 'skeptical-observational-fallback)
        (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)
        (memq (shadow-ledger-dark-matter-hypothesis ledger)
              '(hidden-expansion-or-macro-boom hidden-air-or-cloak-tech-switch))))
  (define prev-scout-entry (hash-ref MIRROR-SCOUT-LAST-EMIT-FRAME mstate #f))
  (define last-scout-emit (if (pair? prev-scout-entry) (car prev-scout-entry) -1000))
  (define prev-scout-mode (if (pair? prev-scout-entry) (cdr prev-scout-entry) #f))
  (define newly-skeptical?
    (and (eq? trust-mode 'skeptical-observational-fallback)
         (not (eq? prev-scout-mode 'skeptical-observational-fallback))))
  (define scout-actions
    (if (and want-mirror-scout?
             (or newly-skeptical?
                 (< frame last-scout-emit)
                 (>= (- frame last-scout-emit) 112)))
        (begin
          (hash-set! MIRROR-SCOUT-LAST-EMIT-FRAME mstate (cons frame trust-mode))
          (list (list 'scout-sector 1 enemy-x enemy-y)))
        '()))

  (append base-actions bo-and-horizon-actions scout-actions))

;; =============================================================================
;; 15. Stealth Shimmer / Burrow-Ripple Detection, Post-Detector-Snipe Window &
;;     Proactive Base Depletion Ledger (1,649-Replay Empirical Model)
;; =============================================================================

;; Detects subtle human-visible cloaked shimmer (`display-type = 2 / Hidden`,
;; `cloak-state = 2 / CloakedUnrevealed`) and burrowed-movement ground ripples
;; (`burrowed = #t` with non-zero velocity or position shift, or explicit
;; `'shimmer-and-burrow-ripples` entries from the observation pipeline).
(define (detect-enemy-shimmer-and-burrow-ripples obs)
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define explicit-ripples (safe-hash-list (hash-ref sanitized-obs 'shimmer-and-burrow-ripples '())))
  (define enemy-units (safe-hash-list (hash-ref sanitized-obs 'enemy-units '())))
  (define scanned-from-units
    (for/list ([e (in-list enemy-units)]
               #:when (let ([ut (unit-type-sym e)]
                            [dt (safe-int (hash-ref e 'display-type 1) 1)]
                            [cs (safe-int (hash-ref e 'cloak-state 0) 0)]
                            [shim? (hash-ref e 'is-shimmer? #f)]
                            [bur? (or (hash-ref e 'burrowed #f)
                                      (hash-ref e 'is-burrowed? #f)
                                      (hash-ref e 'is-burrowed #f)
                                      (memq (unit-type-sym e)
                                            '(roach-burrowed infestor-burrowed lurker-burrowed
                                              widow-mine-burrowed swarm-host-burrowed
                                              baneling-burrowed)))])
                        (and (not (memq ut '(creep-tumor creep-tumor-burrowed creep-tumor-queen)))
                             (or shim? (= dt SC2-SHIMMER-DISPLAY-TYPE-HIDDEN) (= cs 2) bur?))))
      (define utype (unit-type-sym e))
      (define bur?
        (or (hash-ref e 'burrowed #f)
            (hash-ref e 'is-burrowed? #f)
            (memq utype '(roach-burrowed infestor-burrowed lurker-burrowed
                          widow-mine-burrowed swarm-host-burrowed baneling-burrowed))))
      (hash 'id (hash-ref e 'id 0)
            'type utype
            'x (safe-coord (hash-ref e 'x 160) 160)
            'y (safe-coord (hash-ref e 'y 160) 160)
            'indicator-kind (if bur? 'burrow-movement-ripple 'cloaked-shimmer)
            'recommended-aoe-spells SC2-BLIND-AOE-SKILLSHOT-SPELLS)))
  ;; Deduplicate by unit id
  (define seen-ids (make-hash))
  (filter (lambda (r)
            (define rid (hash-ref r 'id 0))
            (cond
              [(and (exact-integer? rid) (> rid 0) (hash-has-key? seen-ids rid)) #f]
              [else
               (when (and (exact-integer? rid) (> rid 0))
                 (hash-set! seen-ids rid #t))
               #t]))
          (append explicit-ripples scanned-from-units)))

;; Evaluates the 60s (`1344` frames) post-detector-snipe stealth unlock window
;; (`58.2%` win rate and `651.0` average uncontested stealth damage in 60s across
;; 1,649 pro/ladder replays).
(define (evaluate-post-detector-snipe-window obs [last-detector-snipe-frame -99999])
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define frame (safe-frame (hash-ref sanitized-obs 'frame 0)))
  (define eff-snipe-frame
    (safe-int (hash-ref sanitized-obs 'last-detector-snipe-frame last-detector-snipe-frame)
              last-detector-snipe-frame))
  (define enemy-units (safe-hash-list (hash-ref sanitized-obs 'enemy-units '())))
  (define enemy-bldgs (safe-hash-list (hash-ref sanitized-obs 'enemy-buildings '())))
  (define live-enemy-detectors
    (+ (count (lambda (e) (memq (unit-type-sym e) SC2-MOBILE-DETECTOR-SYMS)) enemy-units)
       (count (lambda (b) (memq (unit-type-sym b) SC2-STATIC-DETECTOR-SYMS)) enemy-bldgs)))
  (define elapsed (- frame eff-snipe-frame))
  (define active?
    (and (>= eff-snipe-frame 0)
         (>= elapsed 0)
         (<= elapsed SC2-POST-SNIPE-STEALTH-UNLOCK-FRAMES)
         (= live-enemy-detectors 0)))
  (hash 'active? active?
        'remaining-frames (if active? (max 0 (- SC2-POST-SNIPE-STEALTH-UNLOCK-FRAMES elapsed)) 0)
        'live-enemy-detectors live-enemy-detectors
        'expected-damage-res (if active? SC2-POST-SNIPE-EXPECTED-DAMAGE-RES 0.0)
        'recommended-posture (if active?
                                 'uncontested-stealth-and-burrow-aggression
                                 'standard-detector-aware)))

;; Estimates remaining minerals at each enemy base using the 10,800M starting
;; base ledger and flags bases within 90s (`< 2400M` remaining) of depletion so
;; we can predict and intercept forced enemy expansions.
(define (estimate-enemy-base-depletion-ledger obs)
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define frame (safe-frame (hash-ref sanitized-obs 'frame 0)))
  (define enemy-bldgs (safe-hash-list (hash-ref sanitized-obs 'enemy-buildings '())))
  (define townhall-syms
    '(hatchery lair hive command-center orbital-command planetary-fortress nexus))
  (define enemy-bases
    (filter (lambda (b) (memq (unit-type-sym b) townhall-syms)) enemy-bldgs))
  (define eff-bases
    (if (null? enemy-bases)
        (list (hash 'id 9001 'type 'enemy-main-base
                    'x (safe-coord (hash-ref sanitized-obs 'enemy-x 160) 160)
                    'y (safe-coord (hash-ref sanitized-obs 'enemy-y 160) 160)
                    'started-frame 0))
        enemy-bases))
  (for/list ([b (in-list eff-bases)]
             [idx (in-naturals 0)])
    (define default-start-frame (* idx 2000))
    (define start-f (safe-int (hash-ref b 'started-frame default-start-frame) default-start-frame))
    (define mining-frames (max 0 (- frame start-f)))
    ;; Saturated base mines ~16 minerals/sec = ~0.714 minerals/frame
    (define mined-est (exact-round (* mining-frames 0.714)))
    (define rem-minerals (max 0 (- SC2-BASE-STARTING-MINERAL-LEDGER mined-est)))
    (define pre-depleting? (<= rem-minerals SC2-PRE-DEPLETION-PROACTIVE-MINERAL-THRESH))
    (hash 'base-index (add1 idx)
          'x (safe-coord (hash-ref b 'x 160) 160)
          'y (safe-coord (hash-ref b 'y 160) 160)
          'remaining-minerals rem-minerals
          'pre-depleting-90s? pre-depleting?
          'forced-expansion-imminent? pre-depleting?)))

