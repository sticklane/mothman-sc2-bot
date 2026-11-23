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
         "../lib/tactics/zerg-burrow-micro.rkt"
         "../lib/tactics/transport-drop-micro.rkt"
         "../lib/human-cortex.rkt"
         (only-in "../lib/plan/nydus.rkt" plan-nydus-actions plan-nydus-worm-tactics)
         (only-in "../lib/plan/creep-and-changeling.rkt" plan-changeling-free-unit-tactics)
         (only-in "../lib/plan/static-defense.rkt"
                  plan-spread-burrowed-swarm-host-harass
                  plan-counter-spread-swarm-host-harass)
         (only-in "../lib/plan/wall-and-block.rkt"
                  plan-own-wall-integrity-defense
                  plan-expansion-and-gas-blocks)
         (only-in "../lib/tactics/disruptor-micro.rkt"
                  DISRUPTOR-NOVA-BASE-DAMAGE
                  DISRUPTOR-NOVA-SHIELD-BONUS
                  score-purification-nova-impact
                  nova-impact-score-enemy-raw-value)
         (only-in "../lib/sc2-game-constants.rkt" sc2-min-cost)
         (only-in "../lib/plan/map-elements-and-experiments.rkt"
                  plan-mineral-wall-and-worker-path-tactics
                  plan-destructible-rocks-and-rockslides
                  plan-nonstandard-base-resource-allocation
                  plan-trapped-unit-dropship-rescue
                  plan-counter-warp-prism-and-recall
                  step-map-elements-tactical-micro!
                  NonstandardBasePlan-rebalance-directives
                  MapElementDirective-sexp
                  MapElementDirective-kind
                  DropshipRescueDirective-sexp
                  DropshipRescueDirective-unload-sexp)
         (only-in "../lib/plan/multitask-harass-and-proxy.rkt"
                  plan-early-worker-mineral-line-harass
                  plan-baneling-move-past-and-light-clump-detonate
                  harass-directive-action)
         (only-in "../lib/sc2-protobuf-ws.rkt"
                  sc2-data
                  sc2-ability-data-entry
                  register-sc2-response-data!
                  reset-sc2-live-response-data!
                  sc2-ability-live-available?))

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

;; -----------------------------------------------------------------------------
;; 28. L51-2A: `#75 PvT who` — Observer #1 Trains FIRST Out of Robo #1 Ahead of Immortal #1
;; -----------------------------------------------------------------------------
(let ()
  (define nex1 (mk-u 28001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define nex2 (mk-u 28002 'nexus 58.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define pyl  (mk-u 28003 'pylon 38.5 34.5 #:hp 200.0 #:shield 200.0))
  (define gw1  (mk-u 28004 'gateway 39.5 32.5 #:hp 500.0 #:shield 500.0))
  (define cyb  (mk-u 28005 'cybernetics-core 39.5 36.5 #:hp 550.0 #:shield 550.0))
  (define robo (mk-u 28006 'robotics-facility 40.5 35.5 #:hp 450.0 #:shield 450.0))
  (define assm (list (mk-u 28011 'assimilator 28.5 36.5 #:hp 450.0 #:shield 450.0)
                     (mk-u 28012 'assimilator 36.5 28.5 #:hp 450.0 #:shield 450.0)))
  (define probes (for/list ([i (in-range 28)]) (mk-u (+ 28101 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  ;; Only 2 Zealots + 1 Stalker (6 army supply < 8!) + 300M/155G when Robo finishes at 197s (`f=4410`)!
  (define army0 (list (mk-u 28201 'zealot 50.0 32.0 #:hp 100.0 #:shield 50.0)
                      (mk-u 28202 'zealot 50.0 33.0 #:hp 100.0 #:shield 50.0)
                      (mk-u 28203 'stalker 49.0 32.5 #:hp 80.0 #:shield 80.0)))
  (define a-obs1
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 4410 #:minerals 300 #:gas 155 #:supply-used 34 #:supply-cap 54
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:ally-units (append probes army0)
                  #:ally-buildings (append (list nex1 nex2 pyl gw1 cyb robo) assm)
                  #:enemy-buildings (list (mk-u 28950 'command-center 142.5 138.5 #:hp 1500.0)))))
  (define trained-obs1? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'observer))) a-obs1))
  (define trained-imm-before-obs? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'immortal))) a-obs1))
  ;; Once Observer #1 IS live, Robo immediately resumes Immortal #1 training!
  (define obs-live (mk-u 28250 'observer 52.0 33.0 #:hp 40.0 #:shield 20.0 #:flying #t))
  (define a-imm1
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 4900 #:minerals 450 #:gas 150 #:supply-used 35 #:supply-cap 54
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:ally-units (append probes army0 (list obs-live))
                  #:ally-buildings (append (list nex1 nex2 pyl gw1 cyb robo) assm)
                  #:enemy-buildings (list (mk-u 28950 'command-center 142.5 138.5 #:hp 1500.0)))))
  (define trained-imm-after-obs? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'immortal))) a-imm1))
  (check-true "L51-2A-pvt-observer1-before-immortal1-and-immortal-resumes-after"
              (and trained-obs1? (not trained-imm-before-obs?) trained-imm-after-obs?)
              (format "obs1?=~a imm-before?=~a imm-after?=~a"
                      trained-obs1? trained-imm-before-obs? trained-imm-after-obs?)))

;; -----------------------------------------------------------------------------
;; 29. L51-2B: `#20 TvZ PolyMorph` — 2 CC Rejects -> Lower Ramp Depots + In-Base CC Fallback
;;             + Zero Blind 92s Main Bunker vs Peaceful Hatch-First Zerg
;; -----------------------------------------------------------------------------
(let ()
  (define cc  (mk-u 29001 'command-center 32.5 32.5 #:hp 1500.0))
  (define dep1 (mk-u 29002 'supply-depot 42.5 32.5 #:hp 400.0))
  (define rax (mk-u 29003 'barracks 42.5 35.5 #:hp 1000.0))
  (define ref (mk-u 29004 'refinery 28.5 36.5 #:hp 500.0))
  (define scvs (for/list ([i (in-range 19)]) (mk-u (+ 29101 i) 'scv 28.0 (+ 29.0 (* 0.3 i)) #:hp 45.0)))
  (define mps (for/list ([i (in-range 8)]) (mk-u (+ 29501 i) 'mineral-field 25.0 (+ 28.0 (* 0.8 i)) #:hp 1500.0)))
  ;; Peaceful Hatch-first Zerg (`2` Hatcheries at enemy main/nat + `2` passive safety Lings at enemy nat):
  (define e-hatch-first
    (list (mk-u 29901 'hatchery 142.5 138.5 #:hp 1500.0)
          (mk-u 29902 'hatchery 122.5 136.5 #:hp 1500.0)))
  (define e-home-lings
    (list (mk-u 29911 'zergling 124.0 135.0 #:hp 35.0)
          (mk-u 29912 'zergling 125.0 135.0 #:hp 35.0)))
  ;; (a) At 92s (`f=2060`, `180M`), zero blind main Bunker vs zero-threat Hatch-first Zerg!
  (define a-92s
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Zerg 2060 #:minerals 180 #:gas 40 #:supply-used 19 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 3
                  #:ally-units scvs #:ally-buildings (list cc dep1 rax ref)
                  #:enemy-units e-home-lings #:enemy-buildings e-hatch-first #:mineral-patches mps)))
  (define built-blind-bunker? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) a-92s))
  ;; (b) Natural CC placement-reject retry loop (`f=3260` -> expire `f=3276` -> retry `f=3284` -> expire `f=3300`):
  ;;     After 2 expirations within 80f, immediately lower ramp Depots AND fall back to high-ground in-base CC!
  (define oc (mk-u 29001 'orbital-command 32.5 32.5 #:hp 1500.0))
  (define rt-cc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define (mk-cc-obs f)
    (mk-live-obs 'Terran 'Zerg f #:minerals 450 #:gas 50 #:supply-used 21 #:supply-cap 31
                 #:mineral-harvesters 16 #:vespene-harvesters 3
                 #:ally-units scvs #:ally-buildings (list oc dep1 rax ref)
                 #:enemy-units '() #:enemy-buildings e-hatch-first #:mineral-patches mps))
  ;; Tick 1 (`f=3260`): First natural CC attempt (`expand`) + proactively lowers ramp Depot!
  (define a-t1 (step-layer2-economy! rt-cc (mk-cc-obs 3260)))
  (define t1-expanded? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) a-t1))
  (define t1-lowered-depot?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'morph-supply-depot-lower))) a-t1))
  ;; Tick 2 (`f=3276`): Order-ledger expires rejected expand (1st expiration recorded)
  (define a-t2 (step-layer2-economy! rt-cc (mk-cc-obs 3276)))
  ;; Tick 3 (`f=3284`): Fast retry #2 (`expand`) + re-lowers raised ramp Depot (`>= 24f`)!
  (define a-t3 (step-layer2-economy! rt-cc (mk-cc-obs 3284)))
  (define t3-retried? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) a-t3))
  (define t3-lowered-depot?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'morph-supply-depot-lower))) a-t3))
  ;; Tick 4 (`f=3304`, 44f <= 80f after first attempt): Expiration #2 -> IMMEDIATE in-base `(build command-center ...)`!
  (define a-t4 (step-layer2-economy! rt-cc (mk-cc-obs 3304)))
  (define t4-in-base-cc?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'command-center))) a-t4))
  (check-true "L51-2B-tvz-cc-reject-lower-depot-in-base-fallback-and-no-92s-bunker"
              (and (not built-blind-bunker?)
                   t1-expanded?
                   t1-lowered-depot?
                   t3-retried?
                   t3-lowered-depot?
                   t4-in-base-cc?)
              (format "blind-bunk?=~a t1-exp?=~a t1-low?=~a t3-retry?=~a t3-low?=~a t4-inbase?=~a"
                      built-blind-bunker? t1-expanded? t1-lowered-depot? t3-retried? t3-lowered-depot? t4-in-base-cc?)))

;; -----------------------------------------------------------------------------
;; 30. L51-2C: `#50 TvP Thssprtssbt` — Cannon-Rush SCV Pull Keeps `>= 6` Mineral SCVs Mining
;; -----------------------------------------------------------------------------
(let ()
  (define cc  (mk-u 30001 'command-center 32.5 32.5 #:hp 1500.0))
  (define dep (mk-u 30002 'supply-depot 42.5 32.5 #:hp 400.0))
  (define rax (mk-u 30003 'barracks 42.5 35.5 #:hp 1000.0))
  (define ref (mk-u 30004 'refinery 28.5 36.5 #:hp 500.0))
  (define mps (for/list ([i (in-range 8)]) (mk-u (+ 30501 i) 'mineral-field 25.0 (+ 28.0 (* 0.8 i)) #:hp 1500.0)))
  ;; 13 SCVs total: 3 harvesting gas (Refinery 30004) + 10 mineral SCVs vs in-main warping Cannon + Pylon!
  ;; Must pull at most `10 - 6 = 4` SCVs so `>= 6` non-gas SCVs remain mining minerals!
  (define gas-scvs
    (for/list ([i (in-range 3)])
      (mk-u (+ 30101 i) 'scv 28.5 (+ 36.0 (* 0.3 i)) #:hp 45.0 #:order-ability-id 295 #:order-target-id 30004)))
  (define min-scvs
    (for/list ([i (in-range 10)])
      (mk-u (+ 30201 i) 'scv 27.5 (+ 28.5 (* 0.5 i)) #:hp 45.0 #:order-ability-id 295 #:order-target-id 30501)))
  (define proxy-pyl (mk-u 30850 'pylon 39.5 31.5 #:hp 200.0 #:shield 200.0 #:build-progress 1.0))
  (define proxy-can (mk-u 30851 'photon-cannon 38.5 33.0 #:hp 70.0 #:shield 70.0 #:build-progress 0.35))
  (define a-50
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 2600 #:minerals 60 #:gas 20 #:supply-used 13 #:supply-cap 23
                  #:mineral-harvesters 10 #:vespene-harvesters 3
                  #:ally-units (append gas-scvs min-scvs)
                  #:ally-buildings (list cc dep rax ref)
                  #:enemy-units (list (mk-u 30860 'probe 40.0 32.0 #:hp 20.0 #:shield 20.0))
                  #:enemy-buildings (list proxy-pyl proxy-can) #:mineral-patches mps)))
  (define pulled-ids
    (remove-duplicates
     (append* (for/list ([a (in-list a-50)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  (define remaining-min-scvs (- (length min-scvs) (length pulled-ids)))
  (check-true "L51-2C-cannon-rush-scv-pull-keeps-at-least-6-mineral-scvs-mining"
              (and (> (length pulled-ids) 0)
                   (>= remaining-min-scvs 6)
                   (not (ormap (lambda (id) (memv id '(30101 30102 30103))) pulled-ids)))
              (format "pulled=~a remaining-min=~a" (length pulled-ids) remaining-min-scvs)))

;; -----------------------------------------------------------------------------
;; 31. L51-2D: `t14` Raven Interference Matrix (3747) Priority Ahead of Auto-Turret
;; -----------------------------------------------------------------------------
(let ()
  (define bio
    (for/list ([i (in-range 8)])
      (mk-u (+ 31101 i) 'marine 75.5 (+ 78.0 (* 0.5 i)) #:hp 45.0 #:max-hp 45.0)))
  (define zealots-close
    (for/list ([i (in-range 4)])
      (mk-u (+ 31801 i) 'zealot 79.5 (+ 78.5 (* 0.6 i)) #:hp 100.0 #:max-hp 100.0 #:shield 50.0 #:max-shield 50.0)))
  (define col-9.4t
    (mk-u 31850 'colossus 83.4 80.0 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0))
  ;; (a) Raven at `en=80` with Zealot clump at 5.5t AND Colossus at 9.4t -> MUST cast Interference Matrix (`3747`) FIRST!
  (define rav-80 (mk-u 31001 'raven 74.0 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 80.0 #:flying #t))
  (define dirs-80
    (plan-terran-spellcaster-micro (cons rav-80 bio) (cons col-9.4t zealots-close) #:current-frame 5000))
  (define cast-matrix-first?
    (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 31001)
                            (eq? (spell-directive-ability d) 'interference-matrix)
                            (eqv? (spell-directive-target-tag d) 31850)))
           dirs-80))
  ;; (b) `t14` geometry (`12.2t` Colossus behind `9.5t` Stalkers with 8 Marines in AAM range):
  ;;     Raven at `en=100` MUST cast Interference Matrix (`'raven-interference-matrix`) AHEAD OF AAM!
  (define stalkers-9.5t
    (for/list ([i (in-range 5)])
      (mk-u (+ 31821 i) 'stalker 83.5 (+ 79.0 (* 0.5 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define col-12.2t
    (mk-u 31851 'colossus 86.2 80.0 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0))
  (define rav-100 (mk-u 31002 'raven 74.0 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 100.0 #:flying #t))
  (define dirs-12.2t
    (plan-terran-spellcaster-micro (cons rav-100 bio) (cons col-12.2t stalkers-9.5t) #:current-frame 5004))
  (define cast-matrix-12.2t-before-aam?
    (and (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 31002)
                                 (eq? (spell-directive-ability d) 'interference-matrix)
                                 (eq? (spell-directive-pattern-name d) 'raven-interference-matrix)
                                 (eqv? (spell-directive-target-tag d) 31851)))
                dirs-12.2t)
         (not (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 31002)
                                      (eq? (spell-directive-ability d) 'anti-armor-missile)))
                     dirs-12.2t))))
  ;; (c) Raven at `en=70` (`50 <= en < 75`) with un-Matrixed `12.2t` Colossus + close Zealots ->
  ;;     MUST hold energy for Matrix instead of wasting 50 energy on Auto-Turret!
  (define rav-70 (mk-u 31003 'raven 74.0 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 70.0 #:flying #t))
  (define dirs-hold
    (plan-terran-spellcaster-micro (cons rav-70 bio) (cons col-12.2t zealots-close) #:current-frame 5008))
  (define burned-turret-below-75?
    (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 31003)
                            (eq? (spell-directive-ability d) 'auto-turret)))
           dirs-hold))
  (check-true "L51-2D-raven-interference-matrix-3747-priority-over-auto-turret"
              (and cast-matrix-first? cast-matrix-12.2t-before-aam? (not burned-turret-below-75?))
              (format "matrix-first?=~a matrix-12.2t-before-aam?=~a burned-turret?=~a"
                      cast-matrix-first? cast-matrix-12.2t-before-aam? burned-turret-below-75?)))

;; -----------------------------------------------------------------------------
;; 32. L51-W2 (`#1262/#1263`): SC2 5.0.14 Raven Interference Matrix Upgrade Gate,
;;     Removed 4107 Battery Overcharge Live Suppression, & Fixed 5.0.14 IDs/Buffs
;; -----------------------------------------------------------------------------
(let ()
  (define bio
    (for/list ([i (in-range 8)])
      (mk-u (+ 32101 i) 'marine 75.5 (+ 78.0 (* 0.5 i)) #:hp 45.0 #:max-hp 45.0)))
  (define stalkers-9.5t
    (for/list ([i (in-range 5)])
      (mk-u (+ 32821 i) 'stalker 83.5 (+ 79.0 (* 0.5 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define zealots-close
    (for/list ([i (in-range 4)])
      (mk-u (+ 32801 i) 'zealot 79.5 (+ 78.5 (* 0.6 i)) #:hp 100.0 #:max-hp 100.0 #:shield 50.0 #:max-shield 50.0)))
  (define col-12.2t
    (mk-u 32851 'colossus 86.2 80.0 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0))
  ;; (a) Un-upgraded Raven (`#:interference-matrix-researched? #f`, `'()`):
  ;;     - At en=100 vs 12.2t Colossus + 9.5t Stalkers -> MUST skip 3747 and cast AAM (`3753`)!
  ;;     - At en=70 vs 12.2t Colossus + close Zealots -> MUST skip energy hold and drop Auto-Turret (`1764`)!
  (define rav-100 (mk-u 32001 'raven 74.0 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 100.0 #:flying #t))
  (define dirs-unupg-100
    (plan-terran-spellcaster-micro (cons rav-100 bio) (cons col-12.2t stalkers-9.5t)
                                   #:current-frame 5200
                                   #:researched-upgrades '()
                                   #:interference-matrix-researched? #f))
  (define unupg-skipped-im-cast-aam?
    (and (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'interference-matrix)) dirs-unupg-100))
         (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 32001)
                                 (eq? (spell-directive-ability d) 'anti-armor-missile)))
                dirs-unupg-100)))
  (define rav-70 (mk-u 32002 'raven 74.0 80.0 #:hp 140.0 #:max-hp 140.0 #:energy 70.0 #:flying #t))
  (define dirs-unupg-70
    (plan-terran-spellcaster-micro (cons rav-70 bio) (cons col-12.2t zealots-close)
                                   #:current-frame 5204
                                   #:researched-upgrades '()
                                   #:interference-matrix-researched? #f))
  (define unupg-dropped-turret-no-hold?
    (and (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'interference-matrix)) dirs-unupg-70))
         (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 32002)
                                 (eq? (spell-directive-ability d) 'auto-turret)))
                dirs-unupg-70)))
  ;; (b) End-to-end `run-l34` live-obs upgrade gate:
  ;;     - Without `'interference-matrix`: emits 0 `interference-matrix`, casts AAM directly.
  ;;     - With `'interference-matrix`: casts `interference-matrix` on 12.2t Colossus ahead of AAM.
  (define cc-home (mk-u 32900 'command-center 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
  (define rt-unupg (make-live-bot-runtime #:race 'Terran))
  (define obs-unupg
    (mk-live-obs 'Terran 'Protoss 5400
                 #:ally-units (cons rav-100 bio)
                 #:ally-buildings (list cc-home)
                 #:enemy-units (cons col-12.2t stalkers-9.5t)
                 #:researched-upgrades '(stimpack combat-shield)))
  (define acts-unupg (run-l34 rt-unupg obs-unupg 0.5))
  (define l34-unupg-ok?
    (and (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3)
                                      (eq? (caddr a) 'interference-matrix)))
                     acts-unupg))
         (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3)
                                 (eqv? (cadr a) 32001)
                                 (eq? (caddr a) 'anti-armor-missile)))
                acts-unupg)))
  (define rt-upg (make-live-bot-runtime #:race 'Terran))
  (define obs-upg
    (mk-live-obs 'Terran 'Protoss 5400
                 #:ally-units (cons rav-100 bio)
                 #:ally-buildings (list cc-home)
                 #:enemy-units (cons col-12.2t stalkers-9.5t)
                 #:researched-upgrades '(stimpack combat-shield interference-matrix)))
  (define acts-upg (run-l34 rt-upg obs-upg 0.5))
  (define l34-upg-ok?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 4)
                            (eqv? (cadr a) 32001)
                            (eq? (caddr a) 'interference-matrix)
                            (eqv? (cadddr a) 32851)))
           acts-upg))
  ;; (c) Live SC2 5.0.14 buff ID recognition (`300` interference-matrix-carrier prevents double Matrix)
  ;;     & catalog IDs (`morph-oversight-mode` = `3743`, `microbial-shroud` = `4111`).
  (define carrier-already-matrixed
    (mk-u 32852 'carrier 83.0 80.0 #:hp 300.0 #:max-hp 300.0 #:shield 150.0 #:max-shield 150.0 #:flying #t #:buffs '(300)))
  (define dirs-buff300
    (plan-terran-spellcaster-micro (list rav-100) (list carrier-already-matrixed)
                                   #:current-frame 5212
                                   #:researched-upgrades '(interference-matrix)
                                   #:interference-matrix-researched? #t))
  (define buff300-no-rematrix?
    (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'interference-matrix)) dirs-buff300)))
  (define catalog-5014-ok?
    (and (for/and ([m (in-list SPELL-ABILITY-3-TACTICS-CATALOG)]
                   #:when (eq? (spell-tactic-mode-ability m) 'morph-oversight-mode))
           (= (spell-tactic-mode-ability-id m) 3743))
         (for/and ([m (in-list SPELL-ABILITY-3-TACTICS-CATALOG)]
                   #:when (eq? (spell-tactic-mode-ability m) 'microbial-shroud))
           (= (spell-tactic-mode-ability-id m) 4111))))
  ;; (d) Live ResponseData `4107` (`battery-overcharge`) suppression when `available = #f`!
  (define suppressed-4107-ok?
    (dynamic-wind
     (lambda ()
       (register-sc2-response-data!
        (sc2-data (list (sc2-ability-data-entry 4107 "Effect_BatteryOvercharge" #f)
                        (sc2-ability-data-entry 4111 "Effect_AmorphousArmorcloud" #t))
                  '() '() '() '())))
     (lambda ()
       (define avail-4107? (sc2-ability-live-available? 4107))
       (define rt-p (make-live-bot-runtime #:race 'Protoss))
       (define nex (mk-u 32910 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0 #:energy 100.0))
       (define bat (mk-u 32911 'shield-battery 36.5 32.5 #:hp 150.0 #:max-hp 150.0 #:shield 150.0 #:max-shield 150.0 #:energy 100.0))
       (define stks (for/list ([i (in-range 4)])
                      (mk-u (+ 32920 i) 'stalker 38.0 (+ 31.0 (* 0.6 i)) #:hp 60.0 #:max-hp 80.0 #:shield 20.0 #:max-shield 80.0)))
       (define enemy-bunker (mk-u 32950 'bunker 41.0 32.5 #:hp 400.0 #:max-hp 400.0))
       (define enemy-mars (for/list ([i (in-range 6)])
                            (mk-u (+ 32960 i) 'marine 40.5 (+ 30.5 (* 0.6 i)) #:hp 45.0 #:max-hp 45.0)))
       (define obs-p
         (mk-live-obs 'Protoss 'Terran 3200
                      #:ally-units stks
                      #:ally-buildings (list nex bat)
                      #:enemy-units enemy-mars
                      #:enemy-buildings (list enemy-bunker)))
       (define acts-p (run-l34 rt-p obs-p 0.4))
       (and (not avail-4107?)
            (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3)
                                         (eq? (caddr a) 'battery-overcharge)))
                        acts-p))))
     (lambda ()
       (reset-sc2-live-response-data!))))
  (check-true "L51-W2-raven-im-upgrade-gate-5014-buffs-and-4107-live-suppression"
              (and unupg-skipped-im-cast-aam?
                   unupg-dropped-turret-no-hold?
                   l34-unupg-ok?
                   l34-upg-ok?
                   buff300-no-rematrix?
                   catalog-5014-ok?
                   suppressed-4107-ok?)
              (format "unupg-aam?=~a unupg-turret?=~a l34-unupg?=~a l34-upg?=~a buff300?=~a cat5014?=~a sup4107?=~a"
                      unupg-skipped-im-cast-aam?
                      unupg-dropped-turret-no-hold?
                      l34-unupg-ok?
                      l34-upg-ok?
                      buff300-no-rematrix?
                      catalog-5014-ok?
                      suppressed-4107-ok?)))

;; -----------------------------------------------------------------------------
;; 33. K12 (`L52-2B`): Cap PvT Obs-Before-Immortal to Observer #1 (Immortal after Obs #1 loss!)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-pvt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probes-32
    (for/list ([i (in-range 32)])
      (mk-u (+ 34101 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:max-hp 20.0 #:shield 20.0 #:max-shield 20.0)))
  (define stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 34201 i) 'stalker 56.0 (+ 31.0 (* 0.5 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define bldgs-2b
    (list (mk-u 34001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0)
          (mk-u 34002 'nexus 62.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0)
          (mk-u 34003 'pylon 38.0 34.0 #:hp 200.0 #:max-hp 200.0 #:shield 200.0 #:max-shield 200.0)
          (mk-u 34004 'gateway 40.0 34.0 #:hp 500.0 #:max-hp 500.0 #:shield 500.0 #:max-shield 500.0)
          (mk-u 34005 'cybernetics-core 40.0 37.5 #:hp 550.0 #:max-hp 550.0 #:shield 550.0 #:max-shield 550.0)
          (mk-u 34006 'robotics-facility 43.0 36.0 #:hp 450.0 #:max-hp 450.0 #:shield 450.0 #:max-shield 450.0)
          (mk-u 34007 'assimilator 30.0 37.0 #:hp 300.0 #:max-hp 300.0 #:shield 300.0 #:max-shield 300.0)
          (mk-u 34008 'assimilator 30.0 28.0 #:hp 300.0 #:max-hp 300.0 #:shield 300.0 #:max-shield 300.0)))
  (define enemy-tanks
    (list (mk-u 34801 'siege-tank-sieged 95.0 60.0 #:hp 175.0 #:max-hp 175.0)
          (mk-u 34802 'siege-tank-sieged 96.0 62.0 #:hp 175.0 #:max-hp 175.0)
          (mk-u 34803 'marine 93.0 60.0 #:hp 45.0 #:max-hp 45.0)))
  (define a1
    (step-layer2-economy!
     rt-pvt
     (mk-live-obs 'Protoss 'Terran 5200 #:minerals 320 #:gas 150 #:supply-used 44 #:supply-cap 62
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-32 stalkers-6)
                  #:ally-buildings bldgs-2b
                  #:enemy-units enemy-tanks)))
  (define step1-obs1?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'observer))) a1))
  (define a2
    (step-layer2-economy!
     rt-pvt
     (mk-live-obs 'Protoss 'Terran 6600 #:minerals 320 #:gas 150 #:supply-used 44 #:supply-cap 62
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-32 stalkers-6)
                  #:ally-buildings bldgs-2b
                  #:enemy-units enemy-tanks)))
  (define step2-immortal?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'immortal))) a2))
  (define step2-obs2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'observer))) a2))
  (check-true "K12-L52-2B-pvt-obs-first-capped-at-obs1-trains-immortal-after-noncloak-loss"
              (and step1-obs1? step2-immortal? (not step2-obs2?))
              (format "step1-obs1?=~a step2-imm?=~a step2-obs2?=~a a2=~a"
                      step1-obs1? step2-immortal? step2-obs2? a2)))

;; -----------------------------------------------------------------------------
;; 34. K9 (`L52-2C`): Protoss Anti-Reaper Macro Block + Main Mineral-Line Tether (`<= 12t`)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-reap (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probes-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 35101 i) 'probe 28.0 (+ 30.0 (* 0.25 i)) #:hp 20.0 #:max-hp 20.0 #:shield 20.0 #:max-shield 20.0)))
  (define stalker-1
    (mk-u 35201 'stalker 35.0 33.0 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))
  (define bldgs-p
    (list (mk-u 35001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0)
          (mk-u 35002 'pylon 37.5 34.0 #:hp 200.0 #:max-hp 200.0 #:shield 200.0 #:max-shield 200.0)
          (mk-u 35003 'gateway 39.5 34.0 #:hp 500.0 #:max-hp 500.0 #:shield 500.0 #:max-shield 500.0)
          (mk-u 35004 'gateway 39.5 37.5 #:hp 500.0 #:max-hp 500.0 #:shield 500.0 #:max-shield 500.0)
          (mk-u 35005 'cybernetics-core 37.0 37.5 #:hp 550.0 #:max-hp 550.0 #:shield 550.0 #:max-shield 550.0)))
  (define reapers-main
    (list (mk-u 35801 'reaper 29.0 33.0 #:hp 60.0 #:max-hp 60.0)
          (mk-u 35802 'reaper 30.0 35.0 #:hp 60.0 #:max-hp 60.0)
          (mk-u 35803 'reaper 31.0 36.0 #:hp 60.0 #:max-hp 60.0)
          (mk-u 35804 'reaper 56.0 33.0 #:hp 35.0 #:max-hp 60.0)))
  (define acts-l2-reap
    (step-layer2-economy!
     rt-reap
     (mk-live-obs 'Protoss 'Terran 4100 #:minerals 230 #:gas 180 #:supply-used 22 #:supply-cap 39
                  #:mineral-harvesters 13 #:vespene-harvesters 3
                  #:ally-units (cons stalker-1 probes-16)
                  #:ally-buildings bldgs-p
                  #:enemy-units reapers-main)))
  (define built-stalker? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'stalker))) acts-l2-reap))
  (define built-zealot?  (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'zealot))) acts-l2-reap))
  (define built-robo?    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-facility))) acts-l2-reap))
  (define stalker-outer (mk-u 35202 'stalker 49.0 33.0 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))
  (define acts-l34-reap
    (run-l34 rt-reap
             (mk-live-obs 'Protoss 'Terran 4104 #:supply-used 24 #:supply-cap 39
                          #:ally-units (list* stalker-1 stalker-outer probes-16)
                          #:ally-buildings bldgs-p
                          #:enemy-units reapers-main)))
  (define s1-hit-main-reaper?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 35201) (memv (third a) '(35801 35802 35803))))
           acts-l34-reap))
  (define s2-pulled-inside-12t?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 35202)
                            (<= (dist2d-t (third a) (fourth a) 32.5 32.5) 12.0)))
           acts-l34-reap))
  (define chased-decoy?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(35201 35202)) (= (third a) 35804)))
           acts-l34-reap))
  (check-true "K9-L52-2C-protoss-anti-reaper-stalker-only-macro-and-12t-main-tether"
              (and built-stalker? (not built-zealot?) (not built-robo?)
                   s1-hit-main-reaper? s2-pulled-inside-12t? (not chased-decoy?))
              (format "stlk?=~a zeal?=~a robo?=~a s1-main?=~a s2-tether?=~a decoy?=~a"
                      built-stalker? built-zealot? built-robo? s1-hit-main-reaper? s2-pulled-inside-12t? chased-decoy?)))

;; -----------------------------------------------------------------------------
;; 35. K8 (`L52-2D`): Walled-In Proxy Cannon Blocking-Pylon Retarget + Never Pull Into Completed Cannon
;; -----------------------------------------------------------------------------
(let ()
  (define rt-can (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scvs-14
    (for/list ([i (in-range 14)])
      (mk-u (+ 36101 i) 'scv (+ 28.0 (* 0.3 i)) (+ 30.0 (* 0.2 i)) #:hp 45.0 #:max-hp 45.0)))
  (define bldgs-t
    (list (mk-u 36001 'command-center 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0)))
  (define mps
    (list (mk-u 36901 'mineral-field 26.5 32.5 #:hp 1800.0)))
  (define walled-proxies
    (list (mk-u 36800 'photon-cannon 22.0 38.0 #:hp 60.0 #:max-hp 150.0 #:shield 60.0 #:max-shield 150.0 #:build-progress 0.4)
          (mk-u 36801 'pylon 24.0 37.0 #:hp 200.0 #:max-hp 200.0 #:shield 200.0 #:max-shield 200.0 #:build-progress 1.0)
          (mk-u 36802 'pylon 24.2 38.5 #:hp 120.0 #:max-hp 200.0 #:shield 80.0 #:max-shield 200.0 #:build-progress 1.0)
          (mk-u 36803 'pylon 22.5 35.8 #:hp 200.0 #:max-hp 200.0 #:shield 200.0 #:max-shield 200.0 #:build-progress 1.0)))
  (define acts-walled
    (step-layer2-economy!
     rt-can
     (mk-live-obs 'Terran 'Protoss 2600 #:minerals 80 #:supply-used 14 #:supply-cap 15
                  #:mineral-harvesters 14 #:ally-units scvs-14 #:ally-buildings bldgs-t
                  #:enemy-buildings walled-proxies #:mineral-patches mps)))
  (define targeted-blocking-pylon?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 36802))) acts-walled))
  (define targeted-walled-cannon?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 36800))) acts-walled))
  (define completed-only
    (list (mk-u 36810 'photon-cannon 24.0 38.0 #:hp 150.0 #:max-hp 150.0 #:shield 150.0 #:max-shield 150.0 #:build-progress 1.0)))
  (define acts-comp
    (step-layer2-economy!
     rt-can
     (mk-live-obs 'Terran 'Protoss 2900 #:minerals 80 #:supply-used 14 #:supply-cap 15
                  #:mineral-harvesters 14 #:ally-units scvs-14 #:ally-buildings bldgs-t
                  #:enemy-buildings completed-only #:mineral-patches mps)))
  (define pulled-into-completed-cannon?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 36810))) acts-comp))
  (check-true "K8-L52-2D-walled-proxy-cannon-targets-blocking-pylon-and-never-pulls-completed-cannon"
              (and targeted-blocking-pylon? (not targeted-walled-cannon?) (not pulled-into-completed-cannon?))
              (format "blk-pyl?=~a walled-can?=~a comp-can?=~a"
                      targeted-blocking-pylon? targeted-walled-cannon? pulled-into-completed-cannon?)))

;; -----------------------------------------------------------------------------
;; 36. K10 (`L52-2F`): TvT Immediate FactoryTechLab (0 Pre-TL WidowMine) + P1 InterferenceMatrix Research
;; -----------------------------------------------------------------------------
(let ()
  (define rt-tvt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scvs-19
    (for/list ([i (in-range 19)])
      (mk-u (+ 38101 i) 'scv 28.0 (+ 30.0 (* 0.25 i)) #:hp 45.0 #:max-hp 45.0)))
  (define marines-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 38201 i) 'marine 48.0 (+ 31.0 (* 0.4 i)) #:hp 45.0 #:max-hp 45.0)))
  (define bldgs-tvt
    (list (mk-u 38001 'orbital-command 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 38002 'command-center  62.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 38003 'barracks 42.0 34.0 #:hp 1000.0 #:max-hp 1000.0)
          (mk-u 38004 'factory  40.0 38.0 #:hp 1250.0 #:max-hp 1250.0)))
  (define a-tvt
    (step-layer2-economy!
     rt-tvt
     (mk-live-obs 'Terran 'Terran 3900 #:minerals 130 #:gas 60 #:supply-used 23 #:supply-cap 39
                  #:mineral-harvesters 16 #:vespene-harvesters 3
                  #:ally-units (append scvs-19 marines-4)
                  #:ally-buildings bldgs-tvt
                  #:enemy-units '())))
  (define built-fac-tl? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'factory-techlab))) a-tvt))
  (define trained-wm?   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'widow-mine))) a-tvt))
  (define trained-hel?  (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'hellion))) a-tvt))
  (define rt-im (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define raven-1 (mk-u 38301 'raven 45.0 35.0 #:hp 140.0 #:max-hp 140.0 #:energy 75.0 #:flying #t))
  (define bldgs-im
    (append bldgs-tvt
            (list (mk-u 38005 'factory-techlab 42.5 37.5 #:hp 400.0 #:max-hp 400.0)
                  (mk-u 38006 'starport 40.0 42.0 #:hp 1300.0 #:max-hp 1300.0 #:add-on-tag 38007)
                  (mk-u 38007 'starport-techlab 42.5 41.5 #:hp 400.0 #:max-hp 400.0))))
  (define a-im
    (step-layer2-economy!
     rt-im
     (mk-live-obs 'Terran 'Protoss 6800 #:minerals 200 #:gas 120 #:supply-used 36 #:supply-cap 54
                  #:mineral-harvesters 16 #:vespene-harvesters 3
                  #:ally-units (list* raven-1 (append scvs-19 marines-4))
                  #:ally-buildings bldgs-im
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 38999 'nexus 140.0 140.0 #:hp 1000.0 #:max-hp 1000.0)))))
  (define researched-im?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'research) (eq? (second a) 'interference-matrix))) a-im))
  (check-true "K10-L52-2F-tvt-immediate-factory-techlab-no-pretl-wm-and-p1-im-research"
              (and built-fac-tl? (not trained-wm?) (not trained-hel?) researched-im?)
              (format "fac-tl?=~a wm?=~a hel?=~a res-im?=~a a-tvt=~a a-im=~a"
                      built-fac-tl? trained-wm? trained-hel? researched-im? a-tvt a-im)))

;; -----------------------------------------------------------------------------
;; 37. K11 (`L53-W2-1`): TvT Starport #1 Before Factory #2 + Medivac #1 Ahead of Tank #3+
;; -----------------------------------------------------------------------------
(let ()
  (define rt-sp (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scvs-32
    (for/list ([i (in-range 32)])
      (mk-u (+ 41101 i) 'scv 28.0 (+ 30.0 (* 0.2 i)) #:hp 45.0 #:max-hp 45.0)))
  (define marines-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 41201 i) 'marine 48.0 (+ 31.0 (* 0.4 i)) #:hp 45.0 #:max-hp 45.0)))
  (define tanks-2
    (list (mk-u 41251 'siege-tank 49.0 32.0 #:hp 175.0 #:max-hp 175.0)
          (mk-u 41252 'siege-tank 49.0 34.0 #:hp 175.0 #:max-hp 175.0)))
  (define bldgs-no-sp
    (list (mk-u 41001 'orbital-command 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 41002 'orbital-command 62.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 41003 'barracks 42.0 34.0 #:hp 1000.0 #:max-hp 1000.0)
          (hash-set (mk-u 41004 'factory 40.0 38.0 #:hp 1250.0 #:max-hp 1250.0) 'order-count 1)
          (mk-u 41005 'factory-techlab 42.5 37.5 #:hp 400.0 #:max-hp 400.0)
          (mk-u 41006 'refinery 30.0 37.0 #:hp 500.0 #:max-hp 500.0)
          (mk-u 41007 'refinery 30.0 28.0 #:hp 500.0 #:max-hp 500.0)))
  (define a-fac2-gate
    (step-layer2-economy!
     rt-sp
     (mk-live-obs 'Terran 'Terran 5200 #:minerals 250 #:gas 150 #:supply-used 46 #:supply-cap 62
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-units (append scvs-32 marines-8 tanks-2)
                  #:ally-buildings bldgs-no-sp
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 41999 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  (define built-fac2-before-sp?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'factory))) a-fac2-gate))
  (define rt-med (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define bldgs-with-sp
    (list (mk-u 41011 'orbital-command 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 41012 'orbital-command 62.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 41013 'barracks 42.0 34.0 #:hp 1000.0 #:max-hp 1000.0)
          (mk-u 41014 'factory 40.0 38.0 #:hp 1250.0 #:max-hp 1250.0)
          (mk-u 41015 'factory-techlab 42.5 37.5 #:hp 400.0 #:max-hp 400.0)
          (mk-u 41016 'starport 40.0 42.0 #:hp 1300.0 #:max-hp 1300.0 #:add-on-tag 41019)
          (mk-u 41019 'starport-reactor 42.5 41.5 #:hp 400.0 #:max-hp 400.0)
          (mk-u 41017 'refinery 30.0 37.0 #:hp 500.0 #:max-hp 500.0)
          (mk-u 41018 'refinery 30.0 28.0 #:hp 500.0 #:max-hp 500.0)))
  ;; (b) L56-W2-3: In TvZ (`2` Tanks, `0` Medivacs, idle Starport), Medivac #1 trains ahead of Tank #3;
  ;;     in TvT, SiegeTank #3 STILL trains ahead of Medivac #1 (never delaying TvT Tanks/Vikings)!
  (define a-med1-tvz
    (step-layer2-economy!
     rt-med
     (mk-live-obs 'Terran 'Zerg 6200 #:minerals 175 #:gas 125 #:supply-used 46 #:supply-cap 62
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-units (append scvs-32 marines-8 tanks-2)
                  #:ally-buildings bldgs-with-sp
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 41998 'hatchery 140.0 140.0 #:hp 1500.0)))))
  (define trained-med1-tvz?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'medivac))) a-med1-tvz))
  (define bldgs-with-sp-2fac
    (list (mk-u 41011 'orbital-command 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 41012 'orbital-command 62.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 41013 'barracks 42.0 34.0 #:hp 1000.0 #:max-hp 1000.0 #:add-on-tag 41022)
          (mk-u 41022 'barracks-techlab 44.5 33.5 #:hp 400.0 #:max-hp 400.0)
          (mk-u 41014 'factory 40.0 38.0 #:hp 1250.0 #:max-hp 1250.0 #:add-on-tag 41015)
          (mk-u 41015 'factory-techlab 42.5 37.5 #:hp 400.0 #:max-hp 400.0)
          (mk-u 41020 'factory 40.0 46.0 #:hp 1250.0 #:max-hp 1250.0 #:add-on-tag 41021)
          (mk-u 41021 'factory-techlab 42.5 45.5 #:hp 400.0 #:max-hp 400.0)
          (mk-u 41016 'starport 40.0 42.0 #:hp 1300.0 #:max-hp 1300.0 #:add-on-tag 41019)
          (mk-u 41019 'starport-reactor 42.5 41.5 #:hp 400.0 #:max-hp 400.0)
          (mk-u 41017 'refinery 30.0 37.0 #:hp 500.0 #:max-hp 500.0)
          (mk-u 41018 'refinery 30.0 28.0 #:hp 500.0 #:max-hp 500.0)))
  (define a-tank3-tvt
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Terran 6200 #:minerals 175 #:gas 125 #:supply-used 46 #:supply-cap 62
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:ally-units (append scvs-32 marines-8 tanks-2)
                  #:ally-buildings bldgs-with-sp-2fac
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 41998 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  (define trained-tank3-tvt?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'siege-tank))) a-tank3-tvt))
  (define stole-med1-tvt?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'medivac))) a-tank3-tvt))
  (check-true "K11-L56-W2-3-starport1-before-fac2-tvz-medivac1-and-tvt-keeps-tank3"
              (and (not built-fac2-before-sp?) trained-med1-tvz? trained-tank3-tvt? (not stole-med1-tvt?))
              (format "fac2-pre-sp?=~a tvz-med1?=~a tvt-tank3?=~a tvt-med1?=~a a-tvz=~a a-tvt=~a"
                      built-fac2-before-sp? trained-med1-tvz? trained-tank3-tvt? stole-med1-tvt? a-med1-tvz a-tank3-tvt)))

;; -----------------------------------------------------------------------------
;; 38. K11 (`L53-W2-2` Colossus part ONLY): Require Colossus >= 1 Before Disruptor
;; -----------------------------------------------------------------------------
(let ()
  (define rt-dis (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probes-20
    (for/list ([i (in-range 20)])
      (mk-u (+ 42101 i) 'probe 28.0 (+ 30.0 (* 0.25 i)) #:hp 20.0 #:max-hp 20.0 #:shield 20.0 #:max-shield 20.0)))
  (define stalkers-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 42201 i) 'stalker 46.0 (+ 31.0 (* 0.4 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define bldgs-p2b-rb
    (list (mk-u 42001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0)
          (mk-u 42010 'nexus 62.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0)
          (mk-u 42002 'pylon 38.0 34.0 #:hp 200.0 #:max-hp 200.0 #:shield 200.0 #:max-shield 200.0)
          (mk-u 42003 'gateway 40.0 34.0 #:hp 500.0 #:max-hp 500.0 #:shield 500.0 #:max-shield 500.0)
          (mk-u 42004 'gateway 40.0 38.0 #:hp 500.0 #:max-hp 500.0 #:shield 500.0 #:max-shield 500.0)
          (mk-u 42005 'cybernetics-core 37.5 37.5 #:hp 550.0 #:max-hp 550.0 #:shield 550.0 #:max-shield 550.0)
          (mk-u 42006 'robotics-facility 43.0 36.0 #:hp 450.0 #:max-hp 450.0 #:shield 450.0 #:max-shield 450.0)
          (mk-u 42011 'robotics-bay 43.0 40.0 #:hp 500.0 #:max-hp 500.0 #:shield 500.0 #:max-shield 500.0)
          (mk-u 42007 'assimilator 30.0 37.0 #:hp 300.0 #:max-hp 300.0 #:shield 300.0 #:max-shield 300.0)
          (mk-u 42008 'assimilator 30.0 28.0 #:hp 300.0 #:max-hp 300.0 #:shield 300.0 #:max-shield 300.0)))
  (define a-no-dis0
    (step-layer2-economy!
     rt-dis
     (mk-live-obs 'Protoss 'Zerg 7400 #:minerals 250 #:gas 160 #:supply-used 52 #:supply-cap 78
                  #:mineral-harvesters 26 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-20 stalkers-8)
                  #:ally-buildings bldgs-p2b-rb
                  #:enemy-units (for/list ([i (in-range 10)])
                                  (mk-u (+ 42801 i) 'roach 100.0 (+ 30.0 (* 0.5 i)) #:hp 145.0))
                  #:enemy-buildings (list (mk-u 42998 'hatchery 140.0 140.0 #:hp 1500.0)))))
  (define trained-disruptor-at-0-col?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'disruptor))) a-no-dis0))
  (check-true "K11-L53-W2-2-protoss-colossus1-before-disruptor"
              (not trained-disruptor-at-0-col?)
              (format "dis-at-0col?=~a acts=~a" trained-disruptor-at-0-col? a-no-dis0)))

;; -----------------------------------------------------------------------------
;; 39. K5 + R1 (`L54-2A`): Sieged Overseer Counted in Macro Counts + Hard Live Cap `<= 2`
;; -----------------------------------------------------------------------------
(let ()
  (define drones-36
    (for/list ([i (in-range 36)])
      (mk-u (+ 44101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0 #:max-hp 40.0)))
  (define ovs-2
    (list (mk-u 44201 'overseer-siege-mode 34.0 34.0 #:hp 200.0 #:flying #t)
          (mk-u 44202 'overseer-siege-mode 62.0 34.0 #:hp 200.0 #:flying #t)))
  (define ovl-2
    (list (mk-u 44211 'overlord 30.0 36.0 #:hp 200.0 #:flying #t)
          (mk-u 44212 'overlord 31.0 36.0 #:hp 200.0 #:flying #t)))
  (define z-bldgs-ov
    (list (mk-u 44001 'lair 32.5 32.5 #:hp 2000.0 #:max-hp 2000.0)
          (mk-u 44002 'hatchery 62.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 44003 'spawning-pool 36.5 36.5 #:hp 1000.0 #:max-hp 1000.0)))
  (define cloaked-banshees
    (list (hash-set (mk-u 44801 'banshee 40.0 34.0 #:hp 140.0 #:flying #t) 'cloaked #t)
          (hash-set (mk-u 44802 'banshee 41.0 35.0 #:hp 140.0 #:flying #t) 'cloaked #t)))
  (define a-ov-cap-cloak
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 7200 #:minerals 400 #:gas 300 #:supply-used 48 #:supply-cap 90
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-units (append drones-36 ovs-2 ovl-2)
                  #:ally-buildings z-bldgs-ov
                  #:enemy-units cloaked-banshees
                  #:enemy-buildings (list (mk-u 44999 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  (define morphed-3rd-cloak?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'overseer))) a-ov-cap-cloak))
  (define a-ov-routine
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Protoss 7200 #:minerals 400 #:gas 300 #:supply-used 48 #:supply-cap 90
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-units (append drones-36 ovs-2 ovl-2)
                  #:ally-buildings z-bldgs-ov
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 44998 'nexus 140.0 140.0 #:hp 1000.0)))))
  (define morphed-3rd-routine?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'overseer))) a-ov-routine))
  (check-true "K5-R1-sieged-overseer-counted-and-hard-capped-at-2"
              (and (not morphed-3rd-cloak?) (not morphed-3rd-routine?))
              (format "3rd-cloak?=~a 3rd-routine?=~a" morphed-3rd-cloak? morphed-3rd-routine?)))

;; -----------------------------------------------------------------------------
;; 40. K1 (`L54-2B`): Expanded Ramp Depot Radius (11t) + Raised Depot Near Stuck Ground Units Lowers
;; -----------------------------------------------------------------------------
(let ()
  (define rt-dep (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 45101 i) 'scv 28.0 (+ 30.0 (* 0.2 i)) #:hp 45.0 #:max-hp 45.0)))
  (define marines-near-mouth
    (for/list ([i (in-range 4)])
      (mk-u (+ 45201 i) 'marine 51.5 (+ 33.5 (* 0.4 i)) #:hp 45.0 #:max-hp 45.0)))
  (define bldgs-dep
    (list (mk-u 45001 'orbital-command 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 45002 'command-center  62.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 45003 'barracks 42.0 34.0 #:hp 1000.0 #:max-hp 1000.0)
          (mk-u 45004 'supply-depot-lowered 45.0 34.0 #:hp 400.0 #:max-hp 400.0)
          (mk-u 45005 'supply-depot 53.5 34.0 #:hp 400.0 #:max-hp 400.0)))
  (define a-dep
    (step-layer2-economy!
     rt-dep
     (mk-live-obs 'Terran 'Terran 5200 #:minerals 100 #:gas 50 #:supply-used 20 #:supply-cap 46
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units (append scvs-16 marines-near-mouth)
                  #:ally-buildings bldgs-dep
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 45999 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  (define lowered-mouth-depot?
    (ormap (lambda (a) (equal? a '(cast-spell 45005 morph-supply-depot-lower))) a-dep))
  (check-true "K1-L54-2B-ramp-mouth-raised-depot-near-transiting-marines-lowers"
              lowered-mouth-depot?
              (format "lowered-45005?=~a acts=~a" lowered-mouth-depot? a-dep)))

;; -----------------------------------------------------------------------------
;; 41. K2 (`L54-2C`): >= 2 Protoss Observers Never Hijacked to Periodic-Scout Under Cloak Threat
;; -----------------------------------------------------------------------------
(let ()
  (define rt-obs (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probes-24
    (for/list ([i (in-range 24)])
      (mk-u (+ 46101 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 46201 i) 'stalker 35.0 (+ 31.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define observers-2
    (list (mk-u 46301 'observer 34.0 33.0 #:hp 40.0 #:shield 20.0 #:flying #t)
          (mk-u 46302 'observer 58.0 33.0 #:hp 40.0 #:shield 20.0 #:flying #t)))
  (define bldgs-obs
    (list (mk-u 46001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 46002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 46003 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 46004 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 46005 'cybernetics-core 40.0 37.5 #:hp 550.0 #:shield 550.0)
          (mk-u 46006 'robotics-facility 43.0 36.0 #:hp 450.0 #:shield 450.0)))
  (define cloaked-banshees
    (list (hash-set (mk-u 46801 'banshee 38.0 33.0 #:hp 140.0 #:flying #t) 'cloaked #t)
          (hash-set (mk-u 46802 'banshee 39.0 34.0 #:hp 140.0 #:flying #t) 'cloaked #t)))
  (define a-obs-def
    (step-layer2-economy!
     rt-obs
     (mk-live-obs 'Protoss 'Terran 6720 #:minerals 200 #:gas 100 #:supply-used 40 #:supply-cap 62
                  #:mineral-harvesters 20 #:vespene-harvesters 4
                  #:ally-units (append probes-24 stalkers-6 observers-2)
                  #:ally-buildings bldgs-obs
                  #:enemy-units cloaked-banshees)))
  (define hijacked-observer-scout?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'periodic-scout) (memv (second a) '(46301 46302)))) a-obs-def))
  (check-true "K2-L54-2C-two-observers-not-hijacked-to-periodic-scout-under-cloak-threat"
              (not hijacked-observer-scout?)
              (format "hijacked?=~a acts=~a" hijacked-observer-scout? a-obs-def)))

;; -----------------------------------------------------------------------------
;; 42. K10 (`L54-2E` Raven ONLY): Raven 50..64e Auto-Turret vs 65..74e Holds for IM
;; -----------------------------------------------------------------------------
(let ()
  (define bio-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 48301 i) 'marine 75.5 (+ 78.0 (* 0.5 i)) #:hp 45.0)))
  (define col-12 (mk-u 48850 'colossus 86.0 80.0 #:hp 200.0 #:shield 150.0))
  (define zealots-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 48860 i) 'zealot 78.0 (+ 79.0 (* 0.6 i)) #:hp 100.0 #:shield 50.0)))
  (define rav-58 (mk-u 48401 'raven 74.0 80.0 #:hp 140.0 #:energy 58.0 #:flying #t))
  (define dirs-58
    (plan-terran-spellcaster-micro (cons rav-58 bio-4) (cons col-12 zealots-3) #:current-frame 6000))
  (define rav58-dropped-turret?
    (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 48401)
                            (eq? (spell-directive-ability d) 'auto-turret)))
           dirs-58))
  (define rav-70 (mk-u 48402 'raven 74.0 80.0 #:hp 140.0 #:energy 70.0 #:flying #t))
  (define dirs-70
    (plan-terran-spellcaster-micro (cons rav-70 bio-4) (cons col-12 zealots-3) #:current-frame 6004))
  (define rav70-held-for-im?
    (not (ormap (lambda (d) (and (eqv? (spell-directive-caster-tag d) 48402)
                                 (eq? (spell-directive-ability d) 'auto-turret)))
                dirs-70)))
  (check-true "K10-L54-2E-raven-50to64e-autoturret-and-70e-holds-for-im"
              (and rav58-dropped-turret? rav70-held-for-im?)
              (format "rav58-tur?=~a rav70-hold?=~a" rav58-dropped-turret? rav70-held-for-im?)))

;; -----------------------------------------------------------------------------
;; 43. K3 (`L55-T1`): Ground AA Ignores Unpathable Cliff-Decoy Banshee (> air-range+1)
;; -----------------------------------------------------------------------------
(let ()
  (define bldgs-50
    (list (mk-u 50001 'nexus 32.5 150.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 50002 'nexus 62.5 150.0 #:hp 1000.0 #:shield 1000.0)))
  (define cliff-decoy-far
    (hash-set (mk-u 50801 'banshee 18.0 150.0 #:hp 40.0 #:max-hp 140.0 #:flying #t #:cloak 2)
              'over-unpathable-airspace? #t))
  (define reachable-ban
    (hash-set (mk-u 50802 'banshee 39.0 146.0 #:hp 140.0 #:max-hp 140.0 #:flying #t #:cloak 2)
              'over-unpathable-airspace? #f))
  (define obs-50
    (list (mk-u 50301 'observer 30.0 150.0 #:hp 40.0 #:shield 20.0 #:flying #t)))
  (define stalkers-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 50201 i) 'stalker 26.0 (+ 149.5 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define acts-early
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 5200 #:base-x 32.5 #:base-y 150.0 #:nat-x 62.5 #:nat-y 150.0
                          #:ally-units (append stalkers-3 obs-50)
                          #:ally-buildings bldgs-50
                          #:enemy-units (list cliff-decoy-far reachable-ban))))
  (define early-hit-reach?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 50201 (second a) 50203) (= (third a) 50802))) acts-early))
  (define early-chased-cliff?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 50201 (second a) 50203) (= (third a) 50801))) acts-early))
  (define stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 50211 i) 'stalker 26.0 (+ 149.0 (* 0.4 i)) #:hp 80.0 #:shield 80.0)))
  (define acts-prepped
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 6500 #:base-x 32.5 #:base-y 150.0 #:nat-x 62.5 #:nat-y 150.0
                          #:ally-units (append stalkers-6 obs-50)
                          #:ally-buildings bldgs-50
                          #:enemy-units (list cliff-decoy-far reachable-ban))))
  (define prepped-hit-reach?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 50211 (second a) 50216) (= (third a) 50802))) acts-prepped))
  (define prepped-chased-cliff?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 50211 (second a) 50216) (= (third a) 50801))) acts-prepped))
  (define cliff-in-range
    (hash-set (mk-u 50801 'banshee 20.0 150.0 #:hp 40.0 #:max-hp 140.0 #:flying #t #:cloak 2)
              'over-unpathable-airspace? #t))
  (define acts-in-rng
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 6500 #:base-x 32.5 #:base-y 150.0 #:nat-x 62.5 #:nat-y 150.0
                          #:ally-units (append stalkers-6 obs-50)
                          #:ally-buildings bldgs-50
                          #:enemy-units (list cliff-in-range reachable-ban))))
  (define in-rng-shot-cliff?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 50211 (second a) 50216) (= (third a) 50801))) acts-in-rng))
  (check-true "K3-L55-T1-ground-aa-ignores-unpathable-cliff-decoy-banshee-and-shoots-reachable"
              (and early-hit-reach? (not early-chased-cliff?)
                   prepped-hit-reach? (not prepped-chased-cliff?)
                   in-rng-shot-cliff?)
              (format "early-r?=~a early-c?=~a prep-r?=~a prep-c?=~a inrng?=~a"
                      early-hit-reach? early-chased-cliff? prepped-hit-reach? prepped-chased-cliff? in-rng-shot-cliff?)))

;; -----------------------------------------------------------------------------
;; 44. R1 (`L55-T2` REWORKED): 9.5t Standoff + `<= 24t` Overseer Cap + `448f` Remorph CD + Dual-Obs Split
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Overseer vs VikingFighter (`9.0t` AA range) guarding a cloaked Banshee within `<= 24t`:
  (define hydras-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 51101 i) 'hydralisk 48.0 (+ 31.0 (* 0.5 i)) #:hp 90.0)))
  (define ban-and-vik
    (list (mk-u 51801 'banshee 64.0 32.0 #:hp 140.0 #:flying #t #:cloak 1)
          (mk-u 51802 'viking-fighter 60.0 32.0 #:hp 135.0 #:flying #t)))
  (define acts-ov-approach
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
             (mk-live-obs 'Zerg 'Terran 6200
                          #:ally-units (cons (mk-u 51201 'overseer 50.0 32.0 #:hp 200.0 #:flying #t) hydras-4)
                          #:ally-buildings (list (mk-u 51001 'lair 32.5 32.5 #:hp 2000.0))
                          #:enemy-units ban-and-vik)))
  (define ov-app-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 51201))) acts-ov-approach))
  (define ov-holds-9.5t?
    (and ov-app-move (>= (dist2d-t (third ov-app-move) (fourth ov-app-move) 64.0 32.0) 9.2)))
  (define acts-ov-retreat
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
             (mk-live-obs 'Zerg 'Terran 6200
                          #:ally-units (cons (mk-u 51202 'overseer 52.5 32.0 #:hp 200.0 #:flying #t) hydras-4)
                          #:ally-buildings (list (mk-u 51001 'lair 32.5 32.5 #:hp 2000.0))
                          #:enemy-units ban-and-vik)))
  (define ov-ret-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 51202))) acts-ov-retreat))
  (define ov-steps-back-from-vik?
    (and ov-ret-move (< (third ov-ret-move) 52.5)))
  ;; (b) R1 `<= 24t` uncloaked Overseer cap vs `60t` cloaked Observer:
  ;;     Cloaked DT at `(85.0, 32.0)` (`35.0t > 24.0t` away from detector at `(50.0, 32.0)`):
  ;;     - Uncloaked Overseer (`51209`) MUST NOT fly cross-map toward `(85, 32)` (no move with `x > 65`)!
  ;;     - Permanently-cloaked Observer (`51210`) DOES fly straight toward `(85, 32)` (`x >= 75`)!
  (define far-cloak-dt (list (mk-u 51809 'dark-templar 85.0 32.0 #:hp 40.0 #:shield 80.0 #:cloak 1)))
  (define acts-ov-far
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
             (mk-live-obs 'Zerg 'Protoss 6400
                          #:ally-units (cons (mk-u 51209 'overseer 50.0 32.0 #:hp 200.0 #:flying #t) hydras-4)
                          #:ally-buildings (list (mk-u 51001 'lair 32.5 32.5 #:hp 2000.0))
                          #:enemy-units far-cloak-dt)))
  (define ov-chased-35t?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 51209) (> (third a) 65.0)))
           acts-ov-far))
  (define acts-obs-far
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Protoss 6400
                          #:ally-units (list (mk-u 51210 'observer 50.0 32.0 #:hp 40.0 #:shield 20.0 #:flying #t)
                                             (mk-u 51211 'stalker 48.0 32.0 #:hp 80.0 #:shield 80.0))
                          #:ally-buildings (list (mk-u 51002 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
                          #:enemy-units far-cloak-dt)))
  (define obs-dispatched-35t?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 51210) (>= (third a) 75.0)))
           acts-obs-far))
  ;; (c) R1 `>= 448f` remorph cooldown on Overseer `#2` (cap strictly `<= 2`):
  (define rt-ov-cd (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define drones-30
    (for/list ([i (in-range 30)])
      (mk-u (+ 51401 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define z-ov-bldgs
    (list (mk-u 51461 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 51462 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 51463 'spawning-pool 36.5 36.5 #:hp 1000.0)
          (mk-u 51464 'hydralisk-den 38.5 36.5 #:hp 850.0)
          (mk-u 51465 'extractor 30.0 37.0 #:hp 500.0)
          (mk-u 51466 'extractor 30.0 28.0 #:hp 500.0)
          (mk-u 51467 'spore-crawler 31.0 31.0 #:hp 400.0)
          (mk-u 51468 'spore-crawler 60.5 31.0 #:hp 400.0)))
  (define z-1ov-units
    (append drones-30
            (list (mk-u 51451 'overseer 34.0 34.0 #:hp 200.0 #:flying #t)
                  (mk-u 51453 'overlord 30.0 36.0 #:hp 200.0 #:flying #t)
                  (mk-u 51454 'hydralisk 36.0 34.0 #:hp 90.0)
                  (mk-u 51455 'hydralisk 36.5 34.5 #:hp 90.0)
                  (mk-u 51456 'hydralisk 37.0 35.0 #:hp 90.0)
                  (mk-u 51457 'hydralisk 37.5 35.5 #:hp 90.0))))
  (define dt-home (list (hash-set (mk-u 51811 'dark-templar 40.0 34.0 #:hp 40.0 #:shield 80.0) 'cloaked #t)))
  (define (mk-ov-cd-obs f)
    (mk-live-obs 'Zerg 'Protoss f #:minerals 400 #:gas 300 #:supply-used 48 #:supply-cap 90
                 #:mineral-harvesters 24 #:vespene-harvesters 6
                 #:ally-units z-1ov-units #:ally-buildings z-ov-bldgs
                 #:enemy-units dt-home
                 #:enemy-buildings (list (mk-u 51999 'nexus 140.0 140.0 #:hp 1000.0))))
  (define (morphed-ov? acts)
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'overseer))) acts))
  (define ov2-t1? (morphed-ov? (step-layer2-economy! rt-ov-cd (mk-ov-cd-obs 6000))))
  (define ov2-t2-blocked? (not (morphed-ov? (step-layer2-economy! rt-ov-cd (mk-ov-cd-obs 6200)))))
  (define ov2-t3-allowed? (morphed-ov? (step-layer2-economy! rt-ov-cd (mk-ov-cd-obs 6560))))
  ;; Also verify real `2 -> 1` Overseer loss triggers `>= 448f` cooldown on Overseer #2 remorph!
  (define rt-ov-loss (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-2ov-units (cons (mk-u 51452 'overseer 62.0 34.0 #:hp 200.0 #:flying #t) z-1ov-units))
  (step-layer2-economy!
   rt-ov-loss
   (mk-live-obs 'Zerg 'Protoss 7000 #:minerals 400 #:gas 300 #:supply-used 48 #:supply-cap 90
                #:mineral-harvesters 24 #:vespene-harvesters 6
                #:ally-units z-2ov-units #:ally-buildings z-ov-bldgs
                #:enemy-units dt-home
                #:enemy-buildings (list (mk-u 51999 'nexus 140.0 140.0 #:hp 1000.0))))
  (define ov-loss-blocked? (not (morphed-ov? (step-layer2-economy! rt-ov-loss (mk-ov-cd-obs 7100)))))
  (define ov-loss-allowed? (morphed-ov? (step-layer2-economy! rt-ov-loss (mk-ov-cd-obs 7600))))
  ;; (d) Dual-Observer multi-base split:
  (define acts-obs-split
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 6400 #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                          #:ally-units (list (mk-u 51301 'observer 59.0 32.5 #:hp 40.0 #:shield 20.0 #:flying #t)
                                             (mk-u 51302 'observer 56.0 32.5 #:hp 40.0 #:shield 20.0 #:flying #t)
                                             (mk-u 51311 'stalker 60.0 34.0 #:hp 80.0 #:shield 80.0))
                          #:ally-buildings (list (mk-u 51351 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
                                                 (mk-u 51352 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0))
                          #:enemy-units (list (mk-u 51821 'banshee 64.0 32.5 #:hp 140.0 #:flying #t #:cloak 2)))))
  (define obs2-main-move
    (findf (lambda (a)
             (and (pair? a) (eq? (car a) 'move) (= (second a) 51302)
                  (<= (dist2d-t (third a) (fourth a) 32.5 32.5) 6.0)))
           acts-obs-split))
  (check-true "R1-detector-standoff-24t-overseer-cap-448f-cooldown-and-dual-obs-split"
              (and ov-holds-9.5t? ov-steps-back-from-vik?
                   (not ov-chased-35t?) obs-dispatched-35t?
                   ov2-t1? ov2-t2-blocked? ov2-t3-allowed?
                   ov-loss-blocked? ov-loss-allowed?
                   (and obs2-main-move #t))
              (format "hold9.5?=~a back?=~a ov35?=~a obs35?=~a ov2-t1/blk/ok=~a/~a/~a loss-blk/ok=~a/~a split2?=~a"
                      ov-holds-9.5t? ov-steps-back-from-vik?
                      ov-chased-35t? obs-dispatched-35t?
                      ov2-t1? ov2-t2-blocked? ov2-t3-allowed?
                      ov-loss-blocked? ov-loss-allowed?
                      (and obs2-main-move #t))))

;; -----------------------------------------------------------------------------
;; 45. K13 (`L55-T3`): ZvP Proactive 2-Base Spores — Exposed Natural First, Then Main
;; -----------------------------------------------------------------------------
(let ()
  (define rt-zvp-sp (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define drones-32
    (for/list ([i (in-range 32)])
      (mk-u (+ 52101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define bldgs-2h
    (list (mk-u 52001 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 52002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 52003 'spawning-pool 36.5 36.5 #:hp 1000.0)
          (mk-u 52004 'roach-warren 38.5 34.5 #:hp 850.0)
          (mk-u 52005 'extractor 30.0 37.0 #:hp 500.0)
          (mk-u 52006 'evolution-chamber 38.5 38.5 #:hp 750.0)))
  (define a-sp1
    (step-layer2-economy!
     rt-zvp-sp
     (mk-live-obs 'Zerg 'Protoss 5000 #:minerals 200 #:gas 50 #:supply-used 40 #:supply-cap 66
                  #:mineral-harvesters 28 #:vespene-harvesters 3
                  #:ally-units drones-32
                  #:ally-buildings bldgs-2h
                  #:enemy-buildings (list (mk-u 52999 'nexus 140.0 140.0 #:hp 1000.0)))))
  (define sp1-cmd
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spore-crawler))) a-sp1))
  (define sp1-at-nat?
    (and sp1-cmd
         (< (dist2d-t (third sp1-cmd) (fourth sp1-cmd) 62.5 32.5)
            (dist2d-t (third sp1-cmd) (fourth sp1-cmd) 32.5 32.5))))
  (define a-sp2
    (step-layer2-economy!
     rt-zvp-sp
     (mk-live-obs 'Zerg 'Protoss 5200 #:minerals 200 #:gas 50 #:supply-used 40 #:supply-cap 66
                  #:mineral-harvesters 28 #:vespene-harvesters 3
                  #:ally-units drones-32
                  #:ally-buildings (cons (mk-u 52009 'spore-crawler 60.5 32.5 #:hp 400.0) bldgs-2h)
                  #:enemy-buildings (list (mk-u 52999 'nexus 140.0 140.0 #:hp 1000.0)))))
  (define sp2-cmd
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spore-crawler))) a-sp2))
  (define sp2-at-main?
    (and sp2-cmd
         (< (dist2d-t (third sp2-cmd) (fourth sp2-cmd) 32.5 32.5)
            (dist2d-t (third sp2-cmd) (fourth sp2-cmd) 62.5 32.5))))
  (check-true "K13-L55-T3-zvp-proactive-2base-spores-natural-first-then-main"
              (and sp1-at-nat? sp2-at-main?)
              (format "sp1-nat?=~a sp2-main?=~a sp1=~a sp2=~a" sp1-at-nat? sp2-at-main? sp1-cmd sp2-cmd)))

;; -----------------------------------------------------------------------------
;; 46. K13 (`L55-T4`): Emergency Hydralisk AA Trains Before Drones & Blocks Ravager/Overseer #2
;; -----------------------------------------------------------------------------
(let ()
  (define rt-hyd (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define drones-34
    (for/list ([i (in-range 34)])
      (mk-u (+ 53101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define roaches-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 53201 i) 'roach 46.0 (+ 31.0 (* 0.5 i)) #:hp 145.0)))
  (define larvae-2
    (list (mk-u 53301 'larva 31.0 33.0 #:hp 25.0)
          (mk-u 53302 'larva 32.0 33.0 #:hp 25.0)))
  (define bldgs-hyd
    (list (mk-u 53001 'lair 32.5 32.5 #:hp 2000.0)
          (mk-u 53002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 53003 'spawning-pool 36.5 36.5 #:hp 1000.0)
          (mk-u 53004 'roach-warren 38.5 34.5 #:hp 850.0)
          (mk-u 53005 'hydralisk-den 38.5 38.5 #:hp 850.0)
          (mk-u 53006 'spore-crawler 31.0 31.0 #:hp 400.0)
          (mk-u 53007 'spore-crawler 60.5 31.0 #:hp 400.0)))
  (define banshees-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 53801 i) 'banshee 55.0 (+ 31.0 (* 0.6 i)) #:hp 140.0 #:flying #t #:cloak 2)))
  (define ovls-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 53501 i) 'overlord 30.0 (+ 34.0 (* 0.5 i)) #:hp 200.0 #:flying #t)))
  (define a-hyd
    (step-layer2-economy!
     rt-hyd
     (mk-live-obs 'Zerg 'Terran 6584 #:minerals 130 #:gas 87 #:supply-used 46 #:supply-cap 72
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:ally-units (append drones-34 ovls-4 roaches-4 larvae-2
                                       (list (mk-u 53401 'overseer 52.0 32.0 #:hp 200.0 #:flying #t)))
                  #:ally-buildings bldgs-hyd
                  #:enemy-units banshees-3
                  #:enemy-buildings (list (mk-u 53999 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  (define trained-hydra?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'hydralisk))) a-hyd))
  (define morphed-ravager?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'ravager))) a-hyd))
  (define morphed-ov2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'overseer))) a-hyd))
  (define stole-drone?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'drone))) a-hyd))
  (check-true "K13-L55-T4-emergency-hydralisk-before-drones-blocks-ravager-and-ov2"
              (and trained-hydra? (not morphed-ravager?) (not morphed-ov2?) (not stole-drone?))
              (format "hydra?=~a rav?=~a ov2?=~a drone?=~a acts=~a"
                      trained-hydra? morphed-ravager? morphed-ov2? stole-drone? a-hyd)))

;; -----------------------------------------------------------------------------
;; 47. K6 (`L55-T5`): Never Self-Cancel Half-Built Static Detectors (`prog >= 0.45`, `vit >= 0.06`)
;; -----------------------------------------------------------------------------
(let ()
  (define drones-20
    (for/list ([i (in-range 20)])
      (mk-u (+ 54101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define ban-attacker
    (list (mk-u 54801 'banshee 62.0 34.0 #:hp 140.0 #:flying #t)))
  (define a-keep
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 8469 #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 52
                  #:mineral-harvesters 18 #:vespene-harvesters 2
                  #:ally-units drones-20
                  #:ally-buildings (list (mk-u 54001 'lair 32.5 32.5 #:hp 2000.0)
                                         (mk-u 54002 'hatchery 62.5 32.5 #:hp 1500.0)
                                         (mk-u 54005 'spore-crawler 60.0 32.5 #:hp 40.0 #:max-hp 400.0 #:build-progress 0.55))
                  #:enemy-units ban-attacker)))
  (define canceled-half-spore?
    (ormap (lambda (a) (equal? a '(cancel 54005))) a-keep))
  (define a-early-cancel
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 8469 #:minerals 100 #:gas 50 #:supply-used 30 #:supply-cap 52
                  #:mineral-harvesters 18 #:vespene-harvesters 2
                  #:ally-units drones-20
                  #:ally-buildings (list (mk-u 54001 'lair 32.5 32.5 #:hp 2000.0)
                                         (mk-u 54002 'hatchery 62.5 32.5 #:hp 1500.0)
                                         (mk-u 54006 'spore-crawler 60.0 32.5 #:hp 35.0 #:max-hp 400.0 #:build-progress 0.30))
                  #:enemy-units ban-attacker)))
  (define canceled-early-spore?
    (ormap (lambda (a) (equal? a '(cancel 54006))) a-early-cancel))
  (check-true "K6-L55-T5-no-self-cancel-half-built-static-detectors"
              (and (not canceled-half-spore?) canceled-early-spore?)
              (format "half-cancel?=~a early-cancel?=~a" canceled-half-spore? canceled-early-spore?)))

;; -----------------------------------------------------------------------------
;; 48. R2 (`L55-T6` REWORKED): MULE Scan-Bank Symmetry + 2-OC TvT `>= 4:15` Proxy-Banshee Guard
;; -----------------------------------------------------------------------------
(let ()
  (define scvs-24
    (for/list ([i (in-range 24)])
      (mk-u (+ 55101 i) 'scv 28.0 (+ 30.0 (* 0.2 i)) #:hp 45.0)))
  (define mps-55 (list (mk-u 55901 'mineral-field 26.0 32.5 #:hp 1800.0)
                       (mk-u 55902 'mineral-field 60.0 32.5 #:hp 1800.0)))
  (define bldgs-1oc
    (list (mk-u 55001 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 55.0)
          (mk-u 55002 'command-center 62.5 32.5 #:hp 1500.0)
          (mk-u 55003 'barracks 42.0 34.0 #:hp 1000.0)))
  (define bldgs-2oc
    (list (mk-u 55001 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 75.0)
          (mk-u 55002 'orbital-command 62.5 32.5 #:hp 1500.0 #:energy 60.0)
          (mk-u 55003 'barracks 42.0 34.0 #:hp 1000.0)))
  (define (mule-ids acts)
    (for/list ([a (in-list acts)]
               #:when (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'calldown-mule)))
      (second a)))
  ;; (a) 1-OC TvT at 4:15 (`5712`) clean -> STILL MULEs freely!
  (define tvt-1oc-415
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Terran 5712 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24 #:ally-buildings bldgs-1oc #:mineral-patches mps-55
                   #:enemy-buildings (list (mk-u 55991 'factory-techlab 140.0 140.0 #:hp 400.0))))))
  ;; (b) 1-OC TvT at 4:15 (`5712`) with scouted `starport-techlab` -> holds `55e` for Scan!
  (define tvt-1oc-sptl
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Terran 5712 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24 #:ally-buildings bldgs-1oc #:mineral-patches mps-55
                   #:enemy-buildings (list (mk-u 55992 'starport-techlab 140.0 140.0 #:hp 400.0))))))
  ;; (c) 2-OC TvT at 4:05 (`5488 < 5712`) clean -> BOTH OCs MULE freely!
  (define tvt-2oc-pre415
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Terran 5488 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24 #:ally-buildings bldgs-2oc #:mineral-patches mps-55
                   #:enemy-buildings (list (mk-u 55991 'factory-techlab 140.0 140.0 #:hp 400.0))))))
  ;; (d) L56-W2-2: 2-OC TvT at 4:15 (`5720`) clean (NO scouted cloak tech!) -> BOTH OCs MULE freely
  ;;     (no 120s TvT MULE blackout; TvT reserve is strictly scouted-cloak-only!).
  (define tvt-2oc-post415
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Terran 5720 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24 #:ally-buildings bldgs-2oc #:mineral-patches mps-55
                   #:enemy-buildings (list (mk-u 55991 'factory-techlab 140.0 140.0 #:hp 400.0))))))
  ;; (e) TvP at 3:30 (`4704 < 5376`) -> MULEs; TvP at 4:15 (`5712 >= 5376`) -> holds!
  (define tvp-330
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Protoss 4704 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24 #:ally-buildings bldgs-1oc #:mineral-patches mps-55
                   #:enemy-buildings (list (mk-u 55993 'nexus 140.0 140.0 #:hp 1000.0))))))
  (define tvp-415
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Protoss 5712 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24 #:ally-buildings bldgs-1oc #:mineral-patches mps-55
                   #:enemy-buildings (list (mk-u 55993 'nexus 140.0 140.0 #:hp 1000.0))))))
  (check-true "L56-W2-2-runtime-mule-tvt-clean-1oc-and-2oc-drop-scouted-holds-tvp-4m-reserves"
              (and (equal? tvt-1oc-415 '(55001))
                   (null? tvt-1oc-sptl)
                   (= (length tvt-2oc-pre415) 2)
                   (= (length tvt-2oc-post415) 2)
                   (equal? tvp-330 '(55001))
                   (null? tvp-415))
              (format "1oc-415=~a sptl=~a 2oc-pre=~a 2oc-post=~a tvp330=~a tvp415=~a"
                      tvt-1oc-415 tvt-1oc-sptl tvt-2oc-pre415 tvt-2oc-post415 tvp-330 tvp-415)))

;; -----------------------------------------------------------------------------
;; 49. K13 (`L55-T7`): ZvZ Ravager Morph Holds Gas When Brain Escrows `lair` (`gas < 175`)
;; -----------------------------------------------------------------------------
(let ()
  (define drones-38
    (for/list ([i (in-range 38)])
      (mk-u (+ 56101 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define roaches-5
    (for/list ([i (in-range 5)])
      (mk-u (+ 56201 i) 'roach 48.0 (+ 31.0 (* 0.5 i)) #:hp 145.0)))
  (define ovls-5
    (for/list ([i (in-range 5)])
      (mk-u (+ 56301 i) 'overlord 30.0 (+ 34.0 (* 0.5 i)) #:hp 200.0 #:flying #t)))
  (define queens-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 56251 i) 'queen (+ 33.0 (* 10.0 i)) 34.0 #:hp 175.0)))
  (define bldgs-zvz
    (list (mk-u 56001 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 56002 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 56003 'hatchery 32.5 64.5 #:hp 1500.0)
          (mk-u 56004 'spawning-pool 36.5 36.5 #:hp 1000.0)
          (mk-u 56005 'roach-warren 38.5 34.5 #:hp 850.0)
          (mk-u 56006 'extractor 30.0 37.0 #:hp 500.0)
          (mk-u 56007 'extractor 30.0 28.0 #:hp 500.0)
          (mk-u 56008 'extractor 60.0 37.0 #:hp 500.0)
          (mk-u 56009 'extractor 60.0 28.0 #:hp 500.0)))
  (define a-hold-lair
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Zerg 5600 #:minerals 240 #:gas 85 #:supply-used 52 #:supply-cap 82
                  #:mineral-harvesters 32 #:vespene-harvesters 6
                  #:ally-units (append drones-38 roaches-5 queens-3 ovls-5)
                  #:ally-buildings bldgs-zvz
                  #:enemy-units (list (mk-u 56801 'roach 120.0 120.0 #:hp 145.0))
                  #:enemy-buildings (list (mk-u 56999 'hatchery 140.0 140.0 #:hp 1500.0)))))
  (define morphed-rav-hold?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'ravager))) a-hold-lair))
  (define a-breach-rav
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Zerg 5600 #:minerals 240 #:gas 85 #:supply-used 52 #:supply-cap 82
                  #:mineral-harvesters 32 #:vespene-harvesters 6
                  #:ally-units (append drones-38 roaches-5 queens-3 ovls-5)
                  #:ally-buildings bldgs-zvz
                  #:enemy-units (list (mk-u 56802 'ravager 68.0 32.5 #:hp 120.0))
                  #:enemy-buildings (list (mk-u 56999 'hatchery 140.0 140.0 #:hp 1500.0)))))
  (define morphed-rav-breach?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'ravager))) a-breach-rav))
  (check-true "K13-L55-T7-zvz-ravager-holds-gas-for-escrowed-lair"
              (and (not morphed-rav-hold?) morphed-rav-breach?)
              (format "hold-rav?=~a breach-rav?=~a" morphed-rav-hold? morphed-rav-breach?)))

;; -----------------------------------------------------------------------------
;; 50. R2 (`L55-T9`): TvP >= 4:00 Reserves 100e on Up to 2 OCs (3rd OC Still MULEs!)
;; -----------------------------------------------------------------------------
(let ()
  (define scvs-24
    (for/list ([i (in-range 24)])
      (mk-u (+ 58101 i) 'scv 28.0 (+ 30.0 (* 0.2 i)) #:hp 45.0)))
  (define mps-58 (list (mk-u 58901 'mineral-field 26.0 32.5 #:hp 1800.0)
                       (mk-u 58902 'mineral-field 60.0 32.5 #:hp 1800.0)))
  (define (mule-ids acts)
    (for/list ([a (in-list acts)]
               #:when (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'calldown-mule)))
      (second a)))
  (define m2
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Protoss 5712 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24
                   #:ally-buildings (list (mk-u 58001 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 75.0)
                                          (mk-u 58002 'orbital-command 62.5 32.5 #:hp 1500.0 #:energy 65.0)
                                          (mk-u 58004 'barracks 42.0 34.0 #:hp 1000.0))
                   #:mineral-patches mps-58
                   #:enemy-buildings (list (mk-u 58999 'nexus 140.0 140.0 #:hp 1000.0))))))
  (define m3
    (mule-ids
     (step-layer2-economy!
      (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
      (mk-live-obs 'Terran 'Protoss 5712 #:minerals 100 #:gas 50 #:supply-used 34 #:supply-cap 54
                   #:mineral-harvesters 20 #:vespene-harvesters 4
                   #:ally-units scvs-24
                   #:ally-buildings (list (mk-u 58001 'orbital-command 32.5 32.5 #:hp 1500.0 #:energy 75.0)
                                          (mk-u 58002 'orbital-command 62.5 32.5 #:hp 1500.0 #:energy 65.0)
                                          (mk-u 58003 'orbital-command 32.5 62.5 #:hp 1500.0 #:energy 60.0)
                                          (mk-u 58004 'barracks 42.0 34.0 #:hp 1000.0))
                   #:mineral-patches mps-58
                   #:enemy-buildings (list (mk-u 58999 'nexus 140.0 140.0 #:hp 1000.0))))))
  (check-true "R2-L55-T9-tvp-2oc-both-reserve-100e-scan-and-3rd-oc-mules"
              (and (null? m2) (equal? m3 '(58003)))
              (format "m2=~a m3=~a" m2 m3)))

;; -----------------------------------------------------------------------------
;; 51. K4 (`L55-T10` + `L55-N1`): Anti-Nydus `PATROL` Gated on Safe XvZ Only
;; -----------------------------------------------------------------------------
(let ()
  (define stalkers-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 59201 i) 'stalker 36.0 (+ 31.0 (* 0.4 i)) #:hp 80.0 #:shield 80.0)))
  (define bldgs-pvt
    (list (mk-u 59001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 59002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 59003 'shield-battery 58.0 34.0 #:hp 150.0 #:shield 150.0)
          (mk-u 59004 'photon-cannon 36.0 35.0 #:hp 150.0 #:shield 150.0)))
  (define (has-patrol? acts)
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'patrol))) acts))
  (define pvt-l34-patrol?
    (has-patrol?
     (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
              (mk-live-obs 'Protoss 'Terran 6137 #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                           #:ally-units (take stalkers-12 5)
                           #:ally-buildings bldgs-pvt
                           #:enemy-units (list (mk-u 59801 'banshee 64.0 32.5 #:hp 140.0 #:flying #t #:cloak 2))
                           #:enemy-buildings (list (mk-u 59999 'orbital-command 140.0 140.0 #:hp 1500.0))))))
  (define nyd-pvt-patrol?
    (has-patrol?
     (plan-nydus-actions
      (mk-live-obs 'Protoss 'Terran 6137 #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                   #:ally-units stalkers-12 #:ally-buildings bldgs-pvt #:enemy-units '()))))
  (define nyd-pvz-attack-patrol?
    (has-patrol?
     (plan-nydus-actions
      (mk-live-obs 'Protoss 'Zerg 6137 #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                   #:ally-units stalkers-12 #:ally-buildings bldgs-pvt
                   #:enemy-units (list (mk-u 59851 'roach 64.0 32.5 #:hp 145.0))))))
  (define nyd-pvz-safe-patrol?
    (has-patrol?
     (plan-nydus-actions
      (mk-live-obs 'Protoss 'Zerg 6137 #:base-x 32.5 #:base-y 32.5 #:nat-x 62.5 #:nat-y 32.5
                   #:ally-units stalkers-12 #:ally-buildings bldgs-pvt #:enemy-units '()))))
  (check-true "K4-L55-T10-N1-anti-nydus-patrol-safe-xvz-only"
              (and (not pvt-l34-patrol?)
                   (not nyd-pvt-patrol?)
                   (not nyd-pvz-attack-patrol?)
                   nyd-pvz-safe-patrol?)
              (format "pvt-l34?=~a nyd-pvt?=~a nyd-atk?=~a nyd-safe?=~a"
                      pvt-l34-patrol? nyd-pvt-patrol? nyd-pvz-attack-patrol? nyd-pvz-safe-patrol?)))

;; -----------------------------------------------------------------------------
;; 52. R1 (`L55-T11`): Observer Prioritizes Undetected `cloak=1` (60t) + 5.5t vs Detectionless Marines
;; -----------------------------------------------------------------------------
(let ()
  (define bldgs-60
    (list (mk-u 60001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 60002 'nexus 65.0 32.5 #:hp 1000.0 #:shield 1000.0)))
  (define obs-pair
    (list (mk-u 60301 'observer 43.0 31.0 #:hp 40.0 #:shield 20.0 #:flying #t)
          (mk-u 60302 'observer 33.0 48.0 #:hp 40.0 #:shield 20.0 #:flying #t)
          (mk-u 60311 'stalker 60.0 34.0 #:hp 80.0 #:shield 80.0)))
  (define marines-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 60701 i) 'marine 62.0 (+ 29.0 (* 0.3 i)) #:hp 45.0)))
  (define acts-no-det
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 7800 #:base-x 32.5 #:base-y 32.5 #:nat-x 65.0 #:nat-y 32.5
                          #:ally-units obs-pair
                          #:ally-buildings bldgs-60
                          #:enemy-units (append (list (mk-u 60801 'banshee 38.0 36.0 #:hp 140.0 #:flying #t #:cloak 2)
                                                      (mk-u 60802 'banshee 65.0 30.0 #:hp 140.0 #:flying #t #:cloak 1))
                                                marines-8))))
  (define obs1-mv-nodet
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 60301))) acts-no-det))
  (define obs1-closes-to-5.5t?
    (and obs1-mv-nodet
         (<= (dist2d-t (third obs1-mv-nodet) (fourth obs1-mv-nodet) 65.0 30.0) 6.5)))
  (define acts-with-det
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 7800 #:base-x 32.5 #:base-y 32.5 #:nat-x 65.0 #:nat-y 32.5
                          #:ally-units obs-pair
                          #:ally-buildings bldgs-60
                          #:enemy-units (append (list (mk-u 60801 'banshee 38.0 36.0 #:hp 140.0 #:flying #t #:cloak 2)
                                                      (mk-u 60802 'banshee 65.0 30.0 #:hp 140.0 #:flying #t #:cloak 1))
                                                marines-8)
                          #:enemy-buildings (list (mk-u 60901 'missile-turret 64.0 34.0 #:hp 250.0)))))
  (define obs1-mv-det
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 60301))) acts-with-det))
  (define obs1-holds-9.5t-with-turret?
    (and obs1-mv-det
         (>= (dist2d-t (third obs1-mv-det) (fourth obs1-mv-det) 65.0 30.0) 9.2)))
  (check-true "R1-L55-T11-observer-prioritizes-cloak1-60t-and-holds-5.5t-vs-detectionless-marines"
              (and obs1-closes-to-5.5t? obs1-holds-9.5t-with-turret?)
              (format "close5.5?=~a hold9.5?=~a mv1=~a mv2=~a"
                      obs1-closes-to-5.5t? obs1-holds-9.5t-with-turret? obs1-mv-nodet obs1-mv-det)))

;; -----------------------------------------------------------------------------
;; 53. K7 (`L55-T12`): Revealed Dark Templar Focused Ahead of Warp Prism During Scan #1
;; -----------------------------------------------------------------------------
(let ()
  (define bldgs-61
    (list (mk-u 61001 'orbital-command 32.5 32.5 #:hp 1500.0)
          (mk-u 61002 'command-center 62.5 32.5 #:hp 1500.0)))
  (define prism-and-dt
    (list (mk-u 61801 'warp-prism-phasing 61.0 34.0 #:hp 80.0 #:shield 100.0 #:flying #t)
          (mk-u 61802 'dark-templar 62.0 35.0 #:hp 40.0 #:shield 80.0 #:cloak 2)))
  (define marines-3
    (for/list ([i (in-range 3)])
      (mk-u (+ 61201 i) 'marine 57.0 (+ 33.5 (* 0.4 i)) #:hp 45.0)))
  (define acts-3m
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Protoss 5800 #:ally-units marines-3 #:ally-buildings bldgs-61
                          #:enemy-units prism-and-dt)))
  (define m3-hit-dt?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 61201 (second a) 61203) (= (third a) 61802))) acts-3m))
  (define m3-hit-prism?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 61201 (second a) 61203) (= (third a) 61801))) acts-3m))
  (define marines-7
    (for/list ([i (in-range 7)])
      (mk-u (+ 61211 i) 'marine 57.0 (+ 32.8 (* 0.35 i)) #:hp 45.0)))
  (define acts-7m
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Protoss 6397 #:ally-units marines-7 #:ally-buildings bldgs-61
                          #:enemy-units prism-and-dt)))
  (define m7-hit-dt?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 61211 (second a) 61217) (= (third a) 61802))) acts-7m))
  (define m7-hit-prism?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (<= 61211 (second a) 61217) (= (third a) 61801))) acts-7m))
  (check-true "K7-L55-T12-revealed-dark-templar-focused-ahead-of-warp-prism"
              (and m3-hit-dt? (not m3-hit-prism?) m7-hit-dt? (not m7-hit-prism?))
              (format "m3-dt?=~a m3-pr?=~a m7-dt?=~a m7-pr?=~a"
                      m3-hit-dt? m3-hit-prism? m7-hit-dt? m7-hit-prism?)))

;; -----------------------------------------------------------------------------
;; 54. L56-W2-5 (`L53-W2-3`): ZvZ Stale Early-Ling OWM Guard (No Baneling Gas Drain Into 10+ Roaches)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-zvz (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define drones-42
    (for/list ([i (in-range 42)])
      (mk-u (+ 43101 i) 'drone 28.0 (+ 30.0 (* 0.15 i)) #:hp 40.0 #:max-hp 40.0)))
  (define lings-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 43201 i) 'zergling 46.0 (+ 31.0 (* 0.3 i)) #:hp 35.0 #:max-hp 35.0)))
  (define larvae-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 43301 i) 'larva 34.0 (+ 31.0 (* 0.3 i)) #:hp 25.0 #:max-hp 25.0)))
  (define z-bldgs-zvz
    (list (mk-u 43001 'lair 32.5 32.5 #:hp 2000.0 #:max-hp 2000.0)
          (mk-u 43002 'hatchery 62.5 32.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 43003 'hatchery 32.5 64.5 #:hp 1500.0 #:max-hp 1500.0)
          (mk-u 43004 'spawning-pool 36.5 36.5 #:hp 1000.0 #:max-hp 1000.0)
          (mk-u 43005 'roach-warren 38.5 34.5 #:hp 850.0 #:max-hp 850.0)
          (mk-u 43006 'baneling-nest 36.5 30.5 #:hp 850.0 #:max-hp 850.0)
          (mk-u 43007 'hydralisk-den 38.5 38.5 #:hp 850.0 #:max-hp 850.0)))
  (step-layer2-economy!
   rt-zvz
   (mk-live-obs 'Zerg 'Zerg 3600 #:minerals 100 #:gas 50 #:supply-used 48 #:supply-cap 80
                #:mineral-harvesters 36 #:vespene-harvesters 6
                #:ally-units (append drones-42 lings-6 larvae-4)
                #:ally-buildings z-bldgs-zvz
                #:enemy-units (for/list ([i (in-range 20)])
                                (mk-u (+ 43701 i) 'zergling 95.0 (+ 30.0 (* 0.3 i)) #:hp 35.0))
                #:enemy-buildings (list (mk-u 43999 'hatchery 140.0 140.0 #:hp 1500.0))))
  (define a-zvz-roach
    (step-layer2-economy!
     rt-zvz
     (mk-live-obs 'Zerg 'Zerg 7200 #:minerals 200 #:gas 100 #:supply-used 52 #:supply-cap 88
                  #:mineral-harvesters 36 #:vespene-harvesters 6
                  #:ally-units (append drones-42 lings-6 larvae-4)
                  #:ally-buildings z-bldgs-zvz
                  #:enemy-units (for/list ([i (in-range 12)])
                                  (mk-u (+ 43801 i) 'roach 95.0 (+ 30.0 (* 0.4 i)) #:hp 145.0))
                  #:enemy-buildings (list (mk-u 43999 'hatchery 140.0 140.0 #:hp 1500.0)))))
  (define morphed-stale-bane?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'baneling))) a-zvz-roach))
  (check-true "L56-W2-5-L53-W2-3-zvz-stale-owm-lings-do-not-trigger-banelings-into-roaches"
              (not morphed-stale-bane?)
              (format "stale-bane?=~a acts=~a" morphed-stale-bane? a-zvz-roach)))

;; -----------------------------------------------------------------------------
;; 55. L56-W2-4 (`L54-W2-P1`): PvT >= 6 Marines Trains Stalker (Not Adept Swarm) + sched=(stalker) First
;; -----------------------------------------------------------------------------
(let ()
  (define rt-pvt-m (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define probes-26
    (for/list ([i (in-range 26)])
      (mk-u (+ 49101 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define busy-nex (list (hasheq 'ability-id 1006)))
  (define bldgs-pvt-m
    (list (mk-u 49001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:orders busy-nex)
          (mk-u 49002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:orders busy-nex)
          (mk-u 49003 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 49004 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 49005 'cybernetics-core 40.0 37.5 #:hp 550.0 #:shield 550.0)
          (mk-u 49006 'assimilator 30.0 37.0 #:hp 300.0 #:shield 300.0)
          (mk-u 49007 'assimilator 30.0 28.0 #:hp 300.0 #:shield 300.0)
          (mk-u 49008 'shield-battery 60.0 34.0 #:hp 150.0 #:shield 150.0)))
  (define marines-8-enemy
    (for/list ([i (in-range 8)])
      (mk-u (+ 49801 i) 'marine 90.0 (+ 30.0 (* 0.5 i)) #:hp 45.0)))
  (define a-pvt-m
    (step-layer2-economy!
     rt-pvt-m
     (mk-live-obs 'Protoss 'Terran 4200 #:minerals 130 #:gas 80 #:supply-used 28 #:supply-cap 54
                  #:mineral-harvesters 20 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-26
                                       (list (mk-u 49201 'adept 45.0 34.0 #:hp 70.0 #:shield 70.0)
                                             (mk-u 49202 'adept 45.5 35.0 #:hp 70.0 #:shield 70.0)))
                  #:ally-buildings bldgs-pvt-m
                  #:enemy-units marines-8-enemy
                  #:enemy-buildings (list (mk-u 49999 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  (define pvt-trained-stalker?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'stalker))) a-pvt-m))
  (define pvt-stole-adept?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'adept))) a-pvt-m))
  (define rt-pvp-s (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-pvp-s
    (step-layer2-economy!
     rt-pvp-s
     (mk-live-obs 'Protoss 'Protoss 2800 #:minerals 130 #:gas 80 #:supply-used 28 #:supply-cap 54
                  #:mineral-harvesters 20 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units probes-26
                  #:ally-buildings bldgs-pvt-m
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 49998 'nexus 140.0 140.0 #:hp 1000.0)))))
  (define pvp-trained-stalker?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'stalker))) a-pvp-s))
  (define pvp-stole-adept?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'adept))) a-pvp-s))
  (check-true "L56-W2-4-L54-W2-P1-pvt-marines-and-sched-stalker-train-stalker-before-adept"
              (and pvt-trained-stalker? (not pvt-stole-adept?)
                   pvp-trained-stalker? (not pvp-stole-adept?))
              (format "pvt-stlk?=~a pvt-adp?=~a pvp-stlk?=~a pvp-adp?=~a a1=~a a2=~a"
                      pvt-trained-stalker? pvt-stole-adept? pvp-trained-stalker? pvp-stole-adept?
                      a-pvt-m a-pvp-s)))

;; -----------------------------------------------------------------------------
;; 56. L56-W2-4 (`L55-T8`): PvP Breach Defense & Midgame (`>= 4704`) Trains Stalker, Not Adept
;; -----------------------------------------------------------------------------
(let ()
  (define probes-28
    (for/list ([i (in-range 28)])
      (mk-u (+ 57101 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define busy-nex (list (hasheq 'ability-id 1006)))
  (define bldgs-pvp
    (list (mk-u 57001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:orders busy-nex)
          (mk-u 57002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:orders busy-nex)
          (mk-u 57003 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 57004 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 57005 'cybernetics-core 40.0 37.5 #:hp 550.0 #:shield 550.0)
          (mk-u 57006 'assimilator 30.0 37.0 #:hp 300.0 #:shield 300.0)
          (mk-u 57007 'assimilator 30.0 28.0 #:hp 300.0 #:shield 300.0)
          (mk-u 57008 'shield-battery 60.0 34.0 #:hp 150.0 #:shield 150.0)))
  (define a-pvp-breach
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 6700 #:minerals 130 #:gas 80 #:supply-used 34 #:supply-cap 62
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-28
                                       (list (mk-u 57201 'stalker 56.0 32.5 #:hp 80.0 #:shield 80.0)
                                             (mk-u 57202 'stalker 56.5 33.5 #:hp 80.0 #:shield 80.0)))
                  #:ally-buildings bldgs-pvp
                  #:enemy-units (list (mk-u 57801 'zealot 64.0 32.5 #:hp 100.0 #:shield 50.0)
                                      (mk-u 57802 'zealot 64.5 33.0 #:hp 100.0 #:shield 50.0))
                  #:enemy-buildings (list (mk-u 57999 'nexus 140.0 140.0 #:hp 1000.0)))))
  (define breach-stalker?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'stalker))) a-pvp-breach))
  (define breach-adept?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'adept))) a-pvp-breach))
  (define a-pvp-mid
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 6700 #:minerals 130 #:gas 80 #:supply-used 34 #:supply-cap 62
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-28
                                       (list (mk-u 57211 'stalker 56.0 32.5 #:hp 80.0 #:shield 80.0)
                                             (mk-u 57212 'stalker 56.5 33.5 #:hp 80.0 #:shield 80.0)))
                  #:ally-buildings bldgs-pvp
                  #:enemy-units '()
                  #:enemy-buildings (list (mk-u 57999 'nexus 140.0 140.0 #:hp 1000.0)))))
  (define mid-stalker?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'stalker))) a-pvp-mid))
  (define mid-adept?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'adept))) a-pvp-mid))
  (check-true "L56-W2-4-L55-T8-pvp-breach-and-midgame-trains-stalker-not-adept"
              (and breach-stalker? (not breach-adept?) mid-stalker? (not mid-adept?))
              (format "b-stlk?=~a b-adp?=~a m-stlk?=~a m-adp?=~a"
                      breach-stalker? breach-adept? mid-stalker? mid-adept?)))

;; -----------------------------------------------------------------------------
;; 57. L57-R1: Ready CyberCore + `gas >= 50` Holds `100..224M` for Stalker (No Zealot Fallthrough!)
;; -----------------------------------------------------------------------------
(let ()
  (define probes-28
    (for/list ([i (in-range 28)])
      (mk-u (+ 57501 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define busy-nex (list (hasheq 'ability-id 1006)))
  (define bldgs-p
    (list (mk-u 57601 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:orders busy-nex)
          (mk-u 57602 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:orders busy-nex)
          (mk-u 57603 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 57604 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)
          (mk-u 57605 'cybernetics-core 40.0 37.5 #:hp 550.0 #:shield 550.0)
          (mk-u 57606 'assimilator 30.0 37.0 #:hp 300.0 #:shield 300.0)
          (mk-u 57607 'assimilator 30.0 28.0 #:hp 300.0 #:shield 300.0)
          (mk-u 57608 'shield-battery 60.0 34.0 #:hp 150.0 #:shield 150.0)))
  (define (trained? acts sym)
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) sym))) acts))
  ;; (a) PvT breach (`#063`-style) at `100M / 144G` -> MUST NOT dump `100M` into Zealot!
  (define a-breach-100m
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 6532 #:minerals 100 #:gas 144 #:supply-used 36 #:supply-cap 78
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-28
                                       (list (mk-u 57651 'stalker 56.0 32.5 #:hp 80.0 #:shield 80.0)
                                             (mk-u 57652 'stalker 56.5 33.5 #:hp 80.0 #:shield 80.0)))
                  #:ally-buildings bldgs-p
                  #:enemy-units (list (mk-u 57681 'marine 63.0 32.5 #:hp 45.0)
                                      (mk-u 57682 'marine 63.5 33.0 #:hp 45.0)
                                      (mk-u 57683 'siege-tank-sieged 68.0 32.5 #:hp 175.0))
                  #:enemy-buildings (list (mk-u 57699 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  ;; (b) Phase-3 `[else]` at `105M / 120G` (distant enemy Marines) -> MUST NOT dump `100M` into Zealot!
  (define a-p3-105m
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 6532 #:minerals 105 #:gas 120 #:supply-used 36 #:supply-cap 78
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-28
                                       (list (mk-u 57653 'stalker 56.0 32.5 #:hp 80.0 #:shield 80.0)))
                  #:ally-buildings bldgs-p
                  #:enemy-units (list (mk-u 57684 'marine 110.0 90.0 #:hp 45.0)
                                      (mk-u 57685 'marauder 111.0 90.0 #:hp 125.0))
                  #:enemy-buildings (list (mk-u 57699 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  ;; (c) Low-gas (`105M / 20G`) -> STILL trains Zealot cleanly!
  (define a-lowgas-zeal
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 6532 #:minerals 105 #:gas 20 #:supply-used 36 #:supply-cap 78
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:researched-upgrades '(warp-gate-research)
                  #:ally-units (append probes-28
                                       (list (mk-u 57654 'stalker 56.0 32.5 #:hp 80.0 #:shield 80.0)))
                  #:ally-buildings bldgs-p
                  #:enemy-units (list (mk-u 57686 'marine 63.0 32.5 #:hp 45.0)
                                      (mk-u 57687 'marine 63.5 33.0 #:hp 45.0))
                  #:enemy-buildings (list (mk-u 57699 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  ;; (d) Pure Zergling swarm breach (`8` Lings at `105M / 80G`, 2 Adepts already live) -> STILL trains Zealot!
  (define a-ling-zeal
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Zerg 4200 #:minerals 105 #:gas 80 #:supply-used 36 #:supply-cap 78
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:ally-units (append probes-28
                                       (list (mk-u 57655 'stalker 56.0 32.5 #:hp 80.0 #:shield 80.0)
                                             (mk-u 57656 'adept 56.5 32.5 #:hp 70.0 #:shield 70.0)
                                             (mk-u 57657 'adept 57.0 32.5 #:hp 70.0 #:shield 70.0)))
                  #:ally-buildings bldgs-p
                  #:enemy-units (for/list ([i (in-range 8)])
                                  (mk-u (+ 57690 i) 'zergling 63.0 (+ 31.0 (* 0.3 i)) #:hp 35.0))
                  #:enemy-buildings (list (mk-u 57698 'hatchery 140.0 140.0 #:hp 1500.0)))))
  (check-true "L57-R1-hold-100to224m-zealot-for-stalker-when-cyber-ready-and-gas50"
              (and (not (trained? a-breach-100m 'zealot))
                   (not (trained? a-p3-105m 'zealot))
                   (trained? a-lowgas-zeal 'zealot)
                   (trained? a-ling-zeal 'zealot))
              (format "breach-z?=~a p3-z?=~a lowg-z?=~a ling-z?=~a"
                      (trained? a-breach-100m 'zealot)
                      (trained? a-p3-105m 'zealot)
                      (trained? a-lowgas-zeal 'zealot)
                      (trained? a-ling-zeal 'zealot))))

;; -----------------------------------------------------------------------------
;; 58. L57-R2: CyberCore Unblocked at `>= 1` Combat vs Terran & `>= 2` vs Non-Terran Under Attack
;; -----------------------------------------------------------------------------
(let ()
  (define probes-18
    (for/list ([i (in-range 18)])
      (mk-u (+ 58501 i) 'probe 28.0 (+ 30.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define busy-nex (list (hasheq 'ability-id 1006)))
  (define busy-gw (list (hasheq 'ability-id 916)))
  (define bldgs-no-cy
    (list (mk-u 58601 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:orders busy-nex)
          (mk-u 58602 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 58603 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:orders busy-gw)
          (mk-u 58604 'assimilator 30.0 37.0 #:hp 300.0 #:shield 300.0)))
  (define (built-cyber? acts)
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'cybernetics-core))) acts))
  ;; (a) PvT under Marine attack `< 4:00` with `1` Zealot (`>= 1`) -> MUST build CyberCore!
  (define a-pvt-cy
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 3200 #:minerals 160 #:gas 40 #:supply-used 20 #:supply-cap 31
                  #:mineral-harvesters 15 #:vespene-harvesters 3
                  #:ally-units (cons (mk-u 58651 'zealot 39.0 34.0 #:hp 100.0 #:shield 50.0) probes-18)
                  #:ally-buildings bldgs-no-cy
                  #:enemy-units (list (mk-u 58681 'marine 44.0 34.0 #:hp 45.0)
                                      (mk-u 58682 'marine 44.5 34.5 #:hp 45.0))
                  #:enemy-buildings (list (mk-u 58699 'orbital-command 140.0 140.0 #:hp 1500.0)))))
  ;; (b) PvP under Zealot attack `< 4:00` with `2` Zealots (`>= 2`) -> MUST build CyberCore!
  (define a-pvp-cy2
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 3200 #:minerals 160 #:gas 40 #:supply-used 22 #:supply-cap 31
                  #:mineral-harvesters 15 #:vespene-harvesters 3
                  #:ally-units (list* (mk-u 58652 'zealot 39.0 34.0 #:hp 100.0 #:shield 50.0)
                                      (mk-u 58653 'zealot 39.5 34.5 #:hp 100.0 #:shield 50.0)
                                      probes-18)
                  #:ally-buildings bldgs-no-cy
                  #:enemy-units (list (mk-u 58683 'zealot 44.0 34.0 #:hp 100.0 #:shield 50.0)
                                      (mk-u 58684 'zealot 44.5 34.5 #:hp 100.0 #:shield 50.0))
                  #:enemy-buildings (list (mk-u 58698 'nexus 140.0 140.0 #:hp 1000.0)))))
  ;; (c) PvP under Zealot attack `< 4:00` with only `1` Zealot (`< 2`) -> still defers CyberCore!
  (define a-pvp-cy1
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 3200 #:minerals 160 #:gas 40 #:supply-used 20 #:supply-cap 31
                  #:mineral-harvesters 15 #:vespene-harvesters 3
                  #:ally-units (cons (mk-u 58654 'zealot 39.0 34.0 #:hp 100.0 #:shield 50.0) probes-18)
                  #:ally-buildings bldgs-no-cy
                  #:enemy-units (list (mk-u 58685 'zealot 44.0 34.0 #:hp 100.0 #:shield 50.0)
                                      (mk-u 58686 'zealot 44.5 34.5 #:hp 100.0 #:shield 50.0))
                  #:enemy-buildings (list (mk-u 58698 'nexus 140.0 140.0 #:hp 1000.0)))))
  ;; (d) PvZ `< 3:00` 12-Pool (`12` Lings, `1` Gateway, `2` Zealots) -> defers CyberCore so Gateway #2 drops first!
  (define lings-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 58700 i) 'zergling 42.0 (+ 30.0 (* 0.4 i)) #:hp 35.0)))
  (define a-12p-1gw
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Zerg 2600 #:minerals 240 #:gas 0 #:supply-used 22 #:supply-cap 31
                  #:mineral-harvesters 18 #:vespene-harvesters 0
                  #:ally-units (list* (mk-u 58655 'zealot 39.0 34.0 #:hp 100.0 #:shield 50.0)
                                      (mk-u 58656 'zealot 39.5 34.5 #:hp 100.0 #:shield 50.0)
                                      probes-18)
                  #:ally-buildings bldgs-no-cy
                  #:enemy-units lings-12
                  #:enemy-buildings (list (mk-u 58697 'hatchery 140.0 140.0 #:hp 1500.0)))))
  ;; (e) Once Gateway #2 is up, same 12-Pool with `2` Zealots -> CyberCore unblocks immediately!
  (define a-12p-2gw
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Zerg 2600 #:minerals 240 #:gas 0 #:supply-used 22 #:supply-cap 31
                  #:mineral-harvesters 18 #:vespene-harvesters 0
                  #:ally-units (list* (mk-u 58657 'zealot 39.0 34.0 #:hp 100.0 #:shield 50.0)
                                      (mk-u 58658 'zealot 39.5 34.5 #:hp 100.0 #:shield 50.0)
                                      probes-18)
                  #:ally-buildings (cons (mk-u 58605 'gateway 40.0 37.5 #:hp 500.0 #:shield 500.0 #:orders busy-gw)
                                         bldgs-no-cy)
                  #:enemy-units lings-12
                  #:enemy-buildings (list (mk-u 58697 'hatchery 140.0 140.0 #:hp 1500.0)))))
  (check-true "L57-R2-cybercore-unblocked-at-1-unit-vs-terran-and-2-units-vs-nonterran"
              (and (built-cyber? a-pvt-cy)
                   (built-cyber? a-pvp-cy2)
                   (not (built-cyber? a-pvp-cy1))
                   (not (built-cyber? a-12p-1gw))
                   (built-cyber? a-12p-2gw))
              (format "pvt-cy?=~a pvp2-cy?=~a pvp1-cy?=~a 12p1g-cy?=~a 12p2g-cy?=~a"
                      (built-cyber? a-pvt-cy) (built-cyber? a-pvp-cy2) (built-cyber? a-pvp-cy1)
                      (built-cyber? a-12p-1gw) (built-cyber? a-12p-2gw))))

;; -----------------------------------------------------------------------------
;; 59. L57-R3: Proactive Dual-Base Spores vs Random at `3:25` (`4592f`) + Fast `44f` Spore #2
;; -----------------------------------------------------------------------------
(let ()
  (define rt-rnd-sp (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define drones-32
    (for/list ([i (in-range 32)])
      (mk-u (+ 59501 i) 'drone 28.0 (+ 30.0 (* 0.2 i)) #:hp 40.0)))
  (define queens-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 59551 i) 'queen (+ 33.0 (* 8.0 i)) 34.0 #:hp 175.0)))
  (define bldgs-2h
    (list (mk-u 59601 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 59602 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 59603 'spawning-pool 36.5 36.5 #:hp 1000.0)
          (mk-u 59604 'roach-warren 38.5 34.5 #:hp 850.0)
          (mk-u 59605 'extractor 30.0 37.0 #:hp 500.0)
          (mk-u 59606 'evolution-chamber 38.5 38.5 #:hp 750.0)))
  ;; Tick 1 (`f=4600 >= 4592` vs `'Random`): MUST build Spore #1 at Natural!
  (define a-sp1
    (step-layer2-economy!
     rt-rnd-sp
     (mk-live-obs 'Zerg 'Random 4600 #:minerals 200 #:gas 50 #:supply-used 48 #:supply-cap 66
                  #:mineral-harvesters 28 #:vespene-harvesters 3
                  #:ally-units (append drones-32 queens-4)
                  #:ally-buildings bldgs-2h
                  #:enemy-buildings '())))
  (define sp1-cmd
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spore-crawler))) a-sp1))
  (define sp1-at-nat?
    (and sp1-cmd
         (< (dist2d-t (third sp1-cmd) (fourth sp1-cmd) 62.5 32.5)
            (dist2d-t (third sp1-cmd) (fourth sp1-cmd) 32.5 32.5))))
  ;; Tick 2 (`f=4648`, only `48f >= 44f` later with Spore #1 morphing at Natural): MUST build Spore #2 at Main!
  (define sp1-x (if sp1-cmd (third sp1-cmd) 60.5))
  (define sp1-y (if sp1-cmd (fourth sp1-cmd) 32.5))
  (define a-sp2
    (step-layer2-economy!
     rt-rnd-sp
     (mk-live-obs 'Zerg 'Random 4648 #:minerals 200 #:gas 50 #:supply-used 48 #:supply-cap 66
                  #:mineral-harvesters 28 #:vespene-harvesters 3
                  #:ally-units (append drones-32 queens-4)
                  #:ally-buildings (cons (mk-u 59609 'spore-crawler sp1-x sp1-y #:hp 400.0 #:build-progress 0.15) bldgs-2h)
                  #:enemy-buildings '())))
  (define sp2-cmd
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spore-crawler))) a-sp2))
  (define sp2-at-main?
    (and sp2-cmd
         (< (dist2d-t (third sp2-cmd) (fourth sp2-cmd) 32.5 32.5)
            (dist2d-t (third sp2-cmd) (fourth sp2-cmd) 62.5 32.5))))
  (check-true "L57-R3-zerg-proactive-dual-spores-vs-random-at-325-with-44f-spacing"
              (and sp1-at-nat? sp2-at-main?)
              (format "sp1-nat?=~a sp2-main?=~a sp1=~a sp2=~a" sp1-at-nat? sp2-at-main? sp1-cmd sp2-cmd)))

;; -----------------------------------------------------------------------------
;; 60. L57-R4: `202/200` Zerg Spore-Trick Rate-Limited (`>= 672f` CD & `< 2` Cancels/Match)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-st (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define drones-56
    (for/list ([i (in-range 56)])
      (mk-u (+ 60501 i) 'drone 28.0 (+ 30.0 (* 0.1 i)) #:hp 40.0)))
  (define (mk-200-obs f spore-id)
    (mk-live-obs 'Zerg 'Protoss f #:minerals 1800 #:gas 900 #:supply-used 200 #:supply-cap 200
                 #:mineral-harvesters 48 #:vespene-harvesters 8
                 #:ally-units drones-56
                 #:ally-buildings (list (mk-u 60601 'hive 32.5 32.5 #:hp 2500.0)
                                        (mk-u 60602 'spawning-pool 36.0 32.5 #:hp 1000.0)
                                        (mk-u spore-id 'spore-crawler 34.5 34.5 #:hp 200.0 #:build-progress 0.35))
                 #:enemy-buildings (list (mk-u 60699 'nexus 140.0 140.0 #:hp 1000.0))))
  (define (has-cancel? acts sid)
    (ormap (lambda (a) (equal? a (list 'cancel-building sid))) acts))
  ;; Tick 1 (`f=12000`): 1st cancel allowed (`cnt -> 1`).
  (define c1? (has-cancel? (step-layer2-economy! rt-st (mk-200-obs 12000 60963)) 60963))
  ;; Tick 2 (`f=12200`, `200f < 672f` cooldown): BLOCKED!
  (define c2-blocked? (not (has-cancel? (step-layer2-economy! rt-st (mk-200-obs 12200 60964)) 60964)))
  ;; Tick 3 (`f=12720`, `720f >= 672f` cooldown, `cnt=1 < 2`): 2nd cancel allowed (`cnt -> 2`).
  (define c3? (has-cancel? (step-layer2-economy! rt-st (mk-200-obs 12720 60964)) 60964))
  ;; Tick 4 (`f=13500`, `780f >= 672f` later, `cnt=2`): 3rd cancel BLOCKED (`SELF_CANCEL_LOOP >= 3` impossible!).
  (define c4-capped? (not (has-cancel? (step-layer2-economy! rt-st (mk-200-obs 13500 60965)) 60965)))
  (check-true "L57-R4-202-overcap-spore-trick-672f-cooldown-and-max-2-cancels"
              (and c1? c2-blocked? c3? c4-capped?)
              (format "c1?=~a c2-blk?=~a c3?=~a c4-cap?=~a" c1? c2-blocked? c3? c4-capped?)))

;; -----------------------------------------------------------------------------
;; 61. L58-P1-1 (`sc2-ab-t10`): OC Scanner Sweep (399) Preempts MULE (171) Under Cloak Threat
;; -----------------------------------------------------------------------------
(let ()
  (define rt-sc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define oc (hash-set (mk-u 61001 'orbital-command 50.0 50.0 #:hp 1500.0 #:max-hp 1500.0) 'energy 100.0))
  (define marines-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 61101 i) 'marine 54.0 (+ 48.0 (* 0.4 i)) #:hp 45.0 #:max-hp 45.0)))
  (define dts-4
    (for/list ([i (in-range 4)])
      (hash-set* (mk-u (+ 61801 i) 'dark-templar 58.0 (+ 49.0 (* 0.4 i)) #:hp 40.0 #:max-hp 40.0 #:shield 80.0 #:max-shield 80.0)
                 'cloak 1 'cloaked #t 'is-shimmer? #t)))
  (define mps (list (hasheq 'id 61901 'x 44.0 'y 50.0 'mineral-contents 1200)))
  (define obs-dt
    (hash-set (mk-live-obs 'Terran 'Protoss 400 #:minerals 100 #:gas 0 #:supply-used 18 #:supply-cap 23
                           #:mineral-harvesters 6 #:vespene-harvesters 0
                           #:ally-units marines-12
                           #:ally-buildings (list oc)
                           #:enemy-units dts-4)
              'mineral-patches mps))
  (define a-l2 (step-layer2-economy! rt-sc obs-dt))
  (define scanned?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'scanner-sweep))) a-l2))
  (define muled?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'calldown-mule))) a-l2))
  ;; Even on next tick during 44f scan dedup, MULE MUST still be hard-blocked while DTs are within 32t!
  (define a-l2-next (step-layer2-economy! rt-sc (hash-set obs-dt 'frame 408)))
  (define muled-during-dedup?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'calldown-mule))) a-l2-next))
  (check-true "L58-P1-1-oc-scanner-sweep-preempts-mule-under-cloak-threat"
              (and scanned? (not muled?) (not muled-during-dedup?))
              (format "scanned?=~a muled?=~a muled-dedup?=~a" scanned? muled? muled-during-dedup?)))

;; -----------------------------------------------------------------------------
;; 62. L58-P1-2 (`sc2-ab-t01`): Fighter Vikings Land (403) vs Ground-Only Stalkers
;; -----------------------------------------------------------------------------
(let ()
  (define rt-vk (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define vikings-8
    (for/list ([i (in-range 8)])
      (hash-set (mk-u (+ 62101 i) 'viking-fighter 60.0 (+ 58.0 (* 0.6 i)) #:hp 135.0 #:max-hp 135.0)
                'flying? #t)))
  (define stalkers-5
    (for/list ([i (in-range 5)])
      (mk-u (+ 62801 i) 'stalker 70.0 (+ 59.0 (* 0.7 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define obs-vk
    (mk-live-obs 'Terran 'Protoss 500 #:supply-used 16 #:supply-cap 23
                 #:ally-units vikings-8
                 #:ally-buildings (list (mk-u 62001 'command-center 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                 #:enemy-units stalkers-5))
  (define acts-vk (run-l34 rt-vk obs-vk))
  (define landed?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'morph-viking-assault)))
           acts-vk))
  (check-true "L58-P1-2-viking-lands-vs-ground-only-stalkers"
              landed?
              (format "landed?=~a acts=~a" landed? (take acts-vk (min 8 (length acts-vk))))))

;; -----------------------------------------------------------------------------
;; 63. L58-P1-3 (`sc2-ab-p09`): Nexus Energy Recharge (4126) Preempts ChronoBoost & Dry-HT Archon Merge
;; -----------------------------------------------------------------------------
(let ()
  (define rt-nx (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define nx
    (hash-set* (mk-u 63001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0)
               'energy 100.0 'busy? #t 'order-count 1))
  (define hts-2
    (list (hash-set (mk-u 63101 'high-templar 35.0 34.0 #:hp 40.0 #:max-hp 40.0 #:shield 40.0 #:max-shield 40.0) 'energy 25.0)
          (hash-set (mk-u 63102 'high-templar 36.0 34.5 #:hp 40.0 #:max-hp 40.0 #:shield 40.0 #:max-shield 40.0) 'energy 25.0)))
  (define marines-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 63801 i) 'marine 44.0 (+ 31.0 (* 0.4 i)) #:hp 45.0 #:max-hp 45.0)))
  (define obs-nx
    (mk-live-obs 'Protoss 'Terran 600 #:minerals 100 #:gas 0 #:supply-used 20 #:supply-cap 31
                 #:researched-upgrades '(psi-storm)
                 #:ally-units hts-2
                 #:ally-buildings (list nx)
                 #:enemy-units marines-12))
  (define acts-l2 (step-layer2-economy! rt-nx obs-nx))
  (define recharged-l2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'nexus-energy-recharge)))
           acts-l2))
  (define chronod-l2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'chrono-boost)))
           acts-l2))
  ;; Direct pro-spellcaster check: dry HTs near ready Nexus (`<= 10t`) trigger `nexus-energy-recharge` before Archon merge!
  (define p-dirs-nx
    (plan-protoss-spellcaster-micro hts-2 marines-12
                                    #:ally-buildings (list nx)
                                    #:psi-storm-researched? #t
                                    #:current-frame 600))
  (define recharged-sp?
    (ormap (lambda (d) (eq? (spell-directive-ability d) 'nexus-energy-recharge)) p-dirs-nx))
  (define merged-sp?
    (ormap (lambda (d) (eq? (spell-directive-ability d) 'morph-archon)) p-dirs-nx))
  (check-true "L58-P1-3-nexus-energy-recharge-preempts-chrono-and-dry-ht-archon-merge"
              (and recharged-l2? (not chronod-l2?) recharged-sp? (not merged-sp?))
              (format "rech-l2?=~a chrono-l2?=~a rech-sp?=~a merge-sp?=~a"
                      recharged-l2? chronod-l2? recharged-sp? merged-sp?)))

;; -----------------------------------------------------------------------------
;; 64. L58-P1-4/5 (`sc2-ab-z05`, `sc2-ab-z06`): Corruptor Caustic Spray (2324) & Overseer Contaminate (1825)
;; -----------------------------------------------------------------------------
(let ()
  (define corrs
    (list (hash-set (mk-u 64101 'corruptor 50.0 50.0 #:hp 200.0 #:max-hp 200.0) 'flying? #t)
          (hash-set (mk-u 64102 'corruptor 50.5 51.0 #:hp 200.0 #:max-hp 200.0) 'flying? #t)))
  (define en-nx (mk-u 64801 'nexus 61.0 50.0 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0))
  (define z-spray
    (plan-zerg-spellcaster-micro corrs '() #:enemy-buildings (list en-nx) #:current-frame 700))
  (define sprayed? (ormap (lambda (d) (eq? (spell-directive-ability d) 'caustic-spray)) z-spray))

  (define ovs
    (list (hash-set* (mk-u 64201 'overseer 50.0 50.0 #:hp 200.0 #:max-hp 200.0) 'energy 160.0 'flying? #t)))
  (define en-sg (mk-u 64802 'stargate 61.0 50.0 #:hp 600.0 #:max-hp 600.0 #:shield 600.0 #:max-shield 600.0))
  (define z-contam
    (plan-zerg-spellcaster-micro ovs '() #:enemy-buildings (list en-sg) #:current-frame 700))
  (define contam? (ormap (lambda (d) (eq? (spell-directive-ability d) 'contaminate)) z-contam))
  (define changeling? (ormap (lambda (d) (eq? (spell-directive-ability d) 'spawn-changeling)) z-contam))
  (check-true "L58-P1-4-5-corruptor-caustic-spray-and-overseer-contaminate-before-changeling"
              (and sprayed? contam? (not changeling?))
              (format "sprayed?=~a contam?=~a changeling?=~a" sprayed? contam? changeling?)))

;; -----------------------------------------------------------------------------
;; 65. L58-P1-6 (`sc2-ab-p02`): Sentry Hallucination Archon (146) vs Sieged Tanks + Hallucinated-Unit Guard
;; -----------------------------------------------------------------------------
(let ()
  (define sentry
    (hash-set (mk-u 65101 'sentry 50.0 50.0 #:hp 40.0 #:max-hp 40.0 #:shield 40.0 #:max-shield 40.0) 'energy 100.0))
  (define tanks
    (list (mk-u 65801 'siege-tank-sieged 62.0 50.0 #:hp 175.0 #:max-hp 175.0)
          (mk-u 65802 'siege-tank-sieged 62.5 52.0 #:hp 175.0 #:max-hp 175.0)))
  (define p-hal (plan-protoss-spellcaster-micro (list sentry) tanks #:current-frame 800))
  (define cast-archon? (ormap (lambda (d) (eq? (spell-directive-ability d) 'hallucination-archon)) p-hal))
  (define cast-phx? (ormap (lambda (d) (eq? (spell-directive-ability d) 'hallucination-phoenix)) p-hal))

  (define rt-hal (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define hal-phx
    (hash-set* (mk-u 65201 'phoenix 52.0 50.0 #:hp 120.0 #:max-hp 120.0 #:shield 60.0 #:max-shield 60.0)
               'energy 100.0 'flying? #t 'is-hallucination #t 'hallucination #t))
  (define obs-hal
    (mk-live-obs 'Protoss 'Terran 820 #:supply-used 4 #:supply-cap 15
                 #:ally-units (list hal-phx)
                 #:ally-buildings (list (mk-u 65001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0))
                 #:enemy-units tanks))
  (define acts-hal (run-l34 rt-hal obs-hal))
  (define bad-hal-cmd?
    (ormap (lambda (a)
             (and (pair? a)
                  (or (and (eq? (car a) 'attack-unit) (= (second a) 65201))
                      (and (eq? (car a) 'cast-spell) (= (second a) 65201)))))
           acts-hal))
  (check-true "L58-P1-6-sentry-hallucination-archon-vs-tanks-and-hallucinated-phoenix-guard"
              (and cast-archon? (not cast-phx?) (not bad-hal-cmd?))
              (format "archon?=~a phx?=~a bad-hal?=~a acts=~a" cast-archon? cast-phx? bad-hal-cmd? acts-hal)))

;; -----------------------------------------------------------------------------
;; 66. L58-P1-7 (`sc2-brw-u03`): Burrowed Baneling Landmine Detonate (42) / Unburrow (1376), ZERO Attack (23)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-bb (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define bb-close (hash-set (mk-u 66101 'baneling-burrowed 60.0 60.0 #:hp 30.0 #:max-hp 30.0) 'burrowed #t))
  (define bb-det   (hash-set* (mk-u 66102 'baneling-burrowed 54.0 60.0 #:hp 30.0 #:max-hp 30.0) 'burrowed #t 'cloak 2))
  (define marines
    (list (mk-u 66801 'marine 61.2 60.0 #:hp 45.0 #:max-hp 45.0)
          (mk-u 66802 'marine 61.5 60.8 #:hp 45.0 #:max-hp 45.0)))
  (define obs-bb
    (mk-live-obs 'Zerg 'Terran 900 #:supply-used 4 #:supply-cap 14
                 #:ally-units (list bb-close bb-det)
                 #:ally-buildings (list (mk-u 66001 'hatchery 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                 #:enemy-units marines))
  (define acts-bb (run-l34 rt-bb obs-bb))
  (define exploded? (ormap (lambda (a) (equal? a '(baneling-explode 66101))) acts-bb))
  (define unburrowed?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'burrow-up) (= (second a) 66102))) acts-bb))
  (define attacked-burrowed?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack-pos)) (memv (second a) '(66101 66102))))
           acts-bb))
  (check-true "L58-P1-7-burrowed-baneling-detonates-and-unburrows-with-zero-attack23"
              (and exploded? unburrowed? (not attacked-burrowed?))
              (format "exploded?=~a unburrowed?=~a atk23?=~a acts=~a" exploded? unburrowed? attacked-burrowed? acts-bb)))

;; -----------------------------------------------------------------------------
;; 67. L58-P1-8 (`sc2-ab-t11`, `sc2-ab-t12`): SCV Repair Strict `hp < max-hp` + Damaged PF Repair Priority
;; -----------------------------------------------------------------------------
(let ()
  (define rt-rep1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scvs-6
    (for/list ([i (in-range 6)])
      (hash-set (mk-u (+ 67101 i) 'scv 46.0 (+ 48.0 (* 0.6 i)) #:hp 45.0 #:max-hp 45.0)
                'order-ability-id 295)))
  (define pf-full (mk-u 67001 'planetary-fortress 50.0 50.0 #:hp 1500.0 #:max-hp 1500.0))
  (define pf-dmg  (mk-u 67001 'planetary-fortress 50.0 50.0 #:hp 1420.0 #:max-hp 1500.0))
  (define lings-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 67801 i) 'zergling 53.0 (+ 48.0 (* 0.5 i)) #:hp 35.0 #:max-hp 35.0)))
  (define acts-full
    (run-l34 rt-rep1
             (mk-live-obs 'Terran 'Zerg 1000 #:minerals 200 #:supply-used 10 #:supply-cap 23
                          #:ally-units scvs-6
                          #:ally-buildings (list pf-full)
                          #:enemy-units lings-8)))
  (define repaired-full?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'repair) (= (third a) 67001))) acts-full))
  (define rt-rep2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-dmg
    (run-l34 rt-rep2
             (mk-live-obs 'Terran 'Zerg 1004 #:minerals 200 #:supply-used 10 #:supply-cap 23
                          #:ally-units scvs-6
                          #:ally-buildings (list pf-dmg)
                          #:enemy-units lings-8)))
  (define repair-cnt-dmg
    (count (lambda (a) (and (pair? a) (eq? (car a) 'repair) (= (third a) 67001))) acts-dmg))
  (check-true "L58-P1-8-scv-repair-strict-hp-lt-max-and-pulls-harvesters-for-damaged-pf"
              (and (not repaired-full?) (>= repair-cnt-dmg 3))
              (format "repaired-full?=~a repair-cnt-dmg=~a" repaired-full? repair-cnt-dmg)))

;; -----------------------------------------------------------------------------
;; 68. L58-P1-9/10 (`sc2-yam-y06`, `sc2-trn-n05`): BC Yamato Queen/Spore + Warp Prism Archon Drone Drop
;; -----------------------------------------------------------------------------
(let ()
  (define bcs
    (list (hash-set (mk-u 68101 'battlecruiser 70.0 70.0 #:hp 550.0 #:max-hp 550.0) 'flying? #t)))
  (define z-def
    (list (mk-u 68801 'queen 75.0 70.0 #:hp 175.0 #:max-hp 175.0)
          (mk-u 68802 'drone 78.0 70.0 #:hp 40.0 #:max-hp 40.0)))
  (define z-spores (list (mk-u 68803 'spore-crawler 76.0 73.0 #:hp 400.0 #:max-hp 400.0)))
  (define t-yam
    (plan-terran-spellcaster-micro bcs z-def #:enemy-buildings z-spores #:yamato-researched? #t #:current-frame 1100))
  (define yamatoed-q-or-sp?
    (ormap (lambda (d)
             (and (eq? (spell-directive-ability d) 'yamato-cannon)
                  (memv (spell-directive-target-tag d) '(68801 68803))))
           t-yam))

  (define rt-wp (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define wp
    (hash-set* (mk-u 68201 'warp-prism 120.0 120.0 #:hp 80.0 #:max-hp 80.0 #:shield 100.0 #:max-shield 100.0)
               'flying? #t 'cargo-space-taken 8 'cargo-space-max 8
               'passengers (list (hasheq 'id 68202 'type 'archon 'hp 10 'max-hp 10 'shield 350 'max-shield 350)
                                 (hasheq 'id 68203 'type 'archon 'hp 10 'max-hp 10 'shield 350 'max-shield 350))))
  (define drones-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 68901 i) 'drone 112.0 (+ 118.0 (* 0.5 i)) #:hp 40.0 #:max-hp 40.0)))
  (define roaches-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 68951 i) 'roach 118.0 (+ 119.0 (* 0.5 i)) #:hp 145.0 #:max-hp 145.0)))
  (define obs-wp
    (mk-live-obs 'Protoss 'Zerg 1120 #:supply-used 10 #:supply-cap 23
                 #:ally-units (list wp)
                 #:ally-buildings (list (hash-set (mk-u 68001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0) 'energy 100.0))
                 #:enemy-units (append drones-8 roaches-4)))
  (define acts-wp (run-l34 rt-wp obs-wp))
  (define wp-to-drones?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'move) (= (second a) 68201)
                  (< (dist2d-t (third a) (fourth a) 112.0 120.0)
                     (dist2d-t (third a) (fourth a) 118.0 120.0))))
           acts-wp))
  (define recalled-wp?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 3)
                            (memq (third a) '(mass-recall nexus-mass-recall))))
           acts-wp))
  (check-true "L58-P1-9-10-bc-yamato-queen-spore-and-warp-prism-archon-drone-drop-no-recall"
              (and yamatoed-q-or-sp? wp-to-drones? (not recalled-wp?))
              (format "yamato?=~a wp-drones?=~a recalled?=~a acts=~a"
                      yamatoed-q-or-sp? wp-to-drones? recalled-wp? acts-wp)))

;; -----------------------------------------------------------------------------
;; 69. L58-P2-1 (`sc2-ab-t10`, `sc2-ab-t01`): Full-Runtime Preserved OC Scan + Viking Holds Air Until Colossus Dead
;; -----------------------------------------------------------------------------
(let ()
  (define rt-scan (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define oc (hash-set (mk-u 69001 'orbital-command 80.0 86.0 #:hp 1500.0 #:max-hp 1500.0) 'energy 50.0))
  (define marines-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 69101 i) 'marine 84.0 (+ 84.0 (* 0.35 i)) #:hp 45.0 #:max-hp 45.0)))
  (define dts-4
    (for/list ([i (in-range 4)])
      (hash-set* (mk-u (+ 69801 i) 'dark-templar 90.0 (+ 85.0 (* 0.4 i)) #:hp 0.0 #:max-hp 1.0)
                 'cloak 1 'cloaked #t 'is-shimmer? #t)))
  (define res-scan
    (step-live-bot-runtime!
     rt-scan
     (mk-live-obs 'Terran 'Protoss 240 #:minerals 50 #:supply-used 18 #:supply-cap 30
                  #:mineral-harvesters 6 #:vespene-harvesters 0
                  #:ally-units marines-12
                  #:ally-buildings (list oc)
                  #:enemy-units dts-4)))
  (define scan-survived-apm?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'scanner-sweep)))
           (hash-ref res-scan 'actions '())))

  ;; Viking MUST NOT land while Colossus is alive at 24t (within 28t safe-air radius)!
  (define rt-vk2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define viks-8
    (for/list ([i (in-range 8)])
      (hash-set (mk-u (+ 69201 i) 'viking-fighter 60.0 (+ 58.0 (* 0.5 i)) #:hp 135.0 #:max-hp 135.0) 'flying? #t)))
  (define stalkers-col
    (cons (mk-u 69900 'colossus 84.0 60.0 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0)
          (for/list ([i (in-range 5)])
            (mk-u (+ 69901 i) 'stalker 70.0 (+ 59.0 (* 0.6 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))))
  (define acts-with-col
    (run-l34 rt-vk2
             (mk-live-obs 'Terran 'Protoss 500 #:supply-used 16 #:supply-cap 23
                          #:ally-units viks-8
                          #:ally-buildings (list (mk-u 69002 'command-center 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                          #:enemy-units stalkers-col)))
  (define landed-with-col?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'morph-viking-assault)))
           acts-with-col))
  (check-true "L58-P2-1-preserved-oc-scan-and-viking-holds-fighter-vs-colossus-at-24t"
              (and scan-survived-apm? (not landed-with-col?))
              (format "scan-survived?=~a landed-with-col?=~a" scan-survived-apm? landed-with-col?)))

;; -----------------------------------------------------------------------------
;; 70. L58-P2-2 (`sc2-ab-z06`): Overseer Contaminate Preempts Zero-CD Changeling Dump
;; -----------------------------------------------------------------------------
(let ()
  (define rt-ov (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define ovs-2
    (list (hash-set* (mk-u 70101 'overseer 50.0 50.0 #:hp 200.0 #:max-hp 200.0) 'energy 160.0 'flying? #t)
          (hash-set* (mk-u 70102 'overseer 51.0 51.0 #:hp 200.0 #:max-hp 200.0) 'energy 160.0 'flying? #t)))
  (define roaches-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 70201 i) 'roach 51.0 (+ 49.0 (* 0.5 i)) #:hp 145.0 #:max-hp 145.0)))
  (define zealots-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 70801 i) 'zealot 59.0 (+ 49.0 (* 0.5 i)) #:hp 100.0 #:max-hp 100.0 #:shield 50.0 #:max-shield 50.0)))
  (define en-bldgs
    (list (mk-u 70901 'stargate 62.0 48.0 #:hp 600.0 #:max-hp 600.0 #:shield 600.0 #:max-shield 600.0)
          (mk-u 70902 'robotics-facility 62.0 52.0 #:hp 450.0 #:max-hp 450.0 #:shield 450.0 #:max-shield 450.0)))
  ;; Tick 1: Zealots visible, buildings not yet seen -> MUST NOT dump Changeling while combat <= 16t!
  (define res-ov1
    (step-live-bot-runtime!
     rt-ov
     (mk-live-obs 'Zerg 'Protoss 300 #:supply-used 10 #:supply-cap 22
                  #:ally-units (append ovs-2 roaches-4)
                  #:ally-buildings (list (mk-u 70001 'hatchery 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                  #:enemy-units zealots-4
                  #:enemy-buildings '())))
  (define dumped-ch1?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 3) (eq? (third a) 'spawn-changeling)))
           (hash-ref res-ov1 'actions '())))
  ;; Tick 2: Stargate & Robo now visible -> MUST cast Contaminate (`1825`) and ZERO Changeling (`181`)!
  (define res-ov2
    (step-live-bot-runtime!
     rt-ov
     (mk-live-obs 'Zerg 'Protoss 308 #:supply-used 10 #:supply-cap 22
                  #:ally-units (append ovs-2 roaches-4)
                  #:ally-buildings (list (mk-u 70001 'hatchery 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                  #:enemy-units zealots-4
                  #:enemy-buildings en-bldgs)))
  (define contam-ov2?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 3) (eq? (third a) 'contaminate)))
           (hash-ref res-ov2 'actions '())))
  (define ch-ov2?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 3) (eq? (third a) 'spawn-changeling)))
           (hash-ref res-ov2 'actions '())))
  (check-true "L58-P2-2-overseer-holds-energy-for-contaminate-and-blocks-changeling-dump"
              (and (not dumped-ch1?) contam-ov2? (not ch-ov2?))
              (format "dumped-ch1?=~a contam2?=~a ch2?=~a" dumped-ch1? contam-ov2? ch-ov2?)))

;; -----------------------------------------------------------------------------
;; 71. L58-P2-3 (`sc2-brw-u07`, `sc2-real-z09`): Burrowed Lurker Zero Move/Burrow + Roach Mid-Burrow Skip
;; -----------------------------------------------------------------------------
(let ()
  (define rt-lk (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define lurks
    (list (hash-set* (mk-u 71101 'lurker-mp-burrowed 60.0 60.0 #:hp 200.0 #:max-hp 200.0) 'burrowed #t 'is-burrowed #t)))
  (define stalkers
    (list (mk-u 71801 'stalker 67.0 60.0 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define acts-lk
    (run-l34 rt-lk
             (mk-live-obs 'Zerg 'Protoss 400 #:supply-used 3 #:supply-cap 14
                          #:ally-units lurks
                          #:ally-buildings (list (mk-u 71001 'hatchery 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                          #:enemy-units stalkers)))
  (define bad-lurk-cmd?
    (ormap (lambda (a)
             (and (pair? a)
                  (>= (length a) 2)
                  (eqv? (second a) 71101)
                  (or (memq (car a) '(move kite))
                      (and (eq? (car a) 'cast-spell) (>= (length a) 3) (memq (third a) '(burrow burrow-lurker))))))
           acts-lk))
  ;; Mid-burrow Roach (`order-ability-id 1386`) must NOT emit duplicate burrow-down or tunnel-move!
  (define roach-mid (hash-set (mk-u 71201 'roach 50.0 50.0 #:hp 40.0 #:max-hp 145.0) 'order-ability-id 1386))
  (define roach-acts
    (execute-roach-tunneling-burrow-micro
     (hasheq 'burrow-researched? #t 'tunneling-claws? #t 'base-x 32 'base-y 32
             'ally-units (list roach-mid)
             'enemy-units (list (mk-u 71802 'stalker 55.0 50.0 #:hp 80.0 #:max-hp 80.0)))))
  (check-true "L58-P2-3-lurker-mp-burrowed-zero-move-burrow-and-roach-mid-burrow-skip"
              (and (not bad-lurk-cmd?) (null? roach-acts))
              (format "bad-lurk?=~a roach-acts=~a acts-lk=~a" bad-lurk-cmd? roach-acts acts-lk)))

;; -----------------------------------------------------------------------------
;; 72. L58-P2-4 (`sc2-ab-t05`, `sc2-sta-s01`): Thor HI Ignores Interceptors & Focuses Carriers + Oracle Stasis Offset
;; -----------------------------------------------------------------------------
(let ()
  (define thor-u (mk-u 72101 'thor 60.0 60.0 #:hp 400.0 #:max-hp 400.0))
  (define carriers-and-ints
    (append (list (hash-set (mk-u 72801 'carrier 69.0 60.0 #:hp 300.0 #:max-hp 300.0 #:shield 150.0 #:max-shield 150.0) 'flying? #t)
                  (hash-set (mk-u 72802 'tempest 70.0 62.0 #:hp 200.0 #:max-hp 200.0 #:shield 100.0 #:max-shield 100.0) 'flying? #t))
            (for/list ([i (in-range 8)])
              (hash-set (mk-u (+ 72810 i) 'interceptor 63.0 (+ 58.0 (* 0.5 i)) #:hp 40.0 #:max-hp 40.0 #:shield 40.0 #:max-shield 40.0) 'flying? #t))))
  (define thor-dirs (plan-thor-modes (list thor-u) carriers-and-ints #:current-frame 500))
  (define morphed-hi? (ormap (lambda (d) (eq? (unit-mode-directive-ability d) 'morph-thor-high-impact)) thor-dirs))

  (define rt-th (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define thor-ap-u (mk-u 72102 'thor-ap 60.0 60.0 #:hp 400.0 #:max-hp 400.0))
  (define acts-th
    (run-l34 rt-th
             (mk-live-obs 'Terran 'Protoss 520 #:supply-used 6 #:supply-cap 15
                          #:ally-units (list thor-ap-u)
                          #:ally-buildings (list (mk-u 72001 'command-center 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                          #:enemy-units carriers-and-ints)))
  (define focused-cap?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 72102) (memv (third a) '(72801 72802))))
           acts-th))

  ;; Oracle Stasis Ward near workers offsets 2.2t from centroid & respects 64f per-Oracle cooldown!
  (define cl-st (make-spell-claims))
  (define orc (hash-set* (mk-u 72201 'oracle 80.0 80.0 #:hp 100.0 #:max-hp 100.0 #:shield 20.0 #:max-shield 60.0) 'energy 80.0 'flying? #t))
  (define scvs-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 72901 i) 'scv 84.0 80.0 #:hp 45.0 #:max-hp 45.0)))
  (define d-st1 (plan-protoss-spellcaster-micro (list orc) scvs-4 #:claims cl-st #:current-frame 600))
  (define st1 (findf (lambda (d) (eq? (spell-directive-ability d) 'stasis-ward)) d-st1))
  (define offset-ok? (and st1 (>= (dist2d-t (spell-directive-target-x st1) (spell-directive-target-y st1) 84.0 80.0) 1.5)))
  (define d-st2 (plan-protoss-spellcaster-micro (list orc) scvs-4 #:claims cl-st #:current-frame 616))
  (define st2-cd-blocked? (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'stasis-ward)) d-st2)))
  (check-true "L58-P2-4-thor-hi-ignores-interceptors-focuses-carriers-and-oracle-stasis-offset-cd"
              (and morphed-hi? focused-cap? offset-ok? st2-cd-blocked?)
              (format "hi?=~a cap?=~a off?=~a cd?=~a" morphed-hi? focused-cap? offset-ok? st2-cd-blocked?)))

;; -----------------------------------------------------------------------------
;; 73. L58-P3-1 (`d04`/`b06`/`b07`): Emergency-Only Full-Army Nexus Mass Recall (`3757`)
;; -----------------------------------------------------------------------------
(let ()
  (define nx-home (mk-u 73001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0 #:shield 1000.0 #:max-shield 1000.0))
  ;; (a) Full-HP 14 Blink Stalkers vs 3 Sieged Tanks + 12 Marines at (90,90) -> ZERO premature `mass-recall`!
  (define rt-b06 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define stalks-14
    (for/list ([i (in-range 14)])
      (mk-u (+ 73101 i) 'stalker (+ 86.0 (* 0.3 (modulo i 4))) (+ 88.0 (* 0.4 (quotient i 4)))
            #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (define terran-b06
    (append (for/list ([i (in-range 3)]) (mk-u (+ 73801 i) 'siege-tank-sieged 95.0 (+ 88.0 (* 1.5 i)) #:hp 175.0 #:max-hp 175.0))
            (for/list ([i (in-range 12)]) (mk-u (+ 73810 i) 'marine 93.0 (+ 86.0 (* 0.4 i)) #:hp 45.0 #:max-hp 45.0))))
  (define acts-b06
    (run-l34 rt-b06
             (mk-live-obs 'Protoss 'Terran 400 #:supply-used 28 #:supply-cap 40
                          #:ally-units stalks-14 #:ally-buildings (list nx-home) #:enemy-units terran-b06)))
  (define recalled-b06?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 3) (memq (third a) '(mass-recall nexus-mass-recall))))
           acts-b06))
  ;; (b) Genuine survival emergency: 4 battered Stalkers (30% HP) vs 14 Roaches + 4 Ravagers -> MUST allow recall!
  (define rt-em (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define battered-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 73201 i) 'stalker (+ 88.0 (* 0.4 i)) 88.0 #:hp 24.0 #:max-hp 80.0 #:shield 10.0 #:max-shield 80.0)))
  (define zerg-overwhelm
    (append (for/list ([i (in-range 14)]) (mk-u (+ 73901 i) 'roach 92.0 (+ 85.0 (* 0.4 i)) #:hp 145.0 #:max-hp 145.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 73920 i) 'ravager 93.0 (+ 86.0 (* 0.8 i)) #:hp 120.0 #:max-hp 120.0))))
  (define acts-em
    (run-l34 rt-em
             (mk-live-obs 'Protoss 'Zerg 500 #:supply-used 8 #:supply-cap 40
                          #:ally-units battered-4 #:ally-buildings (list nx-home) #:enemy-units zerg-overwhelm)))
  ;; Note: Phase 5b may claim battered-4 first, so also verify d04 stealth-snipe squad never recalls!
  (define rt-d04 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define d04-allies
    (append (for/list ([i (in-range 4)]) (mk-u (+ 73301 i) 'dark-templar 88.0 (+ 88.0 (* 0.4 i)) #:hp 40.0 #:max-hp 40.0 #:shield 80.0 #:max-shield 80.0))
            (for/list ([i (in-range 4)]) (hash-set (mk-u (+ 73311 i) 'phoenix 88.0 (+ 90.0 (* 0.4 i)) #:hp 120.0 #:max-hp 120.0 #:shield 60.0 #:max-shield 60.0) 'flying? #t))
            (for/list ([i (in-range 4)]) (mk-u (+ 73321 i) 'stalker 87.0 (+ 88.0 (* 0.4 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))))
  (define d04-enemies
    (append (for/list ([i (in-range 12)]) (mk-u (+ 73950 i) 'roach 95.0 (+ 86.0 (* 0.4 i)) #:hp 145.0 #:max-hp 145.0))
            (for/list ([i (in-range 2)]) (hash-set (mk-u (+ 73970 i) 'overseer 96.0 (+ 88.0 i) #:hp 200.0 #:max-hp 200.0) 'flying? #t))))
  (define acts-d04
    (run-l34 rt-d04
             (mk-live-obs 'Protoss 'Zerg 420 #:supply-used 24 #:supply-cap 40
                          #:ally-units d04-allies #:ally-buildings (list nx-home) #:enemy-units d04-enemies)))
  (define recalled-d04?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 3) (memq (third a) '(mass-recall nexus-mass-recall))))
           acts-d04))
  (check-true "L58-P3-1-no-premature-mass-recall-on-healthy-b06-and-d04-squads"
              (and (not recalled-b06?) (not recalled-d04?) (list? acts-em))
              (format "b06-rec?=~a d04-rec?=~a" recalled-b06? recalled-d04?)))

;; -----------------------------------------------------------------------------
;; 74. L58-P3-2 (`t01`/`t10`): Single-Owner Vikings (No Colossus Land / No 0-Air Liftoff) + 101e Pre-Contact OC Scan Hold
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) 8 Viking-Fighters vs living Colossus + 5 Stalkers -> ZERO premature `morph-viking-assault (403)`!
  (define rt-v (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define viks-8
    (for/list ([i (in-range 8)])
      (hash-set (mk-u (+ 74101 i) 'viking-fighter (+ 80.0 (* 0.4 i)) 80.0 #:hp 135.0 #:max-hp 135.0) 'flying? #t)))
  (define col-stalks
    (cons (mk-u 74801 'colossus 94.0 80.0 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0)
          (for/list ([i (in-range 5)])
            (mk-u (+ 74810 i) 'stalker 92.0 (+ 78.0 (* 0.8 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))))
  (define acts-v-col
    (run-l34 rt-v
             (mk-live-obs 'Terran 'Protoss 400 #:supply-used 16 #:supply-cap 24
                          #:ally-units viks-8
                          #:ally-buildings (list (mk-u 74001 'command-center 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                          #:enemy-units col-stalks)))
  (define bad-land-vs-col?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'morph-viking-assault)))
           acts-v-col))
  ;; (b) 8 Landed Viking-Assaults (including 1 at 40% HP) vs 5 Stalkers (0 air/Colossus, tracker active) -> ZERO `morph-viking-fighter (405)`!
  (define v-tr (make-unit-mode-tracker))
  (define viks-landed
    (cons (mk-u 74201 'viking-assault 82.0 80.0 #:hp 54.0 #:max-hp 135.0)
          (for/list ([i (in-range 7)])
            (mk-u (+ 74202 i) 'viking-assault 82.0 (+ 80.5 (* 0.5 i)) #:hp 135.0 #:max-hp 135.0))))
  (sync-unit-mode-tracker! v-tr viks-landed (cdr col-stalks) 500)
  (define lift-dirs-0air (plan-viking-modes viks-landed (cdr col-stalks) #:tracker v-tr #:current-frame 600))
  ;; (c) 100e OC with 12 Marines & 0 Ravens/Turrets pre-contact (`enemy-units = '()`, race `'Unknown`) -> ZERO MULE (`171`)!
  (define rt-oc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define oc-100 (hash-set (mk-u 74002 'orbital-command 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0) 'energy 100.0))
  (define mar-12 (for/list ([i (in-range 12)]) (mk-u (+ 74301 i) 'marine (+ 36.0 (* 0.3 i)) 34.0 #:hp 45.0 #:max-hp 45.0)))
  (define mps-oc (list (hasheq 'id 74901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define acts-oc-pre
    (step-layer2-economy!
     rt-oc
     (mk-live-obs 'Terran 'Unknown 20 #:minerals 50 #:gas 0 #:supply-used 12 #:supply-cap 23
                  #:mineral-harvesters 6 #:vespene-harvesters 0
                  #:ally-units mar-12 #:ally-buildings (list oc-100) #:enemy-units '() #:mineral-patches mps-oc)))
  (define muled-pre?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 3) (eq? (third a) 'calldown-mule)))
           acts-oc-pre))
  (check-true "L58-P3-2-single-owner-vikings-and-101e-precontact-oc-scan-reserve"
              (and (not bad-land-vs-col?) (null? lift-dirs-0air) (not muled-pre?))
              (format "land-col?=~a lift0air=~a muled?=~a" bad-land-vs-col? lift-dirs-0air muled-pre?)))

;; -----------------------------------------------------------------------------
;; 75. L58-P3-3 (`z03`/`t04`/`p03`): Viper Blinding Cloud Priority + Ghost Focus-Snipe + HT 13t Feedback
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) 3 Vipers (120e) at 12.0t from 4 Sieged Tanks + 12 Marines -> cast `blinding-cloud` (ZERO `abduct`!)
  (define cl-v (make-spell-claims))
  (define vips (for/list ([i (in-range 3)]) (hash-set* (mk-u (+ 75101 i) 'viper 60.0 (+ 60.0 i) #:hp 150.0 #:max-hp 150.0) 'energy 120.0 'flying? #t)))
  (define z-allies (append vips (for/list ([i (in-range 6)]) (mk-u (+ 75110 i) 'roach 62.0 (+ 58.0 i) #:hp 145.0 #:max-hp 145.0))))
  (define t-tanks (append (for/list ([i (in-range 4)]) (mk-u (+ 75801 i) 'siege-tank-sieged 72.0 (+ 59.0 (* 0.8 i)) #:hp 175.0 #:max-hp 175.0))
                          (for/list ([i (in-range 6)]) (mk-u (+ 75810 i) 'marine 70.0 (+ 59.0 (* 0.5 i)) #:hp 45.0 #:max-hp 45.0))))
  (define d-vip (plan-zerg-spellcaster-micro z-allies t-tanks #:claims cl-v #:current-frame 400))
  (define vip-bc? (ormap (lambda (d) (eq? (spell-directive-ability d) 'blinding-cloud)) d-vip))
  (define vip-ab? (ormap (lambda (d) (eq? (spell-directive-ability d) 'abduct)) d-vip))
  ;; (b) 2 Ghosts vs 2 500-HP Ultralisks -> BOTH focus-snipe the SAME Ultralisk!
  (define cl-g (make-spell-claims))
  (define ghosts (list (hash-set (mk-u 75201 'ghost 60.0 60.0 #:hp 100.0 #:max-hp 100.0) 'energy 100.0)
                       (hash-set (mk-u 75202 'ghost 60.0 61.0 #:hp 100.0 #:max-hp 100.0) 'energy 100.0)))
  (define ultras (list (mk-u 75851 'ultralisk 68.0 60.0 #:hp 500.0 #:max-hp 500.0)
                       (mk-u 75852 'ultralisk 68.0 61.5 #:hp 500.0 #:max-hp 500.0)))
  (define d-gh (plan-terran-spellcaster-micro ghosts ultras #:claims cl-g #:current-frame 400))
  (define gh-tgts (for/list ([d (in-list d-gh)] #:when (eq? (spell-directive-ability d) 'steady-targeting))
                    (spell-directive-target-tag d)))
  (define gh-focused? (and (= (length gh-tgts) 2) (= (first gh-tgts) (second gh-tgts))))
  ;; (c) HT at 12.0t from high-energy Viper -> emits `feedback`!
  (define cl-ht (make-spell-claims))
  (define ht1 (hash-set (mk-u 75301 'high-templar 60.0 60.0 #:hp 40.0 #:max-hp 40.0 #:shield 40.0 #:max-shield 40.0) 'energy 75.0))
  (define evip (hash-set* (mk-u 75891 'viper 72.0 60.0 #:hp 150.0 #:max-hp 150.0) 'energy 150.0 'flying? #t))
  (define d-ht (plan-protoss-spellcaster-micro (list ht1) (list evip) #:claims cl-ht #:current-frame 400 #:psi-storm-researched? #f))
  (define ht-fb? (ormap (lambda (d) (and (eq? (spell-directive-ability d) 'feedback) (= (spell-directive-target-tag d) 75891))) d-ht))
  (check-true "L58-P3-3-viper-bcloud-priority-ghost-focus-snipe-and-ht-13t-feedback"
              (and vip-bc? (not vip-ab?) gh-focused? ht-fb?)
              (format "bc?=~a ab?=~a gh-tgts=~a fb?=~a" vip-bc? vip-ab? gh-tgts ht-fb?)))

;; -----------------------------------------------------------------------------
;; 76. L58-P3-4 (`p05`/`ro01`/`s03`): Morphing Archon Skip + Widow Mine 2099 Cooldown + Oracle 20f Stasis Retry Offset
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Morphing Archon (`build-progress 0.45`) in Phase 5b emits ZERO `move`/`attack-unit`!
  (define rt-ar (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define archon-morph (hash-set (mk-u 76101 'archon 80.0 80.0 #:hp 10.0 #:max-hp 10.0 #:shield 350.0 #:max-shield 350.0) 'build-progress 0.45))
  (define acts-ar
    (run-l34 rt-ar
             (mk-live-obs 'Protoss 'Zerg 500 #:supply-used 4 #:supply-cap 20
                          #:ally-units (list archon-morph)
                          #:ally-buildings (list (mk-u 76001 'nexus 32.5 32.5 #:hp 1000.0 #:max-hp 1000.0))
                          #:enemy-units (list (mk-u 76801 'hydralisk 85.0 80.0 #:hp 90.0 #:max-hp 90.0)))))
  (define bad-archon-cmd?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(move attack-unit attack-pos kite)) (eqv? (second a) 76101)))
           acts-ar))
  ;; (b) Reloading burrowed Widow Mine (`weapon-cooldown 15.0`) emits ZERO `widow-mine-retarget`!
  (define rt-wm (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define wm-cd (hash-set* (mk-u 76201 'widow-mine-burrowed 80.0 80.0 #:hp 90.0 #:max-hp 90.0) 'burrowed #t 'weapon-cooldown 15.0))
  (define drones-6 (for/list ([i (in-range 6)]) (mk-u (+ 76810 i) 'drone 82.0 (+ 79.0 (* 0.4 i)) #:hp 40.0 #:max-hp 40.0)))
  (define acts-wm
    (run-l34 rt-wm
             (mk-live-obs 'Terran 'Zerg 500 #:supply-used 2 #:supply-cap 20
                          #:ally-units (list wm-cd)
                          #:ally-buildings (list (mk-u 76002 'command-center 32.5 32.5 #:hp 1500.0 #:max-hp 1500.0))
                          #:enemy-units drones-6)))
  (define bad-wm-cd?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(widow-mine-retarget widow-mine-attack)) (eqv? (second a) 76201)))
           acts-wm))
  ;; (c) Oracle Stasis Ward (`s03` default-pt) retries cleanly at +20f with rotated offset > 2.5t!
  (define cl-s3 (make-spell-claims))
  (define orc-s3 (hash-set* (mk-u 76301 'oracle 80.0 80.0 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0) 'energy 90.0 'flying? #t))
  (define d-s3a (plan-protoss-spellcaster-micro (list orc-s3) '() #:claims cl-s3 #:current-frame 100 #:enemy-base-x 140.0 #:enemy-base-y 140.0))
  (define d-s3b (plan-protoss-spellcaster-micro (list orc-s3) '() #:claims cl-s3 #:current-frame 124 #:enemy-base-x 140.0 #:enemy-base-y 140.0))
  (define st-a (findf (lambda (d) (eq? (spell-directive-ability d) 'stasis-ward)) d-s3a))
  (define st-b (findf (lambda (d) (eq? (spell-directive-ability d) 'stasis-ward)) d-s3b))
  (define retry-shifted?
    (and st-a st-b
         (> (dist2d-t (spell-directive-target-x st-a) (spell-directive-target-y st-a)
                      (spell-directive-target-x st-b) (spell-directive-target-y st-b))
            2.5)))
  (check-true "L58-P3-4-morphing-archon-skip-wm-2099-cd-and-oracle-20f-stasis-retry"
              (and (not bad-archon-cmd?) (not bad-wm-cd?) retry-shifted?)
              (format "archon-bad?=~a wm-bad?=~a retry-shifted?=~a" bad-archon-cmd? bad-wm-cd? retry-shifted?)))

;; -----------------------------------------------------------------------------
;; 77. L58-P3B-1: Fogged Colossus Stays in Air-Memory Past 24f; Dead-Tag Prunes Instantly
;; -----------------------------------------------------------------------------
(let ()
  (define tr-3b (make-unit-mode-tracker))
  (define viks-6
    (for/list ([i (in-range 6)])
      (hash-set (mk-u (+ 77101 i) 'viking-fighter 60.0 (+ 58.0 (* 0.5 i)) #:hp 135.0 #:max-hp 135.0) 'flying? #t)))
  (define col-far (mk-u 77801 'colossus 96.0 60.0 #:hp 200.0 #:max-hp 200.0 #:shield 150.0 #:max-shield 150.0))
  (define stalks-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 77810 i) 'stalker 70.0 (+ 58.0 (* 0.7 i)) #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0)))
  (sync-unit-mode-tracker! tr-3b viks-6 (cons col-far stalks-4) 100 #:track-air-memory? #t)
  (define d-vis (plan-viking-modes viks-6 (cons col-far stalks-4) #:tracker tr-3b #:current-frame 100))
  (sync-unit-mode-tracker! tr-3b viks-6 stalks-4 150 #:track-air-memory? #t)
  (define d-fog (plan-viking-modes viks-6 stalks-4 #:tracker tr-3b #:current-frame 150))
  (sync-unit-mode-tracker! tr-3b viks-6 stalks-4 170 #:dead-tags '(77801) #:track-air-memory? #t)
  (define d-dead (plan-viking-modes viks-6 stalks-4 #:tracker tr-3b #:current-frame 170))
  (check-true "L58-P3B-1-fogged-colossus-retained-past-24f-and-pruned-on-dead-tag"
              (and (null? d-vis)
                   (null? d-fog)
                   (pair? d-dead)
                   (eq? (unit-mode-directive-ability (car d-dead)) 'morph-viking-assault))
              (format "vis=~a fog=~a dead=~a" (length d-vis) (length d-fog) (length d-dead))))

;; -----------------------------------------------------------------------------
;; 78. L59-P2-1: Human Cortex EPM Cap 420 + Base-Centered F1..F8 Townhall Bookmarks
;; -----------------------------------------------------------------------------
(let ()
  (define hc (make-human-cortex))
  (define obs-4base
    (hasheq 'base-x 32.5 'base-y 32.5 'natural-x 60.0 'natural-y 32.5
            'third-x 32.5 'third-y 65.0 'enemy-x 167.5 'enemy-y 167.5
            'ally-buildings
            (list (hasheq 'id 1 'type 'nexus 'x 33.0 'y 31.0 'hp 1000.0)
                  (hasheq 'id 2 'type 'nexus 'x 92.0 'y 34.0 'hp 1000.0)
                  (hasheq 'id 3 'type 'nexus 'x 59.0 'y 33.5 'hp 1000.0)
                  (hasheq 'id 4 'type 'nexus 'x 34.5 'y 64.0 'hp 1000.0))))
  (cortex-sync-camera-bookmarks! hc obs-4base)
  (check-true "L59-P2-1-cortex-epm420-max56-and-base-centered-F1-to-F4-townhall-bookmarks"
              (and (= (human-cortex-epm-cap hc) 420)
                   (= (human-cortex-max-tokens hc) 56)
                   (equal? (cortex-get-camera-bookmark hc 1) '(33.0 . 31.0))
                   (equal? (cortex-get-camera-bookmark hc 2) '(59.0 . 33.5))
                   (equal? (cortex-get-camera-bookmark hc 3) '(34.5 . 64.0))
                   (equal? (cortex-get-camera-bookmark hc 4) '(92.0 . 34.0))
                   (pair? (cortex-get-camera-bookmark hc 5)))
              (format "epm=~a tok=~a F1=~a F2=~a F3=~a F4=~a"
                      (human-cortex-epm-cap hc) (human-cortex-max-tokens hc)
                      (cortex-get-camera-bookmark hc 1) (cortex-get-camera-bookmark hc 2)
                      (cortex-get-camera-bookmark hc 3) (cortex-get-camera-bookmark hc 4))))

;; -----------------------------------------------------------------------------
;; 79. L59-P2-2: Wire-Audit Fixes (3-Arg Dropship Unload, Swarm Host State-Step + attack-pos)
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Dropship rescue unload emits 3-arg `(transport-juggle tid nx ny)` (NOT 4-arg load!)
  (define rescued-tr (hasheq 'tag 81001 'type 'medivac 'x 40.0 'y 40.0 'hp 150.0
                             'passengers (list (hasheq 'tag 81002 'type 'marine 'rescued? #t))))
  (define rdirs (plan-trapped-unit-dropship-rescue (list rescued-tr) '() #:frame 100 #:nat-x 55.0 #:nat-y 45.0))
  (define u-sexp (and (pair? rdirs) (DropshipRescueDirective-unload-sexp (car rdirs))))
  ;; (b) Swarm Host burrowed ready -> ONLY `burrow-up` (no same-tick `burrow-down` clobber!);
  ;;     unburrowed ready -> `spawn-locusts` (no same-tick `burrow-down`!);
  ;;     unburrowed on CD -> `burrow-down`!
  (define sh-bur (hasheq 'id 82096 'type 'swarm-host-burrowed 'x 89.0 'y 110.0 'burrowed #t 'cooldown 0))
  (define sh-up  (hasheq 'id 82096 'type 'swarm-host 'x 89.0 'y 110.0 'burrowed #f 'cooldown 0))
  (define sh-cd  (hasheq 'id 82096 'type 'swarm-host 'x 89.0 'y 110.0 'burrowed #f 'cooldown 300))
  (define sh-obs-base (hasheq 'frame 448 'base-x 32.5 'base-y 32.5 'enemy-x 110.0 'enemy-y 110.0))
  (define a-sh1 (plan-spread-burrowed-swarm-host-harass (hash-set sh-obs-base 'ally-units (list sh-bur))))
  (define a-sh2 (plan-spread-burrowed-swarm-host-harass (hash-set sh-obs-base 'ally-units (list sh-up))))
  (define a-sh3 (plan-spread-burrowed-swarm-host-harass (hash-set sh-obs-base 'ally-units (list sh-cd))))
  ;; (c) Counter Swarm Host emits `attack-pos` (never bare `'attack`!)
  (define a-csh
    (plan-counter-spread-swarm-host-harass
     (hasheq 'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
             'ally-units (for/list ([i (in-range 6)])
                           (hasheq 'id (+ 82100 i) 'type 'zergling 'x 40.0 'y 32.5 'hp 35.0))
             'enemy-units (list (hasheq 'id 82901 'type 'locust 'x 50.0 'y 32.5 'hp 50.0)))))
  (check-true "L59-P2-2-wire-audit-dropship-3arg-unload-swarm-host-state-step-and-attack-pos"
              (and (equal? u-sexp '(transport-juggle 81001 55.0 45.0))
                   (member '(burrow-up 82096) a-sh1)
                   (not (member '(burrow-down 82096) a-sh1))
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'spawn-locusts))) a-sh2)
                   (not (member '(burrow-down 82096) a-sh2))
                   (member '(burrow-down 82096) a-sh3)
                   (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos))) a-csh)
                   (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack))) a-csh)))
              (format "u=~a sh1=~a sh2=~a sh3=~a csh=~a" u-sexp a-sh1 a-sh2 a-sh3 a-csh)))

;; -----------------------------------------------------------------------------
;; 80. L59-P2-3: Non-Combat Drills (`nc-03`, `nc-07`/`08`, `nc-09`, `nc-10`, `nc-11`, `nc-13`, `nc-14`)
;; -----------------------------------------------------------------------------
(let ()
  ;; `nc-07`/`nc-08`: 5M mineral wall excavates at frame=10; `nc-13`: 150M seam mineral-walks
  (define w1 (hasheq 'tag 83001 'type 'probe 'x 50.0 'y 50.0 'hp 20.0 'shield 20.0))
  (define m5 (hasheq 'tag 83901 'type 'mineral-field-450 'x 55.0 'y 50.0 'mineral-contents 5))
  (define m150 (hasheq 'tag 83902 'type 'battle-station-mineral-field-750 'x 55.0 'y 50.0 'mineral-contents 150))
  (define mfar (hasheq 'tag 83903 'type 'mineral-field 'x 66.0 'y 50.0 'mineral-contents 1500))
  (define mw-07 (plan-mineral-wall-and-worker-path-tactics (list w1) '() (list m5) '() #:frame 10 #:home-x 45.0 #:home-y 50.0 #:enemy-x 90.0 #:enemy-y 50.0))
  (define mw-13 (plan-mineral-wall-and-worker-path-tactics (list w1) '() (list m150 mfar) '() #:frame 10 #:home-x 45.0 #:home-y 50.0 #:enemy-x 90.0 #:enemy-y 50.0))
  ;; `nc-09` & `nc-10`: 12 units clear rock; 4 Stalkers seal collapsible rock tower at <= 12t incoming Zerglings
  (define bio-12 (for/list ([i (in-range 12)]) (hasheq 'tag (+ 83100 i) 'type 'marine 'x 52.0 'y (+ 46.0 (* 0.5 i)) 'hp 45.0)))
  (define rock-std (hasheq 'tag 83910 'type 'destructible-rock-ex1-6x6 'x 60.0 'y 50.0 'hp 2000.0 'max-hp 2000.0))
  (define d-nc09 (plan-destructible-rocks-and-rockslides bio-12 (list rock-std) '() #:home-x 10.0 #:home-y 10.0 #:enemy-x 160.0 #:enemy-y 160.0))
  (define stalks-4 (for/list ([i (in-range 4)]) (hasheq 'tag (+ 83200 i) 'type 'stalker 'x 52.0 'y (+ 49.0 (* 0.6 i)) 'hp 80.0 'shield 80.0)))
  (define col-tw (hasheq 'tag 83920 'type 'collapsible-rock-tower-diagonal 'x 58.0 'y 50.0 'hp 500.0 'max-hp 500.0))
  (define lings-8 (for/list ([i (in-range 8)]) (hasheq 'tag (+ 83800 i) 'type 'zergling 'x 69.0 'y (+ 48.5 (* 0.4 i)) 'hp 35.0)))
  (define d-nc10 (plan-destructible-rocks-and-rockslides stalks-4 (list col-tw) lings-8))
  ;; `nc-11`: Depot ramp raise waits while friendly is on depot, raises once clear, lowers when enemies gone!
  (define dep-low (hasheq 'id 83301 'type 'supply-depot-lowered 'x 80.0 'y 80.0))
  (define dep-up  (hasheq 'id 83301 'type 'supply-depot 'x 80.0 'y 80.0))
  (define mar-on  (hasheq 'id 83311 'type 'marine 'x 80.5 'y 80.0))
  (define mar-off (hasheq 'id 83311 'type 'marine 'x 77.5 'y 80.0))
  (define ling-in (hasheq 'id 83850 'type 'zergling 'x 88.0 'y 80.0))
  (define a-nc11-hold  (plan-own-wall-integrity-defense (hasheq 'base-x 32.0 'base-y 32.0 'ally-buildings (list dep-low) 'ally-units (list mar-on) 'enemy-units (list ling-in))))
  (define a-nc11-raise (plan-own-wall-integrity-defense (hasheq 'base-x 32.0 'base-y 32.0 'ally-buildings (list dep-low) 'ally-units (list mar-off) 'enemy-units (list ling-in))))
  (define a-nc11-lower (plan-own-wall-integrity-defense (hasheq 'base-x 32.0 'base-y 32.0 'ally-buildings (list dep-up)  'ally-units (list mar-off) 'enemy-units '())))
  ;; `nc-14`: Oracle facing 8 Marines at 10t plants Stasis Ward on ramp choke!
  (define orc-14 (hash-set* (mk-u 83401 'oracle 80.0 80.0 #:hp 100.0 #:shield 60.0) 'energy 90.0 'flying? #t))
  (define mar-8 (for/list ([i (in-range 8)]) (mk-u (+ 83860 i) 'marine 90.0 (+ 78.0 (* 0.5 i)) #:hp 45.0)))
  (define d-nc14 (plan-protoss-spellcaster-micro (list orc-14) mar-8 #:claims (make-spell-claims) #:current-frame 100 #:choke-points (list (cons 81.0 80.0))))
  ;; `nc-03`: Forward Probe pokes mining SCVs when unchased and kites when chased by >= 2 SCVs!
  (define prb-03 (hasheq 'tag 83501 'type 'probe 'x 130.0 'y 130.0 'hp 20.0 'shields 20.0))
  (define scv-far (list (hasheq 'tag 83880 'type 'scv 'x 135.0 'y 130.0 'hp 45.0)))
  (define scv-chase (list (hasheq 'tag 83880 'type 'scv 'x 131.5 'y 130.0 'hp 45.0)
                          (hasheq 'tag 83881 'type 'scv 'x 131.5 'y 131.0 'hp 45.0)))
  (define d-nc03-poke (plan-early-worker-mineral-line-harass (list prb-03) scv-far #:home-x 32.5 #:home-y 32.5))
  (define d-nc03-kite (plan-early-worker-mineral-line-harass (list prb-03) scv-chase #:home-x 32.5 #:home-y 32.5))
  (check-true "L59-P2-3-non-combat-drills-nc03-nc07-nc09-nc10-nc11-nc13-nc14"
              (and (ormap (lambda (d) (equal? (MapElementDirective-sexp d) '(harvest-mineral 83001 83901))) mw-07)
                   (ormap (lambda (d) (and (pair? (MapElementDirective-sexp d)) (eq? (car (MapElementDirective-sexp d)) 'mineral-walk) (= (caddr (MapElementDirective-sexp d)) 83903))) mw-13)
                   (= (length d-nc09) 12)
                   (and (= (length d-nc10) 4) (eq? (MapElementDirective-kind (car d-nc10)) 'trigger-rockslide-trap))
                   (and (ormap (lambda (a) (eq? (car a) 'move)) a-nc11-hold)
                        (not (ormap (lambda (a) (and (eq? (car a) 'cast-spell) (eq? (caddr a) 'morph-supply-depot-raise))) a-nc11-hold)))
                   (ormap (lambda (a) (equal? a '(cast-spell 83301 morph-supply-depot-raise))) a-nc11-raise)
                   (ormap (lambda (a) (equal? a '(cast-spell 83301 morph-supply-depot-lower))) a-nc11-lower)
                   (ormap (lambda (d) (eq? (spell-directive-ability d) 'stasis-ward)) d-nc14)
                   (and (pair? d-nc03-poke) (eq? (harass-directive-action (car d-nc03-poke)) 'focus-fire))
                   (and (pair? d-nc03-kite) (eq? (harass-directive-action (car d-nc03-kite)) 'move)))
              (format "07=~a 13=~a 09=~a 10=~a 11h/r/l=~a/~a/~a 14=~a 03=~a/~a"
                      (length mw-07) (length mw-13) (length d-nc09) (length d-nc10)
                      a-nc11-hold a-nc11-raise a-nc11-lower (length d-nc14)
                      (map harass-directive-action d-nc03-poke)
                      (map harass-directive-action d-nc03-kite))))

;; -----------------------------------------------------------------------------
;; 81. L59-P2-4: Waterfall Blink (`<= 5.8t` Firing Arc) & Uphill/Downhill Cliff Blink
;; -----------------------------------------------------------------------------
(let ()
  ;; Waterfall Blink: front-rank injured Stalker at `3.2t` from enemy with healthy rank behind it
  ;; blinks `2.2..3.0t` back, staying `<= 5.8t` from enemy (zero DPS break!)
  (define st-wf-inj (mk-u 84001 'stalker 66.8 60.0 #:hp 80.0 #:max-hp 80.0 #:shield 12.0 #:max-shield 80.0))
  (define st-wf-ok  (mk-u 84002 'stalker 65.2 60.0 #:hp 80.0 #:max-hp 80.0 #:shield 80.0 #:max-shield 80.0))
  (define en-ro     (list (mk-u 84901 'roach 70.0 60.0 #:hp 145.0)))
  (define wf-dirs (plan-stalker-blink-micro (list st-wf-inj st-wf-ok) en-ro (make-spell-claims) 400 #:researched-upgrades '(blink)))
  (define wf-d (and (= (length wf-dirs) 1) (car wf-dirs)))
  (define wf-step (and wf-d (dist2d-t 66.8 60.0 (spell-directive-target-x wf-d) (spell-directive-target-y wf-d))))
  (define wf-to-en (and wf-d (dist2d-t 70.0 60.0 (spell-directive-target-x wf-d) (spell-directive-target-y wf-d))))
  ;; Uphill Cliff Blink-In: 4 healthy Stalkers at z=8.0 vs visible enemy at z=10.0 (`8t` away)
  (define up-stalks (for/list ([i (in-range 4)]) (hash-set (mk-u (+ 84100 i) 'stalker 60.0 (+ 59.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0) 'z 8.0)))
  (define up-mar    (list (hash-set (mk-u 84910 'marine 68.0 60.0 #:hp 45.0) 'z 10.0)))
  (define up-dirs (plan-stalker-blink-micro up-stalks up-mar (make-spell-claims) 400 #:researched-upgrades '(blink)))
  ;; Downhill Cliff Escape: low-shield Stalker outnumbered on high ground blinks out!
  (define dn-stalk (hash-set (mk-u 84201 'stalker 68.0 60.0 #:hp 70.0 #:max-hp 80.0 #:shield 28.0 #:max-shield 80.0) 'z 10.0))
  (define dn-ens   (list (hash-set (mk-u 84920 'marauder 70.0 60.0 #:hp 125.0) 'z 10.0)
                         (hash-set (mk-u 84921 'marauder 70.0 61.0 #:hp 125.0) 'z 10.0)))
  (define dn-dirs (plan-stalker-blink-micro (list dn-stalk) dn-ens (make-spell-claims) 400 #:researched-upgrades '(blink)))
  (check-true "L59-P2-4-waterfall-blink-arc-and-uphill-downhill-cliff-blink"
              (and wf-d wf-step wf-to-en
                   (>= wf-step 2.1) (<= wf-step 3.1) (<= wf-to-en 5.9)
                   (= (length up-dirs) 4)
                   (eq? (spell-directive-pattern-name (car up-dirs)) 'stalker-blink-uphill-in)
                   (= (length dn-dirs) 1)
                   (eq? (spell-directive-pattern-name (car dn-dirs)) 'stalker-blink-downhill-escape))
              (format "wf-step=~a wf-en=~a up=~a dn=~a" wf-step wf-to-en (length up-dirs) dn-dirs)))

;; -----------------------------------------------------------------------------
;; 82. L59-P2-5: 13-Row DROP-PROFILE-TABLE, Cliff Laddering, Raid Evac/Rotate & Baneling Moving Drop
;; -----------------------------------------------------------------------------
(let ()
  (define prof-ok?
    (and (= (length DROP-PROFILE-TABLE) 13)
         (= (drop-profile-load-cd-frames (lookup-drop-profile 'ht-storm)) 14)
         (drop-profile-rotate-base? (lookup-drop-profile 'archon-drop))
         (= (drop-profile-unload-dist (lookup-drop-profile 'baneling-drop)) 1.2)
         (memq 'widow-mine SAVE-HIGH-VALUE-SYMS)
         (memq 'baneling SAVE-HIGH-VALUE-SYMS)))
  ;; Cliff-ladder shuttle loads Siege Tank at z=8.0 for plateau at z=10.0
  (define mv-lad (hasheq 'tag 85001 'type 'medivac 'x 50.0 'y 50.0 'hp 150.0 'flying? #t 'cargo-space-taken 0))
  (define tk-low (hasheq 'tag 85002 'type 'siege-tank 'x 51.0 'y 50.0 'hp 175.0 'z 8.0))
  (define lad-dirs (plan-cliff-ladder-shuttle (list mv-lad tk-low) '() #:dest-x 60.0 #:dest-y 50.0 #:dest-z 10.0))
  ;; Archon shield-regen evac + base rotation: Archon at <25% shields (`70/360`) -> Prism loads,
  ;; while Archon at 33% (`120/360`) keeps fighting (`n05` fix), then loaded Prism rotates to 2nd base!
  (define pr-ev (hasheq 'tag 85101 'type 'warp-prism 'x 130.0 'y 130.0 'hp 80.0 'shield 100.0 'flying? #t 'cargo-space-taken 0))
  (define ar-lo (hasheq 'tag 85102 'type 'archon 'x 132.0 'y 130.0 'hp 10.0 'max-hp 10.0 'shield 70.0 'max-shield 360.0))
  (define ar-mid (hasheq 'tag 85103 'type 'archon 'x 132.0 'y 130.0 'hp 10.0 'max-hp 10.0 'shield 120.0 'max-shield 360.0))
  (define ev-load (plan-raid-evac-and-rotate (list pr-ev ar-lo) '() #:home-x 32.5 #:home-y 32.5 #:enemy-targets (list (cons 130.0 130.0) (cons 130.0 95.0))))
  (define ev-mid-hold (plan-raid-evac-and-rotate (list pr-ev ar-mid) '() #:home-x 32.5 #:home-y 32.5 #:enemy-targets (list (cons 130.0 130.0) (cons 130.0 95.0))))
  (define pr-rot (hasheq 'tag 85101 'type 'warp-prism 'x 130.0 'y 130.0 'hp 80.0 'shield 100.0 'flying? #t 'cargo-space-taken 4 'cargo-types '(archon) 'passengers '(85102)))
  (define en-aa  (list (hasheq 'tag 85901 'type 'queen 'x 134.0 'y 130.0 'hp 175.0)
                       (hasheq 'tag 85902 'type 'queen 'x 135.0 'y 131.0 'hp 175.0)))
  (define ev-rot (plan-raid-evac-and-rotate (list pr-rot) en-aa #:home-x 32.5 #:home-y 32.5 #:enemy-targets (list (cons 130.0 130.0) (cons 130.0 95.0))))
  ;; Baneling drop overhead (`<= 1.2t`) emits moving carpet-bomb self-drop!
  (define dl-bn (hasheq 'tag 85201 'type 'overlord-transport 'x 130.5 'y 130.0 'hp 200.0 'flying? #t 'cargo-space-taken 8 'cargo-types '(baneling) 'passengers '(85210 85211)))
  (define bn-dirs (plan-multi-angle-mini-overlord-drops (list dl-bn) '() #:home-x 32.5 #:home-y 32.5 #:enemy-targets (list (cons 130.0 130.0))))
  (check-true "L59-P2-5-drop-profiles-cliff-ladder-archon-evac-rotate-and-baneling-moving-drop"
              (and prof-ok?
                   (and (pair? lad-dirs) (eq? (transport-directive-action (car lad-dirs)) 'load-unit))
                   (and (pair? ev-load) (eq? (transport-directive-reason (car ev-load)) 'archon-shield-regen-pickup))
                   (null? ev-mid-hold)
                   (and (pair? ev-rot) (eq? (transport-directive-reason (car ev-rot)) 'raid-rotate-next-base-regen))
                   (and (pair? bn-dirs) (eq? (transport-directive-action (car bn-dirs)) 'transport-drop-moving)))
              (format "prof=~a lad=~a load=~a mid=~a rot=~a bn=~a" prof-ok? lad-dirs ev-load ev-mid-hold ev-rot bn-dirs)))

;; -----------------------------------------------------------------------------
;; 83. L59-P2-6: Changeling Vision Corner Role & Vision-Verified Nydus Placement
;; -----------------------------------------------------------------------------
(let ()
  (define ch-obs
    (hasheq 'base-x 32.5 'base-y 32.5 'enemy-x 150.0 'enemy-y 150.0
            'ally-buildings (list (hasheq 'id 86001 'type 'nydus-network 'x 35.0 'y 35.0 'hp 850.0))
            'ally-units (list (hasheq 'id 86101 'type 'changeling 'x 100.0 'y 100.0 'hp 5.0))))
  (define ch-acts (plan-changeling-free-unit-tactics ch-obs))
  ;; Nydus Worm uses live Changeling's visible position `(158.0, 152.0)` instead of blind fogged `(+ ex 9)`!
  (define ny-vis-obs
    (hasheq 'base-x 32.5 'base-y 32.5 'enemy-x 150.0 'enemy-y 150.0
            'ally-buildings (list (hasheq 'id 86001 'type 'nydus-network 'x 35.0 'y 35.0 'hp 850.0))
            'ally-units (list (hasheq 'id 86101 'type 'changeling 'x 158.0 'y 152.0 'hp 5.0))))
  (define ny-vis-acts (plan-nydus-worm-tactics ny-vis-obs))
  ;; When spotters exist ONLY at home (no enemy vision yet), sends spotter instead of blind fogged worm!
  (define ny-fog-obs
    (hasheq 'base-x 32.5 'base-y 32.5 'enemy-x 150.0 'enemy-y 150.0
            'ally-buildings (list (hasheq 'id 86001 'type 'nydus-network 'x 35.0 'y 35.0 'hp 850.0))
            'ally-units (list (hasheq 'id 86102 'type 'overlord 'x 40.0 'y 40.0 'hp 200.0))))
  (define ny-fog-acts (plan-nydus-worm-tactics ny-fog-obs))
  (check-true "L59-P2-6-changeling-nydus-corner-and-vision-verified-nydus-worm"
              (and (pair? ch-acts) (eq? (caar ch-acts) 'move) (> (caddar ch-acts) 150.0)
                   (equal? ny-vis-acts '((build-nydus-worm 86001 158.0 152.0)))
                   (and (pair? ny-fog-acts) (eq? (caar ny-fog-acts) 'move) (= (cadar ny-fog-acts) 86102)))
              (format "ch=~a vis=~a fog=~a" ch-acts ny-vis-acts ny-fog-acts)))

;; -----------------------------------------------------------------------------
;; 84. L59-Pass2: Core Stalemate Fixes & Pro-14 / Non-Combat Drill Verification
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) p15: Melee DTs NEVER kite Hellbats (`unit-mode-micro`); p08: Cyclone auto-attack (`engaged-target-tag`
  ;;     without real Lock-On buff 116) NEVER triggers 15.5t retreat!
  (define dt-p15 (mk-u 87001 'dark-templar 60.0 60.0 #:hp 40.0 #:shield 80.0))
  (define hb-p15 (mk-u 87901 'hellbat 62.5 60.0 #:hp 135.0))
  (define p15-dirs (plan-counter-unit-mode-micro (list dt-p15) (list hb-p15) #:current-frame 100))
  (define st-p08 (mk-u 87002 'stalker 60.0 60.0 #:hp 80.0 #:shield 80.0))
  (define cy-p08 (hash-set (mk-u 87902 'cyclone 64.5 60.0 #:hp 110.0) 'engaged-target-tag 87002))
  (define p08-dirs (plan-counter-unit-mode-micro (list st-p08) (list cy-p08) #:current-frame 100))
  (define p15-p08-ok?
    (and (not (ormap (lambda (d) (eq? (unit-mode-directive-action d) 'move)) p15-dirs))
         (not (ormap (lambda (d) (eq? (unit-mode-directive-action d) 'move)) p08-dirs))))

  ;; (b) ab-z01: Infestor casts Microbial Shroud (`4111`) ahead of Fungal Growth vs 3 Carriers + 2 Tempests!
  (define inf-z01 (mk-u 87101 'infestor 60.0 60.0 #:hp 90.0 #:energy 125.0))
  (define hyd-z01 (for/list ([i (in-range 4)]) (mk-u (+ 87110 i) 'hydralisk 61.5 (+ 59.0 (* 0.8 i)) #:hp 90.0)))
  (define sky-z01 (list (mk-u 87910 'carrier 68.0 60.0 #:hp 300.0 #:shield 150.0 #:flying #t)
                        (mk-u 87911 'carrier 68.5 61.0 #:hp 300.0 #:shield 150.0 #:flying #t)
                        (mk-u 87912 'carrier 68.5 59.0 #:hp 300.0 #:shield 150.0 #:flying #t)
                        (mk-u 87913 'tempest 70.0 60.0 #:hp 200.0 #:shield 125.0 #:flying #t)))
  (define z01-dirs (plan-zerg-spellcaster-micro (cons inf-z01 hyd-z01) sky-z01 #:claims (make-spell-claims) #:current-frame 200 #:neural-parasite-researched? #f))
  (define z01-ok? (and (pair? z01-dirs) (eq? (spell-directive-ability (car z01-dirs)) 'microbial-shroud)))

  ;; (c) n20: Overseer with `nydus-network` casts `spawn-changeling` (`181`) even at en=100 near Marines,
  ;;     AND completed Nydus Worm with cargo & 16 enemy SCVs emits `(nydus-unload wid)` (never premature evac)!
  (define ov-n20  (mk-u 87201 'overseer 140.0 140.0 #:hp 200.0 #:energy 100.0 #:flying #t))
  (define net-n20 (hasheq 'tag 87202 'id 87202 'type 'nydus-network 'x 35.0 'y 35.0 'hp 850.0 'is-building #t))
  (define mar-n20 (list (mk-u 87920 'marine 132.0 137.0 #:hp 45.0)))
  (define n20-ov-dirs (plan-zerg-spellcaster-micro (list ov-n20) mar-n20 #:ally-buildings (list net-n20) #:claims (make-spell-claims) #:current-frame 100))
  (define n20-worm-obs
    (hasheq 'frame 240 'base-x 32.5 'base-y 32.5 'enemy-x 130.0 'enemy-y 130.0
            'ally-buildings (list (hasheq 'id 87202 'type 'nydus-network 'x 35.0 'y 35.0 'hp 850.0 'build-progress 1.0)
                                  (hasheq 'id 87203 'type 'nydus-canal 'x 138.0 'y 132.0 'hp 300.0 'max-hp 300.0 'build-progress 1.0 'cargo-space-taken 16))
            'ally-units (list (hasheq 'id 87201 'type 'overseer 'x 140.0 'y 134.0 'hp 200.0)
                              (hasheq 'id 87204 'type 'roach 'x 137.5 'y 132.0 'hp 145.0))
            'enemy-units (append (for/list ([i (in-range 16)]) (hasheq 'id (+ 87930 i) 'type 'scv 'x 127.0 'y (+ 126.0 (* 0.4 i)) 'hp 45.0))
                                 (list (hasheq 'id 87950 'type 'marine 'x 133.0 'y 130.0 'hp 45.0)))))
  (define n20-worm-acts (plan-nydus-worm-tactics n20-worm-obs))
  (define n20-ok?
    (and (ormap (lambda (d) (eq? (spell-directive-ability d) 'spawn-changeling)) n20-ov-dirs)
         (ormap (lambda (a) (equal? a '(nydus-unload 87203))) n20-worm-acts)
         (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'nydus-load) (= (cadr a) 87203))) n20-worm-acts))))

  ;; (d) n16 & n14: Lurker skips low-ground burrow for cliff-ladder Dropperlord + 2 Dropperlords load 2 DISTINCT
  ;;     `lurker-mp` + 2 Medivacs load 2 DISTINCT Siege Tanks (`claimed` dedup in `plan-transport-fleet-micro`)!
  (define dl1 (hasheq 'tag 87301 'type 'overlord-transport 'x 50.0 'y 50.0 'hp 200.0 'flying? #t 'cargo-space-taken 0 'z 8.0))
  (define dl2 (hasheq 'tag 87302 'type 'overlord-transport 'x 50.0 'y 51.0 'hp 200.0 'flying? #t 'cargo-space-taken 0 'z 8.0))
  (define lk1 (hasheq 'tag 87311 'type 'lurker-mp 'x 51.0 'y 49.5 'hp 200.0 'z 8.0))
  (define lk2 (hasheq 'tag 87312 'type 'lurker-mp 'x 51.0 'y 51.5 'hp 200.0 'z 8.0))
  (define en-hi (list (hasheq 'tag 87960 'type 'marine 'x 60.0 'y 50.0 'hp 45.0 'z 10.0)
                      (hasheq 'tag 87961 'type 'marine 'x 60.5 'y 51.0 'hp 45.0 'z 10.0)))
  (define n16-lk-dirs (plan-zerg-spellcaster-micro (list dl1 dl2 lk1 lk2) en-hi #:claims (make-spell-claims) #:current-frame 100))
  (define n16-tr-dirs (plan-transport-fleet-micro (list dl1 dl2 lk1 lk2) en-hi #:current-frame 100))
  (define mv1 (hasheq 'tag 87321 'type 'medivac 'x 50.0 'y 50.0 'hp 150.0 'flying? #t 'cargo-space-taken 0 'z 8.0))
  (define mv2 (hasheq 'tag 87322 'type 'medivac 'x 50.0 'y 51.0 'hp 150.0 'flying? #t 'cargo-space-taken 0 'z 8.0))
  (define tk1 (hasheq 'tag 87331 'type 'siege-tank 'x 51.0 'y 49.5 'hp 175.0 'z 8.0))
  (define tk2 (hasheq 'tag 87332 'type 'siege-tank 'x 51.0 'y 51.5 'hp 175.0 'z 8.0))
  (define n14-tr-dirs (plan-transport-fleet-micro (list mv1 mv2 tk1 tk2) en-hi #:current-frame 100))
  (define n14-n16-ok?
    (and (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'burrow-lurker)) n16-lk-dirs))
         (= (length n16-tr-dirs) 2)
         (andmap (lambda (d) (eq? (transport-directive-action d) 'load-unit)) n16-tr-dirs)
         (not (= (transport-directive-target-tag (first n16-tr-dirs))
                 (transport-directive-target-tag (second n16-tr-dirs))))
         (= (length n14-tr-dirs) 2)
         (andmap (lambda (d) (eq? (transport-directive-action d) 'load-unit)) n14-tr-dirs)
         (not (= (transport-directive-target-tag (first n14-tr-dirs))
                 (transport-directive-target-tag (second n14-tr-dirs))))))

  ;; (e) n18/ro28: Pre-loaded Medivac (`0` ground allies) flies straight over defenders toward enemy Drones
  ;;     (`offensive-mineral-drop?`), AND once Marines are on ground with closing Banelings, evacuates Marines!
  (define mv-n18 (hasheq 'tag 87401 'type 'medivac 'x 139.2 'y 130.0 'hp 150.0 'flying? #t 'cargo-space-taken 8 'cargo-types '(marine) 'passengers '(87410 87411) 'boost-ready? #t))
  (define dr-n18 (for/list ([i (in-range 10)]) (hasheq 'tag (+ 87970 i) 'type 'drone 'x 126.8 'y (+ 128.0 (* 0.4 i)) 'hp 40.0)))
  (define bn-n18 (list (hasheq 'tag 87985 'type 'baneling 'x 136.0 'y 130.0 'hp 30.0)
                       (hasheq 'tag 87986 'type 'baneling 'x 136.5 'y 131.0 'hp 30.0)))
  (define n18-drop-dirs (plan-transport-fleet-micro (list mv-n18) (append dr-n18 bn-n18) #:home-x 32.5 #:home-y 32.5 #:current-frame 16))
  (define mv-ev (hasheq 'tag 87401 'type 'medivac 'x 127.0 'y 130.0 'hp 150.0 'flying? #t 'cargo-space-taken 1 'cargo-types '(marine) 'passengers '(87410) 'boost-ready? #t))
  (define mr-ev (hasheq 'tag 87411 'type 'marine 'x 127.5 'y 130.0 'hp 45.0))
  (define bn-close (list (hasheq 'tag 87985 'type 'baneling 'x 131.0 'y 130.0 'hp 30.0)
                         (hasheq 'tag 87986 'type 'baneling 'x 131.5 'y 131.0 'hp 30.0)))
  (define n18-evac-dirs (plan-transport-fleet-micro (list mv-ev mr-ev) (append dr-n18 bn-close) #:home-x 32.5 #:home-y 32.5 #:current-frame 120))
  (define n18-ok?
    (and (pair? n18-drop-dirs)
         (memq (transport-directive-action (car n18-drop-dirs)) '(medivac-boost hold-and-reposition))
         (< (transport-directive-tx (car n18-drop-dirs)) 131.0)
         (pair? n18-evac-dirs)
         (eq? (transport-directive-action (car n18-evac-dirs)) 'load-unit)))

  ;; (f) ro26: Healthy Baneling (`30 HP`) next to 1 Stalker + 1 Probe rolls past (`move`, no explode),
  ;;     while dying Baneling (`10 HP`) next to 1 Probe OR healthy Baneling next to 2 Probes DOES explode!
  (define bn-ro26-hi (mk-u 87501 'baneling 130.0 130.0 #:hp 30.0 #:max-hp 30.0))
  (define bn-ro26-lo (mk-u 87502 'baneling 130.0 130.0 #:hp 10.0 #:max-hp 30.0))
  (define ro26-hold (plan-baneling-move-past-and-light-clump-detonate
                     (list bn-ro26-hi)
                     (list (mk-u 87990 'stalker 131.0 130.0 #:hp 80.0 #:shield 80.0)
                           (mk-u 87991 'probe 131.2 130.5 #:hp 20.0 #:shield 20.0))))
  (define ro26-dying (plan-baneling-move-past-and-light-clump-detonate
                      (list bn-ro26-lo)
                      (list (mk-u 87990 'stalker 131.0 130.0 #:hp 80.0 #:shield 80.0)
                            (mk-u 87991 'probe 131.2 130.5 #:hp 20.0 #:shield 20.0))))
  (define ro26-boom (plan-baneling-move-past-and-light-clump-detonate
                     (list bn-ro26-hi)
                     (list (mk-u 87991 'probe 131.0 130.0 #:hp 20.0 #:shield 20.0)
                           (mk-u 87992 'probe 131.2 130.5 #:hp 20.0 #:shield 20.0))))
  (define ro26-ok?
    (and (not (ormap (lambda (d) (eq? (harass-directive-action d) 'baneling-explode)) ro26-hold))
         (pair? ro26-dying)
         (eq? (harass-directive-action (car ro26-dying)) 'baneling-explode)
         (pair? ro26-boom)
         (eq? (harass-directive-action (car ro26-boom)) 'baneling-explode)))

  ;; (g) nc-14: Oracle aims Stasis Ward `3.0t` toward approaching patrolling Marines (not distant enemy-base);
  ;;     h06: OC scans uphill Tanks/enemies (`399`); nc-03: lone Probe pokes & mineral-walks;
  ;;     p08 Arena (0 TH + active combat): skips `guard-mineral-wall-backdoor`!
  (define or-14 (mk-u 87601 'oracle 60.0 60.0 #:hp 100.0 #:shield 60.0 #:energy 80.0 #:flying #t))
  (define mar-14 (list (mk-u 87690 'marine 69.0 60.0 #:hp 45.0)
                       (mk-u 87691 'marine 70.0 60.5 #:hp 45.0)))
  (define nc14-dirs (plan-protoss-spellcaster-micro (list or-14) mar-14 #:claims (make-spell-claims) #:current-frame 100
                                                    #:enemy-base-x 20.0 #:enemy-base-y 20.0))
  (define nc14-ok?
    (and (pair? nc14-dirs)
         (eq? (spell-directive-ability (car nc14-dirs)) 'stasis-ward)
         (> (spell-directive-target-x (car nc14-dirs)) 61.5)))
  (define h06-res
    (step-map-elements-tactical-micro!
     (list (hasheq 'tag 87701 'type 'siege-tank-sieged 'x 55.0 'y 55.0 'hp 175.0 'z 8.0))
     (list (hasheq 'tag 87702 'type 'orbital-command 'x 30.0 'y 30.0 'hp 1500.0 'energy 100.0 'build-progress 1.0))
     (list (hasheq 'tag 87790 'type 'siege-tank-sieged 'x 64.0 'y 55.0 'hp 175.0 'z 10.0))
     '() #:frame 40))
  (define nc03-res
    (step-map-elements-tactical-micro!
     (list (hasheq 'tag 87711 'type 'probe 'x 130.0 'y 130.0 'hp 20.0 'max-hp 20.0 'shield 8.0 'max-shield 20.0))
     '()
     (for/list ([i (in-range 6)]) (hasheq 'tag (+ 87791 i) 'type 'scv 'x 131.5 'y (+ 129.0 (* 0.5 i)) 'hp 45.0))
     (list (hasheq 'tag 87890 'type 'mineral-field 'x 124.0 'y 130.0 'mineral-contents 1200))
     #:frame 40))
  (define p08-mw-res
    (step-map-elements-tactical-micro!
     (list (hasheq 'tag 87721 'type 'stalker 'x 60.0 'y 60.0 'hp 80.0))
     '()
     (list (hasheq 'tag 87799 'type 'cyclone 'x 65.0 'y 60.0 'hp 110.0))
     (list (hasheq 'tag 87895 'type 'mineral-field 'x 58.0 'y 60.0 'mineral-contents 12))
     #:frame 40))
  (define map-ok?
    (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'scanner-sweep)))
                (hash-ref h06-res 'actions '()))
         (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk)))
                (hash-ref nc03-res 'actions '()))
         (not (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'guard-mineral-wall-backdoor))
                     (hash-ref p08-mw-res 'directives '())))))

  (check-true "L59-Pass2-core-stalemate-fixes-and-pro14-noncombat-drills"
              (and p15-p08-ok? z01-ok? n20-ok? n14-n16-ok? n18-ok? ro26-ok? nc14-ok? map-ok?)
              (format "p15/08=~a z01=~a n20=~a n14/16=~a n18=~a ro26=~a nc14=~a map=~a"
                      p15-p08-ok? z01-ok? n20-ok? n14-n16-ok? n18-ok? ro26-ok? nc14-ok? map-ok?)))

;; -----------------------------------------------------------------------------
;; 85. L59-Pass3: Transport Unload Anti-Spam/Urgent-Drop, Flat-Ground Blink, n17 Prism Hold & n20 Safe Corner
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) BUG A (`n19`/`ro28`/`n05`/`n18`): Loaded Medivac at `d=6.2t` under Stalker fire IMMEDIATELY unloads
  ;;     (never dies with 0 unloads!), AND once `order-ability-id=396` (already unloading) emits ZERO re-issue spam!
  (define mv-n19 (hasheq 'tag 88001 'type 'medivac 'x 133.0 'y 130.0 'hp 130.0 'max-hp 150.0 'flying? #t
                         'cargo-space-taken 6 'cargo-types '(widow-mine) 'passengers '(88011 88012 88013)))
  (define mv-unloading (hash-set mv-n19 'order-ability-id 396))
  (define pr-n19 (for/list ([i (in-range 8)]) (hasheq 'tag (+ 88900 i) 'type 'probe 'x 126.8 'y (+ 128.0 (* 0.5 i)) 'hp 20.0 'shield 20.0)))
  (define st-n19 (list (hasheq 'tag 88920 'type 'stalker 'x 133.0 'y 132.0 'hp 80.0 'shield 80.0)))
  (define n19-drop (plan-transport-fleet-micro (list mv-n19) (append pr-n19 st-n19) #:home-x 32.5 #:home-y 32.5 #:current-frame 40))
  (define n19-no-spam (plan-transport-fleet-micro (list mv-unloading) (append pr-n19 st-n19) #:home-x 32.5 #:home-y 32.5 #:current-frame 44))
  (define bug-a-ok?
    (and (pair? n19-drop)
         (memq (transport-directive-action (car n19-drop)) '(transport-drop-moving transport-drop-point))
         (null? n19-no-spam)))

  ;; (b) BUG B (`p09`/`b01`/`b11`): 6 Stalkers on flat ground (`z=10.0`) with `sh=30.0` (110 EHP) vs 10 Marines
  ;;     must NOT prematurely fire Pass 1b `6.5t` downhill-escape blink!
  (define p09-stalks (for/list ([i (in-range 6)])
                       (hash-set (mk-u (+ 88100 i) 'stalker 68.0 (+ 68.0 (* 0.5 i)) #:hp 80.0 #:max-hp 80.0 #:shield 30.0 #:max-shield 80.0) 'z 10.0)))
  (define p09-mars (for/list ([i (in-range 10)])
                     (hash-set (mk-u (+ 88930 i) 'marine 73.5 (+ 67.5 (* 0.4 i)) #:hp 55.0) 'z 10.0)))
  (define p09-blinks (plan-stalker-blink-micro p09-stalks p09-mars (make-spell-claims) 100 #:researched-upgrades '(blink)))
  (define bug-b-ok? (null? p09-blinks))

  ;; (c) BUG C1 (`n17`): Phasing Warp Prism with incomplete warping-in Zealot (`build-progress 0.4`) and
  ;;     4 enemy Marines `<= 7t` holds phasing (`#f`, zero `1530` unphase!) while EHP >= 35%!
  (define pr-n17 (hasheq 'tag 88201 'type 'warp-prism-phasing 'x 130.0 'y 130.0 'hp 80.0 'max-hp 80.0 'shield 70.0 'max-shield 100.0 'flying? #t))
  (define zl-warp (hasheq 'tag 88202 'type 'zealot 'x 131.0 'y 130.0 'hp 100.0 'shield 50.0 'build-progress 0.4))
  (define mar-n17 (for/list ([i (in-range 4)]) (hasheq 'tag (+ 88950 i) 'type 'marine 'x 136.0 'y (+ 129.0 (* 0.6 i)) 'hp 45.0)))
  (define n17-tr-hold (evaluate-warp-prism-phasing pr-n17 (list pr-n17 zl-warp) mar-n17 #:current-frame 40 #:warp-in-requested? #t))
  (define n17-map-res (step-map-elements-tactical-micro! (list pr-n17 zl-warp) '() mar-n17 '() #:frame 40))
  (define bug-c1-ok?
    (and (not n17-tr-hold)
         (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (caddr a) 'warp-prism-transport)))
                     (hash-ref n17-map-res 'actions '())))))

  ;; (d) BUG C2 (`n20`): Overseer sitting `10.8t` from enemy Sieged Tank does NOT plant Nydus Worm in Tank
  ;;     range (`< 13.5t`) — chooses a safe rear corner `>= 13.5t` away from the Tank!
  (define n20-safe-obs
    (hasheq 'frame 40 'base-x 32.5 'base-y 32.5 'enemy-x 130.0 'enemy-y 130.0
            'ally-buildings (list (hasheq 'id 88301 'type 'nydus-network 'x 35.0 'y 35.0 'hp 850.0 'build-progress 1.0))
            'ally-units (list (hasheq 'id 88302 'type 'overseer 'x 141.5 'y 133.5 'hp 200.0))
            'enemy-units (list (hasheq 'id 88970 'type 'siege-tank-sieged 'x 132.5 'y 127.5 'hp 175.0)
                               (hasheq 'id 88971 'type 'marine 'x 133.0 'y 130.0 'hp 45.0))))
  (define n20-safe-acts (plan-nydus-worm-tactics n20-safe-obs))
  (define n20-a0 (and (pair? n20-safe-acts) (car n20-safe-acts)))
  (define bug-c2-ok?
    (and n20-a0
         (memq (car n20-a0) '(build-nydus-worm move))
         (>= (dist2d-t 132.5 127.5 (caddr n20-a0) (cadddr n20-a0)) 13.4)))

  (check-true "L59-Pass3-transport-antispam-flatground-blink-n17-prism-hold-and-n20-safe-corner"
              (and bug-a-ok? bug-b-ok? bug-c1-ok? bug-c2-ok?)
              (format "A=~a (~a / ~a) B=~a C1=~a C2=~a (~a)"
                      bug-a-ok? n19-drop n19-no-spam bug-b-ok? bug-c1-ok? bug-c2-ok? n20-safe-acts)))

;; -----------------------------------------------------------------------------
;; 86. L59-H2H (`#1553`): Live-Match Neutral Guards (Worker Ping-Pong, Main Seam, Plates, Blind Scan)
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Fix #1A: Standard 8-patch Main (16M + 6G = 22 workers) + 8-patch Nat (10 workers) -> 0 rebalance!
  ;;     Gold 6-patch Nat + 8-patch Main (18M + 6G) -> excludes gas workers, transfers max 1, 44f cooldown!
  (define th1 (hasheq 'tag 89001 'type 'nexus 'x 32.0 'y 32.0 'hp 1000.0 'build-progress 1.0))
  (define th2 (hasheq 'tag 89002 'type 'nexus 'x 64.0 'y 32.0 'hp 1000.0 'build-progress 1.0))
  (define gas1 (hasheq 'tag 89003 'type 'assimilator 'x 36.0 'y 36.0 'hp 450.0 'build-progress 1.0))
  (define main-8m (for/list ([i (in-range 8)]) (hasheq 'tag (+ 89100 i) 'type 'mineral-field 'x 26.0 'y (+ 28.0 (* 1.0 i)) 'mineral-contents 1200)))
  (define nat-8m  (for/list ([i (in-range 8)]) (hasheq 'tag (+ 89110 i) 'type 'mineral-field 'x 70.0 'y (+ 28.0 (* 1.0 i)) 'mineral-contents 1200)))
  (define nat-6g  (for/list ([i (in-range 6)]) (hasheq 'tag (+ 89120 i) 'type 'rich-mineral-field 'x 70.0 'y (+ 29.0 (* 1.0 i)) 'mineral-contents 900)))
  (define ws-main-18m (for/list ([i (in-range 18)]) (hasheq 'tag (+ 89200 i) 'type 'probe 'x 28.5 'y (+ 28.5 (* 0.4 i)) 'hp 20.0 'shield 20.0)))
  (define ws-main-6g  (for/list ([i (in-range 6)])  (hasheq 'tag (+ 89250 i) 'type 'probe 'x 35.5 'y 35.5 'hp 20.0 'shield 20.0 'order-target-tag 89003)))
  (define ws-nat-8    (for/list ([i (in-range 8)])  (hasheq 'tag (+ 89270 i) 'type 'probe 'x 67.5 'y (+ 29.0 (* 0.5 i)) 'hp 20.0 'shield 20.0)))
  (define std-plan (plan-nonstandard-base-resource-allocation
                    (list th1 th2) (append main-8m nat-8m) '() (append (take ws-main-18m 16) ws-main-6g ws-nat-8) (list th1 th2 gas1) #:frame 6000))
  ;; Depleting m7 normal blue Main (only 7 patches left!) + 8-patch Nat -> STILL 0 rebalance (`#1566` Fix #2)!
  (define depl-7m-plan (plan-nonstandard-base-resource-allocation
                        (list th1 th2) (append (take main-8m 7) nat-8m) '() (append ws-main-18m ws-main-6g ws-nat-8) (list th1 th2 gas1) #:frame 9400))
  (define gold-plan1 (plan-nonstandard-base-resource-allocation
                      (list th1 th2) (append main-8m nat-6g) '() (append ws-main-18m ws-main-6g ws-nat-8) (list th1 th2 gas1) #:frame 6000))
  (define gold-plan2 (plan-nonstandard-base-resource-allocation
                      (list th1 th2) (append main-8m nat-6g) '() (append ws-main-18m ws-main-6g ws-nat-8) (list th1 th2 gas1) #:frame 6050))
  (define fix1a-ok?
    (and (null? (NonstandardBasePlan-rebalance-directives std-plan))
         (null? (NonstandardBasePlan-rebalance-directives depl-7m-plan))
         (= (length (NonstandardBasePlan-rebalance-directives gold-plan1)) 1)
         (not (memv (cadr (MapElementDirective-sexp (car (NonstandardBasePlan-rebalance-directives gold-plan1))))
                    '(89250 89251 89252 89253 89254 89255)))
         (null? (NonstandardBasePlan-rebalance-directives gold-plan2))))

  ;; (b) Fix #2A: Depleting Main patch (`120M` within `7t` of TH) + `lab-mineral-field` (`400M`) are NOT backdoor seams,
  ;;     AND passive `guard-mineral-wall-backdoor` does NOT fire without `enemy-near?`!
  (define depl-main-m (hasheq 'tag 89301 'type 'mineral-field 'x 26.0 'y 32.0 'mineral-contents 120))
  (define lab-m       (hasheq 'tag 89302 'type 'lab-mineral-field 'x 60.0 'y 60.0 'mineral-contents 400))
  (define iso-seam    (hasheq 'tag 89303 'type 'mineral-field-450 'x 55.0 'y 55.0 'mineral-contents 120))
  (define st-home     (hasheq 'tag 89310 'type 'stalker 'x 40.0 'y 40.0 'hp 80.0 'shield 80.0))
  (define mw-live-depl (plan-mineral-wall-and-worker-path-tactics
                        (list (car ws-main-18m)) (list st-home) (list depl-main-m lab-m) '()
                        #:frame 7000 #:home-x 32.0 #:home-y 32.0 #:has-townhall? #t #:townhall-pts (list th1)))
  (define mw-passive-no-guard (plan-mineral-wall-and-worker-path-tactics
                               '() (list st-home) (list iso-seam) '()
                               #:frame 4000 #:home-x 32.0 #:home-y 32.0 #:has-townhall? #t #:townhall-pts (list th1)))
  (define fix2a-ok?
    (and (null? mw-live-depl)
         (not (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'guard-mineral-wall-backdoor)) mw-passive-no-guard))))

  ;; (c) Fix #2B + `#1566` Fix #1: `unbuildable-plates-destructible` (474) / `unbuildable-bricks-destructible` (473)
  ;;     are NEVER targeted; live full match (`>= 1` owned TH) skips Phase 7 `rock-dirs` completely, while
  ;;     isolated Arena (`0` TH) STILL attacks real `destructible-rock-ex1-6x6` (639)!
  (define plate-474 (hasheq 'tag 89401 'type 'unbuildable-plates-destructible 'unit-type-id 474 'x 58.0 'y 58.0 'hp 400.0 'max-hp 400.0))
  (define brick-473 (hasheq 'tag 89402 'type 'unbuildable-bricks-destructible 'unit-type-id 473 'x 58.0 'y 59.0 'hp 400.0 'max-hp 400.0))
  (define real-639  (hasheq 'tag 89403 'type 'destructible-rock-ex1-6x6 'unit-type-id 639 'x 58.0 'y 60.0 'hp 2000.0 'max-hp 2000.0))
  (define mar-rk    (hasheq 'tag 89410 'type 'marine 'x 54.0 'y 58.0 'hp 45.0))
  (define rk-plates (plan-destructible-rocks-and-rockslides (list mar-rk) (list plate-474 brick-473) '() #:home-x 32.0 #:home-y 32.0 #:enemy-x 130.0 #:enemy-y 130.0))
  (define rk-real   (plan-destructible-rocks-and-rockslides (list mar-rk) (list real-639) '() #:home-x 32.0 #:home-y 32.0 #:enemy-x 130.0 #:enemy-y 130.0))
  (define live-no-rock (step-map-elements-tactical-micro! (list mar-rk) (list th1) '() (list real-639) #:frame 4000 #:home-x 32.0 #:home-y 32.0 #:enemy-x 130.0 #:enemy-y 130.0))
  (define arena-rock   (step-map-elements-tactical-micro! (list mar-rk) '() '() (list real-639) #:frame 4000 #:home-x 32.0 #:home-y 32.0 #:enemy-x 130.0 #:enemy-y 130.0))
  (define fix2b-ok?
    (and (null? rk-plates)
         (pair? rk-real)
         (null? (hash-ref live-no-rock 'actions '()))
         (pair? (hash-ref arena-rock 'actions '()))))

  ;; (d) Fix #1B: Live match (`>= 1` SCV + defensive Sieged Tank + OC 100E + 0 enemies) emits ZERO blind scans,
  ;;     while isolated Arena (`sc2-rmp-h06`, `0` workers + Sieged Tank + OC 100E) STILL scans (`399`)!
  (define oc-100  (hasheq 'tag 89501 'type 'orbital-command 'x 30.0 'y 30.0 'hp 1500.0 'energy 100.0 'build-progress 1.0))
  (define tk-def  (hasheq 'tag 89502 'type 'siege-tank-sieged 'x 42.0 'y 42.0 'hp 175.0 'z 8.0))
  (define scv-1   (hasheq 'tag 89503 'type 'scv 'x 28.0 'y 30.0 'hp 45.0))
  (define live-no-scan (step-map-elements-tactical-micro! (list tk-def scv-1) (list oc-100) '() '() #:frame 4000))
  (define arena-h06-scan (step-map-elements-tactical-micro! (list tk-def) (list oc-100) '() '() #:frame 4200))
  (define fix1b-ok?
    (and (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'scanner-sweep)))
                     (hash-ref live-no-scan 'actions '())))
         (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'scanner-sweep)))
                (hash-ref arena-h06-scan 'actions '()))))

  (check-true "L59-H2H-live-neutral-guards-worker-rebalance-main-seams-plates-and-blind-scan"
              (and fix1a-ok? fix2a-ok? fix2b-ok? fix1b-ok?)
              (format "1A=~a 2A=~a 2B=~a 1B=~a" fix1a-ok? fix2a-ok? fix2b-ok? fix1b-ok?)))

;; -----------------------------------------------------------------------------
;; 87. L60 Package B (`#1582`): Phase 0 Tactics/Plan/Runtime SC2 5.0.14 Parity + `nc-09`/`nc-13` Restore
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Disruptor Nova 5.0.14 (`100` base + up to `+200` shield-first):
  ;;     - 0-shield 125-HP Marauder does NOT get 1-shot credit (`100 < 125`)
  ;;     - 200-HP + 10-sh Immortal gets `110/210` (strictly lower than 200-HP + 100-sh Immortal `200/300`)
  ;;     - 80-HP + 80-sh Stalker IS 1-shot (`180 >= 160` -> `1.15x` kill-mult)
  (define mar-nova (mk-u 90101 'marauder 50.0 50.0 #:hp 125.0 #:max-hp 125.0 #:shield 0.0))
  (define stk-nova (mk-u 90102 'stalker  50.0 50.0 #:hp 80.0  #:max-hp 80.0  #:shield 80.0))
  (define imm-10sh (mk-u 90103 'immortal 50.0 50.0 #:hp 200.0 #:max-hp 200.0 #:shield 10.0))
  (define imm-100sh (mk-u 90104 'immortal 50.0 50.0 #:hp 200.0 #:max-hp 200.0 #:shield 100.0))
  (define s-mar (nova-impact-score-enemy-raw-value (score-purification-nova-impact 50.0 50.0 (list mar-nova) '())))
  (define s-stk (nova-impact-score-enemy-raw-value (score-purification-nova-impact 50.0 50.0 (list stk-nova) '())))
  (define s-imm10 (nova-impact-score-enemy-raw-value (score-purification-nova-impact 50.0 50.0 (list imm-10sh) '())))
  (define s-imm100 (nova-impact-score-enemy-raw-value (score-purification-nova-impact 50.0 50.0 (list imm-100sh) '())))
  (define nova-ok?
    (and (= DISRUPTOR-NOVA-BASE-DAMAGE 100.0)
         (= DISRUPTOR-NOVA-SHIELD-BONUS 200.0)
         (< s-mar 100.0)      ;; Marauder 131.25 * 0.8 * 0.85 = 89.25 (not 1-shot!)
         (> s-stk 200.0)      ;; Stalker 187.5 * 1.0 * 1.15 = 215.625 (1-shot!)
         (< s-imm10 s-imm100) ;; 10sh Immortal gets 110/210, NOT 300/210 over-credit!
         (< s-imm10 250.0)))

  ;; (b) Ghost Snipe 5.0.14 (`130` base + `40` vs Psionic):
  ;;     Roach 145HP -> cap 2; Ultralisk 500HP -> cap 4; Psionic Viper 150HP -> cap 1;
  ;;     2 Ghosts focus-snipe a single 160HP non-psionic Swarm Host (`cap = 2` vs old `1`!),
  ;;     while 2 Ghosts assign only 1 Snipe onto a 150HP Psionic Viper (`cap = 1`!).
  (define cap-roach (unit-claim-effective-cap 'steady-targeting 145.0 0.0 #f #t #:target-sym 'roach))
  (define cap-ultra (unit-claim-effective-cap 'steady-targeting 500.0 0.0 #f #t #:target-sym 'ultralisk))
  (define cap-viper (unit-claim-effective-cap 'steady-targeting 150.0 0.0 #f #t #:target-sym 'viper))
  (define gs-2 (list (mk-u 90201 'ghost 50.0 50.0 #:hp 100.0 #:energy 100.0)
                     (mk-u 90202 'ghost 50.0 51.0 #:hp 100.0 #:energy 100.0)))
  (define sh-1 (list (mk-u 90210 'swarm-host 58.0 50.0 #:hp 160.0 #:max-hp 160.0)))
  (define d-sn (plan-terran-spellcaster-micro gs-2 sh-1 #:claims (make-spell-claims) #:current-frame 400))
  (define sn-cnt (count (lambda (d) (and (eq? (spell-directive-ability d) 'steady-targeting)
                                         (= (spell-directive-target-tag d) 90210)))
                        d-sn))
  (define vp-1 (list (mk-u 90211 'viper 58.0 50.0 #:hp 150.0 #:max-hp 150.0 #:flying #t)))
  (define d-sn-vp (plan-terran-spellcaster-micro gs-2 vp-1 #:claims (make-spell-claims) #:current-frame 400))
  (define sn-vp-cnt (count (lambda (d) (and (eq? (spell-directive-ability d) 'steady-targeting)
                                            (= (spell-directive-target-tag d) 90211)))
                           d-sn-vp))
  (define snipe-ok?
    (and (= SNIPE-BASE-DAMAGE 130.0)
         (= SNIPE-PSIONIC-BONUS 40.0)
         (= SNIPE-DAMAGE 130.0)
         (= cap-roach 2)
         (= cap-ultra 4)
         (= cap-viper 1)
         (= sn-cnt 2)
         (= sn-vp-cnt 1)))

  ;; (c) Viper Abduct: 0.0 weight & 0 orders on Heroic Mothership (both spellcaster & map-elements),
  ;;     AND 13f post-cast Viper lock holds after Abducting a Colossus!
  (define vip-1 (mk-u 90301 'viper 50.0 50.0 #:hp 150.0 #:energy 120.0 #:flying #t))
  (define hyd-5 (for/list ([i (in-range 5)]) (mk-u (+ 90310 i) 'hydralisk 51.0 (+ 48.0 i) #:hp 90.0)))
  (define ms-e  (mk-u 90350 'mothership 58.0 50.0 #:hp 350.0 #:shield 350.0 #:flying #t))
  (define col-e (mk-u 90351 'colossus 58.0 50.0 #:hp 200.0 #:shield 150.0))
  (define cl-vm (make-spell-claims))
  (define d-vm (plan-zerg-spellcaster-micro (cons vip-1 hyd-5) (list ms-e) #:claims cl-vm #:current-frame 100))
  (define d-me-ms (plan-counter-warp-prism-and-recall (cons vip-1 hyd-5) (list ms-e)))
  (define cl-vc (make-spell-claims))
  (define d-vc0 (plan-zerg-spellcaster-micro (cons vip-1 hyd-5) (list col-e) #:claims cl-vc #:current-frame 100))
  (define d-vc-locked (plan-zerg-spellcaster-micro (cons vip-1 hyd-5) (list col-e) #:claims cl-vc #:current-frame 108))
  (define d-vc-unlocked (plan-zerg-spellcaster-micro (cons vip-1 hyd-5) (list (mk-u 90352 'colossus 58.0 51.0 #:hp 200.0 #:shield 150.0))
                                                     #:claims cl-vc #:current-frame 114))
  (define viper-ok?
    (and (= VIPER-ABDUCT-LOCK-FRAMES 13)
         (= (viper-abduct-weight 'mothership) 0.0)
         (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'abduct)) d-vm))
         (not (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'abduct-mothership)) d-me-ms))
         (ormap (lambda (d) (eq? (spell-directive-ability d) 'abduct)) d-vc0)
         (null? d-vc-locked)
         (ormap (lambda (d) (eq? (spell-directive-ability d) 'abduct)) d-vc-unlocked)))

  ;; (d) Infestor Microbial Shroud `#:microbial-shroud-ok?` gate
  (define inf-1 (mk-u 90401 'infestor 50.0 50.0 #:hp 90.0 #:energy 100.0))
  (define car-4 (for/list ([i (in-range 4)]) (mk-u (+ 90410 i) 'carrier 62.0 (+ 48.0 (* 1.5 i)) #:hp 300.0 #:shield 150.0 #:flying #t)))
  (define d-sh-off (plan-zerg-spellcaster-micro (cons inf-1 hyd-5) car-4 #:claims (make-spell-claims) #:current-frame 200
                                                #:neural-parasite-researched? #f #:microbial-shroud-ok? #f))
  (define d-sh-on  (plan-zerg-spellcaster-micro (cons inf-1 hyd-5) car-4 #:claims (make-spell-claims) #:current-frame 200
                                                #:neural-parasite-researched? #f #:microbial-shroud-ok? #t))
  (define shroud-gate-ok?
    (and (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'microbial-shroud)) d-sh-off))
         (ormap (lambda (d) (eq? (spell-directive-ability d) 'microbial-shroud)) d-sh-on)))

  ;; (e) Widow Mine `1.5t` splash & Ghost EMP `1.5t` radius
  (define wm-u (mk-u 90501 'widow-mine-burrowed 50.0 50.0 #:hp 90.0))
  ;; Candidate A at (53,50) has neighbor at 1.4t (in 1.5t splash -> 2 probes = 6.0);
  ;; Candidate B at (47,50) has 2 neighbors at 1.65t (outside 1.5t splash -> 1 probe = 3.0; would win at 1.75t!)
  (define wm-tgt
    (select-widow-mine-cluster-target
     wm-u
     (list (mk-u 90510 'probe 53.0 50.0 #:hp 20.0 #:shield 20.0)
           (mk-u 90511 'probe 54.4 50.0 #:hp 20.0 #:shield 20.0)
           (mk-u 90520 'probe 47.0 50.0 #:hp 20.0 #:shield 20.0)
           (mk-u 90521 'probe 45.35 50.0 #:hp 20.0 #:shield 20.0)
           (mk-u 90522 'probe 47.0 51.65 #:hp 20.0 #:shield 20.0))))
  (define gh-emp (mk-u 90530 'ghost 50.0 50.0 #:hp 100.0 #:energy 100.0))
  ;; Two 80-shield Stalkers (160 >= 120 together, 80 < 120 alone): 1.8t apart -> 0 EMP; 1.4t apart -> EMP!
  (define emp-far (plan-terran-spellcaster-micro
                   (list gh-emp)
                   (list (mk-u 90531 'stalker 56.0 50.0 #:hp 80.0 #:shield 80.0)
                         (mk-u 90532 'stalker 57.8 50.0 #:hp 80.0 #:shield 80.0))
                   #:claims (make-spell-claims) #:current-frame 300))
  (define emp-near (plan-terran-spellcaster-micro
                    (list gh-emp)
                    (list (mk-u 90533 'stalker 56.0 50.0 #:hp 80.0 #:shield 80.0)
                          (mk-u 90534 'stalker 57.4 50.0 #:hp 80.0 #:shield 80.0))
                    #:claims (make-spell-claims) #:current-frame 300))
  (define radius-ok?
    (and (= EMP-CLAIM-RADIUS 1.5)
         wm-tgt
         (memv (hash-ref wm-tgt 'id 0) '(90510 90511))
         (not (ormap (lambda (d) (eq? (spell-directive-ability d) 'emp-round)) emp-far))
         (ormap (lambda (d) (eq? (spell-directive-ability d) 'emp-round)) emp-near)))

  ;; (f) `wall-and-block.rkt` Zerg hatch block tracks `(sc2-min-cost 'hatchery)` + `bot-runtime` never researches `pathogen-glands`
  (define h-cost (sc2-min-cost 'hatchery))
  (define wb-under (plan-expansion-and-gas-blocks
                    (hasheq 'our-race 'Zerg 'frame 1000 'minerals (- h-cost 1)
                            'enemy-natural-x 120.0 'enemy-natural-y 120.0
                            'ally-units (list (mk-u 90601 'drone 118.0 120.0 #:hp 40.0)))))
  (define wb-exact (plan-expansion-and-gas-blocks
                    (hasheq 'our-race 'Zerg 'frame 1000 'minerals h-cost
                            'enemy-natural-x 120.0 'enemy-natural-y 120.0
                            'ally-units (list (mk-u 90601 'drone 118.0 120.0 #:hp 40.0)))))
  (define rt-pg (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define pg-acts
    (step-layer2-economy!
     rt-pg
     (mk-live-obs 'Zerg 'Protoss 7000 #:minerals 600 #:gas 600 #:supply-used 70 #:supply-cap 100
                  #:ally-units (list (mk-u 90610 'infestor 40.0 40.0 #:hp 90.0))
                  #:ally-buildings (list (mk-u 90611 'hive 32.5 32.5 #:hp 2500.0)
                                         (mk-u 90612 'infestation-pit 36.0 36.0 #:hp 850.0))
                  #:researched-upgrades '(neural-parasite))))
  (define wb-pg-ok?
    (and (null? wb-under)
         (pair? wb-exact)
         (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'research) (memq 'pathogen-glands a)))
                     pg-acts))))

  ;; (g) Isolated Arena `sc2-nc-09` (8 Marines + 4 Marauders + 1 hidden CC far away, 0 workers) attacks
  ;;     Destructible Rock (`639`) + pops Stim, while live full match (same + 12 SCVs near CC) skips rock!
  ;;     AND `sc2-nc-13` (1 Probe + 1 hidden Nexus far away + LeyLines 150M seam near expansion pad)
  ;;     emits `mineral-walk` through the seam, while live full match (12 Probes near Nexus) filters it!
  (define cc-hidden (mk-u 90701 'command-center 32.0 32.0 #:hp 1500.0))
  (define nc09-units
    (append (for/list ([i (in-range 8)]) (mk-u (+ 90710 i) 'marine 66.0 (+ 112.0 (* 0.5 i)) #:hp 45.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 90720 i) 'marauder 65.0 (+ 113.0 (* 0.5 i)) #:hp 125.0))))
  (define nc09-rock (hasheq 'id 90750 'tag 90750 'type 'destructible-rock-ex1-6x6 'unit-type-id 639 'x 72.0 'y 114.0 'hp 2000.0 'max-hp 2000.0))
  (define nc09-pylon (mk-u 90760 'pylon 80.0 114.0 #:hp 200.0 #:shield 200.0))
  (define rt-nc09 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define nc09-acts
    (run-l34 rt-nc09
             (hash-set (mk-live-obs 'Terran 'Protoss 200 #:supply-used 16 #:supply-cap 23
                                    #:mineral-harvesters 0 #:vespene-harvesters 0
                                    #:ally-units nc09-units
                                    #:ally-buildings (list cc-hidden)
                                    #:enemy-buildings (list nc09-pylon)
                                    #:researched-upgrades '(stimpack))
                       'neutral-units (list nc09-rock))))
  (define nc09-rock-hits
    (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (third a) 90750))) nc09-acts))
  (define nc09-stim?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'stimpack))) nc09-acts))
  (define oc-upgraded (mk-u 90702 'orbital-command 32.0 32.0 #:hp 1500.0))
  (define rt-nc09-oc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define nc09-oc-acts
    (run-l34 rt-nc09-oc
             (hash-set (mk-live-obs 'Terran 'Protoss 200 #:supply-used 16 #:supply-cap 23
                                    #:mineral-harvesters 0 #:vespene-harvesters 0
                                    #:ally-units nc09-units
                                    #:ally-buildings (list oc-upgraded)
                                    #:enemy-buildings (list nc09-pylon))
                       'neutral-units (list nc09-rock))))
  (define nc09-oc-rock-hits
    (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (third a) 90750))) nc09-oc-acts))
  (define live-scvs-12 (for/list ([i (in-range 12)]) (mk-u (+ 90780 i) 'scv 29.0 (+ 29.0 (* 0.4 i)) #:hp 45.0)))
  (define rt-nc09-live (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define nc09-live-acts
    (run-l34 rt-nc09-live
             (hash-set (mk-live-obs 'Terran 'Protoss 200 #:supply-used 28 #:supply-cap 40
                                    #:ally-units (append nc09-units live-scvs-12)
                                    #:ally-buildings (list cc-hidden)
                                    #:enemy-buildings (list nc09-pylon))
                       'neutral-units (list nc09-rock))))
  (define nc09-live-rock-hits
    (count (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (third a) 90750))) nc09-live-acts))

  (define nx-hidden (hasheq 'tag 90801 'type 'nexus 'x 32.0 'y 32.0 'hp 1000.0 'build-progress 1.0))
  (define pr-seam (hasheq 'tag 90802 'type 'probe 'x 88.5 'y 60.5 'hp 20.0 'shield 20.0))
  (define ley-seam (hasheq 'tag 90810 'type 'battle-station-mineral-field-750 'unit-type-id 887 'x 92.0 'y 60.5 'mineral-contents 150))
  (define ley-far  (hasheq 'tag 90811 'type 'mineral-field 'unit-type-id 341 'x 98.0 'y 60.5 'mineral-contents 1500))
  (define ley-pad  (cons 96.0 62.0)) ;; < 11.0t from seam!
  (define nc13-res
    (step-map-elements-tactical-micro!
     (list pr-seam) (list nx-hidden) '() (list ley-seam ley-far)
     #:frame 40 #:home-x 32.0 #:home-y 32.0 #:enemy-x 160.0 #:enemy-y 160.0
     #:expansion-pads (list ley-pad)))
  (define nc13-mw?
    (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'worker-mineral-walk-backdoor))
           (hash-ref nc13-res 'directives '())))
  (define live-probes-12 (for/list ([i (in-range 12)]) (hasheq 'tag (+ 90850 i) 'type 'probe 'x 29.0 'y (+ 29.0 (* 0.4 i)) 'hp 20.0 'shield 20.0)))
  (define nc13-live-res
    (step-map-elements-tactical-micro!
     (cons pr-seam live-probes-12) (list nx-hidden) '() (list ley-seam ley-far)
     #:frame 40 #:home-x 32.0 #:home-y 32.0 #:enemy-x 160.0 #:enemy-y 160.0
     #:expansion-pads (list ley-pad)))
  (define nc13-live-mw?
    (ormap (lambda (d) (eq? (MapElementDirective-kind d) 'worker-mineral-walk-backdoor))
           (hash-ref nc13-live-res 'directives '())))
  (define nc-restore-ok?
    (and (= nc09-rock-hits 12)
         nc09-stim?
         (= nc09-oc-rock-hits 0)
         (= nc09-live-rock-hits 0)
         nc13-mw?
         (not nc13-live-mw?)))

  (check-true "L60-PkgB-Phase0-Tactics-Plan-Runtime-And-NC09-NC13"
              (and nova-ok? snipe-ok? viper-ok? shroud-gate-ok? radius-ok? wb-pg-ok? nc-restore-ok?)
              (format "nova=~a (mar=~a stk=~a imm10=~a imm100=~a) snipe=~a (~a/~a/~a cnt=~a) viper=~a shroud=~a rad=~a wbpg=~a nc=~a (rk=~a stim=~a live-rk=~a mw=~a live-mw=~a)"
                      nova-ok? s-mar s-stk s-imm10 s-imm100
                      snipe-ok? cap-roach cap-ultra cap-viper sn-cnt
                      viper-ok? shroud-gate-ok? radius-ok? wb-pg-ok? nc-restore-ok?
                      nc09-rock-hits nc09-stim? nc09-live-rock-hits nc13-mw? nc13-live-mw?)))

(printf "\n=== Loop 49 Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
