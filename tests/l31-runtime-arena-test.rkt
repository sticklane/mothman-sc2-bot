#lang racket/base

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/sc2-types.rkt"
         "../lib/tactics/order-ledger.rkt"
         "../lib/tactics/arena-minimax.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt")

;; =============================================================================
;; Loop 31 (`L31-P0-3`) Unit & Live-Runtime Regression Suite
;; Covers:
;;   1. Protoss L2 Gateway Alignment (`#09 33x`, `#12 22x`, `#21 18x` -> ProdPlaceStall 0)
;;   2. Terran 1-Base CC Escrow Guard Fix (`#08`/`#26`: top-2 escrow_queue & bo-goal)
;;   3. Honest Arena `p11` Friendly Detector Convergence (vs `w11-tac-2` no-detector guard)
;;   4. Honest Arena `t07` SP & `p01` Active Close-Fire Commit in DisengageRetreat
;;   5. Honest Arena `t04` Bio Zergling Peel + Screened Ghost Snipe (`1.8t`) + `2.2t` Step-Back
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
                     #:gas [gas 100]
                     #:supply-used [su 30]
                     #:supply-cap [sc 46]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 56.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 140.0] #:enemy-y [ey 120.0]
                     #:upgrades [upgs '()]
                     #:expansion-pads [pads (list (cons 56.5 32.5) (cons 32.5 64.5) (cons 64.5 64.5))]
                     #:extra [extra (hash)])
  (define base-ht
    (hash 'race race 'enemy-race enemy-race 'frame frame
          'live-obs? #t 'live-game? #t
          'mineral-harvesters 16 'gas-harvesters 3
          'minerals minerals 'gas gas
          'supply-used su 'supply-cap sc
          'ally-units au 'ally-buildings ab
          'enemy-units eu 'enemy-buildings eb
          'base-x bx 'base-y by 'nat-x nx 'nat-y ny
          'enemy-x ex 'enemy-y ey
          'researched-upgrades upgs
          'expansion-pads pads
          'map-width 168 'map-height 168))
  (for/fold ([h base-ht]) ([(k v) (in-hash extra)])
    (hash-set h k v)))

(define (step-acts rt obs)
  (define res (step-live-bot-runtime! rt obs))
  (if (hash? res) (hash-ref res 'actions '()) res))

(define (has-build-sym? acts sym)
  (for/or ([a (in-list acts)])
    (and (pair? a)
         (memq (car a) '(build build-structure))
         (>= (length a) 2)
         (eq? (cadr a) sym))))

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
;; TEST 1: Protoss L2 Gateway Alignment (`#09 33x`, `#12 22x`, `#21 18x`)
;; =============================================================================
(let ()
  ;; T1a: 1-base Protoss (`#21` repro), 2 Gateways, 340M under attack (`sched=(gateway@542.0)`!)
  ;; Previously L2 capped desired-gateways at 2 (<650M) and vetoed via protoss-nat-reserve / post-battery bank < 300M.
  (define rt1 (make-live-bot-runtime #:race 'Protoss))
  (define probes1
    (for/list ([i (in-range 22)])
      (mk-u (+ 101 i) 'probe (+ 28.0 (* 0.4 i)) 32.0 #:hp 20.0 #:shield 20.0)))
  (define army1
    (list (mk-u 201 'zealot 40.0 32.0 #:hp 100.0 #:shield 50.0)
          (mk-u 202 'stalker 40.0 34.0 #:hp 80.0 #:shield 80.0)
          (mk-u 203 'stalker 40.0 36.0 #:hp 80.0 #:shield 80.0)))
  (define bldgs1
    (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'pylon 37.5 32.5 #:hp 200.0 #:shield 200.0)
          (mk-u 12 'pylon 37.5 37.5 #:hp 200.0 #:shield 200.0)
          (mk-u 13 'gateway 39.0 33.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 14 'gateway 39.0 37.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 15 'cybernetics-core 35.0 37.0 #:hp 550.0 #:shield 550.0)
          (mk-u 16 'assimilator 26.0 36.0 #:hp 300.0 #:shield 300.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 17 'assimilator 26.0 29.0 #:hp 300.0 #:shield 300.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 18 'robotics-facility 35.0 28.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 19 'shield-battery 38.0 30.0 #:hp 150.0 #:shield 150.0)))
  (define obs1
    (mk-live-obs 'Protoss 'Zerg 6800
                 #:minerals 340 #:gas 40 #:supply-used 34 #:supply-cap 46
                 #:ally-units (append probes1 army1)
                 #:ally-buildings bldgs1
                 #:enemy-units (list (mk-u 901 'roach 57.0 32.5 #:hp 145.0)
                                     (mk-u 902 'roach 57.5 34.0 #:hp 145.0)
                                     (mk-u 903 'roach 57.0 35.0 #:hp 145.0)
                                     (mk-u 904 'roach 56.5 33.0 #:hp 145.0))
                 #:extra (hash 'natural-blocked? #t 'under-attack? #t)))
  (define acts1 (step-acts rt1 obs1))
  (check-true "L31-T1a-1base-340M-aligned-gateway-3"
              (has-build-sym? acts1 'gateway)
              (format "expected 1-base 340M Gateway #3 to emit; acts=~a" acts1))

  ;; T1a-neg: Negative guard — 1-base 340M when Brain IS saving for 'nexus -> MUST NOT break Nexus escrow!
  (define rt1-neg (make-live-bot-runtime #:race 'Protoss))
  (define obs1-neg
    (mk-live-obs 'Protoss 'Zerg 4800
                 #:minerals 340 #:gas 40 #:supply-used 34 #:supply-cap 46
                 #:ally-units (append probes1 army1)
                 #:ally-buildings bldgs1
                 #:enemy-units '()))
  (define acts1-neg (step-acts rt1-neg obs1-neg))
  (check-true "L31-T1a-neg-1base-saving-nexus-holds-gateway"
              (not (has-build-sym? acts1-neg 'gateway))
              (format "expected 1-base saving_for=nexus to hold Gateway; acts=~a" acts1-neg))

  ;; T1b: 2-base Protoss (`#09` repro), 4 Gateways, 360M, 40 probes, Brain schedules 'gateway (not saving_for='nexus)
  (define rt2 (make-live-bot-runtime #:race 'Protoss))
  (define probes2
    (for/list ([i (in-range 40)])
      (mk-u (+ 101 i) 'probe (+ 28.0 (* 0.25 i)) 32.0 #:hp 20.0 #:shield 20.0)))
  (define army2
    (for/list ([i (in-range 8)])
      (mk-u (+ 201 i) 'stalker (+ 50.0 (* 0.5 i)) 32.0 #:hp 80.0 #:shield 80.0)))
  (define bldgs2
    (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 19 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'pylon 37.5 32.5 #:hp 200.0 #:shield 200.0)
          (mk-u 12 'pylon 42.5 37.5 #:hp 200.0 #:shield 200.0)
          (mk-u 20 'pylon 50.5 37.5 #:hp 200.0 #:shield 200.0)
          (mk-u 13 'gateway 39.0 33.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 14 'gateway 39.0 37.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 21 'gateway 44.0 33.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 22 'gateway 44.0 37.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 15 'cybernetics-core 35.0 37.0 #:hp 550.0 #:shield 550.0)
          (mk-u 16 'robotics-facility 35.0 28.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 17 'assimilator 26.0 36.0 #:hp 300.0 #:shield 300.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 18 'assimilator 26.0 29.0 #:hp 300.0 #:shield 300.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))
  (define obs2
    (mk-live-obs 'Protoss 'Zerg 6800
                 #:minerals 360 #:gas 40 #:supply-used 56 #:supply-cap 78
                 #:ally-units (append probes2 army2)
                 #:ally-buildings bldgs2
                 #:enemy-units (list (mk-u 901 'mutalisk 75.0 32.5 #:hp 120.0 #:flying? #t)
                                     (mk-u 902 'mutalisk 76.0 34.0 #:hp 120.0 #:flying? #t)
                                     (mk-u 903 'mutalisk 77.0 32.0 #:hp 120.0 #:flying? #t))))
  (define acts2 (step-acts rt2 obs2))
  (check-true "L31-T1b-2base-360M-aligned-gateway-5"
              (has-build-sym? acts2 'gateway)
              (format "expected 2-base 360M Gateway #5 to emit; acts=~a" acts2))

  ;; T1c: 2-base Protoss (`#12` exact repro), 6 Gateways + Forge + 4 Assimilators + WarpGate,
  ;; 765M/20G -> Brain schedules `gateway@536.0` -> L2 aligns `desired-gateways=8` and emits Gateway #7!
  (define rt3 (make-live-bot-runtime #:race 'Protoss))
  (define probes3
    (for/list ([i (in-range 44)])
      (mk-u (+ 101 i) 'probe (+ 28.0 (* 0.25 i)) 32.0 #:hp 20.0 #:shield 20.0)))
  (define army3
    (for/list ([i (in-range 10)])
      (mk-u (+ 201 i) 'stalker (+ 50.0 (* 0.5 i)) 32.0 #:hp 80.0 #:shield 80.0)))
  (define bldgs3
    (append bldgs2
            (list (mk-u 23 'gateway 48.0 33.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                  (mk-u 24 'gateway 48.0 37.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                  (mk-u 25 'twilight-council 42.0 28.0 #:hp 500.0 #:shield 500.0)
                  (mk-u 26 'forge 46.0 28.0 #:hp 400.0 #:shield 400.0)
                  (mk-u 27 'assimilator 50.0 36.0 #:hp 300.0 #:shield 300.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                  (mk-u 28 'assimilator 50.0 29.0 #:hp 300.0 #:shield 300.0 #:assigned-harvesters 3 #:ideal-harvesters 3))))
  (define obs3
    (mk-live-obs 'Protoss 'Protoss 9600
                 #:minerals 765 #:gas 20 #:supply-used 64 #:supply-cap 94
                 #:upgrades '(warp-gate-research)
                 #:ally-units (append probes3 army3)
                 #:ally-buildings bldgs3
                 #:enemy-units (list (mk-u 901 'stalker 65.0 32.5 #:hp 80.0 #:shield 80.0)
                                     (mk-u 902 'stalker 65.0 34.0 #:hp 80.0 #:shield 80.0))))
  (define acts3 (step-acts rt3 obs3))
  (check-true "L31-T1c-2base-765M-6gw-aligned-gateway-7"
              (has-build-sym? acts3 'gateway)
              (format "expected 2-base 765M w/ 6 GWs to emit Gateway #7; acts=~a" acts3)))

;; =============================================================================
;; TEST 2: Terran 1-Base CC Escrow Guard Fix (`#08`/`#26` top-2 escrow_queue & bo-goal)
;; =============================================================================
(let ()
  ;; T2a: `#08` exact repro — 1-base Terran, 20 SCVs, 4 Marines, 230M/100G,
  ;; Macro Brain has `saving_for = 'starport` (#1) and `'command-center` (#2 in `escrow_queue`).
  ;; L2 MUST hold non-emergency spends (SCV, Marine, SupplyDepot, Bunker, Starport, Barracks #2)!
  (define rt (make-live-bot-runtime #:race 'Terran))
  (define scvs
    (for/list ([i (in-range 20)])
      (mk-u (+ 101 i) 'scv (+ 28.0 (* 0.3 i)) 32.0 #:hp 45.0)))
  (define marines
    (for/list ([i (in-range 4)])
      (mk-u (+ 201 i) 'marine (+ 40.0 (* 0.5 i)) 32.0 #:hp 45.0)))
  (define bldgs
    (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 12 'supply-depot 38.0 34.0 #:hp 400.0)
          (mk-u 13 'supply-depot 38.0 38.0 #:hp 400.0)
          (mk-u 14 'barracks 41.0 32.0 #:hp 1000.0)
          (mk-u 15 'factory 41.0 37.0 #:hp 1250.0)
          (mk-u 16 'refinery 26.0 36.0 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))
  ;; Construct mock priority-schedule-result where starport is #1, command-center is #2, ebay is #3
  (define e1 (priority-decision-entry 1 'starport 'tech '(build starport) 150 100 0 810.0 #t 'escrowed-saving 150 100 #f))
  (define e2 (priority-decision-entry 2 'command-center 'expand '(expand command-center) 400 0 0 560.0 #t 'blocked-by-escrow 400 0 'starport))
  (define e3 (priority-decision-entry 3 'engineering-bay 'tech '(build engineering-bay) 125 0 0 420.0 #t 'blocked-by-escrow 125 0 'command-center))
  (define mock-sched
    (priority-schedule-result '() '() #f 230 100 15
                              (hash 'decision-trace (list e1 e2 e3)
                                    'reserved-min-floor 400
                                    'reserved-gas-floor 100)))
  (define mock-md
    (macro-brain-decision '((train scv) (train marine))
                          '(scv marine)
                          'starport
                          400 100 '()
                          #f '() mock-sched "mock"))
  (check-true "L31-T2a-escrow-queue-top2-matches-rank2-cc"
              (and (macro-decision-sym-in-escrow-queue-top-n? mock-md 'command-center 2)
                   (macro-decision-sym-in-escrow-queue-top-n? mock-md 'starport 2)
                   (not (macro-decision-sym-in-escrow-queue-top-n? mock-md 'engineering-bay 2)))
              "Expected top-2 escrow_queue helper to match rank #1/#2 and reject rank #3")
  ;; Live `#08` Terran 1-base 230M/100G check via full step-layer2-economy!
  (define obs
    (mk-live-obs 'Terran 'Terran 5600
                 #:minerals 230 #:gas 100 #:supply-used 24 #:supply-cap 39
                 #:ally-units (append scvs marines)
                 #:ally-buildings bldgs))
  (define l2-acts (step-layer2-economy! rt obs))
  (define leaky-spends
    (filter (lambda (a)
              (and (pair? a)
                   (or (and (memq (car a) '(build build-structure))
                            (memq (cadr a) '(supply-depot bunker engineering-bay missile-turret barracks starport)))
                       (and (memq (car a) '(train train-unit))
                            (memq (cadr a) '(scv marine))))))
            l2-acts))
  (check-true "L31-T2a-terran-1base-cc-top2-escrow-holds-spends"
              (null? leaky-spends)
              (format "expected 0 leaky spends on 1-base Terran 230M/100G f=5600; leaked=~a all=~a" leaky-spends l2-acts))

  ;; T2b: Early 1-base Terran (`f=3200`, `220M/50G`, `20 SCVs`, `4 Marines`, `bo-goal = 'command-center`)
  ;; ALSO activates 1-base CC hold!
  (define rt2 (make-live-bot-runtime #:race 'Terran))
  (define obs2
    (mk-live-obs 'Terran 'Zerg 3200
                 #:minerals 220 #:gas 50 #:supply-used 24 #:supply-cap 39
                 #:ally-units (append scvs marines)
                 #:ally-buildings bldgs))
  (define l2-acts2 (step-layer2-economy! rt2 obs2))
  (define leaky-spends2
    (filter (lambda (a)
              (and (pair? a)
                   (or (and (memq (car a) '(build build-structure))
                            (memq (cadr a) '(supply-depot bunker engineering-bay missile-turret barracks starport)))
                       (and (memq (car a) '(train train-unit))
                            (memq (cadr a) '(scv marine))))))
            l2-acts2))
  (check-true "L31-T2b-terran-1base-cc-bo-goal-holds-spends"
              (null? leaky-spends2)
              (format "expected 0 leaky spends on 1-base Terran 220M/50G f=3200; leaked=~a all=~a" leaky-spends2 l2-acts2)))

;; =============================================================================
;; TEST 3: Honest Arena `p11` Friendly Detector Convergence (+ `w11-tac-2` guard)
;; =============================================================================
(let ()
  ;; T3a: 6 Blink Stalkers + 2 Observers vs 3 undetected cloak=1 Banshees (`13t` away from Obs)
  (define stalker-ids '(301 302 303 304 305 306))
  (define obs-ids '(351 352))
  (define allies-p11
    (append
     (for/list ([id (in-list stalker-ids)] [i (in-naturals)])
       (mk-u id 'stalker 26.0 (+ 29.0 (* 1.0 i)) #:hp 80.0 #:shield 80.0))
     (list (mk-u 351 'observer 25.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t)
           (mk-u 352 'observer 24.5 33.5 #:hp 40.0 #:shield 20.0 #:flying? #t))))
  (define enemies-p11
    (list (mk-u 901 'banshee 38.0 31.0 #:hp 140.0 #:cloak 1 #:flying? #t)
          (mk-u 902 'banshee 38.5 32.5 #:hp 140.0 #:cloak 1 #:flying? #t)
          (mk-u 903 'banshee 38.0 34.0 #:hp 140.0 #:cloak 1 #:flying? #t)))
  (define obs-p11
    (mk-live-obs 'Protoss 'Terran 100
                 #:ally-units allies-p11
                 #:enemy-units enemies-p11
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  ;; 3a-1: arena-minimax direct check
  (define tbrain (make-tactical-mirror-brain))
  (define-values (tb-acts _tags _decs)
    (step-tactical-mirror-brain! tbrain (make-order-ledger) obs-p11 #:record-ledger? #f))
  (define tb-stalker-kites (count-unit-cmds tb-acts stalker-ids 'kite))
  (define tb-stalker-atks (count-unit-cmds tb-acts stalker-ids 'attack-unit))
  (define tb-obs-advances
    (for/sum ([a (in-list tb-acts)])
      (if (and (pair? a) (eq? (car a) 'move) (memv (cadr a) obs-ids) (> (caddr a) 26.0)) 1 0)))
  (check-true "L31-T3a-minimax-p11-zero-stalker-flee-kite"
              (= tb-stalker-kites 0)
              (format "Stalkers fled via kite=~a with live Observers; acts=~a" tb-stalker-kites tb-acts))
  (check-true "L31-T3a-minimax-p11-zero-invalid-cloak1-attack"
              (= tb-stalker-atks 0)
              (format "Stalkers issued invalid attack-unit=~a on cloak=1; acts=~a" tb-stalker-atks tb-acts))
  (check-true "L31-T3a-minimax-p11-observer-advances-onto-cloak"
              (>= tb-obs-advances 1)
              (format "Observers did not advance toward cloaked Banshees; acts=~a" tb-acts))

  ;; 3a-2: full step-live-bot-runtime! check
  (define rt-p11 (make-live-bot-runtime #:race 'Protoss))
  (define rt-acts-p11 (step-acts rt-p11 obs-p11))
  (define rt-stalker-kites (count-unit-cmds rt-acts-p11 stalker-ids 'kite))
  (define rt-stalker-atks (count-unit-cmds rt-acts-p11 stalker-ids 'attack-unit))
  (define rt-obs-advances
    (for/sum ([a (in-list rt-acts-p11)])
      (if (and (pair? a) (eq? (car a) 'move) (memv (cadr a) obs-ids) (> (caddr a) 26.0)) 1 0)))
  (check-true "L31-T3a-runtime-p11-zero-stalker-flee-kite"
              (= rt-stalker-kites 0)
              (format "Runtime Stalkers fled via kite=~a with live Observers; acts=~a" rt-stalker-kites rt-acts-p11))
  (check-true "L31-T3a-runtime-p11-zero-invalid-cloak1-attack"
              (= rt-stalker-atks 0)
              (format "Runtime Stalkers issued invalid attack-unit=~a on cloak=1" rt-stalker-atks))
  (check-true "L31-T3a-runtime-p11-observer-advances-onto-cloak"
              (>= rt-obs-advances 1)
              (format "Runtime Observers did not advance toward cloaked Banshees; acts=~a" rt-acts-p11))

  ;; T3b: Negative guard (`w11-tac-2`): NO Observer -> Stalkers MUST still pull back via kite!
  (define obs-nodet
    (mk-live-obs 'Protoss 'Protoss 100
                 #:ally-units (for/list ([id (in-list stalker-ids)] [i (in-naturals)])
                                (mk-u id 'stalker 26.0 (+ 29.0 (* 1.0 i)) #:hp 80.0 #:shield 80.0))
                 #:enemy-units (list (mk-u 921 'dark-templar 30.0 31.0 #:hp 40.0 #:shield 80.0 #:cloak 1)
                                     (mk-u 922 'dark-templar 30.5 32.5 #:hp 40.0 #:shield 80.0 #:cloak 1))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-nodet (make-tactical-mirror-brain))
  (define-values (nodet-acts _t2 _d2)
    (step-tactical-mirror-brain! tb-nodet (make-order-ledger) obs-nodet #:record-ledger? #f))
  (check-true "L31-T3b-no-detector-still-kites-back"
              (and (>= (count-unit-cmds nodet-acts stalker-ids 'kite) 4)
                   (= (count-unit-cmds nodet-acts stalker-ids 'attack-unit) 0))
              (format "Expected >=4 kites and 0 attacks without detector; acts=~a" nodet-acts)))

;; =============================================================================
;; TEST 4: Honest Arena `t07` SP & `p01` Active Close-Fire Commit in DisengageRetreat
;; =============================================================================
(let ()
  ;; T4a: `t07` SP — 8 Marines + 2 Cyclones vs 5 Stalkers + 2 Immortals at `8.5t` under DisengageRetreat
  (define m-ids '(401 402 403 404 405 406 407 408))
  (define cyc-ids '(409 410))
  (define allies-t07
    (append
     (for/list ([id (in-list m-ids)] [i (in-naturals)])
       (mk-u id 'marine 27.2 (+ 29.0 (* 0.8 i)) #:hp 45.0 #:w-cd 0.45))
     (list (mk-u 409 'cyclone 28.0 31.5 #:hp 120.0 #:w-cd 0.35)
           (mk-u 410 'cyclone 28.0 32.5 #:hp 120.0 #:w-cd 0.35))))
  (define enemies-t07
    (append
     (for/list ([i (in-range 5)])
       (mk-u (+ 901 i) 'stalker 35.5 (+ 30.0 (* 1.0 i)) #:hp 80.0 #:shield 80.0))
     (list (mk-u 910 'immortal 34.8 31.5 #:hp 200.0 #:shield 100.0)
           (mk-u 911 'immortal 34.8 33.0 #:hp 200.0 #:shield 100.0))))
  (define obs-t07
    (mk-live-obs 'Terran 'Protoss 200
                 #:ally-units allies-t07
                 #:enemy-units enemies-t07
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-t07 (make-tactical-mirror-brain))
  (define-values (acts-t07 _t _d)
    (step-tactical-mirror-brain! tb-t07 (make-order-ledger) obs-t07
                                 #:record-ledger? #f
                                 #:combat-should-engage? #f))
  (define t07-atks (count-unit-cmds acts-t07 (append m-ids cyc-ids) 'attack-unit))
  (define t07-kites (count-unit-cmds acts-t07 (append m-ids cyc-ids) 'kite))
  (check-true "L31-T4a-t07-commit-fire-vs-equal-longer-range-pursuers"
              (and (= t07-atks 10) (= t07-kites 0))
              (format "Expected 10/10 commit attacks and 0 kites in t07 DisengageRetreat; atk=~a kite=~a" t07-atks t07-kites))

  ;; T4b: `p01` — 4 Zealots + 4 Stalkers vs 12 Marines + 3 Marauders at `8.8t` under DisengageRetreat
  (define z-ids '(421 422 423 424))
  (define s-ids '(425 426 427 428))
  (define allies-p01
    (append
     (for/list ([id (in-list z-ids)] [i (in-naturals)])
       (mk-u id 'zealot 28.5 (+ 30.5 (* 1.0 i)) #:hp 100.0 #:shield 50.0))
     (for/list ([id (in-list s-ids)] [i (in-naturals)])
       (mk-u id 'stalker 27.0 (+ 30.5 (* 1.0 i)) #:hp 80.0 #:shield 80.0 #:w-cd 0.9))))
  (define enemies-p01
    (append
     (for/list ([i (in-range 12)])
       (mk-u (+ 920 i) 'marine 36.2 (+ 29.0 (* 0.5 i)) #:hp 45.0))
     (for/list ([i (in-range 3)])
       (mk-u (+ 940 i) 'marauder 35.8 (+ 31.0 (* 1.0 i)) #:hp 125.0))))
  (define obs-p01
    (mk-live-obs 'Protoss 'Terran 200
                 #:ally-units allies-p01
                 #:enemy-units enemies-p01
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-p01 (make-tactical-mirror-brain))
  (define-values (acts-p01 _t2 _d2)
    (step-tactical-mirror-brain! tb-p01 (make-order-ledger) obs-p01
                                 #:record-ledger? #f
                                 #:combat-should-engage? #f))
  (define p01-atks (count-unit-cmds acts-p01 (append z-ids s-ids) 'attack-unit))
  (define p01-kites (count-unit-cmds acts-p01 (append z-ids s-ids) 'kite))
  (check-true "L31-T4b-p01-zealot-stalker-commit-fire"
              (and (= p01-atks 8) (= p01-kites 0))
              (format "Expected 8/8 commit attacks and 0 kites in p01 DisengageRetreat; atk=~a kite=~a" p01-atks p01-kites))

  ;; T4c: Negative guard — `p03` Stalkers on cooldown (`w-cd=1.00`) vs Zerglings (`e-wr=0.1 <= 1.5`) STILL tight-stutter!
  (define p03-sids '(431 432 433 434 435))
  (define obs-p03
    (mk-live-obs 'Protoss 'Zerg 200
                 #:ally-units (for/list ([id (in-list p03-sids)] [i (in-naturals)])
                                (mk-u id 'stalker 28.0 (+ 30.0 (* 1.0 i)) #:hp 80.0 #:shield 80.0 #:w-cd 1.00))
                 #:enemy-units (for/list ([i (in-range 10)])
                                 (mk-u (+ 960 i) 'zergling 30.8 (+ 30.0 (* 0.5 i)) #:hp 35.0))
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define tb-p03 (make-tactical-mirror-brain))
  (define-values (acts-p03 _t3 _d3)
    (step-tactical-mirror-brain! tb-p03 (make-order-ledger) obs-p03
                                 #:record-ledger? #f
                                 #:combat-should-engage? #f))
  (check-true "L31-T4c-p03-stalkers-still-stutter-vs-melee-lings"
              (>= (count-unit-cmds acts-p03 p03-sids 'kite) 4)
              (format "Expected Stalkers on w-cd=1.00 to keep stutter-kiting Zerglings; acts=~a" acts-p03)))

;; =============================================================================
;; TEST 5: Honest Arena `t04` Bio Peel + Screened Ghost Snipe (`1.8t`) + `2.2t` Step-Back
;; =============================================================================
(let ()
  ;; T5a: Full-HP `t04` opening (verifies `has-ally-ghost?` passes Bio into spellcaster micro!)
  ;; Zergling at `2.2t` from Ghost (`<= 3.5t` peel radius, `>= 1.8t` Snipe-safe radius):
  ;;   -> Ghosts STILL fire Snipe (`steady-targeting`) onto Ultralisks!
  ;;   -> Frontline Marines IMMEDIATELY focus-peel the close Zergling (id=950) instead of Ultra/Infestor!
  (define ghost-ids '(501 502))
  (define marine-ids '(511 512 513 514 515 516 517 518))
  (define marauder-ids '(521 522 523 524))
  (define allies-t04
    (append
     (list (mk-u 501 'ghost 26.5 31.5 #:hp 100.0 #:energy 100.0)
           (mk-u 502 'ghost 26.5 32.5 #:hp 100.0 #:energy 100.0)
           (mk-u 531 'medivac 25.5 31.5 #:hp 150.0 #:energy 100.0 #:flying? #t)
           (mk-u 532 'medivac 25.5 32.5 #:hp 150.0 #:energy 100.0 #:flying? #t))
     (for/list ([id (in-list marine-ids)] [i (in-naturals)])
       (mk-u id 'marine 28.0 (+ 30.0 (* 0.5 i)) #:hp 45.0))
     (for/list ([id (in-list marauder-ids)] [i (in-naturals)])
       (mk-u id 'marauder 29.0 (+ 30.8 (* 0.8 i)) #:hp 125.0))))
  (define enemies-t04
    (list (mk-u 950 'zergling 28.7 32.0 #:hp 35.0) ;; 2.2t from Ghosts!
          (mk-u 951 'ultralisk 34.5 31.5 #:hp 500.0)
          (mk-u 952 'ultralisk 34.5 33.0 #:hp 500.0)
          (mk-u 953 'infestor 36.0 32.0 #:hp 90.0 #:energy 150.0)))
  (define obs-t04
    (mk-live-obs 'Terran 'Zerg 240
                 #:ally-units allies-t04
                 #:enemy-units enemies-t04
                 #:base-x 10.0 #:base-y 32.0 #:nat-x 18.0 #:nat-y 32.0
                 #:enemy-x 54.0 #:enemy-y 32.0))
  (define rt-t04 (make-live-bot-runtime #:race 'Terran))
  (define acts-t04 (step-acts rt-t04 obs-t04))
  (define ghost-snipes
    (for/sum ([a (in-list acts-t04)])
      (if (and (pair? a) (eq? (car a) 'cast-spell)
               (memv (cadr a) ghost-ids)
               (eq? (caddr a) 'steady-targeting)
               (memv (cadddr a) '(951 952)))
          1 0)))
  (define marine-peels
    (for/sum ([a (in-list acts-t04)])
      (if (and (pair? a) (eq? (car a) 'attack-unit)
               (>= (length a) 3)
               (= (caddr a) 950))
          (let ([uarg (cadr a)])
            (cond
              [(list? uarg) (count (lambda (x) (memv x marine-ids)) uarg)]
              [(memv uarg marine-ids) 1]
              [else 0]))
          0)))
  (check-true "L31-T5a-full-hp-t04-ghosts-snipe-at-2.2t-melee"
              (>= ghost-snipes 1)
              (format "Expected Ghost Snipe on Ultra at 2.2t melee w/ full-HP Bio screen; snipes=~a acts=~a" ghost-snipes acts-t04))
  (check-true "L31-T5a-marines-peel-close-zergling-near-ghosts"
              (>= marine-peels 6)
              (format "Expected >=6/8 Marines peeling Zergling 950 <=3.5t of Ghosts; peels=~a" marine-peels))

  ;; T5b: Melee threat `< 1.8t` from Ghost (Zergling at `1.2t`) -> Ghost steps `2.2t` behind Marines!
  (define enemies-t04-close
    (list (mk-u 960 'zergling 27.7 32.0 #:hp 35.0) ;; 1.2t from Ghost 501 at (26.5, 31.5)!
          (mk-u 951 'ultralisk 34.5 31.5 #:hp 500.0)))
  (define dirs-close
    (plan-terran-spellcaster-micro
     allies-t04 enemies-t04-close
     #:claims (make-spell-claims)
     #:current-frame 240
     #:home-x 10.0 #:home-y 32.0
     #:ghost-cloak-researched? #f))
  (define ghost-step-backs
    (filter (lambda (d)
              (and (memv (spell-directive-caster-tag d) ghost-ids)
                   (eq? (spell-directive-pattern-name d) 'ghost-melee-step-back)
                   (eq? (spell-directive-target-mode d) 'move)
                   (< (spell-directive-target-x d) 25.0)))
            dirs-close))
  (define ghost-snipes-close
    (filter (lambda (d)
              (and (memv (spell-directive-caster-tag d) ghost-ids)
                   (eq? (spell-directive-ability d) 'steady-targeting)))
            dirs-close))
  (check-true "L31-T5b-ghost-steps-2.2t-behind-marines-under-1.8t-melee"
              (and (>= (length ghost-step-backs) 1) (null? ghost-snipes-close))
              (format "Expected Ghost step-back behind Marines (<25.0) and 0 snipes at 1.2t melee; dirs=~a" dirs-close))

  ;; T5c: Negative guard — Lone unscreened Ghost with enemy at `3.5t` and non-heavy-bio target does NOT
  ;; cast Snipe (`4.499t` guard; heavy-bio solo 2.0t rule is covered by `L32-T4a`),
  ;; AND screened Ghost vs Protoss shielded High Templars (`>= 160` shields) still casts EMP FIRST!
  (define dirs-lone
    (plan-terran-spellcaster-micro
     (list (mk-u 501 'ghost 26.5 32.0 #:hp 100.0 #:energy 100.0))
     (list (mk-u 961 'zergling 30.0 32.0 #:hp 35.0)
           (mk-u 951 'queen 34.5 32.0 #:hp 175.0))
     #:claims (make-spell-claims)
     #:current-frame 240
     #:home-x 10.0 #:home-y 32.0
     #:ghost-cloak-researched? #f))
  (check-true "L31-T5c-unscreened-ghost-keeps-4.499t-safety"
              (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'steady-targeting)) dirs-lone))
              (format "Unscreened lone Ghost should not Snipe at 3.5t; dirs=~a" dirs-lone))
  (define dirs-emp
    (plan-terran-spellcaster-micro
     allies-t04
     (list (mk-u 971 'high-templar 33.5 32.0 #:hp 40.0 #:shield 80.0 #:energy 150.0)
           (mk-u 972 'high-templar 34.0 32.2 #:hp 40.0 #:shield 80.0 #:energy 150.0)
           (mk-u 973 'archon 34.2 31.8 #:hp 10.0 #:shield 350.0))
     #:claims (make-spell-claims)
     #:current-frame 240
     #:home-x 10.0 #:home-y 32.0
     #:ghost-cloak-researched? #f))
  (check-true "L31-T5c-ghost-still-emps-heavy-protoss-shields-first"
              (ormap (lambda (d) (eq? (spell-directive-ability d) 'emp-round)) dirs-emp)
              (format "Expected Ghost EMP first vs Protoss shields; dirs=~a" dirs-emp)))

(printf "L31-RUNTIME-ARENA-TESTS: ~a/~a PASSED (~a failed)\n"
        (- total-checks failed-checks) total-checks failed-checks)
(when (> failed-checks 0)
  (exit 1))
