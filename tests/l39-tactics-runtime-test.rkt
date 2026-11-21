#lang racket/base

;; =============================================================================
;; `tests/l39-tactics-runtime-test.rkt`
;; Loop 39 (`L39-P0-1`, `#902`) Runtime & Tactics Regression Suite:
;;   1. `L39-P0-1a` (`#5140013` / `r05` 15-Probe Rush vs 16 SCVs: disable L2 Pass A/B
;;      & L3/L4 SCV-on-SCV auto-repair while preserving small-rush & Mech/PF/Bunker repair)
;;   2. `L39-P0-1b` (`p15` DT Blink PF 1-Shot: cloaked approach `> 10.95t`, Tank-splash
;;      precedence, exact PF perimeter ring landing, & execution-confirmed 12f -> 314f CD)
;;   3. `L39-P0-1c` (`t15` Battlecruiser Yamato Cannon baseline in LotV 4.7+ with ZERO
;;      `'weapon-refit` upgrade + Viper/Corruptor priority + execution-confirmed CD)
;;   4. `L39-P0-1d` (`z14` Infestor `NeuralParasite` priority & 13t approach BEFORE
;;      FungalGrowth + simultaneous Neural/Fungal split + upgrade gate)
;;   5. `L39-P0-1e` (`z16` Mutalisk Magic-Box vs Thors: `>= 6` Mutalisks spread `>= 1.4t`
;;      via pure MOVE over Thor then HOLD_POSITION + wounded `< 32` HP pull)
;;   6. `L39-P0-1f` (`e03` 3-Adept distributed mineral-walk evac + zero SCV suicide pull;
;;      `e04` 6-Ling `<= 22`-EHP Probe mineral-walk evac; `#72` Anti-Decoy early home tether)
;;   7. `L39-P0-1g` (`#896` Mid-Fight Home-Retreat Stalemate Guard: healthy engaged units
;;      `<= 16t` vs live combat enemies never flee home into fog stalemate)
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
              #:energy [energy 0.0]
              #:flying? [flying? #f]
              #:cloak [cloak #f]
              #:burrowed [burrowed #f]
              #:build-progress [build-progress 1.0]
              #:order-ability-id [order-ability-id 0]
              #:orders [orders '()]
              #:weapon-cooldown [weapon-cooldown 0.0])
  (define h0
    (hash 'id id 'tag id 'type type 'x x 'y y
          'hp hp 'max-hp max-hp
          'shield shield 'shields shield
          'max-shield max-shield 'max-shields max-shield
          'energy energy
          'flying? flying? 'is-flying flying?
          'burrowed burrowed 'is-burrowed burrowed
          'build-progress build-progress
          'order-ability-id order-ability-id
          'orders orders
          'weapon-cooldown weapon-cooldown
          'display-type 1))
  (if cloak (hash-set h0 'cloak cloak) h0))

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

(define main-mps
  (for/list ([i (in-range 8)])
    (hash 'id (+ 9001 i)
          'x (- 26.5 (* 0.3 (modulo i 2)))
          'y (+ 27.5 (* 1.4 i))
          'mineral-contents 1200)))

;; =============================================================================
;; 1. L39-P0-1a: `#5140013` / `r05` Disable SCV Auto-Repair vs >=10-Worker Rush
;; =============================================================================
(let ()
  (define main-cc (mk-u 1000 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 1101 i) 'scv
            (+ 28.5 (* 0.4 (modulo i 4)))
            (+ 30.0 (* 0.8 (quotient i 4)))
            #:hp (cond [(= i 0) 24.0] [(= i 1) 28.0] [else 45.0])
            #:max-hp 45.0)))
  (define probes-15
    (for/list ([i (in-range 15)])
      (mk-u (+ 1901 i) 'probe (+ 31.0 (* 0.2 (modulo i 5))) (+ 31.5 (* 0.2 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  (define rt-r05 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-r05
    (mk-live-obs 'Terran 'Protoss 1200 #:minerals 200 #:gas 0 #:supply-used 16 #:supply-cap 23
                 #:ally-units scvs-16 #:ally-buildings (list main-cc)
                 #:enemy-units probes-15 #:mineral-patches main-mps))
  (define l2-acts-r05 (step-layer2-economy! rt-r05 obs-r05))
  (define l2-repairs (filter (lambda (a) (and (pair? a) (eq? (car a) 'repair))) l2-acts-r05))
  (define l2-drill-or-pull
    (filter (lambda (a) (and (pair? a) (memq (car a) '(worker-drill-stack-attack pull-workers-attack))))
            l2-acts-r05))
  (check-true "L39-T1a-r05-15probe-rush-zero-l2-scv-repair-and-scvs-fight"
              (and (null? l2-repairs) (pair? l2-drill-or-pull))
              (format "repairs=~a fight-cmds=~a" l2-repairs (length l2-drill-or-pull)))

  ;; L3/L4 spellcaster SCV repair also refuses SCV-on-SCV repair under 15-probe rush
  (define sp-dirs-r05
    (plan-terran-spellcaster-micro scvs-16 probes-15
                                   #:claims (make-spell-claims) #:current-frame 1200
                                   #:ally-buildings (list main-cc)))
  (define sp-scv-repairs
    (filter (lambda (d) (eq? (spell-directive-ability d) 'repair)) sp-dirs-r05))
  (check-true "L39-T1a-r05-15probe-rush-zero-l34-scv-on-scv-repair"
              (null? sp-scv-repairs)
              (format "Expected 0 SCV-on-SCV repair directives during 15-probe rush, got ~a" sp-scv-repairs))

  ;; Negative guard: damaged Siege Tank STILL gets SCV repair cleanly!
  (define dmg-tank (mk-u 1500 'siege-tank-sieged 31.0 32.0 #:hp 90.0 #:max-hp 175.0))
  (define sp-dirs-tank
    (plan-terran-spellcaster-micro (cons dmg-tank (take scvs-16 4)) (take probes-15 6)
                                   #:claims (make-spell-claims) #:current-frame 1200))
  (check-true "L39-T1b-damaged-siege-tank-still-receives-scv-repair"
              (ormap (lambda (d) (and (eq? (spell-directive-ability d) 'repair)
                                      (= (spell-directive-target-tag d) 1500)))
                     sp-dirs-tank)
              "Damaged Siege Tank must still receive SCV repair"))

;; =============================================================================
;; 2. L39-P0-1b: `p15` DT Blink PF 1-Shot (Cloaked Approach + Exact Ring + SP Retry)
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 88.0)
  (define pf-bldg (mk-u 9001 'planetary-fortress (+ cx 3.5) cy #:hp 1500.0))
  (define turrets (list (mk-u 9002 'missile-turret (+ cx 6.5) (- cy 2.8) #:hp 250.0)
                        (mk-u 9003 'missile-turret (+ cx 6.5) (+ cy 2.8) #:hp 250.0)))
  ;; Full 76-supply Terran p15 force (commit-splash? = #f vs 54-supply DTs!)
  (define full-p15-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 9100 i) 'hellbat (- cx 1.2) (+ cy (* 0.4 (- i 2.5))) #:hp 135.0))
     (for/list ([i (in-range 8)]) (mk-u (+ 9120 i) 'marauder (- cx 0.5) (+ cy (* 0.35 (- i 3.5))) #:hp 125.0))
     (for/list ([i (in-range 24)]) (mk-u (+ 9200 i) 'marine (+ cx 0.2) (+ cy (* 0.25 (- i 11.5))) #:hp 55.0))
     (for/list ([i (in-range 6)]) (mk-u (+ 9300 i) 'siege-tank-sieged (+ cx 5.0) (+ cy (if (< i 3) -4.5 4.5)) #:hp 175.0))
     (for/list ([i (in-range 3)]) (mk-u (+ 9400 i) 'medivac (+ cx 4.5) (- cy 2.5) #:hp 150.0 #:flying? #t))))

  ;; T2a: Far DTs at x = cx - 9.0 (d_pf = 12.6t > 10.95t) MUST cloaked-walk (`move`), NOT early-blink!
  (define far-dts-27
    (for/list ([i (in-range 27)])
      (mk-u (+ 2001 i) 'dark-templar
            (- cx 9.0) (+ cy (if (< i 14) -1.5 1.5))
            #:hp 40.0 #:shield 80.0)))
  (define rt-p15-far (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-far
    (run-l34 rt-p15-far
             (mk-live-obs 'Protoss 'Terran 600
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units far-dts-27
                          #:enemy-units full-p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-strike shadow-stride))))
  (define far-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-far))
  (define far-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move))) acts-far))
  (check-true "L39-T2a-p15-far-dts-cloaked-walk-before-blinking"
              (and (null? far-blinks) (= (length far-moves) 27))
              (format "Expected 0 early blinks & 27 cloaked moves, got blinks=~a moves=~a"
                      (length far-blinks) (length far-moves)))

  ;; T2b: Once in blink range (d_pf ~ 10.2t <= 10.95t) against FULL 76-supply p15 + 6 Sieged Tanks,
  ;; ALL 27/27 DTs cast shadow-stride directly onto PF perimeter (0 stolen by Tank splash evasion!)
  (define ready-dts-27
    (for/list ([i (in-range 27)])
      (mk-u (+ 2001 i) 'dark-templar
            (+ (- cx 6.7) (* 0.12 (modulo i 4)))
            (+ cy (if (< i 14) -1.4 1.4))
            #:hp 40.0 #:shield 80.0)))
  (define acts-ready
    (run-l34 rt-p15-far
             (mk-live-obs 'Protoss 'Terran 612
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units ready-dts-27
                          #:enemy-units full-p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-strike shadow-stride))))
  (define ready-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-ready))
  (check-true "L39-T2b-p15-all-27-dts-blink-onto-pf-perimeter-past-6-tanks"
              (and (= (length ready-blinks) 27)
                   (for/and ([c (in-list ready-blinks)])
                     (define d-pf (dist2d-t (+ cx 3.5) cy (fourth c) (fifth c)))
                     (and (>= d-pf 2.8) (<= d-pf 3.9))))
              (format "Expected 27/27 PF-perimeter blinks (2.8..3.9t), got ~a" (length ready-blinks)))

  ;; T2c (`p15` Self-Play pre-fight drop recovery): If DTs did NOT teleport by +12f (still at same pos!),
  ;; plan-dt-blink-pf-snipe retries shadow-stride cleanly instead of locking out for 314f!
  (define acts-retry
    (run-l34 rt-p15-far
             (mk-live-obs 'Protoss 'Terran 624
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units ready-dts-27
                          #:enemy-units full-p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-strike shadow-stride))))
  (define retry-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-retry))
  (check-true "L39-T2c-p15-dropped-prefight-blink-retries-after-12f"
              (= (length retry-blinks) 27)
              (format "Expected 27/27 retry blinks after dropped cast, got ~a" (length retry-blinks)))

  ;; T2d: Once DTs actually teleport >= 3.0t (landed at PF), 314f cooldown activates (0 dup blinks at +32f)!
  (define landed-dts-27
    (for/list ([i (in-range 27)])
      (mk-u (+ 2001 i) 'dark-templar (+ cx 0.4) (+ cy (* 0.15 (- i 13))) #:hp 40.0 #:shield 80.0)))
  (void (run-l34 rt-p15-far
                 (mk-live-obs 'Protoss 'Terran 628
                              #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                              #:ally-units landed-dts-27
                              #:enemy-units full-p15-enemies
                              #:enemy-buildings (cons pf-bldg turrets)
                              #:researched-upgrades '(shadow-strike shadow-stride))))
  ;; Even if pushed back > 4.2t at frame 660 (within 314f CD), 0 duplicate blinks!
  (define acts-on-cd
    (run-l34 rt-p15-far
             (mk-live-obs 'Protoss 'Terran 660
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units ready-dts-27
                          #:enemy-units full-p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-strike shadow-stride))))
  (define cd-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-on-cd))
  (check-true "L39-T2d-p15-confirmed-teleport-promotes-314f-cooldown"
              (null? cd-blinks)
              (format "Expected 0 duplicate blinks during confirmed 314f CD, got ~a" (length cd-blinks))))

;; =============================================================================
;; 3. L39-P0-1c: `t15` Battlecruiser Yamato Cannon Baseline (Zero 'weapon-refit)
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 80.0)
  (define bcs-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 3001 i) 'battlecruiser (- cx 5.0) (+ cy (* 1.2 (- i 1))) #:hp 550.0 #:flying? #t)))
  (define vikings-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 3011 i) 'viking-fighter (- cx 6.2) (+ cy 2.0 (* 0.6 i)) #:hp 135.0 #:flying? #t)))
  (define t15-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 3801 i) 'hydralisk (+ cx 1.5) (+ cy (* 0.5 (- i 2.5))) #:hp 90.0))
     (for/list ([i (in-range 12)]) (mk-u (+ 3821 i) 'corruptor (+ cx 5.5) (+ cy -1.5 (* 0.4 (modulo i 4))) #:hp 200.0 #:flying? #t))
     (for/list ([i (in-range 2)]) (mk-u (+ 3851 i) 'viper (+ cx 6.5) (+ cy 1.5 (* 1.0 i)) #:hp 150.0 #:energy 125.0 #:flying? #t))))
  (define rt-t15 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-t15
    (run-l34 rt-t15
             (mk-live-obs 'Terran 'Zerg 500
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units (append bcs-3 vikings-4)
                          #:enemy-units t15-enemies
                          #:researched-upgrades '())))
  (define yam-casts
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'yamato-cannon))) acts-t15))
  (define yam-targets (remove-duplicates (map fourth yam-casts)))
  (check-true "L39-T3a-t15-all-3-bcs-cast-distinct-yamato-without-weapon-refit"
              (and (= (length yam-casts) 3)
                   (= (length yam-targets) 3)
                   (memv 3851 yam-targets)
                   (memv 3852 yam-targets))
              (format "Expected 3 distinct Yamatos prioritizing Vipers 3851/3852 w/ 0 upgrades, got ~a" yam-casts))

  ;; T3b: Confirmed order 401 promotes full 1590f cooldown (0 dup Yamato at frame 540!)
  (define bcs-channelling
    (for/list ([u (in-list bcs-3)]) (hash-set u 'order-ability-id 401)))
  (void (run-l34 rt-t15
                 (mk-live-obs 'Terran 'Zerg 508
                              #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                              #:ally-units (append bcs-channelling vikings-4)
                              #:enemy-units t15-enemies
                              #:researched-upgrades '())))
  (define acts-t15-cd
    (run-l34 rt-t15
             (mk-live-obs 'Terran 'Zerg 560
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units (append bcs-3 vikings-4)
                          #:enemy-units t15-enemies
                          #:researched-upgrades '())))
  (define cd-yams (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'yamato-cannon))) acts-t15-cd))
  (check-true "L39-T3b-t15-confirmed-401-channel-locks-yamato-1590f-cd"
              (null? cd-yams)
              (format "Expected 0 Yamatos during confirmed 1590f CD, got ~a" cd-yams)))

;; =============================================================================
;; 4. L39-P0-1d: `z14` Infestor NeuralParasite Priority & Approach
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 80.0)
  (define lings-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 4101 i) 'zergling (- cx 3.8) (+ cy (* 0.3 (- i 5.5))) #:hp 35.0)))
  (define infestors-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 4001 i) 'infestor (- cx 5.2) (+ cy (* 0.8 (- i 1))) #:hp 90.0 #:energy 125.0)))
  (define z14-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 4801 i) 'marauder (+ cx 3.8) (+ cy (* 0.4 (- i 2.5))) #:hp 125.0))
     (for/list ([i (in-range 10)]) (mk-u (+ 4821 i) 'marine (+ cx 4.8) (+ cy (* 0.35 (- i 4.5))) #:hp 55.0))
     (list (mk-u 4901 'siege-tank-sieged (+ cx 6.2) (- cy 0.8) #:hp 175.0)
           (mk-u 4902 'siege-tank-sieged (+ cx 6.2) (+ cy 0.8) #:hp 175.0))))
  ;; T4a: At 12.0t from Sieged Tanks, 2 Infestors approach Tanks (`infestor-neural-approach`) & 1 casts Fungal!
  (define z14-dirs-far
    (plan-zerg-spellcaster-micro (append lings-12 infestors-3) z14-enemies
                                 #:claims (make-spell-claims) #:current-frame 500
                                 #:researched-upgrades '(neural-parasite)
                                 #:neural-parasite-researched? #t))
  (define approach-cnt (count (lambda (d) (eq? (spell-directive-pattern-name d) 'infestor-neural-approach)) z14-dirs-far))
  (define fungal-cnt (count (lambda (d) (eq? (spell-directive-ability d) 'fungal-growth)) z14-dirs-far))
  (check-true "L39-T4a-z14-infestors-approach-tanks-and-split-fungal"
              (and (= approach-cnt 2) (= fungal-cnt 1))
              (format "Expected 2 neural-approach + 1 fungal-growth, got approach=~a fungal=~a"
                      approach-cnt fungal-cnt))

  ;; T4b: Once Infestors step to 8.2t from Sieged Tanks, 2 distinct Neural Parasites + 1 Fungal fire!
  (define infestors-3-close
    (for/list ([i (in-range 3)])
      (mk-u (+ 4001 i) 'infestor (- cx 2.0) (+ cy (* 0.8 (- i 1))) #:hp 90.0 #:energy 125.0)))
  (define z14-dirs-close
    (plan-zerg-spellcaster-micro (append lings-12 infestors-3-close) z14-enemies
                                 #:claims (make-spell-claims) #:current-frame 520
                                 #:researched-upgrades '(neural-parasite)
                                 #:neural-parasite-researched? #t))
  (define neural-dirs (filter (lambda (d) (eq? (spell-directive-ability d) 'neural-parasite)) z14-dirs-close))
  (define fungal-close (filter (lambda (d) (eq? (spell-directive-ability d) 'fungal-growth)) z14-dirs-close))
  (check-true "L39-T4b-z14-infestors-cast-2-distinct-neurals-and-1-fungal-in-range"
              (and (= (length neural-dirs) 2)
                   (= (length (remove-duplicates (map spell-directive-target-tag neural-dirs))) 2)
                   (= (length fungal-close) 1))
              (format "Expected 2 distinct Neural + 1 Fungal, got neural=~a fungal=~a"
                      (map spell-directive-target-tag neural-dirs) (length fungal-close)))

  ;; T4c: Without neural-parasite upgrade -> 0 Neural Parasite emitted
  (define z14-dirs-noupg
    (plan-zerg-spellcaster-micro (append lings-12 infestors-3-close) z14-enemies
                                 #:claims (make-spell-claims) #:current-frame 520
                                 #:researched-upgrades '()
                                 #:neural-parasite-researched? #f))
  (check-true "L39-T4c-z14-no-neural-without-upgrade"
              (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'neural-parasite)) z14-dirs-noupg))
              "Must never emit neural-parasite without upgrade"))

;; =============================================================================
;; 5. L39-P0-1e: `z16` Mutalisk Magic-Box vs Thors
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 80.0)
  (define mutas-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 5001 i) 'mutalisk
            (+ (- cx 5.0) (* 0.35 (modulo i 4)))
            (+ cy (* 0.35 (- (quotient i 4) 1.5)))
            #:hp 120.0 #:flying? #t)))
  (define thors-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 5901 i) 'thor (+ cx 4.5) (+ cy (* 1.5 (- i 1))) #:hp 400.0)))
  (define rt-z16 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-z16-approach
    (run-l34 rt-z16
             (mk-live-obs 'Zerg 'Terran 500
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units mutas-16 #:enemy-units thors-3)))
  (define mb-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move))) acts-z16-approach))
  (define mb-atks (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit))) acts-z16-approach))
  (define min-pair-dist
    (for/fold ([md +inf.0]) ([i (in-range (length mb-moves))])
      (define a (list-ref mb-moves i))
      (for/fold ([m md]) ([j (in-range (add1 i) (length mb-moves))])
        (define b (list-ref mb-moves j))
        (min m (dist2d-t (third a) (fourth a) (third b) (fourth b))))))
  (check-true "L39-T5a-z16-all-16-mutas-spread-move-over-thor-zero-clump-attack"
              (and (= (length mb-moves) 16)
                   (null? mb-atks)
                   (>= min-pair-dist 1.0))
              (format "moves=~a atks=~a min-slot-dist=~a" (length mb-moves) (length mb-atks) min-pair-dist))

  ;; T5b: Positioned spread Mutas over Thor emit hold-position; critically wounded (< 32 HP) kites!
  (define spread-mutas
    (for/list ([a (in-list mb-moves)] [i (in-naturals)])
      (mk-u (second a) 'mutalisk (third a) (fourth a)
            #:hp (if (= i 0) 24.0 120.0) #:max-hp 120.0 #:flying? #t)))
  (define acts-z16-over
    (run-l34 rt-z16
             (mk-live-obs 'Zerg 'Terran 540
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units spread-mutas #:enemy-units thors-3)))
  (define mb-holds (filter (lambda (a) (and (pair? a) (eq? (car a) 'hold-position))) acts-z16-over))
  (define mb-kites (filter (lambda (a) (and (pair? a) (eq? (car a) 'kite))) acts-z16-over))
  (check-true "L39-T5b-z16-positioned-mutas-hold-position-and-wounded-kites"
              (and (>= (length mb-holds) 12) (= (length mb-kites) 1))
              (format "holds=~a kites=~a" (length mb-holds) (length mb-kites)))

  ;; T5c: < 6 Mutalisks does NOT trigger Magic-Box
  (check-true "L39-T5c-small-muta-pack-skips-magic-box"
              (null? (plan-mutalisk-magic-box (take mutas-16 4) thors-3))
              "Fewer than 6 Mutalisks must not trigger Magic-Box"))

;; =============================================================================
;; 6. L39-P0-1f: `e03`/`e04` Mineral-Defense Evac + `#72` Anti-Decoy Home Tether
;; =============================================================================
(let ()
  ;; T6a (`e03`): 16 SCVs + 2 Marines vs 3 Adepts -> 0 worker melee pull, 0 SCV-on-SCV repair,
  ;; and close/wounded SCVs mineral-walk to distributed far patches!
  (define main-cc (mk-u 6000 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 6101 i) 'scv
            (+ 27.5 (* 0.2 (modulo i 2)))
            (+ 28.0 (* 0.65 i))
            #:hp (if (< i 4) 22.0 45.0) #:max-hp 45.0)))
  (define marines-2
    (list (mk-u 6201 'marine 31.0 30.0 #:hp 45.0)
          (mk-u 6202 'marine 31.0 31.0 #:hp 45.0)))
  (define adepts-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 6901 i) 'adept 29.8 (+ 28.5 (* 0.5 i)) #:hp 70.0 #:shield 70.0)))
  (define rt-e03 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-e03-l2
    (step-layer2-economy!
     rt-e03
     (mk-live-obs 'Terran 'Protoss 1800 #:minerals 150 #:gas 0 #:supply-used 18 #:supply-cap 23
                  #:ally-units (append scvs-16 marines-2) #:ally-buildings (list main-cc)
                  #:enemy-units adepts-3 #:mineral-patches main-mps)))
  (define e03-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-e03-l2))
  (define e03-evacs (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-e03-l2))
  (define e03-evac-patches (remove-duplicates (filter (lambda (id) (> id 0)) (map third e03-evacs))))
  (check-true "L39-T6a-e03-zero-scv-suicide-pull-and-distributed-mineral-walk-evac"
              (and (null? e03-pulls)
                   (>= (length e03-evacs) 4)
                   (>= (length e03-evac-patches) 2))
              (format "pulls=~a evacs=~a distinct-patches=~a"
                      (length e03-pulls) (length e03-evacs) e03-evac-patches))

  ;; T6b (`e04`): 14 Probes (3 wounded <= 20 EHP) + 1 Zealot vs 6 Speedlings ->
  ;; wounded Probes mineral-walk out, ONLY healthy Probes pulled!
  (define main-nexus (mk-u 6500 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define probes-14-w
    (for/list ([i (in-range 14)])
      (mk-u (+ 6601 i) 'probe 28.5 (+ 28.5 (* 0.5 i))
            #:hp (if (< i 3) 18.0 20.0) #:max-hp 20.0
            #:shield (if (< i 3) 0.0 20.0) #:max-shield 20.0)))
  (define lings-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 6801 i) 'zergling 32.5 (+ 29.5 (* 0.4 i)) #:hp 35.0)))
  (define rt-e04 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-e04-l2
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1800 #:minerals 150 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons (mk-u 6701 'zealot 33.5 31.0 #:hp 100.0 #:shield 50.0) probes-14-w)
                  #:ally-buildings (list main-nexus)
                  #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define e04-evac-wids (map second (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-e04-l2)))
  (define e04-pull-wids
    (append* (for/list ([a (in-list acts-e04-l2)]
                        #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
               (second a))))
  (check-true "L39-T6b-e04-wounded-probes-mineral-walk-evac-and-not-pulled"
              (and (memv 6601 e04-evac-wids)
                   (memv 6602 e04-evac-wids)
                   (memv 6603 e04-evac-wids)
                   (not (ormap (lambda (w) (memv w '(6601 6602 6603))) e04-pull-wids))
                   (>= (length e04-pull-wids) 3)
                   (<= (length e04-pull-wids) 5))
              (format "evac-wids=~a pull-wids=~a" e04-evac-wids e04-pull-wids))

  ;; T6c (`#72` Anti-Decoy Early Home Tether): Lone Zealot ignores mid-map decoy Ling when main is breached!
  (define rt-m72 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define zealot-1 (mk-u 7001 'zealot 48.0 42.0 #:hp 100.0 #:shield 50.0))
  (define decoy-ling (mk-u 7900 'zergling 56.0 54.0 #:hp 35.0))
  (define main-breach-ling (mk-u 7901 'zergling 35.0 34.0 #:hp 35.0))
  (define acts-m72-breach
    (run-l34 rt-m72
             (mk-live-obs 'Protoss 'Zerg 3000 #:supply-used 20 #:supply-cap 23
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 50.0 #:nat-y 34.0
                          #:ally-units (list zealot-1)
                          #:ally-buildings (list main-nexus)
                          #:enemy-units (list decoy-ling main-breach-ling))))
  (check-true "L39-T6c-m72-zealot-attacks-main-breacher-not-decoy-ling"
              (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                                      (= (second a) 7001) (= (third a) 7901)))
                     acts-m72-breach)
              (format "Expected Zealot 7001 -> main breacher 7901, got ~a" acts-m72-breach))

  ;; And with ONLY a distant decoy Ling (> 18t from main & natural), lone Zealot tethers at choke!
  (define far-decoy-ling (mk-u 7909 'zergling 82.0 82.0 #:hp 35.0))
  (define acts-m72-decoy-only
    (run-l34 rt-m72
             (mk-live-obs 'Protoss 'Zerg 3040 #:supply-used 20 #:supply-cap 23
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 50.0 #:nat-y 34.0
                          #:ally-units (list (mk-u 7001 'zealot 40.0 34.0 #:hp 100.0 #:shield 50.0))
                          #:ally-buildings (list main-nexus)
                          #:enemy-units (list far-decoy-ling))))
  (check-true "L39-T6c-m72-lone-zealot-never-chases-distant-decoy-midmap"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (third a) 7909)))
                          acts-m72-decoy-only))
              (format "Zealot must NOT chase distant decoy 7909, got ~a" acts-m72-decoy-only)))

;; =============================================================================
;; 7. L39-P0-1g: `#896` Mid-Fight Home-Retreat Stalemate Guard
;; =============================================================================
(let ()
  (define rt-g (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  ;; 2 healthy Stalkers at (80, 80) fighting 9 Zerglings at (92.5, 80) (12.5t > threat-r 11.0t,
  ;; far from home regroup (58.5, 34.5), suppressed by outnumbered Lanchester prediction!)
  (define stalkers-2
    (list (mk-u 8001 'stalker 80.0 79.5 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0 #:weapon-cooldown 0.0)
          (mk-u 8002 'stalker 80.0 80.5 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0 #:weapon-cooldown 0.0)))
  (define lings-9
    (for/list ([i (in-range 9)])
      (mk-u (+ 8901 i) 'zergling 92.5 (+ 78.0 (* 0.5 i)) #:hp 35.0)))
  (define acts-g
    (run-l34 rt-g
             (mk-live-obs 'Protoss 'Zerg 5000 #:supply-used 24 #:supply-cap 40
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 58.5 #:nat-y 34.5
                          #:ally-units stalkers-2
                          #:ally-buildings (list (mk-u 8500 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
                          #:enemy-units lings-9)))
  (define home-moves
    (filter (lambda (a)
              (and (pair? a) (eq? (car a) 'move) (memv (second a) '(8001 8002))
                   (< (dist2d-t (third a) (fourth a) 58.5 34.5) 10.0)))
            acts-g))
  (define reengage-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(8001 8002))))
            acts-g))
  (check-true "L39-T7a-healthy-engaged-stalkers-never-flee-home-into-stalemate"
              (and (null? home-moves) (= (length reengage-atks) 2))
              (format "Expected 0 home-retreat moves & 2 re-engage attacks, got moves=~a atks=~a"
                      home-moves reengage-atks)))

(printf "\nL39 Tactics + Runtime Regression Summary: ~a passed, ~a failed\n" pass-cnt fail-cnt)
(unless (zero? fail-cnt)
  (exit 1))
