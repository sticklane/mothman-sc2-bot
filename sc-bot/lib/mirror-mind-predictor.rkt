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
         (struct-out mirror-mind-state)
         make-mirror-mind-state
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

(define (unit-type-sym u)
  (define t (if (hash? u) (hash-ref u 'type 'unknown) 'unknown))
  (if (symbol? t) t (string->symbol (format "~a" t))))

(define (finite-real? v)
  (and (real? v) (not (nan? v)) (not (infinite? v))))

(define (safe-real v [fallback 0.0])
  (cond
    [(finite-real? v) (exact->inexact v)]
    [(finite-real? fallback) (exact->inexact fallback)]
    [else 0.0]))

(define (safe-int v [fallback 0])
  (cond
    [(finite-real? v) (exact-round v)]
    [(finite-real? fallback) (exact-round fallback)]
    [else 0]))

(define (safe-frame f)
  (max 0 (safe-int f 0)))

(define (safe-coord v [fallback 160])
  (safe-int v fallback))

(define (safe-list xs)
  (if (list? xs) xs '()))

(define (safe-hash-list xs)
  (if (list? xs) (filter hash? xs) '()))

(define (dist2d x1 y1 x2 y2)
  (define sx1 (safe-real x1 32.0))
  (define sy1 (safe-real y1 32.0))
  (define sx2 (safe-real x2 160.0))
  (define sy2 (safe-real y2 160.0))
  (sqrt (+ (sqr (- sx2 sx1)) (sqr (- sy2 sy1)))))

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
         #:historical-upgrades [raw-historical-upgrades '()])
  (define enemy-units (safe-hash-list raw-enemy-units))
  (define enemy-bldgs (safe-hash-list raw-enemy-bldgs))
  (define our-upgrade-tier (safe-int raw-our-upgrade-tier 0))
  (define observed-effects (safe-list raw-observed-effects))
  (define destroyed-enemy-bldgs (safe-list raw-destroyed-enemy-bldgs))
  (define pre-destruction-unit-ids (safe-list raw-pre-destruction-unit-ids))
  (define historical-upgrades (safe-list raw-historical-upgrades))
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

    ;; Air threat trigger
    (when (memq utype '(mutalisk corruptor brood-lord broodlord viper
                        viking viking-fighter medivac liberator banshee raven battlecruiser
                        phoenix oracle void-ray voidray carrier tempest mothership))
      (set! req-aa? #t)))

  ;; 3. Inspect enemy buildings for active research, Chrono Boost, & implied detection/anti-air
  (for ([b (in-list enemy-bldgs)]
        #:unless (or (hash-ref b 'canceled? #f) (hash-ref b 'canceled #f)))
    (define btype (unit-type-sym b))
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
;; 2c. Zero-Sum Opportunity-Cost / Negative Exclusion & Bluff Detector
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

  (define bluff-suspected?
    (and (not (enemy-structure-activity-research-under-attack? struct-act))
         (or (enemy-structure-activity-bluff-or-feint-suspected? struct-act)
             (and (not (eq? candidate-branch 'uncommitted))
                  (not confirmed-commitment?)
                  (>= rem-gas 225))
             (and combat-hallucination-bait?
                  (not confirmed-commitment?)))))

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
                                 0.30
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
                                 0.90
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
;; about us, including transitive implied tech buildings and spells from our units)?
(define (infer-opponent-belief-about-us mstate raw-ally-units raw-ally-bldgs)
  (define ally-units (safe-hash-list raw-ally-units))
  (define ally-bldgs (safe-hash-list raw-ally-bldgs))
  (define our-race (mirror-mind-state-our-race mstate))
  (define our-tech-obs (infer-enemy-implied-tech-and-upgrades ally-units ally-bldgs))
  (define bldg-syms
    (remove-duplicates
     (append (map unit-type-sym ally-bldgs)
             (enemy-tech-observation-implied-tech-buildings our-tech-obs))))
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
;; and observed spells/upgrades) and `zero-sum-exclusion-reading` (including
;; bluff detection) through Depth 1, Depth 2, and all higher depths d >= 3.
(define (predict-at-depth mstate raw-depth raw-obs
                          #:our-tech [our-tech ALL-RATIONAL-TECH]
                          #:our-minerals [raw-our-minerals 300]
                          #:our-gas [raw-our-gas 150])
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
  (define-values (enemy-feasible-tech enemy-rem-min enemy-rem-gas _crippled _excl bluff?)
    (compute-enemy-feasible-tech-and-budget mstate))

  (cond
    ;; -------------------------------------------------------------------------
    ;; DEPTH 0: Pure Observational Baseline (No theory of mind)
    ;; -------------------------------------------------------------------------
    [(<= depth 0)
     (define obs-enemy-arch (classify-enemy-archetype enemy-units))
     (define obs-enemy-unit
       (or previewed-unit
           (archetype-signature-unit enemy-race obs-enemy-arch)))
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
    ;;   their feasible tech tree, crippled buildings, and zero-sum exclusions,
    ;;   OR unmasking a suspected tech bluff!")
    ;; -------------------------------------------------------------------------
    [(= depth 2)
     (define opp-belief-arch
       (infer-opponent-belief-about-us mstate ally-units ally-bldgs))
     (define raw-d2-enemy-unit
       (cond
         ;; If base layer flagged a tech bluff (idle building + >= 225 unspent gas),
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
                                 enemy-feasible-tech
                                 enemy-rem-min
                                 enemy-rem-gas)]))
     (define d2-enemy-unit
       (if bluff?
           raw-d2-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-d2-enemy-unit enemy-feasible-tech zs-reading tech-obs)))
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
    ;;   feasible tech tree, crippled buildings, and zero-sum exclusions")
    ;; -------------------------------------------------------------------------
    [else
     (define prev-node
       (predict-at-depth mstate (sub1 depth) obs
                         #:our-tech our-tech
                         #:our-minerals our-minerals
                         #:our-gas our-gas))
     (define opp-belief-arch
       (unit-to-archetype (depth-node-our-response-unit prev-node)))
     (define raw-dk-enemy-unit
       (counter-unit-for-race enemy-race
                              opp-belief-arch
                              enemy-feasible-tech
                              enemy-rem-min
                              enemy-rem-gas))
     (define dk-enemy-unit
       (if bluff?
           raw-dk-enemy-unit
           (constrain-enemy-unit-to-feasible-tech
            enemy-race raw-dk-enemy-unit enemy-feasible-tech zs-reading tech-obs)))
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
                                #:our-gas [raw-our-gas 150])
  (define obs (if (hash? raw-obs) raw-obs (hash)))
  (define our-minerals (max 0 (safe-int raw-our-minerals 300)))
  (define our-gas (max 0 (safe-int raw-our-gas 150)))
  ;; Ensure base-layer observations/implications & zero-sum exclusions are synchronized with `obs`
  (when (or (hash-has-key? obs 'enemy-units)
            (hash-has-key? obs 'enemy-buildings)
            (hash-has-key? obs 'effects))
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
                                 '())))
    (set-mirror-mind-state-last-tech-observation! mstate tech-obs)
    (define zs-reading
      (evaluate-zero-sum-negative-exclusions
       frame e-units e-bldgs tech-obs (mirror-mind-state-last-shadow-ledger mstate)))
    (set-mirror-mind-state-last-zero-sum-reading! mstate zs-reading))

  (define top-d
    (if (and max-depth (finite-real? max-depth))
        (max (safe-int max-depth 5) (add1 (mirror-mind-state-inferred-opponent-depth mstate)))
        (max 5
             (mirror-mind-state-default-depth mstate)
             (add1 (mirror-mind-state-inferred-opponent-depth mstate)))))
  (define nodes
    (for/list ([d (in-range 0 (add1 top-d))])
      (predict-at-depth mstate d obs
                        #:our-tech our-tech
                        #:our-minerals our-minerals
                        #:our-gas our-gas)))
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

;; Dynamically choose the active depth level across ALL depths d = 0..5 based on:
;;   1. Online Depth Accuracy Tracking (`depth-accuracies` / `depth-accuracy-scores`):
;;      Evaluates all depths d = 0..5 simultaneously without tying depth to any
;;      specific unit or building; if another depth d* is predicting the opponent's
;;      resource-weighted transitions better, dynamically switches to d*!
;;   2. Occam's Razor Low-End Guard: Do NOT over-complicate past Depth 1 when
;;      the opponent shows 'no-reaction or overall accuracy is very low.
;;   3. Diagnostic Probe & High-End Multi-Layer Escalation (Depth 3, 4, 5).
(define (choose-optimal-mirror-depth mstate
                                     #:depth-accuracy-scores [depth-accuracy-scores #f])
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

  (define still-pending '())
  (for ([fc (in-list pending)])
    (define fc-depth (mirror-forecast-depth fc))
    (define pred-unit (mirror-forecast-predicted-enemy-unit fc))
    (define tx (mirror-forecast-target-x fc))
    (define ty (mirror-forecast-target-y fc))
    (define deadline (mirror-forecast-deadline-frame fc))

    ;; Score strategic prediction using resource-weighted & transition-sensitive scorer
    ;; so a single leftover tier-1 unit does NOT give cheap credit over a real tech switch!
    (define score-map
      (score-depth-predictions (list (cons fc-depth pred-unit))
                               enemy-units
                               #:current-enemy-bldgs enemy-bldgs))
    (define strat-score (hash-ref score-map fc-depth 0.0))
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
  (evaluate-pending-diagnostic-probes! mstate frame enemy-units reading)
  (when (and (> frame 672)
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
  (define nodes
    (build-mirror-hierarchy mstate sanitized-obs
                            #:max-depth (max 5 active-d)
                            #:our-tech eff-tech
                            #:our-minerals minerals
                            #:our-gas gas))
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

  ;; 7. Emit Mirror-Mind S-expression directives (including active depth `active-d`, toolbox role, macro directive, tech observation, zero-sum exclusion, and spatial maneuver)
  (define acc-pct
    (exact-round (* 100.0 (safe-real (mirror-mind-state-overall-accuracy mstate) 0.72))))
  (define trust-mode (mirror-mind-state-trust-mode mstate))
  (define tech-obs (mirror-mind-state-last-tech-observation mstate))

  (define actions
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

  (define scout-actions
    (if (or (eq? trust-mode 'skeptical-observational-fallback)
            (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-reading)
            (memq (shadow-ledger-dark-matter-hypothesis ledger)
                  '(hidden-expansion-or-macro-boom hidden-air-or-cloak-tech-switch)))
        (list (list 'scout-sector 1 enemy-x enemy-y)
              (list 'scout-sector 2 tx ty))
        '()))

  (append actions scout-actions))
