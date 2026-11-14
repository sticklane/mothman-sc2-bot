#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/zvp-16-hatch-3-base-roach-hydra.rkt`
;; ZvP — 16 Hatch / 3-Base Roach-Hydra-Bane Macro
;; Exemplar: Serral vs sOs (Lost and Found LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide ZvP-BUILD-ORDER)

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
    ;; 30-44 Fast 3rd Hatchery, Queens, Roach Warren & Baneling Nest
    (pro-bo-goal 'expand   'hatchery               3 30 'spawning-pool     162.9) ;; 2:43
    (pro-bo-goal 'train    'queen                  3 32 'spawning-pool     214.3) ;; 3:34
    (pro-bo-goal 'build    'roach-warren           1 36 'spawning-pool     280.8) ;; 4:41
    (pro-bo-goal 'build    'baneling-nest          1 38 'spawning-pool     295.0) ;; 4:55
    (pro-bo-goal 'build    'extractor              2 40 'spawning-pool     227.5) ;; 3:48
    (pro-bo-goal 'build    'extractor              3 44 'spawning-pool     278.1) ;; 4:38
    ;; 46-68 Lair, Upgrades, and Hydra Den transition
    (pro-bo-goal 'morph    'lair                   1 46 'spawning-pool     272.2) ;; 4:32
    (pro-bo-goal 'build    'evolution-chamber      1 48 'spawning-pool     304.5) ;; 5:05
    (pro-bo-goal 'research 'glial-reconstitution   1 54 'lair              341.7) ;; 5:42
    (pro-bo-goal 'research 'centrifical-hooks      1 56 'lair              355.0) ;; 5:55
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 58 'evolution-chamber 365.6) ;; 6:06
    (pro-bo-goal 'build    'hydralisk-den          1 62 'lair              362.8) ;; 6:03
    (pro-bo-goal 'build    'extractor              4 64 'lair              308.1) ;; 5:08
    (pro-bo-goal 'research 'grooved-spines         1 68 'hydralisk-den     388.8)) ;; 6:29
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  2.0))
     (2 . (20.0 .  2.0))
     (3 . (25.0 . 10.0))
     (4 . (35.0 . 16.0))
     (5 . (48.0 . 21.0))
     (6 . (58.5 . 28.0))
     (7 . (62.0 . 51.0)))
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
