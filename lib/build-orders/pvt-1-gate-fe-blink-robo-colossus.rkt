#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/pvt-1-gate-fe-blink-robo-colossus.rkt`
;; PvT — 19-Nexus Gate Expand into Robo-Twilight Colossus Macro
;; Exemplar: Classic vs Bunny (Ultralove)
;; =============================================================================

(require "../sc2-types.rkt")

(provide PvT-BUILD-ORDER
         PvT-UNIT-BENCHMARKS)

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
    (pro-bo-goal 'build    'pylon                  1 14 #f                 17.4)  ;; 0:17
    (pro-bo-goal 'build    'gateway                1 16 'pylon            35.5)  ;; 0:36
    (pro-bo-goal 'build    'assimilator            1 16 'pylon            46.8)  ;; 0:47
    (pro-bo-goal 'expand   'nexus                  2 19 #f                 93.1)  ;; 1:33
    (pro-bo-goal 'build    'cybernetics-core       1 19 'gateway          82.4)  ;; 1:22
    (pro-bo-goal 'build    'assimilator            2 21 'cybernetics-core 109.2) ;; 1:49
    (pro-bo-goal 'build    'pylon                  2 21 'cybernetics-core 112.0) ;; 1:52
    (pro-bo-goal 'research 'warp-gate-research     1 22 'cybernetics-core 123.0) ;; 2:03
    (pro-bo-goal 'train    'stalker                2 23 'cybernetics-core 152.4) ;; 2:32
    ;; 26-38 Robo + Twilight + 3-Gate timing & Charge
    (pro-bo-goal 'build    'robotics-facility      1 26 'cybernetics-core 248.7) ;; 4:09
    (pro-bo-goal 'build    'twilight-council       1 28 'cybernetics-core 151.2) ;; 2:31
    (pro-bo-goal 'build    'gateway                2 30 'cybernetics-core 192.3) ;; 3:12
    (pro-bo-goal 'build    'gateway                3 32 'cybernetics-core 225.0) ;; 3:45
    (pro-bo-goal 'train    'immortal               1 34 'robotics-facility 295.0) ;; 4:55
    (pro-bo-goal 'train    'observer               1 36 'robotics-facility 290.0) ;; 4:50
    (pro-bo-goal 'research 'charge                 1 38 'twilight-council 310.8) ;; 5:11
    ;; 42-96 +1 Ground, 3rd Nexus, Robotics Bay, Thermal Lance, Templar Archive & 4th Nexus
    (pro-bo-goal 'expand   'nexus                  3 42 'robotics-facility 245.0) ;; 4:05 (3rd Base!)
    (pro-bo-goal 'build    'assimilator            3 46 'robotics-facility 258.0) ;; 4:18 (Pro Gas #3 @ 36w)
    (pro-bo-goal 'build    'assimilator            4 52 'robotics-facility 292.0) ;; 4:52 (Pro Gas #4 @ 39w)
    (pro-bo-goal 'build    'robotics-bay           1 56 'robotics-facility 307.5) ;; 5:08
    (pro-bo-goal 'build    'forge                  1 60 'cybernetics-core 340.0) ;; 5:40
    (pro-bo-goal 'build    'templar-archive        1 64 'twilight-council  350.0) ;; 5:50
    (pro-bo-goal 'research 'protoss-ground-weapons-1 1 68 'forge           358.7) ;; 5:59
    (pro-bo-goal 'research 'extended-thermal-lance 1 72 'robotics-bay     361.4) ;; 6:01
    (pro-bo-goal 'build    'gateway                4 78 'cybernetics-core  385.0) ;; 6:25
    (pro-bo-goal 'build    'gateway                5 84 'cybernetics-core  405.0) ;; 6:45
    (pro-bo-goal 'build    'gateway                6 88 'cybernetics-core  420.0) ;; 7:00
    (pro-bo-goal 'expand   'nexus                  4 94 'robotics-bay      440.0)) ;; 7:20 (4th Base Macro!)
   ;; Empirical pro 4+ base macro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (17.0 .  1.0))
     (2 . (21.0 .  3.0))
     (3 . (28.0 .  8.0))
     (4 . (39.0 . 11.0))
     (5 . (49.0 . 18.0))
     (6 . (59.0 . 26.0))
     (7 . (66.0 . 36.0))
     (8 . (70.0 . 54.0))
     (9 . (70.0 . 74.0))
     (10 . (70.0 . 94.0)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'adept    1 23 108.3 'cybernetics-core)  ;; 1:48
    (pro-unit-timing 'stalker  2 31 152.4 'cybernetics-core)  ;; 2:32
    (pro-unit-timing 'observer 1 50 285.0 'robotics-facility) ;; 4:45
    (pro-unit-timing 'sentry   2 56 298.4 'cybernetics-core)  ;; 4:58
    (pro-unit-timing 'stalker  5 58 298.6 'cybernetics-core)  ;; 4:59
    (pro-unit-timing 'stalker  9 69 326.5 'cybernetics-core)  ;; 5:27
    (pro-unit-timing 'zealot   4 77 346.1 'gateway)           ;; 5:46
    (pro-unit-timing 'zealot  12 95 382.4 'gateway))          ;; 6:22
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'warp-gate-research       123.0 223.0 23 'cybernetics-core) ;; 2:03 -> 3:43
    (pro-upgrade-timing 'blink                    189.2 310.2 37 'twilight-council) ;; 3:09 -> 5:10
    (pro-upgrade-timing 'charge                   310.8 410.8 61 'twilight-council) ;; 5:11 -> 6:51
    (pro-upgrade-timing 'psi-storm                355.4 434.4 64 'templar-archive)  ;; 5:55 -> 7:14
    (pro-upgrade-timing 'protoss-ground-weapons-1 358.7 472.7 73 'forge)            ;; 5:59 -> 7:53
    (pro-upgrade-timing 'extended-thermal-lance   361.4 461.4 91 'robotics-bay))))  ;; 6:01 -> 7:41

;; Full 1..8+ min pro unit composition benchmarks (PvT) covering core, harass, drops & casters.
(: PvT-UNIT-BENCHMARKS (Listof pro-unit-timing))
(define PvT-UNIT-BENCHMARKS
  (list
   (pro-unit-timing 'adept        1 23 108.3 'cybernetics-core)
   (pro-unit-timing 'stalker      2 31 152.4 'cybernetics-core)
   (pro-unit-timing 'oracle       1 42 225.0 'stargate)
   (pro-unit-timing 'warp-prism   1 46 250.0 'robotics-facility)
   (pro-unit-timing 'observer     1 50 285.0 'robotics-facility)
   (pro-unit-timing 'sentry       2 56 298.4 'cybernetics-core)
   (pro-unit-timing 'stalker      5 58 298.6 'cybernetics-core)
   (pro-unit-timing 'immortal     1 62 310.0 'robotics-facility)
   (pro-unit-timing 'stalker      9 69 326.5 'cybernetics-core)
   (pro-unit-timing 'zealot       4 77 346.1 'gateway)
   (pro-unit-timing 'colossus     1 84 370.0 'robotics-bay)
   (pro-unit-timing 'zealot      12 95 382.4 'gateway)
   (pro-unit-timing 'high-templar 2 104 415.0 'templar-archive)
   (pro-unit-timing 'disruptor    1 110 435.0 'robotics-bay)
   (pro-unit-timing 'stalker     14 118 455.0 'cybernetics-core)
   (pro-unit-timing 'zealot      16 124 465.0 'gateway)
   (pro-unit-timing 'colossus     3 130 475.0 'robotics-bay)
   (pro-unit-timing 'immortal     4 134 482.0 'robotics-facility)
   (pro-unit-timing 'high-templar 5 140 490.0 'templar-archive)
   (pro-unit-timing 'archon       3 144 495.0 'templar-archive)
   (pro-unit-timing 'disruptor    3 148 500.0 'robotics-bay)
   (pro-unit-timing 'observer     3 150 503.0 'robotics-facility)
   (pro-unit-timing 'adept        4 152 505.0 'cybernetics-core)
   (pro-unit-timing 'warp-prism   2 154 510.0 'robotics-facility)))
