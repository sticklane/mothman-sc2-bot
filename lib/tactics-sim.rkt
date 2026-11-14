#lang racket/base

;; =============================================================================
;; `lib/tactics-sim.rkt`
;; Unified Facade Re-Exporting Spatial Geometry, Pathing, Placement/Wall-In,
;; Combat Evaluation / FAP / Mastermind, and Per-Tactic Micro Submodules.
;; =============================================================================

(require (except-in "sc2-geometry.rkt" aabb-overlaps?)
         "sc2-pathing.rkt"
         "sc2-placement.rkt"
         "sc2-combat-eval.rkt"
         "tactics/order-ledger.rkt"
         "tactics/arena-minimax.rkt"
         "tactics/zerg-burrow-micro.rkt"
         "tactics/stealth-shimmer-response.rkt"
         "tactics/terran-addon-swap.rkt")

(provide
 (all-from-out "sc2-geometry.rkt")
 (all-from-out "sc2-pathing.rkt")
 (all-from-out "sc2-placement.rkt")
 (all-from-out "sc2-combat-eval.rkt")
 (all-from-out "tactics/order-ledger.rkt")
 (all-from-out "tactics/arena-minimax.rkt")
 (all-from-out "tactics/zerg-burrow-micro.rkt")
 (all-from-out "tactics/stealth-shimmer-response.rkt")
 (all-from-out "tactics/terran-addon-swap.rkt"))
