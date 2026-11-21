#lang racket/base

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         (prefix-in combat: "../lib/sc2-combat-eval.rkt")
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/tactics/unit-mode-micro.rkt")

;; =============================================================================
;; Loop 43 (`L43-P0-1a..1d`) Tactics + Live-Runtime Regression Suite
;; Covers:
;;   1. `L43-P0-1a` (`p15` Detection-First Priority Inversion + 3-Race Detector Snipe):
;;      - Static detectors (`missile-turret`/`photon-cannon`/`spore-crawler`) `<= 20t`
;;        take Priority 1 BEFORE `planetary-fortress`, splitting N & S DT wings onto
;;        BOTH turrets simultaneously (`< 0.25s` kill -> permanent cloak -> PF sweep!)
;;      - SP under-fire early blink triggers on `>= 1` damaged ready DT
;;      - General 3-race Detector-First targeting (`sc2-combat-eval` + `bot-runtime`)
;;   2. `L43-P0-1b` (Stalker Blink-Back & Coordinated Blink-Forward HV Snipe):
;;      - Injured Stalker (`shields < 25` OR `hull-hp < 55%`) blinks `5.5t` behind healthy allies
;;      - `>= 5` Blink-ready Stalkers blink into Sieged Tank `1.75t` dead-zone / under Colossi
;;   3. `L43-P0-1c` (Widow Mine Offense/Defense, Runby Worker Focus, Stasis Harass/Defuse):
;;      - Burrowed Widow Mine targets densest worker-cluster center (ignores Nexus/edge worker)
;;      - Widow Mine drop defense pulls ONLY 1 targeted/closest worker away + scatters neighbors `> 2.2t`
;;      - Runby raiders prioritize workers over structures; Adepts focus hurt workers; Hellions line up rows
;;      - Oracle plants mineral-line Stasis Ward; detected trap sniped at range; undetected defused by 1 cheap unit
;;   4. `L43-P0-1d` (Carried `#967` P0s):
;;      - `r02`/`r05`/`r06` `+2` overkill buffer, Pass-1 `<= 2.4t` wounded finish, zero `use-converge-drill?`
;;      - `e03` Marine EHP focus + outrange stutter-step + SCV `16f` bounce throttle
;;      - `e04` 6-Probe surround on first Zealot hit, `r01` Observer `+1.5t` behind Stalkers, `z16` `< 6` Muta box
;;      - `H2H #02 TvT` Tank+Viking parity guard (`l43-tvt-tank-viking-parity-hold?`)
;; =============================================================================

(define pass-cnt 0)
(define fail-cnt 0)

(define (check-true name cond-val [detail ""])
  (if cond-val
      (begin (set! pass-cnt (add1 pass-cnt))
             (printf "[PASS] ~a\n" name))
      (begin (set! fail-cnt (add1 fail-cnt))
             (eprintf "[FAIL] ~a: ~a\n" name detail))))

(define (dist2d-t x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (run-l34 rt obs)
  (let-values ([(acts _p _t) (step-layer3-and-4-tactics! rt obs 0.5)])
    acts))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0] #:cloak [cloak 3]
              #:flying? [flying? #f] #:burrowed? [burrowed? #f]
              #:cloaked? [cloaked? #f]
              #:build-progress [bp 1.0] #:order-count [oc 0]
              #:order-ability-id [oab 0] #:orders [orders '()]
              #:weapon-cooldown [wcd 0.0]
              #:engaged-target-tag [ett 0]
              #:assigned-harvesters [ah 0] #:ideal-harvesters [ih 0])
  (hash 'id id 'type type 'x x 'y y
        'hp hp 'max-hp max-hp
        'shield shield 'shields shield 'max-shield max-shield 'max-shields max-shield
        'energy energy 'cloak cloak 'cloaked cloaked? 'display-type 1
        'flying? flying? 'is-flying flying?
        'burrowed? burrowed? 'burrowed burrowed? 'is-burrowed burrowed?
        'build-progress bp 'order-count oc 'order-ability-id oab 'orders orders
        'weapon-cooldown wcd 'engaged-target-tag ett 'powered? #t
        'assigned-harvesters ah 'ideal-harvesters ih))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200] #:gas [gas 100]
                     #:supply-used [su 44] #:supply-cap [sc 70]
                     #:ally-units [au '()] #:ally-buildings [ab '()]
                     #:enemy-units [eu '()] #:enemy-buildings [eb '()]
                     #:mineral-patches [mps '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 58.5] #:nat-y [ny 34.5]
                     #:enemy-x [ex 140.0] #:enemy-y [ey 120.0]
                     #:researched-upgrades [upgs '()]
                     #:upgrades-tracked? [tracked? #t])
  (hash 'race race 'enemy-race enemy-race 'frame frame
        'live-obs? #t 'live-game? #t
        'mineral-harvesters 16 'gas-harvesters 0
        'minerals minerals 'gas gas
        'supply-used su 'supply-cap sc
        'ally-units au 'ally-buildings ab
        'enemy-units eu 'enemy-buildings eb
        'mineral-patches mps
        'base-x bx 'base-y by 'nat-x nx 'nat-y ny 'natural-x nx 'natural-y ny
        'enemy-x ex 'enemy-y ey
        'researched-upgrades upgs 'upgrades-tracked? tracked?
        'expansion-pads (list (cons nx ny) (cons 32.5 64.5) (cons 64.5 64.5))
        'map-width 176 'map-height 176))

(define main-mps
  (list (hash 'id 9001 'type 'mineral-field 'x 26.5 'y 27.5 'mineral-contents 1500)
        (hash 'id 9002 'type 'mineral-field 'x 25.8 'y 29.0 'mineral-contents 1500)
        (hash 'id 9003 'type 'mineral-field 'x 25.5 'y 30.8 'mineral-contents 1500)
        (hash 'id 9004 'type 'mineral-field 'x 25.5 'y 32.5 'mineral-contents 1500)
        (hash 'id 9005 'type 'mineral-field 'x 25.5 'y 34.2 'mineral-contents 1500)
        (hash 'id 9006 'type 'mineral-field 'x 25.8 'y 36.0 'mineral-contents 1500)
        (hash 'id 9007 'type 'mineral-field 'x 26.8 'y 37.5 'mineral-contents 1500)
        (hash 'id 9008 'type 'mineral-field 'x 28.5 'y 38.5 'mineral-contents 1500)))

;; =============================================================================
;; 1. L43-P0-1a: `p15` Detection-First Priority Inversion + 3-Race Detector Snipe
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 88.0)
  (define pf-bldg (mk-u 9001 'planetary-fortress (+ cx 3.5) cy #:hp 1500.0))
  (define south-turret (mk-u 9002 'missile-turret (+ cx 6.5) (- cy 2.8) #:hp 250.0))
  (define north-turret (mk-u 9003 'missile-turret (+ cx 6.5) (+ cy 2.8) #:hp 250.0))
  (define turrets (list south-turret north-turret))
  (define p15-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 9100 i) 'hellbat (- cx 1.2) (+ cy (* 0.4 (- i 2.5))) #:hp 135.0))
     (for/list ([i (in-range 8)]) (mk-u (+ 9120 i) 'marauder (- cx 0.5) (+ cy (* 0.35 (- i 3.5))) #:hp 125.0))
     (for/list ([i (in-range 24)]) (mk-u (+ 9200 i) 'marine (+ cx 0.2) (+ cy (* 0.25 (- i 11.5))) #:hp 55.0))
     (for/list ([i (in-range 6)]) (mk-u (+ 9300 i) 'siege-tank-sieged (+ cx 5.0) (+ cy (if (< i 3) -4.5 4.5)) #:hp 175.0))))

  ;; T1a: BOTH PF and BOTH Turrets alive!
  ;; (i) At spawn (`x = cx - 7.2`): ALL 27 DTs emit cloaked flank `move (16)` (0 premature blinks!)
  ;; (ii) On cloaked N/S launch flanks (`x = cx - 0.5, y = cy +- 6.0`, `<= 7.65t` from Turrets):
  ;;      ALL 27 DTs split into South & North wings and blink SIMULTANEOUSLY onto BOTH turrets!
  (define spawn-dts-27
    (append
     (for/list ([i (in-range 14)]) (mk-u (+ 1001 i) 'dark-templar (- cx 7.2) (- cy 1.5) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 13)]) (mk-u (+ 1020 i) 'dark-templar (- cx 7.2) (+ cy 1.5) #:hp 40.0 #:shield 80.0))))
  (define rt-p15 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-spawn
    (run-l34 rt-p15
             (mk-live-obs 'Protoss 'Terran 600
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units spawn-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-stride))))
  (define spawn-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move))) acts-spawn))
  (define spawn-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-spawn))
  (define flank-dts-27
    (append
     (for/list ([i (in-range 14)]) (mk-u (+ 1001 i) 'dark-templar (- cx 0.2) (- cy 5.8) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 13)]) (mk-u (+ 1020 i) 'dark-templar (- cx 0.2) (+ cy 5.8) #:hp 40.0 #:shield 80.0))))
  (define acts-flank
    (run-l34 rt-p15
             (mk-live-obs 'Protoss 'Terran 620
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units flank-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-stride))))
  (define flank-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-flank))
  (define near-south-cnt
    (count (lambda (b) (<= (dist2d-t (fourth b) (fifth b) (+ cx 6.5) (- cy 2.8)) 2.3)) flank-blinks))
  (define near-north-cnt
    (count (lambda (b) (<= (dist2d-t (fourth b) (fifth b) (+ cx 6.5) (+ cy 2.8)) 2.3)) flank-blinks))
  (check-true "L43-T1a-p15-detection-first-cloaked-flank-and-simultaneous-dual-turret-blink"
              (and (= (length spawn-moves) 27) (null? spawn-blinks)
                   (= (length flank-blinks) 27)
                   (= near-south-cnt 14) (= near-north-cnt 13))
              (format "spawn moves=~a blinks=~a | flank blinks=~a south=~a north=~a"
                      (length spawn-moves) (length spawn-blinks) (length flank-blinks) near-south-cnt near-north-cnt))

  ;; T1b: Without ShadowStride (or on blink CD) while PF + BOTH Turrets alive -> South wing attacks
  ;; South Turret `9002` AND North wing attacks North Turret `9003` (0 on PF `9001` until turrets die!);
  ;; once turrets are dead -> ALL 27 immediately attack PF `9001`!
  (define rt-p15-noupg (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-det-focus
    (run-l34 rt-p15-noupg
             (mk-live-obs 'Protoss 'Terran 640
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units flank-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '())))
  (define atk-9002 (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (caddr a) 9002))) acts-det-focus))
  (define atk-9003 (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (caddr a) 9003))) acts-det-focus))
  (define atk-9001-pre (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (caddr a) 9001))) acts-det-focus))
  (define acts-pf-sweep
    (run-l34 rt-p15-noupg
             (mk-live-obs 'Protoss 'Terran 660
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units flank-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (list pf-bldg)
                          #:researched-upgrades '())))
  (define atk-9001-post (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (caddr a) 9001))) acts-pf-sweep))
  (check-true "L43-T1b-p15-both-turrets-focused-before-pf-then-pf-swept-once-turrets-die"
              (and (= atk-9002 14) (= atk-9003 13) (= atk-9001-pre 0) (= atk-9001-post 27))
              (format "pre: t9002=~a t9003=~a pf9001=~a | post-turrets pf9001=~a"
                      atk-9002 atk-9003 atk-9001-pre atk-9001-post))

  ;; T1c: SP under-fire early release triggers on EVEN `1` damaged ready DT (`>= 1`, `>= 30%` in range)!
  (define sp-1dmg-dts-27
    (append
     (for/list ([i (in-range 5)])
       (mk-u (+ 1101 i) 'dark-templar (- cx 0.2) (- cy 5.8)
             #:hp 40.0 #:max-hp 40.0 #:shield (if (= i 0) 20.0 80.0) #:max-shield 80.0))
     (for/list ([i (in-range 9)])
       (mk-u (+ 1106 i) 'dark-templar (- cx 7.0) (- cy 2.0) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 5)])
       (mk-u (+ 1120 i) 'dark-templar (- cx 0.2) (+ cy 5.8) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 8)])
       (mk-u (+ 1125 i) 'dark-templar (- cx 7.0) (+ cy 2.0) #:hp 40.0 #:shield 80.0))))
  (define rt-sp1 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-sp1
    (run-l34 rt-sp1
             (mk-live-obs 'Protoss 'Terran 610
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units sp-1dmg-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-stride))))
  (define sp1-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-sp1))
  (check-true "L43-T1c-p15-sp-single-damaged-dt-triggers-immediate-dual-turret-blink"
              (= (length sp1-blinks) 10)
              (format "Expected 10 immediate turret blinks when 1 DT damaged & 10/27 in range; got ~a" (length sp1-blinks)))

  ;; T1d: General 3-Race Detector-First Targeting (`sc2-combat-eval` + `bot-runtime`)
  ;;  - Terran Vikings + cloaked Banshees snipe enemy Observer before Stalker/Phoenix!
  ;;  - Zerg Hydras + burrowed Lurkers snipe enemy Photon Cannon / Observer before Zealot!
  (define t-viking (mk-u 1201 'viking-fighter 60.0 60.0 #:hp 135.0 #:flying? #t))
  (define t-banshee (mk-u 1202 'banshee 60.5 60.0 #:hp 140.0 #:flying? #t #:cloaked? #t #:cloak 2))
  (define p-obs (mk-u 1901 'observer 65.5 60.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
  (define p-phx (mk-u 1902 'phoenix 63.0 60.0 #:hp 120.0 #:shield 60.0 #:flying? #t))
  (define eval-v-tgt
    (combat:select-focus-fire-target t-viking (list p-phx p-obs) #:ally-units (list t-viking t-banshee)))
  (define rt-v-tgt
    (select-target-enemy-for-unit 60.0 60.0 (list p-phx p-obs) 'viking-fighter #t))
  (define z-hydra (mk-u 1210 'hydralisk 60.0 60.0 #:hp 90.0))
  (define z-lurker (mk-u 1211 'lurker-mp-burrowed 61.0 60.0 #:hp 200.0 #:burrowed? #t))
  (define p-zealot (mk-u 1911 'zealot 63.0 60.0 #:hp 100.0 #:shield 50.0))
  (define p-cannon (mk-u 1912 'photon-cannon 66.0 60.0 #:hp 150.0 #:shield 150.0))
  (define eval-z-tgt
    (combat:select-focus-fire-target z-hydra (list p-zealot p-cannon) #:ally-units (list z-hydra z-lurker)))
  (define rt-z-tgt
    (select-target-enemy-for-unit 60.0 60.0 (list p-zealot p-cannon) 'hydralisk #t))
  (check-true "L43-T1d-general-3race-detector-first-targeting-with-cloaked-or-burrowed-allies"
              (and (combat:ally-squad-has-stealth-unit? (list t-viking t-banshee))
                   (combat:ally-squad-has-stealth-unit? (list z-hydra z-lurker))
                   (= (hash-ref eval-v-tgt 'id) 1901)
                   (= (hash-ref rt-v-tgt 'id) 1901)
                   (= (hash-ref eval-z-tgt 'id) 1912)
                   (= (hash-ref rt-z-tgt 'id) 1912))
              (format "eval-v=~a rt-v=~a eval-z=~a rt-z=~a"
                      (and eval-v-tgt (hash-ref eval-v-tgt 'id))
                      (and rt-v-tgt (hash-ref rt-v-tgt 'id))
                      (and eval-z-tgt (hash-ref eval-z-tgt 'id))
                      (and rt-z-tgt (hash-ref rt-z-tgt 'id)))))

;; =============================================================================
;; 2. L43-P0-1b: Stalker Blink-Back & Coordinated Blink-Forward HV Snipe
;; =============================================================================
(let ()
  ;; T2a: Injured Stalker (`shields = 15 < 25`) blinks `5.5t` back behind healthy Stalkers!
  (define st-inj (mk-u 2001 'stalker 64.0 60.0 #:hp 80.0 #:max-hp 80.0 #:shield 15.0 #:max-shield 80.0))
  (define st-ok1 (mk-u 2002 'stalker 61.5 59.0 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))
  (define st-ok2 (mk-u 2003 'stalker 61.5 61.0 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))
  (define enemy-marines
    (for/list ([i (in-range 6)]) (mk-u (+ 2901 i) 'marine 70.0 (+ 58.5 (* 0.6 i)) #:hp 55.0)))
  (define sc (make-spell-claims))
  (define bb-dirs (plan-stalker-blink-micro (list st-inj st-ok1 st-ok2) enemy-marines sc 500 #:researched-upgrades '(blink)))
  (define bb-d (and (= (length bb-dirs) 1) (car bb-dirs)))
  (check-true "L43-T2a-injured-stalker-blinks-5.5t-back-behind-healthy-stalkers"
              (and bb-d
                   (= (spell-directive-caster-tag bb-d) 2001)
                   (eq? (spell-directive-pattern-name bb-d) 'stalker-blink-back)
                   (< (spell-directive-target-x bb-d) 60.0)
                   (>= (dist2d-t 64.0 60.0 (spell-directive-target-x bb-d) (spell-directive-target-y bb-d)) 4.5)
                   (<= (dist2d-t 64.0 60.0 (spell-directive-target-x bb-d) (spell-directive-target-y bb-d)) 6.5))
              (format "dirs=~a" bb-dirs))

  ;; T2b: Coordinated Blink-Forward Snipe — `6` Blink-ready Stalkers vs Sieged Tank at `8.5t`
  ;; blink directly into Tank's `<= 2.2t` dead-zone, and respect `157f` CD at `+20f`!
  (define stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 2101 i) 'stalker 60.0 (+ 58.0 (* 0.8 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define enemy-tank (list (mk-u 2950 'siege-tank-sieged 68.5 60.0 #:hp 175.0)
                           (mk-u 2951 'marine 67.0 59.0 #:hp 55.0)
                           (mk-u 2952 'marine 67.0 61.0 #:hp 55.0)))
  (define rt-sb (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-bf
    (run-l34 rt-sb
             (mk-live-obs 'Protoss 'Terran 800
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units stalkers-6 #:enemy-units enemy-tank
                          #:researched-upgrades '(blink))))
  (define bf-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'blink))) acts-bf))
  (define all-in-deadzone?
    (and (= (length bf-blinks) 6)
         (for/and ([b (in-list bf-blinks)])
           (<= (dist2d-t (fourth b) (fifth b) 68.5 60.0) 2.5))))
  (define acts-bf-cd
    (run-l34 rt-sb
             (mk-live-obs 'Protoss 'Terran 820
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units stalkers-6 #:enemy-units enemy-tank
                          #:researched-upgrades '(blink))))
  (define bf-cd-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'blink))) acts-bf-cd))
  (check-true "L43-T2b-6-stalkers-coordinated-blink-forward-into-tank-deadzone-with-cd"
              (and all-in-deadzone? (null? bf-cd-blinks))
              (format "blinks=~a deadzone?=~a cd-blinks=~a" (length bf-blinks) all-in-deadzone? (length bf-cd-blinks)))

  ;; T2c (Negative guard): `< 5` Stalkers (`4`) OR no `blink` upgrade does NOT blink-forward!
  (define bf-4 (plan-stalker-blink-micro (take stalkers-6 4) enemy-tank (make-spell-claims) 800 #:researched-upgrades '(blink)))
  (define bf-noupg (plan-stalker-blink-micro stalkers-6 enemy-tank (make-spell-claims) 800 #:researched-upgrades '()))
  (check-true "L43-T2c-below-5-stalkers-or-no-upgrade-does-not-blink-forward"
              (and (null? bf-4) (null? bf-noupg))
              (format "bf-4=~a bf-noupg=~a" (length bf-4) (length bf-noupg))))

;; =============================================================================
;; 3. L43-P0-1c: Widow Mine Offense/Defense, Runby Worker Focus, Stasis Harass/Defuse
;; =============================================================================
(let ()
  ;; T3a: Widow Mine Offense — burrowed Widow Mine targets Probe `#3903` at heart of 5-Probe cluster
  ;; (ignoring isolated Probe `#3910` and ignoring Nexus `#3920`)!
  (define my-wm (mk-u 3001 'widow-mine-burrowed 30.0 32.0 #:hp 90.0 #:burrowed? #t))
  (define enemy-mineral-line
    (list (mk-u 3920 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 3910 'probe 33.0 29.0 #:hp 20.0 #:shield 20.0) ;; isolated outer probe
          (mk-u 3901 'probe 27.0 31.2 #:hp 20.0 #:shield 20.0)
          (mk-u 3902 'probe 27.0 31.8 #:hp 20.0 #:shield 20.0)
          (mk-u 3903 'probe 27.0 32.2 #:hp 20.0 #:shield 20.0) ;; cluster center!
          (mk-u 3904 'probe 27.0 32.6 #:hp 20.0 #:shield 20.0)
          (mk-u 3905 'probe 27.0 33.1 #:hp 20.0 #:shield 20.0)))
  (define wm-tgt (select-widow-mine-cluster-target my-wm enemy-mineral-line))
  (define rt-wm-off (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define wm-acts
    (run-l34 rt-wm-off
             (mk-live-obs 'Terran 'Protoss 3200
                          #:base-x 140.0 #:base-y 120.0 #:nat-x 115.0 #:nat-y 115.0
                          #:ally-units (list my-wm)
                          #:enemy-units enemy-mineral-line)))
  (define wm-atk (findf (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 3001))) wm-acts))
  (check-true "L43-T3a-widow-mine-offense-targets-densest-worker-cluster-center"
              (and wm-tgt (memv (hash-ref wm-tgt 'id) '(3902 3903 3904))
                   wm-atk (memv (third wm-atk) '(3902 3903 3904)))
              (format "unit-mode tgt=~a runtime atk=~a" (and wm-tgt (hash-ref wm-tgt 'id)) wm-atk))

  ;; T3b: Widow Mine Defense — enemy burrowed Widow Mine in our mineral line targeting Probe `#3103`
  ;; pulls ONLY `#3103` AWAY from worker cluster via `move`, and scatters close neighbors `<= 2.6t`!
  (define my-nex (mk-u 3100 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define my-probes
    (list (mk-u 3101 'probe 26.8 30.2 #:hp 20.0 #:shield 20.0)
          (mk-u 3102 'probe 26.8 31.4 #:hp 20.0 #:shield 20.0)
          (mk-u 3103 'probe 27.2 32.0 #:hp 20.0 #:shield 20.0) ;; targeted by WM!
          (mk-u 3104 'probe 26.8 32.8 #:hp 20.0 #:shield 20.0)
          (mk-u 3105 'probe 26.8 34.0 #:hp 20.0 #:shield 20.0)
          (mk-u 3106 'probe 27.5 37.8 #:hp 20.0 #:shield 20.0))) ;; far safe probe!
  (define enemy-wm-drop (list (mk-u 3990 'widow-mine-burrowed 29.8 32.0 #:hp 90.0 #:burrowed? #t #:engaged-target-tag 3103)))
  (define rt-wm-def (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define wm-def-acts
    (step-layer2-economy!
     rt-wm-def
     (mk-live-obs 'Protoss 'Terran 3200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units my-probes #:ally-buildings (list my-nex)
                  #:enemy-units enemy-wm-drop #:mineral-patches main-mps)))
  (define sac-move (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 3103))) wm-def-acts))
  (define neighbor-scatters
    (filter (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk move)) (memv (second a) '(3101 3102 3104 3105))))
            wm-def-acts))
  (define far-untouched?
    (not (ormap (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk move)) (= (second a) 3106))) wm-def-acts)))
  (check-true "L43-T3b-widow-mine-drop-defense-pulls-single-targeted-worker-and-scatters-neighbors"
              (and sac-move (>= (length neighbor-scatters) 2) far-untouched?)
              (format "sac-move=~a scatters=~a far-untouched?=~a" sac-move (length neighbor-scatters) far-untouched?))

  ;; T3c: Runby Worker Focus — Adepts focus hurt worker over full worker & Nexus; Hellions aim down
  ;; lined-up worker row; Zerglings/Oracles prioritize workers over TownHall!
  (define runby-enemies
    (list (mk-u 3500 'command-center 32.5 32.5 #:hp 1500.0)
          (mk-u 3501 'scv 30.0 32.0 #:hp 45.0) ;; closer full-HP SCV
          (mk-u 3502 'scv 31.2 32.0 #:hp 20.0))) ;; slightly farther hurt SCV!
  (define adept-tgt (select-target-enemy-for-unit 28.0 32.0 runby-enemies 'adept #f))
  (define adept-eval-tgt (combat:select-focus-fire-target (mk-u 3600 'adept 28.0 32.0) runby-enemies))
  ;; Hellion flame line-up: isolated SCV `#3520` at `(28.0, 34.0)` (`2.0t` north) vs 4 lined-up SCVs
  ;; east at `(30.5, 32.0)`, `(31.5, 32.0)`, `(32.5, 32.0)`, `(33.5, 32.0)`!
  (define hellion-lineup-enemies
    (list (mk-u 3520 'scv 28.0 34.0 #:hp 45.0)
          (mk-u 3521 'scv 30.5 32.0 #:hp 45.0)
          (mk-u 3522 'scv 31.5 32.0 #:hp 45.0)
          (mk-u 3523 'scv 32.5 32.0 #:hp 45.0)
          (mk-u 3524 'scv 33.5 32.0 #:hp 45.0)))
  (define hellion-tgt (select-target-enemy-for-unit 28.0 32.0 hellion-lineup-enemies 'hellion #f))
  (check-true "L43-T3c-runby-adept-focuses-hurt-worker-and-hellion-aims-down-worker-lineup"
              (and (= (hash-ref adept-tgt 'id) 3502)
                   (= (hash-ref adept-eval-tgt 'id) 3502)
                   (memv (hash-ref hellion-tgt 'id) '(3521 3522 3523 3524)))
              (format "adept-rt=~a adept-eval=~a hellion-rt=~a"
                      (hash-ref adept-tgt 'id) (hash-ref adept-eval-tgt 'id) (hash-ref hellion-tgt 'id)))

  ;; T3d: Stasis Ward Harass (Oracle plants at enemy mineral line w/ `>= 50` energy) & Safe Defuse
  ;; (detected trap -> ranged snipe + melee pullback; undetected -> 1 cheap defuser + main pullback!)
  (define my-oracle (mk-u 3701 'oracle 29.0 32.0 #:hp 100.0 #:shield 20.0 #:energy 52.0 #:flying? #t))
  (define or-dirs
    (plan-protoss-spellcaster-micro
     (list my-oracle)
     (for/list ([i (in-range 5)]) (mk-u (+ 3710 i) 'scv 27.0 (+ 30.0 (* 0.8 i)) #:hp 45.0))
     #:claims (make-spell-claims) #:current-frame 4000))
  (define planted-stasis?
    (ormap (lambda (d) (and (eq? (spell-directive-ability d) 'stasis-ward)
                            (= (spell-directive-caster-tag d) 3701)))
           or-dirs))
  (define det-trap (list (mk-u 3800 'oracle-stasis-trap 60.0 60.0 #:hp 30.0 #:shield 30.0 #:cloak 2)))
  (define rt-stasis-det (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-st-det
    (run-l34 rt-stasis-det
             (mk-live-obs 'Protoss 'Protoss 4200
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units (list (mk-u 3801 'stalker 54.5 60.0 #:hp 80.0 #:shield 80.0)
                                             (mk-u 3802 'zealot 57.0 60.0 #:hp 100.0 #:shield 50.0)
                                             (mk-u 3803 'observer 55.0 61.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
                          #:enemy-units det-trap)))
  (define undet-trap (list (mk-u 3850 'oracle-stasis-trap 60.0 60.0 #:hp 30.0 #:shield 30.0 #:cloak 1 #:cloaked? #t)))
  (define rt-stasis-undet (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-st-undet
    (run-l34 rt-stasis-undet
             (mk-live-obs 'Zerg 'Protoss 4200
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units (list (mk-u 3851 'zergling 56.0 60.0 #:hp 20.0)
                                             (mk-u 3852 'roach 56.5 60.5 #:hp 145.0)
                                             (mk-u 3853 'roach 56.5 59.5 #:hp 145.0))
                          #:enemy-units undet-trap)))
  (check-true "L43-T3d-stasis-ward-mineral-harass-and-detected-or-sacrificial-defuse"
              (and planted-stasis?
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 3801) (= (third a) 3800))) acts-st-det)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 3802))) acts-st-det)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'trigger-stasis-ward-single-unit) (= (second a) 3851))) acts-st-undet)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 3852))) acts-st-undet))
              (format "planted?=~a det=~a undet=~a" planted-stasis? acts-st-det acts-st-undet)))

;; =============================================================================
;; 4. L43-P0-1d: Carried `#967` P0s (`r02/r05/r06`, `e03`, `e04`, `r01`, `z16`, `H2H #02 TvT`)
;; =============================================================================
(let ()
  ;; T4a (`r05` 16 SCVs vs 15 Probes): Zero `3666` disengage, ZERO `worker-drill-stack-attack`
  ;; (even with far SCVs > 6t away!), `+2` overkill buffer (`>= 4` SCVs focus a 10-HP Probe!),
  ;; and Pass-1 wounded `<= 2.4t` priority finishes a 15-HP Probe 2.1t away!
  (define main-cc (mk-u 4000 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16))
  (define scvs-16
    (cons (mk-u 4101 'scv 30.0 32.5 #:hp 45.0)
          (for/list ([i (in-range 1 16)])
            (mk-u (+ 4101 i) 'scv (+ 25.0 (* 0.4 (modulo i 5))) (+ 30.0 (* 0.8 (quotient i 5))) #:hp 45.0))))
  (define probes-15
    (append
     (list (mk-u 4901 'probe 32.1 32.5 #:hp 10.0 #:shield 0.0) ;; wounded 10-HP Probe 2.1t from #4101!
           (mk-u 4902 'probe 30.8 32.5 #:hp 20.0 #:shield 20.0)) ;; full-HP Probe 0.8t from #4101
     (for/list ([i (in-range 13)])
       (mk-u (+ 4903 i) 'probe (+ 32.5 (* 0.2 (modulo i 5))) (+ 31.2 (* 0.3 (quotient i 5))) #:hp 20.0 #:shield 20.0))))
  (define rt-r05 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-r05
    (step-layer2-economy!
     rt-r05
     (mk-live-obs 'Terran 'Protoss 1200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 15
                  #:ally-units scvs-16 #:ally-buildings (list main-cc)
                  #:enemy-units probes-15 #:mineral-patches main-mps)))
  (define r05-drills (filter (lambda (a) (and (pair? a) (eq? (car a) 'worker-drill-stack-attack))) acts-r05))
  (define r05-4901-grp (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 4901))) acts-r05))
  (define r05-4902-grp (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 4902))) acts-r05))
  ;; L48-W3 (Fix W3-R1): Zero converge drill; frontline #4101 swings immediately at adjacent #4902
  ;; (`0.8t <= 1.35t`, never walking 2.1t past it!) while `2..3` nearby SCVs finish 10-HP #4901!
  (check-true "L43-T4a-r05-zero-converge-drill-cap3-direct-contact-and-wounded-finish"
              (and (null? r05-drills)
                   r05-4901-grp
                   (>= (length (second r05-4901-grp)) 2)
                   (<= (length (second r05-4901-grp)) 3)
                   r05-4902-grp
                   (memv 4101 (second r05-4902-grp)))
              (format "drills=~a grp4901=~a grp4902=~a" (length r05-drills) r05-4901-grp r05-4902-grp))

  ;; T4b (`e03` Marine EHP focus + outrange stutter-step + SCV `16f` evac throttle):
  (define e03-scvs
    (list (mk-u 4201 'scv 28.0 32.0 #:hp 45.0 #:max-hp 45.0) ;; healthy close SCV
          (mk-u 4202 'scv 28.0 32.8 #:hp 20.0 #:max-hp 45.0))) ;; wounded SCV <= 24 HP
  (define e03-marines-ready (list (mk-u 4211 'marine 35.0 32.0 #:hp 45.0 #:weapon-cooldown 0.0)
                                  (mk-u 4212 'marine 35.0 33.0 #:hp 45.0 #:weapon-cooldown 0.0)))
  (define e03-marines-cd (list (mk-u 4211 'marine 35.0 32.0 #:hp 45.0 #:weapon-cooldown 0.35)
                               (mk-u 4212 'marine 35.0 33.0 #:hp 45.0 #:weapon-cooldown 0.35)))
  (define e03-adepts (list (mk-u 4921 'adept 31.8 31.5 #:hp 40.0 #:shield 0.0) ;; wounded 40 EHP!
                           (mk-u 4922 'adept 32.2 32.4 #:hp 70.0 #:shield 70.0) ;; closer full 140 EHP!
                           (mk-u 4923 'adept 32.5 33.5 #:hp 70.0 #:shield 70.0)))
  (define rt-e03 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-m-ready
    (run-l34 rt-e03 (mk-live-obs 'Terran 'Protoss 1200 #:supply-used 18 #:supply-cap 23
                                 #:ally-units (append e03-scvs e03-marines-ready)
                                 #:ally-buildings (list main-cc) #:enemy-units e03-adepts)))
  (define rt-e03-cd (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-m-cd
    (run-l34 rt-e03-cd (mk-live-obs 'Terran 'Protoss 1208 #:supply-used 18 #:supply-cap 23
                                    #:ally-units (append e03-scvs e03-marines-cd)
                                    #:ally-buildings (list main-cc) #:enemy-units e03-adepts)))
  (define rt-e03-l2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scv-f0 (step-layer2-economy! rt-e03-l2
                                       (mk-live-obs 'Terran 'Protoss 1200 #:supply-used 18 #:supply-cap 23
                                                    #:ally-units (append e03-scvs e03-marines-ready)
                                                    #:ally-buildings (list main-cc) #:enemy-units e03-adepts
                                                    #:mineral-patches main-mps)))
  (define scv-f8 (step-layer2-economy! rt-e03-l2
                                       (mk-live-obs 'Terran 'Protoss 1208 #:supply-used 18 #:supply-cap 23
                                                    #:ally-units (append e03-scvs e03-marines-ready)
                                                    #:ally-buildings (list main-cc) #:enemy-units e03-adepts
                                                    #:mineral-patches main-mps)))
  (check-true "L43-T4b-e03-marines-focus-lowest-ehp-adept-stutter-kite-and-scv-16f-throttle"
              (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 4211) (= (third a) 4921))) acts-m-ready)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 4212) (= (third a) 4921))) acts-m-ready)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 4211))) acts-m-cd)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) 4201))) scv-f0)
                   (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) 4201))) scv-f8))
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) 4202))) scv-f8))
              (format "ready=~a cd=~a scv-f8=~a" acts-m-ready acts-m-cd scv-f8))

  ;; T4c (`e04` 6-Probe surround on 1st Zealot hit + `r01` Observer `+1.5t` behind Stalkers + `z16` `< 6` Muta box):
  (define main-nex (mk-u 4500 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define probes-14 (for/list ([i (in-range 14)]) (mk-u (+ 4501 i) 'probe 28.5 (+ 28.0 (* 0.5 i)) #:hp 20.0 #:shield 20.0)))
  (define lings-6 (for/list ([i (in-range 6)]) (mk-u (+ 4551 i) 'zergling 34.0 (+ 31.0 (* 0.4 i)) #:hp 35.0)))
  (define zealot-hit (mk-u 4540 'zealot 33.5 32.0 #:hp 100.0 #:shield 35.0)) ;; 135 EHP < 145!
  (define rt-e04 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-e04
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1400 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons zealot-hit probes-14) #:ally-buildings (list main-nex)
                  #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define e04-pulled
    (append* (for/list ([a (in-list acts-e04)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a))))
  ;; `r01` Observer `+1.5t` behind Stalkers (Stalkers at x=31.0, Banshees at x=38.0 -> Observer anchors near x=29.5!)
  (define r01-stalkers (for/list ([i (in-range 9)]) (mk-u (+ 4601 i) 'stalker 31.0 (+ 30.5 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define r01-obs (mk-u 4650 'observer 34.5 32.5 #:hp 40.0 #:shield 20.0 #:flying? #t)) ;; currently out front!
  (define r01-banshees (for/list ([i (in-range 6)]) (mk-u (+ 4680 i) 'banshee 38.0 (+ 31.0 (* 0.5 i)) #:hp 140.0 #:flying? #t #:cloak 2)))
  (define rt-r01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-r01
    (run-l34 rt-r01
             (mk-live-obs 'Protoss 'Terran 1400 #:supply-used 31 #:supply-cap 39
                          #:ally-units (append r01-stalkers (list r01-obs)) #:ally-buildings (list main-nex)
                          #:enemy-units r01-banshees)))
  (define obs-move (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 4650))) acts-r01))
  ;; `z16` runtime with ONLY `3` surviving Mutas (`< 6`) still emits Magic-Box `hold-position (18)` at `3.7t`!
  (define rt-z16-3 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-z16-3
    (run-l34 rt-z16-3
             (mk-live-obs 'Zerg 'Terran 800
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units (list (mk-u 4701 'mutalisk 76.5 80.0 #:hp 120.0 #:flying? #t)
                                             (mk-u 4702 'mutalisk 80.0 83.5 #:hp 120.0 #:flying? #t)
                                             (mk-u 4703 'mutalisk 80.0 76.5 #:hp 120.0 #:flying? #t))
                          #:enemy-units (list (mk-u 4790 'thor 80.0 80.0 #:hp 400.0)))))
  (define z16-3-holds (count (lambda (a) (and (pair? a) (eq? (car a) 'hold-position))) acts-z16-3))
  (check-true "L43-T4c-e04-6probe-surround-r01-obs-behind-stalkers-and-z16-3muta-magicbox"
              (and (= (length e04-pulled) 6)
                   obs-move (< (third obs-move) 30.8)
                   (= z16-3-holds 3))
              (format "e04-pulled=~a obs-move=~a z16-3-holds=~a" (length e04-pulled) obs-move z16-3-holds))

  ;; T4d (`H2H #02 TvT` Tank+Viking Parity Guard): Bio+Medivac (`2` Tanks, `2` Vikings) vs `6` Tanks + `6` Vikings
  ;; across map -> holds (`l43-tvt-tank-viking-parity-hold? = #t`); reaching `4` Tanks + `5` Vikings releases!
  (define tvt-bldgs
    (list (mk-u 5001 'command-center 32.5 32.5 #:hp 1500.0)
          (mk-u 5002 'orbital-command 58.5 34.5 #:hp 1500.0)))
  (define tvt-under-army
    (append (for/list ([i (in-range 16)]) (mk-u (+ 5101 i) 'marine (+ 56.0 (* 0.3 i)) 38.0 #:hp 55.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 5120 i) 'siege-tank 56.0 (+ 36.0 i) #:hp 175.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 5130 i) 'viking-fighter 57.0 (+ 36.0 i) #:hp 135.0 #:flying? #t))
            (for/list ([i (in-range 4)]) (mk-u (+ 5140 i) 'medivac 55.0 (+ 36.0 i) #:hp 150.0 #:flying? #t))))
  (define tvt-parity-army
    (append tvt-under-army
            (list (mk-u 5122 'siege-tank 56.5 36.0 #:hp 175.0)
                  (mk-u 5123 'siege-tank 56.5 37.0 #:hp 175.0)
                  (mk-u 5132 'viking-fighter 57.5 36.0 #:hp 135.0 #:flying? #t)
                  (mk-u 5133 'viking-fighter 57.5 37.0 #:hp 135.0 #:flying? #t)
                  (mk-u 5134 'viking-fighter 57.5 38.0 #:hp 135.0 #:flying? #t))))
  (define enemy-tvt-wall
    (append (for/list ([i (in-range 6)]) (mk-u (+ 5901 i) 'siege-tank-sieged (+ 134.0 (* 1.0 i)) 118.0 #:hp 175.0))
            (for/list ([i (in-range 6)]) (mk-u (+ 5920 i) 'viking-fighter (+ 134.0 (* 0.8 i)) 120.0 #:hp 135.0 #:flying? #t))))
  (define rt-tvt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (void (run-l34 rt-tvt (mk-live-obs 'Terran 'Terran 9600 #:supply-used 90 #:supply-cap 120
                                     #:ally-units tvt-under-army #:ally-buildings tvt-bldgs
                                     #:enemy-units enemy-tvt-wall)))
  (define tvt-hold-under? (hash-ref (rt-door-state rt-tvt) 'l43-tvt-tank-viking-parity-hold? #f))
  (void (run-l34 rt-tvt (mk-live-obs 'Terran 'Terran 10200 #:supply-used 110 #:supply-cap 130
                                     #:ally-units tvt-parity-army #:ally-buildings tvt-bldgs
                                     #:enemy-units enemy-tvt-wall)))
  (define tvt-hold-parity? (hash-ref (rt-door-state rt-tvt) 'l43-tvt-tank-viking-parity-hold? #f))
  (check-true "L43-T4d-h2h-02-tvt-tank-viking-parity-hold-and-release"
              (and tvt-hold-under? (not tvt-hold-parity?))
              (format "hold-under?=~a hold-parity?=~a" tvt-hold-under? tvt-hold-parity?)))

(printf "\nL43 Tactics + Runtime Regression Summary: ~a passed, ~a failed\n" pass-cnt fail-cnt)
(unless (zero? fail-cnt)
  (exit 1))
