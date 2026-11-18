#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/tvp-reaper-fe-3-rax-stim-medivac.rkt`
;; TvP — Reaper FE into 1-1-1 & 3-Rax Stim Medivac Timing
;; Exemplar: VITmaru vs ShoWTimE (Pylon LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide TvP-BUILD-ORDER
         TvP-UNIT-BENCHMARKS)

(: TvP-BUILD-ORDER build-order-spec)
(define TvP-BUILD-ORDER
  (build-order-spec
   'TvP
   'Terran
   "Reaper FE into 3-Rax Stim Medivac Timing"
   'bio-medivac
   "Fast natural Command Center into Reactor Starport Medivacs, Stim/Combat/Concussive Bio push, and 3rd base behind."
   (list
    ;; 14-24 Reaper FE -> Factory + CC2 BEFORE Refinery #2
    (pro-bo-goal 'build    'supply-depot             1 14 #f                 17.7)  ;; 0:18
    (pro-bo-goal 'build    'barracks                 1 16 'supply-depot     39.8)  ;; 0:40
    (pro-bo-goal 'build    'refinery                 1 16 'supply-depot     42.7)  ;; 0:43
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks         87.9)  ;; 1:28
    (pro-bo-goal 'expand   'command-center           2 20 #f                 104.0) ;; 1:44
    (pro-bo-goal 'build    'factory                  1 21 'barracks         114.0) ;; 1:54
    (pro-bo-goal 'build    'supply-depot             2 21 'barracks         122.0) ;; 2:02
    (pro-bo-goal 'build    'barracks-reactor         1 22 'barracks         126.0) ;; 2:06
    (pro-bo-goal 'build    'refinery                 2 23 'barracks         132.0) ;; 2:12 (Pro Gas #2 @ 20w AFTER CC2!)
    ;; 26-44 Starport Medivacs & 3-Rax Bio ramp
    (pro-bo-goal 'morph    'orbital-command          2 26 'barracks         178.0) ;; 2:58
    (pro-bo-goal 'build    'starport                 1 28 'factory          158.6) ;; 2:39
    (pro-bo-goal 'build    'factory-techlab          1 30 'factory          195.0) ;; 3:15
    (pro-bo-goal 'build    'barracks                 2 32 'barracks         217.1) ;; 3:37
    (pro-bo-goal 'build    'barracks-techlab         1 34 'barracks         242.0) ;; 4:02
    (pro-bo-goal 'build    'barracks                 3 38 'barracks         275.0) ;; 4:35
    (pro-bo-goal 'build    'engineering-bay          1 42 'barracks         284.3) ;; 4:44
    (pro-bo-goal 'build    'refinery                 3 44 'factory          290.0) ;; 4:50 (Pro Gas #3 @ 34w)
    (pro-bo-goal 'research 'stimpack                 1 46 'barracks-techlab 308.0) ;; 5:08
    (pro-bo-goal 'build    'starport-reactor         1 48 'starport         313.3) ;; 5:13
    ;; 50-100 +1 Bio, 3rd CC, Ghost Academy, 4th CC & 5-Rax Macro
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 50 'engineering-bay 327.5) ;; 5:28
    (pro-bo-goal 'expand   'command-center           3 54 'starport         335.0) ;; 5:35 (3rd Base!)
    (pro-bo-goal 'build    'refinery                 4 58 'factory          352.0) ;; 5:52 (Pro Gas #4 @ 40w)
    (pro-bo-goal 'research 'combat-shield            1 62 'barracks-techlab 356.5) ;; 5:57
    (pro-bo-goal 'research 'concussive-shells        1 66 'barracks-techlab 367.9) ;; 6:08
    (pro-bo-goal 'build    'armory                   1 72 'factory          390.0) ;; 6:30
    (pro-bo-goal 'build    'ghost-academy            1 80 'barracks         415.0) ;; 6:55
    (pro-bo-goal 'build    'barracks                 4 84 'starport         430.0) ;; 7:10
    (pro-bo-goal 'build    'barracks                 5 88 'starport         440.0) ;; 7:20
    (pro-bo-goal 'expand   'command-center           4 94 'starport         455.0)) ;; 7:35 (4th Base Macro!)
   ;; Empirical pro 4+ base macro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  2.0))
     (3 . (26.0 .  5.0))
     (4 . (34.0 . 18.5))
     (5 . (44.0 . 26.0))
     (6 . (54.0 . 32.0))
     (7 . (62.0 . 44.0))
     (8 . (66.0 . 60.0))
     (9 . (66.0 . 80.0))
     (10 . (66.0 . 100.0)))
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

;; Full 1..8+ min pro unit composition benchmarks (TvP) covering core, harass, drops & casters.
(: TvP-UNIT-BENCHMARKS (Listof pro-unit-timing))
(define TvP-UNIT-BENCHMARKS
  (list
   (pro-unit-timing 'reaper         1 20  86.9 'barracks)
   (pro-unit-timing 'cyclone        1 27 153.6 'factory-techlab)
   (pro-unit-timing 'medivac        1 34 195.0 'starport)
   (pro-unit-timing 'widow-mine     2 41 207.4 'factory)
   (pro-unit-timing 'siege-tank     1 46 233.6 'factory-techlab)
   (pro-unit-timing 'raven          1 52 248.7 'starport-techlab)
   (pro-unit-timing 'marine         8 55 262.2 'barracks)
   (pro-unit-timing 'hellion        2 58 275.0 'factory)
   (pro-unit-timing 'marauder       4 68 305.0 'barracks-techlab)
   (pro-unit-timing 'marine        16 75 323.6 'barracks)
   (pro-unit-timing 'medivac        3 80 345.0 'starport)
   (pro-unit-timing 'siege-tank     4 84 354.8 'factory-techlab)
   (pro-unit-timing 'viking-fighter 4 94 385.0 'starport)
   (pro-unit-timing 'ghost          2 104 420.0 'ghost-academy)
   (pro-unit-timing 'marine        28 118 455.0 'barracks)
   (pro-unit-timing 'marauder      10 124 465.0 'barracks-techlab)
   (pro-unit-timing 'medivac        6 130 475.0 'starport)
   (pro-unit-timing 'viking-fighter 8 136 485.0 'starport)
   (pro-unit-timing 'siege-tank     6 140 490.0 'factory-techlab)
   (pro-unit-timing 'widow-mine     5 142 492.0 'factory)
   (pro-unit-timing 'cyclone        2 144 494.0 'factory-techlab)
   (pro-unit-timing 'hellion        4 146 496.0 'factory)
   (pro-unit-timing 'raven          2 148 498.0 'starport-techlab)
   (pro-unit-timing 'thor           2 152 505.0 'armory)
   (pro-unit-timing 'ghost          5 156 510.0 'ghost-academy)))
