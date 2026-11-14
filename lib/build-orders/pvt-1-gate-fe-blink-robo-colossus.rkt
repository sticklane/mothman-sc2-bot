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
    ;; 42-64 +1 Ground, Robotics Bay, 3rd Nexus & Thermal Lance
    (pro-bo-goal 'build    'assimilator            3 42 'robotics-facility 253.8) ;; 4:14
    (pro-bo-goal 'build    'forge                  1 48 'cybernetics-core 357.3) ;; 5:57
    (pro-bo-goal 'research 'protoss-ground-weapons-1 1 52 'forge           358.7) ;; 5:59
    (pro-bo-goal 'build    'robotics-bay           1 56 'robotics-facility 307.5) ;; 5:08
    (pro-bo-goal 'expand   'nexus                  3 60 'robotics-facility 233.0) ;; 3:53
    (pro-bo-goal 'research 'extended-thermal-lance 1 64 'robotics-bay     361.4)) ;; 6:01
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (17.0 .  1.0))
     (2 . (21.0 .  3.0))
     (3 . (27.0 .  8.0))
     (4 . (38.0 . 11.0))
     (5 . (44.0 . 16.0))
     (6 . (48.5 . 23.0))
     (7 . (60.0 . 30.0)))
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
