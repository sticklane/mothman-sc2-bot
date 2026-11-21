#lang racket/base

;; =============================================================================
;; Loop 45 Surgical All-3-Race Ship #6 Runtime & Tactics Verification Suite
;;   1. L45-P0-1a (`#11 puck`, `#50 Thssprtssbt`, `H2H #02 TvT` + `#53 zig-reapers`):
;;      Gate BOTH `light-home-harass-split-yield?` and `p5-light-harass-split-active?`
;;      strictly on offensive/victory posture (`attack` / `*Victory`) AND decisive
;;      combat-supply dominance (`>= 1.65 * (max 20.0 enemy-known-combat-sup)`).
;;   2. L45-P0-1b (`ro01` Widow Mine Medivac Drop):
;;      Loaded moving drop transport (`tr-cargo > 0`) never skipped by `tr-moving-self-drop-vel?`,
;;      approaches Fog mineral line without wasting boost or drifting home, fires off-GCD
;;      `medivac-boost` + `move`, and unloads over Drones while preserving Suite 45 synthetic
;;      moving self-drop tests (`tr-cargo == 0`).
;;   3. L45-P0-1b (`ro09` Oracle Pulsar Beam SCV Shred):
;;      Holds Pulsar Beam ON down to `sh < 10.0` vs `>= 4` workers, suppresses Stasis Ward
;;      at `sh >= 25` (preserving `L43-T3d` at `sh = 20`), suppresses light-AA kite while
;;      `hp-ratio >= 0.45` & `<= 4` light AA, focus-fires SCVs, and flies into Fog mineral lines.
;;   4. L45-P0-1b (`p15` DT Fog Ground Memory & Perimeter Sweep):
;;      Surviving cloaked DTs with `0` detectors, `0` PFs, and `0` visible ground enemies
;;      sweep remembered last-known ground positions + expanding perimeter ring (`attack-pos`).
;;   5. L45-P0-1b (`ro04` Blue-Flame Hellion Queen Flank + Fog Runby Push):
;;      Hellions take a `±3.5t` perpendicular flank waypoint around body-blocking Queens both
;;      with visible workers and when approaching a Fog mineral line past `<= 3` blockers.
;;   6. L45-P0-1b (`e01` Probe Harass Early Rotation `<= 22` EHP):
;;      Keeps `1..2` pulled Probes (`L38-T5b`/`L40-T6e`) and rotates defending Probes back to
;;      safe minerals at `<= 22.0` EHP (before lethal 3rd-4th volley) with `>= 26.0` pull min.
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/opponent-world-model.rkt")

(define tests-run 0)
(define tests-passed 0)
(define tests-failed 0)

(define (check-true name cond [detail ""])
  (set! tests-run (add1 tests-run))
  (if cond
      (begin
        (set! tests-passed (add1 tests-passed))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! tests-failed (add1 tests-failed))
        (printf "  [FAIL] ~a~a\n" name (if (equal? detail "") "" (format " :: ~a" detail))))))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0] #:buffs [buffs '()]
              #:flying? [flying? #f] #:cloaked? [cloaked? #f]
              #:cloak [cloak 0] #:burrowed? [burrowed? #f]
              #:cargo [cargo 0] #:passengers [passengers '()]
              #:vx [vx 0.0] #:vy [vy 0.0]
              #:orders [orders '()]
              #:assigned-harvesters [ah #f] #:ideal-harvesters [ih #f])
  (define h
    (hasheq 'id id 'tag id 'type type 'x x 'y y
            'hp hp 'max-hp max-hp 'shield shield 'shields shield 'max-shield max-shield
            'energy energy 'buffs buffs
            'flying? flying? 'is-flying flying?
            'cloaked cloaked? 'cloak cloak 'burrowed burrowed?
            'cargo-space-taken cargo 'passengers passengers
            'vx vx 'vy vy 'orders orders
            'display-type 1 'snapshot? #f 'build-progress 1.0))
  (define h1 (if ah (hash-set h 'assigned-harvesters ah) h))
  (if ih (hash-set h1 'ideal-harvesters ih) h1))

(define (mk-live-obs our-race enemy-race frame
                     #:ally-units [ally-units '()]
                     #:ally-buildings [ally-bldgs '()]
                     #:enemy-units [enemy-units '()]
                     #:enemy-buildings [enemy-bldgs '()]
                     #:minerals [minerals 400]
                     #:gas [gas 200]
                     #:supply-used [supply-used 60]
                     #:supply-cap [supply-cap 100]
                     #:base-x [base-x 32.0] #:base-y [base-y 32.0]
                     #:nat-x [nat-x 44.0] #:nat-y [nat-y 40.0]
                     #:enemy-x [enemy-x 140.0] #:enemy-y [enemy-y 120.0]
                     #:mineral-harvesters [mh 16]
                     #:mineral-patches [mps '()]
                     #:researched-upgrades [upgs '()]
                     #:dead-tags [dead-tags '()]
                     #:fog-ground [fog-ground #f])
  (define base
    (hasheq 'frame frame 'our-race our-race 'enemy-race enemy-race
            'minerals minerals 'gas gas
            'supply-used supply-used 'supply-cap supply-cap
            'base-x base-x 'base-y base-y 'nat-x nat-x 'nat-y nat-y
            'enemy-x enemy-x 'enemy-y enemy-y
            'map-width 200 'map-height 200
            'mineral-harvesters mh
            'mineral-patches mps
            'ally-units ally-units 'ally-buildings ally-bldgs
            'enemy-units enemy-units 'enemy-buildings enemy-bldgs
            'researched-upgrades upgs
            'dead-unit-tags dead-tags))
  (if fog-ground
      (hash-set base 'remembered-enemy-ground-positions fog-ground)
      base))

(define (run-l34 rt obs)
  (hash-ref (step-live-bot-runtime! rt obs) 'actions '()))

(printf "=== Loop 45 Surgical All-3-Race Tactics & Runtime Tests ===\n")

;; -----------------------------------------------------------------------------
;; 1. L45-P0-1a: Gate Light Home-Harass Split on Offensive/Victory Posture + 1.65x Dominance
;; -----------------------------------------------------------------------------
(let ()
  (define cc-home (mk-u 1 'command-center 32.0 32.0 #:hp 1500.0))
  (define army-t
    (append
     (for/list ([i (in-range 5)])
       (mk-u (+ 5001 i) 'siege-tank-sieged (+ 40.0 i) 34.0 #:hp 175.0))
     (for/list ([i (in-range 20)])
       (mk-u (+ 5101 i) 'marine (+ 36.0 (* 0.5 (modulo i 5))) (+ 32.0 (* 0.5 (quotient i 5))) #:hp 45.0))
     (for/list ([i (in-range 10)])
       (mk-u (+ 5201 i) 'marauder (+ 42.0 (* 0.5 (modulo i 5))) (+ 35.0 (* 0.5 (quotient i 5))) #:hp 125.0))))
  (define adepts-2
    (list (mk-u 8951 'adept 34.0 32.0 #:hp 70.0 #:shield 70.0)
          (mk-u 8952 'adept 34.5 32.5 #:hp 70.0 #:shield 70.0)))

  ;; (i) Non-attack posture (`'OneRaxFE` / `'Macro12Hatch` midgame with enemy parity):
  ;; Seed OWM with 45 enemy army supply (15 Stalkers + 5 Zealots = 40 supply seen earlier in Fog)
  ;; so Terran has 55 supply vs 40 believed enemy supply (`55 < 1.65 * 40 = 66`!).
  (define rt-parity (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define enemy-army-40
    (append
     (for/list ([i (in-range 15)])
       (mk-u (+ 9100 i) 'stalker (+ 100.0 (* 0.6 i)) 90.0 #:hp 80.0 #:shield 80.0))
     (for/list ([i (in-range 5)])
       (mk-u (+ 9150 i) 'zealot (+ 98.0 (* 0.6 i)) 91.0 #:hp 100.0 #:shield 50.0))))
  ;; Frame 1: Scout enemy army so OWM believes enemy has ~40 combat supply
  (run-l34 rt-parity
           (mk-live-obs 'Terran 'Protoss 7000
                        #:supply-used 95 #:supply-cap 110
                        #:ally-units army-t #:ally-buildings (list cc-home)
                        #:enemy-units enemy-army-40
                        #:enemy-x 140.0 #:enemy-y 120.0))
  ;; Force `'attack` posture on frame 2 to verify even in `'attack` posture, parity (`55 < 1.65*40=66`) blocks split!
  (set-live-bot-runtime-posture! rt-parity 'attack)
  (define acts-parity
    (run-l34 rt-parity
             (mk-live-obs 'Terran 'Protoss 7020
                          #:supply-used 95 #:supply-cap 110
                          #:ally-units army-t #:ally-buildings (list cc-home)
                          #:enemy-units adepts-2
                          #:enemy-x 140.0 #:enemy-y 120.0)))
  (define parity-unsieges
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'unsiege-mode))) acts-parity))
  (define parity-cw-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos)
                             (>= (third a) 130.0) (>= (fourth a) 110.0)))
            acts-parity))
  (check-true "L45-T1a-parity-terran-never-splits-or-unsieges-vs-2-adepts"
              (and (null? parity-unsieges) (null? parity-cw-atks))
              (format "unsieges=~a cw-atks=~a" (length parity-unsieges) (length parity-cw-atks)))

  ;; (ii) Non-offensive posture (`'OneRaxFE` midgame, even with low believed enemy supply):
  ;; Midgame `supply-used = 75` stays in non-attack posture (unless forced), MUST NOT split!
  (define rt-macro (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'OneRaxFE))
  ;; Keep posture non-attack at early-midgame frame 5000 with 55 combat supply (55 < 65 victory supply, supply-used 75)
  (define acts-macro
    (run-l34 rt-macro
             (mk-live-obs 'Terran 'Protoss 5000
                          #:supply-used 75 #:supply-cap 90
                          #:ally-units army-t #:ally-buildings (list cc-home)
                          #:enemy-units (append adepts-2
                                                (for/list ([i (in-range 12)])
                                                  (mk-u (+ 9300 i) 'stalker (+ 125.0 (* 0.5 i)) 115.0 #:hp 80.0 #:shield 80.0)))
                          #:enemy-x 140.0 #:enemy-y 120.0)))
  (define macro-unsieges
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'unsiege-mode))) acts-macro))
  (define macro-cw-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos)
                             (>= (third a) 130.0) (>= (fourth a) 110.0)))
            acts-macro))
  (check-true "L45-T1a-non-dominant-visible-enemy-blocks-split-and-tank-unsiege"
              (and (null? macro-unsieges) (null? macro-cw-atks))
              (format "posture=~a unsieges=~a cw-atks=~a"
                      (live-bot-runtime-posture rt-macro) (length macro-unsieges) (length macro-cw-atks)))

  ;; (iii) Dominant `#53 zig-reapers` Victory/Attack posture (`60` combat sup >= `1.65 * 20 = 33.0`):
  ;; STILL unsieges ALL 5 Tanks & dispatches counter-wave to `(enemy-x, enemy-y)`!
  (define rt-dom (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'MothmanApexVictory))
  (define reapers-2
    (list (mk-u 8951 'reaper 34.0 32.0 #:hp 60.0)
          (mk-u 8952 'reaper 34.5 32.5 #:hp 60.0)))
  (define-values (acts-dom _vg _rs)
    (step-layer3-and-4-tactics!
     rt-dom
     (mk-live-obs 'Terran 'Terran 14000
                  #:supply-used 119 #:supply-cap 134
                  #:ally-units army-t #:ally-buildings (list cc-home)
                  #:enemy-units reapers-2
                  #:enemy-x 140.0 #:enemy-y 120.0)
     0.5))
  (define dom-unsieges
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'unsiege-mode))) acts-dom))
  (define dom-cw-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos)
                             (>= (third a) 130.0) (>= (fourth a) 110.0)))
            acts-dom))
  (check-true "L45-T1a-dominant-53-zig-reapers-still-unsieges-and-dispatches-counter-wave"
              (and (memq (live-bot-runtime-posture rt-dom) '(attack SwarmVictory ProtossArmadaVictory MothmanApexVictory))
                   (= (length dom-unsieges) 5)
                   (>= (length dom-cw-atks) 15))
              (format "posture=~a unsieges=~a cw-atks=~a"
                      (live-bot-runtime-posture rt-dom) (length dom-unsieges) (length dom-cw-atks))))

;; -----------------------------------------------------------------------------
;; 2. L45-P0-1b (`ro01`): Widow Mine Medivac Drop (Fog Approach + Live Moving Unload + Suite 45 Guard)
;; -----------------------------------------------------------------------------
(let ()
  (define wm-pax
    (list (mk-u 202 'widow-mine 42.5 138.5 #:hp 90.0)
          (mk-u 203 'widow-mine 42.5 138.5 #:hp 90.0)))
  (define mv-preload
    (mk-u 201 'medivac 42.5 138.5 #:hp 150.0 #:cargo 4 #:passengers wm-pax #:flying? #t))
  (define q1 (mk-u 8001 'queen 36.3 138.5 #:hp 175.0))
  (define drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8100 i) 'drone 30.3 (+ 135.5 (* 0.4 i)) #:hp 40.0)))

  ;; (i) Preload Fog frame (`enemy-units = '()`, `base-x=142.5, base-y=33.5`, `enemy-x=33.5, enemy-y=138.5`):
  ;; MUST fly west toward `(33.5, 138.5)`, NEVER retreat toward `(142.5, 33.5)`, NEVER waste `medivac-boost`, NEVER blind-unload!
  (define rt-ro01 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-pre
    (run-l34 rt-ro01
             (mk-live-obs 'Terran 'Zerg 140
                          #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:nat-x 129.5 #:nat-y 46.0
                          #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units (list mv-preload) #:enemy-units '())))
  (define pre-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 201))) acts-pre))
  (define pre-boosts (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'medivac-boost))) acts-pre))
  (define pre-unloads (filter (lambda (a) (and (pair? a) (eq? (car a) 'unload-all-at))) acts-pre))
  (check-true "L45-T2a-ro01-fog-preload-flies-to-enemy-mineral-line-no-retreat-no-boost-waste"
              (and (pair? pre-moves)
                   (<= (third (car pre-moves)) 36.0)
                   (null? pre-boosts)
                   (null? pre-unloads))
              (format "moves=~a boosts=~a unloads=~a" pre-moves pre-boosts pre-unloads))

  ;; (ii) Approach frame with 1 Queen visible & moving Medivac (`vx=-2.0`, `cargo=4`):
  ;; Emits BOTH off-GCD `medivac-boost` AND `move` past the Queen toward `(33.5, 138.5)`!
  (define mv-moving-q
    (mk-u 201 'medivac 40.5 138.5 #:hp 150.0 #:cargo 4 #:passengers wm-pax #:flying? #t #:vx -2.0))
  (define acts-q
    (run-l34 rt-ro01
             (mk-live-obs 'Terran 'Zerg 164
                          #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:nat-x 129.5 #:nat-y 46.0
                          #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units (list mv-moving-q) #:enemy-units (list q1))))
  (define q-boost? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'medivac-boost))) acts-q))
  (define q-move-west? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 201) (<= (third a) 35.0))) acts-q))
  (check-true "L45-T2a-ro01-moving-loaded-medivac-boosts-and-flies-past-queen-same-tick"
              (and q-boost? q-move-west?)
              (format "boost?=~a move-west?=~a acts=~a" q-boost? q-move-west? acts-q))

  ;; (iii) Arrival frame over 16 visible Drones while STILL moving (`vx=-2.5`, `cargo=4`):
  ;; Emits `(unload-all-at 201 ...)` directly over Drones (`tr-moving-self-drop-vel?` does NOT skip `cargo > 0`!)
  (define mv-over-drones
    (mk-u 201 'medivac 31.2 138.5 #:hp 150.0 #:cargo 4 #:passengers wm-pax #:flying? #t #:vx -2.5))
  (define acts-drop
    (run-l34 rt-ro01
             (mk-live-obs 'Terran 'Zerg 176
                          #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:nat-x 129.5 #:nat-y 46.0
                          #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units (list mv-over-drones) #:enemy-units (cons q1 drones-16))))
  (define drop-unload?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'unload-all-at) (= (second a) 201))) acts-drop))
  (check-true "L45-T2a-ro01-moving-loaded-medivac-unloads-over-drones"
              drop-unload?
              (format "acts=~a" acts-drop))

  ;; (iv) Suite 45 negative guard: synthetic moving self-drop (`cargo = 0`, `vx = 3.0`, 1 passenger)
  ;; MUST still defer to `plan-transport-fleet-micro` (`transport-juggle`, NOT `unload-all-at`)!
  (define rt-s45 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define mv-s45
    (mk-u 701 'medivac 60.0 60.0 #:hp 150.0 #:cargo 0
          #:passengers (list (mk-u 702 'marine 60.0 60.0 #:hp 45.0))
          #:flying? #t #:vx 3.0))
  (define acts-s45
    (run-l34 rt-s45
             (mk-live-obs 'Terran 'Zerg 2400
                          #:supply-used 10 #:supply-cap 50 #:mineral-harvesters 10
                          #:base-x 30.0 #:base-y 30.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units (list mv-s45)
                          #:enemy-units (list (mk-u 901 'zergling 66.0 60.0 #:hp 35.0)))))
  (check-true "L45-T2a-suite45-synthetic-cargo0-moving-self-drop-preserved"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'unload-all-at))) acts-s45))
              (format "acts=~a" acts-s45)))

;; -----------------------------------------------------------------------------
;; 3. L45-P0-1b (`ro09`): Oracle Pulsar Beam Hold + Light-AA Kite Suppression + SCV Shred
;; -----------------------------------------------------------------------------
(let ()
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8100 i) 'scv 30.3 (+ 135.5 (* 0.4 i)) #:hp 45.0)))
  (define marines-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 8001 i) 'marine 36.5 (+ 137.5 (* 0.6 i)) #:hp 45.0)))

  ;; (i) Pulsar Beam ON at `sh = 15 < 25` over `>= 4` SCVs (`dwell >= 60f`): HOLDS beam ON!
  (define c-or (make-spell-claims))
  (hash-set! (spell-claims-oracle-beam-start c-or) 101 1000)
  (define d-hold
    (plan-protoss-spellcaster-micro
     (list (mk-u 101 'oracle 32.0 138.5 #:hp 100.0 #:shield 15.0 #:energy 30.0 #:flying? #t #:buffs '(oracle-weapon)))
     (append marines-4 scvs-16)
     #:claims c-or #:current-frame 1080))
  ;; (ii) Same Oracle at `sh = 8 < 10`: turns Pulsar Beam OFF cleanly!
  (define d-off
    (plan-protoss-spellcaster-micro
     (list (mk-u 101 'oracle 32.0 138.5 #:hp 100.0 #:shield 8.0 #:energy 30.0 #:flying? #t #:buffs '(oracle-weapon)))
     (append marines-4 scvs-16)
     #:claims c-or #:current-frame 1084))
  ;; (iii) Low-shield `sh = 20 < 25` Oracle with `en = 52` (`L43-T3d` preservation): STILL plants Stasis Ward!
  (define d-stasis-low
    (plan-protoss-spellcaster-micro
     (list (mk-u 102 'oracle 35.0 138.5 #:hp 100.0 #:shield 20.0 #:energy 52.0 #:flying? #t))
     (take scvs-16 5)
     #:claims (make-spell-claims) #:current-frame 1100))
  (check-true "L45-T2b-ro09-pulsar-beam-holds-down-to-sh10-turns-off-below-10-preserves-l43-stasis"
              (and (null? d-hold)
                   (= (length d-off) 1)
                   (eq? (spell-directive-ability (car d-off)) 'pulsar-beam-off)
                   (= (length d-stasis-low) 1)
                   (eq? (spell-directive-ability (car d-stasis-low)) 'stasis-ward))
              (format "hold=~a off=~a stasis=~a" d-hold d-off d-stasis-low))

  ;; (iv) Runtime: 2 Oracles with Pulsar Beam ON (`hp=100, sh=20` => `hp-ratio=0.75 >= 0.45`) vs 4 Marines + 16 SCVs:
  ;; BOTH emit `(attack-unit oid scv-id)` with ZERO `kite` / `move` away from the 4 Marines!
  (define rt-ro09 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define oracles-on
    (list (mk-u 101 'oracle 34.5 138.0 #:hp 100.0 #:max-hp 100.0 #:shield 20.0 #:max-shield 60.0 #:energy 40.0 #:flying? #t #:buffs '(oracle-weapon))
          (mk-u 102 'oracle 34.5 139.0 #:hp 100.0 #:max-hp 100.0 #:shield 20.0 #:max-shield 60.0 #:energy 40.0 #:flying? #t #:buffs '(oracle-weapon))))
  (define acts-ro09
    (run-l34 rt-ro09
             (mk-live-obs 'Protoss 'Terran 1120
                          #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracles-on #:enemy-units (append marines-4 scvs-16))))
  (define scv-ids (map (lambda (s) (hash-ref s 'id)) scvs-16))
  (define or-scv-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (memv (second a) '(101 102))
                             (memv (third a) scv-ids)))
            acts-ro09))
  (define or-kites
    (filter (lambda (a) (and (pair? a) (memq (car a) '(kite move)) (memv (second a) '(101 102)))) acts-ro09))
  (check-true "L45-T2b-ro09-oracles-suppress-marine-kite-and-focus-scvs"
              (and (= (length or-scv-atks) 2) (null? or-kites))
              (format "scv-atks=~a kites=~a acts=~a" or-scv-atks or-kites acts-ro09))

  ;; (v) Fog approach: 2 Oracles at `dx=+9.2` with beam ON, ONLY 4 Marines visible (SCVs in Fog at `enemy-x=33.5`):
  ;; Fly past Marines toward `(33.5, 138.5)` (`move` west!), NEVER kite east!
  (define oracles-fog
    (list (mk-u 101 'oracle 42.7 138.0 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0 #:energy 45.0 #:flying? #t #:buffs '(oracle-weapon))
          (mk-u 102 'oracle 42.7 139.0 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0 #:energy 45.0 #:flying? #t #:buffs '(oracle-weapon))))
  (define acts-ro09-fog
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 1124
                          #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracles-fog #:enemy-units marines-4)))
  (define fog-west-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move)
                             (memv (second a) '(101 102))
                             (< (third a) 40.0)))
            acts-ro09-fog))
  (check-true "L45-T2b-ro09-oracles-fly-past-4-marines-into-fog-mineral-line"
              (= (length fog-west-moves) 2)
              (format "fog-moves=~a acts=~a" fog-west-moves acts-ro09-fog)))

;; -----------------------------------------------------------------------------
;; 4. L45-P0-1b (`p15`): Cloaked DT Fog Ground Memory & Expanding Perimeter Sweep
;; -----------------------------------------------------------------------------
(let ()
  (define rt-p15 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define dts-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 301 i) 'dark-templar (+ 80.0 (* 0.5 (modulo i 5))) (+ 87.0 (* 0.5 (quotient i 5)))
            #:hp 40.0 #:shield 80.0 #:cloaked? #t #:cloak 1)))
  (define medivacs-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 9201 i) 'medivac (+ 84.0 (* 0.8 i)) 86.0 #:hp 150.0 #:flying? #t)))
  (define tank-hidden (mk-u 9301 'siege-tank-sieged 91.0 81.5 #:hp 175.0))

  ;; Frame 1: Tank is briefly visible alongside the 3 Medivacs -> ground memory records `(91.0, 81.5)`!
  (run-l34 rt-p15
           (mk-live-obs 'Protoss 'Terran 1500
                        #:supply-used 20 #:supply-cap 200 #:mineral-harvesters 0
                        #:base-x 72.0 #:base-y 88.0 #:enemy-x 86.0 #:enemy-y 88.0
                        #:ally-units dts-10 #:enemy-units (cons tank-hidden medivacs-3)))
  ;; Frame 2: Tank slips into Fog behind SE wall; ONLY 3 flying Medivacs remain visible (`det=0, pf=0`)!
  (define acts-p15-sweep
    (run-l34 rt-p15
             (mk-live-obs 'Protoss 'Terran 1520
                          #:supply-used 20 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 72.0 #:base-y 88.0 #:enemy-x 86.0 #:enemy-y 88.0
                          #:ally-units dts-10 #:enemy-units medivacs-3)))
  (define dt-sweep-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos) (<= 301 (second a) 310))) acts-p15-sweep))
  (define hits-remembered-tank?
    (ormap (lambda (a) (and (<= (abs (- (third a) 91.0)) 1.5) (<= (abs (- (fourth a) 81.5)) 1.5))) dt-sweep-atks))
  (check-true "L45-T2c-p15-cloaked-dts-sweep-remembered-fog-tank-and-perimeter-when-only-medivacs-visible"
              (and (>= (length dt-sweep-atks) 8) hits-remembered-tank?)
              (format "sweep-cnt=~a hits-tank?=~a sample=~a"
                      (length dt-sweep-atks) hits-remembered-tank? (take dt-sweep-atks (min 3 (length dt-sweep-atks)))))

  ;; Negative guard: when a visible Missile Turret (detector) is alive, fog-sweep must NOT override DT blink/snipe!
  (define rt-p15-det (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define turret (mk-u 9401 'missile-turret 86.5 85.2 #:hp 250.0))
  (define acts-p15-det
    (run-l34 rt-p15-det
             (mk-live-obs 'Protoss 'Terran 1520
                          #:supply-used 20 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 72.0 #:base-y 88.0 #:enemy-x 86.0 #:enemy-y 88.0
                          #:ally-units dts-10 #:enemy-units medivacs-3 #:enemy-buildings (list turret)
                          #:fog-ground (list (hasheq 'id 9301 'x 91.0 'y 81.5)))))
  (define wrong-tank-sweep?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos)
                            (<= (abs (- (third a) 91.0)) 0.5) (<= (abs (- (fourth a) 81.5)) 0.5)))
           acts-p15-det))
  (check-true "L45-T2c-p15-neg-guard-live-detector-not-hijacked-by-fog-sweep"
              (not wrong-tank-sweep?)
              (format "acts=~a" acts-p15-det))

  ;; Wire integration (`#1016`): Fresh runtime with ONLY `'remembered-enemy-ground-positions` on obs
  ;; (no prior frame history!) + 3 flying Medivacs -> DTs immediately sweep the remembered fog Tank!
  (define acts-p15-wire
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 1520
                          #:supply-used 20 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 72.0 #:base-y 88.0 #:enemy-x 86.0 #:enemy-y 88.0
                          #:ally-units dts-10 #:enemy-units medivacs-3
                          #:fog-ground (list (hasheq 'id 9301 'type 'siege-tank-sieged 'x 91.0 'y 81.5)))))
  (check-true "L45-T2c-p15-wire-remembered-enemy-ground-positions-sweeps-fog-tank"
              (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos)
                                      (<= 301 (second a) 310)
                                      (<= (abs (- (third a) 91.0)) 0.5)
                                      (<= (abs (- (fourth a) 81.5)) 0.5)))
                     acts-p15-wire)
              (format "acts=~a" acts-p15-wire)))

;; -----------------------------------------------------------------------------
;; 5. L45-P0-1b (`ro04`): Blue-Flame Hellions Queen Flank Waypoint + Fog Runby Push
;; -----------------------------------------------------------------------------
(let ()
  (define hellions-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 401 i) 'hellion 42.7 (+ 137.8 (* 0.45 i)) #:hp 90.0)))
  (define queens-2
    (list (mk-u 8001 'queen 36.3 138.2 #:hp 175.0)
          (mk-u 8002 'queen 36.3 138.8 #:hp 175.0)))
  (define drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8100 i) 'drone 30.3 (+ 135.5 (* 0.4 i)) #:hp 40.0)))

  ;; (i) Visible Drones + 2 collinear blocking Queens -> Hellions emit perpendicular flank `move` (`|y - 138.5| >= 2.0`)!
  (define acts-ro04-vis
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 160
                          #:supply-used 8 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units hellions-4 #:enemy-units (append queens-2 drones-16))))
  (define vis-flank-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move)
                             (<= 401 (second a) 404)
                             (>= (abs (- (fourth a) 138.5)) 2.0)))
            acts-ro04-vis))
  (check-true "L45-T2d-ro04-hellions-flank-perpendicular-around-blocking-queens-with-visible-drones"
              (= (length vis-flank-moves) 4)
              (format "flank-moves=~a acts=~a" vis-flank-moves acts-ro04-vis))

  ;; (ii) Fog Drones (`12.4t > 10t` Hellion sight — ONLY 2 Queens visible at `dx=+2.8`, `enemy-x=33.5`):
  ;; Hellions flank-`move` around Queens toward `(33.5, 138.5)` instead of trading `attack-unit` into Queens!
  (define acts-ro04-fog
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 160
                          #:supply-used 8 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units hellions-4 #:enemy-units queens-2)))
  (define fog-flank-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move)
                             (<= 401 (second a) 404)
                             (>= (abs (- (fourth a) 138.5)) 2.0)))
            acts-ro04-fog))
  (define fog-queen-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (third a) '(8001 8002)))) acts-ro04-fog))
  (check-true "L45-T2d-ro04-hellions-flank-past-queens-into-fog-mineral-line-zero-queen-trading"
              (and (= (length fog-flank-moves) 4) (null? fog-queen-atks))
              (format "fog-flanks=~a queen-atks=~a" fog-flank-moves fog-queen-atks))

  ;; (iii) Negative guard: Heavy enemy defense (6 Roaches + 2 Queens) must NOT trigger Fog runby flank!
  (define roaches-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 8200 i) 'roach 36.5 (+ 136.0 (* 0.8 i)) #:hp 145.0)))
  (define acts-ro04-heavy
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 160
                          #:supply-used 8 #:supply-cap 200 #:mineral-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units hellions-4 #:enemy-units (append queens-2 roaches-6))))
  (define heavy-flanks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (<= 401 (second a) 404) (>= (abs (- (fourth a) 138.5)) 2.5)))
            acts-ro04-heavy))
  (check-true "L45-T2d-ro04-neg-guard-heavy-roach-queen-defense-blocks-blind-flank"
              (null? heavy-flanks)
              (format "heavy-flanks=~a" heavy-flanks)))

;; -----------------------------------------------------------------------------
;; 6. L45-P0-1b (`e01`): Probe Harass Early Rotation at `<= 22` EHP & `>= 26` Replacement Min
;; -----------------------------------------------------------------------------
(let ()
  (define main-nex (mk-u 6000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 12 #:ideal-harvesters 16))
  (define main-mps
    (for/list ([i (in-range 8)])
      (hasheq 'id (+ 7001 i) 'x 26.5 'y (+ 28.0 (* 1.2 i)) 'mineral-contents 1500)))
  (define probes-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 6101 i) 'probe 28.5 (+ 29.0 (* 0.6 i)) #:hp 20.0 #:shield 20.0)))
  (define enemy-probes-2
    (list (mk-u 6901 'probe 33.5 31.5 #:hp 20.0 #:shield 20.0)
          (mk-u 6902 'probe 33.5 33.0 #:hp 20.0 #:shield 20.0)))
  (define rt-e01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-t1
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 800 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-12 #:ally-buildings (list main-nex)
                  #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define pulled-t1
    (remove-duplicates
     (append* (for/list ([a (in-list acts-t1)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  (define def-id (if (pair? pulled-t1) (car pulled-t1) 6101))
  ;; Drop defender to 20 EHP (`hp=20, shield=0`, after 2 focus volleys -> `<= 22.0`!):
  ;; MUST immediately rotate back via `harvest-mineral` (previously stayed locked until `<= 18.0`!)
  (define probes-20ehp
    (for/list ([u (in-list probes-12)])
      (if (= (hash-ref u 'id) def-id)
          (hash-set* u 'hp 20.0 'shield 0.0 'shields 0.0)
          u)))
  (define acts-t2
    (step-layer2-economy!
     rt-e01
     (mk-live-obs 'Protoss 'Protoss 808 #:minerals 110 #:gas 0 #:supply-used 12 #:supply-cap 15
                  #:ally-units probes-20ehp #:ally-buildings (list main-nex)
                  #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define rotated-at-20?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (= (second a) def-id))) acts-t2))
  (check-true "L45-T2e-e01-defending-probe-rotates-out-at-20-ehp-before-lethal-volley"
              (and (>= (length pulled-t1) 1) (<= (length pulled-t1) 2) rotated-at-20?)
              (format "pulled-t1=~a def-id=~a rotated-at-20?=~a acts-t2=~a"
                      pulled-t1 def-id rotated-at-20? acts-t2)))

(printf "\n=== Loop 45 Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
