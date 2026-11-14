#lang typed/racket/base

;; =============================================================================
;; `lib/sc2-types.rkt`
;; Layer 0 Typed Domain Data Model & Total Helper Primitives.
;;
;; Single source of truth for core StarCraft II domain types, transparent
;; structs shared across macro/prediction/tactics/logging layers, and total
;; numeric/geometry/JSON/hash coercions.
;; =============================================================================

(require racket/math
         racket/string)

(provide
 KnownRace
 Race
 MatchupSym
 PostureSym
 BuildOrderActionKind
 TileCoord
 UnitMap
 SupplyCurvePoint
 (struct-out point2d)
 (struct-out aabb2d)
 (struct-out pro-bo-goal)
 pro-bo-goal-target
 (struct-out pro-bo-eval-result)
 (struct-out build-order-spec)
 (struct-out build-order-tree-node)
 (struct-out bayesian-strategic-priors)
 known-race?
 matchup-sym?
 ->float
 clamp-real
 clamp-prob
 normalize-race
 normalize-known-race
 resolve-matchup-symbol
 finite-real?
 safe-finite-real
 safe-real
 safe-exact-int
 safe-int
 safe-nonneg-int
 round1
 round2
 jnull->false
 dist2d
 safe-dist2d
 safe-tile-coord
 unit-type-sym
 safe-list
 safe-hash-list)

;; -----------------------------------------------------------------------------
;; 1. Core Domain Types
;; -----------------------------------------------------------------------------

(define-type KnownRace (U 'Zerg 'Terran 'Protoss))
(define-type Race (U KnownRace 'Random))
(define-type MatchupSym (U 'ZvZ 'ZvT 'ZvP 'TvZ 'TvT 'TvP 'PvZ 'PvT 'PvP))
(define-type PostureSym Symbol)
(define-type BuildOrderActionKind (U 'build 'expand 'morph 'train 'research))
(define-type TileCoord Real)
(define-type UnitMap HashTableTop)
(define-type SupplyCurvePoint (Pair Positive-Integer (Pair Real Real)))

;; -----------------------------------------------------------------------------
;; 2. Domain Structs
;; -----------------------------------------------------------------------------

(struct point2d
  ([x : Float]
   [y : Float])
  #:transparent)

(struct aabb2d
  ([cx : Float]
   [cy : Float]
   [half-w : Float]
   [half-h : Float])
  #:transparent)

(struct pro-bo-goal
  ([kind : Symbol]              ;; 'build | 'expand | 'morph | 'train | 'research
   [target-sym : Symbol]        ;; canonical symbol (e.g. 'spawning-pool, 'factory, 'cybernetics-core)
   [target-count : Positive-Integer]
   [min-supply : Nonnegative-Integer]
   [prereq-ready-sym : (Option Symbol)])
  #:transparent)

(: pro-bo-goal-target (-> pro-bo-goal Symbol))
(define (pro-bo-goal-target g)
  (pro-bo-goal-target-sym g))

(struct pro-bo-eval-result
  ([matchup : Symbol]
   [active-goal : (Option pro-bo-goal)]
   [ready-actions : (Listof Any)]
   [reserved-minerals : Nonnegative-Integer]
   [reserved-gas : Nonnegative-Integer]
   [target-workers : Nonnegative-Integer]
   [target-army-supply : Real])
  #:transparent)

(struct build-order-spec
  ([matchup : MatchupSym]
   [race : KnownRace]
   [name : String]
   [archetype : Symbol]
   [description : String]
   [steps : (Listof pro-bo-goal)]
   [supply-curve : (Listof SupplyCurvePoint)])
  #:transparent)

(struct build-order-tree-node
  ([id : Symbol]
   [race : KnownRace]
   [parent-id : (Option Symbol)]
   [children-ids : (Listof Symbol)]
   [path-buildings : (Listof Symbol)]
   [step-buildings : (Listof Symbol)]
   [unlocked-units : (Listof Symbol)]
   [unlocked-upgrades : (Listof Symbol)]
   [archetype : Symbol]
   [min-frame : Nonnegative-Integer]
   [min-gas-bldgs : Nonnegative-Integer]
   [step-min-cost : Nonnegative-Integer]
   [step-gas-cost : Nonnegative-Integer]
   [step-build-frames : Nonnegative-Integer]
   [prior-weight : Float])
  #:transparent)

(struct bayesian-strategic-priors
  ([bluff-prior : Float]
   [bluff-posterior : Float]
   [feint-posterior : Float]
   [rush-posterior : Float]
   [hidden-expand-posterior : Float]
   [tech-switch-posterior : Float]
   [branch-posteriors : (HashTable Symbol Float)])
  #:transparent)

;; -----------------------------------------------------------------------------
;; 3. Predicates & Normalizers
;; -----------------------------------------------------------------------------

(: known-race? (-> Any Boolean : #:+ KnownRace))
(define (known-race? v)
  (or (eq? v 'Zerg) (eq? v 'Terran) (eq? v 'Protoss)))

(: matchup-sym? (-> Any Boolean : #:+ MatchupSym))
(define (matchup-sym? v)
  (or (eq? v 'ZvZ) (eq? v 'ZvT) (eq? v 'ZvP)
      (eq? v 'TvZ) (eq? v 'TvT) (eq? v 'TvP)
      (eq? v 'PvZ) (eq? v 'PvT) (eq? v 'PvP)))

(: ->float (-> Real Float))
(define (->float x)
  (real->double-flonum x))

(: clamp-real (-> Real Real Real Float))
(define (clamp-real x lo hi)
  (define f-lo (->float (min lo hi)))
  (define f-hi (->float (max lo hi)))
  (max f-lo (min f-hi (->float x))))

(: clamp-prob (->* (Real) (Real) Float))
(define (clamp-prob p [eps 0.0])
  (define e (clamp-real eps 0.0 0.49))
  (clamp-real p e (- 1.0 e)))

(: normalize-race (-> Any Race))
(define (normalize-race r)
  (cond
    [(or (eq? r 'Zerg) (eq? r 'zerg) (equal? r "Zerg") (equal? r "zerg")) 'Zerg]
    [(or (eq? r 'Protoss) (eq? r 'protoss) (equal? r "Protoss") (equal? r "protoss")) 'Protoss]
    [(or (eq? r 'Terran) (eq? r 'terran) (equal? r "Terran") (equal? r "terran")) 'Terran]
    [(or (eq? r 'Random) (eq? r 'random) (equal? r "Random") (equal? r "random")) 'Random]
    [else 'Zerg]))

(: normalize-known-race (-> Any KnownRace))
(define (normalize-known-race r)
  (define nr (normalize-race r))
  (if (known-race? nr) nr 'Zerg))

(: resolve-matchup-symbol (->* (Any) (Any) MatchupSym))
(define (resolve-matchup-symbol race [enemy-race 'Unknown])
  (if (matchup-sym? race)
      race
      (let ([r (normalize-known-race race)]
            [er (cond
                  [(or (eq? enemy-race 'Zerg) (eq? enemy-race 'zerg)
                       (equal? enemy-race "Zerg") (equal? enemy-race "zerg")) 'Zerg]
                  [(or (eq? enemy-race 'Terran) (eq? enemy-race 'terran)
                       (equal? enemy-race "Terran") (equal? enemy-race "terran")) 'Terran]
                  [(or (eq? enemy-race 'Protoss) (eq? enemy-race 'protoss)
                       (equal? enemy-race "Protoss") (equal? enemy-race "protoss")) 'Protoss]
                  [else 'Unknown])])
        (case r
          [(Zerg)
           (case er
             [(Zerg) 'ZvZ]
             [(Terran) 'ZvT]
             [(Protoss) 'ZvP]
             [else 'ZvT])]
          [(Terran)
           (case er
             [(Zerg) 'TvZ]
             [(Terran) 'TvT]
             [(Protoss) 'TvP]
             [else 'TvZ])]
          [else
           (case er
             [(Zerg) 'PvZ]
             [(Terran) 'PvT]
             [(Protoss) 'PvP]
             [else 'PvT])]))))

;; -----------------------------------------------------------------------------
;; 4. Total Numeric, Geometry, JSON, List, and Unit-Type Helpers
;; -----------------------------------------------------------------------------

;; Returns #t when `v` is a finite real number (neither NaN nor +/-inf.0).
(: finite-real? (-> Any Boolean))
(define (finite-real? v)
  (and (real? v) (not (nan? v)) (not (infinite? v))))

;; Converts finite `v` to a Float, falling back to `default`.
(: safe-finite-real (->* (Any) (Real) Float))
(define (safe-finite-real v [default 0.0])
  (if (and (real? v) (not (nan? v)) (not (infinite? v)))
      (->float v)
      (->float default)))

;; Converts finite `v` to a Float, falling back to finite `fallback` or 0.0.
(: safe-real (->* (Any) (Any) Float))
(define (safe-real v [fallback 0.0])
  (cond
    [(and (real? v) (not (nan? v)) (not (infinite? v)))
     (->float v)]
    [(and (real? fallback) (not (nan? fallback)) (not (infinite? fallback)))
     (->float fallback)]
    [else 0.0]))

;; Rounds finite `v` to an exact integer, falling back to `default`.
(: safe-exact-int (->* (Any) (Integer) Integer))
(define (safe-exact-int v [default 0])
  (if (and (real? v) (not (nan? v)) (not (infinite? v)))
      (exact-round v)
      default))

;; Rounds finite `v` to an exact integer, falling back to finite `fallback` or 0.
(: safe-int (->* (Any) (Any) Integer))
(define (safe-int v [fallback 0])
  (cond
    [(and (real? v) (not (nan? v)) (not (infinite? v)))
     (exact-round v)]
    [(and (real? fallback) (not (nan? fallback)) (not (infinite? fallback)))
     (exact-round fallback)]
    [else 0]))

;; Rounds finite `v` to a non-negative exact integer, falling back to `default`.
(: safe-nonneg-int (->* (Any) (Integer) Nonnegative-Integer))
(define (safe-nonneg-int v [default 0])
  (max 0 (safe-exact-int v default)))

;; Rounds finite `x` to 1 decimal place as a Float (falling back to 0.0).
(: round1 (-> Any Float))
(define (round1 x)
  (->float (/ (round (* 10.0 (safe-finite-real x 0.0))) 10.0)))

;; Rounds finite `x` to 2 decimal places as a Float (falling back to 0.0).
(: round2 (-> Any Float))
(define (round2 x)
  (->float (/ (round (* 100.0 (safe-finite-real x 0.0))) 100.0)))

;; Converts JSON `'null` or `#f` to `#f`, returning any other value unchanged.
(: jnull->false (-> Any Any))
(define (jnull->false v)
  (if (or (eq? v 'null) (not v)) #f v))

;; Returns Euclidean 2D distance using `safe-finite-real` defaults for each endpoint.
(: dist2d (->* (Any Any Any Any) (Real Real) Float))
(define (dist2d x1 y1 x2 y2 [default-1 0.0] [default-2 0.0])
  (define sx1 (safe-finite-real x1 default-1))
  (define sy1 (safe-finite-real y1 default-1))
  (define sx2 (safe-finite-real x2 default-2))
  (define sy2 (safe-finite-real y2 default-2))
  (define dx (- sx2 sx1))
  (define dy (- sy2 sy1))
  (define d2 (+ (* dx dx) (* dy dy)))
  (->float (sqrt (if (>= d2 0.0) d2 0.0))))

;; Returns Euclidean 2D distance when all 4 coordinates are `finite-real?`, else `fallback`.
(: safe-dist2d (->* (Any Any Any Any) (Real) Float))
(define (safe-dist2d x1 y1 x2 y2 [fallback 99999.0])
  (if (and (finite-real? x1) (finite-real? y1) (finite-real? x2) (finite-real? y2))
      (dist2d x1 y1 x2 y2)
      (->float fallback)))

;; Clamps finite `v` to `[0.0, max-coord]` and snaps to 0.5-tile increments.
(: safe-tile-coord (->* (Any) (Real Real) Real))
(define (safe-tile-coord v [default 32.5] [max-coord 256.0])
  (define raw : Real
    (if (and (real? v) (not (nan? v)) (not (infinite? v)))
        v
        default))
  (define clamped : Float (max 0.0 (min (->float max-coord) (->float raw))))
  (define half-rounded : Float (->float (/ (round (* clamped 2.0)) 2.0)))
  (if (and (exact-integer? raw) (= clamped (->float (exact-round half-rounded))))
      (exact-round half-rounded)
      half-rounded))

;; Total symbol extractor for unit hashes, symbols, or strings.
(: unit-type-sym (-> Any Symbol))
(define (unit-type-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type (lambda () 'unknown)))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(symbol? u) u]
    [(string? u) (string->symbol (string-downcase u))]
    [else 'unknown]))

;; Returns `xs` if it is a list, otherwise '().
(: safe-list (-> Any (Listof Any)))
(define (safe-list xs)
  (if (list? xs) xs '()))

;; Returns the hash elements of `xs` if it is a list, otherwise '().
(: safe-hash-list (-> Any (Listof HashTableTop)))
(define (safe-hash-list xs)
  (if (list? xs) (filter hash? xs) '()))
