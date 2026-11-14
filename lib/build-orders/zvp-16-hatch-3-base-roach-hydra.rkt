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
    (pro-bo-goal 'train    'overlord               2 13 #f)
    (pro-bo-goal 'expand   'hatchery               2 16 #f)
    (pro-bo-goal 'build    'extractor              1 17 #f)
    (pro-bo-goal 'build    'spawning-pool          1 17 #f)
    (pro-bo-goal 'train    'overlord               3 19 #f)
    (pro-bo-goal 'train    'queen                  2 20 'spawning-pool)
    (pro-bo-goal 'train    'zergling               4 20 'spawning-pool)
    (pro-bo-goal 'research 'metabolic-boost        1 22 'spawning-pool)
    ;; 30-44 Fast 3rd Hatchery, Queens, Roach Warren & Baneling Nest
    (pro-bo-goal 'expand   'hatchery               3 30 'spawning-pool)
    (pro-bo-goal 'train    'queen                  3 32 'spawning-pool)
    (pro-bo-goal 'build    'roach-warren           1 36 'spawning-pool)
    (pro-bo-goal 'build    'baneling-nest          1 38 'spawning-pool)
    (pro-bo-goal 'build    'extractor              2 40 'spawning-pool)
    (pro-bo-goal 'build    'extractor              3 44 'spawning-pool)
    ;; 46-68 Lair, Upgrades, and Hydra Den transition
    (pro-bo-goal 'morph    'lair                   1 46 'spawning-pool)
    (pro-bo-goal 'build    'evolution-chamber      1 48 'spawning-pool)
    (pro-bo-goal 'research 'glial-reconstitution   1 54 'lair)
    (pro-bo-goal 'research 'centrifical-hooks      1 56 'lair)
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 58 'evolution-chamber)
    (pro-bo-goal 'build    'hydralisk-den          1 62 'lair)
    (pro-bo-goal 'build    'extractor              4 64 'lair)
    (pro-bo-goal 'research 'grooved-spines         1 68 'hydralisk-den))
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  2.0))
     (2 . (20.0 .  2.0))
     (3 . (25.0 . 10.0))
     (4 . (35.0 . 16.0))
     (5 . (48.0 . 21.0))
     (6 . (58.5 . 28.0))
     (7 . (62.0 . 51.0)))))
