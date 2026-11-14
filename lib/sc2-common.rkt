#lang racket/base

;; =============================================================================
;; Shared Total Numeric, Geometry, JSON, List, and Unit-Type Helpers (`lib/sc2-common.rkt`)
;; Provides fast untyped implementations for `#lang racket/base` callers (avoiding
;; Typed/Untyped contract chaperones on unit hash lists and geometry helpers) while
;; re-exporting canonical structs and tech constants from `lib/sc2-types.rkt`.
;; =============================================================================

(require racket/list
         racket/math
         racket/string
         (except-in "sc2-types.rkt"
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
                    safe-hash-list))

(provide
 (struct-out pro-unit-timing)
 (struct-out pro-upgrade-timing)
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
 safe-hash-list
 SC2-SINGLETON-TECH-BUILDINGS
 SC2-DUAL-CAP-TECH-BUILDINGS
 sc2-zerg-corruptor-target-cap)

(define (->fl x)
  (if (flonum? x) x (exact->inexact x)))

(define (finite-real? v)
  (and (real? v) (not (nan? v)) (not (infinite? v))))

(define (safe-finite-real v [default 0.0])
  (if (and (real? v) (not (nan? v)) (not (infinite? v)))
      (->fl v)
      (->fl default)))

(define (safe-real v [fallback 0.0])
  (cond
    [(and (real? v) (not (nan? v)) (not (infinite? v))) (->fl v)]
    [(and (real? fallback) (not (nan? fallback)) (not (infinite? fallback))) (->fl fallback)]
    [else 0.0]))

(define (safe-exact-int v [default 0])
  (if (and (real? v) (not (nan? v)) (not (infinite? v)))
      (exact-round v)
      default))

(define (safe-int v [fallback 0])
  (cond
    [(and (real? v) (not (nan? v)) (not (infinite? v))) (exact-round v)]
    [(and (real? fallback) (not (nan? fallback)) (not (infinite? fallback))) (exact-round fallback)]
    [else 0]))

(define (safe-nonneg-int v [default 0])
  (max 0 (safe-exact-int v default)))

(define (round1 x)
  (/ (round (* 10.0 (safe-finite-real x 0.0))) 10.0))

(define (round2 x)
  (/ (round (* 100.0 (safe-finite-real x 0.0))) 100.0))

(define (jnull->false v)
  (if (or (eq? v 'null) (not v)) #f v))

(define (dist2d x1 y1 x2 y2 [default-1 0.0] [default-2 0.0])
  (define dx (- (safe-finite-real x2 default-2) (safe-finite-real x1 default-1)))
  (define dy (- (safe-finite-real y2 default-2) (safe-finite-real y1 default-1)))
  (define d2 (+ (* dx dx) (* dy dy)))
  (->fl (sqrt (if (>= d2 0.0) d2 0.0))))

(define (safe-dist2d x1 y1 x2 y2 [fallback 99999.0])
  (if (and (finite-real? x1) (finite-real? y1) (finite-real? x2) (finite-real? y2))
      (dist2d x1 y1 x2 y2)
      (->fl fallback)))

(define (safe-tile-coord v [default 32.5] [max-coord 256.0])
  (define raw (if (finite-real? v) v default))
  (define clamped (max 0.0 (min (->fl max-coord) (->fl raw))))
  (define half-rounded (/ (round (* clamped 2.0)) 2.0))
  (if (and (exact-integer? raw) (= clamped (->fl (exact-round half-rounded))))
      (exact-round half-rounded)
      half-rounded))

(define (unit-type-sym u)
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

(define (safe-list xs)
  (if (list? xs) xs '()))

(define (safe-hash-list xs)
  (if (list? xs)
      (if (andmap hash? xs) xs (filter hash? xs))
      '()))
