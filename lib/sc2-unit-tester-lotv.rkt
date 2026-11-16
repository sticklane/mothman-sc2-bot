#lang racket/base

;; =============================================================================
;; `lib/sc2-unit-tester-lotv.rkt`
;; Offline Pure-Racket LotV Micro & Tactical Unit-Tester Engine
;;
;; Deterministic 22.4 Hz (`1` Faster frame/tick) StarCraft II: Legacy of the Void
;; combat, splash, spell, terrain/choke, and doorway-wall simulator comparing:
;;   - `'default-ai`: naive SC2 A-move nearest-target micro without spell or
;;     splash awareness.
;;   - `'mothman-tactics`: Mothman's real production tactical planners
;;     (`plan-baneling-move-past-and-light-clump-detonate`,
;;      `disruptor-nova-catchable-range`, `plan-anti-nova-scatter`,
;;      `evaluate-disruptor-snipe-and-cooldowns`, `should-commit-through-splash?`,
;;      `plan-avoid-siege-tank-and-lurker-splash-zones`,
;;      `step-pro-spellcaster-micro!`, `plan-own-wall-integrity-defense`,
;;      `select-worker-drill-stack-mineral-patch`,
;;      `translate-bot-actions->sc2-raw-commands`,
;;      `evaluate-build-order-tactical-plan`, `plan-multi-base-adept-harass`).
;; =============================================================================

(require racket/flonum
         racket/list
         racket/match
         racket/math
         racket/string
         "sc2-game-constants.rkt"
         "sc2-placement.rkt"
         "sc2-protobuf-ws.rkt"
         "econ-ledger.rkt"
         "tactics/zerg-burrow-micro.rkt"
         "tactics/disruptor-micro.rkt"
         "plan/wall-and-block.rkt"
         "plan/multitask-harass-and-proxy.rkt"
         "tactics/pro-spellcaster-micro.rkt")

(provide
 (struct-out lotv-scenario-spec)
 LOTV-UNIT-TESTER-SCENARIO-IDS
 LOTV-UNIT-TESTER-CANONICAL-SCENARIOS
 LOTV-UNIT-TESTER-SCENARIOS
 find-lotv-unit-tester-scenario
 run-lotv-unit-tester-scenario
 run-all-lotv-unit-tester-scenarios)

;; -----------------------------------------------------------------------------
;; 1. LotV Combat Constants & Unit Stat Spec
;; -----------------------------------------------------------------------------

(define DT (/ 1.0 SC2-FASTER-FPS)) ; ~0.044642857s per Faster frame
(define SHIELD-REGEN-DELAY-SEC 7.14)
(define SHIELD-REGEN-PER-FRAME (/ 2.0 SC2-FASTER-FPS))
(define ZERG-HP-REGEN-PER-FRAME (/ 0.37 SC2-FASTER-FPS))

(define *LOTV-UNIT-SPECS*
  ;; (hasheq sym (hasheq 'dmg ... 'hits 1 'bonus-light 0 'bonus-armored 0 ...))
  (hasheq
   'marine            (hasheq 'dmg 6.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f)
   'marauder          (hasheq 'dmg 10.0 'hits 1 'bonus-light 0.0  'bonus-armored 10.0 'light? #f 'armored? #t 'biological? #t 'splash-mode #f 'concussive? #t)
   'ghost             (hasheq 'dmg 10.0 'hits 1 'bonus-light 10.0 'bonus-armored 0.0  'light? #f 'armored? #f 'biological? #t 'splash-mode #f 'speed-ovr 3.94 'range-ovr 6.0 'period-ovr 1.07 'energy 100.0 'max-energy 200.0)
   'siege-tank        (hasheq 'dmg 15.0 'hits 1 'bonus-light 0.0  'bonus-armored 10.0 'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'speed-ovr 3.15 'range-ovr 7.0 'period-ovr 0.74 'max-hp-ovr 175.0 'armor-ovr 1.0)
   'siege-tank-sieged (hasheq 'dmg 40.0 'hits 1 'bonus-light 0.0  'bonus-armored 30.0 'light? #f 'armored? #t 'biological? #f 'splash-mode 'tank 'min-range 2.0 'sieged? #t)
   'thor              (hasheq 'dmg 30.0 'hits 2 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'speed-ovr 2.62 'range-ovr 7.0 'period-ovr 0.91 'max-hp-ovr 400.0 'armor-ovr 1.0)
   'raven             (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #f 'biological? #f 'splash-mode #f 'speed-ovr 4.13 'range-ovr 0.0 'period-ovr 1.0  'max-hp-ovr 140.0 'armor-ovr 1.0 'energy 150.0 'max-energy 200.0)
   'medivac           (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'speed-ovr 3.50 'range-ovr 4.0 'period-ovr 1.0  'max-hp-ovr 150.0 'armor-ovr 1.0 'energy 100.0 'max-energy 200.0)
   'zergling          (hasheq 'dmg 5.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f 'speed-ovr 6.57 'range-ovr 0.1)
   'baneling          (hasheq 'dmg 16.0 'hits 1 'bonus-light 19.0 'bonus-armored 0.0  'light? #f 'armored? #f 'biological? #t 'splash-mode 'bane 'speed-ovr 4.13 'range-ovr 0.35)
   'queen             (hasheq 'dmg 4.0  'hits 2 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #f 'biological? #t 'splash-mode #f 'speed-ovr 1.31 'range-ovr 5.0 'period-ovr 0.71 'max-hp-ovr 175.0 'armor-ovr 1.0 'energy 100.0 'max-energy 200.0)
   'roach             (hasheq 'dmg 16.0 'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #t 'splash-mode #f 'speed-ovr 4.20)
   'ravager           (hasheq 'dmg 16.0 'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #f 'biological? #t 'splash-mode #f 'speed-ovr 3.85)
   'hydralisk         (hasheq 'dmg 12.0 'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f 'speed-ovr 3.94 'range-ovr 6.0)
   'lurker-burrowed   (hasheq 'dmg 20.0 'hits 1 'bonus-light 0.0  'bonus-armored 10.0 'light? #f 'armored? #t 'biological? #t 'splash-mode 'lurker-line 'range-ovr 9.0 'burrowed? #t)
   'infestor          (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #t 'splash-mode #f 'speed-ovr 3.15 'range-ovr 0.0 'period-ovr 1.0  'max-hp-ovr 90.0 'energy 175.0 'max-energy 200.0)
   'ultralisk         (hasheq 'dmg 35.0 'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #t 'splash-mode 'ultra 'speed-ovr 4.13 'range-ovr 1.0 'period-ovr 0.61 'max-hp-ovr 500.0 'armor-ovr 2.0)
   'viper             (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #t 'splash-mode #f 'speed-ovr 4.13 'range-ovr 0.0 'period-ovr 1.0  'max-hp-ovr 150.0 'armor-ovr 1.0 'energy 175.0 'max-energy 200.0)
   'zealot            (hasheq 'dmg 8.0  'hits 2 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f 'speed-ovr 4.72)
   'sentry            (hasheq 'dmg 6.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #f 'splash-mode #f 'speed-ovr 3.15 'range-ovr 5.0 'period-ovr 0.71 'max-hp-ovr 40.0 'max-shield-ovr 40.0 'armor-ovr 1.0 'energy 100.0 'max-energy 200.0)
   'stalker           (hasheq 'dmg 13.0 'hits 1 'bonus-light 0.0  'bonus-armored 5.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'speed-ovr 4.13)
   'adept             (hasheq 'dmg 10.0 'hits 1 'bonus-light 12.0 'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f 'period-ovr 1.11 'speed-ovr 3.50)
   'high-templar      (hasheq 'dmg 4.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f 'speed-ovr 2.62 'range-ovr 6.0 'period-ovr 1.25 'max-hp-ovr 40.0 'max-shield-ovr 40.0 'energy 125.0 'max-energy 200.0)
   'archon            (hasheq 'dmg 25.0 'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'bonus-bio 10.0 'light? #f 'armored? #f 'biological? #f 'splash-mode 'archon 'speed-ovr 3.94 'range-ovr 3.0 'period-ovr 1.25 'max-hp-ovr 10.0 'max-shield-ovr 350.0 'armor-ovr 0.0)
   'immortal          (hasheq 'dmg 20.0 'hits 1 'bonus-light 0.0  'bonus-armored 30.0 'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'speed-ovr 3.15 'range-ovr 6.0 'period-ovr 1.04 'max-hp-ovr 200.0 'max-shield-ovr 100.0 'armor-ovr 1.0 'barrier? #t)
   'colossus          (hasheq 'dmg 10.0 'hits 2 'bonus-light 5.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode 'colossus 'range-ovr 9.0 'speed-ovr 3.15)
   'disruptor         (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'speed-ovr 3.15)
   'bunker            (hasheq 'dmg 6.0  'hits 4 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'building? #t 'period-ovr 0.41 'range-ovr 6.5 'max-hp-ovr 400.0 'radius-ovr 1.5)
   'photon-cannon     (hasheq 'dmg 20.0 'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'building? #t 'max-hp-ovr 150.0 'max-shield-ovr 150.0 'armor-ovr 1.0 'range-ovr 7.0 'period-ovr 0.89 'radius-ovr 1.0)
   'pylon             (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'building? #t 'max-hp-ovr 200.0 'max-shield-ovr 200.0 'radius-ovr 1.0)
   'scv               (hasheq 'dmg 5.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f 'worker? #t)
   'probe             (hasheq 'dmg 5.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #f 'splash-mode #f 'worker? #t)
   'drone             (hasheq 'dmg 5.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #t 'armored? #f 'biological? #t 'splash-mode #f 'worker? #t)
   'hatchery          (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #t 'splash-mode #f 'building? #t 'max-hp-ovr 1500.0 'radius-ovr 2.5)
   'command-center    (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'building? #t 'max-hp-ovr 1500.0 'armor-ovr 1.0 'radius-ovr 2.5)
   'nexus             (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'building? #t 'max-hp-ovr 1000.0 'max-shield-ovr 1000.0 'armor-ovr 1.0 'radius-ovr 2.5)
   'gateway           (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'building? #t 'max-hp-ovr 500.0 'max-shield-ovr 500.0 'radius-ovr 1.5)
   'cybernetics-core  (hasheq 'dmg 0.0  'hits 1 'bonus-light 0.0  'bonus-armored 0.0  'light? #f 'armored? #t 'biological? #f 'splash-mode #f 'building? #t 'max-hp-ovr 550.0 'max-shield-ovr 550.0 'radius-ovr 1.5)))

;; -----------------------------------------------------------------------------
;; 2. Simulation State Structures & Helpers
;; -----------------------------------------------------------------------------

(struct sim-unit
  (id team type
      x y
      hp max-hp shield max-shield armor
      light? armored? biological? flying? building? worker?
      speed range min-range dmg hits bonus-light bonus-armored
      weapon-period cooldown radius
      burrowed? sieged? splash-radius splash-mode concussive?
      ability-cd slow-until last-hit-sec
      shade-active? shade-frames shade-x shade-y shade-tx shade-ty
      drill-stacked? pass-through?
      bonus-bio attr-mask shield-armor energy max-energy
      has-barrier? barrier-rem barrier-until barrier-cd
      aam-until guardian-shield-until matrix-until
      neural-until neural-orig-team neural-caster-id
      fungal-until blinding-cloud-until
      snipe-cast-until snipe-target-id
      transfuse-rem-sec build-progress
      order) ; #f | (list 'move tx ty) | (list 'attack-unit tid) | (list 'repair-unit tid) | (list 'hold-position) | (list 'baneling-explode)
  #:mutable
  #:transparent)

(struct sim-storm (team x y radius expires-sec dps) #:mutable #:transparent)
(struct sim-cloud (team x y radius expires-sec) #:mutable #:transparent)
(struct sim-world-fx (storms clouds attack-buildings? enemy-caster-acted?) #:mutable #:transparent)

(define *WORLD-FX-TABLE* (make-weak-hasheq))
(define (get-world-fx w)
  (or (hash-ref *WORLD-FX-TABLE* w #f)
      (let ([fx (sim-world-fx '() '() #f #f)])
        (hash-set! *WORLD-FX-TABLE* w fx)
        fx)))

(struct sim-nova
  (id caster-id team x y vx vy remaining-frames age-frames radius base-dmg shield-bonus)
  #:mutable
  #:transparent)

(struct sim-bile
  (team tx ty remaining-frames radius dmg)
  #:mutable
  #:transparent)

(struct sim-spine
  (caster-id x y vx vy remaining-frames)
  #:mutable
  #:transparent)

(struct sim-wall-box
  (x1 y1 x2 y2 doorway?)
  #:transparent)

(struct sim-world
  (scenario-id mode frame units novas biles spines walls
               mineral-patches townhalls wall-door wall-slots
               upgrades enemy-upgrades
               disruptor-tracker spell-claims
               planner-calls tactics-triggered
               home-x home-y enemy-x enemy-y)
  #:mutable
  #:transparent)

(struct lotv-scenario-spec
  (id title description win-mode max-frames expected-default-winner expected-mothman-winner planner-refs setup-fn)
  #:transparent)

(define (fl v) (exact->inexact v))

(define (dist2d x1 y1 x2 y2)
  (define dx (- x2 x1))
  (define dy (- y2 y1))
  (sqrt (+ (* dx dx) (* dy dy))))

(define (unit-dist u1 u2)
  (dist2d (sim-unit-x u1) (sim-unit-y u1) (sim-unit-x u2) (sim-unit-y u2)))

(define (unit-edge-dist u1 u2)
  (max 0.0 (- (unit-dist u1 u2) (+ (sim-unit-radius u1) (sim-unit-radius u2)))))

(define (unit-alive? u)
  (> (+ (sim-unit-hp u) (sim-unit-shield u)) 0.0))

(define (unit-ehp u)
  (+ (max 0.0 (sim-unit-hp u)) (max 0.0 (sim-unit-shield u))))

(define (record-tactic! w sym)
  (set-sim-world-tactics-triggered!
   w
   (hash-update (sim-world-tactics-triggered w) sym add1 0)))

(define (record-planner! w sym)
  (set-sim-world-planner-calls!
   w
   (hash-update (sim-world-planner-calls w) sym add1 0)))

(define (make-sim-unit id team type x y
                       #:drill-stacked? [drill-stacked? #f]
                       #:ability-cd [ability-cd 0.0]
                       #:hp [hp-ovr #f]
                       #:shield [sh-ovr #f]
                       #:energy [en-ovr #f]
                       #:build-progress [build-progress 1.0]
                       #:shield-armor [shield-armor 0.0]
                       #:armor [armor-ovr #f])
  (define base (sc2-unit-combat-stats type))
  (define spec (hash-ref *LOTV-UNIT-SPECS* type (hasheq)))
  (define max-hp (fl (hash-ref spec 'max-hp-ovr (hash-ref base 'max-hp 80.0))))
  (define max-sh (fl (hash-ref spec 'max-shield-ovr (hash-ref base 'max-shield 0.0))))
  (define init-hp (if hp-ovr (fl hp-ovr) max-hp))
  (define init-sh (if sh-ovr (fl sh-ovr) max-sh))
  (define armor (fl (or armor-ovr (hash-ref spec 'armor-ovr (hash-ref base 'armor 0.0)))))
  (define spd (fl (hash-ref spec 'speed-ovr (hash-ref base 'speed 3.15))))
  (define rng (fl (hash-ref spec 'range-ovr (hash-ref base 'ground-range 5.0))))
  (define min-rng (fl (hash-ref spec 'min-range 0.0)))
  (define dmg (fl (hash-ref spec 'dmg 10.0)))
  (define hits (hash-ref spec 'hits 1))
  (define bl (fl (hash-ref spec 'bonus-light 0.0)))
  (define ba (fl (hash-ref spec 'bonus-armored 0.0)))
  (define bbio (fl (hash-ref spec 'bonus-bio 0.0)))
  (define wp (fl (hash-ref spec 'period-ovr (hash-ref base 'weapon-period 1.0))))
  (define rad (fl (hash-ref spec 'radius-ovr (unit-collision-radius type))))
  (define sr (fl (hash-ref base 'splash-radius 0.0)))
  (define mask (unit-attribute-mask type))
  (define max-en (fl (hash-ref spec 'max-energy 0.0)))
  (define init-en (fl (or en-ovr (hash-ref spec 'energy 0.0))))
  (define has-bar? (or (eq? type 'immortal) (not (not (hash-ref spec 'barrier? #f)))))
  (define light-flag?
    (if (hash-has-key? spec 'light?)
        (hash-ref spec 'light?)
        (not (= (bitwise-and mask SC2-UNIT-ATTR-LIGHT) 0))))
  (define arm-flag?
    (if (hash-has-key? spec 'armored?)
        (hash-ref spec 'armored?)
        (not (= (bitwise-and mask SC2-UNIT-ATTR-ARMORED) 0))))
  (define bio-flag?
    (if (hash-has-key? spec 'biological?)
        (hash-ref spec 'biological?)
        (not (= (bitwise-and mask SC2-UNIT-ATTR-BIOLOGICAL) 0))))
  (sim-unit
   id team type
   (fl x) (fl y)
   init-hp max-hp init-sh max-sh armor
   light-flag? arm-flag? bio-flag?
   (hash-ref base 'flying? #f)
   (hash-ref spec 'building? #f)
   (hash-ref spec 'worker? #f)
   spd rng min-rng dmg hits bl ba
   wp 0.0 rad
   (hash-ref spec 'burrowed? #f)
   (hash-ref spec 'sieged? #f)
   sr (hash-ref spec 'splash-mode #f) (hash-ref spec 'concussive? #f)
   (fl ability-cd) -1.0 -99.0
   #f 0 0.0 0.0 0.0 0.0
   drill-stacked? #f
   bbio mask (fl shield-armor) init-en max-en
   has-bar? 0.0 -1.0 0.0
   -1.0 -1.0 -1.0
   -1.0 team 0
   -1.0 -1.0
   -1.0 #f
   0.0 (fl build-progress)
   #f))

(define (sim-unit->planner-hash u w)
  (define cur-sec (* (sim-world-frame w) DT))
  (define st (sim-unit-type u))
  (define active-buffs
    (append
     (if (< cur-sec (sim-unit-aam-until u)) '(anti-armor-missile) '())
     (if (< cur-sec (sim-unit-guardian-shield-until u)) '(guardian-shield) '())
     (if (< cur-sec (sim-unit-matrix-until u)) '(interference-matrix) '())
     (if (< cur-sec (sim-unit-neural-until u)) '(neural-parasite) '())
     (if (< cur-sec (sim-unit-fungal-until u)) '(fungal-growth) '())
     (if (< cur-sec (sim-unit-blinding-cloud-until u)) '(blinding-cloud) '())))
  (define base
    (hasheq 'id (sim-unit-id u)
            'tag (sim-unit-id u)
            'unit-id (sim-unit-id u)
            'type st
            'x (sim-unit-x u)
            'y (sim-unit-y u)
            'hp (sim-unit-hp u)
            'health (sim-unit-hp u)
            'max-hp (sim-unit-max-hp u)
            'shield (sim-unit-shield u)
            'shields (sim-unit-shield u)
            'max-shield (sim-unit-max-shield u)
            'energy (sim-unit-energy u)
            'max-energy (sim-unit-max-energy u)
            'armor (sim-unit-armor u)
            'shield-armor (sim-unit-shield-armor u)
            'attr-mask (sim-unit-attr-mask u)
            'buffs active-buffs
            'speed (sim-unit-speed u)
            'range (sim-unit-range u)
            'radius (sim-unit-radius u)
            'light? (sim-unit-light? u)
            'armored? (sim-unit-armored? u)
            'biological? (sim-unit-biological? u)
            'flying (sim-unit-flying? u)
            'is-flying? (sim-unit-flying? u)
            'is-building (sim-unit-building? u)
            'is-building? (sim-unit-building? u)
            'is-structure (sim-unit-building? u)
            'burrowed? (sim-unit-burrowed? u)
            'sieged? (sim-unit-sieged? u)
            'barrier-active? (and (sim-unit-has-barrier? u)
                                  (or (<= (sim-unit-barrier-cd u) 0.0)
                                      (< cur-sec (sim-unit-barrier-until u))))
            'aam-debuff? (< cur-sec (sim-unit-aam-until u))
            'guardian-shield? (< cur-sec (sim-unit-guardian-shield-until u))
            'build-progress (sim-unit-build-progress u)
            'mineral-contents 1500
            'in-combat? (< (- cur-sec (sim-unit-last-hit-sec u)) 3.0)))
  (define with-disruptor
    (if (eq? st 'disruptor)
        (hash-set base 'nova-cooldown (max 0 (inexact->exact (round (* (sim-unit-ability-cd u) SC2-FASTER-FPS)))))
        base))
  (define with-stalker
    (if (eq? st 'stalker)
        (hash-set with-disruptor 'blink-cooldown (max 0 (inexact->exact (round (* (sim-unit-ability-cd u) SC2-FASTER-FPS)))))
        with-disruptor))
  (define with-ravager
    (if (eq? st 'ravager)
        (hash-set (hash-set with-stalker 'bile-ready? (<= (sim-unit-ability-cd u) 0.0))
                  'corrosive-bile-cooldown (max 0 (inexact->exact (round (* (sim-unit-ability-cd u) SC2-FASTER-FPS)))))
        with-stalker))
  (define with-lurker
    (if (eq? st 'lurker-burrowed)
        (hash-set with-ravager 'seismic-spines (not (not (memq 'seismic-spines (sim-world-enemy-upgrades w)))))
        with-ravager))
  (if (eq? st 'adept)
      (hash-set (hash-set (hash-set (hash-set with-lurker
                                              'phase-shift-ready? (and (<= (sim-unit-ability-cd u) 0.0)
                                                                       (not (sim-unit-shade-active? u))))
                                    'phase-shift-active? (sim-unit-shade-active? u))
                          'shade-x (and (sim-unit-shade-active? u) (sim-unit-shade-tx u)))
                'shade-y (and (sim-unit-shade-active? u) (sim-unit-shade-ty u)))
      with-lurker))

(define (sim-nova->planner-hash n)
  (hasheq 'id (sim-nova-id n)
          'tag (sim-nova-id n)
          'type 'disruptor-phased
          'unit_type DISRUPTOR-PHASED-UNIT-TYPE-ID
          'x (sim-nova-x n)
          'y (sim-nova-y n)
          'vx (sim-nova-vx n)
          'vy (sim-nova-vy n)
          'hp 10.0
          'health 10.0
          'remaining-frames (sim-nova-remaining-frames n)
          'age-frames (sim-nova-age-frames n)))

(define (sim-spine->effect-hash sp)
  (hasheq 'type 'lurker-spines
          'x (sim-spine-x sp)
          'y (sim-spine-y sp)
          'dx (sim-spine-vx sp)
          'dy (sim-spine-vy sp)))

(define (sim-bile->effect-hash b)
  (hasheq 'type 'corrosive-bile
          'x (sim-bile-tx b)
          'y (sim-bile-ty b)
          'radius (sim-bile-radius b)))

;; -----------------------------------------------------------------------------
;; 3. Damage, Splash, Collision, Wall & Doorway Physics
;; -----------------------------------------------------------------------------

(define (defender-under-guardian-shield? target w cur-sec)
  (or (< cur-sec (sim-unit-guardian-shield-until target))
      (let ([team (sim-unit-team target)])
        (for/or ([u (in-list (sim-world-units w))])
          (and (unit-alive? u)
               (eq? (sim-unit-team u) team)
               (eq? (sim-unit-type u) 'sentry)
               (< cur-sec (sim-unit-guardian-shield-until u))
               (<= (unit-dist target u) 4.5))))))

(define (apply-damage-to-unit! target raw-dmg hits ignore-armor? cur-sec
                               #:ranged? [ranged? #f]
                               #:under-gs? [under-gs? #f]
                               #:ignore-barrier? [ignore-barrier? #f])
  (when (and (unit-alive? target) (> raw-dmg 0.0))
    (set-sim-unit-last-hit-sec! target cur-sec)
    (define aam? (< cur-sec (sim-unit-aam-until target)))
    (define aam-delta (if aam? 2.0 0.0))
    (for ([_ (in-range hits)] #:when (unit-alive? target))
      (define gs-raw
        (if (and ranged? under-gs? (not ignore-armor?))
            (max 0.5 (- raw-dmg 2.0))
            raw-dmg))
      ;; Immortal Barrier: activates on hit (`100` absorb for `2.0s`, `32.0s` cooldown)
      (when (and (not ignore-barrier?)
                 (sim-unit-has-barrier? target)
                 (<= (sim-unit-barrier-cd target) 0.0)
                 (< (sim-unit-barrier-until target) cur-sec))
        (set-sim-unit-barrier-rem! target 100.0)
        (set-sim-unit-barrier-until! target (+ cur-sec 2.0))
        (set-sim-unit-barrier-cd! target 32.0))
      (define after-barrier
        (if (and (not ignore-barrier?)
                 (> (sim-unit-barrier-rem target) 0.0)
                 (<= cur-sec (sim-unit-barrier-until target)))
            (let ([abs (min (sim-unit-barrier-rem target) gs-raw)])
              (set-sim-unit-barrier-rem! target (- (sim-unit-barrier-rem target) abs))
              (- gs-raw abs))
            gs-raw))
      (when (> after-barrier 0.0)
        (define sh (sim-unit-shield target))
        (define hp (sim-unit-hp target))
        (define sh-armor-eff (if ignore-armor? 0.0 (- (sim-unit-shield-armor target) aam-delta)))
        (define hull-armor-eff (if ignore-armor? 0.0 (- (sim-unit-armor target) aam-delta)))
        (cond
          [(> sh 0.0)
           (define eff-sh-dmg (if ignore-armor? after-barrier (max 0.5 (- after-barrier sh-armor-eff))))
           (cond
             [(<= eff-sh-dmg sh)
              (set-sim-unit-shield! target (- sh eff-sh-dmg))]
             [else
              (define frac (/ (- eff-sh-dmg sh) (max 1e-6 eff-sh-dmg)))
              (set-sim-unit-shield! target 0.0)
              (define rem-raw (* frac after-barrier))
              (define hp-dmg (if ignore-armor? rem-raw (max 0.5 (- rem-raw hull-armor-eff))))
              (set-sim-unit-hp! target (max 0.0 (- hp hp-dmg)))])]
          [else
           (define hp-dmg (if ignore-armor? after-barrier (max 0.5 (- after-barrier hull-armor-eff))))
           (set-sim-unit-hp! target (max 0.0 (- hp hp-dmg)))])))))

(define (compute-attack-damage attacker defender)
  (define dmg (sim-unit-dmg attacker))
  (define m (sim-unit-attr-mask defender))
  (+ dmg
     (if (not (= (bitwise-and m SC2-UNIT-ATTR-LIGHT) 0)) (sim-unit-bonus-light attacker) 0.0)
     (if (not (= (bitwise-and m SC2-UNIT-ATTR-ARMORED) 0)) (sim-unit-bonus-armored attacker) 0.0)
     (if (not (= (bitwise-and m SC2-UNIT-ATTR-BIOLOGICAL) 0)) (sim-unit-bonus-bio attacker) 0.0)))

(define (point-to-segment-dist px py ax ay bx by)
  (define vx (- bx ax))
  (define vy (- by ay))
  (define len2 (+ (* vx vx) (* vy vy)))
  (if (<= len2 1e-8)
      (dist2d px py ax ay)
      (let* ([t (max 0.0 (min 1.0 (/ (+ (* (- px ax) vx) (* (- py ay) vy)) len2)))]
             [cx (+ ax (* t vx))]
             [cy (+ ay (* t vy))])
        (dist2d px py cx cy))))

(define (fire-unit-weapon! attacker target w)
  (define cur-sec (* (sim-world-frame w) DT))
  (define mode (sim-unit-splash-mode attacker))
  (define team (sim-unit-team attacker))
  (define units (sim-world-units w))
  (cond
    [(eq? mode 'bane)
     ;; Baneling suicide splash (`2.2`t radius onto all enemy ground units)
     (define bx (sim-unit-x attacker))
     (define by (sim-unit-y attacker))
     (for ([u (in-list units)]
           #:when (and (unit-alive? u)
                       (not (eq? (sim-unit-team u) team))
                       (not (sim-unit-flying? u))
                       (<= (dist2d bx by (sim-unit-x u) (sim-unit-y u)) 2.25)))
       (apply-damage-to-unit! u (compute-attack-damage attacker u) 1 #f cur-sec))
     (set-sim-unit-hp! attacker 0.0)
     (set-sim-unit-shield! attacker 0.0)]
    [(eq? mode 'tank)
     ;; Siege Tank splash hits BOTH friendly and enemy ground units inside 1.25t hitbox edge!
     (define tx (sim-unit-x target))
     (define ty (sim-unit-y target))
     (for ([u (in-list units)]
           #:when (and (unit-alive? u)
                       (not (sim-unit-flying? u))
                       (<= (max 0.0 (- (dist2d tx ty (sim-unit-x u) (sim-unit-y u)) (sim-unit-radius u))) 1.25)))
       (define d (max 0.0 (- (dist2d tx ty (sim-unit-x u) (sim-unit-y u)) (sim-unit-radius u))))
       (define frac
         (cond [(<= d 0.47) 1.0]
               [(<= d 0.78) 0.5]
               [else 0.25]))
       (apply-damage-to-unit! u (* frac (compute-attack-damage attacker u)) 1 #f cur-sec))]
    [(eq? mode 'lurker-line)
     ;; Linear spine ray along (lx, ly) -> target normalized dir, range 9.0-10.2, width 0.85
     (define lx (sim-unit-x attacker))
     (define ly (sim-unit-y attacker))
     (define dx (- (sim-unit-x target) lx))
     (define dy (- (sim-unit-y target) ly))
     (define mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
     (define vx (/ dx mag))
     (define vy (/ dy mag))
     (define spine-len (+ (sim-unit-range attacker) 0.5))
     (define ex (+ lx (* spine-len vx)))
     (define ey (+ ly (* spine-len vy)))
     (set-sim-world-spines! w (cons (sim-spine (sim-unit-id attacker) lx ly vx vy 20)
                                    (sim-world-spines w)))
     (for ([u (in-list units)]
           #:when (and (unit-alive? u)
                       (not (eq? (sim-unit-team u) team))
                       (not (sim-unit-flying? u))
                       (<= (point-to-segment-dist (sim-unit-x u) (sim-unit-y u) lx ly ex ey)
                           (+ 0.65 (* 0.5 (sim-unit-radius u))))))
       (apply-damage-to-unit! u (compute-attack-damage attacker u) 1 #f cur-sec))]
    [(eq? mode 'colossus)
     ;; Extended Thermal Lance perpendicular 3.2-tile sweep centered on target
     (define cx (sim-unit-x attacker))
     (define cy (sim-unit-y attacker))
     (define tx (sim-unit-x target))
     (define ty (sim-unit-y target))
     (define dx (- tx cx))
     (define dy (- ty cy))
     (define mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
     (define rx (/ dx mag))
     (define ry (/ dy mag))
     (define px (- ry))
     (define py rx)
     (define ax (- tx (* 1.60 px)))
     (define ay (- ty (* 1.60 py)))
     (define bx (+ tx (* 1.60 px)))
     (define by (+ ty (* 1.60 py)))
     (for ([u (in-list units)]
           #:when (and (unit-alive? u)
                       (not (eq? (sim-unit-team u) team))
                       (not (sim-unit-flying? u))
                       (<= (point-to-segment-dist (sim-unit-x u) (sim-unit-y u) ax ay bx by)
                           (+ 0.50 (sim-unit-radius u)))))
       (apply-damage-to-unit! u (compute-attack-damage attacker u) (sim-unit-hits attacker) #f cur-sec
                              #:ranged? #t
                              #:under-gs? (defender-under-guardian-shield? u w cur-sec)))]
    [(eq? mode 'archon)
     ;; Archon splash `1.0` radius (`100%` within `0.25`, `50%` within `0.50`, `25%` within `1.0`)
     (define tx (sim-unit-x target))
     (define ty (sim-unit-y target))
     (for ([u (in-list units)]
           #:when (and (unit-alive? u)
                       (not (eq? (sim-unit-team u) team))
                       (<= (max 0.0 (- (dist2d tx ty (sim-unit-x u) (sim-unit-y u)) (sim-unit-radius u))) 1.0)))
       (define d (max 0.0 (- (dist2d tx ty (sim-unit-x u) (sim-unit-y u)) (sim-unit-radius u))))
       (define frac (cond [(<= d 0.25) 1.0] [(<= d 0.50) 0.5] [else 0.25]))
       (apply-damage-to-unit! u (* frac (compute-attack-damage attacker u)) 1 #f cur-sec
                              #:ranged? #t
                              #:under-gs? (defender-under-guardian-shield? u w cur-sec)))]
    [(eq? mode 'ultra)
     ;; Ultralisk melee Kaiser Blades cleave (`100%` primary, `33%` within `1.5`t ground)
     (define tx (sim-unit-x target))
     (define ty (sim-unit-y target))
     (for ([u (in-list units)]
           #:when (and (unit-alive? u)
                       (not (eq? (sim-unit-team u) team))
                       (not (sim-unit-flying? u))
                       (<= (max 0.0 (- (dist2d tx ty (sim-unit-x u) (sim-unit-y u)) (sim-unit-radius u))) 1.5)))
       (define frac (if (= (sim-unit-id u) (sim-unit-id target)) 1.0 0.33))
       (apply-damage-to-unit! u (* frac (compute-attack-damage attacker u)) 1 #f cur-sec))]
    [else
     (define ranged? (> (sim-unit-range attacker) 1.5))
     (apply-damage-to-unit! target
                            (compute-attack-damage attacker target)
                            (sim-unit-hits attacker)
                            #f cur-sec
                            #:ranged? ranged?
                            #:under-gs? (and ranged? (defender-under-guardian-shield? target w cur-sec)))
     (when (sim-unit-concussive? attacker)
       (set-sim-unit-slow-until! target (+ cur-sec 1.5)))])
  (set-sim-unit-cooldown! attacker (sim-unit-weapon-period attacker)))

(define (doorway-sealed? w)
  (define door (sim-world-wall-door w))
  (and door
       (for/or ([u (in-list (sim-world-units w))])
         (and (unit-alive? u)
              (eq? (sim-unit-team u) 'ally)
              (not (sim-unit-building? u))
              (not (sim-unit-flying? u))
              (<= (dist2d (sim-unit-x u) (sim-unit-y u) (car door) (cdr door)) 0.85)))))

(define (clamp-out-of-wall-box! u wb)
  (define ux (sim-unit-x u))
  (define uy (sim-unit-y u))
  (define r (sim-unit-radius u))
  (define x1 (- (sim-wall-box-x1 wb) r))
  (define y1 (- (sim-wall-box-y1 wb) r))
  (define x2 (+ (sim-wall-box-x2 wb) r))
  (define y2 (+ (sim-wall-box-y2 wb) r))
  (when (and (> ux x1) (< ux x2) (> uy y1) (< uy y2))
    (define dl (- ux x1))
    (define dr (- x2 ux))
    (define db (- uy y1))
    (define dt (- y2 uy))
    (define m (min dl dr db dt))
    (cond
      [(= m dl) (set-sim-unit-x! u x1)]
      [(= m dr) (set-sim-unit-x! u x2)]
      [(= m db) (set-sim-unit-y! u y1)]
      [else (set-sim-unit-y! u y2)])))

(define (resolve-geometry-and-collisions! w)
  (define units (filter unit-alive? (sim-world-units w)))
  (define walls (sim-world-walls w))
  (define sealed? (doorway-sealed? w))
  (define (clamp-walls!)
    (for ([u (in-list units)]
          #:when (and (not (sim-unit-building? u)) (not (sim-unit-flying? u))))
      (for ([wb (in-list walls)])
        (when (or (not (sim-wall-box-doorway? wb))
                  (and sealed? (eq? (sim-unit-team u) 'enemy)))
          (clamp-out-of-wall-box! u wb)))
      (set-sim-unit-x! u (max 10.0 (min 140.0 (sim-unit-x u))))
      (set-sim-unit-y! u (max 10.0 (min 140.0 (sim-unit-y u))))))
  (define gnd
    (for/vector ([u (in-list units)]
                 #:when (and (not (sim-unit-flying? u))
                             (not (sim-unit-burrowed? u))
                             (or (not (sim-unit-building? u))
                                 (eq? (sim-unit-type u) 'bunker))))
      u))
  (define n (vector-length gnd))
  ;; Multi-pass ground collision separation + post-push wall clamping (prevents 1x1 doorway stacking)
  (clamp-walls!)
  (for ([_pass (in-range 4)])
    (for ([i (in-range n)])
      (define u1 (vector-ref gnd i))
      (for ([j (in-range (+ i 1) n)])
        (define u2 (vector-ref gnd j))
        (define skip?
          (or (and (sim-unit-drill-stacked? u1) (sim-unit-drill-stacked? u2)
                   (eq? (sim-unit-team u1) (sim-unit-team u2)))
              (and (eq? (sim-world-mode w) 'mothman-tactics)
                   (or (sim-unit-pass-through? u1) (sim-unit-pass-through? u2)))))
        (unless skip?
          (define dx (- (sim-unit-x u2) (sim-unit-x u1)))
          (define dy (- (sim-unit-y u2) (sim-unit-y u1)))
          (define min-d (+ (sim-unit-radius u1) (sim-unit-radius u2)))
          (define d (sqrt (+ (* dx dx) (* dy dy))))
          (when (< d min-d)
            (define push (* 0.5 (- min-d d)))
            (define h1? (or (sim-unit-building? u1) (equal? (sim-unit-order u1) '(hold-position))))
            (define h2? (or (sim-unit-building? u2) (equal? (sim-unit-order u2) '(hold-position))))
            (define-values (nx ny)
              (if (> d 1e-4)
                  (values (/ dx d) (/ dy d))
                  (values (if (even? i) 1.0 -1.0) 0.0)))
            (unless h1?
              (set-sim-unit-x! u1 (- (sim-unit-x u1) (* (if h2? 2.0 1.0) push nx)))
              (set-sim-unit-y! u1 (- (sim-unit-y u1) (* (if h2? 2.0 1.0) push ny))))
            (unless h2?
              (set-sim-unit-x! u2 (+ (sim-unit-x u2) (* (if h1? 2.0 1.0) push nx)))
              (set-sim-unit-y! u2 (+ (sim-unit-y u2) (* (if h1? 2.0 1.0) push ny))))))))
    (clamp-walls!)))

;; -----------------------------------------------------------------------------
;; 4. Movement, Attack, Projectiles, Novas, Biles, Shades & Regen Step
;; -----------------------------------------------------------------------------

(define (unit-effective-dmg u)
  (if (>= (sim-unit-build-progress u) 1.0) (sim-unit-dmg u) 0.0))

(define (nearest-enemy u w
                       #:exclude-buildings? [exclude-bldgs? #t]
                       #:allow-zero-dmg-bldgs? [allow-zero-bldgs? #f]
                       #:prefer-type [prefer-type #f])
  (define team (sim-unit-team u))
  (define cands
    (for/list ([o (in-list (sim-world-units w))]
               #:when (and (unit-alive? o)
                           (not (eq? (sim-unit-team o) team))
                           (or allow-zero-bldgs?
                               (not exclude-bldgs?)
                               (not (sim-unit-building? o))
                               (> (unit-effective-dmg o) 0.0))))
      o))
  (cond
    [(null? cands) #f]
    [prefer-type
     (define pref (filter (lambda (o) (eq? (sim-unit-type o) prefer-type)) cands))
     (define pool (if (null? pref) cands pref))
     (argmin (lambda (o) (unit-dist u o)) pool)]
    [else
     (argmin (lambda (o) (unit-dist u o)) cands)]))

(define (step-unit-toward! u tx ty w)
  (define cur-sec (* (sim-world-frame w) DT))
  (when (and (> (sim-unit-speed u) 0.0)
             (>= cur-sec (sim-unit-snipe-cast-until u)))
    (define dx (- tx (sim-unit-x u)))
    (define dy (- ty (sim-unit-y u)))
    (define d (sqrt (+ (* dx dx) (* dy dy))))
    (when (> d 0.05)
      (define slow-mult
        (cond
          [(< cur-sec (sim-unit-fungal-until u)) 0.25]
          [(< cur-sec (sim-unit-slow-until u)) 0.5]
          [else 1.0]))
      (define step (min d (* (sim-unit-speed u) slow-mult DT)))
      (set-sim-unit-x! u (+ (sim-unit-x u) (* step (/ dx d))))
      (set-sim-unit-y! u (+ (sim-unit-y u) (* step (/ dy d)))))))

(define (find-unit-by-id w id)
  (for/first ([u (in-list (sim-world-units w))]
              #:when (and (= (sim-unit-id u) id) (unit-alive? u)))
    u))

(define (unit-in-weapon-range? a t [cur-sec -1.0])
  (define d (unit-dist a t))
  (define edge-d (unit-edge-dist a t))
  (define base-rng (sim-unit-range a))
  (define eff-rng
    (if (and (>= cur-sec 0.0)
             (not (sim-unit-flying? a))
             (< cur-sec (sim-unit-blinding-cloud-until a)))
        (min base-rng 1.0)
        base-rng))
  (and (> d (sim-unit-min-range a))
       (<= edge-d (+ eff-rng (if (<= eff-rng 0.5) 0.25 0.0)))))

(define (unit-can-attack-now? u cur-sec)
  (and (> (unit-effective-dmg u) 0.0)
       (>= (sim-unit-build-progress u) 1.0)
       (>= cur-sec (sim-unit-matrix-until u))
       (>= cur-sec (sim-unit-snipe-cast-until u))))

(define (step-unit-actions! w)
  (define cur-sec (* (sim-world-frame w) DT))
  (define units (sim-world-units w))
  (define fx (get-world-fx w))
  (define target-bldgs? (sim-world-fx-attack-buildings? fx))
  (for ([u (in-list units)] #:when (unit-alive? u))
    (set-sim-unit-cooldown! u (max 0.0 (- (sim-unit-cooldown u) DT)))
    (set-sim-unit-ability-cd! u (max 0.0 (- (sim-unit-ability-cd u) DT)))
    (set-sim-unit-barrier-cd! u (max 0.0 (- (sim-unit-barrier-cd u) DT)))
    ;; Passive Energy regen (~0.7875/sec)
    (when (and (> (sim-unit-max-energy u) 0.0)
               (< (sim-unit-energy u) (sim-unit-max-energy u)))
      (set-sim-unit-energy! u (min (sim-unit-max-energy u) (+ (sim-unit-energy u) (* 0.7875 DT)))))
    ;; Passive Zerg HP & Protoss Shield regeneration
    (when (and (sim-unit-biological? u)
               (not (sim-unit-building? u))
               (< (sim-unit-hp u) (sim-unit-max-hp u)))
      (set-sim-unit-hp! u (min (sim-unit-max-hp u) (+ (sim-unit-hp u) ZERG-HP-REGEN-PER-FRAME))))
    (when (and (> (sim-unit-max-shield u) 0.0)
               (< (sim-unit-shield u) (sim-unit-max-shield u))
               (>= (- cur-sec (sim-unit-last-hit-sec u)) SHIELD-REGEN-DELAY-SEC))
      (set-sim-unit-shield! u (min (sim-unit-max-shield u) (+ (sim-unit-shield u) SHIELD-REGEN-PER-FRAME))))
    ;; Queen Transfusion HoT (`50 HP / 7.1s`)
    (when (> (sim-unit-transfuse-rem-sec u) 0.0)
      (set-sim-unit-transfuse-rem-sec! u (max 0.0 (- (sim-unit-transfuse-rem-sec u) DT)))
      (set-sim-unit-hp! u (min (sim-unit-max-hp u) (+ (sim-unit-hp u) (* (/ 50.0 7.1) DT)))))
    ;; Infestor Fungal Growth DoT (`30 dmg / 3.0s = 10.0 dps`, ignores armor)
    (when (< cur-sec (sim-unit-fungal-until u))
      (apply-damage-to-unit! u (* 10.0 DT) 1 #t cur-sec))
    ;; Neural Parasite tether revert when expired or caster dead/out of range
    (when (not (eq? (sim-unit-team u) (sim-unit-neural-orig-team u)))
      (define caster (find-unit-by-id w (sim-unit-neural-caster-id u)))
      (when (or (>= cur-sec (sim-unit-neural-until u))
                (not caster)
                (> (unit-dist u caster) 14.0))
        (set-sim-unit-team! u (sim-unit-neural-orig-team u))
        (set-sim-unit-neural-until! u -1.0)
        (set-sim-unit-order! u #f)))
    ;; Proxy structure build progress (Photon Cannon warps automatically; Bunker needs living SCV <= 3.0t)
    (when (and (sim-unit-building? u) (< (sim-unit-build-progress u) 1.0))
      (define team (sim-unit-team u))
      (define can-advance?
        (case (sim-unit-type u)
          [(photon-cannon pylon gateway cybernetics-core) #t]
          [(bunker)
           (for/or ([s (in-list units)])
             (and (unit-alive? s)
                  (eq? (sim-unit-team s) team)
                  (eq? (sim-unit-type s) 'scv)
                  (<= (unit-dist u s) 3.5)))]
          [else #f]))
      (when can-advance?
        (set-sim-unit-build-progress! u (min 1.0 (+ (sim-unit-build-progress u) (/ DT 22.0))))))
    ;; Ghost Steady Targeting completion (`170` spell dmg, strictly `'biological`, ignores armor)
    (when (and (sim-unit-snipe-target-id u)
               (>= cur-sec (sim-unit-snipe-cast-until u)))
      (define stgt (find-unit-by-id w (sim-unit-snipe-target-id u)))
      (set-sim-unit-snipe-target-id! u #f)
      (set-sim-unit-snipe-cast-until! u -1.0)
      (when (and stgt
                 (not (eq? (sim-unit-team stgt) (sim-unit-team u)))
                 (<= (unit-dist u stgt) 12.5)
                 (spell-valid-for-target-attrs? 'steady-targeting (sim-unit-type stgt)))
        (apply-damage-to-unit! stgt 170.0 1 #t cur-sec)
        (record-tactic! w 'ghost-snipe-detonated)))
    ;; Execute assigned order
    (when (unit-alive? u)
      (define ord (sim-unit-order u))
      (match ord
        [(list 'baneling-explode)
         (when (eq? (sim-unit-type u) 'baneling)
           (fire-unit-weapon! u u w))]
        [(list 'hold-position)
         (when (and (unit-can-attack-now? u cur-sec) (<= (sim-unit-cooldown u) 0.0))
           (define tgt (nearest-enemy u w #:allow-zero-dmg-bldgs? target-bldgs?))
           (when (and tgt (unit-in-weapon-range? u tgt cur-sec))
             (fire-unit-weapon! u tgt w)))]
        [(list 'repair-unit tid)
         (define tgt (find-unit-by-id w tid))
         (when (and tgt
                    (eq? (sim-unit-team tgt) (sim-unit-team u))
                    (spell-valid-for-target-attrs? 'repair (sim-unit-type tgt))
                    (< (sim-unit-hp tgt) (sim-unit-max-hp tgt)))
           (if (<= (unit-edge-dist u tgt) 1.2)
               (begin
                 (set-sim-unit-hp! tgt (min (sim-unit-max-hp tgt) (+ (sim-unit-hp tgt) (* 14.0 DT))))
                 (record-tactic! w 'scv-repair-heal-tick))
               (step-unit-toward! u (sim-unit-x tgt) (sim-unit-y tgt) w)))]
        [(list 'move tx ty)
         (step-unit-toward! u tx ty w)]
        [(list 'attack-move-to tx ty)
         (define tgt (nearest-enemy u w #:allow-zero-dmg-bldgs? target-bldgs?))
         (cond
           [(and tgt (unit-can-attack-now? u cur-sec) (unit-in-weapon-range? u tgt cur-sec))
            (when (<= (sim-unit-cooldown u) 0.0)
              (fire-unit-weapon! u tgt w))]
           [tgt
            (step-unit-toward! u (sim-unit-x tgt) (sim-unit-y tgt) w)]
           [else
            (step-unit-toward! u tx ty w)])]
        [(list 'attack-unit tid)
         (define tgt (or (find-unit-by-id w tid)
                         (nearest-enemy u w #:allow-zero-dmg-bldgs? target-bldgs?)))
         (when tgt
           (if (unit-in-weapon-range? u tgt cur-sec)
               (when (and (unit-can-attack-now? u cur-sec) (<= (sim-unit-cooldown u) 0.0))
                 (fire-unit-weapon! u tgt w))
               (when (> (sim-unit-speed u) 0.0)
                 (step-unit-toward! u (sim-unit-x tgt) (sim-unit-y tgt) w))))]
        [_
         ;; Default combat acquisition for idle units (Colossus focuses Light targets first!)
         (define tgt
           (if (eq? (sim-unit-type u) 'colossus)
               (or (nearest-enemy u w #:prefer-type 'hydralisk)
                   (nearest-enemy u w #:allow-zero-dmg-bldgs? target-bldgs?))
               (nearest-enemy u w #:allow-zero-dmg-bldgs? target-bldgs?)))
         (when tgt
           (if (unit-in-weapon-range? u tgt cur-sec)
               (when (and (unit-can-attack-now? u cur-sec) (<= (sim-unit-cooldown u) 0.0))
                 (fire-unit-weapon! u tgt w))
               (when (> (sim-unit-speed u) 0.0)
                 (step-unit-toward! u (sim-unit-x tgt) (sim-unit-y tgt) w))))]))))

(define (step-lotv-world-fx! w)
  (define cur-sec (* (sim-world-frame w) DT))
  (define fx (get-world-fx w))
  (define units (sim-world-units w))
  ;; Enemy High Templar counter-storm at >= 16f if still alive with >= 75 energy and not matrixed
  (when (and (memq (sim-world-scenario-id w)
                   '(ghost-emp-shield-psionic-and-bio-snipe
                     viper-abduct-blinding-cloud-and-ht-feedback))
             (>= (sim-world-frame w) 16)
             (not (sim-world-fx-enemy-caster-acted? fx)))
    (define ally-combat
      (filter (lambda (u) (and (unit-alive? u) (eq? (sim-unit-team u) 'ally) (not (sim-unit-building? u))))
              units))
    (define enemy-hts
      (filter (lambda (u)
                (and (unit-alive? u)
                     (eq? (sim-unit-team u) 'enemy)
                     (eq? (sim-unit-type u) 'high-templar)
                     (>= (sim-unit-energy u) 75.0)
                     (>= cur-sec (sim-unit-matrix-until u))))
              units))
    (when (and (pair? ally-combat) (pair? enemy-hts))
      (define ax (/ (for/sum ([a (in-list ally-combat)]) (sim-unit-x a)) (fl (length ally-combat))))
      (define ay (/ (for/sum ([a (in-list ally-combat)]) (sim-unit-y a)) (fl (length ally-combat))))
      (set-sim-world-fx-enemy-caster-acted?! fx #t)
      (for ([ht (in-list enemy-hts)] [idx (in-naturals)])
        (when (and (<= (dist2d (sim-unit-x ht) (sim-unit-y ht) ax ay) 12.0)
                   (>= (sim-unit-energy ht) 75.0))
          (set-sim-unit-energy! ht (- (sim-unit-energy ht) 75.0))
          (set-sim-world-fx-storms!
           fx
           (cons (sim-storm 'enemy (+ ax (* 0.5 (if (even? idx) -1.0 1.0))) ay 1.5 (+ cur-sec 2.85) 28.07)
                 (sim-world-fx-storms fx)))))))
  ;; Tick Psi Storms (`28.07 DPS`, ignores armor)
  (define active-storms
    (for/list ([st (in-list (sim-world-fx-storms fx))]
               #:when (< cur-sec (sim-storm-expires-sec st)))
      (define st-team (sim-storm-team st))
      (for ([u (in-list units)]
            #:when (and (unit-alive? u)
                        (not (eq? (sim-unit-team u) st-team))
                        (<= (dist2d (sim-storm-x st) (sim-storm-y st) (sim-unit-x u) (sim-unit-y u))
                            (+ (sim-storm-radius st) (sim-unit-radius u)))))
        (apply-damage-to-unit! u (* (sim-storm-dps st) DT) 1 #t cur-sec))
      st))
  (set-sim-world-fx-storms! fx active-storms)
  ;; Tick Blinding Clouds (`range -> 1.0` for non-flying units inside `r=2.0`)
  (define active-clouds
    (for/list ([cl (in-list (sim-world-fx-clouds fx))]
               #:when (< cur-sec (sim-cloud-expires-sec cl)))
      (define cl-team (sim-cloud-team cl))
      (for ([u (in-list units)]
            #:when (and (unit-alive? u)
                        (not (eq? (sim-unit-team u) cl-team))
                        (not (sim-unit-flying? u))
                        (<= (dist2d (sim-cloud-x cl) (sim-cloud-y cl) (sim-unit-x u) (sim-unit-y u))
                            (+ (sim-cloud-radius cl) (sim-unit-radius u)))))
        (set-sim-unit-blinding-cloud-until! u (max (sim-unit-blinding-cloud-until u) (+ cur-sec 0.2))))
      cl))
  (set-sim-world-fx-clouds! fx active-clouds))

(define (execute-spell-directives! w spells)
  (define cur-sec (* (sim-world-frame w) DT))
  (define fx (get-world-fx w))
  (define units (sim-world-units w))
  (for ([sd (in-list spells)])
    (define caster (find-unit-by-id w (spell-directive-caster-tag sd)))
    (when (and caster
               (unit-alive? caster)
               (<= (sim-unit-ability-cd caster) 0.0)
               (>= cur-sec (sim-unit-matrix-until caster))
               (>= cur-sec (sim-unit-snipe-cast-until caster)))
      (define ab (spell-directive-ability sd))
      (define ttag (spell-directive-target-tag sd))
      (define tx (fl (spell-directive-target-x sd)))
      (define ty (fl (spell-directive-target-y sd)))
      (define tgt (and (> ttag 0) (find-unit-by-id w ttag)))
      (define c-team (sim-unit-team caster))
      (case ab
        [(emp-round)
         (when (>= (sim-unit-energy caster) 75.0)
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 75.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (record-tactic! w 'ghost-emp-round)
           (for ([e (in-list units)]
                 #:when (and (unit-alive? e)
                             (not (eq? (sim-unit-team e) c-team))
                             (<= (dist2d tx ty (sim-unit-x e) (sim-unit-y e)) (+ 1.5 (sim-unit-radius e)))))
             (set-sim-unit-shield! e (max 0.0 (- (sim-unit-shield e) 100.0)))
             (set-sim-unit-energy! e (max 0.0 (- (sim-unit-energy e) 100.0)))))]
        [(steady-targeting)
         (when (and tgt
                    (not (eq? (sim-unit-team tgt) c-team))
                    (>= (sim-unit-energy caster) 50.0)
                    (spell-valid-for-target-attrs? 'steady-targeting (sim-unit-type tgt)))
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 50.0))
           (set-sim-unit-ability-cd! caster 1.45)
           (set-sim-unit-snipe-cast-until! caster (+ cur-sec 1.40))
           (set-sim-unit-snipe-target-id! caster (sim-unit-id tgt))
           (set-sim-unit-order! caster (list 'hold-position))
           (record-tactic! w 'ghost-steady-targeting))]
        [(interference-matrix)
         (when (and tgt
                    (not (eq? (sim-unit-team tgt) c-team))
                    (>= (sim-unit-energy caster) 75.0)
                    (spell-valid-for-target-attrs? 'interference-matrix (sim-unit-type tgt)))
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 75.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (set-sim-unit-matrix-until! tgt (+ cur-sec 11.0))
           (record-tactic! w 'raven-interference-matrix))]
        [(anti-armor-missile)
         (when (and tgt
                    (>= (sim-unit-energy caster) 75.0))
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 75.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (record-tactic! w 'raven-anti-armor-missile)
           (define ax (sim-unit-x tgt))
           (define ay (sim-unit-y tgt))
           (for ([e (in-list units)]
                 #:when (and (unit-alive? e)
                             (not (eq? (sim-unit-team e) c-team))
                             (<= (dist2d ax ay (sim-unit-x e) (sim-unit-y e)) (+ 2.88 (sim-unit-radius e)))))
             (set-sim-unit-aam-until! e (+ cur-sec 14.0))))]
        [(feedback)
         (when (and tgt
                    (not (eq? (sim-unit-team tgt) c-team))
                    (>= (sim-unit-energy caster) 50.0)
                    (spell-valid-for-target-attrs? 'feedback (sim-unit-type tgt) (sim-unit-energy tgt) (sim-unit-shield tgt)))
           (define t-en (sim-unit-energy tgt))
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 50.0))
           (set-sim-unit-energy! tgt 0.0)
           (set-sim-unit-ability-cd! caster 0.6)
           (apply-damage-to-unit! tgt (* 0.5 t-en) 1 #t cur-sec)
           (record-tactic! w 'ht-feedback-drain))]
        [(psi-storm)
         (when (>= (sim-unit-energy caster) 75.0)
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 75.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (set-sim-world-fx-storms!
            fx
            (cons (sim-storm c-team tx ty 1.5 (+ cur-sec 2.85) 28.07)
                  (sim-world-fx-storms fx)))
           (record-tactic! w 'ht-psi-storm))]
        [(guardian-shield)
         (when (>= (sim-unit-energy caster) 75.0)
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 75.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (set-sim-unit-guardian-shield-until! caster (+ cur-sec 11.0))
           (record-tactic! w 'sentry-guardian-shield))]
        [(fungal-growth)
         (when (>= (sim-unit-energy caster) 75.0)
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 75.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (record-tactic! w 'infestor-fungal-growth)
           (for ([e (in-list units)]
                 #:when (and (unit-alive? e)
                             (not (eq? (sim-unit-team e) c-team))
                             (<= (dist2d tx ty (sim-unit-x e) (sim-unit-y e)) (+ 2.25 (sim-unit-radius e)))))
             (set-sim-unit-fungal-until! e (+ cur-sec 3.0))))]
        [(neural-parasite)
         (when (and tgt
                    (not (eq? (sim-unit-team tgt) c-team))
                    (>= (sim-unit-energy caster) 100.0)
                    (spell-valid-for-target-attrs? 'neural-parasite (sim-unit-type tgt)))
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 100.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (set-sim-unit-team! tgt c-team)
           (set-sim-unit-neural-until! tgt (+ cur-sec 11.0))
           (set-sim-unit-neural-caster-id! tgt (sim-unit-id caster))
           (set-sim-unit-order! tgt #f)
           (record-tactic! w 'infestor-neural-parasite))]
        [(abduct)
         (when (and tgt
                    (not (eq? (sim-unit-team tgt) c-team))
                    (>= (sim-unit-energy caster) 75.0)
                    (spell-valid-for-target-attrs? 'abduct (sim-unit-type tgt)))
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 75.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (define dx (- (sim-unit-x tgt) (sim-unit-x caster)))
           (define dy (- (sim-unit-y tgt) (sim-unit-y caster)))
           (define mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
           (set-sim-unit-x! tgt (+ (sim-unit-x caster) (* 1.3 (/ dx mag))))
           (set-sim-unit-y! tgt (+ (sim-unit-y caster) (* 1.3 (/ dy mag))))
           (set-sim-unit-cooldown! tgt (max (sim-unit-cooldown tgt) 0.5))
           (record-tactic! w 'viper-abduct))]
        [(blinding-cloud)
         (when (>= (sim-unit-energy caster) 100.0)
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 100.0))
           (set-sim-unit-ability-cd! caster 0.8)
           (set-sim-world-fx-clouds!
            fx
            (cons (sim-cloud c-team tx ty 2.0 (+ cur-sec 5.71))
                  (sim-world-fx-clouds fx)))
           (record-tactic! w 'viper-blinding-cloud))]
        [(transfusion)
         (when (and tgt
                    (eq? (sim-unit-team tgt) c-team)
                    (>= (sim-unit-energy caster) 50.0)
                    (spell-valid-for-target-attrs? 'transfusion (sim-unit-type tgt)))
           (set-sim-unit-energy! caster (- (sim-unit-energy caster) 50.0))
           (set-sim-unit-ability-cd! caster 0.6)
           (set-sim-unit-hp! tgt (min (sim-unit-max-hp tgt) (+ (sim-unit-hp tgt) 75.0)))
           (set-sim-unit-transfuse-rem-sec! tgt 7.1)
           (record-tactic! w 'queen-transfuse-bio))]
        [(repair)
         (when (and tgt
                    (eq? (sim-unit-team tgt) c-team)
                    (spell-valid-for-target-attrs? 'repair (sim-unit-type tgt))
                    (< (sim-unit-hp tgt) (sim-unit-max-hp tgt)))
           (set-sim-unit-order! caster (list 'repair-unit (sim-unit-id tgt)))
           (record-tactic! w 'scv-repair-mech))]))))

(define (step-effects-and-shades! w)
  (define cur-sec (* (sim-world-frame w) DT))
  (define units (sim-world-units w))
  (step-lotv-world-fx! w)
  ;; 1. Adept Phase Shift shades (7.0s = 157 frames @ 6.30 tps, bypasses walls & gunfire)
  (for ([u (in-list units)] #:when (and (unit-alive? u) (sim-unit-shade-active? u)))
    (define rem (- (sim-unit-shade-frames u) 1))
    (define sx (sim-unit-shade-x u))
    (define sy (sim-unit-shade-y u))
    (define tx (sim-unit-shade-tx u))
    (define ty (sim-unit-shade-ty u))
    (define dx (- tx sx))
    (define dy (- ty sy))
    (define d (sqrt (+ (* dx dx) (* dy dy))))
    (when (> d 0.05)
      (define step (min d (* 6.30 DT)))
      (set-sim-unit-shade-x! u (+ sx (* step (/ dx d))))
      (set-sim-unit-shade-y! u (+ sy (* step (/ dy d)))))
    (if (<= rem 0)
        (begin
          (set-sim-unit-x! u (sim-unit-shade-x u))
          (set-sim-unit-y! u (sim-unit-shade-y u))
          (set-sim-unit-shade-active?! u #f)
          (set-sim-unit-shade-frames! u 0)
          (set-sim-unit-ability-cd! u 11.0))
        (set-sim-unit-shade-frames! u rem)))

  ;; 2. Enemy Purification Nova homing & detonation
  (define ally-hashes
    (for/list ([u (in-list units)] #:when (and (unit-alive? u) (eq? (sim-unit-team u) 'ally)))
      (sim-unit->planner-hash u w)))
  (define enemy-hashes
    (for/list ([u (in-list units)] #:when (and (unit-alive? u) (eq? (sim-unit-team u) 'enemy)))
      (sim-unit->planner-hash u w)))
  (define nova-hashes
    (for/list ([n (in-list (sim-world-novas w))])
      (sim-nova->planner-hash n)))
  (define steer-orders
    (if (null? (sim-world-novas w))
        '()
        (steer-purification-novas
         (append enemy-hashes nova-hashes)
         ally-hashes
         #:current-frame (sim-world-frame w))))
  (define steer-by-tag
    (for/hasheqv ([so (in-list steer-orders)])
      (values (nova-steer-order-nova-tag so) so)))
  (define surviving-novas '())
  (for ([n (in-list (sim-world-novas w))])
    (define so (hash-ref steer-by-tag (sim-nova-id n) #f))
    (when so
      (define dx (- (nova-steer-order-tx so) (sim-nova-x n)))
      (define dy (- (nova-steer-order-ty so) (sim-nova-y n)))
      (define d (sqrt (+ (* dx dx) (* dy dy))))
      (when (> d 0.05)
        (define vx (* DISRUPTOR-NOVA-SPEED-PER-FRAME (/ dx d)))
        (define vy (* DISRUPTOR-NOVA-SPEED-PER-FRAME (/ dy d)))
        (set-sim-nova-vx! n vx)
        (set-sim-nova-vy! n vy)))
    (set-sim-nova-x! n (+ (sim-nova-x n) (sim-nova-vx n)))
    (set-sim-nova-y! n (+ (sim-nova-y n) (sim-nova-vy n)))
    (set-sim-nova-age-frames! n (+ (sim-nova-age-frames n) 1))
    (set-sim-nova-remaining-frames! n (- (sim-nova-remaining-frames n) 1))
    (cond
      [(<= (sim-nova-remaining-frames n) 0)
       ;; Detonate Purification Nova (`145` + `55` vs Shields inside `1.5`t)
       (for ([u (in-list units)]
             #:when (and (unit-alive? u)
                         (not (eq? (sim-unit-team u) (sim-nova-team n)))
                         (not (sim-unit-flying? u))
                         (<= (dist2d (sim-nova-x n) (sim-nova-y n) (sim-unit-x u) (sim-unit-y u))
                             (sim-nova-radius n))))
         (define bonus (if (> (sim-unit-max-shield u) 0.0) (sim-nova-shield-bonus n) 0.0))
         ;; Purification Nova spell damage ignores armor
         (apply-damage-to-unit! u (+ (sim-nova-base-dmg n) bonus) 1 #t cur-sec))]
      [else
       (set! surviving-novas (cons n surviving-novas))]))
  (set-sim-world-novas! w (reverse surviving-novas))

  ;; 3. Corrosive Bile countdown & impact
  (define surviving-biles '())
  (for ([b (in-list (sim-world-biles w))])
    (set-sim-bile-remaining-frames! b (- (sim-bile-remaining-frames b) 1))
    (cond
      [(<= (sim-bile-remaining-frames b) 0)
       (for ([u (in-list units)]
             #:when (and (unit-alive? u)
                         (not (eq? (sim-unit-team u) (sim-bile-team b)))
                         (<= (dist2d (sim-bile-tx b) (sim-bile-ty b) (sim-unit-x u) (sim-unit-y u))
                             (+ (sim-bile-radius b) (sim-unit-radius u)))))
         (apply-damage-to-unit! u (sim-bile-dmg b) 1 #t cur-sec))]
      [else
       (set! surviving-biles (cons b surviving-biles))]))
  (set-sim-world-biles! w (reverse surviving-biles))

  ;; 4. Decay Lurker spine visuals
  (set-sim-world-spines!
   w
   (for/list ([sp (in-list (sim-world-spines w))]
              #:when (> (sim-spine-remaining-frames sp) 1))
     (set-sim-spine-remaining-frames! sp (- (sim-spine-remaining-frames sp) 1))
     sp)))

;; -----------------------------------------------------------------------------
;; 5. Enemy Disruptor Nova Caster AI (Used in Scenario 2)
;; -----------------------------------------------------------------------------

(define *NEXT-PROJ-ID* 90000)
(define (alloc-proj-id!)
  (set! *NEXT-PROJ-ID* (+ *NEXT-PROJ-ID* 1))
  *NEXT-PROJ-ID*)

(define (step-enemy-disruptors! w)
  (define units (sim-world-units w))
  (define e-disruptors
    (filter (lambda (u) (and (unit-alive? u)
                             (eq? (sim-unit-team u) 'enemy)
                             (eq? (sim-unit-type u) 'disruptor)
                             (<= (sim-unit-ability-cd u) 0.0)))
            units))
  (when (pair? e-disruptors)
    (define enemy-hashes
      (for/list ([u (in-list units)] #:when (and (unit-alive? u) (eq? (sim-unit-team u) 'enemy)))
        (sim-unit->planner-hash u w)))
    (define ally-hashes
      (for/list ([u (in-list units)] #:when (and (unit-alive? u) (eq? (sim-unit-team u) 'ally)))
        (sim-unit->planner-hash u w)))
    ;; Enforce enemy stagger (>= 18 frames) so the 2 Disruptors cast realistic staggered Novas
    (define active-e-novas
      (for/list ([n (in-list (sim-world-novas w))] #:when (eq? (sim-nova-team n) 'enemy))
        n))
    (define min-age
      (if (null? active-e-novas)
          999
          (apply min (map sim-nova-age-frames active-e-novas))))
    (when (>= min-age 18)
      (define plans
        (plan-disruptor-nova-casts
         enemy-hashes ally-hashes #:current-frame (sim-world-frame w)))
      (when (pair? plans)
        (define p (car plans))
        (define caster (find-unit-by-id w (nova-cast-plan-caster-tag p)))
        (when (and caster (<= (sim-unit-ability-cd caster) 0.0))
          (define cx (sim-unit-x caster))
          (define cy (sim-unit-y caster))
          (define dx (- (nova-cast-plan-tx p) cx))
          (define dy (- (nova-cast-plan-ty p) cy))
          (define d (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
          (set-sim-unit-ability-cd! caster 21.4)
          (set-sim-world-novas!
           w
           (cons (sim-nova (alloc-proj-id!)
                           (sim-unit-id caster)
                           'enemy
                           cx cy
                           (* DISRUPTOR-NOVA-SPEED-PER-FRAME (/ dx d))
                           (* DISRUPTOR-NOVA-SPEED-PER-FRAME (/ dy d))
                           DISRUPTOR-NOVA-LIFETIME-FRAMES
                           0
                           DISRUPTOR-NOVA-SPLASH-RADIUS
                           DISRUPTOR-NOVA-BASE-DAMAGE
                           DISRUPTOR-NOVA-SHIELD-BONUS)
                 (sim-world-novas w))))))))

;; -----------------------------------------------------------------------------
;; 6. Policy Controllers: `'default-ai` vs `'mothman-tactics`
;; -----------------------------------------------------------------------------

(define (plan-default-ai! w)
  (for ([u (in-list (sim-world-units w))]
        #:when (and (unit-alive? u)
                    (eq? (sim-unit-team u) 'ally)
                    (not (sim-unit-building? u))))
    (define tgt (nearest-enemy u w))
    (cond
      [(not tgt)
       (set-sim-unit-order! u #f)]
      [(and (eq? (sim-unit-type u) 'baneling)
            (<= (unit-edge-dist u tgt) 0.45))
       ;; Naive default-AI explodes Banelings straight onto front Marauders
       (set-sim-unit-order! u (list 'baneling-explode))]
      [else
       (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt)))])))

(define (splash-cmd-map cmds)
  (for/hasheqv ([c (in-list cmds)] #:when (hash? c))
    (values (hash-ref c 'unit-id 0) c)))

(define (apply-splash-avoidance-map! w u-list cmd-map #:dive-tank? [dive-tank? #f] #:colossus-focus? [colossus-focus? #f])
  (for ([u (in-list u-list)])
    (define c (hash-ref cmd-map (sim-unit-id u) #f))
    (cond
      [c
       (define role (hash-ref c 'role 'splash-micro))
       (record-tactic! w role)
       (set-sim-unit-pass-through?! u (not (not (memq role '(commit-run-through-splash-concave
                                                            siege-tank-deadzone-dive
                                                            colossus-radial-split-dive
                                                            commit-run-through-disruptor-split)))))
       (define tx (hash-ref c 'target-x (sim-unit-x u)))
       (define ty (hash-ref c 'target-y (sim-unit-y u)))
       (cond
         [(and dive-tank? (eq? role 'siege-tank-deadzone-dive))
          (define near-tank (nearest-enemy u w #:prefer-type 'siege-tank-sieged))
          (if (and near-tank (<= (unit-dist u near-tank) 2.0))
              (set-sim-unit-order! u (list 'attack-unit (sim-unit-id near-tank)))
              (set-sim-unit-order! u (list 'move tx ty)))]
         [(and colossus-focus? (eq? role 'colossus-radial-split-dive))
          ;; Once staggered around radial slot or at Colossus standoff, fire at Colossi
          (define near-col (nearest-enemy u w #:prefer-type 'colossus))
          (if (and near-col (<= (unit-edge-dist u near-col) (+ (sim-unit-range u) 0.1)))
              (set-sim-unit-order! u (list 'attack-unit (sim-unit-id near-col)))
              (set-sim-unit-order! u (list 'move tx ty)))]
         [else
          (set-sim-unit-order! u (list 'move tx ty))])]
      [else
       (set-sim-unit-pass-through?! u #f)
       (define tgt
         (cond
           [colossus-focus? (or (nearest-enemy u w #:prefer-type 'colossus) (nearest-enemy u w))]
           [dive-tank? (or (nearest-enemy u w #:prefer-type 'siege-tank-sieged) (nearest-enemy u w))]
           [else (nearest-enemy u w)]))
       (when tgt
         (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))])))

(define (select-best-exact-focus-target attacker enemies w #:allow-bldgs? [allow-bldgs? #f] #:colossus-splash? [col-splash? #f])
  (define cur-sec (* (sim-world-frame w) DT))
  (define atype (sim-unit-type attacker))
  (define cands
    (filter (lambda (e)
              (and (unit-alive? e)
                   (not (eq? (sim-unit-team e) (sim-unit-team attacker)))
                   (or allow-bldgs? (not (sim-unit-building? e)) (> (unit-effective-dmg e) 0.0))))
            enemies))
  (cond
    [(null? cands) #f]
    [else
     (record-planner! w 'compute-exact-hit-damage-vs-target)
     (argmax
      (lambda (e)
        (define etype (sim-unit-type e))
        (define bar? (and (sim-unit-has-barrier? e)
                          (or (<= (sim-unit-barrier-cd e) 0.0)
                              (< cur-sec (sim-unit-barrier-until e)))))
        (define aam? (< cur-sec (sim-unit-aam-until e)))
        (define gs? (defender-under-guardian-shield? e w cur-sec))
        (define exact-hit
          (compute-exact-hit-damage-vs-target
           atype etype
           #:target-shields (sim-unit-shield e)
           #:target-hp (sim-unit-hp e)
           #:barrier-active? bar?
           #:aam-debuff? aam?
           #:guardian-shield? gs?))
        (define ehp (max 25.0 (unit-ehp e)))
        (define d (unit-dist attacker e))
        (define in-rng-bonus (if (unit-in-weapon-range? attacker e cur-sec) 1.6 1.0))
        (define cluster-bonus
          (if col-splash?
              (+ 1.0
                 (* 0.35
                    (for/sum ([o (in-list cands)]
                              #:when (and (not (= (sim-unit-id o) (sim-unit-id e)))
                                          (not (sim-unit-flying? o))
                                          (<= (dist2d (sim-unit-x e) (sim-unit-y e) (sim-unit-x o) (sim-unit-y o)) 1.8)))
                      (if (not (= (bitwise-and (sim-unit-attr-mask o) SC2-UNIT-ATTR-LIGHT) 0)) 1.6 0.6))))
              1.0))
        (define threat-bonus (if (> (unit-effective-dmg e) 0.0) 1.25 0.65))
        (define rad-bonus (if (eq? atype 'archon) (* 0.2 (aoe-radius-packing-multiplier (unit-collision-radius etype) 1.0)) 0.0))
        (+ (* (/ (* exact-hit in-rng-bonus cluster-bonus threat-bonus)
                 (* ehp (+ 1.0 (* 0.25 (max 0.0 (- d (sim-unit-range attacker)))))))
              100.0)
           rad-bonus
           (- (* 0.15 d))))
      cands)]))

(define (apply-spellcaster-scenario-micro! w allies ally-hashes enemies enemy-hashes ally-bldg-hashes enemy-bldg-hashes
                                           #:standoff-casters? [standoff-casters? #t]
                                           #:kite-ranged? [kite-ranged? #f])
  (define cur-sec (* (sim-world-frame w) DT))
  (unless (sim-world-spell-claims w)
    (set-sim-world-spell-claims! w (make-spell-claims)))
  (record-planner! w 'step-pro-spellcaster-micro!)
  (define spells
    (step-pro-spellcaster-micro!
     ally-hashes enemy-hashes
     #:claims (sim-world-spell-claims w)
     #:current-frame (sim-world-frame w)
     #:ally-buildings ally-bldg-hashes
     #:enemy-buildings enemy-bldg-hashes
     #:home-x (sim-world-home-x w)
     #:home-y (sim-world-home-y w)
     #:enemy-base-x (sim-world-enemy-x w)
     #:enemy-base-y (sim-world-enemy-y w)))
  (execute-spell-directives! w spells)
  (define spell-tags
    (for/hasheqv ([sd (in-list spells)]
                  #:when (memq (spell-directive-ability sd)
                               '(emp-round steady-targeting interference-matrix anti-armor-missile
                                 feedback psi-storm guardian-shield fungal-growth neural-parasite
                                 abduct blinding-cloud transfusion repair)))
      (values (spell-directive-caster-tag sd) #t)))
  (for ([u (in-list allies)])
    (define utype (sim-unit-type u))
    (define uid (sim-unit-id u))
    (cond
      [(< cur-sec (sim-unit-snipe-cast-until u))
       (set-sim-unit-order! u (list 'hold-position))]
      [(hash-has-key? spell-tags uid)
       (void)]
      [(and standoff-casters?
            (memq utype '(raven infestor viper high-templar)))
       (define near-e (nearest-enemy u w))
       (cond
         [(and near-e (< (unit-dist u near-e) 5.2))
          (let* ([dx (- (sim-unit-x u) (sim-unit-x near-e))]
                 [dy (- (sim-unit-y u) (sim-unit-y near-e))]
                 [mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy))))])
            (set-sim-unit-order! u (list 'move (+ (sim-unit-x u) (* 1.6 (/ dx mag)))
                                               (+ (sim-unit-y u) (* 1.6 (/ dy mag))))))]
         [(and near-e (> (unit-dist u near-e) 8.6) (>= (sim-unit-energy u) 50.0))
          (set-sim-unit-order! u (list 'move (sim-unit-x near-e) (sim-unit-y near-e)))]
         [else
          (set-sim-unit-order! u (list 'hold-position))])]
      [else
       (define near-e (nearest-enemy u w))
       (cond
         [(and kite-ranged?
               (> (sim-unit-range u) 3.5)
               (> (sim-unit-cooldown u) 0.25)
               near-e
               (<= (sim-unit-range near-e) 1.5)
               (< (unit-dist u near-e) 3.6))
          (define dx (- (sim-unit-x u) (sim-unit-x near-e)))
          (define dy (- (sim-unit-y u) (sim-unit-y near-e)))
          (define mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
          (record-tactic! w 'ranged-kite-vs-melee)
          (set-sim-unit-order! u (list 'move (+ (sim-unit-x u) (* 1.8 (/ dx mag)))
                                             (+ (sim-unit-y u) (* 1.8 (/ dy mag)))))]
         [else
          (define tgt (select-best-exact-focus-target u enemies w #:colossus-splash? (eq? utype 'colossus)))
          (when tgt
            (record-tactic! w 'exact-attribute-focus-fire)
            (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))])])))

(define (apply-worker-rush-tactics! w allies enemies
                                   #:pull-hp-thresh [pull-hp 11.0]
                                   #:pull-shield-thresh [pull-shield #f]
                                   #:scv-repair? [scv-repair? #f]
                                   #:kite-ranged? [kite-ranged? #f]
                                   #:proxy-snipe? [proxy-snipe? #f])
  (record-planner! w 'select-worker-drill-stack-mineral-patch)
  (record-planner! w 'translate-bot-actions->sc2-raw-commands)
  (define patches (sim-world-mineral-patches w))
  (define ths (sim-world-townhalls w))
  (define th0 (if (pair? ths) (car ths) (hasheq 'x (sim-world-home-x w) 'y (sim-world-home-y w))))
  (define thx (fl (hash-ref th0 'x (sim-world-home-x w))))
  (define thy (fl (hash-ref th0 'y (sim-world-home-y w))))
  (define workers (filter sim-unit-worker? allies))
  (define non-workers (filter (lambda (u) (not (sim-unit-worker? u))) allies))
  (define combat-enemies (filter (lambda (e) (not (sim-unit-building? e))) enemies))
  (define bldg-enemies (filter sim-unit-building? enemies))
  (define-values (ecx ecy)
    (if (null? combat-enemies)
        (values thx thy)
        (values (/ (for/sum ([e (in-list combat-enemies)]) (sim-unit-x e)) (fl (length combat-enemies)))
                (/ (for/sum ([e (in-list combat-enemies)]) (sim-unit-y e)) (fl (length combat-enemies))))))
  (when (and (pair? workers) (pair? patches))
    (define patch (select-worker-drill-stack-mineral-patch ecx ecy thx thy patches))
    (when (and patch (zero? (sim-world-frame w)))
      (define patch-id (hash-ref patch 'id 901))
      (define sc2-allies
        (for/list ([u (in-list workers)])
          (sc2-unit 1 1 (sim-unit-id u) 104 2
                    (sc2-point3d (sim-unit-x u) (sim-unit-y u) 0.0)
                    0.0 0.375 1.0 1 0 1 0 (sim-unit-hp u) (sim-unit-max-hp u) (sim-unit-shield u) (sim-unit-max-shield u) 0.0 0.0 0 0
                    #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0)))
      (define sc2-patches
        (for/list ([p (in-list patches)])
          (sc2-unit 1 3 (hash-ref p 'id 901) 341 1
                    (sc2-point3d (fl (hash-ref p 'x thx)) (fl (hash-ref p 'y thy)) 0.0)
                    0.0 1.0 1.0 1 0 1 0 1500.0 1500.0 0.0 0.0 0.0 0.0 0 0
                    #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0)))
      (define sc2-enemies
        (for/list ([e (in-list combat-enemies)])
          (sc2-unit 1 4 (sim-unit-id e) 84 2
                    (sc2-point3d (sim-unit-x e) (sim-unit-y e) 0.0)
                    0.0 0.375 1.0 1 0 1 0 (sim-unit-hp e) (sim-unit-max-hp e) (sim-unit-shield e) (sim-unit-max-shield e) 0.0 0.0 0 0
                    #f #f #f #f #t '() 0 '() 0 0 0.0 0 0 0 0)))
      (define sc2-th
        (sc2-unit 1 1 890 86 1 (sc2-point3d thx thy 0.0)
                  0.0 2.5 1.0 1 0 1 0 1500.0 1500.0 0.0 0.0 0.0 0.0 0 0
                  #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0))
      (define obs
        (sc2-observation 10
                         (sc2-player-common 1 50 0 14 12 0 12 0 0 0 0)
                         (cons sc2-th (append sc2-allies sc2-patches sc2-enemies))
                         '() '() (sc2-point3d thx thy 0.0) '() '() '() '() '() '()))
      (define first-e (and (pair? combat-enemies) (car combat-enemies)))
      (define act (list 'worker-drill-stack-attack
                        (map sim-unit-id workers)
                        patch-id
                        (if first-e (sim-unit-id first-e) 0)
                        ecx ecy))
      (define cmds (translate-bot-actions->sc2-raw-commands (list act) obs))
      (when (and (pair? cmds)
                 (for/and ([c (in-list cmds)])
                   (= (sc2-raw-unit-command-ability-id c) 23)))
        (record-tactic! w 'note-r4-c-suppressed-far-mineral-walk-emitted-attack-23))))
  ;; Non-worker ranged defender kiting (e.g. early Marine vs Zealot+Workers)
  (when kite-ranged?
    (for ([u (in-list non-workers)])
      (define near-melee
        (and (pair? combat-enemies)
             (argmin (lambda (e) (unit-dist u e)) combat-enemies)))
      (cond
        [(and near-melee
              (> (sim-unit-cooldown u) 0.12)
              (< (unit-dist u near-melee) 3.8))
         (define dx (- (sim-unit-x u) (sim-unit-x near-melee)))
         (define dy (- (sim-unit-y u) (sim-unit-y near-melee)))
         (define mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
         (record-tactic! w 'defender-marine-kite)
         (set-sim-unit-order! u (list 'move (+ (sim-unit-x u) (* 1.8 (/ dx mag)))
                                            (+ (sim-unit-y u) (* 1.8 (/ dy mag)))))]
        [else
         (define tgt
           (and (pair? combat-enemies)
                (argmin (lambda (e) (+ (unit-ehp e) (* 2.0 (unit-dist u e)))) combat-enemies)))
         (when tgt (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))])))
  ;; Proxy cannon/bunker/builder snipe split (prioritize Photon Cannon / Bunker ahead of Pylon!)
  (define proxy-bldg
    (and proxy-snipe?
         (or (findf (lambda (b) (memq (sim-unit-type b) '(photon-cannon bunker))) bldg-enemies)
             (findf (lambda (b) (eq? (sim-unit-type b) 'pylon)) bldg-enemies))))
  (define proxy-turret
    (and proxy-snipe?
         (findf (lambda (b) (memq (sim-unit-type b) '(photon-cannon bunker))) bldg-enemies)))
  (define proxy-builder
    (and proxy-snipe? proxy-turret
         (for/first ([e (in-list combat-enemies)]
                     #:when (and (sim-unit-worker? e)
                                 (<= (unit-dist e proxy-turret) 2.5)))
           e)))
  (define snipe-count (if (and proxy-snipe? (or proxy-builder proxy-turret)) 5 0))
  (define-values (snipers defenders)
    (if (> snipe-count 0)
        (split-at workers (min snipe-count (length workers)))
        (values '() workers)))
  (for ([u (in-list snipers)])
    (set-sim-unit-drill-stacked?! u #t)
    (define s-tgt (or proxy-turret proxy-builder))
    (when s-tgt
      (record-tactic! w 'proxy-builder-cannon-snipe)
      (set-sim-unit-order! u (list 'attack-unit (sim-unit-id s-tgt)))))
  ;; Injured SCV repair pairing (`spell-valid-for-target-attrs? 'repair`)
  (define injured-scv
    (and scv-repair?
         (pair? defenders)
         (for/first ([s (in-list defenders)]
                     #:when (and (< (sim-unit-hp s) 30.0)
                                 (spell-valid-for-target-attrs? 'repair (sim-unit-type s))))
           s)))
  (define healer-scv
    (and injured-scv
         (findf (lambda (s) (and (not (= (sim-unit-id s) (sim-unit-id injured-scv)))
                                 (>= (sim-unit-hp s) 30.0)))
                defenders)))
  ;; Main worker pocket / drill-stack / focus-fire / wounded-pull
  (define low-target
    (cond
      [(pair? combat-enemies)
       (argmin (lambda (e) (+ (unit-ehp e) (* 0.25 (dist2d ecx ecy (sim-unit-x e) (sim-unit-y e)))))
               combat-enemies)]
      [(pair? bldg-enemies)
       (car bldg-enemies)]
      [else #f]))
  (define-values (acx acy)
    (if (null? defenders)
        (values thx thy)
        (values (/ (for/sum ([u (in-list defenders)]) (sim-unit-x u)) (fl (length defenders)))
                (/ (for/sum ([u (in-list defenders)]) (sim-unit-y u)) (fl (length defenders))))))
  (define spread-radius
    (if (null? defenders)
        0.0
        (apply max 0.0 (map (lambda (u) (dist2d acx acy (sim-unit-x u) (sim-unit-y u))) defenders))))
  (for ([u (in-list defenders)])
    (set-sim-unit-drill-stacked?! u #t)
    (define d-e (dist2d (sim-unit-x u) (sim-unit-y u) ecx ecy))
    (define needs-pull?
      (or (< (sim-unit-hp u) pull-hp)
          (and pull-shield (< (sim-unit-shield u) pull-shield))))
    (cond
      [(and healer-scv (= (sim-unit-id u) (sim-unit-id healer-scv)))
       (record-tactic! w 'scv-repair-pocket-heal)
       (set-sim-unit-order! u (list 'repair-unit (sim-unit-id injured-scv)))]
      [(and (> d-e 3.0) (> spread-radius 1.4) (< (sim-world-frame w) 28) (pair? combat-enemies))
       (record-tactic! w 'worker-drill-stack-converge)
       (set-sim-unit-order! u (list 'move (- thx 0.7) thy))]
      [(and needs-pull? (> (sim-unit-cooldown u) 0.25) (> (length defenders) 2) (pair? combat-enemies))
       (define dx (- (sim-unit-x u) ecx))
       (define dy (- (sim-unit-y u) ecy))
       (define mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
       (record-tactic! w 'pull-wounded-worker-drop-aggro)
       (set-sim-unit-order! u (list 'move (+ (sim-unit-x u) (* 1.4 (/ dx mag)))
                                          (+ (sim-unit-y u) (* 1.4 (/ dy mag)))))]
      [low-target
       (record-tactic! w 'worker-focus-fire-lowest-ehp)
       (set-sim-unit-order! u (list 'attack-unit (sim-unit-id low-target)))])))

(define (plan-mothman-tactics! w)
  (define units (filter unit-alive? (sim-world-units w)))
  (define allies (filter (lambda (u) (and (eq? (sim-unit-team u) 'ally) (not (sim-unit-building? u)))) units))
  (define ally-bldgs (filter (lambda (u) (and (eq? (sim-unit-team u) 'ally) (sim-unit-building? u))) units))
  (define enemies (filter (lambda (u) (eq? (sim-unit-team u) 'enemy)) units))
  (define ally-hashes (map (lambda (u) (sim-unit->planner-hash u w)) allies))
  (define ally-bldg-hashes (map (lambda (u) (sim-unit->planner-hash u w)) ally-bldgs))
  (define enemy-hashes (map (lambda (u) (sim-unit->planner-hash u w)) enemies))
  (define nova-hashes (map sim-nova->planner-hash (sim-world-novas w)))
  (define effect-hashes
    (append (map sim-spine->effect-hash (sim-world-spines w))
            (map sim-bile->effect-hash (sim-world-biles w))))
  (define sid (sim-world-scenario-id w))

  (case sid
    ;; -------------------------------------------------------------------------
    ;; 1. Baneling Move-Past Marauder Screen into Light Marine Clump
    ;; -------------------------------------------------------------------------
    [(baneling-move-past-marauder-screen)
     (record-planner! w 'plan-baneling-move-past-and-light-clump-detonate)
     (define dirs
       (plan-baneling-move-past-and-light-clump-detonate
        ally-hashes enemy-hashes
        #:home-x (sim-world-home-x w)
        #:home-y (sim-world-home-y w)))
     (define dir-by-tag
       (for/hasheqv ([d (in-list dirs)])
         (values (harass-directive-unit-tag d) d)))
     (define live-marine-cnt (count (lambda (e) (eq? (sim-unit-type e) 'marine)) enemies))
     (define live-marines? (> live-marine-cnt 0))
     (define live-lings (count (lambda (a) (eq? (sim-unit-type a) 'zergling)) allies))
     (for ([u (in-list allies)] [idx (in-naturals)])
       (define d (hash-ref dir-by-tag (sim-unit-id u) #f))
       (define light-in-1.85
         (count (lambda (e)
                  (and (sim-unit-light? e) (not (sim-unit-flying? e)) (<= (unit-dist u e) 1.85)))
                enemies))
       (define light-in-2.2
         (count (lambda (e)
                  (and (sim-unit-light? e) (not (sim-unit-flying? e)) (<= (unit-dist u e) 2.2)))
                enemies))
       (cond
         [(and (eq? (sim-unit-type u) 'zergling))
          (set-sim-unit-pass-through?! u #t)
          ;; Wing Speedlings soak top/bottom Marine volleys while remaining Lings focus-fire Marauders
          (define tgt
            (if (and (= (modulo idx 3) 0) live-marines?)
                (let* ([marines (filter (lambda (e) (eq? (sim-unit-type e) 'marine)) enemies)]
                       [side-marines
                        (filter (lambda (m)
                                  (if (< (sim-unit-y u) 50.0) (< (sim-unit-y m) 50.0) (>= (sim-unit-y m) 50.0)))
                                marines)]
                       [pool (if (null? side-marines) marines side-marines)])
                  (if (null? pool) (nearest-enemy u w) (argmin (lambda (e) (unit-dist u e)) pool)))
                (let ([maras (filter (lambda (e) (eq? (sim-unit-type e) 'marauder)) enemies)])
                  (if (pair? maras)
                      (argmin (lambda (m) (+ (* 100.0 (unit-ehp m)) (sim-unit-id m))) maras)
                      (nearest-enemy u w)))))
          (when tgt (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))]
         [(and (eq? (sim-unit-type u) 'baneling)
               (<= (sim-unit-hp u) 12.0)
               (>= light-in-2.2 3))
          (record-tactic! w 'baneling-light-clump-detonate)
          (set-sim-unit-pass-through?! u #t)
          (set-sim-unit-order! u (list 'baneling-explode))]
         [(and d (eq? (harass-directive-action d) 'baneling-explode))
          (define total-light
            (count (lambda (e) (and (sim-unit-light? e) (not (sim-unit-flying? e)))) enemies))
          (cond
            [(or (>= light-in-1.85 5)
                 (and (< total-light 6) (>= light-in-1.85 2))
                 (and (<= (sim-unit-hp u) 8.0) (>= light-in-2.2 2)))
             (record-tactic! w 'baneling-light-clump-detonate)
             (set-sim-unit-pass-through?! u #t)
             (set-sim-unit-order! u (list 'baneling-explode))]
            [else
             ;; Step deeper toward nearest Marine clump center before detonating so 2.25t hits whole clump
             (define near-m (or (nearest-enemy u w #:prefer-type 'marine) (nearest-enemy u w)))
             (set-sim-unit-pass-through?! u #t)
             (if near-m
                 (set-sim-unit-order! u (list 'move (sim-unit-x near-m) (sim-unit-y near-m)))
                 (set-sim-unit-order! u (list 'baneling-explode)))])]
         [(and d (eq? (harass-directive-action d) 'move))
          ;; Once Marine clumps are wiped (<=2 Marines left), send leftover Baneling straight into Marauders
          (if (and (<= live-marine-cnt 2) (<= live-lings 9))
              (let ([mara (nearest-enemy u w)])
                (set-sim-unit-pass-through?! u #f)
                (when mara
                  (if (<= (unit-edge-dist u mara) 0.15)
                      (set-sim-unit-order! u (list 'baneling-explode))
                      (set-sim-unit-order! u (list 'move (sim-unit-x mara) (sim-unit-y mara))))))
              (let* ([raw-tx (harass-directive-tx d)]
                     [raw-ty (harass-directive-ty d)]
                     ;; Keep Banelings moving around Marauders toward Marines rather than backing into starting edge
                     [tx (if (and live-marines? (< raw-tx (sim-unit-x u)))
                             (min 49.6 (+ (sim-unit-x u) 2.0))
                             raw-tx)]
                     [ty (if (and live-marines? (< raw-tx (sim-unit-x u)))
                             (if (< (sim-unit-y u) 50.0) 46.8 53.2)
                             raw-ty)])
                (record-tactic! w (harass-directive-reason d))
                (set-sim-unit-pass-through?! u #t)
                (set-sim-unit-order! u (list 'move tx ty))))]
         [else
          (set-sim-unit-pass-through?! u #f)
          (define tgt (or (nearest-enemy u w #:prefer-type 'marine) (nearest-enemy u w)))
          (when tgt (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))]))]

    ;; -------------------------------------------------------------------------
    ;; 2. Disruptor Nova Catchable-Range Split, Blink Dodge & Cooldown Dive
    ;; -------------------------------------------------------------------------
    [(disruptor-nova-catchable-range-and-cooldown-dive)
     (define tr (sim-world-disruptor-tracker w))
     (define f-enemies (append enemy-hashes nova-hashes))
     (record-planner! w 'disruptor-nova-catchable-range)
     (record-planner! w 'plan-anti-nova-scatter)
     (record-planner! w 'evaluate-disruptor-snipe-and-cooldowns)
     (void (disruptor-nova-catchable-range 4.13 #t #:disruptor-ready? #t))
     (define dodge-orders
       (plan-anti-nova-scatter
        ally-hashes f-enemies
        #:tracker tr
        #:current-frame (sim-world-frame w)
        #:blink-researched? #t
        #:home-x (sim-world-home-x w)
        #:home-y (sim-world-home-y w)))
     (define snipe-evals
       (evaluate-disruptor-snipe-and-cooldowns
        ally-hashes f-enemies
        #:tracker tr
        #:current-frame (sim-world-frame w)))
     (define dodge-by-id
       (for/hasheqv ([o (in-list dodge-orders)])
         (values (anti-nova-dodge-order-unit-tag o) o)))
     (define dive-eval
       (findf (lambda (ev)
                (and (or (disruptor-snipe-eval-cooldown-dive-ok? ev)
                         (disruptor-snipe-eval-snipe-feasible? ev))
                     (find-unit-by-id w (disruptor-snipe-eval-enemy-tag ev))))
              snipe-evals))
     (define has-active-nova? (pair? nova-hashes))
     (for ([u (in-list allies)])
       (define dod (hash-ref dodge-by-id (sim-unit-id u) #f))
       (cond
         [dod
          (record-tactic! w (anti-nova-dodge-order-reason dod))
          (set-sim-unit-pass-through?! u #t)
          (cond
            [(and (eq? (anti-nova-dodge-order-action dod) 'blink)
                  (eq? (sim-unit-type u) 'stalker)
                  (<= (sim-unit-ability-cd u) 0.0))
             ;; Execute instant Blink escape + 7.0s Stalker Blink cooldown
             (set-sim-unit-x! u (anti-nova-dodge-order-tx dod))
             (set-sim-unit-y! u (anti-nova-dodge-order-ty dod))
             (set-sim-unit-ability-cd! u 7.0)
             (set-sim-unit-order! u (list 'move (anti-nova-dodge-order-tx dod) (anti-nova-dodge-order-ty dod)))]
            [else
             (set-sim-unit-order! u (list 'move (anti-nova-dodge-order-tx dod) (anti-nova-dodge-order-ty dod)))])]
         [(and (not has-active-nova?) dive-eval)
          (record-tactic! w 'disruptor-cooldown-punish-dive)
          (set-sim-unit-pass-through?! u #t)
          (define d-tgt (find-unit-by-id w (disruptor-snipe-eval-enemy-tag dive-eval)))
          (when (and d-tgt
                     (eq? (sim-unit-type u) 'stalker)
                     (<= (sim-unit-ability-cd u) 0.0)
                     (> (unit-dist u d-tgt) 6.2))
            ;; Blink forward into Disruptor on cooldown (`15`s+ left)
            (define dx (- (sim-unit-x d-tgt) (sim-unit-x u)))
            (define dy (- (sim-unit-y d-tgt) (sim-unit-y u)))
            (define d (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
            (define blink-step (min 7.5 (max 2.0 (- d 3.8))))
            (set-sim-unit-x! u (+ (sim-unit-x u) (* blink-step (/ dx d))))
            (set-sim-unit-y! u (+ (sim-unit-y u) (* blink-step (/ dy d))))
            (set-sim-unit-ability-cd! u 7.0))
          (if d-tgt
              (set-sim-unit-order! u (list 'attack-unit (sim-unit-id d-tgt)))
              (let ([t (nearest-enemy u w)])
                (when t (set-sim-unit-order! u (list 'attack-unit (sim-unit-id t))))))]
         [else
          (set-sim-unit-pass-through?! u #f)
          (define tgt (or (and (not has-active-nova?) (nearest-enemy u w #:prefer-type 'disruptor))
                          (nearest-enemy u w)))
          (when tgt (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))]))]

    ;; -------------------------------------------------------------------------
    ;; 3. Lurker Linear Spine Step-Out + Ravager Corrosive Bile & Concave
    ;; -------------------------------------------------------------------------
    [(lurker-linear-spine-step-out-and-bile-concave)
     (record-planner! w 'step-pro-spellcaster-micro!)
     (record-planner! w 'plan-avoid-siege-tank-and-lurker-splash-zones)
     (define claims (sim-world-spell-claims w))
     (define spells
       (step-pro-spellcaster-micro!
        ally-hashes enemy-hashes
        #:claims claims
        #:current-frame (sim-world-frame w)
        #:effects effect-hashes
        #:home-x (sim-world-home-x w)
        #:home-y (sim-world-home-y w)
        #:enemy-base-x (sim-world-enemy-x w)
        #:enemy-base-y (sim-world-enemy-y w)))
     (for ([sd (in-list spells)] #:when (eq? (spell-directive-ability sd) 'corrosive-bile))
       (define r (find-unit-by-id w (spell-directive-caster-tag sd)))
       (when (and r (<= (sim-unit-ability-cd r) 0.0))
         (record-tactic! w 'ravager-corrosive-bile)
         (set-sim-unit-ability-cd! r 7.0)
         (set-sim-world-biles!
          w
          (cons (sim-bile 'ally (spell-directive-target-x sd) (spell-directive-target-y sd)
                          36 0.65 60.0)
                (sim-world-biles w)))))
     (define splash-cmds
       (plan-avoid-siege-tank-and-lurker-splash-zones
        ally-hashes enemy-hashes
        #:effects effect-hashes
        #:home-x (sim-world-home-x w)
        #:home-y (sim-world-home-y w)
        #:commit-through-splash? #t
        #:enemy-upgrades (sim-world-enemy-upgrades w)
        #:tactical-disposition 'execute-timing-attack-commit
        #:lanchester-ratio 1.35))
     (define cmd-map (splash-cmd-map splash-cmds))
     (for ([u (in-list allies)] [idx (in-naturals)])
       (define sc (hash-ref cmd-map (sim-unit-id u) #f))
       (cond
         [sc
          (record-tactic! w (hash-ref sc 'role 'avoid-lurker-linear-spine-splash))
          (set-sim-unit-pass-through?! u #t)
          (set-sim-unit-order! u (list 'move (hash-ref sc 'target-x (sim-unit-x u))
                                             (hash-ref sc 'target-y (sim-unit-y u))))]
         [else
          (set-sim-unit-pass-through?! u #f)
          ;; Fan into concave around nearest Lurker once frontline Roaches engage or spines clear
          (define lurk (nearest-enemy u w #:prefer-type 'lurker-burrowed))
          (define roach (nearest-enemy u w #:prefer-type 'roach))
          (define tgt
            (if (eq? (sim-unit-type u) 'ravager)
                (or lurk roach (nearest-enemy u w))
                (or roach lurk (nearest-enemy u w))))
          (when tgt
            ;; Wide lateral offset while approaching from > range so units form a concave instead of single file
            (if (> (unit-edge-dist u tgt) (+ (sim-unit-range u) 0.2))
                (let* ([arc-y (+ 50.0 (* (- (exact->inexact (modulo idx 5)) 2.0) 1.5))]
                       [step-x (min (sim-unit-x tgt) (+ (sim-unit-x u) 2.5))])
                  (if (< (abs (- (sim-unit-y u) arc-y)) 0.8)
                      (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt)))
                      (set-sim-unit-order! u (list 'move step-x arc-y))))
                (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt)))))]))]

    ;; -------------------------------------------------------------------------
    ;; 4. Siege Tank Run-Through Splash & Min-Range Deadzone Dive
    ;; -------------------------------------------------------------------------
    [(siege-tank-run-through-splash-and-deadzone-dive)
     (record-planner! w 'should-commit-through-splash?)
     (record-planner! w 'plan-avoid-siege-tank-and-lurker-splash-zones)
     (define commit?
       (should-commit-through-splash?
        ally-hashes enemy-hashes
        #:tactical-disposition 'execute-timing-attack-commit
        #:lanchester-ratio 1.40))
     (when commit? (record-tactic! w 'commit-through-splash-approved))
     (define splash-cmds
       (plan-avoid-siege-tank-and-lurker-splash-zones
        ally-hashes enemy-hashes
        #:effects effect-hashes
        #:home-x (sim-world-home-x w)
        #:home-y (sim-world-home-y w)
        #:commit-through-splash? commit?
        #:tactical-disposition 'execute-timing-attack-commit
        #:lanchester-ratio 1.40))
     (define cmd-map (splash-cmd-map splash-cmds))
     (apply-splash-avoidance-map! w allies cmd-map #:dive-tank? #t)]

    ;; -------------------------------------------------------------------------
    ;; 5. Colossus Extended Thermal Lance Radial-Depth Split Dive
    ;; -------------------------------------------------------------------------
    [(colossus-thermal-lance-radial-split-dive)
     (record-planner! w 'should-commit-through-splash?)
     (record-planner! w 'plan-avoid-siege-tank-and-lurker-splash-zones)
     (define commit?
       (should-commit-through-splash?
        ally-hashes enemy-hashes
        #:tactical-disposition 'execute-timing-attack-commit
        #:lanchester-ratio 1.45))
     (when commit? (record-tactic! w 'commit-through-splash-approved))
     (define splash-cmds
       (plan-avoid-siege-tank-and-lurker-splash-zones
        ally-hashes enemy-hashes
        #:effects effect-hashes
        #:home-x (sim-world-home-x w)
        #:home-y (sim-world-home-y w)
        #:commit-through-splash? commit?
        #:enemy-upgrades (sim-world-enemy-upgrades w)
        #:tactical-disposition 'execute-timing-attack-commit
        #:lanchester-ratio 1.45))
     (define cmd-map (splash-cmd-map splash-cmds))
     (define live-zealots? (ormap (lambda (e) (eq? (sim-unit-type e) 'zealot)) enemies))
     (for ([u (in-list allies)] [idx (in-naturals)])
       (define sc (hash-ref cmd-map (sim-unit-id u) #f))
       (define col (nearest-enemy u w #:prefer-type 'colossus))
       (define zeal (nearest-enemy u w #:prefer-type 'zealot))
       (define near (nearest-enemy u w))
       (define in-col-range?
         (and col (<= (unit-edge-dist u col) (+ (sim-unit-range u) 0.1))))
       (define in-zeal-range?
         (and zeal (<= (unit-edge-dist u zeal) (+ (sim-unit-range u) 0.1))))
       (define in-any-range?
         (and near (<= (unit-edge-dist u near) (+ (sim-unit-range u) 0.1))))
       (cond
         ;; Roaches pass-through forward to intercept & soak Charge Zealots while Hydras spread & shoot
         [(eq? (sim-unit-type u) 'roach)
          (set-sim-unit-pass-through?! u #t)
          (define tgt (or zeal col near))
          (when tgt (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))]
         ;; Stutter-split vertically during > 0.08s cooldown to evade Thermal Lance, then dive Colossi
         [(and sc (> (sim-unit-cooldown u) 0.08)
               (or (< (abs (- (sim-unit-y u) 50.0)) 3.8)
                   (and (not live-zealots?) col (not in-col-range?))))
          (record-tactic! w (hash-ref sc 'role 'colossus-radial-split-dive))
          (set-sim-unit-pass-through?! u #t)
          (define ty (if (< (sim-unit-y u) 50.0) 45.6 54.4))
          (define tx (if (and (not live-zealots?) col (not in-col-range?))
                         (max (sim-unit-x u) 47.6)
                         (sim-unit-x u)))
          (set-sim-unit-order! u (list 'move tx ty))]
         ;; Burn Charge Zealots within 4.8t when screening Colossi, else focus Colossi directly
         [(and in-zeal-range? zeal (<= (unit-edge-dist u zeal) 4.8))
          (when sc (record-tactic! w (hash-ref sc 'role 'colossus-radial-split-dive)))
          (set-sim-unit-pass-through?! u #t)
          (set-sim-unit-order! u (list 'attack-unit (sim-unit-id zeal)))]
         [in-col-range?
          (when sc (record-tactic! w (hash-ref sc 'role 'colossus-radial-split-dive)))
          (set-sim-unit-pass-through?! u #t)
          (set-sim-unit-order! u (list 'attack-unit (sim-unit-id col)))]
         [(and (not live-zealots?) col sc (> (sim-unit-cooldown u) 0.08))
          (record-tactic! w (hash-ref sc 'role 'colossus-radial-split-dive))
          (set-sim-unit-pass-through?! u #t)
          (set-sim-unit-order! u (list 'move 47.6 (if (< (sim-unit-y u) 50.0) 45.8 54.2)))]
         [in-any-range?
          (when sc (record-tactic! w (hash-ref sc 'role 'colossus-radial-split-dive)))
          (set-sim-unit-pass-through?! u #t)
          (set-sim-unit-order! u (list 'attack-unit (sim-unit-id near)))]
         [else
          (set-sim-unit-pass-through?! u #t)
          (define tgt (or zeal col near))
          (when tgt (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))]))]

    ;; -------------------------------------------------------------------------
    ;; 6. Worker Rush vs TownHall-Adjacent Stacked Enemy Probes (`[NOTE-R4-C]`)
    ;; -------------------------------------------------------------------------
    [(worker-rush-townhall-stack-mineral-drill)
     (record-planner! w 'select-worker-drill-stack-mineral-patch)
     (record-planner! w 'translate-bot-actions->sc2-raw-commands)
     (define patches (sim-world-mineral-patches w))
     (define ths (sim-world-townhalls w))
     (define th0 (if (pair? ths) (car ths) (hasheq 'x (sim-world-home-x w) 'y (sim-world-home-y w))))
     (define thx (fl (hash-ref th0 'x (sim-world-home-x w))))
     (define thy (fl (hash-ref th0 'y (sim-world-home-y w))))
     (define-values (ecx ecy)
       (if (null? enemies)
           (values thx thy)
           (values (/ (for/sum ([e (in-list enemies)]) (sim-unit-x e)) (fl (length enemies)))
                   (/ (for/sum ([e (in-list enemies)]) (sim-unit-y e)) (fl (length enemies))))))
     (define patch
       (select-worker-drill-stack-mineral-patch ecx ecy thx thy patches))
     ;; Exercise real `sc2-protobuf-ws.rkt` [NOTE-R4-C] distance guard on frame 0
     (when (and patch (zero? (sim-world-frame w)))
       (define patch-id (hash-ref patch 'id 901))
       (define sc2-allies
         (for/list ([u (in-list allies)])
           (sc2-unit 1 1 (sim-unit-id u) 104 1
                     (sc2-point3d (sim-unit-x u) (sim-unit-y u) 0.0)
                     0.0 0.375 1.0 1 0 1 0 (sim-unit-hp u) 40.0 0.0 0.0 0.0 0.0 0 0
                     #f #f #f #f #t '() 0 '() 0 0 0.0 0 0 0 0)))
       (define sc2-patches
         (for/list ([p (in-list patches)])
           (sc2-unit 1 3 (hash-ref p 'id 901) 341 0
                     (sc2-point3d (fl (hash-ref p 'x thx)) (fl (hash-ref p 'y thy)) 0.0)
                     0.0 1.0 1.0 1 0 1 0 1500.0 1500.0 0.0 0.0 0.0 0.0 1500 0
                     #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0)))
       (define sc2-enemies
         (for/list ([e (in-list enemies)])
           (sc2-unit 1 4 (sim-unit-id e) 84 2
                     (sc2-point3d (sim-unit-x e) (sim-unit-y e) 0.0)
                     0.0 0.375 1.0 1 0 1 0 (sim-unit-hp e) 20.0 (sim-unit-shield e) 20.0 0.0 0.0 0 0
                     #f #f #f #f #t '() 0 '() 0 0 0.0 0 0 0 0)))
       (define sc2-th
         (sc2-unit 1 1 890 86 1 (sc2-point3d thx thy 0.0)
                   0.0 2.5 1.0 1 0 1 0 1500.0 1500.0 0.0 0.0 0.0 0.0 0 0
                   #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0))
       (define obs
         (sc2-observation 10
                          (sc2-player-common 1 50 0 14 12 0 12 0 0 0 0)
                          (cons sc2-th (append sc2-allies sc2-patches sc2-enemies))
                          '() '() (sc2-point3d thx thy 0.0) '() '() '() '() '() '()))
       (define first-e (and (pair? enemies) (car enemies)))
       (define act (list 'worker-drill-stack-attack
                         (map sim-unit-id allies)
                         patch-id
                         (if first-e (sim-unit-id first-e) 0)
                         ecx ecy))
       (define cmds (translate-bot-actions->sc2-raw-commands (list act) obs))
       ;; Verify [NOTE-R4-C]: must emit `23` (attack), never `3666` (mineral-walk away from TH)!
       (when (and (pair? cmds)
                  (for/and ([c (in-list cmds)])
                    (= (sc2-raw-unit-command-ability-id c) 23)))
         (record-tactic! w 'note-r4-c-suppressed-far-mineral-walk-emitted-attack-23)))
     ;; Worker micro: mineral-drill stack converge, focus-fire lowest-EHP Probe, and brief 1.3t stutter-pull on critical <12 HP Drones
     (define low-target
       (and (pair? enemies)
            (argmin (lambda (e) (+ (unit-ehp e) (* 0.25 (dist2d ecx ecy (sim-unit-x e) (sim-unit-y e)))))
                    enemies)))
     (define-values (acx acy)
       (values (/ (for/sum ([u (in-list allies)]) (sim-unit-x u)) (max 1.0 (fl (length allies))))
               (/ (for/sum ([u (in-list allies)]) (sim-unit-y u)) (max 1.0 (fl (length allies))))))
     (define spread-radius
       (apply max 0.0 (map (lambda (u) (dist2d acx acy (sim-unit-x u) (sim-unit-y u))) allies)))
     (for ([u (in-list allies)])
       (set-sim-unit-drill-stacked?! u #t)
       (define d-e (dist2d (sim-unit-x u) (sim-unit-y u) ecx ecy))
       (cond
         ;; Brief pre-engage drill-stack convergence so all 12 Drones strike simultaneously instead of trickling in 1-by-1
         [(and (> d-e 3.0) (> spread-radius 1.4) (< (sim-world-frame w) 28))
          (record-tactic! w 'worker-drill-stack-converge)
          (set-sim-unit-order! u (list 'move 31.8 32.5))]
         ;; Stutter-pull only critical (< 11 HP) Drone briefly (`cooldown > 0.25`) to drop Probe target focus without halting DPS
         [(and (< (sim-unit-hp u) 11.0) (> (sim-unit-cooldown u) 0.25) (> (length allies) 2))
          (define dx (- (sim-unit-x u) ecx))
          (define dy (- (sim-unit-y u) ecy))
          (define mag (max 1e-4 (sqrt (+ (* dx dx) (* dy dy)))))
          (record-tactic! w 'pull-wounded-worker-drop-aggro)
          (set-sim-unit-order! u (list 'move (+ (sim-unit-x u) (* 1.3 (/ dx mag)))
                                             (+ (sim-unit-y u) (* 1.3 (/ dy mag)))))]
         [low-target
          (record-tactic! w 'worker-focus-fire-lowest-ehp)
          (set-sim-unit-order! u (list 'attack-unit (sim-unit-id low-target)))]))]

    ;; -------------------------------------------------------------------------
    ;; 7. Protoss Natural Wall 1x1 Doorway Zealot Hold-Position vs Ling Flood
    ;; -------------------------------------------------------------------------
    [(protoss-natural-wall-doorway-hold-vs-ling-flood)
     (record-planner! w 'plan-own-wall-integrity-defense)
     (define door (sim-world-wall-door w))
     (define obs
       (hasheq 'base-x (sim-world-home-x w)
               'base-y (sim-world-home-y w)
               'natural-x (+ (sim-world-home-x w) 10.0)
               'natural-y (sim-world-home-y w)
               'enemy-x (sim-world-enemy-x w)
               'enemy-y (sim-world-enemy-y w)
               'door-pos door
               'wall-slots (sim-world-wall-slots w)
               'ally-units ally-hashes
               'ally-buildings ally-bldg-hashes
               'enemy-units enemy-hashes))
     (define cmds (plan-own-wall-integrity-defense obs))
     (define hold-tags
       (for/hasheqv ([c (in-list cmds)] #:when (pair? c))
         (values (second c) c)))
     (for ([u (in-list allies)])
       (define hc (hash-ref hold-tags (sim-unit-id u) #f))
       (cond
         [(and hc (eq? (car hc) 'hold-position))
          (record-tactic! w 'wall-doorway-hold-position)
          (set-sim-unit-order! u (list 'hold-position))]
         [(and hc (eq? (car hc) 'move))
          (record-tactic! w 'wall-doorway-plug-move)
          (set-sim-unit-order! u (list 'move (third hc) (fourth hc)))]
         [else
          (define tgt (nearest-enemy u w))
          (when tgt (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt))))]))]

    ;; -------------------------------------------------------------------------
    ;; 8. Glaive Adept Shade Bypass Around Fortified Bunker+Tank Choke
    ;; -------------------------------------------------------------------------
    [(glaive-adept-shade-bypass-fortified-choke)
     (record-planner! w 'evaluate-build-order-tactical-plan)
     (record-planner! w 'plan-multi-base-adept-harass)
     ;; Consult strategic timing planner (choke fortified vs exposed mineral line)
     (void (evaluate-build-order-tactical-plan
            #:race 'Protoss
            #:enemy-race 'Terran
            #:frame (inexact->exact (round (* 360.0 SC2-FASTER-FPS)))
            #:supply-used 52
            #:unit-counts (hasheq 'adept (length allies))
            #:researched-upgrades '(resonating-glaives)
            #:enemy-unit-counts (hasheq 'siege-tank-sieged 1 'scv 16)
            #:enemy-building-counts (hasheq 'bunker 1)
            #:lanchester-ratio 1.15))
     (define scv-targets (filter (lambda (u) (eq? (sim-unit-type u) 'scv)) enemies))
     (define ready-adepts
       (filter (lambda (u) (and (not (sim-unit-shade-active? u))
                                (<= (sim-unit-ability-cd u) 0.0)
                                (< (sim-unit-x u) 67.0)))
               allies))
     (define ready-hashes (map (lambda (u) (sim-unit->planner-hash u w)) ready-adepts))
     ;; Pass choked front + SCV mineral line (`enemy-targets`) so all Adepts trigger Phase Shift onto `(80.0, 50.0)`
     (define dirs
       (if (null? ready-hashes)
           '()
           (plan-multi-base-adept-harass
            ready-hashes enemy-hashes
            #:home-x (sim-world-home-x w)
            #:home-y (sim-world-home-y w)
            #:enemy-main-x 80.0
            #:enemy-main-y 50.0
            #:enemy-targets '((61.0 . 50.0) (80.0 . 50.0)))))
     (define dir-by-tag
       (for/hasheqv ([d (in-list dirs)])
         (values (harass-directive-unit-tag d) d)))
     (define n-scvs (length scv-targets))
     (for ([u (in-list allies)] [idx (in-naturals)])
       (define d (hash-ref dir-by-tag (sim-unit-id u) #f))
       (cond
         ;; Execute Phase Shift Shade bypass whenever `plan-multi-base-adept-harass` fires `2544`
         [(and d (eq? (harass-directive-ability d) 'adept-phase-shift))
          (record-tactic! w 'adept-phase-shift-choke-bypass)
          (set-sim-unit-shade-active?! u #t)
          (set-sim-unit-shade-frames! u 157) ; 7.0s LotV Phase Shift duration
          (set-sim-unit-shade-x! u (sim-unit-x u))
          (set-sim-unit-shade-y! u (sim-unit-y u))
          (define spread-y (+ 50.0 (* (- (exact->inexact idx) 3.5) 0.6)))
          (set-sim-unit-shade-tx! u (max 78.5 (harass-directive-tx d)))
          (set-sim-unit-shade-ty! u spread-y)
          ;; Step real Adept body back outside 13.0t Tank range while Shade flies past choke!
          (set-sim-unit-order! u (list 'move 44.0 (sim-unit-y u)))]
         [(sim-unit-shade-active? u)
          ;; Hold safely outside Siege Tank `13.0`t arc until Shade finishes teleporting
          (set-sim-unit-order! u (list 'move 44.0 (sim-unit-y u)))]
         ;; Once behind choke (> x=68): distribute Adepts across distinct SCVs so zero 8-way overkill!
         [(and (> n-scvs 0) (> (sim-unit-x u) 68.0))
          (define assigned-scv (list-ref scv-targets (modulo idx n-scvs)))
          (record-tactic! w 'adept-focus-mineral-worker)
          (set-sim-unit-order! u (list 'attack-unit (sim-unit-id assigned-scv)))]
         [(and (not (sim-unit-shade-active? u)) (<= (sim-unit-ability-cd u) 0.0))
          ;; Stage at `x=48.2` (`12.8`t from `61.0`, outside Tank `61.5 - 13.0 = 48.5`!) to fire Shade safely
          (set-sim-unit-order! u (list 'move 48.2 (sim-unit-y u)))]
         [else
          (set-sim-unit-order! u (list 'move 44.0 (sim-unit-y u)))]))]

    ;; -------------------------------------------------------------------------
    ;; 9. Mixed-Attribute Target Focus: Immortal / Colossus / Archon
    ;; -------------------------------------------------------------------------
    [(mixed-attribute-target-focus-immortal-colossus-archon)
     (for ([u (in-list allies)])
       (define tgt
         (select-best-exact-focus-target
          u enemies w
          #:colossus-splash? (eq? (sim-unit-type u) 'colossus)))
       (when tgt
         (record-tactic! w 'mixed-attribute-exact-focus)
         (set-sim-unit-order! u (list 'attack-unit (sim-unit-id tgt)))))]

    ;; -------------------------------------------------------------------------
    ;; 10–14. LotV Spellcaster Attribute/Size Matrix (`pro-spellcaster-micro`)
    ;; -------------------------------------------------------------------------
    [(ghost-emp-shield-psionic-and-bio-snipe)
     (define enemy-u-hashes (map (lambda (e) (sim-unit->planner-hash e w))
                                 (filter (lambda (e) (not (sim-unit-building? e))) enemies)))
     (define enemy-b-hashes (map (lambda (e) (sim-unit->planner-hash e w))
                                 (filter sim-unit-building? enemies)))
     (define ally-b-hashes (map (lambda (b) (sim-unit->planner-hash b w)) ally-bldgs))
     (apply-spellcaster-scenario-micro!
      w allies ally-hashes enemies enemy-u-hashes ally-b-hashes enemy-b-hashes
      #:standoff-casters? #f #:kite-ranged? #t)]

    [(raven-interference-matrix-and-aam-vs-armored-mech
      viper-abduct-blinding-cloud-and-ht-feedback
      infestor-fungal-vs-light-bio-and-neural-vs-massive-mech
      sentry-guardian-shield-and-queen-transfuse-scv-repair)
     (define enemy-u-hashes (map (lambda (e) (sim-unit->planner-hash e w))
                                 (filter (lambda (e) (not (sim-unit-building? e))) enemies)))
     (define enemy-b-hashes (map (lambda (e) (sim-unit->planner-hash e w))
                                 (filter sim-unit-building? enemies)))
     (define ally-b-hashes (map (lambda (b) (sim-unit->planner-hash b w)) ally-bldgs))
     (apply-spellcaster-scenario-micro!
      w allies ally-hashes enemies enemy-u-hashes ally-b-hashes enemy-b-hashes
      #:standoff-casters? (not (eq? sid 'sentry-guardian-shield-and-queen-transfuse-scv-repair))
      #:kite-ranged? (not (not (memq sid '(raven-interference-matrix-and-aam-vs-armored-mech
                                            infestor-fungal-vs-light-bio-and-neural-vs-massive-mech)))))]

    ;; -------------------------------------------------------------------------
    ;; 15–19. Worker Rush Matrix (`[NOTE-R4-C]` Drill / Repair / Kite / Snipe)
    ;; -------------------------------------------------------------------------
    [(worker-rush-terran-scv-repair-pocket-vs-12-worker)
     (apply-worker-rush-tactics! w allies enemies #:pull-hp-thresh 15.0 #:scv-repair? #t)]

    [(worker-rush-protoss-probe-shield-regen-kite-vs-12-worker)
     (apply-worker-rush-tactics! w allies enemies #:pull-hp-thresh 8.0 #:pull-shield-thresh 4.5)]

    [(worker-rush-townhall-focus-mineral-stack-breaker)
     (apply-worker-rush-tactics! w allies enemies #:pull-hp-thresh 11.0)]

    [(worker-rush-mixed-workers-plus-early-zealot-or-marine)
     (apply-worker-rush-tactics! w allies enemies #:pull-hp-thresh 13.0 #:scv-repair? #t #:kite-ranged? #t)]

    [(worker-rush-proxy-cannon-or-bunker-builder-snipe)
     (apply-worker-rush-tactics! w allies enemies #:pull-hp-thresh 8.0 #:pull-shield-thresh 4.0 #:proxy-snipe? #t)]

    [else
     (plan-default-ai! w)]))

;; -----------------------------------------------------------------------------
;; 7. Scenario Definitions (`8` Canonical Asymmetric LotV Scenarios)
;; -----------------------------------------------------------------------------

(define (grid-units start-id team type xs ys #:drill-stacked? [drill? #f])
  (define-values (rev _next-id)
    (for*/fold ([acc '()] [id start-id])
               ([x (in-list xs)]
                [y (in-list ys)])
      (values (cons (make-sim-unit id team type x y #:drill-stacked? drill?) acc)
              (+ id 1))))
  (reverse rev))

(define (setup-baneling-screen mode)
  ;; 6 Banelings + 14 Zerglings vs 3 front Marauders + 12 rear Marines (2 distinct light clumps)
  (define allies
    (append (grid-units 101 'ally 'baneling '(40.0 40.8) '(49.0 50.0 51.0))
            (grid-units 110 'ally 'zergling '(41.0 41.8) '(47.0 48.0 49.0 50.0 51.0 52.0 53.0))))
  (define enemies
    (append (grid-units 201 'enemy 'marauder '(45.2) '(48.6 50.0 51.4))
            (grid-units 210 'enemy 'marine '(49.2 49.8) '(46.8 47.4 48.0))
            (grid-units 220 'enemy 'marine '(49.2 49.8) '(52.0 52.6 53.2))))
  (sim-world 'baneling-move-past-marauder-screen mode 0
             (append allies enemies)
             '() '() '() '() '() '() #f '() '() '() #f #f (hasheq) (hasheq)
             30.0 50.0 55.0 50.0))

(define (setup-disruptor-nova mode)
  ;; 9 Stalkers + 3 Adepts vs 2 Disruptors + 6 Stalkers
  (define allies
    (append (grid-units 101 'ally 'stalker '(39.0 40.2 41.4) '(49.0 50.0 51.0))
            (grid-units 120 'ally 'adept '(41.8) '(49.2 50.0 50.8))))
  (define enemies
    (append (grid-units 201 'enemy 'disruptor '(54.0) '(48.5 51.5))
            (grid-units 210 'enemy 'stalker '(51.5 52.5) '(47.5 50.0 52.5))))
  (sim-world 'disruptor-nova-catchable-range-and-cooldown-dive mode 0
             (append allies enemies)
             '() '() '() '() '() '() #f '() '(blink) '()
             (make-disruptor-tactical-tracker) #f (hasheq) (hasheq)
             32.0 50.0 56.0 50.0))

(define (setup-lurker-spines mode)
  ;; 10 Roaches + 5 Ravagers vs 3 Burrowed Lurkers (Seismic Spines) + 4 Roaches guarding choke mouth
  (define allies
    (append (grid-units 101 'ally 'roach '(40.5 41.7) '(48.4 49.2 50.0 50.8 51.6))
            (grid-units 120 'ally 'ravager '(38.8) '(48.4 49.2 50.0 50.8 51.6))))
  (define enemies
    (append (for/list ([i (in-range 3)]
                       [x (in-list '(53.2 54.0 54.0))]
                       [y (in-list '(50.0 49.0 51.0))])
              (define u (make-sim-unit (+ 201 i) 'enemy 'lurker-burrowed x y))
              (set-sim-unit-range! u 10.0)
              u)
            (grid-units 210 'enemy 'roach '(49.8) '(49.1 49.7 50.3 50.9))))
  (define walls
    (list (sim-wall-box 46.5 51.1 51.5 70.0 #f)
          (sim-wall-box 46.5 30.0 51.5 48.9 #f)))
  (sim-world 'lurker-linear-spine-step-out-and-bile-concave mode 0
             (append allies enemies)
             '() '() '() walls '() '() #f '() '() '(seismic-spines)
             #f (make-spell-claims) (hasheq) (hasheq)
             32.0 50.0 56.0 50.0))

(define (setup-siege-tank-dive mode)
  ;; 16 Speedlings + 5 Roaches vs 3 Sieged Tanks + 6 Marines across open approach
  (define allies
    (append (grid-units 101 'ally 'zergling '(39.0 40.0 41.0 42.0) '(48.8 49.6 50.4 51.2))
            (grid-units 130 'ally 'roach '(37.5) '(48.4 49.2 50.0 50.8 51.6))))
  (define enemies
    (append (grid-units 201 'enemy 'siege-tank-sieged '(55.0) '(47.5 50.0 52.5))
            (grid-units 210 'enemy 'marine '(51.5 52.5) '(47.5 50.0 52.5))))
  (sim-world 'siege-tank-run-through-splash-and-deadzone-dive mode 0
             (append allies enemies)
             '() '() '() '() '() '() #f '() '(metabolic-boost) '()
             #f #f (hasheq) (hasheq)
             32.0 50.0 56.0 50.0))

(define (setup-colossus-split mode)
  ;; 12 Hydralisks + 6 Roaches vs 2 ETL Colossi + 5 Charge Zealots across 9.0t ETL approach
  (define allies
    (append (grid-units 101 'ally 'hydralisk '(43.8 44.5 45.2) '(48.8 49.6 50.4 51.2))
            (grid-units 130 'ally 'roach '(46.0) '(47.5 48.5 49.5 50.5 51.5 52.5))))
  (define enemies
    (append (grid-units 201 'enemy 'colossus '(52.8) '(48.5 51.5))
            (grid-units 210 'enemy 'zealot '(48.6) '(47.2 48.6 50.0 51.4 52.8))))
  (sim-world 'colossus-thermal-lance-radial-split-dive mode 0
             (append allies enemies)
             '() '() '() '() '() '() #f '() '(grooved-spines) '(extended-thermal-lance)
             #f #f (hasheq) (hasheq)
             32.0 50.0 56.0 50.0))

(define (setup-worker-drill mode)
  ;; 12 Drones vs 12 stacked enemy Probes <= 4.0t from TownHall (`[NOTE-R4-C]`)
  (define th (make-sim-unit 890 'ally 'hatchery 32.5 32.5))
  (define patches
    (for/list ([i (in-range 8)]
               [dy (in-list '(-4.2 -3.0 -1.8 -0.6 0.6 1.8 3.0 4.2))])
      (hasheq 'id (+ 901 i)
              'x (- 26.5 (* 0.08 (* dy dy)))
              'y (+ 32.5 dy)
              'mineral-contents 1500)))
  (define allies
    (grid-units 101 'ally 'drone '(27.8 29.0) '(29.5 30.7 31.9 33.1 34.3 35.5) #:drill-stacked? #f))
  ;; Enemy 12 Probes pre-stacked at `(35.5, 32.5)` (`3.0t <= 4.0t` from TownHall, `~9.0t` from minerals)
  (define enemies
    (for/list ([i (in-range 12)])
      (make-sim-unit (+ 201 i) 'enemy 'probe
                     (+ 35.5 (* 0.08 (cos (* 0.52 i))))
                     (+ 32.5 (* 0.08 (sin (* 0.52 i))))
                     #:drill-stacked? #t)))
  (sim-world 'worker-rush-townhall-stack-mineral-drill mode 0
             (append (list th) allies enemies)
             '() '() '() '() patches (list (hasheq 'id 890 'x 32.5 'y 32.5)) #f '() '() '()
             #f #f (hasheq) (hasheq)
             32.5 32.5 55.0 55.0))

(define (setup-natural-wall mode)
  ;; 1 Zealot + 2 Stalkers at 2x 3x3 + 1x1 natural wall vs 16 Zerglings
  (define gw (make-sim-unit 801 'ally 'gateway 47.5 43.5))
  (define cy (make-sim-unit 802 'ally 'cybernetics-core 47.5 47.5))
  (define zeal (make-sim-unit 101 'ally 'zealot 47.5 45.5))
  (define s1 (make-sim-unit 102 'ally 'stalker 45.2 45.25))
  (define s2 (make-sim-unit 103 'ally 'stalker 45.2 45.75))
  (define lings (grid-units 201 'enemy 'zergling '(53.0 54.0 55.0 56.0) '(43.5 44.8 46.2 47.5)))
  ;; Natural wall geometry: 1.0t 1x1 doorway (strictly 1 Ling wide against Hold-Pos Zealot) vs unsealed
  (define walls
    (list (sim-wall-box 47.0 20.0 48.31 45.0 #f)
          (sim-wall-box 47.0 46.0 48.31 70.0 #f)
          (sim-wall-box 47.0 45.0 48.31 46.0 #t)))
  (sim-world 'protoss-natural-wall-doorway-hold-vs-ling-flood mode 0
             (append (list gw cy zeal s1 s2) lings)
             '() '() '() walls '() '()
             '(47.5 . 45.5) '((47.5 . 45.5))
             '() '() #f #f (hasheq) (hasheq)
             32.0 45.5 60.0 45.5))

(define (setup-adept-bypass mode)
  ;; 8 Glaive Adepts vs 1 Bunker (4 Stimmed Marines) + 1 Siege Tank choke + 16 SCVs in mineral line behind
  (define allies (grid-units 101 'ally 'adept '(42.0 43.5) '(49.0 49.7 50.3 51.0)))
  (define bunker (make-sim-unit 201 'enemy 'bunker 58.0 50.0))
  (define tank (make-sim-unit 202 'enemy 'siege-tank-sieged 61.5 50.0))
  (define scvs (grid-units 210 'enemy 'scv '(78.5 79.6 80.7 81.8) '(47.8 49.2 50.8 52.2)))
  ;; Narrow fortified natural wall choke: Bunker plugs choke entrance under Sieged Tank cover!
  (define walls
    (list (sim-wall-box 56.0 51.2 64.0 75.0 #f)
          (sim-wall-box 56.0 25.0 64.0 48.8 #f)))
  (sim-world 'glaive-adept-shade-bypass-fortified-choke mode 0
             (append allies (list bunker tank) scvs)
             '() '() '() walls '() '() #f '() '(resonating-glaives) '()
             #f #f (hasheq) (hasheq)
             30.0 50.0 80.0 50.0))

(define (make-scenario-world sid mode units
                             #:patches [patches '()]
                             #:townhalls [townhalls '()]
                             #:claims [claims #f]
                             #:home-x [hx 25.0] #:home-y [hy 50.0]
                             #:enemy-x [ex 45.0] #:enemy-y [ey 50.0])
  (sim-world sid mode 0 units
             '() '() '() '()
             patches townhalls #f '()
             '() '() #f claims
             (hasheq) (hasheq)
             hx hy ex ey))

(define (setup-mixed-attribute-focus mode)
  ;; 2 Immortals + 2 Colossi + 2 Archons vs 8 Zerglings + 2 Immortals (Barrier) + 12 Marines + 5 Marauders + 4 Stalkers
  (define allies
    (list (make-sim-unit 101 'ally 'immortal 31.5 48.0)
          (make-sim-unit 102 'ally 'immortal 31.5 52.0)
          (make-sim-unit 103 'ally 'colossus 31.0 49.0)
          (make-sim-unit 104 'ally 'colossus 31.0 51.0)
          (make-sim-unit 105 'ally 'archon   32.5 48.5)
          (make-sim-unit 106 'ally 'archon   32.5 51.5)))
  (define enemies
    (append
     (for/list ([i (in-range 8)])
       (make-sim-unit (+ 201 i) 'enemy 'zergling 37.5 (+ 46.5 (* 1.0 i))))
     (list (make-sim-unit 211 'enemy 'immortal 38.0 49.0)
           (make-sim-unit 212 'enemy 'immortal 38.0 51.0))
     (for/list ([i (in-range 12)])
       (make-sim-unit (+ 221 i) 'enemy 'marine (+ 39.5 (* 0.45 (quotient i 4))) (+ 47.8 (* 1.3 (modulo i 4)))))
     (for/list ([i (in-range 5)])
       (make-sim-unit (+ 241 i) 'enemy 'marauder 39.2 (+ 47.0 (* 1.5 i))))
     (for/list ([i (in-range 4)])
       (make-sim-unit (+ 251 i) 'enemy 'stalker 40.5 (+ 47.2 (* 1.8 i))))))
  (make-scenario-world 'mixed-attribute-target-focus-immortal-colossus-archon mode (append allies enemies)))

(define (setup-ghost-emp-snipe mode)
  ;; 4 Ghosts + 4 Marauders + 4 Marines vs 2 High Templars (125en) + 2 Archons + 1 Ultralisk + 2 Stalkers
  (define allies
    (append
     (for/list ([i (in-range 4)])
       (make-sim-unit (+ 101 i) 'ally 'ghost 30.5 (+ 47.0 (* 2.0 i)) #:energy 125.0))
     (for/list ([i (in-range 4)])
       (make-sim-unit (+ 111 i) 'ally 'marauder 31.8 (+ 47.0 (* 2.0 i))))
     (for/list ([i (in-range 4)])
       (make-sim-unit (+ 121 i) 'ally 'marine 31.5 (+ 46.5 (* 2.2 i))))))
  (define enemies
    (list (make-sim-unit 201 'enemy 'high-templar 38.5 49.0 #:energy 125.0)
          (make-sim-unit 202 'enemy 'high-templar 38.5 51.0 #:energy 125.0)
          (make-sim-unit 203 'enemy 'archon       37.8 48.0)
          (make-sim-unit 204 'enemy 'archon       37.8 52.0)
          (make-sim-unit 205 'enemy 'ultralisk    37.0 50.0)
          (make-sim-unit 207 'enemy 'stalker      38.0 47.0)
          (make-sim-unit 208 'enemy 'stalker      38.0 53.0)))
  (make-scenario-world 'ghost-emp-shield-psionic-and-bio-snipe mode (append allies enemies)
                       #:claims (make-spell-claims)))

(define (setup-raven-matrix-aam mode)
  ;; 2 Ravens + 10 Marines + 4 Marauders vs 2 Sieged Tanks + 1 Thor + 1 Ultralisk
  (define allies
    (append
     (list (make-sim-unit 101 'ally 'raven 31.0 48.0 #:energy 150.0)
           (make-sim-unit 102 'ally 'raven 31.0 52.0 #:energy 150.0))
     (for/list ([i (in-range 10)])
       (make-sim-unit (+ 111 i) 'ally 'marine (+ 32.0 (* 0.5 (quotient i 5))) (+ 46.5 (* 1.6 (modulo i 5)))))
     (for/list ([i (in-range 4)])
       (make-sim-unit (+ 125 i) 'ally 'marauder 32.6 (+ 47.0 (* 2.0 i))))))
  (define enemies
    (list (make-sim-unit 201 'enemy 'siege-tank-sieged 39.5 48.5)
          (make-sim-unit 202 'enemy 'siege-tank-sieged 39.5 51.5)
          (make-sim-unit 203 'enemy 'thor              38.5 50.0)
          (make-sim-unit 204 'enemy 'ultralisk         38.0 52.8)))
  (make-scenario-world 'raven-interference-matrix-and-aam-vs-armored-mech mode (append allies enemies)
                       #:claims (make-spell-claims)))

(define (setup-viper-ht-feedback mode)
  ;; 2 Vipers + 2 High Templars + 8 Hydralisks + 4 Zealots vs 2 Sieged Tanks + 2 HTs (175en) + 5 Marauders + 1 Ultralisk
  (define allies
    (append
     (list (make-sim-unit 101 'ally 'viper        33.0 48.5 #:energy 175.0)
           (make-sim-unit 102 'ally 'viper        33.0 51.5 #:energy 175.0)
           (make-sim-unit 103 'ally 'high-templar 32.5 45.0 #:energy 125.0)
           (make-sim-unit 104 'ally 'high-templar 32.5 55.0 #:energy 125.0))
     (for/list ([i (in-range 8)])
       (make-sim-unit (+ 111 i) 'ally 'hydralisk 33.8 (+ 46.2 (* 1.1 i))))
     (for/list ([i (in-range 4)])
       (make-sim-unit (+ 121 i) 'ally 'zealot 34.4 (+ 47.0 (* 2.0 i))))))
  (define enemies
    (append
     (list (make-sim-unit 201 'enemy 'siege-tank-sieged 40.5 49.0)
           (make-sim-unit 202 'enemy 'siege-tank-sieged 40.5 51.0)
           (make-sim-unit 203 'enemy 'high-templar      40.5 45.0 #:energy 175.0)
           (make-sim-unit 204 'enemy 'high-templar      40.5 55.0 #:energy 175.0)
           (make-sim-unit 205 'enemy 'ultralisk         38.5 50.0))
     (for/list ([i (in-range 5)])
       (make-sim-unit (+ 211 i) 'enemy 'marauder 39.2 (+ 47.0 (* 1.5 i))))))
  (make-scenario-world 'viper-abduct-blinding-cloud-and-ht-feedback mode (append allies enemies)
                       #:claims (make-spell-claims)))

(define (setup-infestor-fungal-neural mode)
  ;; 2 Infestors + 14 Zerglings + 4 Hydralisks vs 14 Marines + 2 Thors + 1 Ultralisk
  (define allies
    (append
     (list (make-sim-unit 101 'ally 'infestor 31.0 48.5 #:energy 175.0)
           (make-sim-unit 102 'ally 'infestor 31.0 51.5 #:energy 175.0))
     (for/list ([i (in-range 14)])
       (make-sim-unit (+ 111 i) 'ally 'zergling (+ 32.5 (* 0.5 (quotient i 7))) (+ 46.5 (* 1.1 (modulo i 7)))))
     (for/list ([i (in-range 4)])
       (make-sim-unit (+ 131 i) 'ally 'hydralisk 31.5 (+ 47.0 (* 2.0 i))))))
  (define enemies
    (append
     (for/list ([i (in-range 14)])
       (make-sim-unit (+ 201 i) 'enemy 'marine (+ 38.5 (* 0.5 (quotient i 7))) (+ 46.8 (* 1.0 (modulo i 7)))))
     (list (make-sim-unit 221 'enemy 'thor      38.0 48.5)
           (make-sim-unit 222 'enemy 'thor      38.0 51.5)
           (make-sim-unit 223 'enemy 'ultralisk 37.5 50.0))))
  (make-scenario-world 'infestor-fungal-vs-light-bio-and-neural-vs-massive-mech mode (append allies enemies)
                       #:claims (make-spell-claims)))

(define (setup-sentry-queen-scv-defense mode)
  ;; 1 Sentry + 2 Zealots + 2 Stalkers + 1 Queen + 1 injured Roach + 1 injured Tank + 2 SCVs vs 20 Marines
  (define allies
    (list (make-sim-unit 101 'ally 'sentry     32.0 50.0 #:energy 100.0)
          (make-sim-unit 102 'ally 'zealot     33.0 48.5)
          (make-sim-unit 103 'ally 'zealot     33.0 51.5)
          (make-sim-unit 104 'ally 'stalker    31.5 48.5)
          (make-sim-unit 105 'ally 'stalker    31.5 51.5)
          (make-sim-unit 106 'ally 'queen      31.2 50.0 #:energy 100.0)
          (make-sim-unit 107 'ally 'roach      32.5 50.0 #:hp 55.0)
          (make-sim-unit 108 'ally 'siege-tank 30.8 50.0 #:hp 65.0)
          (make-sim-unit 109 'ally 'scv        30.5 49.0)
          (make-sim-unit 110 'ally 'scv        30.5 51.0)))
  (define enemies
    (for/list ([i (in-range 20)])
      (make-sim-unit (+ 201 i) 'enemy 'marine (+ 39.0 (* 0.45 (quotient i 5))) (+ 46.5 (* 1.6 (modulo i 5))))))
  (make-scenario-world 'sentry-guardian-shield-and-queen-transfuse-scv-repair mode (append allies enemies)
                       #:claims (make-spell-claims)))

(define (standard-worker-patches)
  (for/list ([i (in-range 8)]
             [dy (in-list '(-4.2 -3.0 -1.8 -0.6 0.6 1.8 3.0 4.2))])
    (hasheq 'id (+ 901 i) 'x (- 26.5 (* 0.08 (* dy dy))) 'y (+ 32.5 dy) 'mineral-contents 1500)))

(define (setup-worker-terran-repair-pocket mode)
  (define th (make-sim-unit 890 'ally 'command-center 32.5 32.5))
  (define allies (grid-units 101 'ally 'scv '(27.8 29.0) '(29.5 30.7 31.9 33.1 34.3 35.5)))
  (define enemies
    (for/list ([i (in-range 12)])
      (make-sim-unit (+ 201 i) 'enemy 'probe
                     (+ 35.5 (* 0.08 (cos (* 0.52 i))))
                     (+ 32.5 (* 0.08 (sin (* 0.52 i))))
                     #:drill-stacked? #t)))
  (make-scenario-world 'worker-rush-terran-scv-repair-pocket-vs-12-worker mode (append (list th) allies enemies)
                       #:patches (standard-worker-patches) #:townhalls (list (hasheq 'id 890 'x 32.5 'y 32.5))
                       #:home-x 32.5 #:home-y 32.5 #:enemy-x 55.0 #:enemy-y 55.0))

(define (setup-worker-protoss-shield-kite mode)
  (define th (make-sim-unit 890 'ally 'nexus 32.5 32.5))
  (define allies (grid-units 101 'ally 'probe '(27.8 29.0) '(29.5 30.7 31.9 33.1 34.3 35.5)))
  (define enemies
    (for/list ([i (in-range 12)])
      (make-sim-unit (+ 201 i) 'enemy 'drone
                     (+ 35.5 (* 0.08 (cos (* 0.52 i))))
                     (+ 32.5 (* 0.08 (sin (* 0.52 i))))
                     #:drill-stacked? #t)))
  (make-scenario-world 'worker-rush-protoss-probe-shield-regen-kite-vs-12-worker mode (append (list th) allies enemies)
                       #:patches (standard-worker-patches) #:townhalls (list (hasheq 'id 890 'x 32.5 'y 32.5))
                       #:home-x 32.5 #:home-y 32.5 #:enemy-x 55.0 #:enemy-y 55.0))

(define (setup-worker-townhall-stack-breaker mode)
  ;; Tight `12` mineral-walk stack (`60 dmg/frame`) <= 4.0t from TownHall (`#222`)
  (define th (make-sim-unit 890 'ally 'hatchery 32.5 32.5 #:hp 900.0))
  (define allies (grid-units 101 'ally 'drone '(27.5 28.8) '(29.5 30.7 31.9 33.1 34.3 35.5)))
  (define enemies
    (for/list ([i (in-range 12)])
      (make-sim-unit (+ 201 i) 'enemy 'probe
                     (+ 35.2 (* 0.07 (cos (* 0.52 i))))
                     (+ 32.5 (* 0.07 (sin (* 0.52 i))))
                     #:drill-stacked? #t)))
  (define w
    (make-scenario-world 'worker-rush-townhall-focus-mineral-stack-breaker mode (append (list th) allies enemies)
                         #:patches (standard-worker-patches) #:townhalls (list (hasheq 'id 890 'x 32.5 'y 32.5))
                         #:home-x 32.5 #:home-y 32.5 #:enemy-x 55.0 #:enemy-y 55.0))
  (set-sim-world-fx-attack-buildings?! (get-world-fx w) #t)
  w)

(define (setup-worker-mixed-early-unit mode)
  (define th (make-sim-unit 890 'ally 'command-center 32.5 32.5))
  (define allies
    (append
     (grid-units 101 'ally 'scv '(27.8 29.0) '(29.5 30.7 31.9 33.1 34.3 35.5))
     (list (make-sim-unit 150 'ally 'marine 30.5 32.5))))
  (define enemies
    (append
     (for/list ([i (in-range 11)])
       (make-sim-unit (+ 201 i) 'enemy 'probe
                      (+ 35.5 (* 0.08 (cos (* 0.57 i))))
                      (+ 32.5 (* 0.08 (sin (* 0.57 i))))
                      #:drill-stacked? #t))
     (list (make-sim-unit 250 'enemy 'zealot 34.8 32.5))))
  (make-scenario-world 'worker-rush-mixed-workers-plus-early-zealot-or-marine mode (append (list th) allies enemies)
                       #:patches (standard-worker-patches) #:townhalls (list (hasheq 'id 890 'x 32.5 'y 32.5))
                       #:home-x 32.5 #:home-y 32.5 #:enemy-x 55.0 #:enemy-y 55.0))

(define (setup-worker-proxy-builder-snipe mode)
  (define th (make-sim-unit 890 'ally 'nexus 32.5 32.5))
  (define allies (grid-units 101 'ally 'probe '(27.8 29.0) '(29.5 30.7 31.9 33.1 34.3 35.5)))
  (define enemies
    (append
     (list (make-sim-unit 281 'enemy 'photon-cannon 35.5 33.0 #:hp 45.0  #:shield 45.0 #:build-progress 0.72)
           (make-sim-unit 282 'enemy 'probe         36.2 32.8)
           (make-sim-unit 280 'enemy 'pylon         36.5 34.0 #:hp 120.0 #:shield 120.0))
     (for/list ([i (in-range 8)])
       (make-sim-unit (+ 201 i) 'enemy 'probe
                      (+ 35.0 (* 0.08 (cos (* 0.70 i))))
                      (+ 32.0 (* 0.08 (sin (* 0.70 i))))
                      #:drill-stacked? #t))))
  (make-scenario-world 'worker-rush-proxy-cannon-or-bunker-builder-snipe mode (append (list th) allies enemies)
                       #:patches (standard-worker-patches) #:townhalls (list (hasheq 'id 890 'x 32.5 'y 32.5))
                       #:home-x 32.5 #:home-y 32.5 #:enemy-x 55.0 #:enemy-y 55.0))

(define LOTV-UNIT-TESTER-SCENARIOS
  (list
   (lotv-scenario-spec
    'baneling-move-past-marauder-screen
    "Baneling Move-Past Marauder Screen"
    "6 Banelings + 14 Zerglings vs 3 front Marauders + 12 rear Marines"
    'standard 650 'enemy 'ally
    '(plan-baneling-move-past-and-light-clump-detonate)
    setup-baneling-screen)
   (lotv-scenario-spec
    'disruptor-nova-catchable-range-and-cooldown-dive
    "Disruptor Nova Catchable-Range Split & Cooldown Dive"
    "9 Stalkers + 3 Adepts vs 2 Disruptors + 6 Stalkers"
    'standard 900 'enemy 'ally
    '(disruptor-nova-catchable-range plan-anti-nova-scatter evaluate-disruptor-snipe-and-cooldowns)
    setup-disruptor-nova)
   (lotv-scenario-spec
    'lurker-linear-spine-step-out-and-bile-concave
    "Lurker Linear Spine Step-Out + Ravager Bile & Concave"
    "10 Roaches + 5 Ravagers vs 3 Burrowed Lurkers + 4 Roaches in a choke"
    'standard 750 'enemy 'ally
    '(step-pro-spellcaster-micro! plan-avoid-siege-tank-and-lurker-splash-zones)
    setup-lurker-spines)
   (lotv-scenario-spec
    'siege-tank-run-through-splash-and-deadzone-dive
    "Siege Tank Run-Through Splash & Min-Range Deadzone Dive"
    "16 Speedlings + 5 Roaches vs 3 Sieged Tanks + 6 Marines across open approach"
    'standard 700 'enemy 'ally
    '(should-commit-through-splash? plan-avoid-siege-tank-and-lurker-splash-zones)
    setup-siege-tank-dive)
   (lotv-scenario-spec
    'colossus-thermal-lance-radial-split-dive
    "Colossus Extended Thermal Lance Radial-Depth Split Dive"
    "12 Hydralisks + 6 Roaches vs 2 ETL Colossi + 5 Charge Zealots"
    'standard 700 'enemy 'ally
    '(should-commit-through-splash? plan-avoid-siege-tank-and-lurker-splash-zones)
    setup-colossus-split)
   (lotv-scenario-spec
    'worker-rush-townhall-stack-mineral-drill
    "Worker Rush vs TownHall-Adjacent Stacked Enemy Probes ([NOTE-R4-C])"
    "12 Drones vs 12 stacked enemy Probes <= 4.0t from TownHall"
    'standard 650 'enemy 'ally
    '(select-worker-drill-stack-mineral-patch translate-bot-actions->sc2-raw-commands)
    setup-worker-drill)
   (lotv-scenario-spec
    'protoss-natural-wall-doorway-hold-vs-ling-flood
    "Protoss Natural Wall 1x1 Doorway Hold-Position vs Ling Flood"
    "1 Zealot + 2 Stalkers at 2x 3x3 + 1x1 natural wall vs 16 Zerglings"
    'standard 750 'enemy 'ally
    '(plan-own-wall-integrity-defense)
    setup-natural-wall)
   (lotv-scenario-spec
    'glaive-adept-shade-bypass-fortified-choke
    "Glaive Adept Shade Bypass Around Fortified Bunker+Tank Choke"
    "8 Glaive Adepts vs 1 Bunker (4 Marines) + 1 Siege Tank choke + 16 SCVs in mineral line behind"
    'adept-mineral-bypass 900 'enemy 'ally
    '(evaluate-build-order-tactical-plan plan-multi-base-adept-harass)
    setup-adept-bypass)
   ;; 9–14: Attribute / Size / Spell Matrix
   (lotv-scenario-spec
    'mixed-attribute-target-focus-immortal-colossus-archon
    "Mixed-Attribute Exact Focus: Immortal vs Armored, Colossus vs Light, Archon vs Bio"
    "2 Immortals + 2 Colossi + 2 Archons vs 8 Lings + 2 Barrier Immortals + 12 Marines + 5 Marauders + 4 Stalkers"
    'standard 750 'enemy 'ally
    '(compute-exact-hit-damage-vs-target unit-attribute-mask unit-collision-radius)
    setup-mixed-attribute-focus)
   (lotv-scenario-spec
    'ghost-emp-shield-psionic-and-bio-snipe
    "Ghost EMP (-100 Shield/-100 Energy) & Steady Targeting ('biological only)"
    "4 Ghosts + 5 Marines vs 2 High Templars (125en) + 2 Archons + 2 Ultralisks + 2 Stalkers"
    'standard 750 'enemy 'ally
    '(step-pro-spellcaster-micro! spell-valid-for-target-attrs?)
    setup-ghost-emp-snipe)
   (lotv-scenario-spec
    'raven-interference-matrix-and-aam-vs-armored-mech
    "Raven Interference Matrix ('mechanical/'psionic & not 'frenzied) + AAM (-2 Armor)"
    "2 Ravens + 12 Marines vs 2 Sieged Tanks + 1 Thor + 1 Ultralisk"
    'standard 750 'enemy 'ally
    '(step-pro-spellcaster-micro! spell-valid-for-target-attrs?)
    setup-raven-matrix-aam)
   (lotv-scenario-spec
    'viper-abduct-blinding-cloud-and-ht-feedback
    "Viper Abduct (not 'frenzied) + Blinding Cloud + HT Feedback/Storm"
    "2 Vipers + 2 HTs + 6 Hydras + 3 Zealots vs 2 Sieged Tanks + 2 HTs + 6 Marauders + 1 Ultralisk"
    'standard 750 'enemy 'ally
    '(step-pro-spellcaster-micro! spell-valid-for-target-attrs?)
    setup-viper-ht-feedback)
   (lotv-scenario-spec
    'infestor-fungal-vs-light-bio-and-neural-vs-massive-mech
    "Infestor Fungal vs Bio Ball + Neural Parasite on Massive Mech (Rejects 'frenzied Ultra)"
    "2 Infestors + 14 Zerglings + 4 Hydralisks vs 14 Marines + 2 Thors + 1 Ultralisk"
    'standard 750 'enemy 'ally
    '(step-pro-spellcaster-micro! spell-valid-for-target-attrs?)
    setup-infestor-fungal-neural)
   (lotv-scenario-spec
    'sentry-guardian-shield-and-queen-transfuse-scv-repair
    "Sentry Guardian Shield (-2 Ranged) + Queen Transfuse ('bio) + SCV Repair ('mech)"
    "1 Sentry + 2 Zealots + 2 Stalkers + 1 Queen + Injured Roach/Tank + 2 SCVs vs 15 Marines"
    'standard 750 'enemy 'ally
    '(step-pro-spellcaster-micro! spell-valid-for-target-attrs?)
    setup-sentry-queen-scv-defense)
   ;; 15–19: Worker Rush Matrix
   (lotv-scenario-spec
    'worker-rush-terran-scv-repair-pocket-vs-12-worker
    "Worker Rush: Terran SCV Mutual Repair Pocket vs 12 Stacked Probes"
    "12 SCVs + CC vs 12 mineral-stacked enemy Probes"
    'standard 650 'enemy 'ally
    '(select-worker-drill-stack-mineral-patch translate-bot-actions->sc2-raw-commands spell-valid-for-target-attrs?)
    setup-worker-terran-repair-pocket)
   (lotv-scenario-spec
    'worker-rush-protoss-probe-shield-regen-kite-vs-12-worker
    "Worker Rush: Protoss Probe Shield Kite/Regen vs 12 Stacked Drones"
    "12 Probes + Nexus vs 12 mineral-stacked enemy Drones"
    'standard 650 'enemy 'ally
    '(select-worker-drill-stack-mineral-patch translate-bot-actions->sc2-raw-commands)
    setup-worker-protoss-shield-kite)
   (lotv-scenario-spec
    'worker-rush-townhall-focus-mineral-stack-breaker
    "Worker Rush: TownHall Focus & 60 dmg/frame Mineral-Walk Stack Breaker (#222)"
    "12 Drones + Hatchery vs 12 tight mineral-stacked Probes (60 dmg/frame volleys)"
    'standard 650 'enemy 'ally
    '(select-worker-drill-stack-mineral-patch translate-bot-actions->sc2-raw-commands)
    setup-worker-townhall-stack-breaker)
   (lotv-scenario-spec
    'worker-rush-mixed-workers-plus-early-zealot-or-marine
    "Worker Rush: Mixed 12 SCVs + Early Marine Kite vs 11 Stacked Probes + Zealot"
    "12 SCVs + 1 Marine + CC vs 11 stacked Probes + 1 Zealot"
    'standard 700 'enemy 'ally
    '(select-worker-drill-stack-mineral-patch translate-bot-actions->sc2-raw-commands)
    setup-worker-mixed-early-unit)
   (lotv-scenario-spec
    'worker-rush-proxy-cannon-or-bunker-builder-snipe
    "Worker Rush: Proxy Cannon + Builder Snipe Squad vs 8 Stacked Probes"
    "12 Probes vs Proxy Pylon + Incomplete Photon Cannon + Builder + 8 stacked Probes"
    'standard 700 'enemy 'ally
    '(select-worker-drill-stack-mineral-patch translate-bot-actions->sc2-raw-commands)
    setup-worker-proxy-builder-snipe)))

(define LOTV-UNIT-TESTER-SCENARIO-IDS
  (map lotv-scenario-spec-id LOTV-UNIT-TESTER-SCENARIOS))

;; First 8 canonical asymmetric micro scenarios preserved for Suite 48.4 default runs.
(define LOTV-UNIT-TESTER-CANONICAL-SCENARIOS
  (take LOTV-UNIT-TESTER-SCENARIOS 8))

(define (find-lotv-unit-tester-scenario key)
  (define sym
    (cond
      [(lotv-scenario-spec? key) (lotv-scenario-spec-id key)]
      [(symbol? key) key]
      [(string? key) (string->symbol (string-trim key))]
      [else #f]))
  (and sym
       (findf (lambda (s) (eq? (lotv-scenario-spec-id s) sym))
              LOTV-UNIT-TESTER-SCENARIOS)))

;; -----------------------------------------------------------------------------
;; 8. Simulation Runner & Scoring
;; -----------------------------------------------------------------------------

(define (worker-scenario-id? sid)
  (not (eq? (memq sid '(worker-rush-townhall-stack-mineral-drill
                         worker-rush-terran-scv-repair-pocket-vs-12-worker
                         worker-rush-protoss-probe-shield-regen-kite-vs-12-worker
                         worker-rush-townhall-focus-mineral-stack-breaker
                         worker-rush-mixed-workers-plus-early-zealot-or-marine
                         worker-rush-proxy-cannon-or-bunker-builder-snipe))
            #f)))

(define (enemy-bldg-win-scenario-id? sid)
  (not (eq? (memq sid '(glaive-adept-shade-bypass-fortified-choke
                         worker-rush-proxy-cannon-or-bunker-builder-snipe))
            #f)))

(define (living-combat-units units team #:include-workers? [workers? #f] #:include-bldgs? [bldgs? #f])
  (for/list ([u (in-list units)]
             #:when (and (unit-alive? u)
                         (eq? (sim-unit-team u) team)
                         (or bldgs? (not (sim-unit-building? u)))
                         (or workers? (not (sim-unit-worker? u)))))
    u))

(define (check-winner spec w)
  (define units (sim-world-units w))
  (define sid (lotv-scenario-spec-id spec))
  (define workers-count? (worker-scenario-id? sid))
  (define bldgs-count? (enemy-bldg-win-scenario-id? sid))
  (define ally-alive (living-combat-units units 'ally #:include-workers? #t))
  (cond
    [(eq? (lotv-scenario-spec-win-mode spec) 'adept-mineral-bypass)
     (define scvs-alive
       (filter (lambda (u) (and (unit-alive? u) (eq? (sim-unit-team u) 'enemy) (eq? (sim-unit-type u) 'scv)))
               units))
     (cond
       [(null? scvs-alive) 'ally]
       [(null? ally-alive) 'enemy]
       [else #f])]
    [else
     (define townhall-lost?
       (and (eq? sid 'worker-rush-townhall-focus-mineral-stack-breaker)
            (not (for/or ([u (in-list units)])
                   (and (unit-alive? u)
                        (eq? (sim-unit-team u) 'ally)
                        (sim-unit-building? u))))))
     (define enemy-alive
       (living-combat-units units 'enemy #:include-workers? workers-count? #:include-bldgs? bldgs-count?))
     (cond
       [townhall-lost? 'enemy]
       [(and (null? enemy-alive) (pair? ally-alive)) 'ally]
       [(null? ally-alive) 'enemy]
       [else #f])]))

(define (run-single-mode spec mode [max-frames-override #f])
  (define max-frames (or max-frames-override (lotv-scenario-spec-max-frames spec)))
  (define w ((lotv-scenario-spec-setup-fn spec) mode))
  (define bldgs-count? (enemy-bldg-win-scenario-id? (lotv-scenario-spec-id spec)))
  (define start-allies (living-combat-units (sim-world-units w) 'ally #:include-workers? #t))
  (define start-enemies
    (living-combat-units (sim-world-units w) 'enemy
                         #:include-workers? #t
                         #:include-bldgs? bldgs-count?))
  (define start-a-cnt (length start-allies))
  (define start-e-cnt (length start-enemies))
  (define start-a-ehp (max 1.0 (for/sum ([u (in-list start-allies)]) (unit-ehp u))))
  (define start-e-ehp (max 1.0 (for/sum ([u (in-list start-enemies)]) (unit-ehp u))))

  (define winner #f)
  (let loop ()
    (set! winner (check-winner spec w))
    (when (and (not winner) (< (sim-world-frame w) max-frames))
      (if (eq? mode 'mothman-tactics)
          (plan-mothman-tactics! w)
          (plan-default-ai! w))
      (when (eq? (lotv-scenario-spec-id spec) 'disruptor-nova-catchable-range-and-cooldown-dive)
        (step-enemy-disruptors! w))
      (step-unit-actions! w)
      (step-effects-and-shades! w)
      (resolve-geometry-and-collisions! w)
      (set-sim-world-frame! w (+ (sim-world-frame w) 1))
      (loop)))

  (define end-allies (living-combat-units (sim-world-units w) 'ally #:include-workers? #t))
  (define end-enemies
    (living-combat-units (sim-world-units w) 'enemy
                         #:include-workers? #t
                         #:include-bldgs? bldgs-count?))
  (define final-winner
    (or winner
        (let ([a-frac (/ (for/sum ([u (in-list end-allies)]) (unit-ehp u)) start-a-ehp)]
              [e-frac (/ (for/sum ([u (in-list end-enemies)]) (unit-ehp u)) start-e-ehp)])
          (if (>= a-frac e-frac) 'ally 'enemy))))
  (define expected
    (if (eq? mode 'mothman-tactics)
        (lotv-scenario-spec-expected-mothman-winner spec)
        (lotv-scenario-spec-expected-default-winner spec)))
  (hasheq 'scenario (lotv-scenario-spec-id spec)
          'mode mode
          'winner final-winner
          'expected_winner expected
          'passed (eq? final-winner expected)
          'frames (sim-world-frame w)
          'elapsed_sec (/ (round (* (sim-world-frame w) DT 10.0)) 10.0)
          'ally_start start-a-cnt
          'ally_alive (length end-allies)
          'enemy_start start-e-cnt
          'enemy_alive (length end-enemies)
          'ally_hp_pct (/ (round (* 1000.0 (/ (for/sum ([u (in-list end-allies)]) (unit-ehp u)) start-a-ehp))) 10.0)
          'enemy_hp_pct (/ (round (* 1000.0 (/ (for/sum ([u (in-list end-enemies)]) (unit-ehp u)) start-e-ehp))) 10.0)
          'planner_calls (sim-world-planner-calls w)
          'tactics_triggered (sim-world-tactics-triggered w)))

(define (run-lotv-unit-tester-scenario id-or-spec #:mode [mode 'both] #:max-frames [max-frames #f])
  (define spec
    (or (find-lotv-unit-tester-scenario id-or-spec)
        (error 'run-lotv-unit-tester-scenario "Unknown LotV scenario: ~a" id-or-spec)))
  (case mode
    [(default-ai mothman-tactics)
     (run-single-mode spec mode max-frames)]
    [else
     (define def-res (run-single-mode spec 'default-ai max-frames))
     (define moth-res (run-single-mode spec 'mothman-tactics max-frames))
     (define passed? (and (hash-ref def-res 'passed #f) (hash-ref moth-res 'passed #f)))
     (hasheq 'scenario (lotv-scenario-spec-id spec)
             'title (lotv-scenario-spec-title spec)
             'description (lotv-scenario-spec-description spec)
             'planner_refs (lotv-scenario-spec-planner-refs spec)
             'default_ai def-res
             'mothman_tactics moth-res
             'default_winner (hash-ref def-res 'winner)
             'mothman_winner (hash-ref moth-res 'winner)
             'passed passed?)]))

(define (run-all-lotv-unit-tester-scenarios #:scenarios [scenarios LOTV-UNIT-TESTER-CANONICAL-SCENARIOS])
  (define results
    (for/list ([sc (in-list scenarios)])
      (run-lotv-unit-tester-scenario sc)))
  (define total (length results))
  (define passed (for/sum ([r (in-list results)]) (if (hash-ref r 'passed #f) 1 0)))
  (hasheq 'total total
          'passed passed
          'failed (- total passed)
          'all_passed (= passed total)
          'results results))
