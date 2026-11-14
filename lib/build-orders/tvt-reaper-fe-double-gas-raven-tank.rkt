#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders/tvt-reaper-fe-double-gas-raven-tank.rkt`
;; TvT — Double-Gas 1-1-1 Raven/Tank into 3-Rax Bio
;; Exemplar: <NWMI> OneScotch vs Eternal (Ulrena)
;; =============================================================================

(require "../sc2-types.rkt")

(provide TvT-BUILD-ORDER)

(: TvT-BUILD-ORDER build-order-spec)
(define TvT-BUILD-ORDER
  (build-order-spec
   'TvT
   'Terran
   "Double-Gas 1-1-1 Raven/Tank into 3-Rax Bio"
   'mech-bio-raven
   "Safe double-refinery Factory into natural Command Center, early Tank/Viking/Raven air superiority, then Stim Bio."
   (list
    ;; 14-24 Double-gas Rax -> Factory -> Natural CC -> Tank & Starport
    (pro-bo-goal 'build    'supply-depot             1 14 #f                 17.8)  ;; 0:18
    (pro-bo-goal 'build    'barracks                 1 15 'supply-depot     42.7)  ;; 0:43
    (pro-bo-goal 'build    'refinery                 1 15 'supply-depot     45.9)  ;; 0:46
    (pro-bo-goal 'build    'refinery                 2 17 'barracks         65.0)  ;; 1:05
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks         93.3)  ;; 1:33
    (pro-bo-goal 'build    'factory                  1 20 'barracks         131.4) ;; 2:11
    (pro-bo-goal 'expand   'command-center           2 21 'barracks         108.6) ;; 1:49
    (pro-bo-goal 'build    'supply-depot             2 22 'barracks         127.9) ;; 2:08
    (pro-bo-goal 'build    'factory-techlab          1 23 'factory          224.9) ;; 3:45
    (pro-bo-goal 'build    'starport                 1 24 'factory          177.3) ;; 2:57
    ;; 26-34 Tank, Viking, Raven core
    (pro-bo-goal 'train    'siege-tank               1 26 'factory-techlab  245.0) ;; 4:05
    (pro-bo-goal 'train    'viking-fighter           1 28 'starport         235.0) ;; 3:55
    (pro-bo-goal 'morph    'orbital-command          2 29 'barracks         180.2) ;; 3:00
    (pro-bo-goal 'build    'starport-techlab         1 30 'starport         250.0) ;; 4:10
    (pro-bo-goal 'train    'raven                    1 32 'starport-techlab 270.0) ;; 4:30
    ;; 34-58 3-Rax Bio transition + upgrades + 3rd CC
    (pro-bo-goal 'build    'barracks                 2 34 'barracks         159.8) ;; 2:40
    (pro-bo-goal 'build    'barracks-techlab         1 36 'barracks         214.6) ;; 3:35
    (pro-bo-goal 'research 'stimpack                 1 38 'barracks-techlab 293.7) ;; 4:54
    (pro-bo-goal 'build    'barracks                 3 40 'barracks         275.0) ;; 4:35
    (pro-bo-goal 'build    'barracks-reactor         1 42 'barracks         141.2) ;; 2:21
    (pro-bo-goal 'research 'combat-shield            1 44 'barracks-techlab 350.1) ;; 5:50
    (pro-bo-goal 'build    'engineering-bay          1 46 'barracks         286.0) ;; 4:46
    (pro-bo-goal 'build    'refinery                 3 48 'factory          320.0) ;; 5:20
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 50 'engineering-bay 331.6) ;; 5:32
    (pro-bo-goal 'expand   'command-center           3 54 'starport         377.1) ;; 6:17
    (pro-bo-goal 'build    'armory                   1 58 'factory          405.5)) ;; 6:46
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  1.0))
     (3 . (23.0 .  7.0))
     (4 . (28.5 . 15.5))
     (5 . (35.5 . 24.0))
     (6 . (43.0 . 37.0))
     (7 . (49.5 . 52.5)))
   ;; Empirical pro unit production timings (Faster LotV sec)
   (list
    (pro-unit-timing 'reaper          1 20  99.5 'barracks)         ;; 1:40
    (pro-unit-timing 'widow-mine      2 39 223.9 'factory)          ;; 3:44
    (pro-unit-timing 'medivac         1 41 226.0 'starport)         ;; 3:46
    (pro-unit-timing 'marine          6 40 229.1 'barracks)         ;; 3:49
    (pro-unit-timing 'viking-fighter  2 44 248.0 'starport)         ;; 4:08
    (pro-unit-timing 'raven           1 46 265.0 'starport-techlab) ;; 4:25
    (pro-unit-timing 'marine         14 55 281.3 'barracks)         ;; 4:41
    (pro-unit-timing 'siege-tank      1 61 306.7 'factory-techlab)  ;; 5:07
    (pro-unit-timing 'siege-tank      2 76 358.3 'factory-techlab)) ;; 5:58
   ;; Empirical pro upgrade start -> complete timings (Faster LotV sec)
   (list
    (pro-upgrade-timing 'stimpack                  293.7 393.7 57 'barracks-techlab) ;; 4:54 -> 6:34
    (pro-upgrade-timing 'terran-infantry-weapons-1 331.6 445.6 67 'engineering-bay)  ;; 5:32 -> 7:26
    (pro-upgrade-timing 'combat-shield             350.1 429.1 73 'barracks-techlab) ;; 5:50 -> 7:09
    (pro-upgrade-timing 'terran-infantry-armor-1   370.9 485.0 90 'engineering-bay)))) ;; 6:11 -> 8:05
