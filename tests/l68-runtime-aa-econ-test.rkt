#lang racket/base

;; =============================================================================
;; `tests/l68-runtime-aa-econ-test.rkt`
;; Loop 68 Lane B — All-3-Races Cloak/AA Runtime Unblock, Unified 1-Base Natural
;; Escrow, 3rd-Base Prereq Unlock & Runtime Tempest Home/Closure Verification
;;
;; Covers:
;;   1. L68-B5-1: Protoss 1-Base Natural Escrow Sawtooth (`100M` floor + timeout keep,
;;      blocks tech/structure drain while still training scheduled Probes)
;;   2. L68-B5-2: Terran 1-Base Natural Escrow Sawtooth (`50M` floor + timeout keep,
;;      blocks Refinery#2/Ebay/Barracks#2 drain while still training scheduled SCVs)
;;   3. L68-B2-3: Terran Mass-Banshee AA (`p3-real-combat-air-urgent?` waives Tank gas
;;      yield, scales Vikings past cap 2, builds Starport-TL for Raven #1 vs cloak)
;;   4. L68-B2-4: Terran OWM Capital-Air (fogged Tempests keep `enemy-capital-air?`
;;      active and train Vikings past cap 2)
;;   5. L68-B2-5: Terran TvT TechLab Factory Reaper Defense (`hellion <= 1` cap,
;;      prioritizes Siege Tank #1 / Cyclone #1, defers Starport/BarracksReactor gas)
;;   6. L68-B3-6: Protoss OWM Capital-Air + VoidRay Stargate Reserve in P2 & P3
;;   7. L68-B3-7: Protoss OWM Unburrowed WidowMine Observer #1 Emergency Bypass
;;   8. L68-B1-8: Zerg Mass-Banshee Roach/BanelingNest Gas Protection & Early OWM
;;      Battlecruiser 7-8 Queen Surge + Spire Gas Protection Over Routine Overseer
;;   9. L68-B6-9: 3rd-Base Prereq Unlock (Terran 36+ sup / Factory-only / 8+ army;
;;      Protoss 40+ sup / 32+ workers / 8+ army)
;;  10. L68-B4-10: Runtime Tempest Home-Shell (`20.0t`) & AA Closure (`22.0t`)
;;      while strictly preserving `< 0.85x` ground-vs-ground disengage
;; =============================================================================

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         (only-in "../lib/opponent-world-model.rkt"
                  opponent-world-model-last-summary
                  opponent-world-summary?
                  opponent-world-summary-known-unit-counts)
         (only-in "../lib/tactics/order-ledger.rkt"
                  order-ledger-reconcile-observation!))

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
              #:powered? [pow? #t]
              #:weapon-cooldown [wcd 0.0])
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
            'weapon-cooldown (exact->inexact wcd)
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
            'enable-opponent-world-model #t
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
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(train morph-unit warp-in))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

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

(define (run-l34 rt obs [fap 0.25])
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt) obs)
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(printf "=== Loop 68 Lane B Runtime AA & Econ Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L68-B5-1: Protoss 1-Base Natural Escrow Sawtooth (`100M` floor + timeout keep)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define exps (list (list 32.5 32.5) (list 62.5 32.5) (list 32.5 68.5)))
  (define p-bldgs
    (list (mk-u 1001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 0)
          (mk-u 1002 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 1003 'pylon 40.0 38.0 #:hp 200.0 #:shield 200.0)
          (mk-u 1004 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 1005 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 1006 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
          (mk-u 1007 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 1008 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)))
  (define p-units
    (append (for/list ([i (in-range 20)])
              (mk-u (+ 1100 i) 'probe 29.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 1130 i) 'stalker 48.0 (+ 32.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))))
  ;; First step seeds escrow timer at frame 3500; second step past escrow timeout at frame 4100 (`160M/100G`).
  (void
   (step-layer2-economy!
    rt-p
    (mk-live-obs 'Protoss 'Protoss 3500 #:minerals 160 #:gas 100 #:supply-used 28 #:supply-cap 46
                 #:mineral-harvesters 14 #:vespene-harvesters 6
                 #:expansion-locations exps
                 #:ally-units p-units
                 #:ally-buildings p-bldgs)))
  (define acts-p
    (step-layer2-economy!
     rt-p
     (mk-live-obs 'Protoss 'Protoss 4100 #:minerals 160 #:gas 100 #:supply-used 28 #:supply-cap 46
                  #:mineral-harvesters 14 #:vespene-harvesters 6
                  #:expansion-locations exps
                  #:ally-units p-units
                  #:ally-buildings p-bldgs)))
  (check-true "L68-B5-1-protoss-1base-nat-160m-blocks-tech-sawtooth-while-allowing-probe"
              (and (not (has-build? acts-p 'robotics-facility))
                   (not (has-build? acts-p 'twilight-council))
                   (not (has-build? acts-p 'shield-battery))
                   (not (has-build? acts-p 'gateway))
                   (has-train? acts-p 'probe))
              (format "acts=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build train)))) acts-p))))

;; -----------------------------------------------------------------------------
;; 2. L68-B5-2: Terran 1-Base Natural Escrow Sawtooth (`50M` floor + timeout keep)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-geysers
    (list (hasheq 'id 2091 'type 'vespene-geyser 'x 28.5 'y 36.5 'vespene-contents 2250)
          (hasheq 'id 2092 'type 'vespene-geyser 'x 36.5 'y 28.5 'vespene-contents 2250)))
  (define t-bldgs
    (list (mk-u 2001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 0)
          (mk-u 2002 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 2003 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 2004 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 2005 'refinery 28.5 36.5 #:hp 500.0)))
  (define t-units
    (append (for/list ([i (in-range 19)])
              (mk-u (+ 2100 i) 'scv 29.0 (+ 30.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 2130 i) 'marine 48.0 (+ 32.0 (* 0.5 i)) #:hp 45.0))))
  ;; First step seeds escrow timer at frame 3400; second step past timeout at frame 4050 (`100M/50G`).
  (void
   (step-layer2-economy!
    rt-t
    (mk-live-obs 'Terran 'Protoss 3400 #:minerals 100 #:gas 50 #:supply-used 23 #:supply-cap 47
                 #:mineral-harvesters 16 #:vespene-harvesters 3
                 #:vespene-geysers t-geysers
                 #:ally-units t-units
                 #:ally-buildings t-bldgs)))
  (define acts-t
    (step-layer2-economy!
     rt-t
     (mk-live-obs 'Terran 'Protoss 4050 #:minerals 100 #:gas 50 #:supply-used 23 #:supply-cap 47
                  #:mineral-harvesters 16 #:vespene-harvesters 3
                  #:vespene-geysers t-geysers
                  #:ally-units t-units
                  #:ally-buildings t-bldgs)))
  (check-true "L68-B5-2-terran-1base-nat-100m-blocks-ref2-ebay-rax2-while-allowing-scv"
              (and (not (has-build? acts-t 'refinery))
                   (not (has-build? acts-t 'engineering-bay))
                   (not (has-build? acts-t 'barracks))
                   (not (has-build? acts-t 'bunker))
                   (has-train? acts-t 'scv))
              (format "acts=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon train)))) acts-t))))

;; -----------------------------------------------------------------------------
;; 3. L68-B2-3: Terran Mass-Banshee AA (Viking gas priority, >2 cap, Starport-TL Raven #1)
;; -----------------------------------------------------------------------------
(let ()
  (define bldgs-t-aa
    (list (mk-u 3001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3003 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 3004 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 3005 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 3006 'factory 46.0 34.0 #:hp 1250.0 #:add-on-tag 3007 #:addon 'techlab #:addon-type 'factory-techlab)
          (mk-u 3007 'factory-techlab 48.5 33.5 #:hp 400.0)
          (mk-u 3008 'starport 52.0 34.0 #:hp 1300.0)
          (mk-u 3009 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 3010 'refinery 36.5 28.5 #:hp 500.0)))
  (define base-units-t
    (append (for/list ([i (in-range 30)])
              (mk-u (+ 3100 i) 'scv 29.0 (+ 28.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 8)])
              (mk-u (+ 3140 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0))))
  (define enemy-banshees
    (list (mk-u 3901 'banshee 90.0 70.0 #:hp 140.0 #:flying #t)
          (mk-u 3902 'banshee 92.0 72.0 #:hp 140.0 #:flying #t)
          (mk-u 3903 'banshee 94.0 74.0 #:hp 140.0 #:flying #t)))

  ;; (3a) At 150M/100G with 0 Tanks & open Factory-TL + open Starport -> trains `'viking`!
  (define rt-b1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-b1
    (mk-live-obs 'Terran 'Terran 6200 #:minerals 150 #:gas 100 #:supply-used 42 #:supply-cap 78
                 #:mineral-harvesters 24 #:vespene-harvesters 6
                 #:ally-units base-units-t
                 #:ally-buildings bldgs-t-aa
                 #:enemy-units enemy-banshees))
  (step-layer1-perception! rt-b1 obs-b1)
  (define acts-b1 (step-layer2-economy! rt-b1 obs-b1))
  (check-true "L68-B2-3a-terran-mass-banshee-150m-100g-trains-viking-over-tank-yield"
              (has-train? acts-b1 'viking)
              (format "trains=~a" (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-b1)))

  ;; (3b) At 150M/150G with 1 Tank AND 2 Vikings already (open Reactored Starport) -> yields Tank #2 gas & scales Viking #3!
  (define rt-b2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-t-aa-reac
    (list (mk-u 3001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3003 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 3004 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 3005 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 3006 'factory 46.0 34.0 #:hp 1250.0 #:add-on-tag 3007 #:addon 'techlab #:addon-type 'factory-techlab)
          (mk-u 3007 'factory-techlab 48.5 33.5 #:hp 400.0)
          (mk-u 3008 'starport 52.0 34.0 #:hp 1300.0 #:add-on-tag 3011 #:addon 'reactor #:addon-type 'starport-reactor)
          (mk-u 3011 'starport-reactor 54.5 33.5 #:hp 400.0)
          (mk-u 3015 'starport 52.0 40.0 #:hp 1300.0 #:order-count 2 #:add-on-tag 3016 #:addon 'reactor #:addon-type 'starport-reactor)
          (mk-u 3016 'starport-reactor 54.5 39.5 #:hp 400.0)
          (mk-u 3012 'engineering-bay 38.0 38.0 #:hp 850.0 #:order-count 1)
          (mk-u 3013 'missile-turret 30.0 34.0 #:hp 250.0)
          (mk-u 3014 'missile-turret 60.0 34.0 #:hp 250.0)
          (mk-u 3009 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 3010 'refinery 36.5 28.5 #:hp 500.0)))
  (define units-b2
    (append base-units-t
            (list (mk-u 3180 'siege-tank 54.0 32.5 #:hp 175.0)
                  (mk-u 3181 'viking-fighter 56.0 34.0 #:hp 135.0 #:flying #t)
                  (mk-u 3182 'viking-fighter 58.0 34.0 #:hp 135.0 #:flying #t))))
  (define obs-b2
    (mk-live-obs 'Terran 'Terran 6400 #:minerals 150 #:gas 150 #:supply-used 49 #:supply-cap 78
                 #:mineral-harvesters 24 #:vespene-harvesters 6
                 #:ally-units units-b2
                 #:ally-buildings bldgs-t-aa-reac
                 #:enemy-units enemy-banshees))
  (step-layer1-perception! rt-b2 obs-b2)
  (define acts-b2 (step-layer2-economy! rt-b2 obs-b2))
  (check-true "L68-B2-3b-terran-mass-banshee-150m-150g-scales-past-2-vikings-ahead-of-tank"
              (and (has-train? acts-b2 'viking)
                   (not (has-train? acts-b2 'siege-tank)))
              (format "trains=~a builds=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-b2)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-b2)))

  ;; (3c) Confirmed cloak with 1 Reactored Starport + 1 bare Starport #2 + 2 OCs + 2 Vikings -> builds Starport-TL for Raven #1!
  (define rt-b3 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-b3
    (list (mk-u 3201 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3202 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 3203 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 3204 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 3205 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 3206 'factory 46.0 34.0 #:hp 1250.0 #:order-count 1 #:add-on-tag 3207 #:addon 'techlab #:addon-type 'factory-techlab)
          (mk-u 3207 'factory-techlab 48.5 33.5 #:hp 400.0)
          (mk-u 3208 'starport 52.0 34.0 #:hp 1300.0 #:order-count 2 #:add-on-tag 3209 #:addon 'reactor #:addon-type 'starport-reactor)
          (mk-u 3209 'starport-reactor 54.5 33.5 #:hp 400.0)
          (mk-u 3210 'starport 52.0 40.0 #:hp 1300.0)
          (mk-u 3211 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 3212 'refinery 36.5 28.5 #:hp 500.0)))
  (define obs-b3
    (mk-live-obs 'Terran 'Terran 6600 #:minerals 200 #:gas 125 #:supply-used 50 #:supply-cap 78
                 #:mineral-harvesters 24 #:vespene-harvesters 6
                 #:ally-units units-b2
                 #:ally-buildings bldgs-b3
                 #:enemy-units enemy-banshees))
  (step-layer1-perception! rt-b3 obs-b3)
  (define acts-b3 (step-layer2-economy! rt-b3 obs-b3))
  (check-true "L68-B2-3c-terran-confirmed-cloak-builds-starport-techlab-for-raven1"
              (has-build? acts-b3 'starport-techlab)
              (format "builds=~a" (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-b3))))

;; -----------------------------------------------------------------------------
;; 4. L68-B2-4: Terran OWM Capital-Air (fogged Tempests sustain Viking scaling > 2)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-ca (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-ca
    (list (mk-u 4001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 4002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 4003 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 4004 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 4005 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 4006 'factory 46.0 34.0 #:hp 1250.0 #:add-on-tag 4007 #:addon 'techlab #:addon-type 'factory-techlab)
          (mk-u 4007 'factory-techlab 48.5 33.5 #:hp 400.0)
          (mk-u 4008 'starport 52.0 34.0 #:hp 1300.0 #:add-on-tag 4009 #:addon 'reactor #:addon-type 'starport-reactor)
          (mk-u 4009 'starport-reactor 54.5 33.5 #:hp 400.0)
          (mk-u 4014 'starport 52.0 40.0 #:hp 1300.0 #:order-count 2 #:add-on-tag 4015 #:addon 'reactor #:addon-type 'starport-reactor)
          (mk-u 4015 'starport-reactor 54.5 39.5 #:hp 400.0)
          (mk-u 4010 'armory 38.0 38.0 #:hp 750.0 #:order-count 1)
          (mk-u 4011 'engineering-bay 42.0 38.0 #:hp 850.0 #:order-count 1)
          (mk-u 4012 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 4013 'refinery 36.5 28.5 #:hp 500.0)))
  (define units-ca
    (append (for/list ([i (in-range 32)])
              (mk-u (+ 4100 i) 'scv 29.0 (+ 28.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 8)])
              (mk-u (+ 4140 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0))
            (list (mk-u 4180 'viking-fighter 56.0 34.0 #:hp 135.0 #:flying #t)
                  (mk-u 4181 'viking-fighter 58.0 34.0 #:hp 135.0 #:flying #t))))
  (define seen-tempests
    (for/list ([i (in-range 4)])
      (mk-u (+ 4900 i) 'tempest (+ 95.0 (* 1.5 i)) 75.0 #:hp 200.0 #:shield 125.0 #:flying #t)))
  ;; Frame 7500: observe 4 Tempests in Layer 1 perception (populates OWM).
  (step-layer1-perception!
   rt-ca
   (mk-live-obs 'Terran 'Protoss 7500 #:minerals 200 #:gas 150 #:supply-used 52 #:supply-cap 78
                #:mineral-harvesters 26 #:vespene-harvesters 6
                #:ally-units units-ca #:ally-buildings bldgs-ca
                #:enemy-units seen-tempests))
  ;; Frame 7600: ALL Tempests stepped back into fog (`enemy-units = '()`)!
  (define obs-fog
    (mk-live-obs 'Terran 'Protoss 7600 #:minerals 200 #:gas 150 #:supply-used 52 #:supply-cap 78
                 #:mineral-harvesters 26 #:vespene-harvesters 6
                 #:ally-units units-ca #:ally-buildings bldgs-ca
                 #:enemy-units '()))
  (step-layer1-perception! rt-ca obs-fog)
  (define owm-sum (opponent-world-model-last-summary (rt-opponent-world-model rt-ca)))
  (define owm-tempests
    (if (opponent-world-summary? owm-sum)
        (hash-ref (opponent-world-summary-known-unit-counts owm-sum) 'tempest 0)
        0))
  (define acts-fog (step-layer2-economy! rt-ca obs-fog))
  (check-true "L68-B2-4-terran-owm-fogged-tempests-keep-capital-air-and-train-viking3"
              (and (>= owm-tempests 4)
                   (has-train? acts-fog 'viking)
                   (not (has-train? acts-fog 'siege-tank)))
              (format "owmTempests=~a trains=~a"
                      owm-tempests
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-fog))))

;; -----------------------------------------------------------------------------
;; 5. L68-B2-5: Terran TvT TechLab Factory Reaper Defense (`hellion <= 1`, Tank/Cyclone, gas defer)
;; -----------------------------------------------------------------------------
(let ()
  (define bldgs-reap
    (list (mk-u 5001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 5002 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 5003 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 5004 'barracks 42.0 34.0 #:hp 1000.0)
          (mk-u 5005 'factory 46.0 34.0 #:hp 1250.0 #:add-on-tag 5006 #:addon 'techlab #:addon-type 'factory-techlab)
          (mk-u 5006 'factory-techlab 48.5 33.5 #:hp 400.0)
          (mk-u 5007 'refinery 28.5 36.5 #:hp 500.0)))
  (define units-reap
    (append (for/list ([i (in-range 20)])
              (mk-u (+ 5100 i) 'scv 29.0 (+ 28.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 5130 i) 'marine 44.0 (+ 32.0 (* 0.5 i)) #:hp 45.0))
            (list (mk-u 5150 'hellion 46.0 32.0 #:hp 90.0))))
  (define enemy-reapers
    (list (mk-u 5901 'reaper 50.0 34.0 #:hp 60.0)
          (mk-u 5902 'reaper 51.0 35.0 #:hp 60.0)
          (mk-u 5903 'reaper 52.0 36.0 #:hp 60.0)))

  ;; (5a) At 150M/125G with 0 Tanks & 1 Hellion -> trains `'siege-tank` (NOT Hellion #2)!
  (define rt-r1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-r1
    (step-layer2-economy!
     rt-r1
     (mk-live-obs 'Terran 'Terran 4200 #:minerals 150 #:gas 125 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 17 #:vespene-harvesters 3
                  #:under-attack? #t
                  #:ally-units units-reap #:ally-buildings bldgs-reap #:enemy-units enemy-reapers)))
  ;; (5b) At 150M/100G with 0 Tanks & 1 Hellion -> trains `'cyclone` (NOT Hellion #2)!
  (define rt-r2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-r2
    (step-layer2-economy!
     rt-r2
     (mk-live-obs 'Terran 'Terran 4200 #:minerals 150 #:gas 100 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 17 #:vespene-harvesters 3
                  #:under-attack? #t
                  #:ally-units units-reap #:ally-buildings bldgs-reap #:enemy-units enemy-reapers)))
  ;; (5c) At 200M/110G with 0 Tanks & 1 Hellion & bare Barracks -> defers Starport & BarracksReactor gas!
  (define rt-r3 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-r3
    (step-layer2-economy!
     rt-r3
     (mk-live-obs 'Terran 'Terran 4200 #:minerals 200 #:gas 110 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 17 #:vespene-harvesters 3
                  #:under-attack? #t
                  #:ally-units units-reap #:ally-buildings bldgs-reap #:enemy-units enemy-reapers)))
  (check-true "L68-B2-5-tvt-techlab-factory-reaper-trains-tank-and-cyclone-not-hellion-or-sp"
              (and (has-train? acts-r1 'siege-tank)
                   (not (has-train? acts-r1 'hellion))
                   (has-train? acts-r2 'cyclone)
                   (not (has-train? acts-r2 'hellion))
                   (not (has-build? acts-r3 'starport))
                   (not (has-build? acts-r3 'barracks-reactor)))
              (format "r1=~a r2=~a r3builds=~a"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-r1)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-r2)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-r3))))

;; -----------------------------------------------------------------------------
;; 6. L68-B3-6: Protoss OWM Capital-Air + VoidRay Stargate Reserve in P2 & P3
;; -----------------------------------------------------------------------------
(let ()
  (define rt-pvr (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define pvr-bldgs
    (list (mk-u 6001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 6002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 6003 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 6004 'pylon 44.0 38.0 #:hp 200.0 #:shield 200.0)
          (mk-u 6005 'cybernetics-core 40.0 38.0 #:hp 550.0 #:shield 550.0)
          (mk-u 6006 'stargate 48.0 38.0 #:hp 600.0 #:shield 600.0)
          (mk-u 6007 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 6008 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 6009 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 6010 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 6011 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)))
  (define pvr-units
    (append (for/list ([i (in-range 36)])
              (mk-u (+ 6100 i) 'probe 29.0 (+ 28.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0))
            (for/list ([i (in-range 6)])
              (mk-u (+ 6150 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))))
  (define enemy-tempests
    (list (mk-u 6901 'tempest 95.0 75.0 #:hp 200.0 #:shield 125.0 #:flying #t)
          (mk-u 6902 'tempest 97.0 75.0 #:hp 200.0 #:shield 125.0 #:flying #t)
          (mk-u 6903 'tempest 99.0 75.0 #:hp 200.0 #:shield 125.0 #:flying #t)))
  ;; Frame 7500: observe 3 Tempests in Layer 1 perception.
  (step-layer1-perception!
   rt-pvr
   (mk-live-obs 'Protoss 'Protoss 7500 #:minerals 200 #:gas 130 #:supply-used 48 #:supply-cap 78
                #:mineral-harvesters 30 #:vespene-harvesters 6
                #:researched-upgrades '(warp-gate-research)
                #:ally-units pvr-units #:ally-buildings pvr-bldgs
                #:enemy-units enemy-tempests))
  ;; Frame 7600: Tempests in fog, 200M/130G -> P3 Gateways MUST yield so Stargate reaches 250M/150G!
  (define obs-pvr-hold
    (mk-live-obs 'Protoss 'Protoss 7600 #:minerals 200 #:gas 130 #:supply-used 48 #:supply-cap 78
                 #:mineral-harvesters 30 #:vespene-harvesters 6
                 #:researched-upgrades '(warp-gate-research)
                 #:ally-units pvr-units #:ally-buildings pvr-bldgs
                 #:enemy-units '()))
  (step-layer1-perception! rt-pvr obs-pvr-hold)
  (define acts-pvr-hold (step-layer2-economy! rt-pvr obs-pvr-hold))
  ;; Frame 7640: At 280M/160G -> Stargate trains `'void-ray`!
  (define obs-pvr-go
    (mk-live-obs 'Protoss 'Protoss 7640 #:minerals 280 #:gas 160 #:supply-used 48 #:supply-cap 78
                 #:mineral-harvesters 30 #:vespene-harvesters 6
                 #:researched-upgrades '(warp-gate-research)
                 #:ally-units pvr-units #:ally-buildings pvr-bldgs
                 #:enemy-units '()))
  (step-layer1-perception! rt-pvr obs-pvr-go)
  (define acts-pvr-go (step-layer2-economy! rt-pvr obs-pvr-go))
  (check-true "L68-B3-6-protoss-owm-tempests-yield-gateway-for-voidray-reserve-and-train-voidray"
              (and (not (has-train? acts-pvr-hold 'stalker))
                   (not (has-train? acts-pvr-hold 'zealot))
                   (not (has-train? acts-pvr-hold 'adept))
                   (has-train? acts-pvr-go 'void-ray))
              (format "holdTrains=~a goTrains=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train warp-in)))) acts-pvr-hold)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train warp-in)))) acts-pvr-go))))

;; -----------------------------------------------------------------------------
;; 7. L68-B3-7: Protoss OWM Unburrowed WidowMine Observer #1 Emergency Bypass
;; -----------------------------------------------------------------------------
(let ()
  (define rt-obs (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-bldgs
    (list (mk-u 7001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 7002 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 7003 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 7004 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0)
          (mk-u 7005 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0)
          (mk-u 7006 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 7007 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)))
  (define obs-units
    (append (for/list ([i (in-range 20)])
              (mk-u (+ 7100 i) 'probe 29.0 (+ 28.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 7130 i) 'stalker 48.0 (+ 32.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))))
  ;; Frame 4400: observe 1 UNBURROWED `'widow-mine` (not cloaked, not burrowed!).
  (step-layer1-perception!
   rt-obs
   (mk-live-obs 'Protoss 'Terran 4400 #:minerals 300 #:gas 125 #:supply-used 28 #:supply-cap 46
                #:mineral-harvesters 14 #:vespene-harvesters 6
                #:ally-units obs-units #:ally-buildings obs-bldgs
                #:enemy-units (list (mk-u 7901 'widow-mine 85.0 70.0 #:hp 90.0))))
  ;; Frame 4460: Widow Mine stepped into fog, 1-base Protoss saving for expand (300M/125G, 0 Obs, 0 Immortals):
  ;; Observer #1 MUST train IMMEDIATELY ahead of Immortal & 1-base Nexus save-hold!
  (define obs-fog-wm
    (mk-live-obs 'Protoss 'Terran 4460 #:minerals 300 #:gas 125 #:supply-used 28 #:supply-cap 46
                 #:mineral-harvesters 14 #:vespene-harvesters 6
                 #:ally-units obs-units #:ally-buildings obs-bldgs
                 #:enemy-units '()))
  (step-layer1-perception! rt-obs obs-fog-wm)
  (define acts-obs (step-layer2-economy! rt-obs obs-fog-wm))
  (check-true "L68-B3-7-protoss-owm-unburrowed-widow-mine-trains-observer1-ahead-of-immortal-and-expand"
              (and (has-train? acts-obs 'observer)
                   (not (has-train? acts-obs 'immortal)))
              (format "trains=~a" (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-obs))))

;; -----------------------------------------------------------------------------
;; 8. L68-B1-8: Zerg Mass-Banshee Roach/BanelingNest Protection & OWM BC Queen/Spire Unblock
;; -----------------------------------------------------------------------------
(let ()
  ;; (8a) Mass Banshee: 3 Banshees, HydraDen + RoachWarren + Pool ready, 2 Hydras, 4 Larvae:
  ;;      At 100M/35G -> MUST NOT burn 25G on fallback `'roach`!
  ;;      At 150M/60G -> MUST NOT build `'baneling-nest`!
  (define rt-zb (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define zb-bldgs
    (list (mk-u 8001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 8002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 8003 'spawning-pool 38.0 34.0 #:hp 1000.0)
          (mk-u 8004 'roach-warren 42.0 34.0 #:hp 850.0)
          (mk-u 8005 'hydralisk-den 46.0 34.0 #:hp 850.0)
          (mk-u 8006 'extractor 28.5 36.5 #:hp 500.0)
          (mk-u 8007 'extractor 36.5 28.5 #:hp 500.0)))
  (define zb-units
    (append (for/list ([i (in-range 32)])
              (mk-u (+ 8100 i) 'drone 29.0 (+ 28.0 (* 0.2 i)) #:hp 40.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 8140 i) 'larva 34.0 (+ 31.0 (* 0.3 i)) #:hp 25.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 8150 i) 'queen 36.0 (+ 32.0 (* 0.4 i)) #:hp 175.0))
            (list (mk-u 8160 'hydralisk 48.0 32.0 #:hp 90.0)
                  (mk-u 8161 'hydralisk 49.0 32.0 #:hp 90.0)
                  (mk-u 8162 'overseer 50.0 32.0 #:hp 200.0 #:flying #t))))
  (define enemy-3-banshees
    (list (mk-u 8901 'banshee 90.0 70.0 #:hp 140.0 #:flying #t)
          (mk-u 8902 'banshee 92.0 72.0 #:hp 140.0 #:flying #t)
          (mk-u 8903 'banshee 94.0 74.0 #:hp 140.0 #:flying #t)))
  (define obs-zb-35g
    (mk-live-obs 'Zerg 'Terran 6600 #:minerals 100 #:gas 35 #:supply-used 46 #:supply-cap 74
                 #:mineral-harvesters 26 #:vespene-harvesters 6
                 #:ally-units zb-units #:ally-buildings zb-bldgs
                 #:enemy-units enemy-3-banshees))
  (step-layer1-perception! rt-zb obs-zb-35g)
  (define acts-zb-35g (step-layer2-economy! rt-zb obs-zb-35g))
  (define rt-zb2 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define obs-zb-60g
    (mk-live-obs 'Zerg 'Terran 6600 #:minerals 150 #:gas 60 #:supply-used 46 #:supply-cap 74
                 #:mineral-harvesters 26 #:vespene-harvesters 6
                 #:ally-units zb-units #:ally-buildings zb-bldgs
                 #:enemy-units enemy-3-banshees))
  (step-layer1-perception! rt-zb2 obs-zb-60g)
  (define acts-zb-60g (step-layer2-economy! rt-zb2 obs-zb-60g))
  (check-true "L68-B1-8a-zerg-mass-banshee-blocks-roach-25g-drain-and-baneling-nest"
              (and (not (has-train? acts-zb-35g 'roach))
                   (not (has-build? acts-zb-60g 'baneling-nest)))
              (format "35gTrains=~a 60gBuilds=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train morph-unit)))) acts-zb-35g)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build morph-building)))) acts-zb-60g)))

  ;; (8b) Early OWM Battlecruiser (in fog!): Lair ready, 0 Spire, 4 Queens, 1 Overlord, 250M/120G ->
  ;;      MUST train `'queen` #5 (7-8 Queen surge) AND MUST NOT morph routine `'overseer` (50G) ahead of Spire (200G)!
  (define rt-zbc (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define zbc-bldgs
    (list (mk-u 8201 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 8202 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 8203 'spawning-pool 38.0 34.0 #:hp 1000.0)
          (mk-u 8204 'extractor 28.5 36.5 #:hp 500.0)
          (mk-u 8205 'extractor 36.5 28.5 #:hp 500.0)
          (mk-u 8206 'spore-crawler 30.0 33.0 #:hp 400.0)
          (mk-u 8207 'spore-crawler 60.0 33.0 #:hp 400.0)
          (mk-u 8208 'hydralisk-den 42.0 34.0 #:hp 850.0)))
  (define zbc-units
    (append (for/list ([i (in-range 32)])
              (mk-u (+ 8300 i) 'drone 29.0 (+ 28.0 (* 0.2 i)) #:hp 40.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 8340 i) 'queen 36.0 (+ 32.0 (* 0.4 i)) #:hp 175.0))
            (list (mk-u 8360 'overlord 40.0 32.0 #:hp 200.0 #:flying #t)
                  (mk-u 8361 'overlord 42.0 32.0 #:hp 200.0 #:flying #t))))
  ;; Frame 5800: observe 1 Battlecruiser in Layer 1 perception.
  (step-layer1-perception!
   rt-zbc
   (mk-live-obs 'Zerg 'Terran 5800 #:minerals 300 #:gas 120 #:supply-used 42 #:supply-cap 66
                #:mineral-harvesters 26 #:vespene-harvesters 6
                #:ally-units zbc-units #:ally-buildings zbc-bldgs
                #:enemy-units (list (mk-u 8950 'battlecruiser 95.0 75.0 #:hp 550.0 #:flying #t))))
  ;; Frame 5880: Battlecruiser stepped into fog (`enemy-units = '()`)!
  (define obs-zbc-fog
    (mk-live-obs 'Zerg 'Terran 5880 #:minerals 300 #:gas 120 #:supply-used 42 #:supply-cap 66
                 #:mineral-harvesters 26 #:vespene-harvesters 6
                 #:ally-units zbc-units #:ally-buildings zbc-bldgs
                 #:enemy-units '()))
  (step-layer1-perception! rt-zbc obs-zbc-fog)
  (define acts-zbc-fog (step-layer2-economy! rt-zbc obs-zbc-fog))
  (check-true "L68-B1-8b-zerg-owm-bc-surges-queen5-and-protects-spire-gas-over-overseer"
              (and (has-train? acts-zbc-fog 'queen)
                   (not (has-train? acts-zbc-fog 'overseer)))
              (format "trains=~a builds=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train morph-unit)))) acts-zbc-fog)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build morph-building)))) acts-zbc-fog))))

;; -----------------------------------------------------------------------------
;; 9. L68C-B6-9: Restored 3rd-Base Stability Prereqs (Terran >=42 sup / >=10 army /
;;               ready Starport; Protoss >=46 sup / >=14 army or 40w+10 army)
;; -----------------------------------------------------------------------------
(let ()
  (define exps-3 (list (list 32.5 32.5) (list 62.5 32.5) (list 32.5 68.5) (list 92.5 32.5)))

  ;; (9a) Terran: at 38 sup + 8 army + Factory ready (NO Starport!) + 300M -> MUST NOT start
  ;;      premature 400M 3rd-CC escrow (builds Starport instead!); once >=42 sup / >=10 army /
  ;;      Starport ready at 450M -> emits 3rd CC expand!
  (define rt-3t-pre (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-3t-pre
    (list (mk-u 9001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 9002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 9003 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 9004 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 9005 'supply-depot 42.0 30.0 #:hp 400.0)
          (mk-u 9006 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 9007 'factory 46.0 34.0 #:hp 1250.0 #:order-count 1)
          (mk-u 9008 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 9009 'refinery 36.5 28.5 #:hp 500.0)))
  (define units-3t-pre
    (append (for/list ([i (in-range 30)])
              (mk-u (+ 9100 i) 'scv 29.0 (+ 28.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 8)])
              (mk-u (+ 9140 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0))))
  (define acts-3t-pre
    (step-layer2-economy!
     rt-3t-pre
     (mk-live-obs 'Terran 'Protoss 6200 #:minerals 300 #:gas 150 #:supply-used 38 #:supply-cap 62
                  #:mineral-harvesters 24 #:vespene-harvesters 6
                  #:expansion-locations exps-3
                  #:ally-units units-3t-pre #:ally-buildings bldgs-3t-pre)))
  (define rt-3t-rdy (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define units-3t-rdy
    (append (for/list ([i (in-range 34)])
              (mk-u (+ 9100 i) 'scv 29.0 (+ 28.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 10)])
              (mk-u (+ 9140 i) 'marine 52.0 (+ 30.0 (* 0.4 i)) #:hp 45.0))))
  (define acts-3t-rdy
    (step-layer2-economy!
     rt-3t-rdy
     (mk-live-obs 'Terran 'Protoss 6200 #:minerals 500 #:gas 100 #:supply-used 44 #:supply-cap 62
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:expansion-locations exps-3
                  #:ally-units units-3t-rdy
                  #:ally-buildings (append (list (mk-u 9010 'starport 50.0 34.0 #:hp 1300.0 #:order-count 1)
                                                 (mk-u 9011 'engineering-bay 38.0 38.0 #:hp 850.0 #:order-count 1)
                                                 (mk-u 9012 'barracks 42.0 38.0 #:hp 1000.0 #:order-count 1))
                                           bldgs-3t-pre))))
  (check-true "L68C-B6-9a-terran-3rd-cc-prereqs-hold-before-starport-and-expand-at-44sup-10army"
              (and (has-build? acts-3t-pre 'starport)
                   (has-expand? acts-3t-rdy))
              (format "pre=~a rdy=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(expand build)))) acts-3t-pre)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(expand build)))) acts-3t-rdy)))

  ;; (9b) Protoss: at 40 sup / 32 Probes / 8 army / 550M -> MUST NOT prematurely expand 3rd Nexus;
  ;;      once >=46 sup / >=14 army (7 Stalkers) + 38 Probes + Robo ready at 550M -> emits 3rd Nexus!
  (define bldgs-3p
    (list (mk-u 9201 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 9202 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 9203 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9204 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9205 'pylon 52.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9206 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 9207 'gateway 44.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 9214 'gateway 40.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 9215 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 9216 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 9208 'cybernetics-core 48.0 38.0 #:hp 550.0 #:shield 550.0)
          (mk-u 9209 'robotics-facility 52.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 9213 'twilight-council 56.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 9210 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 9211 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
          (mk-u 9212 'assimilator 60.0 36.5 #:hp 300.0 #:shield 300.0)))
  (define units-3p-pre
    (append (for/list ([i (in-range 32)])
              (mk-u (+ 9300 i) 'probe 29.0 (+ 28.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 9350 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))))
  (define units-3p-rdy
    (append (for/list ([i (in-range 38)])
              (mk-u (+ 9300 i) 'probe 29.0 (+ 28.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0))
            (for/list ([i (in-range 7)])
              (mk-u (+ 9350 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))))
  (define rt-3p-pre (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3p-pre
    (step-layer2-economy!
     rt-3p-pre
     (mk-live-obs 'Protoss 'Terran 6200 #:minerals 550 #:gas 100 #:supply-used 40 #:supply-cap 62
                  #:mineral-harvesters 23 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units units-3p-pre #:ally-buildings bldgs-3p)))
  (define rt-3p-rdy (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3p-rdy
    (step-layer2-economy!
     rt-3p-rdy
     (mk-live-obs 'Protoss 'Terran 6200 #:minerals 550 #:gas 100 #:supply-used 52 #:supply-cap 78
                  #:mineral-harvesters 29 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units units-3p-rdy #:ally-buildings bldgs-3p)))
  (check-true "L68C-B6-9b-protoss-3rd-nexus-prereqs-hold-at-40sup-and-expand-at-52sup-14army"
              (and (not (has-expand? acts-3p-pre))
                   (has-expand? acts-3p-rdy))
              (format "pre=~a rdy=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(expand build)))) acts-3p-pre)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(expand build)))) acts-3p-rdy))))

;; -----------------------------------------------------------------------------
;; 10. L68-B4-10: Runtime Tempest Home-Shell (`20.0t`) & AA Closure (`22.0t`)
;;     + Negative Guard Preserving Ground `< 0.85x` Disengage
;; -----------------------------------------------------------------------------
(let ()
  ;; (10a) 2 Viking Fighters (suppressed `fap = 0.25`) at 20.5t from an enemy Tempest shelling
  ;;       from 18.0t outside Main `(32.5, 32.5)`: MUST emit `attack-unit` on Tempest (NOT move retreat)!
  (define rt-tclose (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-tclose
    (mk-live-obs 'Terran 'Protoss 8200 #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 62
                 #:ally-buildings (list (mk-u 9501 'orbital-command 32.5 32.5 #:hp 1500.0))
                 #:ally-units (list (mk-u 9510 'viking-fighter 30.0 32.5 #:hp 135.0 #:flying #t)
                                    (mk-u 9511 'viking-fighter 30.0 33.5 #:hp 135.0 #:flying #t))
                 #:enemy-units (list (mk-u 9590 'tempest 50.5 32.5 #:hp 200.0 #:shield 125.0 #:flying #t)
                                     ;; Distant heavy ground army far away to keep overall fap depressed
                                     (mk-u 9591 'carrier 135.0 130.0 #:hp 300.0 #:shield 150.0 #:flying #t)
                                     (mk-u 9592 'carrier 137.0 130.0 #:hp 300.0 #:shield 150.0 #:flying #t)
                                     (mk-u 9593 'carrier 139.0 130.0 #:hp 300.0 #:shield 150.0 #:flying #t))))
  (step-layer1-perception! rt-tclose obs-tclose)
  (define acts-tclose (run-l34 rt-tclose obs-tclose 0.20))
  (define viking-attacks-tempest?
    (and (ormap (lambda (a)
                  (and (pair? a)
                       (eq? (car a) 'attack-unit)
                       (>= (length a) 3)
                       (memv (second a) '(9510 9511))
                       (= (third a) 9590)))
                acts-tclose)
         #t))
  (check-true "L68-B4-10a-suppressed-aa-flyers-at-20.5t-close-on-tempest-at-18t-from-main"
              viking-attacks-tempest?
              (format "acts=~a" acts-tclose))

  ;; (10b) Negative guard: Outnumbered ground Marines (`2` Marines vs `8` Roaches at `18.0t` in mid-map,
  ;;       no capital air, no home threat) MUST still disengage (NOT dive into outnumbered ground)!
  (define rt-gdis (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-gdis
    (mk-live-obs 'Terran 'Zerg 6000 #:minerals 100 #:gas 50 #:supply-used 24 #:supply-cap 46
                 #:ally-buildings (list (mk-u 9601 'orbital-command 32.5 32.5 #:hp 1500.0))
                 #:ally-units (list (mk-u 9610 'marine 90.0 90.0 #:hp 45.0)
                                    (mk-u 9611 'marine 91.0 90.0 #:hp 45.0))
                 #:enemy-units (for/list ([i (in-range 8)])
                                 (mk-u (+ 9650 i) 'roach (+ 108.0 (* 0.5 i)) 90.0 #:hp 145.0))))
  (step-layer1-perception! rt-gdis obs-gdis)
  (define acts-gdis (run-l34 rt-gdis obs-gdis 0.15))
  (define marine-retreats?
    (and (ormap (lambda (a)
                  (and (pair? a)
                       (eq? (car a) 'move)
                       (>= (length a) 4)
                       (memv (second a) '(9610 9611))
                       (< (third a) 90.0)))
                acts-gdis)
         #t))
  (check-true "L68-B4-10b-outnumbered-ground-squad-still-disengages-away-from-enemy"
              marine-retreats?
              (format "acts=~a" acts-gdis)))

;; -----------------------------------------------------------------------------
;; 11. L68B-11: Zerg Lone `StarportTechLab` No False Spire / Corruptor Drain
;; -----------------------------------------------------------------------------
(let ()
  (define rt-z1 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z1-bldgs
    (list (mk-u 9701 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 9702 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 9703 'spawning-pool 38.0 34.0 #:hp 1000.0)
          (mk-u 9704 'roach-warren 42.0 34.0 #:hp 850.0)
          (mk-u 9705 'extractor 28.5 36.5 #:hp 500.0)
          (mk-u 9706 'extractor 36.5 28.5 #:hp 500.0)
          (mk-u 9708 'spore-crawler 30.0 33.0 #:hp 400.0)
          (mk-u 9709 'spore-crawler 60.0 33.0 #:hp 400.0)))
  (define z1-units
    (append (for/list ([i (in-range 34)])
              (mk-u (+ 9710 i) 'drone 29.0 (+ 28.0 (* 0.2 i)) #:hp 40.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 9750 i) 'larva 34.0 (+ 31.0 (* 0.3 i)) #:hp 25.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 9760 i) 'queen 36.0 (+ 32.0 (* 0.4 i)) #:hp 175.0))
            (list (mk-u 9770 'overseer 44.0 32.0 #:hp 200.0 #:flying #t)
                  (mk-u 9771 'roach 48.0 32.0 #:hp 145.0))))
  (define enemy-bio-medivac
    (list (mk-u 9781 'marine 110.0 90.0 #:hp 45.0)
          (mk-u 9782 'marine 111.0 90.0 #:hp 45.0)
          (mk-u 9783 'marine 112.0 90.0 #:hp 45.0)
          (mk-u 9784 'marine 113.0 90.0 #:hp 45.0)
          (mk-u 9785 'marauder 114.0 92.0 #:hp 125.0)
          (mk-u 9786 'marauder 115.0 92.0 #:hp 125.0)
          (mk-u 9787 'medivac 112.0 94.0 #:hp 150.0 #:flying #t)))
  ;; Single lone enemy `starport-techlab` (no Banshees, no BCs, no Fusion Core!):
  (define enemy-lone-sptl
    (list (mk-u 9790 'starport 135.0 130.0 #:hp 1300.0)
          (mk-u 9791 'starport-techlab 137.5 129.5 #:hp 400.0)))
  (define obs-z1
    (mk-live-obs 'Zerg 'Terran 6200 #:minerals 300 #:gas 220 #:supply-used 48 #:supply-cap 74
                 #:mineral-harvesters 28 #:vespene-harvesters 6
                 #:ally-units z1-units #:ally-buildings z1-bldgs
                 #:enemy-units enemy-bio-medivac #:enemy-buildings enemy-lone-sptl))
  (step-layer1-perception! rt-z1 obs-z1)
  (define acts-z1 (step-layer2-economy! rt-z1 obs-z1))
  ;; Also verify ready Spire with 0 air threat & 0 Corruptors does NOT force Corruptor drain over Roach:
  (define rt-z2 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define obs-z2
    (mk-live-obs 'Zerg 'Terran 6400 #:minerals 220 #:gas 120 #:supply-used 48 #:supply-cap 74
                 #:mineral-harvesters 28 #:vespene-harvesters 6
                 #:ally-units z1-units
                 #:ally-buildings (cons (mk-u 9707 'spire 46.0 34.0 #:hp 850.0) z1-bldgs)
                 #:enemy-units enemy-bio-medivac #:enemy-buildings enemy-lone-sptl))
  (step-layer1-perception! rt-z2 obs-z2)
  (define acts-z2 (step-layer2-economy! rt-z2 obs-z2))
  (check-true "L68B-11-zerg-lone-starport-techlab-no-false-spire-or-corruptor-drain"
              (and (not (has-build? acts-z1 'spire))
                   (has-train? acts-z1 'roach)
                   (not (has-train? acts-z2 'corruptor))
                   (has-train? acts-z2 'roach))
              (format "z1Builds=~a z1Trains=~a z2Builds=~a z2Trains=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build morph-building)))) acts-z1)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train morph-unit)))) acts-z1)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build morph-building)))) acts-z2)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train morph-unit)))) acts-z2))))

;; -----------------------------------------------------------------------------
;; 12. L68B-12: Terran TvT Bare-Factory Hellion Cap (`<= 1`) & TechLab Attach vs Reapers
;; -----------------------------------------------------------------------------
(let ()
  (define bldgs-bare
    (list (mk-u 9801 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 9802 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 9803 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 9804 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 9805 'factory 46.0 34.0 #:hp 1250.0)
          (mk-u 9806 'refinery 28.5 36.5 #:hp 500.0)))
  (define units-bare
    (append (for/list ([i (in-range 20)])
              (mk-u (+ 9810 i) 'scv 29.0 (+ 28.0 (* 0.2 i)) #:hp 45.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 9840 i) 'marine 52.0 (+ 32.0 (* 0.5 i)) #:hp 45.0))
            (list (mk-u 9850 'hellion 54.0 33.0 #:hp 90.0))))
  (define enemy-reapers-far
    (list (mk-u 9891 'reaper 60.0 34.0 #:hp 60.0)
          (mk-u 9892 'reaper 61.0 35.0 #:hp 60.0)
          (mk-u 9893 'reaper 62.0 36.0 #:hp 60.0)))
  ;; (12a) With 1 Hellion already live, 0 Tanks, bare Factory #1, `150M/40G` vs 3 Reapers:
  ;;       MUST attach `factory-techlab` (`50M/25G`) and MUST NOT spam Hellion #2!
  (define rt-bf1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-bf1
    (step-layer2-economy!
     rt-bf1
     (mk-live-obs 'Terran 'Terran 4200 #:minerals 150 #:gas 40 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 17 #:vespene-harvesters 3
                  #:under-attack? #t
                  #:ally-units units-bare #:ally-buildings bldgs-bare #:enemy-units enemy-reapers-far)))
  ;; (12b) Even at `150M/15G` (`< 25G`, before TechLab affordable) with 1 Hellion already live:
  ;;       MUST hold bare Factory #1 (NO Hellion #2!) so TechLab attaches as soon as gas reaches 25G!
  (define rt-bf2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-bf2
    (step-layer2-economy!
     rt-bf2
     (mk-live-obs 'Terran 'Terran 4200 #:minerals 150 #:gas 15 #:supply-used 26 #:supply-cap 47
                  #:mineral-harvesters 17 #:vespene-harvesters 3
                  #:under-attack? #t
                  #:ally-units units-bare #:ally-buildings bldgs-bare #:enemy-units enemy-reapers-far)))
  (check-true "L68B-12-tvt-bare-factory-caps-hellion-at-1-and-attaches-techlab-vs-reapers"
              (and (has-build? acts-bf1 'factory-techlab)
                   (not (has-train? acts-bf1 'hellion))
                   (not (has-train? acts-bf2 'hellion)))
              (format "bf1Builds=~a bf1Trains=~a bf2Trains=~a"
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build build-addon)))) acts-bf1)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-bf1)
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'train))) acts-bf2))))

(printf "\n=== Loop 68 Lane B Runtime AA & Econ Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
