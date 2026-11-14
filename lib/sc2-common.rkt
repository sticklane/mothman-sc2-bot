#lang typed/racket/base

;; =============================================================================
;; Shared Total Numeric, Geometry, JSON, List, and Unit-Type Helpers (`lib/sc2-common.rkt`)
;; Canonical implementations live in `lib/sc2-types.rkt`.
;; =============================================================================

(require "sc2-types.rkt")

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
