#lang racket/base

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt")

;; =============================================================================
;; Loop 42 (`L42-P0-1a..1d`) Tactics + Live-Runtime Regression Suite
;; Covers:
;;   1. `L42-P0-1a` (`r02`/`r05`/`r06` 3-Race `rush_probe` Killer):
;;      - `max-total-dis-heavy-rush = 0` when `hw <= ew + 2` in `>= 11`-worker pure all-in
;;      - Direct melee contact (`<= 1.65t`) priority prevents body-block target churn
;;      - `effective-melee-cap = 8` / `chaser-cap = 6` on primary focus target
;;      - Preserves `10`-Probe Suite 26 critical 10-HP disengage
;;   2. `L42-P0-1b` (`p15` Post-PF North Turret Snipe + SP `>= 2` Damaged Release):
;;      - Post-PF static detector scan widened `11 -> 16t` & works down to `>= 1` DT
;;      - Under-fire alpha-strike releases at `>= 2` damaged ready DTs (`>= 35%` in range)
;;      - Negative guard: `0` damaged DTs still holds until `>= 70%` ready
;;   3. `L42-P0-1c` (`z16` Muta Magic-Box Restoration):
;;      - `MUTA-MAGIC-BOX-MIN-COUNT = 2` keeps 2–5 surviving Mutas spread-locked
;;      - Tightened `slots-r2 = 2.65t` stays inside Mutalisk `3.0t` weapon range
;;      - Spread Mutas (`<= 3.3t` of `best-thor` & `>= 1.35t` ally sep) stay on `HOLD (18)`
;;        even when the Thor shifts (`d-slot > 1.05t`)
;;   4. `L42-P0-1d` (`e03`/`e04` Polish + `#04 PvT` `2–6m` Colossus Staging Guard):
;;      - `e03`: far healthy SCVs (`> 5.9t`) stay mining while close SCVs scatter
;;      - `e04`: breach latch releases Probes at `<= 2` Lings if Zealot alive, holds if dead
;;      - `#04 PvT`: holds 2-base Gateway army while awaiting Colossus #1, releases when
;;        Colossus #1 arrives or under home attack
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
;; 1. L42-P0-1a: `r02`/`r05`/`r06` 3-Race `rush_probe` Killer
;; =============================================================================
(let ()
  (define main-cc (mk-u 1000 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16))
  (define scvs-16-low
    (for/list ([i (in-range 16)])
      (mk-u (+ 1101 i) 'scv
            (+ 29.2 (* 0.3 (modulo i 4)))
            (+ 30.8 (* 0.45 (quotient i 4)))
            #:hp (if (< i 4) 8.0 45.0) #:max-hp 45.0)))
  (define probes-15
    (for/list ([i (in-range 15)])
      (mk-u (+ 1901 i) 'probe (+ 30.6 (* 0.15 (modulo i 5))) (+ 31.2 (* 0.15 (quotient i 5)))
            #:hp (if (= i 0) 20.0 20.0) #:shield (if (= i 0) 15.0 20.0))))

  ;; T1a: 16 SCVs (4 at 8 HP!) vs 15 Probes (`16 <= 15 + 2`, restored `L48-P0-1b` zero-disengage):
  ;; ZERO `mineral-walk` disengages, ZERO `worker-drill-stack-attack`, ALL 16 SCVs commit directly via `pull-workers-attack` (`tid > 0`)!
  (define rt-r05 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-r05
    (step-layer2-economy!
     rt-r05
     (mk-live-obs 'Terran 'Protoss 1200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 15
                  #:ally-units scvs-16-low #:ally-buildings (list main-cc)
                  #:enemy-units probes-15 #:mineral-patches main-mps)))
  (define r05-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-r05))
  (define r05-drills (filter (lambda (a) (and (pair? a) (eq? (car a) 'worker-drill-stack-attack))) acts-r05))
  (define r05-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-r05))
  (define r05-pulled (remove-duplicates (append* (map second r05-pulls))))
  (define r05-primary-grp
    (findf (lambda (a) (and (>= (length a) 5) (= (third a) 1901))) r05-pulls))
  ;; L48-W3 (Fix W3-R1): Static 15-Probe melee cap tightened to `<= 3` per target (`2..3` attackers
  ;; on primary focus #1901) to maximize melee surface-area uptime & eliminate 6-8 body-blocking!
  (check-true "L42-T1a-r05-15probe-allin-zero-disengage-all-16-commit-and-cap3-surface-focus"
              (and (null? r05-mws)
                   (null? r05-drills)
                   (= (length r05-pulled) 16)
                   r05-primary-grp
                   (>= (length (second r05-primary-grp)) 2)
                   (<= (length (second r05-primary-grp)) 3))
              (format "mws=~a drills=~a pulled=~a primary-grp=~a"
                      (length r05-mws) (length r05-drills) (length r05-pulled) r05-primary-grp))

  ;; T1b (`r06` PvP 16 Probes vs 15 Probes): Front-row Probe #1201 directly touching full-HP enemy
  ;; Probe #1960 (`0.8t` away) attacks #1960 (`<= 1.65t` contact!) instead of body-blocking to walk
  ;; `3.1t` back for wounded Probe #1951, with ZERO disengages!
  (define main-nex (mk-u 1050 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16))
  (define ally-probes-16
    (cons (mk-u 1201 'probe 30.0 32.5 #:hp 8.0 #:max-hp 20.0 #:shield 0.0 #:max-shield 20.0)
          (for/list ([i (in-range 1 16)])
            (mk-u (+ 1201 i) 'probe (+ 28.0 (* 0.3 (modulo i 4))) (+ 30.5 (* 0.45 (quotient i 4)))
                  #:hp 20.0 #:shield 20.0))))
  (define enemy-probes-15-r06
    (append
     (list (mk-u 1960 'probe 30.8 32.5 #:hp 20.0 #:shield 20.0)  ;; directly touching #1201 (0.8t!)
           (mk-u 1951 'probe 33.1 32.5 #:hp 10.0 #:shield 0.0))  ;; wounded Probe 3.1t behind front row!
     (for/list ([i (in-range 13)])
       (mk-u (+ 1961 i) 'probe (+ 32.8 (* 0.15 (modulo i 5))) (+ 31.5 (* 0.25 (quotient i 5)))
             #:hp 20.0 #:shield 20.0))))
  (define rt-r06 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-r06
    (step-layer2-economy!
     rt-r06
     (mk-live-obs 'Protoss 'Protoss 1200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 15
                  #:ally-units ally-probes-16 #:ally-buildings (list main-nex)
                  #:enemy-units enemy-probes-15-r06 #:mineral-patches main-mps)))
  (define r06-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-r06))
  (define r06-1201-tgt
    (for/first ([a (in-list acts-r06)]
                #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)
                            (memv 1201 (second a))))
      (third a)))
  (check-true "L42-T1b-r06-pvp-16probes-zero-disengage-and-direct-contact-no-bodyblock"
              (and (null? r06-mws)
                   (= r06-1201-tgt 1960))
              (format "mws=~a p1201-tgt=~a (expected 1960)" (length r06-mws) r06-1201-tgt))

  ;; T1c (Negative guard preserving Suite 26): 12 Drones (1 at 10 HP `#101`) vs 10 Probes (`< 11`)
  ;; STILL disengages critical 10-HP Drone `#101` via `mineral-walk`!
  (define main-hatch (mk-u 1090 'hatchery 32.5 32.5 #:hp 1500.0))
  (define drones-12-s26
    (cons (mk-u 101 'drone 34.5 32.5 #:hp 10.0 #:max-hp 40.0)
          (for/list ([i (in-range 1 12)])
            (mk-u (+ 101 i) 'drone (+ 29.0 (* 0.35 i)) 32.5 #:hp 40.0 #:max-hp 40.0))))
  (define probes-10-s26
    (for/list ([i (in-range 10)])
      (mk-u (+ 1980 i) 'probe (+ 35.5 (* 0.25 i)) 32.5 #:hp 20.0 #:shield 20.0)))
  (define rt-s26 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-s26
    (step-layer2-economy!
     rt-s26
     (mk-live-obs 'Zerg 'Protoss 720 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 14
                  #:ally-units drones-12-s26 #:ally-buildings (list main-hatch)
                  #:enemy-units probes-10-s26 #:mineral-patches main-mps)))
  (check-true "L42-T1c-10probe-rush-still-disengages-10hp-drone-preserving-suite26"
              (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) 101))) acts-s26)
              (format "Expected 10-HP Drone 101 mineral-walk on 10-Probe rush; acts=~a" acts-s26)))

;; =============================================================================
;; 2. L42-P0-1b: `p15` Post-PF North Turret Snipe (16t) + SP `>= 2` Damaged Release
;; =============================================================================
(let ()
  (define cx 80.0)
  (define cy 88.0)
  (define pf-bldg (mk-u 2001 'planetary-fortress (+ cx 3.5) cy #:hp 1500.0))
  (define north-turret (mk-u 2003 'missile-turret (+ cx 6.5) (+ cy 2.8) #:hp 250.0))
  (define p15-enemies
    (append
     (for/list ([i (in-range 6)]) (mk-u (+ 2100 i) 'hellbat (- cx 1.2) (+ cy (* 0.4 (- i 2.5))) #:hp 135.0))
     (for/list ([i (in-range 8)]) (mk-u (+ 2120 i) 'marauder (- cx 0.5) (+ cy (* 0.35 (- i 3.5))) #:hp 125.0))
     (for/list ([i (in-range 24)]) (mk-u (+ 2200 i) 'marine (+ cx 0.2) (+ cy (* 0.25 (- i 11.5))) #:hp 55.0))))

  ;; T2a: Post-PF (0 PFs remaining!), only 3 surviving DTs (`< 4`!) on South side `13.5t` away from
  ;; surviving North Missile Turret (`> 11.0t`, `<= 16.0t`) -> ALL 3 DTs immediately target North Turret!
  (define dts-3-postpf
    (for/list ([i (in-range 3)])
      (mk-u (+ 2301 i) 'dark-templar (- cx 3.5) (- cy 6.5 (* 0.3 i)) #:hp 40.0 #:shield 80.0)))
  (define postpf-dirs
    (plan-dt-blink-pf-snipe dts-3-postpf p15-enemies (list north-turret)
                            (make-spell-claims) 700
                            #:shadow-stride-ok? #t))
  (check-true "L42-T2a-p15-post-pf-16t-scan-snipes-distant-north-turret-with-3-dts"
              (and (= (length postpf-dirs) 3)
                   (for/and ([d (in-list postpf-dirs)])
                     (memq (spell-directive-pattern-name d) '(dt-blink-detector-snipe dt-detector-focus-fire))))
              (format "Expected 3 detector-snipe directives at 13.5t; got ~a"
                      (map spell-directive-pattern-name postpf-dirs)))

  ;; T2b: SP under-fire early release — ONLY `2` damaged ready DTs (`< 4`) and `10/27` (`>= 35%`)
  ;; in blink range -> immediately fires synchronized `10`-DT alpha-strike!
  (define sp-2dmg-dts-27
    (append
     (for/list ([i (in-range 5)])
       (mk-u (+ 2401 i) 'dark-templar (- cx 3.1) (- cy 4.8)
             #:hp 40.0 #:max-hp 40.0 #:shield (if (< i 2) 30.0 80.0) #:max-shield 80.0))
     (for/list ([i (in-range 9)])
       (mk-u (+ 2406 i) 'dark-templar (- cx 6.8) (- cy 2.0) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 5)])
       (mk-u (+ 2420 i) 'dark-templar (- cx 3.1) (+ cy 4.8) #:hp 40.0 #:shield 80.0))
     (for/list ([i (in-range 8)])
       (mk-u (+ 2425 i) 'dark-templar (- cx 6.8) (+ cy 2.0) #:hp 40.0 #:shield 80.0))))
  (define rt-sp2 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-sp2
    (run-l34 rt-sp2
             (mk-live-obs 'Protoss 'Terran 610
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units sp-2dmg-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (list pf-bldg)
                          #:researched-upgrades '(shadow-stride))))
  (define sp2-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-sp2))
  (check-true "L42-T2b-p15-sp-2-damaged-dts-and-10-in-range-triggers-early-alpha-strike"
              (= (length sp2-blinks) 10)
              (format "Expected 10 early-release blinks when 2 DTs damaged & 10/27 in range; got ~a" (length sp2-blinks)))

  ;; T2c (Negative guard): Same `10/27` in range with `0` damaged DTs -> STILL holds cloaked staging!
  (define sp-0dmg-dts-27
    (map (lambda (u) (hash-set (hash-set u 'shield 80.0) 'shields 80.0)) sp-2dmg-dts-27))
  (define rt-sp0 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-sp0
    (run-l34 rt-sp0
             (mk-live-obs 'Protoss 'Terran 610
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units sp-0dmg-dts-27
                          #:enemy-units p15-enemies
                          #:enemy-buildings (list pf-bldg)
                          #:researched-upgrades '(shadow-stride))))
  (define sp0-blinks (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'shadow-stride))) acts-sp0))
  (define sp0-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move))) acts-sp0))
  (check-true "L42-T2c-p15-zero-damaged-10-in-range-still-holds-until-70pct"
              (and (null? sp0-blinks) (= (length sp0-moves) 27))
              (format "Expected 0 blinks & 27 staging moves w/ 0 damaged; blinks=~a moves=~a"
                      (length sp0-blinks) (length sp0-moves))))

;; =============================================================================
;; 3. L42-P0-1c: `z16` Muta Magic-Box Restoration (Min 2, `r2=2.65t`, Moving-Thor HOLD)
;; =============================================================================
(let ()
  (define thor1 (list (mk-u 3901 'thor 80.0 80.0 #:hp 400.0)))
  (define mutas-3
    (list (mk-u 3001 'mutalisk 78.2 80.0 #:hp 120.0 #:flying? #t)
          (mk-u 3002 'mutalisk 81.8 80.0 #:hp 120.0 #:flying? #t)
          (mk-u 3003 'mutalisk 80.0 81.8 #:hp 120.0 #:flying? #t)))
  (define d3 (plan-mutalisk-magic-box mutas-3 thor1))
  (define d1 (plan-mutalisk-magic-box (take mutas-3 1) thor1))
  (check-true "L42-T3a-z16-3-surviving-mutas-still-magic-box-and-1-muta-skips"
              (and (= (length d3) 3) (null? d1))
              (format "3-muta=~a 1-muta=~a" (length d3) (length d1)))

  ;; T3b: 16 Mutas approaching Thor -> tightened `5+11` packing (`r1=1.40t, r2=2.90t`) keeps ALL
  ;; 16 slots strictly `<= 2.95t` of Thor (inside 3.0t weapon range) with `>= 1.50t` pairwise sep!
  (define mutas-16-far
    (for/list ([i (in-range 16)])
      (mk-u (+ 3101 i) 'mutalisk (+ 72.0 (* 0.3 (modulo i 4))) (+ 79.0 (* 0.3 (quotient i 4)))
            #:hp 120.0 #:flying? #t)))
  (define d16 (plan-mutalisk-magic-box mutas-16-far thor1))
  (define max-slot-r
    (for/fold ([mr 0.0]) ([d (in-list d16)])
      (max mr (dist2d-t 80.0 80.0 (spell-directive-target-x d) (spell-directive-target-y d)))))
  (define min-slot-sep
    (for/fold ([ms +inf.0]) ([i (in-range (length d16))])
      (define a (list-ref d16 i))
      (for/fold ([m ms]) ([j (in-range (add1 i) (length d16))])
        (define b (list-ref d16 j))
        (min m (dist2d-t (spell-directive-target-x a) (spell-directive-target-y a)
                         (spell-directive-target-x b) (spell-directive-target-y b))))))
  (check-true "L42-T3b-z16-tightened-r2-slots-2.90t-inside-muta-weapon-range-with-1.50t-sep"
              (and (= (length d16) 16) (<= max-slot-r 2.95) (>= min-slot-sep 1.48))
              (format "n=~a max-slot-r=~a min-sep=~a (expected <=2.95 & >=1.48)"
                      (length d16) max-slot-r min-slot-sep))

  ;; T3c: Moving Thor shifts 1.2t -> 6 spread Mutas still within `<= 3.3t` of `best-thor` with
  ;; `>= 1.35t` ally separation STAY on `hold-position (18)` instead of jittering back into `move (16)`!
  (define spread-6-mutas
    (for/list ([k (in-range 6)])
      (define ang (* 2.0 pi (/ k 6.0)))
      ;; Centered around old Thor pos (78.8, 80.0) at r=1.8t -> now Thor moved to (80.0, 80.0)!
      (mk-u (+ 3201 k) 'mutalisk (+ 78.8 (* 1.8 (cos ang))) (+ 80.0 (* 1.8 (sin ang)))
            #:hp 120.0 #:flying? #t)))
  (define d6-shifted (plan-mutalisk-magic-box spread-6-mutas thor1))
  (define hold-cnt (count (lambda (d) (eq? (spell-directive-ability d) 'hold-position)) d6-shifted))
  (check-true "L42-T3c-z16-moving-thor-keeps-spread-mutas-on-hold-18"
              (= hold-cnt 6)
              (format "Expected all 6 spread Mutas (<=3.3t, sep>=1.35t) to HOLD 18; got ~a (~a)"
                      hold-cnt (map spell-directive-ability d6-shifted))))

;; =============================================================================
;; 4. L42-P0-1d: `e03`/`e04` Polish + `#04 PvT` `2–6m` Colossus Staging Guard
;; =============================================================================
(let ()
  ;; T4a (`e03`): Close healthy SCVs (`<= 5.9t`) evacuate via collision-free `mineral-walk`,
  ;; while far healthy SCVs (`> 5.9t`) stay mining!
  (define main-cc (mk-u 4000 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-e03
    (list (mk-u 4101 'scv 27.5 29.0 #:hp 45.0 #:max-hp 45.0) ;; close to Adepts at (31.5, 29.0) -> 4.0t <= 5.9t
          (mk-u 4102 'scv 27.5 29.8 #:hp 45.0 #:max-hp 45.0) ;; close -> 4.1t
          (mk-u 4103 'scv 26.8 37.5 #:hp 45.0 #:max-hp 45.0) ;; far -> 9.7t > 5.9t (MUST stay mining!)
          (mk-u 4104 'scv 28.5 38.5 #:hp 45.0 #:max-hp 45.0))) ;; far -> 10.0t > 5.9t (MUST stay mining!)
  (define adepts-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 4901 i) 'adept 31.5 (+ 28.8 (* 0.3 i)) #:hp 70.0 #:shield 70.0)))
  (define rt-e03 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-e03
    (step-layer2-economy!
     rt-e03
     (mk-live-obs 'Terran 'Protoss 1400 #:minerals 100 #:gas 0 #:supply-used 18 #:supply-cap 23
                  #:ally-units (append scvs-e03 (list (mk-u 4201 'marine 31.0 29.5 #:hp 45.0)))
                  #:ally-buildings (list main-cc)
                  #:enemy-units adepts-3 #:mineral-patches main-mps)))
  (define e03-mw-wids (map second (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-e03)))
  (check-true "L42-T4a-e03-close-scvs-evacuate-while-far-healthy-scvs-keep-mining"
              (and (memv 4101 e03-mw-wids) (memv 4102 e03-mw-wids)
                   (not (memv 4103 e03-mw-wids)) (not (memv 4104 e03-mw-wids)))
              (format "e03 mw-wids=~a" e03-mw-wids))

  ;; T4b (`e04`): After 6-Ling breach latch: when Zealot is STILL ALIVE and Lings drop to 2 ->
  ;; releases Probes back to `harvest-mineral` (saving uptime!); when Zealot is DEAD and 2 Lings
  ;; remain -> latch HOLDS (`pull-workers-attack`) to finish every last Ling!
  (define main-nex (mk-u 4500 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define probes-14
    (for/list ([i (in-range 14)])
      (mk-u (+ 4601 i) 'probe 28.5 (+ 28.0 (* 0.6 i)) #:hp 20.0 #:shield 20.0)))
  (define lings-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 4801 i) 'zergling 33.5 (+ 31.0 (* 0.4 i)) #:hp 35.0)))
  (define zealot-alive (mk-u 4701 'zealot 33.0 32.0 #:hp 100.0 #:shield 50.0))
  (define rt-e04-z (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (void (step-layer2-economy!
         rt-e04-z
         (mk-live-obs 'Protoss 'Zerg 1400 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                      #:ally-units (cons zealot-alive probes-14)
                      #:ally-buildings (list main-nex)
                      #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define acts-z-alive-2lings
    (step-layer2-economy!
     rt-e04-z
     (mk-live-obs 'Protoss 'Zerg 1412 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:ally-units (cons zealot-alive probes-14)
                  #:ally-buildings (list main-nex)
                  #:enemy-units (take lings-6 2) #:mineral-patches main-mps)))
  (define z-alive-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-z-alive-2lings))
  (define z-alive-rets (filter (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral))) acts-z-alive-2lings))
  ;; Separate runtime where Zealot died -> latch holds at 2 Lings!
  (define rt-e04-dead (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (void (step-layer2-economy!
         rt-e04-dead
         (mk-live-obs 'Protoss 'Zerg 1400 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 23
                      #:ally-units (cons zealot-alive probes-14)
                      #:ally-buildings (list main-nex)
                      #:enemy-units lings-6 #:mineral-patches main-mps)))
  (define acts-z-dead-2lings
    (step-layer2-economy!
     rt-e04-dead
     (mk-live-obs 'Protoss 'Zerg 1412 #:minerals 100 #:gas 0 #:supply-used 14 #:supply-cap 23
                  #:ally-units probes-14
                  #:ally-buildings (list main-nex)
                  #:enemy-units (take lings-6 2) #:mineral-patches main-mps)))
  (define z-dead-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-z-dead-2lings))
  (check-true "L42-T4b-e04-zealot-alive-releases-probes-at-2-lings-zealot-dead-holds-latch"
              (and (null? z-alive-pulls) (>= (length z-alive-rets) 4)
                   (pair? z-dead-pulls))
              (format "z-alive pulls=~a rets=~a | z-dead pulls=~a"
                      (length z-alive-pulls) (length z-alive-rets) (length z-dead-pulls)))

  ;; T4c (`#04 PvT` 2-6m Colossus Staging Guard): 2-base PvT (`f=6800`, 18-supply Stalkers+Immortal,
  ;; `RoboticsBay` present, `0` Colossi, enemy Terran far across map at `(140, 120)`) -> suppresses
  ;; cross-map attack; once Colossus #1 spawns -> releases to push!
  (define pvt-bldgs
    (list (mk-u 5001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 5002 'nexus 58.5 34.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 5003 'robotics-facility 38.0 34.0 #:hp 450.0 #:shield 450.0)
          (mk-u 5004 'robotics-bay 42.0 34.0 #:hp 500.0 #:shield 500.0)))
  (define pvt-gw-army
    (append
     (for/list ([i (in-range 7)]) (mk-u (+ 5101 i) 'stalker (+ 56.0 (* 0.4 i)) 38.0 #:hp 80.0 #:shield 80.0))
     (list (mk-u 5120 'immortal 57.0 37.0 #:hp 200.0 #:shield 100.0))))
  (define far-terran-army
    (append
     (for/list ([i (in-range 10)]) (mk-u (+ 5901 i) 'marine (+ 136.0 (* 0.3 i)) 118.0 #:hp 55.0))
     (list (mk-u 5920 'siege-tank-sieged 138.0 119.0 #:hp 175.0))))
  (define rt-pvt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-pvt-wait
    (mk-live-obs 'Protoss 'Terran 6800 #:minerals 300 #:gas 200 #:supply-used 62 #:supply-cap 78
                 #:ally-units pvt-gw-army #:ally-buildings pvt-bldgs
                 #:enemy-units far-terran-army))
  (define acts-pvt-wait (run-l34 rt-pvt obs-pvt-wait))
  (define hold-wait? (eq? (hash-ref (rt-door-state rt-pvt) 'l88-op-mode #f) 'pre-arc-hold))
  (define stage-wait? (hash-ref (rt-door-state rt-pvt) 'l34-mass-staging? #f))
  (define cross-map-atk-wait?
    (ormap (lambda (a)
             (and (pair? a) (memq (car a) '(attack attack-pos))
                  (or (eq? (car a) 'attack)
                      (and (>= (length a) 4)
                           (> (dist2d-t (third a) (fourth a) 58.5 34.5) 45.0)))))
           acts-pvt-wait))
  ;; Now add Colossus #1 -> guard releases!
  (define pvt-with-col (cons (mk-u 5130 'colossus 57.5 38.5 #:hp 200.0 #:shield 150.0) pvt-gw-army))
  (define obs-pvt-go
    (mk-live-obs 'Protoss 'Terran 7200 #:minerals 300 #:gas 200 #:supply-used 68 #:supply-cap 78
                 #:ally-units pvt-with-col #:ally-buildings pvt-bldgs
                 #:enemy-units far-terran-army))
  (define acts-pvt-go (run-l34 rt-pvt obs-pvt-go))
  (define hold-go? (eq? (hash-ref (rt-door-state rt-pvt) 'l88-op-mode #f) 'pre-arc-hold))
  (define stage-go? (hash-ref (rt-door-state rt-pvt) 'l34-mass-staging? #f))
  (check-true "L42-T4c-m04-pvt-staging-holds-while-awaiting-colossus1-and-releases-when-ready"
              (and hold-wait? stage-wait? (not cross-map-atk-wait?)
                   (not hold-go?) (not stage-go?))
              (format "hold-wait?=~a stage-wait?=~a cross-map-wait?=~a | hold-go?=~a stage-go?=~a"
                      hold-wait? stage-wait? cross-map-atk-wait? hold-go? stage-go?))

  ;; T4d (Negative guard): Same 2-base PvT awaiting Colossus #1, but enemy Marines attack at our
  ;; Natural Nexus (`<= 10t`) -> MUST immediately fight (`attack-unit`) & NEVER set colossus hold!
  (define home-terran-raid
    (for/list ([i (in-range 6)]) (mk-u (+ 5951 i) 'marine (+ 62.0 (* 0.4 i)) 36.0 #:hp 55.0)))
  (define rt-pvt-def (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-pvt-def
    (run-l34 rt-pvt-def
             (mk-live-obs 'Protoss 'Terran 6850 #:minerals 300 #:gas 200 #:supply-used 62 #:supply-cap 78
                          #:ally-units pvt-gw-army #:ally-buildings pvt-bldgs
                          #:enemy-units home-terran-raid)))
  (define home-def-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit))) acts-pvt-def))
  (define hold-home? (hash-ref (rt-door-state rt-pvt-def) 'l34-mass-staging? #f))
  (check-true "L42-T4d-m04-pvt-home-defense-never-suppressed-by-colossus-hold"
              (and (not hold-home?) (>= (length home-def-atks) 4))
              (format "Expected hold-home?=#f & >= 4 home defense attack-unit orders, got hold=~a atks=~a"
                      hold-home? (length home-def-atks))))

(printf "\nL42 Tactics + Runtime Regression Summary: ~a passed, ~a failed\n" pass-cnt fail-cnt)
(unless (zero? fail-cnt)
  (exit 1))
