#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/zvt-16-hatch-macro-roach-ravager.rkt`
;; ZvT — 16 Hatch / 3-Base Ling-Bane-Roach-Hydra
;; Exemplar: Serral vs SpeCial (Proxima Station LE, WCS Austin)
;; =============================================================================

(require "../sc2-types.rkt")

(provide ZvT-BUILD-ORDER)

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
    ;; 30-44 Third Hatchery, 3rd Queen, defensive Roach Warren & Baneling Nest
    (pro-bo-goal 'expand   'hatchery               3 30 'spawning-pool     164.4) ;; 2:44
    (pro-bo-goal 'train    'queen                  3 32 'spawning-pool     172.8) ;; 2:53
    (pro-bo-goal 'build    'roach-warren           1 36 'spawning-pool     249.7) ;; 4:10
    (pro-bo-goal 'build    'baneling-nest          1 38 'spawning-pool     309.0) ;; 5:09
    (pro-bo-goal 'build    'extractor              2 40 'spawning-pool     233.3) ;; 3:53
    (pro-bo-goal 'build    'extractor              3 44 'spawning-pool     271.3) ;; 4:31
    ;; 46-68 Lair, Upgrades, and Hydra Den transition
    (pro-bo-goal 'morph    'lair                   1 46 'spawning-pool     262.0) ;; 4:22
    (pro-bo-goal 'build    'evolution-chamber      1 48 'spawning-pool     301.9) ;; 5:02
    (pro-bo-goal 'research 'glial-reconstitution   1 54 'lair              345.3) ;; 5:45
    (pro-bo-goal 'research 'centrifical-hooks      1 56 'lair              382.0) ;; 6:22
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 58 'evolution-chamber 374.1) ;; 6:14
    (pro-bo-goal 'build    'hydralisk-den          1 62 'lair              380.0) ;; 6:20
    (pro-bo-goal 'build    'extractor              4 64 'lair              317.4) ;; 5:17
    (pro-bo-goal 'research 'grooved-spines         1 68 'hydralisk-den     405.0)) ;; 6:45
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  1.0))
     (2 . (19.0 .  4.0))
     (3 . (24.0 . 10.0))
     (4 . (35.0 . 17.0))
     (5 . (44.5 . 23.5))
     (6 . (49.0 . 29.0))
     (7 . (63.5 . 38.0)))
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
