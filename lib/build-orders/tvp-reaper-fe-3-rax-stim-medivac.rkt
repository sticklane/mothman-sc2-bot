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
    ;; 26-40 Starport Medivacs & 3-Rax Bio ramp
    (pro-bo-goal 'morph    'orbital-command          2 26 'barracks)
    (pro-bo-goal 'build    'starport                 1 28 'factory)
    (pro-bo-goal 'build    'factory-techlab          1 30 'factory)
    (pro-bo-goal 'build    'barracks                 2 32 'barracks)
    (pro-bo-goal 'build    'barracks                 3 36 'barracks)
    (pro-bo-goal 'build    'barracks-reactor         1 36 'barracks)
    (pro-bo-goal 'build    'starport-reactor         1 38 'starport)
    (pro-bo-goal 'research 'combat-shield            1 40 'barracks-techlab)
    ;; 44-60 +1 Bio, 3rd CC, Concussive Shells & Armory
    (pro-bo-goal 'build    'engineering-bay          1 44 'barracks)
    (pro-bo-goal 'build    'refinery                 3 46 'factory)
    (pro-bo-goal 'research 'terran-infantry-weapons-1 1 48 'engineering-bay)
    (pro-bo-goal 'expand   'command-center           3 52 'starport)
    (pro-bo-goal 'research 'concussive-shells        1 56 'barracks-techlab)
    (pro-bo-goal 'build    'armory                   1 60 'factory))
   ;; Empirical pro supply checkpoints: (minute . (workers . army-supply))
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  2.0))
     (3 . (24.0 .  5.0))
     (4 . (28.0 . 18.5))
     (5 . (36.5 . 26.0))
     (6 . (43.5 . 32.0))
     (7 . (47.0 . 44.0)))))
