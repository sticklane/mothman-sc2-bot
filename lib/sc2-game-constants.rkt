#lang typed/racket/base

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
         racket/fixnum
         racket/flonum
         racket/string
         typed/racket/unsafe
         (except-in racket/set set-member? set-mutable? set-add!)
         "sc2-types.rkt")

(unsafe-require/typed racket/set
  [set-mutable? (-> Any Boolean)]
  [set-member? (-> Any Any Boolean)]
  [set-add! (-> Any Any Void)])

(module dispatch-dyn racket/base
  (provide call-1-or-2 call-2-or-3 dyn-hash-set!)
  (define (call-1-or-2 p a f)
    (if (procedure-arity-includes? p 2) (p a f) (p a)))
  (define (call-2-or-3 p a b f)
    (if (procedure-arity-includes? p 3) (p a b f) (p a b)))
  (define (dyn-hash-set! h k v)
    (when (and (hash? h) (not (immutable? h)))
      (hash-set! h k v))))

(define-type Cb12 (U (-> Any Any) (-> Any Integer Any)))
(define-type Cb23 (U (-> Any Any Any) (-> Any Any Integer Any)))
(define-type CombatStatTable (Immutable-HashTable Symbol (U Real Boolean Symbol)))

(unsafe-require/typed (submod "." dispatch-dyn)
  [call-1-or-2 (-> Cb12 Any Integer Any)]
  [call-2-or-3 (-> Cb23 Any Any Integer Any)]
  [dyn-hash-set! (-> Any Any Any Void)])

(provide (all-defined-out))

;; -----------------------------------------------------------------------------
;; 1. Core SC2 Engine Timing, Map Coordinate & Supply Constants
;; -----------------------------------------------------------------------------
(define SC2-FASTER-FPS                     22.4)
(define SC2-FRAMES-PER-SECOND-INT          22)
(: SC2-SECONDS->FRAMES (-> Real Integer))
(define SC2-SECONDS->FRAMES
  (lambda (sec) (exact-round (* sec SC2-FASTER-FPS))))

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

;; Continuous production-and-build-coupled supply lead-time buffer:
;; Estimates expected supply consumption during one supply-provider build cycle (~18s)
;; directly from active bases (worker production) and active production structures
;; (combat unit production), scaled smoothly by worker economy saturation without
;; arbitrary supply-cap breakpoints.
(: compute-production-coupled-supply-buffer
   (->* ()
        (#:active-bases Real
         #:production-facilities Real
         #:workers Real
         #:target-workers Real
         #:min-buffer Integer
         #:max-buffer Integer)
        Integer))
(define (compute-production-coupled-supply-buffer
         #:active-bases [raw-bases 1]
         #:production-facilities [raw-facilities 0]
         #:workers [raw-workers 12]
         #:target-workers [raw-target-workers 44]
         #:min-buffer [min-buf 2]
         #:max-buffer [max-buf 18])
  (define bases (max 1 (exact-round raw-bases)))
  (define facilities (max 0 (exact-round raw-facilities)))
  (define workers (max 0 (exact-round raw-workers)))
  (define target-workers (max 12 (exact-round raw-target-workers)))
  (define econ-ramp
    (min 1.0 (max 0.0 (/ (->float (- workers 13)) 15.0))))
  (define worker-sat-factor
    (if (< workers target-workers) 1.0 0.5))
  (define townhall-burn
    (* 2.0 (->float bases) worker-sat-factor (+ 0.25 (* 0.75 econ-ramp))))
  (define effective-combat-facilities
    (max 0 (- facilities (if (= bases 1) 1 0))))
  (define facility-burn
    (* 1.15 (->float (+ (* 0.5 (min 1 facilities)) effective-combat-facilities))
       (+ 0.20 (* 0.80 econ-ramp))))
  (define raw-buf
    (exact-round (+ 0.65 townhall-burn facility-burn)))
  (max min-buf (min max-buf raw-buf)))

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
(define SC2-RESUME-BLDG-RUSH-COOLDOWN-FRAMES 24)  ;; ~1.1s fast resume under worker rush / early crisis
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
(: SC2-LOTV-COST-TABLE (Immutable-HashTable Symbol (List Integer Integer Integer)))
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
   'hatchery                '(275 0 0)
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
   'queen                   '(175 0 2)
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
   'immortal                '(250 100 4)
   'colossus                '(300 200 6)
   'disruptor               '(150 150 3)
   'phoenix                 '(150 100 2)
   'void-ray                '(250 150 4)
   'oracle                  '(150 150 3)
   'carrier                 '(350 250 6)
   'tempest                 '(250 175 4)
   'mothership              '(400 400 8)

   ;; Terran Structures
   'barracks                '(150 0 0)
   'factory                 '(150 100 0)
   'starport                '(150 100 0)
   'engineering-bay         '(125 0 0)
   'armory                  '(150 100 0)
   'missile-turret          '(100 0 0)
   'bunker                  '(100 0 0)
   'sensor-tower            '(100 50 0)
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
   'queen-burrowed           '(175 0 2)
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

(: sc2-lookup-cost-triple (-> Any (Option (List Integer Integer Integer))))
(define (sc2-lookup-cost-triple sym)
  (and (symbol? sym)
       (or (and (unbox SC2-LIVE-DATA-ACTIVE?)
                (let ([canon (canonical-unit-type-sym sym)])
                  (or (hash-ref SC2-LIVE-COST-OVERLAY sym (lambda () #f))
                      (and (not (eq? canon sym))
                           (hash-ref SC2-LIVE-COST-OVERLAY canon (lambda () #f)))
                      (let ([upg (hash-ref SC2-LIVE-UPG-COST-OVERLAY sym (lambda () #f))])
                        (and upg (list (first upg) (second upg) 0))))))
           (hash-ref SC2-LOTV-COST-TABLE sym (lambda () #f)))))

(: sc2-min-cost (->* (Any) (Integer) Integer))
(define (sc2-min-cost sym [default 50])
  (match (sc2-lookup-cost-triple sym)
    [(list m _ _) m]
    [_ default]))

(: sc2-gas-cost (->* (Any) (Integer) Integer))
(define (sc2-gas-cost sym [default 0])
  (match (sc2-lookup-cost-triple sym)
    [(list _ g _) g]
    [_ default]))

(: sc2-supply-cost (->* (Any) (Integer) Integer))
(define (sc2-supply-cost sym [default 1])
  (match (sc2-lookup-cost-triple sym)
    [(list _ _ s) s]
    [_ default]))

(: sc2-can-afford? (->* (Any Real Real) (Real) Boolean))
(define (sc2-can-afford? sym minerals gas [supply-left 200])
  (match (sc2-lookup-cost-triple sym)
    [(list m g s)
     (and (>= minerals m)
          (>= gas g)
          (or (<= s 0) (>= supply-left s)))]
    [_ #f]))

(: sc2-race-townhall-min-cost (-> Any Integer))
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
;;   - `microbial-shroud` = `4111` (`EFFECT_AMORPHOUSARMORCLOUD`, PointTarget; SC2 5.0.14)
;;   - `guardian-shield` = `76` (`GUARDIANSHIELD_GUARDIANSHIELD`, NoTarget)
(: SC2-SPELL-ABILITY-IDS (Immutable-HashTable Symbol Integer))
(define SC2-SPELL-ABILITY-IDS
  (hasheq
   'emp-round            1628
   'oracle-revelation    2146
   'microbial-shroud     4111
   'amorphous-armorcloud 4111
   'hydralisk-frenzy     4109
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
   'auto-turret          1764
   'build-auto-turret    1764
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
   'spawn-changeling     181
   'caustic-spray        2324
   'cloak-ghost          382
   'decloak-ghost        383
   'hallucination-phoenix 154
   'hallucination-archon 146
   'pulsar-beam-on       2375
   'pulsar-beam-off      2376
   'lock-on              2350
   ;; Wave 1 / 1.5 / 1C / 1D / 1E / 2A Canonical Spells & Tactical Abilities
   'spawn-locusts        2704
   'spawn-locusts-legacy 2704
   'locust-swoop         2387
   'cancel-adept-shade   2596
   'overlord-generate-creep 1692
   'generate-creep       1692
   'time-warp            2244
   'nexus-mass-recall    3757
   'mothership-mass-recall 142
   'energy-recharge      4126
   'nexus-energy-recharge 4126
   'shield-battery-recharge 4113
   'shield-battery-restore 4113
   'shield-battery-restore-legacy 3751
   'bunker-load          407
   'bunker-unload        408
   'nydus-load           1437
   'nydus-unload         1438
   'nydus-worm-load      2370
   'nydus-worm-unload    2371
   'effect-repair        316
   'repair               3685
   'spine-crawler-uproot 1725
   'spine-crawler-root   1729
   'spore-crawler-uproot 1727
   'spore-crawler-root   1731
   'uproot               3681
   'root                 3680
   'baneling-explode     42
   'widow-mine-attack    2099
   'widow-mine-retarget  2099
   'cancel-adept-phase-shift 2594
   'cancel-phase-shift   2594
   'cancel-build         314
   'cancel-building      314
   'burrow-down          3661
   'burrow-up            3662
   'hold-position        18
   'shadow-stride        2700
   'siege-mode           388
   'unsiege              390
   'unsiege-mode         390
   'morph-oversight-mode 3743
   'morph-overseer-mode  3745
   'morph-observer-mode  3739
   'morph-observer-siege-mode 3741
   'morph-supply-depot-lower 556
   'morph-supply-depot-raise 558
   'morph-warp-prism-phasing 1528
   'morph-warp-prism-transport 1530))

(: SC2-NO-TARGET-ABILITY-IDS (Setof Integer))
(define SC2-NO-TARGET-ABILITY-IDS
  (list->seteqv
   '(18    ;; HOLDPOSITION
     32    ;; EFFECT_SALVAGE
     42    ;; EXPLODE_EXPLODE (Baneling Explode)
     181   ;; SPAWNCHANGELING_SPAWNCHANGELING
     253   ;; EFFECT_STIM_MARAUDER
     314   ;; CANCEL_BUILDINPROGRESS
     380   ;; EFFECT_STIM_MARINE
     382   ;; BEHAVIOR_CLOAKON_GHOST
     383   ;; BEHAVIOR_CLOAKOFF_GHOST
     388   ;; SIEGEMODE_SIEGEMODE
     390   ;; UNSIEGE_UNSIEGE
     392   ;; BEHAVIOR_CLOAKON_BANSHEE
     393   ;; BEHAVIOR_CLOAKOFF_BANSHEE
     403   ;; MORPH_VIKINGASSAULTMODE
     405   ;; MORPH_VIKINGFIGHTERMODE
     408   ;; UNLOADALL_BUNKER
     76    ;; GUARDIANSHIELD_GUARDIANSHIELD
     154   ;; HALLUCINATION_PHOENIX
     146   ;; HALLUCINATION_ARCHON
     1372  ;; MORPH_BROODLORD
     1438  ;; UNLOADALL_NYDUSNETWORK
     1448  ;; MORPH_OVERSEER
     1518  ;; MORPH_WARPGATE
     1520  ;; MORPH_GATEWAY
     1725  ;; SPINECRAWLERUPROOT_SPINECRAWLERUPROOT
     1727  ;; SPORECRAWLERUPROOT_SPORECRAWLERUPROOT
     1766  ;; MORPH_ARCHON
     1692  ;; BEHAVIOR_GENERATECREEPON (SC2 4.10 Overlord Generate Creep)
     1882  ;; BEHAVIOR_GENERATECREEPON (legacy Overlord Generate Creep alias)
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
     2371  ;; UNLOADALL_NYDUSWORM
     2375  ;; BEHAVIOR_PULSARBEAMON
     2376  ;; BEHAVIOR_PULSARBEAMOFF
     2393  ;; EFFECT_VOIDRAYPRISMATICALIGNMENT
     2546  ;; CANCEL_ADEPTPHASESHIFT (raw replay variant)
     2560  ;; MORPH_LIBERATORAAMODE
     2594  ;; CANCEL_ADEPTPHASESHIFT
     2596  ;; CANCEL_ADEPTSHADEPHASESHIFT (SC2 4.10)
     2708  ;; MORPH_OVERLORDTRANSPORT
     556   ;; MORPH_SUPPLYDEPOT_LOWER
     558   ;; MORPH_SUPPLYDEPOT_RAISE
     3659  ;; CANCEL
     3661  ;; BURROWDOWN
     3662  ;; BURROWUP
     3671  ;; CANCEL_LAST
     3675  ;; EFFECT_STIM
     3679  ;; LIFT
     3681  ;; UPROOT
     3739  ;; MORPH_OBSERVERMODE
     3741  ;; MORPH_OBSERVERSIEGEMODE
     3743  ;; MORPH_OVERSIGHTMODE
     3745  ;; MORPH_OVERSEERMODE
     4109  ;; HYDRALISKFRENZY_0 (SC2 5.0.14 Hydralisk Lunge)
     1528  ;; MORPH_WARPPRISMPHASINGMODE
     1530  ;; MORPH_WARPPRISMTRANSPORTMODE
     1042  ;; BUILD_INTERCEPTORS
     )))

(: SC2-POINT-TARGET-ABILITY-IDS (Setof Integer))
(define SC2-POINT-TARGET-ABILITY-IDS
  (list->seteqv
   '(74    ;; FUNGALGROWTH_FUNGALGROWTH
     142   ;; EFFECT_MASSRECALL_STRATEGICRECALL (Mothership Mass Recall, SC2 5.0.14)
     349   ;; BUILD_AUTOTURRET (legacy alias)
     399   ;; SCAN_MOVE (Scanner Sweep)
     1036  ;; PSISTORM_PSISTORM
     1442  ;; EFFECT_BLINK_STALKER
     1526  ;; FORCEFIELD_FORCEFIELD
     1622  ;; TACNUKESTRIKE_NUKECALLDOWN
     1628  ;; EMP_EMP
     1694  ;; BUILD_CREEPTUMOR_QUEEN
     1729  ;; SPINECRAWLERROOT_SPINECRAWLERROOT
     1731  ;; SPORECRAWLERROOT_SPORECRAWLERROOT
     1733  ;; BUILD_CREEPTUMOR_TUMOR
     1764  ;; BUILDAUTOTURRET_AUTOTURRET (SC2 4.10)
     1768  ;; BUILD_NYDUSWORM
     1990  ;; EFFECT_SPAWNLOCUSTS (legacy alias)
     2063  ;; BLINDINGCLOUD_BLINDINGCLOUD
     2146  ;; ORACLEREVELATION_ORACLEREVELATION
     2244  ;; TIMEWARP_TIMEWARP
     2338  ;; EFFECT_CORROSIVEBILE
     2346  ;; EFFECT_PURIFICATIONNOVA
     2358  ;; EFFECT_TACTICALJUMP
     2368  ;; EFFECT_MASSRECALL_MOTHERSHIP
     2387  ;; EFFECT_LOCUSTSWOOP (SC2 4.10)
     2505  ;; BUILD_STASISTRAP
     2544  ;; EFFECT_ADEPTPHASESHIFT
     2545  ;; EFFECT_MICROBIALSHROUD
     2558  ;; MORPH_LIBERATORAGMODE
     2588  ;; KD8CHARGE_KD8CHARGE
     2700  ;; EFFECT_SHADOWSTRIDE
     2704  ;; EFFECT_SPAWNLOCUSTS (SC2 4.10)
     2706  ;; LOCUSTMPFLYINGSWOOPATTACK
     3678  ;; LAND
     3680  ;; ROOT
     3687  ;; EFFECT_BLINK
     3691  ;; BUILD_CREEPTUMOR
     3757  ;; EFFECT_MASSRECALL_NEXUS
     4111  ;; EFFECT_AMORPHOUSARMORCLOUD (SC2 5.0.14 Microbial Shroud)
     )))

(: SC2-UNIT-TARGET-ABILITY-IDS (Setof Integer))
(define SC2-UNIT-TARGET-ABILITY-IDS
  (list->seteqv
   '(140   ;; FEEDBACK_FEEDBACK
     171   ;; EFFECT_CALLDOWNMULE
     173   ;; GRAVITONBEAM_GRAVITONBEAM
     249   ;; NEURALPARASITE_NEURALPARASITE
     251   ;; EFFECT_INJECTLARVA
     255   ;; EFFECT_SUPPLYDROP
     316   ;; EFFECT_REPAIR_SCV
     386   ;; EFFECT_HEAL
     401   ;; YAMATO_YAMATOGUN
     407   ;; LOAD_BUNKER
     1437  ;; LOAD_NYDUSNETWORK
     1664  ;; TRANSFUSION_TRANSFUSION
     1825  ;; CONTAMINATE_CONTAMINATE
     2067  ;; EFFECT_ABDUCT
     2069  ;; VIPERCONSUMESTRUCTURE
     2073  ;; VIPERCONSUME_VIPERCONSUME
     2099  ;; WIDOWMINEATTACK_WIDOWMINEATTACK
     2324  ;; EFFECT_CAUSTICSPRAY
     2350  ;; EFFECT_LOCKON
     2370  ;; LOAD_NYDUSWORM
     2542  ;; EFFECT_PARASITICBOMB
     2714  ;; EFFECT_GHOSTSNIPE (Steady Targeting)
     3668  ;; LOAD_ALL (Transport pickup)
     3685  ;; EFFECT_REPAIR
     3747  ;; EFFECT_INTERFERENCEMATRIX
     3751  ;; SHIELD_BATTERY_RESTORE (legacy alias)
     3753  ;; EFFECT_ANTIARMORMISSILE
     3755  ;; EFFECT_CHRONOBOOSTENERGYCOST
     4107  ;; BATTERYOVERCHARGE_BATTERYOVERCHARGE
     4113  ;; SHIELDBATTERYRECHARGEEX5
     4126  ;; ENERGYRECHARGE_ENERGYRECHARGE
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
(define SC2-CAMERA-MOVE-DEDUP-DIST          8.0)   ;; Min non-base camera shift (tiles) — suppresses short 2-7t screen scrolling in favor of base hotkeys & minimap clicks
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
(: SC2-UNIT-COMBAT-STATS-TABLE (Immutable-HashTable Symbol CombatStatTable))
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
   'disruptor         (hasheq 'max-hp 100 'max-shield 100 'armor 1 'speed 3.15 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 21.4  'damage-point 1.50 'splash-radius 1.5  'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5)
   'observer          (hasheq 'max-hp 40  'max-shield 20  'armor 0 'speed 3.01 'ground-dps 0.0  'air-dps 0.0  'ground-range 0.0  'air-range 0.0  'weapon-period 1.0   'damage-point 0.0  'splash-radius 0.0  'flying? #t 'detector? #t 'can-cloak? #t 'radius 0.375)
   'phoenix           (hasheq 'max-hp 120 'max-shield 60  'armor 0 'speed 5.95 'ground-dps 0.0  'air-dps 14.0 'ground-range 0.0  'air-range 5.0  'weapon-period 0.79  'damage-point 0.06 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'void-ray          (hasheq 'max-hp 150 'max-shield 100 'armor 0 'speed 3.85 'ground-dps 22.4 'air-dps 22.4 'ground-range 6.0  'air-range 6.0  'weapon-period 0.36  'damage-point 0.05 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.875)
   'oracle            (hasheq 'max-hp 100 'max-shield 60  'armor 0 'speed 5.60 'ground-dps 24.4 'air-dps 0.0  'ground-range 4.0  'air-range 0.0  'weapon-period 0.61  'damage-point 0.05 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.75)
   'carrier           (hasheq 'max-hp 300 'max-shield 150 'armor 2 'speed 2.62 'ground-dps 37.5 'air-dps 37.5 'ground-range 8.0  'air-range 8.0  'weapon-period 2.14  'damage-point 0.10 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 1.25)
   'interceptor       (hasheq 'max-hp 40  'max-shield 40  'armor 0 'speed 10.5 'ground-dps 5.0  'air-dps 5.0  'ground-range 2.0  'air-range 2.0  'weapon-period 2.14  'damage-point 0.10 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 0.25)
   'tempest           (hasheq 'max-hp 200 'max-shield 100 'armor 2 'speed 3.15 'ground-dps 16.8 'air-dps 14.3 'ground-range 10.0 'air-range 13.0 'weapon-period 2.36  'damage-point 0.15 'splash-radius 0.0  'flying? #t 'detector? #f 'can-cloak? #f 'radius 1.25)
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

(: DEFAULT-UNIT-COMBAT-STATS CombatStatTable)
(define DEFAULT-UNIT-COMBAT-STATS
  (hasheq 'max-hp 80 'max-shield 0 'armor 0 'speed 3.15
          'ground-dps 10.0 'air-dps 0.0 'ground-range 5.0 'air-range 0.0
          'weapon-period 1.0 'damage-point 0.10 'splash-radius 0.0
          'flying? #f 'detector? #f 'can-cloak? #f 'radius 0.5))

(: sc2-unit-combat-stats (-> Any CombatStatTable))
(define sc2-unit-combat-stats
  (let ([default-thunk : (-> CombatStatTable) (lambda () DEFAULT-UNIT-COMBAT-STATS)])
    (lambda (sym)
      (cond
        [(not (symbol? sym)) DEFAULT-UNIT-COMBAT-STATS]
        [(not (unbox SC2-LIVE-DATA-ACTIVE?))
         (hash-ref SC2-UNIT-COMBAT-STATS-TABLE sym default-thunk)]
        [else
         (define cached (hash-ref SC2-LIVE-COMBAT-STATS-CACHE sym (lambda () #f)))
         (if cached
             cached
             (let* ([canon (canonical-unit-type-sym sym)]
                    [base (hash-ref SC2-UNIT-COMBAT-STATS-TABLE sym default-thunk)]
                    [rng (or (hash-ref SC2-LIVE-RANGE-OVERLAY sym (lambda () #f))
                             (and (not (eq? canon sym))
                                  (hash-ref SC2-LIVE-RANGE-OVERLAY canon (lambda () #f))))]
                    [spd (or (hash-ref SC2-LIVE-SPEED-OVERLAY sym (lambda () #f))
                             (and (not (eq? canon sym))
                                  (hash-ref SC2-LIVE-SPEED-OVERLAY canon (lambda () #f))))]
                    [arm (or (hash-ref SC2-LIVE-ARMOR-OVERLAY sym (lambda () #f))
                             (and (not (eq? canon sym))
                                  (hash-ref SC2-LIVE-ARMOR-OVERLAY canon (lambda () #f))))]
                    [h1 (if rng
                            (let* ([gr (car rng)]
                                   [ar (cdr rng)]
                                   [b1 (if (fl> gr 0.0) (hash-set base 'ground-range gr) base)])
                              (if (fl> ar 0.0) (hash-set b1 'air-range ar) b1))
                            base)]
                    [h2 (if spd (hash-set h1 'speed spd) h1)]
                    [h3 (if arm (hash-set h2 'armor arm) h2)])
               (hash-set! SC2-LIVE-COMBAT-STATS-CACHE sym h3)
               h3))]))))

(: sc2-unit-can-attack-air? (-> Any Boolean))
(define sc2-unit-can-attack-air?
  (let ([false-thunk : (-> Boolean) (lambda () #f)]
        [zero-thunk : (-> Real) (lambda () 0.0)]
        [ht : (Immutable-HashTable Symbol Boolean)
            (for/hasheq : (Immutable-HashTable Symbol Boolean)
                        ([(k stats) (in-hash SC2-UNIT-COMBAT-STATS-TABLE)]
                         #:when (let ([v (hash-ref stats 'air-dps (lambda () 0.0))])
                                  (and (real? v) (> v 0.0))))
              (values k #t))])
    (void zero-thunk)
    (lambda (sym)
      (and (symbol? sym) (hash-ref ht sym false-thunk)))))

(: sc2-unit-can-attack-ground? (-> Any Boolean))
(define sc2-unit-can-attack-ground?
  (let ([false-thunk : (-> Boolean) (lambda () #f)]
        [ht : (Immutable-HashTable Symbol Boolean)
            (for/hasheq : (Immutable-HashTable Symbol Boolean)
                        ([(k stats) (in-hash SC2-UNIT-COMBAT-STATS-TABLE)]
                         #:unless (let ([v (hash-ref stats 'ground-dps (lambda () 0.0))])
                                    (and (real? v) (> v 0.0))))
              (values k #t))])
    (lambda (sym)
      (not (and (symbol? sym) (hash-ref ht sym false-thunk))))))

(: sc2-unit-is-detector-sym? (-> Any Boolean))
(define sc2-unit-is-detector-sym?
  (let ([false-thunk : (-> Boolean) (lambda () #f)]
        [ht : (Immutable-HashTable Symbol Boolean)
            (for/hasheq : (Immutable-HashTable Symbol Boolean)
                        ([(k stats) (in-hash SC2-UNIT-COMBAT-STATS-TABLE)]
                         #:when (eq? (hash-ref stats 'detector? (lambda () #f)) #t))
              (values k #t))])
    (lambda (sym)
      (and (symbol? sym) (hash-ref ht sym false-thunk)))))

(: sc2-unit-is-flying-sym? (-> Any Boolean))
(define sc2-unit-is-flying-sym?
  (let ([false-thunk : (-> Boolean) (lambda () #f)]
        [ht : (Immutable-HashTable Symbol Boolean)
            (for/hasheq : (Immutable-HashTable Symbol Boolean)
                        ([(k stats) (in-hash SC2-UNIT-COMBAT-STATS-TABLE)]
                         #:when (eq? (hash-ref stats 'flying? (lambda () #f)) #t))
              (values k #t))])
    (lambda (sym)
      (and (symbol? sym) (hash-ref ht sym false-thunk)))))

;; Invulnerable shades, phased projectiles, eggs/larvae, and decoys that should
;; never be selected as primary combat attack targets:
(: SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS (Listof Symbol))
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
(: SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS (Listof Symbol))
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

(: SC2-ALL-STRUCTURE-SYMS (Listof Symbol))
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
(: SC2-TECHLAB-REQUIRED-UNIT-SYMS (Listof Symbol))
(define SC2-TECHLAB-REQUIRED-UNIT-SYMS
  '(marauder
    ghost
    siege-tank
    cyclone
    thor
    banshee
    raven
    battlecruiser))

(: sc2-unit-requires-techlab? (-> Any Boolean))
(define (sc2-unit-requires-techlab? sym)
  (cond
    [(not (symbol? sym)) #f]
    [(unbox SC2-LIVE-DATA-ACTIVE?)
     (define canon (canonical-unit-type-sym sym))
     (define live
       (hash-ref SC2-LIVE-TECHLAB-OVERLAY sym
                 (lambda ()
                   (hash-ref SC2-LIVE-TECHLAB-OVERLAY canon (lambda () 'miss)))))
     (if (boolean? live)
         live
         (and (memq canon SC2-TECHLAB-REQUIRED-UNIT-SYMS) #t))]
    [else
     (and (memq (canonical-unit-type-sym sym) SC2-TECHLAB-REQUIRED-UNIT-SYMS) #t)]))

(: sc2-enemy-unit-targetable? (-> Any Boolean))
(define (sc2-enemy-unit-targetable? e)
  (cond
    [(hash? e)
     (define ty (hash-ref e 'type (lambda () 'unknown)))
     (and (not (and (symbol? ty) (memq ty SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS)))
          (not (eq? (hash-ref e 'hallucination (lambda () #f)) #t)))]
    [(symbol? e)
     (not (memq e SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS))]
    [else #t]))

(: sc2-attacker-can-hit-enemy? (->* (Any Any) (Any) Boolean))
(define (sc2-attacker-can-hit-enemy? attacker-sym e [enemy-flying-override #f])
  (define eflying?
    (cond
      [(hash? e)
       (or (eq? (hash-ref e 'flying (lambda () #f)) #t)
           (eq? (hash-ref e 'flying? (lambda () #f)) #t)
           (eq? (hash-ref e 'is-flying (lambda () #f)) #t)
           (sc2-unit-is-flying-sym? (hash-ref e 'type (lambda () 'marine))))]
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
(: SC2-MOBILE-DETECTOR-SYMS (Listof Symbol))
(define SC2-MOBILE-DETECTOR-SYMS
  '(observer observer-siege-mode overseer overseer-siege-mode raven))
(: SC2-STATIC-DETECTOR-SYMS (Listof Symbol))
(define SC2-STATIC-DETECTOR-SYMS
  '(missile-turret photon-cannon spore-crawler))
(: SC2-CHANGELING-UNIT-SYMS (Listof Symbol))
(define SC2-CHANGELING-UNIT-SYMS
  '(changeling changeling-zealot changeling-marine-shield
    changeling-marine changeling-zergling-wings changeling-zergling))
(: SC2-CLOAKED-OR-BURROW-STEALTH-SYMS (Listof Symbol))
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
(: SC2-BLIND-AOE-SKILLSHOT-SPELLS (Listof Symbol))
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

(: sc2-canonical-structure-sym (-> Any Symbol))
(define (sc2-canonical-structure-sym sym)
  (if (not (symbol? sym))
      'unknown
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
        [else                          sym])))

(: SC2-PROTOSS-PYLON-POWERED-STRUCTURE-SYMS (Listof Symbol))
(define SC2-PROTOSS-PYLON-POWERED-STRUCTURE-SYMS
  '(gateway warp-gate warpgate cybernetics-core forge photon-cannon shield-battery
    twilight-council robotics-facility robotics-bay robotics-support-bay
    stargate fleet-beacon templar-archive templar-archives dark-shrine))

(: sc2-structure-requires-pylon-power? (-> Any Boolean))
(define sc2-structure-requires-pylon-power?
  (let ([false-thunk : (-> Boolean) (lambda () #f)]
        [ht : (Immutable-HashTable Symbol Boolean)
            (for/hasheq : (Immutable-HashTable Symbol Boolean)
                        ([s (in-list SC2-PROTOSS-PYLON-POWERED-STRUCTURE-SYMS)])
              (values s #t))])
    (lambda (sym)
      (and (symbol? sym)
           (hash-ref ht (sc2-canonical-structure-sym sym) false-thunk)))))

(: sc2-structure-equivalent-syms (->* (Any) (Boolean) (Listof Symbol)))
(define (sc2-structure-equivalent-syms sym [include-free-addons? #f])
  (if (not (symbol? sym))
      '()
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
         (list sym)])))

(: sc2-structure-matches-target? (->* (Any Any) (Boolean) Boolean))
(define sc2-structure-matches-target?
  (let* ([false-thunk : (-> Boolean) (lambda () #f)]
         [empty-ht : (Immutable-HashTable Symbol Boolean) (hasheq)]
         [empty-thunk : (-> (Immutable-HashTable Symbol Boolean)) (lambda () empty-ht)]
         [build-equiv-map : (-> Boolean (Immutable-HashTable Symbol (Immutable-HashTable Symbol Boolean)))
                          (lambda (addons?)
                            (define base-ht : (Mutable-HashTable Symbol (Immutable-HashTable Symbol Boolean))
                              (make-hasheq))
                            (for ([target (in-list SC2-ALL-STRUCTURE-SYMS)])
                              (define eqs (sc2-structure-equivalent-syms target addons?))
                              (when (pair? (cdr eqs))
                                (hash-set! base-ht target
                                           (for/hasheq : (Immutable-HashTable Symbol Boolean)
                                                       ([s (in-list eqs)])
                                             (values s #t)))))
                            (for/hasheq : (Immutable-HashTable Symbol (Immutable-HashTable Symbol Boolean))
                                        ([(k v) (in-hash base-ht)])
                              (values k v)))]
         [map-no-addons : (Immutable-HashTable Symbol (Immutable-HashTable Symbol Boolean))
                        (build-equiv-map #f)]
         [map-with-addons : (Immutable-HashTable Symbol (Immutable-HashTable Symbol Boolean))
                          (build-equiv-map #t)])
    (lambda (actual-sym target-sym [include-free-addons? #f])
      (and (symbol? actual-sym)
           (or (eq? actual-sym target-sym)
               (and (symbol? target-sym)
                    (let ([sub (hash-ref (if include-free-addons? map-with-addons map-no-addons)
                                         target-sym
                                         empty-thunk)])
                      (hash-ref sub actual-sym false-thunk))))))))

(: sc2-count-equivalent-structures (->* (Any Any) (Boolean) Integer))
(define (sc2-count-equivalent-structures counts-hash sym [include-free-addons? #f])
  (if (hash? counts-hash)
      (for/sum ([s (in-list (sc2-structure-equivalent-syms sym include-free-addons?))])
        (define v (hash-ref counts-hash s (lambda () 0)))
        (if (exact-integer? v) v 0))
      0))

(define CANONICAL-MISS-SENTINEL : Symbol
  (string->uninterned-symbol "sc2-canon-miss"))

(: canon-miss-thunk (-> Symbol))
(define (canon-miss-thunk) CANONICAL-MISS-SENTINEL)

(define CANONICAL-UNIT-SYM-HT : (Immutable-HashTable Symbol Symbol)
  (hasheq
   'viking-fighter             'viking
   'viking-assault             'viking
   'siege-tank-sieged          'siege-tank
   'widow-mine-burrowed        'widow-mine
   'thor-ap                    'thor
   'liberator-ag               'liberator
   'lurker-mp                  'lurker
   'lurker-burrowed            'lurker
   'lurker-mp-burrowed         'lurker
   'lurker-egg                 'lurker
   'lurker-mp-egg              'lurker
   'baneling-burrowed          'baneling
   'baneling-cocoon            'baneling
   'ravager-cocoon             'ravager
   'ravager-burrowed           'ravager
   'broodlord                  'brood-lord
   'brood-lord-cocoon          'brood-lord
   'overlord-cocoon            'overseer
   'overseer-siege-mode        'overseer
   'overlord-transport         'overlord
   'transport-overlord-cocoon  'overlord
   'roach-burrowed             'roach
   'zergling-burrowed          'zergling
   'hydralisk-burrowed         'hydralisk
   'infestor-burrowed          'infestor
   'swarm-host-burrowed        'swarm-host
   'swarmhost                  'swarm-host
   'ultralisk-burrowed         'ultralisk
   'queen-burrowed             'queen
   'drone-burrowed             'drone
   'observer-siege-mode        'observer
   'warp-prism-phasing         'warp-prism
   'voidray                    'void-ray))

(: sc2-canonical-unit-sym (-> Any Symbol))
(define (sc2-canonical-unit-sym sym)
  (if (not (symbol? sym))
      'unknown
      (let ([hit (hash-ref CANONICAL-UNIT-SYM-HT sym canon-miss-thunk)])
        (if (eq? hit CANONICAL-MISS-SENTINEL) sym hit))))

(: sc2-unit-equivalent-syms (-> Any (Listof Symbol)))
(define (sc2-unit-equivalent-syms sym)
  (if (not (symbol? sym))
      '()
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
         (list sym)])))

;; True for 3x3 and 5x5 SC2 structures whose footprint centers snap to (x.5, y.5)
;; rather than 2x2 integer centers (x.0, y.0).
(: SC2-2X2-STRUCTURE-SYMS (Listof Symbol))
(define SC2-2X2-STRUCTURE-SYMS
  '(supply-depot supply-depot-lowered missile-turret sensor-tower
    pylon pylon-overcharged photon-cannon shield-battery dark-shrine oracle-stasis-trap
    spire greater-spire spine-crawler spine-crawler-uprooted
    spore-crawler spore-crawler-uprooted
    barracks-techlab barracks-tech-lab barracks-reactor
    factory-techlab factory-tech-lab factory-reactor
    starport-techlab starport-tech-lab starport-reactor
    tech-lab techlab reactor))

(: SC2-TOWNHALL-STRUCTURE-SYMS (Listof Symbol))
(define SC2-TOWNHALL-STRUCTURE-SYMS
  '(hatchery lair hive
    nexus
    command-center command-center-flying
    orbital-command orbital-command-flying
    planetary-fortress))

(: sc2-odd-footprint-structure? (-> Any Boolean))
(define sc2-odd-footprint-structure?
  (let ([false-thunk : (-> Boolean) (lambda () #f)]
        [ht : (Immutable-HashTable Symbol Boolean)
            (for/hasheq : (Immutable-HashTable Symbol Boolean)
                        ([s (in-list SC2-ALL-STRUCTURE-SYMS)]
                         #:unless (memq s SC2-2X2-STRUCTURE-SYMS))
              (values s #t))])
    (lambda (sym)
      (and (symbol? sym) (hash-ref ht sym false-thunk)))))

;; -----------------------------------------------------------------------------
;; 11. Generalized Cross-Cutting Ontology, Order Protection, Role-Lease Registry,
;;     Bistable Hysteresis, Chebyshev AABB Footprints & Macro Energy Dispatcher
;; -----------------------------------------------------------------------------

;; Canonical mapping from generic/smart vs race-specific Unit.orders ability IDs.
(: sc2-canonical-order-ability (-> Any Any))
(define sc2-canonical-order-ability
  (let* ([miss : Symbol (gensym 'sc2-order-ability-miss)]
         [miss-thunk : (-> Symbol) (lambda () miss)]
         [pairs : (Listof (Pair (Listof Integer) Symbol))
                '(((166 295 298 1183 3666) . harvest-gather)
                  ((167 296 299 1184 3667) . harvest-return)
                  ((168 316 3685)          . repair)
                  ((16 19 20 3794)         . move)
                  ((17 3795)               . patrol)
                  ((18 3793)               . hold-position)
                  ((4 5 6 7 3665)          . stop)
                  ((23 24 25 2099 3674 3771) . attack)
                  ((417 452 485 518 1522 3679) . lift)
                  ((419 520 522 554 1524 3678) . land)
                  ((421 454 487 3682)      . build-techlab)
                  ((422 455 488 3683)      . build-reactor)
                  ((1374 1378 1382 1386 1390 1433 1444 1512 2014 2095 2108 2340 3661) . burrow-down)
                  ((1376 1380 1384 1388 1392 1435 1446 1514 2016 2097 2110 2342 3662) . burrow-up)
                  ((1394 1396 3680)        . uproot)
                  ((1398 1400 3681)        . root)
                  ((1662 1694 1733 3691)   . spawn-creep-tumor)
                  ((253 380 3675)          . stim)
                  ((1442 3687)             . blink)
                  ((142 2368 3686 3757)    . mass-recall)
                  ((1163 2112)             . build-lurker-den)
                  ((895 1909)              . build-shield-battery)
                  ((80 4121)               . morph-baneling)
                  ((349 379 1764)          . auto-turret)
                  ((2069 2073)             . viper-consume)
                  ((1990 2704)             . spawn-locusts)
                  ((2706 2387)             . locust-swoop)
                  ((2545 4111)             . microbial-shroud)
                  ((1882 1692)             . overlord-generate-creep))]
         [ht : (Immutable-HashTable Integer Symbol)
             (for*/hasheqv : (Immutable-HashTable Integer Symbol)
                           ([grp (in-list pairs)]
                            [id (in-list (car grp))])
               (values id (cdr grp)))])
    (lambda (ab-id)
      (if (exact-integer? ab-id)
          (let ([hit (hash-ref ht ab-id miss-thunk)])
            (if (eq? hit miss) ab-id hit))
          ab-id))))

;; Protected Unit.orders classes that must not be overwritten by generic army/idle commands:
(: SC2-PROTECTED-ORDER-CLASS-TABLE (Immutable-HashTable Integer Symbol))
(define SC2-PROTECTED-ORDER-CLASS-TABLE
  (let ([ht : (Mutable-HashTable Integer Symbol) (make-hasheqv)])
    (for ([id (in-list '(80 4121 2330 2332 1372 1448 2708 1766 1216 1218 1220 1516 1450 1518))])
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
                         1764 2338 2346 2067 2063 2542 2545 4111 2704 3747 3753 181 2505 1526))])
      (hash-set! ht id 'cast-walk))
    (for/hasheqv : (Immutable-HashTable Integer Symbol) ([(k v) (in-hash ht)])
      (values k v))))

(: sc2-order-protection-class (-> Any (Option Symbol)))
(define sc2-order-protection-class
  (let ([false-thunk : (-> False) (lambda () #f)])
    (lambda (ab-id)
      (cond
        [(exact-integer? ab-id)
         (hash-ref SC2-PROTECTED-ORDER-CLASS-TABLE ab-id false-thunk)]
        [(symbol? ab-id)
         (case ab-id
           [(burrow-down burrow-up lift land uproot root) 'mode-switch]
           [(spawn-creep-tumor) 'cast-walk]
           [(mass-recall) 'channel]
           [else #f])]
        [else #f]))))

;; Non-combat morphing cocoons/eggs, temporary summons, wards, scouts, and auxiliary transports.
(: SC2-COCOON-AND-EGG-SYMS (Listof Symbol))
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

(: SC2-NON-ARMY-SUMMON-AND-AUX-SYMS (Listof Symbol))
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

(: SC2-NON-ARMY-SUMMON-AND-AUX-SET (Setof Symbol))
(define SC2-NON-ARMY-SUMMON-AND-AUX-SET
  (list->seteq SC2-NON-ARMY-SUMMON-AND-AUX-SYMS))

(: sc2-non-combat-or-summon-sym? (-> Any Boolean))
(define sc2-non-combat-or-summon-sym?
  (let* ([miss : Symbol 'sc2-non-combat-miss]
         [miss-thunk : (-> Symbol) (lambda () miss)]
         [aux-ht : (Immutable-HashTable Symbol Boolean)
                 (for/hasheq : (Immutable-HashTable Symbol Boolean)
                             ([s (in-list SC2-NON-ARMY-SUMMON-AND-AUX-SYMS)])
                   (values s #t))]
         [compute : (-> Symbol Boolean)
                  (lambda (sym)
                    (or (hash-has-key? aux-ht sym)
                        (let ([s (symbol->string sym)])
                          (or (regexp-match? #rx"^changeling" s)
                              (regexp-match? #rx"^creep-tumor" s)
                              (regexp-match? #rx"-cocoon$" s)
                              (regexp-match? #rx"-egg$" s)))))]
         [cache : (Mutable-HashTable Symbol Boolean) (make-hasheq)])
    (for ([s (in-list SC2-NON-ARMY-SUMMON-AND-AUX-SYMS)])
      (hash-set! cache s #t))
    (for ([(s _) (in-hash SC2-UNIT-COMBAT-STATS-TABLE)])
      (unless (hash-has-key? cache s)
        (hash-set! cache s (compute s))))
    (lambda (sym)
      (if (symbol? sym)
          (let ([hit (hash-ref cache sym miss-thunk)])
            (if (boolean? hit)
                hit
                (let ([res (compute sym)])
                  (when (< (hash-count cache) 4096)
                    (hash-set! cache sym res))
                  res)))
          #f))))

;; Unit Role-Lease Registry
(struct unit-role-lease
  ([role : Symbol]
   [priority : Integer]
   [target-id : Any]
   [target-x : Float]
   [target-y : Float]
   [expires-frame : Integer])
  #:transparent)

(: role-lease-priority (-> Any Integer))
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
    [(strike-group)     55]
    [(staging-group)    50]
    [(army)             20]
    [(harvester)        10]
    [else                0]))

(: acquire-unit-lease!
   (->* (Any Any Symbol Integer Integer)
        (#:target-id Any #:x Real #:y Real)
        Boolean))
(define (acquire-unit-lease! lease-ht uid role frame ttl #:target-id [tid 0] #:x [tx 0.0] #:y [ty 0.0])
  (cond
    [(and (hash? lease-ht) (not (immutable? lease-ht)) (exact-integer? uid) (> uid 0))
     (define new-prio (role-lease-priority role))
     (define existing (hash-ref lease-ht uid (lambda () #f)))
     (cond
       [(or (not (unit-role-lease? existing))
            (<= (unit-role-lease-expires-frame existing) frame)
            (>= new-prio (unit-role-lease-priority existing)))
        (define lease
          (unit-role-lease role
                           new-prio
                           tid
                           (->float tx)
                           (->float ty)
                           (+ frame (max 1 ttl))))
        (dyn-hash-set! lease-ht uid lease)
        #t]
       [else #f])]
    [else #f]))

(: unit-leased-above? (-> Any Any Any Integer Boolean))
(define (unit-leased-above? lease-ht uid caller-role frame)
  (and (hash? lease-ht)
       uid
       (let ([existing (hash-ref lease-ht uid (lambda () #f))])
         (and (unit-role-lease? existing)
              (> (unit-role-lease-expires-frame existing) frame)
              (> (unit-role-lease-priority existing) (role-lease-priority caller-role))
              #t))))

(: leased-tags-above (-> Any Any Integer (Setof Integer)))
(define (leased-tags-above lease-ht caller-role frame)
  (cond
    [(hash? lease-ht)
     (define caller-prio (role-lease-priority caller-role))
     (for/fold ([acc : (Setof Integer) (ann (seteqv) (Setof Integer))])
               ([(uid lease) (in-hash lease-ht)])
       (if (and (exact-integer? uid)
                (unit-role-lease? lease)
                (> (unit-role-lease-expires-frame lease) frame)
                (> (unit-role-lease-priority lease) caller-prio))
           (set-add acc uid)
           acc))]
    [else (ann (seteqv) (Setof Integer))]))

;; Bistable Hysteresis Controller (Schmitt trigger + minimum dwell + re-entry cooldown)
(struct bistable-state
  ([active? : Boolean]
   [changed-frame : Integer]
   [cooldown-until-frame : Integer])
  #:transparent)

(: bistable-hysteresis-step
   (->* (Any Any Integer #:enter? Boolean #:exit? Boolean)
        (#:min-dwell-loops Integer #:cooldown-loops Integer)
        Boolean))
(define (bistable-hysteresis-step state-ht key frame
                                  #:enter? enter-now?
                                  #:exit? exit-now?
                                  #:min-dwell-loops [min-dwell 44]
                                  #:cooldown-loops [cooldown 22])
  (define raw-prev (and (hash? state-ht) (hash-ref state-ht key (lambda () #f))))
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
    (dyn-hash-set! state-ht key next))
  (bistable-state-active? next))

;; Chebyshev / Axis-Aligned Bounding Box Reserved Spatial Footprint
(struct reserved-aabb
  ([cx : Float]
   [cy : Float]
   [half-w : Float]
   [half-h : Float]
   [kind : Symbol]
   [owner-tag : Any]
   [expires-frame : Integer])
  #:transparent)

(: aabb-overlaps? (-> Real Real Real Real Any Boolean))
(define (aabb-overlaps? cx1 cy1 hw1 hh1 b)
  (and (reserved-aabb? b)
       (< (abs (- (->float cx1) (->float (reserved-aabb-cx b))))
          (- (+ (->float hw1) (->float (reserved-aabb-half-w b))) 1e-6))
       (< (abs (- (->float cy1) (->float (reserved-aabb-cy b))))
          (- (+ (->float hh1) (->float (reserved-aabb-half-h b))) 1e-6))
       #t))

(: sc2-structure-half-dims (-> Any (Values Float Float)))
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
(: dispatch-macro-energy!
   (->* ((Listof Any)
         (Listof Any)
         Integer
         Any
         #:min-energy Real
         #:valid-pair? Cb23
         #:score-pair Cb23
         #:emit-cast! Cb23)
        (#:valid-caster? Cb12)
        (Listof Any)))
(define (dispatch-macro-energy! casters
                                candidates
                                frame
                                claimed-targets-set
                                #:min-energy min-energy
                                #:valid-caster? [valid-caster? (lambda ([_c : Any]) #t)]
                                #:valid-pair? valid-pair?
                                #:score-pair score-pair
                                #:emit-cast! emit-cast!)
  (define local-claimed-casters : (Mutable-HashTable Any Boolean) (make-hash))
  (define local-claimed-targets : (Mutable-HashTable Any Boolean) (make-hash))
  (: entity-key (-> Any Any))
  (define (entity-key x)
    (cond
      [(hash? x) (or (hash-ref x 'id (lambda () #f))
                     (hash-ref x 'tag (lambda () #f))
                     x)]
      [else x]))
  (: target-claimed? (-> Any Any Boolean))
  (define (target-claimed? tkey raw-cand)
    (or (hash-has-key? local-claimed-targets tkey)
        (cond
          [(set-mutable? claimed-targets-set)
           (or (set-member? claimed-targets-set tkey)
               (set-member? claimed-targets-set raw-cand))]
          [(set? claimed-targets-set)
           (or (set-member? claimed-targets-set tkey)
               (set-member? claimed-targets-set raw-cand))]
          [(hash? claimed-targets-set)
           (or (hash-has-key? claimed-targets-set tkey)
               (hash-has-key? claimed-targets-set raw-cand))]
          [else #f])))
  (: claim-target! (-> Any Void))
  (define (claim-target! tkey)
    (hash-set! local-claimed-targets tkey #t)
    (cond
      [(set-mutable? claimed-targets-set)
       (set-add! claimed-targets-set tkey)]
      [(and (hash? claimed-targets-set) (not (immutable? claimed-targets-set)))
       (dyn-hash-set! claimed-targets-set tkey frame)]
      [else (void)]))
  (define eligible-casters : (Listof Any)
    (for/list : (Listof Any)
              ([c (in-list casters)]
               #:when (and (or (not (hash? c))
                               (let ([en (hash-ref c 'energy (lambda () 0.0))])
                                 (and (real? en) (>= en min-energy))))
                           (and (call-1-or-2 valid-caster? c frame) #t)))
      c))
  (define scored-pairs : (Listof (Vector Float Any Any Any Any))
    (for*/fold ([acc : (Listof (Vector Float Any Any Any Any)) '()])
               ([c (in-list eligible-casters)]
                [cand (in-list candidates)])
      (define tkey (entity-key cand))
      (if (and (not (target-claimed? tkey cand))
               (and (call-2-or-3 valid-pair? c cand frame) #t))
          (let ([sc (call-2-or-3 score-pair c cand frame)])
            (if (and (real? sc) (not (nan? sc)) (not (infinite? sc)))
                (cons (vector (->float sc) c cand (entity-key c) tkey) acc)
                acc))
          acc)))
  (define sorted-pairs : (Listof (Vector Float Any Any Any Any))
    (sort scored-pairs
          (lambda ([a : (Vector Float Any Any Any Any)]
                   [b : (Vector Float Any Any Any Any)])
            (> (vector-ref a 0) (vector-ref b 0)))))
  (define emitted : (Listof Any) '())
  (for ([v (in-list sorted-pairs)])
    (define c (vector-ref v 1))
    (define cand (vector-ref v 2))
    (define ckey (vector-ref v 3))
    (define tkey (vector-ref v 4))
    (unless (or (hash-has-key? local-claimed-casters ckey)
                (target-claimed? tkey cand))
      (hash-set! local-claimed-casters ckey #t)
      (claim-target! tkey)
      (define res (call-2-or-3 emit-cast! c cand frame))
      (when (and res (not (void? res)))
        (set! emitted (cons res emitted)))))
  (reverse emitted))

;; Midgame Economy-to-Army Curve (prevents pure-drone / pure-probe greed deaths vs pushes)
(: required-army-supply-for-worker-growth (->* (Real) (Real) Float))
(define (required-army-supply-for-worker-growth total-workers [enemy-threat-supply 0.0])
  (max (* 0.85 (->float enemy-threat-supply))
       (cond
         [(< total-workers 26) 0.0]
         [(< total-workers 34) 4.0]
         [(< total-workers 40) 8.0]
         [(< total-workers 46) 12.0]
         [(< total-workers 54) 18.0]
         [(< total-workers 64) 32.0]
         [else 48.0])))

;; -----------------------------------------------------------------------------
;; 12. LotV O(1) Unit Attributes, Collision Radii, Exact Weapon-vs-Armor Math
;;     & Attribute-Gated Spell Eligibility (Zero External Dependencies)
;; -----------------------------------------------------------------------------

(: SC2-UNIT-ATTR-LIGHT Fixnum)
(define SC2-UNIT-ATTR-LIGHT 1)
(: SC2-UNIT-ATTR-ARMORED Fixnum)
(define SC2-UNIT-ATTR-ARMORED 2)
(: SC2-UNIT-ATTR-BIOLOGICAL Fixnum)
(define SC2-UNIT-ATTR-BIOLOGICAL 4)
(: SC2-UNIT-ATTR-MECHANICAL Fixnum)
(define SC2-UNIT-ATTR-MECHANICAL 8)
(: SC2-UNIT-ATTR-PSIONIC Fixnum)
(define SC2-UNIT-ATTR-PSIONIC 16)
(: SC2-UNIT-ATTR-MASSIVE Fixnum)
(define SC2-UNIT-ATTR-MASSIVE 32)
(: SC2-UNIT-ATTR-SHIELDED Fixnum)
(define SC2-UNIT-ATTR-SHIELDED 64)
(: SC2-UNIT-ATTR-FRENZIED Fixnum)
(define SC2-UNIT-ATTR-FRENZIED 128)
(: SC2-UNIT-ATTR-STRUCTURE Fixnum)
(define SC2-UNIT-ATTR-STRUCTURE 256)
(: SC2-UNIT-ATTR-HEROIC Fixnum)
(define SC2-UNIT-ATTR-HEROIC 512)

;; Canonical numeric unit_type ID -> symbol map for O(1) attribute/radius lookup
(: SC2-UNIT-ID->SYM-TABLE (Immutable-HashTable Integer Symbol))
(define SC2-UNIT-ID->SYM-TABLE
  (hasheqv
   ;; Zerg Units & Structures
   151 'larva 103 'egg 104 'drone 116 'drone-burrowed
   106 'overlord 128 'overlord-cocoon 892 'transport-overlord-cocoon
   893 'overlord-transport 129 'overseer 1912 'overseer-siege-mode
   105 'zergling 119 'zergling-burrowed
   8 'baneling-cocoon 9 'baneling 115 'baneling-burrowed
   110 'roach 118 'roach-burrowed
   687 'ravager-cocoon 688 'ravager 690 'ravager-burrowed
   107 'hydralisk 117 'hydralisk-burrowed
   501 'lurker-egg 502 'lurker 503 'lurker-burrowed
   108 'mutalisk 112 'corruptor 113 'brood-lord-cocoon 114 'brood-lord
   126 'queen 125 'queen-burrowed
   111 'infestor 127 'infestor-burrowed
   494 'swarm-host 493 'swarm-host-burrowed
   109 'ultralisk 131 'ultralisk-burrowed
   499 'viper
   12 'changeling 13 'changeling-zealot 14 'changeling-marine-shield
   15 'changeling-marine 16 'changeling-zergling-wings 17 'changeling-zergling
   489 'locust 693 'locust-flying 289 'broodling 143 'broodling-escort
   824 'parasitic-bomb-dummy
   86 'hatchery 100 'lair 101 'hive 88 'extractor 1995 'extractor-rich
   89 'spawning-pool 90 'evolution-chamber 97 'roach-warren 96 'baneling-nest
   91 'hydralisk-den 504 'lurker-den 92 'spire 102 'greater-spire
   94 'infestation-pit 93 'ultralisk-cavern 95 'nydus-network 142 'nydus-worm
   98 'spine-crawler 139 'spine-crawler-uprooted
   99 'spore-crawler 140 'spore-crawler-uprooted
   87 'creep-tumor 137 'creep-tumor-burrowed 138 'creep-tumor-queen
   ;; Terran Units & Structures
   45 'scv 268 'mule 48 'marine 51 'marauder 49 'reaper 50 'ghost
   53 'hellion 484 'hellbat 498 'widow-mine 500 'widow-mine-burrowed
   33 'siege-tank 32 'siege-tank-sieged 692 'cyclone
   52 'thor 691 'thor-ap 35 'viking 34 'viking-assault
   54 'medivac 689 'liberator 734 'liberator-ag
   56 'raven 55 'banshee 57 'battlecruiser
   31 'auto-turret 11 'point-defense-drone 830 'kd8-charge 1913 'raven-repair-drone
   18 'command-center 36 'command-center-flying
   132 'orbital-command 134 'orbital-command-flying
   130 'planetary-fortress 19 'supply-depot 47 'supply-depot-lowered
   20 'refinery 1943 'refinery-rich 21 'barracks 46 'barracks-flying
   27 'factory 43 'factory-flying 28 'starport 44 'starport-flying
   22 'engineering-bay 29 'armory 24 'bunker 23 'missile-turret
   25 'sensor-tower 26 'ghost-academy 30 'fusion-core
   5 'tech-lab 6 'reactor 37 'barracks-tech-lab 38 'barracks-reactor
   39 'factory-tech-lab 40 'factory-reactor 41 'starport-tech-lab 42 'starport-reactor
   ;; Protoss Units & Structures
   84 'probe 73 'zealot 74 'stalker 77 'sentry 311 'adept 801 'adept-phase-shift
   75 'high-templar 76 'dark-templar 141 'archon 83 'immortal
   82 'observer 1911 'observer-siege-mode 81 'warp-prism 136 'warp-prism-phasing
   4 'colossus 694 'disruptor 733 'disruptor-phased
   78 'phoenix 80 'void-ray 495 'oracle 79 'carrier 496 'tempest
   10 'mothership 488 'mothership-core 85 'interceptor
   59 'nexus 60 'pylon 894 'pylon-overcharged 61 'assimilator 1994 'assimilator-rich
   62 'gateway 133 'warp-gate 63 'forge 72 'cybernetics-core
   66 'photon-cannon 1910 'shield-battery 65 'twilight-council
   71 'robotics-facility 70 'robotics-bay 67 'stargate
   68 'templar-archive 69 'dark-shrine 64 'fleet-beacon 732 'oracle-stasis-trap))

(: SC2-UNIT-SYM-ALIAS-TABLE (Immutable-HashTable Symbol Symbol))
(define SC2-UNIT-SYM-ALIAS-TABLE
  (hasheq
   'broodlord 'brood-lord
   'voidray 'void-ray
   'swarmhost 'swarm-host
   'hellion-tank 'hellbat
   'viking-fighter 'viking
   'warpgate 'warp-gate
   'lurker-mp 'lurker
   'lurker-mp-burrowed 'lurker-burrowed
   'lurker-mp-egg 'lurker-egg
   'robotics-support-bay 'robotics-bay
   'templar-archives 'templar-archive
   'nydus-canal 'nydus-worm
   'stasis-ward 'oracle-stasis-trap
   'techlab 'tech-lab
   'barracks-techlab 'barracks-tech-lab
   'factory-techlab 'factory-tech-lab
   'starport-techlab 'starport-tech-lab))

(: canonical-unit-type-sym (-> Any Symbol))
(define (canonical-unit-type-sym unit-type-or-id)
  (cond
    [(symbol? unit-type-or-id)
     (hash-ref SC2-UNIT-SYM-ALIAS-TABLE unit-type-or-id (lambda () unit-type-or-id))]
    [(exact-integer? unit-type-or-id)
     (hash-ref SC2-UNIT-ID->SYM-TABLE unit-type-or-id (lambda () 'unknown))]
    [(string? unit-type-or-id)
     (define sym (string->symbol (string-replace (string-downcase (string-trim unit-type-or-id)) "_" "-")))
     (hash-ref SC2-UNIT-SYM-ALIAS-TABLE sym (lambda () sym))]
    [else 'unknown]))

(: fx-attr-or (-> Fixnum * Fixnum))
(define (fx-attr-or . bits)
  (for/fold ([acc : Fixnum 0]) ([b (in-list bits)])
    (fxior acc b)))

(: SC2-UNIT-ATTRIBUTE-MASK-TABLE (Immutable-HashTable Symbol Fixnum))
(define SC2-UNIT-ATTRIBUTE-MASK-TABLE
  (let ([L SC2-UNIT-ATTR-LIGHT]
        [A SC2-UNIT-ATTR-ARMORED]
        [B SC2-UNIT-ATTR-BIOLOGICAL]
        [M SC2-UNIT-ATTR-MECHANICAL]
        [P SC2-UNIT-ATTR-PSIONIC]
        [X SC2-UNIT-ATTR-MASSIVE]
        [S SC2-UNIT-ATTR-SHIELDED]
        [F SC2-UNIT-ATTR-FRENZIED]
        [T SC2-UNIT-ATTR-STRUCTURE]
        [H SC2-UNIT-ATTR-HEROIC]
        [fxior fx-attr-or])
    (hasheq
     ;; Zerg Units
     'larva                       (fxior L B)
     'egg                         B
     'cocoon                      B
     'baneling-cocoon             B
     'ravager-cocoon              B
     'brood-lord-cocoon           B
     'lurker-egg                  B
     'drone                       (fxior L B)
     'drone-burrowed              (fxior L B)
     'zergling                    (fxior L B)
     'zergling-burrowed           (fxior L B)
     'baneling                    B
     'baneling-burrowed           B
     'queen                       (fxior B P)
     'queen-burrowed              (fxior B P)
     'roach                       (fxior A B)
     'roach-burrowed              (fxior A B)
     'ravager                     B
     'ravager-burrowed            B
     'hydralisk                   (fxior L B)
     'hydralisk-burrowed          (fxior L B)
     'lurker                      (fxior A B)
     'lurker-burrowed             (fxior A B)
     'mutalisk                    (fxior L B)
     'corruptor                   (fxior A B)
     'brood-lord                  (fxior A B X)
     'infestor                    (fxior A B P)
     'infestor-burrowed           (fxior A B P)
     'swarm-host                  (fxior A B)
     'swarm-host-burrowed         (fxior A B)
     'ultralisk                   (fxior A B X F)
     'ultralisk-burrowed          (fxior A B X F)
     'viper                       (fxior A B P)
     'overlord                    (fxior A B)
     'overlord-transport          (fxior A B)
     'overlord-cocoon             (fxior A B)
     'transport-overlord-cocoon   (fxior A B)
     'overseer                    (fxior A B)
     'overseer-siege-mode         (fxior A B)
     'locust                      (fxior L B)
     'locust-flying               (fxior L B)
     'broodling                   (fxior L B)
     'broodling-escort            (fxior L B)
     'changeling                  (fxior L B)
     'changeling-zealot           (fxior L B)
     'changeling-marine-shield    (fxior L B)
     'changeling-marine           (fxior L B)
     'changeling-zergling-wings   (fxior L B)
     'changeling-zergling         (fxior L B)
     ;; Zerg Structures
     'hatchery                    (fxior A B T)
     'lair                        (fxior A B T)
     'hive                        (fxior A B T)
     'extractor                   (fxior A B T)
     'extractor-rich              (fxior A B T)
     'spawning-pool               (fxior A B T)
     'evolution-chamber           (fxior A B T)
     'roach-warren                (fxior A B T)
     'baneling-nest               (fxior A B T)
     'hydralisk-den               (fxior A B T)
     'lurker-den                  (fxior A B T)
     'spire                       (fxior A B T)
     'greater-spire               (fxior A B T)
     'infestation-pit             (fxior A B T)
     'ultralisk-cavern            (fxior A B T)
     'nydus-network               (fxior A B T)
     'nydus-worm                  (fxior A B T)
     'spine-crawler               (fxior A B T)
     'spine-crawler-uprooted      (fxior A B)
     'spore-crawler               (fxior A B T)
     'spore-crawler-uprooted      (fxior A B)
     'creep-tumor                 (fxior L B T)
     'creep-tumor-burrowed        (fxior L B T)
     'creep-tumor-queen           (fxior L B T)
     ;; Terran Units
     'scv                         (fxior L B M)
     'mule                        (fxior L M)
     'marine                      (fxior L B)
     'marauder                    (fxior A B)
     'reaper                      (fxior L B)
     'ghost                       (fxior B P)
     'hellion                     (fxior L M)
     'hellbat                     (fxior L B M)
     'widow-mine                  (fxior L M)
     'widow-mine-burrowed         (fxior L M)
     'cyclone                     (fxior A M)
     'siege-tank                  (fxior A M)
     'siege-tank-sieged           (fxior A M)
     'thor                        (fxior A M X)
     'thor-ap                     (fxior A M X)
     'viking                      (fxior A M)
     'viking-assault              (fxior A M)
     'medivac                     (fxior A M)
     'liberator                   (fxior A M)
     'liberator-ag                (fxior A M)
     'raven                       (fxior L M)
     'banshee                     (fxior L M)
     'battlecruiser               (fxior A M X)
     ;; Terran Structures / Summons
     'auto-turret                 (fxior A M T)
     'point-defense-drone         (fxior A M T)
     'raven-repair-drone          (fxior A M)
     'command-center              (fxior A M T)
     'command-center-flying       (fxior A M T)
     'orbital-command             (fxior A M T)
     'orbital-command-flying      (fxior A M T)
     'planetary-fortress          (fxior A M T)
     'supply-depot                (fxior A M T)
     'supply-depot-lowered        (fxior A M T)
     'refinery                    (fxior A M T)
     'refinery-rich               (fxior A M T)
     'barracks                    (fxior A M T)
     'barracks-flying             (fxior A M T)
     'factory                     (fxior A M T)
     'factory-flying              (fxior A M T)
     'starport                    (fxior A M T)
     'starport-flying             (fxior A M T)
     'engineering-bay             (fxior A M T)
     'armory                      (fxior A M T)
     'bunker                      (fxior A M T)
     'missile-turret              (fxior A M T)
     'sensor-tower                (fxior A M T)
     'ghost-academy               (fxior A M T)
     'fusion-core                 (fxior A M T)
     'tech-lab                    (fxior A M T)
     'reactor                     (fxior A M T)
     'barracks-tech-lab           (fxior A M T)
     'barracks-reactor            (fxior A M T)
     'factory-tech-lab            (fxior A M T)
     'factory-reactor             (fxior A M T)
     'starport-tech-lab           (fxior A M T)
     'starport-reactor            (fxior A M T)
     ;; Protoss Units
     'probe                       (fxior L M S)
     'zealot                      (fxior L B S)
     'stalker                     (fxior A M S)
     'sentry                      (fxior L M P S)
     'adept                       (fxior L B S)
     'high-templar                (fxior L B P S)
     'dark-templar                (fxior L B P S)
     'archon                      (fxior P X S)
     'immortal                    (fxior A M S)
     'colossus                    (fxior A M X S)
     'disruptor                   (fxior A M S)
     'observer                    (fxior L M S)
     'observer-siege-mode         (fxior L M S)
     'warp-prism                  (fxior A M P S)
     'warp-prism-phasing          (fxior A M P S)
     'phoenix                     (fxior L M S)
     'void-ray                    (fxior A M S)
     'oracle                      (fxior A M P S)
     'carrier                     (fxior A M X S)
     'interceptor                 (fxior L M S)
     'tempest                     (fxior A M X S)
     'mothership                  (fxior A M P X S H)
     'mothership-core             (fxior A M P S)
     ;; Protoss Structures
     'nexus                       (fxior A T S)
     'pylon                       (fxior A T S)
     'pylon-overcharged           (fxior A T S)
     'assimilator                 (fxior A T S)
     'assimilator-rich            (fxior A T S)
     'gateway                     (fxior A T S)
     'warp-gate                   (fxior A T S)
     'forge                       (fxior A T S)
     'cybernetics-core            (fxior A T S)
     'photon-cannon               (fxior A T S)
     'shield-battery              (fxior A T S)
     'twilight-council            (fxior A T S)
     'robotics-facility           (fxior A T S)
     'robotics-bay                (fxior A T S)
     'stargate                    (fxior A T S)
     'templar-archive             (fxior A T S)
     'dark-shrine                 (fxior A T S)
     'fleet-beacon                (fxior A T S)
     'oracle-stasis-trap          (fxior L M T S))))

(void fx-attr-or)

(: unit-attribute-mask (-> Any Fixnum))
(define unit-attribute-mask
  (let ([zero-thunk : (-> Fixnum) (lambda () 0)])
    (lambda (unit-type-or-id)
      (define sym (canonical-unit-type-sym unit-type-or-id))
      (if (unbox SC2-LIVE-DATA-ACTIVE?)
          (hash-ref SC2-LIVE-ATTR-OVERLAY sym
                    (lambda () (hash-ref SC2-UNIT-ATTRIBUTE-MASK-TABLE sym zero-thunk)))
          (hash-ref SC2-UNIT-ATTRIBUTE-MASK-TABLE sym zero-thunk)))))

(: sc2-unit-attr-has-any? (-> Any Fixnum Boolean))
(define (sc2-unit-attr-has-any? unit-type-or-id mask)
  (fx> (fxand (unit-attribute-mask unit-type-or-id) mask) 0))

(: SC2-UNIT-COLLISION-RADIUS-TABLE (Immutable-HashTable Symbol Flonum))
(define SC2-UNIT-COLLISION-RADIUS-TABLE
  (hasheq
   ;; 0.25 tiny summons
   'broodling 0.25 'interceptor 0.25
   ;; 0.375 light/worker/ling/bane/marine
   'scv 0.375 'probe 0.375 'drone 0.375 'drone-burrowed 0.375 'mule 0.375
   'zergling 0.375 'zergling-burrowed 0.375
   'baneling 0.375 'baneling-burrowed 0.375
   'marine 0.375 'reaper 0.375 'locust 0.375 'locust-flying 0.375 'larva 0.375
   'changeling 0.375 'changeling-zealot 0.375 'changeling-marine-shield 0.375
   'changeling-marine 0.375 'changeling-zergling-wings 0.375 'changeling-zergling 0.375
   ;; 0.50 medium
   'roach 0.5 'roach-burrowed 0.5 'ravager 0.5 'ravager-burrowed 0.5
   'hydralisk 0.5 'hydralisk-burrowed 0.5
   'marauder 0.5 'ghost 0.5
   'zealot 0.5 'adept 0.5 'sentry 0.5 'high-templar 0.5 'dark-templar 0.5
   'infestor 0.5 'infestor-burrowed 0.5
   'widow-mine 0.5 'widow-mine-burrowed 0.5
   'observer 0.5 'observer-siege-mode 0.5 'oracle-stasis-trap 0.5
   'egg 0.5 'baneling-cocoon 0.5 'ravager-cocoon 0.5 'lurker-egg 0.5 'brood-lord-cocoon 0.5
   ;; 0.625 heavy infantry / medium walkers
   'stalker 0.625 'immortal 0.625 'disruptor 0.625
   'lurker 0.625 'lurker-burrowed 0.625 'queen 0.625 'queen-burrowed 0.625
   ;; 0.75 mechanized / flyers / archon
   'archon 0.75 'siege-tank 0.75 'siege-tank-sieged 0.75 'cyclone 0.75
   'hellion 0.75 'hellbat 0.75 'viking 0.75 'viking-assault 0.75
   'medivac 0.75 'liberator 0.75 'liberator-ag 0.75 'raven 0.75 'banshee 0.75
   'void-ray 0.75 'oracle 0.75 'phoenix 0.75 'mutalisk 0.75 'corruptor 0.75 'viper 0.75
   'overlord 0.75 'overlord-transport 0.75 'overlord-cocoon 0.75 'transport-overlord-cocoon 0.75
   'overseer 0.75 'overseer-siege-mode 0.75
   'warp-prism 0.75 'warp-prism-phasing 0.75 'swarm-host 0.75 'swarm-host-burrowed 0.75
   'auto-turret 0.75
   ;; 0.875 - 1.375 bulky / massive / capitals
   'colossus 0.875 'brood-lord 0.875 'tempest 0.875
   'thor 1.0 'thor-ap 1.0 'ultralisk 1.0 'ultralisk-burrowed 1.0
   'battlecruiser 1.0 'carrier 1.0 'mothership 1.375 'mothership-core 0.875
   ;; Structures
   'supply-depot 1.0 'supply-depot-lowered 1.0 'missile-turret 1.0
   'pylon 1.0 'pylon-overcharged 1.0 'photon-cannon 1.0 'shield-battery 1.0
   'spine-crawler 1.0 'spine-crawler-uprooted 1.0 'spore-crawler 1.0 'spore-crawler-uprooted 1.0
   'spawning-pool 1.5 'evolution-chamber 1.5 'roach-warren 1.5 'baneling-nest 1.5
   'hydralisk-den 1.5 'lurker-den 1.5 'spire 1.0 'greater-spire 1.0 'infestation-pit 1.5
   'ultralisk-cavern 1.5 'nydus-network 1.5 'nydus-worm 1.5 'extractor 1.5 'extractor-rich 1.5
   'barracks 1.5 'factory 1.5 'starport 1.5 'engineering-bay 1.5 'armory 1.5 'bunker 1.5
   'ghost-academy 1.5 'fusion-core 1.5 'refinery 1.5 'refinery-rich 1.5
   'gateway 1.5 'warp-gate 1.5 'forge 1.5 'cybernetics-core 1.5 'twilight-council 1.5
   'robotics-facility 1.5 'robotics-bay 1.5 'stargate 1.5 'templar-archive 1.5
   'dark-shrine 1.5 'fleet-beacon 1.5 'assimilator 1.5 'assimilator-rich 1.5
   'hatchery 2.5 'lair 2.5 'hive 2.5
   'command-center 2.5 'command-center-flying 2.5
   'orbital-command 2.5 'orbital-command-flying 2.5 'planetary-fortress 2.5
   'nexus 2.5))

(: unit-collision-radius (-> Any Flonum))
(define unit-collision-radius
  (let ([default-thunk : (-> Flonum) (lambda () 0.5)])
    (lambda (unit-type-or-id)
      (define sym (canonical-unit-type-sym unit-type-or-id))
      (hash-ref SC2-UNIT-COLLISION-RADIUS-TABLE sym default-thunk))))

(: aoe-radius-packing-multiplier (-> Any Any Flonum))
(define (aoe-radius-packing-multiplier target-radius aoe-radius)
  (define raw-r : Flonum (if (real? target-radius) (->float target-radius) 0.5))
  (define raw-a : Flonum (if (real? aoe-radius) (->float aoe-radius) 1.5))
  (define r (flmax 0.25 (if (and (fl> raw-r -inf.0) (fl< raw-r +inf.0)) raw-r 0.5)))
  (define a (flmax 0.5 (if (and (fl> raw-a -inf.0) (fl< raw-a +inf.0)) raw-a 1.5)))
  (define ratio (fl/ 0.5 r))
  (define inv-r (fl* ratio (flsqrt ratio)))
  (define fit (fl* 1.3333333333333333 (fl/ a (fl+ a r))))
  (flmin 2.5 (flmax 0.25 (fl* inv-r fit))))

(: SC2-UNIT-PRIMARY-BONUS-ATTR-TABLE (Immutable-HashTable Symbol Fixnum))
(define SC2-UNIT-PRIMARY-BONUS-ATTR-TABLE
  (let ([L SC2-UNIT-ATTR-LIGHT]
        [A SC2-UNIT-ATTR-ARMORED]
        [B SC2-UNIT-ATTR-BIOLOGICAL]
        [M SC2-UNIT-ATTR-MECHANICAL]
        [X SC2-UNIT-ATTR-MASSIVE])
    (hasheq
     'immortal          A
     'marauder          A
     'stalker           A
     'lurker            A
     'lurker-burrowed   A
     'void-ray          A
     'siege-tank        A
     'siege-tank-sieged A
     'spine-crawler     A
     'viking            A
     'viking-assault    M
     'colossus          L
     'hellbat           L
     'hellion           L
     'adept             L
     'oracle            L
     'phoenix           L
     'baneling          L
     'baneling-burrowed L
     'ghost             L
     'archon            B
     'spore-crawler     B
     'thor              (fxior L X)
     'thor-ap           X
     'tempest           X
     'corruptor         X)))

(: unit-primary-bonus-attr-mask (-> Any Fixnum))
(define unit-primary-bonus-attr-mask
  (let ([zero-thunk : (-> Fixnum) (lambda () 0)])
    (lambda (attacker-type)
      (define sym (canonical-unit-type-sym attacker-type))
      (hash-ref SC2-UNIT-PRIMARY-BONUS-ATTR-TABLE sym zero-thunk))))

;; Exact LotV Weapon Specs (single weapon profile per domain)
(struct sc2-weapon-spec
  ([hits : Fixnum]
   [base : Flonum]
   [upg-base : Flonum]
   [bonus-mask : Fixnum]
   [bonus : Flonum]
   [upg-bonus : Flonum]
   [period : Flonum]
   [ranged? : Boolean])
  #:transparent)

(: SC2-GROUND-WEAPON-TABLE (Immutable-HashTable Symbol sc2-weapon-spec))
(define SC2-GROUND-WEAPON-TABLE
  (let ([L SC2-UNIT-ATTR-LIGHT]
        [A SC2-UNIT-ATTR-ARMORED]
        [B SC2-UNIT-ATTR-BIOLOGICAL]
        [M SC2-UNIT-ATTR-MECHANICAL])
    (hasheq
     ;; Workers
     'scv               (sc2-weapon-spec 1 5.0  0.0 0 0.0  0.0 1.07  #f)
     'probe             (sc2-weapon-spec 1 5.0  0.0 0 0.0  0.0 1.07  #f)
     'drone             (sc2-weapon-spec 1 5.0  0.0 0 0.0  0.0 1.07  #f)
     ;; Terran Ground
     'marine            (sc2-weapon-spec 1 6.0  1.0 0 0.0  0.0 0.61  #t)
     'marauder          (sc2-weapon-spec 1 10.0 1.0 A 10.0 1.0 1.07  #t)
     'reaper            (sc2-weapon-spec 2 4.0  1.0 0 0.0  0.0 0.79  #t)
     'ghost             (sc2-weapon-spec 1 10.0 1.0 L 10.0 1.0 1.07  #t)
     'hellion           (sc2-weapon-spec 1 8.0  1.0 L 6.0  1.0 1.79  #t)
     'hellbat           (sc2-weapon-spec 1 18.0 2.0 L 12.0 1.0 1.43  #t)
     'widow-mine-burrowed (sc2-weapon-spec 1 125.0 0.0 0 0.0 0.0 29.0 #f)
     'cyclone           (sc2-weapon-spec 1 11.0 1.0 0 0.0  0.0 0.48  #t)
     'siege-tank        (sc2-weapon-spec 1 15.0 2.0 A 10.0 1.0 0.74  #t)
     'siege-tank-sieged (sc2-weapon-spec 1 40.0 4.0 A 30.0 1.0 2.14  #t)
     'thor              (sc2-weapon-spec 2 30.0 3.0 0 0.0  0.0 0.91  #t)
     'thor-ap           (sc2-weapon-spec 2 30.0 3.0 0 0.0  0.0 0.91  #t)
     'viking-assault    (sc2-weapon-spec 1 12.0 1.0 M 8.0  1.0 0.71  #t)
     'liberator-ag      (sc2-weapon-spec 1 75.0 5.0 0 0.0  0.0 1.14  #t)
     'banshee           (sc2-weapon-spec 2 12.0 1.0 0 0.0  0.0 0.89  #t)
     'battlecruiser     (sc2-weapon-spec 1 8.0  1.0 0 0.0  0.0 0.16  #t)
     'auto-turret       (sc2-weapon-spec 1 18.0 0.0 0 0.0  0.0 0.57  #t)
     'bunker            (sc2-weapon-spec 4 6.0  1.0 0 0.0  0.0 0.61  #t)
     'planetary-fortress (sc2-weapon-spec 1 40.0 0.0 0 0.0 0.0 1.43  #t)
     ;; Zerg Ground
     'zergling          (sc2-weapon-spec 1 5.0  1.0 0 0.0  0.0 0.497 #f)
     'baneling          (sc2-weapon-spec 1 16.0 2.0 L 19.0 2.0 1.0   #f)
     'baneling-burrowed (sc2-weapon-spec 1 16.0 2.0 L 19.0 2.0 1.0   #f)
     'roach             (sc2-weapon-spec 1 16.0 2.0 0 0.0  0.0 1.43  #t)
     'ravager           (sc2-weapon-spec 1 16.0 2.0 0 0.0  0.0 1.14  #t)
     'hydralisk         (sc2-weapon-spec 1 12.0 1.0 0 0.0  0.0 0.59  #t)
     'lurker            (sc2-weapon-spec 1 20.0 2.0 A 10.0 1.0 1.43  #t)
     'lurker-burrowed   (sc2-weapon-spec 1 20.0 2.0 A 10.0 1.0 1.43  #t)
     'queen             (sc2-weapon-spec 2 4.0  1.0 0 0.0  0.0 0.71  #t)
     'mutalisk          (sc2-weapon-spec 1 9.0  1.0 0 0.0  0.0 1.09  #t)
     'brood-lord        (sc2-weapon-spec 2 20.0 2.0 0 0.0  0.0 1.79  #t)
     'ultralisk         (sc2-weapon-spec 1 35.0 3.0 0 0.0  0.0 0.61  #f)
     'locust            (sc2-weapon-spec 1 10.0 1.0 0 0.0  0.0 0.43  #t)
     'broodling         (sc2-weapon-spec 1 4.0  1.0 0 0.0  0.0 0.46  #f)
     'spine-crawler     (sc2-weapon-spec 1 25.0 0.0 A 5.0  0.0 1.32  #t)
     ;; Protoss Ground
     'zealot            (sc2-weapon-spec 2 8.0  1.0 0 0.0  0.0 0.86  #f)
     'stalker           (sc2-weapon-spec 1 13.0 1.0 A 5.0  1.0 1.34  #t)
     'sentry            (sc2-weapon-spec 1 6.0  1.0 0 0.0  0.0 0.71  #t)
     'adept             (sc2-weapon-spec 1 10.0 1.0 L 12.0 1.0 1.61  #t)
     'high-templar      (sc2-weapon-spec 1 4.0  1.0 0 0.0  0.0 1.25  #t)
     'dark-templar      (sc2-weapon-spec 1 45.0 5.0 0 0.0  0.0 1.21  #f)
     'archon            (sc2-weapon-spec 1 25.0 3.0 B 10.0 1.0 1.25  #t)
     'immortal          (sc2-weapon-spec 1 20.0 2.0 A 30.0 3.0 1.04  #t)
     'colossus          (sc2-weapon-spec 2 10.0 1.0 L 5.0  1.0 1.07  #t)
     'void-ray          (sc2-weapon-spec 1 6.0  1.0 A 4.0  0.0 0.36  #t)
     'oracle            (sc2-weapon-spec 1 15.0 0.0 L 7.0  0.0 0.61  #t)
     'carrier           (sc2-weapon-spec 8 5.0  1.0 0 0.0  0.0 1.07  #t)
     'interceptor       (sc2-weapon-spec 2 5.0  1.0 0 0.0  0.0 2.14  #t)
     'tempest           (sc2-weapon-spec 1 40.0 4.0 0 0.0  0.0 2.36  #t)
     'mothership        (sc2-weapon-spec 6 6.0  1.0 0 0.0  0.0 1.58  #t)
     'photon-cannon     (sc2-weapon-spec 1 20.0 0.0 0 0.0  0.0 0.89  #t))))

(: SC2-AIR-WEAPON-TABLE (Immutable-HashTable Symbol sc2-weapon-spec))
(define SC2-AIR-WEAPON-TABLE
  (let ([L SC2-UNIT-ATTR-LIGHT]
        [A SC2-UNIT-ATTR-ARMORED]
        [B SC2-UNIT-ATTR-BIOLOGICAL]
        [X SC2-UNIT-ATTR-MASSIVE])
    (hasheq
     ;; Terran Air
     'marine            (sc2-weapon-spec 1 6.0  1.0 0 0.0  0.0 0.61 #t)
     'ghost             (sc2-weapon-spec 1 10.0 1.0 L 10.0 1.0 1.07 #t)
     'widow-mine-burrowed (sc2-weapon-spec 1 125.0 0.0 0 0.0 0.0 29.0 #f)
     'cyclone           (sc2-weapon-spec 1 11.0 1.0 0 0.0  0.0 0.48 #t)
     'thor              (sc2-weapon-spec 4 6.0  1.0 L 6.0  1.0 2.14 #t)
     'thor-ap           (sc2-weapon-spec 1 25.0 3.0 X 15.0 1.0 0.91 #t)
     'viking            (sc2-weapon-spec 2 10.0 1.0 A 4.0  0.0 1.43 #t)
     'liberator         (sc2-weapon-spec 2 5.0  1.0 0 0.0  0.0 1.29 #t)
     'battlecruiser     (sc2-weapon-spec 1 5.0  1.0 0 0.0  0.0 0.16 #t)
     'auto-turret       (sc2-weapon-spec 1 18.0 0.0 0 0.0  0.0 0.57 #t)
     'missile-turret    (sc2-weapon-spec 2 12.0 0.0 0 0.0  0.0 0.61 #t)
     'bunker            (sc2-weapon-spec 4 6.0  1.0 0 0.0  0.0 0.61 #t)
     ;; Zerg Air
     'hydralisk         (sc2-weapon-spec 1 12.0 1.0 0 0.0  0.0 0.59 #t)
     'queen             (sc2-weapon-spec 1 9.0  1.0 0 0.0  0.0 0.71 #t)
     'mutalisk          (sc2-weapon-spec 1 9.0  1.0 0 0.0  0.0 1.09 #t)
     'corruptor         (sc2-weapon-spec 1 14.0 1.0 X 6.0  1.0 1.36 #t)
     'spore-crawler     (sc2-weapon-spec 1 15.0 0.0 B 15.0 0.0 0.61 #t)
     ;; Protoss Air
     'stalker           (sc2-weapon-spec 1 13.0 1.0 A 5.0  1.0 1.34 #t)
     'sentry            (sc2-weapon-spec 1 6.0  1.0 0 0.0  0.0 0.71 #t)
     'archon            (sc2-weapon-spec 1 25.0 3.0 B 10.0 1.0 1.25 #t)
     'phoenix           (sc2-weapon-spec 2 5.0  1.0 L 5.0  0.0 0.79 #t)
     'void-ray          (sc2-weapon-spec 1 6.0  1.0 A 4.0  0.0 0.36 #t)
     'carrier           (sc2-weapon-spec 8 5.0  1.0 0 0.0  0.0 1.07 #t)
     'interceptor       (sc2-weapon-spec 2 5.0  1.0 0 0.0  0.0 2.14 #t)
     'tempest           (sc2-weapon-spec 1 30.0 3.0 X 22.0 2.0 2.36 #t)
     'mothership        (sc2-weapon-spec 6 6.0  1.0 0 0.0  0.0 1.58 #t)
     'photon-cannon     (sc2-weapon-spec 1 20.0 0.0 0 0.0  0.0 0.89 #t))))

(: SC2-UNIT-HULL-ARMOR-TABLE (Immutable-HashTable Symbol Flonum))
(define SC2-UNIT-HULL-ARMOR-TABLE
  (for/hasheq : (Immutable-HashTable Symbol Flonum)
              ([(k stats) (in-hash SC2-UNIT-COMBAT-STATS-TABLE)])
    (define raw (hash-ref stats 'armor (lambda () 0)))
    (values k (if (real? raw) (->float raw) 0.0))))

(: sc2-ground-weapon (-> Any (Option sc2-weapon-spec)))
(define sc2-ground-weapon
  (let ([false-thunk : (-> False) (lambda () #f)])
    (lambda (unit-type-or-id)
      (define sym (canonical-unit-type-sym unit-type-or-id))
      (or (and (unbox SC2-LIVE-DATA-ACTIVE?)
               (hash-ref SC2-LIVE-GROUND-WPN-OVERLAY sym false-thunk))
          (hash-ref SC2-GROUND-WEAPON-TABLE sym false-thunk)))))

(: sc2-air-weapon (-> Any (Option sc2-weapon-spec)))
(define sc2-air-weapon
  (let ([false-thunk : (-> False) (lambda () #f)])
    (lambda (unit-type-or-id)
      (define sym (canonical-unit-type-sym unit-type-or-id))
      (or (and (unbox SC2-LIVE-DATA-ACTIVE?)
               (hash-ref SC2-LIVE-AIR-WPN-OVERLAY sym false-thunk))
          (hash-ref SC2-AIR-WEAPON-TABLE sym false-thunk)))))

(: select-weapon-spec-for-target (-> Symbol Symbol Boolean (Option sc2-weapon-spec)))
(define select-weapon-spec-for-target
  (lambda (atk-sym tgt-sym tgt-flying?)
    (cond
      [tgt-flying?
       (sc2-air-weapon atk-sym)]
      [(eq? tgt-sym 'colossus)
       (or (sc2-ground-weapon atk-sym)
           (sc2-air-weapon atk-sym))]
      [else
       (sc2-ground-weapon atk-sym)])))

(: SC2-BANELING-STRUCT-WEAPON sc2-weapon-spec)
(define SC2-BANELING-STRUCT-WEAPON
  (sc2-weapon-spec 1 80.0 5.0 0 0.0 0.0 1.0 #f))

(: nonneg-fl (-> Any Flonum Flonum))
(define (nonneg-fl v default)
  (if (real? v)
      (let ([fv : Flonum (->float v)])
        (if (and (fl> fv -inf.0) (fl< fv +inf.0))
            (flmax 0.0 fv)
            default))
      default))

(: resolve-weapon-spec-and-hull (-> Any Any (Values (Option sc2-weapon-spec) Fixnum Flonum)))
(define resolve-weapon-spec-and-hull
  (let ([zero-fl-thunk : (-> Flonum) (lambda () 0.0)])
    (lambda (attacker-type target-type)
      (define atk-sym (canonical-unit-type-sym attacker-type))
      (define tgt-sym (canonical-unit-type-sym target-type))
      (define tmask (unit-attribute-mask tgt-sym))
      (define flying? (sc2-unit-is-flying-sym? tgt-sym))
      (define hull-base
        (if (unbox SC2-LIVE-DATA-ACTIVE?)
            (hash-ref SC2-LIVE-ARMOR-OVERLAY tgt-sym
                      (lambda () (hash-ref SC2-UNIT-HULL-ARMOR-TABLE tgt-sym zero-fl-thunk)))
            (hash-ref SC2-UNIT-HULL-ARMOR-TABLE tgt-sym zero-fl-thunk)))
      (define spec
        (if (and (eq? atk-sym 'baneling)
                 (fx> (fxand tmask SC2-UNIT-ATTR-STRUCTURE) 0))
            SC2-BANELING-STRUCT-WEAPON
            (select-weapon-spec-for-target atk-sym tgt-sym flying?)))
      (values spec tmask hull-base))))

(: compute-exact-weapon-per-volley
   (-> sc2-weapon-spec Fixnum Flonum Flonum Flonum Flonum Boolean Boolean
       (Values Flonum Flonum Flonum)))
(define (compute-exact-weapon-per-volley spec tmask hull-base upgs-f aupg-f supg-f aam? gs?)
  (define hits-f : Flonum (->float (sc2-weapon-spec-hits spec)))
  (define bonus-match? (fx> (fxand (sc2-weapon-spec-bonus-mask spec) tmask) 0))
  (define raw-hit
    (fl+ (fl+ (sc2-weapon-spec-base spec)
              (fl* upgs-f (sc2-weapon-spec-upg-base spec)))
         (if bonus-match?
             (fl+ (sc2-weapon-spec-bonus spec)
                  (fl* upgs-f (sc2-weapon-spec-upg-bonus spec)))
             0.0)))
  (define gs-red (if (and gs? (sc2-weapon-spec-ranged? spec)) 2.0 0.0))
  (define aam-delta (if aam? -2.0 0.0))
  (define shield-armor (fl+ supg-f aam-delta))
  (define hull-armor (fl+ hull-base (fl+ aupg-f aam-delta)))
  (define per-hit-shield (flmax 0.5 (fl- (fl- raw-hit shield-armor) gs-red)))
  (define per-hit-hull (flmax 0.5 (fl- (fl- raw-hit hull-armor) gs-red)))
  (values (fl* hits-f per-hit-shield)
          (fl* hits-f per-hit-hull)
          (sc2-weapon-spec-period spec)))

(: compute-exact-hit-damage-vs-target/fast
   (-> Any Any Real Real Real Real Real Any Any Any Flonum))
(define (compute-exact-hit-damage-vs-target/fast
         attacker-type target-type upgs aupg supg sh hp barrier? aam? gs?)
  (define-values (spec tmask hull-base)
    (resolve-weapon-spec-and-hull attacker-type target-type))
  (cond
    [(not spec) 0.0]
    [else
     (define upgs-f (nonneg-fl upgs 0.0))
     (define aupg-f (nonneg-fl aupg 0.0))
     (define supg-f (nonneg-fl supg 0.0))
     (define sh-f (nonneg-fl sh 0.0))
     (define hp-f (nonneg-fl hp 100.0))
     (define-values (v-shield v-hull _period)
       (compute-exact-weapon-per-volley spec tmask hull-base upgs-f aupg-f supg-f
                                        (and aam? #t) (and gs? #t)))
     (define raw-volley
       (cond
         [(fl<= sh-f 0.0) v-hull]
         [(fl<= v-shield sh-f) v-shield]
         [else
          (define sh-frac (fl/ sh-f (flmax 0.5 v-shield)))
          (fl+ sh-f (fl* (fl- 1.0 sh-frac) v-hull))]))
     (if barrier?
         (let ([ehp (flmax 1.0 (fl+ sh-f hp-f))])
           (fl* raw-volley (fl/ ehp (fl+ ehp 100.0))))
         raw-volley)]))

(: compute-exact-hit-damage-vs-target
   (->* (Any Any)
        (#:attacker-upgrades Any
         #:target-armor-upg Any
         #:target-shield-upg Any
         #:target-shields Any
         #:target-hp Any
         #:barrier-active? Any
         #:aam-debuff? Any
         #:guardian-shield? Any)
        Flonum))
(define (compute-exact-hit-damage-vs-target attacker-type target-type
                                            #:attacker-upgrades [upgs 0]
                                            #:target-armor-upg [aupg 0]
                                            #:target-shield-upg [supg 0]
                                            #:target-shields [sh 0]
                                            #:target-hp [hp 100]
                                            #:barrier-active? [barrier? #f]
                                            #:aam-debuff? [aam? #f]
                                            #:guardian-shield? [gs? #f])
  (compute-exact-hit-damage-vs-target/fast
   attacker-type target-type
   (nonneg-fl upgs 0.0)
   (nonneg-fl aupg 0.0)
   (nonneg-fl supg 0.0)
   (nonneg-fl sh 0.0)
   (nonneg-fl hp 100.0)
   barrier? aam? gs?))

(: compute-exact-weapon-dps-vs-target
   (->* (Any Any)
        (#:attacker-upgrades Any
         #:target-armor-upg Any
         #:target-shield-upg Any
         #:target-shields Any
         #:target-hp Any
         #:barrier-active? Any
         #:aam-debuff? Any
         #:guardian-shield? Any)
        Flonum))
(define (compute-exact-weapon-dps-vs-target attacker-type target-type
                                            #:attacker-upgrades [upgs 0]
                                            #:target-armor-upg [aupg 0]
                                            #:target-shield-upg [supg 0]
                                            #:target-shields [sh 0]
                                            #:target-hp [hp 100]
                                            #:barrier-active? [barrier? #f]
                                            #:aam-debuff? [aam? #f]
                                            #:guardian-shield? [gs? #f])
  (define-values (spec tmask hull-base)
    (resolve-weapon-spec-and-hull attacker-type target-type))
  (cond
    [(not spec) 0.0]
    [else
     (define upgs-f (nonneg-fl upgs 0.0))
     (define aupg-f (nonneg-fl aupg 0.0))
     (define supg-f (nonneg-fl supg 0.0))
     (define sh-f (nonneg-fl sh 0.0))
     (define hp-f (nonneg-fl hp 100.0))
     (define-values (v-shield v-hull period)
       (compute-exact-weapon-per-volley spec tmask hull-base upgs-f aupg-f supg-f
                                        (and aam? #t) (and gs? #t)))
     (define dps-shield (fl/ v-shield period))
     (define dps-hull (fl/ v-hull period))
     (define total-ehp (fl+ sh-f hp-f))
     (define shield-phase (fl+ sh-f (if barrier? 100.0 0.0)))
     (cond
       [(fl<= total-ehp 0.0)
        (if (fl> shield-phase 0.0) dps-shield dps-hull)]
       [else
        (define ttk
          (fl+ (if (fl> shield-phase 0.0) (fl/ shield-phase dps-shield) 0.0)
               (if (fl> hp-f 0.0) (fl/ hp-f dps-hull) 0.0)))
        (fl/ total-ehp (flmax 1e-6 ttk))])]))

(: spell-valid-for-target-attrs? (->* (Any Any) (Any Any) Boolean))
(define (spell-valid-for-target-attrs? spell-sym target-type [target-energy 0] [target-shields 0])
  (define mask (unit-attribute-mask target-type))
  (define e-val (nonneg-fl target-energy 0.0))
  (define s-val (nonneg-fl target-shields 0.0))
  (define bio? (fx> (fxand mask SC2-UNIT-ATTR-BIOLOGICAL) 0))
  (define mech? (fx> (fxand mask SC2-UNIT-ATTR-MECHANICAL) 0))
  (define psi? (fx> (fxand mask SC2-UNIT-ATTR-PSIONIC) 0))
  (define frenzied? (fx> (fxand mask SC2-UNIT-ATTR-FRENZIED) 0))
  (define struct? (fx> (fxand mask SC2-UNIT-ATTR-STRUCTURE) 0))
  (define heroic? (fx> (fxand mask SC2-UNIT-ATTR-HEROIC) 0))
  (case spell-sym
    [(snipe steady-targeting)
     (and bio? (not struct?))]
    [(emp emp-round)
     (or (fl> s-val 0.0) psi? (fl> e-val 0.0))]
    [(feedback)
     (and (not struct?) (fl>= e-val 50.0))]
    [(interference-matrix)
     (and (or mech? psi?) (not frenzied?) (not struct?))]
    [(neural-parasite)
     (and (fx> mask 0) (not frenzied?) (not struct?) (not heroic?))]
    [(abduct)
     (and (fx> mask 0) (not frenzied?) (not struct?) (not heroic?))]
    [(repair)
     mech?]
    [(transfuse transfusion)
     bio?]
    [(heal)
     (and bio? (not struct?))]
    [else
     (fx> mask 0)]))

;; -----------------------------------------------------------------------------
;; 13. Loop 60 Phase 0: Live Frame-0 `ResponseData` Overlay Store & Query API
;; -----------------------------------------------------------------------------
;; Populated once at match start by `register-sc2-response-data!` in
;; `lib/sc2-protobuf-ws.rkt` using flat primitive arguments (zero Typed/Untyped
;; chaperone overhead). Cleared cleanly by `reset-sc2-live-game-data!` between
;; matches and tests so offline unit tests always fall back to static `5.0.14`
;; defaults when `SC2-LIVE-DATA-ACTIVE?` is `#f`.

(define SC2-LIVE-DATA-ACTIVE?        : (Boxof Boolean) (box #f))
(define SC2-LIVE-COST-OVERLAY        : (Mutable-HashTable Symbol (List Integer Integer Integer)) (make-hasheq))
(define SC2-LIVE-RAW-COST-OVERLAY    : (Mutable-HashTable Symbol (List Integer Integer Real))    (make-hasheq))
(define SC2-LIVE-ATTR-OVERLAY        : (Mutable-HashTable Symbol Fixnum)  (make-hasheq))
(define SC2-LIVE-TECHLAB-OVERLAY     : (Mutable-HashTable Symbol Boolean) (make-hasheq))
(define SC2-LIVE-BUILD-TIME-OVERLAY  : (Mutable-HashTable Symbol Integer) (make-hasheq))
(define SC2-LIVE-RANGE-OVERLAY       : (Mutable-HashTable Symbol (Pairof Flonum Flonum)) (make-hasheq))
(define SC2-LIVE-SPEED-OVERLAY       : (Mutable-HashTable Symbol Flonum)  (make-hasheq))
(define SC2-LIVE-ARMOR-OVERLAY       : (Mutable-HashTable Symbol Flonum)  (make-hasheq))
(define SC2-LIVE-GROUND-WPN-OVERLAY  : (Mutable-HashTable Symbol sc2-weapon-spec) (make-hasheq))
(define SC2-LIVE-AIR-WPN-OVERLAY     : (Mutable-HashTable Symbol sc2-weapon-spec) (make-hasheq))
(define SC2-LIVE-COMBAT-STATS-CACHE  : (Mutable-HashTable Symbol CombatStatTable) (make-hasheq))
(define SC2-LIVE-ABIL-CAST-RANGE     : (Mutable-HashTable Integer Flonum) (make-hasheqv))
(define SC2-LIVE-ABIL-TARGET-MODE    : (Mutable-HashTable Integer Symbol) (make-hasheqv))
(define SC2-LIVE-ABIL-AUTOCAST       : (Mutable-HashTable Integer Boolean) (make-hasheqv))
(define SC2-LIVE-ABIL-REMAP          : (Mutable-HashTable Integer Integer) (make-hasheqv))
(define SC2-LIVE-UPG-COST-OVERLAY    : (Mutable-HashTable Symbol (List Integer Integer Integer)) (make-hasheq))
(define SC2-LIVE-UPG-ABIL-OVERLAY    : (Mutable-HashTable Symbol Integer) (make-hasheq))
(define SC2-LIVE-EFFECT-RADIUS       : (Mutable-HashTable Symbol Flonum)  (make-hasheq))

;; Base-cost subtraction map for SC2 `UnitTypeData` cumulative morph/drone costs:
;; - Zerg structures include the consumed Drone (`50M / 0G`, keeping `supply = 0`)
;; - Upgraded structures include their predecessor structure (`supply = 0`)
;; - Morphed units include their source unit (`min`, `gas`, & `supply`)
(define SC2-ZERG-DRONE-CONSUMED-STRUCTS : (Listof Symbol)
  '(hatchery spawning-pool extractor extractor-rich roach-warren baneling-nest
    evolution-chamber hydralisk-den lurker-den lurker-den-mp spire infestation-pit
    ultralisk-cavern spine-crawler spore-crawler nydus-network))

(define SC2-UPGRADED-ZERO-SUPPLY-STRUCTS : (Immutable-HashTable Symbol Symbol)
  (hasheq
   'lair                'hatchery
   'hive                'lair
   'greater-spire       'spire
   'orbital-command     'command-center
   'planetary-fortress  'command-center))

(define SC2-UNIT-MORPH-BASE-MAP : (Immutable-HashTable Symbol (U Symbol (List Integer Integer Real)))
  (let ([ht : (Mutable-HashTable Symbol (U Symbol (List Integer Integer Real))) (make-hasheq)])
    (for ([s (in-list SC2-ZERG-DRONE-CONSUMED-STRUCTS)])
      (hash-set! ht s 'drone))
    (for ([(s base) (in-hash SC2-UPGRADED-ZERO-SUPPLY-STRUCTS)])
      (hash-set! ht s base))
    (hash-set! ht 'ravager    'roach)
    (hash-set! ht 'lurker     'hydralisk)
    (hash-set! ht 'lurker-mp  'hydralisk)
    (hash-set! ht 'brood-lord 'corruptor)
    (hash-set! ht 'overseer   'overlord)
    (hash-set! ht 'baneling   '(25 0 0.5))
    (for/hasheq : (Immutable-HashTable Symbol (U Symbol (List Integer Integer Real)))
                ([(k v) (in-hash ht)])
      (values k v))))

(: reset-sc2-live-game-data! (-> Void))
(define (reset-sc2-live-game-data!)
  (set-box! SC2-LIVE-DATA-ACTIVE? #f)
  (hash-clear! SC2-LIVE-COST-OVERLAY)
  (hash-clear! SC2-LIVE-RAW-COST-OVERLAY)
  (hash-clear! SC2-LIVE-ATTR-OVERLAY)
  (hash-clear! SC2-LIVE-TECHLAB-OVERLAY)
  (hash-clear! SC2-LIVE-BUILD-TIME-OVERLAY)
  (hash-clear! SC2-LIVE-RANGE-OVERLAY)
  (hash-clear! SC2-LIVE-SPEED-OVERLAY)
  (hash-clear! SC2-LIVE-ARMOR-OVERLAY)
  (hash-clear! SC2-LIVE-GROUND-WPN-OVERLAY)
  (hash-clear! SC2-LIVE-AIR-WPN-OVERLAY)
  (hash-clear! SC2-LIVE-COMBAT-STATS-CACHE)
  (hash-clear! SC2-LIVE-ABIL-CAST-RANGE)
  (hash-clear! SC2-LIVE-ABIL-TARGET-MODE)
  (hash-clear! SC2-LIVE-ABIL-AUTOCAST)
  (hash-clear! SC2-LIVE-ABIL-REMAP)
  (hash-clear! SC2-LIVE-UPG-COST-OVERLAY)
  (hash-clear! SC2-LIVE-UPG-ABIL-OVERLAY)
  (hash-clear! SC2-LIVE-EFFECT-RADIUS))

(: register-sc2-live-unit-data!
   (-> Symbol Integer Integer Real Integer Fixnum Boolean Flonum Flonum Flonum Flonum
       (Option sc2-weapon-spec) (Option sc2-weapon-spec) Void))
(define (register-sc2-live-unit-data!
         raw-sym min-cost gas-cost food-req build-frames attr-mask require-attached?
         speed armor ground-range air-range ground-wpn air-wpn)
  (set-box! SC2-LIVE-DATA-ACTIVE? #t)
  (define canon (canonical-unit-type-sym raw-sym))
  (hash-set! SC2-LIVE-RAW-COST-OVERLAY canon (list min-cost gas-cost food-req))
  (unless (eq? raw-sym canon)
    (hash-set! SC2-LIVE-RAW-COST-OVERLAY raw-sym (list min-cost gas-cost food-req)))
  (when (fx> attr-mask 0)
    (define static-mask (hash-ref SC2-UNIT-ATTRIBUTE-MASK-TABLE canon (lambda () 0)))
    (define preserved-synth
      (fxand static-mask (fxior SC2-UNIT-ATTR-SHIELDED SC2-UNIT-ATTR-FRENZIED)))
    (define eff-mask (fxior attr-mask preserved-synth))
    (hash-set! SC2-LIVE-ATTR-OVERLAY canon eff-mask)
    (unless (eq? raw-sym canon)
      (hash-set! SC2-LIVE-ATTR-OVERLAY raw-sym eff-mask)))
  (hash-set! SC2-LIVE-TECHLAB-OVERLAY canon require-attached?)
  (unless (eq? raw-sym canon)
    (hash-set! SC2-LIVE-TECHLAB-OVERLAY raw-sym require-attached?))
  (when (> build-frames 0)
    (hash-set! SC2-LIVE-BUILD-TIME-OVERLAY canon build-frames)
    (unless (eq? raw-sym canon)
      (hash-set! SC2-LIVE-BUILD-TIME-OVERLAY raw-sym build-frames)))
  (when (or (fl> ground-range 0.0) (fl> air-range 0.0))
    (define rng-pair (cons ground-range air-range))
    (hash-set! SC2-LIVE-RANGE-OVERLAY canon rng-pair)
    (unless (eq? raw-sym canon)
      (hash-set! SC2-LIVE-RANGE-OVERLAY raw-sym rng-pair)))
  (when (fl> speed 0.0)
    (hash-set! SC2-LIVE-SPEED-OVERLAY canon speed)
    (unless (eq? raw-sym canon)
      (hash-set! SC2-LIVE-SPEED-OVERLAY raw-sym speed)))
  (when (fl>= armor 0.0)
    (hash-set! SC2-LIVE-ARMOR-OVERLAY canon armor)
    (unless (eq? raw-sym canon)
      (hash-set! SC2-LIVE-ARMOR-OVERLAY raw-sym armor)))
  (when ground-wpn
    (hash-set! SC2-LIVE-GROUND-WPN-OVERLAY canon ground-wpn)
    (unless (eq? raw-sym canon)
      (hash-set! SC2-LIVE-GROUND-WPN-OVERLAY raw-sym ground-wpn)))
  (when air-wpn
    (hash-set! SC2-LIVE-AIR-WPN-OVERLAY canon air-wpn)
    (unless (eq? raw-sym canon)
      (hash-set! SC2-LIVE-AIR-WPN-OVERLAY raw-sym air-wpn)))
  (hash-remove! SC2-LIVE-COMBAT-STATS-CACHE canon)
  (hash-remove! SC2-LIVE-COMBAT-STATS-CACHE raw-sym))

(: lookup-raw-or-static-base-cost (-> Symbol (List Integer Integer Real)))
(define (lookup-raw-or-static-base-cost base-sym)
  (or (hash-ref SC2-LIVE-RAW-COST-OVERLAY base-sym (lambda () #f))
      (let ([st (hash-ref SC2-LOTV-COST-TABLE base-sym (lambda () #f))])
        (if st
            (list (first st) (second st) (third st))
            '(0 0 0)))))

(: finalize-sc2-live-unit-costs! (-> Void))
(define (finalize-sc2-live-unit-costs!)
  (hash-clear! SC2-LIVE-COST-OVERLAY)
  (for ([(sym raw-triple) (in-hash SC2-LIVE-RAW-COST-OVERLAY)])
    (define raw-min (first raw-triple))
    (define raw-gas (second raw-triple))
    (define raw-food (third raw-triple))
    (define static-entry (hash-ref SC2-LOTV-COST-TABLE sym (lambda () #f)))
    (cond
      ;; Special-case Zergling pair trained from 1 Larva (50M / 0G / 1 supply)
      [(eq? sym 'zergling)
       (define eff-min (if (and (= raw-min 25) (= raw-food 0.5)) 50 raw-min))
       (define eff-gas (if (and (= raw-min 25) (= raw-food 0.5)) (* 2 raw-gas) raw-gas))
       (define eff-sup (if (= raw-food 0.5) 1 (max 0 (exact-round raw-food))))
       (hash-set! SC2-LIVE-COST-OVERLAY sym (list eff-min eff-gas eff-sup))]
      ;; Guard against zero-cost UnitTypeData entries (e.g. Archon 0/0/4, cocoons) clobbering static costs
      [(and (= raw-min 0) (= raw-gas 0)
            static-entry
            (or (> (first static-entry) 0) (> (second static-entry) 0)))
       (when (> raw-food 0)
         (hash-set! SC2-LIVE-COST-OVERLAY sym
                    (list (first static-entry) (second static-entry) (max 0 (exact-round raw-food)))))]
      [else
       (define morph-base (hash-ref SC2-UNIT-MORPH-BASE-MAP sym (lambda () #f)))
       (cond
         [(not morph-base)
          (hash-set! SC2-LIVE-COST-OVERLAY sym
                     (list (max 0 raw-min)
                           (max 0 raw-gas)
                           (max 0 (exact-round raw-food))))]
         [(symbol? morph-base)
          (define base-cost (lookup-raw-or-static-base-cost morph-base))
          (define struct-zero-sup?
            (or (and (memq sym SC2-ZERG-DRONE-CONSUMED-STRUCTS) #t)
                (hash-has-key? SC2-UPGRADED-ZERO-SUPPLY-STRUCTS sym)))
          (define inc-min (max 0 (- raw-min (first base-cost))))
          (define inc-gas (max 0 (- raw-gas (second base-cost))))
          (define inc-sup
            (if struct-zero-sup?
                0
                (max 0 (exact-round (- raw-food (third base-cost))))))
          (hash-set! SC2-LIVE-COST-OVERLAY sym (list inc-min inc-gas inc-sup))]
         [else
          (define inc-min (max 0 (- raw-min (first morph-base))))
          (define inc-gas (max 0 (- raw-gas (second morph-base))))
          (define inc-sup (max 0 (exact-round (- raw-food (third morph-base)))))
          (hash-set! SC2-LIVE-COST-OVERLAY sym (list inc-min inc-gas inc-sup))])])))

(: register-sc2-live-ability-data! (-> Integer Symbol Flonum Boolean Integer Void))
(define (register-sc2-live-ability-data! ab-id target-sym cast-range allow-autocast? remaps-to)
  (when (> ab-id 0)
    (set-box! SC2-LIVE-DATA-ACTIVE? #t)
    (unless (eq? target-sym 'unknown)
      (hash-set! SC2-LIVE-ABIL-TARGET-MODE ab-id target-sym))
    (when (fl> cast-range 0.0)
      (hash-set! SC2-LIVE-ABIL-CAST-RANGE ab-id cast-range))
    (hash-set! SC2-LIVE-ABIL-AUTOCAST ab-id allow-autocast?)
    (when (> remaps-to 0)
      (hash-set! SC2-LIVE-ABIL-REMAP ab-id remaps-to))))

(: register-sc2-live-upgrade-data! (-> Symbol Integer Integer Integer Integer Void))
(define (register-sc2-live-upgrade-data! upg-sym min-cost gas-cost research-frames ab-id)
  (set-box! SC2-LIVE-DATA-ACTIVE? #t)
  (when (or (> min-cost 0) (> gas-cost 0) (> research-frames 0))
    (hash-set! SC2-LIVE-UPG-COST-OVERLAY upg-sym
               (list (max 0 min-cost) (max 0 gas-cost) (max 0 research-frames))))
  (when (> ab-id 0)
    (hash-set! SC2-LIVE-UPG-ABIL-OVERLAY upg-sym ab-id)))

(: register-sc2-live-effect-data! (-> Symbol Flonum Void))
(define (register-sc2-live-effect-data! eff-sym radius)
  (when (fl> radius 0.0)
    (set-box! SC2-LIVE-DATA-ACTIVE? #t)
    (hash-set! SC2-LIVE-EFFECT-RADIUS eff-sym radius)))

(: sc2-ability-cast-range (->* (Integer) (Flonum) Flonum))
(define (sc2-ability-cast-range ab-id [default 0.0])
  (if (unbox SC2-LIVE-DATA-ACTIVE?)
      (hash-ref SC2-LIVE-ABIL-CAST-RANGE ab-id (lambda () default))
      default))

(: sc2-ability-live-target-mode (-> Integer (Option Symbol)))
(define (sc2-ability-live-target-mode ab-id)
  (and (unbox SC2-LIVE-DATA-ACTIVE?)
       (hash-ref SC2-LIVE-ABIL-TARGET-MODE ab-id (lambda () #f))))

(: sc2-ability-live-autocast? (-> Integer Boolean))
(define (sc2-ability-live-autocast? ab-id)
  (and (unbox SC2-LIVE-DATA-ACTIVE?)
       (hash-ref SC2-LIVE-ABIL-AUTOCAST ab-id (lambda () #f))))

(: sc2-ability-live-remap (-> Integer (Option Integer)))
(define (sc2-ability-live-remap ab-id)
  (and (unbox SC2-LIVE-DATA-ACTIVE?)
       (hash-ref SC2-LIVE-ABIL-REMAP ab-id (lambda () #f))))

(: sc2-live-effect-radius (->* (Symbol) (Flonum) Flonum))
(define (sc2-live-effect-radius eff-sym [default 0.0])
  (if (unbox SC2-LIVE-DATA-ACTIVE?)
      (hash-ref SC2-LIVE-EFFECT-RADIUS eff-sym (lambda () default))
      default))

(: sc2-unit-build-frames (->* (Symbol) (Integer) Integer))
(define (sc2-unit-build-frames sym [default 0])
  (if (unbox SC2-LIVE-DATA-ACTIVE?)
      (let ([canon (canonical-unit-type-sym sym)])
        (hash-ref SC2-LIVE-BUILD-TIME-OVERLAY sym
                  (lambda ()
                    (hash-ref SC2-LIVE-BUILD-TIME-OVERLAY canon (lambda () default)))))
      default))

(: sc2-upgrade-research-ability-id (-> Symbol (Option Integer)))
(define (sc2-upgrade-research-ability-id upg-sym)
  (and (unbox SC2-LIVE-DATA-ACTIVE?)
       (hash-ref SC2-LIVE-UPG-ABIL-OVERLAY upg-sym (lambda () #f))))

;; =============================================================================
;; 11. Loop 61 Phase 1: Single-Source Total-Value, On-Field Supply, & Spell Spec
;; =============================================================================

(: zerg-drone-consumed-ancestor? (-> Symbol Boolean))
(define (zerg-drone-consumed-ancestor? s)
  (let loop ([cur : Symbol s] [depth : Integer 0])
    (cond
      [(> depth 6) #f]
      [(memq cur SC2-ZERG-DRONE-CONSUMED-STRUCTS) #t]
      [else
       (define parent (hash-ref SC2-UPGRADED-ZERO-SUPPLY-STRUCTS cur (lambda () #f)))
       (if parent (loop parent (+ depth 1)) #f)])))

(: static-unit-morph-base-for-total (-> Symbol (Option (U Symbol (List Integer Integer Real)))))
(define (static-unit-morph-base-for-total canon)
  (or (hash-ref SC2-UNIT-MORPH-BASE-MAP canon (lambda () #f))
      (case canon
        [(orbital-command-flying) 'command-center]
        [(overseer-siege-mode overlord-cocoon overlord-transport transport-overlord-cocoon) 'overlord]
        [(baneling-cocoon) '(25 0 0.5)]
        [(ravager-cocoon) 'roach]
        [(lurker-egg lurker-mp-egg) 'hydralisk]
        [(brood-lord-cocoon) 'corruptor]
        [else #f])))

(: static-unit-on-field-supply-opt (-> Symbol Integer (Option Flonum)))
(define (static-unit-on-field-supply-opt raw-sym depth)
  (define canon (canonical-unit-type-sym raw-sym))
  (cond
    [(> depth 6) #f]
    [(memq canon '(zergling zergling-burrowed baneling baneling-burrowed baneling-cocoon)) 0.5]
    [(eq? canon 'archon) 4.0]
    [(eq? canon 'mothership) 8.0]
    [(or (memq canon SC2-ZERG-DRONE-CONSUMED-STRUCTS)
         (hash-has-key? SC2-UPGRADED-ZERO-SUPPLY-STRUCTS canon))
     0.0]
    [else
     (define entry
       (or (hash-ref SC2-LOTV-COST-TABLE raw-sym (lambda () #f))
           (and (not (eq? canon raw-sym))
                (hash-ref SC2-LOTV-COST-TABLE canon (lambda () #f)))))
     (and entry
          (let ([base (static-unit-morph-base-for-total canon)])
            (cond
              [(or (not base) (eq? base 'drone))
               (real->double-flonum (third entry))]
              [(symbol? base)
               (fl+ (real->double-flonum (third entry))
                    (or (static-unit-on-field-supply-opt base (+ depth 1)) 0.0))]
              [else
               (fl+ (real->double-flonum (third entry))
                    (real->double-flonum (third base)))])))]))

(: sc2-unit-on-field-supply (->* (Any) (Flonum) Flonum))
(define (sc2-unit-on-field-supply sym [default 1.0])
  (cond
    [(not (symbol? sym)) default]
    [else
     (define canon (canonical-unit-type-sym sym))
     (define live-raw
       (and (unbox SC2-LIVE-DATA-ACTIVE?)
            (or (hash-ref SC2-LIVE-RAW-COST-OVERLAY sym (lambda () #f))
                (and (not (eq? canon sym))
                     (hash-ref SC2-LIVE-RAW-COST-OVERLAY canon (lambda () #f))))))
     (if live-raw
         (real->double-flonum (third live-raw))
         (or (static-unit-on-field-supply-opt sym 0) default))]))

(: static-unit-total-cost-pair-opt (-> Symbol Integer (Option (Pairof Integer Integer))))
(define (static-unit-total-cost-pair-opt raw-sym depth)
  (define canon (canonical-unit-type-sym raw-sym))
  (cond
    [(> depth 6) #f]
    [(memq canon '(zergling zergling-burrowed)) (cons 25 0)]
    [(eq? canon 'archon) (cons 100 300)]
    [else
     (define entry
       (or (hash-ref SC2-LOTV-COST-TABLE raw-sym (lambda () #f))
           (and (not (eq? canon raw-sym))
                (hash-ref SC2-LOTV-COST-TABLE canon (lambda () #f)))))
     (and entry
          (let ([base (static-unit-morph-base-for-total canon)])
            (cond
              [(or (not base) (eq? base 'drone))
               (cons (first entry) (second entry))]
              [(symbol? base)
               (define bp (or (static-unit-total-cost-pair-opt base (+ depth 1)) (cons 0 0)))
               (cons (+ (first entry) (car bp))
                     (+ (second entry) (cdr bp)))]
              [else
               (cons (+ (first entry) (first base))
                     (+ (second entry) (second base)))])))]))

(: sc2-unit-total-cost-pair-opt (-> Any (Option (Pairof Integer Integer))))
(define (sc2-unit-total-cost-pair-opt sym)
  (cond
    [(not (symbol? sym)) #f]
    [else
     (define canon (canonical-unit-type-sym sym))
     (define live-raw
       (and (unbox SC2-LIVE-DATA-ACTIVE?)
            (or (hash-ref SC2-LIVE-RAW-COST-OVERLAY sym (lambda () #f))
                (and (not (eq? canon sym))
                     (hash-ref SC2-LIVE-RAW-COST-OVERLAY canon (lambda () #f))))))
     (cond
       [live-raw
        (define rm (first live-raw))
        (define rg (second live-raw))
        (cond
          [(and (eq? canon 'archon) (= rm 0) (= rg 0))
           (cons 100 300)]
          [(zerg-drone-consumed-ancestor? canon)
           (cons (max 0 (- rm 50)) (max 0 rg))]
          [else
           (cons (max 0 rm) (max 0 rg))])]
       [else
        (static-unit-total-cost-pair-opt sym 0)])]))

(: sc2-unit-total-cost-pair (->* (Any) ((Pairof Integer Integer)) (Pairof Integer Integer)))
(define (sc2-unit-total-cost-pair sym [default (cons 50 0)])
  (or (sc2-unit-total-cost-pair-opt sym) default))

(: sc2-unit-total-min-cost (->* (Any) (Integer) Integer))
(define (sc2-unit-total-min-cost sym [default 50])
  (define p (sc2-unit-total-cost-pair-opt sym))
  (if p (car p) default))

(: sc2-unit-total-gas-cost (->* (Any) (Integer) Integer))
(define (sc2-unit-total-gas-cost sym [default 0])
  (define p (sc2-unit-total-cost-pair-opt sym))
  (if p (cdr p) default))

(: sc2-unit-total-value (->* (Any) (Integer) Integer))
(define (sc2-unit-total-value sym [default 0])
  (define p (sc2-unit-total-cost-pair-opt sym))
  (if p (+ (car p) (cdr p)) default))

;; -----------------------------------------------------------------------------
;; Unified Live-Hydrated `SC2-SPELL-SPEC` Registry
;; -----------------------------------------------------------------------------

(struct sc2-spell-spec
  ([sym              : Symbol]
   [ability-id       : Nonnegative-Integer]
   [caster-sym       : Symbol]
   [target-mode      : Symbol]          ;; 'point | 'unit | 'none | 'point-or-unit
   [energy-cost      : Flonum]
   [cooldown-frames  : Nonnegative-Integer] ;; 0 if none (at 22.4 fps)
   [cast-range       : Flonum]          ;; static 5.0.14 fallback
   [effect-radius    : Flonum]          ;; static 5.0.14 fallback
   [claim-radius     : Flonum]          ;; tactical dedup floor (expands with live effect-radius)
   [claim-ttl-frames : Nonnegative-Integer]
   [duration-frames  : Nonnegative-Integer] ;; persistent effect / nova lifetime
   [lockout-frames   : Nonnegative-Integer] ;; channel / post-cast caster lock
   [base-damage      : Flonum]
   [bonus-damage     : Flonum]
   [bonus-attr-mask  : Fixnum]          ;; e.g., SC2-UNIT-ATTR-PSIONIC, 0 if shield/none
   [required-upgrade : (Option Symbol)])
  #:transparent)

(: SC2-SPELL-SPEC-TABLE (Immutable-HashTable Symbol sc2-spell-spec))
(define SC2-SPELL-SPEC-TABLE
  (hasheq
   'psi-storm             (sc2-spell-spec 'psi-storm             1036 'high-templar        'point 75.0  0    9.0   1.5  2.0  56   64  0  80.0  0.0   0                     'psi-storm)
   'feedback              (sc2-spell-spec 'feedback              140  'high-templar        'unit  50.0  0    10.0  0.0  0.0  36   0   0  0.0   0.0   0                     #f)
   'purification-nova     (sc2-spell-spec 'purification-nova     2346 'disruptor           'point 0.0   480  10.0  1.5  4.0  47   47  0  100.0 200.0 0                     #f)
   'nexus-energy-recharge (sc2-spell-spec 'nexus-energy-recharge 4126 'nexus               'unit  50.0  1344 10.0  0.0  0.0  1344 0   0  0.0   0.0   0                     #f)
   'guardian-shield       (sc2-spell-spec 'guardian-shield       76   'sentry              'none  75.0  0    0.0   4.5  5.0  246  246 0  0.0   0.0   0                     #f)
   'force-field           (sc2-spell-spec 'force-field           1526 'sentry              'point 50.0  0    9.0   1.5  1.5  32   246 0  0.0   0.0   0                     #f)
   'revelation            (sc2-spell-spec 'revelation            2146 'oracle              'point 25.0  0    9.0   6.0  6.0  448  448 0  0.0   0.0   0                     #f)
   'stasis-ward           (sc2-spell-spec 'stasis-ward           2536 'oracle              'point 50.0  0    4.0   2.5  2.5  64   0   0  0.0   0.0   0                     #f)
   'shadow-stride         (sc2-spell-spec 'shadow-stride         2700 'dark-templar        'point 0.0   314  8.0   0.0  0.0  0    0   0  0.0   0.0   0                     'shadow-stride)
   'blink                 (sc2-spell-spec 'blink                 1442 'stalker             'point 0.0   157  8.0   0.0  0.0  0    0   0  0.0   0.0   0                     'blink)
   'time-warp             (sc2-spell-spec 'time-warp             2244 'mothership          'point 100.0 0    9.0   3.5  3.5  224  224 0  0.0   0.0   0                     #f)
   'emp-round             (sc2-spell-spec 'emp-round             1628 'ghost               'point 75.0  0    10.0  1.5  1.5  24   0   0  100.0 0.0   0                     #f)
   'steady-targeting      (sc2-spell-spec 'steady-targeting      2714 'ghost               'unit  50.0  0    10.0  0.0  0.0  34   0   34 130.0 40.0  SC2-UNIT-ATTR-PSIONIC #f)
   'anti-armor-missile    (sc2-spell-spec 'anti-armor-missile    3753 'raven               'unit  75.0  0    10.0  2.5  2.5  48   336 0  0.0   0.0   0                     #f)
   'interference-matrix   (sc2-spell-spec 'interference-matrix   3747 'raven               'unit  75.0  0    9.0   0.0  0.0  36   179 0  0.0   0.0   0                     'interference-matrix)
   'yamato-cannon         (sc2-spell-spec 'yamato-cannon         401  'battlecruiser       'unit  0.0   1590 10.0  0.0  0.0  36   0   0  240.0 0.0   0                     'weapon-refit)
   'tactical-jump         (sc2-spell-spec 'tactical-jump         2358 'battlecruiser       'point 0.0   1590 256.0 0.0  0.0  0    0   0  0.0   0.0   0                     #f)
   'medivac-boost         (sc2-spell-spec 'medivac-boost         2116 'medivac             'none  0.0   320  0.0   0.0  0.0  0    128 0  0.0   0.0   0                     #f)
   'lock-on               (sc2-spell-spec 'lock-on               2350 'cyclone             'unit  0.0   196  7.0   0.0  0.0  0    134 0  0.0   0.0   0                     #f)
   'widow-mine-splash     (sc2-spell-spec 'widow-mine-splash     0    'widow-mine-burrowed 'unit  0.0   648  5.0   1.5  1.5  0    0   0  40.0  25.0  0                     #f)
   'scanner-sweep         (sc2-spell-spec 'scanner-sweep         399  'orbital-command     'point 50.0  0    256.0 13.0 13.0 268  268 0  0.0   0.0   0                     #f)
   'fungal-growth         (sc2-spell-spec 'fungal-growth         74   'infestor            'point 75.0  0    10.0  2.25 2.25 32   67  0  30.0  0.0   0                     #f)
   'neural-parasite       (sc2-spell-spec 'neural-parasite       249  'infestor            'unit  100.0 0    8.0   0.0  0.0  36   246 0  0.0   0.0   0                     'neural-parasite)
   'microbial-shroud      (sc2-spell-spec 'microbial-shroud      4111 'infestor            'point 100.0 0    9.0   3.5  3.5  48   246 0  0.0   0.0   0                     #f)
   'blinding-cloud        (sc2-spell-spec 'blinding-cloud        2063 'viper               'point 100.0 0    11.0  2.0  2.0  48   128 0  0.0   0.0   0                     #f)
   'abduct                (sc2-spell-spec 'abduct                2067 'viper               'unit  75.0  0    9.0   0.0  0.0  36   0   13 0.0   0.0   0                     #f)
   'parasitic-bomb        (sc2-spell-spec 'parasitic-bomb        2542 'viper               'unit  125.0 0    8.0   3.0  3.0  36   157 0  120.0 0.0   0                     #f)
   'corrosive-bile        (sc2-spell-spec 'corrosive-bile        2338 'ravager             'point 0.0   157  9.0   0.5  0.55 36   56  0  60.0  0.0   0                     #f)
   'caustic-spray         (sc2-spell-spec 'caustic-spray         2324 'corruptor           'unit  0.0   1008 6.0   0.0  0.0  36   0   0  0.0   0.0   0                     #f)
   'transfusion           (sc2-spell-spec 'transfusion           1664 'queen               'unit  50.0  0    7.0   0.0  0.0  16   0   0  0.0   0.0   0                     #f)))

(: normalize-sc2-spell-sym (-> Symbol Symbol))
(define (normalize-sc2-spell-sym sym)
  (case sym
    [(psionic-storm psistorm) 'psi-storm]
    [(emp)                    'emp-round]
    [(snipe)                  'steady-targeting]
    [(energy-recharge)        'nexus-energy-recharge]
    [(amorphous-armorcloud)   'microbial-shroud]
    [(disruptor-nova)         'purification-nova]
    [(oracle-revelation)      'revelation]
    [(anti-armor)             'anti-armor-missile]
    [(fungal)                 'fungal-growth]
    [(bile)                   'corrosive-bile]
    [(yamato)                 'yamato-cannon]
    [(stalker-blink)          'blink]
    [else                     sym]))

(: sc2-spell-spec-ref (-> Symbol (Option sc2-spell-spec)))
(define (sc2-spell-spec-ref sym)
  (hash-ref SC2-SPELL-SPEC-TABLE (normalize-sc2-spell-sym sym) (lambda () #f)))

(: sc2-spell-ability-id (->* (Symbol) (Nonnegative-Integer) Nonnegative-Integer))
(define (sc2-spell-ability-id sym [default 0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-ability-id spec) default))

(: sc2-spell-cast-range (->* (Symbol) (Flonum) Flonum))
(define (sc2-spell-cast-range sym [default 0.0])
  (define spec (sc2-spell-spec-ref sym))
  (cond
    [(not spec) default]
    [else
     (define ab-id (sc2-spell-spec-ability-id spec))
     (define live-rng (if (> ab-id 0) (sc2-ability-cast-range ab-id 0.0) 0.0))
     (if (fl> live-rng 0.0) live-rng (sc2-spell-spec-cast-range spec))]))

(: sc2-spell-effect-radius (->* (Symbol) (Flonum) Flonum))
(define (sc2-spell-effect-radius sym [default 0.0])
  (define spec (sc2-spell-spec-ref sym))
  (cond
    [(not spec) default]
    [else
     (define live-r (sc2-live-effect-radius (sc2-spell-spec-sym spec) 0.0))
     (if (fl> live-r 0.0) live-r (sc2-spell-spec-effect-radius spec))]))

(: sc2-spell-claim-radius (->* (Symbol) (Flonum) Flonum))
(define (sc2-spell-claim-radius sym [default 0.0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec
      (flmax (sc2-spell-spec-claim-radius spec)
             (sc2-spell-effect-radius (sc2-spell-spec-sym spec) 0.0))
      default))

(: sc2-spell-energy (->* (Symbol) (Flonum) Flonum))
(define (sc2-spell-energy sym [default 0.0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-energy-cost spec) default))

(: sc2-spell-cooldown-frames (->* (Symbol) (Nonnegative-Integer) Nonnegative-Integer))
(define (sc2-spell-cooldown-frames sym [default 0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-cooldown-frames spec) default))

(: sc2-spell-claim-ttl (->* (Symbol) (Nonnegative-Integer) Nonnegative-Integer))
(define (sc2-spell-claim-ttl sym [default 0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-claim-ttl-frames spec) default))

(: sc2-spell-duration-frames (->* (Symbol) (Nonnegative-Integer) Nonnegative-Integer))
(define (sc2-spell-duration-frames sym [default 0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-duration-frames spec) default))

(: sc2-spell-lockout-frames (->* (Symbol) (Nonnegative-Integer) Nonnegative-Integer))
(define (sc2-spell-lockout-frames sym [default 0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-lockout-frames spec) default))

(: sc2-spell-base-damage (->* (Symbol) (Flonum) Flonum))
(define (sc2-spell-base-damage sym [default 0.0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-base-damage spec) default))

(: sc2-spell-bonus-damage (->* (Symbol) (Flonum) Flonum))
(define (sc2-spell-bonus-damage sym [default 0.0])
  (define spec (sc2-spell-spec-ref sym))
  (if spec (sc2-spell-spec-bonus-damage spec) default))

(: sc2-spell-required-upgrade (-> Symbol (Option Symbol)))
(define (sc2-spell-required-upgrade sym)
  (define spec (sc2-spell-spec-ref sym))
  (and spec (sc2-spell-spec-required-upgrade spec)))



