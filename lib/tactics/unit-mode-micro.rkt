#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/unit-mode-micro.rkt`
;; Empirical Pro-Calibrated Unit Mode & Standoff Micro Module (Typed Racket):
;;
;;   1. `Thor` Mode (`'thor` 52 <-> `'thor-ap` 691):
;;      224f (10.0s) dwell hysteresis, Explosive (`2364`) vs Mutalisk/light air
;;      clumps (`19/19` pro Mutalisk invariant), High-Impact (`2362`) vs capital/
;;      massive air (< 3 Mutas), plus low-HP / close high-DPS morph safety guard.
;;   2. `Hellion` (`53`) <-> `Hellbat` (`484`):
;;      Armory-gated, <= 18.0-tile pre-engagement morph (`1998`) with 96f
;;      hysteresis and one-way combat commitment (`1978` unmorph only after
;;      >= 176f [7.9s] and 0 melee/ground threats within 22.0 tiles, or runby).
;;   3. `Viking` (`'viking-fighter` 35 <-> `'viking-assault` 34):
;;      Strict cleanup-only landing (`403`, >= 135f dwell, 0 combat air / Colossus
;;      within 22.0 tiles or in air memory, HP >= 0.70, 0 anti-mech splash <= 11.0,
;;      >= 1.35x local ground superiority, [4.5..5.5]-tile safe standoff), plus
;;      immediate / 64f emergency capital-air liftoff (`405`).
;;   4. `Cyclone` (`692`) `Lock On` (`2350`) & [8.5..13.5]-Tile Tether Kiting:
;;      >= 135f cooldown, < 315f channel tracking, 0 manual cancels, transport/
;;      armored/tech priority within 6.5 tiles (avoiding lone Zergling/Larva),
;;      and dynamic kite/orbit/reclose within the 15.0-tile tether envelope.
;;   5. `Marauder` (`51`) Concussive Shells Target Spreading:
;;      Per-enemy 32f (1.43s) slow timestamp table spreading shots across N
;;      unslowed non-massive ground enemies in 6.0-7.5-tile range, preserving
;;      lethal-finish (`<= 35` HP+shield) and massive-only exceptions.
;;
;; Architecture Guard: Zero cyclic `require` (only `typed/racket/base`, stdlib,
;; `../sc2-types.rkt`, `../sc2-geometry.rkt`, `../sc2-game-constants.rkt`).
;; =============================================================================

(require racket/list
         racket/math
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-geometry.rkt"
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

;; Safe dynamic hash boundary for untyped observation hashes (`sc2-unit` / `hasheq`).
(module dyn-hash-ops racket/base
  (provide dyn-hash-ref
           dyn-hash-has-key?)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (hash-ref h k (lambda () default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k))))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)])

(provide
 ;; Canonical Unit Type & Ability Constants
 THOR-UNIT-TYPE-ID
 THOR-AP-UNIT-TYPE-ID
 HELLION-UNIT-TYPE-ID
 HELLBAT-UNIT-TYPE-ID
 VIKING-FIGHTER-UNIT-TYPE-ID
 VIKING-ASSAULT-UNIT-TYPE-ID
 CYCLONE-UNIT-TYPE-ID
 MARAUDER-UNIT-TYPE-ID
 MORPH-THOR-HIGH-IMPACT-ABILITY-ID
 MORPH-THOR-EXPLOSIVE-ABILITY-ID
 MORPH-HELLBAT-ABILITY-ID
 MORPH-HELLION-ABILITY-ID
 MORPH-VIKING-ASSAULT-ABILITY-ID
 MORPH-VIKING-FIGHTER-ABILITY-ID
 CYCLONE-LOCK-ON-ABILITY-ID
 CYCLONE-LOCK-ON-BUFF-ID

 ;; Pro-Calibrated Mode, Dwell & Tether Constants
 THOR-MODE-DWELL-FRAMES
 THOR-EXPLOSIVE-MUTALISK-MIN
 THOR-EXPLOSIVE-AIR-SCAN-RADIUS
 THOR-EXPLOSIVE-CAPITAL-CHECK-RADIUS
 THOR-HIGH-IMPACT-SCAN-RADIUS
 THOR-HIGH-IMPACT-LIGHT-BLOCK-RADIUS
 THOR-MORPH-SAFETY-HP-RATIO
 THOR-MORPH-SAFETY-GROUND-RADIUS
 THOR-MORPH-SAFETY-DPS-THREATS
 HELLBAT-PREENGAGE-RANGE
 HELLBAT-ARMY-COHESION-RANGE
 HELLBAT-PREENGAGE-HYSTERESIS-FRAMES
 HELLBAT-MIN-COMMIT-DWELL-FRAMES
 HELLBAT-UNMORPH-CLEAR-RADIUS
 VIKING-LIFTOFF-AIR-RADIUS
 VIKING-EMERGENCY-CAPITAL-RADIUS
 VIKING-EMERGENCY-LIFTOFF-DWELL-FRAMES
 VIKING-LIFTOFF-HP-RATIO
 VIKING-LIFTOFF-GROUND-SPLASH-RADIUS
 VIKING-LIFTOFF-POWER-THRESHOLD
 VIKING-LAND-SAFE-AIR-RADIUS
 VIKING-LAND-MIN-HP-RATIO
 VIKING-GROUND-DWELL-FRAMES
 VIKING-LAND-GROUND-SPLASH-RADIUS
 VIKING-LAND-GROUND-TARGET-RADIUS
 VIKING-LAND-POWER-RATIO
 VIKING-LAND-STANDOFF-MIN
 VIKING-LAND-STANDOFF-MAX
 CYCLONE-LOCK-ON-COOLDOWN-FRAMES
 CYCLONE-LOCK-ON-CHANNEL-FRAMES
 CYCLONE-LOCK-ON-CAST-RANGE
 CYCLONE-TETHER-MIN-DIST
 CYCLONE-TETHER-ORBIT-MIN
 CYCLONE-TETHER-ORBIT-MAX
 CYCLONE-TETHER-TARGET-KITE
 CYCLONE-TETHER-MAX-RECLOSE
 CYCLONE-TETHER-BREAK-RANGE
 CYCLONE-CLOSE-THREAT-RADIUS
 MARAUDER-SLOW-DURATION-FRAMES
 MARAUDER-WEAPON-RANGE
 MARAUDER-ACQUIRE-MAX-RANGE
 MARAUDER-LETHAL-FINISH-EHP

 ;; Typed Data Structs
 (struct-out mode-unit-input)
 (struct-out unit-mode-directive)
 (struct-out marauder-target-order)

 ;; Frame State Tracker Management
 unit-mode-tracker?
 make-unit-mode-tracker
 unit-mode-tracker-thor-dwell-elapsed
 unit-mode-tracker-hellbat-dwell-elapsed
 unit-mode-tracker-viking-dwell-elapsed
 unit-mode-tracker-cyclone-lock-state
 unit-mode-tracker-marauder-slow-until
 unit-mode-tracker-enemy-slowed?
 unit-mode-tracker-mark-enemy-slowed!
 unit-mode-tracker-record-enemy-air!
 unit-mode-tracker-prune-dead!
 sync-unit-mode-tracker!

 ;; Unit Predicates & Scoring Helpers
 thor-explosive-threat-air?
 thor-high-impact-target-air?
 thor-capital-air-sym?
 thor-morph-safe?
 viking-combat-air-or-colossus-sym?
 viking-capital-air-sym?
 viking-ground-splash-sym?
 compute-viking-land-standoff
 cyclone-target-priority-score
 massive-ground-unit-sym?

 ;; Single-Unit & Batch Mode Planners
 evaluate-thor-mode
 plan-thor-modes
 evaluate-hellion-mode
 plan-hellion-modes
 evaluate-viking-mode
 plan-viking-modes
 evaluate-cyclone-micro
 plan-cyclone-micro
 plan-marauder-concussive-targets

 ;; S-Expression Orchestrator
 unit-mode-directive->sexp
 marauder-order->sexp
 step-unit-mode-micro!)

;; =============================================================================
;; Constants (LotV Balance / Empirical `#115` Calibration at 22.4 fps)
;; =============================================================================

;; SC2 Unit Type IDs (`lib/sc2-protobuf-ws.rkt:739-754`)
(: THOR-UNIT-TYPE-ID Integer)
(define THOR-UNIT-TYPE-ID 52)

(: THOR-AP-UNIT-TYPE-ID Integer)
(define THOR-AP-UNIT-TYPE-ID 691)

(: HELLION-UNIT-TYPE-ID Integer)
(define HELLION-UNIT-TYPE-ID 53)

(: HELLBAT-UNIT-TYPE-ID Integer)
(define HELLBAT-UNIT-TYPE-ID 484)

(: VIKING-FIGHTER-UNIT-TYPE-ID Integer)
(define VIKING-FIGHTER-UNIT-TYPE-ID 35)

(: VIKING-ASSAULT-UNIT-TYPE-ID Integer)
(define VIKING-ASSAULT-UNIT-TYPE-ID 34)

(: CYCLONE-UNIT-TYPE-ID Integer)
(define CYCLONE-UNIT-TYPE-ID 692)

(: MARAUDER-UNIT-TYPE-ID Integer)
(define MARAUDER-UNIT-TYPE-ID 51)

;; Canonical Wire Ability IDs (`lib/sc2-protobuf-ws.rkt:986-995`, `lib/sc2-typed-commands.rkt:1666-1758`)
(: MORPH-THOR-HIGH-IMPACT-ABILITY-ID Integer)
(define MORPH-THOR-HIGH-IMPACT-ABILITY-ID 2362)

(: MORPH-THOR-EXPLOSIVE-ABILITY-ID Integer)
(define MORPH-THOR-EXPLOSIVE-ABILITY-ID 2364)

(: MORPH-HELLBAT-ABILITY-ID Integer)
(define MORPH-HELLBAT-ABILITY-ID 1998)

(: MORPH-HELLION-ABILITY-ID Integer)
(define MORPH-HELLION-ABILITY-ID 1978)

(: MORPH-VIKING-ASSAULT-ABILITY-ID Integer)
(define MORPH-VIKING-ASSAULT-ABILITY-ID 403)

(: MORPH-VIKING-FIGHTER-ABILITY-ID Integer)
(define MORPH-VIKING-FIGHTER-ABILITY-ID 405)

(: CYCLONE-LOCK-ON-ABILITY-ID Integer)
(define CYCLONE-LOCK-ON-ABILITY-ID 2350)

(: CYCLONE-LOCK-ON-BUFF-ID Integer)
(define CYCLONE-LOCK-ON-BUFF-ID 116)

;; 1. Thor Constants
(: THOR-MODE-DWELL-FRAMES Integer)
(define THOR-MODE-DWELL-FRAMES 224)

(: THOR-EXPLOSIVE-MUTALISK-MIN Integer)
(define THOR-EXPLOSIVE-MUTALISK-MIN 3)

(: THOR-EXPLOSIVE-AIR-SCAN-RADIUS Float)
(define THOR-EXPLOSIVE-AIR-SCAN-RADIUS 13.0)

(: THOR-EXPLOSIVE-CAPITAL-CHECK-RADIUS Float)
(define THOR-EXPLOSIVE-CAPITAL-CHECK-RADIUS 12.0)

(: THOR-HIGH-IMPACT-SCAN-RADIUS Float)
(define THOR-HIGH-IMPACT-SCAN-RADIUS 15.0)

(: THOR-HIGH-IMPACT-LIGHT-BLOCK-RADIUS Float)
(define THOR-HIGH-IMPACT-LIGHT-BLOCK-RADIUS 11.0)

(: THOR-MORPH-SAFETY-HP-RATIO Float)
(define THOR-MORPH-SAFETY-HP-RATIO 0.35)

(: THOR-MORPH-SAFETY-GROUND-RADIUS Float)
(define THOR-MORPH-SAFETY-GROUND-RADIUS 6.5)

(: THOR-MORPH-SAFETY-DPS-THREATS Integer)
(define THOR-MORPH-SAFETY-DPS-THREATS 3)

;; 2. Hellion <-> Hellbat Constants
(: HELLBAT-PREENGAGE-RANGE Float)
(define HELLBAT-PREENGAGE-RANGE 18.0)

(: HELLBAT-ARMY-COHESION-RANGE Float)
(define HELLBAT-ARMY-COHESION-RANGE 6.0)

(: HELLBAT-PREENGAGE-HYSTERESIS-FRAMES Integer)
(define HELLBAT-PREENGAGE-HYSTERESIS-FRAMES 96)

(: HELLBAT-MIN-COMMIT-DWELL-FRAMES Integer)
(define HELLBAT-MIN-COMMIT-DWELL-FRAMES 176)

(: HELLBAT-UNMORPH-CLEAR-RADIUS Float)
(define HELLBAT-UNMORPH-CLEAR-RADIUS 22.0)

;; 3. Viking Landing & Liftoff Constants
(: VIKING-LIFTOFF-AIR-RADIUS Float)
(define VIKING-LIFTOFF-AIR-RADIUS 25.0)

(: VIKING-EMERGENCY-CAPITAL-RADIUS Float)
(define VIKING-EMERGENCY-CAPITAL-RADIUS 15.0)

(: VIKING-EMERGENCY-LIFTOFF-DWELL-FRAMES Integer)
(define VIKING-EMERGENCY-LIFTOFF-DWELL-FRAMES 64)

(: VIKING-LIFTOFF-HP-RATIO Float)
(define VIKING-LIFTOFF-HP-RATIO 0.55)

(: VIKING-LIFTOFF-GROUND-SPLASH-RADIUS Float)
(define VIKING-LIFTOFF-GROUND-SPLASH-RADIUS 9.5)

(: VIKING-LIFTOFF-POWER-THRESHOLD Float)
(define VIKING-LIFTOFF-POWER-THRESHOLD 0.85)

(: VIKING-LAND-SAFE-AIR-RADIUS Float)
(define VIKING-LAND-SAFE-AIR-RADIUS 22.0)

(: VIKING-LAND-MIN-HP-RATIO Float)
(define VIKING-LAND-MIN-HP-RATIO 0.70)

(: VIKING-GROUND-DWELL-FRAMES Integer)
(define VIKING-GROUND-DWELL-FRAMES 135)

(: VIKING-LAND-GROUND-SPLASH-RADIUS Float)
(define VIKING-LAND-GROUND-SPLASH-RADIUS 11.0)

(: VIKING-LAND-GROUND-TARGET-RADIUS Float)
(define VIKING-LAND-GROUND-TARGET-RADIUS 10.0)

(: VIKING-LAND-POWER-RATIO Float)
(define VIKING-LAND-POWER-RATIO 1.35)

(: VIKING-LAND-STANDOFF-MIN Float)
(define VIKING-LAND-STANDOFF-MIN 4.5)

(: VIKING-LAND-STANDOFF-MAX Float)
(define VIKING-LAND-STANDOFF-MAX 5.5)

;; 4. Cyclone Lock-On & Tether Constants
(: CYCLONE-LOCK-ON-COOLDOWN-FRAMES Integer)
(define CYCLONE-LOCK-ON-COOLDOWN-FRAMES 135)

(: CYCLONE-LOCK-ON-CHANNEL-FRAMES Integer)
(define CYCLONE-LOCK-ON-CHANNEL-FRAMES 315)

(: CYCLONE-LOCK-ON-CAST-RANGE Float)
(define CYCLONE-LOCK-ON-CAST-RANGE 6.5)

(: CYCLONE-TETHER-MIN-DIST Float)
(define CYCLONE-TETHER-MIN-DIST 9.0)

(: CYCLONE-TETHER-ORBIT-MIN Float)
(define CYCLONE-TETHER-ORBIT-MIN 9.0)

(: CYCLONE-TETHER-ORBIT-MAX Float)
(define CYCLONE-TETHER-ORBIT-MAX 12.8)

(: CYCLONE-TETHER-TARGET-KITE Float)
(define CYCLONE-TETHER-TARGET-KITE 11.0)

(: CYCLONE-TETHER-MAX-RECLOSE Float)
(define CYCLONE-TETHER-MAX-RECLOSE 11.5)

(: CYCLONE-TETHER-BREAK-RANGE Float)
(define CYCLONE-TETHER-BREAK-RANGE 15.0)

(: CYCLONE-CLOSE-THREAT-RADIUS Float)
(define CYCLONE-CLOSE-THREAT-RADIUS 7.0)

;; 5. Marauder Concussive Shells Constants
(: MARAUDER-SLOW-DURATION-FRAMES Integer)
(define MARAUDER-SLOW-DURATION-FRAMES 32)

(: MARAUDER-WEAPON-RANGE Float)
(define MARAUDER-WEAPON-RANGE 6.0)

(: MARAUDER-ACQUIRE-MAX-RANGE Float)
(define MARAUDER-ACQUIRE-MAX-RANGE 7.5)

(: MARAUDER-LETHAL-FINISH-EHP Float)
(define MARAUDER-LETHAL-FINISH-EHP 35.0)

;; =============================================================================
;; Public Data Structs
;; =============================================================================

;; Optional structured input record accepted interchangeably with unit hashes.
(struct mode-unit-input
  ([tag : Integer]
   [type : Symbol]
   [x : Float]
   [y : Float]
   [hp : Float]
   [max-hp : Float]
   [shield : Float]
   [max-shield : Float]
   [flying? : Boolean]
   [under-fire? : Boolean]
   [worker-runby? : Boolean])
  #:transparent)

;; Unified mode/lock-on/kite directive emitted by single-unit & batch planners.
(struct unit-mode-directive
  ([unit-tag : Integer]
   [unit-type : Symbol]
   [action : Symbol]
   [ability : (Option Symbol)]
   [ability-id : Integer]
   [target-tag : Integer]
   [tx : Float]
   [ty : Float]
   [reason : Symbol])
  #:transparent)

;; Marauder Concussive Shells target assignment order.
(struct marauder-target-order
  ([unit-tag : Integer]
   [target-tag : Integer]
   [tx : Float]
   [ty : Float]
   [already-slowed? : Boolean]
   [lethal-finish? : Boolean]
   [massive-target? : Boolean]
   [reason : Symbol])
  #:transparent)

;; =============================================================================
;; Stateful Cross-Frame Tracker (`unit-mode-tracker`)
;; =============================================================================

(struct mode-switch-rec
  ([last-switch-frame : Integer]
   [mode : Symbol])
  #:transparent)

(struct cyclone-lock-rec
  ([last-cast-frame : Integer]
   [active-target-tag : Integer]
   [lock-start-frame : Integer])
  #:transparent)

(struct remembered-air-rec
  ([tag : Integer]
   [type : Symbol]
   [last-seen-frame : Integer])
  #:transparent)

;; Opaque mutable cross-frame state tracker (safe across typed/untyped boundaries).
(struct unit-mode-tracker
  ([thor-modes : (Mutable-HashTable Integer mode-switch-rec)]
   [hellion-modes : (Mutable-HashTable Integer mode-switch-rec)]
   [viking-modes : (Mutable-HashTable Integer mode-switch-rec)]
   [cyclone-locks : (Mutable-HashTable Integer cyclone-lock-rec)]
   [marauder-slow-table : (Mutable-HashTable Integer Integer)]
   [remembered-enemy-air : (Mutable-HashTable Integer remembered-air-rec)]))

;; Creates a fresh empty `unit-mode-tracker`.
(: make-unit-mode-tracker (-> unit-mode-tracker))
(define (make-unit-mode-tracker)
  (unit-mode-tracker
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)))

(: mode-dwell-elapsed (-> (Mutable-HashTable Integer mode-switch-rec) Integer Integer Integer))
(define (mode-dwell-elapsed tbl tag current-frame)
  (define rec (hash-ref tbl tag (lambda () #f)))
  (if rec
      (max 0 (- current-frame (mode-switch-rec-last-switch-frame rec)))
      10000))

;; Returns elapsed frames since `tag` last switched Thor mode (large default if unseen).
(: unit-mode-tracker-thor-dwell-elapsed (-> unit-mode-tracker Integer Integer Integer))
(define (unit-mode-tracker-thor-dwell-elapsed tr tag current-frame)
  (mode-dwell-elapsed (unit-mode-tracker-thor-modes tr) tag current-frame))

;; Returns elapsed frames since `tag` last switched Hellion/Hellbat mode.
(: unit-mode-tracker-hellbat-dwell-elapsed (-> unit-mode-tracker Integer Integer Integer))
(define (unit-mode-tracker-hellbat-dwell-elapsed tr tag current-frame)
  (mode-dwell-elapsed (unit-mode-tracker-hellion-modes tr) tag current-frame))

;; Returns elapsed frames since `tag` last switched Viking Fighter/Assault mode.
(: unit-mode-tracker-viking-dwell-elapsed (-> unit-mode-tracker Integer Integer Integer))
(define (unit-mode-tracker-viking-dwell-elapsed tr tag current-frame)
  (mode-dwell-elapsed (unit-mode-tracker-viking-modes tr) tag current-frame))

;; Returns `(values active-target-tag lock-age-frames cooldown-remaining)` for Cyclone `tag`.
(: unit-mode-tracker-cyclone-lock-state
   (-> unit-mode-tracker Integer Integer (Values Integer Integer Integer)))
(define (unit-mode-tracker-cyclone-lock-state tr tag current-frame)
  (define rec (hash-ref (unit-mode-tracker-cyclone-locks tr) tag (lambda () #f)))
  (if (not rec)
      (values 0 0 0)
      (let* ([last-cast (cyclone-lock-rec-last-cast-frame rec)]
             [cd-rem (max 0 (- (+ last-cast CYCLONE-LOCK-ON-COOLDOWN-FRAMES) current-frame))]
             [tgt (cyclone-lock-rec-active-target-tag rec)]
             [age (max 0 (- current-frame (cyclone-lock-rec-lock-start-frame rec)))])
        (if (and (> tgt 0) (< age CYCLONE-LOCK-ON-CHANNEL-FRAMES))
            (values tgt age cd-rem)
            (values 0 0 cd-rem)))))

;; Returns the frame at which Concussive Shells slow expires for `enemy-tag` (0 if unset).
(: unit-mode-tracker-marauder-slow-until (-> unit-mode-tracker Integer Integer))
(define (unit-mode-tracker-marauder-slow-until tr enemy-tag)
  (hash-ref (unit-mode-tracker-marauder-slow-table tr) enemy-tag (lambda () 0)))

;; True while `enemy-tag` is currently slowed by a tracked Marauder Concussive shot.
(: unit-mode-tracker-enemy-slowed? (-> unit-mode-tracker Integer Integer Boolean))
(define (unit-mode-tracker-enemy-slowed? tr enemy-tag current-frame)
  (> (unit-mode-tracker-marauder-slow-until tr enemy-tag) current-frame))

;; Marks `enemy-tag` as slowed by Concussive Shells until `(+ current-frame 32)`.
(: unit-mode-tracker-mark-enemy-slowed! (-> unit-mode-tracker Integer Integer Void))
(define (unit-mode-tracker-mark-enemy-slowed! tr enemy-tag current-frame)
  (hash-set! (unit-mode-tracker-marauder-slow-table tr)
             enemy-tag
             (+ current-frame MARAUDER-SLOW-DURATION-FRAMES)))

;; Records seen combat air / Colossus units into the tracker's enemy air memory.
(: unit-mode-tracker-record-enemy-air! (-> unit-mode-tracker (Listof Any) Integer Void))
(define (unit-mode-tracker-record-enemy-air! tr enemy-units current-frame)
  (define mem (unit-mode-tracker-remembered-enemy-air tr))
  (for ([e (in-list enemy-units)])
    (define ut (exact-unit-type e))
    (define tag (u-tag e))
    (when (and (u-alive? e) (viking-combat-air-or-colossus-sym? ut) (> tag 0))
      (hash-set! mem tag (remembered-air-rec tag ut current-frame)))))

;; Removes dead unit tags from all tracker tables (including remembered air threats).
(: unit-mode-tracker-prune-dead! (-> unit-mode-tracker (Listof Integer) Void))
(define (unit-mode-tracker-prune-dead! tr dead-tags)
  (define mem (unit-mode-tracker-remembered-enemy-air tr))
  (define slow-tbl (unit-mode-tracker-marauder-slow-table tr))
  (for ([dtag (in-list dead-tags)])
    (hash-remove! mem dtag)
    (hash-remove! slow-tbl dtag)))

;; =============================================================================
;; Internal Unit Normalization & Classification Helpers
;; =============================================================================

(: id->exact-unit-sym (-> Integer Symbol))
(define (id->exact-unit-sym id)
  (case id
    [(51)  'marauder]
    [(52)  'thor]
    [(691) 'thor-ap]
    [(53)  'hellion]
    [(484) 'hellbat]
    [(35)  'viking-fighter]
    [(34)  'viking-assault]
    [(692) 'cyclone]
    [(48)  'marine]
    [(49)  'reaper]
    [(50)  'ghost]
    [(33)  'siege-tank]
    [(32)  'siege-tank-sieged]
    [(498) 'widow-mine]
    [(500) 'widow-mine-burrowed]
    [(54)  'medivac]
    [(55)  'banshee]
    [(56)  'raven]
    [(57)  'battlecruiser]
    [(689) 'liberator]
    [(734) 'liberator-ag]
    [(29)  'armory]
    [(74)  'stalker]
    [(73)  'zealot]
    [(311) 'adept]
    [(77)  'sentry]
    [(75)  'high-templar]
    [(76)  'dark-templar]
    [(141) 'archon]
    [(83)  'immortal]
    [(4)   'colossus]
    [(694) 'disruptor]
    [(733) 'disruptor-phased]
    [(82)  'observer]
    [(1911) 'observer-siege-mode]
    [(81)  'warp-prism]
    [(136) 'warp-prism-phasing]
    [(78)  'phoenix]
    [(80)  'void-ray]
    [(495) 'oracle]
    [(79)  'carrier]
    [(496) 'tempest]
    [(10)  'mothership]
    [(105) 'zergling]
    [(9)   'baneling]
    [(110) 'roach]
    [(688) 'ravager]
    [(107) 'hydralisk]
    [(502) 'lurker]
    [(503) 'lurker-burrowed]
    [(108) 'mutalisk]
    [(112) 'corruptor]
    [(114) 'brood-lord]
    [(109) 'ultralisk]
    [(111) 'infestor]
    [(499) 'viper]
    [(126) 'queen]
    [(106) 'overlord]
    [(893) 'overlord-transport]
    [(129) 'overseer]
    [(1912) 'overseer-siege-mode]
    [(151) 'larva]
    [(289) 'broodling]
    [else  'unknown]))

;; Preserves mode-specific symbols (unlike `sc2-canonical-unit-sym` which collapses `'thor-ap`, `'viking-*`).
(: exact-unit-type (-> Any Symbol))
(define (exact-unit-type u)
  (cond
    [(mode-unit-input? u) (mode-unit-input-type u)]
    [(symbol? u) u]
    [(exact-integer? u) (id->exact-unit-sym u)]
    [(hash? u)
     (define raw-ut
       (cond
         [(dyn-hash-has-key? u 'unit-type) (dyn-hash-ref u 'unit-type #f)]
         [(dyn-hash-has-key? u 'unit_type) (dyn-hash-ref u 'unit_type #f)]
         [(dyn-hash-has-key? u 'type)      (dyn-hash-ref u 'type #f)]
         [else #f]))
     (cond
       [(symbol? raw-ut)
        (if (eq? raw-ut 'viking) 'viking-fighter raw-ut)]
       [(exact-integer? raw-ut)
        (let ([sym (id->exact-unit-sym raw-ut)])
          (if (not (eq? sym 'unknown)) sym (unit-type-sym u)))]
       [else
        (define t-sym (unit-type-sym u))
        (if (eq? t-sym 'viking) 'viking-fighter t-sym)])]
    [else 'unknown]))

(: u-tag (-> Any Integer))
(define (u-tag u)
  (cond
    [(mode-unit-input? u) (mode-unit-input-tag u)]
    [(hash? u)
     (define t (dyn-hash-ref u 'tag #f))
     (if (exact-integer? t)
         t
         (safe-exact-int (dyn-hash-ref u 'id 0) 0))]
    [else 0]))

(: u-x (-> Any Float))
(define (u-x u)
  (if (mode-unit-input? u)
      (mode-unit-input-x u)
      (safe-finite-real (dyn-hash-ref u 'x 0.0) 0.0)))

(: u-y (-> Any Float))
(define (u-y u)
  (if (mode-unit-input? u)
      (mode-unit-input-y u)
      (safe-finite-real (dyn-hash-ref u 'y 0.0) 0.0)))

(: u-hp (-> Any Float Float))
(define (u-hp u default)
  (cond
    [(mode-unit-input? u) (max 0.0 (mode-unit-input-hp u))]
    [(dyn-hash-has-key? u 'hp) (max 0.0 (safe-finite-real (dyn-hash-ref u 'hp default) default))]
    [(dyn-hash-has-key? u 'health) (max 0.0 (safe-finite-real (dyn-hash-ref u 'health default) default))]
    [else default]))

(: u-max-hp (-> Any Float Float))
(define (u-max-hp u default)
  (cond
    [(mode-unit-input? u) (max 1.0 (mode-unit-input-max-hp u))]
    [(dyn-hash-has-key? u 'max-hp) (max 1.0 (safe-finite-real (dyn-hash-ref u 'max-hp default) default))]
    [(dyn-hash-has-key? u 'health-max) (max 1.0 (safe-finite-real (dyn-hash-ref u 'health-max default) default))]
    [(dyn-hash-has-key? u 'max_hp) (max 1.0 (safe-finite-real (dyn-hash-ref u 'max_hp default) default))]
    [else
     (define stats (sc2-unit-combat-stats (exact-unit-type u)))
     (max 1.0 (safe-finite-real (hash-ref stats 'max-hp (lambda () default)) default))]))

(: u-shield (-> Any Float Float))
(define (u-shield u default)
  (cond
    [(mode-unit-input? u) (max 0.0 (mode-unit-input-shield u))]
    [(dyn-hash-has-key? u 'shield) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shield default) default))]
    [(dyn-hash-has-key? u 'shields) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shields default) default))]
    [else default]))

(: u-max-shield (-> Any Float Float))
(define (u-max-shield u default)
  (cond
    [(mode-unit-input? u) (max 0.0 (mode-unit-input-max-shield u))]
    [(dyn-hash-has-key? u 'max-shield) (max 0.0 (safe-finite-real (dyn-hash-ref u 'max-shield default) default))]
    [(dyn-hash-has-key? u 'shield-max) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shield-max default) default))]
    [else
     (define stats (sc2-unit-combat-stats (exact-unit-type u)))
     (max 0.0 (safe-finite-real (hash-ref stats 'max-shield (lambda () default)) default))]))

(: u-total-ehp (-> Any Float))
(define (u-total-ehp u)
  (cond
    [(mode-unit-input? u)
     (+ (max 0.0 (mode-unit-input-hp u))
        (max 0.0 (mode-unit-input-shield u)))]
    [(dyn-hash-has-key? u 'hull-hp)
     (if (or (dyn-hash-has-key? u 'hp) (dyn-hash-has-key? u 'health))
         (u-hp u 0.0)
         (+ (max 0.0 (safe-finite-real (dyn-hash-ref u 'hull-hp 0.0) 0.0))
            (u-shield u 0.0)))]
    [else
     (define ut (exact-unit-type u))
     (define stats (sc2-unit-combat-stats ut))
     (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
     (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
     (+ (u-hp u def-hp) (u-shield u def-sh))]))

(: u-total-max-ehp (-> Any Float))
(define (u-total-max-ehp u)
  (define ut (exact-unit-type u))
  (define stats (sc2-unit-combat-stats ut))
  (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
  (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
  (cond
    [(mode-unit-input? u)
     (max 1.0 (+ (max 1.0 (mode-unit-input-max-hp u))
                 (max 0.0 (mode-unit-input-max-shield u))))]
    [(dyn-hash-has-key? u 'hull-hp)
     (if (or (dyn-hash-has-key? u 'max-hp)
             (dyn-hash-has-key? u 'health-max)
             (dyn-hash-has-key? u 'max_hp))
         (max 1.0 (u-max-hp u (+ def-hp def-sh)))
         (max 1.0 (+ def-hp def-sh)))]
    [else
     (max 1.0 (+ (u-max-hp u def-hp) (u-max-shield u def-sh)))]))

(: u-hp-ratio (-> Any Float))
(define (u-hp-ratio u)
  (clamp-prob (/ (u-total-ehp u) (u-total-max-ehp u))))

(: u-alive? (-> Any Boolean))
(define (u-alive? u)
  (cond
    [(mode-unit-input? u) (> (+ (mode-unit-input-hp u) (mode-unit-input-shield u)) 0.0)]
    [(or (dyn-hash-has-key? u 'hp)
         (dyn-hash-has-key? u 'health)
         (dyn-hash-has-key? u 'hull-hp)
         (dyn-hash-has-key? u 'shield)
         (dyn-hash-has-key? u 'shields))
     (> (u-total-ehp u) 0.0)]
    [else #t]))

(: u-flying? (-> Any Boolean))
(define (u-flying? u)
  (cond
    [(mode-unit-input? u) (mode-unit-input-flying? u)]
    [(or (eq? (dyn-hash-ref u 'flying #f) #t)
         (eq? (dyn-hash-ref u 'flying? #f) #t)
         (eq? (dyn-hash-ref u 'is-flying #f) #t)
         (eq? (dyn-hash-ref u 'is_flying #f) #t))
     #t]
    [else
     (define ut (exact-unit-type u))
     (and (not (eq? ut 'viking-assault))
          (sc2-unit-is-flying-sym? ut))]))

(: u-structure? (-> Any Boolean))
(define (u-structure? u)
  (define ut (exact-unit-type u))
  (not (not (or (eq? (dyn-hash-ref u 'is-building #f) #t)
                (eq? (dyn-hash-ref u 'building? #f) #t)
                (eq? (dyn-hash-ref u 'is-structure #f) #t)
                (memq ut SC2-ALL-STRUCTURE-SYMS)
                (memq ut '(auto-turret point-defense-drone))))))

(: u-under-fire? (-> Any Boolean))
(define (u-under-fire? u)
  (cond
    [(mode-unit-input? u) (mode-unit-input-under-fire? u)]
    [(or (eq? (dyn-hash-ref u 'under-fire? #f) #t)
         (eq? (dyn-hash-ref u 'under-fire #f) #t))
     #t]
    [else #f]))

(: u-worker-runby? (-> Any Boolean))
(define (u-worker-runby? u)
  (cond
    [(mode-unit-input? u) (mode-unit-input-worker-runby? u)]
    [(or (eq? (dyn-hash-ref u 'worker-runby? #f) #t)
         (eq? (dyn-hash-ref u 'worker-runby #f) #t)
         (eq? (dyn-hash-ref u 'runby? #f) #t))
     #t]
    [else #f]))

(: u-completed? (-> Any Boolean))
(define (u-completed? u)
  (cond
    [(mode-unit-input? u) #t]
    [(dyn-hash-has-key? u 'build-progress)
     (>= (safe-finite-real (dyn-hash-ref u 'build-progress 1.0) 1.0) 1.0)]
    [(dyn-hash-has-key? u 'build_progress)
     (>= (safe-finite-real (dyn-hash-ref u 'build_progress 1.0) 1.0) 1.0)]
    [(dyn-hash-has-key? u 'progress)
     (>= (safe-finite-real (dyn-hash-ref u 'progress 1.0) 1.0) 1.0)]
    [else #t]))

(: u-has-buff? (-> Any Integer Boolean))
(define (u-has-buff? u buff-id)
  (define b1 (dyn-hash-ref u 'buffs #f))
  (define b2 (dyn-hash-ref u 'buff-ids #f))
  (define b3 (dyn-hash-ref u 'buff_ids #f))
  (or (and (list? b1) (not (not (memv buff-id b1))))
      (and (list? b2) (not (not (memv buff-id b2))))
      (and (list? b3) (not (not (memv buff-id b3))))))

(: u-weapon-range (-> Any Float))
(define (u-weapon-range u)
  (define ut (exact-unit-type u))
  (define stats (sc2-unit-combat-stats ut))
  (max (safe-finite-real (hash-ref stats 'ground-range (lambda () 0.0)) 0.0)
       (safe-finite-real (hash-ref stats 'air-range (lambda () 0.0)) 0.0)))

(: clamp-playable-pt (-> Real Real point2d))
(define (clamp-playable-pt x y)
  (clamp-point-to-map (point2d (->float x) (->float y))
                      SC2-MAP-PLAYABLE-MIN-COORD
                      SC2-MAP-PLAYABLE-MAX-COORD))

(: record-mode-switch! (-> (Mutable-HashTable Integer mode-switch-rec) Integer Integer Symbol Void))
(define (record-mode-switch! tbl tag frame new-mode)
  (hash-set! tbl tag (mode-switch-rec frame new-mode)))

;; Initializes tracker entry without consuming dwell on first observation, or records external flip.
(: sync-unit-mode-entry! (-> (Mutable-HashTable Integer mode-switch-rec) Integer Integer Symbol Void))
(define (sync-unit-mode-entry! tbl tag current-frame cur-mode)
  (define prev (hash-ref tbl tag (lambda () #f)))
  (cond
    [(not prev)
     (hash-set! tbl tag (mode-switch-rec -10000 cur-mode))]
    [(not (eq? (mode-switch-rec-mode prev) cur-mode))
     (hash-set! tbl tag (mode-switch-rec current-frame cur-mode))]))

;; Synchronizes Thor, Hellion/Hellbat, and Viking mode entries against current observations.
(: sync-unit-mode-tracker! (->* (unit-mode-tracker (Listof Any) (Listof Any) Integer)
                                (#:dead-tags (Listof Integer) #:track-air-memory? Boolean)
                                Void))
(define (sync-unit-mode-tracker! tr ally-units enemy-units current-frame
                                 #:dead-tags [dead-tags '()]
                                 #:track-air-memory? [track-air-memory? #f])
  (for ([a (in-list ally-units)]
        #:when (u-alive? a))
    (define tag (u-tag a))
    (define ut (exact-unit-type a))
    (when (> tag 0)
      (case ut
        [(thor)           (sync-unit-mode-entry! (unit-mode-tracker-thor-modes tr) tag current-frame 'explosive)]
        [(thor-ap)        (sync-unit-mode-entry! (unit-mode-tracker-thor-modes tr) tag current-frame 'high-impact)]
        [(hellion)        (sync-unit-mode-entry! (unit-mode-tracker-hellion-modes tr) tag current-frame 'hellion)]
        [(hellbat)        (sync-unit-mode-entry! (unit-mode-tracker-hellion-modes tr) tag current-frame 'hellbat)]
        [(viking-fighter viking)
                          (sync-unit-mode-entry! (unit-mode-tracker-viking-modes tr) tag current-frame 'fighter)]
        [(viking-assault) (sync-unit-mode-entry! (unit-mode-tracker-viking-modes tr) tag current-frame 'assault)])))

  (when track-air-memory?
    (unit-mode-tracker-record-enemy-air! tr enemy-units current-frame))

  (when (pair? dead-tags)
    (unit-mode-tracker-prune-dead! tr dead-tags))

  ;; Expire Cyclones' completed channels (`>= 315f`) or broken tethers (`dead` / `> 15.0` tiles)
  (define alive-enemy-by-tag : (HashTable Integer Any)
    (for/hasheqv : (HashTable Integer Any)
                 ([e (in-list enemy-units)]
                  #:when (and (u-alive? e) (> (u-tag e) 0)))
      (values (u-tag e) e)))
  (define ally-by-tag : (HashTable Integer Any)
    (for/hasheqv : (HashTable Integer Any)
                 ([a (in-list ally-units)]
                  #:when (and (u-alive? a) (> (u-tag a) 0)))
      (values (u-tag a) a)))

  (define cy-tbl (unit-mode-tracker-cyclone-locks tr))
  (for ([(ctag rec) (in-hash cy-tbl)])
    (define tgt (cyclone-lock-rec-active-target-tag rec))
    (when (> tgt 0)
      (define age (- current-frame (cyclone-lock-rec-lock-start-frame rec)))
      (define cy (hash-ref ally-by-tag ctag (lambda () #f)))
      (define en (hash-ref alive-enemy-by-tag tgt (lambda () #f)))
      (define broken?
        (or (>= age CYCLONE-LOCK-ON-CHANNEL-FRAMES)
            (not cy)
            (not en)
            (> (dist-2d (u-x cy) (u-y cy) (u-x en) (u-y en))
               (+ CYCLONE-TETHER-BREAK-RANGE 0.25))))
      (when broken?
        (hash-set! cy-tbl ctag
                   (cyclone-lock-rec (cyclone-lock-rec-last-cast-frame rec) 0 0))))))

;; =============================================================================
;; 1. Thor Cannon Mode Management (`52` <-> `691`)
;; =============================================================================

(define THOR-EXPLOSIVE-AIR-SYMS : (Listof Symbol)
  '(mutalisk phoenix viking viking-fighter banshee interceptor))

(define THOR-HIGH-IMPACT-TARGET-AIR-SYMS : (Listof Symbol)
  '(tempest carrier battlecruiser brood-lord broodlord colossus
    corruptor void-ray voidray viper liberator liberator-ag
    warp-prism warp-prism-phasing overseer overseer-siege-mode mothership))

(define THOR-CAPITAL-AIR-SYMS : (Listof Symbol)
  '(tempest carrier battlecruiser brood-lord broodlord colossus
    corruptor void-ray voidray viper mothership))

;; True if `sym` benefits from Thor Explosive Splash (`2364`).
(: thor-explosive-threat-air? (-> Symbol Boolean))
(define (thor-explosive-threat-air? sym)
  (not (not (memq sym THOR-EXPLOSIVE-AIR-SYMS))))

;; True if `sym` is massive/armored air or Colossus prioritized by High-Impact (`2362`).
(: thor-high-impact-target-air? (-> Symbol Boolean))
(define (thor-high-impact-target-air? sym)
  (not (not (memq sym THOR-HIGH-IMPACT-TARGET-AIR-SYMS))))

;; True if `sym` is capital/armored air blocking reversion from High-Impact inside 12.0 tiles.
(: thor-capital-air-sym? (-> Symbol Boolean))
(define (thor-capital-air-sym? sym)
  (not (not (memq sym THOR-CAPITAL-AIR-SYMS))))

;; Evaluates Thor morph safety guard: blocks morphing when critically low under fire
;; or surrounded by >= 3 high-DPS ground enemies within 6.5 tiles.
(: thor-morph-safe? (->* (Any (Listof Any)) (#:under-fire? (U Boolean 'auto)) Boolean))
(define (thor-morph-safe? thor-u enemy-units #:under-fire? [uf-arg 'auto])
  (define tx (u-x thor-u))
  (define ty (u-y thor-u))
  (define hp-rat (u-hp-ratio thor-u))
  (define-values (heavy-cnt ling-cnt zealot-cnt near-attacker?)
    (for/fold ([heavy : Integer 0]
               [lings : Integer 0]
               [zealots : Integer 0]
               [att? : Boolean #f])
              ([e (in-list enemy-units)]
               #:when (u-alive? e))
      (define d (dist-2d tx ty (u-x e) (u-y e)))
      (define et (exact-unit-type e))
      (define has-threat?
        (and (<= d (+ (max 6.0 (u-weapon-range e)) 1.5))
             (not (memq et '(observer overseer overlord larva egg)))))
      (define in-close-ground?
        (and (not (u-flying? e)) (<= d THOR-MORPH-SAFETY-GROUND-RADIUS)))
      (values (if (and in-close-ground?
                       (memq et '(immortal marauder siege-tank-sieged lurker-burrowed)))
                  (add1 heavy)
                  heavy)
              (if (and in-close-ground? (eq? et 'zergling)) (add1 lings) lings)
              (if (and in-close-ground? (eq? et 'zealot)) (add1 zealots) zealots)
              (or att? has-threat?))))
  (define under-fire?
    (if (boolean? uf-arg)
        uf-arg
        (or (u-under-fire? thor-u) near-attacker?)))
  (define low-hp-block?
    (and (< hp-rat THOR-MORPH-SAFETY-HP-RATIO) under-fire?))
  (define dps-swarm-block?
    (or (>= heavy-cnt THOR-MORPH-SAFETY-DPS-THREATS)
        (>= ling-cnt 8)
        (>= zealot-cnt 4)))
  (not (or low-hp-block? dps-swarm-block?)))

;; Evaluates a single Thor (`'thor` / `'thor-ap`) and returns a mode-switch directive or `#f`.
(: evaluate-thor-mode
   (->* (Any (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:under-fire? (U Boolean 'auto))
        (Option unit-mode-directive)))
(define (evaluate-thor-mode thor-u enemy-units
                            #:tracker [tr #f]
                            #:current-frame [current-frame 0]
                            #:under-fire? [uf-arg 'auto])
  (define ut (exact-unit-type thor-u))
  (define tag (u-tag thor-u))
  (cond
    [(or (not (u-alive? thor-u)) (not (memq ut '(thor thor-ap)))) #f]
    [else
     (define tx (u-x thor-u))
     (define ty (u-y thor-u))
     (define high-impact-now? (eq? ut 'thor-ap))
     (define dwell-ok?
       (or (not tr)
           (>= (unit-mode-tracker-thor-dwell-elapsed tr tag current-frame)
               THOR-MODE-DWELL-FRAMES)))
     (cond
       [(not dwell-ok?) #f]
       [(not (thor-morph-safe? thor-u enemy-units #:under-fire? uf-arg)) #f]
       [else
        (define-values (global-muta muta-13 phoenix-13 viking-13 banshee-13
                        cap-air-12 massive-15 light-11)
          (for/fold ([gmuta : Integer 0]
                     [m13 : Integer 0]
                     [p13 : Integer 0]
                     [v13 : Integer 0]
                     [b13 : Integer 0]
                     [cap12 : Integer 0]
                     [mass15 : Integer 0]
                     [lt11 : Integer 0])
                    ([e (in-list enemy-units)]
                     #:when (u-alive? e))
            (define et (exact-unit-type e))
            (define d (dist-2d tx ty (u-x e) (u-y e)))
            (values (if (eq? et 'mutalisk) (add1 gmuta) gmuta)
                    (if (and (eq? et 'mutalisk) (<= d THOR-EXPLOSIVE-AIR-SCAN-RADIUS)) (add1 m13) m13)
                    (if (and (eq? et 'phoenix) (<= d THOR-EXPLOSIVE-AIR-SCAN-RADIUS)) (add1 p13) p13)
                    (if (and (memq et '(viking viking-fighter)) (<= d THOR-EXPLOSIVE-AIR-SCAN-RADIUS)) (add1 v13) v13)
                    (if (and (eq? et 'banshee) (<= d THOR-EXPLOSIVE-AIR-SCAN-RADIUS)) (add1 b13) b13)
                    (if (and (thor-capital-air-sym? et) (<= d THOR-EXPLOSIVE-CAPITAL-CHECK-RADIUS)) (add1 cap12) cap12)
                    (if (and (thor-high-impact-target-air? et) (<= d THOR-HIGH-IMPACT-SCAN-RADIUS)) (add1 mass15) mass15)
                    (if (and (thor-explosive-threat-air? et) (<= d THOR-HIGH-IMPACT-LIGHT-BLOCK-RADIUS)) (add1 lt11) lt11))))
        (define keep-explosive-for-mutas?
          (>= global-muta THOR-EXPLOSIVE-MUTALISK-MIN))
        (define explosive-clump?
          (and (zero? cap-air-12)
               (or keep-explosive-for-mutas?
                   (>= muta-13 3)
                   (>= phoenix-13 3)
                   (>= viking-13 4)
                   (>= banshee-13 3))))
        (define want-high-impact?
          (and (not keep-explosive-for-mutas?)
               (> massive-15 0)
               (< light-11 4)))
        (cond
          [(and (not high-impact-now?) want-high-impact?)
           (when tr
             (record-mode-switch! (unit-mode-tracker-thor-modes tr) tag current-frame 'high-impact))
           (unit-mode-directive tag ut 'cast-spell 'morph-thor-high-impact
                                MORPH-THOR-HIGH-IMPACT-ABILITY-ID tag tx ty
                                'thor-high-impact-capital-air)]
          [(and high-impact-now? explosive-clump?)
           (when tr
             (record-mode-switch! (unit-mode-tracker-thor-modes tr) tag current-frame 'explosive))
           (unit-mode-directive tag ut 'cast-spell 'morph-thor-explosive
                                MORPH-THOR-EXPLOSIVE-ABILITY-ID tag tx ty
                                'thor-explosive-light-air-clump)]
          [else #f])])]))

;; Plans Thor cannon-mode directives across all friendly Thors.
(: plan-thor-modes
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker) #:current-frame Integer)
        (Listof unit-mode-directive)))
(define (plan-thor-modes ally-units enemy-units #:tracker [tr #f] #:current-frame [current-frame 0])
  (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
            ([a (in-list ally-units)])
    (define d (evaluate-thor-mode a enemy-units #:tracker tr #:current-frame current-frame))
    (if d (cons d acc) acc)))

;; =============================================================================
;; 2. Hellion (`53`) <-> Hellbat (`484`) Mode Management
;; =============================================================================

(define HELLBAT-PRIMARY-MELEE-LIGHT-SYMS : (Listof Symbol)
  '(zergling baneling zealot adept hydralisk marine broodling))

(define TERRAN-BIO-ARMY-SYMS : (Listof Symbol)
  '(marine marauder ghost medivac))

(define TERRAN-BIO-MECH-ARMY-SYMS : (Listof Symbol)
  '(marine marauder ghost medivac siege-tank siege-tank-sieged thor thor-ap cyclone))

(: ally-armory-completed? (-> (Listof Any) Boolean))
(define (ally-armory-completed? ally-units)
  (for/or : Boolean ([a (in-list ally-units)])
    (and (u-alive? a)
         (eq? (exact-unit-type a) 'armory)
         (u-completed? a))))

(: main-army-centroid (-> (Listof Any) (Values Boolean Float Float Boolean)))
(define (main-army-centroid ally-units)
  (define-values (sx sy cnt bio?)
    (for/fold ([ax : Float 0.0]
               [ay : Float 0.0]
               [n : Integer 0]
               [has-bio? : Boolean #f])
              ([a (in-list ally-units)]
               #:when (u-alive? a))
      (define at (exact-unit-type a))
      (if (memq at TERRAN-BIO-MECH-ARMY-SYMS)
          (values (+ ax (u-x a))
                  (+ ay (u-y a))
                  (add1 n)
                  (or has-bio? (not (not (memq at TERRAN-BIO-ARMY-SYMS)))))
          (values ax ay n has-bio?))))
  (if (> cnt 0)
      (values #t (/ sx (->float cnt)) (/ sy (->float cnt)) bio?)
      (values #f 0.0 0.0 #f)))

;; Evaluates Hellion <-> Hellbat transformation using `#115` pre-engagement & commitment dwells.
(: evaluate-hellion-mode
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:armory-ready? (U Boolean 'auto)
         #:worker-runby? (U Boolean 'auto))
        (Option unit-mode-directive)))
(define (evaluate-hellion-mode unit enemy-units ally-units
                               #:tracker [tr #f]
                               #:current-frame [current-frame 0]
                               #:armory-ready? [armory-arg 'auto]
                               #:worker-runby? [runby-arg 'auto])
  (define ut (exact-unit-type unit))
  (define tag (u-tag unit))
  (define armory-ok?
    (if (eq? armory-arg 'auto)
        (ally-armory-completed? ally-units)
        (not (not armory-arg))))
  (define runby?
    (if (boolean? runby-arg)
        runby-arg
        (u-worker-runby? unit)))
  (cond
    [(or (not (u-alive? unit))
         (not (memq ut '(hellion hellbat)))
         (not armory-ok?))
     #f]
    [else
     (define ux (u-x unit))
     (define uy (u-y unit))
     (define is-hellbat? (eq? ut 'hellbat))
     (define dwell
       (if tr
           (unit-mode-tracker-hellbat-dwell-elapsed tr tag current-frame)
           10000))
     (define-values (has-army? acx acy has-bio?) (main-army-centroid ally-units))
     (define near-main-army?
       (and has-army? (<= (dist-2d ux uy acx acy) HELLBAT-ARMY-COHESION-RANGE)))

     (define-values (squad-18 roach-18 ground-combat-18 ground-threat-22)
       (for/fold ([sq18 : Integer 0]
                  [rch18 : Integer 0]
                  [gc18 : Boolean #f]
                  [gt22 : Boolean #f])
                 ([e (in-list enemy-units)]
                  #:when (and (u-alive? e) (not (u-flying? e))))
         (define et (exact-unit-type e))
         (define d (dist-2d ux uy (u-x e) (u-y e)))
         (define is-ground-combat?
           (and (not (memq et '(drone probe scv mule larva egg)))
                (or (not (u-structure? e))
                    (memq et '(photon-cannon bunker planetary-fortress spine-crawler)))))
         (values (if (and (<= d HELLBAT-PREENGAGE-RANGE)
                          (memq et HELLBAT-PRIMARY-MELEE-LIGHT-SYMS))
                     (add1 sq18)
                     sq18)
                 (if (and (<= d HELLBAT-PREENGAGE-RANGE) (eq? et 'roach))
                     (add1 rch18)
                     rch18)
                 (or gc18 (and is-ground-combat? (<= d HELLBAT-PREENGAGE-RANGE)))
                 (or gt22 (and is-ground-combat? (<= d HELLBAT-UNMORPH-CLEAR-RADIUS))))))

     (define bio-roach-squad-count (+ squad-18 (if has-bio? roach-18 0)))
     (cond
       ;; Hellion -> Hellbat pre-engagement morph (requires 96f hysteresis, skipped during worker runby)
       [(and (not is-hellbat?)
             (not runby?)
             (>= dwell HELLBAT-PREENGAGE-HYSTERESIS-FRAMES)
             (or (>= bio-roach-squad-count 3)
                 (and near-main-army? ground-combat-18)))
        (when tr
          (record-mode-switch! (unit-mode-tracker-hellion-modes tr) tag current-frame 'hellbat))
        (unit-mode-directive tag ut 'cast-spell 'morph-hellbat
                             MORPH-HELLBAT-ABILITY-ID tag ux uy
                             (if (>= bio-roach-squad-count 3)
                                 'hellbat-preengage-melee-light-squad
                                 'hellbat-escort-main-army))]
       ;; Hellbat -> Hellion unmorph ONLY after >= 176f AND (zero threats <= 22.0 OR worker runby)
       [(and is-hellbat?
             (>= dwell HELLBAT-MIN-COMMIT-DWELL-FRAMES)
             (or runby? (not ground-threat-22)))
        (when tr
          (record-mode-switch! (unit-mode-tracker-hellion-modes tr) tag current-frame 'hellion))
        (unit-mode-directive tag ut 'cast-spell 'morph-hellion
                             MORPH-HELLION-ABILITY-ID tag ux uy
                             (if runby? 'hellion-worker-runby 'hellion-area-clear-mobility))]
       [else #f])]))

;; Plans Hellion <-> Hellbat mode directives across all friendly Hellions/Hellbats.
(: plan-hellion-modes
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:armory-ready? (U Boolean 'auto))
        (Listof unit-mode-directive)))
(define (plan-hellion-modes ally-units enemy-units
                            #:tracker [tr #f]
                            #:current-frame [current-frame 0]
                            #:armory-ready? [armory-arg 'auto])
  (define armory-ok?
    (if (eq? armory-arg 'auto)
        (ally-armory-completed? ally-units)
        (not (not armory-arg))))
  (if (not armory-ok?)
      '()
      (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
                ([a (in-list ally-units)])
        (define d (evaluate-hellion-mode a enemy-units ally-units
                                         #:tracker tr
                                         #:current-frame current-frame
                                         #:armory-ready? #t))
        (if d (cons d acc) acc))))

;; =============================================================================
;; 3. Viking (`35` <-> `34`) Landing & Lift-Off
;; =============================================================================

(define VIKING-NON-COMBAT-AIR-SYMS : (Listof Symbol)
  '(observer observer-siege-mode overlord
    changeling changeling-zealot changeling-marine-shield changeling-marine
    changeling-zergling-wings changeling-zergling))

(define VIKING-CAPITAL-AIR-SYMS : (Listof Symbol)
  '(colossus carrier tempest battlecruiser brood-lord broodlord mothership))

(define VIKING-GROUND-ANTI-MECH-SPLASH-SYMS : (Listof Symbol)
  '(siege-tank-sieged lurker-burrowed lurker-mp-burrowed
    baneling immortal archon ultralisk disruptor disruptor-phased))

;; True if `sym` is enemy combat air or Colossus (allows non-combat `'observer`/`'overlord`).
(: viking-combat-air-or-colossus-sym? (-> Symbol Boolean))
(define (viking-combat-air-or-colossus-sym? sym)
  (cond
    [(eq? sym 'colossus) #t]
    [(memq sym VIKING-NON-COMBAT-AIR-SYMS) #f]
    [(memq sym '(tempest carrier battlecruiser brood-lord broodlord mothership
                 void-ray voidray corruptor mutalisk phoenix viking viking-fighter
                 liberator liberator-ag banshee raven oracle viper medivac
                 warp-prism warp-prism-phasing overlord-transport overseer
                 overseer-siege-mode interceptor))
     #t]
    [else (sc2-unit-is-flying-sym? sym)]))

;; True if `sym` is capital air or Colossus triggering 64f emergency liftoff inside 15.0 tiles.
(: viking-capital-air-sym? (-> Symbol Boolean))
(define (viking-capital-air-sym? sym)
  (not (not (memq sym VIKING-CAPITAL-AIR-SYMS))))

;; True if `sym` is a banned ground anti-mech splash threat to Assault Vikings.
(: viking-ground-splash-sym? (-> Symbol Boolean))
(define (viking-ground-splash-sym? sym)
  (not (not (memq sym VIKING-GROUND-ANTI-MECH-SPLASH-SYMS))))

;; Computes safe Assault landing point `[4.5..5.5]` tiles from `(target-x, target-y)` toward base.
(: compute-viking-land-standoff (-> Real Real Real Real point2d))
(define (compute-viking-land-standoff target-x target-y home-x home-y)
  (define tx (->float target-x))
  (define ty (->float target-y))
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define mid-standoff (* 0.5 (+ VIKING-LAND-STANDOFF-MIN VIKING-LAND-STANDOFF-MAX)))
  (define raw (step-toward-2d tx ty hx hy mid-standoff))
  (clamp-playable-pt (point2d-x raw) (point2d-y raw)))

;; Estimates local ground Lanchester-style combat strength `sqrt(ehp * gdps)` (Vikings + ground).
(: local-ground-unit-strength (-> Any Symbol Float))
(define (local-ground-unit-strength u ut)
  (define ehp (u-total-ehp u))
  (define eff-ut (if (memq ut '(viking viking-fighter)) 'viking-assault ut))
  (define stats (sc2-unit-combat-stats eff-ut))
  (define gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0))
  (cond
    [(> gdps 0.0)
     (->float (sqrt (max 0.0 (* ehp gdps))))]
    [(u-structure? u)
     (->float (sqrt (max 0.0 (* 0.5 ehp))))]
    [else 5.0]))

(: local-ground-power-balance (-> Float Float (Listof Any) (Listof Any) (Values Float Float)))
(define (local-ground-power-balance vx vy ally-units enemy-units)
  (define local-r 12.0)
  (define ally-pwr
    (for/fold ([acc : Float 0.0])
              ([a (in-list ally-units)]
               #:when (u-alive? a))
      (define at (exact-unit-type a))
      (if (and (or (not (u-flying? a))
                   (memq at '(viking viking-fighter)))
               (not (u-structure? a))
               (<= (dist-2d vx vy (u-x a) (u-y a)) local-r))
          (+ acc (local-ground-unit-strength a at))
          acc)))
  (define enemy-pwr
    (for/fold ([acc : Float 0.0])
              ([e (in-list enemy-units)]
               #:when (u-alive? e))
      (define et (exact-unit-type e))
      (if (and (not (u-flying? e))
               (not (memq et '(larva egg changeling)))
               (<= (dist-2d vx vy (u-x e) (u-y e)) local-r))
          (+ acc (local-ground-unit-strength e et))
          acc)))
  (values ally-pwr enemy-pwr))

(: enemy-air-memory-has-threat? (-> (Option unit-mode-tracker) (Listof Any) Boolean))
(define (enemy-air-memory-has-threat? tr explicit-mem)
  (define explicit-threat?
    (for/or : Boolean ([item (in-list explicit-mem)])
      (and (if (or (hash? item) (mode-unit-input? item)) (u-alive? item) #t)
           (viking-combat-air-or-colossus-sym? (exact-unit-type item)))))
  (define tracker-threat?
    (and tr
         (for/or : Boolean ([(_ rec) (in-hash (unit-mode-tracker-remembered-enemy-air tr))])
           (viking-combat-air-or-colossus-sym? (remembered-air-rec-type rec)))))
  (or explicit-threat? tracker-threat?))

;; Evaluates a Viking (`'viking-fighter` / `'viking-assault`) for safe landing or liftoff.
(: evaluate-viking-mode
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:enemy-air-memory (Listof Any))
        (Option unit-mode-directive)))
(define (evaluate-viking-mode unit enemy-units ally-units
                              #:tracker [tr #f]
                              #:current-frame [current-frame 0]
                              #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                              #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                              #:enemy-air-memory [enemy-air-memory '()])
  (define ut (exact-unit-type unit))
  (define tag (u-tag unit))
  (cond
    [(or (not (u-alive? unit))
         (not (memq ut '(viking viking-fighter viking-assault))))
     #f]
    [else
     (define vx (u-x unit))
     (define vy (u-y unit))
     (define is-assault? (eq? ut 'viking-assault))
     (define hp-rat (u-hp-ratio unit))
     (define dwell
       (if tr
           (unit-mode-tracker-viking-dwell-elapsed tr tag current-frame)
           10000))

     (define-values (combat-air-22? combat-air-25? cap-air-15?
                     splash-9.5? splash-11.0? nearest-ground-tgt nearest-ground-dist)
       (for/fold ([ca22? : Boolean #f]
                  [ca25? : Boolean #f]
                  [cap15? : Boolean #f]
                  [sp95? : Boolean #f]
                  [sp11? : Boolean #f]
                  [best-g : Any #f]
                  [best-gd : Float +inf.0])
                 ([e (in-list enemy-units)]
                  #:when (u-alive? e))
         (define et (exact-unit-type e))
         (define d (dist-2d vx vy (u-x e) (u-y e)))
         (define ca? (viking-combat-air-or-colossus-sym? et))
         (define cap? (viking-capital-air-sym? et))
         (define sp? (and (not (u-flying? e)) (viking-ground-splash-sym? et)))
         (define attackable-ground?
           (and (not (u-flying? e))
                (not (memq et '(larva egg)))))
         (define-values (ng ngd)
           (if (and attackable-ground? (<= d VIKING-LAND-GROUND-TARGET-RADIUS) (< d best-gd))
               (values e d)
               (values best-g best-gd)))
         (values (or ca22? (and ca? (<= d VIKING-LAND-SAFE-AIR-RADIUS)))
                 (or ca25? (and ca? (<= d VIKING-LIFTOFF-AIR-RADIUS)))
                 (or cap15? (and cap? (<= d VIKING-EMERGENCY-CAPITAL-RADIUS)))
                 (or sp95? (and sp? (<= d VIKING-LIFTOFF-GROUND-SPLASH-RADIUS)))
                 (or sp11? (and sp? (<= d VIKING-LAND-GROUND-SPLASH-RADIUS)))
                 ng
                 ngd)))

     (define-values (ally-pwr enemy-pwr)
       (local-ground-power-balance vx vy ally-units enemy-units))
     (define air-mem-threat? (enemy-air-memory-has-threat? tr enemy-air-memory))

     (cond
       [is-assault?
        (define low-hp-lift? (< hp-rat VIKING-LIFTOFF-HP-RATIO))
        (define power-bad? (> enemy-pwr (* VIKING-LIFTOFF-POWER-THRESHOLD (max 1.0 ally-pwr))))
        (define emerg-cap-lift? (and cap-air-15? (>= dwell VIKING-EMERGENCY-LIFTOFF-DWELL-FRAMES)))
        (define air-lift? (and combat-air-25? (>= dwell VIKING-GROUND-DWELL-FRAMES)))
        (define lift-reason : (Option Symbol)
          (cond
            [low-hp-lift?    'viking-liftoff-low-hp]
            [splash-9.5?     'viking-liftoff-ground-splash]
            [power-bad?      'viking-liftoff-ground-power]
            [emerg-cap-lift? 'viking-liftoff-emergency-capital-air]
            [air-lift?       'viking-liftoff-combat-air]
            [else            #f]))
        (if lift-reason
            (begin
              (when tr
                (record-mode-switch! (unit-mode-tracker-viking-modes tr) tag current-frame 'fighter))
              (unit-mode-directive tag ut 'cast-spell 'morph-viking-fighter
                                   MORPH-VIKING-FIGHTER-ABILITY-ID tag vx vy lift-reason))
            #f)]
       [else
        (define power-super? (>= ally-pwr (* VIKING-LAND-POWER-RATIO (max 1.0 enemy-pwr))))
        (define can-land?
          (and (not combat-air-22?)
               (not air-mem-threat?)
               (>= hp-rat VIKING-LAND-MIN-HP-RATIO)
               (>= dwell VIKING-GROUND-DWELL-FRAMES)
               (not splash-11.0?)
               nearest-ground-tgt
               power-super?))
        (if can-land?
            (let ([land-pt (compute-viking-land-standoff
                            (u-x nearest-ground-tgt)
                            (u-y nearest-ground-tgt)
                            home-x
                            home-y)])
              (when tr
                (record-mode-switch! (unit-mode-tracker-viking-modes tr) tag current-frame 'assault))
              (unit-mode-directive tag ut 'cast-spell 'morph-viking-assault
                                   MORPH-VIKING-ASSAULT-ABILITY-ID tag
                                   (point2d-x land-pt) (point2d-y land-pt)
                                   'viking-land-cleanup-superiority))
            #f)])]))

;; Plans Viking landing/liftoff directives across all friendly Vikings.
(: plan-viking-modes
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:enemy-air-memory (Listof Any))
        (Listof unit-mode-directive)))
(define (plan-viking-modes ally-units enemy-units
                           #:tracker [tr #f]
                           #:current-frame [current-frame 0]
                           #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                           #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                           #:enemy-air-memory [enemy-air-memory '()])
  (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
            ([a (in-list ally-units)])
    (define d (evaluate-viking-mode a enemy-units ally-units
                                    #:tracker tr
                                    #:current-frame current-frame
                                    #:home-x home-x
                                    #:home-y home-y
                                    #:enemy-air-memory enemy-air-memory))
    (if d (cons d acc) acc)))

;; =============================================================================
;; 4. Cyclone (`692`) Lock On (`2350`) & [8.5..13.5]-Tile Tether Kiting
;; =============================================================================

;; Target priority score for Cyclone Lock On within 6.5 tiles (never prefer 1 Zergling/Larva over high value).
(: cyclone-target-priority-score (-> Symbol Float Float Float))
(define (cyclone-target-priority-score sym ehp dist)
  (define base : Float
    (cond
      [(memq sym '(warp-prism warp-prism-phasing medivac overlord-transport))
       1000.0]
      [(memq sym '(immortal siege-tank siege-tank-sieged colossus
                   lurker lurker-burrowed lurker-mp lurker-mp-burrowed
                   thor thor-ap ultralisk))
       800.0]
      [(memq sym '(stalker void-ray voidray oracle roach ravager banshee
                   viking viking-fighter viking-assault tempest battlecruiser
                   corruptor carrier brood-lord broodlord overseer phoenix
                   liberator liberator-ag adept marauder queen))
       550.0]
      [(memq sym '(larva egg))
       -1000.0]
      [(eq? sym 'zergling)
       20.0]
      [else 150.0]))
  (+ base (* -0.05 ehp) (* -1.5 dist)))

(: compute-tether-orbit-point (-> Float Float Float Float Float Float point2d))
(define (compute-tether-orbit-point cx cy tx ty home-x home-y)
  (define rx (- cx tx))
  (define ry (- cy ty))
  (define r (dist-2d cx cy tx ty))
  (define-values (ux uy)
    (if (> r 1e-4)
        (values (/ rx r) (/ ry r))
        (values 1.0 0.0)))
  ;; Blend tangent orbit with slight home-base bias to stay away from enemy army core
  (define tang1-x (+ tx (* CYCLONE-TETHER-TARGET-KITE (- (* 0.85 ux) (* 0.52 uy)))))
  (define tang1-y (+ ty (* CYCLONE-TETHER-TARGET-KITE (+ (* 0.52 ux) (* 0.85 uy)))))
  (define tang2-x (+ tx (* CYCLONE-TETHER-TARGET-KITE (+ (* 0.85 ux) (* 0.52 uy)))))
  (define tang2-y (+ ty (* CYCLONE-TETHER-TARGET-KITE (- (* 0.85 uy) (* 0.52 ux)))))
  (define d1 (dist-2d tang1-x tang1-y home-x home-y))
  (define d2 (dist-2d tang2-x tang2-y home-x home-y))
  (if (<= d1 d2)
      (clamp-playable-pt tang1-x tang1-y)
      (clamp-playable-pt tang2-x tang2-y)))

(: compute-tether-kite-point (-> Float Float Float Float Float Float Float point2d))
(define (compute-tether-kite-point cx cy tx ty home-x home-y desired-radius)
  (define away-x (- cx tx))
  (define away-y (- cy ty))
  (define d (dist-2d cx cy tx ty))
  (define-values (ax ay)
    (if (> d 1e-4)
        (values (/ away-x d) (/ away-y d))
        (let ([hd (max 1e-4 (dist-2d tx ty home-x home-y))])
          (values (/ (- home-x tx) hd) (/ (- home-y ty) hd)))))
  (define hx (- home-x cx))
  (define hy (- home-y cy))
  (define hd (dist-2d cx cy home-x home-y))
  (define-values (bx by)
    (if (> hd 1e-4)
        (values (+ (* 0.70 ax) (* 0.30 (/ hx hd)))
                (+ (* 0.70 ay) (* 0.30 (/ hy hd))))
        (values ax ay)))
  (define blen (max 1e-4 (dist-2d 0.0 0.0 bx by)))
  (define step (max 2.5 (- desired-radius d)))
  (clamp-playable-pt (+ cx (* step (/ bx blen)))
                     (+ cy (* step (/ by blen)))))

;; Evaluates a Cyclone (`'cyclone` 692) for Lock On (`2350`) or [8.5..13.5]-tile tether kiting.
;; Never issues a manual Lock-On cancel (`0%` cancel rate per `#115`).
(: evaluate-cyclone-micro
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:claimed-targets (Option (Mutable-HashTable Integer Boolean)))
        (Option unit-mode-directive)))
(define (evaluate-cyclone-micro cy enemy-units _ally-units
                                #:tracker [tr #f]
                                #:current-frame [current-frame 0]
                                #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                #:claimed-targets [claimed-targets #f])
  (define ut (exact-unit-type cy))
  (define tag (u-tag cy))
  (cond
    [(or (not (u-alive? cy)) (not (eq? ut 'cyclone))) #f]
    [else
     (define cx (u-x cy))
     (define cy-y (u-y cy))
     (define fhx (->float home-x))
     (define fhy (->float home-y))
     (define-values (locked-tag lock-age cd-rem)
       (if tr
           (unit-mode-tracker-cyclone-lock-state tr tag current-frame)
           (values 0 0 0)))
     (define locked-enemy : (Option Any)
       (and (> locked-tag 0)
            (< lock-age CYCLONE-LOCK-ON-CHANNEL-FRAMES)
            (let loop ([es : (Listof Any) enemy-units])
              (cond
                [(null? es) #f]
                [(and (u-alive? (car es)) (= (u-tag (car es)) locked-tag)) (car es)]
                [else (loop (cdr es))]))))
     (cond
       ;; Active Lock-On channel -> maintain [8.5..13.5]-tile tether envelope (NEVER cancel)
       [(and locked-enemy
             (<= (dist-2d cx cy-y (u-x locked-enemy) (u-y locked-enemy))
                 CYCLONE-TETHER-BREAK-RANGE))
        (define lx (u-x locked-enemy))
        (define ly (u-y locked-enemy))
        (define d (dist-2d cx cy-y lx ly))
        (define erange (u-weapon-range locked-enemy))
        (define nearest-close-threat
          (for/fold ([best : (Option Any) #f]
                     [bd : Float CYCLONE-CLOSE-THREAT-RADIUS]
                     #:result best)
                    ([e (in-list enemy-units)]
                     #:when (and (u-alive? e)
                                 (not (= (u-tag e) locked-tag))
                                 (not (memq (exact-unit-type e) '(larva egg observer overlord)))))
            (define ed (dist-2d cx cy-y (u-x e) (u-y e)))
            (if (< ed bd) (values e ed) (values best bd))))
        (cond
          [(> d CYCLONE-TETHER-ORBIT-MAX)
           (define step-pt (step-toward-2d cx cy-y lx ly (max 0.5 (- d CYCLONE-TETHER-MAX-RECLOSE))))
           (define cpt (clamp-playable-pt (point2d-x step-pt) (point2d-y step-pt)))
           (unit-mode-directive tag ut 'move #f 0 locked-tag
                                (point2d-x cpt) (point2d-y cpt)
                                'cyclone-tether-reclose)]
          [(or (< d CYCLONE-TETHER-MIN-DIST)
               (< d (+ erange 2.0)))
           (define kpt (compute-tether-kite-point cx cy-y lx ly fhx fhy CYCLONE-TETHER-TARGET-KITE))
           (unit-mode-directive tag ut 'kite #f 0 locked-tag
                                (point2d-x kpt) (point2d-y kpt)
                                'cyclone-tether-kite-away)]
          [nearest-close-threat
           (define kpt (compute-tether-kite-point cx cy-y
                                                  (u-x nearest-close-threat)
                                                  (u-y nearest-close-threat)
                                                  fhx fhy 9.5))
           (unit-mode-directive tag ut 'kite #f 0 (u-tag nearest-close-threat)
                                (point2d-x kpt) (point2d-y kpt)
                                'cyclone-tether-evade-close-threat)]
          [else
           (define opt (compute-tether-orbit-point cx cy-y lx ly fhx fhy))
           (unit-mode-directive tag ut 'move #f 0 locked-tag
                                (point2d-x opt) (point2d-y opt)
                                'cyclone-tether-orbit)])]

       ;; Ready to Lock On (`cd-rem == 0`) within 6.5 tiles
       [(zero? cd-rem)
        (define-values (best-tgt best-score)
          (for/fold ([bt : (Option Any) #f]
                     [bs : Float -1e9])
                    ([e (in-list enemy-units)]
                     #:when (u-alive? e))
            (define et (exact-unit-type e))
            (define etag (u-tag e))
            (define d (dist-2d cx cy-y (u-x e) (u-y e)))
            (cond
              [(or (> etag 0) (= etag 0))
               (define valid?
                 (and (> etag 0)
                      (<= d CYCLONE-LOCK-ON-CAST-RANGE)
                      (not (memq et '(larva egg)))
                      (not (u-structure? e))))
               (if (not valid?)
                   (values bt bs)
                   (let* ([already-claimed?
                           (and claimed-targets (hash-has-key? claimed-targets etag))]
                          [sc0 (cyclone-target-priority-score et (u-total-ehp e) d)]
                          [sc (if already-claimed? (- sc0 300.0) sc0)])
                     (if (> sc bs)
                         (values e sc)
                         (values bt bs))))]
              [else (values bt bs)])))
        (cond
          [best-tgt
           (define btag (u-tag best-tgt))
           (when claimed-targets
             (hash-set! claimed-targets btag #t))
           (when tr
             (hash-set! (unit-mode-tracker-cyclone-locks tr)
                        tag
                        (cyclone-lock-rec current-frame btag current-frame)))
           (unit-mode-directive tag ut 'cast-spell 'lock-on
                                CYCLONE-LOCK-ON-ABILITY-ID btag
                                (u-x best-tgt) (u-y best-tgt)
                                'cyclone-lock-on-acquire)]
          [else
           ;; No Lock On target in 6.5 tiles, check if close enemy threatens < 7.0
           (define close-e : (Option Any)
             (let loop ([es : (Listof Any) enemy-units])
               (cond
                 [(null? es) #f]
                 [(let ([e (car es)])
                    (and (u-alive? e)
                         (not (memq (exact-unit-type e) '(larva egg)))
                         (< (dist-2d cx cy-y (u-x e) (u-y e))
                            CYCLONE-CLOSE-THREAT-RADIUS)))
                  (car es)]
                 [else (loop (cdr es))])))
           (if close-e
               (let ([kpt (compute-tether-kite-point cx cy-y (u-x close-e) (u-y close-e) fhx fhy 9.0)])
                 (unit-mode-directive tag ut 'kite #f 0 (u-tag close-e)
                                      (point2d-x kpt) (point2d-y kpt)
                                      'cyclone-cooldown-kite-safety))
               #f)])]

       ;; Lock On on cooldown: keep safe standoff from closest threat < 9.0
       [else
        (define near-e
          (for/fold ([best : (Option Any) #f]
                     [bd : Float 9.0]
                     #:result best)
                    ([e (in-list enemy-units)]
                     #:when (and (u-alive? e)
                                 (not (memq (exact-unit-type e) '(larva egg observer overlord)))))
            (define ed (dist-2d cx cy-y (u-x e) (u-y e)))
            (if (< ed bd) (values e ed) (values best bd))))
        (if near-e
            (let ([kpt (compute-tether-kite-point cx cy-y (u-x near-e) (u-y near-e) fhx fhy 9.5)])
              (unit-mode-directive tag ut 'kite #f 0 (u-tag near-e)
                                   (point2d-x kpt) (point2d-y kpt)
                                   'cyclone-cooldown-kite))
            #f)])]))

;; Plans Lock-On and tether-kiting directives across all friendly Cyclones.
(: plan-cyclone-micro
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real)
        (Listof unit-mode-directive)))
(define (plan-cyclone-micro ally-units enemy-units
                            #:tracker [tr #f]
                            #:current-frame [current-frame 0]
                            #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                            #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y])
  (define claimed : (Mutable-HashTable Integer Boolean) (make-hasheqv))
  (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
            ([a (in-list ally-units)])
    (define d (evaluate-cyclone-micro a enemy-units ally-units
                                      #:tracker tr
                                      #:current-frame current-frame
                                      #:home-x home-x
                                      #:home-y home-y
                                      #:claimed-targets claimed))
    (if d (cons d acc) acc)))

;; =============================================================================
;; 5. Marauder (`51`) Concussive Shells (`32f`) Target Spreading
;; =============================================================================

(define MASSIVE-GROUND-SYMS : (Listof Symbol)
  '(thor thor-ap ultralisk ultralisk-burrowed colossus archon mothership))

;; True if ground unit type `sym` is Massive (immune to Concussive Shells slow).
(: massive-ground-unit-sym? (-> Symbol Boolean))
(define (massive-ground-unit-sym? sym)
  (not (not (memq sym MASSIVE-GROUND-SYMS))))

;; Plans same-frame Marauder target selections spreading Concussive Shells (`+32f` slow
;; timestamp per target) across N distinct non-massive ground targets, preserving
;; (a) lethal finish (`<= 35` HP+shield) and (b) massive-only exceptions.
(: plan-marauder-concussive-targets
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:concussive-shells-researched? Boolean)
        (Listof marauder-target-order)))
(define (plan-marauder-concussive-targets ally-units enemy-units
                                          #:tracker [tr #f]
                                          #:current-frame [current-frame 0]
                                          #:concussive-shells-researched? [researched? #t])
  (define active-tr (or tr (make-unit-mode-tracker)))
  (define ground-enemies
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (u-alive? e)
                                          (not (u-flying? e))
                                          (not (memq (exact-unit-type e) '(larva egg)))))
      e))
  ;; Track lethal focus slots per frame so 1-2 shots finish <=35 EHP targets while excess Marauders spread
  (define lethal-claim-cnt : (Mutable-HashTable Integer Integer) (make-hasheqv))
  (for/fold ([acc : (Listof marauder-target-order) '()] #:result (reverse acc))
            ([a (in-list ally-units)]
             #:when (and (u-alive? a)
                         (eq? (exact-unit-type a) 'marauder)))
    (define mid (u-tag a))
    (define mx (u-x a))
    (define my (u-y a))
    (define in-range
      (for/list : (Listof Any) ([e (in-list ground-enemies)]
                                #:when (<= (dist-2d mx my (u-x e) (u-y e))
                                           MARAUDER-ACQUIRE-MAX-RANGE))
        e))
    (cond
      [(null? in-range) acc]
      [else
       (define best-choice
         (for/fold ([best : (Option Any) #f]
                    [best-sc : Float -1e9]
                    #:result best)
                   ([e (in-list in-range)])
           (define etag (u-tag e))
           (define et (exact-unit-type e))
           (define d (dist-2d mx my (u-x e) (u-y e)))
           (define ehp (u-total-ehp e))
           (define massive? (massive-ground-unit-sym? et))
           (define struct? (u-structure? e))
           (define slowed-now? (unit-mode-tracker-enemy-slowed? active-tr etag current-frame))
           (define lethal? (and (<= ehp MARAUDER-LETHAL-FINISH-EHP)
                                (< (hash-ref lethal-claim-cnt etag (lambda () 0)) 2)))
           (define range-penalty (if (<= d (+ MARAUDER-WEAPON-RANGE 0.25)) 0.0 -80.0))
           (define sc : Float
             (cond
               [(not researched?)
                (+ (if lethal? 400.0 0.0) range-penalty (* -0.5 ehp) (* -3.0 d))]
               [lethal?
                (+ 2000.0 range-penalty (* -1.0 ehp) (* -2.0 d))]
               [(and (not massive?) (not struct?) (not slowed-now?))
                ;; Unslowed non-massive combat ground unit gets top spreading priority
                (+ 1000.0 range-penalty (* -0.2 ehp) (* -3.0 d))]
               [(and massive? (not struct?))
                (+ 250.0 range-penalty (* -0.1 ehp) (* -3.0 d))]
               [(not struct?)
                ;; Already-slowed non-massive fallback when all else is slowed
                (+ 150.0 range-penalty (* -0.2 ehp) (* -3.0 d))]
               [else
                (+ -200.0 range-penalty (* -3.0 d))]))
           (if (> sc best-sc)
               (values e sc)
               (values best best-sc))))
       (cond
         [(not best-choice) acc]
         [else
          (define etag (u-tag best-choice))
          (define et (exact-unit-type best-choice))
          (define ehp (u-total-ehp best-choice))
          (define massive? (massive-ground-unit-sym? et))
          (define lethal? (<= ehp MARAUDER-LETHAL-FINISH-EHP))
          (define was-slowed? (unit-mode-tracker-enemy-slowed? active-tr etag current-frame))
          (define reason : Symbol
            (cond
              [(not researched?) 'marauder-focus-no-concussive]
              [lethal?           'marauder-lethal-finish-exception]
              [(and (not massive?) (not was-slowed?))
               'marauder-spread-concussive-slow]
              [massive?          'marauder-massive-only-exception]
              [else              'marauder-all-targets-already-slowed]))
          (when lethal?
            (hash-set! lethal-claim-cnt etag (add1 (hash-ref lethal-claim-cnt etag (lambda () 0)))))
          (when (and researched? (not massive?) (not (u-structure? best-choice)))
            (unit-mode-tracker-mark-enemy-slowed! active-tr etag current-frame))
          (cons (marauder-target-order mid etag (u-x best-choice) (u-y best-choice)
                                       was-slowed? lethal? massive? reason)
                acc)])])))

;; =============================================================================
;; 6. Unified S-Expression Action Conversion & Orchestrator
;; =============================================================================

;; Converts a `unit-mode-directive` into a runtime-compatible S-expression command.
(: unit-mode-directive->sexp (-> unit-mode-directive (Listof Any)))
(define (unit-mode-directive->sexp d)
  (case (unit-mode-directive-action d)
    [(cast-spell)
     (define ab (unit-mode-directive-ability d))
     (define tgt (unit-mode-directive-target-tag d))
     (list 'cast-spell
           (unit-mode-directive-unit-tag d)
           (or ab 'unknown)
           (if (> tgt 0) tgt (unit-mode-directive-unit-tag d)))]
    [(move kite)
     (list (unit-mode-directive-action d)
           (unit-mode-directive-unit-tag d)
           (unit-mode-directive-tx d)
           (unit-mode-directive-ty d))]
    [else
     (list 'attack-unit
           (unit-mode-directive-unit-tag d)
           (unit-mode-directive-target-tag d))]))

;; Converts a `marauder-target-order` into an `attack-unit` S-expression command.
(: marauder-order->sexp (-> marauder-target-order (Listof Any)))
(define (marauder-order->sexp o)
  (list 'attack-unit
        (marauder-target-order-unit-tag o)
        (marauder-target-order-target-tag o)))

;; Runs all 5 unit-mode & micro planners for the current frame and returns S-exp orders.
(: step-unit-mode-micro!
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:armory-ready? (U Boolean 'auto)
         #:concussive-shells-researched? Boolean
         #:enemy-air-memory (Listof Any)
         #:dead-tags (Listof Integer)
         #:track-air-memory? Boolean)
        (Listof (Listof Any))))
(define (step-unit-mode-micro! ally-units enemy-units
                               #:tracker [tr-arg #f]
                               #:current-frame [current-frame 0]
                               #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                               #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                               #:armory-ready? [armory-arg 'auto]
                               #:concussive-shells-researched? [concussive-ok? #t]
                               #:enemy-air-memory [enemy-air-memory '()]
                               #:dead-tags [dead-tags '()]
                               #:track-air-memory? [track-air-memory? #f])
  (define tr (or tr-arg (make-unit-mode-tracker)))
  (sync-unit-mode-tracker! tr ally-units enemy-units current-frame
                           #:dead-tags dead-tags
                           #:track-air-memory? track-air-memory?)
  (define thor-dirs
    (plan-thor-modes ally-units enemy-units #:tracker tr #:current-frame current-frame))
  (define hellion-dirs
    (plan-hellion-modes ally-units enemy-units #:tracker tr #:current-frame current-frame
                        #:armory-ready? armory-arg))
  (define viking-dirs
    (plan-viking-modes ally-units enemy-units #:tracker tr #:current-frame current-frame
                       #:home-x home-x #:home-y home-y
                       #:enemy-air-memory enemy-air-memory))
  (define cyclone-dirs
    (plan-cyclone-micro ally-units enemy-units #:tracker tr #:current-frame current-frame
                        #:home-x home-x #:home-y home-y))
  (define marauder-orders
    (plan-marauder-concussive-targets ally-units enemy-units #:tracker tr #:current-frame current-frame
                                      #:concussive-shells-researched? concussive-ok?))
  (append
   (map unit-mode-directive->sexp thor-dirs)
   (map unit-mode-directive->sexp hellion-dirs)
   (map unit-mode-directive->sexp viking-dirs)
   (map unit-mode-directive->sexp cyclone-dirs)
   (map marauder-order->sexp marauder-orders)))
