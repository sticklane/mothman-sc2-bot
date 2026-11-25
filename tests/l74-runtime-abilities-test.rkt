#lang racket/base

;; =============================================================================
;; `tests/l74-runtime-abilities-test.rkt`
;; Loop 74 Lane B — Hydralisk Transfuse Exemption, Queen Combat/Tumor Energy
;; Hold, Protoss Blink-First, Peaceful 2-Base Templar Archive & Caster Chrono Hold
;;
;; Covers:
;;   1. L74-B1a: `l2-transfuse-targets` exempts >= 50e Queen near 50/90 HP
;;      Hydralisk from inject/creep; does NOT exempt near 75/90 HP Hydralisk!
;;   2. L74-B1b: Dedicated creeping Queen at 40e holds for 75e surplus when
;;      >= 3 active creep tumors exist or threat >= 6, while keeping 100%
;;      Hatchery Inject Larva at 25e and early 0..2 tumor startup intact!
;;   3. L74-B2: `blink-first?` researches Blink before Charge in PvP and in
;;      Stalker-core PvT (>= 4 Stalkers, < 4 Zealots), while preserving
;;      Charge-first in PvZ (no Mutas/AA) and Zealot-heavy PvT (>= 4 Zealots)!
;;   4. L74-B3a: Peaceful 2-base PvT/PvP `templar-archive` unlock (>= 66 sup,
;;      >= 200G, Robo/RoboBay present/pending) while respecting gas < 200,
;;      under-attack, and Colossus escrow!
;;   5. L74-B3b: `#:has-ally-caster?` wiring holds 75e Nexus below 100e at
;;      >= 52w when an allied caster exists, while still boosting at >= 100e!
;; =============================================================================

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt")

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
              #:flying [fly? #f]
              #:build-progress [bp 1.0]
              #:orders [ords '()]
              #:order-count [oc #f]
              #:order-ability-id [oab 0]
              #:order-target-id [otid 0]
              #:busy? [busy? #f]
              #:buffs [buffs '()]
              #:powered? [pow? #t])
  (define h0
    (hasheq 'id id 'type type 'x (exact->inexact x) 'y (exact->inexact y)
            'hp (exact->inexact hp) 'max-hp (exact->inexact mhp)
            'shield (exact->inexact sh) 'shields (exact->inexact sh)
            'max-shield (exact->inexact msh)
            'energy (exact->inexact en) 'cloak 3
            'flying fly? 'flying? fly? 'is-flying fly?
            'build-progress (exact->inexact bp)
            'orders ords
            'order-ability-id oab 'order-target-id otid
            'busy? busy?
            'buffs buffs
            'powered? pow?
            'display-type 1))
  (if oc (hash-set h0 'order-count oc) h0))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200]
                     #:gas [gas 150]
                     #:supply-used [su 68]
                     #:supply-cap [sc 118]
                     #:mineral-harvesters [mh 34]
                     #:vespene-harvesters [vh 12]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb #f]
                     #:expansion-locations [exps '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 62.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 142.5] #:enemy-y [ey 138.5]
                     #:researched-upgrades [upgs '()]
                     #:under-attack? [ua? #f])
  (define eff-eb
    (if eb
        eb
        (list (mk-u 9001
                    (case enemy-race
                      [(Zerg) 'hatchery]
                      [(Protoss) 'nexus]
                      [else 'orbital-command])
                    ex ey #:hp 1500.0))))
  (define h0
    (hasheq 'race race 'enemy-race enemy-race 'frame frame
            'live-game? #t 'live-obs? #t 'live-obs-harvesters? #t
            'enable-opponent-world-model #t
            'minerals minerals 'gas gas
            'supply-used su 'supply-cap sc
            'mineral-harvesters mh 'vespene-harvesters vh 'gas-harvesters vh
            'ally-units au 'ally-buildings ab
            'enemy-units eu 'enemy-buildings eff-eb
            'base-x bx 'base-y by 'nat-x nx 'nat-y ny 'natural-x nx 'natural-y ny
            'enemy-x ex 'enemy-y ey
            'researched-upgrades upgs 'upgrades-tracked? #t
            'under-attack? ua? 'under-attack ua?
            'map-width 176 'map-height 176))
  (if (pair? exps)
      (hash-set* h0 'expansion-locations exps 'expansion-candidates exps)
      h0))

(define (has-build? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(build build-addon morph-building))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (has-research? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (eq? (car a) 'research)
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (has-spell? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (eq? (car a) 'cast-spell)
                     (>= (length a) 3)
                     (eq? (third a) sym)))
              acts)
       #t))

(define (has-queen-inject? acts)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (or (eq? (car a) 'inject-larva)
                         (and (eq? (car a) 'cast-spell)
                              (>= (length a) 3)
                              (eq? (third a) 'inject-larva)))))
              acts)
       #t))

(define (has-creep-tumor? acts)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (or (eq? (car a) 'spawn-creep-tumor)
                         (and (eq? (car a) 'cast-spell)
                              (>= (length a) 3)
                              (eq? (third a) 'spawn-creep-tumor)))))
              acts)
       #t))

(define (fmt-fail rt acts)
  (define tel (live-bot-runtime-last-telemetry rt))
  (define pl (and (hash? tel) (hash-ref tel 'priority-log-line #f)))
  (define macro-acts
    (filter (lambda (a)
              (and (pair? a)
                   (memq (car a) '(build build-addon morph-building train morph-unit warp-in
                                   research expand cast-spell inject-larva spawn-creep-tumor))))
            acts))
  (format "macro=~a prio=~a" macro-acts pl))

(define (mk-drones n [start-id 3100])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) 'drone (+ 28.0 (* 0.15 (modulo i 16))) (+ 30.0 (* 0.25 (quotient i 16))) #:hp 40.0)))

(define (mk-probes n [start-id 2100])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) 'probe (+ 28.0 (* 0.15 (modulo i 16))) (+ 30.0 (* 0.25 (quotient i 16))) #:hp 20.0 #:shield 20.0)))

(define exps-2 (list (list 32.5 32.5) (list 62.5 32.5)))

(printf "=== Loop 74 Lane B Runtime Abilities, Blink-First & Templar Archive Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L74-B1a: Hydralisk Transfuse Target Filter (`mhp >= 85.0`, `missing >= 35.0`)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-1h
    (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 3002 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 3003 'hydralisk-den 39.0 34.0 #:hp 850.0)
          (mk-u 3050 'creep-tumor-burrowed 45.0 34.0 #:hp 50.0)
          (mk-u 3051 'creep-tumor-burrowed 49.0 34.0 #:hp 50.0)
          (mk-u 3052 'creep-tumor-burrowed 53.0 34.0 #:hp 50.0)))
  (define (mk-z-hydra-units hydra-hp)
    (append (mk-drones 24)
            (list (mk-u 3201 'queen 35.0 34.0 #:hp 175.0 #:energy 55.0)
                  (mk-u 3210 'hydralisk 40.0 34.0 #:hp hydra-hp #:max-hp 90.0)
                  (mk-u 3250 'overlord 28.0 28.0 #:hp 200.0 #:flying #t))))

  ;; 1a: 50/90 HP Hydralisk (missing=40 >= 35, 55.6% < 70%) -> 55e Queen EXEMPTED from inject & creep!
  (define rt-1a (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-1a
    (step-layer2-economy!
     rt-1a
     (mk-live-obs 'Zerg 'Protoss 6000 #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (mk-z-hydra-units 50.0) #:ally-buildings z-bldgs-1h)))
  (check-true "L74-B1-1a-55e-queen-exempt-from-inject-creep-near-50-90-hydralisk"
              (and (not (has-queen-inject? acts-1a))
                   (not (has-creep-tumor? acts-1a)))
              (fmt-fail rt-1a acts-1a))

  ;; 1b: 75/90 HP Hydralisk (missing=15 < 35) -> 55e Queen NOT exempted -> injects Hatchery normally!
  (define rt-1b (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-1b
    (step-layer2-economy!
     rt-1b
     (mk-live-obs 'Zerg 'Protoss 6000 #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (mk-z-hydra-units 75.0) #:ally-buildings z-bldgs-1h)))
  (check-true "L74-B1-1b-55e-queen-injects-normally-near-75-90-hydralisk"
              (has-queen-inject? acts-1b)
              (fmt-fail rt-1b acts-1b)))

;; -----------------------------------------------------------------------------
;; 2. L74-B1b: Queen Combat / Threat / >= 3 Tumors Energy Hold (Preserving 100% Inject!)
;; -----------------------------------------------------------------------------
(let ()
  ;; 2 already-injected Hatcheries (buff 11 = QueenSpawnLarvaTimer) + N active creep tumors
  (define (mk-z-creep-bldgs tumor-cnt #:injected? [inj? #t])
    (define buffs (if inj? '(11) '()))
    (append
     (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0 #:buffs buffs)
           (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0 #:buffs buffs)
           (mk-u 3003 'spawning-pool 36.0 34.0 #:hp 1000.0))
     (for/list ([i (in-range tumor-cnt)])
       (mk-u (+ 3050 i) 'creep-tumor-burrowed (+ 45.0 (* 4.0 i)) 34.0 #:hp 50.0))))
  ;; 3 Queens on 2 bases -> Queen #3 (id 3203) is dedicated creeper
  (define (mk-z-units-3q q3-energy)
    (append (mk-drones 30)
            (list (mk-u 3201 'queen 33.5 33.5 #:hp 175.0 #:energy 30.0)
                  (mk-u 3202 'queen 63.5 33.5 #:hp 175.0 #:energy 30.0)
                  (mk-u 3203 'queen 50.0 34.0 #:hp 175.0 #:energy q3-energy)
                  (mk-u 3250 'overlord 28.0 28.0 #:hp 200.0 #:flying #t))))
  (define z-units-3q (mk-z-units-3q 40.0))

  ;; 2a: >= 3 active creep tumors -> 40e dedicated creeper holds for 75e surplus (NO tumor cast!)
  (define rt-2a (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2a
    (step-layer2-economy!
     rt-2a
     (mk-live-obs 'Zerg 'Terran 5600 #:minerals 150 #:gas 50 #:supply-used 36 #:supply-cap 62
                  #:mineral-harvesters 30 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-3q #:ally-buildings (mk-z-creep-bldgs 3))))
  (check-true "L74-B1-2a-3plus-tumors-40e-creeper-holds-for-transfuse-no-tumor"
              (not (has-creep-tumor? acts-2a))
              (fmt-fail rt-2a acts-2a))

  ;; 2b: Only 1 active tumor, but live-enemy-threat-supply >= 6 (7 Marauders=14 raw -> 9 net >= 6) -> holds!
  (define prox-threat
    (for/list ([i (in-range 7)]) (mk-u (+ 9600 i) 'marauder 82.0 (+ 30.0 (* 0.6 i)) #:hp 125.0)))
  (define rt-2b (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2b
    (step-layer2-economy!
     rt-2b
     (mk-live-obs 'Zerg 'Terran 5600 #:minerals 150 #:gas 50 #:supply-used 36 #:supply-cap 62
                  #:mineral-harvesters 30 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-3q #:ally-buildings (mk-z-creep-bldgs 1)
                  #:enemy-units prox-threat)))
  (check-true "L74-B1-2b-threat-ge-6-40e-creeper-holds-for-transfuse-no-tumor"
              (not (has-creep-tumor? acts-2b))
              (fmt-fail rt-2b acts-2b))

  ;; 2c: Peaceful with 1 tumor (< 3) -> 40e creeper DOES cast tumor; AND >= 3 tumors uninjected STILL injects!
  (define rt-2c-creep (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2c-creep
    (step-layer2-economy!
     rt-2c-creep
     (mk-live-obs 'Zerg 'Terran 5600 #:minerals 150 #:gas 50 #:supply-used 36 #:supply-cap 62
                  #:mineral-harvesters 30 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-3q #:ally-buildings (mk-z-creep-bldgs 1))))
  (define rt-2c-inj (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2c-inj
    (step-layer2-economy!
     rt-2c-inj
     (mk-live-obs 'Zerg 'Terran 5600 #:minerals 150 #:gas 50 #:supply-used 36 #:supply-cap 62
                  #:mineral-harvesters 30 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-3q #:ally-buildings (mk-z-creep-bldgs 3 #:injected? #f))))
  (check-true "L74-B1-2c-peaceful-1tumor-creeps-and-3tumors-still-injects-100pct"
              (and (has-creep-tumor? acts-2c-creep)
                   (has-queen-inject? acts-2c-inj))
              (format "creep=~a inj=~a" (fmt-fail rt-2c-creep acts-2c-creep) (fmt-fail rt-2c-inj acts-2c-inj)))

  ;; 2d: >= 3 active tumors with 80e (>= 75e surplus) Queen -> DOES drop tumor (retaining >= 50e for Transfuse!)
  (define rt-2d (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2d
    (step-layer2-economy!
     rt-2d
     (mk-live-obs 'Zerg 'Terran 5600 #:minerals 150 #:gas 50 #:supply-used 36 #:supply-cap 62
                  #:mineral-harvesters 30 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (mk-z-units-3q 80.0) #:ally-buildings (mk-z-creep-bldgs 3))))
  (check-true "L74-B1-2d-3plus-tumors-80e-surplus-queen-casts-tumor-retaining-50e"
              (has-creep-tumor? acts-2d)
              (fmt-fail rt-2d acts-2d)))

;; -----------------------------------------------------------------------------
;; 3. L74-B2: Protoss `blink-first?` in PvP & Stalker-Core PvT (Charge-First in PvZ/Zealot-PvT)
;; -----------------------------------------------------------------------------
(let ()
  (define p-bldgs-tc
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 2003 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 2004 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 2005 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2006 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2007 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2014 'gateway 52.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2015 'gateway 40.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2016 'gateway 44.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2008 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
          (mk-u 2009 'twilight-council 40.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 0)
          (mk-u 2010 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 2017 'forge 36.0 42.0 #:hp 400.0 #:shield 400.0 #:order-count 1)
          (mk-u 2011 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2012 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2013 'assimilator 58.5 36.5 #:hp 300.0 #:shield 300.0)))
  (define (mk-p-tc-units stalkers zealots)
    (append (mk-probes 36)
            (for/list ([i (in-range stalkers)]) (mk-u (+ 2200 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range zealots)]) (mk-u (+ 2250 i) 'zealot 54.0 (+ 30.0 (* 0.5 i)) #:hp 100.0 #:shield 50.0))))

  ;; 3a: PvP -> researches 'blink before 'charge!
  (define rt-3a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3a
    (step-layer2-economy!
     rt-3a
     (mk-live-obs 'Protoss 'Protoss 6400 #:minerals 180 #:gas 160 #:supply-used 48 #:supply-cap 78
                  #:mineral-harvesters 27 #:vespene-harvesters 9
                  #:expansion-locations exps-2
                  #:ally-units (mk-p-tc-units 4 2) #:ally-buildings p-bldgs-tc
                  #:researched-upgrades '(warpgate warp-gate-research))))
  (check-true "L74-B2-3a-pvp-researches-blink-before-charge"
              (and (has-research? acts-3a 'blink)
                   (not (has-research? acts-3a 'charge)))
              (fmt-fail rt-3a acts-3a))

  ;; 3b: PvT with 4 Stalkers + 2 Zealots -> researches 'blink before 'charge!
  (define rt-3b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3b
    (step-layer2-economy!
     rt-3b
     (mk-live-obs 'Protoss 'Terran 6400 #:minerals 180 #:gas 160 #:supply-used 48 #:supply-cap 78
                  #:mineral-harvesters 27 #:vespene-harvesters 9
                  #:expansion-locations exps-2
                  #:ally-units (mk-p-tc-units 4 2) #:ally-buildings p-bldgs-tc
                  #:researched-upgrades '(warpgate warp-gate-research))))
  (check-true "L74-B2-3b-pvt-stalker-core-researches-blink-before-charge"
              (and (has-research? acts-3b 'blink)
                   (not (has-research? acts-3b 'charge)))
              (fmt-fail rt-3b acts-3b))

  ;; 3c: PvZ (no Mutas/AA) with 4 Stalkers + 2 Zealots -> STILL researches 'charge before 'blink!
  (define rt-3c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3c
    (step-layer2-economy!
     rt-3c
     (mk-live-obs 'Protoss 'Zerg 6400 #:minerals 180 #:gas 160 #:supply-used 48 #:supply-cap 78
                  #:mineral-harvesters 27 #:vespene-harvesters 9
                  #:expansion-locations exps-2
                  #:ally-units (mk-p-tc-units 4 2) #:ally-buildings p-bldgs-tc
                  #:researched-upgrades '(warpgate warp-gate-research))))
  (check-true "L74-B2-3c-pvz-no-aa-still-researches-charge-before-blink"
              (and (has-research? acts-3c 'charge)
                   (not (has-research? acts-3c 'blink)))
              (fmt-fail rt-3c acts-3c))

  ;; 3d: PvT with 4 Stalkers + 4 Zealots (>= 4 Zealots) -> STILL researches 'charge before 'blink!
  (define rt-3d (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3d
    (step-layer2-economy!
     rt-3d
     (mk-live-obs 'Protoss 'Terran 6400 #:minerals 180 #:gas 160 #:supply-used 52 #:supply-cap 78
                  #:mineral-harvesters 27 #:vespene-harvesters 9
                  #:expansion-locations exps-2
                  #:ally-units (mk-p-tc-units 4 4) #:ally-buildings p-bldgs-tc
                  #:researched-upgrades '(warpgate warp-gate-research))))
  (check-true "L74-B2-3d-pvt-zealot-heavy-still-researches-charge-before-blink"
              (and (has-research? acts-3d 'charge)
                   (not (has-research? acts-3d 'blink)))
              (fmt-fail rt-3d acts-3d)))

;; -----------------------------------------------------------------------------
;; 4. L74-B3a: Peaceful 2-Base PvT/PvP `templar-archive` Unlock & Escrow Guards
;; -----------------------------------------------------------------------------
(let ()
  (define (mk-p-ta-bldgs #:with-robo-bay? [rb? #t])
    (append
     (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
           (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
           (mk-u 2003 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
           (mk-u 2004 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
           (mk-u 2005 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2006 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2007 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2008 'gateway 40.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2018 'gateway 52.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2019 'gateway 48.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2009 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
           (mk-u 2010 'twilight-council 40.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2011 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
           (mk-u 2012 'forge 36.0 42.0 #:hp 400.0 #:shield 400.0 #:order-count 1)
           (mk-u 2020 'forge 32.0 42.0 #:hp 400.0 #:shield 400.0 #:order-count 1)
           (mk-u 2013 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
           (mk-u 2014 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
           (mk-u 2015 'assimilator 58.5 36.5 #:hp 300.0 #:shield 300.0)
           (mk-u 2016 'assimilator 66.5 28.5 #:hp 300.0 #:shield 300.0))
     (if rb? (list (mk-u 2017 'robotics-bay 52.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)) '())))
  ;; 32 Probes (< 34w 3rd-Nexus escrow threshold) + 37 army supply = 69 supply on 2 Nexuses!
  (define p-units-68sup
    (append (mk-probes 32)
            (for/list ([i (in-range 12)]) (mk-u (+ 2200 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 2240 i) 'colossus 50.0 (+ 34.0 (* 0.8 i)) #:hp 200.0 #:shield 150.0))
            (list (mk-u 2260 'observer 52.0 38.0 #:hp 40.0 #:shield 20.0 #:flying #t))))
  (define p-units-68sup-0col
    (append (mk-probes 32)
            (for/list ([i (in-range 14)]) (mk-u (+ 2200 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 2240 i) 'immortal 50.0 (+ 34.0 (* 0.8 i)) #:hp 200.0 #:shield 100.0))
            (list (mk-u 2260 'observer 52.0 38.0 #:hp 40.0 #:shield 20.0 #:flying #t))))

  ;; 4a: PvT 2-base, 69 sup, 220M/220G, peaceful, RoboBay + 2 Colossi + TC ready -> builds templar-archive!
  (define rt-4a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4a
    (step-layer2-economy!
     rt-4a
     (mk-live-obs 'Protoss 'Terran 6800 #:minerals 220 #:gas 220 #:supply-used 69 #:supply-cap 118
                  #:mineral-harvesters 20 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-68sup #:ally-buildings (mk-p-ta-bldgs)
                  #:researched-upgrades '(warpgate warp-gate-research blink charge))))
  (check-true "L74-B3-4a-pvt-2base-68sup-220g-peaceful-builds-templar-archive"
              (has-build? acts-4a 'templar-archive)
              (fmt-fail rt-4a acts-4a))

  ;; 4b: PvP 2-base, 69 sup, 220M/220G, peaceful -> builds templar-archive!
  (define rt-4b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4b
    (step-layer2-economy!
     rt-4b
     (mk-live-obs 'Protoss 'Protoss 6800 #:minerals 220 #:gas 220 #:supply-used 69 #:supply-cap 118
                  #:mineral-harvesters 20 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-68sup #:ally-buildings (mk-p-ta-bldgs)
                  #:researched-upgrades '(warpgate warp-gate-research blink charge))))
  (check-true "L74-B3-4b-pvp-2base-68sup-220g-peaceful-builds-templar-archive"
              (has-build? acts-4b 'templar-archive)
              (fmt-fail rt-4b acts-4b))

  ;; 4c: PvT 2-base with gas=190 (< 200G) -> does NOT build templar-archive!
  (define rt-4c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4c
    (step-layer2-economy!
     rt-4c
     (mk-live-obs 'Protoss 'Terran 6800 #:minerals 220 #:gas 190 #:supply-used 69 #:supply-cap 118
                  #:mineral-harvesters 20 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-68sup #:ally-buildings (mk-p-ta-bldgs)
                  #:researched-upgrades '(warpgate warp-gate-research blink charge))))
  (check-true "L74-B3-4c-pvt-2base-under-200g-blocks-templar-archive"
              (not (has-build? acts-4c 'templar-archive))
              (fmt-fail rt-4c acts-4c))

  ;; 4d: PvT 2-base under-base-attack? -> does NOT build templar-archive!
  (define rt-4d (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4d
    (step-layer2-economy!
     rt-4d
     (mk-live-obs 'Protoss 'Terran 6800 #:minerals 220 #:gas 220 #:supply-used 69 #:supply-cap 118
                  #:mineral-harvesters 20 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-68sup #:ally-buildings (mk-p-ta-bldgs)
                  #:under-attack? #t
                  #:researched-upgrades '(warpgate warp-gate-research blink charge))))
  (check-true "L74-B3-4d-pvt-2base-under-attack-blocks-templar-archive"
              (not (has-build? acts-4d 'templar-archive))
              (fmt-fail rt-4d acts-4d))

  ;; 4e: PvT 2-base with Robotics Bay ready + 0 Colossi + 220M/220G -> Colossus escrow blocks templar-archive!
  (define rt-4e (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4e
    (step-layer2-economy!
     rt-4e
     (mk-live-obs 'Protoss 'Terran 6800 #:minerals 220 #:gas 220 #:supply-used 69 #:supply-cap 118
                  #:mineral-harvesters 20 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-68sup-0col #:ally-buildings (mk-p-ta-bldgs #:with-robo-bay? #t)
                  #:researched-upgrades '(warpgate warp-gate-research blink charge))))
  (check-true "L74-B3-4e-pvt-2base-preserves-colossus-escrow-blocks-templar-archive"
              (not (has-build? acts-4e 'templar-archive))
              (fmt-fail rt-4e acts-4e)))

;; -----------------------------------------------------------------------------
;; 5. L74-B3b: Protoss `#:has-ally-caster?` Wiring Holds 75e Nexus at >= 52w
;; -----------------------------------------------------------------------------
(let ()
  (define (mk-p-chrono-bldgs nx-en)
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy nx-en #:busy? #t #:order-count 1)
          (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy 20.0 #:busy? #t #:order-count 1)
          (mk-u 2003 'nexus 32.5 68.5 #:hp 1000.0 #:shield 1000.0 #:energy 20.0 #:busy? #t #:order-count 1)
          (mk-u 2004 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 2005 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:busy? #f #:order-count 0)
          (mk-u 2006 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0 #:busy? #f #:order-count 0)))
  ;; Allied HT far away (100,100 -> dist > 80t so dry-caster-near? is #f, testing #:has-ally-caster? directly!)
  (define p-units-56w-caster
    (append (mk-probes 56)
            (list (mk-u 2300 'high-templar 100.0 100.0 #:hp 40.0 #:shield 40.0 #:energy 60.0))))
  (define p-units-56w-nocaster (mk-probes 56))

  ;; 5a: >= 52w, 75e Nexus (< 100e), HT alive -> holds Nexus energy (NO Probe Chrono dump!)
  (define rt-5a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-5a
    (step-layer2-economy!
     rt-5a
     (mk-live-obs 'Protoss 'Terran 9000 #:minerals 200 #:gas 100 #:supply-used 58 #:supply-cap 118
                  #:mineral-harvesters 44 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-56w-caster #:ally-buildings (mk-p-chrono-bldgs 75.0))))
  ;; 5b: Same with 105e Nexus (>= 100e) -> DOES cast Chrono Boost!
  (define rt-5b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-5b
    (step-layer2-economy!
     rt-5b
     (mk-live-obs 'Protoss 'Terran 9000 #:minerals 200 #:gas 100 #:supply-used 58 #:supply-cap 118
                  #:mineral-harvesters 44 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-56w-caster #:ally-buildings (mk-p-chrono-bldgs 105.0))))
  ;; 5c: Same 75e Nexus with NO allied caster -> DOES cast Chrono Boost!
  (define rt-5c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-5c
    (step-layer2-economy!
     rt-5c
     (mk-live-obs 'Protoss 'Terran 9000 #:minerals 200 #:gas 100 #:supply-used 56 #:supply-cap 118
                  #:mineral-harvesters 44 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-56w-nocaster #:ally-buildings (mk-p-chrono-bldgs 75.0))))
  (check-true "L74-B3-5-has-ally-caster-holds-75e-nexus-at-56w-and-boosts-at-105e-or-nocaster"
              (and (not (has-spell? acts-5a 'chrono-boost))
                   (has-spell? acts-5b 'chrono-boost)
                   (has-spell? acts-5c 'chrono-boost))
              (format "75e+ht=~a 105e+ht=~a 75e-noht=~a"
                      (fmt-fail rt-5a acts-5a) (fmt-fail rt-5b acts-5b) (fmt-fail rt-5c acts-5c))))

(printf "=== Results: ~a/~a passed (~a failed) ===\n" tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
