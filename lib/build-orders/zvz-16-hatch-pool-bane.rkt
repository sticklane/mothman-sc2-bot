#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/zvz-16-hatch-pool-bane.rkt`
;; ZvZ — 16 Hatch / 17 Pool / Ling-Bane into Roach Timing
;; Exemplar: Serral vs Elazer (Ascension to Aiur LE, WCS Montreal)
;; =============================================================================

(require "../sc2-types.rkt")

(provide ZvZ-BUILD-ORDER
         ZvZ-UNIT-BENCHMARKS)

(: ZvZ-BUILD-ORDER build-order-spec)
(define ZvZ-BUILD-ORDER
  (build-order-spec
   'ZvZ
   'Zerg
   "16 Hatch / 17 Pool / Baneling-Roach"
   'ling-bane-roach
   "Safe macro natural into Ling/Bane speed defense, fast 3rd Hatchery, and +1 Missile Roach-Ravager transition."
   (list
    ;; 13-17 Opening: Overlord scout -> natural Hatchery -> gas + Pool
    (pro-bo-goal 'train    'overlord               2 13 #f                 13.0)  ;; 0:13
    (pro-bo-goal 'expand   'hatchery               2 16 #f                 51.1)  ;; 0:51
    (pro-bo-goal 'build    'extractor              1 17 #f                 68.9)  ;; 1:09
    (pro-bo-goal 'build    'spawning-pool          1 17 #f                 72.5)  ;; 1:13
    (pro-bo-goal 'train    'overlord               3 19 #f                 99.5)  ;; 1:40
    ;; 20-28 Ling/Bane stabilization & third base
    (pro-bo-goal 'train    'queen                  2 20 'spawning-pool     122.1) ;; 2:02
    (pro-bo-goal 'train    'zergling               6 20 'spawning-pool     128.0) ;; 2:08
    (pro-bo-goal 'research 'metabolic-boost        1 22 'spawning-pool     129.5) ;; 2:10
    (pro-bo-goal 'build    'baneling-nest          1 28 'spawning-pool     148.5) ;; 2:29
    (pro-bo-goal 'expand   'hatchery               3 30 'spawning-pool     170.4) ;; 2:50
    ;; 36-108 Roach Warren -> Lair -> +1 Missile -> 4th Base -> Hydra/Lurker/Hive Macro
    (pro-bo-goal 'build    'roach-warren           1 36 'spawning-pool     233.9) ;; 3:54
    (pro-bo-goal 'build    'evolution-chamber      1 38 'spawning-pool     235.0) ;; 3:55
    (pro-bo-goal 'build    'extractor              2 38 'spawning-pool     240.8) ;; 4:01 (Pro Gas #2 @ ~31w)
    (pro-bo-goal 'morph    'lair                   1 44 'spawning-pool     265.0) ;; 4:25
    (pro-bo-goal 'build    'extractor              3 50 'lair              275.0) ;; 4:35 (Pro Gas #3 @ ~39w)
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 54 'evolution-chamber 280.0) ;; 4:40
    (pro-bo-goal 'research 'glial-reconstitution   1 56 'lair              325.0) ;; 5:25
    (pro-bo-goal 'build    'extractor              4 60 'lair              340.0) ;; 5:40 (Pro Gas #4 @ ~46w)
    (pro-bo-goal 'expand   'hatchery               4 64 'lair              350.0) ;; 5:50 (4th Base Macro!)
    (pro-bo-goal 'build    'hydralisk-den          1 68 'lair              375.0) ;; 6:15
    (pro-bo-goal 'research 'grooved-spines         1 74 'hydralisk-den     400.0) ;; 6:40
    (pro-bo-goal 'build    'lurker-den             1 84 'hydralisk-den     430.0) ;; 7:10
    (pro-bo-goal 'build    'infestation-pit        1 92 'lair              455.0) ;; 7:35
    (pro-bo-goal 'morph    'hive                   1 100 'infestation-pit  485.0) ;; 8:05
    (pro-bo-goal 'expand   'hatchery               5 108 'lair             500.0)) ;; 8:20 (5th Base Macro!)
   ;; Empirical pro 4+ base macro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  2.0))
     (2 . (20.0 .  4.0))
     (3 . (26.0 .  8.0))
     (4 . (34.0 . 16.0))
     (5 . (44.0 . 26.0))
     (6 . (54.0 . 38.0))
     (7 . (64.0 . 54.5))
     (8 . (70.0 . 66.0))
     (9 . (76.0 . 78.0))
     (10 . (76.0 . 90.0)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'overlord  2 13  13.0 #f)               ;; 0:13
    (pro-unit-timing 'queen     2 22 122.1 'spawning-pool)   ;; 2:02
    (pro-unit-timing 'zergling  6 24 140.0 'spawning-pool)   ;; 2:20
    (pro-unit-timing 'queen     3 41 202.6 'spawning-pool)   ;; 3:23
    (pro-unit-timing 'baneling  4 36 206.0 'baneling-nest)   ;; 3:26
    (pro-unit-timing 'queen     4 54 273.6 'spawning-pool)   ;; 4:34
    (pro-unit-timing 'roach     4 55 316.3 'roach-warren)    ;; 5:16
    (pro-unit-timing 'overseer  1 58 330.0 'lair)            ;; 5:30
    (pro-unit-timing 'ravager   2 68 345.5 'roach-warren))   ;; 5:46
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'metabolic-boost        129.5 208.5 26 'spawning-pool)     ;; 2:10 -> 3:29
    (pro-upgrade-timing 'zerg-melee-weapons-1   225.2 339.2 40 'evolution-chamber) ;; 3:45 -> 5:39
    (pro-upgrade-timing 'zerg-missile-weapons-1 277.4 391.4 59 'evolution-chamber) ;; 4:37 -> 6:31
    (pro-upgrade-timing 'centrifical-hooks      323.0 402.0 67 'baneling-nest)     ;; 5:23 -> 6:42
    (pro-upgrade-timing 'glial-reconstitution   340.4 419.5 74 'roach-warren)      ;; 5:40 -> 7:00
    (pro-upgrade-timing 'burrow                 356.8 427.8 70 'hatchery))))        ;; 5:57 -> 7:08

;; Full 1..8+ min pro unit composition benchmarks (ZvZ) covering core, harass, drops & casters.
(: ZvZ-UNIT-BENCHMARKS (Listof pro-unit-timing))
(define ZvZ-UNIT-BENCHMARKS
  (list
   (pro-unit-timing 'overlord           2 13  13.0 #f)
   (pro-unit-timing 'queen              2 22 122.1 'spawning-pool)
   (pro-unit-timing 'zergling           6 24 140.0 'spawning-pool)
   (pro-unit-timing 'queen              3 41 202.6 'spawning-pool)
   (pro-unit-timing 'baneling           4 36 206.0 'baneling-nest)
   (pro-unit-timing 'overlord-transport 1 48 255.0 'lair)
   (pro-unit-timing 'queen              4 54 273.6 'spawning-pool)
   (pro-unit-timing 'zergling          16 54 280.0 'spawning-pool)
   (pro-unit-timing 'roach              4 55 316.3 'roach-warren)
   (pro-unit-timing 'overseer           1 58 330.0 'lair)
   (pro-unit-timing 'ravager            2 68 345.5 'roach-warren)
   (pro-unit-timing 'overlord-transport 2 76 375.0 'lair)
   (pro-unit-timing 'roach             10 82 390.0 'roach-warren)
   (pro-unit-timing 'baneling           8 86 400.0 'baneling-nest)
   (pro-unit-timing 'hydralisk          6 94 415.0 'hydralisk-den)
   (pro-unit-timing 'overseer           2 96 420.0 'lair)
   (pro-unit-timing 'ravager            4 104 445.0 'roach-warren)
   (pro-unit-timing 'lurker-mp          2 112 455.0 'lurker-den)
   (pro-unit-timing 'roach             16 120 470.0 'roach-warren)
   (pro-unit-timing 'hydralisk         12 128 480.0 'hydralisk-den)
   (pro-unit-timing 'zergling          28 134 485.0 'spawning-pool)
   (pro-unit-timing 'lurker-mp          5 142 495.0 'lurker-den)
   (pro-unit-timing 'overseer           3 145 500.0 'lair)
   (pro-unit-timing 'viper              2 152 510.0 'hive)))
