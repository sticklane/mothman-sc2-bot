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
    ;; 36-62 Roach Warren -> Lair -> +1 Missile -> Hydralisk transition
    (pro-bo-goal 'build    'roach-warren           1 36 'spawning-pool     233.9) ;; 3:54
    (pro-bo-goal 'build    'extractor              2 38 'spawning-pool     240.8) ;; 4:01
    (pro-bo-goal 'morph    'lair                   1 44 'spawning-pool     279.2) ;; 4:39
    (pro-bo-goal 'build    'evolution-chamber      1 46 'spawning-pool     233.5) ;; 3:54
    (pro-bo-goal 'build    'extractor              3 50 'lair              263.5) ;; 4:24
    (pro-bo-goal 'research 'glial-reconstitution   1 52 'lair              340.4) ;; 5:40
    (pro-bo-goal 'research 'zerg-missile-weapons-1 1 54 'evolution-chamber 277.4) ;; 4:37
    (pro-bo-goal 'research 'burrow                 1 58 'hatchery          356.8) ;; 5:57
    (pro-bo-goal 'build    'hydralisk-den          1 62 'lair              375.0)) ;; 6:15
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (15.0 .  2.0))
     (2 . (20.0 .  4.0))
     (3 . (24.5 .  8.0))
     (4 . (34.0 . 16.0))
     (5 . (38.0 . 26.0))
     (6 . (42.0 . 38.0))
     (7 . (48.0 . 54.5)))
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
