#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/tvp-reaper-fe-3-rax-stim-medivac.rkt`
;; TvP — Reaper FE into 1-1-1 & 3-Rax Stim Medivac Timing
;; Exemplar: VITmaru vs ShoWTimE (Pylon LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide TvP-BUILD-ORDER)

(: TvP-BUILD-ORDER build-order-spec)
(define TvP-BUILD-ORDER
  (build-order-spec
   'TvP
   'Terran
   "Reaper FE into 3-Rax Stim Medivac Timing"
   'bio-medivac
   "Fast natural Command Center into Reactor Starport Medivacs, Stim/Combat/Concussive Bio push, and 3rd base behind."
   (list
    ;; 14-22 Reaper FE -> Stim + Factory
    (pro-bo-goal 'build    'supply-depot             1 14 #f                 17.7)  ;; 0:18
    (pro-bo-goal 'build    'barracks                 1 16 'supply-depot     39.8)  ;; 0:40
    (pro-bo-goal 'build    'refinery                 1 16 'supply-depot     42.7)  ;; 0:43
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks         87.9)  ;; 1:28
    (pro-bo-goal 'expand   'command-center           2 20 #f                 137.7) ;; 2:18
    (pro-bo-goal 'build    'supply-depot             2 21 'barracks         145.0) ;; 2:25
    (pro-bo-goal 'build    'barracks-techlab         1 21 'barracks         120.1) ;; 2:00
    (pro-bo-goal 'build    'factory                  1 21 'barracks         101.2) ;; 1:41
    (pro-bo-goal 'research 'stimpack                 1 21 'barracks-techlab 308.0) ;; 5:08
    (pro-bo-goal 'build    'refinery                 2 22 'barracks         52.9)  ;; 0:53
    ;; 26-40 Starport Medivacs & 3-Rax Bio ramp
    (pro-bo-goal 'morph    'orbital-command          2 26 'barracks         210.0) ;; 3:30
    (pro-bo-goal 'build    'starport                 1 28 'factory          158.6) ;; 2:39
    (pro-bo-goal 'build    'factory-techlab          1 30 'factory          195.0) ;; 3:15
    (pro-bo-goal 'build    'barracks                 2 32 'barracks         217.1) ;; 3:37
    (pro-bo-goal 'build    'barracks                 3 36 'barracks         285.5) ;; 4:46
    (pro-bo-goal 'build    'barracks-reactor         1 36 'barracks         170.0) ;; 2:50
    (pro-bo-goal 'build    'starport-reactor         1 38 'starport         313.3) ;; 5:13
    (pro-bo-goal 'research 'combat-shield            1 40 'barracks-techlab 356.5) ;; 5:57
    ;; 44-60 +1 Bio, 3rd CC, Concussive Shells & Armory
    (pro-bo-goal 'build    'engineering-bay          1 44 'barracks         284.3) ;; 4:44
    (pro-bo-goal 'build    'refinery                 3 46 'factory          264.7) ;; 4:25
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 48 'engineering-bay 327.5) ;; 5:28
    (pro-bo-goal 'expand   'command-center           3 52 'starport         383.7) ;; 6:24
    (pro-bo-goal 'research 'concussive-shells        1 56 'barracks-techlab 367.9) ;; 6:08
    (pro-bo-goal 'build    'armory                   1 60 'factory          390.0)) ;; 6:30
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  2.0))
     (3 . (24.0 .  5.0))
     (4 . (28.0 . 18.5))
     (5 . (36.5 . 26.0))
     (6 . (43.5 . 32.0))
     (7 . (47.0 . 44.0)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'reaper      1 20  86.9 'barracks)         ;; 1:27
    (pro-unit-timing 'cyclone     1 27 153.6 'factory-techlab)  ;; 2:34
    (pro-unit-timing 'medivac     1 34 195.0 'starport)         ;; 3:15
    (pro-unit-timing 'widow-mine  2 41 207.4 'factory)          ;; 3:27
    (pro-unit-timing 'siege-tank  1 46 233.6 'factory-techlab)  ;; 3:54
    (pro-unit-timing 'raven       1 52 248.7 'starport-techlab) ;; 4:09
    (pro-unit-timing 'marine      8 55 262.2 'barracks)         ;; 4:22
    (pro-unit-timing 'marine     16 75 323.6 'barracks)         ;; 5:24
    (pro-unit-timing 'siege-tank  4 84 354.8 'factory-techlab)) ;; 5:55
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'banshee-cloak             259.1 338.1  49 'starport-techlab) ;; 4:19 -> 5:38
    (pro-upgrade-timing 'stimpack                  308.0 408.0  65 'barracks-techlab) ;; 5:08 -> 6:48
    (pro-upgrade-timing 'terran-infantry-weapons-1 327.5 441.5  68 'engineering-bay)  ;; 5:28 -> 7:22
    (pro-upgrade-timing 'combat-shield             356.5 435.5  70 'barracks-techlab) ;; 5:57 -> 7:16
    (pro-upgrade-timing 'concussive-shells         367.9 410.9  88 'barracks-techlab) ;; 6:08 -> 6:51
    (pro-upgrade-timing 'terran-infantry-armor-1   419.0 533.0 118 'engineering-bay)))) ;; 6:59 -> 8:53
