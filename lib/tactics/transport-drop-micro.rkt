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
 transport-tracker-record-pickup!
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
(define SAVE-BRUISED-HP-RATIO 0.42)

(: SAVE-UNDER-FIRE-HP-RATIO Float)
(define SAVE-UNDER-FIRE-HP-RATIO 0.55)

(: SAVE-HIGH-VALUE-SYMS (Listof Symbol))
(define SAVE-HIGH-VALUE-SYMS
  '(immortal archon colossus high-templar disruptor siege-tank thor thor-ap
    cyclone ghost marauder lurker ravager roach hydralisk queen infestor))

;; Drop & Emergency Dump Constants
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

;; WarpPrism Phasing Constants (`#115` empirical dwells)
(: WARP-PRISM-MIN-PHASING-DWELL-FRAMES Integer)
(define WARP-PRISM-MIN-PHASING-DWELL-FRAMES 140)

(: WARP-PRISM-TARGET-WARP-CYCLE-FRAMES Integer)
(define WARP-PRISM-TARGET-WARP-CYCLE-FRAMES 208)

(: WARP-PRISM-REPHASE-COOLDOWN-FRAMES Integer)
(define WARP-PRISM-REPHASE-COOLDOWN-FRAMES 160)

(: WARP-PRISM-THREAT-UNPHASE-RADIUS Float)
(define WARP-PRISM-THREAT-UNPHASE-RADIUS 10.0)

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
   [prism-phases : (Mutable-HashTable Integer prism-phase-rec)]))

;; Creates a fresh empty `transport-tracker`.
(: make-transport-tracker (-> transport-tracker))
(define (make-transport-tracker)
  (transport-tracker
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)))

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
      (hash-set! c-tbl tr-tag current-frame))))

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
     (define raw-ut
       (cond
         [(dyn-hash-has-key? u 'unit-type) (dyn-hash-ref u 'unit-type #f)]
         [(dyn-hash-has-key? u 'unit_type) (dyn-hash-ref u 'unit_type #f)]
         [(dyn-hash-has-key? u 'type)      (dyn-hash-ref u 'type #f)]
         [else #f]))
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
     (define t (dyn-hash-ref u 'tag #f))
     (if (exact-integer? t)
         t
         (safe-exact-int (dyn-hash-ref u 'id 0) 0))]
    [else 0]))

(: u-x (-> Any Float))
(define (u-x u)
  (if (transport-unit-input? u)
      (transport-unit-input-x u)
      (safe-finite-real (dyn-hash-ref u 'x 0.0) 0.0)))

(: u-y (-> Any Float))
(define (u-y u)
  (if (transport-unit-input? u)
      (transport-unit-input-y u)
      (safe-finite-real (dyn-hash-ref u 'y 0.0) 0.0)))

(: u-hp (-> Any Float Float))
(define (u-hp u default)
  (cond
    [(transport-unit-input? u) (max 0.0 (transport-unit-input-hp u))]
    [(dyn-hash-has-key? u 'hp) (max 0.0 (safe-finite-real (dyn-hash-ref u 'hp default) default))]
    [(dyn-hash-has-key? u 'health) (max 0.0 (safe-finite-real (dyn-hash-ref u 'health default) default))]
    [else default]))

(: u-max-hp (-> Any Float Float))
(define (u-max-hp u default)
  (cond
    [(transport-unit-input? u) (max 1.0 (transport-unit-input-max-hp u))]
    [(dyn-hash-has-key? u 'max-hp) (max 1.0 (safe-finite-real (dyn-hash-ref u 'max-hp default) default))]
    [(dyn-hash-has-key? u 'health-max) (max 1.0 (safe-finite-real (dyn-hash-ref u 'health-max default) default))]
    [else
     (define stats (sc2-unit-combat-stats (exact-unit-type u)))
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
     (define stats (sc2-unit-combat-stats (exact-unit-type u)))
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
     (define stats (sc2-unit-combat-stats ut))
     (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
     (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
     (+ (u-hp u def-hp) (u-shield u def-sh))]))

(: u-hp-ratio (-> Any Float))
(define (u-hp-ratio u)
  (define ut (exact-unit-type u))
  (define stats (sc2-unit-combat-stats ut))
  (define def-hp (safe-finite-real (hash-ref stats 'max-hp (lambda () 100.0)) 100.0))
  (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
  (define cur (u-total-ehp u))
  (define tot
    (cond
      [(transport-unit-input? u)
       (max 1.0 (+ (max 1.0 (transport-unit-input-max-hp u))
                   (max 0.0 (transport-unit-input-max-shield u))))]
      [(dyn-hash-has-key? u 'hull-hp)
       (if (or (dyn-hash-has-key? u 'max-hp)
               (dyn-hash-has-key? u 'health-max))
           (max 1.0 (u-max-hp u (+ def-hp def-sh)))
           (max 1.0 (+ def-hp def-sh)))]
      [else
       (max 1.0 (+ (u-max-hp u def-hp) (u-max-shield u def-sh)))]))
  (clamp-prob (/ cur tot)))

(: u-alive? (-> Any Boolean))
(define (u-alive? u)
  (cond
    [(transport-unit-input? u) (> (+ (transport-unit-input-hp u) (transport-unit-input-shield u)) 0.0)]
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
  (define stats (sc2-unit-combat-stats ut))
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
    [(siege-tank cyclone immortal archon disruptor lurker) 4]
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
                             lurker infestor queen ultralisk))))]
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

  (for ([a (in-list ally-units)]
        #:when (u-alive? a))
    (define tag (u-tag a))
    (define ut (exact-unit-type a))
    (when (and (> tag 0) (transport-unit-sym? ut))
      (define ptags (extract-passenger-tags a))
      (define cargo-used (u-cargo-space-taken a))
      (for ([ptag (in-list ptags)])
        (hash-set! active-passengers ptag #t)
        (unless (hash-has-key? p-tbl ptag)
          (hash-set! p-tbl ptag current-frame)))
      (if (or (pair? ptags) (> cargo-used 0))
          (unless (hash-has-key? c-tbl tag)
            (define earliest-p
              (for/fold ([best : Integer current-frame]) ([pt (in-list ptags)])
                (min best (hash-ref p-tbl pt (lambda () current-frame)))))
            (hash-set! c-tbl tag earliest-p))
          (hash-remove! c-tbl tag))
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
                      (prism-phase-rec (prism-phase-rec-phase-start-frame prev) current-frame #f))]))))

  ;; Remove unloaded/dead passengers from pickup table & dead transports from tracker tables
  (define stale-p
    (for/list : (Listof Integer) ([pt (in-hash-keys p-tbl)]
                                  #:when (or (not (hash-has-key? active-passengers pt))
                                             (memv pt dead-tags)))
      pt))
  (for ([pt (in-list stale-p)])
    (hash-remove! p-tbl pt))
  (for ([dt (in-list dead-tags)])
    (hash-remove! c-tbl dt)
    (hash-remove! phase-tbl dt)
    (hash-remove! boost-tbl dt)))

;; =============================================================================
;; Active Danger Zones & Threat Inspection
;; =============================================================================

;; Extracts active Nova/Bile/Storm/Cloud danger zones from enemy units and effects list.
(: collect-active-danger-zones (-> (Listof Any) (Listof Any) Integer (Listof danger-zone)))
(define (collect-active-danger-zones enemy-units effects current-frame)
  (define from-novas
    (for/fold ([acc : (Listof danger-zone) '()]) ([e (in-list enemy-units)])
      (if (and (u-alive? e) (eq? (exact-unit-type e) 'disruptor-phased))
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

;; Counts living enemy attackers currently within effective weapon reach of unit `u`.
(: count-attackers-in-range (-> Any (Listof Any) Integer))
(define (count-attackers-in-range u enemy-units)
  (define ux (u-x u))
  (define uy (u-y u))
  (define u-air? (u-flying? u))
  (for/sum : Integer ([e (in-list enemy-units)]
                      #:when (u-alive? e))
    (define et (exact-unit-type e))
    (define stats (sc2-unit-combat-stats et))
    (define dps-key (if u-air? 'air-dps 'ground-dps))
    (define rng-key (if u-air? 'air-range 'ground-range))
    (define dps (safe-finite-real (hash-ref stats dps-key (lambda () 0.0)) 0.0))
    (define rng (safe-finite-real (hash-ref stats rng-key (lambda () 0.0)) 0.0))
    (define d (dist-2d ux uy (u-x e) (u-y e)))
    (if (and (> dps 0.0) (<= d (+ (max 1.5 rng) 0.75))) 1 0)))

(: nearest-enemy-combat-dist (-> Real Real (Listof Any) Float))
(define (nearest-enemy-combat-dist x y enemy-units)
  (define fx (->float x))
  (define fy (->float y))
  (for/fold ([best : Float +inf.0]) ([e (in-list enemy-units)]
                                     #:when (u-alive? e))
    (define et (exact-unit-type e))
    (if (memq et '(larva egg observer overlord changeling))
        best
        (min best (dist-2d fx fy (u-x e) (u-y e))))))

;; =============================================================================
;; 1. Combat Save-Pickup Priority & Execution
;; =============================================================================

;; Scores a friendly unit's save-pickup urgency (<= 0.0 if rescue is not warranted).
(: save-pickup-candidate-priority
   (-> Symbol Any (Listof Any) (Listof danger-zone) Integer Float))
(define (save-pickup-candidate-priority tr-sym ally-u enemy-units zones cargo-free)
  (define ut (exact-unit-type ally-u))
  (define sz (unit-cargo-size ut))
  (cond
    [(or (not (u-alive? ally-u))
         (u-flying? ally-u)
         (u-structure? ally-u)
         (> sz cargo-free)
         (not (transport-race-accepts-unit? tr-sym ut))
         (memq ut '(siege-tank-sieged lurker-burrowed larva egg)))
     0.0]
    [else
     (define ux (u-x ally-u))
     (define uy (u-y ally-u))
     (define in-aoe? (point-in-danger-zones? ux uy zones 0.35))
     (define hp-rat (u-hp-ratio ally-u))
     (define attackers (count-attackers-in-range ally-u enemy-units))
     (define disruptor-cd-danger?
       (and (eq? ut 'disruptor)
            (not (u-nova-ready? ally-u))
            (<= (nearest-enemy-combat-dist ux uy enemy-units) 9.0)))
     (define high-val? (not (not (memq ut SAVE-HIGH-VALUE-SYMS))))
     (define bruised?
       (and high-val?
            (or (< hp-rat SAVE-BRUISED-HP-RATIO)
                (and (< hp-rat SAVE-UNDER-FIRE-HP-RATIO) (>= attackers 2)))))
     (cond
       [(or in-aoe? disruptor-cd-danger? bruised?)
        (define value-bonus
          (exact->inexact (max 50 (+ (sc2-min-cost ut) (sc2-gas-cost ut)))))
        (+ (if in-aoe? 1500.0 0.0)
           (if disruptor-cd-danger? 1100.0 0.0)
           (if bruised? (* 900.0 (- 1.0 hp-rat)) 0.0)
           (* 0.5 value-bonus))]
       [else 0.0])]))

(: find-save-pickup-target
   (-> Any Symbol (Listof Any) (Listof Any) (Listof danger-zone) (Values (Option Any) Symbol)))
(define (find-save-pickup-target tr-u tr-sym ally-units enemy-units zones)
  (define tx (u-x tr-u))
  (define ty (u-y tr-u))
  (define tr-tag (u-tag tr-u))
  (define cargo-used (u-cargo-space-taken tr-u))
  (define cargo-free (max 0 (- TRANSPORT-MAX-CARGO-CAPACITY cargo-used)))
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
            (memv atag carried-tags)
            (> (dist-2d tx ty (u-x a) (u-y a)) TRANSPORT-SAVE-SEARCH-RADIUS))
        (values best best-sc)
        (let ([sc (save-pickup-candidate-priority tr-sym a enemy-units zones cargo-free)])
          (if (> sc best-sc)
              (values a sc)
              (values best best-sc))))))

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
  (define tr-tag (u-tag tr-u))
  (cond
    [(or (not (u-alive? tr-u)) (not (transport-unit-sym? tr-sym))) #f]
    [else
     (define zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame)))
     (define-values (victim reason) (find-save-pickup-target tr-u tr-sym ally-units enemy-units zones))
     (cond
       [(not victim) #f]
       [(eq? tr-sym 'warp-prism-phasing)
        ;; Unphase immediately so WarpPrism becomes mobile for save-pickup/escape
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
                             'warp-prism-unphase-emergency-save)]
       [else
        (define vtag (u-tag victim))
        (define vx (u-x victim))
        (define vy (u-y victim))
        (define d (dist-2d (u-x tr-u) (u-y tr-u) vx vy))
        (define p-range (transport-pickup-range tr-sym))
        (cond
          [(<= d p-range)
           (when tr
             (transport-tracker-record-pickup! tr tr-tag vtag current-frame))
           (transport-directive tr-tag tr-sym 'load-unit 'load-transport
                                LOAD-TRANSPORT-ABILITY-ID vtag (list vtag) vx vy reason)]
          [else
           (transport-directive tr-tag tr-sym 'approach-save-pickup 'move
                                16 vtag (list vtag) vx vy reason)])])]))

;; =============================================================================
;; 2. Safe Rear-Offset Drop, Pro Moving Self-Drop (`#115`) & 672f Ceiling
;; =============================================================================

(: compute-ally-front-anchor (-> (Listof Any) (Listof Any) Real Real (Values Float Float)))
(define (compute-ally-front-anchor ally-units enemy-units fallback-x fallback-y)
  (define-values (ecount ex-sum ey-sum)
    (for/fold ([n : Integer 0] [sx : Float 0.0] [sy : Float 0.0])
              ([e (in-list enemy-units)] #:when (u-alive? e))
      (values (add1 n) (+ sx (u-x e)) (+ sy (u-y e)))))
  (define-values (ecx ecy)
    (if (> ecount 0)
        (values (/ ex-sum (->float ecount)) (/ ey-sum (->float ecount)))
        (values (+ (->float fallback-x) 40.0) (+ (->float fallback-y) 40.0))))
  ;; Pick friendly combat centroid weighted or nearest ground combat front if available
  (define-values (acount ax-sum ay-sum)
    (for/fold ([n : Integer 0] [sx : Float 0.0] [sy : Float 0.0])
              ([a (in-list ally-units)]
               #:when (and (u-alive? a)
                           (not (u-flying? a))
                           (not (u-structure? a))
                           (not (transport-unit-sym? (exact-unit-type a)))))
      (values (add1 n) (+ sx (u-x a)) (+ sy (u-y a)))))
  (if (> acount 0)
      (values (/ ax-sum (->float acount)) (/ ay-sum (->float acount)))
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
         #:prefer-moving-drop? Boolean)
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
                                 #:prefer-moving-drop? [prefer-moving-drop? #f])
  (define tr-sym (exact-unit-type tr-u))
  (define tr-tag (u-tag tr-u))
  (define ptags (extract-passenger-tags tr-u))
  (define cargo-used (u-cargo-space-taken tr-u))
  (cond
    [(or (not (u-alive? tr-u))
         (not (transport-unit-sym? tr-sym))
         (and (null? ptags) (<= cargo-used 0)))
     #f]
    [else
     (define tx (u-x tr-u))
     (define ty (u-y tr-u))
     (define hp-rat (u-hp-ratio tr-u))
     (define zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame)))
     (define ground-ok? (u-ground-safe? tr-u))
     (define pos-safe? (and ground-ok? (not (point-in-danger-zones? tx ty zones 0.35))))
     (define carry-dwell
       (if tr
           (transport-tracker-carry-dwell-frames tr tr-tag ptags current-frame)
           MIN-CARRY-DWELL-FRAMES))
     (define-values (fx0 fy0) (compute-ally-front-anchor ally-units enemy-units tx ty))
     (define front-x (if front-x-arg (->float front-x-arg) fx0))
     (define front-y (if front-y-arg (->float front-y-arg) fy0))
     (define safe-pt (compute-safe-rear-drop-point front-x front-y home-x home-y zones enemy-units))
     (define sx (point2d-x safe-pt))
     (define sy (point2d-y safe-pt))
     (define unload-ab-id (transport-unload-ability-id tr-sym))

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

     (cond
       ;; 1. `< 25%` HP+shields emergency dump immediately
       [(< hp-rat EMERGENCY-DUMP-HP-RATIO)
        (if pos-safe?
            (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                                 unload-ab-id tr-tag ptags tx ty 'emergency-low-hp-dump)
            (transport-directive tr-tag tr-sym 'transport-drop-point 'unload-all-at
                                 unload-ab-id 0 ptags sx sy 'emergency-low-hp-offset-dump))]

       ;; 2. `672f` (30s) stuck-cargo safety unload ceiling
       [(>= carry-dwell STUCK-CARGO-CEILING-FRAMES)
        (if pos-safe?
            (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                                 unload-ab-id tr-tag ptags tx ty 'stuck-cargo-ceiling-672f)
            (transport-directive tr-tag tr-sym 'transport-drop-point 'unload-all-at
                                 unload-ab-id 0 ptags sx sy 'stuck-cargo-ceiling-offset-672f))]

       ;; 3. `< 18f` carry dwell -> protect cargo while repositioning away from focus-fire
       [(< carry-dwell MIN-CARRY-DWELL-FRAMES)
        (if (and boost-available? (> (dist-2d tx ty sx sy) 4.0))
            (begin
              (when tr (transport-tracker-record-boost! tr tr-tag current-frame))
              (transport-directive tr-tag tr-sym 'medivac-boost 'medivac-boost
                                   MEDIVAC-BOOST-ABILITY-ID tr-tag ptags sx sy 'medivac-boost-escape-hold))
            (transport-directive tr-tag tr-sym 'hold-and-reposition 'move
                                 16 tr-tag ptags sx sy 'carry-dwell-protect-hold))]

       ;; 4. `>= 18f` Medivac Boost -> Unload `16f-36f` moving self-drop cadence
       [(and in-boost-unload-window? pos-safe?)
        (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                             unload-ab-id tr-tag ptags tx ty 'medivac-boost-moving-self-drop)]

       ;; 5. Active moving self-drop (`'transport-drop-moving` targeting transport's own tag)
       [(and pos-safe?
             (or prefer-moving-drop? (u-moving? tr-u))
             (<= (dist-2d tx ty sx sy) 6.5))
        (transport-directive tr-tag tr-sym 'transport-drop-moving 'transport-drop-moving
                             unload-ab-id tr-tag ptags tx ty 'transport-moving-self-drop)]

       ;; 6. Arrived at safe rear-offset drop point `[3.5..5.0]` outside AoE zones
       [(<= (dist-2d tx ty sx sy) 3.0)
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

;; =============================================================================
;; 3. WarpPrism Phasing Management (`1528` <-> `1530`)
;; =============================================================================

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
     (define zones (append explicit-zones (collect-active-danger-zones enemy-units effects current-frame)))
     (define near-enemy-d (nearest-enemy-combat-dist px py enemy-units))
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
     (define army-dist (if has-army? (dist-2d px py acx acy) 0.0))
     (define-values (emergency-victim _why)
       (find-save-pickup-target prism-u ut ally-units enemy-units zones))
     (define phase-tbl (and tr (transport-tracker-prism-phases tr)))

     (cond
       [is-phasing?
        (define phase-dwell
          (if tr (transport-tracker-prism-phase-dwell tr tag current-frame) WARP-PRISM-TARGET-WARP-CYCLE-FRAMES))
        (define immediate-reason : (Option Symbol)
          (cond
            [emergency-victim                               'warp-prism-unphase-emergency-save]
            [(< hp-rat WARP-PRISM-UNPHASE-HP-RATIO)         'warp-prism-unphase-low-hp]
            [(< near-enemy-d WARP-PRISM-THREAT-UNPHASE-RADIUS) 'warp-prism-unphase-threat-close]
            [(and has-army? (> army-dist WARP-PRISM-ARMY-LEASH-RADIUS))
             'warp-prism-unphase-army-far]
            [else #f]))
        (define cycle-reason : (Option Symbol)
          (cond
            [immediate-reason immediate-reason]
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
        (define safe-to-phase?
          (and cargo-empty?
               (not emergency-victim)
               (zero? rephase-cd)
               (>= hp-rat WARP-PRISM-UNPHASE-HP-RATIO)
               (>= near-enemy-d WARP-PRISM-THREAT-UNPHASE-RADIUS)
               (not (point-in-danger-zones? px py zones 0.75))
               (or warp-in-requested? (and has-army? (<= army-dist WARP-PRISM-ARMY-LEASH-RADIUS)))))
        (if safe-to-phase?
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
            #f)])]))

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
    [else
     (define lair-ok?
       (if (eq? kw-lair 'auto)
           (for/or : Boolean ([a (in-list ally-or-lair)])
             (and (u-alive? a)
                  (memq (exact-unit-type a) '(lair hive))
                  (u-completed? a)))
           (not (not kw-lair))))
     (define sup
       (or kw-supply pos-supply (overlord-drop-combat-supply ally-or-lair)))
     (define act
       (or kw-active
           pos-active
           (for/sum : Integer ([a (in-list ally-or-lair)]
                               #:when (and (u-alive? a)
                                           (memq (exact-unit-type a)
                                                 '(overlord-transport transport-overlord-cocoon))))
             1)))
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
  (if (not (should-morph-overlord-transport? ally-units
                                             #:lair-or-hive-ready? kw-lair
                                             #:combat-supply kw-supply
                                             #:active-dropperlords kw-active))
      '()
      (let ([best-ovi
             (for/fold ([best : (Option Any) #f]
                        [best-safe : Float -1.0]
                        #:result best)
                       ([a (in-list ally-units)]
                        #:when (and (u-alive? a)
                                    (eq? (exact-unit-type a) 'overlord)
                                    (> (u-tag a) 0)))
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
            '()))))

;; =============================================================================
;; 5. Unified Single-Transport, Fleet & S-Expression Orchestrator
;; =============================================================================

;; Evaluates one transport unit's highest-priority tactical action this frame:
;;   1) Carried cargo drop/hold (`<25%` dump, `672f` ceiling, `>=18f` drop vs hold),
;;   2) Combat save-pickup (`9.0`-tile scan, `5.0`/`1.5` pickup range, emergency unphase),
;;   3) WarpPrism phasing cycle (`140f`/`208f`/`160f`).
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
  (or (evaluate-transport-drop tr-u ally-units enemy-units
                               #:tracker tr
                               #:current-frame current-frame
                               #:home-x home-x
                               #:home-y home-y
                               #:danger-zones explicit-zones
                               #:effects effects
                               #:prefer-moving-drop? prefer-moving-drop?)
      (evaluate-save-pickup tr-u ally-units enemy-units
                            #:tracker tr
                            #:current-frame current-frame
                            #:danger-zones explicit-zones
                            #:effects effects)
      (and (memq (exact-unit-type tr-u) '(warp-prism warp-prism-phasing))
           (evaluate-warp-prism-phasing tr-u ally-units enemy-units
                                        #:tracker tr
                                        #:current-frame current-frame
                                        #:danger-zones explicit-zones
                                        #:effects effects
                                        #:warp-in-complete? warp-in-complete?
                                        #:warp-in-requested? warp-in-requested?))))

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
  (define tr-dirs
    (for/fold ([acc : (Listof transport-directive) '()] #:result (reverse acc))
              ([a (in-list ally-units)]
               #:when (and (u-alive? a) (transport-unit-sym? (exact-unit-type a))))
      (define d (evaluate-transport-micro a ally-units enemy-units
                                          #:tracker tr
                                          #:current-frame current-frame
                                          #:home-x home-x
                                          #:home-y home-y
                                          #:danger-zones explicit-zones
                                          #:effects effects
                                          #:prefer-moving-drop? prefer-moving-drop?
                                          #:warp-in-complete? warp-in-complete?
                                          #:warp-in-requested? warp-in-requested?))
      (if d (cons d acc) acc)))
  (define ovi-dirs
    (plan-overlord-transport-morphs ally-units enemy-units
                                    #:lair-or-hive-ready? kw-lair
                                    #:combat-supply kw-supply
                                    #:active-dropperlords kw-active))
  (append tr-dirs ovi-dirs))

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
       (plan-transport-fleet-micro ally-units enemy-units
                                   #:tracker tr
                                   #:current-frame current-frame
                                   #:home-x home-x
                                   #:home-y home-y
                                   #:danger-zones explicit-zones
                                   #:effects effects
                                   #:prefer-moving-drop? prefer-moving-drop?
                                   #:warp-in-complete? warp-in-complete?
                                   #:warp-in-requested? warp-in-requested?
                                   #:lair-or-hive-ready? kw-lair
                                   #:combat-supply kw-supply
                                   #:active-dropperlords kw-active)))
