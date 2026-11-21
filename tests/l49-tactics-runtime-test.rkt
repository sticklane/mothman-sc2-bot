#lang racket/base

;; =============================================================================
;; Loop 49 Wave 1 Tactics & Runtime Verification Suite (`#1145`)
;; Covers:
;;   1. L49-T1a: Stall Watchdog Law 2 — Gas Valve (`'pull-to-minerals` & `'force-saturate-gas`)
;;   2. L49-T1b: Stall Watchdog Law 2 — Zero-Income Recovery (`>= 48f`, worker-rush guarded)
;;   3. L49-T1c: Stall Watchdog Law 4 — Halted Terran Building (`>= 24f` unchanged -> P0 SCV resume)
;;   4. L49-T1d: Terran Unpressured Bunker Trim (0 spam when ahead; full emergency Bunker preserved)
;;   5. L49-T2a: Stalker Blink-Forward (`b06`/`b07` close-in, `<= 2.0t` dead-zone, chain HV focus)
;;   6. L49-T2b: Detection-Snipe (`d01`/`d02`/`d04`/`d17` DT staging, unified detector focus, Overseer escort)
;;   7. L49-T2c: Oracle Runby (`ro09` zero Stasis spam at `en=100`, Fog backside push, SCV shred)
;;   8. L49-T2d: Cloaked Banshee vs Corner Spore (`ro11` zero cloak-2 spam, safe-wing Spore avoidance)
;;   9. L49-T2e: Protoss Kiting Worker-Rush (`r16` pinned miners at `h-cnt=6` + Zealot #1 `7.5t` guard)
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/tactics/order-ledger.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/tactics/unit-mode-micro.rkt"
         "../lib/tactics/arena-minimax.rkt"
         "../lib/tactics/zerg-burrow-micro.rkt")

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
              #:hp [hp 80.0] #:max-hp [mhp hp]
              #:shield [sh 0.0] #:max-shield [msh sh]
              #:energy [en 0.0]
              #:cloak [clk 3]
              #:flying [fly? #f]
              #:build-progress [bp 1.0]
              #:assigned-harvesters [ah #f]
              #:ideal-harvesters [ih #f]
              #:vespene-contents [vc #f]
              #:orders [ords '()]
              #:order-ability-id [oab 0]
              #:order-target-id [otid 0]
              #:buffs [buffs '()]
              #:weapon-cooldown [wcd 0.0]
              #:has-builder [hb #t]
              #:add-on-tag [aot 0])
  (define h0
    (hasheq 'id id 'type type 'x x 'y y
            'hp hp 'max-hp mhp
            'shield sh 'shields sh 'max-shield msh
            'energy en 'cloak clk 'flying fly? 'is-flying fly?
            'build-progress bp 'orders ords
            'order-ability-id oab 'order-target-id otid
            'buffs buffs 'weapon-cooldown wcd 'has-builder hb
            'add-on-tag aot
            'display-type 1))
  (define h1 (if ah (hash-set h0 'assigned-harvesters ah) h0))
  (define h2 (if ih (hash-set h1 'ideal-harvesters ih) h1))
  (if vc (hash-set h2 'vespene-contents vc) h2))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 150]
                     #:gas [gas 0]
                     #:supply-used [su 30]
                     #:supply-cap [sc 46]
                     #:mineral-harvesters [mh 16]
                     #:vespene-harvesters [vh 0]
                     #:min-rate [mr #f]
                     #:vesp-rate [vr #f]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:mineral-patches [mps '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 62.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 142.5] #:enemy-y [ey 138.5]
                     #:researched-upgrades [upgs '()])
  (define base
    (hasheq 'race race 'enemy-race enemy-race 'frame frame
            'live-game? #t 'live-obs? #t 'live-obs-harvesters? #t
            'minerals minerals 'gas gas
            'supply-used su 'supply-cap sc
            'mineral-harvesters mh 'vespene-harvesters vh 'gas-harvesters vh
            'ally-units au 'ally-buildings ab
            'enemy-units eu 'enemy-buildings eb
            'mineral-patches mps
            'base-x bx 'base-y by 'nat-x nx 'nat-y ny 'natural-x nx 'natural-y ny
            'enemy-x ex 'enemy-y ey
            'researched-upgrades upgs 'upgrades-tracked? #t
            'map-width 176 'map-height 176))
  (define b1 (if mr (hash-set base 'collection-rate-minerals mr) base))
  (if vr (hash-set b1 'collection-rate-vespene vr) b1))

(define (run-l34 rt obs [fap 0.5])
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt) obs)
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(define (dist2d-t x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(printf "=== Loop 49 Tactics & Runtime Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L49-T1a: Stall Watchdog Law 2 — Gas Valve (`'pull-to-minerals` & `'force-saturate-gas`)
;; -----------------------------------------------------------------------------
(let ()
  (define cc (mk-u 1001 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 14 #:ideal-harvesters 16))
  (define ref (mk-u 1002 'refinery 28.5 36.5 #:hp 500.0 #:assigned-harvesters 3 #:ideal-harvesters 3 #:vespene-contents 1800))
  (define mps (list (hasheq 'id 1901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define scvs-pull
    (append (for/list ([i (in-range 3)])
              (mk-u (+ 1101 i) 'scv 29.0 (+ 35.5 (* 0.3 i)) #:hp 45.0 #:order-ability-id 3666 #:order-target-id 1002))
            (for/list ([i (in-range 17)])
              (mk-u (+ 1110 i) 'scv 28.0 (+ 30.0 (* 0.3 i)) #:hp 45.0 #:order-ability-id 3666 #:order-target-id 1901))))
  ;; (i) Gas-rich (`500G`) + mineral-starved (`120M`) + `< 175` supply -> MUST emit `rebalance-gas-to-minerals`!
  (define a-pull
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Zerg 6000 #:minerals 120 #:gas 500 #:supply-used 90 #:supply-cap 110
                  #:mineral-harvesters 17 #:vespene-harvesters 3 #:vesp-rate 160
                  #:ally-units scvs-pull #:ally-buildings (list cc ref) #:mineral-patches mps)))
  (define reb-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'rebalance-gas-to-minerals))) a-pull))
  ;; (ii) `sec >= 300` (`f=7200`), `20` workers, empty ready Refinery (`assigned=0`, `vesp-rate=0`) -> MUST emit `harvest-gas`!
  (define ref-empty (mk-u 1002 'refinery 28.5 36.5 #:hp 500.0 #:assigned-harvesters 0 #:ideal-harvesters 3 #:vespene-contents 1800))
  (define scvs-fill
    (for/list ([i (in-range 20)])
      (mk-u (+ 1201 i) 'scv 28.0 (+ 30.0 (* 0.3 i)) #:hp 45.0 #:orders (if (< i 3) '() (list (hasheq 'ability-id 3666))))))
  (define a-fill
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Zerg 7200 #:minerals 300 #:gas 20 #:supply-used 60 #:supply-cap 78
                  #:mineral-harvesters 17 #:vespene-harvesters 0 #:vesp-rate 0
                  #:ally-units scvs-fill #:ally-buildings (list cc ref-empty) #:mineral-patches mps)))
  (define fill-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'harvest-gas) (= (third a) 1002))) a-fill))
  (check-true "L49-T1a-watchdog-law2-gas-valve-pull-and-force-saturate"
              (and reb-act
                   (list? (second reb-act))
                   (>= (length (second reb-act)) 2)
                   fill-act
                   (list? (second fill-act))
                   (>= (length (second fill-act)) 2))
              (format "reb=~a fill=~a" reb-act fill-act)))

;; -----------------------------------------------------------------------------
;; 2. L49-T1b: Stall Watchdog Law 2 — Zero-Income Recovery (`>= 48f`, worker-rush guarded)
;; -----------------------------------------------------------------------------
(let ()
  (define cc (mk-u 2001 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 0 #:ideal-harvesters 16))
  (define mps (list (hasheq 'id 2901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 0)
                    (hasheq 'id 2902 'type 'mineral-field 'x 60.5 'y 32.5 'mineral-contents 1500)))
  (define scvs-stalled
    (for/list ([i (in-range 12)])
      ;; Simulate workers stranded near enemy scout or stuck on depleted patch (`orders` non-empty stale move!)
      (mk-u (+ 2101 i) 'scv 30.0 (+ 30.0 (* 0.3 i)) #:hp 45.0 #:orders (list (hasheq 'ability-id 16)) #:order-ability-id 16)))
  (define rt-zi (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (void (step-layer2-economy!
         rt-zi
         (mk-live-obs 'Terran 'Protoss 3000 #:minerals 80 #:gas 0 #:supply-used 12 #:supply-cap 23
                      #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                      #:ally-units scvs-stalled #:ally-buildings (list cc) #:mineral-patches mps)))
  (define a-zi-52
    (step-layer2-economy!
     rt-zi
     (mk-live-obs 'Terran 'Protoss 3052 #:minerals 80 #:gas 0 #:supply-used 12 #:supply-cap 23
                  #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                  #:ally-units scvs-stalled #:ally-buildings (list cc) #:mineral-patches mps)))
  (define zi-harvs
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (= (third a) 2902))) a-zi-52))
  ;; (ii) Under active 15-Probe worker rush: `wd-zero-income-recovery?` MUST stay `#f` (never yank fighters!)
  (define rt-wr (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define probes-15 (for/list ([i (in-range 15)]) (mk-u (+ 2801 i) 'probe 35.0 (+ 31.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (void (step-layer2-economy!
         rt-wr
         (mk-live-obs 'Terran 'Protoss 1000 #:minerals 50 #:gas 0 #:supply-used 12 #:supply-cap 23
                      #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                      #:ally-units scvs-stalled #:ally-buildings (list cc)
                      #:enemy-units probes-15 #:mineral-patches mps)))
  (define a-wr-52
    (step-layer2-economy!
     rt-wr
     (mk-live-obs 'Terran 'Protoss 1052 #:minerals 50 #:gas 0 #:supply-used 12 #:supply-cap 23
                  #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                  #:ally-units scvs-stalled #:ally-buildings (list cc)
                  #:enemy-units probes-15 #:mineral-patches mps)))
  (define wr-rec? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'return-workers-to-gather))) a-wr-52))
  (check-true "L49-T1b-watchdog-law2-zero-income-recovery-and-worker-rush-guard"
              (and (>= (length zi-harvs) 8)
                   (not wr-rec?))
              (format "zi-harvs=~a wr-rec?=~a" (length zi-harvs) wr-rec?)))

;; -----------------------------------------------------------------------------
;; 3. L49-T1c: Stall Watchdog Law 4 — Halted Terran Building (`>= 24f` unchanged -> P0 SCV resume)
;; -----------------------------------------------------------------------------
(let ()
  (define cc (mk-u 3001 'command-center 32.5 32.5 #:hp 1500.0))
  ;; Factory stuck at `build-progress = 0.45` WITHOUT `'halted #t` and WITH `'has-builder #t`!
  (define fac-stuck (mk-u 3002 'factory 36.5 34.5 #:hp 600.0 #:build-progress 0.45 #:has-builder #t))
  (define scvs (for/list ([i (in-range 12)]) (mk-u (+ 3101 i) 'scv 29.0 (+ 30.0 (* 0.3 i)) #:hp 45.0)))
  (define rt-h (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-t0
    (step-layer2-economy!
     rt-h
     (mk-live-obs 'Terran 'Zerg 2500 #:minerals 150 #:gas 100 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 12 #:ally-units scvs #:ally-buildings (list cc fac-stuck))))
  (define a-t28
    (step-layer2-economy!
     rt-h
     (mk-live-obs 'Terran 'Zerg 2528 #:minerals 150 #:gas 100 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 12 #:ally-units scvs #:ally-buildings (list cc fac-stuck))))
  (define res-t0? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'resume-halted-building) (= (third a) 3002))) a-t0))
  (define res-t28? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'resume-halted-building) (= (third a) 3002))) a-t28))
  (check-true "L49-T1c-watchdog-law4-halted-terran-building-24f-p0-resume"
              (and (not res-t0?) res-t28?)
              (format "t0?=~a t28?=~a" res-t0? res-t28?)))

;; -----------------------------------------------------------------------------
;; 4. L49-T1d: Terran Unpressured Bunker Trim (0 spam when ahead; emergency Bunker preserved)
;; -----------------------------------------------------------------------------
(let ()
  (define cc1 (mk-u 4001 'command-center 32.5 32.5 #:hp 1500.0))
  (define cc2 (mk-u 4002 'command-center 62.5 32.5 #:hp 1500.0))
  (define rax (mk-u 4003 'barracks 36.5 36.5 #:hp 1000.0))
  (define scvs (for/list ([i (in-range 22)]) (mk-u (+ 4101 i) 'scv 29.0 (+ 30.0 (* 0.2 i)) #:hp 45.0)))
  (define marines-14 (for/list ([i (in-range 14)]) (mk-u (+ 4201 i) 'marine 55.0 (+ 31.0 (* 0.2 i)) #:hp 45.0)))
  ;; (i) Unpressured macro: 14 Marines (`army=14`) vs 3 distant Stalkers (`threat=6`, far at `x=120`) -> 0 Bunker!
  (define stalkers-far (for/list ([i (in-range 3)]) (mk-u (+ 4801 i) 'stalker 120.0 (+ 120.0 i) #:hp 80.0 #:shield 80.0)))
  (define a-unp
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 4500 #:minerals 250 #:gas 100 #:supply-used 36 #:supply-cap 54
                  #:mineral-harvesters 22 #:ally-units (append scvs marines-14)
                  #:ally-buildings (list cc1 cc2 rax) #:enemy-units stalkers-far)))
  (define unp-bunker? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) a-unp))
  ;; (ii) Pressured/outnumbered rush: 2 Marines vs 5 Stalkers at base (`x=42`) -> MUST build Bunker!
  (define stalkers-rush (for/list ([i (in-range 5)]) (mk-u (+ 4851 i) 'stalker 42.0 (+ 32.0 i) #:hp 80.0 #:shield 80.0)))
  (define a-rush
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 3200 #:minerals 200 #:gas 0 #:supply-used 24 #:supply-cap 31
                  #:mineral-harvesters 22 #:ally-units (append scvs (take marines-14 2))
                  #:ally-buildings (list cc1 rax) #:enemy-units stalkers-rush)))
  (define rush-bunker? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) a-rush))
  (check-true "L49-T1d-terran-unpressured-bunker-trim-and-rush-bunker-preserve"
              (and (not unp-bunker?) rush-bunker?)
              (format "unp-bunker?=~a rush-bunker?=~a" unp-bunker? rush-bunker?)))

;; -----------------------------------------------------------------------------
;; 5. L49-T2a: Stalker Blink-Forward (`b06`/`b07` Close-In, Dead-Zone `<= 2.0t`, Chain HV Focus)
;; -----------------------------------------------------------------------------
(let ()
  ;; 14 Blink Stalkers vs 3 Sieged Tanks + 12 Marines + 1 Medivac (`b06` geometry!)
  (define tanks-3
    (list (mk-u 5801 'siege-tank-sieged 85.8 88.0 #:hp 175.0)
          (mk-u 5802 'siege-tank-sieged 85.8 86.0 #:hp 175.0)
          (mk-u 5803 'siege-tank-sieged 85.8 90.0 #:hp 175.0)))
  (define marines-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 5810 i) 'marine 83.6 (+ 85.0 (* 0.5 i)) #:hp 55.0)))
  (define med-1 (mk-u 5899 'medivac 86.6 88.0 #:hp 150.0 #:flying #t))
  (define b06-enemies (append tanks-3 marines-12 (list med-1)))
  ;; (i) At `11.6t` (`x=74.2`): MUST emit closing `(move ...)` toward Tank (NOT backward splash retreat)!
  (define stalkers-far
    (for/list ([i (in-range 14)])
      (mk-u (+ 5101 i) 'stalker 74.2 (+ 85.0 (* 0.45 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define rt-b06 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-close
    (run-l34 rt-b06
             (mk-live-obs 'Protoss 'Terran 2652 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units stalkers-far #:enemy-units b06-enemies
                          #:researched-upgrades '(blink))))
  (define close-moves-fwd
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (> (third a) 82.0))) a-close))
  ;; (ii) At `9.2t` (`x=76.6`): ALL `14` Stalkers Blink directly into Tank `<= 2.0t` dead-zone!
  (define stalkers-range
    (for/list ([i (in-range 14)])
      (mk-u (+ 5101 i) 'stalker 76.6 (+ 85.0 (* 0.45 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define a-blink
    (run-l34 rt-b06
             (mk-live-obs 'Protoss 'Terran 2664 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units stalkers-range #:enemy-units b06-enemies
                          #:researched-upgrades '(blink))))
  (define blink-cmds
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'blink))) a-blink))
  (define all-inside-deadzone?
    (and (= (length blink-cmds) 14)
         (for/and ([b (in-list blink-cmds)])
           (<= (min (dist2d-t (fourth b) (fifth b) 85.8 88.0)
                    (dist2d-t (fourth b) (fifth b) 85.8 86.0)
                    (dist2d-t (fourth b) (fifth b) 85.8 90.0))
               2.05))))
  ;; (iii) On `+4f` after Tank #1 (`5801`) dies, Stalkers chain-focus living Tank #2/#3 (`5802`/`5803`)!
  (define stalkers-landed
    (for/list ([i (in-range 14)])
      (mk-u (+ 5101 i) 'stalker 84.3 (+ 86.5 (* 0.25 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define a-chain
    (run-l34 rt-b06
             (mk-live-obs 'Protoss 'Terran 2668 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units stalkers-landed #:enemy-units (cdr b06-enemies)
                          #:researched-upgrades '(blink))))
  (define chain-tank-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (third a) '(5802 5803)))) a-chain))
  (check-true "L49-T2a-stalker-blink-forward-b06-close-in-deadzone-and-chain-hv-focus"
              (and (= (length close-moves-fwd) 14)
                   all-inside-deadzone?
                   (>= (length chain-tank-atks) 12))
              (format "close=~a blinks=~a deadzone?=~a chain=~a"
                      (length close-moves-fwd) (length blink-cmds) all-inside-deadzone? (length chain-tank-atks))))

;; -----------------------------------------------------------------------------
;; 6. L49-T2b: Detection-Snipe (`d02` Unified Cannon Focus + DT Staging; `d17` Overseer Escort + Stealth Tick-0)
;; -----------------------------------------------------------------------------
(let ()
  ;; (i) `d02`: 4 non-Blink DTs + 6 Stalkers vs 2 Photon Cannons + 6 Zealots + 6 Stalkers
  (define dts-4 (for/list ([i (in-range 4)]) (mk-u (+ 6101 i) 'dark-templar 76.5 (+ 87.0 (* 0.6 i)) #:hp 40.0 #:shield 80.0 #:cloak 1)))
  (define st-6  (for/list ([i (in-range 6)]) (mk-u (+ 6201 i) 'stalker 75.0 (+ 86.0 (* 0.8 i)) #:hp 80.0 #:shield 80.0)))
  (define cannons-2
    (list (mk-u 6801 'photon-cannon 84.0 85.6 #:hp 150.0 #:shield 150.0)
          (mk-u 6802 'photon-cannon 84.0 90.4 #:hp 150.0 #:shield 150.0)))
  (define guards-12
    (append (for/list ([i (in-range 6)]) (mk-u (+ 6810 i) 'zealot 83.2 (+ 86.0 (* 0.8 i)) #:hp 100.0 #:shield 50.0))
            (for/list ([i (in-range 6)]) (mk-u (+ 6820 i) 'stalker 85.0 (+ 86.0 (* 0.8 i)) #:hp 80.0 #:shield 80.0))))
  (define a-d02
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Protoss 700 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units (append dts-4 st-6)
                          #:enemy-units guards-12 #:enemy-buildings cannons-2)))
  (define st-targets
    (remove-duplicates
     (for/list ([a (in-list a-d02)]
                #:when (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(6201 6202 6203 6204 6205 6206))))
       (third a))))
  (define dt-staged-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(6101 6102 6103 6104)) (< (third a) 74.0))) a-d02))
  (define dt-suicide-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(6101 6102 6103 6104)))) a-d02))
  ;; Once both Cannons die (`enemy-buildings '()`): all 4 DTs immediately engage!
  (define a-d02-blind
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Protoss 720 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units (append dts-4 st-6)
                          #:enemy-units guards-12 #:enemy-buildings '())))
  (define dt-blind-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(6101 6102 6103 6104)))) a-d02-blind))

  ;; (ii) `d17`: Unburrowed Tunneling-Claws Roaches + 4 Corruptors + 6 Hydralisks + 1 Overseer vs 2 Observers + army
  (define roaches-12 (for/list ([i (in-range 12)]) (mk-u (+ 6301 i) 'roach 76.4 (+ 85.0 (* 0.5 i)) #:hp 145.0)))
  (define hydras-6   (for/list ([i (in-range 6)])  (mk-u (+ 6331 i) 'hydralisk 75.0 (+ 86.0 (* 0.7 i)) #:hp 90.0)))
  (define corrs-4    (for/list ([i (in-range 4)])  (mk-u (+ 6351 i) 'corruptor 74.8 (+ 88.0 (* 0.6 i)) #:hp 200.0 #:flying #t)))
  (define ov-1       (mk-u 6399 'overseer 68.0 88.0 #:hp 200.0 #:energy 20.0 #:flying #t))
  (define obs-2      (list (mk-u 6901 'observer 85.0 89.0 #:hp 40.0 #:shield 20.0 #:flying #t #:cloak 2)
                           (mk-u 6902 'observer 85.0 91.5 #:hp 40.0 #:shield 20.0 #:flying #t #:cloak 2)))
  (define p-army     (append obs-2 (for/list ([i (in-range 8)]) (mk-u (+ 6910 i) 'stalker 85.2 (+ 85.0 (* 0.6 i)) #:hp 80.0 #:shield 80.0))))
  (define a-d17
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
             (mk-live-obs 'Zerg 'Protoss 900 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units (append roaches-12 hydras-6 corrs-4 (list ov-1))
                          #:enemy-units p-army
                          #:researched-upgrades '(burrow tunneling-claws glial-reconstitution))))
  (define ov-oversight? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'morph-oversight-mode))) a-d17))
  (define ov-escort? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 6399) (> (third a) 71.0))) a-d17))
  (define corr-obs-tgts
    (remove-duplicates
     (for/list ([a (in-list a-d17)]
                #:when (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(6351 6352 6353 6354))))
       (third a))))
  (check-true "L49-T2b-detection-snipe-dt-staging-unified-detector-focus-and-overseer-escort"
              (and (= (length st-targets) 1)
                   (memv (car st-targets) '(6801 6802))
                   (= (length dt-staged-moves) 4)
                   (null? dt-suicide-atks)
                   (>= (length dt-blind-atks) 4)
                   (not ov-oversight?)
                   ov-escort?
                   (= (length corr-obs-tgts) 1)
                   (memv (car corr-obs-tgts) '(6901 6902)))
              (format "st-tgts=~a dt-mv=~a dt-atk=~a dt-blind=~a ov-os?=~a ov-esc?=~a corr-tgts=~a"
                      st-targets (length dt-staged-moves) (length dt-suicide-atks) (length dt-blind-atks)
                      ov-oversight? ov-escort? corr-obs-tgts)))

;; -----------------------------------------------------------------------------
;; 7. L49-T2c: Oracle Runby (`ro09` Zero Stasis Spam at `en=100`, Fog Backside Push, SCV Shred)
;; -----------------------------------------------------------------------------
(let ()
  (define enemy-cc (mk-u 7800 'command-center 33.5 138.5 #:hp 1500.0))
  (define marines-4 (for/list ([i (in-range 4)]) (mk-u (+ 7810 i) 'marine 36.5 (+ 137.5 (* 0.5 i)) #:hp 45.0)))
  (define scvs-16   (for/list ([i (in-range 16)]) (mk-u (+ 7830 i) 'scv 30.3 (+ 135.5 (* 0.4 i)) #:hp 45.0)))
  ;; (i) High-energy (`100`) Oracles at `9.2t` approaching CC + 4 Marines (SCVs in Fog!):
  ;;     Tick 0: turns Pulsar Beam ON (`0` Stasis Ward spam!); Tick 1 (beam ON): pushes past Marines to CC backside!
  (define rt-ro09 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define oracles-far (list (mk-u 7101 'oracle 42.7 138.5 #:hp 100.0 #:shield 60.0 #:energy 100.0 #:flying #t)
                            (mk-u 7102 'oracle 42.7 139.5 #:hp 100.0 #:shield 60.0 #:energy 100.0 #:flying #t)))
  (define a-ro09-fog
    (run-l34 rt-ro09
             (mk-live-obs 'Protoss 'Terran 450 #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracles-far #:enemy-units marines-4 #:enemy-buildings (list enemy-cc))))
  (define fog-stasis? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'stasis-ward))) a-ro09-fog))
  (define oracles-far-on (list (mk-u 7101 'oracle 42.7 138.5 #:hp 100.0 #:shield 60.0 #:energy 75.0 #:flying #t #:buffs '(pulsar-beam))
                               (mk-u 7102 'oracle 42.7 139.5 #:hp 100.0 #:shield 60.0 #:energy 75.0 #:flying #t #:buffs '(pulsar-beam))))
  (define a-ro09-fog2
    (run-l34 rt-ro09
             (mk-live-obs 'Protoss 'Terran 454 #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracles-far-on #:enemy-units marines-4 #:enemy-buildings (list enemy-cc))))
  (define fog-push?   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(7101 7102)) (< (third a) 40.0))) a-ro09-fog2))
  ;; (ii) Beam-ON Oracles within `<= 6.5t` of SCVs -> IMMEDIATELY `attack-unit` SCVs (NOT move loop)!
  (define oracles-in
    (list (mk-u 7101 'oracle 34.5 141.5 #:hp 100.0 #:shield 50.0 #:energy 60.0 #:flying #t #:buffs '(pulsar-beam))
          (mk-u 7102 'oracle 34.5 142.5 #:hp 100.0 #:shield 50.0 #:energy 60.0 #:flying #t #:buffs '(pulsar-beam))))
  (define a-ro09-shred
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 480 #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracles-in #:enemy-units (append marines-4 scvs-16) #:enemy-buildings (list enemy-cc))))
  (define scv-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(7101 7102)) (>= (third a) 7830))) a-ro09-shred))
  (check-true "L49-T2c-ro09-oracle-zero-stasis-spam-and-pulsar-beam-scv-shred"
              (and (not fog-stasis?) fog-push? (= (length scv-atks) 2))
              (format "stasis?=~a push?=~a scv-atks=~a" fog-stasis? fog-push? scv-atks)))

;; -----------------------------------------------------------------------------
;; 8. L49-T2d: Cloaked Banshee vs Corner Spore (`ro11` Zero Cloak-2 Spam & Safe-Wing Avoidance)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch (mk-u 8800 'hatchery 33.5 138.5 #:hp 1500.0))
  (define spore (mk-u 8801 'spore-crawler 31.5 135.7 #:hp 400.0)) ;; South-corner Spore `(-2.0, -2.8)`!
  ;; Drones spanning south (`y=135`) and north safe wing (`y=142.5`, `6.8t` north of Spore!)
  (define drones-safe (for/list ([i (in-range 8)]) (mk-u (+ 8810 i) 'drone 30.3 (+ 141.5 (* 0.35 i)) #:hp 40.0)))
  (define drones-south (for/list ([i (in-range 8)]) (mk-u (+ 8820 i) 'drone 30.3 (+ 134.5 (* 0.3 i)) #:hp 40.0)))
  ;; (i) Already-cloaked Banshee (`cloak = 2` CloakedDetected) inside Spore range (`d=6.0t < 7.8t`):
  ;;     MUST emit `0` redundant `cloak-banshee` AND step radially OUT of Spore danger!
  (define ban-in (mk-u 8101 'banshee 31.5 141.7 #:hp 140.0 #:energy 60.0 #:cloak 2 #:flying #t #:buffs '(cloak-banshee)))
  (define a-out
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 300 #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units (list ban-in) #:enemy-units (append drones-safe drones-south)
                          #:enemy-buildings (list hatch spore) #:researched-upgrades '(banshee-cloak))))
  (define spam-cloak? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'cloak-banshee))) a-out))
  (define step-out-mv (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 8101))) a-out))
  (define stepped-safe? (and step-out-mv (>= (dist2d-t (third step-out-mv) (fourth step-out-mv) 31.5 135.7) 7.8)))
  ;; (ii) Cloaked Banshee outside Spore `7.8t` (`(31.5, 144.2)`, `8.5t` from Spore, `2.0t` from north Drones, 0 Queens):
  ;;      MUST IMMEDIATELY `attack-unit` a safe-wing north Drone!
  (define ban-safe (mk-u 8102 'banshee 31.5 144.2 #:hp 140.0 #:energy 60.0 #:cloak 2 #:flying #t #:buffs '(cloak-banshee)))
  (define a-shred
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 320 #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units (list ban-safe) #:enemy-units (append drones-safe drones-south)
                          #:enemy-buildings (list hatch spore) #:researched-upgrades '(banshee-cloak))))
  (define shred-north?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 8102)
                            (>= (third a) 8810) (< (third a) 8818)))
           a-shred))
  (check-true "L49-T2d-ro11-banshee-zero-cloak-spam-and-safe-wing-spore-avoidance"
              (and (not spam-cloak?) stepped-safe? shred-north?)
              (format "spam-clk?=~a step-out=~a shred-north?=~a" spam-cloak? step-out-mv shred-north?)))

;; -----------------------------------------------------------------------------
;; 9. L49-T2e: Protoss Kiting Worker-Rush (`r16` Pinned Miners at `h-cnt=6` + Zealot #1 `7.5t` Guard)
;; -----------------------------------------------------------------------------
(let ()
  (define nex (mk-u 9001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define pyl (mk-u 9002 'pylon 35.5 32.5 #:hp 200.0 #:shield 200.0))
  (define gw  (mk-u 9003 'gateway 35.5 35.5 #:hp 500.0 #:shield 500.0))
  (define mps (list (hasheq 'id 9901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  ;; `6` healthy Probes (`h-cnt = 6 < 8`!) + `5` wounded Probes sliding + `1` Zealot at `(30.5, 32.5)` vs 15 Probes at `4.0t` from Zealot (`<= 7.5t` of Nexus!)
  (define probes-6-ok (for/list ([i (in-range 6)]) (mk-u (+ 9101 i) 'probe 28.0 (+ 31.0 (* 0.5 i)) #:hp 20.0 #:shield 20.0)))
  (define probes-5-wd (for/list ([i (in-range 5)]) (mk-u (+ 9120 i) 'probe 33.5 (+ 31.5 (* 0.3 i)) #:hp 10.0 #:shield 0.0)))
  (define zealot-1    (mk-u 9199 'zealot 30.5 32.5 #:hp 100.0 #:shield 50.0))
  (define e-probes-15 (for/list ([i (in-range 15)]) (mk-u (+ 9801 i) 'probe 34.5 (+ 31.5 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define rt-r16 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-r16
    (mk-live-obs 'Protoss 'Protoss 1400 #:minerals 50 #:gas 0 #:supply-used 13 #:supply-cap 23
                 #:mineral-harvesters 11 #:vespene-harvesters 0
                 #:ally-units (cons zealot-1 (append probes-6-ok probes-5-wd))
                 #:ally-buildings (list nex pyl gw)
                 #:enemy-units e-probes-15 #:mineral-patches mps))
  (define a-l2 (step-layer2-economy! rt-r16 obs-r16))
  (define a-l34 (run-l34 rt-r16 obs-r16))
  (define pulled-ids
    (remove-duplicates (append* (for/list ([a (in-list a-l2)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (define healthy-kept-mining (- 6 (count (lambda (id) (and (>= id 9101) (<= id 9106))) pulled-ids)))
  (define zlt-l2-atk? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 9199))) a-l2))
  (define zlt-l34-atk? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 9199))) a-l34))
  (check-true "L49-T2e-r16-protoss-pinned-miners-at-6w-and-zealot1-7.5t-pocket-defense"
              (and (>= healthy-kept-mining 3)
                   zlt-l2-atk?
                   zlt-l34-atk?)
              (format "kept-mining=~a/6 zlt-l2?=~a zlt-l34?=~a" healthy-kept-mining zlt-l2-atk? zlt-l34-atk?)))

;; -----------------------------------------------------------------------------
;; 10. L49-W1b-1: Zerg Root Cause #1 — Baneling Slot Floor `>= 2` vs Heavy Bio/Zealots
;; -----------------------------------------------------------------------------
(let ()
  (define h1 (mk-u 10001 'lair 32.5 32.5 #:hp 2000.0))
  (define h2 (mk-u 10002 'hatchery 56.5 32.5 #:hp 1500.0))
  (define sp (mk-u 10003 'spawning-pool 36.5 36.5 #:hp 1000.0))
  (define bn (mk-u 10004 'baneling-nest 38.5 34.5 #:hp 850.0))
  (define drones (for/list ([i (in-range 36)]) (mk-u (+ 10101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define lings-3 (for/list ([i (in-range 3)]) (mk-u (+ 10201 i) 'zergling 48.0 (+ 32.0 (* 0.4 i)) #:hp 35.0)))
  (define marines-12 (for/list ([i (in-range 12)]) (mk-u (+ 10801 i) 'marine 70.0 (+ 32.0 (* 0.4 i)) #:hp 45.0)))
  (define a-bane
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 6200 #:minerals 200 #:gas 150 #:supply-used 46 #:supply-cap 72
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-units (append drones lings-3)
                  #:ally-buildings (list h1 h2 sp bn)
                  #:enemy-units marines-12)))
  (define morphed-bane?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'baneling))) a-bane))
  (check-true "L49-W1b-1-zerg-baneling-slot-floor-2-and-heavy-bio-morph"
              morphed-bane?
              (format "acts=~a" a-bane)))

;; -----------------------------------------------------------------------------
;; 11. L49-W1b-2: Zerg Root Cause #2 — Reactive Burrow Roach-Only + Regen + 112f CD + 2-Base Burrow Gate
;; -----------------------------------------------------------------------------
(let ()
  (define tr (make-burrow-dodge-tracker))
  ;; (a) Wounded Hydra, Ravager, Zergling, Drone, Queen, Lurker-MP taking damage -> ZERO burrow-down!
  (define non-roach-0
    (list (mk-u 11001 'hydralisk 60.0 60.0 #:hp 80.0 #:max-hp 90.0)
          (mk-u 11002 'ravager   61.0 60.0 #:hp 100.0 #:max-hp 120.0)
          (mk-u 11003 'zergling  62.0 60.0 #:hp 30.0 #:max-hp 35.0)
          (mk-u 11004 'drone     63.0 60.0 #:hp 35.0 #:max-hp 40.0)
          (mk-u 11005 'queen     64.0 60.0 #:hp 140.0 #:max-hp 175.0)
          (mk-u 11006 'lurker-mp 65.0 60.0 #:hp 160.0 #:max-hp 200.0)))
  (define non-roach-1
    (list (mk-u 11001 'hydralisk 60.0 60.0 #:hp 45.0 #:max-hp 90.0)
          (mk-u 11002 'ravager   61.0 60.0 #:hp 55.0 #:max-hp 120.0)
          (mk-u 11003 'zergling  62.0 60.0 #:hp 12.0 #:max-hp 35.0)
          (mk-u 11004 'drone     63.0 60.0 #:hp 15.0 #:max-hp 40.0)
          (mk-u 11005 'queen     64.0 60.0 #:hp 70.0 #:max-hp 175.0)
          (mk-u 11006 'lurker-mp 65.0 60.0 #:hp 90.0 #:max-hp 200.0)))
  (define stalkers (list (mk-u 11801 'stalker 66.0 60.0 #:hp 80.0 #:shield 80.0)))
  (execute-zerg-reactive-burrow-dodge-micro
   (mk-live-obs 'Zerg 'Protoss 7000 #:ally-units non-roach-0 #:enemy-units stalkers #:researched-upgrades '(burrow))
   #:tracker tr)
  (define a-non-roach
    (execute-zerg-reactive-burrow-dodge-micro
     (mk-live-obs 'Zerg 'Protoss 7008 #:ally-units non-roach-1 #:enemy-units stalkers #:researched-upgrades '(burrow))
     #:tracker tr))
  ;; (b) Wounded Roach (`35%` HP) burrows, stays burrowed at `dwell=32f` (`60%` HP), unburrows at `82%` HP,
  ;;     and respects `112f` re-burrow CD at `+40f`!
  (define tr-r (make-burrow-dodge-tracker))
  (execute-zerg-reactive-burrow-dodge-micro
   (mk-live-obs 'Zerg 'Protoss 7000
                #:ally-units (list (mk-u 11101 'roach 60.0 60.0 #:hp 90.0 #:max-hp 145.0))
                #:enemy-units stalkers #:researched-upgrades '(burrow))
   #:tracker tr-r)
  (define a-r-down
    (execute-zerg-reactive-burrow-dodge-micro
     (mk-live-obs 'Zerg 'Protoss 7008
                  #:ally-units (list (mk-u 11101 'roach 60.0 60.0 #:hp 50.0 #:max-hp 145.0))
                  #:enemy-units stalkers #:researched-upgrades '(burrow))
     #:tracker tr-r))
  (define a-r-stay
    (execute-zerg-reactive-burrow-dodge-micro
     (mk-live-obs 'Zerg 'Protoss 7040
                  #:ally-units (list (mk-u 11101 'roach-burrowed 60.0 60.0 #:hp 87.0 #:max-hp 145.0))
                  #:enemy-units stalkers #:researched-upgrades '(burrow))
     #:tracker tr-r))
  (define a-r-up
    (execute-zerg-reactive-burrow-dodge-micro
     (mk-live-obs 'Zerg 'Protoss 7090
                  #:ally-units (list (mk-u 11101 'roach-burrowed 60.0 60.0 #:hp 120.0 #:max-hp 145.0))
                  #:enemy-units stalkers #:researched-upgrades '(burrow))
     #:tracker tr-r))
  (define a-r-cd-block
    (execute-zerg-reactive-burrow-dodge-micro
     (mk-live-obs 'Zerg 'Protoss 7130
                  #:ally-units (list (mk-u 11101 'roach 60.0 60.0 #:hp 50.0 #:max-hp 145.0))
                  #:enemy-units stalkers #:researched-upgrades '(burrow))
     #:tracker tr-r))
  ;; (c) 2-base Zerg with 4 Roaches + HydraDen does NOT auto-research `burrow`!
  (define bldgs-2b
    (list (mk-u 11201 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 11202 'hatchery 56.5 32.5 #:hp 1500.0)
          (mk-u 11203 'spawning-pool 36.5 36.5 #:hp 1000.0)
          (mk-u 11204 'roach-warren 38.5 34.5 #:hp 850.0)
          (mk-u 11205 'hydralisk-den 38.5 38.5 #:hp 850.0)))
  (define roaches-4 (for/list ([i (in-range 4)]) (mk-u (+ 11301 i) 'roach 50.0 (+ 32.0 i) #:hp 145.0)))
  (define drones-36 (for/list ([i (in-range 36)]) (mk-u (+ 11320 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define a-2b
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Protoss 5800 #:minerals 300 #:gas 250 #:supply-used 48 #:supply-cap 72
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-units (append drones-36 roaches-4)
                  #:ally-buildings bldgs-2b #:enemy-units '())))
  (define res-burrow-2b?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'research) (eq? (second a) 'burrow))) a-2b))
  (check-true "L49-W1b-2-reactive-burrow-roach-only-no-hydra-ravager-stun-and-2base-burrow-gate"
              (and (null? a-non-roach)
                   (pair? (assq 'burrow-down a-r-down))
                   (null? a-r-stay)
                   (pair? (assq 'burrow-up a-r-up))
                   (null? a-r-cd-block)
                   (not res-burrow-2b?))
              (format "non-r=~a down=~a stay=~a up=~a cd=~a 2b-bur?=~a"
                      a-non-roach a-r-down a-r-stay a-r-up a-r-cd-block res-burrow-2b?)))

;; -----------------------------------------------------------------------------
;; 12. L49-W1b-3: Zerg Root Cause #3 — Corruptor Retreat Over Main + Non-Cap Cap<=4 + Flyer Carapace
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) 2 Corruptors at Main `(32.5, 32.5)` vs 10 Tempests at `(44.0, 32.5)` (`11.5t` = over Main!) ->
  ;;     MUST actively retreat WEST (`x < 30.0`), ZERO `attack-unit` suicide!
  (define rt-c (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define corrs-2
    (list (mk-u 12101 'corruptor 32.5 32.5 #:hp 200.0 #:flying #t)
          (mk-u 12102 'corruptor 33.0 33.0 #:hp 200.0 #:flying #t)))
  (define tempests-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 12801 i) 'tempest 44.0 (+ 30.0 (* 0.5 i)) #:hp 200.0 #:shield 125.0 #:flying #t)))
  (define z-bldgs
    (list (mk-u 12001 'hive 32.5 32.5 #:hp 2500.0)
          (mk-u 12002 'hatchery 56.5 32.5 #:hp 1500.0)
          (mk-u 12003 'spire 36.5 36.5 #:hp 850.0)
          (mk-u 12004 'spawning-pool 35.5 34.5 #:hp 1000.0)
          (mk-u 12005 'infestation-pit 34.5 36.5 #:hp 850.0)))
  (define a-ret
    (run-l34 rt-c
             (mk-live-obs 'Zerg 'Protoss 10200 #:supply-used 72 #:supply-cap 110
                          #:ally-units corrs-2 #:ally-buildings z-bldgs #:enemy-units tempests-10)))
  (define corr-retreated?
    (for/and ([cid '(12101 12102)])
      (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) cid) (< (third a) 30.0))) a-ret)))
  (define corr-suicided?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(12101 12102)))) a-ret))
  ;; (b) 4 Corruptors + Spire vs 4 Vikings + 2 Medivacs (`0` Capital Air!) -> does NOT train 5th Corruptor!
  (define corrs-4 (for/list ([i (in-range 4)]) (mk-u (+ 12201 i) 'corruptor 34.0 (+ 32.0 i) #:hp 200.0 #:flying #t)))
  (define drones-54 (for/list ([i (in-range 54)]) (mk-u (+ 12301 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define larvae-6 (for/list ([i (in-range 6)]) (mk-u (+ 12401 i) 'larva 34.0 (+ 32.0 (* 0.2 i)) #:hp 25.0)))
  (define vikings-meds
    (append (for/list ([i (in-range 4)]) (mk-u (+ 12851 i) 'viking-fighter 75.0 (+ 32.0 i) #:hp 135.0 #:flying #t))
            (for/list ([i (in-range 2)]) (mk-u (+ 12861 i) 'medivac 77.0 (+ 32.0 i) #:hp 150.0 #:flying #t))))
  (define a-noncap
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 9600 #:minerals 400 #:gas 300 #:supply-used 90 #:supply-cap 130
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:ally-units (append drones-54 corrs-4 larvae-6)
                  #:ally-buildings (list (mk-u 12011 'lair 32.5 32.5 #:hp 2000.0)
                                         (mk-u 12012 'hatchery 56.5 32.5 #:hp 1500.0)
                                         (mk-u 12013 'hatchery 32.5 64.5 #:hp 1500.0)
                                         (mk-u 12014 'spawning-pool 36.5 36.5 #:hp 1000.0)
                                         (mk-u 12015 'hydralisk-den 38.5 34.5 #:hp 850.0)
                                         (mk-u 12016 'spire 38.5 38.5 #:hp 850.0))
                  #:enemy-units vikings-meds)))
  (define trained-5th-corr?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'corruptor))) a-noncap))
  ;; (c) Spire vs 10 Tempests -> researches `'zerg-flyer-armor-1`!
  (define a-cara
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Protoss 10200 #:minerals 600 #:gas 400 #:supply-used 90 #:supply-cap 130
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:ally-units (append drones-54 corrs-4 larvae-6)
                  #:ally-buildings z-bldgs #:enemy-units tempests-10)))
  (define res-flyer-armor?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'research) (eq? (second a) 'zerg-flyer-armor-1))) a-cara))
  (check-true "L49-W1b-3-corruptor-volley-over-main-retreat-noncap-cap4-and-flyer-carapace"
              (and corr-retreated? (not corr-suicided?) (not trained-5th-corr?) res-flyer-armor?)
              (format "ret?=~a suic?=~a 5th-corr?=~a cara?=~a" corr-retreated? corr-suicided? trained-5th-corr? res-flyer-armor?)))

;; -----------------------------------------------------------------------------
;; 13. L49-W1b-4: Zerg Root Cause #4 — Yield Larvae to Combat at `>= 38w`, `>= 5:00`, `< 24` Army
;; -----------------------------------------------------------------------------
(let ()
  (define drones-40 (for/list ([i (in-range 40)]) (mk-u (+ 13101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define roaches-6 (for/list ([i (in-range 6)]) (mk-u (+ 13201 i) 'roach 52.0 (+ 32.0 (* 0.4 i)) #:hp 145.0)))
  (define larvae-6  (for/list ([i (in-range 6)]) (mk-u (+ 13301 i) 'larva 34.0 (+ 32.0 (* 0.2 i)) #:hp 25.0)))
  (define bldgs-3b
    (list (mk-u 13001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 13002 'hatchery 56.5 32.5 #:hp 1500.0)
          (mk-u 13003 'hatchery 32.5 64.5 #:hp 1500.0)
          (mk-u 13004 'spawning-pool 36.5 36.5 #:hp 1000.0)
          (mk-u 13005 'roach-warren 38.5 34.5 #:hp 850.0)))
  (define a-yield
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Protoss 7000 #:minerals 450 #:gas 200 #:supply-used 52 #:supply-cap 82
                  #:mineral-harvesters 34 #:vespene-harvesters 6
                  #:ally-units (append drones-40 roaches-6 larvae-6)
                  #:ally-buildings bldgs-3b #:enemy-units '())))
  (define trained-drone?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'drone))) a-yield))
  (define trained-combat?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (memq (second a) '(roach hydralisk zergling)))) a-yield))
  (check-true "L49-W1b-4-zerg-yield-larva-to-combat-at-38w-5min-low-army"
              (and (not trained-drone?) trained-combat?)
              (format "drone?=~a combat?=~a acts=~a" trained-drone? trained-combat? a-yield)))

;; -----------------------------------------------------------------------------
;; 14. L49-W2-1: `ro09` Oracle 7.0t Flank, TownHall 22t Beam Hold & No AA/Low-Sh Stasis Ward
;; -----------------------------------------------------------------------------
(let ()
  (define cc (mk-u 14801 'command-center 142.0 34.0 #:hp 1500.0))
  (define marines-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 14810 i) 'marine 136.0 (+ 38.0 (* 0.4 i)) #:hp 45.0)))
  (define scvs-far
    (for/list ([i (in-range 16)])
      (mk-u (+ 14820 i) 'scv 147.0 (+ 30.0 (* 0.3 i)) #:hp 45.0)))
  ;; (a) Beam-ON Oracle 18t from CC (> 14t from SCVs) at sh=18 keeps Pulsar Beam ON!
  (define o-hold
    (list (mk-u 14101 'oracle 128.0 45.0 #:hp 100.0 #:max-hp 100.0 #:shield 18.0 #:max-shield 60.0
                #:energy 55.0 #:flying #t #:buffs '(oracle-weapon))))
  (define a-hold
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 500 #:base-x 32.5 #:base-y 138.5 #:enemy-x 142.0 #:enemy-y 34.0
                          #:ally-units o-hold #:enemy-units (append marines-4 scvs-far) #:enemy-buildings (list cc))))
  (define turned-off?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'pulsar-beam-off))) a-hold))
  ;; (b) Beam-OFF low-shield Oracle (sh=18, en=80) under Marine AA emits ZERO Stasis Ward!
  (define o-low
    (list (mk-u 14102 'oracle 130.0 42.0 #:hp 100.0 #:max-hp 100.0 #:shield 18.0 #:max-shield 60.0
                #:energy 80.0 #:flying #t)))
  (define a-low
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 520 #:base-x 32.5 #:base-y 138.5 #:enemy-x 142.0 #:enemy-y 34.0
                          #:ally-units o-low #:enemy-units marines-4 #:enemy-buildings (list cc))))
  (define cast-desert-stasis?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'stasis-ward))) a-low))
  ;; (c) Fog CC behind 4 Marines: Oracle flanks >= 6.0t laterally outside Marine 5.0t range!
  (define o-flk
    (list (mk-u 14103 'oracle 130.0 44.0 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0
                #:energy 90.0 #:flying #t #:buffs '(oracle-weapon))))
  (define a-flk
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 540 #:base-x 32.5 #:base-y 138.5 #:enemy-x 142.0 #:enemy-y 34.0
                          #:ally-units o-flk #:enemy-units marines-4 #:enemy-buildings (list cc))))
  (define flk-mv (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 14103))) a-flk))
  (define flk-clear-marines?
    (and flk-mv (>= (dist2d-t (third flk-mv) (fourth flk-mv) 136.0 38.6) 6.0)))
  (check-true "L49-W2-1-ro09-oracle-7t-flank-townhall-beam-hold-and-no-aa-desert-stasis"
              (and (not turned-off?) (not cast-desert-stasis?) flk-clear-marines?)
              (format "off?=~a stasis?=~a flk-mv=~a" turned-off? cast-desert-stasis? flk-mv)))

;; -----------------------------------------------------------------------------
;; 15. L49-W2-2: `b06`/`b07` Pre-Splash 10.6t Blink (After 1 Tank Shot) + 112f Colossus #2 Chain
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) 10 Stalkers (4 hit by 1 Tank shell: sh=10, hp=80 => total=90 >= 85!) at 10.3t vs 3 Tanks + 12 Marines
  (define tanks-3
    (list (mk-u 15801 'siege-tank-sieged 86.0 88.0 #:hp 175.0)
          (mk-u 15802 'siege-tank-sieged 86.0 86.0 #:hp 175.0)
          (mk-u 15803 'siege-tank-sieged 86.0 90.0 #:hp 175.0)))
  (define marines-12
    (for/list ([i (in-range 12)]) (mk-u (+ 15810 i) 'marine 83.5 (+ 85.0 (* 0.5 i)) #:hp 55.0)))
  (define stalkers-10-hit
    (for/list ([i (in-range 10)])
      (mk-u (+ 15101 i) 'stalker 75.7 (+ 86.0 (* 0.45 i))
            #:hp 80.0 #:max-hp 80.0 #:shield (if (< i 4) 10.0 80.0) #:max-shield 80.0)))
  (define dirs-b06
    (plan-stalker-blink-micro stalkers-10-hit (append tanks-3 marines-12) (make-spell-claims) 900
                              #:researched-upgrades '(blink)))
  (define fwd-blinks
    (count (lambda (d) (eq? (spell-directive-pattern-name d) 'stalker-blink-forward-snipe)) dirs-b06))
  (define back-blinks
    (count (lambda (d) (eq? (spell-directive-pattern-name d) 'stalker-blink-back)) dirs-b06))
  ;; (b) `b07`: Blink under Colossus #1 at f=1000, then at f=1070 (+70f > old 40f!) Colossus #1 is dead,
  ;;     Colossus #2 (15902) is alive at 5t alongside 8 Zealots at 2.5t -> Stalkers chain-focus Colossus #2!
  (define rt-b07 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define col1 (mk-u 15901 'colossus 85.0 88.0 #:hp 200.0 #:shield 150.0))
  (define col2 (mk-u 15902 'colossus 86.0 85.0 #:hp 200.0 #:shield 150.0))
  (define zealots-8 (for/list ([i (in-range 8)]) (mk-u (+ 15910 i) 'zealot 81.5 (+ 85.5 (* 0.5 i)) #:hp 100.0 #:shield 50.0)))
  (define st-b07-0
    (for/list ([i (in-range 10)])
      (mk-u (+ 15201 i) 'stalker 76.0 (+ 86.0 (* 0.45 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (run-l34 rt-b07
           (mk-live-obs 'Protoss 'Protoss 1000 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                        #:ally-units st-b07-0 #:enemy-units (cons col1 (cons col2 zealots-8))
                        #:researched-upgrades '(blink)))
  (define st-b07-70
    (for/list ([i (in-range 10)])
      ;; Low shields (sh=15, hp=65 => ehp=80 > 45): MUST stay locked on Colossus #2, NOT kite Zealots!
      (mk-u (+ 15201 i) 'stalker 83.5 (+ 86.0 (* 0.35 i)) #:hp 65.0 #:max-hp 80.0 #:shield 15.0 #:max-shield 80.0)))
  (define a-b07-70
    (run-l34 rt-b07
             (mk-live-obs 'Protoss 'Protoss 1070 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units st-b07-70 #:enemy-units (cons col2 zealots-8)
                          #:researched-upgrades '(blink))))
  (define col2-atks
    (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (third a) 15902))) a-b07-70))
  (define any-kite?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite))) a-b07-70))
  (check-true "L49-W2-2-b06-b07-stalker-10.6t-pre-splash-blink-1tank-shot-and-112f-colossus2-chain"
              (and (= fwd-blinks 10) (= back-blinks 0) (= col2-atks 10) (not any-kite?))
              (format "fwd=~a back=~a col2-atks=~a kite?=~a" fwd-blinks back-blinks col2-atks any-kite?)))

;; -----------------------------------------------------------------------------
;; 16. L49-W2-3: `d02` Healthy DT No-Archon-Merge + Sole Powering Pylon Detector Disable
;; -----------------------------------------------------------------------------
(let ()
  (define dts-4 (for/list ([i (in-range 4)]) (mk-u (+ 16101 i) 'dark-templar 65.0 (+ 80.0 i) #:hp 40.0 #:max-hp 40.0 #:shield 80.0 #:max-shield 80.0)))
  (define stk-6 (for/list ([i (in-range 6)]) (mk-u (+ 16121 i) 'stalker 74.0 (+ 79.0 (* 0.6 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define sole-pylon (mk-u 16801 'pylon 81.0 80.5 #:hp 200.0 #:shield 200.0))
  (define can-1 (mk-u 16802 'photon-cannon 80.0 78.5 #:hp 150.0 #:shield 150.0))
  (define can-2 (mk-u 16803 'photon-cannon 80.0 82.5 #:hp 150.0 #:shield 150.0))
  (define e-zlts (for/list ([i (in-range 6)]) (mk-u (+ 16810 i) 'zealot 78.5 (+ 79.0 (* 0.6 i)) #:hp 100.0 #:shield 50.0)))
  (define obs-d02
    (mk-live-obs 'Protoss 'Protoss 2600 #:base-x 20.0 #:base-y 20.0 #:enemy-x 140.0 #:enemy-y 140.0
                 #:ally-units (append dts-4 stk-6)
                 #:enemy-units e-zlts
                 #:enemy-buildings (list sole-pylon can-1 can-2)))
  ;; (a) Layer 2 MUST NOT merge healthy DTs into an Archon during active skirmish with <= 3 detectors + Stalkers!
  (define a-d02-l2 (step-layer2-economy! (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss) obs-d02))
  (define merged-archon?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'archon))) a-d02-l2))
  ;; (b) All 6 Stalkers MUST focus-fire the sole powering Pylon (`16801`)!
  (define a-d02-l34 (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss) obs-d02))
  (define stk-pylon-atks
    (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                            (>= (second a) 16121) (<= (second a) 16126)
                            (= (third a) 16801)))
           a-d02-l34))
  (check-true "L49-W2-3-d02-healthy-dt-no-archon-merge-and-sole-powering-pylon-focus"
              (and (not merged-archon?) (= stk-pylon-atks 6))
              (format "merged?=~a stk-pylon-atks=~a/6" merged-archon? stk-pylon-atks)))

;; -----------------------------------------------------------------------------
;; 17. L49-W2-4: `r16` Active <= 8.5t Worker-Defense Leash Recall + `r15` Terran Pin Floor 8
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Protoss Gateway training Zealot #1 (`order-ability-id=916`): Probe `17199` drifted to `10.5t`
  ;;     from Nexus MUST be recalled via `mineral-walk`, and Probes must NOT target kiting Probe at `10.0t`!
  (define nex (mk-u 17001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define pyl (mk-u 17002 'pylon 35.5 32.5 #:hp 200.0 #:shield 200.0))
  (define gw  (mk-u 17003 'gateway 35.5 35.5 #:hp 500.0 #:shield 500.0 #:order-ability-id 916))
  (define mps (list (hasheq 'id 17901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define home-probes (for/list ([i (in-range 11)]) (mk-u (+ 17101 i) 'probe 30.0 (+ 30.0 (* 0.4 i)) #:hp 20.0 #:shield 20.0)))
  (define drifted-probe (mk-u 17199 'probe 43.0 32.5 #:hp 20.0 #:shield 20.0)) ; 10.5t from Nexus!
  (define e-probes-mix
    (append (for/list ([i (in-range 8)]) (mk-u (+ 17801 i) 'probe 37.5 (+ 31.0 (* 0.3 i)) #:hp 20.0 #:shield 20.0))
            (for/list ([i (in-range 7)]) (mk-u (+ 17820 i) 'probe 42.5 (+ 31.0 (* 0.3 i)) #:hp 20.0 #:shield 20.0))))
  (define a-leash
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 1200 #:minerals 60 #:gas 0 #:supply-used 14 #:supply-cap 23
                  #:mineral-harvesters 12 #:vespene-harvesters 0
                  #:ally-units (cons drifted-probe home-probes)
                  #:ally-buildings (list nex pyl gw)
                  #:enemy-units e-probes-mix #:mineral-patches mps)))
  (define recalled-17199?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk move)) (= (second a) 17199))) a-leash))
  (define chased-past-8.5?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack)
                            (>= (length a) 5) (number? (fifth a))
                            (>= (fifth a) 17820) (<= (fifth a) 17826)))
           a-leash))
  ;; (b) Terran with 2 Marines (`combat-supply=2.0`) and 6 healthy SCVs (`< 8`) vs 12 breaching Probes:
  ;;     Terran keeps its `>= 8` pin floor so all 5..6 SCVs screen instead of over-pinning 3 miners!
  (define cc  (mk-u 17501 'command-center 32.5 32.5 #:hp 1500.0))
  (define rax (mk-u 17502 'barracks 36.5 35.5 #:hp 1000.0 #:order-ability-id 560))
  (define scvs-6 (for/list ([i (in-range 6)]) (mk-u (+ 17601 i) 'scv 31.0 (+ 31.0 (* 0.4 i)) #:hp 45.0)))
  (define mar-2  (for/list ([i (in-range 2)]) (mk-u (+ 17651 i) 'marine 33.0 (+ 31.5 i) #:hp 45.0)))
  (define e-probes-breach
    (for/list ([i (in-range 12)]) (mk-u (+ 17850 i) 'probe 34.5 (+ 30.5 (* 0.3 i)) #:hp 20.0 #:shield 20.0)))
  (define a-r15
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 1500 #:minerals 40 #:gas 0 #:supply-used 8 #:supply-cap 15
                  #:mineral-harvesters 6 #:vespene-harvesters 0
                  #:ally-units (append scvs-6 mar-2)
                  #:ally-buildings (list cc rax)
                  #:enemy-units e-probes-breach #:mineral-patches mps)))
  (define r15-pulled-cnt
    (length (remove-duplicates (append* (for/list ([a (in-list a-r15)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a))))))
  (check-true "L49-W2-4-r16-worker-defense-8.5t-leash-recall-and-r15-terran-pin-floor-8"
              (and recalled-17199? (not chased-past-8.5?) (>= r15-pulled-cnt 5))
              (format "recalled?=~a past8.5?=~a r15-pulled=~a/6" recalled-17199? chased-past-8.5? r15-pulled-cnt)))

;; -----------------------------------------------------------------------------
;; 18. L49-W2-5: `#02 TvT` Starport Viking/Medivac/Liberator Yields 125G for Siege Tank #1..#3
;; -----------------------------------------------------------------------------
(let ()
  (define cc1 (mk-u 18001 'orbital-command 32.5 32.5 #:hp 1500.0))
  (define cc2 (mk-u 18002 'command-center 56.5 32.5 #:hp 1500.0))
  (define rax (mk-u 18003 'barracks 38.0 34.0 #:hp 1000.0))
  (define fac (mk-u 18004 'factory 38.0 38.0 #:hp 1250.0 #:add-on-tag 18005))
  (define ftl (mk-u 18005 'factory-techlab 40.5 37.5 #:hp 400.0))
  (define sp  (mk-u 18006 'starport 42.0 40.0 #:hp 1300.0 #:add-on-tag 18007))
  (define spr (mk-u 18007 'starport-reactor 44.5 39.5 #:hp 400.0))
  (define scvs-34 (for/list ([i (in-range 34)]) (mk-u (+ 18101 i) 'scv 28.0 (+ 30.0 (* 0.2 i)) #:hp 45.0)))
  (define mars-14 (for/list ([i (in-range 14)]) (mk-u (+ 18201 i) 'marine 52.0 (+ 32.0 (* 0.3 i)) #:hp 45.0)))
  ;; Enemy has 2 Vikings + 1 Medivac + 2 Tanks (requires anti-air, NOT Capital Air!), gas=150:
  ;; MUST train Siege Tank (`125G`) and NOT let Vikings/Medivacs drain gas below `125G`!
  (define e-tvt
    (list (mk-u 18801 'viking-fighter 95.0 95.0 #:hp 135.0 #:flying #t)
          (mk-u 18802 'viking-fighter 96.0 95.0 #:hp 135.0 #:flying #t)
          (mk-u 18803 'medivac 97.0 95.0 #:hp 150.0 #:flying #t)
          (mk-u 18804 'siege-tank-sieged 95.0 92.0 #:hp 175.0)
          (mk-u 18805 'siege-tank-sieged 97.0 92.0 #:hp 175.0)))
  (define a-tvt
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Terran 6200 #:minerals 350 #:gas 150 #:supply-used 52 #:supply-cap 78
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-units (append scvs-34 mars-14)
                  #:ally-buildings (list cc1 cc2 rax fac ftl sp spr)
                  #:enemy-units e-tvt
                  #:enemy-buildings (list (mk-u 18890 'command-center 140.0 140.0 #:hp 1500.0)))))
  (define trained-tank?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'siege-tank))) a-tvt))
  (define trained-viking?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'viking))) a-tvt))
  (check-true "L49-W2-5-tvt-starport-viking-yields-125g-for-siege-tank"
              (and trained-tank? (not trained-viking?))
              (format "tank?=~a viking?=~a acts=~a" trained-tank? trained-viking? a-tvt)))

;; -----------------------------------------------------------------------------
;; 19. L49-W2-6: Ship #8 Hotfix (`#1190`/`#1191`) — `wd-zero-inc-active?` Partial/Zero Filtered `take` Safety
;; -----------------------------------------------------------------------------
(let ()
  (define cc (mk-u 19001 'command-center 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 0 #:ideal-harvesters 16))
  (define mps (list (hasheq 'id 19901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  ;; (a) 14 workers in `harvest-workers-pool` (10 carrying cargo + 4 non-carrying stalled) + 2 building SCVs:
  ;;     `wd-rec-cands` has length 4 < (min 12 14) -> MUST NOT throw `take` contract violation and MUST recover the 4!
  (define scvs-partial
    (append (for/list ([i (in-range 8)])
              (mk-u (+ 19101 i) 'scv 29.0 (+ 30.0 (* 0.3 i)) #:hp 45.0 #:buffs '(271)
                    #:orders (list (hasheq 'ability-id 296)) #:order-ability-id 296))
            (for/list ([i (in-range 2)])
              (mk-u (+ 19110 i) 'scv 29.5 (+ 30.0 (* 0.3 i)) #:hp 45.0 #:buffs '(273)
                    #:orders (list (hasheq 'ability-id 296)) #:order-ability-id 296))
            (for/list ([i (in-range 2)])
              (mk-u (+ 19120 i) 'scv 36.0 (+ 34.0 (* 0.5 i)) #:hp 45.0
                    #:orders (list (hasheq 'ability-id 318)) #:order-ability-id 318))
            (for/list ([i (in-range 4)])
              (mk-u (+ 19130 i) 'scv 30.5 (+ 30.0 (* 0.3 i)) #:hp 45.0
                    #:orders (list (hasheq 'ability-id 16)) #:order-ability-id 16))))
  (define rt-part (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (void (step-layer2-economy!
         rt-part
         (mk-live-obs 'Terran 'Protoss 5000 #:minerals 80 #:gas 0 #:supply-used 16 #:supply-cap 23
                      #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                      #:ally-units scvs-partial #:ally-buildings (list cc) #:mineral-patches mps)))
  (define a-part-60
    (step-layer2-economy!
     rt-part
     (mk-live-obs 'Terran 'Protoss 5060 #:minerals 80 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                  #:ally-units scvs-partial #:ally-buildings (list cc) #:mineral-patches mps)))
  (define ret-part (findf (lambda (a) (and (pair? a) (eq? (car a) 'return-workers-to-gather))) a-part-60))
  (define harv-part
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (= (third a) 19901))) a-part-60))
  ;; (b) 10 workers ALL carrying cargo (`wd-rec-cands` length = 0 < 10): MUST NOT crash and MUST emit 0 recovery!
  (define scvs-all-carrying
    (for/list ([i (in-range 10)])
      (mk-u (+ 19201 i) 'scv 29.0 (+ 30.0 (* 0.3 i)) #:hp 45.0 #:buffs '(271)
            #:orders (list (hasheq 'ability-id 296)) #:order-ability-id 296)))
  (define rt-zero (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (void (step-layer2-economy!
         rt-zero
         (mk-live-obs 'Terran 'Protoss 5000 #:minerals 80 #:gas 0 #:supply-used 10 #:supply-cap 15
                      #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                      #:ally-units scvs-all-carrying #:ally-buildings (list cc) #:mineral-patches mps)))
  (define a-zero-60
    (step-layer2-economy!
     rt-zero
     (mk-live-obs 'Terran 'Protoss 5060 #:minerals 80 #:gas 0 #:supply-used 10 #:supply-cap 15
                  #:mineral-harvesters 0 #:vespene-harvesters 0 #:min-rate 0
                  #:ally-units scvs-all-carrying #:ally-buildings (list cc) #:mineral-patches mps)))
  (define ret-zero? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'return-workers-to-gather))) a-zero-60))
  (check-true "L49-W2-6-wd-zero-income-partial-and-zero-filtered-take-safety"
              (and ret-part
                   (equal? (sort (second ret-part) <) '(19130 19131 19132 19133))
                   (= (length harv-part) 4)
                   (not ret-zero?))
              (format "ret-part=~a harv-cnt=~a ret-zero?=~a" ret-part (length harv-part) ret-zero?)))

;; -----------------------------------------------------------------------------
;; 20. L50-W1-2a: Starport Tank Gas-Yield Open-Factory Gate + Non-TvT First 2 Medivacs
;; -----------------------------------------------------------------------------
(let ()
  (define cc1 (mk-u 20001 'orbital-command 32.5 32.5 #:hp 1500.0))
  (define cc2 (mk-u 20002 'command-center 56.5 32.5 #:hp 1500.0))
  (define rax (mk-u 20003 'barracks 38.0 34.0 #:hp 1000.0))
  ;; Busy FactoryTechLab (`orders` non-empty -> `open-prod-slots 'factory = 0`):
  (define fac-busy (mk-u 20004 'factory 38.0 38.0 #:hp 1250.0 #:add-on-tag 20005
                         #:orders (list (hasheq 'ability-id 591)) #:order-ability-id 591))
  (define fac-open (mk-u 20004 'factory 38.0 38.0 #:hp 1250.0 #:add-on-tag 20005))
  (define ftl (mk-u 20005 'factory-techlab 40.5 37.5 #:hp 400.0))
  (define sp  (mk-u 20006 'starport 42.0 40.0 #:hp 1300.0 #:add-on-tag 20007))
  (define spr (mk-u 20007 'starport-reactor 44.5 39.5 #:hp 400.0))
  (define scvs-34 (for/list ([i (in-range 34)]) (mk-u (+ 20101 i) 'scv 28.0 (+ 30.0 (* 0.2 i)) #:hp 45.0)))
  (define mars-14 (for/list ([i (in-range 14)]) (mk-u (+ 20201 i) 'marine 52.0 (+ 32.0 (* 0.3 i)) #:hp 45.0)))
  ;; (a) Busy Factory in TvT with 150G: MUST train Medivac/Viking instead of holding 125G idle!
  (define e-tvt
    (list (mk-u 20801 'siege-tank-sieged 95.0 92.0 #:hp 175.0)
          (mk-u 20802 'marine 94.0 93.0 #:hp 45.0)))
  (define a-busy
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Terran 6200 #:minerals 350 #:gas 150 #:supply-used 52 #:supply-cap 78
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-units (append scvs-34 mars-14)
                  #:ally-buildings (list cc1 cc2 rax fac-busy ftl sp spr)
                  #:enemy-units e-tvt
                  #:enemy-buildings (list (mk-u 20890 'command-center 140.0 140.0 #:hp 1500.0)))))
  (define busy-med? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'medivac))) a-busy))
  ;; (b) Open Factory in TvP (`not tvt-need-tanks-p3?`) with 14 Marines, 0 Medivacs, 250M/130G:
  ;;     First 2 Medivacs are exempted from Starport Tank gas-yield -> MUST train Medivac!
  (define e-tvp
    (for/list ([i (in-range 6)]) (mk-u (+ 20850 i) 'stalker 105.0 (+ 95.0 i) #:hp 80.0 #:shield 80.0)))
  (define a-tvp
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 6400 #:minerals 130 #:gas 130 #:supply-used 52 #:supply-cap 78
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-units (append scvs-34 mars-14)
                  #:ally-buildings (list cc1 cc2 rax fac-open ftl sp spr)
                  #:enemy-units e-tvp
                  #:enemy-buildings (list (mk-u 20891 'nexus 140.0 140.0 #:hp 1000.0 #:shield 1000.0)))))
  (define tvp-med? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'medivac))) a-tvp))
  (check-true "L50-W1-2a-starport-open-factory-gate-and-tvp-first-2-medivacs"
              (and busy-med? tvp-med?)
              (format "busy-med?=~a tvp-med?=~a" busy-med? tvp-med?)))

;; -----------------------------------------------------------------------------
;; 21. L50-W1-2b: Worker-Rush Ramp Building Defense (`#08 Chance`) + Proxy Cannon Pull (`#59`)
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) `#08 TvP vs Chance`: Terran ramp SupplyDepot (`11.2t`) + Barracks (`9.8t`, training Marine #1)
  ;;     under Probe rush (`10.5t..11.2t` from CC): MUST engage Probes & emit ZERO mineral-walk away!
  (define cc  (mk-u 21001 'command-center 32.5 32.5 #:hp 1500.0))
  (define dep (mk-u 21002 'supply-depot 43.7 32.5 #:hp 350.0 #:max-hp 400.0)) ;; 11.2t from CC!
  (define rax (mk-u 21003 'barracks 42.3 32.5 #:hp 920.0 #:max-hp 1000.0 #:order-ability-id 560)) ;; 9.8t!
  (define mps (list (hasheq 'id 21901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define scvs-15 (for/list ([i (in-range 15)]) (mk-u (+ 21101 i) 'scv (+ 34.0 (* 0.3 i)) (+ 31.0 (* 0.2 i)) #:hp 45.0)))
  (define e-probes-ramp
    (for/list ([i (in-range 12)])
      (mk-u (+ 21801 i) 'probe (+ 42.5 (* 0.15 i)) (+ 31.2 (* 0.22 i)) #:hp 20.0 #:shield 20.0)))
  (define a-chance
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 1400 #:minerals 80 #:gas 0 #:supply-used 15 #:supply-cap 23
                  #:mineral-harvesters 15 #:vespene-harvesters 0
                  #:ally-units scvs-15 #:ally-buildings (list cc dep rax)
                  #:enemy-units e-probes-ramp #:mineral-patches mps)))
  (define chance-pulled
    (remove-duplicates (append* (for/list ([a (in-list a-chance)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (define chance-leash-mw?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (memv (second a) (map (lambda (w) (hash-ref w 'id)) scvs-15)))) a-chance))
  ;; (b) `#59 Creepy` Proxy Cannon Rush inside Main (`<= 22t`):
  ;;     17 SCVs vs 1 Pylon + 1 warping Photon Cannon -> pulls >= 6 SCVs onto warping Cannon FIRST!
  (define scvs-17 (for/list ([i (in-range 17)]) (mk-u (+ 21201 i) 'scv 29.0 (+ 29.0 (* 0.4 i)) #:hp 45.0)))
  (define proxy-pyl (mk-u 21850 'pylon 39.5 31.5 #:hp 200.0 #:shield 200.0 #:build-progress 1.0))
  (define proxy-can (mk-u 21851 'photon-cannon 38.5 33.0 #:hp 70.0 #:shield 70.0 #:build-progress 0.35))
  (define a-59
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 2600 #:minerals 120 #:gas 0 #:supply-used 17 #:supply-cap 23
                  #:mineral-harvesters 17 #:vespene-harvesters 0
                  #:ally-units scvs-17 #:ally-buildings (list cc dep rax)
                  #:enemy-units (list (mk-u 21860 'probe 40.0 32.0 #:hp 20.0 #:shield 20.0))
                  #:enemy-buildings (list proxy-pyl proxy-can) #:mineral-patches mps)))
  (define can-pull (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 21851))) a-59))
  (define pyl-pull (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 21850))) a-59))
  ;; (c) When a completed Cannon exists at `(38.5, 33.0)`, a distant safe Pylon at `(48.0, 33.0)` (`9.5t > 7.8t` away,
  ;;     `15.5t <= 22t` from Main) STILL pulls SCVs while the adjacent Pylon (`1.8t`) does NOT!
  (define done-can (mk-u 21852 'photon-cannon 38.5 33.0 #:hp 150.0 #:shield 150.0 #:build-progress 1.0))
  (define safe-pyl (mk-u 21853 'pylon 48.0 33.0 #:hp 120.0 #:shield 120.0 #:build-progress 0.4))
  (define a-59-safe
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 2700 #:minerals 120 #:gas 0 #:supply-used 17 #:supply-cap 23
                  #:mineral-harvesters 17 #:vespene-harvesters 0
                  #:ally-units scvs-17 #:ally-buildings (list cc dep rax)
                  #:enemy-buildings (list proxy-pyl done-can safe-pyl) #:mineral-patches mps)))
  (define safe-pyl-pulled? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 21853))) a-59-safe))
  (define near-pyl-pulled? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 21850))) a-59-safe))
  (check-true "L50-W1-2b-worker-rush-protects-ramp-buildings-and-proxy-cannon-pull"
              (and (>= (length chance-pulled) 8)
                   (not chance-leash-mw?)
                   can-pull (>= (length (second can-pull)) 6)
                   pyl-pull
                   safe-pyl-pulled?
                   (not near-pyl-pulled?))
              (format "chance=~a mw?=~a can-pull=~a pyl?=~a safe?=~a near?=~a"
                      (length chance-pulled) chance-leash-mw? can-pull (and pyl-pull #t) safe-pyl-pulled? near-pyl-pulled?)))

;; -----------------------------------------------------------------------------
;; 22. L50-W1-2c: Zerg Baneling Light-Ground Gate, Routine Overseer Cap<=3, Dropper Gate & Ring Ambush
;; -----------------------------------------------------------------------------
(let ()
  (define h1 (mk-u 22001 'lair 32.5 32.5 #:hp 2000.0))
  (define h2 (mk-u 22002 'hatchery 56.5 32.5 #:hp 1500.0))
  (define sp (mk-u 22003 'spawning-pool 36.5 36.5 #:hp 1000.0))
  (define bn (mk-u 22004 'baneling-nest 38.5 34.5 #:hp 850.0))
  (define drones (for/list ([i (in-range 36)]) (mk-u (+ 22101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define lings-16 (for/list ([i (in-range 16)]) (mk-u (+ 22201 i) 'zergling 48.0 (+ 32.0 (* 0.3 i)) #:hp 35.0)))
  (define ovis-4 (for/list ([i (in-range 4)]) (mk-u (+ 22251 i) 'overlord 34.0 (+ 34.0 i) #:hp 200.0 #:flying #t)))
  ;; (a) Baneling Light-Ground Gate: vs 12 Roaches (`#64`, 0 Light ground) -> ZERO Baneling morphs!
  (define e-roaches (for/list ([i (in-range 12)]) (mk-u (+ 22801 i) 'roach 80.0 (+ 32.0 (* 0.4 i)) #:hp 145.0)))
  (define a-vs-roach
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Zerg 6400 #:minerals 300 #:gas 200 #:supply-used 48 #:supply-cap 72
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-units (append drones lings-16 ovis-4)
                  #:ally-buildings (list h1 h2 sp bn) #:enemy-units e-roaches)))
  (define bane-vs-roach? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'baneling))) a-vs-roach))
  ;; (b) Routine Overseer Cap <= 3 (`#37` Phoenixes, 0 cloak/burrow), unlocked immediately when DT appears!
  (define rt-ov (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define e-phx (for/list ([i (in-range 6)]) (mk-u (+ 22830 i) 'phoenix 85.0 (+ 35.0 i) #:hp 120.0 #:shield 60.0 #:flying #t)))
  (define sp-bldg (mk-u 22005 'spire 38.5 36.5 #:hp 850.0))
  (define hd-bldg (mk-u 22006 'hydralisk-den 38.5 38.5 #:hp 850.0))
  (define (step-ov f eu)
    (step-layer2-economy!
     rt-ov
     (mk-live-obs 'Zerg 'Protoss f #:minerals 350 #:gas 300 #:supply-used 48 #:supply-cap 72
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-units (append drones lings-16 ovis-4)
                  #:ally-buildings (list h1 h2 sp sp-bldg hd-bldg) #:enemy-units eu)))
  (define (morphed-ov? acts) (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'overseer))) acts))
  (define ov1? (morphed-ov? (step-ov 6000 e-phx)))
  (define ov2? (morphed-ov? (step-ov 6500 e-phx)))
  (define ov3? (morphed-ov? (step-ov 7000 e-phx)))
  (define ov4-blocked? (not (morphed-ov? (step-ov 7500 e-phx))))
  (define ov-cloak-unlock? (morphed-ov? (step-ov 7600 (cons (mk-u 22899 'dark-templar 75.0 35.0 #:hp 40.0 #:shield 80.0 #:cloak 1) e-phx))))
  ;; (c) `OverlordTransport` active-drop gate (`#49`): Lair + 40 supply Roaches + 4 Overlords, NO active drop plan -> 0 morph!
  (define roaches-20 (for/list ([i (in-range 20)]) (mk-u (+ 22301 i) 'roach 50.0 (+ 32.0 (* 0.3 i)) #:hp 145.0)))
  (define a-dl-l34
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
             (mk-live-obs 'Zerg 'Protoss 7200 #:supply-used 76 #:supply-cap 100
                          #:ally-units (append drones roaches-20 ovis-4)
                          #:ally-buildings (list h1 h2 sp) #:enemy-units '())))
  (define dl-morphed? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (third a) 'overlord-transport))) a-dl-l34))
  ;; (d) `RING-AMBUSH-RAIDER-SYMS` excludes `hydralisk`/`ravager` -> ZERO burrow-down near Photon Cannon!
  (define hydras-ravs
    (append (for/list ([i (in-range 6)]) (mk-u (+ 22401 i) 'hydralisk 76.0 (+ 80.0 (* 0.5 i)) #:hp 90.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 22421 i) 'ravager 75.0 (+ 80.0 (* 0.6 i)) #:hp 120.0))))
  (define a-ring
    (execute-stationary-detection-ring-ambush-micro
     (mk-live-obs 'Zerg 'Protoss 8000 #:ally-units hydras-ravs
                  #:enemy-units (for/list ([i (in-range 10)]) (mk-u (+ 22901 i) 'stalker 84.0 (+ 80.0 (* 0.4 i)) #:hp 80.0 #:shield 80.0))
                  #:enemy-buildings (list (mk-u 22950 'photon-cannon 83.0 80.5 #:hp 150.0 #:shield 150.0)
                                          (mk-u 22951 'nexus 88.0 80.5 #:hp 1000.0 #:shield 1000.0))
                  #:researched-upgrades '(burrow))))
  (define ring-burrow? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'burrow-down))) a-ring))
  (check-true "L50-W1-2c-zerg-baneling-light-gate-overseer-cap3-dropper-gate-and-ring-ambush"
              (and (not bane-vs-roach?)
                   ov1? ov2? ov3? ov4-blocked? ov-cloak-unlock?
                   (not dl-morphed?)
                   (not ring-burrow?))
              (format "bane?=~a ov=~a/~a/~a/blk=~a/clk=~a dl?=~a ring?=~a"
                      bane-vs-roach? ov1? ov2? ov3? ov4-blocked? ov-cloak-unlock? dl-morphed? ring-burrow?)))

;; -----------------------------------------------------------------------------
;; 23. L50-W1-2d: Medivac Safe Bio-Rear Tether (<= 6.0t) & Solo AA/Cannon Over-Fly Guard (`#50`)
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) 4 empty Medivacs drifted forward at `(84, 80)` over enemy Photon Cannon `(86, 80)` & Stalkers `(85, 82)`
  ;;     while friendly Marines are at `(70, 80)`: ALL 4 Medivacs MUST move strictly `<= 6.0t` behind Bio (`x < 70`)!
  (define bio-8 (for/list ([i (in-range 8)]) (mk-u (+ 23101 i) 'marine 70.0 (+ 78.5 (* 0.4 i)) #:hp 55.0)))
  (define meds-4 (for/list ([i (in-range 4)]) (mk-u (+ 23201 i) 'medivac 84.0 (+ 79.0 (* 0.5 i)) #:hp 150.0 #:flying #t)))
  (define e-cannon (mk-u 23801 'photon-cannon 86.0 80.0 #:hp 150.0 #:shield 150.0))
  (define e-stalkers (list (mk-u 23810 'stalker 85.0 82.0 #:hp 80.0 #:shield 80.0)
                           (mk-u 23811 'stalker 85.0 78.0 #:hp 80.0 #:shield 80.0)))
  (define a-med
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Protoss 9800 #:base-x 32.5 #:base-y 32.5 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units (append bio-8 meds-4)
                          #:enemy-units e-stalkers #:enemy-buildings (list e-cannon))))
  (define med-mvs
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (>= (second a) 23201) (<= (second a) 23204))) a-med))
  (define all-tethered-behind-bio?
    (and (= (length med-mvs) 4)
         (for/and ([m (in-list med-mvs)])
           (and (< (third m) 70.0)
                (<= (dist2d-t (third m) (fourth m) 70.0 79.9) 6.05)))))
  ;; (b) Lone empty Medivac (`0` bio) hovering over Photon Cannon at `(86, 80)` retreats away toward home!
  (define a-lone
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Protoss 9820 #:base-x 32.5 #:base-y 32.5 #:enemy-x 140.0 #:enemy-y 140.0
                          #:ally-units (list (mk-u 23299 'medivac 84.0 80.0 #:hp 150.0 #:flying #t))
                          #:enemy-units '() #:enemy-buildings (list e-cannon))))
  (define lone-mv (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 23299))) a-lone))
  (define lone-retreated? (and lone-mv (< (third lone-mv) 80.0)))
  (check-true "L50-W1-2d-medivac-bio-rear-tether-and-aa-cannon-overfly-guard"
              (and all-tethered-behind-bio? lone-retreated?)
              (format "med-mvs=~a lone-mv=~a" med-mvs lone-mv)))

;; -----------------------------------------------------------------------------
;; 24. L50-W2-3: `#04 PvT` Robo-Busy Colossus #1 Escrow Guard & 1-Medivac Stargate No-Bypass
;; -----------------------------------------------------------------------------
(let ()
  (define nex1 (mk-u 24001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define nex2 (mk-u 24002 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define pyl  (mk-u 24003 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0))
  (define gws  (for/list ([i (in-range 4)]) (mk-u (+ 24010 i) 'warp-gate (+ 38.0 (* 2.0 i)) 34.0 #:hp 500.0 #:shield 500.0)))
  (define assm (list (mk-u 24020 'assimilator 28.5 36.5 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
                     (mk-u 24021 'assimilator 52.5 36.5 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))
  (define cyb  (mk-u 24005 'cybernetics-core 38.0 37.0 #:hp 550.0 #:shield 550.0))
  (define tc   (mk-u 24006 'twilight-council 35.0 38.0 #:hp 500.0 #:shield 500.0))
  ;; Robo #1 BUSY training Observer (`order-ability-id 977` -> `open-prod-slots 'robotics-facility = 0`):
  (define robo-busy (mk-u 24007 'robotics-facility 41.0 34.0 #:hp 450.0 #:shield 450.0
                          #:orders (list (hasheq 'ability-id 977)) #:order-ability-id 977))
  (define rbay (mk-u 24008 'robotics-bay 41.0 38.0 #:hp 500.0 #:shield 500.0))
  (define p-bldgs (append (list nex1 nex2 pyl cyb tc robo-busy rbay) gws assm))
  (define probes (for/list ([i (in-range 42)]) (mk-u (+ 24101 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define stks (for/list ([i (in-range 10)]) (mk-u (+ 24201 i) 'stalker 50.0 (+ 32.0 (* 0.3 i)) #:hp 80.0 #:shield 80.0)))
  ;; Enemy Terran: 14 Marines + 1 Medivac (`protoss-aa-needed?` on 1 Medivac, `< 4` air, NOT capital air!):
  (define e-pvt
    (cons (mk-u 24899 'medivac 72.0 34.0 #:hp 150.0 #:flying #t)
          (for/list ([i (in-range 14)]) (mk-u (+ 24801 i) 'marine 70.0 (+ 31.0 (* 0.3 i)) #:hp 45.0))))
  (define a-col-hold
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 9200 #:minerals 350 #:gas 210 #:supply-used 66 #:supply-cap 94
                  #:mineral-harvesters 36 #:vespene-harvesters 6
                  #:ally-units (append probes stks)
                  #:ally-buildings p-bldgs
                  #:enemy-units e-pvt
                  #:enemy-buildings (list (mk-u 24950 'command-center 140.0 140.0 #:hp 1500.0))
                  #:researched-upgrades '(warp-gate-research))))
  (define built-stargate? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'stargate))) a-col-hold))
  (define built-ta? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'templar-archive))) a-col-hold))
  (define res-blink? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'research) (eq? (second a) 'blink))) a-col-hold))
  ;; Against Capital Air (2 Battlecruisers), Stargate MUST still bypass Colossus #1 hold
  ;; even at 250G (< 200G Colossus + 150G Stargate = 350G)!
  (define e-cap-air
    (list (mk-u 24850 'battlecruiser 80.0 32.0 #:hp 550.0 #:flying #t)
          (mk-u 24851 'battlecruiser 82.0 34.0 #:hp 550.0 #:flying #t)))
  (define a-cap-air
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 9200 #:minerals 400 #:gas 250 #:supply-used 66 #:supply-cap 94
                  #:mineral-harvesters 36 #:vespene-harvesters 6
                  #:ally-units (append probes stks)
                  #:ally-buildings p-bldgs
                  #:enemy-units e-cap-air
                  #:enemy-buildings (list (mk-u 24950 'command-center 140.0 140.0 #:hp 1500.0))
                  #:researched-upgrades '(warp-gate-research))))
  (define cap-air-stargate? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'stargate))) a-cap-air))
  (check-true "L50-W2-3-pvt-robo-busy-colossus1-guard-and-stargate-1medivac-no-bypass"
              (and (not built-stargate?) (not built-ta?) (not res-blink?) cap-air-stargate?)
              (format "sg?=~a ta?=~a blink?=~a cap-sg?=~a" built-stargate? built-ta? res-blink? cap-air-stargate?)))

;; -----------------------------------------------------------------------------
;; 25. L50-W2-4: `#01 ZvZ` Light-Ground Urgent Baneling Trigger (>= 12) + Ravager Cap (4 / 6)
;; -----------------------------------------------------------------------------
(let ()
  (define h1 (mk-u 25001 'lair 32.5 32.5 #:hp 2000.0))
  (define h2 (mk-u 25002 'hatchery 56.5 32.5 #:hp 1500.0))
  (define sp (mk-u 25003 'spawning-pool 36.5 36.5 #:hp 1000.0))
  (define bn (mk-u 25004 'baneling-nest 38.5 34.5 #:hp 850.0))
  (define rw (mk-u 25005 'roach-warren 38.5 38.5 #:hp 850.0))
  (define hd (mk-u 25006 'hydralisk-den 35.5 38.5 #:hp 850.0))
  (define drones (for/list ([i (in-range 40)]) (mk-u (+ 25101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define lings-14 (for/list ([i (in-range 14)]) (mk-u (+ 25201 i) 'zergling 48.0 (+ 32.0 (* 0.3 i)) #:hp 35.0)))
  ;; (a) ZvZ Ling+Hydra swarm (10 Lings + 4 Hydras = 14 >= 12 Light ground, 0 Marines/Zealots) -> morphs Baneling!
  (define e-zvz-light
    (append (for/list ([i (in-range 10)]) (mk-u (+ 25801 i) 'zergling 78.0 (+ 32.0 (* 0.3 i)) #:hp 35.0))
            (for/list ([i (in-range 4)])  (mk-u (+ 25821 i) 'hydralisk 80.0 (+ 32.0 (* 0.4 i)) #:hp 90.0))))
  (define a-zvz-bane
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Zerg 8200 #:minerals 250 #:gas 150 #:supply-used 52 #:supply-cap 86
                  #:mineral-harvesters 34 #:vespene-harvesters 6
                  #:ally-units (append drones lings-14)
                  #:ally-buildings (list h1 h2 sp bn rw) #:enemy-units e-zvz-light)))
  (define zvz-bane? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'baneling))) a-zvz-bane))
  ;; (b) Ravager cap = 4 when HydraDen ready, < 12 Hydras, < 200G; hard cap = 6 at >= 200G; <= 2 still morphs!
  (define h3 (mk-u 25007 'hatchery 32.5 64.5 #:hp 1500.0))
  (define roaches-16 (for/list ([i (in-range 16)]) (mk-u (+ 25301 i) 'roach 52.0 (+ 32.0 (* 0.3 i)) #:hp 145.0)))
  (define hydras-6   (for/list ([i (in-range 6)])  (mk-u (+ 25351 i) 'hydralisk 50.0 (+ 32.0 (* 0.3 i)) #:hp 90.0)))
  (define ravs-4     (for/list ([i (in-range 4)])  (mk-u (+ 25401 i) 'ravager 53.0 (+ 32.0 (* 0.4 i)) #:hp 120.0)))
  (define ravs-6     (for/list ([i (in-range 6)])  (mk-u (+ 25411 i) 'ravager 53.0 (+ 32.0 (* 0.4 i)) #:hp 120.0)))
  (define ravs-2     (for/list ([i (in-range 2)])  (mk-u (+ 25421 i) 'ravager 53.0 (+ 32.0 (* 0.4 i)) #:hp 120.0)))
  (define e-roaches-8 (for/list ([i (in-range 8)]) (mk-u (+ 25851 i) 'roach 82.0 (+ 32.0 (* 0.4 i)) #:hp 145.0)))
  (define (morphed-rav? acts) (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'ravager))) acts))
  (define a-rav-cap4
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Zerg 9200 #:minerals 300 #:gas 150 #:supply-used 96 #:supply-cap 130
                  #:mineral-harvesters 34 #:vespene-harvesters 6
                  #:ally-units (append drones roaches-16 hydras-6 ravs-4)
                  #:ally-buildings (list h1 h2 h3 sp rw hd) #:enemy-units e-roaches-8)))
  (define a-rav-cap6
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Zerg 9200 #:minerals 400 #:gas 350 #:supply-used 102 #:supply-cap 130
                  #:mineral-harvesters 34 #:vespene-harvesters 6
                  #:ally-units (append drones roaches-16 hydras-6 ravs-6)
                  #:ally-buildings (list h1 h2 h3 sp rw hd) #:enemy-units e-roaches-8)))
  (define a-rav-ok2
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Zerg 9200 #:minerals 300 #:gas 250 #:supply-used 90 #:supply-cap 130
                  #:mineral-harvesters 34 #:vespene-harvesters 6
                  #:ally-units (append drones roaches-16 hydras-6 ravs-2)
                  #:ally-buildings (list h1 h2 h3 sp rw hd) #:enemy-units e-roaches-8)))
  (check-true "L50-W2-4-zvz-light-gnd-baneling-trigger-and-ravager-cap-4-6"
              (and zvz-bane?
                   (not (morphed-rav? a-rav-cap4))
                   (not (morphed-rav? a-rav-cap6))
                   (morphed-rav? a-rav-ok2))
              (format "zvz-bane?=~a rav4?=~a rav6?=~a rav2?=~a"
                      zvz-bane? (morphed-rav? a-rav-cap4) (morphed-rav? a-rav-cap6) (morphed-rav? a-rav-ok2))))

;; -----------------------------------------------------------------------------
;; 26. L50-W3-1: `d10` Viking Landing vs Mechanical Stalkers After Observers Die
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Unit-level `plan-viking-modes`:
  ;;     - While live Observers remain AND Cloaked Banshees are in our squad -> stay Fighter (snipe Observers!).
  ;;     - Once both Observers die (0 live air, >= 64f dwell, >= 50% HP, 0 splash <= 7.5t,
  ;;       Mechanical Stalkers at 0.55 ratio with Banshee squad allies) -> land Assault (`403`)!
  ;;     - If Colossus or Void Ray appears -> lift off immediately (`405`)!
  (define tr (make-unit-mode-tracker))
  (define v1-55hp (mk-u 26001 'viking-fighter 78.0 80.0 #:hp 75.0 #:max-hp 135.0 #:flying #t))
  (define v2-full (mk-u 26002 'viking-fighter 78.0 81.5 #:hp 135.0 #:max-hp 135.0 #:flying #t))
  (define banshees
    (list (mk-u 26011 'banshee 80.0 79.5 #:hp 140.0 #:max-hp 140.0 #:cloak 1 #:flying #t)
          (mk-u 26012 'banshee 80.0 80.5 #:hp 140.0 #:max-hp 140.0 #:cloak 1 #:flying #t)
          (mk-u 26013 'banshee 80.0 81.5 #:hp 140.0 #:max-hp 140.0 #:cloak 1 #:flying #t)))
  (define d10-allies (append (list v1-55hp v2-full) banshees))
  (define stalkers-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 26801 i) 'stalker 88.0 (+ 77.0 (* 0.8 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define obs-live
    (list (mk-u 26851 'observer 85.0 80.0 #:hp 40.0 #:max-hp 40.0 #:shield 20.0 #:max-shield 20.0 #:flying #t)
          (mk-u 26852 'observer 85.5 81.0 #:hp 40.0 #:max-hp 40.0 #:shield 20.0 #:max-shield 20.0 #:flying #t)))
  (sync-unit-mode-tracker! tr d10-allies (append stalkers-8 obs-live) 4000 #:track-air-memory? #t)
  (define hold-while-obs-live
    (plan-viking-modes d10-allies (append stalkers-8 obs-live) #:tracker tr #:current-frame 4070))
  ;; Observers killed -> 0 live air -> Vikings land (`morph-viking-assault` 403), including 55% HP Viking!
  (sync-unit-mode-tracker! tr d10-allies stalkers-8 4080 #:dead-tags '(26851 26852) #:track-air-memory? #t)
  (define land-after-obs-dead
    (plan-viking-modes d10-allies stalkers-8 #:tracker tr #:current-frame 4080))
  (define both-landed?
    (and (= (length land-after-obs-dead) 2)
         (andmap (lambda (d) (eq? (unit-mode-directive-ability d) 'morph-viking-assault))
                 land-after-obs-dead)))
  ;; Once landed at 55% HP against Stalkers, Assault Viking must NOT yo-yo lift off next frame!
  (define v1-landed (mk-u 26001 'viking-assault 82.0 80.0 #:hp 75.0 #:max-hp 135.0 #:flying #f))
  (define v2-landed (mk-u 26002 'viking-assault 82.0 81.5 #:hp 135.0 #:max-hp 135.0 #:flying #f))
  (define stay-landed-no-yoyo
    (plan-viking-modes (append (list v1-landed v2-landed) banshees) stalkers-8 #:tracker tr #:current-frame 4120))
  ;; If Colossus enters <= 15t after >= 64f dwell -> immediate liftoff (`morph-viking-fighter` 405)!
  (define col-enemy (mk-u 26890 'colossus 92.0 80.5 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0))
  (define lift-vs-colossus
    (plan-viking-modes (append (list v1-landed v2-landed) banshees) (cons col-enemy stalkers-8)
                       #:tracker tr #:current-frame 4150))
  (define both-lifted?
    (and (= (length lift-vs-colossus) 2)
         (andmap (lambda (d) (eq? (unit-mode-directive-ability d) 'morph-viking-fighter))
                 lift-vs-colossus)))
  ;; (b) End-to-end `run-l34`: 55% HP Fighter Viking lands cleanly via live runtime
  ;;     (verifies `bot-runtime.rkt:31472` prefilter honors `VIKING-LAND-MIN-HP-RATIO=0.50` & `64f` dwell!).
  (define rt-vik (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define cc-t (mk-u 26901 'command-center 32.5 32.5 #:hp 1500.0))
  (define acts-vik-land
    (run-l34
     rt-vik
     (mk-live-obs 'Terran 'Protoss 4200 #:supply-used 22 #:supply-cap 54
                  #:ally-units d10-allies #:ally-buildings (list cc-t)
                  #:enemy-units stalkers-8
                  #:enemy-buildings (list (mk-u 26950 'nexus 142.5 138.5 #:hp 1000.0 #:shield 1000.0)))))
  (define rt-v1-landed?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eqv? (second a) 26001) (eq? (third a) 'morph-viking-assault)))
           acts-vik-land))
  (define rt-v2-landed?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eqv? (second a) 26002) (eq? (third a) 'morph-viking-assault)))
           acts-vik-land))
  (check-true "L50-W3-1-viking-d10-landing-vs-stalkers-and-colossus-liftoff"
              (and (null? hold-while-obs-live)
                   both-landed?
                   (null? stay-landed-no-yoyo)
                   both-lifted?
                   rt-v1-landed?
                   rt-v2-landed?)
              (format "hold-obs=~a landed?=~a no-yoyo=~a lifted?=~a rt1?=~a rt2?=~a"
                      (length hold-while-obs-live) both-landed? (length stay-landed-no-yoyo)
                      both-lifted? rt-v1-landed? rt-v2-landed?)))

;; -----------------------------------------------------------------------------
;; 27. L50-W3-2: Raven Auto-Turret `1764` + Cast Non-Overwrite + `< 75%` Kite + `< 50` En Retreat
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) `pro-spellcaster-micro.rkt` metadata matches live SC2 wire IDs (`1764`, `2073`, `2704`)
  (define turret-modes
    (filter (lambda (m) (and (eq? (spell-tactic-mode-caster-type m) 'raven)
                             (eq? (spell-tactic-mode-ability m) 'auto-turret)))
            SPELL-ABILITY-3-TACTICS-CATALOG))
  (define consume-modes
    (filter (lambda (m) (and (eq? (spell-tactic-mode-caster-type m) 'viper)
                             (eq? (spell-tactic-mode-ability m) 'viper-consume)))
            SPELL-ABILITY-3-TACTICS-CATALOG))
  (define locust-modes
    (filter (lambda (m) (and (eq? (spell-tactic-mode-caster-type m) 'swarm-host-mp)
                             (eq? (spell-tactic-mode-ability m) 'spawn-locusts)))
            SPELL-ABILITY-3-TACTICS-CATALOG))
  (define meta-ids-ok?
    (and (pair? turret-modes) (andmap (lambda (m) (= (spell-tactic-mode-ability-id m) 1764)) turret-modes)
         (pair? consume-modes) (andmap (lambda (m) (= (spell-tactic-mode-ability-id m) 2073)) consume-modes)
         (pair? locust-modes) (andmap (lambda (m) (= (spell-tactic-mode-ability-id m) 2704)) locust-modes)))
  (define cc-t (mk-u 27901 'command-center 32.5 32.5 #:hp 1500.0))
  (define nex-e (mk-u 27950 'nexus 142.5 138.5 #:hp 1000.0 #:shield 1000.0))
  (define banshees
    (list (mk-u 27011 'banshee 80.0 80.0 #:hp 140.0 #:max-hp 140.0 #:cloak 1 #:flying #t)
          (mk-u 27012 'banshee 80.0 81.0 #:hp 140.0 #:max-hp 140.0 #:cloak 1 #:flying #t)))
  (define stalkers-close
    (for/list ([i (in-range 6)])
      (mk-u (+ 27801 i) 'stalker 84.5 (+ 78.5 (* 0.6 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  ;; (b) Raven at `60` energy emits `auto-turret` AND `[(raven) ...]` does NOT emit any overwriting `move`/`kite`!
  (define rav-cast (mk-u 27001 'raven 79.0 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 60.0 #:flying #t))
  (define acts-cast
    (run-l34
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 4300 #:supply-used 22 #:supply-cap 54
                  #:ally-units (cons rav-cast banshees) #:ally-buildings (list cc-t)
                  #:enemy-units stalkers-close #:enemy-buildings (list nex-e))))
  (define rav-cast-cmds (filter (lambda (a) (and (pair? a) (>= (length a) 2) (eqv? (second a) 27001))) acts-cast))
  (define cast-turret-only?
    (and (ormap (lambda (a) (and (eq? (car a) 'cast-spell) (eq? (third a) 'auto-turret))) rav-cast-cmds)
         (not (ormap (lambda (a) (memq (car a) '(move kite))) rav-cast-cmds))))
  ;; (c) Raven actively cast-walking Auto-Turret (`order-ability-id 1764`) is NOT overwritten on next tick!
  (define rav-walking-1764
    (mk-u 27001 'raven 79.0 80.0 #:hp 100.0 #:max-hp 140.0 #:energy 60.0 #:flying #t #:order-ability-id 1764))
  (define acts-walk-1764
    (run-l34
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 4304 #:supply-used 22 #:supply-cap 54
                  #:ally-units (cons rav-walking-1764 banshees) #:ally-buildings (list cc-t)
                  #:enemy-units stalkers-close #:enemy-buildings (list nex-e))))
  (define walk-1764-protected?
    (not (ormap (lambda (a) (and (pair? a) (>= (length a) 2) (eqv? (second a) 27001) (memq (car a) '(move kite))))
                acts-walk-1764)))
  ;; (d) Injured Raven (`HP = 95/140 = 67.8% < 75%`, `en = 30`) within `<= 8.0t` of Stalkers -> kites away!
  (define rav-hurt (mk-u 27002 'raven 78.5 80.0 #:hp 95.0 #:max-hp 140.0 #:energy 30.0 #:flying #t))
  (define obs-alive (mk-u 27851 'observer 84.0 80.0 #:hp 40.0 #:max-hp 40.0 #:shield 20.0 #:max-shield 20.0 #:flying #t))
  (define acts-hurt
    (run-l34
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 4310 #:supply-used 22 #:supply-cap 54
                  #:ally-units (cons rav-hurt banshees) #:ally-buildings (list cc-t)
                  #:enemy-units (cons obs-alive stalkers-close) #:enemy-buildings (list nex-e))))
  (define hurt-kite-cmd
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'kite) (eqv? (second a) 27002))) acts-hurt))
  (define hurt-kites-away?
    (and hurt-kite-cmd (< (third hurt-kite-cmd) 77.5)))
  ;; (e) Healthy Raven with `< 50` energy (`en = 25`) & ZERO enemy cloaked/burrowed threats retreats
  ;;     safely `>= 9.5t` away from Stalkers (instead of hovering `2.2t` behind Banshees at `x=77.8`!)
  (define rav-low-en (mk-u 27003 'raven 78.5 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 25.0 #:flying #t))
  (define acts-low-en
    (run-l34
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 4320 #:supply-used 22 #:supply-cap 54
                  #:ally-units (cons rav-low-en banshees) #:ally-buildings (list cc-t)
                  #:enemy-units stalkers-close #:enemy-buildings (list nex-e))))
  (define low-en-ret-cmd
    (findf (lambda (a) (and (pair? a) (memq (car a) '(kite move)) (eqv? (second a) 27003))) acts-low-en))
  (define low-en-retreats-9.5?
    (and low-en-ret-cmd
         (let* ([rx (third low-en-ret-cmd)]
                [ry (fourth low-en-ret-cmd)]
                [d-stk (sqrt (+ (expt (- rx 84.5) 2) (expt (- ry 80.0) 2)))])
           (>= d-stk 9.5))))
  ;; (f) Healthy Raven (`HP = 140/140`, `en = 25`) WITH live cloaked Observer stays tethered near Vikings!
  (define vik-escort (mk-u 27021 'viking-fighter 78.5 80.0 #:hp 135.0 #:max-hp 135.0 #:flying #t))
  (define rav-det (mk-u 27004 'raven 72.0 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 25.0 #:flying #t))
  (define acts-det
    (run-l34
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 4330 #:supply-used 22 #:supply-cap 54
                  #:ally-units (cons rav-det (cons vik-escort banshees)) #:ally-buildings (list cc-t)
                  #:enemy-units (cons obs-alive stalkers-close) #:enemy-buildings (list nex-e))))
  (define det-tether-cmd
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (eqv? (second a) 27004))) acts-det))
  (define det-stays-tethered?
    (and det-tether-cmd (> (third det-tether-cmd) 74.5)))
  (check-true "L50-W3-2-raven-1764-non-overwrite-75hp-kite-and-low-en-retreat"
              (and meta-ids-ok?
                   cast-turret-only?
                   walk-1764-protected?
                   hurt-kites-away?
                   low-en-retreats-9.5?
                   det-stays-tethered?)
              (format "meta?=~a cast-only?=~a walk1764?=~a hurt-kite?=~a low-en-9.5?=~a det-tether?=~a"
                      meta-ids-ok? cast-turret-only? walk-1764-protected?
                      hurt-kites-away? low-en-retreats-9.5? det-stays-tethered?)))

(printf "\n=== Loop 49 Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
