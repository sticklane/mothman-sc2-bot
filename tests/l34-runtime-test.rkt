#lang racket/base

(require racket/list
         racket/match
         "../lib/bot-runtime.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/tactics/order-ledger.rkt")

;; =============================================================================
;; Loop 34 (`L34-P0-3`) Live-Runtime Economy & Anti-Cloak Regression Suite
;; Covers:
;;   1. Decoupled emergency `missile-turret` (`100M`) from EBay (`125M`)/Orbital/Expand locks (`#74`)
;;   2. Protect Siege Tank #1/#2 from Factory #2 gas theft (`#77`) + Factory #2 TechLab + TvT Air-Dom cap (`#02`)
;;   3. Proactive Zerg `3:45` ZvP Spore Crawler emission (`#73`) + negative guards
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

;; =============================================================================
;; TEST 1: Decoupled Emergency `missile-turret` (`100M`) from EBay/Orbital/Expand Locks
;; =============================================================================
(let ()
  (define scvs (for/list ([i (in-range 28)]) (mk-u (+ 101 i) 'scv 29.0 32.0 #:hp 45.0)))
  (define marines (for/list ([i (in-range 8)]) (mk-u (+ 151 i) 'marine 44.0 32.0 #:hp 45.0)))

  ;; T1a (`#74` repro): Ready Engineering Bay, `105M` (< 125M EBay cost!), unmorphed CC #2
  ;; (`terran-saving-for-orbital? = #t`!), cloaked Banshee sighted -> MUST build `missile-turret`!
  (define rt1a (make-live-bot-runtime #:race 'Terran))
  (define acts1a
    (step-layer2-economy!
     rt1a
     (mk-live-obs 'Terran 'Terran 5968
                  #:minerals 105 #:gas 147 #:supply-used 42 #:supply-cap 62
                  #:ally-units (append scvs marines)
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'command-center 56.5 32.5 #:hp 1500.0 #:assigned-harvesters 12 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
                                         (mk-u 14 'engineering-bay 37.5 28.5 #:hp 850.0))
                  #:enemy-units (list (mk-u 901 'banshee 90.0 32.0 #:hp 140.0 #:cloak 1 #:flying? #t)))))
  (check-true "L34-T1a-emergency-turret-builds-at-105M-despite-orbital-save"
              (has-build-sym? acts1a 'missile-turret)
              (format "Expected missile-turret at 105M w/ ready EBay & unmorphed CC vs Banshee; acts=~a" acts1a))

  ;; T1b: Ready Engineering Bay, `110M` (< 125M), 1-base saving for expand, DT sighted -> MUST build `missile-turret`!
  (define rt1b (make-live-bot-runtime #:race 'Terran))
  (define acts1b
    (step-layer2-economy!
     rt1b
     (mk-live-obs 'Terran 'Protoss 5600
                  #:minerals 110 #:gas 60 #:supply-used 32 #:supply-cap 46
                  #:ally-units (append (take scvs 20) marines)
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
                                         (mk-u 14 'engineering-bay 37.5 28.5 #:hp 850.0))
                  #:enemy-units (list (mk-u 902 'dark-templar 80.0 32.0 #:hp 40.0 #:shield 80.0 #:cloak 1)))))
  (check-true "L34-T1b-emergency-turret-builds-at-110M-despite-expand-save"
              (has-build-sym? acts1b 'missile-turret)
              (format "Expected missile-turret at 110M w/ ready EBay on 1-base vs DT; acts=~a" acts1b))

  ;; T1c (Negative guard): Peaceful TvT with 0 cloak/air threats, 1 Tank (< 2), ready Factory TechLab,
  ;; ready EBay, 160M/130G -> MUST train Siege Tank #2 and NOT waste minerals on speculative Turret!
  (define rt1c (make-live-bot-runtime #:race 'Terran))
  (define acts1c
    (step-layer2-economy!
     rt1c
     (mk-live-obs 'Terran 'Terran 6200
                  #:minerals 160 #:gas 130 #:supply-used 46 #:supply-cap 78
                  #:upgrades '(stimpack)
                  #:ally-units (append scvs marines (list (mk-u 250 'siege-tank 46.0 32.0 #:hp 175.0)))
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:order-count 1 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 20.0 #:order-count 1 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
                                         (mk-u 21 'barracks 41.0 36.0 #:hp 1000.0 #:order-count 1)
                                         (mk-u 22 'barracks-techlab 43.5 31.5 #:hp 400.0)
                                         (mk-u 14 'engineering-bay 37.5 28.5 #:hp 850.0)
                                         (mk-u 15 'factory 41.0 40.0 #:hp 1250.0 #:order-count 0)
                                         (mk-u 16 'factory-techlab 43.5 39.5 #:hp 400.0)
                                         (mk-u 17 'starport 41.0 44.0 #:hp 1300.0 #:order-count 1)
                                         (mk-u 18 'refinery 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                         (mk-u 19 'refinery 26.0 29.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                         (mk-u 20 'refinery 50.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3))
                  #:enemy-units (list (mk-u 905 'marine 90.0 32.0 #:hp 45.0)))))
  (check-true "L34-T1c-no-speculative-turret-ahead-of-tvt-tank2"
              (and (not (has-build-sym? acts1c 'missile-turret))
                   (has-train-sym? acts1c 'siege-tank))
              (format "Expected Tank #2 (no speculative turret) in peaceful TvT at 160M/130G; acts=~a" acts1c)))

;; =============================================================================
;; TEST 2: Siege Tank #1/#2 Protection + Factory #2 TechLab + TvT Air-Dom Cap
;; =============================================================================
(let ()
  (define scvs (for/list ([i (in-range 34)]) (mk-u (+ 201 i) 'scv 29.0 32.0 #:hp 45.0)))
  (define marines (for/list ([i (in-range 8)]) (mk-u (+ 251 i) 'marine 44.0 32.0 #:hp 45.0)))
  (define tvt-base-bldgs
    (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:order-count 1 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 20.0 #:order-count 1 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 13 'supply-depot 38.0 34.0 #:hp 400.0)
          (mk-u 14 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
          (mk-u 15 'barracks 41.0 36.0 #:hp 1000.0 #:order-count 1)
          (mk-u 16 'barracks-techlab 43.5 31.5 #:hp 400.0)
          (mk-u 17 'factory 41.0 40.0 #:hp 1250.0 #:order-count 0)
          (mk-u 18 'factory-techlab 43.5 39.5 #:hp 400.0)
          (mk-u 19 'starport 41.0 44.0 #:hp 1300.0 #:order-count 1)
          (mk-u 20 'refinery 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 21 'refinery 26.0 29.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 28 'refinery 50.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))

  ;; T2a (`#77` repro): TvT `f=5424`, `160M/127G`, 1 Factory + ready `factory-techlab`, `0` Tanks ->
  ;; Factory #2 MUST yield so Siege Tank #1 trains immediately!
  (define rt2a (make-live-bot-runtime #:race 'Terran))
  (define acts2a
    (step-layer2-economy!
     rt2a
     (mk-live-obs 'Terran 'Terran 5424
                  #:minerals 160 #:gas 127 #:supply-used 46 #:supply-cap 70
                  #:upgrades '(stimpack)
                  #:ally-units (append scvs marines)
                  #:ally-buildings tvt-base-bldgs
                  #:enemy-units (list (mk-u 910 'marine 90.0 32.0 #:hp 45.0)))))
  (check-true "L34-T2a-factory2-yields-to-siege-tank1-at-160M-127G"
              (and (not (has-build-sym? acts2a 'factory))
                   (has-train-sym? acts2a 'siege-tank))
              (format "Expected Factory #2 to yield to Siege Tank #1 at 160M/127G; acts=~a" acts2a))

  ;; T2b: Same state at `320M/240G` (can afford BOTH Tank #1 & Factory #2!) -> builds Factory #2 AND trains Tank #1!
  (define rt2b (make-live-bot-runtime #:race 'Terran))
  (define acts2b
    (step-layer2-economy!
     rt2b
     (mk-live-obs 'Terran 'Terran 5424
                  #:minerals 320 #:gas 240 #:supply-used 46 #:supply-cap 70
                  #:upgrades '(stimpack)
                  #:ally-units (append scvs marines)
                  #:ally-buildings tvt-base-bldgs
                  #:enemy-units (list (mk-u 910 'marine 90.0 32.0 #:hp 45.0)))))
  (check-true "L34-T2b-builds-factory2-and-tank1-when-320M-240G-banked"
              (and (has-build-sym? acts2b 'factory)
                   (has-train-sym? acts2b 'siege-tank))
              (format "Expected BOTH Factory #2 and Siege Tank #1 at 320M/240G; acts=~a" acts2b))

  ;; T2c (`#02` repro): TvT with 2 Factories (Fac #1 has TechLab, Fac #2 is bare & idle) at `90M/50G` ->
  ;; MUST attach `factory-techlab` onto bare Factory #2!
  (define rt2c (make-live-bot-runtime #:race 'Terran))
  (define bldgs2c
    (cons (mk-u 22 'factory 48.0 40.0 #:hp 1250.0 #:order-count 0)
          (map (lambda (b) (if (= (hash-ref b 'id) 17) (hash-set b 'order-count 1) b))
               tvt-base-bldgs)))
  (define acts2c
    (step-layer2-economy!
     rt2c
     (mk-live-obs 'Terran 'Terran 6800
                  #:minerals 90 #:gas 50 #:supply-used 52 #:supply-cap 78
                  #:upgrades '(stimpack)
                  #:ally-units (append scvs marines (list (mk-u 260 'siege-tank 46.0 32.0 #:hp 175.0)))
                  #:ally-buildings bldgs2c
                  #:enemy-units (list (mk-u 910 'siege-tank 90.0 32.0 #:hp 175.0)))))
  (check-true "L34-T2c-tvt-factory2-attaches-techlab-immediately"
              (has-build-sym? acts2c 'factory-techlab)
              (format "Expected bare Factory #2 in TvT to attach factory-techlab; acts=~a" acts2c))

  ;; T2d (`#02` repro): TvT 3-base with 2 Starports facing enemy grounded Tank+Bio core
  ;; (`5` Siege Tanks + `8` Marines + `6` Vikings, `0` capital air) & already `8` Vikings ->
  ;; MUST cap Starports `<= 2` (no Starport #3) and NOT train Viking #9!
  (define rt2d (make-live-bot-runtime #:race 'Terran))
  (define bldgs2d
    (append (list (mk-u 22 'factory 48.0 40.0 #:hp 1250.0 #:order-count 1)
                  (mk-u 23 'factory-techlab 50.5 39.5 #:hp 400.0)
                  (mk-u 24 'orbital-command 32.5 64.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 14 #:ideal-harvesters 16)
                  (mk-u 25 'starport 48.0 44.0 #:hp 1300.0 #:order-count 0)
                  (mk-u 26 'starport-reactor 50.5 43.5 #:hp 400.0)
                  (mk-u 27 'engineering-bay 37.5 28.5 #:hp 850.0))
            (map (lambda (b) (if (= (hash-ref b 'id) 17) (hash-set b 'order-count 1) b))
                 tvt-base-bldgs)))
  (define eight-vikings
    (for/list ([i (in-range 8)])
      (mk-u (+ 271 i) 'viking-fighter 45.0 (+ 30.0 (* 0.5 i)) #:hp 135.0 #:flying? #t)))
  (define enemy-tank-bio-air
    (append (for/list ([i (in-range 5)]) (mk-u (+ 921 i) 'siege-tank-sieged 95.0 (+ 30.0 (* 1.0 i)) #:hp 175.0))
            (for/list ([i (in-range 8)]) (mk-u (+ 931 i) 'marine 92.0 (+ 29.0 (* 0.5 i)) #:hp 45.0))
            (for/list ([i (in-range 6)]) (mk-u (+ 941 i) 'viking-fighter 94.0 (+ 30.0 (* 0.6 i)) #:hp 135.0 #:flying? #t))))
  (define acts2d
    (step-layer2-economy!
     rt2d
     (mk-live-obs 'Terran 'Terran 11000
                  #:minerals 420 #:gas 250 #:supply-used 84 #:supply-cap 110
                  #:upgrades '(stimpack combat-shield)
                  #:ally-units (append scvs marines eight-vikings
                                       (list (mk-u 260 'siege-tank 46.0 32.0 #:hp 175.0)
                                             (mk-u 261 'siege-tank 46.0 34.0 #:hp 175.0)
                                             (mk-u 262 'medivac 45.0 32.0 #:hp 150.0 #:flying? #t)
                                             (mk-u 263 'medivac 45.0 34.0 #:hp 150.0 #:flying? #t)))
                  #:ally-buildings bldgs2d
                  #:enemy-units enemy-tank-bio-air)))
  (check-true "L34-T2d-tvt-tank-bio-core-caps-starports-at-2-and-vikings-at-8"
              (and (not (has-build-sym? acts2d 'starport))
                   (not (has-train-sym? acts2d 'viking)))
              (format "Expected TvT vs 5 Tanks + 8 Marines + 6 Vikings to cap Starports<=2 and Vikings<=8; acts=~a" acts2d))

  ;; T2e (Negative guard): Pure mass Banshees (`6` Banshees, `0` Tanks) on 3 bases with 2 Starports ->
  ;; STILL builds Starport #3!
  (define rt2e (make-live-bot-runtime #:race 'Terran))
  (define acts2e
    (step-layer2-economy!
     rt2e
     (mk-live-obs 'Terran 'Terran 11000
                  #:minerals 420 #:gas 250 #:supply-used 84 #:supply-cap 110
                  #:upgrades '(stimpack combat-shield)
                  #:ally-units (append scvs marines eight-vikings
                                       (list (mk-u 260 'siege-tank 46.0 32.0 #:hp 175.0)
                                             (mk-u 261 'siege-tank 46.0 34.0 #:hp 175.0)))
                  #:ally-buildings bldgs2d
                  #:enemy-units (for/list ([i (in-range 6)])
                                  (mk-u (+ 961 i) 'banshee 94.0 (+ 30.0 (* 0.8 i)) #:hp 140.0 #:flying? #t)))))
  (check-true "L34-T2e-pure-mass-banshees-still-scales-starport3"
              (has-build-sym? acts2e 'starport)
              (format "Expected 3rd Starport vs 6 pure Banshees (0 Tanks); acts=~a" acts2e)))

;; =============================================================================
;; TEST 3: Proactive Zerg `3:45` ZvP Spore Crawler Emission (`#73` `CloakLoss -> 0`)
;; =============================================================================
(let ()
  (define drones (for/list ([i (in-range 30)]) (mk-u (+ 301 i) 'drone 29.0 32.0 #:hp 40.0)))
  (define base-z-units
    (append drones
            (list (mk-u 351 'overlord 35.0 35.0 #:hp 200.0 #:flying? #t)
                  (mk-u 352 'overlord 36.0 36.0 #:hp 200.0 #:flying? #t)
                  (mk-u 353 'queen 34.0 32.0 #:hp 175.0)
                  (mk-u 354 'queen 56.0 32.0 #:hp 175.0)
                  (mk-u 361 'zergling 42.0 32.0 #:hp 35.0)
                  (mk-u 362 'zergling 42.5 32.0 #:hp 35.0)
                  (mk-u 363 'zergling 43.0 32.0 #:hp 35.0)
                  (mk-u 364 'zergling 43.5 32.0 #:hp 35.0))))
  (define base-z-bldgs
    (list (mk-u 10 'hatchery 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'hatchery 56.5 32.5 #:hp 1500.0 #:assigned-harvesters 14 #:ideal-harvesters 16)
          (mk-u 12 'spawning-pool 36.0 36.0 #:hp 1000.0)
          (mk-u 13 'extractor 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))

  ;; T3a (`#73` repro): ZvP at `f=5000` (`3:43`), 2 Hatches, ready Pool, NO Lair, 0 Overseers, 0 Spores,
  ;; 0 visible cloaked/air enemies, `100M/40G` -> MUST build proactive Spore Crawler!
  (define rt3a (make-live-bot-runtime #:race 'Zerg))
  (define acts3a
    (step-layer2-economy!
     rt3a
     (mk-live-obs 'Zerg 'Protoss 5000
                  #:minerals 100 #:gas 40 #:supply-used 42 #:supply-cap 58
                  #:ally-units base-z-units
                  #:ally-buildings base-z-bldgs
                  #:enemy-units '())))
  (check-true "L34-T3a-zvp-proactive-345-spore-crawler-emits-without-visible-cloak"
              (has-build-sym? acts3a 'spore-crawler)
              (format "Expected proactive ZvP Spore Crawler at f=5000 w/ no Lair & no Overseer; acts=~a" acts3a))

  ;; T3b (Negative guard): ZvP at `f=5000`, Lair IS ready + `1` Overseer already exists, 0 visible cloak/air ->
  ;; MUST NOT build unnecessary proactive Spore!
  (define rt3b (make-live-bot-runtime #:race 'Zerg))
  (define acts3b
    (step-layer2-economy!
     rt3b
     (mk-live-obs 'Zerg 'Protoss 5000
                  #:minerals 100 #:gas 40 #:supply-used 42 #:supply-cap 58
                  #:ally-units (cons (mk-u 370 'overseer 40.0 32.0 #:hp 200.0 #:flying? #t) base-z-units)
                  #:ally-buildings (cons (mk-u 10 'lair 32.5 32.5 #:hp 2000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (cdr base-z-bldgs))
                  #:enemy-units '())))
  (check-true "L34-T3b-zvp-with-ready-lair-and-overseer-skips-proactive-spore"
              (not (has-build-sym? acts3b 'spore-crawler))
              (format "Expected NO proactive Spore when Lair + Overseer already ready; acts=~a" acts3b))

  ;; T3c (Negative guard): ZvZ at `f=5000`, no Lair, 0 Spores, 0 visible cloak/air -> MUST NOT emit proactive ZvP Spore!
  (define rt3c (make-live-bot-runtime #:race 'Zerg))
  (define acts3c
    (step-layer2-economy!
     rt3c
     (mk-live-obs 'Zerg 'Zerg 5000
                  #:minerals 100 #:gas 40 #:supply-used 42 #:supply-cap 58
                  #:ally-units base-z-units
                  #:ally-buildings base-z-bldgs
                  #:enemy-units '())))
  (check-true "L34-T3c-zvz-does-not-emit-proactive-zvp-spore"
              (not (has-build-sym? acts3c 'spore-crawler))
              (format "Expected NO proactive ZvP Spore in ZvZ w/ 0 air/cloak; acts=~a" acts3c)))

(printf "L34-RUNTIME-TESTS: ~a/~a PASSED (~a failed)\n"
        (- total-checks failed-checks) total-checks failed-checks)
(when (> failed-checks 0)
  (exit 1))
