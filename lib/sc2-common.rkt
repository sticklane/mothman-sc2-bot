#lang racket/base

;; =============================================================================
;; Shared Total Numeric, Geometry, JSON, List, and Unit-Type Helpers (`lib/sc2-common.rkt`)
;; =============================================================================

(require racket/math)

(provide
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

;; Returns #t when `v` is a finite real number (neither NaN nor +/-inf.0).
(define (finite-real? v)
  (and (real? v) (not (nan? v)) (not (infinite? v))))

;; Converts finite `v` to an inexact real, falling back to `default`.
(define (safe-finite-real v [default 0.0])
  (if (finite-real? v) (exact->inexact v) default))

;; Converts finite `v` to an inexact real, falling back to finite `fallback` or 0.0.
(define (safe-real v [fallback 0.0])
  (cond
    [(finite-real? v) (exact->inexact v)]
    [(finite-real? fallback) (exact->inexact fallback)]
    [else 0.0]))

;; Rounds finite `v` to an exact integer, falling back to `default`.
(define (safe-exact-int v [default 0])
  (if (finite-real? v) (exact-round v) default))

;; Rounds finite `v` to an exact integer, falling back to finite `fallback` or 0.
(define (safe-int v [fallback 0])
  (cond
    [(finite-real? v) (exact-round v)]
    [(finite-real? fallback) (exact-round fallback)]
    [else 0]))

;; Rounds finite `v` to a non-negative exact integer, falling back to `default`.
(define (safe-nonneg-int v [default 0])
  (max 0 (safe-exact-int v default)))

;; Rounds finite `x` to 1 decimal place as an inexact real (falling back to 0.0).
(define (round1 x)
  (/ (round (* 10.0 (safe-finite-real x 0.0))) 10.0))

;; Rounds finite `x` to 2 decimal places as an inexact real (falling back to 0.0).
(define (round2 x)
  (/ (round (* 100.0 (safe-finite-real x 0.0))) 100.0))

;; Converts JSON `'null` or `#f` to `#f`, returning any other value unchanged.
(define (jnull->false v)
  (if (or (eq? v 'null) (not v)) #f v))

;; Returns Euclidean 2D distance using `safe-finite-real` defaults for each endpoint.
(define (dist2d x1 y1 x2 y2 [default-1 0.0] [default-2 0.0])
  (define sx1 (safe-finite-real x1 default-1))
  (define sy1 (safe-finite-real y1 default-1))
  (define sx2 (safe-finite-real x2 default-2))
  (define sy2 (safe-finite-real y2 default-2))
  (sqrt (+ (sqr (- sx2 sx1)) (sqr (- sy2 sy1)))))

;; Returns Euclidean 2D distance when all 4 coordinates are `finite-real?`, else `fallback`.
(define (safe-dist2d x1 y1 x2 y2 [fallback 99999.0])
  (if (and (finite-real? x1) (finite-real? y1) (finite-real? x2) (finite-real? y2))
      (dist2d x1 y1 x2 y2)
      fallback))

;; Clamps finite `v` to `[0.0, max-coord]` and snaps to 0.5-tile increments.
(define (safe-tile-coord v [default 32.5] [max-coord 256.0])
  (define raw (if (finite-real? v) v default))
  (define clamped (max 0.0 (min max-coord (exact->inexact raw))))
  (define half-rounded (/ (round (* clamped 2.0)) 2.0))
  (if (and (exact-integer? raw) (= clamped (exact->inexact (exact-round half-rounded))))
      (exact-round half-rounded)
      half-rounded))

;; Total symbol extractor for unit hashes, symbols, or strings.
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

;; Returns `xs` if it is a list, otherwise '().
(define (safe-list xs)
  (if (list? xs) xs '()))

;; Returns the hash elements of `xs` if it is a list, otherwise '().
(define (safe-hash-list xs)
  (if (list? xs) (filter hash? xs) '()))
