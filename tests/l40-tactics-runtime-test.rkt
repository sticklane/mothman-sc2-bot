#lang racket/base

;; =============================================================================
;; `tests/l40-tactics-runtime-test.rkt`
;; Loop 40 (`L40-P0-1`, `#916`/`#919`) Runtime & Tactics Regression Suite:
;;   1. `L40-P0-1a` (`baseline_h2h` Ship-Gate Fix): Gate `mid-fight-clash-engaged?`
;;      so outnumbered squads / lone Zealots with live base + production cleanly
;;      retreat & regroup home, while Arena 2.0 (0 TH / 0 prod) and >=0.72x parity
;;      clashes still commit without retreating into stalemates!
;;   2. `L40-P0-1b` (`r02` / `r05` `rush_probe` Killer): Gate 3rd SCV repair loop
;;      (`damaged-mech`) against >=10-worker pure all-ins (`0` `3685` repair!),
;;      suppress `3666` `worker-drill-stack-attack` inside `<= 6.0t`, cap disengage
;;      at `<= 1` worker (`<= 10` HP), and focus-fire all defenders via `23`!
;;   3. `L40-P0-1c` (`p15` DT Blink N/S/E Flank + Cloaked `move 16`): From spawn
;;      (`x = cx - 7.2`) behind WEST Hellbat/Bio screen, DTs cloaked-flank (`move`)
;;      around North/South instead of blinking onto WEST rim into Hellbats; once
;;      `<= 7.65t` of N/S/E PF rim slots, all 27 cast ShadowStride strictly onto
;;      the N/S/E PF perimeter away from the screen!
;;   4. `L40-P0-1d` (`t15` Single-Emitter BC Yamato + `weapon-refit` + `52f` Lock):
;;      Restore `weapon-refit` (`76`) check, enforce `<= 10.0t` cast range, NEVER
;;      emit same-tick `attack-unit` alongside `401`, lock channeling BCs (`order
;;      401` / `52f`) in `snipe-locked-tags`/`wave3-handled-tags`, and remove
;;      duplicate synthetic emitter!
;;   5. `L40-P0-1e` (`z14` Infestor Neural Self-Claim Fix): Infestor #1 & #3 hold
;;      and renew their OWN `neural-approach` claims across ticks 1 -> 2 -> 3 (no
;;      self-block fallthrough to Fungal!) and fire 2 distinct `NeuralParasite (249)`
;;      once `<= 9.0t` while Infestor #2 Fungals Bio!
;;   6. `L40-P0-1f` (`e01..e04` Econ-Harass + `#16` Overseer AA Leash):
;;      - `e01` persists `light-harass-def-wids` into `cur-rush-fighting-wids` on
;;        refractory ticks (zero `3666` ping-pong!);
;;      - `e02` leased `inject-queen` shoots Reapers `<= 12.0t` + wounded Drone slides;
;;      - `e03` `<= 6.5t` Adept evac keeps collision-free mineral-walk (`patch-id > 0`);
;;      - `e04` pulls `5` Probes + Zealot w/ synchronized `attack-unit` focus-fire &
;;        persists `'breach-def-wids` across ticks;
;;      - `#16` Overseer pulls immediately out of Marine/Thor/Mine AA fire even with
;;        `>= 3` allied combat units nearby!
;; =============================================================================

(require racket/list
         racket/math
         "../lib/sc2-game-constants.rkt"
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
;; 1. L40-P0-1a: `baseline_h2h` Ship-Gate Fix (`mid-fight-clash-engaged?` Gate)
;; =============================================================================
(let ()
  (define prod-base-p
    (list (mk-u 100 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 101 'gateway 38.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 102 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0)))

  ;; T1a: Lone Zealot (`#03 PvP` / `#04 PvT` smoking gun!) outside natural with live Nexus+Gateways
  ;; facing 7 Stalkers + Immortal at 12.5t MUST retreat/regroup — NEVER suicide-charge!
  (define rt-z (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define lone-zealot (mk-u 1001 'zealot 85.0 80.0 #:hp 100.0 #:shield 50.0))
  (define big-p-army
    (cons (mk-u 1900 'immortal 97.5 80.0 #:hp 200.0 #:shield 100.0)
          (for/list ([i (in-range 7)])
            (mk-u (+ 1901 i) 'stalker 97.5 (+ 77.5 (* 0.7 i)) #:hp 80.0 #:shield 80.0))))
  (define acts-z
    (run-l34 rt-z
             (mk-live-obs 'Protoss 'Protoss 7000 #:supply-used 46 #:supply-cap 62
                          #:ally-units (list lone-zealot)
                          #:ally-buildings prod-base-p
                          #:enemy-units big-p-army)))
  (define z-suicide?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 1001))) acts-z))
  (define z-retreats?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(move kite)) (= (second a) 1001))) acts-z))
  (check-true "L40-T1a-h2h-lone-zealot-with-live-base-retreats-not-suicide-charge"
              (and (not z-suicide?) z-retreats?)
              (format "Expected lone Zealot retreat/regroup, got ~a" acts-z))

  ;; T1b: Outnumbered ranged squad (3 Stalkers = 525 val vs 10 Stalkers + 2 Immortals = 2500 val,
  ;; 0.21x < 0.72x!) at 12.8t (> threat-r 11.0t) with live Nexus+Gateway MUST move regroup home,
  ;; NEVER turn back around into enemy fire!
  (define rt-r (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define small-stalkers
    (for/list ([i (in-range 3)])
      (mk-u (+ 1101 i) 'stalker 85.0 (+ 79.0 (* 0.8 i)) #:hp 80.0 #:shield 80.0 #:weapon-cooldown 0.8)))
  (define huge-enemy
    (append
     (list (mk-u 1950 'immortal 97.8 79.5 #:hp 200.0 #:shield 100.0)
           (mk-u 1951 'immortal 97.8 80.5 #:hp 200.0 #:shield 100.0))
     (for/list ([i (in-range 10)])
       (mk-u (+ 1960 i) 'stalker 97.8 (+ 77.0 (* 0.6 i)) #:hp 80.0 #:shield 80.0))))
  (define acts-r
    (run-l34 rt-r
             (mk-live-obs 'Protoss 'Protoss 7500 #:supply-used 52 #:supply-cap 66
                          #:ally-units small-stalkers
                          #:ally-buildings prod-base-p
                          #:enemy-units huge-enemy)))
  (define r-turnaround-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(1101 1102 1103)))) acts-r))
  (define r-regroup-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(1101 1102 1103)))) acts-r))
  (check-true "L40-T1b-h2h-outnumbered-ranged-squad-regroups-home-past-threat-r"
              (and (null? r-turnaround-atks) (= (length r-regroup-moves) 3))
              (format "Expected 0 turn-around attacks & 3 regroup moves, got atks=~a moves=~a"
                      r-turnaround-atks r-regroup-moves))

  ;; T1c: Arena 2.0 / 0-TownHall skirmish STILL preserves `mid-fight-clash-engaged?` (0 home retreat)!
  (define rt-arena (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-arena
    (run-l34 rt-arena
             (mk-live-obs 'Protoss 'Protoss 7500 #:supply-used 6 #:supply-cap 20
                          #:ally-units small-stalkers
                          #:ally-buildings '()
                          #:enemy-units huge-enemy)))
  (define arena-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(1101 1102 1103)))) acts-arena))
  (check-true "L40-T1c-arena-zero-townhall-still-commits-no-stalemate"
              (= (length arena-atks) 3)
              (format "Expected 3 Arena re-engage attacks with 0 TH, got ~a" acts-arena)))

;; =============================================================================
;; 2. L40-P0-1b: `r02` / `r05` `rush_probe` Killer (3rd SCV Repair + 3666 Guard)
;; =============================================================================
(let ()
  (define main-cc (mk-u 2000 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 2101 i) 'scv
            (+ 28.5 (* 0.35 (modulo i 4)))
            (+ 30.0 (* 0.6 (quotient i 4)))
            #:hp (cond [(< i 4) 8.0] [(< i 8) 22.0] [else 45.0])
            #:max-hp 45.0)))
  (define probes-15
    (for/list ([i (in-range 15)])
      (mk-u (+ 2901 i) 'probe (+ 30.2 (* 0.15 (modulo i 5))) (+ 31.0 (* 0.15 (quotient i 5)))
            #:hp (if (= i 0) 10.0 20.0) #:shield (if (= i 0) 0.0 20.0))))

  ;; T2a: Full L3/L4 `l34-phase5a` 3rd SCV repair loop emits ZERO `repair` (`3685`) under 15-Probe all-in!
  (define rt-r05 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-r05
    (mk-live-obs 'Terran 'Protoss 1200 #:minerals 200 #:gas 0 #:supply-used 16 #:supply-cap 23
                 #:ally-units scvs-16 #:ally-buildings (list main-cc)
                 #:enemy-units probes-15 #:mineral-patches main-mps))
  (define acts-l34-r05 (run-l34 rt-r05 obs-r05))
  (define l34-repairs
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'repair))) acts-l34-r05))
  (check-true "L40-T2a-r05-third-scv-repair-loop-emits-zero-3685-under-15probe-allin"
              (null? l34-repairs)
              (format "Expected 0 L3/L4 SCV repair commands in r05, got ~a" l34-repairs))

  ;; T2b: L2 heavy pure worker all-in caps disengage at <= 1 (`<= 10` HP), emits ZERO `3666`
  ;; `worker-drill-stack-attack` inside `<= 6.0t`, and focuses ALL 15 fighting SCVs via direct `23`!
  (define acts-l2-r05 (step-layer2-economy! rt-r05 obs-r05))
  (define l2-drills (filter (lambda (a) (and (pair? a) (eq? (car a) 'worker-drill-stack-attack))) acts-l2-r05))
  (define l2-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-l2-r05))
  (define l2-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-l2-r05))
  (define pulled-tags (remove-duplicates (append* (map second l2-pulls))))
  (define all-direct-unit-targets?
    (and (pair? l2-pulls)
         (for/and ([p (in-list l2-pulls)])
           (and (>= (length p) 5) (exact-integer? (third p)) (> (third p) 0)))))
  (check-true "L40-T2b-r05-zero-drill-cap-1-disengage-and-direct-focus-fire-23"
              (and (null? l2-drills)
                   (<= (length l2-mws) 1)
                   (>= (length pulled-tags) 15)
                   all-direct-unit-targets?)
              (format "drills=~a mws=~a pulled=~a direct-targets?=~a pulls=~a"
                      (length l2-drills) (length l2-mws) (length pulled-tags) all-direct-unit-targets? l2-pulls))

  ;; T2c: Negative guard — damaged Siege Tank with 3 enemy probes STILL gets L3/L4 SCV repair!
  (define rt-mech (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define dmg-tank (mk-u 2500 'siege-tank-sieged 31.0 32.0 #:hp 90.0 #:max-hp 175.0))
  (define acts-mech
    (run-l34 rt-mech
             (mk-live-obs 'Terran 'Protoss 4000 #:minerals 200 #:gas 0 #:supply-used 20 #:supply-cap 30
                          #:ally-units (cons dmg-tank (take scvs-16 4))
                          #:ally-buildings (list main-cc)
                          #:enemy-units (take probes-15 3))))
  (check-true "L40-T2c-damaged-siege-tank-still-repaired-by-scv"
              (ormap (lambda (a)
                       (and (pair? a)
                            (or (and (eq? (car a) 'repair) (= (third a) 2500))
                                (and (eq? (car a) 'cast-spell) (>= (length a) 4)
                                     (eq? (caddr a) 'repair) (= (fourth a) 2500)))))
                     acts-mech)
              (format "Expected SCV repair on Tank 2500, got ~a" acts-mech)))

;; =============================================================================
;; 3. L40-P0-1c: `p15` DT Blink N/S/E Flank + Cloaked `move 16`
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
  ;; Exact `p15` spawn coordinates (`x = cx - 7.2`, `y = cy +- 1.5`)!
  (define spawn-dts-27
    (append
     (for/list ([i (in-range 14)])
       (mk-u (+ 3001 i) 'dark-templar (- cx 7.2) (+ (- cy 1.5) (* 0.12 (modulo i 4))) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 13)])
       (mk-u (+ 3020 i) 'dark-templar (- cx 7.2) (+ (+ cy 1.5) (* 0.12 (modulo i 4))) #:hp 40.0 #:shield 80.0))))

  ;; T3a: At exact `p15` spawn (`d_pf = 10.8t`), ALL 27 DTs emit cloaked flanking `move (16)`
  ;; around North/South of the Hellbat/Bio screen (`0` premature WEST-rim blinks, `0` suicide `23`!)
  (define rt-p15 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-spawn
    (run-l34 rt-p15
             (mk-live-obs 'Protoss 'Terran 600
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units spawn-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-stride))))
  (define sp-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move))) acts-spawn))
  (define sp-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-spawn))
  (define sp-atks (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit))) acts-spawn))
  (check-true "L40-T3a-p15-spawn-dts-cloaked-flank-move-16-zero-west-blink"
              (and (= (length sp-moves) 27) (null? sp-blinks) (null? sp-atks))
              (format "Expected 27 cloaked moves, 0 blinks, 0 attacks; got moves=~a blinks=~a atks=~a"
                      (length sp-moves) (length sp-blinks) (length sp-atks)))

  ;; T3b: Once DTs reach their cloaked flank launch waypoints (`x = cx - 3.1, y = cy +- 3.0`),
  ;; ALL 27 blink onto the N/S/E PF rim strictly EAST of the Hellbat/Bio wall (`bx >= cx + 1.8`)!
  (define flank-dts-27
    (append
     (for/list ([i (in-range 14)])
       (mk-u (+ 3001 i) 'dark-templar (- cx 3.1) (- cy 3.0) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 13)])
       (mk-u (+ 3020 i) 'dark-templar (- cx 3.1) (+ cy 3.0) #:hp 40.0 #:shield 80.0))))
  (define acts-flank
    (run-l34 rt-p15
             (mk-live-obs 'Protoss 'Terran 620
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units flank-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (cons pf-bldg turrets)
                          #:researched-upgrades '(shadow-stride))))
  (define fl-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-flank))
  (define all-nse-clear-of-hellbats?
    (for/and ([b (in-list fl-blinks)])
      (define bx (fourth b))
      (define by (fifth b))
      (define d-pf (dist2d-t (+ cx 3.5) cy bx by))
      (and (>= bx (+ cx 1.8)) (>= (abs (- by cy)) 2.4) (>= d-pf 2.85) (<= d-pf 3.7))))
  (check-true "L40-T3b-p15-all-27-dts-blink-onto-nse-pf-rim-clear-of-hellbats"
              (and (= (length fl-blinks) 27) all-nse-clear-of-hellbats?)
              (format "blinks=~a sample=~a" (length fl-blinks) (take fl-blinks (min 3 (length fl-blinks))))))

;; =============================================================================
;; 4. L40-P0-1d: `t15` Single-Emitter BC Yamato + `weapon-refit` + `52f` Channel Lock
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 80.0)
  (define bcs-3-far
    (for/list ([i (in-range 3)])
      (mk-u (+ 4001 i) 'battlecruiser (- cx 5.0) (+ cy (* 1.2 (- i 1))) #:hp 550.0 #:flying? #t)))
  (define bcs-3-inrange
    (for/list ([i (in-range 3)])
      (mk-u (+ 4001 i) 'battlecruiser (- cx 3.0) (+ cy (* 1.2 (- i 1))) #:hp 550.0 #:flying? #t)))
  (define t15-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 4801 i) 'hydralisk (+ cx 1.5) (+ cy (* 0.5 (- i 2.5))) #:hp 90.0))
     (for/list ([i (in-range 12)]) (mk-u (+ 4821 i) 'corruptor (+ cx 5.5) (+ cy -1.5 (* 0.4 (modulo i 4))) #:hp 200.0 #:flying? #t))
     (for/list ([i (in-range 2)]) (mk-u (+ 4851 i) 'viper (+ cx 6.5) (+ cy 1.5 (* 1.0 i)) #:hp 150.0 #:energy 125.0 #:flying? #t))))

  ;; T4a: Without `weapon-refit` (`76`) -> ZERO Yamato casts (prevents silent SC2 rejects & fixes `novel-122`!)
  (define rt-noupg (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-noupg
    (run-l34 rt-noupg
             (mk-live-obs 'Terran 'Zerg 500
                          #:ally-units bcs-3-inrange #:enemy-units t15-enemies
                          #:researched-upgrades '())))
  (check-true "L40-T4a-t15-zero-yamato-without-weapon-refit"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'yamato-cannon))) acts-noupg))
              (format "Expected 0 Yamatos without weapon-refit, got ~a" acts-noupg))

  ;; T4b: Beyond `10.0t` (`d = 10.6..11.7t` with `weapon-refit`) -> ZERO out-of-range Yamato cast-walk!
  (define rt-t15 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-far
    (run-l34 rt-t15
             (mk-live-obs 'Terran 'Zerg 500
                          #:ally-units bcs-3-far #:enemy-units t15-enemies
                          #:researched-upgrades '(weapon-refit))))
  (check-true "L40-T4b-t15-no-out-of-range-yamato-above-10t"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'yamato-cannon))) acts-far))
              (format "Expected 0 Yamatos > 10.0t, got ~a" acts-far))

  ;; T4c: Inside `<= 10.0t` with `weapon-refit` -> 3 distinct Yamato casts AND ZERO same-tick
  ;; `attack-unit` overwrites (fixing P0/P2 cancellation!) AND locked for full `52f` channel!
  (define acts-in
    (run-l34 rt-t15
             (mk-live-obs 'Terran 'Zerg 520
                          #:ally-units bcs-3-inrange #:enemy-units t15-enemies
                          #:researched-upgrades '(weapon-refit))))
  (define yams-in (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'yamato-cannon))) acts-in))
  (define bc-same-tick-atks (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(4001 4002 4003)))) acts-in))
  ;; Tick +16 (mid 48-loop channel!): ZERO re-issued `401`, ZERO `attack-unit`, ZERO `move` on channeling BCs!
  (define bcs-chan (for/list ([u (in-list bcs-3-inrange)]) (hash-set u 'order-ability-id 401)))
  (define acts-mid-chan
    (run-l34 rt-t15
             (mk-live-obs 'Terran 'Zerg 536
                          #:ally-units bcs-chan #:enemy-units t15-enemies
                          #:researched-upgrades '(weapon-refit))))
  (define mid-chan-bc-acts
    (filter (lambda (a) (and (pair? a) (>= (length a) 2) (memv (second a) '(4001 4002 4003)))) acts-mid-chan))
  (check-true "L40-T4c-t15-clean-yamato-zero-same-tick-attack-and-52f-channel-lock"
              (and (= (length yams-in) 3)
                   (null? bc-same-tick-atks)
                   (null? mid-chan-bc-acts))
              (format "yams=~a same-tick-atks=~a mid-chan-acts=~a" yams-in bc-same-tick-atks mid-chan-bc-acts)))

;; =============================================================================
;; 5. L40-P0-1e: `z14` Infestor `neural-approach` Self-Claim Fix Across Ticks
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 80.0)
  (define lings-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 5101 i) 'zergling (- cx 3.8) (+ cy (* 0.3 (- i 5.5))) #:hp 35.0)))
  (define z14-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 5801 i) 'marauder (+ cx 3.8) (+ cy (* 0.4 (- i 2.5))) #:hp 125.0))
     (for/list ([i (in-range 10)]) (mk-u (+ 5821 i) 'marine (+ cx 4.8) (+ cy (* 0.35 (- i 4.5))) #:hp 55.0))
     (list (mk-u 5901 'siege-tank-sieged (+ cx 6.2) (- cy 0.8) #:hp 175.0)
           (mk-u 5902 'siege-tank-sieged (+ cx 6.2) (+ cy 0.8) #:hp 175.0))))
  (define shared-claims (make-spell-claims))
  ;; Tick 1 (f=500, d_tank=12.0t): 2 Infestors claim `neural-approach` on Tanks 5901/5902 + 1 Fungals Bio
  (define inf-t1
    (for/list ([i (in-range 3)])
      (mk-u (+ 5001 i) 'infestor (- cx 5.8) (+ cy (* 0.8 (- i 1))) #:hp 90.0 #:energy 125.0)))
  (define d1
    (plan-zerg-spellcaster-micro (append lings-12 inf-t1) z14-enemies
                                 #:claims shared-claims #:current-frame 500
                                 #:researched-upgrades '(neural-parasite)
                                 #:neural-parasite-researched? #t))
  ;; Tick 2 (f=504, 5001 & 5002 stepped 0.8t closer to d_tank=11.2t — STILL inside 12f claim TTL!):
  ;; Previously self-blocked at L2628 and dumped 75e into Fungal! MUST BOTH RENEW `infestor-neural-approach`
  ;; while 5003 casts Fungal on Bio!
  (define inf-t2
    (list (mk-u 5001 'infestor (- cx 5.0) (- cy 0.8) #:hp 90.0 #:energy 125.0)
          (mk-u 5002 'infestor (- cx 5.0) cy #:hp 90.0 #:energy 125.0)
          (mk-u 5003 'infestor (- cx 5.0) (+ cy 0.8) #:hp 90.0 #:energy 125.0)))
  (define d2
    (plan-zerg-spellcaster-micro (append lings-12 inf-t2) z14-enemies
                                 #:claims shared-claims #:current-frame 504
                                 #:researched-upgrades '(neural-parasite)
                                 #:neural-parasite-researched? #t))
  (define t2-approaches (filter (lambda (d) (eq? (spell-directive-pattern-name d) 'infestor-neural-approach)) d2))
  (define t2-fungals (filter (lambda (d) (eq? (spell-directive-ability d) 'fungal-growth)) d2))
  (check-true "L40-T5a-z14-tick2-infestors-renew-own-neural-approach-zero-self-block"
              (and (= (length t2-approaches) 2)
                   (memv 5001 (map spell-directive-caster-tag t2-approaches))
                   (memv 5002 (map spell-directive-caster-tag t2-approaches))
                   (= (length t2-fungals) 1))
              (format "Tick 1=~a | Tick 2 approaches=~a fungals=~a"
                      (map spell-directive-pattern-name d1)
                      (map spell-directive-caster-tag t2-approaches)
                      t2-fungals))

  ;; Tick 3 (f=520, 5001 & 5002 stepped into <= 8.5t range of both Sieged Tanks): BOTH fire `neural-parasite` (249)!
  (define inf-t3
    (list (mk-u 5001 'infestor (- cx 2.3) (- cy 0.8) #:hp 90.0 #:energy 125.0)
          (mk-u 5002 'infestor (- cx 2.3) cy #:hp 90.0 #:energy 125.0)
          (mk-u 5003 'infestor (- cx 5.8) (+ cy 0.8) #:hp 90.0 #:energy 55.0)))
  (define d3
    (plan-zerg-spellcaster-micro (append lings-12 inf-t3) z14-enemies
                                 #:claims shared-claims #:current-frame 520
                                 #:researched-upgrades '(neural-parasite)
                                 #:neural-parasite-researched? #t))
  (define t3-neurals (filter (lambda (d) (eq? (spell-directive-ability d) 'neural-parasite)) d3))
  (check-true "L40-T5b-z14-tick3-both-approaching-infestors-fire-distinct-neural-249"
              (and (= (length t3-neurals) 2)
                   (= (length (remove-duplicates (map spell-directive-target-tag t3-neurals))) 2))
              (format "Expected 2 distinct NeuralParasite casts, got ~a"
                      (map (lambda (d) (list (spell-directive-caster-tag d) (spell-directive-target-tag d))) t3-neurals))))

;; =============================================================================
;; 6. L40-P0-1f: `e01..e04` Mineral-Defense + `#16` Overseer AA Leash
;; =============================================================================
(let ()
  ;; T6a (`e02`): Leased `inject-queen` next to Hatchery shoots 2 Reapers <= 12.0t (`attack-unit`!),
  ;; and wounded Drone (<= 24 HP) slides via `mineral-walk` while healthy Drones keep mining!
  (define main-hatch (mk-u 6000 'hatchery 32.5 32.5 #:hp 1500.0))
  (define drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 6101 i) 'drone 28.5 (+ 28.0 (* 0.6 i))
            #:hp (if (= i 0) 20.0 40.0) #:max-hp 40.0)))
  (define queen-1 (mk-u 6201 'queen 33.0 34.0 #:hp 175.0 #:energy 10.0))
  (define reapers-2
    (list (mk-u 6901 'reaper 31.0 30.0 #:hp 60.0)
          (mk-u 6902 'reaper 31.5 31.0 #:hp 60.0)))
  ;; Tick 1: L2 with Queen at 25 energy injects Hatchery and acquires real `inject-queen` lease!
  (define rt-e02 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (void (step-layer2-economy!
         rt-e02
         (mk-live-obs 'Zerg 'Terran 1000 #:minerals 150 #:gas 0 #:supply-used 18 #:supply-cap 22
                      #:ally-units (cons (hash-set queen-1 'energy 25.0) drones-16)
                      #:ally-buildings (list main-hatch)
                      #:enemy-units '() #:mineral-patches main-mps)))
  ;; Tick 2: Reapers enter <= 12.0t while Queen still holds active `inject-queen` lease -> MUST shoot!
  (define obs-e02
    (mk-live-obs 'Zerg 'Terran 1020 #:minerals 150 #:gas 0 #:supply-used 18 #:supply-cap 22
                 #:ally-units (cons queen-1 drones-16)
                 #:ally-buildings (list main-hatch)
                 #:enemy-units reapers-2 #:mineral-patches main-mps))
  (define acts-e02-l34 (run-l34 rt-e02 obs-e02))
  (define acts-e02-l2 (step-layer2-economy! rt-e02 obs-e02))
  (define queen-shoots-reaper?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 6201) (memv (third a) '(6901 6902))))
           acts-e02-l34))
  (define e02-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-e02-l2))
  (define e02-mw-wids (remove-duplicates (map second e02-mws)))
  (check-true "L40-T6a-e02-leased-queen-shoots-reapers-and-only-wounded-drone-slides"
              (and queen-shoots-reaper? (equal? e02-mw-wids '(6101)))
              (format "queen-atk?=~a mw-wids=~a mws=~a" queen-shoots-reaper? e02-mw-wids e02-mws))

  ;; T6b (`e03`): Adepts at `5.8t` (`<= 6.5t`) trigger SCV collision-free mineral-walk (`patch-id > 0`!)
  (define main-cc (mk-u 6500 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-16-e03
    (for/list ([i (in-range 16)])
      (mk-u (+ 6601 i) 'scv 27.8 (+ 28.0 (* 0.6 i)) #:hp 45.0 #:max-hp 45.0)))
  (define adepts-3-mid
    (for/list ([i (in-range 3)])
      (mk-u (+ 6951 i) 'adept 33.4 (+ 30.5 (* 0.5 i)) #:hp 70.0 #:shield 70.0)))
  (define rt-e03 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-e03
    (step-layer2-economy!
     rt-e03
     (mk-live-obs 'Terran 'Protoss 1400 #:minerals 150 #:gas 0 #:supply-used 18 #:supply-cap 23
                  #:ally-units (append scvs-16-e03 (list (mk-u 6701 'marine 31.0 30.0 #:hp 45.0)
                                                         (mk-u 6702 'marine 31.0 31.0 #:hp 45.0)))
                  #:ally-buildings (list main-cc)
                  #:enemy-units adepts-3-mid #:mineral-patches main-mps)))
  (define e03-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-e03))
  (check-true "L40-T6b-e03-adept-6.5t-triggers-collision-free-mineral-walk-patch"
              (and (>= (length e03-mws) 4)
                   (for/and ([m (in-list e03-mws)]) (> (third m) 0)))
              (format "e03 mws=~a" e03-mws))

  ;; T6c (`e04`): 14 Probes + 1 Zealot vs 6 Speedlings pulls 5 Probes with synchronized `attack-unit`
  ;; target tag (`> 0`) and ZERO `worker-drill-stack-attack`!
  (define main-nex (mk-u 7000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define probes-14
    (for/list ([i (in-range 14)])
      (mk-u (+ 7101 i) 'probe 28.5 (+ 28.0 (* 0.6 i)) #:hp 20.0 #:shield 20.0)))
  (define lings-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 7801 i) 'zergling 32.0 (+ 29.5 (* 0.4 i)) #:hp (if (= i 0) 15.0 35.0))))
  (define rt-e04 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-e04
    (step-layer2-economy!
     rt-e04
     (mk-live-obs 'Protoss 'Zerg 1400 #:minerals 150 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons (mk-u 7201 'zealot 33.5 31.0 #:hp 100.0 #:shield 50.0) probes-14)
                  #:ally-buildings (list main-nex)
                  #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define e04-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-e04))
  (define e04-drills (filter (lambda (a) (and (pair? a) (eq? (car a) 'worker-drill-stack-attack))) acts-e04))
  (check-true "L40-T6c-e04-pulls-5-probes-synchronized-focus-fire-zero-drill"
              (and (= (length e04-pulls) 1)
                   (= (length (second (car e04-pulls))) 5)
                   (= (third (car e04-pulls)) 7801)
                   (null? e04-drills))
              (format "pulls=~a drills=~a" e04-pulls e04-drills))

  ;; T6d (`#16` Overseer AA Leash): Overseer hovering over friendly army inside Marine/Thor AA
  ;; range (`5.0t`) IMMEDIATELY retreats away from AA EVEN WITH >= 3 allied combat units nearby!
  (define rt-ov (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define ov-u (mk-u 8001 'overseer 80.0 80.0 #:hp 200.0 #:flying? #t))
  (define hydras-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 8101 i) 'hydralisk 79.0 (+ 78.0 (* 0.8 i)) #:hp 90.0)))
  (define marines-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 8901 i) 'marine 85.0 (+ 78.0 (* 0.5 i)) #:hp 55.0)))
  (define acts-ov
    (run-l34 rt-ov
             (mk-live-obs 'Zerg 'Terran 9000 #:supply-used 60 #:supply-cap 80
                          #:base-x 32.5 #:base-y 32.5 #:nat-x 55.0 #:nat-y 35.0
                          #:ally-units (cons ov-u hydras-6)
                          #:ally-buildings (list main-hatch)
                          #:enemy-units marines-8)))
  (define ov-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 8001))) acts-ov))
  (check-true "L40-T6d-m16-overseer-pulls-out-of-marine-aa-even-with-6-allies-near"
              (and ov-move (< (third ov-move) 78.0))
              (format "Expected Overseer 8001 retreat away from Marines (x < 78.0), got ~a" ov-move))

  ;; T6e (`e01` refractory ping-pong fix): Defending Probes pulled on tick 1 (`f=800`) remain
  ;; locked in `cur-rush-fighting-wids` on refractory tick 2 (`f=804`, zero `harvest-mineral` yank!)
  (define probes-12-e01
    (for/list ([i (in-range 12)])
      (mk-u (+ 8501 i) 'probe 28.5 (+ 28.5 (* 0.6 i)) #:hp 20.0 #:shield 20.0)))
  (define enemy-probes-2
    (list (mk-u 8951 'probe 33.0 31.5 #:hp 20.0 #:shield 20.0)
          (mk-u 8952 'probe 33.0 33.0 #:hp 20.0 #:shield 20.0)))
  (define rt-e01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-e01-t1
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 800 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12-e01 #:ally-buildings (list main-nex)
                  #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define e01-pulled-t1
    (remove-duplicates (append* (for/list ([a (in-list acts-e01-t1)]
                                           #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                                  (second a)))))
  ;; On refractory tick +4 (f=804), pulled defenders MUST NOT be yanked back via `harvest-mineral`!
  (define acts-e01-t2
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 804 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12-e01 #:ally-buildings (list main-nex)
                  #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define yanked-back?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'harvest-mineral) (memv (second a) e01-pulled-t1)))
           acts-e01-t2))
  (check-true "L40-T6e-e01-defending-probes-not-yanked-to-minerals-on-refractory-tick"
              (and (pair? e01-pulled-t1) (<= (length e01-pulled-t1) 2) (not yanked-back?))
              (format "pulled-t1=~a yanked-back-t2?=~a acts-t2=~a" e01-pulled-t1 yanked-back? acts-e01-t2)))

(printf "\nL40 Tactics + Runtime Regression Summary: ~a passed, ~a failed\n" pass-cnt fail-cnt)
(unless (zero? fail-cnt)
  (exit 1))
