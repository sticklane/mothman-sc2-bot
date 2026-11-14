#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/multitask-harass-and-proxy.rkt`
;; Multi-Tasking Harass, Off-Path Proxy All-Ins (Each Race + Random Variants),
;; Air Worker Harass, Simultaneous Multi-Base Viking Landings & Anti-Baneling
;; Splitting / Zero-Overkill Target-Fire <-> Baneling Move-Past & Landmines.
;;
;; Self-contained Typed Racket module using pure vector geometry (ZERO cyclic
;; dependencies and ZERO dependency on `lib/sc2-placement.rkt`).
;; =============================================================================

(require racket/list
         racket/math
         racket/flonum
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-geometry.rkt"
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

;; Safe dynamic hash boundary for heterogeneous untyped unit observation hashes.
(module dyn-hash-ops racket/base
  (provide dyn-hash-ref
           dyn-hash-has-key?
           dyn-u-raw-type
           dyn-u-raw-tag
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
  [dyn-u-alive-fast (-> Any Symbol)])

(provide
 ;; Canonical Constants
 ADEPT-PHASE-SHIFT-ABILITY-ID
 CANCEL-ADEPT-PHASE-SHIFT-ABILITY-ID
 WIDOW-MINE-BURROW-ABILITY-ID
 WIDOW-MINE-RETARGET-ABILITY-ID
 WIDOW-MINE-BURROWED-UNIT-ID
 AUTO-TURRET-ABILITY-ID
 ANTI-ARMOR-MISSILE-ABILITY-ID
 PULSAR-BEAM-ABILITY-ID
 STASIS-WARD-ABILITY-ID
 ORACLE-REVELATION-ABILITY-ID
 MORPH-VIKING-ASSAULT-ABILITY-ID
 MORPH-VIKING-FIGHTER-ABILITY-ID
 BANELING-EXPLODE-ABILITY-ID
 BANELING-UNIT-TYPE-ID
 BANELING-BURROWED-UNIT-TYPE-ID
 WIDOW-MINE-SYNC-MAX-DELTA-FRAMES
 WIDOW-MINE-WORKER-PULL-SAFE-RANGE
 RUNBY-ENEMY-MOVEOUT-THRESHOLD
 OFF-PATH-PROXY-PERP-MIN
 OFF-PATH-PROXY-PERP-MAX
 ANTI-BANELING-SPLIT-RADIUS
 BANELING-SPLASH-RADIUS
 BANELING-LANDMINE-DETONATE-RADIUS
 BANELING-SAFE-SPACING

 ;; Structs
 (struct-out harass-directive)
 (struct-out widow-mine-runby-plan)
 (struct-out proxy-all-in-spec)
 (struct-out counter-proxy-plan)

 ;; Multi-Base Adept Split Harass & Counter
 plan-multi-base-adept-harass
 plan-counter-adept-harass

 ;; Widow Mine Drop Timed with Ground Runby, Clump Retargeting (`2099`) & Trigger Bait
 plan-widow-mine-drop-and-runby
 plan-counter-widow-mine-drop
 plan-widow-mine-retarget-and-bait

 ;; Cross-Race Coordinated Runby Catalog & Counter
 plan-coordinated-runby-tactics
 plan-counter-runby-defense

 ;; Off-Path Proxy All-Ins (T/P/Z + Random Variants) & Counter
 compute-off-path-proxy-coords
 plan-off-path-proxy-all-in
 plan-counter-proxy-all-in

 ;; Raven, Oracle & Simultaneous Multi-Base Viking Landings + Counters
 plan-air-worker-harass-tactics
 plan-counter-air-worker-harass

 ;; Anti-Baneling Fan Split + Zero-Overkill Target-Fire <-> Move-Past & Landmines
 plan-anti-baneling-split-and-target-fire
 plan-baneling-move-past-and-light-clump-detonate

 ;; S-Expression Orchestration
 harass-directive->sexp
 step-multitask-harass-and-proxy)

;; =============================================================================
;; Constants
;; =============================================================================

(: ADEPT-PHASE-SHIFT-ABILITY-ID Integer)
(define ADEPT-PHASE-SHIFT-ABILITY-ID 2544)

(: CANCEL-ADEPT-PHASE-SHIFT-ABILITY-ID Integer)
(define CANCEL-ADEPT-PHASE-SHIFT-ABILITY-ID 2594) ;; `2546` in raw replay events

(: WIDOW-MINE-BURROW-ABILITY-ID Integer)
(define WIDOW-MINE-BURROW-ABILITY-ID 2095)

(: WIDOW-MINE-RETARGET-ABILITY-ID Integer)
(define WIDOW-MINE-RETARGET-ABILITY-ID 2099)

(: WIDOW-MINE-BURROWED-UNIT-ID Integer)
(define WIDOW-MINE-BURROWED-UNIT-ID 500)

(: AUTO-TURRET-ABILITY-ID Integer)
(define AUTO-TURRET-ABILITY-ID 349)

(: ANTI-ARMOR-MISSILE-ABILITY-ID Integer)
(define ANTI-ARMOR-MISSILE-ABILITY-ID 3753)

(: PULSAR-BEAM-ABILITY-ID Integer)
(define PULSAR-BEAM-ABILITY-ID 2375)

(: STASIS-WARD-ABILITY-ID Integer)
(define STASIS-WARD-ABILITY-ID 2505)

(: ORACLE-REVELATION-ABILITY-ID Integer)
(define ORACLE-REVELATION-ABILITY-ID 2146)

(: MORPH-VIKING-ASSAULT-ABILITY-ID Integer)
(define MORPH-VIKING-ASSAULT-ABILITY-ID 403)

(: MORPH-VIKING-FIGHTER-ABILITY-ID Integer)
(define MORPH-VIKING-FIGHTER-ABILITY-ID 405)

(: BANELING-EXPLODE-ABILITY-ID Integer)
(define BANELING-EXPLODE-ABILITY-ID 42)

(: BANELING-UNIT-TYPE-ID Integer)
(define BANELING-UNIT-TYPE-ID 9)

(: BANELING-BURROWED-UNIT-TYPE-ID Integer)
(define BANELING-BURROWED-UNIT-TYPE-ID 115)

(: WIDOW-MINE-SYNC-MAX-DELTA-FRAMES Integer)
(define WIDOW-MINE-SYNC-MAX-DELTA-FRAMES 48)

(: WIDOW-MINE-WORKER-PULL-SAFE-RANGE Float)
(define WIDOW-MINE-WORKER-PULL-SAFE-RANGE 5.5)

(: RUNBY-ENEMY-MOVEOUT-THRESHOLD Float)
(define RUNBY-ENEMY-MOVEOUT-THRESHOLD 22.0)

(: OFF-PATH-PROXY-PERP-MIN Float)
(define OFF-PATH-PROXY-PERP-MIN 24.0)

(: OFF-PATH-PROXY-PERP-MAX Float)
(define OFF-PATH-PROXY-PERP-MAX 38.0)

(: ANTI-BANELING-SPLIT-RADIUS Float)
(define ANTI-BANELING-SPLIT-RADIUS 7.5)

(: BANELING-SPLASH-RADIUS Float)
(define BANELING-SPLASH-RADIUS 2.2)

(: BANELING-LANDMINE-DETONATE-RADIUS Float)
(define BANELING-LANDMINE-DETONATE-RADIUS 2.1)

(: BANELING-SAFE-SPACING Float)
(define BANELING-SAFE-SPACING 2.4)

;; =============================================================================
;; Public Data Structs
;; =============================================================================

;; Unified multi-task harass / proxy / defense / baneling-micro directive.
(struct harass-directive
  ([unit-tag : Integer]
   [unit-type : Symbol]
   [action : Symbol]
   [ability : (Option Symbol)]
   [ability-id : Integer]
   [target-tag : Integer]
   [tx : Float]
   [ty : Float]
   [priority : Float]
   [reason : Symbol]
   [meta : Symbol])
  #:transparent)

;; Synchronized Widow Mine Drop + ground Hellion/Marine runby plan.
(struct widow-mine-runby-plan
  ([synchronized? : Boolean]
   [sync-delta-frames : Integer]
   [medivac-drop-pt : (Pair Float Float)]
   [runby-pt : (Pair Float Float)]
   [directives : (Listof harass-directive)])
  #:transparent)

;; Race & Random-aware off-path proxy all-in build specification + builder orders.
(struct proxy-all-in-spec
  ([our-race : Symbol]
   [enemy-race : Symbol]
   [variant : Symbol]
   [site-x : Float]
   [site-y : Float]
   [perp-axis-dist : Float]
   [buildings : (Listof Symbol)]
   [unit-comp : (Listof Symbol)]
   [trigger-frame : Integer]
   [directives : (Listof harass-directive)])
  #:transparent)

;; Early proxy detection & lateral scouting / static-defense response plan.
(struct counter-proxy-plan
  ([missing-home-prod? : Boolean]
   [suspected-enemy-race : Symbol]
   [scout-targets : (Listof (Pair Float Float))]
   [defensive-buildings : (Listof Symbol)]
   [directives : (Listof harass-directive)]
   [reason : Symbol])
  #:transparent)

;; =============================================================================
;; Unit Extraction & Geometry Helpers (Typed, Self-Contained)
;; =============================================================================

(: ->float (-> Real Float))
(define (->float r) (real->double-flonum r))

(: safe-finite-real (-> Any Float Float))
(define (safe-finite-real v default)
  (if (and (real? v) (not (nan? v)) (not (infinite? v)))
      (real->double-flonum v)
      default))

(: safe-int (-> Any Integer Integer))
(define (safe-int v default)
  (if (exact-integer? v) v default))

(: clamp-coord (-> Float Float Float Float))
(define (clamp-coord v lo hi)
  (max lo (min hi v)))

(: clamp-pt (-> Real Real Float Float (Pair Float Float)))
(define (clamp-pt x y map-w map-h)
  (define lo 4.0)
  (define max-x (max 16.0 (- map-w 4.0)))
  (define max-y (max 16.0 (- map-h 4.0)))
  (cons (clamp-coord (->float x) lo max-x)
        (clamp-coord (->float y) lo max-y)))

(: dist2 (-> Float Float Float Float Float))
(define (dist2 x1 y1 x2 y2)
  (define dx (- x1 x2))
  (define dy (- y1 y2))
  (flsqrt (+ (* dx dx) (* dy dy))))

(: id->sym (-> Integer Symbol))
(define (id->sym tid)
  (case tid
    [(9)    'baneling]
    [(115)  'baneling-burrowed]
    [(53)   'hellion]
    [(484)  'hellbat]
    [(498)  'widow-mine]
    [(500)  'widow-mine-burrowed]
    [(54)   'medivac]
    [(56)   'raven]
    [(379)  'auto-turret]
    [(34)   'viking-assault]
    [(35)   'viking-fighter]
    [(311)  'adept]
    [(801)  'adept-phase-shift]
    [(495)  'oracle]
    [(732)  'oracle-stasis-trap]
    [(893)  'overlord-transport]
    [(692)  'cyclone]
    [else   'unknown]))

(require (only-in typed/racket/unsafe unsafe-require/typed))

(module dyn-harass-fast racket/base
  (provide dyn-u-type-sym
           dyn-u-tag-int
           dyn-u-x-fl
           dyn-u-y-fl
           dyn-u-structure-flag)
  (define (id->sym-fast tid)
    (case tid
      [(9)    'baneling]
      [(115)  'baneling-burrowed]
      [(53)   'hellion]
      [(484)  'hellbat]
      [(498)  'widow-mine]
      [(500)  'widow-mine-burrowed]
      [(54)   'medivac]
      [(56)   'raven]
      [(379)  'auto-turret]
      [(34)   'viking-assault]
      [(35)   'viking-fighter]
      [(311)  'adept]
      [(801)  'adept-phase-shift]
      [(495)  'oracle]
      [(732)  'oracle-stasis-trap]
      [(692)  'cyclone]
      [else   'unknown]))
  (define (to-fl v)
    (if (and (real? v) (< -inf.0 v +inf.0))
        (real->double-flonum v)
        0.0))
  (define (dyn-u-type-sym u)
    (cond
      [(symbol? u) u]
      [(exact-integer? u) (id->sym-fast u)]
      [(hash? u)
       (define raw (or (hash-ref u 'type #f) (hash-ref u 'unit-type #f)))
       (cond
         [(symbol? raw) raw]
         [(exact-integer? raw) (id->sym-fast raw)]
         [else 'unknown])]
      [else 'unknown]))
  (define (dyn-u-tag-int u)
    (if (hash? u)
        (let ([t (or (hash-ref u 'tag #f) (hash-ref u 'id #f))])
          (if (exact-integer? t) t 0))
        0))
  (define (dyn-u-x-fl u)
    (if (hash? u) (to-fl (hash-ref u 'x 0.0)) 0.0))
  (define (dyn-u-y-fl u)
    (if (hash? u) (to-fl (hash-ref u 'y 0.0)) 0.0))
  (define (dyn-u-structure-flag u)
    (and (hash? u)
         (or (eq? (hash-ref u 'is-building #f) #t)
             (eq? (hash-ref u 'is-structure #f) #t)))))

(unsafe-require/typed (submod "." dyn-harass-fast)
  [dyn-u-type-sym (-> Any Symbol)]
  [dyn-u-tag-int (-> Any Integer)]
  [dyn-u-x-fl (-> Any Float)]
  [dyn-u-y-fl (-> Any Float)]
  [dyn-u-structure-flag (-> Any Boolean)])

(: u-type (-> Any Symbol))
(define (u-type u)
  (dyn-u-type-sym u))

(: u-tag (-> Any Integer))
(define (u-tag u)
  (dyn-u-tag-int u))

(: u-x (-> Any Float))
(define (u-x u)
  (dyn-u-x-fl u))

(: u-y (-> Any Float))
(define (u-y u)
  (dyn-u-y-fl u))

(: u-hp (-> Any Float Float))
(define (u-hp u default)
  (cond
    [(dyn-hash-has-key? u 'hp) (max 0.0 (safe-finite-real (dyn-hash-ref u 'hp default) default))]
    [(dyn-hash-has-key? u 'health) (max 0.0 (safe-finite-real (dyn-hash-ref u 'health default) default))]
    [else default]))

(define-type HarassCombatStatTable (Immutable-HashTable Symbol (U Real Boolean Symbol)))

(struct unit-combat-cache
  ([def-hp-50 : Float]
   [def-hp-100 : Float]
   [def-sh : Float]
   [max-dps : Float]))

(define *harass-combat-cache* : (HashTable Symbol unit-combat-cache) (make-hasheq))

(: cached-unit-combat (-> Symbol unit-combat-cache))
(define (cached-unit-combat ut)
  (hash-ref!
   *harass-combat-cache*
   ut
   (lambda ()
     (define stats : HarassCombatStatTable (sc2-unit-combat-stats ut))
     (define raw-hp (hash-ref stats 'max-hp (lambda () #f)))
     (define def-hp-50 (safe-finite-real raw-hp 50.0))
     (define def-hp-100 (safe-finite-real raw-hp 100.0))
     (define def-sh (safe-finite-real (hash-ref stats 'max-shield (lambda () 0.0)) 0.0))
     (define gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0))
     (define adps (safe-finite-real (hash-ref stats 'air-dps (lambda () 0.0)) 0.0))
     (unit-combat-cache def-hp-50 def-hp-100 def-sh (max gdps adps)))))

(: u-ehp/cached (-> Any unit-combat-cache Float))
(define (u-ehp/cached u c)
  (define def-sh (unit-combat-cache-def-sh c))
  (define cur-hp (u-hp u (unit-combat-cache-def-hp-50 c)))
  (define cur-sh
    (cond
      [(dyn-hash-has-key? u 'shield) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shield def-sh) def-sh))]
      [(dyn-hash-has-key? u 'shields) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shields def-sh) def-sh))]
      [else def-sh]))
  (+ cur-hp cur-sh))

(: u-ehp (-> Any Float))
(define (u-ehp u)
  (u-ehp/cached u (cached-unit-combat (u-type u))))

(: u-hp-ratio (-> Any Float))
(define (u-hp-ratio u)
  (define c (cached-unit-combat (u-type u)))
  (define mhp (max 1.0 (safe-finite-real (dyn-hash-ref u 'max-hp (unit-combat-cache-def-hp-100 c)) 100.0)))
  (define msh (max 0.0 (safe-finite-real (dyn-hash-ref u 'max-shield (unit-combat-cache-def-sh c)) 0.0)))
  (max 0.0 (min 1.0 (/ (u-ehp/cached u c) (max 1.0 (+ mhp msh))))))

(: u-alive? (-> Any Boolean))
(define (u-alive? u)
  (case (dyn-u-alive-fast u)
    [(true) #t]
    [(false) #f]
    [else (> (u-ehp u) 0.0)]))

(: u-energy (-> Any Float))
(define (u-energy u)
  (safe-finite-real (dyn-hash-ref u 'energy 0.0) 0.0))

(: u-flying? (-> Any Boolean))
(define (u-flying? u)
  (define ut (u-type u))
  (or (eq? (dyn-hash-ref u 'flying? #f) #t)
      (eq? (dyn-hash-ref u 'flying #f) #t)
      (eq? (dyn-hash-ref u 'is-flying #f) #t)
      (and (not (eq? ut 'viking-assault))
           (sc2-unit-is-flying-sym? ut))))

(define *harass-structure-sym-set* : (Immutable-HashTable Symbol Boolean)
  (for/hasheq : (Immutable-HashTable Symbol Boolean)
              ([s (in-list (cons 'auto-turret (cons 'oracle-stasis-trap SC2-ALL-STRUCTURE-SYMS)))])
    (values s #t)))

(: u-structure? (-> Any Boolean))
(define (u-structure? u)
  (define ut (u-type u))
  (or (hash-has-key? *harass-structure-sym-set* ut)
      (dyn-u-structure-flag u)))

(: u-worker? (-> Symbol Boolean))
(define (u-worker? ut)
  (not (not (memq ut '(scv probe drone mule)))))

(: unit-power (-> Any Float))
(define (unit-power u)
  (define ut (u-type u))
  (cond
    [(memq ut '(larva egg changeling adept-phase-shift observer overlord)) 0.0]
    [else
     (define c (cached-unit-combat ut))
     (define dps (unit-combat-cache-max-dps c))
     (define ehp (u-ehp/cached u c))
     (cond
       [(> dps 0.0) (max 5.0 (flsqrt (max 0.0 (* ehp dps))))]
       [(u-structure? u) (flsqrt (max 0.0 (* 0.35 ehp)))]
       [else 4.0])]))

(: sum-unit-power (-> (Listof Any) Float Float Float Float))
(define (sum-unit-power units cx cy radius)
  (define r2 (* radius radius))
  (for/fold ([acc : Float 0.0])
            ([u (in-list units)])
    (if (u-alive? u)
        (let ([dx (- cx (u-x u))]
              [dy (- cy (u-y u))])
          (if (and (<= (abs dx) radius)
                   (<= (abs dy) radius)
                   (<= (+ (* dx dx) (* dy dy)) r2))
              (+ acc (unit-power u))
              acc))
        acc)))

(: infer-base-targets (-> (Listof Any) Float Float (Option Real) (Option Real) (Listof (Pair Float Float))))
(define (infer-base-targets enemy-units hx hy emx emy)
  (define townhalls
    (sort
     (for/list : (Listof Any)
               ([e (in-list enemy-units)]
                #:when (and (u-alive? e)
                            (memq (u-type e)
                                  '(nexus command-center orbital-command
                                    planetary-fortress hatchery lair hive))))
       e)
     (lambda ([a : Any] [b : Any])
       (> (dist2 hx hy (u-x a) (u-y a))
          (dist2 hx hy (u-x b) (u-y b))))))
  (cond
    [(>= (length townhalls) 2)
     (for/list : (Listof (Pair Float Float)) ([th (in-list (take townhalls (min 3 (length townhalls))))])
       (cons (u-x th) (u-y th)))]
    [(or (= (length townhalls) 1) (and emx emy))
     (define mx (if (pair? townhalls) (u-x (car townhalls)) (->float (or emx 130.0))))
     (define my (if (pair? townhalls) (u-y (car townhalls)) (->float (or emy 130.0))))
     (define dx (- hx mx))
     (define dy (- hy my))
     (define n (max 1e-4 (dist2 0.0 0.0 dx dy)))
     (define ux (/ dx n))
     (define uy (/ dy n))
     (list (cons mx my)
           (clamp-pt (+ mx (* 28.0 ux)) (+ my (* 28.0 uy)) 200.0 200.0)
           (clamp-pt (+ mx (* 32.0 (- uy))) (+ my (* 32.0 ux)) 200.0 200.0))]
    [else
     (list (cons 136.0 136.0) (cons 136.0 104.0) (cons 104.0 136.0))]))

(: infer-ally-bases (-> (Listof Any) Float Float (Listof (Pair Float Float))))
(define (infer-ally-bases ally-units hx hy)
  (define ths
    (for/list : (Listof (Pair Float Float))
              ([a (in-list ally-units)]
               #:when (and (u-alive? a)
                           (memq (u-type a)
                                 '(nexus command-center orbital-command
                                   planetary-fortress hatchery lair hive))))
      (cons (u-x a) (u-y a))))
  (if (pair? ths) ths (list (cons hx hy))))

(: find-nearest-worker (-> Float Float (Listof Any) Float (Option Any)))
(define (find-nearest-worker tx ty enemy-units radius)
  (define r2 (* radius radius))
  (for/fold ([best : (Option Any) #f] [bd2 : Float r2] #:result best)
            ([e (in-list enemy-units)]
             #:when (and (u-alive? e) (> (u-tag e) 0) (u-worker? (u-type e))))
    (define dx (- tx (u-x e)))
    (define dy (- ty (u-y e)))
    (define d2 (+ (* dx dx) (* dy dy)))
    (if (< d2 bd2) (values e d2) (values best bd2))))

(: point-to-segment-dist (-> Float Float Float Float Float Float Float))
(define (point-to-segment-dist px py ax ay bx by)
  (define abx (- bx ax))
  (define aby (- by ay))
  (define ab2 (+ (* abx abx) (* aby aby)))
  (if (<= ab2 1e-6)
      (dist2 px py ax ay)
      (let* ([apx (- px ax)]
             [apy (- py ay)]
             [t (max 0.0 (min 1.0 (/ (+ (* apx abx) (* apy aby)) ab2)))]
             [cx (+ ax (* t abx))]
             [cy (+ ay (* t aby))])
        (dist2 px py cx cy))))

(: normalize-race (-> Symbol Symbol))
(define (normalize-race r)
  (case r
    [(terran Terran T t) 'Terran]
    [(protoss Protoss P p) 'Protoss]
    [(zerg Zerg Z z) 'Zerg]
    [(random Random R r unknown Unknown) 'Random]
    [else 'Random]))

;; =============================================================================
;; 1. Multi-Base Adept Split Harass & Counter
;; =============================================================================

;; Splits Adepts across two enemy mineral lines using `adept-phase-shift` (`2544`) into Base B
;; while engaging Base A, and emits `cancel-adept-phase-shift` (`2594` / raw `2546`) if the
;; Base B shade destination has `enemy-power > 1.2 * adept-power`.
(: plan-multi-base-adept-harass
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real
         #:home-y Real
         #:enemy-main-x (Option Real)
         #:enemy-main-y (Option Real)
         #:enemy-targets (Listof (Pair Real Real))
         #:max-safe-power-ratio Real)
        (Listof harass-directive)))
(define (plan-multi-base-adept-harass ally-units enemy-units
                                      #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                      #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                      #:enemy-main-x [emx #f]
                                      #:enemy-main-y [emy #f]
                                      #:enemy-targets [explicit-targets '()]
                                      #:max-safe-power-ratio [power-ratio-kw 1.2])
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define power-ratio (->float power-ratio-kw))
  (define-values (rev-adepts rev-shades)
    (for/fold ([as : (Listof Any) '()] [ss : (Listof Any) '()])
              ([a (in-list ally-units)])
      (define ut (u-type a))
      (cond
        [(and (eq? ut 'adept) (> (u-tag a) 0) (u-alive? a))
         (values (cons a as) ss)]
        [(and (eq? ut 'adept-phase-shift) (u-alive? a))
         (values as (cons a ss))]
        [else (values as ss)])))
  (cond
    [(and (null? rev-adepts) (null? rev-shades)) '()]
    [else
     (define adepts (reverse rev-adepts))
     (define shades (reverse rev-shades))
     (cond
       [(null? adepts) '()]
       [else
        (define multi-adept? (pair? (cdr adepts)))
        (define targets : (Listof (Pair Float Float))
          (if (>= (length explicit-targets) 2)
              (for/list : (Listof (Pair Float Float)) ([p (in-list (take explicit-targets 2))])
                (cons (->float (car p)) (->float (cdr p))))
              (infer-base-targets enemy-units hx hy emx emy)))
        (define base-a (car targets))
        (define base-b (if (pair? (cdr targets)) (cadr targets) (car targets)))
        (define ax0 (car base-a))
        (define ay0 (cdr base-a))
        (define bx0 (car base-b))
        (define by0 (cdr base-b))
        (define total-adept-power
          (max 1.0 (for/fold ([acc : Float 0.0]) ([a (in-list adepts)]) (+ acc (unit-power a)))))
        (define canceled-tags : (Mutable-HashTable Integer Boolean) (make-hasheqv))
        (define pwr-cache-set? : Boolean #f)
        (define pwr-cache-x : Float 0.0)
        (define pwr-cache-y : Float 0.0)
        (define pwr-cache-val : Float 0.0)
        (: cached-enemy-pwr (-> Float Float Float))
        (define (cached-enemy-pwr cx cy)
          (cond
            [(and pwr-cache-set? (= cx pwr-cache-x) (= cy pwr-cache-y))
             pwr-cache-val]
            [else
             (define v (sum-unit-power enemy-units cx cy 8.5))
             (set! pwr-cache-set? #t)
             (set! pwr-cache-x cx)
             (set! pwr-cache-y cy)
             (set! pwr-cache-val v)
             v]))
        ;; First inspect active shades or explicit shade destination against > 1.2 * adept-power
        (define cancel-dirs
          (if (and (null? shades)
                   (not (for/or : Boolean ([a (in-list adepts)])
                          (or (real? (dyn-hash-ref a 'shade-x #f))
                              (eq? (dyn-hash-ref a 'phase-shift-active? #f) #t)))))
              '()
              (for/fold ([acc : (Listof harass-directive) '()]
                         #:result (reverse acc))
                        ([a (in-list adepts)])
                (define atag (u-tag a))
                (define explicit-sx (dyn-hash-ref a 'shade-x #f))
                (define explicit-sy (dyn-hash-ref a 'shade-y #f))
                (define matched-shade
                  (and (pair? shades)
                       (for/fold ([hit : (Option Any) #f])
                                 ([sh (in-list shades)]
                                  #:when (not hit))
                         (define owner (dyn-hash-ref sh 'owner-tag #f))
                         (if (or (eqv? owner atag) (not multi-adept?)) sh #f))))
                (define shade-active?
                  (or matched-shade
                      (and (real? explicit-sx) (real? explicit-sy))
                      (eq? (dyn-hash-ref a 'phase-shift-active? #f) #t)))
                (cond
                  [(not shade-active?) acc]
                  [else
                   (define sx
                     (cond
                       [matched-shade (u-x matched-shade)]
                       [(real? explicit-sx) (->float explicit-sx)]
                       [else (+ bx0 0.0)]))
                   (define sy
                     (cond
                       [matched-shade (u-y matched-shade)]
                       [(real? explicit-sy) (->float explicit-sy)]
                       [else (+ by0 0.0)]))
                   (define local-enemy-pwr (cached-enemy-pwr sx sy))
                   (define local-adept-pwr
                     (max (unit-power a)
                          (if matched-shade
                              (for/fold ([s : Float 0.0])
                                        ([sh (in-list shades)])
                                (define dx (- sx (u-x sh)))
                                (define dy (- sy (u-y sh)))
                                (if (<= (+ (* dx dx) (* dy dy)) 49.0)
                                    (+ s 15.0)
                                    s))
                              total-adept-power)))
                   (if (> local-enemy-pwr (* power-ratio local-adept-pwr))
                       (begin
                         (hash-set! canceled-tags atag #t)
                         (cons (harass-directive atag 'adept 'cast-spell 'cancel-adept-phase-shift
                                                 CANCEL-ADEPT-PHASE-SHIFT-ABILITY-ID atag sx sy
                                                 90.0 'adept-cancel-unsafe-shade-dest 'multi-base-adept)
                               acc))
                       acc)]))))
        ;; Hoist Base A / Base B safe power & nearest worker queries lazily (at most once each).
        (define max-safe-pwr (* power-ratio total-adept-power))
        (define a-safe-done? : Boolean #f)
        (define a-safe-val : Boolean #f)
        (define b-safe-done? : Boolean #f)
        (define b-safe-val : Boolean #f)
        (: base-safe? (-> Boolean Float Float Boolean))
        (define (base-safe? alt-is-b? shx shy)
          (if alt-is-b?
              (begin
                (unless b-safe-done?
                  (set! b-safe-val (<= (cached-enemy-pwr shx shy) max-safe-pwr))
                  (set! b-safe-done? #t))
                b-safe-val)
              (begin
                (unless a-safe-done?
                  (set! a-safe-val (<= (cached-enemy-pwr shx shy) max-safe-pwr))
                  (set! a-safe-done? #t))
                a-safe-val)))
        (define w-a-done? : Boolean #f)
        (define w-a-val : (Option Any) #f)
        (define w-b-done? : Boolean #f)
        (define w-b-val : (Option Any) #f)
        (: base-worker (-> Boolean Float Float (Option Any)))
        (define (base-worker on-b? ex ey)
          (if on-b?
              (begin
                (unless w-b-done?
                  (set! w-b-val (find-nearest-worker ex ey enemy-units 8.5))
                  (set! w-b-done? #t))
                w-b-val)
              (begin
                (unless w-a-done?
                  (set! w-a-val (find-nearest-worker ex ey enemy-units 8.5))
                  (set! w-a-done? #t))
                w-a-val)))
        ;; Split remaining active Adepts across Base A (direct attack) & Base B (phase shift)
        (define attack-dirs
          (for/fold ([acc : (Listof harass-directive) '()]
                     #:result (reverse acc))
                    ([a (in-list adepts)]
                     [idx (in-naturals)])
            (define atag (u-tag a))
            (cond
              [(hash-has-key? canceled-tags atag) acc]
              [else
               (define on-b-group? (and multi-adept? (odd? idx)))
               (define ex (if on-b-group? bx0 ax0))
               (define ey (if on-b-group? by0 ay0))
               (define sh-x (if on-b-group? ax0 bx0))
               (define sh-y (if on-b-group? ay0 by0))
               (define ax (u-x a))
               (define ay (u-y a))
               (define dax (- ax sh-x))
               (define day (- ay sh-y))
               (define d-alt2 (+ (* dax dax) (* day day)))
               (define dex (- ax ex))
               (define dey (- ay ey))
               (define d-eng2 (+ (* dex dex) (* dey dey)))
               (define phase-ready?
                 (and (even? idx)
                      (<= d-alt2 1764.0)
                      (<= d-eng2 196.0)
                      (not (eq? (dyn-hash-ref a 'phase-shift-ready? #t) #f))
                      (not (eq? (dyn-hash-ref a 'phase-shift-active? #f) #t))))
               (cond
                 ;; Cast phase shift (`2544`) toward opposite mineral line to split enemy defense
                 [(and phase-ready? (base-safe? (not on-b-group?) sh-x sh-y))
                  (cons (harass-directive atag 'adept 'cast-spell 'adept-phase-shift
                                          ADEPT-PHASE-SHIFT-ABILITY-ID 0 sh-x sh-y
                                          75.0 'adept-split-shade-second-base 'multi-base-adept)
                        acc)]
                 [(base-worker on-b-group? ex ey)
                  => (lambda ([worker-tgt : Any])
                       (cons (harass-directive atag 'adept 'focus-fire #f 0 (u-tag worker-tgt)
                                               (u-x worker-tgt) (u-y worker-tgt)
                                               70.0 'adept-focus-mineral-worker 'multi-base-adept)
                             acc))]
                 [else
                  (cons (harass-directive atag 'adept 'attack-pos #f 0 0 ex ey
                                          60.0 'adept-move-harass-mineral-line 'multi-base-adept)
                        acc)])])))
        (append cancel-dirs attack-dirs)])]))

;; Splits friendly defenders between live enemy Adepts at Base A and approaching
;; `adept-phase-shift` shades threatening Base B so neither mineral line is left empty.
(: plan-counter-adept-harass
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real #:home-y Real #:base-points (Listof (Pair Real Real)))
        (Listof harass-directive)))
(define (plan-counter-adept-harass ally-units enemy-units
                                   #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                   #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                   #:base-points [explicit-bases '()])
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define-values (cand-adepts cand-shades)
    (for/fold ([ea : (Listof Any) '()] [es : (Listof Any) '()])
              ([e (in-list enemy-units)])
      (define ut (u-type e))
      (cond
        [(and (eq? ut 'adept) (u-alive? e))
         (values (cons e ea) es)]
        [(and (eq? ut 'adept-phase-shift) (u-alive? e))
         (values ea (cons e es))]
        [else (values ea es)])))
  (cond
    [(and (null? cand-adepts) (null? cand-shades))
     '()]
    [else
     (define bases
       (if (pair? explicit-bases)
           (for/list : (Listof (Pair Float Float)) ([p (in-list explicit-bases)])
             (cons (->float (car p)) (->float (cdr p))))
           (infer-ally-bases ally-units hx hy)))
     (: near-base? (-> Float Float Boolean))
     (define (near-base? x y)
       (for/or : Boolean ([b (in-list bases)]) (<= (dist2 x y (car b) (cdr b)) 20.0)))
     (define enemy-adepts
       (for/fold ([acc : (Listof Any) '()]) ([e (in-list cand-adepts)])
         (if (near-base? (u-x e) (u-y e)) (cons e acc) acc)))
     (define enemy-shades
       (for/fold ([acc : (Listof Any) '()]) ([e (in-list cand-shades)])
         (if (near-base? (u-x e) (u-y e)) (cons e acc) acc)))
     (cond
       [(and (null? enemy-adepts) (null? enemy-shades)) '()]
       [else
        (define defenders
          (for/list : (Listof Any) ([a (in-list ally-units)]
                                    #:when (and (> (u-tag a) 0)
                                                (not (memq (u-type a) '(overlord observer larva egg)))
                                                (not (u-worker? (u-type a)))
                                                (not (u-structure? a))
                                                (u-alive? a)))
            a))
        (for/fold ([acc : (Listof harass-directive) '()]
                   #:result (reverse acc))
                  ([d (in-list defenders)]
                   [idx (in-naturals)])
          (define dtag (u-tag d))
          (define dt (u-type d))
          ;; Split defenders across real Adepts and active shades (proportional alternate assignment)
          (define track-shade?
            (and (pair? enemy-shades)
                 (or (null? enemy-adepts) (odd? idx))))
          (cond
            [track-shade?
             (define sh (list-ref enemy-shades (modulo idx (length enemy-shades))))
             (cons (harass-directive dtag dt 'move #f 0 (u-tag sh) (u-x sh) (u-y sh)
                                     65.0 'counter-adept-track-shade 'counter-adept)
                   acc)]
            [(pair? enemy-adepts)
             (define ad (list-ref enemy-adepts (modulo idx (length enemy-adepts))))
             (cons (harass-directive dtag dt 'focus-fire #f 0 (u-tag ad) (u-x ad) (u-y ad)
                                     80.0 'counter-adept-focus-real 'counter-adept)
                   acc)]
            [else acc]))])]))

;; =============================================================================
;; 2. Widow Mine Drop Timed with Ground Runby & Counter
;; =============================================================================

;; Syncs `medivac` + `widow-mine` burrow (`2095`) in enemy Main mineral line within `<= 48`
;; frames of a `hellion`/`marine` natural or 3rd mineral-line runby.
(: plan-widow-mine-drop-and-runby
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real
         #:home-y Real
         #:enemy-main-x (Option Real)
         #:enemy-main-y (Option Real)
         #:enemy-targets (Listof (Pair Real Real)))
        widow-mine-runby-plan))
(define (plan-widow-mine-drop-and-runby ally-units enemy-units
                                        #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                        #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                        #:enemy-main-x [emx #f]
                                        #:enemy-main-y [emy #f]
                                        #:enemy-targets [explicit-targets '()])
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define targets
    (if (>= (length explicit-targets) 2)
        (for/list : (Listof (Pair Float Float)) ([p (in-list (take explicit-targets 2))])
          (cons (->float (car p)) (->float (cdr p))))
        (infer-base-targets enemy-units hx hy emx emy)))
  (define main-pt (car targets))
  (define runby-pt (if (pair? (cdr targets)) (cadr targets) (car targets)))
  (define-values (rev-meds rev-mines rev-runby)
    (for/fold ([ms : (Listof Any) '()] [wms : (Listof Any) '()] [rs : (Listof Any) '()])
              ([a (in-list ally-units)])
      (define ut (u-type a))
      (cond
        [(and (eq? ut 'medivac) (> (u-tag a) 0) (u-alive? a))
         (values (cons a ms) wms rs)]
        [(and (eq? ut 'widow-mine) (> (u-tag a) 0) (u-alive? a))
         (values ms (cons a wms) rs)]
        [(and (memq ut '(hellion marine)) (> (u-tag a) 0) (u-alive? a))
         (values ms wms (cons a rs))]
        [else (values ms wms rs)])))
  (define medivacs (reverse rev-meds))
  (define mines (reverse rev-mines))
  (define runby-squad (reverse rev-runby))
  (define medivac-eta
    (if (pair? medivacs)
        (let* ([m (car medivacs)]
               [d (dist2 (u-x m) (u-y m) (car main-pt) (cdr main-pt))])
          (exact-round (* (/ d 4.2) 22.4)))
        0))
  (define runby-eta
    (if (pair? runby-squad)
        (let* ([r (car runby-squad)]
               [d (dist2 (u-x r) (u-y r) (car runby-pt) (cdr runby-pt))])
          (exact-round (* (/ d 4.25) 22.4)))
        medivac-eta))
  (define delta-frames (abs (- medivac-eta runby-eta)))
  (define synced? (or (null? medivacs) (null? runby-squad) (<= delta-frames WIDOW-MINE-SYNC-MAX-DELTA-FRAMES)))
  (define med-dirs
    (for/fold ([acc : (Listof harass-directive) '()]
               #:result (reverse acc))
              ([m (in-list medivacs)])
      (define mtag (u-tag m))
      (define d (dist2 (u-x m) (u-y m) (car main-pt) (cdr main-pt)))
      (cond
        [(<= d 5.5)
         (cons (harass-directive mtag 'medivac 'transport-drop-point 'unload-all-at 396
                                 mtag (car main-pt) (cdr main-pt)
                                 95.0 'widow-mine-drop-unload-main 'widow-mine-runby)
               acc)]
        [else
         (cons (harass-directive mtag 'medivac 'move #f 16 0 (car main-pt) (cdr main-pt)
                                 85.0 'widow-mine-drop-fly-main 'widow-mine-runby)
               acc)])))
  (define mine-dirs
    (for/list : (Listof harass-directive) ([wm (in-list mines)])
      (define wtag (u-tag wm))
      (define d (dist2 (u-x wm) (u-y wm) (car main-pt) (cdr main-pt)))
      (if (<= d 10.0)
          (harass-directive wtag 'widow-mine 'cast-spell 'widow-mine-burrow
                            WIDOW-MINE-BURROW-ABILITY-ID wtag (u-x wm) (u-y wm)
                            100.0 'widow-mine-burrow-mineral-line 'widow-mine-runby)
          (harass-directive wtag 'widow-mine 'move #f 16 0 (car main-pt) (cdr main-pt)
                            60.0 'widow-mine-advance-to-drop 'widow-mine-runby))))
  ;; Hold ground runby slightly if arriving > 48 frames ahead of Medivac drop; else simultaneous attack!
  (define runby-hold? (and (pair? medivacs) (> (- medivac-eta runby-eta) WIDOW-MINE-SYNC-MAX-DELTA-FRAMES)))
  (define runby-worker-tgt
    (if (and (pair? runby-squad) (not runby-hold?))
        (find-nearest-worker (car runby-pt) (cdr runby-pt) enemy-units 10.0)
        #f))
  (define hold-pt-cached
    (if (and (pair? runby-squad) runby-hold?)
        (clamp-pt (+ (* 0.25 hx) (* 0.75 (car runby-pt)))
                  (+ (* 0.25 hy) (* 0.75 (cdr runby-pt)))
                  200.0 200.0)
        (cons 0.0 0.0)))
  (define runby-dirs
    (for/list : (Listof harass-directive) ([r (in-list runby-squad)])
      (define rtag (u-tag r))
      (define rt (u-type r))
      (if runby-hold?
          (harass-directive rtag rt 'move #f 16 0 (car hold-pt-cached) (cdr hold-pt-cached)
                            70.0 'runby-stage-sync-48f 'widow-mine-runby)
          (if runby-worker-tgt
              (harass-directive rtag rt 'focus-fire #f 0 (u-tag runby-worker-tgt) (u-x runby-worker-tgt) (u-y runby-worker-tgt)
                                88.0 'runby-synced-worker-slaughter 'widow-mine-runby)
              (harass-directive rtag rt 'attack-pos #f 0 0 (car runby-pt) (cdr runby-pt)
                                82.0 'runby-synced-attack-nat-third 'widow-mine-runby)))))
  (widow-mine-runby-plan synced? delta-frames main-pt runby-pt
                         (append med-dirs mine-dirs runby-dirs)))

;; Counters Widow Mine drops:
;;   1) Pulls workers strictly `> 5.5` tiles away from `widow-mine-burrowed` (`500`),
;;   2) Out-ranges / AoEs mines (`corrosive-bile` or `stalker`/`hydralisk`+detector), or
;;   3) Baits the shot cleanly with strictly `1` cheap unit.
(: plan-counter-widow-mine-drop
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real #:home-y Real)
        (Listof harass-directive)))
(define (plan-counter-widow-mine-drop ally-units enemy-units
                                      #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                      #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y])
  (define _hx (->float home-x))
  (define _hy (->float home-y))
  (define mines
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (memq (u-type e) '(widow-mine widow-mine-burrowed))
                                          (> (u-tag e) 0)
                                          (u-alive? e)))
      e))
  (cond
    [(null? mines) '()]
    [else
     ;; 1. Worker pull > 5.5 tiles away from all dropped mines
     (define worker-pulls
       (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                 ([w (in-list ally-units)]
                  #:when (and (u-alive? w) (> (u-tag w) 0) (u-worker? (u-type w))))
         (define wx (u-x w))
         (define wy (u-y w))
         (define near-m
           (for/fold ([best : (Option Any) #f] [bd : Float WIDOW-MINE-WORKER-PULL-SAFE-RANGE] #:result best)
                     ([m (in-list mines)])
             (define d (dist2 wx wy (u-x m) (u-y m)))
             (if (<= d bd) (values m d) (values best bd))))
         (if near-m
             (let* ([mx (u-x near-m)]
                    [my (u-y near-m)]
                    [dx (- wx mx)]
                    [dy (- wy my)]
                    [n (max 1e-4 (dist2 0.0 0.0 dx dy))]
                    [safe (clamp-pt (+ mx (* 6.8 (/ dx n))) (+ my (* 6.8 (/ dy n))) 200.0 200.0)])
               (cons (harass-directive (u-tag w) (u-type w) 'move #f 16 (u-tag near-m)
                                       (car safe) (cdr safe)
                                       98.0 'pull-workers-outside-widow-mine-5.5t 'counter-widow-mine)
                     acc))
             acc)))
     ;; 2. AoE Corrosive Bile OR Stalker/Ranged + detector clear OR single cheap bait
     (define primary-m (car mines))
     (define pm-x (u-x primary-m))
     (define pm-y (u-y primary-m))
     (define pm-tag (u-tag primary-m))
     (define has-detector?
       (for/or : Boolean ([a (in-list ally-units)])
         (and (u-alive? a)
              (memq (u-type a) '(observer overseer overseer-siege-mode raven photon-cannon spore-crawler missile-turret))
              (<= (dist2 (u-x a) (u-y a) pm-x pm-y) 13.0))))
     (define clear-dirs
       (for/fold ([acc : (Listof harass-directive) '()]
                  [biled? : Boolean #f]
                  [baited? : Boolean #f]
                  #:result (reverse acc))
                 ([a (in-list ally-units)]
                  #:when (and (u-alive? a) (> (u-tag a) 0) (not (u-structure? a)) (not (u-worker? (u-type a)))))
         (define atag (u-tag a))
         (define at (u-type a))
         (define d (dist2 (u-x a) (u-y a) pm-x pm-y))
         (cond
           [(and (eq? at 'ravager) (not biled?) (<= d 10.5))
            (values (cons (harass-directive atag at 'cast-spell 'corrosive-bile 2338 pm-tag pm-x pm-y
                                            96.0 'corrosive-bile-clear-widow-mine 'counter-widow-mine)
                          acc)
                    #t
                    baited?)]
           [(and (eq? at 'stalker) has-detector? (<= d 12.0))
            (values (cons (harass-directive atag at 'focus-fire #f 0 pm-tag pm-x pm-y
                                            92.0 'stalker-detector-outrange-widow-mine 'counter-widow-mine)
                          acc)
                    biled?
                    baited?)]
           [(and (memq at '(hydralisk marauder immortal colossus tempest)) has-detector? (<= d 12.0))
            (values (cons (harass-directive atag at 'focus-fire #f 0 pm-tag pm-x pm-y
                                            90.0 'ranged-detector-clear-widow-mine 'counter-widow-mine)
                          acc)
                    biled?
                    baited?)]
           [(and (not baited?) (memq at '(zergling zealot marine roach adept)) (<= d 12.0))
            (values (cons (harass-directive atag at 'move #f 16 pm-tag pm-x pm-y
                                            85.0 'single-cheap-unit-bait-widow-mine 'counter-widow-mine)
                          acc)
                    biled?
                    #t)]
           [else (values acc biled? baited?)])))
     (append worker-pulls clear-dirs)]))

;; Widow Mine Clump Retargeting (`2099`) & Single Low-Value Unit Trigger Bait (`5.8t` hold + `4.5t` bait):
;;   - Offense: armed `widow-mine-burrowed` (`500`) scans enemies in `5.0` tiles and emits
;;     `(widow-mine-retarget wm-id best-clump-unit-id)` (`2099`) toward the target with maximum
;;     neighbors within `1.75` tiles, avoiding lone `0`-neighbor bait units!
;;   - Counter: holds workers & army `>= 5.8` tiles from armed `widow-mine-burrowed`, sends strictly
;;     `1` low-value unit (`changeling`/`zergling`/`hallucination`/`marine`/`zealot`) into `<= 4.5`
;;     tiles to soak the `29s` (`648f`) Sentinel Missile, and re-engages on cooldown.
(: plan-widow-mine-retarget-and-bait
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real #:home-y Real)
        (Listof harass-directive)))
(define (plan-widow-mine-retarget-and-bait ally-units enemy-units
                                           #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                           #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y])
  (define _hx (->float home-x))
  (define _hy (->float home-y))
  ;; 1. Offense: our armed `widow-mine-burrowed` retargeting onto densest `<= 1.75`-tile clump
  (define my-mines
    (for/list : (Listof Any) ([a (in-list ally-units)]
                              #:when (and (u-alive? a) (> (u-tag a) 0)
                                          (eq? (u-type a) 'widow-mine-burrowed)
                                          (not (eq? (dyn-hash-ref a 'on-cooldown? #f) #t))
                                          (<= (safe-int (or (dyn-hash-ref a 'cooldown #f)
                                                            (dyn-hash-ref a 'sentinel-cooldown 0))
                                                        0)
                                              0)))
      a))
  (define live-enemies
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (u-alive? e) (> (u-tag e) 0)
                                          (not (u-structure? e))))
      e))
  (define offense-dirs
    (if (or (null? my-mines) (null? live-enemies))
        '()
        (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                  ([wm (in-list my-mines)])
          (define wtag (u-tag wm))
          (define wx (u-x wm))
          (define wy (u-y wm))
          (define in-range
            (for/list : (Listof Any) ([e (in-list live-enemies)]
                                      #:when (<= (dist2 wx wy (u-x e) (u-y e)) 5.0))
              e))
          (define-values (best-tgt best-nbrs _best-score)
            (for/fold ([bt : (Option Any) #f] [bn : Integer -1] [bs : Float -1e9])
                      ([e (in-list in-range)])
              (define ex (u-x e))
              (define ey (u-y e))
              (define et (u-type e))
              (define nbrs
                (for/sum : Integer ([other (in-list live-enemies)]
                                    #:when (and (not (= (u-tag other) (u-tag e)))
                                                (<= (dist2 ex ey (u-x other) (u-y other)) 1.75)))
                  1))
              (define bait-pen
                (if (and (= nbrs 0)
                         (memq et '(changeling changeling-zealot changeling-marine changeling-zergling
                                    zergling larva egg hallucination-zealot hallucination-adept)))
                    -200.0
                    0.0))
              (define sc (+ (* 100.0 (->float nbrs)) bait-pen (* 0.25 (unit-power e))))
              (if (> sc bs)
                  (values e nbrs sc)
                  (values bt bn bs))))
          ;; Explicitly retarget onto >=1-neighbor clump (never waste missile on lone 0-neighbor bait)
          (if (and best-tgt (or (>= best-nbrs 1) (>= (u-ehp best-tgt) 120.0)))
              (cons (harass-directive wtag 'widow-mine-burrowed 'widow-mine-retarget 'widow-mine-attack
                                      WIDOW-MINE-RETARGET-ABILITY-ID (u-tag best-tgt)
                                      (u-x best-tgt) (u-y best-tgt)
                                      97.0 'widow-mine-retarget-densest-clump 'widow-mine-retarget)
                    acc)
              acc))))
  ;; 2. Counter: hold army/workers >= 5.8t from armed enemy mines + send 1 cheap unit <= 4.5t
  (define enemy-mines
    (for/list : (Listof Any) ([e (in-list enemy-units)]
                              #:when (and (u-alive? e) (> (u-tag e) 0)
                                          (eq? (u-type e) 'widow-mine-burrowed)))
      e))
  (define counter-dirs
    (if (null? enemy-mines)
        '()
        (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                  ([em (in-list enemy-mines)])
          (define emtag (u-tag em))
          (define emx (u-x em))
          (define emy (u-y em))
          (define armed?
            (and (not (eq? (dyn-hash-ref em 'on-cooldown? #f) #t))
                 (<= (safe-int (or (dyn-hash-ref em 'cooldown #f)
                                   (dyn-hash-ref em 'sentinel-cooldown 0))
                               0)
                     0)))
          (cond
            [(not armed?)
             ;; On 29s cooldown -> commit nearby combat units immediately!
             (for/fold ([sub : (Listof harass-directive) acc])
                       ([a (in-list ally-units)]
                        #:when (and (u-alive? a) (> (u-tag a) 0)
                                    (not (u-structure? a)) (not (u-worker? (u-type a)))
                                    (<= (dist2 (u-x a) (u-y a) emx emy) 12.0)))
               (cons (harass-directive (u-tag a) (u-type a) 'focus-fire #f 0 emtag emx emy
                                       91.0 'engage-widow-mine-on-cooldown 'widow-mine-bait)
                     sub))]
            [else
             ;; Pick strictly 1 low-value trigger unit nearest the armed mine
             (: bait-rank (-> Symbol Float))
             (define (bait-rank ut)
               (case ut
                 [(changeling changeling-zealot changeling-marine changeling-marine-shield
                   changeling-zergling changeling-zergling-wings) 1.0]
                 [(hallucination-zealot hallucination-adept hallucination-stalker
                   hallucination-phoenix) 2.0]
                 [(zergling) 3.0]
                 [(marine zealot) 4.0]
                 [else 99.0]))
             (define bait-unit
               (for/fold ([best : (Option Any) #f] [bsc : Float 1e9] #:result best)
                         ([a (in-list ally-units)]
                          #:when (and (u-alive? a) (> (u-tag a) 0)
                                      (not (u-structure? a)) (not (u-worker? (u-type a)))
                                      (<= (dist2 (u-x a) (u-y a) emx emy) 14.0)
                                      (< (bait-rank (u-type a)) 50.0)))
                 (define sc (+ (* 100.0 (bait-rank (u-type a)))
                               (dist2 (u-x a) (u-y a) emx emy)))
                 (if (< sc bsc) (values a sc) (values best bsc))))
             (define bait-tag (if bait-unit (u-tag bait-unit) -1))
             (define with-bait
               (if bait-unit
                   (let* ([ax (u-x bait-unit)]
                          [ay (u-y bait-unit)]
                          [dx (- ax emx)]
                          [dy (- ay emy)]
                          [n (max 1e-4 (dist2 0.0 0.0 dx dy))]
                          ;; Enter 4.2-tile radius (inside 4.5t / 5.0t trigger range)
                          [tpt (clamp-pt (+ emx (* 4.2 (/ dx n))) (+ emy (* 4.2 (/ dy n))) 200.0 200.0)])
                     (cons (harass-directive bait-tag (u-type bait-unit) 'move #f 16 emtag
                                             (car tpt) (cdr tpt)
                                             98.0 'bait-widow-mine-single-low-value-trigger 'widow-mine-bait)
                           acc))
                   acc))
             ;; Hold ALL other workers & combat units outside >= 5.8 tiles
             (for/fold ([sub : (Listof harass-directive) with-bait])
                       ([a (in-list ally-units)]
                        #:when (and (u-alive? a) (> (u-tag a) 0)
                                    (not (= (u-tag a) bait-tag))
                                    (not (u-structure? a))
                                    (< (dist2 (u-x a) (u-y a) emx emy) 5.8)))
               (define ax (u-x a))
               (define ay (u-y a))
               (define dx (- ax emx))
               (define dy (- ay emy))
               (define n (max 1e-4 (dist2 0.0 0.0 dx dy)))
               (define hold-pt (clamp-pt (+ emx (* 6.4 (/ dx n))) (+ emy (* 6.4 (/ dy n))) 200.0 200.0))
               (cons (harass-directive (u-tag a) (u-type a) 'move #f 16 emtag
                                       (car hold-pt) (cdr hold-pt)
                                       95.0 'hold-units-outside-widow-mine-5.8t 'widow-mine-bait)
                     sub))]))))
  (append offense-dirs counter-dirs))

;; =============================================================================
;; 3. Cross-Race Coordinated Runby Catalog & Counter
;; =============================================================================

;; Dispatches `4–10` fast raiders (`zergling`/`baneling`/`hellion`/`zealot`/`roach`) into the
;; opposite exposed flank mineral line when enemy army moves out `> 22.0` tiles or air harass is active.
(: plan-coordinated-runby-tactics
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real
         #:home-y Real
         #:enemy-main-x (Option Real)
         #:enemy-main-y (Option Real)
         #:enemy-targets (Listof (Pair Real Real))
         #:force-commit? Boolean)
        (Listof harass-directive)))
(define (plan-coordinated-runby-tactics ally-units enemy-units
                                        #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                        #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                        #:enemy-main-x [emx #f]
                                        #:enemy-main-y [emy #f]
                                        #:enemy-targets [explicit-targets '()]
                                        #:force-commit? [force-commit? #f])
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define-values (rev-runby rcnt rev-air-harass)
    (for/fold ([rs : (Listof Any) '()] [n : Integer 0] [as : (Listof Any) '()])
              ([a (in-list ally-units)])
      (define ut (u-type a))
      (cond
        [(and (memq ut '(zergling baneling hellion zealot roach))
              (> (u-tag a) 0)
              (u-alive? a))
         (values (cons a rs) (add1 n) as)]
        [(and (not force-commit?)
              (memq ut '(oracle raven banshee mutalisk medivac liberator overlord-transport warp-prism))
              (u-alive? a))
         (values rs n (cons a as))]
        [else (values rs n as)])))
  (cond
    [(< rcnt 4) '()]
    [else
     (define runby-units (reverse rev-runby))
     (define targets
       (if (pair? explicit-targets)
           (for/list : (Listof (Pair Float Float)) ([p (in-list explicit-targets)])
             (cons (->float (car p)) (->float (cdr p))))
           (infer-base-targets enemy-units hx hy emx emy)))
     (define enemy-main (car targets))
     ;; Compute enemy combat army centroid to measure > 22.0 tile move-out distance from enemy main
     (define-values (ecnt esx esy)
       (for/fold ([n : Integer 0] [sx : Float 0.0] [sy : Float 0.0])
                 ([e (in-list enemy-units)]
                  #:when (and (not (u-worker? (u-type e))) (not (u-structure? e)) (u-alive? e)))
         (values (add1 n) (+ sx (u-x e)) (+ sy (u-y e)))))
     (define enemy-army-out?
       (and (> ecnt 0)
            (let ([ecx (/ esx (->float ecnt))]
                  [ecy (/ esy (->float ecnt))])
              (> (dist2 ecx ecy (car enemy-main) (cdr enemy-main))
                 RUNBY-ENEMY-MOVEOUT-THRESHOLD))))
     (define air-harass-active?
       (and (not force-commit?)
            (not enemy-army-out?)
            (for/or : Boolean ([a (in-list rev-air-harass)])
              (define ax (u-x a))
              (define ay (u-y a))
              (for/or : Boolean ([t (in-list targets)])
                (define dx (- ax (car t)))
                (define dy (- ay (cdr t)))
                (<= (+ (* dx dx) (* dy dy)) 324.0)))))
     (cond
       [(not (or force-commit? enemy-army-out? air-harass-active?))
        '()]
       [else
        ;; Choose target expansion furthest from enemy army centroid (opposite exposed flank)
        (define ecx (if (> ecnt 0) (/ esx (->float ecnt)) (car enemy-main)))
        (define ecy (if (> ecnt 0) (/ esy (->float ecnt)) (cdr enemy-main)))
        (define best-target : (Pair Float Float)
          (for/fold ([best : (Pair Float Float) (car targets)]
                     [bd2 : Float -1.0]
                     #:result best)
                    ([p (in-list targets)])
            (define dx (- ecx (car p)))
            (define dy (- ecy (cdr p)))
            (define d2 (+ (* dx dx) (* dy dy)))
            (if (> d2 bd2) (values p d2) (values best bd2))))
        (define squad (if (<= rcnt 10) runby-units (take runby-units 10)))
        (define tx (car best-target))
        (define ty (cdr best-target))
        (define worker-tgt (find-nearest-worker tx ty enemy-units 9.5))
        (for/list : (Listof harass-directive) ([u (in-list squad)])
          (define utag (u-tag u))
          (define ut (u-type u))
          (if worker-tgt
              (harass-directive utag ut 'focus-fire #f 0 (u-tag worker-tgt)
                                (u-x worker-tgt) (u-y worker-tgt)
                                84.0 'coordinated-opposite-flank-runby-workers 'coordinated-runby)
              (harass-directive utag ut 'attack-pos #f 0 0 tx ty
                                80.0 'coordinated-opposite-flank-runby 'coordinated-runby)))])]))

;; Defends against enemy fast runbys (`zergling`, `baneling`, `hellion`, `zealot`, `adept`, `reaper`)
;; with proportional local intercept + mineral-walk worker shelter without pulling whole front line.
(: plan-counter-runby-defense
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real #:home-y Real #:base-points (Listof (Pair Real Real)))
        (Listof harass-directive)))
(define (plan-counter-runby-defense ally-units enemy-units
                                    #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                    #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                    #:base-points [explicit-bases '()])
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define need-ally-th? (null? explicit-bases))
  (define-values (bases rev-raw-defs-pre)
    (cond
      [(not need-ally-th?)
       (values (for/list : (Listof (Pair Float Float)) ([p (in-list explicit-bases)])
                 (cons (->float (car p)) (->float (cdr p))))
               '())]
      [else
       (define rev-ths
         (for/fold ([ths : (Listof (Pair Float Float)) '()])
                   ([a (in-list ally-units)])
           (if (and (memq (u-type a) '(nexus command-center orbital-command
                                       planetary-fortress hatchery lair hive))
                    (u-alive? a))
               (cons (cons (u-x a) (u-y a)) ths)
               ths)))
       (values (if (pair? rev-ths) (reverse rev-ths) (list (cons hx hy))) '())]))
  (: near-base? (-> Float Float Boolean))
  (define (near-base? x y)
    (for/or : Boolean ([b (in-list bases)])
      (define dx (- x (car b)))
      (define dy (- y (cdr b)))
      (<= (+ (* dx dx) (* dy dy)) 324.0)))
  ;; Single pass over `enemy-units` for runby unit types within base perimeter; skip `ally-units` defenders if none exist.
  (define raiders
    (for/fold ([acc : (Listof Any) '()] #:result (reverse acc))
              ([e (in-list enemy-units)])
      (if (and (memq (u-type e) '(zergling baneling hellion zealot adept reaper roach))
               (> (u-tag e) 0)
               (u-alive? e)
               (near-base? (u-x e) (u-y e)))
          (cons e acc)
          acc)))
  (cond
    [(null? raiders) '()]
    [else
     (define rev-raw-defs : (Listof Any)
       (if (pair? rev-raw-defs-pre)
           rev-raw-defs-pre
           (for/fold ([defs : (Listof Any) '()])
                     ([a (in-list ally-units)])
             (define ut (u-type a))
             (if (and (> (u-tag a) 0)
                      (not (u-worker? ut))
                      (not (memq ut '(overlord observer larva egg)))
                      (not (u-structure? a))
                      (u-alive? a))
                 (cons a defs)
                 defs))))
        (define threat-pwr (for/fold ([acc : Float 0.0]) ([r (in-list raiders)]) (+ acc (unit-power r))))
        (define need-pwr (* 1.3 threat-pwr))
        (define primary (car raiders))
        (define ptag (u-tag primary))
        (define px (u-x primary))
        (define py (u-y primary))
        (define keyed-defs : (Listof (Pair Any Float))
          (for/list : (Listof (Pair Any Float)) ([a (in-list (reverse rev-raw-defs))])
            (define dx (- (u-x a) px))
            (define dy (- (u-y a) py))
            (cons a (+ (* dx dx) (* dy dy)))))
        (define defenders
          (sort keyed-defs
                (lambda ([a : (Pair Any Float)] [b : (Pair Any Float)])
                  (< (cdr a) (cdr b)))))
        (define-values (def-dirs _used)
          (for/fold ([acc : (Listof harass-directive) '()] [acc-pwr : Float 0.0])
                    ([kd (in-list defenders)])
            (if (>= acc-pwr need-pwr)
                (values acc acc-pwr)
                (let ([d (car kd)])
                  (values (cons (harass-directive (u-tag d) (u-type d) 'focus-fire #f 0
                                                  ptag px py
                                                  86.0 'counter-runby-proportional-intercept 'counter-runby)
                                acc)
                          (+ acc-pwr (unit-power d)))))))
        (reverse def-dirs)]))

;; =============================================================================
;; 4. Off-Path Proxy All-Ins (Each Race + Random Variants) & Counter
;; =============================================================================

;; Pure vector solver computing off-scout-path coordinates displaced `24.0–38.0` tiles
;; perpendicular to BOTH `our-main<->enemy-main` and `our-nat<->enemy-nat` scouting axes.
(: compute-off-path-proxy-coords
   (->* (Real Real Real Real Real Real Real Real)
        (#:perp-dist Real #:side Integer #:map-width Real #:map-height Real)
        (Values Float Float Float)))
(define (compute-off-path-proxy-coords our-main-x our-main-y
                                       our-nat-x our-nat-y
                                       enemy-main-x enemy-main-y
                                       enemy-nat-x enemy-nat-y
                                       #:perp-dist [perp-kw 30.0]
                                       #:side [side 1]
                                       #:map-width [map-width SC2-MAP-PLAYABLE-MAX-COORD]
                                       #:map-height [map-height SC2-MAP-PLAYABLE-MAX-COORD])
  (define omx (->float our-main-x))
  (define omy (->float our-main-y))
  (define onx (->float our-nat-x))
  (define ony (->float our-nat-y))
  (define emx (->float enemy-main-x))
  (define emy (->float enemy-main-y))
  (define enx (->float enemy-nat-x))
  (define eny (->float enemy-nat-y))
  (define mw (->float map-width))
  (define mh (->float map-height))
  (define target-perp (clamp-coord (->float perp-kw) OFF-PATH-PROXY-PERP-MIN OFF-PATH-PROXY-PERP-MAX))
  (define vx (- omx emx))
  (define vy (- omy emy))
  (define n (max 1e-4 (dist2 0.0 0.0 vx vy)))
  (define ux (/ vx n))
  (define uy (/ vy n))
  ;; Anchor 38% from enemy main toward our main (closer side for fast reinforcement)
  (define ax (+ emx (* 0.38 vx)))
  (define ay (+ emy (* 0.38 vy)))
  (: eval-side (-> Integer (Values Float Float Float Float)))
  (define (eval-side sgn)
    (define s (->float sgn))
    (define rx (* s (- uy)))
    (define ry (* s ux))
    (define cand (clamp-pt (+ ax (* target-perp rx)) (+ ay (* target-perp ry)) mw mh))
    (define cx (car cand))
    (define cy (cdr cand))
    (define d-main-axis (point-to-segment-dist cx cy omx omy emx emy))
    (define d-nat-axis (point-to-segment-dist cx cy onx ony enx eny))
    (define d-min (min d-main-axis d-nat-axis))
    ;; Prefer candidate squarely inside [24..38] off BOTH axes and well inside map bounds
    (define margin (min (- cx 8.0) (- cy 8.0) (- mw 8.0 cx) (- mh 8.0 cy)))
    (define score (+ d-min (* 0.5 (min 15.0 margin))))
    (values cx cy d-min score))
  (define-values (x1 y1 d1 s1) (eval-side (if (>= side 0) 1 -1)))
  (define-values (x2 y2 d2 s2) (eval-side (if (>= side 0) -1 1)))
  (cond
    [(and (>= d1 OFF-PATH-PROXY-PERP-MIN) (<= d1 OFF-PATH-PROXY-PERP-MAX)) (values x1 y1 d1)]
    [(and (>= d2 OFF-PATH-PROXY-PERP-MIN) (<= d2 OFF-PATH-PROXY-PERP-MAX)) (values x2 y2 d2)]
    [(>= s1 s2) (values x1 y1 d1)]
    [else (values x2 y2 d2)]))

;; Selects race-specific & Random-variant off-path proxy all-in specifications + builder dispatch.
(: plan-off-path-proxy-all-in
   (->* (Symbol Symbol (Listof Any))
        (#:variant (Option Symbol)
         #:our-main-x Real #:our-main-y Real
         #:our-nat-x Real #:our-nat-y Real
         #:enemy-main-x Real #:enemy-main-y Real
         #:enemy-nat-x Real #:enemy-nat-y Real
         #:perp-dist Real
         #:side Integer
         #:map-width Real #:map-height Real)
        proxy-all-in-spec))
(define (plan-off-path-proxy-all-in raw-our-race raw-enemy-race ally-units
                                     #:variant [variant-kw #f]
                                     #:our-main-x [our-main-x SC2-DEFAULT-HOME-BASE-X]
                                     #:our-main-y [our-main-y SC2-DEFAULT-HOME-BASE-Y]
                                     #:our-nat-x [our-nat-x (+ SC2-DEFAULT-HOME-BASE-X 26.0)]
                                     #:our-nat-y [our-nat-y SC2-DEFAULT-HOME-BASE-Y]
                                     #:enemy-main-x [enemy-main-x 132.0]
                                     #:enemy-main-y [enemy-main-y 132.0]
                                     #:enemy-nat-x [enemy-nat-x 106.0]
                                     #:enemy-nat-y [enemy-nat-y 132.0]
                                     #:perp-dist [perp-dist 30.0]
                                     #:side [side 1]
                                     #:map-width [map-width SC2-MAP-PLAYABLE-MAX-COORD]
                                     #:map-height [map-height SC2-MAP-PLAYABLE-MAX-COORD])
  (define our-race (normalize-race raw-our-race))
  (define enemy-race (normalize-race raw-enemy-race))
  (define-values (px py perp-d)
    (compute-off-path-proxy-coords our-main-x our-main-y our-nat-x our-nat-y
                                   enemy-main-x enemy-main-y enemy-nat-x enemy-nat-y
                                   #:perp-dist perp-dist #:side side
                                   #:map-width map-width #:map-height map-height))
  (define vs-random? (eq? enemy-race 'Random))
  (define variant : Symbol
    (or variant-kw
        (case our-race
          [(Terran)  (if vs-random? 'proxy-rax-fact-reaper-cyclone 'proxy-2rax-reaper-marine)]
          [(Protoss) (if vs-random? 'proxy-gate-stargate-oracle 'proxy-robo-immortal-prism)]
          [(Zerg)    (if vs-random? 'proxy-hatch-roach-ravager 'proxy-hatch-ravager-queen)]
          [else      'proxy-rax-fact-reaper-cyclone])))
  (define buildings : (Listof Symbol)
    (case variant
      [(proxy-2rax-reaper-marine)     '(barracks barracks)]
      [(proxy-factory-cyclone-hellion) '(factory factory)]
      [(proxy-starport-banshee-raven)  '(factory starport)]
      [(proxy-rax-fact-reaper-cyclone) '(barracks factory)]
      [(proxy-robo-immortal-prism)     '(pylon robotics-facility)]
      [(proxy-stargate-oracle-voidray) '(pylon stargate)]
      [(proxy-3gate-adept-stalker)     '(pylon gateway gateway gateway)]
      [(proxy-gate-stargate-oracle)    '(pylon gateway stargate)]
      [(proxy-hatch-ravager-queen)     '(hatchery spine-crawler)]
      [(proxy-spine-ling-flood)        '(hatchery spine-crawler spine-crawler)]
      [(proxy-hatch-roach-ravager)     '(hatchery)]
      [else                            '(barracks)]))
  (define unit-comp : (Listof Symbol)
    (case variant
      [(proxy-2rax-reaper-marine)     '(reaper marine)]
      [(proxy-factory-cyclone-hellion) '(cyclone hellion)]
      [(proxy-starport-banshee-raven)  '(banshee raven viking-fighter)]
      [(proxy-rax-fact-reaper-cyclone) '(reaper cyclone hellion)]
      [(proxy-robo-immortal-prism)     '(immortal warp-prism stalker)]
      [(proxy-stargate-oracle-voidray) '(oracle void-ray)]
      [(proxy-3gate-adept-stalker)     '(adept stalker)]
      [(proxy-gate-stargate-oracle)    '(stalker adept oracle)]
      [(proxy-hatch-ravager-queen)     '(ravager roach queen)]
      [(proxy-spine-ling-flood)        '(zergling queen)]
      [(proxy-hatch-roach-ravager)     '(roach ravager zergling)]
      [else                            '(marine reaper)]))
  (define trigger-f
    (case our-race
      [(Terran)  750]
      [(Protoss) 680]
      [else      1000]))
  (define builder
    (for/fold ([best : (Option Any) #f] [bd : Float 1e9] #:result best)
              ([a (in-list ally-units)]
               #:when (and (u-alive? a) (> (u-tag a) 0) (u-worker? (u-type a))))
      (define d (dist2 (u-x a) (u-y a) px py))
      (if (< d bd) (values a d) (values best bd))))
  (define dirs
    (if builder
        (list (harass-directive (u-tag builder) (u-type builder) 'move #f 16 0 px py
                                88.0 variant 'off-path-proxy-all-in))
        '()))
  (proxy-all-in-spec our-race enemy-race variant px py perp-d buildings unit-comp trigger-f dirs))

;; Detects missing enemy home production at frame `<= 3024` (`2:15`), dispatches lateral
;; off-path scouts perpendicular (`±28` tiles) to both scouting corridors, and triggers
;; immediate home ramp/mineral-line static defense (`bunker` / `shield-battery` / `spine-crawler`).
(: plan-counter-proxy-all-in
   (->* (Symbol Symbol Integer (Listof Any) (Listof Any))
        (#:our-main-x Real #:our-main-y Real
         #:our-nat-x Real #:our-nat-y Real
         #:enemy-main-x Real #:enemy-main-y Real
         #:enemy-nat-x Real #:enemy-nat-y Real
         #:enemy-main-scouted? Boolean)
        counter-proxy-plan))
(define (plan-counter-proxy-all-in raw-our-race raw-enemy-race current-frame ally-units enemy-units
                                     #:our-main-x [our-main-x SC2-DEFAULT-HOME-BASE-X]
                                     #:our-main-y [our-main-y SC2-DEFAULT-HOME-BASE-Y]
                                     #:our-nat-x [our-nat-x (+ SC2-DEFAULT-HOME-BASE-X 26.0)]
                                     #:our-nat-y [our-nat-y SC2-DEFAULT-HOME-BASE-Y]
                                     #:enemy-main-x [enemy-main-x 132.0]
                                     #:enemy-main-y [enemy-main-y 132.0]
                                     #:enemy-nat-x [enemy-nat-x 106.0]
                                     #:enemy-nat-y [enemy-nat-y 132.0]
                                     #:enemy-main-scouted? [scouted? #t])
  (define our-race (normalize-race raw-our-race))
  (define enemy-race (normalize-race raw-enemy-race))
  (define early-window? (<= current-frame 3024))
  (cond
    [(or (not scouted?) (not early-window?) (< current-frame 1792))
     (counter-proxy-plan #f enemy-race '() '() '() 'proxy-threat-clear)]
    [else
     (define emx (->float enemy-main-x))
     (define emy (->float enemy-main-y))
     (: count-enemy-in-main (-> (Listof Symbol) Integer))
     (define (count-enemy-in-main syms)
       (for/sum : Integer ([e (in-list enemy-units)]
                           #:when (and (memq (u-type e) syms)
                                       (u-alive? e)
                                       (<= (dist2 (u-x e) (u-y e) emx emy) 24.0)))
         1))
     (define missing-home-prod?
       (case enemy-race
         [(Terran)
          (and (>= current-frame 1792)
               (zero? (count-enemy-in-main '(barracks factory starport barracks-reactor barracks-tech-lab))))]
         [(Protoss)
          (and (>= current-frame 1904)
               (<= (count-enemy-in-main '(gateway robotics-facility stargate)) 1))]
         [(Zerg)
          (and (>= current-frame 2240)
               (<= (for/sum : Integer ([e (in-list enemy-units)]
                                       #:when (and (memq (u-type e) '(hatchery lair hive)) (u-alive? e)))
                     1)
                   1))]
         [(Random)
          (and (>= current-frame 1792)
               (zero? (count-enemy-in-main '(barracks factory starport barracks-reactor barracks-tech-lab
                                                      gateway robotics-facility stargate))))]
         [else
          (and (>= current-frame 1904)
               (zero? (count-enemy-in-main '(barracks factory starport barracks-reactor barracks-tech-lab
                                                      gateway robotics-facility stargate))))]))
     (cond
       [(not missing-home-prod?)
        (counter-proxy-plan #f enemy-race '() '() '() 'proxy-threat-clear)]
       [else
        (define-values (lx1 ly1 _d1)
          (compute-off-path-proxy-coords our-main-x our-main-y our-nat-x our-nat-y
                                         enemy-main-x enemy-main-y enemy-nat-x enemy-nat-y
                                         #:perp-dist 28.0 #:side 1))
        (define-values (lx2 ly2 _d2)
          (compute-off-path-proxy-coords our-main-x our-main-y our-nat-x our-nat-y
                                         enemy-main-x enemy-main-y enemy-nat-x enemy-nat-y
                                         #:perp-dist 28.0 #:side -1))
        (define scout-pts : (Listof (Pair Float Float)) (list (cons lx1 ly1) (cons lx2 ly2)))
        (define def-bldgs : (Listof Symbol)
          (case our-race
            [(Terran)  '(bunker)]
            [(Protoss) '(shield-battery)]
            [(Zerg)    '(spine-crawler)]
            [else      '(bunker)]))
        (define scouts
          (let ([avail
                 (for/list : (Listof Any) ([a (in-list ally-units)]
                                           #:when (and (or (u-worker? (u-type a))
                                                           (memq (u-type a) '(reaper zergling adept stalker marine)))
                                                       (> (u-tag a) 0)
                                                       (u-alive? a)))
                   a)])
            (for/list : (Listof harass-directive)
                      ([u (in-list (take avail (min 2 (length avail))))]
                       [pt (in-list scout-pts)])
              (harass-directive (u-tag u) (u-type u) 'move #f 16 0 (car pt) (cdr pt)
                                94.0 'counter-proxy-lateral-off-path-scout 'counter-proxy))))
        (counter-proxy-plan #t enemy-race scout-pts def-bldgs scouts 'counter-proxy-missing-home-production)])]))

;; =============================================================================
;; 5. Raven Harass, Oracle Harass & Simultaneous Multi-Base Viking Landings
;; =============================================================================

(define VIKING-LAND-BLOCKING-AIR-SYMS : (Listof Symbol)
  '(carrier tempest battlecruiser brood-lord broodlord mothership
    void-ray voidray corruptor phoenix mutalisk viking viking-fighter))

;; Plans peripheral air harass across Raven (`auto-turret` `349`/`379`, `anti-armor-missile` `3753`),
;; Oracle (`pulsar-beam` `2375` `60f` dwell, `stasis-ward` `2505`, `oracle-revelation` `2146`), and
;; Simultaneous Multi-Base Viking Landings (`>= 4` Vikings split into `2–3` pairs via `403`, liftoff `405`).
(: plan-air-worker-harass-tactics
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real #:home-y Real
         #:enemy-main-x (Option Real) #:enemy-main-y (Option Real)
         #:enemy-targets (Listof (Pair Real Real))
         #:current-frame Integer)
        (Listof harass-directive)))
(define (plan-air-worker-harass-tactics ally-units enemy-units
                                        #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                        #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                        #:enemy-main-x [emx #f]
                                        #:enemy-main-y [emy #f]
                                        #:enemy-targets [explicit-targets '()]
                                        #:current-frame [_current-frame 0])
  (define hx (->float home-x))
  (define hy (->float home-y))
  (define-values (rev-ravens rev-oracles rev-v-air rev-v-landed)
    (for/fold ([rs : (Listof Any) '()]
               [os : (Listof Any) '()]
               [vas : (Listof Any) '()]
               [vls : (Listof Any) '()])
              ([a (in-list ally-units)])
      (define ut (u-type a))
      (cond
        [(and (eq? ut 'raven) (> (u-tag a) 0) (u-alive? a))
         (values (cons a rs) os vas vls)]
        [(and (eq? ut 'oracle) (> (u-tag a) 0) (u-alive? a))
         (values rs (cons a os) vas vls)]
        [(and (memq ut '(viking viking-fighter)) (> (u-tag a) 0) (u-alive? a))
         (values rs os (cons a vas) vls)]
        [(and (eq? ut 'viking-assault) (> (u-tag a) 0) (u-alive? a))
         (values rs os vas (cons a vls))]
        [else (values rs os vas vls)])))
  (cond
    [(and (null? rev-ravens) (null? rev-oracles) (null? rev-v-air) (null? rev-v-landed))
     '()]
    [else
     (define ravens (reverse rev-ravens))
     (define oracles (reverse rev-oracles))
     (define vikings-air (reverse rev-v-air))
     (define vikings-landed (reverse rev-v-landed))
     (define targets
       (if (pair? explicit-targets)
           (for/list : (Listof (Pair Float Float)) ([p (in-list explicit-targets)])
             (cons (->float (car p)) (->float (cdr p))))
           (infer-base-targets enemy-units hx hy emx emy)))
     (define num-targets (length targets))
     ;; Check whether enemy capital / combat air suppresses Viking harassment landings (only when Vikings present)
     (define capital-air-present?
       (and (or (pair? vikings-landed) (>= (length vikings-air) 4))
            (for/or : Boolean ([e (in-list enemy-units)])
              (and (not (not (memq (u-type e) VIKING-LAND-BLOCKING-AIR-SYMS)))
                   (u-alive? e)))))
     ;; 1. Raven Harass (`auto-turret` + `anti-armor-missile`)
     (define raven-dirs
       (if (null? ravens)
           '()
           (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                     ([r (in-list ravens)]
                      [idx (in-naturals)])
             (define rtag (u-tag r))
             (define rx (u-x r))
             (define ry (u-y r))
             (define eng (u-energy r))
             (define tgt (list-ref targets (modulo idx num-targets)))
             (define tx (car tgt))
             (define ty (cdr tgt))
             (define d (dist2 rx ry tx ty))
             (define aa-threat?
               (for/or : Boolean ([e (in-list enemy-units)])
                 (and (memq (u-type e) '(marine stalker hydralisk queen cyclone missile-turret spore-crawler photon-cannon))
                      (u-alive? e)
                      (<= (dist2 rx ry (u-x e) (u-y e)) 7.0))))
             (define aam-tgt
               (for/fold ([best : (Option Any) #f] [bpwr : Float 0.0] #:result best)
                         ([e (in-list enemy-units)]
                          #:when (and (> (u-tag e) 0) (not (u-structure? e)) (u-alive? e)
                                      (<= (dist2 rx ry (u-x e) (u-y e)) 10.0)))
                 (define p (unit-power e))
                 (if (> p bpwr) (values e p) (values best bpwr))))
             (cond
               [(and aa-threat? (< (u-hp-ratio r) 0.70))
                (define esc (clamp-pt (+ rx (* 6.0 (/ (- hx rx) (max 1e-4 (dist2 rx ry hx hy)))))
                                      (+ ry (* 6.0 (/ (- hy ry) (max 1e-4 (dist2 rx ry hx hy)))))
                                      200.0 200.0))
                (cons (harass-directive rtag 'raven 'move #f 16 0 (car esc) (cdr esc)
                                        95.0 'raven-evade-anti-air 'raven-harass)
                      acc)]
               [(and (>= eng 75.0) aam-tgt (>= (sum-unit-power enemy-units (u-x aam-tgt) (u-y aam-tgt) 4.0) 45.0))
                (cons (harass-directive rtag 'raven 'cast-spell 'anti-armor-missile ANTI-ARMOR-MISSILE-ABILITY-ID
                                        (u-tag aam-tgt) (u-x aam-tgt) (u-y aam-tgt)
                                        88.0 'raven-cast-anti-armor-missile 'raven-harass)
                      acc)]
               [(and (>= eng 50.0) (<= d 9.0))
                (define worker-tgt (find-nearest-worker tx ty enemy-units 7.5))
                (define drop-x (if worker-tgt (u-x worker-tgt) tx))
                (define drop-y (if worker-tgt (u-y worker-tgt) ty))
                (cons (harass-directive rtag 'raven 'cast-spell 'auto-turret AUTO-TURRET-ABILITY-ID
                                        0 drop-x drop-y
                                        86.0 'raven-drop-auto-turret-mineral-line 'raven-harass)
                      acc)]
               [else
                (cons (harass-directive rtag 'raven 'move #f 16 0 tx ty
                                        62.0 'raven-fly-peripheral-mineral-line 'raven-harass)
                      acc)]))))
     ;; 2. Oracle Harass (`pulsar-beam` 60f dwell + `stasis-ward` + `oracle-revelation`)
     (define oracle-dirs
       (if (null? oracles)
           '()
           (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                     ([o (in-list oracles)]
                      [idx (in-naturals)])
             (define otag (u-tag o))
             (define ox (u-x o))
             (define oy (u-y o))
             (define eng (u-energy o))
             (define dwell (safe-int (dyn-hash-ref o 'pulsar-dwell-frames 0) 0))
             (define tgt (list-ref targets (modulo idx num-targets)))
             (define tx (car tgt))
             (define ty (cdr tgt))
             (define d (dist2 ox oy tx ty))
             (define cloak-threat
               (for/fold ([hit : (Option Any) #f])
                         ([e (in-list enemy-units)]
                          #:when (and (not hit)
                                      (or (eq? (dyn-hash-ref e 'cloaked? #f) #t)
                                          (memq (u-type e) '(banshee dark-templar widow-mine-burrowed lurker-burrowed)))
                                      (u-alive? e)
                                      (<= (dist2 ox oy (u-x e) (u-y e)) 11.0)))
                 e))
             (define worker-tgt (find-nearest-worker tx ty enemy-units 7.5))
             (cond
               ;; Dwell ceiling `60f` or heavy AA -> disengage immediately after sweep
               [(or (>= dwell 60) (< (u-hp-ratio o) 0.45))
                (define esc (clamp-pt (+ ox (* 8.0 (/ (- hx ox) (max 1e-4 (dist2 ox oy hx hy)))))
                                      (+ oy (* 8.0 (/ (- hy oy) (max 1e-4 (dist2 ox oy hx hy)))))
                                      200.0 200.0))
                (cons (harass-directive otag 'oracle 'move #f 16 0 (car esc) (cdr esc)
                                        94.0 'oracle-pulsar-60f-dwell-exit 'oracle-harass)
                      acc)]
               [(and cloak-threat (>= eng 25.0))
                (cons (harass-directive otag 'oracle 'cast-spell 'oracle-revelation ORACLE-REVELATION-ABILITY-ID
                                        0 (u-x cloak-threat) (u-y cloak-threat)
                                        90.0 'oracle-revelation-cloaked-threat 'oracle-harass)
                      acc)]
               [(and worker-tgt (<= d 6.5) (>= eng 25.0)
                     (not (eq? (dyn-hash-ref o 'pulsar-beam-active? #f) #t)))
                (cons (harass-directive otag 'oracle 'cast-spell 'pulsar-beam PULSAR-BEAM-ABILITY-ID
                                        otag (u-x worker-tgt) (u-y worker-tgt)
                                        92.0 'oracle-activate-pulsar-beam-workers 'oracle-harass)
                      acc)]
               [(and worker-tgt (<= d 6.5))
                (cons (harass-directive otag 'oracle 'focus-fire #f 0 (u-tag worker-tgt)
                                        (u-x worker-tgt) (u-y worker-tgt)
                                        89.0 'oracle-pulsar-beam-focus-worker 'oracle-harass)
                      acc)]
               [(and (>= eng 50.0) (<= d 14.0))
                (cons (harass-directive otag 'oracle 'cast-spell 'stasis-ward STASIS-WARD-ABILITY-ID
                                        0 tx ty
                                        78.0 'oracle-place-stasis-ward-trap 'oracle-harass)
                      acc)]
               [else
                (cons (harass-directive otag 'oracle 'move #f 16 0 tx ty
                                        60.0 'oracle-fly-to-mineral-line 'oracle-harass)
                      acc)]))))
     ;; 3. Simultaneous Multi-Base Viking Landings (`>= 4` Vikings into `2-3` mineral-line pairs)
     (define viking-landed-dirs
       (if (null? vikings-landed)
           '()
           (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                     ([v (in-list vikings-landed)])
             (define vtag (u-tag v))
             (define vx (u-x v))
             (define vy (u-y v))
             (define threat-near?
               (for/or : Boolean ([e (in-list enemy-units)])
                 (and (not (u-worker? (u-type e))) (not (u-structure? e)) (u-alive? e)
                      (<= (dist2 vx vy (u-x e) (u-y e)) 6.5))))
             (define worker-tgt (find-nearest-worker vx vy enemy-units 7.5))
             (cond
               [(or capital-air-present? threat-near? (< (u-hp-ratio v) 0.50))
                (cons (harass-directive vtag 'viking-assault 'cast-spell 'morph-viking-fighter
                                        MORPH-VIKING-FIGHTER-ABILITY-ID vtag vx vy
                                        96.0 'viking-liftoff-on-6.5t-defender-threat 'multi-base-viking)
                      acc)]
               [worker-tgt
                (cons (harass-directive vtag 'viking-assault 'focus-fire #f 0 (u-tag worker-tgt)
                                        (u-x worker-tgt) (u-y worker-tgt)
                                        85.0 'viking-assault-slaughter-workers 'multi-base-viking)
                      acc)]
               [else acc]))))
     (define viking-air-dirs
       (if (or (< (length vikings-air) 4) capital-air-present?)
           '()
           (let* ([num-groups (min 3 (max 2 (min num-targets (quotient (length vikings-air) 2))))]
                  [tgt-vec : (Vectorof (Pair Float Float))
                   (for/vector : (Vectorof (Pair Float Float)) ([i (in-range num-groups)])
                     (list-ref targets i))]
                  [blocked-vec : (Vectorof Boolean) (make-vector num-groups #f)])
             (for ([e (in-list enemy-units)])
               (when (and (not (u-worker? (u-type e))) (not (u-structure? e)) (u-alive? e))
                 (define ex (u-x e))
                 (define ey (u-y e))
                 (for ([gi (in-range num-groups)])
                   (unless (vector-ref blocked-vec gi)
                     (define tp (vector-ref tgt-vec gi))
                     (when (<= (dist2 (car tp) (cdr tp) ex ey) 6.5)
                       (vector-set! blocked-vec gi #t))))))
             (for/list : (Listof harass-directive)
                       ([v (in-list vikings-air)]
                        [idx (in-naturals)])
               (define gi (modulo (quotient idx 2) num-groups))
               (define tgt (vector-ref tgt-vec gi))
               (define vtag (u-tag v))
               (define vx (u-x v))
               (define vy (u-y v))
               (define tx (car tgt))
               (define ty (cdr tgt))
               (define d (dist2 vx vy tx ty))
               (if (and (<= d 6.5) (not (vector-ref blocked-vec gi)))
                   (harass-directive vtag 'viking-fighter 'cast-spell 'morph-viking-assault
                                     MORPH-VIKING-ASSAULT-ABILITY-ID vtag tx ty
                                     91.0 'multi-base-viking-simultaneous-land 'multi-base-viking)
                   (harass-directive vtag 'viking-fighter 'move #f 16 0 tx ty
                                     74.0 'multi-base-viking-pair-approach 'multi-base-viking))))))
     (append raven-dirs oracle-dirs viking-landed-dirs viking-air-dirs)]))

;; Counters Raven Auto-Turrets (`> 7.0`-tile worker pull for 10s), Oracle Stasis Wards,
;; and Simultaneous Multi-Base Landed Vikings (`2` anti-armor defenders per landed Viking pair).
(: plan-counter-air-worker-harass
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real #:home-y Real)
        (Listof harass-directive)))
(define (plan-counter-air-worker-harass ally-units enemy-units
                                        #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                        #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y])
  (define _hx (->float home-x))
  (define _hy (->float home-y))
  (define-values (rev-turrets rev-stases rev-landed-vikings)
    (for/fold ([ts : (Listof Any) '()] [ss : (Listof Any) '()] [lvs : (Listof Any) '()])
              ([e (in-list enemy-units)])
      (define ut (u-type e))
      (cond
        [(and (eq? ut 'auto-turret) (u-alive? e))
         (values (cons e ts) ss lvs)]
        [(and (memq ut '(oracle-stasis-trap stasis-ward)) (> (u-tag e) 0) (u-alive? e))
         (values ts (cons e ss) lvs)]
        [(and (eq? ut 'viking-assault) (> (u-tag e) 0) (u-alive? e))
         (values ts ss (cons e lvs))]
        [else (values ts ss lvs)])))
  (cond
    [(and (null? rev-turrets) (null? rev-stases) (null? rev-landed-vikings))
     '()]
    [else
     (define turrets (reverse rev-turrets))
     (define stases (reverse rev-stases))
     (define landed-vikings (reverse rev-landed-vikings))
  ;; 1. Worker evacuation > 7.0 tiles from enemy Auto-Turret (10s timeout vs killing turret)
  (define turret-worker-pulls
    (if (null? turrets)
        '()
        (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                  ([w (in-list ally-units)]
                   #:when (and (u-alive? w) (> (u-tag w) 0) (u-worker? (u-type w))))
          (define wx (u-x w))
          (define wy (u-y w))
          (define near-t
            (for/fold ([best : (Option Any) #f] [bd : Float 7.0] #:result best)
                      ([t (in-list turrets)])
              (define d (dist2 wx wy (u-x t) (u-y t)))
              (if (<= d bd) (values t d) (values best bd))))
          (if near-t
              (let* ([tx (u-x near-t)]
                     [ty (u-y near-t)]
                     [dx (- wx tx)]
                     [dy (- wy ty)]
                     [n (max 1e-4 (dist2 0.0 0.0 dx dy))]
                     [safe (clamp-pt (+ tx (* 8.2 (/ dx n))) (+ ty (* 8.2 (/ dy n))) 200.0 200.0)])
                (cons (harass-directive (u-tag w) (u-type w) 'move #f 16 (u-tag near-t)
                                        (car safe) (cdr safe)
                                        96.0 'counter-auto-turret-pull-workers-7t 'counter-air-harass)
                      acc))
              acc))))
  ;; 2. Stasis Ward clearing (ranged snipe or single cheap unit trigger, keeping workers away)
  (define stasis-dirs
    (if (null? stases)
        '()
        (let* ([st (car stases)]
               [sx (u-x st)]
               [sy (u-y st)]
               [cleaner
                (for/fold ([best : (Option Any) #f] [bd : Float 14.0] #:result best)
                          ([a (in-list ally-units)]
                           #:when (and (u-alive? a) (> (u-tag a) 0)
                                       (not (u-worker? (u-type a))) (not (u-structure? a))))
                  (define d (dist2 (u-x a) (u-y a) sx sy))
                  (if (< d bd) (values a d) (values best bd)))])
          (if cleaner
              (list (harass-directive (u-tag cleaner) (u-type cleaner) 'focus-fire #f 0
                                      (u-tag st) sx sy
                                      84.0 'counter-oracle-clear-stasis-ward 'counter-air-harass))
              '()))))
  ;; 3. Cluster landed VikingAssaults by base (~10t clusters) & dispatch 2 defenders per cluster
  (define viking-dirs
    (if (null? landed-vikings)
        '()
        (let ([clusters : (Listof (Listof Any))
                (reverse
                 (for/fold ([cls : (Listof (Listof Any)) '()])
                           ([v (in-list landed-vikings)])
                   (define vx (u-x v))
                   (define vy (u-y v))
                   (define-values (rev-updated placed?)
                     (for/fold ([sub : (Listof (Listof Any)) '()] [hit? : Boolean #f])
                               ([c (in-list cls)])
                       (if (and (not hit?) (<= (dist2 vx vy (u-x (car c)) (u-y (car c))) 12.0))
                           (values (cons (cons v c) sub) #t)
                           (values (cons c sub) hit?))))
                   (if placed? (reverse rev-updated) (cons (list v) cls))))]
              [used-defenders : (Mutable-HashTable Integer Boolean) (make-hasheqv)]
              [anti-armor-defs
               (for/list : (Listof Any) ([a (in-list ally-units)]
                                         #:when (and (u-alive? a) (> (u-tag a) 0)
                                                     (memq (u-type a) '(marauder stalker immortal roach ravager
                                                                        hydralisk queen zealot marine))))
                 a)])
          (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                    ([c (in-list clusters)])
            (define lead-v (car c))
            (define vx (u-x lead-v))
            (define vy (u-y lead-v))
            (define avail
              (sort
               (for/list : (Listof Any) ([a (in-list anti-armor-defs)]
                                         #:when (not (hash-has-key? used-defenders (u-tag a))))
                 a)
               (lambda ([a : Any] [b : Any])
                 (< (dist2 (u-x a) (u-y a) vx vy)
                    (dist2 (u-x b) (u-y b) vx vy)))))
            (define pair-defs (take avail (min 2 (length avail))))
            (for/fold ([sub : (Listof harass-directive) acc]) ([d (in-list pair-defs)])
              (hash-set! used-defenders (u-tag d) #t)
              (cons (harass-directive (u-tag d) (u-type d) 'focus-fire #f 0
                                      (u-tag lead-v) vx vy
                                      90.0 'counter-multi-base-viking-2-defenders 'counter-air-harass)
                    sub))))))
     (append turret-worker-pulls stasis-dirs viking-dirs)]))

;; =============================================================================
;; 6. Splitting & Baneling Target-Firing <-> Baneling Move-Past & Landmines
;; =============================================================================

(define SPLIT-FAN-DEGREES : (Listof Float)
  '(65.0 -65.0 110.0 -110.0 180.0 40.0 -40.0))

(define SPLIT-FAN-COS-SIN : (Vectorof (Pair Float Float))
  (for/vector : (Vectorof (Pair Float Float)) ([deg (in-list SPLIT-FAN-DEGREES)])
    (define rad (* deg (/ pi 180.0)))
    (cons (cos rad) (sin rad))))

(struct abane-rec
  ([tag : Integer]
   [x : Float]
   [y : Float]
   [ehp-lim : Float]
   [assigned-dmg : Float])
  #:mutable)

(struct ashooter-rec
  ([tag : Integer]
   [ut : Symbol]
   [x : Float]
   [y : Float]
   [dmg : Float]
   [light? : Boolean]))

(struct alight-rec
  ([tag : Integer]
   [ut : Symbol]
   [x : Float]
   [y : Float]
   [idx : Integer]))

(: rotate-vec (-> Float Float Float (Pair Float Float)))
(define (rotate-vec vx vy deg)
  (define rad (* deg (/ pi 180.0)))
  (define ca (cos rad))
  (define sa (sin rad))
  (cons (- (* vx ca) (* vy sa))
        (+ (* vx sa) (* vy ca))))

(: anti-baneling-light-sym? (-> Symbol Boolean))
(define (anti-baneling-light-sym? ut)
  (not (not (memq ut '(marine zergling hydralisk adept zealot scv probe drone reaper)))))

(: anti-baneling-armored-blocker-sym? (-> Symbol Boolean))
(define (anti-baneling-armored-blocker-sym? ut)
  (not (not (memq ut '(marauder thor thor-ap immortal archon stalker roach queen)))))

(: attacker-bane-damage (-> Symbol Float))
(define (attacker-bane-damage ut)
  (case ut
    [(siege-tank-sieged) 70.0]
    [(siege-tank)        35.0]
    [(immortal)          20.0]
    [(roach ravager)     16.0]
    [(stalker)           13.0]
    [(hydralisk)         12.0]
    [(adept)             10.0]
    [(marauder)          10.0]
    [(marine)             6.0]
    [else                 0.0]))

;; Anti-Baneling defense:
;;   1) Radial + perpendicular (`±65°`, `±110°`, `180°`) delta-fan split for light units &
;;      workers within `7.5` tiles of incoming Banelings, maintaining `>= 2.4`-tile spacing,
;;      while advancing `1` armored tanky blocker toward leading Banelings.
;;   2) Zero-overkill exact-HP focus-fire allocation (`5–6` Marines, `1` SiegeTank, or
;;      `2–3` Roaches/Stalkers/Hydras per incoming Baneling in parallel).
(: plan-anti-baneling-split-and-target-fire
   (->* ((Listof Any) (Listof Any))
        (#:home-x Real #:home-y Real #:split-radius Real #:min-spacing Real)
        (Listof harass-directive)))
(define (plan-anti-baneling-split-and-target-fire ally-units enemy-units
                                                  #:home-x [home-x SC2-DEFAULT-HOME-BASE-X]
                                                  #:home-y [home-y SC2-DEFAULT-HOME-BASE-Y]
                                                  #:split-radius [split-r-kw ANTI-BANELING-SPLIT-RADIUS]
                                                  #:min-spacing [spacing-kw BANELING-SAFE-SPACING])
  (define _hx (->float home-x))
  (define _hy (->float home-y))
  (define split-r (->float split-r-kw))
  (define split-r2 (* split-r split-r))
  (define min-spacing (->float spacing-kw))
  (define min-sp2 (* min-spacing min-spacing))
  (define rev-bane-recs : (Listof abane-rec)
    (for/fold ([acc : (Listof abane-rec) '()])
              ([e (in-list enemy-units)])
      (if (and (eq? (u-type e) 'baneling)
               (> (u-tag e) 0)
               (u-alive? e))
          (cons (abane-rec (u-tag e) (u-x e) (u-y e) (+ (u-ehp e) 4.0) 0.0) acc)
          acc)))
  (cond
    [(null? rev-bane-recs) '()]
    [else
     (define bane-recs (reverse rev-bane-recs))
     (define lead-rec (car bane-recs))
     (define lb-tag (abane-rec-tag lead-rec))
     (define lb-x (abane-rec-x lead-rec))
     (define lb-y (abane-rec-y lead-rec))
     ;; Single pass over `ally-units`: find nearest armored blocker + sac Zergling fallback,
     ;; collect shooters (`dmg > 0`), and collect splittable light units with original index.
     (define best-arm-tag : Integer -1)
     (define best-arm-ut : Symbol 'unknown)
     (define best-arm-d2 : Float +inf.0)
     (define first-ling-tag : Integer -1)
     (define ling-cnt : Integer 0)
     (define-values (rev-shooters rev-lights)
       (for/fold ([shs : (Listof ashooter-rec) '()]
                  [lts : (Listof alight-rec) '()])
                 ([a (in-list ally-units)]
                  [idx (in-naturals)])
         (cond
           [(not (u-alive? a)) (values shs lts)]
           [else
            (define atag (u-tag a))
            (cond
              [(<= atag 0) (values shs lts)]
              [else
               (define ut (u-type a))
               (define arm? (anti-baneling-armored-blocker-sym? ut))
               (define dmg (attacker-bane-damage ut))
               (define lgt? (anti-baneling-light-sym? ut))
               (define sac-ling? (eq? ut 'zergling))
               (if (or arm? (> dmg 0.0) lgt?)
                   (let ([ax (u-x a)]
                         [ay (u-y a)])
                     (when arm?
                       (define dx (- ax lb-x))
                       (define dy (- ay lb-y))
                       (define d2 (+ (* dx dx) (* dy dy)))
                       (when (and (<= d2 121.0)
                                  (or (< best-arm-tag 0) (< d2 best-arm-d2)))
                         (set! best-arm-tag atag)
                         (set! best-arm-ut ut)
                         (set! best-arm-d2 d2)))
                     (when (and sac-ling? (< best-arm-tag 0))
                       (define dx (- ax lb-x))
                       (define dy (- ay lb-y))
                       (when (<= (+ (* dx dx) (* dy dy)) split-r2)
                         (when (= ling-cnt 0)
                           (set! first-ling-tag atag))
                         (set! ling-cnt (add1 ling-cnt))))
                     (values
                      (if (> dmg 0.0)
                          (cons (ashooter-rec atag ut ax ay dmg lgt?) shs)
                          shs)
                      (if lgt?
                          (cons (alight-rec atag ut ax ay idx) lts)
                          lts)))
                   (values shs lts))])])))
     ;; Note: if `best-arm-tag < 0` and an early zergling triggered before an armored unit appeared later,
     ;; `best-arm-tag` became >= 0 later so armored takes precedence (`blocker-tag` prefers `best-arm-tag`).
     (define-values (blocker-tag blocker-ut)
       (cond
         [(>= best-arm-tag 0) (values best-arm-tag best-arm-ut)]
         [(>= ling-cnt 4) (values first-ling-tag 'zergling)]
         [else (values -1 'unknown)]))
     (define blocker-dirs
       (if (>= blocker-tag 0)
           (list (harass-directive blocker-tag blocker-ut 'move #f 16
                                   lb-tag lb-x lb-y
                                   94.0 'anti-baneling-armored-tank-block 'anti-baneling))
           '()))
     ;; 2. Zero-overkill exact-HP focus-fire allocation across multiple Banelings in parallel
     (define shooter-used : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (define raw-shooters
       (if (< blocker-tag 0)
           (reverse rev-shooters)
           (for/fold ([acc : (Listof ashooter-rec) '()])
                     ([sr (in-list rev-shooters)])
             (if (= (ashooter-rec-tag sr) blocker-tag)
                 acc
                 (cons sr acc)))))
     (define shooters
       (sort raw-shooters
             (lambda ([a : ashooter-rec] [b : ashooter-rec])
               ;; Prioritize Siege Tanks first (1-shot kill), then Roaches/Stalkers/Hydras, then Marines
               (> (ashooter-rec-dmg a) (ashooter-rec-dmg b)))))
     (define fire-dirs
       (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                 ([sr (in-list shooters)])
         (define stag (ashooter-rec-tag sr))
         (define st (ashooter-rec-ut sr))
         (define dmg (ashooter-rec-dmg sr))
         (define sx (ashooter-rec-x sr))
         (define sy (ashooter-rec-y sr))
         (define rng2
           (case st
             [(siege-tank-sieged) 182.25]
             [(siege-tank stalker hydralisk) 56.25]
             [(marine marauder immortal roach adept ravager) 51.84]
             [else 42.25]))
         ;; Do NOT pull unengaged close light units forward if already inside split panic < 4.8t (let Marines shoot only if > 4.8t or already clear)
         (define safe-to-shoot?
           (or (not (ashooter-rec-light? sr))
               (for/and : Boolean ([br (in-list bane-recs)])
                 (define dx (- sx (abane-rec-x br)))
                 (define dy (- sy (abane-rec-y br)))
                 (> (+ (* dx dx) (* dy dy)) 21.16))))
         (define target-br : (Option abane-rec)
           (and safe-to-shoot?
                (for/fold ([best : (Option abane-rec) #f] [bd2 : Float +inf.0] #:result best)
                          ([br (in-list bane-recs)])
                  (define dx (- sx (abane-rec-x br)))
                  (define dy (- sy (abane-rec-y br)))
                  (define d2 (+ (* dx dx) (* dy dy)))
                  (if (and (<= d2 rng2)
                           (< (abane-rec-assigned-dmg br) (abane-rec-ehp-lim br))
                           (< d2 bd2))
                      (values br d2)
                      (values best bd2)))))
         (if target-br
             (begin
               (set-abane-rec-assigned-dmg! target-br (+ (abane-rec-assigned-dmg target-br) dmg))
               (hash-set! shooter-used stag #t)
               (cons (harass-directive stag st 'focus-fire #f 0 (abane-rec-tag target-br)
                                       (abane-rec-x target-br) (abane-rec-y target-br)
                                       92.0 'anti-baneling-zero-overkill-focus-fire 'anti-baneling)
                     acc))
             acc)))
     ;; 3. Radial + perpendicular (`±65°`, `±110°`, `180°`) fan splitting for threatened light units
     (define fan-cnt (vector-length SPLIT-FAN-COS-SIN))
     (define occupied-split-pts : (Listof (Pair Float Float)) '())
     (define split-dirs
       (for/fold ([acc : (Listof harass-directive) '()] #:result (reverse acc))
                 ([lr (in-list (reverse rev-lights))]
                  #:when (and (not (= (alight-rec-tag lr) blocker-tag))
                              (not (hash-has-key? shooter-used (alight-rec-tag lr)))))
         (define ax (alight-rec-x lr))
         (define ay (alight-rec-y lr))
         (define near-bane : (Option abane-rec)
           (for/fold ([best : (Option abane-rec) #f] [bd2 : Float split-r2] #:result best)
                     ([br (in-list bane-recs)])
             (define dx (- ax (abane-rec-x br)))
             (define dy (- ay (abane-rec-y br)))
             (define d2 (+ (* dx dx) (* dy dy)))
             (if (<= d2 bd2) (values br d2) (values best bd2))))
         (cond
           [(not near-bane) acc]
           [else
            (define bx (abane-rec-x near-bane))
            (define by (abane-rec-y near-bane))
            (define avx (- ax bx))
            (define avy (- ay by))
            (define alen (max 1e-4 (flsqrt (+ (* avx avx) (* avy avy)))))
            (define ux (/ avx alen))
            (define uy (/ avy alen))
            (define idx (alight-rec-idx lr))
            (define fan-idx (modulo idx fan-cnt))
            (define step-len (+ 3.2 (* 0.8 (exact->inexact (quotient idx fan-cnt)))))
            ;; Try rotating through fan degrees + step lengths until >= 2.4 tiles from existing targets
            (define chosen-pt : (Pair Float Float)
              (let loop ([offs : Integer 0])
                (if (>= offs fan-cnt)
                    (let* ([cs (vector-ref SPLIT-FAN-COS-SIN fan-idx)]
                           [ca (car cs)]
                           [sa (cdr cs)]
                           [rx (- (* ux ca) (* uy sa))]
                           [ry (+ (* ux sa) (* uy ca))])
                      (clamp-pt (+ ax (* 4.2 rx)) (+ ay (* 4.2 ry)) 200.0 200.0))
                    (let* ([cs (vector-ref SPLIT-FAN-COS-SIN (modulo (+ fan-idx offs) fan-cnt))]
                           [ca (car cs)]
                           [sa (cdr cs)]
                           [rx (- (* ux ca) (* uy sa))]
                           [ry (+ (* ux sa) (* uy ca))]
                           [cx (+ ax (* step-len rx))]
                           [cy (+ ay (* step-len ry))]
                           [cand (clamp-pt cx cy 200.0 200.0)]
                           [cpx (car cand)]
                           [cpy (cdr cand)]
                           [spaced?
                            (for/and : Boolean ([p (in-list occupied-split-pts)])
                              (define dx (- cpx (car p)))
                              (define dy (- cpy (cdr p)))
                              (>= (+ (* dx dx) (* dy dy)) min-sp2))])
                      (if spaced? cand (loop (add1 offs)))))))
            (set! occupied-split-pts (cons chosen-pt occupied-split-pts))
            (cons (harass-directive (alight-rec-tag lr) (alight-rec-ut lr) 'move #f 16 (abane-rec-tag near-bane)
                                    (car chosen-pt) (cdr chosen-pt)
                                    96.0 'anti-baneling-fan-split-2.4t 'anti-baneling)
                  acc)])))
     (append blocker-dirs split-dirs fire-dirs)]))

(: baneling-high-value-light-sym? (-> Symbol Boolean))
(define (baneling-high-value-light-sym? ut)
  (not (not (memq ut '(marine zergling zealot adept hydralisk scv probe drone mule hellbat baneling high-templar)))))

(: baneling-worker-sym? (-> Symbol Boolean))
(define (baneling-worker-sym? ut)
  (not (not (memq ut '(scv probe drone mule)))))

(: baneling-armored-tank-sym? (-> Symbol Boolean))
(define (baneling-armored-tank-sym? ut)
  (not (not (memq ut '(marauder immortal archon roach ravager stalker thor thor-ap siege-tank siege-tank-sieged ultralisk colossus lurker lurker-burrowed)))))

(: baneling-light-default-hp (-> Symbol Float))
(define (baneling-light-default-hp ut)
  (case ut
    [(hydralisk adept) 125.0]
    [(zealot) 150.0]
    [(zergling) 35.0]
    [(baneling) 30.0]
    [else 45.0]))

;; Counterpart Baneling micro:
;;   1) Rolling `baneling` (`9`): move (`16`) PAST armored blockers into dense Light/Worker clumps
;;      with exact-lethal quota (`needed-banes`) per clump; never overcommit excess Banelings, and
;;      hold off (`4.5` tiles back) from armored/structure/isolated single targets (`<= 9.0` tiles).
;;   2) Burrowed `baneling-burrowed` (`115`) landmines: detonate (`42`) when `>= 3` light/worker
;;      units stand within `2.1` tiles, bounded by clump `needed-banes`.
(struct light-clump-rec
  ([u : Any]
   [x : Float]
   [y : Float]
   [base-sc : Float]
   [val : Float]
   [needed-banes : Integer]))

(struct gnd-enemy-rec
  ([x : Float]
   [y : Float]
   [armored? : Boolean]
   [struct? : Boolean]))

(struct baneling-unit-rec
  ([u : Any]
   [tag : Integer]
   [bt : Symbol]
   [x : Float]
   [y : Float]
   [hp : Float]))

(struct baneling-raw-light
  ([u : Any]
   [x : Float]
   [y : Float]
   [ehp : Float]
   [worker? : Boolean]))

(: baneling-pullback-pt (-> Float Float Float Float Float Float Float Integer (Pair Float Float)))
(define (baneling-pullback-pt bx by ex ey home-x home-y step-dist spread-idx)
  (define ax (- bx ex))
  (define ay (- by ey))
  (define alen (flsqrt (+ (* ax ax) (* ay ay))))
  (define-values (ux uy)
    (if (> alen 1e-4)
        (values (/ ax alen) (/ ay alen))
        (values 0.0 0.0)))
  (define hx (- home-x bx))
  (define hy (- home-y by))
  (define hlen (flsqrt (+ (* hx hx) (* hy hy))))
  (define-values (vx vy)
    (if (> hlen 1e-4)
        (values (/ hx hlen) (/ hy hlen))
        (values 0.0 0.0)))
  (define-values (dx0 dy0)
    (cond
      [(and (> alen 1e-4) (> hlen 1e-4) (>= (+ (* ux vx) (* uy vy)) -0.2))
       (values (+ (* 0.55 ux) (* 0.45 vx))
               (+ (* 0.55 uy) (* 0.45 vy)))]
      [(> alen 1e-4) (values ux uy)]
      [(> hlen 1e-4) (values vx vy)]
      [else (values -1.0 0.0)]))
  (define dlen (flsqrt (+ (* dx0 dx0) (* dy0 dy0))))
  (define-values (nx ny)
    (if (> dlen 1e-4)
        (values (/ dx0 dlen) (/ dy0 dlen))
        (values -1.0 0.0)))
  (define lat-offset
    (if (= spread-idx 0)
        0.0
        (let* ([sign (if (odd? spread-idx) 1.0 -1.0)]
               [mag (* 1.3 (->float (quotient (+ spread-idx 1) 2)))])
          (* sign mag))))
  (define tx (clamp-coord (+ bx (* step-dist nx) (* lat-offset (- ny))) 4.0 220.0))
  (define ty (clamp-coord (+ by (* step-dist ny) (* lat-offset nx)) 4.0 220.0))
  (cons tx ty))

(: plan-baneling-move-past-and-light-clump-detonate
   (->* ((Listof Any) (Listof Any))
        (#:splash-radius Real #:landmine-radius Real #:home-x Real #:home-y Real)
        (Listof harass-directive)))
(define (plan-baneling-move-past-and-light-clump-detonate ally-units enemy-units
                                                          #:splash-radius [splash-kw BANELING-SPLASH-RADIUS]
                                                          #:landmine-radius [mine-r-kw BANELING-LANDMINE-DETONATE-RADIUS]
                                                          #:home-x [home-x 28.0]
                                                          #:home-y [home-y 28.0])
  (define splash-r (->float splash-kw))
  (define splash-r2 (* splash-r splash-r))
  (define mine-r (->float mine-r-kw))
  (define mine-r2 (* mine-r mine-r))
  (define hx-f (->float home-x))
  (define hy-f (->float home-y))
  (define-values (burrowed-banes rolling-banes)
    (for/fold ([bur : (Listof baneling-unit-rec) '()]
               [rol : (Listof baneling-unit-rec) '()])
              ([a (in-list ally-units)])
      (define bt (u-type a))
      (if (memq bt '(baneling baneling-burrowed))
          (let ([btag (u-tag a)])
            (if (and (> btag 0) (u-alive? a))
                (let ([rec (baneling-unit-rec a btag bt (u-x a) (u-y a) (u-hp a 30.0))])
                  (if (eq? bt 'baneling-burrowed)
                      (values (cons rec bur) rol)
                      (values bur (cons rec rol))))
                (values bur rol)))
          (values bur rol))))
  (cond
    [(and (null? burrowed-banes) (null? rolling-banes)) '()]
    [else
     (define-values (rev-ground rev-inefficient rev-light-raw any-armored?)
       (for/fold ([gs : (Listof gnd-enemy-rec) '()]
                  [ineffs : (Listof (Pair Float Float)) '()]
                  [ls : (Listof baneling-raw-light) '()]
                  [arm? : Boolean #f])
                 ([e (in-list enemy-units)]
                  #:when (and (not (u-flying? e)) (u-alive? e)))
         (define ex (u-x e))
         (define ey (u-y e))
         (define e-struct? (u-structure? e))
         (cond
           [e-struct?
            (values gs (cons (cons ex ey) ineffs) ls #t)]
           [else
            (define et (u-type e))
            (define e-arm? (baneling-armored-tank-sym? et))
            (define next-gs (cons (gnd-enemy-rec ex ey e-arm? #f) gs))
            (define next-ineffs (if e-arm? (cons (cons ex ey) ineffs) ineffs))
            (define next-ls
              (if (baneling-high-value-light-sym? et)
                  (let ([ehp (max (baneling-light-default-hp et) (u-ehp e))])
                    ;; Use observed hp/shields directly when present, otherwise unit default HP.
                    (define raw-hp (u-hp e -1.0))
                    (define unit-hp
                      (if (>= raw-hp 0.0)
                          (u-ehp e)
                          (baneling-light-default-hp et)))
                    (define worker? (baneling-worker-sym? et))
                    (cons (baneling-raw-light e ex ey (max 1.0 unit-hp) worker?) ls))
                  ls))
            (values next-gs next-ineffs next-ls (or arm? e-arm?))])))
     (define ground-recs (reverse rev-ground))
     (define raw-lights (reverse rev-light-raw))
     (cond
       [(and (null? ground-recs) (null? rev-inefficient)) '()]
       [else
        ;; Compute light-neighbor counts and cluster light/worker targets into disjoint clumps.
        (define raw-n (length raw-lights))
        (define raw-vec : (Vectorof baneling-raw-light) (list->vector raw-lights))
        (define neighbor-cnts : (Vectorof Integer) (make-vector raw-n 0))
        (define cluster-max-hps : (Vectorof Float) (make-vector raw-n 0.0))
        (define cluster-vals : (Vectorof Float) (make-vector raw-n 0.0))
        (for ([i (in-range raw-n)])
          (define ri (vector-ref raw-vec i))
          (define cx (baneling-raw-light-x ri))
          (define cy (baneling-raw-light-y ri))
          (define-values (cnt mhp val)
            (for/fold ([c : Integer 0]
                       [mh : Float (baneling-raw-light-ehp ri)]
                       [tv : Float 0.0])
                      ([j (in-range raw-n)])
              (define rj (vector-ref raw-vec j))
              (define dx (- cx (baneling-raw-light-x rj)))
              (define dy (- cy (baneling-raw-light-y rj)))
              (if (and (<= (abs dx) splash-r)
                       (<= (abs dy) splash-r)
                       (<= (+ (* dx dx) (* dy dy)) splash-r2))
                  (let ([ehp (baneling-raw-light-ehp rj)])
                    (values (+ c 1) (max mh ehp) (+ tv ehp)))
                  (values c mh tv))))
          (vector-set! neighbor-cnts i cnt)
          (vector-set! cluster-max-hps i mhp)
          (vector-set! cluster-vals i val))
        ;; Single isolated non-worker units with < 2 other light neighbors (i.e. cnt <= 2 and non-worker,
        ;; specifically isolated singletons cnt == 1) go to inefficient hold-off list; valid clumps
        ;; require either a worker or >= 2 light units in splash radius.
        (define inefficient-pts : (Listof (Pair Float Float))
          (for/fold ([pts : (Listof (Pair Float Float)) (reverse rev-inefficient)])
                    ([i (in-range raw-n)])
            (define ri (vector-ref raw-vec i))
            (if (and (not (baneling-raw-light-worker? ri))
                     (<= (vector-ref neighbor-cnts i) 1))
                (cons (cons (baneling-raw-light-x ri) (baneling-raw-light-y ri)) pts)
                pts)))
        ;; Greedily form disjoint clumps prioritized by neighbor density & total EHP.
        (define cand-scored : (Listof (Pair Float Integer))
          (for/list ([i (in-range raw-n)]
                     #:when (let ([ri (vector-ref raw-vec i)])
                              (or (baneling-raw-light-worker? ri)
                                  (>= (vector-ref neighbor-cnts i) 2))))
            (cons (+ (* 100.0 (->float (vector-ref neighbor-cnts i)))
                     (vector-ref cluster-vals i))
                  i)))
        (define cand-indices : (Listof Integer)
          (map (lambda ([p : (Pair Float Integer)]) (cdr p))
               (sort cand-scored
                     (lambda ([a : (Pair Float Integer)] [b : (Pair Float Integer)])
                       (> (car a) (car b))))))
        (define covered-vec : (Vectorof Boolean) (make-vector raw-n #f))
        (define clump-list : (Listof light-clump-rec)
          (for/fold ([acc : (Listof light-clump-rec) '()] #:result (reverse acc))
                    ([i (in-list cand-indices)])
            (cond
              [(vector-ref covered-vec i) acc]
              [else
               (define ri (vector-ref raw-vec i))
               (define cx (baneling-raw-light-x ri))
               (define cy (baneling-raw-light-y ri))
               (define-values (cnt mhp val)
                 (for/fold ([c : Integer 0]
                            [mh : Float 0.0]
                            [tv : Float 0.0])
                           ([j (in-range raw-n)])
                   (define rj (vector-ref raw-vec j))
                   (define dx (- cx (baneling-raw-light-x rj)))
                   (define dy (- cy (baneling-raw-light-y rj)))
                   (if (and (<= (abs dx) splash-r)
                            (<= (abs dy) splash-r)
                            (<= (+ (* dx dx) (* dy dy)) splash-r2))
                       (let ([ehp (baneling-raw-light-ehp rj)])
                         (vector-set! covered-vec j #t)
                         (values (+ c 1) (max mh ehp) (+ tv ehp)))
                       (values c mh tv))))
               (define max-hp (if (> mhp 0.0) mhp (baneling-raw-light-ehp ri)))
               (define needed
                 (max 1
                      (min (exact-ceiling (/ max-hp 35.0))
                           (exact-ceiling (/ (max 1.0 val) 55.0)))))
               (cons (light-clump-rec (baneling-raw-light-u ri)
                                      cx cy
                                      (* 25.0 (->float cnt))
                                      val
                                      needed)
                     acc)])))
        (define clump-n (length clump-list))
        (define clump-vec : (Vectorof light-clump-rec) (list->vector clump-list))
        (define clump-det-cnt : (Vectorof Integer) (make-vector clump-n 0))
        (define clump-roll-cnt : (Vectorof Integer) (make-vector clump-n 0))

        ;; Helper: nearest light clump index and distance-squared for a point (bx, by).
        (define (nearest-clump-idx-d2 [bx : Float] [by : Float]) : (Values Integer Float)
          (for/fold ([bi : Integer -1]
                     [bd2 : Float +inf.0])
                    ([i (in-range clump-n)])
            (define c (vector-ref clump-vec i))
            (define dx (- bx (light-clump-rec-x c)))
            (define dy (- by (light-clump-rec-y c)))
            (define d2 (+ (* dx dx) (* dy dy)))
            (if (< d2 bd2) (values i d2) (values bi bd2))))

        ;; Helper: nearest inefficient enemy point within max-r2, or #f.
        (define (nearest-ineff-within [bx : Float] [by : Float] [max-r2 : Float]) : (Option (Pair Float Float))
          (for/fold ([best : (Option (Pair Float Float)) #f]
                     [bd2 : Float max-r2]
                     #:result best)
                    ([pt (in-list inefficient-pts)])
            (define dx (- bx (car pt)))
            (define dy (- by (cdr pt)))
            (define d2 (+ (* dx dx) (* dy dy)))
            (if (<= d2 bd2) (values pt d2) (values best bd2))))

        ;; Sort rolling banelings by distance to nearest light clump so closest claim quota first.
        (define sorted-rolling : (Listof baneling-unit-rec)
          (if (> clump-n 0)
              (let ([scored-banes : (Listof (Pair Float baneling-unit-rec))
                      (for/list ([b (in-list rolling-banes)])
                        (define-values (_idx bd2)
                          (nearest-clump-idx-d2 (baneling-unit-rec-x b) (baneling-unit-rec-y b)))
                        (cons bd2 b))])
                (map (lambda ([p : (Pair Float baneling-unit-rec)]) (cdr p))
                     (sort scored-banes
                           (lambda ([a : (Pair Float baneling-unit-rec)]
                                    [b : (Pair Float baneling-unit-rec)])
                             (< (car a) (car b))))))
              (reverse rolling-banes)))

        ;; 1) Process burrowed landmines first (respecting needed-banes detonation quota per clump).
        (define acc-after-burrowed : (Listof harass-directive)
          (for/fold ([acc : (Listof harass-directive) '()])
                    ([b (in-list (reverse burrowed-banes))])
            (define bx (baneling-unit-rec-x b))
            (define by (baneling-unit-rec-y b))
            (define light-in-mine
              (for/sum : Integer ([j (in-range raw-n)])
                (define rj (vector-ref raw-vec j))
                (define dx (- bx (baneling-raw-light-x rj)))
                (define dy (- by (baneling-raw-light-y rj)))
                (if (and (<= (abs dx) mine-r)
                         (<= (abs dy) mine-r)
                         (<= (+ (* dx dx) (* dy dy)) mine-r2))
                    1
                    0)))
            (cond
              [(>= light-in-mine 3)
               (define-values (ci _cd2) (nearest-clump-idx-d2 bx by))
               (define quota-ok?
                 (or (< ci 0)
                     (< (vector-ref clump-det-cnt ci)
                        (light-clump-rec-needed-banes (vector-ref clump-vec ci)))))
               (cond
                 [quota-ok?
                  (when (>= ci 0)
                    (vector-set! clump-det-cnt ci (+ (vector-ref clump-det-cnt ci) 1))
                    (vector-set! clump-roll-cnt ci (+ (vector-ref clump-roll-cnt ci) 1)))
                  (cons (harass-directive (baneling-unit-rec-tag b) 'baneling-burrowed
                                          'baneling-explode 'baneling-explode BANELING-EXPLODE-ABILITY-ID
                                          (baneling-unit-rec-tag b) bx by 100.0
                                          'baneling-landmine-detonate-3plus-light 'baneling-micro)
                        acc)]
                 [else acc])]
              [else acc])))

        ;; 2) Process rolling banelings in closest-first order.
        (define hold-r2 81.0) ;; 9.0^2 tiles
        (define-values (final-rev-acc _res-idx)
          (for/fold ([acc : (Listof harass-directive) acc-after-burrowed]
                     [res-idx : Integer 0])
                    ([b (in-list sorted-rolling)])
            (define btag (baneling-unit-rec-tag b))
            (define bt (baneling-unit-rec-bt b))
            (define bx (baneling-unit-rec-x b))
            (define by (baneling-unit-rec-y b))
            (define bhp (baneling-unit-rec-hp b))
            (define light-in-splash
              (for/sum : Integer ([j (in-range raw-n)])
                (define rj (vector-ref raw-vec j))
                (define dx (- bx (baneling-raw-light-x rj)))
                (define dy (- by (baneling-raw-light-y rj)))
                (if (and (<= (abs dx) splash-r)
                         (<= (abs dy) splash-r)
                         (<= (+ (* dx dx) (* dy dy)) splash-r2))
                    1
                    0)))
            (define-values (near-ci near-d2) (nearest-clump-idx-d2 bx by))
            (define det-quota-ok?
              (and (>= near-ci 0)
                   (<= near-d2 splash-r2)
                   (< (vector-ref clump-det-cnt near-ci)
                      (light-clump-rec-needed-banes (vector-ref clump-vec near-ci)))))
            (define low-hp-detonate?
              (and (< light-in-splash 3)
                   (<= bhp 12.0)
                   (or (< near-ci 0)
                       (< (vector-ref clump-det-cnt near-ci)
                          (light-clump-rec-needed-banes (vector-ref clump-vec near-ci))))
                   (>= (for/sum : Integer ([g (in-list ground-recs)])
                         (define dx (- bx (gnd-enemy-rec-x g)))
                         (define dy (- by (gnd-enemy-rec-y g)))
                         (if (and (<= (abs dx) splash-r)
                                  (<= (abs dy) splash-r)
                                  (<= (+ (* dx dx) (* dy dy)) splash-r2))
                             1
                             0))
                       2)))
            (define should-explode?
              (and (or (and (>= light-in-splash 3)
                            (or (< near-ci 0)
                                (< (vector-ref clump-det-cnt near-ci)
                                   (light-clump-rec-needed-banes (vector-ref clump-vec near-ci)))))
                       low-hp-detonate?)
                   ;; Only detonate if either there's a valid clump with remaining det quota or low-hp trade
                   (or det-quota-ok? low-hp-detonate? (>= light-in-splash 3))))
            (cond
              [should-explode?
               (when (>= near-ci 0)
                 (vector-set! clump-det-cnt near-ci (+ (vector-ref clump-det-cnt near-ci) 1))
                 (vector-set! clump-roll-cnt near-ci (+ (vector-ref clump-roll-cnt near-ci) 1)))
               (values (cons (harass-directive btag bt 'baneling-explode 'baneling-explode BANELING-EXPLODE-ABILITY-ID
                                               btag bx by 100.0 'baneling-light-clump-detonate 'baneling-micro)
                             acc)
                       res-idx)]
              [(> clump-n 0)
               ;; First seek best clump with strictly < needed-banes assigned; then allow (+ needed 1) if d > 6.0.
               (define-values (strict-ci strict-sc)
                 (for/fold ([bi : Integer -1]
                            [best-sc : Float -1e9])
                           ([i (in-range clump-n)])
                   (define c (vector-ref clump-vec i))
                   (if (< (vector-ref clump-roll-cnt i) (light-clump-rec-needed-banes c))
                       (let* ([d (dist2 bx by (light-clump-rec-x c) (light-clump-rec-y c))]
                              [sc (- (light-clump-rec-base-sc c) d)])
                         (if (> sc best-sc) (values i sc) (values bi best-sc)))
                       (values bi best-sc))))
               (define assigned-ci : Integer
                 (if (>= strict-ci 0)
                     strict-ci
                     (for/fold ([bi : Integer -1]
                                [best-sc : Float -1e9]
                                #:result bi)
                               ([i (in-range clump-n)])
                       (define c (vector-ref clump-vec i))
                       (define d (dist2 bx by (light-clump-rec-x c) (light-clump-rec-y c)))
                       (define roll-cap (+ (light-clump-rec-needed-banes c) (if (> d 6.0) 1 0)))
                       (if (< (vector-ref clump-roll-cnt i) roll-cap)
                           (let ([sc (- (light-clump-rec-base-sc c) d)])
                             (if (> sc best-sc) (values i sc) (values bi best-sc)))
                           (values bi best-sc)))))
               (cond
                 [(>= assigned-ci 0)
                  (vector-set! clump-roll-cnt assigned-ci (+ (vector-ref clump-roll-cnt assigned-ci) 1))
                  (define chosen-clump (vector-ref clump-vec assigned-ci))
                  (define tx (light-clump-rec-x chosen-clump))
                  (define ty (light-clump-rec-y chosen-clump))
                  (define armored-blocking?
                    (and any-armored?
                         (let* ([cdx (- bx tx)]
                                [cdy (- by ty)]
                                [d-clump-sq (+ (* cdx cdx) (* cdy cdy))])
                           (for/or : Boolean ([g (in-list ground-recs)])
                             (and (gnd-enemy-rec-armored? g)
                                  (let ([dx (- bx (gnd-enemy-rec-x g))]
                                        [dy (- by (gnd-enemy-rec-y g))])
                                    (< (+ (* dx dx) (* dy dy)) d-clump-sq)))))))
                  (values (cons (harass-directive btag bt 'move #f 16 0 tx ty
                                                  91.0
                                                  (if armored-blocking?
                                                      'baneling-move-past-screens
                                                      'baneling-roll-to-light-clump)
                                                  'baneling-micro)
                                acc)
                          res-idx)]
                 [else
                  ;; All visible Light/Worker clumps have their quota filled:
                  ;; Hold off 4.5t if armored/inefficient enemy within 9.0t, otherwise reserve 4.0t behind line.
                  (define near-ineff (nearest-ineff-within bx by hold-r2))
                  (cond
                    [near-ineff
                     (define pb (baneling-pullback-pt bx by (car near-ineff) (cdr near-ineff) hx-f hy-f 4.5 0))
                     (values (cons (harass-directive btag bt 'move #f 16 0 (car pb) (cdr pb)
                                                     88.0 'baneling-avoid-armored-waste
                                                     'baneling-hold-off-inefficient-armored)
                                   acc)
                             res-idx)]
                    [else
                     (define ref-c (vector-ref clump-vec (max 0 near-ci)))
                     (define pb (baneling-pullback-pt bx by (light-clump-rec-x ref-c) (light-clump-rec-y ref-c)
                                                      hx-f hy-f 4.0 res-idx))
                     (values (cons (harass-directive btag bt 'move #f 16 0 (car pb) (cdr pb)
                                                     85.0 'baneling-exact-lethal-quota-filled
                                                     'baneling-reserve-no-overcommit)
                                   acc)
                             (+ res-idx 1))])])]
              [else
               ;; raw-lights/valid clumps is empty: hold off from inefficient/armored/isolated enemies within 9.0t.
               (define near-ineff (nearest-ineff-within bx by hold-r2))
               (if near-ineff
                   (let ([pb (baneling-pullback-pt bx by (car near-ineff) (cdr near-ineff) hx-f hy-f 4.5 0)])
                     (values (cons (harass-directive btag bt 'move #f 16 0 (car pb) (cdr pb)
                                                     88.0 'baneling-avoid-armored-waste
                                                     'baneling-hold-off-inefficient-armored)
                                   acc)
                             res-idx))
                   (values acc res-idx))])))
        (reverse final-rev-acc)])]))

;; =============================================================================
;; 7. S-Expression Orchestration
;; =============================================================================

;; Converts a `harass-directive` into a standard `lib/sc2-typed-commands.rkt` S-expression.
(: harass-directive->sexp (-> harass-directive (Listof Any)))
(define (harass-directive->sexp d)
  (define utag (harass-directive-unit-tag d))
  (define tx (harass-directive-tx d))
  (define ty (harass-directive-ty d))
  (define tgt (harass-directive-target-tag d))
  (define ab (harass-directive-ability d))
  (case (harass-directive-action d)
    [(baneling-explode)
     (list 'baneling-explode utag)]
    [(widow-mine-retarget)
     (list 'widow-mine-retarget utag tgt)]
    [(focus-fire)
     (if (> tgt 0)
         (list 'focus-fire utag tgt tx ty)
         (list 'attack-pos utag tx ty))]
    [(attack-unit)
     (list 'attack-unit utag tgt)]
    [(attack-pos)
     (list 'attack-pos utag tx ty)]
    [(transport-drop-point)
     (list 'transport-juggle utag tx ty)]
    [(cast-spell)
     (cond
       [(memq ab '(cancel-adept-phase-shift widow-mine-burrow widow-mine-unburrow
                   morph-viking-assault morph-viking-fighter pulsar-beam))
        (list 'cast-spell utag (or ab 'unknown))]
       [(eq? ab 'anti-armor-missile)
        (list 'cast-spell utag 'anti-armor-missile tgt)]
       [else
        (list 'cast-spell utag (or ab 'unknown) tx ty)])]
    [else
     (list 'move utag tx ty)]))

;; Unified step helper running all Wave 1C multi-task harass, counter, & baneling micro
;; planners cleanly in S-expression form.
(: step-multitask-harass-and-proxy
   (->* (Symbol Symbol (Listof Any) (Listof Any))
        (#:current-frame Integer #:home-x Real #:home-y Real #:enemy-main-x Real #:enemy-main-y Real)
        (Listof (Listof Any))))
(define (step-multitask-harass-and-proxy our-race enemy-race ally-units enemy-units
                                         #:current-frame [current-frame 0]
                                         #:home-x [hx SC2-DEFAULT-HOME-BASE-X]
                                         #:home-y [hy SC2-DEFAULT-HOME-BASE-Y]
                                         #:enemy-main-x [emx 132.0]
                                         #:enemy-main-y [emy 132.0])
  (define hx-f (->float hx))
  (define hy-f (->float hy))
  (define-values (a-has-bane? a-has-adept? a-has-wm-runby? a-runby-cnt a-has-air-harass? rev-ally-ths)
    (for/fold ([bane? : Boolean #f]
               [adept? : Boolean #f]
               [wmr? : Boolean #f]
               [rcnt : Integer 0]
               [airh? : Boolean #f]
               [ths : (Listof (Pair Float Float)) '()])
              ([a (in-list ally-units)])
      (define ut (u-type a))
      (case ut
        [(baneling)
         (if (and (> (u-tag a) 0) (u-alive? a))
             (values #t adept? wmr? (add1 rcnt) airh? ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(baneling-burrowed)
         (if (and (> (u-tag a) 0) (u-alive? a))
             (values #t adept? wmr? rcnt airh? ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(zergling zealot roach)
         (if (and (> (u-tag a) 0) (u-alive? a))
             (values bane? adept? wmr? (add1 rcnt) airh? ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(hellion)
         (if (and (> (u-tag a) 0) (u-alive? a))
             (values bane? adept? #t (add1 rcnt) airh? ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(medivac widow-mine marine)
         (if (and (> (u-tag a) 0) (u-alive? a))
             (values bane? adept? #t rcnt airh? ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(adept)
         (if (and (> (u-tag a) 0) (u-alive? a))
             (values bane? #t wmr? rcnt airh? ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(adept-phase-shift)
         (if (u-alive? a)
             (values bane? #t wmr? rcnt airh? ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(raven oracle viking viking-fighter viking-assault)
         (if (and (> (u-tag a) 0) (u-alive? a))
             (values bane? adept? wmr? rcnt #t ths)
             (values bane? adept? wmr? rcnt airh? ths))]
        [(nexus command-center orbital-command planetary-fortress hatchery lair hive)
         (if (u-alive? a)
             (values bane? adept? wmr? rcnt airh? (cons (cons (u-x a) (u-y a)) ths))
             (values bane? adept? wmr? rcnt airh? ths))]
        [else (values bane? adept? wmr? rcnt airh? ths)])))
  (define-values (e-has-bane? e-has-wm? e-has-air-harass? e-has-adept? e-has-runby? rev-enemy-ths)
    (for/fold ([bane? : Boolean #f]
               [wm? : Boolean #f]
               [airh? : Boolean #f]
               [adept? : Boolean #f]
               [runby? : Boolean #f]
               [ths : (Listof Any) '()])
              ([e (in-list enemy-units)])
      (define ut (u-type e))
      (case ut
        [(baneling)
         (if (and (> (u-tag e) 0) (u-alive? e))
             (values #t wm? airh? adept? #t ths)
             (values bane? wm? airh? adept? runby? ths))]
        [(zergling hellion zealot reaper roach)
         (if (and (> (u-tag e) 0) (u-alive? e))
             (values bane? wm? airh? adept? #t ths)
             (values bane? wm? airh? adept? runby? ths))]
        [(adept)
         (if (u-alive? e)
             (values bane? wm? airh? #t (or runby? (> (u-tag e) 0)) ths)
             (values bane? wm? airh? adept? runby? ths))]
        [(adept-phase-shift)
         (if (u-alive? e)
             (values bane? wm? airh? #t runby? ths)
             (values bane? wm? airh? adept? runby? ths))]
        [(widow-mine widow-mine-burrowed)
         (if (and (> (u-tag e) 0) (u-alive? e))
             (values bane? #t airh? adept? runby? ths)
             (values bane? wm? airh? adept? runby? ths))]
        [(auto-turret)
         (if (u-alive? e)
             (values bane? wm? #t adept? runby? ths)
             (values bane? wm? airh? adept? runby? ths))]
        [(oracle-stasis-trap stasis-ward viking-assault)
         (if (and (> (u-tag e) 0) (u-alive? e))
             (values bane? wm? #t adept? runby? ths)
             (values bane? wm? airh? adept? runby? ths))]
        [(nexus command-center orbital-command planetary-fortress hatchery lair hive)
         (if (u-alive? e)
             (values bane? wm? airh? adept? runby? (cons e ths))
             (values bane? wm? airh? adept? runby? ths))]
        [else (values bane? wm? airh? adept? runby? ths)])))
  ;; Precompute shared enemy base targets and ally base points lazily from extracted THs.
  (define need-enemy-targets? (or a-has-adept? a-has-wm-runby? (>= a-runby-cnt 4) a-has-air-harass?))
  (define cached-enemy-targets : (Listof (Pair Float Float))
    (if need-enemy-targets?
        (infer-base-targets (reverse rev-enemy-ths) hx-f hy-f emx emy)
        '()))
  (define cached-ally-bases : (Listof (Pair Float Float))
    (if (pair? rev-ally-ths)
        (reverse rev-ally-ths)
        (list (cons hx-f hy-f))))
  (define all-dirs : (Listof harass-directive)
    (append
     (if e-has-bane?
         (plan-anti-baneling-split-and-target-fire ally-units enemy-units #:home-x hx #:home-y hy)
         '())
     (if a-has-bane?
         (plan-baneling-move-past-and-light-clump-detonate ally-units enemy-units #:home-x hx #:home-y hy)
         '())
     (if e-has-wm?
         (plan-counter-widow-mine-drop ally-units enemy-units #:home-x hx #:home-y hy)
         '())
     (if e-has-air-harass?
         (plan-counter-air-worker-harass ally-units enemy-units #:home-x hx #:home-y hy)
         '())
     (if e-has-adept?
         (plan-counter-adept-harass ally-units enemy-units #:home-x hx #:home-y hy #:base-points cached-ally-bases)
         '())
     (if e-has-runby?
         (plan-counter-runby-defense ally-units enemy-units #:home-x hx #:home-y hy #:base-points cached-ally-bases)
         '())
     (if (<= 1792 current-frame 3024)
         (counter-proxy-plan-directives
          (plan-counter-proxy-all-in our-race enemy-race current-frame ally-units enemy-units
                                     #:our-main-x hx #:our-main-y hy
                                     #:enemy-main-x emx #:enemy-main-y emy))
         '())
     (if a-has-adept?
         (plan-multi-base-adept-harass ally-units enemy-units #:home-x hx #:home-y hy #:enemy-main-x emx #:enemy-main-y emy #:enemy-targets cached-enemy-targets)
         '())
     (if a-has-wm-runby?
         (widow-mine-runby-plan-directives
          (plan-widow-mine-drop-and-runby ally-units enemy-units #:home-x hx #:home-y hy #:enemy-main-x emx #:enemy-main-y emy #:enemy-targets cached-enemy-targets))
         '())
     (if (>= a-runby-cnt 4)
         (plan-coordinated-runby-tactics ally-units enemy-units #:home-x hx #:home-y hy #:enemy-main-x emx #:enemy-main-y emy #:enemy-targets cached-enemy-targets)
         '())
     (if a-has-air-harass?
         (plan-air-worker-harass-tactics ally-units enemy-units #:home-x hx #:home-y hy #:enemy-main-x emx #:enemy-main-y emy #:enemy-targets cached-enemy-targets #:current-frame current-frame)
         '())))
  (map harass-directive->sexp all-dirs))
