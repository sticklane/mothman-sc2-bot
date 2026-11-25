#lang racket/base

;; =============================================================================
;; `tests/l74-runtime-abilities-test.rkt`
;; Loop 74 -> Loop 75 Kept Runtime Ability & Surgical Revert Regression Suite
;;
;; Covers:
;;   1. L74-B1a (KEPT): `l2-transfuse-targets` exempts >= 50e Queen near 50/90 HP
;;      Hydralisk from inject/creep so Transfuse fires; does NOT exempt near
;;      75/90 HP Hydralisk or when Queen has < 50e!
;;   2. L75 Part 1 Reverts (Restoring R21 Zerg Creep & Protoss Charge/Chrono):
;;      - 2a: Dedicated creeping Queen at 40e with >= 3 tumors resumes Creep!
;;      - 2b: PvP / Stalker-core PvT restores Charge-first on Twilight Council!
;;      - 2c: Peaceful 2-base PvT at 69 sup 220M/220G stops early Templar drain!
;;      - 2d: 75e Nexus at 56w with distant HT resumes full Probe Chrono Boost!
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

(printf "=== Loop 74 Kept Hydralisk Transfuse & L75 Surgical Revert Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L74-B1a (KEPT): Hydralisk Transfuse Target Filter (`mhp >= 85.0`, `missing >= 35.0`)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-1h
    (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 3002 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 3003 'hydralisk-den 39.0 34.0 #:hp 850.0)
          (mk-u 3050 'creep-tumor-burrowed 38.0 34.0 #:hp 50.0)))
  (define (mk-z-hydra-units hydra-hp [q-en 55.0])
    (append (mk-drones 24)
            (list (mk-u 3201 'queen 35.0 34.0 #:hp 175.0 #:energy q-en)
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
                  #:ally-units (mk-z-hydra-units 50.0 55.0) #:ally-buildings z-bldgs-1h)))
  (check-true "L74-B1-1a-55e-queen-exempt-from-inject-creep-near-50-90-hydralisk"
              (and (not (has-queen-inject? acts-1a))
                   (not (has-creep-tumor? acts-1a)))
              (fmt-fail rt-1a acts-1a))

  ;; 1b: 75/90 HP Hydralisk (missing=15 < 35) -> 55e Queen NOT exempted (casts macro spell normally!)
  (define rt-1b (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-1b
    (step-layer2-economy!
     rt-1b
     (mk-live-obs 'Zerg 'Protoss 6000 #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (mk-z-hydra-units 75.0 55.0) #:ally-buildings z-bldgs-1h)))
  (check-true "L74-B1-1b-55e-queen-not-exempt-near-75-90-hydralisk"
              (or (has-queen-inject? acts-1b)
                  (has-creep-tumor? acts-1b))
              (fmt-fail rt-1b acts-1b))

  ;; 1c: 40e Queen (< 50e Transfuse) near 50/90 HP Hydralisk -> NOT exempted, injects normally!
  (define rt-1c (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-1c
    (step-layer2-economy!
     rt-1c
     (mk-live-obs 'Zerg 'Protoss 6000 #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (mk-z-hydra-units 50.0 40.0) #:ally-buildings z-bldgs-1h)))
  (check-true "L74-B1-1c-40e-queen-below-50e-still-injects-near-50-90-hydralisk"
              (has-queen-inject? acts-1c)
              (fmt-fail rt-1c acts-1c)))

;; -----------------------------------------------------------------------------
;; 2. L75 Part 1 Surgical Reverts (Restore R21 Zerg Creep + Protoss Charge/Chrono)
;; -----------------------------------------------------------------------------
(let ()
  ;; 2a: Dedicated creeping Queen at 40e with 3 active tumors resumes full R21 Creep spread!
  (define z-bldgs-3t
    (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0 #:buffs '(11))
          (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0 #:buffs '(11))
          (mk-u 3003 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 3050 'creep-tumor-burrowed 45.0 34.0 #:hp 50.0)
          (mk-u 3051 'creep-tumor-burrowed 49.0 34.0 #:hp 50.0)
          (mk-u 3052 'creep-tumor-burrowed 53.0 34.0 #:hp 50.0)))
  (define z-units-3q
    (append (mk-drones 30)
            (list (mk-u 3201 'queen 33.5 33.5 #:hp 175.0 #:energy 30.0)
                  (mk-u 3202 'queen 63.5 33.5 #:hp 175.0 #:energy 30.0)
                  (mk-u 3203 'queen 50.0 34.0 #:hp 175.0 #:energy 40.0)
                  (mk-u 3250 'overlord 28.0 28.0 #:hp 200.0 #:flying #t))))
  (define rt-2a (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2a
    (step-layer2-economy!
     rt-2a
     (mk-live-obs 'Zerg 'Terran 5600 #:minerals 150 #:gas 50 #:supply-used 36 #:supply-cap 62
                  #:mineral-harvesters 30 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-3q #:ally-buildings z-bldgs-3t)))
  (check-true "L75-P1-2a-reverted-creep-hold-restores-40e-creeper-with-3-tumors"
              (has-creep-tumor? acts-2a)
              (fmt-fail rt-2a acts-2a))

  ;; 2b: PvT Twilight Council preserves Charge-first when no AA/Muta threat,
  ;;     while Loop 81 PvP strictly prioritizes Blink ahead of Charge!
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
  (define p-units-tc
    (append (mk-probes 36)
            (for/list ([i (in-range 4)]) (mk-u (+ 2200 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 2250 i) 'zealot 54.0 (+ 30.0 (* 0.5 i)) #:hp 100.0 #:shield 50.0))))
  (define rt-2b-pvt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-2b-pvt
    (step-layer2-economy!
     rt-2b-pvt
     (mk-live-obs 'Protoss 'Terran 6400 #:minerals 180 #:gas 160 #:supply-used 48 #:supply-cap 78
                  #:mineral-harvesters 27 #:vespene-harvesters 9
                  #:expansion-locations exps-2
                  #:ally-units p-units-tc #:ally-buildings p-bldgs-tc
                  #:researched-upgrades '(warpgate warp-gate-research))))
  (define rt-2b-pvp (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-2b-pvp
    (step-layer2-economy!
     rt-2b-pvp
     (mk-live-obs 'Protoss 'Protoss 6400 #:minerals 180 #:gas 160 #:supply-used 48 #:supply-cap 78
                  #:mineral-harvesters 27 #:vespene-harvesters 9
                  #:expansion-locations exps-2
                  #:ally-units p-units-tc #:ally-buildings p-bldgs-tc
                  #:researched-upgrades '(warpgate warp-gate-research))))
  (check-true "L75-P1-2b-charge-first-in-pvt-and-l81-blink-first-in-pvp"
              (and (has-research? acts-2b-pvt 'charge)
                   (not (has-research? acts-2b-pvt 'blink))
                   (has-research? acts-2b-pvp 'blink)
                   (not (has-research? acts-2b-pvp 'charge)))
              (format "pvt=~a pvp=~a" (fmt-fail rt-2b-pvt acts-2b-pvt) (fmt-fail rt-2b-pvp acts-2b-pvp)))

  ;; 2c: Peaceful 2-base PvT at 69 sup 220M/220G stops early 2-base templar-archive gas drain!
  (define p-bldgs-ta
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
          (mk-u 2017 'robotics-bay 52.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2013 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2014 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2015 'assimilator 58.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2016 'assimilator 66.5 28.5 #:hp 300.0 #:shield 300.0)))
  (define p-units-69sup
    (append (mk-probes 32)
            (for/list ([i (in-range 12)]) (mk-u (+ 2200 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 2240 i) 'colossus 50.0 (+ 34.0 (* 0.8 i)) #:hp 200.0 #:shield 150.0))
            (list (mk-u 2260 'observer 52.0 38.0 #:hp 40.0 #:shield 20.0 #:flying #t))))
  (define rt-2c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-2c
    (step-layer2-economy!
     rt-2c
     (mk-live-obs 'Protoss 'Terran 6800 #:minerals 220 #:gas 220 #:supply-used 69 #:supply-cap 118
                  #:mineral-harvesters 20 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-69sup #:ally-buildings p-bldgs-ta
                  #:researched-upgrades '(warpgate warp-gate-research blink charge))))
  (check-true "L75-P1-2c-reverted-2base-templar-stops-pvt-2base-gas-drain"
              (not (has-build? acts-2c 'templar-archive))
              (fmt-fail rt-2c acts-2c))

  ;; 2d: 75e Nexus at 56w with distant HT resumes full R21 Probe Chrono Boost!
  (define p-bldgs-chrono
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy 75.0 #:busy? #t #:order-count 1)
          (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy 20.0 #:busy? #t #:order-count 1)
          (mk-u 2003 'nexus 32.5 68.5 #:hp 1000.0 #:shield 1000.0 #:energy 20.0 #:busy? #t #:order-count 1)
          (mk-u 2004 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 2005 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:busy? #f #:order-count 0)
          (mk-u 2006 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0 #:busy? #f #:order-count 0)))
  (define p-units-56w-ht
    (append (mk-probes 56)
            (list (mk-u 2300 'high-templar 100.0 100.0 #:hp 40.0 #:shield 40.0 #:energy 60.0))))
  (define rt-2d (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-2d
    (step-layer2-economy!
     rt-2d
     (mk-live-obs 'Protoss 'Terran 9000 #:minerals 200 #:gas 100 #:supply-used 58 #:supply-cap 118
                  #:mineral-harvesters 44 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units p-units-56w-ht #:ally-buildings p-bldgs-chrono)))
  (check-true "L75-P1-2d-reverted-caster-chrono-hold-restores-75e-probe-chrono"
              (has-spell? acts-2d 'chrono-boost)
              (fmt-fail rt-2d acts-2d)))

(printf "=== Results: ~a/~a passed (~a failed) ===\n" tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
