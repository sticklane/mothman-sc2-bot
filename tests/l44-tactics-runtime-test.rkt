#lang racket/base

(require racket/list
         racket/math
         "../lib/bot-runtime.rkt"
         (prefix-in combat: "../lib/sc2-combat-eval.rkt")
         "../lib/tactics/pro-spellcaster-micro.rkt")

;; =============================================================================
;; Loop 44 (`L44-P0-1a..1c`) Tactics + Live-Runtime Regression Suite
;; Covers:
;;   1. `L44-P0-1a` (Protoss Dip Fix: `#04 PvT` / `#82 PvT` / `b06` / `b07`):
;;      - Stalker Blink-Forward NEVER bypasses `local-enemy-cnt` parity OR blinks into
;;        `>= 2` overlapping enemy Sieged Tanks unless overwhelming (`>= 10` vs light escort)
;;      - Approved Blink-Forward immediately locks post-blink preserved `(attack-unit uid hv-tid)`
;;        onto `best-hv` (skipping Tank-evasion during the `40f` execution window)
;;      - `raider-worker-mult` (`sc2-combat-eval` + `bot-runtime`) gated strictly to mineral-line
;;        runby context (NEVER pulling Zealots/Adepts/Lings off a real frontal army clash!)
;;   2. `L44-P0-1b` (Tactics Arena 3.0 Instant Multipliers):
;;      - `p15`: Zero DT -> Archon `(morph archon)` when enemy has `0` live detectors
;;      - `ro09`: Healthy Oracle (`sh >= 35`, `en < 90`) skips Stasis Ward & activates
;;        `pulsar-beam-on` (`2375`) at `<= 7.5t` (while low-shield `sh < 35` preserves `L43-T3d`!)
;;      - `ro01`/`n05`/`ro26`: Loaded transports fly directly over mineral-line worker clusters
;;        (`<= 2.5t`) or combat armies (`<= 4.5t`) and emit `(unload-all-at tr-id x y)`;
;;        freshly dropped Widow Mines immediately emit preserved `burrow` (`2095`)
;;      - `ro04`: Hellions `MOVE 16` past slow Queens into mineral pocket (`>= 6` workers `<= 14t`),
;;        then roast lined-up worker rows inside `<= 3.8t`
;;   3. `L44-P0-1c` (`rd01` + `r02`/`r05`/`r06` + `#53` Counter-Wave + `d01`/`d02`):
;;      - `rd01`: Skip disarmed/reloading Widow Mines (`weapon-cooldown > 0.9s`); scatter
;;        neighbors onto `> 3.5t` patches (or 2 farthest patches) via `mineral-walk` (`3666`), 0 MOVE spam
;;      - `r02`/`r05`/`r06`: Brief `10f` pre-contact mineral-patch stack when `>= 10` enemy workers
;;        approach at `3.8..8.5t`, releasing cleanly at `+10f` or melee contact `<= 3.8t`
;;      - `#53`: `>= 50`-supply army vs `<= 6` light home harassers leaves `~30%` home guard and
;;        unsieges/dispatches `~65-70%` counter-wave to finish the enemy base
;;      - `d01`/`d02`: Stalkers paired with non-blink DTs cleanly prioritize Missile Turrets /
;;        Photon Cannons (even in `enemy-buildings` and under negative FAP!)
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

(define (run-l34 rt obs [fap-score 0.5])
  (let-values ([(acts _p _t) (step-layer3-and-4-tactics! rt obs fap-score)])
    acts))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0] #:cloak [cloak 3]
              #:flying? [flying? #f] #:burrowed? [burrowed? #f]
              #:cloaked? [cloaked? #f] #:structure? [structure? #f]
              #:build-progress [bp 1.0] #:order-count [oc 0]
              #:order-ability-id [oab 0] #:orders [orders '()]
              #:weapon-cooldown [wcd 0.0]
              #:engaged-target-tag [ett 0]
              #:passengers [passengers '()]
              #:cargo-space-taken [cargo-taken 0]
              #:cargo-space-max [cargo-max 0]
              #:assigned-harvesters [ah 0] #:ideal-harvesters [ih 0])
  (hash 'id id 'type type 'x x 'y y
        'hp hp 'max-hp max-hp
        'shield shield 'shields shield 'max-shield max-shield 'max-shields max-shield
        'energy energy 'cloak cloak 'cloaked cloaked? 'display-type 1
        'flying? flying? 'is-flying flying? 'structure? structure?
        'burrowed? burrowed? 'burrowed burrowed? 'is-burrowed burrowed?
        'build-progress bp 'order-count oc 'order-ability-id oab 'orders orders
        'weapon-cooldown wcd 'engaged-target-tag ett 'powered? #t
        'passengers passengers 'cargo-space-taken cargo-taken 'cargo-space-max cargo-max
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

;; =============================================================================
;; 1. L44-P0-1a: Stalker Blink-Forward Parity + Multi-Tank Guard + Post-Blink Focus + Runby Gate
;; =============================================================================
(let ()
  (define stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 1001 i) 'stalker 60.0 (+ 58.0 (* 0.8 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define stalkers-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 1101 i) 'stalker 60.0 (+ 56.0 (* 0.7 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))

  ;; T1a-i (`#04 PvT` bio wall): 6 Stalkers vs 1 Sieged Tank + 20 Marines (`local-enemy-cnt = 21 > 12`)
  ;; MUST NOT bypass local parity and suicide-blink!
  (define bio-wall-enemies
    (cons (mk-u 9001 'siege-tank-sieged 68.5 60.0 #:hp 175.0)
          (for/list ([i (in-range 20)])
            (mk-u (+ 9100 i) 'marine (+ 66.5 (* 0.2 (modulo i 5))) (+ 57.0 (* 0.6 (quotient i 5))) #:hp 55.0))))
  (define dirs-bio-wall
    (plan-stalker-blink-micro stalkers-6 bio-wall-enemies (make-spell-claims) 800 #:researched-upgrades '(blink)))

  ;; T1a-ii (Multi-Tank overlap): 6 Stalkers vs 3 overlapping Sieged Tanks (`<= 13t`) + 2 Marines
  ;; (`local-enemy-cnt = 5 <= 12`, BUT `other-sieged-tanks-in-range = 2 >= 2`) -> MUST NOT suicide-blink!
  (define multi-tank-enemies
    (list (mk-u 9201 'siege-tank-sieged 68.5 60.0 #:hp 175.0)
          (mk-u 9202 'siege-tank-sieged 72.0 58.0 #:hp 175.0)
          (mk-u 9203 'siege-tank-sieged 72.0 62.0 #:hp 175.0)
          (mk-u 9204 'marine 67.5 59.5 #:hp 55.0)
          (mk-u 9205 'marine 67.5 60.5 #:hp 55.0)))
  (define dirs-multi-tank
    (plan-stalker-blink-micro stalkers-6 multi-tank-enemies (make-spell-claims) 800 #:researched-upgrades '(blink)))

  ;; T1a-iii (Overwhelming Stalkers vs 3 Tanks + light escort): 12 Stalkers vs 3 Tanks + 2 Marines -> ALLOWED!
  (define dirs-overwhelm
    (plan-stalker-blink-micro stalkers-12 multi-tank-enemies (make-spell-claims) 800 #:researched-upgrades '(blink)))
  (check-true "L44-T1a-stalker-blink-forward-blocks-outnumbered-and-multi-tank-overlap-allows-overwhelm"
              (and (null? dirs-bio-wall)
                   (null? dirs-multi-tank)
                   (= (length dirs-overwhelm) 12)
                   (for/and ([d (in-list dirs-overwhelm)])
                     (and (eq? (spell-directive-pattern-name d) 'stalker-blink-forward-snipe)
                          (> (spell-directive-target-tag d) 0))))
              (format "bio-wall=~a multi-tank=~a overwhelm=~a"
                      (length dirs-bio-wall) (length dirs-multi-tank) (length dirs-overwhelm)))

  ;; T1b: Approved Blink-Forward immediately locks post-blink focus-fire `(attack-unit cid hv-tid)`
  ;; on the next tick (`+4f`) instead of Tank-evading away or splitting onto escort Marines!
  (define single-tank-enemies
    (list (mk-u 9301 'siege-tank-sieged 68.5 60.0 #:hp 175.0)
          (mk-u 9302 'marine 66.5 59.0 #:hp 45.0)
          (mk-u 9303 'marine 66.5 61.0 #:hp 45.0)))
  (define rt-bf (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-t0
    (run-l34 rt-bf
             (mk-live-obs 'Protoss 'Terran 800
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units stalkers-6 #:enemy-units single-tank-enemies
                          #:researched-upgrades '(blink))))
  (define landed-stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 1001 i) 'stalker 67.0 (+ 59.0 (* 0.35 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define acts-t1
    (run-l34 rt-bf
             (mk-live-obs 'Protoss 'Terran 804
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units landed-stalkers-6 #:enemy-units single-tank-enemies
                          #:researched-upgrades '(blink))))
  (define blinks-t0 (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'blink))) acts-t0))
  (define tank-focus-t1
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (caddr a) 9301))) acts-t1))
  (check-true "L44-T1b-post-blink-stalkers-immediately-focus-fire-hv-tank-without-evasion-cancel"
              (and (= (length blinks-t0) 6)
                   (= (length tank-focus-t1) 6))
              (format "blinks-t0=~a tank-focus-t1=~a acts-t1=~a"
                      (length blinks-t0) (length tank-focus-t1) (take acts-t1 (min 8 (length acts-t1)))))

  ;; T1c: Runby-Only Worker Mult Gate (`sc2-combat-eval` + `bot-runtime`)
  ;; Frontal clash (Zealot vs 4 Marines + 1 repairing SCV): MUST pick Marine, NOT SCV!
  ;; Mineral-line runby (Zealot/Adept vs 6 SCVs + 1 Marine + CC): MUST still pick SCV!
  (define zealot-u (mk-u 1401 'zealot 60.0 60.0 #:hp 100.0 #:shield 50.0))
  (define adept-u (mk-u 1402 'adept 60.0 60.0 #:hp 70.0 #:shield 70.0))
  (define clash-enemies
    (list (mk-u 9401 'scv 62.5 60.0 #:hp 45.0)
          (mk-u 9402 'marine 62.0 59.5 #:hp 45.0)
          (mk-u 9403 'marine 62.2 60.5 #:hp 45.0)
          (mk-u 9404 'marine 63.0 59.0 #:hp 45.0)
          (mk-u 9405 'marine 63.0 61.0 #:hp 45.0)))
  (define eval-clash-z (combat:select-focus-fire-target zealot-u clash-enemies))
  (define rt-clash-z (select-target-enemy-for-unit 60.0 60.0 clash-enemies 'zealot #f))
  (define eval-clash-a (combat:select-focus-fire-target adept-u clash-enemies))
  (define rt-clash-a (select-target-enemy-for-unit 60.0 60.0 clash-enemies 'adept #f))
  (define runby-enemies
    (list (mk-u 9450 'command-center 61.5 60.0 #:hp 1500.0 #:structure? #t)
          (mk-u 9451 'marine 64.0 60.0 #:hp 45.0)
          (mk-u 9452 'scv 62.5 60.0 #:hp 45.0)
          (mk-u 9453 'scv 63.0 60.5 #:hp 22.0)
          (mk-u 9454 'scv 63.5 59.5 #:hp 45.0)))
  (define eval-runby-z (combat:select-focus-fire-target zealot-u runby-enemies))
  (define rt-runby-z (select-target-enemy-for-unit 60.0 60.0 runby-enemies 'zealot #f))
  (define rt-runby-a (select-target-enemy-for-unit 60.0 60.0 runby-enemies 'adept #f))
  (check-true "L44-T1c-raider-worker-mult-strictly-gated-to-runby-not-frontal-army-clash"
              (and (eq? (hash-ref eval-clash-z 'type) 'marine)
                   (eq? (hash-ref rt-clash-z 'type) 'marine)
                   (eq? (hash-ref eval-clash-a 'type) 'marine)
                   (eq? (hash-ref rt-clash-a 'type) 'marine)
                   (eq? (hash-ref eval-runby-z 'type) 'scv)
                   (eq? (hash-ref rt-runby-z 'type) 'scv)
                   (= (hash-ref rt-runby-a 'id) 9453))
              (format "clash eval-z=~a rt-z=~a eval-a=~a rt-a=~a | runby eval-z=~a rt-z=~a rt-a=~a"
                      (hash-ref eval-clash-z 'type) (hash-ref rt-clash-z 'type)
                      (hash-ref eval-clash-a 'type) (hash-ref rt-clash-a 'type)
                      (hash-ref eval-runby-z 'type) (hash-ref rt-runby-z 'type)
                      (hash-ref rt-runby-a 'id))))

;; =============================================================================
;; 2. L44-P0-1b: Arena 3.0 Instant Multipliers (`p15`, `ro09`, `ro01`/`n05`/`ro26`, `ro04`)
;; =============================================================================
(let ()
  ;; T2a (`p15` Permanent-Cloak KO WIN): Living DTs NEVER morph Archon (`1766`) when enemy has `0` detectors!
  (define rt-p15 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define dts-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 2001 i) 'dark-templar 65.0 (+ 56.0 (* 0.6 i)) #:hp 40.0 #:shield 80.0 #:cloak 1)))
  (define blind-terrans
    (for/list ([i (in-range 12)])
      (mk-u (+ 8001 i) 'marine 67.0 (+ 56.0 (* 0.6 i)) #:hp 45.0)))
  (define pf-bldg (mk-u 8900 'planetary-fortress 68.0 60.0 #:hp 1500.0 #:structure? #t))
  (define obs-p15-nodet
    (mk-live-obs 'Protoss 'Terran 1200
                 #:minerals 400 #:gas 400 #:supply-used 40 #:supply-cap 70
                 #:ally-units dts-10
                 #:enemy-units blind-terrans
                 #:enemy-buildings (list pf-bldg)))
  (define l2-p15-nodet (step-layer2-economy! rt-p15 obs-p15-nodet))
  (define archon-morphs-nodet (filter (lambda (a) (equal? a '(morph archon))) l2-p15-nodet))
  ;; Contrast: with 2 dry HTs (even with 0 detectors), HT -> Archon merge STILL works!
  (define rt-ht (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define dry-hts
    (list (mk-u 2101 'high-templar 32.0 32.0 #:hp 40.0 #:shield 40.0 #:energy 10.0)
          (mk-u 2102 'high-templar 33.0 32.0 #:hp 40.0 #:shield 40.0 #:energy 15.0)))
  (define l2-ht-merge
    (step-layer2-economy! rt-ht
                          (mk-live-obs 'Protoss 'Terran 1200
                                       #:ally-units dry-hts
                                       #:enemy-units blind-terrans
                                       #:enemy-buildings (list pf-bldg))))
  (check-true "L44-T2a-p15-blocks-dt-archon-merge-when-zero-enemy-detectors-allows-dry-ht-merge"
              (and (null? archon-morphs-nodet)
                   (pair? (filter (lambda (a) (equal? a '(morph archon))) l2-ht-merge)))
              (format "dt-nodet-morphs=~a ht-morphs=~a"
                      archon-morphs-nodet (filter (lambda (a) (equal? a '(morph archon))) l2-ht-merge)))

  ;; T2b (`ro09` Oracle Pulsar Beam Priority):
  ;; (i) Healthy Oracle (`sh=60, en=60`) at `7.0t` from 6 Drones -> `pulsar-beam-on` (NOT `stasis-ward`!)
  ;; (ii) Healthy Oracle (`sh=60, en=60`) at `10.0t` approaching 6 Drones -> saves energy (0 `stasis-ward`)!
  ;; (iii) Low-shield Oracle (`sh=20 < 35, en=52`) near 5 SCVs -> STILL plants `stasis-ward` (`L43-T3d`)!
  (define drones-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 8201 i) 'drone 80.0 (+ 58.0 (* 0.5 i)) #:hp 40.0)))
  (define or-7t (mk-u 2201 'oracle 73.2 59.5 #:hp 100.0 #:shield 60.0 #:energy 60.0 #:flying? #t))
  (define or-10t (mk-u 2202 'oracle 70.0 59.5 #:hp 100.0 #:shield 60.0 #:energy 60.0 #:flying? #t))
  (define or-lowsh (mk-u 2203 'oracle 72.0 59.5 #:hp 80.0 #:shield 20.0 #:energy 52.0 #:flying? #t))
  (define d-or-7t (plan-protoss-spellcaster-micro (list or-7t) drones-6 #:claims (make-spell-claims) #:current-frame 1000))
  (define d-or-10t (plan-protoss-spellcaster-micro (list or-10t) drones-6 #:claims (make-spell-claims) #:current-frame 1000))
  (define d-or-lowsh (plan-protoss-spellcaster-micro (list or-lowsh) drones-6 #:claims (make-spell-claims) #:current-frame 1000))
  (check-true "L44-T2b-ro09-healthy-oracle-pops-pulsar-beam-at-7.5t-skips-stasis-preserves-low-shield-stasis"
              (and (= (length d-or-7t) 1)
                   (eq? (spell-directive-ability (car d-or-7t)) 'pulsar-beam-on)
                   (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'stasis-ward)) d-or-10t))
                   (= (length d-or-lowsh) 1)
                   (eq? (spell-directive-ability (car d-or-lowsh)) 'stasis-ward))
              (format "7t=~a 10t=~a lowsh=~a" d-or-7t d-or-10t d-or-lowsh))

  ;; T2c (`ro01` Widow Mine Medivac, `n05` Warp Prism + Archons, `ro26` Baneling Drop):
  (define scvs-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 8301 i) 'scv (+ 80.0 (* 0.4 (modulo i 5))) (+ 60.0 (* 0.4 (quotient i 5))) #:hp 45.0)))
  (define wm-pax (for/list ([i (in-range 4)]) (hash 'id (+ 2350 i) 'type 'widow-mine 'hp 90 'max-hp 90)))
  (define med-far (mk-u 2301 'medivac 70.0 60.0 #:hp 150.0 #:max-hp 150.0 #:flying? #t
                        #:passengers wm-pax #:cargo-space-taken 8 #:cargo-space-max 8))
  (define med-over (mk-u 2301 'medivac 80.5 60.5 #:hp 150.0 #:max-hp 150.0 #:flying? #t
                         #:passengers wm-pax #:cargo-space-taken 8 #:cargo-space-max 8))
  (define rt-ro01 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-med-far
    (run-l34 rt-ro01 (mk-live-obs 'Terran 'Terran 500 #:ally-units (list med-far) #:enemy-units scvs-10)))
  (define acts-med-over
    (run-l34 rt-ro01 (mk-live-obs 'Terran 'Terran 520 #:ally-units (list med-over) #:enemy-units scvs-10)))
  ;; Freshly dropped unburrowed Widow Mine near SCVs immediately burrows (`2095`) even under negative FAP!
  (define wm-dropped (mk-u 2350 'widow-mine 80.0 60.0 #:hp 90.0 #:max-hp 90.0))
  (define acts-wm-burrow
    (run-l34 rt-ro01 (mk-live-obs 'Terran 'Terran 530 #:ally-units (list wm-dropped) #:enemy-units scvs-10) -500.0))
  ;; `n05` Warp Prism + 2 Archons over enemy combat army (`<= 4.5t`) emits `(unload-all-at ...)`
  (define archon-pax (list (hash 'id 2450 'type 'archon 'hp 360 'max-hp 360)
                           (hash 'id 2451 'type 'archon 'hp 360 'max-hp 360)))
  (define prism-over (mk-u 2401 'warp-prism 76.5 60.0 #:hp 80.0 #:shield 100.0 #:max-hp 180.0 #:flying? #t
                           #:passengers archon-pax #:cargo-space-taken 8 #:cargo-space-max 8))
  (define army-zerg (for/list ([i (in-range 8)]) (mk-u (+ 8401 i) 'hydralisk 80.0 (+ 58.0 (* 0.5 i)) #:hp 90.0)))
  (define rt-n05 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-prism-over
    (run-l34 rt-n05 (mk-live-obs 'Protoss 'Zerg 600 #:ally-units (list prism-over) #:enemy-units army-zerg)))
  ;; `ro26` Dropperlord + 4 Banelings over enemy Probes (`<= 2.5t`) emits `(unload-all-at ...)`
  (define bane-pax (for/list ([i (in-range 4)]) (hash 'id (+ 2550 i) 'type 'baneling 'hp 30 'max-hp 30)))
  (define ovi-over (mk-u 2501 'overlord-transport 80.5 60.5 #:hp 200.0 #:max-hp 200.0 #:flying? #t
                         #:passengers bane-pax #:cargo-space-taken 8 #:cargo-space-max 8))
  (define rt-ro26 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-ovi-over
    (run-l34 rt-ro26 (mk-live-obs 'Zerg 'Terran 600 #:ally-units (list ovi-over) #:enemy-units scvs-10)))
  (check-true "L44-T2c-ro01-n05-ro26-loaded-transports-fly-over-unload-and-dropped-wm-instantly-burrows"
              (and (ormap (lambda (a) (and (pair? a) (= (second a) 2301)
                                           (or (eq? (car a) 'move)
                                               (and (eq? (car a) 'cast-spell) (eq? (caddr a) 'medivac-boost)))))
                          acts-med-far)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'unload-all-at) (= (second a) 2301))) acts-med-over)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (= (second a) 2350) (eq? (caddr a) 'burrow)))
                          acts-wm-burrow)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'unload-all-at) (= (second a) 2401))) acts-prism-over)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'unload-all-at) (= (second a) 2501))) acts-ovi-over))
              (format "med-far=~a med-over=~a wm-burrow=~a prism=~a ovi=~a"
                      (filter (lambda (a) (and (pair? a) (equal? (second a) 2301))) acts-med-far)
                      (filter (lambda (a) (and (pair? a) (equal? (second a) 2301))) acts-med-over)
                      (filter (lambda (a) (and (pair? a) (equal? (second a) 2350))) acts-wm-burrow)
                      (filter (lambda (a) (and (pair? a) (equal? (second a) 2401))) acts-prism-over)
                      (filter (lambda (a) (and (pair? a) (equal? (second a) 2501))) acts-ovi-over)))

  ;; T2d (`ro04` Hellion Runby): Hellion at `7.5t` from 10 Drones with 2 slow Queens blocking at `3.0t`
  ;; MUST `MOVE 16` past the Queens into the Drone mineral pocket (and NEVER be hijacked by Phase 7
  ;; `multitask-harass-and-proxy`!); once `<= 3.5t`, roasts Drones cleanly!
  (define rt-ro04-a (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define rt-ro04-b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define hellion-approach (mk-u 2601 'hellion 72.5 60.0 #:hp 90.0))
  (define hellion-pocket (mk-u 2601 'hellion 77.5 60.0 #:hp 90.0))
  (define z-def-and-drones
    (append (list (mk-u 8601 'queen 75.5 59.5 #:hp 175.0)
                  (mk-u 8602 'queen 75.5 60.5 #:hp 175.0))
            (for/list ([i (in-range 10)])
              (mk-u (+ 8610 i) 'drone (+ 80.0 (* 0.4 (modulo i 5))) (+ 59.0 (* 0.5 (quotient i 5))) #:hp 40.0))))
  (define acts-h-approach
    (run-l34 rt-ro04-a (mk-live-obs 'Terran 'Zerg 700 #:ally-units (list hellion-approach) #:enemy-units z-def-and-drones)))
  (define acts-h-pocket
    (run-l34 rt-ro04-b (mk-live-obs 'Terran 'Zerg 720 #:ally-units (list hellion-pocket) #:enemy-units z-def-and-drones)))
  (define h-app-acts (filter (lambda (a) (and (pair? a) (equal? (second a) 2601))) acts-h-approach))
  (define h-pkt-acts (filter (lambda (a) (and (pair? a) (equal? (second a) 2601))) acts-h-pocket))
  (check-true "L44-T2d-ro04-hellion-dives-past-queens-into-mineral-pocket-then-roasts-drones"
              (and (= (length h-app-acts) 1)
                   (eq? (car (car h-app-acts)) 'move)
                   (> (third (car h-app-acts)) 78.0)
                   (= (length h-pkt-acts) 1)
                   (eq? (car (car h-pkt-acts)) 'attack-unit)
                   (>= (caddr (car h-pkt-acts)) 8610))
              (format "approach=~a pocket=~a" h-app-acts h-pkt-acts)))

;; =============================================================================
;; 3. L44-P0-1c: `rd01`, `r02`/`r05`/`r06` Pre-Contact Stack, `#53` Counter-Wave, `d01`/`d02`
;; =============================================================================
(let ()
  ;; T3a (`rd01` Widow Mine Drop Defense):
  ;; (i) Disarmed Widow Mine (`weapon-cooldown = 18.0s > 0.9s`) -> ZERO pulls/scatters!
  ;; (ii) Armed Widow Mine (`weapon-cooldown = 0.0s`) with patches at `3.8t` -> pulls 1 targeted Probe
  ;;      and scatters neighbors via `mineral-walk` (`3666`), ZERO `MOVE 16` spam on neighbors!
  ;; (iii) Armed Widow Mine dead-center where ALL patches are `<= 3.4t` -> falls back to 2 farthest
  ;;       patches via `mineral-walk` (still ZERO `MOVE 16` on neighbors!)
  (define probes-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 3101 i) 'probe (+ 28.0 (* 0.35 i)) (+ 31.5 (* 0.3 (modulo i 2))) #:hp 20.0 #:shield 20.0)))
  (define mps-3.8t
    (list (hash 'id 99101 'x 25.0 'y 29.0)
          (hash 'id 99102 'x 25.0 'y 34.5)))
  (define mps-tight
    (list (hash 'id 99201 'x 27.5 'y 30.0)
          (hash 'id 99202 'x 27.5 'y 34.5)
          (hash 'id 99203 'x 31.0 'y 32.0)))
  (define wm-reloading (mk-u 8801 'widow-mine-burrowed 28.5 32.0 #:hp 90.0 #:burrowed? #t #:weapon-cooldown 18.0 #:engaged-target-tag 3103))
  (define wm-armed (mk-u 8802 'widow-mine-burrowed 28.5 32.0 #:hp 90.0 #:burrowed? #t #:weapon-cooldown 0.0 #:engaged-target-tag 3103))
  (define nexus-home (mk-u 3001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:structure? #t))
  (define rt-rd01-a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define l2-disarmed
    (step-layer2-economy! rt-rd01-a
                          (mk-live-obs 'Protoss 'Terran 1400
                                       #:ally-units probes-6 #:ally-buildings (list nexus-home)
                                       #:enemy-units (list wm-reloading) #:mineral-patches mps-3.8t)))
  (define rt-rd01-b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define l2-armed-3.8
    (step-layer2-economy! rt-rd01-b
                          (mk-live-obs 'Protoss 'Terran 1400
                                       #:ally-units probes-6 #:ally-buildings (list nexus-home)
                                       #:enemy-units (list wm-armed) #:mineral-patches mps-3.8t)))
  (define rt-rd01-c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define l2-armed-tight
    (step-layer2-economy! rt-rd01-c
                          (mk-live-obs 'Protoss 'Terran 1400
                                       #:ally-units probes-6 #:ally-buildings (list nexus-home)
                                       #:enemy-units (list wm-armed) #:mineral-patches mps-tight)))
  (define dis-moves (filter (lambda (a) (and (pair? a) (memq (car a) '(move mineral-walk)) (memv (second a) '(3101 3102 3103 3104 3105 3106)))) l2-disarmed))
  (define arm38-nb-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(3101 3102 3104 3105 3106)))) l2-armed-3.8))
  (define arm38-nb-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (memv (second a) '(3101 3102 3104 3105 3106)))) l2-armed-3.8))
  (define arm38-sac-pull (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 3103))) l2-armed-3.8))
  (define tight-nb-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(3101 3102 3104 3105 3106)))) l2-armed-tight))
  (define tight-nb-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (memv (second a) '(3101 3102 3104 3105 3106)))) l2-armed-tight))
  (check-true "L44-T3a-rd01-skips-disarmed-wm-and-scatters-neighbors-via-mineral-walk-not-move-spam"
              (and (null? dis-moves)
                   (= (length arm38-sac-pull) 1)
                   (null? arm38-nb-moves)
                   (>= (length arm38-nb-mws) 4)
                   (null? tight-nb-moves)
                   (>= (length tight-nb-mws) 4))
              (format "dis-moves=~a sac=~a 38-moves=~a 38-mws=~a tight-moves=~a tight-mws=~a"
                      (length dis-moves) (length arm38-sac-pull) (length arm38-nb-moves)
                      (length arm38-nb-mws) (length tight-nb-moves) (length tight-nb-mws)))

  ;; T3b (10-Probe non-allin pre-contact `4f` stack — L48-W3 disables pre-stack on >=11 static all-ins):
  ;; Spread `16` defenders (`spread > 4t`) vs `10` approaching enemy Probes at `6.0t` -> stacks on
  ;; front mineral patch for `4f` (`900`, `904`), then releases into `pull-workers-attack` at `910`!
  (define rt-r05 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define cc-home (mk-u 4001 'command-center 32.5 32.5 #:hp 1500.0 #:structure? #t))
  (define spread-scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 4101 i) 'scv (+ 25.0 (* 0.2 (modulo i 3))) (+ 27.0 (* 0.75 i)) #:hp 45.0)))
  (define approach-probes-12
    (for/list ([i (in-range 10)])
      (mk-u (+ 8901 i) 'probe (+ 32.5 (* 0.25 (modulo i 4))) (+ 31.5 (* 0.35 (quotient i 4))) #:hp 20.0 #:shield 20.0)))
  (define base-mps
    (list (hash 'id 99301 'x 26.0 'y 28.0)
          (hash 'id 99302 'x 26.0 'y 32.0)
          (hash 'id 99303 'x 26.0 'y 36.0)))
  (define (r05-obs fr)
    (mk-live-obs 'Terran 'Protoss fr
                 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                 #:ally-units spread-scvs-16 #:ally-buildings (list cc-home)
                 #:enemy-units approach-probes-12 #:mineral-patches base-mps))
  (define acts-r05-900 (step-layer2-economy! rt-r05 (r05-obs 900)))
  (define acts-r05-904 (step-layer2-economy! rt-r05 (r05-obs 904)))
  (define acts-r05-910 (step-layer2-economy! rt-r05 (r05-obs 910)))
  (define mw-900 (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-r05-900))
  (define atk-900 (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-r05-900))
  (define mw-904 (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-r05-904))
  (define atk-910 (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-r05-910))
  (check-true "L44-T3b-r05-pre-contact-4f-mineral-stack-then-simultaneous-pull-attack-release"
              (and (>= (length mw-900) 10)
                   (null? atk-900)
                   (>= (length mw-904) 10)
                   (pair? atk-910))
              (format "f900 mw=~a atk=~a | f904 mw=~a | f910 atk=~a"
                      (length mw-900) (length atk-900) (length mw-904) (length atk-910)))

  ;; T3c (`#53 zig-reapers` Counter-Wave Split):
  ;; `5` Sieged Tanks + `25` Marines (`40` supply -> add 10 Marauders = `60` supply!) at home vs
  ;; `2` Reapers in main (`enemy` main in Fog!) -> leaves `<= 12` closest Marines for Reapers,
  ;; unsieges Tanks & dispatches `>= 20` units to `(enemy-x, enemy-y)`!
  (define rt-53 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'MothmanApexVictory))
  (define army-53
    (append
     (for/list ([i (in-range 5)])
       (mk-u (+ 5001 i) 'siege-tank-sieged (+ 40.0 i) 34.0 #:hp 175.0))
     (for/list ([i (in-range 25)])
       (mk-u (+ 5101 i) 'marine (+ 36.0 (* 0.5 (modulo i 5))) (+ 32.0 (* 0.5 (quotient i 5))) #:hp 45.0))
     (for/list ([i (in-range 10)])
       (mk-u (+ 5201 i) 'marauder (+ 42.0 (* 0.5 (modulo i 5))) (+ 35.0 (* 0.5 (quotient i 5))) #:hp 125.0))))
  (define reapers-2
    (list (mk-u 8951 'reaper 34.0 32.0 #:hp 60.0)
          (mk-u 8952 'reaper 34.5 32.5 #:hp 60.0)))
  (define acts-53
    (run-l34 rt-53
             (mk-live-obs 'Terran 'Terran 14000
                          #:supply-used 119 #:supply-cap 134
                          #:ally-units army-53 #:ally-buildings (list cc-home)
                          #:enemy-units reapers-2
                          #:enemy-x 140.0 #:enemy-y 120.0)))
  (define cw-attacks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos)
                             (>= (third a) 130.0) (>= (fourth a) 110.0)))
            acts-53))
  (define cw-unsieges
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'unsiege-mode))) acts-53))
  (define home-reaper-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (caddr a) '(8951 8952)))) acts-53))
  ;; Negative guard: heavy home threat (4 Roaches + 2 Reapers) must NOT abandon home!
  (define heavy-home-enemies
    (append reapers-2
            (for/list ([i (in-range 4)]) (mk-u (+ 8960 i) 'roach 35.0 (+ 31.0 i) #:hp 145.0))))
  (define rt-53-neg (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'MothmanApexVictory))
  (define acts-53-neg
    (run-l34 rt-53-neg
             (mk-live-obs 'Terran 'Zerg 14000
                          #:supply-used 119 #:supply-cap 134
                          #:ally-units army-53 #:ally-buildings (list cc-home)
                          #:enemy-units heavy-home-enemies
                          #:enemy-x 140.0 #:enemy-y 120.0)))
  (define neg-cw-attacks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos)
                             (>= (third a) 130.0) (>= (fourth a) 110.0)))
            acts-53-neg))
  (check-true "L44-T3c-53-large-army-splits-home-guard-and-dispatches-65pct-counter-wave-vs-light-harass"
              (and (>= (length cw-attacks) 20)
                   (= (length cw-unsieges) 5)
                   (>= (length home-reaper-atks) 4)
                   (<= (length home-reaper-atks) 12)
                   (null? neg-cw-attacks))
              (format "cw-atk=~a unsiege=~a home-guard=~a neg-cw-atk=~a"
                      (length cw-attacks) (length cw-unsieges) (length home-reaper-atks) (length neg-cw-attacks)))

  ;; T3d (`d01`/`d02` Detector Snipe):
  ;; `4` non-blink DTs + `8` Stalkers vs `1` Missile Turret (in `enemy-buildings`) + `12` Marines + `4` Marauders
  ;; under negative FAP (`-500.0`) -> ALL 8 Stalkers focus-fire the Missile Turret (`9701`)!
  ;; And vs `2` Photon Cannons (in `enemy-buildings`) + `10` Zealots -> ALL 8 Stalkers focus-fire a Photon Cannon!
  (define rt-d01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define d01-allies
    (append
     (for/list ([i (in-range 4)]) (mk-u (+ 6001 i) 'dark-templar 55.0 (+ 58.0 i) #:hp 40.0 #:shield 80.0 #:cloak 1))
     (for/list ([i (in-range 8)]) (mk-u (+ 6101 i) 'stalker 53.0 (+ 56.0 i) #:hp 80.0 #:shield 80.0))))
  (define d01-turret (mk-u 9701 'missile-turret 67.0 60.0 #:hp 250.0 #:structure? #t))
  (define d01-bio
    (append
     (for/list ([i (in-range 12)]) (mk-u (+ 9710 i) 'marine 64.0 (+ 54.0 i) #:hp 45.0))
     (for/list ([i (in-range 4)]) (mk-u (+ 9730 i) 'marauder 63.0 (+ 58.0 i) #:hp 125.0))))
  (define acts-d01
    (run-l34 rt-d01
             (mk-live-obs 'Protoss 'Terran 400
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units d01-allies
                          #:enemy-units d01-bio #:enemy-buildings (list d01-turret))
             -500.0))
  (define d01-stalker-turret-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (>= (second a) 6101) (<= (second a) 6108)
                             (= (caddr a) 9701)))
            acts-d01))
  (define rt-d02 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define d02-cannons
    (list (mk-u 9801 'photon-cannon 66.0 58.0 #:hp 150.0 #:shield 150.0 #:structure? #t)
          (mk-u 9802 'photon-cannon 66.0 62.0 #:hp 150.0 #:shield 150.0 #:structure? #t)))
  (define d02-zealots
    (for/list ([i (in-range 10)]) (mk-u (+ 9810 i) 'zealot 63.0 (+ 55.0 i) #:hp 100.0 #:shield 50.0)))
  (define acts-d02
    (run-l34 rt-d02
             (mk-live-obs 'Protoss 'Protoss 400
                          #:base-x 20.0 #:base-y 20.0 #:nat-x 35.0 #:nat-y 35.0
                          #:ally-units d01-allies
                          #:enemy-units d02-zealots #:enemy-buildings d02-cannons)
             -500.0))
  (define d02-stalker-cannon-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (>= (second a) 6101) (<= (second a) 6108)
                             (memv (caddr a) '(9801 9802))))
            acts-d02))
  (check-true "L44-T3d-d01-d02-stalkers-paired-with-non-blink-dts-snipe-turret-and-cannons-under-neg-fap"
              (and (= (length d01-stalker-turret-atks) 8)
                   (= (length d02-stalker-cannon-atks) 8))
              (format "d01-turret-atks=~a/8 d02-cannon-atks=~a/8"
                      (length d01-stalker-turret-atks) (length d02-stalker-cannon-atks))))

(printf "\n=== Loop 44 Tactics/Runtime Suite: ~a PASS, ~a FAIL ===\n" pass-cnt fail-cnt)
(when (> fail-cnt 0)
  (exit 1))
