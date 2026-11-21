#lang racket/base

;; =============================================================================
;; `tests/l38-tactics-prod-test.rkt`
;; Loop 38 (`L38-P0-1`) Regression Suite:
;;   1. `L38-P0-1a` (`p15` DT Blink `ShadowStride` ab 2700 / upg 141 PF 1-Shot Snipe
;;      + cooldown non-spam + upgrade gate + post-PF static detector snipe)
;;   2. `L38-P0-1b` (`p13` Burrowed Widow Mine Range-6 Snipe + Zealot `>5.5t` hold
;;      + Observer AA standoff + `cloak=1` undetected guard + Zealot release)
;;   3. `L38-P0-1c` (`#5138254` Sole Observer #1 tether & Observer #2 on >=2 bases;
;;      `#5138250` CyberneticsCore queued Probe-order dedup & 168f issue lock;
;;      `#5138248` / `r02` 16 Drones vs 15 Probes mineral-walk stack + capped disengage;
;;      `e01`..`e04` econ-harass minimal 1-2 worker pull, wounded rotation & fast return)
;; =============================================================================

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt")

(define pass-cnt 0)
(define fail-cnt 0)

(define (check-true name cond-val [detail ""])
  (if cond-val
      (begin
        (set! pass-cnt (add1 pass-cnt))
        (printf "[PASS] ~a\n" name))
      (begin
        (set! fail-cnt (add1 fail-cnt))
        (printf "[FAIL] ~a~a\n"
                name
                (if (string=? detail "") "" (format " — ~a" detail))))))

(define (dist2d-t x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (run-l34 rt obs)
  (let-values ([(acts _p _t) (step-layer3-and-4-tactics! rt obs 0.5)])
    acts))

(define (mk-u id type x y
              #:hp [hp 100.0]
              #:max-hp [max-hp hp]
              #:shield [shield 0.0]
              #:max-shield [max-shield shield]
              #:flying? [flying? #f]
              #:cloak [cloak #f]
              #:burrowed [burrowed #f]
              #:build-progress [build-progress 1.0]
              #:order-ability-id [order-ability-id 0]
              #:order-ability-sym [order-ability-sym #f]
              #:orders [orders '()]
              #:build-target [build-target #f]
              #:assigned-harvesters [assigned-harvesters #f]
              #:ideal-harvesters [ideal-harvesters #f]
              #:weapon-cooldown [weapon-cooldown 0.0])
  (define h0
    (hash 'id id 'tag id 'type type 'x x 'y y
          'hp hp 'max-hp max-hp
          'shield shield 'max-shield max-shield
          'flying? flying? 'is-flying flying?
          'burrowed burrowed 'is-burrowed burrowed
          'build-progress build-progress
          'order-ability-id order-ability-id
          'orders orders
          'weapon-cooldown weapon-cooldown
          'display-type 1))
  (define h1 (if cloak (hash-set h0 'cloak cloak) h0))
  (define h2 (if order-ability-sym (hash-set h1 'order-ability-sym order-ability-sym) h1))
  (define h3 (if build-target (hash-set h2 'build-target build-target) h2))
  (define h4 (if assigned-harvesters (hash-set h3 'assigned-harvesters assigned-harvesters) h3))
  (if ideal-harvesters (hash-set h4 'ideal-harvesters ideal-harvesters) h4))

(define (mk-live-obs our-race enemy-race frame
                     #:minerals [minerals 400]
                     #:gas [gas 200]
                     #:supply-used [supply-used 40]
                     #:supply-cap [supply-cap 54]
                     #:base-x [base-x 32.5]
                     #:base-y [base-y 32.5]
                     #:nat-x [nat-x 58.5]
                     #:nat-y [nat-y 34.5]
                     #:enemy-x [enemy-x 140.0]
                     #:enemy-y [enemy-y 140.0]
                     #:ally-units [ally-units '()]
                     #:ally-buildings [ally-buildings '()]
                     #:enemy-units [enemy-units '()]
                     #:enemy-buildings [enemy-buildings '()]
                     #:mineral-patches [mineral-patches '()]
                     #:researched-upgrades [researched-upgrades '()]
                     #:live-upgrades? [live-upgrades? #t])
  (define base-h
    (hash 'frame frame
          'race our-race
          'enemy-race enemy-race
          'minerals minerals
          'gas gas
          'supply-used supply-used
          'supply-cap supply-cap
          'supply-left (max 0 (- supply-cap supply-used))
          'mineral-harvesters (count (lambda (u) (memq (hash-ref u 'type 'unknown) '(probe drone scv))) ally-units)
          'vespene-harvesters 0
          'base-x base-x 'base-y base-y
          'natural-x nat-x 'natural-y nat-y
          'enemy-x enemy-x 'enemy-y enemy-y
          'ally-units ally-units
          'ally-buildings ally-buildings
          'enemy-units enemy-units
          'enemy-buildings enemy-buildings
          'mineral-patches mineral-patches))
  (if live-upgrades?
      (hash-set base-h 'researched-upgrades researched-upgrades)
      base-h))

;; =============================================================================
;; 1. L38-P0-1a: `p15` DT Blink (`ShadowStride`, ab 2700, upg 141) PF 1-Shot Snipe
;; =============================================================================
(let ()
  ;; Exact p15 geometry shifted onto playable coordinates (center 64.0, 64.0)
  (define cx 64.0)
  (define cy 64.0)
  (define dts-27
    (append
     (for/list ([i (in-range 14)])
       (mk-u (+ 1001 i) 'dark-templar
             (+ (- cx 7.2) (* 0.15 (modulo i 4)))
             (+ (- cy 1.5) (* 0.18 (quotient i 4)))
             #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 13)])
       (mk-u (+ 1020 i) 'dark-templar
             (+ (- cx 7.2) (* 0.15 (modulo i 4)))
             (+ (+ cy 1.5) (* 0.18 (quotient i 4)))
             #:hp 40.0 #:shield 80.0))))
  (define pf-bldg (mk-u 9001 'planetary-fortress (+ cx 3.5) cy #:hp 1500.0))
  (define turrets (list (mk-u 9002 'missile-turret (+ cx 6.5) (- cy 2.8) #:hp 250.0)
                        (mk-u 9003 'missile-turret (+ cx 6.5) (+ cy 2.8) #:hp 250.0)))
  (define p15-enemy-units
    (append
     (for/list ([i (in-range 6)])
       (mk-u (+ 9100 i) 'hellbat (- cx 1.2) (+ cy (* 0.5 (- i 2.5))) #:hp 135.0))
     (for/list ([i (in-range 12)])
       (mk-u (+ 9200 i) 'marine (+ cx 0.2) (+ cy (* 0.4 (- i 5.5))) #:hp 55.0))
     (for/list ([i (in-range 6)])
       (mk-u (+ 9300 i) 'siege-tank-sieged (+ cx 5.0) (+ cy (if (< i 3) -4.5 4.5)) #:hp 175.0))))

  (define rt-p15 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-p15-f0
    (mk-live-obs 'Protoss 'Terran 40
                 #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                 #:ally-units dts-27
                 #:enemy-units p15-enemy-units
                 #:enemy-buildings (cons pf-bldg turrets)
                 #:researched-upgrades '(shadow-strike shadow-stride)))
  (define acts-p15-f0 (run-l34 rt-p15 obs-p15-f0))
  (define ss-casts-f0
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'cast-spell)
                   (>= (length a) 5) (eq? (caddr a) 'shadow-stride)))
            acts-p15-f0))
  (define dt-by-id (for/hasheqv ([u (in-list dts-27)]) (values (hash-ref u 'id) u)))
  (check-true "L38-T1a-p15-all-27-dts-cast-shadow-stride-frame0"
              (= (length ss-casts-f0) 27)
              (format "Expected 27 shadow-stride casts, got ~a" (length ss-casts-f0)))
  (check-true "L38-T1a-p15-all-blinks-clamped-within-8.0-range-and-near-pf-perimeter"
              (and (= (length ss-casts-f0) 27)
                   (for/and ([c (in-list ss-casts-f0)])
                     (define u (hash-ref dt-by-id (cadr c)))
                     (define bx (fourth c))
                     (define by (fifth c))
                     (define d-cast (dist2d-t (hash-ref u 'x) (hash-ref u 'y) bx by))
                     (define d-pf (dist2d-t (+ cx 3.5) cy bx by))
                     (and (<= d-cast 8.0) (>= d-pf 2.8) (<= d-pf 4.6))))
              (format "Sample blink casts: ~a" (take ss-casts-f0 (min 3 (length ss-casts-f0)))))
  (define ys-spread
    (if (pair? ss-casts-f0)
        (- (apply max (map fifth ss-casts-f0)) (apply min (map fifth ss-casts-f0)))
        0.0))
  (check-true "L38-T1a-p15-blinks-spread-along-pf-ring"
              (>= ys-spread 3.5)
              (format "Expected Y spread >= 3.5t around PF perimeter, got ~a" ys-spread))

  ;; T1b: Frame +8 (on 314f ShadowStride CD, DTs landed at ~3.2t from PF) -> ZERO duplicate blinks & ALL 27 focus-fire PF 9001!
  (define dts-landed
    (for/list ([u (in-list dts-27)] [i (in-naturals)])
      (define ang (+ pi (* 0.1 (- i 13))))
      (mk-u (hash-ref u 'id) 'dark-templar
            (+ (+ cx 3.5) (* 3.1 (cos ang)))
            (+ cy (* 3.1 (sin ang)))
            #:hp 40.0 #:shield 80.0)))
  (define obs-p15-f8
    (mk-live-obs 'Protoss 'Terran 48
                 #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                 #:ally-units dts-landed
                 #:enemy-units p15-enemy-units
                 #:enemy-buildings (cons pf-bldg turrets)
                 #:researched-upgrades '(shadow-strike shadow-stride)))
  (define acts-p15-f8 (run-l34 rt-p15 obs-p15-f8))
  (define ss-casts-f8
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride)))
            acts-p15-f8))
  (define pf-attacks-f8
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (caddr a) 9001)))
            acts-p15-f8))
  (check-true "L38-T1b-p15-cooldown-non-spam-and-all-27-focus-fire-pf"
              (and (null? ss-casts-f8) (= (length pf-attacks-f8) 27))
              (format "Expected 0 shadow-stride & 27 PF attack-unit, got ~a casts & ~a PF attacks"
                      (length ss-casts-f8) (length pf-attacks-f8)))

  ;; T1c: Without ShadowStride upgrade (141), emit ZERO shadow-stride casts (no wire rejects!) & focus-fire PF
  (define rt-p15-noupg (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-p15-noupg
    (mk-live-obs 'Protoss 'Terran 40
                 #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                 #:ally-units dts-27
                 #:enemy-units p15-enemy-units
                 #:enemy-buildings (cons pf-bldg turrets)
                 #:researched-upgrades '()))
  (define acts-p15-noupg (run-l34 rt-p15-noupg obs-p15-noupg))
  (check-true "L38-T1c-p15-no-shadow-stride-without-upgrade-141"
              (and (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride)))
                               acts-p15-noupg))
                   (= (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (caddr a) 9001)))
                             acts-p15-noupg)
                      27))
              "Without upgrade 141, DTs must emit 0 shadow-stride and still focus-fire PF")

  ;; T1d: Post-PF static detector snipe (once PF explodes, surviving DTs snipe Missile Turrets to go dark!)
  (define obs-p15-postpf
    (mk-live-obs 'Protoss 'Terran 80
                 #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                 #:ally-units (take dts-landed 20)
                 #:enemy-units p15-enemy-units
                 #:enemy-buildings turrets
                 #:researched-upgrades '(shadow-stride)))
  (define acts-p15-postpf (run-l34 rt-p15 obs-p15-postpf))
  (define turret-attacks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (caddr a) '(9002 9003))))
            acts-p15-postpf))
  (check-true "L38-T1d-p15-post-pf-dts-snipe-missile-turret-detection"
              (>= (length turret-attacks) 18)
              (format "Expected >= 18 DTs focus-firing Missile Turrets post-PF, got ~a" (length turret-attacks)))
  (check-true "L38-T1d-small-dt-squad-below-4-does-not-trigger-pf-dive"
              (null? (plan-dt-blink-pf-snipe (take dts-27 3) p15-enemy-units (list pf-bldg)
                                             (make-spell-claims) 40 #:researched-upgrades '(141)))
              "Fewer than 4 DTs must not trigger PF snipe"))

;; =============================================================================
;; 2. L38-P0-1b: `p13` Burrowed Widow Mine Range-6 Snipe & Zealot `> 5.5t` Hold
;; =============================================================================
(let ()
  (define cx 64.0)
  (define cy 64.0)
  (define zealots-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 2001 i) 'zealot (- cx 3.5) (+ cy (* 0.5 (- i 1.5))) #:hp 100.0 #:shield 50.0)))
  (define stalkers-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 2011 i) 'stalker (- cx 5.0) (+ cy (* 0.4 (- i 3.5))) #:hp 80.0 #:shield 80.0)))
  (define colossi-2
    (list (mk-u 2021 'colossus (- cx 6.2) (- cy 0.8) #:hp 200.0 #:shield 150.0)
          (mk-u 2022 'colossus (- cx 6.2) (+ cy 0.8) #:hp 200.0 #:shield 150.0)))
  (define observers-2
    (list (mk-u 2031 'observer (- cx 5.2) (+ cy 1.8) #:hp 40.0 #:shield 20.0 #:flying? #t)
          (mk-u 2032 'observer (- cx 5.2) (- cy 1.8) #:hp 40.0 #:shield 20.0 #:flying? #t)))
  (define p13-mines-det
    (append
     (for/list ([i (in-range 3)])
       (mk-u (+ 8001 i) 'widow-mine-burrowed (+ cx 2.8) (- cy 2.0 (* 0.2 i)) #:hp 90.0 #:burrowed #t #:cloak 2))
     (for/list ([i (in-range 3)])
       (mk-u (+ 8004 i) 'widow-mine-burrowed (+ cx 2.8) (+ cy 2.0 (* 0.2 i)) #:hp 90.0 #:burrowed #t #:cloak 2))))
  (define p13-bio
    (append
     (for/list ([i (in-range 6)])
       (mk-u (+ 8100 i) 'marauder (+ cx 4.0) (+ cy (* 0.4 (- i 2.5))) #:hp 125.0))
     (for/list ([i (in-range 14)])
       (mk-u (+ 8200 i) 'marine (+ cx 5.0) (+ cy (* 0.3 (- i 6.5))) #:hp 55.0))))
  (define wm-ids '(8001 8002 8003 8004 8005 8006))

  (define rt-p13 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-p13
    (mk-live-obs 'Protoss 'Terran 40
                 #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                 #:ally-units (append zealots-4 stalkers-8 colossi-2 observers-2)
                 #:enemy-units (append p13-mines-det p13-bio)
                 #:researched-upgrades '(charge blink extended-thermal-lance)))
  (define acts-p13 (run-l34 rt-p13 obs-p13))
  (define sniper-wm-attacks
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'attack-unit)
                   (or (<= 2011 (cadr a) 2018) (memv (cadr a) '(2021 2022)))
                   (memv (caddr a) wm-ids)))
            acts-p13))
  (define zealot-bad-attacks
    (filter (lambda (a)
              (and (pair? a)
                   (memq (car a) '(attack-unit attack-pos))
                   (<= 2001 (cadr a) 2004)))
            acts-p13))
  (define zealot-holds-or-kites
    (filter (lambda (a)
              (and (pair? a)
                   (memq (car a) '(kite move))
                   (<= 2001 (cadr a) 2004)))
            acts-p13))
  (check-true "L38-T2a-p13-all-stalkers-and-colossi-focus-fire-detected-burrowed-mines"
              (= (length sniper-wm-attacks) 10)
              (format "Expected 10 range-6+ mine snipes (8 Stalkers + 2 Colossi), got ~a" (length sniper-wm-attacks)))
  (check-true "L38-T2a-p13-zealots-hold-safely-away-from-burrowed-mines"
              (and (null? zealot-bad-attacks) (= (length zealot-holds-or-kites) 4))
              (format "Expected 0 Zealot mine-charges & 4 Zealot holds/kites, got bad=~a holds=~a"
                      zealot-bad-attacks zealot-holds-or-kites))

  ;; Even when Zealots stand at dist = 7.6t (> old 6.8t cutoff!), they MUST STILL hold instead of Charging in!
  (define zealots-far
    (for/list ([i (in-range 4)])
      (mk-u (+ 2001 i) 'zealot (- cx 4.8) (+ cy (* 0.5 (- i 1.5))) #:hp 100.0 #:shield 50.0)))
  (define obs-p13-far
    (mk-live-obs 'Protoss 'Terran 44
                 #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                 #:ally-units (append zealots-far stalkers-8 colossi-2 observers-2)
                 #:enemy-units (append p13-mines-det p13-bio)
                 #:researched-upgrades '(charge blink extended-thermal-lance)))
  (define acts-p13-far (run-l34 rt-p13 obs-p13-far))
  (check-true "L38-T2a-p13-zealots-at-7.6t-still-hold-no-charge-into-mines"
              (not (ormap (lambda (a)
                            (and (pair? a) (memq (car a) '(attack-unit attack-pos))
                                 (<= 2001 (cadr a) 2004)))
                          acts-p13-far))
              "Zealots at 7.6t must hold standoff while un-cleared burrowed mines remain")

  ;; Observers stay at safe AA standoff (not diving within < 6.8t of Marines at cx+5.0!)
  (define obs-moves-p13
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (cadr a) '(2031 2032))))
            acts-p13))
  (check-true "L38-T2a-p13-observers-do-not-dive-into-marine-aa-range"
              (for/and ([m (in-list obs-moves-p13)])
                (> (dist2d-t (third m) (fourth m) (+ cx 5.0) cy) 6.5))
              (format "Observers must hold safe AA standoff from Marines; moves=~a" obs-moves-p13))

  ;; T2b: Exact cloak=1 undetected mine guard + Zealot release once all mines dead!
  (define wm-undet (mk-u 8099 'widow-mine-burrowed (+ cx 2.8) cy #:hp 90.0 #:burrowed #t #:cloak 1))
  (define wm-det   (mk-u 8098 'widow-mine-burrowed (+ cx 2.8) cy #:hp 90.0 #:burrowed #t #:cloak 2))
  (check-true "L38-T2b-widow-mine-detected-targetable-blocks-cloak1"
              (and (not (widow-mine-detected-targetable? wm-undet observers-2))
                   (widow-mine-detected-targetable? wm-det observers-2))
              "Undetected cloak=1 mine must return #f; detected cloak=2 mine must return #t")

  (define obs-p13-cleared
    (mk-live-obs 'Protoss 'Terran 88
                 #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                 #:ally-units (append zealots-4 stalkers-8 colossi-2 observers-2)
                 #:enemy-units p13-bio
                 #:researched-upgrades '(charge blink extended-thermal-lance)))
  ;; Run full multi-step `step-live-bot-runtime!` (so order-ledger syncs across frames like live SC2!)
  (define rt-p13-rel (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (step-live-bot-runtime! rt-p13-rel obs-p13)
  (define acts-p13-cleared (hash-ref (step-live-bot-runtime! rt-p13-rel obs-p13-cleared) 'actions '()))
  (check-true "L38-T2b-p13-zealots-release-to-engage-bio-once-mines-cleared"
              (ormap (lambda (a)
                       (and (pair? a) (memq (car a) '(attack-unit attack-pos))
                            (let ([uarg (cadr a)])
                              (or (and (exact-integer? uarg) (<= 2001 uarg 2004))
                                  (and (list? uarg)
                                       (ormap (lambda (id) (and (exact-integer? id) (<= 2001 id 2004))) uarg))))))
                     acts-p13-cleared)
              (format "Once burrowed mines are cleared, Zealots must immediately engage enemy Bio; acts=~a"
                      acts-p13-cleared)))

;; =============================================================================
;; 3. L38-P0-1c (`#5138254`): Sole Observer #1 Tether & Observer #2 on >= 2 Bases
;; =============================================================================
(let ()
  (define probes-20
    (for/list ([i (in-range 20)])
      (mk-u (+ 3001 i) 'probe 29.0 (+ 30.0 (* 0.25 i)) #:hp 20.0 #:shield 20.0)))
  (define stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 3101 i) 'stalker 35.0 (+ 31.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define sole-obs-far (mk-u 3201 'observer 50.0 50.0 #:hp 40.0 #:shield 20.0 #:flying? #t))
  (define banshee-uncloaked (mk-u 7001 'banshee 38.0 33.0 #:hp 140.0 #:flying? #t))
  (define p-2base-bldgs
    (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 11 'nexus 58.5 34.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 12 #:ideal-harvesters 16)
          (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
          (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0)
          (mk-u 14 'cybernetics-core 40.0 36.0 #:hp 550.0 #:shield 550.0)
          (mk-u 15 'robotics-facility 37.0 38.0 #:hp 450.0 #:shield 450.0)))

  (define rt-obs (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-5138254
    (mk-live-obs 'Protoss 'Terran 5000
                 #:minerals 350 #:gas 200 #:supply-used 48 #:supply-cap 62
                 #:ally-units (append probes-20 stalkers-6 (list sole-obs-far))
                 #:ally-buildings p-2base-bldgs
                 #:enemy-units (list banshee-uncloaked
                                     (mk-u 7002 'banshee 40.0 34.0 #:hp 140.0 #:flying? #t))))
  (define l2-acts-obs (step-layer2-economy! rt-obs obs-5138254))
  (define l34-acts-obs (run-l34 rt-obs obs-5138254))
  (check-true "L38-T3a-5138254-sole-observer-never-stolen-by-periodic-scout"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'periodic-scout) (= (cadr a) 3201)))
                          l2-acts-obs))
              (format "Sole Observer #1 must NOT be sent on periodic-scout under Banshee threat; acts=~a" l2-acts-obs))
  (define obs-tether-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (cadr a) 3201))) l34-acts-obs))
  (check-true "L38-T3a-5138254-sole-observer-tethered-within-6t-of-defending-stalkers"
              (and obs-tether-move
                   (<= (dist2d-t (third obs-tether-move) (fourth obs-tether-move) 35.0 32.25) 6.0))
              (format "Expected sole Observer #1 tethered <= 6t to Stalkers (35,32.25); move=~a" obs-tether-move))
  (check-true "L38-T3b-5138254-observer-2-trains-on-2-bases-under-banshee-threat"
              (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (cadr a) 'observer)))
                     l2-acts-obs)
              (format "Expected 2-base Protoss with 1 Observer to train Observer #2 vs Banshees; acts=~a" l2-acts-obs)))

;; =============================================================================
;; 4. L38-P0-1c (`#5138250`): Duplicate CyberneticsCore Queued Probe-Order Dedup
;; =============================================================================
(let ()
  (define base-p-bldgs
    (list (mk-u 10 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 12 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
          (mk-u 13 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0)))
  (define base-probes-18
    (for/list ([i (in-range 18)])
      (mk-u (+ 4001 i) 'probe 29.0 32.0 #:hp 20.0 #:shield 20.0)))
  (define (has-build-cyber? acts)
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'cybernetics-core))) acts))

  ;; Case 1: Probe has ord0 = 299 (HARVEST_RETURN) with queued 894 (build-cybernetics-core) in `orders`!
  (define rt-cy1 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probe-queued-894
    (mk-u 4099 'probe 37.0 33.0 #:hp 20.0 #:shield 20.0
          #:order-ability-id 299
          #:orders (list (hasheq 'ability-id 299 'ability 'harvest-return-probe)
                         (hasheq 'ability-id 894 'ability 'build-cybernetics-core))))
  (define acts-cy1
    (step-layer2-economy!
     rt-cy1
     (mk-live-obs 'Protoss 'Terran 2400 #:minerals 260 #:gas 50 #:supply-used 22 #:supply-cap 31
                  #:ally-units (cons probe-queued-894 base-probes-18)
                  #:ally-buildings base-p-bldgs)))
  (check-true "L38-T4a-5138250-blocks-dup-cybercore-on-queued-894-order"
              (not (has-build-cyber? acts-cy1))
              (format "Must NOT emit duplicate CyberCore when Probe has queued 894; acts=~a" acts-cy1))

  ;; Case 2: Probe tagged with `'build-target 'cybernetics-core` while order-ability-id is 16 (MOVE)
  (define rt-cy2 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probe-btarget
    (mk-u 4098 'probe 37.0 33.0 #:hp 20.0 #:shield 20.0
          #:order-ability-id 16
          #:build-target 'cybernetics-core))
  (define acts-cy2
    (step-layer2-economy!
     rt-cy2
     (mk-live-obs 'Protoss 'Terran 2400 #:minerals 260 #:gas 50 #:supply-used 22 #:supply-cap 31
                  #:ally-units (cons probe-btarget base-probes-18)
                  #:ally-buildings base-p-bldgs)))
  (check-true "L38-T4a-5138250-blocks-dup-cybercore-on-build-target"
              (not (has-build-cyber? acts-cy2))
              (format "Must NOT emit duplicate CyberCore when Probe carries build-target; acts=~a" acts-cy2))

  ;; Case 3: 168f build-issue lock prevents duplicate CyberCore at +68f (past old 56f lock / 64f wall fallback!)
  (define rt-cy3 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-cy3-a
    (step-layer2-economy!
     rt-cy3
     (mk-live-obs 'Protoss 'Terran 2200 #:minerals 360 #:gas 50 #:supply-used 22 #:supply-cap 39
                  #:ally-units (cons (mk-u 4050 'zealot 40.0 34.0 #:hp 100.0 #:shield 50.0) base-probes-18)
                  #:ally-buildings base-p-bldgs)))
  (define acts-cy3-b
    (step-layer2-economy!
     rt-cy3
     (mk-live-obs 'Protoss 'Terran 2268 #:minerals 360 #:gas 60 #:supply-used 22 #:supply-cap 39
                  #:ally-units (cons (mk-u 4050 'zealot 40.0 34.0 #:hp 100.0 #:shield 50.0) base-probes-18)
                  #:ally-buildings base-p-bldgs)))
  (check-true "L38-T4a-5138250-168f-issue-lock-prevents-second-cybercore-at-68f"
              (and (has-build-cyber? acts-cy3-a)
                   (not (has-build-cyber? acts-cy3-b)))
              (format "Expected CyberCore at f=2200 (~a) and NO duplicate at f=2268 (~a)"
                      (has-build-cyber? acts-cy3-a) (has-build-cyber? acts-cy3-b))))

;; =============================================================================
;; 5. L38-P0-1c (`#5138248` / `r02` & `e01`..`e04`): Worker-Rush Stack & Econ-Harass
;; =============================================================================
(let ()
  (define main-mps
    (for/list ([i (in-range 8)])
      (hash 'id (+ 50001 i) 'type 'mineral-field
            'x 26.5 'y (+ 29.0 (* 1.0 i)) 'mineral-contents 1500)))
  (define main-hatch
    (mk-u 5000 'hatchery 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16))

  ;; T5a: 16 Zerg Drones vs 15 rushing Probes near mineral line/Hatchery (`#5138248` / `r02`):
  ;; - All 16 healthy Drones commit (keep-mining = 0)
  ;; - Outer Drones (> 2.2t from Probes, <= 6.4t from drill-patch) get `worker-drill-stack-attack`
  ;;   emitted BEFORE `pull-workers-attack` and NOT duplicated in `pull-workers-attack`!
  (define drones-16
    (append
     ;; 6 inner drones already near Probes at (30.0, 32.5)
     (for/list ([i (in-range 6)])
       (mk-u (+ 5101 i) 'drone 29.5 (+ 31.2 (* 0.4 i)) #:hp 40.0))
     ;; 10 outer drones around mineral arc/Hatchery (> 2.2t from Probes, <= 6.4t from drill patch 26.5, 32.0)
     (for/list ([i (in-range 10)])
       (mk-u (+ 5111 i) 'drone 27.5 (+ 29.0 (* 0.3 i)) #:hp 40.0))))
  (define probes-15-rush
    (for/list ([i (in-range 15)])
      (mk-u (+ 5901 i) 'probe (+ 29.5 (* 0.08 (modulo i 5))) (+ 32.5 (* 0.08 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))

  (define rt-r02 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-r02
    (step-layer2-economy!
     rt-r02
     (mk-live-obs 'Zerg 'Protoss 1200 #:minerals 220 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:ally-units drones-16
                  #:ally-buildings (list main-hatch)
                  #:enemy-units probes-15-rush
                  #:mineral-patches main-mps)))
  (define drill-idx
    (for/first ([a (in-list acts-r02)] [idx (in-naturals)]
                #:when (and (pair? a) (eq? (car a) 'worker-drill-stack-attack)))
      idx))
  (define pull-idx
    (for/first ([a (in-list acts-r02)] [idx (in-naturals)]
                #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
      idx))
  (define drill-wids
    (append* (for/list ([a (in-list acts-r02)]
                        #:when (and (pair? a) (eq? (car a) 'worker-drill-stack-attack)))
               (second a))))
  (define pull-wids
    (append* (for/list ([a (in-list acts-r02)]
                        #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
               (second a))))
  (define total-engaged-drones (length (remove-duplicates (append drill-wids pull-wids))))
  (check-true "L38-T5a-5138248-all-16-drones-commit-and-drill-stack-precedes-pull"
              (and (= total-engaged-drones 16)
                   (number? drill-idx)
                   (or (not pull-idx) (< drill-idx pull-idx))
                   (null? (filter (lambda (w) (memv w pull-wids)) drill-wids)))
              (format "engaged=~a drill-idx=~a pull-idx=~a drill-cnt=~a pull-cnt=~a"
                      total-engaged-drones drill-idx pull-idx (length drill-wids) (length pull-wids)))

  ;; T5a2: When 5 Drones drop to <= 10 HP during 15-Probe all-in, cap simultaneous disengage at <= 2!
  (define drones-5-low
    (for/list ([u (in-list drones-16)] [i (in-naturals)])
      (if (< i 5) (hash-set u 'hp 8.0) u)))
  (define acts-r02-low
    (step-layer2-economy!
     rt-r02
     (mk-live-obs 'Zerg 'Protoss 1208 #:minerals 220 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:ally-units drones-5-low
                  #:ally-buildings (list main-hatch)
                  #:enemy-units probes-15-rush
                  #:mineral-patches main-mps)))
  (define mw-dis-cnt
    (count (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-r02-low))
  (check-true "L38-T5a-5138248-heavy-worker-allin-caps-simultaneous-disengage-at-2"
              (<= mw-dis-cnt 2)
              (format "Expected <= 2 Drones disengaging simultaneously in 15-Probe all-in, got ~a" mw-dis-cnt))

  ;; T5b (`e01`): 12 mining Probes vs 2 enemy harass Probes -> pulls strictly <= 2 healthy Probes
  ;; (keeping >= 10 mining!), zero extra worker-harass, and rotates wounded defender back to minerals!
  (define main-nexus
    (mk-u 6000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 12 #:ideal-harvesters 16))
  (define probes-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 6101 i) 'probe 28.5 (+ 29.0 (* 0.6 i)) #:hp 20.0 #:shield 20.0)))
  (define enemy-harass-probes-2
    (list (mk-u 6901 'probe 33.5 31.5 #:hp 20.0 #:shield 20.0)
          (mk-u 6902 'probe 33.5 33.0 #:hp 20.0 #:shield 20.0)))
  (define rt-e01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-e01
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 800 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12
                  #:ally-buildings (list main-nexus)
                  #:enemy-units enemy-harass-probes-2
                  #:mineral-patches main-mps)))
  (define e01-pulled
    (append* (for/list ([a (in-list acts-e01)]
                        #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
               (second a))))
  (define e01-extra-harass?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-harass))) acts-e01))
  (check-true "L38-T5b-e01-minimal-pull-1-to-2-probes-keeps-10-mining"
              (and (>= (length e01-pulled) 1)
                   (<= (length e01-pulled) 2)
                   (not e01-extra-harass?))
              (format "Expected 1..2 pulled Probes & no extra worker-harass; pulled=~a extra=~a"
                      e01-pulled e01-extra-harass?))

  ;; Rotate wounded defender (<= 18 EHP) straight back to harvest-mineral!
  (define wounded-def-id (if (pair? e01-pulled) (car e01-pulled) 6101))
  (define probes-12-wounded
    (for/list ([u (in-list probes-12)])
      (if (= (hash-ref u 'id) wounded-def-id)
          (hash-set (hash-set u 'hp 14.0) 'shield 0.0)
          u)))
  (define acts-e01-rot
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 812 #:minerals 120 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12-wounded
                  #:ally-buildings (list main-nexus)
                  #:enemy-units enemy-harass-probes-2
                  #:mineral-patches main-mps)))
  (check-true "L38-T5b-e01-wounded-defender-rotates-back-to-minerals"
              (ormap (lambda (a)
                       (and (pair? a) (eq? (car a) 'harvest-mineral) (= (cadr a) wounded-def-id)))
                     acts-e01-rot)
              (format "Expected wounded Probe ~a returned via harvest-mineral; acts=~a"
                      wounded-def-id acts-e01-rot))

  ;; Fast idle-worker return when idle worker sits near <= 2 light harass scouts!
  (define probes-with-idle
    (for/list ([u (in-list probes-12)])
      (if (= (hash-ref u 'id) 6105)
          (hash-set u 'orders '())
          (hash-set u 'orders (list (hasheq 'ability-id 298))))))
  (define acts-e01-idle
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 824 #:minerals 140 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-with-idle
                  #:ally-buildings (list main-nexus)
                  #:enemy-units enemy-harass-probes-2
                  #:mineral-patches main-mps)))
  (check-true "L38-T5b-e01-displaced-idle-worker-returns-to-safe-minerals"
              (ormap (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (= (cadr a) 6105)))
                     acts-e01-idle)
              (format "Expected idle healthy Probe 6105 returned to minerals; acts=~a" acts-e01-idle))

  ;; T5c (`e02` & `e04`):
  ;; e02: 16 Drones + 1 Queen vs 2 Reapers -> 0 healthy Drones blanket-evacuated!
  (define rt-e02 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-e02
    (step-layer2-economy!
     rt-e02
     (mk-live-obs 'Zerg 'Terran 1800 #:minerals 150 #:gas 0 #:supply-used 18 #:supply-cap 22
                  #:ally-units (cons (mk-u 5201 'queen 35.5 32.5 #:hp 175.0) drones-16)
                  #:ally-buildings (list main-hatch)
                  #:enemy-units (list (mk-u 5801 'reaper 34.5 31.5 #:hp 60.0)
                                      (mk-u 5802 'reaper 34.5 33.5 #:hp 60.0))
                  #:mineral-patches main-mps)))
  (define e02-evac-cnt (count (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-e02))
  (check-true "L38-T5c-e02-queen-and-16-drones-vs-2-reapers-zero-healthy-evac"
              (= e02-evac-cnt 0)
              (format "Expected 0 healthy Drones evacuated with Queen defending 2 Reapers, got ~a" e02-evac-cnt))

  ;; e04: 14 Probes + 1 Zealot vs 6 Speedlings -> proportional pull <= 5 Probes (keeps >= 9 mining!)
  (define rt-e04 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probes-14
    (for/list ([i (in-range 14)])
      (mk-u (+ 6301 i) 'probe 28.5 (+ 29.0 (* 0.5 i)) #:hp 20.0 #:shield 20.0)))
  (define lings-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 6801 i) 'zergling 35.0 (+ 31.0 (* 0.4 i)) #:hp 35.0)))
  (define acts-e04
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1800 #:minerals 150 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons (mk-u 6401 'zealot 34.0 32.5 #:hp 100.0 #:shield 50.0) probes-14)
                  #:ally-buildings (list main-nexus)
                  #:enemy-units lings-6
                  #:mineral-patches main-mps)))
  (define e04-pulled
    (append* (for/list ([a (in-list acts-e04)]
                        #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
               (second a))))
  (check-true "L38-T5c-e04-6lings-with-zealot-pulls-proportionally-keeps-9-mining"
              (and (>= (length e04-pulled) 3) (<= (length e04-pulled) 5))
              (format "Expected 3..5 Probes pulled alongside Zealot vs 6 Lings, got ~a" (length e04-pulled))))

(printf "\nL38 Tactics + Prod Regression Summary: ~a passed, ~a failed\n" pass-cnt fail-cnt)
(unless (zero? fail-cnt)
  (exit 1))
