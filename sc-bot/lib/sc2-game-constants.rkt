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

(require racket/match
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
(define SC2-MAX-QUEENS-CAP                 4)

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

   ;; Key Upgrades
   'metabolic-boost         '(100 100 0)
   'zergling-movementspeed  '(100 100 0)
   'adrenal-glands          '(200 200 0)
   'glial-reconstitution    '(100 100 0)
   'centrifugal-hooks       '(150 150 0)
   'grooved-spines          '(100 100 0)
   'muscular-augments       '(100 100 0)
   'adaptive-talons         '(150 150 0)
   'lurker-range            '(150 150 0)
   'zerg-missile-weapons-1  '(100 100 0)
   'stimpack                '(100 100 0)
   'combat-shield           '(100 100 0)
   'concussive-shells       '(50 50 0)
   'drilling-claws          '(75 75 0)
   'personal-cloaking       '(150 150 0)
   'terran-infantry-weapons-1 '(100 100 0)
   'warpgate                '(50 50 0)
   'warp-gate-research      '(100 100 0)
   'charge                  '(100 100 0)
   'blink                   '(150 150 0)
   'extended-thermal-lance  '(150 150 0)
   'protoss-ground-weapons-1 '(100 100 0)))

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
(define SC2-NO-TARGET-ABILITY-IDS
  (list->seteqv
   '(181   ;; SPAWNCHANGELING_SPAWNCHANGELING
     253   ;; EFFECT_STIM_MARAUDER
     380   ;; EFFECT_STIM_MARINE
     388   ;; SIEGEMODE_SIEGEMODE
     390   ;; UNSIEGE_UNSIEGE
     392   ;; BEHAVIOR_CLOAKON_BANSHEE
     393   ;; BEHAVIOR_CLOAKOFF_BANSHEE
     76    ;; GUARDIANSHIELD_GUARDIANSHIELD
     154   ;; HALLUCINATION_PHOENIX
     146   ;; HALLUCINATION_ARCHON
     2116  ;; EFFECT_MEDIVACIGNITEAFTERBURNERS
     2328  ;; EFFECT_IMMORTALBARRIER
     2375  ;; BEHAVIOR_PULSARBEAMON
     2376  ;; BEHAVIOR_PULSARBEAMOFF
     2393  ;; EFFECT_VOIDRAYPRISMATICALIGNMENT
     3661  ;; BURROWDOWN
     3662  ;; BURROWUP
     3675  ;; EFFECT_STIM
     3741  ;; MORPH_OBSERVERSIEGEMODE
     1528  ;; MORPH_WARPPRISMPHASINGMODE
     1530  ;; MORPH_WARPPRISMTRANSPORTMODE
     )))

(define SC2-POINT-TARGET-ABILITY-IDS
  (list->seteqv
   '(74    ;; FUNGALGROWTH_FUNGALGROWTH
     399   ;; SCAN_MOVE (Scanner Sweep)
     1036  ;; PSISTORM_PSISTORM
     1442  ;; EFFECT_BLINK_STALKER
     1526  ;; FORCEFIELD_FORCEFIELD
     1628  ;; EMP_EMP
     1694  ;; BUILD_CREEPTUMOR_QUEEN
     1733  ;; BUILD_CREEPTUMOR_TUMOR
     2063  ;; BLINDINGCLOUD_BLINDINGCLOUD
     2146  ;; ORACLEREVELATION_ORACLEREVELATION
     2338  ;; EFFECT_CORROSIVEBILE
     2346  ;; EFFECT_PURIFICATIONNOVA
     2358  ;; EFFECT_TACTICALJUMP
     2505  ;; BUILD_STASISTRAP
     2544  ;; EFFECT_ADEPTPHASESHIFT
     2588  ;; KD8CHARGE_KD8CHARGE
     3687  ;; EFFECT_BLINK
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
