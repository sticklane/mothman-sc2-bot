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
    (pro-bo-goal 'build    'supply-depot             1 14 #f)
    (pro-bo-goal 'build    'barracks                 1 16 'supply-depot)
    (pro-bo-goal 'build    'refinery                 1 16 'supply-depot)
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks)
    (pro-bo-goal 'expand   'command-center           2 20 #f)
    (pro-bo-goal 'build    'supply-depot             2 21 'barracks)
    (pro-bo-goal 'build    'barracks-techlab         1 21 'barracks)
    (pro-bo-goal 'build    'factory                  1 21 'barracks)
    (pro-bo-goal 'research 'stimpack                 1 21 'barracks-techlab)
    (pro-bo-goal 'build    'refinery                 2 22 'barracks)
    ;; 26-40 1-1-1 Starport + 3-Rax Production Converge
    (pro-bo-goal 'morph    'orbital-command          2 26 'barracks)
    (pro-bo-goal 'build    'starport                 1 28 'factory)
    (pro-bo-goal 'build    'factory-techlab          1 30 'factory)
    (pro-bo-goal 'build    'barracks                 2 32 'barracks)
    (pro-bo-goal 'build    'barracks                 3 36 'barracks)
    (pro-bo-goal 'build    'barracks-reactor         1 36 'barracks)
    (pro-bo-goal 'build    'starport-reactor         1 38 'starport)
    (pro-bo-goal 'research 'combat-shield            1 40 'barracks-techlab)
    ;; 44-60 Upgrades, 3rd CC & Armory
    (pro-bo-goal 'build    'engineering-bay          1 44 'barracks)
    (pro-bo-goal 'build    'refinery                 3 46 'factory)
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 48 'engineering-bay)
    (pro-bo-goal 'expand   'command-center           3 52 'starport)
    (pro-bo-goal 'research 'concussive-shells        1 56 'barracks-techlab)
    (pro-bo-goal 'build    'armory                   1 60 'factory))
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  2.0))
     (3 . (23.0 .  4.0))
     (4 . (31.0 . 14.0))
     (5 . (40.0 . 21.0))
     (6 . (49.0 . 31.5))
     (7 . (58.0 . 41.0)))))
