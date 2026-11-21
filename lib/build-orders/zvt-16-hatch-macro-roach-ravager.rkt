#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/zvt-16-hatch-macro-roach-ravager.rkt`
;; ZvT — 16 Hatch / 3-Base Ling-Bane-Roach-Hydra
;; Exemplar: Serral vs SpeCial (Proxima Station LE, WCS Austin)
;; =============================================================================

(require "../sc2-types.rkt")

(provide ZvT-BUILD-ORDER
         ZvT-UNIT-BENCHMARKS)

(: ZvT-BUILD-ORDER build-order-spec)
(define ZvT-BUILD-ORDER
  (build-order-spec
   'ZvT
   'Zerg
   "16 Hatch / 3-Base Ling-Bane-Roach-Hydra"
   'ling-bane-hydra
   "Standard 16-Hatch 3-base opening into Ling/Bane/Roach midgame stability, Lair tech, and Grooved Spines Hydralisks."
   (list
    ;; 13-22 Standard 16 Hatch / 17 Gas / 17 Pool -> Ling Speed
    (pro-bo-goal 'train    'overlord               2 13 #f                 12.8)  ;; 0:13
    (pro-bo-goal 'expand   'hatchery               2 16 #f                 52.9)  ;; 0:53
    (pro-bo-goal 'build    'extractor              1 17 #f                 68.0)  ;; 1:08
    (pro-bo-goal 'build    'spawning-pool          1 17 #f                 71.1)  ;; 1:11
    (pro-bo-goal 'train    'overlord               3 19 #f                 100.1) ;; 1:40
    (pro-bo-goal 'train    'queen                  2 20 'spawning-pool     124.8) ;; 2:05
    (pro-bo-goal 'train    'zergling               4 20 'spawning-pool     125.2) ;; 2:05
    (pro-bo-goal 'research 'metabolic-boost        1 22 'spawning-pool     140.8) ;; 2:21
    ;; 30-50 Third Hatchery (~2:44), Queens #3-#4, Pro Geyser #2, Roach Warren, then Lair/BaneNest/Evo
    (pro-bo-goal 'expand   'hatchery               3 30 'spawning-pool     164.4) ;; 2:44
    (pro-bo-goal 'train    'queen                  3 32 'spawning-pool     172.8) ;; 2:53
    (pro-bo-goal 'build    'extractor              2 34 'spawning-pool     225.0) ;; 3:45 (Pro Gas #2 @ ~30w)
    (pro-bo-goal 'train    'queen                  4 36 'spawning-pool     215.7) ;; 3:36 (Pro Queen #4!)
    (pro-bo-goal 'build    'roach-warren           1 36 'spawning-pool     249.7) ;; 4:10
    (pro-bo-goal 'build    'baneling-nest          1 38 'spawning-pool     275.0) ;; 4:35 (deferred <4:30 unless Bio/pressure)
    (pro-bo-goal 'morph    'lair                   1 44 'spawning-pool     270.0) ;; 4:30 (strictly after 3rd Hatch!)
    (pro-bo-goal 'build    'extractor              3 48 'spawning-pool     278.0) ;; 4:38 (Pro Gas #3 @ ~40w)
    ;; 52-90 4th Hatchery, Upgrades, Hydra/Lurker Den & Hive 5th-Base Macro
    (pro-bo-goal 'build    'evolution-chamber      1 52 'spawning-pool     305.0) ;; 5:05 (Pro Evo ~5:04)
    (pro-bo-goal 'build    'extractor              4 58 'lair              317.4) ;; 5:17 (Pro Gas #4 @ ~48w)
    (pro-bo-goal 'expand   'hatchery               4 62 'lair              330.0) ;; 5:30 (4th Base Macro!)
    (pro-bo-goal 'research 'glial-reconstitution   1 64 'lair              345.3) ;; 5:45
    (pro-bo-goal 'build    'hydralisk-den          1 66 'lair              360.0) ;; 6:00
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 68 'evolution-chamber 374.1) ;; 6:14
    (pro-bo-goal 'research 'centrifical-hooks      1 70 'lair              382.0) ;; 6:22
    (pro-bo-goal 'research 'grooved-spines         1 74 'hydralisk-den     400.0) ;; 6:40
    (pro-bo-goal 'build    'lurker-den             1 82 'hydralisk-den     420.0) ;; 7:00
    (pro-bo-goal 'build    'infestation-pit        1 90 'lair              445.0) ;; 7:25
    (pro-bo-goal 'morph    'hive                   1 98 'infestation-pit   475.0) ;; 7:55
    (pro-bo-goal 'expand   'hatchery               5 106 'lair             490.0) ;; 8:10 (5th Base Macro!)
    (pro-bo-goal 'research 'adaptive-talons        1 112 'hive             525.0)) ;; 8:45
   ;; Empirical pro 4+ base macro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  1.0))
     (2 . (19.0 .  4.0))
     (3 . (28.0 .  8.0))
     (4 . (38.0 . 14.0))
     (5 . (44.5 . 23.5))
     (6 . (58.0 . 29.0))
     (7 . (66.0 . 38.0))
     (8 . (72.0 . 54.0))
     (9 . (76.0 . 70.0))
     (10 . (76.0 . 88.0)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'overlord  2 13  12.8 #f)             ;; 0:13
    (pro-unit-timing 'queen     2 24 124.8 'spawning-pool) ;; 2:05
    (pro-unit-timing 'zergling  4 24 125.2 'spawning-pool) ;; 2:05
    (pro-unit-timing 'queen     3 34 172.8 'spawning-pool) ;; 2:53
    (pro-unit-timing 'queen     4 45 215.7 'spawning-pool) ;; 3:36
    (pro-unit-timing 'zergling 10 71 288.0 'spawning-pool) ;; 4:48
    (pro-unit-timing 'roach     4 58 290.0 'roach-warren)  ;; 4:50
    (pro-unit-timing 'overseer  1 62 315.0 'lair)          ;; 5:15
    (pro-unit-timing 'baneling  4 74 330.0 'baneling-nest)) ;; 5:30
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'metabolic-boost        140.8 219.8 28 'spawning-pool)     ;; 2:21 -> 3:40
    (pro-upgrade-timing 'zerg-ground-armor-1    331.0 445.0 73 'evolution-chamber) ;; 5:31 -> 7:25
    (pro-upgrade-timing 'glial-reconstitution   345.3 424.3 85 'roach-warren)      ;; 5:45 -> 7:04
    (pro-upgrade-timing 'zerg-melee-weapons-1   354.2 468.2 76 'evolution-chamber) ;; 5:54 -> 7:48
    (pro-upgrade-timing 'zerg-missile-weapons-1 374.1 488.2 94 'evolution-chamber) ;; 6:14 -> 8:08
    (pro-upgrade-timing 'centrifical-hooks      382.0 461.0 90 'baneling-nest))))    ;; 6:22 -> 7:41

;; Full 1..8+ min pro unit composition benchmarks (ZvT) covering core, harass, drops & casters.
(: ZvT-UNIT-BENCHMARKS (Listof pro-unit-timing))
(define ZvT-UNIT-BENCHMARKS
  (list
   (pro-unit-timing 'overlord           2 13  12.8 #f)
   (pro-unit-timing 'queen              2 24 124.8 'spawning-pool)
   (pro-unit-timing 'zergling           4 24 125.2 'spawning-pool)
   (pro-unit-timing 'queen              3 34 172.8 'spawning-pool)
   (pro-unit-timing 'queen              4 45 215.7 'spawning-pool)
   (pro-unit-timing 'overlord-transport 1 56 260.0 'lair)
   (pro-unit-timing 'zergling          10 71 288.0 'spawning-pool)
   (pro-unit-timing 'roach              4 58 290.0 'roach-warren)
   (pro-unit-timing 'overseer           1 62 315.0 'lair)
   (pro-unit-timing 'baneling           4 74 330.0 'baneling-nest)
   (pro-unit-timing 'ravager            2 80 350.0 'roach-warren)
   (pro-unit-timing 'overlord-transport 2 84 375.0 'lair)
   (pro-unit-timing 'hydralisk          6 92 395.0 'hydralisk-den)
   (pro-unit-timing 'zergling          22 98 405.0 'spawning-pool)
   (pro-unit-timing 'baneling           8 104 420.0 'baneling-nest)
   (pro-unit-timing 'overseer           2 108 430.0 'lair)
   (pro-unit-timing 'lurker-mp          2 116 450.0 'lurker-den)
   (pro-unit-timing 'roach             12 122 465.0 'roach-warren)
   (pro-unit-timing 'hydralisk         14 130 475.0 'hydralisk-den)
   (pro-unit-timing 'ravager            4 136 485.0 'roach-warren)
   (pro-unit-timing 'lurker-mp          5 142 495.0 'lurker-den)
   (pro-unit-timing 'zergling          32 146 500.0 'spawning-pool)
   (pro-unit-timing 'baneling          12 148 502.0 'baneling-nest)
   (pro-unit-timing 'overseer           3 150 505.0 'lair)
   (pro-unit-timing 'viper              3 155 510.0 'hive)))
