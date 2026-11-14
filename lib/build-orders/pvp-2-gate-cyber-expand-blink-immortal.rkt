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
    (pro-bo-goal 'build    'pylon                  1 14 #f                 19.7)  ;; 0:20
    (pro-bo-goal 'build    'gateway                1 16 'pylon            42.4)  ;; 0:42
    (pro-bo-goal 'build    'assimilator            1 16 'pylon            47.7)  ;; 0:48
    (pro-bo-goal 'build    'gateway                2 17 'pylon            75.8)  ;; 1:16
    (pro-bo-goal 'build    'assimilator            2 18 'pylon            61.5)  ;; 1:02
    (pro-bo-goal 'build    'cybernetics-core       1 19 'gateway          90.8)  ;; 1:31
    (pro-bo-goal 'build    'pylon                  2 20 'cybernetics-core 105.0) ;; 1:45
    (pro-bo-goal 'research 'warp-gate-research     1 21 'cybernetics-core 133.1) ;; 2:13
    (pro-bo-goal 'train    'stalker                2 21 'cybernetics-core 145.0) ;; 2:25
    ;; 26-40 Natural Nexus -> Sentry -> Robo/Twilight -> Blink
    (pro-bo-goal 'expand   'nexus                  2 26 'cybernetics-core 160.2) ;; 2:40
    (pro-bo-goal 'train    'sentry                 1 28 'cybernetics-core 185.0) ;; 3:05
    (pro-bo-goal 'build    'robotics-facility      1 29 'cybernetics-core 205.2) ;; 3:25
    (pro-bo-goal 'build    'twilight-council       1 32 'cybernetics-core 217.7) ;; 3:38
    (pro-bo-goal 'train    'immortal               1 34 'robotics-facility 258.6) ;; 4:19
    (pro-bo-goal 'train    'observer               1 36 'robotics-facility 245.0) ;; 4:05
    (pro-bo-goal 'build    'gateway                3 38 'cybernetics-core 265.0) ;; 4:25
    (pro-bo-goal 'research 'blink                  1 40 'twilight-council 280.0) ;; 4:40
    ;; 44-60 +1 Weapons, Robotics Bay & 3rd Nexus
    (pro-bo-goal 'build    'assimilator            3 44 'robotics-facility 300.0) ;; 5:00
    (pro-bo-goal 'build    'forge                  1 48 'cybernetics-core 326.8) ;; 5:27
    (pro-bo-goal 'research 'protoss-ground-weapons-1 1 52 'forge           320.8) ;; 5:21
    (pro-bo-goal 'build    'robotics-bay           1 56 'robotics-facility 350.0) ;; 5:50
    (pro-bo-goal 'expand   'nexus                  3 60 'robotics-facility 369.5)) ;; 6:10
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (17.0 .  1.0))
     (2 . (22.0 .  1.0))
     (3 . (24.0 .  8.0))
     (4 . (26.0 . 11.5))
     (5 . (29.5 . 19.0))
     (6 . (35.0 . 25.0))
     (7 . (40.0 . 32.0)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'adept    2 24 117.4 'cybernetics-core)  ;; 1:57
    (pro-unit-timing 'stalker  2 33 241.8 'cybernetics-core)  ;; 4:02
    (pro-unit-timing 'observer 1 33 245.0 'robotics-facility) ;; 4:05
    (pro-unit-timing 'immortal 1 34 258.6 'robotics-facility) ;; 4:19
    (pro-unit-timing 'zealot   2 38 272.1 'gateway)           ;; 4:32
    (pro-unit-timing 'sentry   1 43 301.4 'cybernetics-core)  ;; 5:01
    (pro-unit-timing 'stalker  5 44 321.5 'cybernetics-core)) ;; 5:22
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'warp-gate-research       133.1 233.1 24 'cybernetics-core) ;; 2:13 -> 3:53
    (pro-upgrade-timing 'charge                   320.0 420.0 60 'twilight-council) ;; 5:20 -> 7:00
    (pro-upgrade-timing 'protoss-ground-weapons-1 320.8 434.8 61 'forge)            ;; 5:21 -> 7:15
    (pro-upgrade-timing 'protoss-ground-weapons-2 408.6 544.6 77 'forge))))          ;; 6:49 -> 9:05
