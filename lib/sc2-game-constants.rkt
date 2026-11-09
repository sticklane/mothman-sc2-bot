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
   'protoss-air-armor-1      '(150 150 0)))

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
     2095  ;; BURROWDOWN_WIDOWMINE
     2097  ;; BURROWUP_WIDOWMINE
     2108  ;; BURROWDOWN_LURKER
     2110  ;; BURROWUP_LURKER
     2116  ;; EFFECT_MEDIVACIGNITEAFTERBURNERS
     2328  ;; EFFECT_IMMORTALBARRIER
     2375  ;; BEHAVIOR_PULSARBEAMON
     2376  ;; BEHAVIOR_PULSARBEAMOFF
     2393  ;; EFFECT_VOIDRAYPRISMATICALIGNMENT
     556   ;; MORPH_SUPPLYDEPOT_LOWER
     558   ;; MORPH_SUPPLYDEPOT_RAISE
     3661  ;; BURROWDOWN
     3662  ;; BURROWUP
     3675  ;; EFFECT_STIM
     3741  ;; MORPH_OBSERVERSIEGEMODE
      1528  ;; MORPH_WARPPRISMPHASINGMODE
      1530  ;; MORPH_WARPPRISMTRANSPORTMODE
      1042  ;; BUILD_INTERCEPTORS
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
   'widow-mine        (hasheq 'max-hp 90  'max-shield 0   'armor 0 'speed 3.94 'ground-dps 18.0 'air-dps 18.0 'ground-range 5.0  'air-range 5.0  'weapon-period 29.0  'damage-point 1.07 'splash-radius 1.75 'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.5)
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
   'stasis-ward       (hasheq 'max-hp 30  'max-shield 30  'armor 0 'speed 0.0  'ground-dps 0.0  'air-dps 0.0  'ground-range 4.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 4.0  'flying? #f 'detector? #f 'can-cloak? #t 'radius 0.5  'attribute 'Light)))

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
  '(hatchery lair hive extractor spawning-pool roach-warren baneling-nest
    evolution-chamber hydralisk-den lurker-den spire greater-spire
    infestation-pit ultralisk-cavern spine-crawler spore-crawler nydus-network
    nexus pylon assimilator gateway warp-gate warpgate cybernetics-core forge
    photon-cannon shield-battery twilight-council robotics-facility robotics-bay
    robotics-support-bay stargate fleet-beacon templar-archive templar-archives dark-shrine
    command-center orbital-command planetary-fortress supply-depot supply-depot-lowered
    refinery barracks factory starport engineering-bay bunker missile-turret
    sensor-tower ghost-academy armory fusion-core
    barracks-techlab barracks-tech-lab barracks-reactor
    factory-techlab factory-tech-lab factory-reactor
    starport-techlab starport-tech-lab starport-reactor
    tech-lab reactor))

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
