#lang racket/base

(require racket/list
         racket/match
         "../lib/bot-runtime.rkt"
         "../lib/tactics/arena-minimax.rkt"
         "../lib/opponent-world-model.rkt"
         "../lib/mirror-mind-predictor.rkt")

;; =============================================================================
;; Loop 36 (`L36-P0-3`) Mirror-Brain Invariance, Focus-Fire & Prod Parity Suite
;; Covers:
;;   1. `arena-minimax.rkt` deterministic group-by-unit-type compression:
;;      0% tactic flips under unit-list reversal & permutation across 8 mixed clashes,
;;      plus 0% dropped distinct unit types (`#834` #1 ROI).
;;   2. `tbrain` priority focus-fire `(attack-unit uid eid)` wired into Terran/Protoss
;;      core units (`marine`/`marauder`/`stalker`/`adept`/`viking`/`void-ray`) while
;;      preserving stim/prismatic/blink/w11-tac-2 cloak safety (`#834` #3 ROI).
;;   3. Prod Anti-`DripFeed` parity staging (`>= 0.85x` value, cap `<= 65` sup) for
;;      Protoss Gateway-Robo balls (`>= 10`) & `>= 3` Sieged Tank lines (`#840`).
;;   4. TvP L2 (`widow-mine <= 2/3`, `factory #2` after `starport #1` + `Nat CC`,
;;      `>= 3` Vikings/Colossus), Protoss L2 (singleton `cybernetics-core` walking-Probe
;;      guard, continuous `PvZ` Robo + `<5:00` Stalkers, safe `robotics-bay`, `>= 6`
;;      anti-Banshee Stalkers), and `#31` Corruptors diving inside `6t` onto Tempests.
;;   5. `step-layer1c-mirror-mind!` forwarding `our-upgrade-tier` & OWM `workers-killed`.
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
              #:order-ability-id [oab 0]
              #:assigned-harvesters [ah 0] #:ideal-harvesters [ih 0])
  (hash 'id id 'type type 'x x 'y y
        'hp hp 'max-hp max-hp
        'shield shield 'shields shield 'max-shield max-shield 'max-shields max-shield
        'energy energy 'cloak cloak 'display-type 1
        'flying? flying? 'is-flying flying?
        'build-progress bp 'order-count oc 'order-ability-id oab
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

(define (rotate-list lst k)
  (define n (length lst))
  (if (<= n 1)
      lst
      (let ([r (modulo k n)])
        (append (drop lst r) (take lst r)))))

;; =============================================================================
;; TEST 1: Arena-Minimax Unit-Order Reversal & Permutation Invariance (`#834` #1)
;; =============================================================================
(let ()
  (define scenarios
    (list
     ;; 1. TvP Mixed Bio+Tank+Medivac+Viking vs Stalker+Zealot+Immortal+Colossus
     (list 'tvp-mixed
           (append (for/list ([i (in-range 8)]) (mk-u (+ 101 i) 'marine (+ 76.0 (* 0.5 i)) 80.0 #:hp 45.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 121 i) 'marauder (+ 77.0 (* 0.6 i)) 81.5 #:hp 125.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 131 i) 'siege-tank-sieged (+ 73.0 (* 1.5 i)) 79.0 #:hp 175.0))
                   (list (mk-u 141 'medivac 75.0 82.0 #:hp 150.0 #:flying? #t)
                         (mk-u 142 'viking-fighter 78.0 83.0 #:hp 135.0 #:flying? #t)))
           (append (for/list ([i (in-range 6)]) (mk-u (+ 501 i) 'stalker (+ 85.0 (* 0.6 i)) 80.0 #:hp 80.0 #:shield 80.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 521 i) 'zealot (+ 83.5 (* 0.5 i)) 80.5 #:hp 100.0 #:shield 50.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 531 i) 'immortal (+ 86.0 (* 1.0 i)) 81.0 #:hp 200.0 #:shield 100.0))
                   (list (mk-u 541 'colossus 87.5 80.0 #:hp 200.0 #:shield 150.0))))
     ;; 2. ZvP Roach+Hydra+Ravager+Corruptor vs Stalker+Immortal+Archon+Tempest
     (list 'zvp-mixed
           (append (for/list ([i (in-range 6)]) (mk-u (+ 101 i) 'roach (+ 77.0 (* 0.6 i)) 80.0 #:hp 145.0))
                   (for/list ([i (in-range 6)]) (mk-u (+ 121 i) 'hydralisk (+ 75.5 (* 0.6 i)) 81.0 #:hp 90.0))
                   (for/list ([i (in-range 3)]) (mk-u (+ 131 i) 'ravager (+ 76.5 (* 0.8 i)) 79.0 #:hp 120.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 141 i) 'corruptor (+ 78.0 (* 0.8 i)) 82.0 #:hp 200.0 #:flying? #t)))
           (append (for/list ([i (in-range 6)]) (mk-u (+ 501 i) 'stalker (+ 85.0 (* 0.6 i)) 80.0 #:hp 80.0 #:shield 80.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 521 i) 'immortal (+ 85.5 (* 1.0 i)) 81.0 #:hp 200.0 #:shield 100.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 531 i) 'archon (+ 84.5 (* 1.0 i)) 79.5 #:hp 10.0 #:shield 350.0))
                   (for/list ([i (in-range 3)]) (mk-u (+ 541 i) 'tempest (+ 89.0 (* 1.0 i)) 82.0 #:hp 200.0 #:shield 125.0 #:flying? #t))))
     ;; 3. TvZ Bio+Tank+Ghost vs Ling+Bane+Hydra+Ultra
     (list 'tvz-late
           (append (for/list ([i (in-range 8)]) (mk-u (+ 101 i) 'marine (+ 76.0 (* 0.5 i)) 80.0 #:hp 45.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 121 i) 'marauder (+ 77.0 (* 0.6 i)) 81.0 #:hp 125.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 131 i) 'siege-tank-sieged (+ 73.0 (* 1.5 i)) 79.0 #:hp 175.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 141 i) 'ghost (+ 75.0 (* 1.0 i)) 82.0 #:hp 100.0 #:energy 100.0)))
           (append (for/list ([i (in-range 10)]) (mk-u (+ 501 i) 'zergling (+ 84.0 (* 0.4 i)) 80.0 #:hp 35.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 521 i) 'baneling (+ 84.5 (* 0.5 i)) 81.0 #:hp 30.0))
                   (for/list ([i (in-range 6)]) (mk-u (+ 531 i) 'hydralisk (+ 86.0 (* 0.6 i)) 79.5 #:hp 90.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 541 i) 'ultralisk (+ 85.0 (* 1.5 i)) 80.5 #:hp 500.0))))
     ;; 4. PvP Mixed Gateway-Robo
     (list 'pvp-mixed
           (append (for/list ([i (in-range 7)]) (mk-u (+ 101 i) 'stalker (+ 77.0 (* 0.5 i)) 80.0 #:hp 80.0 #:shield 80.0))
                   (for/list ([i (in-range 3)]) (mk-u (+ 121 i) 'immortal (+ 76.0 (* 0.8 i)) 81.0 #:hp 200.0 #:shield 100.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 131 i) 'archon (+ 78.0 (* 1.0 i)) 79.5 #:hp 10.0 #:shield 350.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 141 i) 'zealot (+ 79.0 (* 0.5 i)) 80.5 #:hp 100.0 #:shield 50.0)))
           (append (for/list ([i (in-range 6)]) (mk-u (+ 501 i) 'stalker (+ 85.0 (* 0.5 i)) 80.0 #:hp 80.0 #:shield 80.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 521 i) 'immortal (+ 86.0 (* 0.8 i)) 81.0 #:hp 200.0 #:shield 100.0))
                   (for/list ([i (in-range 2)]) (mk-u (+ 531 i) 'colossus (+ 87.0 (* 1.0 i)) 80.0 #:hp 200.0 #:shield 150.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 541 i) 'zealot (+ 84.0 (* 0.5 i)) 80.5 #:hp 100.0 #:shield 50.0))))
     ;; 5. Homogeneous Stalkers vs Zerglings (`w7-tac-3` style!)
     (list 'stalker-vs-ling
           (for/list ([i (in-range 7)]) (mk-u (+ 101 i) 'stalker (+ 76.0 (* 0.5 i)) 80.0 #:hp 80.0 #:shield 80.0))
           (for/list ([i (in-range 14)]) (mk-u (+ 501 i) 'zergling (+ 83.0 (* 0.4 i)) (+ 78.0 (* 0.3 (modulo i 5))) #:hp 35.0)))
     ;; 6. Bio+Vikings vs Colossi+Stalkers
     (list 'bio-viking-vs-colossus
           (append (for/list ([i (in-range 10)]) (mk-u (+ 101 i) 'marine (+ 76.0 (* 0.5 i)) 80.0 #:hp 45.0))
                   (for/list ([i (in-range 6)]) (mk-u (+ 121 i) 'viking-fighter (+ 77.0 (* 0.7 i)) 82.0 #:hp 135.0 #:flying? #t)))
           (append (for/list ([i (in-range 3)]) (mk-u (+ 501 i) 'colossus (+ 85.0 (* 1.2 i)) 80.0 #:hp 200.0 #:shield 150.0))
                   (for/list ([i (in-range 6)]) (mk-u (+ 521 i) 'stalker (+ 84.0 (* 0.6 i)) 81.0 #:hp 80.0 #:shield 80.0))))
     ;; 7. Corruptors vs Tempests+Carriers
     (list 'corruptor-vs-skytoss
           (for/list ([i (in-range 10)]) (mk-u (+ 101 i) 'corruptor (+ 76.0 (* 0.6 i)) 80.0 #:hp 200.0 #:flying? #t))
           (append (for/list ([i (in-range 5)]) (mk-u (+ 501 i) 'tempest (+ 86.0 (* 1.0 i)) 80.0 #:hp 200.0 #:shield 125.0 #:flying? #t))
                   (for/list ([i (in-range 3)]) (mk-u (+ 521 i) 'carrier (+ 87.0 (* 1.2 i)) 82.0 #:hp 300.0 #:shield 150.0 #:flying? #t))))
     ;; 8. Hellions+Reapers vs Lings+Queens
     (list 'hellion-reaper-vs-zerg
           (append (for/list ([i (in-range 4)]) (mk-u (+ 101 i) 'hellion (+ 77.0 (* 0.6 i)) 80.0 #:hp 90.0))
                   (for/list ([i (in-range 4)]) (mk-u (+ 121 i) 'reaper (+ 78.0 (* 0.5 i)) 81.0 #:hp 60.0)))
           (append (for/list ([i (in-range 12)]) (mk-u (+ 501 i) 'zergling (+ 84.0 (* 0.4 i)) 80.0 #:hp 35.0))
                   (for/list ([i (in-range 3)]) (mk-u (+ 521 i) 'queen (+ 86.0 (* 1.0 i)) 81.0 #:hp 175.0))))))

  (define (extract-arena-decisions brain au eu)
    (define obs (hash 'frame 7200 'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
                      'ally-units au 'enemy-units eu 'enemy-buildings '()))
    (define-values (_acts _ctags decs) (step-tactical-mirror-brain! brain obs #:record-ledger? #f))
    (for/list ([d (in-list decs)])
      (list (hash-ref d 'committed-action #f)
            (hash-ref d 'predicted-enemy-action #f)
            (hash-ref d 'combined-value 0.0))))

  (define flips 0)
  (for ([sc (in-list scenarios)])
    (define nm (first sc))
    (define au (second sc))
    (define eu (third sc))
    (define d-fwd (extract-arena-decisions (make-tactical-mirror-brain) au eu))
    (define d-rev (extract-arena-decisions (make-tactical-mirror-brain) (reverse au) (reverse eu)))
    (define d-rot (extract-arena-decisions (make-tactical-mirror-brain) (rotate-list au 5) (rotate-list eu 7)))
    (unless (and (pair? d-fwd) (equal? d-fwd d-rev) (equal? d-fwd d-rot))
      (set! flips (add1 flips))
      (eprintf "  ORDER-FLIP [~a]: fwd=~a rev=~a rot=~a\n" nm d-fwd d-rev d-rot)))
  (check-true "L36-T1a-arena-minimax-order-reversal-and-rotation-zero-flips"
              (= flips 0)
              (format "Expected 0/8 order-dependent flips across mixed clashes, got ~a flips" flips))

  ;; T1b: Deterministic group-by-unit-type compression preserves ALL 5 distinct unit types
  ;; and produces bit-exact equal output under input reversal!
  (define mixed-5types
    (append (for/list ([i (in-range 10)]) (unit-hash->tactical-sim-unit (mk-u (+ 101 i) 'marine (+ 76.0 (* 0.5 i)) 80.0 #:hp 45.0) 'ally))
            (for/list ([i (in-range 4)]) (unit-hash->tactical-sim-unit (mk-u (+ 121 i) 'marauder (+ 77.0 (* 0.5 i)) 81.0 #:hp 125.0) 'ally))
            (for/list ([i (in-range 3)]) (unit-hash->tactical-sim-unit (mk-u (+ 131 i) 'siege-tank-sieged (+ 74.0 (* 1.0 i)) 79.0 #:hp 175.0) 'ally))
            (for/list ([i (in-range 2)]) (unit-hash->tactical-sim-unit (mk-u (+ 141 i) 'medivac (+ 75.0 (* 1.0 i)) 82.0 #:hp 150.0 #:flying? #t) 'ally))
            (list (unit-hash->tactical-sim-unit (mk-u 151 'ghost 76.0 81.5 #:hp 100.0 #:energy 100.0) 'ally))))
  (define comp-fwd (compress-arena-sim-units mixed-5types 3))
  (define comp-rev (compress-arena-sim-units (reverse mixed-5types) 3))
  (define comp-types (map tactical-sim-unit-type comp-fwd))
  (check-true "L36-T1b-compress-preserves-all-5-unit-types-and-is-bit-exact-invariant"
              (and (equal? comp-fwd comp-rev)
                   (= (length comp-types) 5)
                   (memq 'marine comp-types)
                   (memq 'marauder comp-types)
                   (memq 'siege-tank-sieged comp-types)
                   (memq 'medivac comp-types)
                   (memq 'ghost comp-types))
              (format "Expected all 5 unit types preserved & bit-exact equal; types=~a eq?=~a"
                      comp-types (equal? comp-fwd comp-rev))))

;; =============================================================================
;; TEST 2: `tbrain` Focus-Fire Targeting Wired into Core T/P Units (`#834` #3)
;; =============================================================================
(let ()
  ;; Marines + Void Ray with `tbrain` priority focus-fire target (`902`, low-HP high-threat)
  ;; while a closer healthy target (`901`) exists; also verify Stimpack & Prismatic Alignment
  ;; still fire AND undetected cloak=1 enemy (`903`) is NEVER targeted!
  (define rt2 (make-live-bot-runtime #:race 'Terran))
  (define obs2
    (mk-live-obs 'Terran 'Protoss 7200
                 #:supply-used 40 #:supply-cap 62
                 #:ally-units (append (for/list ([i (in-range 6)])
                                        (mk-u (+ 201 i) 'marine (+ 76.0 (* 0.3 i)) 80.0 #:hp 45.0))
                                      (list (mk-u 210 'marauder 76.5 81.0 #:hp 125.0)))
                 #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0))
                 #:enemy-units (list (mk-u 901 'zealot 80.0 80.0 #:hp 100.0 #:shield 50.0)
                                     (mk-u 902 'stalker 81.5 80.0 #:hp 12.0 #:max-hp 80.0 #:shield 0.0 #:max-shield 80.0)
                                     (mk-u 903 'dark-templar 79.0 80.0 #:hp 40.0 #:shield 80.0 #:cloak 1))
                 #:upgrades '(stimpack)))
  (define-values (acts2 _v2 _r2) (step-layer3-and-4-tactics! rt2 obs2 0.0))
  (define hit-902?
    (for/or ([a (in-list acts2)])
      (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
           (eqv? (cadr a) 201) (eqv? (caddr a) 902))))
  (define hit-cloaked-903?
    (for/or ([a (in-list acts2)])
      (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3) (eqv? (caddr a) 903))))
  (define stim-cast?
    (for/or ([a (in-list acts2)])
      (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (caddr a) 'stimpack))))
  (check-true "L36-T2a-tbrain-focus-fire-marine-targets-low-hp-keeps-stim-and-cloak-safety"
              (and hit-902? stim-cast? (not hit-cloaked-903?))
              (format "Expected Marine 201 focus-fire 902 + stimpack + no cloak 903; acts=~a" acts2))

  ;; Protoss Stalkers + Void Ray: focus-fire low-HP Armored target while still casting Prismatic Alignment!
  (define rt2p (make-live-bot-runtime #:race 'Protoss))
  (define obs2p
    (mk-live-obs 'Protoss 'Terran 7200
                 #:supply-used 40 #:supply-cap 62
                 #:ally-units (append (for/list ([i (in-range 5)])
                                        (mk-u (+ 301 i) 'stalker (+ 76.0 (* 0.4 i)) 80.0 #:hp 80.0 #:shield 80.0))
                                      (list (mk-u 310 'void-ray 76.5 81.0 #:hp 150.0 #:shield 100.0 #:flying? #t)))
                 #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
                 #:enemy-units (list (mk-u 911 'marauder 81.0 80.0 #:hp 125.0)
                                     (mk-u 912 'siege-tank 82.0 80.0 #:hp 18.0 #:max-hp 175.0))))
  (define-values (acts2p _v2p _r2p) (step-layer3-and-4-tactics! rt2p obs2p 0.0))
  (define vr-prismatic?
    (for/or ([a (in-list acts2p)])
      (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3)
           (eqv? (cadr a) 310) (eq? (caddr a) 'prismatic-alignment))))
  (define stalker-hit-912?
    (for/or ([a (in-list acts2p)])
      (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
           (eqv? (cadr a) 301) (eqv? (caddr a) 912))))
  (check-true "L36-T2b-tbrain-focus-fire-stalker-and-voidray-keeps-prismatic-alignment"
              (and vr-prismatic? stalker-hit-912?)
              (format "Expected Stalker 301 -> 912 & VoidRay 310 Prismatic Alignment; acts=~a" acts2p)))

;; =============================================================================
;; TEST 3: Prod Anti-`DripFeed` Parity Staging (`#840` Gateway-Robo & >=3 Tanks)
;; =============================================================================
(let ()
  (define base-bldgs-t
    (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0)
          (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0)))
  (define enemy-gw-robo-far
    (append (for/list ([i (in-range 8)]) (mk-u (+ 901 i) 'stalker (+ 126.0 (* 0.6 i)) 110.0 #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 921 i) 'immortal (+ 128.0 (* 1.0 i)) 111.0 #:hp 200.0 #:shield 100.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 931 i) 'colossus (+ 129.0 (* 1.2 i)) 112.0 #:hp 200.0 #:shield 150.0))))
  (define marines18
    (for/list ([i (in-range 18)]) (mk-u (+ 201 i) 'marine (+ 56.0 (* 0.4 (modulo i 6))) (+ 32.0 (* 0.4 (quotient i 6))) #:hp 45.0)))
  (define marines66
    (for/list ([i (in-range 66)]) (mk-u (+ 201 i) 'marine (+ 56.0 (* 0.3 (modulo i 11))) (+ 32.0 (* 0.3 (quotient i 11))) #:hp 45.0)))

  ;; T3a: 18 Marines (900 val, 18 sup) vs 12 Gateway-Robo units (~3,150 val) across the map -> MUST hold!
  (define rt3a (make-live-bot-runtime #:race 'Terran))
  (define-values (_a3a _v3a _r3a)
    (step-layer3-and-4-tactics!
     rt3a
     (mk-live-obs 'Terran 'Protoss 9600
                  #:supply-used 62 #:supply-cap 102
                  #:ally-units marines18
                  #:ally-buildings base-bldgs-t
                  #:enemy-units enemy-gw-robo-far)
     0.0))
  (check-true "L36-T3a-prod-parity-holds-underpowered-army-vs-12-gateway-robo-ball"
              (hash-ref (rt-door-state rt3a) 'l36-prod-parity-mass-hold? #f)
              "Expected l36-prod-parity-mass-hold? = #t against 12-unit Protoss Gateway-Robo ball")

  ;; T3b: 66 Marines (>= 65 supply cap & >= 0.85x value) -> MUST release (`#f`)!
  (define rt3b (make-live-bot-runtime #:race 'Terran))
  (define-values (_a3b _v3b _r3b)
    (step-layer3-and-4-tactics!
     rt3b
     (mk-live-obs 'Terran 'Protoss 11200
                  #:supply-used 110 #:supply-cap 150
                  #:ally-units marines66
                  #:ally-buildings base-bldgs-t
                  #:enemy-units enemy-gw-robo-far)
     0.0))
  (check-true "L36-T3b-prod-parity-releases-at-65plus-supply"
              (not (hash-ref (rt-door-state rt3b) 'l36-prod-parity-mass-hold? #f))
              "Expected l36-prod-parity-mass-hold? = #f once combat supply >= 65")

  ;; T3c: >= 3 Sieged Tanks + 10 Marines across the map vs 18 Marines -> MUST hold!
  (define enemy-3tanks-far
    (append (for/list ([i (in-range 3)]) (mk-u (+ 901 i) 'siege-tank-sieged (+ 128.0 (* 1.2 i)) 110.0 #:hp 175.0))
            (for/list ([i (in-range 10)]) (mk-u (+ 921 i) 'marine (+ 126.0 (* 0.5 i)) 109.0 #:hp 45.0))))
  (define rt3c (make-live-bot-runtime #:race 'Terran))
  (define-values (_a3c _v3c _r3c)
    (step-layer3-and-4-tactics!
     rt3c
     (mk-live-obs 'Terran 'Terran 9600
                  #:supply-used 62 #:supply-cap 102
                  #:ally-units marines18
                  #:ally-buildings base-bldgs-t
                  #:enemy-units enemy-3tanks-far)
     0.0))
  (check-true "L36-T3c-prod-parity-holds-against-3-sieged-tank-line"
              (and (hash-ref (rt-door-state rt3c) 'l35-siege-tempest-mass-hold? #f)
                   (hash-ref (rt-door-state rt3c) 'l36-prod-parity-mass-hold? #f))
              "Expected >= 3 Sieged Tank line to activate L35/L36 mass staging hold")

  ;; T3d: Home defense (`enemy-within-14-of-th?`) vs Gateway-Robo ball -> MUST NOT hold!
  (define enemy-gw-robo-at-nat
    (append (for/list ([i (in-range 8)]) (mk-u (+ 901 i) 'stalker (+ 64.0 (* 0.5 i)) 32.5 #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 921 i) 'immortal (+ 65.0 (* 1.0 i)) 33.5 #:hp 200.0 #:shield 100.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 931 i) 'colossus (+ 66.0 (* 1.0 i)) 32.5 #:hp 200.0 #:shield 150.0))))
  (define rt3d (make-live-bot-runtime #:race 'Terran))
  (define-values (_a3d _v3d _r3d)
    (step-layer3-and-4-tactics!
     rt3d
     (mk-live-obs 'Terran 'Protoss 9600
                  #:supply-used 62 #:supply-cap 102
                  #:ally-units marines18
                  #:ally-buildings base-bldgs-t
                  #:enemy-units enemy-gw-robo-at-nat)
     0.0))
  (check-true "L36-T3d-prod-parity-never-holds-home-defense"
              (not (hash-ref (rt-door-state rt3d) 'l36-prod-parity-mass-hold? #f))
              "Home defense must NEVER be held by l36-prod-parity-mass-hold?"))

;; =============================================================================
;; TEST 4: TvP / PvZ / PvT L2 Enforcement & `#31` Corruptor Dive vs Tempests
;; =============================================================================
(let ()
  (define scvs28 (for/list ([i (in-range 28)]) (mk-u (+ 101 i) 'scv 29.0 32.0 #:hp 45.0)))
  (define marines10 (for/list ([i (in-range 10)]) (mk-u (+ 151 i) 'marine 44.0 32.0 #:hp 45.0)))
  (define probes32 (for/list ([i (in-range 32)]) (mk-u (+ 101 i) 'probe 29.0 32.0 #:hp 20.0 #:shield 20.0)))

  ;; T4a (`#5138233` TvP Widow Mine cap <= 2 early / <= 3 midgame):
  (define rt4a (make-live-bot-runtime #:race 'Terran))
  (define acts4a
    (step-layer2-economy!
     rt4a
     (mk-live-obs 'Terran 'Protoss 4800
                  #:minerals 200 #:gas 100 #:supply-used 42 #:supply-cap 62
                  #:ally-units (append scvs28 marines10
                                       (list (mk-u 201 'widow-mine 45.0 32.0 #:hp 90.0)
                                             (mk-u 202 'widow-mine-burrowed 46.0 32.0 #:hp 90.0)))
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 12 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
                                         (mk-u 14 'factory 44.0 36.0 #:hp 1250.0)
                                         (mk-u 15 'starport 44.0 40.0 #:hp 1300.0 #:order-count 1))
                  #:enemy-units (list (mk-u 901 'stalker 110.0 80.0 #:hp 80.0 #:shield 80.0)))))
  (check-true "L36-T4a-tvp-caps-early-widow-mines-at-2"
              (not (has-train-sym? acts4a 'widow-mine))
              (format "TvP <5:30 with 2 Widow Mines must NOT train 3rd Widow Mine; acts=~a" acts4a))

  ;; T4b (`#5138231` TvP Factory #2 blocked before Starport #1):
  (define rt4b (make-live-bot-runtime #:race 'Terran))
  (define acts4b
    (step-layer2-economy!
     rt4b
     (mk-live-obs 'Terran 'Protoss 5600
                  #:minerals 350 #:gas 200 #:supply-used 52 #:supply-cap 70
                  #:ally-units (append scvs28 marines10)
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 12 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
                                         (mk-u 14 'factory 44.0 36.0 #:hp 1250.0 #:order-count 1))
                  #:enemy-units (list (mk-u 901 'stalker 110.0 80.0 #:hp 80.0 #:shield 80.0)))))
  (check-true "L36-T4b-tvp-blocks-factory2-until-starport1-started"
              (and (has-build-sym? acts4b 'starport)
                   (not (has-build-sym? acts4b 'factory)))
              (format "TvP must build Starport #1 before Factory #2; acts=~a" acts4b))

  ;; T4c (`#5138231` TvP >= 3 Vikings per observed Colossus ahead of Medivac):
  (define rt4c (make-live-bot-runtime #:race 'Terran))
  (define acts4c
    (step-layer2-economy!
     rt4c
     (mk-live-obs 'Terran 'Protoss 9000
                  #:minerals 180 #:gas 125 #:supply-used 58 #:supply-cap 86
                  #:ally-units (append scvs28 marines10
                                       (list (mk-u 201 'viking-fighter 45.0 32.0 #:hp 135.0 #:flying? #t)))
                  #:ally-buildings (list (mk-u 10 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'orbital-command 56.5 32.5 #:hp 1500.0 #:energy 20.0 #:assigned-harvesters 12 #:ideal-harvesters 16)
                                         (mk-u 12 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 13 'barracks 41.0 32.0 #:hp 1000.0 #:order-count 1)
                                         (mk-u 14 'factory 44.0 36.0 #:hp 1250.0 #:order-count 1)
                                         (mk-u 15 'starport 44.0 40.0 #:hp 1300.0))
                  #:enemy-units (list (mk-u 901 'colossus 110.0 80.0 #:hp 200.0 #:shield 150.0)
                                      (mk-u 902 'colossus 112.0 80.0 #:hp 200.0 #:shield 150.0)))))
  (check-true "L36-T4c-tvp-trains-anti-colossus-vikings-ahead-of-medivac"
              (and (has-train-sym? acts4c 'viking)
                   (not (has-train-sym? acts4c 'medivac)))
              (format "Expected anti-Colossus Viking ahead of Medivac vs 2 Colossi; acts=~a" acts4c))

  ;; T4d (`#5138232` Singleton CyberCore guard when walking Probe carries ability 894):
  (define rt4d (make-live-bot-runtime #:race 'Protoss))
  (define acts4d
    (step-layer2-economy!
     rt4d
     (mk-live-obs 'Protoss 'Zerg 2400
                  #:minerals 220 #:gas 50 #:supply-used 22 #:supply-cap 31
                  #:ally-units (cons (mk-u 199 'probe 37.0 33.0 #:hp 20.0 #:shield 20.0 #:order-count 1 #:order-ability-id 894)
                                     (for/list ([i (in-range 19)]) (mk-u (+ 101 i) 'probe 29.0 32.0 #:hp 20.0 #:shield 20.0)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0)))))
  (check-true "L36-T4d-protoss-blocks-duplicate-cybercore-while-probe-walks-894"
              (not (has-build-sym? acts4d 'cybernetics-core))
              (format "Must NOT emit duplicate cybernetics-core while Probe carries 894; acts=~a" acts4d))

  ;; T4e (`#5138232` PvZ continuous Robo Immortal + early <5:00 ranged Stalker):
  (define rt4e (make-live-bot-runtime #:race 'Protoss))
  (define acts4e
    (step-layer2-economy!
     rt4e
     (mk-live-obs 'Protoss 'Zerg 4800
                  #:minerals 425 #:gas 175 #:supply-used 42 #:supply-cap 62
                  #:ally-units (append probes32
                                       (list (mk-u 201 'zealot 42.0 32.0 #:hp 100.0 #:shield 50.0)
                                             (mk-u 202 'observer 45.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 14 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0)
                                         (mk-u 15 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0)
                                         (mk-u 16 'assimilator 29.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                         (mk-u 17 'assimilator 35.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3))
                  #:upgrades '(warpgate)
                  #:enemy-units (for/list ([i (in-range 6)]) (mk-u (+ 901 i) 'roach 100.0 (+ 30.0 (* 0.8 i)) #:hp 145.0)))))
  (check-true "L36-T4e-protoss-pvz-pumps-continuous-immortal-and-early-stalker"
              (and (has-train-sym? acts4e 'immortal)
                   (has-train-sym? acts4e 'stalker))
              (format "Expected continuous PvZ Immortal + early Stalker <5:00; acts=~a" acts4e))

  ;; T4f (`H2H #04` safe Robotics Bay defense gate + `#5138236` >= 6 anti-Banshee Stalkers):
  (define rt4f (make-live-bot-runtime #:race 'Protoss))
  (define acts4f
    (step-layer2-economy!
     rt4f
     (mk-live-obs 'Protoss 'Terran 6200
                  #:minerals 225 #:gas 225 #:supply-used 52 #:supply-cap 70
                  #:ally-units (append (for/list ([i (in-range 42)]) (mk-u (+ 101 i) 'probe 29.0 32.0 #:hp 20.0 #:shield 20.0))
                                       (list (mk-u 201 'immortal 44.0 32.0 #:hp 200.0 #:shield 100.0)
                                             (mk-u 202 'stalker 44.5 32.0 #:hp 80.0 #:shield 80.0)
                                             (mk-u 203 'observer 45.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t)))
                  #:ally-buildings (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 11 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
                                         (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                                         (mk-u 14 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0)
                                         (mk-u 15 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
                                         (mk-u 16 'assimilator 29.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                                         (mk-u 17 'assimilator 35.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3))
                  #:upgrades '(warpgate)
                  #:enemy-units (list (mk-u 901 'marine 110.0 80.0 #:hp 45.0)))))
  (check-true "L36-T4f-protoss-gates-unsafe-robotics-bay-when-army-below-14"
              (not (has-build-sym? acts4f 'robotics-bay))
              (format "Must NOT drop unsafe robotics-bay with 6 army supply & 225M; acts=~a" acts4f))

  ;; T4g (`#31` Visual-QA Corruptor Dive inside 6t onto Tempests — zero cliff-edge parking!):
  (define rt4g (make-live-bot-runtime #:race 'Zerg))
  (define corruptors6
    (for/list ([i (in-range 6)])
      (mk-u (+ 301 i) 'corruptor 70.0 (+ 48.0 (* 0.8 i)) #:hp 200.0 #:flying? #t)))
  (define tempests8
    (for/list ([i (in-range 8)])
      (mk-u (+ 901 i) 'tempest (+ 83.0 (* 0.5 i)) (+ 48.0 (* 0.8 i)) #:hp 200.0 #:shield 125.0 #:flying? #t)))
  (define-values (acts4g _v4g _r4g)
    (step-layer3-and-4-tactics!
     rt4g
     (mk-live-obs 'Zerg 'Protoss 12000
                  #:supply-used 72 #:supply-cap 110
                  #:ally-units corruptors6
                  #:ally-buildings (list (mk-u 10 'hive 32.5 32.5 #:hp 2500.0)
                                         (mk-u 11 'hatchery 56.5 32.5 #:hp 1500.0))
                  #:enemy-units tempests8)
     0.0))
  (define all-6-corruptors-dive?
    (for/and ([cid (in-range 301 307)])
      (for/or ([a (in-list acts4g)])
        (and (pair? a) (eq? (car a) 'attack-unit) (>= (length a) 3)
             (eqv? (cadr a) cid)
             (>= (caddr a) 901) (<= (caddr a) 908)))))
  (check-true "L36-T4g-corruptors-dive-onto-tempests-at-13t-zero-cliff-parking"
              all-6-corruptors-dive?
              (format "Expected all 6 Corruptors at 13t to dive Tempests via attack-unit; acts=~a" acts4g)))

;; =============================================================================
;; TEST 5: `step-layer1c-mirror-mind!` Forwards `our-upgrade-tier` & OWM `workers-killed`
;; =============================================================================
(let ()
  (define rt5 (make-live-bot-runtime #:race 'Terran))
  ;; Seed OWM with 4 enemy worker kills (`workers-killed = 4`):
  (define owm (rt-opponent-world-model rt5))
  (set-opponent-world-model-workers-killed! owm 4)
  (step-opponent-world-model!
   owm
   (mk-live-obs 'Terran 'Protoss 6000
                #:ally-units (list (mk-u 101 'marine 40.0 32.0 #:hp 45.0))
                #:enemy-units (list (mk-u 901 'stalker 110.0 80.0 #:hp 80.0 #:shield 80.0))))
  (define mm-obs
    (mk-live-obs 'Terran 'Protoss 6000
                 #:ally-units (list (mk-u 101 'marine 40.0 32.0 #:hp 45.0))
                 #:enemy-units (list (mk-u 901 'stalker 110.0 80.0 #:hp 80.0 #:shield 80.0))
                 #:upgrades '(terran-infantry-weapons-2 terran-infantry-armor-2)))
  (define mm-res (step-layer1c-mirror-mind! rt5 mm-obs))
  (check-true "L36-T5-step-layer1c-mirror-mind-clean-with-our-upgrade-tier-and-owm-workers-killed"
              (and (list? mm-res)
                   (= (opponent-world-summary-workers-killed (opponent-world-model-last-summary owm)) 4))
              (format "Expected clean step-layer1c-mirror-mind! with OWM workers-killed=4; res=~a" mm-res)))

(printf "L36-RUNTIME-MIRROR-TESTS: ~a/~a PASSED (~a failed)\n"
        (- total-checks failed-checks)
        total-checks
        failed-checks)
(when (> failed-checks 0)
  (exit 1))
