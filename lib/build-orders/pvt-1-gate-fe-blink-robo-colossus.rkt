#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/pvt-1-gate-fe-blink-robo-colossus.rkt`
;; PvT — 19-Nexus Gate Expand into Robo-Twilight Colossus Macro
;; Exemplar: Classic vs Bunny (Ultralove)
;; =============================================================================

(require "../sc2-types.rkt")

(provide PvT-BUILD-ORDER)

(: PvT-BUILD-ORDER build-order-spec)
(define PvT-BUILD-ORDER
  (build-order-spec
   'PvT
   'Protoss
   "19-Nexus Robo-Twilight Colossus Macro"
   'stalker-colossus
   "Standard 19-Nexus opening into fast Warp Gate Stalkers, Observer/Immortal Robo, Charge Zealot buffer, and Colossus."
   (list
    ;; 14-23 1-Gate 19-Nexus -> Cyber Core & Warp Gate
    (pro-bo-goal 'build    'pylon                  1 14 #f)
    (pro-bo-goal 'build    'gateway                1 16 'pylon)
    (pro-bo-goal 'build    'assimilator            1 16 'pylon)
    (pro-bo-goal 'expand   'nexus                  2 19 #f)
    (pro-bo-goal 'build    'cybernetics-core       1 19 'gateway)
    (pro-bo-goal 'build    'assimilator            2 21 'cybernetics-core)
    (pro-bo-goal 'build    'pylon                  2 21 'cybernetics-core)
    (pro-bo-goal 'research 'warp-gate-research     1 22 'cybernetics-core)
    (pro-bo-goal 'train    'stalker                2 23 'cybernetics-core)
    ;; 26-38 Robo + Twilight + 3-Gate timing & Charge
    (pro-bo-goal 'build    'robotics-facility      1 26 'cybernetics-core)
    (pro-bo-goal 'build    'twilight-council       1 28 'cybernetics-core)
    (pro-bo-goal 'build    'gateway                2 30 'cybernetics-core)
    (pro-bo-goal 'build    'gateway                3 32 'cybernetics-core)
    (pro-bo-goal 'train    'immortal               1 34 'robotics-facility)
    (pro-bo-goal 'train    'observer               1 36 'robotics-facility)
    (pro-bo-goal 'research 'charge                 1 38 'twilight-council)
    ;; 42-64 +1 Ground, Robotics Bay, 3rd Nexus & Thermal Lance
    (pro-bo-goal 'build    'assimilator            3 42 'robotics-facility)
    (pro-bo-goal 'build    'forge                  1 48 'cybernetics-core)
    (pro-bo-goal 'research 'protoss-ground-weapons-1 1 52 'forge)
    (pro-bo-goal 'build    'robotics-bay           1 56 'robotics-facility)
    (pro-bo-goal 'expand   'nexus                  3 60 'robotics-facility)
    (pro-bo-goal 'research 'extended-thermal-lance 1 64 'robotics-bay))
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (17.0 .  1.0))
     (2 . (21.0 .  3.0))
     (3 . (27.0 .  8.0))
     (4 . (38.0 . 11.0))
     (5 . (44.0 . 16.0))
     (6 . (48.5 . 23.0))
     (7 . (60.0 . 30.0)))))
