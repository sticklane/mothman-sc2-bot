#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/tvz-reaper-fe-1-1-1-hellion-banshee.rkt`
;; TvZ — Reaper Fast Expand into 1-1-1 & 3-Rax Bio/Tank
;; Exemplar: GuMiho vs Serral (Abyssal Reef LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide TvZ-BUILD-ORDER
         TvZ-UNIT-BENCHMARKS)

(: TvZ-BUILD-ORDER build-order-spec)
(define TvZ-BUILD-ORDER
  (build-order-spec
   'TvZ
   'Terran
   "Reaper FE into 1-1-1 Stim Bio-Tank"
   'bio-tank
   "16 Rax / Gas Reaper expand into 1-1-1 Starport pressure, Stim + Combat Shield +1 Bio, and 3rd Command Center."
   (list
    ;; 14-24 Reaper Fast Expand -> Factory + Reactor Hellions (100% Pro TvZ Standard!)
    (pro-bo-goal 'build    'supply-depot             1 14 #f                 17.1)  ;; 0:17
    (pro-bo-goal 'build    'barracks                 1 16 'supply-depot     40.6)  ;; 0:41
    (pro-bo-goal 'build    'refinery                 1 16 'supply-depot     43.9)  ;; 0:44
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks         91.1)  ;; 1:31
    (pro-bo-goal 'expand   'command-center           2 20 #f                 103.2) ;; 1:43
    (pro-bo-goal 'build    'factory                  1 21 'barracks         114.4) ;; 1:54
    (pro-bo-goal 'build    'barracks-reactor         1 21 'barracks         118.0) ;; 1:58 (Reactor BEFORE TechLab for Hellion swap!)
    (pro-bo-goal 'build    'supply-depot             2 22 'barracks         128.0) ;; 2:08
    (pro-bo-goal 'build    'refinery                 2 23 'barracks         135.0) ;; 2:15 (Pro Gas #2 @ 20w AFTER CC2!)
    ;; 26-42 1-1-1 Starport + Hellion Map Control + 3rd CC + 3-Rax Stim Converge
    (pro-bo-goal 'morph    'orbital-command          2 26 'barracks         175.9) ;; 2:56
    (pro-bo-goal 'build    'starport                 1 28 'factory          161.8) ;; 2:42
    (pro-bo-goal 'train    'hellion                  4 30 'factory          198.0) ;; 3:18
    (pro-bo-goal 'build    'barracks                 2 34 'barracks         215.0) ;; 3:35
    (pro-bo-goal 'build    'barracks-techlab         1 36 'barracks         229.2) ;; 3:49
    (pro-bo-goal 'expand   'command-center           3 40 'starport         257.1) ;; 4:17 (3rd Base!)
    (pro-bo-goal 'research 'stimpack                 1 42 'barracks-techlab 273.2) ;; 4:33
    (pro-bo-goal 'build    'barracks                 3 44 'barracks         285.0) ;; 4:45
    (pro-bo-goal 'build    'engineering-bay          1 46 'barracks         289.4) ;; 4:49
    (pro-bo-goal 'build    'refinery                 3 48 'factory          298.0) ;; 4:58 (Pro Gas #3 @ 38w)
    (pro-bo-goal 'build    'starport-reactor         1 50 'starport         312.0) ;; 5:12
    ;; 52-104 Double Upgrades, Tank/Mine Tech, 4th CC & 5-Rax Macro
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 52 'engineering-bay 317.0) ;; 5:17
    (pro-bo-goal 'build    'factory-techlab          1 54 'factory          322.0) ;; 5:22
    (pro-bo-goal 'build    'armory                   1 58 'factory          340.0) ;; 5:40
    (pro-bo-goal 'build    'refinery                 4 60 'factory          352.0) ;; 5:52 (Pro Gas #4 @ 41w)
    (pro-bo-goal 'research 'combat-shield            1 64 'barracks-techlab 366.5) ;; 6:07
    (pro-bo-goal 'research 'concussive-shells        1 68 'barracks-techlab 385.0) ;; 6:25
    (pro-bo-goal 'build    'barracks                 4 78 'starport         410.0) ;; 6:50
    (pro-bo-goal 'build    'barracks                 5 82 'starport         420.0) ;; 7:00
    (pro-bo-goal 'expand   'command-center           4 90 'starport         445.0)) ;; 7:25 (4th Base Macro!)
   ;; Empirical pro 4+ base macro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  2.0))
     (3 . (27.0 .  6.0))
     (4 . (36.0 . 14.0))
     (5 . (46.0 . 21.0))
     (6 . (56.0 . 31.5))
     (7 . (64.0 . 44.0))
     (8 . (66.0 . 62.0))
     (9 . (66.0 . 82.0))
     (10 . (66.0 . 102.0)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'reaper      1 20  91.7 'barracks)         ;; 1:32
    (pro-unit-timing 'marine      2 25 162.2 'barracks)         ;; 2:42
    (pro-unit-timing 'widow-mine  1 31 170.8 'factory)          ;; 2:51
    (pro-unit-timing 'medivac     1 35 198.6 'starport)         ;; 3:19
    (pro-unit-timing 'marine      6 36 201.2 'barracks)         ;; 3:21
    (pro-unit-timing 'hellion     4 53 246.1 'factory)          ;; 4:06
    (pro-unit-timing 'raven       1 57 250.4 'starport-techlab) ;; 4:10
    (pro-unit-timing 'marine     14 76 361.2 'barracks))        ;; 6:01
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'banshee-cloak             247.8 326.9 48 'starport-techlab) ;; 4:08 -> 5:27
    (pro-upgrade-timing 'stimpack                  273.2 373.2 54 'barracks-techlab) ;; 4:33 -> 6:13
    (pro-upgrade-timing 'terran-infantry-weapons-1 317.0 431.0 58 'engineering-bay)  ;; 5:17 -> 7:11
    (pro-upgrade-timing 'terran-infantry-armor-1   319.9 433.9 63 'engineering-bay)  ;; 5:20 -> 7:14
    (pro-upgrade-timing 'combat-shield             366.5 445.5 84 'barracks-techlab) ;; 6:07 -> 7:26
    (pro-upgrade-timing 'terran-infantry-weapons-2 388.7 524.7 94 'engineering-bay)))) ;; 6:29 -> 8:45

;; Full 1..8+ min pro unit composition benchmarks (TvZ) covering core, harass, drops & casters.
(: TvZ-UNIT-BENCHMARKS (Listof pro-unit-timing))
(define TvZ-UNIT-BENCHMARKS
  (list
   (pro-unit-timing 'reaper         1 20  91.7 'barracks)
   (pro-unit-timing 'marine         2 25 162.2 'barracks)
   (pro-unit-timing 'widow-mine     1 31 170.8 'factory)
   (pro-unit-timing 'medivac        1 35 198.6 'starport)
   (pro-unit-timing 'marine         6 36 201.2 'barracks)
   (pro-unit-timing 'hellion        4 53 246.1 'factory)
   (pro-unit-timing 'raven          1 57 250.4 'starport-techlab)
   (pro-unit-timing 'cyclone        1 60 270.0 'factory-techlab)
   (pro-unit-timing 'widow-mine     3 66 300.0 'factory)
   (pro-unit-timing 'siege-tank     2 70 325.0 'factory-techlab)
   (pro-unit-timing 'medivac        2 74 335.0 'starport)
   (pro-unit-timing 'marine        14 76 361.2 'barracks)
   (pro-unit-timing 'marauder       4 84 375.0 'barracks-techlab)
   (pro-unit-timing 'viking-fighter 2 90 390.0 'starport)
   (pro-unit-timing 'hellion        6 96 410.0 'factory)
   (pro-unit-timing 'medivac        4 108 440.0 'starport)
   (pro-unit-timing 'marine        26 118 460.0 'barracks)
   (pro-unit-timing 'siege-tank     5 124 470.0 'factory-techlab)
   (pro-unit-timing 'marauder       8 130 480.0 'barracks-techlab)
   (pro-unit-timing 'widow-mine     5 134 485.0 'factory)
   (pro-unit-timing 'viking-fighter 4 138 490.0 'starport)
   (pro-unit-timing 'thor           2 144 495.0 'armory)
   (pro-unit-timing 'raven          2 146 500.0 'starport-techlab)
   (pro-unit-timing 'ghost          3 152 510.0 'ghost-academy)))
