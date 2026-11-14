#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/pvz-1-gate-fe-stargate-oracle-archon.rkt`
;; PvZ — 19-Nexus Gate Expand into Robo-Twilight Charge/Colossus
;; Exemplar: Stats vs Serral (Fracture LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide PvZ-BUILD-ORDER)

(: PvZ-BUILD-ORDER build-order-spec)
(define PvZ-BUILD-ORDER
  (build-order-spec
   'PvZ
   'Protoss
   "19-Nexus Robo-Twilight Charge/Colossus"
   'stalker-colossus
   "Safe 19-Nexus Gateway expand into Warp Gate, Immortal/Observer Robo defense, Twilight Charge, and 3-base Colossus."
   (list
    ;; 14-23 1-Gate 19-Nexus -> Cyber Core & Warp Gate
    (pro-bo-goal 'build    'pylon                  1 14 #f                 17.5)  ;; 0:18
    (pro-bo-goal 'build    'gateway                1 16 'pylon            44.5)  ;; 0:45
    (pro-bo-goal 'build    'assimilator            1 16 'pylon            46.8)  ;; 0:47
    (pro-bo-goal 'expand   'nexus                  2 19 #f                 86.2)  ;; 1:26
    (pro-bo-goal 'build    'cybernetics-core       1 19 'gateway          95.0)  ;; 1:35
    (pro-bo-goal 'build    'assimilator            2 21 'cybernetics-core 102.7) ;; 1:43
    (pro-bo-goal 'build    'pylon                  2 21 'cybernetics-core 111.5) ;; 1:52
    (pro-bo-goal 'research 'warp-gate-research     1 22 'cybernetics-core 147.1) ;; 2:27
    (pro-bo-goal 'train    'stalker                2 23 'cybernetics-core 165.7) ;; 2:46
    ;; 26-38 Robo + Twilight + 3-Gate timing & Charge
    (pro-bo-goal 'build    'robotics-facility      1 26 'cybernetics-core 182.8) ;; 3:03
    (pro-bo-goal 'build    'twilight-council       1 28 'cybernetics-core 145.0) ;; 2:25
    (pro-bo-goal 'build    'gateway                2 30 'cybernetics-core 217.6) ;; 3:38
    (pro-bo-goal 'build    'gateway                3 32 'cybernetics-core 220.7) ;; 3:41
    (pro-bo-goal 'train    'immortal               1 34 'robotics-facility 322.4) ;; 5:22
    (pro-bo-goal 'train    'observer               1 36 'robotics-facility 312.9) ;; 5:13
    (pro-bo-goal 'research 'charge                 1 38 'twilight-council 317.2) ;; 5:17
    ;; 42-64 +1 Ground, Robotics Bay, 3rd Nexus & Thermal Lance
    (pro-bo-goal 'build    'assimilator            3 42 'robotics-facility 260.0) ;; 4:20
    (pro-bo-goal 'build    'forge                  1 48 'cybernetics-core 289.2) ;; 4:49
    (pro-bo-goal 'research 'protoss-ground-weapons-1 1 52 'forge           336.9) ;; 5:37
    (pro-bo-goal 'build    'robotics-bay           1 56 'robotics-facility 350.0) ;; 5:50
    (pro-bo-goal 'expand   'nexus                  3 60 'robotics-facility 297.8) ;; 4:58
    (pro-bo-goal 'research 'extended-thermal-lance 1 64 'robotics-bay     400.0)) ;; 6:40
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (17.0 .  1.0))
     (2 . (21.0 .  1.0))
     (3 . (28.0 .  6.0))
     (4 . (38.0 . 14.0))
     (5 . (45.0 . 20.0))
     (6 . (54.0 . 24.0))
     (7 . (65.0 . 32.5)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'adept      2 28 140.6 'cybernetics-core)  ;; 2:21
    (pro-unit-timing 'stalker    1 33 165.7 'cybernetics-core)  ;; 2:46
    (pro-unit-timing 'warp-prism 1 42 219.2 'robotics-facility) ;; 3:39
    (pro-unit-timing 'observer   1 60 312.9 'robotics-facility) ;; 5:13
    (pro-unit-timing 'archon     2 67 318.0 'templar-archive)   ;; 5:18
    (pro-unit-timing 'immortal   1 64 322.4 'robotics-facility) ;; 5:22
    (pro-unit-timing 'sentry     3 78 366.0 'cybernetics-core)  ;; 6:06
    (pro-unit-timing 'immortal   4 97 405.9 'robotics-facility)) ;; 6:46
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'warp-gate-research       147.1 247.1 27 'cybernetics-core) ;; 2:27 -> 4:07
    (pro-upgrade-timing 'resonating-glaives       255.9 355.9 53 'twilight-council) ;; 4:16 -> 5:56
    (pro-upgrade-timing 'charge                   317.2 417.2 70 'twilight-council) ;; 5:17 -> 6:57
    (pro-upgrade-timing 'blink                    318.6 439.6 70 'twilight-council) ;; 5:19 -> 7:20
    (pro-upgrade-timing 'protoss-ground-weapons-1 336.9 450.9 80 'forge)            ;; 5:37 -> 7:31
    (pro-upgrade-timing 'psi-storm                382.4 461.4 90 'templar-archive)))) ;; 6:22 -> 7:41
