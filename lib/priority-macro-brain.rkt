#lang racket/base

(require racket/list
         racket/match
         racket/math
         racket/string
         "sc2-common.rkt"
         "sc2-game-constants.rkt"
         "build-orders.rkt"
         "econ-ledger.rkt"
         "situational-counter-planner.rkt")

(provide
 ;; 1. Declarative SC2 Tech, Cost, Build-Time, Facility-Slot & Prerequisite DAG
 (struct-out sc2-tech-node)
 SC2-TECH-GRAPH
 lookup-sc2-tech-node
 sc2-tech-prereqs-ready?
 sc2-tech-already-satisfied?
 resolve-missing-prereq-chain
 find-all-broken-tech-dependencies

 ;; 2. Decoupled Macro World State, Dynamic Goal-Plan & Priority Macro Brain
 (struct-out plan-goal-node)
 (struct-out dynamic-macro-plan)
 (struct-out macro-world-state)
 (struct-out macro-brain-decision)
 macro-world-state-enemy-unit-counts
 macro-world-state-enemy-building-counts
 translate-goal-to-next-action
 synthesize-dynamic-macro-plan
 macro-brain-decision-dynamic-plan
 make-macro-world-state
 obs-hash->macro-world-state
 step-priority-macro-brain
 macro-brain-can-spend?
 zerg-queen-target
 creep-self-sustaining?
 (struct-out bo-tactical-phase-plan)
 (struct-out bo-active-tactical-plan)
 PRO-BO-TACTICAL-PHASE-PLANS
 pro-tactical-phases-for-matchup
 evaluate-build-order-tactical-plan
 compute-enemy-comp-attrs
 detect-build-order-deviation
 evaluate-post-bo-strategic-goals
 bo-active-tactical-plan-target-location
 bo-active-tactical-plan-micro-profile
 bo-active-tactical-plan-abort-condition
 bo-active-tactical-plan-strategic-goals
 macro-world-state-mirror-signals
 macro-world-state-depleting-bases
 macro-world-state-natural-blocked?
 macro-world-state->ledger-hash
 reset-macro-escrow-tracker!
 macro-escrow-sync-entry!
 macro-escrow-record-decision!
 macro-escrow-in-backoff?

 ;; 3. Fast Standalone Macro Simulator & Chaos Monkey Engine
 (struct-out macro-sim-task)
 (struct-out macro-sim-state)
 (struct-out chaos-monkey-event)
 (struct-out chaos-monkey-trial-result)
 make-initial-macro-sim-state
 step-macro-sim!
 chaos-monkey-delete!
 run-chaos-monkey-build-order-trial
 run-chaos-monkey-campaign)

;; =============================================================================
;; 1. Declarative SC2 Tech, Cost, Build-Time, Facility-Slot & Prerequisite DAG
;; =============================================================================
;; Centralizes all SC2 LotV rules for costs, supply, producer slots, and tech
;; prerequisites so that build-order evaluation, priority scheduling, and
;; Chaos Monkey self-healing recovery operate from a single source of truth.

(struct sc2-tech-node
  (id              ;; symbol (e.g., 'zergling, 'barracks-techlab, 'stimpack)
   race            ;; 'Zerg | 'Terran | 'Protoss
   kind            ;; 'train | 'build | 'expand | 'morph | 'research | 'addon
   category        ;; 'supply | 'worker | 'expansion | 'counter-tech | 'tech-upgrade | 'production-scaling | 'combat-unit
   min-cost        ;; exact nonnegative integer
   gas-cost        ;; exact nonnegative integer
   supply-cost     ;; exact nonnegative integer
   supply-provided ;; exact nonnegative integer
   build-frames    ;; exact positive integer (at 22.4 fps faster game speed)
   producer-slot   ;; symbol: 'larva | 'townhall | 'worker | 'barracks | 'barracks-techlab | ...
   prereqs         ;; list of structure/addon symbols that must be READY
   unique?)        ;; boolean: #t for single-instance tech structures or upgrades
  #:transparent)

(define SC2-TECH-NODES-LIST
  (list
   (sc2-tech-node 'gravitic-drive 'Protoss 'research 'tech-upgrade 100 100 0 0 1280 'robotics-bay '(robotics-bay) #t)
   (sc2-tech-node 'hyperflight-rotors 'Terran 'research 'tech-upgrade 150 150 0 0 2240 'starport-techlab '(starport-techlab) #t)
   (sc2-tech-node 'cyclone-lock-on-damage 'Terran 'research 'tech-upgrade 100 100 0 0 1760 'factory-techlab '(factory-techlab) #t)
   ;; -------------------------------------------------------------------------
   ;; ZERG
   ;; -------------------------------------------------------------------------
   (sc2-tech-node 'hatchery            'Zerg 'expand   'expansion          300   0 0 6 1590 'worker            '()                                 #f)
   (sc2-tech-node 'drone               'Zerg 'train    'worker              50   0 1 0  270 'larva             '()                                 #f)
   (sc2-tech-node 'overlord            'Zerg 'train    'supply             100   0 0 8  400 'larva             '()                                 #f)
   (sc2-tech-node 'extractor           'Zerg 'build    'production-scaling  25   0 0 0  480 'worker            '()                                 #f)
   (sc2-tech-node 'spawning-pool       'Zerg 'build    'production-scaling 200   0 0 0 1040 'worker            '(hatchery)                         #t)
   (sc2-tech-node 'queen               'Zerg 'train    'counter-tech       150   0 2 0  800 'townhall          '(spawning-pool)                    #f)
   (sc2-tech-node 'zergling            'Zerg 'train    'combat-unit         50   0 1 0  380 'larva             '(spawning-pool)                    #f)
   (sc2-tech-node 'spine-crawler       'Zerg 'build    'counter-tech       100   0 0 0  800 'worker            '(spawning-pool)                    #f)
   (sc2-tech-node 'spore-crawler       'Zerg 'build    'counter-tech        75   0 0 0  480 'worker            '(spawning-pool)                    #f)
   (sc2-tech-node 'roach-warren        'Zerg 'build    'production-scaling 150   0 0 0  880 'worker            '(spawning-pool)                    #t)
   (sc2-tech-node 'baneling-nest       'Zerg 'build    'production-scaling 100  50 0 0  960 'worker            '(spawning-pool)                    #t)
   (sc2-tech-node 'evolution-chamber   'Zerg 'build    'production-scaling  75   0 0 0  560 'worker            '(hatchery)                         #t)
   (sc2-tech-node 'roach               'Zerg 'train    'combat-unit         75  25 2 0  430 'larva             '(roach-warren)                     #f)
   (sc2-tech-node 'ravager             'Zerg 'morph    'combat-unit         25  75 1 0  190 'roach             '(roach-warren)                     #f)
   (sc2-tech-node 'baneling            'Zerg 'morph    'combat-unit         25  25 0 0  320 'zergling          '(baneling-nest)                    #f)
   (sc2-tech-node 'lair                'Zerg 'morph    'tech-upgrade       150 100 0 0 1280 'townhall          '(spawning-pool)                    #t)
   (sc2-tech-node 'overseer            'Zerg 'morph    'counter-tech        50  50 0 0  270 'overlord          '(lair)                             #f)
   (sc2-tech-node 'overlord-transport  'Zerg 'morph    'combat-unit         25  25 0 0  270 'overlord          '(lair)                             #f)
   (sc2-tech-node 'hydralisk-den       'Zerg 'build    'counter-tech       100 100 0 0  640 'worker            '(lair)                             #t)
   (sc2-tech-node 'hydralisk           'Zerg 'train    'combat-unit        100  50 2 0  540 'larva             '(hydralisk-den)                    #f)
   (sc2-tech-node 'lurker-den          'Zerg 'build    'counter-tech       100 150 0 0 1288 'worker            '(hydralisk-den lair)               #t)
   (sc2-tech-node 'lurker              'Zerg 'morph    'combat-unit         50 100 1 0  403 'hydralisk         '(lurker-den)                       #f)
   (sc2-tech-node 'infestation-pit     'Zerg 'build    'tech-upgrade       100 100 0 0  800 'worker            '(lair)                             #t)
   (sc2-tech-node 'infestor            'Zerg 'train    'combat-unit        100 150 2 0  670 'larva             '(infestation-pit)                  #f)
   (sc2-tech-node 'hive                'Zerg 'morph    'tech-upgrade       200 150 0 0 1600 'townhall          '(infestation-pit lair)             #t)
   (sc2-tech-node 'viper               'Zerg 'train    'combat-unit        100 200 3 0  640 'larva             '(hive)                             #f)
   (sc2-tech-node 'ultralisk-cavern    'Zerg 'build    'tech-upgrade       150 200 0 0 1040 'worker            '(hive)                             #t)
   (sc2-tech-node 'ultralisk           'Zerg 'train    'combat-unit        275 200 6 0  880 'larva             '(ultralisk-cavern)                 #f)
   (sc2-tech-node 'spire               'Zerg 'build    'tech-upgrade       200 200 0 0 1600 'worker            '(lair)                             #t)
   (sc2-tech-node 'greater-spire       'Zerg 'morph    'tech-upgrade       100 150 0 0 1600 'spire             '(spire hive)                       #t)
   (sc2-tech-node 'mutalisk            'Zerg 'train    'combat-unit        100 100 2 0  540 'larva             '(spire)                            #f)
   (sc2-tech-node 'corruptor           'Zerg 'train    'combat-unit        150 100 2 0  640 'larva             '(spire)                            #f)
   (sc2-tech-node 'brood-lord          'Zerg 'morph    'combat-unit        150 150 2 0  540 'corruptor         '(greater-spire)                    #f)
   (sc2-tech-node 'metabolic-boost     'Zerg 'research 'tech-upgrade       100 100 0 0 1760 'spawning-pool     '(spawning-pool)                    #t)
   (sc2-tech-node 'zergling-attackspeed 'Zerg 'research 'tech-upgrade      200 200 0 0 2080 'spawning-pool     '(spawning-pool hive)               #t)
   (sc2-tech-node 'burrow              'Zerg 'research 'tech-upgrade       100 100 0 0 1600 'townhall          '(hatchery)                         #t)
   (sc2-tech-node 'pneumatized-carapace 'Zerg 'research 'tech-upgrade      100 100 0 0  960 'townhall          '(hatchery)                         #t)
   (sc2-tech-node 'glial-reconstitution 'Zerg 'research 'tech-upgrade      100 100 0 0 1760 'roach-warren      '(roach-warren lair)                #t)
   (sc2-tech-node 'tunneling-claws     'Zerg 'research 'tech-upgrade       100 100 0 0 1760 'roach-warren      '(roach-warren lair)                #t)
   (sc2-tech-node 'centrifical-hooks   'Zerg 'research 'tech-upgrade       150 150 0 0 1760 'baneling-nest     '(baneling-nest lair)               #t)
   (sc2-tech-node 'zerg-melee-weapons-1 'Zerg 'research 'tech-upgrade      100 100 0 0 2560 'evolution-chamber '(evolution-chamber)                #t)
   (sc2-tech-node 'zerg-melee-weapons-2 'Zerg 'research 'tech-upgrade      150 150 0 0 3040 'evolution-chamber '(evolution-chamber lair)           #t)
   (sc2-tech-node 'zerg-melee-weapons-3 'Zerg 'research 'tech-upgrade      200 200 0 0 3520 'evolution-chamber '(evolution-chamber hive)           #t)
   (sc2-tech-node 'zerg-missile-weapons-1 'Zerg 'research 'tech-upgrade    100 100 0 0 2560 'evolution-chamber '(evolution-chamber)                #t)
   (sc2-tech-node 'zerg-missile-weapons-2 'Zerg 'research 'tech-upgrade    150 150 0 0 3040 'evolution-chamber '(evolution-chamber lair)           #t)
   (sc2-tech-node 'zerg-missile-weapons-3 'Zerg 'research 'tech-upgrade    200 200 0 0 3520 'evolution-chamber '(evolution-chamber hive)           #t)
   (sc2-tech-node 'zerg-ground-armor-1 'Zerg 'research 'tech-upgrade       150 150 0 0 2560 'evolution-chamber '(evolution-chamber)                #t)
   (sc2-tech-node 'zerg-ground-armor-2 'Zerg 'research 'tech-upgrade       225 225 0 0 3040 'evolution-chamber '(evolution-chamber lair)           #t)
   (sc2-tech-node 'zerg-ground-armor-3 'Zerg 'research 'tech-upgrade       300 300 0 0 3520 'evolution-chamber '(evolution-chamber hive)           #t)
   (sc2-tech-node 'zerg-flyer-weapons-1 'Zerg 'research 'tech-upgrade      100 100 0 0 2560 'spire             '(spire)                            #t)
   (sc2-tech-node 'zerg-flyer-weapons-2 'Zerg 'research 'tech-upgrade      175 175 0 0 3040 'spire             '(spire lair)                       #t)
   (sc2-tech-node 'zerg-flyer-weapons-3 'Zerg 'research 'tech-upgrade      250 250 0 0 3520 'spire             '(spire hive)                       #t)
   (sc2-tech-node 'zerg-flyer-armor-1   'Zerg 'research 'tech-upgrade      150 150 0 0 2560 'spire             '(spire)                            #t)
   (sc2-tech-node 'zerg-flyer-armor-2   'Zerg 'research 'tech-upgrade      225 225 0 0 3040 'spire             '(spire lair)                       #t)
   (sc2-tech-node 'zerg-flyer-armor-3   'Zerg 'research 'tech-upgrade      300 300 0 0 3520 'spire             '(spire hive)                       #t)
   (sc2-tech-node 'grooved-spines      'Zerg 'research 'tech-upgrade       100 100 0 0 1120 'hydralisk-den     '(hydralisk-den)                    #t)
   (sc2-tech-node 'muscular-augments   'Zerg 'research 'tech-upgrade       100 100 0 0 1120 'hydralisk-den     '(hydralisk-den lair)               #t)
   (sc2-tech-node 'adaptive-talons     'Zerg 'research 'tech-upgrade       150 150 0 0 1120 'lurker-den        '(lurker-den hive)                  #t)
   (sc2-tech-node 'seismic-spines      'Zerg 'research 'tech-upgrade       150 150 0 0 1280 'lurker-den        '(lurker-den hive)                  #t)
   (sc2-tech-node 'neural-parasite     'Zerg 'research 'tech-upgrade       150 150 0 0 1760 'infestation-pit   '(infestation-pit)                  #t)
   (sc2-tech-node 'chitinous-plating   'Zerg 'research 'tech-upgrade       150 150 0 0 1760 'ultralisk-cavern  '(ultralisk-cavern)                 #t)
   (sc2-tech-node 'anabolic-synthesis  'Zerg 'research 'tech-upgrade       150 150 0 0  960 'ultralisk-cavern  '(ultralisk-cavern hive)            #t)

   ;; -------------------------------------------------------------------------
   ;; TERRAN
   ;; -------------------------------------------------------------------------
   (sc2-tech-node 'command-center      'Terran 'expand   'expansion          400   0 0 15 1600 'worker            '()                                 #f)
   (sc2-tech-node 'scv                 'Terran 'train    'worker              50   0 1  0  270 'townhall          '()                                 #f)
   (sc2-tech-node 'supply-depot        'Terran 'build    'supply             100   0 0  8  480 'worker            '()                                 #f)
   (sc2-tech-node 'refinery            'Terran 'build    'production-scaling  75   0 0  0  480 'worker            '()                                 #f)
   (sc2-tech-node 'barracks            'Terran 'build    'production-scaling 150   0 0  0 1040 'worker            '(supply-depot)                     #f)
   (sc2-tech-node 'orbital-command     'Terran 'morph    'tech-upgrade       150   0 0  0  560 'townhall          '(barracks)                         #f)
   (sc2-tech-node 'planetary-fortress  'Terran 'morph    'counter-tech       150 150 0  0  800 'townhall          '(engineering-bay)                  #f)
   (sc2-tech-node 'barracks-techlab    'Terran 'addon    'production-scaling  50  25 0  0  400 'barracks          '(barracks)                         #f)
   (sc2-tech-node 'barracks-reactor    'Terran 'addon    'production-scaling  50  50 0  0  800 'barracks          '(barracks)                         #f)
   (sc2-tech-node 'marine              'Terran 'train    'combat-unit         50   0 1  0  400 'barracks          '(barracks)                         #f)
   (sc2-tech-node 'marauder            'Terran 'train    'combat-unit        100  25 2  0  480 'barracks          '(barracks barracks-techlab)        #f)
   (sc2-tech-node 'reaper              'Terran 'train    'combat-unit         50  50 1  0  720 'barracks          '(barracks)                         #f)
   (sc2-tech-node 'ghost-academy       'Terran 'build    'tech-upgrade       150  50 0  0  640 'worker            '(barracks)                         #t)
   (sc2-tech-node 'ghost               'Terran 'train    'combat-unit        150 125 2  0  640 'barracks          '(barracks barracks-techlab ghost-academy) #f)
   (sc2-tech-node 'factory             'Terran 'build    'production-scaling 150 100 0  0  960 'worker            '(barracks)                         #t)
   (sc2-tech-node 'factory-techlab     'Terran 'addon    'counter-tech        50  25 0  0  400 'factory           '(factory)                          #t)
   (sc2-tech-node 'factory-reactor     'Terran 'addon    'production-scaling  50  50 0  0  800 'factory           '(factory)                          #f)
   (sc2-tech-node 'hellion             'Terran 'train    'combat-unit        100   0 2  0  480 'factory           '(factory)                          #f)
   (sc2-tech-node 'hellbat             'Terran 'train    'combat-unit        100   0 2  0  480 'factory           '(factory armory)                   #f)
   (sc2-tech-node 'widow-mine          'Terran 'train    'combat-unit         75  25 2  0  450 'factory           '(factory)                          #f)
   (sc2-tech-node 'cyclone             'Terran 'train    'combat-unit        150 100 3  0  720 'factory           '(factory factory-techlab)          #f)
   (sc2-tech-node 'siege-tank          'Terran 'train    'combat-unit        150 125 3  0  720 'factory           '(factory factory-techlab)          #f)
   (sc2-tech-node 'thor                'Terran 'train    'combat-unit        300 200 6  0  960 'factory           '(factory factory-techlab armory)   #f)
   (sc2-tech-node 'starport            'Terran 'build    'production-scaling 150 100 0  0  800 'worker            '(factory)                          #t)
   (sc2-tech-node 'starport-reactor    'Terran 'addon    'production-scaling  50  50 0  0  800 'starport          '(starport)                         #t)
   (sc2-tech-node 'starport-techlab    'Terran 'addon    'production-scaling  50  25 0  0  400 'starport          '(starport)                         #t)
   (sc2-tech-node 'medivac             'Terran 'train    'combat-unit        100 100 2  0  670 'starport          '(starport)                         #f)
   (sc2-tech-node 'viking-fighter      'Terran 'train    'counter-tech       150  75 2  0  670 'starport          '(starport)                         #f)
   (sc2-tech-node 'liberator           'Terran 'train    'combat-unit        150 125 3  0  960 'starport          '(starport)                         #f)
   (sc2-tech-node 'banshee             'Terran 'train    'combat-unit        150 100 3  0  960 'starport          '(starport starport-techlab)        #f)
   (sc2-tech-node 'raven               'Terran 'train    'counter-tech       100 150 2  0  760 'starport          '(starport starport-techlab)        #f)
   (sc2-tech-node 'fusion-core         'Terran 'build    'tech-upgrade       150 150 0  0 1040 'worker            '(starport)                         #t)
   (sc2-tech-node 'battlecruiser       'Terran 'train    'combat-unit        400 300 6  0 1440 'starport          '(starport starport-techlab fusion-core) #f)
   (sc2-tech-node 'engineering-bay     'Terran 'build    'counter-tech       125   0 0  0  560 'worker            '(command-center)                   #t)
   (sc2-tech-node 'bunker              'Terran 'build    'counter-tech       100   0 0  0  640 'worker            '(barracks)                         #f)
   (sc2-tech-node 'missile-turret      'Terran 'build    'counter-tech       100   0 0  0  400 'worker            '(engineering-bay)                  #f)
   (sc2-tech-node 'armory              'Terran 'build    'tech-upgrade       150 100 0  0 1040 'worker            '(factory)                          #t)
   (sc2-tech-node 'stimpack            'Terran 'research 'tech-upgrade       100 100 0  0 2240 'barracks-techlab  '(barracks-techlab)                 #t)
   (sc2-tech-node 'combat-shield       'Terran 'research 'tech-upgrade       100 100 0  0 1760 'barracks-techlab  '(barracks-techlab)                 #t)
   (sc2-tech-node 'concussive-shells   'Terran 'research 'tech-upgrade        50  50 0  0  960 'barracks-techlab  '(barracks-techlab)                 #t)
   (sc2-tech-node 'terran-infantry-weapons-1 'Terran 'research 'tech-upgrade 100 100 0  0 2560 'engineering-bay   '(engineering-bay)                  #t)
   (sc2-tech-node 'terran-infantry-weapons-2 'Terran 'research 'tech-upgrade 175 175 0  0 3040 'engineering-bay   '(engineering-bay armory)           #t)
   (sc2-tech-node 'terran-infantry-weapons-3 'Terran 'research 'tech-upgrade 250 250 0  0 3520 'engineering-bay   '(engineering-bay armory)           #t)
   (sc2-tech-node 'terran-infantry-armor-1   'Terran 'research 'tech-upgrade 100 100 0  0 2560 'engineering-bay   '(engineering-bay)                  #t)
   (sc2-tech-node 'terran-infantry-armor-2   'Terran 'research 'tech-upgrade 175 175 0  0 3040 'engineering-bay   '(engineering-bay armory)           #t)
   (sc2-tech-node 'terran-infantry-armor-3   'Terran 'research 'tech-upgrade 250 250 0  0 3520 'engineering-bay   '(engineering-bay armory)           #t)
   (sc2-tech-node 'terran-vehicle-weapons-1  'Terran 'research 'tech-upgrade 100 100 0  0 2560 'armory            '(armory)                           #t)
   (sc2-tech-node 'terran-vehicle-weapons-2  'Terran 'research 'tech-upgrade 175 175 0  0 3040 'armory            '(armory)                           #t)
   (sc2-tech-node 'terran-vehicle-weapons-3  'Terran 'research 'tech-upgrade 250 250 0  0 3520 'armory            '(armory)                           #t)
   (sc2-tech-node 'terran-ship-weapons-1     'Terran 'research 'tech-upgrade 100 100 0  0 2560 'armory            '(armory)                           #t)
   (sc2-tech-node 'terran-ship-weapons-2     'Terran 'research 'tech-upgrade 175 175 0  0 3040 'armory            '(armory)                           #t)
   (sc2-tech-node 'terran-ship-weapons-3     'Terran 'research 'tech-upgrade 250 250 0  0 3520 'armory            '(armory)                           #t)
   (sc2-tech-node 'terran-vehicle-and-ship-plating-1 'Terran 'research 'tech-upgrade 100 100 0 0 2560 'armory     '(armory)                           #t)
   (sc2-tech-node 'terran-vehicle-and-ship-plating-2 'Terran 'research 'tech-upgrade 175 175 0 0 3040 'armory     '(armory)                           #t)
   (sc2-tech-node 'terran-vehicle-and-ship-plating-3 'Terran 'research 'tech-upgrade 250 250 0 0 3520 'armory     '(armory)                           #t)
   (sc2-tech-node 'infernal-pre-igniter 'Terran 'research 'tech-upgrade      100 100 0  0 1760 'factory-techlab   '(factory-techlab)                  #t)
   (sc2-tech-node 'drilling-claws      'Terran 'research 'tech-upgrade        75  75 0  0 1760 'factory-techlab   '(factory-techlab armory)           #t)
   (sc2-tech-node 'banshee-cloak       'Terran 'research 'tech-upgrade       100 100 0  0 1760 'starport-techlab  '(starport-techlab)                 #t)
   (sc2-tech-node 'advanced-ballistics 'Terran 'research 'tech-upgrade       150 150 0  0 1280 'starport-techlab  '(fusion-core starport-techlab)     #t)
   (sc2-tech-node 'weapon-refit        'Terran 'research 'tech-upgrade       150 150 0  0  960 'fusion-core       '(fusion-core)                      #t)
   (sc2-tech-node 'personal-cloaking   'Terran 'research 'tech-upgrade       150 150 0  0 1920 'ghost-academy     '(ghost-academy)                    #t)

   ;; -------------------------------------------------------------------------
   ;; PROTOSS
   ;; -------------------------------------------------------------------------
   (sc2-tech-node 'nexus               'Protoss 'expand   'expansion          400   0 0 15 1600 'worker            '()                                 #f)
   (sc2-tech-node 'probe               'Protoss 'train    'worker              50   0 1  0  270 'townhall          '()                                 #f)
   (sc2-tech-node 'pylon               'Protoss 'build    'supply             100   0 0  8  400 'worker            '()                                 #f)
   (sc2-tech-node 'assimilator         'Protoss 'build    'production-scaling  75   0 0  0  480 'worker            '()                                 #f)
   (sc2-tech-node 'gateway             'Protoss 'build    'production-scaling 150   0 0  0 1040 'worker            '(pylon)                            #f)
   (sc2-tech-node 'cybernetics-core    'Protoss 'build    'production-scaling 150   0 0  0  800 'worker            '(pylon gateway)                    #t)
   (sc2-tech-node 'shield-battery      'Protoss 'build    'counter-tech       100   0 0  0  400 'worker            '(pylon cybernetics-core)           #f)
   (sc2-tech-node 'zealot              'Protoss 'train    'combat-unit        100   0 2  0  600 'gateway           '(gateway)                          #f)
   (sc2-tech-node 'stalker             'Protoss 'train    'combat-unit        125  50 2  0  670 'gateway           '(gateway cybernetics-core)         #f)
   (sc2-tech-node 'sentry              'Protoss 'train    'combat-unit         50 100 2  0  580 'gateway           '(gateway cybernetics-core)         #f)
   (sc2-tech-node 'adept               'Protoss 'train    'combat-unit        100  25 2  0  670 'gateway           '(gateway cybernetics-core)         #f)
   (sc2-tech-node 'robotics-facility   'Protoss 'build    'counter-tech       150 100 0  0 1040 'worker            '(pylon cybernetics-core)           #t)
   (sc2-tech-node 'observer            'Protoss 'train    'counter-tech        25  75 1  0  480 'robotics-facility '(robotics-facility)                #f)
   (sc2-tech-node 'warp-prism          'Protoss 'train    'combat-unit        250   0 2  0  800 'robotics-facility '(robotics-facility)                #f)
   (sc2-tech-node 'immortal            'Protoss 'train    'combat-unit        275 100 4  0  880 'robotics-facility '(robotics-facility)                #f)
   (sc2-tech-node 'robotics-bay        'Protoss 'build    'tech-upgrade       150 150 0  0 1040 'worker            '(pylon robotics-facility)          #t)
   (sc2-tech-node 'colossus            'Protoss 'train    'combat-unit        300 200 6  0 1200 'robotics-facility '(robotics-facility robotics-bay)   #f)
   (sc2-tech-node 'disruptor           'Protoss 'train    'combat-unit        150 150 3  0  800 'robotics-facility '(robotics-facility robotics-bay)   #f)
   (sc2-tech-node 'stargate            'Protoss 'build    'production-scaling 150 150 0  0  960 'worker            '(pylon cybernetics-core)           #t)
   (sc2-tech-node 'phoenix             'Protoss 'train    'counter-tech       150 100 2  0  560 'stargate          '(stargate)                         #f)
   (sc2-tech-node 'oracle              'Protoss 'train    'combat-unit        150 150 3  0  830 'stargate          '(stargate)                         #f)
   (sc2-tech-node 'void-ray            'Protoss 'train    'combat-unit        250 150 4  0  960 'stargate          '(stargate)                         #f)
   (sc2-tech-node 'fleet-beacon        'Protoss 'build    'tech-upgrade       300 200 0  0  960 'worker            '(pylon stargate)                   #t)
   (sc2-tech-node 'carrier             'Protoss 'train    'combat-unit        350 250 6  0 1440 'stargate          '(stargate fleet-beacon)            #f)
   (sc2-tech-node 'tempest             'Protoss 'train    'combat-unit        250 175 5  0  960 'stargate          '(stargate fleet-beacon)            #f)
   (sc2-tech-node 'twilight-council    'Protoss 'build    'tech-upgrade       150 100 0  0  800 'worker            '(pylon cybernetics-core)           #t)
   (sc2-tech-node 'templar-archive     'Protoss 'build    'tech-upgrade       150 200 0  0  800 'worker            '(pylon twilight-council)           #t)
   (sc2-tech-node 'dark-shrine         'Protoss 'build    'tech-upgrade       150 150 0  0 1600 'worker            '(pylon twilight-council)           #t)
   (sc2-tech-node 'high-templar        'Protoss 'train    'combat-unit         50 150 2  0  880 'gateway           '(gateway templar-archive)          #f)
   (sc2-tech-node 'dark-templar        'Protoss 'train    'combat-unit        125 125 2  0  880 'gateway           '(gateway dark-shrine)              #f)
   (sc2-tech-node 'archon              'Protoss 'morph    'combat-unit          0   0 0  0  270 'high-templar      '(templar-archive)                  #f)
   (sc2-tech-node 'forge               'Protoss 'build    'tech-upgrade       150   0 0  0  720 'worker            '(pylon gateway)                    #t)
   (sc2-tech-node 'photon-cannon       'Protoss 'build    'counter-tech       150   0 0  0  640 'worker            '(pylon forge)                      #f)
   (sc2-tech-node 'warp-gate-research  'Protoss 'research 'tech-upgrade        50  50 0  0 2240 'cybernetics-core  '(cybernetics-core)                 #t)
   (sc2-tech-node 'charge              'Protoss 'research 'tech-upgrade       100 100 0  0 2240 'twilight-council  '(twilight-council)                 #t)
   (sc2-tech-node 'blink               'Protoss 'research 'tech-upgrade       150 150 0  0 2240 'twilight-council  '(twilight-council)                 #t)
   (sc2-tech-node 'resonating-glaives  'Protoss 'research 'tech-upgrade       100 100 0  0 2240 'twilight-council  '(twilight-council)                 #t)
   (sc2-tech-node 'protoss-ground-weapons-1 'Protoss 'research 'tech-upgrade  100 100 0  0 2880 'forge             '(forge)                            #t)
   (sc2-tech-node 'protoss-ground-weapons-2 'Protoss 'research 'tech-upgrade  150 150 0  0 3440 'forge             '(forge twilight-council)           #t)
   (sc2-tech-node 'protoss-ground-weapons-3 'Protoss 'research 'tech-upgrade  200 200 0  0 4000 'forge             '(forge twilight-council)           #t)
   (sc2-tech-node 'protoss-ground-armor-1   'Protoss 'research 'tech-upgrade  100 100 0  0 2880 'forge             '(forge)                            #t)
   (sc2-tech-node 'protoss-ground-armor-2   'Protoss 'research 'tech-upgrade  150 150 0  0 3440 'forge             '(forge twilight-council)           #t)
   (sc2-tech-node 'protoss-ground-armor-3   'Protoss 'research 'tech-upgrade  200 200 0  0 4000 'forge             '(forge twilight-council)           #t)
   (sc2-tech-node 'protoss-shields-1        'Protoss 'research 'tech-upgrade  150 150 0  0 2880 'forge             '(forge)                            #t)
   (sc2-tech-node 'protoss-shields-2        'Protoss 'research 'tech-upgrade  225 225 0  0 3440 'forge             '(forge twilight-council)           #t)
   (sc2-tech-node 'protoss-shields-3        'Protoss 'research 'tech-upgrade  300 300 0  0 4000 'forge             '(forge twilight-council)           #t)
   (sc2-tech-node 'protoss-air-weapons-1    'Protoss 'research 'tech-upgrade  100 100 0  0 2880 'cybernetics-core  '(cybernetics-core)                 #t)
   (sc2-tech-node 'protoss-air-weapons-2    'Protoss 'research 'tech-upgrade  175 175 0  0 3440 'cybernetics-core  '(cybernetics-core fleet-beacon)    #t)
   (sc2-tech-node 'protoss-air-weapons-3    'Protoss 'research 'tech-upgrade  250 250 0  0 4000 'cybernetics-core  '(cybernetics-core fleet-beacon)    #t)
   (sc2-tech-node 'protoss-air-armor-1      'Protoss 'research 'tech-upgrade  150 150 0  0 2880 'cybernetics-core  '(cybernetics-core)                 #t)
   (sc2-tech-node 'protoss-air-armor-2      'Protoss 'research 'tech-upgrade  225 225 0  0 3440 'cybernetics-core  '(cybernetics-core fleet-beacon)    #t)
   (sc2-tech-node 'protoss-air-armor-3      'Protoss 'research 'tech-upgrade  300 300 0  0 4000 'cybernetics-core  '(cybernetics-core fleet-beacon)    #t)
   (sc2-tech-node 'extended-thermal-lance   'Protoss 'research 'tech-upgrade  150 150 0  0 2240 'robotics-bay      '(robotics-bay)                     #t)
   (sc2-tech-node 'gravitic-booster         'Protoss 'research 'tech-upgrade  100 100 0  0 1280 'robotics-bay      '(robotics-bay)                     #t)
   (sc2-tech-node 'psi-storm                'Protoss 'research 'tech-upgrade  200 200 0  0 1760 'templar-archive   '(templar-archive)                  #t)
   (sc2-tech-node 'shadow-strike            'Protoss 'research 'tech-upgrade  100 100 0  0 2240 'dark-shrine       '(dark-shrine)                      #t)))

(define SC2-TECH-GRAPH
  (for/hasheq ([n (in-list SC2-TECH-NODES-LIST)])
    (values (sc2-tech-node-id n) n)))

;; Normalizes unit, structure, add-on, and upgrade aliases onto SC2-TECH-GRAPH node IDs.
(define *brain-sym-norm-ht*
  (hasheq
   'shield-wall                    'combat-shield
   'punisher-grenades              'concussive-shells
   'blink-tech                     'blink
   'adept-piercing-attack          'resonating-glaives
   'observer-gravitic-booster      'gravitic-booster
   'gravitic-boosters              'gravitic-booster
   'high-capacity-barrels          'infernal-pre-igniter
   'infernal-preigniter            'infernal-pre-igniter
   'drill-claws                    'drilling-claws
   'zerg-ling-metabolic-boost      'metabolic-boost
   'protoss-air-weapons-level-1    'protoss-air-weapons-1
   'protoss-air-weapons-level-2    'protoss-air-weapons-2
   'protoss-air-weapons-level-3    'protoss-air-weapons-3
   'protoss-air-armor-level-1      'protoss-air-armor-1
   'protoss-air-armor-level-2      'protoss-air-armor-2
   'protoss-air-armor-level-3      'protoss-air-armor-3
   'protoss-air-armors-1           'protoss-air-armor-1
   'protoss-air-armors-2           'protoss-air-armor-2
   'protoss-air-armors-3           'protoss-air-armor-3
   'cyclone-lock-on-damage-upgrade 'cyclone-lock-on-damage
   'mag-field-accelerator          'cyclone-lock-on-damage
   'viking                         'viking-fighter
   'viking-assault            'viking-fighter
   'siege-tank-sieged         'siege-tank
   'widow-mine-burrowed       'widow-mine
   'thor-ap                   'thor
   'liberator-ag              'liberator
   'broodlord                 'brood-lord
   'voidray                   'void-ray
   'lurker-mp                 'lurker
   'lurker-burrowed           'lurker
   'lurker-mp-burrowed        'lurker
   'overseer-siege-mode       'overseer
   'overlord-cocoon           'overseer
   'transport-overlord-cocoon 'overlord-transport
   'lurker-den-mp             'lurker-den
   'robotics-support-bay      'robotics-bay
   'templar-archives          'templar-archive
   'barracks-tech-lab         'barracks-techlab
   'factory-tech-lab          'factory-techlab
   'starport-tech-lab         'starport-techlab
   'zergling-movementspeed    'metabolic-boost
   'centrifugal-hooks         'centrifical-hooks
   'cloaking-field            'banshee-cloak
   'adrenal-glands            'zergling-attackspeed
   'warpgate-research         'warp-gate-research
   'melee-attacks-1           'zerg-melee-weapons-1
   'melee-attacks-2           'zerg-melee-weapons-2
   'melee-attacks-3           'zerg-melee-weapons-3
   'missile-attacks-1         'zerg-missile-weapons-1
   'missile-attacks-2         'zerg-missile-weapons-2
   'missile-attacks-3         'zerg-missile-weapons-3
   'ground-carapace-1         'zerg-ground-armor-1
   'ground-carapace-2         'zerg-ground-armor-2
   'ground-carapace-3         'zerg-ground-armor-3
   'infantry-weapons-1        'terran-infantry-weapons-1
   'infantry-weapons-2        'terran-infantry-weapons-2
   'infantry-weapons-3        'terran-infantry-weapons-3
   'infantry-armor-1          'terran-infantry-armor-1
   'infantry-armor-2          'terran-infantry-armor-2
   'infantry-armor-3          'terran-infantry-armor-3
   'ground-weapons-1          'protoss-ground-weapons-1
   'ground-weapons-2          'protoss-ground-weapons-2
   'ground-weapons-3          'protoss-ground-weapons-3
   'ground-armor-1            'protoss-ground-armor-1
   'ground-armor-2            'protoss-ground-armor-2
   'ground-armor-3            'protoss-ground-armor-3
   'shields-1                 'protoss-shields-1
   'shields-2                 'protoss-shields-2
   'shields-3                 'protoss-shields-3
   'zerg-flyer-armors-1       'zerg-flyer-armor-1
   'zerg-flyer-armors-2       'zerg-flyer-armor-2
   'zerg-flyer-armors-3       'zerg-flyer-armor-3
   'zerg-flyer-carapace-1     'zerg-flyer-armor-1
   'zerg-flyer-carapace-2     'zerg-flyer-armor-2
   'zerg-flyer-carapace-3     'zerg-flyer-armor-3
   'protoss-air-armors-1      'protoss-air-armor-1
   'protoss-air-armors-2      'protoss-air-armor-2
   'protoss-air-armors-3      'protoss-air-armor-3
   'terran-vehicle-and-ship-armors-1 'terran-vehicle-and-ship-plating-1
   'terran-vehicle-and-ship-armors-2 'terran-vehicle-and-ship-plating-2
   'terran-vehicle-and-ship-armors-3 'terran-vehicle-and-ship-plating-3
   'hellion-tank              'hellbat
   'creeping-queen            'queen))

(define (normalize-brain-sym sym)
  (hash-ref *brain-sym-norm-ht* sym sym))

(define (creep-self-sustaining? active-creep-tumors active-bases)
  (define tumors
    (if (real? active-creep-tumors)
        (max 0 (inexact->exact (floor active-creep-tumors)))
        0))
  (define bases
    (if (real? active-bases)
        (max 1 (inexact->exact (floor active-bases)))
        1))
  (>= tumors (min 6 (* 2 bases))))

(define (same-brain-sym? a b)
  (and (symbol? a)
       (symbol? b)
       (eq? (hash-ref *brain-sym-norm-ht* a a)
            (hash-ref *brain-sym-norm-ht* b b))))

(define *tech-node-cache* (make-hasheq))

(define (lookup-sc2-tech-node sym)
  (and (symbol? sym)
       (let ([hit (hash-ref *tech-node-cache* sym 'miss)])
         (if (eq? hit 'miss)
             (let ([v (hash-ref SC2-TECH-GRAPH (hash-ref *brain-sym-norm-ht* sym sym) #f)])
               (hash-set! *tech-node-cache* sym v)
               v)
             hit))))

(define current-ready-bldg-cache (make-parameter #f))
(define current-total-bldg-cache (make-parameter #f))
(define current-unit-count-cache (make-parameter #f))

(define *struct-equiv-syms-cache* (make-hasheq))

(define (cached-struct-equiv-syms sym)
  (or (hash-ref *struct-equiv-syms-cache* sym #f)
      (let ([lst (sc2-structure-equivalent-syms sym #f)])
        (hash-set! *struct-equiv-syms-cache* sym lst)
        lst)))

(define (sum-equiv-bldg-ht ht sym)
  (if (hash? ht)
      (let ([syms (cached-struct-equiv-syms sym)])
        (if (and (pair? syms) (null? (cdr syms)))
            (let ([v (hash-ref ht (car syms) 0)])
              (if (exact-integer? v) v 0))
            (for/sum ([s (in-list syms)])
              (define v (hash-ref ht s 0))
              (if (exact-integer? v) v 0))))
      0))

;; Delegates structure equivalence (morphs, flying Terran buildings, lowered depots,
;; rich geysers, uprooted crawlers, overcharged pylons, LotV structure aliases) to
;; `sc2-count-equivalent-structures` with `include-free-addons? = #f` so unattached
;; add-ons never falsely satisfy attached TechLab/Reactor prerequisites and
;; `starport-techlab` is never double-counted as `starport-reactor`.
(define (bldg-count-equivalent ht sym)
  (define rc (current-ready-bldg-cache))
  (cond
    [(and rc (eq? ht (car rc)) (symbol? sym))
     (define cht (cdr rc))
     (or (hash-ref cht sym #f)
         (let ([v (sum-equiv-bldg-ht ht sym)])
           (hash-set! cht sym v)
           v))]
    [else
     (define tc (current-total-bldg-cache))
     (cond
       [(and tc (eq? ht (car tc)) (symbol? sym))
        (define cht (cdr tc))
        (or (hash-ref cht sym #f)
            (let ([v (sum-equiv-bldg-ht ht sym)])
              (hash-set! cht sym v)
              v))]
       [else
        (sum-equiv-bldg-ht ht sym)])]))

;; Counts equivalent unit modes (fighter/assault, tank/sieged, burrowed, phasing, transport).
(define *unit-equiv-syms-cache* (make-hasheq))

(define (cached-unit-equiv-syms sym)
  (or (hash-ref *unit-equiv-syms-cache* sym #f)
      (let ([lst (remove-duplicates (sc2-unit-equivalent-syms sym) eq?)])
        (hash-set! *unit-equiv-syms-cache* sym lst)
        lst)))

(define (unit-count-equivalent-uncached ht sym)
  (define syms (cached-unit-equiv-syms sym))
  (cond
    [(null? syms) 0]
    [(null? (cdr syms)) (hash-ref ht (car syms) 0)]
    [else (for/sum ([s (in-list syms)]) (hash-ref ht s 0))]))

(define (unit-count-equivalent ht sym)
  (define uc (current-unit-count-cache))
  (if (and uc (eq? ht (car uc)) (symbol? sym))
      (let ([cht (cdr uc)])
        (or (hash-ref cht sym #f)
            (let ([v (unit-count-equivalent-uncached ht sym)])
              (hash-set! cht sym v)
              v)))
      (unit-count-equivalent-uncached ht sym)))

(define (addon-parent-facility sym)
  (case (normalize-brain-sym sym)
    [(barracks-techlab barracks-reactor) 'barracks]
    [(factory-techlab factory-reactor)   'factory]
    [(starport-techlab starport-reactor) 'starport]
    [else #f]))

(define (parent-attached-addon-count parent-fac bldg-counts)
  (case parent-fac
    [(barracks)
     (+ (bldg-count-equivalent bldg-counts 'barracks-techlab)
        (bldg-count-equivalent bldg-counts 'barracks-reactor))]
    [(factory)
     (+ (bldg-count-equivalent bldg-counts 'factory-techlab)
        (bldg-count-equivalent bldg-counts 'factory-reactor))]
    [(starport)
     (+ (bldg-count-equivalent bldg-counts 'starport-techlab)
        (bldg-count-equivalent bldg-counts 'starport-reactor))]
    [else 0]))

(define (terr-free-addons-saturate-all-facilities? total-bldg-counts)
  (define free-addons
    (+ (hash-ref total-bldg-counts 'tech-lab 0)
       (hash-ref total-bldg-counts 'techlab 0)
       (hash-ref total-bldg-counts 'reactor 0)))
  (if (<= free-addons 0)
      #f
      (let ([total-attached-addons
             (+ (parent-attached-addon-count 'barracks total-bldg-counts)
                (parent-attached-addon-count 'factory total-bldg-counts)
                (parent-attached-addon-count 'starport total-bldg-counts))]
            [total-terr-facilities
             (+ (bldg-count-equivalent total-bldg-counts 'barracks)
                (bldg-count-equivalent total-bldg-counts 'factory)
                (bldg-count-equivalent total-bldg-counts 'starport))])
        (and (> total-terr-facilities 0)
             (>= (+ free-addons total-attached-addons) total-terr-facilities)))))

;; Returns #f if `sym` is not a Terran add-on, or one of:
;; - 'ready-slot-free    : at least one ready parent facility has a free add-on slot right now
;; - 'parent-in-progress : ready parents are occupied, but an under-construction parent has a free slot
;; - 'needs-new-parent   : all existing+pending parent facilities are occupied; another parent is needed
(define (addon-parent-slot-state sym ready-bldg-counts total-bldg-counts)
  (define parent-fac (addon-parent-facility sym))
  (cond
    [(not parent-fac) #f]
    [(terr-free-addons-saturate-all-facilities? total-bldg-counts) 'needs-new-parent]
    [else
     (define ready-facs (bldg-count-equivalent ready-bldg-counts parent-fac))
     (define total-facs (bldg-count-equivalent total-bldg-counts parent-fac))
     (define fac-addons (parent-attached-addon-count parent-fac total-bldg-counts))
     (cond
       [(> ready-facs fac-addons) 'ready-slot-free]
       [(> total-facs fac-addons) 'parent-in-progress]
       [else 'needs-new-parent])]))

;; Checks whether all ready facilities of the parent type for `sym` already have
;; attached add-ons (or all Terran facilities on map are saturated by attached + free add-ons).
(define (facility-addon-slot-occupied? sym ready-bldg-counts total-bldg-counts
                                       #:min-ready-floor [min-ready-floor 0])
  (define parent-fac (addon-parent-facility sym))
  (cond
    [(not parent-fac) #f]
    [else
     (define ready-facs (bldg-count-equivalent ready-bldg-counts parent-fac))
     (define fac-addons (parent-attached-addon-count parent-fac total-bldg-counts))
     (or (>= fac-addons (max min-ready-floor ready-facs))
         (terr-free-addons-saturate-all-facilities? total-bldg-counts))]))

;; Distinguishes genuine anti-air vs detection vs static ground-defense responses under attack
;; so non-defensive tech/upgrades never starve combat units during an active enemy attack.
(define (is-aa-or-detection-answer? sym requires-anti-air? requires-detection?)
  (define csym (normalize-brain-sym sym))
  (or (memq csym '(spine-crawler bunker shield-battery planetary-fortress))
      (and requires-anti-air?
           (memq csym '(queen spore-crawler lair hydralisk-den hydralisk spire corruptor mutalisk zerg-flyer-armor-1
                        marine missile-turret engineering-bay viking-fighter starport thor cyclone
                        stalker cybernetics-core photon-cannon stargate fleet-beacon phoenix void-ray tempest)))
      (and requires-detection?
           (memq csym '(spore-crawler overseer lair
                        missile-turret engineering-bay orbital-command raven starport starport-techlab
                        observer robotics-facility photon-cannon forge)))))

(define (single-prereq-ready? ready-bldg-counts prereq-sym)
  (or (not prereq-sym)
      (> (bldg-count-equivalent ready-bldg-counts prereq-sym) 0)))

(define UNIT-MORPH-SOURCE-SLOTS
  '(zergling hydralisk roach corruptor overlord high-templar))

;; Plain morph-source unit count so `'overlord-transport` never masks or satisfies `'overlord` morph capacity.
(define (morph-source-unit-count unit-counts slot-sym)
  (if (eq? slot-sym 'overlord)
      (hash-ref unit-counts 'overlord 0)
      (unit-count-equivalent unit-counts slot-sym)))

;; Goal count accessor: keeps `'overlord-transport` separate from plain Overlords.
(define (unit-count-for-goal unit-counts sym)
  (define csym (normalize-brain-sym sym))
  (if (eq? csym 'overlord-transport)
      (+ (hash-ref unit-counts 'overlord-transport 0)
         (hash-ref unit-counts 'transport-overlord-cocoon 0))
      (unit-count-equivalent unit-counts sym)))

(define (unit-morph-slot-ready? slot-sym unit-counts [used-counts #f])
  (define needed (if (eq? slot-sym 'high-templar) 2 1))
  (define avail
    (- (morph-source-unit-count unit-counts slot-sym)
       (if used-counts (hash-ref used-counts slot-sym 0) 0)))
  (>= avail needed))

(define (sc2-tech-prereqs-ready? sym ready-bldg-counts [unit-counts (hash)])
  (define node (lookup-sc2-tech-node sym))
  (cond
    [(not node) #t]
    [else
     (define csym (sc2-tech-node-id node))
     (define prereqs-ok?
       (for/and ([p (in-list (sc2-tech-node-prereqs node))])
         (single-prereq-ready? ready-bldg-counts p)))
     (define morph-source-ok?
       (case (sc2-tech-node-kind node)
         [(morph)
          (define pslot (sc2-tech-node-producer-slot node))
          (cond
            [(eq? pslot 'townhall)
             (case csym
               [(lair) (> (hash-ref ready-bldg-counts 'hatchery 0) 0)]
               [(hive) (> (hash-ref ready-bldg-counts 'lair 0) 0)]
               [(orbital-command planetary-fortress)
                (> (+ (hash-ref ready-bldg-counts 'command-center 0)
                      (hash-ref ready-bldg-counts 'command-center-flying 0))
                   0)]
               [else (> (bldg-count-equivalent ready-bldg-counts 'hatchery) 0)])]
            [(eq? pslot 'spire)
             (> (hash-ref ready-bldg-counts 'spire 0) 0)]
            [(eq? csym 'archon)
             (>= (unit-count-equivalent unit-counts 'high-templar) 2)]
            [else
             (> (morph-source-unit-count unit-counts pslot) 0)])]
         [else #t]))
     (and prereqs-ok? morph-source-ok?)]))

(define (sc2-tech-already-satisfied? sym total-bldg-counts researched-upgs pending-upgs [target-count 1])
  (define node (lookup-sc2-tech-node sym))
  (cond
    [(not node) #f]
    [(eq? (sc2-tech-node-kind node) 'research)
     (define csym (sc2-tech-node-id node))
     (or (not (not (memq sym researched-upgs)))
         (not (not (memq sym pending-upgs)))
         (has-upgrade-sym? csym researched-upgs)
         (has-upgrade-sym? csym pending-upgs))]
    [(sc2-tech-node-unique? node)
     (>= (bldg-count-equivalent total-bldg-counts (sc2-tech-node-id node))
         (max 1 target-count))]
    [else #f]))

;; Walks the SC2-TECH-GRAPH recursively to find the earliest missing prerequisite
;; structure/add-on that is neither ready nor currently under construction (`total-bldg-counts == 0`).
;; Returns an ordered list of missing prerequisite symbols (from root prerequisite to immediate prerequisite).
(define (resolve-missing-prereq-chain sym ready-bldg-counts total-bldg-counts
                                     [visited '()]
                                     #:expand-occupied-addons? [expand-occupied-addons? #t])
  (define csym (normalize-brain-sym sym))
  (define node (lookup-sc2-tech-node csym))
  (cond
    [(or (not node) (memq csym visited)) '()]
    [else
     (define next-vis (cons csym visited))
     (remove-duplicates
      (apply append
             (for/list ([p (in-list (sc2-tech-node-prereqs node))])
               (cond
                 [(and expand-occupied-addons?
                       (eq? p (addon-parent-facility csym))
                       (= (bldg-count-equivalent total-bldg-counts csym) 0))
                  ;; Missing Terran add-on needs an open parent slot; surface parent if all slots are full.
                  (case (addon-parent-slot-state csym ready-bldg-counts total-bldg-counts)
                    [(ready-slot-free) '()]
                    [(parent-in-progress)
                     (resolve-missing-prereq-chain p ready-bldg-counts total-bldg-counts next-vis
                                                   #:expand-occupied-addons? expand-occupied-addons?)]
                    [else
                     (append (resolve-missing-prereq-chain p ready-bldg-counts total-bldg-counts next-vis
                                                           #:expand-occupied-addons? expand-occupied-addons?)
                             (list p))])]
                 [(single-prereq-ready? ready-bldg-counts p)
                  '()]
                 [(> (bldg-count-equivalent total-bldg-counts p) 0)
                  ;; Prerequisite is already under construction / morphing; wait for it to finish
                  ;; unless IT has a broken upstream prerequisite
                  (resolve-missing-prereq-chain p ready-bldg-counts total-bldg-counts next-vis
                                                #:expand-occupied-addons? expand-occupied-addons?)]
                 [else
                  ;; Prerequisite is completely missing (never built or destroyed by Chaos Monkey)!
                  (append (resolve-missing-prereq-chain p ready-bldg-counts total-bldg-counts next-vis
                                                        #:expand-occupied-addons? expand-occupied-addons?)
                          (list p))])))
      eq?)]))

(define LATE-TECH-SPECULATIVE-STRUCTS
  '(armory ghost-academy fusion-core fleet-beacon robotics-bay templar-archive dark-shrine
    lair hive infestation-pit spire greater-spire hydralisk-den lurker-den ultralisk-cavern))

;; Returns #t when `sym` either is or requires building an unbuilt late-tech structure.
(define (speculative-late-tech-unit-deferred? sym ready-bldg-counts total-bldg-counts)
  (define nsym (normalize-brain-sym sym))
  (or (and (memq nsym LATE-TECH-SPECULATIVE-STRUCTS)
           (= (bldg-count-equivalent total-bldg-counts nsym) 0))
      (ormap (lambda (req)
               (and (memq (normalize-brain-sym req) LATE-TECH-SPECULATIVE-STRUCTS)
                    (= (bldg-count-equivalent total-bldg-counts req) 0)))
             (resolve-missing-prereq-chain nsym ready-bldg-counts total-bldg-counts))))

;; Scans all existing buildings/units/upgrades AND active build-order goals to find
;; any broken tech tree dependencies (e.g., Lair exists or Roach Warren exists, but Spawning Pool
;; was destroyed; or Cybernetics Core exists, but Gateway or Pylon was destroyed; or Factory
;; exists, but Barracks or Supply Depot was destroyed).
(define *tech-build-node-ids-by-race*
  (for/hasheq ([r (in-list '(Zerg Terran Protoss))])
    (values r
            (for/list ([n (in-list SC2-TECH-NODES-LIST)]
                       #:when (and (eq? (sc2-tech-node-race n) r)
                                   (memq (sc2-tech-node-kind n) '(build expand morph addon))))
              (sc2-tech-node-id n)))))

(define (find-all-broken-tech-dependencies race ready-bldg-counts total-bldg-counts
                                           #:active-goals [active-goals '()])
  (define r-sym
    (case race
      [(Zerg zerg ZvZ ZvT ZvP) 'Zerg]
      [(Terran terran TvZ TvT TvP) 'Terran]
      [else 'Protoss]))
  (define (compute)
    ;; 1. Check any structure currently owned by the player whose upstream prerequisite was destroyed
    (define race-node-ids (hash-ref *tech-build-node-ids-by-race* r-sym '()))
    (define owned-syms
      (for/list ([nid (in-list race-node-ids)]
                 #:when (> (bldg-count-equivalent total-bldg-counts nid) 0))
        nid))
    ;; 2. Check all active build-order goal symbols
    (define goal-syms
      (for/fold ([acc '()] #:result (reverse acc)) ([g (in-list active-goals)])
        (cond
          [(pro-bo-goal? g) (cons (pro-bo-goal-target-sym g) acc)]
          [(symbol? g) (cons g acc)]
          [else acc])))
    (remove-duplicates
     (apply append
            (for/list ([sym (in-list (append owned-syms goal-syms))])
              (resolve-missing-prereq-chain sym ready-bldg-counts total-bldg-counts
                                            #:expand-occupied-addons? #f)))
     eq?))
  (if (and (current-ready-bldg-cache) (current-total-bldg-cache))
      (compute)
      (parameterize ([current-ready-bldg-cache (cons ready-bldg-counts (make-hasheq))]
                     [current-total-bldg-cache (cons total-bldg-counts (make-hasheq))])
        (compute))))

;; =============================================================================
;; 2. Decoupled Macro World State & Priority Macro Brain
;; =============================================================================

(struct macro-world-state
  (race                  ;; 'Zerg | 'Terran | 'Protoss
   enemy-race            ;; 'Zerg | 'Terran | 'Protoss | 'Unknown
   frame                 ;; exact nonnegative integer
   minerals              ;; exact nonnegative integer
   gas                   ;; exact nonnegative integer
   supply-used           ;; exact nonnegative integer
   supply-cap            ;; exact nonnegative integer
   supply-left           ;; exact integer (can be <= 0 when supply-blocked after Chaos Monkey deletion)
   pending-supply        ;; exact nonnegative integer (number of in-progress supply providers)
   workers               ;; exact nonnegative integer
   active-bases          ;; exact nonnegative integer
   gas-harvesters        ;; exact nonnegative integer or #f (when unknown in synthetic states)
   mineral-harvesters    ;; exact nonnegative integer or #f (when unknown in synthetic states)
   ready-building-counts ;; immutable hash: symbol -> count
   total-building-counts ;; immutable hash: symbol -> count (ready + in-progress + pending)
   unit-counts           ;; immutable hash: symbol -> count (alive + in-progress)
   researched-upgrades   ;; list of symbols
   pending-upgrades      ;; list of symbols
   open-facility-slots   ;; immutable hash: slot-symbol -> count (or #f for unconstrained synthetic mode)
   army-supply           ;; exact nonnegative integer
   enemy-threat-supply   ;; exact nonnegative integer
   under-attack?         ;; boolean
   requires-anti-air?    ;; boolean
   requires-detection?   ;; boolean
   supply-at-risk?       ;; boolean
   peak-supply-reached   ;; exact nonnegative integer (watermark so unit deaths don't regress tech phase)
   base-x                ;; flonum
   base-y                ;; flonum
   nat-x                 ;; flonum
   nat-y                 ;; flonum
   third-x               ;; flonum
   third-y)              ;; flonum
  #:transparent)

(struct macro-brain-decision
  (scheduled-actions     ;; list of action s-expressions approved for immediate execution
   scheduled-ids         ;; list of candidate symbols approved for immediate execution
   saving-for            ;; symbol of top escrowed candidate or 'none
   reserved-min-floor    ;; exact nonnegative integer
   reserved-gas-floor    ;; exact nonnegative integer
   reserved-slots        ;; list of facility slot symbols reserved by escrowed higher-priority items
   bo-active-goal        ;; pro-bo-goal or #f
   repaired-prereqs      ;; list of missing prerequisite symbols promoted by DAG self-healing
   priority-schedule     ;; priority-schedule-result from econ-ledger
   log-line)             ;; formatted [SCBOT_PRIORITY] string
  #:transparent)

(define macro-world-state-enemy-units-table (make-weak-hasheq))
(define macro-world-state-enemy-buildings-table (make-weak-hasheq))
(define macro-world-state-mirror-signals-table (make-weak-hasheq))
(define macro-world-state-depleting-bases-table (make-weak-hasheq))
(define macro-world-state-natural-blocked-table (make-weak-hasheq))

(define (macro-world-state-enemy-unit-counts ws)
  (and (macro-world-state? ws)
       (hash-ref macro-world-state-enemy-units-table ws #f)))

(define (macro-world-state-enemy-building-counts ws)
  (and (macro-world-state? ws)
       (hash-ref macro-world-state-enemy-buildings-table ws #f)))

(define (macro-world-state-mirror-signals ws)
  (if (macro-world-state? ws)
      (hash-ref macro-world-state-mirror-signals-table ws #f)
      #f))

(define (macro-world-state-depleting-bases ws)
  (if (macro-world-state? ws)
      (hash-ref macro-world-state-depleting-bases-table ws 0)
      0))

(define (macro-world-state-natural-blocked? ws)
  (and (macro-world-state? ws)
       (not (not (hash-ref macro-world-state-natural-blocked-table ws #f)))))

(define (macro-world-state->ledger-hash ws)
  (cond
    [(hash? ws) ws]
    [(not (macro-world-state? ws)) (hasheq)]
    [else
     (define ms (macro-world-state-mirror-signals ws))
     (define base-ht
       (hasheq
        'race (macro-world-state-race ws)
        'enemy-race (macro-world-state-enemy-race ws)
        'frame (macro-world-state-frame ws)
        'minerals (macro-world-state-minerals ws)
        'gas (macro-world-state-gas ws)
        'supply-used (macro-world-state-supply-used ws)
        'supply-cap (macro-world-state-supply-cap ws)
        'supply-left (macro-world-state-supply-left ws)
        'pending-supply (macro-world-state-pending-supply ws)
        'workers (macro-world-state-workers ws)
        'active-bases (macro-world-state-active-bases ws)
        'depleting-bases (macro-world-state-depleting-bases ws)
        'natural-blocked? (macro-world-state-natural-blocked? ws)
        'building-counts (macro-world-state-total-building-counts ws)
        'ready-building-counts (macro-world-state-ready-building-counts ws)
        'unit-counts (macro-world-state-unit-counts ws)
        'enemy-unit-counts (or (macro-world-state-enemy-unit-counts ws) (hasheq))
        'enemy-building-counts (or (macro-world-state-enemy-building-counts ws) (hasheq))
        'researched-upgrades (macro-world-state-researched-upgrades ws)
        'pending-upgrades (macro-world-state-pending-upgrades ws)
        'army-supply (macro-world-state-army-supply ws)
        'enemy-threat-supply (macro-world-state-enemy-threat-supply ws)
        'under-attack? (macro-world-state-under-attack? ws)
        'requires-anti-air? (macro-world-state-requires-anti-air? ws)
        'requires-detection? (macro-world-state-requires-detection? ws)
        'supply-at-risk? (macro-world-state-supply-at-risk? ws)
        'peak-supply-reached (macro-world-state-peak-supply-reached ws)
        'base-x (macro-world-state-base-x ws)
        'base-y (macro-world-state-base-y ws)
        'nat-x (macro-world-state-nat-x ws)
        'nat-y (macro-world-state-nat-y ws)
        'third-x (macro-world-state-third-x ws)
        'third-y (macro-world-state-third-y ws)
        'mirror-signals (if (hash? ms) ms (hasheq))))
     (if (hash? ms)
         (for/fold ([h base-ht]) ([(k v) (in-hash ms)])
           (if (hash-has-key? h k) h (hash-set h k v)))
         base-ht)]))

(register-macro-world-state-extractor! macro-world-state->ledger-hash)

(define (make-macro-world-state
         #:race [race 'Zerg]
         #:enemy-race [enemy-race 'Unknown]
         #:frame [frame 0]
         #:minerals [minerals 50]
         #:gas [gas 0]
         #:supply-used [supply-used 12]
         #:supply-cap [supply-cap 14]
         #:supply-left [supply-left (- supply-cap supply-used)]
         #:pending-supply [pending-supply 0]
         #:workers [workers 12]
         #:active-bases [active-bases 1]
         #:gas-harvesters [gas-harvesters #f]
         #:mineral-harvesters [mineral-harvesters #f]
         #:ready-building-counts [ready-bldg-counts (hash)]
         #:total-building-counts [total-bldg-counts ready-bldg-counts]
         #:unit-counts [unit-counts (hash)]
         #:researched-upgrades [researched-upgrades '()]
         #:pending-upgrades [pending-upgrades '()]
         #:open-facility-slots [open-facility-slots #f]
         #:army-supply [army-supply 0]
         #:enemy-threat-supply [enemy-threat-supply 0]
         #:under-attack? [under-attack? #f]
         #:requires-anti-air? [requires-anti-air? #f]
         #:requires-detection? [requires-detection? #f]
         #:supply-at-risk? [supply-at-risk? #f]
         #:peak-supply-reached [peak-supply-reached supply-used]
         #:enemy-unit-counts [enemy-unit-counts #f]
         #:enemy-building-counts [enemy-building-counts #f]
         #:base-x [base-x 32.5]
         #:base-y [base-y 32.5]
         #:nat-x [nat-x 50.5]
         #:nat-y [nat-y 50.5]
         #:third-x [third-x 60.5]
         #:third-y [third-y 40.5]
         #:mirror-signals [mirror-signals #f]
         #:depleting-bases [depleting-bases 0]
         #:natural-blocked? [natural-blocked? #f]
         #:opp-commitment-ht [opp-commitment-ht #f]
         #:loss-recovery-ht [loss-recovery-ht #f]
         #:peak-workers [peak-workers #f]
         #:peak-bases [peak-bases #f]
         #:peak-army-supply [peak-army-supply #f]
         #:enemy-gas-count [enemy-gas-count #f])
  (define r-sym
    (case race
      [(Zerg zerg "Zerg" "zerg" ZvZ ZvT ZvP) 'Zerg]
      [(Terran terran "Terran" "terran" TvZ TvT TvP) 'Terran]
      [else 'Protoss]))
  (define ws
    (macro-world-state
     r-sym enemy-race
     (max 0 (exact-round frame))
     (max 0 (exact-round minerals))
     (max 0 (exact-round gas))
     (max 0 (exact-round supply-used))
     (min 200 (max 0 (exact-round supply-cap)))
     (exact-round supply-left)
     (max 0 (exact-round pending-supply))
     (max 0 (exact-round workers))
     (max 1 (exact-round active-bases))
     (and (real? gas-harvesters) (max 0 (exact-round gas-harvesters)))
     (and (real? mineral-harvesters) (max 0 (exact-round mineral-harvesters)))
     ready-bldg-counts
     total-bldg-counts
     unit-counts
     researched-upgrades
     pending-upgrades
     open-facility-slots
     (max 0 (exact-round army-supply))
     (max 0 (exact-round enemy-threat-supply))
     (not (not under-attack?))
     (not (not requires-anti-air?))
     (not (not requires-detection?))
     (not (not supply-at-risk?))
     (max (exact-round supply-used) (exact-round peak-supply-reached))
     (exact->inexact base-x)
     (exact->inexact base-y)
     (exact->inexact nat-x)
     (exact->inexact nat-y)
     (exact->inexact third-x)
     (exact->inexact third-y)))
  (when (hash? enemy-unit-counts)
    (hash-set! macro-world-state-enemy-units-table ws enemy-unit-counts))
  (when (hash? enemy-building-counts)
    (hash-set! macro-world-state-enemy-buildings-table ws enemy-building-counts))
  (when (hash? mirror-signals)
    (hash-set! macro-world-state-mirror-signals-table ws mirror-signals))
  (when (or opp-commitment-ht loss-recovery-ht peak-workers peak-bases peak-army-supply enemy-gas-count)
    (define base-ms (or (and (hash? mirror-signals) mirror-signals) (hasheq)))
    (define merged-ms
      (let* ([h base-ms]
             [h (if (hash? opp-commitment-ht) (hash-set h 'opp-commitment-ht opp-commitment-ht) h)]
             [h (if (hash? loss-recovery-ht) (hash-set h 'loss-recovery-ht loss-recovery-ht) h)]
             [h (if (real? peak-workers) (hash-set h 'peak-workers peak-workers) h)]
             [h (if (real? peak-bases) (hash-set h 'peak-bases peak-bases) h)]
             [h (if (real? peak-army-supply) (hash-set h 'peak-army-supply peak-army-supply) h)]
             [h (if (real? enemy-gas-count) (hash-set h 'enemy-gas-count enemy-gas-count) h)])
        h))
    (hash-set! macro-world-state-mirror-signals-table ws merged-ms))
  (when (and (exact-integer? depleting-bases) (> depleting-bases 0))
    (hash-set! macro-world-state-depleting-bases-table ws depleting-bases))
  (when (eq? natural-blocked? #t)
    (hash-set! macro-world-state-natural-blocked-table ws #t))
  ws)

;; =============================================================================
;; Slice 1.5A: Opportunity-Cost & Loss-Recovery Tables & Candidate Adjustment
;; =============================================================================

(define dyn-plan-ctx-slice15-table (make-weak-hasheq))

(define *slice15-cap-air-suppressed-syms*
  '(roach ravager zergling baneling lurker ultralisk
    marauder siege-tank siege-tank-sieged hellion hellbat
    zealot colossus disruptor immortal adept))

(define (slice15-cap-air-counter-utility-table race)
  (case race
    [(Zerg)
     (hasheq 'corruptor 514.0
             'spire 510.0
             'queen 502.0
             'spore-crawler 496.0
             'viper 490.0
             'zerg-flyer-armor-1 488.0)]
    [(Terran)
     (hasheq 'viking-fighter 514.0
             'starport 510.0
             'thor 502.0
             'cyclone 496.0
             'missile-turret 495.0
             'raven 490.0)]
    [else
     (hasheq 'tempest 514.0
             'void-ray 508.0
             'stargate 504.0
             'stalker 498.0
             'archon 494.0
             'shield-battery 492.0
             'photon-cannon 490.0
             'high-templar 488.0)]))

(define (slice15-cap-air-extra-syms race ready-bldg-counts unit-counts)
  (case race
    [(Zerg)
     (append '(spire corruptor queen spore-crawler)
             (if (> (bldg-count-equivalent ready-bldg-counts 'hive) 0) '(viper) '())
             (if (or (> (bldg-count-equivalent ready-bldg-counts 'spire) 0)
                     (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0))
                 '(zerg-flyer-armor-1)
                 '()))]
    [(Terran)
     (append '(starport viking-fighter cyclone missile-turret)
             (if (> (bldg-count-equivalent ready-bldg-counts 'armory) 0) '(thor) '())
             (if (> (bldg-count-equivalent ready-bldg-counts 'starport-techlab) 0) '(raven) '()))]
    [else
     (append '(stargate fleet-beacon tempest void-ray stalker shield-battery photon-cannon)
             (if (> (bldg-count-equivalent ready-bldg-counts 'templar-archive) 0)
                 (if (>= (unit-count-equivalent unit-counts 'high-templar) 2)
                     '(archon high-templar)
                     '(high-templar))
                 '()))]))

(define (slice15-mineral-line-static-def-syms race)
  (case race
    [(Zerg) '(spore-crawler)]
    [(Terran) '(missile-turret)]
    [else '(photon-cannon shield-battery)]))

(define (slice15-choke-static-def-syms race)
  (case race
    [(Zerg) '(spine-crawler spore-crawler)]
    [(Terran) '(bunker missile-turret)]
    [else '(shield-battery photon-cannon)]))

(define (slice15-race-counter-list-from-opp race opp-rec-syms ready-bldg-counts unit-counts)
  (define ht (make-hasheq))
  (define idx 0)
  (for ([raw (in-list opp-rec-syms)])
    (define nsym (normalize-brain-sym raw))
    (define nd (lookup-sc2-tech-node nsym))
    (when (and nd (eq? (sc2-tech-node-race nd) race))
      (define base-u (max 488.0 (- 512.0 (* 2.5 idx))))
      (set! idx (add1 idx))
      (unless (hash-has-key? ht nsym)
        (hash-set! ht nsym base-u))))
  (when (= (hash-count ht) 0)
    (for ([fallback (in-list (case race
                               [(Zerg) '(corruptor hydralisk ravager queen)]
                               [(Terran) '(viking-fighter siege-tank marauder cyclone)]
                               [else '(immortal stalker void-ray colossus)]))]
          [i (in-naturals 0)])
      (hash-set! ht fallback (max 490.0 (- 508.0 (* 3.0 i))))))
  ;; Only keep archon if >= 2 HT or keep high-templar/etc. clean
  (when (and (eq? race 'Protoss)
             (hash-has-key? ht 'archon)
             (< (unit-count-equivalent unit-counts 'high-templar) 2))
    (hash-remove! ht 'archon))
  (void ready-bldg-counts)
  ht)

(define (slice15-nonessential-tech-preemptable? c is-repaired? is-bo-goal? is-timing-bo? workers severe-crisis?)
  (define sym (normalize-brain-sym (priority-candidate-id c)))
  (define cat (priority-candidate-category c))
  (define node (lookup-sc2-tech-node sym))
  (define kind (and node (sc2-tech-node-kind node)))
  (and (not is-repaired?)
       (or (not is-timing-bo?) (< workers 18))
       (not (memq sym '(spawning-pool barracks gateway cybernetics-core orbital-command queen
                        spire starport stargate fleet-beacon)))
       (not (memq cat '(worker supply expansion)))
       (or (not is-bo-goal?) severe-crisis? (< workers 14))
       (or (eq? kind 'research)
           (and (eq? cat 'tech-upgrade)
                (or severe-crisis? (< workers 18)))
           (memq sym '(fusion-core dark-shrine templar-archive infestation-pit
                       greater-spire robotics-bay twilight-council ghost-academy)))))

;; Extracts a pure `macro-world-state` from a runtime observation hash (`obs`).
(define (obs-hash->macro-world-state obs [default-race 'Zerg])
  (define raw-race (hash-ref obs 'actual-race (hash-ref obs 'race default-race)))
  (define race
    (case raw-race
      [(Zerg zerg "Zerg" "zerg") 'Zerg]
      [(Terran terran "Terran" "terran") 'Terran]
      [(Protoss protoss "Protoss" "protoss") 'Protoss]
      [else default-race]))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define ready-bldgs
    (filter (lambda (b)
              (and (>= (hash-ref b 'build-progress 1.0) 0.999)
                   (or (not (sc2-structure-requires-pylon-power? (hash-ref b 'type 'unknown)))
                       (not (eq? (hash-ref b 'powered? #t) #f)))))
            ally-bldgs))
  (define ready-counts
    (for/fold ([ht (hash)]) ([b (in-list ready-bldgs)])
      (hash-update ht (hash-ref b 'type 'unknown) add1 0)))
  (define total-counts
    (for/fold ([ht (hash)]) ([b (in-list ally-bldgs)])
      (hash-update ht (hash-ref b 'type 'unknown) add1 0)))
  (define unit-counts
    (for/fold ([ht (hash)]) ([u (in-list ally-units)])
      (hash-update ht (hash-ref u 'type 'unknown) add1 0)))
  (define w-sym
    (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
  (define workers
    (+ (unit-count-equivalent unit-counts w-sym)
       (hash-ref obs 'pending-workers 0)))
  (define th-sym
    (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
  (define active-bases (max 1 (bldg-count-equivalent total-counts th-sym)))
  (define ready-gas-bldg-list
    (filter (lambda (b)
              (memq (hash-ref b 'type 'unknown)
                    '(extractor extractor-rich refinery refinery-rich assimilator assimilator-rich)))
            ready-bldgs))
  (define obs-gas-harvesters
    (cond
      [(hash-ref obs 'gas-harvesters #f) => values]
      [(hash-ref obs 'vespene-harvesters #f) => values]
      [(and (pair? ready-gas-bldg-list)
            (ormap (lambda (b) (hash-has-key? b 'assigned-harvesters)) ready-gas-bldg-list))
       (for/sum ([b (in-list ready-gas-bldg-list)])
         (hash-ref b 'assigned-harvesters 0))]
      [else #f]))
  (define obs-min-harvesters
    (hash-ref obs 'mineral-harvesters #f))
  (define sup-used (hash-ref obs 'supply-used 12))
  (define sup-cap (hash-ref obs 'supply-cap (if (eq? race 'Zerg) 14 15)))
  (define sup-left (hash-ref obs 'supply-left (- sup-cap sup-used)))
  (define enemy-u-counts
    (for/fold ([ht (hasheq)])
              ([eu (in-list enemy-units)])
      (hash-update ht (unit-type-sym eu) add1 0)))
  (define enemy-b-counts
    (for/fold ([ht (hasheq)])
              ([eb (in-list enemy-bldgs)])
      (hash-update ht (unit-type-sym eb) add1 0)))
  (make-macro-world-state
   #:race race
   #:enemy-race (hash-ref obs 'enemy-race 'Unknown)
   #:enemy-unit-counts enemy-u-counts
   #:enemy-building-counts enemy-b-counts
   #:frame (hash-ref obs 'frame 0)
   #:minerals (hash-ref obs 'minerals 50)
   #:gas (hash-ref obs 'gas 0)
   #:supply-used sup-used
   #:supply-cap sup-cap
   #:supply-left sup-left
   #:pending-supply (hash-ref obs 'pending-supply 0)
   #:workers workers
   #:active-bases active-bases
   #:gas-harvesters obs-gas-harvesters
   #:mineral-harvesters obs-min-harvesters
   #:ready-building-counts ready-counts
   #:total-building-counts total-counts
   #:unit-counts unit-counts
   #:researched-upgrades (hash-ref obs 'researched-upgrades '())
   #:pending-upgrades (hash-ref obs 'pending-upgrades '())
   #:open-facility-slots (hash-ref obs 'open-facility-slots #f)
   #:army-supply (hash-ref obs 'army-supply 0)
   #:enemy-threat-supply (hash-ref obs 'enemy-threat-supply 0)
   #:under-attack? (hash-ref obs 'under-attack? #f)
   #:requires-anti-air?
   (or (ormap (lambda (e)
                (define ut (unit-type-sym e))
                (and (not (memq ut '(medivac warp-prism warp-prism-phasing overlord-transport)))
                     (or (hash-ref e 'flying? #f)
                         (hash-ref e 'flying #f)
                         (hash-ref e 'is-flying #f)
                         (memq ut '(mutalisk corruptor brood-lord broodlord viper
                                    viking viking-fighter liberator banshee raven battlecruiser
                                    phoenix oracle void-ray voidray carrier tempest mothership
                                    colossus)))))
              enemy-units)
       (ormap (lambda (eb)
                (or (hash-ref eb 'flying? #f)
                    (hash-ref eb 'flying #f)
                    (hash-ref eb 'is-flying #f)
                    (memq (hash-ref eb 'type 'unknown)
                          '(command-center-flying orbital-command-flying
                            barracks-flying factory-flying starport-flying))))
              enemy-bldgs))
   #:requires-detection?
   (not (null? (filter (lambda (e)
                         (or (hash-ref e 'cloaked #f)
                             (hash-ref e 'cloaked? #f)
                             (hash-ref e 'burrowed #f)
                             (hash-ref e 'burrowed? #f)
                             (hash-ref e 'is-burrowed #f)))
                       enemy-units)))
   #:supply-at-risk? (hash-ref obs 'supply-at-risk #f)
   #:peak-supply-reached (hash-ref obs 'peak-supply-reached sup-used)
   #:base-x (hash-ref obs 'base-x 32.5)
   #:base-y (hash-ref obs 'base-y 32.5)
   #:nat-x (hash-ref obs 'natural-x 50.5)
   #:nat-y (hash-ref obs 'natural-y 50.5)
   #:third-x (hash-ref obs 'third-x 60.5)
   #:third-y (hash-ref obs 'third-y 40.5)
   #:mirror-signals
   (let* ([raw-sub (hash-ref obs 'mirror-signals #f)]
          [sub (if (hash? raw-sub) raw-sub (hasheq))]
          [mget (lambda (k default)
                  (cond
                    [(hash-has-key? obs k) (hash-ref obs k default)]
                    [(hash-has-key? sub k) (hash-ref sub k default)]
                    [else default]))])
     (hasheq
      'mirror-preemptive-unit (mget 'mirror-preemptive-unit #f)
      'mirror-predicted-enemy-unit (mget 'mirror-predicted-enemy-unit #f)
      'mirror-recommended-min-bases (let ([v (mget 'mirror-recommended-min-bases 0)])
                                      (if (exact-nonnegative-integer? v) v 0))
      'mirror-macro-verdict (mget 'mirror-macro-verdict 'pace-Macro-And-Disrupt)
      'mirror-requires-detection? (not (not (mget 'mirror-requires-detection? #f)))
      'mirror-requires-anti-air? (not (not (mget 'mirror-requires-anti-air? #f)))
      'mirror-enemy-upgrade-advantage (let ([v (mget 'mirror-enemy-upgrade-advantage 0)])
                                        (if (exact-integer? v) v 0))
      'mirror-trust-mode (mget 'mirror-trust-mode 'balanced-bayesian-hedged)
      'mirror-strategy (mget 'mirror-strategy #f)
      'opp-commitment-ht (mget 'opp-commitment-ht #f)
      'loss-recovery-ht (mget 'loss-recovery-ht #f)
      'peak-workers (mget 'peak-workers #f)
      'peak-bases (mget 'peak-bases #f)
      'peak-army-supply (mget 'peak-army-supply #f)
      'enemy-gas-count (mget 'enemy-gas-count #f)
      'enemy-bases (mget 'enemy-bases #f)))
   #:depleting-bases (let ([d (hash-ref obs 'depleting-bases 0)])
                       (if (exact-nonnegative-integer? d) d 0))
   #:natural-blocked? (eq? (hash-ref obs 'natural-blocked? #f) #t)))

;; Helper: convert building/unit counts hash to flat list of symbols for legacy APIs
(define (counts-hash->symbol-list ht)
  (apply append
         (for/list ([(sym cnt) (in-hash ht)]
                    #:when (and (symbol? sym) (> cnt 0)))
           (make-list (min 30 cnt) sym))))

;; Helper: build action s-expression for any tech node
(define (tech-node->action sym kind base-x base-y nat-x nat-y third-x third-y active-bases)
  (case kind
    [(expand)
     (if (>= active-bases 2)
         (list 'expand third-x third-y)
         (list 'expand nat-x nat-y))]
    [(train)
     (list 'train sym)]
    [(morph)
     (list 'morph sym)]
    [(research)
     (list 'research sym)]
    [(addon)
     (list 'build sym (+ base-x 6.5) (+ base-y 3.5))]
    [(build)
     (case sym
       [(photon-cannon spine-crawler)
        (list 'build sym nat-x nat-y)]
       [else
        (list 'build sym (+ base-x 4.0) (+ base-y 4.0))])]
    [else
     (list 'build sym (+ base-x 4.0) (+ base-y 4.0))]))

;; =============================================================================
;; 2b. Dynamic Multi-Track Goal Plan & Next-Action Translator
;; =============================================================================
;; Replaces static FIFO build-order queue scanning with a live, multi-track
;; strategic plan (`dynamic-macro-plan`) that continuously updates goal statuses
;; (`'satisfied`, `'in-progress`, `'waiting-on-in-progress-prereq`, `'needs-prereq`,
;; `'actionable-now`) and translates every active goal into its concrete ready
;; next action (`next-action-sym`) via backward-chaining over `SC2-TECH-GRAPH`.

(struct plan-goal-node
  (id              ;; symbol: target goal (e.g. 'terran-infantry-weapons-1, 'roach-warren, 'observer)
   track           ;; symbol: 'survival-supply | 'economy-expansion | 'tech-infrastructure | 'army-production | 'intel-recon
   kind            ;; symbol: 'build | 'expand | 'morph | 'research | 'train | 'addon
   target-count    ;; exact positive integer
   current-ready   ;; exact nonnegative integer
   current-total   ;; exact nonnegative integer (ready + under-construction/pending)
   status          ;; symbol: 'satisfied | 'in-progress | 'waiting-on-in-progress-prereq | 'needs-prereq | 'actionable-now
   next-action-sym ;; symbol or #f: concrete executable next action translated from this goal
   priority-weight ;; flonum: dynamic plan utility weight computed from current world state
   reason)         ;; symbol: provenance tag
  #:transparent)

(struct dynamic-macro-plan
  (race                    ;; 'Zerg | 'Terran | 'Protoss
   frame                   ;; exact nonnegative integer
   phase-supply            ;; exact nonnegative integer
   all-goals               ;; list of plan-goal-node across all tracks
   active-goals            ;; list of unsatisfied plan-goal-node (status != 'satisfied)
   actionable-goals        ;; list of plan-goal-node with non-#f next-action-sym, sorted by descending weight
   translated-next-actions ;; immutable hash: next-action-sym -> highest-priority plan-goal-node
   in-progress-syms)       ;; list of symbols currently 'in-progress or 'waiting-on-in-progress-prereq
  #:transparent)

;; Translates a single high-level plan goal `(id, track, kind, target-count, priority-weight, reason)`
;; into a `plan-goal-node` with its live lifecycle `status` and concrete `next-action-sym`.
(define (translate-goal-to-next-action id track kind target-count priority-weight reason
                                       ready-bldg-counts total-bldg-counts unit-counts
                                       researched-upgrades pending-upgrades)
  (define cid (normalize-brain-sym id))
  (define unit-morph?
    (and (eq? kind 'morph)
         (memq cid '(ravager baneling lurker brood-lord overseer overlord-transport archon))))
  (define current-ready
    (cond
      [(eq? kind 'research)
       (if (sc2-tech-already-satisfied? cid (hash) researched-upgrades '() 1) 1 0)]
      [(or (eq? kind 'train) unit-morph?)
       (unit-count-for-goal unit-counts cid)]
      [else
       (bldg-count-equivalent ready-bldg-counts cid)]))
  (define current-total
    (cond
      [(eq? kind 'research)
       (if (sc2-tech-already-satisfied? cid (hash) researched-upgrades pending-upgrades 1) 1 0)]
      [(or (eq? kind 'train) unit-morph?)
       (unit-count-for-goal unit-counts cid)]
      [else
       (bldg-count-equivalent total-bldg-counts cid)]))

  (define-values (status next-action-sym)
    (cond
      ;; 1. Goal is already completely ready/satisfied
      [(>= current-ready target-count)
       (values 'satisfied #f)]

      ;; 2. Goal is already under construction / morphing / researching (`total >= target > ready`)
      [(>= current-total target-count)
       (define missing-up
        (resolve-missing-prereq-chain cid ready-bldg-counts total-bldg-counts))
       (if (and (pair? missing-up)
                (sc2-tech-prereqs-ready? (first missing-up) ready-bldg-counts unit-counts))
           (values 'needs-prereq (first missing-up))
           (values 'in-progress #f))]

      ;; 3. Goal has all prerequisites (and open add-on parent slot, if add-on) ready right now -> `cid`!
      [(let ([cid-slot-st (addon-parent-slot-state cid ready-bldg-counts total-bldg-counts)])
         (and (sc2-tech-prereqs-ready? cid ready-bldg-counts unit-counts)
              (or (not cid-slot-st) (eq? cid-slot-st 'ready-slot-free))))
       (values 'actionable-now cid)]

      ;; 4. Goal is missing one or more prerequisites -> resolve via backward-chaining over SC2-TECH-GRAPH
      [else
       (define cid-slot-st (addon-parent-slot-state cid ready-bldg-counts total-bldg-counts))
       (define cid-parent-fac (addon-parent-facility cid))
       (define missing-chain
         (cond
           [(and cid-parent-fac (eq? cid-slot-st 'needs-new-parent))
            (append (resolve-missing-prereq-chain cid-parent-fac ready-bldg-counts total-bldg-counts)
                    (list cid-parent-fac))]
           [(and cid-parent-fac (eq? cid-slot-st 'parent-in-progress))
            (resolve-missing-prereq-chain cid-parent-fac ready-bldg-counts total-bldg-counts)]
           [else
            (resolve-missing-prereq-chain cid ready-bldg-counts total-bldg-counts)]))
       (cond
         [(pair? missing-chain)
          (define root-missing (first missing-chain))
          (define root-slot-st (addon-parent-slot-state root-missing ready-bldg-counts total-bldg-counts))
          (if (and (sc2-tech-prereqs-ready? root-missing ready-bldg-counts unit-counts)
                   (or (not root-slot-st) (eq? root-slot-st 'ready-slot-free)))
              (values 'needs-prereq root-missing)
              (values 'waiting-on-in-progress-prereq #f))]
         [unit-morph?
          ;; Structure prerequisites for unit morph are present; check if morph source unit is missing
          (define node (lookup-sc2-tech-node cid))
          (define src-sym (and node (sc2-tech-node-producer-slot node)))
          (define struct-prereqs-ready?
            (and node
                 (for/and ([p (in-list (sc2-tech-node-prereqs node))])
                   (single-prereq-ready? ready-bldg-counts p))))
          (define min-src-needed (if (eq? cid 'archon) 2 1))
          (if (and struct-prereqs-ready?
                   src-sym
                   (< (morph-source-unit-count unit-counts src-sym) min-src-needed)
                   (sc2-tech-prereqs-ready? src-sym ready-bldg-counts unit-counts))
              (values 'needs-prereq src-sym)
              (values 'waiting-on-in-progress-prereq #f))]
         [else
          ;; Required prerequisite structure is already under construction (`total > 0, ready == 0`)
          (values 'waiting-on-in-progress-prereq #f)])]))

  (plan-goal-node cid track kind target-count current-ready current-total
                  status next-action-sym (exact->inexact priority-weight) reason))

(define (min-workers-for-next-gas-bldg cur-gas-bldgs)
  (cond
    [(= cur-gas-bldgs 0) 12]
    [(= cur-gas-bldgs 1) 18]
    [(= cur-gas-bldgs 2) 26]
    [else (+ 18 (* 8 cur-gas-bldgs))]))

;; Filters build-order steps by `effective-phase-supply` and, when `frame > 0`,
;; elapsed Faster clock time (`elapsed-sec >= target-sec`), plus due empirical
;; unit and upgrade timings (`frame > 0`).
(define (collect-due-bo-context race enemy-race frame effective-phase-supply)
  (define elapsed-sec (/ (exact->inexact frame) 22.4))
  (define steps-so-far
    (filter (lambda (g)
              (or (>= effective-phase-supply (pro-bo-goal-min-supply g))
                  (and (> frame 0)
                       (> (exact->inexact (pro-bo-goal-target-sec g)) 0.0)
                       (>= elapsed-sec (exact->inexact (pro-bo-goal-target-sec g))))))
            (pro-build-order-steps-for-matchup race enemy-race)))
  (define due-upgs
    (if (> frame 0)
        (due-pro-upgrade-timings race enemy-race frame effective-phase-supply)
        '()))
  (define due-units
    (if (> frame 0)
        (due-pro-unit-timings race enemy-race frame effective-phase-supply)
        '()))
  (define due-timing-goals
    (append (map pro-upgrade-timing->bo-goal due-upgs)
            (map pro-unit-timing->bo-goal due-units)))
  (values elapsed-sec steps-so-far due-upgs due-units due-timing-goals))

(define (zerg-hive-t3-online? race bldg-counts)
  (and (eq? race 'Zerg)
       (> (bldg-count-equivalent bldg-counts 'hive) 0)
       (or (> (bldg-count-equivalent bldg-counts 'ultralisk-cavern) 0)
           (> (bldg-count-equivalent bldg-counts 'greater-spire) 0))))

(define (zerg-t3-obsolete-unbuilt? sym total-bldg-counts)
  (define nsym (normalize-brain-sym sym))
  (or (and (memq nsym '(roach-warren baneling-nest evolution-chamber))
           (= (bldg-count-equivalent total-bldg-counts nsym) 0))
      (eq? nsym 'burrow)
      (and (memq nsym '(glial-reconstitution tunneling-claws ravager roach))
           (= (bldg-count-equivalent total-bldg-counts 'roach-warren) 0))
      (and (memq nsym '(centrifical-hooks baneling))
           (= (bldg-count-equivalent total-bldg-counts 'baneling-nest) 0))
      (and (memq nsym '(zerg-melee-weapons-1 zerg-melee-weapons-2 zerg-melee-weapons-3
                        zerg-ground-armor-1 zerg-ground-armor-2 zerg-ground-armor-3
                        zerg-missile-weapons-1 zerg-missile-weapons-2 zerg-missile-weapons-3))
           (= (bldg-count-equivalent total-bldg-counts 'evolution-chamber) 0))))

;; Prevents Mirror-Mind expand directives from forcing a premature 3rd+ base escrow
;; before Protoss/Terran stabilize army supply (10+) and 32+ workers (or 550+ M bank),
;; while keeping natural expansion (<2 bases), Zerg macro, and base depletion unrestricted.
(define (depletion-or-mirror-expand-due? race active-bases workers depleting-bases
                                        mirror-min-bases under-attack? army-supply minerals)
  (and (not under-attack?)
       (>= workers (if (eq? race 'Zerg) 16 20))
       (or (> depleting-bases 0)
           (and (> mirror-min-bases active-bases)
                (or (< active-bases 2)
                    (eq? race 'Zerg)
                    (and (>= workers 42)
                         (>= army-supply 10))
                    (>= minerals 550))))))

;; Earlier Colossus tech unlock in PvT once >=52 supply and >=1 Immortal with Robotics Facility ready.
(define (pvt-immortal-robo-bay-due? race enemy-race eff-supply
                                    ready-bldg-counts total-bldg-counts unit-counts)
  (and (eq? race 'Protoss)
       (eq? enemy-race 'Terran)
       (>= eff-supply 52)
       (>= (unit-count-equivalent unit-counts 'immortal) 1)
       (> (bldg-count-equivalent ready-bldg-counts 'robotics-facility) 0)
       (= (bldg-count-equivalent total-bldg-counts 'robotics-bay) 0)))

(struct dyn-plan-ctx
  (all-upgs benchmark-targets
   has-robo? has-ready-armory? enemy-cap-air? enemy-cap-air-ground-aa?
   desired-thors air-fleet-cnt ship-weap-due?
   zvp-stargate-threat? keep-spire-aa? aa-effective? pvt-fast-kiter-threat? tvp-cannon-contain?
   desired-spores has-lair-or-hive-ready? desired-overseers desired-droppers
   gas-bldg-sym total-gas-bldgs suppress-tvp-extra-rax?
   crisis-defer? severe-crisis-static-def? defer-stargate?
   early-zero-army-attack? root-combat-facility-ready? under-early-rush-crisis?
   supply-sym hard-supply-block? zero-supply-provider-lockout? supply-lockout-active?
   total-townhalls steps-so-far due-timing-goals repaired-prereqs
   post-bo-goals post-bo-deviation))

;; Synthesizes the live 5-track `dynamic-macro-plan` plus reusable per-step context.
(define (synthesize-dynamic-macro-plan/ctx state
                                         #:enemy-unit-counts [override-enemy-unit-counts #f]
                                         #:enemy-building-counts [override-enemy-building-counts #f])
  (define enemy-u-counts
    (or (and (hash? override-enemy-unit-counts) override-enemy-unit-counts)
        (macro-world-state-enemy-unit-counts state)))
  (define enemy-b-counts
    (or (and (hash? override-enemy-building-counts) override-enemy-building-counts)
        (macro-world-state-enemy-building-counts state)))
  (match-define (macro-world-state
                 race enemy-race frame minerals gas
                 supply-used supply-cap supply-left pending-supply
                 workers active-bases
                 gas-harvesters mineral-harvesters
                 ready-bldg-counts total-bldg-counts unit-counts
                 researched-upgrades pending-upgrades open-facility-slots
                 army-supply enemy-threat-supply
                 under-attack? requires-anti-air? requires-detection? supply-at-risk?
                 peak-supply-reached
                 base-x base-y nat-x nat-y third-x third-y)
    state)

  (define effective-phase-supply (max supply-used peak-supply-reached))
  (define all-upgs (remove-duplicates (append researched-upgrades pending-upgrades) eq?))
  (define raw-mirror-signals (macro-world-state-mirror-signals state))
  (define ws-depleting-bases (macro-world-state-depleting-bases state))
  (define ws-natural-blocked? (macro-world-state-natural-blocked? state))
  (define eff-req-aa?
    (or requires-anti-air?
        (and (hash? raw-mirror-signals)
             (eq? (hash-ref raw-mirror-signals 'mirror-requires-anti-air? #f) #t))))
  (define eff-req-det?
    (or requires-detection?
        (and (hash? raw-mirror-signals)
             (eq? (hash-ref raw-mirror-signals 'mirror-requires-detection? #f) #t))))
  (define enemy-bases-est
    (max 1
         (if (and (hash? raw-mirror-signals) (real? (hash-ref raw-mirror-signals 'enemy-bases #f)))
             (inexact->exact (floor (hash-ref raw-mirror-signals 'enemy-bases 1)))
             1)
         (bldg-count-equivalent enemy-b-counts 'hatchery)
         (bldg-count-equivalent enemy-b-counts 'lair)
         (bldg-count-equivalent enemy-b-counts 'hive)
         (bldg-count-equivalent enemy-b-counts 'command-center)
         (bldg-count-equivalent enemy-b-counts 'orbital-command)
         (bldg-count-equivalent enemy-b-counts 'planetary-fortress)
         (bldg-count-equivalent enemy-b-counts 'nexus)))
  (define enemy-gas-est
    (max (if (and (hash? raw-mirror-signals) (real? (hash-ref raw-mirror-signals 'enemy-gas-count #f)))
             (inexact->exact (floor (hash-ref raw-mirror-signals 'enemy-gas-count 0)))
             0)
         (bldg-count-equivalent enemy-b-counts 'extractor)
         (bldg-count-equivalent enemy-b-counts 'refinery)
         (bldg-count-equivalent enemy-b-counts 'assimilator)))
  (define opp-commitment-ht
    (let ([ext (and (hash? raw-mirror-signals) (hash-ref raw-mirror-signals 'opp-commitment-ht #f))])
      (if (hash? ext)
          ext
          (evaluate-opponent-opportunity-cost-commitment
           enemy-u-counts enemy-b-counts frame enemy-bases-est enemy-gas-est))))
  (define opp-dominant-path (hash-ref opp-commitment-ht 'dominant-path 'none))
  (define opp-hard-override? (eq? (hash-ref opp-commitment-ht 'hard-override-build-order? #f) #t))
  (define opp-cap-air-override?
    (and opp-hard-override? (eq? opp-dominant-path 'capital-air-fleet)))
  (define opp-rec-counters (hash-ref opp-commitment-ht 'recommended-counter-units '()))
  (define opp-suppressed-units
    (map normalize-brain-sym (hash-ref opp-commitment-ht 'suppressed-non-counter-units '())))
  (define raw-peak-workers (and (hash? raw-mirror-signals) (hash-ref raw-mirror-signals 'peak-workers #f)))
  (define raw-peak-bases (and (hash? raw-mirror-signals) (hash-ref raw-mirror-signals 'peak-bases #f)))
  (define raw-peak-army (and (hash? raw-mirror-signals) (hash-ref raw-mirror-signals 'peak-army-supply #f)))
  (define loss-metrics-ht
    (hasheq 'workers workers
            'peak-workers (if (real? raw-peak-workers) (max workers raw-peak-workers) workers)
            'active-bases active-bases
            'peak-bases (if (real? raw-peak-bases) (max active-bases raw-peak-bases) active-bases)
            'supply-used supply-used
            'peak-supply-reached peak-supply-reached
            'army-supply army-supply
            'peak-army-supply (if (real? raw-peak-army) (max army-supply raw-peak-army) army-supply)
            'enemy-threat-supply enemy-threat-supply
            'frame frame))
  (define loss-recovery-ht
    (let ([ext (and (hash? raw-mirror-signals) (hash-ref raw-mirror-signals 'loss-recovery-ht #f))])
      (if (hash? ext)
          ext
          (evaluate-loss-recovery-macro-mode loss-metrics-ht))))
  (define loss-recovery-mode (hash-ref loss-recovery-ht 'mode 'none))
  (define lr-unlock-locked-path? (eq? (hash-ref loss-recovery-ht 'unlock-locked-path? #f) #t))
  (define slice15-unlock-locked-path? (or lr-unlock-locked-path? opp-hard-override?))
  (define sg-world-ht
    (let* ([h0 (macro-world-state->ledger-hash state)]
           [h1 (hash-set h0 'requires-anti-air? (or eff-req-aa? opp-cap-air-override?))]
           [h2 (hash-set h1 'requires-detection? eff-req-det?)])
      (if slice15-unlock-locked-path?
          (hash-set (hash-set h2 'unlock-locked-path? #t) 'opp-commitment-ht opp-commitment-ht)
          h2)))
  (define raw-post-bo-goals
    (evaluate-post-bo-strategic-goals sg-world-ht enemy-u-counts raw-mirror-signals))
  (define post-bo-goals
    (if (or slice15-unlock-locked-path? opp-cap-air-override?)
        (let* ([cur-supp (hash-ref raw-post-bo-goals 'suppressed-units '())]
               [keep-syms (if opp-cap-air-override?
                              (append (map normalize-brain-sym opp-rec-counters)
                                      '(spire corruptor queen spore-crawler viper zerg-flyer-armor-1
                                        starport viking-fighter raven thor cyclone missile-turret
                                        stargate void-ray tempest stalker high-templar archon shield-battery photon-cannon))
                              (map normalize-brain-sym opp-rec-counters))]
               [new-supp (filter (lambda (s) (not (memq (normalize-brain-sym s) keep-syms))) cur-supp)]
               [g1 (hash-set raw-post-bo-goals 'suppressed-units new-supp)]
               [g2 (if slice15-unlock-locked-path?
                       (hash-set (hash-set g1 'unlock-locked-path? #t) 'locked-path #f)
                       g1)])
          g2)
        raw-post-bo-goals))
  (define post-bo-deviation (hash-ref post-bo-goals 'deviation (hasheq)))
  (define post-bo-deviated? (eq? (hash-ref post-bo-goals 'deviated? #f) #t))
  (define post-bo-phase? (eq? (hash-ref post-bo-goals 'post-bo-phase? #f) #t))
  (define suppress-opening-harass?
    (eq? (hash-ref post-bo-goals 'suppress-opening-harass? #f) #t))
  (define sg-suppressed-units (hash-ref post-bo-goals 'suppressed-units '()))
  (define sg-unit-caps (hash-ref post-bo-goals 'unit-caps (hasheq)))
  (define sg-rec-units (hash-ref post-bo-goals 'recommended-units (hasheq)))
  (define sg-rec-upgs (hash-ref post-bo-goals 'recommended-upgrades '()))
  (define sg-desired-bases (hash-ref post-bo-goals 'desired-bases active-bases))
  (define sg-upg-escalation? (eq? (hash-ref post-bo-goals 'upgrade-escalation-active? #f) #t))
  (define sg-upg-mult (exact->inexact (hash-ref post-bo-goals 'upgrade-priority-multiplier 1.0)))
  (define sg-desired-upg-bays (hash-ref post-bo-goals 'desired-upgrade-bays 1))
  (define sg-desired-upg-bay-sym (hash-ref post-bo-goals 'desired-upgrade-bay-sym #f))
  (define sg-high-bank-inject? (eq? (hash-ref post-bo-goals 'high-bank-macro-inject? #f) #t))
  (define sg-macro-inject-structs (hash-ref post-bo-goals 'macro-inject-structures '()))
  (define sg-mirror-min-bases (hash-ref post-bo-goals 'mirror-recommended-min-bases 0))
  (define (sg-unit-allowed? raw-sym [cur-cnt #f])
    (define nsym (normalize-brain-sym raw-sym))
    (and (not (memq nsym sg-suppressed-units))
         (or (not (hash-has-key? sg-unit-caps nsym))
             (let ([cap (hash-ref sg-unit-caps nsym 999)]
                   [have (or cur-cnt (unit-count-equivalent unit-counts nsym))])
               (< have cap)))))
  (define benchmark-targets
    (normalized-pro-unit-benchmarks race enemy-race frame active-bases))
  (define has-robo? (> (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0))
  (define has-ready-armory? (> (bldg-count-equivalent ready-bldg-counts 'armory) 0))
  (define enemy-cap-air? (or (protoss-enemy-capital-air? enemy-u-counts) opp-cap-air-override?))
  (define enemy-cap-air-ground-aa? (terran-enemy-capital-air-with-ground-aa? enemy-u-counts))
  (define desired-thors (terran-desired-thor-cap enemy-u-counts))
  (define air-fleet-cnt (terran-air-fleet-count unit-counts))
  (define ship-weap-due?
    (terran-ship-weapons-due? race air-fleet-cnt has-ready-armory? all-upgs))
  (define zvp-stargate-threat?
    (and (eq? race 'Zerg)
         (zerg-enemy-stargate-air-threat? enemy-u-counts enemy-b-counts enemy-race eff-req-aa?)))
  (define keep-spire-aa?
    (and (eq? race 'Zerg)
         (zerg-enemy-air-spire-needed? enemy-u-counts enemy-b-counts enemy-race eff-req-aa?)))
  (define aa-effective?
    (or eff-req-aa?
        zvp-stargate-threat?
        (and (eq? race 'Zerg) (or keep-spire-aa? enemy-cap-air?))))
  (define pvt-fast-kiter-threat?
    (and (eq? race 'Protoss)
         (eq? enemy-race 'Terran)
         (protoss-enemy-fast-kiter-threat? enemy-u-counts)))
  (define tvp-cannon-contain?
    (terran-enemy-cannon-contain? race enemy-race enemy-u-counts enemy-b-counts))
  (define desired-spores
    (if (eq? race 'Zerg)
        (desired-zerg-spore-count active-bases enemy-u-counts enemy-b-counts enemy-race
                                  eff-req-aa? eff-req-det?)
        0))
  (define has-lair-or-hive-ready?
    (or (> (bldg-count-equivalent ready-bldg-counts 'lair) 0)
        (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)))
  (define desired-overseers
    (if (eq? race 'Zerg)
        (desired-zerg-overseer-count active-bases army-supply has-lair-or-hive-ready? eff-req-det?)
        0))
  (define desired-droppers
    (if (eq? race 'Zerg)
        (desired-zerg-overlord-transport-count active-bases army-supply workers has-lair-or-hive-ready? under-attack?)
        0))
  (define gas-bldg-sym
    (case race [(Zerg) 'extractor] [(Terran) 'refinery] [else 'assimilator]))
  (define total-gas-bldgs (bldg-count-equivalent total-bldg-counts gas-bldg-sym))
  (define suppress-tvp-extra-rax?
    (suppress-terran-extra-barracks-for-tvp-factory?
     race enemy-race
     (bldg-count-equivalent total-bldg-counts 'barracks)
     (bldg-count-equivalent total-bldg-counts 'factory)
     (unit-count-equivalent unit-counts 'siege-tank)
     minerals frame total-gas-bldgs gas
     enemy-u-counts enemy-b-counts))
  (define crisis-defer?
    (crisis-defense-tech-defer-active? under-attack? army-supply enemy-threat-supply workers))
  (define severe-crisis-static-def?
    (and crisis-defer?
         (or (>= army-supply 4) (>= minerals 200))
         (or (< workers 32)
             (< army-supply (* 0.8 enemy-threat-supply))
             (< army-supply 16))))
  (define defer-stargate?
    (or has-robo? (and (not eff-req-aa?) (not enemy-cap-air?))))
  (define live-slots? (hash? open-facility-slots))
  (define peaceful? (and (not under-attack?) (<= enemy-threat-supply 0)))
  (define early-zero-army-attack?
    (and (or under-attack? (> enemy-threat-supply 0))
         (= army-supply 0)))
  (define root-combat-facility-ready?
    (case race
      [(Zerg) (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)]
      [(Terran) (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0)]
      [else (> (+ (bldg-count-equivalent ready-bldg-counts 'gateway)
                  (bldg-count-equivalent ready-bldg-counts 'warp-gate)) 0)]))
  (define under-early-rush-crisis?
    (and (< frame 3000)
         (or under-attack? (>= enemy-threat-supply 4))))
  (define plan-supply-sym
    (case race [(Zerg) 'overlord] [(Terran) 'supply-depot] [else 'pylon]))
  (define plan-cur-supply-cnt
    (case race
      [(Zerg) (unit-count-equivalent unit-counts 'overlord)]
      [(Terran) (bldg-count-equivalent total-bldg-counts 'supply-depot)]
      [else (bldg-count-equivalent total-bldg-counts 'pylon)]))
  (define hard-supply-block?
    (and (< supply-cap 200)
         (<= pending-supply 0)
         (or (<= supply-left 0)
             (>= supply-used supply-cap))))
  (define zero-supply-provider-lockout?
    (and (< supply-cap 200)
         (<= pending-supply 0)
         (<= supply-left 1)
         (<= supply-cap (* 15 (max 1 active-bases)))
         (or (and (eq? race 'Protoss)
                  (= (bldg-count-equivalent total-bldg-counts 'pylon) 0)
                  (>= supply-used 14))
             (and (eq? race 'Terran)
                  (= (bldg-count-equivalent total-bldg-counts 'supply-depot) 0)
                  (>= supply-used 14)))))
  (define supply-lockout-active?
    (or hard-supply-block? zero-supply-provider-lockout?))
  (define plan-total-townhalls
    (case race
      [(Zerg) (bldg-count-equivalent total-bldg-counts 'hatchery)]
      [(Terran) (bldg-count-equivalent total-bldg-counts 'command-center)]
      [else (bldg-count-equivalent total-bldg-counts 'nexus)]))

  (define-values (elapsed-sec steps-so-far due-upgs due-units due-timing-goals)
    (collect-due-bo-context race enemy-race frame effective-phase-supply))
  (define zerg-t3-on? (zerg-hive-t3-online? race ready-bldg-counts))
  (define filtered-repair-goals
    (if zerg-t3-on?
        (filter (lambda (g)
                  (not (zerg-t3-obsolete-unbuilt? (pro-bo-goal-target-sym g) total-bldg-counts)))
                steps-so-far)
        steps-so-far))
  (define repaired-prereqs
    (filter (lambda (sym)
              (and (not (and zerg-t3-on? (zerg-t3-obsolete-unbuilt? sym total-bldg-counts)))
                   (not (crisis-deferred-sym? (normalize-brain-sym sym) crisis-defer?
                                              #:defer-stargate? defer-stargate?
                                              #:keep-ship-weapons? ship-weap-due?
                                              #:keep-spire-aa? keep-spire-aa?))))
            (find-all-broken-tech-dependencies
             race ready-bldg-counts total-bldg-counts
             #:active-goals filtered-repair-goals)))
  (define ctx-out
    (dyn-plan-ctx
     all-upgs benchmark-targets
     has-robo? has-ready-armory? enemy-cap-air? enemy-cap-air-ground-aa?
     desired-thors air-fleet-cnt ship-weap-due?
     zvp-stargate-threat? keep-spire-aa? aa-effective? pvt-fast-kiter-threat? tvp-cannon-contain?
     desired-spores has-lair-or-hive-ready? desired-overseers desired-droppers
     gas-bldg-sym total-gas-bldgs suppress-tvp-extra-rax?
     crisis-defer? severe-crisis-static-def? defer-stargate?
     early-zero-army-attack? root-combat-facility-ready? under-early-rush-crisis?
     plan-supply-sym hard-supply-block? zero-supply-provider-lockout? supply-lockout-active?
     plan-total-townhalls steps-so-far due-timing-goals repaired-prereqs
     post-bo-goals post-bo-deviation))

  (define raw-goal-specs '())
  (define (add-goal-spec! id track kind target-count weight reason)
    (define nsym (normalize-brain-sym id))
    (define not-crisis-def?
      (not (crisis-deferred-sym? nsym crisis-defer?
                                 #:defer-stargate? defer-stargate?
                                 #:keep-ship-weapons? ship-weap-due?
                                 #:keep-spire-aa? keep-spire-aa?)))
    (define upg-gate-ok?
      (or (not (eq? kind 'research))
          (upgrade-allowed-by-unit-and-order-gates?
           race nsym frame workers
           ready-bldg-counts total-bldg-counts unit-counts
           researched-upgrades pending-upgrades)))
    (cond
      [(and (lookup-sc2-tech-node id) upg-gate-ok? not-crisis-def?)
       (set! raw-goal-specs
             (cons (list id track kind target-count weight reason)
                   raw-goal-specs))]
      [(and (eq? kind 'research)
            (not upg-gate-ok?)
            not-crisis-def?
            (memq reason '(macro-tech-plan timing-upgrade-plan))
            (sc2-tech-prereqs-ready? nsym ready-bldg-counts unit-counts))
       (define sub
         (bug5-gated-upgrade-prereq-spec
          race nsym ready-bldg-counts researched-upgrades pending-upgrades))
       (when (and sub (lookup-sc2-tech-node (second sub)))
         (define p-kind (first sub))
         (define p-sym (second sub))
         (define p-tgt (third sub))
         (define p-track (if (eq? p-kind 'research) 'tech-infrastructure 'army-production))
         (set! raw-goal-specs
               (cons (list p-sym p-track p-kind p-tgt (max weight 488.0) 'bug5-upgrade-prereq)
                     raw-goal-specs)))]))

  ;; Track 1: Survival, Hard Supply-Lockout Unblock, Worker-Rush Override & Broken Prereq Repair
  (when supply-lockout-active?
    (add-goal-spec! plan-supply-sym
                    'survival-supply
                    (if (eq? race 'Zerg) 'train 'build)
                    (add1 plan-cur-supply-cnt)
                    980.0
                    'emergency-supply-unblock))

  (when (and (<= plan-total-townhalls 1)
             (natural-expansion-window-active?
              race frame workers plan-total-townhalls
              ready-bldg-counts total-bldg-counts
              under-attack? enemy-threat-supply under-early-rush-crisis?))
    (add-goal-spec! (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus])
                    'economy-expansion 'build 2 620.0 'pro-benchmark-natural-expand))

  (when under-early-rush-crisis?
    (cond
      [(not root-combat-facility-ready?)
       (case race
         [(Zerg)
          (add-goal-spec! 'spawning-pool 'survival-supply 'build 1 590.0 'emergency-rush-defense)]
         [(Terran)
          (when (= (bldg-count-equivalent total-bldg-counts 'supply-depot) 0)
            (add-goal-spec! 'supply-depot 'survival-supply 'build 1 595.0 'emergency-rush-defense))
          (add-goal-spec! 'barracks 'survival-supply 'build 1 590.0 'emergency-rush-defense)]
         [else
          (when (= (bldg-count-equivalent total-bldg-counts 'pylon) 0)
            (add-goal-spec! 'pylon 'survival-supply 'build 1 595.0 'emergency-rush-defense))
          (add-goal-spec! 'gateway 'survival-supply 'build 1 590.0 'emergency-rush-defense)])]
      [(< army-supply (max 8 (+ enemy-threat-supply 4)))
       (case race
         [(Zerg)
          (add-goal-spec! 'zergling 'survival-supply 'train 8 540.0 'emergency-rush-defense)
          (add-goal-spec! 'spine-crawler 'survival-supply 'build 1 515.0 'emergency-rush-defense)]
         [(Terran)
          (add-goal-spec! 'marine 'survival-supply 'train 6 540.0 'emergency-rush-defense)
          (add-goal-spec! 'bunker 'survival-supply 'build 1 515.0 'emergency-rush-defense)]
         [else
          (if (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
              (begin
                (add-goal-spec! 'stalker 'survival-supply 'train 4 555.0 'emergency-rush-defense)
                (add-goal-spec! 'adept 'survival-supply 'train 2 545.0 'emergency-rush-defense)
                (unless pvt-fast-kiter-threat?
                  (add-goal-spec! 'zealot 'survival-supply 'train 2 530.0 'emergency-rush-defense))
                (add-goal-spec! 'shield-battery 'survival-supply 'build 1 520.0 'emergency-rush-defense))
              (begin
                (when (= (bldg-count-equivalent total-bldg-counts 'cybernetics-core) 0)
                  (add-goal-spec! 'cybernetics-core 'survival-supply 'build 1 552.0 'emergency-rush-defense))
                (add-goal-spec! 'zealot 'survival-supply 'train 2 540.0 'emergency-rush-defense)))])]))

  (for ([rep-sym (in-list repaired-prereqs)]
        [idx (in-naturals 0)])
    (define node (lookup-sc2-tech-node rep-sym))
    (when node
      (define root-repair?
        (or (not live-slots?)
            peaceful?
            (not root-combat-facility-ready?)
            (memq rep-sym '(spawning-pool barracks gateway pylon supply-depot overlord))))
      (define w (if root-repair? (- 560.0 (* 4.0 idx)) 160.0))
      (add-goal-spec! rep-sym 'survival-supply (sc2-tech-node-kind node) 1 w 'prereq-repair)))

  ;; Track 2 & 3 & 4: Evaluate ALL eligible Matchup Plan Milestones concurrently (not a FIFO queue!)
  (define zerg-hatch-first-opening?
    (and (eq? race 'Zerg)
         (< plan-total-townhalls 2)
         (not under-attack?)
         (not under-early-rush-crisis?)
         (<= enemy-threat-supply 1.5)
         (<= frame 2400)
         (not (not (findf (lambda (g)
                            (match g
                              [(pro-bo-goal kind sym _ _ _ _)
                               (and (eq? kind 'expand) (eq? sym 'hatchery))]
                              [_ #f]))
                          steps-so-far)))))
  (define macro-step-rank 0)
  (define seen-step-keys (make-hash))
  (for ([g (in-list steps-so-far)])
    (match-define (pro-bo-goal kind sym tgt-cnt min-sup _ _tgt-sec) g)
    (hash-set! seen-step-keys (cons kind (normalize-brain-sym sym)) #t)
    (define redundant-scaling-fac-with-idle-slots?
      (and live-slots?
           (< minerals 300)
           (or (and (eq? sym 'barracks)
                    (>= (bldg-count-equivalent total-bldg-counts 'barracks) (if (>= active-bases 2) 4 2))
                    (>= (hash-ref open-facility-slots 'barracks 0) 2))
               (and (eq? sym 'gateway)
                    (>= (bldg-count-equivalent total-bldg-counts 'gateway) (if (>= active-bases 2) 5 2))
                    (>= (+ (hash-ref open-facility-slots 'gateway 0)
                           (hash-ref open-facility-slots 'warp-gate 0))
                        2)))))
    (define protoss-1base-2nd-gas-capped?
      (and (eq? race 'Protoss)
           (eq? sym 'assimilator)
           (<= active-bases 1)
           (< plan-total-townhalls 2)
           (>= (bldg-count-equivalent total-bldg-counts 'assimilator) 1)
           (or (not (memq enemy-race '(Protoss Random)))
               (< (bldg-count-equivalent total-bldg-counts 'gateway) 2))
           (not under-early-rush-crisis?)))
    (define extra-geyser-deferred-by-gas-bank?
      (and (memq sym '(extractor refinery assimilator))
           (let ([cur-gb (bldg-count-equivalent total-bldg-counts sym)])
             (or (not (gas-building-cap-ok? cur-gb active-bases))
                 (< workers (min-workers-for-next-gas-bldg cur-gb))
                 early-zero-army-attack?
                 (and supply-lockout-active?
                      (< minerals (+ (sc2-min-cost plan-supply-sym 100) (sc2-min-cost sym 75))))
                 protoss-1base-2nd-gas-capped?
                 (and live-slots?
                      (> cur-gb 0)
                      (>= gas (if (and (>= cur-gb 2) (>= workers 36)) 550 250)))))))
    (define late-tech-deferred-by-low-army?
      (and live-slots?
           (memq sym '(armory ghost-academy))
           (< army-supply 18)
           (not (>= active-bases 3))
           (not (and (eq? sym 'armory) (eq? race 'Terran) enemy-cap-air?))
           (not (and (eq? sym 'ghost-academy) (eq? race 'Terran) (terran-enemy-needs-ghost? enemy-u-counts) (>= active-bases 2)))
           (not (ormap (lambda (r) (same-brain-sym? sym r)) repaired-prereqs))))
    (define zerg-hatch-first-defer?
      (and zerg-hatch-first-opening?
           (memq sym '(extractor spawning-pool))
           (< minerals 450)
           (not (ormap (lambda (r) (same-brain-sym? sym r)) repaired-prereqs))))
    (define suppressed-extra-tvp-rax?
      (and suppress-tvp-extra-rax?
           (eq? sym 'barracks)
           (>= (bldg-count-equivalent total-bldg-counts 'barracks) 1)))
    (define suppressed-kiter-zealot?
      (and pvt-fast-kiter-threat?
           (eq? sym 'zealot)
           (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)))
    (define nsym (normalize-brain-sym sym))
    (define suppressed-by-post-bo?
      (and (eq? kind 'train)
           (not (sg-unit-allowed? nsym))))
    (define eff-tgt-cnt
      (if (and (eq? kind 'train) (hash-has-key? sg-unit-caps nsym))
          (min tgt-cnt (hash-ref sg-unit-caps nsym tgt-cnt))
          tgt-cnt))
    (unless (or redundant-scaling-fac-with-idle-slots?
                extra-geyser-deferred-by-gas-bank?
                late-tech-deferred-by-low-army?
                (and zerg-t3-on? (zerg-t3-obsolete-unbuilt? sym total-bldg-counts))
                zerg-hatch-first-defer?
                suppressed-extra-tvp-rax?
                suppressed-kiter-zealot?
                suppressed-by-post-bo?
                (< eff-tgt-cnt 1))
      (cond
        [(eq? kind 'expand)
         (define exp-w
           (cond
             [(and supply-lockout-active?
                   (< minerals (+ (sc2-min-cost plan-supply-sym 100) (sc2-min-cost sym 300))))
              25.0]
             [(or peaceful? zerg-hatch-first-opening?)
              (max 466.0 (- 476.0 (* 2.0 macro-step-rank)))]
             [else 42.0]))
         (set! macro-step-rank (add1 macro-step-rank))
         (add-goal-spec! sym 'economy-expansion 'expand eff-tgt-cnt exp-w 'expansion-plan)]
        [(memq kind '(build morph research addon))
         (define non-defensive-tech-under-attack?
           (and live-slots?
                (not peaceful?)
                root-combat-facility-ready?
                (not (is-aa-or-detection-answer?
                      sym
                      (or aa-effective?
                          (and (eq? race 'Protoss) (protoss-enemy-capital-air? enemy-u-counts)))
                      eff-req-det?))
                (or (and (eq? kind 'research)
                         (or under-attack? (< army-supply (+ enemy-threat-supply 6))))
                    (memq sym '(lair hive spire greater-spire infestation-pit ultralisk-cavern evolution-chamber
                                engineering-bay armory ghost-academy fusion-core
                                twilight-council forge robotics-bay fleet-beacon templar-archive dark-shrine)))))
         (define addon-ready-free?
           (and (addon-parent-facility sym)
                peaceful?
                (>= workers 20)
                (not non-defensive-tech-under-attack?)
                (eq? (addon-parent-slot-state sym ready-bldg-counts total-bldg-counts)
                     'ready-slot-free)))
         (define tech-w
           (cond
             [non-defensive-tech-under-attack? 140.0]
             [addon-ready-free? (max 478.0 (- 476.0 (* 3.5 macro-step-rank)))]
             [else (max 442.0 (- 476.0 (* 3.5 macro-step-rank)))]))
         (set! macro-step-rank (add1 macro-step-rank))
         (add-goal-spec! sym 'tech-infrastructure kind eff-tgt-cnt tech-w 'macro-tech-plan)]
        [(eq? kind 'train)
         (define cur-queens (unit-count-equivalent unit-counts 'queen))
         (define queen-defer?
           (and (eq? sym 'queen)
                (or under-attack? (> enemy-threat-supply 2))
                (< army-supply 4)))
         (define queen-sat-defer?
           (and (eq? sym 'queen)
                (not (or zvp-stargate-threat? enemy-cap-air?))
                (< workers (min 42 (* 14 active-bases)))
                (>= cur-queens active-bases)))
         (define gas-locked-0g?
           (and live-slots?
                peaceful?
                (>= gas 80)
                (>= army-supply 4)
                (memq sym '(zergling marine zealot hellion))))
         (define past-opening-window?
           (and (> effective-phase-supply (+ min-sup 6))
                (or (memq sym '(overlord zergling marine zealot hellion))
                    (> (unit-count-equivalent unit-counts sym) 0))))
         (define unfulfilled-unique-bo-train?
           (and peaceful?
                (not (memq sym '(overlord zergling marine zealot hellion)))
                (= (unit-count-equivalent unit-counts sym) 0)
                (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts)))
         (define train-w
           (cond
             [queen-defer? 80.0]
             [queen-sat-defer? 120.0]
             [(or gas-locked-0g? past-opening-window?) 390.0]
             [unfulfilled-unique-bo-train? 494.0]
             [peaceful? 466.0]
             [else 420.0]))
         (add-goal-spec! sym 'army-production 'train eff-tgt-cnt train-w 'army-milestone-plan)])))

  ;; Track 2c: Empirical Pro Upgrade & Unit Clock Timings (`frame > 0`)
  (define under-sat-econ?
    (and peaceful?
         (< workers (min 36 (* 16 active-bases)))))
  (define (timing-goal-needs-extra-occupied-parent? sym)
    (define prereqs-ready? (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts))
    (and (not prereqs-ready?)
         (not (and eff-req-det? (eq? (normalize-brain-sym sym) 'raven)))
         (let ([chain (resolve-missing-prereq-chain sym ready-bldg-counts total-bldg-counts)])
           (and (pair? chain)
                (let ([first-m (first chain)])
                  (and (memq first-m '(barracks factory starport))
                       (> (bldg-count-equivalent total-bldg-counts first-m) 0)
                       (let* ([nd (lookup-sc2-tech-node sym)]
                              [ps (if nd (sc2-tech-node-prereqs nd) '())])
                         (not (ormap (lambda (psym)
                                       (define npsym (normalize-brain-sym psym))
                                       (or (hash-has-key? seen-step-keys (cons 'build npsym))
                                           (hash-has-key? seen-step-keys (cons 'addon npsym))))
                                     ps)))))))))
  (when (> frame 0)
    (for ([up (in-list due-upgs)])
      (define sym (pro-upgrade-timing-upgrade-sym up))
      (define ssec (exact->inexact (pro-upgrade-timing-start-sec up)))
      (unless (or (hash-has-key? seen-step-keys (cons 'research (normalize-brain-sym sym)))
                  (sc2-tech-already-satisfied? sym total-bldg-counts researched-upgrades pending-upgrades 1)
                  (timing-goal-needs-extra-occupied-parent? sym))
        (define timing-prereqs-ready? (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts))
        (define non-defensive-under-attack?
          (and live-slots?
               (not peaceful?)
               root-combat-facility-ready?
               (not (is-aa-or-detection-answer? sym aa-effective? eff-req-det?))
               (or under-attack? (< army-supply (+ enemy-threat-supply 6)))))
        (define upg-w
          (cond
            [non-defensive-under-attack? 140.0]
            [(not timing-prereqs-ready?) (if under-sat-econ? 422.0 430.0)]
            [(>= elapsed-sec ssec) (if under-sat-econ? 428.0 460.0)]
            [else (if under-sat-econ? 422.0 438.0)]))
        (add-goal-spec! sym 'tech-infrastructure 'research 1 upg-w 'timing-upgrade-plan)))
    (for ([ut (in-list due-units)])
      (define sym (pro-unit-timing-unit-sym ut))
      (define nsym (normalize-brain-sym sym))
      (define raw-tgt-cnt (pro-unit-timing-target-count ut))
      (define tgt-cnt
        (if (hash-has-key? sg-unit-caps nsym)
            (min raw-tgt-cnt (hash-ref sg-unit-caps nsym raw-tgt-cnt))
            raw-tgt-cnt))
      (define min-sup (pro-unit-timing-min-supply ut))
      (define tsec (exact->inexact (pro-unit-timing-target-sec ut)))
      (define cur-cnt (unit-count-equivalent unit-counts sym))
      (unless (or (< tgt-cnt 1)
                  (>= cur-cnt tgt-cnt)
                  (not (sg-unit-allowed? nsym cur-cnt))
                  (hash-has-key? seen-step-keys (cons 'train nsym))
                  (timing-goal-needs-extra-occupied-parent? sym)
                  (and pvt-fast-kiter-threat?
                       (eq? sym 'zealot)
                       (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0))
                  (and (eq? sym 'overlord) (> effective-phase-supply (+ min-sup 12))))
        (define timing-prereqs-ready? (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts))
        (define queen-defer?
          (and (eq? sym 'queen)
               (or under-attack? (> enemy-threat-supply 2))
               (< army-supply 4)))
        (define queen-sat-defer?
          (and (eq? sym 'queen)
               (not (or zvp-stargate-threat? enemy-cap-air?))
               (< workers (min 42 (* 14 active-bases)))
               (>= (unit-count-equivalent unit-counts 'queen) active-bases)))
        (define past-unit-window?
          (and (> effective-phase-supply (+ min-sup 12))
               (or (>= cur-cnt 1)
                   (memq sym '(reaper adept)))))
        (unless past-unit-window?
          (define unit-w
            (cond
              [queen-defer? 80.0]
              [queen-sat-defer? 120.0]
              [(not peaceful?) 420.0]
              [(not timing-prereqs-ready?) (if under-sat-econ? 422.0 430.0)]
              [(and (>= elapsed-sec tsec) (not under-sat-econ?)) 436.0]
              [else 424.0]))
          (add-goal-spec! sym 'army-production 'train tgt-cnt unit-w 'timing-unit-plan)))))

  ;; Track 2b: Zerg Per-Base + Creep/Defense Queen Engine (capped at SC2-MAX-QUEENS-CAP = 8)
  (define cur-queens (unit-count-equivalent unit-counts 'queen))
  (define early-aggro? (or under-attack? (> enemy-threat-supply 0)))
  (define desired-queens
    (if (and (eq? race 'Zerg) enemy-cap-air?)
        SC2-MAX-QUEENS-CAP
        (desired-zerg-queen-count active-bases zvp-stargate-threat? early-aggro?)))
  (when (and (eq? race 'Zerg)
             (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
             (< cur-queens desired-queens))
    (define queen-drone-sat-defer?
      (and (not (or zvp-stargate-threat? enemy-cap-air?))
           (< workers (min 42 (* 14 active-bases)))
           (>= cur-queens active-bases)))
    (add-goal-spec! 'queen 'economy-expansion 'train desired-queens
                    (cond
                      [(and (or under-attack? (> enemy-threat-supply 2)) (< army-supply 4)) 80.0]
                      [(or zvp-stargate-threat? enemy-cap-air?) 495.0]
                      [queen-drone-sat-defer? 120.0]
                      [(and live-slots? peaceful? (< cur-queens active-bases)) 445.0]
                      [(and live-slots? peaceful?) 432.0]
                      [else 230.0])
                    'larva-inject-engine))

  ;; Track 3b: Dynamic Gas-Unlock Tech Progression when floating >= 80G in peace time
  (when (and live-slots? peaceful? (>= gas 80))
    (case race
      [(Zerg)
       (when (and (= (bldg-count-equivalent total-bldg-counts 'roach-warren) 0)
                  (= (bldg-count-equivalent total-bldg-counts 'lair) 0)
                  (= (bldg-count-equivalent total-bldg-counts 'hive) 0))
         (add-goal-spec! 'roach-warren 'tech-infrastructure 'build 1 455.0 'gas-unlock-tech))
       (when (and (>= gas 100)
                  (> (bldg-count-equivalent total-bldg-counts 'roach-warren) 0)
                  (= (bldg-count-equivalent total-bldg-counts 'lair) 0)
                  (= (bldg-count-equivalent total-bldg-counts 'hive) 0))
         (add-goal-spec! 'lair 'tech-infrastructure 'morph 1 448.0 'gas-unlock-tech))]
      [(Protoss)
       (when (= (bldg-count-equivalent total-bldg-counts 'cybernetics-core) 0)
         (add-goal-spec! 'cybernetics-core 'tech-infrastructure 'build 1 455.0 'gas-unlock-tech))
       (when (and (>= gas 100)
                  (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
                  (= (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0))
         (add-goal-spec! 'robotics-facility 'tech-infrastructure 'build 1 450.0 'gas-unlock-tech))]
      [(Terran)
       (when (and (>= gas 100)
                  (= (bldg-count-equivalent total-bldg-counts 'factory) 0))
         (add-goal-spec! 'factory 'tech-infrastructure 'build 1 455.0 'gas-unlock-tech))
       (when (and (>= gas 100)
                  (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)
                  (= (bldg-count-equivalent total-bldg-counts 'starport) 0))
         (add-goal-spec! 'starport 'tech-infrastructure 'build 1 450.0 'gas-unlock-tech))]))

  ;; Track 5: Dynamic Counter-Tech & Proactive Intel/Detection/Harass Goals
  (when (and (eq? race 'Zerg) has-lair-or-hive-ready?)
    (define cur-overseers (unit-count-equivalent unit-counts 'overseer))
    (when (and (> desired-overseers 0) (< cur-overseers desired-overseers))
      (add-goal-spec! 'overseer 'intel-recon 'morph desired-overseers
                      (cond
                        [(= cur-overseers 0) 488.0]
                        [requires-detection? 478.0]
                        [else 456.0])
                      'proactive-overseer-detection))
    (define cur-droppers (unit-count-for-goal unit-counts 'overlord-transport))
    (when (and (> desired-droppers 0)
               (< cur-droppers desired-droppers)
               (> (morph-source-unit-count unit-counts 'overlord) 0))
      (add-goal-spec! 'overlord-transport 'army-production 'morph desired-droppers
                      454.0 'proactive-dropperlord-harass)))

  (define enemy-ground-army?
    (if (and (hash? enemy-u-counts) (> (hash-count enemy-u-counts) 0))
        (let ([ground-cnt
               (for/sum ([(utype cnt) (in-hash enemy-u-counts)]
                         #:when (and (> (if (exact-integer? cnt) cnt 0) 0)
                                     (not (memq utype
                                                '(drone scv probe larva egg cocoon
                                                  overlord overlord-transport overseer overseer-siege-mode
                                                  observer observer-siege-mode medivac warp-prism warp-prism-phasing
                                                  mutalisk corruptor brood-lord broodlord viper
                                                  viking viking-fighter liberator banshee raven battlecruiser
                                                  phoenix oracle void-ray voidray carrier tempest mothership interceptor)))))
                 cnt)]
              [air-combat-cnt
               (for/sum ([(utype cnt) (in-hash enemy-u-counts)]
                         #:when (memq utype '(mutalisk corruptor brood-lord broodlord viper
                                               viking viking-fighter liberator banshee raven battlecruiser
                                               phoenix oracle void-ray voidray carrier tempest mothership)))
                 (if (exact-integer? cnt) cnt 0))])
          (or (> ground-cnt 0)
              (and (not eff-req-aa?) (= air-combat-cnt 0))))
        (not eff-req-aa?)))

  (define terran-need-ghost? (terran-enemy-needs-ghost? enemy-u-counts))
  (define terran-need-lib? (terran-enemy-needs-liberator? enemy-u-counts))
  (define desired-rax-tl
    (terran-desired-barracks-techlabs race enemy-race (bldg-count-equivalent total-bldg-counts 'barracks)))
  (define desired-factories
    (terran-desired-factories race enemy-race active-bases effective-phase-supply))
  (define desired-ghosts
    (terran-desired-ghost-cap active-bases supply-used enemy-race enemy-u-counts))
  (define desired-libs
    (terran-desired-liberator-cap active-bases enemy-u-counts))

  (when (eq? race 'Zerg)
    (define cur-zerglings (unit-count-equivalent unit-counts 'zergling))
    (define cur-banelings (unit-count-equivalent unit-counts 'baneling))
    (define baneling-light-bio-rec? (> (hash-ref sg-rec-units 'baneling 0.0) 0.0))
    (define min-lings-for-bane (if baneling-light-bio-rec? 2 8))
    (define baneling-cap
      (if baneling-light-bio-rec?
          (min 18 (max 8 cur-zerglings))
          (min 12 (max 4 (quotient cur-zerglings 2)))))
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'baneling-nest) 0)
               (>= cur-zerglings min-lings-for-bane)
               (or baneling-light-bio-rec? enemy-ground-army?)
               (< cur-banelings baneling-cap))
      (add-goal-spec! 'baneling 'army-production 'morph baneling-cap
                      (cond
                        [(and baneling-light-bio-rec? (< cur-banelings 6)) 486.0]
                        [baneling-light-bio-rec? 474.0]
                        [(< cur-banelings 4) 472.0]
                        [else 448.0])
                      'proactive-baneling-morph))
    (define cur-hydras (unit-count-equivalent unit-counts 'hydralisk))
    (define cur-lurkers (unit-count-equivalent unit-counts 'lurker))
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'lurker-den) 0)
               (>= cur-hydras 2)
               (< cur-lurkers 10))
      (add-goal-spec! 'lurker 'army-production 'morph 10
                      (if (< cur-lurkers 4) 476.0 456.0)
                      'proactive-lurker-morph))
    ;; Proactive Zerg burrow, tunneling-claws, and centrifical-hooks timings.
    (define has-t3-hive-tech?
      (and (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)
           (or (> (bldg-count-equivalent ready-bldg-counts 'ultralisk-cavern) 0)
               (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0))))
    (define has-burrow-play-unit?
      (or (>= (unit-count-equivalent unit-counts 'roach) 2)
          (>= (unit-count-equivalent unit-counts 'infestor) 1)
          (>= (unit-count-equivalent unit-counts 'lurker) 1)
          (> (bldg-count-equivalent ready-bldg-counts 'lurker-den) 0)))
    (when (and (not crisis-defer?)
               peaceful?
               (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
               (>= effective-phase-supply 28)
               (or (not has-t3-hive-tech?) has-burrow-play-unit?)
               (or (> (bldg-count-equivalent ready-bldg-counts 'roach-warren) 0)
                   has-burrow-play-unit?)
               (or (has-upgrade-sym? 'metabolic-boost all-upgs)
                   (>= gas 100))
               (not (sc2-tech-already-satisfied? 'burrow total-bldg-counts researched-upgrades pending-upgrades 1)))
      (add-goal-spec! 'burrow 'tech-infrastructure 'research 1 462.0 'proactive-burrow-tech))
    (when (and (not crisis-defer?)
               has-lair-or-hive-ready?
               (> (bldg-count-equivalent ready-bldg-counts 'roach-warren) 0)
               (>= (unit-count-equivalent unit-counts 'roach) 4)
               (not (sc2-tech-already-satisfied? 'tunneling-claws total-bldg-counts researched-upgrades pending-upgrades 1)))
      (add-goal-spec! 'tunneling-claws 'tech-infrastructure 'research 1 464.0 'roach-burrow-micro-tech))
    (when (and has-lair-or-hive-ready?
               (> (bldg-count-equivalent ready-bldg-counts 'baneling-nest) 0)
               (>= (+ cur-zerglings cur-banelings) 6)
               (not (sc2-tech-already-satisfied? 'centrifical-hooks total-bldg-counts researched-upgrades pending-upgrades 1)))
      (add-goal-spec! 'centrifical-hooks 'tech-infrastructure 'research 1 468.0 'baneling-speed-timing))
    ;; [ISSUE-R5-3] ZvP Stargate / Phoenix / Oracle -> 1 Spore Crawler per base + Hydralisk/Queen AA.
    (when (and (> desired-spores 0)
               (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
               (< (bldg-count-equivalent total-bldg-counts 'spore-crawler) desired-spores))
      (add-goal-spec! 'spore-crawler 'intel-recon 'build desired-spores
                      (if (or zvp-stargate-threat? enemy-cap-air?) 496.0 490.0)
                      'stargate-mineral-line-spore))
    (when zvp-stargate-threat?
      (when (< cur-queens desired-queens)
        (add-goal-spec! 'queen 'survival-supply 'train desired-queens 496.0 'zvp-stargate-aa-response))
      (when (and has-lair-or-hive-ready?
                 (= (bldg-count-equivalent total-bldg-counts 'hydralisk-den) 0))
        (add-goal-spec! 'hydralisk-den 'tech-infrastructure 'build 1 488.0 'zvp-stargate-aa-response))
      (when (> (bldg-count-equivalent ready-bldg-counts 'hydralisk-den) 0)
        (add-goal-spec! 'hydralisk 'army-production 'train 8 492.0 'zvp-stargate-aa-response)))
    ;; Anti-Capital-Air (`battlecruiser`, `carrier`, `tempest`, `brood-lord`): ramp Queens to 8,
    ;; unlock Lair -> Spire -> Corruptors (14..20) + Flyer Armor, and backup Hydralisks (#156 G1).
    (when enemy-cap-air?
      (define zerg-cap-air-corruptors
        (zerg-enemy-capital-air-corruptor-cap enemy-u-counts eff-req-aa? enemy-race))
      (when (< cur-queens desired-queens)
        (add-goal-spec! 'queen 'survival-supply 'train desired-queens 497.0 'anti-capital-air))
      (when (and (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
                 (= (bldg-count-equivalent total-bldg-counts 'spire) 0)
                 (= (bldg-count-equivalent total-bldg-counts 'greater-spire) 0))
        (add-goal-spec! 'spire 'tech-infrastructure 'build 1 495.0 'anti-capital-air))
      (when (and (or (> (bldg-count-equivalent ready-bldg-counts 'spire) 0)
                     (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0))
                 (< (unit-count-equivalent unit-counts 'corruptor) zerg-cap-air-corruptors))
        (add-goal-spec! 'corruptor 'army-production 'train zerg-cap-air-corruptors 494.0 'anti-capital-air))
      (when (and (or (> (bldg-count-equivalent ready-bldg-counts 'spire) 0)
                     (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0))
                 (not (sc2-tech-already-satisfied? 'zerg-flyer-armor-1 total-bldg-counts researched-upgrades pending-upgrades 1)))
        (add-goal-spec! 'zerg-flyer-armor-1 'tech-infrastructure 'research 1 490.0 'anti-capital-air))
      (when (> (bldg-count-equivalent ready-bldg-counts 'hydralisk-den) 0)
        (add-goal-spec! 'hydralisk 'army-production 'train 12 486.0 'anti-capital-air)))
    ;; Keep Roach (< 16) active as mineral-sink ground core when minerals >= 300 (unless ZvP anti-Immortal suppresses Roaches).
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'roach-warren) 0)
               (sg-unit-allowed? 'roach)
               (>= minerals 300)
               (< (unit-count-equivalent unit-counts 'roach) 16))
      (add-goal-spec! 'roach 'army-production 'train 16
                      (if (> (bldg-count-equivalent ready-bldg-counts 'hydralisk-den) 0) 442.0 462.0)
                      'zerg-roach-mineral-sink))
    ;; Boost ready-tech Ultralisk & Brood Lord whenever Ultralisk Cavern / Greater Spire are ready.
    (when (> (bldg-count-equivalent ready-bldg-counts 'ultralisk-cavern) 0)
      (add-goal-spec! 'chitinous-plating 'tech-infrastructure 'research 1 462.0 't3-endgame-tech)
      (add-goal-spec! 'anabolic-synthesis 'tech-infrastructure 'research 1 458.0 't3-endgame-tech)
      (add-goal-spec! 'ultralisk 'army-production 'train (if (>= active-bases 4) 6 4) 470.0 'ready-tech-ultralisk))
    (when (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0)
      (when (< (unit-count-equivalent unit-counts 'corruptor) 1)
        (add-goal-spec! 'corruptor 'army-production 'train 2 466.0 'ready-tech-brood-lord))
      (add-goal-spec! 'brood-lord 'army-production 'morph (if (>= active-bases 4) 5 3) 474.0 'ready-tech-brood-lord)))

  ;; TvT scaling (`barracks-techlab`, 2nd `factory`, `marauder`, `siege-tank`, `medivac`, `viking-fighter`)
  ;; and ready-tech / enemy-triggered Ghost & Liberator counters (`#5123417`, `#5123667`, `#5123937`).
  (when (eq? race 'Terran)
    ;; [ISSUE-R5-1] TvP Cannon Contain Break & Early Factory/Tank Progression
    (when (or tvp-cannon-contain?
              (and (eq? enemy-race 'Protoss)
                   (> (bldg-count-equivalent total-bldg-counts 'barracks) 0)
                   (or (> total-gas-bldgs 0) (>= gas 50) (>= frame 1800))))
      (when (= (bldg-count-equivalent total-bldg-counts 'factory) 0)
        (add-goal-spec! 'factory 'tech-infrastructure 'build 1
                        (if tvp-cannon-contain? 495.0 476.0)
                        'tvp-cannon-contain-break))
      (when (and (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)
                 (= (bldg-count-equivalent total-bldg-counts 'factory-techlab) 0)
                 (not (facility-addon-slot-occupied? 'factory-techlab ready-bldg-counts total-bldg-counts #:min-ready-floor 1)))
        (add-goal-spec! 'factory-techlab 'tech-infrastructure 'addon 1
                        (if tvp-cannon-contain? 494.0 475.0)
                        'tvp-cannon-contain-break))
      (when (and (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
                 (< (unit-count-equivalent unit-counts 'siege-tank) (if tvp-cannon-contain? 3 2)))
        (add-goal-spec! 'siege-tank 'army-production 'train (if tvp-cannon-contain? 3 2)
                        (if tvp-cannon-contain? 496.0 474.0)
                        'tvp-cannon-contain-break))
      (when (and tvp-cannon-contain?
                 (> (bldg-count-equivalent ready-bldg-counts 'barracks-techlab) 0)
                 (not (sc2-tech-already-satisfied? 'concussive-shells total-bldg-counts researched-upgrades pending-upgrades 1)))
        (add-goal-spec! 'concussive-shells 'tech-infrastructure 'research 1 478.0 'tvp-cannon-contain-break)))
    (when (and (memq enemy-race '(Terran Protoss))
               (< (bldg-count-equivalent total-bldg-counts 'barracks-techlab) desired-rax-tl)
               (not (facility-addon-slot-occupied? 'barracks-techlab ready-bldg-counts total-bldg-counts #:min-ready-floor 1)))
      (add-goal-spec! 'barracks-techlab 'tech-infrastructure 'addon desired-rax-tl 466.0 'tvt-rax-techlab-scaling))
    (when (and (eq? enemy-race 'Terran) (>= desired-factories 2))
      (when (< (bldg-count-equivalent total-bldg-counts 'factory) desired-factories)
        (add-goal-spec! 'factory 'tech-infrastructure 'build desired-factories 466.0 'tvt-mech-scaling))
      (when (and (>= (bldg-count-equivalent ready-bldg-counts 'factory) 2)
                 (< (bldg-count-equivalent total-bldg-counts 'factory-techlab) desired-factories)
                 (not (facility-addon-slot-occupied? 'factory-techlab ready-bldg-counts total-bldg-counts #:min-ready-floor 1)))
        (add-goal-spec! 'factory-techlab 'tech-infrastructure 'addon desired-factories 465.0 'tvt-mech-scaling)))
    (when (and (eq? enemy-race 'Terran) (>= effective-phase-supply 26))
      (when (> (bldg-count-equivalent ready-bldg-counts 'barracks-techlab) 0)
        (add-goal-spec! 'marauder 'army-production 'train (if (>= active-bases 2) 10 4) 462.0 'tvt-bio-tank))
      (when (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
        (add-goal-spec! 'siege-tank 'army-production 'train (if (>= active-bases 2) 8 3) 468.0 'tvt-bio-tank))
      (when (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
        (add-goal-spec! 'medivac 'army-production 'train 4 464.0 'tvt-bio-tank)
        (add-goal-spec! 'viking-fighter 'army-production 'train 6 465.0 'tvt-bio-tank)))
    (when (and (or (>= active-bases 3)
                   (and (>= active-bases 2) terran-need-ghost?))
               terran-need-ghost?)
      (add-goal-spec! 'ghost-academy 'tech-infrastructure 'build 1
                      (if (>= active-bases 2) 478.0 474.0)
                      't3-ghost-counter))
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'ghost-academy) 0)
               (< (unit-count-equivalent unit-counts 'ghost) desired-ghosts))
      (add-goal-spec! 'ghost 'army-production 'train desired-ghosts
                      (if terran-need-ghost? 480.0 465.0)
                      't3-ghost-counter))
    (when (and (>= active-bases 3)
               terran-need-lib?
               (> (bldg-count-equivalent ready-bldg-counts 'starport) 0))
      (add-goal-spec! 'liberator 'army-production 'train desired-libs 474.0 't3-liberator-counter))
    ;; Proactive Widow Mine, Raven, and Viking multi-task/control production when facilities are ready
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)
               (or (memq enemy-race '(Protoss Zerg)) (>= active-bases 2))
               (< (unit-count-equivalent unit-counts 'widow-mine) (if (>= active-bases 2) 3 1)))
      (add-goal-spec! 'widow-mine 'army-production 'train (if (>= active-bases 2) 3 1)
                      462.0 'proactive-widow-mine-harass))
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
               (> (bldg-count-equivalent ready-bldg-counts 'starport-techlab) 0)
               (< (unit-count-equivalent unit-counts 'raven) (if (or eff-req-det? (>= active-bases 2)) 2 1)))
      (add-goal-spec! 'raven 'intel-recon 'train (if (or eff-req-det? (>= active-bases 2)) 2 1)
                      (if eff-req-det? 496.0 462.0)
                      'proactive-raven-intel))
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
               (< (unit-count-equivalent unit-counts 'medivac) 2)
               (>= (+ (unit-count-equivalent unit-counts 'marine)
                      (unit-count-equivalent unit-counts 'marauder))
                   6))
      (add-goal-spec! 'medivac 'army-production 'train 2 464.0 'proactive-bio-medivac))
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
               (or eff-req-aa? enemy-cap-air? (memq enemy-race '(Protoss Terran)))
               (< (unit-count-equivalent unit-counts 'viking-fighter)
                  (cond
                    [enemy-cap-air? 20]
                    [eff-req-aa? 6]
                    [else 2])))
      (add-goal-spec! 'viking-fighter 'army-production 'train
                      (cond
                        [enemy-cap-air? 20]
                        [eff-req-aa? 6]
                        [else 2])
                      (cond
                        [enemy-cap-air? 496.0]
                        [eff-req-aa? 492.0]
                        [else 458.0])
                      (if enemy-cap-air? 'anti-capital-air 'proactive-viking-control)))
    ;; [BUG-4] Multi-Starport + StarportReactor scaling vs enemy capital air (`FastBC`, `Tempest`, `Carrier`, `BroodLord`)
    (when enemy-cap-air?
      (define want-cap-air-starports (if (>= active-bases 3) 3 2))
      (define want-cap-air-reactors (if (>= active-bases 3) 2 1))
      (when (and (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)
                 (< (bldg-count-equivalent total-bldg-counts 'starport) want-cap-air-starports))
        (add-goal-spec! 'starport 'tech-infrastructure 'build want-cap-air-starports 488.0 'anti-capital-air))
      (when (and (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
                 (< (bldg-count-equivalent total-bldg-counts 'starport-reactor) want-cap-air-reactors)
                 (not (facility-addon-slot-occupied? 'starport-reactor ready-bldg-counts total-bldg-counts #:min-ready-floor 1))
                 (or (> (bldg-count-equivalent total-bldg-counts 'starport-techlab) 0)
                     (>= (bldg-count-equivalent total-bldg-counts 'starport) 2)
                     (not requires-detection?)))
        (add-goal-spec! 'starport-reactor 'tech-infrastructure 'addon want-cap-air-reactors 486.0 'anti-capital-air)))
    ;; [NOTE-R4-B] Anti-Capital-Air (`tempest`, `carrier`, `battlecruiser`, `brood-lord`):
    ;; boost Armory + Thors (< 5-6) alongside Viking-Fighter, plus `+1` Ship Weapons when air fleet >= 4.
    (when (and enemy-cap-air?
               (or enemy-cap-air-ground-aa?
                   (> (bldg-count-equivalent total-bldg-counts 'factory-techlab) 0)))
      (when (and (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)
                 (= (bldg-count-equivalent total-bldg-counts 'armory) 0))
        (add-goal-spec! 'armory 'tech-infrastructure 'build 1
                        (if enemy-cap-air-ground-aa? 494.0 486.0)
                        'anti-capital-air))
      (when (and (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
                 (< (unit-count-equivalent unit-counts 'viking-fighter) 20))
        (add-goal-spec! 'viking-fighter 'army-production 'train 20 496.0 'anti-capital-air)))
    (when (and enemy-cap-air?
               (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
               (> (bldg-count-equivalent ready-bldg-counts 'armory) 0)
               (< (unit-count-equivalent unit-counts 'thor) desired-thors))
      (add-goal-spec! 'thor 'army-production 'train desired-thors
                      (if enemy-cap-air-ground-aa? 495.0 494.0)
                      'anti-capital-air))
    (when ship-weap-due?
      (add-goal-spec! 'terran-ship-weapons-1 'tech-infrastructure 'research 1 492.5 'anti-capital-air))
    ;; [BUG-5] Terran contained on <= 3 CCs with >= 1500M bank: queue breakout Orbital/CCs
    (when (and (<= active-bases 3)
               (<= plan-total-townhalls 3)
               (>= minerals 1500)
               (>= workers 18))
      (add-goal-spec! 'command-center 'economy-expansion 'expand (add1 active-bases) 478.0 'terran-breakout-cc)))

  ;; [NOTE-R4-A] Base-Defense Crisis: focus all resources/larva/production on immediate defenders.
  (when crisis-defer?
    (case race
      [(Zerg)
       (when (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
         (add-goal-spec! 'queen 'army-production 'train (min SC2-MAX-QUEENS-CAP (+ active-bases 2)) 468.0 'crisis-defense)
         (when (and severe-crisis-static-def? (< (bldg-count-equivalent total-bldg-counts 'spine-crawler) 2))
           (add-goal-spec! 'spine-crawler 'survival-supply 'build 2 470.0 'crisis-defense)))
       (when (> (bldg-count-equivalent ready-bldg-counts 'roach-warren) 0)
         (add-goal-spec! 'roach 'army-production 'train 16 471.0 'crisis-defense)
         (when (> (unit-count-equivalent unit-counts 'roach) 0)
           (add-goal-spec! 'ravager 'army-production 'morph (min 6 (unit-count-equivalent unit-counts 'roach)) 469.0 'crisis-defense)))]
      [(Protoss)
       (when (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
         (add-goal-spec! 'stalker 'army-production 'train 14 471.0 'crisis-defense)
         (when (and severe-crisis-static-def? (< (bldg-count-equivalent total-bldg-counts 'shield-battery) 2))
           (add-goal-spec! 'shield-battery 'survival-supply 'build 2 469.0 'crisis-defense)))
       (when (> (bldg-count-equivalent ready-bldg-counts 'robotics-facility) 0)
         (add-goal-spec! 'immortal 'army-production 'train 6 472.0 'crisis-defense))
       (when (> (+ (bldg-count-equivalent ready-bldg-counts 'gateway)
                   (bldg-count-equivalent ready-bldg-counts 'warp-gate)) 0)
         (add-goal-spec! 'zealot 'army-production 'train 12 466.0 'crisis-defense))]
      [(Terran)
       (when (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
         (add-goal-spec! 'siege-tank 'army-production 'train 8 471.0 'crisis-defense))
       (when (> (bldg-count-equivalent ready-bldg-counts 'barracks-techlab) 0)
         (add-goal-spec! 'marauder 'army-production 'train 10 469.0 'crisis-defense))
       (when (and severe-crisis-static-def?
                  (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0)
                  (< (bldg-count-equivalent total-bldg-counts 'bunker) 2))
         (add-goal-spec! 'bunker 'survival-supply 'build 2 468.0 'crisis-defense))]))

  ;; Protoss Anti-Capital-Air (`tempest`, `carrier`, `battlecruiser`, `brood-lord`),
  ;; [ISSUE-R5-2] PvT fast-kiter counter, proactive Adept/Oracle harass, & 4th Nexus.
  (when (eq? race 'Protoss)
    (when (and pvt-fast-kiter-threat?
               (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0))
      (add-goal-spec! 'stalker 'army-production 'train 8 492.0 'pvt-fast-kiter-counter)
      (add-goal-spec! 'adept 'army-production 'train 4 486.0 'pvt-fast-kiter-counter)
      (add-goal-spec! 'shield-battery 'survival-supply 'build 2 484.0 'pvt-fast-kiter-counter))
    (when (and (not pvt-fast-kiter-threat?)
               (not suppress-opening-harass?)
               (sg-unit-allowed? 'adept)
               (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
               (< army-supply 24)
               (< (unit-count-equivalent unit-counts 'adept) 2))
      (add-goal-spec! 'adept 'army-production 'train 2 458.0 'proactive-adept-harass))
    (when (and (> (bldg-count-equivalent ready-bldg-counts 'stargate) 0)
               (not enemy-cap-air?)
               (not suppress-opening-harass?)
               (not eff-req-aa?)
               (sg-unit-allowed? 'oracle)
               (< (unit-count-equivalent unit-counts 'oracle) 1))
      (add-goal-spec! 'oracle 'army-production 'train 1
                      466.0 'proactive-oracle-harass))
    (when enemy-cap-air?
      (add-goal-spec! 'stalker 'army-production 'train 12 494.0 'anti-capital-air)
      (add-goal-spec! 'stargate 'tech-infrastructure 'build (if (>= active-bases 2) 2 1) 495.0 'anti-capital-air)
      (when (> (bldg-count-equivalent ready-bldg-counts 'stargate) 0)
        (add-goal-spec! 'void-ray 'army-production 'train 8 495.0 'anti-capital-air)
        (add-goal-spec! 'fleet-beacon 'tech-infrastructure 'build 1 496.0 'anti-capital-air))
      (when (> (bldg-count-equivalent ready-bldg-counts 'fleet-beacon) 0)
        (add-goal-spec! 'tempest 'army-production 'train 10 498.0 'anti-capital-air)))
    (when (protoss-4th-nexus-due? race active-bases workers army-supply minerals enemy-cap-air?)
      (add-goal-spec! 'nexus 'economy-expansion 'expand 4
                      (if peaceful? 472.0 432.0)
                      'protoss-4th-nexus-scaling)))

  (when eff-req-aa?
    (case race
      [(Zerg)
       (add-goal-spec! 'queen 'survival-supply 'train (desired-zerg-queen-count active-bases #t) 495.0 'anti-air-response)
       (add-goal-spec! 'hydralisk 'army-production 'train 4 490.0 'anti-air-response)]
      [(Terran)
       (add-goal-spec! 'marine 'army-production 'train 6 495.0 'anti-air-response)
       (add-goal-spec! 'viking-fighter 'army-production 'train 2 490.0 'anti-air-response)]
      [(Protoss)
       (add-goal-spec! 'stalker 'army-production 'train 6 495.0 'anti-air-response)
       (add-goal-spec! 'blink 'tech-infrastructure 'research 1 492.0 'anti-air-response)
       (add-goal-spec! 'stargate 'tech-infrastructure 'build 1 488.0 'anti-air-response)
       (unless (or enemy-cap-air? (eq? enemy-race 'Terran) (not (sg-unit-allowed? 'phoenix)))
         (add-goal-spec! 'phoenix 'army-production 'train 10 491.0 'anti-air-response))]))

  (when eff-req-det?
    (case race
      [(Zerg)
       (add-goal-spec! 'spore-crawler 'intel-recon 'build (max 1 desired-spores) 495.0 'detection-response)
       (add-goal-spec! 'overseer 'intel-recon 'morph (max 1 desired-overseers) 492.0 'detection-response)]
      [(Terran)
       (add-goal-spec! 'missile-turret 'intel-recon 'build 1 495.0 'detection-response)
       (when (and (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
                  (> (bldg-count-equivalent ready-bldg-counts 'starport-techlab) 0)
                  (= (unit-count-equivalent unit-counts 'raven) 0))
         (add-goal-spec! 'raven 'intel-recon 'train 1 496.0 'detection-response))]
      [(Protoss)
       (add-goal-spec! 'observer 'intel-recon 'train 1 495.0 'detection-response)
       (when (and (= (unit-count-equivalent unit-counts 'observer) 0)
                  (= (bldg-count-equivalent total-bldg-counts 'photon-cannon) 0)
                  (or (> (bldg-count-equivalent ready-bldg-counts 'forge) 0)
                      (= (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0)))
         (add-goal-spec! 'photon-cannon 'intel-recon 'build 1 490.0 'detection-response))]))

  ;; Track 6: Cross-Race T3 Endgame Tech & Capital Army Progression (3+ bases & >=50 workers or >=90 supply)
  (define zerg-pit-spire-army-ok?
    (and (>= active-bases 3) (>= army-supply 28)))
  (define corruptor-cap
    (zerg-enemy-capital-air-corruptor-cap enemy-u-counts eff-req-aa? enemy-race))
  (define t3-endgame-window?
    (and (>= active-bases 3)
         (or (>= workers 50) (>= effective-phase-supply 90))
         (or peaceful? (>= army-supply (+ enemy-threat-supply 4)))))
  (when t3-endgame-window?
    (case race
      [(Zerg)
       (when (or zerg-pit-spire-army-ok? eff-req-aa? eff-req-det?)
         (add-goal-spec! 'infestation-pit 'tech-infrastructure 'build 1 468.0 't3-endgame-tech))
       (add-goal-spec! 'hive 'tech-infrastructure 'morph 1 472.0 't3-endgame-tech)
       (when (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)
         (when (> (bldg-count-equivalent ready-bldg-counts 'ultralisk-cavern) 0)
           (add-goal-spec! 'ultralisk 'army-production 'train 4 495.0 't3-endgame-army))
         (when (and (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0)
                    (> (unit-count-equivalent unit-counts 'corruptor) 0))
           (add-goal-spec! 'brood-lord 'army-production 'morph 4 494.0 't3-endgame-army))
         (add-goal-spec! 'viper 'army-production 'train (if (>= supply-used 130) 2 1) (if zerg-t3-on? 493.0 470.0) 't3-endgame-army)
         (add-goal-spec! 'ultralisk-cavern 'tech-infrastructure 'build 1 466.0 't3-endgame-tech)
         (when (or (not zerg-t3-on?) (> (bldg-count-equivalent total-bldg-counts 'evolution-chamber) 0))
           (add-goal-spec! 'zerg-missile-weapons-3 'tech-infrastructure 'research 1 452.0 't3-endgame-tech)
           (add-goal-spec! 'zerg-ground-armor-3 'tech-infrastructure 'research 1 450.0 't3-endgame-tech)))
       (when (> (bldg-count-equivalent ready-bldg-counts 'infestation-pit) 0)
         (add-goal-spec! 'infestor 'army-production 'train (if (>= supply-used 140) 2 1) (if zerg-t3-on? 488.0 448.0) 't3-endgame-army))
       (when (or (and zerg-pit-spire-army-ok? (or (>= workers 56) (>= effective-phase-supply 110)))
                 eff-req-aa?
                 enemy-cap-air?)
         (add-goal-spec! 'spire 'tech-infrastructure 'build 1 464.0 't3-endgame-tech)
         (when (and (> (bldg-count-equivalent ready-bldg-counts 'spire) 0)
                    (> corruptor-cap 0))
           (add-goal-spec! 'corruptor 'army-production 'train corruptor-cap 454.0 't3-endgame-army)
           (when (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)
             (add-goal-spec! 'greater-spire 'tech-infrastructure 'morph 1 468.0 't3-endgame-tech))))]
      [(Terran)
       (add-goal-spec! 'armory 'tech-infrastructure 'build 1 468.0 't3-endgame-tech)
       (add-goal-spec! 'ghost-academy 'tech-infrastructure 'build 1 462.0 't3-endgame-tech)
       (add-goal-spec! 'starport 'tech-infrastructure 'build 1 466.0 't3-endgame-tech)
       (when (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
         (add-goal-spec! 'medivac 'army-production 'train (if (>= supply-used 130) 6 4) 466.0 't3-endgame-army)
         (add-goal-spec! 'liberator 'army-production 'train desired-libs 464.0 't3-endgame-army)
         (define bo-needs-starport-reactor?
           (ormap (lambda (g)
                    (and (pro-bo-goal? g)
                         (eq? (normalize-brain-sym (pro-bo-goal-target-sym g)) 'starport-reactor)
                         (< (bldg-count-equivalent total-bldg-counts 'starport-reactor)
                            (max 1 (pro-bo-goal-target-count g)))))
                  steps-so-far))
         (unless bo-needs-starport-reactor?
           (add-goal-spec! 'starport-techlab 'tech-infrastructure 'addon 1 462.0 't3-endgame-tech))
         (add-goal-spec! 'fusion-core 'tech-infrastructure 'build 1 464.0 't3-endgame-tech))
       (when (> (bldg-count-equivalent ready-bldg-counts 'armory) 0)
         (add-goal-spec! 'thor 'army-production 'train (max desired-thors (if (>= active-bases 4) 4 2)) 462.0 't3-endgame-army)
         (add-goal-spec! 'terran-infantry-weapons-2 'tech-infrastructure 'research 1 456.0 't3-endgame-tech)
         (add-goal-spec! 'terran-infantry-armor-2 'tech-infrastructure 'research 1 454.0 't3-endgame-tech))
       (when (> (bldg-count-equivalent ready-bldg-counts 'fusion-core) 0)
         (add-goal-spec! 'advanced-ballistics 'tech-infrastructure 'research 1 458.0 't3-endgame-tech)
         (when (>= active-bases 4)
           (add-goal-spec! 'weapon-refit 'tech-infrastructure 'research 1 456.0 't3-endgame-tech)
           (add-goal-spec! 'battlecruiser 'army-production 'train (if (>= supply-used 150) 5 3) 468.0 't3-endgame-army)))]
      [else ;; Protoss
       (add-goal-spec! 'robotics-facility 'tech-infrastructure 'build 1 468.0 't3-endgame-tech)
       (add-goal-spec! 'robotics-bay 'tech-infrastructure 'build 1 468.0 't3-endgame-tech)
       (add-goal-spec! 'twilight-council 'tech-infrastructure 'build 1 468.0 't3-endgame-tech)
       (add-goal-spec! 'templar-archive 'tech-infrastructure 'build 1 466.0 't3-endgame-tech)
       (when (> (bldg-count-equivalent ready-bldg-counts 'robotics-bay) 0)
         (when (>= (unit-count-equivalent unit-counts 'colossus) 1)
           (add-goal-spec! 'extended-thermal-lance 'tech-infrastructure 'research 1 466.0 't3-endgame-tech))
         (add-goal-spec! 'colossus 'army-production 'train (if (>= supply-used 140) 4 3) 468.0 't3-endgame-army)
         (add-goal-spec! 'disruptor 'army-production 'train (if (>= supply-used 135) 2 1) 456.0 't3-endgame-army))
       (when (> (bldg-count-equivalent ready-bldg-counts 'templar-archive) 0)
         (add-goal-spec! 'psi-storm 'tech-infrastructure 'research 1 468.0 't3-endgame-tech)
         (add-goal-spec! 'high-templar 'army-production 'train 4 464.0 't3-endgame-army)
         (when (>= (unit-count-equivalent unit-counts 'high-templar) 2)
           (add-goal-spec! 'archon 'army-production 'morph (if (>= supply-used 140) 3 2) 467.0 't3-endgame-army)))
       (when (and (or enemy-cap-air? (>= active-bases 4) (>= workers 60) (>= effective-phase-supply 120))
                  (or enemy-cap-air?
                      (not (and (<= active-bases 2)
                                (not eff-req-aa?)
                                (not eff-req-det?)
                                (> (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0)
                                (> (bldg-count-equivalent total-bldg-counts 'twilight-council) 0)))))
         (add-goal-spec! 'stargate 'tech-infrastructure 'build 1 460.0 't3-endgame-tech)
         (add-goal-spec! 'fleet-beacon 'tech-infrastructure 'build 1 464.0 't3-endgame-tech)
         (when (> (bldg-count-equivalent ready-bldg-counts 'fleet-beacon) 0)
           (add-goal-spec! 'tempest 'army-production 'train (if (>= active-bases 4) 3 2) 464.0 't3-endgame-army)
           (when (>= active-bases 4)
             (add-goal-spec! 'carrier 'army-production 'train (if (>= supply-used 150) 5 3) 468.0 't3-endgame-army))))]))

  (when (pvt-immortal-robo-bay-due? race enemy-race effective-phase-supply
                                    ready-bldg-counts total-bldg-counts unit-counts)
    (add-goal-spec! 'robotics-bay 'tech-infrastructure 'build 1 565.0 'pvt-immortal-robo-bay))

  ;; Track 6B: Closed-Loop 4-Pillar Post-BO & Mirror-Brain Strategic Goals Integration
  (define sg-attrs (hash-ref post-bo-goals 'enemy-comp-attrs (hasheq)))
  (define sg-enemy-sup (exact->inexact (hash-ref sg-attrs 'total-supply 0.0)))
  (define sg-mirror-pre (hash-ref post-bo-goals 'mirror-preemptive-unit #f))
  (define sg-counter-inject-active?
    (or post-bo-deviated?
        (> sg-enemy-sup 0.0)
        (>= active-bases 2)
        (>= workers 24)
        (and (symbol? sg-mirror-pre) (>= workers 16))))

  ;; Pillar 1: Base depletion replacement, Mirror min bases, and >=1000M macro injection
  (define sg-expand-sym (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
  (when (and (> sg-desired-bases plan-total-townhalls)
             (depletion-or-mirror-expand-due?
              race active-bases workers ws-depleting-bases
              sg-mirror-min-bases under-attack? army-supply minerals))
    (add-goal-spec! sg-expand-sym 'economy-expansion 'expand sg-desired-bases
                    (if (> ws-depleting-bases 0) 476.0 468.0)
                    'post-bo-expansion))
  (when (and sg-high-bank-inject?
             (>= workers 20)
             (not under-attack?))
    (for ([st (in-list sg-macro-inject-structs)])
      (define nd (lookup-sc2-tech-node st))
      (when (and nd (eq? (sc2-tech-node-race nd) race))
        (define st-kind (sc2-tech-node-kind nd))
        (define cur-st (bldg-count-equivalent total-bldg-counts st))
        (define cap-st
          (case st
            [(hatchery nexus command-center) 6]
            [(gateway barracks) 8]
            [else 3]))
        (when (< cur-st cap-st)
          (add-goal-spec! st
                          (if (eq? st-kind 'expand) 'economy-expansion 'tech-infrastructure)
                          st-kind
                          (add1 cur-st)
                          (if (eq? st-kind 'expand) 470.0 462.0)
                          'high-bank-macro-inject)))))

  ;; Pillar 2: Dual upgrade bays + continuous +1/+2/+3 upgrade escalation
  (when (and sg-upg-escalation?
             (not crisis-defer?)
             (symbol? sg-desired-upg-bay-sym)
             (not (and zerg-t3-on? (zerg-t3-obsolete-unbuilt? sg-desired-upg-bay-sym total-bldg-counts)))
             (< (bldg-count-equivalent total-bldg-counts sg-desired-upg-bay-sym) sg-desired-upg-bays)
             (or (= (bldg-count-equivalent total-bldg-counts sg-desired-upg-bay-sym) 0)
                 (not live-slots?)
                 (>= army-supply 12)
                 (>= active-bases 3)
                 (>= minerals 300)))
    (add-goal-spec! sg-desired-upg-bay-sym 'tech-infrastructure 'build sg-desired-upg-bays
                    (if (= (bldg-count-equivalent total-bldg-counts sg-desired-upg-bay-sym) 0) 463.0 459.0)
                    'post-bo-upgrade-escalation))
  (when (and sg-counter-inject-active? (not crisis-defer?))
    (let loop ([rest sg-rec-upgs] [emitted 0])
      (when (and (pair? rest) (< emitted 3))
        (define usym (car rest))
        (define und (lookup-sc2-tech-node usym))
        (cond
          [(and und
                (eq? (sc2-tech-node-race und) race)
                (upgrade-allowed-by-unit-and-order-gates?
                 race (normalize-brain-sym usym) frame workers
                 ready-bldg-counts total-bldg-counts unit-counts
                 researched-upgrades pending-upgrades)
                (not (and zerg-t3-on? (zerg-t3-obsolete-unbuilt? usym total-bldg-counts)))
                (not (sc2-tech-already-satisfied? usym total-bldg-counts researched-upgrades pending-upgrades 1))
                (or sg-upg-escalation?
                    (sc2-tech-prereqs-ready? usym ready-bldg-counts unit-counts)))
           (add-goal-spec! usym 'tech-infrastructure 'research 1
                           (min 492.0 (+ 458.0 (* 12.0 sg-upg-mult)))
                           'post-bo-upgrade-escalation)
           (loop (cdr rest) (add1 emitted))]
          [else (loop (cdr rest) emitted)]))))

  ;; Pillar 3: Attribute-counter & 9-matchup strategic unit/tech goals
  (when sg-counter-inject-active?
    (define (post-bo-unit-target-count sym)
      (case sym
        [(baneling) (min 18 (max 8 (unit-count-equivalent unit-counts 'zergling)))]
        [(lurker) 8]
        [(ravager) 6]
        [(archon) 4]
        [(brood-lord) 4]
        [(hellbat) 8]
        [(ghost) (max 4 desired-ghosts)]
        [(raven) 2]
        [(viking-fighter) (if enemy-cap-air? 18 6)]
        [(thor) (max 2 desired-thors)]
        [(liberator) (max 3 desired-libs)]
        [(immortal) 5]
        [(colossus) 3]
        [(high-templar) 4]
        [(void-ray) 6]
        [(tempest) 6]
        [(corruptor) (max 8 corruptor-cap)]
        [(hydralisk) 10]
        [(ultralisk) 4]
        [(viper) 2]
        [(marauder) 10]
        [(siege-tank) 6]
        [(zealot) 8]
        [(stalker) 10]
        [(marine) 12]
        [(queen) (max 4 desired-queens)]
        [(roach) 10]
        [(medivac) 4]
        [(spore-crawler) (max 1 desired-spores)]
        [(barracks-techlab) (max 1 desired-rax-tl)]
        [else 1]))
    (define defer-blind-late-tech-rec?
      (and live-slots?
           (<= sg-enemy-sup 0.0)
           (<= enemy-threat-supply 0)
           (< army-supply 18)
           (< active-bases 3)
           (not enemy-cap-air?)
           (not eff-req-det?)))
    (for ([kv (in-list (sort (hash->list sg-rec-units)
                             >
                             #:key cdr))])
      (define rsym (normalize-brain-sym (car kv)))
      (define bonus (exact->inexact (cdr kv)))
      (define node (lookup-sc2-tech-node rsym))
      (when (and node
                 (eq? (sc2-tech-node-race node) race)
                 (> bonus 0.0)
                 (not (and zerg-t3-on? (zerg-t3-obsolete-unbuilt? rsym total-bldg-counts)))
                 (sg-unit-allowed? rsym)
                 (not (and defer-blind-late-tech-rec?
                           (speculative-late-tech-unit-deferred? rsym ready-bldg-counts total-bldg-counts)))
                 (or post-bo-deviated?
                     (> sg-enemy-sup 0.0)
                     (>= active-bases 2)
                     (>= workers 24)
                     (and (eq? rsym sg-mirror-pre) (>= workers 16))
                     (sc2-tech-prereqs-ready? rsym ready-bldg-counts unit-counts)))
        (define rkind (sc2-tech-node-kind node))
        (define rcat (sc2-tech-node-category node))
        (define raw-tgt (post-bo-unit-target-count rsym))
        (define tgt-cnt
          (if (and (memq rkind '(train morph)) (hash-has-key? sg-unit-caps rsym))
              (min raw-tgt (hash-ref sg-unit-caps rsym raw-tgt))
              raw-tgt))
        (when (>= tgt-cnt 1)
          (define track
            (cond
              [(eq? rkind 'expand) 'economy-expansion]
              [(eq? rcat 'intel-recon) 'intel-recon]
              [(memq rkind '(build research addon)) 'tech-infrastructure]
              [else 'army-production]))
          (define sg-w (min 494.0 (+ 455.0 (* 0.55 bonus))))
          (add-goal-spec! rsym track rkind tgt-cnt sg-w 'post-bo-strategic-goal)))))

  ;; Slice 1.5A: Opportunity-Cost Capital-Air Override & Loss-Recovery Strategic Goals
  (define slice15-defense-stabilized?
    (and (not under-attack?)
         (or (<= enemy-threat-supply 0)
             (>= army-supply (* 0.75 enemy-threat-supply)))
         (>= workers (if (eq? race 'Zerg) 12 14))))
  (when opp-cap-air-override?
    (case race
      [(Zerg)
       (when (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
         (when (< (unit-count-equivalent unit-counts 'queen) desired-queens)
           (add-goal-spec! 'queen 'army-production 'train desired-queens 502.0 'opp-cap-air-override))
         (when (< (bldg-count-equivalent total-bldg-counts 'spore-crawler) (max 1 active-bases))
           (add-goal-spec! 'spore-crawler 'intel-recon 'build (max 1 active-bases) 496.0 'opp-cap-air-override))
         (when (= (+ (bldg-count-equivalent total-bldg-counts 'spire)
                     (bldg-count-equivalent total-bldg-counts 'greater-spire))
                  0)
           (add-goal-spec! 'spire 'tech-infrastructure 'build 1 510.0 'opp-cap-air-override)))
       (when (or (> (bldg-count-equivalent ready-bldg-counts 'spire) 0)
                 (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0))
         (add-goal-spec! 'corruptor 'army-production 'train (max 12 corruptor-cap) 514.0 'opp-cap-air-override)
         (unless (sc2-tech-already-satisfied? 'zerg-flyer-armor-1 total-bldg-counts researched-upgrades pending-upgrades 1)
           (add-goal-spec! 'zerg-flyer-armor-1 'tech-infrastructure 'research 1 488.0 'opp-cap-air-override)))
       (when (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)
         (add-goal-spec! 'viper 'army-production 'train 2 490.0 'opp-cap-air-override))]
      [(Terran)
       (when (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)
         (add-goal-spec! 'starport 'tech-infrastructure 'build (if (>= active-bases 3) 3 2) 510.0 'opp-cap-air-override))
       (when (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
         (add-goal-spec! 'viking-fighter 'army-production 'train 20 514.0 'opp-cap-air-override)
         (when (> (bldg-count-equivalent ready-bldg-counts 'starport-techlab) 0)
           (add-goal-spec! 'raven 'army-production 'train 2 490.0 'opp-cap-air-override)))
       (when (and (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
                  has-ready-armory?)
         (add-goal-spec! 'thor 'army-production 'train (max 2 desired-thors) 502.0 'opp-cap-air-override))
       (when (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
         (add-goal-spec! 'cyclone 'army-production 'train 4 496.0 'opp-cap-air-override))
       (when (> (bldg-count-equivalent ready-bldg-counts 'engineering-bay) 0)
         (add-goal-spec! 'missile-turret 'intel-recon 'build (max 1 active-bases) 495.0 'opp-cap-air-override))]
      [else
       (when (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
         (add-goal-spec! 'stargate 'tech-infrastructure 'build (if (>= active-bases 2) 2 1) 504.0 'opp-cap-air-override)
         (add-goal-spec! 'stalker 'army-production 'train 14 498.0 'opp-cap-air-override)
         (add-goal-spec! 'shield-battery 'survival-supply 'build (max 1 active-bases) 492.0 'opp-cap-air-override))
       (when (> (bldg-count-equivalent ready-bldg-counts 'stargate) 0)
         (add-goal-spec! 'void-ray 'army-production 'train 8 508.0 'opp-cap-air-override)
         (add-goal-spec! 'fleet-beacon 'tech-infrastructure 'build 1 506.0 'opp-cap-air-override))
       (when (> (bldg-count-equivalent ready-bldg-counts 'fleet-beacon) 0)
         (add-goal-spec! 'tempest 'army-production 'train 10 514.0 'opp-cap-air-override))
       (when (> (bldg-count-equivalent ready-bldg-counts 'templar-archive) 0)
         (add-goal-spec! 'high-templar 'army-production 'train 4 488.0 'opp-cap-air-override)
         (when (>= (unit-count-equivalent unit-counts 'high-templar) 2)
           (add-goal-spec! 'archon 'army-production 'morph 4 494.0 'opp-cap-air-override)))
       (when (> (bldg-count-equivalent ready-bldg-counts 'forge) 0)
         (add-goal-spec! 'photon-cannon 'intel-recon 'build (max 1 active-bases) 490.0 'opp-cap-air-override))]))
  (case loss-recovery-mode
    [(worker-loss-recovery)
     (define w-sym (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
     (add-goal-spec! w-sym 'economy-expansion 'train (min 70 (* 22 active-bases)) 498.0 'worker-loss-recovery)
     (when (and (eq? race 'Zerg)
                (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
                (< (unit-count-equivalent unit-counts 'queen) desired-queens))
       (add-goal-spec! 'queen 'economy-expansion 'train desired-queens 498.0 'worker-loss-recovery))
     (when (and (eq? race 'Terran)
                (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0)
                (< (bldg-count-equivalent total-bldg-counts 'orbital-command) active-bases))
       (add-goal-spec! 'orbital-command 'economy-expansion 'morph active-bases 498.0 'worker-loss-recovery))
     (when (eq? (hash-ref loss-recovery-ht 'boost-static-defense? #f) #t)
       (case race
         [(Zerg)
          (when (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
            (add-goal-spec! 'spore-crawler 'intel-recon 'build (max 1 active-bases) 496.0 'worker-loss-recovery))]
         [(Terran)
          (when (> (bldg-count-equivalent ready-bldg-counts 'engineering-bay) 0)
            (add-goal-spec! 'missile-turret 'intel-recon 'build (max 1 active-bases) 496.0 'worker-loss-recovery))]
         [else
          (cond
            [(> (bldg-count-equivalent ready-bldg-counts 'forge) 0)
             (add-goal-spec! 'photon-cannon 'intel-recon 'build (max 1 active-bases) 496.0 'worker-loss-recovery)]
            [(> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
             (add-goal-spec! 'shield-battery 'survival-supply 'build (max 1 active-bases) 495.0 'worker-loss-recovery)])]))]
    [(base-loss-recovery)
     (define th-sym (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
     (if slice15-defense-stabilized?
         (add-goal-spec! th-sym 'economy-expansion 'expand (add1 active-bases) 492.0 'base-loss-recovery)
         (when (eq? (hash-ref loss-recovery-ht 'boost-static-defense? #f) #t)
           (for ([sd (in-list (slice15-choke-static-def-syms race))])
             (when (sc2-tech-prereqs-ready? sd ready-bldg-counts unit-counts)
               (add-goal-spec! sd 'survival-supply 'build (max 2 active-bases) 494.0 'base-loss-recovery)))))]
    [(army-wipe-counter-pivot-recovery)
     (for ([sd (in-list (slice15-choke-static-def-syms race))])
       (when (sc2-tech-prereqs-ready? sd ready-bldg-counts unit-counts)
         (add-goal-spec! sd 'survival-supply 'build (max 2 active-bases) 494.0 'army-wipe-counter-pivot)))
     (unless opp-cap-air-override?
       (define pivot-ht
         (slice15-race-counter-list-from-opp race opp-rec-counters ready-bldg-counts unit-counts))
       (for ([(csym cu) (in-hash pivot-ht)])
         (define cnd (lookup-sc2-tech-node csym))
         (when (and cnd (sc2-tech-prereqs-ready? csym ready-bldg-counts unit-counts))
           (add-goal-spec! csym 'army-production (sc2-tech-node-kind cnd) 12 cu 'army-wipe-counter-pivot))))]
    [else (void)])

  ;; Track 7: Pro Replay Unit Composition Benchmarks (`build-orders.rkt` cumulative median counts)
  (when (> frame 0)
    (define sat-econ-lagging?
      (and peaceful? (< workers (min 36 (* 16 active-bases)))))
    (for ([kv (in-list (sort (hash->list benchmark-targets)
                             string<?
                             #:key (lambda (p) (symbol->string (car p)))))])
      (define sym (normalize-brain-sym (car kv)))
      (define raw-tgt-cnt (cdr kv))
      (define tgt-cnt
        (if (hash-has-key? sg-unit-caps sym)
            (min raw-tgt-cnt (hash-ref sg-unit-caps sym raw-tgt-cnt))
            raw-tgt-cnt))
      (define node (lookup-sc2-tech-node sym))
      (when (and node
                 (eq? (sc2-tech-node-race node) race)
                 (> tgt-cnt 0)
                 (sg-unit-allowed? sym)
                 (not (memq sym '(overlord overseer overlord-transport drone scv probe)))
                 (not (and pvt-fast-kiter-threat?
                           (eq? sym 'zealot)
                           (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)))
                 (not (hash-has-key? seen-step-keys (cons (sc2-tech-node-kind node) sym)))
                 (< (unit-count-for-goal unit-counts sym) tgt-cnt)
                 (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts))
        (define def-ratio (compute-benchmark-deficit-ratio sym benchmark-targets unit-counts))
        (when (> def-ratio 0.0)
          (define bench-w
            (cond
              [crisis-defer? 466.0]
              [sat-econ-lagging? (+ 405.0 (* 10.0 def-ratio))]
              [else (+ 422.0 (* 16.0 def-ratio))]))
          (add-goal-spec! sym 'army-production (sc2-tech-node-kind node) tgt-cnt bench-w 'benchmark-unit-plan)))))

  (define all-nodes
    (for/list ([spec (in-list (reverse raw-goal-specs))])
      (match-define (list id track kind tgt-cnt w reason) spec)
      (define base-node
        (translate-goal-to-next-action id track kind tgt-cnt w reason
                                       ready-bldg-counts total-bldg-counts unit-counts
                                       researched-upgrades pending-upgrades))
      (define w-sym (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
      (define th-sym (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
      (define min-exp-workers (if (eq? race 'Zerg) 14 16))
      (cond
        ;; If an expansion goal is ready structurally but we have fewer than `min-exp-workers`
        ;; (e.g., after a worker raid/wipeout), translate the expansion goal into worker recovery!
        [(and (eq? kind 'expand)
              (eq? (plan-goal-node-status base-node) 'actionable-now)
              (< workers min-exp-workers))
         (struct-copy plan-goal-node base-node
                      [status 'needs-prereq]
                      [next-action-sym w-sym])]
        ;; If a gas-building goal exceeds `2 * active-bases` available geysers, it requires an expansion first!
        [(and (memq id '(extractor refinery assimilator))
              (not (eq? (plan-goal-node-status base-node) 'satisfied))
              (> tgt-cnt (gas-building-cap active-bases)))
         (struct-copy plan-goal-node base-node
                      [status 'needs-prereq]
                      [next-action-sym (if (< workers min-exp-workers) w-sym th-sym)])]
        ;; If Zerg has fewer than 13 workers and already has a Spawning Pool, non-survival build goals
        ;; (which sacrifice a Drone) translate into Drone production first so economy doesn't collapse!
        [(and (eq? race 'Zerg)
              (eq? kind 'build)
              (eq? (plan-goal-node-status base-node) 'actionable-now)
              (< workers 13)
              (> (bldg-count-equivalent total-bldg-counts 'spawning-pool) 0)
              (not (memq id '(spawning-pool spine-crawler spore-crawler)))
              (or (not (eq? id 'extractor))
                  (> (bldg-count-equivalent total-bldg-counts 'extractor) 0)))
         (struct-copy plan-goal-node base-node
                      [status 'needs-prereq]
                      [next-action-sym 'drone])]
        [else base-node])))

  (define active-nodes
    (filter (lambda (n)
              (and (not (eq? (plan-goal-node-status n) 'satisfied))
                   (not (crisis-deferred-sym?
                         (normalize-brain-sym (plan-goal-node-id n))
                         crisis-defer?
                         #:defer-stargate? defer-stargate?
                         #:keep-ship-weapons? ship-weap-due?
                         #:keep-spire-aa? keep-spire-aa?))
                   (not (crisis-deferred-sym?
                         (normalize-brain-sym (plan-goal-node-next-action-sym n))
                         crisis-defer?
                         #:defer-stargate? defer-stargate?
                         #:keep-ship-weapons? ship-weap-due?
                         #:keep-spire-aa? keep-spire-aa?))))
            all-nodes))

  (define in-prog-syms
    (remove-duplicates
     (for/list ([n (in-list active-nodes)]
                #:when (memq (plan-goal-node-status n) '(in-progress waiting-on-in-progress-prereq)))
       (plan-goal-node-id n))
     eq?))

  (define actionable-nodes
    (sort (filter (lambda (n) (symbol? (plan-goal-node-next-action-sym n)))
                  active-nodes)
          >
          #:key plan-goal-node-priority-weight))

  (define translated-map
    (for/fold ([ht (hasheq)]) ([n (in-list actionable-nodes)])
      (define act-sym (plan-goal-node-next-action-sym n))
      (define prev (hash-ref ht act-sym #f))
      (if (or (not prev)
              (> (plan-goal-node-priority-weight n)
                 (plan-goal-node-priority-weight prev)))
          (hash-set ht act-sym n)
          ht)))

  (hash-set! dyn-plan-ctx-slice15-table ctx-out
             (hasheq 'opp-commitment-ht opp-commitment-ht
                     'loss-recovery-ht loss-recovery-ht
                     'opp-dominant-path opp-dominant-path
                     'opp-hard-override? opp-hard-override?
                     'opp-cap-air-override? opp-cap-air-override?
                     'opp-rec-counters opp-rec-counters
                     'opp-suppressed-units opp-suppressed-units
                     'loss-recovery-mode loss-recovery-mode
                     'unlock-locked-path? slice15-unlock-locked-path?
                     'defense-stabilized? slice15-defense-stabilized?))
  (values
   (dynamic-macro-plan
    race frame effective-phase-supply
    all-nodes active-nodes actionable-nodes
    translated-map in-prog-syms)
   ctx-out))

;; Synthesizes the live 5-track `dynamic-macro-plan` from `macro-world-state` on every frame.
(define (synthesize-dynamic-macro-plan state
                                     #:enemy-unit-counts [override-enemy-unit-counts #f]
                                     #:enemy-building-counts [override-enemy-building-counts #f])
  (define rbc (macro-world-state-ready-building-counts state))
  (define tbc (macro-world-state-total-building-counts state))
  (define uc (macro-world-state-unit-counts state))
  (define-values (dp _ctx)
    (if (current-ready-bldg-cache)
        (synthesize-dynamic-macro-plan/ctx state
                                           #:enemy-unit-counts override-enemy-unit-counts
                                           #:enemy-building-counts override-enemy-building-counts)
        (parameterize ([current-ready-bldg-cache (cons rbc (make-hasheq))]
                       [current-total-bldg-cache (cons tbc (make-hasheq))]
                       [current-unit-count-cache (cons uc (make-hasheq))])
          (synthesize-dynamic-macro-plan/ctx state
                                             #:enemy-unit-counts override-enemy-unit-counts
                                             #:enemy-building-counts override-enemy-building-counts))))
  dp)

(define (macro-brain-decision-dynamic-plan decision)
  (define sched (macro-brain-decision-priority-schedule decision))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (and (hash? cat-ht) (hash-ref cat-ht 'dynamic-plan #f)))

;; Shared single-source prerequisite-unit/upgrade table for Bug 5 gated BO research goals.
(define (bug5-gated-upgrade-prereq-spec race gsym ready-bldg-counts researched-upgrades pending-upgrades)
  (case gsym
    [(grooved-spines muscular-augments) '(train hydralisk 3 hydralisk-den)]
    [(centrifical-hooks) '(morph baneling 3 baneling-nest)]
    [(blink) '(train stalker 3 gateway)]
    [(charge) '(train zealot 3 gateway)]
    [(resonating-glaives) '(train adept 3 gateway)]
    [(gravitic-drive) '(train warp-prism 1 robotics-facility)]
    [(gravitic-booster) '(train observer 1 robotics-facility)]
    [(protoss-air-weapons-1 protoss-air-armor-1)
     (and (> (bldg-count-equivalent ready-bldg-counts 'stargate) 0)
          '(train void-ray 2 stargate))]
    [(infernal-pre-igniter) '(train hellion 3 factory)]
    [(drilling-claws) '(train widow-mine 3 factory)]
    [(cyclone-lock-on-damage) '(train cyclone 2 factory)]
    [(banshee-cloak hyperflight-rotors) '(train banshee 2 starport)]
    [(combat-shield) '(research stimpack 1 barracks-techlab)]
    [(concussive-shells)
     (if (not (or (memq 'stimpack researched-upgrades)
                  (memq 'stimpack pending-upgrades)))
         '(research stimpack 1 barracks-techlab)
         '(research combat-shield 1 barracks-techlab))]
    [(burrow)
     (and (eq? race 'Zerg)
          (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
          (not (or (memq 'metabolic-boost researched-upgrades)
                   (memq 'zergling-movementspeed researched-upgrades)
                   (memq 'zerg-ling-metabolic-boost researched-upgrades)
                   (memq 'metabolic-boost pending-upgrades)
                   (memq 'glial-reconstitution researched-upgrades)
                   (memq 'glial-reconstitution pending-upgrades)))
          '(research metabolic-boost 1 spawning-pool))]
    [else #f]))

;; When a pro BO research goal has its building prerequisite ready but is blocked by Bug 5 unit/order gates,
;; pivot the active BO sub-goal to the required unit count or prerequisite upgrade so build orders never stall.
(define (resolve-gated-upgrade-prereq-goal race raw-goal frame workers
                                           ready-bldg-counts total-bldg-counts unit-counts
                                           researched-upgrades pending-upgrades)
  (and (pro-bo-goal? raw-goal)
       (eq? (pro-bo-goal-kind raw-goal) 'research)
       (let* ([gsym (normalize-brain-sym (pro-bo-goal-target-sym raw-goal))]
              [ready? (sc2-tech-prereqs-ready? gsym ready-bldg-counts unit-counts)])
         (and ready?
              (not (upgrade-allowed-by-unit-and-order-gates?
                    race gsym frame workers
                    ready-bldg-counts total-bldg-counts unit-counts
                    researched-upgrades pending-upgrades))
              (let ([sub (bug5-gated-upgrade-prereq-spec
                          race gsym ready-bldg-counts researched-upgrades pending-upgrades)])
                (and sub
                     (pro-bo-goal (first sub) (second sub) (third sub)
                                  (pro-bo-goal-min-supply raw-goal)
                                  (fourth sub)
                                  (pro-bo-goal-target-sec raw-goal))))))))

;; Convert symbol->count hashes into compact '(sym . count) pairs for situational-counter-planner.
(define (counts-ht->obs-pairs ht)
  (if (hash? ht)
      (for/list ([(k v) (in-hash ht)]
                 #:when (and (symbol? k) (real? v) (> v 0)))
        (cons k (max 1 (inexact->exact (round v)))))
      '()))

(define (build-brain-situational-weights race enemy-race frame minerals gas workers active-bases
                                         ready-bldg-counts unit-counts enemy-u-counts enemy-b-counts
                                         researched-upgrades pending-upgrades
                                         eff-req-aa? enemy-cap-air? enemy-threat-supply)
  (define ready-th-cnt
    (for/sum ([th-sym (in-list '(hatchery lair hive nexus command-center orbital-command planetary-fortress))])
      (bldg-count-equivalent ready-bldg-counts th-sym)))
  (define base-obs
    (hasheq 'race race
            'enemy-race enemy-race
            'frame frame
            'minerals minerals
            'gas gas
            'workers workers
            'ally-bases active-bases
            'natural-ready? (>= ready-th-cnt 2)
            'ally-units (counts-ht->obs-pairs unit-counts)
            'ally-buildings (counts-ht->obs-pairs ready-bldg-counts)
            'enemy-units (counts-ht->obs-pairs enemy-u-counts)
            'enemy-buildings (counts-ht->obs-pairs enemy-b-counts)
            'researched-upgrades (if (list? researched-upgrades) researched-upgrades '())
            'pending-upgrades (if (list? pending-upgrades) pending-upgrades '())))
  ;; Only fall back to heuristic enemy-air-supply when the caller flagged requires-anti-air?
  ;; without populating enemy-u-counts (legacy unit tests); preserve exact 1.25x caps when units exist.
  (define sit-obs
    (if (and (or eff-req-aa? enemy-cap-air?)
             (or (not (hash? enemy-u-counts)) (= (hash-count enemy-u-counts) 0)))
        (hash-set base-obs 'enemy-air-supply (max 8.0 (* 2.0 (max 1.0 (exact->inexact enemy-threat-supply)))))
        base-obs))
  (evaluate-situational-unit-weights sit-obs race enemy-race frame))

;; Pure Core Priority & Dynamic Plan Brain Step:
;; Synthesizes the live 5-track `dynamic-macro-plan`, translates active goals into
;; concrete ready next-actions, self-heals broken/deleted prerequisite chains,
;; checks income feasibility for mineral & gas escrows, and runs the Okasaki Braun-heap
;; scheduler with dual-resource (mineral + gas) and facility-slot reservations.
(define (step-priority-macro-brain state
                                   #:enemy-unit-counts [override-enemy-unit-counts #f]
                                   #:enemy-building-counts [override-enemy-building-counts #f])
  (define enemy-u-counts
    (or (and (hash? override-enemy-unit-counts) override-enemy-unit-counts)
        (macro-world-state-enemy-unit-counts state)))
  (define enemy-b-counts
    (or (and (hash? override-enemy-building-counts) override-enemy-building-counts)
        (macro-world-state-enemy-building-counts state)))
  (match-define (macro-world-state
                 race enemy-race frame minerals gas
                 supply-used supply-cap supply-left pending-supply
                 workers active-bases
                 gas-harvesters mineral-harvesters
                 ready-bldg-counts total-bldg-counts unit-counts
                 researched-upgrades pending-upgrades open-facility-slots
                 army-supply enemy-threat-supply
                 under-attack? requires-anti-air? requires-detection? supply-at-risk?
                 peak-supply-reached
                 base-x base-y nat-x nat-y third-x third-y)
    state)

  (parameterize ([current-ready-bldg-cache (cons ready-bldg-counts (make-hasheq))]
                 [current-total-bldg-cache (cons total-bldg-counts (make-hasheq))]
                 [current-unit-count-cache (cons unit-counts (make-hasheq))])
    (define effective-phase-supply (max supply-used peak-supply-reached))

    ;; 1. Evaluate pro supply curve targets & synthesize live Dynamic Macro Plan
    (define bo-eval
      (evaluate-build-order-next-step
       #:race race
       #:enemy-race enemy-race
       #:frame frame
       #:minerals minerals
       #:gas gas
       #:supply-used effective-phase-supply
       #:supply-left (max 0 supply-left)
       #:active-bases active-bases
       #:ready-building-counts ready-bldg-counts
       #:total-building-counts total-bldg-counts
       #:unit-counts unit-counts
       #:researched-upgrades researched-upgrades
       #:pending-upgrades pending-upgrades
       #:base-x base-x #:base-y base-y
       #:nat-x nat-x #:nat-y nat-y
       #:third-x third-x #:third-y third-y))

    (define bo-raw-goal (pro-bo-eval-result-active-goal bo-eval))
    (define target-workers (pro-bo-eval-result-target-workers bo-eval))
    (define-values (dyn-plan dp-ctx)
      (synthesize-dynamic-macro-plan/ctx state
                                         #:enemy-unit-counts enemy-u-counts
                                         #:enemy-building-counts enemy-b-counts))
    (define plan-active-nodes (dynamic-macro-plan-active-goals dyn-plan))
    (define plan-actionable-nodes (dynamic-macro-plan-actionable-goals dyn-plan))
    (define plan-next-actions-ht (dynamic-macro-plan-translated-next-actions dyn-plan))

    ;; Unpack reusable per-step context from synthesize-dynamic-macro-plan/ctx
    (define all-upgs (dyn-plan-ctx-all-upgs dp-ctx))
    (define benchmark-targets (dyn-plan-ctx-benchmark-targets dp-ctx))
    (define has-robo? (dyn-plan-ctx-has-robo? dp-ctx))
    (define has-ready-armory? (dyn-plan-ctx-has-ready-armory? dp-ctx))
    (define enemy-cap-air? (dyn-plan-ctx-enemy-cap-air? dp-ctx))
    (define enemy-cap-air-ground-aa? (dyn-plan-ctx-enemy-cap-air-ground-aa? dp-ctx))
    (define desired-thors (dyn-plan-ctx-desired-thors dp-ctx))
    (define air-fleet-cnt (dyn-plan-ctx-air-fleet-cnt dp-ctx))
    (define ship-weap-due? (dyn-plan-ctx-ship-weap-due? dp-ctx))
    (define zvp-stargate-threat? (dyn-plan-ctx-zvp-stargate-threat? dp-ctx))
    (define keep-spire-aa? (dyn-plan-ctx-keep-spire-aa? dp-ctx))
    (define aa-effective? (dyn-plan-ctx-aa-effective? dp-ctx))
    (define pvt-fast-kiter-threat? (dyn-plan-ctx-pvt-fast-kiter-threat? dp-ctx))
    (define tvp-cannon-contain? (dyn-plan-ctx-tvp-cannon-contain? dp-ctx))
    (define desired-spores (dyn-plan-ctx-desired-spores dp-ctx))
    (define has-lair-or-hive-ready? (dyn-plan-ctx-has-lair-or-hive-ready? dp-ctx))
    (define desired-overseer-cnt (dyn-plan-ctx-desired-overseers dp-ctx))
    (define desired-dropper-cnt (dyn-plan-ctx-desired-droppers dp-ctx))
    (define gas-bldg-sym (dyn-plan-ctx-gas-bldg-sym dp-ctx))
    (define total-gas-bldgs (dyn-plan-ctx-total-gas-bldgs dp-ctx))
    (define suppress-tvp-extra-rax? (dyn-plan-ctx-suppress-tvp-extra-rax? dp-ctx))
    (define crisis-defer? (dyn-plan-ctx-crisis-defer? dp-ctx))
    (define severe-crisis-static-def? (dyn-plan-ctx-severe-crisis-static-def? dp-ctx))
    (define defer-stargate? (dyn-plan-ctx-defer-stargate? dp-ctx))
    (define early-zero-army-attack? (dyn-plan-ctx-early-zero-army-attack? dp-ctx))
    (define root-combat-facility-ready? (dyn-plan-ctx-root-combat-facility-ready? dp-ctx))
    (define under-early-rush-crisis? (dyn-plan-ctx-under-early-rush-crisis? dp-ctx))
    (define race-supply-sym (dyn-plan-ctx-supply-sym dp-ctx))
    (define hard-supply-block? (dyn-plan-ctx-hard-supply-block? dp-ctx))
    (define zero-supply-provider-lockout? (dyn-plan-ctx-zero-supply-provider-lockout? dp-ctx))
    (define supply-lockout-active? (dyn-plan-ctx-supply-lockout-active? dp-ctx))
    (define total-townhalls-incl-pending (dyn-plan-ctx-total-townhalls dp-ctx))
    (define steps-so-far (dyn-plan-ctx-steps-so-far dp-ctx))
    (define due-timing-goals (dyn-plan-ctx-due-timing-goals dp-ctx))
    (define post-bo-goals (dyn-plan-ctx-post-bo-goals dp-ctx))
    (define post-bo-deviation (dyn-plan-ctx-post-bo-deviation dp-ctx))
    (define raw-mirror-signals (macro-world-state-mirror-signals state))
    (define ws-depleting-bases (macro-world-state-depleting-bases state))
    (define ws-natural-blocked? (macro-world-state-natural-blocked? state))
    (define eff-req-aa?
      (or requires-anti-air?
          (and (hash? raw-mirror-signals)
               (eq? (hash-ref raw-mirror-signals 'mirror-requires-anti-air? #f) #t))))
    (define eff-req-det?
      (or requires-detection?
          (and (hash? raw-mirror-signals)
               (eq? (hash-ref raw-mirror-signals 'mirror-requires-detection? #f) #t))))
    (define post-bo-deviated? (eq? (hash-ref post-bo-goals 'deviated? #f) #t))
    (define suppress-opening-harass? (eq? (hash-ref post-bo-goals 'suppress-opening-harass? #f) #t))
    (define sg-suppressed-units (hash-ref post-bo-goals 'suppressed-units '()))
    (define sg-unit-caps (hash-ref post-bo-goals 'unit-caps (hasheq)))
    (define sg-rec-units (hash-ref post-bo-goals 'recommended-units (hasheq)))
    (define sg-rec-upgs (hash-ref post-bo-goals 'recommended-upgrades '()))
    (define sg-desired-bases (hash-ref post-bo-goals 'desired-bases active-bases))
    (define sg-upg-escalation? (eq? (hash-ref post-bo-goals 'upgrade-escalation-active? #f) #t))
    (define sg-upg-mult (exact->inexact (hash-ref post-bo-goals 'upgrade-priority-multiplier 1.0)))
    (define sg-desired-upg-bays (hash-ref post-bo-goals 'desired-upgrade-bays 1))
    (define sg-desired-upg-bay-sym (hash-ref post-bo-goals 'desired-upgrade-bay-sym #f))
    (define sg-high-bank-inject? (eq? (hash-ref post-bo-goals 'high-bank-macro-inject? #f) #t))
    (define sg-macro-inject-structs (hash-ref post-bo-goals 'macro-inject-structures '()))
    (define sg-mirror-min-bases (hash-ref post-bo-goals 'mirror-recommended-min-bases 0))
    (define sg-enemy-sup
      (exact->inexact (hash-ref (hash-ref post-bo-goals 'enemy-comp-attrs (hasheq)) 'total-supply 0.0)))
    (define sg-mirror-pre (hash-ref post-bo-goals 'mirror-preemptive-unit #f))
    (define sg-counter-inject-active?
      (or post-bo-deviated?
          (> sg-enemy-sup 0.0)
          (>= active-bases 2)
          (>= workers 24)
          (and (symbol? sg-mirror-pre) (>= workers 16))))
    (define (sg-unit-allowed? raw-sym [cur-cnt #f] [add-sched 0])
      (define nsym (normalize-brain-sym raw-sym))
      (and (not (memq nsym sg-suppressed-units))
           (or (not (hash-has-key? sg-unit-caps nsym))
               (let ([cap (hash-ref sg-unit-caps nsym 999)]
                     [have (+ (or cur-cnt (unit-count-equivalent unit-counts nsym)) add-sched)])
                 (< have cap)))))

    (define sit-weights
      (build-brain-situational-weights
       race enemy-race frame minerals gas workers active-bases
       ready-bldg-counts unit-counts enemy-u-counts enemy-b-counts
       researched-upgrades pending-upgrades
       eff-req-aa? enemy-cap-air? enemy-threat-supply))
    (define sit-recommended-units (hash-ref sit-weights 'recommended-units '()))
    (define sit-suppressed-units (hash-ref sit-weights 'suppressed-units '()))
    (define sit-unit-caps (hash-ref sit-weights 'unit-caps (hasheq)))
    (define sit-penalties (hash-ref sit-weights 'penalties (hasheq)))

    ;; 2. Self-Healing Tech Prerequisite DAG Check & O(1) due-goal tables:
    (define all-due-goals
      (append (if bo-raw-goal (list bo-raw-goal) '())
              steps-so-far
              due-timing-goals))
    (define timing-sec-ht (make-hasheq))
    (define goal-target-count-ht (make-hasheq))
    (define bo-unit-target-ht (make-hasheq))
    (for ([g (in-list all-due-goals)]
          #:when (pro-bo-goal? g))
      (define key (normalize-brain-sym (pro-bo-goal-target-sym g)))
      (define tsec (pro-bo-goal-target-sec g))
      (when (and (> (exact->inexact tsec) 0.0)
                 (not (hash-has-key? timing-sec-ht key)))
        (hash-set! timing-sec-ht key tsec))
      (hash-set! goal-target-count-ht key
                 (max (hash-ref goal-target-count-ht key 1)
                      (pro-bo-goal-target-count g)))
      (when (eq? (pro-bo-goal-kind g) 'train)
        (hash-set! bo-unit-target-ht key
                   (max (hash-ref bo-unit-target-ht key 0)
                        (pro-bo-goal-target-count g)))))
    (for ([n (in-list plan-active-nodes)])
      (define key (normalize-brain-sym (plan-goal-node-id n)))
      (hash-set! goal-target-count-ht key
                 (max (hash-ref goal-target-count-ht key 1)
                      (plan-goal-node-target-count n)))
      (define next-act (plan-goal-node-next-action-sym n))
      (define defer-extra-addon-parent?
        (and (hash? open-facility-slots)
             (< minerals 250)
             (or (< army-supply 10)
                 (and (< army-supply 16)
                      (>= (+ (hash-ref open-facility-slots 'barracks 0)
                             (hash-ref open-facility-slots 'gateway 0)
                             (hash-ref open-facility-slots 'warp-gate 0))
                          2)))))
      (when (and (eq? (plan-goal-node-status n) 'needs-prereq)
                 (symbol? next-act)
                 (memq next-act '(barracks factory starport))
                 (> (bldg-count-equivalent total-bldg-counts next-act) 0)
                 (not defer-extra-addon-parent?))
        ;; Allow building an additional parent facility when existing parents' add-on slots are full,
        ;; unless primary army production is starved under a tight mineral bank (< 250M).
        (define needed-facs (add1 (bldg-count-equivalent total-bldg-counts next-act)))
        (hash-set! goal-target-count-ht next-act
                   (max (hash-ref goal-target-count-ht next-act 1) needed-facs))))
    (define (lookup-timing-sec-for-sym sym)
      (hash-ref timing-sec-ht (normalize-brain-sym sym) 0.0))
    (define (goal-target-count-for sym)
      (hash-ref goal-target-count-ht (normalize-brain-sym sym) 1))

    (define has-armory? (> (bldg-count-equivalent total-bldg-counts 'armory) 0))
    (define tvp-worker-recovery?
      (worker-recovery-after-cannon-or-contain?
       race enemy-race workers active-bases army-supply under-attack?
       enemy-threat-supply enemy-u-counts enemy-b-counts))
    (define early-aggro? (or under-attack? (> enemy-threat-supply 0) under-early-rush-crisis?))
    (define desired-queens
      (if (and (eq? race 'Zerg) enemy-cap-air?)
          SC2-MAX-QUEENS-CAP
          (desired-zerg-queen-count active-bases zvp-stargate-threat? early-aggro?)))
    (define ready-gas-bldgs (bldg-count-equivalent ready-bldg-counts gas-bldg-sym))
    (define zerg-step-t3-on? (zerg-hive-t3-online? race ready-bldg-counts))
    (define repaired-prereqs
      (let ([plan-repaired (dyn-plan-ctx-repaired-prereqs dp-ctx)])
        (if (or (not bo-raw-goal)
                (memq bo-raw-goal steps-so-far)
                (memq bo-raw-goal due-timing-goals))
            plan-repaired
            (let ([bo-repaired
                   (filter (lambda (sym)
                             (and (not (and zerg-step-t3-on?
                                            (zerg-t3-obsolete-unbuilt? sym total-bldg-counts)))
                                  (not (crisis-deferred-sym? (normalize-brain-sym sym) crisis-defer?
                                                             #:defer-stargate? defer-stargate?
                                                             #:keep-ship-weapons? ship-weap-due?
                                                             #:keep-spire-aa? keep-spire-aa?))))
                           (find-all-broken-tech-dependencies
                            race ready-bldg-counts total-bldg-counts
                            #:active-goals (if (and zerg-step-t3-on?
                                                    (zerg-t3-obsolete-unbuilt?
                                                     (pro-bo-goal-target-sym bo-raw-goal)
                                                     total-bldg-counts))
                                               '()
                                               (list bo-raw-goal))))])
              (if (or (null? bo-repaired)
                      (andmap (lambda (s)
                                (ormap (lambda (r) (same-brain-sym? s r)) plan-repaired))
                              bo-repaired))
                  plan-repaired
                  (filter (lambda (sym)
                            (and (not (and zerg-step-t3-on?
                                           (zerg-t3-obsolete-unbuilt? sym total-bldg-counts)))
                                 (not (crisis-deferred-sym? (normalize-brain-sym sym) crisis-defer?
                                                            #:defer-stargate? defer-stargate?
                                                            #:keep-ship-weapons? ship-weap-due?
                                                            #:keep-spire-aa? keep-spire-aa?))))
                          (find-all-broken-tech-dependencies
                           race ready-bldg-counts total-bldg-counts
                           #:active-goals (if zerg-step-t3-on?
                                              (filter (lambda (g)
                                                        (not (zerg-t3-obsolete-unbuilt?
                                                              (pro-bo-goal-target-sym g)
                                                              total-bldg-counts)))
                                                      (cons bo-raw-goal steps-so-far))
                                              (cons bo-raw-goal steps-so-far)))))))))
    (define repaired-prereq-set (make-hasheq))
    (for ([r (in-list repaired-prereqs)]
          #:when (symbol? r))
      (hash-set! repaired-prereq-set (normalize-brain-sym r) #t))
    (define (is-repaired-prereq? sym)
      (and (symbol? sym)
           (hash-ref repaired-prereq-set (normalize-brain-sym sym) #f)))

    ;; Derive top actionable goal from the Dynamic Plan (translating any blocked goal
    ;; directly into its ready `next-action-sym` instead of stalling on a static queue head!)
    (define emergency-army-before-workers?
      (and (not tvp-worker-recovery?)
           (or under-attack? (> enemy-threat-supply 0))
           (< army-supply (if (and (< frame 3000) (>= enemy-threat-supply 4))
                              (max 8 (+ enemy-threat-supply 4))
                              4))
           root-combat-facility-ready?
           (>= workers 1)))
  (define top-plan-node
    (and (pair? plan-actionable-nodes)
         (first plan-actionable-nodes)))
  (define (bo-fallback-goal-allowed? g)
    (and (pro-bo-goal? g)
         (let ([gsym (pro-bo-goal-target-sym g)])
           (and (not (crisis-deferred-sym? (normalize-brain-sym gsym) crisis-defer?
                                           #:defer-stargate? defer-stargate?
                                           #:keep-ship-weapons? ship-weap-due?
                                           #:keep-spire-aa? keep-spire-aa?))
                (not (and supply-lockout-active?
                          (memq gsym '(extractor refinery assimilator
                                       hatchery nexus command-center))))
                (or (not (memq gsym '(extractor refinery assimilator)))
                    (let ([cur-gb (bldg-count-equivalent total-bldg-counts gsym)])
                      (and (gas-building-cap-ok? cur-gb active-bases)
                           (>= workers (min-workers-for-next-gas-bldg cur-gb))
                           (not early-zero-army-attack?))))
                (not (and (eq? gsym 'queen)
                          (or under-attack? (> enemy-threat-supply 2))
                          (< army-supply 4)))))))
  (define (plan-node->pro-bo-goal pnode)
    (define node (and pnode (lookup-sc2-tech-node (plan-goal-node-next-action-sym pnode))))
    (and node
         (let* ([next-sym (sc2-tech-node-id node)]
                [p-list (sc2-tech-node-prereqs node)])
           (pro-bo-goal (if (eq? (sc2-tech-node-kind node) 'addon) 'build (sc2-tech-node-kind node))
                        next-sym
                        (max 1 (safe-exact-int (plan-goal-node-target-count pnode) 1))
                        0
                        (and (pair? p-list) (first p-list))
                        (lookup-timing-sec-for-sym next-sym)))))
  (define raw-effective-bo-goal
    (or (plan-node->pro-bo-goal top-plan-node)
        (and (bo-fallback-goal-allowed? bo-raw-goal) bo-raw-goal)))
  (define timed-bo-display-goal
    (and top-plan-node
         (eq? (plan-goal-node-reason top-plan-node) 'worker-loss-recovery)
         (or (and (pair? plan-actionable-nodes)
                  (let ([n (findf (lambda (cand-n)
                                    (and (not (eq? (plan-goal-node-reason cand-n) 'worker-loss-recovery))
                                         (> (lookup-timing-sec-for-sym (plan-goal-node-next-action-sym cand-n)) 0.0)
                                         (lookup-sc2-tech-node (plan-goal-node-next-action-sym cand-n))))
                                  plan-actionable-nodes)])
                    (plan-node->pro-bo-goal n)))
             (and (pro-bo-goal? bo-raw-goal)
                  (> (pro-bo-goal-target-sec bo-raw-goal) 0.0)
                  bo-raw-goal))))
  (define effective-bo-goal
    (cond
      [(and (pro-bo-goal? raw-effective-bo-goal)
            (eq? (pro-bo-goal-kind raw-effective-bo-goal) 'train))
       (let* ([g-sym (pro-bo-goal-target-sym raw-effective-bo-goal)]
              [g-node (lookup-sc2-tech-node g-sym)]
              [prereq-sym (or (pro-bo-goal-prereq-ready-sym raw-effective-bo-goal)
                              (and g-node
                                   (pair? (sc2-tech-node-prereqs g-node))
                                   (first (sc2-tech-node-prereqs g-node))))])
         (if (and prereq-sym
                  (= (bldg-count-equivalent total-bldg-counts prereq-sym) 0))
             (let* ([p-node (lookup-sc2-tech-node prereq-sym)]
                    [p-prereqs (and p-node (sc2-tech-node-prereqs p-node))])
               (pro-bo-goal (if (and p-node (eq? (sc2-tech-node-kind p-node) 'morph)) 'morph 'build)
                            prereq-sym
                            1
                            (pro-bo-goal-min-supply raw-effective-bo-goal)
                            (and (pair? p-prereqs) (first p-prereqs))
                            (pro-bo-goal-target-sec raw-effective-bo-goal)))
             raw-effective-bo-goal))]
      [(resolve-gated-upgrade-prereq-goal
        race raw-effective-bo-goal frame workers
        ready-bldg-counts total-bldg-counts unit-counts
        researched-upgrades pending-upgrades)
       => values]
      [else raw-effective-bo-goal]))

  (define bo-goal-sym
    (and (pro-bo-goal? effective-bo-goal)
         (pro-bo-goal-target-sym effective-bo-goal)))

  ;; 3. Income Feasibility & Anti-Starvation Diagnostics:
  (define has-mineral-income?
    (and (> workers 0)
         (if (exact-integer? mineral-harvesters)
             (> mineral-harvesters 0)
             #t)))
  (define has-gas-income?
    (if (exact-integer? gas-harvesters)
        (and (> gas-harvesters 0) (> ready-gas-bldgs 0))
        (and (> workers 3) (> ready-gas-bldgs 0))))

  ;; Facility count for production scaling (needed early to size dynamic supply lead-time buffer)
  (define prod-fac-count
    (case race
      [(Zerg) (+ (bldg-count-equivalent total-bldg-counts 'hatchery)
                 (bldg-count-equivalent total-bldg-counts 'roach-warren))]
      [(Terran) (+ (bldg-count-equivalent total-bldg-counts 'barracks)
                   (bldg-count-equivalent total-bldg-counts 'factory)
                   (bldg-count-equivalent total-bldg-counts 'starport))]
      [else (+ (bldg-count-equivalent total-bldg-counts 'gateway)
               (bldg-count-equivalent total-bldg-counts 'robotics-facility)
               (bldg-count-equivalent total-bldg-counts 'stargate))]))
  (define max-fac-count (max 2 (* 3 active-bases)))

  ;; Supply threshold: continuously coupled to active bases, production facilities & worker saturation
  ;; so multi-Rax/Gate/Hatch cycles trigger Overlord/Depot/Pylon lead time BEFORE hitting 100% cap.
  ;; Adds +2 supply lead headroom between 30 and 90 supply used while leaving < 30 openings unchanged.
  (define supply-buffer
    (+ (if (hash? open-facility-slots)
           (compute-production-coupled-supply-buffer
            #:active-bases active-bases
            #:production-facilities prod-fac-count
            #:workers workers
            #:target-workers target-workers
            #:min-buffer 1
            #:max-buffer 16)
           (compute-production-coupled-supply-buffer
            #:active-bases active-bases
            #:production-facilities (min 2 prod-fac-count)
            #:workers workers
            #:target-workers target-workers
            #:min-buffer 1
            #:max-buffer 6))
       (if (and (>= supply-used 30) (<= supply-used 90)) 2 0)))

  (define eff-desired-bases
    (max sg-desired-bases
         (cond [(>= effective-phase-supply 108) 5]
               [(>= effective-phase-supply 64) 4]
               [(>= effective-phase-supply 40) 3]
               [else 2])))

  (define base-metrics
    (compute-state-pressure-metrics
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left (max 0 supply-left)
     #:supply-cap (max 1 supply-cap)
     #:pending-supply pending-supply
     #:workers workers
     #:target-workers target-workers
     #:active-bases active-bases
     #:desired-bases eff-desired-bases
     #:production-facilities (max 1 prod-fac-count)
     #:max-facilities max-fac-count
     #:army-supply army-supply
     #:enemy-threat-supply enemy-threat-supply
     #:under-attack? under-attack?
     #:requires-anti-air? eff-req-aa?
     #:requires-detection? eff-req-det?
     #:supply-at-risk? (or supply-at-risk? (< supply-left 0) supply-lockout-active?)
     #:supply-buffer supply-buffer))

  (define metrics
    (enrich-priority-metrics
     base-metrics
     #:race race
     #:enemy-race enemy-race
     #:minerals minerals
     #:active-bases active-bases
     #:under-attack? under-attack?
     #:requires-anti-air? eff-req-aa?
     #:army-supply army-supply
     #:enemy-threat-supply enemy-threat-supply
     #:workers workers
     #:has-barracks-techlab? (> (bldg-count-equivalent ready-bldg-counts 'barracks-techlab) 0)
     #:has-twilight-or-charge? (or (> (bldg-count-equivalent ready-bldg-counts 'twilight-council) 0)
                                   (memq 'charge all-upgs))
     #:has-hydralisk-den? (> (bldg-count-equivalent ready-bldg-counts 'hydralisk-den) 0)
     #:has-robo? has-robo?
     #:has-armory? has-armory?
     #:crisis-defense-defer? crisis-defer?
     #:enemy-capital-air-ground-aa? enemy-cap-air-ground-aa?
     #:terran-ship-weapons-due? ship-weap-due?
     #:stalker-count (unit-count-equivalent unit-counts 'stalker)
     #:roach-count (unit-count-equivalent unit-counts 'roach)
     #:enemy-unit-counts enemy-u-counts
     #:enemy-building-counts enemy-b-counts
     #:benchmark-targets benchmark-targets
     #:unit-counts unit-counts
     #:bo-goal-sym bo-goal-sym
     #:strategic-goals post-bo-goals))

  ;; Check if a producer facility/research slot is open
  (define (slot-available? slot-sym)
    (cond
      [(eq? slot-sym 'worker) (> workers 0)]
      [(memq slot-sym UNIT-MORPH-SOURCE-SLOTS)
       (unit-morph-slot-ready? slot-sym unit-counts)]
      [(not (hash? open-facility-slots)) #t]
      [else (> (hash-ref open-facility-slots slot-sym 0) 0)]))

  (define prereqs-ready-cache (make-hasheq))
  (define (step-prereqs-ready? sym)
    (if (symbol? sym)
        (hash-ref! prereqs-ready-cache sym
                   (lambda () (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts)))
        (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts)))

  (define already-satisfied-cache (make-hasheq))
  (define (step-already-satisfied? sym)
    (if (symbol? sym)
        (hash-ref! already-satisfied-cache sym
                   (lambda ()
                     (sc2-tech-already-satisfied? sym total-bldg-counts researched-upgrades pending-upgrades
                                                   (goal-target-count-for sym))))
        (sc2-tech-already-satisfied? sym total-bldg-counts researched-upgrades pending-upgrades
                                     (goal-target-count-for sym))))

  (define feasible-cache (make-hasheq))
  (define (cand-feasible-now? sym)
    (define (compute)
      (define node (lookup-sc2-tech-node sym))
      (cond
        [(not node) #t]
        [(step-already-satisfied? sym) #f]
        [(not (step-prereqs-ready? sym)) #f]
        [else (slot-available? (sc2-tech-node-producer-slot node))]))
    (if (symbol? sym)
        (hash-ref! feasible-cache sym compute)
        (compute)))

  (define can-escrow-cache (make-hasheq))
  (define eff-th-total-cnt
    (for/sum ([s (in-list '(hatchery lair hive nexus command-center orbital-command planetary-fortress))])
      (hash-ref total-bldg-counts s 0)))
  (define escrow-state-entry
    (macro-escrow-sync-entry! race enemy-race frame minerals eff-th-total-cnt))
  (define (cand-can-escrow? sym)
    (define (compute)
      (define node (lookup-sc2-tech-node sym))
      (define nsym (normalize-brain-sym sym))
      (define supply-sym? (memq nsym '(overlord pylon supply-depot)))
      (define nat-exp-sym? (and natural-exp-window? (eq? nsym race-expand-sym)))
      (and node
           (or supply-sym? (not supply-preempt-now?))
           (or supply-sym? (not (macro-escrow-in-backoff? escrow-state-entry frame nsym)))
           (or (not (eq? (sc2-tech-node-kind node) 'research))
               (upgrade-allowed-by-unit-and-order-gates?
                race nsym frame workers ready-bldg-counts total-bldg-counts
                unit-counts researched-upgrades pending-upgrades))
           (or (>= workers 6)
               (and emergency-army-before-workers?
                    (eq? (sc2-tech-node-category node) 'combat-unit)))
           (or (>= minerals (sc2-tech-node-min-cost node)) has-mineral-income?)
           (or (>= gas (sc2-tech-node-gas-cost node)) has-gas-income?)
           (or supply-sym?
               nat-exp-sym?
               (can-fund-within-frames?
                minerals gas
                (sc2-tech-node-min-cost node) (sc2-tech-node-gas-cost node)
                mineral-harvesters gas-harvesters
                workers ready-bldg-counts race #:frames 120))
           (not (step-already-satisfied? sym))
           (step-prereqs-ready? sym)))
    (if (symbol? sym)
        (hash-ref! can-escrow-cache sym compute)
        (compute)))

  (define terran-need-ghost? (terran-enemy-needs-ghost? enemy-u-counts))
  (define terran-need-lib? (terran-enemy-needs-liberator? enemy-u-counts))
  (define desired-rax-tl
    (terran-desired-barracks-techlabs race enemy-race (bldg-count-equivalent total-bldg-counts 'barracks)))
  (define desired-factories
    (terran-desired-factories race enemy-race active-bases effective-phase-supply))
  (define desired-ghosts
    (terran-desired-ghost-cap active-bases supply-used enemy-race enemy-u-counts))
  (define desired-libs
    (terran-desired-liberator-cap active-bases enemy-u-counts))
  (define zerg-army-step-ok?
    (zerg-worker-army-floor-ok? race enemy-race workers army-supply))

  ;; 4. Generate base candidates from `econ-ledger` + inject all translated next-actions
  ;;    from `dyn-plan`, any missing repaired prerequisites, and emergency recovery candidates.
  (define raw-cands
    (generate-race-priority-candidates
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left (max 0 supply-left)
     #:supply-cap (max 1 supply-cap)
     #:pending-supply pending-supply
     #:workers workers
     #:target-workers (min 70 target-workers)
     #:active-bases active-bases
     #:desired-bases eff-desired-bases
     #:production-facilities (max 1 prod-fac-count)
     #:max-facilities max-fac-count
     #:army-supply army-supply
     #:enemy-threat-supply enemy-threat-supply
     #:under-attack? under-attack?
     #:requires-anti-air? eff-req-aa?
     #:requires-detection? eff-req-det?
     #:supply-at-risk? (or supply-at-risk? (< supply-left 0) supply-lockout-active?)
     #:supply-buffer supply-buffer
     #:ally-buildings '()
     #:ready-buildings '()
     #:ally-units '()
     #:researched-upgrades all-upgs
     #:open-prod-slots open-facility-slots
     #:bo-active-goal effective-bo-goal
     #:enemy-race enemy-race
     #:enemy-unit-counts enemy-u-counts
     #:enemy-building-counts enemy-b-counts
     #:benchmark-targets benchmark-targets
     #:unit-counts unit-counts
     #:total-building-counts total-bldg-counts
     #:ready-building-counts ready-bldg-counts
     #:base-x base-x #:base-y base-y
     #:nat-x nat-x #:nat-y nat-y
     #:third-x third-x #:third-y third-y
     #:depleting-bases ws-depleting-bases
     #:natural-blocked? ws-natural-blocked?
     #:mirror-signals raw-mirror-signals
     #:strategic-goals post-bo-goals
     #:post-bo-deviation post-bo-deviation))

  ;; Slice 1.5A runtime metadata unpacked from `synthesize-dynamic-macro-plan/ctx`
  (define slice15-meta (hash-ref dyn-plan-ctx-slice15-table dp-ctx (hasheq)))
  (define opp-commitment-ht (hash-ref slice15-meta 'opp-commitment-ht (hasheq)))
  (define loss-recovery-ht (hash-ref slice15-meta 'loss-recovery-ht (hasheq)))
  (define opp-cap-air-override? (eq? (hash-ref slice15-meta 'opp-cap-air-override? #f) #t))
  (define opp-rec-counters (map normalize-brain-sym (hash-ref slice15-meta 'opp-rec-counters '())))
  (define opp-suppressed-units (map normalize-brain-sym (hash-ref slice15-meta 'opp-suppressed-units '())))
  (define loss-recovery-mode (hash-ref slice15-meta 'loss-recovery-mode 'none))
  (define lr-unlock-locked-path? (eq? (hash-ref slice15-meta 'unlock-locked-path? #f) #t))
  (define lr-preempt-greedy-tech? (eq? (hash-ref loss-recovery-ht 'preempt-greedy-tech? #f) #t))
  (define lr-boost-workers? (eq? (hash-ref loss-recovery-ht 'boost-workers? #f) #t))
  (define lr-boost-expand? (eq? (hash-ref loss-recovery-ht 'boost-expand? #f) #t))
  (define lr-boost-static-def? (eq? (hash-ref loss-recovery-ht 'boost-static-defense? #f) #t))
  (define lr-suppress-failing-comp? (eq? (hash-ref loss-recovery-ht 'suppress-failing-comp? #f) #t))
  (define slice15-defense-stabilized?
    (eq? (hash-ref slice15-meta 'defense-stabilized? #t) #t))
  (define slice15-base-loss-expand-now?
    (and (eq? loss-recovery-mode 'base-loss-recovery)
         lr-boost-expand?
         slice15-defense-stabilized?))
  (define cap-air-boost-table
    (if opp-cap-air-override? (slice15-cap-air-counter-utility-table race) (hasheq)))
  (define wipe-counter-boost-table
    (if (and (eq? loss-recovery-mode 'army-wipe-counter-pivot-recovery)
             (not opp-cap-air-override?))
        (slice15-race-counter-list-from-opp race opp-rec-counters ready-bldg-counts unit-counts)
        (hasheq)))
  (define wipe-suppressed-units
    (if (eq? loss-recovery-mode 'army-wipe-counter-pivot-recovery)
        (let* ([has-ready-counter?
                (for/or ([k (in-hash-keys wipe-counter-boost-table)])
                  (sc2-tech-prereqs-ready? k ready-bldg-counts unit-counts))]
               [ally-prev-failing
                (if has-ready-counter?
                    (for/list ([(u cnt) (in-hash unit-counts)]
                               #:when (and (real? cnt) (> cnt 0)
                                           (let ([nu (normalize-brain-sym u)]
                                                 [nd (lookup-sc2-tech-node (normalize-brain-sym u))])
                                             (and nd
                                                  (eq? (sc2-tech-node-category nd) 'combat-unit)
                                                  (not (memq nu opp-rec-counters))
                                                  (not (hash-has-key? wipe-counter-boost-table nu))))))
                      (normalize-brain-sym u))
                    '())])
          (remove-duplicates (append opp-suppressed-units ally-prev-failing) eq?))
        '()))
  (define slice15-all-suppressed-units
    (remove-duplicates
     (append (if opp-cap-air-override? *slice15-cap-air-suppressed-syms* '())
             wipe-suppressed-units)
     eq?))
  (define slice15-mineral-def-syms (slice15-mineral-line-static-def-syms race))
  (define slice15-choke-def-syms (slice15-choke-static-def-syms race))
  (define slice15-worker-sym (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))

  (define max-crisis-pending-supply
    (cond
      [(< supply-left 0) 3]
      [(and (hash? open-facility-slots) (or (>= supply-cap 66) (>= prod-fac-count 5))) 3]
      [else 2]))
  (define supply-margin (compute-supply-preemption-margin supply-cap))
  (define supply-preempt-now?
    (supply-preemption-needed? supply-used supply-cap pending-supply))
  (define supply-crisis?
    (or supply-lockout-active?
        supply-preempt-now?
        (and (< supply-cap 200)
             (< (+ supply-cap (* 8 pending-supply)) 200)
             (< pending-supply max-crisis-pending-supply)
             (or (and (= pending-supply 0) (<= supply-left supply-buffer))
                 (<= (+ supply-left (* 8 pending-supply)) (max 0 (quotient supply-buffer 2)))
                 (and (>= active-bases 3)
                      (>= minerals 400)
                      (<= (+ supply-left (* 8 pending-supply)) (max 8 supply-buffer)))))))

  (define race-expand-sym
    (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
  (define natural-exp-window?
    (and (<= total-townhalls-incl-pending 1)
         (natural-expansion-window-active?
          race frame workers (max eff-th-total-cnt total-townhalls-incl-pending)
          ready-bldg-counts total-bldg-counts
          under-attack? enemy-threat-supply
          under-early-rush-crisis?)))
  (define overdue-1base-expand?
    (or natural-exp-window?
        (and (>= minerals 400)
             (= active-bases 1)
             (<= total-townhalls-incl-pending 1)
             (>= frame 2688)
             (not under-attack?)
             (< enemy-threat-supply 6.0)
             (>= workers 12))))

  (define emergency-rush-syms
    (if under-early-rush-crisis?
        (append
         (if (not root-combat-facility-ready?)
             (case race
               [(Zerg) '(spawning-pool)]
               [(Terran) (if (> (bldg-count-equivalent total-bldg-counts 'supply-depot) 0)
                             '(barracks)
                             '(supply-depot barracks))]
               [else (if (> (bldg-count-equivalent total-bldg-counts 'pylon) 0)
                         '(gateway)
                         '(pylon gateway))])
             '())
         (if (and root-combat-facility-ready?
                  (< army-supply (max 8 (+ enemy-threat-supply 4))))
             (case race
               [(Zerg) (if (< (bldg-count-equivalent total-bldg-counts 'spine-crawler) 1)
                           '(zergling spine-crawler)
                           '(zergling))]
               [(Terran) (if (< (bldg-count-equivalent total-bldg-counts 'bunker) 1)
                             '(marine bunker)
                             '(marine))]
               [else
                (let ([need-sb? (< (bldg-count-equivalent total-bldg-counts 'shield-battery) 1)])
                  (if (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
                      (if pvt-fast-kiter-threat?
                          (if need-sb?
                              '(stalker adept shield-battery)
                              '(stalker adept))
                          (if need-sb?
                              '(stalker adept shield-battery zealot)
                              '(stalker adept zealot)))
                      (if need-sb?
                          (if (= (bldg-count-equivalent total-bldg-counts 'cybernetics-core) 0)
                              '(cybernetics-core zealot shield-battery)
                              '(zealot shield-battery))
                          (if (= (bldg-count-equivalent total-bldg-counts 'cybernetics-core) 0)
                              '(cybernetics-core zealot)
                              '(zealot)))))])
             '()))
        '()))

  (define existing-id-norms-ht
    (for/fold ([ht (hasheq)]) ([eid (in-list (map priority-candidate-id raw-cands))])
      (if (symbol? eid) (hash-set ht (normalize-brain-sym eid) #t) ht)))
  (define plan-translated-syms (map plan-goal-node-next-action-sym plan-actionable-nodes))
  (define extra-syms
    (remove-duplicates
     (filter (lambda (s)
               (and s
                    (symbol? s)
                    (sg-unit-allowed? s)
                    (not (hash-has-key? existing-id-norms-ht (normalize-brain-sym s)))
                    (lookup-sc2-tech-node s)
                    (not (crisis-deferred-sym? (normalize-brain-sym s) crisis-defer?
                                               #:defer-stargate? defer-stargate?
                                               #:keep-ship-weapons? ship-weap-due?
                                               #:keep-spire-aa? keep-spire-aa?))
                    (not (and zerg-step-t3-on? (zerg-t3-obsolete-unbuilt? s total-bldg-counts)))
                    (not (step-already-satisfied? s))))
             (append (if supply-crisis? (list race-supply-sym) '())
                     emergency-rush-syms
                     (if (and (eq? race 'Protoss)
                              under-early-rush-crisis?
                              root-combat-facility-ready?
                              (= (bldg-count-equivalent total-bldg-counts 'cybernetics-core) 0))
                         '(cybernetics-core)
                         '())
                     (if (and (eq? race 'Zerg)
                              (or under-early-rush-crisis? under-attack? (> enemy-threat-supply 0))
                              (>= workers 2)
                              (= (bldg-count-equivalent total-bldg-counts 'spawning-pool) 0))
                         '(spawning-pool)
                         '())
                     (if crisis-defer?
                         (case race
                           [(Zerg)
                            (append
                             (if (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
                                 (append '(queen)
                                         (if (and severe-crisis-static-def?
                                                  (< (bldg-count-equivalent total-bldg-counts 'spine-crawler) 2))
                                             '(spine-crawler)
                                             '()))
                                 '())
                             (if (> (bldg-count-equivalent ready-bldg-counts 'roach-warren) 0)
                                 (if (> (unit-count-equivalent unit-counts 'roach) 0)
                                     '(roach ravager)
                                     '(roach))
                                 '()))]
                           [(Protoss)
                            (append
                             (if (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
                                 (if (and severe-crisis-static-def?
                                          (< (bldg-count-equivalent total-bldg-counts 'shield-battery) 2))
                                     '(stalker shield-battery)
                                     '(stalker))
                                 '())
                             (if (> (bldg-count-equivalent ready-bldg-counts 'robotics-facility) 0)
                                 '(immortal)
                                 '())
                             (if (and (not pvt-fast-kiter-threat?)
                                      (> (+ (bldg-count-equivalent ready-bldg-counts 'gateway)
                                            (bldg-count-equivalent ready-bldg-counts 'warp-gate)) 0))
                                 '(zealot)
                                 '()))]
                           [else
                            (append
                             (if (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
                                 '(siege-tank)
                                 '())
                             (if (> (bldg-count-equivalent ready-bldg-counts 'barracks-techlab) 0)
                                 '(marauder)
                                 '())
                             (if (and severe-crisis-static-def?
                                      (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0)
                                      (< (bldg-count-equivalent total-bldg-counts 'bunker) 2))
                                 '(bunker)
                                 '()))])
                         '())
                     (if (and (eq? race 'Zerg) enemy-cap-air?)
                         (append
                          (if (and (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
                                   (< (unit-count-equivalent unit-counts 'queen) desired-queens))
                              '(queen)
                              '())
                          (if (and has-lair-or-hive-ready?
                                   (= (bldg-count-equivalent total-bldg-counts 'spire) 0)
                                   (= (bldg-count-equivalent total-bldg-counts 'greater-spire) 0))
                              '(spire)
                              '())
                          (if (or (> (bldg-count-equivalent ready-bldg-counts 'spire) 0)
                                  (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0))
                              (append
                               (if (< (unit-count-equivalent unit-counts 'corruptor)
                                      (zerg-enemy-capital-air-corruptor-cap enemy-u-counts eff-req-aa? enemy-race))
                                   '(corruptor)
                                   '())
                               '(zerg-flyer-armor-1))
                              '())
                          (if (> (bldg-count-equivalent ready-bldg-counts 'hydralisk-den) 0)
                              '(hydralisk)
                              '()))
                         '())
                     (if (and (eq? race 'Terran)
                              enemy-cap-air?
                              (or enemy-cap-air-ground-aa?
                                  (> (bldg-count-equivalent total-bldg-counts 'factory-techlab) 0))
                              (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)
                              (= (bldg-count-equivalent total-bldg-counts 'armory) 0))
                         '(armory)
                         '())
                     (if (and (eq? race 'Terran)
                              enemy-cap-air?
                              (> (bldg-count-equivalent ready-bldg-counts 'factory-techlab) 0)
                              has-ready-armory?
                              (< (unit-count-equivalent unit-counts 'thor) desired-thors))
                         '(thor)
                         '())
                     (if ship-weap-due?
                         '(terran-ship-weapons-1)
                         '())
                     (if overdue-1base-expand? (list race-expand-sym) '())
                     repaired-prereqs
                     plan-translated-syms
                     (if bo-goal-sym (list bo-goal-sym) '())
                     (if (and sg-upg-escalation?
                              (not crisis-defer?)
                              (symbol? sg-desired-upg-bay-sym)
                              (< (bldg-count-equivalent total-bldg-counts sg-desired-upg-bay-sym) sg-desired-upg-bays)
                              (or (= (bldg-count-equivalent total-bldg-counts sg-desired-upg-bay-sym) 0)
                                  (not (hash? open-facility-slots))
                                  (>= army-supply 12)
                                  (>= active-bases 3)
                                  (>= minerals 300)))
                         (list sg-desired-upg-bay-sym)
                         '())
                     (if (and sg-counter-inject-active? (not crisis-defer?))
                         (filter (lambda (u)
                                   (and (not (sc2-tech-already-satisfied? u total-bldg-counts researched-upgrades pending-upgrades 1))
                                        (or sg-upg-escalation?
                                            (sc2-tech-prereqs-ready? u ready-bldg-counts unit-counts))))
                                 sg-rec-upgs)
                         '())
                     (if (and sg-high-bank-inject? (>= workers 20) (not under-attack?))
                         sg-macro-inject-structs
                         '())
                     (if sg-counter-inject-active?
                         (let ([defer-blind-rec?
                                (and (hash? open-facility-slots)
                                     (<= sg-enemy-sup 0.0)
                                     (<= enemy-threat-supply 0)
                                     (< army-supply 18)
                                     (< active-bases 3)
                                     (not enemy-cap-air?)
                                     (not eff-req-det?))])
                           (if defer-blind-rec?
                               (filter (lambda (u)
                                         (not (speculative-late-tech-unit-deferred? u ready-bldg-counts total-bldg-counts)))
                                       (hash-keys sg-rec-units))
                               (hash-keys sg-rec-units)))
                         '())
                     (if opp-cap-air-override?
                         (slice15-cap-air-extra-syms race ready-bldg-counts unit-counts)
                         '())
                     (case loss-recovery-mode
                       [(worker-loss-recovery)
                        (append (list slice15-worker-sym)
                                (cond
                                  [(and (eq? race 'Zerg)
                                        (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
                                        (< (unit-count-equivalent unit-counts 'queen) desired-queens))
                                   '(queen)]
                                  [(and (eq? race 'Terran)
                                        (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0)
                                        (< (bldg-count-equivalent total-bldg-counts 'orbital-command) active-bases))
                                   '(orbital-command)]
                                  [else '()])
                                (if lr-boost-static-def?
                                    (filter (lambda (sd) (sc2-tech-prereqs-ready? sd ready-bldg-counts unit-counts))
                                            slice15-mineral-def-syms)
                                    '()))]
                       [(base-loss-recovery)
                        (if slice15-defense-stabilized?
                            (list race-expand-sym)
                            (if lr-boost-static-def?
                                (filter (lambda (sd) (sc2-tech-prereqs-ready? sd ready-bldg-counts unit-counts))
                                        slice15-choke-def-syms)
                                '()))]
                       [(army-wipe-counter-pivot-recovery)
                        (append
                         (filter (lambda (sd) (sc2-tech-prereqs-ready? sd ready-bldg-counts unit-counts))
                                 slice15-choke-def-syms)
                         (filter (lambda (u) (sc2-tech-prereqs-ready? u ready-bldg-counts unit-counts))
                                 (hash-keys wipe-counter-boost-table)))]
                       [else '()])
                     (if (and (= total-gas-bldgs 0)
                              (gas-building-cap-ok? total-gas-bldgs active-bases)
                              (>= workers 14)
                              (not early-zero-army-attack?)
                              (or (not (hash? open-facility-slots))
                                  (eq? race 'Zerg)
                                  (and (eq? race 'Terran)
                                       (> (bldg-count-equivalent total-bldg-counts 'barracks) 0))
                                  (and (eq? race 'Protoss)
                                       (> (bldg-count-equivalent total-bldg-counts 'gateway) 0))))
                         (list gas-bldg-sym)
                         '())))
     eq?))

  (define (build-scored-candidate id category action min-cost gas-cost supply-cost blocking-allowed? m-ht)
    (define blk-bool (not (not blocking-allowed?)))
    (define c0 (priority-candidate id category action min-cost gas-cost supply-cost 0.0 'medium blk-bool))
    (define score (compute-candidate-marginal-utility c0 m-ht))
    (define tier
      (cond
        [(>= score 1000.0) 'critical-supply]
        [(>= score 230.0)  'high-priority]
        [(>= score 110.0)  'standard-macro]
        [else              'background-economy]))
    (priority-candidate id category action min-cost gas-cost supply-cost score tier blk-bool))

  (define extra-cands
    (for/list ([sym (in-list extra-syms)])
      (define node (lookup-sc2-tech-node sym))
      (define csym (sc2-tech-node-id node))
      (define cat (sc2-tech-node-category node))
      (define act (tech-node->action csym (sc2-tech-node-kind node)
                                     base-x base-y nat-x nat-y third-x third-y active-bases))
      (define raw-cand
        (build-scored-candidate csym cat act
                                (sc2-tech-node-min-cost node)
                                (sc2-tech-node-gas-cost node)
                                (sc2-tech-node-supply-cost node)
                                (cand-can-escrow? csym)
                                metrics))
      (if (is-repaired-prereq? csym)
          (struct-copy priority-candidate raw-cand
                       [utility-score (+ 300.0 (priority-candidate-utility-score raw-cand))])
          raw-cand)))

  (define open-combat-fac-slots-cnt
    (if (hash? open-facility-slots)
        (for/sum ([k (in-list '(barracks factory starport gateway warp-gate robotics-facility stargate larva))])
          (hash-ref open-facility-slots k 0))
        99))

  (define zerg-passive-sat-ok?
    (and (eq? race 'Zerg)
         (not under-attack?)
         zerg-army-step-ok?
         (< workers (min 60 (* 16 active-bases)))
         (or (<= enemy-threat-supply 0)
             (>= army-supply (if (>= active-bases 3) 4 6)))))

  (define zerg-3base-interleave-ok?
    (and (eq? race 'Zerg)
         (not under-attack?)
         zerg-army-step-ok?
         (>= active-bases 3)
         (< workers 55)
         (>= army-supply 4)))

  (define passive-sat-ok?
    (or tvp-worker-recovery?
        (and (not under-attack?)
             zerg-army-step-ok?
             (or (<= enemy-threat-supply 0)
                 zerg-passive-sat-ok?
                 (and (< workers (min 44 (* 22 active-bases)))
                      (< enemy-threat-supply 18)
                      (<= enemy-threat-supply (* 1.65 (max 6 army-supply))))))))

  (define worker-army-curve-ok?
    (or (not (hash? open-facility-slots))
        (and zerg-army-step-ok?
             (or (< workers 24)
                 zerg-3base-interleave-ok?
                 (and passive-sat-ok?
                      (< workers (min 44 (* 22 active-bases))))
                 (and (not under-attack?)
                      (<= enemy-threat-supply 0)
                      (or (and (< workers (min 66 (* 20 active-bases))) (>= minerals 150))
                          (and (>= minerals 350) (<= open-combat-fac-slots-cnt 1))))
                 (>= army-supply (required-army-supply-for-worker-growth workers enemy-threat-supply))))))

  (define need-worker-saturation?
    (and (not under-attack?)
         passive-sat-ok?
         worker-army-curve-ok?
         (< workers (min 70 (max target-workers (* 22 active-bases))))))

  (define nat-exp-min-reserve
    (compute-natural-expansion-mineral-reserve
     #:race race
     #:frame frame
     #:active-bases active-bases
     #:pending-bases (max 0 (- total-townhalls-incl-pending active-bases))
     #:workers workers
     #:under-attack? under-attack?
     #:enemy-threat-supply enemy-threat-supply))

  (define zerg-16-hatch-pending?
    (and (eq? race 'Zerg)
         (< total-townhalls-incl-pending 2)
         (not under-attack?)
         (not under-early-rush-crisis?)
         (<= enemy-threat-supply 1.5)
         (<= frame 2400)
         (or (same-brain-sym? bo-goal-sym 'hatchery)
             (not (not (hash-ref plan-next-actions-ht 'hatchery #f))))))
  (define terran-contained-breakout-cc?
    (and (eq? race 'Terran)
         (<= active-bases 3)
         (<= total-townhalls-incl-pending 3)
         (>= minerals 1500)
         (>= workers 18)))

  (define (cand-wanted-now? c)
    (define id (priority-candidate-id c))
    (define c-norm (normalize-brain-sym id))
    (define cat (priority-candidate-category c))
    (define act (priority-candidate-action c))
    (define blk0 (priority-candidate-blocking-allowed? c))
    (define research-allowed?
      (or (not (and (pair? act) (eq? (car act) 'research)))
          (upgrade-allowed-by-unit-and-order-gates?
           race c-norm frame workers ready-bldg-counts total-bldg-counts
           unit-counts researched-upgrades pending-upgrades)))
    (define nat-exp-defers-cand?
      (and natural-exp-window?
           (not (eq? c-norm race-expand-sym))
           (not (memq c-norm '(overlord pylon supply-depot drone probe scv)))
           (case race
             [(Zerg) (or (and (eq? c-norm 'spawning-pool)
                              (or (not (pro-bo-goal? effective-bo-goal))
                                  (not (eq? (pro-bo-goal-target-sym effective-bo-goal) 'spawning-pool))
                                  (>= (pro-bo-goal-min-supply effective-bo-goal) 16)))
                         (memq c-norm '(roach-warren extractor queen zergling)))]
             [(Protoss) (or (and (eq? c-norm 'gateway)
                                 (>= (bldg-count-equivalent total-bldg-counts 'gateway) 1))
                            (and (eq? cat 'tech-upgrade)
                                 (pair? act)
                                 (eq? (car act) 'research))
                            (and (eq? cat 'combat-unit)
                                 (memq c-norm '(zealot stalker adept sentry))
                                 (>= army-supply 2)))]
             [(Terran) (or (and (eq? c-norm 'barracks)
                                (>= (bldg-count-equivalent total-bldg-counts 'barracks) 1))
                           (eq? c-norm 'factory)
                           (and (eq? c-norm 'marine)
                                (>= (unit-count-equivalent unit-counts 'marine) 1)))]
             [else #f])))
    (if (or (not research-allowed?) nat-exp-defers-cand?)
        #f
        (let ()
          (define node (lookup-sc2-tech-node id))
    (define plan-node
      (or (hash-ref plan-next-actions-ht id #f)
          (hash-ref plan-next-actions-ht (normalize-brain-sym id) #f)))
    (define protoss-1base-2nd-gas-capped?
      (and (eq? race 'Protoss)
           (eq? id 'assimilator)
           (<= active-bases 1)
           (< total-townhalls-incl-pending 2)
           (or (not (memq enemy-race '(Protoss Random)))
               (< (bldg-count-equivalent total-bldg-counts 'gateway) 2))
           (not under-early-rush-crisis?)
           (>= (bldg-count-equivalent total-bldg-counts 'assimilator) 1)))
    (define geyser-cap-ok?
      (or (not (memq id '(extractor refinery assimilator)))
          (let ([cur-gas-bldgs (bldg-count-equivalent total-bldg-counts id)])
            (and (not protoss-1base-2nd-gas-capped?)
                 (or (not supply-lockout-active?)
                     (>= minerals (+ (sc2-min-cost race-supply-sym 100)
                                     (priority-candidate-min-cost c))))
                 (gas-building-cap-ok? cur-gas-bldgs active-bases)
                 (>= workers (min-workers-for-next-gas-bldg cur-gas-bldgs))
                 (not early-zero-army-attack?)
                 (or (not (hash? open-facility-slots))
                     (> cur-gas-bldgs 0)
                     (and bo-goal-sym (same-brain-sym? id bo-goal-sym))
                     (eq? id 'extractor)
                     (and (eq? id 'refinery)
                          (> (bldg-count-equivalent total-bldg-counts 'barracks) 0))
                     (and (eq? id 'assimilator)
                          (> (bldg-count-equivalent total-bldg-counts 'gateway) 0)))
                 (or (not (hash? open-facility-slots))
                     (= cur-gas-bldgs 0)
                     (< gas (if (and (>= cur-gas-bldgs 2) (>= workers 36)) 550 250)))))))
    (define addon-slot-free-ok?
      (or (not (hash? open-facility-slots))
          (not (facility-addon-slot-occupied? id ready-bldg-counts total-bldg-counts #:min-ready-floor 0))))
    (define redundant-scaling-fac-idle?
      (and (hash? open-facility-slots)
           (< minerals 300)
           (or (and (eq? id 'barracks)
                    (>= (bldg-count-equivalent total-bldg-counts 'barracks) (if (>= active-bases 2) 4 2))
                    (>= (hash-ref open-facility-slots 'barracks 0) 2))
               (and (eq? id 'gateway)
                    (>= (bldg-count-equivalent total-bldg-counts 'gateway) (if (>= active-bases 2) 5 2))
                    (>= (+ (hash-ref open-facility-slots 'gateway 0)
                           (hash-ref open-facility-slots 'warp-gate 0))
                        2)))))
    (define late-tech-army-ok?
      (or (not (hash? open-facility-slots))
          (not (memq id '(armory ghost-academy fusion-core ultralisk-cavern templar-archive dark-shrine)))
          (is-repaired-prereq? id)
          (and (> (hash-ref sg-rec-units id 0.0) 0.0)
               sg-counter-inject-active?)
          (and (eq? id 'armory)
               (eq? race 'Terran)
               enemy-cap-air?
               (or enemy-cap-air-ground-aa?
                   (> (bldg-count-equivalent total-bldg-counts 'factory-techlab) 0)))
          (and (eq? id 'ghost-academy) (>= active-bases 2) terran-need-ghost?)
          (>= army-supply 18)
          (and (memq id '(templar-archive dark-shrine ultralisk-cavern fusion-core armory ghost-academy))
               (or (and bo-goal-sym (same-brain-sym? id bo-goal-sym))
                   (and plan-node (>= (plan-goal-node-priority-weight plan-node) 440.0))))))
    (define zerg-drone-sacrifice-ok?
      (or (not (eq? race 'Zerg))
          (not node)
          (not (memq (sc2-tech-node-kind node) '(build expand)))
          (and (or under-early-rush-crisis? under-attack? (> enemy-threat-supply 0))
               (>= workers 2)
               (or (and (eq? id 'spawning-pool)
                        (= (bldg-count-equivalent total-bldg-counts 'spawning-pool) 0)
                        (>= minerals 200))
                   (and (eq? id 'spine-crawler)
                        (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
                        (>= minerals 100))))
          (and (>= workers 5)
               (or (>= workers 13)
                   overdue-1base-expand?
                   (= (bldg-count-equivalent total-bldg-counts 'spawning-pool) 0)
                   (memq id '(spawning-pool spine-crawler spore-crawler))
                   (and (eq? id 'extractor)
                        (= (bldg-count-equivalent total-bldg-counts 'extractor) 0))))))
    (define nat-reserve-allows-2nd-fac?
      (or (not (memq id '(gateway barracks)))
          (= (bldg-count-equivalent total-bldg-counts id) 0)
          (and (eq? race 'Protoss)
               (memq enemy-race '(Protoss Random))
               (eq? id 'gateway)
               (< (bldg-count-equivalent total-bldg-counts 'gateway) 2))
          (<= nat-exp-min-reserve 0)
          (>= (- minerals nat-exp-min-reserve) (priority-candidate-min-cost c))))
    (define supply-lockout-allows-expand?
      (or (not (eq? cat 'expansion))
          (not supply-lockout-active?)
          (>= minerals (+ (sc2-min-cost race-supply-sym 100)
                          (priority-candidate-min-cost c)))))
    (define depletion-or-mirror-expand?
      (depletion-or-mirror-expand-due?
       race active-bases workers ws-depleting-bases
       sg-mirror-min-bases under-attack? army-supply minerals))
    (define nat-blocked-expand-ok?
      (or (not (eq? cat 'expansion))
          (not ws-natural-blocked?)
          (>= minerals 350)))
    (define protoss-4th-exp-due?
      (protoss-4th-nexus-due? race active-bases workers army-supply minerals enemy-cap-air?))
    (define 3rd-plus-expand-ready?
      (or (not (eq? cat 'expansion))
          slice15-base-loss-expand-now?
          (not (hash? open-facility-slots))
          (< active-bases 2)
          terran-contained-breakout-cc?
          depletion-or-mirror-expand?
          (and (not under-attack?)
               (<= enemy-threat-supply (* 1.35 (max 10 army-supply)))
               (>= workers (cond
                             [(eq? race 'Zerg) 24]
                             [(and (eq? race 'Protoss)
                                   (= active-bases 2)
                                   (>= frame 6200)
                                   (or (>= minerals 350)
                                       ;; Late recovery on 2 bases with a real army can escrow the 3rd Nexus at 34+ Probes.
                                       (and (>= frame 9000) (>= army-supply 20))))
                              34]
                             [(eq? race 'Protoss) 38]
                             [else 36]))
               (or (eq? race 'Zerg)
                   protoss-4th-exp-due?
                   (>= army-supply (if (= active-bases 2) 12 16))
                   (>= minerals 550)))))
    (define csym (normalize-brain-sym id))
    (define suppressed-kiter-zealot?
      (and pvt-fast-kiter-threat?
           (eq? csym 'zealot)
           (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)))
    (define suppressed-tvp-extra-rax?
      (and suppress-tvp-extra-rax?
           (eq? csym 'barracks)
           (>= (bldg-count-equivalent total-bldg-counts 'barracks) 1)))
    (define sentry-cap-ok?
      (or (not (eq? csym 'sentry))
          (< (unit-count-equivalent unit-counts 'sentry)
             (if (>= active-bases 4) 3 2))))
    (define research-unit-prereq-ok?
      (or (not (eq? csym 'extended-thermal-lance))
          (>= (unit-count-equivalent unit-counts 'colossus) 1)))
    (and (not suppressed-kiter-zealot?)
         (not suppressed-tvp-extra-rax?)
         (sg-unit-allowed? csym)
         nat-blocked-expand-ok?
         geyser-cap-ok?
         sentry-cap-ok?
         research-unit-prereq-ok?
         addon-slot-free-ok?
         (not redundant-scaling-fac-idle?)
         late-tech-army-ok?
         zerg-drone-sacrifice-ok?
         nat-reserve-allows-2nd-fac?
         supply-lockout-allows-expand?
         3rd-plus-expand-ready?
         (not (and zerg-16-hatch-pending?
                   (memq csym '(spawning-pool extractor))
                   (< minerals 450)
                   (not (is-repaired-prereq? id))))
         (cond
           [(crisis-deferred-sym? csym crisis-defer?
                                  #:defer-stargate? defer-stargate?
                                  #:keep-ship-weapons? ship-weap-due?
                                  #:keep-spire-aa? keep-spire-aa?)
            #f]
           [(and (memq id SC2-SINGLETON-TECH-BUILDINGS)
                 (> (bldg-count-equivalent total-bldg-counts id) 0))
            #f]
           [(and (memq id SC2-DUAL-CAP-TECH-BUILDINGS)
                 (>= (bldg-count-equivalent total-bldg-counts id) 2))
            #f]
           [(and (eq? race 'Zerg)
                 (memq id '(infestation-pit spire))
                 (not (or eff-req-aa?
                          eff-req-det?
                          (> (hash-ref sg-rec-units id 0.0) 0.0)
                          (and (eq? id 'spire) (or keep-spire-aa? enemy-cap-air?))
                          (and (>= active-bases 3) (>= army-supply 28)))))
            #f]
           [(and (eq? race 'Protoss)
                 (eq? id 'stargate)
                 (<= active-bases 2)
                 (> (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0)
                 (> (bldg-count-equivalent total-bldg-counts 'twilight-council) 0)
                 (not (or eff-req-aa? eff-req-det? enemy-cap-air? (> (hash-ref sg-rec-units 'stargate 0.0) 0.0))))
            #f]
           [(is-repaired-prereq? id)
            (not (and (memq id SC2-SINGLETON-TECH-BUILDINGS)
                      (> (bldg-count-equivalent total-bldg-counts id) 0)))]
           [(memq id emergency-rush-syms) #t]
           [(eq? cat 'supply)
            (or supply-crisis?
                (and (or (and bo-goal-sym (same-brain-sym? id bo-goal-sym)) plan-node)
                     (<= pending-supply 0)))]
           [(and bo-goal-sym (same-brain-sym? id bo-goal-sym)) #t]
           [(and plan-node
                 (or (>= (plan-goal-node-priority-weight plan-node) 440.0)
                     (and (memq (plan-goal-node-reason plan-node) '(timing-upgrade-plan timing-unit-plan benchmark-unit-plan))
                          (>= (plan-goal-node-priority-weight plan-node) 420.0)
                          (or (not (eq? cat 'combat-unit))
                              (< army-supply 8)
                              under-attack?
                              (> enemy-threat-supply 0)
                              (>= workers (min 24 (* 11 active-bases)))))))
            #t]
           [(eq? cat 'worker)
            (or tvp-worker-recovery?
                (if (hash? open-facility-slots)
                    (and zerg-army-step-ok?
                         (< workers (min 70 (max target-workers (* 22 active-bases)))))
                    (< workers (min 80 (max target-workers (* 20 active-bases))))))]
           [(eq? cat 'expansion)
            (or terran-contained-breakout-cc?
                depletion-or-mirror-expand?
                (and sg-high-bank-inject? (not under-attack?) (>= workers 20) (< total-townhalls-incl-pending 6))
                (and (not under-attack?)
                     (or overdue-1base-expand?
                         protoss-4th-exp-due?
                         (and (< active-bases
                                 (max eff-desired-bases
                                      (cond [(>= effective-phase-supply 108) 5]
                                            [(>= effective-phase-supply 64) 4]
                                            [(>= effective-phase-supply 30) 3]
                                            [else 2])))
                              (>= workers (if (= active-bases 1)
                                              (if (eq? race 'Zerg) 15 18)
                                              24))))))]
           [(eq? cat 'counter-tech)
            (cond
              [(memq id '(queen observer))
               (define cur-cnt (unit-count-equivalent unit-counts id))
               (define max-cnt (if (eq? id 'queen) desired-queens 1))
               (and blk0 (< cur-cnt max-cnt))]
              [(eq? id 'raven)
               (and blk0
                    (or eff-req-det?
                        (> (hash-ref sg-rec-units 'raven 0.0) 0.0)
                        (and bo-goal-sym (same-brain-sym? id bo-goal-sym))
                        (and plan-node (>= (plan-goal-node-priority-weight plan-node) 440.0)))
                    (< (unit-count-equivalent unit-counts 'raven)
                       (if (or eff-req-det? (>= active-bases 2) (> (hash-ref sg-rec-units 'raven 0.0) 0.0)) 2 1)))]
              [(eq? id 'overseer)
               (and (or eff-req-det? has-lair-or-hive-ready?)
                    (< (unit-count-equivalent unit-counts 'overseer) (max 1 desired-overseer-cnt)))]
              [(memq id '(viking viking-fighter corruptor phoenix))
               (and blk0
                    (or (not (eq? id 'phoenix))
                        (and (not enemy-cap-air?)
                             (not (eq? enemy-race 'Terran))
                             (sg-unit-allowed? 'phoenix)))
                    (or aa-effective?
                        enemy-cap-air?
                        keep-spire-aa?
                        (> (hash-ref sg-rec-units (normalize-brain-sym id) 0.0) 0.0)
                        (not (hash? open-facility-slots))
                        (and bo-goal-sym (same-brain-sym? id bo-goal-sym))))]
              [(eq? id 'spore-crawler)
               (and (or aa-effective? eff-req-det? enemy-cap-air? keep-spire-aa?)
                    (< (bldg-count-equivalent total-bldg-counts 'spore-crawler)
                       (max 1 desired-spores)))]
              [(memq id '(photon-cannon missile-turret))
               (and (or aa-effective? eff-req-det?)
                    (< (bldg-count-equivalent total-bldg-counts id) 1))]
              [(memq id '(shield-battery spine-crawler bunker))
               (and (or under-attack? (> enemy-threat-supply 0))
                    (< (bldg-count-equivalent total-bldg-counts id)
                       (if severe-crisis-static-def? 2 1)))]
              [else blk0])]
           [(eq? cat 'production-scaling)
            (cond
              [(memq id '(gateway barracks))
               (define cur-facs (bldg-count-equivalent total-bldg-counts id))
               (define fac-cap
                 (cond
                   [(eq? id 'gateway)
                    (cond
                      [(>= active-bases 3) 8]
                      [(>= active-bases 2) (if (or (>= workers 34) (>= minerals 400)) 6 4)]
                      [(memq enemy-race '(Protoss Random)) 2]
                      [else 1])]
                   [else ;; barracks
                    (cond
                      [(>= active-bases 3) 8]
                      [(>= active-bases 2) (if (or (>= workers 34) (>= minerals 400)) 5 3)]
                      [else 2])]))
               (define worker-gate-ok?
                 (cond
                   [(eq? id 'gateway)
                    (or (< cur-facs 2)
                        (and (>= active-bases 2)
                             (or (and (< cur-facs 4) (>= workers 26))
                                 (and (< cur-facs 6) (or (>= workers 34) (>= minerals 400)))))
                        (and (>= active-bases 3) (>= workers 40)))]
                   [else
                    (or (< cur-facs 2)
                        (and (>= active-bases 2)
                             (or (and (< cur-facs 3) (>= workers 20))
                                 (and (< cur-facs 5) (or (>= workers 34) (>= minerals 400)))))
                        (and (>= active-bases 3) (>= workers 44)))]))
               (and (< cur-facs fac-cap) worker-gate-ok?)]
              [(eq? id 'barracks-techlab)
               (< (bldg-count-equivalent total-bldg-counts 'barracks-techlab) desired-rax-tl)]
              [(eq? id 'factory)
               (< (bldg-count-equivalent total-bldg-counts 'factory)
                  (max desired-factories (goal-target-count-for 'factory)))]
              [(memq id '(extractor refinery assimilator))
               (define cur-gas-bldgs (bldg-count-equivalent total-bldg-counts id))
               (and (not protoss-1base-2nd-gas-capped?)
                    (gas-building-cap-ok? cur-gas-bldgs active-bases)
                    (>= workers (min-workers-for-next-gas-bldg cur-gas-bldgs))
                    (not early-zero-army-attack?))]
              [else blk0])]
           [(eq? cat 'combat-unit)
            (and (or blk0
                     (and emergency-army-before-workers?
                          (step-prereqs-ready? id)
                          (slot-available? (if node (sc2-tech-node-producer-slot node) 'worker))))
                 (< supply-used 196)
                 (or (not (eq? csym 'overlord-transport))
                     (< (unit-count-for-goal unit-counts 'overlord-transport) desired-dropper-cnt))
                 (or (not (hash? open-facility-slots))
                     (not (eq? csym 'zergling))
                     (< (unit-count-equivalent unit-counts 'zergling)
                        (zergling-target-cap minerals enemy-u-counts)))
                 (or under-attack?
                     (> enemy-threat-supply 0)
                     (< army-supply 8)
                     (>= workers (min 24 (* 11 active-bases)))))]
           [else blk0])))))

  (define all-adjusted-cands
    (for/list ([c (in-list (append raw-cands extra-cands))]
               #:when (cand-wanted-now? c))
      (define sym (priority-candidate-id c))
      (define cat (priority-candidate-category c))
      (define u0 (priority-candidate-utility-score c))
      (define blk0 (priority-candidate-blocking-allowed? c))
      (define node (lookup-sc2-tech-node sym))
      (define is-repaired-raw?
        (is-repaired-prereq? sym))
      (define is-repaired?
        (and is-repaired-raw?
             (or (not (hash? open-facility-slots))
                 (and (not under-attack?) (<= enemy-threat-supply 0))
                 (not root-combat-facility-ready?)
                 (memq sym '(spawning-pool barracks gateway pylon supply-depot overlord)))))
      (define plan-node
        (or (hash-ref plan-next-actions-ht sym #f)
            (hash-ref plan-next-actions-ht (normalize-brain-sym sym) #f)))
      (define plan-weight (if plan-node (plan-goal-node-priority-weight plan-node) 0.0))
      (define plan-reason (and plan-node (plan-goal-node-reason plan-node)))
      (define is-timing-plan?
        (not (not (memq plan-reason '(timing-upgrade-plan timing-unit-plan benchmark-unit-plan)))))
      (define under-sat-peaceful-econ?
        (and (not under-attack?)
             (<= enemy-threat-supply 0)
             (< workers (min 36 (* 16 active-bases)))))
      (define is-plan-milestone?
        (and plan-node
             (not is-timing-plan?)
             (>= plan-weight 440.0)))
      (define is-bo-goal?
        (or (and bo-goal-sym (same-brain-sym? sym bo-goal-sym))
            is-plan-milestone?))
      (cond
        ;; Supply candidate during supply crisis or hard 15/15 lockout
        [(eq? cat 'supply)
         (define u-sup
           (cond
             [supply-lockout-active? (max 2200.0 u0)]
             [supply-crisis? (max 1350.0 u0)]
             [else (max 280.0 u0)]))
         (struct-copy priority-candidate c
                      [utility-score u-sup]
                      [blocking-allowed? (or has-mineral-income?
                                             (>= minerals (priority-candidate-min-cost c)))])]

        ;; Worker candidate: emergency recovery when workers < 14, and sustained saturation up to min(70, 22 * bases)
        ;; Gated by `worker-army-curve-ok?` (`required-army-supply-for-worker-growth`) at `workers >= 24`.
        [(eq? cat 'worker)
         (define sat-target (min 70 (* 22 active-bases)))
         (define emergency-worker-boost
           (cond
             [(= workers 0) 1500.0]
             [emergency-army-before-workers? 0.0]
             [(>= workers 70) 0.0]
             [(< workers 8) (+ 600.0 (* 100.0 (- 8.0 workers)))]
             [(< workers 14) (+ 120.0 (* 25.0 (- 14.0 workers)))]
             [(and need-worker-saturation? (< workers sat-target)) 135.0]
             [need-worker-saturation? 115.0]
             [else 0.0]))
         (define w-plan-boost
           (cond
             [emergency-army-before-workers? 0.0]
             [(>= workers 70) 0.0]
             [(and tvp-worker-recovery? (< workers 20)) 525.0]
             [(and tvp-worker-recovery? (< workers (min 36 (* 22 active-bases)))) 482.0]
             [(and (< workers (if (eq? race 'Zerg) 14 16))
                   (not under-attack?)
                   (<= enemy-threat-supply 0))
              plan-weight]
             [(and need-worker-saturation?
                   (< workers sat-target))
              (cond
                [(<= enemy-threat-supply 0) 430.0]
                [(and worker-army-curve-ok?
                      (< workers (min 44 (* 22 active-bases))))
                 380.0]
                [else 220.0])]
             [else 0.0]))
         (define raw-worker-u0
           (if (>= workers 70)
               25.0
               (max w-plan-boost (+ u0 emergency-worker-boost))))
         (define raw-worker-u
           (if (and (not under-attack?)
                    (< workers (min 66 (* 16 active-bases))))
               (max 60.0 raw-worker-u0)
               raw-worker-u0))
         (struct-copy priority-candidate c
                      [utility-score (cond
                                       [(>= workers 70) 25.0]
                                       [emergency-army-before-workers? (min 160.0 raw-worker-u)]
                                       [(not worker-army-curve-ok?) (min 105.0 raw-worker-u)]
                                       [else raw-worker-u])]
                      [blocking-allowed? (and (not emergency-army-before-workers?)
                                              (or (< workers 8)
                                                  (and tvp-worker-recovery? (< workers 20)))
                                              has-mineral-income?)])]

        ;; Expansion candidate: high priority when active plan expansion goal or 1-base natural ready,
        ;; but NEVER blocks combat units when under-attack?, enemy-threat-supply > 0 (PV1/PV2/PV7),
        ;; or when 2-base Terran/Protoss lacks standing army (< 10 supply) below 550M (#5122353 fix).
        [(eq? cat 'expansion)
         (define depletion-or-mirror-exp?
           (depletion-or-mirror-expand-due?
            race active-bases workers ws-depleting-bases
            sg-mirror-min-bases under-attack? army-supply minerals))
         (define high-bank-exp?
           (and sg-high-bank-inject?
                (not under-attack?)
                (>= workers 20)
                (< total-townhalls-incl-pending 6)))
         (define premature-3rd-base-starving-army?
           (and (not terran-contained-breakout-cc?)
                (not depletion-or-mirror-exp?)
                (hash? open-facility-slots)
                (>= active-bases 2)
                (not (eq? race 'Zerg))
                (< army-supply 10)
                (< minerals 550)))
         (define light-expand-threat-ok?
           (or terran-contained-breakout-cc?
               depletion-or-mirror-exp?
               slice15-base-loss-expand-now?
               high-bank-exp?
               (<= enemy-threat-supply 0)
               (and zerg-16-hatch-pending? (<= enemy-threat-supply 1.5))
               (and (>= active-bases 2)
                    (not under-attack?)
                    (<= enemy-threat-supply (* 1.35 (max 10 army-supply)))
                    (>= army-supply (if (eq? race 'Protoss) 10 14))
                    (or (not (eq? race 'Protoss))
                        (>= workers 38)
                        (and (>= frame 6200) (>= workers 34) (>= minerals 350))))))
         (define protoss-3rd-nexus-due?
           (and (eq? race 'Protoss)
                (= active-bases 2)
                light-expand-threat-ok?
                (not premature-3rd-base-starving-army?)
                (>= army-supply 10)
                (or (>= workers 38)
                    (and (>= frame 6200) (>= workers 34) (>= minerals 350)))))
         (define protoss-4th-nexus-ready?
           (and (protoss-4th-nexus-due? race active-bases workers army-supply minerals enemy-cap-air?)
                light-expand-threat-ok?))
         (define exp-in-backoff? (macro-escrow-in-backoff? escrow-state-entry frame sym))
         (define exp-affordable-now?
           (and (>= minerals (priority-candidate-min-cost c))
                (>= gas (priority-candidate-gas-cost c))))
         (define exp-ok?
           (and (not supply-preempt-now?)
                (not exp-in-backoff?)
                (or natural-exp-window?
                    slice15-base-loss-expand-now?
                    overdue-1base-expand?
                    (can-fund-within-frames?
                     minerals gas (priority-candidate-min-cost c) (priority-candidate-gas-cost c)
                     mineral-harvesters gas-harvesters workers ready-bldg-counts race #:frames 90))
                (or slice15-base-loss-expand-now?
                    (and (or (not ws-natural-blocked?) (>= minerals 350))
                         (or blk0 is-bo-goal? is-repaired? natural-exp-window? overdue-1base-expand? protoss-3rd-nexus-due? protoss-4th-nexus-ready? terran-contained-breakout-cc? depletion-or-mirror-exp? high-bank-exp?)
                         (or terran-contained-breakout-cc? (not under-attack?))
                         (or natural-exp-window? light-expand-threat-ok?)
                         (not premature-3rd-base-starving-army?)
                         (or overdue-1base-expand?
                             terran-contained-breakout-cc?
                             (>= workers (if (eq? race 'Zerg) 14 16)))
                         has-mineral-income?))))
         (define exp-u
           (cond
             [(and exp-in-backoff? (not exp-affordable-now?)) (min u0 20.0)]
             [slice15-base-loss-expand-now? (max 492.0 plan-weight u0)]
             [(and (not terran-contained-breakout-cc?)
                   (or under-attack?
                       (and (not natural-exp-window?) (not light-expand-threat-ok?))
                       premature-3rd-base-starving-army?
                       (and ws-natural-blocked? (< minerals 350))))
              (min u0 45.0)]
             [is-repaired? (max 520.0 u0)]
             [natural-exp-window? (max 620.0 plan-weight u0)]
             [terran-contained-breakout-cc? (max 478.0 plan-weight u0)]
             [(and depletion-or-mirror-exp? exp-ok?) (max 474.0 plan-weight u0)]
             [(and high-bank-exp? exp-ok?) (max 470.0 plan-weight u0)]
             [overdue-1base-expand? (max 490.0 plan-weight u0)]
             [protoss-4th-nexus-ready? (max 462.0 plan-weight u0)]
             [protoss-3rd-nexus-due? (max 455.0 plan-weight u0)]
             [(and is-bo-goal? exp-ok?) (max plan-weight 465.0 u0)]
             [exp-ok? (max 210.0 u0)]
             [else u0]))
         (struct-copy priority-candidate c
                      [utility-score exp-u]
                      [blocking-allowed? exp-ok?])]

        [else
         (define worker-sat-thresh
            (if (hash? open-facility-slots)
                (* 21 active-bases)
                (* 16 active-bases)))
         (define cur-queens (unit-count-equivalent unit-counts 'queen))
         (define max-queens desired-queens)
         (define queen-defer-for-first-lings?
           (and (eq? sym 'queen)
                (or under-attack? (> enemy-threat-supply 2))
                (< army-supply 4)))
         (define queen-sat-cap
           (if (and (not (or zvp-stargate-threat? enemy-cap-air? early-aggro?))
                    (< workers (if (>= active-bases 2) 18 14)))
               active-bases
               max-queens))
         (define inject-queen-boost?
           (and (eq? sym 'queen)
                (not queen-defer-for-first-lings?)
                (< cur-queens queen-sat-cap)
                (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)))
         (define proactive-overseer-boost?
           (and (eq? sym 'overseer)
                has-lair-or-hive-ready?
                (< (unit-count-equivalent unit-counts 'overseer)
                   (max 1 desired-overseer-cnt))))
         (define emergency-rush-root-boost?
           (and (or (and under-early-rush-crisis?
                         (not root-combat-facility-ready?)
                         (memq sym '(spawning-pool barracks gateway supply-depot pylon))
                         (or (memq sym '(supply-depot pylon))
                             (= (bldg-count-equivalent total-bldg-counts sym) 0))
                         (memq sym emergency-rush-syms))
                    (and under-early-rush-crisis?
                         (eq? race 'Protoss)
                         root-combat-facility-ready?
                         (eq? sym 'cybernetics-core)
                         (= (bldg-count-equivalent total-bldg-counts 'cybernetics-core) 0))
                    (and (or under-early-rush-crisis? under-attack? (> enemy-threat-supply 0))
                         (eq? race 'Zerg)
                         (>= workers 2)
                         (eq? sym 'spawning-pool)
                         (= (bldg-count-equivalent total-bldg-counts 'spawning-pool) 0)))))
         (define emergency-rush-def-boost?
           (and under-early-rush-crisis?
                root-combat-facility-ready?
                (memq sym emergency-rush-syms)))
         (define gas-unlock-tech-boost?
           (and (hash? open-facility-slots)
                (not under-attack?)
                (<= enemy-threat-supply 0)
                (>= gas 80)
                (or (and (eq? sym 'roach-warren)
                         (= (bldg-count-equivalent total-bldg-counts 'roach-warren) 0)
                         (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0))
                    (and (eq? sym 'lair)
                         (>= gas 100)
                         (= (bldg-count-equivalent total-bldg-counts 'lair) 0)
                         (= (bldg-count-equivalent total-bldg-counts 'hive) 0)
                         (> (bldg-count-equivalent total-bldg-counts 'roach-warren) 0))
                    (and (eq? sym 'cybernetics-core)
                         (= (bldg-count-equivalent total-bldg-counts 'cybernetics-core) 0)
                         (> (+ (bldg-count-equivalent ready-bldg-counts 'gateway)
                               (bldg-count-equivalent ready-bldg-counts 'warp-gate)) 0))
                    (and (eq? sym 'robotics-facility)
                         (>= gas 100)
                         (= (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0)
                         (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0))
                    (and (eq? sym 'factory)
                         (>= gas 100)
                         (= (bldg-count-equivalent total-bldg-counts 'factory) 0)
                         (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0))
                    (and (eq? sym 'starport)
                         (>= gas 100)
                         (= (bldg-count-equivalent total-bldg-counts 'starport) 0)
                         (> (bldg-count-equivalent ready-bldg-counts 'factory) 0)))))
         (define act (priority-candidate-action c))
         (define nsym (normalize-brain-sym sym))
         (define is-combat-unit-cand?
           (or (eq? cat 'combat-unit)
               (and (eq? cat 'counter-tech)
                    (pair? act)
                    (memq (car act) '(train morph)))))
         (define static-roi-bias
           (if is-combat-unit-cand?
               (let ([gc (priority-candidate-gas-cost c)]
                     [mc (priority-candidate-min-cost c)])
                 (if (> gc 0)
                     (+ (if (eq? cat 'combat-unit) 14.0 0.0)
                        (min 16.0 (+ (* 0.025 (exact->inexact mc))
                                     (* 0.075 (exact->inexact gc)))))
                     0.0))
               0.0))
         (define sit-w (if is-combat-unit-cand? (situational-unit-weight sit-weights nsym 1.0) 1.0))
         (define sit-penalty (and is-combat-unit-cand? (hash-ref sit-penalties nsym #f)))
         (define sit-suppressed? (and is-combat-unit-cand? (not (not (memq nsym sit-suppressed-units)))))
         (define sit-recommended? (and is-combat-unit-cand? (not (not (memq nsym sit-recommended-units)))))
         (define sit-cap-val (and is-combat-unit-cand? (hash-ref sit-unit-caps nsym #f)))
         (define sit-over-cap?
           (and is-combat-unit-cand?
                (exact-integer? sit-cap-val)
                (>= (unit-count-equivalent unit-counts nsym) sit-cap-val)))
         (define mineral-only-gas-locked?
           (and (hash? open-facility-slots)
                (eq? cat 'combat-unit)
                (memq sym '(zergling marine zealot hellion))
                (not under-attack?)
                (<= enemy-threat-supply 0)
                (>= gas 80)
                (>= army-supply 4)))
         (define effective-bo-goal?
           (and is-bo-goal?
                (not mineral-only-gas-locked?)
                (not queen-defer-for-first-lings?)))
         (define colossus-unlock-needed?
           (and (eq? race 'Protoss)
                (eq? sym 'colossus)
                (= (unit-count-equivalent unit-counts 'colossus) 0)
                (> (bldg-count-equivalent ready-bldg-counts 'robotics-bay) 0)
                (not (step-already-satisfied? 'extended-thermal-lance))))
         (define pvt-robo-bay-boost?
           (and (eq? sym 'robotics-bay)
                (pvt-immortal-robo-bay-due? race enemy-race effective-phase-supply
                                            ready-bldg-counts total-bldg-counts unit-counts)))
         (define combat-escrow-ok?
           (and (not (and mineral-only-gas-locked? (>= army-supply 4)))
                (or (not (eq? cat 'combat-unit))
                    effective-bo-goal?
                    colossus-unlock-needed?
                    under-attack?
                    (> enemy-threat-supply 0)
                    (and (>= frame 1800) (< army-supply 6))
                    (>= workers (min target-workers worker-sat-thresh)))))
         (define queen-escrow-ok?
           (and (not queen-defer-for-first-lings?)
                (or (not (eq? sym 'queen))
                    (< cur-queens max-queens))
                (or (not (hash? open-facility-slots))
                    (not (eq? sym 'queen))
                    inject-queen-boost?
                    effective-bo-goal?
                    eff-req-aa?
                    keep-spire-aa?
                    enemy-cap-air?)))
         (define answers-aa-or-det?
           (or (is-aa-or-detection-answer?
                sym
                (or aa-effective? (and (eq? race 'Protoss) enemy-cap-air?))
                eff-req-det?)
               (and (eq? race 'Protoss)
                    enemy-cap-air?
                    (memq (normalize-brain-sym sym) '(stargate fleet-beacon void-ray tempest)))
               (and (eq? race 'Terran)
                    (or (and tvp-cannon-contain?
                             (memq (normalize-brain-sym sym) '(factory factory-techlab siege-tank concussive-shells)))
                        (and (memq (normalize-brain-sym sym) '(ghost ghost-academy)) terran-need-ghost?)
                        (and (eq? (normalize-brain-sym sym) 'liberator) terran-need-lib?)
                        (and (memq (normalize-brain-sym sym) '(starport starport-reactor viking-fighter))
                             enemy-cap-air?)
                        (and (eq? (normalize-brain-sym sym) 'armory)
                             enemy-cap-air?
                             (or enemy-cap-air-ground-aa?
                                 (> (bldg-count-equivalent total-bldg-counts 'factory-techlab) 0)))
                        (and (eq? (normalize-brain-sym sym) 'terran-ship-weapons-1)
                             ship-weap-due?)
                        (and (eq? (normalize-brain-sym sym) 'thor) enemy-cap-air?)))
               proactive-overseer-boost?
               emergency-rush-root-boost?
               emergency-rush-def-boost?))
         (define first-robo-under-attack-ok?
           (and (eq? sym 'robotics-facility)
                (= (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0)
                (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
                (>= workers 20)))
         (define tech-under-attack-escrow-ok?
           (or (not (hash? open-facility-slots))
               (and (not under-attack?) (<= enemy-threat-supply 0))
               (eq? cat 'combat-unit)
               (eq? cat 'supply)
               is-repaired?
               answers-aa-or-det?
               first-robo-under-attack-ok?))
         (define secondary-starving-primary-slots?
           (and (hash? open-facility-slots)
                (eq? cat 'combat-unit)
                (memq (and node (sc2-tech-node-producer-slot node))
                      '(robotics-facility stargate factory starport))
                (< army-supply 16)
                (>= (+ (hash-ref open-facility-slots 'gateway 0)
                       (hash-ref open-facility-slots 'warp-gate 0)
                       (hash-ref open-facility-slots 'barracks 0))
                    2)
                (< minerals (- (priority-candidate-min-cost c) 75))))
         (define worker-recovery-target
           (cond
             [(eq? cat 'tech-upgrade) (min 22 (* 11 active-bases))]
             [(memq plan-reason '(tvt-rax-techlab-scaling tvt-mech-scaling tvt-bio-tank
                                  proactive-widow-mine-harass proactive-bio-medivac proactive-raven-intel))
              40]
             [else (min 44 (* 22 active-bases))]))
         (define tvt-optional-scaling-defer?
           (and (memq plan-reason '(tvt-rax-techlab-scaling tvt-mech-scaling tvt-bio-tank
                                   proactive-widow-mine-harass proactive-bio-medivac proactive-raven-intel))
                (not eff-req-aa?)
                (not (and post-bo-deviated? (> (hash-ref sg-rec-units (normalize-brain-sym sym) 0.0) 0.0)))
                (not (and bo-goal-sym (same-brain-sym? sym bo-goal-sym)))
                (> (if (memq cat '(combat-unit counter-tech))
                       (unit-count-equivalent unit-counts sym)
                       (bldg-count-equivalent total-bldg-counts sym))
                   0)))
         (define unique-bo-unit-ready?
           (and (memq race '(Terran Protoss))
                (eq? cat 'combat-unit)
                (>= workers 22)
                (= (unit-count-equivalent unit-counts sym) 0)
                (or (and bo-goal-sym (same-brain-sym? sym bo-goal-sym))
                    colossus-unlock-needed?)))
         (define defer-for-worker-recovery?
           (and (hash? open-facility-slots)
                (not under-attack?)
                (<= enemy-threat-supply 0)
                (>= army-supply 6)
                (< workers worker-recovery-target)
                (not (and (eq? cat 'tech-upgrade) (> sg-upg-mult 1.25) (>= workers 20)))
                (or (and (memq cat '(combat-unit tech-upgrade))
                         (not is-repaired?)
                         (not answers-aa-or-det?)
                         (not unique-bo-unit-ready?)
                         (not (eq? sym 'orbital-command))
                         (not (and (eq? sym 'queen) inject-queen-boost?)))
                    tvt-optional-scaling-defer?)))
         (define sit-hard-counter-exempt?
           (or opp-cap-air-override?
               emergency-rush-def-boost?
               answers-aa-or-det?
               colossus-unlock-needed?
               pvt-robo-bay-boost?
               (and tvp-cannon-contain? (eq? nsym 'siege-tank))
               (and under-attack? (< army-supply 4))))
         (define sit-penalized-block?
           (and is-combat-unit-cand?
                (or sit-over-cap?
                    sit-suppressed?
                    (symbol? sit-penalty))
                (cond
                  [(eq? sit-penalty 'banshee-cannot-shoot-air) #t]
                  [(eq? sit-penalty 'aa-supply-over-cap) #t]
                  [(eq? sit-penalty 'no-enemy-air-supply)
                   (let ([bo-tgt (hash-ref bo-unit-target-ht nsym 0)])
                     (not (or opp-cap-air-override?
                              answers-aa-or-det?
                              (and is-bo-goal?
                                   (> bo-tgt 0)
                                   (<= bo-tgt 2)
                                   (< (unit-count-equivalent unit-counts nsym) bo-tgt)))))]
                  [(eq? sit-penalty 'early-econ-gas-starvation)
                   (not (or sit-hard-counter-exempt?
                            (and (>= gas 250)
                                 (>= active-bases 2)
                                 (or effective-bo-goal? is-timing-plan?))))]
                  [(memq sit-penalty '(pre-range-hydra-vs-splash late-t1-vs-splash))
                   (not sit-hard-counter-exempt?)]
                  [else
                   (not (or sit-hard-counter-exempt? effective-bo-goal?))])))
         (define u-after-gas-lock
           (let* ([u-gas (if mineral-only-gas-locked?
                             (/ u0 (+ 1.0 (expt (/ (exact->inexact gas) 100.0) 2)))
                             u0)]
                  [u-clean (if is-combat-unit-cand?
                               (max 10.0 (- u-gas static-roi-bias))
                               u-gas)])
             (cond
               [(not is-combat-unit-cand?) u-clean]
               [sit-penalized-block?
                (min (if (eq? sit-penalty 'early-econ-gas-starvation) 85.0 35.0)
                     (+ (* u-clean (+ 0.25 (* 0.35 sit-w)))
                        (if (eq? sit-penalty 'early-econ-gas-starvation) 15.0 0.0)))]
               [else
                (+ (* u-clean (+ 0.45 (* 0.55 sit-w)))
                   (if sit-recommended? (* 35.0 (max 0.0 (- sit-w 1.0))) 0.0))])))
         (define can-esc?
           (and (not queen-defer-for-first-lings?)
                (not defer-for-worker-recovery?)
                (not sit-penalized-block?)
                (or blk0
                    effective-bo-goal?
                    colossus-unlock-needed?
                    pvt-robo-bay-boost?
                    is-repaired?
                    inject-queen-boost?
                    proactive-overseer-boost?
                    emergency-rush-root-boost?
                    emergency-rush-def-boost?
                    gas-unlock-tech-boost?
                    (and emergency-army-before-workers? (eq? cat 'combat-unit)))
                combat-escrow-ok?
                queen-escrow-ok?
                tech-under-attack-escrow-ok?
                (not secondary-starving-primary-slots?)
                (not (and (memq sym '(spine-crawler bunker shield-battery))
                          (< army-supply 4)
                          (< minerals 200)))
                (not (and is-timing-plan?
                          under-sat-peaceful-econ?
                          (not (and bo-goal-sym (same-brain-sym? sym bo-goal-sym)))))
                (cand-can-escrow? sym)
                (> workers 0)))
         (define boosted-u
           (cond
             [queen-defer-for-first-lings? (min 80.0 u-after-gas-lock)]
             [emergency-rush-root-boost? (max 680.0 (+ 500.0 u0))]
             [(and emergency-rush-def-boost? (eq? cat 'combat-unit))
              (max 620.0 (+ 340.0 u0))]
             [emergency-rush-def-boost?
              (if (and (< army-supply 4) (< minerals 200))
                  (min 390.0 u-after-gas-lock)
                  (max 515.0 (+ 200.0 u0)))]
             [sit-penalized-block? u-after-gas-lock]
             [(and effective-bo-goal? (memq plan-reason '(anti-capital-air opp-cap-air-override)))
              (max plan-weight (+ 650.0 u0) 930.0)]
             [pvt-robo-bay-boost? (max 960.0 (+ 400.0 u0))]
             [is-repaired? (max (+ 380.0 u0) 520.0)]
             [defer-for-worker-recovery? (min 425.0 u-after-gas-lock)]
             [proactive-overseer-boost? (max 475.0 (+ 140.0 u0))]
             [colossus-unlock-needed? (max plan-weight 496.0 u0)]
             [(and effective-bo-goal?
                   (or (and (not under-attack?) (<= enemy-threat-supply 0))
                       (eq? cat 'combat-unit)
                       answers-aa-or-det?
                       (memq nsym '(baneling lurker ultralisk brood-lord ravager archon))))
              (max plan-weight
                   (if answers-aa-or-det? u-after-gas-lock 0.0)
                   (if (and bo-goal-sym (same-brain-sym? sym bo-goal-sym)) (+ 200.0 u0) 0.0)
                   (if is-combat-unit-cand? (+ 465.0 (* 18.0 (- sit-w 1.0))) 465.0))]
             [(and (eq? cat 'tech-upgrade)
                   (not under-attack?)
                   (> sg-upg-mult 1.25)
                   (memq (normalize-brain-sym sym) sg-rec-upgs))
              (max plan-weight (min 492.0 (+ 458.0 (* 12.0 sg-upg-mult))) u0)]
             [(and effective-bo-goal?
                   (not under-attack?)
                   (<= enemy-threat-supply (* 0.65 (max 1 army-supply)))
                   (memq plan-reason '(tvt-rax-techlab-scaling tvt-mech-scaling anti-capital-air t3-ghost-counter t3-liberator-counter post-bo-strategic-goal)))
              ;; Light non-attack threat should not drop matchup scaling behind generic upgrades while
              ;; staying strictly below boosted combat units (465+) and keeping `can-esc?` gated above.
              (max 420.0 u-after-gas-lock)]
             [(and is-timing-plan?
                   (or (and (not under-attack?) (<= enemy-threat-supply 0))
                       answers-aa-or-det?))
              (max plan-weight u-after-gas-lock)]
             [gas-unlock-tech-boost? (max plan-weight 445.0 u0)]
             [inject-queen-boost?
              (if (and (hash? open-facility-slots) (not under-attack?) (<= enemy-threat-supply 0))
                  (max 440.0 u0)
                  (max 225.0 u0))]
             [(and (eq? cat 'combat-unit)
                   (not under-attack?)
                   (<= enemy-threat-supply 0)
                   (>= army-supply 2))
              (min 415.0 u-after-gas-lock)]
             [(and first-robo-under-attack-ok? (>= army-supply 6))
              (max plan-weight 475.0 u0)]
             [(and is-repaired-raw? (not is-repaired?))
              (max 50.0 (- u-after-gas-lock 300.0))]
             [else u-after-gas-lock]))
         (struct-copy priority-candidate c
                      [utility-score boosted-u]
                      [blocking-allowed? can-esc?])])))

  ;; Slice 1.5A utility overrides, counter pivots, escrow preemptions, and failing-comp suppression
  (define protoss-ground-combat-cnt
    (if (eq? race 'Protoss)
        (+ (unit-count-equivalent unit-counts 'zealot)
           (unit-count-equivalent unit-counts 'stalker)
           (unit-count-equivalent unit-counts 'adept)
           (unit-count-equivalent unit-counts 'sentry)
           (unit-count-equivalent unit-counts 'immortal)
           (unit-count-equivalent unit-counts 'colossus)
           (unit-count-equivalent unit-counts 'disruptor)
           (unit-count-equivalent unit-counts 'high-templar)
           (unit-count-equivalent unit-counts 'dark-templar)
           (unit-count-equivalent unit-counts 'archon))
        0))
  (define protoss-air-combat-cnt
    (if (eq? race 'Protoss)
        (+ (unit-count-equivalent unit-counts 'void-ray)
           (unit-count-equivalent unit-counts 'carrier)
           (unit-count-equivalent unit-counts 'tempest)
           (unit-count-equivalent unit-counts 'phoenix)
           (unit-count-equivalent unit-counts 'oracle))
        0))
  (define (post-adjust-candidate c)
    (define id (priority-candidate-id c))
    (define nsym (normalize-brain-sym id))
    (define cat (priority-candidate-category c))
    (define act (priority-candidate-action c))
    (define u (priority-candidate-utility-score c))
    (define blk? (priority-candidate-blocking-allowed? c))
    (define in-backoff? (macro-escrow-in-backoff? escrow-state-entry frame nsym))
    (define affordable-now?
      (and (>= minerals (priority-candidate-min-cost c))
           (>= gas (priority-candidate-gas-cost c))))
    (cond
      [(eq? cat 'supply)
       (if supply-preempt-now?
           (struct-copy priority-candidate c
                        [utility-score (max u 1350.0)]
                        [blocking-allowed? #t])
           c)]
      [(and in-backoff? (not affordable-now?))
       (struct-copy priority-candidate c
                    [utility-score (min u 20.0)]
                    [blocking-allowed? #f])]
      [(and (pair? act)
            (eq? (car act) 'research)
            (not (upgrade-allowed-by-unit-and-order-gates?
                  race nsym frame workers ready-bldg-counts total-bldg-counts
                  unit-counts researched-upgrades pending-upgrades)))
       (struct-copy priority-candidate c
                    [utility-score 0.0]
                    [blocking-allowed? #f])]
      [else
       (define u1
         (cond
           [(and (eq? race 'Protoss)
                 (>= protoss-ground-combat-cnt protoss-air-combat-cnt)
                 (memq nsym '(protoss-ground-weapons-1 protoss-ground-weapons-2 protoss-ground-weapons-3
                              protoss-ground-armor-1 protoss-ground-armor-2 protoss-ground-armor-3)))
            (max u 476.0)]
           [(and (eq? race 'Protoss)
                 (> protoss-ground-combat-cnt protoss-air-combat-cnt)
                 (memq nsym '(protoss-air-weapons-1 protoss-air-weapons-2 protoss-air-weapons-3
                              protoss-air-armor-1 protoss-air-armor-2 protoss-air-armor-3)))
            (min u 440.0)]
           [(and natural-exp-window? (eq? nsym race-expand-sym))
            (max u 620.0)]
           [(and natural-exp-window? (not (memq cat '(supply worker))))
            (min u 460.0)]
           [else u]))
       (define blk1
         (cond
           [(or supply-preempt-now? in-backoff?) #f]
           [(and natural-exp-window? (eq? nsym race-expand-sym)) #t]
           [else blk?]))
       (struct-copy priority-candidate c
                    [utility-score u1]
                    [blocking-allowed? blk1])]))
  (define raw-adjusted-cands (map post-adjust-candidate all-adjusted-cands))
  (define slice15-adjusted-cands
    (if (and (not opp-cap-air-override?) (eq? loss-recovery-mode 'none))
        raw-adjusted-cands
        (for/list ([c (in-list raw-adjusted-cands)])
          (define cid (priority-candidate-id c))
          (define csym (normalize-brain-sym cid))
          (define cat (priority-candidate-category c))
          (define prereq-ok? (step-prereqs-ready? cid))
          (define u (priority-candidate-utility-score c))
          (define blk (priority-candidate-blocking-allowed? c))
          (define is-bo?
            (and bo-goal-sym (same-brain-sym? cid bo-goal-sym)))
          (define pnode
            (or (hash-ref plan-next-actions-ht cid #f)
                (hash-ref plan-next-actions-ht (normalize-brain-sym cid) #f)))
          (define is-timing-bo?
            (and pnode
                 (memq (plan-goal-node-reason pnode)
                       '(pro-bo-timing-step bo-goal-repair missing-tech-prereq broken-tech-repair
                         timing-upgrade-plan macro-tech-plan prereq-repair timing-unit-plan
                         expansion-plan army-milestone-plan))
                 #t))
          (define is-rep? (is-repaired-prereq? cid))
          ;; Step 1: Opportunity-cost capital-air-fleet hard override (485..515 counters, -140 ground non-counters)
          (define sit-aa-capped-here?
            (let ([cap (hash-ref sit-unit-caps csym #f)])
              (or (eq? (hash-ref sit-penalties csym #f) 'aa-supply-over-cap)
                  (and (exact-integer? cap)
                       (> (unit-count-equivalent unit-counts csym) 0)
                       (>= (unit-count-equivalent unit-counts csym) cap)))))
          (define-values (u1 blk1)
            (if opp-cap-air-override?
                (let ([cap-u (hash-ref cap-air-boost-table csym #f)])
                  (cond
                    [(and cap-u (not sit-aa-capped-here?))
                     (values (max u cap-u)
                             (or prereq-ok? (memq csym '(spire starport stargate fleet-beacon))))]
                    [(and cap-u sit-aa-capped-here?)
                     (values (min u 35.0) #f)]
                    [(memq csym *slice15-cap-air-suppressed-syms*)
                     (values (- u 140.0) #f)]
                    [else (values u blk)]))
                (values u blk)))
          ;; Step 2: Loss-recovery mode adjustments (worker / base / army-wipe)
          (define-values (u2 blk2)
            (case loss-recovery-mode
              [(worker-loss-recovery)
               (cond
                 [(and (eq? race 'Protoss)
                       (>= workers 22)
                       (> (bldg-count-equivalent ready-bldg-counts 'robotics-bay) 0)
                       (or (and (eq? csym 'immortal)
                                (= (unit-count-equivalent unit-counts 'immortal) 0)
                                (> (bldg-count-equivalent ready-bldg-counts 'robotics-facility) 0))
                           (and (eq? csym 'colossus)
                                (>= (unit-count-equivalent unit-counts 'immortal) 1)
                                (= (unit-count-equivalent unit-counts 'colossus) 0)
                                (not (step-already-satisfied? 'extended-thermal-lance)))
                           (and (eq? csym 'extended-thermal-lance)
                                (>= (unit-count-equivalent unit-counts 'colossus) 1))))
                  (values (max u1 500.0) #t)]
                 [(or (eq? csym slice15-worker-sym)
                      (and (eq? race 'Zerg)
                           (eq? csym 'queen)
                           (< (unit-count-equivalent unit-counts 'queen) desired-queens))
                      (and (eq? race 'Terran)
                           (eq? csym 'orbital-command)
                           (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0)
                           (< (bldg-count-equivalent total-bldg-counts 'orbital-command) active-bases)))
                  (values (if (eq? cat 'supply) u1 (max u1 498.0)) #t)]
                 [(and lr-boost-static-def?
                       (memq csym slice15-mineral-def-syms)
                       (< (bldg-count-equivalent total-bldg-counts csym) (max 1 active-bases)))
                  (values (max u1 496.0) prereq-ok?)]
                 [(and lr-preempt-greedy-tech?
                       (not opp-cap-air-override?)
                       (slice15-nonessential-tech-preemptable? c is-rep? is-bo? is-timing-bo? workers lr-boost-static-def?))
                  (values (min u1 140.0) #f)]
                 [else (values u1 blk1)])]
              [(base-loss-recovery)
               (cond
                 [(and (eq? csym race-expand-sym) slice15-defense-stabilized?)
                  (values (max u1 492.0) #t)]
                 [(and (not slice15-defense-stabilized?)
                       lr-boost-static-def?
                       (memq csym slice15-choke-def-syms)
                       (< (bldg-count-equivalent total-bldg-counts csym) 2))
                  (values (max u1 494.0) prereq-ok?)]
                 [(and lr-preempt-greedy-tech?
                       slice15-defense-stabilized?
                       (not opp-cap-air-override?)
                       (slice15-nonessential-tech-preemptable? c is-rep? #f is-timing-bo? workers #t))
                  (values (min u1 140.0) #f)]
                 [else (values u1 blk1)])]
              [(army-wipe-counter-pivot-recovery)
               (define w-counter-u (hash-ref wipe-counter-boost-table csym #f))
               (cond
                 [(and (memq csym slice15-choke-def-syms)
                       (< (bldg-count-equivalent total-bldg-counts csym) (max 2 active-bases)))
                  (values (max u1 494.0) prereq-ok?)]
                 [(and (not opp-cap-air-override?) w-counter-u)
                  (values (max u1 w-counter-u) prereq-ok?)]
                 [(and (memq csym wipe-suppressed-units)
                       (not (and opp-cap-air-override?
                                 (memq csym *slice15-cap-air-suppressed-syms*))))
                  (values (- u1 130.0) #f)]
                 [(and (not (hash-has-key? cap-air-boost-table csym))
                       (not w-counter-u)
                       (slice15-nonessential-tech-preemptable? c is-rep? #f #f workers #t))
                  (values (min u1 130.0) #f)]
                 [else (values u1 blk1)])]
              [else (values u1 blk1)]))
          (struct-copy priority-candidate c
                       [utility-score u2]
                       [blocking-allowed? blk2]))))

  ;; 5. Filter out candidates that are ALREADY satisfied (e.g. researched/pending upgrades or unique buildings)
  ;;    and deduplicate by canonical candidate `id` (keeping highest utility).
  (define seen-ids (make-hasheq))
  (define active-cands
    (filter (lambda (c)
              (define id (priority-candidate-id c))
              (define cid (normalize-brain-sym id))
              (and (not (hash-has-key? seen-ids cid))
                   (not (step-already-satisfied? cid))
                   (begin (hash-set! seen-ids cid #t) #t)))
            (sort slice15-adjusted-cands > #:key priority-candidate-utility-score)))

  (define sorted-cands active-cands)

  ;; Mutable simulation ledger for this frame's scheduling pass
  (define desired-corruptor-cap
    (if (eq? race 'Zerg)
        (zerg-enemy-capital-air-corruptor-cap enemy-u-counts eff-req-aa? enemy-race)
        0))
  (define rem-min minerals)
  (define rem-gas gas)
  (define rem-sup (max 0 supply-left))
  (define rem-slots
    (if (hash? open-facility-slots)
        (hash-copy open-facility-slots)
        #f))
  (define reserved-slots '())
  (define seen-tech-counts (make-hasheq))
  (define seen-unit-counts (make-hasheq))
  (define used-morph-slots (make-hasheq))
  (define worker-build-escrowed? #f)
  (define min-floor 0)
  (define min-floor-for-worker 0)
  (define gas-floor 0)
  (define scheduled-cands '())
  (define reserved-cand #f)
  (define decision-entries '())
  (define escrowed-entries '())

  (for ([c (in-list sorted-cands)]
        [rank-idx (in-naturals 1)])
    (define id (priority-candidate-id c))
    (define csym (normalize-brain-sym id))
    (define cat (priority-candidate-category c))
    (define act (priority-candidate-action c))
    (define m-cost (priority-candidate-min-cost c))
    (define g-cost (priority-candidate-gas-cost c))
    (define s-cost (priority-candidate-supply-cost c))
    (define u-score (priority-candidate-utility-score c))
    (define blk-ok? (eq? (priority-candidate-blocking-allowed? c) #t))
    (define node (lookup-sc2-tech-node id))
    (define pslot (if node (sc2-tech-node-producer-slot node) 'worker))

    ;; Strict singleton (== 0) and upgrade-bay (<= 2) deduplication across existing+pending+same-frame.
    (define existing-tech-cnt (bldg-count-equivalent total-bldg-counts csym))
    (define sched-tech-cnt (hash-ref seen-tech-counts csym 0))
    (define tech-cap-ok?
      (cond
        [(memq csym SC2-SINGLETON-TECH-BUILDINGS)
         (= (+ existing-tech-cnt sched-tech-cnt) 0)]
        [(memq csym SC2-DUAL-CAP-TECH-BUILDINGS)
         (< (+ existing-tech-cnt sched-tech-cnt) 2)]
        [(memq csym '(extractor refinery assimilator))
         (< (+ existing-tech-cnt sched-tech-cnt) (gas-building-cap active-bases))]
        [(eq? csym 'barracks-techlab)
         (< (+ existing-tech-cnt sched-tech-cnt) desired-rax-tl)]
        [(eq? csym 'factory)
         (< (+ existing-tech-cnt sched-tech-cnt)
            (max desired-factories (goal-target-count-for 'factory)))]
        [(eq? csym 'starport)
         (< (+ existing-tech-cnt sched-tech-cnt)
            (max 1 (if (and (eq? race 'Terran) enemy-cap-air?)
                       (if (>= active-bases 3) 3 2)
                       (goal-target-count-for 'starport))))]
        [(eq? csym 'starport-reactor)
         (< (+ existing-tech-cnt sched-tech-cnt)
            (max 1 (if (and (eq? race 'Terran) enemy-cap-air?)
                       (if (>= active-bases 3) 2 1)
                       (goal-target-count-for 'starport-reactor))))]
        [(eq? csym 'stargate)
         (< (+ existing-tech-cnt sched-tech-cnt)
            (max 1 (if (and (eq? race 'Protoss) enemy-cap-air? (>= active-bases 2))
                       2
                       (goal-target-count-for 'stargate))))]
        [(eq? csym 'spore-crawler)
         (< (+ existing-tech-cnt sched-tech-cnt) (max 1 desired-spores))]
        [else #t]))
    (define unit-cap-ok?
      (and
       (sg-unit-allowed? csym #f (hash-ref seen-unit-counts csym 0))
       (not (and (eq? cat 'combat-unit)
                 (memq csym slice15-all-suppressed-units)))
       (case csym
         [(queen)
          (< (+ (unit-count-equivalent unit-counts 'queen)
                (hash-ref seen-unit-counts 'queen 0))
             desired-queens)]
         [(corruptor)
          (let ([tgt (max desired-corruptor-cap (goal-target-count-for 'corruptor))])
            (or (<= tgt 0)
                (< (+ (unit-count-equivalent unit-counts 'corruptor)
                      (hash-ref seen-unit-counts 'corruptor 0))
                   tgt)))]
         [(overseer)
          (< (+ (unit-count-equivalent unit-counts 'overseer)
                (hash-ref seen-unit-counts 'overseer 0))
             (max 1 desired-overseer-cnt))]
         [(overlord-transport)
          (< (+ (unit-count-for-goal unit-counts 'overlord-transport)
                (hash-ref seen-unit-counts 'overlord-transport 0))
             desired-dropper-cnt)]
         [(sentry)
          (< (+ (unit-count-equivalent unit-counts 'sentry)
                (hash-ref seen-unit-counts 'sentry 0))
             (if (>= active-bases 4) 3 2))]
         [(lurker)
          (< (+ (unit-count-equivalent unit-counts 'lurker)
                (hash-ref seen-unit-counts 'lurker 0))
             10)]
         [(hellbat)
          (< (+ (unit-count-equivalent unit-counts 'hellbat)
                (hash-ref seen-unit-counts 'hellbat 0))
             12)]
         [(zergling)
          (or (not (hash? open-facility-slots))
              (< (+ (unit-count-equivalent unit-counts 'zergling)
                    (hash-ref seen-unit-counts 'zergling 0))
                 (zergling-target-cap minerals enemy-u-counts)))]
         [(ghost)
          (< (+ (unit-count-equivalent unit-counts 'ghost)
                (hash-ref seen-unit-counts 'ghost 0))
             desired-ghosts)]
         [(liberator)
          (< (+ (unit-count-equivalent unit-counts 'liberator)
                (hash-ref seen-unit-counts 'liberator 0))
             desired-libs)]
         [(thor)
          (< (+ (unit-count-equivalent unit-counts 'thor)
                (hash-ref seen-unit-counts 'thor 0))
             (if enemy-cap-air? desired-thors 4))]
         [else #t])))

    ;; Check tech prerequisite readiness & open producer slot
    (define prereq-ok?
      (and (step-prereqs-ready? id)
           (or (not (eq? csym 'extended-thermal-lance))
               (>= (unit-count-equivalent unit-counts 'colossus) 1))))
    (define slot-ok?
      (and (not (memq pslot reserved-slots))
           (cond
             [(eq? pslot 'worker) (> workers 0)]
             [(memq pslot UNIT-MORPH-SOURCE-SLOTS)
              (unit-morph-slot-ready? pslot unit-counts used-morph-slots)]
             [(not rem-slots) #t]
             [else (> (hash-ref rem-slots pslot 0) 0)])))
    (define worker-cap-ok?
      (or (not (eq? cat 'worker))
          (if (hash? open-facility-slots)
              (and (or zerg-army-step-ok?
                       (and (eq? loss-recovery-mode 'worker-loss-recovery) lr-boost-workers?))
                   (< workers (min 70 (max target-workers (* 22 active-bases)))))
              (< workers (min 80 (max target-workers (* 20 active-bases)))))))

    (define supply-ok? (or (<= s-cost 0) (>= rem-sup s-cost)))
    (define min-ok? (>= rem-min m-cost))
    (define gas-ok? (>= rem-gas g-cost))

    ;; High-bank deadlock guard: when minerals >= 600 and supply-left >= 2, tech/morph/upgrade
    ;; goals never freeze downstream combat/worker spending (supply escrow still protected).
    (define high-bank-tech-unlock?
      (high-bank-unlock-allowed? minerals 600 rem-sup reserved-cand))

    ;; Supply candidate ignores non-supply floors (PV4)
    (define app-min-floor
      (cond
        [(eq? cat 'supply) 0]
        [(and high-bank-tech-unlock? (memq cat '(combat-unit worker))) 0]
        [(eq? cat 'worker) min-floor-for-worker]
        [else min-floor]))
    (define app-gas-floor
      (cond
        [(eq? cat 'supply) 0]
        [(and high-bank-tech-unlock? (>= gas 400) (memq cat '(combat-unit worker))) 0]
        [else gas-floor]))
    (define floor-min-ok? (>= (- rem-min m-cost) app-min-floor))
    (define floor-gas-ok? (or (= g-cost 0) (>= (- rem-gas g-cost) app-gas-floor)))

    (cond
      [(and tech-cap-ok? unit-cap-ok? prereq-ok? slot-ok? worker-cap-ok? supply-ok? min-ok? gas-ok? floor-min-ok? floor-gas-ok?)
       (set! rem-min (- rem-min m-cost))
       (set! rem-gas (- rem-gas g-cost))
       (set! rem-sup (- rem-sup s-cost))
       (when (or (memq csym SC2-SINGLETON-TECH-BUILDINGS)
                 (memq csym SC2-DUAL-CAP-TECH-BUILDINGS)
                 (memq csym '(extractor refinery assimilator barracks-techlab factory factory-techlab spore-crawler)))
         (hash-update! seen-tech-counts csym add1 0))
       (when (memq csym '(queen corruptor overseer overlord-transport sentry lurker baneling zergling ghost liberator thor))
         (hash-update! seen-unit-counts csym add1 0))
       (when (memq pslot UNIT-MORPH-SOURCE-SLOTS)
         (hash-update! used-morph-slots pslot
                       (lambda (n) (+ n (if (eq? pslot 'high-templar) 2 1)))
                       0))
       (when (and rem-slots (not (eq? pslot 'worker)) (not (memq pslot UNIT-MORPH-SOURCE-SLOTS)))
         (hash-update! rem-slots pslot sub1 0))
       (set! scheduled-cands (cons c scheduled-cands))
       (set! decision-entries
             (cons (priority-decision-entry rank-idx id cat act m-cost g-cost s-cost
                                            u-score blk-ok? 'scheduled
                                            app-min-floor app-gas-floor #f)
                   decision-entries))]
      [else
       ;; If candidate is ready (`prereq-ok?` and `slot-ok?`) and `blk-ok?` (income-feasible),
       ;; and waiting on minerals or gas (with sufficient supply), reserve mineral/gas/slot escrow!
       ;; When an item already has full minerals (`rem-min >= m-cost`) and is > 40G short on gas,
       ;; lock ONLY gas (`min-escrow-amt = 0`) so 0-gas production is never mineral-starved while waiting on gas.
       (define worker-slot-escrow-ok?
         (or (not (eq? pslot 'worker))
             (not worker-build-escrowed?)))
       (define high-bank-skip-tech-escrow?
         (and (>= minerals 600)
              (>= rem-sup 2)
              ;; Do not skip escrow when a gas-costing tech/upgrade actually needs gas below high gas bank.
              (or (>= gas 400) (>= rem-gas g-cost))
              (memq cat '(tech-upgrade counter-tech production-scaling))
              (not (and node (eq? (sc2-tech-node-kind node) 'train)))))
       (define rem-escrow-plausible?
         (or (not (and (eq? cat 'expansion)
                       (>= active-bases 2)
                       (not slice15-base-loss-expand-now?)))
             (can-fund-within-frames?
              rem-min rem-gas m-cost g-cost
              mineral-harvesters gas-harvesters
              workers ready-bldg-counts race #:frames 120)))
       (define escrowed-now? #f)
       (when (and tech-cap-ok? unit-cap-ok? prereq-ok? slot-ok? worker-slot-escrow-ok? blk-ok? supply-ok?
                  rem-escrow-plausible?
                  (not high-bank-skip-tech-escrow?)
                  (or (< rem-min m-cost) (< rem-gas g-cost)))
         (define pure-gas-starved?
           (and (> g-cost 0)
                (>= rem-min m-cost)
                (< rem-gas (- g-cost 40))))
         (define min-escrow-amt (if pure-gas-starved? 0 m-cost))
         (set! min-floor (max min-floor min-escrow-amt))
         (unless (and (> g-cost 0) (< rem-gas (- g-cost 40)))
           (set! min-floor-for-worker (max min-floor-for-worker min-escrow-amt)))
         (when (> g-cost 0)
           (set! gas-floor (max gas-floor g-cost)))
         (when (and (eq? pslot 'worker) (> min-escrow-amt 0))
           (set! worker-build-escrowed? #t))
         (when (and pslot (not (memq pslot '(worker larva townhall))))
           (set! reserved-slots (cons pslot reserved-slots)))
         (set! escrowed-now? #t)
         (set! escrowed-entries (cons (list u-score min-escrow-amt g-cost id cat) escrowed-entries))
         (unless reserved-cand (set! reserved-cand c)))

       (define outcome-sym
         (cond
           [escrowed-now? 'escrowed-saving]
           [(not prereq-ok?) 'prerequisite-unmet]
           [(not slot-ok?) 'facility-busy]
           [(not supply-ok?) 'insufficient-supply]
           [(and min-ok? gas-ok? (or (not floor-min-ok?) (not floor-gas-ok?))) 'blocked-by-escrow]
           [else 'insufficient-resources]))
       (define blocked-by-id
         (and (eq? outcome-sym 'blocked-by-escrow)
              reserved-cand
              (priority-candidate-id reserved-cand)))
       (set! decision-entries
             (cons (priority-decision-entry rank-idx id cat act m-cost g-cost s-cost
                                            u-score blk-ok? outcome-sym
                                            app-min-floor app-gas-floor blocked-by-id)
                   decision-entries))]))

  ;; High-bank deadlock guard (closes any downstream reserved floor leak when minerals >= 600 & supply-left >= 2)
  (define high-bank-release?
    (high-bank-unlock-allowed? minerals 600 supply-left reserved-cand))
  (when high-bank-release?
    (set! min-floor 0)
    (when (>= gas 400)
      (set! gas-floor 0)))

  (define (tumor-direct-count sym)
    (max (if (hash? total-bldg-counts) (hash-ref total-bldg-counts sym 0) 0)
         (if (hash? ready-bldg-counts) (hash-ref ready-bldg-counts sym 0) 0)
         (if (hash? unit-counts) (hash-ref unit-counts sym 0) 0)))
  (define active-creep-tumors
    (if (eq? race 'Zerg)
        (+ (tumor-direct-count 'creep-tumor)
           (tumor-direct-count 'creep-tumor-burrowed)
           (tumor-direct-count 'creep-tumor-queen))
        0))
  (define creep-self-sustaining-now?
    (or (not (eq? race 'Zerg))
        (creep-self-sustaining? active-creep-tumors active-bases)))
  (define cur-queen-total
    (if (eq? race 'Zerg) (unit-count-equivalent unit-counts 'queen) 0))
  (define emit-creep-tumor-directive?
    (and (eq? race 'Zerg)
         (not creep-self-sustaining-now?)
         (>= cur-queen-total 1)))
  (define creep-cand
    (and emit-creep-tumor-directive?
         (priority-candidate 'spawn-creep-tumor
                             'macro-creep
                             (list 'spawn-creep-tumor nat-x nat-y)
                             0 0 0
                             540.0
                             'high-priority
                             #f)))
  (define raw-final-cands (reverse scheduled-cands))
  (define final-cands
    (if creep-cand
        (append raw-final-cands (list creep-cand))
        raw-final-cands))
  (define final-actions (map priority-candidate-action final-cands))
  (define final-ids (map priority-candidate-id final-cands))
  (define final-trace
    (let ([base-trace (reverse decision-entries)])
      (if creep-cand
          (append base-trace
                  (list (priority-decision-entry
                         1
                         'spawn-creep-tumor
                         'macro-creep
                         (priority-candidate-action creep-cand)
                         0 0 0 540.0 #f 'scheduled 0 0 #f)))
          base-trace)))
  (define final-escrowed (reverse escrowed-entries))
  (define cand-utils-mut (make-hasheq))
  (for ([c (in-list raw-cands)])
    (define cid (priority-candidate-id c))
    (define ncid (normalize-brain-sym cid))
    (define base-u (min 120.0 (priority-candidate-utility-score c)))
    (hash-set! cand-utils-mut cid base-u)
    (unless (eq? ncid cid)
      (hash-set! cand-utils-mut ncid base-u)))
  (for ([c (in-list extra-cands)])
    (define cid (priority-candidate-id c))
    (define ncid (normalize-brain-sym cid))
    (define base-u (min 120.0 (priority-candidate-utility-score c)))
    (hash-set! cand-utils-mut cid base-u)
    (unless (eq? ncid cid)
      (hash-set! cand-utils-mut ncid base-u)))
  (for ([c (in-list sorted-cands)])
    (define cid (priority-candidate-id c))
    (define ncid (normalize-brain-sym cid))
    (define u (priority-candidate-utility-score c))
    (hash-set! cand-utils-mut cid u)
    (unless (eq? ncid cid)
      (hash-set! cand-utils-mut ncid u)))
  (when creep-cand
    (hash-set! cand-utils-mut 'spawn-creep-tumor 540.0)
    (hash-set! cand-utils-mut 'creep-tumor 540.0))
  (define cand-utils (make-immutable-hasheq (hash->list cand-utils-mut)))
  (define cat-utils
    (let ([ht (make-hasheq)])
      (hash-set! ht 'decision-trace final-trace)
      (hash-set! ht 'escrowed-entries final-escrowed)
      (hash-set! ht 'candidate-utilities cand-utils)
      (hash-set! ht 'reserved-min-floor min-floor)
      (hash-set! ht 'reserved-gas-floor gas-floor)
      (hash-set! ht 'dynamic-plan dyn-plan)
      (hash-set! ht 'opp-commitment-ht opp-commitment-ht)
      (hash-set! ht 'loss-recovery-ht loss-recovery-ht)
      (hash-set! ht 'loss-recovery-mode loss-recovery-mode)
      (hash-set! ht 'unlock-locked-path? (or lr-unlock-locked-path? opp-cap-air-override?))
      (hash-set! ht 'suppressed-non-counter-units slice15-all-suppressed-units)
      (hash-set! ht 'active-creep-tumors active-creep-tumors)
      (hash-set! ht 'creep-self-sustaining? creep-self-sustaining-now?)
      (for ([c (in-list sorted-cands)])
        (define cat (priority-candidate-category c))
        (define u (priority-candidate-utility-score c))
        (when (> u (hash-ref ht cat -inf.0))
          (hash-set! ht cat u)))
      (make-immutable-hasheq (hash->list ht))))

  (define sched-result
    (priority-schedule-result final-actions
                              final-cands
                              reserved-cand
                              rem-min
                              rem-gas
                              rem-sup
                              cat-utils))
  (define bo-goal-deadlocked?
    (and bo-goal-sym
         (not reserved-cand)
         (not (ormap (lambda (s) (same-brain-sym? s bo-goal-sym)) final-ids))
         (let ([g-mcost (sc2-min-cost bo-goal-sym 0)]
               [g-gcost (sc2-gas-cost bo-goal-sym 0)])
           (or (<= workers 0)
               (and (< minerals g-mcost) (not has-mineral-income?))
               (and (> g-gcost 0) (< gas g-gcost) (not has-gas-income?))))))
  (define final-effective-bo-goal
    (if bo-goal-deadlocked? #f effective-bo-goal))
  (define final-bo-goal-sym
    (and (pro-bo-goal? final-effective-bo-goal)
         (pro-bo-goal-target-sym final-effective-bo-goal)))
  (define final-bo-sup-cost
    (if (and (pro-bo-goal? final-effective-bo-goal)
             (eq? (pro-bo-goal-kind final-effective-bo-goal) 'train))
        (sc2-supply-cost final-bo-goal-sym 0)
        0))
  (define supply-scheduled-this-step?
    (ormap (lambda (s) (memq (normalize-brain-sym s) '(overlord pylon supply-depot))) final-ids))
  (define supply-preempt-saving?
    (and supply-preempt-now? (not supply-scheduled-this-step?)))
  (define final-bo-goal-norm
    (and final-bo-goal-sym (normalize-brain-sym final-bo-goal-sym)))
  (define final-bo-is-supply?
    (not (not (memq final-bo-goal-norm '(overlord pylon supply-depot)))))
  (define final-bo-is-nat-expand?
    (and natural-exp-window? (eq? final-bo-goal-norm race-expand-sym)))
  (define final-bo-eligible-for-saving-fallback?
    (and has-mineral-income?
         final-bo-goal-sym
         (not supply-preempt-saving?)
         (or (not supply-preempt-now?)
             final-bo-is-supply?
             final-bo-is-nat-expand?)
         (not (macro-escrow-in-backoff? escrow-state-entry frame final-bo-goal-sym))
         (upgrade-allowed-by-unit-and-order-gates?
          race final-bo-goal-sym frame workers
          ready-bldg-counts total-bldg-counts unit-counts
          researched-upgrades pending-upgrades)
         (or final-bo-is-supply?
             final-bo-is-nat-expand?
             (can-fund-within-frames?
              rem-min rem-gas (sc2-min-cost final-bo-goal-sym 0) (sc2-gas-cost final-bo-goal-sym 0)
              mineral-harvesters gas-harvesters
              workers ready-bldg-counts race #:frames 120))
         (<= final-bo-sup-cost supply-left)
         (not (and (memq final-bo-goal-sym '(hatchery nexus command-center))
                   (hash? open-facility-slots)
                   (>= active-bases 2)
                   (not (eq? race 'Zerg))
                   (< army-supply 10)
                   (< rem-min 550)))))
   (define saving-id
     (let ([high-bank-tech-release?
            (and (not supply-preempt-saving?)
                 (>= minerals 600)
                 (>= supply-left 2)
                 (or (>= gas 400) (<= gas-floor 0))
                 (if reserved-cand
                     (memq (priority-candidate-category reserved-cand)
                           '(tech-upgrade counter-tech production-scaling))
                     (not (memq final-bo-goal-sym '(overlord pylon supply-depot)))))])
       (cond
         [supply-preempt-saving? race-supply-sym]
         [high-bank-tech-release? 'none]
         [reserved-cand (priority-candidate-id reserved-cand)]
         [final-bo-eligible-for-saving-fallback? final-bo-goal-sym]
         [else 'none])))
  (define out-min-floor (if supply-preempt-saving? 100 min-floor))
  (define out-gas-floor (if supply-preempt-saving? 0 gas-floor))
  (define out-reserved-slots (if supply-preempt-saving? '() (reverse reserved-slots)))
  (macro-escrow-record-decision! race enemy-race frame minerals eff-th-total-cnt saving-id final-ids)
  (define log-str
    (format-priority-schedule-log-line
     sched-result
     #:frame frame
     #:race race
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:bo-goal-sym (and has-mineral-income? (not supply-preempt-saving?) final-bo-goal-sym)
     #:bo-reserved-min out-min-floor
     #:bo-reserved-gas out-gas-floor))

  (define reported-effective-bo-goal
    (if (and (not bo-goal-deadlocked?)
             (pro-bo-goal? final-effective-bo-goal)
             (<= (pro-bo-goal-target-sec final-effective-bo-goal) 0.0)
             timed-bo-display-goal)
        timed-bo-display-goal
        final-effective-bo-goal))
  (macro-brain-decision
   final-actions
   final-ids
   saving-id
   out-min-floor
   out-gas-floor
   out-reserved-slots
   reported-effective-bo-goal
   repaired-prereqs
   sched-result
   log-str)))

;; Return #t when bank/supply high-bank unlock applies without breaking supply escrow.
(define (high-bank-unlock-allowed? bank-amt threshold rem-sup reserved-cand)
  (and (>= bank-amt threshold)
       (>= rem-sup 2)
       (not (and reserved-cand
                 (eq? (priority-candidate-category reserved-cand) 'supply)))))

;; Per-game escrow age & 112-frame re-escrow backoff tracker for Bug 3 Rule 2.
;; Keys: (list race enemy-race) -> (hash 'last-frame f 'active-id sym 'start-frame f 'peak-min m 'backoff-ht (hash sym -> until-frame))
(define *macro-escrow-state-ht* (make-hash))

(define (reset-macro-escrow-tracker!)
  (hash-clear! *macro-escrow-state-ht*))

(define (macro-escrow-sync-entry! race enemy-race frame minerals total-th)
  (define key (list race enemy-race))
  (define prev (hash-ref *macro-escrow-state-ht* key #f))
  (define last-f (if prev (hash-ref prev 'last-frame -9999) -9999))
  (define new-game?
    (or (not prev)
        (< frame last-f)
        (and (<= frame 16) (> last-f 32))))
  (define cur
    (if new-game?
        (hash 'last-frame frame
              'active-id #f
              'start-frame frame
              'start-min minerals
              'peak-min minerals
              'th-count total-th
              'backoff-ht (hash))
        (let* ([aid (hash-ref prev 'active-id #f)]
               [sf (hash-ref prev 'start-frame frame)]
               [sm (hash-ref prev 'start-min minerals)]
               [pm (hash-ref prev 'peak-min minerals)]
               [prev-th (hash-ref prev 'th-count total-th)]
               [bht0 (hash-ref prev 'backoff-ht (hash))]
               [bht (for/hash ([(k until) (in-hash bht0)]
                               #:when (< frame until))
                      (values k until))]
               [nat-age
                (if (and aid
                         (memq aid '(hatchery nexus command-center))
                         (< total-th 2)
                         (= total-th prev-th)
                         (> minerals sm))
                    (if (>= minerals 200) 672 448)
                    MAX-ESCROW-AGE-FRAMES)]
               [expired? (and aid (>= (- frame sf) nat-age))])
          (if expired?
              (hash 'last-frame frame
                    'active-id #f
                    'start-frame frame
                    'start-min minerals
                    'peak-min minerals
                    'th-count total-th
                    'backoff-ht (hash-set bht aid (+ frame ESCROW-EXPIRATION-BACKOFF-FRAMES)))
              (hash 'last-frame frame
                    'active-id aid
                    'start-frame sf
                    'start-min sm
                    'peak-min (max pm minerals)
                    'th-count total-th
                    'backoff-ht bht)))))
  (hash-set! *macro-escrow-state-ht* key cur)
  cur)

(define (macro-escrow-record-decision! race enemy-race frame minerals total-th saving-id scheduled-ids)
  (define key (list race enemy-race))
  (define cur (hash-ref *macro-escrow-state-ht* key #f))
  (when cur
    (define prev-aid (hash-ref cur 'active-id #f))
    (define bht (hash-ref cur 'backoff-ht (hash)))
    (define norm-save
      (if (and saving-id (not (eq? saving-id 'none)))
          (normalize-brain-sym saving-id)
          #f))
    (define sched-norm?
      (and norm-save
           (ormap (lambda (s) (eq? (normalize-brain-sym s) norm-save)) scheduled-ids)))
    (define next-aid
      (if (and norm-save
               (not sched-norm?)
               (not (memq norm-save '(overlord pylon supply-depot))))
          norm-save
          #f))
    (define next-sf
      (cond
        [(not next-aid) frame]
        [(eq? next-aid prev-aid) (hash-ref cur 'start-frame frame)]
        [else frame]))
    (define next-sm
      (cond
        [(not next-aid) minerals]
        [(eq? next-aid prev-aid) (hash-ref cur 'start-min minerals)]
        [else minerals]))
    (define next-pm
      (cond
        [(not next-aid) minerals]
        [(eq? next-aid prev-aid) (max (hash-ref cur 'peak-min minerals) minerals)]
        [else minerals]))
    (hash-set! *macro-escrow-state-ht* key
               (hash 'last-frame frame
                     'active-id next-aid
                     'start-frame next-sf
                     'start-min next-sm
                     'peak-min next-pm
                     'th-count total-th
                     'backoff-ht bht))))

(define (macro-escrow-in-backoff? escrow-entry frame id)
  (define bht (if escrow-entry (hash-ref escrow-entry 'backoff-ht (hash)) (hash)))
  (define nid (normalize-brain-sym id))
  (< frame (hash-ref bht nid 0)))

(define (macro-brain-can-spend? decision id-sym cur-min cur-gas [cat-sym 'combat-unit])
  (define norm-id (normalize-brain-sym id-sym))
  (define node (lookup-sc2-tech-node norm-id))
  (define m-cost (if node (sc2-tech-node-min-cost node) (sc2-min-cost norm-id 0)))
  (define g-cost (if node (sc2-tech-node-gas-cost node) (sc2-gas-cost norm-id 0)))
  (define pslot (and node (sc2-tech-node-producer-slot node)))
  (define slot-blocked-by-escrow?
    (and node
         (memq (sc2-tech-node-kind node) '(research addon))
         pslot
         (memq pslot (macro-brain-decision-reserved-slots decision))
         (not (ormap (lambda (s) (same-brain-sym? norm-id s))
                     (macro-brain-decision-scheduled-ids decision)))))
  (define high-bank-tech-unlock?
    (and (>= cur-min 600)
         (or (= g-cost 0)
             (>= cur-gas 400)
             (<= (macro-brain-decision-reserved-gas-floor decision) 0))
         (not (memq (macro-brain-decision-saving-for decision) '(overlord pylon supply-depot)))))
  (and (>= cur-min m-cost)
       (>= cur-gas g-cost)
       (or (eq? cat-sym 'supply)
           high-bank-tech-unlock?
           (same-brain-sym? norm-id (macro-brain-decision-saving-for decision))
           (ormap (lambda (r) (same-brain-sym? norm-id r))
                  (macro-brain-decision-repaired-prereqs decision))
           (and (not slot-blocked-by-escrow?)
                (let* ([sched (macro-brain-decision-priority-schedule decision)]
                       [cat-ht (if (priority-schedule-result? sched)
                                   (priority-schedule-result-category-utilities sched)
                                   (hash))]
                       [escrowed (if (hash? cat-ht) (hash-ref cat-ht 'escrowed-entries '()) '())]
                       [cat-Lookup-u (and (hash? cat-ht)
                                          (let ([cu-map (hash-ref cat-ht 'candidate-utilities (hash))])
                                            (hash-ref cu-map norm-id #f)))]
                       [sched-eff
                        (if (or cat-Lookup-u (not (priority-schedule-result? sched)) (not (hash? cat-ht)))
                            sched
                            (let ([cu-map (hash-ref cat-ht 'candidate-utilities (hash))])
                              (struct-copy priority-schedule-result sched
                                           [category-utilities
                                            (hash-set cat-ht 'candidate-utilities
                                                      (hash-set cu-map norm-id
                                                                (if (eq? cat-sym 'worker) 65.0 110.0)))])))])
                  (define bo-goal (macro-brain-decision-bo-active-goal decision))
                  (define bo-sym (and (pro-bo-goal? bo-goal) (pro-bo-goal-target-sym bo-goal)))
                  (priority-schedule-can-spend?
                   sched-eff norm-id cur-min cur-gas
                   #:category cat-sym
                   #:min-cost m-cost
                   #:gas-cost g-cost
                   #:bo-goal-sym bo-sym
                   #:bo-reserved-min (if (pair? escrowed) 0 (macro-brain-decision-reserved-min-floor decision))
                   #:bo-reserved-gas (if (pair? escrowed) 0 (macro-brain-decision-reserved-gas-floor decision))))))))

;; =============================================================================
;; 3. Fast Standalone Macro Simulator & Chaos Monkey Engine
;; =============================================================================
;; Simulates build orders and priority brain decisions at >10,000 frames/sec
;; without SC2_x64 or tactical/perception layers, including randomized Chaos
;; Monkey deletions of units, add-ons, and buildings (preserving main townhall).

(struct macro-sim-task
  (id             ;; symbol (e.g. 'spawning-pool, 'drone, 'stimpack)
   kind           ;; 'train | 'build | 'expand | 'morph | 'research | 'addon
   producer-slot  ;; symbol
   complete-frame ;; exact integer
   supply-add)    ;; exact nonnegative integer
  #:transparent)

(struct chaos-monkey-event
  (frame          ;; exact integer
   deleted-kind   ;; 'worker | 'supply | 'addon | 'tech-building | 'gas-building | 'expansion | 'combat-unit
   deleted-sym    ;; symbol
   deleted-count  ;; exact positive integer
   state-summary) ;; string
  #:transparent)

(struct macro-sim-state
  (race
   enemy-race
   frame
   minerals
   gas
   min-frac
   gas-frac
   ready-buildings   ;; mutable hash: symbol -> count
   in-progress-tasks ;; list of macro-sim-task
   units             ;; mutable hash: symbol -> count
   researched-upgs   ;; list of symbols
   larvae            ;; exact nonnegative integer (Zerg)
   peak-supply       ;; exact nonnegative integer
   chaos-events      ;; list of chaos-monkey-event
   priority-logs)    ;; list of [SCBOT_PRIORITY] strings
  #:mutable
  #:transparent)

(struct chaos-monkey-trial-result
  (race
   enemy-race
   seed
   frames-simulated
   chaos-deletions-count
   chaos-events
   recovered-all-bo-goals?
   unsatisfied-bo-goals
   final-workers
   final-bases
   final-supply-used
   final-supply-cap
   final-army-supply
   final-researched-upgrades
   final-ready-buildings
   sample-priority-logs)
  #:transparent)

(define (make-initial-macro-sim-state race [enemy-race 'Unknown] #:seed [seed 0])
  (define r-sym
    (case race
      [(Zerg zerg ZvZ ZvT ZvP) 'Zerg]
      [(Terran terran TvZ TvT TvP) 'Terran]
      [(Protoss protoss PvZ PvT PvP) 'Protoss]
      [(Random random RvZ RvT RvP)
       (list-ref '(Zerg Terran Protoss) (modulo (abs seed) 3))]
      [else 'Protoss]))
  (define resolved-enemy-race
    (if (not (eq? enemy-race 'Unknown))
        enemy-race
        (case race
          [(ZvZ TvZ PvZ RvZ) 'Zerg]
          [(ZvT TvT PvT RvT) 'Terran]
          [(ZvP TvP PvP RvP) 'Protoss]
          [else 'Unknown])))
  (define rb (make-hasheq))
  (define un (make-hasheq))
  (case r-sym
    [(Zerg)
     (hash-set! rb 'hatchery 1)
     (hash-set! un 'drone 12)
     (hash-set! un 'overlord 1)]
    [(Terran)
     (hash-set! rb 'command-center 1)
     (hash-set! un 'scv 12)]
    [else
     (hash-set! rb 'nexus 1)
     (hash-set! un 'probe 12)])
  (macro-sim-state r-sym resolved-enemy-race 0 50 0 0.0 0.0 rb '() un '() 3 12 '() '()))

(define (sim-recompute-supply st)
  (define rb (macro-sim-state-ready-buildings st))
  (define un (macro-sim-state-units st))
  (define tasks (macro-sim-state-in-progress-tasks st))
  ;; Supply cap from ready townhalls + supply providers
  (define cap-raw
    (+ (* 6 (+ (hash-ref rb 'hatchery 0) (hash-ref rb 'lair 0) (hash-ref rb 'hive 0)))
       (* 15 (+ (hash-ref rb 'command-center 0) (hash-ref rb 'orbital-command 0) (hash-ref rb 'planetary-fortress 0)))
       (* 15 (hash-ref rb 'nexus 0))
       (* 8 (+ (hash-ref un 'overlord 0)
               (hash-ref un 'overseer 0)
               (hash-ref un 'overlord-transport 0)
               (for/sum ([t (in-list tasks)]
                         #:when (memq (macro-sim-task-id t) '(overseer overlord-transport)))
                 1)))
       (* 8 (+ (hash-ref rb 'supply-depot 0) (hash-ref rb 'supply-depot-lowered 0)))
       (* 8 (hash-ref rb 'pylon 0))))
  (define supply-cap (min 200 cap-raw))
  ;; Supply used from alive units + in-progress unit trainings/morphs
  (define used-alive
    (for/sum ([(sym cnt) (in-hash un)])
      (define node (lookup-sc2-tech-node sym))
      (* cnt (if node (sc2-tech-node-supply-cost node) 0))))
  (define used-pending
    (for/sum ([t (in-list tasks)])
      (define node (lookup-sc2-tech-node (macro-sim-task-id t)))
      (if (and node
               (or (eq? (sc2-tech-node-kind node) 'train)
                   (and (eq? (sc2-tech-node-kind node) 'morph)
                        (memq (sc2-tech-node-producer-slot node)
                              '(roach zergling hydralisk corruptor)))))
          (sc2-tech-node-supply-cost node)
          0)))
  (define supply-used (+ used-alive used-pending))
  (define army-sup
    (for/sum ([(sym cnt) (in-hash un)]
              #:when (not (memq sym '(drone scv probe overlord))))
      (define node (lookup-sc2-tech-node sym))
      (* cnt (if node (sc2-tech-node-supply-cost node) 0))))
  (values supply-used supply-cap (- supply-cap supply-used) army-sup))

(define (sim-state->macro-world-state st
                                      #:under-attack? [under-attack? #f]
                                      #:requires-anti-air? [requires-anti-air? #f]
                                      #:requires-detection? [requires-detection? #f])
  (define race (macro-sim-state-race st))
  (define rb (macro-sim-state-ready-buildings st))
  (define un (macro-sim-state-units st))
  (define tasks (macro-sim-state-in-progress-tasks st))
  (define-values (sup-used sup-cap sup-left army-sup) (sim-recompute-supply st))

  (define ready-ht (for/hasheq ([(k v) (in-hash rb)] #:when (> v 0)) (values k v)))
  (define total-ht
    (for/fold ([ht ready-ht]) ([t (in-list tasks)])
      (define tid (macro-sim-task-id t))
      (define tkind (macro-sim-task-kind t))
      (if (memq tkind '(build expand morph addon))
          (hash-update ht tid add1 0)
          ht)))
  (define unit-ht
    (for/fold ([ht (for/hasheq ([(k v) (in-hash un)] #:when (> v 0)) (values k v))])
              ([t (in-list tasks)])
      (define tid (macro-sim-task-id t))
      (define tkind (macro-sim-task-kind t))
      (if (or (eq? tkind 'train)
              (and (eq? tkind 'morph)
                   (not (memq tid '(lair hive greater-spire orbital-command planetary-fortress)))))
          (hash-update ht tid add1 0)
          ht)))
  (define pend-upgs
    (for/list ([t (in-list tasks)]
               #:when (eq? (macro-sim-task-kind t) 'research))
      (macro-sim-task-id t)))
  (define pend-sup
    (for/sum ([t (in-list tasks)]
              #:when (> (macro-sim-task-supply-add t) 0))
      1))

  ;; Compute open facility/research slots
  (define busy-by-slot
    (for/fold ([ht (hasheq)]) ([t (in-list tasks)])
      (hash-update ht (macro-sim-task-producer-slot t) add1 0)))
  (define open-slots (make-hasheq))
  (define th-count
    (+ (bldg-count-equivalent ready-ht 'hatchery)
       (bldg-count-equivalent ready-ht 'command-center)
       (bldg-count-equivalent ready-ht 'nexus)))
  (hash-set! open-slots 'townhall (max 0 (- th-count (hash-ref busy-by-slot 'townhall 0))))
  (hash-set! open-slots 'larva (macro-sim-state-larvae st))
  (for ([fac-sym (in-list '(barracks barracks-techlab factory factory-techlab starport starport-techlab
                            gateway robotics-facility robotics-bay stargate fleet-beacon
                            cybernetics-core twilight-council templar-archive dark-shrine forge
                            spawning-pool roach-warren baneling-nest hydralisk-den lurker-den
                            infestation-pit spire greater-spire ultralisk-cavern evolution-chamber
                            engineering-bay armory ghost-academy fusion-core))])
    (define cap
      (case fac-sym
        [(barracks)
         (+ (bldg-count-equivalent ready-ht 'barracks)
            (bldg-count-equivalent ready-ht 'barracks-reactor))]
        [(factory)
         (+ (bldg-count-equivalent ready-ht 'factory)
            (bldg-count-equivalent ready-ht 'factory-reactor))]
        [(starport)
         (+ (bldg-count-equivalent ready-ht 'starport)
            (bldg-count-equivalent ready-ht 'starport-reactor))]
        [else
         (bldg-count-equivalent ready-ht fac-sym)]))
    (hash-set! open-slots fac-sym (max 0 (- cap (hash-ref busy-by-slot fac-sym 0)))))
  (hash-set! open-slots 'roach (hash-ref un 'roach 0))
  (hash-set! open-slots 'zergling (hash-ref un 'zergling 0))
  (hash-set! open-slots 'hydralisk (hash-ref un 'hydralisk 0))
  (hash-set! open-slots 'corruptor (hash-ref un 'corruptor 0))
  (hash-set! open-slots 'overlord (hash-ref un 'overlord 0))

  (define w-sym (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
  (define g-sym (case race [(Zerg) 'extractor] [(Terran) 'refinery] [else 'assimilator]))
  (define workers (hash-ref unit-ht w-sym 0))
  (define alive-w (hash-ref un w-sym 0))
  (define ready-g (bldg-count-equivalent ready-ht g-sym))
  (define sim-gas-w
    (if (<= alive-w 6)
        0
        (min (* 3 ready-g) (max 0 (exact-floor (* 0.32 (- alive-w 4)))))))
  (define sim-min-w (max 0 (- alive-w sim-gas-w)))
  (define th-sym (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
  (define active-bases (max 1 (bldg-count-equivalent total-ht th-sym)))

  (make-macro-world-state
   #:race race
   #:enemy-race (macro-sim-state-enemy-race st)
   #:frame (macro-sim-state-frame st)
   #:minerals (macro-sim-state-minerals st)
   #:gas (macro-sim-state-gas st)
   #:supply-used sup-used
   #:supply-cap sup-cap
   #:supply-left sup-left
   #:pending-supply pend-sup
   #:workers workers
   #:active-bases active-bases
   #:gas-harvesters sim-gas-w
   #:mineral-harvesters sim-min-w
   #:ready-building-counts ready-ht
   #:total-building-counts total-ht
   #:unit-counts unit-ht
   #:researched-upgrades (macro-sim-state-researched-upgs st)
   #:pending-upgrades pend-upgs
   #:open-facility-slots (for/hasheq ([(k v) (in-hash open-slots)]) (values k v))
   #:army-supply army-sup
   #:enemy-threat-supply (if under-attack? (max 6 (+ army-sup 4)) 0)
   #:under-attack? under-attack?
   #:requires-anti-air? requires-anti-air?
   #:requires-detection? requires-detection?
   #:supply-at-risk? (< sup-left 0)
   #:peak-supply-reached (macro-sim-state-peak-supply st)))

;; Chaos Monkey Deletion Operator:
;; Randomly deletes units, add-ons, or buildings (always preserving 1 main starting townhall).
(define (chaos-monkey-delete! st rng
                              #:target-category [forced-cat #f]
                              #:severity [severity 0.5])
  (define race (macro-sim-state-race st))
  (define frame (macro-sim-state-frame st))
  (define rb (macro-sim-state-ready-buildings st))
  (define un (macro-sim-state-units st))
  (define w-sym (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
  (define main-th-sym (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))

  ;; Build list of deletable targets currently present in `st`
  (define deletable-candidates '())

  ;; 1. Workers (can delete up to 85% of workers, or down to 0 if minerals >= 50)
  (define cur-workers (hash-ref un w-sym 0))
  (when (> cur-workers 1)
    (set! deletable-candidates (cons (list 'worker w-sym cur-workers) deletable-candidates)))

  ;; 2. Supply providers (`overlord`, `supply-depot`, `pylon`)
  (case race
    [(Zerg)
     (when (> (hash-ref un 'overlord 0) 0)
       (set! deletable-candidates (cons (list 'supply 'overlord (hash-ref un 'overlord 0)) deletable-candidates)))]
    [(Terran)
     (when (> (hash-ref rb 'supply-depot 0) 0)
       (set! deletable-candidates (cons (list 'supply 'supply-depot (hash-ref rb 'supply-depot 0)) deletable-candidates)))]
    [else
     (when (> (hash-ref rb 'pylon 0) 0)
       (set! deletable-candidates (cons (list 'supply 'pylon (hash-ref rb 'pylon 0)) deletable-candidates)))])

  ;; 3. Add-ons (`barracks-techlab`, `barracks-reactor`, `factory-techlab`, `starport-reactor`, `starport-techlab`)
  (for ([asym (in-list '(barracks-techlab barracks-reactor factory-techlab factory-reactor starport-reactor starport-techlab))])
    (when (> (hash-ref rb asym 0) 0)
      (set! deletable-candidates (cons (list 'addon asym (hash-ref rb asym 0)) deletable-candidates))))

  ;; 4. Gas buildings (`extractor`, `refinery`, `assimilator`)
  (for ([gsym (in-list '(extractor refinery assimilator))])
    (when (> (hash-ref rb gsym 0) 0)
      (set! deletable-candidates (cons (list 'gas-building gsym (hash-ref rb gsym 0)) deletable-candidates))))

  ;; 5. Tech & Production Buildings (excluding main starting townhall)
  (for ([bsym (in-list '(spawning-pool roach-warren baneling-nest evolution-chamber hydralisk-den lurker-den
                         infestation-pit spire ultralisk-cavern spine-crawler spore-crawler
                         barracks factory starport engineering-bay armory ghost-academy fusion-core bunker missile-turret
                         gateway cybernetics-core robotics-facility robotics-bay stargate fleet-beacon
                         twilight-council templar-archive dark-shrine forge photon-cannon shield-battery))])
    (when (> (hash-ref rb bsym 0) 0)
      (set! deletable-candidates (cons (list 'tech-building bsym (hash-ref rb bsym 0)) deletable-candidates))))

  ;; 6. Expansion Townhalls (only if total townhalls > 1 so main starting townhall is NEVER deleted!)
  (define total-ths (bldg-count-equivalent rb main-th-sym))
  (when (> total-ths 1)
    (when (> (hash-ref rb main-th-sym 0) 1)
      (set! deletable-candidates (cons (list 'expansion main-th-sym (sub1 (hash-ref rb main-th-sym 0))) deletable-candidates))))

  ;; 7. Combat units & Queens
  (for ([(usym cnt) (in-hash un)]
        #:when (and (> cnt 0) (not (memq usym (list w-sym 'overlord)))))
    (set! deletable-candidates (cons (list 'combat-unit usym cnt) deletable-candidates)))

  (define filtered
    (if forced-cat
        (let ([f (filter (lambda (x) (eq? (first x) forced-cat)) deletable-candidates)])
          (if (null? f) deletable-candidates f))
        deletable-candidates))

  (cond
    [(null? filtered) #f]
    [else
     (define idx (random (length filtered) rng))
     (match-define (list dkind dsym avail-cnt) (list-ref filtered idx))
     (define del-cnt
       (case dkind
         [(worker)
          (define max-del
            (if (>= (macro-sim-state-minerals st) 50)
                avail-cnt ;; Can even wipe to 0 workers if >= 50M in bank!
                (max 1 (sub1 avail-cnt))))
          (max 1 (min max-del (exact-ceiling (* severity avail-cnt))))]
         [(expansion) 1]
         [else (max 1 (min avail-cnt (exact-ceiling (* severity avail-cnt))))]))

     ;; Apply deletion to `un` or `rb`
     (if (memq dkind '(worker combat-unit))
         (hash-set! un dsym (max 0 (- (hash-ref un dsym 0) del-cnt)))
         (if (and (eq? dkind 'supply) (eq? dsym 'overlord))
             (hash-set! un 'overlord (max 0 (- (hash-ref un 'overlord 0) del-cnt)))
             (hash-set! rb dsym (max (if (eq? dsym main-th-sym) 1 0)
                                     (- (hash-ref rb dsym 0) del-cnt)))))

     ;; If a parent building was deleted (e.g., all Barracks deleted), also delete orphaned add-ons
     (when (and (eq? dsym 'barracks) (= (hash-ref rb 'barracks 0) 0))
       (hash-set! rb 'barracks-techlab 0)
       (hash-set! rb 'barracks-reactor 0))
     (when (and (eq? dsym 'factory) (= (hash-ref rb 'factory 0) 0))
       (hash-set! rb 'factory-techlab 0)
       (hash-set! rb 'factory-reactor 0))
     (when (and (eq? dsym 'starport) (= (hash-ref rb 'starport 0) 0))
       (hash-set! rb 'starport-techlab 0)
       (hash-set! rb 'starport-reactor 0))

     (define-values (su sc sl _as) (sim-recompute-supply st))
     (define ev
       (chaos-monkey-event
        frame dkind dsym del-cnt
        (format "f=~a deleted ~ax ~a (~a) -> sup=~a/~a(left=~a) workers=~a bank=~aM/~aG"
                frame del-cnt dsym dkind su sc sl
                (hash-ref un w-sym 0)
                (macro-sim-state-minerals st)
                (macro-sim-state-gas st))))
     (set-macro-sim-state-chaos-events! st (cons ev (macro-sim-state-chaos-events st)))
     ev]))

;; Advances `macro-sim-state` by `dt-frames` (default 8 frames = 0.357s):
;; 1. Completes finished tasks (`complete-frame <= frame`)
;; 2. Harvests minerals & gas from active workers (`min-workers` + `gas-workers`)
;; 3. Regenerates Zerg larvae (Hatchery passive + Queen inject)
;; 4. Runs `step-priority-macro-brain` on the pure `macro-world-state`
;; 5. Executes all scheduled actions (`scheduled-ids`), deducting costs and queueing `macro-sim-task`s
(define (step-macro-sim! st [dt-frames 8]
                         #:under-attack? [under-attack? #f]
                         #:requires-anti-air? [requires-anti-air? #f]
                         #:requires-detection? [requires-detection? #f])
  (define race (macro-sim-state-race st))
  (define frame (+ (macro-sim-state-frame st) dt-frames))
  (set-macro-sim-state-frame! st frame)
  (define rb (macro-sim-state-ready-buildings st))
  (define un (macro-sim-state-units st))

  ;; 1. Complete finished construction / training / morph / research tasks
  (define-values (done-tasks rem-tasks)
    (partition (lambda (t) (<= (macro-sim-task-complete-frame t) frame))
               (macro-sim-state-in-progress-tasks st)))
  (set-macro-sim-state-in-progress-tasks! st rem-tasks)
  (for ([t (in-list done-tasks)])
    (define tid (macro-sim-task-id t))
    (define tkind (macro-sim-task-kind t))
    (case tkind
      [(build expand addon)
       (hash-update! rb tid add1 0)]
      [(morph)
       (case tid
        [(lair)
          (when (> (hash-ref rb 'hatchery 0) 0)
            (hash-update! rb 'hatchery sub1 0))
          (hash-update! rb 'lair add1 0)]
        [(hive)
          (when (> (hash-ref rb 'lair 0) 0)
            (hash-update! rb 'lair sub1 0))
          (hash-update! rb 'hive add1 0)]
        [(greater-spire)
          (when (> (hash-ref rb 'spire 0) 0)
            (hash-update! rb 'spire sub1 0))
          (hash-update! rb 'greater-spire add1 0)]
        [(orbital-command)
          (when (> (hash-ref rb 'command-center 0) 0)
            (hash-update! rb 'command-center sub1 0))
          (hash-update! rb 'orbital-command add1 0)]
        [(planetary-fortress)
          (when (> (hash-ref rb 'command-center 0) 0)
            (hash-update! rb 'command-center sub1 0))
          (hash-update! rb 'planetary-fortress add1 0)]
         [else
          (hash-update! un tid add1 0)])]
      [(train)
       (hash-update! un tid add1 0)]
      [(research)
       (set-macro-sim-state-researched-upgs!
        st (remove-duplicates (cons tid (macro-sim-state-researched-upgs st)) eq?))]))

  ;; 2. Resource harvesting (LotV rates: ~1.05 M/worker/sec, ~0.95 G/gas-worker/sec)
  (define w-sym (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
  (define g-sym (case race [(Zerg) 'extractor] [(Terran) 'refinery] [else 'assimilator]))
  (define total-w (hash-ref un w-sym 0))
  (define ready-g (bldg-count-equivalent rb g-sym))
  ;; Gas worker allocation: never pull workers into gas if total-w <= 6, leaving >= 4 on minerals!
  (define gas-w
    (if (<= total-w 6)
        0
        (min (* 3 ready-g) (max 0 (exact-floor (* 0.32 (- total-w 4)))))))
  (define min-w (max 0 (- total-w gas-w)))
  (define dt-sec (/ (exact->inexact dt-frames) 22.4))
  (define m-0 (+ (macro-sim-state-min-frac st) (* min-w 1.08 dt-sec)
                 ;; Orbital Command MULE bonus (~3.5 worker equivalents per Orbital)
                 (* (bldg-count-equivalent rb 'orbital-command) 3.2 dt-sec)))
  (define g-0 (+ (macro-sim-state-gas-frac st) (* gas-w 0.98 dt-sec)))
  (define m-add (exact-floor m-0))
  (define g-add (exact-floor g-0))
  (set-macro-sim-state-minerals! st (+ (macro-sim-state-minerals st) m-add))
  (set-macro-sim-state-gas! st (+ (macro-sim-state-gas st) g-add))
  (set-macro-sim-state-min-frac! st (- m-0 m-add))
  (set-macro-sim-state-gas-frac! st (- g-0 g-add))

  ;; 3. Zerg larva regeneration (1 per hatchery + Queen inject bonus)
  (when (eq? race 'Zerg)
    (define ths (bldg-count-equivalent rb 'hatchery))
    (define queens (hash-ref un 'queen 0))
    (when (zero? (modulo frame 120))
      (set-macro-sim-state-larvae!
       st (min (* 19 (max 1 ths))
               (+ (macro-sim-state-larvae st) ths (* 2 (min ths queens)))))))

  ;; Update peak supply watermark
  (define-values (su _sc _sl _as) (sim-recompute-supply st))
  (when (> su (macro-sim-state-peak-supply st))
    (set-macro-sim-state-peak-supply! st su))

  ;; 4. Run the pure Core Priority & Build-Order Brain
  (define wstate
    (sim-state->macro-world-state
     st
     #:under-attack? under-attack?
     #:requires-anti-air? requires-anti-air?
     #:requires-detection? requires-detection?))
  (define decision (step-priority-macro-brain wstate))

  (when (zero? (modulo frame 160))
    (set-macro-sim-state-priority-logs!
     st (cons (macro-brain-decision-log-line decision)
              (macro-sim-state-priority-logs st))))

  ;; 5. Execute scheduled candidates (allowing multi-larva / multi-townhall / multi-facility
  ;;    training up to open producer slots while respecting reserved-min-floor & reserved-gas-floor,
  ;;    matching `bot-runtime.rkt`'s actuator loop).
  (define min-flr (macro-brain-decision-reserved-min-floor decision))
  (define gas-flr (macro-brain-decision-reserved-gas-floor decision))
  (define open-slots-ht (hash-copy (macro-world-state-open-facility-slots wstate)))
  (define-values (cur-su cur-sc cur-sl _cur-as) (sim-recompute-supply st))
  (define rem-sup-sim cur-sl)

  (for ([sym (in-list (macro-brain-decision-scheduled-ids decision))])
    (define node (lookup-sc2-tech-node sym))
    (when node
      (define kind (sc2-tech-node-kind node))
      (define cat (sc2-tech-node-category node))
      (define pslot (sc2-tech-node-producer-slot node))
      (define m-cost (sc2-tech-node-min-cost node))
      (define g-cost (sc2-tech-node-gas-cost node))
      (define s-cost (sc2-tech-node-supply-cost node))
      (define max-iters
        (if (memq cat '(worker combat-unit))
            (min 3 (max 1 (hash-ref open-slots-ht pslot 1)))
            1))
      (for ([iter (in-range max-iters)])
        (define slot-avail (if (eq? pslot 'worker) (hash-ref un w-sym 0) (hash-ref open-slots-ht pslot 0)))
        (define floor-ok?
          (or (= iter 0)
              (and (>= (- (macro-sim-state-minerals st) m-cost) min-flr)
                   (or (= g-cost 0) (>= (- (macro-sim-state-gas st) g-cost) gas-flr)))))
        (define supply-ok? (or (<= s-cost 0) (>= rem-sup-sim s-cost)))
        (when (and (> slot-avail 0)
                   supply-ok?
                   floor-ok?
                   (>= (macro-sim-state-minerals st) m-cost)
                   (>= (macro-sim-state-gas st) g-cost))
          (set-macro-sim-state-minerals! st (- (macro-sim-state-minerals st) m-cost))
          (set-macro-sim-state-gas! st (- (macro-sim-state-gas st) g-cost))
          (set! rem-sup-sim (- rem-sup-sim s-cost))
          (unless (eq? pslot 'worker)
            (hash-update! open-slots-ht pslot sub1 0))
          ;; Zerg building consumes a Drone; Zerg larva train consumes 1 larva; morph consumes source unit
          (when (and (eq? race 'Zerg) (memq kind '(build expand)))
            (when (> (hash-ref un 'drone 0) 1)
              (hash-update! un 'drone sub1 0)))
          (when (eq? pslot 'larva)
            (set-macro-sim-state-larvae! st (max 0 (sub1 (macro-sim-state-larvae st)))))
          (when (and (eq? kind 'morph)
                     (memq pslot '(roach zergling hydralisk corruptor overlord)))
            (when (> (hash-ref un pslot 0) 0)
              (hash-update! un pslot sub1 0)))
          (define task
            (macro-sim-task sym
                            kind
                            pslot
                            (+ frame (sc2-tech-node-build-frames node))
                            (sc2-tech-node-supply-provided node)))
          (set-macro-sim-state-in-progress-tasks!
           st (cons task (macro-sim-state-in-progress-tasks st)))))))
  decision)

;; Runs a full Chaos Monkey Build-Order recovery trial for `(race, enemy-race)`
;; with `num-deletions` random deletion waves injected at frames across the game,
;; then allows recovery up to `max-frames` and checks whether all build-order steps
;; (tech structures, expansions, add-ons, and upgrades) were recovered and completed!
(define (run-chaos-monkey-build-order-trial
         #:race [race 'Zerg]
         #:enemy-race [enemy-race 'Unknown]
         #:seed [seed 42]
         #:max-frames [max-frames 14000]
         #:dt-frames [dt-frames 8]
         #:deletion-frames [deletion-frames '(1600 3200 4800 6400)]
         #:forced-deletion-categories [forced-categories '()]
         #:severity [severity 0.65])
  (define (seed-elem offset)
    (add1 (modulo (abs (+ seed offset)) 4294967000)))
  (define rng
    (vector->pseudo-random-generator
     (vector (seed-elem 1) (seed-elem 7) (seed-elem 13)
             (seed-elem 29) (seed-elem 53) (seed-elem 97))))
  (define st (make-initial-macro-sim-state race enemy-race #:seed seed))
  (define resolved-race (macro-sim-state-race st))
  (define resolved-enemy-race (macro-sim-state-enemy-race st))
  (define del-table
    (for/hash ([f (in-list deletion-frames)]
               [idx (in-naturals)])
      (define cat (and (< idx (length forced-categories)) (list-ref forced-categories idx)))
      (values f cat)))

  (for ([f (in-range dt-frames (add1 max-frames) dt-frames)])
    (when (hash-has-key? del-table f)
      (chaos-monkey-delete! st rng
                            #:target-category (hash-ref del-table f #f)
                            #:severity severity))
    (step-macro-sim! st dt-frames))

  (define wstate (sim-state->macro-world-state st))
  (define rb (macro-world-state-ready-building-counts wstate))
  (define tb (macro-world-state-total-building-counts wstate))
  (define uc (macro-world-state-unit-counts wstate))
  (define upgs (append (macro-world-state-researched-upgrades wstate)
                       (macro-world-state-pending-upgrades wstate)))
  (define steps (pro-build-order-steps-for-matchup resolved-race resolved-enemy-race))

  ;; Check which build-order structural/upgrade goals are satisfied at the end of recovery
  (define unsatisfied
    (filter (lambda (g)
              (match-define (pro-bo-goal kind sym tgt-cnt _ _ _) g)
              (case kind
                [(build expand morph)
                 (< (bldg-count-equivalent tb sym) tgt-cnt)]
                [(research)
                 (not (memq sym upgs))]
                [(train)
                 ;; For unit train goals (e.g. overlord/queen/zergling/stalker/immortal/viking-fighter/raven/sentry),
                 ;; check that prerequisite structure is ready and unit count >= 1
                 (and (not (memq sym '(overlord zergling)))
                      (< (unit-count-equivalent uc sym) 1))]
                [else #f]))
            steps))

  (chaos-monkey-trial-result
   resolved-race
   resolved-enemy-race
   seed
   max-frames
   (length (macro-sim-state-chaos-events st))
   (reverse (macro-sim-state-chaos-events st))
   (null? unsatisfied)
   unsatisfied
   (macro-world-state-workers wstate)
   (macro-world-state-active-bases wstate)
   (macro-world-state-supply-used wstate)
   (macro-world-state-supply-cap wstate)
   (macro-world-state-army-supply wstate)
   (macro-world-state-researched-upgrades wstate)
   rb
   (reverse (take (macro-sim-state-priority-logs st)
                  (min 8 (length (macro-sim-state-priority-logs st)))))))

;; Runs a multi-matchup Chaos Monkey campaign across Zerg, Terran, Protoss (and optional Random) build orders
(define (run-chaos-monkey-campaign
         #:trials-per-race [trials-per-race 6]
         #:max-frames [max-frames 14000]
         #:severity [severity 0.65]
         #:include-random? [include-random? #f])
  (define base-matchups '((Zerg Zerg) (Zerg Terran) (Zerg Protoss)
                          (Terran Zerg) (Terran Terran) (Terran Protoss)
                          (Protoss Zerg) (Protoss Terran) (Protoss Protoss)))
  (define matchups
    (if include-random?
        (append base-matchups '((Random Terran) (Random Zerg) (Random Protoss)))
        base-matchups))
  (define category-rotations
    '((supply tech-building addon worker)
      (worker gas-building tech-building supply)
      (tech-building expansion addon combat-unit)
      (supply worker tech-building gas-building)))
  (for*/list ([m (in-list matchups)]
              [t-idx (in-range trials-per-race)])
    (match-define (list r er) m)
    (define rot (list-ref category-rotations (modulo t-idx (length category-rotations))))
    (run-chaos-monkey-build-order-trial
     #:race r
     #:enemy-race er
     #:seed (+ 100 (* 37 t-idx) (equal-hash-code m))
     #:max-frames max-frames
     #:forced-deletion-categories rot
     #:severity severity)))

