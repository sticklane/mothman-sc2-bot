#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/tvz-reaper-fe-1-1-1-hellion-banshee.rkt`
;; TvZ — Reaper Fast Expand into 1-1-1 & 3-Rax Bio/Tank
;; Exemplar: GuMiho vs Serral (Abyssal Reef LE)
;; =============================================================================

(require "../sc2-types.rkt")

(provide TvZ-BUILD-ORDER)

(: TvZ-BUILD-ORDER build-order-spec)
(define TvZ-BUILD-ORDER
  (build-order-spec
   'TvZ
   'Terran
   "Reaper FE into 1-1-1 Stim Bio-Tank"
   'bio-tank
   "16 Rax / Gas Reaper expand into 1-1-1 Starport pressure, Stim + Combat Shield +1 Bio, and 3rd Command Center."
   (list
    ;; 14-21 Reaper Fast Expand -> Reactor/TechLab & Factory
    (pro-bo-goal 'build    'supply-depot             1 14 #f                 17.1)  ;; 0:17
    (pro-bo-goal 'build    'barracks                 1 16 'supply-depot     44.6)  ;; 0:45
    (pro-bo-goal 'build    'refinery                 1 16 'supply-depot     28.9)  ;; 0:29
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks         91.1)  ;; 1:31
    (pro-bo-goal 'expand   'command-center           2 20 #f                 103.2) ;; 1:43
    (pro-bo-goal 'build    'supply-depot             2 21 'barracks         135.3) ;; 2:15
    (pro-bo-goal 'build    'barracks-techlab         1 21 'barracks         229.2) ;; 3:49
    (pro-bo-goal 'build    'factory                  1 21 'barracks         114.4) ;; 1:54
    (pro-bo-goal 'research 'stimpack                 1 21 'barracks-techlab 273.2) ;; 4:33
    (pro-bo-goal 'build    'refinery                 2 22 'barracks         123.8) ;; 2:04
    ;; 26-40 1-1-1 Starport + 3-Rax Production Converge
    (pro-bo-goal 'morph    'orbital-command          2 26 'barracks         175.9) ;; 2:56
    (pro-bo-goal 'build    'starport                 1 28 'factory          161.8) ;; 2:42
    (pro-bo-goal 'build    'factory-techlab          1 30 'factory          192.4) ;; 3:12
    (pro-bo-goal 'build    'barracks                 2 32 'barracks         291.7) ;; 4:52
    (pro-bo-goal 'build    'barracks                 3 36 'barracks         295.1) ;; 4:55
    (pro-bo-goal 'build    'barracks-reactor         1 36 'barracks         125.5) ;; 2:06
    (pro-bo-goal 'build    'starport-reactor         1 38 'starport         318.9) ;; 5:19
    (pro-bo-goal 'research 'combat-shield            1 40 'barracks-techlab 366.5) ;; 6:07
    ;; 44-60 Upgrades, 3rd CC & Armory
    (pro-bo-goal 'build    'engineering-bay          1 44 'barracks         289.4) ;; 4:49
    (pro-bo-goal 'build    'refinery                 3 46 'factory          300.0) ;; 5:00
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 48 'engineering-bay 317.0) ;; 5:17
    (pro-bo-goal 'expand   'command-center           3 52 'starport         257.1) ;; 4:17
    (pro-bo-goal 'research 'concussive-shells        1 56 'barracks-techlab 375.0) ;; 6:15
    (pro-bo-goal 'build    'armory                   1 60 'factory          326.4)) ;; 5:26
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  2.0))
     (3 . (23.0 .  4.0))
     (4 . (31.0 . 14.0))
     (5 . (40.0 . 21.0))
     (6 . (49.0 . 31.5))
     (7 . (58.0 . 41.0)))
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
