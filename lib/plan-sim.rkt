#lang racket/base

;; =============================================================================
;; `lib/plan-sim.rkt`
;; Unified Facade Re-Exporting Operational, Positional & Counter Plan Submodules
;; under `lib/plan/*.rkt` (separated from real-time micro in `lib/tactics/*.rkt`).
;; =============================================================================

(require "plan/situational-counter.rkt"
         "plan/creep-and-changeling.rkt"
         "plan/wall-and-block.rkt"
         (except-in "plan/static-defense.rkt"
                    NEXUS-ENERGY-RECHARGE-ABILITY-ID
                    SHIELD-BATTERY-RECHARGE-ABILITY-ID
                    SHIELD-BATTERY-RESTORE-LEGACY-ID
                    LOCUST-SWOOP-ABILITY-ID)
         "plan/nydus.rkt"
         "plan/terran-addon-swap.rkt"
         "plan/multitask-harass-and-proxy.rkt"
         "plan/map-elements-and-experiments.rkt")

(provide
 (all-from-out "plan/situational-counter.rkt")
 (all-from-out "plan/creep-and-changeling.rkt")
 (all-from-out "plan/wall-and-block.rkt")
 (all-from-out "plan/static-defense.rkt")
 (all-from-out "plan/nydus.rkt")
 (all-from-out "plan/terran-addon-swap.rkt")
 (all-from-out "plan/multitask-harass-and-proxy.rkt")
 (all-from-out "plan/map-elements-and-experiments.rkt")
 plan-static-defense-and-nydus-actions)

;; Compatibility wrapper preserving the combined orchestrator signature.
(define (plan-static-defense-and-nydus-actions raw-obs)
  (append (plan-static-defense-actions raw-obs)
          (plan-nydus-actions raw-obs)))
