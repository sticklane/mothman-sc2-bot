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
         "tactics/terran-addon-swap.rkt"
         "tactics/disruptor-micro.rkt"
         "tactics/pro-spellcaster-micro.rkt"
         "tactics/unit-mode-micro.rkt"
         "tactics/transport-drop-micro.rkt"
         "situational-counter-planner.rkt"
         "tactics/creep-and-changeling-tactics.rkt"
         "tactics/wall-and-block-tactics.rkt"
         (except-in "tactics/multitask-harass-and-proxy.rkt"
                    MORPH-VIKING-ASSAULT-ABILITY-ID
                    MORPH-VIKING-FIGHTER-ABILITY-ID)
         "tactics/map-elements-and-experiments.rkt"
         (except-in "tactics/static-defense-and-nydus-tactics.rkt"
                    NEXUS-ENERGY-RECHARGE-ABILITY-ID
                    SHIELD-BATTERY-RECHARGE-ABILITY-ID
                    SHIELD-BATTERY-RESTORE-LEGACY-ID
                    LOCUST-SWOOP-ABILITY-ID))

(provide
 (all-from-out "sc2-geometry.rkt")
 (all-from-out "sc2-pathing.rkt")
 (all-from-out "sc2-placement.rkt")
 (all-from-out "sc2-combat-eval.rkt")
 (all-from-out "tactics/order-ledger.rkt")
 (all-from-out "tactics/arena-minimax.rkt")
 (all-from-out "tactics/zerg-burrow-micro.rkt")
 (all-from-out "tactics/stealth-shimmer-response.rkt")
 (all-from-out "tactics/terran-addon-swap.rkt")
 (all-from-out "tactics/disruptor-micro.rkt")
 (all-from-out "tactics/pro-spellcaster-micro.rkt")
 (all-from-out "tactics/unit-mode-micro.rkt")
 (all-from-out "tactics/transport-drop-micro.rkt")
 (all-from-out "situational-counter-planner.rkt")
 (all-from-out "tactics/creep-and-changeling-tactics.rkt")
 (all-from-out "tactics/wall-and-block-tactics.rkt")
 (all-from-out "tactics/multitask-harass-and-proxy.rkt")
 (all-from-out "tactics/map-elements-and-experiments.rkt")
 (all-from-out "tactics/static-defense-and-nydus-tactics.rkt"))
