#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/zvz-16-hatch-pool-bane.rkt`
;; ZvZ — 16 Hatch / 17 Pool / Ling-Bane into Roach Timing
;; Exemplar: Serral vs Elazer (Ascension to Aiur LE, WCS Montreal)
;; =============================================================================

(require "../sc2-types.rkt")

(provide ZvZ-BUILD-ORDER)

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
    (pro-bo-goal 'train    'overlord               2 13 #f)
    (pro-bo-goal 'expand   'hatchery               2 16 #f)
    (pro-bo-goal 'build    'extractor              1 17 #f)
    (pro-bo-goal 'build    'spawning-pool          1 17 #f)
    (pro-bo-goal 'train    'overlord               3 19 #f)
    ;; 20-28 Ling/Bane stabilization & third base
    (pro-bo-goal 'train    'queen                  2 20 'spawning-pool)
    (pro-bo-goal 'train    'zergling               6 20 'spawning-pool)
    (pro-bo-goal 'research 'metabolic-boost        1 22 'spawning-pool)
    (pro-bo-goal 'build    'baneling-nest          1 28 'spawning-pool)
    (pro-bo-goal 'expand   'hatchery               3 30 'spawning-pool)
    ;; 36-62 Roach Warren -> Lair -> +1 Missile -> Hydralisk transition
    (pro-bo-goal 'build    'roach-warren           1 36 'spawning-pool)
    (pro-bo-goal 'build    'extractor              2 38 'spawning-pool)
    (pro-bo-goal 'morph    'lair                   1 44 'spawning-pool)
    (pro-bo-goal 'build    'evolution-chamber      1 46 'spawning-pool)
    (pro-bo-goal 'build    'extractor              3 50 'lair)
    (pro-bo-goal 'research 'glial-reconstitution   1 52 'lair)
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 54 'evolution-chamber)
    (pro-bo-goal 'research 'burrow                 1 58 'hatchery)
    (pro-bo-goal 'build    'hydralisk-den          1 62 'lair))
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  2.0))
     (2 . (20.0 .  4.0))
     (3 . (24.5 .  8.0))
     (4 . (34.0 . 16.0))
     (5 . (38.0 . 26.0))
     (6 . (42.0 . 38.0))
     (7 . (48.0 . 54.5)))))
