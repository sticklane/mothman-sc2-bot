#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/zvp-16-hatch-3-base-roach-hydra.rkt`
;; ZvP — 16 Hatch / 3-Base Roach-Hydra-Bane Macro
;; Exemplar: Serral vs sOs (Lost and Found LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide ZvP-BUILD-ORDER
         ZvP-UNIT-BENCHMARKS)

(: ZvP-BUILD-ORDER build-order-spec)
(define ZvP-BUILD-ORDER
  (build-order-spec
   'ZvP
   'Zerg
   "16 Hatch / 3-Base Roach-Hydra"
   'roach-hydra
   "Rapid 3-base Drone surge into Roach/Ling defense against Protoss timings, scaling to Lair/Hydralisk Range."
   (list
    ;; 13-22 Standard 16 Hatch / 17 Gas / 17 Pool -> Ling Speed
    (pro-bo-goal 'train    'overlord               2 13 #f                 12.4)  ;; 0:12
    (pro-bo-goal 'expand   'hatchery               2 16 #f                 48.7)  ;; 0:49
    (pro-bo-goal 'build    'extractor              1 17 #f                 64.8)  ;; 1:05
    (pro-bo-goal 'build    'spawning-pool          1 17 #f                 73.3)  ;; 1:13
    (pro-bo-goal 'train    'overlord               3 19 #f                 100.0) ;; 1:40
    (pro-bo-goal 'train    'queen                  2 20 'spawning-pool     151.4) ;; 2:31
    (pro-bo-goal 'train    'zergling               4 20 'spawning-pool     139.4) ;; 2:19
    (pro-bo-goal 'research 'metabolic-boost        1 22 'spawning-pool     134.6) ;; 2:15
    ;; 30-52 Fast 3rd Hatchery (~2:43), Queens #3-#4, Pro Geyser #2, Roach Warren, then Lair/BaneNest/Evo
    (pro-bo-goal 'expand   'hatchery               3 30 'spawning-pool     162.9) ;; 2:43
    (pro-bo-goal 'train    'queen                  3 32 'spawning-pool     205.0) ;; 3:25
    (pro-bo-goal 'build    'extractor              2 34 'spawning-pool     227.5) ;; 3:48 (Pro Gas #2 @ ~30w)
    (pro-bo-goal 'train    'queen                  4 42 'spawning-pool     245.0) ;; 4:05 (Pro Queen #4 @ ~4:09-4:24)
    (pro-bo-goal 'build    'roach-warren           1 44 'spawning-pool     250.0) ;; 4:10
    (pro-bo-goal 'build    'extractor              3 48 'spawning-pool     278.1) ;; 4:38 (Pro Gas #3 @ ~40w)
    (pro-bo-goal 'morph    'lair                   1 48 'spawning-pool     285.0) ;; 4:45 (strictly after 3rd Hatch!)
    (pro-bo-goal 'build    'baneling-nest          1 52 'spawning-pool     295.0) ;; 4:55 (deferred behind 3rd Hatch!)
    ;; 54-110 4th Hatchery, Upgrades, Hydra/Lurker Den & Hive 5th-Base Macro
    (pro-bo-goal 'build    'evolution-chamber      1 54 'spawning-pool     305.0) ;; 5:05 (Pro Evo ~5:04-5:14)
    (pro-bo-goal 'build    'extractor              4 58 'lair              308.1) ;; 5:08 (Pro Gas #4 @ ~47w)
    (pro-bo-goal 'expand   'hatchery               4 62 'lair              325.0) ;; 5:25 (4th Base Macro!)
    (pro-bo-goal 'research 'glial-reconstitution   1 64 'lair              341.7) ;; 5:42
    (pro-bo-goal 'build    'hydralisk-den          1 66 'lair              352.0) ;; 5:52
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 68 'evolution-chamber 365.6) ;; 6:06
    (pro-bo-goal 'research 'grooved-spines         1 72 'hydralisk-den     388.8) ;; 6:29
    (pro-bo-goal 'build    'lurker-den             1 82 'hydralisk-den     415.0) ;; 6:55
    (pro-bo-goal 'build    'infestation-pit        1 90 'lair              440.0) ;; 7:20
    (pro-bo-goal 'morph    'hive                   1 98 'infestation-pit   470.0) ;; 7:50
    (pro-bo-goal 'expand   'hatchery               5 106 'lair             485.0) ;; 8:05 (5th Base Macro!)
    (pro-bo-goal 'research 'adaptive-talons        1 112 'hive             515.0)) ;; 8:35
   ;; Empirical pro 4+ base macro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  2.0))
     (2 . (20.0 .  2.0))
     (3 . (28.0 .  8.0))
     (4 . (38.0 . 14.0))
     (5 . (50.0 . 21.0))
     (6 . (61.0 . 28.0))
     (7 . (68.0 . 51.0))
     (8 . (74.0 . 64.0))
     (9 . (76.0 . 78.0))
     (10 . (76.0 . 92.0)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'overlord 2 13  12.4 #f)             ;; 0:12
    (pro-unit-timing 'zergling 4 25 139.4 'spawning-pool) ;; 2:19
    (pro-unit-timing 'queen    2 27 151.4 'spawning-pool) ;; 2:31
    (pro-unit-timing 'queen    3 41 214.3 'spawning-pool) ;; 3:34
    (pro-unit-timing 'zergling 8 56 256.5 'spawning-pool) ;; 4:17
    (pro-unit-timing 'queen    4 59 264.3 'spawning-pool) ;; 4:24
    (pro-unit-timing 'roach    7 85 326.1 'roach-warren)  ;; 5:26
    (pro-unit-timing 'overseer 2 86 332.3 'lair))         ;; 5:32
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'metabolic-boost        134.6 213.6 28 'spawning-pool)     ;; 2:15 -> 3:34
    (pro-upgrade-timing 'zerg-melee-weapons-1   337.3 451.3 79 'evolution-chamber) ;; 5:37 -> 7:31
    (pro-upgrade-timing 'zerg-ground-armor-1    341.0 455.0 78 'evolution-chamber) ;; 5:41 -> 7:35
    (pro-upgrade-timing 'glial-reconstitution   341.7 420.7 86 'roach-warren)      ;; 5:42 -> 7:01
    (pro-upgrade-timing 'zerg-missile-weapons-1 365.6 479.6 94 'evolution-chamber) ;; 6:06 -> 8:00
    (pro-upgrade-timing 'grooved-spines         388.8 438.8 96 'hydralisk-den))))    ;; 6:29 -> 7:19

;; Full 1..8+ min pro unit composition benchmarks (ZvP) covering core, harass, drops & casters.
(: ZvP-UNIT-BENCHMARKS (Listof pro-unit-timing))
(define ZvP-UNIT-BENCHMARKS
  (list
   (pro-unit-timing 'overlord           2 13  12.4 #f)
   (pro-unit-timing 'zergling           4 25 139.4 'spawning-pool)
   (pro-unit-timing 'queen              2 27 151.4 'spawning-pool)
   (pro-unit-timing 'queen              3 41 214.3 'spawning-pool)
   (pro-unit-timing 'overlord-transport 1 54 255.0 'lair)
   (pro-unit-timing 'zergling           8 56 256.5 'spawning-pool)
   (pro-unit-timing 'queen              4 59 264.3 'spawning-pool)
   (pro-unit-timing 'roach              7 85 326.1 'roach-warren)
   (pro-unit-timing 'overseer           2 86 332.3 'lair)
   (pro-unit-timing 'baneling           4 88 345.0 'baneling-nest)
   (pro-unit-timing 'ravager            3 92 365.0 'roach-warren)
   (pro-unit-timing 'overlord-transport 2 94 375.0 'lair)
   (pro-unit-timing 'hydralisk          8 98 400.0 'hydralisk-den)
   (pro-unit-timing 'roach             12 106 420.0 'roach-warren)
   (pro-unit-timing 'lurker-mp          3 116 450.0 'lurker-den)
   (pro-unit-timing 'zergling          20 122 465.0 'spawning-pool)
   (pro-unit-timing 'baneling           8 126 470.0 'baneling-nest)
   (pro-unit-timing 'hydralisk         16 132 480.0 'hydralisk-den)
   (pro-unit-timing 'ravager            6 138 490.0 'roach-warren)
   (pro-unit-timing 'lurker-mp          6 144 495.0 'lurker-den)
   (pro-unit-timing 'overseer           3 148 500.0 'lair)
   (pro-unit-timing 'viper              3 154 510.0 'hive)))
