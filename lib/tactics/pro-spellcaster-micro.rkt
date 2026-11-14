#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/pro-spellcaster-micro.rkt`
;; Pro-Corpus-Calibrated Spellcaster Micro Module (Zerg / Terran / Protoss)
;;
;; Empirically grounded in the #115 pro replay corpus audit (278 LotV games /
;; 556 trajectories / 4,300+ combat spell casts):
;;   1. Universal delta-f = 0 overkill prevention via spatial (`point-claim`)
;;      and single/HP-capped (`unit-claim`) reservation + Disruptor `28f-32f`
;;      (`med=31f`) army-wide Nova stagger.
;;   2. Zerg: Queen Transfusion (`<110` missing = 1 caster, `>=110` = 2) & safe
;;      Creep Tumor; Ravager Fungal->Bile combo, Siege/Static/ForceField shatter,
;;      velocity-led clumps with `0.75`-tile multi-Ravager stagger; Infestor
;;      `0.5`-tile velocity-led Fungal, Neural Parasite w/ nearby army,
;;      Microbial Shroud vs air, non-channeling `<70` energy retreat; Viper
;;      Blinding Cloud, Abduct into `>=4` allies, Parasitic Bomb anti-`824`
;;      stack guard, safe Consume `<60` (`hp > 450`); Corruptor Caustic Spray
;;      when clear of air/AA threats within `11.0` tiles.
;;   3. Terran: Ghost EMP, close-threat-guarded (`0` enemies `<4.5`) HP-capped
;;      Snipe + `34f` channel movement/kite lockout, detector-guarded Cloak;
;;      Raven Interference Matrix, Anti-Armor Missile (`>=5` clump & `>=6`
;;      allies), Auto-Turret; Battlecruiser HP-capped Yamato & `<32%` emergency
;;      Tactical Jump home.
;;   4. Protoss: Sentry `246f` Guardian Shield, `~27f` post-GS Force Field
;;      avoiding `<1.8`-tile ally traps, early `4:00-4:15` Hallucination
;;      Phoenix scout / Archon tank; High Templar Psi Storm (`<=1` ally in `1.5`),
;;      Feedback priority (`Infestor->Viper->Ghost->Medivac->HT->Raven->Oracle`),
;;      post-storm dry-HT `<50` Archon pair merge vs unpaired kite; Oracle
;;      strict 1-command/frame mutex (Revelation -> Pulsar Beam ON w/ `>=60f`
;;      minimum dwell before OFF -> Stasis Ward only when beam OFF).
;;
;; Architecture Boundary:
;;   Depends ONLY on typed Racket stdlib and `../sc2-game-constants.rkt`
;;   (plus local `dyn-hash-ops` typed bridge). Never requires `tactics-sim.rkt`,
;;   `bot-runtime.rkt`, `unit-mode-micro.rkt`, or `transport-drop-micro.rkt`.
;; =============================================================================

(require racket/flonum
         racket/list
         racket/math
         racket/string
         racket/vector
         typed/racket/unsafe
         "../sc2-game-constants.rkt")

;; Safe bridge for inspecting heterogeneous untyped/mutable/immutable hashes.
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
 ;; Pro-calibrated constants
 PSI-STORM-CLAIM-RADIUS
 PSI-STORM-CLAIM-TTL
 EMP-CLAIM-RADIUS
 EMP-CLAIM-TTL
 FUNGAL-CLAIM-RADIUS
 FUNGAL-CLAIM-TTL
 BLINDING-CLOUD-CLAIM-RADIUS
 BLINDING-CLOUD-CLAIM-TTL
 GUARDIAN-SHIELD-CLAIM-RADIUS
 GUARDIAN-SHIELD-CLAIM-TTL
 ORACLE-REVELATION-CLAIM-RADIUS
 ORACLE-REVELATION-CLAIM-TTL
 FORCE-FIELD-CLAIM-RADIUS
 FORCE-FIELD-CLAIM-TTL
 CORROSIVE-BILE-CLAIM-RADIUS
 CORROSIVE-BILE-CLAIM-TTL
 CORROSIVE-BILE-STAGGER-OFFSET
 CORROSIVE-BILE-COOLDOWN-FRAMES
 ANTI-ARMOR-CLAIM-RADIUS
 ANTI-ARMOR-CLAIM-TTL
 MICROBIAL-SHROUD-CLAIM-RADIUS
 MICROBIAL-SHROUD-CLAIM-TTL
 STASIS-WARD-CLAIM-RADIUS
 STASIS-WARD-CLAIM-TTL
 UNIT-SPELL-CLAIM-TTL
 SNIPE-CHANNEL-LOCKOUT-FRAMES
 SNIPE-DAMAGE
 YAMATO-DAMAGE
 DISRUPTOR-NOVA-STAGGER-MIN-FRAMES
 DISRUPTOR-NOVA-STAGGER-MAX-FRAMES
 DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES
 ORACLE-PULSAR-BEAM-MIN-DWELL-FRAMES
 ORACLE-PULSAR-BEAM-ZERO-TARGET-DWELL-FRAMES
 SENTRY-FORCE-FIELD-POST-GS-DELAY-FRAMES
 HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES

 ;; Data structures
 (struct-out spell-directive)
 (struct-out point-claim)
 (struct-out unit-claim)
 (struct-out spell-claims)
 make-spell-claims

 ;; Claim, lockout & stagger primitives
 prune-spell-claims!
 spell-point-claimed?
 spell-claim-point?!
 spell-unit-claim-count
 spell-claim-unit?!
 disruptor-nova-stagger-ready?
 record-disruptor-nova-cast!
 filter-staggered-nova-actions
 lock-ghost-snipe-channel!
 snipe-channel-locked?
 can-ghost-move-or-kite?
 spellcaster-channel-protected?
 oracle-pulsar-beam-active?
 spell-directive->sexp

 ;; Race planners & top-level orchestrators
 plan-zerg-spellcaster-micro
 plan-terran-spellcaster-micro
 plan-protoss-spellcaster-micro
 step-pro-spellcaster-micro!
 step-pro-spellcaster-sexps!)

;; -----------------------------------------------------------------------------
;; 1. Calibrated Constants (#115 Pro Corpus)
;; -----------------------------------------------------------------------------

(define PSI-STORM-CLAIM-RADIUS : Float 2.0)
(define PSI-STORM-CLAIM-TTL : Integer 56)

(define EMP-CLAIM-RADIUS : Float 2.0)
(define EMP-CLAIM-TTL : Integer 24)

(define FUNGAL-CLAIM-RADIUS : Float 2.25)
(define FUNGAL-CLAIM-TTL : Integer 32)

(define BLINDING-CLOUD-CLAIM-RADIUS : Float 2.0)
(define BLINDING-CLOUD-CLAIM-TTL : Integer 48)

(define GUARDIAN-SHIELD-CLAIM-RADIUS : Float 5.0)
(define GUARDIAN-SHIELD-CLAIM-TTL : Integer 246)

(define ORACLE-REVELATION-CLAIM-RADIUS : Float 6.0)
(define ORACLE-REVELATION-CLAIM-TTL : Integer 448)

(define FORCE-FIELD-CLAIM-RADIUS : Float 1.5)
(define FORCE-FIELD-CLAIM-TTL : Integer 32)

(define CORROSIVE-BILE-CLAIM-RADIUS : Float 0.55)
(define CORROSIVE-BILE-CLAIM-TTL : Integer 36)
(define CORROSIVE-BILE-STAGGER-OFFSET : Float 0.75)
(define CORROSIVE-BILE-COOLDOWN-FRAMES : Integer 157)

(define ANTI-ARMOR-CLAIM-RADIUS : Float 2.5)
(define ANTI-ARMOR-CLAIM-TTL : Integer 48)

(define MICROBIAL-SHROUD-CLAIM-RADIUS : Float 3.5)
(define MICROBIAL-SHROUD-CLAIM-TTL : Integer 48)

(define STASIS-WARD-CLAIM-RADIUS : Float 2.5)
(define STASIS-WARD-CLAIM-TTL : Integer 64)

(define UNIT-SPELL-CLAIM-TTL : Integer 36)

(define SNIPE-CHANNEL-LOCKOUT-FRAMES : Integer 34)
(define SNIPE-DAMAGE : Float 170.0)
(define YAMATO-DAMAGE : Float 240.0)

(define DISRUPTOR-NOVA-STAGGER-MIN-FRAMES : Integer 28)
(define DISRUPTOR-NOVA-STAGGER-MAX-FRAMES : Integer 32)
(define DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES : Integer 31)

(define ORACLE-PULSAR-BEAM-MIN-DWELL-FRAMES : Integer 60)
(define ORACLE-PULSAR-BEAM-ZERO-TARGET-DWELL-FRAMES : Integer 111)
(define SENTRY-FORCE-FIELD-POST-GS-DELAY-FRAMES : Integer 27)
(define HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES : Integer 33)

;; -----------------------------------------------------------------------------
;; 2. Typed Directives & Claim Registry
;; -----------------------------------------------------------------------------

;; Typed spellcaster tactical order (`target-mode`: `'none` `'point` `'unit` `'pair` `'move` `'kite`).
(struct spell-directive
  ([caster-tag : Integer]
   [caster-type : Symbol]
   [ability : Symbol]
   [target-mode : Symbol]
   [target-tag : Integer]
   [target-x : Float]
   [target-y : Float]
   [pattern-name : Symbol])
  #:transparent)

;; Spatial AoE reservation record preventing delta-f = 0 overlapping casts.
(struct point-claim
  ([ability : Symbol]
   [x : Float]
   [y : Float]
   [radius : Float]
   [frame : Integer]
   [expires-frame : Integer])
  #:transparent)

;; Single-target reservation record preventing delta-f = 0 overkill casts.
(struct unit-claim
  ([ability : Symbol]
   [target-tag : Integer]
   [caster-tag : Integer]
   [frame : Integer]
   [expires-frame : Integer])
  #:transparent)

;; Mutable army-wide spell claim, cooldown, channel-lockout, and dwell state.
(struct spell-claims
  ([point-claims : (Listof point-claim)]
   [unit-claims : (Listof unit-claim)]
   [last-disruptor-nova-frame : Integer]
   [last-guardian-shield-frame : Integer]
   [last-hallucination-phoenix-frame : Integer]
   [ghost-snipe-unlock : (HashTable Integer Integer)]
   [oracle-beam-start : (HashTable Integer Integer)]
   [ravager-bile-ready-frame : (HashTable Integer Integer)]
   [ht-storm-frame : (HashTable Integer Integer)]
   [ht-merge-lock-until : (HashTable Integer Integer)]
   [ghost-cloak-frame : (HashTable Integer Integer)])
  #:mutable
  #:transparent)

;; Construct an empty `spell-claims` state for multi-frame micro tracking.
(: make-spell-claims (-> spell-claims))
(define (make-spell-claims)
  (spell-claims
   '()
   '()
   -10000
   -10000
   -10000
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)))

;; -----------------------------------------------------------------------------
;; 3. Internal Math, Normalization & Safe Unit Hash Inspectors
;; -----------------------------------------------------------------------------

(: safe-fl (-> Any Float Float))
(define (safe-fl v default)
  (if (real? v)
      (let ([f (real->double-flonum v)])
        (if (or (nan? f) (infinite? f)) default f))
      default))

(: safe-int (-> Any Integer Integer))
(define (safe-int v default)
  (cond
    [(exact-integer? v) v]
    [(real? v)
     (let ([f (real->double-flonum v)])
       (if (or (nan? f) (infinite? f))
           default
           (exact-round f)))]
    [else default]))

(: safe-sym (-> Any Symbol Symbol))
(define (safe-sym v default)
  (cond
    [(symbol? v) v]
    [(string? v)
     (let ([t (string-trim v)])
       (if (zero? (string-length t))
           default
           (string->symbol (string-downcase t))))]
    [else default]))

(: ->float (-> Real Float))
(define (->float x)
  (real->double-flonum x))

(: dist2 (-> Float Float Float Float Float))
(define (dist2 x1 y1 x2 y2)
  (define dx (- x1 x2))
  (define dy (- y1 y2))
  (flsqrt (+ (* dx dx) (* dy dy))))

(: clamp-coord (-> Float Float))
(define (clamp-coord c)
  (min SC2-MAP-SAFE-MAX-COORD (max SC2-MAP-SAFE-MIN-COORD c)))

(: safe-ceil-div (-> Float Float Integer))
(define (safe-ceil-div num den)
  (define d (max 1.0 den))
  (define n (max 0.0 num))
  (if (<= n 0.0)
      1
      (let* ([q (/ n d)]
             [i (exact-floor q)])
        (max 1 (if (< (* d (->float i)) n) (+ i 1) i)))))

(: sum-units-fl (-> (Listof Any) (-> Any Float) Float))
(define (sum-units-fl units fn)
  (for/fold ([tot : Float 0.0])
            ([u (in-list units)])
    (+ tot (fn u))))

(: sum-hp-within (-> (Listof Any) Float Float Float Float))
(define (sum-hp-within units cx cy rad)
  (for/fold ([tot : Float 0.0])
            ([e (in-list units)])
    (if (and (hash? e) (<= (dist2 cx cy (uh-x e) (uh-y e)) rad))
        (+ tot (uh-total-hp e))
        tot)))

(: canonical-spell-key (-> Symbol Symbol))
(define (canonical-spell-key ab)
  (case ab
    [(emp) 'emp-round]
    [(psistorm) 'psi-storm]
    [(forcefield) 'force-field]
    [(snipe) 'steady-targeting]
    [(yamato yamato-gun) 'yamato-cannon]
    [(transfuse) 'transfusion]
    [(consume viper-consume-structure) 'viper-consume]
    [(revelation) 'oracle-revelation]
    [(oracle-stasis-ward build-stasis-trap) 'stasis-ward]
    [(pulsar-beam) 'pulsar-beam-on]
    [(spread-creep-tumor build-creep-tumor) 'spawn-creep-tumor]
    [(build-auto-turret) 'auto-turret]
    [else ab]))

(: canonical-sexp-spell (-> Symbol Symbol))
(define (canonical-sexp-spell ab)
  (case ab
    [(yamato-gun yamato) 'yamato-cannon]
    [(snipe) 'steady-targeting]
    [(transfuse) 'transfusion]
    [(revelation) 'oracle-revelation]
    [(emp) 'emp-round]
    [(consume) 'viper-consume]
    [else ab]))

(: uh-tag (-> Any Integer))
(define (uh-tag u)
  (define tid (safe-int (dyn-hash-ref u 'id 0) 0))
  (if (> tid 0) tid (safe-int (dyn-hash-ref u 'tag 0) 0)))

(: uh-type (-> Any Symbol))
(define (uh-type u)
  (sc2-canonical-unit-sym (safe-sym (dyn-hash-ref u 'type 'unknown) 'unknown)))

(: uh-raw-type (-> Any Symbol))
(define (uh-raw-type u)
  (safe-sym (dyn-hash-ref u 'type 'unknown) 'unknown))

(: uh-x (-> Any Float))
(define (uh-x u)
  (safe-fl (dyn-hash-ref u 'x 0.0) 0.0))

(: uh-y (-> Any Float))
(define (uh-y u)
  (safe-fl (dyn-hash-ref u 'y 0.0) 0.0))

(: uh-vx (-> Any Float))
(define (uh-vx u)
  (safe-fl (dyn-hash-ref u 'vx 0.0) 0.0))

(: uh-vy (-> Any Float))
(define (uh-vy u)
  (safe-fl (dyn-hash-ref u 'vy 0.0) 0.0))

(: uh-energy (-> Any Float))
(define (uh-energy u)
  (safe-fl (dyn-hash-ref u 'energy 0.0) 0.0))

(: uh-shields (-> Any Float))
(define (uh-shields u)
  (if (dyn-hash-has-key? u 'shield)
      (safe-fl (dyn-hash-ref u 'shield 0.0) 0.0)
      (safe-fl (dyn-hash-ref u 'shields 0.0) 0.0)))

;; Extract total current HP (hull + shields) supporting both live combined
;; `sc2-protobuf-ws` hashes (`'hull-hp` + combined `'hp`) and synthetic split hashes.
(: uh-total-hp (-> Any Float))
(define (uh-total-hp u)
  (define stats (sc2-unit-combat-stats (uh-type u)))
  (define t-hull (safe-fl (hash-ref stats 'max-hp (lambda () 0.0)) 0.0))
  (define sh (uh-shields u))
  (cond
    [(dyn-hash-has-key? u 'hull-hp)
     (if (dyn-hash-has-key? u 'hp)
         (safe-fl (dyn-hash-ref u 'hp 0.0) 0.0)
         (+ (safe-fl (dyn-hash-ref u 'hull-hp 0.0) 0.0) sh))]
    [else
     (define raw-hp (safe-fl (dyn-hash-ref u 'hp 0.0) 0.0))
     (define has-max? (dyn-hash-has-key? u 'max-hp))
     (define raw-max (safe-fl (dyn-hash-ref u 'max-hp 0.0) 0.0))
     (define already-combined?
       (and (> sh 0.0)
            (or (and (> t-hull 0.0) (> raw-hp (+ t-hull 0.5)))
                (and (<= t-hull 0.0) has-max? (> raw-max (+ sh 0.5)) (>= raw-hp sh)))))
     (if already-combined? raw-hp (+ raw-hp sh))]))

(: uh-max-total-hp (-> Any Float))
(define (uh-max-total-hp u)
  (define stats (sc2-unit-combat-stats (uh-type u)))
  (define t-hull (safe-fl (hash-ref stats 'max-hp (lambda () 0.0)) 0.0))
  (define t-shield (safe-fl (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
  (define table-tot (+ t-hull t-shield))
  (cond
    [(dyn-hash-has-key? u 'hull-hp)
     (define raw-max (safe-fl (dyn-hash-ref u 'max-hp 0.0) 0.0))
     (if (> raw-max 0.0) raw-max table-tot)]
    [(dyn-hash-has-key? u 'max-hp)
     (define raw-max (safe-fl (dyn-hash-ref u 'max-hp 0.0) 0.0))
     (define sh (uh-shields u))
     (if (and (> (+ t-shield sh) 0.0)
              (> t-hull 0.0)
              (<= raw-max (+ t-hull 0.5)))
         (+ raw-max (max t-shield sh))
         (max raw-max (uh-total-hp u)))]
    [(> table-tot 0.0) (max table-tot (uh-total-hp u))]
    [else (uh-total-hp u)]))

(: uh-missing-hp (-> Any Float))
(define (uh-missing-hp u)
  (max 0.0 (- (uh-max-total-hp u) (uh-total-hp u))))

(: uh-hp-ratio (-> Any Float))
(define (uh-hp-ratio u)
  (define m (uh-max-total-hp u))
  (if (<= m 0.0) 1.0 (min 1.0 (max 0.0 (/ (uh-total-hp u) m)))))

(: buff-entry->sym (-> Any (Option Symbol)))
(define (buff-entry->sym b)
  (cond
    [(symbol? b) b]
    [(string? b) (string->symbol (string-downcase (string-trim b)))]
    [(exact-integer? b)
     (case b
       [(17) 'fungal-growth]
       [(18) 'guardian-shield]
       [(22) 'neural-parasite]
       [(28) 'transfusion]
       [(49) 'oracle-revelation]
       [(56) 'oracle-weapon]
       [(83) 'blinding-cloud]
       [(132) 'parasitic-bomb]
       [else #f])]
    [else #f]))

(: uh-buffs (-> Any (Listof Symbol)))
(define (uh-buffs u)
  (define raw (dyn-hash-ref u 'buffs '()))
  (define items : (Listof Any)
    (cond
      [(list? raw) raw]
      [(vector? raw) (vector->list raw)]
      [else '()]))
  (for/fold ([acc : (Listof Symbol) '()])
            ([b (in-list items)])
    (define s (buff-entry->sym b))
    (if s (cons s acc) acc)))

(: uh-has-buff? (-> Any Symbol Boolean))
(define (uh-has-buff? u target-buff)
  (and (memq target-buff (uh-buffs u)) #t))

(: uh-cloaked? (-> Any Boolean))
(define (uh-cloaked? u)
  (or (eq? (dyn-hash-ref u 'cloaked #f) #t)
      (let ([cv (dyn-hash-ref u 'cloak 0)])
        (or (eq? cv #t)
            (and (exact-integer? cv) (or (= cv 1) (= cv 2)))
            (and (memq (safe-sym cv 'unknown) '(cloaked cloaked-detected)) #t)))))

(: uh-burrowed? (-> Any Boolean))
(define (uh-burrowed? u)
  (or (eq? (dyn-hash-ref u 'is-burrowed #f) #t)
      (eq? (dyn-hash-ref u 'burrowed #f) #t)
      (and (memq (uh-raw-type u)
                 '(lurker-burrowed lurker-mp-burrowed widow-mine-burrowed
                   infestor-burrowed roach-burrowed zergling-burrowed
                   baneling-burrowed hydralisk-burrowed ultralisk-burrowed
                   queen-burrowed drone-burrowed swarm-host-burrowed))
           #t)))

(: uh-hallucination? (-> Any Boolean))
(define (uh-hallucination? u)
  (or (eq? (dyn-hash-ref u 'is-hallucination #f) #t)
      (eq? (dyn-hash-ref u 'hallucination #f) #t)))

(: uh-flying? (-> Any Boolean))
(define (uh-flying? u)
  (or (eq? (dyn-hash-ref u 'flying? #f) #t)
      (eq? (dyn-hash-ref u 'is-flying #f) #t)
      (sc2-unit-is-flying-sym? (uh-type u))))

(: uh-detector? (-> Any Boolean))
(define (uh-detector? u)
  (or (eq? (dyn-hash-ref u 'is-detector #f) #t)
      (eq? (dyn-hash-ref u 'detector? #f) #t)
      (sc2-unit-is-detector-sym? (uh-type u))
      (and (memq (uh-type u) SC2-MOBILE-DETECTOR-SYMS) #t)
      (and (memq (uh-type u) SC2-STATIC-DETECTOR-SYMS) #t)))

(: uh-order-ids (-> Any (Listof Integer)))
(define (uh-order-ids u)
  (define top-ab (safe-int (dyn-hash-ref u 'order-ability-id 0) 0))
  (define orders-raw (dyn-hash-ref u 'orders '()))
  (define lst : (Listof Any)
    (cond
      [(list? orders-raw) orders-raw]
      [(vector? orders-raw) (vector->list orders-raw)]
      [else '()]))
  (define order-ids
    (for/fold ([acc : (Listof Integer) '()])
              ([ord (in-list lst)])
      (define ab
        (cond
          [(exact-integer? ord) ord]
          [(hash? ord)
           (let ([id1 (safe-int (dyn-hash-ref ord 'ability-id 0) 0)])
             (if (> id1 0) id1 (safe-int (dyn-hash-ref ord 'ability_id 0) 0)))]
          [else 0]))
      (if (> ab 0) (cons ab acc) acc)))
  (if (> top-ab 0) (cons top-ab order-ids) order-ids))

;; Returns `#t` if unit is currently executing a protected channel or Archon morph order.
(: spellcaster-channel-protected? (-> Any Boolean))
(define (spellcaster-channel-protected? u)
  (for/or : Boolean ([ab (in-list (uh-order-ids u))])
    (define cls (sc2-order-protection-class ab))
    (or (eq? cls 'channel) (eq? cls 'morph))))

(: velocity-lead-xy (-> Any Float (Values Float Float)))
(define (velocity-lead-xy u max-lead)
  (define vx (uh-vx u))
  (define vy (uh-vy u))
  (define spd2 (+ (* vx vx) (* vy vy)))
  (if (<= spd2 0.0625) ;; speed <= 0.25 tiles/sec
      (values (uh-x u) (uh-y u))
      (let* ([spd (flsqrt spd2)]
             [lead (min max-lead (* 0.25 spd))])
        (values (clamp-coord (+ (uh-x u) (* lead (/ vx spd))))
                (clamp-coord (+ (uh-y u) (* lead (/ vy spd))))))))

;; -----------------------------------------------------------------------------
;; 4. Universal delta-f = 0 Claims, Lockouts & Disruptor Stagger Primitives
;; -----------------------------------------------------------------------------

(: spell-point-default-radius (-> Symbol Float))
(define (spell-point-default-radius ab)
  (case (canonical-spell-key ab)
    [(psi-storm) PSI-STORM-CLAIM-RADIUS]
    [(emp-round) EMP-CLAIM-RADIUS]
    [(fungal-growth) FUNGAL-CLAIM-RADIUS]
    [(blinding-cloud) BLINDING-CLOUD-CLAIM-RADIUS]
    [(guardian-shield) GUARDIAN-SHIELD-CLAIM-RADIUS]
    [(oracle-revelation) ORACLE-REVELATION-CLAIM-RADIUS]
    [(force-field) FORCE-FIELD-CLAIM-RADIUS]
    [(corrosive-bile) CORROSIVE-BILE-CLAIM-RADIUS]
    [(anti-armor-missile) ANTI-ARMOR-CLAIM-RADIUS]
    [(microbial-shroud) MICROBIAL-SHROUD-CLAIM-RADIUS]
    [(stasis-ward) STASIS-WARD-CLAIM-RADIUS]
    [(spawn-creep-tumor) 3.5]
    [(auto-turret) 2.0]
    [else 2.0]))

(: spell-point-default-ttl (-> Symbol Integer))
(define (spell-point-default-ttl ab)
  (case (canonical-spell-key ab)
    [(psi-storm) PSI-STORM-CLAIM-TTL]
    [(emp-round) EMP-CLAIM-TTL]
    [(fungal-growth) FUNGAL-CLAIM-TTL]
    [(blinding-cloud) BLINDING-CLOUD-CLAIM-TTL]
    [(guardian-shield) GUARDIAN-SHIELD-CLAIM-TTL]
    [(oracle-revelation) ORACLE-REVELATION-CLAIM-TTL]
    [(force-field) FORCE-FIELD-CLAIM-TTL]
    [(corrosive-bile) CORROSIVE-BILE-CLAIM-TTL]
    [(anti-armor-missile) ANTI-ARMOR-CLAIM-TTL]
    [(microbial-shroud) MICROBIAL-SHROUD-CLAIM-TTL]
    [(stasis-ward) STASIS-WARD-CLAIM-TTL]
    [(spawn-creep-tumor auto-turret) 64]
    [else 32]))

(: prune-hash-below! (-> (HashTable Integer Integer) Integer Void))
(define (prune-hash-below! ht frame)
  (define stale
    (for/fold ([ks : (Listof Integer) '()])
              ([(k v) (in-hash ht)])
      (if (<= v frame) (cons k ks) ks)))
  (for ([k (in-list stale)])
    (hash-remove! ht k)))

;; Prune all expired spatial point claims, unit claims, and temporary windows.
(: prune-spell-claims! (-> spell-claims Integer Void))
(define (prune-spell-claims! claims current-frame)
  (set-spell-claims-point-claims!
   claims
   (for/list : (Listof point-claim)
             ([c (in-list (spell-claims-point-claims claims))]
              #:when (> (point-claim-expires-frame c) current-frame))
     c))
  (set-spell-claims-unit-claims!
   claims
   (for/list : (Listof unit-claim)
             ([c (in-list (spell-claims-unit-claims claims))]
              #:when (> (unit-claim-expires-frame c) current-frame))
     c))
  (prune-hash-below! (spell-claims-ghost-snipe-unlock claims) current-frame)
  (prune-hash-below! (spell-claims-ht-merge-lock-until claims) current-frame)
  (prune-hash-below! (spell-claims-ravager-bile-ready-frame claims) current-frame))

;; Returns `#t` if an active claim of `ability` covers `(x, y)` at `current-frame`.
;; Supports `(claims ability x y frame)` and `(claims ability x y radius frame)`.
(: spell-point-claimed? (->* (spell-claims Symbol Real Real Real) ((Option Real) #:radius (Option Real)) Boolean))
(define (spell-point-claimed? claims ability x y arg5 [arg6 #f] #:radius [kw-radius #f])
  (define ab (canonical-spell-key ability))
  (define fx (safe-fl x 0.0))
  (define fy (safe-fl y 0.0))
  (define-values (rad frame)
    (cond
      [arg6 (values (safe-fl arg5 (spell-point-default-radius ab)) (safe-int arg6 0))]
      [(exact-integer? arg5)
       (values (if kw-radius (safe-fl kw-radius (spell-point-default-radius ab)) (spell-point-default-radius ab))
               arg5)]
      [else (values (spell-point-default-radius ab) (safe-int arg5 0))]))
  (for/or : Boolean ([c (in-list (spell-claims-point-claims claims))])
    (and (eq? (point-claim-ability c) ab)
         (> (point-claim-expires-frame c) frame)
         (< (dist2 fx fy (point-claim-x c) (point-claim-y c))
            (max rad (point-claim-radius c))))))

;; Atomically reserve an AoE cast point `(x, y)` if no active claim overlaps.
;; Supports 5-arg `(claims ab x y frame)`, 6-arg `(claims ab x y radius frame)`,
;; 7-arg `(claims ab x y radius frame ttl)`, or keyword overrides.
(: spell-claim-point?!
   (->* (spell-claims Symbol Real Real)
        ((Option Real) (Option Real) (Option Integer) #:radius (Option Real) #:frame (Option Integer) #:ttl (Option Integer))
        Boolean))
(define (spell-claim-point?! claims ability x y [arg5 #f] [arg6 #f] [arg7 #f]
                             #:radius [kw-radius #f] #:frame [kw-frame #f] #:ttl [kw-ttl #f])
  (define ab (canonical-spell-key ability))
  (define fx (safe-fl x 0.0))
  (define fy (safe-fl y 0.0))
  (define-values (rad frame ttl)
    (cond
      [(and arg5 arg6 arg7)
       (values (safe-fl arg5 (spell-point-default-radius ab))
               (safe-int arg6 0)
               (max 1 (safe-int arg7 (spell-point-default-ttl ab))))]
      [(and arg5 arg6)
       (values (safe-fl arg5 (spell-point-default-radius ab))
               (safe-int arg6 0)
               (if kw-ttl (max 1 kw-ttl) (spell-point-default-ttl ab)))]
      [arg5
       (values (if kw-radius (safe-fl kw-radius (spell-point-default-radius ab)) (spell-point-default-radius ab))
               (if kw-frame kw-frame (safe-int arg5 0))
               (if kw-ttl (max 1 kw-ttl) (spell-point-default-ttl ab)))]
      [else
       (values (if kw-radius (safe-fl kw-radius (spell-point-default-radius ab)) (spell-point-default-radius ab))
               (or kw-frame 0)
               (if kw-ttl (max 1 kw-ttl) (spell-point-default-ttl ab)))]))
  (cond
    [(spell-point-claimed? claims ab fx fy rad frame) #f]
    [else
     (define active
       (for/list : (Listof point-claim)
                 ([c (in-list (spell-claims-point-claims claims))]
                  #:when (> (point-claim-expires-frame c) frame))
         c))
     (set-spell-claims-point-claims!
      claims
      (cons (point-claim ab fx fy rad frame (+ frame ttl)) active))
     (when (eq? ab 'guardian-shield)
       (set-spell-claims-last-guardian-shield-frame! claims frame))
     #t]))

;; Count active unit-target claims for `(ability, target-tag)` at `current-frame`.
(: spell-unit-claim-count (-> spell-claims Symbol Integer Integer Integer))
(define (spell-unit-claim-count claims ability target-tag current-frame)
  (define ab (canonical-spell-key ability))
  (for/sum : Integer ([c (in-list (spell-claims-unit-claims claims))])
    (if (and (eq? (unit-claim-ability c) ab)
             (= (unit-claim-target-tag c) target-tag)
             (> (unit-claim-expires-frame c) current-frame))
        1
        0)))

;; Determine effective concurrent caster cap on `target-tag` per #115/#117 rules.
(: unit-claim-effective-cap (-> Symbol Real Real (Option Positive-Integer) Boolean Positive-Integer))
(define (unit-claim-effective-cap ab target-hp missing-hp explicit-max allow-multi?)
  (cond
    [explicit-max explicit-max]
    [(eq? ab 'steady-targeting)
     (define eff (if (> (safe-fl target-hp 0.0) 0.0) (safe-fl target-hp SNIPE-DAMAGE) SNIPE-DAMAGE))
     (define c (safe-ceil-div eff SNIPE-DAMAGE))
     (if (> c 0) c 1)]
    [(eq? ab 'yamato-cannon)
     (define eff (if (> (safe-fl target-hp 0.0) 0.0) (safe-fl target-hp YAMATO-DAMAGE) YAMATO-DAMAGE))
     (define c (safe-ceil-div eff YAMATO-DAMAGE))
     (if (> c 0) c 1)]
    [(eq? ab 'transfusion)
     (if (and allow-multi? (>= (safe-fl missing-hp 0.0) 110.0)) 2 1)]
    [else 1]))

;; Atomically reserve a single/HP-capped unit-target spell cast on `target-tag`.
;; Enforces `target-tag > 0` and delta-f = 0 / overkill limits.
(: spell-claim-unit?!
   (->* (spell-claims Symbol Integer Integer)
        (Integer #:caster-tag Integer #:max-casters (Option Positive-Integer) #:target-hp Real #:missing-hp Real #:allow-multi? Boolean)
        Boolean))
(define (spell-claim-unit?! claims ability target-tag current-frame
                            [ttl UNIT-SPELL-CLAIM-TTL]
                            #:caster-tag [caster-tag 0]
                            #:max-casters [max-casters #f]
                            #:target-hp [target-hp 0.0]
                            #:missing-hp [missing-hp 0.0]
                            #:allow-multi? [allow-multi? #t])
  (define ab (canonical-spell-key ability))
  (cond
    [(<= target-tag 0) #f]
    [else
     (define active
       (for/list : (Listof unit-claim)
                 ([c (in-list (spell-claims-unit-claims claims))]
                  #:when (> (unit-claim-expires-frame c) current-frame))
         c))
     (define matching
       (for/list : (Listof unit-claim)
                 ([c (in-list active)]
                  #:when (and (eq? (unit-claim-ability c) ab)
                              (= (unit-claim-target-tag c) target-tag)))
         c))
     (define cap (unit-claim-effective-cap ab target-hp missing-hp max-casters allow-multi?))
     (define same-caster-this-frame?
       (and (> caster-tag 0)
            (for/or : Boolean ([c (in-list matching)])
              (and (= (unit-claim-caster-tag c) caster-tag)
                   (= (unit-claim-frame c) current-frame)))))
     (cond
       [same-caster-this-frame? #f]
       [(>= (length matching) cap) #f]
       [else
        (set-spell-claims-unit-claims!
         claims
         (cons (unit-claim ab target-tag caster-tag current-frame (+ current-frame (max 1 ttl)))
               active))
        #t])]))

;; Record an army-wide Disruptor Purification Nova cast at `current-frame`.
(: record-disruptor-nova-cast! (-> spell-claims Integer Void))
(define (record-disruptor-nova-cast! claims current-frame)
  (set-spell-claims-last-disruptor-nova-frame! claims current-frame))

;; Check #115 `28f-32f` (`med=31f`) army-wide Disruptor Purification Nova stagger gate.
;; When `#:commit? #t` is passed and ready, atomically advances the Nova timestamp.
(: disruptor-nova-stagger-ready? (->* (spell-claims Integer) (Integer #:commit? Boolean) Boolean))
(define (disruptor-nova-stagger-ready? claims current-frame
                                       [stagger-frames DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES]
                                       #:commit? [commit? #f])
  (define last-f (spell-claims-last-disruptor-nova-frame claims))
  (define ready?
    (or (< last-f -5000)
        (>= (- current-frame last-f) stagger-frames)))
  (when (and ready? commit?)
    (set-spell-claims-last-disruptor-nova-frame! claims current-frame))
  ready?)

;; Filter S-expression action lists (e.g. from `step-disruptor-tactical-micro!`)
;; so at most one `'purification-nova` (`2346`) fires per `28f-32f` (`med=31f`) window.
(: filter-staggered-nova-actions (->* (spell-claims (Listof (Listof Any)) Integer) (Integer) (Listof (Listof Any))))
(define (filter-staggered-nova-actions claims actions current-frame
                                       [stagger-frames DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES])
  (for/fold ([acc : (Listof (Listof Any)) '()]
             #:result (reverse acc))
            ([act (in-list actions)])
    (define nova-cast?
      (and (pair? act)
           (memq (car act) '(cast cast-spell))
           (>= (length act) 3)
           (let ([sp (caddr act)])
             (or (eq? sp 'purification-nova)
                 (and (exact-integer? sp) (= sp 2346))))))
    (cond
      [(not nova-cast?) (cons act acc)]
      [(disruptor-nova-stagger-ready? claims current-frame stagger-frames #:commit? #t)
       (cons act acc)]
      [else acc])))

;; Lock a Ghost out of movement/kiting/recasting for `duration-frames` (`34f` per #115).
(: lock-ghost-snipe-channel! (->* (spell-claims Integer Integer) (Integer) Void))
(define (lock-ghost-snipe-channel! claims caster-tag current-frame
                                   [duration-frames SNIPE-CHANNEL-LOCKOUT-FRAMES])
  (when (> caster-tag 0)
    (hash-set! (spell-claims-ghost-snipe-unlock claims)
               caster-tag
               (+ current-frame (max 1 duration-frames)))))

;; Returns `#t` if Ghost (`tag` or unit hash) is inside its `34f` Snipe channel lockout.
(: snipe-channel-locked? (-> spell-claims Any Integer Boolean))
(define (snipe-channel-locked? claims caster-or-tag current-frame)
  (define tag : Integer
    (if (exact-integer? caster-or-tag)
        caster-or-tag
        (uh-tag caster-or-tag)))
  (define unlock-f (hash-ref (spell-claims-ghost-snipe-unlock claims) tag (lambda () -1)))
  (or (< current-frame unlock-f)
      (and (hash? caster-or-tag)
           (for/or : Boolean ([ab (in-list (uh-order-ids caster-or-tag))])
             (= ab 2714)))))

;; Convenience inverse of `snipe-channel-locked?`.
(: can-ghost-move-or-kite? (-> spell-claims Any Integer Boolean))
(define (can-ghost-move-or-kite? claims caster-or-tag current-frame)
  (not (snipe-channel-locked? claims caster-or-tag current-frame)))

;; Returns `(values active? dwell-frames)` for an Oracle's Pulsar Beam mutex tracker.
(: oracle-pulsar-beam-active? (-> spell-claims Any Integer (Values Boolean Integer)))
(define (oracle-pulsar-beam-active? claims oracle-u current-frame)
  (define o-tag (if (exact-integer? oracle-u) oracle-u (uh-tag oracle-u)))
  (define start-ht (spell-claims-oracle-beam-start claims))
  (define explicit-off?
    (and (hash? oracle-u)
         (dyn-hash-has-key? oracle-u 'pulsar-beam-on?)
         (not (eq? (dyn-hash-ref oracle-u 'pulsar-beam-on? #t) #t))))
  (define buff-on?
    (and (hash? oracle-u)
         (or (uh-has-buff? oracle-u 'oracle-weapon)
             (uh-has-buff? oracle-u 'pulsar-beam)
             (eq? (dyn-hash-ref oracle-u 'pulsar-beam-on? #f) #t)
             (eq? (dyn-hash-ref oracle-u 'pulsar-beam? #f) #t))))
  (cond
    [explicit-off?
     (hash-remove! start-ht o-tag)
     (values #f 0)]
    [buff-on?
     (define st
       (or (hash-ref start-ht o-tag (lambda () #f))
           (begin (hash-set! start-ht o-tag current-frame) current-frame)))
     (values #t (max 0 (- current-frame st)))]
    [(hash-ref start-ht o-tag (lambda () #f))
     => (lambda ([st : Integer])
          (define dwell (max 0 (- current-frame st)))
          (if (> dwell 450)
              (begin (hash-remove! start-ht o-tag) (values #f 0))
              (values #t dwell)))]
    [else (values #f 0)]))

;; Convert a typed `spell-directive` into a `sc2-typed-commands` S-expression.
(: spell-directive->sexp (-> spell-directive (Listof Any)))
(define (spell-directive->sexp d)
  (define uid (spell-directive-caster-tag d))
  (define ab (canonical-sexp-spell (spell-directive-ability d)))
  (define mode (spell-directive-target-mode d))
  (define tid (spell-directive-target-tag d))
  (define tx (spell-directive-target-x d))
  (define ty (spell-directive-target-y d))
  (case mode
    [(none) (list 'cast-spell uid ab)]
    [(point) (list 'cast-spell uid ab tx ty)]
    [(unit) (list 'cast-spell uid ab tid)]
    [(pair)
     (if (and (memq (spell-directive-ability d) '(morph-archon archon))
              (> tid 0)
              (not (= uid tid)))
         (list 'morph (list uid tid) 'archon)
         (list 'morph 'archon))]
    [(move) (list 'move uid tx ty)]
    [(kite) (list 'kite uid tx ty)]
    [else (list 'cast-spell uid ab)]))

;; -----------------------------------------------------------------------------
;; 5. Shared Spatial Scoring, Cluster Selection & Effect Helpers
;; -----------------------------------------------------------------------------

(: unit-combat-relevant? (-> Any Boolean))
(define (unit-combat-relevant? u)
  (define t (uh-type u))
  (and (not (memq t '(larva egg cocoon baneling-cocoon ravager-cocoon
                      brood-lord-cocoon overlord-cocoon overlord
                      overlord-transport changeling changeling-zealot
                      changeling-marine changeling-marine-shield
                      changeling-zergling changeling-zergling-wings
                      adept-phase-shift disruptor-phased kd8-charge
                      parasitic-bomb-dummy mule broodling broodling-escort
                      creep-tumor creep-tumor-burrowed creep-tumor-queen)))
       (not (memq t '(scv probe drone)))
       (not (uh-hallucination? u))))

(: count-units-within (-> (Listof Any) Float Float Float (-> Any Boolean) Integer))
(define (count-units-within units cx cy radius pred)
  (for/sum : Integer ([u (in-list units)])
    (if (and (hash? u)
             (<= (dist2 cx cy (uh-x u) (uh-y u)) radius)
             (pred u))
        1
        0)))

(: any-unit-within? (-> (Listof Any) Float Float Float (-> Any Boolean) Boolean))
(define (any-unit-within? units cx cy radius pred)
  (for/or : Boolean ([u (in-list units)])
    (and (hash? u)
         (<= (dist2 cx cy (uh-x u) (uh-y u)) radius)
         (pred u))))

(: count-all-allies-within (-> (Listof Any) (Listof Any) Float Float Float (-> Any Boolean) Integer))
(define (count-all-allies-within units bldgs cx cy radius pred)
  (+ (count-units-within units cx cy radius pred)
     (count-units-within bldgs cx cy radius pred)))

(: enemy-ground-range (-> Any Float))
(define (enemy-ground-range u)
  (safe-fl (hash-ref (sc2-unit-combat-stats (uh-type u)) 'ground-range (lambda () 0.0)) 0.0))

(: enemy-ranged-threat? (-> Any Boolean))
(define (enemy-ranged-threat? u)
  (define st (sc2-unit-combat-stats (uh-type u)))
  (define gr (safe-fl (hash-ref st 'ground-range (lambda () 0.0)) 0.0))
  (define ar (safe-fl (hash-ref st 'air-range (lambda () 0.0)) 0.0))
  (or (>= gr 2.0) (>= ar 2.0)))

(: enemy-anti-air-or-air-threat? (-> Any Boolean))
(define (enemy-anti-air-or-air-threat? u)
  (define t (uh-type u))
  (and (not (memq t '(overlord overlord-transport observer observer-siege-mode
                      overseer overseer-siege-mode scv probe drone larva egg
                      parasitic-bomb-dummy kd8-charge)))
       (or (uh-flying? u)
           (sc2-unit-can-attack-air? t))))

(: enemy-detector-within? (-> (Listof Any) (Listof Any) Float Float Float Boolean))
(define (enemy-detector-within? enemy-units enemy-bldgs cx cy radius)
  (or (any-unit-within? enemy-units cx cy radius uh-detector?)
      (any-unit-within? enemy-bldgs cx cy radius uh-detector?)))

(: safe-retreat-point (-> Float Float (Listof Any) Float Float Float (Values Float Float)))
(define (safe-retreat-point ux uy threats home-x home-y step-dist)
  (define-values (tx ty n)
    (for/fold ([sx : Float 0.0]
               [sy : Float 0.0]
               [cnt : Integer 0])
              ([e (in-list threats)]
               #:when (and (hash? e) (<= (dist2 ux uy (uh-x e) (uh-y e)) 14.0)))
      (values (+ sx (uh-x e)) (+ sy (uh-y e)) (+ cnt 1))))
  (define raw-dx
    (if (> n 0)
        (- ux (/ tx (->float n)))
        (- home-x ux)))
  (define raw-dy
    (if (> n 0)
        (- uy (/ ty (->float n)))
        (- home-y uy)))
  ;; Blend 65% away from immediate threats + 35% toward home base
  (define hdx (- home-x ux))
  (define hdy (- home-y uy))
  (define hlen (max 0.01 (flsqrt (+ (* hdx hdx) (* hdy hdy)))))
  (define rlen (max 0.01 (flsqrt (+ (* raw-dx raw-dx) (* raw-dy raw-dy)))))
  (define vx (+ (* 0.65 (/ raw-dx rlen)) (* 0.35 (/ hdx hlen))))
  (define vy (+ (* 0.65 (/ raw-dy rlen)) (* 0.35 (/ hdy hlen))))
  (define vlen (max 0.01 (flsqrt (+ (* vx vx) (* vy vy)))))
  (values (clamp-coord (+ ux (* step-dist (/ vx vlen))))
          (clamp-coord (+ uy (* step-dist (/ vy vlen))))))

(: centroid-and-velocity (-> (Listof Any) (Values Float Float Float Float Integer)))
(define (centroid-and-velocity members)
  (define-values (sx sy svx svy n)
    (for/fold ([ax : Float 0.0]
               [ay : Float 0.0]
               [avx : Float 0.0]
               [avy : Float 0.0]
               [cnt : Integer 0])
              ([u (in-list members)])
      (values (+ ax (uh-x u))
              (+ ay (uh-y u))
              (+ avx (uh-vx u))
              (+ avy (uh-vy u))
              (+ cnt 1))))
  (if (= n 0)
      (values 0.0 0.0 0.0 0.0 0)
      (let ([fn (->float n)])
        (values (/ sx fn) (/ sy fn) (/ svx fn) (/ svy fn) n))))

;; Generic cluster evaluator: returns `(values best-x best-y best-score)`.
;; Evaluates candidate cluster centered on each eligible seed unit in `seeds`
;; within `cast-range` of `(caster-x, caster-y)`, aggregating nearby enemies
;; within `aoe-radius`, applying optional velocity lead (`max-lead`), and calling
;; `score-fn : (cluster-cx cluster-cy cluster-members -> Float)`.
(: best-enemy-cluster
   (-> Float Float Float (Listof Any) Float Float (-> Float Float (Listof Any) Float)
       (Values Boolean Float Float Float)))
(define (best-enemy-cluster caster-x caster-y cast-range enemies aoe-radius max-lead score-fn)
  (define-values (found? bx by bs)
    (for/fold ([f? : Boolean #f]
               [best-x : Float 0.0]
               [best-y : Float 0.0]
               [best-s : Float 0.0])
              ([seed (in-list enemies)]
               #:when (and (hash? seed)
                           (sc2-enemy-unit-targetable? seed)
                           (<= (dist2 caster-x caster-y (uh-x seed) (uh-y seed)) cast-range)))
      (define sx (uh-x seed))
      (define sy (uh-y seed))
      (define cluster
        (for/list : (Listof Any)
                  ([e (in-list enemies)]
                   #:when (and (hash? e)
                               (sc2-enemy-unit-targetable? e)
                               (<= (dist2 sx sy (uh-x e) (uh-y e)) aoe-radius)))
          e))
      (define-values (cx cy vx vy cnt) (centroid-and-velocity cluster))
      (cond
        [(= cnt 0) (values f? best-x best-y best-s)]
        [else
         (define-values (lx ly)
           (if (<= max-lead 0.0)
               (values cx cy)
               (let ([spd2 (+ (* vx vx) (* vy vy))])
                 (if (<= spd2 0.0625)
                     (values cx cy)
                     (let* ([spd (flsqrt spd2)]
                            [lead (min max-lead (* 0.25 spd))])
                       (values (clamp-coord (+ cx (* lead (/ vx spd))))
                               (clamp-coord (+ cy (* lead (/ vy spd))))))))))
         (define sc (if (<= (dist2 caster-x caster-y lx ly) cast-range)
                        (score-fn lx ly cluster)
                        0.0))
         (if (> sc best-s)
             (values #t lx ly sc)
             (values f? best-x best-y best-s))])))
  (values found? bx by bs))

(: effect-type (-> Any Symbol))
(define (effect-type eff)
  (safe-sym (dyn-hash-ref eff 'type 'unknown) 'unknown))

(: effect-friendly? (-> Any Boolean))
(define (effect-friendly? eff)
  (eq? (dyn-hash-ref eff 'friendly? #f) #t))

(: any-effect-within? (-> (Listof Any) Symbol Float Float Float (-> Any Boolean) Boolean))
(define (any-effect-within? effects target-type cx cy radius extra-pred)
  (for/or : Boolean ([eff (in-list effects)])
    (and (hash? eff)
         (eq? (effect-type eff) target-type)
         (<= (dist2 cx cy (uh-x eff) (uh-y eff)) radius)
         (extra-pred eff))))

(: unit-inside-point-claim? (-> spell-claims Symbol Float Float Float Integer Boolean))
(define (unit-inside-point-claim? claims ab ux uy extra-rad frame)
  (for/or : Boolean ([c (in-list (spell-claims-point-claims claims))])
    (and (eq? (point-claim-ability c) ab)
         (> (point-claim-expires-frame c) frame)
         (<= (dist2 ux uy (point-claim-x c) (point-claim-y c))
             (+ (point-claim-radius c) extra-rad)))))

;; Pick highest-priority target unit within `cast-range` matching `pred` & `weight-fn`.
(: best-unit-target
   (-> Float Float Float (Listof Any) (-> Any Boolean) (-> Any Float)
       (Values Boolean Any Float)))
(define (best-unit-target cx cy cast-range candidates pred weight-fn)
  (for/fold ([found? : Boolean #f]
             [best-u : Any #f]
             [best-w : Float 0.0])
            ([u (in-list candidates)]
             #:when (and (hash? u)
                         (> (uh-tag u) 0)
                         (<= (dist2 cx cy (uh-x u) (uh-y u)) cast-range)
                         (pred u)))
    (define w (weight-fn u))
    (if (> w best-w)
        (values #t u w)
        (values found? best-u best-w))))

;; -----------------------------------------------------------------------------
;; 6. Zerg Spellcaster Patterns (Queen, Ravager, Infestor, Viper, Corruptor)
;; -----------------------------------------------------------------------------

(: queen-transfuse-priority (-> Symbol Float))
(define (queen-transfuse-priority sym)
  (case sym
    [(ultralisk) 100.0]
    [(brood-lord) 95.0]
    [(queen) 92.0]
    [(lurker lurker-burrowed lurker-mp lurker-mp-burrowed) 88.0]
    [(viper) 85.0]
    [(infestor infestor-burrowed) 82.0]
    [(ravager) 78.0]
    [(hydralisk) 72.0]
    [(roach roach-burrowed) 68.0]
    [(spine-crawler) 64.0]
    [(spore-crawler) 60.0]
    [(hatchery lair hive) 58.0]
    [else 0.0]))

(: zerg-bile-siege-or-static? (-> Any Boolean))
(define (zerg-bile-siege-or-static? e)
  (and (memq (uh-type e)
             '(siege-tank-sieged liberator-ag lurker-burrowed lurker-mp-burrowed
               warp-prism-phasing photon-cannon bunker shield-battery
               spine-crawler spore-crawler missile-turret))
       #t))

(: ravager-try-bile-point! (-> spell-claims Integer Float Float Float Float Float Boolean Integer Symbol (Option spell-directive)))
(define (ravager-try-bile-point! claims r-tag rx ry bx by cluster-hp force-field? current-frame pattern)
  (define max-biles : Integer
    (if force-field?
        1
        (min 3 (max 1 (safe-ceil-div (max 60.0 cluster-hp) 60.0)))))
  (define existing-near
    (for/sum : Integer ([c (in-list (spell-claims-point-claims claims))])
      (if (and (eq? (point-claim-ability c) 'corrosive-bile)
               (> (point-claim-expires-frame c) current-frame)
               (<= (dist2 bx by (point-claim-x c) (point-claim-y c)) 1.6))
          1
          0)))
  (cond
    [(>= existing-near max-biles) #f]
    [else
     (define d-off CORROSIVE-BILE-STAGGER-OFFSET)
     (define offsets : (Listof (Pairof Float Float))
       (list (cons 0.0 0.0)
             (cons d-off 0.0)
             (cons (- d-off) 0.0)
             (cons 0.0 d-off)
             (cons 0.0 (- d-off))
             (cons (* 0.707 d-off) (* 0.707 d-off))
             (cons (* -0.707 d-off) (* 0.707 d-off))))
     (for/or : (Option spell-directive) ([off (in-list offsets)])
       (define cx (clamp-coord (+ bx (car off))))
       (define cy (clamp-coord (+ by (cdr off))))
       (and (<= (dist2 rx ry cx cy) 9.0)
            (spell-claim-point?! claims 'corrosive-bile cx cy
                                 CORROSIVE-BILE-CLAIM-RADIUS
                                 current-frame
                                 CORROSIVE-BILE-CLAIM-TTL)
            (begin
              (hash-set! (spell-claims-ravager-bile-ready-frame claims)
                         r-tag
                         (+ current-frame CORROSIVE-BILE-COOLDOWN-FRAMES))
              (spell-directive r-tag 'ravager 'corrosive-bile 'point 0 cx cy pattern))))]))

(: infestor-neural-weight (-> Symbol Float))
(define (infestor-neural-weight sym)
  (case sym
    [(carrier mothership) 130.0]
    [(battlecruiser) 125.0]
    [(tempest) 118.0]
    [(thor thor-ap) 115.0]
    [(colossus) 112.0]
    [(archon) 108.0]
    [(siege-tank-sieged siege-tank) 104.0]
    [(immortal) 98.0]
    [(ultralisk) 95.0]
    [else 0.0]))

(: enemy-fungal-value-weight (-> Symbol Float))
(define (enemy-fungal-value-weight sym)
  (case sym
    [(mutalisk phoenix) 1.6]
    [(stalker blink-stalker adept hellion reaper) 1.45]
    [(marine zergling baneling medivac viking viking-fighter banshee) 1.3]
    [(high-templar ghost oracle hydralisk) 1.25]
    [else 1.0]))

(: enemy-air-capital-or-ranged? (-> Any Boolean))
(define (enemy-air-capital-or-ranged? e)
  (and (uh-flying? e)
       (not (memq (uh-type e)
                  '(overlord overlord-transport observer observer-siege-mode
                    overseer overseer-siege-mode parasitic-bomb-dummy
                    interceptor)))
       (sc2-enemy-unit-targetable? e)))

(: viper-abduct-weight (-> Symbol Float))
(define (viper-abduct-weight sym)
  (case sym
    [(siege-tank-sieged) 130.0]
    [(colossus) 125.0]
    [(thor thor-ap) 120.0]
    [(tempest) 115.0]
    [(carrier mothership) 112.0]
    [(battlecruiser) 110.0]
    [(lurker-burrowed lurker-mp-burrowed lurker lurker-mp) 106.0]
    [(liberator-ag liberator) 102.0]
    [(immortal) 98.0]
    [(viper) 95.0]
    [(siege-tank) 90.0]
    [else 0.0]))

(: viper-ranged-ground? (-> Any Boolean))
(define (viper-ranged-ground? e)
  (and (not (uh-flying? e))
       (>= (enemy-ground-range e) 2.0)
       (sc2-enemy-unit-targetable? e)))

(: zerg-consume-structure-weight (-> Any Float))
(define (zerg-consume-structure-weight b)
  (define t (uh-type b))
  (define hp (uh-total-hp b))
  (cond
    [(<= hp 450.0) 0.0]
    [(memq t '(creep-tumor creep-tumor-burrowed creep-tumor-queen
               larva egg cocoon spine-crawler spore-crawler)) 0.0]
    [(memq t '(evolution-chamber roach-warren baneling-nest spawning-pool)) (+ 120.0 (* 0.05 hp))]
    [(memq t '(hatchery lair hive spire greater-spire infestation-pit
               hydralisk-den lurker-den ultralisk-cavern)) (+ 90.0 (* 0.05 hp))]
    [(memq t '(extractor extractor-rich)) (+ 80.0 (* 0.05 hp))]
    [else 0.0]))

;; Plan #115-calibrated Zerg spellcaster micro (`queen`, `ravager`, `infestor`,
;; `viper`, `corruptor`) while preserving delta-f = 0 invariants via `claims`.
(: plan-zerg-spellcaster-micro
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:home-x Float
         #:home-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:inject-queen-tags (Listof Integer)
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-zerg-spellcaster-micro
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:inject-queen-tags [inject-queen-tags '()]
         #:exclude-tags [exclude-tags '()])
  (define all-enemies (append enemy-units enemy-buildings))
  (define all-allies (append ally-units ally-buildings))

  (define-values (dirs-rev _)
    (for/fold ([acc : (Listof spell-directive) '()]
               [used-tags : (Listof Integer) exclude-tags])
              ([u (in-list ally-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used-tags))
         (values acc used-tags)]
        [else
         (define ux (uh-x u))
         (define uy (uh-y u))
         (define en (uh-energy u))
         (define dir : (Option spell-directive)
           (case sym
             ;; --- QUEEN ---
             [(queen)
              (define transfuse-d : (Option spell-directive)
                (and (>= en SC2-QUEEN-TRANSFUSION-ENERGY)
                     (let-values ([(ok? tgt _w)
                                   (best-unit-target
                                    ux uy 7.0 all-allies
                                    (lambda ([a : Any])
                                      (and (not (= (uh-tag a) tag))
                                           (not (uh-hallucination? a))
                                           (> (queen-transfuse-priority (uh-type a)) 0.0)
                                           (>= (uh-missing-hp a) 65.0)
                                           (< (uh-hp-ratio a) 0.65)))
                                    (lambda ([a : Any])
                                      (+ (queen-transfuse-priority (uh-type a))
                                         (* 30.0 (- 1.0 (uh-hp-ratio a)))
                                         (min 40.0 (* 0.25 (uh-missing-hp a))))))])
                       (and ok?
                            (let ([ttag (uh-tag tgt)])
                              (and (spell-claim-unit?!
                                    claims 'transfusion ttag current-frame UNIT-SPELL-CLAIM-TTL
                                    #:caster-tag tag #:missing-hp (uh-missing-hp tgt))
                                   (spell-directive tag 'queen 'transfusion 'unit ttag
                                                    (uh-x tgt) (uh-y tgt) 'queen-transfuse)))))))
              (or transfuse-d
                  (let* ([inject? (and (memv tag inject-queen-tags) #t)]
                         [tumor-en-min (if inject? 100.0 (->float SC2-QUEEN-TUMOR-ENERGY))]
                         [safe? (not (any-unit-within? all-enemies ux uy 14.0 sc2-enemy-unit-targetable?))])
                    (and (>= en tumor-en-min)
                         safe?
                         (let* ([dx (- enemy-base-x ux)]
                                [dy (- enemy-base-y uy)]
                                [dlen (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                [tx (clamp-coord (+ ux (* 3.0 (/ dx dlen))))]
                                [ty (clamp-coord (+ uy (* 3.0 (/ dy dlen))))]
                                [tumor-nearby?
                                 (any-unit-within?
                                  all-allies tx ty 2.8
                                  (lambda ([b : Any])
                                    (and (memq (uh-type b)
                                               '(creep-tumor creep-tumor-burrowed creep-tumor-queen))
                                         #t)))])
                           (and (not tumor-nearby?)
                                (spell-claim-point?! claims 'spawn-creep-tumor tx ty 3.5 current-frame 64)
                                (spell-directive tag 'queen 'spawn-creep-tumor 'point 0 tx ty
                                                 'queen-creep-tumor))))))]

             ;; --- RAVAGER ---
             [(ravager)
              (define bile-unlock (hash-ref (spell-claims-ravager-bile-ready-frame claims) tag (lambda () -1)))
              (define explicit-ready? (not (eq? (dyn-hash-ref u 'bile-ready? #t) #f)))
              (define explicit-cd (safe-int (dyn-hash-ref u 'corrosive-bile-cooldown 0) 0))
              (define ready? (and explicit-ready? (<= explicit-cd 0) (>= current-frame bile-unlock)))
              (and ready?
                   ;; Priority 1: Fungal -> Bile guaranteed 60-damage combo
                   (or (let-values ([(ok? fx fy _s)
                                     (best-enemy-cluster
                                      ux uy 9.0 enemy-units 1.5 0.0
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define fungal-cnt
                                          (for/sum : Integer ([e (in-list cl)])
                                            (if (or (uh-has-buff? e 'fungal-growth)
                                                    (unit-inside-point-claim? claims 'fungal-growth (uh-x e) (uh-y e) 0.5 current-frame)
                                                    (any-effect-within? effects 'fungal-growth (uh-x e) (uh-y e) 2.5 (lambda ([_ef : Any]) #t)))
                                                1 0)))
                                        (if (> fungal-cnt 0)
                                            (+ (* 100.0 (->float fungal-cnt)) (* 10.0 (->float (length cl))))
                                            0.0)))])
                         (and ok?
                              (let ([hp-sum (sum-hp-within enemy-units fx fy 1.6)])
                                (ravager-try-bile-point! claims tag ux uy fx fy hp-sum #f current-frame
                                                         'ravager-fungal-bile-combo))))
                       ;; Priority 2: Enemy Force Fields
                       (for/or : (Option spell-directive) ([eff (in-list effects)])
                         (and (hash? eff)
                              (eq? (effect-type eff) 'force-field)
                              (not (effect-friendly? eff))
                              (<= (dist2 ux uy (uh-x eff) (uh-y eff)) 9.0)
                              (ravager-try-bile-point! claims tag ux uy (uh-x eff) (uh-y eff) 60.0 #t current-frame
                                                       'ravager-force-field-shatter)))
                       ;; Priority 2b: Enemy Siege / Static Defense targets
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 9.0 all-enemies zerg-bile-siege-or-static?
                                      (lambda ([e : Any])
                                        (case (uh-type e)
                                          [(siege-tank-sieged) 130.0]
                                          [(liberator-ag) 125.0]
                                          [(lurker-burrowed lurker-mp-burrowed) 120.0]
                                          [(warp-prism-phasing) 115.0]
                                          [(bunker photon-cannon shield-battery) 100.0]
                                          [else 85.0])))])
                         (and ok?
                              (ravager-try-bile-point! claims tag ux uy (uh-x tgt) (uh-y tgt) (uh-total-hp tgt) #f
                                                       current-frame 'ravager-siege-static-bile)))
                       ;; Priority 3: Velocity-led ground clumps (>= 2 within 1.5 tiles)
                       (let-values ([(ok? bx by _s)
                                     (best-enemy-cluster
                                      ux uy 9.0
                                      (filter (lambda ([e : Any]) (and (hash? e) (not (uh-flying? e)))) enemy-units)
                                      1.5 1.1
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (if (>= (length cl) 2)
                                            (+ (* 30.0 (->float (length cl)))
                                               (* 0.1 (sum-units-fl cl uh-total-hp)))
                                            0.0)))])
                         (and ok?
                              (let ([hp-sum (sum-hp-within enemy-units bx by 1.6)])
                                (ravager-try-bile-point! claims tag ux uy bx by hp-sum #f current-frame
                                                         'ravager-clump-bile))))))]

             ;; --- INFESTOR ---
             [(infestor infestor-burrowed)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [(eq? sym 'infestor-burrowed)
                 ;; Burrowed Infestor can still safely channel Neural Parasite
                 (define friendly-army-near?
                   (any-unit-within? ally-units ux uy 11.0
                                     (lambda ([a : Any]) (and (not (= (uh-tag a) tag)) (unit-combat-relevant? a)))))
                 (and (>= en SC2-INFESTOR-NEURAL-ENERGY)
                      friendly-army-near?
                      (let-values ([(ok? tgt _w)
                                    (best-unit-target
                                     ux uy SC2-INFESTOR-NEURAL-CAST-RANGE enemy-units
                                     (lambda ([e : Any])
                                       (and (not (uh-has-buff? e 'neural-parasite))
                                            (> (infestor-neural-weight (uh-type e)) 0.0)))
                                     (lambda ([e : Any]) (infestor-neural-weight (uh-type e))))])
                        (and ok?
                             (spell-claim-unit?! claims 'neural-parasite (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                 #:caster-tag tag)
                             (spell-directive tag sym 'neural-parasite 'unit (uh-tag tgt)
                                              (uh-x tgt) (uh-y tgt) 'infestor-neural))))]
                [else
                 (define friendly-army-near?
                   (any-unit-within? ally-units ux uy 11.0
                                     (lambda ([a : Any]) (and (not (= (uh-tag a) tag)) (unit-combat-relevant? a)))))
                 (or
                  ;; 1. Fungal Growth (`0.5`-tile velocity lead, `r=2.25 ttl=32`)
                  (and (>= en SC2-INFESTOR-FUNGAL-ENERGY)
                       (let-values ([(ok? fx fy _s)
                                     (best-enemy-cluster
                                      ux uy SC2-INFESTOR-FUNGAL-CAST-RANGE enemy-units 2.25 0.5
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define unbuffed
                                          (for/list : (Listof Any) ([e (in-list cl)]
                                                                    #:when (not (uh-has-buff? e 'fungal-growth)))
                                            e))
                                        (if (and (>= (length unbuffed) 2)
                                                 (not (spell-point-claimed? claims 'fungal-growth cx cy FUNGAL-CLAIM-RADIUS current-frame)))
                                            (sum-units-fl unbuffed
                                                          (lambda ([e : Any])
                                                            (* 25.0 (enemy-fungal-value-weight (uh-type e)))))
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'fungal-growth fx fy FUNGAL-CLAIM-RADIUS current-frame FUNGAL-CLAIM-TTL)
                              (spell-directive tag 'infestor 'fungal-growth 'point 0 fx fy 'infestor-fungal))))
                  ;; 2. Neural Parasite (`energy >= 100`, range `9.0`, friendly army `< 11.0`)
                  (and (>= en SC2-INFESTOR-NEURAL-ENERGY)
                       friendly-army-near?
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy SC2-INFESTOR-NEURAL-CAST-RANGE enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-has-buff? e 'neural-parasite))
                                             (> (infestor-neural-weight (uh-type e)) 0.0)))
                                      (lambda ([e : Any]) (infestor-neural-weight (uh-type e))))])
                         (and ok?
                              (spell-claim-unit?! claims 'neural-parasite (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'infestor 'neural-parasite 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'infestor-neural))))
                  ;; 3. Microbial Shroud vs >= 3 air threats over friendly ground army cluster
                  (and (>= en 75.0)
                       (>= (count-units-within enemy-units ux uy 14.0 enemy-air-capital-or-ranged?) 3)
                       (let-values ([(ok? sx sy _cnt)
                                     (for/fold ([f? : Boolean #f] [bx : Float 0.0] [by : Float 0.0] [bc : Integer 2])
                                               ([a (in-list ally-units)]
                                                #:when (and (hash? a)
                                                            (not (uh-flying? a))
                                                            (unit-combat-relevant? a)
                                                            (<= (dist2 ux uy (uh-x a) (uh-y a)) 9.0)))
                                       (define ax (uh-x a))
                                       (define ay (uh-y a))
                                       (define cnt
                                         (count-units-within
                                          ally-units ax ay 3.5
                                          (lambda ([b : Any]) (and (not (uh-flying? b)) (unit-combat-relevant? b)))))
                                       (if (and (> cnt bc)
                                                (not (spell-point-claimed? claims 'microbial-shroud ax ay MICROBIAL-SHROUD-CLAIM-RADIUS current-frame)))
                                           (values #t ax ay cnt)
                                           (values f? bx by bc)))])
                         (and ok?
                              (spell-claim-point?! claims 'microbial-shroud sx sy MICROBIAL-SHROUD-CLAIM-RADIUS current-frame MICROBIAL-SHROUD-CLAIM-TTL)
                              (spell-directive tag 'infestor 'microbial-shroud 'point 0 sx sy 'infestor-microbial-shroud))))
                  ;; 4. Low-energy (< 70, non-channeling) 10.0-tile retreat when threatened
                  (and (< en 70.0)
                       (any-unit-within? all-enemies ux uy 12.0 sc2-enemy-unit-targetable?)
                       (let-values ([(rx ry) (safe-retreat-point ux uy all-enemies home-x home-y 10.0)])
                         (spell-directive tag 'infestor 'move 'kite 0 rx ry 'infestor-low-energy-retreat))))])]

             ;; --- VIPER ---
             [(viper)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (or
                  ;; 1. Blinding Cloud on >= 2 ground ranged clumps (`range 11.0`)
                  (and (>= en 100.0)
                       (let-values ([(ok? cx cy _s)
                                     (best-enemy-cluster
                                      ux uy 11.0 enemy-units 2.0 0.0
                                      (lambda ([px : Float] [py : Float] [cl : (Listof Any)])
                                        (define rcnt
                                          (for/sum : Integer ([e (in-list cl)])
                                            (if (and (viper-ranged-ground? e)
                                                     (not (uh-has-buff? e 'blinding-cloud)))
                                                1 0)))
                                        (if (and (>= rcnt 2)
                                                 (not (spell-point-claimed? claims 'blinding-cloud px py BLINDING-CLOUD-CLAIM-RADIUS current-frame)))
                                            (->float rcnt)
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'blinding-cloud cx cy BLINDING-CLOUD-CLAIM-RADIUS current-frame BLINDING-CLOUD-CLAIM-TTL)
                              (spell-directive tag 'viper 'blinding-cloud 'point 0 cx cy 'viper-blinding-cloud))))
                  ;; 2. Abduct into >= 4 friendly combat units within 7.0 (`energy >= 75`, `range 9.0`)
                  (and (>= en 75.0)
                       (>= (count-units-within ally-units ux uy 7.0
                                               (lambda ([a : Any]) (and (not (= (uh-tag a) tag)) (unit-combat-relevant? a))))
                           4)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 9.0 enemy-units
                                      (lambda ([e : Any]) (> (viper-abduct-weight (uh-type e)) 0.0))
                                      (lambda ([e : Any]) (viper-abduct-weight (uh-type e))))])
                         (and ok?
                              (spell-claim-unit?! claims 'abduct (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'viper 'abduct 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'viper-abduct))))
                  ;; 3. Parasitic Bomb on >= 3 air units without nearby `824` dummy or active bomb
                  (and (>= en 125.0)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 8.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (enemy-air-capital-or-ranged? e)
                                             (not (uh-has-buff? e 'parasitic-bomb))
                                             (>= (count-units-within enemy-units (uh-x e) (uh-y e) 3.0 enemy-air-capital-or-ranged?) 3)
                                             (not (any-unit-within?
                                                   enemy-units (uh-x e) (uh-y e) 4.0
                                                   (lambda ([d : Any])
                                                     (or (eq? (uh-type d) 'parasitic-bomb-dummy)
                                                         (= (safe-int (dyn-hash-ref d 'unit-type-id 0) 0) 824)
                                                         (= (safe-int (dyn-hash-ref d 'type 0) 0) 824)
                                                         (uh-has-buff? d 'parasitic-bomb)))))
                                             (not (spell-point-claimed? claims 'parasitic-bomb-zone (uh-x e) (uh-y e) 3.5 current-frame))))
                                      (lambda ([e : Any])
                                        (+ (* 20.0 (->float (count-units-within enemy-units (uh-x e) (uh-y e) 3.0 enemy-air-capital-or-ranged?)))
                                           (min 100.0 (* 0.2 (uh-total-hp e))))))])
                         (and ok?
                              (spell-claim-unit?! claims 'parasitic-bomb (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (begin
                                (spell-claim-point?! claims 'parasitic-bomb-zone (uh-x tgt) (uh-y tgt) 3.5 current-frame 64)
                                (spell-directive tag 'viper 'parasitic-bomb 'unit (uh-tag tgt)
                                                 (uh-x tgt) (uh-y tgt) 'viper-parasitic-bomb)))))
                  ;; 4. Safe Consume (`energy < 60`, `0` enemies within `12.0`, Zerg building `hp > 450`)
                  (and (< en 60.0)
                       (not (any-unit-within? all-enemies ux uy 12.0 sc2-enemy-unit-targetable?))
                       (let-values ([(ok? bldg _w)
                                     (best-unit-target
                                      ux uy 25.0 (append ally-buildings ally-units)
                                      (lambda ([b : Any]) (> (zerg-consume-structure-weight b) 0.0))
                                      (lambda ([b : Any])
                                        (- (zerg-consume-structure-weight b)
                                           (* 1.5 (dist2 ux uy (uh-x b) (uh-y b))))))])
                         (and ok?
                              (spell-claim-unit?! claims 'viper-consume (uh-tag bldg) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'viper 'viper-consume 'unit (uh-tag bldg)
                                               (uh-x bldg) (uh-y bldg) 'viper-safe-consume)))))])]

             ;; --- CORRUPTOR ---
             [(corruptor)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [(any-unit-within? all-enemies ux uy 11.0 enemy-anti-air-or-air-threat?) #f]
                [else
                 (let-values ([(ok? th _w)
                               (best-unit-target
                                ux uy 6.0 all-enemies
                                (lambda ([e : Any]) (and (memq (uh-type e) SC2-TOWNHALL-STRUCTURE-SYMS) #t))
                                (lambda ([e : Any]) (uh-total-hp e)))])
                   (and ok?
                        (spell-directive tag 'corruptor 'caustic-spray 'unit (uh-tag th)
                                         (uh-x th) (uh-y th) 'corruptor-caustic-spray)))])]

             [else #f]))
         (if dir
             (values (cons dir acc) (cons tag used-tags))
             (values acc used-tags))])))
  (reverse dirs-rev))

;; -----------------------------------------------------------------------------
;; 7. Terran Spellcaster Patterns (Ghost, Raven, Battlecruiser)
;; -----------------------------------------------------------------------------

(: ghost-emp-target-bonus (-> Any Float))
(define (ghost-emp-target-bonus e)
  (define sh (uh-shields e))
  (define caster?
    (and (memq (uh-type e) '(high-templar sentry oracle archon infestor viper ghost raven))
         (>= (+ (uh-energy e) sh) 40.0)))
  (if (or (> sh 0.0) caster?)
      (+ sh (if caster? 80.0 0.0))
      0.0))

(: ghost-snipe-weight (-> Any Float))
(define (ghost-snipe-weight e)
  (case (uh-type e)
    [(lurker-burrowed lurker-mp-burrowed lurker lurker-mp) 130.0]
    [(viper) 128.0]
    [(infestor infestor-burrowed) 124.0]
    [(brood-lord) 120.0]
    [(ultralisk) 115.0]
    [(ravager) 105.0]
    [(high-templar ghost) 100.0]
    [(queen) 95.0]
    [else 0.0]))

(: raven-matrix-weight (-> Any Float))
(define (raven-matrix-weight e)
  (case (uh-type e)
    [(colossus) 130.0]
    [(siege-tank-sieged) 128.0]
    [(carrier mothership tempest) 124.0]
    [(battlecruiser) 122.0]
    [(thor thor-ap) 118.0]
    [(infestor viper high-templar) 112.0]
    [(archon immortal) 105.0]
    [(siege-tank raven ghost warp-prism warp-prism-phasing) 95.0]
    [else 0.0]))

(: bc-yamato-weight (-> Any Float))
(define (bc-yamato-weight e)
  (case (uh-type e)
    [(carrier mothership) 130.0]
    [(battlecruiser) 126.0]
    [(tempest) 122.0]
    [(thor thor-ap) 118.0]
    [(corruptor viper) 112.0]
    [(viking viking-fighter) 106.0]
    [(infestor archon) 102.0]
    [(high-templar) 96.0]
    [(stalker) 88.0]
    [else 0.0]))

(: terran-upgrade-ready? (-> (Listof Any) Symbol Boolean Boolean))
(define (terran-upgrade-ready? upgrades target-sym fallback-flag)
  (if (null? upgrades)
      fallback-flag
      (or fallback-flag
          (for/or : Boolean ([up (in-list upgrades)])
            (eq? (safe-sym up 'unknown) target-sym)))))

;; Plan #115-calibrated Terran spellcaster micro (`ghost`, `raven`, `battlecruiser`)
;; enforcing Ghost `34f` Snipe channel lockout, close-range `<4.5` guard, and detector Cloak check.
(: plan-terran-spellcaster-micro
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:yamato-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-terran-spellcaster-micro
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [_effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:yamato-researched? [yamato-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:exclude-tags [exclude-tags '()])
  (define all-enemies (append enemy-units enemy-buildings))
  (define yamato-ok? (terran-upgrade-ready? researched-upgrades 'weapon-refit yamato-researched?))

  (define-values (dirs-rev _)
    (for/fold ([acc : (Listof spell-directive) '()]
               [used-tags : (Listof Integer) exclude-tags])
              ([u (in-list ally-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used-tags))
         (values acc used-tags)]
        [else
         (define ux (uh-x u))
         (define uy (uh-y u))
         (define en (uh-energy u))
         (define dir : (Option spell-directive)
           (case sym
             ;; --- GHOST ---
             [(ghost)
              (cond
                [(snipe-channel-locked? claims u current-frame) #f]
                [(spellcaster-channel-protected? u) #f]
                [else
                 (or
                  ;; 1. EMP Round (`energy >= 75`, `r=2.0 ttl=24`, >= 180 shields or key casters)
                  (and (>= en 75.0)
                       (let-values ([(ok? ex ey _s)
                                     (best-enemy-cluster
                                      ux uy 10.0 enemy-units 2.0 0.25
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define shield-sum
                                          (sum-units-fl cl uh-shields))
                                        (define has-priority-caster?
                                          (for/or : Boolean ([e (in-list cl)])
                                            (and (memq (uh-type e)
                                                       '(high-templar sentry oracle archon infestor viper ghost raven))
                                                 (>= (+ (uh-energy e) (uh-shields e)) 40.0))))
                                        (if (and (or (>= shield-sum 180.0) has-priority-caster?)
                                                 (not (spell-point-claimed? claims 'emp-round cx cy EMP-CLAIM-RADIUS current-frame)))
                                            (sum-units-fl cl ghost-emp-target-bonus)
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'emp-round ex ey EMP-CLAIM-RADIUS current-frame EMP-CLAIM-TTL)
                              (spell-directive tag 'ghost 'emp-round 'point 0 ex ey 'ghost-emp))))
                  ;; 2. Snipe / Steady Targeting (`energy >= 50`, ZERO enemies `< 4.5` tiles, HP-capped + `34f` lock)
                  (and (>= en 50.0)
                       (not (any-unit-within? all-enemies ux uy 4.499 sc2-enemy-unit-targetable?))
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 10.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-hallucination? e))
                                             (> (ghost-snipe-weight e) 0.0)))
                                      (lambda ([e : Any]) (ghost-snipe-weight e)))])
                         (and ok?
                              (spell-claim-unit?!
                               claims 'steady-targeting (uh-tag tgt) current-frame SNIPE-CHANNEL-LOCKOUT-FRAMES
                               #:caster-tag tag #:target-hp (uh-total-hp tgt))
                              (begin
                                (lock-ghost-snipe-channel! claims tag current-frame SNIPE-CHANNEL-LOCKOUT-FRAMES)
                                (spell-directive tag 'ghost 'steady-targeting 'unit (uh-tag tgt)
                                                 (uh-x tgt) (uh-y tgt) 'ghost-snipe)))))
                  ;; 3. Ghost Cloak (`energy >= 50`, engaging `< 10.0`, no enemy detector `< 11.0`)
                  (and (>= en 50.0)
                       (not (uh-cloaked? u))
                       (> (- current-frame (hash-ref (spell-claims-ghost-cloak-frame claims) tag (lambda () -10000))) 20)
                       (any-unit-within? enemy-units ux uy 10.0 sc2-enemy-unit-targetable?)
                       (not (enemy-detector-within? enemy-units enemy-buildings ux uy 10.999))
                       (begin
                         (hash-set! (spell-claims-ghost-cloak-frame claims) tag current-frame)
                         (spell-directive tag 'ghost 'cloak-ghost 'none 0 ux uy 'ghost-cloak))))])]

             ;; --- RAVEN ---
             [(raven)
              (or
               ;; 1. Interference Matrix (`energy >= 75`, `range 9.0`, 1/target)
               (and (>= en 75.0)
                    (let-values ([(ok? tgt _w)
                                  (best-unit-target
                                   ux uy 9.0 enemy-units
                                   (lambda ([e : Any])
                                     (and (not (uh-hallucination? e))
                                          (not (uh-has-buff? e 'interference-matrix))
                                          (> (raven-matrix-weight e) 0.0)))
                                   (lambda ([e : Any]) (raven-matrix-weight e)))])
                      (and ok?
                           (spell-claim-unit?! claims 'interference-matrix (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                               #:caster-tag tag)
                           (spell-directive tag 'raven 'interference-matrix 'unit (uh-tag tgt)
                                            (uh-x tgt) (uh-y tgt) 'raven-interference-matrix))))
               ;; 2. Anti-Armor Missile (`energy >= 75`, `>= 5` clump & `>= 6` allies firing)
               (and (>= en 75.0)
                    (let-values ([(ok? tgt _w)
                                  (best-unit-target
                                   ux uy 10.0 enemy-units
                                   (lambda ([e : Any])
                                     (define ex (uh-x e))
                                     (define ey (uh-y e))
                                     (and (sc2-enemy-unit-targetable? e)
                                          (not (uh-has-buff? e 'anti-armor-missile))
                                          (>= (count-units-within enemy-units ex ey 2.88 sc2-enemy-unit-targetable?) 5)
                                          (>= (count-units-within ally-units ex ey 11.0 unit-combat-relevant?) 6)
                                          (not (spell-point-claimed? claims 'anti-armor-missile ex ey ANTI-ARMOR-CLAIM-RADIUS current-frame))))
                                   (lambda ([e : Any])
                                     (->float (count-units-within enemy-units (uh-x e) (uh-y e) 2.88 sc2-enemy-unit-targetable?))))])
                      (and ok?
                           (spell-claim-unit?! claims 'anti-armor-missile (uh-tag tgt) current-frame ANTI-ARMOR-CLAIM-TTL
                                               #:caster-tag tag)
                           (spell-claim-point?! claims 'anti-armor-missile (uh-x tgt) (uh-y tgt)
                                                ANTI-ARMOR-CLAIM-RADIUS current-frame ANTI-ARMOR-CLAIM-TTL)
                           (spell-directive tag 'raven 'anti-armor-missile 'unit (uh-tag tgt)
                                            (uh-x tgt) (uh-y tgt) 'raven-anti-armor-missile))))
               ;; 3. Auto-Turret (`energy >= 50`, harass workers / melee / engaged zone)
               (and (>= en 50.0)
                    (let-values ([(ok? tgt _w)
                                  (best-unit-target
                                   ux uy 8.0 enemy-units
                                   (lambda ([e : Any])
                                     (or (and (memq (uh-type e) '(scv probe drone zergling zealot adept baneling dark-templar)) #t)
                                         (>= (count-units-within enemy-units (uh-x e) (uh-y e) 3.5 sc2-enemy-unit-targetable?) 2)))
                                   (lambda ([e : Any])
                                     (if (memq (uh-type e) '(scv probe drone))
                                         110.0
                                         (->float (* 20 (count-units-within enemy-units (uh-x e) (uh-y e) 3.5 sc2-enemy-unit-targetable?))))))])
                      (and ok?
                           (let* ([dx (- (uh-x tgt) ux)]
                                  [dy (- (uh-y tgt) uy)]
                                  [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                  [cast-d (min 2.5 (max 0.5 (- d 0.75)))]
                                  [tx (clamp-coord (+ ux (* cast-d (/ dx d))))]
                                  [ty (clamp-coord (+ uy (* cast-d (/ dy d))))])
                             (and (spell-claim-point?! claims 'auto-turret tx ty 2.5 current-frame 64)
                                  (spell-directive tag 'raven 'auto-turret 'point 0 tx ty 'raven-auto-turret)))))))]

             ;; --- BATTLECRUISER ---
             [(battlecruiser)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (define jump-ready? (not (eq? (dyn-hash-ref u 'tactical-jump-ready? #t) #f)))
                 (define yam-ready? (and yamato-ok? (not (eq? (dyn-hash-ref u 'yamato-ready? #t) #f))))
                 (or
                  ;; 1. Emergency Tactical Jump home when HP ratio < 0.32
                  (and jump-ready?
                       (< (uh-hp-ratio u) 0.32)
                       (> (dist2 ux uy home-x home-y) 12.0)
                       (spell-directive tag 'battlecruiser 'tactical-jump 'point 0 home-x home-y
                                        'bc-emergency-tactical-jump))
                  ;; 2. Yamato Cannon (`ceil(hp/240)` claim cap)
                  (and yam-ready?
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 10.0 enemy-units
                                      (lambda ([e : Any])
                                        (and (not (uh-hallucination? e))
                                             (> (bc-yamato-weight e) 0.0)))
                                      (lambda ([e : Any]) (bc-yamato-weight e)))])
                         (and ok?
                              (spell-claim-unit?! claims 'yamato-cannon (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag #:target-hp (uh-total-hp tgt))
                              (spell-directive tag 'battlecruiser 'yamato-cannon 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'bc-yamato-snipe)))))])]

             [else #f]))
         (if dir
             (values (cons dir acc) (cons tag used-tags))
             (values acc used-tags))])))
  (reverse dirs-rev))

;; -----------------------------------------------------------------------------
;; 8. Protoss Spellcaster Patterns (Sentry, High Templar, Oracle)
;; -----------------------------------------------------------------------------

(: ht-feedback-priority (-> Any Float))
(define (ht-feedback-priority e)
  (define en (uh-energy e))
  (if (< en 45.0)
      0.0
      (let ([base (case (uh-type e)
                    [(infestor infestor-burrowed) 200.0]
                    [(viper) 180.0]
                    [(ghost) 160.0]
                    [(medivac) 140.0]
                    [(high-templar) 125.0]
                    [(raven) 115.0]
                    [(oracle) 105.0]
                    [(sentry queen banshee battlecruiser) 75.0]
                    [else 0.0])])
        (if (> base 0.0) (+ base (* 0.35 en)) 0.0))))

(: force-field-splitter-target? (-> Any Boolean))
(define (force-field-splitter-target? e)
  (and (not (uh-flying? e))
       (not (memq (uh-type e) '(ultralisk ultralisk-burrowed archon colossus thor thor-ap)))
       (<= (enemy-ground-range e) 3.5)
       (sc2-enemy-unit-targetable? e)))

(: oracle-revelation-priority-target? (-> Any Boolean))
(define (oracle-revelation-priority-target? e)
  (and (not (uh-has-buff? e 'oracle-revelation))
       (or (uh-cloaked? e)
           (uh-burrowed? e)
           (and (memq (uh-type e)
                      '(lurker-burrowed lurker-mp-burrowed widow-mine-burrowed
                        banshee ghost dark-templar))
                #t))))

(: oracle-pulsar-victim? (-> Any Boolean))
(define (oracle-pulsar-victim? e)
  (and (not (uh-flying? e))
       (sc2-enemy-unit-targetable? e)
       (or (eq? (dyn-hash-ref e 'light? #f) #t)
           (eq? (safe-sym (dyn-hash-ref e 'attribute 'unknown) 'unknown) 'light)
           (and (memq (uh-type e)
                      '(scv probe drone marine zergling baneling zealot adept
                        high-templar dark-templar ghost reaper hellion hydralisk
                        sentry widow-mine locust swarm-host))
                #t))))

(: ht-dry-for-archon? (-> Any Boolean))
(define (ht-dry-for-archon? u)
  (and (hash? u)
       (eq? (uh-type u) 'high-templar)
       (> (uh-tag u) 0)
       (< (uh-energy u) 50.0)
       (not (spellcaster-channel-protected? u))))

;; Plan #115-calibrated Protoss spellcaster micro (`sentry`, `high-templar`, `oracle`)
;; enforcing Sentry `246f` GS / `~27f` Force Field stagger / `<1.8` ally trap guard,
;; HT `<=1` FF / Feedback priority / paired dry-HT `morph-archon`, and Oracle `[P0]`
;; strict 1-command-per-frame mutex + `>=60f` Pulsar Beam dwell.
(: plan-protoss-spellcaster-micro
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:psi-storm-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:natural-x Float
         #:natural-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:choke-points (Listof (Pairof Real Real))
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (plan-protoss-spellcaster-micro
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:psi-storm-researched? [psi-storm-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:natural-x [natural-x SC2-DEFAULT-NATURAL-X]
         #:natural-y [natural-y SC2-DEFAULT-NATURAL-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:choke-points [choke-points '()]
         #:exclude-tags [exclude-tags '()])
  (define all-enemies (append enemy-units enemy-buildings))
  (define all-allies (append ally-units ally-buildings))
  (define storm-ok?
    (or psi-storm-researched?
        (for/or : Boolean ([up (in-list researched-upgrades)])
          (and (memq (safe-sym up 'unknown) '(psi-storm psistorm psi-storm-tech psistorm-tech psionic-storm)) #t))))

  ;; Pre-collect friendly High Templar positions for Oracle Revelation support
  (define friendly-hts : (Listof Any)
    (for/list ([a (in-list ally-units)]
               #:when (and (hash? a) (eq? (uh-type a) 'high-templar)))
      a))

  ;; Phase A: Per-unit primary spell actions (`sentry`, `high-templar` Storm/Feedback, `oracle`)
  (define-values (dirs-rev used-tags)
    (for/fold ([acc : (Listof spell-directive) '()]
               [used : (Listof Integer) exclude-tags])
              ([u (in-list ally-units)])
      (define tag (if (hash? u) (uh-tag u) 0))
      (define sym (if (hash? u) (uh-type u) 'unknown))
      (cond
        [(or (<= tag 0) (memv tag used))
         (values acc used)]
        [else
         (define ux (uh-x u))
         (define uy (uh-y u))
         (define en (uh-energy u))
         (define sh (uh-shields u))
         (define dir : (Option spell-directive)
           (case sym
             ;; --- SENTRY ---
             [(sentry)
              (or
               ;; 1. Guardian Shield (`r=5.0 ttl=246f`, >= 3 allies within 4.5, >= 2 enemy ranged < 10.0)
               (and (>= en SC2-SENTRY-GUARDIAN-SHIELD-ENERGY)
                    (not (uh-has-buff? u 'guardian-shield))
                    (>= (count-units-within ally-units ux uy 4.5 unit-combat-relevant?) 3)
                    (>= (count-units-within enemy-units ux uy 10.0 enemy-ranged-threat?) 2)
                    (spell-claim-point?! claims 'guardian-shield ux uy
                                         GUARDIAN-SHIELD-CLAIM-RADIUS current-frame GUARDIAN-SHIELD-CLAIM-TTL)
                    (spell-directive tag 'sentry 'guardian-shield 'none 0 ux uy 'sentry-guardian-shield))
               ;; 2. Force Field (`energy >= 50`, `~27f` post-GS stagger, splitting >= 4 melee, zero allies < 1.8)
               (let* ([last-gs (spell-claims-last-guardian-shield-frame claims)]
                      [gs-stagger-ok? (or (< last-gs 0)
                                           (>= (- current-frame last-gs) SENTRY-FORCE-FIELD-POST-GS-DELAY-FRAMES))])
                 (and (>= en SC2-SENTRY-FORCE-FIELD-ENERGY)
                      gs-stagger-ok?
                      (let-values ([(ok? mx my _s)
                                    (best-enemy-cluster
                                     ux uy 10.5 enemy-units 3.5 0.0
                                     (lambda ([_cx : Float] [_cy : Float] [cl : (Listof Any)])
                                       (define mcnt (count-units-within cl _cx _cy 3.5 force-field-splitter-target?))
                                       (if (>= mcnt 4) (->float mcnt) 0.0)))])
                        (and ok?
                             (let* ([dx (- ux mx)]
                                    [dy (- uy my)]
                                    [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                    [fx (clamp-coord (+ mx (* 1.6 (/ dx d))))]
                                    [fy (clamp-coord (+ my (* 1.6 (/ dy d))))]
                                    [ally-trapped?
                                     (any-unit-within? ally-units fx fy 1.799
                                                       (lambda ([a : Any]) (not (uh-flying? a))))]
                                    [existing-ff?
                                     (any-effect-within? effects 'force-field fx fy 2.2 (lambda ([_e : Any]) #t))])
                               (and (<= (dist2 ux uy fx fy) 9.0)
                                    (not ally-trapped?)
                                    (not existing-ff?)
                                    (spell-claim-point?! claims 'force-field fx fy FORCE-FIELD-CLAIM-RADIUS current-frame FORCE-FIELD-CLAIM-TTL)
                                    (spell-directive tag 'sentry 'force-field 'point 0 fx fy 'sentry-force-field)))))))
               ;; 3. Hallucination Phoenix (~4:00-4:15 early scout, `88.6%`) / Archon surplus tank
               (let* ([scout-window? (and (>= current-frame 4480) (<= current-frame 7000))]
                      [no-recent-phoenix?
                       (> (- current-frame (spell-claims-last-hallucination-phoenix-frame claims)) 900)]
                      [safe? (not (any-unit-within? all-enemies ux uy 10.0 sc2-enemy-unit-targetable?))]
                      [engaged? (any-unit-within? enemy-units ux uy 10.0 sc2-enemy-unit-targetable?)])
                 (cond
                   [(and (>= en 75.0)
                         scout-window?
                         safe?
                         no-recent-phoenix?)
                    (set-spell-claims-last-hallucination-phoenix-frame! claims current-frame)
                    (spell-directive tag 'sentry 'hallucination-phoenix 'none 0 ux uy 'sentry-hallucination-phoenix-scout)]
                   [(and (>= en 125.0)
                         engaged?
                         (spell-claim-unit?! claims 'hallucination-archon tag current-frame 24 #:caster-tag tag))
                    (spell-directive tag 'sentry 'hallucination-archon 'none 0 ux uy 'sentry-hallucination-archon-tank)]
                   [(and (>= en 75.0)
                         safe?
                         no-recent-phoenix?
                         (<= current-frame 7200))
                    (set-spell-claims-last-hallucination-phoenix-frame! claims current-frame)
                    (spell-directive tag 'sentry 'hallucination-phoenix 'none 0 ux uy 'sentry-hallucination-phoenix-scout)]
                   [else #f])))]

             ;; --- HIGH TEMPLAR (Primary spells: Storm & Feedback) ---
             [(high-templar)
              (cond
                [(spellcaster-channel-protected? u) #f]
                [else
                 (or
                  ;; 1. Psi Storm (`energy >= 75`, `r=2.0 ttl=56f`, `<= 1` ally within `1.5`)
                  (and storm-ok?
                       (>= en 75.0)
                       (let-values ([(ok? sx sy _s)
                                     (best-enemy-cluster
                                      ux uy 9.0 enemy-units 2.0 0.25
                                      (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                        (define ally-in-1.5
                                          (count-units-within ally-units cx cy 1.5
                                                              (lambda ([a : Any]) (not (uh-hallucination? a)))))
                                        (if (and (>= (length cl) 2)
                                                 (<= ally-in-1.5 1)
                                                 (not (spell-point-claimed? claims 'psi-storm cx cy PSI-STORM-CLAIM-RADIUS current-frame)))
                                            (+ (* 35.0 (->float (length cl)))
                                               (* 0.08 (sum-units-fl cl uh-total-hp)))
                                            0.0)))])
                         (and ok?
                              (spell-claim-point?! claims 'psi-storm sx sy PSI-STORM-CLAIM-RADIUS current-frame PSI-STORM-CLAIM-TTL)
                              (begin
                                (hash-set! (spell-claims-ht-storm-frame claims) tag current-frame)
                                (spell-directive tag 'high-templar 'psi-storm 'point 0 sx sy 'ht-psi-storm)))))
                  ;; 2. Feedback (`Infestor -> Viper -> Ghost -> Medivac -> HT -> Raven -> Oracle`, 1/target)
                  (and (>= en 50.0)
                       (let-values ([(ok? tgt _w)
                                     (best-unit-target
                                      ux uy 10.0 enemy-units
                                      (lambda ([e : Any]) (> (ht-feedback-priority e) 0.0))
                                      (lambda ([e : Any]) (ht-feedback-priority e)))])
                         (and ok?
                              (spell-claim-unit?! claims 'feedback (uh-tag tgt) current-frame UNIT-SPELL-CLAIM-TTL
                                                  #:caster-tag tag)
                              (spell-directive tag 'high-templar 'feedback 'unit (uh-tag tgt)
                                               (uh-x tgt) (uh-y tgt) 'ht-feedback)))))])]

             ;; --- ORACLE (#115 [P0] Strict 1-command-per-frame mutex + >=60f Pulsar dwell) ---
             [(oracle)
              (define-values (beam-on? dwell) (oracle-pulsar-beam-active? claims u current-frame))
              (define near-enemy-cnt (count-units-within all-enemies ux uy 8.0 sc2-enemy-unit-targetable?))
              (cond
                ;; When Pulsar Beam is ON: ONLY permit OFF after >= 60f minimum dwell
                [beam-on?
                 (and (>= dwell ORACLE-PULSAR-BEAM-MIN-DWELL-FRAMES)
                      (or (< en 15.0)
                          (< sh 25.0)
                          (and (= near-enemy-cnt 0)
                               (>= dwell ORACLE-PULSAR-BEAM-ZERO-TARGET-DWELL-FRAMES)))
                      (begin
                        (hash-remove! (spell-claims-oracle-beam-start claims) tag)
                        (spell-directive tag 'oracle 'pulsar-beam-off 'none 0 ux uy
                                         'oracle-pulsar-beam-off)))]
                [else
                 ;; Branch (a): Oracle Revelation (`energy >= 25`, `r=6.0 ttl=448`)
                 (define rev-dir : (Option spell-directive)
                   (and (>= en 25.0)
                        (or
                         ;; (a1) Cloaked / burrowed priority threat
                         (let-values ([(ok? tgt _w)
                                       (best-unit-target
                                        ux uy 10.5 enemy-units oracle-revelation-priority-target?
                                        (lambda ([e : Any])
                                          (if (memq (uh-type e) '(lurker-burrowed lurker-mp-burrowed))
                                              120.0 95.0)))])
                           (and ok?
                                (spell-claim-point?! claims 'oracle-revelation (uh-x tgt) (uh-y tgt)
                                                     ORACLE-REVELATION-CLAIM-RADIUS current-frame ORACLE-REVELATION-CLAIM-TTL)
                                (spell-directive tag 'oracle 'oracle-revelation 'point 0
                                                 (uh-x tgt) (uh-y tgt) 'oracle-revelation-stealth)))
                         ;; (a2) Unrevealed enemy army ahead of friendly HTs
                         (let-values ([(ok? rx ry _s)
                                       (best-enemy-cluster
                                        ux uy 9.5 enemy-units 4.5 0.0
                                        (lambda ([cx : Float] [cy : Float] [cl : (Listof Any)])
                                          (define unrev-combat
                                            (for/sum : Integer ([e (in-list cl)])
                                              (if (and (not (uh-has-buff? e 'oracle-revelation))
                                                       (unit-combat-relevant? e))
                                                  1 0)))
                                          (define key-unrev?
                                            (for/or : Boolean ([e (in-list cl)])
                                              (and (not (uh-has-buff? e 'oracle-revelation))
                                                   (memq (uh-type e)
                                                         '(siege-tank-sieged colossus disruptor high-templar ghost immortal tempest liberator-ag))
                                                   #t)))
                                          (define ht-near?
                                            (any-unit-within? friendly-hts cx cy 16.0 (lambda ([_h : Any]) #t)))
                                          (if (and ht-near?
                                                   (or (>= unrev-combat 2) key-unrev?)
                                                   (not (spell-point-claimed? claims 'oracle-revelation cx cy
                                                                               ORACLE-REVELATION-CLAIM-RADIUS current-frame)))
                                              (+ (->float unrev-combat) (if key-unrev? 2.0 0.0))
                                              0.0)))])
                           (and ok?
                                (spell-claim-point?! claims 'oracle-revelation rx ry
                                                     ORACLE-REVELATION-CLAIM-RADIUS current-frame ORACLE-REVELATION-CLAIM-TTL)
                                (spell-directive tag 'oracle 'oracle-revelation 'point 0 rx ry
                                                 'oracle-revelation-army))))))
                 (or rev-dir
                     ;; Branch (b): Pulsar Beam ON (`energy >= 40`, `shields >= 35`, `>= 2` light/workers in `5.0`)
                     (and (>= en 40.0)
                          (>= sh 35.0)
                          (>= (count-units-within enemy-units ux uy 5.0 oracle-pulsar-victim?) 2)
                          (begin
                            (hash-set! (spell-claims-oracle-beam-start claims) tag current-frame)
                            (spell-directive tag 'oracle 'pulsar-beam-on 'none 0 ux uy
                                             'oracle-pulsar-beam-on)))
                     ;; Branch (c): Stasis Ward (`beam OFF` & `energy >= 55`) at choke or approach
                     (and (>= en 55.0)
                          (let* ([safe-site?
                                  (lambda ([wx : Float] [wy : Float])
                                    (and (<= (dist2 ux uy wx wy) 8.0)
                                         (not (any-unit-within? all-enemies wx wy 4.5 sc2-enemy-unit-targetable?))
                                         (not (any-unit-within?
                                               all-allies wx wy 4.5
                                               (lambda ([a : Any]) (and (memq (uh-type a) '(oracle-stasis-trap stasis-ward)) #t))))
                                         (not (spell-point-claimed? claims 'stasis-ward wx wy STASIS-WARD-CLAIM-RADIUS current-frame))))]
                                 [choke-pt : (Option (Pairof Float Float))
                                  (for/or : (Option (Pairof Float Float)) ([cp (in-list choke-points)])
                                    (define cx (safe-fl (car cp) 0.0))
                                    (define cy (safe-fl (cdr cp) 0.0))
                                    (and (safe-site? cx cy) (cons cx cy)))]
                                 [default-pt : (Option (Pairof Float Float))
                                  (let* ([dx (- enemy-base-x ux)]
                                         [dy (- enemy-base-y uy)]
                                         [d (max 0.01 (flsqrt (+ (* dx dx) (* dy dy))))]
                                         [wx (clamp-coord (if (<= (dist2 ux uy natural-x natural-y) 8.0)
                                                              (+ natural-x (* 2.5 (/ (- enemy-base-x natural-x)
                                                                                     (max 0.01 (dist2 natural-x natural-y enemy-base-x enemy-base-y)))))
                                                              (+ ux (* 2.5 (/ dx d)))))]
                                         [wy (clamp-coord (if (<= (dist2 ux uy natural-x natural-y) 8.0)
                                                              (+ natural-y (* 2.5 (/ (- enemy-base-y natural-y)
                                                                                     (max 0.01 (dist2 natural-x natural-y enemy-base-x enemy-base-y)))))
                                                              (+ uy (* 2.5 (/ dy d)))))])
                                    (and (safe-site? wx wy) (cons wx wy)))]
                                 [chosen (or choke-pt default-pt)])
                            (and chosen
                                 (spell-claim-point?! claims 'stasis-ward (car chosen) (cdr chosen)
                                                      STASIS-WARD-CLAIM-RADIUS current-frame STASIS-WARD-CLAIM-TTL)
                                 (spell-directive tag 'oracle 'stasis-ward 'point 0
                                                  (car chosen) (cdr chosen) 'oracle-stasis-ward)))))])]

             [else #f]))
         (if dir
             (values (cons dir acc) (cons tag used))
             (values acc used))])))

  ;; Phase B: Post-storm dry High Templars (< 50 energy) -> Archon pair merge vs unpaired kite
  (define dry-hts : (Listof Any)
    (for/list ([u (in-list ally-units)]
               #:when (and (ht-dry-for-archon? u)
                           (not (memv (uh-tag u) used-tags))))
      u))

  (define-values (final-rev _paired)
    (let loop : (Values (Listof spell-directive) (Listof Integer))
         ([rem : (Listof Any) dry-hts]
          [acc : (Listof spell-directive) dirs-rev]
          [seen : (Listof Integer) used-tags])
      (cond
        [(null? rem) (values acc seen)]
        [else
         (define ht1 (car rem))
         (define t1 (uh-tag ht1))
         (cond
           [(memv t1 seen) (loop (cdr rem) acc seen)]
           [else
            (define x1 (uh-x ht1))
            (define y1 (uh-y ht1))
            ;; Find closest dry HT partner within 20.0 tiles
            (define-values (partner _best-d)
              (for/fold ([best : Any #f]
                         [bd : Float 20.001])
                        ([cand (in-list (cdr rem))])
                (define ctag (uh-tag cand))
                (if (memv ctag seen)
                    (values best bd)
                    (let ([d (dist2 x1 y1 (uh-x cand) (uh-y cand))])
                      (if (< d bd)
                          (values cand d)
                          (values best bd))))))
            (cond
              [(hash? partner)
               (define t2 (uh-tag partner))
               (define mx (* 0.5 (+ x1 (uh-x partner))))
               (define my (* 0.5 (+ y1 (uh-y partner))))
               (hash-set! (spell-claims-ht-merge-lock-until claims) t1 (+ current-frame HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES))
               (hash-set! (spell-claims-ht-merge-lock-until claims) t2 (+ current-frame HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES))
               (loop (cdr rem)
                     (cons (spell-directive t1 'high-templar 'morph-archon 'pair t2 mx my
                                            'ht-post-storm-archon-merge)
                           acc)
                     (cons t1 (cons t2 seen)))]
              [else
               ;; Unpaired dry HT: only kite if not inside an active merge lock and threatened
               (define merge-until (hash-ref (spell-claims-ht-merge-lock-until claims) t1 (lambda () -1)))
               (define threatened? (any-unit-within? all-enemies x1 y1 10.0 sc2-enemy-unit-targetable?))
               (if (and (>= current-frame merge-until) threatened?)
                   (let-values ([(rx ry) (safe-retreat-point x1 y1 all-enemies home-x home-y 8.0)])
                     (loop (cdr rem)
                           (cons (spell-directive t1 'high-templar 'move 'kite 0 rx ry
                                                  'ht-unpaired-dry-kite)
                                 acc)
                           (cons t1 seen)))
                   (loop (cdr rem) acc (cons t1 seen)))])])])))
  (reverse final-rev))

;; -----------------------------------------------------------------------------
;; 9. Unified Multi-Race Spellcaster Entrypoints
;; -----------------------------------------------------------------------------

;; Plan pro-calibrated spellcaster micro across Zerg, Terran, and Protoss casters
;; in a single pass after pruning expired `spell-claims`.
(: step-pro-spellcaster-micro!
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:psi-storm-researched? Boolean
         #:yamato-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:natural-x Float
         #:natural-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:inject-queen-tags (Listof Integer)
         #:choke-points (Listof (Pairof Real Real))
         #:exclude-tags (Listof Integer))
        (Listof spell-directive)))
(define (step-pro-spellcaster-micro!
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:psi-storm-researched? [psi-storm-researched? #t]
         #:yamato-researched? [yamato-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:natural-x [natural-x SC2-DEFAULT-NATURAL-X]
         #:natural-y [natural-y SC2-DEFAULT-NATURAL-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:inject-queen-tags [inject-queen-tags '()]
         #:choke-points [choke-points '()]
         #:exclude-tags [exclude-tags '()])
  (prune-spell-claims! claims current-frame)
  (append
   (plan-zerg-spellcaster-micro
    ally-units enemy-units
    #:claims claims
    #:current-frame current-frame
    #:ally-buildings ally-buildings
    #:enemy-buildings enemy-buildings
    #:effects effects
    #:home-x home-x
    #:home-y home-y
    #:enemy-base-x enemy-base-x
    #:enemy-base-y enemy-base-y
    #:inject-queen-tags inject-queen-tags
    #:exclude-tags exclude-tags)
   (plan-terran-spellcaster-micro
    ally-units enemy-units
    #:claims claims
    #:current-frame current-frame
    #:ally-buildings ally-buildings
    #:enemy-buildings enemy-buildings
    #:effects effects
    #:researched-upgrades researched-upgrades
    #:yamato-researched? yamato-researched?
    #:home-x home-x
    #:home-y home-y
    #:exclude-tags exclude-tags)
   (plan-protoss-spellcaster-micro
    ally-units enemy-units
    #:claims claims
    #:current-frame current-frame
    #:ally-buildings ally-buildings
    #:enemy-buildings enemy-buildings
    #:effects effects
    #:researched-upgrades researched-upgrades
    #:psi-storm-researched? psi-storm-researched?
    #:home-x home-x
    #:home-y home-y
    #:natural-x natural-x
    #:natural-y natural-y
    #:enemy-base-x enemy-base-x
    #:enemy-base-y enemy-base-y
    #:choke-points choke-points
    #:exclude-tags exclude-tags)))

;; Convenience wrapper returning `sc2-typed-commands`-ready S-expression commands.
(: step-pro-spellcaster-sexps!
   (->* ((Listof Any) (Listof Any))
        (#:claims spell-claims
         #:current-frame Integer
         #:ally-buildings (Listof Any)
         #:enemy-buildings (Listof Any)
         #:effects (Listof Any)
         #:researched-upgrades (Listof Any)
         #:psi-storm-researched? Boolean
         #:yamato-researched? Boolean
         #:home-x Float
         #:home-y Float
         #:natural-x Float
         #:natural-y Float
         #:enemy-base-x Float
         #:enemy-base-y Float
         #:inject-queen-tags (Listof Integer)
         #:choke-points (Listof (Pairof Real Real))
         #:exclude-tags (Listof Integer))
        (Listof (Listof Any))))
(define (step-pro-spellcaster-sexps!
         ally-units enemy-units
         #:claims [claims (make-spell-claims)]
         #:current-frame [current-frame 0]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:effects [effects '()]
         #:researched-upgrades [researched-upgrades '()]
         #:psi-storm-researched? [psi-storm-researched? #t]
         #:yamato-researched? [yamato-researched? #t]
         #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
         #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
         #:natural-x [natural-x SC2-DEFAULT-NATURAL-X]
         #:natural-y [natural-y SC2-DEFAULT-NATURAL-Y]
         #:enemy-base-x [enemy-base-x SC2-DEFAULT-ENEMY-BASE-X]
         #:enemy-base-y [enemy-base-y SC2-DEFAULT-ENEMY-BASE-Y]
         #:inject-queen-tags [inject-queen-tags '()]
         #:choke-points [choke-points '()]
         #:exclude-tags [exclude-tags '()])
  (map spell-directive->sexp
       (step-pro-spellcaster-micro!
        ally-units enemy-units
        #:claims claims
        #:current-frame current-frame
        #:ally-buildings ally-buildings
        #:enemy-buildings enemy-buildings
        #:effects effects
        #:researched-upgrades researched-upgrades
        #:psi-storm-researched? psi-storm-researched?
        #:yamato-researched? yamato-researched?
        #:home-x home-x
        #:home-y home-y
        #:natural-x natural-x
        #:natural-y natural-y
        #:enemy-base-x enemy-base-x
        #:enemy-base-y enemy-base-y
        #:inject-queen-tags inject-queen-tags
        #:choke-points choke-points
        #:exclude-tags exclude-tags)))
