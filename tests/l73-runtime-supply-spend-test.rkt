#lang racket/base

;; =============================================================================
;; `tests/l73-runtime-supply-spend-test.rkt`
;; Loop 73 Lane B — Opener/Mid Supply Alignment, Zerg Effective-Gas Larva
;; Fallback & Ghost `562` P1 TechLab Slot Guard
;;
;; Covers:
;;   1. L73-B2: Zerg 13/14 holds 75M for Overlord #1 (no Drone #14), morphs
;;      Overlord at 100M, and still waives hold under worker rush!
;;   2. L73-B2: Protoss 13/15 (0 Pylons) reserves 75M for Pylon #1, builds
;;      Pylon at 100M, and immediately resumes Probe once Pylon #1 is pending!
;;   3. L73-B1: Protoss 19/23 (supply-left=4) triggers Pylon #2 while Terran
;;      19/23 (1 base + Barracks) preserves CC #2 ahead of Depot #2!
;;   4. L73-B1: Zerg midgame cap=30 (24/30, left=6) & cap=52 (45/52, left=7)
;;      trigger proactive inject-burst Overlords!
;;   5. L73-B3: Zerg gas-deficit Spire-reserve (650M/46G, Spire gas reserve
;;      active) drains surplus minerals into Zerglings without stealing gas!
;;   6. L73-B4: Ghost training requires open TechLab Rax slot (`rax-tl-open-now > 0`)
;;      and clamps batch size to open TechLab slots (zero `562` Reactor spam)!
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
            'energy (exact->inexact en) 'cloak 3
            'flying fly? 'flying? fly? 'is-flying fly?
            'build-progress (exact->inexact bp)
            'orders ords
            'order-ability-id oab 'order-target-id otid
            'buffs buffs 'add-on-tag aot
            'powered? pow?
            'display-type 1))
  (define h1 (if oc (hash-set h0 'order-count oc) h0))
  (define h2 (if addon (hash-set h1 'addon addon) h1))
  (if atype (hash-set h2 'addon-type atype) h2))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 100]
                     #:gas [gas 0]
                     #:supply-used [su 13]
                     #:supply-cap [sc 15]
                     #:pending-supply [ps 0]
                     #:mineral-harvesters [mh 13]
                     #:vespene-harvesters [vh 0]
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
            'supply-used su 'supply-cap sc 'pending-supply ps
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

(define (has-train? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(train morph-unit warp-in))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (count-trains acts sym)
  (count (lambda (a)
           (and (pair? a)
                (memq (car a) '(train morph-unit warp-in))
                (>= (length a) 2)
                (eq? (second a) sym)))
         acts))

(define (has-build? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(build build-addon morph-building))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (has-expand? acts)
  (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts) #t))

(define (fmt-fail rt acts)
  (define tel (live-bot-runtime-last-telemetry rt))
  (define pl (and (hash? tel) (hash-ref tel 'priority-log-line #f)))
  (define macro-acts
    (filter (lambda (a)
              (and (pair? a)
                   (memq (car a) '(build build-addon morph-building train morph-unit warp-in research expand))))
            acts))
  (format "macro=~a prio=~a" macro-acts pl))

(define (mk-drones n [start-id 3100])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) 'drone (+ 28.0 (* 0.15 (modulo i 16))) (+ 30.0 (* 0.25 (quotient i 16))) #:hp 40.0)))

(define (mk-probes n [start-id 2100])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) 'probe (+ 28.0 (* 0.15 (modulo i 16))) (+ 30.0 (* 0.25 (quotient i 16))) #:hp 20.0 #:shield 20.0)))

(define (mk-scvs n [start-id 1100])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) 'scv (+ 28.0 (* 0.15 (modulo i 16))) (+ 30.0 (* 0.25 (quotient i 16))) #:hp 45.0)))

(define exps-2 (list (list 32.5 32.5) (list 62.5 32.5)))
(define exps-3 (list (list 32.5 32.5) (list 62.5 32.5) (list 32.5 68.5)))
(define exps-4 (list (list 32.5 32.5) (list 62.5 32.5) (list 32.5 68.5) (list 92.5 32.5)))

(printf "=== Loop 73 Lane B Runtime Supply Alignment, Gas-Deficit & Ghost 562 Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L73-B2: Zerg 13/14 Holds 75M for Overlord #1 & Morphs at 100M
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-1b (list (mk-u 3001 'hatchery 32.5 32.5 #:hp 1500.0)))
  (define z-units-13
    (append (mk-drones 13)
            (list (mk-u 3201 'larva 31.0 31.0 #:hp 25.0)
                  (mk-u 3202 'larva 31.5 31.0 #:hp 25.0)
                  (mk-u 3203 'larva 32.0 31.0 #:hp 25.0)
                  (mk-u 3250 'overlord 28.0 28.0 #:hp 200.0 #:flying #t))))
  ;; 1a: 13/14 with 75M -> holds minerals for Overlord #1 (does NOT spend 50M on Drone #14!)
  (define rt-1a (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-1a
    (step-layer2-economy!
     rt-1a
     (mk-live-obs 'Zerg 'Terran 260 #:minerals 75 #:gas 0 #:supply-used 13 #:supply-cap 14
                  #:mineral-harvesters 13 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-13 #:ally-buildings z-bldgs-1b)))
  (check-true "L73-B2-1a-zerg-13-14-75m-holds-for-overlord-no-drone14"
              (not (has-train? acts-1a 'drone))
              (fmt-fail rt-1a acts-1a))

  ;; 1b: 13/14 with 100M -> morphs Overlord #1!
  (define rt-1b (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-1b
    (step-layer2-economy!
     rt-1b
     (mk-live-obs 'Zerg 'Terran 320 #:minerals 100 #:gas 0 #:supply-used 13 #:supply-cap 14
                  #:mineral-harvesters 13 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-13 #:ally-buildings z-bldgs-1b)))
  (check-true "L73-B2-1b-zerg-13-14-100m-morphs-overlord1"
              (has-train? acts-1b 'overlord)
              (fmt-fail rt-1b acts-1b)))

;; -----------------------------------------------------------------------------
;; 2. L73-B2: Zerg 13/14 Worker Rush Waives Overlord Hold (zerg-emergency-rush-lings?)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-rush
    (list (mk-u 3001 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 3002 'spawning-pool 36.0 34.0 #:hp 1000.0)))
  (define z-units-rush
    (append (mk-drones 13)
            (list (mk-u 3201 'larva 31.0 31.0 #:hp 25.0)
                  (mk-u 3202 'larva 31.5 31.0 #:hp 25.0)
                  (mk-u 3250 'overlord 28.0 28.0 #:hp 200.0 #:flying #t))))
  (define enemy-worker-rush
    (for/list ([i (in-range 6)])
      (mk-u (+ 9500 i) 'probe (+ 34.0 (* 0.4 i)) 34.0 #:hp 20.0 #:shield 20.0)))
  (define rt-2 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2
    (step-layer2-economy!
     rt-2
     (mk-live-obs 'Zerg 'Protoss 1200 #:minerals 75 #:gas 0 #:supply-used 13 #:supply-cap 14
                  #:mineral-harvesters 13 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-rush #:ally-buildings z-bldgs-rush
                  #:enemy-units enemy-worker-rush #:under-attack? #t)))
  (check-true "L73-B2-2-zerg-13-14-worker-rush-waives-overlord-trains-zergling"
              (and (has-train? acts-2 'zergling)
                   (not (has-train? acts-2 'overlord)))
              (fmt-fail rt-2 acts-2)))

;; -----------------------------------------------------------------------------
;; 3. L73-B2: Protoss 13/15 Opener Reserves for Pylon #1, Builds at 100M, Resumes Probe
;; -----------------------------------------------------------------------------
(let ()
  (define p-bldgs-0p (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 0)))
  (define p-bldgs-pend-p
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 0)
          (mk-u 2002 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0 #:build-progress 0.2)))
  (define p-units-13 (mk-probes 13))

  ;; 3a: 13/15 with 0 Pylons and 75M -> holds for Pylon #1 (does NOT spend 50M on Probe #14!)
  (define rt-3a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3a
    (step-layer2-economy!
     rt-3a
     (mk-live-obs 'Protoss 'Terran 260 #:minerals 75 #:gas 0 #:supply-used 13 #:supply-cap 15
                  #:mineral-harvesters 13 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units p-units-13 #:ally-buildings p-bldgs-0p)))
  (check-true "L73-B2-3a-protoss-13-15-0pylons-75m-holds-for-pylon1-no-probe14"
              (not (has-train? acts-3a 'probe))
              (fmt-fail rt-3a acts-3a))

  ;; 3b: 13/15 with 0 Pylons and 100M -> builds Pylon #1!
  (define rt-3b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3b
    (step-layer2-economy!
     rt-3b
     (mk-live-obs 'Protoss 'Terran 320 #:minerals 100 #:gas 0 #:supply-used 13 #:supply-cap 15
                  #:mineral-harvesters 13 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units p-units-13 #:ally-buildings p-bldgs-0p)))
  (check-true "L73-B2-3b-protoss-13-15-0pylons-100m-builds-pylon1"
              (has-build? acts-3b 'pylon)
              (fmt-fail rt-3b acts-3b))

  ;; 3c: 13/15 with 1 Pylon pending (build-progress=0.2, pending-supply=1) and 75M -> immediately resumes Probe #14!
  (define rt-3c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3c
    (step-layer2-economy!
     rt-3c
     (mk-live-obs 'Protoss 'Terran 360 #:minerals 75 #:gas 0 #:supply-used 13 #:supply-cap 15 #:pending-supply 1
                  #:mineral-harvesters 13 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units p-units-13 #:ally-buildings p-bldgs-pend-p)))
  (check-true "L73-B2-3c-protoss-13-15-pending-pylon1-resumes-probe14"
              (has-train? acts-3c 'probe)
              (fmt-fail rt-3c acts-3c)))

;; -----------------------------------------------------------------------------
;; 4. L73-B1: Protoss 19/23 Triggers Pylon #2; Terran 19/23 Keeps CC #2 Ahead of Depot #2
;; -----------------------------------------------------------------------------
(let ()
  ;; 4a: Protoss 19/23 (supply-left=4, 1 Pylon, 1 Gateway, 100M, 0 pending) -> builds Pylon #2!
  (define p-bldgs-19
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 2002 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 2003 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)))
  (define rt-4a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4a
    (step-layer2-economy!
     rt-4a
     (mk-live-obs 'Protoss 'Terran 1800 #:minerals 100 #:gas 0 #:supply-used 19 #:supply-cap 23
                  #:mineral-harvesters 19 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (mk-probes 19) #:ally-buildings p-bldgs-19)))
  (check-true "L73-B1-4a-protoss-19-23-supply-left4-triggers-pylon2"
              (has-build? acts-4a 'pylon)
              (fmt-fail rt-4a acts-4a))

  ;; 4b: Terran 19/23 (1 base + Depot #1 + Barracks #1 + Refinery #1, no CC #2 yet):
  ;;     at 150M does NOT prematurely build Depot #2; at 400M expands CC #2 ahead of Depot #2!
  (define t-bldgs-19
    (list (mk-u 1001 'command-center 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 1002 'supply-depot 24.0 40.0 #:hp 400.0)
          (mk-u 1003 'barracks 42.0 36.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1004 'refinery 28.5 36.5 #:hp 500.0)))
  (define rt-4b-low (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-4b-low
    (step-layer2-economy!
     rt-4b-low
     (mk-live-obs 'Terran 'Protoss 1900 #:minerals 150 #:gas 20 #:supply-used 19 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 3
                  #:expansion-locations exps-2
                  #:ally-units (mk-scvs 19) #:ally-buildings t-bldgs-19)))
  (define rt-4b-cc2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-4b-cc2
    (step-layer2-economy!
     rt-4b-cc2
     (mk-live-obs 'Terran 'Protoss 2000 #:minerals 400 #:gas 20 #:supply-used 19 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 3
                  #:expansion-locations exps-2
                  #:ally-units (mk-scvs 19) #:ally-buildings t-bldgs-19)))
  (check-true "L73-B1-4b-terran-19-23-preserves-cc2-ahead-of-depot2"
              (and (not (has-build? acts-4b-low 'supply-depot))
                   (has-expand? acts-4b-cc2))
              (format "low=~a cc2=~a" (fmt-fail rt-4b-low acts-4b-low) (fmt-fail rt-4b-cc2 acts-4b-cc2))))

;; -----------------------------------------------------------------------------
;; 5. L73-B1: Zerg Midgame Inject-Burst Headroom (cap=30 left=6 & cap=52 left=7)
;; -----------------------------------------------------------------------------
(let ()
  ;; 5a: Zerg 24/30 (supply-left=6, 2 bases, 100M, 0 pending) -> proactive Overlord!
  (define z-bldgs-30
    (list (mk-u 3001 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 3003 'spawning-pool 36.0 34.0 #:hp 1000.0)))
  (define z-units-24
    (append (mk-drones 22)
            (list (mk-u 3201 'queen 33.0 34.0 #:hp 175.0 #:energy 20.0)
                  (mk-u 3211 'larva 31.0 31.0 #:hp 25.0)
                  (mk-u 3212 'larva 31.5 31.0 #:hp 25.0)
                  (mk-u 3250 'overlord 28.0 28.0 #:hp 200.0 #:flying #t)
                  (mk-u 3251 'overlord 26.0 28.0 #:hp 200.0 #:flying #t))))
  (define rt-5a (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-5a
    (step-layer2-economy!
     rt-5a
     (mk-live-obs 'Zerg 'Terran 3400 #:minerals 100 #:gas 0 #:supply-used 24 #:supply-cap 30
                  #:mineral-harvesters 22 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units z-units-24 #:ally-buildings z-bldgs-30)))
  (check-true "L73-B1-5a-zerg-midgame-24-30-left6-triggers-proactive-overlord"
              (has-train? acts-5a 'overlord)
              (fmt-fail rt-5a acts-5a))

  ;; 5b: Zerg 45/52 (supply-left=7, 3 bases, 100M, 0 pending) -> proactive Overlord!
  (define z-bldgs-52
    (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 3003 'hatchery 32.5 68.5 #:hp 1500.0)
          (mk-u 3004 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 3005 'roach-warren 39.0 34.0 #:hp 850.0)))
  (define z-units-45
    (append (mk-drones 35)
            (for/list ([i (in-range 2)]) (mk-u (+ 3201 i) 'queen (+ 33.0 (* 12.0 i)) 34.0 #:hp 175.0 #:energy 20.0))
            (for/list ([i (in-range 3)]) (mk-u (+ 3220 i) 'roach 52.0 (+ 32.0 (* 0.5 i)) #:hp 145.0))
            (list (mk-u 3211 'larva 31.0 31.0 #:hp 25.0)
                  (mk-u 3212 'larva 31.5 31.0 #:hp 25.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 3250 i) 'overlord (+ 24.0 (* 2.0 i)) 24.0 #:hp 200.0 #:flying #t))))
  (define rt-5b (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-5b
    (step-layer2-economy!
     rt-5b
     (mk-live-obs 'Zerg 'Terran 6200 #:minerals 100 #:gas 0 #:supply-used 45 #:supply-cap 52
                  #:mineral-harvesters 35 #:vespene-harvesters 0
                  #:expansion-locations exps-3
                  #:ally-units z-units-45 #:ally-buildings z-bldgs-52)))
  (check-true "L73-B1-5b-zerg-midgame-45-52-left7-triggers-proactive-overlord"
              (has-train? acts-5b 'overlord)
              (fmt-fail rt-5b acts-5b)))

;; -----------------------------------------------------------------------------
;; 6. L73-B3: Zerg Effective-Gas Spire-Reserve Overflow -> Zerglings (0G Spent!)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-spire-hold
    (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 3003 'hatchery 32.5 68.5 #:hp 1500.0)
          (mk-u 3004 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 3005 'roach-warren 39.0 34.0 #:hp 850.0)
          (mk-u 3006 'extractor 28.5 36.5 #:hp 500.0)
          (mk-u 3007 'extractor 36.5 28.5 #:hp 500.0)
          (mk-u 3008 'extractor 58.5 36.5 #:hp 500.0)
          (mk-u 3009 'extractor 66.5 28.5 #:hp 500.0)
          (mk-u 3010 'spore-crawler 30.0 34.0 #:hp 400.0)
          (mk-u 3011 'spore-crawler 60.0 34.0 #:hp 400.0)))
  (define z-units-spire-hold
    (append (mk-drones 50)
            (for/list ([i (in-range 5)]) (mk-u (+ 3201 i) 'queen (+ 33.0 (* 6.0 i)) 34.0 #:hp 175.0 #:energy 20.0))
            (for/list ([i (in-range 8)]) (mk-u (+ 3220 i) 'roach 52.0 (+ 32.0 (* 0.5 i)) #:hp 145.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 3280 i) 'larva 31.0 (+ 31.0 (* 0.3 i)) #:hp 25.0))
            (for/list ([i (in-range 10)]) (mk-u (+ 3250 i) 'overlord (+ 24.0 (* 2.0 i)) 24.0 #:hp 200.0 #:flying #t))))
  ;; Visible enemy Battlecruiser triggers zerg-holding-for-aa-spire? (zerg-spire-res-gas=200G)
  ;; with gas=46 (raw >= 25, effective 46 - 200 < 25) and minerals=650 (>= 500):
  ;; MUST drain excess minerals into Zerglings and emit ZERO Roaches (keeping 46G untouched)!
  (define rt-6 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-6
    (step-layer2-economy!
     rt-6
     (mk-live-obs 'Zerg 'Terran 9000 #:minerals 650 #:gas 46 #:supply-used 76 #:supply-cap 118
                  #:mineral-harvesters 38 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units z-units-spire-hold #:ally-buildings z-bldgs-spire-hold
                  #:enemy-units (list (mk-u 9701 'battlecruiser 115.0 115.0 #:hp 550.0 #:flying #t))
                  #:researched-upgrades '(metabolic-boost glial-reconstitution))))
  (check-true "L73-B3-6-zerg-spire-gas-reserve-650m-46g-spends-zerglings-zero-roaches"
              (and (has-train? acts-6 'zergling)
                   (not (has-train? acts-6 'roach)))
              (fmt-fail rt-6 acts-6)))

;; -----------------------------------------------------------------------------
;; 7. L73-B4: Ghost `562` P1 APM Guard (`rax-tl-open-now > 0` & Batch Clamping)
;; -----------------------------------------------------------------------------
(let ()
  (define (mk-ghost-bldgs tl-order-cnt)
    (list (mk-u 1001 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:order-count 1)
          (mk-u 1002 'orbital-command 62.5 32.5 #:hp 1500.0 #:energy 20.0 #:order-count 1)
          (mk-u 1003 'orbital-command 32.5 68.5 #:hp 1500.0 #:energy 20.0 #:order-count 1)
          (mk-u 1028 'orbital-command 92.5 32.5 #:hp 1500.0 #:energy 20.0 #:order-count 1)
          (mk-u 1004 'supply-depot 24.0 40.0 #:hp 400.0)
          (mk-u 1005 'supply-depot 26.5 40.0 #:hp 400.0)
          (mk-u 1006 'barracks 42.0 36.0 #:hp 1000.0 #:order-count tl-order-cnt
                #:add-on-tag 1016 #:addon 'barracks-techlab #:addon-type 'barracks-techlab)
          (mk-u 1016 'barracks-techlab 44.5 35.5 #:hp 400.0)
          (mk-u 1007 'barracks 46.0 36.0 #:hp 1000.0 #:order-count 0
                #:add-on-tag 1017 #:addon 'barracks-reactor #:addon-type 'barracks-reactor)
          (mk-u 1017 'barracks-reactor 48.5 35.5 #:hp 400.0)
          (mk-u 1008 'barracks 50.0 36.0 #:hp 1000.0 #:order-count 0
                #:add-on-tag 1018 #:addon 'barracks-reactor #:addon-type 'barracks-reactor)
          (mk-u 1018 'barracks-reactor 52.5 35.5 #:hp 400.0)
          (mk-u 1009 'factory 48.0 42.0 #:hp 1250.0 #:order-count 1
                #:add-on-tag 1019 #:addon 'factory-techlab #:addon-type 'factory-techlab)
          (mk-u 1019 'factory-techlab 50.5 41.5 #:hp 400.0)
          (mk-u 1010 'starport 52.0 46.0 #:hp 1300.0 #:order-count 1)
          (mk-u 1011 'ghost-academy 38.0 44.0 #:hp 1250.0)
          (mk-u 1012 'engineering-bay 34.0 44.0 #:hp 850.0 #:order-count 1)
          (mk-u 1020 'engineering-bay 30.0 44.0 #:hp 850.0 #:order-count 1)
          (mk-u 1021 'armory 38.0 48.0 #:hp 750.0 #:order-count 1)
          (mk-u 1029 'fusion-core 34.0 48.0 #:hp 750.0 #:order-count 1)
          (mk-u 1026 'missile-turret 28.0 34.0 #:hp 250.0)
          (mk-u 1027 'missile-turret 58.0 34.0 #:hp 250.0)
          (mk-u 1013 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 1014 'refinery 36.5 28.5 #:hp 500.0)
          (mk-u 1022 'refinery 58.5 36.5 #:hp 500.0)
          (mk-u 1023 'refinery 66.5 28.5 #:hp 500.0)
          (mk-u 1024 'refinery 28.5 72.5 #:hp 500.0)
          (mk-u 1025 'refinery 36.5 64.5 #:hp 500.0)))
  (define ghost-units
    (append (mk-scvs 50)
            (for/list ([i (in-range 14)]) (mk-u (+ 1200 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0))
            (for/list ([i (in-range 3)]) (mk-u (+ 1250 i) 'siege-tank 50.0 (+ 34.0 (* 1.0 i)) #:hp 175.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 1260 i) 'medivac 50.0 (+ 38.0 (* 1.0 i)) #:hp 150.0 #:flying #t))))
  (define enemy-ht-archons
    (list (mk-u 9801 'high-templar 120.0 120.0 #:hp 40.0 #:shield 40.0)
          (mk-u 9802 'archon 122.0 120.0 #:hp 10.0 #:shield 350.0)))

  ;; 7a: TechLab Rax BUSY (order-count=1), 2 Reactor Rax IDLE -> ZERO (train ghost)!
  (define rt-7a (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-7a
    (step-layer2-economy!
     rt-7a
     (mk-live-obs 'Terran 'Protoss 11000 #:minerals 700 #:gas 300 #:supply-used 77 #:supply-cap 130
                  #:mineral-harvesters 32 #:vespene-harvesters 18
                  #:expansion-locations exps-4
                  #:ally-units ghost-units #:ally-buildings (mk-ghost-bldgs 1)
                  #:enemy-units enemy-ht-archons
                  #:researched-upgrades '(stimpack combat-shield concussive-shells personal-cloaking))))
  (check-true "L73-B4-7a-ghost-busy-techlab-rax-emits-zero-ghosts-no-562-spam"
              (and (= (count-trains acts-7a 'ghost) 0)
                   (or (has-train? acts-7a 'marine)
                       (has-train? acts-7a 'marauder)))
              (format "ghostCnt=~a ~a" (count-trains acts-7a 'ghost) (fmt-fail rt-7a acts-7a)))

  ;; 7b: 1 TechLab Rax IDLE (order-count=0), 2 Reactor Rax IDLE -> EXACTLY 1 Ghost + Reactor Marines!
  (define rt-7b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-7b
    (step-layer2-economy!
     rt-7b
     (mk-live-obs 'Terran 'Protoss 11000 #:minerals 600 #:gas 300 #:supply-used 77 #:supply-cap 130
                  #:mineral-harvesters 32 #:vespene-harvesters 18
                  #:expansion-locations exps-4
                  #:ally-units ghost-units #:ally-buildings (mk-ghost-bldgs 0)
                  #:enemy-units enemy-ht-archons
                  #:researched-upgrades '(stimpack combat-shield concussive-shells personal-cloaking))))
  (check-true "L73-B4-7b-ghost-1-idle-techlab-rax-trains-exactly-1-ghost-and-reactor-marines"
              (and (= (count-trains acts-7b 'ghost) 1)
                   (has-train? acts-7b 'marine))
              (format "ghostCnt=~a ~a" (count-trains acts-7b 'ghost) (fmt-fail rt-7b acts-7b))))

(printf "=== Results: ~a/~a passed (~a failed) ===\n" tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
