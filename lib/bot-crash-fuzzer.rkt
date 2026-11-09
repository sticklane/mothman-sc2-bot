#lang racket

;; =============================================================================
;; Pure-Racket Crash & SC2 LotV Actuator-Contract Fuzzer
;; (`lib/bot-crash-fuzzer.rkt`)
;;
;; Stress-tests all cognitive, macro, tactical, and S-expression entry points
;; across 10,000+ deterministic-seed + randomized property-based frames and
;; multi-frame trajectories across Zerg, Protoss, Terran, and Random:
;;   1. `parse-frame-state-sexp` and `runtime-step-sexp!` (`lib/bot-runtime.rkt`)
;;   2. `step-live-bot-runtime!` (`lib/bot-runtime.rkt`)
;;   3. `step-mirror-mind-predictor!`, `compute-shadow-ledger`,
;;      `interpret-opponent-actions`, `evaluate-mirror-macro-verdict`,
;;      `choose-optimal-mirror-depth` (`lib/mirror-mind-predictor.rkt`)
;;   4. `evaluate-coupled-macro-governor`, `evaluate-adaptive-build-and-tech-plan`,
;;      `evaluate-guns-vs-butter-ppf`, `compute-optimal-gas-workers` (`lib/econ-ledger.rkt`)
;;   5. `step-zerospace-mastermind!` (`lib/zerospace-mastermind.rkt`)
;; =============================================================================

(require racket/match
         racket/list
         racket/set
         racket/math
         racket/runtime-path
         "bot-runtime.rkt"
         "econ-ledger.rkt"
         "mirror-mind-predictor.rkt"
         "zerospace-mastermind.rkt")

(provide
 ;; Contract Tables & Constants
 SC2-LOTV-VALID-ACTION-HEADS
 FORBIDDEN-BROODWAR-UNIT-AND-BUILDING-SYMS
 FORBIDDEN-BROODWAR-AND-INVALID-UPGRADE-SYMS
 SC2-LOTV-VALID-UPGRADE-SYMS
 SC2-LOTV-VALID-UNIT-SYMS
 SC2-LOTV-VALID-BUILDING-SYMS
 SC2-LOTV-VALID-MORPH-SYMS
 FLYING-NONCOMBAT-SCOUT-SYMS
 ALL-AIR-UNIT-SYMS
 BOUNDARY-NUMERIC-VALUES
 ENGINE-UNEXPECTED-UNIT-AND-BUILDING-SYMS
 DEGENERATE-SCENARIO-KINDS

 ;; Dynamic / Compatibility Target Wrappers
 compute-shadow-ledger
 step-zerospace-mastermind!

 ;; Contract Validator & Result Struct
 (struct-out action-contract-result)
 check-emitted-action-sexp
 explain-emitted-action-sexp
 validate-emitted-action-sexp
 validate-emitted-actions-list

 ;; Fuzz State & Frame Generators
 make-deterministic-prng
 generate-boundary-numeric-frame
 generate-boundary-numeric-sexp
 generate-degenerate-game-state-frame
 generate-degenerate-game-state-sexp
 generate-random-property-frame
 generate-random-property-sexp
 generate-multi-frame-trajectory

 ;; Individual Target Fuzzers
 fuzz-parse-and-runtime-step-sexp!
 fuzz-step-live-bot-runtime!
 fuzz-mirror-mind-suite!
 fuzz-econ-ledger-suite!
 fuzz-zerospace-mastermind-suite!

 ;; Campaign Runner & Report Struct
 (struct-out fuzz-campaign-report)
 run-contract-self-checks!
 run-bot-crash-and-contract-fuzzer
 print-fuzz-campaign-report)

(define-runtime-path mirror-mind-mod-path "mirror-mind-predictor.rkt")
(define-runtime-path mastermind-mod-path "zerospace-mastermind.rkt")

;; Support both `compute-shadow-ledger` and `compute-opponent-shadow-ledger`
(define compute-shadow-ledger
  (let ([exported (with-handlers ([exn:fail? (lambda (_e) #f)])
                    (dynamic-require mirror-mind-mod-path 'compute-shadow-ledger))])
    (or exported compute-opponent-shadow-ledger)))

;; Support both `step-zerospace-mastermind!` and `step-double-reaction!`
(define step-zerospace-mastermind!
  (let ([exported (with-handlers ([exn:fail? (lambda (_e) #f)])
                    (dynamic-require mastermind-mod-path 'step-zerospace-mastermind!))])
    (or exported
        (lambda (mstate
                 [obs #f]
                 #:fap-score [fap-score 0]
                 #:enemy-units [enemy-units '()]
                 #:ally-buildings [ally-buildings '()]
                 #:self-workers [self-workers 16]
                 #:enemy-workers [enemy-workers 16]
                 #:self-army [self-army 200]
                 #:enemy-army [enemy-army 200])
          (if (hash? obs)
              (let ([eu (hash-ref obs 'enemy-units enemy-units)]
                    [ab (map (lambda (b)
                               (if (hash? b) (hash-ref b 'type 'unknown) b))
                             (hash-ref obs 'ally-buildings ally-buildings))]
                    [au (hash-ref obs 'ally-units '())])
                (step-double-reaction! mstate
                                       #:fap-score (hash-ref obs 'fap-score fap-score)
                                       #:enemy-units eu
                                       #:ally-buildings ab
                                       #:self-workers (max 1 (length au))
                                       #:enemy-workers enemy-workers
                                       #:self-army (* 50 (length au))
                                       #:enemy-army (* 50 (length eu))))
              (step-double-reaction! mstate
                                     #:fap-score fap-score
                                     #:enemy-units enemy-units
                                     #:ally-buildings ally-buildings
                                     #:self-workers self-workers
                                     #:enemy-workers enemy-workers
                                     #:self-army self-army
                                     #:enemy-army enemy-army))))))

;; =============================================================================
;; 1. SC2 LotV Actuator Grammar & Symbol Contract Tables
;; =============================================================================

(define SC2-LOTV-VALID-ACTION-HEADS
  '(build
    build-at
    train
    morph
    research
    upgrade
    expand
    attack
    attack-pos
    attack-unit
    move
    move-waypoint
    retreat
    kite
    focus-fire
    micro
    cast
    cast-spell
    ability
    scout
    scout-sector
    harass
    harass-workers
    worker-harass
    drop
    multi-prong-drop
    multiprong
    defend
    pull-workers-attack
    return-workers-mine
    distribute-workers
    gas-workers
    harvest-gas
    harvest-mineral
    mineral-walk
    chronoboost
    chrono-boost
    inject-larva
    spawn-larva
    creep-spread
    spawn-creep-tumor
    spread-creep-tumor
    calldown-mule
    scanner-sweep
    burrow
    burrow-block
    unburrow
    siege
    siege-mode
    unsiege
    unsiege-mode
    cloak
    blink
    stim
    stimpack
    morph-archon
    warp-in
    cancel
    cancel-building
    resume-halted-building
    lift-building
    land-building
    swap-addon
    rally
    patrol
    patrol-block-expansion
    hold-position
    contain
    posture
    posture-transition
    clear-gas-steal
    clear-expansion-block
    transport-juggle
    snipe-enemy-changeling
    cast-deception-and-scout-spells
    cast-protective-buff-aura
    position-in-buff-aura-with-splash-spread
    pre-split-wings
    form-concave-arc
    high-ground-tactics
    execute-spatial-maneuver
    move-camera
    camera-focus
    camera-bookmark-save
    camera-bookmark-jump
    control-group-steal
    control-group-set
    control-group-recall
    human-apm-discipline
    mirror-prediction
    mirror-macro-directive
    mirror-tech-observation
    mirror-zero-sum-exclusion
    mirror-spatial-maneuver
    mirror-bo-tree-prediction
    mirror-horizon-curve
    worker-drill-stack-attack
    counter-enemy-worker-drill
    evacuate-workers-from-stasis-ward
    trigger-stasis-ward-single-unit
    stasis-worker-stoppage-compensation
    return-workers-to-gather
    chat
    log
    noop))

(define FORBIDDEN-BROODWAR-UNIT-AND-BUILDING-SYMS
  '(sunken-colony
    spore-colony
    dragoon
    reaver
    shuttle
    arbiter
    corsair
    scout-ship
    science-vessel
    science-facility
    covert-ops
    machine-shop
    physics-lab
    control-tower
    comsat-station
    nuclear-silo
    vulture
    medic
    goliath
    firebat
    valkyrie
    defiler
    devourer
    guardian
    scourge
    queen-nest
    robotics-support-bay
    warpgate))

(define FORBIDDEN-BROODWAR-AND-INVALID-UPGRADE-SYMS
  '(centrifugal-hooks
    lockdown
    lurker-aspect
    zergling-speed
    singularity-charge
    leg-enhancements
    scarab-damage
    charon-boosters
    irradiate))

(define SC2-LOTV-VALID-UPGRADE-SYMS
  '(;; Zerg SC2 LotV upgrades
    metabolic-boost
    zergling-movementspeed
    adrenal-glands
    zergling-attackspeed
    centrifical-hooks
    glial-reconstitution
    tunneling-claws
    grooved-spines
    muscular-augments
    adaptive-talons
    seismic-spines
    chitinous-plating
    anabolic-synthesis
    pneumatized-carapace
    overlordspeed
    burrow
    neural-parasite
    pathogen-glands
    microbial-shroud
    digging-claws
    EvolveGroovedSpines
    zerg-melee-weapons-1
    zerg-melee-weapons-2
    zerg-melee-weapons-3
    zerg-missile-weapons-1
    zerg-missile-weapons-2
    zerg-missile-weapons-3
    zerg-ground-armor-1
    zerg-ground-armor-2
    zerg-ground-armor-3
    zerg-flyer-weapons-1
    zerg-flyer-weapons-2
    zerg-flyer-weapons-3
    zerg-flyer-armor-1
    zerg-flyer-armor-2
    zerg-flyer-armor-3
    melee-attacks-1
    melee-attacks-2
    melee-attacks-3
    missile-attacks-1
    missile-attacks-2
    missile-attacks-3
    ground-carapace-1
    ground-carapace-2
    ground-carapace-3
    flyer-attacks-1
    flyer-attacks-2
    flyer-attacks-3
    flyer-carapace-1
    flyer-carapace-2
    flyer-carapace-3

    ;; Protoss SC2 LotV upgrades
    warp-gate-research
    charge
    blink-tech
    blink
    resonating-glaives
    psi-storm-tech
    psi-storm
    extended-thermal-lance
    gravitic-boosters
    gravitic-drive
    flux-vanes
    anion-pulse-crystals
    shadow-stride
    protoss-ground-weapons-1
    protoss-ground-weapons-2
    protoss-ground-weapons-3
    protoss-ground-armor-1
    protoss-ground-armor-2
    protoss-ground-armor-3
    protoss-shields-1
    protoss-shields-2
    protoss-shields-3
    protoss-air-weapons-1
    protoss-air-weapons-2
    protoss-air-weapons-3
    protoss-air-armor-1
    protoss-air-armor-2
    protoss-air-armor-3
    ground-weapons-1
    ground-weapons-2
    ground-weapons-3
    ground-armor-1
    ground-armor-2
    ground-armor-3
    shields-1
    shields-2
    shields-3
    air-weapons-1
    air-weapons-2
    air-weapons-3
    air-armor-1
    air-armor-2
    air-armor-3

    ;; Terran SC2 LotV upgrades
    stimpack
    combat-shield
    concussive-shells
    infernal-pre-igniter
    drilling-claws
    cyclone-lock-on-damage
    mag-field-accelerator
    smart-servos
    hyperflight-rotors
    cloaking-field
    personal-cloaking
    weapon-refit
    advanced-ballistics
    siege-mode
    hisec-auto-tracking
    neosteel-armor
    caduceus-reactor
    corvid-reactor
    behemoth-reactor
    hurricane-thrusters
    interference-matrix
    terran-infantry-weapons-1
    terran-infantry-weapons-2
    terran-infantry-weapons-3
    terran-infantry-armor-1
    terran-infantry-armor-2
    terran-infantry-armor-3
    terran-vehicle-weapons-1
    terran-vehicle-weapons-2
    terran-vehicle-weapons-3
    terran-ship-weapons-1
    terran-ship-weapons-2
    terran-ship-weapons-3
    terran-vehicle-and-ship-plating-1
    terran-vehicle-and-ship-plating-2
    terran-vehicle-and-ship-plating-3
    infantry-weapons-1
    infantry-weapons-2
    infantry-weapons-3
    infantry-armor-1
    infantry-armor-2
    infantry-armor-3
    vehicle-weapons-1
    vehicle-weapons-2
    vehicle-weapons-3
    ship-weapons-1
    ship-weapons-2
    ship-weapons-3
    vehicle-and-ship-plating-1
    vehicle-and-ship-plating-2
    vehicle-and-ship-plating-3))

(define SC2-LOTV-VALID-BUILDING-SYMS
  '(;; Zerg
    hatchery lair hive spawning-pool extractor extractor-rich
    roach-warren baneling-nest evolution-chamber hydralisk-den
    lurker-den lurker-den-mp spire greater-spire infestation-pit
    ultralisk-cavern nydus-network nydus-worm nydus-canal
    spine-crawler spine-crawler-uprooted spore-crawler spore-crawler-uprooted
    creep-tumor creep-tumor-burrowed creep-tumor-queen
    ;; Protoss
    nexus pylon assimilator assimilator-rich gateway warp-gate
    forge cybernetics-core photon-cannon shield-battery
    twilight-council stargate robotics-facility robotics-bay
    templar-archive templar-archives dark-shrine fleet-beacon
    ;; Terran
    command-center orbital-command planetary-fortress supply-depot
    supply-depot-lowered refinery refinery-rich barracks
    barracks-techlab barracks-reactor factory factory-techlab
    factory-reactor starport starport-techlab starport-reactor
    engineering-bay armory fusion-core ghost-academy bunker
    missile-turret sensor-tower techlab reactor))

(define SC2-LOTV-VALID-UNIT-SYMS
  '(;; Zerg
    drone drone-burrowed larva egg overlord overlord-cocoon
    overlord-transport overseer overseer-siege-mode queen queen-burrowed
    zergling zergling-burrowed baneling baneling-cocoon baneling-burrowed
    roach roach-burrowed ravager ravager-cocoon ravager-burrowed
    hydralisk hydralisk-burrowed lurker lurker-mp lurker-mp-egg
    lurker-burrowed lurker-mp-burrowed mutalisk corruptor
    brood-lord broodlord brood-lord-cocoon broodling
    infestor infestor-burrowed swarm-host swarm-host-mp swarm-host-burrowed
    locust locust-mp locust-mp-flying viper ultralisk ultralisk-burrowed
    changeling changeling-zealot changeling-marine changeling-marine-shield
    changeling-zergling changeling-zergling-wings
    ;; Protoss
    probe zealot stalker sentry adept adept-phase-shift
    high-templar dark-templar archon observer observer-siege-mode
    warp-prism warp-prism-phasing immortal colossus disruptor
    disruptor-phased phoenix void-ray voidray oracle tempest
    carrier interceptor mothership mothership-core
    ;; Terran
    scv mule marine marauder reaper ghost hellion
    hellbat hellion-tank widow-mine widowmine widow-mine-burrowed
    cyclone siege-tank siege-tank-sieged tank thor thor-ap
    viking viking-fighter viking-assault medivac liberator
    liberator-ag banshee raven battlecruiser auto-turret point-defense-drone))

(define SC2-LOTV-VALID-MORPH-SYMS
  (remove-duplicates
   (append SC2-LOTV-VALID-UNIT-SYMS
           SC2-LOTV-VALID-BUILDING-SYMS
           '(siege-mode unsiege-mode uproot root))))

(define FLYING-NONCOMBAT-SCOUT-SYMS
  '(overlord overseer observer overlord-transport overseer-siege-mode observer-siege-mode))

(define ALL-AIR-UNIT-SYMS
  '(overlord overseer observer overlord-transport overseer-siege-mode observer-siege-mode
    mutalisk corruptor brood-lord broodlord viper
    phoenix oracle void-ray voidray carrier tempest mothership warp-prism
    viking viking-fighter medivac liberator liberator-ag banshee raven battlecruiser))

(define BOUNDARY-NUMERIC-VALUES
  (list 0 -1 -99999 999999 +nan.0 +inf.0 -inf.0 1/3 -7/3 0.3333333333333333 #f 'null "bad" '()))

(define ENGINE-UNEXPECTED-UNIT-AND-BUILDING-SYMS
  '(mineral-field-750
    unbuildable-plates
    larva
    egg
    cocoon
    adept-phase-shift
    disruptor-phased
    kd8-charge
    parasitic-bomb-dummy
    destructible-rock-ex1-vertical-huge
    xelnaga-tower
    rich-vespene-geyser
    purifier-mineral-field))

(define DEGENERATE-SCENARIO-KINDS
  '(zero-ally-elimination
    total-fog-of-war
    max-supply-10k-bank
    zero-econ-50-enemy-swarm
    all-air-enemy-on-base
    flying-scouts-only-on-base
    changelings-and-hallucinations-mix
    all-bases-mined-out
    non-monotonic-frame-jumps
    unexpected-engine-symbols))

;; =============================================================================
;; 2. SC2 LotV Actuator & Symbol Contract Checker (`validate-emitted-action-sexp`)
;; =============================================================================

(struct action-contract-result (valid? action violations) #:transparent)

(define VALID-HEAD-SET (list->seteq SC2-LOTV-VALID-ACTION-HEADS))
(define FORBIDDEN-UNIT-BLDG-SET (list->seteq FORBIDDEN-BROODWAR-UNIT-AND-BUILDING-SYMS))
(define FORBIDDEN-UPGRADE-SET (list->seteq FORBIDDEN-BROODWAR-AND-INVALID-UPGRADE-SYMS))
(define VALID-UPGRADE-SET (list->seteq SC2-LOTV-VALID-UPGRADE-SYMS))
(define VALID-UNIT-SET (list->seteq SC2-LOTV-VALID-UNIT-SYMS))
(define VALID-BLDG-SET (list->seteq SC2-LOTV-VALID-BUILDING-SYMS))
(define VALID-MORPH-SET (list->seteq SC2-LOTV-VALID-MORPH-SYMS))
(define FLYING-SCOUT-SET (list->seteq FLYING-NONCOMBAT-SCOUT-SYMS))
(define ALL-AIR-SET (list->seteq ALL-AIR-UNIT-SYMS))

(define (finite-real? v)
  (and (real? v) (not (nan? v)) (not (infinite? v))))

(define (safe-dist2d x1 y1 x2 y2)
  (if (and (finite-real? x1) (finite-real? y1) (finite-real? x2) (finite-real? y2))
      (sqrt (+ (sqr (- x2 x1)) (sqr (- y2 y1))))
      99999.0))

(define (extract-unit-type-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(and (list? u) (>= (length u) 2) (symbol? (second u)))
     (second u)]
    [else 'unknown]))

(define (extract-coord u key fallback)
  (cond
    [(hash? u)
     (define v (hash-ref u key fallback))
     (if (finite-real? v) v fallback)]
    [(and (list? u) (>= (length u) 4))
     (define v (if (eq? key 'x) (third u) (fourth u)))
     (if (finite-real? v) v fallback)]
    [else fallback]))

;; Checks if `(pull-workers-attack ...)` violates the tactical invariant:
;; NEVER pull workers to attack when the only nearby enemies are flying non-combat
;; scouts (`overlord`, `overseer`, `observer`) or air-only units with no ground targets.
(define (worker-pull-violates-flying-scout-invariant? obs)
  (cond
    [(not obs) #f]
    [else
     (define h
       (cond
         [(hash? obs) obs]
         [(pair? obs)
          (with-handlers ([exn:fail? (lambda (_e) (hash))])
            (parse-frame-state-sexp obs))]
         [else (hash)]))
     (define base-x-raw (hash-ref h 'base-x 32.5))
     (define base-y-raw (hash-ref h 'base-y 32.5))
     (define base-x (if (finite-real? base-x-raw) base-x-raw 32.5))
     (define base-y (if (finite-real? base-y-raw) base-y-raw 32.5))
     (define enemy-units
       (let ([eu (hash-ref h 'enemy-units '())])
         (if (list? eu) eu '())))
     (define enemy-bldgs
       (let ([eb (hash-ref h 'enemy-buildings '())])
         (if (list? eb) eb '())))
     (define nearby-units
       (filter (lambda (e)
                 (<= (safe-dist2d base-x base-y
                                  (extract-coord e 'x 9999)
                                  (extract-coord e 'y 9999))
                     12.0))
               enemy-units))
     (define nearby-bldgs
       (filter (lambda (b)
                 (<= (safe-dist2d base-x base-y
                                  (extract-coord b 'x 9999)
                                  (extract-coord b 'y 9999))
                     12.0))
               enemy-bldgs))
     (define relevant-units
       (if (not (null? nearby-units)) nearby-units enemy-units))
     (and (null? nearby-bldgs)
          (not (null? relevant-units))
          (or (andmap (lambda (e) (set-member? FLYING-SCOUT-SET (extract-unit-type-sym e)))
                      relevant-units)
              (andmap (lambda (e) (set-member? ALL-AIR-SET (extract-unit-type-sym e)))
                      relevant-units)))]))

(define (check-emitted-action-sexp act [obs #f])
  (define violations '())
  (define (flag! kind detail)
    (set! violations (cons (list kind detail act) violations)))

  (cond
    [(not (and (pair? act) (list? act)))
     (flag! 'malformed-action-sexp act)]
    [else
     (define head (car act))
     (define args (cdr act))
     (unless (symbol? head)
       (flag! 'non-symbol-action-head head))
     (when (and (symbol? head) (not (set-member? VALID-HEAD-SET head)))
       (flag! 'invalid-action-head head))

     ;; Recursively walk all atoms in `act` for forbidden symbols and non-finite numbers
     ;; (Skip non-actuated telemetry lists in mirror-tech-observation / mirror-zero-sum-exclusion
     ;;  if they merely echo enemy observed symbols, EXCEPT we still check all numbers are finite)
     (define telemetry-observation-head?
       (memq head '(mirror-tech-observation mirror-zero-sum-exclusion)))

     (let walk ([node args])
       (cond
         [(pair? node)
          (walk (car node))
          (walk (cdr node))]
         [(symbol? node)
          (unless telemetry-observation-head?
            (when (set-member? FORBIDDEN-UNIT-BLDG-SET node)
              (flag! 'forbidden-broodwar-unit-or-building-symbol node))
            (when (set-member? FORBIDDEN-UPGRADE-SET node)
              (flag! 'forbidden-broodwar-or-misspelled-upgrade-symbol node)))]
         [(number? node)
          (unless (finite-real? node)
            (flag! 'non-finite-numeric-argument node))]
         [else (void)]))

     ;; Head-specific SC2 LotV contract checks
     (case head
       [(build build-at)
        (if (null? args)
            (flag! 'missing-build-target head)
            (let ([btype (car args)])
              (cond
                [(not (symbol? btype))
                 (flag! 'non-symbol-build-target btype)]
                [(set-member? FORBIDDEN-UNIT-BLDG-SET btype)
                 (flag! 'forbidden-broodwar-building btype)]
                [(not (set-member? VALID-BLDG-SET btype))
                 (flag! 'unknown-sc2-lotv-building btype)])))]

       [(train warp-in)
        (if (null? args)
            (flag! 'missing-train-target head)
            (let ([utype (car args)])
              (cond
                [(not (symbol? utype))
                 (flag! 'non-symbol-train-target utype)]
                [(set-member? FORBIDDEN-UNIT-BLDG-SET utype)
                 (flag! 'forbidden-broodwar-unit utype)]
                [(not (set-member? VALID-UNIT-SET utype))
                 (flag! 'unknown-sc2-lotv-unit utype)])))]

       [(morph)
        (if (null? args)
            (flag! 'missing-morph-target head)
            (let ([mtarget (if (and (>= (length args) 2)
                                    (not (symbol? (car args))))
                               (second args)
                               (car args))])
              (cond
                [(not (symbol? mtarget))
                 (flag! 'non-symbol-morph-target mtarget)]
                [(set-member? FORBIDDEN-UNIT-BLDG-SET mtarget)
                 (flag! 'forbidden-broodwar-morph-target mtarget)]
                [(not (set-member? VALID-MORPH-SET mtarget))
                 (flag! 'unknown-sc2-lotv-morph-target mtarget)])))]

       [(research upgrade)
        (if (null? args)
            (flag! 'missing-upgrade-target head)
            (let ([upg (car args)])
              (cond
                [(not (symbol? upg))
                 (flag! 'non-symbol-upgrade-target upg)]
                [(set-member? FORBIDDEN-UPGRADE-SET upg)
                 (flag! 'forbidden-broodwar-or-invalid-upgrade upg)]
                [(not (set-member? VALID-UPGRADE-SET upg))
                 (flag! 'unknown-sc2-lotv-upgrade upg)])))]

       [(pull-workers-attack)
        (when (worker-pull-violates-flying-scout-invariant? obs)
          (flag! 'tactical-invariant-worker-pull-vs-flying-scouts head))]

       [else (void)])])

  (define rev-violations (reverse (remove-duplicates violations)))
  (action-contract-result (null? rev-violations) act rev-violations))

(define (explain-emitted-action-sexp act [obs #f])
  (check-emitted-action-sexp act obs))

;; Primary contract validator:
;; Returns `#t` if `act` is 100% valid SC2 LotV actuator syntax/symbols/invariants,
;; or `#f` if any contract violation exists (unless `#:return-details? #t` is passed).
(define (validate-emitted-action-sexp act [obs #f] #:return-details? [return-details? #f])
  (define res (check-emitted-action-sexp act obs))
  (if return-details?
      res
      (action-contract-result-valid? res)))

(define (validate-emitted-actions-list actions [obs #f])
  (for/list ([act (in-list (if (list? actions) actions '()))])
    (check-emitted-action-sexp act obs)))

;; =============================================================================
;; 3. Deterministic PRNG & Adversarial / Boundary / Degenerate Fuzz Generators
;; =============================================================================

;; Linear congruential + xorshift deterministic PRNG in pure Racket
(define (make-deterministic-prng [seed 20261107])
  (define state (bitwise-and (abs seed) #x7fffffff))
  (when (zero? state) (set! state 20261107))
  (lambda ([mod #f])
    (set! state (bitwise-and (+ (* state 1103515245) 12345) #x7fffffff))
    (if (and mod (> mod 0))
        (modulo state mod)
        (/ (exact->inexact state) (exact->inexact #x7fffffff)))))

(define (prng-pick prng lst)
  (list-ref lst (prng (length lst))))

(define ALL-FUZZ-RACES '(Zerg Protoss Terran Random))

(define SAMPLE-ALLY-UNITS-BY-RACE
  (hash 'Zerg    '(drone zergling baneling roach ravager hydralisk lurker mutalisk corruptor queen overlord overseer infestor ultralisk)
        'Protoss '(probe zealot stalker sentry adept immortal colossus archon high-templar dark-templar phoenix void-ray carrier observer warp-prism)
        'Terran  '(scv marine marauder reaper ghost hellion hellbat widow-mine siege-tank thor viking medivac liberator banshee battlecruiser)
        'Random  '(drone zergling roach marine siege-tank probe stalker immortal)))

(define SAMPLE-ALLY-BLDGS-BY-RACE
  (hash 'Zerg    '(hatchery spawning-pool extractor roach-warren lair baneling-nest hydralisk-den spire infestation-pit hive ultralisk-cavern spore-crawler spine-crawler)
        'Protoss '(nexus pylon assimilator gateway warp-gate cybernetics-core forge photon-cannon twilight-council robotics-facility robotics-bay stargate templar-archives fleet-beacon)
        'Terran  '(command-center orbital-command planetary-fortress supply-depot refinery barracks barracks-techlab barracks-reactor factory factory-techlab starport engineering-bay armory fusion-core ghost-academy missile-turret bunker)
        'Random  '(hatchery spawning-pool command-center barracks nexus gateway cybernetics-core)))

(define SAMPLE-ENEMY-UNITS
  '(zergling baneling roach ravager hydralisk lurker mutalisk corruptor ultralisk brood-lord overlord overseer
    marine marauder reaper ghost hellion widow-mine cyclone siege-tank thor viking medivac banshee battlecruiser
    zealot stalker sentry adept immortal colossus void-ray carrier oracle phoenix dark-templar high-templar archon observer))

;; 3.1 Boundary Numeric Fuzz Frame Generator
;; Injects boundary values (0, -1, -99999, 999999, +nan.0, +inf.0, -inf.0, 1/3, #f, 'null, "bad", '())
;; into frame, minerals, gas, supply-used, supply-cap, supply-left, unit x, y, hp, max-hp,
;; hp-pct, shield, energy, ideal-harvesters, assigned-harvesters.
(define (generate-boundary-numeric-frame prng idx [race 'Zerg])
  (define bval (lambda () (prng-pick prng BOUNDARY-NUMERIC-VALUES)))
  (define target-field (modulo idx 15))
  (define (field-val slot default-v)
    (if (or (= target-field slot) (= (prng 7) 0))
        (bval)
        default-v))

  (define u1
    (hash 'id (field-val 0 101)
          'type (prng-pick prng (hash-ref SAMPLE-ALLY-UNITS-BY-RACE race '(drone roach)))
          'x (field-val 6 32.5)
          'y (field-val 7 32.5)
          'hp (field-val 8 45)
          'max-hp (field-val 9 45)
          'hp-pct (field-val 10 1.0)
          'shield (field-val 11 0)
          'energy (field-val 12 50)))
  (define b1
    (hash 'id 201
          'type (prng-pick prng (hash-ref SAMPLE-ALLY-BLDGS-BY-RACE race '(hatchery spawning-pool)))
          'x (field-val 6 32.5)
          'y (field-val 7 32.5)
          'hp (field-val 8 1500)
          'max-hp (field-val 9 1500)
          'hp-pct (field-val 10 1.0)
          'build-progress (field-val 10 0.5)
          'ideal-harvesters (field-val 13 16)
          'assigned-harvesters (field-val 14 16)))
  (define e1
    (hash 'id 901
          'type (prng-pick prng SAMPLE-ENEMY-UNITS)
          'x (field-val 6 50.5)
          'y (field-val 7 56.5)
          'hp (field-val 8 80)
          'max-hp (field-val 9 80)
          'hp-pct (field-val 10 0.5)
          'shield (field-val 11 40)
          'energy (field-val 12 100)))

  (hash 'frame (field-val 0 (* idx 16))
        'race race
        'actual-race (if (eq? race 'Random) (prng-pick prng '(Zerg Protoss Terran)) race)
        'minerals (field-val 1 250)
        'gas (field-val 2 150)
        'supply-used (field-val 3 24)
        'supply-cap (field-val 4 30)
        'supply-left (field-val 5 6)
        'base-x (field-val 6 32.5)
        'base-y (field-val 7 32.5)
        'natural-x (field-val 6 50.5)
        'natural-y (field-val 7 56.5)
        'ally-units (list u1)
        'ally-buildings (list b1)
        'enemy-units (list e1)
        'enemy-buildings (list (hash 'id 950
                                     'type 'nexus
                                     'x (field-val 6 160.5)
                                     'y (field-val 7 160.5)
                                     'hp (field-val 8 1500)
                                     'max-hp (field-val 9 1500)
                                     'hp-pct (field-val 10 1.0)
                                     'ideal-harvesters (field-val 13 16)
                                     'assigned-harvesters (field-val 14 16)))))

(define (generate-boundary-numeric-sexp prng idx [race 'Zerg])
  (define bval (lambda () (prng-pick prng BOUNDARY-NUMERIC-VALUES)))
  (list 'frame-state
        '#:frame (bval)
        '#:race race
        '#:minerals (bval)
        '#:gas (bval)
        '#:supply-used (bval)
        '#:supply-cap (bval)
        '#:supply-left (bval)
        '#:start-pos (list (bval) (bval))
        '#:enemy-base (list (bval) (bval))
        '#:my-units (list (list (bval) 'drone (bval) (bval) (bval) (bval))
                          (list 102 'roach (bval) (bval) (bval)))
        '#:my-buildings (list (list 201 'hatchery (bval) (bval) (bval) (bval) (bval)))
        '#:enemy-units (list (list 901 'marine (bval) (bval) (bval) (bval)))
        '#:enemy-buildings (list (list 950 'barracks (bval) (bval) (bval) (bval) #f))
        '#:effects (list (list 'force-field (bval) (bval)))))

;; 3.2 Degenerate & Extreme Game States Generator
(define (generate-degenerate-game-state-frame prng idx [race 'Zerg])
  (define kind (list-ref DEGENERATE-SCENARIO-KINDS (modulo idx (length DEGENERATE-SCENARIO-KINDS))))
  (define eff-race (if (eq? race 'Random) (list-ref '(Zerg Protoss Terran) (modulo idx 3)) race))
  (define base-x 32.5)
  (define base-y 32.5)
  (case kind
    ;; 1. 0 ally units and 0 ally buildings (total base elimination / last unit standing)
    [(zero-ally-elimination)
     (hash 'scenario-kind kind
           'frame 4500
           'race race
           'actual-race eff-race
           'minerals 0
           'gas 0
           'supply-used 0
           'supply-cap 0
           'supply-left 0
           'base-x base-x
           'base-y base-y
           'ally-units '()
           'ally-buildings '()
           'enemy-units (list (hash 'id 901 'type 'stalker 'x 34.0 'y 34.0 'hp 80 'max-hp 80))
           'enemy-buildings (list (hash 'id 950 'type 'nexus 'x 160.5 'y 160.5 'hp 1500)))]

    ;; 2. 0 enemy units and 0 enemy buildings (total fog of war)
    [(total-fog-of-war)
     (hash 'scenario-kind kind
           'frame 3200
           'race race
           'actual-race eff-race
           'minerals 450
           'gas 300
           'supply-used 64
           'supply-cap 84
           'supply-left 20
           'enemy-main-cleared #t
           'ally-units (for/list ([i (in-range 6)])
                         (hash 'id (+ 100 i)
                               'type (prng-pick prng (hash-ref SAMPLE-ALLY-UNITS-BY-RACE eff-race))
                               'x (+ base-x (* i 1.5))
                               'y (+ base-y (* i 1.5))
                               'hp 100
                               'max-hp 100))
           'ally-buildings (for/list ([b (in-list (hash-ref SAMPLE-ALLY-BLDGS-BY-RACE eff-race))]
                                      [i (in-naturals)])
                             (hash 'id (+ 200 i) 'type b 'x (+ base-x (* i 2.5)) 'y base-y 'hp 1000))
           'enemy-units '()
           'enemy-buildings '())]

    ;; 3. 200/200 supply blocked with 10,000 minerals and 10,000 gas
    [(max-supply-10k-bank)
     (hash 'scenario-kind kind
           'frame 9000
           'race race
           'actual-race eff-race
           'minerals 10000
           'gas 10000
           'supply-used 200
           'supply-cap 200
           'supply-left 0
           'pending-supply 0
           'ally-units (for/list ([i (in-range 20)])
                         (hash 'id (+ 100 i)
                               'type (prng-pick prng (hash-ref SAMPLE-ALLY-UNITS-BY-RACE eff-race))
                               'x (+ base-x (* i 1.0))
                               'y (+ base-y (* i 1.0))
                               'hp 120
                               'max-hp 120))
           'ally-buildings (for/list ([b (in-list (hash-ref SAMPLE-ALLY-BLDGS-BY-RACE eff-race))]
                                      [i (in-naturals)])
                             (hash 'id (+ 200 i) 'type b 'x (+ base-x (* i 2.0)) 'y base-y 'hp 1200))
           'enemy-units (list (hash 'id 901 'type 'thor 'x 110.0 'y 110.0 'hp 400 'max-hp 400))
           'enemy-buildings (list (hash 'id 950 'type 'command-center 'x 160.5 'y 160.5 'hp 1500)))]

    ;; 4. 0 minerals, 0 gas, 0 supply-left under massive 50-unit enemy attack at (base-x, base-y)
    [(zero-econ-50-enemy-swarm)
     (hash 'scenario-kind kind
           'frame 1800
           'race race
           'actual-race eff-race
           'minerals 0
           'gas 0
           'supply-used 38
           'supply-cap 38
           'supply-left 0
           'base-x base-x
           'base-y base-y
           'ally-units (list (hash 'id 101 'type (case eff-race [(Zerg) 'drone] [(Protoss) 'probe] [else 'scv])
                                   'x base-x 'y base-y 'hp 20 'max-hp 40)
                             (hash 'id 102 'type (case eff-race [(Zerg) 'queen] [(Protoss) 'zealot] [else 'marine])
                                   'x (+ base-x 2.0) 'y base-y 'hp 45 'max-hp 100))
           'ally-buildings (list (hash 'id 201
                                       'type (case eff-race [(Zerg) 'hatchery] [(Protoss) 'nexus] [else 'command-center])
                                       'x base-x 'y base-y 'hp 120 'max-hp 1500 'hp-pct 0.08 'build-progress 0.6))
           'enemy-units (for/list ([i (in-range 50)])
                          (hash 'id (+ 900 i)
                                'type (prng-pick prng '(zergling marine zealot baneling reaper))
                                'x (+ base-x (* 0.5 (modulo i 10)))
                                'y (+ base-y (* 0.5 (quotient i 10)))
                                'hp 40
                                'max-hp 45))
           'enemy-buildings '())]

    ;; 5. All-air enemy army (mutalisk, void-ray, banshee, carrier, overlord, observer) right on top of (base-x, base-y)
    [(all-air-enemy-on-base)
     (hash 'scenario-kind kind
           'frame 2200
           'race race
           'actual-race eff-race
           'minerals 350
           'gas 250
           'supply-used 42
           'supply-cap 54
           'supply-left 12
           'base-x base-x
           'base-y base-y
           'ally-units (for/list ([i (in-range 8)])
                         (hash 'id (+ 10 i)
                               'type (case eff-race [(Zerg) 'drone] [(Protoss) 'probe] [else 'scv])
                               'x (+ base-x (* i 0.5))
                               'y (+ base-y (* i 0.5))
                               'hp 40
                               'max-hp 40))
           'ally-buildings (for/list ([b (in-list (hash-ref SAMPLE-ALLY-BLDGS-BY-RACE eff-race))]
                                      [i (in-naturals)])
                             (hash 'id (+ 200 i) 'type b 'x (+ base-x (* i 2.0)) 'y base-y 'hp 1000))
           'enemy-units (list (hash 'id 901 'type 'mutalisk 'x base-x 'y base-y 'hp 120 'max-hp 120)
                              (hash 'id 902 'type 'void-ray 'x (+ base-x 2.0) 'y base-y 'hp 150 'max-hp 150 'shield 100)
                              (hash 'id 903 'type 'banshee 'x base-x 'y (+ base-y 2.0) 'hp 140 'max-hp 140 'cloaked #t)
                              (hash 'id 904 'type 'carrier 'x (+ base-x 3.0) 'y (+ base-y 3.0) 'hp 300 'max-hp 300 'shield 150)
                              (hash 'id 905 'type 'overlord 'x base-x 'y base-y 'hp 200 'max-hp 200)
                              (hash 'id 906 'type 'observer 'x (+ base-x 1.0) 'y (+ base-y 1.0) 'hp 40 'max-hp 40 'cloaked #t))
           'enemy-buildings '())]

    ;; 5b. Only flying non-combat scouts (overlord, overseer, observer) right on top of (base-x, base-y)
    [(flying-scouts-only-on-base)
     (hash 'scenario-kind kind
           'frame 1200
           'race race
           'actual-race eff-race
           'minerals 250
           'gas 100
           'supply-used 18
           'supply-cap 22
           'supply-left 4
           'base-x base-x
           'base-y base-y
           'ally-units (for/list ([i (in-range 12)])
                         (hash 'id (+ 10 i)
                               'type (case eff-race [(Zerg) 'drone] [(Protoss) 'probe] [else 'scv])
                               'x (+ base-x (* i 0.5))
                               'y (+ base-y (* i 0.5))
                               'hp 40
                               'max-hp 40))
           'ally-buildings (list (hash 'id 201
                                       'type (case eff-race [(Zerg) 'hatchery] [(Protoss) 'nexus] [else 'command-center])
                                       'x base-x 'y base-y 'hp 1500 'max-hp 1500))
           'enemy-units (list (hash 'id 901 'type 'overlord 'x (+ base-x 2.5) 'y (+ base-y 2.5) 'hp 200 'max-hp 200)
                              (hash 'id 902 'type 'overseer 'x (+ base-x 3.5) 'y (+ base-y 3.5) 'hp 200 'max-hp 200)
                              (hash 'id 903 'type 'observer 'x (+ base-x 1.5) 'y (+ base-y 1.5) 'hp 40 'max-hp 40))
           'enemy-buildings '())]

    ;; 6. Changelings and hallucinations mixed with real units
    [(changelings-and-hallucinations-mix)
     (hash 'scenario-kind kind
           'frame 2600
           'race race
           'actual-race eff-race
           'minerals 400
           'gas 250
           'supply-used 52
           'supply-cap 66
           'supply-left 14
           'base-x base-x
           'base-y base-y
           'ally-units (list (hash 'id 101 'type 'sentry 'x 50.0 'y 56.0 'hp 40 'energy 100)
                             (hash 'id 102 'type 'overseer 'x 51.0 'y 57.0 'hp 200 'energy 100)
                             (hash 'id 103 'type 'roach 'x 52.0 'y 58.0 'hp 145))
           'ally-buildings (list (hash 'id 201 'type 'hatchery 'x base-x 'y base-y 'hp 1500))
           'enemy-units (list (hash 'id 901 'type 'changeling 'x 34.0 'y 34.0 'hp 50 'changeling? #t)
                              (hash 'id 902 'type 'changeling-zealot 'x 35.0 'y 35.0 'hp 50 'changeling? #t)
                              (hash 'id 903 'type 'changeling-zergling 'x 36.0 'y 36.0 'hp 50 'changeling? #t)
                              (hash 'id 904 'type 'changeling-marine 'x 37.0 'y 37.0 'hp 50 'changeling? #t)
                              (hash 'id 905 'type 'phoenix 'x 55.0 'y 60.0 'hp 120 'hallucination? #t 'damage-rate-ratio 2.0)
                              (hash 'id 906 'type 'colossus 'x 56.0 'y 61.0 'hp 200 'hallucination #t 'damage-taken-multiplier 2.0)
                              (hash 'id 907 'type 'stalker 'x 75.0 'y 80.0 'hp 80 'shield 80))
           'enemy-buildings (list (hash 'id 950 'type 'gateway 'x 155.0 'y 155.0 'hp 1000)))]

    ;; 7. All bases mined-out (mined-out? = #t, depleting-bases = 4)
    [(all-bases-mined-out)
     (hash 'scenario-kind kind
           'frame 7200
           'race race
           'actual-race eff-race
           'minerals 320
           'gas 180
           'supply-used 90
           'supply-cap 110
           'supply-left 20
           'mined-out #t
           'mined-out? #t
           'depleting-bases 4
           'ally-units (for/list ([i (in-range 16)])
                         (hash 'id (+ 10 i)
                               'type (case eff-race [(Zerg) 'drone] [(Protoss) 'probe] [else 'scv])
                               'x (+ base-x (* i 0.5))
                               'y base-y
                               'hp 40))
           'ally-buildings (for/list ([i (in-range 4)])
                             (hash 'id (+ 200 i)
                                   'type (case eff-race [(Zerg) 'hatchery] [(Protoss) 'nexus] [else 'orbital-command])
                                   'x (+ base-x (* i 18.0))
                                   'y (+ base-y (* i 18.0))
                                   'hp 1500
                                   'ideal-harvesters 0
                                   'assigned-harvesters 4))
           'enemy-units (list (hash 'id 901 'type 'marauder 'x 145.0 'y 145.0 'hp 125))
           'enemy-buildings '())]

    ;; 8. Rapid non-monotonic or huge frame jumps (frame = 0, 1, 2688, 6048, 50000, 0)
    [(non-monotonic-frame-jumps)
     (define jump-frames '#(0 1 2688 6048 50000 0 999999 -100 1344 0))
     (define f (vector-ref jump-frames (modulo idx (vector-length jump-frames))))
     (hash 'scenario-kind kind
           'frame f
           'race race
           'actual-race eff-race
           'minerals 500
           'gas 350
           'supply-used 48
           'supply-cap 64
           'supply-left 16
           'ally-units (list (hash 'id 101 'type 'roach 'x 44.0 'y 48.0 'hp 145)
                             (hash 'id 102 'type 'drone 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (hash-map SAMPLE-ALLY-BLDGS-BY-RACE
                                     (lambda (_k v) (hash 'id 201 'type (car v) 'x 32.5 'y 32.5 'hp 1000)))
           'enemy-units (list (hash 'id 901 'type 'siege-tank 'x 135.0 'y 135.0 'hp 175))
           'enemy-buildings (list (hash 'id 950 'type 'factory 'x 155.0 'y 155.0 'hp 1250)))]

    ;; 9. Unknown/unexpected unit or building symbols from SC2 engine
    [else
     (hash 'scenario-kind 'unexpected-engine-symbols
           'frame 2000
           'race race
           'actual-race eff-race
           'minerals 300
           'gas 200
           'supply-used 28
           'supply-cap 36
           'supply-left 8
           'ally-units (for/list ([sym (in-list ENGINE-UNEXPECTED-UNIT-AND-BUILDING-SYMS)]
                                  [i (in-naturals)])
                         (hash 'id (+ 500 i) 'type sym 'x (+ 32.5 (* i 1.5)) 'y 32.5 'hp 50 'max-hp 50))
           'ally-buildings (list (hash 'id 201 'type 'unbuildable-plates 'x 32.5 'y 32.5 'hp 500)
                                 (hash 'id 202 'type 'mineral-field-750 'x 28.0 'y 28.0 'hp 1500))
           'enemy-units (for/list ([sym (in-list ENGINE-UNEXPECTED-UNIT-AND-BUILDING-SYMS)]
                                   [i (in-naturals)])
                          (hash 'id (+ 800 i) 'type sym 'x (+ 50.5 (* i 1.5)) 'y 56.5 'hp 45 'max-hp 45))
           'enemy-buildings (list (hash 'id 950 'type 'destructible-rock-ex1-vertical-huge 'x 50.5 'y 56.5 'hp 2000)))]))

(define (generate-degenerate-game-state-sexp prng idx [race 'Zerg])
  (define obs (generate-degenerate-game-state-frame prng idx race))
  (define (unit->tup u)
    (list (hash-ref u 'id 101)
          (hash-ref u 'type 'drone)
          (hash-ref u 'x 32.5)
          (hash-ref u 'y 32.5)
          (hash-ref u 'hp 40)
          (hash-ref u 'energy 0)))
  (define (bldg->tup b)
    (list (hash-ref b 'id 201)
          (hash-ref b 'type 'hatchery)
          (hash-ref b 'x 32.5)
          (hash-ref b 'y 32.5)
          (hash-ref b 'hp-pct 1.0)
          (hash-ref b 'build-progress 1.0)
          (hash-ref b 'halted #f)))
  (list 'frame-state
        '#:frame (hash-ref obs 'frame 0)
        '#:race (hash-ref obs 'race race)
        '#:minerals (hash-ref obs 'minerals 200)
        '#:gas (hash-ref obs 'gas 100)
        '#:supply-used (hash-ref obs 'supply-used 12)
        '#:supply-cap (hash-ref obs 'supply-cap 15)
        '#:supply-left (hash-ref obs 'supply-left 3)
        '#:start-pos (list (hash-ref obs 'base-x 32.5) (hash-ref obs 'base-y 32.5))
        '#:enemy-base (list (hash-ref obs 'enemy-x 160.5) (hash-ref obs 'enemy-y 160.5))
        '#:my-units (map unit->tup (hash-ref obs 'ally-units '()))
        '#:my-buildings (map bldg->tup (hash-ref obs 'ally-buildings '()))
        '#:enemy-units (map unit->tup (hash-ref obs 'enemy-units '()))
        '#:enemy-buildings (map bldg->tup (hash-ref obs 'enemy-buildings '()))
        '#:effects '((force-field 50.5 56.5))))

;; 3.3 Randomized Property-Based Frame & S-Expression Generator
(define (generate-random-property-frame prng idx [race 'Zerg])
  (define eff-race (if (eq? race 'Random) (prng-pick prng '(Zerg Protoss Terran)) race))
  (define frame (* (prng 600) 16))
  (define minerals (- (prng 2500) 50))
  (define gas (- (prng 1500) 25))
  (define supply-cap (* 8 (+ 2 (prng 24))))
  (define supply-used (min supply-cap (prng (+ supply-cap 10))))
  (define supply-left (- supply-cap supply-used))
  (define n-ally (prng 14))
  (define n-bldg (add1 (prng 8)))
  (define n-enemy (prng 14))
  (define n-ebldg (prng 5))
  (define ally-unit-pool (hash-ref SAMPLE-ALLY-UNITS-BY-RACE eff-race))
  (define ally-bldg-pool (hash-ref SAMPLE-ALLY-BLDGS-BY-RACE eff-race))

  (hash 'frame frame
        'race race
        'actual-race eff-race
        'minerals minerals
        'gas gas
        'supply-used supply-used
        'supply-cap supply-cap
        'supply-left supply-left
        'pending-supply (prng 3)
        'depleting-bases (prng 3)
        'mined-out (= (prng 10) 0)
        'under-cheese-rush (= (prng 12) 0)
        'natural-blocked (= (prng 12) 0)
        'nuke-alert (if (= (prng 20) 0) (cons 50.5 56.5) #f)
        'base-x 32.5
        'base-y 32.5
        'natural-x 50.5
        'natural-y 56.5
        'enemy-x 160.5
        'enemy-y 160.5
        'ally-units (for/list ([i (in-range n-ally)])
                      (hash 'id (+ 100 i)
                            'type (prng-pick prng ally-unit-pool)
                            'x (+ 24.0 (prng 60))
                            'y (+ 24.0 (prng 60))
                            'hp (+ 10 (prng 180))
                            'max-hp (+ 40 (prng 200))
                            'energy (prng 150)))
        'ally-buildings (for/list ([i (in-range n-bldg)])
                          (hash 'id (+ 200 i)
                                'type (list-ref ally-bldg-pool (modulo i (length ally-bldg-pool)))
                                'x (+ 28.0 (* i 3.0))
                                'y (+ 28.0 (* i 2.5))
                                'hp (+ 100 (prng 1400))
                                'max-hp 1500
                                'hp-pct (/ (+ 10.0 (prng 90)) 100.0)
                                'build-progress (if (= (prng 6) 0) 0.5 1.0)
                                'halted (= (prng 10) 0)
                                'energy (prng 100)))
        'enemy-units (for/list ([i (in-range n-enemy)])
                       (hash 'id (+ 900 i)
                             'type (prng-pick prng SAMPLE-ENEMY-UNITS)
                             'x (+ 28.0 (prng 140))
                             'y (+ 28.0 (prng 140))
                             'hp (+ 15 (prng 200))
                             'max-hp 200
                             'cloaked (= (prng 8) 0)
                             'burrowed (= (prng 8) 0)))
        'enemy-buildings (for/list ([i (in-range n-ebldg)])
                           (hash 'id (+ 950 i)
                                 'type (prng-pick prng '(hatchery lair spire roach-warren nexus gateway stargate robotics-facility command-center barracks factory starport photon-cannon bunker spine-crawler assimilator extractor refinery))
                                 'x (+ 32.0 (prng 140))
                                 'y (+ 32.0 (prng 140))
                                 'hp (+ 200 (prng 1300))
                                 'max-hp 1500
                                 'active? (= (prng 3) 0)
                                 'canceled? (= (prng 12) 0)))))

(define (generate-random-property-sexp prng idx [race 'Zerg])
  (define obs (generate-random-property-frame prng idx race))
  (list 'frame-state
        '#:frame (hash-ref obs 'frame 0)
        '#:race race
        '#:minerals (hash-ref obs 'minerals 200)
        '#:gas (hash-ref obs 'gas 100)
        '#:supply-used (hash-ref obs 'supply-used 12)
        '#:supply-cap (hash-ref obs 'supply-cap 15)
        '#:supply-left (hash-ref obs 'supply-left 3)
        '#:start-pos '(32.5 32.5)
        '#:enemy-base '(160.5 160.5)
        '#:my-units (for/list ([u (in-list (hash-ref obs 'ally-units '()))])
                      (list (hash-ref u 'id 101)
                            (hash-ref u 'type 'drone)
                            (hash-ref u 'x 32.5)
                            (hash-ref u 'y 32.5)
                            (hash-ref u 'hp 40)
                            (hash-ref u 'energy 0)))
        '#:my-buildings (for/list ([b (in-list (hash-ref obs 'ally-buildings '()))])
                          (list (hash-ref b 'id 201)
                                (hash-ref b 'type 'hatchery)
                                (hash-ref b 'x 32.5)
                                (hash-ref b 'y 32.5)
                                (hash-ref b 'hp-pct 1.0)
                                (hash-ref b 'build-progress 1.0)
                                (hash-ref b 'halted #f)))
        '#:enemy-units (for/list ([e (in-list (hash-ref obs 'enemy-units '()))])
                         (list (hash-ref e 'id 901)
                               (hash-ref e 'type 'marine)
                               (hash-ref e 'x 100.0)
                               (hash-ref e 'y 100.0)
                               (hash-ref e 'hp 45)))
        '#:enemy-buildings (for/list ([eb (in-list (hash-ref obs 'enemy-buildings '()))])
                             (list (hash-ref eb 'id 950)
                                   (hash-ref eb 'type 'barracks)
                                   (hash-ref eb 'x 150.0)
                                   (hash-ref eb 'y 150.0)
                                   (hash-ref eb 'hp 1000)))
        '#:effects '()))

(define (generate-multi-frame-trajectory prng race [steps 16])
  (define jump-schedule '#(0 1 224 672 1344 2688 6048 50000 0 3200))
  (for/list ([s (in-range steps)])
    (define base-obs
      (cond
        [(= (modulo s 5) 0) (generate-degenerate-game-state-frame prng s race)]
        [(= (modulo s 7) 0) (generate-boundary-numeric-frame prng s race)]
        [else               (generate-random-property-frame prng s race)]))
    (hash-set base-obs 'frame (vector-ref jump-schedule (modulo s (vector-length jump-schedule))))))

;; =============================================================================
;; 4. Target Function Fuzzers
;; =============================================================================

;; Target 1: `parse-frame-state-sexp` and `runtime-step-sexp!` (`lib/bot-runtime.rkt`)
(define (fuzz-parse-and-runtime-step-sexp! rt sexp)
  (define crashes '())
  (define contract-violations '())
  (define actions-checked 0)

  (define parsed
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! crashes (cons (list 'parse-frame-state-sexp (exn-message e) sexp) crashes))
                       (hash))])
      (parse-frame-state-sexp sexp)))

  (define emitted
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! crashes (cons (list 'runtime-step-sexp! (exn-message e) sexp) crashes))
                       '())])
      (runtime-step-sexp! rt sexp)))

  (when (list? emitted)
    (for ([act (in-list emitted)])
      (set! actions-checked (add1 actions-checked))
      (define res (check-emitted-action-sexp act parsed))
      (unless (action-contract-result-valid? res)
        (set! contract-violations
              (append (action-contract-result-violations res) contract-violations)))))

  (values crashes contract-violations actions-checked))

;; Target 2: `step-live-bot-runtime!` (`lib/bot-runtime.rkt`)
(define (fuzz-step-live-bot-runtime! rt obs)
  (define crashes '())
  (define contract-violations '())
  (define actions-checked 0)

  (define res
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! crashes (cons (list 'step-live-bot-runtime! (exn-message e) obs) crashes))
                       #f)])
      (step-live-bot-runtime! rt obs)))

  (when (hash? res)
    (define all-acts
      (append (hash-ref res 'actions '())
              (hash-ref res 'mirror-actions '())))
    (for ([act (in-list all-acts)])
      (set! actions-checked (add1 actions-checked))
      (define chk (check-emitted-action-sexp act obs))
      (unless (action-contract-result-valid? chk)
        (set! contract-violations
              (append (action-contract-result-violations chk) contract-violations)))))

  (values crashes contract-violations actions-checked))

;; Target 3: `step-mirror-mind-predictor!`, `compute-shadow-ledger`,
;;           `interpret-opponent-actions`, `evaluate-mirror-macro-verdict`,
;;           `choose-optimal-mirror-depth` (`lib/mirror-mind-predictor.rkt`)
(define (fuzz-mirror-mind-suite! mmstate obs prng)
  (define crashes '())
  (define contract-violations '())
  (define checks 0)

  (define frame (hash-ref obs 'frame 0))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))

  ;; 3a. `compute-shadow-ledger`
  (define ledger
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! crashes (cons (list 'compute-shadow-ledger (exn-message e) obs) crashes))
                       (mirror-mind-state-last-shadow-ledger mmstate))])
      (set! checks (add1 checks))
      (compute-shadow-ledger mmstate frame enemy-units enemy-bldgs)))

  ;; 3b. `interpret-opponent-actions`
  (define reading
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! crashes (cons (list 'interpret-opponent-actions (exn-message e) obs) crashes))
                       (mirror-mind-state-last-action-reading mmstate))])
      (set! checks (add1 checks))
      (interpret-opponent-actions mmstate frame enemy-units enemy-bldgs ledger)))

  ;; 3c. `evaluate-mirror-macro-verdict`
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (set! crashes (cons (list 'evaluate-mirror-macro-verdict (exn-message e) obs) crashes)))])
    (set! checks (add1 checks))
    (evaluate-mirror-macro-verdict mmstate frame ally-units ally-bldgs
                                   enemy-units enemy-bldgs ledger reading))

  ;; 3d. `choose-optimal-mirror-depth`
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (set! crashes (cons (list 'choose-optimal-mirror-depth (exn-message e) obs) crashes)))])
    (set! checks (add1 checks))
    (define scores
      (if (= (prng 4) 0)
          (hash 0 (prng) 1 (prng) 2 (prng) 3 (prng) 4 (prng) 5 (prng))
          #f))
    (choose-optimal-mirror-depth mmstate #:depth-accuracy-scores scores))

  ;; 3e. `step-mirror-mind-predictor!`
  (define mm-acts
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! crashes (cons (list 'step-mirror-mind-predictor! (exn-message e) obs) crashes))
                       '())])
      (set! checks (add1 checks))
      (step-mirror-mind-predictor! mmstate obs)))

  (when (list? mm-acts)
    (for ([act (in-list mm-acts)])
      (set! checks (add1 checks))
      (define chk (check-emitted-action-sexp act obs))
      (unless (action-contract-result-valid? chk)
        (set! contract-violations
              (append (action-contract-result-violations chk) contract-violations)))))

  (values crashes contract-violations checks))

;; Target 4: `evaluate-coupled-macro-governor`, `evaluate-adaptive-build-and-tech-plan`,
;;           `evaluate-guns-vs-butter-ppf`, `compute-optimal-gas-workers` (`lib/econ-ledger.rkt`)
(define (fuzz-econ-ledger-suite! obs prng)
  (define crashes '())
  (define contract-violations '())
  (define checks 0)

  (define race (hash-ref obs 'actual-race (hash-ref obs 'race 'Zerg)))
  (define frame (hash-ref obs 'frame 0))
  (define minerals (hash-ref obs 'minerals 200))
  (define gas (hash-ref obs 'gas 100))
  (define supply-left (hash-ref obs 'supply-left 4))
  (define supply-cap (hash-ref obs 'supply-cap 22))
  (define depleting-bases (hash-ref obs 'depleting-bases 0))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define bldg-syms
    (if (list? ally-bldgs)
        (map extract-unit-type-sym ally-bldgs)
        '()))
  (define unit-syms
    (if (list? ally-units)
        (map extract-unit-type-sym ally-units)
        '()))

  ;; 4a. `evaluate-coupled-macro-governor`
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (set! crashes (cons (list 'evaluate-coupled-macro-governor (exn-message e) obs) crashes)))])
    (set! checks (add1 checks))
    (evaluate-coupled-macro-governor
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left supply-left
     #:active-bases (if (list? ally-bldgs) (length ally-bldgs) 1)
     #:depleting-bases depleting-bases
     #:workers (if (list? ally-units) (length ally-units) 12)
     #:pending-workers (prng 4)
     #:production-facilities (max 1 (prng 6))
     #:busy-facilities (prng 6)
     #:busy-townhalls (prng 4)
     #:under-crisis? (= (prng 5) 0)
     #:recommended-min-bases (add1 (prng 5))))

  ;; 4b. `evaluate-adaptive-build-and-tech-plan`
  (define tech-plan
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! crashes (cons (list 'evaluate-adaptive-build-and-tech-plan (exn-message e) obs) crashes))
                       #f)])
      (set! checks (add1 checks))
      (evaluate-adaptive-build-and-tech-plan
       race
       #:ally-buildings bldg-syms
       #:ally-units unit-syms
       #:researched-upgrades '()
       #:enemy-archetype (prng-pick prng '(standard-macro bio-ball mech-siege air-fleet sky-toss muta-flock stalker-colossus roach-ravager lurker-contain early-rush))
       #:mirror-predicted-unit (prng-pick prng SAMPLE-ENEMY-UNITS)
       #:mirror-macro-verdict (prng-pick prng '(punish-And-Deny-Greedy-Expand out-Expand-Passive-Turtle defend-All-In-Then-Counter-Expand pace-Macro-And-Disrupt))
       #:requires-detection? (= (prng 3) 0)
       #:requires-anti-air? (= (prng 3) 0)
       #:enemy-upgrade-advantage (- (prng 4) 1)
       #:minerals minerals
       #:gas gas)))

  (when (adaptive-tech-plan? tech-plan)
    ;; Validate every priority upgrade & emitted next-action in `adaptive-tech-plan`
    (for ([u (in-list (adaptive-tech-plan-priority-upgrades tech-plan))])
      (set! checks (add1 checks))
      (define chk (check-emitted-action-sexp (list 'research u) obs))
      (unless (action-contract-result-valid? chk)
        (set! contract-violations
              (append (action-contract-result-violations chk) contract-violations))))
    (for ([act (in-list (adaptive-tech-plan-next-actions tech-plan))])
      (set! checks (add1 checks))
      (define chk (check-emitted-action-sexp act obs))
      (unless (action-contract-result-valid? chk)
        (set! contract-violations
              (append (action-contract-result-violations chk) contract-violations)))))

  ;; 4c. `compute-optimal-gas-workers`
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (set! crashes (cons (list 'compute-optimal-gas-workers (exn-message e) obs) crashes)))])
    (set! checks (add1 checks))
    (compute-optimal-gas-workers
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:workers (if (list? ally-units) (length ally-units) 16)
     #:active-bases (max 1 (prng 5))
     #:active-geysers (prng 6)
     #:current-gas-workers (prng 12)
     #:should-expand? (= (prng 2) 0)
     #:tech-gas-demand (* 50 (prng 6))
     #:under-crisis? (= (prng 5) 0)))

  ;; 4d. `evaluate-guns-vs-butter-ppf`
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (set! crashes (cons (list 'evaluate-guns-vs-butter-ppf (exn-message e) obs) crashes)))])
    (set! checks (add1 checks))
    (evaluate-guns-vs-butter-ppf
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left supply-left
     #:supply-cap supply-cap
     #:workers (if (list? ally-units) (length ally-units) 16)
     #:target-workers 44
     #:active-bases (max 1 (prng 5))
     #:depleting-bases depleting-bases
     #:active-geysers (prng 6)
     #:current-gas-workers (prng 12)
     #:production-facilities (max 1 (prng 6))
     #:busy-facilities (prng 6)
     #:army-count (if (list? ally-units) (length ally-units) 4)
     #:missing-synergy-count (prng 5)
     #:fap-score (- (prng 80) 40)
     #:under-crisis? (= (prng 5) 0)
     #:mirror-macro-verdict (prng-pick prng '(punish-And-Deny-Greedy-Expand out-Expand-Passive-Turtle defend-All-In-Then-Counter-Expand pace-Macro-And-Disrupt))
     #:enemy-upgrade-advantage (- (prng 4) 1)
     #:enemy-active-research-count (prng 3)
     #:requires-detection? (= (prng 3) 0)
     #:requires-anti-air? (= (prng 3) 0)))

  (values crashes contract-violations checks))

;; Target 5: `step-zerospace-mastermind!` (`lib/zerospace-mastermind.rkt`)
(define (fuzz-zerospace-mastermind-suite! mstate obs prng)
  (define crashes '())
  (define contract-violations '())
  (define checks 0)

  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define ally-bldgs
    (let ([ab (hash-ref obs 'ally-buildings '())])
      (if (list? ab) (map extract-unit-type-sym ab) '())))

  (with-handlers ([exn:fail?
                   (lambda (e)
                     (set! crashes (cons (list 'step-zerospace-mastermind! (exn-message e) obs) crashes)))])
    (set! checks (add1 checks))
    (cond
      [(procedure-arity-includes? step-zerospace-mastermind! 2)
       (step-zerospace-mastermind! mstate obs)]
      [else
       (step-zerospace-mastermind! mstate
                                   #:fap-score (- (prng 100) 50)
                                   #:enemy-units (if (list? enemy-units) enemy-units '())
                                   #:ally-buildings ally-bldgs
                                   #:self-workers (prng 80)
                                   #:enemy-workers (prng 80)
                                   #:self-army (* 50 (prng 40))
                                   #:enemy-army (* 50 (prng 40)))]))

  (values crashes contract-violations checks))

;; =============================================================================
;; 5. Full Campaign Runner (`run-bot-crash-and-contract-fuzzer`)
;; =============================================================================

(struct fuzz-campaign-report
  (seed
   total-frames-fuzzed
   total-trajectories-fuzzed
   total-contract-checks
   races-covered
   category-frame-counts
   total-crashes
   total-contract-violations
   crashes-by-function
   violations-by-kind
   sample-crashes
   sample-violations
   passed?)
  #:transparent)

(define (run-bot-crash-and-contract-fuzzer #:iterations [raw-iterations 10000]
                                           #:frames [raw-frames #f]
                                           #:seed [seed 20261107])
  (define iterations (or raw-frames raw-iterations))
  (define prng (make-deterministic-prng seed))
  (define total-frames 0)
  (define total-trajectories 0)
  (define total-checks 0)
  (define total-crashes 0)
  (define total-violations 0)

  (define cat-counts (make-hash))
  (define crash-by-fn (make-hash))
  (define viol-by-kind (make-hash))
  (define sample-crashes '())
  (define sample-violations '())

  (define (record-crashes! cs)
    (for ([c (in-list cs)])
      (set! total-crashes (add1 total-crashes))
      (define fn-name (first c))
      (hash-set! crash-by-fn fn-name (add1 (hash-ref crash-by-fn fn-name 0)))
      (when (< (length sample-crashes) 25)
        (set! sample-crashes (append sample-crashes (list c))))))

  (define (record-violations! vs)
    (for ([v (in-list vs)])
      (set! total-violations (add1 total-violations))
      (define kind (first v))
      (hash-set! viol-by-kind kind (add1 (hash-ref viol-by-kind kind 0)))
      (when (< (length sample-violations) 25)
        (set! sample-violations (append sample-violations (list v))))))

  (define (bump-cat! cat [n 1])
    (hash-set! cat-counts cat (+ (hash-ref cat-counts cat 0) n)))

  ;; Maintain reusable runtime instances per race + periodic fresh resets
  (define runtimes
    (for/hash ([r (in-list ALL-FUZZ-RACES)])
      (values r (make-live-bot-runtime #:race r))))
  (define mm-states
    (for/hash ([r (in-list ALL-FUZZ-RACES)])
      (values r (make-mirror-mind-state #:our-race (if (eq? r 'Random) 'Zerg r)))))
  (define m-states
    (for/hash ([r (in-list ALL-FUZZ-RACES)])
      (values r (make-mastermind-state (if (eq? r 'Random) 'Zerg r)))))

  ;; Phase 1: Single-frame adversarial, boundary numeric, degenerate, and property fuzzing
  (for ([idx (in-range iterations)])
    (define race (list-ref ALL-FUZZ-RACES (modulo idx (length ALL-FUZZ-RACES))))
    (define rt
      (if (zero? (modulo idx 250))
          (make-live-bot-runtime #:race race)
          (hash-ref runtimes race)))
    (define mmstate (hash-ref mm-states race))
    (define mstate (hash-ref m-states race))

    (define mode (modulo idx 10))
    (cond
      ;; 20%: Boundary numeric fuzzing (0, -1, -99999, 999999, +nan.0, +inf.0, -inf.0, 1/3, #f, 'null, "bad", '())
      [(< mode 2)
       (bump-cat! 'boundary-numeric-frames)
       (set! total-frames (add1 total-frames))
       (define obs (generate-boundary-numeric-frame prng idx race))
       (define sexp (generate-boundary-numeric-sexp prng idx race))
       (define-values (c1 v1 k1) (fuzz-parse-and-runtime-step-sexp! rt sexp))
       (define-values (c2 v2 k2) (fuzz-step-live-bot-runtime! rt obs))
       (define-values (c3 v3 k3) (fuzz-mirror-mind-suite! mmstate obs prng))
       (define-values (c4 v4 k4) (fuzz-econ-ledger-suite! obs prng))
       (define-values (c5 v5 k5) (fuzz-zerospace-mastermind-suite! mstate obs prng))
       (set! total-checks (+ total-checks k1 k2 k3 k4 k5))
       (record-crashes! (append c1 c2 c3 c4 c5))
       (record-violations! (append v1 v2 v3 v4 v5))]

      ;; 30%: Degenerate & extreme game states (all 10 scenarios)
      [(< mode 5)
       (bump-cat! 'degenerate-extreme-states)
       (set! total-frames (add1 total-frames))
       (define obs (generate-degenerate-game-state-frame prng idx race))
       (define sexp (generate-degenerate-game-state-sexp prng idx race))
       (define-values (c1 v1 k1) (fuzz-parse-and-runtime-step-sexp! rt sexp))
       (define-values (c2 v2 k2) (fuzz-step-live-bot-runtime! rt obs))
       (define-values (c3 v3 k3) (fuzz-mirror-mind-suite! mmstate obs prng))
       (define-values (c4 v4 k4) (fuzz-econ-ledger-suite! obs prng))
       (define-values (c5 v5 k5) (fuzz-zerospace-mastermind-suite! mstate obs prng))
       (set! total-checks (+ total-checks k1 k2 k3 k4 k5))
       (record-crashes! (append c1 c2 c3 c4 c5))
       (record-violations! (append v1 v2 v3 v4 v5))]

      ;; 50%: Randomized property-based SC2 LotV frames
      [else
       (bump-cat! 'randomized-property-frames)
       (set! total-frames (add1 total-frames))
       (define obs (generate-random-property-frame prng idx race))
       (define sexp
         (if (even? idx)
             (generate-random-property-sexp prng idx race)
             #f))
       (when sexp
         (define-values (c1 v1 k1) (fuzz-parse-and-runtime-step-sexp! rt sexp))
         (set! total-checks (+ total-checks k1))
         (record-crashes! c1)
         (record-violations! v1))
       (define-values (c2 v2 k2) (fuzz-step-live-bot-runtime! rt obs))
       (define-values (c3 v3 k3) (fuzz-mirror-mind-suite! mmstate obs prng))
       (define-values (c4 v4 k4) (fuzz-econ-ledger-suite! obs prng))
       (define-values (c5 v5 k5) (fuzz-zerospace-mastermind-suite! mstate obs prng))
       (set! total-checks (+ total-checks k2 k3 k4 k5))
       (record-crashes! (append c2 c3 c4 c5))
       (record-violations! (append v2 v3 v4 v5))]))

  ;; Phase 2: Multi-frame stateful trajectories across all 4 races (40 trajectories x 12 frames = 480 frames)
  (for ([t-idx (in-range 40)])
    (define race (list-ref ALL-FUZZ-RACES (modulo t-idx (length ALL-FUZZ-RACES))))
    (define rt (make-live-bot-runtime #:race race))
    (define mmstate (make-mirror-mind-state #:our-race (if (eq? race 'Random) 'Zerg race)))
    (define traj (generate-multi-frame-trajectory prng race 12))
    (set! total-trajectories (add1 total-trajectories))
    (for ([obs (in-list traj)])
      (bump-cat! 'multi-frame-trajectory-steps)
      (set! total-frames (add1 total-frames))
      (define-values (c2 v2 k2) (fuzz-step-live-bot-runtime! rt obs))
      (define-values (c3 v3 k3) (fuzz-mirror-mind-suite! mmstate obs prng))
      (set! total-checks (+ total-checks k2 k3))
      (record-crashes! (append c2 c3))
      (record-violations! (append v2 v3))))

  (fuzz-campaign-report
   seed
   total-frames
   total-trajectories
   total-checks
   ALL-FUZZ-RACES
   (for/hash ([(k v) (in-hash cat-counts)]) (values k v))
   total-crashes
   total-violations
   (for/hash ([(k v) (in-hash crash-by-fn)]) (values k v))
   (for/hash ([(k v) (in-hash viol-by-kind)]) (values k v))
   sample-crashes
   sample-violations
   (and (zero? total-crashes) (zero? total-violations))))

(define (print-fuzz-campaign-report rep)
  (printf "============================================================================\n")
  (printf "  SC2 LotV Pure-Racket Crash & Actuator-Contract Fuzzing Report\n")
  (printf "============================================================================\n")
  (printf "  Deterministic Seed          : ~a\n" (fuzz-campaign-report-seed rep))
  (printf "  Races Covered               : ~a\n" (fuzz-campaign-report-races-covered rep))
  (printf "  Total Frames Fuzzed         : ~a\n" (fuzz-campaign-report-total-frames-fuzzed rep))
  (printf "  Multi-Frame Trajectories    : ~a\n" (fuzz-campaign-report-total-trajectories-fuzzed rep))
  (printf "  Contract & Target Checks    : ~a\n" (fuzz-campaign-report-total-contract-checks rep))
  (printf "  Category Breakdown          :\n")
  (for ([(cat cnt) (in-hash (fuzz-campaign-report-category-frame-counts rep))])
    (printf "    - ~a: ~a frames\n" cat cnt))
  (printf "  Total Runtime Crashes       : ~a\n" (fuzz-campaign-report-total-crashes rep))
  (when (> (fuzz-campaign-report-total-crashes rep) 0)
    (for ([(fn cnt) (in-hash (fuzz-campaign-report-crashes-by-function rep))])
      (printf "    * [CRASH] ~a : ~a occurrences\n" fn cnt))
    (printf "  Sample Crash Diagnostics    :\n")
    (for ([sc (in-list (take (fuzz-campaign-report-sample-crashes rep)
                             (min 8 (length (fuzz-campaign-report-sample-crashes rep)))))])
      (printf "    ! ~a -> ~a\n" (first sc) (second sc))))
  (printf "  Total Contract Violations   : ~a\n" (fuzz-campaign-report-total-contract-violations rep))
  (when (> (fuzz-campaign-report-total-contract-violations rep) 0)
    (for ([(vk cnt) (in-hash (fuzz-campaign-report-violations-by-kind rep))])
      (printf "    * [VIOLATION] ~a : ~a occurrences\n" vk cnt))
    (printf "  Sample Contract Violations  :\n")
    (for ([sv (in-list (take (fuzz-campaign-report-sample-violations rep)
                             (min 10 (length (fuzz-campaign-report-sample-violations rep)))))])
      (printf "    ! ~a: ~v in action ~v\n" (first sv) (second sv) (third sv))))
  (printf "  Campaign Verdict            : ~a\n"
          (if (fuzz-campaign-report-passed? rep)
              "PASS (0 crashes, 0 contract violations)"
              "VIOLATIONS DETECTED (see breakdown above)"))
  (printf "============================================================================\n"))

;; =============================================================================
;; 6. Contract Self-Checks (30/30 Positive & Negative Contract Verifications)
;; =============================================================================

(define (run-contract-self-checks! #:print-report? [print-report? #f])
  (define total 0)
  (define passed 0)
  (define (check-self! label ok?)
    (set! total (add1 total))
    (when ok?
      (set! passed (add1 passed)))
    (when print-report?
      (printf "  [~a] ~a\n" (if ok? "PASS" "FAIL") label))
    (unless ok?
      (error 'run-contract-self-checks! "Contract self-check failed: ~a" label)))

  ;; 6 valid SC2 LotV actions across Zerg, Protoss, Terran
  (check-self! "Valid Zerg build `(build spawning-pool 38 38)`"
               (validate-emitted-action-sexp '(build spawning-pool 38 38)))
  (check-self! "Valid Zerg upgrade `(research centrifical-hooks)`"
               (validate-emitted-action-sexp '(research centrifical-hooks)))
  (check-self! "Valid Zerg upgrade `(research metabolic-boost)`"
               (validate-emitted-action-sexp '(research metabolic-boost)))
  (check-self! "Valid Protoss morph `(morph warp-gate)`"
               (validate-emitted-action-sexp '(morph warp-gate)))
  (check-self! "Valid Protoss build `(build robotics-bay 42 42)`"
               (validate-emitted-action-sexp '(build robotics-bay 42 42)))
  (check-self! "Valid Terran train `(train widow-mine)`"
               (validate-emitted-action-sexp '(train widow-mine)))

  ;; 13 forbidden BroodWar / non-LotV unit & building symbols
  (for ([sym (in-list '(sunken-colony
                        spore-colony
                        dragoon
                        reaver
                        shuttle
                        science-vessel
                        science-facility
                        covert-ops
                        machine-shop
                        vulture
                        medic
                        robotics-support-bay
                        warpgate))])
    (check-self! (format "Reject forbidden BroodWar/invalid symbol `~a`" sym)
                 (and (not (validate-emitted-action-sexp (list 'build sym 32.5 32.5)))
                      (not (validate-emitted-action-sexp (list 'train sym))))))

  ;; 9 forbidden / misspelled upgrade symbols
  (for ([upg (in-list '(centrifugal-hooks
                        lockdown
                        lurker-aspect
                        zergling-speed
                        singularity-charge
                        leg-enhancements
                        scarab-damage
                        charon-boosters
                        irradiate))])
    (check-self! (format "Reject forbidden/misspelled upgrade `~a`" upg)
                 (not (validate-emitted-action-sexp (list 'research upg)))))

  ;; 2 tactical invariant checks on `(pull-workers-attack ...)`
  (check-self! "Reject `(pull-workers-attack ...)` when only nearby enemies are flying scouts"
               (not (validate-emitted-action-sexp
                     '(pull-workers-attack 4 34.0 34.0)
                     (hash 'base-x 32.5 'base-y 32.5
                           'enemy-units (list (hash 'id 901 'type 'overlord 'x 34.0 'y 34.0))
                           'enemy-buildings '()))))
  (check-self! "Allow `(pull-workers-attack ...)` against ground proxy/cannon rush"
               (validate-emitted-action-sexp
                '(pull-workers-attack 4 34.0 34.0)
                (hash 'base-x 32.5 'base-y 32.5
                      'enemy-units (list (hash 'id 902 'type 'zealot 'x 34.0 'y 34.0))
                      'enemy-buildings (list (hash 'id 903 'type 'photon-cannon 'x 35.0 'y 35.0)))))

  (when print-report?
    (printf "  Total Contract Self-Checks Passed: ~a/~a\n" passed total))
  (cons passed total))

(module+ main
  (require "state-machine-verifier.rkt")
  (printf "============================================================================\n")
  (printf "  Part 1: Formal State-Machine & Invariant Verifier (`state-machine-verifier.rkt`)\n")
  (printf "============================================================================\n")
  (printf "  [EXEC] Invoking `run-all-formal-verifications` from `lib/state-machine-verifier.rkt` ...\n")
  (define sm-res (run-all-formal-verifications))
  (printf "  [DONE] `run-all-formal-verifications` completed: ~v\n\n" sm-res)

  (printf "============================================================================\n")
  (printf "  Part 2: SC2 LotV Actuator & Symbol Contract Self-Verification\n")
  (printf "============================================================================\n")
  (void (run-contract-self-checks! #:print-report? #t))
  (printf "\n")

  (define rep (run-bot-crash-and-contract-fuzzer #:frames 10000 #:seed 20261107))
  (print-fuzz-campaign-report rep)
  (unless (fuzz-campaign-report-passed? rep)
    (error 'bot-crash-fuzzer "Fuzz campaign detected crashes or contract violations!")))

