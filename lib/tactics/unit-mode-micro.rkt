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
           dyn-hash-has-key?
           dyn-u-raw-type
           dyn-u-raw-tag
           dyn-u-x
           dyn-u-y
           dyn-u-alive-fast)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (hash-ref h k (lambda () default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k)))
  (define (dyn-u-raw-type u)
    (if (hash? u)
        (or (hash-ref u 'unit-type #f)
            (hash-ref u 'unit_type #f)
            (hash-ref u 'type #f))
        #f))
  (define (dyn-u-raw-tag u)
    (if (hash? u)
        (or (hash-ref u 'tag #f)
            (hash-ref u 'id 0))
        0))
  (define (to-fl v default)
    (cond
      [(flonum? v) (if (< -inf.0 v +inf.0) v default)]
      [(and (real? v) (< -inf.0 v +inf.0)) (exact->inexact v)]
      [else default]))
  (define (dyn-u-x u)
    (if (hash? u) (to-fl (hash-ref u 'x 0.0) 0.0) 0.0))
  (define (dyn-u-y u)
    (if (hash? u) (to-fl (hash-ref u 'y 0.0) 0.0) 0.0))
  (define (dyn-u-alive-fast u)
    (cond
      [(not (hash? u)) 'false]
      [else
       (define hpv (hash-ref u 'hp #f))
       (cond
         [(and (real? hpv) (< 0.0 hpv +inf.0)) 'true]
         [(and (not hpv) (not (hash-has-key? u 'hp)))
          (define hv (hash-ref u 'health #f))
          (cond
            [(and (real? hv) (< 0.0 hv +inf.0)) 'true]
            [(or hv
                 (hash-has-key? u 'health)
                 (hash-has-key? u 'hull-hp)
                 (hash-has-key? u 'shield)
                 (hash-has-key? u 'shields))
             'check-ehp]
            [else 'true])]
         [else 'check-ehp])])))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)]
  [dyn-u-raw-type (-> Any Any)]
  [dyn-u-raw-tag (-> Any Any)]
  [dyn-u-x (-> Any Float)]
  [dyn-u-y (-> Any Float)]
  [dyn-u-alive-fast (-> Any Symbol)])

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
 unit-mode-tracker-widow-mine-dwell-elapsed
 unit-mode-tracker-cyclone-lock-state
 unit-mode-tracker-marauder-slow-until
 unit-mode-tracker-enemy-slowed?
 unit-mode-tracker-mark-enemy-slowed!
 unit-mode-tracker-record-enemy-air!
 unit-mode-tracker-prune-dead!
 sync-unit-mode-tracker!
 WIDOW-MINE-UNIT-TYPE-ID
 WIDOW-MINE-BURROWED-UNIT-TYPE-ID
 WIDOW-MINE-UNBURROW-ABILITY-ID
 WIDOW-MINE-BURROW-ENEMY-RANGE
 WIDOW-MINE-UNBURROW-CLEAR-RADIUS
 WIDOW-MINE-UNBURROW-ARMY-DIST
 WIDOW-MINE-MODE-COOLDOWN-FRAMES
 UNIT-MODE-TRANSPORT-LOAD-COOLDOWN-FRAMES
 SIEGE-TANK-SPLASH-RADIUS
 evaluate-widow-mine-mode
 plan-widow-mine-modes
 siege-tank-target-safe?
 plan-siege-tank-targets

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

  ;; Wave 1C Counter-Unit-Mode Micro (Cyclone Lock-On Break, Hellbat Kite, Viking/Thor Counter)
  COUNTER-CYCLONE-TETHER-BREAK-TARGET
  COUNTER-CYCLONE-PICKUP-MAX-DIST
  COUNTER-HELLBAT-KITE-RANGE
  break-enemy-cyclone-lock-on
  plan-counter-unit-mode-micro

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

(: WIDOW-MINE-UNIT-TYPE-ID Integer)
(define WIDOW-MINE-UNIT-TYPE-ID 498)

(: WIDOW-MINE-BURROWED-UNIT-TYPE-ID Integer)
(define WIDOW-MINE-BURROWED-UNIT-TYPE-ID 500)

(: WIDOW-MINE-BURROW-ABILITY-ID Integer)
(define WIDOW-MINE-BURROW-ABILITY-ID 2095)

(: WIDOW-MINE-UNBURROW-ABILITY-ID Integer)
(define WIDOW-MINE-UNBURROW-ABILITY-ID 2097)

(: WIDOW-MINE-BURROW-ENEMY-RANGE Float)
(define WIDOW-MINE-BURROW-ENEMY-RANGE 11.5)

(: WIDOW-MINE-UNBURROW-CLEAR-RADIUS Float)
(define WIDOW-MINE-UNBURROW-CLEAR-RADIUS 15.5)

(: WIDOW-MINE-UNBURROW-ARMY-DIST Float)
(define WIDOW-MINE-UNBURROW-ARMY-DIST 18.0)

(: WIDOW-MINE-MODE-COOLDOWN-FRAMES Integer)
(define WIDOW-MINE-MODE-COOLDOWN-FRAMES 44)

(: UNIT-MODE-TRANSPORT-LOAD-COOLDOWN-FRAMES Integer)
(define UNIT-MODE-TRANSPORT-LOAD-COOLDOWN-FRAMES 44)

(: SIEGE-TANK-SPLASH-RADIUS Float)
(define SIEGE-TANK-SPLASH-RADIUS 1.25)

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
   [remembered-enemy-air : (Mutable-HashTable Integer remembered-air-rec)]
   [widow-mine-modes : (Mutable-HashTable Integer mode-switch-rec)]
   [transport-last-load : (Mutable-HashTable Integer Integer)]))

;; Creates a fresh empty `unit-mode-tracker`.
(: make-unit-mode-tracker (-> unit-mode-tracker))
(define (make-unit-mode-tracker)
  (unit-mode-tracker
   (make-hasheqv)
   (make-hasheqv)
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

;; Returns elapsed frames since `tag` last switched WidowMine burrow mode (large default if unseen).
(: unit-mode-tracker-widow-mine-dwell-elapsed (-> unit-mode-tracker Integer Integer Integer))
(define (unit-mode-tracker-widow-mine-dwell-elapsed tr tag current-frame)
  (mode-dwell-elapsed (unit-mode-tracker-widow-mine-modes tr) tag current-frame))

(: unit-mode-tracker-transport-load-cooldown (-> unit-mode-tracker Integer Integer Integer))
(define (unit-mode-tracker-transport-load-cooldown tr tr-tag current-frame)
  (define last-f (hash-ref (unit-mode-tracker-transport-last-load tr) tr-tag (lambda () #f)))
  (if last-f
      (max 0 (- (+ last-f UNIT-MODE-TRANSPORT-LOAD-COOLDOWN-FRAMES) current-frame))
      0))

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
    (when (and (viking-combat-air-or-colossus-sym? ut) (u-alive? e))
      (define tag (u-tag e))
      (when (> tag 0)
        (hash-set! mem tag (remembered-air-rec tag ut current-frame))))))

;; Removes dead unit tags from all tracker tables (including remembered air threats).
(: unit-mode-tracker-prune-dead! (-> unit-mode-tracker (Listof Integer) Void))
(define (unit-mode-tracker-prune-dead! tr dead-tags)
  (define mem (unit-mode-tracker-remembered-enemy-air tr))
  (define slow-tbl (unit-mode-tracker-marauder-slow-table tr))
  (define wm-tbl (unit-mode-tracker-widow-mine-modes tr))
  (define tr-load-tbl (unit-mode-tracker-transport-last-load tr))
  (for ([dtag (in-list dead-tags)])
    (hash-remove! mem dtag)
    (hash-remove! slow-tbl dtag)
    (hash-remove! wm-tbl dtag)
    (hash-remove! tr-load-tbl dtag)))

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
     (define raw-ut (dyn-u-raw-type u))
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
     (define t (dyn-u-raw-tag u))
     (if (exact-integer? t)
         t
         (safe-exact-int t 0))]
    [else 0]))

(: u-x (-> Any Float))
(define (u-x u)
  (if (mode-unit-input? u)
      (mode-unit-input-x u)
      (dyn-u-x u)))

(: u-y (-> Any Float))
(define (u-y u)
  (if (mode-unit-input? u)
      (mode-unit-input-y u)
      (dyn-u-y u)))

(: u-hp (-> Any Float Float))
(define (u-hp u default)
  (cond
    [(mode-unit-input? u) (max 0.0 (mode-unit-input-hp u))]
    [(dyn-hash-has-key? u 'hp) (max 0.0 (safe-finite-real (dyn-hash-ref u 'hp default) default))]
    [(dyn-hash-has-key? u 'health) (max 0.0 (safe-finite-real (dyn-hash-ref u 'health default) default))]
    [else default]))

(define *unit-mode-combat-stats-cache* :
  (Mutable-HashTable Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol)))
  (make-hasheq))

(: cached-unit-combat-stats (-> Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol))))
(define (cached-unit-combat-stats sym)
  (or (hash-ref *unit-mode-combat-stats-cache* sym (lambda () #f))
      (let ([st (sc2-unit-combat-stats sym)])
        (hash-set! *unit-mode-combat-stats-cache* sym st)
        st)))

(: u-max-hp (-> Any Float Float))
(define (u-max-hp u default)
  (cond
    [(mode-unit-input? u) (max 1.0 (mode-unit-input-max-hp u))]
    [(dyn-hash-has-key? u 'max-hp) (max 1.0 (safe-finite-real (dyn-hash-ref u 'max-hp default) default))]
    [(dyn-hash-has-key? u 'health-max) (max 1.0 (safe-finite-real (dyn-hash-ref u 'health-max default) default))]
    [(dyn-hash-has-key? u 'max_hp) (max 1.0 (safe-finite-real (dyn-hash-ref u 'max_hp default) default))]
    [else
     (define stats (cached-unit-combat-stats (exact-unit-type u)))
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
     (define stats (cached-unit-combat-stats (exact-unit-type u)))
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
     (define stats (cached-unit-combat-stats ut))
     (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
     (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
     (+ (u-hp u def-hp) (u-shield u def-sh))]))

(: u-total-max-ehp (-> Any Float))
(define (u-total-max-ehp u)
  (cond
    [(mode-unit-input? u)
     (max 1.0 (+ (max 1.0 (mode-unit-input-max-hp u))
                 (max 0.0 (mode-unit-input-max-shield u))))]
    [(dyn-hash-has-key? u 'hull-hp)
     (define ut (exact-unit-type u))
     (define stats (cached-unit-combat-stats ut))
     (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
     (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
     (if (or (dyn-hash-has-key? u 'max-hp)
             (dyn-hash-has-key? u 'health-max)
             (dyn-hash-has-key? u 'max_hp))
         (max 1.0 (u-max-hp u (+ def-hp def-sh)))
         (max 1.0 (+ def-hp def-sh)))]
    [else
     (define ut (exact-unit-type u))
     (define stats (cached-unit-combat-stats ut))
     (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
     (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
     (max 1.0 (+ (u-max-hp u def-hp) (u-max-shield u def-sh)))]))

(: u-hp-ratio (-> Any Float))
(define (u-hp-ratio u)
  (clamp-prob (/ (u-total-ehp u) (u-total-max-ehp u))))

(: u-alive? (-> Any Boolean))
(define (u-alive? u)
  (if (mode-unit-input? u)
      (> (+ (mode-unit-input-hp u) (mode-unit-input-shield u)) 0.0)
      (case (dyn-u-alive-fast u)
        [(true) #t]
        [(false) #f]
        [else (> (u-total-ehp u) 0.0)])))

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

(: u-has-buff? (-> Any (U Integer Symbol) Boolean))
(define (u-has-buff? u buff-id)
  (define b1 (dyn-hash-ref u 'buffs #f))
  (define b2 (dyn-hash-ref u 'buff-ids #f))
  (define b3 (dyn-hash-ref u 'buff_ids #f))
  (: list-has-buff? (-> Any Boolean))
  (define (list-has-buff? lst)
    (and (list? lst)
         (for/or : Boolean ([b (in-list lst)])
           (or (equal? b buff-id)
               (and (eqv? buff-id CYCLONE-LOCK-ON-BUFF-ID)
                    (not (not (memq b '(lock-on lock-on-ground lockon)))))))))
  (or (list-has-buff? b1)
      (list-has-buff? b2)
      (list-has-buff? b3)))

(: u-weapon-range (-> Any Float))
(define (u-weapon-range u)
  (define ut (exact-unit-type u))
  (define stats (cached-unit-combat-stats ut))
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

(: sync-unit-mode-tracker-post!
   (-> unit-mode-tracker (Listof Any) (Listof Any) Integer (Listof Integer) Boolean Void))
(define (sync-unit-mode-tracker-post! tr ally-units enemy-units current-frame dead-tags track-air-memory?)
  (when track-air-memory?
    (unit-mode-tracker-record-enemy-air! tr enemy-units current-frame))

  (when (pair? dead-tags)
    (unit-mode-tracker-prune-dead! tr dead-tags))

  ;; Expire Cyclones' completed channels (`>= 315f`) or broken tethers (`dead` / `> 15.0` tiles)
  (define cy-tbl (unit-mode-tracker-cyclone-locks tr))
  (define has-active-lock?
    (and (not (hash-empty? cy-tbl))
         (for/or : Boolean ([(_ rec) (in-hash cy-tbl)])
           (> (cyclone-lock-rec-active-target-tag rec) 0))))
  (when has-active-lock?
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
                     (cyclone-lock-rec (cyclone-lock-rec-last-cast-frame rec) 0 0)))))))

;; Synchronizes Thor, Hellion/Hellbat, and Viking mode entries against current observations.
(: sync-unit-mode-tracker! (->* (unit-mode-tracker (Listof Any) (Listof Any) Integer)
                                (#:dead-tags (Listof Integer) #:track-air-memory? Boolean)
                                Void))
(define (sync-unit-mode-tracker! tr ally-units enemy-units current-frame
                                 #:dead-tags [dead-tags '()]
                                 #:track-air-memory? [track-air-memory? #f])
  (for ([a (in-list ally-units)])
    (define ut (exact-unit-type a))
    (when (and (memq ut '(thor thor-ap hellion hellbat viking-fighter viking viking-assault
                          widow-mine widow-mine-burrowed))
               (u-alive? a))
      (define tag (u-tag a))
      (when (> tag 0)
        (case ut
          [(thor)           (sync-unit-mode-entry! (unit-mode-tracker-thor-modes tr) tag current-frame 'explosive)]
          [(thor-ap)        (sync-unit-mode-entry! (unit-mode-tracker-thor-modes tr) tag current-frame 'high-impact)]
          [(hellion)        (sync-unit-mode-entry! (unit-mode-tracker-hellion-modes tr) tag current-frame 'hellion)]
          [(hellbat)        (sync-unit-mode-entry! (unit-mode-tracker-hellion-modes tr) tag current-frame 'hellbat)]
          [(viking-fighter viking)
                            (sync-unit-mode-entry! (unit-mode-tracker-viking-modes tr) tag current-frame 'fighter)]
          [(viking-assault) (sync-unit-mode-entry! (unit-mode-tracker-viking-modes tr) tag current-frame 'assault)]
          [(widow-mine widow-mine-burrowed)
                            (sync-unit-mode-entry!
                             (unit-mode-tracker-widow-mine-modes tr)
                             tag
                             current-frame
                             (if (or (eq? ut 'widow-mine-burrowed)
                                     (eq? (dyn-hash-ref a 'burrowed #f) #t))
                                 'burrowed
                                 'mobile))]))))
  (sync-unit-mode-tracker-post! tr ally-units enemy-units current-frame dead-tags track-air-memory?))

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
            ([a (in-list ally-units)]
             #:when (and (u-alive? a) (memq (exact-unit-type a) '(thor thor-ap))))
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
(: evaluate-hellion-mode/centroid
   (-> Any (Listof Any) (Option unit-mode-tracker) Integer (U Boolean 'auto)
       Boolean Float Float Boolean
       (Option unit-mode-directive)))
(define (evaluate-hellion-mode/centroid unit enemy-units tr current-frame runby-arg
                                         has-army? acx acy has-bio?)
  (define ut (exact-unit-type unit))
  (define tag (u-tag unit))
  (define runby?
    (if (boolean? runby-arg)
        runby-arg
        (u-worker-runby? unit)))
  (define ux (u-x unit))
  (define uy (u-y unit))
  (define is-hellbat? (eq? ut 'hellbat))
  (define dwell
    (if tr
        (unit-mode-tracker-hellbat-dwell-elapsed tr tag current-frame)
        10000))
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
    [else #f]))

(define (evaluate-hellion-mode unit enemy-units ally-units
                               #:tracker [tr #f]
                               #:current-frame [current-frame 0]
                               #:armory-ready? [armory-arg 'auto]
                               #:worker-runby? [runby-arg 'auto])
  (define ut (exact-unit-type unit))
  (cond
    [(or (not (u-alive? unit))
         (not (memq ut '(hellion hellbat))))
     #f]
    [else
     (define armory-ok?
       (if (eq? armory-arg 'auto)
           (ally-armory-completed? ally-units)
           (not (not armory-arg))))
     (if (not armory-ok?)
         #f
         (let-values ([(has-army? acx acy has-bio?) (main-army-centroid ally-units)])
           (evaluate-hellion-mode/centroid unit enemy-units tr current-frame runby-arg
                                           has-army? acx acy has-bio?)))]))

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
  (if (eq? armory-arg #f)
      '()
      (let-values ([(hellions auto-armory?)
                    (for/fold ([hs : (Listof Any) '()]
                               [arm? : Boolean (not (eq? armory-arg 'auto))]
                               #:result (values (reverse hs) arm?))
                              ([a (in-list ally-units)]
                               #:when (u-alive? a))
                      (define ut (exact-unit-type a))
                      (values (if (memq ut '(hellion hellbat)) (cons a hs) hs)
                              (or arm? (and (eq? ut 'armory) (u-completed? a)))))])
        (if (or (null? hellions) (not auto-armory?))
            '()
            (let-values ([(has-army? acx acy has-bio?) (main-army-centroid ally-units)])
              (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
                        ([a (in-list hellions)])
                (define d (evaluate-hellion-mode/centroid a enemy-units tr current-frame 'auto
                                                          has-army? acx acy has-bio?))
                (if d (cons d acc) acc)))))))

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
  (define stats (cached-unit-combat-stats eff-ut))
  (define gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0))
  (cond
    [(> gdps 0.0)
     (->float (sqrt (max 0.0 (* ehp gdps))))]
    [(u-structure? u)
     (->float (sqrt (max 0.0 (* 0.5 ehp))))]
    [else 5.0]))

(struct v-enemy-rec
  ([u : Any]
   [x : Float]
   [y : Float]
   [ca? : Boolean]
   [cap? : Boolean]
   [sp? : Boolean]
   [ground-tgt? : Boolean]
   [ground-pwr? : Boolean]
   [gstr : Float]))

(struct v-ally-pwr
  ([x : Float]
   [y : Float]
   [str : Float]))

(: local-ground-power-balance (-> Float Float (Listof Any) (Listof Any) (Values Float Float)))
(define (local-ground-power-balance vx vy ally-units enemy-units)
  (define local-r 12.0)
  (define local-r2 (* local-r local-r))
  (define ally-pwr
    (for/fold ([acc : Float 0.0])
              ([a (in-list ally-units)]
               #:when (u-alive? a))
      (define ax (u-x a))
      (define ay (u-y a))
      (define dx (- vx ax))
      (define dy (- vy ay))
      (if (and (<= (abs dx) local-r)
               (<= (abs dy) local-r)
               (<= (+ (* dx dx) (* dy dy)) local-r2))
          (let ([at (exact-unit-type a)])
            (if (and (or (not (u-flying? a))
                         (memq at '(viking viking-fighter)))
                     (not (u-structure? a)))
                (+ acc (local-ground-unit-strength a at))
                acc))
          acc)))
  (define enemy-pwr
    (for/fold ([acc : Float 0.0])
              ([e (in-list enemy-units)]
               #:when (u-alive? e))
      (define ex (u-x e))
      (define ey (u-y e))
      (define dx (- vx ex))
      (define dy (- vy ey))
      (if (and (<= (abs dx) local-r)
               (<= (abs dy) local-r)
               (<= (+ (* dx dx) (* dy dy)) local-r2)
               (not (u-flying? e)))
          (let ([et (exact-unit-type e)])
            (if (not (memq et '(larva egg changeling)))
                (+ acc (local-ground-unit-strength e et))
                acc))
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

(: evaluate-viking-mode/pre
   (-> Any Symbol Integer Float Float Boolean Float Integer
       (Listof v-enemy-rec) (Listof v-ally-pwr)
       (Option unit-mode-tracker) Integer Real Real Boolean
       (Option unit-mode-directive)))
(define (evaluate-viking-mode/pre unit ut tag vx vy is-assault? hp-rat dwell
                                  e-recs a-pwrs tr current-frame home-x home-y air-mem-threat?)
  (define local-r 12.0)
  (define local-r2 144.0)
  (define safe-air-r VIKING-LAND-SAFE-AIR-RADIUS)
  (define safe-air-r2 (* safe-air-r safe-air-r))
  (define lift-air-r VIKING-LIFTOFF-AIR-RADIUS)
  (define lift-air-r2 (* lift-air-r lift-air-r))
  (define cap-r VIKING-EMERGENCY-CAPITAL-RADIUS)
  (define cap-r2 (* cap-r cap-r))
  (define sp-lift-r VIKING-LIFTOFF-GROUND-SPLASH-RADIUS)
  (define sp-lift-r2 (* sp-lift-r sp-lift-r))
  (define sp-land-r VIKING-LAND-GROUND-SPLASH-RADIUS)
  (define sp-land-r2 (* sp-land-r sp-land-r))
  (define g-tgt-r VIKING-LAND-GROUND-TARGET-RADIUS)
  (define g-tgt-r2 (* g-tgt-r g-tgt-r))
  (cond
    [is-assault?
     (cond
       [(< hp-rat VIKING-LIFTOFF-HP-RATIO)
        (when tr
          (record-mode-switch! (unit-mode-tracker-viking-modes tr) tag current-frame 'fighter))
        (unit-mode-directive tag ut 'cast-spell 'morph-viking-fighter
                             MORPH-VIKING-FIGHTER-ABILITY-ID tag vx vy 'viking-liftoff-low-hp)]
       [else
        (define-values (splash-9.5? cap-air-15? combat-air-25? enemy-pwr)
          (let loop : (Values Boolean Boolean Boolean Float)
            ([rem : (Listof v-enemy-rec) e-recs]
             [sp95? : Boolean #f]
             [cap15? : Boolean #f]
             [ca25? : Boolean #f]
             [epwr : Float 0.0])
            (cond
              [(null? rem) (values sp95? cap15? ca25? epwr)]
              [else
               (define r (car rem))
               (define dx (- vx (v-enemy-rec-x r)))
               (define dy (- vy (v-enemy-rec-y r)))
               (define adx (abs dx))
               (define ady (abs dy))
               (if (and (<= adx lift-air-r) (<= ady lift-air-r))
                   (let ([d2 (+ (* dx dx) (* dy dy))])
                     (if (and (v-enemy-rec-sp? r) (<= adx sp-lift-r) (<= ady sp-lift-r) (<= d2 sp-lift-r2))
                         (values #t cap15? ca25? epwr)
                         (let ([n-epwr (if (and (v-enemy-rec-ground-pwr? r)
                                                (<= adx local-r) (<= ady local-r) (<= d2 local-r2))
                                           (+ epwr (v-enemy-rec-gstr r))
                                           epwr)]
                               [n-cap (or cap15? (and (v-enemy-rec-cap? r)
                                                      (<= adx cap-r) (<= ady cap-r) (<= d2 cap-r2)))]
                               [n-ca (or ca25? (and (v-enemy-rec-ca? r) (<= d2 lift-air-r2)))])
                           (loop (cdr rem) #f n-cap n-ca n-epwr))))
                   (loop (cdr rem) sp95? cap15? ca25? epwr))])))
        (define lift-reason : (Option Symbol)
          (cond
            [splash-9.5? 'viking-liftoff-ground-splash]
            [else
             (define ally-pwr
               (for/fold ([acc : Float 0.0]) ([a (in-list a-pwrs)])
                 (define dx (- vx (v-ally-pwr-x a)))
                 (define dy (- vy (v-ally-pwr-y a)))
                 (if (and (<= (abs dx) local-r)
                          (<= (abs dy) local-r)
                          (<= (+ (* dx dx) (* dy dy)) local-r2))
                     (+ acc (v-ally-pwr-str a))
                     acc)))
             (cond
               [(> enemy-pwr (* VIKING-LIFTOFF-POWER-THRESHOLD (max 1.0 ally-pwr)))
                'viking-liftoff-ground-power]
               [(and cap-air-15? (>= dwell VIKING-EMERGENCY-LIFTOFF-DWELL-FRAMES))
                'viking-liftoff-emergency-capital-air]
               [(and combat-air-25? (>= dwell VIKING-GROUND-DWELL-FRAMES))
                'viking-liftoff-combat-air]
               [else #f])]))
        (if lift-reason
            (begin
              (when tr
                (record-mode-switch! (unit-mode-tracker-viking-modes tr) tag current-frame 'fighter))
              (unit-mode-directive tag ut 'cast-spell 'morph-viking-fighter
                                   MORPH-VIKING-FIGHTER-ABILITY-ID tag vx vy lift-reason))
            #f)])]
    [else
     (cond
       [(or air-mem-threat?
            (< hp-rat VIKING-LAND-MIN-HP-RATIO)
            (< dwell VIKING-GROUND-DWELL-FRAMES))
        #f]
       [else
        (define scan-r (max safe-air-r (max sp-land-r (max g-tgt-r local-r))))
        (define-values (unsafe? best-g _best-gd2 enemy-pwr)
          (let loop : (Values Boolean Any Float Float)
            ([rem : (Listof v-enemy-rec) e-recs]
             [bg : Any #f]
             [bgd2 : Float +inf.0]
             [epwr : Float 0.0])
            (cond
              [(null? rem) (values #f bg bgd2 epwr)]
              [else
               (define r (car rem))
               (define dx (- vx (v-enemy-rec-x r)))
               (define dy (- vy (v-enemy-rec-y r)))
               (define adx (abs dx))
               (define ady (abs dy))
               (if (and (<= adx scan-r) (<= ady scan-r))
                   (let ([d2 (+ (* dx dx) (* dy dy))])
                     (if (or (and (v-enemy-rec-ca? r) (<= adx safe-air-r) (<= ady safe-air-r) (<= d2 safe-air-r2))
                             (and (v-enemy-rec-sp? r) (<= adx sp-land-r) (<= ady sp-land-r) (<= d2 sp-land-r2)))
                         (values #t #f +inf.0 0.0)
                         (let-values ([(nbg nbgd2)
                                       (if (and (v-enemy-rec-ground-tgt? r)
                                                (<= adx g-tgt-r)
                                                (<= ady g-tgt-r)
                                                (<= d2 g-tgt-r2)
                                                (< d2 bgd2))
                                           (values (v-enemy-rec-u r) d2)
                                           (values bg bgd2))])
                           (define n-epwr
                             (if (and (v-enemy-rec-ground-pwr? r)
                                      (<= adx local-r) (<= ady local-r) (<= d2 local-r2))
                                 (+ epwr (v-enemy-rec-gstr r))
                                 epwr))
                           (loop (cdr rem) nbg nbgd2 n-epwr))))
                   (loop (cdr rem) bg bgd2 epwr))])))
        (if (or unsafe? (not best-g))
            #f
            (let ([ally-pwr
                   (for/fold ([acc : Float 0.0]) ([a (in-list a-pwrs)])
                     (define dx (- vx (v-ally-pwr-x a)))
                     (define dy (- vy (v-ally-pwr-y a)))
                     (if (and (<= (abs dx) local-r)
                              (<= (abs dy) local-r)
                              (<= (+ (* dx dx) (* dy dy)) local-r2))
                         (+ acc (v-ally-pwr-str a))
                         acc))])
              (if (>= ally-pwr (* VIKING-LAND-POWER-RATIO (max 1.0 enemy-pwr)))
                  (let ([land-pt (compute-viking-land-standoff
                                  (u-x best-g)
                                  (u-y best-g)
                                  home-x
                                  home-y)])
                    (when tr
                      (record-mode-switch! (unit-mode-tracker-viking-modes tr) tag current-frame 'assault))
                    (unit-mode-directive tag ut 'cast-spell 'morph-viking-assault
                                         MORPH-VIKING-ASSAULT-ABILITY-ID tag
                                         (point2d-x land-pt) (point2d-y land-pt)
                                         'viking-land-cleanup-superiority))
                  #f)))])]))

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
     (define air-mem-threat?
       (if is-assault? #f (enemy-air-memory-has-threat? tr enemy-air-memory)))
     (cond
       [(and (not is-assault?)
             (or air-mem-threat?
                 (< hp-rat VIKING-LAND-MIN-HP-RATIO)
                 (< dwell VIKING-GROUND-DWELL-FRAMES)))
        #f]
       [(and is-assault? (< hp-rat VIKING-LIFTOFF-HP-RATIO))
        (when tr
          (record-mode-switch! (unit-mode-tracker-viking-modes tr) tag current-frame 'fighter))
        (unit-mode-directive tag ut 'cast-spell 'morph-viking-fighter
                             MORPH-VIKING-FIGHTER-ABILITY-ID tag vx vy 'viking-liftoff-low-hp)]
       [else
        (define max-scan (if is-assault?
                             VIKING-LIFTOFF-AIR-RADIUS
                             (max VIKING-LAND-SAFE-AIR-RADIUS
                                  (max VIKING-LAND-GROUND-SPLASH-RADIUS
                                       (max VIKING-LAND-GROUND-TARGET-RADIUS 12.0)))))
        (define e-recs
          (for/list : (Listof v-enemy-rec)
                    ([e (in-list enemy-units)]
                     #:when (and (u-alive? e)
                                 (<= (abs (- vx (u-x e))) max-scan)
                                 (<= (abs (- vy (u-y e))) max-scan)))
            (define et (exact-unit-type e))
            (define fly? (u-flying? e))
            (define ground-pwr? (and (not fly?) (not (memq et '(larva egg changeling)))))
            (v-enemy-rec e (u-x e) (u-y e)
                         (viking-combat-air-or-colossus-sym? et)
                         (viking-capital-air-sym? et)
                         (and (not fly?) (viking-ground-splash-sym? et))
                         (and (not fly?) (not (memq et '(larva egg))))
                         ground-pwr?
                         (if ground-pwr? (local-ground-unit-strength e et) 0.0))))
        (define a-pwrs
          (for/list : (Listof v-ally-pwr)
                    ([a (in-list ally-units)]
                     #:when (and (u-alive? a)
                                 (<= (abs (- vx (u-x a))) 12.0)
                                 (<= (abs (- vy (u-y a))) 12.0)
                                 (let ([at (exact-unit-type a)])
                                   (and (or (not (u-flying? a))
                                            (memq at '(viking viking-fighter)))
                                        (not (u-structure? a))))))
            (v-ally-pwr (u-x a) (u-y a) (local-ground-unit-strength a (exact-unit-type a)))))
        (evaluate-viking-mode/pre unit ut tag vx vy is-assault? hp-rat dwell
                                  e-recs a-pwrs tr current-frame home-x home-y air-mem-threat?)])]))

(: plan-viking-modes/list
   (-> (Listof Any) (Listof Any) (Listof Any)
       (Option unit-mode-tracker) Integer Real Real (Listof Any)
       (Listof unit-mode-directive)))
(define (plan-viking-modes/list vikings ally-units enemy-units
                                tr current-frame home-x home-y enemy-air-memory)
  (cond
    [(null? vikings) '()]
    [else
     (define air-mem-threat? (enemy-air-memory-has-threat? tr enemy-air-memory))
     ;; Precheck if any Viking can possibly act before building full enemy/ally tables
     (define need-tables?
       (for/or : Boolean ([v (in-list vikings)])
         (define ut (exact-unit-type v))
         (or (eq? ut 'viking-assault)
             (and (not air-mem-threat?)
                  (>= (u-hp-ratio v) VIKING-LAND-MIN-HP-RATIO)
                  (>= (if tr (unit-mode-tracker-viking-dwell-elapsed tr (u-tag v) current-frame) 10000)
                      VIKING-GROUND-DWELL-FRAMES)))))
     (cond
       [(not need-tables?) '()]
       [else
        (define e-recs
          (for/list : (Listof v-enemy-rec)
                    ([e (in-list enemy-units)]
                     #:when (u-alive? e))
            (define et (exact-unit-type e))
            (define fly? (u-flying? e))
            (define ground-pwr? (and (not fly?) (not (memq et '(larva egg changeling)))))
            (v-enemy-rec e (u-x e) (u-y e)
                         (viking-combat-air-or-colossus-sym? et)
                         (viking-capital-air-sym? et)
                         (and (not fly?) (viking-ground-splash-sym? et))
                         (and (not fly?) (not (memq et '(larva egg))))
                         ground-pwr?
                         (if ground-pwr? (local-ground-unit-strength e et) 0.0))))
        (define a-pwrs
          (for/list : (Listof v-ally-pwr)
                    ([a (in-list ally-units)]
                     #:when (and (u-alive? a)
                                 (let ([at (exact-unit-type a)])
                                   (and (or (not (u-flying? a))
                                            (memq at '(viking viking-fighter)))
                                        (not (u-structure? a))))))
            (v-ally-pwr (u-x a) (u-y a) (local-ground-unit-strength a (exact-unit-type a)))))
        (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
                  ([v (in-list vikings)])
          (define ut (exact-unit-type v))
          (define tag (u-tag v))
          (define d
            (evaluate-viking-mode/pre
             v ut tag (u-x v) (u-y v) (eq? ut 'viking-assault)
             (u-hp-ratio v)
             (if tr (unit-mode-tracker-viking-dwell-elapsed tr tag current-frame) 10000)
             e-recs a-pwrs tr current-frame home-x home-y air-mem-threat?))
          (if d (cons d acc) acc))])]))

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
  (define vikings
    (for/list : (Listof Any)
              ([a (in-list ally-units)]
               #:when (and (memq (exact-unit-type a) '(viking viking-fighter viking-assault))
                           (u-alive? a)))
      a))
  (plan-viking-modes/list vikings ally-units enemy-units
                          tr current-frame home-x home-y enemy-air-memory))

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
               ;; W12-P0-4-rt (`w12-tac-2`): Skip enemies already carrying Cyclone Lock-On (`buff=116`)
               ;; or already claimed by another Cyclone on this tick so 2350 is never double-burned.
               (define already-locked-buff?
                 (let ([bfs (dyn-hash-ref e 'buffs '())])
                   (and (list? bfs)
                        (for/or : Boolean ([b (in-list bfs)])
                          (or (eqv? b 116)
                              (eq? b 'lock-on)
                              (eq? b 'cyclone-lock-on))))))
               (define already-claimed?
                 (and claimed-targets (hash-has-key? claimed-targets etag)))
               (define valid?
                 (and (> etag 0)
                      (<= d CYCLONE-LOCK-ON-CAST-RANGE)
                      (not already-locked-buff?)
                      (not already-claimed?)
                      (not (memq et '(larva egg)))
                      (not (u-structure? e))))
               (if (not valid?)
                   (values bt bs)
                   (let ([sc (cyclone-target-priority-score et (u-total-ehp e) d)])
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
  (define cyclones
    (for/list : (Listof Any) ([a (in-list ally-units)]
                              #:when (and (u-alive? a) (eq? (exact-unit-type a) 'cyclone)))
      a))
  (cond
    [(null? cyclones) '()]
    [else
     (define claimed : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
               ([a (in-list cyclones)])
       (define d (evaluate-cyclone-micro a enemy-units ally-units
                                         #:tracker tr
                                         #:current-frame current-frame
                                         #:home-x home-x
                                         #:home-y home-y
                                         #:claimed-targets claimed))
       (if d (cons d acc) acc))]))

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
(struct mar-e-rec
  ([tag : Integer]
   [ut : Symbol]
   [x : Float]
   [y : Float]
   [ehp : Float]
   [massive? : Boolean]
   [struct? : Boolean]
   [lethal-hp? : Boolean]
   [slowed? : Boolean]
   [lethal-claims : Integer])
  #:mutable)

(struct mar-a-rec
  ([tag : Integer]
   [x : Float]
   [y : Float]))

(: plan-marauder-concussive-targets/list
   (-> (Listof Any) (Listof Any) (Option unit-mode-tracker) Integer Boolean
       (Listof marauder-target-order)))
(define (plan-marauder-concussive-targets/list marauders enemy-units tr current-frame researched?)
  (cond
    [(or (null? marauders) (null? enemy-units)) '()]
    [else
     (define active-tr (or tr (make-unit-mode-tracker)))
     (define max-rng MARAUDER-ACQUIRE-MAX-RANGE)
     (define max-r2 (* max-rng max-rng))
     (define wep-rng (+ MARAUDER-WEAPON-RANGE 0.25))
     (define wep-r2 (* wep-rng wep-rng))
     ;; Single Marauder pass: cache tag/x/y and compute fleet bounding box to pre-prune enemies
     ;; BEFORE expensive `u-flying?`, `exact-unit-type`, `u-total-ehp`, and slowed-table lookups.
     (define-values (rev-m-recs min-mx max-mx min-my max-my)
       (for/fold ([acc : (Listof mar-a-rec) '()]
                  [minx : Float +inf.0]
                  [maxx : Float -inf.0]
                  [miny : Float +inf.0]
                  [maxy : Float -inf.0])
                 ([a (in-list marauders)])
         (define mx (u-x a))
         (define my (u-y a))
         (values (cons (mar-a-rec (u-tag a) mx my) acc)
                 (if (< mx minx) mx minx)
                 (if (> mx maxx) mx maxx)
                 (if (< my miny) my miny)
                 (if (> my maxy) my maxy))))
     (define m-recs (reverse rev-m-recs))
     (define bb-lo-x (- min-mx max-rng))
     (define bb-hi-x (+ max-mx max-rng))
     (define bb-lo-y (- min-my max-rng))
     (define bb-hi-y (+ max-my max-rng))
     (define g-recs : (Listof mar-e-rec)
       (for/fold ([acc : (Listof mar-e-rec) '()] #:result (reverse acc))
                 ([e (in-list enemy-units)])
         (define ex (u-x e))
         (define ey (u-y e))
         (if (and (<= bb-lo-x ex bb-hi-x)
                  (<= bb-lo-y ey bb-hi-y)
                  (u-alive? e)
                  (not (u-flying? e)))
             (let ([et (exact-unit-type e)])
               (if (memq et '(larva egg))
                   acc
                   (let ([etag (u-tag e)]
                         [ehp (u-total-ehp e)])
                     (cons (mar-e-rec etag
                                      et
                                      ex
                                      ey
                                      ehp
                                      (massive-ground-unit-sym? et)
                                      (u-structure? e)
                                      (<= ehp MARAUDER-LETHAL-FINISH-EHP)
                                      (if tr (unit-mode-tracker-enemy-slowed? active-tr etag current-frame) #f)
                                      0)
                           acc))))
             acc)))
     (cond
       [(null? g-recs) '()]
       [else
        (for/fold ([acc : (Listof marauder-target-order) '()] #:result (reverse acc))
                  ([mr (in-list m-recs)])
          (define mid (mar-a-rec-tag mr))
          (define mx (mar-a-rec-x mr))
          (define my (mar-a-rec-y mr))
          (define best-rec : (Option mar-e-rec)
            (for/fold ([best : (Option mar-e-rec) #f]
                       [best-sc : Float -1e9]
                       #:result best)
                      ([r (in-list g-recs)])
              (define ehp (mar-e-rec-ehp r))
              (define massive? (mar-e-rec-massive? r))
              (define struct? (mar-e-rec-struct? r))
              (define slowed-now? (mar-e-rec-slowed? r))
              (define lethal? (and (mar-e-rec-lethal-hp? r)
                                   (< (mar-e-rec-lethal-claims r) 2)))
              ;; Exact zero-distance upper bound (range-penalty <= 0, dist-term <= 0) prunes impossible
              ;; candidates before `abs` / `d2` / `sqrt`.
              (define tier-ub : Float
                (cond
                  [(not researched?) (+ (if lethal? 400.0 0.0) (* -0.5 ehp))]
                  [lethal? (+ 2000.0 (* -1.0 ehp))]
                  [(and (not massive?) (not struct?) (not slowed-now?)) (+ 1000.0 (* -0.2 ehp))]
                  [(and massive? (not struct?)) (+ 250.0 (* -0.1 ehp))]
                  [(not struct?) (+ 150.0 (* -0.2 ehp))]
                  [else -200.0]))
              (if (<= tier-ub best-sc)
                  (values best best-sc)
                  (let ([dx (- mx (mar-e-rec-x r))]
                        [dy (- my (mar-e-rec-y r))])
                    (if (and (<= (abs dx) max-rng)
                             (<= (abs dy) max-rng))
                        (let ([d2 (+ (* dx dx) (* dy dy))])
                          (if (<= d2 max-r2)
                              (let* ([range-penalty (if (<= d2 wep-r2) 0.0 -80.0)]
                                     [ub-after-range (+ tier-ub range-penalty)])
                                (if (<= ub-after-range best-sc)
                                    (values best best-sc)
                                    (let* ([d (->float (sqrt (max 0.0 d2)))]
                                           [sc : Float (+ ub-after-range (* (if (and researched? lethal?) -2.0 -3.0) d))])
                                      (if (> sc best-sc)
                                          (values r sc)
                                          (values best best-sc)))))
                              (values best best-sc)))
                        (values best best-sc))))))
          (cond
            [(not best-rec) acc]
            [else
             (define etag (mar-e-rec-tag best-rec))
             (define massive? (mar-e-rec-massive? best-rec))
             (define lethal? (mar-e-rec-lethal-hp? best-rec))
             (define was-slowed? (mar-e-rec-slowed? best-rec))
             (define reason : Symbol
               (cond
                 [(not researched?) 'marauder-focus-no-concussive]
                 [lethal?           'marauder-lethal-finish-exception]
                 [(and (not massive?) (not was-slowed?))
                  'marauder-spread-concussive-slow]
                 [massive?          'marauder-massive-only-exception]
                 [else              'marauder-all-targets-already-slowed]))
             (when lethal?
               (set-mar-e-rec-lethal-claims! best-rec (add1 (mar-e-rec-lethal-claims best-rec))))
             (when (and researched? (not massive?) (not (mar-e-rec-struct? best-rec)))
               (unit-mode-tracker-mark-enemy-slowed! active-tr etag current-frame)
               (set-mar-e-rec-slowed?! best-rec #t))
             (cons (marauder-target-order mid etag
                                          (mar-e-rec-x best-rec) (mar-e-rec-y best-rec)
                                          was-slowed? lethal? massive? reason)
                   acc)]))])]))

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
  (define marauders
    (for/list : (Listof Any) ([a (in-list ally-units)]
                              #:when (and (u-alive? a) (eq? (exact-unit-type a) 'marauder)))
      a))
  (plan-marauder-concussive-targets/list marauders enemy-units tr current-frame researched?))

;; =============================================================================
;; 6. Counter-Unit-Mode Micro (`plan-counter-unit-mode-micro` — Wave 1C)
;; =============================================================================

(: COUNTER-CYCLONE-TETHER-BREAK-TARGET Float)
(define COUNTER-CYCLONE-TETHER-BREAK-TARGET 15.6)

(: COUNTER-CYCLONE-PICKUP-MAX-DIST Float)
(define COUNTER-CYCLONE-PICKUP-MAX-DIST 4.0)

(: COUNTER-HELLBAT-KITE-RANGE Float)
(define COUNTER-HELLBAT-KITE-RANGE 4.5)

(: zerg-burrowable-counter-sym? (-> Symbol Boolean))
(define (zerg-burrowable-counter-sym? sym)
  (not (not (memq sym '(zergling baneling roach hydralisk ravager infestor lurker lurker-mp queen drone)))))

(: enemy-detector-in-range? (-> Float Float (Listof Any) Float Boolean))
(define (enemy-detector-in-range? ux uy enemy-units r)
  (for/or : Boolean ([e (in-list enemy-units)])
    (and (u-alive? e)
         (memq (exact-unit-type e) '(observer observer-siege-mode overseer overseer-siege-mode
                                     raven photon-cannon missile-turret spore-crawler))
         (<= (dist-2d ux uy (u-x e) (u-y e)) r))))

(: friendly-locked-by-cyclone? (-> Any (Listof Any) (Option Any)))
(define (friendly-locked-by-cyclone? a enemy-units)
  (define atag (u-tag a))
  (define ax (u-x a))
  (define ay (u-y a))
  (define has-lock-buff?
    (or (u-has-buff? a CYCLONE-LOCK-ON-BUFF-ID)
        (eq? (dyn-hash-ref a 'locked-on? #f) #t)))
  (define cyclones
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (u-alive? e)
                                          (eq? (exact-unit-type e) 'cyclone)
                                          (<= (dist-2d ax ay (u-x e) (u-y e)) 15.2)))
      e))
  (cond
    [(null? cyclones) #f]
    [else
     (define explicit-tetherer : (Option Any)
       (for/fold ([hit : (Option Any) #f])
                 ([c (in-list cyclones)]
                  #:when (and (not hit)
                              (or (eqv? (dyn-hash-ref c 'lock-on-target-tag #f) atag)
                                  (eqv? (dyn-hash-ref c 'engaged-target-tag #f) atag)
                                  (eqv? (dyn-hash-ref c 'target-tag #f) atag))))
         c))
     (or explicit-tetherer
         (and has-lock-buff?
              (for/fold ([best : (Option Any) #f] [bd : Float 1e9] #:result best)
                        ([c (in-list cyclones)])
                (define d (dist-2d ax ay (u-x c) (u-y c)))
                (if (< d bd) (values c d) (values best bd)))))]))

(: compute-cyclone-break-escape-pt (-> Float Float Float Float Float Float Float point2d))
(define (compute-cyclone-break-escape-pt ax ay cx cy hx hy target-cyclone-dist)
  (define rx (- ax cx))
  (define ry (- ay cy))
  (define rlen (max 1e-4 (dist-2d 0.0 0.0 rx ry)))
  (define tx (- hx ax))
  (define ty (- hy ay))
  (define tlen (dist-2d 0.0 0.0 tx ty))
  (define bx
    (if (> tlen 1e-3)
        (+ (* 0.78 (/ rx rlen)) (* 0.22 (/ tx tlen)))
        (/ rx rlen)))
  (define by
    (if (> tlen 1e-3)
        (+ (* 0.78 (/ ry rlen)) (* 0.22 (/ ty tlen)))
        (/ ry rlen)))
  (define blen (max 1e-4 (dist-2d 0.0 0.0 bx by)))
  (define want-r (max (+ rlen 4.0) target-cyclone-dist))
  (clamp-playable-pt (+ cx (* want-r (/ bx blen)))
                     (+ cy (* want-r (/ by blen)))))

(: zerg-counter-burrow-ability-id (-> Symbol Integer))
(define (zerg-counter-burrow-ability-id sym)
  (case sym
    [(zergling)          1390]
    [(baneling)          1374]
    [(drone)             1378]
    [(roach)             1386]
    [(hydralisk)         1382]
    [(infestor)          1444]
    [(lurker lurker-mp)  2108]
    [(queen)             1433]
    [(ravager)           2340]
    [else                3661]))

;; Counter-Cyclone Lock-On tether breaker for one friendly unit (`<= 4.0` transport pickup
;; only when wounded `< 35%` HP or outside active combat + `>= 44f` transport cooldown,
;; `burrow-down` when undetected, `blink` beyond `15.2` tiles, or retreat beyond `15.0` tiles).
(: break-enemy-cyclone-lock-on
   (->* (Any (Listof Any) (Listof Any))
        (#:home-x Real
         #:home-y Real
         #:burrow-researched? Boolean
         #:blink-ready? (U Boolean 'auto)
         #:tracker (Option unit-mode-tracker)
         #:current-frame Integer)
        (Option unit-mode-directive)))
(define (break-enemy-cyclone-lock-on a ally-units enemy-units
                                     #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                     #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                     #:burrow-researched? [burrow-researched? #f]
                                     #:blink-ready? [blink-ready-kw 'auto]
                                     #:tracker [tr #f]
                                     #:current-frame [current-frame 0])
  (define tether-cyclone (and (u-alive? a) (friendly-locked-by-cyclone? a enemy-units)))
  (cond
    [(not tether-cyclone) #f]
    [else
     (define atag (u-tag a))
     (define at (exact-unit-type a))
     (define ax (u-x a))
     (define ay (u-y a))
     (define cx (u-x tether-cyclone))
     (define cy (u-y tether-cyclone))
     (define hx (->float home-x))
     (define hy (->float home-y))
     (define a-hp-frac (u-hp-ratio a))
     (define in-active-combat?
       (or (<= (dist-2d ax ay cx cy) 15.2)
           (for/or : Boolean ([e (in-list enemy-units)])
             (and (u-alive? e)
                  (<= (dist-2d ax ay (u-x e) (u-y e)) 12.0)))))
     (define pickup-warranted?
       (or (< a-hp-frac 0.35)
           (not in-active-combat?)))
     ;; 1. Load into nearby friendly transport (`<= 4.0` tiles) ONLY when retreating `< 35%` HP
     ;;    or outside active combat, with `>= 44f` per-transport cooldown
     (define nearby-transport
       (and pickup-warranted?
            (not (u-flying? a))
            (not (u-structure? a))
            (not (memq at '(medivac warp-prism warp-prism-phasing overlord-transport)))
            (for/fold ([best : (Option Any) #f]
                       [bd : Float COUNTER-CYCLONE-PICKUP-MAX-DIST]
                       #:result best)
                      ([tr-u (in-list ally-units)]
                       #:when (and (u-alive? tr-u)
                                   (> (u-tag tr-u) 0)
                                   (memq (exact-unit-type tr-u) '(medivac warp-prism overlord-transport))
                                   (< (safe-nonneg-int (dyn-hash-ref tr-u 'cargo-space-taken 0) 0) 8)
                                   (or (not tr)
                                       (= (unit-mode-tracker-transport-load-cooldown
                                           tr (u-tag tr-u) current-frame)
                                          0))))
              (define td (dist-2d ax ay (u-x tr-u) (u-y tr-u)))
              (if (<= td bd) (values tr-u td) (values best td)))))
     (define can-blink?
       (and (eq? at 'stalker)
            (if (eq? blink-ready-kw 'auto)
                (and (not (eq? (dyn-hash-ref a 'blink-ready? #t) #f))
                     (<= (safe-exact-int (dyn-hash-ref a 'blink-cooldown 0) 0) 0))
                (not (not blink-ready-kw)))))
     (cond
       [nearby-transport
        (define tr-tag (u-tag nearby-transport))
        (when tr
          (hash-set! (unit-mode-tracker-transport-last-load tr) tr-tag current-frame))
        (unit-mode-directive atag at 'load-into-transport 'load-transport 3668
                             tr-tag (u-x nearby-transport) (u-y nearby-transport)
                             'break-cyclone-lock-on-pickup)]
       [(and (or burrow-researched? (memq at '(lurker lurker-mp)))
             (zerg-burrowable-counter-sym? at)
             (not (enemy-detector-in-range? ax ay enemy-units 11.0)))
        (unit-mode-directive atag at 'burrow-down 'burrow-down (zerg-counter-burrow-ability-id at)
                             (u-tag tether-cyclone) ax ay
                             'break-cyclone-lock-on-burrow)]
       [can-blink?
        (define bpt (compute-cyclone-break-escape-pt ax ay cx cy hx hy COUNTER-CYCLONE-TETHER-BREAK-TARGET))
        (unit-mode-directive atag at 'blink 'blink 3687
                             (u-tag tether-cyclone) (point2d-x bpt) (point2d-y bpt)
                             'break-cyclone-lock-on-blink)]
       [else
        (define rpt (compute-cyclone-break-escape-pt ax ay cx cy hx hy COUNTER-CYCLONE-TETHER-BREAK-TARGET))
        (unit-mode-directive atag at 'retreat #f 0
                             (u-tag tether-cyclone) (point2d-x rpt) (point2d-y rpt)
                             'break-cyclone-lock-on-retreat)])]))

(: unit-can-hit-ground-sym? (-> Symbol Boolean))
(define (unit-can-hit-ground-sym? sym)
  (define stats (cached-unit-combat-stats sym))
  (> (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0) 0.0))

;; Counter-unit-mode micro across friendly units:
;;   (a) Break enemy Cyclone (`692`) Lock-On tether (`116`) via pickup/burrow/blink/retreat;
;;   (b) Counter Hellbat (`484`) by kiting `>= 4.5` tiles while closing/surrounding Hellion (`53`);
;;   (c) Focus-fire landed VikingAssault (`34`) with ground DPS/anti-armor, and swarm Thor HI
;;       (`691`) with light melee/ground while leashing capital air outside `13.5` tiles.
(: plan-counter-unit-mode-micro
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real
         #:home-y Real
         #:burrow-researched? Boolean
         #:blink-ready-tags (Listof Integer)
         #:tracker (Option unit-mode-tracker)
         #:current-frame Integer)
        (Listof unit-mode-directive)))
(define (plan-counter-unit-mode-micro ally-units enemy-units
                                      #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                      #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                      #:burrow-researched? [burrow-researched? #f]
                                      #:blink-ready-tags [blink-ready-tags '()]
                                      #:tracker [tr #f]
                                      #:current-frame [current-frame 0])
  (define-values (enemy-cyclones enemy-hellbats enemy-hellions enemy-vikings-landed enemy-thors-hi)
    (for/fold ([cys : (Listof Any) '()]
               [hbs : (Listof Any) '()]
               [hls : (Listof Any) '()]
               [vks : (Listof Any) '()]
               [ths : (Listof Any) '()])
              ([e (in-list enemy-units)]
               #:when (u-alive? e))
      (case (exact-unit-type e)
        [(cyclone)        (values (cons e cys) hbs hls vks ths)]
        [(hellbat)        (values cys (cons e hbs) hls vks ths)]
        [(hellion)        (values cys hbs (cons e hls) vks ths)]
        [(viking-assault) (values cys hbs hls (cons e vks) ths)]
        [(thor-ap thor)   (values cys hbs hls vks (cons e ths))]
        [else             (values cys hbs hls vks ths)])))
  (cond
    [(and (null? enemy-cyclones)
          (null? enemy-hellbats)
          (null? enemy-hellions)
          (null? enemy-vikings-landed)
          (null? enemy-thors-hi))
     '()]
    [else
     (define hx (->float home-x))
     (define hy (->float home-y))
     (define has-cys? (pair? enemy-cyclones))
     (for/fold ([acc : (Listof unit-mode-directive) '()]
                #:result (reverse acc))
               ([a (in-list ally-units)]
                #:when (and (u-alive? a) (> (u-tag a) 0) (not (u-structure? a))))
       (define atag (u-tag a))
       (define at (exact-unit-type a))
       (define ax (u-x a))
       (define ay (u-y a))
       (define blink-ok?
         (if (pair? blink-ready-tags)
             (not (not (memv atag blink-ready-tags)))
             'auto))
       ;; (a) Cyclone Lock-On Tether Break (skip when no enemy Cyclones exist or not locked)
       (define lock-dir
         (and has-cys?
              (friendly-locked-by-cyclone? a enemy-cyclones)
              (break-enemy-cyclone-lock-on a ally-units enemy-units
                                           #:home-x hx #:home-y hy
                                           #:burrow-researched? burrow-researched?
                                           #:blink-ready? blink-ok?
                                           #:tracker tr
                                           #:current-frame current-frame)))
       (cond
         [lock-dir (cons lock-dir acc)]
         [else
          ;; Find nearest Hellbat / Hellion / VikingAssault / ThorHI
          (define-values (nearest-hellbat d-hb)
            (if (null? enemy-hellbats)
                (values #f 1e9)
                (for/fold ([best : (Option Any) #f] [bd : Float 9.0])
                          ([hb (in-list enemy-hellbats)])
                  (define hbx (u-x hb))
                  (define hby (u-y hb))
                  (if (and (<= (abs (- ax hbx)) bd) (<= (abs (- ay hby)) bd))
                      (let ([d (dist-2d ax ay hbx hby)])
                        (if (< d bd) (values hb d) (values best bd)))
                      (values best bd)))))
          (define nearest-hellion
            (if (null? enemy-hellions)
                #f
                (for/fold ([best : (Option Any) #f] [bd : Float 10.0] #:result best)
                          ([hl (in-list enemy-hellions)])
                  (define hlx (u-x hl))
                  (define hly (u-y hl))
                  (if (and (<= (abs (- ax hlx)) bd) (<= (abs (- ay hly)) bd))
                      (let ([d (dist-2d ax ay hlx hly)])
                        (if (< d bd) (values hl d) (values best bd)))
                      (values best bd)))))
          (define nearest-landed-viking
            (if (null? enemy-vikings-landed)
                #f
                (for/fold ([best : (Option Any) #f] [bd : Float 11.0] #:result best)
                          ([vk (in-list enemy-vikings-landed)])
                  (define vkx (u-x vk))
                  (define vky (u-y vk))
                  (if (and (<= (abs (- ax vkx)) bd) (<= (abs (- ay vky)) bd))
                      (let ([d (dist-2d ax ay vkx vky)])
                        (if (< d bd) (values vk d) (values best bd)))
                      (values best bd)))))
          (define-values (nearest-thor-hi d-th)
            (if (null? enemy-thors-hi)
                (values #f 1e9)
                (for/fold ([best : (Option Any) #f] [bd : Float 14.0])
                          ([th (in-list enemy-thors-hi)])
                  (define thx (u-x th))
                  (define thy (u-y th))
                  (if (and (<= (abs (- ax thx)) bd) (<= (abs (- ay thy)) bd))
                      (let ([d (dist-2d ax ay thx thy)])
                        (if (< d bd) (values th d) (values best bd)))
                      (values best bd)))))
          (define flying? (u-flying? a))
          (cond
            ;; (c1) Capital/air unit near Thor High-Impact (`691`) -> leash outside `13.5` tiles
            [(and nearest-thor-hi
                  (eq? (exact-unit-type nearest-thor-hi) 'thor-ap)
                  (or (viking-capital-air-sym? at)
                      (memq at '(void-ray voidray corruptor phoenix mutalisk oracle liberator liberator-aa banshee)))
                  (< d-th 13.5))
             (define kpt (compute-tether-kite-point ax ay (u-x nearest-thor-hi) (u-y nearest-thor-hi) hx hy 14.0))
             (cons (unit-mode-directive atag at 'kite #f 0 (u-tag nearest-thor-hi)
                                        (point2d-x kpt) (point2d-y kpt)
                                        'counter-thor-hi-leash-capital-air)
                   acc)]
            ;; (b1) Hellbat (`484`) within `<= 4.5` tiles -> kite to `>= 5.2` tiles (avoid cone splash!)
            [(and nearest-hellbat
                  (not flying?)
                  (<= d-hb COUNTER-HELLBAT-KITE-RANGE)
                  (unit-can-hit-ground-sym? at))
             (define kpt (compute-tether-kite-point ax ay (u-x nearest-hellbat) (u-y nearest-hellbat) hx hy 5.4))
             (cons (unit-mode-directive atag at 'kite #f 0 (u-tag nearest-hellbat)
                                        (point2d-x kpt) (point2d-y kpt)
                                        'counter-hellbat-kite-4.5)
                   acc)]
            ;; (c2) Focus-fire landed VikingAssault (`34`) with ground anti-armor / DPS
            [(and nearest-landed-viking
                  (not flying?)
                  (memq at '(marauder stalker immortal roach ravager hydralisk siege-tank siege-tank-sieged marine zealot)))
             (cons (unit-mode-directive atag at 'attack-unit #f 0 (u-tag nearest-landed-viking)
                                        (u-x nearest-landed-viking) (u-y nearest-landed-viking)
                                        'counter-viking-assault-ground-focus)
                   acc)]
            ;; (b2) Close/surround Hellion (`53`) when no Hellbat splash nearby
            [(and nearest-hellion
                  (or (not nearest-hellbat) (> d-hb 6.0))
                  (not flying?)
                  (memq at '(zergling stalker reaper roach ravager marauder zealot adept hydralisk marine)))
             (cons (unit-mode-directive atag at 'attack-unit #f 0 (u-tag nearest-hellion)
                                        (u-x nearest-hellion) (u-y nearest-hellion)
                                        'counter-hellion-close-surround)
                   acc)]
            ;; (c3) Swarm Thor High-Impact (`691`) with light melee / ground forces
            [(and nearest-thor-hi
                  (not flying?)
                  (memq at '(zergling zealot baneling marauder immortal roach hydralisk)))
             (cons (unit-mode-directive atag at 'attack-unit #f 0 (u-tag nearest-thor-hi)
                                        (u-x nearest-thor-hi) (u-y nearest-thor-hi)
                                        'counter-thor-hi-ground-swarm)
                   acc)]
            [else acc])]))]))

;; =============================================================================
;; 6b. WidowMine (`498` <-> `500`) Burrow/Unburrow Hysteresis (`Bug 8b`)
;; =============================================================================

(define WIDOW-MINE-ARMY-EXCLUDE-SYMS : (Listof Symbol)
  '(widow-mine widow-mine-burrowed scv probe drone mule larva egg
    command-center orbital-command planetary-fortress supply-depot
    supply-depot-lowered refinery barracks factory starport bunker
    missile-turret sensor-tower engineering-bay armory ghost-academy
    fusion-core tech-lab reactor auto-turret))

(: widow-mine-main-army-anchor (-> (Listof Any) (Values Boolean Float Float)))
(define (widow-mine-main-army-anchor ally-units)
  (define-values (bio-mech? bcx bcy _bio?) (main-army-centroid ally-units))
  (if bio-mech?
      (values #t bcx bcy)
      (for/fold ([sx : Float 0.0] [sy : Float 0.0] [n : Integer 0]
                 #:result (if (> n 0)
                              (values #t (/ sx (->float n)) (/ sy (->float n)))
                              (values #f 0.0 0.0)))
                ([a (in-list ally-units)]
                 #:when (and (u-alive? a)
                             (not (u-structure? a))
                             (not (memq (exact-unit-type a) WIDOW-MINE-ARMY-EXCLUDE-SYMS))))
        (values (+ sx (u-x a)) (+ sy (u-y a)) (add1 n)))))

(: widow-mine-holding-defense? (-> Float Float Any (Listof Any) (Listof (Pairof Float Float)) Boolean))
(define (widow-mine-holding-defense? wx wy wm-u ally-units anchors)
  (or (eq? (dyn-hash-ref wm-u 'holding-defensive-choke? #f) #t)
      (eq? (dyn-hash-ref wm-u 'near-mineral-line? #f) #t)
      (for/or : Boolean ([pt (in-list anchors)])
        (<= (dist-2d wx wy (car pt) (cdr pt)) 9.5))
      (for/or : Boolean ([a (in-list ally-units)]
                         #:when (u-alive? a))
        (define ut (exact-unit-type a))
        (cond
          [(memq ut '(command-center orbital-command planetary-fortress nexus hatchery lair hive))
           (<= (dist-2d wx wy (u-x a) (u-y a)) 10.5)]
          [(memq ut '(bunker missile-turret supply-depot supply-depot-lowered sensor-tower))
           (<= (dist-2d wx wy (u-x a) (u-y a)) 7.5)]
          [else #f]))))

;; Evaluates a WidowMine (`498` / `500`) mode decision with strict hysteresis:
;; - Burrow (`2095`) when enemy `<= 11.5` tiles or holding defensive choke/mineral line;
;; - Once burrowed, do NOT Unburrow (`2097`) unless `>= 44f` cooldown elapsed AND
;;   no enemy within `15.5` tiles AND main army anchor `> 18.0` tiles away.
(: evaluate-widow-mine-mode
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:defensive-anchors (Listof (Pairof Float Float)))
        (Option unit-mode-directive)))
(define (evaluate-widow-mine-mode wm-u ally-units enemy-units
                                  #:tracker [tr #f]
                                  #:current-frame [current-frame 0]
                                  #:defensive-anchors [anchors '()])
  (define wt (exact-unit-type wm-u))
  (cond
    [(or (not (u-alive? wm-u))
         (not (memq wt '(widow-mine widow-mine-burrowed))))
     #f]
    [else
     (define wtag (u-tag wm-u))
     (define wx (u-x wm-u))
     (define wy (u-y wm-u))
     (define burrowed?
       (or (eq? wt 'widow-mine-burrowed)
           (eq? (dyn-hash-ref wm-u 'burrowed #f) #t)))
     (define wm-tbl (and tr (unit-mode-tracker-widow-mine-modes tr)))
     (when (and wm-tbl (> wtag 0))
       (sync-unit-mode-entry! wm-tbl wtag current-frame (if burrowed? 'burrowed 'mobile)))
     (define dwell
       (if (and wm-tbl (> wtag 0))
           (mode-dwell-elapsed wm-tbl wtag current-frame)
           10000))
     (define cooldown-ok? (>= dwell WIDOW-MINE-MODE-COOLDOWN-FRAMES))
     (define near-enemy-dist
       (for/fold ([best : Float 1e9])
                 ([e (in-list enemy-units)]
                  #:when (and (u-alive? e)
                              (not (eq? (dyn-hash-ref e 'is-hallucination? #f) #t))))
         (min best (dist-2d wx wy (u-x e) (u-y e)))))
     (cond
       [(not burrowed?)
        (define hold-def? (widow-mine-holding-defense? wx wy wm-u ally-units anchors))
        (define enemy-close? (<= near-enemy-dist WIDOW-MINE-BURROW-ENEMY-RANGE))
        (cond
          [(and cooldown-ok? (or enemy-close? hold-def?))
           (when (and wm-tbl (> wtag 0))
             (record-mode-switch! wm-tbl wtag current-frame 'burrowed))
           (unit-mode-directive wtag wt 'cast-spell 'widow-mine-burrow
                                WIDOW-MINE-BURROW-ABILITY-ID wtag wx wy
                                (if enemy-close?
                                    'widow-mine-burrow-enemy-in-range
                                    'widow-mine-burrow-defensive-choke))]
          [else #f])]
       [else
        (define-values (has-army? acx acy) (widow-mine-main-army-anchor ally-units))
        (define army-far?
          (and has-army?
               (> (dist-2d wx wy acx acy) WIDOW-MINE-UNBURROW-ARMY-DIST)))
        (define clear-15.5? (> near-enemy-dist WIDOW-MINE-UNBURROW-CLEAR-RADIUS))
        (cond
          [(and cooldown-ok? clear-15.5? army-far?)
           (when (and wm-tbl (> wtag 0))
             (record-mode-switch! wm-tbl wtag current-frame 'mobile))
           (unit-mode-directive wtag wt 'cast-spell 'widow-mine-unburrow
                                WIDOW-MINE-UNBURROW-ABILITY-ID wtag wx wy
                                'widow-mine-unburrow-clear-army-far)]
          [else #f])])]))

(: plan-widow-mine-modes/list
   (-> (Listof Any) (Listof Any) (Listof Any) (Option unit-mode-tracker) Integer
       (Listof (Pairof Float Float)) (Listof unit-mode-directive)))
(define (plan-widow-mine-modes/list wms ally-units enemy-units tr current-frame anchors)
  (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
            ([wm (in-list wms)])
    (define d (evaluate-widow-mine-mode wm ally-units enemy-units
                                        #:tracker tr
                                        #:current-frame current-frame
                                        #:defensive-anchors anchors))
    (if d (cons d acc) acc)))

(: plan-widow-mine-modes
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option unit-mode-tracker)
         #:current-frame Integer
         #:defensive-anchors (Listof (Pairof Float Float)))
        (Listof unit-mode-directive)))
(define (plan-widow-mine-modes ally-units enemy-units
                               #:tracker [tr #f]
                               #:current-frame [current-frame 0]
                               #:defensive-anchors [anchors '()])
  (define wms
    (for/fold ([rev : (Listof Any) '()] #:result (reverse rev))
              ([a (in-list ally-units)]
               #:when (and (u-alive? a)
                           (memq (exact-unit-type a) '(widow-mine widow-mine-burrowed))))
      (cons a rev)))
  (if (null? wms)
      '()
      (plan-widow-mine-modes/list wms ally-units enemy-units tr current-frame anchors)))

;; =============================================================================
;; 6c. SiegeTank (`32`) Friendly-Fire Splash Target Guard (`Bug 9`)
;; =============================================================================

(: unit-splash-supply (-> Any Symbol Float))
(define (unit-splash-supply u ut)
  (case ut
    [(zergling zergling-burrowed baneling baneling-burrowed) 0.5]
    [else (->float (sc2-supply-cost ut (if (u-structure? u) 0 1)))]))

;; Returns `#t` iff firing a SiegeTank shot at `enemy-u` will NOT splash friendly
;; clusters where `friendly-supply > enemy-supply` within splash envelope (`1.75` tiles).
(: siege-tank-target-safe? (-> Any Any (Listof Any) (Listof Any) Boolean))
(define (siege-tank-target-safe? tank-u enemy-u ally-units enemy-units)
  (define tank-tag (u-tag tank-u))
  (define tx (u-x enemy-u))
  (define ty (u-y enemy-u))
  (define splash-check-r (+ SIEGE-TANK-SPLASH-RADIUS 0.5))
  (define friendly-sup : Float
    (for/fold ([sup : Float 0.0])
              ([a (in-list ally-units)]
               #:when (and (u-alive? a)
                           (not (= (u-tag a) tank-tag))
                           (not (u-flying? a))))
      (define ax (u-x a))
      (define ay (u-y a))
      (if (and (<= (abs (- tx ax)) splash-check-r)
               (<= (abs (- ty ay)) splash-check-r)
               (<= (dist-2d tx ty ax ay) splash-check-r))
          (+ sup (unit-splash-supply a (exact-unit-type a)))
          sup)))
  (cond
    [(<= friendly-sup 0.0) #t]
    [else
     (define enemy-sup : Float
       (for/fold ([sup : Float 0.0])
                 ([e (in-list enemy-units)]
                  #:when (and (u-alive? e)
                              (not (u-flying? e))))
         (define ex (u-x e))
         (define ey (u-y e))
         (if (and (<= (abs (- tx ex)) splash-check-r)
                  (<= (abs (- ty ey)) splash-check-r)
                  (<= (dist-2d tx ty ex ey) splash-check-r))
             (+ sup (unit-splash-supply e (exact-unit-type e)))
             sup)))
     (not (> friendly-sup enemy-sup))]))

;; Selects splash-safe `siege-tank-sieged` (`32`) attack directives in `[2.0 .. 13.0]` range.
;; When `only-on-splash-risk?` is `#t`, emits only when at least one in-range ground target
;; threatens friendly splash (`friendly-supply > enemy-supply`) so safe targets exist cleanly.
(: plan-siege-tank-targets/list
   (-> (Listof Any) (Listof Any) (Listof Any) Boolean (Listof unit-mode-directive)))
(define (plan-siege-tank-targets/list tanks ally-units enemy-units only-on-splash-risk?)
  (define ground-enemies
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (u-alive? e)
                                          (> (u-tag e) 0)
                                          (not (u-flying? e))))
      e))
  (if (or (null? tanks) (null? ground-enemies))
      '()
      (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
                ([t (in-list tanks)]
                 #:when (and (u-alive? t) (eq? (exact-unit-type t) 'siege-tank-sieged)))
        (define ttag (u-tag t))
        (define tx (u-x t))
        (define ty (u-y t))
        (define-values (best-safe best-safe-score any-unsafe?)
          (for/fold ([best : (Option Any) #f]
                     [best-sc : Float -1e9]
                     [unsafe? : Boolean #f])
                    ([e (in-list ground-enemies)])
            (define d (dist-2d tx ty (u-x e) (u-y e)))
            (cond
              [(or (< d 2.0) (> d 13.0))
               (values best best-sc unsafe?)]
              [(not (siege-tank-target-safe? t e ally-units ground-enemies))
               (values best best-sc #t)]
              [else
               (define esym (exact-unit-type e))
               (define ehp (max 1.0 (u-total-ehp e)))
               (define sc (- (* 100.0 (unit-splash-supply e esym)) (* 0.05 ehp) (* 0.5 d)))
               (if (> sc best-sc)
                   (values e sc unsafe?)
                   (values best best-sc unsafe?))])))
        (if (and best-safe (or (not only-on-splash-risk?) any-unsafe?))
            (cons (unit-mode-directive ttag 'siege-tank-sieged 'attack-unit #f 0
                                       (u-tag best-safe) (u-x best-safe) (u-y best-safe)
                                       'siege-tank-splash-safe-target)
                  acc)
            acc))))

(: plan-siege-tank-targets
   (->* ((Listof Any) (Listof Any))
        (#:only-on-splash-risk? Boolean)
        (Listof unit-mode-directive)))
(define (plan-siege-tank-targets ally-units enemy-units
                                 #:only-on-splash-risk? [only-on-splash-risk? #f])
  (define tanks
    (for/fold ([rev : (Listof Any) '()] #:result (reverse rev))
              ([a (in-list ally-units)]
               #:when (and (u-alive? a) (eq? (exact-unit-type a) 'siege-tank-sieged)))
      (cons a rev)))
  (plan-siege-tank-targets/list tanks ally-units enemy-units only-on-splash-risk?))

;; =============================================================================
;; 7. Unified S-Expression Action Conversion & Orchestrator
;; =============================================================================

;; Converts a `unit-mode-directive` into a runtime-compatible S-expression command.
(: unit-mode-directive->sexp (-> unit-mode-directive (Listof Any)))
(define (unit-mode-directive->sexp d)
  (case (unit-mode-directive-action d)
    [(load-into-transport)
     (list 'transport-juggle
           (unit-mode-directive-target-tag d)
           (list (unit-mode-directive-unit-tag d))
           (unit-mode-directive-tx d)
           (unit-mode-directive-ty d))]
    [(burrow-down)
     (define ab (unit-mode-directive-ability-id d))
     (if (> ab 0)
         (list 'burrow-down
               (unit-mode-directive-unit-tag d)
               (or (unit-mode-directive-ability d) 'unit-mode-micro)
               ab)
         (list 'burrow-down (unit-mode-directive-unit-tag d)))]
    [(burrow-up)
     (define ab (unit-mode-directive-ability-id d))
     (if (> ab 0)
         (list 'burrow-up
               (unit-mode-directive-unit-tag d)
               (or (unit-mode-directive-ability d) 'unit-mode-micro)
               ab)
         (list 'burrow-up (unit-mode-directive-unit-tag d)))]
    [(blink)
     (list 'cast-spell
           (unit-mode-directive-unit-tag d)
           'blink
           (unit-mode-directive-tx d)
           (unit-mode-directive-ty d))]
    [(cast-spell)
     (define ab (unit-mode-directive-ability d))
     (define tgt (unit-mode-directive-target-tag d))
     ;; W12-P0-4-rt (`w12-tac-3`): Emit zero-target mode toggles as 3-element `(cast-spell uid ab)`
     ;; so Layer-5 `pre-coalesced-actions` & `human-cortex` coalesce full squads into 1 command!
     (if (memq ab '(morph-viking-fighter morph-viking-assault
                    morph-hellbat morph-hellion
                    morph-thor-high-impact morph-thor-explosive
                    siege-mode unsiege-mode
                    widow-mine-burrow widow-mine-unburrow
                    lurker-burrow lurker-unburrow))
         (list 'cast-spell
               (unit-mode-directive-unit-tag d)
               ab)
         (list 'cast-spell
               (unit-mode-directive-unit-tag d)
               (or ab 'unknown)
               (if (> tgt 0) tgt (unit-mode-directive-unit-tag d))))]
    [(move kite retreat attack-pos)
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
  (define thor-tbl (unit-mode-tracker-thor-modes tr))
  (define hellion-tbl (unit-mode-tracker-hellion-modes tr))
  (define viking-tbl (unit-mode-tracker-viking-modes tr))
  (define wm-tbl (unit-mode-tracker-widow-mine-modes tr))
  (define auto-armory-init? (not (eq? armory-arg 'auto)))
  (define-values (thors-rev hellions-rev vikings-rev cyclones-rev marauders-rev widow-mines-rev siege-tanks-rev armory-ok?)
    (for/fold ([ts : (Listof Any) '()]
               [hs : (Listof Any) '()]
               [vs : (Listof Any) '()]
               [cs : (Listof Any) '()]
               [ms : (Listof Any) '()]
               [wms : (Listof Any) '()]
               [tks : (Listof Any) '()]
               [arm? : Boolean auto-armory-init?])
              ([a (in-list ally-units)]
               #:when (u-alive? a))
      (define ut (exact-unit-type a))
      (case ut
        [(thor)
         (define tag (u-tag a))
         (when (> tag 0) (sync-unit-mode-entry! thor-tbl tag current-frame 'explosive))
         (values (cons a ts) hs vs cs ms wms tks arm?)]
        [(thor-ap)
         (define tag (u-tag a))
         (when (> tag 0) (sync-unit-mode-entry! thor-tbl tag current-frame 'high-impact))
         (values (cons a ts) hs vs cs ms wms tks arm?)]
        [(hellion)
         (define tag (u-tag a))
         (when (> tag 0) (sync-unit-mode-entry! hellion-tbl tag current-frame 'hellion))
         (values ts (cons a hs) vs cs ms wms tks arm?)]
        [(hellbat)
         (define tag (u-tag a))
         (when (> tag 0) (sync-unit-mode-entry! hellion-tbl tag current-frame 'hellbat))
         (values ts (cons a hs) vs cs ms wms tks arm?)]
        [(viking-fighter viking)
         (define tag (u-tag a))
         (when (> tag 0) (sync-unit-mode-entry! viking-tbl tag current-frame 'fighter))
         (values ts hs (cons a vs) cs ms wms tks arm?)]
        [(viking-assault)
         (define tag (u-tag a))
         (when (> tag 0) (sync-unit-mode-entry! viking-tbl tag current-frame 'assault))
         (values ts hs (cons a vs) cs ms wms tks arm?)]
        [(widow-mine widow-mine-burrowed)
         (define tag (u-tag a))
         (when (> tag 0)
           (sync-unit-mode-entry! wm-tbl tag current-frame
                                 (if (or (eq? ut 'widow-mine-burrowed)
                                         (eq? (dyn-hash-ref a 'burrowed #f) #t))
                                     'burrowed
                                     'mobile)))
         (values ts hs vs cs ms (cons a wms) tks arm?)]
        [(siege-tank-sieged)
         (values ts hs vs cs ms wms (cons a tks) arm?)]
        [(cyclone)
         (values ts hs vs (cons a cs) ms wms tks arm?)]
        [(marauder)
         (values ts hs vs cs (cons a ms) wms tks arm?)]
        [(armory)
         (values ts hs vs cs ms wms tks (or arm? (and (eq? armory-arg 'auto) (u-completed? a))))]
        [else
         (values ts hs vs cs ms wms tks arm?)])))
  (sync-unit-mode-tracker-post! tr ally-units enemy-units current-frame dead-tags track-air-memory?)
  (define thor-dirs
    (if (null? thors-rev)
        '()
        (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
                  ([a (in-list (reverse thors-rev))])
          (define d (evaluate-thor-mode a enemy-units #:tracker tr #:current-frame current-frame))
          (if d (cons d acc) acc))))
  (define hellion-dirs
    (if (or (null? hellions-rev) (not armory-ok?) (eq? armory-arg #f))
        '()
        (let-values ([(has-army? acx acy has-bio?) (main-army-centroid ally-units)])
          (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
                    ([a (in-list (reverse hellions-rev))])
            (define d (evaluate-hellion-mode/centroid a enemy-units tr current-frame 'auto
                                                      has-army? acx acy has-bio?))
            (if d (cons d acc) acc)))))
  (define viking-dirs
    (if (null? vikings-rev)
        '()
        (plan-viking-modes/list (reverse vikings-rev) ally-units enemy-units
                                tr current-frame home-x home-y enemy-air-memory)))
  (define cyclone-dirs
    (if (null? cyclones-rev)
        '()
        (let ([claimed : (Mutable-HashTable Integer Boolean) (make-hasheqv)])
          (for/fold ([acc : (Listof unit-mode-directive) '()] #:result (reverse acc))
                    ([a (in-list (reverse cyclones-rev))])
            (define d (evaluate-cyclone-micro a enemy-units ally-units
                                              #:tracker tr
                                              #:current-frame current-frame
                                              #:home-x home-x
                                              #:home-y home-y
                                              #:claimed-targets claimed))
            (if d (cons d acc) acc)))))
  (define marauder-orders
    (if (null? marauders-rev)
        '()
        (plan-marauder-concussive-targets/list (reverse marauders-rev) enemy-units
                                               tr current-frame concussive-ok?)))
  (define widow-mine-dirs
    (if (null? widow-mines-rev)
        '()
        (plan-widow-mine-modes/list (reverse widow-mines-rev) ally-units enemy-units
                                    tr current-frame '())))
  (define siege-tank-dirs
    (if (null? siege-tanks-rev)
        '()
        (plan-siege-tank-targets/list (reverse siege-tanks-rev) ally-units enemy-units #t)))
  (if (and (null? thor-dirs)
           (null? hellion-dirs)
           (null? viking-dirs)
           (null? cyclone-dirs)
           (null? marauder-orders)
           (null? widow-mine-dirs)
           (null? siege-tank-dirs))
      '()
      (append
       (if (null? thor-dirs) '() (map unit-mode-directive->sexp thor-dirs))
       (if (null? hellion-dirs) '() (map unit-mode-directive->sexp hellion-dirs))
       (if (null? viking-dirs) '() (map unit-mode-directive->sexp viking-dirs))
       (if (null? cyclone-dirs) '() (map unit-mode-directive->sexp cyclone-dirs))
       (if (null? marauder-orders) '() (map marauder-order->sexp marauder-orders))
       (if (null? widow-mine-dirs) '() (map unit-mode-directive->sexp widow-mine-dirs))
       (if (null? siege-tank-dirs) '() (map unit-mode-directive->sexp siege-tank-dirs)))))
