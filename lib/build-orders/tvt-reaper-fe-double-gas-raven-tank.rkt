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
    (pro-bo-goal 'build    'supply-depot             1 14 #f)
    (pro-bo-goal 'build    'barracks                 1 15 'supply-depot)
    (pro-bo-goal 'build    'refinery                 1 15 'supply-depot)
    (pro-bo-goal 'build    'refinery                 2 17 'barracks)
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks)
    (pro-bo-goal 'build    'factory                  1 20 'barracks)
    (pro-bo-goal 'expand   'command-center           2 21 'barracks)
    (pro-bo-goal 'build    'supply-depot             2 22 'barracks)
    (pro-bo-goal 'build    'factory-techlab          1 23 'factory)
    (pro-bo-goal 'build    'starport                 1 24 'factory)
    ;; 26-34 Tank, Viking, Raven core
    (pro-bo-goal 'train    'siege-tank               1 26 'factory-techlab)
    (pro-bo-goal 'train    'viking-fighter           1 28 'starport)
    (pro-bo-goal 'morph    'orbital-command          2 29 'barracks)
    (pro-bo-goal 'build    'starport-techlab         1 30 'starport)
    (pro-bo-goal 'train    'raven                    1 32 'starport-techlab)
    ;; 34-58 3-Rax Bio transition + upgrades + 3rd CC
    (pro-bo-goal 'build    'barracks                 2 34 'barracks)
    (pro-bo-goal 'build    'barracks-techlab         1 36 'barracks)
    (pro-bo-goal 'research 'stimpack                 1 38 'barracks-techlab)
    (pro-bo-goal 'build    'barracks                 3 40 'barracks)
    (pro-bo-goal 'build    'barracks-reactor         1 42 'barracks)
    (pro-bo-goal 'research 'combat-shield            1 44 'barracks-techlab)
    (pro-bo-goal 'build    'engineering-bay          1 46 'barracks)
    (pro-bo-goal 'build    'refinery                 3 48 'factory)
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 50 'engineering-bay)
    (pro-bo-goal 'expand   'command-center           3 54 'starport)
    (pro-bo-goal 'build    'armory                   1 58 'factory))
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  1.0))
     (3 . (23.0 .  7.0))
     (4 . (28.5 . 15.5))
     (5 . (35.5 . 24.0))
     (6 . (43.0 . 37.0))
     (7 . (49.5 . 52.5)))))
