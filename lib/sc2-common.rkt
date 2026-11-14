#lang racket/base

;; =============================================================================
;; Shared Total Numeric, List, and Unit/Race Helpers (`lib/sc2-common.rkt`)
;; =============================================================================

(require racket/math)

(provide
 finite-real?
 safe-finite-real
 safe-real
 safe-exact-int
 safe-int
 safe-nonneg-int
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

;; Returns `xs` if it is a list, otherwise '().
(define (safe-list xs)
  (if (list? xs) xs '()))

;; Returns the hash elements of `xs` if it is a list, otherwise '().
(define (safe-hash-list xs)
  (if (list? xs) (filter hash? xs) '()))
