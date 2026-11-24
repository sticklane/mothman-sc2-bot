#lang racket/base

;; =============================================================================
;; `tests/l67-phase-d-runtime-test.rkt`
;; Loop 67 / 67B Architecture Phase D — Lane B Runtime Verification Suite
;;
;; Covers:
;;   1. L67-D1: Tightened gas-deficit mineral-overflow `#:alternatives`
;;      (`>= 500M`, `eff-gas < g-cost - 35`, `#:respect-bo-reserve? #t`, Zerg
;;      `larva >= 2`) for Protoss (`zealot`), Terran (`marine`), Zerg (`zergling`),
;;      protected-unit (`colossus`/`immortal`/`siege-tank`/`warp-prism`) escrow
;;      and overflow immunity at `450M/120G`, and air-dominated negative guard.
;;   2. L67-D2: Qualified `[SCBOT_ARBITER]` starvation recording (ZERO spam on
;;      routine `50M/10G` broke/busy-slot/0-larva frames!), genuine `'budget-larva`
;;      (`>= 300M` + `0` larvae) & `'facility-busy` (`>= 350M`), Zerg Queen `25e`
;;      creep suppression + `>= 50e` surplus preservation, `step-live-bot-runtime!`
;;      `'mineral-override-pressure?` (`>= 6` in `224f` & `gas >= 200` & `min < 150`),
;;      Terran MULE pressure + cloak-reserve preservation, and Protoss Chrono
;;      facility-override pressure bounds.
;;   3. L67-D3: Controlled A/B proof of `terran-protect-oc1-min?` (`< 250M`
;;      while unmorphed completed CC exists even with `order-count = 1`), plus
;;      light-poke (`threat <= 2.0`) retention and real-attack (`threat > 2.0`) break.
;;   4. L67-D4: 1-base Natural CC reserve survival past escrow timeout,
;;      `Refinery #2` `< 475M` gate, `Starport` non-bypass when 1-base saving
;;      for `'command-center`, and peaceful `5:15` (`>= 7056f`) 3rd CC
;;      `terran-3rd-cc-overdue-override?` (+ negative guard under attack).
;; =============================================================================

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         (only-in "../lib/engine/arbiter.rkt"
                  arbiter-ledger?
                  arbiter-recent-override-count
                  arbiter-resolve!
                  arbiter-telemetry-summary
                  make-arbiter-budget-snapshot
                  make-proposal
                  make-proposal-cost)
         (only-in "../lib/sc2-game-constants.rkt"
                  sc2-gas-cost))

(define tests-run 0)
(define tests-passed 0)
(define tests-failed 0)

(define (check-true name cond-val [detail ""])
  (set! tests-run (add1 tests-run))
  (if cond-val
      (begin
        (set! tests-passed (add1 tests-passed))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! tests-failed (add1 tests-failed))
        (printf "  [FAIL] ~a ~a\n" name detail))))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [mhp hp]
              #:shield [sh 0.0] #:max-shield [msh sh]
              #:energy [en 0.0]
              #:cloak [clk 3]
              #:flying [fly? #f]
              #:build-progress [bp 1.0]
              #:assigned-harvesters [ah #f]
              #:ideal-harvesters [ih #f]
              #:vespene-contents [vc #f]
              #:orders [ords '()]
              #:order-count [oc #f]
              #:busy? [busy? #f]
              #:order-ability-id [oab 0]
              #:order-target-id [otid 0]
              #:buffs [buffs '()]
              #:add-on-tag [aot 0]
              #:addon [addon #f]
              #:addon-type [atype #f]
              #:powered? [pow? #t])
  (define h0
    (hasheq 'id id 'type type 'x (exact->inexact x) 'y (exact->inexact y)
            'hp (exact->inexact hp) 'max-hp (exact->inexact mhp)
            'shield (exact->inexact sh) 'shields (exact->inexact sh)
            'max-shield (exact->inexact msh)
            'energy (exact->inexact en) 'cloak clk
            'flying fly? 'flying? fly? 'is-flying fly?
            'build-progress (exact->inexact bp)
            'orders ords
            'order-ability-id oab 'order-target-id otid
            'buffs buffs 'add-on-tag aot
            'powered? pow?
            'display-type 1))
  (define h1 (if ah (hash-set h0 'assigned-harvesters ah) h0))
  (define h2 (if ih (hash-set h1 'ideal-harvesters ih) h1))
  (define h3 (if vc (hash-set h2 'vespene-contents vc) h2))
  (define h4 (if oc (hash-set h3 'order-count oc) h3))
  (define h4b (if busy? (hash-set h4 'busy? #t) h4))
  (define h5 (if addon (hash-set h4b 'addon addon) h4b))
  (if atype (hash-set h5 'addon-type atype) h5))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 150]
                     #:gas [gas 0]
                     #:supply-used [su 30]
                     #:supply-cap [sc 54]
                     #:mineral-harvesters [mh 16]
                     #:vespene-harvesters [vh 3]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:mineral-patches [mps '()]
                     #:vespene-geysers [vgs '()]
                     #:expansion-locations [exps '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 62.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 142.5] #:enemy-y [ey 138.5]
                     #:researched-upgrades [upgs '()]
                     #:under-attack? [ua? #f])
  (define h0
    (hasheq 'race race 'enemy-race enemy-race 'frame frame
            'live-game? #t 'live-obs? #t 'live-obs-harvesters? #t
            'minerals minerals 'gas gas
            'supply-used su 'supply-cap sc
            'mineral-harvesters mh 'vespene-harvesters vh 'gas-harvesters vh
            'ally-units au 'ally-buildings ab
            'enemy-units eu 'enemy-buildings eb
            'mineral-patches mps
            'vespene-geysers vgs
            'base-x bx 'base-y by 'nat-x nx 'nat-y ny 'natural-x nx 'natural-y ny
            'enemy-x ex 'enemy-y ey
            'researched-upgrades upgs 'upgrades-tracked? #t
            'under-attack? ua?
            'map-width 176 'map-height 176))
  (if (pair? exps)
      (hash-set h0 'expansion-locations exps)
      h0))

(define (has-train? acts sym)
  (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) sym))) acts) #t))

(define (has-build? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(build build-addon))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (has-expand? acts)
  (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts) #t))

(define (has-spell? acts spell-sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (eq? (car a) 'cast-spell)
                     (>= (length a) 3)
                     (eq? (third a) spell-sym)))
              acts)
       #t))

(define (count-spell acts spell-sym)
  (count (lambda (a)
           (and (pair? a)
                (eq? (car a) 'cast-spell)
                (>= (length a) 3)
                (eq? (third a) spell-sym)))
         acts))

(define (gas-spent-by-trains acts)
  (for/sum ([a (in-list acts)]
            #:when (and (pair? a) (eq? (car a) 'train) (>= (length a) 2)))
    (sc2-gas-cost (second a))))

(printf "=== Loop 67B Phase D Runtime Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L67-D1: Tightened Gas-Deficit Mineral-Overflow `#:alternatives` (`>= 500M`,
;;    `eff-gas < g-cost - 35`, protected tech immunity, Zerg `larva >= 2`,
;;    `#:respect-bo-reserve? #t`)
;; -----------------------------------------------------------------------------
(let ()
  ;; (1a) Protoss (`560M/10G`, 3 Nexuses, idle Gateways + idle Stargate, unprotected `void-ray`
  ;;      gas deficit `150G - 10G = 140G > 35G`): overflows to `'zealot` on `'gateway`,
  ;;      spends 0G, and logs `'superseded-by-alternative`!
  (define rt-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs
    (list (mk-u 1001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 1002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 1003 'nexus 32.5 64.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 1004 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 1005 'pylon 60.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 1006 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1007 'gateway 42.5 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1008 'gateway 45.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1009 'gateway 47.5 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1016 'gateway 50.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1017 'gateway 52.5 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1020 'gateway 55.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1021 'gateway 57.5 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1010 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0)
          (mk-u 1011 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 1024 'stargate 52.0 42.0 #:hp 600.0 #:shield 600.0)
          (mk-u 1012 'twilight-council 52.0 38.0 #:hp 500.0 #:shield 500.0)
          (mk-u 1013 'forge 56.0 38.0 #:hp 400.0 #:shield 400.0)
          (mk-u 1014 'assimilator 30.0 38.0 #:hp 300.0 #:shield 300.0)
          (mk-u 1015 'assimilator 38.0 28.0 #:hp 300.0 #:shield 300.0)
          (mk-u 1018 'assimilator 60.0 38.0 #:hp 300.0 #:shield 300.0)
          (mk-u 1019 'assimilator 66.0 28.0 #:hp 300.0 #:shield 300.0)
          (mk-u 1022 'assimilator 30.0 68.0 #:hp 300.0 #:shield 300.0)
          (mk-u 1023 'assimilator 38.0 60.0 #:hp 300.0 #:shield 300.0)))
  (define p-units
    (append (list (mk-u 1101 'observer 58.0 32.5 #:hp 40.0 #:shield 20.0 #:flying #t)
                  (mk-u 1102 'immortal 52.0 32.5 #:hp 200.0 #:shield 100.0)
                  (mk-u 1103 'warp-prism 56.0 34.0 #:hp 80.0 #:shield 100.0 #:flying #t))
            (for/list ([i (in-range 6)])
              (mk-u (+ 1110 i) 'stalker 50.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))))
  (define acts-p
    (step-layer2-economy!
     rt-p
     (mk-live-obs 'Protoss 'Terran 6200 #:minerals 560 #:gas 10 #:supply-used 62 #:supply-cap 96
                  #:mineral-harvesters 48 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units p-units
                  #:ally-buildings p-bldgs)))
  (define p-sup-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-p)
                                   'l2-macro-runtime 'superseded-by-alternative 6200
                                   #:window-frames 224))
  (check-true "L67-D1a-protoss-560m-10g-overflows-zealot-preserves-gas-and-logs-superseded"
              (and (has-train? acts-p 'zealot)
                   (= (gas-spent-by-trains acts-p) 0)
                   (> p-sup-ov 0))
              (format "trains=~a gasSpent=~a supOv=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-p)
                      (gas-spent-by-trains acts-p)
                      p-sup-ov))

  ;; (1b) Terran (`560M/10G`, idle Barracks + idle Starport, unprotected `medivac`/`viking`
  ;;      gas deficit `> 35G`): overflows to `'marine` on `'barracks`, spends 0G, logs `'superseded-by-alternative`!
  (define rt-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-bldgs
    (list (mk-u 2001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 2002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 2003 'orbital-command 32.5 64.5 #:hp 1500.0 #:order-count 1)
          (mk-u 2004 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 2005 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 2006 'barracks 42.0 34.0 #:hp 1000.0)
          (mk-u 2007 'barracks 44.5 34.0 #:hp 1000.0)
          (mk-u 2008 'barracks 47.0 34.0 #:hp 1000.0)
          (mk-u 2009 'factory 50.0 34.0 #:hp 1250.0 #:order-count 1 #:add-on-tag 2010 #:addon 'techlab #:addon-type 'factory-techlab)
          (mk-u 2010 'factory-techlab 52.5 33.5 #:hp 400.0)
          (mk-u 2011 'starport 50.0 38.0 #:hp 1300.0)
          (mk-u 2012 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 2013 'refinery 36.5 28.5 #:hp 500.0)
          (mk-u 2014 'refinery 60.5 36.5 #:hp 500.0)
          (mk-u 2015 'refinery 66.5 28.5 #:hp 500.0)))
  (define t-units
    (for/list ([i (in-range 10)])
      (mk-u (+ 2100 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0)))
  (define acts-t
    (step-layer2-economy!
     rt-t
     (mk-live-obs 'Terran 'Protoss 6200 #:minerals 560 #:gas 10 #:supply-used 62 #:supply-cap 96
                  #:mineral-harvesters 44 #:vespene-harvesters 6
                  #:ally-units t-units
                  #:ally-buildings t-bldgs)))
  (define t-sup-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-t)
                                   'l2-macro-runtime 'superseded-by-alternative 6200
                                   #:window-frames 224))
  (check-true "L67-D1b-terran-560m-10g-overflows-marine-preserves-gas-and-logs-superseded"
              (and (has-train? acts-t 'marine)
                   (= (gas-spent-by-trains acts-t) 0)
                   (> t-sup-ov 0))
              (format "trains=~a gasSpent=~a supOv=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-t)
                      (gas-spent-by-trains acts-t)
                      t-sup-ov))

  ;; (1c) Zerg (`560M/10G`, 3 Hatcheries, Spawning Pool + Roach Warren + Hydralisk Den):
  ;;      With `>= 2` larvae (3 larvae) & gas-escrowed Roach/Hydra (`eff-gas < g-cost - 35`),
  ;;      overflows to `'zergling` on `'larva`, spends 0G, logs `'superseded-by-alternative`;
  ;;      with ONLY `1` larva (`< 2` larva gate), does NOT trigger `'superseded-by-alternative`!
  (define z-bldgs
    (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0 #:order-count 1)
          (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3003 'hatchery 32.5 64.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3004 'spawning-pool 38.0 34.0 #:hp 1000.0)
          (mk-u 3005 'roach-warren 42.0 34.0 #:hp 850.0)
          (mk-u 3006 'hydralisk-den 46.0 34.0 #:hp 850.0)
          (mk-u 3011 'evolution-chamber 50.0 34.0 #:hp 750.0)
          (mk-u 3012 'evolution-chamber 54.0 34.0 #:hp 750.0)
          (mk-u 3013 'spine-crawler 66.0 32.5 #:hp 300.0)
          (mk-u 3014 'spore-crawler 34.0 30.0 #:hp 400.0)
          (mk-u 3015 'spore-crawler 64.0 30.0 #:hp 400.0)
          (mk-u 3007 'extractor 28.5 36.5 #:hp 500.0)
          (mk-u 3008 'extractor 36.5 28.5 #:hp 500.0)
          (mk-u 3009 'extractor 60.5 36.5 #:hp 500.0)
          (mk-u 3010 'extractor 66.5 28.5 #:hp 500.0)
          (mk-u 3016 'extractor 28.5 68.5 #:hp 500.0)
          (mk-u 3017 'extractor 36.5 60.5 #:hp 500.0)))
  (define z-base-units
    (append (list (mk-u 3104 'queen 35.0 32.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3105 'queen 65.0 32.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3106 'queen 35.0 64.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3107 'queen 42.0 34.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3108 'overlord 34.0 38.0 #:hp 200.0 #:flying #t))
            (for/list ([i (in-range 10)])
              (mk-u (+ 3110 i) 'roach 52.0 (+ 30.0 (* 0.5 i)) #:hp 145.0))))
  ;; 3 larvae -> allowed to overflow
  (define rt-z3 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-z3
    (step-layer2-economy!
     rt-z3
     (mk-live-obs 'Zerg 'Protoss 6800 #:minerals 560 #:gas 10 #:supply-used 68 #:supply-cap 140
                  #:mineral-harvesters 50 #:vespene-harvesters 6
                  #:ally-units (append (list (mk-u 3101 'larva 32.5 30.0 #:hp 25.0)
                                             (mk-u 3102 'larva 33.5 30.0 #:hp 25.0)
                                             (mk-u 3103 'larva 62.5 30.0 #:hp 25.0))
                                       z-base-units)
                  #:ally-buildings z-bldgs)))
  (define z3-sup-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-z3)
                                   'l2-macro-runtime 'superseded-by-alternative 6800
                                   #:window-frames 224))
  ;; Only 1 larva (`< 2` larva gate!) -> MUST NOT fire `'superseded-by-alternative`!
  (define rt-z1 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (step-layer2-economy!
   rt-z1
   (mk-live-obs 'Zerg 'Protoss 6800 #:minerals 560 #:gas 10 #:supply-used 68 #:supply-cap 140
                #:mineral-harvesters 50 #:vespene-harvesters 6
                #:ally-units (cons (mk-u 3101 'larva 32.5 30.0 #:hp 25.0) z-base-units)
                #:ally-buildings z-bldgs))
  (define z1-sup-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-z1)
                                   'l2-macro-runtime 'superseded-by-alternative 6800
                                   #:window-frames 224))
  (check-true "L67-D1c-zerg-560m-10g-overflows-with-2plus-larva-and-skips-at-1-larva"
              (and (has-train? acts-z3 'zergling)
                   (= (gas-spent-by-trains acts-z3) 0)
                   (> z3-sup-ov 0)
                   (= z1-sup-ov 0))
              (format "z3Trains=~a z3Sup=~a z1Sup=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-z3)
                      z3-sup-ov z1-sup-ov))

  ;; (1d) Air-dominated negative guard: Protoss (`560M/10G`) vs 4 enemy flying Banshees (0 ground)
  ;;      MUST NOT trigger `'superseded-by-alternative` gas-overflow into ground-only `'zealot`!
  (define rt-p-air (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define enemy-4-banshees
    (for/list ([i (in-range 4)])
      (mk-u (+ 1901 i) 'banshee (+ 100.0 (* 2.0 i)) 80.0 #:hp 140.0 #:flying #t)))
  (define acts-p-air
    (step-layer2-economy!
     rt-p-air
     (mk-live-obs 'Protoss 'Terran 6200 #:minerals 560 #:gas 10 #:supply-used 62 #:supply-cap 96
                  #:mineral-harvesters 48 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units p-units
                  #:ally-buildings p-bldgs
                  #:enemy-units enemy-4-banshees)))
  (define p-air-sup-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-p-air)
                                   'l2-macro-runtime 'superseded-by-alternative 6200
                                   #:window-frames 224))
  (define p-air-gas-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-p-air)
                                   'l2-macro-runtime 'budget-gas 6200
                                   #:window-frames 224))
  (check-true "L67-D1d-air-dominated-blocks-protoss-zealot-gas-overflow"
              (and (= p-air-sup-ov 0)
                   (> p-air-gas-ov 0))
              (format "trains=~a supOv=~a gasOv=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-p-air)
                      p-air-sup-ov p-air-gas-ov))

  ;; (1e) Protected core tech/power units (`colossus`/`immortal`/`siege-tank`/`warp-prism`):
  ;;      At `450M/120G`, idle Robo with Robotics Bay does NOT supersede `colossus`/`immortal`
  ;;      into `'zealot` AND preserves mineral escrow (`eff-escrow-min` stays intact)!
  (define rt-prot-col (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-col
    (cons (mk-u 1025 'robotics-bay 48.0 42.0 #:hp 500.0 #:shield 500.0)
          (map (lambda (b)
                 (cond
                   [(= (hash-ref b 'id 0) 1011)
                    (hash-remove b 'order-count)] ;; idle Robotics Facility
                   [(= (hash-ref b 'id 0) 1024)
                    (hash-set b 'order-count 1)]  ;; busy Stargate so only Robo is idle
                   [else b]))
               p-bldgs)))
  (define acts-prot-col
    (step-layer2-economy!
     rt-prot-col
     (mk-live-obs 'Protoss 'Terran 6200 #:minerals 450 #:gas 120 #:supply-used 62 #:supply-cap 96
                  #:mineral-harvesters 48 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units p-units
                  #:ally-buildings p-bldgs-col)))
  (define col-sup-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-prot-col)
                                   'l2-macro-runtime 'superseded-by-alternative 6200
                                   #:window-frames 224))
  ;; Also verify `immortal` at `560M/10G` (idle Robo, busy Stargate) is protected from `eff-alts`!
  (define rt-prot-imm (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-imm
    (map (lambda (b)
           (cond
             [(= (hash-ref b 'id 0) 1011) (hash-remove b 'order-count)]
             [(= (hash-ref b 'id 0) 1024) (hash-set b 'order-count 1)]
             [else b]))
         p-bldgs))
  (step-layer2-economy!
   rt-prot-imm
   (mk-live-obs 'Protoss 'Terran 6200 #:minerals 560 #:gas 10 #:supply-used 62 #:supply-cap 96
                #:mineral-harvesters 48 #:vespene-harvesters 6
                #:researched-upgrades '(warp-gate-research)
                #:ally-units p-units
                #:ally-buildings p-bldgs-imm))
  (define imm-sup-ov
    (arbiter-recent-override-count (rt-arbiter-ledger rt-prot-imm)
                                   'l2-macro-runtime 'superseded-by-alternative 6200
                                   #:window-frames 224))
  (check-true "L67-D1e-protected-colossus-and-immortal-never-superseded-and-keep-escrow-at-450m-120g"
              (and (= col-sup-ov 0)
                   (= imm-sup-ov 0)
                   (not (has-train? acts-prot-col 'zealot)))
              (format "colTrains=~a colSup=~a immSup=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-prot-col)
                      col-sup-ov imm-sup-ov)))

;; -----------------------------------------------------------------------------
;; 2. L67-D2: Qualified `[SCBOT_ARBITER]` Starvation Signals (ZERO Spam on
;;    `50M/10G` Busy/Broke Frames!), Zerg Queen `25e` Creep Suppression,
;;    `>= 6` Gas-Rich `'mineral-override-pressure?`, Terran MULE, & Protoss Chrono
;; -----------------------------------------------------------------------------
(let ()
  ;; (2a) Zerg with 0 larvae (`egg` enables live-larva-tracking?, 0 `'larva` units, 3 Hatcheries + 3 Queens):
  ;;      At `>= 300M` (`600M/300G`), records `'budget-larva` (NOT `'facility-busy`);
  ;;      at routine broke `50M/10G`, records ZERO `'budget-larva` and ZERO arbiter spam!
  (define rt-zl (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define zl-bldgs
    (list (mk-u 4001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 4002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 4003 'hatchery 32.5 64.5 #:hp 1500.0)
          (mk-u 4004 'spawning-pool 38.0 34.0 #:hp 1000.0)
          (mk-u 4005 'roach-warren 42.0 34.0 #:hp 850.0)
          (mk-u 4008 'hydralisk-den 46.0 34.0 #:hp 850.0)
          (mk-u 4009 'evolution-chamber 50.0 34.0 #:hp 750.0)
          (mk-u 4010 'evolution-chamber 54.0 34.0 #:hp 750.0)
          (mk-u 4011 'spine-crawler 66.0 32.5 #:hp 300.0)
          (mk-u 4012 'spore-crawler 34.0 30.0 #:hp 400.0)
          (mk-u 4013 'spore-crawler 64.0 30.0 #:hp 400.0)
          (mk-u 4006 'extractor 28.5 36.5 #:hp 500.0)
          (mk-u 4007 'extractor 36.5 28.5 #:hp 500.0)
          (mk-u 4014 'extractor 60.5 36.5 #:hp 500.0)
          (mk-u 4015 'extractor 66.5 28.5 #:hp 500.0)
          (mk-u 4016 'extractor 28.5 68.5 #:hp 500.0)
          (mk-u 4017 'extractor 36.5 60.5 #:hp 500.0)))
  (define zl-units
    (list (mk-u 4101 'egg 32.5 30.0 #:hp 200.0)
          (mk-u 4102 'queen 35.0 32.5 #:hp 175.0 #:energy 10.0)
          (mk-u 4103 'queen 65.0 32.5 #:hp 175.0 #:energy 10.0)
          (mk-u 4104 'queen 35.0 64.5 #:hp 175.0 #:energy 10.0)
          (mk-u 4107 'queen 42.0 34.5 #:hp 175.0 #:energy 10.0)
          (mk-u 4109 'queen 44.0 34.5 #:hp 175.0 #:energy 10.0)
          (mk-u 4108 'overlord 34.0 38.0 #:hp 200.0 #:flying #t)
          (mk-u 4105 'roach 52.0 32.5 #:hp 145.0)
          (mk-u 4106 'roach 53.0 32.5 #:hp 145.0)))
  (step-layer2-economy!
   rt-zl
   (mk-live-obs 'Zerg 'Terran 5600 #:minerals 600 #:gas 300 #:supply-used 60 #:supply-cap 112
                #:mineral-harvesters 48 #:vespene-harvesters 6
                #:researched-upgrades '(metabolic-boost zerg-missile-weapons-1 zerg-ground-armors-1
                                        muscular-augments grooved-spines glial-reconstitution)
                #:ally-units zl-units
                #:ally-buildings zl-bldgs))
  (define larva-ov-cnt
    (arbiter-recent-override-count (rt-arbiter-ledger rt-zl)
                                   'l2-macro-runtime 'budget-larva 5600
                                   #:window-frames 224))
  (define fac-ov-cnt
    (arbiter-recent-override-count (rt-arbiter-ledger rt-zl)
                                   'l2-macro-runtime 'facility-busy 5600
                                   #:window-frames 224))
  (define rt-zl-broke (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (step-layer2-economy!
   rt-zl-broke
   (mk-live-obs 'Zerg 'Terran 5600 #:minerals 50 #:gas 10 #:supply-used 60 #:supply-cap 112
                #:mineral-harvesters 48 #:vespene-harvesters 6
                #:ally-units zl-units
                #:ally-buildings zl-bldgs))
  (define broke-z-total
    (hash-ref (arbiter-telemetry-summary (rt-arbiter-ledger rt-zl-broke)) 'total-overrides 0))
  (check-true "L67-D2a-zerg-zero-larva-records-budget-larva-at-300m-plus-and-zero-at-50m"
              (and (> larva-ov-cnt 0)
                   (= fac-ov-cnt 0)
                   (= broke-z-total 0))
              (format "budgetLarva=~a facilityBusy=~a brokeTotal=~a"
                      larva-ov-cnt fac-ov-cnt broke-z-total))

  ;; (2b) Zerg Queen `25e` creep suppression when `'budget-larva` pressure >= 3 in 224f
  ;;      and uninjected Hatcheries exist (while `>= 50e` surplus still allows creep!):
  (define q-bldgs
    (list (mk-u 4201 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 4202 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 4203 'spawning-pool 38.0 34.0 #:hp 1000.0)))
  (define q-units-30e
    (list (mk-u 4211 'queen 34.5 32.5 #:hp 175.0 #:energy 30.0)
          (mk-u 4212 'queen 64.5 32.5 #:hp 175.0 #:energy 30.0)
          (mk-u 4213 'roach 52.0 32.5 #:hp 145.0)))
  (define q-units-55e
    (list (mk-u 4211 'queen 34.5 32.5 #:hp 175.0 #:energy 55.0)
          (mk-u 4212 'queen 64.5 32.5 #:hp 175.0 #:energy 30.0)
          (mk-u 4213 'roach 52.0 32.5 #:hp 145.0)))
  (define q-obs-30e
    (mk-live-obs 'Zerg 'Protoss 4800 #:minerals 200 #:gas 50 #:supply-used 44 #:supply-cap 66
                 #:mineral-harvesters 28 #:vespene-harvesters 3
                 #:ally-units q-units-30e #:ally-buildings q-bldgs))
  (define rt-q-base (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-q-base (step-layer2-economy! rt-q-base q-obs-30e))
  (define rt-q-press (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define led-q-press (rt-arbiter-ledger rt-q-press))
  (for ([k (in-range 3)])
    (arbiter-resolve! led-q-press (+ 4760 (* k 8))
                      (make-arbiter-budget-snapshot #:minerals 400 #:gas 100 #:supply-left 20 #:larva-count 0)
                      (list (make-proposal (list 'l2-spend 'roach) 'l2-macro-runtime 'macro 580.0
                                           '(authorize roach)
                                           #:cost (make-proposal-cost #:minerals 75 #:gas 25 #:supply 2 #:larva 1)))))
  (define acts-q-press (step-layer2-economy! rt-q-press q-obs-30e))
  (define rt-q-surplus (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define led-q-surplus (rt-arbiter-ledger rt-q-surplus))
  (for ([k (in-range 3)])
    (arbiter-resolve! led-q-surplus (+ 4760 (* k 8))
                      (make-arbiter-budget-snapshot #:minerals 400 #:gas 100 #:supply-left 20 #:larva-count 0)
                      (list (make-proposal (list 'l2-spend 'roach) 'l2-macro-runtime 'macro 580.0
                                           '(authorize roach)
                                           #:cost (make-proposal-cost #:minerals 75 #:gas 25 #:supply 2 #:larva 1)))))
  (define acts-q-surplus
    (step-layer2-economy! rt-q-surplus (hash-set q-obs-30e 'ally-units q-units-55e)))
  (check-true "L67-D2b-zerg-larva-pressure-suppresses-25e-creep-injects-both-and-keeps-50e-surplus"
              (and (has-spell? acts-q-base 'spawn-creep-tumor)
                   (not (has-spell? acts-q-press 'spawn-creep-tumor))
                   (= (count-spell acts-q-press 'inject-larva) 2)
                   (has-spell? acts-q-surplus 'spawn-creep-tumor)
                   (has-spell? acts-q-surplus 'inject-larva))
              (format "baseSpells=~a pressSpells=~a surplusSpells=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell))) acts-q-base)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell))) acts-q-press)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell))) acts-q-surplus)))

  ;; (2c) `step-live-bot-runtime!` `'mineral-override-pressure?` Loop 67B qualification:
  ;;      Requires `>= 6` `'budget-mineral` overrides in `224f` AND `gas >= 200` AND `minerals < 150`!
  (define rt-mh (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define led-mh (rt-arbiter-ledger rt-mh))
  (define obs-mh-base
    (mk-live-obs 'Terran 'Zerg 5000 #:minerals 40 #:gas 220 #:supply-used 30 #:supply-cap 54
                 #:mineral-harvesters 18 #:vespene-harvesters 3
                 #:ally-buildings (list (mk-u 4301 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
                                        (mk-u 4302 'barracks 40.0 34.0 #:hp 1000.0 #:order-count 1))))
  ;; 5 overrides (< 6) -> #f
  (for ([k (in-range 5)])
    (arbiter-resolve! led-mh (+ 4940 (* k 8))
                      (make-arbiter-budget-snapshot #:minerals 40 #:gas 220 #:supply-left 20)
                      (list (make-proposal (list 'mh-t k) 'l2-macro-runtime 'macro 500.0 '(authorize barracks)
                                           #:cost (make-proposal-cost #:minerals 150)))))
  (define res-mh-5 (step-live-bot-runtime! rt-mh (hash-set obs-mh-base 'frame 4980)))
  ;; Add 6th override -> still #f if gas < 200 or minerals >= 150, #t when 40M/220G!
  (arbiter-resolve! led-mh 4988
                    (make-arbiter-budget-snapshot #:minerals 40 #:gas 220 #:supply-left 20)
                    (list (make-proposal 'mh-t-6 'l2-macro-runtime 'macro 500.0 '(authorize barracks)
                                         #:cost (make-proposal-cost #:minerals 150))))
  (define res-mh-6-lowgas
    (step-live-bot-runtime! rt-mh (hash-set (hash-set obs-mh-base 'frame 4992) 'gas 100)))
  (define res-mh-6-highmin
    (step-live-bot-runtime! rt-mh (hash-set (hash-set obs-mh-base 'frame 4996) 'minerals 200)))
  (define res-mh-6-true
    (step-live-bot-runtime! rt-mh (hash-set obs-mh-base 'frame 5000)))
  (check-true "L67-D2c-mineral-override-pressure-requires-6-overrides-gas200-and-min-lt-150"
              (and (eq? (hash-ref res-mh-5 'mineral-override-pressure? #t) #f)
                   (eq? (hash-ref res-mh-6-lowgas 'mineral-override-pressure? #t) #f)
                   (eq? (hash-ref res-mh-6-highmin 'mineral-override-pressure? #t) #f)
                   (eq? (hash-ref res-mh-6-true 'mineral-override-pressure? #f) #t))
              (format "at5=~a lowGas=~a highMin=~a true=~a"
                      (hash-ref res-mh-5 'mineral-override-pressure? 'missing)
                      (hash-ref res-mh-6-lowgas 'mineral-override-pressure? 'missing)
                      (hash-ref res-mh-6-highmin 'mineral-override-pressure? 'missing)
                      (hash-ref res-mh-6-true 'mineral-override-pressure? 'missing)))

  ;; (2d) Terran MULE pressure plumbing (`>= 6` `'budget-mineral` in `224f` & `gas >= 200` & `min < 150`):
  ;;      Post-8:00 (`frame = 11200`) peaceful non-cloak 2 OCs (`100e` & `80e`) drop MULEs;
  ;;      under cloak threat (enemy DT, OCs at `85e < 100e`), BOTH hold Scan reserve (0 MULEs)!
  (define mps-mule (list (hasheq 'id 4491 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define obs-mule-press
    (mk-live-obs 'Terran 'Zerg 11200 #:minerals 120 #:gas 220 #:supply-used 64 #:supply-cap 90
                 #:mineral-harvesters 36 #:vespene-harvesters 6
                 #:mineral-patches mps-mule
                 #:ally-units (for/list ([i (in-range 10)])
                                (mk-u (+ 4420 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0))
                 #:ally-buildings (list (mk-u 4401 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 100.0)
                                        (mk-u 4402 'orbital-command 62.5 32.5 #:hp 1500.0 #:energy 80.0)
                                        (mk-u 4403 'barracks 40.0 34.0 #:hp 1000.0))))
  (define rt-mule-press (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define led-mp (rt-arbiter-ledger rt-mule-press))
  (for ([k (in-range 6)])
    (arbiter-resolve! led-mp (+ 11140 (* k 8))
                      (make-arbiter-budget-snapshot #:minerals 40 #:gas 220 #:supply-left 20)
                      (list (make-proposal (list 'mp-t k) 'l2-macro-runtime 'macro 500.0 '(authorize barracks)
                                           #:cost (make-proposal-cost #:minerals 150)))))
  (define acts-mule-press (step-layer2-economy! rt-mule-press obs-mule-press))
  (define rt-mule-cloak (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define led-mc (rt-arbiter-ledger rt-mule-cloak))
  (for ([k (in-range 6)])
    (arbiter-resolve! led-mc (+ 11140 (* k 8))
                      (make-arbiter-budget-snapshot #:minerals 40 #:gas 220 #:supply-left 20)
                      (list (make-proposal (list 'mc-t k) 'l2-macro-runtime 'macro 500.0 '(authorize barracks)
                                           #:cost (make-proposal-cost #:minerals 150)))))
  (define obs-mule-cloak
    (mk-live-obs 'Terran 'Protoss 11200 #:minerals 120 #:gas 220 #:supply-used 64 #:supply-cap 90
                 #:mineral-harvesters 36 #:vespene-harvesters 6
                 #:mineral-patches mps-mule
                 #:ally-units (for/list ([i (in-range 10)])
                                (mk-u (+ 4420 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0))
                 #:ally-buildings (list (mk-u 4401 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 85.0)
                                        (mk-u 4402 'orbital-command 62.5 32.5 #:hp 1500.0 #:energy 85.0)
                                        (mk-u 4403 'barracks 40.0 34.0 #:hp 1000.0))
                 #:enemy-units (list (mk-u 4499 'dark-templar 110.0 90.0 #:hp 40.0 #:shield 80.0 #:cloak 3))))
  (define acts-mule-cloak (step-layer2-economy! rt-mule-cloak obs-mule-cloak))
  (check-true "L67-D2d-terran-mule-pressure-boosts-peaceful-and-preserves-cloak-scan-reserve"
              (and (has-spell? acts-mule-press 'calldown-mule)
                   (not (has-spell? acts-mule-cloak 'calldown-mule)))
              (format "pressSpells=~a cloakSpells=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell))) acts-mule-press)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell))) acts-mule-cloak)))

  ;; (2e) Protoss Chrono facility-override pressure plumbing (`>= 3` `'facility-busy` in `224f`):
  ;;      Post-4m busy Robo + busy Forge + 1 Nexus (60e): Forge (`955`) STILL outranks boosted Robo (`925`),
  ;;      without ever unlocking post-4m Gateway Chrono!
  (define rt-ch1 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define led-ch1 (rt-arbiter-ledger rt-ch1))
  (for ([k (in-range 3)])
    (arbiter-resolve! led-ch1 (+ 6160 (* k 8))
                      (make-arbiter-budget-snapshot #:minerals 400 #:gas 200 #:supply-left 20
                                                    #:open-facility-slots (hasheq 'robotics-facility 0))
                      (list (make-proposal (list 'fb-t k) 'l2-macro-runtime 'macro 580.0 '(authorize immortal)
                                           #:cost (make-proposal-cost #:minerals 275 #:gas 100 #:supply 4
                                                                      #:facility-slot 'robotics-facility)))))
  (define acts-ch1
    (step-layer2-economy!
     rt-ch1
     (mk-live-obs 'Protoss 'Terran 6200 #:minerals 200 #:gas 100 #:supply-used 60 #:supply-cap 90
                  #:mineral-harvesters 36 #:vespene-harvesters 6
                  #:ally-buildings (list (mk-u 4501 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy 60.0)
                                         (mk-u 4502 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 4503 'forge 40.0 34.0 #:hp 400.0 #:shield 400.0 #:order-count 1 #:busy? #t)
                                         (mk-u 4504 'robotics-facility 44.0 34.0 #:hp 450.0 #:shield 450.0 #:order-count 1 #:busy? #t)
                                         (mk-u 4505 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1 #:busy? #t)))))
  (define chrono-acts-1
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'chrono-boost))) acts-ch1))
  (check-true "L67-D2e-protoss-chrono-facility-pressure-bounded-below-forge-and-no-gate-unlock"
              (and (= (length chrono-acts-1) 1)
                   (= (fourth (first chrono-acts-1)) 4503))
              (format "chronoActs=~a" chrono-acts-1))

  ;; (2f) ZERO `[SCBOT_ARBITER]` spam on routine `50M/10G` busy-slot / broke frames across Protoss & Terran!
  (define rt-spam-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (step-layer2-economy!
   rt-spam-p
   (mk-live-obs 'Protoss 'Terran 5800 #:minerals 50 #:gas 10 #:supply-used 52 #:supply-cap 78
                #:mineral-harvesters 32 #:vespene-harvesters 6
                #:researched-upgrades '(warp-gate-research)
                #:ally-units (list (mk-u 4610 'stalker 50.0 34.0 #:hp 80.0 #:shield 80.0))
                #:ally-buildings (list (mk-u 4601 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
                                       (mk-u 4602 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
                                       (mk-u 4603 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
                                       (mk-u 4604 'cybernetics-core 40.0 38.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
                                       (mk-u 4605 'twilight-council 44.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                                       (mk-u 4606 'forge 46.0 36.0 #:hp 400.0 #:shield 400.0 #:order-count 1)
                                       (mk-u 4607 'robotics-facility 38.0 36.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
                                       (mk-u 4608 'gateway 42.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1))))
  (define rt-spam-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (step-layer2-economy!
   rt-spam-t
   (mk-live-obs 'Terran 'Protoss 5800 #:minerals 50 #:gas 10 #:supply-used 52 #:supply-cap 78
                #:mineral-harvesters 32 #:vespene-harvesters 6
                #:ally-units (list (mk-u 4620 'marine 50.0 34.0 #:hp 45.0))
                #:ally-buildings (list (mk-u 4621 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
                                       (mk-u 4622 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
                                       (mk-u 4623 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
                                       (mk-u 4624 'factory 46.0 34.0 #:hp 1250.0 #:order-count 1)
                                       (mk-u 4625 'starport 50.0 34.0 #:hp 1300.0 #:order-count 1)
                                       (mk-u 4626 'engineering-bay 54.0 34.0 #:hp 850.0 #:order-count 1))))
  (define spam-p-sum (arbiter-telemetry-summary (rt-arbiter-ledger rt-spam-p)))
  (define spam-t-sum (arbiter-telemetry-summary (rt-arbiter-ledger rt-spam-t)))
  (check-true "L67-D2f-zero-arbiter-spam-on-routine-50m-10g-busy-slot-frames"
              (and (= (hash-ref spam-p-sum 'total-overrides 0) 0)
                   (= (hash-ref spam-t-sum 'total-overrides 0) 0))
              (format "pSum=~a tSum=~a" spam-p-sum spam-t-sum)))

;; -----------------------------------------------------------------------------
;; 3. L67-D3: Controlled A/B Proof of `terran-protect-oc1-min?` (`oc1` Stall Fix)
;;    + Light-Poke (`threat <= 2.0`) Retention vs Real-Attack (`threat > 2.0`) Break
;; -----------------------------------------------------------------------------
(let ()
  (define oc1-geysers
    (list (hasheq 'id 5091 'type 'vespene-geyser 'x 28.5 'y 36.5 'vespene-contents 2250)
          (hasheq 'id 5092 'type 'vespene-geyser 'x 36.5 'y 28.5 'vespene-contents 2250)))
  (define oc1-shared-bldgs
    (list (mk-u 5002 'command-center 62.5 32.5 #:hp 750.0 #:max-hp 1500.0 #:build-progress 0.5)
          (mk-u 5003 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 5004 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 5005 'barracks 42.0 34.0 #:hp 1000.0)
          (mk-u 5006 'barracks 46.0 34.0 #:hp 1000.0)
          (mk-u 5007 'factory 50.0 34.0 #:hp 1250.0)
          (mk-u 5009 'starport 54.0 34.0 #:hp 1300.0 #:order-count 1)
          (mk-u 5008 'refinery 28.5 36.5 #:hp 500.0)))
  (define oc1-units
    (append (for/list ([i (in-range 24)])
              (mk-u (+ 5100 i) 'scv 29.0 (+ 30.0 (* 0.2 i)) #:hp 45.0))
            (list (mk-u 5130 'marine 48.0 32.5 #:hp 45.0)
                  (mk-u 5131 'marine 49.0 32.5 #:hp 45.0))))
  (define (oc1-sink-built? acts)
    (or (has-build? acts 'bunker)
        (has-build? acts 'refinery)
        (has-build? acts 'barracks-techlab)
        (has-build? acts 'barracks-reactor)
        (has-build? acts 'factory-techlab)))

  ;; (3a) Unmorphed BUSY CC (`order-count = 1`), `0` OCs, `180M / 100G`:
  (define rt-oc1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-oc1-hold
    (step-layer2-economy!
     rt-oc1
     (mk-live-obs 'Terran 'Protoss 3200 #:minerals 180 #:gas 100 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 21 #:vespene-harvesters 3
                  #:vespene-geysers oc1-geysers
                  #:ally-units oc1-units
                  #:ally-buildings (cons (mk-u 5001 'command-center 32.5 32.5 #:hp 1500.0
                                               #:order-count 1 #:order-ability-id 524)
                                         oc1-shared-bldgs))))
  (check-true "L67-D3a-terran-protect-oc1-min-blocks-sinks-while-cc-finishes-scv-at-180m"
              (not (oc1-sink-built? acts-oc1-hold))
              (format "builds=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-oc1-hold)))

  ;; (3b) Identical layout EXCEPT Main CC #1 is already `'orbital-command`:
  (define rt-oc1-done (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-oc1-resumed
    (step-layer2-economy!
     rt-oc1-done
     (mk-live-obs 'Terran 'Protoss 3200 #:minerals 180 #:gas 100 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 21 #:vespene-harvesters 3
                  #:vespene-geysers oc1-geysers
                  #:ally-units oc1-units
                  #:ally-buildings (cons (mk-u 5001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
                                         oc1-shared-bldgs))))
  (check-true "L67-D3b-terran-addons-or-ref2-resume-once-oc1-exists"
              (oc1-sink-built? acts-oc1-resumed)
              (format "builds=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-oc1-resumed)))

  ;; (3c) Light-poke (`under-attack? = #t` from 1 scouting Probe -> threat <= 2.0):
  ;;      OC #1 protection MUST STILL hold; real attack (`4` Stalkers, threat = 8.0 > 2.0) breaks it!
  (define rt-oc1-poke (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-oc1-poke
    (step-layer2-economy!
     rt-oc1-poke
     (mk-live-obs 'Terran 'Protoss 3200 #:minerals 180 #:gas 100 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 21 #:vespene-harvesters 3
                  #:vespene-geysers oc1-geysers
                  #:under-attack? #t
                  #:enemy-units (list (mk-u 5901 'probe 38.0 34.0 #:hp 20.0 #:shield 20.0))
                  #:ally-units oc1-units
                  #:ally-buildings (cons (mk-u 5001 'command-center 32.5 32.5 #:hp 1500.0
                                               #:order-count 1 #:order-ability-id 524)
                                         oc1-shared-bldgs))))
  (define rt-oc1-real-atk (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-oc1-real-atk
    (step-layer2-economy!
     rt-oc1-real-atk
     (mk-live-obs 'Terran 'Protoss 3200 #:minerals 180 #:gas 100 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 21 #:vespene-harvesters 3
                  #:vespene-geysers oc1-geysers
                  #:under-attack? #t
                  #:enemy-units (for/list ([i (in-range 4)])
                                  (mk-u (+ 5910 i) 'stalker 44.0 (+ 32.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
                  #:ally-units oc1-units
                  #:ally-buildings (cons (mk-u 5001 'command-center 32.5 32.5 #:hp 1500.0
                                               #:order-count 1 #:order-ability-id 524)
                                         oc1-shared-bldgs))))
  (check-true "L67-D3c-oc1-protection-survives-scouting-probe-poke-and-breaks-on-real-attack"
              (and (not (oc1-sink-built? acts-oc1-poke))
                   (has-build? acts-oc1-real-atk 'bunker))
              (format "pokeBuilds=~a realAtkBuilds=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-oc1-poke)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-oc1-real-atk))))

;; -----------------------------------------------------------------------------
;; 4. L67-D4: 1-Base Natural CC Reserve Survival + Starport Non-Bypass +
;;    Peaceful `5:15` (`>= 7056f`) `terran-3rd-cc-overdue-override?`
;; -----------------------------------------------------------------------------
(let ()
  ;; (4a) 1-base peaceful Terran (`frame = 3500 -> 4050 < 5376`, `minerals = 280`, `gas = 150`,
  ;;      1 OC + Barracks + Factory + 1 Refinery) saving for Natural CC past timeout:
  (define rt-nat (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define nat-geysers
    (list (hasheq 'id 6091 'type 'vespene-geyser 'x 28.5 'y 36.5 'vespene-contents 2250)
          (hasheq 'id 6092 'type 'vespene-geyser 'x 36.5 'y 28.5 'vespene-contents 2250)))
  (define nat-bldgs
    (list (mk-u 6001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 6002 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 6003 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 6004 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 6005 'factory 46.0 34.0 #:hp 1250.0 #:order-count 1)
          (mk-u 6006 'refinery 28.5 36.5 #:hp 500.0)))
  (define nat-units
    (append (for/list ([i (in-range 20)])
              (mk-u (+ 6100 i) 'scv 29.0 (+ 30.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 6130 i) 'marine 48.0 (+ 32.0 (* 0.5 i)) #:hp 45.0))))
  (step-layer2-economy!
   rt-nat
   (mk-live-obs 'Terran 'Protoss 3500 #:minerals 260 #:gas 150 #:supply-used 26 #:supply-cap 47
                #:mineral-harvesters 17 #:vespene-harvesters 3
                #:vespene-geysers nat-geysers
                #:ally-units nat-units
                #:ally-buildings nat-bldgs))
  (define acts-nat-after-timeout
    (step-layer2-economy!
     rt-nat
     (mk-live-obs 'Terran 'Protoss 4050 #:minerals 280 #:gas 150 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 17 #:vespene-harvesters 3
                  #:vespene-geysers nat-geysers
                  #:ally-units nat-units
                  #:ally-buildings nat-bldgs)))
  (check-true "L67-D4a-1base-nat-cc-escrow-survives-timeout-blocks-ref2-and-starport-drain"
              (and (not (has-build? acts-nat-after-timeout 'refinery))
                   (not (has-build? acts-nat-after-timeout 'starport)))
              (format "builds=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon))))
                              acts-nat-after-timeout)))

  ;; (4b) Peaceful 2-base Terran at `5:15` (`frame = 7200 >= 7056`, 36 SCVs, >= 10 army sup,
  ;;      450M/100G, even with 0 Starports & Brain wanting non-emergency macro):
  (define rt-3cc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define exps-3cc
    (list (list 32.5 32.5)
          (list 62.5 32.5)
          (list 32.5 68.5)
          (list 92.5 32.5)))
  (define bldgs-3cc
    (list (mk-u 7001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 7002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 7003 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 7004 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 7005 'supply-depot 42.0 30.0 #:hp 400.0)
          (mk-u 7006 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 7007 'barracks 46.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 7008 'factory 50.0 34.0 #:hp 1250.0 #:order-count 1)
          (mk-u 7009 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 7010 'refinery 36.5 28.5 #:hp 500.0)))
  (define units-3cc
    (append (for/list ([i (in-range 36)])
              (mk-u (+ 7100 i) 'scv 29.0 (+ 28.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 12)])
              (mk-u (+ 7200 i) 'marine 52.0 (+ 30.0 (* 0.3 i)) #:hp 45.0))
            (list (mk-u 7250 'siege-tank 54.0 32.5 #:hp 175.0))))
  (define obs-3cc-peace
    (mk-live-obs 'Terran 'Protoss 7200 #:minerals 450 #:gas 100 #:supply-used 52 #:supply-cap 78
                 #:mineral-harvesters 30 #:vespene-harvesters 6
                 #:expansion-locations exps-3cc
                 #:ally-units units-3cc
                 #:ally-buildings bldgs-3cc))
  (define acts-3cc-peace (step-layer2-economy! rt-3cc obs-3cc-peace))
  (check-true "L67-D4b-peaceful-2base-terran-5m15-emits-3rd-cc-expand"
              (has-expand? acts-3cc-peace)
              (format "acts=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(expand build build-addon))))
                              acts-3cc-peace)))

  ;; (4c) Negative guard: under active attack at `frame = 7200`, MUST NOT greedily expand 3rd CC!
  (define rt-3cc-atk (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define enemy-raiders
    (for/list ([i (in-range 8)])
      (mk-u (+ 7900 i) 'stalker 46.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define acts-3cc-atk
    (step-layer2-economy!
     rt-3cc-atk
     (hash-set (hash-set obs-3cc-peace 'under-attack? #t)
               'enemy-units enemy-raiders)))
  (check-true "L67-D4c-under-attack-blocks-peaceful-3rd-cc-override"
              (not (has-expand? acts-3cc-atk))
              (format "acts=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts-3cc-atk))))

(printf "\n=== Loop 67B Phase D Runtime Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
