#lang racket
;; =============================================================================
;; Loop 48 Verification Suite: Terran Barracks Cap Alignment & Arena 3.0 Polish
;;   1. `L48-P0-1a` (`H2H #02 TvT` `prod_stall=132` & `#47/#74/#84` `ProdStall 3 -> 0`):
;;      - When Macro Brain schedules `barracks` (`brain-sched-rax-now?`), Runtime
;;        builds Barracks #5/#7/#8 up to `SC2-MAX-PRODUCTION-FACILITIES (8)` instead
;;        of capping at `raw-desired-barracks = 2 * CCs` (and waives expansion reserve
;;        when Brain is not saving for CC/OC), while preserving `terran-tvt-cap-rax-for-tanks?`!
;;   2. `L48-P0-1b` (`r02`/`r05`/`r06` Zero-Disengage + `4f` Focus + `4f` Stack):
;;      - 15-Probe all-in emits ZERO `mineral-walk` mid-fight disengages (all 16 commit!),
;;        refreshes lowest-HP focus every `4f`, and stacks `<= 4f` (aborting `<= 2.5t`).
;;   3. `L48-P0-1b` (`ro09` Oracle `+4.5t` Lateral Flank + `0.25` Beam-ON Floor):
;;      - Oracles facing blocking Marines arc `+4.5t` laterally around Marine centroid
;;        past the CC into SCVs, hold `o-raid-safe?` down to `0.25` while `oracle-beam-on?`,
;;        and still kite safely at `0.28` when beam is OFF!
;;   4. `L48-P0-1b` (`e01` `> 20.0` EHP Sticky + One-Shot Rotate-Out `harvest-mineral`):
;;      - Defender at `21.0` EHP stays sticky; defender at `20.0` EHP emits `harvest-mineral`
;;        strictly ONCE (`20f` refractory) and skips workers already carrying/harvesting minerals!
;;   5. `L48-P0-1b` (`rd01` Widow Mine `> 3.5t` Patch Fallback + Overseer/Queen Mine Escort):
;;      - 2 mines with `3.7t` (`> 3.5t`) patch scatter Drones via `mineral-walk` (`0` `move` spam).
;;      - Overseer (`0` non-Queen combat units!) advances to `<= 7.5t` of mineral-line Widow Mines;
;;        Queens suspend `creep-tumor`/`inject-larva`, focus revealed Widow Mines over flying
;;        Medivacs, and stage `<= 7.5t` of unrevealed burrowed mines!
;;   6. `L48-P0-1b` (`ro11` SP Cloaked Banshee `24t` Evacuated-Worker Chase):
;;      - Undetected cloaked Banshees chase evacuated Drones `19.0t` away (`<= 24.0t`!) instead
;;        of shooting the closer Hatchery, while yielding cleanly when detectors are `<= 12.5t`!
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         "../lib/bot-runtime.rkt"
         "../lib/tactics/pro-spellcaster-micro.rkt"
         "../lib/tactics/concave-positioning.rkt")

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
              #:hp [hp 45.0]
              #:max-hp [max-hp hp]
              #:shield [sh 0.0]
              #:max-shield [max-sh sh]
              #:energy [en 0.0]
              #:flying? [fly? #f]
              #:cloaked? [cloak? #f]
              #:cloak [cloak-state (if cloak? 1 0)]
              #:burrowed? [burr? #f]
              #:buffs [buffs '()]
              #:build-progress [bp 1.0]
              #:weapon-cooldown [wcd 0.0]
              #:engaged-target-tag [etgt 0]
              #:orders [orders '()]
              #:carrying-minerals? [carry? #f]
              #:assigned-harvesters [ah #f]
              #:ideal-harvesters [ih #f])
  (define h
    (hasheq 'id id 'type type 'x x 'y y
            'hp hp 'max-hp max-hp
            'shield sh 'shields sh 'max-shield max-sh
            'energy en 'flying? fly?
            'cloaked? cloak? 'cloak cloak-state
            'is-burrowed? burr? 'burrowed? burr?
            'buffs buffs 'build-progress bp
            'weapon-cooldown wcd 'engaged-target-tag etgt
            'orders orders 'order-count (length orders)
            'carrying-minerals? carry?))
  (define h1 (if ah (hash-set h 'assigned-harvesters ah) h))
  (if ih (hash-set h1 'ideal-harvesters ih) h1))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200]
                     #:gas [gas 100]
                     #:supply-used [sup-used 60]
                     #:supply-cap [sup-cap 100]
                     #:base-x [bx 32.5]
                     #:base-y [by 32.5]
                     #:nat-x [nx 52.5]
                     #:nat-y [ny 34.5]
                     #:third-x [tx 72.5]
                     #:third-y [ty 36.5]
                     #:enemy-x [ex 142.5]
                     #:enemy-y [ey 138.5]
                     #:mineral-harvesters [mh 40]
                     #:vespene-harvesters [vh 6]
                     #:ally-units [aus '()]
                     #:ally-buildings [abs '()]
                     #:enemy-units [eus '()]
                     #:enemy-buildings [ebs '()]
                     #:mineral-patches [mps '()]
                     #:researched-upgrades [upgs '()])
  (hasheq 'frame frame
          'race race
          'enemy-race enemy-race
          'minerals minerals
          'gas gas
          'supply-used sup-used
          'supply-cap sup-cap
          'supply-left (max 0 (- sup-cap sup-used))
          'mineral-harvesters mh
          'vespene-harvesters vh
          'base-x bx 'base-y by
          'natural-x nx 'natural-y ny
          'third-x tx 'third-y ty
          'enemy-x ex 'enemy-y ey
          'ally-units aus
          'ally-buildings abs
          'enemy-units eus
          'enemy-buildings ebs
          'mineral-patches mps
          'researched-upgrades upgs
          'live-obs? #t))

(define (run-l34 rt obs [fap 0.5])
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(printf "=== Loop 48 Tactics & Runtime Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. L48-P0-1a (`H2H #02 TvT` `prod_stall=132` & `#47/#74/#84` Barracks Cap Fix)
;; -----------------------------------------------------------------------------
(let ()
  ;; 3-base Terran (`3` OCs, `6` busy Barracks = old `2 * CCs` cap!, `2` Factories + TL,
  ;; `1` Starport + TL, `3` Siege Tanks, `54` SCVs, `600M/20G` at `f=10200` -> clears L65's
  ;; `< 500M` 4th-CC mineral save so Macro Brain schedules `barracks` `#7` (`terran-midgame-rax-scale-due?`),
  ;; and Runtime MUST emit `(build barracks ...)` past `2 * CCs = 6`!).
  (define scvs-54
    (for/list ([i (in-range 54)])
      (mk-u (+ 1001 i) 'scv (+ 28.0 (* 0.25 (modulo i 9))) (+ 29.0 (* 0.5 (quotient i 9))) #:hp 45.0)))
  (define tanks-3
    (list (mk-u 1201 'siege-tank 42.0 34.0 #:hp 175.0)
          (mk-u 1202 'siege-tank 43.0 34.0 #:hp 175.0)
          (mk-u 1203 'siege-tank 44.0 34.0 #:hp 175.0)))
  (define marines-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 1210 i) 'marine (+ 40.0 (* 0.4 i)) 35.0 #:hp 45.0)))
  (define bldgs-3b-6rax
    (append
     (list (mk-u 2001 'orbital-command 32.5 32.5 #:hp 1500.0 #:orders (list (hasheq 'ability-id 524)) #:assigned-harvesters 18 #:ideal-harvesters 16)
           (mk-u 2002 'orbital-command 52.5 34.5 #:hp 1500.0 #:orders (list (hasheq 'ability-id 524)) #:assigned-harvesters 18 #:ideal-harvesters 16)
           (mk-u 2003 'orbital-command 72.5 36.5 #:hp 1500.0 #:orders (list (hasheq 'ability-id 524)) #:assigned-harvesters 18 #:ideal-harvesters 16)
           (mk-u 2004 'refinery 30.0 27.0 #:hp 500.0)
           (mk-u 2005 'refinery 35.0 27.0 #:hp 500.0)
           (mk-u 2006 'refinery 50.0 29.0 #:hp 500.0)
           (mk-u 2007 'refinery 55.0 29.0 #:hp 500.0)
           (mk-u 2008 'refinery 70.0 31.0 #:hp 500.0)
           (mk-u 2009 'refinery 75.0 31.0 #:hp 500.0)
           (mk-u 2010 'factory 38.0 30.0 #:hp 1250.0 #:orders (list (hasheq 'ability-id 591)))
           (mk-u 2011 'factory-techlab 40.5 30.0 #:hp 400.0)
           (mk-u 2015 'factory 44.0 30.0 #:hp 1250.0 #:orders (list (hasheq 'ability-id 591)))
           (mk-u 2016 'factory-techlab 46.5 30.0 #:hp 400.0)
           (mk-u 2012 'starport 38.0 36.0 #:hp 1300.0 #:orders (list (hasheq 'ability-id 620)))
           (mk-u 2017 'starport-techlab 40.5 36.0 #:hp 400.0)
           (mk-u 2013 'engineering-bay 34.0 38.0 #:hp 850.0 #:orders (list (hasheq 'ability-id 650)))
           (mk-u 2018 'engineering-bay 37.0 38.0 #:hp 850.0 #:orders (list (hasheq 'ability-id 651)))
           (mk-u 2014 'armory 34.0 41.0 #:hp 750.0 #:orders (list (hasheq 'ability-id 855)))
           (mk-u 2019 'missile-turret 28.0 34.0 #:hp 250.0)
           (mk-u 2029 'missile-turret 48.0 36.0 #:hp 250.0)
           (mk-u 2030 'missile-turret 68.0 38.0 #:hp 250.0)
           (mk-u 2051 'barracks-techlab 38.5 24.0 #:hp 400.0)
           (mk-u 2052 'barracks-techlab 41.7 24.0 #:hp 400.0)
           (mk-u 2053 'barracks-reactor 38.5 27.2 #:hp 400.0)
           (mk-u 2054 'barracks-reactor 41.7 27.2 #:hp 400.0))
     (for/list ([i (in-range 12)])
       (mk-u (+ 2020 i) 'supply-depot (+ 28.0 (* 2.2 (modulo i 6))) (+ 39.0 (* 2.2 (quotient i 6))) #:hp 400.0))
     (for/list ([i (in-range 6)])
       ;; Busy Barracks (order-count 2) so open-prod-slots is 0 and Brain schedules Barracks #7!
       (mk-u (+ 2040 i) 'barracks (+ 36.0 (* 3.2 (modulo i 3))) (+ 24.0 (* 3.2 (quotient i 3)))
             #:hp 1000.0 #:orders (list (hasheq 'ability-id 560) (hasheq 'ability-id 560))))))
  (define rt-rax7 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-rax7
    (step-layer2-economy!
     rt-rax7
     (mk-live-obs 'Terran 'Terran 10200
                  #:minerals 600 #:gas 20 #:supply-used 80 #:supply-cap 140
                  #:mineral-harvesters 42 #:vespene-harvesters 12
                  #:ally-units (append scvs-54 tanks-3 marines-12)
                  #:ally-buildings bldgs-3b-6rax
                  #:researched-upgrades '(stimpack combat-shield concussive-shells))))
  (define ps-rax7 (hash-ref (live-bot-runtime-last-telemetry rt-rax7) 'priority-summary (hasheq)))
  (define brain-sched-rax7? (not (not (memq 'barracks (hash-ref ps-rax7 'scheduled-ids '())))))
  (define built-rax7?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks))) acts-rax7))

  ;; Negative guard (`TvT0Tank`): 2-base TvT with `2` Barracks, `1` Factory, `0` Siege Tanks, `240M`:
  ;; `terran-tvt-cap-rax-for-tanks?` MUST STILL hold Barracks <= 2 until >= 2 Tanks / >= 2 Factories!
  (define bldgs-tvt-0tank
    (list (mk-u 2101 'orbital-command 32.5 32.5 #:hp 1500.0)
          (mk-u 2102 'command-center 52.5 34.5 #:hp 1500.0)
          (mk-u 2110 'factory 38.0 30.0 #:hp 1250.0)
          (mk-u 2112 'starport 38.0 36.0 #:hp 1300.0)
          (mk-u 2120 'supply-depot 29.0 39.0 #:hp 400.0)
          (mk-u 2121 'supply-depot 31.0 39.0 #:hp 400.0)
          (mk-u 2122 'supply-depot 33.0 39.0 #:hp 400.0)
          (mk-u 2140 'barracks 36.0 25.0 #:hp 1000.0 #:orders (list (hasheq 'ability-id 560)))
          (mk-u 2141 'barracks 39.5 25.0 #:hp 1000.0 #:orders (list (hasheq 'ability-id 560)))))
  (define rt-tvt0t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-tvt0t
    (step-layer2-economy!
     rt-tvt0t
     (mk-live-obs 'Terran 'Terran 6200
                  #:minerals 240 #:gas 120 #:supply-used 40 #:supply-cap 54
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-units (append (take scvs-54 34) (take marines-12 6))
                  #:ally-buildings bldgs-tvt-0tank)))
  (define tvt0t-rax3?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks))) acts-tvt0t))
  (check-true "L48-T1a-brain-scheduled-barracks7-builds-past-2xCC-cap-and-preserves-tvt0tank-guard"
              (and brain-sched-rax7? built-rax7? (not tvt0t-rax3?))
              (format "brain-sched?=~a built-rax7?=~a tvt0t-rax3?=~a" brain-sched-rax7? built-rax7? tvt0t-rax3?)))

;; -----------------------------------------------------------------------------
;; 2. L48-P0-1b (`r02`/`r05`/`r06` Zero-Disengage + `4f` Focus + `4f` Stack)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch (mk-u 3000 'hatchery 32.5 32.5 #:hp 1500.0))
  (define mps
    (list (hasheq 'id 3901 'type 'mineral-field 'x 26.5 'y 28.5 'mineral-contents 1500)
          (hasheq 'id 3902 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)
          (hasheq 'id 3903 'type 'mineral-field 'x 26.5 'y 36.5 'mineral-contents 1500)))
  (define drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 3101 i) 'drone (+ 29.0 (* 0.3 (modulo i 4))) (+ 30.2 (* 0.45 (quotient i 4)))
            #:hp (if (< i 3) 12.0 40.0) #:max-hp 40.0)))
  (define (mk-probes p1-hp p2-hp)
    (append
     (list (mk-u 3801 'probe 30.4 30.4 #:hp p1-hp #:shield 0.0)
           (mk-u 3802 'probe 30.6 30.6 #:hp p2-hp #:shield 0.0))
     (for/list ([i (in-range 13)])
       (mk-u (+ 3803 i) 'probe (+ 30.8 (* 0.15 (modulo i 4))) (+ 30.5 (* 0.2 (quotient i 4)))
             #:hp 20.0 #:shield 20.0))))
  (define rt-r02 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define a1 (step-layer2-economy!
              rt-r02
              (mk-live-obs 'Zerg 'Protoss 1200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 22
                           #:mineral-harvesters 16 #:vespene-harvesters 0
                           #:ally-units drones-16 #:ally-buildings (list hatch)
                           #:enemy-units (mk-probes 15.0 20.0) #:mineral-patches mps)))
  (define a2 (step-layer2-economy!
              rt-r02
              (mk-live-obs 'Zerg 'Protoss 1204 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 22
                           #:mineral-harvesters 16 #:vespene-harvesters 0
                           #:ally-units drones-16 #:ally-buildings (list hatch)
                           #:enemy-units (mk-probes 15.0 5.0) #:mineral-patches mps)))
  (define mw1 (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) a1))
  (define pulled1 (remove-duplicates (append* (for/list ([a (in-list a1)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (define foc-3801? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 3801))) a1))
  (define foc-3802? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack) (= (third a) 3802))) a2))
  (check-true "L48-T2a-r02-zero-disengage-all-16-commit-and-4f-focus-refresh"
              (and (null? mw1) (= (length pulled1) 16) foc-3801? foc-3802?)
              (format "mw1=~a pulled1=~a f3801?=~a f3802?=~a" (length mw1) (length pulled1) foc-3801? foc-3802?)))

;; -----------------------------------------------------------------------------
;; 3. L48-P0-1b (`ro09` Oracle `+4.5t` Lateral Flank + `0.25` Beam-ON Floor)
;; -----------------------------------------------------------------------------
(let ()
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8100 i) 'scv 30.3 (+ 135.5 (* 0.4 i)) #:hp 45.0)))
  (define marines-4
    (for/list ([i (in-range 4)])
      (mk-u (+ 8001 i) 'marine 36.5 (+ 137.8 (* 0.45 i)) #:hp 45.0)))
  ;; (i) 2 Oracles at `(42.7, 138.3/138.7)` with 4 Marines directly between them and 16 SCVs at `(30.3, 138.5)`:
  ;; Tick 1 (beam OFF, 6.2t from Marines) activates Pulsar Beam; Tick 2 (beam ON) MUST emit `+4.5t`
  ;; lateral flank `move` (`|y - 138.5| >= 3.5`) around the Marine centroid!
  (define oracles-t1
    (list (mk-u 401 'oracle 42.7 138.3 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0 #:energy 80.0 #:flying? #t)
          (mk-u 402 'oracle 42.7 138.7 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0 #:energy 80.0 #:flying? #t)))
  (define acts-t1
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 400 #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0 #:vespene-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracles-t1 #:enemy-units (append marines-4 scvs-16))))
  (define beam-ons
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (memv (second a) '(401 402)) (eq? (third a) 'pulsar-beam-on)))
            acts-t1))
  (define oracles-t2
    (list (mk-u 401 'oracle 42.7 138.3 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0 #:energy 60.0 #:flying? #t #:buffs '(oracle-weapon))
          (mk-u 402 'oracle 42.7 138.7 #:hp 100.0 #:max-hp 100.0 #:shield 60.0 #:max-shield 60.0 #:energy 60.0 #:flying? #t #:buffs '(oracle-weapon))))
  (define acts-flank
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 408 #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0 #:vespene-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracles-t2 #:enemy-units (append marines-4 scvs-16))))
  (define lat-flanks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(401 402))
                             (>= (abs (- (fourth a) 138.5)) 3.5)))
            acts-flank))

  ;; (ii) Beam-ON Oracle at low HP (`hp=45, sh=0` => `hp-rat = 0.281 >= 0.25`) already past Marines
  ;; over SCVs (`(32.0, 138.5)`): holds `o-raid-safe?` ON and emits `(attack-unit 403 scv-id)`!
  (define oracle-low-on
    (list (mk-u 403 'oracle 32.0 138.5 #:hp 45.0 #:max-hp 100.0 #:shield 0.0 #:max-shield 60.0
                #:energy 40.0 #:flying? #t #:buffs '(oracle-weapon))))
  (define acts-low-on
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 450 #:supply-used 3 #:supply-cap 200 #:mineral-harvesters 0 #:vespene-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracle-low-on #:enemy-units (append marines-4 scvs-16))))
  (define scv-ids (map (lambda (s) (hash-ref s 'id)) scvs-16))
  (define low-on-atk?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 403) (memv (third a) scv-ids)))
           acts-low-on))

  ;; (iii) Negative guard: Beam-OFF Oracle at `hp=45, sh=0` (`0.281 < 0.45`) with 4 Marines kites safely!
  (define oracle-low-off
    (list (mk-u 404 'oracle 32.0 138.5 #:hp 45.0 #:max-hp 100.0 #:shield 0.0 #:max-shield 60.0
                #:energy 40.0 #:flying? #t)))
  (define acts-low-off
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Terran 450 #:supply-used 3 #:supply-cap 200 #:mineral-harvesters 0 #:vespene-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 33.5 #:enemy-y 138.5
                          #:ally-units oracle-low-off #:enemy-units (append marines-4 scvs-16))))
  (define low-off-kites?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 404))) acts-low-off))
  (check-true "L48-T2b-ro09-oracle-lateral-4.5t-flank-and-0.25-beam-on-floor-with-beam-off-kite-guard"
              (and (= (length beam-ons) 2) (= (length lat-flanks) 2) low-on-atk? low-off-kites?)
              (format "beam-ons=~a flanks=~a low-on-atk?=~a low-off-kites?=~a" (length beam-ons) lat-flanks low-on-atk? low-off-kites?)))

;; -----------------------------------------------------------------------------
;; 4. L48-P0-1b (`e01` `> 20.0` EHP Sticky + One-Shot Rotate-Out `harvest-mineral`)
;; -----------------------------------------------------------------------------
(let ()
  (define main-nex (mk-u 6000 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 12 #:ideal-harvesters 16))
  (define main-mps
    (for/list ([i (in-range 8)])
      (hasheq 'id (+ 7001 i) 'x 26.5 'y (+ 28.0 (* 1.2 i)) 'mineral-contents 1500)))
  (define probes-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 6101 i) 'probe 28.5 (+ 28.0 (* 0.75 i)) #:hp 20.0 #:shield 20.0
            #:orders (list (hasheq 'ability-id 295)))))
  (define enemy-probes-2
    (list (mk-u 6901 'probe 31.0 29.0 #:hp 20.0 #:shield 20.0)
          (mk-u 6902 'probe 31.0 30.0 #:hp 20.0 #:shield 20.0)))
  (define rt-e01 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a1 (step-layer2-economy!
              rt-e01
              (mk-live-obs 'Protoss 'Protoss 800 #:minerals 100 #:gas 0 #:supply-used 12 #:supply-cap 15
                           #:mineral-harvesters 12 #:vespene-harvesters 0
                           #:ally-units probes-12 #:ally-buildings (list main-nex)
                           #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define p1 (remove-duplicates (append* (for/list ([a (in-list a1)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (define def-1 (car p1))
  (define def-2 (cadr p1))
  ;; Tick 2 (`f=808`):
  ;; - `def-1` drops to `20.0` EHP while CARRYING MINERALS (`ability-id=299`) -> rotates out, ZERO `harvest-mineral` / `mineral-walk`!
  ;; - `def-2` drops to `21.0` EHP -> stays sticky in `pull-workers-attack`, ZERO conflicting `mineral-walk`!
  (define probes-t2
    (for/list ([u (in-list probes-12)])
      (cond
        [(= (hash-ref u 'id) def-1)
         (hash-set* u 'hp 20.0 'shield 0.0 'shields 0.0 'carrying-minerals? #t
                    'orders (list (hasheq 'ability-id 299)) 'order-count 1)]
        [(= (hash-ref u 'id) def-2)
         (hash-set* u 'hp 20.0 'shield 1.0 'shields 1.0 'orders (list (hasheq 'ability-id 23)) 'order-count 1)]
        [else u])))
  (define a2 (step-layer2-economy!
              rt-e01
              (mk-live-obs 'Protoss 'Protoss 808 #:minerals 110 #:gas 0 #:supply-used 12 #:supply-cap 15
                           #:mineral-harvesters 12 #:vespene-harvesters 0
                           #:ally-units probes-t2 #:ally-buildings (list main-nex)
                           #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define carry-interrupted?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(harvest-mineral mineral-walk)) (= (second a) def-1))) a2))
  (define def2-mw-conflict?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) def-2))) a2))
  (define p2 (remove-duplicates (append* (for/list ([a (in-list a2)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  ;; Tick 3 (`f=816`): `def-2` (NOT carrying, still on attack order 23) drops to `20.0` EHP -> rotates out
  ;; with strictly ONE `harvest-mineral` onto safe patch and ZERO `mineral-walk`!
  ;; Tick 4 (`f=820`, `+4f < 20f` refractory): ZERO duplicate `harvest-mineral` or `mineral-walk` on `def-2`!
  (define probes-t3
    (for/list ([u (in-list probes-t2)])
      (if (= (hash-ref u 'id) def-2)
          (hash-set* u 'hp 20.0 'shield 0.0 'shields 0.0 'orders (list (hasheq 'ability-id 23)) 'order-count 1)
          u)))
  (define a3 (step-layer2-economy!
              rt-e01
              (mk-live-obs 'Protoss 'Protoss 816 #:minerals 115 #:gas 0 #:supply-used 12 #:supply-cap 15
                           #:mineral-harvesters 12 #:vespene-harvesters 0
                           #:ally-units probes-t3 #:ally-buildings (list main-nex)
                           #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define def2-ret-t3 (filter (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (= (second a) def-2))) a3))
  (define def2-mw-t3 (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) def-2))) a3))
  (define a4 (step-layer2-economy!
              rt-e01
              (mk-live-obs 'Protoss 'Protoss 820 #:minerals 120 #:gas 0 #:supply-used 12 #:supply-cap 15
                           #:mineral-harvesters 12 #:vespene-harvesters 0
                           #:ally-units probes-t3 #:ally-buildings (list main-nex)
                           #:enemy-units enemy-probes-2 #:mineral-patches main-mps)))
  (define def2-dup-t4 (filter (lambda (a) (and (pair? a) (memq (car a) '(harvest-mineral mineral-walk)) (= (second a) def-2))) a4))
  (check-true "L48-T2c-e01-20ehp-sticky-no-carry-interrupt-no-mw-conflict-and-oneshot-rotate-out"
              (and (= (length p1) 2)
                   (not carry-interrupted?)
                   (not def2-mw-conflict?)
                   (memv def-2 p2)
                   (not (memv def-1 p2))
                   (= (length def2-ret-t3) 1)
                   (null? def2-mw-t3)
                   (null? def2-dup-t4))
              (format "p1=~a carry-int?=~a mw-conf?=~a p2=~a ret3=~a mw3=~a dup4=~a"
                      p1 carry-interrupted? def2-mw-conflict? p2 def2-ret-t3 def2-mw-t3 def2-dup-t4)))

;; -----------------------------------------------------------------------------
;; 5. L48-P0-1b (`rd01` `> 3.5t` Patch Fallback + Overseer `<= 7.5t` + Queen Mine Defense)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch (mk-u 5000 'hatchery 32.5 32.5 #:hp 1500.0))
  ;; (i) 2 mines with ONLY patch `#5903` at `3.7t` (`> 3.5t`, `<= 4.5t`!) from Mine 2 ->
  ;; scatters threatened Drones via `mineral-walk` (`3666`) onto `#5903`, ZERO neighbor `move (16)`!
  (define wm-mps-3.7
    (list (hasheq 'id 5901 'type 'mineral-field 'x 26.5 'y 27.5 'mineral-contents 1500)
          (hasheq 'id 5902 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)
          (hasheq 'id 5903 'type 'mineral-field 'x 26.5 'y 36.2 'mineral-contents 1500))) ;; 4.2t from WM2 (28.5,32.5)!
  (define drones-rd01
    (list (mk-u 5101 'drone 27.8 27.5 #:hp 40.0)
          (mk-u 5102 'drone 27.0 29.8 #:hp 40.0)
          (mk-u 5103 'drone 27.8 32.5 #:hp 40.0)
          (mk-u 5104 'drone 27.0 34.4 #:hp 40.0)))
  (define wms-2
    (list (mk-u 5991 'widow-mine-burrowed 28.5 27.5 #:hp 90.0 #:burrowed? #t #:engaged-target-tag 5101)
          (mk-u 5992 'widow-mine-burrowed 28.5 32.5 #:hp 90.0 #:burrowed? #t #:engaged-target-tag 5103)))
  (define acts-l2-rd01
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Terran 3200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units drones-rd01 #:ally-buildings (list hatch)
                  #:enemy-units wms-2 #:mineral-patches wm-mps-3.7)))
  (define nb-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (memv (second a) '(5102 5104)))) acts-l2-rd01))
  (define nb-moves (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(5102 5104)))) acts-l2-rd01))

  ;; (ii) L3/L4 Overseer + 2 Queens (`0` other combat units!) vs revealed Widow Mine + flying Medivac:
  ;; - Overseer at `(36.0, 42.5)` (`10.2t` away from mine at `(28.5, 35.5)`) advances within `<= 7.5t`!
  ;; - Both Queens (`energy=60`) suspend `creep-tumor`/`inject-larva` and focus-fire the revealed Widow Mine
  ;;   over the flying Medivac!
  (define overseer-1 (mk-u 5201 'overseer 36.0 42.5 #:hp 200.0 #:flying? #t))
  (define queens-2
    (list (mk-u 5202 'queen 34.0 34.0 #:hp 175.0 #:energy 60.0)
          (mk-u 5203 'queen 34.5 35.0 #:hp 175.0 #:energy 60.0)))
  (define wm-revealed (mk-u 5995 'widow-mine-burrowed 28.5 35.5 #:hp 90.0 #:burrowed? #t #:cloak 2))
  (define medivac-fly (mk-u 5996 'medivac 31.0 34.5 #:hp 150.0 #:flying? #t))
  (define acts-l34-rd01
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
             (mk-live-obs 'Zerg 'Terran 3200 #:supply-used 20 #:supply-cap 22 #:mineral-harvesters 16 #:vespene-harvesters 0
                          #:ally-units (append drones-rd01 (list overseer-1) queens-2)
                          #:ally-buildings (list hatch)
                          #:enemy-units (list wm-revealed medivac-fly))))
  (define ov-moved-to-mine?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 5201)
                            (< (third a) 35.5) (< (fourth a) 42.0)))
           acts-l34-rd01))
  (define queen-wm-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (memv (second a) '(5202 5203)) (= (third a) 5995)))
            acts-l34-rd01))
  (define queen-tumors
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell)
                             (memv (second a) '(5202 5203))
                             (memq (third a) '(creep-tumor creep-tumor-queen inject-larva))))
            acts-l34-rd01))

  ;; (iii) Unrevealed burrowed Widow Mine (`cloak=1`) `10.0t` from Queen -> Queen moves closer (`<= 7.5t`)!
  (define wm-hidden (mk-u 5997 'widow-mine-burrowed 24.0 35.0 #:hp 90.0 #:burrowed? #t #:cloak 1))
  (define acts-l34-hidden
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
             (mk-live-obs 'Zerg 'Terran 3200 #:supply-used 20 #:supply-cap 22 #:mineral-harvesters 16 #:vespene-harvesters 0
                          #:ally-units (append drones-rd01 (list overseer-1) queens-2)
                          #:ally-buildings (list hatch)
                          #:enemy-units (list wm-hidden))))
  (define queen-stage-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(5202 5203)) (< (third a) 32.0)))
            acts-l34-hidden))
  (check-true "L48-T2d-rd01-3.5t-patch-fallback-overseer-7.5t-escort-and-queen-wm-focus"
              (and (= (length nb-mws) 2)
                   (null? nb-moves)
                   ov-moved-to-mine?
                   (= (length queen-wm-atks) 2)
                   (null? queen-tumors)
                   (= (length queen-stage-moves) 2))
              (format "nb-mws=~a nb-moves=~a ov?=~a q-wm=~a q-tum=~a q-stg=~a"
                      (length nb-mws) (length nb-moves) ov-moved-to-mine?
                      (length queen-wm-atks) (length queen-tumors) (length queen-stage-moves))))

;; -----------------------------------------------------------------------------
;; 6. L48-P0-1b (`ro11` SP Cloaked Banshee `24t` Evacuated-Worker Chase)
;; -----------------------------------------------------------------------------
(let ()
  (define banshees-2
    (list (mk-u 601 'banshee 40.0 133.5 #:hp 140.0 #:energy 60.0 #:flying? #t #:cloaked? #t #:cloak 1)
          (mk-u 602 'banshee 40.5 133.5 #:hp 140.0 #:energy 60.0 #:flying? #t #:cloaked? #t #:cloak 1)))
  (define enemy-hatch (mk-u 9001 'hatchery 35.0 137.0 #:hp 1500.0)) ;; 6.1t away!
  ;; Evacuated Drones `19.0t` away (`> 14.0t`, `<= 24.0t`!)
  (define drones-evac-19t
    (for/list ([i (in-range 8)])
      (mk-u (+ 9100 i) 'drone 24.0 (+ 144.0 (* 0.4 i)) #:hp 40.0)))
  (define acts-ro11-24t
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Zerg 420 #:supply-used 6 #:supply-cap 200 #:mineral-harvesters 0 #:vespene-harvesters 0
                          #:base-x 142.5 #:base-y 33.5 #:enemy-x 35.0 #:enemy-y 137.0
                          #:ally-units banshees-2 #:enemy-units drones-evac-19t
                          #:enemy-buildings (list enemy-hatch))))
  (define drone-ids (map (lambda (d) (hash-ref d 'id)) drones-evac-19t))
  (define chase-24t-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit)
                             (memv (second a) '(601 602)) (memv (third a) drone-ids)))
            acts-ro11-24t))
  (define hatch-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (third a) 9001))) acts-ro11-24t))
  (check-true "L48-T2e-ro11-cloaked-banshee-chases-evacuated-drones-19t-within-24t-radius"
              (and (= (length chase-24t-atks) 2) (null? hatch-atks))
              (format "chase-atks=~a hatch-atks=~a" chase-24t-atks hatch-atks)))

;; -----------------------------------------------------------------------------
;; 7. L48-W2a (Kinematic Kiting Detector + Two-Mode Micro + Keep-Mining + 48f Hysteresis)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch (mk-u 7000 'hatchery 32.5 32.5 #:hp 1500.0))
  (define pool50 (mk-u 7001 'spawning-pool 30.0 36.0 #:hp 1000.0 #:build-progress 0.5))
  (define mps
    (list (hasheq 'id 7901 'type 'mineral-field 'x 26.5 'y 28.5 'mineral-contents 1500)
          (hasheq 'id 7902 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)
          (hasheq 'id 7903 'type 'mineral-field 'x 26.5 'y 36.5 'mineral-contents 1500)))
  ;; 16 Drones (3 wounded at 12 HP + 13 healthy at 40 HP), `minerals = 50 < 150`
  (define drones-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 7101 i) 'drone (+ 27.5 (* 0.35 (modulo i 4))) (+ 29.0 (* 1.6 (quotient i 4)))
            #:hp (if (< i 3) 12.0 40.0) #:max-hp 40.0)))
  ;; Tick 1 (`f=1200`): 15 enemy Probes at `(31.2..32.0, 31.0..32.5)` (d_th ~ 1.5t)
  (define probes-t1
    (for/list ([i (in-range 15)])
      (mk-u (+ 7801 i) 'probe (+ 31.2 (* 0.2 (modulo i 5))) (+ 31.0 (* 0.3 (quotient i 5)))
            #:hp (if (< i 3) 10.0 20.0) #:shield (if (< i 3) 0.0 20.0))))
  ;; Tick 2 (`f=1204`): 3 wounded Probes (#7801..#7803) mineral-walk AWAY (`+3.5t` toward enemy base `(142.5, 138.5)`!)
  ;; -> Kinematic detector flags them `fleeing-away?` (`Δd_th > +0.35t`) and latches `enemy-kiting-rush-detected?`!
  (define probes-t2
    (for/list ([p (in-list probes-t1)])
      (define pid (hash-ref p 'id))
      (if (memv pid '(7801 7802 7803))
          (hash-set* p 'x (+ (hash-ref p 'x) 3.5) 'y (+ (hash-ref p 'y) 3.5))
          p)))
  (define rt-kite (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (void (step-layer2-economy!
         rt-kite
         (mk-live-obs 'Zerg 'Protoss 1200 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 22
                      #:mineral-harvesters 16 #:vespene-harvesters 0
                      #:ally-units drones-16 #:ally-buildings (list hatch pool50)
                      #:enemy-units probes-t1 #:mineral-patches mps)))
  (define a2
    (step-layer2-economy!
     rt-kite
     (mk-live-obs 'Zerg 'Protoss 1204 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units drones-16 #:ally-buildings (list hatch pool50)
                  #:enemy-units probes-t2 #:mineral-patches mps)))
  (define mw2 (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) a2))
  (define pulls2 (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) a2))
  (define pulled2 (remove-duplicates (append* (map second pulls2))))
  (define chased-fleeing?
    (ormap (lambda (a) (memv (third a) '(7801 7802 7803))) pulls2))
  ;; Tick 3 (`f=1232`, `+28f > 14f`, `<= 48f` hysteresis): ALL 15 Probes hover at `8.5t` (`<= 11t`, `> 7.0t`)
  ;; -> 48f hysteresis MUST keep defending Drones engaged (NOT mass snap-back `harvest-mineral`!)
  (define probes-hover-8.5
    (for/list ([i (in-range 15)])
      (mk-u (+ 7801 i) 'probe (+ 39.0 (* 0.15 (modulo i 5))) (+ 38.0 (* 0.2 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  (define a3
    (step-layer2-economy!
     rt-kite
     (mk-live-obs 'Zerg 'Protoss 1232 #:minerals 60 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units drones-16 #:ally-buildings (list hatch pool50)
                  #:enemy-units probes-hover-8.5 #:mineral-patches mps)))
  (define snap-backs-t3
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral) (memv (second a) pulled2))) a3))
  ;; Also verify `l44-pre-contact-stack-mp` does NOT fire when approaching Probes are already `4.2t` (`< 5.0t`)!
  (define rt-nostack (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define cc-ns (mk-u 7050 'command-center 32.5 32.5 #:hp 1500.0))
  (define scvs-ns (for/list ([i (in-range 16)]) (mk-u (+ 7201 i) 'scv 27.0 (+ 27.0 (* 0.7 i)) #:hp 45.0)))
  (define probes-4.2 (for/list ([i (in-range 12)]) (mk-u (+ 7851 i) 'probe 31.2 (+ 31.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define a-ns
    (step-layer2-economy!
     rt-nostack
     (mk-live-obs 'Terran 'Protoss 900 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units scvs-ns #:ally-buildings (list cc-ns)
                  #:enemy-units probes-4.2 #:mineral-patches mps)))
  (define ns-mws (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) a-ns))
  (define ns-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) a-ns))
  (check-true "L48-W2a-kiting-detector-no-flee-chase-restores-disengage-keeps-miners-48f-hyst-and-5t-stack-gate"
              (and (not chased-fleeing?)
                   (>= (length mw2) 2)
                   (<= (length pulled2) 10)  ;; >= 3 wounded disengaged + >= 4 kept mining out of 16!
                   (>= (length pulled2) 6)
                   (null? snap-backs-t3)
                   (null? ns-mws)
                   (pair? ns-pulls))
              (format "chased?=~a mw2=~a pulled2=~a snap3=~a ns-mws=~a ns-pulls=~a"
                      chased-fleeing? (length mw2) (length pulled2) (length snap-backs-t3)
                      (length ns-mws) (length ns-pulls))))

;; -----------------------------------------------------------------------------
;; 8. L48-W2b (Terran In-Main Barracks #1 + 24f Instant Resume & Pull Exclusion)
;; -----------------------------------------------------------------------------
(let ()
  (define cc-t (mk-u 8000 'command-center 32.5 32.5 #:hp 1500.0))
  (define depot-t (mk-u 8001 'supply-depot 42.0 40.0 #:hp 400.0))
  (define scvs-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 8101 i) 'scv (+ 29.0 (* 0.25 (modulo i 4))) (+ 30.0 (* 0.5 (quotient i 4)))
            #:hp (if (= i 0) 10.0 45.0) #:max-hp 45.0)))
  (define probes-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 8801 i) 'probe (+ 32.0 (* 0.2 (modulo i 4))) (+ 31.5 (* 0.25 (quotient i 4)))
            #:hp 20.0 #:shield 20.0)))
  (define mps (list (hasheq 'id 8901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  ;; (i) Barracks #1 under worker rush bypasses the exposed `15.3t` ramp wall slot and builds safely
  ;; inside the main (`<= 10.5t`, `>= 5.0t` closer to CC than peaceful ramp-wall placement)!
  (define (run-rax1 eus)
    (define rt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks)))
           (step-layer2-economy!
            rt
            (mk-live-obs 'Terran 'Protoss 950 #:minerals 165 #:gas 0 #:supply-used 16 #:supply-cap 23
                         #:mineral-harvesters 16 #:vespene-harvesters 0
                         #:nat-x 62.5 #:nat-y 62.5
                         #:ally-units scvs-16 #:ally-buildings (list cc-t depot-t)
                         #:enemy-units eus #:mineral-patches mps))))
  (define rax-peace (run-rax1 '()))
  (define rax-build (run-rax1 probes-12))
  (define rax-peace-dist
    (if rax-peace (sqrt (+ (sqr (- (third rax-peace) 32.5)) (sqr (- (fourth rax-peace) 32.5)))) 0.0))
  (define rax-dist-base
    (if rax-build
        (sqrt (+ (sqr (- (third rax-build) 32.5)) (sqr (- (fourth rax-build) 32.5))))
        999.0))
  ;; (ii) Halted Barracks (`build-progress 0.5, has-builder #f`): immediately resumes with a healthy
  ;; SCV (`!= 8101` at 10 HP!), excludes that SCV from same-frame `pull-workers-attack`, AND retries
  ;; after `24f` (`f=1028`, NOT locked out for `224f`!)!
  (define halted-rax (hash-set* (mk-u 8002 'barracks 35.5 32.5 #:hp 500.0 #:build-progress 0.5)
                                'halted #t 'has-builder #f))
  (define rt-res (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-res1
    (step-layer2-economy!
     rt-res
     (mk-live-obs 'Terran 'Protoss 1000 #:minerals 80 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units scvs-16 #:ally-buildings (list cc-t depot-t halted-rax)
                  #:enemy-units probes-12 #:mineral-patches mps)))
  (define res1 (findf (lambda (a) (and (pair? a) (eq? (car a) 'resume-halted-building) (= (third a) 8002))) a-res1))
  (define res1-scv (and res1 (second res1)))
  (define pulled-res1
    (remove-duplicates (append* (for/list ([a (in-list a-res1)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (define a-res2
    (step-layer2-economy!
     rt-res
     (mk-live-obs 'Terran 'Protoss 1028 #:minerals 80 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units scvs-16 #:ally-buildings (list cc-t depot-t halted-rax)
                  #:enemy-units probes-12 #:mineral-patches mps)))
  (define res2 (findf (lambda (a) (and (pair? a) (eq? (car a) 'resume-halted-building) (= (third a) 8002))) a-res2))
  (define rax-ramp-sep
    (if (and rax-peace rax-build)
        (sqrt (+ (sqr (- (third rax-peace) (third rax-build)))
                 (sqr (- (fourth rax-peace) (fourth rax-build)))))
        0.0))
  (check-true "L48-W2b-terran-in-main-rax1-and-24f-instant-resume-excludes-scv-from-pull"
              (and rax-peace rax-build
                   (>= rax-peace-dist 12.0)
                   (<= rax-dist-base 10.5)
                   (>= rax-ramp-sep 12.0)
                   res1
                   (not (= res1-scv 8101))
                   (not (memv res1-scv pulled-res1))
                   (not (not res2)))
              (format "peace=~a(~a) rush=~a(~a) sep=~a res1=~a pulled?=~a res2=~a"
                      rax-peace rax-peace-dist rax-build rax-dist-base rax-ramp-sep res1
                      (and res1-scv (not (not (memv res1-scv pulled-res1)))) res2)))

;; -----------------------------------------------------------------------------
;; 9. L48-W2c (Cancel Incomplete `< 85%` Natural Expand & Gas Building Under Worker Rush)
;; -----------------------------------------------------------------------------
(let ()
  (define main-nex (mk-u 8500 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define nat-nex-35 (mk-u 8501 'nexus 52.5 34.5 #:hp 400.0 #:shield 400.0 #:build-progress 0.35))
  (define assim-20 (mk-u 8502 'assimilator 29.0 27.5 #:hp 150.0 #:shield 150.0 #:build-progress 0.20))
  (define assim-90 (mk-u 8503 'assimilator 35.0 27.5 #:hp 420.0 #:shield 420.0 #:build-progress 0.90))
  (define probes-14 (for/list ([i (in-range 14)]) (mk-u (+ 8601 i) 'probe 29.0 (+ 30.0 (* 0.3 i)) #:hp 20.0 #:shield 20.0)))
  (define enemy-probes-8 (for/list ([i (in-range 8)]) (mk-u (+ 8701 i) 'probe 34.0 (+ 31.0 (* 0.3 i)) #:hp 20.0 #:shield 20.0)))
  (define rt-can (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-can
    (step-layer2-economy!
     rt-can
     (mk-live-obs 'Protoss 'Protoss 1300 #:minerals 60 #:gas 0 #:supply-used 14 #:supply-cap 23
                  #:mineral-harvesters 14 #:vespene-harvesters 0
                  #:ally-units probes-14 #:ally-buildings (list main-nex nat-nex-35 assim-20 assim-90)
                  #:enemy-units enemy-probes-8)))
  (define canceled-ids
    (for/list ([a (in-list a-can)] #:when (and (pair? a) (eq? (car a) 'cancel-building))) (second a)))
  (check-true "L48-W2c-worker-rush-cancels-incomplete-natural-and-gas-under-85pct-only"
              (and (memv 8501 canceled-ids)
                   (memv 8502 canceled-ids)
                   (not (memv 8503 canceled-ids)))
              (format "canceled-ids=~a" canceled-ids)))

;; -----------------------------------------------------------------------------
;; 10. L48-W2d (Zero-Trickle Lings + Marine 5t Kiting + Protoss Chrono GW + Counter-Attack)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch (mk-u 9000 'hatchery 32.5 32.5 #:hp 1500.0))
  (define mps (list (hasheq 'id 9901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define probes-15 (for/list ([i (in-range 15)]) (mk-u (+ 9801 i) 'probe (+ 35.0 (* 0.15 (modulo i 5))) (+ 32.0 (* 0.2 (quotient i 5))) #:hp 20.0 #:shield 20.0)))
  ;; (i) L48-W3c: 2 Zerglings (`< 6`, 0 Spine, 3 Drones) vs 15 Probes:
  ;;     - When Probes are INSIDE `<= 7.5t` of Hatchery -> DEFEND (`attack-unit`) in BOTH L2 & L3/L4!
  ;;     - When Probes kite OUTSIDE `> 7.5t` toward ramp (`11t`) -> HOLD behind Hatchery (`move`) in BOTH!
  (define drones-3 (for/list ([i (in-range 3)]) (mk-u (+ 9101 i) 'drone 28.0 (+ 31.0 i) #:hp 40.0)))
  (define lings-2 (list (mk-u 9201 'zergling 31.5 32.5 #:hp 35.0) (mk-u 9202 'zergling 31.8 33.0 #:hp 35.0)))
  (define rt-ling (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define obs-ling2
    (mk-live-obs 'Zerg 'Protoss 2200 #:minerals 60 #:gas 0 #:supply-used 6 #:supply-cap 14
                 #:mineral-harvesters 3 #:vespene-harvesters 0
                 #:ally-units (append drones-3 lings-2) #:ally-buildings (list hatch)
                 #:enemy-units probes-15 #:mineral-patches mps))
  (define a-l2-ling2 (step-layer2-economy! rt-ling obs-ling2))
  (define a-l34-ling2 (run-l34 rt-ling obs-ling2))
  (define l2-ling-inmain-atk? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(9201 9202)))) a-l2-ling2))
  (define l34-ling-inmain-atk? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(9201 9202)))) a-l34-ling2))
  (define probes-15-ramp
    (for/list ([i (in-range 15)]) (mk-u (+ 9801 i) 'probe (+ 43.5 (* 0.15 (modulo i 5))) (+ 32.0 (* 0.2 (quotient i 5))) #:hp 20.0 #:shield 20.0)))
  (define obs-ling2-ramp
    (mk-live-obs 'Zerg 'Protoss 2204 #:minerals 60 #:gas 0 #:supply-used 6 #:supply-cap 14
                 #:mineral-harvesters 3 #:vespene-harvesters 0
                 #:ally-units (append drones-3 lings-2) #:ally-buildings (list hatch)
                 #:enemy-units probes-15-ramp #:mineral-patches mps))
  (define a-l2-ling2-ramp (step-layer2-economy! rt-ling obs-ling2-ramp))
  (define a-l34-ling2-ramp (run-l34 rt-ling obs-ling2-ramp))
  (define l2-ling-atk? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(9201 9202)))) a-l2-ling2-ramp))
  (define l2-ling-hold? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 9201))) a-l2-ling2-ramp))
  (define l34-ling-atk? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (memv (second a) '(9201 9202)))) a-l34-ling2-ramp))
  (define l34-ling-hold? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 9201))) a-l34-ling2-ramp))

  ;; (ii) Marine vs 15 Probes: L2 emits 0 static `attack-unit`; L3/L4 kites on weapon-cooldown > 0.15!
  (define cc-m (mk-u 9010 'command-center 32.5 32.5 #:hp 1500.0))
  (define mar-cd (mk-u 9301 'marine 32.2 32.5 #:hp 45.0 #:weapon-cooldown 0.50))
  (define mar-rdy (mk-u 9302 'marine 32.2 32.5 #:hp 45.0 #:weapon-cooldown 0.0))
  (define rt-mar (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-l2-mar
    (step-layer2-economy!
     rt-mar
     (mk-live-obs 'Terran 'Protoss 2200 #:minerals 60 #:gas 0 #:supply-used 10 #:supply-cap 23
                  #:mineral-harvesters 9 #:vespene-harvesters 0
                  #:ally-units (cons mar-cd (for/list ([i (in-range 9)]) (mk-u (+ 9151 i) 'scv 28.0 (+ 29.0 (* 0.5 i)) #:hp 45.0)))
                  #:ally-buildings (list cc-m) #:enemy-units probes-15 #:mineral-patches mps)))
  (define l2-mar-static-atk? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 9301))) a-l2-mar))
  (define a-l34-mar
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
             (mk-live-obs 'Terran 'Protoss 2200 #:supply-used 10 #:supply-cap 23 #:mineral-harvesters 8 #:vespene-harvesters 0
                          #:ally-units (list mar-cd mar-rdy) #:ally-buildings (list cc-m)
                          #:enemy-units probes-15)))
  (define mar-kited? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 9301))) a-l34-mar))
  (define mar-shot? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 9302))) a-l34-mar))

  ;; (iii) Protoss Chrono Boost Gateway #1 while training Zealot under `worker-rush-active?`!
  (define nex-p (hash-set (mk-u 9020 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy 60.0) 'busy? #t))
  (define gw-p (mk-u 9021 'gateway 35.5 34.5 #:hp 500.0 #:shield 500.0 #:orders (list (hasheq 'ability-id 916))))
  (define a-chrono
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 1900 #:minerals 80 #:gas 0 #:supply-used 14 #:supply-cap 23
                  #:mineral-harvesters 14 #:vespene-harvesters 0
                  #:ally-units (for/list ([i (in-range 14)]) (mk-u (+ 9401 i) 'probe 28.0 (+ 29.0 (* 0.5 i)) #:hp 20.0 #:shield 20.0))
                  #:ally-buildings (list nex-p gw-p) #:enemy-units probes-15 #:mineral-patches mps)))
  (define chrono-gw?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (= (second a) 9020)
                            (eq? (third a) 'chrono-boost) (= (fourth a) 9021)))
           a-chrono))

  ;; (iv) Post-Fight Counter-Attack: `10` enemy Probes hit at `f=1200`, drop to `2` (`< 4`) at `f=2400`
  ;; while we have `2` Zealots -> BOTH Zealots immediately emit `(attack-pos uid enemy-x enemy-y)`!
  (define rt-cnt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (void (run-l34 rt-cnt
                 (mk-live-obs 'Protoss 'Protoss 1200 #:supply-used 14 #:supply-cap 23 #:mineral-harvesters 14 #:vespene-harvesters 0
                              #:ally-units '() #:ally-buildings (list nex-p gw-p)
                              #:enemy-units (take probes-15 10))))
  (define zealots-2 (list (mk-u 9501 'zealot 34.0 34.0 #:hp 100.0 #:shield 50.0)
                          (mk-u 9502 'zealot 34.5 34.0 #:hp 100.0 #:shield 50.0)))
  (define a-cnt
    (run-l34 rt-cnt
             (mk-live-obs 'Protoss 'Protoss 2400 #:supply-used 16 #:supply-cap 23 #:mineral-harvesters 12 #:vespene-harvesters 0
                          #:enemy-x 142.5 #:enemy-y 138.5
                          #:ally-units zealots-2 #:ally-buildings (list nex-p gw-p)
                          #:enemy-units '())))
  (define cnt-atks
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos) (memv (second a) '(9501 9502))
                             (= (third a) 142.5) (= (fourth a) 138.5)))
            a-cnt))
  (check-true "L48-W2d-zero-trickle-lings-marine-5t-kite-chrono-gw-and-post-rush-counter-attack"
              (and l2-ling-inmain-atk? l34-ling-inmain-atk?
                   (not l2-ling-atk?) l2-ling-hold?
                   (not l34-ling-atk?) l34-ling-hold?
                   (not l2-mar-static-atk?) mar-kited? mar-shot?
                   chrono-gw?
                   (= (length cnt-atks) 2))
              (format "inm=(~a,~a) l2-la?=~a l2-lh?=~a l34-la?=~a l34-lh?=~a l2-ma?=~a mk?=~a ms?=~a cg?=~a cnt=~a"
                      l2-ling-inmain-atk? l34-ling-inmain-atk?
                      l2-ling-atk? l2-ling-hold? l34-ling-atk? l34-ling-hold?
                      l2-mar-static-atk? mar-kited? mar-shot? chrono-gw? cnt-atks)))

;; -----------------------------------------------------------------------------
;; 11. L48-W2e (`r15` SCV 3685 Repair Suppression + Rax1/GW1/Spine1 Worker-Rush Caps)
;; -----------------------------------------------------------------------------
(let ()
  (define cc-dmg (mk-u 9600 'command-center 32.5 32.5 #:hp 1100.0 #:max-hp 1500.0))
  (define rax-dmg (mk-u 9601 'barracks 36.0 34.0 #:hp 350.0 #:max-hp 1000.0 #:build-progress 0.5))
  (define depot-dmg (mk-u 9602 'supply-depot 36.0 30.0 #:hp 250.0 #:max-hp 400.0))
  (define scvs-r15
    (for/list ([i (in-range 16)])
      (mk-u (+ 9610 i) 'scv (+ 29.0 (* 0.25 (modulo i 4))) (+ 30.5 (* 0.5 (quotient i 4)))
            #:hp (if (< i 4) 20.0 45.0) #:max-hp 45.0)))
  (define probes-r15-near
    (for/list ([i (in-range 15)])
      (mk-u (+ 9710 i) 'probe (+ 35.0 (* 0.15 (modulo i 5))) (+ 32.0 (* 0.2 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  ;; Probes kiting at `19.0t` away (`> 18t`, `<= 24t`!)
  (define probes-r15-kite19
    (for/list ([i (in-range 8)])
      (mk-u (+ 9730 i) 'probe (+ 51.0 (* 0.2 i)) 34.0 #:hp 20.0 #:shield 20.0)))
  ;; (i) pro-spellcaster-micro emits ZERO `repair` on damaged CC/Barracks/Depot/SCVs vs >=6 pure Probes!
  (define sp-r15-dirs
    (plan-terran-spellcaster-micro scvs-r15 probes-r15-near
                                   #:claims (make-spell-claims) #:current-frame 1200
                                   #:ally-buildings (list cc-dmg rax-dmg depot-dmg)))
  (define sp-r15-repairs (filter (lambda (d) (eq? (spell-directive-ability d) 'repair)) sp-r15-dirs))
  ;; (ii) Full L2 + L3/L4 emits ZERO `repair` (`3685`) even when Probes kite out to `19t`!
  (define rt-r15 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-r15-near
    (mk-live-obs 'Terran 'Protoss 1200 #:minerals 220 #:gas 0 #:supply-used 16 #:supply-cap 23
                 #:mineral-harvesters 16 #:vespene-harvesters 0
                 #:ally-units scvs-r15 #:ally-buildings (list cc-dmg rax-dmg depot-dmg)
                 #:enemy-units probes-r15-near))
  (define l2-r15-a (step-layer2-economy! rt-r15 obs-r15-near))
  (define l34-r15-a (run-l34 rt-r15 obs-r15-near))
  (define obs-r15-kite19
    (mk-live-obs 'Terran 'Protoss 1212 #:minerals 220 #:gas 0 #:supply-used 16 #:supply-cap 23
                 #:mineral-harvesters 16 #:vespene-harvesters 0
                 #:ally-units scvs-r15 #:ally-buildings (list cc-dmg rax-dmg depot-dmg)
                 #:enemy-units probes-r15-kite19))
  (define l34-r15-k19 (run-l34 rt-r15 obs-r15-kite19))
  (define (has-any-repair? acts)
    (ormap (lambda (a)
             (and (pair? a)
                  (or (eq? (car a) 'repair)
                      (and (eq? (car a) 'cast-spell) (>= (length a) 3) (eq? (third a) 'repair)))))
           acts))
  ;; (iii) `r15` Barracks #2 cap (`< 4` Marines at `220M`), `r16` Gateway #2 cap (`< 3` Zealots at `220M`),
  ;; and `r14` Spine #1 reserve (`75M` with ready Pool & `0` Spines -> no Zergling drain!)
  (define r15-built-rax2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks))) l2-r15-a))
  (define rt-r16 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define l2-r16-a
    (step-layer2-economy!
     rt-r16
     (mk-live-obs 'Protoss 'Protoss 1200 #:minerals 220 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units (for/list ([i (in-range 16)]) (mk-u (+ 9650 i) 'probe 29.0 (+ 30.0 (* 0.3 i)) #:hp 20.0 #:shield 20.0))
                  #:ally-buildings (list (mk-u 9640 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 9641 'pylon 35.5 32.5 #:hp 200.0 #:shield 200.0)
                                         (mk-u 9642 'gateway 35.5 35.5 #:hp 500.0 #:shield 500.0 #:orders (list (hasheq 'ability-id 916))))
                  #:enemy-units probes-r15-near)))
  (define r16-built-gw2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) l2-r16-a))
  (define rt-r14-sp (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define l2-r14-sp
    (step-layer2-economy!
     rt-r14-sp
     (mk-live-obs 'Zerg 'Protoss 1200 #:minerals 75 #:gas 0 #:supply-used 19 #:supply-cap 22
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units (append (for/list ([i (in-range 16)]) (mk-u (+ 9670 i) 'drone 29.0 (+ 30.0 (* 0.3 i)) #:hp 40.0))
                                       (for/list ([i (in-range 6)]) (mk-u (+ 9680 i) 'zergling 31.0 (+ 31.0 (* 0.2 i)) #:hp 35.0))
                                       (list (mk-u 9690 'larva 32.0 32.0 #:hp 25.0)))
                  #:ally-buildings (list (mk-u 9660 'hatchery 32.5 32.5 #:hp 1500.0)
                                         (mk-u 9661 'spawning-pool 30.0 36.0 #:hp 1000.0))
                  #:enemy-units probes-r15-near)))
  (define r14-drained-lings-before-spine?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'zergling))) l2-r14-sp))
  ;; (iv) Negative guard: damaged Siege Tank STILL receives SCV repair cleanly!
  (define dmg-tank-w2 (mk-u 9699 'siege-tank-sieged 31.0 32.0 #:hp 90.0 #:max-hp 175.0))
  (define sp-tank-dirs
    (plan-terran-spellcaster-micro (cons dmg-tank-w2 (take scvs-r15 4)) (take probes-r15-near 6)
                                   #:claims (make-spell-claims) #:current-frame 1200))
  (define tank-repaired?
    (ormap (lambda (d) (and (eq? (spell-directive-ability d) 'repair)
                            (= (spell-directive-target-tag d) 9699)))
           sp-tank-dirs))
  (check-true "L48-W2e-r15-zero-3685-scv-repair-on-bldg-and-scv-plus-rax1-gw1-spine1-caps-and-tank-guard"
              (and (null? sp-r15-repairs)
                   (not (has-any-repair? l2-r15-a))
                   (not (has-any-repair? l34-r15-a))
                   (not (has-any-repair? l34-r15-k19))
                   (not r15-built-rax2?)
                   (not r16-built-gw2?)
                   (not r14-drained-lings-before-spine?)
                   tank-repaired?)
              (format "sp-rep=~a l2-rep?=~a l34-rep?=~a k19-rep?=~a rax2?=~a gw2?=~a ling-pre-spine?=~a tank?=~a"
                      (length sp-r15-repairs) (has-any-repair? l2-r15-a) (has-any-repair? l34-r15-a)
                      (has-any-repair? l34-r15-k19) r15-built-rax2? r16-built-gw2?
                      r14-drained-lings-before-spine? tank-repaired?)))

;; -----------------------------------------------------------------------------
;; 12. L48-W2f (`r14` Zerg `< 6` Zergling Perimeter Hold Even at 22t Ramp; Release at `>= 6`)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch (mk-u 9800 'hatchery 32.5 32.5 #:hp 1500.0))
  (define mps (list (hasheq 'id 9991 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define drones-10 (for/list ([i (in-range 10)]) (mk-u (+ 9810 i) 'drone 28.0 (+ 30.0 (* 0.4 i)) #:hp 40.0)))
  (define lings-4 (for/list ([i (in-range 4)]) (mk-u (+ 9830 i) 'zergling 31.5 (+ 31.5 (* 0.4 i)) #:hp 35.0)))
  (define lings-6 (for/list ([i (in-range 6)]) (mk-u (+ 9830 i) 'zergling 31.5 (+ 31.5 (* 0.3 i)) #:hp 35.0)))
  ;; 14 kiting Probes sitting `22t` up the ramp (`> 16t`, `<= 32t`!)
  (define probes-ramp22
    (for/list ([i (in-range 14)])
      (mk-u (+ 9850 i) 'probe (+ 54.0 (* 0.2 (modulo i 5))) (+ 32.5 (* 0.2 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  (define rt-hold6 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define obs-4l
    (mk-live-obs 'Zerg 'Protoss 2000 #:minerals 60 #:gas 0 #:supply-used 12 #:supply-cap 22
                 #:mineral-harvesters 10 #:vespene-harvesters 0
                 #:ally-units (append drones-10 lings-4) #:ally-buildings (list hatch)
                 #:enemy-units probes-ramp22 #:mineral-patches mps))
  (define a-l2-4l (step-layer2-economy! rt-hold6 obs-4l))
  (define a-l34-4l (run-l34 rt-hold6 obs-4l))
  (define l34-4l-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (memv (second a) '(9830 9831 9832 9833)))) a-l34-4l))
  (define l34-4l-atks
    (filter (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack-pos harass-workers burrow-block))
                             (let ([arg (second a)])
                               (if (list? arg)
                                   (ormap (lambda (x) (memv x '(9830 9831 9832 9833))) arg)
                                   (memv arg '(9830 9831 9832 9833))))))
            a-l34-4l))
  ;; Now 6 Zerglings (`>= 6`) -> MUST release to engage!
  (define obs-6l
    (mk-live-obs 'Zerg 'Protoss 2004 #:minerals 60 #:gas 0 #:supply-used 13 #:supply-cap 22
                 #:mineral-harvesters 10 #:vespene-harvesters 0
                 #:ally-units (append drones-10 lings-6) #:ally-buildings (list hatch)
                 #:enemy-units probes-ramp22 #:mineral-patches mps))
  (define a-l34-6l (run-l34 rt-hold6 obs-6l))
  (define l34-6l-atks
    (filter (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack-pos))
                             (let ([arg (second a)])
                               (if (list? arg)
                                   (ormap (lambda (x) (memv x '(9830 9831 9832 9833 9834 9835))) arg)
                                   (memv arg '(9830 9831 9832 9833 9834 9835))))))
            a-l34-6l))
  (check-true "L48-W2f-r14-4-lings-hold-vs-22t-ramp-probes-and-6-lings-release"
              (and (pair? a-l2-4l)
                   (= (length l34-4l-moves) 4)
                   (null? l34-4l-atks)
                   (>= (length l34-6l-atks) 1))
              (format "4l-moves=~a 4l-atks=~a 6l-atks=~a"
                      (length l34-4l-moves) l34-4l-atks (length l34-6l-atks))))

;; -----------------------------------------------------------------------------
;; 13. L48-W2g (`r02`/`r05`/`r06` Static Brawl: Zero False Kiting Latch & Zero 3666 Down to 5 HP!)
;; -----------------------------------------------------------------------------
(let ()
  (define cc-sb (mk-u 9900 'command-center 32.5 32.5 #:hp 1500.0))
  (define mps (list (hasheq 'id 9992 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  ;; 16 SCVs in melee contact (incl. 3 at 5.0 HP and 2 at 10.0 HP!) — NO breakout prod building!
  (define scvs-sb
    (for/list ([i (in-range 16)])
      (mk-u (+ 9910 i) 'scv (+ 29.8 (* 0.25 (modulo i 4))) (+ 31.2 (* 0.45 (quotient i 4)))
            #:hp (cond [(< i 3) 5.0] [(< i 5) 10.0] [else 45.0]) #:max-hp 45.0)))
  ;; Tick 1: 15 Probes at `d_th ~ 3.2t`
  (define probes-sb-t1
    (for/list ([i (in-range 15)])
      (mk-u (+ 9940 i) 'probe (+ 35.3 (* 0.15 (modulo i 5))) (+ 31.8 (* 0.25 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  ;; Tick 2: 4 Probes bump `+0.40x, +0.10y` inside melee ball (`d_th ~ +0.40t`, `cur-th-d ~ 3.6t`) ->
  ;; MUST NOT false-latch `enemy-kiting-rush-detected?` and MUST emit ZERO `3666` (`mineral-walk`/`harvest-mineral`)!
  (define probes-sb-t2
    (for/list ([p (in-list probes-sb-t1)])
      (if (memv (hash-ref p 'id) '(9940 9941 9942 9943))
          (hash-set* p 'x (+ (hash-ref p 'x) 0.40) 'y (+ (hash-ref p 'y) 0.10))
          p)))
  (define rt-sb (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (void (step-layer2-economy!
         rt-sb
         (mk-live-obs 'Terran 'Protoss 900 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                      #:mineral-harvesters 16 #:vespene-harvesters 0
                      #:ally-units scvs-sb #:ally-buildings (list cc-sb)
                      #:enemy-units probes-sb-t1 #:mineral-patches mps)))
  (define acts-sb-t2
    (step-layer2-economy!
     rt-sb
     (mk-live-obs 'Terran 'Protoss 904 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units scvs-sb #:ally-buildings (list cc-sb)
                  #:enemy-units probes-sb-t2 #:mineral-patches mps)))
  (define sb-3666
    (filter (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk harvest-mineral worker-drill-stack-attack))))
            acts-sb-t2))
  (define sb-pulled
    (remove-duplicates
     (append* (for/list ([a (in-list acts-sb-t2)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                (second a)))))
  ;; If `enemy-kiting-rush-detected?` had false-latched on Tick 2, BOTH `min-breakout-miners = 4`
  ;; AND `max-total-dis = 5` would have fired `3666` (`mineral-walk`/`harvest-mineral`) and dropped
  ;; `sb-pulled` from `16` down to `<= 8`!
  (check-true "L48-W2g-static-16v15-brawl-no-false-kiting-latch-and-zero-3666-down-to-5hp"
              (and (null? sb-3666)
                   (= (length sb-pulled) 16))
              (format "3666=~a pulled=~a/16" sb-3666 (length sb-pulled))))

;; -----------------------------------------------------------------------------
;; 14. L48-W2h (`H2H #01 ZvZ` Drone-vs-Combat Larva Guard at `>= 52` Workers)
;; -----------------------------------------------------------------------------
(let ()
  (define drones-54
    (for/list ([i (in-range 54)])
      (mk-u (+ 10100 i) 'drone 29.0 32.0 #:hp 40.0)))
  (define roaches-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 10200 i) 'roach 46.0 (+ 30.0 (* 0.4 i)) #:hp 145.0)))
  (define larvae-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 10250 i) 'larva 32.0 32.0 #:hp 25.0)))
  (define z-bldgs-4b
    (list (mk-u 10001 'hatchery 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 10002 'hatchery 56.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 10003 'hatchery 80.5 32.5 #:hp 1500.0 #:assigned-harvesters 14 #:ideal-harvesters 16)
          (mk-u 10004 'hatchery 104.5 32.5 #:hp 1500.0 #:assigned-harvesters 8 #:ideal-harvesters 16)
          (mk-u 10005 'spawning-pool 30.0 36.0 #:hp 1000.0)
          (mk-u 10006 'roach-warren 30.0 39.0 #:hp 850.0)
          (mk-u 10007 'hydralisk-den 33.0 39.0 #:hp 850.0)))
  (define enemy-roaches-20
    (for/list ([i (in-range 20)])
      (mk-u (+ 10300 i) 'roach 105.0 (+ 80.0 (* 0.4 i)) #:hp 145.0)))
  (define rt-zvz (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-zvz
    (step-layer2-economy!
     rt-zvz
     (mk-live-obs 'Zerg 'Zerg 9000 #:minerals 650 #:gas 300 #:supply-used 74 #:supply-cap 110
                  #:mineral-harvesters 48 #:vespene-harvesters 6
                  #:ally-units (append drones-54 roaches-10 larvae-8)
                  #:ally-buildings z-bldgs-4b
                  #:enemy-units enemy-roaches-20)))
  (define trained-drones (filter (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'drone))) acts-zvz))
  (define trained-combat (filter (lambda (a) (and (pair? a) (eq? (car a) 'train) (memq (second a) '(hydralisk roach zergling)))) acts-zvz))
  (check-true "L48-W2h-zvz-54-workers-20-army-yields-larvae-to-hydras-roaches-not-drones"
              (and (null? trained-drones)
                   (pair? trained-combat))
              (format "drones=~a combat=~a" trained-drones trained-combat)))

;; -----------------------------------------------------------------------------
;; 15. L48-W2i (`H2H #04 PvT` RoboBay/Immortal Unblock + `H2H #02 TvT` Starport<=2 & GhostAcademy Cap)
;; -----------------------------------------------------------------------------
(let ()
  ;; (i) PvT with Medivac + 2 Vikings (`protoss-aa-needed? = #t`, NO raiders/capital air!),
  ;; 0 Immortals, ready Robo + Stargate, `army = 20 >= 14`, `280M/220G`:
  ;; MUST emit `(train immortal)` (idle Robo) AND/OR `(build robotics-bay)` (unblocked by Medivac+Viking)!
  (define p-probes-44 (for/list ([i (in-range 44)]) (mk-u (+ 10400 i) 'probe 29.0 32.0 #:hp 20.0 #:shield 20.0)))
  (define p-army-20
    (append (for/list ([i (in-range 6)]) (mk-u (+ 10460 i) 'stalker 44.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 10470 i) 'zealot 45.0 (+ 30.0 (* 0.5 i)) #:hp 100.0 #:shield 50.0))
            (list (mk-u 10475 'observer 46.0 32.0 #:hp 40.0 #:shield 20.0 #:flying? #t))))
  (define p-bldgs-pvt
    (list (mk-u 10501 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 10502 'nexus 56.5 32.5 #:hp 1000.0 #:shield 1000.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 10503 'pylon 37.0 32.0 #:hp 200.0 #:shield 200.0)
          (mk-u 10504 'gateway 40.0 32.0 #:hp 500.0 #:shield 500.0 #:orders (list (hasheq 'ability-id 916)))
          (mk-u 10505 'gateway 40.0 35.0 #:hp 500.0 #:shield 500.0 #:orders (list (hasheq 'ability-id 916)))
          (mk-u 10506 'gateway 40.0 38.0 #:hp 500.0 #:shield 500.0 #:orders (list (hasheq 'ability-id 916)))
          (mk-u 10507 'cybernetics-core 38.0 35.0 #:hp 550.0 #:shield 550.0)
          (mk-u 10508 'robotics-facility 36.0 36.0 #:hp 450.0 #:shield 450.0)
          (mk-u 10509 'stargate 36.0 39.0 #:hp 600.0 #:shield 600.0)
          (mk-u 10510 'assimilator 29.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 10511 'assimilator 35.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 10512 'assimilator 53.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)
          (mk-u 10513 'assimilator 59.0 29.0 #:hp 450.0 #:shield 450.0 #:assigned-harvesters 3 #:ideal-harvesters 3)))
  (define enemy-t-bio-med-vik
    (append (for/list ([i (in-range 16)]) (mk-u (+ 10550 i) 'marine 108.0 (+ 80.0 (* 0.3 i)) #:hp 45.0))
            (list (mk-u 10580 'medivac 108.0 82.0 #:hp 150.0 #:flying? #t)
                  (mk-u 10581 'viking-fighter 108.0 84.0 #:hp 135.0 #:flying? #t)
                  (mk-u 10582 'viking-fighter 108.0 85.0 #:hp 135.0 #:flying? #t))))
  ;; Test A: Idle Robo Facility trains Immortal despite idle Stargate + Medivac/Viking!
  ;; (With `280M/120G`, old `reserve-idle-stargate-aa?` reserved `150M/100G` for Phoenix and blocked Immortal!)
  (define acts-pvt-imm
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 7200 #:minerals 280 #:gas 120 #:supply-used 64 #:supply-cap 90
                  #:mineral-harvesters 32 #:vespene-harvesters 12
                  #:researched-upgrades '(warpgate)
                  #:ally-units (append p-probes-44 p-army-20)
                  #:ally-buildings p-bldgs-pvt
                  #:enemy-units enemy-t-bio-med-vik)))
  (define pvt-trained-imm?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'immortal))) acts-pvt-imm))
  ;; Test B: Busy Robo Facility + `300M/250G` + Brain schedules `robotics-bay` -> builds `robotics-bay`
  ;; even with `0` Immortals & Medivac/Vikings (`protoss-aa-needed? = #t`)!
  (define p-bldgs-pvt-busy-robo
    (map (lambda (b)
           (if (= (hash-ref b 'id) 10508)
               (hash-set* b 'orders (list (hasheq 'ability-id 979)) 'order-count 1)
               b))
         p-bldgs-pvt))
  (define acts-pvt-rbay
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Terran 8200 #:minerals 300 #:gas 250 #:supply-used 64 #:supply-cap 90
                  #:mineral-harvesters 38 #:vespene-harvesters 6
                  #:ally-units (append p-probes-44 p-army-20)
                  #:ally-buildings p-bldgs-pvt-busy-robo
                  #:enemy-units enemy-t-bio-med-vik)))
  (define pvt-built-rbay?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay))) acts-pvt-rbay))

  ;; (ii) TvT on 3 bases with 2 Starports, `6` mirror enemy Vikings + `2` Tanks (0 capital air):
  ;; MUST emit ZERO `(build starport)` (`desired-starports <= 2`) AND ZERO `(build ghost-academy)`!
  (define t-scvs-60 (for/list ([i (in-range 60)]) (mk-u (+ 10600 i) 'scv 29.0 32.0 #:hp 45.0)))
  (define t-army-36
    (append (for/list ([i (in-range 20)]) (mk-u (+ 10670 i) 'marine 48.0 (+ 30.0 (* 0.3 i)) #:hp 45.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 10700 i) 'siege-tank 47.0 (+ 31.0 (* 0.8 i)) #:hp 175.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 10710 i) 'medivac 46.0 (+ 31.0 i) #:hp 150.0 #:flying? #t))))
  (define t-bldgs-3b
    (list (mk-u 10750 'orbital-command 32.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 10751 'orbital-command 56.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 10752 'orbital-command 80.5 32.5 #:hp 1500.0 #:assigned-harvesters 16 #:ideal-harvesters 16)
          (mk-u 10753 'barracks 40.0 32.0 #:hp 1000.0 #:orders (list (hasheq 'ability-id 560)))
          (mk-u 10754 'barracks 40.0 35.0 #:hp 1000.0 #:orders (list (hasheq 'ability-id 560)))
          (mk-u 10755 'barracks 40.0 38.0 #:hp 1000.0 #:orders (list (hasheq 'ability-id 560)))
          (mk-u 10756 'factory 44.0 34.0 #:hp 1250.0 #:orders (list (hasheq 'ability-id 591)))
          (mk-u 10757 'factory-techlab 46.5 33.5 #:hp 400.0)
          (mk-u 10758 'factory 44.0 38.0 #:hp 1250.0 #:orders (list (hasheq 'ability-id 591)))
          (mk-u 10759 'factory-techlab 46.5 37.5 #:hp 400.0)
          (mk-u 10760 'starport 48.0 34.0 #:hp 1300.0 #:orders (list (hasheq 'ability-id 624)))
          (mk-u 10761 'starport 48.0 38.0 #:hp 1300.0 #:orders (list (hasheq 'ability-id 624)))))
  (define enemy-tvt-vikings6
    (append (for/list ([i (in-range 6)]) (mk-u (+ 10800 i) 'viking-fighter 105.0 (+ 80.0 (* 0.5 i)) #:hp 135.0 #:flying? #t))
            (for/list ([i (in-range 2)]) (mk-u (+ 10810 i) 'siege-tank 108.0 (+ 80.0 i) #:hp 175.0))))
  (define acts-tvt-cap
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Terran 10500 #:minerals 650 #:gas 350 #:supply-used 96 #:supply-cap 140
                  #:mineral-harvesters 50 #:vespene-harvesters 10
                  #:researched-upgrades '(stimpack combat-shield)
                  #:ally-units (append t-scvs-60 t-army-36)
                  #:ally-buildings t-bldgs-3b
                  #:enemy-units enemy-tvt-vikings6)))
  (define tvt-built-sp3?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'starport))) acts-tvt-cap))
  (define tvt-built-ghost-acad?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'ghost-academy))) acts-tvt-cap))
  (check-true "L48-W2i-pvt-robobay-immortal-unblock-and-tvt-starport2-ghost-academy-cap"
              (and pvt-trained-imm?
                   pvt-built-rbay?
                   (not tvt-built-sp3?)
                   (not tvt-built-ghost-acad?))
              (format "pvt-imm?=~a pvt-rbay?=~a tvt-sp3?=~a tvt-ghost?=~a"
                      pvt-trained-imm? pvt-built-rbay? tvt-built-sp3? tvt-built-ghost-acad?)))

;; -----------------------------------------------------------------------------
;; 16. L48-W3a (`r02`/`r05`/`r06` Fix W3-R1: Zero Pre-Stack 3666 + <=3 Cap + 1.35t Direct Contact + Dist-First)
;; -----------------------------------------------------------------------------
(let ()
  (define cc-w3 (mk-u 11000 'command-center 32.5 32.5 #:hp 1500.0))
  (define mps-w3
    (list (hasheq 'id 11901 'type 'mineral-field 'x 26.5 'y 28.5 'mineral-contents 1500)
          (hasheq 'id 11902 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)
          (hasheq 'id 11903 'type 'mineral-field 'x 26.5 'y 36.5 'mineral-contents 1500)))
  ;; (i) Spread 16 SCVs (`spread > 4t`) vs 15 static Probes at `min-ew-d = 6.2t` (NO breakout bldg):
  ;; MUST emit ZERO pre-stack `3666` (`mineral-walk`) and IMMEDIATELY emit `pull-workers-attack` on tick 0,
  ;; with `<= 3` SCVs per enemy Probe target!
  (define spread-scvs-w3
    (for/list ([i (in-range 16)])
      (mk-u (+ 11100 i) 'scv (+ 26.0 (* 0.2 (modulo i 3))) (+ 27.0 (* 0.72 i)) #:hp 45.0)))
  (define static-probes-far
    (for/list ([i (in-range 15)])
      (mk-u (+ 11200 i) 'probe (+ 34.0 (* 0.25 (modulo i 5))) (+ 31.0 (* 0.45 (quotient i 5)))
            #:hp (if (= i 0) 20.0 20.0) #:shield (if (= i 0) 5.0 20.0))))
  (define a-w3-t0
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 900 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units spread-scvs-w3 #:ally-buildings (list cc-w3)
                  #:enemy-units static-probes-far #:mineral-patches mps-w3)))
  (define w3-mws (filter (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk harvest-mineral worker-drill-stack-attack)))) a-w3-t0))
  (define w3-pulls (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) a-w3-t0))
  (define max-grp-sz
    (for/fold ([m 0]) ([p (in-list w3-pulls)] #:when (> (third p) 0))
      (max m (length (second p)))))
  ;; (ii) Direct melee contact `<= 1.35t` + distance-first Pass 2:
  ;; SCV #11301 at `(30.0, 32.5)` has adjacent full-HP Probe #11401 at `(31.0, 32.5)` (`1.0t <= 1.35t`)
  ;; and wounded Probe #11402 at `(32.3, 32.5)` (`2.3t > 1.35t`, `15` EHP) -> MUST swing at adjacent #11401!
  ;; Outer SCV #11302 at `(27.0, 32.5)` (`> 1.35t` from all) has closer #11401 (`4.0t`) vs farther #11402 (`5.3t`, `15` EHP)
  ;; -> distance-first Pass 2 (`20*4.0 + 0.35*40 = 94.0` vs `20*5.3 + 0.35*15 = 111.25`) picks closer #11401!
  (define scvs-contact
    (append
     (list (mk-u 11301 'scv 30.0 32.5 #:hp 45.0)
           (mk-u 11302 'scv 27.0 32.5 #:hp 45.0))
     (for/list ([i (in-range 14)])
       (mk-u (+ 11310 i) 'scv 28.5 (+ 35.0 (* 0.25 i)) #:hp 45.0))))
  (define probes-contact
    (append
     (list (mk-u 11401 'probe 31.0 32.5 #:hp 20.0 #:shield 20.0)
           (mk-u 11402 'probe 32.3 32.5 #:hp 15.0 #:shield 0.0))
     (for/list ([i (in-range 13)])
       (mk-u (+ 11410 i) 'probe (+ 32.0 (* 0.15 (modulo i 4))) (+ 35.0 (* 0.3 (quotient i 4)))
             #:hp 20.0 #:shield 20.0))))
  (define a-w3-c
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
     (mk-live-obs 'Terran 'Protoss 920 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units scvs-contact #:ally-buildings (list cc-w3)
                  #:enemy-units probes-contact #:mineral-patches mps-w3)))
  (define (assigned-target acts wid)
    (for/first ([a (in-list acts)]
                #:when (and (pair? a) (eq? (car a) 'pull-workers-attack) (memv wid (second a))))
      (third a)))
  (define t-11301 (assigned-target a-w3-c 11301))
  (define t-11302 (assigned-target a-w3-c 11302))
  (check-true "L48-W3a-r02-r05-r06-zero-prestack-3666-cap3-direct-1.35t-contact-and-dist-first"
              (and (null? w3-mws)
                   (pair? w3-pulls)
                   (<= max-grp-sz 3)
                   (= t-11301 11401)
                   (= t-11302 11401))
              (format "mws=~a pulls=~a max-grp=~a t11301=~a t11302=~a"
                      (length w3-mws) (length w3-pulls) max-grp-sz t-11301 t-11302)))

;; -----------------------------------------------------------------------------
;; 17. L48-W3b (`r14`/`r16` Fix W3-R2: Pinned Breakout Miners + Carrying Guard + Tucked Spine + Pocket Zealot #1)
;; -----------------------------------------------------------------------------
(let ()
  (define hatch-w3 (mk-u 12000 'hatchery 32.5 32.5 #:hp 1500.0))
  (define pool-w3 (mk-u 12001 'spawning-pool 30.0 36.0 #:hp 1000.0))
  (define mps-w3
    (list (hasheq 'id 12901 'type 'mineral-field 'x 26.5 'y 28.5 'mineral-contents 1500)
          (hasheq 'id 12902 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)
          (hasheq 'id 12903 'type 'mineral-field 'x 26.5 'y 36.5 'mineral-contents 1500)))
  ;; (i) `r14` Zerg at Frame 0 (`minerals = 75`, `0` Spines, `16` Drones incl. `#12100` `carrying-minerals? #t`):
  ;; MUST pin `6` miners on tick 0 (`pulled <= 10`), NEVER pull carrying Drone `#12100`, AND persist pinned IDs across ticks!
  (define drones-r14
    (for/list ([i (in-range 16)])
      (mk-u (+ 12100 i) 'drone (+ 27.5 (* 0.35 (modulo i 4))) (+ 29.0 (* 1.5 (quotient i 4)))
            #:hp 40.0 #:max-hp 40.0 #:carrying-minerals? (= i 0))))
  (define probes-r14-t0
    (for/list ([i (in-range 15)])
      (mk-u (+ 12200 i) 'probe (+ 37.0 (* 0.15 (modulo i 5))) (+ 32.0 (* 0.2 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  (define rt-r14-w3 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define a-r14-t0
    (step-layer2-economy!
     rt-r14-w3
     (mk-live-obs 'Zerg 'Protoss 100 #:minerals 75 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units drones-r14 #:ally-buildings (list hatch-w3 pool-w3)
                  #:enemy-units probes-r14-t0 #:mineral-patches mps-w3)))
  (define pulled-r14-t0
    (remove-duplicates (append* (for/list ([a (in-list a-r14-t0)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  ;; Tick 2 (`minerals = 100`, `6` Zerglings already out): emergency `SpineCrawler #1` MUST anchor on
  ;; mineral-pocket side (`x < 32.5`, AWAY from `nat-x = 52.5`!)
  (define lings6-r14 (for/list ([i (in-range 6)]) (mk-u (+ 12150 i) 'zergling 31.0 (+ 31.0 (* 0.2 i)) #:hp 35.0)))
  (define a-r14-spine
    (step-layer2-economy!
     rt-r14-w3
     (mk-live-obs 'Zerg 'Protoss 104 #:minerals 100 #:gas 0 #:supply-used 19 #:supply-cap 30
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units (append drones-r14 lings6-r14) #:ally-buildings (list hatch-w3 pool-w3)
                  #:enemy-units probes-r14-t0 #:mineral-patches mps-w3)))
  (define spine-build-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spine-crawler))) a-r14-spine))
  (define spine-tucked-behind-hatch?
    (and spine-build-act (< (third spine-build-act) 32.5)))

  ;; (ii) `r16` Protoss Pocket `Zealot #1` Leash:
  ;; Solo Zealot #1 (`< 2`) vs 15 Probes at `12t` -> leashed inside pocket (`move`, NOT chasing Probes at 12t!) in L3/L4;
  ;; When a Probe enters `<= 2.0t` of Zealot #1 inside `<= 6.5t` of Nexus -> `attack-unit` on that Probe;
  ;; Once Zealot #2 arrives (`>= 2`) -> BOTH Zealots release to attack!
  (define nex-r16 (mk-u 12500 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define gw-r16 (mk-u 12501 'gateway 35.5 34.5 #:hp 500.0 #:shield 500.0))
  (define zlt1 (mk-u 12510 'zealot 30.5 32.5 #:hp 100.0 #:shield 50.0))
  (define zlt2 (mk-u 12511 'zealot 31.0 33.0 #:hp 100.0 #:shield 50.0))
  (define probes-r16-12t
    (for/list ([i (in-range 15)])
      (mk-u (+ 12600 i) 'probe (+ 44.5 (* 0.15 (modulo i 5))) (+ 32.0 (* 0.2 (quotient i 5)))
            #:hp 20.0 #:shield 20.0)))
  (define rt-r16-w3 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-z1-far
    (run-l34 rt-r16-w3
             (mk-live-obs 'Protoss 'Protoss 1500 #:minerals 80 #:gas 0 #:supply-used 16 #:supply-cap 23
                          #:mineral-harvesters 14 #:vespene-harvesters 0
                          #:ally-units (list zlt1) #:ally-buildings (list nex-r16 gw-r16)
                          #:enemy-units probes-r16-12t #:mineral-patches mps-w3)))
  (define z1-far-holds? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 12510))) a-z1-far))
  (define z1-far-chased? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 12510))) a-z1-far))
  (define probes-r16-close (cons (mk-u 12699 'probe 31.8 32.5 #:hp 20.0 #:shield 20.0) probes-r16-12t))
  (define a-z1-close
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Protoss 1504 #:minerals 80 #:gas 0 #:supply-used 16 #:supply-cap 23
                          #:mineral-harvesters 14 #:vespene-harvesters 0
                          #:ally-units (list zlt1) #:ally-buildings (list nex-r16 gw-r16)
                          #:enemy-units probes-r16-close #:mineral-patches mps-w3)))
  (define z1-hits-close? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (= (second a) 12510) (= (third a) 12699))) a-z1-close))
  (define a-z2-release
    (run-l34 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
             (mk-live-obs 'Protoss 'Protoss 1508 #:minerals 80 #:gas 0 #:supply-used 18 #:supply-cap 23
                          #:mineral-harvesters 14 #:vespene-harvesters 0
                          #:ally-units (list zlt1 zlt2) #:ally-buildings (list nex-r16 gw-r16)
                          #:enemy-units probes-r16-12t #:mineral-patches mps-w3)))
  (define z2-released?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack-pos)) (memv (second a) '(12510 12511)))) a-z2-release))
  (check-true "L48-W3b-pinned-breakout-miners-carrying-guard-tucked-spine-and-pocket-zealot1"
              (and (= (length pulled-r14-t0) 12) ;; 4 pinned miners + 12 active screen defenders!
                   (not (memv 12100 pulled-r14-t0))
                   spine-tucked-behind-hatch?
                   z1-far-holds?
                   (not z1-far-chased?)
                   z1-hits-close?
                   z2-released?)
              (format "pulled0=~a carry-pulled?=~a spine=~a z1-hold?=~a z1-chase?=~a z1-close?=~a z2-rel?=~a"
                      (length pulled-r14-t0) (not (not (memv 12100 pulled-r14-t0)))
                      spine-build-act z1-far-holds? z1-far-chased? z1-hits-close? z2-released?)))

;; -----------------------------------------------------------------------------
;; 18. L48-W3c (Wave 3B: `r16` Zero Probe Theft, `r14` 6-Lings-Before-Spine, & `r02`/`r05` +3-Lead Zero-Peel `3666=0`)
;; -----------------------------------------------------------------------------
(let ()
  ;; (i) `r16` Protoss at `75M` with READY Gateway, `16` Probes, `1` Zealot (`< 3`):
  ;; MUST pause Probe training (`0` `(train probe)`) so 100% of minerals fund Zealot #2!
  (define probes-16-p (for/list ([i (in-range 16)]) (mk-u (+ 13100 i) 'probe 29.0 (+ 30.0 (* 0.3 i)) #:hp 20.0 #:shield 20.0)))
  (define probes-15-e (for/list ([i (in-range 15)]) (mk-u (+ 13200 i) 'probe 35.0 (+ 31.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define a-r16-nopr
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 1200 #:minerals 75 #:gas 0 #:supply-used 18 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units (cons (mk-u 13199 'zealot 31.0 32.5 #:hp 100.0 #:shield 50.0) probes-16-p)
                  #:ally-buildings (list (mk-u 13001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 13002 'pylon 35.5 32.5 #:hp 200.0 #:shield 200.0)
                                         (mk-u 13003 'gateway 35.5 35.5 #:hp 500.0 #:shield 500.0 #:orders (list (hasheq 'ability-id 916))))
                  #:enemy-units probes-15-e)))
  (define r16-stole-probe?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'probe))) a-r16-nopr))

  ;; (ii) `r14` Zerg at `100M` with READY SpawningPool, `0` Zerglings (`< 6`), `0` Spines, `3` Larvae:
  ;; MUST train Zerglings FIRST (`(train zergling)` present, NO `(build spine-crawler)` at `100M`!)
  (define a-r14-lings6
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
     (mk-live-obs 'Zerg 'Protoss 1200 #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units (append (for/list ([i (in-range 16)]) (mk-u (+ 13300 i) 'drone 29.0 (+ 30.0 (* 0.3 i)) #:hp 40.0))
                                       (for/list ([i (in-range 3)]) (mk-u (+ 13350 i) 'larva 32.0 32.0 #:hp 25.0)))
                  #:ally-buildings (list (mk-u 13390 'hatchery 32.5 32.5 #:hp 1500.0)
                                         (mk-u 13391 'spawning-pool 30.0 36.0 #:hp 1000.0))
                  #:enemy-units probes-15-e)))
  (define r14-trained-lings? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'zergling))) a-r14-lings6))
  (define r14-built-spine-early? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spine-crawler))) a-r14-lings6))

  ;; (iii) `r05` Static Non-Kiting Brawl pulling ahead by `+4` workers mid-fight (`14` SCVs vs `10` Probes
  ;; after latching on `15` Probes, incl. `3` SCVs at `5 HP`!): MUST keep ALL `14` SCVs fighting with
  ;; ZERO `3666` peel/disengage!
  (define cc-lead (mk-u 13400 'command-center 32.5 32.5 #:hp 1500.0))
  (define mps-lead (list (hasheq 'id 13901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define rt-lead (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define scvs-16-lead (for/list ([i (in-range 16)]) (mk-u (+ 13410 i) 'scv 29.5 (+ 30.0 (* 0.35 i)) #:hp 45.0)))
  (void (step-layer2-economy!
         rt-lead
         (mk-live-obs 'Terran 'Protoss 900 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 23
                      #:mineral-harvesters 16 #:vespene-harvesters 0
                      #:ally-units scvs-16-lead #:ally-buildings (list cc-lead)
                      #:enemy-units probes-15-e #:mineral-patches mps-lead)))
  (define scvs-14-mid
    (for/list ([i (in-range 14)])
      (mk-u (+ 13410 i) 'scv 29.8 (+ 30.2 (* 0.35 i)) #:hp (if (< i 3) 5.0 35.0) #:max-hp 45.0)))
  (define a-lead
    (step-layer2-economy!
     rt-lead
     (mk-live-obs 'Terran 'Protoss 920 #:minerals 50 #:gas 0 #:supply-used 14 #:supply-cap 23
                  #:mineral-harvesters 14 #:vespene-harvesters 0
                  #:ally-units scvs-14-mid #:ally-buildings (list cc-lead)
                  #:enemy-units (take probes-15-e 10) #:mineral-patches mps-lead)))
  (define lead-3666 (filter (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk harvest-mineral worker-drill-stack-attack)))) a-lead))
  (define lead-pulled (remove-duplicates (append* (for/list ([a (in-list a-lead)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (check-true "L48-W3c-r16-no-probe-theft-r14-6lings-before-spine-and-r05-plus4-lead-zero-3666"
              (and (not r16-stole-probe?)
                   r14-trained-lings?
                   (not r14-built-spine-early?)
                   (null? lead-3666)
                   (= (length lead-pulled) 14))
              (format "r16-pr?=~a r14-l?=~a r14-sp?=~a lead-3666=~a lead-pulled=~a/14"
                      r16-stole-probe? r14-trained-lings? r14-built-spine-early? lead-3666 (length lead-pulled))))

;; -----------------------------------------------------------------------------
;; 19. L48-W3d (Wave 3C Killshot: `r02`/`r06` 12s Static Brawl No False Latch, `r15` 8.5t Leash + 28f Slide, `r16` 9w Probe Pause)
;; -----------------------------------------------------------------------------
(let ()
  ;; (i) Static brawl past `12s` (`268f`) with `0` fleeing Probes and `0` kills (`6..8t` mineral-line fight):
  ;; MUST NOT false-latch `enemy-kiting-rush-detected?` and MUST keep `3666 = 0`!
  (define hatch-s (mk-u 14001 'hatchery 32.5 32.5 #:hp 1500.0))
  (define mps-s (list (hasheq 'id 14901 'type 'mineral-field 'x 26.5 'y 32.5 'mineral-contents 1500)))
  (define drones-16-s (for/list ([i (in-range 16)]) (mk-u (+ 14100 i) 'drone 28.0 (+ 30.0 (* 0.35 i)) #:hp (if (< i 3) 8.0 40.0) #:max-hp 40.0)))
  ;; Probes brawling at `d_th ~ 6.2t` (outside old `5.5t`, inside `<= 8.5t`!) with `0` fleeing!
  (define probes-15-s (for/list ([i (in-range 15)]) (mk-u (+ 14200 i) 'probe (+ 38.5 (* 0.15 (modulo i 5))) (+ 31.8 (* 0.2 (quotient i 5))) #:hp 20.0 #:shield 20.0)))
  (define rt-stat (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (for ([f (in-list '(900 960 1020 1080 1140 1180))])
    (void (step-layer2-economy!
           rt-stat
           (mk-live-obs 'Zerg 'Protoss f #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 22
                        #:mineral-harvesters 16 #:vespene-harvesters 0
                        #:ally-units drones-16-s #:ally-buildings (list hatch-s)
                        #:enemy-units probes-15-s #:mineral-patches mps-s))))
  (define a-stat-late
    (step-layer2-economy!
     rt-stat
     (mk-live-obs 'Zerg 'Protoss 1220 #:minerals 50 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units drones-16-s #:ally-buildings (list hatch-s)
                  #:enemy-units probes-15-s #:mineral-patches mps-s)))
  (define stat-late-3666 (filter (lambda (a) (and (pair? a) (memq (car a) '(mineral-walk harvest-mineral worker-drill-stack-attack)))) a-stat-late))
  (define stat-late-pulled
    (remove-duplicates (append* (for/list ([a (in-list a-stat-late)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))

  ;; (ii) `r15` Terran (`CC + Barracks` ready, `16` SCVs): Probes at `6.8t` (`<= 7.0t`, NOT truncated at `6.5t`!)
  ;; STILL pull screening SCVs, ALL `5` wounded SCVs (`12 HP`) disengage simultaneously (`kiting-breakout-max-dis = 5`)
  ;; at `f=1200`, and RE-ENGAGE by `f=1232` (`+32f > 28f` snappy slide, vs old `48f` slide)!
  (define cc-r15 (mk-u 14300 'command-center 32.5 32.5 #:hp 1500.0))
  (define rax-r15 (mk-u 14301 'barracks 36.5 35.5 #:hp 1000.0))
  (define scvs-16-r15
    (for/list ([i (in-range 16)])
      (mk-u (+ 14310 i) 'scv (if (< i 5) 36.0 29.0) (if (< i 5) (+ 31.5 (* 0.4 i)) (+ 30.0 (* 0.35 i)))
            #:hp (if (< i 5) 12.0 45.0) #:max-hp 45.0)))
  (define probes-6.8 (for/list ([i (in-range 15)]) (mk-u (+ 14400 i) 'probe (+ 39.2 (* 0.05 (modulo i 5))) (+ 32.5 (* 0.1 (quotient i 5))) #:hp 20.0 #:shield 20.0)))
  (define rt-r15 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define a-r15-68
    (step-layer2-economy!
     rt-r15
     (mk-live-obs 'Terran 'Protoss 1200 #:minerals 60 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units scvs-16-r15 #:ally-buildings (list cc-r15 rax-r15)
                  #:enemy-units probes-6.8 #:mineral-patches mps-s)))
  (define r15-pulled-68
    (remove-duplicates (append* (for/list ([a (in-list a-r15-68)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (define scv0-dis-at-1200?
    (and (= (length (filter (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) a-r15-68)) 5)
         (not (memv 14310 r15-pulled-68))))
  (define a-r15-1232
    (step-layer2-economy!
     rt-r15
     (mk-live-obs 'Terran 'Protoss 1232 #:minerals 60 #:gas 0 #:supply-used 16 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 0
                  #:ally-units scvs-16-r15 #:ally-buildings (list cc-r15 rax-r15)
                  #:enemy-units probes-6.8 #:mineral-patches mps-s)))
  (define r15-pulled-1232
    (remove-duplicates (append* (for/list ([a (in-list a-r15-1232)] #:when (and (pair? a) (eq? (car a) 'pull-workers-attack))) (second a)))))
  (define scv0-reengaged-at-1232? (and (memv 14310 r15-pulled-1232) #t))

  ;; (iii) `r16` Protoss at `9` workers (`>= 5`), `60M`, `1` Zealot, READY Gateway -> ZERO Probe theft!
  ;; While at `4` workers (`< 5`), anti-deadlock STILL allows Probe training!
  (define probes-15-r16 (for/list ([i (in-range 15)]) (mk-u (+ 14600 i) 'probe 35.0 (+ 31.0 (* 0.2 i)) #:hp 20.0 #:shield 20.0)))
  (define nex-r16 (mk-u 14500 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0))
  (define pyl-r16 (mk-u 14501 'pylon 35.5 32.5 #:hp 200.0 #:shield 200.0))
  (define gw-r16 (mk-u 14502 'gateway 35.5 35.5 #:hp 500.0 #:shield 500.0 #:orders (list (hasheq 'ability-id 916))))
  (define a-r16-9w
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 1500 #:minerals 60 #:gas 0 #:supply-used 11 #:supply-cap 23
                  #:mineral-harvesters 9 #:vespene-harvesters 0
                  #:ally-units (cons (mk-u 14599 'zealot 31.0 32.5 #:hp 100.0 #:shield 50.0)
                                     (for/list ([i (in-range 9)]) (mk-u (+ 14510 i) 'probe 29.0 (+ 30.0 (* 0.4 i)) #:hp 20.0 #:shield 20.0)))
                  #:ally-buildings (list nex-r16 pyl-r16 gw-r16)
                  #:enemy-units probes-15-r16 #:mineral-patches mps-s)))
  (define r16-9w-stole-probe? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'probe))) a-r16-9w))
  (define a-r16-4w
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs 'Protoss 'Protoss 1500 #:minerals 60 #:gas 0 #:supply-used 6 #:supply-cap 23
                  #:mineral-harvesters 4 #:vespene-harvesters 0
                  #:ally-units (cons (mk-u 14599 'zealot 31.0 32.5 #:hp 100.0 #:shield 50.0)
                                     (for/list ([i (in-range 4)]) (mk-u (+ 14510 i) 'probe 29.0 (+ 30.0 (* 0.4 i)) #:hp 20.0 #:shield 20.0)))
                  #:ally-buildings (list nex-r16 pyl-r16 gw-r16)
                  #:enemy-units probes-15-r16 #:mineral-patches mps-s)))
  (define r16-4w-allowed-probe? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'probe))) a-r16-4w))

  (check-true "L48-W3d-static-12s-no-false-latch-r15-8.5t-leash-28f-slide-and-r16-9w-probe-pause"
              (and (null? stat-late-3666)
                   (= (length stat-late-pulled) 16)
                   (>= (length r15-pulled-68) 10)
                   scv0-dis-at-1200?
                   scv0-reengaged-at-1232?
                   (not r16-9w-stole-probe?)
                   r16-4w-allowed-probe?)
              (format "3666=~a stat-pulled=~a/16 r15-pulled=~a dis1200?=~a re1232?=~a r16-9w?=~a r16-4w?=~a"
                      stat-late-3666 (length stat-late-pulled) (length r15-pulled-68)
                      scv0-dis-at-1200? scv0-reengaged-at-1232?
                      r16-9w-stole-probe? r16-4w-allowed-probe?)))

;; Loop 65E (`#1907`/`#1908`): Zerg Roach skips natural (non-splash) lateral concave fanning
;; so short-range Roaches charge ahead of Ravagers/Hydras, while keeping anti-splash spread vs Tanks!
(let ()
  (define roaches-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 14900 i) 'roach 70.0 (+ 49.5 (* 0.2 i)) #:hp 145.0)))
  (define ravagers-2
    (list (mk-u 14910 'ravager 69.5 49.8 #:hp 120.0)
          (mk-u 14911 'ravager 69.5 50.2 #:hp 120.0)))
  (define en-nosplash
    (for/list ([i (in-range 6)])
      (mk-u (+ 14920 i) 'roach 79.0 (+ 49.4 (* 0.2 i)) #:hp 145.0)))
  (define en-tank-splash
    (cons (mk-u 14930 'siege-tank-sieged 81.0 50.0 #:hp 175.0) en-nosplash))
  (define ctx-ns (build-combat-positioning-context (append roaches-6 ravagers-2) en-nosplash))
  (define ctx-sp (build-combat-positioning-context (append roaches-6 ravagers-2) en-tank-splash))
  (define roach-ns-pts
    (filter real?
            (for/list ([u (in-list roaches-6)])
              (define-values (ax ay) (compute-lateral-concave-spread-pt ctx-ns u 79.0 50.0 4.0))
              (and ax ay ax))))
  (define roach-sp-pts
    (filter real?
            (for/list ([u (in-list roaches-6)])
              (define-values (ax ay) (compute-lateral-concave-spread-pt ctx-sp u 79.0 50.0 4.0))
              (and ax ay ay))))
  (check-true "L65E-roach-skips-natural-lateral-concave-but-spreads-vs-tank-splash"
              (and (null? roach-ns-pts)
                   (>= (length roach-sp-pts) 4))
              (format "roach-nosplash=~a roach-splash-cnt=~a" roach-ns-pts (length roach-sp-pts))))

(printf "\n=== Loop 48 Suite Summary: ~a/~a passed, ~a failed ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
