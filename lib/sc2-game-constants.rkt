#lang racket/base

;; =============================================================================
;; `lib/sc2-game-constants.rkt`
;; Centrally Defined StarCraft II: Legacy of the Void (LotV) Game Constants,
;; Unit/Structure/Upgrade Catalogs, Costs, Supply, Energy, Cooldowns & Radii.
;;
;; All numerical parameters across `bot-runtime.rkt`, `sc2-protobuf-ws.rkt`,
;; `econ-ledger.rkt`, and `human-cortex.rkt` are derived from this single source
;; of truth rather than inlined as magic literals.
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/set)

(provide (all-defined-out))

;; -----------------------------------------------------------------------------
;; 1. Core SC2 Engine Timing, Map Coordinate & Supply Constants
;; -----------------------------------------------------------------------------
(define SC2-FASTER-FPS                     22.4)
(define SC2-FRAMES-PER-SECOND-INT          22)
(define SC2-SECONDS->FRAMES
  (lambda (sec) ( exact-round (* sec SC2-FASTER-FPS))))

(define SC2-MAP-MIN-COORD                  0.0)
(define SC2-MAP-MAX-COORD                  256.0)
(define SC2-MAP-SAFE-MIN-COORD             4.0)
(define SC2-MAP-SAFE-MAX-COORD             248.0)
(define SC2-MAP-PLAYABLE-MIN-COORD         8.0)
(define SC2-MAP-PLAYABLE-MAX-COORD         240.0)
(define SC2-DEFAULT-MAP-WIDTH              176.0)
(define SC2-DEFAULT-MAP-HEIGHT             176.0)
(define SC2-DEFAULT-MAP-CENTER-X           88.0)
(define SC2-DEFAULT-MAP-CENTER-Y           88.0)
(define SC2-DEFAULT-HOME-BASE-X            32.5)
(define SC2-DEFAULT-HOME-BASE-Y            32.5)
(define SC2-DEFAULT-NATURAL-X              45.0)
(define SC2-DEFAULT-NATURAL-Y              45.0)
(define SC2-DEFAULT-THIRD-X                60.5)
(define SC2-DEFAULT-THIRD-Y                40.5)
(define SC2-DEFAULT-ENEMY-BASE-X           160.5)
(define SC2-DEFAULT-ENEMY-BASE-Y           160.5)
(define SC2-DEFAULT-ENEMY-EXPAND-X         148.0)
(define SC2-DEFAULT-ENEMY-EXPAND-Y         148.0)
(define SC2-SYNTHETIC-MINERAL-PATCH-ID     504)

(define SC2-MAX-SUPPLY                     200)
(define SC2-STARTING-WORKERS               12)
(define SC2-STARTING-MINERALS              50)
(define SC2-STARTING-GAS                   0)
(define SC2-SUPPLY-PER-OVERLORD            8)
(define SC2-SUPPLY-PER-PYLON               8)
(define SC2-SUPPLY-PER-DEPOT               8)
(define SC2-SUPPLY-PER-PROVIDER            8)
(define SC2-TOWN-HALL-SUPPLY-PROVIDED      15)
(define SC2-HATCHERY-SUPPLY-PROVIDED       6)

;; Supply buffer thresholds derived from production cycle concurrency
(define SC2-EARLY-SUPPLY-CAP-THRESHOLD     30)
(define SC2-MID-SUPPLY-CAP-THRESHOLD       66)
(define SC2-BASE-SUPPLY-BUFFER             4)
(define SC2-EARLY-SUPPLY-BUFFER            6)
(define SC2-MID-SUPPLY-BUFFER              10)
(define SC2-CRITICAL-LOW-SUPPLY            2)
(define SC2-PENDING-SUPPLY-CREDIT          2)

;; -----------------------------------------------------------------------------
;; 2. Economy, Worker Saturation & Expansion Constants
;; -----------------------------------------------------------------------------
(define SC2-MINERAL-PATCHES-PER-BASE       8)
(define SC2-WORKERS-PER-MINERAL-PATCH      2)
(define SC2-IDEAL-WORKERS-PER-MINERAL-LINE (* SC2-MINERAL-PATCHES-PER-BASE SC2-WORKERS-PER-MINERAL-PATCH)) ; 16
(define SC2-GEYSERS-PER-BASE               2)
(define SC2-IDEAL-WORKERS-PER-GEYSER       3)
(define SC2-IDEAL-GAS-WORKERS-PER-BASE     (* SC2-GEYSERS-PER-BASE SC2-IDEAL-WORKERS-PER-GEYSER))          ; 6
(define SC2-IDEAL-WORKERS-PER-BASE         (+ SC2-IDEAL-WORKERS-PER-MINERAL-LINE SC2-IDEAL-GAS-WORKERS-PER-BASE)) ; 22
(define SC2-PRIORITY-WORKERS-PER-BASE      (+ SC2-IDEAL-WORKERS-PER-MINERAL-LINE 2)) ; 18
(define SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND (- SC2-IDEAL-WORKERS-PER-MINERAL-LINE 2)) ; 14
(define SC2-MIN-WORKERS-FOR-GAS            14)
(define SC2-MIN-WORKERS-FOR-SECOND-GAS     20)
(define SC2-MIN-WORKERS-FOR-FOUR-GAS       28)
(define SC2-MAX-ACTIVE-BASES               6)
(define SC2-MIN-DESIRED-BASES              2)
(define SC2-MAX-PRODUCTION-FACILITIES      8)
(define SC2-TERRAN-FACILITIES-PER-BASE     2)
(define SC2-PROTOSS-FACILITIES-PER-BASE    3)
(define SC2-MAX-QUEENS-CAP                 8)

;; Depletion & Gas/Mineral Rebalancing Thresholds
(define SC2-BASE-DEPLETION-MINERAL-THRESH  1200)
(define SC2-GAS-FLOAT-PULL-THRESHOLD       600)
(define SC2-MINERAL-STARVED-THRESHOLD      200)
(define SC2-SURPLUS-MINERAL-BANK-THRESHOLD 300)

;; -----------------------------------------------------------------------------
;; 3. Build Progress, Health/Shield Integrity & Spatial Radii (in SC2 Tiles)
;; -----------------------------------------------------------------------------
(define SC2-BUILD-COMPLETE-PROGRESS        0.999)
(define SC2-IN-TRANSIT-BUILD-PROGRESS      0.05)
(define SC2-NEW-FOOTPRINT-PROGRESS-MAX     0.25)

(define SC2-SUPPLY-BLDG-DAMAGED-HP-PCT     0.65)
(define SC2-DYING-BLDG-CANCEL-HP-PCT       0.18)
(define SC2-DYING-BLDG-CANCEL-MIN-HP       50)
(define SC2-WOUNDED-WORKER-HP-PCT          0.60)
(define SC2-WOUNDED-WORKER-MIN-HP          25)
(define SC2-HEALTHY-WORKER-PULL-MIN-HP     18)
(define SC2-MAX-WORKER-PULL-COUNT          6)
(define SC2-WOUNDED-PASSENGER-HP-PCT       0.45)
(define SC2-WOUNDED-PASSENGER-MIN-HP       55)

;; Unit Max Health & Shield Constants (SC2 LotV)
(define SC2-DRONE-MAX-HP                   40)
(define SC2-PROBE-MAX-HP                   40) ;; 20 HP + 20 Shield
(define SC2-SCV-MAX-HP                     45)
(define SC2-OVERLORD-MAX-HP                200)
(define SC2-OVERLORD-DAMAGED-HP-THRESH     150)
(define SC2-PYLON-HULL-MAX-HP              200)
(define SC2-PYLON-SHIELD-MAX-HP            200)
(define SC2-PYLON-TOTAL-MAX-HP             (+ SC2-PYLON-HULL-MAX-HP SC2-PYLON-SHIELD-MAX-HP)) ; 400
(define SC2-PYLON-DAMAGED-HULL-THRESH      (exact-round (* SC2-PYLON-HULL-MAX-HP SC2-SUPPLY-BLDG-DAMAGED-HP-PCT))) ; 130
(define SC2-SUPPLY-DEPOT-MAX-HP            400)
(define SC2-SUPPLY-DEPOT-DAMAGED-HP-THRESH (exact-round (* SC2-SUPPLY-DEPOT-MAX-HP SC2-SUPPLY-BLDG-DAMAGED-HP-PCT))) ; 260
(define SC2-STALKER-BLINK-HP-THRESH        80)
(define SC2-MUTALISK-KITE-HP-THRESH        60)
(define SC2-MARINE-STIM-MIN-HP             40)

;; Spatial Radii (in SC2 Map Tiles)
(define SC2-WORKER-ESCAPE-THREAT-RADIUS    4.0)
(define SC2-KITE-STEP-DISTANCE             4.0)
(define SC2-TERRAN-BUILDER-RADIUS          5.5)
(define SC2-NATURAL-BLOCK-RADIUS           6.0)
(define SC2-OVERLORD-THREAT-RADIUS         8.0)
(define SC2-CREEP-TUMOR-STEP-DISTANCE      8.0)
(define SC2-CHEESE-RUSH-RADIUS             9.0)
(define SC2-BLDG-UNDER-ATTACK-RADIUS       10.0)
(define SC2-GAS-STEAL-RADIUS               10.0)
(define SC2-NUKE-EVASION-RADIUS            10.0)
(define SC2-TRANSPORT-JUGGLE-RADIUS        10.0)
(define SC2-ENGAGEMENT-FOCUS-FIRE-RADIUS   10.0)
(define SC2-RESOURCE-CLUSTER-RADIUS        11.0)
(define SC2-BASE-RESOURCE-RADIUS           12.0)
(define SC2-TOWNHALL-EXCLUSION-RADIUS      13.0)
(define SC2-SIEGE-TANK-SIEGE-RANGE         13.0)
(define SC2-SIEGE-TANK-UNSIEGE-RANGE       16.0)
(define SC2-ANTI-KITE-LEASH-RADIUS         16.0)
(define SC2-BASE-DEFENSE-RADIUS            24.0)
(define SC2-NATURAL-VECTOR-OFFSET-TILES    24.0)
(define SC2-THIRD-VECTOR-OFFSET-TILES      42.0)
(define SC2-FORCE-FIELD-STEPBACK-RADIUS    3.0)
(define SC2-GAS-HARVESTER-EXCLUSION-RADIUS 3.5)
(define SC2-GEYSER-OCCUPIED-RADIUS         3.5)
(define SC2-EXPANSION-MINERAL-STANDOFF     5.2)
(define SC2-EXPANSION-SEED-OFFSET          5.5)

;; Attack Wave & Harassment Squad Thresholds
(define SC2-ATTACK-WAVE-MIN-COMBAT-UNITS   8)
(define SC2-ATTACK-WAVE-MIN-ARMY-SUPPLY    14)
(define SC2-MIN-DEFENSE-RALLY-UNITS        2)
(define SC2-LONE-KITER-MAX-DEFENDERS       6)
(define SC2-EARLY-CHEESE-MAX-FRAME         3200)
(define SC2-EARLY-CHEESE-MIN-DEFENDERS     4)
(define SC2-DOOR-GUARD-MAX-FRAME           3000)
(define SC2-MACRO-EXPAND-FRAME-THRESHOLD   2200)
(define SC2-EARLY-CHRONO-NEXUS-MAX-FRAME   1500)
(define SC2-EARLY-CHRONO-MAX-WORKERS       18)
(define SC2-WORKER-RUSH-DETECT-RADIUS      32.0)
(define SC2-WORKER-RUSH-MIN-ENEMY-WORKERS  4)
(define SC2-IN-BASE-PROXY-DETECT-RADIUS    35.0)
(define SC2-IN-BASE-PROXY-MAX-FRAME        4704)
(define SC2-FIGHTING-WORKER-DISENGAGE-HP   12)
(define SC2-FIGHTING-WORKER-REENGAGE-HP    16)

;; -----------------------------------------------------------------------------
;; 4. Refractory Cooldowns & Spell Energy Costs (in SC2 Frames & Energy)
;; -----------------------------------------------------------------------------
(define SC2-STATIC-DETECTOR-COOLDOWN-FRAMES 160)  ;; ~7.1s
(define SC2-CREEP-TUMOR-COOLDOWN-FRAMES     224)  ;; 10.0s
(define SC2-RESUME-BLDG-COOLDOWN-FRAMES     224)  ;; 10.0s
(define SC2-EXPANSION-COOLDOWN-FRAMES       336)  ;; 15.0s
(define SC2-MAX-TUMOR-SPREADS-PER-FRAME     2)

(define SC2-QUEEN-INJECT-ENERGY             25)
(define SC2-QUEEN-TUMOR-ENERGY              25)
(define SC2-QUEEN-TUMOR-SURPLUS-ENERGY      45)
(define SC2-QUEEN-TRANSFUSION-ENERGY        50)
(define SC2-OVERSEER-CHANGELING-ENERGY      50)
(define SC2-NEXUS-CHRONO-BOOST-ENERGY       50)
(define SC2-ORBITAL-MULE-ENERGY             50)
(define SC2-ORBITAL-SCAN-ENERGY             50)
(define SC2-SENTRY-FORCE-FIELD-ENERGY       50)
(define SC2-SENTRY-GUARDIAN-SHIELD-ENERGY   75)

;; -----------------------------------------------------------------------------
;; 5. Canonical SC2 LotV Unit, Structure & Upgrade Cost Catalog
;; -----------------------------------------------------------------------------
;; Each entry maps symbol -> (list minerals gas supply)
(define SC2-LOTV-COST-TABLE
  (hasheq
   ;; Workers & Supply
   'drone                   '(50 0 1)
   'probe                   '(50 0 1)
   'scv                     '(50 0 1)
   'overlord                '(100 0 0)
   'pylon                   '(100 0 0)
   'supply-depot            '(100 0 0)

   ;; TownHalls & Gas Buildings
   'hatchery                '(300 0 0)
   'lair                    '(150 100 0)
   'hive                    '(200 150 0)
   'nexus                   '(400 0 0)
   'command-center          '(400 0 0)
   'orbital-command         '(150 0 0)
   'planetary-fortress      '(150 150 0)
   'extractor               '(25 0 0)
   'assimilator             '(75 0 0)
   'refinery                '(75 0 0)
   'gas-building-reserve    '(75 0 0)

   ;; Zerg Structures
   'spawning-pool           '(200 0 0)
   'roach-warren            '(150 0 0)
   'baneling-nest           '(100 50 0)
   'evolution-chamber       '(75 0 0)
   'hydralisk-den           '(100 100 0)
   'lurker-den              '(100 150 0)
   'spire                   '(200 200 0)
   'greater-spire           '(100 150 0)
   'infestation-pit         '(100 100 0)
   'ultralisk-cavern        '(150 200 0)
   'spine-crawler           '(100 0 0)
   'spore-crawler           '(75 0 0)

   ;; Zerg Units
   'queen                   '(150 0 2)
   'zergling                '(50 0 1)
   'baneling                '(25 25 1)
   'roach                   '(75 25 2)
   'ravager                 '(25 75 1)
   'hydralisk               '(100 50 2)
   'lurker                  '(50 100 1)
   'mutalisk                '(100 100 2)
   'corruptor               '(150 100 2)
   'brood-lord              '(150 150 2)
   'infestor                '(100 150 2)
   'swarm-host              '(100 75 3)
   'ultralisk               '(275 200 6)
   'viper                   '(100 200 3)
   'overseer                '(50 50 0)

   ;; Protoss Structures
   'gateway                 '(150 0 0)
   'warp-gate               '(150 0 0)
   'warpgate                '(150 0 0)
   'cybernetics-core        '(150 0 0)
   'forge                   '(150 0 0)
   'photon-cannon           '(150 0 0)
   'shield-battery          '(100 0 0)
   'twilight-council        '(150 100 0)
   'robotics-facility       '(150 100 0)
   'robotics-bay            '(150 150 0)
   'robotics-support-bay    '(150 150 0)
   'stargate                '(150 150 0)
   'templar-archive         '(150 200 0)
   'templar-archives        '(150 200 0)
   'dark-shrine             '(150 150 0)
   'fleet-beacon            '(300 200 0)

   ;; Protoss Units
   'zealot                  '(100 0 2)
   'stalker                 '(125 50 2)
   'sentry                  '(50 100 2)
   'adept                   '(100 25 2)
   'high-templar            '(50 150 2)
   'dark-templar            '(125 125 2)
   'archon                  '(100 300 4)
   'observer                '(25 75 1)
   'warp-prism              '(250 0 2)
   'immortal                '(275 100 4)
   'colossus                '(300 200 6)
   'disruptor               '(150 150 4)
   'phoenix                 '(150 100 2)
   'void-ray                '(250 150 4)
   'oracle                  '(150 150 3)
   'carrier                 '(350 250 6)
   'tempest                 '(250 175 5)
   'mothership              '(300 300 6)

   ;; Terran Structures
   'barracks                '(150 0 0)
   'factory                 '(150 100 0)
   'starport                '(150 100 0)
   'engineering-bay         '(125 0 0)
   'armory                  '(150 100 0)
   'missile-turret          '(100 0 0)
   'bunker                  '(100 0 0)
   'sensor-tower            '(125 100 0)
   'ghost-academy           '(150 50 0)
   'fusion-core             '(150 150 0)
   'barracks-techlab        '(50 25 0)
   'barracks-tech-lab       '(50 25 0)
   'barracks-reactor        '(50 50 0)
   'factory-techlab         '(50 25 0)
   'factory-tech-lab        '(50 25 0)
   'factory-reactor         '(50 50 0)
   'starport-techlab        '(50 25 0)
   'starport-tech-lab       '(50 25 0)
   'starport-reactor        '(50 50 0)

   ;; Terran Units
   'marine                  '(50 0 1)
   'marauder                '(100 25 2)
   'reaper                  '(50 50 1)
   'ghost                   '(150 125 2)
   'hellion                 '(100 0 2)
   'hellbat                 '(100 0 2)
   'widow-mine              '(75 25 2)
   'siege-tank              '(150 125 3)
   'cyclone                 '(150 100 3)
   'thor                    '(300 200 6)
   'viking                  '(150 75 2)
   'viking-fighter          '(150 75 2)
   'medivac                 '(100 100 2)
   'liberator               '(150 125 3)
   'raven                   '(100 150 2)
   'banshee                 '(150 100 3)
   'battlecruiser           '(400 300 6)

   ;; Key Upgrades (all race canonical names & aliases)
   'metabolic-boost          '(100 100 0)
   'zergling-movementspeed   '(100 100 0)
   'adrenal-glands           '(200 200 0)
   'zergling-attackspeed     '(200 200 0)
   'glial-reconstitution     '(100 100 0)
   'tunneling-claws          '(150 150 0)
   'centrifugal-hooks        '(150 150 0)
   'grooved-spines           '(100 100 0)
   'muscular-augments        '(100 100 0)
   'adaptive-talons          '(150 150 0)
   'lurker-range             '(150 150 0)
   'seismic-spines           '(150 150 0)
   'burrow                   '(100 100 0)
   'pneumatized-carapace     '(100 100 0)
   'overlord-speed           '(100 100 0)
   'chitinous-plating        '(150 150 0)
   'anabolic-synthesis       '(150 150 0)
   'neural-parasite          '(150 150 0)
   'zerg-melee-weapons-1     '(100 100 0)
   'zerg-melee-weapons-2     '(150 150 0)
   'zerg-melee-weapons-3     '(200 200 0)
   'zerg-missile-weapons-1   '(100 100 0)
   'zerg-missile-weapons-2   '(150 150 0)
   'zerg-missile-weapons-3   '(200 200 0)
   'missile-attacks-1        '(100 100 0)
   'zerg-ground-armor-1      '(150 150 0)
   'zerg-ground-armor-2      '(225 225 0)
   'zerg-ground-armor-3      '(300 300 0)
   'zerg-ground-carapace-1   '(150 150 0)
   'ground-carapace-1        '(150 150 0)
   'zerg-flyer-weapons-1     '(100 100 0)
   'zerg-flyer-armor-1       '(150 150 0)
   'stimpack                 '(100 100 0)
   'combat-shield            '(100 100 0)
   'concussive-shells        '(50 50 0)
   'infernal-preigniter      '(100 100 0)
   'infernal-pre-igniter     '(100 100 0)
   'drilling-claws           '(75 75 0)
   'smart-servos             '(100 100 0)
   'banshee-cloak            '(100 100 0)
   'hyperflight-rotors       '(150 150 0)
   'personal-cloaking        '(150 150 0)
   'weapon-refit             '(150 150 0)
   'terran-infantry-weapons-1 '(100 100 0)
   'terran-infantry-weapons-2 '(175 175 0)
   'terran-infantry-weapons-3 '(250 250 0)
   'infantry-weapons-1       '(100 100 0)
   'terran-infantry-armor-1  '(100 100 0)
   'terran-infantry-armor-2  '(175 175 0)
   'terran-infantry-armor-3  '(250 250 0)
   'infantry-armor-1         '(100 100 0)
   'terran-vehicle-weapons-1 '(100 100 0)
   'vehicle-weapons-1        '(100 100 0)
   'terran-vehicle-plating-1 '(100 100 0)
   'terran-ship-weapons-1    '(100 100 0)
   'warpgate                 '(50 50 0)
   'warp-gate-research       '(50 50 0)
   'warpgate-research        '(50 50 0)
   'charge                   '(100 100 0)
   'blink                    '(150 150 0)
   'resonating-glaives       '(100 100 0)
   'shadow-strike            '(100 100 0)
   'psi-storm                '(200 200 0)
   'extended-thermal-lance   '(150 150 0)
   'gravitic-booster         '(100 100 0)
   'gravitic-drive           '(100 100 0)
   'flux-vanes               '(100 100 0)
   'protoss-ground-weapons-1 '(100 100 0)
   'protoss-ground-weapons-2 '(150 150 0)
   'protoss-ground-weapons-3 '(200 200 0)
   'ground-weapons-1         '(100 100 0)
   'protoss-ground-armor-1   '(100 100 0)
   'protoss-ground-armor-2   '(150 150 0)
   'protoss-ground-armor-3   '(200 200 0)
   'ground-armor-1           '(100 100 0)
   'protoss-shields-1        '(150 150 0)
   'protoss-shields-2        '(225 225 0)
   'protoss-shields-3        '(300 300 0)
   'protoss-air-weapons-1    '(100 100 0)
   'protoss-air-weapons-2    '(175 175 0)
   'protoss-air-weapons-3    '(250 250 0)
   'protoss-air-armor-1      '(150 150 0)
   'protoss-air-armor-2      '(225 225 0)
   'protoss-air-armor-3      '(300 300 0)
   'warp-gate                '(50 50 0)
   'adept-piercing-attack    '(100 100 0)
   'cyclone-lock-on-damage   '(100 100 0)
   'zerg-flyer-weapons-2     '(175 175 0)
   'zerg-flyer-weapons-3     '(250 250 0)
   'zerg-flyer-armor-2       '(225 225 0)
   'zerg-flyer-armor-3       '(300 300 0)
   'terran-vehicle-weapons-2 '(175 175 0)
   'terran-vehicle-weapons-3 '(250 250 0)
   'terran-vehicle-plating-2 '(175 175 0)
   'terran-vehicle-plating-3 '(250 250 0)
   'terran-vehicle-and-ship-plating-1 '(100 100 0)
   'terran-vehicle-and-ship-plating-2 '(175 175 0)
   'terran-vehicle-and-ship-plating-3 '(250 250 0)
   'terran-ship-weapons-2    '(175 175 0)
   'terran-ship-weapons-3    '(250 250 0)

   ;; Missing Structures, Flying/Uprooted/Lowered/Rich Variants & Free Add-Ons
   'nydus-network            '(150 150 0)
   'nydus-worm               '(75 75 0)
   'nydus-canal              '(75 75 0)
   'lurker-den-mp            '(100 150 0)
   'command-center-flying    '(400 0 0)
   'orbital-command-flying   '(150 0 0)
   'barracks-flying          '(150 0 0)
   'factory-flying           '(150 100 0)
   'starport-flying          '(150 100 0)
   'supply-depot-lowered     '(100 0 0)
   'extractor-rich           '(25 0 0)
   'assimilator-rich         '(75 0 0)
   'refinery-rich            '(75 0 0)
   'pylon-overcharged        '(100 0 0)
   'spine-crawler-uprooted   '(100 0 0)
   'spore-crawler-uprooted   '(75 0 0)
   'tech-lab                 '(50 25 0)
   'techlab                  '(50 25 0)
   'reactor                  '(50 50 0)

   ;; Unit Mode, Burrowed, Sieged & Cocoon Variants (for tactical trade & ledger valuation)
   'siege-tank-sieged        '(150 125 3)
   'widow-mine-burrowed      '(75 25 2)
   'thor-ap                  '(300 200 6)
   'viking-assault           '(150 75 2)
   'liberator-ag             '(150 125 3)
   'drone-burrowed           '(50 0 1)
   'queen-burrowed           '(150 0 2)
   'zergling-burrowed        '(50 0 1)
   'baneling-burrowed        '(50 25 1)
   'roach-burrowed           '(75 25 2)
   'hydralisk-burrowed       '(100 50 2)
   'lurker-mp                '(50 100 1)
   'lurker-burrowed          '(150 150 3)
   'lurker-mp-burrowed       '(150 150 3)
   'infestor-burrowed        '(100 150 2)
   'swarm-host-burrowed      '(100 75 3)
   'swarmhost                '(100 75 3)
   'ultralisk-burrowed       '(275 200 6)
   'broodlord                '(150 150 2)
   'overlord-transport       '(25 25 0)
   'overseer-siege-mode      '(50 50 0)
   'observer-siege-mode      '(25 75 1)
   'warp-prism-phasing       '(250 0 2)
   'voidray                  '(250 150 4)
   'baneling-cocoon          '(25 25 1)
   'ravager-cocoon           '(25 75 1)
   'ravager-burrowed         '(100 100 3)
   'lurker-egg               '(50 100 1)
   'lurker-mp-egg            '(50 100 1)
   'brood-lord-cocoon        '(150 150 2)
   'overlord-cocoon          '(50 50 0)
   'transport-overlord-cocoon '(25 25 0)
   'point-defense-drone      '(0 0 0)
   'advanced-ballistics      '(150 150 0)))

(define (sc2-min-cost sym [default 50])
  (match (hash-ref SC2-LOTV-COST-TABLE sym #f)
    [(list m _ _) m]
    [_ default]))

(define (sc2-gas-cost sym [default 0])
  (match (hash-ref SC2-LOTV-COST-TABLE sym #f)
    [(list _ g _) g]
    [_ default]))

(define (sc2-supply-cost sym [default 1])
  (match (hash-ref SC2-LOTV-COST-TABLE sym #f)
    [(list _ _ s) s]
    [_ default]))

(define (sc2-can-afford? sym minerals gas [supply-left 200])
  (match (hash-ref SC2-LOTV-COST-TABLE sym #f)
    [(list m g s)
     (and (>= minerals m)
          (>= gas g)
          (or (<= s 0) (>= supply-left s)))]
    [_ #f]))

(define (sc2-race-townhall-min-cost race)
  (case race
    [(Zerg)    (sc2-min-cost 'hatchery)]
    [(Protoss) (sc2-min-cost 'nexus)]
    [(Terran)  (sc2-min-cost 'command-center)]
    [else      (sc2-min-cost 'command-center)]))

;; -----------------------------------------------------------------------------
;; 6. Canonical SC2 Ability Target Mode Classification
;; -----------------------------------------------------------------------------
;; In SC2 s2clientprotocol:
;; - NO-TARGET-ABILITY-IDS must be sent with target_world_space_pos=#f, target_unit_tag=0
;; - POINT-TARGET-ABILITY-IDS must be sent with target_world_space_pos=Point2D, target_unit_tag=0
;; - UNIT-TARGET-ABILITY-IDS must be sent with target_world_space_pos=#f, target_unit_tag=tag
;; Canonical LotV active spell -> ability_id map (ground-truth `s2clientprotocol` IDs):
;;   - `emp-round` = `1628` (`EFFECT_EMP`, PointTarget; never `381`!)
;;   - `oracle-revelation` = `2146` (`EFFECT_ORACLEREVELATION`, PointTarget; `1632` is `TRAIN_QUEEN`!)
;;   - `microbial-shroud` = `2545` (`EFFECT_MICROBIALSHROUD`, PointTarget)
;;   - `guardian-shield` = `76` (`GUARDIANSHIELD_GUARDIANSHIELD`, NoTarget)
(define SC2-SPELL-ABILITY-IDS
  (hasheq
   'emp-round            1628
   'oracle-revelation    2146
   'microbial-shroud     2545
   'guardian-shield      76
   'force-field          1526
   'psi-storm            1036
   'feedback             140
   'fungal-growth        74
   'neural-parasite      249
   'corrosive-bile       2338
   'inject-larva         251
   'transfusion          1664
   'spawn-creep-tumor    1694
   'spread-creep-tumor   1733
   'build-creep-tumor    3691
   'build-nydus-worm     1768
   'calldown-mule        171
   'scanner-sweep        399
   'supply-drop          255
   'stimpack             3675
   'stim-marine          380
   'stim-marauder        253
   'steady-targeting     2714
   'snipe                2714
   'yamato-cannon        401
   'tactical-jump        2358
   'auto-turret          349
   'interference-matrix  3747
   'anti-armor-missile   3753
   'salvage              32
   'chrono-boost         3755
   'battery-overcharge   4107
   'mass-recall          3757
   'blink                3687
   'blink-stalker        1442
   'adept-phase-shift    2544
   'purification-nova    2346
   'stasis-ward          2505
   'pulsar-beam          2375
   'abduct               2067
   'blinding-cloud       2063
   'parasitic-bomb       2542
   'viper-consume        2073
   'spawn-changeling     181))

(define SC2-NO-TARGET-ABILITY-IDS
  (list->seteqv
   '(32    ;; EFFECT_SALVAGE
     181   ;; SPAWNCHANGELING_SPAWNCHANGELING
     253   ;; EFFECT_STIM_MARAUDER
     380   ;; EFFECT_STIM_MARINE
     388   ;; SIEGEMODE_SIEGEMODE
     390   ;; UNSIEGE_UNSIEGE
     392   ;; BEHAVIOR_CLOAKON_BANSHEE
     393   ;; BEHAVIOR_CLOAKOFF_BANSHEE
     403   ;; MORPH_VIKINGASSAULTMODE
     405   ;; MORPH_VIKINGFIGHTERMODE
     76    ;; GUARDIANSHIELD_GUARDIANSHIELD
     154   ;; HALLUCINATION_PHOENIX
     146   ;; HALLUCINATION_ARCHON
     1372  ;; MORPH_BROODLORD
     1448  ;; MORPH_OVERSEER
     1518  ;; MORPH_WARPGATE
     1520  ;; MORPH_GATEWAY
     1766  ;; MORPH_ARCHON
     1978  ;; MORPH_HELLION
     1998  ;; MORPH_HELLBAT
     2095  ;; BURROWDOWN_WIDOWMINE
     2097  ;; BURROWUP_WIDOWMINE
     2108  ;; BURROWDOWN_LURKER
     2110  ;; BURROWUP_LURKER
     2116  ;; EFFECT_MEDIVACIGNITEAFTERBURNERS
     2328  ;; EFFECT_IMMORTALBARRIER
     2362  ;; MORPH_THORHIGHIMPACTMODE
     2364  ;; MORPH_THOREXPLOSIVEMODE
     2375  ;; BEHAVIOR_PULSARBEAMON
     2376  ;; BEHAVIOR_PULSARBEAMOFF
     2393  ;; EFFECT_VOIDRAYPRISMATICALIGNMENT
     2560  ;; MORPH_LIBERATORAAMODE
     2708  ;; MORPH_OVERLORDTRANSPORT
     556   ;; MORPH_SUPPLYDEPOT_LOWER
     558   ;; MORPH_SUPPLYDEPOT_RAISE
     3661  ;; BURROWDOWN
     3662  ;; BURROWUP
     3675  ;; EFFECT_STIM
     3679  ;; LIFT
     3739  ;; MORPH_OBSERVERMODE
     3741  ;; MORPH_OBSERVERSIEGEMODE
     3743  ;; MORPH_OVERSEERMODE
     3745  ;; MORPH_OVERSIGHTMODE
     1528  ;; MORPH_WARPPRISMPHASINGMODE
     1530  ;; MORPH_WARPPRISMTRANSPORTMODE
     1042  ;; BUILD_INTERCEPTORS
     )))

(define SC2-POINT-TARGET-ABILITY-IDS
  (list->seteqv
   '(74    ;; FUNGALGROWTH_FUNGALGROWTH
     349   ;; BUILD_AUTOTURRET
     399   ;; SCAN_MOVE (Scanner Sweep)
     1036  ;; PSISTORM_PSISTORM
     1442  ;; EFFECT_BLINK_STALKER
     1526  ;; FORCEFIELD_FORCEFIELD
     1628  ;; EMP_EMP
     1694  ;; BUILD_CREEPTUMOR_QUEEN
     1733  ;; BUILD_CREEPTUMOR_TUMOR
     1768  ;; BUILD_NYDUSWORM
     1990  ;; EFFECT_SPAWNLOCUSTS
     2063  ;; BLINDINGCLOUD_BLINDINGCLOUD
     2146  ;; ORACLEREVELATION_ORACLEREVELATION
     2338  ;; EFFECT_CORROSIVEBILE
     2346  ;; EFFECT_PURIFICATIONNOVA
     2358  ;; EFFECT_TACTICALJUMP
     2505  ;; BUILD_STASISTRAP
     2544  ;; EFFECT_ADEPTPHASESHIFT
     2545  ;; EFFECT_MICROBIALSHROUD
     2558  ;; MORPH_LIBERATORAGMODE
     2588  ;; KD8CHARGE_KD8CHARGE
     3678  ;; LAND
     3687  ;; EFFECT_BLINK
     3691  ;; BUILD_CREEPTUMOR
     3757  ;; EFFECT_MASSRECALL_NEXUS
     )))

(define SC2-UNIT-TARGET-ABILITY-IDS
  (list->seteqv
   '(140   ;; FEEDBACK_FEEDBACK
     171   ;; EFFECT_CALLDOWNMULE
     173   ;; GRAVITONBEAM_GRAVITONBEAM
     249   ;; NEURALPARASITE_NEURALPARASITE
     251   ;; EFFECT_INJECTLARVA
     255   ;; EFFECT_SUPPLYDROP
     386   ;; EFFECT_HEAL
     401   ;; YAMATO_YAMATOGUN
     1664  ;; TRANSFUSION_TRANSFUSION
     1825  ;; CONTAMINATE_CONTAMINATE
     2067  ;; EFFECT_ABDUCT
     2069  ;; VIPERCONSUMESTRUCTURE
     2073  ;; VIPERCONSUME_VIPERCONSUME
     2324  ;; EFFECT_CAUSTICSPRAY
     2542  ;; EFFECT_PARASITICBOMB
     2714  ;; EFFECT_GHOSTSNIPE (Steady Targeting)
     3685  ;; EFFECT_REPAIR
     3747  ;; EFFECT_INTERFERENCEMATRIX
     3753  ;; EFFECT_ANTIARMORMISSILE
     3755  ;; EFFECT_CHRONOBOOSTENERGYCOST
     4107  ;; BATTERYOVERCHARGE_BATTERYOVERCHARGE
     )))

;; -----------------------------------------------------------------------------
;; 7. Tactical Mirror Brain, In-Progress Order Ledger, Control Groups & Walling
;; -----------------------------------------------------------------------------
(define SC2-TACTICAL-ARENA-CLUSTER-RADIUS   12.0)  ;; Squad linkage radius (tiles)
(define SC2-TACTICAL-ARENA-ENGAGE-RADIUS    18.0)  ;; Enemy inclusion radius (tiles)
(define SC2-TACTICAL-REINFORCE-RADIUS       36.0)  ;; Reinforcement horizon radius (tiles)
(define SC2-TACTICAL-SIM-DT-SEC             0.25)  ;; 5.6 frames per kinematic tick
(define SC2-TACTICAL-DEPTH1-SEC             0.50)  ;; 11 frames (2 ticks): immediate swing
(define SC2-TACTICAL-DEPTH2-SEC             2.00)  ;; 45 frames (8 ticks): skirmish trade
(define SC2-TACTICAL-DEPTH3-SEC             5.00)  ;; 112 frames (20 ticks): fight & reinf
(define SC2-TACTICAL-DEPTH1-WEIGHT          0.30)
(define SC2-TACTICAL-DEPTH2-WEIGHT          0.45)
(define SC2-TACTICAL-DEPTH3-WEIGHT          0.25)
(define SC2-TACTICAL-MINIMAX-LAMBDA         0.35)  ;; Weight on worst-case enemy counter
(define SC2-TACTICAL-HYSTERESIS-BONUS       18.0)  ;; Stickiness bonus for current micro action
(define SC2-TACTICAL-PREEMPT-MULTIPLIER     2.50)  ;; Multiplier to break lock early
(define SC2-TACTICAL-MIN-LOCK-FRAMES        11)    ;; ~0.5s minimum micro commitment
(define SC2-TACTICAL-RETREAT-LOCK-FRAMES    22)    ;; ~1.0s commitment for retreat/harass
(define SC2-WEAPON-READY-COOLDOWN-THRESH    0.08)  ;; Cooldown threshold to issue fire order
(define SC2-WEAPON-KITE-COOLDOWN-THRESH     0.15)  ;; Cooldown threshold to kite during backswing
(define SC2-BANSHEE-CLOAK-MIN-ENERGY        25)
(define SC2-WORKER-KILL-ECONOMIC-VALUE      75.0)
(define SC2-HERO-UNIT-LOSS-PENALTY          60.0)
(define SC2-POSITIONAL-SURVIVAL-BONUS       15.0)

;; In-Progress Order Tracking, Deduplication & Build-Site Reservation Constants
(define SC2-ORDER-EQUIV-DIST-TOLERANCE      1.75)  ;; Tiles within which a move/attack-pos order is equivalent
(define SC2-ORDER-LEDGER-TTL-FRAMES         45)    ;; ~2.0s in-flight order memory before engine expiry
(define SC2-BUILD-SITE-RESERVATION-TTL      180)   ;; ~8.0s build-site footprint reservation while builder walks
(define SC2-BUILD-SITE-MIN-CLEARANCE        3.0)   ;; Minimum clearance around reserved in-transit build site
(define SC2-MAX-PENDING-SUPPLY-EARLY        1)     ;; Max concurrent supply providers when supply-cap < 66
(define SC2-MAX-PENDING-SUPPLY-LATE         2)     ;; Max concurrent supply providers when supply-cap >= 66

;; Camera Hotkey & Control Group Constants
(define SC2-CONTROL-GROUP-COUNT             10)    ;; Groups 0..9
(define SC2-CONTROL-GROUP-ACTION-RECALL           1)
(define SC2-CONTROL-GROUP-ACTION-SET              2)
(define SC2-CONTROL-GROUP-ACTION-APPEND           3)
(define SC2-CONTROL-GROUP-ACTION-SET-AND-STEAL    4)
(define SC2-CONTROL-GROUP-ACTION-APPEND-AND-STEAL 5)
(define SC2-CAMERA-BOOKMARK-COUNT           8)     ;; Slots 1..8 (F1..F8)
(define SC2-CAMERA-SACCADE-MIN-DWELL-FRAMES 16)    ;; ~0.71s minimum fixation dwell between routine jumps
(define SC2-CAMERA-MOVE-DEDUP-DIST          2.0)   ;; Minimum camera shift (tiles) to emit ActionRawCameraMove
(define SC2-BOOKMARK-DRIFT-UPDATE-DIST      4.0)   ;; Minimum drift (tiles) to re-save dynamic camera bookmark

;; Terran Ramp Wall-In & East (+X) Add-on Geometry Constants
(define SC2-TERRAN-ADDON-OFFSET-X           2.5)   ;; Add-on center X offset from 3x3 facility center
(define SC2-TERRAN-ADDON-OFFSET-Y          -0.5)   ;; Add-on center Y offset from 3x3 facility center
(define SC2-TERRAN-ADDON-CLEARANCE-RADIUS   1.6)   ;; Reserved radius around (bx + 2.5, by - 0.5)
(define SC2-ADDON-FOOTPRINT-HALF-SIZE       1.6)   ;; Alias for add-on footprint clearance radius
(define SC2-TERRAN-FACILITY-STEP-X          6.0)   ;; Horizontal spacing for 3x3 facility + 2x2 add-on (5+1 tiles)
(define SC2-TERRAN-FACILITY-STEP-Y          3.5)   ;; Vertical spacing for 3x3 facility rows
(define SC2-DEPOT-RAISE-THREAT-RADIUS       10.0)  ;; Raise Supply Depot when enemy ground unit within 10 tiles
(define SC2-DEPOT-RAISE-ENEMY-RADIUS        10.0)  ;; Alias for depot raise threat radius
(define SC2-RAMP-SEARCH-MIN-RADIUS          5.0)
(define SC2-RAMP-SEARCH-MAX-RADIUS          24.0)

;; -----------------------------------------------------------------------------
;; 8. Canonical SC2 LotV Unit Combat & Kinematic Stats Table
;; -----------------------------------------------------------------------------
(define SC2-UNIT-COMBAT-STATS-TABLE
  (hasheq
   ;; Workers
   'scv               (hasheq 'max-hp 45  'max-shield 0   'armor 0 'speed 3.94 'ground-dps 4.7  'air-dps 0.0  'ground-range 0.1  'air-range 0.0  'weapon-period 1.07  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   'probe             (hasheq 'max-hp 20  'max-shield 20  'armor 0 'speed 3.94 'ground-dps 4.7  'air-dps 0.0  'ground-range 0.1  'air-range 0.0  'weapon-period 1.07  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   'drone             (hasheq 'max-hp 40  'max-shield 0   'armor 0 'speed 3.94 'ground-dps 4.7  'air-dps 0.0  'ground-range 0.1  'air-range 0.0  'weapon-period 1.07  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   ;; Terran Combat & Support
   'marine            (hasheq 'max-hp 45  'max-shield 0   'armor 0 'speed 3.15 'ground-dps 9.8  'air-dps 9.8  'ground-range 5.0  'air-range 5.0  'weapon-period 0.61  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   'marauder          (hasheq 'max-hp 125 'max-shield 0   'armor 1 'speed 3.15 'ground-dps 13.9 'air-dps 0.0  'ground-range 6.0  'air-range 0.0  'weapon-period 1.07  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5625)
   'reaper            (hasheq 'max-hp 60  'max-shield 0   'armor 0 'speed 5.25 'ground-dps 10.1 'air-dps 0.0  'ground-range 5.0  'air-range 0.0  'weapon-period 0.79  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   'ghost             (hasheq 'max-hp 100 'max-shield 0   'armor 0 'speed 3.94 'ground-dps 14.4 'air-dps 14.4 'ground-range 6.0  'air-range 6.0  'weapon-period 1.07  'damage-point 0.08 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.375)
   'hellion           (hasheq 'max-hp 90  'max-shield 0   'armor 0 'speed 5.95 'ground-dps 6.5  'air-dps 0.0  'ground-range 5.0  'air-range 0.0  'weapon-period 1.79  'damage-point 0.18 'splash-radius 0.8  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.625)
   'hellbat           (hasheq 'max-hp 135 'max-shield 0   'armor 0 'speed 3.15 'ground-dps 16.8 'air-dps 0.0  'ground-range 2.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.18 'splash-radius 1.2  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.625)
   'widow-mine        (hasheq 'max-hp 90  'max-shield 0   'armor 0 'speed 3.94 'ground-dps 0.0  'air-dps 0.0  'ground-range 5.0  'air-range 5.0  'weapon-period 29.0  'damage-point 1.07 'splash-radius 1.75 'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.5)
   'widow-mine-burrowed (hasheq 'max-hp 90 'max-shield 0  'armor 0 'speed 0.0  'ground-dps 25.0 'air-dps 25.0 'ground-range 5.0  'air-range 5.0  'weapon-period 29.0  'damage-point 1.07 'splash-radius 1.75 'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.5)
   'cyclone           (hasheq 'max-hp 130 'max-shield 0   'armor 1 'speed 4.13 'ground-dps 22.4 'air-dps 22.4 'ground-range 6.0  'air-range 6.0  'weapon-period 0.48  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.75)
   'siege-tank        (hasheq 'max-hp 175 'max-shield 0   'armor 1 'speed 3.15 'ground-dps 26.0 'air-dps 0.0  'ground-range 7.0  'air-range 0.0  'weapon-period 1.49  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.875)
   'siege-tank-sieged (hasheq 'max-hp 175 'max-shield 0   'armor 1 'speed 0.0  'ground-dps 23.4 'air-dps 0.0  'ground-range 13.0 'air-range 0.0  'weapon-period 2.14  'damage-point 0.12 'splash-radius 1.25 'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.875)
   'thor              (hasheq 'max-hp 400 'max-shield 0   'armor 1 'speed 2.62 'ground-dps 65.9 'air-dps 33.6 'ground-range 7.0  'air-range 11.0 'weapon-period 0.91  'damage-point 0.25 'splash-radius 0.5  'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
   'viking            (hasheq 'max-hp 135 'max-shield 0   'armor 0 'speed 3.85 'ground-dps 0.0  'air-dps 14.0 'ground-range 0.0  'air-range 9.0  'weapon-period 1.43  'damage-point 0.08 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'viking-fighter    (hasheq 'max-hp 135 'max-shield 0   'armor 0 'speed 3.85 'ground-dps 0.0  'air-dps 14.0 'ground-range 0.0  'air-range 9.0  'weapon-period 1.43  'damage-point 0.08 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'viking-assault    (hasheq 'max-hp 135 'max-shield 0   'armor 0 'speed 3.15 'ground-dps 16.8 'air-dps 0.0  'ground-range 6.0  'air-range 0.0  'weapon-period 0.71  'damage-point 0.08 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.75)
   'medivac           (hasheq 'max-hp 150 'max-shield 0   'armor 1 'speed 3.50 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'liberator         (hasheq 'max-hp 180 'max-shield 0   'armor 0 'speed 4.72 'ground-dps 35.0 'air-dps 7.8  'ground-range 10.0 'air-range 5.0  'weapon-period 1.14  'damage-point 0.12 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'raven             (hasheq 'max-hp 140 'max-shield 0   'armor 1 'speed 4.13 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #t 'can-cloak? #f 'radius 0.625)
   'banshee           (hasheq 'max-hp 140 'max-shield 0   'armor 0 'speed 3.85 'ground-dps 27.0 'air-dps 0.0  'ground-range 6.0  'air-range 0.0  'weapon-period 0.89  'damage-point 0.17 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #t 'radius 0.75)
   'battlecruiser     (hasheq 'max-hp 550 'max-shield 0   'armor 3 'speed 2.62 'ground-dps 49.8 'air-dps 31.1 'ground-range 6.0  'air-range 6.0  'weapon-period 0.16  'damage-point 0.04 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 1.25)
   'missile-turret    (hasheq 'max-hp 250 'max-shield 0   'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 39.3 'ground-range 0.0  'air-range 7.0  'weapon-period 0.61  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #t 'can-cloak? #f 'radius 1.0)
   'bunker            (hasheq 'max-hp 400 'max-shield 0   'armor 1 'speed 0.0  'ground-dps 39.2 'air-dps 39.2 'ground-range 6.0  'air-range 6.0  'weapon-period 0.61  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.5)
   'planetary-fortress (hasheq 'max-hp 1500 'max-shield 0 'armor 3 'speed 0.0  'ground-dps 28.0 'air-dps 0.0  'ground-range 6.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.12 'splash-radius 1.25 'flying? #f 'detector? #f 'can-cloak? #f 'radius 2.5)
   ;; Zerg Combat & Support
   'overlord          (hasheq 'max-hp 200 'max-shield 0   'armor 0 'speed 0.90 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'queen             (hasheq 'max-hp 175 'max-shield 0   'armor 1 'speed 1.31 'ground-dps 11.2 'air-dps 12.6 'ground-range 5.0  'air-range 8.0  'weapon-period 0.71  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.875)
   'zergling          (hasheq 'max-hp 35  'max-shield 0   'armor 0 'speed 4.13 'ground-dps 10.0 'air-dps 0.0  'ground-range 0.1  'air-range 0.0  'weapon-period 0.497 'damage-point 0.08 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   'baneling          (hasheq 'max-hp 30  'max-shield 0   'armor 0 'speed 3.50 'ground-dps 80.0 'air-dps 0.0  'ground-range 0.25 'air-range 0.0  'weapon-period 1.0   'damage-point 0.05 'splash-radius 2.2  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   'roach             (hasheq 'max-hp 145 'max-shield 0   'armor 1 'speed 3.15 'ground-dps 11.2 'air-dps 0.0  'ground-range 4.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5)
   'ravager           (hasheq 'max-hp 120 'max-shield 0   'armor 1 'speed 3.85 'ground-dps 14.0 'air-dps 0.0  'ground-range 6.0  'air-range 0.0  'weapon-period 1.14  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.75)
   'hydralisk         (hasheq 'max-hp 90  'max-shield 0   'armor 0 'speed 3.15 'ground-dps 20.4 'air-dps 20.4 'ground-range 6.0  'air-range 6.0  'weapon-period 0.59  'damage-point 0.07 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.625)
   'lurker            (hasheq 'max-hp 200 'max-shield 0   'armor 1 'speed 4.13 'ground-dps 20.0 'air-dps 0.0  'ground-range 8.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.18 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.75)
   'lurker-burrowed   (hasheq 'max-hp 200 'max-shield 0   'armor 1 'speed 0.0  'ground-dps 20.0 'air-dps 0.0  'ground-range 8.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.18 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.75)
   'mutalisk          (hasheq 'max-hp 120 'max-shield 0   'armor 0 'speed 5.60 'ground-dps 11.9 'air-dps 11.9 'ground-range 3.0  'air-range 3.0  'weapon-period 1.09  'damage-point 0.08 'splash-radius 1.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.5)
   'corruptor         (hasheq 'max-hp 200 'max-shield 0   'armor 2 'speed 4.72 'ground-dps 0.0  'air-dps 14.7 'ground-range 0.0  'air-range 6.0  'weapon-period 1.36  'damage-point 0.10 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.625)
   'brood-lord        (hasheq 'max-hp 225 'max-shield 0   'armor 1 'speed 1.97 'ground-dps 22.4 'air-dps 0.0  'ground-range 10.0 'air-range 0.0  'weapon-period 1.79  'damage-point 0.12 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 1.0)
   'ultralisk         (hasheq 'max-hp 500 'max-shield 0   'armor 2 'speed 4.13 'ground-dps 57.4 'air-dps 0.0  'ground-range 1.0  'air-range 0.0  'weapon-period 0.61  'damage-point 0.16 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
   'overseer          (hasheq 'max-hp 200 'max-shield 0   'armor 1 'speed 4.72 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #t 'can-cloak? #f 'radius 0.75)
   'spine-crawler     (hasheq 'max-hp 300 'max-shield 0   'armor 2 'speed 0.0  'ground-dps 20.2 'air-dps 0.0  'ground-range 7.0  'air-range 0.0  'weapon-period 1.32  'damage-point 0.15 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
   'spore-crawler     (hasheq 'max-hp 400 'max-shield 0   'armor 1 'speed 0.0  'ground-dps 0.0  'air-dps 24.6 'ground-range 0.0  'air-range 7.0  'weapon-period 0.61  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #t 'can-cloak? #f 'radius 1.0)
   ;; Protoss Combat & Support
   'zealot            (hasheq 'max-hp 100 'max-shield 50  'armor 1 'speed 3.15 'ground-dps 18.6 'air-dps 0.0  'ground-range 0.1  'air-range 0.0  'weapon-period 0.86  'damage-point 0.10 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5)
   'stalker           (hasheq 'max-hp 80  'max-shield 80  'armor 1 'speed 4.13 'ground-dps 13.4 'air-dps 13.4 'ground-range 6.0  'air-range 6.0  'weapon-period 1.34  'damage-point 0.17 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.625)
   'sentry            (hasheq 'max-hp 40  'max-shield 40  'armor 1 'speed 3.15 'ground-dps 8.4  'air-dps 8.4  'ground-range 5.0  'air-range 5.0  'weapon-period 0.71  'damage-point 0.08 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5)
   'adept             (hasheq 'max-hp 70  'max-shield 70  'armor 1 'speed 3.50 'ground-dps 9.6  'air-dps 0.0  'ground-range 4.0  'air-range 0.0  'weapon-period 1.61  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5)
   'high-templar      (hasheq 'max-hp 40  'max-shield 40  'armor 0 'speed 2.62 'ground-dps 3.2  'air-dps 0.0  'ground-range 6.0  'air-range 0.0  'weapon-period 1.25  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
   'dark-templar      (hasheq 'max-hp 40  'max-shield 80  'armor 1 'speed 3.94 'ground-dps 37.2 'air-dps 0.0  'ground-range 0.1  'air-range 0.0  'weapon-period 1.21  'damage-point 0.25 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.375)
   'archon            (hasheq 'max-hp 10  'max-shield 350 'armor 0 'speed 3.94 'ground-dps 25.0 'air-dps 25.0 'ground-range 3.0  'air-range 3.0  'weapon-period 1.25  'damage-point 0.18 'splash-radius 1.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
   'immortal          (hasheq 'max-hp 200 'max-shield 100 'armor 1 'speed 3.15 'ground-dps 29.0 'air-dps 0.0  'ground-range 6.0  'air-range 0.0  'weapon-period 1.04  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.75)
   'colossus          (hasheq 'max-hp 200 'max-shield 150 'armor 1 'speed 3.15 'ground-dps 26.8 'air-dps 0.0  'ground-range 9.0  'air-range 0.0  'weapon-period 1.07  'damage-point 0.16 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
   'disruptor         (hasheq 'max-hp 100 'max-shield 100 'armor 1 'speed 3.15 'ground-dps 20.0 'air-dps 0.0  'ground-range 9.0  'air-range 0.0  'weapon-period 21.4  'damage-point 1.50 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5)
   'observer          (hasheq 'max-hp 40  'max-shield 20  'armor 0 'speed 3.01 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #t 'can-cloak? #t 'radius 0.375)
   'phoenix           (hasheq 'max-hp 120 'max-shield 60  'armor 0 'speed 5.95 'ground-dps 0.0  'air-dps 14.0 'ground-range 0.0  'air-range 5.0  'weapon-period 0.79  'damage-point 0.06 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'void-ray          (hasheq 'max-hp 150 'max-shield 100 'armor 0 'speed 3.85 'ground-dps 22.4 'air-dps 22.4 'ground-range 6.0  'air-range 6.0  'weapon-period 0.36  'damage-point 0.05 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.875)
   'oracle            (hasheq 'max-hp 100 'max-shield 60  'armor 0 'speed 5.60 'ground-dps 24.4 'air-dps 0.0  'ground-range 4.0  'air-range 0.0  'weapon-period 0.61  'damage-point 0.05 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'carrier           (hasheq 'max-hp 300 'max-shield 150 'armor 2 'speed 2.62 'ground-dps 37.5 'air-dps 37.5 'ground-range 8.0  'air-range 8.0  'weapon-period 2.14  'damage-point 0.10 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 1.25)
   'interceptor       (hasheq 'max-hp 40  'max-shield 40  'armor 0 'speed 10.5 'ground-dps 5.0  'air-dps 5.0  'ground-range 2.0  'air-range 2.0  'weapon-period 2.14  'damage-point 0.10 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.25)
   'tempest           (hasheq 'max-hp 200 'max-shield 100 'armor 2 'speed 3.15 'ground-dps 16.8 'air-dps 14.3 'ground-range 10.0 'air-range 14.0 'weapon-period 2.36  'damage-point 0.15 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 1.25)
   'photon-cannon     (hasheq 'max-hp 150 'max-shield 150 'armor 1 'speed 0.0  'ground-dps 22.4 'air-dps 22.4 'ground-range 7.0  'air-range 7.0  'weapon-period 0.89  'damage-point 0.08 'splash-radius 0.0  'flying? #f 'detector? #t 'can-cloak? #f 'radius 1.0)
    'oracle-stasis-trap (hasheq 'max-hp 30  'max-shield 30  'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 4.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 4.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.5  'attribute 'Light)
    'stasis-ward       (hasheq 'max-hp 30  'max-shield 30  'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 4.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 4.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.5  'attribute 'Light)
    'roach-burrowed    (hasheq 'max-hp 145 'max-shield 0   'armor 1 'speed 2.80 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.5)
    'infestor          (hasheq 'max-hp 90  'max-shield 0   'armor 0 'speed 3.15 'ground-dps 0.0  'air-dps 0.0  'ground-range 10.0 'air-range 10.0 'weapon-period 1.0   'damage-point 0.0  'splash-radius 2.25 'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.75)
    'infestor-burrowed (hasheq 'max-hp 90  'max-shield 0   'armor 0 'speed 2.80 'ground-dps 0.0  'air-dps 0.0  'ground-range 10.0 'air-range 10.0 'weapon-period 1.0   'damage-point 0.0  'splash-radius 2.25 'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.75)
    'swarm-host        (hasheq 'max-hp 160 'max-shield 0   'armor 1 'speed 4.13 'ground-dps 18.0 'air-dps 0.0  'ground-range 10.0 'air-range 0.0  'weapon-period 2.0   'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.875)
    'swarm-host-burrowed (hasheq 'max-hp 160 'max-shield 0 'armor 1 'speed 0.0  'ground-dps 18.0 'air-dps 0.0  'ground-range 10.0 'air-range 0.0  'weapon-period 2.0   'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.875)
    'viper             (hasheq 'max-hp 150 'max-shield 0   'armor 1 'speed 4.13 'ground-dps 0.0  'air-dps 0.0  'ground-range 9.0  'air-range 9.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 2.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.875)
    'mothership        (hasheq 'max-hp 350 'max-shield 350 'armor 2 'speed 2.62 'ground-dps 37.8 'air-dps 37.8 'ground-range 7.0  'air-range 7.0  'weapon-period 1.58  'damage-point 0.10 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #t 'radius 1.375)
    ;; Alt-Mode, Sieged, Burrowed, Transport & Summoned Combat Stats
    'thor-ap           (hasheq 'max-hp 400 'max-shield 0   'armor 1 'speed 2.62 'ground-dps 65.9 'air-dps 40.0 'ground-range 7.0  'air-range 10.0 'weapon-period 0.91  'damage-point 0.25 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
    'liberator-ag      (hasheq 'max-hp 180 'max-shield 0   'armor 0 'speed 0.0  'ground-dps 65.8 'air-dps 0.0  'ground-range 10.0 'air-range 0.0  'weapon-period 1.14  'damage-point 0.12 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
    'observer-siege-mode (hasheq 'max-hp 40 'max-shield 20 'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #t 'can-cloak? #t 'radius 0.375)
    'overseer-siege-mode (hasheq 'max-hp 200 'max-shield 0 'armor 1 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #t 'can-cloak? #f 'radius 0.75)
    'warp-prism        (hasheq 'max-hp 80  'max-shield 100 'armor 0 'speed 4.13 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.875)
    'warp-prism-phasing (hasheq 'max-hp 80 'max-shield 100 'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.875)
    'overlord-transport (hasheq 'max-hp 200 'max-shield 0  'armor 0 'speed 0.90 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
    'lurker-mp         (hasheq 'max-hp 200 'max-shield 0   'armor 1 'speed 4.13 'ground-dps 20.0 'air-dps 0.0  'ground-range 8.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.18 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.75)
    'lurker-mp-burrowed (hasheq 'max-hp 200 'max-shield 0  'armor 1 'speed 0.0  'ground-dps 20.0 'air-dps 0.0  'ground-range 8.0  'air-range 0.0  'weapon-period 1.43  'damage-point 0.18 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.75)
    'zergling-burrowed (hasheq 'max-hp 35  'max-shield 0   'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 0.497 'damage-point 0.08 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.375)
    'baneling-burrowed (hasheq 'max-hp 30  'max-shield 0   'armor 0 'speed 0.0  'ground-dps 80.0 'air-dps 0.0  'ground-range 0.25 'air-range 0.0  'weapon-period 1.0   'damage-point 0.05 'splash-radius 2.2  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.375)
    'hydralisk-burrowed (hasheq 'max-hp 90 'max-shield 0   'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 0.59  'damage-point 0.07 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.625)
    'ultralisk-burrowed (hasheq 'max-hp 500 'max-shield 0  'armor 2 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 0.61  'damage-point 0.16 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #t 'radius 1.0)
    'queen-burrowed    (hasheq 'max-hp 175 'max-shield 0   'armor 1 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 0.71  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.875)
    'drone-burrowed    (hasheq 'max-hp 40  'max-shield 0   'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.07  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.375)
    'spine-crawler-uprooted (hasheq 'max-hp 300 'max-shield 0 'armor 2 'speed 1.40 'ground-dps 0.0 'air-dps 0.0 'ground-range 0.0 'air-range 0.0 'weapon-period 1.32 'damage-point 0.15 'splash-radius 0.0 'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
    'spore-crawler-uprooted (hasheq 'max-hp 400 'max-shield 0 'armor 1 'speed 1.40 'ground-dps 0.0 'air-dps 0.0 'ground-range 0.0 'air-range 0.0 'weapon-period 0.61 'damage-point 0.05 'splash-radius 0.0 'flying? #f 'detector? #f 'can-cloak? #f 'radius 1.0)
    'locust            (hasheq 'max-hp 50  'max-shield 0   'armor 0 'speed 2.62 'ground-dps 23.3 'air-dps 0.0  'ground-range 3.0  'air-range 0.0  'weapon-period 0.43  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.375)
    'locust-flying     (hasheq 'max-hp 50  'max-shield 0   'armor 0 'speed 2.62 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.375)
    'broodling         (hasheq 'max-hp 30  'max-shield 0   'armor 0 'speed 5.37 'ground-dps 8.7  'air-dps 0.0  'ground-range 0.1  'air-range 0.0  'weapon-period 0.46  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.25)
    'mule              (hasheq 'max-hp 60  'max-shield 0   'armor 0 'speed 3.94 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5)
    'ravager-burrowed  (hasheq 'max-hp 120 'max-shield 0   'armor 1 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.14  'damage-point 0.12 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.75)
    'transport-overlord-cocoon (hasheq 'max-hp 200 'max-shield 0 'armor 0 'speed 0.0 'ground-dps 0.0 'air-dps 0.0 'ground-range 0.0 'air-range 0.0 'weapon-period 1.0 'damage-point 0.0 'splash-radius 0.0 'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
    'point-defense-drone (hasheq 'max-hp 50 'max-shield 0  'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.5)
    'auto-turret       (hasheq 'max-hp 150 'max-shield 0   'armor 1 'speed 0.0  'ground-dps 31.5 'air-dps 31.5 'ground-range 6.0  'air-range 6.0  'weapon-period 0.57  'damage-point 0.05 'splash-radius 0.0  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.75)))

(define (sc2-unit-combat-stats sym)
  (hash-ref SC2-UNIT-COMBAT-STATS-TABLE sym
            (lambda ()
              (hasheq 'max-hp 80 'max-shield 0 'armor 0 'speed 3.15
                      'ground-dps 10.0 'air-dps 0.0 'ground-range 5.0 'air-range 0.0
                      'weapon-period 1.0 'damage-point 0.10 'splash-radius 0.0
                      'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5))))

(define (sc2-unit-can-attack-air? sym)
  (> (hash-ref (sc2-unit-combat-stats sym) 'air-dps 0.0) 0.0))

(define (sc2-unit-can-attack-ground? sym)
  (> (hash-ref (sc2-unit-combat-stats sym) 'ground-dps 0.0) 0.0))

(define (sc2-unit-is-detector-sym? sym)
  (eq? (hash-ref (sc2-unit-combat-stats sym) 'detector? #f) #t))

(define (sc2-unit-is-flying-sym? sym)
  (eq? (hash-ref (sc2-unit-combat-stats sym) 'flying? #f) #t))

;; Invulnerable shades, phased projectiles, eggs/larvae, and decoys that should
;; never be selected as primary combat attack targets:
(define SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS
  '(adept-phase-shift
    disruptor-phased
    kd8-charge
    parasitic-bomb-dummy
    larva
    egg
    cocoon
    broodling-escort
    changeling
    changeling-zealot
    changeling-marine-shield
    changeling-marine
    changeling-zergling-wings
    changeling-zergling))

;; Non-combat scouts, summoned minions/interceptors, and untargetable units that
;; should be heavily de-prioritized in favor of parent Carriers / Brood Lords / real threats:
(define SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS
  '(adept-phase-shift
    disruptor-phased
    kd8-charge
    parasitic-bomb-dummy
    larva
    egg
    cocoon
    broodling-escort
    broodling
    interceptor
    locust
    locust-flying
    changeling
    changeling-zealot
    changeling-marine-shield
    changeling-marine
    changeling-zergling-wings
    changeling-zergling
    overlord
    overlord-cocoon
    overseer
    overseer-siege-mode
    observer
    observer-siege-mode))

(define SC2-ALL-STRUCTURE-SYMS
  '(hatchery lair hive extractor extractor-rich spawning-pool roach-warren baneling-nest
    evolution-chamber hydralisk-den lurker-den lurker-den-mp spire greater-spire
    infestation-pit ultralisk-cavern spine-crawler spine-crawler-uprooted
    spore-crawler spore-crawler-uprooted nydus-network nydus-worm nydus-canal
    creep-tumor creep-tumor-burrowed creep-tumor-queen
    nexus pylon pylon-overcharged assimilator assimilator-rich
    gateway warp-gate warpgate cybernetics-core forge
    photon-cannon shield-battery twilight-council robotics-facility robotics-bay
    robotics-support-bay stargate fleet-beacon templar-archive templar-archives dark-shrine
    oracle-stasis-trap
    command-center command-center-flying orbital-command orbital-command-flying
    planetary-fortress supply-depot supply-depot-lowered
    refinery refinery-rich barracks barracks-flying factory factory-flying
    starport starport-flying engineering-bay bunker missile-turret
    sensor-tower ghost-academy armory fusion-core
    barracks-techlab barracks-tech-lab barracks-reactor
    factory-techlab factory-tech-lab factory-reactor
    starport-techlab starport-tech-lab starport-reactor
    tech-lab techlab reactor))

;; Terran units that strictly require a completed TechLab attached to their producer:
(define SC2-TECHLAB-REQUIRED-UNIT-SYMS
  '(marauder
    ghost
    siege-tank
    thor
    banshee
    raven
    battlecruiser))

(define (sc2-unit-requires-techlab? sym)
  (and (memq sym SC2-TECHLAB-REQUIRED-UNIT-SYMS) #t))

(define (sc2-enemy-unit-targetable? e)
  (cond
    [(hash? e)
     (and (not (memq (hash-ref e 'type 'unknown) SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS))
          (not (eq? (hash-ref e 'hallucination #f) #t)))]
    [(symbol? e)
     (not (memq e SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS))]
    [else #t]))

(define (sc2-attacker-can-hit-enemy? attacker-sym e [enemy-flying-override #f])
  (define eflying?
    (cond
      [(hash? e)
       (or (eq? (hash-ref e 'flying #f) #t)
           (eq? (hash-ref e 'flying? #f) #t)
           (eq? (hash-ref e 'is-flying #f) #t)
           (sc2-unit-is-flying-sym? (hash-ref e 'type 'marine)))]
      [(symbol? e)
       (or (eq? enemy-flying-override #t)
           (sc2-unit-is-flying-sym? e))]
      [else (eq? enemy-flying-override #t)]))
  (and (sc2-enemy-unit-targetable? e)
       (if eflying?
           (sc2-unit-can-attack-air? attacker-sym)
           (sc2-unit-can-attack-ground? attacker-sym))))

;; -----------------------------------------------------------------------------
;; 9. Empirical 1,649/1,685-Replay Stealth, Burrow-Move, Detector-Sniping,
;;    Shimmer/Ripple, Upgrade-Timing, Terran Add-On Swap & Depletion Constants
;; -----------------------------------------------------------------------------
;; Detector-sniping & 60s post-snipe stealth unlock (`benchmarks/full_corpus_stealth_burrow_detector_report.json`):
;;   - 65.6% mobile detector mortality across 1,649 replays
;;   - 58.2% win rate when sniping enemy detectors
;;   - 651.0 avg post-snipe resource damage inflicted in the 60s (1,344-frame) stealth window
(define SC2-DETECTOR-SNIPE-PRIORITY-BONUS         3.5)
(define SC2-POST-SNIPE-STEALTH-UNLOCK-FRAMES      1344)   ;; 60.0s at 22.4 fps
(define SC2-POST-SNIPE-EXPECTED-DAMAGE-RES        651.0)
(define SC2-MOBILE-DETECTOR-SYMS
  '(observer observer-siege-mode overseer overseer-siege-mode raven))
(define SC2-STATIC-DETECTOR-SYMS
  '(missile-turret photon-cannon spore-crawler))
(define SC2-CHANGELING-UNIT-SYMS
  '(changeling changeling-zealot changeling-marine-shield
    changeling-marine changeling-zergling-wings changeling-zergling))
(define SC2-CLOAKED-OR-BURROW-STEALTH-SYMS
  '(banshee dark-templar ghost mothership lurker lurker-mp lurker-burrowed
    lurker-mp-burrowed roach-burrowed infestor infestor-burrowed
    widow-mine widow-mine-burrowed swarm-host-burrowed observer))

;; Burrowed Roach (`TunnelingClaws`) & Burrowed Infestor movement/cast/escape micro:
(define SC2-ROACH-BURROW-HP-PCT-THRESH            0.38)
(define SC2-ROACH-UNBURROW-HP-PCT-THRESH          0.82)
(define SC2-ROACH-TUNNEL-FLANK-RANGE              5.5)
(define SC2-INFESTOR-BURROW-APPROACH-RANGE        13.0)
(define SC2-INFESTOR-FUNGAL-CAST-RANGE            10.0)
(define SC2-INFESTOR-NEURAL-CAST-RANGE            9.0)
(define SC2-INFESTOR-FUNGAL-ENERGY                75)
(define SC2-INFESTOR-NEURAL-ENERGY                100)

;; Subtle burrowed-movement ripple & cloaked shimmer detection (`display_type = Hidden (2)`):
(define SC2-SHIMMER-DISPLAY-TYPE-HIDDEN           2)
(define SC2-BURROW-RIPPLE-MIN-SPEED               0.15)
(define SC2-BLIND-AOE-SKILLSHOT-SPELLS
  '(corrosive-bile psi-storm fungal-growth purification-nova emp-round scanner-sweep oracle-revelation))

;; Pro Upgrade Timings, Gas-Float Harvester Rebalancing, Terran Add-On Swapping
;; & Proactive Pre-Depletion Expansion (`benchmarks/full_corpus_upgrades_and_addon_swaps_report.json`):
;;   - 69.2% win rate for upgrade lead at 8:00 (93.2% on AI Arena ladder)
;;   - 480 pro Terran add-on swaps (median first swap 198.6s = 4,448 frames)
;;   - Proactive pre-depletion expansion 90s (~2,016 frames / < 2,400M remaining) before base mines out
(define SC2-GAS-FLOAT-REBALANCE-THRESH            350)
(define SC2-GAS-FLOAT-CRITICAL-THRESH             550)
(define SC2-MINERAL-STARVED-REBALANCE-THRESH      180)
(define SC2-TERRAN-FIRST-ADDON-SWAP-FRAME         4448)   ;; 198.6s median pro first add-on swap
(define SC2-PRE-DEPLETION-PROACTIVE-MINERAL-THRESH 2400)  ;; ~90s of full 16-worker mining remaining
(define SC2-BASE-STARTING-MINERAL-LEDGER          10800)  ;; 4x1800 + 4x900 standard LotV base minerals

;; -----------------------------------------------------------------------------
;; 10. Canonical Structure, Unit & Footprint Equivalence Helpers
;; -----------------------------------------------------------------------------
;; Single source of truth for SC2 structure/unit state transitions, flying/lowered/
;; uprooted/rich/overcharged variants, morphed tech structures, and spelling aliases.

(define (sc2-canonical-structure-sym sym)
  (case sym
    [(warpgate)                    'warp-gate]
    [(robotics-support-bay)        'robotics-bay]
    [(templar-archives)            'templar-archive]
    [(lurker-den-mp)               'lurker-den]
    [(barracks-tech-lab)           'barracks-techlab]
    [(factory-tech-lab)            'factory-techlab]
    [(starport-tech-lab)           'starport-techlab]
    [(techlab)                     'tech-lab]
    [(pylon-overcharged)           'pylon]
    [(supply-depot-lowered)        'supply-depot]
    [(extractor-rich)              'extractor]
    [(refinery-rich)               'refinery]
    [(assimilator-rich)            'assimilator]
    [(spine-crawler-uprooted)      'spine-crawler]
    [(spore-crawler-uprooted)      'spore-crawler]
    [(barracks-flying)             'barracks]
    [(factory-flying)              'factory]
    [(starport-flying)             'starport]
    [(command-center-flying)       'command-center]
    [(orbital-command-flying)      'orbital-command]
    [else                          sym]))

(define SC2-PROTOSS-PYLON-POWERED-STRUCTURE-SYMS
  '(gateway warp-gate warpgate cybernetics-core forge photon-cannon shield-battery
    twilight-council robotics-facility robotics-bay robotics-support-bay
    stargate fleet-beacon templar-archive templar-archives dark-shrine))

(define (sc2-structure-requires-pylon-power? sym)
  (not (not (memq (sc2-canonical-structure-sym sym)
                  SC2-PROTOSS-PYLON-POWERED-STRUCTURE-SYMS))))

(define (sc2-structure-equivalent-syms sym [include-free-addons? #f])
  (case sym
    [(hatchery)
     '(hatchery lair hive)]
    [(lair)
     '(lair hive)]
    [(hive)
     '(hive)]
    [(spire)
     '(spire greater-spire)]
    [(greater-spire)
     '(greater-spire)]
    [(lurker-den lurker-den-mp)
     '(lurker-den lurker-den-mp)]
    [(extractor extractor-rich)
     '(extractor extractor-rich)]
    [(spine-crawler spine-crawler-uprooted)
     '(spine-crawler spine-crawler-uprooted)]
    [(spore-crawler spore-crawler-uprooted)
     '(spore-crawler spore-crawler-uprooted)]
    [(nydus-worm nydus-canal)
     '(nydus-worm nydus-canal)]
    [(gateway)
     '(gateway warp-gate warpgate)]
    [(warp-gate warpgate)
     '(warp-gate warpgate)]
    [(pylon pylon-overcharged)
     '(pylon pylon-overcharged)]
    [(assimilator assimilator-rich)
     '(assimilator assimilator-rich)]
    [(robotics-bay robotics-support-bay)
     '(robotics-bay robotics-support-bay)]
    [(templar-archive templar-archives)
     '(templar-archive templar-archives)]
    [(command-center command-center-flying)
     '(command-center command-center-flying orbital-command orbital-command-flying planetary-fortress)]
    [(orbital-command orbital-command-flying)
     '(orbital-command orbital-command-flying)]
    [(supply-depot supply-depot-lowered)
     '(supply-depot supply-depot-lowered)]
    [(refinery refinery-rich)
     '(refinery refinery-rich)]
    [(barracks barracks-flying)
     '(barracks barracks-flying)]
    [(factory factory-flying)
     '(factory factory-flying)]
    [(starport starport-flying)
     '(starport starport-flying)]
    [(barracks-techlab barracks-tech-lab)
     (if include-free-addons?
         '(barracks-techlab barracks-tech-lab tech-lab techlab)
         '(barracks-techlab barracks-tech-lab))]
    [(factory-techlab factory-tech-lab)
     (if include-free-addons?
         '(factory-techlab factory-tech-lab tech-lab techlab)
         '(factory-techlab factory-tech-lab))]
    [(starport-techlab starport-tech-lab)
     (if include-free-addons?
         '(starport-techlab starport-tech-lab tech-lab techlab)
         '(starport-techlab starport-tech-lab))]
    [(barracks-reactor)
     (if include-free-addons?
         '(barracks-reactor reactor)
         '(barracks-reactor))]
    [(factory-reactor)
     (if include-free-addons?
         '(factory-reactor reactor)
         '(factory-reactor))]
    [(starport-reactor)
     (if include-free-addons?
         '(starport-reactor reactor)
         '(starport-reactor))]
    [(tech-lab techlab)
     '(tech-lab techlab)]
    [else
     (list sym)]))

(define (sc2-structure-matches-target? actual-sym target-sym [include-free-addons? #f])
  (and (memq actual-sym (sc2-structure-equivalent-syms target-sym include-free-addons?)) #t))

(define (sc2-count-equivalent-structures counts-hash sym [include-free-addons? #f])
  (for/sum ([s (in-list (remove-duplicates (sc2-structure-equivalent-syms sym include-free-addons?) eq?))])
    (hash-ref counts-hash s 0)))

(define (sc2-canonical-unit-sym sym)
  (case sym
    [(viking-fighter viking-assault)   'viking]
    [(siege-tank-sieged)               'siege-tank]
    [(widow-mine-burrowed)             'widow-mine]
    [(thor-ap)                         'thor]
    [(liberator-ag)                    'liberator]
    [(lurker-mp lurker-burrowed lurker-mp-burrowed lurker-egg lurker-mp-egg) 'lurker]
    [(baneling-burrowed baneling-cocoon) 'baneling]
    [(ravager-cocoon ravager-burrowed) 'ravager]
    [(broodlord brood-lord-cocoon)     'brood-lord]
    [(overlord-cocoon overseer-siege-mode) 'overseer]
    [(overlord-transport transport-overlord-cocoon) 'overlord]
    [(roach-burrowed)                  'roach]
    [(zergling-burrowed)               'zergling]
    [(hydralisk-burrowed)              'hydralisk]
    [(infestor-burrowed)               'infestor]
    [(swarm-host-burrowed swarmhost)   'swarm-host]
    [(ultralisk-burrowed)              'ultralisk]
    [(queen-burrowed)                  'queen]
    [(drone-burrowed)                  'drone]
    [(observer-siege-mode)             'observer]
    [(warp-prism-phasing)              'warp-prism]
    [(voidray)                         'void-ray]
    [else                              sym]))

(define (sc2-unit-equivalent-syms sym)
  (case sym
    [(viking viking-fighter viking-assault)
     '(viking viking-fighter viking-assault)]
    [(siege-tank siege-tank-sieged)
     '(siege-tank siege-tank-sieged)]
    [(widow-mine widow-mine-burrowed)
     '(widow-mine widow-mine-burrowed)]
    [(thor thor-ap)
     '(thor thor-ap)]
    [(liberator liberator-ag)
     '(liberator liberator-ag)]
    [(hellion hellbat)
     (list sym)]
    [(lurker lurker-mp lurker-burrowed lurker-mp-burrowed lurker-egg lurker-mp-egg)
     '(lurker lurker-mp lurker-burrowed lurker-mp-burrowed lurker-egg lurker-mp-egg)]
    [(roach roach-burrowed)
     '(roach roach-burrowed)]
    [(zergling zergling-burrowed)
     '(zergling zergling-burrowed)]
    [(baneling baneling-burrowed baneling-cocoon)
     '(baneling baneling-burrowed baneling-cocoon)]
    [(ravager ravager-burrowed ravager-cocoon)
     '(ravager ravager-burrowed ravager-cocoon)]
    [(hydralisk hydralisk-burrowed)
     '(hydralisk hydralisk-burrowed)]
    [(infestor infestor-burrowed)
     '(infestor infestor-burrowed)]
    [(swarm-host swarm-host-burrowed swarmhost)
     '(swarm-host swarm-host-burrowed swarmhost)]
    [(ultralisk ultralisk-burrowed)
     '(ultralisk ultralisk-burrowed)]
    [(queen queen-burrowed)
     '(queen queen-burrowed)]
    [(drone drone-burrowed)
     '(drone drone-burrowed)]
    [(brood-lord broodlord brood-lord-cocoon)
     '(brood-lord broodlord brood-lord-cocoon)]
    [(overlord overlord-transport transport-overlord-cocoon)
     '(overlord overlord-transport transport-overlord-cocoon)]
    [(overseer overseer-siege-mode overlord-cocoon)
     '(overseer overseer-siege-mode overlord-cocoon)]
    [(observer observer-siege-mode)
     '(observer observer-siege-mode)]
    [(warp-prism warp-prism-phasing)
     '(warp-prism warp-prism-phasing)]
    [(void-ray voidray)
     '(void-ray voidray)]
    [else
     (list sym)]))

;; True for 3x3 and 5x5 SC2 structures whose footprint centers snap to (x.5, y.5)
;; rather than 2x2 integer centers (x.0, y.0).
(define SC2-2X2-STRUCTURE-SYMS
  '(supply-depot supply-depot-lowered missile-turret sensor-tower
    pylon pylon-overcharged photon-cannon shield-battery dark-shrine oracle-stasis-trap
    spire greater-spire spine-crawler spine-crawler-uprooted
    spore-crawler spore-crawler-uprooted
    barracks-techlab barracks-tech-lab barracks-reactor
    factory-techlab factory-tech-lab factory-reactor
    starport-techlab starport-tech-lab starport-reactor
    tech-lab techlab reactor))

(define SC2-TOWNHALL-STRUCTURE-SYMS
  '(hatchery lair hive
    nexus
    command-center command-center-flying
    orbital-command orbital-command-flying
    planetary-fortress))

(define (sc2-odd-footprint-structure? sym)
  (and (memq sym SC2-ALL-STRUCTURE-SYMS)
       (not (memq sym SC2-2X2-STRUCTURE-SYMS))
       #t))

;; -----------------------------------------------------------------------------
;; 11. Generalized Cross-Cutting Ontology, Order Protection, Role-Lease Registry,
;;     Bistable Hysteresis, Chebyshev AABB Footprints & Macro Energy Dispatcher
;; -----------------------------------------------------------------------------

;; Canonical mapping from generic/smart vs race-specific Unit.orders ability IDs.
(define (sc2-canonical-order-ability ab-id)
  (case ab-id
    [(166 295 298 1183 3666) 'harvest-gather]
    [(167 296 299 1184 3667) 'harvest-return]
    [(168 316 3685)          'repair]
    [(16 19 20 3794)         'move]
    [(17 3795)               'patrol]
    [(18 3793)               'hold-position]
    [(4 5 6 7 3665)          'stop]
    [(23 24 25 2099 3674 3771) 'attack]
    [(417 452 485 518 1522 3679) 'lift]
    [(419 520 522 554 1524 3678) 'land]
    [(421 454 487 3682)      'build-techlab]
    [(422 455 488 3683)      'build-reactor]
    [(1374 1378 1382 1386 1390 1433 1444 1512 2014 2095 2108 2340 3661) 'burrow-down]
    [(1376 1380 1384 1388 1392 1435 1446 1514 2016 2097 2110 2342 3662) 'burrow-up]
    [(1394 1396 3680)        'uproot]
    [(1398 1400 3681)        'root]
    [(1662 1694 1733 3691)   'spawn-creep-tumor]
    [(253 380 3675)          'stim]
    [(1442 3687)             'blink]
    [(142 3686 3757)         'mass-recall]
    [(1163 2112)             'build-lurker-den]
    [(895 1909)              'build-shield-battery]
    [else                    ab-id]))

;; Protected Unit.orders classes that must not be overwritten by generic army/idle commands:
;;   'morph       — unit/structure morphs (Baneling/Ravager/BroodLord/Overseer/Archon/Lair/Hive/Lurker/etc.)
;;   'channel     — channeled abilities (Yamato/TacticalJump/Snipe/Neural/Graviton/Consume/Recall/etc.)
;;   'mode-switch — siege/unsiege, burrow/unburrow, lift/land, uproot/root, fighter/assault, depot raise/lower
;;   'cast-walk   — walk-to-cast spells (Inject, CreepTumor, Transfusion, EMP, Storm, Feedback, Fungal, Bile, etc.)
(define SC2-PROTECTED-ORDER-CLASS-TABLE
  (let ([ht (make-hasheqv)])
    (for ([id (in-list '(80 2330 2332 1372 1448 2708 1766 1216 1218 1220 1516 1450 1518))])
      (hash-set! ht id 'morph))
    (for ([id (in-list '(401 2358 2714 249 173 2073 2069 2324 258 3757 142 3686))])
      (hash-set! ht id 'channel))
    (for ([id (in-list '(388 390 2558 2560 403 405 1978 1998 2362 2364
                         3739 3741 3743 3745 1528 1530 556 558
                         1374 1378 1382 1386 1390 1433 1444 1512 2014 2095 2108 2340 3661
                         1376 1380 1384 1388 1392 1435 1446 1514 2016 2097 2110 2342 3662
                         417 452 485 518 1522 3679
                         419 520 522 554 1524 3678
                         1394 1396 3680
                         1398 1400 3681))])
      (hash-set! ht id 'mode-switch))
    (for ([id (in-list '(251 1662 1694 3691 1733 1664 1628 1036 140 74 3763
                         2338 2346 2067 2063 2542 2545 3747 3753 181 2505 1526))])
      (hash-set! ht id 'cast-walk))
    (for/hasheqv ([(k v) (in-hash ht)])
      (values k v))))

(define (sc2-order-protection-class ab-id)
  (or (hash-ref SC2-PROTECTED-ORDER-CLASS-TABLE ab-id #f)
      (case (sc2-canonical-order-ability ab-id)
        [(burrow-down burrow-up lift land uproot root) 'mode-switch]
        [(spawn-creep-tumor) 'cast-walk]
        [(mass-recall) 'channel]
        [else #f])))

;; Non-combat morphing cocoons/eggs, temporary summons, wards, scouts, and auxiliary transports.
(define SC2-COCOON-AND-EGG-SYMS
  '(larva
    egg
    cocoon
    baneling-cocoon
    ravager-cocoon
    brood-lord-cocoon
    overlord-cocoon
    transport-overlord-cocoon
    lurker-egg
    lurker-mp-egg))

(define SC2-NON-ARMY-SUMMON-AND-AUX-SYMS
  (append
   SC2-COCOON-AND-EGG-SYMS
   '(mule
     interceptor
     adept-phase-shift
     disruptor-phased
     auto-turret
     point-defense-drone
     raven-repair-drone
     kd8-charge
     parasitic-bomb-dummy
     changeling
     changeling-zealot
     changeling-marine-shield
     changeling-marine
     changeling-zergling-wings
     changeling-zergling
     creep-tumor
     creep-tumor-burrowed
     creep-tumor-queen
     oracle-stasis-trap
     stasis-ward
     force-field
     overlord
     overlord-transport
     overseer
     overseer-siege-mode
     observer
     observer-siege-mode
     warp-prism
     warp-prism-phasing
     broodling-escort)))

(define SC2-NON-ARMY-SUMMON-AND-AUX-SET
  (list->seteq SC2-NON-ARMY-SUMMON-AND-AUX-SYMS))

(define (sc2-non-combat-or-summon-sym? sym)
  (and (symbol? sym)
       (or (set-member? SC2-NON-ARMY-SUMMON-AND-AUX-SET sym)
           (let ([s (symbol->string sym)])
             (or (regexp-match? #rx"^changeling" s)
                 (regexp-match? #rx"^creep-tumor" s)
                 (regexp-match? #rx"-cocoon$" s)
                 (regexp-match? #rx"-egg$" s))))
       #t))

;; Unit Role-Lease Registry
(struct unit-role-lease (role priority target-id target-x target-y expires-frame) #:transparent)

(define (role-lease-priority role)
  (case role
    [(builder)         100]
    [(inject-queen)     95]
    [(door-guard)       90]
    [(mule)             90]
    [(evac)             85]
    [(cargo-returner)   80]
    [(detector-escort)  75]
    [(scout)            70]
    [(spotter)          68]
    [(creep-queen)      65]
    [(army)             20]
    [(harvester)        10]
    [else                0]))

(define (acquire-unit-lease! lease-ht uid role frame ttl #:target-id [tid 0] #:x [tx 0.0] #:y [ty 0.0])
  (cond
    [(and (hash? lease-ht) (not (immutable? lease-ht)) (integer? uid) (> uid 0))
     (define new-prio (role-lease-priority role))
     (define existing (hash-ref lease-ht uid #f))
     (cond
       [(or (not (unit-role-lease? existing))
            (<= (unit-role-lease-expires-frame existing) frame)
            (>= new-prio (unit-role-lease-priority existing)))
        (define lease
          (unit-role-lease role
                           new-prio
                           tid
                           (exact->inexact tx)
                           (exact->inexact ty)
                           (+ frame (max 1 ttl))))
        (hash-set! lease-ht uid lease)
        #t]
       [else #f])]
    [else #f]))

(define (unit-leased-above? lease-ht uid caller-role frame)
  (and (hash? lease-ht)
       uid
       (let ([existing (hash-ref lease-ht uid #f)])
         (and (unit-role-lease? existing)
              (> (unit-role-lease-expires-frame existing) frame)
              (> (unit-role-lease-priority existing) (role-lease-priority caller-role))
              #t))))

(define (leased-tags-above lease-ht caller-role frame)
  (cond
    [(hash? lease-ht)
     (define caller-prio (role-lease-priority caller-role))
     (for/fold ([acc (seteqv)])
               ([(uid lease) (in-hash lease-ht)])
       (if (and (unit-role-lease? lease)
                (> (unit-role-lease-expires-frame lease) frame)
                (> (unit-role-lease-priority lease) caller-prio))
           (set-add acc uid)
           acc))]
    [else (seteqv)]))

;; Bistable Hysteresis Controller (Schmitt trigger + minimum dwell + re-entry cooldown)
(struct bistable-state (active? changed-frame cooldown-until-frame) #:transparent)

(define (bistable-hysteresis-step state-ht key frame
                                  #:enter? enter-now?
                                  #:exit? exit-now?
                                  #:min-dwell-loops [min-dwell 44]
                                  #:cooldown-loops [cooldown 22])
  (define raw-prev (and (hash? state-ht) (hash-ref state-ht key #f)))
  (define prev
    (if (and (bistable-state? raw-prev)
             (>= frame (bistable-state-changed-frame raw-prev)))
        raw-prev
        (bistable-state #f -100000 0)))
  (define next
    (cond
      [(bistable-state-active? prev)
       (if (and exit-now?
                (>= (- frame (bistable-state-changed-frame prev)) min-dwell))
           (bistable-state #f frame (+ frame cooldown))
           prev)]
      [else
       (if (and enter-now?
                (>= frame (bistable-state-cooldown-until-frame prev)))
           (bistable-state #t frame (bistable-state-cooldown-until-frame prev))
           prev)]))
  (when (and (hash? state-ht) (not (immutable? state-ht)))
    (hash-set! state-ht key next))
  (bistable-state-active? next))

;; Chebyshev / Axis-Aligned Bounding Box Reserved Spatial Footprint
(struct reserved-aabb (cx cy half-w half-h kind owner-tag expires-frame) #:transparent)

(define (aabb-overlaps? cx1 cy1 hw1 hh1 b)
  (and (reserved-aabb? b)
       (< (abs (- (exact->inexact cx1) (exact->inexact (reserved-aabb-cx b))))
          (- (+ (exact->inexact hw1) (exact->inexact (reserved-aabb-half-w b))) 1e-6))
       (< (abs (- (exact->inexact cy1) (exact->inexact (reserved-aabb-cy b))))
          (- (+ (exact->inexact hh1) (exact->inexact (reserved-aabb-half-h b))) 1e-6))
       #t))

(define (sc2-structure-half-dims bldg-sym)
  (define canon (sc2-canonical-structure-sym bldg-sym))
  (cond
    [(or (memq bldg-sym SC2-TOWNHALL-STRUCTURE-SYMS)
         (memq canon SC2-TOWNHALL-STRUCTURE-SYMS))
     (values 2.5 2.5)]
    [(or (memq bldg-sym SC2-2X2-STRUCTURE-SYMS)
         (memq canon SC2-2X2-STRUCTURE-SYMS))
     (values 1.0 1.0)]
    [else
     (values 1.5 1.5)]))

;; Generalized 1-to-1 Macro Energy Dispatcher
(define (dispatch-macro-energy! casters
                                candidates
                                frame
                                claimed-targets-set
                                #:min-energy min-energy
                                #:valid-caster? [valid-caster? (lambda (_c) #t)]
                                #:valid-pair? valid-pair?
                                #:score-pair score-pair
                                #:emit-cast! emit-cast!)
  (define local-claimed-casters (mutable-set))
  (define local-claimed-targets (mutable-set))
  (define (entity-key x)
    (cond
      [(hash? x) (or (hash-ref x 'id #f) (hash-ref x 'tag #f) x)]
      [else x]))
  (define (target-claimed? tkey raw-cand)
    (or (set-member? local-claimed-targets tkey)
        (cond
          [(and (set-mutable? claimed-targets-set))
           (or (set-member? claimed-targets-set tkey)
               (set-member? claimed-targets-set raw-cand))]
          [(set? claimed-targets-set)
           (or (set-member? claimed-targets-set tkey)
               (set-member? claimed-targets-set raw-cand))]
          [(hash? claimed-targets-set)
           (or (hash-has-key? claimed-targets-set tkey)
               (hash-has-key? claimed-targets-set raw-cand))]
          [else #f])))
  (define (claim-target! tkey)
    (set-add! local-claimed-targets tkey)
    (cond
      [(set-mutable? claimed-targets-set)
       (set-add! claimed-targets-set tkey)]
      [(and (hash? claimed-targets-set) (not (immutable? claimed-targets-set)))
       (hash-set! claimed-targets-set tkey frame)]
      [else (void)]))
  (define eligible-casters
    (for/list ([c (in-list casters)]
               #:when (and (or (not (hash? c))
                               (>= (hash-ref c 'energy 0.0) min-energy))
                           (if (procedure-arity-includes? valid-caster? 2)
                               (valid-caster? c frame)
                               (valid-caster? c))))
      c))
  (define scored-pairs
    (for*/fold ([acc '()])
               ([c (in-list eligible-casters)]
                [cand (in-list candidates)])
      (define tkey (entity-key cand))
      (if (and (not (target-claimed? tkey cand))
               (if (procedure-arity-includes? valid-pair? 3)
                   (valid-pair? c cand frame)
                   (valid-pair? c cand)))
          (let ([sc (if (procedure-arity-includes? score-pair 3)
                        (score-pair c cand frame)
                        (score-pair c cand))])
            (if (and (real? sc) (not (nan? sc)))
                (cons (vector (exact->inexact sc) c cand (entity-key c) tkey) acc)
                acc))
          acc)))
  (define sorted-pairs
    (sort scored-pairs > #:key (lambda (v) (vector-ref v 0))))
  (define emitted '())
  (for ([v (in-list sorted-pairs)])
    (define c (vector-ref v 1))
    (define cand (vector-ref v 2))
    (define ckey (vector-ref v 3))
    (define tkey (vector-ref v 4))
    (unless (or (set-member? local-claimed-casters ckey)
                (target-claimed? tkey cand))
      (set-add! local-claimed-casters ckey)
      (claim-target! tkey)
      (define res
        (if (procedure-arity-includes? emit-cast! 3)
            (emit-cast! c cand frame)
            (emit-cast! c cand)))
      (when (and res (not (void? res)))
        (set! emitted (cons res emitted)))))
  (reverse emitted))

;; Midgame Economy-to-Army Curve (prevents pure-drone / pure-probe greed deaths vs pushes)
(define (required-army-supply-for-worker-growth total-workers [enemy-threat-supply 0.0])
  (max (* 0.85 (exact->inexact enemy-threat-supply))
       (cond
         [(< total-workers 26) 0.0]
         [(< total-workers 34) 4.0]
         [(< total-workers 40) 8.0]
         [(< total-workers 46) 12.0]
         [(< total-workers 54) 18.0]
         [(< total-workers 64) 32.0]
         [else 48.0])))

