#lang racket/base

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/tactics/order-ledger.rkt"
         "../lib/tactics/arena-minimax.rkt")

;; =============================================================================
;; Loop 33 (`L33-P0-3`) Unit & Live-Runtime Regression Suite
;; Covers:
;;   1. Revert L32 equal-speed `DisengageRetreat` & `StutterKiteBack` suicide regression
;;   2. Remembered/`owm` Corruptor Volley Latch (`#58` fog flicker) + Isolated Phoenix/Colossus Regroup (`#18`)
;;   3. Fix `#73` sole `CloakLoss`: `zerg-proactive-overseer1?` waives Spire/Corruptor lock (keeps BC guard!)
;;   4. Honest Arena `t02`: Bio `2.5x` target priority on melee rushers `<= 6.5t` of friendly Sieged Tanks
;;   5. Honest Arena `p01`: Melee-engaged ranged focus-fire on lowest-HP enemy Bio (0 Stalker backward-kite!)
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
          'natural-x nx 'natural-y ny
          'enemy-x ex 'enemy-y ey
          'researched-upgrades upgs
          'expansion-pads (list (cons 56.5 32.5) (cons 32.5 64.5) (cons 64.5 64.5))
          'map-width 168 'map-height 168))
  (for/fold ([h base-ht]) ([(k v) (in-hash extra)])
    (hash-set h k v)))

(define (count-unit-cmds acts uids head-sym)
  (for/sum ([a (in-list acts)])
    (if (and (pair? a) (eq? (car a) head-sym) (>= (length a) 2))
        (let ([uarg (cadr a)])
          (cond
            [(list? uarg) (count (lambda (x) (memv x uids)) uarg)]
            [(memv uarg uids) 1]
            [else 0]))
        0)))

(define (unit-attack-targets acts uids)
  (for/list ([a (in-list acts)]
             #:when (and (pair? a) (eq? (car a) 'attack-unit)
                         (>= (length a) 3) (memv (cadr a) uids)))
    (caddr a)))

(define (has-morph-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a) (eq? (car a) 'morph) (>= (length a) 2) (eq? (cadr a) sym))))

(define (has-train-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a) (memq (car a) '(train train-unit)) (>= (length a) 2) (eq? (cadr a) sym))))

;; =============================================================================
;; TEST 1: Revert L32 Equal-Speed `DisengageRetreat` & `StutterKiteBack`
;; =============================================================================
(let ()
  ;; T1a: Outnumbered equal-speed Hydralisks (6r, spd=3.15, w-cd=0.45) vs Roaches (4r, spd=3.15)
  ;; under DisengageRetreat -> MUST kite/regroup instead of suicidal commit-fire!
  (define h-ids '(101 102 103 104 105))
  (define obs-hr
    (mk-live-obs 'Zerg 'Zerg 300
                 #:ally-units (for/list ([id (in-list h-ids)] [i (in-naturals)])
                                (mk-u id 'hydralisk 28.0 (+ 30.0 (* 0.9 i)) #:hp 90.0 #:w-cd 0.45))
                 #:enemy-units (for/list ([i (in-range 12)])
                                 (mk-u (+ 901 i) 'roach 32.0 (+ 28.5 (* 0.6 i)) #:hp 145.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-hr _t1 decs-hr)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-hr
                                 #:record-ledger? #f #:combat-should-engage? #f))
  (check-true "L33-T1a-outnumbered-hydras-vs-equal-speed-roaches-retreat-on-cd"
              (and (pair? decs-hr)
                   (eq? (hash-ref (car decs-hr) 'committed-action #f) 'DisengageRetreat)
                   (>= (count-unit-cmds acts-hr h-ids 'kite) 4))
              (format "Expected outnumbered Hydras (6r) vs Roaches (4r) to kite/regroup; decs=~a acts=~a" decs-hr acts-hr))

  ;; T1b: Outnumbered equal-speed Immortals (6r, spd=3.15, w-cd=0.75) vs Marines (5r, spd=3.15)
  ;; under DisengageRetreat -> MUST kite/regroup instead of suiciding!
  (define i-ids '(111 112 113 114))
  (define obs-im
    (mk-live-obs 'Protoss 'Terran 300
                 #:ally-units (for/list ([id (in-list i-ids)] [i (in-naturals)])
                                (mk-u id 'immortal 28.0 (+ 30.0 (* 1.1 i)) #:hp 200.0 #:shield 100.0 #:w-cd 0.75))
                 #:enemy-units (for/list ([i (in-range 16)])
                                 (mk-u (+ 921 i) 'marine 32.5 (+ 28.5 (* 0.5 i)) #:hp 45.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-im _t2 decs-im)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-im
                                 #:record-ledger? #f #:combat-should-engage? #f))
  (check-true "L33-T1b-outnumbered-immortals-vs-equal-speed-marines-retreat-on-cd"
              (and (pair? decs-im)
                   (eq? (hash-ref (car decs-im) 'committed-action #f) 'DisengageRetreat)
                   (>= (count-unit-cmds acts-im i-ids 'kite) 3))
              (format "Expected outnumbered Immortals vs Marines on w-cd to kite/regroup; decs=~a acts=~a" decs-im acts-im))

  ;; T1c: Hydralisks (6r, w-cd=0.45) vs shorter-range Roaches (4r) under StutterKiteBack -> stutters cleanly!
  (define obs-hr-skb
    (mk-live-obs 'Zerg 'Zerg 300
                 #:ally-units (for/list ([id (in-list h-ids)] [i (in-naturals)])
                                (mk-u id 'hydralisk 28.0 (+ 30.0 (* 0.9 i)) #:hp 90.0 #:w-cd 0.45))
                 #:enemy-units (for/list ([i (in-range 5)])
                                 (mk-u (+ 941 i) 'roach 32.0 (+ 29.5 (* 0.8 i)) #:hp 145.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-hr-skb _t3 decs-hr-skb)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-hr-skb
                                 #:record-ledger? #f))
  (check-true "L33-T1c-hydras-stutter-kite-shorter-range-roaches"
              (>= (count-unit-cmds acts-hr-skb h-ids 'kite) 4)
              (format "Expected Hydras on w-cd=0.45 to stutter-kite shorter-range Roaches; decs=~a acts=~a" decs-hr-skb acts-hr-skb))

  ;; T1d: Negative guard (`t07`): Marines (5r, spd=3.15) vs faster/longer-range Stalkers (6r, spd=4.13)
  ;; under DisengageRetreat STILL commit-fire (`0` kites)!
  (define m-ids '(121 122 123 124 125 126))
  (define obs-ms
    (mk-live-obs 'Terran 'Protoss 300
                 #:ally-units (for/list ([id (in-list m-ids)] [i (in-naturals)])
                                (mk-u id 'marine 28.0 (+ 30.0 (* 0.7 i)) #:hp 45.0 #:w-cd 0.45))
                 #:enemy-units (for/list ([i (in-range 6)])
                                 (mk-u (+ 961 i) 'stalker 34.5 (+ 30.0 (* 0.9 i)) #:hp 80.0 #:shield 80.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-ms _t4 _d4)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-ms
                                 #:record-ledger? #f #:combat-should-engage? #f))
  (check-true "L33-T1d-marines-vs-faster-longer-range-stalkers-still-commit-fire"
              (and (= (count-unit-cmds acts-ms m-ids 'attack-unit) 6)
                   (= (count-unit-cmds acts-ms m-ids 'kite) 0))
              (format "Expected Marines vs faster/longer-range Stalkers to commit-fire; acts=~a" acts-ms)))

;; =============================================================================
;; TEST 2: Remembered/`owm` Corruptor Volley Latch (`#58`) + Isolated Phoenix/Colossus (`#18`)
;; =============================================================================
(let ()
  ;; T2a: Frame 10000 sees 8 Tempests (populates OWM!); Frame 10020 fog-flickers to 0 visible Tempests
  ;; (only 1 distant enemy Nexus visible, or 0 enemies visible) -> 2 lone Corruptors MUST stay staged behind
  ;; main (never launching across map toward x=140)!
  (define rt-corr (make-live-bot-runtime #:race 'Zerg))
  (define z-bldgs
    (list (mk-u 10 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 11 'hatchery 56.5 32.5 #:hp 1500.0)
          (mk-u 12 'spire 36.0 36.0 #:hp 850.0)))
  (define two-corrs
    (list (mk-u 201 'corruptor 50.0 38.0 #:hp 200.0 #:flying? #t)
          (mk-u 202 'corruptor 51.0 39.0 #:hp 200.0 #:flying? #t)))
  (define eight-tempests
    (for/list ([i (in-range 8)])
      (mk-u (+ 801 i) 'tempest (+ 115.0 (* 1.0 i)) 100.0 #:hp 200.0 #:shield 100.0 #:flying? #t)))
  ;; Frame 10000: Tempests visible -> OWM + runtime latch records 8 Tempests
  (step-live-bot-runtime!
   rt-corr
   (mk-live-obs 'Zerg 'Protoss 10000
                #:supply-used 60 #:supply-cap 90
                #:ally-units two-corrs #:ally-buildings z-bldgs
                #:enemy-units eight-tempests
                #:enemy-buildings (list (mk-u 990 'nexus 140.0 120.0 #:hp 1000.0 #:shield 1000.0))
                #:extra (hash 'enable-opponent-world-model #t)))
  ;; Frame 10020: Complete fog flicker (0 visible enemies AND 0 visible buildings!) ->
  ;; 2 newly-spawned Corruptors at (50, 38) MUST still stage behind main (<35)!
  (define fresh-corrs
    (list (mk-u 203 'corruptor 50.0 38.0 #:hp 200.0 #:flying? #t)
          (mk-u 204 'corruptor 51.0 39.0 #:hp 200.0 #:flying? #t)))
  (define acts-fog
    (hash-ref (step-live-bot-runtime!
               rt-corr
               (mk-live-obs 'Zerg 'Protoss 10020
                            #:supply-used 60 #:supply-cap 90
                            #:ally-units fresh-corrs #:ally-buildings z-bldgs
                            #:enemy-units '()
                            #:enemy-buildings '()
                            #:extra (hash 'enable-opponent-world-model #t)))
              'actions '()))
  (define (act-hits-any-id? a ids)
    (and (pair? a) (>= (length a) 2)
         (let ([u (cadr a)])
           (if (list? u) (ormap (lambda (x) (memv x ids)) u) (memv u ids)))))
  (define corr-staged-behind-main?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'move)
                  (act-hits-any-id? a '(203 204))
                  (< (caddr a) 35.0)))
           acts-fog))
  (define corr-suicide-across-map?
    (ormap (lambda (a)
             (and (pair? a) (memq (car a) '(attack-pos attack-unit move))
                  (act-hits-any-id? a '(203 204))
                  (or (eq? (car a) 'attack-unit)
                      (and (>= (length a) 3) (real? (caddr a)) (> (caddr a) 80.0)))))
           acts-fog))
  (check-true "L33-T2a-corruptor-volley-stays-latched-through-fog-flicker"
              (and corr-staged-behind-main? (not corr-suicide-across-map?))
              (format "Expected 2 freshly-hatched Corruptors to stage (<35) via OWM capital-air latch on fog flicker; acts=~a" acts-fog))

  ;; T2b: 2 isolated Phoenixes at (90, 90) (> 14t from enemies) while 6 Stalkers are at Natural (56, 32)
  ;; and enemy has 8 Vikings at (130, 115) -> Phoenixes MUST regroup toward main ground army (x < 75),
  ;; NEVER fly solo into 8 Vikings (x > 110)!
  (define rt-phx (make-live-bot-runtime #:race 'Protoss))
  (define p-bldgs
    (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 12 'stargate 38.0 36.0 #:hp 600.0 #:shield 600.0)
          (mk-u 13 'robotics-facility 40.0 38.0 #:hp 450.0 #:shield 450.0)))
  (define six-stalkers
    (for/list ([i (in-range 6)])
      (mk-u (+ 301 i) 'stalker (+ 56.0 (* 0.5 i)) 34.0 #:hp 80.0 #:shield 80.0)))
  (define eight-vikings
    (for/list ([i (in-range 8)])
      (mk-u (+ 821 i) 'viking-fighter (+ 128.0 (* 0.8 i)) 115.0 #:hp 135.0 #:flying? #t)))
  (define acts-phx
    (hash-ref (step-live-bot-runtime!
               rt-phx
               (mk-live-obs 'Protoss 'Terran 11000
                            #:supply-used 72 #:supply-cap 100
                            #:ally-units (append six-stalkers
                                                 (list (mk-u 351 'phoenix 90.0 90.0 #:hp 120.0 #:shield 60.0 #:flying? #t)
                                                       (mk-u 352 'phoenix 91.5 90.5 #:hp 120.0 #:shield 60.0 #:flying? #t)))
                            #:ally-buildings p-bldgs
                            #:enemy-units eight-vikings
                            #:enemy-buildings (list (mk-u 991 'command-center 140.0 120.0 #:hp 1500.0))))
              'actions '()))
  (define phx-regroups-to-army?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-pos)
                  (act-hits-any-id? a '(351 352))
                  (< (caddr a) 70.0) (< (cadddr a) 50.0)))
           acts-phx))
  (define phx-flies-into-vikings?
    (ormap (lambda (a)
             (and (pair? a) (memq (car a) '(attack-pos move attack-unit))
                  (act-hits-any-id? a '(351 352))
                  (or (eq? (car a) 'attack-unit)
                      (and (>= (length a) 3) (real? (caddr a)) (> (caddr a) 105.0)))))
           acts-phx))
  (check-true "L33-T2b-isolated-phoenixes-regroup-to-army-vs-8-vikings"
              (and phx-regroups-to-army? (not phx-flies-into-vikings?))
              (format "Expected 2 isolated Phoenixes to regroup toward Stalkers (<70,<50) vs 8 Vikings; acts=~a" acts-phx))

  ;; T2c: 1 isolated Colossus at (90, 90) (> 14t from enemy) while 6 Stalkers are at Natural (56, 34) ->
  ;; Colossus MUST regroup via `attack-pos` toward main ground army (<70, <50), NEVER march solo to x=140!
  (define rt-col (make-live-bot-runtime #:race 'Protoss))
  (define acts-col
    (hash-ref (step-live-bot-runtime!
               rt-col
               (mk-live-obs 'Protoss 'Terran 11000
                            #:supply-used 76 #:supply-cap 100
                            #:ally-units (append six-stalkers
                                                 (list (mk-u 361 'colossus 90.0 90.0 #:hp 200.0 #:shield 150.0)))
                            #:ally-buildings p-bldgs
                            #:enemy-units eight-vikings
                            #:enemy-buildings (list (mk-u 991 'command-center 140.0 120.0 #:hp 1500.0))))
              'actions '()))
  (define col-regroups-to-army?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'attack-pos)
                  (act-hits-any-id? a '(361))
                  (< (caddr a) 70.0) (< (cadddr a) 50.0)))
           acts-col))
  (define col-solo-march?
    (ormap (lambda (a)
             (and (pair? a) (memq (car a) '(attack-pos move attack-unit))
                  (act-hits-any-id? a '(361))
                  (or (eq? (car a) 'attack-unit)
                      (and (>= (length a) 3) (real? (caddr a)) (> (caddr a) 105.0)))))
           acts-col))
  (check-true "L33-T2c-isolated-colossus-regroups-to-main-ground-army"
              (and col-regroups-to-army? (not col-solo-march?))
              (format "Expected solo Colossus to regroup toward Stalkers (<70,<50); acts=~a" acts-col)))

;; =============================================================================
;; TEST 3: Fix `#73` Sole `CloakLoss` (`zerg-proactive-overseer1?` + Suite 34 BC Guard)
;; =============================================================================
(let ()
  (define drones (for/list ([i (in-range 36)]) (mk-u (+ 401 i) 'drone 29.0 32.0 #:hp 40.0)))
  (define base-z-units
    (append drones
            (list (mk-u 451 'overlord 35.0 35.0 #:hp 200.0 #:flying? #t)
                  (mk-u 452 'overlord 36.0 36.0 #:hp 200.0 #:flying? #t)
                  (mk-u 453 'queen 34.0 32.0 #:hp 175.0)
                  (mk-u 454 'queen 56.0 32.0 #:hp 175.0)
                  (mk-u 461 'larva 33.0 31.0 #:hp 25.0)
                  (mk-u 462 'larva 33.5 31.0 #:hp 25.0))))
  (define base-z-bldgs
    (list (mk-u 10 'lair 32.5 32.5 #:hp 2000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'hatchery 56.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 12 'hatchery 32.5 64.5 #:hp 1500.0 #:assigned-harvesters 4 #:ideal-harvesters 16)
          (mk-u 13 'spawning-pool 36.0 36.0 #:hp 1000.0)
          (mk-u 14 'extractor 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 15 'extractor 26.0 29.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))

  ;; T3a (`#73` repro): Zerg with ready Lair vs Terran Banshees (NO Spire yet -> `zerg-holding-for-aa-spire? = #t`,
  ;; `150M/150G`, `0` Overseers) MUST STILL morph proactive Overseer #1!
  (define rt-z73 (make-live-bot-runtime #:race 'Zerg))
  (define acts-z73
    (step-layer2-economy!
     rt-z73
     (mk-live-obs 'Zerg 'Terran 7200
                  #:minerals 150 #:gas 150 #:supply-used 52 #:supply-cap 70
                  #:ally-units base-z-units #:ally-buildings base-z-bldgs
                  #:enemy-units (list (mk-u 851 'banshee 90.0 40.0 #:hp 140.0 #:flying? #t)
                                      (mk-u 852 'banshee 92.0 40.0 #:hp 140.0 #:flying? #t)))))
  (check-true "L33-T3a-zerg-proactive-overseer1-morphs-despite-aa-spire-hold"
              (has-morph-sym? acts-z73 'overseer)
              (format "Expected Overseer #1 morph while holding for AA Spire vs Banshees; acts=~a" acts-z73))

  ;; T3b (Suite 34 BC guard): Zerg with ready Lair + ready Spire at `160M/120G` vs visible `battlecruiser`
  ;; MUST hold Overseer and train Corruptor FIRST!
  (define rt-zbc (make-live-bot-runtime #:race 'Zerg))
  (define acts-zbc
    (step-layer2-economy!
     rt-zbc
     (mk-live-obs 'Zerg 'Terran 9000
                  #:minerals 160 #:gas 120 #:supply-used 58 #:supply-cap 86
                  #:ally-units base-z-units
                  #:ally-buildings (cons (mk-u 16 'spire 38.0 38.0 #:hp 850.0) base-z-bldgs)
                  #:enemy-units (list (mk-u 861 'battlecruiser 110.0 110.0 #:hp 550.0 #:flying? #t)))))
  (check-true "L33-T3b-battlecruiser-guard-preserves-corruptor-ahead-of-overseer"
              (and (has-train-sym? acts-zbc 'corruptor)
                   (not (has-morph-sym? acts-zbc 'overseer)))
              (format "Expected Corruptor (not Overseer) at 160M/120G vs visible Battlecruiser; acts=~a" acts-zbc)))

;; =============================================================================
;; TEST 4: Honest Arena `t02` Bio `2.5x` Target Priority on Tank-Deadzone Melee Rushers
;; =============================================================================
(let ()
  ;; T4a: 2 Sieged Tanks at (24.5, 32) + 6 Marines at (27.5, 32).
  ;; 3 Zerglings rushing at (29.0, 32) (`4.5t <= 6.5t` from Tanks, `1.5t <= 8t` from Marines),
  ;; plus 4 damaged Roaches at (29.8, 32, hp=90) ->
  ;; Marines MUST peel Zerglings (ids 901..903) via `2.5x` boost while Sieged Tanks splash Roaches (ids 911..914)!
  (define m-ids '(501 502 503 504 505 506))
  (define t-ids '(511 512))
  (define ling-ids '(901 902 903))
  (define roach-ids '(911 912 913 914))
  (define obs-t02-peel
    (mk-live-obs 'Terran 'Zerg 200
                 #:ally-units (append
                               (list (mk-u 511 'siege-tank-sieged 24.5 31.2 #:hp 175.0)
                                     (mk-u 512 'siege-tank-sieged 24.5 32.8 #:hp 175.0))
                               (for/list ([id (in-list m-ids)] [i (in-naturals)])
                                 (mk-u id 'marine 27.5 (+ 30.2 (* 0.7 i)) #:hp 45.0 #:w-cd 0.0)))
                 #:enemy-units (append
                                (list (mk-u 901 'zergling 29.2 31.4 #:hp 35.0)
                                      (mk-u 902 'zergling 29.2 32.0 #:hp 35.0)
                                      (mk-u 903 'zergling 29.2 32.6 #:hp 35.0))
                                (for/list ([id (in-list roach-ids)] [i (in-naturals)])
                                  (mk-u id 'roach 29.6 (+ 30.8 (* 0.8 i)) #:hp 90.0 #:max-hp 145.0)))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-t02p _t _d)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-t02-peel #:record-ledger? #f))
  (define m-tgts (unit-attack-targets acts-t02p m-ids))
  (define t-tgts (unit-attack-targets acts-t02p t-ids))
  (check-true "L33-T4a-t02-bio-peels-tank-rusher-lings-while-tanks-splash-roaches"
              (and (= (length m-tgts) 6)
                   (andmap (lambda (eid) (memv eid ling-ids)) m-tgts)
                   (= (length t-tgts) 2)
                   (andmap (lambda (eid) (memv eid roach-ids)) t-tgts))
              (format "Expected 6/6 Marines on tank-rusher Lings (901-903) & 2/2 Tanks on Roaches (911-914); m=~a t=~a"
                      m-tgts t-tgts)))

;; =============================================================================
;; TEST 5: Honest Arena `p01` Melee-Engaged Ranged Bio Focus-Fire (0 Stalker Kite!)
;; =============================================================================
(let ()
  (define z-ids '(601 602 603 604))
  (define s-ids '(611 612 613 614))

  ;; T5a: 4 Zealots actively engaged (`1.7t <= 3.5t`) with 12 Marines (906 injured at 20 HP at center y=31.5) + 3 Marauders;
  ;; 4 Stalkers in weapon range (`<= 6.75t`) on cooldown (`w-cd = 0.90`) ->
  ;; ALL 4 Stalkers MUST focus-fire lowest-HP Marine 906 with 0 backward kites!
  (define obs-p01-low
    (mk-live-obs 'Protoss 'Terran 200
                 #:ally-units (append
                               (for/list ([id (in-list z-ids)] [i (in-naturals)])
                                 (mk-u id 'zealot 31.5 (+ 30.5 (* 1.0 i)) #:hp 100.0 #:shield 50.0))
                               (for/list ([id (in-list s-ids)] [i (in-naturals)])
                                 (mk-u id 'stalker 28.0 (+ 30.5 (* 1.0 i)) #:hp 80.0 #:shield 80.0 #:w-cd 0.90)))
                 #:enemy-units (append
                                (for/list ([i (in-range 12)])
                                  (mk-u (+ 901 i) 'marine 33.2 (+ 29.0 (* 0.5 i)) #:hp (if (= i 5) 20.0 45.0) #:max-hp 45.0))
                                (for/list ([i (in-range 3)])
                                  (mk-u (+ 921 i) 'marauder 34.5 (+ 31.0 (* 1.0 i)) #:hp 125.0)))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-p01a _t1 _d1)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-p01-low #:record-ledger? #f))
  (define s-tgts-a (unit-attack-targets acts-p01a s-ids))
  (check-true "L33-T5a-p01-stalkers-focus-fire-lowest-hp-marine-zero-kite"
              (and (= (count-unit-cmds acts-p01a s-ids 'kite) 0)
                   (= (length s-tgts-a) 4)
                   (andmap (lambda (eid) (= eid 906)) s-tgts-a))
              (format "Expected 4/4 Stalkers focusing injured Marine 906 with 0 kites; tgts=~a acts=~a" s-tgts-a acts-p01a))

  ;; T5b: All 12 Marines at full 45 HP -> ALL 4 Stalkers STILL converge on the SAME single front Marine
  ;; (1-volley kill: 4*13=52 > 45 HP!) with 0 kites!
  (define obs-p01-full
    (mk-live-obs 'Protoss 'Terran 200
                 #:ally-units (append
                               (for/list ([id (in-list z-ids)] [i (in-naturals)])
                                 (mk-u id 'zealot 31.5 (+ 30.5 (* 1.0 i)) #:hp 100.0 #:shield 50.0))
                               (for/list ([id (in-list s-ids)] [i (in-naturals)])
                                 (mk-u id 'stalker 28.0 (+ 30.5 (* 1.0 i)) #:hp 80.0 #:shield 80.0 #:w-cd 0.90)))
                 #:enemy-units (append
                                (for/list ([i (in-range 12)])
                                  (mk-u (+ 901 i) 'marine 33.2 (+ 29.0 (* 0.5 i)) #:hp 45.0 #:max-hp 45.0))
                                (for/list ([i (in-range 3)])
                                  (mk-u (+ 921 i) 'marauder 34.5 (+ 31.0 (* 1.0 i)) #:hp 125.0)))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-p01b _t2 _d2)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-p01-full #:record-ledger? #f))
  (define s-tgts-b (unit-attack-targets acts-p01b s-ids))
  (check-true "L33-T5b-p01-stalkers-converge-on-single-full-hp-marine"
              (and (= (count-unit-cmds acts-p01b s-ids 'kite) 0)
                   (= (length s-tgts-b) 4)
                   (= (length (remove-duplicates s-tgts-b)) 1))
              (format "Expected 4/4 Stalkers converging onto 1 shared Marine target with 0 kites; tgts=~a" s-tgts-b))

  ;; T5c: Negative guard — 4 Stalkers on w-cd=0.90 with NO Zealots vs 10 Zerglings STILL stutter-kite!
  (define obs-p03-neg
    (mk-live-obs 'Protoss 'Zerg 200
                 #:ally-units (for/list ([id (in-list s-ids)] [i (in-naturals)])
                                (mk-u id 'stalker 28.0 (+ 30.5 (* 1.0 i)) #:hp 80.0 #:shield 80.0 #:w-cd 0.90))
                 #:enemy-units (for/list ([i (in-range 10)])
                                 (mk-u (+ 951 i) 'zergling 30.8 (+ 29.5 (* 0.5 i)) #:hp 35.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define-values (acts-p03n _t3 _d3)
    (step-tactical-mirror-brain! (make-tactical-mirror-brain) (make-order-ledger) obs-p03-neg #:record-ledger? #f))
  (check-true "L33-T5c-stalkers-without-zealots-still-kite-zerglings"
              (>= (count-unit-cmds acts-p03n s-ids 'kite) 3)
              (format "Expected Stalkers without Zealots to keep kiting Zerglings; acts=~a" acts-p03n)))

(printf "L33-RUNTIME-ARENA-TESTS: ~a/~a PASSED (~a failed)\n"
        (- total-checks failed-checks) total-checks failed-checks)
(when (> failed-checks 0)
  (exit 1))
