#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/disruptor-micro.rkt`
;; Protoss Disruptor (`694`) & Purification Nova (`733` / Ability `2346`)
;; Comprehensive Offensive & Defensive Micro Module (Typed Racket):
;;
;; Offensive Micro:
;;   - `plan-disruptor-nova-casts`     : Ground-cluster optimization, 145 (+55 shield)
;;                                       splash scoring, 2.0x friendly-fire guard,
;;                                       min-value gate, reach clamp, >= 4.0-tile
;;                                       volley de-confliction across casters/Novas
;;   - `steer-purification-novas`      : Per-step homing for friendly `DisruptorPhased`
;;                                       (`733`) projectiles onto best reachable
;;                                       enemy ground cluster (with anti-FF escape)
;;   - `kite-disruptor-casters`        : Weaponless standoff (10.5-12.0 ready) &
;;                                       cooldown retreat (13.0-15.0 behind army),
;;                                       never emitting `attack-unit` / `attack-move`
;;
;; Defensive & Counter-Play Micro:
;;   - `purification-nova-unit?`       : Invulnerable `disruptor-phased` (`733`) guard
;;   - `plan-anti-nova-scatter`        : Velocity-ray + radial/perpendicular split
;;                                       (danger <= 6.5 / corridor <= 9.5), any-HP
;;                                       emergency Stalker Blink (< 2.75 tiles),
;;                                       and pre-split spacing near ready casters
;;   - `evaluate-disruptor-snipe-and-cooldowns`
;;                                     : Enemy Disruptor 480-frame cooldown tracking
;;                                       & lethal active-cast fizzle-snipe scoring
;;   - `step-disruptor-tactical-micro!`: Unified per-frame orchestrator emitting
;;                                       S-expression tactical orders
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-geometry.rkt"
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

;; Safe bridge for inspecting heterogeneous untyped/mutable/immutable unit hashes.
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
 ;; LotV Disruptor & Purification Nova constants
 DISRUPTOR-UNIT-TYPE-ID
 DISRUPTOR-PHASED-UNIT-TYPE-ID
 PURIFICATION-NOVA-ABILITY-ID
 DISRUPTOR-NOVA-SPLASH-RADIUS
 DISRUPTOR-NOVA-BASE-DAMAGE
 DISRUPTOR-NOVA-SHIELD-BONUS
 DISRUPTOR-NOVA-LIFETIME-FRAMES
 DISRUPTOR-NOVA-COOLDOWN-FRAMES
 DISRUPTOR-NOVA-SPEED
 DISRUPTOR-NOVA-SPEED-PER-FRAME
 DISRUPTOR-CAST-RANGE
 DISRUPTOR-MAX-REACH-RANGE
 DISRUPTOR-STANDOFF-MIN-DIST
 DISRUPTOR-STANDOFF-MAX-DIST
 DISRUPTOR-RETREAT-MIN-DIST
 DISRUPTOR-RETREAT-MAX-DIST
 DISRUPTOR-MIN-WORTHWHILE-SCORE
 DISRUPTOR-VOLLEY-DECONFLICT-DIST
 DISRUPTOR-ANTI-NOVA-DANGER-RADIUS
 DISRUPTOR-ANTI-NOVA-CONE-RANGE
 DISRUPTOR-BLINK-DODGE-RADIUS
 DISRUPTOR-BLINK-COOLDOWN-FRAMES
 DISRUPTOR-PRESPLIT-THREAT-RANGE
 DISRUPTOR-PRESPLIT-SPACING-TARGET

 ;; Output & state structs
 (struct-out nova-impact-score)
 (struct-out nova-cast-plan)
 (struct-out nova-steer-order)
 (struct-out disruptor-kite-order)
 (struct-out anti-nova-dodge-order)
 (struct-out disruptor-snipe-eval)

 ;; Tracker management & accessors
 disruptor-tactical-tracker?
 make-disruptor-tactical-tracker
 disruptor-tracker-enemy-cooldown
 disruptor-tracker-enemy-active-nova-frames
 disruptor-tracker-friendly-cooldown
 disruptor-tracker-stalker-blink-cooldown
 disruptor-tracker-nova-velocity

 ;; Predicates & scoring
 purification-nova-unit?
 disruptor-caster-unit?
 ground-nova-vulnerable-unit?
 filter-targetable-ground-units
 score-purification-nova-impact

 ;; Offensive & defensive tactical planners
 plan-disruptor-nova-casts
 steer-purification-novas
 kite-disruptor-casters
 plan-anti-nova-scatter
 evaluate-disruptor-snipe-and-cooldowns
 step-disruptor-tactical-micro!)

;; =============================================================================
;; Constants (LotV Balance / 22.4 Faster-speed frames)
;; =============================================================================

(: DISRUPTOR-UNIT-TYPE-ID Integer)
(define DISRUPTOR-UNIT-TYPE-ID 694)

(: DISRUPTOR-PHASED-UNIT-TYPE-ID Integer)
(define DISRUPTOR-PHASED-UNIT-TYPE-ID 733)

(: PURIFICATION-NOVA-ABILITY-ID Integer)
(define PURIFICATION-NOVA-ABILITY-ID 2346)

(: DISRUPTOR-NOVA-SPLASH-RADIUS Float)
(define DISRUPTOR-NOVA-SPLASH-RADIUS 1.5)

(: DISRUPTOR-NOVA-BASE-DAMAGE Float)
(define DISRUPTOR-NOVA-BASE-DAMAGE 145.0)

(: DISRUPTOR-NOVA-SHIELD-BONUS Float)
(define DISRUPTOR-NOVA-SHIELD-BONUS 55.0)

(: DISRUPTOR-NOVA-LIFETIME-FRAMES Integer)
(define DISRUPTOR-NOVA-LIFETIME-FRAMES 47)

(: DISRUPTOR-NOVA-COOLDOWN-FRAMES Integer)
(define DISRUPTOR-NOVA-COOLDOWN-FRAMES 480)

(: DISRUPTOR-NOVA-SPEED Float)
(define DISRUPTOR-NOVA-SPEED 5.95)

(: DISRUPTOR-NOVA-SPEED-PER-FRAME Float)
(define DISRUPTOR-NOVA-SPEED-PER-FRAME (/ 5.95 22.4))

(: DISRUPTOR-CAST-RANGE Float)
(define DISRUPTOR-CAST-RANGE 10.0)

(: DISRUPTOR-MAX-REACH-RANGE Float)
(define DISRUPTOR-MAX-REACH-RANGE 13.0)

(: DISRUPTOR-STANDOFF-MIN-DIST Float)
(define DISRUPTOR-STANDOFF-MIN-DIST 10.5)

(: DISRUPTOR-STANDOFF-MAX-DIST Float)
(define DISRUPTOR-STANDOFF-MAX-DIST 12.0)

(: DISRUPTOR-RETREAT-MIN-DIST Float)
(define DISRUPTOR-RETREAT-MIN-DIST 13.0)

(: DISRUPTOR-RETREAT-MAX-DIST Float)
(define DISRUPTOR-RETREAT-MAX-DIST 15.0)

(: DISRUPTOR-MIN-WORTHWHILE-SCORE Float)
(define DISRUPTOR-MIN-WORTHWHILE-SCORE 100.0)

(: DISRUPTOR-VOLLEY-DECONFLICT-DIST Float)
(define DISRUPTOR-VOLLEY-DECONFLICT-DIST 4.0)

(: DISRUPTOR-ANTI-NOVA-DANGER-RADIUS Float)
(define DISRUPTOR-ANTI-NOVA-DANGER-RADIUS 6.5)

(: DISRUPTOR-ANTI-NOVA-CONE-RANGE Float)
(define DISRUPTOR-ANTI-NOVA-CONE-RANGE 9.0)

(: DISRUPTOR-BLINK-DODGE-RADIUS Float)
(define DISRUPTOR-BLINK-DODGE-RADIUS 2.75)

(: DISRUPTOR-BLINK-COOLDOWN-FRAMES Integer)
(define DISRUPTOR-BLINK-COOLDOWN-FRAMES 160)

(: DISRUPTOR-PRESPLIT-THREAT-RANGE Float)
(define DISRUPTOR-PRESPLIT-THREAT-RANGE 14.5)

(: DISRUPTOR-PRESPLIT-SPACING-TARGET Float)
(define DISRUPTOR-PRESPLIT-SPACING-TARGET 3.0)

(: DISRUPTOR-HIGH-VALUE-SYMS (Listof Symbol))
(define DISRUPTOR-HIGH-VALUE-SYMS
  '(lurker lurker-burrowed siege-tank siege-tank-sieged ghost high-templar
    disruptor ravager infestor infestor-burrowed viper colossus immortal archon))

;; =============================================================================
;; Public Data Structs
;; =============================================================================

(struct nova-impact-score
  ([net-score : Float]
   [enemy-hits : Integer]
   [ally-hits : Integer]
   [enemy-raw-value : Float]
   [ally-penalty-value : Float])
  #:transparent)

(struct nova-cast-plan
  ([caster-tag : Integer]
   [tx : Float]
   [ty : Float]
   [expected-score : Float]
   [enemy-hits : Integer]
   [ally-risk : Integer])
  #:transparent)

(struct nova-steer-order
  ([nova-tag : Integer]
   [tx : Float]
   [ty : Float]
   [target-score : Float]
   [hits : Integer])
  #:transparent)

(struct disruptor-kite-order
  ([unit-tag : Integer]
   [action : Symbol]
   [tx : Float]
   [ty : Float]
   [nearest-enemy-dist : Float]
   [state : Symbol]
   [reason : Symbol])
  #:transparent)

(struct anti-nova-dodge-order
  ([unit-tag : Integer]
   [action : Symbol]
   [tx : Float]
   [ty : Float]
   [threat-nova-tag : Integer]
   [dist : Float]
   [reason : Symbol])
  #:transparent)

(struct disruptor-snipe-eval
  ([enemy-tag : Integer]
   [x : Float]
   [y : Float]
   [state : Symbol]
   [cooldown-remaining : Integer]
   [active-nova-frames-left : Integer]
   [snipe-feasible? : Boolean]
   [attacker-tags : (Listof Integer)]
   [projected-burst-dps : Float]
   [effective-ehp : Float])
  #:transparent)

;; =============================================================================
;; Stateful Cross-Frame Tracker (Velocities, Parent Links, 480f/160f Cooldowns)
;; =============================================================================

(struct nova-track-state
  ([x : Float]
   [y : Float]
   [vx : Float]
   [vy : Float]
   [first-frame : Integer]
   [last-frame : Integer]
   [expire-frame : Integer]
   [parent-tag : Integer]
   [friendly? : Boolean])
  #:transparent)

(struct caster-cooldown-state
  ([cooldown-until-frame : Integer]
   [active-nova-tag : Integer]
   [nova-expire-frame : Integer])
  #:transparent)

(struct disruptor-tactical-tracker
  ([nova-table : (Mutable-HashTable Integer nova-track-state)]
   [enemy-casters : (Mutable-HashTable Integer caster-cooldown-state)]
   [friendly-casters : (Mutable-HashTable Integer Integer)]
   [stalker-blinks : (Mutable-HashTable Integer Integer)]))

(: make-disruptor-tactical-tracker (-> disruptor-tactical-tracker))
(define (make-disruptor-tactical-tracker)
  (disruptor-tactical-tracker
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)))

(: disruptor-tracker-enemy-cooldown (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-enemy-cooldown tr enemy-tag current-frame)
  (define st (hash-ref (disruptor-tactical-tracker-enemy-casters tr) enemy-tag (lambda () #f)))
  (if st
      (max 0 (- (caster-cooldown-state-cooldown-until-frame st) current-frame))
      0))

(: disruptor-tracker-enemy-active-nova-frames (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-enemy-active-nova-frames tr enemy-tag current-frame)
  (define st (hash-ref (disruptor-tactical-tracker-enemy-casters tr) enemy-tag (lambda () #f)))
  (if (and st (> (caster-cooldown-state-active-nova-tag st) 0))
      (max 0 (- (caster-cooldown-state-nova-expire-frame st) current-frame))
      0))

(: disruptor-tracker-friendly-cooldown (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-friendly-cooldown tr unit-tag current-frame)
  (define until (hash-ref (disruptor-tactical-tracker-friendly-casters tr) unit-tag (lambda () 0)))
  (max 0 (- until current-frame)))

(: disruptor-tracker-stalker-blink-cooldown (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-stalker-blink-cooldown tr unit-tag current-frame)
  (define until (hash-ref (disruptor-tactical-tracker-stalker-blinks tr) unit-tag (lambda () 0)))
  (max 0 (- until current-frame)))

(: disruptor-tracker-nova-velocity (-> disruptor-tactical-tracker Integer (Values Float Float Boolean)))
(define (disruptor-tracker-nova-velocity tr nova-tag)
  (define st (hash-ref (disruptor-tactical-tracker-nova-table tr) nova-tag (lambda () #f)))
  (if st
      (let ([vx (nova-track-state-vx st)]
            [vy (nova-track-state-vy st)])
        (values vx vy (> (+ (* vx vx) (* vy vy)) 0.0025)))
      (values 0.0 0.0 #f)))

;; =============================================================================
;; Internal Unit Attribute & Vector Helpers
;; =============================================================================

(: unit-tag-int (-> Any Integer))
(define (unit-tag-int u)
  (if (hash? u)
      (let ([t (dyn-hash-ref u 'tag #f)])
        (if (exact-integer? t)
            t
            (safe-exact-int (dyn-hash-ref u 'id 0) 0)))
      0))

(: resolved-unit-type (-> Any Symbol))
(define (resolved-unit-type u)
  (cond
    [(symbol? u) (sc2-canonical-unit-sym u)]
    [(exact-integer? u)
     (cond
       [(= u DISRUPTOR-UNIT-TYPE-ID) 'disruptor]
       [(= u DISRUPTOR-PHASED-UNIT-TYPE-ID) 'disruptor-phased]
       [(= u 74) 'stalker]
       [else 'unknown])]
    [(hash? u)
     (define ut (unit-type-sym u))
     (define uid-type (safe-exact-int (dyn-hash-ref u 'unit_type 0) 0))
     (cond
       [(not (eq? ut 'unknown)) (sc2-canonical-unit-sym ut)]
       [(= uid-type DISRUPTOR-UNIT-TYPE-ID) 'disruptor]
       [(= uid-type DISRUPTOR-PHASED-UNIT-TYPE-ID) 'disruptor-phased]
       [(= uid-type 74) 'stalker]
       [else 'unknown])]
    [else 'unknown]))

(: unit-x (-> Any Float))
(define (unit-x u)
  (safe-finite-real (dyn-hash-ref u 'x 0.0) 0.0))

(: unit-y (-> Any Float))
(define (unit-y u)
  (safe-finite-real (dyn-hash-ref u 'y 0.0) 0.0))

(: unit-hp (-> Any Float Float))
(define (unit-hp u default-hp)
  (cond
    [(dyn-hash-has-key? u 'hp) (max 0.0 (safe-finite-real (dyn-hash-ref u 'hp default-hp) default-hp))]
    [(dyn-hash-has-key? u 'health) (max 0.0 (safe-finite-real (dyn-hash-ref u 'health default-hp) default-hp))]
    [else default-hp]))

(: unit-shield (-> Any Float Float))
(define (unit-shield u default-shield)
  (cond
    [(dyn-hash-has-key? u 'shield) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shield default-shield) default-shield))]
    [(dyn-hash-has-key? u 'shields) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shields default-shield) default-shield))]
    [else default-shield]))

(: unit-alive? (-> Any Boolean))
(define (unit-alive? u)
  (if (or (dyn-hash-has-key? u 'hp)
          (dyn-hash-has-key? u 'health)
          (dyn-hash-has-key? u 'shield)
          (dyn-hash-has-key? u 'shields))
      (> (+ (unit-hp u 0.0) (unit-shield u 0.0)) 0.0)
      #t))

(: unit-is-flying? (-> Any Boolean))
(define (unit-is-flying? u)
  (define ut (resolved-unit-type u))
  (not (not (or (eq? (dyn-hash-ref u 'flying #f) #t)
                (eq? (dyn-hash-ref u 'flying? #f) #t)
                (eq? (dyn-hash-ref u 'is-flying #f) #t)
                (eq? (dyn-hash-ref u 'is_flying #f) #t)
                (sc2-unit-is-flying-sym? ut)))))

(: unit-is-structure? (-> Any Boolean))
(define (unit-is-structure? u)
  (define ut (resolved-unit-type u))
  (not (not (or (eq? (dyn-hash-ref u 'is-building #f) #t)
                (eq? (dyn-hash-ref u 'building? #f) #t)
                (eq? (dyn-hash-ref u 'is-structure #f) #t)
                (memq ut SC2-ALL-STRUCTURE-SYMS)
                (memq ut '(auto-turret point-defense-drone interceptor))))))

(: unit-radius-bonus (-> Any Float Float))
(define (unit-radius-bonus u extra-margin)
  (define raw
    (if (dyn-hash-has-key? u 'radius)
        (clamp-real (safe-finite-real (dyn-hash-ref u 'radius 0.0) 0.0) 0.0 0.65)
        0.0))
  (+ raw extra-margin))

(: clamp-to-playable (-> Real Real point2d))
(define (clamp-to-playable x y)
  (clamp-point-to-map (point2d (->float x) (->float y))
                      SC2-MAP-PLAYABLE-MIN-COORD
                      SC2-MAP-PLAYABLE-MAX-COORD))

(: unit-vec-2d (-> Real Real (Values Float Float Float)))
(define (unit-vec-2d dx dy)
  (define fx (->float dx))
  (define fy (->float dy))
  (define sq (max 0.0 (+ (* fx fx) (* fy fy))))
  (define mag : Float (if (> sq 0.0) (assert (sqrt sq) flonum?) 0.0))
  (if (> mag 1e-6)
      (values (/ fx mag) (/ fy mag) mag)
      (values 0.0 0.0 0.0)))

(: stalker-unit? (-> Any Boolean))
(define (stalker-unit? u)
  (eq? (resolved-unit-type u) 'stalker))

(: explicit-nova-order? (-> Any Boolean))
(define (explicit-nova-order? u)
  (define orders (dyn-hash-ref u 'orders '()))
  (and (list? orders)
       (for/or : Boolean ([o (in-list orders)])
         (cond
           [(eq? o 'purification-nova) #t]
           [(exact-integer? o) (= o PURIFICATION-NOVA-ABILITY-ID)]
           [(pair? o)
            (or (eq? (car o) 'purification-nova)
                (equal? (car o) PURIFICATION-NOVA-ABILITY-ID))]
           [(hash? o)
            (define aid (dyn-hash-ref o 'ability_id #f))
            (define asym (dyn-hash-ref o 'ability #f))
            (or (equal? aid PURIFICATION-NOVA-ABILITY-ID)
                (eq? asym 'purification-nova)
                (eq? asym 'purification-nova-targeted))]
           [else #f]))))

(: explicit-order-target-point (-> Any (Option point2d)))
(define (explicit-order-target-point u)
  (define orders (dyn-hash-ref u 'orders '()))
  (and (list? orders)
       (for/or : (Option point2d) ([o (in-list orders)])
         (cond
           [(hash? o)
            (define tx (dyn-hash-ref o 'target_x (dyn-hash-ref o 'tx #f)))
            (define ty (dyn-hash-ref o 'target_y (dyn-hash-ref o 'ty #f)))
            (and (finite-real? tx) (finite-real? ty)
                 (point2d (safe-finite-real tx 0.0) (safe-finite-real ty 0.0)))]
           [else #f]))))

;; =============================================================================
;; Public Unit Predicates & Target Filtering
;; =============================================================================

;; Identify phased Purification Nova projectiles (`DisruptorPhased` 733),
;; which are completely invulnerable and must NEVER be targeted by attacks/spells.
(: purification-nova-unit? (-> Any Boolean))
(define (purification-nova-unit? u)
  (cond
    [(symbol? u) (eq? (sc2-canonical-unit-sym u) 'disruptor-phased)]
    [(exact-integer? u) (= u DISRUPTOR-PHASED-UNIT-TYPE-ID)]
    [(hash? u)
     (define ut (unit-type-sym u))
     (define uid-type (safe-exact-int (dyn-hash-ref u 'unit_type 0) 0))
     (not (not (or (eq? ut 'disruptor-phased)
                   (eq? (sc2-canonical-unit-sym ut) 'disruptor-phased)
                   (= uid-type DISRUPTOR-PHASED-UNIT-TYPE-ID))))]
    [else #f]))

;; Identify Protoss Disruptor caster units (`694`), which have NO auto-attack weapon.
(: disruptor-caster-unit? (-> Any Boolean))
(define (disruptor-caster-unit? u)
  (cond
    [(symbol? u) (eq? (sc2-canonical-unit-sym u) 'disruptor)]
    [(exact-integer? u) (= u DISRUPTOR-UNIT-TYPE-ID)]
    [(hash? u) (eq? (resolved-unit-type u) 'disruptor)]
    [else #f]))

;; Return #t iff `u` is a living, non-hallucination ground non-structure unit
;; susceptible to Purification Nova splash damage.
(: ground-nova-vulnerable-unit? (-> Any Boolean))
(define (ground-nova-vulnerable-unit? u)
  (and (hash? u)
       (not (purification-nova-unit? u))
       (not (eq? (dyn-hash-ref u 'hallucination #f) #t))
       (unit-alive? u)
       (let ([ut (resolved-unit-type u)])
         (and (not (memq ut SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS))
              (not (unit-is-flying? u))
              (not (unit-is-structure? u))))))

;; Filter a list of enemy (or ally) hashes down to targetable ground units,
;; excluding `disruptor-phased`, decoys, air units, hallucinations, and buildings.
(: filter-targetable-ground-units (-> (Listof Any) (Listof Any)))
(define (filter-targetable-ground-units units)
  (filter ground-nova-vulnerable-unit? units))

;; =============================================================================
;; Splash Cluster Scoring (`145 + 55 shield`, 1.5 radius, 2.0x FF penalty)
;; =============================================================================

(: unit-nova-replacement-value (-> Any Float))
(define (unit-nova-replacement-value u)
  (define ut (resolved-unit-type u))
  (define min-c (sc2-min-cost ut 50))
  (define gas-c (sc2-gas-cost ut 0))
  (define base (+ (->float min-c) (* 1.25 (->float gas-c))))
  (define tier-mult (if (memq ut DISRUPTOR-HIGH-VALUE-SYMS) 1.15 1.0))
  (* base tier-mult))

(: effective-nova-damage-fraction (-> Any Float Float))
(define (effective-nova-damage-fraction u unit-val)
  (define hp (unit-hp u 80.0))
  (define sh (unit-shield u 0.0))
  (define ehp (+ hp sh))
  (define nova-dmg
    (if (> sh 0.0)
        (+ DISRUPTOR-NOVA-BASE-DAMAGE DISRUPTOR-NOVA-SHIELD-BONUS)
        DISRUPTOR-NOVA-BASE-DAMAGE))
  (define frac (if (> ehp 0.0) (min 1.0 (/ nova-dmg ehp)) 1.0))
  (define kill-mult (if (<= ehp nova-dmg) 1.15 0.85))
  (* unit-val frac kill-mult))

;; Score placing a Purification Nova detonation at `(tx, ty)` against
;; ground-vulnerable `enemy-units` and `ally-units` within splash radius `1.5`.
(: score-purification-nova-impact (-> Real Real (Listof Any) (Listof Any) nova-impact-score))
(define (score-purification-nova-impact tx ty enemy-units ally-units)
  (define ftx (->float tx))
  (define fty (->float ty))
  (define-values (enemy-raw enemy-hits)
    (for/fold ([acc : Float 0.0]
               [hits : Integer 0])
              ([e (in-list enemy-units)]
               #:when (ground-nova-vulnerable-unit? e))
      (define d (dist-2d ftx fty (unit-x e) (unit-y e)))
      (define hit-r (+ DISRUPTOR-NOVA-SPLASH-RADIUS (unit-radius-bonus e 0.0)))
      (if (<= d hit-r)
          (let* ([uval (unit-nova-replacement-value e)]
                 [contrib (effective-nova-damage-fraction e uval)])
            (values (+ acc contrib) (+ hits 1)))
          (values acc hits))))
  ;; Friendly fire: Disruption hits ally ground units too; apply 2.0x penalty + 0.25m buffer.
  (define-values (ally-pen ally-hits)
    (for/fold ([acc : Float 0.0]
               [hits : Integer 0])
              ([a (in-list ally-units)]
               #:when (ground-nova-vulnerable-unit? a))
      (define d (dist-2d ftx fty (unit-x a) (unit-y a)))
      (define hit-r (+ DISRUPTOR-NOVA-SPLASH-RADIUS (unit-radius-bonus a 0.25)))
      (if (<= d hit-r)
          (let* ([uval (unit-nova-replacement-value a)]
                 [loss (effective-nova-damage-fraction a uval)])
            (values (+ acc (* 2.0 loss)) (+ hits 1)))
          (values acc hits))))
  (nova-impact-score (- enemy-raw ally-pen) enemy-hits ally-hits enemy-raw ally-pen))

;; Generate candidate detonation points covering exact unit positions, 2-unit
;; midpoints (catching pairs <= 3.0 apart), local neighborhood centroids, and
;; ally-avoiding outer offsets.
(: generate-nova-candidate-points (-> (Listof Any) (Listof Any) Float Float Float (Listof point2d)))
(define (generate-nova-candidate-points enemies allies origin-x origin-y max-range)
  (define near-enemies : (Listof Any)
    (let ([filtered
           (filter (lambda ([e : Any])
                     (<= (dist-2d origin-x origin-y (unit-x e) (unit-y e))
                         (+ max-range 2.5)))
                   enemies)])
      (if (> (length filtered) 40)
          (take (sort filtered
                      (lambda ([a : Any] [b : Any])
                        (< (dist-sq-2d origin-x origin-y (unit-x a) (unit-y a))
                           (dist-sq-2d origin-x origin-y (unit-x b) (unit-y b)))))
                40)
          filtered)))
  (define near-allies : (Listof Any)
    (filter (lambda ([a : Any])
              (and (ground-nova-vulnerable-unit? a)
                   (<= (dist-2d origin-x origin-y (unit-x a) (unit-y a))
                       (+ max-range 5.0))))
            allies))
  (define raw-pts : (Listof point2d) '())
  (: add-pt! (-> Real Real Void))
  (define (add-pt! x y)
    (define cp (clamp-to-playable x y))
    (when (<= (dist-2d origin-x origin-y (point2d-x cp) (point2d-y cp)) max-range)
      (set! raw-pts (cons cp raw-pts))))

  (for ([e1 (in-list near-enemies)])
    (define x1 (unit-x e1))
    (define y1 (unit-y e1))
    (add-pt! x1 y1)
    ;; Neighborhood centroid & pair midpoints within 2*radius (~3.05 tiles)
    (define-values (sx sy cnt)
      (for/fold ([ax : Float 0.0]
                 [ay : Float 0.0]
                 [c : Integer 0])
                ([e2 (in-list near-enemies)])
        (define x2 (unit-x e2))
        (define y2 (unit-y e2))
        (define d (dist-2d x1 y1 x2 y2))
        (if (<= d 3.05)
            (begin
              (when (> d 0.1)
                (add-pt! (* 0.5 (+ x1 x2)) (* 0.5 (+ y1 y2))))
              (values (+ ax x2) (+ ay y2) (+ c 1)))
            (values ax ay c))))
    (when (> cnt 1)
      (add-pt! (/ sx (->float cnt)) (/ sy (->float cnt))))
    ;; Off-center shift away from nearby friendly ground units to avoid friendly fire
    (when (pair? near-allies)
      (define-values (cx cy acnt)
        (for/fold ([ax : Float 0.0]
                   [ay : Float 0.0]
                   [c : Integer 0])
                  ([a (in-list near-allies)])
          (define axu (unit-x a))
          (define ayu (unit-y a))
          (if (<= (dist-2d x1 y1 axu ayu) 3.5)
              (values (+ ax axu) (+ ay ayu) (+ c 1))
              (values ax ay c))))
      (when (> acnt 0)
        (define away-x (- x1 (/ cx (->float acnt))))
        (define away-y (- y1 (/ cy (->float acnt))))
        (define-values (ux uy mag) (unit-vec-2d away-x away-y))
        (when (> mag 0.05)
          (add-pt! (+ x1 (* 1.15 ux)) (+ y1 (* 1.15 uy)))))))
  raw-pts)

(: pick-best-nova-target
   (-> (Listof Any) (Listof Any) Float Float Float (Listof point2d) Float
       (Values (Option point2d) nova-impact-score)))
(define (pick-best-nova-target ground-enemies ground-allies origin-x origin-y max-range reserved-pts deconflict-dist)
  (define candidates (generate-nova-candidate-points ground-enemies ground-allies origin-x origin-y max-range))
  (define best-pt : (Option point2d) #f)
  (define best-sc : nova-impact-score (nova-impact-score -999999.0 0 0 0.0 0.0))
  (for ([pt (in-list candidates)])
    (define px (point2d-x pt))
    (define py (point2d-y pt))
    (define clear?
      (for/and : Boolean ([rp (in-list reserved-pts)])
        (>= (dist-2d px py (point2d-x rp) (point2d-y rp)) deconflict-dist)))
    (when clear?
      (define sc (score-purification-nova-impact px py ground-enemies ground-allies))
      (define cur-best best-pt)
      (define better? : Boolean
        (if cur-best
            (or (> (nova-impact-score-net-score sc) (nova-impact-score-net-score best-sc))
                (and (= (nova-impact-score-net-score sc) (nova-impact-score-net-score best-sc))
                     (< (dist-sq-2d origin-x origin-y px py)
                        (dist-sq-2d origin-x origin-y (point2d-x cur-best) (point2d-y cur-best)))))
            #t))
      (when better?
        (set! best-pt pt)
        (set! best-sc sc))))
  (values best-pt best-sc))

;; =============================================================================
;; Tracker State Synchronization (Velocities, Parent Matching, Cooldowns)
;; =============================================================================

(: sync-tracker-state!
   (-> disruptor-tactical-tracker (Listof Any) (Listof Any) Integer Void))
(define (sync-tracker-state! tr ally-units enemy-units current-frame)
  (define nova-ht (disruptor-tactical-tracker-nova-table tr))
  (define enemy-cd-ht (disruptor-tactical-tracker-enemy-casters tr))
  (define friendly-cd-ht (disruptor-tactical-tracker-friendly-casters tr))

  ;; Helper to update a faction's Nova positions/velocities and discover new spawns.
  (: update-nova-list! (-> (Listof Any) (Listof Any) Boolean Void))
  (define (update-nova-list! units casters friendly?)
    (for ([u (in-list units)]
          #:when (and (hash? u) (purification-nova-unit? u)))
      (define ntag (unit-tag-int u))
      (define nx (unit-x u))
      (define ny (unit-y u))
      (define prev (hash-ref nova-ht ntag (lambda () #f)))
      (define explicit-vx (if (dyn-hash-has-key? u 'vx) (safe-finite-real (dyn-hash-ref u 'vx 0.0) 0.0) 0.0))
      (define explicit-vy (if (dyn-hash-has-key? u 'vy) (safe-finite-real (dyn-hash-ref u 'vy 0.0) 0.0) 0.0))
      (define-values (vx vy)
        (cond
          [(> (+ (* explicit-vx explicit-vx) (* explicit-vy explicit-vy)) 0.0025)
           (values explicit-vx explicit-vy)]
          [(and prev (> (- current-frame (nova-track-state-last-frame prev)) 0))
           (define dt-sec (/ (->float (- current-frame (nova-track-state-last-frame prev))) 22.4))
           (define cvx (/ (- nx (nova-track-state-x prev)) dt-sec))
           (define cvy (/ (- ny (nova-track-state-y prev)) dt-sec))
           (if (> (+ (* cvx cvx) (* cvy cvy)) 0.0025)
               (values cvx cvy)
               (values (nova-track-state-vx prev) (nova-track-state-vy prev)))]
          [(dyn-hash-has-key? u 'facing)
           (define ang (safe-finite-real (dyn-hash-ref u 'facing 0.0) 0.0))
           (values (* DISRUPTOR-NOVA-SPEED (cos ang)) (* DISRUPTOR-NOVA-SPEED (sin ang)))]
          [else (values 0.0 0.0)]))
      (define first-f (if prev (nova-track-state-first-frame prev) current-frame))
      (define expire-f
        (if (dyn-hash-has-key? u 'remaining-frames)
            (+ current-frame (max 1 (safe-exact-int (dyn-hash-ref u 'remaining-frames DISRUPTOR-NOVA-LIFETIME-FRAMES) DISRUPTOR-NOVA-LIFETIME-FRAMES)))
            (if prev
                (nova-track-state-expire-frame prev)
                (+ current-frame DISRUPTOR-NOVA-LIFETIME-FRAMES))))
      ;; Match newly observed Nova to nearest parent Disruptor within 3.5 tiles
      (define parent-tag : Integer
        (if (and prev (> (nova-track-state-parent-tag prev) 0))
            (nova-track-state-parent-tag prev)
            (let-values ([(best-p _best-d)
                          (for/fold ([best-p : Integer 0]
                                     [best-d : Float 3.51])
                                    ([c (in-list casters)])
                            (define d (dist-2d nx ny (unit-x c) (unit-y c)))
                            (if (< d best-d)
                                (values (unit-tag-int c) d)
                                (values best-p best-d)))])
              best-p)))
      (hash-set! nova-ht ntag
                 (nova-track-state nx ny vx vy first-f current-frame expire-f parent-tag friendly?))
      (when (> parent-tag 0)
        (if friendly?
            (when (<= (hash-ref friendly-cd-ht parent-tag (lambda () 0)) current-frame)
              (hash-set! friendly-cd-ht parent-tag (+ first-f DISRUPTOR-NOVA-COOLDOWN-FRAMES)))
            (let ([cst (hash-ref enemy-cd-ht parent-tag (lambda () #f))])
              (when (or (not cst)
                        (not (= (caster-cooldown-state-active-nova-tag cst) ntag)))
                (hash-set! enemy-cd-ht parent-tag
                           (caster-cooldown-state
                            (+ first-f DISRUPTOR-NOVA-COOLDOWN-FRAMES)
                            ntag
                            expire-f))))))))

  (define ally-casters (filter (lambda ([u : Any]) (and (hash? u) (disruptor-caster-unit? u))) ally-units))
  (define enemy-casters (filter (lambda ([u : Any]) (and (hash? u) (disruptor-caster-unit? u))) enemy-units))
  (update-nova-list! ally-units ally-casters #t)
  (update-nova-list! enemy-units enemy-casters #f)

  ;; Clear expired active-nova links if Nova vanished or expired
  (define live-enemy-nova-tags : (Setof Integer)
    (list->set
     (for/list : (Listof Integer)
               ([u (in-list enemy-units)]
                #:when (and (hash? u) (purification-nova-unit? u)))
       (unit-tag-int u))))
  (for ([ec (in-list enemy-casters)])
    (define etag (unit-tag-int ec))
    (define cst (hash-ref enemy-cd-ht etag (lambda () #f)))
    (when (and cst (> (caster-cooldown-state-active-nova-tag cst) 0))
      (define ant (caster-cooldown-state-active-nova-tag cst))
      (when (or (not (set-member? live-enemy-nova-tags ant))
                (> current-frame (caster-cooldown-state-nova-expire-frame cst)))
        (hash-set! enemy-cd-ht etag
                   (caster-cooldown-state
                    (caster-cooldown-state-cooldown-until-frame cst)
                    0
                    0))))
    ;; Also honor explicit unit order 2346 or explicit cooldown on hash
    (when (and (explicit-nova-order? ec)
               (or (not cst) (<= (caster-cooldown-state-cooldown-until-frame cst) current-frame)))
      (hash-set! enemy-cd-ht etag
                 (caster-cooldown-state
                  (+ current-frame DISRUPTOR-NOVA-COOLDOWN-FRAMES)
                  (if cst (caster-cooldown-state-active-nova-tag cst) -1)
                  (+ current-frame DISRUPTOR-NOVA-LIFETIME-FRAMES)))))

  ;; Prune dead/expired Novas from nova-table
  (define live-all-novas : (Setof Integer)
    (set-union
     live-enemy-nova-tags
     (list->set
      (for/list : (Listof Integer)
                ([u (in-list ally-units)]
                 #:when (and (hash? u) (purification-nova-unit? u)))
        (unit-tag-int u)))))
  (for ([k (in-list (hash-keys nova-ht))])
    (unless (set-member? live-all-novas k)
      (hash-remove! nova-ht k))))

;; =============================================================================
;; 1. Offensive Cast Planning (`plan-disruptor-nova-casts`)
;; =============================================================================

(: caster-on-cooldown? (-> Any (Option disruptor-tactical-tracker) Integer Boolean))
(define (caster-on-cooldown? u tr current-frame)
  (define uid (unit-tag-int u))
  (define explicit-cd
    (max (safe-exact-int (dyn-hash-ref u 'nova-cooldown 0) 0)
         (safe-exact-int (dyn-hash-ref u 'ability-cooldown 0) 0)
         (safe-exact-int (dyn-hash-ref u 'cooldown 0) 0)))
  (define explicit-not-ready? (eq? (dyn-hash-ref u 'purification-nova-ready #t) #f))
  (define tracker-cd
    (if tr (disruptor-tracker-friendly-cooldown tr uid current-frame) 0))
  (or (> explicit-cd 0)
      explicit-not-ready?
      (> tracker-cd 0)
      (explicit-nova-order? u)))

;; Plan optimal Purification Nova (`2346`) casts for ready friendly Disruptors:
;; - Ground non-structure non-`disruptor-phased` enemies only
;; - Requires net splash score >= `min-worthwhile-score` (default 100.0)
;; - Checks cast reach <= `max-reach` (default 13.0)
;; - De-conflicts >= `deconflict-dist` (default 4.0) from active friendly Novas
;;   and earlier planned casts on the same tick.
(: plan-disruptor-nova-casts
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:min-worthwhile-score Real
         #:max-reach Real
         #:deconflict-dist Real)
        (Listof nova-cast-plan)))
(define (plan-disruptor-nova-casts ally-units enemy-units
                                   #:tracker [tr #f]
                                   #:current-frame [current-frame 0]
                                   #:min-worthwhile-score [min-score-arg DISRUPTOR-MIN-WORTHWHILE-SCORE]
                                   #:max-reach [max-reach-arg DISRUPTOR-MAX-REACH-RANGE]
                                   #:deconflict-dist [deconflict-arg DISRUPTOR-VOLLEY-DECONFLICT-DIST])
  (when tr
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define min-score (->float min-score-arg))
  (define max-reach (->float max-reach-arg))
  (define deconflict (->float deconflict-arg))
  (define ground-enemies (filter-targetable-ground-units enemy-units))
  (define ground-allies (filter-targetable-ground-units ally-units))
  (if (null? ground-enemies)
      '()
      (let ()
        ;; Reserve positions of live friendly Novas + active channeling orders
        (define reserved-pts : (Listof point2d)
          (append
           (for/list : (Listof point2d) ([u (in-list ally-units)]
                                         #:when (and (hash? u) (purification-nova-unit? u)))
             (point2d (unit-x u) (unit-y u)))
           (for/fold ([pts : (Listof point2d) '()])
                     ([u (in-list ally-units)]
                      #:when (and (hash? u) (disruptor-caster-unit? u) (explicit-nova-order? u)))
             (define op (explicit-order-target-point u))
             (if op (cons op pts) pts))))
        (define ready-casters : (Listof Any)
          (filter (lambda ([u : Any])
                    (and (hash? u)
                         (disruptor-caster-unit? u)
                         (unit-alive? u)
                         (not (caster-on-cooldown? u tr current-frame))))
                  ally-units))
        (define plans : (Listof nova-cast-plan) '())
        (for ([c (in-list ready-casters)])
          (define cid (unit-tag-int c))
          (define cx (unit-x c))
          (define cy (unit-y c))
          (define-values (best-pt sc)
            (pick-best-nova-target ground-enemies ground-allies cx cy max-reach reserved-pts deconflict))
          (when (and best-pt
                     (> (nova-impact-score-enemy-hits sc) 0)
                     (>= (nova-impact-score-net-score sc) min-score))
            (define tx (point2d-x best-pt))
            (define ty (point2d-y best-pt))
            (set! reserved-pts (cons best-pt reserved-pts))
            (set! plans (cons (nova-cast-plan cid tx ty
                                              (nova-impact-score-net-score sc)
                                              (nova-impact-score-enemy-hits sc)
                                              (nova-impact-score-ally-hits sc))
                              plans))
            (when tr
              (hash-set! (disruptor-tactical-tracker-friendly-casters tr)
                         cid
                         (+ current-frame DISRUPTOR-NOVA-COOLDOWN-FRAMES)))))
        (reverse plans))))

;; =============================================================================
;; 2. Live Friendly Purification Nova Steering (`steer-purification-novas`)
;; =============================================================================

;; Compute per-step homing orders for active friendly `DisruptorPhased` (`733`)
;; balls (~47-frame lifetime, 5.95 tiles/sec) onto the highest-value reachable
;; enemy ground cluster centroid, avoiding friendly fire.
(: steer-purification-novas
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer)
        (Listof nova-steer-order)))
(define (steer-purification-novas ally-units enemy-units
                                  #:tracker [tr #f]
                                  #:current-frame [current-frame 0])
  (when tr
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define ground-enemies (filter-targetable-ground-units enemy-units))
  (define ground-allies (filter-targetable-ground-units ally-units))
  (define friendly-novas : (Listof Any)
    (filter (lambda ([u : Any]) (and (hash? u) (purification-nova-unit? u))) ally-units))
  (if (null? friendly-novas)
      '()
      (let ()
        (define claimed-targets : (Listof point2d) '())
        (define orders : (Listof nova-steer-order) '())
        (for ([n (in-list friendly-novas)])
          (define nid (unit-tag-int n))
          (define nx (unit-x n))
          (define ny (unit-y n))
          (define rem-frames : Integer
            (cond
              [(dyn-hash-has-key? n 'remaining-frames)
               (max 1 (safe-exact-int (dyn-hash-ref n 'remaining-frames DISRUPTOR-NOVA-LIFETIME-FRAMES)
                                      DISRUPTOR-NOVA-LIFETIME-FRAMES))]
              [(dyn-hash-has-key? n 'age-frames)
               (max 1 (- DISRUPTOR-NOVA-LIFETIME-FRAMES
                         (max 0 (safe-exact-int (dyn-hash-ref n 'age-frames 0) 0))))]
              [tr
               (define st (hash-ref (disruptor-tactical-tracker-nova-table tr) nid (lambda () #f)))
               (if st
                   (max 1 (- (nova-track-state-expire-frame st) current-frame))
                   DISRUPTOR-NOVA-LIFETIME-FRAMES)]
              [else DISRUPTOR-NOVA-LIFETIME-FRAMES]))
          ;; Reachable travel radius before detonation + splash margin
          (define travel-reach
            (+ DISRUPTOR-NOVA-SPLASH-RADIUS
               (* (->float rem-frames) DISRUPTOR-NOVA-SPEED-PER-FRAME)))
          (define-values (best-pt sc)
            (if (null? ground-enemies)
                (values #f (nova-impact-score -1.0 0 0 0.0 0.0))
                (let ()
                  ;; Try de-conflicted reachable clusters first
                  (define-values (pt1 sc1)
                    (pick-best-nova-target ground-enemies ground-allies nx ny travel-reach claimed-targets 3.2))
                  (if (and pt1 (> (nova-impact-score-enemy-hits sc1) 0))
                      (values pt1 sc1)
                      ;; Fallback without de-confliction if only 1 enemy cluster exists
                      (pick-best-nova-target ground-enemies ground-allies nx ny travel-reach '() 0.0)))))
          (cond
            [(and best-pt
                  (> (nova-impact-score-enemy-hits sc) 0)
                  (>= (nova-impact-score-net-score sc) 0.0))
             (set! claimed-targets (cons best-pt claimed-targets))
             (set! orders (cons (nova-steer-order nid (point2d-x best-pt) (point2d-y best-pt)
                                                  (nova-impact-score-net-score sc)
                                                  (nova-impact-score-enemy-hits sc))
                                orders))]
            [else
             ;; If only friendly units are near the live Nova (avoid friendly fire!) or
             ;; enemies are slightly beyond remaining reach, steer away from ally cluster.
             (define near-ally-pts : (Listof point2d)
               (for/list : (Listof point2d) ([a (in-list ground-allies)]
                                             #:when (<= (dist-2d nx ny (unit-x a) (unit-y a))
                                                        (+ travel-reach 2.5)))
                 (point2d (unit-x a) (unit-y a))))
             (cond
               [(pair? near-ally-pts)
                (define ac (centroid-2d near-ally-pts))
                (define away-pt (clamp-point-to-map
                                 (step-away-2d nx ny (point2d-x ac) (point2d-y ac) (min travel-reach 5.0))
                                 SC2-MAP-PLAYABLE-MIN-COORD SC2-MAP-PLAYABLE-MAX-COORD))
                (set! orders (cons (nova-steer-order nid (point2d-x away-pt) (point2d-y away-pt) 0.0 0)
                                   orders))]
               [(pair? ground-enemies)
                ;; Lunge toward nearest ground enemy if strictly beyond current travel reach
                (define-values (nearest-e _bd)
                  (for/fold ([best : Any (car ground-enemies)]
                             [bd : Float (dist-2d nx ny (unit-x (car ground-enemies)) (unit-y (car ground-enemies)))])
                            ([e (in-list (cdr ground-enemies))])
                    (define d (dist-2d nx ny (unit-x e) (unit-y e)))
                    (if (< d bd) (values e d) (values best bd))))
                (define lunge (clamp-to-playable (unit-x nearest-e) (unit-y nearest-e)))
                (set! orders (cons (nova-steer-order nid (point2d-x lunge) (point2d-y lunge) 0.0 1)
                                   orders))]
               [else (void)])]))
        (reverse orders))))

;; =============================================================================
;; 3. Weaponless Disruptor Stand-off & Cooldown Kiting (`kite-disruptor-casters`)
;; =============================================================================

(: compute-friendly-army-anchor (-> (Listof Any) Float Float point2d))
(define (compute-friendly-army-anchor ally-units home-x home-y)
  (define escort-pts : (Listof point2d)
    (for/list : (Listof point2d)
              ([u (in-list ally-units)]
               #:when (and (hash? u)
                           (unit-alive? u)
                           (not (purification-nova-unit? u))
                           (not (disruptor-caster-unit? u))
                           (not (unit-is-structure? u))
                           (not (memq (resolved-unit-type u) '(probe scv drone mule observer)))))
      (point2d (unit-x u) (unit-y u))))
  (if (pair? escort-pts)
      (centroid-2d escort-pts)
      (point2d home-x home-y)))

;; Position friendly weaponless Disruptors (`694`) cleanly:
;; - NEVER emits `attack-unit` or `attack-move`!
;; - Ready casters hold standoff 10.5 - 12.0 tiles from nearest enemy threat.
;; - On-cooldown or active-channeling casters retreat behind army anchor to
;;   13.0 - 15.0 tiles from nearest enemy threat.
(: kite-disruptor-casters
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:exclude-tags (Listof Integer)
         #:emit-hold? Boolean)
        (Listof disruptor-kite-order)))
(define (kite-disruptor-casters ally-units enemy-units
                                #:tracker [tr #f]
                                #:current-frame [current-frame 0]
                                #:home-x [home-x-arg 32.0]
                                #:home-y [home-y-arg 32.0]
                                #:exclude-tags [exclude-tags '()]
                                #:emit-hold? [emit-hold? #f])
  (when tr
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define home-x (->float home-x-arg))
  (define home-y (->float home-y-arg))
  (define valid-threats : (Listof Any)
    (filter (lambda ([e : Any])
              (and (hash? e)
                   (not (purification-nova-unit? e))
                   (unit-alive? e)
                   (not (eq? (dyn-hash-ref e 'hallucination #f) #t))))
            enemy-units))
  (define casters : (Listof Any)
    (filter (lambda ([u : Any])
              (and (hash? u)
                   (disruptor-caster-unit? u)
                   (unit-alive? u)
                   (not (memv (unit-tag-int u) exclude-tags))))
            ally-units))
  (if (or (null? casters) (null? valid-threats))
      '()
      (let ()
        (define anchor (compute-friendly-army-anchor ally-units home-x home-y))
        (define ax (point2d-x anchor))
        (define ay (point2d-y anchor))
        (define orders : (Listof disruptor-kite-order) '())
        (for ([c (in-list casters)])
          (define cid (unit-tag-int c))
          (define cx (unit-x c))
          (define cy (unit-y c))
          ;; Nearest threatening enemy (never Nova)
          (define-values (near-e min-d)
            (for/fold ([best-e : Any (car valid-threats)]
                       [best-d : Float 999999.0])
                      ([e (in-list valid-threats)])
              (define d (dist-2d cx cy (unit-x e) (unit-y e)))
              (if (< d best-d) (values e d) (values best-e best-d))))
          (define ex (unit-x near-e))
          (define ey (unit-y near-e))
          (define on-cd? (caster-on-cooldown? c tr current-frame))
          (define state-sym : Symbol (if on-cd? 'on-cooldown 'ready))
          (define min-band (if on-cd? DISRUPTOR-RETREAT-MIN-DIST DISRUPTOR-STANDOFF-MIN-DIST))
          (define max-band (if on-cd? DISRUPTOR-RETREAT-MAX-DIST DISRUPTOR-STANDOFF-MAX-DIST))
          (define desired-d (* 0.5 (+ min-band max-band))) ; 11.25 ready / 14.0 cooldown

          ;; Unit away-from-enemy vector, blended lightly toward army/home when retreating
          (define-values (awx awy amag) (unit-vec-2d (- cx ex) (- cy ey)))
          (define-values (hmx hmy hmag) (unit-vec-2d (- home-x cx) (- home-y cy)))
          (define-values (acx acy acmag) (unit-vec-2d (- ax cx) (- ay cy)))
          (define base-vx (if (> amag 0.05) awx (if (> hmag 0.05) hmx -1.0)))
          (define base-vy (if (> amag 0.05) awy (if (> hmag 0.05) hmy 0.0)))

          (cond
            ;; Too close -> retreat to exact desired standoff / cooldown distance
            [(< min-d min-band)
             (define-values (rx ry rmag)
               (unit-vec-2d (+ (* 0.85 base-vx) (* 0.15 (if (> acmag 0.05) acx hmx)))
                            (+ (* 0.85 base-vy) (* 0.15 (if (> acmag 0.05) acy hmy)))))
             (define raw-tx (+ ex (* desired-d (if (> rmag 0.05) rx base-vx))))
             (define raw-ty (+ ey (* desired-d (if (> rmag 0.05) ry base-vy))))
             (define tgt (clamp-to-playable raw-tx raw-ty))
             (set! orders (cons (disruptor-kite-order cid 'move (point2d-x tgt) (point2d-y tgt)
                                                      min-d state-sym
                                                      (if on-cd? 'cooldown-retreat 'standoff-retreat))
                                orders))]
            ;; Ready caster too far from enemy fight -> move up ONLY to 11.25 standoff (never attack-unit!)
            [(and (not on-cd?) (> min-d max-band) (<= min-d 30.0))
             (define tgt (clamp-to-playable (+ ex (* desired-d base-vx))
                                            (+ ey (* desired-d base-vy))))
             (set! orders (cons (disruptor-kite-order cid 'move (point2d-x tgt) (point2d-y tgt)
                                                      min-d 'ready 'standoff-approach)
                                orders))]
            ;; On-cooldown caster way behind friendly army (> 17.5 from threat): escort behind anchor at >= 14.0
            [(and on-cd? (> min-d 17.5) (< (dist-2d ex ey ax ay) (- min-d 2.0)))
             (define tgt (clamp-to-playable (+ ex (* desired-d base-vx))
                                            (+ ey (* desired-d base-vy))))
             (set! orders (cons (disruptor-kite-order cid 'move (point2d-x tgt) (point2d-y tgt)
                                                      min-d 'on-cooldown 'cooldown-escort-behind-army)
                                orders))]
            [emit-hold?
             (set! orders (cons (disruptor-kite-order cid 'move cx cy min-d state-sym 'hold-standoff)
                                orders))]))
        (reverse orders))))

;; =============================================================================
;; 4. Defensive Anti-Nova Scatter, Emergency Stalker Blink, & Pre-Split
;; =============================================================================

;; Estimate unit heading vector `(hx, hy)` and forward corridor endpoint `(fx, fy)`
;; for an enemy `DisruptorPhased` Nova ball.
(: infer-enemy-nova-ray
   (-> Any (Option disruptor-tactical-tracker) (Listof Any) (Values Float Float Float Float)))
(define (infer-enemy-nova-ray nova tr ground-allies)
  (define nid (unit-tag-int nova))
  (define nx (unit-x nova))
  (define ny (unit-y nova))
  ;; 1. Explicit vx/vy on hash
  (define evx (if (dyn-hash-has-key? nova 'vx) (safe-finite-real (dyn-hash-ref nova 'vx 0.0) 0.0) 0.0))
  (define evy (if (dyn-hash-has-key? nova 'vy) (safe-finite-real (dyn-hash-ref nova 'vy 0.0) 0.0) 0.0))
  (define-values (ux1 uy1 mag1) (unit-vec-2d evx evy))
  (cond
    [(> mag1 0.05) (values ux1 uy1 1.0 DISRUPTOR-ANTI-NOVA-CONE-RANGE)]
    [else
     ;; 2. Tracker frame-delta velocity
     (define-values (tvx tvy has-tv?)
       (if tr (disruptor-tracker-nova-velocity tr nid) (values 0.0 0.0 #f)))
     (define-values (ux2 uy2 mag2) (unit-vec-2d tvx tvy))
     (cond
       [(and has-tv? (> mag2 0.05)) (values ux2 uy2 1.0 DISRUPTOR-ANTI-NOVA-CONE-RANGE)]
       [(dyn-hash-has-key? nova 'facing)
        (define ang (safe-finite-real (dyn-hash-ref nova 'facing 0.0) 0.0))
        (values (cos ang) (sin ang) 1.0 DISRUPTOR-ANTI-NOVA-CONE-RANGE)]
       [else
        ;; 3. Infer oncoming steering direction toward nearest/highest-value friendly ground clump
        (define-values (sx sy wsum)
          (for/fold ([ax : Float 0.0]
                     [ay : Float 0.0]
                     [ws : Float 0.0])
                    ([a (in-list ground-allies)])
            (define d (dist-2d nx ny (unit-x a) (unit-y a)))
            (if (<= d 13.0)
                (let ([w (/ (unit-nova-replacement-value a) (+ 1.0 (* 0.3 d)))])
                  (values (+ ax (* w (unit-x a))) (+ ay (* w (unit-y a))) (+ ws w)))
                (values ax ay ws))))
        (if (> wsum 0.0)
            (let-values ([(ux3 uy3 mag3) (unit-vec-2d (- (/ sx wsum) nx) (- (/ sy wsum) ny))])
              (values ux3 uy3 (if (> mag3 0.05) 1.0 0.0) DISRUPTOR-ANTI-NOVA-CONE-RANGE))
            (values 0.0 0.0 0.0 0.0))])]))

(struct nova-ray-info
  ([tag : Integer]
   [x : Float]
   [y : Float]
   [hx : Float]
   [hy : Float]
   [has-ray? : Float]
   [ray-len : Float]))

(struct nova-threat-hit
  ([ray : nova-ray-info]
   [dist : Float]
   [ray-dist : Float]))

(: nova-threat-score-for-unit (-> Float Float Float Float Float Float Float Float
                                  (Values Boolean Float Float)))
(define (nova-threat-score-for-unit ux uy nx ny hx hy has-ray? ray-len)
  (define d (dist-2d ux uy nx ny))
  (define fx (+ nx (* hx ray-len)))
  (define fy (+ ny (* hy ray-len)))
  (define ray-d
    (if (> has-ray? 0.5)
        (point-to-segment-dist ux uy nx ny fx fy)
        d))
  (define proj
    (if (> has-ray? 0.5)
        (+ (* (- ux nx) hx) (* (- uy ny) hy))
        0.0))
  (define threatened?
    (or (<= d DISRUPTOR-ANTI-NOVA-DANGER-RADIUS)
        (and (> has-ray? 0.5)
             (>= proj -0.5)
             (<= proj ray-len)
             (<= ray-d 3.25))))
  (values threatened? d ray-d))

;; Choose a safe 7.5-tile Stalker Blink landing destination escaping radial + perpendicular
;; away from the threatening Nova while avoiding all other active enemy Novas.
(: pick-safe-stalker-blink-point (-> Float Float Float Float Float Float Integer (Listof Any) point2d))
(define (pick-safe-stalker-blink-point ux uy nx ny hx hy uid enemy-novas)
  (define-values (rx ry rmag) (unit-vec-2d (- ux nx) (- uy ny)))
  (define px (if (> (+ (* hx hx) (* hy hy)) 0.25) (- hy) (if (> rmag 0.05) (- ry) 0.0)))
  (define py (if (> (+ (* hx hx) (* hy hy)) 0.25) hx (if (> rmag 0.05) rx 1.0)))
  (define cross
    (if (> (+ (* hx hx) (* hy hy)) 0.25)
        (- (* hx (- uy ny)) (* hy (- ux nx)))
        0.0))
  (define p-sign : Float (cond [(> cross 0.05) 1.0] [(< cross -0.05) -1.0] [(even? uid) 1.0] [else -1.0]))
  (define candidates : (Listof point2d)
    (for/list : (Listof point2d) ([dir (in-list (list (cons (+ (* 0.55 rx) (* 0.85 p-sign px))
                                                            (+ (* 0.55 ry) (* 0.85 p-sign py)))
                                                      (cons (* p-sign px) (* p-sign py))
                                                      (cons (* (- p-sign) px) (* (- p-sign) py))
                                                      (cons (if (> rmag 0.05) rx 0.0)
                                                            (if (> rmag 0.05) ry 1.0))
                                                      (cons (+ (* -0.4 hx) (* p-sign px))
                                                            (+ (* -0.4 hy) (* p-sign py)))))])
      (define-values (dx dy dmag) (unit-vec-2d (car dir) (cdr dir)))
      (if (> dmag 0.05)
          (clamp-to-playable (+ ux (* 7.6 dx)) (+ uy (* 7.6 dy)))
          (clamp-to-playable (+ ux 7.6) uy))))
  ;; Pick candidate maximizing minimum distance to all active enemy Novas
  (define-values (best-pt _best-min-d)
    (for/fold ([best-pt : point2d (car candidates)]
               [best-min-d : Float -1.0])
              ([cand (in-list candidates)])
      (define md
        (for/fold ([m : Float 999.0]) ([en (in-list enemy-novas)])
          (min m (dist-2d (point2d-x cand) (point2d-y cand) (unit-x en) (unit-y en)))))
      (if (> md best-min-d)
          (values cand md)
          (values best-pt best-min-d))))
  best-pt)

;; Plan defensive evasion against enemy Disruptors and active Purification Novas:
;; 1. Emergency Stalker Blink (< 2.75 tiles OR imminent forward cone), REGARDLESS of HP!
;; 2. Radial + perpendicular fan split for ground units within danger radius <= 6.5
;;    or forward Nova velocity corridor (ray <= 3.25, ahead <= 9.0), using signed
;;    cross product + deterministic ID parity tie-break to part away from the Nova path.
;; 3. Pre-split spacing repulsion when enemy `Disruptor` (`694`) is within 14.5 tiles
;;    and not known on cooldown, and friendly ground units cluster < 2.8 tiles apart.
(: plan-anti-nova-scatter
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:blink-researched? Boolean
         #:home-x Real
         #:home-y Real)
        (Listof anti-nova-dodge-order)))
(define (plan-anti-nova-scatter ally-units enemy-units
                                 #:tracker [tr #f]
                                 #:current-frame [current-frame 0]
                                 #:blink-researched? [blink-researched? #t]
                                 #:home-x [home-x-arg 32.0]
                                 #:home-y [home-y-arg 32.0])
  (when tr
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define home-x (->float home-x-arg))
  (define home-y (->float home-y-arg))
  ;; Never scatter air units or `disruptor-phased` Novas or buildings!
  (define ground-allies (filter-targetable-ground-units ally-units))
  (define enemy-novas : (Listof Any)
    (filter (lambda ([e : Any]) (and (hash? e) (purification-nova-unit? e))) enemy-units))
  (define ready-enemy-casters : (Listof Any)
    (filter (lambda ([e : Any])
              (and (hash? e)
                   (disruptor-caster-unit? e)
                   (unit-alive? e)
                   (or (not tr)
                       (<= (disruptor-tracker-enemy-cooldown tr (unit-tag-int e) current-frame) 0))
                   (<= (safe-exact-int (dyn-hash-ref e 'nova-cooldown 0) 0) 0)))
            enemy-units))

  (if (or (null? ground-allies)
          (and (null? enemy-novas) (null? ready-enemy-casters)))
      '()
      (let ()
        ;; Precompute rays for all live enemy Novas
        (define nova-rays : (Listof nova-ray-info)
          (for/list : (Listof nova-ray-info) ([en (in-list enemy-novas)])
            (define-values (hx hy has-r? rlen) (infer-enemy-nova-ray en tr ground-allies))
            (nova-ray-info (unit-tag-int en) (unit-x en) (unit-y en) hx hy has-r? rlen)))

        (define orders : (Listof anti-nova-dodge-order) '())
        (for ([u (in-list ground-allies)])
          (define uid (unit-tag-int u))
          (define ux (unit-x u))
          (define uy (unit-y u))

          ;; Find highest-urgency active Nova threatening this unit
          (define best-threat : (Option nova-threat-hit) #f)
          (for ([nr (in-list nova-rays)])
            (define nx (nova-ray-info-x nr))
            (define ny (nova-ray-info-y nr))
            (define hx (nova-ray-info-hx nr))
            (define hy (nova-ray-info-hy nr))
            (define has-r? (nova-ray-info-has-ray? nr))
            (define rlen (nova-ray-info-ray-len nr))
            (define-values (threat? d ray-d)
              (nova-threat-score-for-unit ux uy nx ny hx hy has-r? rlen))
            (when threat?
              (define urgency (min d (+ ray-d 0.8)))
              (define prev-bt best-threat)
              (when (or (not prev-bt)
                        (< urgency (min (nova-threat-hit-dist prev-bt)
                                        (+ (nova-threat-hit-ray-dist prev-bt) 0.8))))
                (set! best-threat (nova-threat-hit nr d ray-d)))))

          (define chosen-threat best-threat)
          (cond
            [chosen-threat
             (define nr (nova-threat-hit-ray chosen-threat))
             (define ntag (nova-ray-info-tag nr))
             (define nx (nova-ray-info-x nr))
             (define ny (nova-ray-info-y nr))
             (define hx (nova-ray-info-hx nr))
             (define hy (nova-ray-info-hy nr))
             (define has-r? (nova-ray-info-has-ray? nr))
             (define d (nova-threat-hit-dist chosen-threat))
             (define ray-d (nova-threat-hit-ray-dist chosen-threat))

             (define blink-cd
               (max (safe-exact-int (dyn-hash-ref u 'blink-cooldown 0) 0)
                    (if tr (disruptor-tracker-stalker-blink-cooldown tr uid current-frame) 0)))
             (define urgent-blink?
               (and (stalker-unit? u)
                    blink-researched?
                    (<= blink-cd 0)
                    (or (< d DISRUPTOR-BLINK-DODGE-RADIUS)
                        (and (> has-r? 0.5) (< d 3.25) (< ray-d 2.2)))))

             (cond
               [urgent-blink?
                (define bpt (pick-safe-stalker-blink-point ux uy nx ny hx hy uid enemy-novas))
                (when tr
                  (hash-set! (disruptor-tactical-tracker-stalker-blinks tr)
                             uid
                             (+ current-frame DISRUPTOR-BLINK-COOLDOWN-FRAMES)))
                (set! orders (cons (anti-nova-dodge-order uid 'blink (point2d-x bpt) (point2d-y bpt)
                                                         ntag d 'emergency-stalker-blink)
                                   orders))]
               [else
                ;; Radial + perpendicular split orthogonal to Nova trajectory
                (define-values (rx0 ry0 rmag) (unit-vec-2d (- ux nx) (- uy ny)))
                (define-values (hmx hmy hmag) (unit-vec-2d (- home-x ux) (- home-y uy)))
                (define rx (if (> rmag 0.05) rx0 (if (> hmag 0.05) hmx -1.0)))
                (define ry (if (> rmag 0.05) ry0 (if (> hmag 0.05) hmy 0.0)))
                ;; Effective forward axis: Nova velocity axis if known, else (n -> u)
                (define ax-hx (if (> has-r? 0.5) hx (- rx)))
                (define ax-hy (if (> has-r? 0.5) hy (- ry)))
                (define px (- ax-hy))
                (define py ax-hx)
                (define cross (- (* ax-hx (- uy ny)) (* ax-hy (- ux nx))))
                (define p-sign : Float
                  (cond
                    [(> cross 0.05) 1.0]
                    [(< cross -0.05) -1.0]
                    [(even? uid) 1.0]
                    [else -1.0]))
                ;; Local neighbor repulsion (< 2.2 tiles) so dodging units don't stack
                (define-values (nsx nsy ncnt)
                  (for/fold ([sx : Float 0.0]
                             [sy : Float 0.0]
                             [c : Integer 0])
                            ([other (in-list ground-allies)]
                             #:when (and (not (= (unit-tag-int other) uid))
                                         (< (dist-2d ux uy (unit-x other) (unit-y other)) 2.2)))
                    (define-values (ox oy omag) (unit-vec-2d (- ux (unit-x other)) (- uy (unit-y other))))
                    (if (> omag 0.05)
                        (values (+ sx ox) (+ sy oy) (+ c 1))
                        (values sx sy c))))
                (define nrep-x (if (> ncnt 0) (/ nsx (->float ncnt)) 0.0))
                (define nrep-y (if (> ncnt 0) (/ nsy (->float ncnt)) 0.0))
                ;; Blend: strong perpendicular fan (0.75) + radial escape (0.55) + de-stack (0.25)
                (define-values (sx sy smag)
                  (unit-vec-2d (+ (* 0.55 rx) (* 0.75 p-sign px) (* 0.25 nrep-x))
                               (+ (* 0.55 ry) (* 0.75 p-sign py) (* 0.25 nrep-y))))
                (define step-dist (if (<= d 4.0) 5.0 4.2))
                (define tgt (clamp-to-playable (+ ux (* step-dist (if (> smag 0.05) sx rx)))
                                               (+ uy (* step-dist (if (> smag 0.05) sy ry)))))
                (set! orders (cons (anti-nova-dodge-order
                                    uid 'split (point2d-x tgt) (point2d-y tgt)
                                    ntag d
                                    (if (<= (abs cross) 0.05)
                                        'centerline-perp-split
                                        'radial-perp-split))
                                   orders))])]

            ;; No live Nova threatening `u`: check ready enemy Disruptor pre-split spacing pressure
            [(pair? ready-enemy-casters)
             (define-values (near-ed near-ed-dist)
               (for/fold ([bd-e : Any (car ready-enemy-casters)]
                          [bd : Float 999.0])
                         ([ed (in-list ready-enemy-casters)])
                 (define d (dist-2d ux uy (unit-x ed) (unit-y ed)))
                 (if (< d bd) (values ed d) (values bd-e bd))))
             (when (<= near-ed-dist DISRUPTOR-PRESPLIT-THREAT-RANGE)
               ;; Check tight friendly ground neighbors within 2.8 tiles (< 3.0 splash diameter)
               (define-values (clx cly cl-cnt)
                 (for/fold ([sx : Float 0.0]
                            [sy : Float 0.0]
                            [c : Integer 0])
                           ([other (in-list ground-allies)]
                            #:when (and (not (= (unit-tag-int other) uid))
                                        (not (disruptor-caster-unit? other))
                                        (< (dist-2d ux uy (unit-x other) (unit-y other)) 2.8)))
                   (values (+ sx (unit-x other)) (+ sy (unit-y other)) (+ c 1))))
               (when (>= cl-cnt 1)
                 (define cx (/ clx (->float cl-cnt)))
                 (define cy (/ cly (->float cl-cnt)))
                 (define-values (rep-x rep-y rmag) (unit-vec-2d (- ux cx) (- uy cy)))
                 (when (> rmag 0.05)
                   (define tgt (clamp-to-playable (+ ux (* 2.2 rep-x))
                                                  (+ uy (* 2.2 rep-y))))
                   (set! orders (cons (anti-nova-dodge-order
                                       uid 'pre-split (point2d-x tgt) (point2d-y tgt)
                                       (unit-tag-int near-ed) near-ed-dist 'disruptor-pre-split)
                                      orders)))))]))
        (reverse orders))))

;; =============================================================================
;; 5. Enemy Disruptor 480-Frame Cooldown & Active-Cast Parent Snipe Evaluator
;; =============================================================================

;; Evaluate all enemy `Disruptor` (`694`) casters:
;; - Tracks active casting window (`active-nova-frames-left` in `~47` frames) and
;;   `480`-frame post-shot cooldown via `tracker` (automatic Nova-spawn matching
;;   within 3.5 tiles + explicit `'orders` / `'nova-cooldown` support).
;; - Computes whether nearby friendly ranged/air units can lethally burst an
;;   active-casting parent Disruptor before its Nova detonates (killing the caster
;;   fizzles the Nova!).
(: evaluate-disruptor-snipe-and-cooldowns
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer)
        (Listof disruptor-snipe-eval)))
(define (evaluate-disruptor-snipe-and-cooldowns ally-units enemy-units
                                                #:tracker [tr #f]
                                                #:current-frame [current-frame 0])
  (when tr
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define enemy-casters : (Listof Any)
    (filter (lambda ([e : Any]) (and (hash? e) (disruptor-caster-unit? e) (unit-alive? e)))
            enemy-units))
  (define enemy-novas : (Listof Any)
    (filter (lambda ([e : Any]) (and (hash? e) (purification-nova-unit? e))) enemy-units))
  (define friendly-shooters : (Listof Any)
    (filter (lambda ([a : Any])
              (and (hash? a)
                   (unit-alive? a)
                   (not (purification-nova-unit? a))
                   (not (disruptor-caster-unit? a))
                   (not (memq (resolved-unit-type a) '(probe scv drone mule observer)))))
            ally-units))

  (for/list : (Listof disruptor-snipe-eval) ([ed (in-list enemy-casters)])
    (define etag (unit-tag-int ed))
    (define ex (unit-x ed))
    (define ey (unit-y ed))
    (define ehp (+ (unit-hp ed 100.0) (unit-shield ed 100.0)))

    (define explicit-cd (safe-exact-int (dyn-hash-ref ed 'nova-cooldown 0) 0))
    (define tr-cd (if tr (disruptor-tracker-enemy-cooldown tr etag current-frame) 0))
    (define tr-nova-left (if tr (disruptor-tracker-enemy-active-nova-frames tr etag current-frame) 0))

    ;; Fallback if no tracker passed: associate nearby live enemy Nova within 3.5 tiles
    (define fallback-nova-left : Integer
      (if (and (= tr-nova-left 0)
               (or (explicit-nova-order? ed)
                   (for/or : Boolean ([en (in-list enemy-novas)])
                     (<= (dist-2d ex ey (unit-x en) (unit-y en)) 3.5))))
          DISRUPTOR-NOVA-LIFETIME-FRAMES
          0))
    (define active-left (max tr-nova-left fallback-nova-left))
    (define cd-rem (max explicit-cd tr-cd (if (> active-left 0) DISRUPTOR-NOVA-COOLDOWN-FRAMES 0)))
    (define state : Symbol
      (cond
        [(> active-left 0) 'active-casting]
        [(> cd-rem 0) 'on-cooldown]
        [else 'ready]))

    ;; Burst window: active Nova frames remaining minus ~5f reaction margin (min 0.25s),
    ;; or 1.6s reference window for DPS assessment.
    (define t-win-sec
      (if (> active-left 0)
          (/ (->float (max 6 (- active-left 5))) 22.4)
          1.6))

    (define-values (att-tags burst-dps total-burst-dmg)
      (for/fold ([tags : (Listof Integer) '()]
                 [dps-acc : Float 0.0]
                 [dmg-acc : Float 0.0])
                ([a (in-list friendly-shooters)])
        (define ut (resolved-unit-type a))
        (define stats (sc2-unit-combat-stats ut))
        (define gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0))
        (define grange (safe-finite-real (hash-ref stats 'ground-range (lambda () 0.0)) 0.0))
        (define spd (max 1.0 (safe-finite-real (hash-ref stats 'speed (lambda () 3.0)) 3.0)))
        (define wperiod (safe-finite-real (hash-ref stats 'weapon-period (lambda () 1.0)) 1.0))
        (define d (dist-2d (unit-x a) (unit-y a) ex ey))
        ;; Exclude ground units currently right inside a live Nova (< 2.75) that must dodge instead
        (define must-dodge-now?
          (and (not (unit-is-flying? a))
               (for/or : Boolean ([en (in-list enemy-novas)])
                 (< (dist-2d (unit-x a) (unit-y a) (unit-x en) (unit-y en))
                    DISRUPTOR-BLINK-DODGE-RADIUS))))
        (if (and (> gdps 0.0)
                 (<= d (+ grange 1.5))
                 (not must-dodge-now?))
            (let* ([walk-sec (if (<= d (+ grange 0.35)) 0.0 (/ (- d (+ grange 0.35)) spd))]
                   [t-eff (max 0.0 (- t-win-sec walk-sec))]
                   [volley-bonus (if (<= d (+ grange 0.35)) (* 0.45 wperiod) 0.0)]
                   [dmg (* gdps (+ t-eff volley-bonus))])
              (if (> dmg 0.0)
                  (values (cons (unit-tag-int a) tags) (+ dps-acc gdps) (+ dmg-acc dmg))
                  (values tags dps-acc dmg-acc)))
            (values tags dps-acc dmg-acc))))

    (define snipe-ok?
      (and (eq? state 'active-casting)
           (pair? att-tags)
           (>= total-burst-dmg (* 1.05 ehp))))

    (disruptor-snipe-eval etag ex ey state cd-rem active-left snipe-ok?
                          (reverse att-tags) burst-dps ehp)))

;; =============================================================================
;; 6. Unified S-Expression Action Orchestrator (`step-disruptor-tactical-micro!`)
;; =============================================================================

;; Execute a full offensive + defensive Disruptor/Nova micro step and emit clean
;; S-expression action commands compatible with `bot-runtime.rkt`:
;;   - `(purification-nova uid tx ty)`
;;   - `(move uid tx ty)`  (Nova homing `733`, caster standoff/retreat `694`, `split`/`pre-split`)
;;   - `(blink uid tx ty)` (emergency Stalker Blink dodge)
;;   - `(attack-unit uid enemy-disruptor-tag)` (lethal active-cast fizzle snipe)
(: step-disruptor-tactical-micro!
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:blink-researched? Boolean
         #:home-x Real
         #:home-y Real)
        (Listof (Listof Any))))
(define (step-disruptor-tactical-micro! ally-units enemy-units
                                        #:tracker [tr-arg #f]
                                        #:current-frame [current-frame 0]
                                        #:blink-researched? [blink-researched? #t]
                                        #:home-x [home-x 32.0]
                                        #:home-y [home-y 32.0])
  (define tr (or tr-arg (make-disruptor-tactical-tracker)))
  (sync-tracker-state! tr ally-units enemy-units current-frame)

  (define cast-plans
    (plan-disruptor-nova-casts ally-units enemy-units
                               #:tracker tr
                               #:current-frame current-frame))
  (define cast-tags (map nova-cast-plan-caster-tag cast-plans))

  (define steer-orders
    (steer-purification-novas ally-units enemy-units
                              #:tracker tr
                              #:current-frame current-frame))
  (define kite-orders
    (kite-disruptor-casters ally-units enemy-units
                            #:tracker tr
                            #:current-frame current-frame
                            #:home-x home-x
                            #:home-y home-y
                            #:exclude-tags cast-tags))
  (define dodge-orders
    (plan-anti-nova-scatter ally-units enemy-units
                            #:tracker tr
                            #:current-frame current-frame
                            #:blink-researched? blink-researched?
                            #:home-x home-x
                            #:home-y home-y))
  (define snipe-evals
    (evaluate-disruptor-snipe-and-cooldowns ally-units enemy-units
                                            #:tracker tr
                                            #:current-frame current-frame))

  ;; Defensive dodges take priority over snipe attacks if the same unit is listed in both
  (define dodging-tags : (Setof Integer)
    (list->set
     (for/list : (Listof Integer) ([d (in-list dodge-orders)])
       (anti-nova-dodge-order-unit-tag d))))

  (define actions : (Listof (Listof Any)) '())
  (: emit! (-> (Listof Any) Void))
  (define (emit! a) (set! actions (cons a actions)))

  (for ([cp (in-list cast-plans)])
    (emit! (list 'purification-nova
                 (nova-cast-plan-caster-tag cp)
                 (nova-cast-plan-tx cp)
                 (nova-cast-plan-ty cp))))
  (for ([so (in-list steer-orders)])
    (emit! (list 'move
                 (nova-steer-order-nova-tag so)
                 (nova-steer-order-tx so)
                 (nova-steer-order-ty so))))
  (for ([ko (in-list kite-orders)]
        #:when (not (set-member? dodging-tags (disruptor-kite-order-unit-tag ko))))
    (emit! (list (disruptor-kite-order-action ko)
                 (disruptor-kite-order-unit-tag ko)
                 (disruptor-kite-order-tx ko)
                 (disruptor-kite-order-ty ko))))
  (for ([do (in-list dodge-orders)])
    (emit! (list (anti-nova-dodge-order-action do)
                 (anti-nova-dodge-order-unit-tag do)
                 (anti-nova-dodge-order-tx do)
                 (anti-nova-dodge-order-ty do))))
  (for ([se (in-list snipe-evals)]
        #:when (disruptor-snipe-eval-snipe-feasible? se))
    (define etag (disruptor-snipe-eval-enemy-tag se))
    (for ([att-id (in-list (disruptor-snipe-eval-attacker-tags se))]
          #:when (not (set-member? dodging-tags att-id)))
      (emit! (list 'attack-unit att-id etag))))

  (reverse actions))
