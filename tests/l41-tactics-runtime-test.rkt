#lang racket/base

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt")

;; =============================================================================
;; Loop 41 (`L41-P0-1a..1d`) Tactics + Live-Runtime Regression Suite
;; Covers:
;;   1. `L41-P0-1a` (`p15` Synchronized 20+-DT Alpha Strike):
;;      Lead 5 DTs HOLD on wide cloaked staging arc (0 premature blinks!) until
;;      >= 70% of ready DTs are within <= 7.65t of N/S/E PF rim slots -> ONE
;;      synchronized alpha-strike (plus 50% under-fire early release & Turret snipe)
;;   2. `L41-P0-1b` (`r02`/`r05` Pure Worker-Rush Latch):
;;      Once >= 10 pure enemy workers trigger `heavy-pure-worker-allin?`, latch
;;      stays active down to 3 Probes (0 `3685` repair in L2, L34 & pro-caster!),
;;      resets cleanly below 3 Probes, and preserves Siege Tank repair
;;   3. `L41-P0-1c` (`#75 PvP who` Home Observer Leash — `CloakLoss 1 -> 0/84`):
;;      Observer #1 reserved from `periodic-scout` (even when #2 is busy at front!),
;;      Warp Prism / DT at Natural Nexus pulls far mid-map Observer #1 (>55t!)
;;      directly over threatened Nexus instead of chasing mid-map Stalkers
;;   4. `L41-P0-1d` (`e02`/`e03`/`e04` Mineral-Defense Polish):
;;      - `e02` sole Queen skips `inject-larva (251)` under <=10t Reaper raid and
;;        shoots immediately; wounded Drones <= 28 HP slide while 40 HP mine
;;      - `e03` SCVs scatter across spatially separated safe patches (not 1 corner)
;;      - `e04` 17.5t early trigger, 6-Probe escalation when Zealot < 100 EHP,
;;        breach latch stays active down to 2 Lings (resets at 0), and lone far
;;        Zealot hugs back toward Nexus/Probes
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

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0] #:cloak [cloak 3]
              #:flying? [flying? #f] #:burrowed? [burrowed? #f]
              #:build-progress [bp 1.0] #:order-count [oc 0]
              #:order-ability-id [oab 0] #:orders [orders '()]
              #:weapon-cooldown [wcd 0.0]
              #:assigned-harvesters [ah 0] #:ideal-harvesters [ih 0])
  (hash 'id id 'type type 'x x 'y y
        'hp hp 'max-hp max-hp
        'shield shield 'shields shield 'max-shield max-shield 'max-shields max-shield
        'energy energy 'cloak cloak 'display-type 1
        'flying? flying? 'is-flying flying?
        'burrowed? burrowed? 'is-burrowed burrowed?
        'build-progress bp 'order-count oc 'order-ability-id oab 'orders orders
        'weapon-cooldown wcd 'powered? #t
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

(define (run-l34 rt obs)
  (let-values ([(acts _p _t) (step-layer3-and-4-tactics! rt obs 0.5)])
    acts))

(define main-mps
  ;; Realistic semicircular mineral arc around (32.5, 32.5) spanning 8+ tiles
  (list (hash 'id 9001 'type 'mineral-field 'x 26.5 'y 27.5 'mineral-contents 1500)
        (hash 'id 9002 'type 'mineral-field 'x 25.8 'y 29.0 'mineral-contents 1500)
        (hash 'id 9003 'type 'mineral-field 'x 25.5 'y 30.8 'mineral-contents 1500)
        (hash 'id 9004 'type 'mineral-field 'x 25.5 'y 32.5 'mineral-contents 1500)
        (hash 'id 9005 'type 'mineral-field 'x 25.5 'y 34.2 'mineral-contents 1500)
        (hash 'id 9006 'type 'mineral-field 'x 25.8 'y 36.0 'mineral-contents 1500)
        (hash 'id 9007 'type 'mineral-field 'x 26.8 'y 37.5 'mineral-contents 1500)
        (hash 'id 9008 'type 'mineral-field 'x 28.5 'y 38.5 'mineral-contents 1500)))

;; =============================================================================
;; 1. L41-P0-1a: `p15` Synchronized 20+-DT Alpha Strike
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 88.0)
  (define pf-bldg (mk-u 9001 'planetary-fortress (+ cx 3.5) cy #:hp 1500.0))
  (define turrets (list (mk-u 9002 'missile-turret (+ cx 6.5) (- cy 2.8) #:hp 250.0)
                        (mk-u 9003 'missile-turret (+ cx 6.5) (+ cy 2.8) #:hp 250.0)))
  (define p15-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 9100 i) 'hellbat (- cx 1.2) (+ cy (* 0.4 (- i 2.5))) #:hp 135.0))
     (for/list ([i (in-range 8)]) (mk-u (+ 9120 i) 'marauder (- cx 0.5) (+ cy (* 0.35 (- i 3.5))) #:hp 125.0))
     (for/list ([i (in-range 24)]) (mk-u (+ 9200 i) 'marine (+ cx 0.2) (+ cy (* 0.25 (- i 11.5))) #:hp 55.0))
     (for/list ([i (in-range 6)]) (mk-u (+ 9300 i) 'siege-tank-sieged (+ cx 5.0) (+ cy (if (< i 3) -4.5 4.5)) #:hp 175.0))))

  ;; T1a: 5 lead DTs reach blink range (`x = cx - 3.1, y = cy +- 3.0`, `<= 7.65t` of PF rim)
  ;; while 22 trailing DTs are still at `x = cx - 6.8` (`> 8.5t`) -> ZERO staggered blinks;
  ;; ALL 27 DTs hold on wide cloaked staging arc (`|wy - cy| >= 5.0`, clear of Hellbats/Marines)!
  (define staggered-dts-27
    (append
     (for/list ([i (in-range 3)])
       (mk-u (+ 1001 i) 'dark-templar (- cx 3.1) (- cy 5.2) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 11)])
       (mk-u (+ 1004 i) 'dark-templar (- cx 6.8) (- cy 2.0) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 2)])
       (mk-u (+ 1020 i) 'dark-templar (- cx 3.1) (+ cy 5.2) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 11)])
       (mk-u (+ 1022 i) 'dark-templar (- cx 6.8) (+ cy 2.0) #:hp 40.0 #:shield 80.0))))
  (define rt-p15 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-stag
    (run-l34 rt-p15
             (mk-live-obs 'Protoss 'Terran 600
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units staggered-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (list pf-bldg)
                          #:researched-upgrades '(shadow-stride))))
  (define stag-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-stag))
  (define stag-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move))) acts-stag))
  (define stag-wide-ok?
    (and (= (length stag-moves) 27)
         (for/and ([m (in-list stag-moves)])
           (>= (abs (- (fourth m) cy)) 5.0))))
  (check-true "L41-T1a-p15-staggered-lead-5-dts-hold-cloaked-staging-zero-premature-blink"
              (and (null? stag-blinks) stag-wide-ok?)
              (format "Expected 0 premature blinks & 27 wide staging moves (|dy|>=5.0); blinks=~a moves=~a sample=~a"
                      (length stag-blinks) (length stag-moves) (take stag-moves (min 3 (length stag-moves)))))

  ;; T1b: Once 19/27 (`>= 70%`) DTs reach `<= 7.65t` of their N/S/E PF rim slots while 8 trailing
  ;; DTs are still `> 8.5t` back -> ALL 19 ready DTs fire ONE synchronized `shadow-stride` alpha-strike
  ;; onto the N/S/E PF rim (`bx >= cx + 1.8`, `|by - cy| >= 2.4`), while the 8 trailing DTs keep moving!
  (define sync19-dts-27
    (append
     (for/list ([i (in-range 10)])
       (mk-u (+ 1001 i) 'dark-templar (- cx 3.1) (- cy 4.8) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 4)])
       (mk-u (+ 1011 i) 'dark-templar (- cx 6.8) (- cy 2.0) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 9)])
       (mk-u (+ 1020 i) 'dark-templar (- cx 3.1) (+ cy 4.8) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 4)])
       (mk-u (+ 1029 i) 'dark-templar (- cx 6.8) (+ cy 2.0) #:hp 40.0 #:shield 80.0))))
  (define acts-sync19
    (run-l34 rt-p15
             (mk-live-obs 'Protoss 'Terran 612
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units sync19-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (list pf-bldg)
                          #:researched-upgrades '(shadow-stride))))
  (define sync19-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-sync19))
  (define sync19-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move))) acts-sync19))
  (define sync19-rim-ok?
    (for/and ([b (in-list sync19-blinks)])
      (and (>= (fourth b) (+ cx 1.8))
           (>= (abs (- (fifth b) cy)) 2.4))))
  (check-true "L41-T1b-p15-70pct-19-in-range-fires-synchronized-alpha-strike"
              (and (= (length sync19-blinks) 19)
                   (= (length sync19-moves) 8)
                   sync19-rim-ok?)
              (format "Expected 19 synced blinks + 8 trailing moves; blinks=~a moves=~a rim-ok?=~a"
                      (length sync19-blinks) (length sync19-moves) sync19-rim-ok?))

  ;; T1c: Under-fire early release (`>= 50%` = 14 in range AND `>= 4` damaged ready DTs) releases
  ;; the alpha-strike cleanly instead of bleeding out!
  (define rt-p15-uf (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define underfire-dts-27
    (append
     (for/list ([i (in-range 7)])
       (mk-u (+ 1101 i) 'dark-templar (- cx 3.1) (- cy 4.8)
             #:hp 40.0 #:max-hp 40.0 #:shield (if (< i 4) 30.0 80.0) #:max-shield 80.0))
     (for/list ([i (in-range 7)])
       (mk-u (+ 1108 i) 'dark-templar (- cx 6.8) (- cy 2.0) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 7)])
       (mk-u (+ 1120 i) 'dark-templar (- cx 3.1) (+ cy 4.8) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 6)])
       (mk-u (+ 1127 i) 'dark-templar (- cx 6.8) (+ cy 2.0) #:hp 40.0 #:shield 80.0))))
  (define acts-uf
    (run-l34 rt-p15-uf
             (mk-live-obs 'Protoss 'Terran 620
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units underfire-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (list pf-bldg)
                          #:researched-upgrades '(shadow-stride))))
  (define uf-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-uf))
  (check-true "L41-T1c-p15-under-fire-50pct-early-release-fires-alpha-strike"
              (= (length uf-blinks) 14)
              (format "Expected 14 early-release blinks when 4 DTs damaged & 14/27 ready, got ~a" (length uf-blinks))))

;; =============================================================================
;; 2. L41-P0-1b: `r02`/`r05` Pure Worker-Rush Latch (`0` `3685` Relapse Below 10!)
;; =============================================================================
(let ()
  (define main-cc (mk-u 2000 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16))
  (define scvs-16-dmg
    (for/list ([i (in-range 16)])
      (mk-u (+ 2101 i) 'scv (+ 29.0 (* 0.35 (modulo i 4))) (+ 30.5 (* 0.5 (quotient i 4)))
            #:hp (if (< i 6) 24.0 45.0) #:max-hp 45.0)))
  (define (mk-probes n)
    (for/list ([i (in-range n)])
      (mk-u (+ 2901 i) 'probe (+ 30.5 (* 0.3 (modulo i 5))) (+ 31.0 (* 0.4 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  (define (has-repair? acts)
    (ormap (lambda (a)
             (and (pair? a)
                  (or (eq? (car a) 'repair)
                      (and (memq (car a) '(cast cast-spell))
                           (>= (length a) 3) (eq? (caddr a) 'repair)))))
           acts))
  (define rt-r05 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))

  ;; Tick 1 (f=100): 15 Probes arrive -> latches `heavy-pure-worker-allin?`
  (define obs-15 (mk-live-obs 'Terran 'Protoss 100 #:minerals 120 #:gas 0 #:supply-used 16 #:supply-cap 15
                              #:ally-units scvs-16-dmg #:ally-buildings (list main-cc)
                              #:enemy-units (mk-probes 15) #:mineral-patches main-mps))
  (define l2-15 (step-layer2-economy! rt-r05 obs-15))
  (define l34-15 (run-l34 rt-r05 obs-15))

  ;; Tick 2 (f=116): 6 Probes killed (9 < 10 remain!) -> latch HOLDS: 0 repair in L2 & L34!
  (define obs-9 (mk-live-obs 'Terran 'Protoss 116 #:minerals 120 #:gas 0 #:supply-used 16 #:supply-cap 15
                             #:ally-units scvs-16-dmg #:ally-buildings (list main-cc)
                             #:enemy-units (mk-probes 9) #:mineral-patches main-mps))
  (define l2-9 (step-layer2-economy! rt-r05 obs-9))
  (define l34-9 (run-l34 rt-r05 obs-9))

  ;; Tick 3 (f=132): Only 4 Probes remain (`< 6`!) -> latch STILL HOLDS: 0 repair in L2, L34 & pro-caster!
  (define obs-4 (mk-live-obs 'Terran 'Protoss 132 #:minerals 120 #:gas 0 #:supply-used 16 #:supply-cap 15
                             #:ally-units scvs-16-dmg #:ally-buildings (list main-cc)
                             #:enemy-units (mk-probes 4) #:mineral-patches main-mps))
  (define l2-4 (step-layer2-economy! rt-r05 obs-4))
  (define l34-4 (run-l34 rt-r05 obs-4))

  (check-true "L41-T2a-r05-latch-holds-zero-3685-repair-from-15-down-to-4-probes"
              (and (not (has-repair? l2-15)) (not (has-repair? l34-15))
                   (not (has-repair? l2-9))  (not (has-repair? l34-9))
                   (not (has-repair? l2-4))  (not (has-repair? l34-4)))
              (format "l2-9-rep?=~a l34-9-rep?=~a l2-4-rep?=~a l34-4-rep?=~a"
                      (has-repair? l2-9) (has-repair? l34-9) (has-repair? l2-4) (has-repair? l34-4)))

  ;; Tick 4 (f=148): Only 2 Probes remain (`< 3` -> latch resets!) + damaged Siege Tank -> SCV repairs Tank!
  (define dmg-tank (mk-u 2500 'siege-tank 35.0 32.5 #:hp 80.0 #:max-hp 175.0))
  (define obs-2 (mk-live-obs 'Terran 'Protoss 148 #:minerals 120 #:gas 0 #:supply-used 19 #:supply-cap 23
                             #:ally-units (cons dmg-tank scvs-16-dmg) #:ally-buildings (list main-cc)
                             #:enemy-units (mk-probes 2) #:mineral-patches main-mps))
  (void (step-layer2-economy! rt-r05 obs-2))
  (define l34-2 (run-l34 rt-r05 obs-2))
  (check-true "L41-T2b-r05-latch-resets-below-3-probes-and-preserves-siege-tank-repair"
              (ormap (lambda (a)
                       (and (pair? a) (eq? (car a) 'cast-spell)
                            (>= (length a) 4) (eq? (caddr a) 'repair) (= (fourth a) 2500)))
                     l34-2)
              (format "Expected SCV repair on Siege Tank 2500 once <3 probes remain; l34=~a" l34-2)))

;; =============================================================================
;; 3. L41-P0-1c: `#75 PvP who` Home Observer Leash (`CloakLoss 1 -> 0/84`)
;; =============================================================================
(let ()
  (define p-2base-bldgs
    (list (mk-u 3010 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 3011 'nexus 58.5 34.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 14 #:ideal-harvesters 16)
          (mk-u 3012 'robotics-facility 37.0 36.0 #:hp 450.0 #:shield 450.0)))
  (define probes-24
    (for/list ([i (in-range 24)])
      (mk-u (+ 3101 i) 'probe (if (< i 12) 28.5 54.5) (+ 30.0 (* 0.4 (modulo i 12)))
            #:hp 20.0 #:shield 20.0)))
  ;; Friendly Stalkers are OUT MID-MAP at (95, 95) while enemy DTs + Warp Prism drop our Natural Nexus!
  (define midmap-stalkers
    (for/list ([i (in-range 5)])
      (mk-u (+ 3201 i) 'stalker (+ 94.0 (* 0.5 i)) 95.0 #:hp 80.0 #:shield 80.0)))
  ;; Both Observers wandered far mid-map (`obs #1` at (85, 85) -> 57t from Natural Nexus!)
  (define obs1-far (mk-u 3301 'observer 85.0 85.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
  (define obs2-far (mk-u 3302 'observer 105.0 105.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
  (define dt-at-nat (mk-u 3901 'dark-templar 59.0 35.0 #:hp 40.0 #:shield 80.0 #:cloak 1))
  (define prism-at-nat (mk-u 3902 'warp-prism-phasing 61.0 37.0 #:hp 80.0 #:shield 100.0 #:flying? #t))

  ;; T3a: Enemy DT + Warp Prism at Natural Nexus pulls far mid-map Observer #1 (>55t away!)
  ;; DIRECTLY onto the Natural Nexus / DT (`(59, 35)`), NOT mid-map Stalkers `(95, 95)`!
  (define rt-m75 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-m75
    (mk-live-obs 'Protoss 'Protoss 5330 #:minerals 250 #:gas 120 #:supply-used 46 #:supply-cap 62
                 #:ally-units (append probes-24 midmap-stalkers (list obs1-far obs2-far))
                 #:ally-buildings p-2base-bldgs
                 #:enemy-units (list dt-at-nat prism-at-nat)))
  (define l2-m75 (step-layer2-economy! rt-m75 obs-m75))
  (define l34-m75 (run-l34 rt-m75 obs-m75))
  (define obs1-scouted?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'periodic-scout) (= (cadr a) 3301))) l2-m75))
  (define obs1-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (cadr a) 3301))) l34-m75))
  (check-true "L41-T3a-m75-dt-at-natural-pulls-far-midmap-observer1-home-not-midmap-stalkers"
              (and (not obs1-scouted?)
                   obs1-move
                   (<= (dist2d-t (third obs1-move) (fourth obs1-move) 59.0 35.0) 6.0))
              (format "obs1-scouted?=~a obs1-move=~a" obs1-scouted? obs1-move))

  ;; T3b: With 2 Observers & Observer #2 busy near frontline enemies (0 visible cloak yet, f=4660),
  ;; `periodic-scout` NEVER falls through to home Observer #1 AND PvP proactive home guard tethers #1 home!
  (define rt-m75b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs1-home (mk-u 3311 'observer 45.0 40.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
  (define obs2-front (mk-u 3312 'observer 100.0 100.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
  (define enemy-front-stalker (mk-u 3950 'stalker 105.0 102.0 #:hp 80.0 #:shield 80.0))
  (define obs-m75b
    (mk-live-obs 'Protoss 'Protoss 4660 #:minerals 250 #:gas 120 #:supply-used 46 #:supply-cap 62
                 #:ally-units (append probes-24 (list obs1-home obs2-front))
                 #:ally-buildings p-2base-bldgs
                 #:enemy-units (list enemy-front-stalker)))
  (define l2-m75b (step-layer2-economy! rt-m75b obs-m75b))
  (define l34-m75b (run-l34 rt-m75b obs-m75b))
  (define obs1b-scouted?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'periodic-scout) (= (cadr a) 3311))) l2-m75b))
  (define obs1b-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (cadr a) 3311))) l34-m75b))
  (check-true "L41-T3b-m75-two-observers-never-fall-through-to-home-observer1-and-tether-nat"
              (and (not obs1b-scouted?)
                   obs1b-move
                   (<= (dist2d-t (third obs1b-move) (fourth obs1b-move) 58.5 34.5) 6.0))
              (format "obs1b-scouted?=~a obs1b-move=~a" obs1b-scouted? obs1b-move))

  ;; T3c: Enemy `warp-prism-phasing` alone at 210s (f=4704, BEFORE DTs warp in!) pulls sole
  ;; Observer back from mid-map `(80, 75)` directly over the Warp Prism at Natural Nexus!
  (define rt-m75c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define sole-obs (mk-u 3321 'observer 80.0 75.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
  (define obs-m75c
    (mk-live-obs 'Protoss 'Protoss 4704 #:minerals 250 #:gas 120 #:supply-used 44 #:supply-cap 62
                 #:ally-units (append probes-24 (list sole-obs))
                 #:ally-buildings p-2base-bldgs
                 #:enemy-units (list prism-at-nat)))
  (define l2-m75c (step-layer2-economy! rt-m75c obs-m75c))
  (define l34-m75c (run-l34 rt-m75c obs-m75c))
  (define sole-scouted?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'periodic-scout) (= (cadr a) 3321))) l2-m75c))
  (define sole-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (cadr a) 3321))) l34-m75c))
  (check-true "L41-T3c-m75-warp-prism-alone-at-210s-anchors-observer-over-threatened-nexus"
              (and (not sole-scouted?)
                   sole-move
                   (<= (dist2d-t (third sole-move) (fourth sole-move) 61.0 37.0) 5.0))
              (format "sole-scouted?=~a sole-move=~a" sole-scouted? sole-move)))

;; =============================================================================
;; 4. L41-P0-1d: `e02` / `e03` / `e04` Mineral-Defense Polish
;; =============================================================================
(let ()
  ;; T4a (`e02` Queen Inject Guard): Sole Queen with 25e next to uninjected Hatchery under
  ;; <=10t Reaper raid skips `inject-larva (251)` and emits `(attack-unit queen reaper)`!
  (define main-hatch (mk-u 4000 'hatchery 32.5 32.5 #:hp 1500.0))
  (define drones-16-e02
    (for/list ([i (in-range 16)])
      (mk-u (+ 4101 i) 'drone 28.5 (+ 28.0 (* 0.6 i))
            #:hp (if (= i 0) 27.0 40.0) #:max-hp 40.0)))
  (define queen-25e (mk-u 4201 'queen 35.7 32.5 #:hp 175.0 #:energy 25.0))
  (define reapers-2 (list (mk-u 4901 'reaper 32.0 31.0 #:hp 60.0)
                          (mk-u 4902 'reaper 32.5 32.0 #:hp 60.0)))
  (define rt-e02 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define obs-e02
    (mk-live-obs 'Zerg 'Terran 1144 #:minerals 50 #:gas 0 #:supply-used 18 #:supply-cap 22
                 #:ally-units (cons queen-25e drones-16-e02)
                 #:ally-buildings (list main-hatch)
                 #:enemy-units reapers-2 #:mineral-patches main-mps))
  (define acts-e02-l2 (step-layer2-economy! rt-e02 obs-e02))
  (define acts-e02-l34 (run-l34 rt-e02 obs-e02))
  (define emitted-inject?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'inject-larva))) acts-e02-l2))
  (define queen-shoots?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 4201) (memv (third a) '(4901 4902))))
           acts-e02-l34))
  (check-true "L41-T4a-e02-queen-skips-inject-under-reaper-raid-and-shoots-immediately"
              (and (not emitted-inject?) queen-shoots?)
              (format "emitted-inject?=~a queen-shoots?=~a l2=~a" emitted-inject? queen-shoots? acts-e02-l2))

  ;; T4b (`e02` <= 28 HP wounded Drone evac): Drone #4101 at 27.0 HP slides via mineral-walk
  ;; while all 15 healthy 40.0 HP Drones stay mining (0 evac)!
  (define e02-mw-wids
    (remove-duplicates (for/list ([a (in-list acts-e02-l2)]
                                  #:when (and (pair? a) (eq? (car a) 'mineral-walk)))
                         (second a))))
  (check-true "L41-T4b-e02-wounded-drone-at-27hp-slides-while-40hp-drones-keep-mining"
              (equal? e02-mw-wids '(4101))
              (format "Expected only wounded Drone 4101 (27 HP) to slide; got ~a" e02-mw-wids))

  ;; T4c (`e03` Adept anti-clump scatter): 16 SCVs vs 3 Adepts inside mineral line scatter
  ;; across >= 2 spatially separated safe patches (`pairwise dist >= 3.0t`, 0 SCV attack pulls!)
  (define main-cc (mk-u 4500 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-16-e03
    (for/list ([i (in-range 16)])
      (mk-u (+ 4601 i) 'scv 27.5 (+ 28.0 (* 0.6 i)) #:hp 45.0 #:max-hp 45.0)))
  (define adepts-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 4951 i) 'adept 31.5 (+ 31.5 (* 0.5 i)) #:hp 70.0 #:shield 70.0)))
  (define rt-e03 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-e03
    (step-layer2-economy!
     rt-e03
     (mk-live-obs 'Terran 'Protoss 1400 #:minerals 150 #:gas 0 #:supply-used 18 #:supply-cap 23
                  #:ally-units (append scvs-16-e03 (list (mk-u 4701 'marine 31.0 30.0 #:hp 45.0)
                                                         (mk-u 4702 'marine 31.0 31.0 #:hp 45.0)))
                  #:ally-buildings (list main-cc)
                  #:enemy-units adepts-3 #:mineral-patches main-mps)))
  (define e03-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-e03))
  (define e03-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-e03))
  (define e03-pts (remove-duplicates (map (lambda (m) (cons (fourth m) (fifth m))) e03-mws)))
  (define max-patch-spread
    (for*/fold ([best 0.0]) ([p (in-list e03-pts)] [q (in-list e03-pts)])
      (max best (dist2d-t (car p) (cdr p) (car q) (cdr q)))))
  (check-true "L41-T4c-e03-adept-scatters-scvs-across-spatially-separated-patches"
              (and (null? e03-pulls)
                   (>= (length e03-mws) 6)
                   (for/and ([m (in-list e03-mws)]) (> (third m) 0))
                   (>= (length e03-pts) 2)
                   (>= max-patch-spread 3.0))
              (format "pulls=~a mws=~a distinct-pts=~a max-spread=~a"
                      (length e03-pulls) (length e03-mws) e03-pts max-patch-spread))

  ;; T4d (`e04` early 17.5t trigger + wounded Zealot 6-Probe escalation + breach latch down to 2 Lings -> 0 reset)
  (define main-nex (mk-u 5000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define probes-14-e04
    (for/list ([i (in-range 14)])
      (mk-u (+ 5101 i) 'probe 28.5 (+ 28.0 (* 0.6 i)) #:hp 20.0 #:shield 20.0)))
  (define lings-6-far
    (for/list ([i (in-range 6)])
      (mk-u (+ 5801 i) 'zergling 48.0 (+ 31.5 (* 0.4 i)) #:hp 35.0)))
  (define rt-e04 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  ;; Tick 1 (f=1400): 6 Lings at 15.5t (`<= 17.5t`) + full-HP Zealot -> pulls 5 Probes early & latches!
  (define acts-e04-t1
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1400 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons (mk-u 5201 'zealot 34.5 32.5 #:hp 100.0 #:shield 50.0) probes-14-e04)
                  #:ally-buildings (list main-nex)
                  #:enemy-units lings-6-far #:mineral-patches main-mps)))
  (define pull-t1 (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-e04-t1))
  ;; Tick 2 (f=1412): Lings close in & Zealot wounded (`75` EHP `< 100`) -> escalates to 6 Probes!
  (define lings-6-close
    (for/list ([i (in-range 6)])
      (mk-u (+ 5801 i) 'zergling 33.0 (+ 31.0 (* 0.4 i)) #:hp 35.0)))
  (define acts-e04-t2
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1412 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons (mk-u 5201 'zealot 34.0 32.0 #:hp 75.0 #:max-hp 100.0 #:shield 0.0 #:max-shield 50.0)
                                     probes-14-e04)
                  #:ally-buildings (list main-nex)
                  #:enemy-units lings-6-close #:mineral-patches main-mps)))
  (define pull-t2 (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-e04-t2))
  ;; Tick 3 (f=1424): 4 Lings die leaving ONLY `2` Lings (`< 4`!) inside mineral line -> latch HOLDS!
  (define lings-2-rem (take lings-6-close 2))
  (define acts-e04-t3
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1424 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units probes-14-e04
                  #:ally-buildings (list main-nex)
                  #:enemy-units lings-2-rem #:mineral-patches main-mps)))
  (define pull-t3 (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-e04-t3))
  ;; Tick 4 (f=1440): 0 Lings remain -> latch resets & defending Probes immediately return via harvest-mineral!
  (define acts-e04-t4
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1440 #:minerals 100 #:gas 0 #:supply-used 14 #:supply-cap 23
                  #:ally-units probes-14-e04
                  #:ally-buildings (list main-nex)
                  #:enemy-units '() #:mineral-patches main-mps)))
  (define ret-t4 (filter (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral))) acts-e04-t4))
  (check-true "L41-T4d-e04-17.5t-trigger-6probe-escalation-and-breach-latch-to-last-ling"
              (and pull-t1 (= (length (second pull-t1)) 5)
                   pull-t2 (= (length (second pull-t2)) 6)
                   pull-t3 (>= (length (second pull-t3)) 4)
                   (>= (length ret-t4) 4))
              (format "t1=~a t2=~a t3=~a ret-t4=~a" pull-t1 pull-t2 pull-t3 (length ret-t4)))

  ;; T4e (`e04` lone Zealot hug): Lone Zealot 5.5t out from Nexus with 6 Lings 3.5t away and
  ;; pulled Probes 5.5t behind hugs back (`move`) toward the Nexus instead of 1v6 suicide!
  (define rt-e04-hug (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define lings-6-mid
    (for/list ([i (in-range 6)])
      (mk-u (+ 5851 i) 'zergling 42.0 (+ 31.5 (* 0.4 i)) #:hp 35.0)))
  (define acts-e04-hug
    (step-layer2-economy!
     rt-e04-hug
     (mk-live-obs 'Protoss 'Zerg 1400 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons (mk-u 5251 'zealot 38.0 32.5 #:hp 100.0 #:shield 50.0) probes-14-e04)
                  #:ally-buildings (list main-nex)
                  #:enemy-units lings-6-mid #:mineral-patches main-mps)))
  (define zealot-hug-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 5251))) acts-e04-hug))
  (check-true "L41-T4e-e04-lone-zealot-far-from-nexus-hugs-back-to-probes-and-nexus"
              (and zealot-hug-move
                   (<= (dist2d-t (third zealot-hug-move) (fourth zealot-hug-move) 32.5 32.5) 1.0))
              (format "Expected lone far Zealot 5251 to hug back toward Nexus (32.5,32.5); move=~a" zealot-hug-move)))

(printf "\nL41 Tactics + Runtime Regression Summary: ~a passed, ~a failed\n" pass-cnt fail-cnt)
(unless (zero? fail-cnt)
  (exit 1))
