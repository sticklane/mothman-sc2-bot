#lang racket/base

(require racket/list
         racket/match
         "../lib/bot-runtime.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/tactics/order-ledger.rkt")

;; =============================================================================
;; Loop 35 (`L35-P0-3`) Runtime Enforcement & Anti-Siege/Tempest Regression Suite
;; Covers:
;;   1. Protoss L2 Enforcement: Urgent AA/Reaper Stalker reserve (`#75`, `#54`)
;;      + PvT Bio-heavy Colossus-ahead-of-Disruptor/Immortal & 2nd Robo on 3 bases (`H2H #04`)
;;   2. Terran L2 Early-Rush Hellion/Marine Override (`#41` Zerglings, `#53` Reapers)
;;      + peaceful midgame negative guard
;;   3. Anti-Siege (`>= 4` Tanks) / Anti-Tempest (`>= 3` Tempests) Mass-Breakout Staging
;;      with `min(60, max(36, 0.70 * rem-enemy-sup))` + home-defense & close-contact guards
;;   4. `#56` Defending Unsieged Tanks on high-ground main/natural emit `siege-mode`
;;      cleanly even under `l25-counter-volley-staging?` and enemy Tank splash zones!
;; =============================================================================

(define total-checks 0)
(define failed-checks 0)

(define (check-true name cond-val [detail ""])
  (set! total-checks (add1 total-checks))
  (unless cond-val
    (set! failed-checks (add1 failed-checks))
    (eprintf "FAIL [~a]: ~a\n" name detail)))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0] #:cloak [cloak 3]
              #:flying? [flying? #f]
              #:build-progress [bp 1.0] #:order-count [oc 0]
              #:assigned-harvesters [ah 0] #:ideal-harvesters [ih 0])
  (hash 'id id 'type type 'x x 'y y
        'hp hp 'max-hp max-hp
        'shield shield 'shields shield 'max-shield max-shield 'max-shields max-shield
        'energy energy 'cloak cloak 'display-type 1
        'flying? flying? 'is-flying flying?
        'build-progress bp 'order-count oc 'order-ability-id 0
        'powered? #t
        'assigned-harvesters ah 'ideal-harvesters ih))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200]
                     #:gas [gas 100]
                     #:supply-used [su 44]
                     #:supply-cap [sc 70]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 56.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 140.0] #:enemy-y [ey 120.0]
                     #:upgrades [upgs '()])
  (hash 'race race 'enemy-race enemy-race 'frame frame
        'live-obs? #t 'live-game? #t
        'mineral-harvesters 28 'gas-harvesters 6
        'minerals minerals 'gas gas
        'supply-used su 'supply-cap sc
        'ally-units au 'ally-buildings ab
        'enemy-units eu 'enemy-buildings eb
        'base-x bx 'base-y by 'nat-x nx 'nat-y ny
        'natural-x nx 'natural-y ny
        'enemy-x ex 'enemy-y ey
        'researched-upgrades upgs
        'expansion-pads (list (cons 56.5 32.5) (cons 32.5 64.5) (cons 64.5 64.5))
        'map-width 168 'map-height 168))

(define (has-build-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a)
         (memq (car a) '(build build-structure))
         (>= (length a) 2)
         (eq? (cadr a) sym))))

(define (has-train-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a)
         (memq (car a) '(train train-unit))
         (>= (length a) 2)
         (eq? (cadr a) sym))))

(define (has-morph-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a)
         (eq? (car a) 'morph)
         (or (and (>= (length a) 2) (eq? (cadr a) sym))
             (and (>= (length a) 3) (eq? (caddr a) sym))))))

(define (has-cast-spell-sym? acts uid sym)
  (for/or ([a (in-list acts)])
    (and (pair? a)
         (eq? (car a) 'cast-spell)
         (>= (length a) 3)
         (eqv? (cadr a) uid)
         (eq? (caddr a) sym))))

;; =============================================================================
;; TEST 1: Protoss L2 Enforcement (`#75` Banshees, `#54` Reapers, `H2H #04` PvT)
;; =============================================================================
(let ()
  (define probes24 (for/list ([i (in-range 24)]) (mk-u (+ 101 i) 'probe 29.0 32.0 #:hp 20.0 #:shield 20.0)))
  (define probes48 (for/list ([i (in-range 48)]) (mk-u (+ 101 i) 'probe 29.0 32.0 #:hp 20.0 #:shield 20.0)))

  ;; T1a (`#75` Banshees): 2 Gateways, CyberCore, Robo + 1 Observer already alive, 0 Stalkers,
  ;; 175M / 150G facing 2 Banshees -> MUST train Stalker FIRST (no Gateway #3 / Stargate / Probe / Zealot theft!)
  (define rt1a (make-live-bot-runtime #:race 'Protoss))
  (define acts1a
    (step-layer2-economy!
     rt1a
     (mk-live-obs 'Protoss 'Terran 6200
                  #:minerals 175 #:gas 150 #:supply-used 36 #:supply-cap 62
                  #:ally-units (append probes24
                                       (list (mk-u 201 'observer 40.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t)
                                             (mk-u 202 'zealot 42.0 32.0 #:hp 100.0 #:shield 50.0)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 8 #:ideal-harvesters 16)
                                         (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 14 'gateway 43.0 32.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 15 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0)
                                         (mk-u 16 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0))
                  #:enemy-units (list (mk-u 901 'banshee 50.0 32.0 #:hp 140.0 #:flying? #t)
                                      (mk-u 902 'banshee 52.0 34.0 #:hp 140.0 #:flying? #t)))))
  (check-true "L35-T1a-protoss-urgent-stalker-trains-vs-banshees"
              (has-train-sym? acts1a 'stalker)
              (format "Expected stalker vs 2 Banshees at 175M/150G; acts=~a" acts1a))
  (check-true "L35-T1a-protoss-urgent-stalker-blocks-stargate-and-gate3-theft"
              (and (not (has-build-sym? acts1a 'stargate))
                   (not (has-build-sym? acts1a 'gateway))
                   (not (has-train-sym? acts1a 'zealot)))
              (format "Stargate/Gateway#3/Zealot must not steal urgent Stalker resources; acts=~a" acts1a))

  ;; T1b (`#75` Cloak Observer #1 protection): 0 Observers, ready Robo, 175M/100G vs cloaked Banshee
  ;; -> MUST train Observer #1 (75G) FIRST and NOT let Stalker steal the last gas!
  (define rt1b (make-live-bot-runtime #:race 'Protoss))
  (define acts1b
    (step-layer2-economy!
     rt1b
     (mk-live-obs 'Protoss 'Terran 6200
                  #:minerals 175 #:gas 100 #:supply-used 36 #:supply-cap 62
                  #:ally-units (append probes24
                                       (list (mk-u 202 'zealot 42.0 32.0 #:hp 100.0 #:shield 50.0)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 8 #:ideal-harvesters 16)
                                         (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 14 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0)
                                         (mk-u 16 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0))
                  #:enemy-units (list (mk-u 901 'banshee 50.0 32.0 #:hp 140.0 #:cloak 1 #:flying? #t)))))
  (check-true "L35-T1b-protoss-preserves-observer1-gas-under-cloaked-banshee"
              (has-train-sym? acts1b 'observer)
              (format "Expected observer #1 with 0 Observers & 100G vs cloaked Banshee; acts=~a" acts1b))

  ;; T1c (`#54` Reapers): 2 Gateways, CyberCore, 150M/75G vs 3 Reapers -> MUST train Stalker, NOT Zealot/Gateway#3!
  (define rt1c (make-live-bot-runtime #:race 'Protoss))
  (define acts1c
    (step-layer2-economy!
     rt1c
     (mk-live-obs 'Protoss 'Terran 3800
                  #:minerals 150 #:gas 75 #:supply-used 28 #:supply-cap 46
                  #:ally-units (append probes24
                                       (list (mk-u 202 'zealot 42.0 32.0 #:hp 100.0 #:shield 50.0)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 14 'gateway 43.0 32.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 15 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0))
                  #:enemy-units (list (mk-u 901 'reaper 48.0 32.0 #:hp 60.0)
                                      (mk-u 902 'reaper 49.0 33.0 #:hp 60.0)
                                      (mk-u 903 'reaper 49.0 31.0 #:hp 60.0)))))
  (check-true "L35-T1c-protoss-urgent-stalker-trains-vs-3-reapers-no-zealot-gate3"
              (and (has-train-sym? acts1c 'stalker)
                   (not (has-train-sym? acts1c 'zealot))
                   (not (has-build-sym? acts1c 'gateway)))
              (format "Expected stalker (no zealot/gateway#3) vs 3 Reapers at 150M/75G; acts=~a" acts1c))

  ;; T1d (`H2H #04` PvT Bio-Heavy Colossus > Disruptor/Immortal):
  ;; 3 Nexuses, Robo + RoboticsBay ready, 1 Colossus alive, 325M/225G vs 18 Marines+Marauders + 2 Medivacs
  ;; -> MUST train Colossus (NOT Disruptor, NOT Immortal)!
  (define bio18
    (append (for/list ([i (in-range 12)]) (mk-u (+ 901 i) 'marine 110.0 (+ 30.0 (* 0.5 i)) #:hp 45.0))
            (for/list ([i (in-range 6)]) (mk-u (+ 921 i) 'marauder 112.0 (+ 30.0 (* 0.5 i)) #:hp 125.0))
            (list (mk-u 931 'medivac 114.0 32.0 #:hp 150.0 #:flying? #t)
                  (mk-u 932 'medivac 114.0 34.0 #:hp 150.0 #:flying? #t))))
  (define rt1d (make-live-bot-runtime #:race 'Protoss))
  (define acts1d
    (step-layer2-economy!
     rt1d
     (mk-live-obs 'Protoss 'Terran 9600
                  #:minerals 325 #:gas 225 #:supply-used 74 #:supply-cap 110
                  #:ally-units (append probes48
                                       (list (mk-u 201 'colossus 55.0 32.0 #:hp 200.0 #:shield 150.0)
                                             (mk-u 202 'observer 58.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
                                       (for/list ([i (in-range 8)]) (mk-u (+ 210 i) 'stalker 56.0 32.0 #:hp 80.0 #:shield 80.0)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'nexus 32.5 64.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 13 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 14 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                                         (mk-u 15 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0)
                                         (mk-u 16 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0)
                                         (mk-u 17 'robotics-facility 40.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
                                         (mk-u 18 'robotics-bay 36.0 40.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 19 'assimilator 29.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                         (mk-u 20 'assimilator 35.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                         (mk-u 21 'assimilator 53.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                         (mk-u 22 'assimilator 59.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3))
                  #:upgrades '(warpgate)
                  #:enemy-units bio18)))
  (check-true "L35-T1d-protoss-pvt-bio-heavy-trains-colossus-ahead-of-disruptor-immortal"
              (and (has-train-sym? acts1d 'colossus)
                   (not (has-train-sym? acts1d 'disruptor))
                   (not (has-train-sym? acts1d 'immortal)))
              (format "Expected colossus ahead of disruptor/immortal vs 18 Terran Bio; acts=~a" acts1d))

  ;; T1e (`H2H #04` 2nd Robo unlock on 3 bases < 72 supply & < 550M):
  ;; 3 Nexuses, 1 busy Robo (`order-count = 1`), `supply-used = 58` (< 72), `250M/150G` (< 550M) vs 18 Bio
  ;; -> MUST build 2nd `robotics-facility` immediately!
  (define rt1e (make-live-bot-runtime #:race 'Protoss))
  (define acts1e
    (step-layer2-economy!
     rt1e
     (mk-live-obs 'Protoss 'Terran 8200
                  #:minerals 250 #:gas 150 #:supply-used 58 #:supply-cap 94
                  #:ally-units (append (take probes48 38)
                                       (list (mk-u 201 'colossus 55.0 32.0 #:hp 200.0 #:shield 150.0)
                                             (mk-u 202 'observer 58.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
                                       (for/list ([i (in-range 6)]) (mk-u (+ 210 i) 'stalker 56.0 32.0 #:hp 80.0 #:shield 80.0)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 14 #:ideal-harvesters 16)
                                         (mk-u 12 'nexus 32.5 64.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 8 #:ideal-harvesters 16)
                                         (mk-u 13 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 14 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                                         (mk-u 15 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0)
                                         (mk-u 16 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
                                         (mk-u 18 'robotics-bay 36.0 40.0 #:hp 500.0 #:shield 500.0))
                  #:enemy-units bio18)))
  (check-true "L35-T1e-protoss-pvt-bio-heavy-unlocks-2nd-robo-on-3bases"
              (has-build-sym? acts1e 'robotics-facility)
              (format "Expected 2nd robotics-facility on 3 bases at 58 sup / 250M vs 18 Terran Bio; acts=~a" acts1e)))

;; =============================================================================
;; TEST 2: Terran L2 Early-Rush Hellion/Marine Override (`#41` Lings, `#53` Reapers)
;; =============================================================================
(let ()
  (define scvs22 (for/list ([i (in-range 22)]) (mk-u (+ 101 i) 'scv 29.0 32.0 #:hp 45.0)))
  (define marines2 (for/list ([i (in-range 2)]) (mk-u (+ 151 i) 'marine 44.0 32.0 #:hp 45.0)))

  ;; T2a (`#53` Reapers): frame 3800 (< 6720), unmorphed CC, bare Factory, Barracks, 165M/75G vs 3 Reapers
  ;; -> MUST train Hellion + Marine immediately (NOT spend 150M on OrbitalCommand or lock Factory on TechLab!)
  (define rt2a (make-live-bot-runtime #:race 'Terran))
  (define acts2a
    (step-layer2-economy!
     rt2a
     (mk-live-obs 'Terran 'Terran 3800
                  #:minerals 165 #:gas 75 #:supply-used 24 #:supply-cap 46
                  #:ally-units (append scvs22 marines2)
                  #:ally-buildings (list (mk-u 10 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0)
                                         (mk-u 14 'factory 44.0 36.0 #:hp 1250.0))
                  #:enemy-units (list (mk-u 901 'reaper 48.0 32.0 #:hp 60.0)
                                      (mk-u 902 'reaper 49.0 33.0 #:hp 60.0)
                                      (mk-u 903 'reaper 50.0 31.0 #:hp 60.0)))))
  (check-true "L35-T2a-terran-early-reaper-rush-trains-hellion-and-marine"
              (and (has-train-sym? acts2a 'hellion)
                   (has-train-sym? acts2a 'marine))
              (format "Expected BOTH hellion & marine vs 3 Reapers at <5:00; acts=~a" acts2a))
  (check-true "L35-T2a-terran-early-reaper-rush-no-oc-or-techlab-theft"
              (and (not (has-morph-sym? acts2a 'orbital-command))
                   (not (has-build-sym? acts2a 'factory-techlab)))
              (format "OC/FactoryTechLab must not steal minerals/slot ahead of Hellion+Marine; acts=~a" acts2a))

  ;; T2b (`#41` Zerglings): frame 4200 (< 6720), Factory+TechLab ready, Barracks, 175M/100G vs 14 Zerglings
  ;; -> MUST train Hellion + Marine immediately (bypassing hold-fac-tl-for-tank? & Starport escrow!)
  (define lings14 (for/list ([i (in-range 14)]) (mk-u (+ 901 i) 'zergling 50.0 (+ 28.0 (* 0.4 i)) #:hp 35.0)))
  (define rt2b (make-live-bot-runtime #:race 'Terran))
  (define acts2b
    (step-layer2-economy!
     rt2b
     (mk-live-obs 'Terran 'Zerg 4200
                  #:minerals 175 #:gas 100 #:supply-used 25 #:supply-cap 46
                  #:ally-units (append scvs22 marines2)
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 25.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0)
                                         (hash 'id 14 'type 'factory 'x 44.0 'y 36.0 'hp 1250.0 'max-hp 1250.0
                                               'build-progress 1.0 'order-count 0 'order-ability-id 0
                                               'addon 'factory-techlab 'has-addon? #t)
                                         (mk-u 15 'factory-techlab 46.5 35.5 #:hp 400.0))
                  #:enemy-units lings14)))
  (check-true "L35-T2b-terran-early-zergling-rush-trains-hellion-and-marine-no-starport-theft"
              (and (has-train-sym? acts2b 'hellion)
                   (has-train-sym? acts2b 'marine)
                   (not (has-build-sym? acts2b 'starport)))
              (format "Expected hellion+marine (no starport theft) vs 14 Zerglings at <5:00; acts=~a" acts2b))

  ;; T2c (Negative guard): Peaceful frame 4200 (0 Reapers, 0 Zerglings), unmorphed CC + bare Factory
  ;; -> MUST morph Orbital Command / build FactoryTechLab normally (no false rush override!)
  (define rt2c (make-live-bot-runtime #:race 'Terran))
  (define acts2c
    (step-layer2-economy!
     rt2c
     (mk-live-obs 'Terran 'Terran 4200
                  #:minerals 210 #:gas 75 #:supply-used 28 #:supply-cap 46
                  #:ally-units (append scvs22 (for/list ([i (in-range 6)]) (mk-u (+ 151 i) 'marine 44.0 32.0 #:hp 45.0)))
                  #:ally-buildings (list (mk-u 10 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0)
                                         (mk-u 14 'factory 44.0 36.0 #:hp 1250.0))
                  #:enemy-units '())))
  (check-true "L35-T2c-terran-peaceful-negative-guard-no-false-rush-override"
              (or (has-morph-sym? acts2c 'orbital-command)
                  (has-build-sym? acts2c 'factory-techlab))
              (format "Expected normal OC/FactoryTechLab in peaceful TvT; acts=~a" acts2c)))

;; =============================================================================
;; TEST 3: Anti-Siege / Anti-Tempest Mass-Breakout Staging (`L35-P0-3`)
;; =============================================================================
(let ()
  (define base-bldgs-p
    (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0)))
  (define stalkers12
    (for/list ([i (in-range 12)])
      (mk-u (+ 201 i) 'stalker (+ 56.0 (* 0.5 (modulo i 4))) (+ 32.0 (* 0.5 (quotient i 4))) #:hp 80.0 #:shield 80.0)))
  (define stalkers31
    (for/list ([i (in-range 31)])
      (mk-u (+ 201 i) 'stalker (+ 56.0 (* 0.5 (modulo i 6))) (+ 32.0 (* 0.5 (quotient i 6))) #:hp 80.0 #:shield 80.0)))
  (define enemy-tanks6-far
    (append (for/list ([i (in-range 6)])
              (mk-u (+ 901 i) 'siege-tank-sieged (+ 130.0 (* 1.5 i)) 110.0 #:hp 175.0))
            (for/list ([i (in-range 12)])
              (mk-u (+ 921 i) 'marine (+ 128.0 (* 0.5 i)) 108.0 #:hp 45.0))))

  ;; T3a: 24-supply army staging at natural vs 6 enemy Sieged Tanks + 12 Marines across the map
  ;; -> MUST hold (`l35-siege-tempest-mass-hold? = #t` & no cross-map attack into enemy Tanks)!
  (define rt3a (make-live-bot-runtime #:race 'Protoss))
  (define-values (acts3a _v3a _r3a)
    (step-layer3-and-4-tactics!
     rt3a
     (mk-live-obs 'Protoss 'Terran 9600
                  #:supply-used 72 #:supply-cap 110
                  #:ally-units stalkers12
                  #:ally-buildings base-bldgs-p
                  #:enemy-units enemy-tanks6-far)
     0.0))
  (define ds3a (rt-door-state rt3a))
  (check-true "L35-T3a-anti-siege-holds-24sup-against-6-enemy-tanks"
              (and (hash-ref ds3a 'l35-siege-tempest-mass-hold? #f)
                   (>= (hash-ref ds3a 'l35-siege-breakout-sup-req 0.0) 36.0)
                   (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack))) acts3a)))
              (format "Expected l35-siege-tempest-mass-hold? & no cross-map attack; hold=~a req=~a acts=~a"
                      (hash-ref ds3a 'l35-siege-tempest-mass-hold? #f)
                      (hash-ref ds3a 'l35-siege-breakout-sup-req 0.0)
                      acts3a))

  ;; T3b: Anti-Tempest scaling (`10` Tempests + `8` Carriers = `98` sup -> capped at `60.0` sup req!):
  ;; 24-supply army holds (`#t`), while 62-supply army (`31` Stalkers) releases (`#f`)!
  (define enemy-tempests10-far
    (append (for/list ([i (in-range 10)])
              (mk-u (+ 901 i) 'tempest (+ 130.0 (* 1.5 i)) 110.0 #:hp 200.0 #:shield 125.0 #:flying? #t))
            (for/list ([i (in-range 8)])
              (mk-u (+ 921 i) 'carrier (+ 132.0 (* 1.5 i)) 114.0 #:hp 300.0 #:shield 150.0 #:flying? #t))))
  (define rt3b1 (make-live-bot-runtime #:race 'Protoss))
  (define-values (_acts3b1 _v3b1 _r3b1)
    (step-layer3-and-4-tactics!
     rt3b1
     (mk-live-obs 'Protoss 'Protoss 12000
                  #:supply-used 72 #:supply-cap 110
                  #:ally-units stalkers12
                  #:ally-buildings base-bldgs-p
                  #:enemy-units enemy-tempests10-far)
     0.0))
  (define ds3b1 (rt-door-state rt3b1))
  (define rt3b2 (make-live-bot-runtime #:race 'Protoss))
  (define-values (_acts3b2 _v3b2 _r3b2)
    (step-layer3-and-4-tactics!
     rt3b2
     (mk-live-obs 'Protoss 'Protoss 12000
                  #:supply-used 110 #:supply-cap 150
                  #:ally-units stalkers31
                  #:ally-buildings base-bldgs-p
                  #:enemy-units enemy-tempests10-far)
     0.0))
  (define ds3b2 (rt-door-state rt3b2))
  (check-true "L35-T3b-anti-tempest-clamps-at-60sup-holds-24sup-releases-62sup"
              (and (hash-ref ds3b1 'l35-siege-tempest-mass-hold? #f)
                   (= (hash-ref ds3b1 'l35-siege-breakout-sup-req 0.0) 60.0)
                   (not (hash-ref ds3b2 'l35-siege-tempest-mass-hold? #f)))
              (format "Expected 24sup hold (req=60.0) & 62sup release; b1-hold=~a b1-req=~a b2-hold=~a"
                      (hash-ref ds3b1 'l35-siege-tempest-mass-hold? #f)
                      (hash-ref ds3b1 'l35-siege-breakout-sup-req 0.0)
                      (hash-ref ds3b2 'l35-siege-tempest-mass-hold? #f)))

  ;; T3c (Home defense guard): Same 6 Tanks approaching within 10t of natural Nexus (`enemy-within-14-of-th?`)
  ;; -> MUST NOT activate `l35-siege-tempest-mass-hold?`!
  (define enemy-tanks6-at-nat
    (for/list ([i (in-range 6)])
      (mk-u (+ 901 i) 'siege-tank-sieged (+ 64.0 (* 0.8 i)) 32.5 #:hp 175.0)))
  (define rt3c (make-live-bot-runtime #:race 'Protoss))
  (define-values (_acts3c _v3c _r3c)
    (step-layer3-and-4-tactics!
     rt3c
     (mk-live-obs 'Protoss 'Terran 9600
                  #:supply-used 72 #:supply-cap 110
                  #:ally-units stalkers12
                  #:ally-buildings base-bldgs-p
                  #:enemy-units enemy-tanks6-at-nat)
     0.0))
  (define ds3c (rt-door-state rt3c))
  (check-true "L35-T3c-anti-siege-home-defense-engages-immediately"
              (not (hash-ref ds3c 'l35-siege-tempest-mass-hold? #f))
              (format "Home defense must NEVER be held by l35-siege-tempest-mass-hold?; hold=~a"
                      (hash-ref ds3c 'l35-siege-tempest-mass-hold? #f)))

  ;; T3d (Close contact guard): 24-supply army ALREADY within 11t of 6 enemy Sieged Tanks mid-map
  ;; -> `army-in-direct-visible-contact? = #t` -> MUST NOT activate `l35-siege-tempest-mass-hold?`!
  (define stalkers12-mid
    (for/list ([i (in-range 12)])
      (mk-u (+ 201 i) 'stalker (+ 100.0 (* 0.5 (modulo i 4))) (+ 80.0 (* 0.5 (quotient i 4))) #:hp 80.0 #:shield 80.0)))
  (define enemy-tanks6-mid
    (for/list ([i (in-range 6)])
      (mk-u (+ 901 i) 'siege-tank-sieged (+ 110.0 (* 0.8 i)) 80.0 #:hp 175.0)))
  (define rt3d (make-live-bot-runtime #:race 'Protoss))
  (define-values (_acts3d _v3d _r3d)
    (step-layer3-and-4-tactics!
     rt3d
     (mk-live-obs 'Protoss 'Terran 9600
                  #:supply-used 72 #:supply-cap 110
                  #:ally-units stalkers12-mid
                  #:ally-buildings base-bldgs-p
                  #:enemy-units enemy-tanks6-mid)
     0.0))
  (define ds3d (rt-door-state rt3d))
  (check-true "L35-T3d-anti-siege-close-contact-engages-zero-siege0dps"
              (not (hash-ref ds3d 'l35-siege-tempest-mass-hold? #f))
              (format "Close-contact army inside Tank range must NEVER be held; hold=~a"
                      (hash-ref ds3d 'l35-siege-tempest-mass-hold? #f)))

  ;; T3e (Fog / OWM persistence): Step 1 spots 6 Siege Tanks + 12 Marines across the map;
  ;; Step 2 has 0 visible enemies (fog!) -> OWM remembers the 6 Tanks & holds our 24-supply army!
  (define rt3e (make-live-bot-runtime #:race 'Protoss))
  (step-live-bot-runtime!
   rt3e
   (hash-set
    (mk-live-obs 'Protoss 'Terran 9600
                 #:supply-used 72 #:supply-cap 110
                 #:ally-units stalkers12
                 #:ally-buildings base-bldgs-p
                 #:enemy-units enemy-tanks6-far)
    'enable-opponent-world-model #t))
  (step-live-bot-runtime!
   rt3e
   (hash-set
    (mk-live-obs 'Protoss 'Terran 9640
                 #:supply-used 72 #:supply-cap 110
                 #:ally-units stalkers12
                 #:ally-buildings base-bldgs-p
                 #:enemy-units '())
    'enable-opponent-world-model #t))
  (define ds3e (rt-door-state rt3e))
  (check-true "L35-T3e-anti-siege-persists-through-fog-via-owm"
              (hash-ref ds3e 'l35-siege-tempest-mass-hold? #f)
              (format "Expected OWM-remembered 6 Tanks to hold 24sup army even on 0-visible fog tick; hold=~a req=~a"
                      (hash-ref ds3e 'l35-siege-tempest-mass-hold? #f)
                      (hash-ref ds3e 'l35-siege-breakout-sup-req 0.0))))

;; =============================================================================
;; TEST 4: `#56` Defending Unsieged Tanks on High Ground Siege Cleanly!
;; =============================================================================
(let ()
  ;; Repro `#56`: 3 defending unsieged Siege Tanks at main ramp `(38.0, 32.5)` (`5.5t` from main CC),
  ;; while 6 enemy Tanks + 8 Marines (`>= 1400` val -> severely outgunned -> `l25-counter-volley-staging? = #t`!)
  ;; approach our natural at `(52.0, 32.5)` (`14.0t` from our Tanks, `4.5t` from natural CC `(56.5, 32.5)`).
  ;; Defending Tanks MUST emit `(cast-spell uid 'siege-mode)` instead of getting swallowed by
  ;; `ground-counter-volley-stage?` or `splash-evading-tags`!
  (define rt4 (make-live-bot-runtime #:race 'Terran))
  (define-values (acts4 _v4 _r4)
    (step-layer3-and-4-tactics!
     rt4
     (mk-live-obs 'Terran 'Terran 10200
                  #:supply-used 46 #:supply-cap 78
                  #:ally-units (list (mk-u 301 'siege-tank 38.0 32.5 #:hp 175.0)
                                     (mk-u 302 'siege-tank 38.0 34.0 #:hp 175.0)
                                     (mk-u 303 'siege-tank 38.0 31.0 #:hp 175.0)
                                     (mk-u 304 'marine 40.0 32.5 #:hp 45.0)
                                     (mk-u 305 'marine 40.0 33.5 #:hp 45.0))
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0)
                                         (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0))
                  #:enemy-units (append (for/list ([i (in-range 6)])
                                          (mk-u (+ 901 i) 'siege-tank-sieged (+ 52.0 (* 0.5 i)) 32.5 #:hp 175.0))
                                        (for/list ([i (in-range 8)])
                                          (mk-u (+ 921 i) 'marine (+ 51.5 (* 0.3 i)) (+ 31.0 (* 0.4 i)) #:hp 45.0))))
     0.0))
  (check-true "L35-T4a-defending-unsieged-tanks-siege-under-counter-volley-and-tank-push"
              (and (has-cast-spell-sym? acts4 301 'siege-mode)
                   (has-cast-spell-sym? acts4 302 'siege-mode)
                   (has-cast-spell-sym? acts4 303 'siege-mode))
              (format "Expected all 3 defending main-ramp Tanks to emit siege-mode; acts=~a" acts4)))

(printf "L35-RUNTIME-TESTS: ~a/~a PASSED (~a failed)\n"
        (- total-checks failed-checks)
        total-checks
        failed-checks)
(when (> failed-checks 0)
  (exit 1))
