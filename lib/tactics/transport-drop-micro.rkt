#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/transport-drop-micro.rkt`
;; Empirical Pro-Calibrated Transport Save-Pickup, Safe/Moving Drop &
;; WarpPrism Phasing Micro Module (Typed Racket):
;;
;;   1. Combat Save-Pickup (`'medivac` 54, `'warp-prism` 81/136,
;;      `'overlord-transport` 893):
;;      Rescues high-value bruised units (`< 0.42` HP+shield ratio, or `< 0.55`
;;      with `>= 2` attackers in range), `!nova-ready` Disruptors within `9.0`
;;      of enemies, and units in Nova/Bile/Storm/Cloud danger zones; honors
;;      `5.0`-tile WarpPrism vs `1.5`-tile Medivac/Dropperlord pickup range and
;;      tracks per-passenger `pickup-frame`.
;;   2. Safe Rear-Offset Drop & Moving Self-Drop (`#115`):
;;      Supports safe `[3.5..5.0]`-tile rear-offset drops outside AoE zones AND
;;      self-targeted moving drops (`'transport-drop-moving` targeting transport's
;;      own `tag`, including Medivac `Boost -> Unload` `16f-36f` cadence) once
;;      carry dwell `>= 18f` (0.8s), plus a `672f` (30s) stuck-cargo ceiling and
;;      `< 25%` emergency dump.
;;   3. `WarpPrism` Phasing (`'morph-warp-prism-phasing` 1528 <-> `1530`):
;;      `140f` (6.25s) min dwell, `208f` (9.3s) target warp cycle, `160f`
;;      re-phase cooldown, immediate unphase on `< 10.0`-tile threat, `< 65%`
;;      HP+shield, army `> 9.0` tiles away, or emergency save-pickup `<= 9.0`.
;;   4. `OverlordTransport` Eligibility (`'morph-overlord-transport` 2708):
;;      `should-morph-overlord-transport?` gated on Lair/Hive readiness,
;;      Roach/Hydra/Lurker/Bane/Queen combat supply `>= 16`, and active `< 2`.
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
 MEDIVAC-UNIT-TYPE-ID
 WARP-PRISM-UNIT-TYPE-ID
 WARP-PRISM-PHASING-UNIT-TYPE-ID
 OVERLORD-TRANSPORT-UNIT-TYPE-ID
 LOAD-TRANSPORT-ABILITY-ID
 UNLOAD-ALL-AT-ABILITY-ID
 MEDIVAC-UNLOAD-ALL-AT-ABILITY-ID
 WARP-PRISM-UNLOAD-ALL-AT-ABILITY-ID
 OVERLORD-UNLOAD-ALL-AT-ABILITY-ID
 MEDIVAC-BOOST-ABILITY-ID
 MORPH-WARP-PRISM-PHASING-ABILITY-ID
 MORPH-WARP-PRISM-TRANSPORT-ABILITY-ID
 MORPH-OVERLORD-TRANSPORT-ABILITY-ID
 TRANSPORT-MAX-CARGO-CAPACITY

 ;; Pro-Calibrated Thresholds & Dwell Constants
 TRANSPORT-SAVE-SEARCH-RADIUS
 WARP-PRISM-PICKUP-RANGE
 STANDARD-TRANSPORT-PICKUP-RANGE
 SAVE-BRUISED-HP-RATIO
 SAVE-UNDER-FIRE-HP-RATIO
 SAVE-HIGH-VALUE-SYMS
 SAFE-DROP-REAR-OFFSET-MIN
 SAFE-DROP-REAR-OFFSET-MAX
 MIN-CARRY-DWELL-FRAMES
 MEDIVAC-BOOST-UNLOAD-MIN-FRAMES
 MEDIVAC-BOOST-UNLOAD-MAX-FRAMES
 STUCK-CARGO-CEILING-FRAMES
 EMERGENCY-DUMP-HP-RATIO
 WARP-PRISM-MIN-PHASING-DWELL-FRAMES
 WARP-PRISM-TARGET-WARP-CYCLE-FRAMES
 WARP-PRISM-REPHASE-COOLDOWN-FRAMES
 WARP-PRISM-THREAT-UNPHASE-RADIUS
 WARP-PRISM-UNPHASE-HP-RATIO
 WARP-PRISM-ARMY-LEASH-RADIUS
 DROPPERLORD-MIN-COMBAT-SUPPLY
 DROPPERLORD-MAX-ACTIVE-COUNT

 ;; Typed Data Structs
 (struct-out transport-unit-input)
 (struct-out danger-zone)
 (struct-out transport-directive)

 ;; Tracker Management & Accessors
 transport-tracker?
 make-transport-tracker
 TRANSPORT-LOAD-UNLOAD-COOLDOWN-FRAMES
 WARP-PRISM-MODE-TOGGLE-COOLDOWN-FRAMES
 transport-tracker-record-pickup!
 transport-tracker-record-load!
 transport-tracker-record-unload!
 transport-tracker-load-cooldown
 transport-tracker-unload-cooldown
 transport-tracker-record-boost!
 transport-tracker-passenger-pickup-frame
 transport-tracker-carry-dwell-frames
 transport-tracker-prism-phase-dwell
 transport-tracker-prism-rephase-cooldown
 sync-transport-tracker!

 ;; Predicates, Danger Detection & Spatial Helpers
 transport-unit-sym?
 transport-unload-ability-id
 transport-pickup-range
 unit-cargo-size
 collect-active-danger-zones
 point-in-danger-zones?
 count-attackers-in-range
 save-pickup-candidate-priority
 compute-safe-rear-drop-point
 overlord-drop-combat-supply
 overlord-transport-eligible?
 should-morph-overlord-transport?

  ;; Single-Transport & Fleet Planners
  evaluate-save-pickup
  evaluate-transport-drop
  evaluate-warp-prism-phasing
  evaluate-transport-micro
  plan-transport-fleet-micro
  plan-overlord-transport-morphs

  ;; Wave 1C Multi-Angle Mini Overlord Drops & Counter-Drop Defense
  MINI-DROP-MAX-ACTIVE-COUNT
  MINI-DROP-CARGO-MIN
  MINI-DROP-CARGO-MAX
  DROP-LOADED-FOCUS-FIRE-BONUS
  COUNTER-DROP-DEFENSE-POWER-MULT
  COUNTER-DROP-MAX-ARMY-PULL-FRACTION
  (struct-out counter-drop-order)
  (struct-out counter-drop-plan)
  plan-multi-angle-mini-overlord-drops
  plan-counter-drop-defense
  counter-drop-plan->sexps

  ;; L59-P2 (`#1481`) 13-Row Pro Drop Profiles, 3-Race Cliff Laddering & Raid Evac/Rotation
  (struct-out drop-profile)
  DROP-PROFILE-TABLE
  lookup-drop-profile
  infer-drop-profile
  plan-cliff-ladder-shuttle
  plan-raid-evac-and-rotate

  ;; S-Expression Orchestrator
  transport-directive->sexp
  step-transport-drop-micro!)

;; =============================================================================
;; Constants (LotV Balance / Empirical `#115` Calibration at 22.4 fps)
;; =============================================================================

;; SC2 Unit Type IDs (`lib/sc2-protobuf-ws.rkt:661,755,813-814`)
(: MEDIVAC-UNIT-TYPE-ID Integer)
(define MEDIVAC-UNIT-TYPE-ID 54)

(: WARP-PRISM-UNIT-TYPE-ID Integer)
(define WARP-PRISM-UNIT-TYPE-ID 81)

(: WARP-PRISM-PHASING-UNIT-TYPE-ID Integer)
(define WARP-PRISM-PHASING-UNIT-TYPE-ID 136)

(: OVERLORD-TRANSPORT-UNIT-TYPE-ID Integer)
(define OVERLORD-TRANSPORT-UNIT-TYPE-ID 893)

;; Canonical Wire Ability IDs (`sc2-typed-commands.rkt:260,352-362,1664,1683-1684`)
(: LOAD-TRANSPORT-ABILITY-ID Integer)
(define LOAD-TRANSPORT-ABILITY-ID 3668)

(: UNLOAD-ALL-AT-ABILITY-ID Integer)
(define UNLOAD-ALL-AT-ABILITY-ID 3669)

(: MEDIVAC-UNLOAD-ALL-AT-ABILITY-ID Integer)
(define MEDIVAC-UNLOAD-ALL-AT-ABILITY-ID 396)

(: WARP-PRISM-UNLOAD-ALL-AT-ABILITY-ID Integer)
(define WARP-PRISM-UNLOAD-ALL-AT-ABILITY-ID 913)

(: OVERLORD-UNLOAD-ALL-AT-ABILITY-ID Integer)
(define OVERLORD-UNLOAD-ALL-AT-ABILITY-ID 1408)

(: MEDIVAC-BOOST-ABILITY-ID Integer)
(define MEDIVAC-BOOST-ABILITY-ID 2116)

(: MORPH-WARP-PRISM-PHASING-ABILITY-ID Integer)
(define MORPH-WARP-PRISM-PHASING-ABILITY-ID 1528)

(: MORPH-WARP-PRISM-TRANSPORT-ABILITY-ID Integer)
(define MORPH-WARP-PRISM-TRANSPORT-ABILITY-ID 1530)

(: MORPH-OVERLORD-TRANSPORT-ABILITY-ID Integer)
(define MORPH-OVERLORD-TRANSPORT-ABILITY-ID 2708)

(: TRANSPORT-MAX-CARGO-CAPACITY Integer)
(define TRANSPORT-MAX-CARGO-CAPACITY 8)

;; Save-Pickup Constants
(: TRANSPORT-SAVE-SEARCH-RADIUS Float)
(define TRANSPORT-SAVE-SEARCH-RADIUS 9.0)

(: WARP-PRISM-PICKUP-RANGE Float)
(define WARP-PRISM-PICKUP-RANGE 5.0)

(: STANDARD-TRANSPORT-PICKUP-RANGE Float)
(define STANDARD-TRANSPORT-PICKUP-RANGE 1.5)

(: SAVE-BRUISED-HP-RATIO Float)
(define SAVE-BRUISED-HP-RATIO 0.35)

(: SAVE-UNDER-FIRE-HP-RATIO Float)
(define SAVE-UNDER-FIRE-HP-RATIO 0.35)

;; W11-P0-4-rt (`w11-tac-5` / `t04` + `novel-84`): Frontline Medivac-healable bio (`marauder`)
;; should stay fighting and absorb `12.6 HP/s` Medivac heal beam rather than being `3668`-yanked
;; at 30% HP when no lethal AoE is present; still rescue at lethal-threshold `<= 22%` HP (e.g.
;; `25/125` one-swipe Ultralisk danger in `novel-84`) or whenever inside an AoE danger zone.
(: SAVE-CRITICAL-BIO-HP-RATIO Float)
(define SAVE-CRITICAL-BIO-HP-RATIO 0.22)

(: SAVE-HIGH-VALUE-SYMS (Listof Symbol))
(define SAVE-HIGH-VALUE-SYMS
  '(immortal archon colossus high-templar disruptor dark-templar zealot
    siege-tank thor thor-ap cyclone ghost marauder marine widow-mine hellbat hellion
    lurker lurker-mp ravager roach hydralisk queen infestor baneling zergling))

(: SAVE-CRITICAL-BIO-SYMS (Listof Symbol))
(define SAVE-CRITICAL-BIO-SYMS
  '(marauder marine hellbat hellion zealot zergling))

;; Drop & Emergency Dump Constants
(: TRANSPORT-LOAD-UNLOAD-COOLDOWN-FRAMES Integer)
(define TRANSPORT-LOAD-UNLOAD-COOLDOWN-FRAMES 44)

(: SAFE-DROP-REAR-OFFSET-MIN Float)
(define SAFE-DROP-REAR-OFFSET-MIN 3.5)

(: SAFE-DROP-REAR-OFFSET-MAX Float)
(define SAFE-DROP-REAR-OFFSET-MAX 5.0)

(: MIN-CARRY-DWELL-FRAMES Integer)
(define MIN-CARRY-DWELL-FRAMES 18)

(: MEDIVAC-BOOST-UNLOAD-MIN-FRAMES Integer)
(define MEDIVAC-BOOST-UNLOAD-MIN-FRAMES 16)

(: MEDIVAC-BOOST-UNLOAD-MAX-FRAMES Integer)
(define MEDIVAC-BOOST-UNLOAD-MAX-FRAMES 36)

(: STUCK-CARGO-CEILING-FRAMES Integer)
(define STUCK-CARGO-CEILING-FRAMES 672)

(: EMERGENCY-DUMP-HP-RATIO Float)
(define EMERGENCY-DUMP-HP-RATIO 0.25)

;; WarpPrism Phasing Constants (`#115` empirical dwells & anti-oscillation cooldowns)
(: WARP-PRISM-MODE-TOGGLE-COOLDOWN-FRAMES Integer)
(define WARP-PRISM-MODE-TOGGLE-COOLDOWN-FRAMES 44)

(: WARP-PRISM-MIN-PHASING-DWELL-FRAMES Integer)
(define WARP-PRISM-MIN-PHASING-DWELL-FRAMES 140)

(: WARP-PRISM-TARGET-WARP-CYCLE-FRAMES Integer)
(define WARP-PRISM-TARGET-WARP-CYCLE-FRAMES 208)

(: WARP-PRISM-REPHASE-COOLDOWN-FRAMES Integer)
(define WARP-PRISM-REPHASE-COOLDOWN-FRAMES 160)

(: WARP-PRISM-THREAT-UNPHASE-RADIUS Float)
(define WARP-PRISM-THREAT-UNPHASE-RADIUS 6.0)

(: WARP-PRISM-UNPHASE-HP-RATIO Float)
(define WARP-PRISM-UNPHASE-HP-RATIO 0.65)

(: WARP-PRISM-ARMY-LEASH-RADIUS Float)
(define WARP-PRISM-ARMY-LEASH-RADIUS 9.0)

;; OverlordTransport Eligibility Constants
(: DROPPERLORD-MIN-COMBAT-SUPPLY Integer)
(define DROPPERLORD-MIN-COMBAT-SUPPLY 16)

(: DROPPERLORD-MAX-ACTIVE-COUNT Integer)
(define DROPPERLORD-MAX-ACTIVE-COUNT 2)

;; =============================================================================
;; Public Data Structs
;; =============================================================================

;; Optional structured unit record accepted interchangeably with unit hashes.
(struct transport-unit-input
  ([tag : Integer]
   [type : Symbol]
   [x : Float]
   [y : Float]
   [hp : Float]
   [max-hp : Float]
   [shield : Float]
   [max-shield : Float]
   [flying? : Boolean]
   [passengers : (Listof Integer)]
   [cargo-space-taken : Integer]
   [moving? : Boolean]
   [ground-safe? : Boolean]
   [boost-ready? : Boolean]
   [nova-ready? : Boolean])
  #:transparent)

;; Active AoE danger zone (Nova, Bile, Psi Storm, Blinding Cloud).
(struct danger-zone
  ([kind : Symbol]
   [x : Float]
   [y : Float]
   [radius : Float]
   [expires-frame : Integer])
  #:transparent)

;; Tactical transport/drop/phasing directive returned by planners.
(struct transport-directive
  ([transport-tag : Integer]
   [transport-type : Symbol]
   [action : Symbol]
   [ability : (Option Symbol)]
   [ability-id : Integer]
   [target-tag : Integer]
   [passenger-tags : (Listof Integer)]
   [tx : Float]
   [ty : Float]
   [reason : Symbol])
  #:transparent)

;; =============================================================================
;; Cross-Frame Transport Tracker (`transport-tracker`)
;; =============================================================================

(struct prism-phase-rec
  ([phase-start-frame : Integer]
   [last-unphase-frame : Integer]
   [phasing? : Boolean])
  #:transparent)

;; Opaque mutable tracker recording per-passenger pickup frames, Medivac Boost timestamps,
;; transport carry age, and WarpPrism phasing cycles.
(struct transport-tracker
  ([passenger-pickup-table : (Mutable-HashTable Integer Integer)]
   [transport-cargo-since : (Mutable-HashTable Integer Integer)]
   [medivac-last-boost : (Mutable-HashTable Integer Integer)]
   [prism-phases : (Mutable-HashTable Integer prism-phase-rec)]
   [transport-last-load : (Mutable-HashTable Integer Integer)]
   [transport-last-unload : (Mutable-HashTable Integer Integer)]
   [transport-seen-empty : (Mutable-HashTable Integer Boolean)]))

;; Creates a fresh empty `transport-tracker`.
(: make-transport-tracker (-> transport-tracker))
(define (make-transport-tracker)
  (transport-tracker
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)))

;; Records a transport Load (`MedivacLoad` / `WarpPrismLoad` / `3668`) frame.
(: transport-tracker-record-load! (-> transport-tracker Integer Integer Void))
(define (transport-tracker-record-load! tr tr-tag current-frame)
  (when (> tr-tag 0)
    (hash-set! (transport-tracker-transport-last-load tr) tr-tag current-frame)
    (hash-remove! (transport-tracker-transport-seen-empty tr) tr-tag)))

;; Records a transport UnloadAt (`396` / `913` / `1408` / `3669`) frame.
(: transport-tracker-record-unload! (-> transport-tracker Integer Integer Void))
(define (transport-tracker-record-unload! tr tr-tag current-frame)
  (when (> tr-tag 0)
    (hash-set! (transport-tracker-transport-last-unload tr) tr-tag current-frame)))

;; Returns remaining loops before `tr-tag` may Load again after an UnloadAt (0 when ready).
(: transport-tracker-load-cooldown (-> transport-tracker Integer Integer Integer))
(define (transport-tracker-load-cooldown tr tr-tag current-frame)
  (define last-u (hash-ref (transport-tracker-transport-last-unload tr) tr-tag (lambda () #f)))
  (if last-u
      (max 0 (- (+ last-u TRANSPORT-LOAD-UNLOAD-COOLDOWN-FRAMES) current-frame))
      0))

;; Returns remaining loops before `tr-tag` may UnloadAt again after a Load (0 when ready).
(: transport-tracker-unload-cooldown (-> transport-tracker Integer Integer Integer))
(define (transport-tracker-unload-cooldown tr tr-tag current-frame)
  (define last-l (hash-ref (transport-tracker-transport-last-load tr) tr-tag (lambda () #f)))
  (if last-l
      (max 0 (- (+ last-l TRANSPORT-LOAD-UNLOAD-COOLDOWN-FRAMES) current-frame))
      0))

;; Records that `passenger-tag` was loaded at `current-frame` (preserving earliest timestamp if carried).
(: transport-tracker-record-pickup! (-> transport-tracker Integer Integer Integer Void))
(define (transport-tracker-record-pickup! tr tr-tag passenger-tag current-frame)
  (when (> passenger-tag 0)
    (define p-tbl (transport-tracker-passenger-pickup-table tr))
    (unless (hash-has-key? p-tbl passenger-tag)
      (hash-set! p-tbl passenger-tag current-frame)))
  (when (> tr-tag 0)
    (define c-tbl (transport-tracker-transport-cargo-since tr))
    (unless (hash-has-key? c-tbl tr-tag)
      (hash-set! c-tbl tr-tag current-frame))
    (transport-tracker-record-load! tr tr-tag current-frame)))

;; Records a Medivac `Boost` (`2116`) activation frame for Boost -> Unload `16f-36f` cadence tracking.
(: transport-tracker-record-boost! (-> transport-tracker Integer Integer Void))
(define (transport-tracker-record-boost! tr medivac-tag current-frame)
  (when (> medivac-tag 0)
    (hash-set! (transport-tracker-medivac-last-boost tr) medivac-tag current-frame)))

;; Returns recorded `pickup-frame` for `passenger-tag`, or `#f` if unseen.
(: transport-tracker-passenger-pickup-frame (-> transport-tracker Integer (Option Integer)))
(define (transport-tracker-passenger-pickup-frame tr passenger-tag)
  (hash-ref (transport-tracker-passenger-pickup-table tr) passenger-tag (lambda () #f)))

;; Returns carry dwell frames aboard `tr-tag` at `current-frame`.
(: transport-tracker-carry-dwell-frames (-> transport-tracker Integer (Listof Integer) Integer Integer))
(define (transport-tracker-carry-dwell-frames tr tr-tag passenger-tags current-frame)
  (define p-tbl (transport-tracker-passenger-pickup-table tr))
  (define c-tbl (transport-tracker-transport-cargo-since tr))
  (define oldest-passenger-frame
    (for/fold ([oldest : Integer current-frame]
               [any? : Boolean #f]
               #:result (if any? oldest #f))
              ([ptag (in-list passenger-tags)])
      (define pf (hash-ref p-tbl ptag (lambda () #f)))
      (if pf
          (values (if any? (min oldest pf) pf) #t)
          (values oldest any?))))
  (cond
    [oldest-passenger-frame
     (max 0 (- current-frame oldest-passenger-frame))]
    [(hash-ref c-tbl tr-tag (lambda () #f))
     => (lambda ([f0 : Integer]) (max 0 (- current-frame f0)))]
    [else 0]))

;; Returns how many frames a WarpPrism has remained phased at `current-frame`.
(: transport-tracker-prism-phase-dwell (-> transport-tracker Integer Integer Integer))
(define (transport-tracker-prism-phase-dwell tr prism-tag current-frame)
  (define rec (hash-ref (transport-tracker-prism-phases tr) prism-tag (lambda () #f)))
  (if (and rec (prism-phase-rec-phasing? rec))
      (max 0 (- current-frame (prism-phase-rec-phase-start-frame rec)))
      0))

;; Returns remaining WarpPrism re-phase cooldown frames (0 when ready).
(: transport-tracker-prism-rephase-cooldown (-> transport-tracker Integer Integer Integer))
(define (transport-tracker-prism-rephase-cooldown tr prism-tag current-frame)
  (define rec (hash-ref (transport-tracker-prism-phases tr) prism-tag (lambda () #f)))
  (if (and rec (not (prism-phase-rec-phasing? rec)))
      (max 0 (- (+ (prism-phase-rec-last-unphase-frame rec) WARP-PRISM-REPHASE-COOLDOWN-FRAMES)
                current-frame))
      0))

;; Returns `#t` iff a phased WarpPrism has met the `44f` mode-toggle dwell cooldown (or no tracker).
(: prism-can-unphase? (-> (Option transport-tracker) Integer Integer Boolean))
(define (prism-can-unphase? tr prism-tag current-frame)
  (or (not tr)
      (>= (transport-tracker-prism-phase-dwell tr prism-tag current-frame)
          WARP-PRISM-MODE-TOGGLE-COOLDOWN-FRAMES)))

;; =============================================================================
;; Internal Unit Normalization & Cargo Inspection Helpers
;; =============================================================================

(: id->transport-unit-sym (-> Integer Symbol))
(define (id->transport-unit-sym id)
  (case id
    [(54)   'medivac]
    [(81)   'warp-prism]
    [(136)  'warp-prism-phasing]
    [(893)  'overlord-transport]
    [(892)  'transport-overlord-cocoon]
    [(106)  'overlord]
    [(100)  'lair]
    [(101)  'hive]
    [(83)   'immortal]
    [(141)  'archon]
    [(4)    'colossus]
    [(75)   'high-templar]
    [(694)  'disruptor]
    [(733)  'disruptor-phased]
    [(33)   'siege-tank]
    [(32)   'siege-tank-sieged]
    [(52)   'thor]
    [(691)  'thor-ap]
    [(50)   'ghost]
    [(51)   'marauder]
    [(48)   'marine]
    [(53)   'hellion]
    [(484)  'hellbat]
    [(498)  'widow-mine]
    [(500)  'widow-mine-burrowed]
    [(502)  'lurker]
    [(503)  'lurker-burrowed]
    [(688)  'ravager]
    [(110)  'roach]
    [(107)  'hydralisk]
    [(126)  'queen]
    [(111)  'infestor]
    [(9)    'baneling]
    [(8)    'baneling-cocoon]
    [(74)   'stalker]
    [(73)   'zealot]
    [(311)  'adept]
    [(77)   'sentry]
    [(76)   'dark-templar]
    [(105)  'zergling]
    [else   'unknown]))

(: exact-unit-type (-> Any Symbol))
(define (exact-unit-type u)
  (cond
    [(transport-unit-input? u) (transport-unit-input-type u)]
    [(symbol? u) u]
    [(exact-integer? u) (id->transport-unit-sym u)]
    [(hash? u)
     (define raw-ut (dyn-u-raw-type u))
     (cond
       [(symbol? raw-ut) raw-ut]
       [(exact-integer? raw-ut)
        (let ([sym (id->transport-unit-sym raw-ut)])
          (if (not (eq? sym 'unknown)) sym (unit-type-sym u)))]
       [else (unit-type-sym u)])]
    [else 'unknown]))

(: u-tag (-> Any Integer))
(define (u-tag u)
  (cond
    [(transport-unit-input? u) (transport-unit-input-tag u)]
    [(hash? u)
     (define t (dyn-u-raw-tag u))
     (if (exact-integer? t)
         t
         (safe-exact-int t 0))]
    [else 0]))

(: u-x (-> Any Float))
(define (u-x u)
  (if (transport-unit-input? u)
      (transport-unit-input-x u)
      (dyn-u-x u)))

(: u-y (-> Any Float))
(define (u-y u)
  (if (transport-unit-input? u)
      (transport-unit-input-y u)
      (dyn-u-y u)))

(: u-z (-> Any (Option Float)))
(define (u-z u)
  (if (hash? u)
      (let ([raw (or (dyn-hash-ref u 'z #f) (dyn-hash-ref u 'pos-z #f))])
        (if (and (real? raw) (< -inf.0 raw +inf.0))
            (real->double-flonum raw)
            #f))
      #f))

;; =============================================================================
;; L59-P2 (`#1481`) 13-Row Declarative Pro Drop Profile Table
;; =============================================================================
(struct drop-profile
  ([id : Symbol]
   [transport : Symbol]          ;; 'warp-prism | 'medivac | 'overlord-transport | 'any
   [load-cd-frames : Integer]    ;; Per-profile Load<->Unload cadence (`14..44f`)
   [min-dwell-frames : Integer]  ;; Minimum cargo carry dwell (`8..18f`)
   [unload-dist : Float]         ;; Distance to target for drop (`1.2t` Banelings .. `4.0t`)
   [evac-ratio : Float]          ;; Local ally/enemy power ratio below which squad evacuates
   [moving-drop? : Boolean]      ;; Prefer self-targeted moving drop (`transport-drop-moving`)
   [rotate-base? : Boolean])     ;; Rotate to next enemy base to regen shields / re-hit
  #:transparent)

(: DROP-PROFILE-TABLE (Listof drop-profile))
(define DROP-PROFILE-TABLE
  (list
   (drop-profile 'ht-storm            'warp-prism         14  8 2.5 0.50 #f #f)
   (drop-profile 'archon-drop         'warp-prism         18 10 2.5 0.65 #f #t)
   (drop-profile 'disruptor-drop      'warp-prism         16 10 3.0 0.60 #f #f)
   (drop-profile 'immortal-juggle     'warp-prism         16  8 2.5 0.55 #f #f)
   (drop-profile 'prism-warp-in       'warp-prism         44 18 4.0 0.60 #f #f)
   (drop-profile 'widow-mine          'medivac            22 14 1.8 0.60 #t #t)
   (drop-profile 'bio-drop            'medivac            36 18 3.0 0.65 #t #t)
   (drop-profile 'hellbat-drop        'medivac            28 16 2.0 0.65 #t #f)
   (drop-profile 'cliff-tank          'medivac            24 12 2.2 0.60 #f #f)
   (drop-profile 'baneling-drop       'overlord-transport 24 14 1.2 0.55 #t #f)
   (drop-profile 'ling-drop           'overlord-transport 32 16 2.8 0.65 #f #f)
   (drop-profile 'lurker-ravager-drop 'overlord-transport 28 16 3.2 0.60 #f #f)
   (drop-profile 'cliff-ladder        'any                18 10 2.0 0.50 #f #f)))

(: lookup-drop-profile (-> Symbol (Option drop-profile)))
(define (lookup-drop-profile id)
  (for/or : (Option drop-profile) ([p (in-list DROP-PROFILE-TABLE)])
    (and (eq? (drop-profile-id p) id) p)))

(: infer-drop-profile (-> Symbol (Listof Symbol) drop-profile))
(define (infer-drop-profile tr-sym cargo-syms)
  (define chosen-id : Symbol
    (case tr-sym
      [(warp-prism warp-prism-phasing)
       (cond
         [(memq 'high-templar cargo-syms) 'ht-storm]
         [(memq 'archon cargo-syms)       'archon-drop]
         [(memq 'disruptor cargo-syms)    'disruptor-drop]
         [(memq 'immortal cargo-syms)     'immortal-juggle]
         [else                            'prism-warp-in])]
      [(medivac)
       (cond
         [(or (memq 'widow-mine cargo-syms) (memq 'widow-mine-burrowed cargo-syms)) 'widow-mine]
         [(memq 'hellbat cargo-syms)      'hellbat-drop]
         [(or (memq 'siege-tank cargo-syms) (memq 'siege-tank-sieged cargo-syms)) 'cliff-tank]
         [else                            'bio-drop])]
      [(overlord-transport)
       (cond
         [(memq 'baneling cargo-syms)     'baneling-drop]
         [(or (memq 'lurker cargo-syms) (memq 'lurker-mp cargo-syms) (memq 'ravager cargo-syms)) 'lurker-ravager-drop]
         [else                            'ling-drop])]
      [else 'cliff-ladder]))
  (or (lookup-drop-profile chosen-id) (first DROP-PROFILE-TABLE)))

(define current-active-drop-profile : (Parameterof (Option drop-profile))
  (make-parameter #f))

(: u-hp (-> Any Float Float))
(define (u-hp u default)
  (cond
    [(transport-unit-input? u) (max 0.0 (transport-unit-input-hp u))]
    [(dyn-hash-has-key? u 'hp) (max 0.0 (safe-finite-real (dyn-hash-ref u 'hp default) default))]
    [(dyn-hash-has-key? u 'health) (max 0.0 (safe-finite-real (dyn-hash-ref u 'health default) default))]
    [else default]))

(define *transport-combat-stats-cache* :
  (Mutable-HashTable Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol)))
  (make-hasheq))

(: cached-unit-combat-stats (-> Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol))))
(define (cached-unit-combat-stats sym)
  (or (hash-ref *transport-combat-stats-cache* sym (lambda () #f))
      (let ([st (sc2-unit-combat-stats sym)])
        (hash-set! *transport-combat-stats-cache* sym st)
        st)))

(: u-max-hp (-> Any Float Float))
(define (u-max-hp u default)
  (cond
    [(transport-unit-input? u) (max 1.0 (transport-unit-input-max-hp u))]
    [(dyn-hash-has-key? u 'max-hp) (max 1.0 (safe-finite-real (dyn-hash-ref u 'max-hp default) default))]
    [(dyn-hash-has-key? u 'health-max) (max 1.0 (safe-finite-real (dyn-hash-ref u 'health-max default) default))]
    [else
     (define stats (cached-unit-combat-stats (exact-unit-type u)))
     (max 1.0 (safe-finite-real (hash-ref stats 'max-hp (lambda () default)) default))]))

(: u-shield (-> Any Float Float))
(define (u-shield u default)
  (cond
    [(transport-unit-input? u) (max 0.0 (transport-unit-input-shield u))]
    [(dyn-hash-has-key? u 'shield) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shield default) default))]
    [(dyn-hash-has-key? u 'shields) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shields default) default))]
    [else default]))

(: u-max-shield (-> Any Float Float))
(define (u-max-shield u default)
  (cond
    [(transport-unit-input? u) (max 0.0 (transport-unit-input-max-shield u))]
    [(dyn-hash-has-key? u 'max-shield) (max 0.0 (safe-finite-real (dyn-hash-ref u 'max-shield default) default))]
    [(dyn-hash-has-key? u 'shield-max) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shield-max default) default))]
    [else
     (define stats (cached-unit-combat-stats (exact-unit-type u)))
     (max 0.0 (safe-finite-real (hash-ref stats 'max-shield (lambda () default)) default))]))

(: u-total-ehp (-> Any Float))
(define (u-total-ehp u)
  (cond
    [(transport-unit-input? u)
     (+ (max 0.0 (transport-unit-input-hp u))
        (max 0.0 (transport-unit-input-shield u)))]
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

(: u-hp-ratio (-> Any Float))
(define (u-hp-ratio u)
  (cond
    [(transport-unit-input? u)
     (define cur (+ (max 0.0 (transport-unit-input-hp u))
                    (max 0.0 (transport-unit-input-shield u))))
     (define tot (max 1.0 (+ (max 1.0 (transport-unit-input-max-hp u))
                             (max 0.0 (transport-unit-input-max-shield u)))))
     (clamp-prob (/ cur tot))]
    [else
     (define ut (exact-unit-type u))
     (define stats (cached-unit-combat-stats ut))
     (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
     (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
     (define cur (u-total-ehp u))
     (define tot
       (cond
         [(dyn-hash-has-key? u 'hull-hp)
          (if (or (dyn-hash-has-key? u 'max-hp)
                  (dyn-hash-has-key? u 'health-max))
              (max 1.0 (u-max-hp u (+ def-hp def-sh)))
              (max 1.0 (+ def-hp def-sh)))]
         [else
          (max 1.0 (+ (u-max-hp u def-hp) (u-max-shield u def-sh)))]))
     (clamp-prob (/ cur tot))]))

(: u-alive? (-> Any Boolean))
(define (u-alive? u)
  (if (transport-unit-input? u)
      (> (+ (transport-unit-input-hp u) (transport-unit-input-shield u)) 0.0)
      (case (dyn-u-alive-fast u)
        [(true) #t]
        [(false) #f]
        [else (> (u-total-ehp u) 0.0)])))

(: u-flying? (-> Any Boolean))
(define (u-flying? u)
  (cond
    [(transport-unit-input? u) (transport-unit-input-flying? u)]
    [(or (eq? (dyn-hash-ref u 'flying #f) #t)
         (eq? (dyn-hash-ref u 'flying? #f) #t)
         (eq? (dyn-hash-ref u 'is-flying #f) #t)
         (eq? (dyn-hash-ref u 'is_flying #f) #t))
     #t]
    [else (sc2-unit-is-flying-sym? (exact-unit-type u))]))

(: u-structure? (-> Any Boolean))
(define (u-structure? u)
  (define ut (exact-unit-type u))
  (not (not (or (eq? (dyn-hash-ref u 'is-building #f) #t)
                (eq? (dyn-hash-ref u 'building? #f) #t)
                (eq? (dyn-hash-ref u 'is-structure #f) #t)
                (memq ut SC2-ALL-STRUCTURE-SYMS)
                (memq ut '(auto-turret point-defense-drone))))))

(: u-completed? (-> Any Boolean))
(define (u-completed? u)
  (cond
    [(transport-unit-input? u) #t]
    [(dyn-hash-has-key? u 'build-progress)
     (>= (safe-finite-real (dyn-hash-ref u 'build-progress 1.0) 1.0) 1.0)]
    [(dyn-hash-has-key? u 'build_progress)
     (>= (safe-finite-real (dyn-hash-ref u 'build_progress 1.0) 1.0) 1.0)]
    [(dyn-hash-has-key? u 'progress)
     (>= (safe-finite-real (dyn-hash-ref u 'progress 1.0) 1.0) 1.0)]
    [else #t]))

(: u-weapon-range (-> Any Float))
(define (u-weapon-range u)
  (define ut (exact-unit-type u))
  (define stats (cached-unit-combat-stats ut))
  (max (safe-finite-real (hash-ref stats 'ground-range (lambda () 0.0)) 0.0)
       (safe-finite-real (hash-ref stats 'air-range (lambda () 0.0)) 0.0)))

(: extract-passenger-tags (-> Any (Listof Integer)))
(define (extract-passenger-tags tr-u)
  (cond
    [(transport-unit-input? tr-u) (transport-unit-input-passengers tr-u)]
    [(hash? tr-u)
     (define raw
       (or (dyn-hash-ref tr-u 'passengers #f)
           (dyn-hash-ref tr-u 'cargo #f)
           (dyn-hash-ref tr-u 'cargo-tags #f)
           (dyn-hash-ref tr-u 'cargo_tags #f)))
     (if (list? raw)
         (for/fold ([acc : (Listof Integer) '()] #:result (reverse acc))
                   ([item (in-list raw)])
           (define t
             (cond
               [(exact-integer? item) item]
               [(hash? item) (u-tag item)]
               [else 0]))
           (if (> t 0) (cons t acc) acc))
         '())]
    [else '()]))

(: u-cargo-space-taken (-> Any Integer))
(define (u-cargo-space-taken tr-u)
  (cond
    [(transport-unit-input? tr-u)
     (define explicit (transport-unit-input-cargo-space-taken tr-u))
     (if (> explicit 0)
         explicit
         (length (transport-unit-input-passengers tr-u)))]
    [(hash? tr-u)
     (define explicit
       (cond
         [(dyn-hash-has-key? tr-u 'cargo-space-taken)
          (safe-nonneg-int (dyn-hash-ref tr-u 'cargo-space-taken 0) 0)]
         [(dyn-hash-has-key? tr-u 'cargo_space_taken)
          (safe-nonneg-int (dyn-hash-ref tr-u 'cargo_space_taken 0) 0)]
         [(dyn-hash-has-key? tr-u 'cargo-used)
          (safe-nonneg-int (dyn-hash-ref tr-u 'cargo-used 0) 0)]
         [else 0]))
     (define plist (extract-passenger-tags tr-u))
     (if (> explicit 0) explicit (length plist))]
    [else 0]))

(: u-moving? (-> Any Boolean))
(define (u-moving? tr-u)
  (cond
    [(transport-unit-input? tr-u) (transport-unit-input-moving? tr-u)]
    [(or (eq? (dyn-hash-ref tr-u 'moving? #f) #t)
         (eq? (dyn-hash-ref tr-u 'moving #f) #t)
         (eq? (dyn-hash-ref tr-u 'is-moving? #f) #t))
     #t]
    [else
     (define vx (safe-finite-real (dyn-hash-ref tr-u 'vx 0.0) 0.0))
     (define vy (safe-finite-real (dyn-hash-ref tr-u 'vy 0.0) 0.0))
     (> (+ (* vx vx) (* vy vy)) 0.04)]))

(: u-ground-safe? (-> Any Boolean))
(define (u-ground-safe? tr-u)
  (cond
    [(transport-unit-input? tr-u) (transport-unit-input-ground-safe? tr-u)]
    [(dyn-hash-has-key? tr-u 'ground-safe?)
     (not (not (dyn-hash-ref tr-u 'ground-safe? #t)))]
    [(dyn-hash-has-key? tr-u 'pathable-below?)
     (not (not (dyn-hash-ref tr-u 'pathable-below? #t)))]
    [else #t]))

(: u-boost-ready? (-> Any Boolean))
(define (u-boost-ready? tr-u)
  (cond
    [(transport-unit-input? tr-u) (transport-unit-input-boost-ready? tr-u)]
    [(dyn-hash-has-key? tr-u 'boost-ready?)
     (not (not (dyn-hash-ref tr-u 'boost-ready? #t)))]
    [else #t]))

(: u-nova-ready? (-> Any Boolean))
(define (u-nova-ready? u)
  (cond
    [(transport-unit-input? u) (transport-unit-input-nova-ready? u)]
    [(dyn-hash-has-key? u 'nova-ready?)
     (not (not (dyn-hash-ref u 'nova-ready? #t)))]
    [(dyn-hash-has-key? u 'nova-ready)
     (not (not (dyn-hash-ref u 'nova-ready #t)))]
    [(dyn-hash-has-key? u 'nova-cooldown)
     (<= (safe-exact-int (dyn-hash-ref u 'nova-cooldown 0) 0) 0)]
    [(dyn-hash-has-key? u 'cooldown)
     (<= (safe-exact-int (dyn-hash-ref u 'cooldown 0) 0) 0)]
    [else #t]))

(: clamp-playable-pt (-> Real Real point2d))
(define (clamp-playable-pt x y)
  (clamp-point-to-map (point2d (->float x) (->float y))
                      SC2-MAP-PLAYABLE-MIN-COORD
                      SC2-MAP-PLAYABLE-MAX-COORD))

;; True if `sym` is a valid transport unit (`'medivac`, `'warp-prism`, `'warp-prism-phasing`, `'overlord-transport`).
(: transport-unit-sym? (-> Symbol Boolean))
(define (transport-unit-sym? sym)
  (not (not (memq sym '(medivac warp-prism warp-prism-phasing overlord-transport)))))

;; Returns unit-specific `UnloadAllAt` wire ability ID (`396` Medivac, `913` Prism, `1408` Overlord).
(: transport-unload-ability-id (-> Symbol Integer))
(define (transport-unload-ability-id tr-sym)
  (case tr-sym
    [(medivac)                     MEDIVAC-UNLOAD-ALL-AT-ABILITY-ID]
    [(warp-prism warp-prism-phasing) WARP-PRISM-UNLOAD-ALL-AT-ABILITY-ID]
    [(overlord-transport)          OVERLORD-UNLOAD-ALL-AT-ABILITY-ID]
    [else                          UNLOAD-ALL-AT-ABILITY-ID]))

;; Pickup range: WarpPrism `5.0` tiles vs Medivac / OverlordTransport `1.5` tiles.
(: transport-pickup-range (-> Symbol Float))
(define (transport-pickup-range tr-sym)
  (if (memq tr-sym '(warp-prism warp-prism-phasing))
      WARP-PRISM-PICKUP-RANGE
      STANDARD-TRANSPORT-PICKUP-RANGE))

;; Canonical SC2 LotV cargo slot size per unit type.
(: unit-cargo-size (-> Symbol Integer))
(define (unit-cargo-size sym)
  (case sym
    [(marine reaper scv probe drone zergling) 1]
    [(baneling baneling-cocoon) 2]
    [(marauder ghost hellion hellbat widow-mine widow-mine-burrowed
      zealot stalker sentry adept high-templar dark-templar
      roach ravager hydralisk queen infestor) 2]
    [(siege-tank cyclone immortal archon disruptor lurker lurker-mp) 4]
    [(thor thor-ap colossus ultralisk) 8]
    [else 2]))

(: transport-race-accepts-unit? (-> Symbol Symbol Boolean))
(define (transport-race-accepts-unit? tr-sym u-sym)
  (case tr-sym
    [(medivac)
     (not (not (memq u-sym '(scv marine marauder reaper ghost hellion hellbat
                             widow-mine siege-tank cyclone thor thor-ap))))]
    [(warp-prism warp-prism-phasing)
     (not (not (memq u-sym '(probe zealot stalker sentry adept high-templar
                             dark-templar archon immortal colossus disruptor))))]
    [(overlord-transport)
     (not (not (memq u-sym '(drone zergling baneling roach ravager hydralisk
                             lurker lurker-mp infestor queen ultralisk))))]
    [else #f]))

;; Synchronizes transport passenger pickup timestamps & WarpPrism phase state across frames.
(: sync-transport-tracker! (->* (transport-tracker (Listof Any) Integer)
                                (#:dead-tags (Listof Integer))
                                Void))
(define (sync-transport-tracker! tr ally-units current-frame #:dead-tags [dead-tags '()])
  (define active-passengers : (Mutable-HashTable Integer Boolean) (make-hasheqv))
  (define p-tbl (transport-tracker-passenger-pickup-table tr))
  (define c-tbl (transport-tracker-transport-cargo-since tr))
  (define phase-tbl (transport-tracker-prism-phases tr))
  (define boost-tbl (transport-tracker-medivac-last-boost tr))
  (define last-load-tbl (transport-tracker-transport-last-load tr))
  (define last-unload-tbl (transport-tracker-transport-last-unload tr))
  (define seen-empty-tbl (transport-tracker-transport-seen-empty tr))

  (for ([a (in-list ally-units)])
    (define ut (exact-unit-type a))
    (when (and (transport-unit-sym? ut) (u-alive? a))
      (define tag (u-tag a))
      (when (> tag 0)
        (define ptags (extract-passenger-tags a))
        (define cargo-used (u-cargo-space-taken a))
        (for ([ptag (in-list ptags)])
          (hash-set! active-passengers ptag #t)
          (unless (hash-has-key? p-tbl ptag)
            (hash-set! p-tbl ptag current-frame)))
        (cond
          [(or (pair? ptags) (> cargo-used 0))
           (when (or (hash-has-key? seen-empty-tbl tag)
                     (and (hash-has-key? last-unload-tbl tag)
                          (not (hash-has-key? c-tbl tag))))
             (hash-set! last-load-tbl tag current-frame))
           (hash-remove! seen-empty-tbl tag)
           (unless (hash-has-key? c-tbl tag)
             (define earliest-p
               (for/fold ([best : Integer current-frame]) ([pt (in-list ptags)])
                 (min best (hash-ref p-tbl pt (lambda () current-frame)))))
             (hash-set! c-tbl tag earliest-p))]
          [else
           (define prev-cargo-since (hash-ref c-tbl tag (lambda () #f)))
           (when prev-cargo-since
             (define prev-u (hash-ref last-unload-tbl tag (lambda () #f)))
             (when (or (not prev-u) (< prev-u prev-cargo-since))
               (hash-set! last-unload-tbl tag current-frame)))
           (hash-remove! c-tbl tag)
           (hash-set! seen-empty-tbl tag #t)])
        (when (memq ut '(warp-prism warp-prism-phasing))
          (define phasing-now? (eq? ut 'warp-prism-phasing))
          (define prev (hash-ref phase-tbl tag (lambda () #f)))
          (cond
            [(not prev)
             (hash-set! phase-tbl tag
                        (if phasing-now?
                            (prism-phase-rec current-frame -10000 #t)
                            (prism-phase-rec -10000 -10000 #f)))]
            [(and phasing-now? (not (prism-phase-rec-phasing? prev)))
             (hash-set! phase-tbl tag
                        (prism-phase-rec current-frame (prism-phase-rec-last-unphase-frame prev) #t))]
            [(and (not phasing-now?) (prism-phase-rec-phasing? prev))
             (hash-set! phase-tbl tag
                        (prism-phase-rec (prism-phase-rec-phase-start-frame prev) current-frame #f))])))))

  ;; Remove unloaded/dead passengers from pickup table & dead transports from tracker tables
  (unless (hash-empty? p-tbl)
    (define stale-p
      (for/list : (Listof Integer) ([pt (in-hash-keys p-tbl)]
                                    #:when (or (not (hash-has-key? active-passengers pt))
                                               (memv pt dead-tags)))
        pt))
    (for ([pt (in-list stale-p)])
      (hash-remove! p-tbl pt)))
  (for ([dt (in-list dead-tags)])
    (hash-remove! c-tbl dt)
    (hash-remove! phase-tbl dt)
    (hash-remove! boost-tbl dt)
    (hash-remove! last-load-tbl dt)
    (hash-remove! last-unload-tbl dt)
    (hash-remove! seen-empty-tbl dt)))

;; =============================================================================
;; Active Danger Zones & Threat Inspection
;; =============================================================================

;; Extracts active Nova/Bile/Storm/Cloud danger zones from enemy units and effects list.
(: collect-active-danger-zones (-> (Listof Any) (Listof Any) Integer (Listof danger-zone)))
(define (collect-active-danger-zones enemy-units effects current-frame)
  (define from-novas
    (for/fold ([acc : (Listof danger-zone) '()]) ([e (in-list enemy-units)])
      (if (and (eq? (exact-unit-type e) 'disruptor-phased) (u-alive? e))
          (cons (danger-zone 'purification-nova (u-x e) (u-y e) 2.25 (+ current-frame 47)) acc)
          acc)))
  (for/fold ([acc : (Listof danger-zone) from-novas]) ([ef (in-list effects)])
    (cond
      [(danger-zone? ef)
       (if (or (<= (danger-zone-expires-frame ef) 0)
               (>= (danger-zone-expires-frame ef) current-frame))
           (cons ef acc)
           acc)]
      [(hash? ef)
       (define raw-kind (or (dyn-hash-ref ef 'kind #f)
                            (dyn-hash-ref ef 'type #f)
                            (dyn-hash-ref ef 'effect-sym #f)
                            'unknown))
       (define kind
         (if (symbol? raw-kind) raw-kind 'unknown))
       (define eff-id
         (safe-exact-int (cond
                           [(dyn-hash-has-key? ef 'effect-id) (dyn-hash-ref ef 'effect-id 0)]
                           [(dyn-hash-has-key? ef 'effect_id) (dyn-hash-ref ef 'effect_id 0)]
                           [(dyn-hash-has-key? ef 'id)        (dyn-hash-ref ef 'id 0)]
                           [else 0])
                         0))
       (define norm-kind
         (cond
           [(not (eq? kind 'unknown)) kind]
           [(= eff-id 1)  'psi-storm]
           [(= eff-id 10) 'blinding-cloud]
           [(= eff-id 11) 'corrosive-bile]
           [(= eff-id 7)  'nuke-persistent]
           [else 'unknown]))
       (if (memq norm-kind '(purification-nova nova corrosive-bile bile
                             psi-storm storm blinding-cloud nuke-persistent))
           (let ([r (if (dyn-hash-has-key? ef 'radius)
                        (max 1.25 (safe-finite-real (dyn-hash-ref ef 'radius 2.0) 2.0))
                        (case norm-kind
                          [(purification-nova nova) 2.25]
                          [(corrosive-bile bile)    1.5]
                          [(nuke-persistent)        8.0]
                          [else                     2.25]))]
                 [exp (safe-exact-int (dyn-hash-ref ef 'expires-frame 0) 0)])
             (if (or (<= exp 0) (>= exp current-frame))
                 (cons (danger-zone norm-kind
                                    (u-x ef)
                                    (u-y ef)
                                    r
                                    (if (> exp 0) exp (+ current-frame 30)))
                       acc)
                 acc))
           acc)]
      [else acc])))

;; True when point `(x, y)` lies inside (or within `margin` of) any active danger zone.
(: point-in-danger-zones? (->* (Real Real (Listof danger-zone)) (Real) Boolean))
(define (point-in-danger-zones? x y zones [margin 0.35])
  (define fx (->float x))
  (define fy (->float y))
  (define fm (->float margin))
  (for/or : Boolean ([dz (in-list zones)])
    (<= (dist-2d fx fy (danger-zone-x dz) (danger-zone-y dz))
        (+ (danger-zone-radius dz) fm))))

(struct tr-enemy-rec
  ([x : Float]
   [y : Float]
   [combat? : Boolean]
   [gdps>0? : Boolean]
   [geff-r : Float]
   [geff-r2 : Float]
   [adps>0? : Boolean]
   [aeff-r : Float]
   [aeff-r2 : Float]))

(struct tr-save-cand
  ([u : Any]
   [tag : Integer]
   [ut : Symbol]
   [sz : Integer]
   [x : Float]
   [y : Float]
   [in-aoe? : Boolean]
   [score : Float]))

(define current-fleet-enemy-recs : (Parameterof (Option (Listof tr-enemy-rec)))
  (make-parameter #f))
(define current-fleet-save-cands : (Parameterof (Option (Listof tr-save-cand)))
  (make-parameter #f))

(: build-fleet-enemy-recs (-> (Listof Any) (Listof tr-enemy-rec)))
(define (build-fleet-enemy-recs enemy-units)
  (for/list : (Listof tr-enemy-rec)
            ([e (in-list enemy-units)]
             #:when (u-alive? e))
    (define et (exact-unit-type e))
    (define stats (cached-unit-combat-stats et))
    (define gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0))
    (define adps (safe-finite-real (hash-ref stats 'air-dps (lambda () 0.0)) 0.0))
    (define grng (if (> gdps 0.0)
                     (+ (max 1.5 (safe-finite-real (hash-ref stats 'ground-range (lambda () 0.0)) 0.0)) 0.75)
                     0.0))
    (define arng (if (> adps 0.0)
                     (+ (max 1.5 (safe-finite-real (hash-ref stats 'air-range (lambda () 0.0)) 0.0)) 0.75)
                     0.0))
    (tr-enemy-rec (u-x e)
                  (u-y e)
                  (not (memq et '(larva egg observer overlord changeling)))
                  (> gdps 0.0) grng (* grng grng)
                  (> adps 0.0) arng (* arng arng))))

;; Counts living enemy attackers currently within effective weapon reach of unit `u`.
(: count-attackers-in-range (-> Any (Listof Any) Integer))
(define (count-attackers-in-range u enemy-units)
  (define ux (u-x u))
  (define uy (u-y u))
  (define u-air? (u-flying? u))
  (define pre-e (current-fleet-enemy-recs))
  (cond
    [pre-e
     (for/sum : Integer ([r (in-list pre-e)])
       (define ok? (if u-air? (tr-enemy-rec-adps>0? r) (tr-enemy-rec-gdps>0? r)))
       (if (not ok?)
           0
           (let ([eff-rng (if u-air? (tr-enemy-rec-aeff-r r) (tr-enemy-rec-geff-r r))]
                 [eff-r2 (if u-air? (tr-enemy-rec-aeff-r2 r) (tr-enemy-rec-geff-r2 r))]
                 [dx (- ux (tr-enemy-rec-x r))]
                 [dy (- uy (tr-enemy-rec-y r))])
             (if (and (<= (abs dx) eff-rng)
                      (<= (abs dy) eff-rng)
                      (<= (+ (* dx dx) (* dy dy)) eff-r2))
                 1
                 0))))]
    [else
     (define dps-key (if u-air? 'air-dps 'ground-dps))
     (define rng-key (if u-air? 'air-range 'ground-range))
     (for/sum : Integer ([e (in-list enemy-units)]
                         #:when (u-alive? e))
       (define et (exact-unit-type e))
       (define stats (cached-unit-combat-stats et))
       (define dps (safe-finite-real (hash-ref stats dps-key (lambda () 0.0)) 0.0))
       (if (<= dps 0.0)
           0
           (let* ([rng (safe-finite-real (hash-ref stats rng-key (lambda () 0.0)) 0.0)]
                  [eff-rng (+ (max 1.5 rng) 0.75)]
                  [dx (- ux (u-x e))]
                  [dy (- uy (u-y e))])
             (if (and (<= (abs dx) eff-rng)
                      (<= (abs dy) eff-rng)
                      (<= (+ (* dx dx) (* dy dy)) (* eff-rng eff-rng)))
                 1
                 0))))]))

(: nearest-enemy-combat-dist (-> Real Real (Listof Any) Float))
(define (nearest-enemy-combat-dist x y enemy-units)
  (define fx (->float x))
  (define fy (->float y))
  (define pre-e (current-fleet-enemy-recs))
  (define best-d2 : Float
    (cond
      [pre-e
       (for/fold ([best : Float +inf.0])
                 ([r (in-list pre-e)]
                  #:when (tr-enemy-rec-combat? r))
         (define dx (- fx (tr-enemy-rec-x r)))
         (define dy (- fy (tr-enemy-rec-y r)))
         (min best (+ (* dx dx) (* dy dy))))]
      [else
       (for/fold ([best : Float +inf.0])
                 ([e (in-list enemy-units)]
                  #:when (u-alive? e))
         (define et (exact-unit-type e))
         (if (memq et '(larva egg observer overlord changeling))
             best
             (let ([dx (- fx (u-x e))]
                   [dy (- fy (u-y e))])
               (min best (+ (* dx dx) (* dy dy))))))]))
  (if (infinite? best-d2) +inf.0 (->float (sqrt (max 0.0 best-d2)))))

;; =============================================================================
;; 1. Combat Save-Pickup Priority & Execution
;; =============================================================================

;; W9-TAC-5-rt: Detect units actively channeling Steady Targeting (2714) or other
;; protected spell channels so Medivacs do not cancel a 170-damage Snipe at standoff!
(: u-channeling-protected-order? (-> Any Boolean))
(define (u-channeling-protected-order? u)
  (cond
    [(not (hash? u)) #f]
    [else
     (define top-ab (safe-exact-int (dyn-hash-ref u 'order-ability-id 0) 0))
     (define top-ab2 (safe-exact-int (dyn-hash-ref u 'ability-id 0) 0))
     (define top-sym (dyn-hash-ref u 'order #f))
     (define orders-raw (dyn-hash-ref u 'orders '()))
     (define ord-list : (Listof Any)
       (cond
         [(list? orders-raw) orders-raw]
         [(vector? orders-raw) (vector->list orders-raw)]
         [else '()]))
     (define (chan-ab? [ab : Integer]) : Boolean
       (or (= ab 2714) ;; Ghost Steady Targeting (Snipe channel)
           (= ab 249)  ;; Infestor Neural Parasite channel
           (= ab 401)  ;; Battlecruiser Yamato Gun channel
           (= ab 1622))) ;; Ghost Nuke Calldown channel
     (or (chan-ab? top-ab)
         (chan-ab? top-ab2)
         (and (symbol? top-sym)
              (not (not (memq top-sym '(steady-targeting snipe neural-parasite yamato-gun nuke-calldown)))))
         (for/or : Boolean ([ord (in-list ord-list)])
           (cond
             [(exact-integer? ord) (chan-ab? ord)]
             [(hash? ord)
              (define id1 (safe-exact-int (dyn-hash-ref ord 'ability-id 0) 0))
              (define id2 (safe-exact-int (dyn-hash-ref ord 'ability_id 0) 0))
              (or (chan-ab? id1) (chan-ab? id2))]
             [else #f])))]))

(: ally-base-save-priority (-> Any Symbol Integer (Listof Any) (Listof danger-zone) (Values Float Boolean)))
(define (ally-base-save-priority ally-u ut sz enemy-units zones)
  (define has-zones? (pair? zones))
  (define high-val? (not (not (memq ut SAVE-HIGH-VALUE-SYMS))))
  (define is-disr? (eq? ut 'disruptor))
  (cond
    [(or (and (not has-zones?) (not is-disr?) (not high-val?))
         (> sz TRANSPORT-MAX-CARGO-CAPACITY)
         (memq ut '(siege-tank-sieged lurker-burrowed larva egg))
         (not (u-alive? ally-u)))
     (values 0.0 #f)]
    [else
     (define ux (u-x ally-u))
     (define uy (u-y ally-u))
     (define in-aoe? (and has-zones? (point-in-danger-zones? ux uy zones 0.35)))
     (define channel-standoff-protected?
       (and (not in-aoe?)
            (u-channeling-protected-order? ally-u)
            (> (nearest-enemy-combat-dist ux uy enemy-units) 3.5)))
     (define disruptor-cd-danger?
       (and is-disr?
            (not (u-nova-ready? ally-u))
            (<= (nearest-enemy-combat-dist ux uy enemy-units) 9.0)))
     (cond
       [(or channel-standoff-protected?
            (not (or in-aoe? disruptor-cd-danger? high-val?)))
        (values 0.0 #f)]
       [else
        (define hp-rat (if (or in-aoe? disruptor-cd-danger?) 1.0 (u-hp-ratio ally-u)))
        (define critical-bio? (not (not (memq ut SAVE-CRITICAL-BIO-SYMS))))
        (define save-hp-thresh
          (if critical-bio? SAVE-CRITICAL-BIO-HP-RATIO SAVE-UNDER-FIRE-HP-RATIO))
        (define bruised-hp-thresh
          (if critical-bio? SAVE-CRITICAL-BIO-HP-RATIO SAVE-BRUISED-HP-RATIO))
        (define need-rescue?
          (or in-aoe?
              disruptor-cd-danger?
              (and high-val? (< hp-rat save-hp-thresh))))
        (cond
          [(or (not need-rescue?)
               (u-flying? ally-u)
               (u-structure? ally-u))
           (values 0.0 #f)]
          [else
           (define bruised?
             (and high-val?
                  (let ([r (if (or in-aoe? disruptor-cd-danger?) (u-hp-ratio ally-u) hp-rat)])
                    (or (< r bruised-hp-thresh)
                        (and (< r save-hp-thresh)
                             (>= (count-attackers-in-range ally-u enemy-units) 2))))))
           (if (or in-aoe? disruptor-cd-danger? bruised?)
               (let* ([r (if (or in-aoe? disruptor-cd-danger?) (u-hp-ratio ally-u) hp-rat)]
                      [value-bonus (exact->inexact (max 50 (+ (sc2-min-cost ut) (sc2-gas-cost ut))))])
                 (values (+ (if in-aoe? 1500.0 0.0)
                            (if disruptor-cd-danger? 1100.0 0.0)
                            (if bruised? (* 900.0 (- 1.0 r)) 0.0)
                            (* 0.5 value-bonus))
                         in-aoe?))
               (values 0.0 #f))])])]))

(: build-fleet-save-cands (-> (Listof Any) (Listof Any) (Listof danger-zone) (Listof tr-save-cand)))
(define (build-fleet-save-cands ally-units enemy-units zones)
  (define has-zones? (pair? zones))
  (for/fold ([acc : (Listof tr-save-cand) '()] #:result (reverse acc))
            ([a (in-list ally-units)])
    (define ut (exact-unit-type a))
    (cond
      [(and (not has-zones?)
            (not (eq? ut 'disruptor))
            (not (memq ut SAVE-HIGH-VALUE-SYMS)))
       acc]
      [else
       (define sz (unit-cargo-size ut))
       (define-values (sc in-aoe?) (ally-base-save-priority a ut sz enemy-units zones))
       (if (> sc 0.0)
           (let ([atag (u-tag a)])
             (if (> atag 0)
                 (cons (tr-save-cand a atag ut sz (u-x a) (u-y a) in-aoe? sc) acc)
                 acc))
           acc)])))

;; Scores a friendly unit's save-pickup urgency (<= 0.0 if rescue is not warranted).
(: save-pickup-candidate-priority
   (-> Symbol Any (Listof Any) (Listof danger-zone) Integer Float))
(define (save-pickup-candidate-priority tr-sym ally-u enemy-units zones cargo-free)
  (define ut (exact-unit-type ally-u))
  (define sz (unit-cargo-size ut))
  (cond
    [(or (> sz cargo-free)
         (not (transport-race-accepts-unit? tr-sym ut)))
     0.0]
    [else
     (define-values (sc _in-aoe?) (ally-base-save-priority ally-u ut sz enemy-units zones))
     sc]))

(: find-save-pickup-target
   (-> Any Symbol (Listof Any) (Listof Any) (Listof danger-zone) (Values (Option Any) Symbol)))
(define (find-save-pickup-target tr-u tr-sym ally-units enemy-units zones)
  (define cargo-used (u-cargo-space-taken tr-u))
  (define cargo-free (max 0 (- TRANSPORT-MAX-CARGO-CAPACITY cargo-used)))
  (define pre-cands (current-fleet-save-cands))
  (cond
    [(<= cargo-free 0) (values #f 'none)]
    [pre-cands
     (if (null? pre-cands)
         (values #f 'none)
         (let ([tx (u-x tr-u)]
               [ty (u-y tr-u)]
               [tr-tag (u-tag tr-u)]
               [carried-tags : (Listof Integer) (extract-passenger-tags tr-u)]
               [r2 (* TRANSPORT-SAVE-SEARCH-RADIUS TRANSPORT-SAVE-SEARCH-RADIUS)])
           (for/fold ([best : (Option Any) #f]
                      [best-sc : Float 0.0]
                      [best-ut : Symbol 'unknown]
                      [best-aoe? : Boolean #f]
                      #:result
                      (if best
                          (values best
                                  (cond
                                    [best-aoe? 'save-pickup-aoe-danger-zone]
                                    [(eq? best-ut 'disruptor) 'save-pickup-disruptor-nova-cooldown]
                                    [else 'save-pickup-bruised-high-value]))
                          (values #f 'none)))
                     ([c (in-list pre-cands)])
             (define atag (tr-save-cand-tag c))
             (define sc (tr-save-cand-score c))
             (if (and (> sc best-sc)
                      (not (= atag tr-tag))
                      (not (memv atag carried-tags))
                      (<= (tr-save-cand-sz c) cargo-free)
                      (transport-race-accepts-unit? tr-sym (tr-save-cand-ut c)))
                 (let ([dx (- tx (tr-save-cand-x c))]
                       [dy (- ty (tr-save-cand-y c))])
                   (if (and (<= (abs dx) TRANSPORT-SAVE-SEARCH-RADIUS)
                            (<= (abs dy) TRANSPORT-SAVE-SEARCH-RADIUS)
                            (<= (+ (* dx dx) (* dy dy)) r2))
                       (values (tr-save-cand-u c) sc (tr-save-cand-ut c) (tr-save-cand-in-aoe? c))
                       (values best best-sc best-ut best-aoe?)))
                 (values best best-sc best-ut best-aoe?)))))]
    [else
     (define tx (u-x tr-u))
     (define ty (u-y tr-u))
     (define tr-tag (u-tag tr-u))
     (define carried-tags : (Listof Integer) (extract-passenger-tags tr-u))
     (for/fold ([best : (Option Any) #f]
                [best-sc : Float 0.0]
                #:result
                (if best
                    (let ([reason
                           (cond
                             [(point-in-danger-zones? (u-x best) (u-y best) zones 0.35)
                              'save-pickup-aoe-danger-zone]
                             [(eq? (exact-unit-type best) 'disruptor)
                              'save-pickup-disruptor-nova-cooldown]
                             [else
                              'save-pickup-bruised-high-value])])
                      (values best reason))
                    (values #f 'none)))
               ([a (in-list ally-units)])
       (define atag (u-tag a))
       (if (or (<= atag 0)
               (= atag tr-tag)
               (memv atag carried-tags))
           (values best best-sc)
           (let ([ax (u-x a)]
                 [ay (u-y a)])
             (if (or (> (abs (- tx ax)) TRANSPORT-SAVE-SEARCH-RADIUS)
                     (> (abs (- ty ay)) TRANSPORT-SAVE-SEARCH-RADIUS)
                     (> (dist-2d tx ty ax ay) TRANSPORT-SAVE-SEARCH-RADIUS))
                 (values best best-sc)
                 (let ([sc (save-pickup-candidate-priority tr-sym a enemy-units zones cargo-free)])
                   (if (> sc best-sc)
                       (values a sc)
                       (values best best-sc)))))))]))

(: evaluate-save-pickup/zones
   (-> Any (Listof Any) (Listof Any) (Option transport-tracker) Integer (Listof danger-zone)
       (Option transport-directive)))
(define (evaluate-save-pickup/zones tr-u ally-units enemy-units tr current-frame zones)
  (define tr-sym (exact-unit-type tr-u))
  (define tr-tag (u-tag tr-u))
  (cond
    [(or (not (u-alive? tr-u)) (not (transport-unit-sym? tr-sym))) #f]
    [else
     (define-values (victim reason) (find-save-pickup-target tr-u tr-sym ally-units enemy-units zones))
     (cond
       [(not victim) #f]
       [(eq? tr-sym 'warp-prism-phasing)
        (cond
          [(not (prism-can-unphase? tr tr-tag current-frame)) #f]
          [else
           ;; Unphase only after >= 44f phase dwell so WarpPrism does not oscillate on save-pickup
           (when tr
             (define p-tbl (transport-tracker-prism-phases tr))
             (define prev (hash-ref p-tbl tr-tag (lambda () #f)))
             (hash-set! p-tbl tr-tag
                        (prism-phase-rec (if prev (prism-phase-rec-phase-start-frame prev) current-frame)
                                         current-frame
                                         #f)))
           (transport-directive tr-tag tr-sym 'morph-warp-prism-transport
                                'morph-warp-prism-transport MORPH-WARP-PRISM-TRANSPORT-ABILITY-ID
                                tr-tag '() (u-x tr-u) (u-y tr-u)
                                'warp-prism-unphase-emergency-save)])]
       [else
        (define vtag (u-tag victim))
        (define vx (u-x victim))
        (define vy (u-y victim))
        (define d (dist-2d (u-x tr-u) (u-y tr-u) vx vy))
        (define p-range (transport-pickup-range tr-sym))
        (cond
          [(or (< (u-hp-ratio tr-u) EMERGENCY-DUMP-HP-RATIO)
               (and tr (> (transport-tracker-load-cooldown tr tr-tag current-frame) 0)))
           #f]
          [(<= d p-range)
           (when tr
             (transport-tracker-record-pickup! tr tr-tag vtag current-frame)
             (transport-tracker-record-load! tr tr-tag current-frame))
           (transport-directive tr-tag tr-sym 'load-unit 'load-transport
                                LOAD-TRANSPORT-ABILITY-ID vtag (list vtag) vx vy reason)]
          [else
           (transport-directive tr-tag tr-sym 'approach-save-pickup 'move
                                16 vtag (list vtag) vx vy reason)])])]))

;; Evaluates combat save-pickup for a transport (`5.0` WarpPrism vs `1.5` Medivac/Dropperlord).
(: evaluate-save-pickup
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option transport-tracker)
         #:current-frame Integer
         #:danger-zones (Listof danger-zone)
         #:effects (Listof Any))
        (Option transport-directive)))
(define (evaluate-save-pickup tr-u ally-units enemy-units
                              #:tracker [tr #f]
                              #:current-frame [current-frame 0]
                              #:danger-zones [explicit-zones '()]
                              #:effects [effects '()])
  (define tr-sym (exact-unit-type tr-u))
  (cond
    [(or (not (u-alive? tr-u)) (not (transport-unit-sym? tr-sym))) #f]
    [else
     (define zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame)))
     (evaluate-save-pickup/zones tr-u ally-units enemy-units tr current-frame zones)]))

;; =============================================================================
;; 2. Safe Rear-Offset Drop, Pro Moving Self-Drop (`#115`) & 672f Ceiling
;; =============================================================================

(define current-fleet-front-xy : (Parameterof (Option (Pairof Float Float)))
  (make-parameter #f))
(define current-fleet-safe-drop : (Parameterof (Option point2d))
  (make-parameter #f))

(: compute-ally-ground-anchor (-> (Listof Any) (Option (Pairof Float Float))))
(define (compute-ally-ground-anchor ally-units)
  (define-values (acount ax-sum ay-sum)
    (for/fold ([n : Integer 0] [sx : Float 0.0] [sy : Float 0.0])
              ([a (in-list ally-units)]
               #:when (and (u-alive? a)
                           (not (u-flying? a))
                           (not (u-structure? a))
                           (not (transport-unit-sym? (exact-unit-type a)))))
      (values (add1 n) (+ sx (u-x a)) (+ sy (u-y a)))))
  (if (> acount 0)
      (cons (/ ax-sum (->float acount)) (/ ay-sum (->float acount)))
      #f))

(: compute-ally-front-anchor (-> (Listof Any) (Listof Any) Real Real (Values Float Float)))
(define (compute-ally-front-anchor ally-units enemy-units fallback-x fallback-y)
  (define anchor (compute-ally-ground-anchor ally-units))
  (if anchor
      (values (car anchor) (cdr anchor))
      (values (->float fallback-x) (->float fallback-y))))

;; Computes a safe drop point `3.5..5.0` tiles behind `front` toward `(home-x, home-y)`
;; strictly outside all active Nova/Bile/Storm/Cloud danger zones.
(: compute-safe-rear-drop-point
   (->* (Real Real Real Real)
        ((Listof danger-zone) (Listof Any))
        point2d))
(define (compute-safe-rear-drop-point front-x front-y home-x home-y
                                      [danger-zones '()]
                                      [enemy-units '()])
  (define fx (->float front-x))
  (define fy (->float front-y))
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define dx (- hx fx))
  (define dy (- hy fy))
  (define d (dist-2d fx fy hx hy))
  (define base-ang
    (if (> d 1e-4)
        (atan dy dx)
        (/ (* -3.0 pi) 4.0)))
  (define mid-off (* 0.5 (+ SAFE-DROP-REAR-OFFSET-MIN SAFE-DROP-REAR-OFFSET-MAX)))
  (define candidate-points : (Listof point2d)
    (for*/list : (Listof point2d)
               ([off (in-list (list mid-off SAFE-DROP-REAR-OFFSET-MIN SAFE-DROP-REAR-OFFSET-MAX))]
                [ang-off (in-list '(0.0 0.45 -0.45 0.9 -0.9 1.35 -1.35))])
      (define ang (+ base-ang ang-off))
      (clamp-playable-pt (+ fx (* off (->float (cos ang))))
                         (+ fy (* off (->float (sin ang)))))))
  (define best-safe : (Option point2d)
    (let loop ([pts : (Listof point2d) candidate-points])
      (cond
        [(null? pts) #f]
        [(let ([pt (car pts)])
           (and (not (point-in-danger-zones? (point2d-x pt) (point2d-y pt) danger-zones 0.75))
                (> (nearest-enemy-combat-dist (point2d-x pt) (point2d-y pt) enemy-units) 3.5)))
         (car pts)]
        [else (loop (cdr pts))])))
  (define fallback-safe : (Option point2d)
    (let loop ([pts : (Listof point2d) candidate-points])
      (cond
        [(null? pts) #f]
        [(let ([pt (car pts)])
           (not (point-in-danger-zones? (point2d-x pt) (point2d-y pt) danger-zones 0.5)))
         (car pts)]
        [else (loop (cdr pts))])))
  (or best-safe fallback-safe (first candidate-points)))

(: evaluate-transport-drop/zones
   (-> Any (Listof Any) (Listof Any) (Option transport-tracker) Integer Real Real
       (Option Real) (Option Real) (Listof danger-zone) Boolean
       (Option transport-directive)))
(define (evaluate-transport-drop/zones tr-u ally-units enemy-units
                                       tr current-frame home-x home-y
                                       front-x-arg front-y-arg zones prefer-moving-drop?)
  (define tr-sym (exact-unit-type tr-u))
  (define tr-tag (u-tag tr-u))
  (define ptags (extract-passenger-tags tr-u))
  (define cargo-used (u-cargo-space-taken tr-u))
  (cond
    [(or (not (u-alive? tr-u))
         (<= tr-tag 0)
         (not (transport-unit-sym? tr-sym))
         (and (null? ptags) (<= cargo-used 0)))
     #f]
    [else
     (define tx (u-x tr-u))
     (define ty (u-y tr-u))
     (define hp-rat (u-hp-ratio tr-u))
     (define ground-ok? (u-ground-safe? tr-u))
     (define pos-safe? (and ground-ok? (not (point-in-danger-zones? tx ty zones 0.35))))
     (define carry-dwell
       (if tr
           (transport-tracker-carry-dwell-frames tr tr-tag ptags current-frame)
           MIN-CARRY-DWELL-FRAMES))
     (define pre-front (if (and (not front-x-arg) (not front-y-arg))
                           (current-fleet-front-xy)
                           #f))
     (define-values (fx0 fy0)
       (if pre-front
           (values (car pre-front) (cdr pre-front))
           (compute-ally-front-anchor ally-units enemy-units tx ty)))
     (define front-x (if front-x-arg (->float front-x-arg) fx0))
     (define front-y (if front-y-arg (->float front-y-arg) fy0))
     (define pre-safe (if (and (not front-x-arg) (not front-y-arg))
                          (current-fleet-safe-drop)
                          #f))
     (define safe-pt
       (or pre-safe
           (compute-safe-rear-drop-point front-x front-y home-x home-y zones enemy-units)))
     ;; L59-P2 (`n18`/`ro28`/`ro26` offensive mineral-line drop fix):
     ;; When a loaded transport arrives near an enemy mineral line (`>= 4` enemy workers within `22t`)
     ;; with `0` friendly ground combat units already on the ground (`<= 10t`), fly PAST defenders
     ;; straight to the enemy worker cluster `(wcx, wcy)` instead of dumping `4.25t` toward home!
     (define nearby-enemy-workers : (Listof Any)
       (if (and (not front-x-arg) (not front-y-arg))
           (for/list : (Listof Any)
                     ([e (in-list enemy-units)]
                      #:when (and (u-alive? e)
                                  (memq (exact-unit-type e) '(scv probe drone mule))
                                  (<= (dist-2d tx ty (u-x e) (u-y e)) 22.0)))
             e)
           '()))
     (define ally-ground-near? : Boolean
       (and (pair? nearby-enemy-workers)
            (for/or : Boolean ([a (in-list ally-units)])
              (and (u-alive? a)
                   (not (u-flying? a))
                   (not (u-structure? a))
                   (not (memq (exact-unit-type a) '(scv probe drone mule)))
                   (<= (dist-2d tx ty (u-x a) (u-y a)) 10.0)))))
     (define offensive-mineral-drop?
       (and (>= (length nearby-enemy-workers) 4)
            (not ally-ground-near?)))
     (define ptypes-now (extract-passenger-types tr-u))
     (define has-bane-cargo? (not (not (memq 'baneling ptypes-now))))
     (define-values (sx sy)
       (if offensive-mineral-drop?
           (let ([nw (exact->inexact (length nearby-enemy-workers))])
             (values (/ (for/fold ([s : Float 0.0]) ([w (in-list nearby-enemy-workers)]) (+ s (u-x w))) nw)
                     (/ (for/fold ([s : Float 0.0]) ([w (in-list nearby-enemy-workers)]) (+ s (u-y w))) nw)))
           (values (point2d-x safe-pt) (point2d-y safe-pt))))
     (define unload-ab-id (transport-unload-ability-id tr-sym))
     ;; L59-P3 (`n05`/`n18`/`n14` anti-spam fix): Never re-issue `396`/`913`/`1408` while the
     ;; transport is ALREADY executing an unload order or within `< 12f` of our last unload order,
     ;; otherwise SC2 resets the `0.5s` unload channel every 4 frames and traps passengers inside!
     (define cur-order-ab (safe-exact-int (dyn-hash-ref tr-u 'order-ability-id 0) 0))
     (define already-unloading?
       (or (not (not (memv cur-order-ab '(395 396 913 914 1408 1409 3669))))
           (and tr
                (let ([last-u (hash-ref (transport-tracker-transport-last-unload tr) tr-tag (lambda () -10000))])
                  (and (>= current-frame last-u) (< (- current-frame last-u) 12))))))

     (define last-boost
       (if tr (hash-ref (transport-tracker-medivac-last-boost tr) tr-tag (lambda () -1000)) -1000))
     (define boost-delta (- current-frame last-boost))
     (define in-boost-unload-window?
       (and (eq? tr-sym 'medivac)
            (<= MEDIVAC-BOOST-UNLOAD-MIN-FRAMES boost-delta MEDIVAC-BOOST-UNLOAD-MAX-FRAMES)))
     (define boost-available?
       (and (eq? tr-sym 'medivac)
            (u-boost-ready? tr-u)
            (>= boost-delta 224)))
     (define active-prof (current-active-drop-profile))
     (define eff-min-dwell : Integer
       (if offensive-mineral-drop?
           0
           (if active-prof (drop-profile-min-dwell-frames active-prof) MIN-CARRY-DWELL-FRAMES)))
     (define eff-load-cd : Integer
       (if active-prof (drop-profile-load-cd-frames active-prof) TRANSPORT-LOAD-UNLOAD-COOLDOWN-FRAMES))
     (define unload-cd
       (if tr
           (let ([last-load (hash-ref (transport-tracker-transport-last-load tr) tr-tag (lambda () -10000))])
             (max 0 (- (+ last-load eff-load-cd) current-frame)))
           0))
     (define can-unload?
       (and (not already-unloading?)
            (or (= unload-cd 0) (>= carry-dwell STUCK-CARGO-CEILING-FRAMES))))

     (cond
       ;; 0. L59-P3 (`n19`/`ro28`/`ro26`/`n05`/`n18` fix): Offensive mineral-line drop transit &
       ;;    reliable unload! Unload cleanly once within `<= 6.5t` (or `<= 2.8t` for Banelings) OR
       ;;    immediately when taking fire (`hp < 92%`, `< 72%` Banelings) or facing AA defenders
       ;;    within `<= 8.0t` — NEVER fly over Stalkers/Marines and die with `0` unloads!
       [offensive-mineral-drop?
        (define d-ml (dist-2d tx ty sx sy))
        (define aa-threat-near? : Boolean
          (for/or : Boolean ([e (in-list enemy-units)])
            (and (u-alive? e)
                 (anti-air-defender-sym? (exact-unit-type e))
                 (<= (dist-2d tx ty (u-x e) (u-y e)) 8.0))))
        (define drop-r : Float (if has-bane-cargo? 2.8 6.5))
        (define urgent-drop? : Boolean
          (or (<= d-ml drop-r)
              (< hp-rat (if has-bane-cargo? 0.72 0.92))
              (and aa-threat-near? (<= d-ml (if has-bane-cargo? 6.0 9.5)))))
        (cond
          [already-unloading? #f]
          [(and can-unload? urgent-drop?)
           (when tr (transport-tracker-record-unload! tr tr-tag current-frame))
           ;; Use moving self-drop when over-flying (`d-ml > 3.5` or Banelings/Medivac) so cargo pours
           ;; out cleanly while gliding toward workers; use point unload at worker center when right on top!
           (if (or has-bane-cargo? (eq? tr-sym 'medivac) (> d-ml 3.5))
               (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                                    unload-ab-id tr-tag ptags sx sy 'offensive-mineral-line-moving-drop)
               (transport-directive tr-tag tr-sym 'transport-drop-point 'unload-all-at
                                    unload-ab-id 0 ptags sx sy 'offensive-mineral-line-drop))]
          [(and boost-available? (> d-ml 5.0))
           (when tr (transport-tracker-record-boost! tr tr-tag current-frame))
           (transport-directive tr-tag tr-sym 'medivac-boost 'medivac-boost
                                MEDIVAC-BOOST-ABILITY-ID tr-tag ptags sx sy 'offensive-drop-medivac-boost)]
          [else
           (transport-directive tr-tag tr-sym 'move-to-drop 'move
                                16 tr-tag ptags sx sy 'offensive-drop-transit-mineral-line)])]

       ;; 0b. If already executing an unload order, do NOT stomp the unload channel with a fresh move/unload!
       [already-unloading? #f]

       ;; 1. `< 25%` HP+shields emergency dump (only when per-profile Load->UnloadAt cooldown satisfied)
       [(and can-unload? (< hp-rat EMERGENCY-DUMP-HP-RATIO))
        (when tr (transport-tracker-record-unload! tr tr-tag current-frame))
        (if pos-safe?
            (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                                 unload-ab-id tr-tag ptags tx ty 'emergency-low-hp-dump)
            (transport-directive tr-tag tr-sym 'transport-drop-point 'unload-all-at
                                 unload-ab-id 0 ptags sx sy 'emergency-low-hp-offset-dump))]

       ;; 2. `672f` (30s) stuck-cargo safety unload ceiling
       [(>= carry-dwell STUCK-CARGO-CEILING-FRAMES)
        (when tr (transport-tracker-record-unload! tr tr-tag current-frame))
        (if pos-safe?
            (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                                 unload-ab-id tr-tag ptags tx ty 'stuck-cargo-ceiling-672f)
            (transport-directive tr-tag tr-sym 'transport-drop-point 'unload-all-at
                                 unload-ab-id 0 ptags sx sy 'stuck-cargo-ceiling-offset-672f))]

       ;; 3. `< eff-min-dwell` carry dwell or `< eff-load-cd` Load->UnloadAt cooldown -> hold/reposition safely
       [(or (< carry-dwell eff-min-dwell) (not can-unload?))
        (if (and boost-available? (> (dist-2d tx ty sx sy) 4.0))
            (begin
              (when tr (transport-tracker-record-boost! tr tr-tag current-frame))
              (transport-directive tr-tag tr-sym 'medivac-boost 'medivac-boost
                                   MEDIVAC-BOOST-ABILITY-ID tr-tag ptags sx sy 'medivac-boost-escape-hold))
            (transport-directive tr-tag tr-sym 'hold-and-reposition 'move
                                 16 tr-tag ptags sx sy
                                 (if (< carry-dwell eff-min-dwell)
                                     'carry-dwell-protect-hold
                                     'load-unload-cooldown-44f-hold)))]

       ;; 4. `>= 18f` (and `>= 44f` after Load) Medivac Boost -> Unload `16f-36f` moving self-drop cadence
       [(and in-boost-unload-window? pos-safe?)
        (when tr (transport-tracker-record-unload! tr tr-tag current-frame))
        (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                             unload-ab-id tr-tag ptags tx ty 'medivac-boost-moving-self-drop)]

       ;; 5. Active moving self-drop (`'transport-drop-moving` targeting transport's own tag)
       [(and pos-safe?
             (or prefer-moving-drop? (u-moving? tr-u))
             (<= (dist-2d tx ty sx sy) 6.5))
        (when tr (transport-tracker-record-unload! tr tr-tag current-frame))
        (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                             unload-ab-id tr-tag ptags tx ty 'transport-moving-self-drop)]

       ;; 6. Arrived at safe rear-offset drop point `[3.5..5.0]` outside AoE zones
       [(<= (dist-2d tx ty sx sy) 3.0)
        (when tr (transport-tracker-record-unload! tr tr-tag current-frame))
        (if prefer-moving-drop?
            (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                                 unload-ab-id tr-tag ptags sx sy 'transport-moving-self-drop)
            (transport-directive tr-tag tr-sym 'transport-drop-point 'unload-all-at
                                 unload-ab-id 0 ptags sx sy 'safe-rear-offset-drop))]

       ;; 7. Still transiting to safe drop zone (optionally trigger Medivac Boost first)
       [(and boost-available? prefer-moving-drop?)
        (when tr (transport-tracker-record-boost! tr tr-tag current-frame))
        (transport-directive tr-tag tr-sym 'medivac-boost 'medivac-boost
                             MEDIVAC-BOOST-ABILITY-ID tr-tag ptags sx sy 'medivac-boost-prep-moving-drop)]
       [else
        (transport-directive tr-tag tr-sym 'move-to-drop 'move
                             16 tr-tag ptags sx sy 'transit-safe-rear-drop)])]))

;; Evaluates cargo dwell, `<25%` dump, `672f` ceiling, Medivac Boost->Unload (`16f-36f`),
;; moving self-drops (`'transport-drop-moving`), and safe `[3.5..5.0]`-tile rear-offset drops.
(: evaluate-transport-drop
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option transport-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:front-x (Option Real)
         #:front-y (Option Real)
         #:danger-zones (Listof danger-zone)
         #:effects (Listof Any)
         #:prefer-moving-drop? Boolean
         #:drop-profile (Option drop-profile))
        (Option transport-directive)))
(define (evaluate-transport-drop tr-u ally-units enemy-units
                                 #:tracker [tr #f]
                                 #:current-frame [current-frame 0]
                                 #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                 #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                 #:front-x [front-x-arg #f]
                                 #:front-y [front-y-arg #f]
                                 #:danger-zones [explicit-zones '()]
                                 #:effects [effects '()]
                                 #:prefer-moving-drop? [prefer-moving-drop? #f]
                                 #:drop-profile [prof #f])
  (define tr-sym (exact-unit-type tr-u))
  (define tr-tag (u-tag tr-u))
  (define ptags (extract-passenger-tags tr-u))
  (define cargo-used (u-cargo-space-taken tr-u))
  (cond
    [(or (not (u-alive? tr-u))
         (<= tr-tag 0)
         (not (transport-unit-sym? tr-sym))
         (and (null? ptags) (<= cargo-used 0)))
     #f]
    [else
     (define zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame)))
     (define eff-moving? (or prefer-moving-drop? (and prof (drop-profile-moving-drop? prof))))
     (parameterize ([current-active-drop-profile prof])
       (evaluate-transport-drop/zones tr-u ally-units enemy-units tr current-frame
                                      home-x home-y front-x-arg front-y-arg zones eff-moving?))]))

;; =============================================================================
;; 3. WarpPrism Phasing Management (`1528` <-> `1530`)
;; =============================================================================

(: evaluate-warp-prism-phasing/zones
   (-> Any (Listof Any) (Listof Any) (Option transport-tracker) Integer (Listof danger-zone)
       Boolean Boolean Boolean
       (Option transport-directive)))
(define (evaluate-warp-prism-phasing/zones prism-u ally-units enemy-units
                                           tr current-frame zones
                                           warp-in-complete? warp-in-requested? check-emergency-save?)
  (define ut (exact-unit-type prism-u))
  (define tag (u-tag prism-u))
  (cond
    [(or (not (u-alive? prism-u))
         (not (memq ut '(warp-prism warp-prism-phasing))))
     #f]
    [else
     (define px (u-x prism-u))
     (define py (u-y prism-u))
     (define hp-rat (u-hp-ratio prism-u))
     (define is-phasing? (eq? ut 'warp-prism-phasing))
     (define phase-tbl (and tr (transport-tracker-prism-phases tr)))
     (cond
       [is-phasing?
        (define phase-dwell
          (if tr (transport-tracker-prism-phase-dwell tr tag current-frame) WARP-PRISM-TARGET-WARP-CYCLE-FRAMES))
        (define can-unphase? (prism-can-unphase? tr tag current-frame))
        (define-values (emergency-victim _why)
          (if (and can-unphase? check-emergency-save?)
              (find-save-pickup-target prism-u ut ally-units enemy-units zones)
              (values #f 'none)))
        (define-values (has-army? acx acy)
          (for/fold ([sx : Float 0.0] [sy : Float 0.0] [n : Integer 0]
                     #:result (if (> n 0)
                                  (values #t (/ sx (->float n)) (/ sy (->float n)))
                                  (values #f 0.0 0.0)))
                    ([a (in-list ally-units)]
                     #:when (and (u-alive? a)
                                 (not (u-flying? a))
                                 (not (u-structure? a))
                                 (not (memq (exact-unit-type a) '(probe)))))
            (values (+ sx (u-x a)) (+ sy (u-y a)) (add1 n))))
        ;; L59-P3 (`n17` fix): Protect active warp-ins (`build-progress < 1.0` within `7.5t`) and
        ;; offensive warp-in prism cycles (`phase-dwell < 160f`, 0 ground army yet) from premature
        ;; unphasing (`1530`) unless Prism EHP drops below `< 35%` (`novel-104` still unphases at `19.4%`!).
        (define warping-allies-under-prism? : Boolean
          (for/or : Boolean ([a (in-list ally-units)])
            (and (u-alive? a)
                 (not (u-flying? a))
                 (not (u-structure? a))
                 (not (u-completed? a))
                 (<= (dist-2d px py (u-x a) (u-y a)) 7.5))))
        (define hold-phase-for-live-warp? : Boolean
          (and (>= hp-rat 0.35)
               (or warping-allies-under-prism?
                   (and warp-in-requested? (not has-army?) (< phase-dwell 160)))))
        (define immediate-reason : (Option Symbol)
          (cond
            [(not can-unphase?)                      #f]
            [(< hp-rat 0.35)                         'warp-prism-unphase-low-hp]
            [hold-phase-for-live-warp?               #f]
            [emergency-victim                         'warp-prism-unphase-emergency-save]
            [(< hp-rat WARP-PRISM-UNPHASE-HP-RATIO)   'warp-prism-unphase-low-hp]
            [(< (nearest-enemy-combat-dist px py enemy-units) WARP-PRISM-THREAT-UNPHASE-RADIUS)
             'warp-prism-unphase-threat-close]
            [(and has-army?
                  (not warp-in-requested?)
                  (> (dist-2d px py acx acy) WARP-PRISM-ARMY-LEASH-RADIUS))
             'warp-prism-unphase-army-far]
            [else #f]))
        (define keep-phasing-for-warp-or-army?
          (or hold-phase-for-live-warp?
              warp-in-requested?
              (and has-army? (not warp-in-complete?))))
        (define cycle-reason : (Option Symbol)
          (cond
            [(not can-unphase?) #f]
            [immediate-reason immediate-reason]
            [keep-phasing-for-warp-or-army? #f]
            [(>= phase-dwell WARP-PRISM-TARGET-WARP-CYCLE-FRAMES)
             'warp-prism-unphase-cycle-complete]
            [(and warp-in-complete? (>= phase-dwell WARP-PRISM-MIN-PHASING-DWELL-FRAMES))
             'warp-prism-unphase-warp-done]
            [else #f]))
        (if cycle-reason
            (begin
              (when phase-tbl
                (define prev (hash-ref phase-tbl tag (lambda () #f)))
                (hash-set! phase-tbl tag
                           (prism-phase-rec (if prev (prism-phase-rec-phase-start-frame prev) current-frame)
                                            current-frame
                                            #f)))
              (transport-directive tag ut 'morph-warp-prism-transport 'morph-warp-prism-transport
                                   MORPH-WARP-PRISM-TRANSPORT-ABILITY-ID tag '() px py cycle-reason))
            #f)]
       [else
        (define cargo-empty? (and (null? (extract-passenger-tags prism-u))
                                  (<= (u-cargo-space-taken prism-u) 0)))
        (define rephase-cd
          (if tr (transport-tracker-prism-rephase-cooldown tr tag current-frame) 0))
        (cond
          [(or (not cargo-empty?)
               (not (zero? rephase-cd))
               (< hp-rat WARP-PRISM-UNPHASE-HP-RATIO)
               (and (pair? zones) (point-in-danger-zones? px py zones 0.75)))
           #f]
          [else
           (define-values (emergency-victim _why)
             (if check-emergency-save?
                 (find-save-pickup-target prism-u ut ally-units enemy-units zones)
                 (values #f 'none)))
           (cond
             [emergency-victim #f]
             [(< (nearest-enemy-combat-dist px py enemy-units) WARP-PRISM-THREAT-UNPHASE-RADIUS) #f]
             [else
              (define army-ok?
                (if warp-in-requested?
                    #t
                    (let-values ([(has-army? acx acy)
                                  (for/fold ([sx : Float 0.0] [sy : Float 0.0] [n : Integer 0]
                                             #:result (if (> n 0)
                                                          (values #t (/ sx (->float n)) (/ sy (->float n)))
                                                          (values #f 0.0 0.0)))
                                            ([a (in-list ally-units)]
                                             #:when (and (u-alive? a)
                                                         (not (u-flying? a))
                                                         (not (u-structure? a))
                                                         (not (memq (exact-unit-type a) '(probe)))))
                                    (values (+ sx (u-x a)) (+ sy (u-y a)) (add1 n)))])
                      (and has-army? (<= (dist-2d px py acx acy) WARP-PRISM-ARMY-LEASH-RADIUS)))))
              (if army-ok?
                  (begin
                    (when phase-tbl
                      (define prev (hash-ref phase-tbl tag (lambda () #f)))
                      (hash-set! phase-tbl tag
                                 (prism-phase-rec current-frame
                                                  (if prev (prism-phase-rec-last-unphase-frame prev) -10000)
                                                  #t)))
                    (transport-directive tag ut 'morph-warp-prism-phasing 'morph-warp-prism-phasing
                                         MORPH-WARP-PRISM-PHASING-ABILITY-ID tag '() px py
                                         'warp-prism-phase-for-warp-cycle))
                  #f)])])])]))

;; Evaluates WarpPrism phasing (`1528`) / unphasing (`1530`) using `#115` dwells:
;; min dwell `140f`, target warp-cycle `208f`, rephase cooldown `160f`, plus immediate
;; unphase on `<10.0`-tile threat, `<65%` HP+shield, army `>9.0` away, or emergency save.
(: evaluate-warp-prism-phasing
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option transport-tracker)
         #:current-frame Integer
         #:danger-zones (Listof danger-zone)
         #:effects (Listof Any)
         #:warp-in-complete? Boolean
         #:warp-in-requested? Boolean)
        (Option transport-directive)))
(define (evaluate-warp-prism-phasing prism-u ally-units enemy-units
                                     #:tracker [tr #f]
                                     #:current-frame [current-frame 0]
                                     #:danger-zones [explicit-zones '()]
                                     #:effects [effects '()]
                                     #:warp-in-complete? [warp-in-complete? #f]
                                     #:warp-in-requested? [warp-in-requested? #t])
  (define ut (exact-unit-type prism-u))
  (cond
    [(or (not (u-alive? prism-u))
         (not (memq ut '(warp-prism warp-prism-phasing))))
     #f]
    [else
     (define zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame)))
     (evaluate-warp-prism-phasing/zones prism-u ally-units enemy-units tr current-frame zones
                                        warp-in-complete? warp-in-requested? #t)]))

;; =============================================================================
;; 4. OverlordTransport Eligibility (`'morph-overlord-transport` `2708`)
;; =============================================================================

;; Sums Dropperlord-eligible combat supply (`Roach`, `Hydralisk`, `Lurker`, `Baneling`, `Queen`).
(: overlord-drop-combat-supply (-> (Listof Any) Float))
(define (overlord-drop-combat-supply ally-units)
  (for/fold ([sum : Float 0.0])
            ([a (in-list ally-units)]
             #:when (u-alive? a))
    (+ sum
       (case (exact-unit-type a)
         [(roach roach-burrowed)                             2.0]
         [(hydralisk hydralisk-burrowed)                     2.0]
         [(lurker lurker-burrowed lurker-mp lurker-mp-burrowed
           lurker-egg lurker-mp-egg)                         3.0]
         [(queen queen-burrowed)                             2.0]
         [(baneling baneling-burrowed baneling-cocoon)       0.5]
         [else                                               0.0]))))

;; Scalar check for Dropperlord eligibility (`Lair`/`Hive` ready, supply >= 16, active < 2).
(: overlord-transport-eligible? (-> Boolean Real Integer Boolean))
(define (overlord-transport-eligible? lair-or-hive-ready? combat-supply active-dropperlords)
  (and lair-or-hive-ready?
       (>= (->float combat-supply) (->float DROPPERLORD-MIN-COMBAT-SUPPLY))
       (< active-dropperlords DROPPERLORD-MAX-ACTIVE-COUNT)))

;; Returns `#t` when a Zerg army should morph an `overlord-transport` (`2708`).
;; Accepts either an `ally-units` list (with optional keyword overrides) or scalar `lair-ready?`.
(: should-morph-overlord-transport?
   (->* ((U Boolean (Listof Any)))
        ((Option Real)
         (Option Integer)
         #:lair-or-hive-ready? (U Boolean 'auto)
         #:combat-supply (Option Real)
         #:active-dropperlords (Option Integer))
        Boolean))
(define (should-morph-overlord-transport? ally-or-lair
                                          [pos-supply #f]
                                          [pos-active #f]
                                          #:lair-or-hive-ready? [kw-lair 'auto]
                                          #:combat-supply [kw-supply #f]
                                          #:active-dropperlords [kw-active #f])
  (cond
    [(boolean? ally-or-lair)
     (define lair-ok?
       (if (eq? kw-lair 'auto) ally-or-lair (not (not kw-lair))))
     (define sup (or kw-supply pos-supply 0.0))
     (define act (or kw-active pos-active 0))
     (overlord-transport-eligible? lair-ok? sup act)]
    [(eq? kw-lair #f) #f]
    [(let ([act-ov (or kw-active pos-active)])
       (and act-ov (>= act-ov DROPPERLORD-MAX-ACTIVE-COUNT)))
     #f]
    [(let ([sup-ov (or kw-supply pos-supply)])
       (and sup-ov (< (->float sup-ov) (->float DROPPERLORD-MIN-COMBAT-SUPPLY))))
     #f]
    [else
     (define need-lair? (eq? kw-lair 'auto))
     (define need-sup? (not (or kw-supply pos-supply)))
     (define need-act? (not (or kw-active pos-active)))
     (define init-lair? (if need-lair? #f (not (not kw-lair))))
     (define init-sup : Float (if need-sup? 0.0 (->float (or kw-supply pos-supply 0.0))))
     (define init-act : Integer (if need-act? 0 (or kw-active pos-active 0)))
     (define-values (lair-ok? sup act)
       (for/fold ([l-ok? : Boolean init-lair?]
                  [s : Float init-sup]
                  [ac : Integer init-act])
                 ([a (in-list ally-or-lair)]
                  #:when (u-alive? a))
         (define ut (exact-unit-type a))
         (define next-l?
           (if (and need-lair? (not l-ok?) (memq ut '(lair hive)) (u-completed? a))
               #t
               l-ok?))
         (define next-s
           (if need-sup?
               (+ s
                  (case ut
                    [(roach roach-burrowed)                             2.0]
                    [(hydralisk hydralisk-burrowed)                     2.0]
                    [(lurker lurker-burrowed lurker-mp lurker-mp-burrowed
                      lurker-egg lurker-mp-egg)                         3.0]
                    [(queen queen-burrowed)                             2.0]
                    [(baneling baneling-burrowed baneling-cocoon)       0.5]
                    [else                                               0.0]))
               s))
         (define next-ac
           (if (and need-act? (memq ut '(overlord-transport transport-overlord-cocoon)))
               (add1 ac)
               ac))
         (values next-l? next-s next-ac)))
     (overlord-transport-eligible? lair-ok? sup act)]))

;; Selects up to 1 Overlord to morph into `'overlord-transport` (`2708`) when eligible.
(: plan-overlord-transport-morphs
   (->* ((Listof Any) (Listof Any))
        (#:lair-or-hive-ready? (U Boolean 'auto)
         #:combat-supply (Option Real)
         #:active-dropperlords (Option Integer))
        (Listof transport-directive)))
(define (plan-overlord-transport-morphs ally-units enemy-units
                                        #:lair-or-hive-ready? [kw-lair 'auto]
                                        #:combat-supply [kw-supply #f]
                                        #:active-dropperlords [kw-active #f])
  (cond
    [(or (eq? kw-lair #f)
         (and kw-active (>= kw-active DROPPERLORD-MAX-ACTIVE-COUNT))
         (and kw-supply (< (->float kw-supply) (->float DROPPERLORD-MIN-COMBAT-SUPPLY))))
     '()]
    [else
     (define need-lair? (eq? kw-lair 'auto))
     (define need-sup? (not kw-supply))
     (define need-act? (not kw-active))
     (define init-lair? (if need-lair? #f (not (not kw-lair))))
     (define init-sup : Float (if need-sup? 0.0 (->float (or kw-supply 0.0))))
     (define init-act : Integer (if need-act? 0 (or kw-active 0)))
     (define-values (lair-ok? sup act overlords)
       (for/fold ([l-ok? : Boolean init-lair?]
                  [s : Float init-sup]
                  [ac : Integer init-act]
                  [ovis : (Listof Any) '()])
                 ([a (in-list ally-units)]
                  #:when (u-alive? a))
         (define ut (exact-unit-type a))
         (define next-l?
           (if (and need-lair? (not l-ok?) (memq ut '(lair hive)) (u-completed? a))
               #t
               l-ok?))
         (define next-s
           (if need-sup?
               (+ s
                  (case ut
                    [(roach roach-burrowed)                             2.0]
                    [(hydralisk hydralisk-burrowed)                     2.0]
                    [(lurker lurker-burrowed lurker-mp lurker-mp-burrowed
                      lurker-egg lurker-mp-egg)                         3.0]
                    [(queen queen-burrowed)                             2.0]
                    [(baneling baneling-burrowed baneling-cocoon)       0.5]
                    [else                                               0.0]))
               s))
         (define next-ac
           (if (and need-act? (memq ut '(overlord-transport transport-overlord-cocoon)))
               (add1 ac)
               ac))
         (define next-ovis
           (if (and (eq? ut 'overlord) (> (u-tag a) 0))
               (cons a ovis)
               ovis))
         (values next-l? next-s next-ac next-ovis)))
     (if (and (pair? overlords) (overlord-transport-eligible? lair-ok? sup act))
         (let ([best-ovi
                (for/fold ([best : (Option Any) #f]
                           [best-safe : Float -1.0]
                           #:result best)
                          ([a (in-list overlords)])
                  (define safety-d (nearest-enemy-combat-dist (u-x a) (u-y a) enemy-units))
                  (if (> safety-d best-safe)
                      (values a safety-d)
                      (values best best-safe)))])
           (if best-ovi
               (let ([otag (u-tag best-ovi)])
                 (list (transport-directive otag 'overlord 'cast-spell 'morph-overlord-transport
                                            MORPH-OVERLORD-TRANSPORT-ABILITY-ID otag '()
                                            (u-x best-ovi) (u-y best-ovi)
                                            'dropperlord-midgame-mobility)))
               '()))
         '())]))

;; =============================================================================
;; 5. Multi-Angle Mini Overlord Drops (`893`) & Counter-Drop Defense (Wave 1C)
;; =============================================================================

(: MINI-DROP-MAX-ACTIVE-COUNT Integer)
(define MINI-DROP-MAX-ACTIVE-COUNT 3)

(: MINI-DROP-CARGO-MIN Integer)
(define MINI-DROP-CARGO-MIN 4)

(: MINI-DROP-CARGO-MAX Integer)
(define MINI-DROP-CARGO-MAX 8)

(: DROP-LOADED-FOCUS-FIRE-BONUS Float)
(define DROP-LOADED-FOCUS-FIRE-BONUS 50.0)

(: COUNTER-DROP-DEFENSE-POWER-MULT Float)
(define COUNTER-DROP-DEFENSE-POWER-MULT 1.25)

(: COUNTER-DROP-MAX-ARMY-PULL-FRACTION Float)
(define COUNTER-DROP-MAX-ARMY-PULL-FRACTION 0.35)

;; Single unit defense assignment against an incoming or unloaded enemy drop.
(struct counter-drop-order
  ([unit-tag : Integer]
   [unit-type : Symbol]
   [action : Symbol]
   [target-tag : Integer]
   [tx : Float]
   [ty : Float]
   [priority : Float]
   [assigned-drop-tag : Integer]
   [reason : Symbol])
  #:transparent)

;; Summary plan for proportional anti-drop interception & base defense split.
(struct counter-drop-plan
  ([enemy-drops-detected : Integer]
   [drop-combat-power : Float]
   [required-defense-power : Float]
   [assigned-defense-power : Float]
   [max-army-pull-power : Float]
   [total-army-power : Float]
   [orders : (Listof counter-drop-order)]
   [worker-pull-orders : (Listof counter-drop-order)])
  #:transparent)

(: anti-air-defender-sym? (-> Symbol Boolean))
(define (anti-air-defender-sym? sym)
  (not (not (memq sym
                  '(marine stalker phoenix viking viking-fighter cyclone
                    hydralisk queen mutalisk corruptor archon ghost thor thor-ap
                    void-ray voidray spore-crawler missile-turret photon-cannon
                    bunker liberator-aa)))))

(: drop-unit-combat-power (-> Any Float))
(define (drop-unit-combat-power u)
  (define ut (exact-unit-type u))
  (define stats (cached-unit-combat-stats ut))
  (define gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0))
  (define adps (safe-finite-real (hash-ref stats 'air-dps (lambda () 0.0)) 0.0))
  (define max-dps (max gdps adps))
  (define ehp (u-total-ehp u))
  (cond
    [(and (> max-dps 0.0) (not (memq ut '(scv probe drone mule))))
     (max 8.0 (->float (sqrt (max 0.0 (* ehp max-dps)))))]
    [(transport-unit-sym? ut)
     (define cargo (u-cargo-space-taken u))
     ;; Active drop transport with cargo carries lethal raiding potential even before unload
     (+ 16.0 (* 12.0 (->float (max 2 cargo))))]
    [else 10.0]))

(: unit-loaded-transport? (-> Any Boolean))
(define (unit-loaded-transport? tr-u)
  (or (> (u-cargo-space-taken tr-u) 0)
      (not (null? (extract-passenger-tags tr-u)))
      (eq? (dyn-hash-ref tr-u 'loaded? #f) #t)
      (eq? (dyn-hash-ref tr-u 'has-cargo? #f) #t)))

(: infer-enemy-drop-mineral-targets (-> (Listof Any) Real Real (Option Real) (Option Real) (Listof (Pair Float Float))))
(define (infer-enemy-drop-mineral-targets enemy-units home-x home-y enemy-main-x enemy-main-y)
  (define fh-x (->float home-x))
  (define fh-y (->float home-y))
  (define townhalls
    (sort
     (for/list : (Listof Any) ([e (in-list enemy-units)]
                               #:when (and (u-alive? e)
                                           (memq (exact-unit-type e)
                                                 '(nexus command-center orbital-command
                                                   planetary-fortress hatchery lair hive))))
       e)
     (lambda ([a : Any] [b : Any])
       (> (dist-2d fh-x fh-y (u-x a) (u-y a))
          (dist-2d fh-x fh-y (u-x b) (u-y b))))))
  (cond
    [(>= (length townhalls) 2)
     (for/list : (Listof (Pair Float Float)) ([th (in-list (take townhalls (min 3 (length townhalls))))])
       (cons (u-x th) (u-y th)))]
    [(or (= (length townhalls) 1) (and enemy-main-x enemy-main-y))
     (define mx (if (pair? townhalls) (u-x (car townhalls)) (->float (or enemy-main-x 130.0))))
     (define my (if (pair? townhalls) (u-y (car townhalls)) (->float (or enemy-main-y 130.0))))
     (define dx (- fh-x mx))
     (define dy (- fh-y my))
     (define n (max 1e-4 (dist-2d 0.0 0.0 dx dy)))
     (define ux (/ dx n))
     (define uy (/ dy n))
     ;; Main, opposite-flank 3rd, and natural along home-enemy vectors
     (define third-pt (clamp-playable-pt (+ mx (* 30.0 (- uy))) (+ my (* 30.0 ux))))
     (define nat-pt (clamp-playable-pt (+ mx (* 28.0 ux)) (+ my (* 28.0 uy))))
     (list (cons mx my)
           (cons (point2d-x third-pt) (point2d-y third-pt))
           (cons (point2d-x nat-pt) (point2d-y nat-pt)))]
    [else
     (define gx (max 40.0 (min (- SC2-MAP-PLAYABLE-MAX-COORD 20.0) (- 200.0 fh-x))))
     (define gy (max 40.0 (min (- SC2-MAP-PLAYABLE-MAX-COORD 20.0) (- 200.0 fh-y))))
     (define third-pt (clamp-playable-pt (- gx 26.0) gy))
     (define nat-pt (clamp-playable-pt gx (- gy 26.0)))
     (list (cons gx gy)
           (cons (point2d-x third-pt) (point2d-y third-pt))
           (cons (point2d-x nat-pt) (point2d-y nat-pt)))]))

(: peripheral-edge-waypoint (-> Float Float Float Float Integer Float Float (Pair Float Float)))
(define (peripheral-edge-waypoint hx hy tx ty side-sign map-w map-h)
  (define dx (- tx hx))
  (define dy (- ty hy))
  (define d (max 1e-4 (dist-2d 0.0 0.0 dx dy)))
  ;; Perpendicular lateral vector: +1 -> left normal, -1 -> right normal
  (define nx (* (->float side-sign) (/ (- dy) d)))
  (define ny (* (->float side-sign) (/ dx d)))
  (define mid-x (* 0.5 (+ hx tx)))
  (define mid-y (* 0.5 (+ hy ty)))
  (define push-dist (max 44.0 (* 0.48 (min map-w map-h))))
  (define min-c (+ SC2-MAP-PLAYABLE-MIN-COORD 8.0))
  (define max-x (- (max 80.0 map-w) 8.0))
  (define max-y (- (max 80.0 map-h) 8.0))
  (define wx (max min-c (min max-x (+ mid-x (* push-dist nx)))))
  (define wy (max min-c (min max-y (+ mid-y (* push-dist ny)))))
  (cons wx wy))

(: mini-drop-cargo-eligible-weight (-> Symbol Integer))
(define (mini-drop-cargo-eligible-weight sym)
  (case sym
    [(zergling)              1]
    [(baneling)              2]
    [(roach)                 2]
    [(hydralisk)             2]
    [(ravager)               4]
    [else                    0]))

(: select-compact-mini-drop-cargo
   (-> Float Float (Listof Any) (Mutable-HashTable Integer Boolean) (Values (Listof Integer) Integer Float Float)))
(define (select-compact-mini-drop-cargo ox oy ally-units used-tags)
  (define candidates
    (sort
     (for/list : (Listof Any) ([a (in-list ally-units)]
                               #:when (and (u-alive? a)
                                           (> (u-tag a) 0)
                                           (not (hash-has-key? used-tags (u-tag a)))
                                           (> (mini-drop-cargo-eligible-weight (exact-unit-type a)) 0)
                                           (<= (dist-2d ox oy (u-x a) (u-y a)) 28.0)))
       a)
     (lambda ([a : Any] [b : Any])
       (define wa (mini-drop-cargo-eligible-weight (exact-unit-type a)))
       (define wb (mini-drop-cargo-eligible-weight (exact-unit-type b)))
       (define da (- (dist-2d ox oy (u-x a) (u-y a)) (if (eq? (exact-unit-type a) 'baneling) 3.0 0.0)))
       (define db (- (dist-2d ox oy (u-x b) (u-y b)) (if (eq? (exact-unit-type b) 'baneling) 3.0 0.0)))
       (if (not (= da db)) (< da db) (< wa wb)))))
  (define-values (chosen slots sx sy cnt)
    (for/fold ([acc : (Listof Integer) '()]
               [used : Integer 0]
               [sum-x : Float 0.0]
               [sum-y : Float 0.0]
               [n : Integer 0])
              ([c (in-list candidates)])
      (define w (mini-drop-cargo-eligible-weight (exact-unit-type c)))
      (define ct (u-tag c))
      (if (<= (+ used w) MINI-DROP-CARGO-MAX)
          (begin
            (hash-set! used-tags ct #t)
            (values (cons ct acc) (+ used w) (+ sum-x (u-x c)) (+ sum-y (u-y c)) (add1 n)))
          (values acc used sum-x sum-y n))))
  (if (> cnt 0)
      (values (reverse chosen) slots (/ sx (->float cnt)) (/ sy (->float cnt)))
      (values '() 0 ox oy)))

;; Plans `1–3` independent compact `overlord-transport` (`893`) drops carrying `4–8` cargo
;; (`4` Lings / `2` Banes / `2` Roaches) along opposite left/right peripheral map edges
;; into enemy main and 3rd/natural mineral lines simultaneously.
(: plan-multi-angle-mini-overlord-drops
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option transport-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:enemy-main-x (Option Real)
         #:enemy-main-y (Option Real)
         #:enemy-targets (Listof (Pair Real Real))
         #:map-width Real
         #:map-height Real
         #:max-drops Integer
         #:lair-or-hive-ready? (U Boolean 'auto))
        (Listof transport-directive)))
(define (plan-multi-angle-mini-overlord-drops ally-units enemy-units
                                              #:tracker [_tr #f]
                                              #:current-frame [_current-frame 0]
                                              #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                              #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                              #:enemy-main-x [enemy-main-x #f]
                                              #:enemy-main-y [enemy-main-y #f]
                                              #:enemy-targets [explicit-targets '()]
                                              #:map-width [map-width SC2-MAP-PLAYABLE-MAX-COORD]
                                              #:map-height [map-height SC2-MAP-PLAYABLE-MAX-COORD]
                                              #:max-drops [max-drops MINI-DROP-MAX-ACTIVE-COUNT]
                                              #:lair-or-hive-ready? [kw-lair 'auto])
  (define cap-drops (max 1 (min MINI-DROP-MAX-ACTIVE-COUNT max-drops)))
  (define fh-x (->float home-x))
  (define fh-y (->float home-y))
  (define fmw (->float map-width))
  (define fmh (->float map-height))
  (define raw-targets : (Listof (Pair Float Float))
    (if (pair? explicit-targets)
        (for/list : (Listof (Pair Float Float)) ([p (in-list explicit-targets)])
          (cons (->float (car p)) (->float (cdr p))))
        (infer-enemy-drop-mineral-targets enemy-units fh-x fh-y enemy-main-x enemy-main-y)))
  (define all-dropperlords
    (sort
     (for/list : (Listof Any) ([a (in-list ally-units)]
                               #:when (and (u-alive? a)
                                           (eq? (exact-unit-type a) 'overlord-transport)
                                           (> (u-tag a) 0)))
       a)
     (lambda ([a : Any] [b : Any])
       (> (u-cargo-space-taken a) (u-cargo-space-taken b)))))
  (define dropperlords
    (take all-dropperlords (min cap-drops (length all-dropperlords))))
  (define used-cargo : (Mutable-HashTable Integer Boolean) (make-hasheqv))
  (define n-tgts (max 1 (length raw-targets)))
  (define active-dirs
    (for/fold ([acc : (Listof transport-directive) '()]
               #:result (reverse acc))
              ([dl (in-list dropperlords)]
               [idx (in-naturals)])
      (define dtag (u-tag dl))
      (define dx (u-x dl))
      (define dy (u-y dl))
      (define cargo (u-cargo-space-taken dl))
      (define tgt-pair (list-ref raw-targets (modulo idx n-tgts)))
      (define tx (car tgt-pair))
      (define ty (cdr tgt-pair))
      ;; Odd/even indices strictly alternate opposite left (+1) and right (-1) peripheral edges
      (define edge-side (if (even? idx) 1 -1))
      (define edge-lbl (if (= edge-side 1) 'left-edge 'right-edge))
      (define edge-pt (peripheral-edge-waypoint fh-x fh-y tx ty edge-side fmw fmh))
      (define wx (car edge-pt))
      (define wy (cdr edge-pt))
      (define d-target (dist-2d dx dy tx ty))
      (define d-edge (dist-2d dx dy wx wy))
      (define d-home-to-dl (dist-2d fh-x fh-y dx dy))
      (define d-home-to-edge (dist-2d fh-x fh-y wx wy))
      (define dir
        (cond
          ;; Loaded (`>= 4` cargo or already deep near enemy line) -> fly via peripheral edge & unload
          [(or (>= cargo MINI-DROP-CARGO-MIN)
               (and (> cargo 0) (< d-target 26.0)))
           (define ptags-dl (extract-passenger-tags dl))
           ;; L59-P2 (`#1481`): Detect Baneling carpet-bomb cargo -> moving self-drop right overhead (`<= 1.2t`)!
           (define raw-pass-list (if (hash? dl) (dyn-hash-ref dl 'passengers '()) '()))
           (define has-baneling-cargo?
             (or (and (list? raw-pass-list)
                      (for/or : Boolean ([p (in-list raw-pass-list)])
                        (and (hash? p) (eq? (exact-unit-type p) 'baneling))))
                 (let ([ctypes (if (hash? dl) (dyn-hash-ref dl 'cargo-types '()) '())])
                   (and (list? ctypes) (not (not (memq 'baneling ctypes)))))))
           (cond
             [(and has-baneling-cargo? (<= d-target 1.2))
              (transport-directive dtag 'overlord-transport 'transport-drop-moving
                                   'transport-drop-moving OVERLORD-UNLOAD-ALL-AT-ABILITY-ID
                                   dtag ptags-dl tx ty 'baneling-drop-moving-carpet-bomb)]
             [(and (not has-baneling-cargo?) (<= d-target 5.5))
              (transport-directive dtag 'overlord-transport 'transport-drop-point
                                   'unload-all-at OVERLORD-UNLOAD-ALL-AT-ABILITY-ID
                                   dtag ptags-dl tx ty
                                   (if (= edge-side 1)
                                       'mini-dropperlord-unload-left-edge
                                       'mini-dropperlord-unload-right-edge))]
             ;; Route along assigned peripheral edge waypoint before cutting inward to mineral line
             [(and (> d-edge 10.0) (< d-home-to-dl (+ d-home-to-edge 8.0)) (> d-target 22.0))
              (transport-directive dtag 'overlord-transport 'move-to-drop 'move 16
                                   dtag (extract-passenger-tags dl) wx wy
                                   (if (eq? edge-lbl 'left-edge)
                                       'mini-dropperlord-route-left-edge
                                       'mini-dropperlord-route-right-edge))]
             [else
              (transport-directive dtag 'overlord-transport 'move-to-drop 'move 16
                                   dtag (extract-passenger-tags dl) tx ty
                                   (if (eq? edge-lbl 'left-edge)
                                       'mini-dropperlord-inward-left-angle
                                       'mini-dropperlord-inward-right-angle))])]
          ;; Empty / < 4 cargo -> load compact 4-8 cargo slice (4 Lings / 2 Banes / 2 Roaches)
          [else
           (define-values (ptags _slots cx cy)
             (select-compact-mini-drop-cargo dx dy ally-units used-cargo))
           (cond
             [(pair? ptags)
              (define d-cargo (dist-2d dx dy cx cy))
              (if (<= d-cargo 2.5)
                  (transport-directive dtag 'overlord-transport 'load-unit 'load-transport
                                       LOAD-TRANSPORT-ABILITY-ID (car ptags) ptags cx cy
                                       'mini-dropperlord-load-compact-cargo)
                  (transport-directive dtag 'overlord-transport 'approach-save-pickup 'move 16
                                       (car ptags) ptags cx cy
                                       'mini-dropperlord-stage-for-cargo))]
             [else
              (transport-directive dtag 'overlord-transport 'hold-and-reposition 'move 16
                                   dtag '() dx dy 'mini-dropperlord-await-cargo)])]))
      (cons dir acc)))
  ;; Morph additional Dropperlords up to `cap-drops` (`<= 3`) when Lair/Hive + >= 16 supply ready
  (define active-cnt (length dropperlords))
  (define lair-ok?
    (if (eq? kw-lair 'auto)
        (for/or : Boolean ([a (in-list ally-units)])
          (and (u-alive? a) (memq (exact-unit-type a) '(lair hive)) (u-completed? a)))
        (not (not kw-lair))))
  (define morph-dirs : (Listof transport-directive)
    (if (and lair-ok?
             (< active-cnt cap-drops)
             (>= (overlord-drop-combat-supply ally-units) (->float DROPPERLORD-MIN-COMBAT-SUPPLY)))
        (let ([needed (- cap-drops active-cnt)]
              [candidates
               (sort
                (for/list : (Listof Any) ([a (in-list ally-units)]
                                          #:when (and (u-alive? a)
                                                      (eq? (exact-unit-type a) 'overlord)
                                                      (> (u-tag a) 0)))
                  a)
                (lambda ([a : Any] [b : Any])
                  (> (nearest-enemy-combat-dist (u-x a) (u-y a) enemy-units)
                     (nearest-enemy-combat-dist (u-x b) (u-y b) enemy-units))))])
          (for/list : (Listof transport-directive) ([ovi (in-list (take candidates (min needed (length candidates))))])
            (define otag (u-tag ovi))
            (transport-directive otag 'overlord 'cast-spell 'morph-overlord-transport
                                 MORPH-OVERLORD-TRANSPORT-ABILITY-ID otag '()
                                 (u-x ovi) (u-y ovi) 'mini-dropperlord-morph)))
        '()))
  (append active-dirs morph-dirs))

;; Prioritizes anti-air focus-fire on incoming loaded enemy drops (`medivac`, `warp-prism`,
;; `overlord-transport`, `+50` bonus when loaded) and computes a proportional local defense split
;; (`1.25x` drop combat power, capped by `max-army-pull-fraction` so a mini-drop never pulls our
;; entire front-line army away).
(: plan-counter-drop-defense
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real
         #:home-y Real
         #:base-points (Listof (Pair Real Real))
         #:max-army-pull-fraction Real
         #:defense-power-multiplier Real)
        counter-drop-plan))
(define (plan-counter-drop-defense ally-units enemy-units
                                   #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                   #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                   #:base-points [explicit-bases '()]
                                   #:max-army-pull-fraction [max-pull-frac COUNTER-DROP-MAX-ARMY-PULL-FRACTION]
                                   #:defense-power-multiplier [pwr-mult COUNTER-DROP-DEFENSE-POWER-MULT])
  (define fh-x (->float home-x))
  (define fh-y (->float home-y))
  (define bases : (Listof (Pair Float Float))
    (let ([discovered
           (for/list : (Listof (Pair Float Float))
                     ([a (in-list ally-units)]
                      #:when (and (u-alive? a)
                                  (memq (exact-unit-type a)
                                        '(nexus command-center orbital-command
                                          planetary-fortress hatchery lair hive))))
             (cons (u-x a) (u-y a)))])
      (cond
        [(pair? explicit-bases)
         (for/list : (Listof (Pair Float Float)) ([p (in-list explicit-bases)])
           (cons (->float (car p)) (->float (cdr p))))]
        [(pair? discovered) discovered]
        [else (list (cons fh-x fh-y))])))
  (: near-our-base? (-> Float Float Boolean))
  (define (near-our-base? ux uy)
    (for/or : Boolean ([b (in-list bases)])
      (<= (dist-2d ux uy (car b) (cdr b)) 20.0)))
  (define enemy-drop-transports
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (u-alive? e)
                                          (> (u-tag e) 0)
                                          (transport-unit-sym? (exact-unit-type e))
                                          (near-our-base? (u-x e) (u-y e))))
      e))
  (define unloaded-raiders
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (u-alive? e)
                                          (> (u-tag e) 0)
                                          (not (u-structure? e))
                                          (not (transport-unit-sym? (exact-unit-type e)))
                                          (near-our-base? (u-x e) (u-y e))))
      e))
  (define drop-power : Float
    (+ (for/fold ([acc : Float 0.0]) ([tr (in-list enemy-drop-transports)])
         (+ acc (drop-unit-combat-power tr)))
       (for/fold ([acc : Float 0.0]) ([r (in-list unloaded-raiders)])
         (+ acc (drop-unit-combat-power r)))))
  (define friendly-combat
    (for/list : (Listof Any) ([a (in-list ally-units)]
                              #:when (and (u-alive? a)
                                          (> (u-tag a) 0)
                                          (not (u-structure? a))
                                          (not (memq (exact-unit-type a)
                                                     '(scv probe drone mule larva egg overlord
                                                       observer changeling)))))
      a))
  (define total-army-power
    (for/fold ([acc : Float 0.0]) ([a (in-list friendly-combat)])
      (+ acc (drop-unit-combat-power a))))
  (define req-power (max 0.0 (* (->float pwr-mult) drop-power)))
  (define cap-frac (max 0.15 (min 0.75 (->float max-pull-frac))))
  (define max-pull-power
    (if (zero? total-army-power)
        0.0
        (min req-power (max 24.0 (* cap-frac total-army-power)))))
  (cond
    [(and (null? enemy-drop-transports) (null? unloaded-raiders))
     (counter-drop-plan 0 0.0 0.0 0.0 max-pull-power total-army-power '() '())]
    [else
     ;; Focus target priority: loaded enemy transport gets +50.0 bonus before unload!
     (: threat-prio (-> Any Float))
     (define (threat-prio e)
       (+ (if (and (transport-unit-sym? (exact-unit-type e))
                   (unit-loaded-transport? e))
              DROP-LOADED-FOCUS-FIRE-BONUS
              0.0)
          (drop-unit-combat-power e)))
     (define sorted-threats
       (sort (append enemy-drop-transports unloaded-raiders)
             (lambda ([a : Any] [b : Any]) (> (threat-prio a) (threat-prio b)))))
     (define primary-threat (car sorted-threats))
     (define primary-tag (u-tag primary-threat))
     (define ptx (u-x primary-threat))
     (define pty (u-y primary-threat))
     ;; Prefer nearest local/base defenders first so distant front-line main army stays put
     (: defender-cost (-> Any Float))
     (define (defender-cost a)
       (+ (dist-2d (u-x a) (u-y a) ptx pty)
          (if (anti-air-defender-sym? (exact-unit-type a)) -6.0 0.0)
          (if (near-our-base? (u-x a) (u-y a)) -12.0 18.0)))
     (define sorted-defenders
       (sort friendly-combat
             (lambda ([a : Any] [b : Any]) (< (defender-cost a) (defender-cost b)))))
     (define-values (rev-orders assigned-power)
       (for/fold ([orders : (Listof counter-drop-order) '()]
                  [acc-pwr : Float 0.0])
                 ([a (in-list sorted-defenders)])
         (define a-pwr (drop-unit-combat-power a))
         (if (or (>= acc-pwr max-pull-power)
                 (and (pair? orders)
                      (> (+ acc-pwr a-pwr) (* 1.05 max-pull-power))))
             (values orders acc-pwr)
             (let* ([atag (u-tag a)]
                    [at (exact-unit-type a)]
                    [aa? (anti-air-defender-sym? at)]
                    [best-tgt
                     (or (and aa?
                              (for/fold ([bt : (Option Any) #f]
                                         [bsc : Float -1e9]
                                         #:result bt)
                                        ([e (in-list enemy-drop-transports)])
                                (define loaded? (unit-loaded-transport? e))
                                (define sc (+ (if loaded? DROP-LOADED-FOCUS-FIRE-BONUS 15.0)
                                              (- (* 0.5 (dist-2d (u-x a) (u-y a) (u-x e) (u-y e))))))
                                (if (> sc bsc) (values e sc) (values bt bsc))))
                         (and (pair? unloaded-raiders) (not (u-flying? (car unloaded-raiders)))
                              (car unloaded-raiders))
                         primary-threat)]
                    [loaded-drop? (and (transport-unit-sym? (exact-unit-type best-tgt))
                                       (unit-loaded-transport? best-tgt))]
                    [prio (+ (drop-unit-combat-power best-tgt)
                             (if loaded-drop? DROP-LOADED-FOCUS-FIRE-BONUS 0.0))]
                    [reason : Symbol
                      (cond
                        [(and aa? loaded-drop?) 'aa-focus-loaded-drop-before-unload]
                        [(and aa? (transport-unit-sym? (exact-unit-type best-tgt)))
                         'aa-focus-enemy-transport]
                        [else 'proportional-drop-defense-split])]
                    [ord (counter-drop-order atag at 'attack-unit (u-tag best-tgt)
                                             (u-x best-tgt) (u-y best-tgt)
                                             prio primary-tag reason)])
               (values (cons ord orders) (+ acc-pwr a-pwr))))))
     ;; Worker evasion away from landing zone if threat landed right inside mineral line
     (define worker-pulls
       (for/list : (Listof counter-drop-order)
                 ([a (in-list ally-units)]
                  #:when (and (u-alive? a)
                              (> (u-tag a) 0)
                              (memq (exact-unit-type a) '(scv probe drone))
                              (<= (dist-2d (u-x a) (u-y a) ptx pty) 6.5)))
         (define wx (u-x a))
         (define wy (u-y a))
         (define dx (- wx ptx))
         (define dy (- wy pty))
         (define d (max 1e-4 (dist-2d 0.0 0.0 dx dy)))
         (define safe-pt (clamp-playable-pt (+ ptx (* 7.5 (/ dx d))) (+ pty (* 7.5 (/ dy d)))))
         (counter-drop-order (u-tag a) (exact-unit-type a) 'move primary-tag
                             (point2d-x safe-pt) (point2d-y safe-pt)
                             30.0 primary-tag 'evacuate-workers-from-drop)))
     (counter-drop-plan (length enemy-drop-transports)
                        drop-power
                        req-power
                        assigned-power
                        max-pull-power
                        total-army-power
                        (reverse rev-orders)
                        worker-pulls)]))

(: counter-drop-plan->sexps (-> counter-drop-plan (Listof (Listof Any))))
(define (counter-drop-plan->sexps plan)
  (append
   (for/list : (Listof (Listof Any)) ([ord (in-list (counter-drop-plan-orders plan))])
     (if (> (counter-drop-order-target-tag ord) 0)
         (list 'focus-fire
               (counter-drop-order-unit-tag ord)
               (counter-drop-order-target-tag ord)
               (counter-drop-order-tx ord)
               (counter-drop-order-ty ord))
         (list 'attack-pos
               (counter-drop-order-unit-tag ord)
               (counter-drop-order-tx ord)
               (counter-drop-order-ty ord))))
   (for/list : (Listof (Listof Any)) ([wp (in-list (counter-drop-plan-worker-pull-orders plan))])
     (list 'move
           (counter-drop-order-unit-tag wp)
           (counter-drop-order-tx wp)
           (counter-drop-order-ty wp)))))

;; =============================================================================
;; 5b. L59-P2 (`#1481`): 3-Race Cliff-Laddering Shuttle & Raid Evac/Base Rotation
;; =============================================================================

(: extract-passenger-types (-> Any (Listof Symbol)))
(define (extract-passenger-types tr-u)
  (cond
    [(not (hash? tr-u)) '()]
    [else
     (define ctypes (dyn-hash-ref tr-u 'cargo-types #f))
     (if (list? ctypes)
         (for/list : (Listof Symbol) ([s (in-list ctypes)] #:when (symbol? s)) s)
         (let ([raw (or (dyn-hash-ref tr-u 'passengers #f) (dyn-hash-ref tr-u 'cargo #f))])
           (if (list? raw)
               (for/fold ([acc : (Listof Symbol) '()] #:result (reverse acc))
                         ([item (in-list raw)])
                 (if (hash? item)
                     (let ([sym (exact-unit-type item)])
                       (if (eq? sym 'unknown) acc (cons sym acc)))
                     acc))
               '())))]))

;; 3-Race Cliff-Laddering Shuttle (`medivac`, `warp-prism`, `overlord-transport`):
;; Ferries friendly ground units at `z_lo` across an unpathable cliff/chasm onto
;; `(dest-x, dest-y)` at `dest-z` whenever `|dest-z - z_lo| >= 1.5`, strictly
;; outside active danger zones. Works symmetrically for uphill climb & cliff escape!
(: plan-cliff-ladder-shuttle
   (->* ((Listof Any) (Listof Any))
        (#:dest-x Real
         #:dest-y Real
         #:dest-z Real
         #:danger-zones (Listof danger-zone)
         #:tracker (Option transport-tracker)
         #:current-frame Integer)
        (Listof transport-directive)))
(define (plan-cliff-ladder-shuttle ally-units enemy-units
                                   #:dest-x [dest-x 80.0]
                                   #:dest-y [dest-y 80.0]
                                   #:dest-z [dest-z 12.0]
                                   #:danger-zones [zones '()]
                                   #:tracker [tr #f]
                                   #:current-frame [current-frame 0])
  (define dx-f (->float dest-x))
  (define dy-f (->float dest-y))
  (define dz-f (->float dest-z))
  (define transports : (Listof Any)
    (for/list : (Listof Any)
              ([a (in-list ally-units)]
               #:when (and (u-alive? a)
                           (> (u-tag a) 0)
                           (transport-unit-sym? (exact-unit-type a))))
      a))
  (define claimed-units : (Mutable-HashTable Integer Boolean) (make-hasheqv))
  (for/fold ([acc : (Listof transport-directive) '()] #:result (reverse acc))
            ([tr-u (in-list transports)])
    (define tr-tag (u-tag tr-u))
    (define tr-sym (exact-unit-type tr-u))
    (define tx (u-x tr-u))
    (define ty (u-y tr-u))
    (define cargo-used (u-cargo-space-taken tr-u))
    (define cargo-free (max 0 (- TRANSPORT-MAX-CARGO-CAPACITY cargo-used)))
    (define ptags (extract-passenger-tags tr-u))
    (define unload-ab (transport-unload-ability-id tr-sym))
    (define p-range (transport-pickup-range tr-sym))
    (define d-dest (dist-2d tx ty dx-f dy-f))
    (define dest-safe? (not (point-in-danger-zones? dx-f dy-f zones 0.5)))
    ;; Eligible ground allies on the DIFFERENT elevation (`|uz - dest-z| >= 1.5`) near this shuttle,
    ;; strictly excluding burrowed units and prioritizing heavy artillery (`siege-tank`/`lurker-mp`/`immortal`) first!
    (define (cliff-priority [u : Any]) : Float
      (define ut (exact-unit-type u))
      (define d (dist-2d tx ty (u-x u) (u-y u)))
      (- d
         (cond
           [(memq ut '(siege-tank lurker lurker-mp immortal archon colossus)) 20.0]
           [(memq ut '(marauder roach ravager stalker)) 6.0]
           [else 0.0])))
    (define ground-cands : (Listof Any)
      (sort
       (for/list : (Listof Any)
                 ([a (in-list ally-units)]
                  #:when (let ([ut (exact-unit-type a)]
                               [uz (u-z a)])
                           (and (u-alive? a)
                                (> (u-tag a) 0)
                                (not (hash-has-key? claimed-units (u-tag a)))
                                (not (u-flying? a))
                                (not (u-structure? a))
                                (not (memq ut '(lurker-burrowed lurker-mp-burrowed siege-tank-sieged widow-mine-burrowed)))
                                (not (eq? (dyn-hash-ref a 'burrowed #f) #t))
                                (not (eq? (dyn-hash-ref a 'is-burrowed #f) #t))
                                (transport-race-accepts-unit? tr-sym ut)
                                (<= (unit-cargo-size ut) cargo-free)
                                uz
                                (>= (abs (- uz dz-f)) 1.5)
                                (<= (dist-2d tx ty (u-x a) (u-y a)) 14.0))))
         a)
       (lambda ([a : Any] [b : Any])
         (< (cliff-priority a) (cliff-priority b)))))
    (define dir : (Option transport-directive)
      (cond
        [(eq? tr-sym 'warp-prism-phasing)
         (transport-directive tr-tag tr-sym 'morph-warp-prism-transport
                              'morph-warp-prism-transport MORPH-WARP-PRISM-TRANSPORT-ABILITY-ID
                              tr-tag '() tx ty 'cliff-ladder-unphase)]
        ;; If loaded & near cliff plateau (or full / no more nearby passengers), deliver & unload!
        [(and (> cargo-used 0)
              (or (null? ground-cands) (<= cargo-free 1) (<= d-dest 6.0)))
         (cond
           [(and (<= d-dest 2.2) dest-safe?)
            (when tr (transport-tracker-record-unload! tr tr-tag current-frame))
            (transport-directive tr-tag tr-sym 'transport-drop-point 'unload-all-at
                                 unload-ab 0 ptags dx-f dy-f 'cliff-ladder-unload)]
           [else
            (transport-directive tr-tag tr-sym 'move-to-drop 'move 16
                                 tr-tag ptags dx-f dy-f 'cliff-ladder-transit-plateau)])]
        ;; Empty or partially loaded with eligible ground allies waiting at `z_lo` -> scoop them!
        [(pair? ground-cands)
         (define u (car ground-cands))
         (define uid (u-tag u))
         (define ux (u-x u))
         (define uy (u-y u))
         (hash-set! claimed-units uid #t)
         (if (<= (dist-2d tx ty ux uy) p-range)
             (begin
               (when tr
                 (transport-tracker-record-pickup! tr tr-tag uid current-frame)
                 (transport-tracker-record-load! tr tr-tag current-frame))
               (transport-directive tr-tag tr-sym 'load-unit 'load-transport
                                    LOAD-TRANSPORT-ABILITY-ID uid (list uid) ux uy 'cliff-ladder-load))
             (transport-directive tr-tag tr-sym 'approach-save-pickup 'move 16
                                  uid (list uid) ux uy 'cliff-ladder-approach))]
        [else #f]))
    (if dir (cons dir acc) acc)))

;; Outnumbered Raid Squad Evacuation, Medivac Boost Escape & Base-to-Base Shield-Regen Rotation:
;; Handles all 3 races' drop raids (`archon-drop`, `bio-drop`, `widow-mine`, `ling-drop`, etc.)
;; when raiders are locally outnumbered (`< evac-ratio`), threatened by AA, or an Archon drops
;; below 45% shields / gets surrounded by `>= 4` melee units within `2.5t`.
(: plan-raid-evac-and-rotate
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real
         #:home-y Real
         #:enemy-targets (Listof (Pair Real Real))
         #:tracker (Option transport-tracker)
         #:current-frame Integer)
        (Listof transport-directive)))
(define (plan-raid-evac-and-rotate ally-units enemy-units
                                   #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                   #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                   #:enemy-targets [enemy-targets '()]
                                   #:tracker [tr #f]
                                   #:current-frame [current-frame 0])
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define transports : (Listof Any)
    (for/list : (Listof Any)
              ([a (in-list ally-units)]
               #:when (and (u-alive? a)
                           (> (u-tag a) 0)
                           (transport-unit-sym? (exact-unit-type a))
                           (> (dist-2d (u-x a) (u-y a) hx hy) 20.0)))
      a))
  (for/fold ([acc : (Listof transport-directive) '()] #:result (reverse acc))
            ([tr-u (in-list transports)])
    (define tr-tag (u-tag tr-u))
    (define tr-sym (exact-unit-type tr-u))
    (define tx (u-x tr-u))
    (define ty (u-y tr-u))
    (define cargo-used (u-cargo-space-taken tr-u))
    (define cargo-free (max 0 (- TRANSPORT-MAX-CARGO-CAPACITY cargo-used)))
    (define ptags (extract-passenger-tags tr-u))
    (define ptypes (extract-passenger-types tr-u))
    (define p-range (transport-pickup-range tr-sym))
    ;; Ground raid allies operating within `10.0t` of this transport (completed units ONLY — never incomplete warp-ins!)
    (define local-raiders : (Listof Any)
      (for/list : (Listof Any)
                ([a (in-list ally-units)]
                 #:when (and (u-alive? a)
                             (> (u-tag a) 0)
                             (u-completed? a)
                             (not (u-flying? a))
                             (not (u-structure? a))
                             (transport-race-accepts-unit? tr-sym (exact-unit-type a))
                             (<= (dist-2d tx ty (u-x a) (u-y a)) 10.0)))
        a))
    (define warping-under-tr? : Boolean
      (and (eq? tr-sym 'warp-prism-phasing)
           (for/or : Boolean ([a (in-list ally-units)])
             (and (u-alive? a) (not (u-flying? a)) (not (u-structure? a))
                  (not (u-completed? a))
                  (<= (dist-2d tx ty (u-x a) (u-y a)) 7.5)))))
    (define local-enemies : (Listof Any)
      (for/list : (Listof Any)
                ([e (in-list enemy-units)]
                 #:when (and (u-alive? e)
                             (> (u-tag e) 0)
                             (not (u-structure? e))
                             (not (memq (exact-unit-type e) '(scv probe drone mule larva egg overlord observer changeling)))
                             (<= (dist-2d tx ty (u-x e) (u-y e)) 11.5)))
        e))
    (define aa-cnt
      (for/sum : Integer ([e (in-list local-enemies)]
                          #:when (and (anti-air-defender-sym? (exact-unit-type e))
                                      (<= (dist-2d tx ty (u-x e) (u-y e)) 9.0)))
        1))
    (define all-raid-syms (append ptypes (map exact-unit-type local-raiders)))
    (define prof (infer-drop-profile tr-sym all-raid-syms))
    (define local-ally-pwr
      (for/fold ([s : Float 0.0]) ([a (in-list local-raiders)])
        (+ s (drop-unit-combat-power a))))
    (define local-enemy-pwr
      (for/fold ([s : Float 0.0]) ([e (in-list local-enemies)])
        (+ s (drop-unit-combat-power e))))
    ;; L59-P2 (`n05` fix): Archon shield-regen pickup ONLY when shields `< 25%` OR hull `< 60%`
    ;; (never yank winning Archons at `< 45%` shields mid-fight!)
    (define archon-evac-target : (Option Any)
      (for/or : (Option Any) ([a (in-list local-raiders)])
        (and (eq? (exact-unit-type a) 'archon)
             (let* ([sh (u-shield a 360.0)]
                    [msh (max 1.0 (u-max-shield a 360.0))]
                    [sh-rat (/ sh msh)]
                    [hp (u-hp a 10.0)]
                    [mhp (max 1.0 (u-max-hp a 10.0))]
                    [hp-rat (/ hp mhp)])
               (or (< sh-rat 0.25) (< hp-rat 0.60)))
             a)))
    ;; L59-P2 (`n18` fix): Banelings closing within `<= 6.5t` of ground Bio trigger immediate evac pickup!
    (define baneling-threat-near-raiders? : Boolean
      (and (pair? local-raiders)
           (for/or : Boolean ([e (in-list local-enemies)])
             (and (eq? (exact-unit-type e) 'baneling)
                  (for/or : Boolean ([r (in-list local-raiders)])
                    (<= (dist-2d (u-x e) (u-y e) (u-x r) (u-y r)) 6.5))))))
    (define outnumbered?
      (and (>= (length local-enemies) 2)
           (> local-enemy-pwr 0.0)
           (< local-ally-pwr (* (drop-profile-evac-ratio prof) local-enemy-pwr))))
    (define danger-evac?
      (or outnumbered?
          baneling-threat-near-raiders?
          (>= aa-cnt 3)
          (and (>= aa-cnt 2) (< (u-hp-ratio tr-u) 0.72))
          (< (u-hp-ratio tr-u) 0.50)
          (and archon-evac-target #t)))
    (define next-rotate-base : (Option (Pair Float Float))
      (and (drop-profile-rotate-base? prof)
           (>= (u-hp-ratio tr-u) 0.55)
           (for/or : (Option (Pair Float Float)) ([pt (in-list enemy-targets)])
             (define px (->float (car pt)))
             (define py (->float (cdr pt)))
             (and (>= (dist-2d tx ty px py) 18.0) (cons px py)))))
    (define dir : (Option transport-directive)
      (cond
        [(not danger-evac?) #f]
        ;; Priority 1: Scoop surviving raiders if cargo space remains!
        [(and (or archon-evac-target (pair? local-raiders)) (> cargo-free 0))
         (define pick-cand : (Option Any)
           (or (and archon-evac-target (<= (unit-cargo-size 'archon) cargo-free) archon-evac-target)
               (let ([fits (filter (lambda ([a : Any]) (<= (unit-cargo-size (exact-unit-type a)) cargo-free))
                                   local-raiders)])
                 (and (pair? fits)
                      (argmin (lambda ([a : Any]) (dist-2d tx ty (u-x a) (u-y a))) fits)))))
         (cond
           [(not pick-cand) #f]
           [(eq? tr-sym 'warp-prism-phasing)
            (if (and warping-under-tr? (>= (u-hp-ratio tr-u) 0.35))
                #f
                (transport-directive tr-tag tr-sym 'morph-warp-prism-transport
                                     'morph-warp-prism-transport MORPH-WARP-PRISM-TRANSPORT-ABILITY-ID
                                     tr-tag '() tx ty 'raid-evac-unphase))]
           [else
            (define uid (u-tag pick-cand))
            (define ux (u-x pick-cand))
            (define uy (u-y pick-cand))
            (if (<= (dist-2d tx ty ux uy) p-range)
                (begin
                  (when tr
                    (transport-tracker-record-pickup! tr tr-tag uid current-frame)
                    (transport-tracker-record-load! tr tr-tag current-frame))
                  (transport-directive tr-tag tr-sym 'load-unit 'load-transport
                                       LOAD-TRANSPORT-ABILITY-ID uid (list uid) ux uy
                                       (if archon-evac-target 'archon-shield-regen-pickup 'raid-evac-pickup)))
                (transport-directive tr-tag tr-sym 'approach-save-pickup 'move 16
                                     uid (list uid) ux uy 'raid-evac-approach))])]
        ;; Priority 2: Loaded with evacuated squad -> Boost / rotate to next base (Archon shield regen) or escape home!
        [(> cargo-used 0)
         (define dest-x (if next-rotate-base (car next-rotate-base) hx))
         (define dest-y (if next-rotate-base (cdr next-rotate-base) hy))
         (define reason (if next-rotate-base 'raid-rotate-next-base-regen 'raid-evac-escape-home))
         (define last-boost
           (if tr (hash-ref (transport-tracker-medivac-last-boost tr) tr-tag (lambda () -1000)) -1000))
         (if (and (eq? tr-sym 'medivac) (u-boost-ready? tr-u) (>= (- current-frame last-boost) 224))
             (begin
               (when tr (transport-tracker-record-boost! tr tr-tag current-frame))
               (transport-directive tr-tag tr-sym 'medivac-boost 'medivac-boost
                                    MEDIVAC-BOOST-ABILITY-ID tr-tag ptags dest-x dest-y 'raid-evac-medivac-boost))
             (transport-directive tr-tag tr-sym 'hold-and-reposition 'move 16
                                  tr-tag ptags dest-x dest-y reason))]
        [else #f]))
    (if dir (cons dir acc) acc)))

;; =============================================================================
;; 6. Unified Single-Transport, Fleet & S-Expression Orchestrator
;; =============================================================================

;; Evaluates one transport unit's highest-priority tactical action this frame:
;;   1) Carried cargo drop/hold (`<25%` dump, `672f` ceiling, `>=18f` drop vs hold),
;;   2) Combat save-pickup (`9.0`-tile scan, `5.0`/`1.5` pickup range, emergency unphase),
;;   3) WarpPrism phasing cycle (`140f`/`208f`/`160f`).
(: evaluate-transport-micro/zones
   (-> Any (Listof Any) (Listof Any) (Option transport-tracker) Integer Real Real
       (Listof danger-zone) Boolean Boolean Boolean
       (Option transport-directive)))
(define (evaluate-transport-micro/zones tr-u ally-units enemy-units
                                        tr current-frame home-x home-y
                                        zones prefer-moving-drop?
                                        warp-in-complete? warp-in-requested?)
  (or (evaluate-transport-drop/zones tr-u ally-units enemy-units
                                      tr current-frame home-x home-y
                                      #f #f zones prefer-moving-drop?)
      (evaluate-save-pickup/zones tr-u ally-units enemy-units
                                  tr current-frame zones)
      (and (memq (exact-unit-type tr-u) '(warp-prism warp-prism-phasing))
           ;; `evaluate-save-pickup/zones` just checked save targets; skip re-scanning on `#f`
           (evaluate-warp-prism-phasing/zones tr-u ally-units enemy-units
                                              tr current-frame zones
                                              warp-in-complete? warp-in-requested? #f))))

(: evaluate-transport-micro
   (->* (Any (Listof Any) (Listof Any))
        (#:tracker (Option transport-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:danger-zones (Listof danger-zone)
         #:effects (Listof Any)
         #:prefer-moving-drop? Boolean
         #:warp-in-complete? Boolean
         #:warp-in-requested? Boolean)
        (Option transport-directive)))
(define (evaluate-transport-micro tr-u ally-units enemy-units
                                  #:tracker [tr #f]
                                  #:current-frame [current-frame 0]
                                  #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                  #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                  #:danger-zones [explicit-zones '()]
                                  #:effects [effects '()]
                                  #:prefer-moving-drop? [prefer-moving-drop? #f]
                                  #:warp-in-complete? [warp-in-complete? #f]
                                  #:warp-in-requested? [warp-in-requested? #t])
  (define tr-sym (exact-unit-type tr-u))
  (cond
    [(or (not (u-alive? tr-u)) (not (transport-unit-sym? tr-sym))) #f]
    [else
     (define zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame)))
     (evaluate-transport-micro/zones tr-u ally-units enemy-units tr current-frame
                                     home-x home-y zones prefer-moving-drop?
                                     warp-in-complete? warp-in-requested?)]))

(: plan-transport-fleet-micro/synced
   (-> (Listof Any) (Listof Any) transport-tracker Integer Real Real
       (Listof danger-zone) (Listof Any) Boolean Boolean Boolean
       (U Boolean 'auto) (Option Real) (Option Integer)
       (Listof transport-directive)))
(define (plan-transport-fleet-micro/synced ally-units enemy-units tr current-frame
                                           home-x home-y explicit-zones effects
                                           prefer-moving-drop? warp-in-complete? warp-in-requested?
                                           kw-lair kw-supply kw-active)
  (define-values (transports has-overlord?)
    (for/fold ([trs : (Listof Any) '()]
               [has-ovi? : Boolean #f]
               #:result (values (reverse trs) has-ovi?))
              ([a (in-list ally-units)])
      (define ut (exact-unit-type a))
      (cond
        [(and (transport-unit-sym? ut) (u-alive? a))
         (values (cons a trs) has-ovi?)]
        [(and (eq? ut 'overlord) (not has-ovi?) (u-alive? a) (> (u-tag a) 0))
         (values trs #t)]
        [else (values trs has-ovi?)])))
  (define tr-dirs
    (if (null? transports)
        '()
        (let* ([zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame))]
               [e-recs (build-fleet-enemy-recs enemy-units)]
               [s-cands (parameterize ([current-fleet-enemy-recs e-recs])
                          (build-fleet-save-cands ally-units enemy-units zones))]
               [any-loaded?
                (for/or : Boolean ([t (in-list transports)])
                  (or (pair? (extract-passenger-tags t))
                      (> (u-cargo-space-taken t) 0)))]
               [shared-front (if any-loaded? (compute-ally-ground-anchor ally-units) #f)]
               [shared-safe
                (if shared-front
                    (parameterize ([current-fleet-enemy-recs e-recs])
                      (compute-safe-rear-drop-point
                       (car shared-front) (cdr shared-front)
                       home-x home-y zones enemy-units))
                    #f)])
          (parameterize ([current-fleet-enemy-recs e-recs]
                         [current-fleet-save-cands s-cands]
                         [current-fleet-front-xy shared-front]
                         [current-fleet-safe-drop shared-safe])
            (for/fold ([acc : (Listof transport-directive) '()]
                       [claimed : (Listof Integer) '()]
                       [tr-idx : Integer 0]
                       #:result (reverse acc))
                      ([a (in-list transports)])
              (define ax (u-x a))
              (define ay (u-y a))
              (define at-sym (exact-unit-type a))
              (define at-tag (u-tag a))
              (define a-cargo (u-cargo-space-taken a))
              ;; L59-P2 (`n14`/`n16` live hook): Detect cliff-laddering elevation split (`|ez - uz| >= 1.5`)
              ;; between nearby unclaimed ground allies (`<= 14t`) and visible ground enemies (`<= 20t`)!
              (define cliff-dir : (Option transport-directive)
                (let* ([near-gnd-allies
                        (for/list : (Listof Any)
                                  ([u (in-list ally-units)]
                                   #:when (and (u-alive? u) (not (u-flying? u)) (not (u-structure? u))
                                               (not (memv (u-tag u) claimed))
                                               (u-z u)
                                               (transport-race-accepts-unit? at-sym (exact-unit-type u))
                                               (<= (dist-2d ax ay (u-x u) (u-y u)) 14.0)))
                          u)]
                       [ref-z : (Option Float)
                        (if (pair? near-gnd-allies) (u-z (car near-gnd-allies)) #f)]
                       [uphill-enemies
                        (if (or ref-z (> a-cargo 0))
                            (for/list : (Listof Any)
                                      ([e (in-list enemy-units)]
                                       #:when (let ([ez (u-z e)])
                                                (and (u-alive? e) (not (u-flying? e)) (not (u-structure? e))
                                                     ez
                                                     (<= (dist-2d ax ay (u-x e) (u-y e)) 20.0)
                                                     (or (not ref-z) (>= (abs (- ez ref-z)) 1.5)))))
                              e)
                            '())])
                  (if (and (pair? uphill-enemies)
                           (or (pair? near-gnd-allies)
                               (and (> a-cargo 0)
                                    (let ([az-first (u-z (car uphill-enemies))])
                                      (and az-first
                                           (for/or : Boolean ([u (in-list ally-units)])
                                             (let ([uz (u-z u)])
                                               (and (not (u-flying? u)) uz (>= (abs (- az-first uz)) 1.5)))))))))
                      (let* ([ne (exact->inexact (length uphill-enemies))]
                             [ecx (/ (for/fold ([s : Float 0.0]) ([e (in-list uphill-enemies)]) (+ s (u-x e))) ne)]
                             [ecy (/ (for/fold ([s : Float 0.0]) ([e (in-list uphill-enemies)]) (+ s (u-y e))) ne)]
                             [ez-avg (/ (for/fold ([s : Float 0.0]) ([e (in-list uphill-enemies)]) (+ s (or (u-z e) 10.0))) ne)]
                             [dx (- ax ecx)]
                             [dy (- ay ecy)]
                             [dn (max 0.1 (dist-2d 0.0 0.0 dx dy))]
                             [ux (/ dx dn)]
                             [uy (/ dy dn)]
                             ;; Lateral stagger (`-1.2t` / `+1.2t`) so 2 transports drop 2 Tanks/Lurkers cleanly side-by-side
                             [lat (if (even? tr-idx) -1.2 1.2)]
                             ;; Land on high-ground cliff edge `3.2t` back from enemy cluster toward shuttle
                             [land-pt (clamp-playable-pt (+ ecx (* 3.2 ux) (* lat (- uy)))
                                                         (+ ecy (* 3.2 uy) (* lat ux)))]
                             [ldirs (plan-cliff-ladder-shuttle
                                     (cons a near-gnd-allies) enemy-units
                                     #:dest-x (point2d-x land-pt) #:dest-y (point2d-y land-pt)
                                     #:dest-z ez-avg #:danger-zones zones
                                     #:tracker tr #:current-frame current-frame)])
                        (and (pair? ldirs) (car ldirs)))
                      #f)))
              ;; L59-P2 (`n18`/`n05` live hook): Run active raid evac BEFORE re-drop when ground raiders
              ;; are present (`pair? near-raiders`) OR this transport JUST scooped raiders (`recent-load?`),
              ;; while frame-0 pre-loaded mineral drops (`null? near-raiders` & no prior load) run drop-in first!
              (define near-raiders : (Listof Any)
                (for/list : (Listof Any)
                          ([u (in-list ally-units)]
                           #:when (and (u-alive? u) (not (u-flying? u)) (not (u-structure? u))
                                       (not (memv (u-tag u) claimed))
                                       (transport-race-accepts-unit? at-sym (exact-unit-type u))
                                       (<= (dist-2d ax ay (u-x u) (u-y u)) 10.5)))
                  u))
              ;; L59-P2 (`n18`/`n05` live hook): Run active raid evac BEFORE re-drop ONLY during genuine
              ;; behind-enemy-lines raids (`>= 3` enemy workers within `22t`, OR Baneling rush, OR
              ;; WarpPrism Archon juggle) — never hijacking open-field frontline healing Medivacs
              ;; (`w10-tac-1`/`w10-tac-3`/`w11-tac-5`), and never overriding `< 25% HP` emergency cargo dump!
              (define raid-context? : Boolean
                (or (>= (for/sum : Integer ([e (in-list enemy-units)]
                                            #:when (and (u-alive? e)
                                                        (memq (exact-unit-type e) '(scv probe drone))
                                                        (<= (dist-2d ax ay (u-x e) (u-y e)) 22.0)))
                          1)
                        3)
                    (and (memq at-sym '(warp-prism warp-prism-phasing))
                         (for/or : Boolean ([u (in-list near-raiders)])
                           (eq? (exact-unit-type u) 'archon)))))
              (define emergency-dump-needed? : Boolean
                (and (> a-cargo 0) (< (u-hp-ratio a) 0.25)))
              (define recent-load? : Boolean
                (let ([last-l (hash-ref (transport-tracker-transport-last-load tr) at-tag (lambda () #f))])
                  (and last-l (<= (- current-frame last-l) 240))))
              (define active-evac-dir : (Option transport-directive)
                (if (and (not cliff-dir)
                         (not emergency-dump-needed?)
                         raid-context?
                         (or (pair? near-raiders)
                             (and (> a-cargo 0) recent-load?)))
                    (let ([edirs (plan-raid-evac-and-rotate
                                  (cons a near-raiders)
                                  enemy-units
                                  #:home-x home-x #:home-y home-y
                                  #:tracker tr #:current-frame current-frame)])
                      (and (pair? edirs) (car edirs)))
                    #f))
              (define d
                (or cliff-dir
                    active-evac-dir
                    (evaluate-transport-micro/zones a ally-units enemy-units
                                                    tr current-frame home-x home-y
                                                    zones prefer-moving-drop?
                                                    warp-in-complete? warp-in-requested?)))
              (define next-claimed : (Listof Integer)
                (if (and d
                         (memq (transport-directive-action d) '(load-unit approach-save-pickup))
                         (> (transport-directive-target-tag d) 0))
                    (cons (transport-directive-target-tag d) claimed)
                    claimed))
              (values (if d (cons d acc) acc) next-claimed (+ tr-idx 1)))))))
  (define ovi-dirs
    (if has-overlord?
        (plan-overlord-transport-morphs ally-units enemy-units
                                        #:lair-or-hive-ready? kw-lair
                                        #:combat-supply kw-supply
                                        #:active-dropperlords kw-active)
        '()))
  (if (null? ovi-dirs) tr-dirs (append tr-dirs ovi-dirs)))

;; Plans tactical micro directives across all friendly transports (plus eligible Overlord morph).
(: plan-transport-fleet-micro
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option transport-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:danger-zones (Listof danger-zone)
         #:effects (Listof Any)
         #:prefer-moving-drop? Boolean
         #:warp-in-complete? Boolean
         #:warp-in-requested? Boolean
         #:lair-or-hive-ready? (U Boolean 'auto)
         #:combat-supply (Option Real)
         #:active-dropperlords (Option Integer))
        (Listof transport-directive)))
(define (plan-transport-fleet-micro ally-units enemy-units
                                    #:tracker [tr-arg #f]
                                    #:current-frame [current-frame 0]
                                    #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                    #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                    #:danger-zones [explicit-zones '()]
                                    #:effects [effects '()]
                                    #:prefer-moving-drop? [prefer-moving-drop? #f]
                                    #:warp-in-complete? [warp-in-complete? #f]
                                    #:warp-in-requested? [warp-in-requested? #t]
                                    #:lair-or-hive-ready? [kw-lair 'auto]
                                    #:combat-supply [kw-supply #f]
                                    #:active-dropperlords [kw-active #f])
  (define tr (or tr-arg (make-transport-tracker)))
  (sync-transport-tracker! tr ally-units current-frame)
  (plan-transport-fleet-micro/synced ally-units enemy-units tr current-frame
                                     home-x home-y explicit-zones effects
                                     prefer-moving-drop? warp-in-complete? warp-in-requested?
                                     kw-lair kw-supply kw-active))

;; Converts a `transport-directive` into a runtime-compatible S-expression command.
(: transport-directive->sexp (-> transport-directive (Listof Any)))
(define (transport-directive->sexp d)
  (define tr-tag (transport-directive-transport-tag d))
  (case (transport-directive-action d)
    [(transport-drop-moving)
     (list 'transport-drop-moving tr-tag tr-tag)]
    [(transport-drop-point)
     (list 'transport-juggle tr-tag (transport-directive-tx d) (transport-directive-ty d))]
    [(load-unit)
     (list 'transport-juggle
           tr-tag
           (transport-directive-passenger-tags d)
           (transport-directive-tx d)
           (transport-directive-ty d))]
    [(approach-save-pickup hold-and-reposition move-to-drop)
     (list 'move tr-tag (transport-directive-tx d) (transport-directive-ty d))]
    [(medivac-boost morph-warp-prism-phasing morph-warp-prism-transport cast-spell)
     (list 'cast-spell
           tr-tag
           (or (transport-directive-ability d) 'unknown)
           tr-tag)]
    [else
     (list 'move tr-tag (transport-directive-tx d) (transport-directive-ty d))]))

;; Executes one transport micro frame across fleet + Dropperlord eligibility and emits S-exps.
(: step-transport-drop-micro!
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option transport-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:danger-zones (Listof danger-zone)
         #:effects (Listof Any)
         #:prefer-moving-drop? Boolean
         #:warp-in-complete? Boolean
         #:warp-in-requested? Boolean
         #:dead-tags (Listof Integer)
         #:lair-or-hive-ready? (U Boolean 'auto)
         #:combat-supply (Option Real)
         #:active-dropperlords (Option Integer))
        (Listof (Listof Any))))
(define (step-transport-drop-micro! ally-units enemy-units
                                    #:tracker [tr-arg #f]
                                    #:current-frame [current-frame 0]
                                    #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                    #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                    #:danger-zones [explicit-zones '()]
                                    #:effects [effects '()]
                                    #:prefer-moving-drop? [prefer-moving-drop? #f]
                                    #:warp-in-complete? [warp-in-complete? #f]
                                    #:warp-in-requested? [warp-in-requested? #t]
                                    #:dead-tags [dead-tags '()]
                                    #:lair-or-hive-ready? [kw-lair 'auto]
                                    #:combat-supply [kw-supply #f]
                                    #:active-dropperlords [kw-active #f])
  (define tr (or tr-arg (make-transport-tracker)))
  (sync-transport-tracker! tr ally-units current-frame #:dead-tags dead-tags)
  (map transport-directive->sexp
       (plan-transport-fleet-micro/synced ally-units enemy-units tr current-frame
                                          home-x home-y explicit-zones effects
                                          prefer-moving-drop? warp-in-complete? warp-in-requested?
                                          kw-lair kw-supply kw-active)))
