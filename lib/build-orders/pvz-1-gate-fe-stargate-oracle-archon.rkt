#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/pvz-1-gate-fe-stargate-oracle-archon.rkt`
;; PvZ — 19-Nexus Gate Expand into Robo-Twilight Charge/Colossus
;; Exemplar: Stats vs Serral (Fracture LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide PvZ-BUILD-ORDER
         PvZ-UNIT-BENCHMARKS)

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
    ;; 42-96 +1 Ground, 3rd Nexus, Robotics Bay, Thermal Lance, Templar Archive & 4th Nexus
    (pro-bo-goal 'build    'assimilator            3 42 'robotics-facility 260.0) ;; 4:20 (Pro Gas #3 @ 36w)
    (pro-bo-goal 'expand   'nexus                  3 46 'robotics-facility 282.0) ;; 4:42 (3rd Base!)
    (pro-bo-goal 'build    'forge                  1 50 'cybernetics-core 289.2) ;; 4:49
    (pro-bo-goal 'build    'assimilator            4 54 'robotics-facility 302.0) ;; 5:02 (Pro Gas #4 @ 40w)
    (pro-bo-goal 'research 'protoss-ground-weapons-1 1 56 'forge           336.9) ;; 5:37
    (pro-bo-goal 'build    'robotics-bay           1 60 'robotics-facility 345.0) ;; 5:45
    (pro-bo-goal 'build    'templar-archive        1 66 'twilight-council  365.0) ;; 6:05
    (pro-bo-goal 'build    'gateway                4 72 'cybernetics-core  380.0) ;; 6:20
    (pro-bo-goal 'build    'gateway                5 76 'cybernetics-core  390.0) ;; 6:30
    (pro-bo-goal 'research 'extended-thermal-lance 1 80 'robotics-bay      400.0) ;; 6:40
    (pro-bo-goal 'build    'gateway                6 86 'cybernetics-core  420.0) ;; 7:00
    (pro-bo-goal 'expand   'nexus                  4 94 'robotics-bay      440.0)) ;; 7:20 (4th Base Macro!)
   ;; Empirical pro 4+ base macro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (17.0 .  1.0))
     (2 . (21.0 .  1.0))
     (3 . (29.0 .  6.0))
     (4 . (39.0 . 14.0))
     (5 . (49.0 . 20.0))
     (6 . (59.0 . 26.0))
     (7 . (66.0 . 36.0))
     (8 . (70.0 . 54.0))
     (9 . (70.0 . 74.0))
     (10 . (70.0 . 94.0)))
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

;; Full 1..8+ min pro unit composition benchmarks (PvZ) covering core, harass, drops & casters.
(: PvZ-UNIT-BENCHMARKS (Listof pro-unit-timing))
(define PvZ-UNIT-BENCHMARKS
  (list
   (pro-unit-timing 'adept        2 28 140.6 'cybernetics-core)
   (pro-unit-timing 'stalker      1 33 165.7 'cybernetics-core)
   (pro-unit-timing 'oracle       1 38 205.0 'stargate)
   (pro-unit-timing 'warp-prism   1 42 219.2 'robotics-facility)
   (pro-unit-timing 'sentry       2 50 265.0 'cybernetics-core)
   (pro-unit-timing 'observer     1 60 312.9 'robotics-facility)
   (pro-unit-timing 'archon       2 67 318.0 'templar-archive)
   (pro-unit-timing 'immortal     1 64 322.4 'robotics-facility)
   (pro-unit-timing 'oracle       2 68 335.0 'stargate)
   (pro-unit-timing 'zealot       6 74 355.0 'gateway)
   (pro-unit-timing 'sentry       3 78 366.0 'cybernetics-core)
   (pro-unit-timing 'colossus     1 84 385.0 'robotics-bay)
   (pro-unit-timing 'immortal     4 97 405.9 'robotics-facility)
   (pro-unit-timing 'high-templar 2 104 425.0 'templar-archive)
   (pro-unit-timing 'stalker      8 110 445.0 'cybernetics-core)
   (pro-unit-timing 'zealot      14 118 460.0 'gateway)
   (pro-unit-timing 'adept        4 122 465.0 'cybernetics-core)
   (pro-unit-timing 'colossus     3 128 475.0 'robotics-bay)
   (pro-unit-timing 'immortal     6 134 485.0 'robotics-facility)
   (pro-unit-timing 'archon       5 140 492.0 'templar-archive)
   (pro-unit-timing 'high-templar 5 144 498.0 'templar-archive)
   (pro-unit-timing 'disruptor    2 148 502.0 'robotics-bay)
   (pro-unit-timing 'observer     2 150 505.0 'robotics-facility)
   (pro-unit-timing 'warp-prism   2 154 510.0 'robotics-facility)))
