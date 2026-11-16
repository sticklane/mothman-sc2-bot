#lang racket/base

;; =============================================================================
;; `lib/plan/static-defense.rkt`
;; Symmetric Static-Defense, Proxy-Cannon, & Swarm-Host Plans Module
;;
;; Layering invariant: imports ONLY `"../sc2-geometry.rkt"`,
;; `"../sc2-game-constants.rkt"`, and `"../sc2-common.rkt"` (plus `racket/*`).
;; Never imports `sc2-placement.rkt`, `tactics-sim.rkt`, or `nydus.rkt`.
;;
;; Symmetric Pairs (Offense <-> Counter):
;;   a) `plan-spread-burrowed-swarm-host-harass` <-> `plan-counter-spread-swarm-host-harass`
;;   b) `plan-pro-cannon-rush-tactics`           <-> `plan-counter-cannon-rush-tactics`
;;   c) `plan-photon-cannon-tactics`             <-> `plan-counter-photon-cannon-tactics`
;;   d) `plan-bunker-tactics`                    <-> `plan-counter-bunker-tactics`
;;   e) `plan-missile-turret-tactics`            <-> `plan-counter-missile-turret-tactics`
;;   f) `plan-planetary-fortress-tactics`        <-> `plan-counter-planetary-fortress-tactics`
;;   g) `plan-shield-battery-and-nexus-overcharge-tactics` <-> `plan-counter-shield-battery-tactics`
;;   h) `plan-spore-crawler-tactics`             <-> `plan-counter-spore-crawler-tactics`
;;      `plan-spine-crawler-tactics`             <-> `plan-counter-spine-crawler-tactics`
;; =============================================================================

(require racket/list
         racket/math
         racket/flonum
         racket/fixnum
         racket/set
         "../sc2-common.rkt"
         (except-in "../sc2-geometry.rkt" point2d aabb2d)
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

(provide
 ;; Canonical Constants
 NEXUS-ENERGY-RECHARGE-ABILITY-ID
 SHIELD-BATTERY-RECHARGE-ABILITY-ID
 SHIELD-BATTERY-RESTORE-LEGACY-ID
 SWARM-HOST-SPAWN-LOCUSTS-ABILITY-ID
 LOCUST-SWOOP-ABILITY-ID
 SWARM-HOST-COOLDOWN-FRAMES
 SWARM-HOST-STAGGER-MODULO
 BATTERY-OVERCHARGE-WINDOW-FRAMES
 ;; 8 Symmetric Static-Defense & Swarm-Host Tactic <-> Counter Pairs
 plan-spread-burrowed-swarm-host-harass
 plan-counter-spread-swarm-host-harass
 plan-pro-cannon-rush-tactics
 plan-counter-cannon-rush-tactics
 plan-photon-cannon-tactics
 plan-counter-photon-cannon-tactics
 plan-bunker-tactics
 plan-counter-bunker-tactics
 plan-missile-turret-tactics
 plan-counter-missile-turret-tactics
 plan-planetary-fortress-tactics
 plan-counter-planetary-fortress-tactics
 plan-shield-battery-and-nexus-overcharge-tactics
 plan-counter-shield-battery-tactics
 plan-spore-crawler-tactics
 plan-counter-spore-crawler-tactics
 plan-spine-crawler-tactics
 plan-counter-spine-crawler-tactics
 ;; Top-level orchestrator
 plan-static-defense-actions)

;; -----------------------------------------------------------------------------
;; 1. Canonical Ability & Window Constants
;; -----------------------------------------------------------------------------

(define NEXUS-ENERGY-RECHARGE-ABILITY-ID    4126) ;; ENERGYRECHARGE_ENERGYRECHARGE
(define SHIELD-BATTERY-RECHARGE-ABILITY-ID  4113) ;; SHIELDBATTERYRECHARGEEX5
(define SHIELD-BATTERY-RESTORE-LEGACY-ID    3751) ;; Legacy Shield Battery restore ID
(define SWARM-HOST-SPAWN-LOCUSTS-ABILITY-ID 1990) ;; SWARMHOSTSPAWNLOCUSTS_LOCUSTMP (legacy alias 2704)
(define LOCUST-SWOOP-ABILITY-ID             2706) ;; LOCUSTMPFLYINGSWOOPATTACK
(define SWARM-HOST-COOLDOWN-FRAMES          963)  ;; 43s Swarm Host cooldown @ 22.4 fps
(define SWARM-HOST-STAGGER-MODULO           112)  ;; 5s stagger modulus
(define BATTERY-OVERCHARGE-WINDOW-FRAMES    314)  ;; 14s Battery Overcharge window

;; -----------------------------------------------------------------------------
;; 2. Fast Cached Observation, Index & Geometry Helpers (Zero Contract Churn)
;; -----------------------------------------------------------------------------

(define *missing* (gensym 'missing))
(define *canon-unit-cache* (make-hasheq))
(define *canon-struct-cache* (make-hasheq))
(define *flying-sym-cache* (make-hasheq))
(define *noncombat-sym-cache* (make-hasheq))

(define (fast-safe-real v default)
  (if (and (real? v) (< -inf.0 v +inf.0))
      (exact->inexact v)
      (exact->inexact default)))

(define (fast-safe-int v default)
  (cond
    [(exact-integer? v) v]
    [(and (real? v) (< -inf.0 v +inf.0)) (inexact->exact (round v))]
    [else default]))

(define (fast-safe-nonneg-int v default)
  (define iv (fast-safe-int v default))
  (if (>= iv 0) iv default))

(define (fast-round2 v)
  (/ (round (* 100.0 (fast-safe-real v 0.0))) 100.0))

(define (fast-dist2 x1 y1 x2 y2)
  (define dx (- x2 x1))
  (define dy (- y2 y1))
  (+ (* dx dx) (* dy dy)))

(define (fast-dist2d x1 y1 x2 y2)
  (sqrt (fast-dist2 x1 y1 x2 y2)))

(define (fast-raw-unit-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(symbol? u) u]
    [(string? u) (string->symbol (string-downcase u))]
    [else 'unknown]))

(define (fast-canon-unit raw-sym)
  (or (hash-ref *canon-unit-cache* raw-sym #f)
      (let ([c (sc2-canonical-unit-sym raw-sym)])
        (hash-set! *canon-unit-cache* raw-sym c)
        c)))

(define (fast-canon-struct raw-sym)
  (or (hash-ref *canon-struct-cache* raw-sym #f)
      (let ([c (sc2-canonical-structure-sym raw-sym)])
        (hash-set! *canon-struct-cache* raw-sym c)
        c)))

(define (fast-flying-sym? csym)
  (define hit (hash-ref *flying-sym-cache* csym #f))
  (if hit
      (eq? hit 'yes)
      (let ([f? (or (sc2-unit-is-flying-sym? csym)
                    (and (memq csym
                               '(oracle banshee mutalisk phoenix void-ray liberator medivac
                                 warp-prism carrier tempest battlecruiser brood-lord))
                         #t))])
        (hash-set! *flying-sym-cache* csym (if f? 'yes 'no))
        f?)))

(define (fast-noncombat-sym? csym)
  (define hit (hash-ref *noncombat-sym-cache* csym #f))
  (if hit
      (eq? hit 'yes)
      (let ([nc? (or (and (memq csym '(scv probe drone larva egg overlord mule observer changeling)) #t)
                     (sc2-non-combat-or-summon-sym? csym))])
        (hash-set! *noncombat-sym-cache* csym (if nc? 'yes 'no))
        nc?)))

;; Combined per-symbol unit metadata: #(canon-sym worker? noncombat? flying?)
(define *unit-meta-cache* (make-hasheq))

(define (fast-unit-meta raw-sym)
  (or (hash-ref *unit-meta-cache* raw-sym #f)
      (let* ([csym (fast-canon-unit raw-sym)]
             [wrk? (and (memq csym '(scv probe drone)) #t)]
             [nc?  (fast-noncombat-sym? csym)]
             [fly? (fast-flying-sym? csym)]
             [v    (vector csym wrk? nc? fly?)])
        (hash-set! *unit-meta-cache* raw-sym v)
        v)))

(define (fast-hash-unit-pos-id? u)
  (define vid (hash-ref u 'id *missing*))
  (if (exact-integer? vid)
      (> vid 0)
      (> (u-id u) 0)))

(define (fast-hash-raw-sym u)
  (define raw (hash-ref u 'type 'unknown))
  (cond
    [(symbol? raw) raw]
    [(string? raw) (string->symbol (string-downcase raw))]
    [else 'unknown]))

(define (ensure-obs obs)
  (if (hash? obs) obs (hash)))

(define (obs-ref obs k default)
  (if (hash? obs)
      (let ([v (hash-ref obs k *missing*)])
        (if (eq? v *missing*) default v))
      default))

(define (obs-list obs k)
  (define v (obs-ref obs k '()))
  (if (list? v) v '()))

(define (u-id u)
  (if (hash? u)
      (let ([v (hash-ref u 'id *missing*)])
        (cond
          [(exact-integer? v) v]
          [(eq? v *missing*) (fast-safe-int (hash-ref u 'tag 0) 0)]
          [else (fast-safe-int v 0)]))
      0))

(define (u-sym u)
  (fast-canon-unit (fast-raw-unit-sym u)))

(define (u-struct-sym u)
  (fast-canon-struct (fast-raw-unit-sym u)))

(define (u-x u [default 32.5])
  (if (hash? u)
      (let ([v (hash-ref u 'x *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-y u [default 32.5])
  (if (hash? u)
      (let ([v (hash-ref u 'y *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-hp u [default 100.0])
  (if (hash? u)
      (let ([v (hash-ref u 'hp *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-max-hp u [default 100.0])
  (if (hash? u)
      (let ([v (hash-ref u 'max-hp *missing*)])
        (cond
          [(and (flonum? v) (fl< 1.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (max 1.0 (fast-safe-real (hash-ref u 'health-max default) default))]
          [else (max 1.0 (fast-safe-real v default))]))
      (max 1.0 (exact->inexact default))))

(define (u-hp-frac u)
  (if (hash? u)
      (let ([hp (hash-ref u 'hp *missing*)]
            [mh (hash-ref u 'max-hp *missing*)])
        (if (and (flonum? hp) (flonum? mh) (fl> mh 1.0) (fl< mh +inf.0) (fl< -inf.0 hp) (fl< hp +inf.0))
            (fl/ hp mh)
            (/ (u-hp u) (u-max-hp u))))
      1.0))

(define (u-shield u [default 0.0])
  (if (hash? u)
      (let ([v (hash-ref u 'shield *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (fast-safe-real (hash-ref u 'shields default) default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-max-shield u [default 0.0])
  (if (hash? u)
      (let ([v (hash-ref u 'max-shield *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (fast-safe-real (hash-ref u 'shield-max default) default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-shield-frac u)
  (if (hash? u)
      (let ([ms (hash-ref u 'max-shield *missing*)])
        (cond
          [(eq? ms *missing*)
           (let ([nms (u-max-shield u 0.0)])
             (if (> nms 0.0) (/ (u-shield u 0.0) nms) 1.0))]
          [(flonum? ms)
           (if (and (fl> ms 0.0) (fl< ms +inf.0))
               (let ([sh (hash-ref u 'shield *missing*)])
                 (if (and (flonum? sh) (fl< -inf.0 sh) (fl< sh +inf.0))
                     (fl/ sh ms)
                     (/ (u-shield u 0.0) ms)))
               1.0)]
          [(and (exact-integer? ms) (> ms 0))
           (/ (u-shield u 0.0) (exact->inexact ms))]
          [(and (real? ms) (> ms 0.0) (< ms +inf.0))
           (/ (u-shield u 0.0) (exact->inexact ms))]
          [else 1.0]))
      1.0))

(define (u-energy u [default 0.0])
  (if (hash? u)
      (let ([v (hash-ref u 'energy *missing*)])
        (if (eq? v *missing*)
            (exact->inexact default)
            (fast-safe-real v default)))
      (exact->inexact default)))

(define (u-max-energy u [default 200.0])
  (define me
    (if (hash? u)
        (let ([v (hash-ref u 'max-energy *missing*)])
          (if (eq? v *missing*)
              (fast-safe-real (hash-ref u 'energy-max default) default)
              (fast-safe-real v default)))
        (exact->inexact default)))
  (max 1.0 me))

(define (u-progress u [default 1.0])
  (if (hash? u)
      (let ([v (hash-ref u 'build-progress *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-complete? u)
  (if (hash? u)
      (let ([v (hash-ref u 'build-progress *missing*)])
        (cond
          [(flonum? v) (fl>= v SC2-BUILD-COMPLETE-PROGRESS)]
          [(eq? v *missing*) #t]
          [else (>= (fast-safe-real v 1.0) SC2-BUILD-COMPLETE-PROGRESS)]))
      #t))

(define (u-cargo-used u)
  (if (hash? u)
      (let ([v (hash-ref u 'cargo-space-taken *missing*)])
        (if (eq? v *missing*)
            (fast-safe-nonneg-int (hash-ref u 'cargo-used 0) 0)
            (fast-safe-nonneg-int v 0)))
      0))

(define (u-cargo-max u [default 4])
  (if (hash? u)
      (let ([v (hash-ref u 'cargo-space-max *missing*)])
        (if (eq? v *missing*)
            (fast-safe-nonneg-int (hash-ref u 'cargo-max default) default)
            (fast-safe-nonneg-int v default)))
      default))

(define (clamp-coord v)
  (fast-round2 (max SC2-MAP-SAFE-MIN-COORD (min SC2-MAP-SAFE-MAX-COORD (fast-safe-real v 88.0)))))

(define (home-xy obs)
  (values (fast-safe-real (obs-ref obs 'base-x SC2-DEFAULT-HOME-BASE-X) SC2-DEFAULT-HOME-BASE-X)
          (fast-safe-real (obs-ref obs 'base-y SC2-DEFAULT-HOME-BASE-Y) SC2-DEFAULT-HOME-BASE-Y)))

(define (nat-xy obs)
  (values (fast-safe-real (obs-ref obs 'natural-x SC2-DEFAULT-NATURAL-X) SC2-DEFAULT-NATURAL-X)
          (fast-safe-real (obs-ref obs 'natural-y SC2-DEFAULT-NATURAL-Y) SC2-DEFAULT-NATURAL-Y)))

(define (third-xy obs)
  (values (fast-safe-real (obs-ref obs 'third-x SC2-DEFAULT-THIRD-X) SC2-DEFAULT-THIRD-X)
          (fast-safe-real (obs-ref obs 'third-y SC2-DEFAULT-THIRD-Y) SC2-DEFAULT-THIRD-Y)))

(define (enemy-xy obs)
  (values (fast-safe-real (obs-ref obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) SC2-DEFAULT-ENEMY-BASE-X)
          (fast-safe-real (obs-ref obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) SC2-DEFAULT-ENEMY-BASE-Y)))

(define (enemy-exp-xy obs)
  (values (fast-safe-real (obs-ref obs 'enemy-expand-x (obs-ref obs 'enemy-exp-x SC2-DEFAULT-ENEMY-EXPAND-X))
                          SC2-DEFAULT-ENEMY-EXPAND-X)
          (fast-safe-real (obs-ref obs 'enemy-expand-y (obs-ref obs 'enemy-exp-y SC2-DEFAULT-ENEMY-EXPAND-Y))
                          SC2-DEFAULT-ENEMY-EXPAND-Y)))

(define (filter-by-types lst type-syms)
  (filter (lambda (u)
            (and (hash? u)
                 (> (u-id u) 0)
                 (or (memq (u-sym u) type-syms)
                     (memq (u-struct-sym u) type-syms))
                 #t))
          lst))

(define (nearest-entity-to x y candidates)
  (for/fold ([best #f] [best-d2 +inf.0] #:result best)
            ([c (in-list candidates)])
    (define d2 (fast-dist2 x y (u-x c x) (u-y c y)))
    (if (< d2 best-d2) (values c d2) (values best best-d2))))

(define (entities-within x y radius candidates)
  (if (null? candidates)
      '()
      (let ([r2 (* radius radius)])
        (for/fold ([acc '()] #:result (reverse acc))
                  ([c (in-list candidates)])
          (if (<= (fast-dist2 x y (u-x c 9999.0) (u-y c 9999.0)) r2)
              (cons c acc)
              acc)))))

(define (any-entity-within? x y radius candidates)
  (define r2 (* radius radius))
  (for/or ([c (in-list candidates)])
    (<= (fast-dist2 x y (u-x c 9999.0) (u-y c 9999.0)) r2)))

(define (topk-insert! kd2 ku filled k d2 u)
  (define full? (= filled k))
  (cond
    [(and full? (> d2 (vector-ref kd2 (- k 1)))) filled]
    [else
     (let loop ([p (if full? (- k 1) filled)])
       (cond
         [(and (> p 0) (<= d2 (vector-ref kd2 (- p 1))))
          (vector-set! kd2 p (vector-ref kd2 (- p 1)))
          (vector-set! ku p (vector-ref ku (- p 1)))
          (loop (- p 1))]
         [else
          (vector-set! kd2 p d2)
          (vector-set! ku p u)
          (if full? k (+ filled 1))]))]))

(define (topk->list ku filled)
  (let loop ([i (- filled 1)] [acc '()])
    (if (< i 0) acc (loop (- i 1) (cons (vector-ref ku i) acc)))))

(define (k-nearest-to x y k candidates [max-dist +inf.0])
  (if (or (fx<= k 0) (null? candidates))
      '()
      (let ([fx (real->double-flonum x)]
            [fy (real->double-flonum y)]
            [k-1 (fx- k 1)]
            [kd2 (make-vector k +inf.0)]
            [ku (make-vector k #f)]
            [init-cutoff (if (infinite? max-dist) +inf.0 (* max-dist max-dist))])
        (let loop ([rem candidates] [filled 0] [cutoff init-cutoff])
          (if (null? rem)
              (topk->list ku filled)
              (let* ([c (car rem)]
                     [dx (fl- (u-x c 9999.0) fx)]
                     [dx2 (fl* dx dx)])
                (if (<= dx2 cutoff)
                    (let* ([dy (fl- (u-y c 9999.0) fy)]
                           [d2 (fl+ dx2 (fl* dy dy))])
                      (if (<= d2 cutoff)
                          (let ([nf (topk-insert! kd2 ku filled k d2 c)])
                            (loop (cdr rem)
                                  nf
                                  (if (fx= nf k) (vector-ref kd2 k-1) cutoff)))
                          (loop (cdr rem) filled cutoff)))
                    (loop (cdr rem) filled cutoff))))))))

(define (step-from-to x1 y1 x2 y2 dist)
  (define dx (- x2 x1))
  (define dy (- y2 y1))
  (define d (sqrt (+ (* dx dx) (* dy dy))))
  (if (< d 0.001)
      (values (clamp-coord (+ x1 dist)) (clamp-coord y1))
      (values (clamp-coord (+ x1 (* dist (/ dx d))))
              (clamp-coord (+ y1 (* dist (/ dy d)))))))

(define (unit-is-worker? u)
  (and (memq (u-sym u) '(scv probe drone)) #t))

(define (ally-workers-list obs)
  (filter unit-is-worker? (obs-list obs 'ally-units)))

(define (ally-combat-units obs)
  (filter (lambda (u)
            (and (hash? u)
                 (> (u-id u) 0)
                 (not (fast-noncombat-sym? (u-sym u)))))
          (obs-list obs 'ally-units)))

(define (enemy-air-threats obs)
  (filter (lambda (u) (fast-flying-sym? (u-sym u)))
          (obs-list obs 'enemy-units)))

;; Flat XY cloud with axis-aligned bounding box for O(1) out-of-range skip & zero-hash inner loops
(struct xy-cloud (units xs ys minx maxx miny maxy count) #:transparent)

(define (build-xy-cloud lst default-xy)
  (if (null? lst)
      (xy-cloud '#() (flvector) (flvector) +inf.0 -inf.0 +inf.0 -inf.0 0)
      (let* ([dxy (real->double-flonum default-xy)]
             [uv (list->vector lst)]
             [n (vector-length uv)]
             [xv (make-flvector n 0.0)]
             [yv (make-flvector n 0.0)])
        (let loop ([i 0] [minx +inf.0] [maxx -inf.0] [miny +inf.0] [maxy -inf.0])
          (if (fx>= i n)
              (xy-cloud uv xv yv minx maxx miny maxy n)
              (let* ([u (vector-ref uv i)]
                     [ux (if (hash? u)
                             (let ([rx (hash-ref u 'x *missing*)])
                               (cond
                                 [(and (flonum? rx) (fl< -inf.0 rx) (fl< rx +inf.0)) rx]
                                 [(and (real? rx) (< -inf.0 rx +inf.0)) (real->double-flonum rx)]
                                 [else dxy]))
                             dxy)]
                     [uy (if (hash? u)
                             (let ([ry (hash-ref u 'y *missing*)])
                               (cond
                                 [(and (flonum? ry) (fl< -inf.0 ry) (fl< ry +inf.0)) ry]
                                 [(and (real? ry) (< -inf.0 ry +inf.0)) (real->double-flonum ry)]
                                 [else dxy]))
                             dxy)])
                (flvector-set! xv i ux)
                (flvector-set! yv i uy)
                (loop (fx+ i 1)
                      (if (fl< ux minx) ux minx)
                      (if (fl> ux maxx) ux maxx)
                      (if (fl< uy miny) uy miny)
                      (if (fl> uy maxy) uy maxy))))))))

;; Single-pass pre-indexer (`sd-index`) eliminating 20x duplicate scans over 200v200 units
(struct sd-index
  (frame
   bx by nx ny tx ty ex ey eex eey
   ally-units ally-bldgs enemy-units enemy-bldgs effects
   ally-u-by-type
   ally-b-by-type
   enemy-u-by-type
   enemy-b-by-type
   ally-workers
   ally-combat
   ally-air
   enemy-air
   [subtargets #:mutable]
   [eu-cloud #:mutable]
   [au-cloud #:mutable]
   [combat-cloud #:mutable]
   [aoe-casters #:mutable])
  #:transparent)

(define (ensure-eu-cloud! idx)
  (or (sd-index-eu-cloud idx)
      (let ([c (build-xy-cloud (sd-index-enemy-units idx) 9999.0)])
        (set-sd-index-eu-cloud! idx c)
        c)))

(define (ensure-au-cloud! idx)
  (or (sd-index-au-cloud idx)
      (let ([c (build-xy-cloud (sd-index-ally-units idx) 9999.0)])
        (set-sd-index-au-cloud! idx c)
        c)))

(define (ensure-combat-cloud! idx)
  (or (sd-index-combat-cloud idx)
      (let ([c (build-xy-cloud (sd-index-ally-combat idx) 9999.0)])
        (set-sd-index-combat-cloud! idx c)
        c)))

(define (cloud-k-nearest-to cld x y k max-dist)
  (define cnt (xy-cloud-count cld))
  (cond
    [(or (fx<= k 0) (fx= cnt 0)) '()]
    [(and (not (infinite? max-dist))
          (or (< (+ x max-dist) (xy-cloud-minx cld))
              (> (- x max-dist) (xy-cloud-maxx cld))
              (< (+ y max-dist) (xy-cloud-miny cld))
              (> (- y max-dist) (xy-cloud-maxy cld))))
     '()]
    [else
     (define uv (xy-cloud-units cld))
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define max-d2 (if (infinite? max-dist) +inf.0 (real->double-flonum (* max-dist max-dist))))
     (define k-1 (fx- k 1))
     (define kd2 (make-vector k +inf.0))
     (define ku (make-vector k #f))
     (let loop ([i 0] [filled 0] [cutoff max-d2])
       (if (fx>= i cnt)
           (topk->list ku filled)
           (let* ([dx (fl- (flvector-ref xs i) fx)]
                  [dx2 (fl* dx dx)])
             (if (fl<= dx2 cutoff)
                 (let* ([dy (fl- (flvector-ref ys i) fy)]
                        [d2 (fl+ dx2 (fl* dy dy))])
                   (if (fl<= d2 cutoff)
                       (let ([nf (topk-insert! kd2 ku filled k d2 (vector-ref uv i))])
                         (loop (fx+ i 1)
                               nf
                               (if (fx= nf k) (real->double-flonum (vector-ref kd2 k-1)) cutoff)))
                       (loop (fx+ i 1) filled cutoff)))
                 (loop (fx+ i 1) filled cutoff)))))]))

(define (cloud-any-within? cld x y r)
  (define cnt (xy-cloud-count cld))
  (cond
    [(fx= cnt 0) #f]
    [(or (< (+ x r) (xy-cloud-minx cld))
         (> (- x r) (xy-cloud-maxx cld))
         (< (+ y r) (xy-cloud-miny cld))
         (> (- y r) (xy-cloud-maxy cld)))
     #f]
    [else
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define r2 (real->double-flonum (* r r)))
     (let loop ([i 0])
       (cond
         [(fx>= i cnt) #f]
         [else
          (define dx (fl- (flvector-ref xs i) fx))
          (define dy (fl- (flvector-ref ys i) fy))
          (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) r2)
              #t
              (loop (fx+ i 1)))]))]))

(define (cloud-count-within? cld x y r limit)
  (define cnt (xy-cloud-count cld))
  (cond
    [(fx= cnt 0) 0]
    [(or (< (+ x r) (xy-cloud-minx cld))
         (> (- x r) (xy-cloud-maxx cld))
         (< (+ y r) (xy-cloud-miny cld))
         (> (- y r) (xy-cloud-maxy cld)))
     0]
    [else
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define r2 (real->double-flonum (* r r)))
     (let loop ([i 0] [hits 0])
       (cond
         [(or (fx>= i cnt) (fx>= hits limit)) hits]
         [else
          (define dx (fl- (flvector-ref xs i) fx))
          (define dy (fl- (flvector-ref ys i) fy))
          (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) r2)
              (loop (fx+ i 1) (fx+ hits 1))
              (loop (fx+ i 1) hits))]))]))

(define (cloud-entities-within cld x y r)
  (define cnt (xy-cloud-count cld))
  (cond
    [(fx= cnt 0) '()]
    [(or (< (+ x r) (xy-cloud-minx cld))
         (> (- x r) (xy-cloud-maxx cld))
         (< (+ y r) (xy-cloud-miny cld))
         (> (- y r) (xy-cloud-maxy cld)))
     '()]
    [else
     (define uv (xy-cloud-units cld))
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define r2 (real->double-flonum (* r r)))
     (let loop ([i (fx- cnt 1)] [acc '()])
       (cond
         [(fx< i 0) acc]
         [else
          (define dx (fl- (flvector-ref xs i) fx))
          (define dy (fl- (flvector-ref ys i) fy))
          (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) r2)
              (loop (fx- i 1) (cons (vector-ref uv i) acc))
              (loop (fx- i 1) acc))]))]))

(define (cloud-near-flags cld x y r-small r-big)
  (define cnt (xy-cloud-count cld))
  (cond
    [(fx= cnt 0) (values #f #f)]
    [(or (< (+ x r-big) (xy-cloud-minx cld))
         (> (- x r-big) (xy-cloud-maxx cld))
         (< (+ y r-big) (xy-cloud-miny cld))
         (> (- y r-big) (xy-cloud-maxy cld)))
     (values #f #f)]
    [else
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define r2s (real->double-flonum (* r-small r-small)))
     (define r2b (real->double-flonum (* r-big r-big)))
     (let loop ([i 0] [ns? #f] [nb? #f])
       (cond
         [(or (fx>= i cnt) ns?) (values ns? nb?)]
         [else
          (define dx (fl- (flvector-ref xs i) fx))
          (define dy (fl- (flvector-ref ys i) fy))
          (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
          (loop (fx+ i 1)
                (or ns? (fl<= d2 r2s))
                (or nb? (fl<= d2 r2b)))]))]))

(define (cloud-near-collect-idx+flag cld x y r-collect r-flag)
  (define cnt (xy-cloud-count cld))
  (cond
    [(fx= cnt 0) (values '() #f)]
    [(or (< (+ x r-flag) (xy-cloud-minx cld))
         (> (- x r-flag) (xy-cloud-maxx cld))
         (< (+ y r-flag) (xy-cloud-miny cld))
         (> (- y r-flag) (xy-cloud-maxy cld)))
     (values '() #f)]
    [else
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define r2c (real->double-flonum (* r-collect r-collect)))
     (define r2f (real->double-flonum (* r-flag r-flag)))
     (let loop ([i (fx- cnt 1)] [coll '()] [nf? #f])
       (cond
         [(fx< i 0) (values coll nf?)]
         [else
          (define dx (fl- (flvector-ref xs i) fx))
          (define dy (fl- (flvector-ref ys i) fy))
          (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
          (cond
            [(fl<= d2 r2c) (loop (fx- i 1) (cons i coll) #t)]
            [(fl<= d2 r2f) (loop (fx- i 1) coll #t)]
            [else (loop (fx- i 1) coll nf?)])]))]))

(define (ht-push! ht key val)
  (define b (hash-ref ht key #f))
  (if b
      (set-box! b (cons val (unbox b)))
      (hash-set! ht key (box (list val)))))

(define (finalize-buckets! ht)
  (let loop ([pos (hash-iterate-first ht)])
    (when pos
      (define lst (unbox (hash-iterate-value ht pos)))
      (hash-set! ht (hash-iterate-key ht pos)
                 (if (pair? (cdr lst)) (reverse lst) lst))
      (loop (hash-iterate-next ht pos)))))

(define (has-bucket? ht syms)
  (let loop ([rem syms])
    (and (pair? rem)
         (or (hash-has-key? ht (car rem))
             (loop (cdr rem))))))

;; build-sd-index pre-filters (> uid 0) and preserves forward order
(define (bucket-pos-ids ht syms)
  (if (and (pair? syms) (null? (cdr syms)))
      (hash-ref ht (car syms) '())
      (let loop ([rem syms] [acc '()])
        (if (null? rem)
            acc
            (let ([vs (hash-ref ht (car rem) '())])
              (loop (cdr rem)
                    (if (null? vs) acc (if (null? acc) vs (append acc vs)))))))))

(define (first-pos-id ht sym)
  (define vs (hash-ref ht sym '()))
  (and (pair? vs) (car vs)))

(define (build-sd-index raw-obs)
  (define obs (ensure-obs raw-obs))
  (define frame (fast-safe-nonneg-int (obs-ref obs 'frame 0) 0))
  (define-values (bx by) (home-xy obs))
  (define-values (nx ny) (nat-xy obs))
  (define-values (tx ty) (third-xy obs))
  (define-values (ex ey) (enemy-xy obs))
  (define-values (eex eey) (enemy-exp-xy obs))
  (define ally-units (obs-list obs 'ally-units))
  (define ally-bldgs (obs-list obs 'ally-buildings))
  (define enemy-units (obs-list obs 'enemy-units))
  (define enemy-bldgs (obs-list obs 'enemy-buildings))
  (define effects (obs-list obs 'effects))

  (define ally-u-ht (make-hasheq))
  (define ally-b-ht (make-hasheq))
  (define enemy-u-ht (make-hasheq))
  (define enemy-b-ht (make-hasheq))

  (define-values (workers-rev combat-rev ally-air-rev)
    (let loop-ally ([rem ally-units] [w-rev '()] [c-rev '()] [aa-rev '()])
      (if (null? rem)
          (values w-rev c-rev aa-rev)
          (let ([u (car rem)]
                [rest (cdr rem)])
            (if (and (hash? u) (fast-hash-unit-pos-id? u))
                (let ([meta (fast-unit-meta (fast-hash-raw-sym u))])
                  (ht-push! ally-u-ht (vector-ref meta 0) u)
                  (cond
                    [(vector-ref meta 1) (loop-ally rest (cons u w-rev) c-rev aa-rev)]
                    [(not (vector-ref meta 2))
                     (loop-ally rest
                                w-rev
                                (cons u c-rev)
                                (if (vector-ref meta 3) (cons u aa-rev) aa-rev))]
                    [else (loop-ally rest w-rev c-rev aa-rev)]))
                (loop-ally rest w-rev c-rev aa-rev))))))

  (let loop-ab ([rem ally-bldgs])
    (when (pair? rem)
      (let ([b (car rem)])
        (when (and (hash? b) (fast-hash-unit-pos-id? b))
          (ht-push! ally-b-ht (fast-canon-struct (fast-hash-raw-sym b)) b)))
      (loop-ab (cdr rem))))

  (define air-rev
    (let loop-enemy ([rem enemy-units] [e-rev '()])
      (if (null? rem)
          e-rev
          (let ([u (car rem)]
                [rest (cdr rem)])
            (if (and (hash? u) (fast-hash-unit-pos-id? u))
                (let ([meta (fast-unit-meta (fast-hash-raw-sym u))])
                  (ht-push! enemy-u-ht (vector-ref meta 0) u)
                  (loop-enemy rest (if (vector-ref meta 3) (cons u e-rev) e-rev)))
                (loop-enemy rest e-rev))))))

  (let loop-eb ([rem enemy-bldgs])
    (when (pair? rem)
      (let ([b (car rem)])
        (when (and (hash? b) (fast-hash-unit-pos-id? b))
          (ht-push! enemy-b-ht (fast-canon-struct (fast-hash-raw-sym b)) b)))
      (loop-eb (cdr rem))))

  (finalize-buckets! ally-u-ht)
  (finalize-buckets! ally-b-ht)
  (finalize-buckets! enemy-u-ht)
  (finalize-buckets! enemy-b-ht)

  (sd-index frame bx by nx ny tx ty ex ey eex eey
            ally-units ally-bldgs enemy-units enemy-bldgs effects
            ally-u-ht ally-b-ht enemy-u-ht enemy-b-ht
            (reverse workers-rev) (reverse combat-rev) (reverse ally-air-rev) (reverse air-rev)
            #f #f #f #f #f))

(define (collect-enemy-base-subtargets/idx idx)
  (or (sd-index-subtargets idx)
      (let* ([ex (sd-index-ex idx)]
             [ey (sd-index-ey idx)]
             [eex (sd-index-eex idx)]
             [eey (sd-index-eey idx)]
             [eb-ht (sd-index-enemy-b-by-type idx)]
             [ths (bucket-pos-ids eb-ht '(hatchery lair hive nexus command-center orbital-command planetary-fortress))]
             [techs (bucket-pos-ids eb-ht '(spawning-pool roach-warren baneling-nest spire infestation-pit
                                            factory starport cybernetics-core twilight-council robotics-facility stargate))]
             [addons (bucket-pos-ids eb-ht '(barracks-techlab factory-techlab starport-techlab
                                             barracks-reactor factory-reactor starport-reactor))]
             [base-targets
              (append
               (list (list 'main-mineral-line (clamp-coord (+ ex 3.0)) (clamp-coord (+ ey 3.0)))
                     (list 'natural-mineral-line (clamp-coord eex) (clamp-coord eey)))
               (for/list ([th (in-list ths)])
                 (list 'enemy-base (clamp-coord (u-x th ex)) (clamp-coord (u-y th ey))))
               (for/list ([tc (in-list techs)])
                 (list 'tech-cluster (clamp-coord (u-x tc ex)) (clamp-coord (u-y tc ey))))
               (for/list ([ad (in-list addons)])
                 (list 'addon-cluster (clamp-coord (u-x ad ex)) (clamp-coord (u-y ad ey)))))]
             [res (remove-duplicates base-targets equal?)])
        (set-sd-index-subtargets! idx res)
        res)))

(define (get-aoe-casters/idx idx)
  (or (sd-index-aoe-casters idx)
      (let* ([au-ht (sd-index-ally-u-by-type idx)]
             [rav (first-pos-id au-ht 'ravager)]
             [ht (for/or ([u (in-list (hash-ref au-ht 'high-templar '()))])
                   (and (>= (u-energy u 0.0) 75.0) u))]
             [gh (for/or ([u (in-list (hash-ref au-ht 'ghost '()))])
                   (and (>= (u-energy u 0.0) 75.0) u))]
             [inf (for/or ([u (in-list (hash-ref au-ht 'infestor '()))])
                   (and (>= (u-energy u 0.0) 75.0) u))]
             [vpr (for/or ([u (in-list (hash-ref au-ht 'viper '()))])
                   (and (>= (u-energy u 0.0) 100.0) u))]
             [res (vector (and rav (u-id rav))
                          (and ht  (u-id ht))
                          (and gh  (u-id gh))
                          (and inf (u-id inf))
                          (and vpr (u-id vpr)))])
        (set-sd-index-aoe-casters! idx res)
        res)))

(define (find-aoe-helper-cast/idx idx tx ty)
  (define casters (get-aoe-casters/idx idx))
  (define rav-id (vector-ref casters 0))
  (define ht-id  (vector-ref casters 1))
  (define gh-id  (vector-ref casters 2))
  (define inf-id (vector-ref casters 3))
  (define vpr-id (vector-ref casters 4))
  (if (not (or rav-id ht-id gh-id inf-id vpr-id))
      '()
      (let ([ctx (clamp-coord tx)]
            [cty (clamp-coord ty)]
            [acts '()])
        (when vpr-id (set! acts (cons (list 'cast-spell vpr-id 'blinding-cloud ctx cty) acts)))
        (when inf-id (set! acts (cons (list 'cast-spell inf-id 'fungal-growth ctx cty) acts)))
        (when gh-id  (set! acts (cons (list 'cast-spell gh-id  'emp-round ctx cty) acts)))
        (when ht-id  (set! acts (cons (list 'cast-spell ht-id  'psi-storm ctx cty) acts)))
        (when rav-id (set! acts (cons (list 'cast-spell rav-id 'corrosive-bile ctx cty) acts)))
        acts)))

;; -----------------------------------------------------------------------------
;; 3a. Spread Burrowed Swarm Host Harass <-> Counter Spread Swarm Host Harass
;; -----------------------------------------------------------------------------

(define (plan-spread-burrowed-swarm-host-harass/idx idx)
  (define au-ht (sd-index-ally-u-by-type idx))
  (if (not (has-bucket? au-ht '(swarm-host swarm-host-burrowed locust-flying)))
      '()
      (let ()
        (define hosts (sort (bucket-pos-ids au-ht '(swarm-host swarm-host-burrowed)) < #:key u-id))
        (define flying-locusts (bucket-pos-ids au-ht '(locust-flying)))
        (if (and (null? hosts) (null? flying-locusts))
            '()
            (let ()
              (define frame (sd-index-frame idx))
              (define sub-vec #f)
              (define ntgt 1)
              (define (ensure-sub-vec!)
                (unless sub-vec
                  (set! sub-vec (list->vector (collect-enemy-base-subtargets/idx idx)))
                  (set! ntgt (max 1 (vector-length sub-vec))))
                sub-vec)
              (define ex (sd-index-ex idx))
              (define ey (sd-index-ey idx))
              (define actions '())
              (define (emit! a) (set! actions (cons a actions)))

              ;; 1. Spread hosts on a 16.0-26.0 tile arc outside enemy base with >= 7.5 tile spacing
              (when (pair? hosts)
                (define nhosts (length hosts))
                (define h-ids (make-vector nhosts 0))
                (define h-xs (make-flvector nhosts 0.0))
                (define h-ys (make-flvector nhosts 0.0))
                (for ([sh (in-list hosts)]
                      [i (in-naturals)])
                  (vector-set! h-ids i (u-id sh))
                  (flvector-set! h-xs i (real->double-flonum (u-x sh ex)))
                  (flvector-set! h-ys i (real->double-flonum (u-y sh ey))))
                (for ([sh (in-list hosts)]
                      [i (in-naturals)])
                  (define sh-id (vector-ref h-ids i))
                  (define sx (flvector-ref h-xs i))
                  (define sy (flvector-ref h-ys i))
                  (define d-enemy (fast-dist2d sx sy ex ey))
                  (define out-of-band? (or (< d-enemy 16.0) (> d-enemy 26.0)))
                  (define too-close-peer?
                    (and (not out-of-band?)
                         (let loop-p ([j 0])
                           (and (fx< j i)
                                (or (let* ([dx (fl- sx (flvector-ref h-xs j))]
                                           [dy (fl- sy (flvector-ref h-ys j))])
                                      (fl< (fl+ (fl* dx dx) (fl* dy dy)) 56.25))
                                    (loop-p (fx+ j 1)))))))
                  (define burrowed? (or (eq? (u-sym sh) 'swarm-host-burrowed)
                                        (eq? (obs-ref sh 'burrowed #f) #t)))
                  (cond
                    [(or out-of-band? too-close-peer?)
                     (define base-ang (atan (- sy ey) (- sx ex)))
                     (define slot-ang (+ base-ang (* (- i 1.5) 0.48)))
                     (define ax (clamp-coord (+ ex (* 21.0 (cos slot-ang)))))
                     (define ay (clamp-coord (+ ey (* 21.0 (sin slot-ang)))))
                     (when burrowed? (emit! (list 'burrow-up sh-id)))
                     (emit! (list 'move sh-id ax ay))]
                    [else
                     (define stagger-slot (modulo (+ frame (* 37 sh-id)) SWARM-HOST-STAGGER-MODULO))
                     (define fire-window? (<= stagger-slot 15))
                     (define ready?
                       (and fire-window?
                            (not (eq? (obs-ref sh 'locusts-ready? #t) #f))
                            (let ([raw-cd (hash-ref sh 'spawn-locusts-cooldown *missing*)])
                              (<= (fast-safe-int
                                   (if (eq? raw-cd *missing*) (obs-ref sh 'cooldown 0) raw-cd)
                                   0)
                                  0))))
                     (cond
                       [ready?
                        (define sv (ensure-sub-vec!))
                        (define tgt-idx (remainder (+ sh-id (quotient frame SWARM-HOST-STAGGER-MODULO)) ntgt))
                        (define sub (vector-ref sv tgt-idx))
                        (define sub-kind (first sub))
                        (define tx (second sub))
                        (define ty (third sub))
                        (when burrowed? (emit! (list 'burrow-up sh-id)))
                        (emit! (list 'cast-spell sh-id 'spawn-locusts tx ty))
                        (emit! (list 'swarm-host-stagger-spawn sh-id tx ty sub-kind))
                        (emit! (list 'burrow-down sh-id))]
                       [(not burrowed?)
                        (emit! (list 'burrow-down sh-id))])])))

              ;; 2. Swoop flying Locusts onto enemy mineral/tech sub-targets (`2706`)
              (when (pair? flying-locusts)
                (define sv (ensure-sub-vec!))
                (for ([loc (in-list flying-locusts)]
                      [i (in-naturals)])
                  (define lid (u-id loc))
                  (define sub (vector-ref sv (remainder (+ lid i) ntgt)))
                  (define tx (second sub))
                  (define ty (third sub))
                  (when (<= (fast-dist2 (u-x loc tx) (u-y loc ty) tx ty) 784.0)
                    (emit! (list 'locust-swoop lid tx ty)))))

              (reverse actions))))))

(define (plan-spread-burrowed-swarm-host-harass raw-obs)
  (plan-spread-burrowed-swarm-host-harass/idx (build-sd-index raw-obs)))

(define (plan-counter-spread-swarm-host-harass/idx idx)
  (define eu-ht (sd-index-enemy-u-by-type idx))
  (if (not (has-bucket? eu-ht '(locust locust-flying)))
      '()
      (let ([enemy-locusts (bucket-pos-ids eu-ht '(locust locust-flying))])
        (if (null? enemy-locusts)
            '()
            (let ()
              (define bx (sd-index-bx idx))
              (define by (sd-index-by idx))
              (define nx (sd-index-nx idx))
              (define ny (sd-index-ny idx))
              (define actions '())
              (define (emit! a) (set! actions (cons a actions)))
              ;; Triangulate average hideout vector by back-projecting 21.0 tiles (midpoint of 16.0-26.0)
              (define-values (sx sy cnt)
                (for/fold ([ax 0.0] [ay 0.0] [n 0])
                          ([loc (in-list enemy-locusts)])
                  (define lx (u-x loc bx))
                  (define ly (u-y loc by))
                  (define-values (tx ty)
                    (if (<= (fast-dist2 lx ly nx ny) (fast-dist2 lx ly bx by))
                        (values nx ny)
                        (values bx by)))
                  (define vx (fast-safe-real (obs-ref loc 'vx (- tx lx)) (- tx lx)))
                  (define vy (fast-safe-real (obs-ref loc 'vy (- ty ly)) (- ty ly)))
                  (define mag (max 0.001 (sqrt (+ (* vx vx) (* vy vy)))))
                  (define hx (clamp-coord (- lx (* 21.0 (/ vx mag)))))
                  (define hy (clamp-coord (- ly (* 21.0 (/ vy mag)))))
                  (values (+ ax hx) (+ ay hy) (+ n 1))))
              (define hide-x (clamp-coord (/ sx (max 1 cnt))))
              (define hide-y (clamp-coord (/ sy (max 1 cnt))))
              (emit! (list 'swarm-host-triangulated-hideout hide-x hide-y cnt))

              (define au-ht (sd-index-ally-u-by-type idx))
              (define detectors (bucket-pos-ids au-ht '(overseer observer raven)))
              (define hunters
                (bucket-pos-ids au-ht '(zergling mutalisk roach hellion reaper cyclone phoenix stalker zealot adept)))
              (define screen-count (min 3 (inexact->exact (ceiling (/ cnt 2.0)))))
              (define-values (screen-units remaining-hunters)
                (if (<= (length hunters) screen-count)
                    (values hunters '())
                    (split-at hunters screen-count)))
              (define lead-loc (first enemy-locusts))
              (for ([su (in-list screen-units)])
                (emit! (list 'attack-unit (u-id su) (u-id lead-loc))))

              (cond
                [(pair? detectors)
                 (emit! (list 'move (u-id (first detectors)) hide-x hide-y))]
                [else
                 (define ocs (bucket-pos-ids (sd-index-ally-b-by-type idx) '(orbital-command)))
                 (define ready-oc (findf (lambda (o) (>= (u-energy o 0.0) 50.0)) ocs))
                 (when ready-oc
                   (emit! (list 'cast-spell (u-id ready-oc) 'scanner-sweep hide-x hide-y)))])

              (for ([hu (in-list (take remaining-hunters (min 6 (length remaining-hunters))))])
                (emit! (list 'attack (u-id hu) hide-x hide-y)))
              (reverse actions))))))

(define (plan-counter-spread-swarm-host-harass raw-obs)
  (plan-counter-spread-swarm-host-harass/idx (build-sd-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 3b. Pro Cannon Rush Tactics <-> Counter Cannon Rush Tactics
;; -----------------------------------------------------------------------------

(define (first-existing-coord vals default)
  (let loop ([xs vals])
    (if (null? xs)
        default
        (let ([v (car xs)])
          (if (and (real? v) (< -inf.0 v +inf.0))
              (exact->inexact v)
              (loop (cdr xs)))))))

(define (emit-assimilator-wedge-if-flagged! u ex ey emit!)
  (when (or (eq? (obs-ref u 'assimilator-wedge-ready? #f) #t)
            (eq? (obs-ref u 'near-geyser? #f) #t))
    (define ux (u-x u ex))
    (define uy (u-y u ey))
    (define gx (obs-ref u 'geyser-x #f))
    (define gy (obs-ref u 'geyser-y #f))
    (define-values (ax ay)
      (if (and (real? gx) (real? gy) (< -inf.0 gx +inf.0) (< -inf.0 gy +inf.0))
          (values (clamp-coord gx) (clamp-coord gy))
          (step-from-to ux uy ex ey 2.5)))
    (emit! (list 'printf-assimilator-wedge 'assimilator ax ay))))

(define *printf-hazard-effects*
  '(corrosive-bile corrosivebile siege-tank-splash tank-splash psi-storm psionic-storm
    nuke purification-nova blinding-cloud kd8-charge liberator-defender-zone fungal-growth))

(define *printf-def-structs*
  '(spine-crawler bunker shield-battery photon-cannon))

(define *printf-wall-structs*
  '(pylon gateway))

(define *printf-enemy-th-structs*
  '(command-center orbital-command planetary-fortress hatchery lair hive))

(define (collect-hazard-points idx)
  (define effects (sd-index-effects idx))
  (define eu-ht (sd-index-enemy-u-by-type idx))
  (define biles (hash-ref eu-ht 'corrosive-bile '()))
  (define tanks (bucket-pos-ids eu-ht '(siege-tank siege-tank-sieged)))
  (define pts '())
  (for ([ef (in-list effects)])
    (when (hash? ef)
      (define sym
        (fast-canon-unit
         (let ([t (obs-ref ef 'type (obs-ref ef 'name 'unknown))])
           (cond [(symbol? t) t] [(string? t) (string->symbol (string-downcase t))] [else 'unknown]))))
      (when (memq sym *printf-hazard-effects*)
        (define rx (hash-ref ef 'x *missing*))
        (define ry (hash-ref ef 'y *missing*))
        (when (and (real? rx) (real? ry) (< -inf.0 rx +inf.0) (< -inf.0 ry +inf.0))
          (set! pts (cons (cons (exact->inexact rx) (exact->inexact ry)) pts))))))
  (for ([bu (in-list biles)])
    (set! pts (cons (cons (u-x bu 9999.0) (u-y bu 9999.0)) pts)))
  (for ([tk (in-list tanks)])
    (when (or (eq? (obs-ref tk 'attacking? #f) #t)
              (eq? (obs-ref tk 'firing? #f) #t))
      (define tx (obs-ref tk 'target-x #f))
      (define ty (obs-ref tk 'target-y #f))
      (cond
        [(and (real? tx) (real? ty) (< -inf.0 tx +inf.0) (< -inf.0 ty +inf.0))
         (set! pts (cons (cons (exact->inexact tx) (exact->inexact ty)) pts))]
        [else
         (set! pts (cons (cons (u-x tk 9999.0) (u-y tk 9999.0)) pts))])))
  pts)

(define (plan-pro-cannon-rush-tactics/idx idx [obs #f])
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define au-ht (sd-index-ally-u-by-type idx))
  (if (not (or (has-bucket? ab-ht '(pylon photon-cannon gateway shield-battery robotics-facility stargate))
               (has-bucket? au-ht '(probe))))
      '()
      (let ()
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define nx (sd-index-nx idx))
        (define ny (sd-index-ny idx))
        (define ex (sd-index-ex idx))
        (define ey (sd-index-ey idx))
        (define pylons (hash-ref ab-ht 'pylon '()))
        (define cannons (hash-ref ab-ht 'photon-cannon '()))
        (define gateways (hash-ref ab-ht 'gateway '()))
        (define probes (hash-ref au-ht 'probe '()))
        (define eu-cld #f)
        (define (get-eu-cld)
          (unless eu-cld (set! eu-cld (ensure-eu-cloud! idx)))
          eu-cld)
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        ;; Single-pass scans over pylons / cannons / gateways (unboxed tail loops)
        (define-values (completed-hg-pylon? inc-pylons-rev forward-pylons lg-anchor-p)
          (let loop-py ([rem pylons] [hg? #f] [inc '()] [fwd '()] [anc #f])
            (if (null? rem)
                (values hg? inc (reverse fwd) anc)
                (let* ([b (car rem)]
                       [px (u-x b bx)]
                       [py (u-y b by)]
                       [comp? (u-complete? b)]
                       [ninc (if comp? inc (cons b inc))])
                  (if (> (fast-dist2 px py bx by) 676.0)
                      (let* ([bait? (eq? (obs-ref b 'low-ground-bait? #f) #t)]
                             [nhg? (or hg? (and comp? (not bait?)))]
                             [nanc (if (and (or (not anc) (eq? (obs-ref b 'low-ground? #f) #t) bait?)
                                            (<= (fast-dist2 px py ex ey) 1600.0))
                                       b
                                       anc)])
                        (loop-py (cdr rem) nhg? ninc (cons b fwd) nanc))
                      (loop-py (cdr rem) hg? ninc fwd anc))))))

        (define-values (incomplete-pc-rev forward-cannons ready-fwd-cannons lg-anchor)
          (let loop-can ([rem cannons] [inc inc-pylons-rev] [fwd '()] [rdy '()] [anc lg-anchor-p])
            (if (null? rem)
                (values inc (reverse fwd) (reverse rdy) anc)
                (let* ([c (car rem)]
                       [cx (u-x c bx)]
                       [cy (u-y c by)]
                       [comp? (u-complete? c)]
                       [ninc (if comp? inc (cons c inc))])
                  (if (> (fast-dist2 cx cy bx by) 676.0)
                      (let* ([nrdy (if comp? (cons c rdy) rdy)]
                             [nanc (if (and (not anc)
                                            (or (not comp?) (eq? (obs-ref c 'low-ground? #f) #t))
                                            (<= (fast-dist2 cx cy ex ey) 1600.0))
                                       c
                                       anc)])
                        (loop-can (cdr rem) ninc (cons c fwd) nrdy nanc))
                      (loop-can (cdr rem) ninc fwd rdy anc))))))

  (define (u-actual-vitality-frac b)
    (if (hash? b)
        (let* ([has-hull-hp? (hash-has-key? b 'hull-hp)]
               [hp (u-hp b 100.0)]
               [mhp (u-max-hp b 100.0)]
               [sh (if has-hull-hp? 0.0 (u-shield b 0.0))]
               [raw-msh (if has-hull-hp?
                            0.0
                            (let ([ms1 (hash-ref b 'max-shield *missing*)])
                              (cond
                                [(not (eq? ms1 *missing*)) (fast-safe-real ms1 0.0)]
                                [(not (eq? (hash-ref b 'shield-max *missing*) *missing*))
                                 (fast-safe-real (hash-ref b 'shield-max 0.0) 0.0)]
                                [else (fast-safe-real (hash-ref b 'max-shields 0.0) 0.0)])))]
               [cur (+ hp sh)]
               [tot (max 1.0 (+ mhp raw-msh))])
          (if (> raw-msh 0.0)
              (/ cur tot)
              (min 1.0 (/ cur tot))))
        1.0))

  (define (enemy-weapon-attacker-near? x y radius)
    (define cld (get-eu-cld))
    (define near-eu (cloud-entities-within cld x y radius))
    (define (armed? ent)
      (and (hash? ent)
           (let ([sym (u-sym ent)])
             (and (not (memq sym SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS))
                  (let ([st (sc2-unit-combat-stats sym)])
                    (or (> (hash-ref st 'ground-dps 0.0) 0.0)
                        (> (hash-ref st 'air-dps 0.0) 0.0)))))))
    (or (for/or ([e (in-list near-eu)])
          (armed? e))
        (let ([r2 (* radius radius)])
          (for/or ([eb (in-list (sd-index-enemy-bldgs idx))])
            (and (armed? eb)
                 (u-complete? eb)
                 (<= (fast-dist2 x y (u-x eb 9999.0) (u-y eb 9999.0)) r2))))))

  (define incomplete-bldgs-rev
          (let loop-gw ([rem gateways] [inc incomplete-pc-rev])
            (if (null? rem)
                inc
                (let ([g (car rem)])
                  (loop-gw (cdr rem) (if (u-complete? g) inc (cons g inc)))))))

        ;; 1. Cancel under-fire dying forward proxy buildings (`314`) using SC2 construction
        ;;    vitality (`0.10 + 0.90*progress`, shield-inclusive), wedge Pylons after push, or
        ;;    redundant low-ground bait Pylons. NEVER cancel home/natural/third structures.
        ;;    + Printf (`printf-cancel-and-rewall`): step 1.5 tiles back toward defended Cannon/home
        (for ([b (in-list (reverse incomplete-bldgs-rev))])
          (define bid (u-id b))
          (define bkx (u-x b bx))
          (define bky (u-y b by))
          (define d2-b-enemy (fast-dist2 bkx bky ex ey))
          (define d2-b-home (fast-dist2 bkx bky bx by))
          (define forward-proxy?
            (and (< d2-b-enemy 1764.0)  ;; dist-to-enemy < 42.0
                 (> d2-b-home 1225.0))) ;; dist-to-own-main > 35.0
          (define prog (max 0.0 (min 1.0 (u-progress b 1.0))))
          (define expected-vitality-frac (+ 0.10 (* 0.90 prog)))
          (define actual-vitality-frac (u-actual-vitality-frac b))
          (define low-hp?
            (and forward-proxy?
                 (< actual-vitality-frac (* 0.35 expected-vitality-frac))
                 (< actual-vitality-frac 0.12)
                 (enemy-weapon-attacker-near? bkx bky 9.0)))
          (define push-wedge? (and forward-proxy? (eq? (obs-ref b 'push-wedge? #f) #t)))
          (define redundant-bait?
            (and forward-proxy? (eq? (obs-ref b 'low-ground-bait? #f) #t) completed-hg-pylon?))
          (when (or low-hp? push-wedge? redundant-bait?)
            (emit! (list 'cancel-building bid))
            (when low-hp?
              (when (or (> d2-b-home 676.0)
                        (pair? forward-cannons))
                (define-values (back-x back-y)
                  (let loop ([cs forward-cannons] [best-d2 +inf.0] [tx bx] [ty by])
                    (if (null? cs)
                        (values tx ty)
                        (let* ([c (car cs)]
                               [cid (u-id c)])
                          (if (= cid bid)
                              (loop (cdr cs) best-d2 tx ty)
                              (let* ([cx (u-x c bx)]
                                     [cy (u-y c by)]
                                     [d2-ce (fast-dist2 cx cy ex ey)])
                                (if (and (> d2-ce d2-b-enemy)
                                         (< (fast-dist2 bkx bky cx cy) best-d2))
                                    (loop (cdr cs) (fast-dist2 bkx bky cx cy) cx cy)
                                    (loop (cdr cs) best-d2 tx ty))))))))
                (define-values (rx ry) (step-from-to bkx bky back-x back-y 1.5))
                (emit! (list 'printf-rewall-1hex-back 'pylon rx ry))))))

        ;; 2. Forward Probe scan: `push-probe-with-building` + Printf `printf-two-probe-tandem` / `printf-lg-pylon-hg-cannon`
        (define-values (forward-probes near-enemy-probes)
          (let loop-pr ([rem probes] [fp '()] [np '()])
            (if (null? rem)
                (values (reverse fp) (reverse np))
                (let* ([pr (car rem)]
                       [ppx (u-x pr bx)]
                       [ppy (u-y pr by)]
                       [d2-home (fast-dist2 ppx ppy bx by)])
                  (if (> d2-home 676.0)
                      (begin
                        (emit-assimilator-wedge-if-flagged! pr ex ey emit!)
                        (when (> d2-home 784.0)
                          (define seam-blocked?
                            (or (eq? (obs-ref pr 'seam-blocked? #f) #t)
                                (>= (cloud-count-within? (get-eu-cld) ppx ppy 1.6 2) 2)))
                          (when seam-blocked?
                            (define pid (u-id pr))
                            (define-values (sx sy) (step-from-to ppx ppy ex ey 1.25))
                            (define-values (wx wy) (step-from-to ex ey ppx ppy 1.0))
                            (emit! (list 'push-probe-with-building pid 'pylon wx wy sx sy))))
                        (loop-pr (cdr rem)
                                 (cons pr fp)
                                 (if (<= (fast-dist2 ppx ppy ex ey) 1296.0) (cons pr np) np)))
                      (loop-pr (cdr rem) fp np))))))

        ;; Printf Technique 1: 2-Probe tandem / Low-ground Pylon -> High-ground Cannon spotter
        (when (or (and (pair? near-enemy-probes) (pair? (cdr near-enemy-probes)))
                  (and (pair? forward-probes) lg-anchor))
          (define spot-probe
            (cond
              [(and (pair? near-enemy-probes) (pair? (cdr near-enemy-probes)))
               (cadr near-enemy-probes)]
              [(and (pair? forward-probes) (pair? (cdr forward-probes)))
               (cadr forward-probes)]
              [else (car forward-probes)]))
          (define spx (u-x spot-probe ex))
          (define spy (u-y spot-probe ey))
          (define-values (anc-x anc-y)
            (if lg-anchor
                (values (u-x lg-anchor ex) (u-y lg-anchor ey))
                (values spx spy)))
          (define-values (hgx hgy) (step-from-to anc-x anc-y ex ey 4.5))
          (define pid2 (u-id spot-probe))
          (emit! (list 'printf-high-ground-vision-probe pid2 hgx hgy))
          (emit! (list 'move pid2 hgx hgy))
          (when lg-anchor
            (emit! (list 'printf-lg-pylon-hg-cannon (u-id lg-anchor) hgx hgy))))

        ;; 3. Protective 3-Pylon / Gateway cage around warping forward Cannons
        (when (pair? forward-cannons)
          (define cage-pool (bucket-pos-ids ab-ht '(pylon gateway)))
          (for ([c (in-list forward-cannons)])
            (define cx (u-x c ex))
            (define cy (u-y c ey))
            (emit-assimilator-wedge-if-flagged! c ex ey emit!)
            (define cage-cnt
              (for/sum ([cp (in-list cage-pool)])
                (if (<= (fast-dist2 cx cy (u-x cp 9999.0) (u-y cp 9999.0)) 10.24) 1 0)))
            (when (< cage-cnt 3)
              (define offsets '((-2.0 . 0.0) (0.0 . 2.0) (2.0 . -1.0)))
              (define off (list-ref offsets (remainder cage-cnt 3)))
              (emit! (list 'build 'pylon (clamp-coord (+ cx (car off))) (clamp-coord (+ cy (cdr off))))))))

        ;; Printf Technique 3: 3-Pylon ramp block (worker pull >= 4 or enemy CC/Hatch <= 16.0t) & top-level assimilator wedge
        (define fwd-anchor
          (cond
            [(pair? forward-cannons) (car forward-cannons)]
            [(pair? forward-pylons) (car forward-pylons)]
            [(pair? near-enemy-probes) (car near-enemy-probes)]
            [else #f]))
        (when fwd-anchor
          (define fx (u-x fwd-anchor ex))
          (define fy (u-y fwd-anchor ey))
          (when obs (emit-assimilator-wedge-if-flagged! obs ex ey emit!))
          (define eu-ht (sd-index-enemy-u-by-type idx))
          (define eb-ht (sd-index-enemy-b-by-type idx))
          (define pulled-workers
            (let loop ([syms '(scv probe drone)] [cnt 0])
              (cond
                [(or (null? syms) (>= cnt 4)) cnt]
                [else
                 (define ncnt
                   (let wloop ([ws (hash-ref eu-ht (car syms) '())] [c cnt])
                     (cond
                       [(or (null? ws) (>= c 4)) c]
                       [else
                        (define ew (car ws))
                        (if (or (eq? (obs-ref ew 'pulling? #f) #t)
                                (<= (fast-dist2 (u-x ew 9999.0) (u-y ew 9999.0) fx fy) 324.0))
                            (wloop (cdr ws) (fx+ c 1))
                            (wloop (cdr ws) c))])))
                 (loop (cdr syms) ncnt)])))
          (define near-enemy-th?
            (and (< pulled-workers 4)
                 (for/or ([tsym (in-list *printf-enemy-th-structs*)])
                   (for/or ([th (in-list (hash-ref eb-ht tsym '()))])
                     (<= (fast-dist2 (u-x th 9999.0) (u-y th 9999.0) fx fy) 256.0)))))
          (when (or (>= pulled-workers 4) near-enemy-th?)
            (define mx (clamp-coord (* 0.5 (+ bx ex))))
            (define my (clamp-coord (* 0.5 (+ by ey))))
            (define use-nat?
              (and (not (and (= nx bx) (= ny by)))
                   (<= (fast-dist2 nx ny ex ey) (fast-dist2 mx my ex ey))))
            (define rx (if use-nat? (clamp-coord nx) mx))
            (define ry (if use-nat? (clamp-coord ny) my))
            (emit! (list 'printf-3pylon-ramp-block rx ry))
            (emit! (list 'build 'pylon rx ry))))

        ;; Printf Technique 4: Cannon focus fire (7.0 range = 49.0 dist2)
        (when (pair? ready-fwd-cannons)
          (define ready-ids
            (for/list ([rc (in-list ready-fwd-cannons)]) (u-id rc)))
          (define eb-ht (sd-index-enemy-b-by-type idx))
          (define cld (get-eu-cld))
          (define best-tgt #f)
          (define best-tier 4)
          (define best-eff-hp +inf.0)
          (for ([rc (in-list ready-fwd-cannons)])
            (define rcx (u-x rc bx))
            (define rcy (u-y rc by))
            (for ([eu (in-list (cloud-entities-within cld rcx rcy 7.0))])
              (define tier
                (if (and (eq? (u-sym eu) 'scv)
                         (or (eq? (obs-ref eu 'building-bunker? #f) #t)
                             (eq? (obs-ref eu 'repairing? #f) #t)))
                    1
                    2))
              (define eff-hp (+ (u-hp eu 100.0) (u-shield eu 0.0)))
              (when (or (< tier best-tier)
                        (and (= tier best-tier) (< eff-hp best-eff-hp)))
                (set! best-tgt eu)
                (set! best-tier tier)
                (set! best-eff-hp eff-hp)))
            (when (> best-tier 2)
              (for ([dsym (in-list *printf-def-structs*)])
                (for ([db (in-list (hash-ref eb-ht dsym '()))]
                      #:when (and (not (u-complete? db))
                                  (<= (fast-dist2 rcx rcy (u-x db 9999.0) (u-y db 9999.0)) 49.0)))
                  (define eff-hp (+ (u-hp db 200.0) (u-shield db 0.0)))
                  (when (or (< 3 best-tier) (< eff-hp best-eff-hp))
                    (set! best-tgt db)
                    (set! best-tier 3)
                    (set! best-eff-hp eff-hp))))))
          (when best-tgt
            (emit! (list 'cannon-focus-fire ready-ids (u-id best-tgt)))))

        ;; Printf Technique 5: 1-Base Follow-Up Contain Transitions (Robo Immortal/Prism & Stargate Tempest/Void+Battery)
        (when (and (or (and (has-bucket? ab-ht '(shield-battery))
                            (has-bucket? au-ht '(immortal warp-prism warp-prism-phasing stalker void-ray tempest)))
                       (and (has-bucket? au-ht '(warp-prism warp-prism-phasing))
                            (has-bucket? au-ht '(immortal stalker))))
                   (or (pair? forward-cannons)
                       (pair? forward-pylons)
                       (for/or ([sym (in-list '(gateway shield-battery robotics-facility stargate))])
                         (for/or ([b (in-list (hash-ref ab-ht sym '()))])
                           (> (fast-dist2 (u-x b bx) (u-y b by) bx by) 676.0)))))
          (define fwd-bats-rev '())
          (for ([sb (in-list (hash-ref ab-ht 'shield-battery '()))])
            (when (> (fast-dist2 (u-x sb bx) (u-y sb by) bx by) 676.0)
              (set! fwd-bats-rev (cons sb fwd-bats-rev))))
          (define fwd-bats (reverse fwd-bats-rev))
          (define fwd-immortals
            (for/list ([u (in-list (hash-ref au-ht 'immortal '()))]
                       #:when (> (fast-dist2 (u-x u bx) (u-y u by) bx by) 676.0))
              u))
          (define fwd-stalkers
            (for/list ([u (in-list (hash-ref au-ht 'stalker '()))]
                       #:when (> (fast-dist2 (u-x u bx) (u-y u by) bx by) 676.0))
              u))
          (define fwd-voids
            (for/list ([u (in-list (hash-ref au-ht 'void-ray '()))]
                       #:when (> (fast-dist2 (u-x u bx) (u-y u by) bx by) 676.0))
              u))
          (define fwd-tempests
            (for/list ([u (in-list (hash-ref au-ht 'tempest '()))]
                       #:when (> (fast-dist2 (u-x u bx) (u-y u by) bx by) 676.0))
              u))
          (define fwd-prisms
            (for/fold ([acc '()] #:result (reverse acc))
                      ([sym (in-list '(warp-prism warp-prism-phasing))])
              (for/fold ([a2 acc])
                        ([u (in-list (hash-ref au-ht sym '()))]
                         #:when (> (fast-dist2 (u-x u bx) (u-y u by) bx by) 676.0))
                (cons u a2))))

          (when (pair? fwd-bats)
            (when (or (pair? fwd-immortals) (pair? fwd-prisms))
              (define anchor (if (pair? fwd-immortals) (car fwd-immortals) (car fwd-prisms)))
              (emit! (list 'printf-robo-immortal-prism-contain (u-id anchor))))
            (when (or (pair? fwd-tempests) (pair? fwd-voids))
              (define anchor (if (pair? fwd-tempests) (car fwd-tempests) (car fwd-voids)))
              (emit! (list 'printf-stargate-tempest-battery-contain (u-id anchor))))
            ;; Shield-Battery leash retreat (`shield-frac < 0.40` -> <= 6.0 tiles of forward Shield Battery)
            (for ([lst (in-list (list fwd-immortals fwd-stalkers fwd-voids fwd-tempests))])
              (for ([u (in-list lst)]
                    #:when (< (u-shield-frac u) 0.40))
                (define ux (u-x u ex))
                (define uy (u-y u ey))
                (define-values (best-sb best-d2)
                  (for/fold ([bs #f] [bd2 +inf.0])
                            ([sb (in-list fwd-bats)])
                    (define d2 (fast-dist2 ux uy (u-x sb ex) (u-y sb ey)))
                    (if (< d2 bd2) (values sb d2) (values bs bd2))))
                (when best-sb
                  (define sbx (u-x best-sb ex))
                  (define sby (u-y best-sb ey))
                  (define-values (lx ly)
                    (if (> best-d2 36.0)
                        (step-from-to sbx sby ux uy 5.5)
                        (values (clamp-coord ux) (clamp-coord uy))))
                  (define uid (u-id u))
                  (emit! (list 'printf-battery-contain-leash uid (u-id best-sb) lx ly))
                  (emit! (list 'move uid lx ly))))))

          ;; Warp Prism pickup juggle around Immortal/Stalker under Bile / Splash danger (<= 4.5t = 20.25)
          (when (and (pair? fwd-prisms) (or (pair? fwd-immortals) (pair? fwd-stalkers)))
            (define hazards (collect-hazard-points idx))
            (for ([lst (in-list (list fwd-immortals fwd-stalkers))])
              (for ([u (in-list lst)])
                (define ux (u-x u ex))
                (define uy (u-y u ey))
                (define in-danger?
                  (or (eq? (obs-ref u 'under-bile? #f) #t)
                      (eq? (obs-ref u 'in-splash? #f) #t)
                      (eq? (obs-ref u 'under-danger? #f) #t)
                      (for/or ([hp (in-list hazards)])
                        (<= (fast-dist2 ux uy (car hp) (cdr hp)) 20.25))))
                (when in-danger?
                  (define-values (best-pr _bd2)
                    (for/fold ([bp #f] [bd2 +inf.0])
                              ([pr (in-list fwd-prisms)]
                               #:when (< (u-cargo-used pr) (max 4 (u-cargo-max pr 4))))
                      (define d2 (fast-dist2 ux uy (u-x pr ex) (u-y pr ey)))
                      (if (< d2 bd2) (values pr d2) (values bp bd2))))
                  (when best-pr
                    (define prism-id (u-id best-pr))
                    (define uid (u-id u))
                    (emit! (list 'printf-prism-contain-pickup prism-id uid))
                    (emit! (list 'load-unit prism-id uid))))))))

        (reverse actions))))

(define (plan-pro-cannon-rush-tactics raw-obs)
  (define obs (ensure-obs raw-obs))
  (plan-pro-cannon-rush-tactics/idx (build-sd-index obs) obs))

(define (strip-used-workers workers used-ht)
  (for/fold ([acc '()] #:result (reverse acc))
            ([w (in-list workers)])
    (if (hash-has-key? used-ht (u-id w)) acc (cons w acc))))

(define (plan-counter-cannon-rush-tactics/idx idx [obs #f])
  (define eu-ht (sd-index-enemy-u-by-type idx))
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (if (not (or (hash-has-key? eu-ht 'probe)
               (hash-has-key? eb-ht 'photon-cannon)
               (hash-has-key? eb-ht 'pylon)))
      '()
      (let ()
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define race-sym (if obs (obs-ref obs 'race 'Unknown) 'Unknown))
        (define nearby-probes (entities-within bx by 44.0 (hash-ref eu-ht 'probe '())))
        (define raw-cannons (entities-within bx by 44.0 (hash-ref eb-ht 'photon-cannon '())))
        (define nearby-cannons
          (if (and (pair? raw-cannons) (pair? (cdr raw-cannons)))
              (sort raw-cannons (lambda (a b) (< (u-progress a 1.0) (u-progress b 1.0))))
              raw-cannons))
        (define nearby-pylons (entities-within bx by 44.0 (hash-ref eb-ht 'pylon '())))

        (if (and (null? nearby-probes) (null? nearby-cannons) (null? nearby-pylons))
            '()
            (let ()
              (define avail-workers (sd-index-ally-workers idx))
              (define used-ht (make-hasheq))
              (define actions '())
              (define (emit! a) (set! actions (cons a actions)))
              (define any-warping-cannon?
                (for/or ([c (in-list nearby-cannons)])
                  (< (u-progress c 1.0) SC2-BUILD-COMPLETE-PROGRESS)))
              (define target-pylons
                (if any-warping-cannon?
                    (for/fold ([acc '()] #:result (reverse acc))
                              ([py (in-list nearby-pylons)]
                               #:when (not (eq? (obs-ref py 'low-ground-bait? #f) #t)))
                      (cons py acc))
                    nearby-pylons))
              (define wall-pool (bucket-pos-ids eb-ht *printf-wall-structs*))

              ;; 1. Chase enemy Probes: 1 dedicated chaser per Probe (`printf-multi-probe-chase` when >= 2)
              (when (and (pair? nearby-probes) (pair? avail-workers))
                (define multi-probes? (pair? (cdr nearby-probes)))
                (for ([ep (in-list nearby-probes)]
                      #:when (pair? avail-workers))
                  (define chaser (nearest-entity-to (u-x ep bx) (u-y ep by) avail-workers))
                  (when chaser
                    (hash-set! used-ht (u-id chaser) #t)
                    (set! avail-workers (strip-used-workers avail-workers used-ht))
                    (when multi-probes?
                      (emit! (list 'printf-multi-probe-chase (u-id chaser) (u-id ep))))
                    (emit! (list 'attack-unit (u-id chaser) (u-id ep))))))

              ;; 2. Anti-trap abort for >= 3-wall or complete Cannons; otherwise pull 3-4 workers per warping Cannon
              (define aborted-walled-cannon? #f)
              (for ([c (in-list nearby-cannons)])
                (define cx (u-x c bx))
                (define cy (u-y c by))
                (define adj-wall-cnt
                  (let loop ([ws wall-pool] [cnt 0])
                    (cond
                      [(or (null? ws) (>= cnt 3)) cnt]
                      [else
                       (define w (car ws))
                       (if (<= (fast-dist2 cx cy (u-x w 9999.0) (u-y w 9999.0)) 12.25)
                           (loop (cdr ws) (fx+ cnt 1))
                           (loop (cdr ws) cnt))])))
                (cond
                  [(or (>= adj-wall-cnt 3) (u-complete? c))
                   (set! aborted-walled-cannon? #t)
                   (emit! (list 'printf-abort-walled-cannon-pull (u-id c)))]
                  [else
                   (define need-cnt (if (< (u-progress c 1.0) 0.65) 4 3))
                   (define squad (k-nearest-to cx cy need-cnt avail-workers 30.0))
                   (when (pair? squad)
                     (for ([w (in-list squad)]) (hash-set! used-ht (u-id w) #t))
                     (set! avail-workers (strip-used-workers avail-workers used-ht))
                     (emit! (list 'pull-workers-attack (map u-id squad) (u-id c) cx cy)))
                   (define blocker (nearest-entity-to (+ cx 2.0) cy avail-workers))
                   (when blocker
                     (hash-set! used-ht (u-id blocker) #t)
                     (set! avail-workers (strip-used-workers avail-workers used-ht))
                     (emit! (list 'hold-position (u-id blocker) (clamp-coord (+ cx 2.0)) (clamp-coord cy))))]))

              ;; When walled/complete cannon abort triggers, return spare workers to mineral mining
              (when (and aborted-walled-cannon? (pair? avail-workers))
                (define spare-ids (for/list ([w (in-list avail-workers)]) (u-id w)))
                (emit! (list 'return-workers-to-gather spare-ids bx by)))

              ;; If only non-bait Pylon exists with no Cannons yet, hit Pylon with 3 workers
              (when (and (null? nearby-cannons) (pair? target-pylons) (pair? avail-workers))
                (define py (first target-pylons))
                (define px (u-x py bx))
                (define pyy (u-y py by))
                (define squad (k-nearest-to px pyy 3 avail-workers 30.0))
                (when (pair? squad)
                  (emit! (list 'pull-workers-attack (map u-id squad) (u-id py) px pyy))))

              ;; Follow-up ranged counters: Ravager Bile / Tank Siege / Cyclone Lock-On / Bunker + SCV Swap / Spine 7.2t / Stalker + Battery + Overcharge
              (define first-tgt
                (cond
                  [(pair? nearby-cannons) (first nearby-cannons)]
                  [(pair? target-pylons) (first target-pylons)]
                  [else #f]))
              (when first-tgt
                (define tx (u-x first-tgt bx))
                (define ty (u-y first-tgt by))
                (define tid (u-id first-tgt))
                (define au-ht (sd-index-ally-u-by-type idx))
                (define ab-ht (sd-index-ally-b-by-type idx))
                (for ([act (in-list (find-aoe-helper-cast/idx idx tx ty))]) (emit! act))
                (for ([tk (in-list (bucket-pos-ids au-ht '(siege-tank)))])
                  (define tkx (u-x tk tx))
                  (define tky (u-y tk ty))
                  (define d2-tk (fast-dist2 tkx tky tx ty))
                  (when (and aborted-walled-cannon? (or (< d2-tk 56.25) (> d2-tk 169.0)))
                    (define-values (sx sy) (step-from-to tx ty bx by 12.5))
                    (emit! (list 'move (u-id tk) sx sy)))
                  (emit! (list 'cast-spell (u-id tk) 'siege-mode)))
                (for ([tk (in-list (bucket-pos-ids au-ht '(siege-tank-sieged)))])
                  (emit! (list 'attack-unit (u-id tk) tid)))
                (for ([cyc (in-list (bucket-pos-ids au-ht '(cyclone)))])
                  (emit! (list 'cast-spell (u-id cyc) 'lock-on tid)))
                (for ([st (in-list (bucket-pos-ids au-ht '(stalker)))])
                  (emit! (list 'attack-unit (u-id st) tid)))
                ;; Race-specific ranged / Printf static pivots
                (if aborted-walled-cannon?
                    (let ()
                      ;; Zerg: Spine Crawler rooted outside Cannon 7.0 range at 7.2 tiles
                      (when (or (eq? race-sym 'Zerg)
                                (hash-has-key? au-ht 'drone) (hash-has-key? ab-ht 'hatchery)
                                (hash-has-key? ab-ht 'lair) (hash-has-key? ab-ht 'hive))
                        (define-values (spx spy) (step-from-to tx ty bx by 7.2))
                        (emit! (list 'build 'spine-crawler spx spy))
                        (for ([sp (in-list (append (bucket-pos-ids ab-ht '(spine-crawler))
                                                   (bucket-pos-ids au-ht '(spine-crawler-uprooted))))])
                          (when (< (fast-dist2 tx ty (u-x sp bx) (u-y sp by)) 49.0)
                            (emit! (list 'spine-crawler-uproot (u-id sp)))
                            (emit! (list 'spine-crawler-root (u-id sp) spx spy)))))
                      ;; Terran: High-ground Bunker + swap-bunker-builder-scv if builder damaged
                      (when (or (eq? race-sym 'Terran)
                                (hash-has-key? au-ht 'scv) (hash-has-key? ab-ht 'command-center)
                                (hash-has-key? ab-ht 'orbital-command) (hash-has-key? ab-ht 'barracks))
                        (define bunkers (hash-ref ab-ht 'bunker '()))
                        (when (null? bunkers)
                          (define-values (bkx bky) (step-from-to tx ty bx by 8.5))
                          (emit! (list 'build 'bunker bkx bky)))
                        (define scvs (hash-ref au-ht 'scv '()))
                        (for ([bnk (in-list bunkers)]
                              #:when (not (u-complete? bnk)))
                          (define low-scv
                            (for/or ([s (in-list scvs)])
                              (and (or (eq? (obs-ref s 'building-bunker? #f) #t)
                                       (<= (fast-dist2 (u-x s bx) (u-y s by) (u-x bnk bx) (u-y bnk by)) 9.0))
                                   (< (u-hp-frac s) 0.55)
                                   s)))
                          (when low-scv
                            (define fresh-scv
                              (for/or ([s (in-list scvs)])
                                (and (not (= (u-id s) (u-id low-scv)))
                                     (>= (u-hp-frac s) 0.70)
                                     s)))
                            (when fresh-scv
                              (emit! (list 'swap-bunker-builder-scv (u-id low-scv) (u-id fresh-scv) (u-id bnk)))))))
                      ;; Protoss: Shield Battery + Nexus Battery Overcharge
                      (when (or (eq? race-sym 'Protoss)
                                (hash-has-key? ab-ht 'nexus) (hash-has-key? au-ht 'probe))
                        (define bats (hash-ref ab-ht 'shield-battery '()))
                        (define nexs (hash-ref ab-ht 'nexus '()))
                        (when (null? bats)
                          (define-values (sbx sby) (step-from-to bx by tx ty 4.5))
                          (emit! (list 'build 'shield-battery sbx sby)))
                        (when (and (pair? bats) (pair? nexs))
                          (define ready-nex
                            (for/or ([n (in-list nexs)])
                              (and (u-complete? n) (>= (u-energy n 0.0) 50.0) n)))
                          (when ready-nex
                            (emit! (list 'cast-spell (u-id ready-nex) 'battery-overcharge (u-id (car bats))))))))
                    (emit-cannon-counter-zerg-spine? idx bx by emit!)))
              (reverse actions))))))

(define (emit-cannon-counter-zerg-spine? idx bx by emit!)
  (define au-ht (sd-index-ally-u-by-type idx))
  (define ab-ht (sd-index-ally-b-by-type idx))
  (when (or (hash-has-key? au-ht 'drone) (hash-has-key? ab-ht 'hatchery)
            (hash-has-key? ab-ht 'lair) (hash-has-key? ab-ht 'hive))
    (emit! (list 'build 'spine-crawler (clamp-coord (+ bx 5.0)) (clamp-coord (+ by 5.0))))))

(define (plan-counter-cannon-rush-tactics raw-obs)
  (define obs (ensure-obs raw-obs))
  (define idx (build-sd-index obs))
  (define acts (plan-counter-cannon-rush-tactics/idx idx obs))
  ;; Preserve exact race='Zerg explicit trigger even when obs has no drones/hatcheries
  (if (and (eq? (obs-ref obs 'race 'Unknown) 'Zerg)
           (pair? acts)
           (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts)))
      (let-values ([(bx by) (home-xy obs)])
        (append acts (list (list 'build 'spine-crawler (clamp-coord (+ bx 5.0)) (clamp-coord (+ by 5.0))))))
      acts))

;; -----------------------------------------------------------------------------
;; 3c. Photon Cannon Tactics <-> Counter Photon Cannon Tactics
;; -----------------------------------------------------------------------------

(define (plan-photon-cannon-tactics/idx idx)
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define cannons (bucket-pos-ids ab-ht '(photon-cannon)))
  (if (null? cannons)
      '()
      (let ()
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define batteries (bucket-pos-ids ab-ht '(shield-battery)))
        (define pylons (bucket-pos-ids ab-ht '(pylon)))
        (define local-pool (append cannons batteries))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (for ([c (in-list cannons)])
          (define cx (u-x c bx))
          (define cy (u-y c by))
          (when (not (any-entity-within? cx cy 5.0 batteries))
            (define-values (sbx sby) (step-from-to cx cy bx by 3.0))
            (emit! (list 'build 'shield-battery sbx sby)))
          (define powering-cnt
            (for/sum ([p (in-list pylons)])
              (if (<= (fast-dist2 cx cy (u-x p 9999.0) (u-y p 9999.0)) 42.25) 1 0)))
          (when (= powering-cnt 1)
            (define def-cnt
              (for/sum ([d (in-list local-pool)])
                (if (<= (fast-dist2 cx cy (u-x d 9999.0) (u-y d 9999.0)) 42.25) 1 0)))
            (when (>= def-cnt 2)
              (define-values (px py) (step-from-to cx cy bx by 4.0))
              (emit! (list 'build 'pylon px py)))))

        (reverse actions))))

(define (plan-photon-cannon-tactics raw-obs)
  (plan-photon-cannon-tactics/idx (build-sd-index raw-obs)))

(define (plan-counter-photon-cannon-tactics/idx idx)
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (define e-cannons (bucket-pos-ids eb-ht '(photon-cannon)))
  (if (null? e-cannons)
      '()
      (let ()
        (define e-batteries (bucket-pos-ids eb-ht '(shield-battery)))
        (define e-pylons (bucket-pos-ids eb-ht '(pylon)))
        (define attackers (sd-index-ally-combat idx))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))
        (define e-def-pool (append e-cannons e-batteries))
        (define artosis-pylons
          (filter (lambda (py)
                    (define px (u-x py 0.0))
                    (define pyy (u-y py 0.0))
                    (define powered-cnt
                      (for/sum ([d (in-list e-def-pool)])
                        (if (<= (fast-dist2 px pyy (u-x d 9999.0) (u-y d 9999.0)) 42.25) 1 0)))
                    (and (>= powered-cnt 2)
                         (<= (for/sum ([ep (in-list e-pylons)])
                               (if (<= (fast-dist2 px pyy (u-x ep 9999.0) (u-y ep 9999.0)) 42.25) 1 0))
                             1)))
                  e-pylons))
        (cond
          [(and (pair? artosis-pylons) (pair? attackers))
           (define ap (first artosis-pylons))
           (emit! (list 'focus-fire (map u-id attackers) (u-id ap)))]
          [(pair? e-cannons)
           (define tc (first e-cannons))
           (define cx (u-x tc 0.0))
           (define cy (u-y tc 0.0))
           (for ([act (in-list (find-aoe-helper-cast/idx idx cx cy))]) (emit! act))
           (for ([su (in-list (bucket-pos-ids (sd-index-ally-u-by-type idx)
                                              '(siege-tank siege-tank-sieged lurker tempest brood-lord disruptor)))])
             (define sx (u-x su cx))
             (define sy (u-y su cy))
             (when (< (fast-dist2 sx sy cx cy) 56.25)
               (define-values (rx ry) (step-from-to cx cy sx sy 8.5))
               (emit! (list 'move (u-id su) rx ry)))
             (when (eq? (u-sym su) 'siege-tank)
               (emit! (list 'cast-spell (u-id su) 'siege-mode)))
             (emit! (list 'attack-unit (u-id su) (u-id tc))))])
        (reverse actions))))

(define (plan-counter-photon-cannon-tactics raw-obs)
  (plan-counter-photon-cannon-tactics/idx (build-sd-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 3d. Bunker Tactics <-> Counter Bunker Tactics
;; -----------------------------------------------------------------------------

(define (plan-bunker-tactics/idx idx)
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define bunkers (bucket-pos-ids ab-ht '(bunker)))
  (if (null? bunkers)
      '()
      (let ()
        (define frame (sd-index-frame idx))
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define au-ht (sd-index-ally-u-by-type idx))
        (define eu-cld (ensure-eu-cloud! idx))
        (define effects (sd-index-effects idx))
        (define scvs (bucket-pos-ids au-ht '(scv)))
        (define bio (bucket-pos-ids au-ht '(marine marauder reaper ghost)))
        (define aoe-pts
          (for/fold ([acc '()] #:result (reverse acc))
                    ([ef (in-list effects)]
                     #:when (and (hash? ef)
                                 (let* ([rt (hash-ref ef 'type *missing*)]
                                        [t (if (eq? rt *missing*) (obs-ref ef 'name 'unknown) rt)])
                                   (memq (fast-canon-unit
                                          (cond [(symbol? t) t] [(string? t) (string->symbol (string-downcase t))] [else 'unknown]))
                                         '(corrosive-bile psi-storm nuke purification-nova blinding-cloud)))))
            (cons (cons (u-x ef 9999.0) (u-y ef 9999.0)) acc)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (for ([bk (in-list bunkers)]
              #:when (u-complete? bk))
          (define bid (u-id bk))
          (define bkx (u-x bk bx))
          (define bky (u-y bk by))
          (define-values (near8? near20?)
            (cloud-near-flags eu-cld bkx bky 8.0 20.0))
          (define cargo (u-cargo-used bk))
          (define cap (max 4 (u-cargo-max bk 4)))
          (define near-aoe?
            (and (pair? aoe-pts)
                 (for/or ([pt (in-list aoe-pts)])
                   (<= (fast-dist2 bkx bky (car pt) (cdr pt)) 6.25))))

          (cond
            [near-aoe?
             (emit! (list 'bunker-unload bid))]
            [(and near8? (< cargo cap))
             (for ([inf (in-list (k-nearest-to bkx bky (- cap cargo) bio 10.0))])
               (emit! (list 'bunker-load bid (u-id inf))))]
            [(and (not near8?) (> cargo 0) near20?)
             (emit! (list 'bunker-unload bid))]
            [(and (not near20?)
                  (= cargo 0)
                  (or (> frame 4200) (eq? (obs-ref bk 'abandoned? #f) #t)))
             (emit! (list 'salvage bid))])

          ;; Pull 3-6 SCVs auto-repair (`316`) when Bunker < 90% HP or under fire
          (when (and (not (and (not near20?) (> frame 4200)))
                     (or (< (u-hp-frac bk) 0.90) near8?))
            (define repairers (k-nearest-to bkx bky 6 scvs 18.0))
            (for ([s (in-list repairers)])
              (emit! (list 'repair (u-id s) bid)))))

        (reverse actions))))

(define (plan-bunker-tactics raw-obs)
  (plan-bunker-tactics/idx (build-sd-index raw-obs)))

(define (plan-counter-bunker-tactics/idx idx)
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (define e-bunkers (bucket-pos-ids eb-ht '(bunker)))
  (if (null? e-bunkers)
      '()
      (let ()
        (define e-scvs (bucket-pos-ids (sd-index-enemy-u-by-type idx) '(scv)))
        (define attackers (sd-index-ally-combat idx))
        (define sentry
          (for/or ([u (in-list (hash-ref (sd-index-ally-u-by-type idx) 'sentry '()))])
            (and (> (u-id u) 0) (>= (u-energy u 0.0) 50.0) u)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))
        (for ([bk (in-list e-bunkers)])
          (define bkx (u-x bk 0.0))
          (define bky (u-y bk 0.0))
          (define repairing-scvs (entities-within bkx bky 4.5 e-scvs))
          (when (pair? repairing-scvs)
            (define lead-scv (first repairing-scvs))
            (when (pair? attackers)
              (emit! (list 'focus-fire (map u-id attackers) (u-id lead-scv))))
            (for ([act (in-list (find-aoe-helper-cast/idx idx (u-x lead-scv bkx) (u-y lead-scv bky)))])
              (emit! act))
            (when sentry
              (emit! (list 'cast-spell (u-id sentry) 'force-field (u-x lead-scv bkx) (u-y lead-scv bky))))))
        (reverse actions))))

(define (plan-counter-bunker-tactics raw-obs)
  (plan-counter-bunker-tactics/idx (build-sd-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 3e. Missile Turret Tactics <-> Counter Missile Turret Tactics
;; -----------------------------------------------------------------------------

(define (plan-missile-turret-tactics/idx idx)
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define turrets (bucket-pos-ids ab-ht '(missile-turret)))
  (define air-threats (sd-index-enemy-air idx))
  (if (and (null? turrets) (null? air-threats))
      '()
      (let ()
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define nx (sd-index-nx idx))
        (define ny (sd-index-ny idx))
        (define au-ht (sd-index-ally-u-by-type idx))
        (define tanks (bucket-pos-ids au-ht '(siege-tank siege-tank-sieged)))
        (define scvs (bucket-pos-ids au-ht '(scv)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (when (and (pair? air-threats) (not (any-entity-within? bx by 9.0 turrets)))
          (emit! (list 'build 'missile-turret (clamp-coord (- bx 4.0)) (clamp-coord (- by 4.0)))))
        (when (and (pair? air-threats) (pair? tanks))
          (define t0 (first tanks))
          (define tx (u-x t0 nx))
          (define ty (u-y t0 ny))
          (when (not (any-entity-within? tx ty 8.0 turrets))
            (emit! (list 'build 'missile-turret (clamp-coord (- tx 3.0)) (clamp-coord (+ ty 3.0))))))

        (for ([mt (in-list turrets)]
              #:when (< (u-hp-frac mt) 0.95))
          (for ([s (in-list (k-nearest-to (u-x mt bx) (u-y mt by) 2 scvs 14.0))])
            (emit! (list 'repair (u-id s) (u-id mt)))))

        (reverse actions))))

(define (plan-missile-turret-tactics raw-obs)
  (plan-missile-turret-tactics/idx (build-sd-index raw-obs)))

(define (plan-counter-missile-turret-tactics/idx idx)
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (define e-turrets (bucket-pos-ids eb-ht '(missile-turret)))
  (if (null? e-turrets)
      '()
      (let ()
        (define ex (sd-index-ex idx))
        (define ey (sd-index-ey idx))
        (define air-units (sd-index-ally-air idx))
        (define eu-cld (ensure-eu-cloud! idx))
        ;; Check isolated turret first so non-isolated 200v200 fights skip scanning ally-combat.
        (define isolated-t
          (for/or ([t (in-list e-turrets)])
            (and (<= (cloud-count-within? eu-cld (u-x t ex) (u-y t ey) 6.0 3) 2)
                 t)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (when (pair? air-units)
          (define t0 (first e-turrets))
          (define tx (u-x t0 ex))
          (define ty (u-y t0 ey))
          (define safe-x (clamp-coord (+ ex (- ty ey))))
          (define safe-y (clamp-coord (- ey (- tx ex))))
          (define final-safe
            (if (> (fast-dist2 safe-x safe-y tx ty) 56.25)
                (cons safe-x safe-y)
                (cons (clamp-coord (- ex 11.0)) (clamp-coord (+ ey 11.0)))))
          (emit! (list 'air-route-blind-spot-bypass (car final-safe) (cdr final-safe)))
          (for ([au (in-list air-units)])
            (when (<= (fast-dist2 (u-x au ex) (u-y au ey) tx ty) 72.25)
              (emit! (list 'move (u-id au) (car final-safe) (cdr final-safe))))))

        (when isolated-t
          (define ground-ids
            (for/fold ([g-rev '()] #:result (reverse g-rev))
                      ([u (in-list (sd-index-ally-combat idx))]
                       #:when (not (fast-flying-sym? (u-sym u))))
              (cons (u-id u) g-rev)))
          (when (pair? ground-ids)
            (emit! (list 'focus-fire ground-ids (u-id isolated-t)))))
        (reverse actions))))

(define (plan-counter-missile-turret-tactics raw-obs)
  (plan-counter-missile-turret-tactics/idx (build-sd-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 3f. Planetary Fortress Tactics <-> Counter Planetary Fortress Tactics
;; -----------------------------------------------------------------------------

(define (pf-best-splash-target near-idxs eu-cld)
  (define uv (xy-cloud-units eu-cld))
  (if (null? (cdr near-idxs))
      (vector-ref uv (car near-idxs))
      (let* ([xv (xy-cloud-xs eu-cld)]
             [yv (xy-cloud-ys eu-cld)]
             [n (length near-idxs)]
             [pu (make-vector n #f)]
             [pxv (make-flvector n 0.0)]
             [pyv (make-flvector n 0.0)]
             [sv (make-fxvector n 0)])
        (for ([idx (in-list near-idxs)]
              [i (in-naturals)])
          (define e (vector-ref uv idx))
          (vector-set! pu i e)
          (flvector-set! pxv i (flvector-ref xv idx))
          (flvector-set! pyv i (flvector-ref yv idx))
          (fxvector-set! sv i
                         (if (memq (u-sym e) '(zergling baneling marine zealot hydralisk adept))
                             3
                             2)))
        (for ([i (in-range n)])
          (define xi (flvector-ref pxv i))
          (define yi (flvector-ref pyv i))
          (define acc 0)
          (for ([j (in-range (fx+ i 1) n)])
            (define dx (fl- (flvector-ref pxv j) xi))
            (when (fl<= (flabs dx) 1.25)
              (define dy (fl- (flvector-ref pyv j) yi))
              (when (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 1.5625)
                (set! acc (fx+ acc 1))
                (fxvector-set! sv j (fx+ (fxvector-ref sv j) 1)))))
          (fxvector-set! sv i (fx+ (fxvector-ref sv i) acc)))
        (let loop ([i 0] [best-sc -1] [best-u (vector-ref pu 0)])
          (if (fx>= i n)
              best-u
              (let ([sc (fxvector-ref sv i)])
                (if (fx> sc best-sc)
                    (loop (fx+ i 1) sc (vector-ref pu i))
                    (loop (fx+ i 1) best-sc best-u))))))))

(define (plan-planetary-fortress-tactics/idx idx)
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define ccs (bucket-pos-ids ab-ht '(command-center)))
  (define pfs (bucket-pos-ids ab-ht '(planetary-fortress planetary)))
  (if (and (null? ccs) (null? pfs))
      '()
      (let ()
        (define frame (sd-index-frame idx))
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define eu-cld (ensure-eu-cloud! idx))
        (define scvs (bucket-pos-ids (sd-index-ally-u-by-type idx) '(scv)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (for ([cc (in-list ccs)]
              #:when (u-complete? cc))
          (define ccx (u-x cc bx))
          (define ccy (u-y cc by))
          (when (and (> (fast-dist2 ccx ccy bx by) 484.0)
                     (or (>= frame 4500)
                         (cloud-any-within? eu-cld ccx ccy 18.0)))
            (emit! (list 'morph (u-id cc) 'planetary-fortress))))

        (for ([pf (in-list pfs)])
          (define pfid (u-id pf))
          (define pfx (u-x pf bx))
          (define pfy (u-y pf by))
          (define-values (near-6-idxs near-10?)
            (cloud-near-collect-idx+flag eu-cld pfx pfy 6.0 10.0))
          (when (or (< (u-hp-frac pf) 0.96) near-10?)
            (for ([s (in-list (k-nearest-to pfx pfy 14 scvs 18.0))])
              (emit! (list 'repair (u-id s) pfid))))
          (when (pair? near-6-idxs)
            (emit! (list 'focus-fire pfid (u-id (pf-best-splash-target near-6-idxs eu-cld))))))

        (reverse actions))))

(define (plan-planetary-fortress-tactics raw-obs)
  (plan-planetary-fortress-tactics/idx (build-sd-index raw-obs)))

(define (plan-counter-planetary-fortress-tactics/idx idx)
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (define e-pfs (bucket-pos-ids eb-ht '(planetary-fortress planetary)))
  (if (null? e-pfs)
      '()
      (let ()
        (define e-scvs (bucket-pos-ids (sd-index-enemy-u-by-type idx) '(scv)))
        (define au-ht (sd-index-ally-u-by-type idx))
        (define rvn
          (for/or ([u (in-list (hash-ref au-ht 'raven '()))])
            (and (> (u-id u) 0) (>= (u-energy u 0.0) 75.0) u)))
        (define siege-units
          (bucket-pos-ids au-ht '(lurker lurker-burrowed siege-tank siege-tank-sieged
                                  brood-lord immortal tempest disruptor)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))
        (define rvn-id (and rvn (u-id rvn)))
        (define siege-pts
          (if (and (pair? siege-units) (pair? (cdr e-pfs)))
              (for/list ([su (in-list siege-units)])
                (vector (u-id su) (u-x su 0.0) (u-y su 0.0) (eq? (u-sym su) 'siege-tank)))
              #f))
        (for ([pf (in-list e-pfs)]
              [pf-i (in-naturals)])
          (define first-pf? (fx= pf-i 0))
          (define pfid (u-id pf))
          (define pfx (u-x pf 0.0))
          (define pfy (u-y pf 0.0))
          (define scv-ring (entities-within pfx pfy 4.5 e-scvs))
          (define ring-x (if (pair? scv-ring) (u-x (first scv-ring) pfx) pfx))
          (define ring-y (if (pair? scv-ring) (u-y (first scv-ring) pfy) pfy))
          (for ([act (in-list (find-aoe-helper-cast/idx idx ring-x ring-y))]) (emit! act))
          (when rvn-id
            (if (pair? scv-ring)
                (emit! (list 'cast-spell rvn-id 'anti-armor-missile (u-id (first scv-ring))))
                (emit! (list 'cast-spell rvn-id 'interference-matrix pfid))))
          (if siege-pts
              (for ([sp (in-list siege-pts)])
                (define suid (vector-ref sp 0))
                (define sx (vector-ref sp 1))
                (define sy (vector-ref sp 2))
                (when (< (fast-dist2 sx sy pfx pfy) 42.25)
                  (define-values (kx ky) (step-from-to pfx pfy sx sy 7.5))
                  (emit! (list 'move suid kx ky)))
                (when (and first-pf? (vector-ref sp 3))
                  (emit! (list 'cast-spell suid 'siege-mode)))
                (emit! (list 'attack-unit suid pfid)))
              (for ([su (in-list siege-units)])
                (define sx (u-x su pfx))
                (define sy (u-y su pfy))
                (define suid (u-id su))
                (when (< (fast-dist2 sx sy pfx pfy) 42.25)
                  (define-values (kx ky) (step-from-to pfx pfy sx sy 7.5))
                  (emit! (list 'move suid kx ky)))
                (when (and first-pf? (eq? (u-sym su) 'siege-tank))
                  (emit! (list 'cast-spell suid 'siege-mode)))
                (emit! (list 'attack-unit suid pfid)))))
        (reverse actions))))

(define (plan-counter-planetary-fortress-tactics raw-obs)
  (plan-counter-planetary-fortress-tactics/idx (build-sd-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 3g. Shield Battery & Nexus Overcharge / Energy Recharge <-> Counter
;; -----------------------------------------------------------------------------

(define (plan-shield-battery-and-nexus-overcharge-tactics/idx idx)
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define nexuses (bucket-pos-ids ab-ht '(nexus)))
  (define batteries (bucket-pos-ids ab-ht '(shield-battery)))
  (if (and (null? nexuses) (null? batteries))
      '()
      (let ()
        (define complete-bats
          (for/fold ([acc '()] #:result (reverse acc))
                    ([b (in-list batteries)])
            (if (u-complete? b) (cons b acc) acc)))
        (define ready-nexuses
          (for/fold ([acc '()] #:result (reverse acc))
                    ([n (in-list nexuses)])
            (if (and (u-complete? n) (>= (u-energy n 0.0) 50.0)) (cons n acc) acc)))
        (if (and (null? ready-nexuses) (null? complete-bats))
            '()
            (let ()
              (define bx (sd-index-bx idx))
              (define by (sd-index-by idx))
              (define n-bats (length complete-bats))
              (define-values (bat-ids bat-xs bat-ys bat-d65-hits any-d65? damaged-25)
                (if (fx= n-bats 0)
                    (values #f #f #f #f #f '())
                    (let ([ids (make-vector n-bats 0)]
                          [xs (make-flvector n-bats 0.0)]
                          [ys (make-flvector n-bats 0.0)]
                          [hits (make-vector n-bats #f)])
                      (define-values (bminx bmaxx bminy bmaxy)
                        (let loop-bats ([rem complete-bats] [i 0] [x0 +inf.0] [x1 -inf.0] [y0 +inf.0] [y1 -inf.0])
                          (if (null? rem)
                              (values x0 x1 y0 y1)
                              (let* ([b (car rem)]
                                     [x (exact->inexact (u-x b bx))]
                                     [y (exact->inexact (u-y b by))])
                                (vector-set! ids i (u-id b))
                                (flvector-set! xs i x)
                                (flvector-set! ys i y)
                                (loop-bats (cdr rem) (fx+ i 1) (min x0 x) (max x1 x) (min y0 y) (max y1 y))))))
                      (define xlo (fl- (real->double-flonum bminx) 14.0))
                      (define xhi (fl+ (real->double-flonum bmaxx) 14.0))
                      (define ylo (fl- (real->double-flonum bminy) 14.0))
                      (define yhi (fl+ (real->double-flonum bmaxy) 14.0))
                      (define init-rem (if (pair? ready-nexuses) n-bats 0))
                      (let loop-u ([rem (sd-index-ally-combat idx)]
                                   [rem-d65 init-rem]
                                   [any? #f]
                                   [d25-rev '()])
                        (if (null? rem)
                            (values ids xs ys hits any? (reverse d25-rev))
                            (let* ([u (car rem)]
                                   [sf (u-shield-frac u)]
                                   [thresh (if (fx> rem-d65 0) 0.65 0.25)])
                              (if (>= sf thresh)
                                  (loop-u (cdr rem) rem-d65 any? d25-rev)
                                  (let ([ux (real->double-flonum (u-x u bx))]
                                        [uy (real->double-flonum (u-y u by))])
                                    (if (and (fl<= xlo ux) (fl<= ux xhi) (fl<= ylo uy) (fl<= uy yhi))
                                        (let-values ([(nrem nany)
                                                      (if (fx> rem-d65 0)
                                                          (let loop-h ([i 0] [r rem-d65] [a any?])
                                                            (cond
                                                              [(or (fx>= i n-bats) (fx= r 0)) (values r a)]
                                                              [(vector-ref hits i) (loop-h (fx+ i 1) r a)]
                                                              [else
                                                               (let* ([dx (fl- ux (flvector-ref xs i))]
                                                                      [dy (fl- uy (flvector-ref ys i))])
                                                                 (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 64.0)
                                                                     (begin
                                                                       (vector-set! hits i #t)
                                                                       (loop-h (fx+ i 1) (fx- r 1) #t))
                                                                     (loop-h (fx+ i 1) r a)))]))
                                                          (values rem-d65 any?))])
                                          (loop-u (cdr rem)
                                                  nrem
                                                  nany
                                                  (if (< sf 0.25)
                                                      (cons (vector (u-id u) ux uy) d25-rev)
                                                      d25-rev)))
                                        (loop-u (cdr rem) rem-d65 any? d25-rev))))))))))
              (define actions '())
              (define (emit! a) (set! actions (cons a actions)))

              (when (pair? ready-nexuses)
                (define low-caster 'uninit)
                (define (get-low-caster)
                  (when (eq? low-caster 'uninit)
                    (define casters (bucket-pos-ids (sd-index-ally-u-by-type idx)
                                                    '(high-templar oracle sentry mothership)))
                    (set! low-caster
                          (for/or ([c (in-list casters)])
                            (and (< (/ (u-energy c 0.0) (u-max-energy c 200.0)) 0.50) c))))
                  low-caster)
                (for ([nex (in-list ready-nexuses)])
                  (define nid (u-id nex))
                  (define overcharge-target-id
                    (and any-d65?
                         (let ([nxx (exact->inexact (u-x nex bx))]
                               [nxy (exact->inexact (u-y nex by))]
                               [eu-cld #f])
                           (let loop ([i 0])
                             (cond
                               [(fx>= i n-bats) #f]
                               [(vector-ref bat-d65-hits i)
                                (define batx (flvector-ref bat-xs i))
                                (define baty (flvector-ref bat-ys i))
                                (define dx (fl- nxx batx))
                                (define dy (fl- nxy baty))
                                (if (and (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 64.0)
                                         (begin
                                           (unless eu-cld (set! eu-cld (ensure-eu-cloud! idx)))
                                           (cloud-any-within? eu-cld batx baty 10.0)))
                                    (vector-ref bat-ids i)
                                    (loop (fx+ i 1)))]
                               [else (loop (fx+ i 1))])))))
                  (if overcharge-target-id
                      (emit! (list 'cast-spell nid 'battery-overcharge overcharge-target-id))
                      (let ([lc (get-low-caster)])
                        (when lc
                          (emit! (list 'cast-spell nid 'nexus-energy-recharge (u-id lc))))))))

              (when (and (pair? damaged-25) (fx> n-bats 0))
                (for ([d (in-list damaged-25)])
                  (define uid (vector-ref d 0))
                  (define ux (vector-ref d 1))
                  (define uy (vector-ref d 2))
                  (define-values (best-i best-d2)
                    (let loop ([i 0] [bi -1] [bd2 +inf.0])
                      (if (fx>= i n-bats)
                          (values bi bd2)
                          (let ([dx (fl- ux (flvector-ref bat-xs i))]
                                [dy (fl- uy (flvector-ref bat-ys i))])
                            (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
                            (if (fl< d2 bd2)
                                (loop (fx+ i 1) i d2)
                                (loop (fx+ i 1) bi bd2))))))
                  (when (and (fx>= best-i 0) (fl<= best-d2 196.0))
                    (when (fl> best-d2 36.0)
                      (emit! (list 'move uid (flvector-ref bat-xs best-i) (flvector-ref bat-ys best-i))))
                    (emit! (list 'shield-battery-restore (vector-ref bat-ids best-i) uid)))))

              (reverse actions))))))

(define (plan-shield-battery-and-nexus-overcharge-tactics raw-obs)
  (plan-shield-battery-and-nexus-overcharge-tactics/idx (build-sd-index raw-obs)))

(define (plan-counter-shield-battery-tactics/idx idx)
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (define e-bats (bucket-pos-ids eb-ht '(shield-battery)))
  (if (null? e-bats)
      '()
      (let ()
        (define e-pylons (bucket-pos-ids eb-ht '(pylon)))
        (define attackers (sd-index-ally-combat idx))
        (define attacker-ids #f)
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))
        (for ([bat (in-list e-bats)])
          (define btx (u-x bat 0.0))
          (define bty (u-y bat 0.0))
          (define overcharged?
            (or (eq? (obs-ref bat 'overcharged? #f) #t)
                (memq 'battery-overcharge (obs-list bat 'buffs))))
          (when overcharged?
            (emit! (list 'counter-kite-battery-overcharge btx bty BATTERY-OVERCHARGE-WINDOW-FRAMES))
            (for ([au (in-list (entities-within btx bty 7.0 attackers))])
              (define-values (kx ky) (step-from-to btx bty (u-x au btx) (u-y au bty) 8.5))
              (emit! (list 'kite (u-id au) kx ky))))
          (for ([act (in-list (find-aoe-helper-cast/idx idx btx bty))]) (emit! act))
          (define sole-pylons (entities-within btx bty 6.5 e-pylons))
          (when (and (= (length sole-pylons) 1) (pair? attackers))
            (unless attacker-ids (set! attacker-ids (map u-id attackers)))
            (emit! (list 'focus-fire attacker-ids (u-id (first sole-pylons))))))
        (reverse actions))))

(define (plan-counter-shield-battery-tactics raw-obs)
  (plan-counter-shield-battery-tactics/idx (build-sd-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 3i. Spore Crawler & Spine Crawler Tactics <-> Counters
;; -----------------------------------------------------------------------------

(define (plan-spore-crawler-tactics/idx idx)
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define au-ht (sd-index-ally-u-by-type idx))
  (define spores (bucket-pos-ids ab-ht '(spore-crawler)))
  (define uprooted-spores
    (append (bucket-pos-ids au-ht '(spore-crawler-uprooted))
            (bucket-pos-ids ab-ht '(spore-crawler-uprooted))))
  (if (and (null? spores) (null? uprooted-spores))
      '()
      (let ()
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define nx (sd-index-nx idx))
        (define ny (sd-index-ny idx))
        (define tx (sd-index-tx idx))
        (define ty (sd-index-ty idx))
        (define air-threats (sd-index-enemy-air idx))
        (define spu0-id (and (pair? uprooted-spores) (u-id (first uprooted-spores))))
        (define multi-spores? (and (not spu0-id) (pair? spores) (pair? (cdr spores))))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (when (and (pair? air-threats) (or spu0-id multi-spores?))
          (define n-sp (length spores))
          (define sp-ids (make-vector n-sp 0))
          (define sp-xs (make-flvector n-sp 0.0))
          (define sp-ys (make-flvector n-sp 0.0))
          (for ([sp (in-list spores)] [i (in-naturals)])
            (vector-set! sp-ids i (u-id sp))
            (flvector-set! sp-xs i (real->double-flonum (u-x sp bx)))
            (flvector-set! sp-ys i (real->double-flonum (u-y sp by))))
          (define fnx (real->double-flonum nx))
          (define fny (real->double-flonum ny))
          (define ftx (real->double-flonum tx))
          (define fty (real->double-flonum ty))
          (define rbx (clamp-coord bx))
          (define rby (clamp-coord by))
          (define rnx (clamp-coord nx))
          (define rny (clamp-coord ny))
          (define rtx (clamp-coord tx))
          (define rty (clamp-coord ty))
          (define max-pairs (fx* 3 n-sp))
          (let loop-at ([rem air-threats] [spu-mask 0] [seen-up '()] [seen-pairs '()] [n-pairs 0])
            (unless (or (null? rem)
                        (and spu0-id (fx= spu-mask 7))
                        (and (not spu0-id) (fx>= n-pairs max-pairs)))
              (define at (car rem))
              (define ax (real->double-flonum (u-x at bx)))
              (define ay (real->double-flonum (u-y at by)))
              (define dxn (fl- ax fnx))
              (define dyn (fl- ay fny))
              (define bkt
                (if (fl<= (fl+ (fl* dxn dxn) (fl* dyn dyn)) 144.0)
                    0
                    (let ([dxt (fl- ax ftx)] [dyt (fl- ay fty)])
                      (if (fl<= (fl+ (fl* dxt dxt) (fl* dyt dyt)) 144.0) 1 2))))
              (define bkt-bit (fxlshift 1 bkt))
              (if (and spu0-id (not (fx= (fxand spu-mask bkt-bit) 0)))
                  (loop-at (cdr rem) spu-mask seen-up seen-pairs n-pairs)
                  (let ([res
                         (let loop-sp ([i 0] [bid #f] [bd2 -1.0])
                           (if (fx>= i n-sp)
                               bid
                               (let* ([dx (fl- (flvector-ref sp-xs i) ax)]
                                      [dy (fl- (flvector-ref sp-ys i) ay)]
                                      [d2 (fl+ (fl* dx dx) (fl* dy dy))])
                                 (cond
                                   [(fl<= d2 56.25) 'covered]
                                   [(fl> d2 bd2) (loop-sp (fx+ i 1) (vector-ref sp-ids i) d2)]
                                   [else (loop-sp (fx+ i 1) bid bd2)]))))])
                    (if (eq? res 'covered)
                        (loop-at (cdr rem) spu-mask seen-up seen-pairs n-pairs)
                        (let ([root-x (case bkt [(0) rnx] [(1) rtx] [else rbx])]
                              [root-y (case bkt [(0) rny] [(1) rty] [else rby])])
                          (cond
                            [spu0-id
                             (emit! (list 'spore-crawler-root spu0-id root-x root-y))
                             (loop-at (cdr rem) (fxior spu-mask bkt-bit) seen-up seen-pairs n-pairs)]
                            [res
                             (define n-up
                               (if (memv res seen-up)
                                   seen-up
                                   (begin
                                     (emit! (list 'spore-crawler-uproot res))
                                     (cons res seen-up))))
                             (define pair-key (+ bkt (* 4 res)))
                             (if (memv pair-key seen-pairs)
                                 (loop-at (cdr rem) spu-mask n-up seen-pairs n-pairs)
                                 (begin
                                   (emit! (list 'spore-crawler-root res root-x root-y))
                                   (loop-at (cdr rem) spu-mask n-up (cons pair-key seen-pairs) (fx+ n-pairs 1))))]
                            [else
                             (loop-at (cdr rem) spu-mask seen-up seen-pairs n-pairs)]))))))))

        (when (pair? spores)
          (define queens (bucket-pos-ids au-ht '(queen)))
          (when (pair? queens)
            (define ready-q-pts #f)
            (for ([sp (in-list spores)]
                  #:when (< (u-hp-frac sp) 0.70))
              (unless ready-q-pts
                (set! ready-q-pts
                      (for/fold ([acc '()] #:result (reverse acc))
                                ([qn (in-list queens)])
                        (if (>= (u-energy qn 0.0) 50.0)
                            (cons (vector (u-id qn) (u-x qn 9999.0) (u-y qn 9999.0)) acc)
                            acc))))
              (when (pair? ready-q-pts)
                (define spx (u-x sp bx))
                (define spy (u-y sp by))
                (define best-qid
                  (for/fold ([best #f] [best-d2 +inf.0] #:result best)
                            ([qp (in-list ready-q-pts)])
                    (define d2 (fast-dist2 spx spy (vector-ref qp 1) (vector-ref qp 2)))
                    (if (< d2 best-d2) (values (vector-ref qp 0) d2) (values best best-d2))))
                (when best-qid (emit! (list 'cast-spell best-qid 'transfusion (u-id sp))))))))

        (reverse actions))))

(define (plan-spore-crawler-tactics raw-obs)
  (plan-spore-crawler-tactics/idx (build-sd-index raw-obs)))

(define (plan-counter-spore-crawler-tactics/idx idx)
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (define eu-ht (sd-index-enemy-u-by-type idx))
  (define e-uprooted
    (append (bucket-pos-ids eu-ht '(spore-crawler-uprooted))
            (bucket-pos-ids eb-ht '(spore-crawler-uprooted))))
  (define e-spores (bucket-pos-ids eb-ht '(spore-crawler)))
  (define e-tumors (bucket-pos-ids eb-ht '(creep-tumor creep-tumor-burrowed)))
  (if (and (null? e-uprooted) (null? e-spores) (null? e-tumors))
      '()
      (let ()
        (define attackers (sd-index-ally-combat idx))
        (define attacker-ids
          (if (and (pair? attackers) (or (pair? e-uprooted) (pair? e-tumors)))
              (map u-id attackers)
              '()))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (when (and (pair? e-uprooted) (pair? attacker-ids))
          (emit! (list 'focus-fire attacker-ids (u-id (first e-uprooted)))))
        (when (and (pair? e-tumors) (pair? attacker-ids))
          (emit! (list 'focus-fire attacker-ids (u-id (first e-tumors)))))
        (when (pair? e-spores)
          (define flying-allies
            (for/fold ([acc '()] #:result (reverse acc))
                      ([u (in-list attackers)])
              (if (fast-flying-sym? (u-sym u)) (cons u acc) acc)))
          (when (pair? flying-allies)
            (for ([sp (in-list e-spores)])
              (define sx (u-x sp 0.0))
              (define sy (u-y sp 0.0))
              (for ([au (in-list flying-allies)])
                (define ax (u-x au sx))
                (define ay (u-y au sy))
                (when (< (fast-dist2 ax ay sx sy) 56.25)
                  (define-values (rx ry) (step-from-to sx sy ax ay 8.5))
                  (emit! (list 'move (u-id au) rx ry)))))))

        (reverse actions))))

(define (plan-counter-spore-crawler-tactics raw-obs)
  (plan-counter-spore-crawler-tactics/idx (build-sd-index raw-obs)))

(define (plan-spine-crawler-tactics/idx idx)
  (define ab-ht (sd-index-ally-b-by-type idx))
  (define au-ht (sd-index-ally-u-by-type idx))
  (define spines (bucket-pos-ids ab-ht '(spine-crawler)))
  (define uprooted-spines
    (append (bucket-pos-ids au-ht '(spine-crawler-uprooted))
            (bucket-pos-ids ab-ht '(spine-crawler-uprooted))))
  (if (and (null? spines) (null? uprooted-spines))
      '()
      (let ()
        (define bx (sd-index-bx idx))
        (define by (sd-index-by idx))
        (define ex (sd-index-ex idx))
        (define ey (sd-index-ey idx))
        (define tumors (bucket-pos-ids ab-ht '(creep-tumor creep-tumor-burrowed)))
        (define eu-cld #f)
        (define ready-queens 'ready-queens-uninit)
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (define front-tumor
          (and (pair? tumors)
               (argmin (lambda (tm) (fast-dist2 (u-x tm bx) (u-y tm by) ex ey)) tumors)))
        (define-values (front-x front-y)
          (if front-tumor
              (values (u-x front-tumor ex) (u-y front-tumor ey))
              (values (sd-index-nx idx) (sd-index-ny idx))))
        (define rfx (clamp-coord front-x))
        (define rfy (clamp-coord front-y))

        (for ([spu (in-list uprooted-spines)])
          (emit! (list 'spine-crawler-root (u-id spu) rfx rfy)))

        (for ([sp (in-list spines)])
          (define sx (u-x sp bx))
          (define sy (u-y sp by))
          (when (and front-tumor (> (fast-dist2 sx sy front-x front-y) 196.0))
            (unless eu-cld (set! eu-cld (ensure-eu-cloud! idx)))
            (unless (cloud-any-within? eu-cld sx sy 12.0)
              (emit! (list 'spine-crawler-uproot (u-id sp)))
              (emit! (list 'spine-crawler-root (u-id sp) rfx rfy))))
          (when (< (u-hp-frac sp) 0.70)
            (when (eq? ready-queens 'ready-queens-uninit)
              (set! ready-queens
                    (for/fold ([acc '()] #:result (reverse acc))
                              ([qn (in-list (bucket-pos-ids au-ht '(queen)))])
                      (if (>= (u-energy qn 0.0) 50.0) (cons qn acc) acc))))
            (when (pair? ready-queens)
              (define q (nearest-entity-to sx sy ready-queens))
              (when q (emit! (list 'cast-spell (u-id q) 'transfusion (u-id sp)))))))

        (reverse actions))))

(define (plan-spine-crawler-tactics raw-obs)
  (plan-spine-crawler-tactics/idx (build-sd-index raw-obs)))

(define (plan-counter-spine-crawler-tactics/idx idx)
  (define eb-ht (sd-index-enemy-b-by-type idx))
  (define eu-ht (sd-index-enemy-u-by-type idx))
  (define e-uprooted
    (append (bucket-pos-ids eu-ht '(spine-crawler-uprooted))
            (bucket-pos-ids eb-ht '(spine-crawler-uprooted))))
  (define e-spines (bucket-pos-ids eb-ht '(spine-crawler)))
  (define e-tumors (bucket-pos-ids eb-ht '(creep-tumor creep-tumor-burrowed)))
  (if (and (null? e-uprooted) (null? e-spines) (null? e-tumors))
      '()
      (let ()
        (define attackers (sd-index-ally-combat idx))
        (define siege-units
          (bucket-pos-ids (sd-index-ally-u-by-type idx)
                          '(siege-tank siege-tank-sieged lurker tempest brood-lord disruptor)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (when (and (pair? e-uprooted) (pair? attackers))
          (emit! (list 'focus-fire (map u-id attackers) (u-id (first e-uprooted)))))
        (when (and (pair? e-tumors) (pair? attackers))
          (emit! (list 'focus-fire (map u-id attackers) (u-id (first e-tumors)))))
        (define siege-pts
          (if (and (pair? siege-units) (pair? (cdr e-spines)))
              (for/list ([su (in-list siege-units)])
                (vector (u-id su) (u-x su 0.0) (u-y su 0.0)))
              #f))
        (for ([sp (in-list e-spines)])
          (define spid (u-id sp))
          (define sx (u-x sp 0.0))
          (define sy (u-y sp 0.0))
          (for ([act (in-list (find-aoe-helper-cast/idx idx sx sy))]) (emit! act))
          (if siege-pts
              (for ([pt (in-list siege-pts)])
                (define suid (vector-ref pt 0))
                (define ux (vector-ref pt 1))
                (define uy (vector-ref pt 2))
                (when (< (fast-dist2 ux uy sx sy) 56.25)
                  (define-values (rx ry) (step-from-to sx sy ux uy 8.5))
                  (emit! (list 'move suid rx ry)))
                (emit! (list 'attack-unit suid spid)))
              (for ([su (in-list siege-units)])
                (define suid (u-id su))
                (define ux (u-x su sx))
                (define uy (u-y su sy))
                (when (< (fast-dist2 ux uy sx sy) 56.25)
                  (define-values (rx ry) (step-from-to sx sy ux uy 8.5))
                  (emit! (list 'move suid rx ry)))
                (emit! (list 'attack-unit suid spid)))))

        (reverse actions))))

(define (plan-counter-spine-crawler-tactics raw-obs)
  (plan-counter-spine-crawler-tactics/idx (build-sd-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 4. Top-Level Unified Orchestrator (`plan-static-defense-actions`)
;; -----------------------------------------------------------------------------

(define (dedup-action-slot a)
  (and (pair? a)
       (symbol? (car a))
       (let ([r2 (cdr a)])
         (and (pair? r2)
              (let* ([k2 (car r2)]
                     [r3 (cdr r2)]
                     [k (if (and (pair? r3) (exact-integer? (car r3)))
                            (car r3)
                            (and (or (exact-integer? k2) (symbol? k2)) k2))])
                (and k
                     (cond
                       [(and (fixnum? k) (fixnum? k2))
                        (fxand (fx+ (fx* k2 131) k) 511)]
                       [(fixnum? k) (fxand k 511)]
                       [else (fxand (eq-hash-code k) 511)])))))))

(define (dedup-vec-seen?! vec a slot)
  (define bucket (vector-ref vec slot))
  (cond
    [(not bucket)
     (vector-set! vec slot a)
     #f]
    [(pair? bucket)
     (cond
       [(symbol? (car bucket))
        (if (equal? bucket a)
            #t
            (begin
              (vector-set! vec slot (list a bucket))
              #f))]
       [(member a bucket) #t]
       [(and (pair? (cdr bucket)) (pair? (cddr bucket)) (pair? (cdddr bucket))
             (pair? (cddddr bucket)) (pair? (cdr (cddddr bucket)))
             (pair? (cddr (cddddr bucket))) (pair? (cdddr (cddddr bucket))))
        (define h (make-hash))
        (for ([x (in-list bucket)]) (hash-set! h x #t))
        (hash-set! h a #t)
        (vector-set! vec slot h)
        #f]
       [else
        (vector-set! vec slot (cons a bucket))
        #f])]
    [else
     (if (hash-ref bucket a #f)
         #t
         (begin
           (hash-set! bucket a #t)
           #f))]))

(define (dedup-action-chunks chunks)
  (let loop-ch ([chs chunks] [acc '()] [n 0] [vec #f] [fb #f])
    (if (null? chs)
        (cond
          [(null? acc) '()]
          [(null? (cdr acc)) acc]
          [else (reverse acc)])
        (let loop-act ([acts (car chs)] [acc acc] [n n] [vec vec] [fb fb])
          (if (null? acts)
              (loop-ch (cdr chs) acc n vec fb)
              (let ([a (car acts)]
                    [rest (cdr acts)])
                (cond
                  [(and (not vec) (fx< n 8))
                   (if (member a acc)
                       (loop-act rest acc n vec fb)
                       (loop-act rest (cons a acc) (fx+ n 1) vec fb))]
                  [else
                   (define-values (v fb0)
                     (if vec
                         (values vec fb)
                         (let ([nv (make-vector 512 #f)])
                           (let loop-prev ([p acc] [f fb])
                             (if (null? p)
                                 (values nv f)
                                 (let* ([pa (car p)]
                                        [pslot (dedup-action-slot pa)])
                                   (if pslot
                                       (begin
                                         (dedup-vec-seen?! nv pa pslot)
                                         (loop-prev (cdr p) f))
                                       (let ([f2 (or f (make-hash))])
                                         (hash-set! f2 pa #t)
                                         (loop-prev (cdr p) f2)))))))))
                   (define slot (dedup-action-slot a))
                   (if slot
                       (if (dedup-vec-seen?! v a slot)
                           (loop-act rest acc n v fb0)
                           (loop-act rest (cons a acc) n v fb0))
                       (let ([f2 (or fb0 (make-hash))])
                         (if (hash-ref f2 a #f)
                             (loop-act rest acc n v f2)
                             (begin
                               (hash-set! f2 a #t)
                               (loop-act rest (cons a acc) n v f2)))))])))))))

(define (plan-static-defense-actions raw-obs)
  (define obs (ensure-obs raw-obs))
  (define idx (build-sd-index obs))
  (define race-raw (obs-ref obs 'race #f))
  (define cannon-counter-acts
    (let ([acts (plan-counter-cannon-rush-tactics/idx idx obs)])
      (if (and (eq? race-raw 'Zerg)
               (pair? acts)
               (not (for/or ([a (in-list acts)]) (and (pair? a) (eq? (car a) 'build)))))
          (append acts (list (list 'build 'spine-crawler
                                   (clamp-coord (+ (sd-index-bx idx) 5.0))
                                   (clamp-coord (+ (sd-index-by idx) 5.0)))))
          acts)))
  (define chunks
    (list
     (plan-spread-burrowed-swarm-host-harass/idx idx)
     (plan-counter-spread-swarm-host-harass/idx idx)
     (plan-pro-cannon-rush-tactics/idx idx obs)
     cannon-counter-acts
     (plan-photon-cannon-tactics/idx idx)
     (plan-counter-photon-cannon-tactics/idx idx)
     (plan-bunker-tactics/idx idx)
     (plan-counter-bunker-tactics/idx idx)
     (plan-missile-turret-tactics/idx idx)
     (plan-counter-missile-turret-tactics/idx idx)
     (plan-planetary-fortress-tactics/idx idx)
     (plan-counter-planetary-fortress-tactics/idx idx)
     (plan-shield-battery-and-nexus-overcharge-tactics/idx idx)
     (plan-counter-shield-battery-tactics/idx idx)
     (plan-spore-crawler-tactics/idx idx)
     (plan-counter-spore-crawler-tactics/idx idx)
     (plan-spine-crawler-tactics/idx idx)
     (plan-counter-spine-crawler-tactics/idx idx)))
  (dedup-action-chunks chunks))
