#lang racket/base

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/tactics/order-ledger.rkt"
         "../lib/tactics/arena-minimax.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt")

;; =============================================================================
;; Loop 32 (`L32-P0-3`) Unit & Live-Runtime Regression Suite
;; Covers:
;;   1. Terran L2 Production Alignment (Factory #2, Starport #2..4, TvT Rax<=2, Air Vikings)
;;   2. Proactive Anti-Cloak Readiness (Terran OC 50e Scan Reserve >=3:30, Zerg Lair Overseer #1)
;;   3. Honest Arena `p11` Observer Lock-On (exclude det-cloak-cmds from plan-counter-burrow-response)
;;   4. Honest Arena `t04` Solo Ghost `2.0t` Snipe + Solo Step-Back (+ `novel-62` Cloak guard)
;;   5. Honest Arena `t02` `shorter-threat-closing?` (no kiting equal-speed Roaches; still kite slower/melee)
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
              #:w-cd [w-cd 0.0] #:flying? [flying? #f]
              #:build-progress [bp 1.0] #:order-count [oc 0]
              #:powered? [powered? #t] #:assigned-harvesters [ah 0]
              #:ideal-harvesters [ih 0])
  (hash 'id id 'type type 'x x 'y y
        'hp hp 'max-hp max-hp
        'shield shield 'shields shield 'max-shield max-shield 'max-shields max-shield
        'energy energy 'cloak cloak 'display-type 1
        'weapon-cooldown w-cd 'flying? flying? 'is-flying flying?
        'build-progress bp 'order-count oc 'order-ability-id 0
        'powered? powered?
        'assigned-harvesters ah 'ideal-harvesters ih))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 300]
                     #:gas [gas 150]
                     #:supply-used [su 48]
                     #:supply-cap [sc 70]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 56.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 140.0] #:enemy-y [ey 120.0]
                     #:upgrades [upgs '()]
                     #:mineral-patches [mp '()]
                     #:extra [extra (hash)])
  (define base-ht
    (hash 'race race 'enemy-race enemy-race 'frame frame
          'live-obs? #t 'live-game? #t
          'mineral-harvesters 28 'gas-harvesters 6
          'minerals minerals 'gas gas
          'supply-used su 'supply-cap sc
          'ally-units au 'ally-buildings ab
          'enemy-units eu 'enemy-buildings eb
          'base-x bx 'base-y by 'nat-x nx 'nat-y ny
          'enemy-x ex 'enemy-y ey
          'researched-upgrades upgs
          'mineral-patches mp
          'expansion-pads (list (cons 56.5 32.5) (cons 32.5 64.5) (cons 64.5 64.5))
          'map-width 168 'map-height 168))
  (for/fold ([h base-ht]) ([(k v) (in-hash extra)])
    (hash-set h k v)))

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
         (>= (length a) 2)
         (eq? (cadr a) sym))))

(define (mule-caster-ids acts)
  (for/list ([a (in-list acts)]
             #:when (and (pair? a)
                         (eq? (car a) 'cast-spell)
                         (>= (length a) 3)
                         (eq? (caddr a) 'calldown-mule)))
    (cadr a)))

(define (count-unit-cmds acts uids head-sym)
  (for/sum ([a (in-list acts)])
    (if (and (pair? a) (eq? (car a) head-sym) (>= (length a) 2))
        (let ([uarg (cadr a)])
          (cond
            [(list? uarg) (count (lambda (x) (memv x uids)) uarg)]
            [(memv uarg uids) 1]
            [else 0]))
        0)))

;; =============================================================================
;; TEST 1: Terran L2 Production Alignment (`#05/#17/#20/#29/#35` + `H2H #02`)
;; =============================================================================
(let ()
  (define scvs
    (for/list ([i (in-range 34)])
      (mk-u (+ 101 i) 'scv (+ 28.0 (* 0.2 i)) 32.0 #:hp 45.0)))
  (define marines
    (for/list ([i (in-range 8)])
      (mk-u (+ 201 i) 'marine (+ 44.0 (* 0.5 i)) 32.0 #:hp 45.0)))
  (define base-bldgs
    (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 13 'supply-depot 38.0 34.0 #:hp 400.0)
          (mk-u 14 'supply-depot 38.0 38.0 #:hp 400.0)
          (mk-u 15 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
          (mk-u 16 'barracks 41.0 36.0 #:hp 1000.0 #:order-count 1)
          (mk-u 17 'barracks-techlab 43.5 31.5 #:hp 400.0)
          (mk-u 18 'factory 41.0 40.0 #:hp 1250.0 #:order-count 1)
          (mk-u 19 'factory-techlab 43.5 39.5 #:hp 400.0)
          (mk-u 20 'starport 41.0 44.0 #:hp 1300.0 #:order-count 1)
          (mk-u 21 'refinery 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 22 'refinery 26.0 29.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 23 'refinery 50.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))

  ;; T1a: TvT 2-base at eff-phase-supply = 48 (< old 68 gate!), 240M/160G -> MUST emit Factory #2!
  (define rt1a (make-live-bot-runtime #:race 'Terran))
  (define obs1a
    (mk-live-obs 'Terran 'Terran 6200
                 #:minerals 240 #:gas 160 #:supply-used 48 #:supply-cap 78
                 #:upgrades '(stimpack)
                 #:ally-units (append scvs marines (list (mk-u 250 'siege-tank 46.0 32.0 #:hp 175.0)))
                 #:ally-buildings base-bldgs))
  (define acts1a (step-layer2-economy! rt1a obs1a))
  (check-true "L32-T1a-tvt-2base-sup48-builds-factory2"
              (has-build-sym? acts1a 'factory)
              (format "Expected 2nd Factory on 2b TvT sup=48; acts=~a" acts1a))

  ;; T1b: Terran vs >= 4 Banshees (`#20` mass-Banshee repro) -> MUST emit Starport #2 even w/ unresearched Stim!
  (define rt1b (make-live-bot-runtime #:race 'Terran))
  (define bldgs1b (cons (mk-u 24 'factory 46.0 40.0 #:hp 1250.0 #:order-count 1) base-bldgs))
  (define obs1b
    (mk-live-obs 'Terran 'Terran 8200
                 #:minerals 280 #:gas 180 #:supply-used 52 #:supply-cap 78
                 #:ally-units (append scvs marines
                                      (list (mk-u 250 'siege-tank 46.0 32.0 #:hp 175.0)
                                            (mk-u 251 'siege-tank 46.0 34.0 #:hp 175.0)))
                 #:ally-buildings bldgs1b
                 #:enemy-units (list (mk-u 901 'banshee 90.0 32.0 #:hp 140.0 #:flying? #t)
                                     (mk-u 902 'banshee 91.0 33.0 #:hp 140.0 #:flying? #t)
                                     (mk-u 903 'banshee 92.0 32.0 #:hp 140.0 #:flying? #t)
                                     (mk-u 904 'banshee 93.0 34.0 #:hp 140.0 #:flying? #t))))
  (define acts1b (step-layer2-economy! rt1b obs1b))
  (check-true "L32-T1b-vs-4-banshees-builds-starport2"
              (has-build-sym? acts1b 'starport)
              (format "Expected Starport #2 vs 4 Banshees; acts=~a" acts1b))

  ;; T1c: Terran vs >= 2 Colossi -> MUST emit Starport #2 even w/ unresearched Stim!
  (define rt1c (make-live-bot-runtime #:race 'Terran))
  (define obs1c
    (mk-live-obs 'Terran 'Protoss 9000
                 #:minerals 280 #:gas 180 #:supply-used 58 #:supply-cap 86
                 #:ally-units (append scvs marines
                                      (list (mk-u 250 'siege-tank 46.0 32.0 #:hp 175.0)
                                            (mk-u 251 'siege-tank 46.0 34.0 #:hp 175.0)))
                 #:ally-buildings bldgs1b
                 #:enemy-units (list (mk-u 911 'colossus 90.0 32.0 #:hp 200.0 #:shield 150.0)
                                     (mk-u 912 'colossus 92.0 34.0 #:hp 200.0 #:shield 150.0))))
  (define acts1c (step-layer2-economy! rt1c obs1c))
  (check-true "L32-T1c-vs-2-colossi-builds-starport2"
              (has-build-sym? acts1c 'starport)
              (format "Expected Starport #2 vs 2 Colossi; acts=~a" acts1c))

  ;; T1d: 3-base Terran at 380M (< old 600M gate!) -> MUST emit Starport #2!
  (define rt1d (make-live-bot-runtime #:race 'Terran))
  (define bldgs1d
    (append (list (mk-u 24 'factory 46.0 40.0 #:hp 1250.0 #:order-count 1)
                  (mk-u 25 'orbital-command 32.5 64.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 12 #:ideal-harvesters 16))
            base-bldgs))
  (define obs1d
    (mk-live-obs 'Terran 'Zerg 10500
                 #:minerals 380 #:gas 180 #:supply-used 68 #:supply-cap 94
                 #:upgrades '(stimpack combat-shield)
                 #:ally-units (append scvs marines
                                      (list (mk-u 250 'siege-tank 46.0 32.0 #:hp 175.0)
                                            (mk-u 251 'siege-tank 46.0 34.0 #:hp 175.0)))
                 #:ally-buildings bldgs1d))
  (define acts1d (step-layer2-economy! rt1d obs1d))
  (check-true "L32-T1d-3base-380M-builds-starport2"
              (has-build-sym? acts1d 'starport)
              (format "Expected Starport #2 on 3b at 380M; acts=~a" acts1d))

  ;; T1e: TvT `desired-barracks <= 2` cap until >= 2 Tanks or >= 2 Factories (min < 500)!
  (define rt1e (make-live-bot-runtime #:race 'Terran))
  (define obs1e
    (mk-live-obs 'Terran 'Terran 6400
                 #:minerals 360 #:gas 60 #:supply-used 46 #:supply-cap 78
                 #:ally-units (append scvs marines (list (mk-u 250 'siege-tank 46.0 32.0 #:hp 175.0)))
                 #:ally-buildings base-bldgs))
  (define acts1e (step-layer2-economy! rt1e obs1e))
  (check-true "L32-T1e-tvt-caps-rax-at-2-before-2-tanks-or-2-facs"
              (not (has-build-sym? acts1e 'barracks))
              (format "TvT with 1 Tank & 1 Factory at 360M must NOT build Barracks #3; acts=~a" acts1e))

  ;; T1f: Air-dominated Terran (`5` Banshees, `0` ground) with `5` Vikings (above old `4` cap) & idle Starport -> keeps training Viking!
  (define rt1f (make-live-bot-runtime #:race 'Terran))
  (define bldgs1f
    (append (list (mk-u 26 'starport 46.0 44.0 #:hp 1300.0 #:order-count 0)
                  (mk-u 27 'starport-techlab 43.5 43.5 #:hp 400.0)
                  (mk-u 28 'starport-reactor 48.5 43.5 #:hp 400.0))
            bldgs1b))
  (define obs1f
    (mk-live-obs 'Terran 'Terran 9600
                 #:minerals 300 #:gas 150 #:supply-used 66 #:supply-cap 94
                 #:upgrades '(stimpack combat-shield)
                 #:ally-units (append scvs marines
                                      (list (mk-u 250 'siege-tank 46.0 32.0 #:hp 175.0)
                                            (mk-u 251 'siege-tank 46.0 34.0 #:hp 175.0)
                                            (mk-u 255 'raven 45.0 30.0 #:hp 140.0 #:flying? #t)
                                            (mk-u 261 'viking-fighter 45.0 32.0 #:hp 135.0 #:flying? #t)
                                            (mk-u 262 'viking-fighter 45.0 33.0 #:hp 135.0 #:flying? #t)
                                            (mk-u 263 'viking-fighter 45.0 34.0 #:hp 135.0 #:flying? #t)
                                            (mk-u 264 'viking-fighter 45.0 35.0 #:hp 135.0 #:flying? #t)
                                            (mk-u 265 'viking-fighter 45.0 36.0 #:hp 135.0 #:flying? #t)))
                 #:ally-buildings bldgs1f
                 #:enemy-units (list (mk-u 901 'banshee 90.0 32.0 #:hp 140.0 #:flying? #t)
                                     (mk-u 902 'banshee 91.0 33.0 #:hp 140.0 #:flying? #t)
                                     (mk-u 903 'banshee 92.0 32.0 #:hp 140.0 #:flying? #t)
                                     (mk-u 904 'banshee 93.0 34.0 #:hp 140.0 #:flying? #t)
                                     (mk-u 905 'banshee 94.0 32.0 #:hp 140.0 #:flying? #t))))
  (define acts1f (step-layer2-economy! rt1f obs1f))
  (check-true "L32-T1f-air-dominated-keeps-training-vikings"
              (and (has-train-sym? acts1f 'viking)
                   (not (has-train-sym? acts1f 'medivac)))
              (format "Expected continuous Viking training (no Medivac leak) vs 5 Banshees; acts=~a" acts1f))

  ;; T1g: Proactive 3:45 (`f=5200`) TvP `engineering-bay` honored by L2 via `brain-sched-ebay-now?`!
  (define rt1g (make-live-bot-runtime #:race 'Terran))
  (define obs1g
    (mk-live-obs 'Terran 'Protoss 5200
                 #:minerals 200 #:gas 80 #:supply-used 42 #:supply-cap 62
                 #:upgrades '(stimpack)
                 #:ally-units (append scvs marines)
                 #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                        (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                        (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                        (mk-u 13 'supply-depot 38.0 34.0 #:hp 400.0)
                                        (mk-u 15 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
                                        (mk-u 16 'barracks 41.0 36.0 #:hp 1000.0 #:order-count 1)
                                        (mk-u 18 'factory 41.0 40.0 #:hp 1250.0 #:order-count 1)
                                        (mk-u 19 'factory-techlab 43.5 39.5 #:hp 400.0)
                                        (mk-u 21 'refinery 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                        (mk-u 22 'refinery 26.0 29.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3))))
  (define acts1g (step-layer2-economy! rt1g obs1g))
  (check-true "L32-T1g-proactive-345-tvp-ebay-honored-by-l2"
              (has-build-sym? acts1g 'engineering-bay)
              (format "Expected proactive 3:45 TvP Engineering Bay at f=5200; acts=~a" acts1g)))

;; =============================================================================
;; TEST 2: Proactive Anti-Cloak Readiness (`#40/#41` `CloakLoss -> 0`)
;; =============================================================================
(let ()
  (define patches
    (list (hash 'id 701 'x 27.0 'y 32.5 'mineral-contents 1200)
          (hash 'id 702 'x 61.0 'y 32.5 'mineral-contents 1200)))
  (define scvs (for/list ([i (in-range 28)]) (mk-u (+ 101 i) 'scv 29.0 32.0 #:hp 45.0)))
  (define base-t-bldgs
    (list (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0)))

  ;; T2a-1: Loop 74 Lane A: Frame 6800 (>= 5:00, 6720f) vs Protoss, 0 Ravens, 0 ready Turrets, 1 OC at 65e -> MUST HOLD 50e (no MULE)!
  (define rt-oc1 (make-live-bot-runtime #:race 'Terran))
  (define obs-oc1
    (mk-live-obs 'Terran 'Protoss 6800
                 #:minerals 100 #:gas 40 #:supply-used 34 #:supply-cap 54
                 #:ally-units scvs
                 #:ally-buildings (cons (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 65.0) base-t-bldgs)
                 #:mineral-patches patches))
  (define acts-oc1 (step-layer2-economy! rt-oc1 obs-oc1))
  (check-true "L32-T2a-oc-past-330-vs-protoss-reserves-50e-scan"
              (null? (mule-caster-ids acts-oc1))
              (format "Expected 1-OC at 65e past 5:00 vs Protoss to hold 50e for Scan; mules=~a" (mule-caster-ids acts-oc1)))

  ;; T2a-2: Same state at 105e -> DOES drop MULE (still retains 55e >= 50e for Scan!)
  (define rt-oc2 (make-live-bot-runtime #:race 'Terran))
  (define obs-oc2
    (mk-live-obs 'Terran 'Protoss 6800
                 #:minerals 100 #:gas 40 #:supply-used 34 #:supply-cap 54
                 #:ally-units scvs
                 #:ally-buildings (cons (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 105.0) base-t-bldgs)
                 #:mineral-patches patches))
  (define acts-oc2 (step-layer2-economy! rt-oc2 obs-oc2))
  (check-true "L32-T2a-oc-at-105e-still-drops-mule"
              (equal? (mule-caster-ids acts-oc2) '(10))
              (format "Expected OC at 105e to drop MULE (keeping 55e); mules=~a" (mule-caster-ids acts-oc2)))

  ;; T2a-3: L55-T9 / L56 R2: 3 OCs (OC1=75e, OC2=65e, OC3=60e) past 4:00 vs Protoss ->
  ;; top-2 OCs (OC1 & OC2) BOTH hold 50e for 2 back-to-back Scans, and OC3 drops MULE!
  (define rt-oc3 (make-live-bot-runtime #:race 'Terran))
  (define obs-oc3
    (mk-live-obs 'Terran 'Protoss 5600
                 #:minerals 100 #:gas 40 #:supply-used 34 #:supply-cap 54
                 #:ally-units scvs
                 #:ally-buildings (append (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 75.0)
                                                (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 65.0)
                                                (mk-u 14 'orbital-command 32.5 56.5 #:hp 1500.0 #:energy 60.0))
                                          base-t-bldgs)
                 #:mineral-patches patches))
  (define acts-oc3 (step-layer2-economy! rt-oc3 obs-oc3))
  (check-true "L32-T2a-2oc-highest-holds-scan-second-mules"
              (equal? (mule-caster-ids acts-oc3) '(14))
              (format "Expected OC1(75e) & OC2(65e) to reserve 2 Scans and OC3(60e, id=14) to MULE; mules=~a" (mule-caster-ids acts-oc3)))

  ;; T2a-4: Negative guard — ready Missile Turret exists -> OC at 65e drops MULE normally!
  (define rt-oc4 (make-live-bot-runtime #:race 'Terran))
  (define obs-oc4
    (mk-live-obs 'Terran 'Protoss 5000
                 #:minerals 100 #:gas 40 #:supply-used 34 #:supply-cap 54
                 #:ally-units scvs
                 #:ally-buildings (append (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 65.0)
                                                (mk-u 19 'missile-turret 35.0 35.0 #:hp 250.0))
                                          base-t-bldgs)
                 #:mineral-patches patches))
  (define acts-oc4 (step-layer2-economy! rt-oc4 obs-oc4))
  (check-true "L32-T2a-with-ready-turret-oc-mules-normally"
              (equal? (mule-caster-ids acts-oc4) '(10))
              (format "Expected OC with ready Turret to MULE at 65e; mules=~a" (mule-caster-ids acts-oc4)))

  ;; T2b: Zerg proactive Overseer #1 upon Lair completion vs Protoss (`min=60, gas=60, overseers=0`)!
  (define rt-z (make-live-bot-runtime #:race 'Zerg))
  (define drones (for/list ([i (in-range 28)]) (mk-u (+ 101 i) 'drone 29.0 32.0 #:hp 40.0)))
  (define obs-z
    (mk-live-obs 'Zerg 'Protoss 5400
                 #:minerals 60 #:gas 60 #:supply-used 40 #:supply-cap 54
                 #:ally-units (append drones
                                      (list (mk-u 201 'overlord 35.0 35.0 #:hp 200.0 #:flying? #t)
                                            (mk-u 202 'overlord 36.0 36.0 #:hp 200.0 #:flying? #t)
                                            (mk-u 203 'queen 34.0 32.0 #:hp 175.0)))
                 #:ally-buildings (list (mk-u 10 'lair 32.5 32.5 #:hp 2000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                        (mk-u 11 'hatchery 56.5 32.5 #:hp 1500.0 #:assigned-harvesters 12 #:ideal-harvesters 16)
                                        (mk-u 12 'spawning-pool 36.0 36.0 #:hp 1000.0)
                                        (mk-u 13 'extractor 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3))))
  (define acts-z (step-layer2-economy! rt-z obs-z))
  (check-true "L32-T2b-zerg-lair-proactive-overseer-vs-protoss"
              (has-morph-sym? acts-z 'overseer)
              (format "Expected proactive Overseer morph upon Lair completion vs Protoss at 60M/60G; acts=~a" acts-z)))

;; =============================================================================
;; TEST 3: Honest Arena `p11` Observer Lock-On (No `plan-counter-burrow-response` Overwrite!)
;; =============================================================================
(let ()
  (define stalker-ids '(301 302 303 304 305 306))
  (define obs-ids '(351 352))
  ;; T3a: Observers at x=25, Stalkers at x=26, undetected cloak=1 Banshees at x=38 ->
  ;; Observers must emit forward move (x > 26) and NEVER a second snap-back move toward x=26!
  (define obs-p11-adv
    (mk-live-obs 'Protoss 'Terran 120
                 #:ally-units (append
                               (for/list ([id (in-list stalker-ids)] [i (in-naturals)])
                                 (mk-u id 'stalker 26.0 (+ 29.0 (* 1.0 i)) #:hp 80.0 #:shield 80.0))
                               (list (mk-u 351 'observer 25.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t)
                                     (mk-u 352 'observer 24.5 33.5 #:hp 40.0 #:shield 20.0 #:flying? #t)))
                 #:enemy-units (list (mk-u 901 'banshee 38.0 31.0 #:hp 140.0 #:cloak 1 #:flying? #t)
                                     (mk-u 902 'banshee 38.5 32.5 #:hp 140.0 #:cloak 1 #:flying? #t))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define rt-p11a (make-live-bot-runtime #:race 'Protoss))
  (define acts-p11a (hash-ref (step-live-bot-runtime! rt-p11a obs-p11-adv) 'actions '()))
  (define obs-moves-a
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'move)
                   (let ([u (cadr a)])
                     (if (list? u) (ormap (lambda (x) (memv x obs-ids)) u) (memv u obs-ids)))))
            acts-p11a))
  (check-true "L32-T3a-p11-observers-advance-without-snapback"
              (and (pair? obs-moves-a)
                   (andmap (lambda (m) (> (caddr m) 29.0)) obs-moves-a))
              (format "Expected Observers to advance (>29.0) with zero snap-back; obs-moves=~a" obs-moves-a))

  ;; T3b: Observer #1 ALREADY arrived at x=33.5 (5.0t from detected cloak=2 Banshees at x=38.5),
  ;; while Stalkers sit back at x=22.0 -> `plan-counter-burrow-response` MUST NOT yank Observer back toward x=22!
  (define obs-p11-hold
    (mk-live-obs 'Protoss 'Terran 140
                 #:ally-units (append
                               (for/list ([id (in-list stalker-ids)] [i (in-naturals)])
                                 (mk-u id 'stalker 22.0 (+ 29.0 (* 1.0 i)) #:hp 80.0 #:shield 80.0))
                               (list (mk-u 351 'observer 33.5 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t)))
                 #:enemy-units (list (mk-u 901 'banshee 38.5 32.0 #:hp 140.0 #:cloak 2 #:flying? #t)
                                     (mk-u 902 'banshee 39.0 33.0 #:hp 140.0 #:cloak 2 #:flying? #t))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define rt-p11b (make-live-bot-runtime #:race 'Protoss))
  (define acts-p11b (hash-ref (step-live-bot-runtime! rt-p11b obs-p11-hold) 'actions '()))
  (define obs-yank-back?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'move)
                  (let ([u (cadr a)])
                    (if (list? u) (memv 351 u) (eqv? u 351)))
                  (< (caddr a) 32.0)))
           acts-p11b))
  (check-true "L32-T3b-p11-illuminating-observer-never-yanked-back"
              (not obs-yank-back?)
              (format "Observer at x=33.5 illuminating cloak=2 Banshees was yanked back! acts=~a" acts-p11b)))

;; =============================================================================
;; TEST 4: Honest Arena `t04` Solo Ghost `2.0t` Snipe + Solo Step-Back + `novel-62` Guard
;; =============================================================================
(let ()
  ;; T4a: Solo Ghost (Bio dead, ghost-cloak-researched?=#f), enemy at 2.6t (>2.0t), Ultra at 6.5t -> MUST SNIPE!
  (define dirs-solo-snipe
    (plan-terran-spellcaster-micro
     (list (mk-u 501 'ghost 26.5 32.0 #:hp 100.0 #:energy 100.0))
     (list (mk-u 961 'zergling 29.1 32.0 #:hp 35.0)
           (mk-u 951 'ultralisk 33.0 32.0 #:hp 500.0))
     #:claims (make-spell-claims)
     #:current-frame 300
     #:home-x 10.0 #:home-y 32.0
     #:ghost-cloak-researched? #f))
  (check-true "L32-T4a-solo-ghost-snipes-ultra-at-2.6t-melee"
              (ormap (lambda (d)
                       (and (= (spell-directive-caster-tag d) 501)
                            (eq? (spell-directive-ability d) 'steady-targeting)
                            (= (spell-directive-target-tag d) 951)))
                     dirs-solo-snipe)
              (format "Expected solo Ghost (no cloak) to Snipe Ultra at 2.6t melee; dirs=~a" dirs-solo-snipe))

  ;; T4b: Solo Ghost (Bio dead, bcnt=0), melee Zergling closes to 1.4t (< 2.0t) -> steps 2.2t away/home!
  (define dirs-solo-step
    (plan-terran-spellcaster-micro
     (list (mk-u 501 'ghost 26.5 32.0 #:hp 100.0 #:energy 100.0))
     (list (mk-u 962 'zergling 27.9 32.0 #:hp 35.0)
           (mk-u 951 'ultralisk 33.0 32.0 #:hp 500.0))
     #:claims (make-spell-claims)
     #:current-frame 300
     #:home-x 10.0 #:home-y 32.0
     #:ghost-cloak-researched? #f))
  (check-true "L32-T4b-solo-ghost-steps-2.2t-back-under-2.0t-melee"
              (ormap (lambda (d)
                       (and (= (spell-directive-caster-tag d) 501)
                            (eq? (spell-directive-pattern-name d) 'ghost-melee-step-back)
                            (eq? (spell-directive-target-mode d) 'move)
                            (< (spell-directive-target-x d) 25.0)))
                     dirs-solo-step)
              (format "Expected solo Ghost step-back (<25.0) at 1.4t melee; dirs=~a" dirs-solo-step))

  ;; T4c: Negative guard (`novel-62`): Solo Ghost WITH personal-cloaking & Ultra at 3.8t -> casts CLOAK first!
  (define dirs-n62
    (plan-terran-spellcaster-micro
     (list (mk-u 501 'ghost 26.5 32.0 #:hp 100.0 #:energy 100.0))
     (list (mk-u 951 'ultralisk 30.3 32.0 #:hp 500.0))
     #:claims (make-spell-claims)
     #:current-frame 300
     #:home-x 10.0 #:home-y 32.0
     #:ghost-cloak-researched? #t))
  (check-true "L32-T4c-novel62-ghost-with-cloak-still-cloaks-first"
              (ormap (lambda (d)
                       (and (= (spell-directive-caster-tag d) 501)
                            (eq? (spell-directive-ability d) 'cloak-ghost)))
                     dirs-n62)
              (format "Expected cloak-researched Ghost at 3.8t from Ultra to cast cloak-ghost; dirs=~a" dirs-n62)))

;; =============================================================================
;; TEST 5: Arena Minimax Ranged Stutter/Regroup Discipline (Updated for L33 Revert)
;; =============================================================================
(let ()
  ;; T5a: L33-P0-3 reverted L32's equal-speed `DisengageRetreat` override so outnumbered equal-speed
  ;; ranged squads on cooldown (`w-cd=0.45`) disengage/regroup instead of suiciding!
  (define m-ids '(601 602 603 604 605 606))
  (define obs-t02
    (mk-live-obs 'Terran 'Zerg 200
                 #:ally-units (append
                               (for/list ([id (in-list m-ids)] [i (in-naturals)])
                                 (mk-u id 'marine 28.0 (+ 30.0 (* 0.8 i)) #:hp 45.0 #:w-cd 0.45))
                               (list (mk-u 611 'siege-tank-sieged 24.5 31.5 #:hp 175.0)
                                     (mk-u 612 'siege-tank-sieged 24.5 33.0 #:hp 175.0)))
                 #:enemy-units (for/list ([i (in-range 8)])
                                 (mk-u (+ 920 i) 'roach 31.8 (+ 29.5 (* 0.8 i)) #:hp 145.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-t02 (make-tactical-mirror-brain))
  (define-values (acts-t02 _t _d)
    (step-tactical-mirror-brain! tb-t02 (make-order-ledger) obs-t02 #:record-ledger? #f))
  (check-true "L32-T5a-equal-speed-disengage-retreat-regroups-on-cooldown"
              (>= (count-unit-cmds acts-t02 m-ids 'kite) 4)
              (format "Expected outnumbered equal-speed Marines on cooldown to kite/regroup under DisengageRetreat; acts=~a" acts-t02))

  ;; T5a2: Under `StutterKiteBack` (`6 Marines vs 4 Roaches`), L33 restored `shorter-threat-closing?`
  ;; so longer-range units (`5r > 4r`) stutter-kite shorter-range threats while on cooldown!
  (define obs-t02-skb
    (mk-live-obs 'Terran 'Zerg 200
                 #:ally-units (for/list ([id (in-list m-ids)] [i (in-naturals)])
                                (mk-u id 'marine 28.0 (+ 30.0 (* 0.8 i)) #:hp 45.0 #:w-cd 0.45))
                 #:enemy-units (for/list ([i (in-range 4)])
                                 (mk-u (+ 930 i) 'roach 31.8 (+ 29.5 (* 0.8 i)) #:hp 145.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-t02-skb (make-tactical-mirror-brain))
  (define-values (acts-t02-skb _tskb decs-t02-skb)
    (step-tactical-mirror-brain! tb-t02-skb (make-order-ledger) obs-t02-skb #:record-ledger? #f))
  (check-true "L32-T5a2-stutterkiteback-kites-shorter-range-on-cooldown"
              (and (pair? decs-t02-skb)
                   (eq? (hash-ref (car decs-t02-skb) 'committed-action #f) 'StutterKiteBack)
                   (>= (count-unit-cmds acts-t02-skb m-ids 'kite) 4))
              (format "Expected StutterKiteBack to stutter-kite shorter-range Roaches on cooldown; decs=~a acts=~a" decs-t02-skb acts-t02-skb))

  ;; T5b: Negative guard — Faster Stalkers (6r, spd=4.13, w-cd=1.00) vs slower Roaches (4r, spd=3.15) at 4.5t
  ;; STILL kite slower Roaches when minimax selects StutterKiteBack (e.g. slightly outnumbered)!
  (define s-ids '(621 622 623 624))
  (define obs-st-roach
    (mk-live-obs 'Protoss 'Zerg 200
                 #:ally-units (for/list ([id (in-list s-ids)] [i (in-naturals)])
                                (mk-u id 'stalker 28.0 (+ 30.5 (* 0.8 i)) #:hp 80.0 #:shield 80.0 #:w-cd 1.00))
                 #:enemy-units (for/list ([i (in-range 6)])
                                 (mk-u (+ 940 i) 'roach 32.5 (+ 30.0 (* 0.7 i)) #:hp 145.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-sr (make-tactical-mirror-brain))
  (define-values (acts-sr _t2 _d2)
    (step-tactical-mirror-brain! tb-sr (make-order-ledger) obs-st-roach #:record-ledger? #f))
  (check-true "L32-T5b-faster-stalkers-still-kite-slower-roaches"
              (>= (count-unit-cmds acts-sr s-ids 'kite) 3)
              (format "Expected faster Stalkers (4.13) on w-cd=1.00 to kite slower Roaches (3.15); acts=~a" acts-sr))

  ;; T5c: Negative guard — Marines on cooldown (w-cd=0.45) vs melee Zerglings (e-wr=0.1 <= 1.5) STILL tight-stutter!
  (define obs-m-ling
    (mk-live-obs 'Terran 'Zerg 200
                 #:ally-units (for/list ([id (in-list m-ids)] [i (in-naturals)])
                                (mk-u id 'marine 28.0 (+ 30.0 (* 0.8 i)) #:hp 45.0 #:w-cd 0.45))
                 #:enemy-units (for/list ([i (in-range 14)])
                                 (mk-u (+ 960 i) 'zergling 30.8 (+ 29.5 (* 0.4 i)) #:hp 35.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-ml (make-tactical-mirror-brain))
  (define-values (acts-ml _t3 _d3)
    (step-tactical-mirror-brain! tb-ml (make-order-ledger) obs-m-ling #:record-ledger? #f))
  (check-true "L32-T5c-marines-still-stutter-vs-melee-zerglings"
              (>= (count-unit-cmds acts-ml m-ids 'kite) 4)
              (format "Expected Marines on w-cd=0.45 to keep tight-stuttering melee Zerglings; acts=~a" acts-ml)))

(printf "L32-RUNTIME-ARENA-TESTS: ~a/~a PASSED (~a failed)\n"
        (- total-checks failed-checks) total-checks failed-checks)
(when (> failed-checks 0)
  (exit 1))
