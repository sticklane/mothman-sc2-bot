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
         racket/set
         (rename-in "sc2-common.rkt" [dist2d common-dist2d])
         "sc2-game-constants.rkt"
         "zerospace-mastermind.rkt")

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
         lookup-race-build-order-tree
         project-player-onto-build-order-tree
         project-self-build-order-tree
         project-opponent-build-order-tree
         compute-bayesian-bluff-posterior
         compute-bayesian-strategic-posteriors
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
         step-mirror-mind-predictor!)

;; =============================================================================
;; 1. Unit & Structure Cost Table (Minerals . Gas)
;; =============================================================================

(define UNIT-COST-TABLE
  (hash
   ;; Zerg
   'drone             (cons 50 0)
   'zergling          (cons 25 0)
   'baneling          (cons 50 25)
   'queen             (cons 150 0)
   'roach             (cons 75 25)
   'ravager           (cons 100 100)
   'hydralisk         (cons 100 50)
   'lurker            (cons 150 150)
   'mutalisk          (cons 100 100)
   'corruptor         (cons 150 100)
   'ultralisk         (cons 300 200)
   'brood-lord        (cons 300 250)
   'infestor          (cons 100 150)
   'viper             (cons 100 200)
   'overlord          (cons 100 0)
   'overseer          (cons 150 50)
   'hatchery          (cons 300 0)
   'lair              (cons 450 100)
   'hive              (cons 650 250)
   'spawning-pool     (cons 200 0)
   'extractor         (cons 25 0)
   'roach-warren      (cons 150 0)
   'baneling-nest     (cons 100 50)
   'hydralisk-den     (cons 100 100)
   'lurker-den        (cons 100 150)
   'spire             (cons 200 200)
   'infestation-pit   (cons 100 100)
   'ultralisk-cavern  (cons 150 200)
   'spine-crawler     (cons 100 0)
   'spore-crawler     (cons 75 0)
   ;; Terran
   'scv               (cons 50 0)
   'marine            (cons 50 0)
   'marauder          (cons 100 25)
   'reaper            (cons 50 50)
   'ghost             (cons 150 125)
   'hellion           (cons 100 0)
   'hellbat           (cons 100 0)
   'widow-mine        (cons 75 25)
   'cyclone           (cons 150 100)
   'siege-tank        (cons 150 125)
   'siege-tank-sieged (cons 150 125)
   'thor              (cons 300 200)
   'viking            (cons 150 75)
   'medivac           (cons 100 100)
   'liberator         (cons 150 125)
   'banshee           (cons 150 100)
   'raven             (cons 100 150)
   'battlecruiser     (cons 400 300)
   'command-center    (cons 400 0)
   'orbital-command   (cons 550 0)
   'planetary-fortress (cons 550 150)
   'supply-depot      (cons 100 0)
   'refinery          (cons 75 0)
   'barracks          (cons 150 0)
   'barracks-techlab  (cons 50 25)
   'barracks-reactor  (cons 50 50)
   'factory           (cons 150 100)
   'factory-techlab   (cons 50 25)
   'starport          (cons 150 100)
   'engineering-bay   (cons 125 0)
   'armory            (cons 150 100)
   'fusion-core       (cons 150 150)
   'bunker            (cons 100 0)
   'missile-turret    (cons 100 0)
   ;; Protoss
   'probe             (cons 50 0)
   'zealot            (cons 100 0)
   'stalker           (cons 125 50)
   'sentry            (cons 50 100)
   'adept             (cons 100 25)
   'high-templar      (cons 50 150)
   'dark-templar      (cons 125 125)
   'archon            (cons 175 275)
   'observer          (cons 25 75)
   'warp-prism        (cons 250 0)
   'immortal          (cons 275 100)
   'colossus          (cons 300 200)
   'disruptor         (cons 150 150)
   'phoenix           (cons 150 100)
   'void-ray          (cons 250 150)
   'oracle            (cons 150 150)
   'tempest           (cons 250 175)
   'carrier           (cons 350 250)
   'nexus             (cons 400 0)
   'pylon             (cons 100 0)
   'assimilator       (cons 75 0)
   'gateway           (cons 150 0)
   'warpgate          (cons 150 0)
   'forge             (cons 150 0)
   'cybernetics-core  (cons 150 0)
   'photon-cannon     (cons 150 0)
   'shield-battery    (cons 100 0)
   'twilight-council  (cons 150 100)
   'stargate          (cons 150 150)
   'robotics-facility (cons 150 100)
   'robotics-bay      (cons 150 150)
   'robotics-support-bay (cons 150 150)
   'templar-archive   (cons 150 200)
   'dark-shrine       (cons 150 150)
   'fleet-beacon      (cons 300 200)))

(define (unit-resource-cost unit-sym)
  (hash-ref UNIT-COST-TABLE unit-sym (cons 100 25)))

(define (safe-frame f)
  (safe-nonneg-int f 0))

(define (safe-coord v [fallback 160])
  (safe-int v fallback))

(define (dist2d x1 y1 x2 y2)
  (common-dist2d x1 y1 x2 y2 32.0 160.0))

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

;; Canonical Build-Order Tree Node in T_R (shared structural space for self and opponent)
(struct build-order-tree-node
  (id
   race
   parent-id
   children-ids
   path-buildings
   step-buildings
   unlocked-units
   unlocked-upgrades
   archetype
   min-frame
   min-gas-bldgs
   step-min-cost
   step-gas-cost
   step-build-frames
   prior-weight)
  #:transparent)

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

;; Bayesian Strategic Priors & Posteriors (replacing hard boolean bluff flags)
(struct bayesian-strategic-priors
  (bluff-prior
   bluff-posterior
   feint-posterior
   rush-posterior
   hidden-expand-posterior
   tech-switch-posterior
   branch-posteriors)
  #:transparent)

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
    [(psi-storm-tech psi-storm)   (cons 200 200)]
    [(neural-parasite)            (cons 150 150)]
    [(extended-thermal-lance)     (cons 150 150)]
    [(lurker-aspect)              (cons 150 150)]
    [(chitinous-plating)          (cons 150 150)]
    [else                         (cons 100 100)]))

(define (enemy-unit-hallucination? u)
  (cond
    [(not (hash? u)) #f]
    [else
     (define dmg-ratio
       (safe-real (hash-ref u 'damage-rate-ratio
                            (hash-ref u 'damage-taken-multiplier 1.0))
                  1.0))
     (define dmg-dealt (safe-real (hash-ref u 'damage-dealt 1.0) 1.0))
     (or (eq? (hash-ref u 'hallucination? #f) #t)
         (eq? (hash-ref u 'hallucination #f) #t)
         (>= dmg-ratio 1.6)
         (and (hash-ref u 'attacking? #f)
              (= dmg-dealt 0.0)))]))

(define (enemy-unit-changeling? u)
  (and (hash? u)
       (or (eq? (hash-ref u 'changeling? #f) #t)
           (not (not (memq (unit-type-sym u)
                           '(changeling changeling-zealot changeling-marine
                             changeling-marine-shield changeling-zergling
                             changeling-zergling-wings)))))))

(define NON-COMBAT-SCOUT-SYMS
  '(overlord overseer observer larva egg
    changeling changeling-zealot changeling-marine
    changeling-marine-shield changeling-zergling
    changeling-zergling-wings))

(define (enemy-combat-unit? u)
  (define ut (unit-type-sym u))
  (and (not (memq ut NON-COMBAT-SCOUT-SYMS))
       (not (memq ut '(drone probe scv mule)))
       (not (enemy-unit-hallucination? u))
       (not (enemy-unit-changeling? u))))

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

(define (analyze-enemy-structure-activity-and-bluffs raw-enemy-bldgs)
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define in-prog '())
  (define active-res '())
  (define inferred-upgs '())
  (define res-under-atk? #f)
  (define canceled-res-status 'none)
  (define fake-builds '())
  (define previews '())
  (define bluff? #f)

  (for ([b (in-list enemy-bldgs)])
    (define btype (unit-type-sym b))
    (define prog
      (safe-real (hash-ref b 'build-progress (if (hash-ref b 'under-construction #f) 0.5 1.0))
                 1.0))
    (define canceled? (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define hp (safe-real (hash-ref b 'hp 500) 500.0))
    (define max-hp (max 1.0 (safe-real (hash-ref b 'max-hp 500) 500.0)))
    (define under-atk?
      (or (hash-ref b 'under-attack? #f)
          (hash-ref b 'under-attack #f)
          (< hp max-hp)))
    (define b-spells
      (append (safe-list (hash-ref b 'spells '()))
              (safe-list (hash-ref b 'buffs '()))
              (safe-list (hash-ref b 'effects '()))))
    (define chrono?
      (or (hash-ref b 'chrono? #f)
          (hash-ref b 'chrono-boost? #f)
          (memq 'chrono-boost b-spells)
          (memq 'chrono-boost-active b-spells)))
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
       (unless (memq btype fake-builds)
         (set! fake-builds (append fake-builds (list btype))))
       (set! bluff? #t)]
      [(and (< prog 1.0) (not canceled?))
       (unless (memq btype in-prog)
         (set! in-prog (append in-prog (list btype))))])

    ;; 2. Active research, inferred upgrade identity, research under attack, & canceled research
    (define inf-upg (inferred-upgrade-for-research-bldg btype))
    (cond
      [res-canceled?
       (when inf-upg
         (unless (memq inf-upg inferred-upgs)
           (set! inferred-upgs (append inferred-upgs (list inf-upg)))))
       (if under-atk?
           (set! canceled-res-status 'emergency-research-canceled-under-attack)
           (begin
             (set! canceled-res-status 'fake-research-bluff-canceled)
             (set! bluff? #t)))]
      [(and active? (not canceled?))
       (unless (memq btype active-res)
         (set! active-res (append active-res (list btype))))
       (when inf-upg
         (unless (memq inf-upg inferred-upgs)
           (set! inferred-upgs (append inferred-upgs (list inf-upg)))))
       (when under-atk?
         (set! res-under-atk? #t)
         (set! bluff? #f))])

    ;; 3. Stargate / Production Unit Preview (e.g. 'oracle, 'void-ray, 'phoenix, 'carrier)
    (when (and preview (symbol? preview))
      (unless (memq preview previews)
        (set! previews (append previews (list preview))))))

  (enemy-structure-activity in-prog
                            active-res
                            inferred-upgs
                            res-under-atk?
                            canceled-res-status
                            fake-builds
                            previews
                            bluff?))

(define (evaluate-attrition-and-relative-strength
         raw-ally-units
         raw-enemy-units
         #:our-lost-value [raw-our-lost-value 0]
         #:enemy-lost-value [raw-enemy-lost-value 0]
         #:predicted-enemy-bases [raw-predicted-enemy-bases 1]
         #:predicted-enemy-workers [raw-predicted-enemy-workers 16]
         #:observed-enemy-geysers [raw-observed-enemy-geysers 1])
  (define ally-units (safe-hash-list raw-ally-units))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define our-lost-value (max 0 (safe-int raw-our-lost-value 0)))
  (define enemy-lost-value (max 0 (safe-int raw-enemy-lost-value 0)))
  (define predicted-enemy-bases (max 1 (safe-int raw-predicted-enemy-bases 1)))
  (define predicted-enemy-workers (max 0 (safe-int raw-predicted-enemy-workers 16)))
  (define observed-enemy-geysers (max 0 (safe-int raw-observed-enemy-geysers 1)))
  (define noncombat '(drone probe scv overlord observer larva egg))
  (define (army-val units)
    (for/sum ([u (in-list units)]
              #:when (and (not (memq (unit-type-sym u) noncombat))
                          (not (enemy-unit-hallucination? u))
                          (not (enemy-unit-changeling? u))))
      (define c (unit-resource-cost (unit-type-sym u)))
      (+ (car c) (exact-round (* 1.5 (cdr c))))))
  (define our-val (army-val ally-units))
  (define enemy-val (army-val enemy-units))
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
  (define noncombat '(drone probe scv overlord observer larva egg))
  (define real-enemy-combat
    (filter (lambda (u)
              (and (not (memq (unit-type-sym u) noncombat))
                   (not (enemy-unit-hallucination? u))
                   (not (enemy-unit-changeling? u))))
            enemy-units))
  (define real-ally-combat
    (filter (lambda (u) (not (memq (unit-type-sym u) noncombat)))
            ally-units))

  (define (unit-supply-est u)
    (define c (unit-resource-cost (unit-type-sym u)))
    (max 1 (quotient (+ (car c) (* 2 (cdr c))) 75)))

  (define seen-supply
    (for/sum ([u (in-list real-enemy-combat)])
      (unit-supply-est u)))
  (define our-supply
    (for/sum ([u (in-list real-ally-combat)])
      (unit-supply-est u)))

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
  (define enemy-types (map unit-type-sym real-enemy-combat))

  ;; Base speed in SC2 map tiles/sec (~4.2 tiles per second baseline, scaled by
  ;; unit mobility, speed upgrades, Stimpack, Blink, Medivac/Warp-Prism boost, or Nydus/Recall)
  (define has-transport-or-air?
    (ormap (lambda (t)
             (memq t '(medivac warp-prism mutalisk phoenix oracle banshee viking-fighter
                       corruptor void-raynydus-worm nydus-canal)))
           enemy-types))
  (define has-speed-upgrade?
    (or (ormap (lambda (u)
                 (memq u '(zergling-movementspeed stimpack charge blink glial-reconstitution
                           anabolic-synthesis muscular-augments)))
               obs-upgrades)
        (ormap (lambda (s) (memq s '(stimpack blink charge medivac-boost)))
               obs-spells)))
  (define fast-ground?
    (ormap (lambda (t) (memq t '(zergling adept hellion reaper stalker)))
           enemy-types))

  (define eff-speed
    (* 4.2
       (if has-transport-or-air? 1.55 (if fast-ground? 1.25 1.0))
       (if has-speed-upgrade? 1.35 1.0)))

  (define-values (ex ey)
    (if (null? real-enemy-combat)
        (values (safe-real enemy-exp-x 142.0) (safe-real enemy-exp-y 136.0))
        (values (/ (for/sum ([u (in-list real-enemy-combat)])
                     (safe-real (hash-ref u 'x enemy-exp-x) 142.0))
                   (max 1.0 (exact->inexact (length real-enemy-combat))))
                (/ (for/sum ([u (in-list real-enemy-combat)])
                     (safe-real (hash-ref u 'y enemy-exp-y) 136.0))
                   (max 1.0 (exact->inexact (length real-enemy-combat)))))))

  (define-values (ax ay)
    (if (null? real-ally-combat)
        (values (safe-real our-nat-x 50.0) (safe-real our-nat-y 56.0))
        (values (/ (for/sum ([u (in-list real-ally-combat)])
                     (safe-real (hash-ref u 'x our-nat-x) 50.0))
                   (max 1.0 (exact->inexact (length real-ally-combat))))
                (/ (for/sum ([u (in-list real-ally-combat)])
                     (safe-real (hash-ref u 'y our-nat-y) 56.0))
                   (max 1.0 (exact->inexact (length real-ally-combat)))))))

  (define dist dist2d)

  ;; Ground detour factor (1.0 for air/drop/blink, 1.18 for ground terrain pathing)
  (define path-factor (if has-transport-or-air? 1.0 1.18))
  (define eta-main
    (if (null? real-enemy-combat)
        25.0
        (/ (* path-factor (dist ex ey our-base-x our-base-y)) eff-speed)))
  (define eta-nat
    (if (null? real-enemy-combat)
        20.0
        (/ (* path-factor (dist ex ey our-nat-x our-nat-y)) eff-speed)))
  (define eta-enemy-exp
    (if (null? real-enemy-combat)
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
  (define max-atk 0)
  (define max-arm 0)
  (define max-shd 0)
  (define req-det? #f)
  (define req-aa? #f)

  (define (add-hist-bldg! b)
    (unless (memq b historical-bldgs)
      (set! historical-bldgs (append historical-bldgs (list b)))))
  (define (add-post-bldg! b)
    (add-hist-bldg! b)
    (unless (memq b post-destruction-bldgs)
      (set! post-destruction-bldgs (append post-destruction-bldgs (list b)))))
  (define (add-upg! u)
    (unless (memq u obs-upgrades)
      (set! obs-upgrades (append obs-upgrades (list u)))))
  (define (add-spell! s)
    (unless (memq s obs-spells)
      (set! obs-spells (append obs-spells (list s)))))
  (define (add-active-res! b)
    (unless (memq b active-res-bldgs)
      (set! active-res-bldgs (append active-res-bldgs (list b)))))

  ;; Completed upgrades persist even if their research building is later destroyed
  (for ([hu (in-list historical-upgrades)])
    (add-upg! hu))
  ;; Scouted tech buildings persist across fog-of-war blackouts unless destroyed
  (for ([hb (in-list historical-implied-bldgs)]
        #:unless (memq hb destroyed-enemy-bldgs))
    (add-hist-bldg! hb))
  ;; Destroyed buildings still count toward sunk historical tech cost
  (for ([db (in-list destroyed-enemy-bldgs)])
    (add-hist-bldg! db)
    (for ([p (in-list (implied-prereqs-for-sym db))])
      (add-hist-bldg! p)))

  ;; 1. Transitive prerequisite buildings from visible enemy units & buildings
  ;;    - Anti-Ghost-Resurrection Rule: a pre-existing surviving unit (whose 'id is
  ;;      in pre-destruction-unit-ids) contributes to historical-bldgs (sunk cost)
  ;;      but does NOT re-imply that a destroyed tech building is active again!
  ;;    - Hallucination Rule: a hallucinated unit (2.0x damage taken rate) does NOT
  ;;      imply its fake unit type's tech buildings (e.g. Stargate/RoboticsBay);
  ;;      instead it implies Sentry Hallucination tech ('(pylon gateway cybernetics-core assimilator)).
  ;;    - Changeling Rule: an enemy Changeling implies Overseer Lair tech.
  (for ([u (in-list enemy-units)])
    (define utype (unit-type-sym u))
    (define uid (hash-ref u 'id #f))
    (define pre-existing? (and uid (memq uid pre-destruction-unit-ids)))
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
       (for ([p (in-list (implied-prereqs-for-sym utype))])
         (if pre-existing?
             (add-hist-bldg! p)
             (add-post-bldg! p)))]))

  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define btype (unit-type-sym b))
    (add-post-bldg! btype)
    (for ([p (in-list (implied-prereqs-for-sym btype))])
      (add-post-bldg! p))
    (define preview (hash-ref b 'preview-unit (hash-ref b 'unit-preview #f)))
    (when (and preview (symbol? preview))
      (add-spell! preview)
      (for ([p (in-list (implied-prereqs-for-sym preview))])
        (add-post-bldg! p))
      (when (memq preview '(oracle void-ray voidray phoenix carrier tempest mutalisk corruptor banshee battlecruiser))
        (set! req-aa? #t))
      (when (memq preview '(oracle dark-templar banshee lurker))
        (set! req-det? #t))))

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

  ;; 2. Inspect non-hallucinated enemy units for upgrades, HP/speed signatures, spells/buffs, cloak/burrow, and air
  (for ([u (in-list enemy-units)]
        #:unless (or (enemy-unit-hallucination? u)
                     (enemy-unit-changeling? u)))
    (define utype (unit-type-sym u))
    (define uid (hash-ref u 'id #f))
    (define pre-existing? (and uid (memq uid pre-destruction-unit-ids)))
    (define add-bldg! (if pre-existing? add-hist-bldg! add-post-bldg!))
    (define atk (max 0 (safe-int (hash-ref u 'atk-upg (hash-ref u 'attack-upgrade-level 0)) 0)))
    (define arm (max 0 (safe-int (hash-ref u 'arm-upg (hash-ref u 'armor-upgrade-level 0)) 0)))
    (define shd (max 0 (safe-int (hash-ref u 'shd-upg (hash-ref u 'shield-upgrade-level 0)) 0)))
    (define explicit-upgs (safe-list (hash-ref u 'upgrades '())))
    (define unit-spells
      (append (safe-list (hash-ref u 'spells '()))
              (safe-list (hash-ref u 'buffs '()))
              (safe-list (hash-ref u 'effects '()))))
    (define max-hp (safe-real (hash-ref u 'max-hp (hash-ref u 'hp 0)) 0.0))
    (define spd (safe-real (hash-ref u 'speed 0.0) 0.0))
    (define burrowed? (or (hash-ref u 'burrowed? #f) (hash-ref u 'burrowed #f)))
    (define cloaked? (or (hash-ref u 'cloaked? #f) (hash-ref u 'cloaked #f)))

    (set! max-atk (max max-atk atk))
    (set! max-arm (max max-arm arm))
    (set! max-shd (max max-shd shd))

    (for ([eu (in-list explicit-upgs)])
      (add-upg! eu))
    (for ([sp (in-list unit-spells)])
      (process-spell-or-effect! sp))

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
    (when (and (eq? utype 'marine) (>= max-hp 55.0))
      (add-upg! 'combat-shield)
      (add-bldg! 'barracks-techlab))
    (when (and (eq? utype 'zergling) (> spd 3.5))
      (add-upg! 'zergling-movementspeed)
      (add-bldg! 'spawning-pool)
      (add-bldg! 'extractor))
    (when (and (eq? utype 'roach) (> spd 2.5))
      (add-upg! 'glial-reconstitution)
      (add-bldg! 'roach-warren)
      (add-bldg! 'lair))

    ;; Burrow / Cloak / Subterranean detection triggers
    (when (or burrowed?
              (memq utype '(lurker lurker-mp widow-mine widowmine roach-burrowed zergling-burrowed)))
      (add-upg! 'burrow-or-subterranean-tech)
      (set! req-det? #t))
    (when (or cloaked?
              (memq utype '(dark-templar banshee ghost mothership lurker lurker-mp widow-mine widowmine observer)))
      (set! req-det? #t))

    ;; Air threat trigger (unit type OR explicit flying? / flying / is-flying flag)
    (when (or (hash-ref u 'flying? #f)
              (hash-ref u 'flying #f)
              (hash-ref u 'is-flying #f)
              (memq utype '(mutalisk corruptor brood-lord broodlord viper
                            viking viking-fighter medivac liberator banshee raven battlecruiser
                            phoenix oracle void-ray voidray carrier tempest mothership)))
      (set! req-aa? #t)))

  ;; 3. Inspect enemy buildings for active research, Chrono Boost, & implied detection/anti-air
  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define btype (unit-type-sym b))
    (when (or (hash-ref b 'flying? #f)
              (hash-ref b 'flying #f)
              (hash-ref b 'is-flying #f)
              (memq btype '(command-center-flying orbital-command-flying
                            barracks-flying factory-flying starport-flying)))
      (set! req-aa? #t))
    (define b-spells
      (append (safe-list (hash-ref b 'spells '()))
              (safe-list (hash-ref b 'buffs '()))
              (safe-list (hash-ref b 'effects '()))))
    (define chrono?
      (or (hash-ref b 'chrono? #f)
          (hash-ref b 'chrono-boost? #f)
          (memq 'chrono-boost b-spells)
          (memq 'chrono-boost-active b-spells)))
    (for ([sp (in-list b-spells)])
      (process-spell-or-effect! sp))
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
    (when (memq b '(dark-shrine ghost-academy lurker-den lurker-den-mp starport-techlab))
      (set! req-det? #t))
    (when (memq b '(spire greater-spire starport fusion-core stargate fleet-beacon))
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

  (enemy-tech-observation obs-upgrades
                          active-implied-bldgs
                          active-res-bldgs
                          max-atk
                          max-arm
                          max-shd
                          upg-adv
                          req-det?
                          req-aa?
                          implied-min
                          implied-gas
                          obs-spells
                          crippled-bldgs))

;; =============================================================================
;; 2c. Build-Order Tree Space (T_R) for Self & Opponent + Bayesian Priors
;; =============================================================================

(define ZERG-BUILD-ORDER-TREE
  (list
   (build-order-tree-node
    'zerg-root-hatchery 'Zerg #f
    '(zerg-spawning-pool zerg-hatch-first-pool)
    '(hatchery) '(hatchery)
    '(drone overlord zergling) '()
    'early-rush 0 0 300 0 0 0.08)
   (build-order-tree-node
    'zerg-spawning-pool 'Zerg 'zerg-root-hatchery
    '(zerg-hatch-first-pool zerg-baneling-nest zerg-roach-warren)
    '(hatchery spawning-pool) '(spawning-pool)
    '(zergling queen) '(zergling-movementspeed)
    'early-rush 400 0 200 0 720 0.16)
   (build-order-tree-node
    'zerg-hatch-first-pool 'Zerg 'zerg-spawning-pool
    '(zerg-baneling-nest zerg-roach-warren zerg-lair-tech)
    '(hatchery spawning-pool extractor) '(hatchery extractor)
    '(zergling queen) '(zergling-movementspeed burrow)
    'ling-bane-hydra 750 1 325 0 960 0.18)
   (build-order-tree-node
    'zerg-baneling-nest 'Zerg 'zerg-spawning-pool
    '(zerg-lair-tech)
    '(hatchery spawning-pool extractor baneling-nest) '(baneling-nest)
    '(baneling zergling queen) '(zergling-movementspeed centrifical-hooks)
    'ling-bane-hydra 1350 1 100 50 672 0.14)
   (build-order-tree-node
    'zerg-roach-warren 'Zerg 'zerg-spawning-pool
    '(zerg-lair-tech)
    '(hatchery spawning-pool extractor roach-warren) '(roach-warren)
    '(roach ravager zergling queen) '(glial-reconstitution burrow)
    'roach-ravager 1400 1 150 0 605 0.20)
   (build-order-tree-node
    'zerg-lair-tech 'Zerg 'zerg-roach-warren
    '(zerg-hydralisk-den zerg-spire-muta zerg-infestation-pit)
    '(hatchery spawning-pool extractor roach-warren lair) '(lair)
    '(overseer roach ravager zergling queen) '(glial-reconstitution pneumatized-carapace)
    'roach-ravager 2400 2 150 100 896 0.16)
   (build-order-tree-node
    'zerg-hydralisk-den 'Zerg 'zerg-lair-tech
    '(zerg-lurker-den zerg-hive-tech)
    '(hatchery spawning-pool extractor lair hydralisk-den) '(hydralisk-den)
    '(hydralisk roach ravager zergling) '(grooved-spines muscular-augments)
    'ling-bane-hydra 3200 2 100 100 650 0.16)
   (build-order-tree-node
    'zerg-spire-muta 'Zerg 'zerg-lair-tech
    '(zerg-hive-tech zerg-greater-spire-broodlord)
    '(hatchery spawning-pool extractor lair spire) '(spire)
    '(mutalisk corruptor zergling baneling) '(zerg-flyer-weapons-1 zerg-flyer-armor-1)
    'muta-flock 3300 2 200 200 960 0.12)
   (build-order-tree-node
    'zerg-lurker-den 'Zerg 'zerg-hydralisk-den
    '(zerg-hive-tech)
    '(hatchery spawning-pool extractor lair hydralisk-den lurker-den) '(lurker-den)
    '(lurker hydralisk roach ravager) '(adaptive-talons seismic-spines)
    'ling-bane-hydra 4200 3 100 150 896 0.10)
   (build-order-tree-node
    'zerg-infestation-pit 'Zerg 'zerg-lair-tech
    '(zerg-hive-tech)
    '(hatchery spawning-pool extractor lair infestation-pit) '(infestation-pit)
    '(infestor swarm-host roach hydralisk) '(pathogen-glands neural-parasite)
    'ling-bane-hydra 4100 3 100 100 806 0.07)
   (build-order-tree-node
    'zerg-hive-tech 'Zerg 'zerg-infestation-pit
    '(zerg-ultralisk-cavern zerg-greater-spire-broodlord)
    '(hatchery spawning-pool extractor lair infestation-pit hive) '(hive)
    '(viper hydralisk lurker infestor) '(adrenal-glands zerg-melee-weapons-3)
    'ling-bane-hydra 5400 4 200 150 960 0.06)
   (build-order-tree-node
    'zerg-ultralisk-cavern 'Zerg 'zerg-hive-tech
    '()
    '(hatchery spawning-pool extractor lair infestation-pit hive ultralisk-cavern) '(ultralisk-cavern)
    '(ultralisk zergling baneling corruptor viper) '(chitinous-plating anabolic-synthesis)
    'ling-bane-hydra 6200 4 150 200 896 0.05)
   (build-order-tree-node
    'zerg-greater-spire-broodlord 'Zerg 'zerg-hive-tech
    '()
    '(hatchery spawning-pool extractor lair infestation-pit hive spire greater-spire) '(greater-spire)
    '(brood-lord corruptor mutalisk viper) '(zerg-flyer-weapons-3)
    'muta-flock 6400 4 100 150 960 0.05)))

(define TERRAN-BUILD-ORDER-TREE
  (list
   (build-order-tree-node
    'terran-root-cc 'Terran #f
    '(terran-barracks-open)
    '(command-center supply-depot) '(command-center supply-depot)
    '(scv marine) '()
    'early-rush 0 0 500 0 0 0.08)
   (build-order-tree-node
    'terran-barracks-open 'Terran 'terran-root-cc
    '(terran-reaper-expand terran-bio-techlab-stim terran-factory-tech)
    '(command-center supply-depot barracks refinery) '(barracks refinery)
    '(marine reaper) '()
    'bio-ball 480 1 225 0 720 0.18)
   (build-order-tree-node
    'terran-reaper-expand 'Terran 'terran-barracks-open
    '(terran-bio-techlab-stim terran-factory-tech)
    '(command-center orbital-command supply-depot barracks barracks-reactor refinery) '(orbital-command barracks-reactor)
    '(marine reaper) '()
    'bio-ball 1050 1 200 50 672 0.18)
   (build-order-tree-node
    'terran-bio-techlab-stim 'Terran 'terran-barracks-open
    '(terran-factory-tech terran-starport-medivac-bio)
    '(command-center orbital-command supply-depot barracks barracks-techlab refinery engineering-bay) '(barracks-techlab engineering-bay)
    '(marauder marine) '(stimpack combat-shield concussive-shells)
    'bio-ball 1500 1 175 25 650 0.22)
   (build-order-tree-node
    'terran-factory-tech 'Terran 'terran-barracks-open
    '(terran-factory-siege-tank terran-starport-medivac-bio terran-starport-cloak-banshee)
    '(command-center orbital-command supply-depot barracks factory refinery) '(factory)
    '(hellion widow-mine marine) '(drilling-claws infernal-pre-igniter)
    'mech-siege 1800 1 150 100 720 0.16)
   (build-order-tree-node
    'terran-factory-siege-tank 'Terran 'terran-factory-tech
    '(terran-armory-heavy-mech terran-starport-medivac-bio terran-starport-viking-liberator)
    '(command-center orbital-command supply-depot barracks factory factory-techlab refinery) '(factory-techlab)
    '(siege-tank cyclone hellion marine marauder) '(siege-mode)
    'mech-siege 2350 2 50 25 403 0.18)
   (build-order-tree-node
    'terran-starport-medivac-bio 'Terran 'terran-factory-tech
    '(terran-starport-viking-liberator terran-ghost-academy-late)
    '(command-center orbital-command supply-depot barracks barracks-techlab factory starport refinery) '(starport)
    '(medivac marauder marine siege-tank widow-mine) '(stimpack combat-shield)
    'bio-ball 2650 2 150 100 672 0.18)
   (build-order-tree-node
    'terran-starport-cloak-banshee 'Terran 'terran-factory-tech
    '(terran-fusion-battlecruiser terran-starport-viking-liberator)
    '(command-center orbital-command supply-depot barracks factory starport starport-techlab refinery) '(starport starport-techlab)
    '(banshee raven viking hellion) '(cloaking-field)
    'sky-toss 2750 2 200 125 784 0.10)
   (build-order-tree-node
    'terran-starport-viking-liberator 'Terran 'terran-starport-medivac-bio
    '(terran-fusion-battlecruiser terran-armory-heavy-mech)
    '(command-center orbital-command supply-depot barracks factory starport refinery) '(starport)
    '(viking liberator medivac siege-tank marauder) '(advanced-ballistics)
    'sky-toss 3400 2 150 100 672 0.10)
   (build-order-tree-node
    'terran-armory-heavy-mech 'Terran 'terran-factory-siege-tank
    '(terran-fusion-battlecruiser)
    '(command-center orbital-command supply-depot barracks factory factory-techlab armory refinery) '(armory)
    '(thor siege-tank hellbat cyclone) '(terran-vehicle-weapons-1 terran-vehicle-and-ship-plating-1)
    'mech-siege 3600 3 150 100 806 0.10)
   (build-order-tree-node
    'terran-ghost-academy-late 'Terran 'terran-starport-medivac-bio
    '()
    '(command-center orbital-command supply-depot barracks barracks-techlab factory starport ghost-academy refinery) '(ghost-academy)
    '(ghost marauder marine medivac liberator) '(personal-cloaking)
    'bio-ball 4400 3 150 50 650 0.06)
   (build-order-tree-node
    'terran-fusion-battlecruiser 'Terran 'terran-starport-cloak-banshee
    '()
    '(command-center orbital-command supply-depot barracks factory starport starport-techlab fusion-core refinery) '(fusion-core)
    '(battlecruiser viking liberator siege-tank) '(weapon-refit)
    'sky-toss 4600 3 150 150 896 0.06)))

(define PROTOSS-BUILD-ORDER-TREE
  (list
   (build-order-tree-node
    'protoss-root-nexus 'Protoss #f
    '(protoss-gateway-open)
    '(nexus pylon) '(nexus pylon)
    '(probe zealot) '()
    'early-rush 0 0 500 0 0 0.08)
   (build-order-tree-node
    'protoss-gateway-open 'Protoss 'protoss-root-nexus
    '(protoss-cybernetics-core)
    '(nexus pylon gateway assimilator) '(gateway assimilator)
    '(zealot) '()
    'early-rush 480 1 225 0 720 0.15)
   (build-order-tree-node
    'protoss-cybernetics-core 'Protoss 'protoss-gateway-open
    '(protoss-twilight-council protoss-robotics-facility protoss-stargate-air)
    '(nexus pylon gateway cybernetics-core assimilator) '(cybernetics-core)
    '(stalker adept sentry zealot) '(warp-gate-research)
    'stalker-colossus 1050 1 150 0 672 0.22)
   (build-order-tree-node
    'protoss-twilight-council 'Protoss 'protoss-cybernetics-core
    '(protoss-templar-archive-archon protoss-dark-shrine-dt protoss-robotics-facility)
    '(nexus pylon gateway cybernetics-core twilight-council assimilator) '(twilight-council)
    '(stalker adept zealot sentry) '(blink charge resonating-glaives)
    'stalker-colossus 2000 2 150 100 672 0.16)
   (build-order-tree-node
    'protoss-robotics-facility 'Protoss 'protoss-cybernetics-core
    '(protoss-robotics-bay-colossus protoss-twilight-council)
    '(nexus pylon gateway cybernetics-core robotics-facility assimilator) '(robotics-facility)
    '(immortal observer warp-prism stalker zealot) '(gravitic-boosters)
    'stalker-colossus 2000 2 150 100 720 0.18)
   (build-order-tree-node
    'protoss-stargate-air 'Protoss 'protoss-cybernetics-core
    '(protoss-fleet-beacon-carrier protoss-robotics-facility)
    '(nexus pylon gateway cybernetics-core stargate assimilator) '(stargate)
    '(void-ray oracle phoenix stalker adept) '(protoss-air-weapons-1)
    'sky-toss 2000 2 150 150 750 0.14)
   (build-order-tree-node
    'protoss-templar-archive-archon 'Protoss 'protoss-twilight-council
    '(protoss-robotics-bay-colossus)
    '(nexus pylon gateway cybernetics-core twilight-council templar-archive assimilator) '(templar-archive)
    '(archon high-templar zealot stalker immortal) '(psi-storm-tech charge)
    'stalker-colossus 3200 3 150 200 672 0.12)
   (build-order-tree-node
    'protoss-dark-shrine-dt 'Protoss 'protoss-twilight-council
    '(protoss-templar-archive-archon)
    '(nexus pylon gateway cybernetics-core twilight-council dark-shrine assimilator) '(dark-shrine)
    '(dark-templar archon stalker zealot) '(shadow-stride)
    'stalker-colossus 3100 2 150 150 896 0.07)
   (build-order-tree-node
    'protoss-robotics-bay-colossus 'Protoss 'protoss-robotics-facility
    '(protoss-templar-archive-archon)
    '(nexus pylon gateway cybernetics-core robotics-facility robotics-bay assimilator) '(robotics-bay)
    '(colossus disruptor immortal stalker sentry) '(extended-thermal-lance)
    'stalker-colossus 3300 3 150 150 784 0.14)
   (build-order-tree-node
    'protoss-fleet-beacon-carrier 'Protoss 'protoss-stargate-air
    '()
    '(nexus pylon gateway cybernetics-core stargate fleet-beacon assimilator) '(fleet-beacon)
    '(carrier tempest void-ray oracle mothership) '(anion-pulse-crystals)
    'sky-toss 4300 3 300 200 840 0.08)))

(define (normalize-race-sym r)
  (case r
    [(Zerg zerg)       'Zerg]
    [(Terran terran)   'Terran]
    [(Protoss protoss) 'Protoss]
    [else              'Zerg]))

(define (lookup-race-build-order-tree race-sym)
  (case (normalize-race-sym race-sym)
    [(Zerg)    ZERG-BUILD-ORDER-TREE]
    [(Terran)  TERRAN-BUILD-ORDER-TREE]
    [(Protoss) PROTOSS-BUILD-ORDER-TREE]
    [else      ZERG-BUILD-ORDER-TREE]))

(define ZERG-BO-NODE-BY-ID
  (for/hash ([n (in-list ZERG-BUILD-ORDER-TREE)])
    (values (build-order-tree-node-id n) n)))
(define TERRAN-BO-NODE-BY-ID
  (for/hash ([n (in-list TERRAN-BUILD-ORDER-TREE)])
    (values (build-order-tree-node-id n) n)))
(define PROTOSS-BO-NODE-BY-ID
  (for/hash ([n (in-list PROTOSS-BUILD-ORDER-TREE)])
    (values (build-order-tree-node-id n) n)))

(define (lookup-race-bo-node-by-id race-sym)
  (case (normalize-race-sym race-sym)
    [(Zerg)    ZERG-BO-NODE-BY-ID]
    [(Terran)  TERRAN-BO-NODE-BY-ID]
    [(Protoss) PROTOSS-BO-NODE-BY-ID]
    [else      ZERG-BO-NODE-BY-ID]))

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
  (define norm-race (normalize-race-sym race))
  (define tree (lookup-race-build-order-tree norm-race))
  (define node-by-id (lookup-race-bo-node-by-id norm-race))
  (define frame (safe-frame raw-frame))
  (define gas (max 0.0 (safe-real raw-gas 150.0)))

  (define unit-syms (extract-clean-unit-syms raw-units))
  (define direct-bldg-syms (extract-clean-bldg-syms raw-buildings))
  (define upg-syms
    (remove-duplicates
     (append (filter symbol? (safe-list raw-upgrades-or-spells))
             (filter symbol? (safe-list kw-upgrades)))))
  (define implied-from-units-and-bldgs
    (remove-duplicates
     (apply append
            (map implied-prereqs-for-sym
                 (append unit-syms direct-bldg-syms)))))
  (define known-bldgs
    (filter (lambda (b) (not (memq b crippled-buildings)))
            (remove-duplicates (append direct-bldg-syms implied-from-units-and-bldgs))))
  (define gas-bldg-count
    (max (safe-int raw-gas-bldgs 0)
         (count (lambda (b) (memq b '(extractor refinery assimilator))) direct-bldg-syms)
         (if (ormap (lambda (b) (memq b '(extractor refinery assimilator))) known-bldgs) 1 0)))

  (define confirmed-node-ids
    (for/list ([n (in-list tree)]
               #:when (let* ([sbldgs (build-order-tree-node-step-buildings n)]
                             [u-units (build-order-tree-node-unlocked-units n)]
                             [sig-u (if (null? u-units) #f (first u-units))]
                             [bldg-confirmed?
                              (and (not (null? sbldgs))
                                   (andmap (lambda (b) (memq b known-bldgs)) sbldgs))]
                             [unit-confirmed?
                              (and sig-u
                                   (not (memq sig-u '(drone scv probe overlord zergling marine zealot)))
                                   (memq sig-u unit-syms)
                                   (not (ormap (lambda (b) (memq b crippled-buildings)) sbldgs)))])
                        (or bldg-confirmed? unit-confirmed?)))
      (build-order-tree-node-id n)))

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

      (define step-confirmed? (not (not (memq nid confirmed-node-ids))))
      (define parent-confirmed?
        (or (not parent-id)
            (not (not (memq parent-id confirmed-node-ids)))))
      (define frontier-confirmed?
        (and step-confirmed?
             (not (ormap (lambda (ch-id) (memq ch-id confirmed-node-ids))
                         (build-order-tree-node-children-ids n)))))
      (define path-match-count
        (count (lambda (b) (memq b known-bldgs)) pbldgs))
      (define path-ratio
        (/ (exact->inexact path-match-count) (max 1.0 (exact->inexact (length pbldgs)))))

      (define parent-node (and parent-id (hash-ref node-by-id parent-id #f)))
      (define parent-units (if parent-node (build-order-tree-node-unlocked-units parent-node) '()))
      (define node-specific-units
        (let ([diff (filter (lambda (u) (not (memq u parent-units))) u-units)])
          (if (null? diff) u-units diff)))
      (define sig-unit-seen?
        (not (not (ormap (lambda (su) (memq su unit-syms)) node-specific-units))))
      (define matching-units-count
        (count (lambda (u) (memq u unit-syms)) u-units))
      (define matching-upgs-count
        (count (lambda (u) (memq u upg-syms)) u-upgs))

      (define crippled-or-excluded?
        (ormap (lambda (b)
                 (or (memq b crippled-buildings)
                     (memq b excluded-buildings)))
               sbldgs))

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

(define (evaluate-bo-tree-frame-context ctx raw-horizon-sec)
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

  (define raw-weights (make-hash))
  (for ([nf (in-vector node-factors)])
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
    (hash-set! raw-weights nid (max 1e-6 (* base-w timing-gas-lr))))

  (define total-w
    (max 1e-6 (for/sum ([(_k v) (in-hash raw-weights)]) v)))
  (define branch-posteriors
    (for/hash ([(k v) (in-hash raw-weights)])
      (values k (exact->inexact (/ v total-w)))))

  ;; Select active-node-id: highest-posterior confirmed node (or root / highest-posterior node if none confirmed)
  (define root-id (build-order-tree-node-id (first tree)))
  (define-values (active-node-id _best-active-p)
    (let ([candidates (if (null? confirmed-node-ids)
                          (map build-order-tree-node-id tree)
                          confirmed-node-ids)])
      (for/fold ([best-id root-id]
                 [best-p -1.0])
                ([cid (in-list candidates)])
        (define p (hash-ref branch-posteriors cid 0.0))
        (if (> p best-p)
            (values cid p)
            (values best-id best-p)))))
  (define active-node (hash-ref node-by-id active-node-id (first tree)))

  ;; Immediately producible units (0-hop: unlocked on confirmed nodes and active node)
  (define confirmed-Plus-Active
    (remove-duplicates (cons active-node-id confirmed-node-ids)))
  (define immediately-producible-units
    (remove-duplicates
     (append
      (build-order-tree-node-unlocked-units active-node)
      (apply append
             (for/list ([cid (in-list confirmed-Plus-Active)])
               (define cn (hash-ref node-by-id cid #f))
               (if cn (build-order-tree-node-unlocked-units cn) '()))))))

  ;; Horizon-reachable branches in T_R given horizon-sec (0-hop at 15s, 1-hop at 30-60s, 2-hop at 75-130s)
  (define hop-1-ids
    (remove-duplicates
     (apply append
            (for/list ([cid (in-list confirmed-Plus-Active)])
              (define cn (hash-ref node-by-id cid #f))
              (if cn (build-order-tree-node-children-ids cn) '())))))
  (define feasible-hop-1-ids
    (filter (lambda (hid)
              (define hn (hash-ref node-by-id hid #f))
              (and hn
                   (not (ormap (lambda (b)
                                 (or (memq b crippled-buildings)
                                     (memq b excluded-buildings)))
                               (build-order-tree-node-step-buildings hn)))
                   (<= (build-order-tree-node-step-build-frames hn) (+ horizon-frames 260))
                   (<= (build-order-tree-node-step-gas-cost hn)
                       (+ gas (* horizon-sec 2.0 (max 1 gas-bldg-count)) 50.0))))
            hop-1-ids))
  (define hop-2-ids
    (if (> horizon-sec 65.0)
        (remove-duplicates
         (apply append
                (for/list ([h1 (in-list feasible-hop-1-ids)])
                  (define h1n (hash-ref node-by-id h1 #f))
                  (if h1n (build-order-tree-node-children-ids h1n) '()))))
        '()))
  (define feasible-hop-2-ids
    (filter (lambda (hid)
              (define hn (hash-ref node-by-id hid #f))
              (and hn
                   (not (ormap (lambda (b)
                                 (or (memq b crippled-buildings)
                                     (memq b excluded-buildings)))
                               (build-order-tree-node-step-buildings hn)))
                   (<= (build-order-tree-node-step-build-frames hn) (+ horizon-frames 360))))
            hop-2-ids))

  (define raw-reachable-ids
    (cond
      [(<= horizon-sec 20.0) confirmed-Plus-Active]
      [(<= horizon-sec 65.0) (remove-duplicates (append confirmed-Plus-Active feasible-hop-1-ids))]
      [else                  (remove-duplicates (append confirmed-Plus-Active feasible-hop-1-ids feasible-hop-2-ids))]))
  (define reachable-branch-ids
    (sort raw-reachable-ids
          >
          #:key (lambda (id) (hash-ref branch-posteriors id 0.0))))

  (define horizon-reachable-units
    (remove-duplicates
     (append
      (apply append
             (for/list ([rid (in-list reachable-branch-ids)])
               (define rn (hash-ref node-by-id rid #f))
               (if rn (build-order-tree-node-unlocked-units rn) '())))
      immediately-producible-units)))

  (define horizon-reachable-tech-buildings
    (remove-duplicates
     (append
      known-bldgs
      (apply append
             (for/list ([rid (in-list reachable-branch-ids)])
               (define rn (hash-ref node-by-id rid #f))
               (if rn
                   (append (build-order-tree-node-path-buildings rn)
                           (build-order-tree-node-step-buildings rn))
                   '()))))))

  ;; Dominant reachable branch & predicted primary unit
  (define top-reachable-id
    (if (null? reachable-branch-ids) active-node-id (first reachable-branch-ids)))
  (define top-reachable-node
    (hash-ref node-by-id top-reachable-id active-node))
  (define top-unlocked (build-order-tree-node-unlocked-units top-reachable-node))
  (define predicted-primary-unit
    (cond
      [(and (<= horizon-sec 20.0) (not (null? unit-syms)))
       (define combat-seen
         (filter (lambda (u) (not (memq u '(drone scv probe overlord observer larva egg))))
                 unit-syms))
       (if (not (null? combat-seen))
           (first combat-seen)
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
         (argmax (lambda (cid) (hash-ref branch-posteriors cid 0.0)) child-ids)))
  (define recommended-next-build-step
    (cond
      [best-child-id
       (define cn (hash-ref node-by-id best-child-id #f))
       (define sb (if cn (build-order-tree-node-step-buildings cn) '()))
       (define unbuilt (filter (lambda (b) (not (memq b known-bldgs))) sb))
       (cond
         [(not (null? unbuilt)) (first unbuilt)]
         [(not (null? sb))      (first sb)]
         [else                  (first (build-order-tree-node-step-buildings active-node))])]
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
      (normalize-race-sym fallback-race)))

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

  (define prior (max 0.01 (min 0.45 (safe-real raw-prior 0.08))))
  (when (and (null? enemy-units) (null? enemy-bldgs) (not given-tech-obs) (not given-ledger)
             (not given-branch) (eq? given-confirmed? 'auto)
             (null? kw-fake-builds) (null? kw-fake-build-bluffs)
             (not kw-res-cancel-status) (not kw-halluc-bait?)
             (null? kw-idle-bluffs) (not kw-rem-gas) (not kw-rem-gas2)
             (not kw-active-res-cnt) (not kw-res-under-atk?))
    (set! prior (exact->inexact prior)))
  (define odds (/ prior (- 1.0 prior)))
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

  (define hallucinated-units (filter enemy-unit-hallucination? enemy-units))
  (define combat-hallucination-bait?
    (or (and kw-halluc-bait? #t)
        (and (not (null? hallucinated-units))
             (ormap (lambda (hu)
                      (memq (unit-type-sym hu)
                            '(colossus void-ray voidray immortal archon phoenix oracle carrier)))
                    hallucinated-units))))

  (define explicit-idle-tech-bldgs
    (append (safe-list kw-idle-bluffs)
            (filter (lambda (b)
                      (and (hash? b)
                           (not (hash-ref b 'canceled? #f))
                           (not (hash-ref b 'canceled #f))
                           (or (eq? (hash-ref b 'active? 'unspecified) #f)
                               (eq? (hash-ref b 'active 'unspecified) #f)
                               (eq? (hash-ref b 'idle-bluff? #f) #t))))
                    enemy-bldgs)))

  (define rem-gas
    (cond
      [(real? kw-rem-gas)  (safe-real kw-rem-gas 0.0)]
      [(real? kw-rem-gas2) (safe-real kw-rem-gas2 0.0)]
      [(shadow-ledger? ledger) (safe-real (shadow-ledger-unaccounted-gas ledger) 0.0)]
      [else 0.0]))
  (define eff-scouted-us? (or (and scouted-us? #t) (and kw-enemy-scouted-us? #t)))

  (define real-enemy-units
    (filter (lambda (u)
              (and (not (enemy-unit-hallucination? u))
                   (not (enemy-unit-changeling? u))))
            enemy-units))
  (define real-combat-units (filter enemy-combat-unit? real-enemy-units))
  (define obs-upgs (if tech-obs (enemy-tech-observation-observed-upgrades tech-obs) '()))
  (define obs-spells
    (if tech-obs
        (filter (lambda (s) (not (eq? s 'hallucination-scout-or-bait)))
                (enemy-tech-observation-observed-spells tech-obs))
        '()))
  (define has-confirming-evidence?
    (if (boolean? given-confirmed?)
        given-confirmed?
        (or (not (null? active-res))
            res-under-atk?
            (not (null? previews))
            (not (null? real-combat-units))
            (not (null? obs-upgs))
            (not (null? obs-spells)))))

  (define has-candidate-tech-branch?
    (if given-branch
        (not (eq? given-branch 'uncommitted))
        (or (not (null? enemy-bldgs)) (not (null? explicit-idle-tech-bldgs)))))

  (define any-evidence?
    (or (not (null? fake-builds))
        (not (eq? res-cancel-status 'none))
        combat-hallucination-bait?
        (not (null? explicit-idle-tech-bldgs))
        has-candidate-tech-branch?
        has-confirming-evidence?
        (> rem-gas 0.0)
        res-under-atk?))

  ;; Apply positive likelihood ratios
  (when (and any-evidence? (not res-under-atk?))
    (when (not (null? fake-builds))
      (set! odds (* odds 18.0)))
    (when (eq? res-cancel-status 'fake-research-bluff-canceled)
      (set! odds (* odds 15.0)))
    (when (and combat-hallucination-bait? (not has-confirming-evidence?))
      (set! odds (* odds 15.0)))
    (cond
      [(and (not (null? explicit-idle-tech-bldgs))
            (not has-confirming-evidence?)
            (>= rem-gas 225.0))
       (set! odds (* odds (if eff-scouted-us? 16.5 15.2)))]
      [(and has-candidate-tech-branch?
            (not has-confirming-evidence?)
            (>= rem-gas 320.0))
       (set! odds (* odds 14.8))]
      [(and has-candidate-tech-branch?
            (not has-confirming-evidence?)
            (>= rem-gas 225.0))
       (set! odds (* odds 2.5))]))

  ;; Apply negative likelihood ratios (confirming real commitment)
  (when (and any-evidence? (not (null? active-res)))
    (set! odds (* odds 0.08)))
  (when (and any-evidence?
             (or (not (null? previews))
                 (and has-confirming-evidence? (null? fake-builds)
                      (not (eq? res-cancel-status 'fake-research-bluff-canceled)))))
    (set! odds (* odds 0.10)))
  (when (and any-evidence?
             (or res-under-atk?
                 (eq? res-cancel-status 'emergency-research-canceled-under-attack)
                 (eq? res-cancel-status 'research-forced-cancel-under-attack)))
    (set! odds (* odds 0.12)))

  (define post (if any-evidence? (/ odds (+ 1.0 odds)) prior))
  (exact->inexact (max 0.01 (min 0.99 post))))

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
         #:nat-y [nat-y 56])
  (define-values (obs mstate pos-tech-obs pos-ledger)
    (cond
      [(and (number? raw-obs-or-mstate) (symbol? maybe-obs-or-mstate))
       ;; Called as (compute-bayesian-strategic-posteriors frame enemy-race enemy-units enemy-bldgs tech-obs ledger ...)
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

  ;; Feint posterior: base prior 0.10
  (define feint-odds (/ 0.10 0.90))
  (when (and reading (action-lens-reading-feint-or-poke-detected? reading))
    (set! feint-odds (* feint-odds 8.5)))
  (when (and (>= combat-cnt 1) (<= combat-cnt 3) (>= rem-gas 180.0))
    (set! feint-odds (* feint-odds 3.2)))
  (when (>= bluff-post 0.55)
    (set! feint-odds (* feint-odds 2.5)))
  (define feint-post (exact->inexact (max 0.01 (min 0.99 (/ feint-odds (+ 1.0 feint-odds))))))

  ;; Rush posterior: base prior 0.12
  (define rush-odds (/ 0.12 0.88))
  (when (and reading (action-lens-reading-proxy-or-rush-detected? reading))
    (set! rush-odds (* rush-odds 12.0)))
  (when (eq? (shadow-ledger-dark-matter-hypothesis ledger) 'proxy-production-or-all-in)
    (set! rush-odds (* rush-odds 6.0)))
  (when (and (<= frame 2688) (>= combat-cnt 4))
    (set! rush-odds (* rush-odds 4.0)))
  (when (>= (shadow-ledger-predicted-enemy-bases ledger) 3)
    (set! rush-odds (* rush-odds 0.15)))
  (define rush-post (exact->inexact (max 0.01 (min 0.99 (/ rush-odds (+ 1.0 rush-odds))))))

  ;; Hidden expansion posterior: base prior 0.14
  (define exp-odds (/ 0.14 0.86))
  (when (eq? (shadow-ledger-dark-matter-hypothesis ledger) 'hidden-expansion-or-macro-boom)
    (set! exp-odds (* exp-odds 7.5)))
  (when (and (>= rem-min 400.0) (<= combat-cnt 3))
    (set! exp-odds (* exp-odds 3.5)))
  (when (>= rush-post 0.60)
    (set! exp-odds (* exp-odds 0.20)))
  (define hidden-expand-post (exact->inexact (max 0.01 (min 0.99 (/ exp-odds (+ 1.0 exp-odds))))))

  ;; Tech-switch posterior: base prior 0.15
  (define switch-odds (/ 0.15 0.85))
  (when (eq? (shadow-ledger-dark-matter-hypothesis ledger) 'hidden-air-or-cloak-tech-switch)
    (set! switch-odds (* switch-odds 6.5)))
  (when (>= rem-gas 200.0)
    (set! switch-odds (* switch-odds 2.8)))
  (when (>= bluff-post 0.55)
    (set! switch-odds (* switch-odds 3.5)))
  (define tech-switch-post (exact->inexact (max 0.01 (min 0.99 (/ switch-odds (+ 1.0 switch-odds))))))

  (define opp-proj
    (project-opponent-build-order-tree obs horizon-sec
                                       #:enemy-race (or kw-enemy-race (hash-ref obs 'enemy-race #f))
                                       #:mstate mstate))
  (bayesian-strategic-priors
   bluff-prior
   bluff-post
   feint-post
   rush-post
   hidden-expand-post
   tech-switch-post
   (build-order-tree-projection-branch-posteriors opp-proj)))

;; =============================================================================
;; 2d. Zero-Sum Opportunity-Cost / Negative Exclusion & Bayesian Bluff Detector
;; =============================================================================

(define (evaluate-zero-sum-negative-exclusions raw-frame raw-enemy-units raw-enemy-bldgs tech-obs ledger)
  (define frame (safe-frame raw-frame))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define real-enemy-units
    (filter (lambda (u)
              (and (not (enemy-unit-hallucination? u))
                   (not (enemy-unit-changeling? u))))
            enemy-units))
  (define hallucinated-units
    (filter enemy-unit-hallucination? enemy-units))
  (define struct-act
    (analyze-enemy-structure-activity-and-bluffs enemy-bldgs))
  (define active-enemy-bldgs
    (filter (lambda (b)
              (and (not (hash-ref b 'canceled? #f))
                   (not (hash-ref b 'canceled #f))))
            enemy-bldgs))
  (define unit-syms
    (append (map unit-type-sym real-enemy-units)
            (enemy-structure-activity-previewed-units struct-act)))
  (define bldg-syms (map unit-type-sym active-enemy-bldgs))
  (define obs-upgs (enemy-tech-observation-observed-upgrades tech-obs))
  (define obs-spells (enemy-tech-observation-observed-spells tech-obs))
  (define implied-bldgs (enemy-tech-observation-implied-tech-buildings tech-obs))
  (define active-res (enemy-tech-observation-active-research-buildings tech-obs))
  (define pool (append unit-syms bldg-syms obs-upgs obs-spells implied-bldgs))
  (define (any-in-pool? syms)
    (ormap (lambda (s) (memq s pool)) syms))

  (define-values (candidate-branch candidate-exclusions confirming-syms)
    (cond
      ;; Protoss branches
      [(or (any-in-pool? '(templar-archive templar-archives high-templar archon
                           psi-storm psi-storm-tech charge charge-cast blink blink-cast
                           resonating-glaives resonating-glaives-cast))
           (and (memq 'twilight-council bldg-syms)
                (not (any-in-pool? '(dark-shrine dark-templar)))))
       (values 'twilight-templar-ground
               '(stargate-air-rush fleet-beacon-carriers colossus-thermal-lance-rush)
               '(high-templar archon psi-storm psi-storm-tech charge charge-cast
                 blink blink-cast resonating-glaives resonating-glaives-cast chrono-boost-active))]
      [(any-in-pool? '(stargate fleet-beacon phoenix oracle void-ray voidray
                       carrier tempest oracle-revelation pulsar-beam))
       (values 'stargate-sky-fleet
               '(templar-archive-storm dark-shrine-dt-rush colossus-thermal-lance-rush)
               '(phoenix oracle void-ray voidray carrier tempest
                 oracle-revelation pulsar-beam chrono-boost-active))]
      [(any-in-pool? '(robotics-bay robotics-support-bay colossus disruptor
                       immortal robotics-facility))
       (values 'robotics-heavy-siege
               '(stargate-air-rush fleet-beacon-carriers templar-archive-storm)
               '(immortal colossus disruptor extended-thermal-lance chrono-boost-active))]
      ;; Zerg branches
      [(any-in-pool? '(spire greater-spire mutalisk corruptor))
       (values 'spire-air-muta
               '(lurker-den-siege roach-ravager-max-upgrades early-ultralisk-rush)
               '(mutalisk corruptor))]
      [(any-in-pool? '(hydralisk-den lurker-den lurker-den-mp hydralisk lurker lurker-mp lurker-spines))
       (values 'hydra-lurker-den
               '(spire-mutalisk-rush early-brood-lord-rush)
               '(hydralisk lurker lurker-mp lurker-spines grooved-spines muscular-augments lurker-aspect))]
      [(any-in-pool? '(roach-warren roach ravager glial-reconstitution corrosive-bile))
       (values 'roach-ravager-ground
               '(spire-mutalisk-rush baneling-flood-bust)
               '(roach ravager glial-reconstitution corrosive-bile))]
      ;; Terran branches
      [(any-in-pool? '(starport-techlab fusion-core banshee battlecruiser
                       raven banshee-cloak-cast cloaking-field))
       (values 'starport-cloak-or-bc
               '(heavy-bio-stim-timing mass-factory-mech-thor)
               '(banshee battlecruiser raven banshee-cloak-cast cloaking-field))]
      [(any-in-pool? '(factory-techlab armory siege-tank siege-tank-sieged thor hellbat cyclone))
       (values 'factory-mech-siege
               '(bio-stim-marine-marauder-flood battlecruiser-fusion-rush)
               '(siege-tank siege-tank-sieged thor hellbat cyclone siege-mode))]
      [(any-in-pool? '(barracks-techlab stimpack stimpack-cast combat-shield marauder medivac))
       (values 'bio-stim-medivac
               '(battlecruiser-fusion-rush mass-factory-mech-thor)
               '(marauder medivac stimpack stimpack-cast combat-shield))]
      [else
       (values 'uncommitted '() '())]))

  (define macro-exclusions
    (if (and (>= (shadow-ledger-predicted-enemy-bases ledger) 3)
             (< frame 4500))
        '(one-or-two-base-all-in)
        '()))

  (define rem-gas (shadow-ledger-unaccounted-gas ledger))
  (define active-unit-or-spell-pool
    (append unit-syms obs-upgs obs-spells))
  (define confirmed-commitment?
    (or (ormap (lambda (s) (memq s active-unit-or-spell-pool)) confirming-syms)
        (not (null? active-res))
        (enemy-structure-activity-research-under-attack? struct-act)
        (not (null? (enemy-structure-activity-previewed-units struct-act)))
        (< rem-gas 225)))

  (define combat-hallucination-bait?
    (and (not (null? hallucinated-units))
         (ormap (lambda (hu)
                  (memq (unit-type-sym hu)
                        '(colossus void-ray voidray immortal archon phoenix oracle carrier)))
                hallucinated-units)))

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
    (and (not (enemy-structure-activity-research-under-attack? struct-act))
         (>= bluff-posterior 0.55)))

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
     (zero-sum-exclusion-reading candidate-branch
                                 (remove-duplicates (append candidate-exclusions macro-exclusions))
                                 #f
                                 rem-gas
                                 (exact->inexact (max 0.72 (min 0.95 (- 1.0 (* 0.5 bluff-posterior)))))
                                 'zero-sum-gas-committed-orthogonal-excluded)]))

;; =============================================================================
;; 3. Component 1: Shadow Economy & Dark-Matter Resource Ledger
;; =============================================================================

(define (compute-opponent-shadow-ledger mstate raw-frame raw-enemy-units raw-enemy-bldgs
                                        #:base-x [raw-base-x 32]
                                        #:base-y [raw-base-y 32]
                                        #:observed-effects [observed-effects '()]
                                        #:enemy-workers-killed [raw-enemy-workers-killed 0]
                                        #:our-units-lost-value [_our-units-lost-value 0]
                                        #:enemy-units-lost-value [_enemy-units-lost-value 0])
  (define frame (safe-frame raw-frame))
  (define base-x (safe-coord raw-base-x 32))
  (define base-y (safe-coord raw-base-y 32))
  (define enemy-workers-killed (max 0 (safe-int raw-enemy-workers-killed 0)))
  (define enemy-units (if (list? raw-enemy-units) raw-enemy-units '()))
  (define enemy-bldgs (if (list? raw-enemy-bldgs) raw-enemy-bldgs '()))
  (define unit-costs (mirror-mind-state-seen-enemy-unit-costs mstate))
  (define bldg-costs (mirror-mind-state-seen-enemy-bldg-costs mstate))

  (for ([u (in-list enemy-units)])
    (define uid (hash-ref u 'id #f))
    (define utype (unit-type-sym u))
    (define halluc? (enemy-unit-hallucination? u))
    (define changeling? (enemy-unit-changeling? u))
    (when (or halluc? changeling?)
      (set-mirror-mind-state-ever-scouted-by-enemy?! mstate #t))
    (when uid
      (hash-set! unit-costs
                 uid
                 (if (or halluc? changeling?)
                     (cons 0 0)
                     (unit-resource-cost utype)))))

  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define bid (hash-ref b 'id #f))
    (define btype (unit-type-sym b))
    (when bid
      (hash-set! bldg-costs bid (unit-resource-cost btype))))

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

  (define seen-unit-min
    (for/sum ([c (in-hash-values unit-costs)]) (car c)))
  (define seen-unit-gas
    (for/sum ([c (in-hash-values unit-costs)]) (cdr c)))
  (define seen-bldg-min
    (for/sum ([c (in-hash-values bldg-costs)]) (car c)))
  (define seen-bldg-gas
    (for/sum ([c (in-hash-values bldg-costs)]) (cdr c)))

  ;; Infer enemy implied tech buildings, spells & observed upgrades from visible units/buildings
  (define prev-tech-obs (mirror-mind-state-last-tech-observation mstate))
  (define tech-obs
    (infer-enemy-implied-tech-and-upgrades
     enemy-units
     enemy-bldgs
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
  (define visible-bldg-types (map unit-type-sym enemy-bldgs))
  (define unseen-implied-bldgs
    (filter (lambda (b)
              (not (memq b visible-bldg-types)))
            (enemy-tech-observation-implied-tech-buildings tech-obs)))
  (define unseen-implied-min
    (+ (for/sum ([b (in-list unseen-implied-bldgs)])
         (car (unit-resource-cost b)))
       (for/sum ([u (in-list (enemy-tech-observation-observed-upgrades tech-obs))])
         (car (upgrade-resource-cost u)))))
  (define unseen-implied-gas
    (+ (for/sum ([b (in-list unseen-implied-bldgs)])
         (cdr (unit-resource-cost b)))
       (for/sum ([u (in-list (enemy-tech-observation-observed-upgrades tech-obs))])
         (cdr (upgrade-resource-cost u)))))

  (define inferred-worker-spend (* (max 0 (- est-workers 12)) 50))
  (define inferred-supply-spend (* (quotient (max 0 (- est-workers 14)) 8) 100))

  (define accounted-minerals
    (+ 1000 inferred-worker-spend inferred-supply-spend seen-unit-min seen-bldg-min unseen-implied-min))
  (define accounted-gas
    (+ seen-unit-gas seen-bldg-gas unseen-implied-gas))

  (define enemy-townhalls
    (filter (lambda (b)
              (memq (unit-type-sym b)
                    '(nexus command-center orbital-command planetary-fortress
                      hatchery lair hive)))
            enemy-bldgs))

  ;; Pro-Replay Calibration:
  ;; 1. 1-base zero-gas mineral/spine rush (e.g. Dark 12-Pool Spine vs Serral) -> expected-gas = 0
  ;; 2. Law of Negative Base Scouting: when we see explicit 1 gas building (or >= 2 ground combat units
  ;;    with <= 1 gas building), calibrate expected-gas to 1 geyser (starts frame 1200 @ 0.095 G/frame,
  ;;    plus 2nd geyser after frame 2400 @ 0.085 G/frame only when >= 2 gas buildings are seen).
  (define seen-gas-bldgs
    (count (lambda (b) (memq (unit-type-sym b) '(assimilator refinery extractor)))
           enemy-bldgs))
  (define ground-combat-count
    (count (lambda (u)
             (memq (unit-type-sym u)
                   '(zergling baneling roach ravager hydralisk lurker queen
                     marine marauder reaper hellion hellbat widow-mine cyclone siege-tank
                     zealot stalker adept sentry immortal colossus archon)))
           enemy-units))
  (define enemy-combat-count
    (count enemy-combat-unit? enemy-units))
  (define near-base-thresh 32.0)
  (define near-enemy-combat-count
    (count (lambda (u)
             (and (enemy-combat-unit? u)
                  (<= (dist2d base-x base-y
                              (hash-ref u 'x 160)
                              (hash-ref u 'y 160))
                      near-base-thresh)))
           enemy-units))
  (define near-enemy-worker-count
    (count (lambda (u)
             (and (memq (unit-type-sym u) '(drone probe scv))
                  (<= (dist2d base-x base-y
                              (hash-ref u 'x 160)
                              (hash-ref u 'y 160))
                      near-base-thresh)))
           enemy-units))
  (define near-enemy-bldg?
    (ormap (lambda (b)
             (and (not (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
                  (<= (dist2d base-x base-y
                              (hash-ref b 'x 160)
                              (hash-ref b 'y 160))
                      near-base-thresh)))
           enemy-bldgs))
  ;; Exclude non-combat scouts (overlord, overseer, observer, changelings, single scouting worker)
  ;; so routine scouting never triggers false proxy/near-base all-in states!
  (define enemy-near-us?
    (or near-enemy-bldg?
        (>= near-enemy-combat-count 1)
        (>= near-enemy-worker-count 3)))
  (define zero-gas-rush?
    (and (>= frame 1800)
         (<= frame 6048)
         (<= (length enemy-townhalls) 1)
         (= accounted-gas 0)
         (or (>= enemy-combat-count 5)
             (>= near-enemy-worker-count 5))))
  (define calibrated-geyser-mode?
    (or (>= seen-gas-bldgs 1)
        (>= ground-combat-count 2)
        (not enemy-near-us?)))
  (define expected-gas
    (cond
      [zero-gas-rush? 0]
      [calibrated-geyser-mode?
       (define g1 (* (max 0 (- frame 1200)) 0.095))
       (define g2 (if (>= seen-gas-bldgs 2) (* (max 0 (- frame 2400)) 0.085) 0.0))
       (exact-round (+ g1 g2))]
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
            (or enemy-near-us? (>= seen-gas-bldgs 2)))
       'hidden-air-or-cloak-tech-switch]
      [(and (>= frame 2200)
            (<= frame 6048)
            (<= (length enemy-townhalls) 1)
            (>= delta-min 450)
            proxy-attack-near-us?)
       'proxy-production-or-all-in]
      [(and (>= frame 2200)
            (<= (length enemy-townhalls) 1)
            (>= delta-min 450))
       'hidden-expansion-or-macro-boom]
      [(and (>= delta-min 500) (>= delta-gas 100))
       'imminent-fog-timing-wave]
      [else
       'accounted-visible-macro]))

  ;; Predict enemy bases: active visible townhalls + dark-matter imminent expansion
  (define visible-enemy-bases (max 1 (length enemy-townhalls)))
  (define dark-matter-imminent-bases
    (cond
      [(or proxy-attack-near-us? (eq? hypothesis 'proxy-production-or-all-in)) 0]
      [(and (>= frame 5500) (= visible-enemy-bases 1) (>= delta-min 700)) 2]
      [(and (>= frame 3400) (<= visible-enemy-bases 2) (>= delta-min 400)) 1]
      [(and (>= frame 1400) (= visible-enemy-bases 1) (>= delta-min 300)) 1]
      [else 0]))
  (define pred-enemy-bases
    (min 12 (+ visible-enemy-bases dark-matter-imminent-bases)))

  ;; Predict enemy workers based on enemy bases, frame progression, & workers killed
  (define visible-enemy-workers
    (count (lambda (u) (memq (unit-type-sym u) '(drone probe scv))) enemy-units))
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

  (define static-defense?
    (ormap (lambda (e)
             (memq (unit-type-sym e)
                   '(bunker photon-cannon shield-battery spine-crawler
                     planetary-fortress siege-tank siege-tank-sieged)))
           (append enemy-units enemy-bldgs)))

  (define eff-enemy-bases
    (if (> frame 4000) pred-enemy-bases visible-enemy-bases))
  (define initial-verdict
    (cond
      [(or (and (>= pred-enemy-bases 3) (<= enemy-combat-count 4) (not proxy-attack-near-us?))
           (and (eq? hypothesis 'hidden-expansion-or-macro-boom) (<= enemy-combat-count 3)))
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

  (define scout-now?
    (ormap (lambda (u)
             (and (memq (unit-type-sym u)
                        '(probe scv drone overlord overseer reaper adept
                          observer phoenix hallucination mutalisk))
                  (<= (dist2d base-x base-y
                              (hash-ref u 'x 160)
                              (hash-ref u 'y 160))
                      30.0)))
           enemy-units))
  (when scout-now?
    (set-mirror-mind-state-ever-scouted-by-enemy?! mstate #t))
  (define scouted-us? (mirror-mind-state-ever-scouted-by-enemy? mstate))

  (define mobile-poke-count
    (count (lambda (u)
             (and (memq (unit-type-sym u)
                        '(reaper hellion adept stalker zergling roach mutalisk oracle banshee))
                  (<= (dist2d nat-x nat-y
                              (hash-ref u 'x 160)
                              (hash-ref u 'y 160))
                      26.0)))
           enemy-units))
  (define feint-detected?
    (and (>= mobile-poke-count 1)
         (<= (length enemy-units) 4)
         (or (>= (shadow-ledger-unaccounted-gas ledger) 150)
             (>= (shadow-ledger-unaccounted-minerals ledger) 400))))

  (define opponent-turtling?
    (ormap (lambda (e)
             (memq (unit-type-sym e)
                   '(bunker photon-cannon shield-battery spine-crawler
                     planetary-fortress siege-tank siege-tank-sieged)))
           (append enemy-units enemy-bldgs)))

  (define gas-bldgs
    (count (lambda (b)
             (memq (unit-type-sym b) '(refinery assimilator extractor)))
           enemy-bldgs))
  (define early-gas?
    (or (>= gas-bldgs 2)
        (>= (shadow-ledger-unaccounted-gas ledger) 200)))

  (define enemy-townhalls
    (count (lambda (b)
             (memq (unit-type-sym b)
                   '(nexus command-center orbital-command planetary-fortress
                     hatchery lair hive)))
           enemy-bldgs))
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

  ;; Exclude non-combat scouts (overlord, overseer, observer, changeling*) and single scouting workers
  (define near-nat-combat
    (count (lambda (u)
             (and (enemy-combat-unit? u)
                  (or (<= (dist2d nat-x nat-y
                                  (hash-ref u 'x 160)
                                  (hash-ref u 'y 160))
                          28.0)
                      (<= (dist2d base-x base-y
                                  (hash-ref u 'x 160)
                                  (hash-ref u 'y 160))
                          32.0))))
           enemy-units))
  (define near-nat-workers
    (count (lambda (u)
             (and (memq (unit-type-sym u) '(drone probe scv))
                  (or (<= (dist2d nat-x nat-y
                                  (hash-ref u 'x 160)
                                  (hash-ref u 'y 160))
                          28.0)
                      (<= (dist2d base-x base-y
                                  (hash-ref u 'x 160)
                                  (hash-ref u 'y 160))
                          32.0))))
           enemy-units))
  (define proxy-or-rush?
    (or (ormap (lambda (b)
                 (and (not (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
                      (<= (dist2d base-x base-y
                                  (hash-ref b 'x 160)
                                  (hash-ref b 'y 160))
                          38.0)))
               enemy-bldgs)
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
            (or (and (>= pred-enemy-bases 3) (<= enemy-combat-count 4))
                (and (> visible-enemy-townhalls our-bases) (<= enemy-combat-count 3))
                (and (> pred-enemy-bases our-bases) (<= enemy-combat-count 3))
                (and (eq? hyp 'hidden-expansion-or-macro-boom) (<= enemy-combat-count 3))))
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
      [(defend-All-In-Then-Counter-Expand) (max 2 (+ our-bases 1))]
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
    barracks factory starport
    gateway cybernetics-core robotics-facility robotics-bay stargate twilight-council))

(define (unit-to-archetype unit-sym)
  (case unit-sym
    [(marine marauder reaper ghost medivac
      barracks barracks-techlab barracks-reactor ghost-academy)
     'bio-ball]
    [(siege-tank siege-tank-sieged hellion hellbat cyclone thor widow-mine widow-mine-burrowed
      factory factory-techlab armory)
     'mech-siege]
    [(zealot stalker adept sentry colossus immortal archon disruptor
      high-templar dark-templar
      gateway warp-gate cybernetics-core twilight-council robotics-facility robotics-bay templar-archive dark-shrine)
     'stalker-colossus]
    [(void-ray carrier tempest oracle phoenix mothership
      viking banshee battlecruiser liberator liberator-ag raven
      stargate fleet-beacon starport starport-techlab fusion-core)
     'sky-toss]
    [(zergling baneling hydralisk lurker lurker-mp-burrowed queen ultralisk swarm-host
      spawning-pool baneling-nest hydralisk-den lurker-den lurker-den-mp infestation-pit ultralisk-cavern)
     'ling-bane-hydra]
    [(roach ravager roach-warren)
     'roach-ravager]
    [(mutalisk corruptor brood-lord viper spire greater-spire)
     'muta-flock]
    [else
     'early-rush]))

(define (archetype-signature-unit race arch)
  (case arch
    [(bio-ball)          'marauder]
    [(mech-siege)        'siege-tank]
    [(stalker-colossus protoss-deathball) 'stalker]
    [(sky-toss air-fleet) (case race [(Terran) 'banshee] [(Zerg) 'mutalisk] [else 'void-ray])]
    [(ling-bane-hydra)   'hydralisk]
    [(lurker-contain)    'lurker]
    [(zergling-flood)    'zergling]
    [(roach-ravager)     'roach]
    [(muta-flock)        'mutalisk]
    [else                (case race [(Terran) 'marine] [(Protoss) 'zealot] [else 'zergling])]))

(define (race-hidden-gas-threat enemy-race)
  (case enemy-race
    [(Protoss) 'void-ray]
    [(Terran)  'banshee]
    [(Zerg)    'mutalisk]
    [else      'void-ray]))

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
        [(stargate-sky-fleet)      'void-ray]
        [(robotics-heavy-siege)
         (if (memq 'robotics-bay feasible-tech) 'colossus 'immortal)]
        [(roach-ravager-ground)    'ravager]
        [(spire-air-muta)          'mutalisk]
        [(hydra-lurker-den)
         (if (memq 'lurker-den feasible-tech) 'lurker 'hydralisk)]
        [(bio-stim-medivac)        'marauder]
        [(factory-mech-siege)      'siege-tank]
        [(starport-cloak-or-bc)    'banshee]
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
              [(and (memq 'starport feasible-tech) (not (memq 'starport crippled))) 'banshee]
              [(and (memq 'factory feasible-tech) (not (memq 'factory crippled))) 'siege-tank]
              [else 'marauder])]
           [else raw-unit])])))

(define (counter-unit-for-race race target-archetype available-tech raw-minerals raw-gas)
  (define minerals (max 250 (safe-int raw-minerals 300)))
  (define gas (max 150 (safe-int raw-gas 150)))
  (define tree (get-race-counter-tree race))
  (define res
    (resolve-demand-pull tree
                         target-archetype
                         (if (or (not (list? available-tech)) (null? available-tech))
                             ALL-RATIONAL-TECH
                             available-tech)
                         #:minerals minerals
                         #:gas gas))
  (if (hash? res)
      (hash-ref res 'selected-unit 'roach)
      res))

;; What does the opponent predict about US at depth 1 (using what they know
;; about us, including transitive implied tech buildings, spells from our units,
;; and our projected position in the race build-order tree T_R)?
(define (infer-opponent-belief-about-us mstate raw-ally-units raw-ally-bldgs)
  (define ally-units (safe-hash-list raw-ally-units))
  (define ally-bldgs (safe-hash-list raw-ally-bldgs))
  (define our-race (mirror-mind-state-our-race mstate))
  (define our-tech-obs (infer-enemy-implied-tech-and-upgrades ally-units ally-bldgs))
  (define bldg-syms
    (remove-duplicates
     (append (map unit-type-sym ally-bldgs)
             (enemy-tech-observation-implied-tech-buildings our-tech-obs))))
  (define self-bo-proj
    (project-self-build-order-tree
     (hash 'race our-race
           'ally-units ally-units
           'ally-buildings ally-bldgs)
     45.0))
  (define active-bo-node
    (findf (lambda (n)
             (eq? (build-order-tree-node-id n)
                  (build-order-tree-projection-active-node-id self-bo-proj)))
           (lookup-race-build-order-tree our-race)))
  (define visible-arch (classify-enemy-archetype ally-units))
  (cond
    ;; If we have Spire/Stargate (directly or implied by our units), a smart opponent predicts air/tech
    [(or (memq 'spire bldg-syms) (memq 'stargate bldg-syms))
     (if (eq? our-race 'Zerg) 'muta-flock 'sky-toss)]
    [(not (memq visible-arch '(early-rush standard-macro)))
     visible-arch]
    [(memq 'robotics-facility bldg-syms)
     'stalker-colossus]
    [(or (memq 'factory-techlab bldg-syms) (memq 'armory bldg-syms))
     'mech-siege]
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
       [else      'roach-ravager])]))

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
                          #:preprepared-opp-ctx [pre-opp-ctx #f])
  (define depth (max 0 (safe-int raw-depth 0)))
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define our-minerals (max 0 (safe-int raw-our-minerals 300)))
  (define our-gas (max 0 (safe-int raw-our-gas 150)))
  (define our-race (mirror-mind-state-our-race mstate))
  (define enemy-race (mirror-mind-state-enemy-race mstate))
  (define ally-units (safe-hash-list (hash-ref obs 'ally-units '())))
  (define ally-bldgs (safe-hash-list (hash-ref obs 'ally-buildings '())))
  (define enemy-units (safe-hash-list (hash-ref obs 'enemy-units '())))
  (define enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '())))
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
    (compute-enemy-feasible-tech-and-budget mstate))

  ;; Project opponent onto Build-Order Tree T_R at horizon matched to depth
  (define bo-horizon-sec
    (cond
      [(<= depth 0) 15.0]
      [(= depth 1)  30.0]
      [(= depth 2)  60.0]
      [else         105.0]))
  (define opp-bo-proj
    (if pre-opp-ctx
        (evaluate-bo-tree-frame-context pre-opp-ctx bo-horizon-sec)
        (project-opponent-build-order-tree
         (hash-set (hash-set obs 'enemy-race enemy-race)
                   'unaccounted-gas enemy-rem-gas)
         bo-horizon-sec)))
  (define bo-tree-tech
    (let ([reach-bldgs (build-order-tree-projection-horizon-reachable-tech-buildings opp-bo-proj)])
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
     (define obs-enemy-arch (classify-enemy-archetype enemy-units))
     (define obs-enemy-unit
       (or previewed-unit
           (if (and (null? enemy-units) (not (null? enemy-bldgs)))
               (build-order-tree-projection-predicted-primary-unit opp-bo-proj)
               (archetype-signature-unit enemy-race obs-enemy-arch))))
     (define our-d0-unit
       (counter-unit-for-race our-race (unit-to-archetype obs-enemy-unit) our-tech our-minerals our-gas))
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
     (define obs-enemy-arch (classify-enemy-archetype enemy-units))
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
            [(stargate-sky-fleet)      'void-ray]
            [(robotics-heavy-siege)    'colossus]
            [(roach-ravager-ground)    'roach]
            [(spire-air-muta)          'mutalisk]
            [(hydra-lurker-den)        'lurker]
            [(bio-stim-medivac)        'marauder]
            [(factory-mech-siege)      'siege-tank]
            [(starport-cloak-or-bc)    'banshee]
            [else                      (archetype-signature-unit enemy-race obs-enemy-arch)])]
         [(and ledger
               (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                    'hidden-air-or-cloak-tech-switch))
          (race-hidden-gas-threat enemy-race)]
         [(not (eq? committed-branch 'uncommitted))
          (case committed-branch
            [(twilight-templar-ground) 'stalker]
            [(stargate-sky-fleet)      'void-ray]
            [(robotics-heavy-siege)    'immortal]
            [(roach-ravager-ground)    'roach]
            [(spire-air-muta)          'mutalisk]
            [(hydra-lurker-den)        'hydralisk]
            [(bio-stim-medivac)        'marauder]
            [(factory-mech-siege)      'siege-tank]
            [(starport-cloak-or-bc)    'banshee]
            [else                      (archetype-signature-unit enemy-race obs-enemy-arch)])]
         [(or (memq 'spire implied-bldgs) (memq 'greater-spire implied-bldgs)) 'mutalisk]
         [(or (memq 'hydralisk-den implied-bldgs) (memq 'lurker-den implied-bldgs)) 'hydralisk]
         [(memq 'roach-warren implied-bldgs) 'roach]
         [(memq 'stargate implied-bldgs) 'void-ray]
         [(or (memq 'robotics-facility implied-bldgs) (memq 'twilight-council implied-bldgs)) 'stalker]
         [(memq 'starport-techlab implied-bldgs) 'banshee]
         [(or (memq 'factory-techlab implied-bldgs) (memq 'armory implied-bldgs)) 'siege-tank]
         [(memq 'barracks implied-bldgs) 'marauder]
         [(and reading (action-lens-reading-opponent-turtling? reading))
          (case enemy-race
            [(Terran)  'siege-tank]
            [(Protoss) 'colossus]
            [(Zerg)    'lurker]
            [else      'siege-tank])]
         [(not (null? enemy-bldgs))
          (build-order-tree-projection-predicted-primary-unit opp-bo-proj)]
         [else
          (archetype-signature-unit enemy-race obs-enemy-arch)]))
     (define d1-enemy-unit
       (if bluff?
           raw-d1-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-d1-enemy-unit enemy-feasible-tech zs-reading tech-obs)))
     (define d1-enemy-arch (unit-to-archetype d1-enemy-unit))
     (define our-d1-unit
       (counter-unit-for-race our-race d1-enemy-arch our-tech our-minerals our-gas))
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
                                 enemy-rem-gas)]))
     (define d2-enemy-unit
       (if bluff?
           raw-d2-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-d2-enemy-unit bo-tree-tech zs-reading tech-obs)))
     (define d2-enemy-arch (unit-to-archetype d2-enemy-unit))
     (define our-d2-unit
       (counter-unit-for-race our-race d2-enemy-arch our-tech our-minerals our-gas))
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
                              enemy-rem-gas))
     (define dk-enemy-unit
       (if bluff?
           raw-dk-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-dk-enemy-unit bo-tree-tech zs-reading tech-obs)))
     (define dk-enemy-arch (unit-to-archetype dk-enemy-unit))
     (define our-dk-unit
       (counter-unit-for-race our-race dk-enemy-arch our-tech our-minerals our-gas))
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

;; Build the full hierarchy of depth nodes from 0 up to max-depth (at least 4)
(define (build-mirror-hierarchy mstate raw-obs
                                #:max-depth [max-depth #f]
                                #:our-tech [our-tech ALL-RATIONAL-TECH]
                                #:our-minerals [raw-our-minerals 300]
                                #:our-gas [raw-our-gas 150]
                                #:sync-observations? [sync-obs? #t]
                                #:preprepared-opp-ctx [pre-opp-ctx #f])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define our-minerals (max 0 (safe-int raw-our-minerals 300)))
  (define our-gas (max 0 (safe-int raw-our-gas 150)))
  ;; Ensure base-layer observations/implications & zero-sum exclusions are synchronized with `obs`
  (when (and sync-obs?
             (or (hash-has-key? obs 'enemy-units)
                 (hash-has-key? obs 'enemy-buildings)
                 (hash-has-key? obs 'effects)))
    (define frame (safe-frame (hash-ref obs 'frame 0)))
    (define e-units (safe-hash-list (hash-ref obs 'enemy-units '())))
    (define e-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '())))
    (define effs (safe-list (hash-ref obs 'effects '())))
    (define prev-tech (mirror-mind-state-last-tech-observation mstate))
    (define tech-obs
      (infer-enemy-implied-tech-and-upgrades
       e-units
       e-bldgs
       #:observed-effects effs
       #:destroyed-enemy-bldgs (mirror-mind-state-destroyed-enemy-bldgs mstate)
       #:pre-destruction-unit-ids (mirror-mind-state-pre-destruction-unit-ids mstate)
       #:historical-upgrades (if prev-tech
                                 (enemy-tech-observation-observed-upgrades prev-tech)
                                 '())
       #:historical-implied-buildings
       (if (and prev-tech (null? e-units) (null? e-bldgs))
           (enemy-tech-observation-implied-tech-buildings prev-tech)
           '())))
    (set-mirror-mind-state-last-tech-observation! mstate tech-obs)
    (define zs-reading
      (evaluate-zero-sum-negative-exclusions
       frame e-units e-bldgs tech-obs (mirror-mind-state-last-shadow-ledger mstate)))
    (set-mirror-mind-state-last-zero-sum-reading! mstate zs-reading))

  (define shared-opp-ctx
    (or pre-opp-ctx
        (let-values ([(_ft _rmin enemy-rem-gas _ct _ex _bl)
                      (compute-enemy-feasible-tech-and-budget mstate)])
          (prepare-opponent-bo-tree-context
           (hash-set (hash-set obs 'enemy-race (mirror-mind-state-enemy-race mstate))
                     'unaccounted-gas enemy-rem-gas)))))

  (define top-d
    (if (and max-depth (finite-real? max-depth))
        (max (safe-int max-depth 5) (add1 (mirror-mind-state-inferred-opponent-depth mstate)))
        (max 5
             (mirror-mind-state-default-depth mstate)
             (add1 (mirror-mind-state-inferred-opponent-depth mstate)))))
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
                                        #:preprepared-opp-ctx shared-opp-ctx)])
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
  (define base-arch (classify-enemy-archetype enemy-units))
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
       (define cur-arch (classify-enemy-archetype enemy-units))
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
(define (score-depth-predictions depth-predictions
                                 raw-current-enemy-units
                                 #:past-enemy-units [raw-past-enemy-units '()]
                                 #:current-enemy-bldgs [raw-current-enemy-bldgs '()]
                                 #:transition-bonus [raw-transition-bonus 2.5])
  (define current-enemy-units (safe-hash-list raw-current-enemy-units))
  (define past-enemy-units (safe-hash-list raw-past-enemy-units))
  (define current-enemy-bldgs (safe-hash-list raw-current-enemy-bldgs))
  (define transition-bonus (max 1.0 (safe-real raw-transition-bonus 2.5)))
  (define noncombat '(drone probe scv overlord observer larva egg))
  (define non-tech-bldgs
    '(nexus command-center orbital-command planetary-fortress hatchery lair hive
      pylon supply-depot supply-depot-lowered assimilator refinery extractor
      creep-tumor creep-tumor-burrowed creep-tumor-queen
      photon-cannon bunker missile-turret spine-crawler spore-crawler shield-battery
      gateway warp-gate barracks spawning-pool cybernetics-core forge engineering-bay))
  (define tier1-mineral-units '(zergling marine zealot))
  (define (real-combat? u)
    (and (not (memq (unit-type-sym u) noncombat))
         (not (enemy-unit-hallucination? u))
         (not (enemy-unit-changeling? u))))
  (define (tech-bldg? b)
    (not (memq (unit-type-sym b) non-tech-bldgs)))
  (define cur-combat
    (append (filter real-combat? current-enemy-units)
            (filter tech-bldg? current-enemy-bldgs)))
  (define past-combat (filter real-combat? past-enemy-units))
  (define past-ids
    (filter values (map (lambda (u) (hash-ref u 'id #f)) past-combat)))
  (define past-types (remove-duplicates (map unit-type-sym past-combat)))
  (define past-archs (remove-duplicates (map unit-to-archetype past-types)))

  (define has-gas-tech-now?
    (ormap (lambda (u)
             (> (cdr (unit-resource-cost (unit-type-sym u))) 0))
           cur-combat))
  (define any-novel-arch-now?
    (and (not (null? past-archs))
         (ormap (lambda (u)
                  (not (memq (unit-to-archetype (unit-type-sym u)) past-archs)))
                cur-combat)))

  ;; Compute marginal resource + transition weight for each current enemy combat unit / tech building
  (define unit-weights
    (for/list ([u (in-list cur-combat)])
      (define utype (unit-type-sym u))
      (define uarch (unit-to-archetype utype))
      (define uid (hash-ref u 'id #f))
      (define c (unit-resource-cost utype))
      (define raw-val (max 75.0 (+ (car c) (* 1.8 (cdr c)))))
      (define pre-existing-id? (and uid (member uid past-ids)))
      (define novel-tech?
        (if (not (null? past-combat))
            (and (not (memq utype past-types))
                 (not (memq uarch past-archs)))
            (and has-gas-tech-now? (> (cdr c) 0))))
      (define tier1-remnant?
        (or (and has-gas-tech-now?
                 (memq utype tier1-mineral-units)
                 (= (cdr c) 0))
            (and any-novel-arch-now?
                 (memq uarch past-archs))))
      (define w
        (cond
          [pre-existing-id? (* 0.02 raw-val)]
          [novel-tech?      (* transition-bonus raw-val)]
          [tier1-remnant?   (* 0.12 raw-val)]
          [else             raw-val]))
      (list utype uarch w)))

  (define total-weight
    (max 1.0 (for/sum ([uw (in-list unit-weights)]) (third uw))))

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
    (define matched-w
      (for/sum ([uw (in-list unit-weights)])
        (define utype (first uw))
        (define uarch (second uw))
        (define w (third uw))
        (cond
          [(eq? utype pred-u)    w]
          [(eq? uarch pred-arch) (* 0.80 w)]
          [else                  0.0])))
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
      [(and (memq pred-arch '(sky-toss muta-flock))
            (memq true-arch '(sky-toss muta-flock)))
       0.75]
      [(and (eq? pred-arch 'early-rush)
            (memq true-arch '(sky-toss muta-flock mech-siege stalker-colossus)))
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
(define (horizon-sec->optimal-cognitive-depth raw-horizon-sec [raw-obs (hash)])
  (define h-sec (max 1.0 (safe-real raw-horizon-sec 60.0)))
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '())))
  (define enemy-units (safe-hash-list (hash-ref obs 'enemy-units '())))
  (define base-x (safe-coord (hash-ref obs 'base-x 32) 32))
  (define base-y (safe-coord (hash-ref obs 'base-y 32) 32))
  (define unacc-gas (safe-real (hash-ref obs 'unaccounted-gas 0.0) 0.0))
  (define preview-or-completed-morph?
    (or (and (hash-ref obs 'preview-or-completed-tech? #f) #t)
        (for/or ([b (in-list enemy-bldgs)]
                 #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
          (define p (hash-ref b 'preview-unit (hash-ref b 'unit-preview #f)))
          (and (symbol? p) (not (eq? p 'null))))))
  (define enemy-scouted-us?
    (or (and (hash-ref obs 'enemy-scouted-us? #f) #t)
        (ormap (lambda (e)
                 (<= (dist2d base-x base-y (hash-ref e 'x 160) (hash-ref e 'y 160)) 24))
               enemy-units)))
  (define transition-or-bluff-signal?
    (or (and (hash-ref obs 'transition-signal? #f) #t)
        (and (hash-ref obs 'bluff-suspected? #f) #t)
        (>= unacc-gas 175.0)
        enemy-scouted-us?
        (for/or ([b (in-list enemy-bldgs)])
          (or (hash-ref b 'canceled? #f)
              (hash-ref b 'canceled #f)
              (hash-ref b 'research-canceled? #f)
              (< (safe-real (hash-ref b 'build-progress 1.0) 1.0) 1.0)))))
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
     (if (and (hash-ref obs 'committed-low-gas? #f) (not transition-or-bluff-signal?))
         2
         3)]
    [else
     3]))

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
                                         #:preprepared-opp-ctx [pre-opp-ctx #f])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define frame (safe-frame (hash-ref obs 'frame 2400)))
  (define minerals (max 0 (safe-int (hash-ref obs 'minerals 300) 300)))
  (define gas (max 0 (safe-int (hash-ref obs 'gas 150) 150)))
  (define ally-units (safe-hash-list (hash-ref obs 'ally-units '())))
  (define ally-bldgs (safe-hash-list (hash-ref obs 'ally-buildings '())))
  (define enemy-units (safe-hash-list (hash-ref obs 'enemy-units '())))
  (define enemy-bldgs (safe-hash-list (hash-ref obs 'enemy-buildings '())))
  (define mstate
    (if (mirror-mind-state? maybe-mstate)
        maybe-mstate
        (make-mirror-mind-state
         #:our-race (normalize-race-sym (hash-ref obs 'race (hash-ref obs 'our-race 'Zerg)))
         #:enemy-race (normalize-race-sym (hash-ref obs 'enemy-race 'Protoss))
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
  (define bayes-priors
    (compute-bayesian-strategic-posteriors
     frame enemy-race enemy-units enemy-bldgs tech-obs ledger
     #:base-x (safe-coord (hash-ref obs 'base-x 32) 32)
     #:base-y (safe-coord (hash-ref obs 'base-y 32) 32)
     #:nat-x (safe-coord (hash-ref obs 'natural-x 50) 50)
     #:nat-y (safe-coord (hash-ref obs 'natural-y 56) 56)))
  (define bluff-post (bayesian-strategic-priors-bluff-posterior bayes-priors))
  (define previewed-unit
    (for/or ([b (in-list enemy-bldgs)]
             #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
      (define p (hash-ref b 'preview-unit (hash-ref b 'unit-preview #f)))
      (and (symbol? p) (not (eq? p 'null)) p)))

  (define our-tech-syms (map unit-type-sym ally-bldgs))
  (define eff-our-tech (if (null? our-tech-syms) ALL-RATIONAL-TECH our-tech-syms))
  (define enriched-obs
    (hash-set (hash-set (hash-set (hash-set obs 'our-race our-race)
                                  'enemy-race enemy-race)
                        'unaccounted-gas unacc-gas)
              'bluff-suspected? bluff?))
  (define nodes
    (if (and (list? pre-nodes) (pair? pre-nodes))
        pre-nodes
        (build-mirror-hierarchy mstate enriched-obs
                                #:max-depth 4
                                #:our-tech eff-our-tech
                                #:our-minerals minerals
                                #:our-gas gas)))
  (define opp-ctx (or pre-opp-ctx (prepare-opponent-bo-tree-context enriched-obs)))
  (define self-ctx (or pre-self-ctx (prepare-self-bo-tree-context enriched-obs)))
  (define scout-freshness
    (if (and (null? enemy-units) (null? enemy-bldgs)) 0.55 0.88))
  (define h-list
    (if (and (list? horizons-sec) (not (null? horizons-sec)))
        horizons-sec
        MIRROR-HORIZON-SNAPSHOTS-SEC))

  (for/list ([raw-h (in-list h-list)])
    (define h-sec (max 1.0 (safe-real raw-h 60.0)))
    (define h-frames (exact-round (* h-sec 22.4)))
    (define opp-proj (evaluate-bo-tree-frame-context opp-ctx h-sec))
    (define self-proj (evaluate-bo-tree-frame-context self-ctx h-sec))
    (define post-hash (build-order-tree-projection-branch-posteriors opp-proj))
    (define max-post
      (apply max 0.25 (hash-values post-hash)))
    (define branch-entropy (min 1.0 (max 0.0 (- 1.0 max-post))))
    (define opt-d (horizon-sec->optimal-cognitive-depth h-sec enriched-obs))
    (define cert
      (horizon-sec->calibrated-certainty h-sec branch-entropy bluff-post scout-freshness))
    (define d-node
      (or (findf (lambda (n) (= (depth-node-depth n) opt-d)) nodes)
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
           [(and (not (null? enemy-units))
                 (memq (archetype-signature-unit enemy-race (classify-enemy-archetype enemy-units))
                       imm-units))
            (archetype-signature-unit enemy-race (classify-enemy-archetype enemy-units))]
           [(memq primary-bo-u imm-units) primary-bo-u]
           [(not (null? imm-units)) (last imm-units)]
           [else raw-pred-u])]
        [(and bluff? (>= opt-d 2))
         (race-hidden-gas-threat enemy-race)]
        [(memq raw-pred-u reach-units)
         raw-pred-u]
        [else
         (define raw-arch (unit-to-archetype raw-pred-u))
         (or (findf (lambda (u) (eq? (unit-to-archetype u) raw-arch)) reach-units)
             primary-bo-u)]))
    (define pred-arch (unit-to-archetype pred-enemy-u))
    (define self-reach-tech
      (let ([rt (build-order-tree-projection-horizon-reachable-tech-buildings self-proj)])
        (if (null? rt) eff-our-tech (remove-duplicates (append eff-our-tech rt)))))
    (define our-counter
      (counter-unit-for-race our-race pred-arch self-reach-tech minerals gas))
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
         #:our-race (normalize-race-sym (hash-ref obs 'race (hash-ref obs 'our-race 'Zerg)))
         #:enemy-race (normalize-race-sym (hash-ref obs 'enemy-race 'Protoss))
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
     (define committed-no-transition?
       (and (not depth-accuracy-scores)
            (eq? probe-resp 'untested)
            (= def-d 2)
            zs-reading
            (not (eq? (zero-sum-exclusion-reading-committed-primary-branch zs-reading) 'uncommitted))
            (not (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading))
            (< (zero-sum-exclusion-reading-remaining-gas-budget zs-reading) 150)
            (not (and reading
                      (or (action-lens-reading-opponent-scouted-us? reading)
                          (action-lens-reading-feint-or-poke-detected? reading))))
            (not (and ledger
                      (eq? (shadow-ledger-dark-matter-hypothesis ledger)
                           'hidden-air-or-cloak-tech-switch)))))
     (define chosen
       (cond
         ;; If explicit depth-accuracy-scores were supplied, or if any depth d* in 0..5
         ;; has a clear empirical accuracy lead (>= +0.06 over default depth when untested,
         ;; or >= +0.10 overall), switch directly to best-d!
         [(and depth-accuracy-scores (>= best-acc def-acc))
          best-d]
         [(and (eq? probe-resp 'untested)
               (>= overall 0.45)
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
              (= opp-d 2)
              (and (>= acc-2 0.70) (> acc-3 (+ (max def-acc acc-2) 0.06))))
          3]
         [(eq? probe-resp 'direct-counter) 2]
         ;; When opponent is locked into a confirmed build-order branch with < 150G remaining
         ;; and no bluff/scout/transition signal is active, favor Depth 1 committed production!
         [committed-no-transition? 1]
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
(define (compute-mirror-toolbox-allocation mstate raw-ally-units raw-enemy-units
                                           #:crisis? [crisis? #f])
  (define ally-units (safe-hash-list raw-ally-units))
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define worker-syms '(drone scv probe))
  (define ally-combat
    (filter (lambda (u) (not (memq (unit-type-sym u) worker-syms))) ally-units))
  (define enemy-combat
    (filter (lambda (u) (not (memq (unit-type-sym u) worker-syms))) enemy-units))
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
  (define all-enemy (append enemy-units enemy-bldgs))
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

  (define still-pending '())
  (for ([fc (in-list pending)])
    (define fc-depth (mirror-forecast-depth fc))
    (define pred-unit (mirror-forecast-predicted-enemy-unit fc))
    (define tx (mirror-forecast-target-x fc))
    (define ty (mirror-forecast-target-y fc))
    (define deadline (mirror-forecast-deadline-frame fc))

    (define strat-score (hash-ref unit-score-map pred-unit 0.0))
    (define strat-hit? (>= strat-score 0.35))

    (define tact-hit?
      (ormap (lambda (e)
               (<= (dist2d tx ty (hash-ref e 'x 160) (hash-ref e 'y 160)) 24))
             all-enemy))

    (cond
      [(or strat-hit? tact-hit?)
       (define new-strat
         (+ (* (- 1.0 alpha) (mirror-mind-state-strategic-accuracy mstate))
            (* alpha (if strat-hit? (max 0.85 strat-score) 0.75))))
       (define new-tact
         (+ (* (- 1.0 alpha) (mirror-mind-state-tactical-accuracy mstate))
            (* alpha (if tact-hit? 1.0 0.75))))
       (set-mirror-mind-state-strategic-accuracy! mstate (min 0.98 new-strat))
       (set-mirror-mind-state-tactical-accuracy! mstate (min 0.98 new-tact))
       ;; Update per-depth accuracy for `fc-depth` weighted by resource/transition match quality
       (define old-d-acc (safe-real (hash-ref d-acc fc-depth 0.65) 0.65))
       (define hit-credit (if strat-hit? (max 0.85 strat-score) 0.82))
       (hash-set! d-acc fc-depth (min 0.98 (+ (* (- 1.0 alpha) old-d-acc) (* alpha hit-credit))))
       (set-mirror-mind-state-resolved-hits!
        mstate (add1 (mirror-mind-state-resolved-hits mstate)))
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

(define (step-mirror-mind-predictor! mstate raw-obs)
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
    (for/or ([e (in-list (append enemy-units enemy-bldgs))])
      (case (unit-type-sym e)
        [(probe zealot stalker sentry adept high-templar dark-templar archon
          immortal colossus void-ray carrier oracle phoenix nexus pylon gateway
          cybernetics-core photon-cannon stargate robotics-facility)
         'Protoss]
        [(scv marine marauder reaper ghost hellion widow-mine cyclone siege-tank
          thor viking medivac banshee battlecruiser command-center orbital-command
          supply-depot barracks factory starport bunker)
         'Terran]
        [(drone zergling baneling queen roach ravager hydralisk lurker mutalisk
          corruptor ultralisk brood-lord overlord overseer hatchery lair hive
          spawning-pool roach-warren hydralisk-den spire)
         'Zerg]
        [else #f])))
  (when detected-enemy-race
    (set-mirror-mind-state-enemy-race! mstate detected-enemy-race))

  ;; 1. Resolve any pending forecasts against current observations
  (resolve-pending-forecasts! mstate frame enemy-units enemy-bldgs)

  ;; 2. Compute Opponent Shadow Economy & Dark-Matter Resource Ledger
  (define ledger
    (compute-opponent-shadow-ledger mstate frame enemy-units enemy-bldgs
                                    #:base-x base-x #:base-y base-y
                                    #:observed-effects effects))

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
    (evaluate-zero-sum-negative-exclusions
     frame enemy-units enemy-bldgs
     (mirror-mind-state-last-tech-observation mstate)
     ledger))
  (set-mirror-mind-state-last-zero-sum-reading! mstate zs-reading)
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

  ;; 5. Build full recursive k-level hierarchy (d = 0, 1, 2, 3, 4, ...) and select active depth
  (define our-tech-syms (map unit-type-sym ally-bldgs))
  (define eff-tech (if (null? our-tech-syms) ALL-RATIONAL-TECH our-tech-syms))
  (define active-d (choose-optimal-mirror-depth mstate))
  (define bo-obs
    (hash-set (hash-set (hash-set sanitized-obs 'our-race (mirror-mind-state-our-race mstate))
                        'enemy-race (mirror-mind-state-enemy-race mstate))
              'unaccounted-gas (shadow-ledger-unaccounted-gas ledger)))
  (define self-bo-ctx (prepare-self-bo-tree-context bo-obs))
  (define opp-bo-ctx (prepare-opponent-bo-tree-context bo-obs))
  (define nodes
    (build-mirror-hierarchy mstate sanitized-obs
                            #:max-depth (max 5 active-d)
                            #:our-tech eff-tech
                            #:our-minerals minerals
                            #:our-gas gas
                            #:sync-observations? #f
                            #:preprepared-opp-ctx opp-bo-ctx))
  (define active-node
    (or (findf (lambda (n) (= (depth-node-depth n) active-d)) nodes)
        (last nodes)))
  (define d0-node (first nodes))

  (define pred-enemy-unit (depth-node-predicted-enemy-unit active-node))
  (define chosen-counter-unit
    (if (or (eq? (mirror-mind-state-trust-mode mstate) 'skeptical-observational-fallback)
            (eq? (mirror-toolbox-allocation-toolbox-role alloc) 'survival-fundamentals-only))
        (depth-node-our-response-unit d0-node)
        (depth-node-our-response-unit active-node)))
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
  (define self-bo-proj (evaluate-bo-tree-frame-context self-bo-ctx 60.0))
  (define opp-bo-proj (evaluate-bo-tree-frame-context opp-bo-ctx 60.0))
  (define horizon-snapshots
    (predict-multi-horizon-snapshots bo-obs mstate MIRROR-HORIZON-SNAPSHOTS-SEC
                                     #:precomputed-nodes nodes
                                     #:preprepared-self-ctx self-bo-ctx
                                     #:preprepared-opp-ctx opp-bo-ctx))

  ;; 6. Enqueue timestamped forecasts for all depths 0..5 so we can compare
  ;;    which depth level best predicts this specific opponent!
  (when (< (length (mirror-mind-state-pending-forecasts mstate)) 18)
    (define new-fcs
      (for/list ([n (in-list nodes)]
                 #:when (and (>= (depth-node-depth n) 0)
                             (<= (depth-node-depth n) 5)))
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
    (list 'mirror-bo-tree-prediction
          (build-order-tree-projection-active-node-id self-bo-proj)
          (build-order-tree-projection-active-node-id opp-bo-proj)
          (build-order-tree-projection-predicted-primary-unit opp-bo-proj)
          (build-order-tree-projection-recommended-next-build-step self-bo-proj)))
  (define horizon-curve-directive
    (cons 'mirror-horizon-curve
          (for/list ([s (in-list horizon-snapshots)])
            (list (exact-round (horizon-snapshot-forecast-horizon-sec s))
                  (horizon-snapshot-forecast-optimal-depth s)
                  (exact-round (* 100.0 (horizon-snapshot-forecast-certainty-level s)))
                  (horizon-snapshot-forecast-predicted-enemy-unit s)
                  (horizon-snapshot-forecast-our-counter-unit s)))))

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
    (if (emit-top-level-bo-directives? raw-obs)
        (list bo-tree-directive horizon-curve-directive)
        (list (list 'log bo-tree-directive horizon-curve-directive))))

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
               #:when (let ([dt (safe-int (hash-ref e 'display-type 1) 1)]
                            [cs (safe-int (hash-ref e 'cloak-state 0) 0)]
                            [shim? (hash-ref e 'is-shimmer? #f)]
                            [bur? (or (hash-ref e 'burrowed #f)
                                      (hash-ref e 'is-burrowed? #f)
                                      (memq (unit-type-sym e)
                                            '(roach-burrowed infestor-burrowed lurker-burrowed
                                              widow-mine-burrowed swarm-host-burrowed
                                              baneling-burrowed)))])
                        (or shim? (= dt SC2-SHIMMER-DISPLAY-TYPE-HIDDEN) (= cs 2) bur?)))
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

