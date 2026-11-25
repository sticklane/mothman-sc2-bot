#lang racket/base

;; =============================================================================
;; `tests/l75-runtime-upgrades-cohesion-test.rkt`
;; Loop 75 Lane B — Zero-Greed +2/+3 Upgrades, Zerg Evo Ordering, Terran/Protoss
;; Upgrade Unblocks, Runtime Phoenix Cap, & Front-to-Back / Mid-Map Split Pullback
;;
;; Covers:
;;   1. L75-B1: `upg-essential?` promotes ready +2/+3 Weapons & +1/+2/+3 Armor
;;      on >= 3 bases & >= 7:30 (`10080f`) peaceful cash-in-hand; ZERO promotion
;;      on <= 2 bases or < 10080f!
;;   2. L75-B2: Zerg Evo chamber ordering chains +1 Armor & +2 Missile AHEAD of
;;      melee-1 for ranged cores (>= 6 Roaches/Ravagers/Hydras), while pure-Ling
;;      armies still get melee-1!
;;   3. L75-B3: Terran >= 7:30 cash-funded Armory waives 300M core-prod reserve
;;      (< 7:30 stays protected!), and 3-base ready EBay chains +2/+3 at >= 200M/175G!
;;   4. L75-B4: Protoss >= 3 bases ready Forge chains +2/+3 with >= 2 Colossi
;;      while still preserving Colossus #1/#2 escrow at 0 Colossi!
;;   5. L75-B5: Runtime `phoenix-cap` caps Phoenixes at 0 vs Terran ground with
;;      0 Banshees and <= 2..3 vs 1 Banshee + ground, preserving Colossus escrow!
;;   6. L75-B6: Strictly mid-map (> 20t from owned THs) 16t split-squad pullback
;;      (< 0.65x local, >= 0.85x global, d > wr) pulls back toward regroup while
;;      inside-base squad STILL fights (`OBRet == 0`) & in-range squad keeps firing
;;      (`zero_fire_retreat == 0`), plus 8..14t Stalker front-to-back screening!
;; =============================================================================

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
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
              #:flying [fly? #f]
              #:build-progress [bp 1.0]
              #:orders [ords '()]
              #:order-count [oc #f]
              #:order-ability-id [oab 0]
              #:order-target-id [otid 0]
              #:busy? [busy? #f]
              #:buffs [buffs '()]
              #:powered? [pow? #t]
              #:weapon-cooldown [wcd 0.0])
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
            'weapon-cooldown (exact->inexact wcd)
            'display-type 1))
  (if oc (hash-set h0 'order-count oc) h0))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 220]
                     #:gas [gas 200]
                     #:supply-used [su 88]
                     #:supply-cap [sc 134]
                     #:mineral-harvesters [mh 42]
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

(define (has-train? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(train morph-unit warp-in))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (unit-acts acts uid)
  (filter (lambda (a)
            (and (pair? a) (>= (length a) 2) (eqv? (second a) uid)))
          acts))

(define (run-l34 rt obs [fap 0.60])
  (step-layer1-perception! rt obs)
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt) obs)
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(define (fmt-fail rt acts)
  (define tel (live-bot-runtime-last-telemetry rt))
  (define pl (and (hash? tel) (hash-ref tel 'priority-log-line #f)))
  (define macro-acts
    (filter (lambda (a)
              (and (pair? a)
                   (memq (car a) '(build build-addon morph-building train morph-unit warp-in
                                   research expand cast-spell))))
            acts))
  (format "macro=~a prio=~a" macro-acts pl))

(define (mk-workers sym n [start-id 2100] [hp 45.0] [sh 0.0])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) sym (+ 28.0 (* 0.15 (modulo i 18))) (+ 30.0 (* 0.25 (quotient i 18)))
          #:hp hp #:shield sh)))

(define exps-3 (list (list 32.5 32.5) (list 62.5 32.5) (list 32.5 68.5)))
(define exps-2 (list (list 32.5 32.5) (list 62.5 32.5)))

(printf "=== Loop 75 Lane B Zero-Greed Upgrades, Phoenix Cap & Combat Cohesion Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L75-B1: `upg-essential?` on >= 3 Bases & >= 7:30 (`10080f`) Cash-in-Hand
;; -----------------------------------------------------------------------------
(let ()
  ;; Terran 3-base at 10500f vs 6000f (2-base): with ready EBay + Armory + +1W done + 200M/180G,
  ;; Arbiter grants priority 780.0 (essential) on 3-base >= 10080f even against a 680.0 competing spend,
  ;; while on 2-base or < 10080f +2W stays non-essential (620.0)!
  (define (mk-t-upg-bldgs n-bases)
    (append
     (list (mk-u 1001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
           (mk-u 1002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1))
     (if (>= n-bases 3) (list (mk-u 1003 'orbital-command 32.5 68.5 #:hp 1500.0 #:order-count 1)) '())
     (list (mk-u 1010 'barracks 40.0 34.0 #:hp 1000.0 #:order-count 1)
           (mk-u 1011 'barracks 44.0 34.0 #:hp 1000.0 #:order-count 1)
           (mk-u 1012 'barracks 48.0 34.0 #:hp 1000.0 #:order-count 1)
           (mk-u 1013 'barracks 52.0 34.0 #:hp 1000.0 #:order-count 1)
           (mk-u 1014 'barracks 40.0 38.0 #:hp 1000.0 #:order-count 1)
           (mk-u 1015 'factory 44.0 38.0 #:hp 1250.0 #:order-count 1)
           (mk-u 1016 'starport 48.0 38.0 #:hp 1300.0 #:order-count 1)
           (mk-u 1017 'engineering-bay 36.0 42.0 #:hp 850.0 #:order-count 0)
           (mk-u 1018 'armory 40.0 42.0 #:hp 750.0 #:order-count 1)
           (mk-u 1020 'refinery 28.5 36.5 #:hp 500.0)
           (mk-u 1021 'refinery 36.5 28.5 #:hp 500.0)
           (mk-u 1022 'refinery 58.5 36.5 #:hp 500.0)
           (mk-u 1023 'refinery 66.5 28.5 #:hp 500.0)
           (mk-u 1024 'supply-depot 36.0 30.0 #:hp 400.0)
           (mk-u 1025 'supply-depot 38.0 30.0 #:hp 400.0)
           (mk-u 1026 'supply-depot 40.0 30.0 #:hp 400.0)
           (mk-u 1027 'missile-turret 30.0 34.0 #:hp 250.0)
           (mk-u 1028 'missile-turret 60.0 34.0 #:hp 250.0))))
  (define t-units-3b
    (append (mk-workers 'scv 54 1100 45.0 0.0)
            (for/list ([i (in-range 16)]) (mk-u (+ 1200 i) 'marine 52.0 (+ 30.0 (* 0.3 i)) #:hp 45.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 1250 i) 'marauder 54.0 (+ 30.0 (* 0.5 i)) #:hp 125.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 1280 i) 'medivac 50.0 (+ 34.0 (* 1.0 i)) #:hp 150.0 #:flying #t))))

  ;; 1a: Terran 3-base at 10500f with 220M/200G (62 SCVs -> active 400M CC#4 escrow!):
  ;;     `upg-essential?` promotes +2W to essential (bypasses escrow!) -> researches terran-infantry-weapons-2!
  (define t-units-3b-escrow
    (append (mk-workers 'scv 62 1100 45.0 0.0)
            (for/list ([i (in-range 16)]) (mk-u (+ 1200 i) 'marine 52.0 (+ 30.0 (* 0.3 i)) #:hp 45.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 1250 i) 'marauder 54.0 (+ 30.0 (* 0.5 i)) #:hp 125.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 1280 i) 'medivac 50.0 (+ 34.0 (* 1.0 i)) #:hp 150.0 #:flying #t))))
  (define rt-1a (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-1a
    (step-layer2-economy!
     rt-1a
     (mk-live-obs 'Terran 'Protoss 10500 #:minerals 220 #:gas 200 #:supply-used 98 #:supply-cap 134
                  #:mineral-harvesters 50 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-3b-escrow #:ally-buildings (mk-t-upg-bldgs 3)
                  #:researched-upgrades '(terran-infantry-weapons-1 terran-infantry-armor-1 stimpack combat-shield))))
  (check-true "L75-B1-1a-terran-3base-10500f-promotes-infantry-weapons-2-past-escrow"
              (has-research? acts-1a 'terran-infantry-weapons-2)
              (fmt-fail rt-1a acts-1a))

  ;; 1b: Terran 3-base at 6000f (< 10080f) with active CC#4 escrow -> does NOT promote +2W!
  (define rt-1b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-1b
    (step-layer2-economy!
     rt-1b
     (mk-live-obs 'Terran 'Protoss 6000 #:minerals 220 #:gas 200 #:supply-used 98 #:supply-cap 134
                  #:mineral-harvesters 50 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-3b-escrow #:ally-buildings (mk-t-upg-bldgs 3)
                  #:researched-upgrades '(terran-infantry-weapons-1 terran-infantry-armor-1 stimpack combat-shield))))
  (check-true "L75-B1-1b-terran-6000f-below-7m30-does-not-promote-weapons-2-past-escrow"
              (not (has-research? acts-1b 'terran-infantry-weapons-2))
              (fmt-fail rt-1b acts-1b))

  ;; 1c: Terran on 2 bases at 10500f (< 3 bases) with active CC#3 escrow -> does NOT promote +2W!
  (define rt-1c (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-1c
    (step-layer2-economy!
     rt-1c
     (mk-live-obs 'Terran 'Protoss 10500 #:minerals 220 #:gas 200 #:supply-used 90 #:supply-cap 134
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-2
                  #:ally-units t-units-3b #:ally-buildings (mk-t-upg-bldgs 2)
                  #:researched-upgrades '(terran-infantry-weapons-1 terran-infantry-armor-1 stimpack combat-shield))))
  (check-true "L75-B1-1c-terran-2base-10500f-does-not-promote-weapons-2-past-escrow"
              (not (has-research? acts-1c 'terran-infantry-weapons-2))
              (fmt-fail rt-1c acts-1c)))

;; -----------------------------------------------------------------------------
;; 2. L75-B2: Zerg Evolution Chamber Ordering (Ranged Core vs Pure-Ling)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-2evo
    (list (mk-u 3001 'lair 32.5 32.5 #:hp 2000.0 #:buffs '(11))
          (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0 #:buffs '(11))
          (mk-u 3003 'hatchery 32.5 68.5 #:hp 1500.0 #:buffs '(11))
          (mk-u 3004 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 3005 'roach-warren 39.0 34.0 #:hp 850.0)
          (mk-u 3008 'hydralisk-den 42.0 34.0 #:hp 850.0)
          (mk-u 3009 'baneling-nest 45.0 34.0 #:hp 850.0)
          (mk-u 3006 'evolution-chamber 36.0 38.0 #:hp 750.0 #:order-count 0)
          (mk-u 3007 'evolution-chamber 40.0 38.0 #:hp 750.0 #:order-count 0)
          (mk-u 3010 'extractor 28.5 36.5 #:hp 500.0)
          (mk-u 3011 'extractor 36.5 28.5 #:hp 500.0)
          (mk-u 3012 'extractor 58.5 36.5 #:hp 500.0)
          (mk-u 3013 'extractor 66.5 28.5 #:hp 500.0)
          (mk-u 3014 'extractor 28.5 72.5 #:hp 500.0)
          (mk-u 3015 'extractor 36.5 64.5 #:hp 500.0)))

  ;; 2a: 14 Zerglings + 8 Roaches (ranged-core >= 6), +1 Msl done -> starts +1 Armor & +2 Msl, NOT melee-1!
  (define z-units-ranged
    (append (mk-workers 'drone 54 3100 40.0 0.0)
            (for/list ([i (in-range 14)]) (mk-u (+ 3200 i) 'zergling 50.0 (+ 30.0 (* 0.3 i)) #:hp 35.0))
            (for/list ([i (in-range 8)]) (mk-u (+ 3240 i) 'roach 52.0 (+ 30.0 (* 0.5 i)) #:hp 145.0))
            (list (mk-u 3291 'queen 33.5 33.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3292 'queen 63.5 33.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3293 'queen 33.5 69.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3294 'queen 48.0 34.0 #:hp 175.0 #:energy 10.0)
                  (mk-u 3300 'overlord 28.0 28.0 #:hp 200.0 #:flying #t))))
  (define rt-2a (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2a
    (step-layer2-economy!
     rt-2a
     (mk-live-obs 'Zerg 'Protoss 10500 #:minerals 480 #:gas 480 #:supply-used 98 #:supply-cap 134
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units z-units-ranged #:ally-buildings z-bldgs-2evo
                  #:researched-upgrades '(metabolic-boost zerg-missile-weapons-1))))
  (check-true "L75-B2-2a-zerg-ranged-core-researches-armor1-and-missile2-before-melee1"
              (and (has-research? acts-2a 'zerg-ground-armor-1)
                   (has-research? acts-2a 'zerg-missile-weapons-2)
                   (not (has-research? acts-2a 'zerg-melee-weapons-1)))
              (fmt-fail rt-2a acts-2a))

  ;; 2b: Pure-Ling (0 Roaches/Ravagers/Hydras, 16 Zerglings), +1 Msl & +1 Armor & +2 Msl & +2 Armor done -> melee-1 OK!
  (define z-units-pure-ling
    (append (mk-workers 'drone 54 3100 40.0 0.0)
            (for/list ([i (in-range 16)]) (mk-u (+ 3200 i) 'zergling 50.0 (+ 30.0 (* 0.3 i)) #:hp 35.0))
            (list (mk-u 3291 'queen 33.5 33.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3292 'queen 63.5 33.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3293 'queen 33.5 69.5 #:hp 175.0 #:energy 10.0)
                  (mk-u 3294 'queen 48.0 34.0 #:hp 175.0 #:energy 10.0)
                  (mk-u 3300 'overlord 28.0 28.0 #:hp 200.0 #:flying #t))))
  (define rt-2b (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-2b
    (step-layer2-economy!
     rt-2b
     (mk-live-obs 'Zerg 'Protoss 8500 #:minerals 260 #:gas 260 #:supply-used 72 #:supply-cap 118
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units z-units-pure-ling #:ally-buildings z-bldgs-2evo
                  #:researched-upgrades '(metabolic-boost zerg-missile-weapons-1 zerg-ground-armor-1
                                          zerg-missile-weapons-2 zerg-ground-armor-2))))
  (check-true "L75-B2-2b-zerg-pure-ling-still-researches-melee1"
              (has-research? acts-2b 'zerg-melee-weapons-1)
              (fmt-fail rt-2b acts-2b)))

;; -----------------------------------------------------------------------------
;; 3. L75-B3: Terran >= 7:30 Cash-Funded Armory & 3-Base Ready EBay +2/+3
;; -----------------------------------------------------------------------------
(let ()
  (define t-bldgs-no-armory
    (list (mk-u 1001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 0)
          (mk-u 1002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 0)
          (mk-u 1003 'orbital-command 32.5 68.5 #:hp 1500.0 #:order-count 0)
          (mk-u 1004 'orbital-command 62.5 68.5 #:hp 1500.0 #:order-count 0)
          (mk-u 1010 'barracks 40.0 34.0 #:hp 1000.0 #:order-count 0)
          (mk-u 1011 'barracks 44.0 34.0 #:hp 1000.0 #:order-count 0)
          (mk-u 1012 'barracks 48.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1013 'barracks 52.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1019 'barracks 40.0 38.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1014 'factory 44.0 38.0 #:hp 1250.0 #:order-count 0)
          (mk-u 1015 'factory-techlab 46.5 38.0 #:hp 400.0)
          (mk-u 1016 'starport 48.0 38.0 #:hp 1300.0 #:order-count 1)
          (mk-u 1017 'engineering-bay 36.0 42.0 #:hp 850.0 #:order-count 1)
          (mk-u 1020 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 1021 'refinery 36.5 28.5 #:hp 500.0)
          (mk-u 1022 'refinery 58.5 36.5 #:hp 500.0)
          (mk-u 1023 'refinery 66.5 28.5 #:hp 500.0)
          (mk-u 1024 'supply-depot 36.0 30.0 #:hp 400.0)
          (mk-u 1025 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 1026 'supply-depot 40.0 30.0 #:hp 400.0)
          (mk-u 1027 'missile-turret 30.0 34.0 #:hp 250.0)
          (mk-u 1028 'missile-turret 60.0 34.0 #:hp 250.0)))
  (define t-units-20army
    (append (mk-workers 'scv 54 1100 45.0 0.0)
            (for/list ([i (in-range 14)]) (mk-u (+ 1200 i) 'marine 52.0 (+ 30.0 (* 0.3 i)) #:hp 45.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 1240 i) 'marauder 54.0 (+ 30.0 (* 0.5 i)) #:hp 125.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 1280 i) 'medivac 50.0 (+ 34.0 (* 1.0 i)) #:hp 150.0 #:flying #t))))

  ;; 3a: frame=10500 (>= 7:30), +1W done, 20+ army, idle Rax/Fac (core-prod reserve=300M), 180M/120G -> builds armory!
  (define rt-3a (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-3a
    (step-layer2-economy!
     rt-3a
     (mk-live-obs 'Terran 'Zerg 10500 #:minerals 180 #:gas 120 #:supply-used 86 #:supply-cap 134
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-20army #:ally-buildings t-bldgs-no-armory
                  #:researched-upgrades '(terran-infantry-weapons-1 stimpack combat-shield))))
  (check-true "L75-B3-3a-terran-10500f-cash-funded-armory-waives-300m-reserve"
              (has-build? acts-3a 'armory)
              (fmt-fail rt-3a acts-3a))

  ;; 3b: Identical state at frame=5000 (< 7:30) with 180M/120G -> does NOT waive 300M reserve!
  (define rt-3b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-3b
    (step-layer2-economy!
     rt-3b
     (mk-live-obs 'Terran 'Zerg 5000 #:minerals 180 #:gas 120 #:supply-used 86 #:supply-cap 134
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-20army #:ally-buildings t-bldgs-no-armory
                  #:researched-upgrades '(terran-infantry-weapons-1 stimpack combat-shield))))
  (check-true "L75-B3-3b-terran-5000f-below-7m30-does-not-waive-armory-reserve"
              (not (has-build? acts-3b 'armory))
              (fmt-fail rt-3b acts-3b))

  ;; 3c: 3-base ready EBay + Armory at 10500f with 220M/200G & urgent-combat/expand pressure -> researches +2W!
  (define t-bldgs-3b-ebay
    (list (mk-u 1001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 1002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 1003 'orbital-command 32.5 68.5 #:hp 1500.0 #:order-count 1)
          (mk-u 1010 'barracks 40.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1011 'barracks 44.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1012 'barracks 48.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1013 'barracks 52.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1014 'barracks 40.0 38.0 #:hp 1000.0 #:order-count 1)
          (mk-u 1015 'factory 44.0 38.0 #:hp 1250.0 #:order-count 1)
          (mk-u 1016 'starport 48.0 38.0 #:hp 1300.0 #:order-count 1)
          (mk-u 1017 'engineering-bay 36.0 42.0 #:hp 850.0 #:order-count 0)
          (mk-u 1018 'armory 40.0 42.0 #:hp 750.0 #:order-count 1)
          (mk-u 1020 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 1021 'refinery 36.5 28.5 #:hp 500.0)
          (mk-u 1022 'refinery 58.5 36.5 #:hp 500.0)
          (mk-u 1023 'refinery 66.5 28.5 #:hp 500.0)
          (mk-u 1027 'missile-turret 30.0 34.0 #:hp 250.0)
          (mk-u 1028 'missile-turret 60.0 34.0 #:hp 250.0)))
  ;; Visible enemy army at mid-map (triggers urgent-combat-or-intel-need? without under-base-attack?)
  (define mid-enemies
    (for/list ([i (in-range 6)]) (mk-u (+ 9500 i) 'stalker 110.0 (+ 80.0 (* 0.8 i)) #:hp 80.0 #:shield 80.0)))
  (define rt-3c (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-3c
    (step-layer2-economy!
     rt-3c
     (mk-live-obs 'Terran 'Protoss 10500 #:minerals 220 #:gas 200 #:supply-used 90 #:supply-cap 134
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-20army #:ally-buildings t-bldgs-3b-ebay
                  #:enemy-units mid-enemies
                  #:researched-upgrades '(terran-infantry-weapons-1 terran-infantry-armor-1 stimpack combat-shield))))
  (check-true "L75-B3-3c-terran-3base-ready-ebay-researches-weapons-2-at-220m-200g"
              (has-research? acts-3c 'terran-infantry-weapons-2)
              (fmt-fail rt-3c acts-3c)))

;; -----------------------------------------------------------------------------
;; 4. L75-B4: Protoss >= 3 Bases Ready Forge +2/+3 (Protecting Colossus #1/#2)
;; -----------------------------------------------------------------------------
(let ()
  (define p-bldgs-3b-forge
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 2003 'nexus 32.5 68.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 2004 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 2005 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 2006 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2007 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2008 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2009 'gateway 52.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2010 'gateway 40.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2011 'gateway 44.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2024 'gateway 36.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2025 'gateway 52.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2012 'cybernetics-core 48.0 38.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
          (mk-u 2013 'twilight-council 40.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2014 'robotics-facility 48.0 42.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 2015 'robotics-bay 52.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 2016 'forge 36.0 42.0 #:hp 400.0 #:shield 400.0 #:order-count 0)
          (mk-u 2028 'forge 32.0 42.0 #:hp 400.0 #:shield 400.0 #:order-count 1)
          (mk-u 2020 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2021 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2022 'assimilator 58.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2023 'assimilator 66.5 28.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2026 'assimilator 28.5 72.5 #:hp 300.0 #:shield 300.0)
          (mk-u 2027 'assimilator 36.5 64.5 #:hp 300.0 #:shield 300.0)))
  (define (mk-p-units-col n-col)
    (append (mk-workers 'probe 54 2100 20.0 20.0)
            (for/list ([i (in-range 8)]) (mk-u (+ 2200 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range n-col)]) (mk-u (+ 2240 i) 'colossus 50.0 (+ 34.0 (* 0.8 i)) #:hp 200.0 #:shield 150.0))
            (list (mk-u 2260 'observer 52.0 38.0 #:hp 40.0 #:shield 20.0 #:flying #t))))

  ;; 4a: 3-base, 10500f, 2 Colossi out, 220M/200G -> researches protoss-ground-weapons-2!
  (define rt-4a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4a
    (step-layer2-economy!
     rt-4a
     (mk-live-obs 'Protoss 'Terran 10500 #:minerals 220 #:gas 200 #:supply-used 90 #:supply-cap 134
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units (mk-p-units-col 2) #:ally-buildings p-bldgs-3b-forge
                  #:researched-upgrades '(warpgate warp-gate-research charge blink protoss-ground-weapons-1))))
  (check-true "L75-B4-4a-protoss-3base-10500f-2colossi-researches-weapons-2"
              (has-research? acts-4a 'protoss-ground-weapons-2)
              (fmt-fail rt-4a acts-4a))

  ;; 4b: 3-base, 10500f, 0 Colossi with ready RoboBay + 220M/200G -> protects Colossus #1/#2 escrow!
  (define rt-4b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-4b
    (step-layer2-economy!
     rt-4b
     (mk-live-obs 'Protoss 'Terran 10500 #:minerals 220 #:gas 200 #:supply-used 78 #:supply-cap 134
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units (mk-p-units-col 0) #:ally-buildings p-bldgs-3b-forge
                  #:researched-upgrades '(warpgate warp-gate-research charge blink protoss-ground-weapons-1))))
  (check-true "L75-B4-4b-protoss-3base-0colossi-still-protects-colossus-escrow"
              (not (has-research? acts-4b 'protoss-ground-weapons-2))
              (fmt-fail rt-4b acts-4b)))

;; -----------------------------------------------------------------------------
;; 5. L75-B5: Runtime `phoenix-cap` & Colossus Escrow vs Terran Ground
;; -----------------------------------------------------------------------------
(let ()
  (define (mk-p-sg-bldgs #:with-rb? [rb? #f])
    (append
     (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
           (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
           (mk-u 2003 'nexus 32.5 68.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
           (mk-u 2004 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
           (mk-u 2005 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
           (mk-u 2006 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2007 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
           (mk-u 2008 'cybernetics-core 48.0 34.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
           (mk-u 2009 'stargate 40.0 38.0 #:hp 600.0 #:shield 600.0 #:order-count 0)
           (mk-u 2010 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
           (mk-u 2020 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
           (mk-u 2021 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
           (mk-u 2022 'assimilator 58.5 36.5 #:hp 300.0 #:shield 300.0)
           (mk-u 2023 'assimilator 66.5 28.5 #:hp 300.0 #:shield 300.0))
     (if rb? (list (mk-u 2011 'robotics-bay 52.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)) '())))
  (define (mk-p-sg-units n-phx)
    (append (mk-workers 'probe 48 2100 20.0 20.0)
            (for/list ([i (in-range 8)]) (mk-u (+ 2200 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range n-phx)]) (mk-u (+ 2240 i) 'phoenix 52.0 (+ 36.0 (* 0.5 i)) #:hp 120.0 #:shield 60.0 #:flying #t))))
  (define (mk-t-bio-air n-banshee)
    (append
     (for/list ([i (in-range 15)]) (mk-u (+ 9500 i) 'marine 115.0 (+ 85.0 (* 0.4 i)) #:hp 45.0))
     (for/list ([i (in-range 4)]) (mk-u (+ 9550 i) 'medivac 117.0 (+ 85.0 (* 0.8 i)) #:hp 150.0 #:flying #t))
     (for/list ([i (in-range n-banshee)]) (mk-u (+ 9580 i) 'banshee 116.0 (+ 88.0 (* 0.8 i)) #:hp 140.0 #:flying #t))))

  ;; 5a: Terran 15 Marines + 4 Medivacs + 0 Banshees -> phoenix-cap = 0 (ZERO Phoenix trained!)
  (define rt-5a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-5a
    (step-layer2-economy!
     rt-5a
     (mk-live-obs 'Protoss 'Terran 9000 #:minerals 200 #:gas 150 #:supply-used 68 #:supply-cap 118
                  #:mineral-harvesters 36 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units (mk-p-sg-units 0) #:ally-buildings (mk-p-sg-bldgs)
                  #:enemy-units (mk-t-bio-air 0))))
  (check-true "L75-B5-5a-terran-ground-0-banshees-caps-phoenix-at-0"
              (not (has-train? acts-5a 'phoenix))
              (fmt-fail rt-5a acts-5a))

  ;; 5b: Terran 15 Marines + 4 Medivacs + 1 Banshee with 3 Phoenixes already -> capped <= 2..3 (NO 4th Phoenix!)
  (define rt-5b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-5b
    (step-layer2-economy!
     rt-5b
     (mk-live-obs 'Protoss 'Terran 9000 #:minerals 200 #:gas 150 #:supply-used 74 #:supply-cap 118
                  #:mineral-harvesters 36 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units (mk-p-sg-units 3) #:ally-buildings (mk-p-sg-bldgs)
                  #:enemy-units (mk-t-bio-air 1))))
  (check-true "L75-B5-5b-terran-ground-1-banshee-caps-phoenix-at-3-no-4th"
              (not (has-train? acts-5b 'phoenix))
              (fmt-fail rt-5b acts-5b))

  ;; 5c: Terran 15 Marines + 1 Banshee, 0 Phoenixes, ready RoboBay + 0 Colossi -> Colossus escrow blocks Phoenix!
  (define rt-5c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-5c
    (step-layer2-economy!
     rt-5c
     (mk-live-obs 'Protoss 'Terran 9000 #:minerals 200 #:gas 150 #:supply-used 68 #:supply-cap 118
                  #:mineral-harvesters 36 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units (mk-p-sg-units 0) #:ally-buildings (mk-p-sg-bldgs #:with-rb? #t)
                  #:enemy-units (mk-t-bio-air 1))))
  (check-true "L75-B5-5c-terran-ground-1-banshee-preserves-colossus-escrow-over-phoenix"
              (not (has-train? acts-5c 'phoenix))
              (fmt-fail rt-5c acts-5c)))

;; -----------------------------------------------------------------------------
;; 6. L76 Revert of L75-B6 Split-Pullback (`#2370` — Keep `OBRet == 0` &
;;    `zero_fire_retreat == 0`) + 8..14t Stalker Front-to-Back Screening
;; -----------------------------------------------------------------------------
(let ()
  (define z-home-bldgs
    (list (mk-u 3001 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 3002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 3003 'spawning-pool 36.0 34.0 #:hp 1000.0)))
  (define home-roaches-20
    (for/list ([i (in-range 20)])
      (mk-u (+ 3400 i) 'roach (+ 35.0 (* 0.4 (modulo i 5))) (+ 34.0 (* 0.4 (quotient i 5))) #:hp 145.0)))

  ;; 6a (Loop 76 Part 1 `#2370` revert): 4 Roaches at mid-map (90,90) facing 12 Stalkers at (102,90)
  ;;     while 20 Roaches sit at home (winning global army) -> commits via attack order instead of
  ;;     reverted Loop 75 B6 passive `'move` split-pullback!
  (define mid-roaches-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 3500 i) 'roach 90.0 (+ 89.0 (* 0.5 i)) #:hp 145.0)))
  (define stalkers-12-mid
    (for/list ([i (in-range 12)])
      (mk-u (+ 9600 i) 'stalker 102.0 (+ 87.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define rt-6a (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-6a
    (run-l34
     rt-6a
     (mk-live-obs 'Zerg 'Protoss 7200 #:minerals 100 #:gas 50 #:supply-used 72 #:supply-cap 100
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (append home-roaches-20 mid-roaches-4)
                  #:ally-buildings z-home-bldgs
                  #:enemy-units stalkers-12-mid)))
  (define r0-acts-6a (unit-acts acts-6a 3500))
  (define r0-commits-no-b6-split-6a?
    (and (ormap (lambda (a) (memq (car a) '(attack-unit attack-pos))) r0-acts-6a)
         (not (ormap (lambda (a) (eq? (car a) 'move)) r0-acts-6a))))
  (check-true "L76-REVERT-6a-midmap-4-roaches-winning-global-army-commits-no-b6-split-retreat"
              r0-commits-no-b6-split-6a?
              (format "r3500=~a" r0-acts-6a))

  ;; 6b: Identical 4 Roaches INSIDE owned base (38,34, <= 14t from TH) vs 12 Stalkers at (46,34) -> FIGHTS (`OBRet == 0`)!
  (define base-roaches-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 3510 i) 'roach 38.0 (+ 33.0 (* 0.5 i)) #:hp 145.0)))
  (define stalkers-12-base
    (for/list ([i (in-range 12)])
      (mk-u (+ 9650 i) 'stalker 46.0 (+ 31.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define rt-6b (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-6b
    (run-l34
     rt-6b
     (mk-live-obs 'Zerg 'Protoss 7200 #:minerals 100 #:gas 50 #:supply-used 72 #:supply-cap 100
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (append (for/list ([i (in-range 20)])
                                         (mk-u (+ 3450 i) 'roach 63.0 (+ 33.0 (* 0.2 i)) #:hp 145.0))
                                       base-roaches-4)
                  #:ally-buildings z-home-bldgs
                  #:enemy-units stalkers-12-base)))
  (define r0-acts-6b (unit-acts acts-6b 3510))
  (define r0-fights-home-6b?
    (and (ormap (lambda (a) (memq (car a) '(attack-unit attack-pos))) r0-acts-6b)
         (not (ormap (lambda (a) (eq? (car a) 'move)) r0-acts-6b))))
  (check-true "L75-B6-6b-owned-base-4-roaches-vs-12-stalkers-still-fights-obret-0"
              r0-fights-home-6b?
              (format "r3510=~a" r0-acts-6b))

  ;; 6c: Mid-map 4 Roaches ALREADY in weapon range (d=3.5t <= wr=4.0t) -> keeps firing (zero_fire_retreat == 0)!
  (define stalkers-12-inrange
    (for/list ([i (in-range 12)])
      (mk-u (+ 9680 i) 'stalker 93.5 (+ 87.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define rt-6c (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-6c
    (run-l34
     rt-6c
     (mk-live-obs 'Zerg 'Protoss 7200 #:minerals 100 #:gas 50 #:supply-used 72 #:supply-cap 100
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units (append home-roaches-20 mid-roaches-4)
                  #:ally-buildings z-home-bldgs
                  #:enemy-units stalkers-12-inrange)))
  (define r0-acts-6c (unit-acts acts-6c 3500))
  (define r0-fires-inrange-6c?
    (and (ormap (lambda (a) (memq (car a) '(attack-unit attack-pos))) r0-acts-6c)
         (not (ormap (lambda (a) (eq? (car a) 'move)) r0-acts-6c))))
  (check-true "L75-B6-6c-midmap-inrange-roaches-never-cancel-active-shot"
              r0-fires-inrange-6c?
              (format "r3500=~a" r0-acts-6c))

  ;; 6d: Protoss Stalker inverted ahead of Zealots at d=10.0t (inside 8..14t window, > wr+2.0=8.0t)
  ;;     vs Terran Marines (with Medivac overhead): front-to-back screening fires (`attack-pos` behind Zealots)!
  (define p-home-bldgs
    (list (mk-u 2001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 2002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 2003 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)))
  (define p-screen-units
    (list (mk-u 2601 'zealot 88.0 89.0 #:hp 100.0 #:shield 50.0)
          (mk-u 2602 'zealot 88.0 90.0 #:hp 100.0 #:shield 50.0)
          (mk-u 2603 'zealot 88.0 91.0 #:hp 100.0 #:shield 50.0)
          (mk-u 2604 'zealot 88.0 92.0 #:hp 100.0 #:shield 50.0)
          ;; Inverted Stalker at x=90.0 (2t ahead of Zealots at x=88.0), 10.0t from Marines at x=100.0!
          (mk-u 2610 'stalker 90.0 90.0 #:hp 80.0 #:shield 80.0)))
  (define t-marines-med
    (list (mk-u 9701 'marine 100.0 89.0 #:hp 45.0)
          (mk-u 9702 'marine 100.0 90.0 #:hp 45.0)
          (mk-u 9703 'marine 100.0 91.0 #:hp 45.0)
          (mk-u 9704 'marine 100.0 92.0 #:hp 45.0)))
  (define rt-6d (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-6d
    (run-l34
     rt-6d
     (mk-live-obs 'Protoss 'Terran 7200 #:minerals 100 #:gas 50 #:supply-used 40 #:supply-cap 78
                  #:mineral-harvesters 24 #:vespene-harvesters 0
                  #:expansion-locations exps-2
                  #:ally-units p-screen-units
                  #:ally-buildings p-home-bldgs
                  #:enemy-units t-marines-med)))
  (define st-acts-6d (unit-acts acts-6d 2610))
  (define st-screened-6d?
    (and (ormap (lambda (a)
                  (and (eq? (car a) 'attack-pos)
                       (>= (length a) 4)
                       (< (third a) 88.0)))
                st-acts-6d)
         #t))
  (check-true "L75-B6-6d-protoss-stalker-at-10t-screens-behind-zealots-via-attack-pos"
              st-screened-6d?
              (format "st2610=~a" st-acts-6d)))

(printf "=== Results: ~a/~a passed (~a failed) ===\n" tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
