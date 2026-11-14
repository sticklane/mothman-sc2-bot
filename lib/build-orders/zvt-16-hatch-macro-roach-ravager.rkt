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
    (pro-bo-goal 'train    'overlord               2 13 #f)
    (pro-bo-goal 'expand   'hatchery               2 16 #f)
    (pro-bo-goal 'build    'extractor              1 17 #f)
    (pro-bo-goal 'build    'spawning-pool          1 17 #f)
    (pro-bo-goal 'train    'overlord               3 19 #f)
    (pro-bo-goal 'train    'queen                  2 20 'spawning-pool)
    (pro-bo-goal 'train    'zergling               4 20 'spawning-pool)
    (pro-bo-goal 'research 'metabolic-boost        1 22 'spawning-pool)
    ;; 30-44 Third Hatchery, 3rd Queen, defensive Roach Warren & Baneling Nest
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
   '((1 . (15.0 .  1.0))
     (2 . (19.0 .  4.0))
     (3 . (24.0 . 10.0))
     (4 . (35.0 . 17.0))
     (5 . (44.5 . 23.5))
     (6 . (49.0 . 29.0))
     (7 . (63.5 . 38.0)))))
