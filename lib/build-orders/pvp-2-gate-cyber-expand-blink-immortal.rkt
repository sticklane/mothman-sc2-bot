#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/pvp-2-gate-cyber-expand-blink-immortal.rkt`
;; PvP — 2-Gate Cyber Expand into Robo / Blink Immortal
;; Exemplar: <Exper> KaelThas vs VOID (Turbo Cruise '84 LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide PvP-BUILD-ORDER)

(: PvP-BUILD-ORDER build-order-spec)
(define PvP-BUILD-ORDER
  (build-order-spec
   'PvP
   'Protoss
   "2-Gate Cyber Expand into Robo-Blink"
   'blink-immortal
   "Double-gas 2-Gate Cyber opening for PvP pressure safety, followed by Natural Nexus, Immortal/Observer Robo, and Blink."
   (list
    ;; 14-21 Double-Gate Double-Gas Cyber Core -> Stalker defense
    (pro-bo-goal 'build    'pylon                  1 14 #f)
    (pro-bo-goal 'build    'gateway                1 16 'pylon)
    (pro-bo-goal 'build    'assimilator            1 16 'pylon)
    (pro-bo-goal 'build    'gateway                2 17 'pylon)
    (pro-bo-goal 'build    'assimilator            2 18 'pylon)
    (pro-bo-goal 'build    'cybernetics-core       1 19 'gateway)
    (pro-bo-goal 'build    'pylon                  2 20 'cybernetics-core)
    (pro-bo-goal 'research 'warp-gate-research     1 21 'cybernetics-core)
    (pro-bo-goal 'train    'stalker                2 21 'cybernetics-core)
    ;; 26-40 Natural Nexus -> Sentry -> Robo/Twilight -> Blink
    (pro-bo-goal 'expand   'nexus                  2 26 'cybernetics-core)
    (pro-bo-goal 'train    'sentry                 1 28 'cybernetics-core)
    (pro-bo-goal 'build    'robotics-facility      1 29 'cybernetics-core)
    (pro-bo-goal 'build    'twilight-council       1 32 'cybernetics-core)
    (pro-bo-goal 'train    'immortal               1 34 'robotics-facility)
    (pro-bo-goal 'train    'observer               1 36 'robotics-facility)
    (pro-bo-goal 'build    'gateway                3 38 'cybernetics-core)
    (pro-bo-goal 'research 'blink                  1 40 'twilight-council)
    ;; 44-60 +1 Weapons, Robotics Bay & 3rd Nexus
    (pro-bo-goal 'build    'assimilator            3 44 'robotics-facility)
    (pro-bo-goal 'build    'forge                  1 48 'cybernetics-core)
    (pro-bo-goal 'research 'protoss-ground-weapons-1 1 52 'forge)
    (pro-bo-goal 'build    'robotics-bay           1 56 'robotics-facility)
    (pro-bo-goal 'expand   'nexus                  3 60 'robotics-facility))
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (17.0 .  1.0))
     (2 . (22.0 .  1.0))
     (3 . (24.0 .  8.0))
     (4 . (26.0 . 11.5))
     (5 . (29.5 . 19.0))
     (6 . (35.0 . 25.0))
     (7 . (40.0 . 32.0)))))
