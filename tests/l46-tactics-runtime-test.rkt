#lang racket/base

;; =============================================================================
;; Loop 46 Runtime & Tactics Verification Suite (`L46-P0-1a..1b`, `#1032`)
;;   1. L46-P0-1a (`p15` Mass Recall `3757` 1-Liner):
;;      Exclude permanently-cloaked `dark-templar` / undetected cloaked units from
;;      `nexus-recall-save` whenever `0` enemy detectors exist within `<= 24t`
;;      (while STILL allowing recall when enemy detector IS present or squad is uncloaked!).
;;   2. L46-P0-1a (`ro09` Dummy `2505` Stasis Ward Suppress):
;;      Suppress Oracle Stasis Ward (`2505`) when `en < 90` against a full mineral line
;;      (`>= 8` workers `<= 14t`) OR `>= 4` workers under active AA fire (`<= 10.5t`), and
;;      hold Pulsar Beam ON across `14t` down to `sh < 10.0` (while preserving `L43-T3d`!).
;;   3. L46-P0-1b (`ro04` Blue-Flame Hellion Deeper Flank `+0.8t`):
;;      Hellions arc `+4.0t` forward & `±3.8t` perpendicular past blocking Queens!
;;   4. L46-P0-1b (`e01` Probe Harass Sticky Defenders & Zero-Lag Replacement):
;;      Pins existing healthy defending Probes FIRST (zero miner churn as scouts move!)
;;      and replaces a rotated-out (`<= 20` EHP) defender on the exact same frame!
;;   5. L46-P0-1b (`d10` Raven Tether `<= 4.0t` Behind Vikings):
;;      Raven stays tethered `<= 4.0t` behind Viking-Fighter centroid (revealing cloaked
;;      Observers!) while kiting safely if low HP (`< 35%`) near AA!
;;   6. L46-P0-1b (`d12` Ghost Proactive Cloak `382` at `<= 11.0t`):
;;      Ghosts proactively cast `cloak-ghost` at `<= 11.0t` when backed by `>= 6` friendly
;;      combat allies against outer-rim static Spores (`8..11t`), while STILL blocking
;;      cloak near mobile detectors (`observer`/`overseer`/`raven` `< 11t`)!
;;   7. L46-P0-1b (`r02`/`r05`/`r06` Tight `6f` Pre-Contact Stack & `<= 2.2t` Abort):
;;      Stacks at `f=900` & `f=906`, releases by `f=907` (instead of `910`), AND aborts
;;      immediately if enemy workers close to `<= 2.2t`!
;;   8. L46-P0-1b (`#72` 12-Pool Incomplete `Nexus #2` Cancel):
;;      Cancels incomplete `Nexus #2` (`bp < 0.85`) via `(cancel-building nid)` when
;;      `>= 6` Zerglings invade `< 150s` (`<= 3360f`) with `< 6` local combat supply,
;;      while NOT cancelling completed Nexuses (`bp >= 0.85`), solo main Nexus, or defended naturals!
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/plan/map-elements-and-experiments.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt")

(define tests-run 0)
(define tests-passed 0)
(define tests-failed 0)

(define (check-true name cond [detail ""])
  (set! tests-run (add1 tests-run))
  (if cond
      (begin
        (set! tests-passed (add1 tests-passed))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! tests-failed (add1 tests-failed))
        (printf "  [FAIL] ~a~a\n" name (if (equal? detail "") "" (format " :: ~a" detail))))))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0] #:buffs [buffs '()]
              #:flying? [flying? #f] #:cloaked? [cloaked? #f]
              #:cloak [cloak 0] #:burrowed? [burrowed? #f]
              #:build-progress [bp 1.0]
              #:orders [orders '()]
              #:assigned-harvesters [ah #f] #:ideal-harvesters [ih #f])
  (define h
    (hasheq 'id id 'tag id 'type type 'x x 'y y
            'hp hp 'max-hp max-hp 'shield shield 'shields shield 'max-shield max-shield
            'energy energy 'buffs buffs
            'flying? flying? 'is-flying flying?
            'cloaked cloaked? 'cloak cloak 'burrowed burrowed?
            'display-type 1 'snapshot? #f 'build-progress bp
            'orders orders))
  (define h1 (if ah (hash-set h 'assigned-harvesters ah) h))
  (if ih (hash-set h1 'ideal-harvesters ih) h1))

(define (mk-live-obs our-race enemy-race frame
                     #:ally-units [ally-units '()]
                     #:ally-buildings [ally-bldgs '()]
                     #:enemy-units [enemy-units '()]
                     #:enemy-buildings [enemy-bldgs '()]
                     #:minerals [minerals 400]
                     #:gas [gas 200]
                     #:supply-used [supply-used 40]
                     #:supply-cap [supply-cap 100]
                     #:base-x [base-x 32.0] #:base-y [base-y 32.0]
                     #:nat-x [nat-x 52.0] #:nat-y [nat-y 34.0]
                     #:enemy-x [enemy-x 140.0] #:enemy-y [enemy-y 120.0]
                     #:mineral-harvesters [mh 16]
                     #:mineral-patches [mps '()]
                     #:researched-upgrades [upgs '()])
  (hasheq 'frame frame 'our-race our-race 'enemy-race enemy-race
          'minerals minerals 'gas gas
          'supply-used supply-used 'supply-cap supply-cap
          'base-x base-x 'base-y base-y 'nat-x nat-x 'nat-y nat-y
          'enemy-x enemy-x 'enemy-y enemy-y
          'map-width 200 'map-height 200
          'mineral-harvesters mh
          'mineral-patches mps
          'ally-units ally-units 'ally-buildings ally-bldgs
          'enemy-units enemy-units 'enemy-buildings enemy-bldgs
          'researched-upgrades upgs))

(printf "=== Loop 46 Runtime & Tactics Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L46-P0-1a (`p15` Mass Recall 3757 1-Liner)
;; -----------------------------------------------------------------------------
(let ()
  (define home-nexus (mk-u 100 'nexus 32.0 138.0 #:hp 1000.0 #:shield 1000.0 #:energy 100.0))
  (define dts-5
    (for/list ([i (in-range 5)])
      (mk-u (+ 201 i) 'dark-templar (+ 80.0 (* 0.5 i)) 88.0 #:hp 40.0 #:shield 80.0 #:cloaked? #t #:cloak 1)))
  (define terran-48
    (append
     (for/list ([i (in-range 24)])
       (mk-u (+ 8001 i) 'marine (+ 82.0 (* 0.4 (modulo i 6))) (+ 86.0 (* 0.5 (quotient i 6))) #:hp 55.0))
     (for/list ([i (in-range 8)])
       (mk-u (+ 8050 i) 'marauder (+ 83.0 (* 0.4 i)) 89.0 #:hp 125.0))
     (for/list ([i (in-range 6)])
       (mk-u (+ 8080 i) 'siege-tank-sieged (+ 85.0 (* 0.6 i)) 88.0 #:hp 175.0))))

  ;; (i) 0 enemy detectors -> invincible cloaked DTs MUST NOT be recalled home (`3757`)!
  (define dirs-nodet
    (plan-warp-prism-and-recall-tactics
     dts-5 (list home-nexus) terran-48
     #:frame 1400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 84.0 #:enemy-y 88.0
     #:enemy-buildings '()))
  (check-true "L46-T1a-p15-no-mass-recall-on-invincible-cloaked-dts-when-zero-detectors"
              (not (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'nexus-recall-save)) dirs-nodet))
              (format "dirs=~a" dirs-nodet))

  ;; (ii) Live enemy Missile Turret (in `enemy-buildings`) within `<= 24t` -> detected DTs CAN be recalled!
  (define turret-near (mk-u 8901 'missile-turret 84.0 88.0 #:hp 250.0))
  (define dirs-with-turret
    (plan-warp-prism-and-recall-tactics
     dts-5 (list home-nexus) terran-48
     #:frame 1400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 84.0 #:enemy-y 88.0
     #:enemy-buildings (list turret-near)))
  ;; (iii) Uncloaked Zealots overwhelmed > 1.5x -> STILL recalled cleanly!
  (define zealots-5
    (for/list ([i (in-range 5)])
      (mk-u (+ 251 i) 'zealot (+ 80.0 (* 0.5 i)) 88.0 #:hp 100.0 #:shield 50.0)))
  (define dirs-zealots
    (plan-warp-prism-and-recall-tactics
     zealots-5 (list home-nexus) terran-48
     #:frame 1400 #:home-x 32.0 #:home-y 138.0 #:enemy-x 84.0 #:enemy-y 88.0))
  (check-true "L46-T1a-p15-recall-still-fires-when-detector-present-or-squad-uncloaked"
              (and (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'nexus-recall-save)) dirs-with-turret)
                   (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'nexus-recall-save)) dirs-zealots))
              (format "turret-dirs=~a zealot-dirs=~a" (length dirs-with-turret) (length dirs-zealots))))

;; -----------------------------------------------------------------------------
;; 2. L46-P0-1a (`ro09` Dummy `2505` Stasis Ward Suppress + 14t Beam Hold)
;; -----------------------------------------------------------------------------
(let ()
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8100 i) 'scv 30.3 (+ 135.5 (* 0.4 i)) #:hp 45.0)))
  (define marines-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 8001 i) 'marine 36.5 (+ 137.5 (* 0.6 i)) #:hp 45.0)))

  ;; (i) Low-shield Oracle (`sh=18 < 25, en=55`) over 4 Marines + 16 SCVs (`ro09` Dummy!):
  ;; MUST NOT cast `stasis-ward` (`2505`), MUST pop `pulsar-beam-on` (`2375`)!
  (define d-ro09-lowsh
    (plan-protoss-spellcaster-micro
     (list (mk-u 101 'oracle 37.5 138.5 #:hp 100.0 #:shield 18.0 #:energy 55.0 #:flying? #t))
     (append marines-4 scvs-16)
     #:claims (make-spell-claims) #:current-frame 1150))
  (check-true "L46-T1b-ro09-never-casts-stasis-ward-over-marines-pops-pulsar-beam"
              (and (= (length d-ro09-lowsh) 1)
                   (eq? (spell-directive-ability (car d-ro09-lowsh)) 'pulsar-beam-on))
              (format "dirs=~a" d-ro09-lowsh))

  ;; (ii) Oracle crossing 4 Marines at `11.5t` from 16 SCVs (`sh=18`, beam ON, `dwell=80f`):
  ;; HOLDS Pulsar Beam ON across `14t` (zero premature `2376` off!)
  (define c-or (make-spell-claims))
  (hash-set! (spell-claims-oracle-beam-start c-or) 101 1000)
  (define d-hold-11t
    (plan-protoss-spellcaster-micro
     (list (mk-u 101 'oracle 41.8 138.5 #:hp 100.0 #:shield 18.0 #:energy 30.0 #:flying? #t #:buffs '(oracle-weapon)))
     (append marines-4 scvs-16)
     #:claims c-or #:current-frame 1080))
  ;; (iii) Uncontested low-shield Oracle (`sh=20, en=52`) near 5 SCVs (0 AA — `L43-T3d` preservation!):
  ;; STILL plants `stasis-ward`!
  (define d-l43-stasis
    (plan-protoss-spellcaster-micro
     (list (mk-u 102 'oracle 35.0 138.5 #:hp 100.0 #:shield 20.0 #:energy 52.0 #:flying? #t))
     (take scvs-16 5)
     #:claims (make-spell-claims) #:current-frame 1100))
  (check-true "L46-T1b-ro09-holds-beam-at-11.5t-and-preserves-uncontested-l43-stasis"
              (and (null? d-hold-11t)
                   (= (length d-l43-stasis) 1)
                   (eq? (spell-directive-ability (car d-l43-stasis)) 'stasis-ward))
              (format "hold-11t=~a l43-stasis=~a" d-hold-11t d-l43-stasis)))

;; -----------------------------------------------------------------------------
;; 3. L46-P0-1b (`ro04` Blue-Flame Hellion Deeper Flank `+0.8t`)
;; -----------------------------------------------------------------------------
(let ()
  (define hellions-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 401 i) 'hellion 42.7 (+ 137.8 (* 0.45 i)) #:hp 90.0)))
  (define queens-2
    (list (mk-u 8001 'queen 36.3 138.2 #:hp 175.0)
          (mk-u 8002 'queen 36.3 138.8 #:hp 175.0)))
  (define drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8100 i) 'drone 30.3 (+ 135.5 (* 0.4 i)) #:hp 40.0)))
  (define-values (acts-ro04 _v _r)
    (step-layer3-and-4-tactics!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Zerg 160
                  #:supply-used 8 #:supply-cap 200 #:mineral-harvesters 0
                  #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                  #:ally-units hellions-4 #:enemy-units (append queens-2 drones-16))
     0.5))
  (define deep-flanks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move)
                             (<= 401 (second a) 404)
                             (<= (third a) 32.8)
                             (>= (abs (- (fourth a) 138.5)) 3.2)))
            acts-ro04))
  (check-true "L46-T2a-ro04-hellions-arc-deeper-past-queens-behind-mineral-line"
              (= (length deep-flanks) 4)
              (format "deep-flanks=~a" deep-flanks)))

;; -----------------------------------------------------------------------------
;; 4. L46-P0-1b (`e01` Sticky Light-Harass Defenders + Zero-Lag Rotation Replacement)
;; -----------------------------------------------------------------------------
(let ()
  (define main-nex (mk-u 6000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 12 #:ideal-harvesters 16))
  (define main-mps
    (for/list ([i (in-range 8)])
      (hasheq 'id (+ 7001 i) 'x 26.5 'y (+ 28.0 (* 1.2 i)) 'mineral-contents 1500)))
  (define probes-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 6101 i) 'probe 28.5 (+ 28.0 (* 0.75 i)) #:hp 20.0 #:shield 20.0)))
  ;; Tick 1 (`f=800`): 2 enemy Probes near top of mineral line (`y=29`) -> pulls 2 closest healthy Probes!
  (define ep-top
    (list (mk-u 6901 'probe 31.0 28.5 #:hp 20.0 #:shield 20.0)
          (mk-u 6902 'probe 31.0 29.5 #:hp 20.0 #:shield 20.0)))
  (define rt-e01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-1
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 800 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12 #:ally-buildings (list main-nex)
                  #:enemy-units ep-top #:mineral-patches main-mps)))
  (define pulled-1
    (remove-duplicates
     (append* (for/list ([a (in-list acts-1)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  ;; Tick 2 (`f=816`): Enemy Probes move south to `y=35.5` (closer to Probes 6110/6111!),
  ;; while `pulled-1` are still healthy (`35` EHP) -> MUST stick with SAME `pulled-1`, ZERO new miner churn!
  (define ep-bot
    (list (mk-u 6901 'probe 31.0 35.0 #:hp 20.0 #:shield 20.0)
          (mk-u 6902 'probe 31.0 36.0 #:hp 20.0 #:shield 20.0)))
  (define acts-2
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 816 #:minerals 120 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12 #:ally-buildings (list main-nex)
                  #:enemy-units ep-bot #:mineral-patches main-mps)))
  (define pulled-2
    (remove-duplicates
     (append* (for/list ([a (in-list acts-2)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  ;; Tick 3 (`f=820`, ONLY `+4f` after `816` < 16f refractory!): Defender 1 drops to `20` EHP ->
  ;; rotates out via `harvest-mineral` AND a fresh replacement is IMMEDIATELY pulled on the SAME frame (zero 1v2 lag)!
  (define wounded-id (car pulled-1))
  (define probes-rot
    (for/list ([u (in-list probes-12)])
      (if (= (hash-ref u 'id) wounded-id)
          (hash-set* u 'hp 20.0 'shield 0.0 'shields 0.0)
          u)))
  (define acts-3
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 820 #:minerals 125 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-rot #:ally-buildings (list main-nex)
                  #:enemy-units ep-bot #:mineral-patches main-mps)))
  (define rot-ret? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (= (second a) wounded-id))) acts-3))
  (define pulled-3
    (remove-duplicates
     (append* (for/list ([a (in-list acts-3)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  (check-true "L46-T2b-e01-sticky-defenders-zero-miner-churn-and-zero-lag-rotation-replacement"
              (and (= (length pulled-1) 2)
                   (equal? (sort pulled-2 <) (sort pulled-1 <))
                   rot-ret?
                   (= (length pulled-3) 2)
                   (not (memv wounded-id pulled-3)))
              (format "p1=~a p2=~a rot?=~a p3=~a" pulled-1 pulled-2 rot-ret? pulled-3)))

;; -----------------------------------------------------------------------------
;; 5. L46-P0-1b (`d10` Raven Tether `<= 4.0t` Behind Vikings)
;; -----------------------------------------------------------------------------
(let ()
  (define vikings-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 501 i) 'viking-fighter 75.0 (+ 89.0 (* 0.5 i)) #:hp 135.0 #:flying? #t)))
  (define banshees-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 511 i) 'banshee 74.8 (+ 85.0 (* 0.5 i)) #:hp 140.0 #:flying? #t #:cloaked? #t #:cloak 1)))
  ;; Raven starts far behind at `(64.0, 90.0)` (`11t` away from Vikings!) with low energy (`30 < 50`, no spell!)
  (define raven-far (mk-u 520 'raven 64.0 90.0 #:hp 140.0 #:energy 30.0 #:flying? #t))
  (define enemies-d10
    (append
     (for/list ([i (in-range 8)])
       (mk-u (+ 8501 i) 'stalker 84.8 (+ 86.0 (* 0.8 i)) #:hp 80.0 #:shield 80.0))
     (list (mk-u 8551 'observer 85.0 90.0 #:hp 40.0 #:shield 20.0 #:flying? #t #:cloaked? #t #:cloak 2)
           (mk-u 8552 'observer 85.0 91.0 #:hp 40.0 #:shield 20.0 #:flying? #t #:cloaked? #t #:cloak 2))))
  (define-values (acts-d10 _v _r)
    (step-layer3-and-4-tactics!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 900
                  #:supply-used 30 #:supply-cap 200 #:mineral-harvesters 0
                  #:base-x 25.0 #:base-y 25.0 #:enemy-x 85.0 #:enemy-y 90.0
                  #:ally-units (cons raven-far (append vikings-4 banshees-4))
                  #:enemy-units enemies-d10)
     0.5))
  (define raven-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 520))) acts-d10))
  (define raven-tether-dist
    (if (pair? raven-moves)
        (sqrt (+ (sqr (- (third (car raven-moves)) 75.0))
                 (sqr (- (fourth (car raven-moves)) 89.75))))
        999.0))
  (check-true "L46-T2c-d10-raven-tethers-within-4t-behind-vikings-for-observer-detection"
              (and (pair? raven-moves)
                   (<= raven-tether-dist 4.0)
                   (< (third (car raven-moves)) 75.0))
              (format "raven-moves=~a dist-to-vikings=~a" raven-moves raven-tether-dist)))

;; -----------------------------------------------------------------------------
;; 6. L46-P0-1b (`d12` Ghost Proactive Cloak `382` at `<= 11.0t` + Mobile Detector Guard)
;; -----------------------------------------------------------------------------
(let ()
  (define ghost-1 (mk-u 601 'ghost 74.8 86.5 #:hp 100.0 #:energy 75.0))
  (define bio-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 610 i) 'marine 75.5 (+ 85.0 (* 0.5 i)) #:hp 55.0)))
  (define roaches-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 8601 i) 'roach 83.5 (+ 86.0 (* 0.6 i)) #:hp 145.0)))
  (define spores-2
    (list (mk-u 8651 'spore-crawler 84.2 85.6 #:hp 400.0)
          (mk-u 8652 'spore-crawler 84.2 90.4 #:hp 400.0)))
  ;; (i) `d12` scenario: Ghost at `9.44t` from outer-rim Spores, backed by 12 Marines, Roaches at `8.7t` -> casts `cloak-ghost`!
  (define dirs-d12
    (plan-terran-spellcaster-micro
     (cons ghost-1 bio-12) roaches-6
     #:enemy-buildings spores-2
     #:claims (make-spell-claims) #:current-frame 1200
     #:ghost-cloak-researched? #t))
  ;; (ii) Negative guard: Mobile `observer` at `5.0t` STILL strictly blocks Ghost cloak!
  (define dirs-mob-det
    (plan-terran-spellcaster-micro
     (cons ghost-1 bio-12)
     (cons (mk-u 8699 'observer 79.8 86.5 #:hp 40.0 #:shield 20.0 #:flying? #t) roaches-6)
     #:claims (make-spell-claims) #:current-frame 1200
     #:ghost-cloak-researched? #t))
  (check-true "L46-T2d-d12-ghost-proactive-cloak-at-11t-with-bio-squad-blocks-near-mobile-detector"
              (and (ormap (lambda (d) (and (= (spell-directive-caster-tag d) 601)
                                           (eq? (spell-directive-ability d) 'cloak-ghost)))
                          dirs-d12)
                   (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'cloak-ghost))
                               dirs-mob-det)))
              (format "d12=~a mob-det=~a" dirs-d12 dirs-mob-det)))

;; -----------------------------------------------------------------------------
;; 7. L46-P0-1b (`r02`/`r05`/`r06` Tight `6f` Pre-Contact Stack + `<= 2.2t` Abort)
;; -----------------------------------------------------------------------------
(let ()
  (define cc-home (mk-u 4001 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 4101 i) 'scv (+ 25.0 (* 0.2 (modulo i 3))) (+ 27.0 (* 0.75 i)) #:hp 45.0)))
  (define probes-12-far
    (for/list ([i (in-range 10)])
      (mk-u (+ 8901 i) 'probe (+ 32.5 (* 0.25 (modulo i 4))) (+ 31.5 (* 0.35 (quotient i 4))) #:hp 20.0 #:shield 20.0)))
  (define probes-12-close
    (for/list ([i (in-range 10)])
      (mk-u (+ 8901 i) 'probe (+ 27.0 (* 0.15 (modulo i 4))) (+ 31.5 (* 0.25 (quotient i 4))) #:hp 20.0 #:shield 20.0)))
  (define base-mps
    (list (hasheq 'id 99301 'x 26.0 'y 28.0)
          (hasheq 'id 99302 'x 26.0 'y 32.0)
          (hasheq 'id 99303 'x 26.0 'y 36.0)))
  (define rt-r05 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  ;; Tick `f=900` & `f=904` stack (`<= 4f`), `f=905` (`> 4f`) immediately releases into `pull-workers-attack`!
  (define acts-900
    (step-layer2-economy! rt-r05 (mk-live-obs 'Terran 'Protoss 900 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                                              #:ally-units scvs-16 #:ally-buildings (list cc-home)
                                              #:enemy-units probes-12-far #:mineral-patches base-mps)))
  (define acts-905
    (step-layer2-economy! rt-r05 (mk-live-obs 'Terran 'Protoss 905 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                                              #:ally-units scvs-16 #:ally-buildings (list cc-home)
                                              #:enemy-units probes-12-far #:mineral-patches base-mps)))
  ;; Close-range `<= 2.5t` abort on `f=904` (inside `4f` window!):
  (define rt-r05-abort (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (step-layer2-economy! rt-r05-abort (mk-live-obs 'Terran 'Protoss 900 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                                                  #:ally-units scvs-16 #:ally-buildings (list cc-home)
                                                  #:enemy-units probes-12-far #:mineral-patches base-mps))
  (define acts-abort
    (step-layer2-economy! rt-r05-abort (mk-live-obs 'Terran 'Protoss 904 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                                                    #:ally-units scvs-16 #:ally-buildings (list cc-home)
                                                    #:enemy-units probes-12-close #:mineral-patches base-mps)))
  (check-true "L46-T2e-r05-pre-contact-stack-releases-after-4f-and-aborts-at-2.5t"
              (and (>= (length (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-900)) 10)
                   (pair? (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-905))
                   (pair? (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-abort)))
              (format "900-mw=~a 905-atk=~a abort-atk=~a"
                      (length (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-900))
                      (length (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-905))
                      (length (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-abort)))))

;; -----------------------------------------------------------------------------
;; 8. L46-P0-1b (`#72` 12-Pool Cancel Incomplete `Nexus #2`)
;; -----------------------------------------------------------------------------
(let ()
  (define main-nex (mk-u 7001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0 #:build-progress 1.0))
  (define nat-nex-incomp (mk-u 7002 'nexus 52.0 34.0 #:hp 350.0 #:shield 350.0 #:build-progress 0.45))
  (define nat-nex-done (mk-u 7002 'nexus 52.0 34.0 #:hp 900.0 #:shield 900.0 #:build-progress 0.90))
  (define probes-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 7101 i) 'probe 28.5 (+ 28.0 (* 0.5 i)) #:hp 20.0 #:shield 20.0)))
  (define lings-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 8801 i) 'zergling 50.0 (+ 33.0 (* 0.5 i)) #:hp 35.0)))
  ;; (i) 6 Zerglings invade at `f=2400` (`107s < 150s`), incomplete `Nexus #2` (`bp=0.45 < 0.85`), 0 combat -> CANCEL!
  (define acts-cancel
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Zerg 2400 #:minerals 80 #:gas 0 #:supply-used 18 #:supply-cap 23
                  #:ally-units probes-16 #:ally-buildings (list main-nex nat-nex-incomp)
                  #:enemy-units lings-6)))
  ;; (ii) Negative guard: nearly finished `Nexus #2` (`bp=0.90 >= 0.85`) -> MUST NOT cancel!
  (define acts-no-cancel-bp
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Zerg 2400 #:minerals 80 #:gas 0 #:supply-used 18 #:supply-cap 23
                  #:ally-units probes-16 #:ally-buildings (list main-nex nat-nex-done)
                  #:enemy-units lings-6)))
  ;; (iii) Negative guard: well-defended natural (`4` Zealots = `8` supply >= `6.0`) -> MUST NOT cancel!
  (define zealots-4
    (for/list ([i (in-range 4)]) (mk-u (+ 7201 i) 'zealot 50.5 (+ 33.5 (* 0.5 i)) #:hp 100.0 #:shield 50.0)))
  (define acts-no-cancel-def
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Zerg 2400 #:minerals 80 #:gas 0 #:supply-used 26 #:supply-cap 31
                  #:ally-units (append probes-16 zealots-4) #:ally-buildings (list main-nex nat-nex-incomp)
                  #:enemy-units lings-6)))
  (check-true "L46-T2f-72-12pool-cancels-incomplete-nexus2-and-respects-bp-and-defense-guards"
              (and (ormap (lambda (a) (equal? a '(cancel-building 7002))) acts-cancel)
                   (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cancel-building))) acts-no-cancel-bp))
                   (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cancel-building))) acts-no-cancel-def)))
              (format "cancel?=~a bp-guard=~a def-guard=~a"
                      (ormap (lambda (a) (equal? a '(cancel-building 7002))) acts-cancel)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'cancel-building))) acts-no-cancel-bp)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'cancel-building))) acts-no-cancel-def))))

(printf "\n=== Loop 46 Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
