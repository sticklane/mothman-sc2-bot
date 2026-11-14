#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/wall-and-block-tactics.rkt`
;; Wall Integrity, Unwalled Opponent Punish, Expansion/Gas Blocks & Smart Unblock:
;;   - Bayesian unwalled/gapped-wall/open-depot-door classification & flood plan
;;   - Own wall integrity defense (Supply Depot raise `558` + door `hold-position`)
;;   - Offensive natural expansion block + main gas-steal + `cancel-building` (`314`)
;;   - Counter expansion/gas block (1 patrol pre-stage at >= 180M + 3-4 combat /
;;     max 3 worker targeted clear)
;;   - Clean re-exports of `plan-burrowed-zergling-expansion-blocks` and
;;     `plan-clear-own-expansion-block-for-build` from `zerg-burrow-micro.rkt`
;; =============================================================================

(require racket/list
         racket/math
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-geometry.rkt"
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?)
         "../sc2-bayesian.rkt"
         "zerg-burrow-micro.rkt")

(module dyn-hash-ops racket/base
  (provide dyn-hash-ref
           dyn-hash-has-key?
           fast-units-have-any-type?
           fast-runby-within-15?)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (if (procedure? default)
            (hash-ref h k (lambda () default))
            (hash-ref h k default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k)))
  (define (fast-units-have-any-type? units syms)
    (for/or ([u (in-list units)])
      (and (hash? u) (not (not (memq (hash-ref u 'type 'unknown) syms))))))
  (define (fast-runby-within-15? enemy-units door-x door-y wall-slots)
    (define has-ws? (pair? wall-slots))
    (for/or ([e (in-list enemy-units)])
      (and (hash? e)
           (not (hash-ref e 'flying #f))
           (let* ([rx (hash-ref e 'x 9999.0)]
                  [ry (hash-ref e 'y 9999.0)]
                  [ex (if (real? rx) (exact->inexact rx) 9999.0)]
                  [ey (if (real? ry) (exact->inexact ry) 9999.0)]
                  [dx (- door-x ex)]
                  [dy (- door-y ey)])
             (or (and (<= (abs dx) 15.0)
                      (<= (abs dy) 15.0)
                      (<= (+ (* dx dx) (* dy dy)) 225.0))
                 (and has-ws?
                      (for/or ([sp (in-list wall-slots)])
                        (define sdx (- (car sp) ex))
                        (define sdy (- (cdr sp) ey))
                        (and (<= (abs sdx) 15.0)
                             (<= (abs sdy) 15.0)
                             (<= (+ (* sdx sdx) (* sdy sdy)) 225.0))))))))))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)]
  [fast-units-have-any-type? (-> (Listof Any) (Listof Symbol) Boolean)]
  [fast-runby-within-15? (-> (Listof Any) Flonum Flonum (Listof (Pairof Flonum Flonum)) Boolean)])

(provide
 (struct-out EnemyWallAssessment)
 (struct-out UnwalledPunishPlan)
 classify-enemy-wall-state
 plan-unwalled-opponent-punish
 plan-own-wall-integrity-defense
 plan-expansion-and-gas-blocks
 plan-counter-expansion-and-gas-blocks
 plan-burrowed-zergling-expansion-blocks
 plan-clear-own-expansion-block-for-build)

;; =============================================================================
;; Shared Constants & Helpers
;; =============================================================================

(struct EnemyWallAssessment
  ([wall-state : Symbol]
   [unwalled-posterior : Flonum]
   [wall-structure-count : Integer]
   [lowered-depot-count : Integer]
   [door-gap-units : Integer]
   [static-defense-count : Integer]
   [entry-x : Flonum]
   [entry-y : Flonum])
  #:transparent)

(struct UnwalledPunishPlan
  ([plan-kind : Symbol]
   [posterior : Flonum]
   [wall-state : Symbol]
   [commands : (Listof (Listof Any))]
   [entry-point : (Pairof Flonum Flonum)]
   [mineral-target : (Pairof Flonum Flonum)])
  #:transparent)

(: WALL-NON-WALLING-BLDGS (Listof Symbol))
(define WALL-NON-WALLING-BLDGS
  '(command-center orbital-command planetary-fortress nexus hatchery lair hive
    refinery refinery-rich assimilator assimilator-rich extractor extractor-rich
    creep-tumor creep-tumor-burrowed creep-tumor-queen sensor-tower))

(: WALL-STATIC-DEFENSE-SYMS (Listof Symbol))
(define WALL-STATIC-DEFENSE-SYMS
  '(bunker photon-cannon shield-battery spine-crawler spore-crawler planetary-fortress
    missile-turret))

(: WALL-TOWNHALL-SYMS (Listof Symbol))
(define WALL-TOWNHALL-SYMS
  '(hatchery lair hive nexus command-center orbital-command planetary-fortress))

(: WALL-GAS-BUILDING-SYMS (Listof Symbol))
(define WALL-GAS-BUILDING-SYMS
  '(refinery refinery-rich assimilator assimilator-rich extractor extractor-rich))

(: WALL-DOOR-UNIT-ORDER (Listof Symbol))
(define WALL-DOOR-UNIT-ORDER
  '(zealot adept immortal queen roach stalker marine marauder))

(: WORKER-SYMS (Listof Symbol))
(define WORKER-SYMS '(scv probe drone))

(: OFFENSIVE-BLOCK-BLDGS (Listof Symbol))
(define OFFENSIVE-BLOCK-BLDGS
  '(engineering-bay pylon hatchery bunker barracks refinery assimilator extractor))

(: COUNTER-PATROL-UNIT-SYMS (Listof Symbol))
(define COUNTER-PATROL-UNIT-SYMS
  '(zergling zealot adept marine reaper hellion stalker roach))

(: dyn-symbol (-> Any Symbol Symbol))
(define (dyn-symbol v fallback)
  (if (symbol? v) v fallback))

(: dyn-list (-> Any (Listof Any)))
(define (dyn-list v)
  (if (list? v) v '()))

(: parse-pt-pair (-> Any Flonum Flonum (Option (Pairof Flonum Flonum))))
(define (parse-pt-pair v fx fy)
  (cond
    [(hash? v)
     (define vx (dyn-hash-ref v 'x #f))
     (define vy (dyn-hash-ref v 'y #f))
     (and (real? vx) (real? vy)
          (cons (safe-real vx fx) (safe-real vy fy)))]
    [(and (list? v) (>= (length v) 2))
     (define a (car v))
     (define b (cadr v))
     (and (real? a) (real? b)
          (cons (safe-real a fx) (safe-real b fy)))]
    [(pair? v)
     (define a (car v))
     (define b (cdr v))
     (and (real? a) (real? b)
          (cons (safe-real a fx) (safe-real b fy)))]
    [else #f]))

(: clamp-playable (-> Flonum Flonum))
(define (clamp-playable v)
  (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD v)))

(: unit-hp-pct (-> Any Flonum))
(define (unit-hp-pct u)
  (define expl (dyn-hash-ref u 'hp-pct #f))
  (cond
    [(real? expl) (safe-real expl 1.0)]
    [else
     (define raw-hp (or (dyn-hash-ref u 'hp #f) (dyn-hash-ref u 'health #f) 1.0))
     (define hp (+ (safe-real raw-hp 1.0)
                   (safe-real (dyn-hash-ref u 'shield 0.0) 0.0)))
     (define raw-mhp (or (dyn-hash-ref u 'max-hp #f) (dyn-hash-ref u 'health-max #f) (max 1.0 hp)))
     (define mhp (+ (safe-real raw-mhp 1.0)
                    (safe-real (dyn-hash-ref u 'shield-max 0.0) 0.0)))
     (if (> mhp 0.0) (/ hp mhp) 1.0)]))

(: compute-default-ramp-xy (-> Flonum Flonum Flonum Flonum Flonum (Pairof Flonum Flonum)))
(define (compute-default-ramp-xy ox oy toward-x toward-y step-tiles)
  (define vx (- toward-x ox))
  (define vy (- toward-y oy))
  (define d (max 1.0 (dist2d 0.0 0.0 vx vy)))
  (cons (clamp-playable (+ ox (* step-tiles (/ vx d))))
        (clamp-playable (+ oy (* step-tiles (/ vy d))))))

(: units-have-any-type? (-> (Listof Any) (Listof Symbol) Boolean))
(define (units-have-any-type? units syms)
  (fast-units-have-any-type? units syms))

(: obs-has-unit-type? (-> Any Symbol (Listof Any) (Listof Symbol) Boolean))
(define (obs-has-unit-type? obs by-type-key units syms)
  (define by-type (dyn-hash-ref obs by-type-key #f))
  (if (and (hash? by-type) (> (hash-count by-type) 0))
      (for/or : Boolean ([s (in-list syms)])
        (define v (dyn-hash-ref by-type s #f))
        (or (pair? v) (and (real? v) (> v 0))))
      (units-have-any-type? units syms)))

;; =============================================================================
;; 1. Enemy Wall Assessment & Unwalled Opponent Punish (Bayesian-Driven)
;; =============================================================================

;; Evaluates enemy front ramp & natural choke structure density using
;; `compute-bayesian-unwalled-opponent-posterior`.
(: classify-enemy-wall-state (-> Any EnemyWallAssessment))
(define (classify-enemy-wall-state obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define frame (safe-exact-int (dyn-hash-ref sanitized-obs 'frame 0) 0))
  (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
  (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
  (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
  (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
  (define enemy-nat-x
    (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-x (- enemy-x 16.0)) (- enemy-x 16.0)))
  (define enemy-nat-y
    (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-y (- enemy-y 16.0)) (- enemy-y 16.0)))
  (define default-ramp (compute-default-ramp-xy enemy-x enemy-y base-x base-y 8.0))
  (define ramp-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-ramp-x (car default-ramp)) (car default-ramp)))
  (define ramp-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-ramp-y (cdr default-ramp)) (cdr default-ramp)))
  (define default-choke (compute-default-ramp-xy enemy-nat-x enemy-nat-y base-x base-y 9.0))
  (define choke-x
    (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-choke-x (car default-choke)) (car default-choke)))
  (define choke-y
    (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-choke-y (cdr default-choke)) (cdr default-choke)))
  (define enemy-race (dyn-symbol (dyn-hash-ref sanitized-obs 'enemy-race 'Unknown) 'Unknown))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))
  (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))

  ;; Filter structures guarding either enemy main ramp or enemy natural choke
  (define ramp-bldgs : (Listof Any)
    (if (null? enemy-bldgs)
        '()
        (filter (lambda ([b : Any])
                  (and (hash? b)
                       (not (dyn-hash-ref b 'flying #f))
                       (let ([bt (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)]
                             [bx (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)]
                             [by (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0)])
                         (and (not (memq bt WALL-NON-WALLING-BLDGS))
                              (<= (dist2d ramp-x ramp-y bx by) 7.5)))))
                enemy-bldgs)))
  (define choke-bldgs : (Listof Any)
    (if (null? enemy-bldgs)
        '()
        (filter (lambda ([b : Any])
                  (and (hash? b)
                       (not (dyn-hash-ref b 'flying #f))
                       (let ([bt (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)]
                             [bx (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)]
                             [by (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0)])
                         (and (not (memq bt WALL-NON-WALLING-BLDGS))
                              (<= (dist2d choke-x choke-y bx by) 8.0)))))
                enemy-bldgs)))
  (define enemy-has-nat?
    (for/or : Boolean ([b (in-list enemy-bldgs)])
      (and (hash? b)
           (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown) WALL-TOWNHALL-SYMS)))
           (<= (dist2d enemy-nat-x enemy-nat-y
                       (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                       (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
               6.0))))
  (define focus-bldgs : (Listof Any)
    (if (and enemy-has-nat? (null? ramp-bldgs)) choke-bldgs ramp-bldgs))
  (define-values (entry-x entry-y)
    (if (and enemy-has-nat? (null? ramp-bldgs))
        (values choke-x choke-y)
        (values ramp-x ramp-y)))

  (define wall-cnt (length focus-bldgs))
  (define lowered-cnt : Integer
    (for/fold ([cnt : Integer 0]) ([b (in-list enemy-bldgs)])
      (if (and (hash? b)
               (or (eq? (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown) 'supply-depot-lowered)
                   (= (safe-exact-int (dyn-hash-ref b 'unit-type 0) 0) 47))
               (<= (min (dist2d ramp-x ramp-y
                                (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                                (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                        (dist2d choke-x choke-y
                                (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                                (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0)))
                   10.0))
          (add1 cnt)
          cnt)))
  (define static-cnt : Integer
    (for/fold ([cnt : Integer 0]) ([b (in-list enemy-bldgs)])
      (if (and (hash? b)
               (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown) WALL-STATIC-DEFENSE-SYMS)
               (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0) 0.5)
               (<= (dist2d entry-x entry-y
                           (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                           (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                   11.5))
          (add1 cnt)
          cnt)))
  (define explicit-gap (dyn-hash-ref sanitized-obs 'enemy-door-gap-units #f))
  (define enemy-door-plugged?
    (and (>= wall-cnt 2)
         (= lowered-cnt 0)
         (not (exact-integer? explicit-gap))
         (for/or : Boolean ([e (in-list enemy-units)])
           (and (hash? e)
                (not (dyn-hash-ref e 'flying #f))
                (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown) WALL-DOOR-UNIT-ORDER)
                (let ([dx (- (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0) entry-x)]
                      [dy (- (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0) entry-y)])
                  (and (<= (abs dx) 3.5)
                       (<= (abs dy) 3.5)
                       (<= (+ (* dx dx) (* dy dy)) 12.25)))))))
  (define gap-cnt : Integer
    (cond
      [(exact-integer? explicit-gap) (max 0 explicit-gap)]
      [(> lowered-cnt 0) 1]
      [(= wall-cnt 1) 1]
      [(and (>= wall-cnt 2) (not enemy-door-plugged?))
       ;; Check if any pair of ramp structures leaves an open gap > 4.6 tiles
       (define max-pair-dist : Flonum
         (for/fold ([md : Flonum 0.0]) ([a (in-list focus-bldgs)])
           (for/fold ([md2 : Flonum md]) ([b (in-list focus-bldgs)])
             (max md2
                  (dist2d (safe-real (dyn-hash-ref a 'x entry-x) entry-x)
                          (safe-real (dyn-hash-ref a 'y entry-y) entry-y)
                          (safe-real (dyn-hash-ref b 'x entry-x) entry-x)
                          (safe-real (dyn-hash-ref b 'y entry-y) entry-y))))))
       (if (> max-pair-dist 4.8) 1 0)]
      [else 0]))
  (define scouted? : Boolean
    (or (not (not (dyn-hash-ref sanitized-obs 'scouted-enemy-choke? #f)))
        (not (not (dyn-hash-ref sanitized-obs 'scouted-enemy-main? #f)))
        (not (null? enemy-bldgs))
        (for/or : Boolean ([u (in-list ally-units)])
          (and (hash? u)
               (let* ([ux (safe-real (dyn-hash-ref u 'x -999.0) -999.0)]
                      [uy (safe-real (dyn-hash-ref u 'y -999.0) -999.0)]
                      [drx (- ux ramp-x)]
                      [dry (- uy ramp-y)]
                      [dcx (- ux choke-x)]
                      [dcy (- uy choke-y)])
                 (or (and (<= (abs drx) 16.0)
                          (<= (abs dry) 16.0)
                          (<= (+ (* drx drx) (* dry dry)) 256.0))
                     (and (<= (abs dcx) 16.0)
                          (<= (abs dcy) 16.0)
                          (<= (+ (* dcx dcx) (* dcy dcy)) 256.0))))))))

  (define post : Flonum
    (compute-bayesian-unwalled-opponent-posterior
     #:prior (if (memq enemy-race '(Zerg zerg ZERG)) 0.45 0.28)
     #:wall-structure-count wall-cnt
     #:lowered-depot-count lowered-cnt
     #:door-gap-units gap-cnt
     #:scouted-choke? scouted?
     #:enemy-race enemy-race
     #:frame frame
     #:static-defense-count static-cnt))

  (define wstate : Symbol
    (cond
      [(> lowered-cnt 0) 'open-depot-door]
      [(and scouted? (= wall-cnt 0) (>= frame 1568)) 'no-wall]
      [(and scouted? (or (= wall-cnt 1) (> gap-cnt 0))) 'gapped-wall]
      [(>= wall-cnt 2) 'walled]
      [(not scouted?) 'unknown-unscouted]
      [else 'no-wall]))

  (EnemyWallAssessment wstate post wall-cnt lowered-cnt gap-cnt static-cnt entry-x entry-y))

;; Inspects enemy ramp/choke structure density; when `'no-wall`, `'gapped-wall`,
;; or `'open-depot-door` (`frame >= 1568` or immediate depot opening) and Bayesian
;; posterior supports flood punishment, returns race-specific flood commands aimed
;; straight through the enemy ramp/choke into the enemy mineral line.
(: plan-unwalled-opponent-punish (-> Any UnwalledPunishPlan))
(define (plan-unwalled-opponent-punish obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define assess (classify-enemy-wall-state sanitized-obs))
  (define frame (safe-exact-int (dyn-hash-ref sanitized-obs 'frame 0) 0))
  (define wstate (EnemyWallAssessment-wall-state assess))
  (define post (EnemyWallAssessment-unwalled-posterior assess))
  (define entry-x (EnemyWallAssessment-entry-x assess))
  (define entry-y (EnemyWallAssessment-entry-y assess))
  (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
  (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
  ;; Enemy mineral line defaults 4.5 tiles behind enemy main TH away from entry ramp
  (define default-ml
    (let* ([dx (- enemy-x entry-x)]
           [dy (- enemy-y entry-y)]
           [d (max 1.0 (dist2d 0.0 0.0 dx dy))])
      (cons (clamp-playable (+ enemy-x (* 4.5 (/ dx d))))
            (clamp-playable (+ enemy-y (* 4.5 (/ dy d)))))))
  (define ml-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-mineral-x (car default-ml)) (car default-ml)))
  (define ml-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-mineral-y (cdr default-ml)) (cdr default-ml)))
  (define open-window?
    (and (not (not (memq wstate '(no-wall gapped-wall open-depot-door))))
         (or (eq? wstate 'open-depot-door)
             (and (>= frame 1568) (>= post 0.50)))))
  (define ally-units
    (if open-window?
        (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '()))
        '()))
  (define has-punish-units? : Boolean
    (and open-window?
         (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units
                             '(zergling adept hellion hellion-tank reaper))))
  (cond
    [(not has-punish-units?)
     (UnwalledPunishPlan 'none post wstate '() (cons entry-x entry-y) (cons ml-x ml-y))]
    [else
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define race (dyn-symbol (dyn-hash-ref sanitized-obs 'our-race
                                            (dyn-hash-ref sanitized-obs 'race 'Zerg))
                              'Zerg))
     (define-values (rev-lings rev-adepts rev-hr)
       (for/fold ([ls : (Listof Any) '()]
                  [as : (Listof Any) '()]
                  [hs : (Listof Any) '()])
                 ([u (in-list ally-units)]
                  #:when (hash? u))
         (define ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown))
         (cond
           [(eq? ut 'zergling) (values (cons u ls) as hs)]
           [(eq? ut 'adept) (values ls (cons u as) hs)]
           [(memq ut '(hellion hellion-tank reaper)) (values ls as (cons u hs))]
           [else (values ls as hs)])))
     (define zerglings (reverse rev-lings))
     (define adepts (reverse rev-adepts))
     (define hellions-reapers (reverse rev-hr))

     (define-values (plan-kind pool)
       (cond
         [(or (>= (length zerglings) 4)
              (and (memq race '(Zerg zerg ZERG)) (not (null? zerglings))))
          (values 'zergling-flood-unwalled zerglings)]
         [(or (>= (length adepts) 2)
              (and (memq race '(Protoss protoss PROTOSS)) (not (null? adepts))))
          (values 'adept-shade-flood-unwalled adepts)]
         [(or (>= (length hellions-reapers) 2)
              (and (memq race '(Terran terran TERRAN)) (not (null? hellions-reapers))))
          (values 'hellion-reaper-runby-unwalled hellions-reapers)]
         [(>= (length adepts) 1) (values 'adept-shade-flood-unwalled adepts)]
         [(>= (length hellions-reapers) 1) (values 'hellion-reaper-runby-unwalled hellions-reapers)]
         [(>= (length zerglings) 2) (values 'zergling-flood-unwalled zerglings)]
         [else (values 'none '())]))

     (define commands : (Listof (Listof Any))
       (if (or (eq? plan-kind 'none) (null? pool))
           '()
           (reverse
            (for/fold ([acc : (Listof (Listof Any)) '()]) ([u (in-list pool)])
              (define uid (dyn-hash-ref u 'id 0))
              (define ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown))
              (define ux (safe-real (dyn-hash-ref u 'x base-x) base-x))
              (define uy (safe-real (dyn-hash-ref u 'y base-y) base-y))
              (define in-ml? (<= (dist2d ux uy ml-x ml-y) 8.5))
              (define cmd : (Listof Any)
                (cond
                  [(and (eq? ut 'adept) (not in-ml?)
                        (dyn-hash-ref u 'shade-ready? #t))
                   (list 'cast-spell uid 'adept-phase-shift ml-x ml-y)]
                  [in-ml? (list 'attack-pos uid ml-x ml-y)]
                  [else (list 'move uid ml-x ml-y)]))
              (cons cmd acc)))))

     (UnwalledPunishPlan
      (if (null? commands) 'none plan-kind)
      post
      wstate
      commands
      (cons entry-x entry-y)
      (cons ml-x ml-y))]))

;; =============================================================================
;; 2. Own Wall Integrity Defense (Depot Raise `558` + Door Hold-Position `18`)
;; =============================================================================

;; Monitors our own main/natural wall slots & door coordinate; when enemy
;; runby units approach within 15.0 tiles, emits `morph-supply-depot-raise` (`558`)
;; on lowered depots or parks 1 `zealot`/`adept`/`immortal`/`queen`/`roach` in the
;; door slot on `hold-position` (`18`).
(: plan-own-wall-integrity-defense (-> Any (Listof (Listof Any))))
(define (plan-own-wall-integrity-defense obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
  (cond
    [(null? enemy-units) '()]
    [else
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define nat-x (safe-real (dyn-hash-ref sanitized-obs 'natural-x (+ base-x 16.0)) (+ base-x 16.0)))
     (define nat-y (safe-real (dyn-hash-ref sanitized-obs 'natural-y (+ base-y 16.0)) (+ base-y 16.0)))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
     (define default-door (compute-default-ramp-xy nat-x nat-y enemy-x enemy-y 8.0))
     (define explicit-door (parse-pt-pair (dyn-hash-ref sanitized-obs 'door-pos #f) (car default-door) (cdr default-door)))
     (define door-x
       (cond
         [explicit-door (car explicit-door)]
         [(dyn-hash-has-key? sanitized-obs 'wall-door-x)
          (safe-real (dyn-hash-ref sanitized-obs 'wall-door-x (car default-door)) (car default-door))]
         [else (car default-door)]))
     (define door-y
       (cond
         [explicit-door (cdr explicit-door)]
         [(dyn-hash-has-key? sanitized-obs 'wall-door-y)
          (safe-real (dyn-hash-ref sanitized-obs 'wall-door-y (cdr default-door)) (cdr default-door))]
         [else (cdr default-door)]))

     (define raw-ws (dyn-list (dyn-hash-ref sanitized-obs 'wall-slots '())))
     (define raw-ows (dyn-list (dyn-hash-ref sanitized-obs 'own-wall-slots '())))
     (define wall-slots : (Listof (Pairof Flonum Flonum))
       (if (and (null? raw-ws) (null? raw-ows))
           '()
           (append
            (filter-map (lambda ([p : Any]) (parse-pt-pair p door-x door-y)) raw-ws)
            (filter-map (lambda ([p : Any]) (parse-pt-pair p door-x door-y)) raw-ows))))

     ;; Threat within 15.0 tiles of door or wall slots (bounding-box pre-check)
     (define runby-threat?
       (fast-runby-within-15? enemy-units door-x door-y wall-slots))

     (cond
       [(not runby-threat?) '()]
       [else
        (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
        (define ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())))
        (define actions : (Listof (Listof Any)) '())
        (define used-ids : (HashTable Any Boolean) (make-hash))
        (: emit! (-> (Listof Any) Void))
        (define (emit! a) (set! actions (cons a actions)))

        (when runby-threat?
    ;; 1. Terran: raise any `supply-depot-lowered` (`558`) in our wall
    (define lowered-depots : (Listof Any)
      (filter (lambda ([b : Any])
                (and (hash? b)
                     (or (eq? (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown) 'supply-depot-lowered)
                         (= (safe-exact-int (dyn-hash-ref b 'unit-type 0) 0) 47))
                     (let ([bx (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)]
                           [by (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0)])
                       (or (<= (dist2d door-x door-y bx by) 8.5)
                           (ormap (lambda ([sp : (Pairof Flonum Flonum)])
                                    (<= (dist2d (car sp) (cdr sp) bx by) 2.5))
                                  wall-slots)))))
              ally-bldgs))
    (for ([dep (in-list lowered-depots)])
      (define did (dyn-hash-ref dep 'id 0))
      (define dx (safe-real (dyn-hash-ref dep 'x door-x) door-x))
      (define dy (safe-real (dyn-hash-ref dep 'y door-y) door-y))
      ;; Move any friendly unit standing directly on the lowered depot off toward home
      (for ([u (in-list ally-units)]
            #:when (and (hash? u)
                        (not (dyn-hash-ref u 'flying #f))
                        (<= (dist2d dx dy
                                    (safe-real (dyn-hash-ref u 'x 9999.0) 9999.0)
                                    (safe-real (dyn-hash-ref u 'y 9999.0) 9999.0))
                            1.3)))
        (define uid (dyn-hash-ref u 'id 0))
        (hash-set! used-ids uid #t)
        (emit! (list 'move uid base-x base-y)))
      (hash-set! used-ids did #t)
      (emit! (list 'cast-spell did 'morph-supply-depot-raise)))

    ;; 2. Door slot hold-position unit (`1` zealot/adept/immortal/queen/roach) when no depot covered door
    (define door-covered-by-depot?
      (for/or : Boolean ([b (in-list ally-bldgs)])
        (and (hash? b)
             (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                   '(supply-depot supply-depot-lowered))
             (<= (dist2d door-x door-y
                         (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                         (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                 1.8))))
    (unless door-covered-by-depot?
      (define door-candidates : (Listof Any)
        (filter (lambda ([u : Any])
                  (and (hash? u)
                       (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f))
                       (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                       WALL-DOOR-UNIT-ORDER)))
                       (not (dyn-hash-ref u 'is-hallucination #f))))
                ally-units))
      (unless (null? door-candidates)
        (define best-plug
          (argmin (lambda ([u : Any])
                    (define ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown))
                    (define rank : Flonum
                      (cond [(eq? ut 'zealot) 0.0]
                            [(eq? ut 'adept) 2.0]
                            [(eq? ut 'immortal) 4.0]
                            [(eq? ut 'queen) 4.0]
                            [(eq? ut 'roach) 5.0]
                            [else 12.0]))
                    (+ rank (dist2d door-x door-y
                                    (safe-real (dyn-hash-ref u 'x base-x) base-x)
                                    (safe-real (dyn-hash-ref u 'y base-y) base-y))))
                  door-candidates))
        (define pid (dyn-hash-ref best-plug 'id 0))
        (define px (safe-real (dyn-hash-ref best-plug 'x base-x) base-x))
        (define py (safe-real (dyn-hash-ref best-plug 'y base-y) base-y))
        (hash-set! used-ids pid #t)
        (if (<= (dist2d px py door-x door-y) 1.2)
            (emit! (list 'hold-position pid))
            (emit! (list 'move pid door-x door-y))))))

        (reverse actions)])]))

;; =============================================================================
;; 3. Offensive Expansion Blocks, Gas Steals & Smart Cancel (`314`)
;; =============================================================================

;; Dispatches offensive natural expansion blocks (`engineering-bay`/`pylon`/`hatchery`,
;; frame 850..2100) and enemy main gas-steal (`refinery`/`assimilator`/`extractor` at
;; `minerals >= 150`), plus `(cancel-building bid)` (`314`) whenever an in-progress
;; block structure drops to `hp-pct <= 0.18` or reaches `build-progress >= 0.90`.
(: plan-expansion-and-gas-blocks (-> Any (Listof (Listof Any))))
(define (plan-expansion-and-gas-blocks obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define frame (safe-exact-int (dyn-hash-ref sanitized-obs 'frame 0) 0))
  (define mins (safe-real (dyn-hash-ref sanitized-obs 'minerals 0.0) 0.0))
  (define race (dyn-symbol (dyn-hash-ref sanitized-obs 'our-race
                                         (dyn-hash-ref sanitized-obs 'race 'Terran))
                           'Terran))
  (define ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())))
  (define geysers (dyn-list (dyn-hash-ref sanitized-obs 'enemy-geysers
                                          (dyn-hash-ref sanitized-obs 'vespene-geysers '()))))
  (define-values (block-sym block-cost)
    (cond
      [(memq race '(Protoss protoss PROTOSS)) (values 'pylon 100.0)]
      [(memq race '(Zerg zerg ZERG)) (values 'hatchery 300.0)]
      [else (values 'engineering-bay 125.0)]))
  (define has-incomplete-block-bldg? : Boolean
    (for/or : Boolean ([b (in-list ally-bldgs)])
      (and (hash? b)
           (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                           OFFENSIVE-BLOCK-BLDGS)))
           (< (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
              SC2-BUILD-COMPLETE-PROGRESS))))
  (define in-nat-window? : Boolean
    (and (>= frame 850) (<= frame 2100) (>= mins block-cost)))
  (define in-gas-window? : Boolean
    (and (>= mins 150.0) (<= frame 2800) (pair? geysers)))

  (cond
    [(and (not has-incomplete-block-bldg?)
          (not in-nat-window?)
          (not in-gas-window?))
     '()]
    [else
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
     (define enemy-nat-x
       (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-x (- enemy-x 16.0)) (- enemy-x 16.0)))
     (define enemy-nat-y
       (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-y (- enemy-y 16.0)) (- enemy-y 16.0)))
     (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
     (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))

     (define actions : (Listof (Listof Any)) '())
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     ;; 1. Auto-cancel (`314`) dying (`hp-pct <= 0.18`) or nearly completed (`build-progress >= 0.90`)
     ;;    offensive block / gas-steal buildings near enemy base/natural
     (when has-incomplete-block-bldg?
       (for ([b (in-list ally-bldgs)]
             #:when (hash? b))
         (define bt (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown))
         (define prog (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0))
         (define hp-pct (unit-hp-pct b))
         (define bx (safe-real (dyn-hash-ref b 'x base-x) base-x))
         (define by (safe-real (dyn-hash-ref b 'y base-y) base-y))
         (define bid (dyn-hash-ref b 'id 0))
         (define is-offensive-block?
           (and (not (not (memq bt OFFENSIVE-BLOCK-BLDGS)))
                (or (not (not (dyn-hash-ref b 'block-structure? #f)))
                    (<= (dist2d bx by enemy-x enemy-y) 15.0)
                    (<= (dist2d bx by enemy-nat-x enemy-nat-y) 10.0))))
         (when (and is-offensive-block?
                    (not (dyn-hash-ref b 'keep-finish? #f))
                    (< prog SC2-BUILD-COMPLETE-PROGRESS)
                    (exact-integer? bid)
                    (> bid 0)
                    (or (<= hp-pct 0.18) (>= prog 0.90)))
           (emit! (list 'cancel-building bid)))))

     ;; 2. Natural expansion block (`frame 850..2100`) & 3. Main gas-steal (`<= 2800`)
     (define nat-already-taken-or-blocked? : Boolean
       (or (not in-nat-window?)
           (for/or : Boolean ([b (in-list ally-bldgs)])
             (and (hash? b)
                  (<= (dist2d enemy-nat-x enemy-nat-y
                              (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                              (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                      5.5)))
           (for/or : Boolean ([b (in-list enemy-bldgs)])
             (and (hash? b)
                  (<= (dist2d enemy-nat-x enemy-nat-y
                              (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                              (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                      5.5)))))
     (define own-steal-exists? : Boolean
       (or (not in-gas-window?)
           (for/or : Boolean ([b (in-list ally-bldgs)])
             (and (hash? b)
                  (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown) WALL-GAS-BUILDING-SYMS)))
                  (<= (dist2d enemy-x enemy-y
                              (safe-real (dyn-hash-ref b 'x base-x) base-x)
                              (safe-real (dyn-hash-ref b 'y base-y) base-y))
                      14.0)))))
     (define need-workers? : Boolean
       (and (or (and in-nat-window? (not nat-already-taken-or-blocked?))
                (and in-gas-window? (not own-steal-exists?)))
            (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units WORKER-SYMS)))
     (define workers : (Listof Any)
       (if need-workers?
           (filter (lambda ([u : Any])
                     (and (hash? u)
                          (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) WORKER-SYMS)))
                          (let* ([ux (safe-real (dyn-hash-ref u 'x base-x) base-x)]
                                 [uy (safe-real (dyn-hash-ref u 'y base-y) base-y)]
                                 [dxn (- ux enemy-nat-x)]
                                 [dyn (- uy enemy-nat-y)]
                                 [dxe (- ux enemy-x)]
                                 [dye (- uy enemy-y)])
                            (or (and (<= (abs dxn) 28.0)
                                     (<= (abs dyn) 28.0)
                                     (<= (+ (* dxn dxn) (* dyn dyn)) 784.0))
                                (and (<= (abs dxe) 28.0)
                                     (<= (abs dye) 28.0)
                                     (<= (+ (* dxe dxe) (* dye dye)) 784.0))))))
                   ally-units)
           '()))

     (define block-dispatched? : Boolean #f)
     (when (and in-nat-window?
                (not nat-already-taken-or-blocked?)
                (not (null? workers)))
       (set! block-dispatched? #t)
       (emit! (list 'build block-sym enemy-nat-x enemy-nat-y)))

     ;; 3. Enemy main gas-steal (`refinery`/`assimilator`/`extractor` at `>= 150M`)
     (define gas-sym : Symbol
       (cond
         [(memq race '(Protoss protoss PROTOSS)) 'assimilator]
         [(memq race '(Zerg zerg ZERG)) 'extractor]
         [else 'refinery]))
     (when (and (not block-dispatched?)
                in-gas-window?
                (not own-steal-exists?)
                (not (null? workers)))
       (define open-geyser : (Option (Pairof Flonum Flonum))
         (findf (lambda ([gp : (Pairof Flonum Flonum)])
                  (define gx (car gp))
                  (define gy (cdr gp))
                  (and (<= (dist2d gx gy enemy-x enemy-y) 13.0)
                       (not (for/or : Boolean ([b (in-list ally-bldgs)])
                              (and (hash? b)
                                   (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                                                   WALL-GAS-BUILDING-SYMS)))
                                   (<= (dist2d gx gy
                                               (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                                               (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                                       2.2))))
                       (not (for/or : Boolean ([b (in-list enemy-bldgs)])
                              (and (hash? b)
                                   (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                                                   WALL-GAS-BUILDING-SYMS)))
                                   (<= (dist2d gx gy
                                               (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                                               (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))
                                       2.2))))))
                (filter-map (lambda ([g : Any]) (parse-pt-pair g enemy-x enemy-y)) geysers)))
       (when open-geyser
         (emit! (list 'build gas-sym (car open-geyser) (cdr open-geyser)))))

     (reverse actions)]))

;; =============================================================================
;; 4. Counter Expansion & Gas Blocks
;; =============================================================================

;; Pre-stages 1 patrol unit on our unbuilt natural pad at `minerals >= 180`
;; (`patrol-block-expansion`) and assigns 3-4 combat units (or strictly max 3
;; workers) to clear enemy natural/3rd blocks or main gas-steals without pulling
;; the entire mineral line.
(: plan-counter-expansion-and-gas-blocks (-> Any (Listof (Listof Any))))
(define (plan-counter-expansion-and-gas-blocks obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define mins (safe-real (dyn-hash-ref sanitized-obs 'minerals 0.0) 0.0))
  (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
  (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
  (define nat-x (safe-real (dyn-hash-ref sanitized-obs 'natural-x (+ base-x 16.0)) (+ base-x 16.0)))
  (define nat-y (safe-real (dyn-hash-ref sanitized-obs 'natural-y (+ base-y 16.0)) (+ base-y 16.0)))
  (define third-x (safe-real (dyn-hash-ref sanitized-obs 'third-x (+ base-x 32.0)) (+ base-x 32.0)))
  (define third-y (safe-real (dyn-hash-ref sanitized-obs 'third-y (+ base-y 8.0)) (+ base-y 8.0)))
  (define ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())))
  (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))

  ;; 1. Detect enemy blocking structures on natural/3rd pads or gas steals in our main/nat
  (define enemy-blockers : (Listof Any)
    (if (null? enemy-bldgs)
        '()
        (filter (lambda ([b : Any])
                  (and (hash? b)
                       (let ([bt (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)]
                             [bx (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)]
                             [by (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0)])
                         (or (<= (dist2d bx by nat-x nat-y) 6.5)
                             (<= (dist2d bx by third-x third-y) 6.5)
                             (and (not (not (memq bt WALL-GAS-BUILDING-SYMS)))
                                  (or (<= (dist2d bx by base-x base-y) 13.0)
                                      (<= (dist2d bx by nat-x nat-y) 13.0)))))))
                enemy-bldgs)))

  (define own-nat-built? : Boolean
    (and (null? enemy-blockers)
         (>= mins 180.0)
         (for/or : Boolean ([b (in-list ally-bldgs)])
           (and (hash? b)
                (not (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown) WALL-TOWNHALL-SYMS)))
                (<= (dist2d nat-x nat-y
                            (safe-real (dyn-hash-ref b 'x -999.0) -999.0)
                            (safe-real (dyn-hash-ref b 'y -999.0) -999.0))
                    5.5)))))

  (cond
    [(and (null? enemy-blockers)
          (or (< mins 180.0) own-nat-built?))
     '()]
    [else
     (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
     (define actions : (Listof (Listof Any)) '())
     (define used-ids : (HashTable Any Boolean) (make-hash))
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     (when (not (null? enemy-blockers))
       (define combat-pool : (Listof Any)
         (filter (lambda ([u : Any])
                   (and (hash? u)
                        (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                          (and (not (memq ut '(scv probe drone drone-burrowed overlord larva egg mule)))
                               (not (memq ut SC2-MOBILE-DETECTOR-SYMS))
                               (not (sc2-non-combat-or-summon-sym? ut))
                               (not (dyn-hash-ref u 'is-hallucination #f))))))
                 ally-units))
       (define worker-pool-cache : (Option (Listof Any)) #f)
       (define (get-worker-pool) : (Listof Any)
         (or worker-pool-cache
             (let ([wp (filter (lambda ([u : Any])
                                 (and (hash? u)
                                      (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) WORKER-SYMS)))))
                               ally-units)])
               (set! worker-pool-cache wp)
               wp)))
       (for ([blk (in-list enemy-blockers)])
         (define bid (dyn-hash-ref blk 'id 0))
         (define bx (safe-real (dyn-hash-ref blk 'x nat-x) nat-x))
         (define by (safe-real (dyn-hash-ref blk 'y nat-y) nat-y))
         (define avail-combat
           (filter (lambda ([u : Any]) (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f)))
                   combat-pool))
         (define sorted-combat
           (sort avail-combat
                 (lambda ([a : Any] [b : Any])
                   (< (dist2d bx by (safe-real (dyn-hash-ref a 'x base-x) base-x)
                              (safe-real (dyn-hash-ref a 'y base-y) base-y))
                      (dist2d bx by (safe-real (dyn-hash-ref b 'x base-x) base-x)
                              (safe-real (dyn-hash-ref b 'y base-y) base-y))))))
         (define clear-squad : (Listof Any)
           (if (>= (length sorted-combat) 1)
               (take sorted-combat (min 4 (length sorted-combat)))
               (let ([avail-w (filter (lambda ([w : Any])
                                        (not (hash-ref used-ids (dyn-hash-ref w 'id 0) #f)))
                                      (get-worker-pool))])
                 ;; Strictly at most 3 workers so mineral line never gets all-pulled
                 (take (sort avail-w
                             (lambda ([a : Any] [b : Any])
                               (< (dist2d bx by (safe-real (dyn-hash-ref a 'x base-x) base-x)
                                          (safe-real (dyn-hash-ref a 'y base-y) base-y))
                                  (dist2d bx by (safe-real (dyn-hash-ref b 'x base-x) base-x)
                                          (safe-real (dyn-hash-ref b 'y base-y) base-y)))))
                       (min 3 (length avail-w))))))
         (for ([u (in-list clear-squad)])
           (define uid (dyn-hash-ref u 'id 0))
           (hash-set! used-ids uid #t)
           (if (and (exact-integer? bid) (> bid 0))
               (emit! (list 'attack uid bid))
               (emit! (list 'attack-pos uid bx by))))))

     ;; 2. Pre-stage 1 patrol unit on unbuilt natural pad at `minerals >= 180`
     (when (and (null? enemy-blockers)
                (>= mins 180.0))
       (define expanding-near-nat?
         (and (>= mins 225.0)
              (for/or : Boolean ([u (in-list ally-units)])
                (and (hash? u)
                     (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) WORKER-SYMS)
                     (let ([dx (- nat-x (safe-real (dyn-hash-ref u 'x -999.0) -999.0))]
                           [dy (- nat-y (safe-real (dyn-hash-ref u 'y -999.0) -999.0))])
                       (and (<= (abs dx) 10.0)
                            (<= (abs dy) 10.0)
                            (<= (+ (* dx dx) (* dy dy)) 100.0)))))))
       (define already-patrolling-nat?
         (and (not expanding-near-nat?)
              (for/or : Boolean ([u (in-list ally-units)])
                (and (hash? u)
                     (let ([dx (- nat-x (safe-real (dyn-hash-ref u 'x -999.0) -999.0))]
                           [dy (- nat-y (safe-real (dyn-hash-ref u 'y -999.0) -999.0))])
                       (and (<= (abs dx) 3.5)
                            (<= (abs dy) 3.5)
                            (<= (+ (* dx dx) (* dy dy)) 12.25)))
                     (or (= (safe-exact-int (dyn-hash-ref u 'order-ability-id 0) 0) 17)
                         (eq? (dyn-symbol (dyn-hash-ref u 'order 'none) 'none) 'patrol))))))
       (when (and (not expanding-near-nat?)
                  (not already-patrolling-nat?))
         (define patrol-pool : (Listof Any)
           (if (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units COUNTER-PATROL-UNIT-SYMS)
               (filter (lambda ([u : Any])
                         (and (hash? u)
                              (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f))
                              (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                              COUNTER-PATROL-UNIT-SYMS)))))
                       ally-units)
               '()))
         (define fallback-worker-pool : (Listof Any)
           (if (and (null? patrol-pool) (>= mins 210.0))
               (filter (lambda ([u : Any])
                         (and (hash? u)
                              (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f))
                              (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) WORKER-SYMS)))))
                       ally-units)
               '()))
         (define chosen-pool (if (not (null? patrol-pool)) patrol-pool fallback-worker-pool))
         (unless (null? chosen-pool)
           (define best-patrol
             (argmin (lambda ([u : Any])
                       (dist2d nat-x nat-y
                               (safe-real (dyn-hash-ref u 'x base-x) base-x)
                               (safe-real (dyn-hash-ref u 'y base-y) base-y)))
                     chosen-pool))
           (define pid (dyn-hash-ref best-patrol 'id 0))
           (hash-set! used-ids pid #t)
           (emit! (list 'patrol-block-expansion pid nat-x nat-y)))))

     (reverse actions)]))
