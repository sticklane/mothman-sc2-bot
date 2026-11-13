#lang racket/base

(require racket/list
         racket/match
         racket/math
         racket/string
         "sc2-game-constants.rkt"
         "okasaki-sc.rkt"
         "econ-ledger.rkt")

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
 translate-goal-to-next-action
 synthesize-dynamic-macro-plan
 macro-brain-decision-dynamic-plan
 make-macro-world-state
 obs-hash->macro-world-state
 step-priority-macro-brain
 macro-brain-can-spend?

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
   (sc2-tech-node 'zerg-flyer-armor-1   'Zerg 'research 'tech-upgrade      150 150 0 0 2560 'spire             '(spire)                            #t)
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
   (sc2-tech-node 'terran-vehicle-and-ship-plating-1 'Terran 'research 'tech-upgrade 100 100 0 0 2560 'armory     '(armory)                           #t)
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
   (sc2-tech-node 'protoss-air-weapons-1    'Protoss 'research 'tech-upgrade  100 100 0  0 2880 'cybernetics-core  '(cybernetics-core)                 #t)
   (sc2-tech-node 'protoss-air-armor-1      'Protoss 'research 'tech-upgrade  150 150 0  0 2880 'cybernetics-core  '(cybernetics-core)                 #t)
   (sc2-tech-node 'extended-thermal-lance   'Protoss 'research 'tech-upgrade  150 150 0  0 2240 'robotics-bay      '(robotics-bay)                     #t)
   (sc2-tech-node 'gravitic-booster         'Protoss 'research 'tech-upgrade  100 100 0  0 1280 'robotics-bay      '(robotics-bay)                     #t)
   (sc2-tech-node 'psi-storm                'Protoss 'research 'tech-upgrade  200 200 0  0 1760 'templar-archive   '(templar-archive)                  #t)
   (sc2-tech-node 'shadow-strike            'Protoss 'research 'tech-upgrade  100 100 0  0 2240 'dark-shrine       '(dark-shrine)                      #t)))

(define SC2-TECH-GRAPH
  (for/hasheq ([n (in-list SC2-TECH-NODES-LIST)])
    (values (sc2-tech-node-id n) n)))

;; Normalizes unit, structure, add-on, and upgrade aliases onto SC2-TECH-GRAPH node IDs.
(define (normalize-brain-sym sym)
  (case sym
    [(viking viking-assault)                       'viking-fighter]
    [(siege-tank-sieged)                           'siege-tank]
    [(widow-mine-burrowed)                         'widow-mine]
    [(thor-ap)                                     'thor]
    [(liberator-ag)                                'liberator]
    [(broodlord)                                   'brood-lord]
    [(voidray)                                     'void-ray]
    [(lurker-mp lurker-burrowed lurker-mp-burrowed) 'lurker]
    [(lurker-den-mp)                               'lurker-den]
    [(robotics-support-bay)                        'robotics-bay]
    [(templar-archives)                            'templar-archive]
    [(barracks-tech-lab)                           'barracks-techlab]
    [(factory-tech-lab)                            'factory-techlab]
    [(starport-tech-lab)                           'starport-techlab]
    [(zergling-movementspeed)                      'metabolic-boost]
    [(adrenal-glands)                              'zergling-attackspeed]
    [(warpgate-research)                           'warp-gate-research]
    [(melee-attacks-1)                             'zerg-melee-weapons-1]
    [(melee-attacks-2)                             'zerg-melee-weapons-2]
    [(melee-attacks-3)                             'zerg-melee-weapons-3]
    [(missile-attacks-1)                           'zerg-missile-weapons-1]
    [(missile-attacks-2)                           'zerg-missile-weapons-2]
    [(missile-attacks-3)                           'zerg-missile-weapons-3]
    [(ground-carapace-1)                           'zerg-ground-armor-1]
    [(ground-carapace-2)                           'zerg-ground-armor-2]
    [(ground-carapace-3)                           'zerg-ground-armor-3]
    [(infantry-weapons-1)                          'terran-infantry-weapons-1]
    [(infantry-weapons-2)                          'terran-infantry-weapons-2]
    [(infantry-weapons-3)                          'terran-infantry-weapons-3]
    [(infantry-armor-1)                            'terran-infantry-armor-1]
    [(infantry-armor-2)                            'terran-infantry-armor-2]
    [(infantry-armor-3)                            'terran-infantry-armor-3]
    [(ground-weapons-1)                            'protoss-ground-weapons-1]
    [(ground-weapons-2)                            'protoss-ground-weapons-2]
    [(ground-weapons-3)                            'protoss-ground-weapons-3]
    [(ground-armor-1)                              'protoss-ground-armor-1]
    [(ground-armor-2)                              'protoss-ground-armor-2]
    [(ground-armor-3)                              'protoss-ground-armor-3]
    [(shields-1)                                   'protoss-shields-1]
    [else                                          sym]))

(define (same-brain-sym? a b)
  (and (symbol? a)
       (symbol? b)
       (eq? (normalize-brain-sym a) (normalize-brain-sym b))))

(define (lookup-sc2-tech-node sym)
  (and (symbol? sym)
       (hash-ref SC2-TECH-GRAPH (normalize-brain-sym sym) #f)))

;; Delegates structure equivalence (morphs, flying Terran buildings, lowered depots,
;; rich geysers, uprooted crawlers, overcharged pylons, LotV structure aliases) to
;; `sc2-count-equivalent-structures` with `include-free-addons? = #f` so unattached
;; add-ons never falsely satisfy attached TechLab/Reactor prerequisites and
;; `starport-techlab` is never double-counted as `starport-reactor`.
(define (bldg-count-equivalent ht sym)
  (sc2-count-equivalent-structures ht sym #f))

;; Counts equivalent unit modes (fighter/assault, tank/sieged, burrowed, phasing, transport).
(define (unit-count-equivalent ht sym)
  (for/sum ([s (in-list (remove-duplicates (sc2-unit-equivalent-syms sym) eq?))])
    (hash-ref ht s 0)))

;; Checks whether all ready facilities of the parent type for `sym` already have
;; attached add-ons (or all Terran facilities on map are saturated by attached + free add-ons).
(define (facility-addon-slot-occupied? sym ready-bldg-counts total-bldg-counts
                                       #:min-ready-floor [min-ready-floor 0])
  (define csym (normalize-brain-sym sym))
  (define parent-fac
    (case csym
      [(barracks-techlab barracks-reactor) 'barracks]
      [(factory-techlab factory-reactor)   'factory]
      [(starport-techlab starport-reactor) 'starport]
      [else #f]))
  (cond
    [(not parent-fac) #f]
    [else
     (define ready-facs (bldg-count-equivalent ready-bldg-counts parent-fac))
     (define fac-addons
       (case parent-fac
         [(barracks)
          (+ (bldg-count-equivalent total-bldg-counts 'barracks-techlab)
             (bldg-count-equivalent total-bldg-counts 'barracks-reactor))]
         [(factory)
          (+ (bldg-count-equivalent total-bldg-counts 'factory-techlab)
             (bldg-count-equivalent total-bldg-counts 'factory-reactor))]
         [(starport)
          (+ (bldg-count-equivalent total-bldg-counts 'starport-techlab)
             (bldg-count-equivalent total-bldg-counts 'starport-reactor))]
         [else 0]))
     (define free-addons
       (+ (hash-ref total-bldg-counts 'tech-lab 0)
          (hash-ref total-bldg-counts 'techlab 0)
          (hash-ref total-bldg-counts 'reactor 0)))
     (define total-attached-addons
       (+ (bldg-count-equivalent total-bldg-counts 'barracks-techlab)
          (bldg-count-equivalent total-bldg-counts 'barracks-reactor)
          (bldg-count-equivalent total-bldg-counts 'factory-techlab)
          (bldg-count-equivalent total-bldg-counts 'factory-reactor)
          (bldg-count-equivalent total-bldg-counts 'starport-techlab)
          (bldg-count-equivalent total-bldg-counts 'starport-reactor)))
     (define total-terr-facilities
       (+ (bldg-count-equivalent total-bldg-counts 'barracks)
          (bldg-count-equivalent total-bldg-counts 'factory)
          (bldg-count-equivalent total-bldg-counts 'starport)))
     (define all-terr-slots-saturated-with-free?
       (and (> free-addons 0)
            (> total-terr-facilities 0)
            (>= (+ free-addons total-attached-addons) total-terr-facilities)))
     (or (>= fac-addons (max min-ready-floor ready-facs))
         all-terr-slots-saturated-with-free?)]))

;; Distinguishes genuine anti-air vs detection vs static ground-defense responses under attack
;; so non-defensive tech/upgrades never starve combat units during an active enemy attack.
(define (is-aa-or-detection-answer? sym requires-anti-air? requires-detection?)
  (define csym (normalize-brain-sym sym))
  (or (memq csym '(spine-crawler bunker shield-battery planetary-fortress))
      (and requires-anti-air?
           (memq csym '(queen spore-crawler hydralisk-den hydralisk spire corruptor mutalisk
                        marine missile-turret engineering-bay viking-fighter starport thor cyclone
                        stalker cybernetics-core photon-cannon stargate phoenix void-ray)))
      (and requires-detection?
           (memq csym '(spore-crawler overseer lair
                        missile-turret engineering-bay orbital-command raven starport starport-techlab
                        observer robotics-facility photon-cannon forge)))))

(define (single-prereq-ready? ready-bldg-counts prereq-sym)
  (or (not prereq-sym)
      (> (bldg-count-equivalent ready-bldg-counts prereq-sym) 0)))

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
             (> (unit-count-equivalent unit-counts pslot) 0)])]
         [else #t]))
     (and prereqs-ok? morph-source-ok?)]))

(define (desired-zerg-queen-count active-bases)
  (min SC2-MAX-QUEENS-CAP (+ active-bases (if (>= active-bases 2) 2 1))))

(define (sc2-tech-already-satisfied? sym total-bldg-counts researched-upgs pending-upgs [target-count 1])
  (define node (lookup-sc2-tech-node sym))
  (cond
    [(not node) #f]
    [(eq? (sc2-tech-node-kind node) 'research)
     (define csym (sc2-tech-node-id node))
     (or (not (not (memq sym researched-upgs)))
         (not (not (memq csym researched-upgs)))
         (not (not (memq sym pending-upgs)))
         (not (not (memq csym pending-upgs)))
         (and (eq? csym 'metabolic-boost)
              (or (not (not (memq 'zergling-movementspeed researched-upgs)))
                  (not (not (memq 'zergling-movementspeed pending-upgs))))))]
    [(sc2-tech-node-unique? node)
     (>= (bldg-count-equivalent total-bldg-counts (sc2-tech-node-id node))
         (max 1 target-count))]
    [else #f]))

;; Walks the SC2-TECH-GRAPH recursively to find the earliest missing prerequisite
;; structure/add-on that is neither ready nor currently under construction (`total-bldg-counts == 0`).
;; Returns an ordered list of missing prerequisite symbols (from root prerequisite to immediate prerequisite).
(define (resolve-missing-prereq-chain sym ready-bldg-counts total-bldg-counts [visited '()])
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
                 [(single-prereq-ready? ready-bldg-counts p)
                  '()]
                 [(> (bldg-count-equivalent total-bldg-counts p) 0)
                  ;; Prerequisite is already under construction / morphing; wait for it to finish
                  ;; unless IT has a broken upstream prerequisite
                  (resolve-missing-prereq-chain p ready-bldg-counts total-bldg-counts next-vis)]
                 [else
                  ;; Prerequisite is completely missing (never built or destroyed by Chaos Monkey)!
                  (append (resolve-missing-prereq-chain p ready-bldg-counts total-bldg-counts next-vis)
                          (list p))])))
      eq?)]))

;; Scans all existing buildings/units/upgrades AND active build-order goals to find
;; any broken tech tree dependencies (e.g., Lair exists or Roach Warren exists, but Spawning Pool
;; was destroyed; or Cybernetics Core exists, but Gateway or Pylon was destroyed; or Factory
;; exists, but Barracks or Supply Depot was destroyed).
(define (find-all-broken-tech-dependencies race ready-bldg-counts total-bldg-counts
                                           #:active-goals [active-goals '()])
  (define r-sym
    (case race
      [(Zerg zerg ZvZ ZvT ZvP) 'Zerg]
      [(Terran terran TvZ TvT TvP) 'Terran]
      [else 'Protoss]))
  ;; 1. Check any structure currently owned by the player whose upstream prerequisite was destroyed
  (define owned-syms
    (for/list ([n (in-list SC2-TECH-NODES-LIST)]
               #:when (and (eq? (sc2-tech-node-race n) r-sym)
                           (memq (sc2-tech-node-kind n) '(build expand morph addon))
                           (> (bldg-count-equivalent total-bldg-counts (sc2-tech-node-id n)) 0)))
      (sc2-tech-node-id n)))
  ;; 2. Check all active build-order goal symbols
  (define goal-syms
    (filter symbol?
            (map (lambda (g)
                   (cond
                     [(pro-bo-goal? g) (pro-bo-goal-target-sym g)]
                     [(symbol? g) g]
                     [else #f]))
                 active-goals)))
  (remove-duplicates
   (apply append
          (for/list ([sym (in-list (append owned-syms goal-syms))])
            (resolve-missing-prereq-chain sym ready-bldg-counts total-bldg-counts)))
   eq?))

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
         #:base-x [base-x 32.5]
         #:base-y [base-y 32.5]
         #:nat-x [nat-x 50.5]
         #:nat-y [nat-y 50.5]
         #:third-x [third-x 60.5]
         #:third-y [third-y 40.5])
  (define r-sym
    (case race
      [(Zerg zerg "Zerg" "zerg" ZvZ ZvT ZvP) 'Zerg]
      [(Terran terran "Terran" "terran" TvZ TvT TvP) 'Terran]
      [else 'Protoss]))
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
  (make-macro-world-state
   #:race race
   #:enemy-race (hash-ref obs 'enemy-race 'Unknown)
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
                (or (hash-ref e 'flying? #f)
                    (hash-ref e 'flying #f)
                    (hash-ref e 'is-flying #f)))
              enemy-units)
       (ormap (lambda (eb)
                (or (hash-ref eb 'flying? #f)
                    (hash-ref eb 'flying #f)
                    (hash-ref eb 'is-flying #f)
                    (memq (hash-ref eb 'type 'unknown)
                          '(command-center-flying orbital-command-flying
                            barracks-flying factory-flying starport-flying))))
              (hash-ref obs 'enemy-buildings '())))
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
   #:third-y (hash-ref obs 'third-y 40.5)))

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
         (memq cid '(ravager baneling lurker brood-lord overseer archon))))
  (define current-ready
    (cond
      [(eq? kind 'research)
       (if (or (memq cid researched-upgrades) (memq id researched-upgrades)) 1 0)]
      [(or (eq? kind 'train) unit-morph?)
       (unit-count-equivalent unit-counts cid)]
      [else
       (bldg-count-equivalent ready-bldg-counts cid)]))
  (define current-total
    (cond
      [(eq? kind 'research)
       (if (or (memq cid researched-upgrades)
               (memq id researched-upgrades)
               (memq cid pending-upgrades)
               (memq id pending-upgrades))
           1
           0)]
      [(or (eq? kind 'train) unit-morph?)
       (unit-count-equivalent unit-counts cid)]
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

      ;; 3. Goal has all prerequisites ready right now -> translates directly to `cid`!
      [(sc2-tech-prereqs-ready? cid ready-bldg-counts unit-counts)
       (values 'actionable-now cid)]

      ;; 4. Goal is missing one or more prerequisites -> resolve via backward-chaining over SC2-TECH-GRAPH
      [else
       (define missing-chain
         (resolve-missing-prereq-chain cid ready-bldg-counts total-bldg-counts))
       (cond
         [(pair? missing-chain)
          (define root-missing (first missing-chain))
          (if (sc2-tech-prereqs-ready? root-missing ready-bldg-counts unit-counts)
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
                   (< (unit-count-equivalent unit-counts src-sym) min-src-needed)
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

;; Synthesizes the live 5-track `dynamic-macro-plan` from `macro-world-state` on every frame.
(define (synthesize-dynamic-macro-plan state)
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

  (define steps-so-far
    (filter (lambda (g) (>= effective-phase-supply (pro-bo-goal-min-supply g)))
            (pro-build-order-steps-for-matchup race enemy-race)))
  (define repaired-prereqs
    (find-all-broken-tech-dependencies
     race ready-bldg-counts total-bldg-counts
     #:active-goals steps-so-far))

  (define raw-goal-specs '())
  (define (add-goal-spec! id track kind target-count weight reason)
    (when (lookup-sc2-tech-node id)
      (set! raw-goal-specs
            (cons (list id track kind target-count weight reason)
                  raw-goal-specs))))

  ;; Track 1: Survival, Hard Supply-Lockout Unblock, Worker-Rush Override & Broken Prereq Repair
  (when supply-lockout-active?
    (add-goal-spec! plan-supply-sym
                    'survival-supply
                    (if (eq? race 'Zerg) 'train 'build)
                    (add1 plan-cur-supply-cnt)
                    980.0
                    'emergency-supply-unblock))

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
          (add-goal-spec! 'zealot 'survival-supply 'train 4 540.0 'emergency-rush-defense)
          (when (> (bldg-count-equivalent ready-bldg-counts 'cybernetics-core) 0)
            (add-goal-spec! 'shield-battery 'survival-supply 'build 1 515.0 'emergency-rush-defense))])]))

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
  (define macro-step-rank 0)
  (for ([g (in-list steps-so-far)])
    (match-define (pro-bo-goal kind sym tgt-cnt min-sup _) g)
    (define addon-occupies-facility?
      (and live-slots?
           (facility-addon-slot-occupied? sym ready-bldg-counts total-bldg-counts #:min-ready-floor 1)))
    (define redundant-scaling-fac-with-idle-slots?
      (and live-slots?
           (< minerals 350)
           (or (and (eq? sym 'barracks)
                    (>= (bldg-count-equivalent total-bldg-counts 'barracks) 2)
                    (>= (hash-ref open-facility-slots 'barracks 0) 2))
               (and (eq? sym 'gateway)
                    (>= (bldg-count-equivalent total-bldg-counts 'gateway) 3)
                    (>= (+ (hash-ref open-facility-slots 'gateway 0)
                           (hash-ref open-facility-slots 'warp-gate 0))
                        2)))))
    (define protoss-1base-2nd-gas-capped?
      (and (eq? race 'Protoss)
           (eq? sym 'assimilator)
           (<= active-bases 1)
           (< plan-total-townhalls 2)
           (>= (bldg-count-equivalent total-bldg-counts 'assimilator) 1)
           (not (eq? enemy-race 'Protoss))
           (not under-early-rush-crisis?)))
    (define extra-geyser-deferred-by-gas-bank?
      (and (memq sym '(extractor refinery assimilator))
           (let ([cur-gb (bldg-count-equivalent total-bldg-counts sym)])
             (or (< workers (min-workers-for-next-gas-bldg cur-gb))
                 early-zero-army-attack?
                 (and supply-lockout-active?
                      (< minerals (+ (sc2-min-cost plan-supply-sym 100) (sc2-min-cost sym 75))))
                 protoss-1base-2nd-gas-capped?
                 (and live-slots? (> cur-gb 0) (>= gas 250))))))
    (define late-tech-deferred-by-low-army?
      (and live-slots?
           (memq sym '(armory ghost-academy))
           (< army-supply 18)
           (not (>= active-bases 3))
           (not (ormap (lambda (r) (same-brain-sym? sym r)) repaired-prereqs))))
    (unless (or addon-occupies-facility?
                redundant-scaling-fac-with-idle-slots?
                extra-geyser-deferred-by-gas-bank?
                late-tech-deferred-by-low-army?)
      (cond
        [(eq? kind 'expand)
         (define exp-w
           (cond
             [(and supply-lockout-active?
                   (< minerals (+ (sc2-min-cost plan-supply-sym 100) (sc2-min-cost sym 300))))
              25.0]
             [peaceful? (- 476.0 (* 3.0 macro-step-rank))]
             [else 42.0]))
         (set! macro-step-rank (add1 macro-step-rank))
         (add-goal-spec! sym 'economy-expansion 'expand tgt-cnt exp-w 'expansion-plan)]
        [(memq kind '(build morph research addon))
         (define non-defensive-tech-under-attack?
           (and live-slots?
                (not peaceful?)
                root-combat-facility-ready?
                (not (is-aa-or-detection-answer? sym requires-anti-air? requires-detection?))
                (or (and (eq? kind 'research)
                         (or under-attack? (< army-supply (+ enemy-threat-supply 6))))
                    (memq sym '(lair hive spire greater-spire infestation-pit ultralisk-cavern evolution-chamber
                                engineering-bay armory ghost-academy fusion-core
                                twilight-council forge robotics-bay fleet-beacon templar-archive dark-shrine)))))
         (define tech-w
           (if non-defensive-tech-under-attack?
               140.0
               (max 442.0 (- 476.0 (* 3.5 macro-step-rank)))))
         (set! macro-step-rank (add1 macro-step-rank))
         (add-goal-spec! sym 'tech-infrastructure kind tgt-cnt tech-w 'macro-tech-plan)]
        [(eq? kind 'train)
         (define queen-defer?
           (and (eq? sym 'queen)
                (or under-attack? (> enemy-threat-supply 2))
                (< army-supply 4)))
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
         (define train-w
           (cond
             [queen-defer? 80.0]
             [(or gas-locked-0g? past-opening-window?) 390.0]
             [peaceful? 466.0]
             [else 420.0]))
         (add-goal-spec! sym 'army-production 'train tgt-cnt train-w 'army-milestone-plan)])))

  ;; Track 2b: Zerg Per-Base + Creep/Defense Queen Engine (capped at SC2-MAX-QUEENS-CAP = 8)
  (define cur-queens (unit-count-equivalent unit-counts 'queen))
  (define desired-queens (desired-zerg-queen-count active-bases))
  (when (and (eq? race 'Zerg)
             (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)
             (< cur-queens desired-queens))
    (add-goal-spec! 'queen 'economy-expansion 'train desired-queens
                    (cond
                      [(and (or under-attack? (> enemy-threat-supply 2)) (< army-supply 4)) 80.0]
                      [(and live-slots? peaceful? (< cur-queens active-bases)) 445.0]
                      [(and live-slots? peaceful?) 428.0]
                      [else 230.0])
                    'larva-inject-engine))

  ;; Track 3b: Dynamic Gas-Unlock Tech Progression when floating >= 80G in peace time
  (when (and live-slots? peaceful? (>= gas 80))
    (case race
      [(Zerg)
       (when (= (bldg-count-equivalent total-bldg-counts 'roach-warren) 0)
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

  ;; Track 5: Dynamic Counter-Tech & Proactive Intel/Detection Goals
  (define has-lair-or-hive-ready?
    (or (> (bldg-count-equivalent ready-bldg-counts 'lair) 0)
        (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)))
  (when (and (eq? race 'Zerg) has-lair-or-hive-ready?)
    (define desired-overseers (if (or (>= army-supply 40) requires-detection?) 2 1))
    (define cur-overseers (unit-count-equivalent unit-counts 'overseer))
    (when (< cur-overseers desired-overseers)
      (add-goal-spec! 'overseer 'intel-recon 'morph desired-overseers
                      (if (= cur-overseers 0) 488.0 446.0)
                      'proactive-overseer-detection)))

  (when requires-anti-air?
    (case race
      [(Zerg)
       (add-goal-spec! 'queen 'survival-supply 'train (min SC2-MAX-QUEENS-CAP (+ active-bases 2)) 495.0 'anti-air-response)
       (add-goal-spec! 'hydralisk 'army-production 'train 4 490.0 'anti-air-response)]
      [(Terran)
       (add-goal-spec! 'marine 'army-production 'train 6 495.0 'anti-air-response)
       (add-goal-spec! 'viking-fighter 'army-production 'train 2 490.0 'anti-air-response)]
      [(Protoss)
       (add-goal-spec! 'stalker 'army-production 'train 6 495.0 'anti-air-response)
       (add-goal-spec! 'blink 'tech-infrastructure 'research 1 492.0 'anti-air-response)
       (add-goal-spec! 'stargate 'tech-infrastructure 'build 1 488.0 'anti-air-response)
       (add-goal-spec! 'phoenix 'army-production 'train 4 491.0 'anti-air-response)]))

  (when requires-detection?
    (case race
      [(Zerg)
       (add-goal-spec! 'spore-crawler 'intel-recon 'build 1 495.0 'detection-response)
       (add-goal-spec! 'overseer 'intel-recon 'morph (if (>= army-supply 40) 2 1) 492.0 'detection-response)]
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
  (define t3-endgame-window?
    (and (>= active-bases 3)
         (or (>= workers 50) (>= effective-phase-supply 90))
         (or peaceful? (>= army-supply (+ enemy-threat-supply 4)))))
  (when t3-endgame-window?
    (case race
      [(Zerg)
       (add-goal-spec! 'infestation-pit 'tech-infrastructure 'build 1 468.0 't3-endgame-tech)
       (add-goal-spec! 'hive 'tech-infrastructure 'morph 1 472.0 't3-endgame-tech)
       (when (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)
         (add-goal-spec! 'viper 'army-production 'train (if (>= supply-used 130) 2 1) 470.0 't3-endgame-army)
         (add-goal-spec! 'ultralisk-cavern 'tech-infrastructure 'build 1 466.0 't3-endgame-tech)
         (add-goal-spec! 'zerg-missile-weapons-3 'tech-infrastructure 'research 1 452.0 't3-endgame-tech)
         (add-goal-spec! 'zerg-ground-armor-3 'tech-infrastructure 'research 1 450.0 't3-endgame-tech))
       (when (> (bldg-count-equivalent ready-bldg-counts 'ultralisk-cavern) 0)
         (add-goal-spec! 'chitinous-plating 'tech-infrastructure 'research 1 462.0 't3-endgame-tech)
         (add-goal-spec! 'anabolic-synthesis 'tech-infrastructure 'research 1 458.0 't3-endgame-tech)
         (add-goal-spec! 'ultralisk 'army-production 'train (if (>= active-bases 4) 6 4) 464.0 't3-endgame-army))
       (when (> (bldg-count-equivalent ready-bldg-counts 'infestation-pit) 0)
         (add-goal-spec! 'infestor 'army-production 'train (if (>= supply-used 140) 2 1) 448.0 't3-endgame-army))
       (when (or (>= workers 56) (>= effective-phase-supply 110) requires-anti-air?)
         (add-goal-spec! 'spire 'tech-infrastructure 'build 1 464.0 't3-endgame-tech)
         (when (> (bldg-count-equivalent ready-bldg-counts 'spire) 0)
           (add-goal-spec! 'corruptor 'army-production 'train 4 454.0 't3-endgame-army)
           (when (> (bldg-count-equivalent ready-bldg-counts 'hive) 0)
             (add-goal-spec! 'greater-spire 'tech-infrastructure 'morph 1 468.0 't3-endgame-tech)))
         (when (> (bldg-count-equivalent ready-bldg-counts 'greater-spire) 0)
           (add-goal-spec! 'brood-lord 'army-production 'morph (if (>= active-bases 4) 5 3) 470.0 't3-endgame-army)))]
      [(Terran)
       (add-goal-spec! 'armory 'tech-infrastructure 'build 1 468.0 't3-endgame-tech)
       (add-goal-spec! 'ghost-academy 'tech-infrastructure 'build 1 462.0 't3-endgame-tech)
       (add-goal-spec! 'starport 'tech-infrastructure 'build 1 466.0 't3-endgame-tech)
       (when (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
         (add-goal-spec! 'medivac 'army-production 'train (if (>= supply-used 130) 6 4) 466.0 't3-endgame-army)
         (add-goal-spec! 'liberator 'army-production 'train (if (>= active-bases 4) 5 3) 464.0 't3-endgame-army)
         (add-goal-spec! 'starport-techlab 'tech-infrastructure 'addon 1 462.0 't3-endgame-tech)
         (add-goal-spec! 'fusion-core 'tech-infrastructure 'build 1 464.0 't3-endgame-tech))
       (when (> (bldg-count-equivalent ready-bldg-counts 'ghost-academy) 0)
         (add-goal-spec! 'ghost 'army-production 'train (if (>= supply-used 130) 4 2) 465.0 't3-endgame-army))
       (when (> (bldg-count-equivalent ready-bldg-counts 'armory) 0)
         (add-goal-spec! 'thor 'army-production 'train (if (>= active-bases 4) 4 2) 462.0 't3-endgame-army)
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
         (add-goal-spec! 'extended-thermal-lance 'tech-infrastructure 'research 1 466.0 't3-endgame-tech)
         (add-goal-spec! 'colossus 'army-production 'train (if (>= supply-used 140) 4 3) 468.0 't3-endgame-army)
         (add-goal-spec! 'disruptor 'army-production 'train (if (>= supply-used 135) 2 1) 456.0 't3-endgame-army))
       (when (> (bldg-count-equivalent ready-bldg-counts 'templar-archive) 0)
         (add-goal-spec! 'psi-storm 'tech-infrastructure 'research 1 468.0 't3-endgame-tech)
         (add-goal-spec! 'high-templar 'army-production 'train 4 464.0 't3-endgame-army)
         (when (>= (unit-count-equivalent unit-counts 'high-templar) 2)
           (add-goal-spec! 'archon 'army-production 'morph (if (>= supply-used 140) 3 2) 467.0 't3-endgame-army)))
       (when (or (>= active-bases 4) (>= workers 60) (>= effective-phase-supply 120))
         (add-goal-spec! 'stargate 'tech-infrastructure 'build 1 460.0 't3-endgame-tech)
         (add-goal-spec! 'fleet-beacon 'tech-infrastructure 'build 1 464.0 't3-endgame-tech)
         (when (> (bldg-count-equivalent ready-bldg-counts 'fleet-beacon) 0)
           (add-goal-spec! 'tempest 'army-production 'train (if (>= active-bases 4) 3 2) 464.0 't3-endgame-army)
           (when (>= active-bases 4)
             (add-goal-spec! 'carrier 'army-production 'train (if (>= supply-used 150) 5 3) 468.0 't3-endgame-army))))]))

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
              (> tgt-cnt (* 2 active-bases)))
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
    (filter (lambda (n) (not (eq? (plan-goal-node-status n) 'satisfied)))
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

  (dynamic-macro-plan
   race frame effective-phase-supply
   all-nodes active-nodes actionable-nodes
   translated-map in-prog-syms))

(define (macro-brain-decision-dynamic-plan decision)
  (define sched (macro-brain-decision-priority-schedule decision))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (and (hash? cat-ht) (hash-ref cat-ht 'dynamic-plan #f)))

;; Pure Core Priority & Dynamic Plan Brain Step:
;; Synthesizes the live 5-track `dynamic-macro-plan`, translates active goals into
;; concrete ready next-actions, self-heals broken/deleted prerequisite chains,
;; checks income feasibility for mineral & gas escrows, and runs the Okasaki Braun-heap
;; scheduler with dual-resource (mineral + gas) and facility-slot reservations.
(define (step-priority-macro-brain state)
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
  (define dyn-plan (synthesize-dynamic-macro-plan state))
  (define plan-active-nodes (dynamic-macro-plan-active-goals dyn-plan))
  (define plan-actionable-nodes (dynamic-macro-plan-actionable-goals dyn-plan))
  (define plan-next-actions-ht (dynamic-macro-plan-translated-next-actions dyn-plan))

  ;; 2. Self-Healing Tech Prerequisite DAG Check:
  (define steps-so-far
    (filter (lambda (g) (>= effective-phase-supply (pro-bo-goal-min-supply g)))
            (pro-build-order-steps-for-matchup race enemy-race)))
  (define repaired-prereqs
    (find-all-broken-tech-dependencies
     race ready-bldg-counts total-bldg-counts
     #:active-goals (if bo-raw-goal (cons bo-raw-goal steps-so-far) steps-so-far)))

  ;; Derive top actionable goal from the Dynamic Plan (translating any blocked goal
  ;; directly into its ready `next-action-sym` instead of stalling on a static queue head!)
  (define early-zero-army-attack?
    (and (or under-attack? (> enemy-threat-supply 0))
         (= army-supply 0)))
  (define root-combat-facility-ready?
    (case race
      [(Zerg) (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)]
      [(Terran) (> (bldg-count-equivalent ready-bldg-counts 'barracks) 0)]
      [else (> (+ (bldg-count-equivalent ready-bldg-counts 'gateway)
                  (bldg-count-equivalent ready-bldg-counts 'warp-gate)) 0)]))
  (define race-supply-sym
    (case race [(Zerg) 'overlord] [(Terran) 'supply-depot] [else 'pylon]))
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
  (define emergency-army-before-workers?
    (and (or under-attack? (> enemy-threat-supply 0))
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
           (and (not (and supply-lockout-active?
                          (memq gsym '(extractor refinery assimilator
                                       hatchery nexus command-center))))
                (or (not (memq gsym '(extractor refinery assimilator)))
                    (let ([cur-gb (bldg-count-equivalent total-bldg-counts gsym)])
                      (and (< cur-gb (* 2 active-bases))
                           (>= workers (min-workers-for-next-gas-bldg cur-gb))
                           (not early-zero-army-attack?))))
                (not (and (eq? gsym 'queen)
                          (or under-attack? (> enemy-threat-supply 2))
                          (< army-supply 4)))))))
  (define effective-bo-goal
    (cond
      [(and top-plan-node
            (lookup-sc2-tech-node (plan-goal-node-next-action-sym top-plan-node)))
       => (lambda (node)
            (define next-sym (sc2-tech-node-id node))
            (define p-list (sc2-tech-node-prereqs node))
            (pro-bo-goal (if (eq? (sc2-tech-node-kind node) 'addon) 'build (sc2-tech-node-kind node))
                         next-sym
                         (plan-goal-node-target-count top-plan-node)
                         0
                         (and (pair? p-list) (first p-list))))]
      [(bo-fallback-goal-allowed? bo-raw-goal) bo-raw-goal]
      [else #f]))

  (define bo-goal-sym
    (and (pro-bo-goal? effective-bo-goal)
         (pro-bo-goal-target-sym effective-bo-goal)))

  ;; Compute explicit multi-instance target count when an active BO/plan goal requests > 1
  ;; of a structure (e.g. 2nd Forge/Evo/EngBay/Factory/Starport/Robo/Stargate), defaulting to 1.
  (define (goal-target-count-for sym)
    (define csym (normalize-brain-sym sym))
    (define from-bo
      (for/fold ([mx 1]) ([g (in-list (if bo-raw-goal (cons bo-raw-goal steps-so-far) steps-so-far))])
        (if (and (pro-bo-goal? g)
                 (same-brain-sym? (pro-bo-goal-target-sym g) csym))
            (max mx (pro-bo-goal-target-count g))
            mx)))
    (for/fold ([mx from-bo]) ([n (in-list plan-active-nodes)])
      (if (same-brain-sym? (plan-goal-node-id n) csym)
          (max mx (plan-goal-node-target-count n))
          mx)))

  ;; 3. Income Feasibility & Anti-Starvation Diagnostics:
  (define gas-bldg-sym
    (case race [(Zerg) 'extractor] [(Terran) 'refinery] [else 'assimilator]))
  (define ready-gas-bldgs (bldg-count-equivalent ready-bldg-counts gas-bldg-sym))
  (define total-gas-bldgs (bldg-count-equivalent total-bldg-counts gas-bldg-sym))
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

  ;; Supply threshold: scales with both supply-cap AND active production facilities so multi-Rax/Gate/Hatch
  ;; cycles trigger Overlord/Depot/Pylon lead time BEFORE hitting 100% cap (`SUPPLY_BLOCKED` fix).
  (define supply-buffer
    (cond
      [(< supply-cap 20) 1]
      [(< supply-cap 26) 2]
      [(>= supply-cap 66)
       (if (hash? open-facility-slots)
           (min 16 (max 6 (+ 3 (* 2 active-bases) prod-fac-count)))
           6)]
      [(>= supply-cap 36)
       (if (hash? open-facility-slots)
           (min 12 (max 4 (+ 2 (* 2 active-bases) (quotient prod-fac-count 2))))
           4)]
      [else 2]))

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
     #:desired-bases (cond [(>= effective-phase-supply 108) 5]
                           [(>= effective-phase-supply 64) 4]
                           [(>= effective-phase-supply 40) 3]
                           [else 2])
     #:production-facilities (max 1 prod-fac-count)
     #:max-facilities max-fac-count
     #:army-supply army-supply
     #:enemy-threat-supply enemy-threat-supply
     #:under-attack? under-attack?
     #:requires-anti-air? requires-anti-air?
     #:requires-detection? requires-detection?
     #:supply-at-risk? (or supply-at-risk? (< supply-left 0) supply-lockout-active?)
     #:supply-buffer supply-buffer))

  (define metrics
    (if bo-goal-sym
        (hash-set base-metrics 'bo-goal-sym bo-goal-sym)
        base-metrics))

  ;; Check if a producer facility/research slot is open
  (define (slot-available? slot-sym)
    (cond
      [(eq? slot-sym 'worker) (> workers 0)]
      [(eq? slot-sym 'high-templar) (>= (unit-count-equivalent unit-counts 'high-templar) 2)]
      [(not (hash? open-facility-slots)) #t]
      [else (> (hash-ref open-facility-slots slot-sym 0) 0)]))

  (define (cand-feasible-now? sym)
    (define node (lookup-sc2-tech-node sym))
    (cond
      [(not node) #t]
      [(sc2-tech-already-satisfied? sym total-bldg-counts researched-upgrades pending-upgrades
                                    (goal-target-count-for sym)) #f]
      [(not (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts)) #f]
      [else (slot-available? (sc2-tech-node-producer-slot node))]))

  (define (cand-can-escrow? sym)
    (define node (lookup-sc2-tech-node sym))
    (and node
         (not (sc2-tech-already-satisfied? sym total-bldg-counts researched-upgrades pending-upgrades
                                           (goal-target-count-for sym)))
         (sc2-tech-prereqs-ready? sym ready-bldg-counts unit-counts)
         (or (>= workers 6)
             (and emergency-army-before-workers?
                  (eq? (sc2-tech-node-category node) 'combat-unit)))
         (or (>= minerals (sc2-tech-node-min-cost node)) has-mineral-income?)
         (or (>= gas (sc2-tech-node-gas-cost node)) has-gas-income?)))

  (define under-early-rush-crisis?
    (and (< frame 3000)
         (or under-attack? (>= enemy-threat-supply 4))))

  (define has-lair-or-hive-ready?
    (> (+ (bldg-count-equivalent ready-bldg-counts 'lair)
          (bldg-count-equivalent ready-bldg-counts 'hive))
       0))

  (define desired-overseer-cnt
    (if (or (>= army-supply 40) requires-detection?) 2 1))

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
     #:desired-bases (cond [(>= effective-phase-supply 108) 5]
                           [(>= effective-phase-supply 64) 4]
                           [(>= effective-phase-supply 40) 3]
                           [else 2])
     #:production-facilities (max 1 prod-fac-count)
     #:max-facilities max-fac-count
     #:army-supply army-supply
     #:enemy-threat-supply enemy-threat-supply
     #:under-attack? under-attack?
     #:requires-anti-air? requires-anti-air?
     #:requires-detection? requires-detection?
     #:supply-at-risk? (or supply-at-risk? (< supply-left 0) supply-lockout-active?)
     #:supply-buffer supply-buffer
     #:ally-buildings (counts-hash->symbol-list total-bldg-counts)
     #:ready-buildings (counts-hash->symbol-list ready-bldg-counts)
     #:ally-units (counts-hash->symbol-list unit-counts)
     #:researched-upgrades all-upgs
     #:open-prod-slots open-facility-slots
     #:bo-active-goal effective-bo-goal
     #:base-x base-x #:base-y base-y
     #:nat-x nat-x #:nat-y nat-y
     #:third-x third-x #:third-y third-y))

  (define max-crisis-pending-supply
    (cond
      [(< supply-left 0) 3]
      [(and (hash? open-facility-slots) (or (>= supply-cap 66) (>= prod-fac-count 5))) 3]
      [else 2]))
  (define supply-crisis?
    (or supply-lockout-active?
        (and (< supply-cap 200)
             (< (+ supply-cap (* 8 pending-supply)) 200)
             (< pending-supply max-crisis-pending-supply)
             (or (and (= pending-supply 0) (<= supply-left supply-buffer))
                 (<= (+ supply-left (* 8 pending-supply)) (max 0 (quotient supply-buffer 2)))
                 (and (>= active-bases 3)
                      (>= minerals 400)
                      (<= (+ supply-left (* 8 pending-supply)) (max 8 supply-buffer)))))))

  (define total-townhalls-incl-pending
    (case race
      [(Zerg) (bldg-count-equivalent total-bldg-counts 'hatchery)]
      [(Terran) (bldg-count-equivalent total-bldg-counts 'command-center)]
      [else (bldg-count-equivalent total-bldg-counts 'nexus)]))

  (define overdue-1base-expand?
    (and (>= minerals 400)
         (= active-bases 1)
         (<= total-townhalls-incl-pending 1)
         (>= frame 2688)
         (not under-attack?)
         (<= enemy-threat-supply 0)
         (>= workers 12)))

  (define race-expand-sym
    (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))

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
               [else (if (< (bldg-count-equivalent total-bldg-counts 'shield-battery) 1)
                         '(zealot shield-battery)
                         '(zealot))])
             '()))
        '()))

  (define existing-ids (map priority-candidate-id raw-cands))
  (define plan-translated-syms (map plan-goal-node-next-action-sym plan-actionable-nodes))
  (define extra-syms
    (remove-duplicates
     (filter (lambda (s)
               (and s
                    (not (ormap (lambda (eid) (same-brain-sym? eid s)) existing-ids))
                    (lookup-sc2-tech-node s)
                    (not (sc2-tech-already-satisfied? s total-bldg-counts researched-upgrades pending-upgrades
                                                      (goal-target-count-for s)))))
             (append (if supply-crisis? (list race-supply-sym) '())
                     emergency-rush-syms
                     (if overdue-1base-expand? (list race-expand-sym) '())
                     repaired-prereqs
                     plan-translated-syms
                     (if bo-goal-sym (list bo-goal-sym) '())
                     (if (and (eq? race 'Zerg)
                              (or has-lair-or-hive-ready? requires-detection?)
                              (< (unit-count-equivalent unit-counts 'overseer) desired-overseer-cnt))
                         (list 'overseer)
                         '())
                     (if (and (eq? race 'Protoss)
                              (> (bldg-count-equivalent ready-bldg-counts 'stargate) 0))
                         (cond
                           [(and requires-anti-air?
                                 (< (unit-count-equivalent unit-counts 'phoenix) 10))
                            (list 'phoenix)]
                           [(and (not requires-anti-air?)
                                 (or (not (hash? open-facility-slots))
                                     (< army-supply 30))
                                 (< (unit-count-equivalent unit-counts 'oracle)
                                    (if (and (>= minerals 200) (>= gas 200)) 2 1)))
                            (list 'oracle)]
                           [else '()])
                         '())
                     (if (and (eq? race 'Terran)
                              (> (bldg-count-equivalent ready-bldg-counts 'starport) 0)
                              (< (unit-count-equivalent unit-counts 'medivac) 2)
                              (>= (+ (unit-count-equivalent unit-counts 'marine)
                                     (unit-count-equivalent unit-counts 'marauder))
                                  6))
                         (list 'medivac)
                         '())
                     (if (and (= total-gas-bldgs 0)
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
      (if (ormap (lambda (r) (same-brain-sym? csym r)) repaired-prereqs)
          (struct-copy priority-candidate raw-cand
                       [utility-score (+ 300.0 (priority-candidate-utility-score raw-cand))])
          raw-cand)))

  (define open-combat-fac-slots-cnt
    (if (hash? open-facility-slots)
        (for/sum ([k (in-list '(barracks factory starport gateway warp-gate robotics-facility stargate larva))])
          (hash-ref open-facility-slots k 0))
        99))

  (define worker-army-curve-ok?
    (or (not (hash? open-facility-slots))
        (< workers 24)
        (and (not under-attack?)
             (<= enemy-threat-supply 0)
             (or (and (< workers (min 66 (* 20 active-bases))) (>= minerals 150))
                 (and (>= minerals 350) (<= open-combat-fac-slots-cnt 1))))
        (>= army-supply (required-army-supply-for-worker-growth workers enemy-threat-supply))))

  (define need-worker-saturation?
    (and (not under-attack?)
         (<= enemy-threat-supply 0)
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

  (define (cand-wanted-now? c)
    (define id (priority-candidate-id c))
    (define cat (priority-candidate-category c))
    (define blk0 (priority-candidate-blocking-allowed? c))
    (define node (lookup-sc2-tech-node id))
    (define plan-node
      (or (hash-ref plan-next-actions-ht id #f)
          (hash-ref plan-next-actions-ht (normalize-brain-sym id) #f)))
    (define protoss-1base-2nd-gas-capped?
      (and (eq? race 'Protoss)
           (eq? id 'assimilator)
           (<= active-bases 1)
           (< total-townhalls-incl-pending 2)
           (not (eq? enemy-race 'Protoss))
           (not under-early-rush-crisis?)
           (>= (bldg-count-equivalent total-bldg-counts 'assimilator) 1)))
    (define geyser-cap-ok?
      (or (not (memq id '(extractor refinery assimilator)))
          (let ([cur-gas-bldgs (bldg-count-equivalent total-bldg-counts id)])
            (and (not protoss-1base-2nd-gas-capped?)
                 (or (not supply-lockout-active?)
                     (>= minerals (+ (sc2-min-cost race-supply-sym 100)
                                     (priority-candidate-min-cost c))))
                 (< cur-gas-bldgs (* 2 active-bases))
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
                     (< gas 250))))))
    (define addon-slot-free-ok?
      (or (not (hash? open-facility-slots))
          (not (facility-addon-slot-occupied? id ready-bldg-counts total-bldg-counts #:min-ready-floor 0))))
    (define redundant-scaling-fac-idle?
      (and (hash? open-facility-slots)
           (< minerals 350)
           (or (and (eq? id 'barracks)
                    (>= (bldg-count-equivalent total-bldg-counts 'barracks) 2)
                    (>= (hash-ref open-facility-slots 'barracks 0) 2))
               (and (eq? id 'gateway)
                    (>= (bldg-count-equivalent total-bldg-counts 'gateway) 3)
                    (>= (+ (hash-ref open-facility-slots 'gateway 0)
                           (hash-ref open-facility-slots 'warp-gate 0))
                        2)))))
    (define late-tech-army-ok?
      (or (not (hash? open-facility-slots))
          (not (memq id '(armory ghost-academy fusion-core ultralisk-cavern templar-archive dark-shrine)))
          (ormap (lambda (r) (same-brain-sym? id r)) repaired-prereqs)
          (>= army-supply 18)
          (and (memq id '(templar-archive dark-shrine ultralisk-cavern fusion-core))
               (or (and bo-goal-sym (same-brain-sym? id bo-goal-sym))
                   (and plan-node (>= (plan-goal-node-priority-weight plan-node) 440.0))))))
    (define zerg-drone-sacrifice-ok?
      (or (not (eq? race 'Zerg))
          (not node)
          (not (memq (sc2-tech-node-kind node) '(build expand)))
          (and under-early-rush-crisis?
               (>= workers 2)
               (memq id '(spawning-pool spine-crawler))
               (>= minerals 200))
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
               (eq? enemy-race 'Protoss)
               (eq? id 'gateway)
               (< (bldg-count-equivalent total-bldg-counts 'gateway) 2))
          (<= nat-exp-min-reserve 0)
          (>= (- minerals nat-exp-min-reserve) (priority-candidate-min-cost c))))
    (define supply-lockout-allows-expand?
      (or (not (eq? cat 'expansion))
          (not supply-lockout-active?)
          (>= minerals (+ (sc2-min-cost race-supply-sym 100)
                          (priority-candidate-min-cost c)))))
    (define 3rd-plus-expand-ready?
      (or (not (eq? cat 'expansion))
          (not (hash? open-facility-slots))
          (< active-bases 2)
          (and (not under-attack?)
               (<= enemy-threat-supply 0)
               (>= workers (if (eq? race 'Zerg) 24 28))
               (or (eq? race 'Zerg)
                   (>= army-supply (if (= active-bases 2) 10 16))
                   (>= minerals 550)))))
    (and geyser-cap-ok?
         addon-slot-free-ok?
         (not redundant-scaling-fac-idle?)
         late-tech-army-ok?
         zerg-drone-sacrifice-ok?
         nat-reserve-allows-2nd-fac?
         supply-lockout-allows-expand?
         3rd-plus-expand-ready?
         (cond
           [(ormap (lambda (r) (same-brain-sym? id r)) repaired-prereqs) #t]
           [(memq id emergency-rush-syms) #t]
           [(eq? cat 'supply)
            (or supply-crisis?
                (and (or (and bo-goal-sym (same-brain-sym? id bo-goal-sym)) plan-node)
                     (<= pending-supply 0)))]
           [(and bo-goal-sym (same-brain-sym? id bo-goal-sym)) #t]
           [(and plan-node (>= (plan-goal-node-priority-weight plan-node) 440.0)) #t]
           [(eq? cat 'worker)
            (if (hash? open-facility-slots)
                (< workers (min 70 (max target-workers (* 22 active-bases))))
                (< workers (min 80 (max target-workers (* 20 active-bases)))))]
           [(eq? cat 'expansion)
            (and (not under-attack?)
                 (or overdue-1base-expand?
                     (and (< active-bases
                             (cond [(>= effective-phase-supply 108) 5]
                                   [(>= effective-phase-supply 64) 4]
                                   [(>= effective-phase-supply 30) 3]
                                   [else 2]))
                          (>= workers (if (= active-bases 1)
                                          (if (eq? race 'Zerg) 15 18)
                                          24)))))]
           [(eq? cat 'counter-tech)
            (cond
              [(memq id '(queen observer))
               (define cur-cnt (unit-count-equivalent unit-counts id))
               (define max-cnt (if (eq? id 'queen) (desired-zerg-queen-count active-bases) 1))
               (and blk0 (< cur-cnt max-cnt))]
              [(eq? id 'raven)
               (and blk0
                    (or requires-detection?
                        (and bo-goal-sym (same-brain-sym? id bo-goal-sym))
                        (and plan-node (>= (plan-goal-node-priority-weight plan-node) 440.0)))
                    (< (unit-count-equivalent unit-counts 'raven) 1))]
              [(eq? id 'overseer)
               (and (or requires-detection? has-lair-or-hive-ready?)
                    (< (unit-count-equivalent unit-counts 'overseer) desired-overseer-cnt))]
              [(memq id '(viking viking-fighter corruptor phoenix))
               (and blk0
                    (or (not (eq? id 'phoenix))
                        (< (unit-count-equivalent unit-counts 'phoenix) 10))
                    (or requires-anti-air?
                        (not (hash? open-facility-slots))
                        (and bo-goal-sym (same-brain-sym? id bo-goal-sym))))]
              [(memq id '(spore-crawler photon-cannon missile-turret))
               (and (or requires-anti-air? requires-detection?)
                    (< (bldg-count-equivalent total-bldg-counts id) 1))]
              [(memq id '(shield-battery spine-crawler bunker))
               (and (or under-attack? (> enemy-threat-supply 0))
                    (< (bldg-count-equivalent total-bldg-counts id) 1))]
              [else blk0])]
           [(eq? cat 'production-scaling)
            (cond
              [(memq id '(gateway barracks))
               (and (< (bldg-count-equivalent total-bldg-counts id)
                       (min 8 (if (< total-townhalls-incl-pending 2) 1 (* 2 active-bases))))
                    (>= workers (* 18 active-bases)))]
              [(memq id '(extractor refinery assimilator))
               (define cur-gas-bldgs (bldg-count-equivalent total-bldg-counts id))
               (and (not protoss-1base-2nd-gas-capped?)
                    (< cur-gas-bldgs (* 2 active-bases))
                    (>= workers (min-workers-for-next-gas-bldg cur-gas-bldgs))
                    (not early-zero-army-attack?))]
              [else blk0])]
           [(eq? cat 'combat-unit)
            (and (or blk0
                     (and emergency-army-before-workers?
                          (sc2-tech-prereqs-ready? id ready-bldg-counts unit-counts)
                          (slot-available? (if node (sc2-tech-node-producer-slot node) 'worker))))
                 (< supply-used 196)
                 (or under-attack?
                     (> enemy-threat-supply 0)
                     (< army-supply 8)
                     (>= workers (min 24 (* 11 active-bases)))))]
           [else blk0])))

  (define all-adjusted-cands
    (for/list ([c (in-list (append raw-cands extra-cands))]
               #:when (cand-wanted-now? c))
      (define sym (priority-candidate-id c))
      (define cat (priority-candidate-category c))
      (define u0 (priority-candidate-utility-score c))
      (define blk0 (priority-candidate-blocking-allowed? c))
      (define node (lookup-sc2-tech-node sym))
      (define is-repaired-raw?
        (not (not (ormap (lambda (r) (same-brain-sym? sym r)) repaired-prereqs))))
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
      (define is-plan-milestone? (and plan-node (>= plan-weight 440.0)))
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
             [(and (< workers (if (eq? race 'Zerg) 14 16))
                   (not under-attack?)
                   (<= enemy-threat-supply 0))
              plan-weight]
             [(and need-worker-saturation?
                   (< workers sat-target))
              430.0]
             [else 0.0]))
         (define raw-worker-u
           (if (>= workers 70)
               25.0
               (max w-plan-boost (+ u0 emergency-worker-boost))))
         (struct-copy priority-candidate c
                      [utility-score (cond
                                       [(>= workers 70) 25.0]
                                       [emergency-army-before-workers? (min 160.0 raw-worker-u)]
                                       [(not worker-army-curve-ok?) (min 105.0 raw-worker-u)]
                                       [else raw-worker-u])]
                      [blocking-allowed? (and (not emergency-army-before-workers?)
                                              (< workers 8)
                                              has-mineral-income?)])]

        ;; Expansion candidate: high priority when active plan expansion goal or 1-base natural ready,
        ;; but NEVER blocks combat units when under-attack?, enemy-threat-supply > 0 (PV1/PV2/PV7),
        ;; or when 2-base Terran/Protoss lacks standing army (< 10 supply) below 550M (#5122353 fix).
        [(eq? cat 'expansion)
         (define premature-3rd-base-starving-army?
           (and (hash? open-facility-slots)
                (>= active-bases 2)
                (not (eq? race 'Zerg))
                (< army-supply 10)
                (< minerals 550)))
         (define exp-ok?
           (and (or blk0 is-bo-goal? is-repaired? overdue-1base-expand?)
                (not under-attack?)
                (<= enemy-threat-supply 0)
                (not premature-3rd-base-starving-army?)
                (or overdue-1base-expand?
                    (>= workers (if (eq? race 'Zerg) 14 16)))
                has-mineral-income?))
         (define exp-u
           (cond
             [(or under-attack? (> enemy-threat-supply 0) premature-3rd-base-starving-army?) (min u0 45.0)]
             [is-repaired? (max 520.0 u0)]
             [overdue-1base-expand? (max 490.0 plan-weight u0)]
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
         (define max-queens (desired-zerg-queen-count active-bases))
         (define queen-defer-for-first-lings?
           (and (eq? sym 'queen)
                (or under-attack? (> enemy-threat-supply 2))
                (< army-supply 4)))
         (define inject-queen-boost?
           (and (eq? sym 'queen)
                (not queen-defer-for-first-lings?)
                (< cur-queens (min max-queens (add1 active-bases)))
                (> (bldg-count-equivalent ready-bldg-counts 'spawning-pool) 0)))
         (define proactive-overseer-boost?
           (and (eq? sym 'overseer)
                has-lair-or-hive-ready?
                (< (unit-count-equivalent unit-counts 'overseer)
                   (if requires-detection? 2 1))))
         (define emergency-rush-root-boost?
           (and under-early-rush-crisis?
                (not root-combat-facility-ready?)
                (memq sym '(spawning-pool barracks gateway supply-depot pylon))
                (or (memq sym '(supply-depot pylon))
                    (= (bldg-count-equivalent total-bldg-counts sym) 0))
                (memq sym emergency-rush-syms)))
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
         (define u-after-gas-lock
           (if mineral-only-gas-locked?
               (/ u0 (+ 1.0 (expt (/ (exact->inexact gas) 100.0) 2)))
               u0))
         (define combat-escrow-ok?
           (and (not (and mineral-only-gas-locked? (>= army-supply 4)))
                (or (not (eq? cat 'combat-unit))
                    effective-bo-goal?
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
                    requires-anti-air?)))
         (define answers-aa-or-det?
           (or (is-aa-or-detection-answer? sym requires-anti-air? requires-detection?)
               proactive-overseer-boost?
               emergency-rush-root-boost?
               emergency-rush-def-boost?))
         (define tech-under-attack-escrow-ok?
           (or (not (hash? open-facility-slots))
               (and (not under-attack?) (<= enemy-threat-supply 0))
               (eq? cat 'combat-unit)
               (eq? cat 'supply)
               is-repaired?
               answers-aa-or-det?))
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
         (define can-esc?
           (and (not queen-defer-for-first-lings?)
                (or blk0
                    effective-bo-goal?
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
             [is-repaired? (max (+ 380.0 u0) 520.0)]
             [proactive-overseer-boost? (max 475.0 (+ 140.0 u0))]
             [(and effective-bo-goal?
                   (or (and (not under-attack?) (<= enemy-threat-supply 0))
                       answers-aa-or-det?))
              (max plan-weight (if (and bo-goal-sym (same-brain-sym? sym bo-goal-sym)) (+ 200.0 u0) 0.0) 465.0)]
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
             [(and is-repaired-raw? (not is-repaired?))
              (max 50.0 (- u-after-gas-lock 300.0))]
             [else u-after-gas-lock]))
         (struct-copy priority-candidate c
                      [utility-score boosted-u]
                      [blocking-allowed? can-esc?])])))

  ;; 5. Filter out candidates that are ALREADY satisfied (e.g. researched/pending upgrades or unique buildings)
  ;;    and deduplicate by canonical candidate `id` (keeping highest utility).
  (define seen-ids (make-hasheq))
  (define active-cands
    (filter (lambda (c)
              (define id (priority-candidate-id c))
              (define cid (normalize-brain-sym id))
              (and (not (hash-has-key? seen-ids cid))
                   (not (sc2-tech-already-satisfied?
                         cid total-bldg-counts researched-upgrades pending-upgrades
                         (goal-target-count-for cid)))
                   (begin (hash-set! seen-ids cid #t) #t)))
            (sort all-adjusted-cands > #:key priority-candidate-utility-score)))

  ;; Insert into Okasaki Braun heap by descending utility
  (define heap
    (for/fold ([h braun-empty])
              ([c (in-list active-cands)]
               [idx (in-naturals)])
      (define u (priority-candidate-utility-score c))
      (braun-insert h (+ (- u) (* 1e-7 idx)) c)))

  (define sorted-cands
    (let loop ([h heap] [acc '()])
      (if (braun-empty? h)
          (reverse acc)
          (let-values ([(top rest-h) (braun-extract-min h)])
            (loop rest-h (cons top acc))))))

  ;; Mutable simulation ledger for this frame's scheduling pass
  (define rem-min minerals)
  (define rem-gas gas)
  (define rem-sup (max 0 supply-left))
  (define rem-slots
    (if (hash? open-facility-slots)
        (hash-copy open-facility-slots)
        #f))
  (define reserved-slots '())
  (define worker-build-escrowed? #f)
  (define min-floor 0)
  (define gas-floor 0)
  (define scheduled-cands '())
  (define reserved-cand #f)
  (define decision-entries '())
  (define escrowed-entries '())

  (for ([c (in-list sorted-cands)]
        [rank-idx (in-naturals 1)])
    (define id (priority-candidate-id c))
    (define cat (priority-candidate-category c))
    (define act (priority-candidate-action c))
    (define m-cost (priority-candidate-min-cost c))
    (define g-cost (priority-candidate-gas-cost c))
    (define s-cost (priority-candidate-supply-cost c))
    (define u-score (priority-candidate-utility-score c))
    (define blk-ok? (eq? (priority-candidate-blocking-allowed? c) #t))
    (define node (lookup-sc2-tech-node id))
    (define pslot (if node (sc2-tech-node-producer-slot node) 'worker))

    ;; Check tech prerequisite readiness & open producer slot
    (define prereq-ok?
      (sc2-tech-prereqs-ready? id ready-bldg-counts unit-counts))
    (define slot-ok?
      (and (not (memq pslot reserved-slots))
           (cond
             [(eq? pslot 'worker) (> workers 0)]
             [(eq? pslot 'high-templar) (>= (unit-count-equivalent unit-counts 'high-templar) 2)]
             [(not rem-slots) #t]
             [else (> (hash-ref rem-slots pslot 0) 0)])))
    (define worker-cap-ok?
      (or (not (eq? cat 'worker))
          (if (hash? open-facility-slots)
              (< workers (min 70 (max target-workers (* 22 active-bases))))
              (< workers (min 80 (max target-workers (* 20 active-bases)))))))

    (define supply-ok? (or (<= s-cost 0) (>= rem-sup s-cost)))
    (define min-ok? (>= rem-min m-cost))
    (define gas-ok? (>= rem-gas g-cost))

    ;; Supply candidate ignores non-supply floors (PV4)
    (define app-min-floor (if (eq? cat 'supply) 0 min-floor))
    (define app-gas-floor (if (eq? cat 'supply) 0 gas-floor))
    (define floor-min-ok? (>= (- rem-min m-cost) app-min-floor))
    (define floor-gas-ok? (or (= g-cost 0) (>= (- rem-gas g-cost) app-gas-floor)))

    (cond
      [(and prereq-ok? slot-ok? worker-cap-ok? supply-ok? min-ok? gas-ok? floor-min-ok? floor-gas-ok?)
       (set! rem-min (- rem-min m-cost))
       (set! rem-gas (- rem-gas g-cost))
       (set! rem-sup (- rem-sup s-cost))
       (when (and rem-slots (not (eq? pslot 'worker)))
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
       (define escrowed-now? #f)
       (when (and prereq-ok? slot-ok? worker-slot-escrow-ok? blk-ok? supply-ok?
                  (or (< rem-min m-cost) (< rem-gas g-cost)))
         (define pure-gas-starved?
           (and (> g-cost 0)
                (>= rem-min m-cost)
                (< rem-gas (- g-cost 40))))
         (define min-escrow-amt (if pure-gas-starved? 0 m-cost))
         (set! min-floor (max min-floor min-escrow-amt))
         (when (> g-cost 0)
           (set! gas-floor (max gas-floor g-cost)))
         (when (eq? pslot 'worker)
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

  (define final-cands (reverse scheduled-cands))
  (define final-actions (map priority-candidate-action final-cands))
  (define final-ids (map priority-candidate-id final-cands))
  (define final-trace (reverse decision-entries))
  (define final-escrowed (reverse escrowed-entries))
  (define base-cand-utils
    (for/fold ([ht (hash)]) ([c (in-list (append raw-cands extra-cands))])
      (define cid (priority-candidate-id c))
      (define base-u (min 120.0 (priority-candidate-utility-score c)))
      (hash-set (hash-set ht cid base-u)
                (normalize-brain-sym cid)
                base-u)))
  (define cand-utils
    (for/fold ([ht base-cand-utils]) ([c (in-list sorted-cands)])
      (define cid (priority-candidate-id c))
      (hash-set (hash-set ht cid (priority-candidate-utility-score c))
                (normalize-brain-sym cid)
                (priority-candidate-utility-score c))))
  (define cat-utils
    (for/fold ([ht (hash 'decision-trace final-trace
                         'escrowed-entries final-escrowed
                         'candidate-utilities cand-utils
                         'reserved-min-floor min-floor
                         'reserved-gas-floor gas-floor
                         'dynamic-plan dyn-plan)])
              ([c (in-list sorted-cands)])
      (define cat (priority-candidate-category c))
      (define u (priority-candidate-utility-score c))
      (hash-set ht cat (max u (hash-ref ht cat -inf.0)))))

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
  (define final-bo-eligible-for-saving-fallback?
    (and has-mineral-income?
         final-bo-goal-sym
         (<= final-bo-sup-cost supply-left)
         (not (and (memq final-bo-goal-sym '(hatchery nexus command-center))
                   (hash? open-facility-slots)
                   (>= active-bases 2)
                   (not (eq? race 'Zerg))
                   (< army-supply 10)
                   (< minerals 550)))))
  (define saving-id
    (if reserved-cand
        (priority-candidate-id reserved-cand)
        (if final-bo-eligible-for-saving-fallback? final-bo-goal-sym 'none)))
  (define log-str
    (format-priority-schedule-log-line
     sched-result
     #:frame frame
     #:race race
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:bo-goal-sym (and has-mineral-income? final-bo-goal-sym)
     #:bo-reserved-min min-floor
     #:bo-reserved-gas gas-floor))

  (macro-brain-decision
   final-actions
   final-ids
   saving-id
   min-floor
   gas-floor
   (reverse reserved-slots)
   final-effective-bo-goal
   repaired-prereqs
   sched-result
   log-str))

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
  (and (>= cur-min m-cost)
       (>= cur-gas g-cost)
       (or (eq? cat-sym 'supply)
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
               (for/sum ([t (in-list tasks)]
                         #:when (eq? (macro-sim-task-id t) 'overseer))
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
              (match-define (pro-bo-goal kind sym tgt-cnt _ _) g)
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

