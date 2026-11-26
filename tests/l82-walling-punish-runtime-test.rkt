#lang racket/base

;; =============================================================================
;; `tests/l82-walling-punish-runtime-test.rkt`
;; Loop 82 (Release #24 Candidate) — Track D Runtime Verification Suite
;;
;; Part 1 (Self-Contained in `lib/bot-runtime.rkt`):
;;   1a: `norman` ZvP Natural-Pad Pylon Block — NO Cannon-Rush panic, holds 16-Hatch
;;       escrow at 220M, emits `(clear-expansion-block)`, and immediately takes
;;       3rd-as-Natural at 300M with 0 Spawning Pools!
;;   1b: Real Cannon Rush Escalation Guard — Forge / PhotonCannon / 2nd Pylon /
;;       in-main Pylon STILL immediately escalates to Cannon Rush / proxy defense!
;;   1c: `norman` TvP Natural-Pad Pylon Block — builds 2nd CC on high ground inside
;;       Main, then lifts completed idle in-base OC once Natural clears and lands
;;       flying OC directly on `(nat-x, nat-y)`!
;;   1d: `norman` / Pro TvP Ebay Natural-Pad Block for Protoss — NO Cannon-Rush
;;       panic, preserves Nexus escrow, and immediately expands to 3rd-as-Natural!
;;   1e: Terran Bug T1 Auto-Lift Guard — ramp-wall Barracks with `'addon-clear? #f`
;;       NEVER receives `barracks-techlab`/`barracks-reactor`; prefers Barracks #2
;;       inside Main!
;; =============================================================================

(require racket/list
         racket/math
         racket/string
         "../lib/bot-runtime.rkt"
         "../lib/sc2-game-constants.rkt"
         "../lib/tactics/order-ledger.rkt")

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
              #:hp [hp 100.0] #:max-hp [mhp hp]
              #:shield [sh 0.0] #:max-shield [msh sh]
              #:energy [en 0.0]
              #:flying [fly? #f]
              #:build-progress [bp 1.0]
              #:orders [ords '()]
              #:order-count [oc #f]
              #:order-ability-id [oab 0]
              #:order-target-id [otid 0]
              #:busy? [busy? #f]
              #:buffs [buffs '()]
              #:powered? [pow? #t])
  (define h0
    (hasheq 'id id 'type type 'x (exact->inexact x) 'y (exact->inexact y)
            'hp (exact->inexact hp) 'max-hp (exact->inexact mhp)
            'health (exact->inexact hp) 'health-max (exact->inexact mhp)
            'shield (exact->inexact sh) 'shields (exact->inexact sh)
            'max-shield (exact->inexact msh) 'max-shields (exact->inexact msh)
            'energy (exact->inexact en) 'cloak 3
            'flying fly? 'flying? fly? 'is-flying fly?
            'build-progress (exact->inexact bp)
            'orders ords 'order-ability-id oab 'order-target-id otid
            'busy? busy? 'buffs buffs 'powered? pow?
            'weapon-cooldown 0.0 'has-builder #t 'add-on-tag 0 'display-type 1))
  (if oc (hash-set h0 'order-count oc) h0))

(define (mk-workers sym n [start-id 2100] [bx 28.0] [by 30.0])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) sym
          (+ bx (* 0.15 (modulo i 16))) (+ by (* 0.25 (quotient i 16)))
          #:hp 40.0)))

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200]
                     #:gas [gas 0]
                     #:supply-used [su 16]
                     #:supply-cap [sc 22]
                     #:mineral-harvesters [mh 16]
                     #:vespene-harvesters [vh 0]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb #f]
                     #:expansion-locations [exps '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 62.5] #:nat-y [ny 32.5]
                     #:third-x [tx 32.5] #:third-y [ty 68.5]
                     #:enemy-x [ex 142.5] #:enemy-y [ey 138.5]
                     #:researched-upgrades [upgs '()]
                     #:under-attack? [ua? #f]
                     #:extra [extra (hasheq)])
  (define eff-eb
    (if eb
        eb
        (list (mk-u 9001
                    (case enemy-race
                      [(Zerg) 'hatchery]
                      [(Protoss) 'nexus]
                      [else 'orbital-command])
                    ex ey #:hp 1500.0))))
  (define h0
    (hasheq 'race race 'enemy-race enemy-race 'frame frame
            'live-game? #t 'live-obs? #t 'live-obs-harvesters? #t
            'enable-opponent-world-model #t
            'minerals minerals 'gas gas
            'supply-used su 'supply-cap sc
            'mineral-harvesters mh 'vespene-harvesters vh 'gas-harvesters vh
            'ally-units au 'ally-buildings ab
            'enemy-units eu 'enemy-buildings eff-eb
            'base-x bx 'base-y by 'nat-x nx 'nat-y ny 'natural-x nx 'natural-y ny
            'third-x tx 'third-y ty
            'enemy-x ex 'enemy-y ey
            'researched-upgrades upgs 'upgrades-tracked? #t
            'under-attack? ua? 'under-attack ua?
            'map-width 200 'map-height 200))
  (define h1
    (if (pair? exps)
        (hash-set* h0 'expansion-locations exps 'expansion-candidates exps)
        h0))
  (for/fold ([h h1]) ([(k v) (in-hash extra)])
    (hash-set h k v)))

(define (has-act? acts pred)
  (and (ormap pred acts) #t))

(define (has-build? acts sym)
  (has-act? acts (lambda (a)
                   (and (pair? a)
                        (memq (car a) '(build build-addon morph-building))
                        (>= (length a) 2)
                        (eq? (second a) sym)))))

(define (has-train? acts sym)
  (has-act? acts (lambda (a)
                   (and (pair? a)
                        (memq (car a) '(train morph-unit warp-in))
                        (>= (length a) 2)
                        (eq? (second a) sym)))))

(define (dist2 a b c d)
  (sqrt (+ (sqr (- a c)) (sqr (- b d)))))

(define exps-3 (list (list 32.5 32.5) (list 62.5 32.5) (list 32.5 68.5)))

(printf "=== Loop 82 Walling, Expansion-Block & Unwalled-Punish Runtime Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1a. `norman` ZvP Natural-Pad Pylon Block — Immediate 3rd-as-Natural (0 Pools!)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-1b
    (list (mk-u 82001 'hatchery 32.5 32.5 #:hp 1500.0)))
  (define z-units-16
    (append (mk-workers 'drone 16 82010)
            (list (mk-u 82040 'overlord 38.0 34.0 #:hp 200.0 #:flying #t)
                  (mk-u 82041 'overlord 95.0 95.0 #:hp 200.0 #:flying #t)
                  (mk-u 82042 'larva 31.0 31.0 #:hp 25.0)
                  (mk-u 82043 'larva 31.5 31.0 #:hp 25.0))))
  (define-values (e-u e-b)
    (values (list (mk-u 82090 'probe 63.5 33.0 #:hp 20.0 #:shield 20.0))
            (list (mk-u 9001 'nexus 142.5 138.5 #:hp 1000.0 #:shield 1000.0)
                  (mk-u 82091 'pylon 64.5 34.5 #:hp 200.0 #:shield 200.0 #:build-progress 0.3))))
  (define rt-z (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  ;; Tick 1 (f=1220, 220M): Must emit `(clear-expansion-block)`, MUST NOT panic-build Spawning Pool!
  (define acts-220
    (step-layer2-economy!
     rt-z
     (mk-live-obs 'Zerg 'Protoss 1220 #:minerals 220 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:expansion-locations exps-3
                  #:ally-units z-units-16 #:ally-buildings z-bldgs-1b
                  #:enemy-units e-u #:enemy-buildings e-b)))
  (define cleared-220?
    (has-act? acts-220 (lambda (a) (and (pair? a) (eq? (car a) 'clear-expansion-block)))))
  (define panicked-pool-220? (has-build? acts-220 'spawning-pool))
  ;; Tick 2 (f=1280, 300M on SAME runtime): Must immediately expand to 3rd-as-Natural (32.5, 68.5) with 0 Pools!
  (define acts-300
    (step-layer2-economy!
     rt-z
     (mk-live-obs 'Zerg 'Protoss 1280 #:minerals 300 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:expansion-locations exps-3
                  #:ally-units z-units-16 #:ally-buildings z-bldgs-1b
                  #:enemy-units e-u #:enemy-buildings e-b)))
  (define expanded-3rd?
    (has-act? acts-300
              (lambda (a)
                (and (pair? a) (eq? (car a) 'expand) (>= (length a) 3)
                     (<= (dist2 (second a) (third a) 32.5 68.5) 4.0)))))
  (check-true "L82-1a-zerg-norman-nat-pylon-block-holds-escrow-and-takes-3rd-as-natural-0-pools"
              (and cleared-220? (not panicked-pool-220?) expanded-3rd?)
              (format "cleared=~a poolPanic=~a exp3rd=~a acts220=~a acts300=~a"
                      cleared-220? panicked-pool-220? expanded-3rd? acts-220 acts-300)))

;; -----------------------------------------------------------------------------
;; 1b. Real Cannon Rush Escalation Guard (Forge / PhotonCannon / In-Main Pylon)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-1b (list (mk-u 82101 'hatchery 32.5 32.5 #:hp 1500.0)))
  (define z-units-16
    (append (mk-workers 'drone 16 82110)
            (list (mk-u 82140 'overlord 38.0 34.0 #:hp 200.0 #:flying #t)
                  (mk-u 82142 'larva 31.0 31.0 #:hp 25.0))))
  ;; Case i: Pylon on Natural + Photon Cannon starting -> REAL Cannon Rush -> builds Pool, NOT 3rd expand!
  (define rt-cr1 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-cr1
    (step-layer2-economy!
     rt-cr1
     (mk-live-obs 'Zerg 'Protoss 1280 #:minerals 300 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:expansion-locations exps-3
                  #:ally-units z-units-16 #:ally-buildings z-bldgs-1b
                  #:enemy-units (list (mk-u 82190 'probe 63.5 33.0 #:hp 20.0 #:shield 20.0))
                  #:enemy-buildings (list (mk-u 9001 'nexus 142.5 138.5)
                                          (mk-u 82191 'pylon 64.5 34.5 #:build-progress 0.8)
                                          (mk-u 82192 'photon-cannon 63.0 36.0 #:build-progress 0.2)))))
  ;; Case ii: Pylon right inside Main (dMain = 9.0t <= 16.0t) -> REAL In-Base Proxy -> builds Pool!
  (define rt-cr2 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-cr2
    (step-layer2-economy!
     rt-cr2
     (mk-live-obs 'Zerg 'Protoss 1280 #:minerals 220 #:gas 0 #:supply-used 16 #:supply-cap 22
                  #:mineral-harvesters 16 #:expansion-locations exps-3
                  #:ally-units z-units-16 #:ally-buildings z-bldgs-1b
                  #:enemy-units (list (mk-u 82193 'probe 41.0 33.0 #:hp 20.0 #:shield 20.0))
                  #:enemy-buildings (list (mk-u 9001 'nexus 142.5 138.5)
                                          (mk-u 82194 'pylon 41.5 32.5 #:build-progress 0.4)))))
  (check-true "L82-1b-real-cannon-rush-and-in-main-pylon-still-escalate-immediately"
              (and (has-build? acts-cr1 'spawning-pool)
                   (has-build? acts-cr2 'spawning-pool))
              (format "cr1=~a cr2=~a" acts-cr1 acts-cr2)))

;; -----------------------------------------------------------------------------
;; 1c. `norman` TvP Natural-Pad Pylon Block — High-Ground In-Base CC + Float-Down
;; -----------------------------------------------------------------------------
(let ()
  (define t-bldgs-1b
    (list (mk-u 82201 'command-center 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82202 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 82203 'barracks 45.0 36.0 #:hp 1000.0 #:build-progress 0.85)))
  (define t-units-18
    (append (mk-workers 'scv 18 82210)
            (list (mk-u 82240 'marine 44.0 35.0 #:hp 45.0))))
  (define rt-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  ;; Step 1 (f=2200, 400M, Pylon blocking Natural): builds 2nd CC on high ground inside Main!
  (define acts-t-cc
    (step-layer2-economy!
     rt-t
     (mk-live-obs 'Terran 'Protoss 2200 #:minerals 400 #:gas 50 #:supply-used 19 #:supply-cap 23
                  #:mineral-harvesters 15 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units t-units-18 #:ally-buildings t-bldgs-1b
                  #:enemy-units (list (mk-u 82290 'probe 63.5 33.0 #:hp 20.0 #:shield 20.0))
                  #:enemy-buildings (list (mk-u 9001 'nexus 142.5 138.5)
                                          (mk-u 82291 'pylon 64.0 34.0 #:build-progress 0.5)))))
  (define built-hg-cc?
    (has-act? acts-t-cc
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'command-center)
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) 32.5 32.5) 18.0)))))
  ;; Step 2 (f=3600, in-base 2nd OC complete & idle, Natural now clear): emits `(cast-spell 82205 'lift)`!
  (define t-bldgs-hg-done
    (list (mk-u 82201 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82205 'orbital-command 38.5 30.5 #:hp 1500.0 #:order-count 0)
          (mk-u 82202 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 82203 'barracks 45.0 36.0 #:hp 1000.0)))
  (define acts-t-lift
    (step-layer2-economy!
     rt-t
     (mk-live-obs 'Terran 'Protoss 3600 #:minerals 200 #:gas 100 #:supply-used 28 #:supply-cap 46
                  #:mineral-harvesters 20 #:vespene-harvesters 6 #:expansion-locations exps-3
                  #:ally-units t-units-18 #:ally-buildings t-bldgs-hg-done)))
  (define lifted-hg-oc?
    (has-act? acts-t-lift
              (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell)
                               (= (second a) 82205) (eq? (third a) 'lift)))))
  ;; Step 3 (f=3700, 2nd OC is now `orbital-command-flying` & idle): emits `(land-building 82205 62.5 32.5)`!
  (define t-bldgs-flying
    (list (mk-u 82201 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82205 'orbital-command-flying 45.0 31.5 #:hp 1500.0 #:flying #t #:order-count 0)
          (mk-u 82202 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 82203 'barracks 45.0 36.0 #:hp 1000.0)))
  (define acts-t-land
    (step-layer2-economy!
     rt-t
     (mk-live-obs 'Terran 'Protoss 3700 #:minerals 200 #:gas 100 #:supply-used 28 #:supply-cap 46
                  #:mineral-harvesters 20 #:vespene-harvesters 6 #:expansion-locations exps-3
                  #:ally-units t-units-18 #:ally-buildings t-bldgs-flying)))
  (define landed-on-nat?
    (has-act? acts-t-land
              (lambda (a) (and (pair? a) (eq? (car a) 'land-building)
                               (= (second a) 82205)
                               (<= (dist2 (third a) (fourth a) 62.5 32.5) 2.0)))))
  (check-true "L82-1c-terran-norman-block-builds-high-ground-cc-lifts-and-lands-on-natural"
              (and built-hg-cc? lifted-hg-oc? landed-on-nat?)
              (format "hgCC=~a lift=~a land=~a | ccActs=~a liftActs=~a landActs=~a"
                      built-hg-cc? lifted-hg-oc? landed-on-nat? acts-t-cc acts-t-lift acts-t-land)))

;; -----------------------------------------------------------------------------
;; 1d. Protoss Facing Natural-Pad Ebay / Pylon Block — No Panic, 3rd-as-Natural!
;; -----------------------------------------------------------------------------
(let ()
  (define p-bldgs-1b
    (list (mk-u 82301 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 82302 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 82303 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 82304 'cybernetics-core 43.0 34.0 #:hp 550.0 #:shield 550.0 #:build-progress 0.6)))
  (define p-units-20
    (append (mk-workers 'probe 20 82310)
            (list (mk-u 82340 'stalker 44.0 34.0 #:hp 80.0 #:shield 80.0))))
  (define rt-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  ;; Enemy Engineering Bay directly on Natural pad (dNat = 1.0t) + SCV -> NO Cannon-Rush panic, expands to 3rd!
  (define acts-p-ebay
    (step-layer2-economy!
     rt-p
     (mk-live-obs 'Protoss 'Terran 2200 #:minerals 400 #:gas 60 #:supply-used 22 #:supply-cap 31
                  #:mineral-harvesters 17 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units p-units-20 #:ally-buildings p-bldgs-1b
                  #:enemy-units (list (mk-u 82390 'scv 63.0 33.0 #:hp 45.0))
                  #:enemy-buildings (list (mk-u 9001 'command-center 142.5 138.5)
                                          (mk-u 82391 'engineering-bay 63.0 33.0 #:hp 850.0 #:build-progress 0.5)))))
  (define p-exp-3rd?
    (has-act? acts-p-ebay
              (lambda (a)
                (and (pair? a) (eq? (car a) 'expand) (>= (length a) 3)
                     (<= (dist2 (second a) (third a) 32.5 68.5) 4.0)))))
  (define p-cleared?
    (has-act? acts-p-ebay (lambda (a) (and (pair? a) (eq? (car a) 'clear-expansion-block)))))
  (check-true "L82-1d-protoss-nat-ebay-block-no-panic-and-expands-3rd-as-natural"
              (and p-cleared? p-exp-3rd? (not (has-build? acts-p-ebay 'shield-battery)))
              (format "cleared=~a exp3rd=~a acts=~a" p-cleared? p-exp-3rd? acts-p-ebay)))

;; -----------------------------------------------------------------------------
;; 1e. Terran Bug T1 Auto-Lift Guard — Wall Barracks (`addon-clear? #f`) Never Builds Add-On
;; -----------------------------------------------------------------------------
(let ()
  (define wall-hash
    (hasheq 'barracks (cons 45.5 39.5)
            'depot-1 (cons 45.0 37.0)
            'depot-2 (cons 48.0 41.0)
            'addon-clear? #f
            'grid-solved? #t))
  ;; Case i: ONLY the cliff-blocked ramp-wall Barracks exists -> MUST NOT build TechLab/Reactor on it!
  (define t-bldgs-wall-only
    (list (mk-u 82401 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82402 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82403 'supply-depot 45.0 37.0 #:hp 400.0)
          (mk-u 82404 'supply-depot 48.0 41.0 #:hp 400.0)
          (mk-u 82405 'barracks 45.5 39.5 #:hp 1000.0 #:order-count 0)
          (mk-u 82406 'factory 36.0 40.0 #:hp 1250.0 #:order-count 1)
          (mk-u 82407 'factory-techlab 38.5 39.5 #:hp 400.0)
          (mk-u 82408 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 82409 'refinery 36.5 28.5 #:hp 500.0)))
  (define t-units-wall
    (append (mk-workers 'scv 32 82420)
            (for/list ([i (in-range 6)]) (mk-u (+ 82460 i) 'marine 52.0 (+ 30.0 (* 0.5 i)) #:hp 45.0))))
  (define rt-t1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-wall-state rt-t1) 'cached-terran-wall
             (cons (list 32.5 32.5 62.5 32.5 (eq-hash-code #f)) wall-hash))
  (define acts-wall-only
    (step-layer2-economy!
     rt-t1
     (mk-live-obs 'Terran 'Zerg 4200 #:minerals 200 #:gas 100 #:supply-used 40 #:supply-cap 54
                  #:mineral-harvesters 26 #:vespene-harvesters 6 #:expansion-locations exps-3
                  #:ally-units t-units-wall #:ally-buildings t-bldgs-wall-only
                  #:extra (hasheq 'terran-ramp-wall wall-hash))))
  (define built-addon-on-wall-only?
    (or (has-build? acts-wall-only 'barracks-techlab)
        (has-build? acts-wall-only 'barracks-reactor)))
  ;; Case ii: Add Barracks #2 safely inside Main (36.5, 45.5) -> builds TechLab/Reactor on Barracks #2 ONLY!
  (define t-bldgs-with-rax2
    (append t-bldgs-wall-only
            (list (mk-u 82410 'barracks 36.5 45.5 #:hp 1000.0 #:order-count 0))))
  (define rt-t2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-wall-state rt-t2) 'cached-terran-wall
             (cons (list 32.5 32.5 62.5 32.5 (eq-hash-code #f)) wall-hash))
  (define acts-with-rax2
    (step-layer2-economy!
     rt-t2
     (mk-live-obs 'Terran 'Zerg 4200 #:minerals 200 #:gas 100 #:supply-used 40 #:supply-cap 54
                  #:mineral-harvesters 26 #:vespene-harvesters 6 #:expansion-locations exps-3
                  #:ally-units t-units-wall #:ally-buildings t-bldgs-with-rax2
                  #:extra (hasheq 'terran-ramp-wall wall-hash))))
  (define addon-on-rax2-not-wall?
    (has-act? acts-with-rax2
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build)
                     (memq (second a) '(barracks-techlab barracks-reactor))
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) 39.0 45.0) 1.0)))))
  (check-true "L82-1e-terran-wall-barracks-addon-clear-false-never-auto-lifts-uses-rax2"
              (and (not built-addon-on-wall-only?)
                   addon-on-rax2-not-wall?)
              (format "wallOnlyAddon=~a rax2Addon=~a | wallOnly=~a withRax2=~a"
                      built-addon-on-wall-only? addon-on-rax2-not-wall?
                      acts-wall-only acts-with-rax2)))

;; -----------------------------------------------------------------------------
;; 2a. Protoss Emergency Shield Battery / Pylon Wall-Off + Auto-Cancel (`314`)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-ew (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define door-pt (cons 50.0 34.0))
  (hash-set! (rt-wall-state rt-ew) 'cached-protoss-wall
             (cons (list 32.5 32.5 62.5 32.5 'Protoss 'Protoss #t 142.5 138.5 (eq-hash-code #f))
                   (hasheq 'door door-pt 'door-x 50.0 'door-y 34.0)))
  (define p-bldgs-ew
    (list (mk-u 82501 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 82502 'pylon 46.5 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 82503 'gateway 49.0 31.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 82504 'cybernetics-core 49.0 37.0 #:hp 550.0 #:shield 550.0 #:order-count 1)))
  (define p-units-ew
    (append (mk-workers 'probe 18 82510)
            (list (mk-u 82540 'probe 47.0 34.0 #:hp 20.0 #:shield 20.0))))
  ;; Tick 1: Enemy Adept Shade 2.0t from door -> drops emergency `shield-battery` on `(50.0, 34.0)`!
  (define acts-ew-build
    (step-layer2-economy!
     rt-ew
     (mk-live-obs 'Protoss 'Protoss 4200 #:minerals 150 #:gas 50 #:supply-used 22 #:supply-cap 31
                  #:mineral-harvesters 16 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units p-units-ew #:ally-buildings p-bldgs-ew
                  #:enemy-units (list (mk-u 82590 'adept-phase-shift 52.0 34.0 #:hp 1.0))
                  #:extra (hasheq 'door-pos door-pt))))
  (define built-ew-bat?
    (has-act? acts-ew-build
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'shield-battery)
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) 50.0 34.0) 1.5)))))
  ;; Tick 2: Threat clears (0 enemy shades/lings), incomplete Shield Battery at door -> emits `(cancel-building 82555)`!
  (define p-bldgs-ew-cancel
    (append p-bldgs-ew
            (list (mk-u 82555 'shield-battery 50.0 34.0 #:hp 120.0 #:max-hp 150.0 #:shield 90.0 #:max-shield 150.0
                        #:build-progress 0.35))))
  (define acts-ew-cancel
    (step-layer2-economy!
     rt-ew
     (mk-live-obs 'Protoss 'Protoss 4320 #:minerals 80 #:gas 50 #:supply-used 22 #:supply-cap 31
                  #:mineral-harvesters 16 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units p-units-ew #:ally-buildings p-bldgs-ew-cancel
                  #:enemy-units '()
                  #:extra (hasheq 'door-pos door-pt))))
  (define canceled-ew-bat?
    (has-act? acts-ew-cancel
              (lambda (a) (and (pair? a) (eq? (car a) 'cancel-building) (= (second a) 82555)))))
  (check-true "L82-2a-protoss-emergency-battery-walloff-on-shade-and-auto-cancel-314-on-clear"
              (and built-ew-bat? canceled-ew-bat?)
              (format "built=~a canceled=~a | buildActs=~a cancelActs=~a"
                      built-ew-bat? canceled-ew-bat? acts-ew-build acts-ew-cancel)))

;; -----------------------------------------------------------------------------
;; 2b. Pro Offensive `25M` PvZ Pylon-Cancel & `31.25M` TvP Ebay-Cancel in Layer 2
;; -----------------------------------------------------------------------------
(let ()
  (define e-nat-x 118.0)
  (define e-nat-y 138.5)
  ;; PvZ: Scouting Probe within 6t of empty enemy natural at f=1200 -> drops Pylon; at 87% -> cancels!
  (define rt-pvz-blk (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-blk
    (list (mk-u 82601 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 82602 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 82603 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:build-progress 0.5)))
  (define p-units-blk
    (append (mk-workers 'probe 16 82610)
            (list (mk-u 82640 'probe 120.0 138.5 #:hp 20.0 #:shield 20.0))))
  (define acts-pvz-drop
    (step-layer2-economy!
     rt-pvz-blk
     (mk-live-obs 'Protoss 'Zerg 1200 #:minerals 160 #:gas 0 #:supply-used 17 #:supply-cap 23
                  #:mineral-harvesters 16 #:expansion-locations exps-3
                  #:ally-units p-units-blk #:ally-buildings p-bldgs-blk
                  #:extra (hasheq 'enemy-natural-x e-nat-x 'enemy-natural-y e-nat-y))))
  (define dropped-pvz-pylon?
    (has-act? acts-pvz-drop
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon)
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) e-nat-x e-nat-y) 5.0)))))
  (define acts-pvz-cancel
    (step-layer2-economy!
     rt-pvz-blk
     (mk-live-obs 'Protoss 'Zerg 1580 #:minerals 90 #:gas 0 #:supply-used 17 #:supply-cap 23
                  #:mineral-harvesters 16 #:expansion-locations exps-3
                  #:ally-units p-units-blk
                  #:ally-buildings (append p-bldgs-blk
                                           (list (mk-u 82655 'pylon e-nat-x e-nat-y #:hp 180.0 #:max-hp 200.0
                                                       #:shield 180.0 #:max-shield 200.0 #:build-progress 0.87)))
                  #:extra (hasheq 'enemy-natural-x e-nat-x 'enemy-natural-y e-nat-y))))
  (define canceled-pvz-pylon?
    (has-act? acts-pvz-cancel
              (lambda (a) (and (pair? a) (eq? (car a) 'cancel-building) (= (second a) 82655)))))
  ;; TvP: Scouting SCV within 6t of empty enemy natural at f=1750 -> drops Engineering Bay!
  (define rt-tvp-blk (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-bldgs-blk
    (list (mk-u 82661 'command-center 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82662 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 82663 'barracks 45.0 36.0 #:hp 1000.0 #:build-progress 0.6)))
  (define t-units-blk
    (append (mk-workers 'scv 17 82670)
            (list (mk-u 82695 'scv 119.5 138.5 #:hp 45.0))))
  (define acts-tvp-drop
    (step-layer2-economy!
     rt-tvp-blk
     (mk-live-obs 'Terran 'Protoss 1750 #:minerals 180 #:gas 20 #:supply-used 18 #:supply-cap 23
                  #:mineral-harvesters 15 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units t-units-blk #:ally-buildings t-bldgs-blk
                  #:extra (hasheq 'enemy-natural-x e-nat-x 'enemy-natural-y e-nat-y))))
  (define dropped-tvp-ebay?
    (has-act? acts-tvp-drop
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'engineering-bay)
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) e-nat-x e-nat-y) 5.0)))))
  (check-true "L82-2b-pro-offensive-25m-pvz-pylon-cancel-and-31m-tvp-ebay-block"
              (and dropped-pvz-pylon? canceled-pvz-pylon? dropped-tvp-ebay?)
              (format "pvzDrop=~a pvzCancel=~a tvpDrop=~a | pvz=~a cancel=~a tvp=~a"
                      dropped-pvz-pylon? canceled-pvz-pylon? dropped-tvp-ebay?
                      acts-pvz-drop acts-pvz-cancel acts-tvp-drop)))

;; -----------------------------------------------------------------------------
;; 2c. Scout-Triggered Protoss Unwalled Punish (`2` vs Z/P, `3` vs Open T, Cap!)
;; -----------------------------------------------------------------------------
(let ()
  (define p-bldgs-adept
    (list (mk-u 82701 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 82702 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 82703 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 82704 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 82705 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 0)
          (mk-u 82706 'cybernetics-core 43.0 34.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
          (mk-u 82707 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)))
  (define p-units-base (mk-workers 'probe 24 82710))
  ;; (i) Open Zerg (`enemy-wall-open? #t`, 0 Adepts) -> trains `adept`!
  (define rt-open-z (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-open-z
    (step-layer2-economy!
     rt-open-z
     (mk-live-obs 'Protoss 'Zerg 3200 #:minerals 180 #:gas 80 #:supply-used 24 #:supply-cap 39
                  #:mineral-harvesters 21 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units p-units-base #:ally-buildings p-bldgs-adept
                  #:researched-upgrades '(warpgate warp-gate-research)
                  #:extra (hasheq 'enemy-wall-open? #t))))
  ;; (ii) Open Zerg with `2` Adepts already produced -> hard-capped, MUST NOT train Adept #3!
  (define rt-open-z-cap (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-units-2a
    (append p-units-base
            (list (mk-u 82740 'adept 95.0 95.0 #:hp 70.0 #:shield 70.0)
                  (mk-u 82741 'adept 96.0 95.0 #:hp 70.0 #:shield 70.0))))
  (define acts-open-z-cap
    (step-layer2-economy!
     rt-open-z-cap
     (mk-live-obs 'Protoss 'Zerg 3400 #:minerals 180 #:gas 80 #:supply-used 28 #:supply-cap 39
                  #:mineral-harvesters 21 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units p-units-2a #:ally-buildings p-bldgs-adept
                  #:researched-upgrades '(warpgate warp-gate-research)
                  #:extra (hasheq 'enemy-wall-open? #t 'total-adepts-produced 2))))
  ;; (iii) Open Terran with `2` Adepts -> trains Adept #3 (`66 >= 45` 1-volley SCV)!
  (define rt-open-t3 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-open-t3
    (step-layer2-economy!
     rt-open-t3
     (mk-live-obs 'Protoss 'Terran 3400 #:minerals 180 #:gas 80 #:supply-used 28 #:supply-cap 39
                  #:mineral-harvesters 21 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units p-units-2a #:ally-buildings p-bldgs-adept
                  #:researched-upgrades '(warpgate warp-gate-research)
                  #:extra (hasheq 'enemy-wall-open? #t 'total-adepts-produced 2))))
  ;; (iv) Walled / Unscouted Terran (`enemy-wall-open? #f`, 0 Adepts) -> trains `stalker`, NOT `adept`!
  (define rt-walled-t (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-walled-t
    (step-layer2-economy!
     rt-walled-t
     (mk-live-obs 'Protoss 'Terran 3200 #:minerals 180 #:gas 80 #:supply-used 24 #:supply-cap 39
                  #:mineral-harvesters 21 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units p-units-base #:ally-buildings p-bldgs-adept
                  #:researched-upgrades '(warpgate warp-gate-research)
                  #:extra (hasheq 'enemy-wall-open? #f))))
  (check-true "L82-2c-protoss-unwalled-punish-trains-2-adepts-vs-z-3-vs-open-t-and-0-when-walled"
              (and (has-train? acts-open-z 'adept)
                   (not (has-train? acts-open-z-cap 'adept))
                   (has-train? acts-open-t3 'adept)
                   (not (has-train? acts-walled-t 'adept)))
              (format "openZ=~a capZ=~a openT3=~a walledT=~a"
                      (has-train? acts-open-z 'adept)
                      (has-train? acts-open-z-cap 'adept)
                      (has-train? acts-open-t3 'adept)
                      (has-train? acts-walled-t 'adept))))

;; -----------------------------------------------------------------------------
;; 2d. Scout-Triggered Zerg Unwalled Speedling Flood (`14-16` Lings -> Drones!)
;; -----------------------------------------------------------------------------
(let ()
  (define z-bldgs-2b
    (list (mk-u 82801 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 82802 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 82803 'spawning-pool 36.0 34.0 #:hp 1000.0)
          (mk-u 82804 'extractor 28.5 36.5 #:hp 500.0)))
  (define z-units-24d-4l
    (append (mk-workers 'drone 24 82810)
            (for/list ([i (in-range 4)]) (mk-u (+ 82850 i) 'zergling 55.0 (+ 31.0 (* 0.4 i)) #:hp 35.0))
            (list (mk-u 82860 'queen 34.0 32.5 #:hp 175.0)
                  (mk-u 82861 'queen 61.0 32.5 #:hp 175.0)
                  (mk-u 82862 'overlord 38.0 34.0 #:hp 200.0 #:flying #t)
                  (mk-u 82863 'larva 31.0 31.0 #:hp 25.0)
                  (mk-u 82864 'larva 31.5 31.0 #:hp 25.0)
                  (mk-u 82865 'larva 61.0 31.0 #:hp 25.0)
                  (mk-u 82866 'larva 61.5 31.0 #:hp 25.0))))
  ;; (i) Open Protoss (`enemy-wall-open? #t`, f=3600, Speed researched, 4 Lings) -> trains `zergling` BEFORE `drone`!
  (define rt-z-open (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-z-open
    (step-layer2-economy!
     rt-z-open
     (mk-live-obs 'Zerg 'Protoss 3600 #:minerals 250 #:gas 40 #:supply-used 30 #:supply-cap 52
                  #:mineral-harvesters 21 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units z-units-24d-4l #:ally-buildings z-bldgs-2b
                  #:researched-upgrades '(zergling-movementspeed)
                  #:extra (hasheq 'enemy-wall-open? #t))))
  ;; (ii) Hard cap at 16 Lings -> stops Speedling flood and resumes `drone`!
  (define z-units-16l
    (append z-units-24d-4l
            (for/list ([i (in-range 12)]) (mk-u (+ 82870 i) 'zergling 95.0 (+ 90.0 (* 0.3 i)) #:hp 35.0))))
  (define rt-z-cap (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-z-cap
    (step-layer2-economy!
     rt-z-cap
     (mk-live-obs 'Zerg 'Protoss 4200 #:minerals 250 #:gas 40 #:supply-used 36 #:supply-cap 52
                  #:mineral-harvesters 21 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units z-units-16l #:ally-buildings z-bldgs-2b
                  #:researched-upgrades '(zergling-movementspeed)
                  #:extra (hasheq 'enemy-wall-open? #t 'total-zerglings-produced 16))))
  ;; (iii) Walled / Unscouted Terran (`enemy-wall-open? #f`) -> ZERO blind Speedling flood, trains `drone`!
  (define rt-z-walled (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-z-walled
    (step-layer2-economy!
     rt-z-walled
     (mk-live-obs 'Zerg 'Terran 3600 #:minerals 250 #:gas 40 #:supply-used 30 #:supply-cap 52
                  #:mineral-harvesters 21 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units z-units-24d-4l #:ally-buildings z-bldgs-2b
                  #:researched-upgrades '(zergling-movementspeed)
                  #:extra (hasheq 'enemy-wall-open? #f))))
  (check-true "L82-2d-zerg-unwalled-speedling-flood-trains-lings-vs-open-p-stops-at-16-and-0-when-walled"
              (and (has-train? acts-z-open 'zergling)
                   (not (has-train? acts-z-open 'drone))
                   (has-train? acts-z-cap 'drone)
                   (not (has-train? acts-z-cap 'zergling))
                   (has-train? acts-z-walled 'drone))
              (format "openLing=~a openDrone=~a capDrone=~a capLing=~a walledDrone=~a"
                      (has-train? acts-z-open 'zergling)
                      (has-train? acts-z-open 'drone)
                      (has-train? acts-z-cap 'drone)
                      (has-train? acts-z-cap 'zergling)
                      (has-train? acts-z-walled 'drone))))

;; -----------------------------------------------------------------------------
;; 2e. Pro Adept Shade Micro Wiring (`step-layer3-and-4-tactics!` -> Phase 7)
;; -----------------------------------------------------------------------------
(let ()
  (define rt-ad (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-ad
    (list (mk-u 82901 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 82902 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 82903 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)))
  ;; 2 wounded Adepts (< 60% HP) inside enemy main facing 3 enemy Roaches + 3 Drones -> Retreat-Out Safety Shade!
  (define ad-wounded-2
    (list (mk-u 82910 'adept 138.0 136.0 #:hp 35.0 #:max-hp 70.0 #:shield 15.0 #:max-shield 70.0)
          (mk-u 82911 'adept 138.5 137.0 #:hp 35.0 #:max-hp 70.0 #:shield 15.0 #:max-shield 70.0)))
  (define enemy-def-and-drones
    (append (for/list ([i (in-range 3)]) (mk-u (+ 82950 i) 'roach 134.0 (+ 135.0 (* 0.7 i)) #:hp 145.0))
            (for/list ([i (in-range 3)]) (mk-u (+ 82960 i) 'drone 141.0 (+ 137.0 (* 0.5 i)) #:hp 40.0))))
  (define obs-ad
    (mk-live-obs 'Protoss 'Zerg 4200 #:minerals 200 #:gas 100 #:supply-used 36 #:supply-cap 46
                 #:mineral-harvesters 28 #:vespene-harvesters 4
                 #:ally-units ad-wounded-2 #:ally-buildings p-bldgs-ad
                 #:enemy-units enemy-def-and-drones))
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt-ad) obs-ad)
  (define-values (acts-ad _v _r) (step-layer3-and-4-tactics! rt-ad obs-ad 0.5))
  (define cast-retreat-shade?
    (has-act? acts-ad
              (lambda (a)
                (and (pair? a) (memq (car a) '(cast cast-spell)) (>= (length a) 5)
                     (memv (second a) '(82910 82911))
                     (eq? (third a) 'adept-phase-shift)
                     ;; Shade projected OUT toward home/center (x < 130.0)
                     (< (fourth a) 130.0)))))
  (check-true "L82-2e-pro-adept-shade-micro-wired-emits-retreat-out-safety-shade"
              cast-retreat-shade?
              (format "acts=~a" acts-ad)))

;; -----------------------------------------------------------------------------
;; 2f. Latched `l82-enemy-wall-open?` -> `plan-unwalled-opponent-punish` +
;;     Solved Protoss `'door-pos` -> `plan-own-wall-integrity-defense`
;; -----------------------------------------------------------------------------
(let ()
  ;; (i) Zerg Overlord scouts open enemy Protoss natural at f=3000 -> latches `l82-enemy-wall-open?`,
  ;;     then at f=3600 even with 0 visible enemy buildings, 6 Zerglings flood enemy mineral line!
  (define rt-lat (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-bldgs-lat
    (list (mk-u 82970 'hatchery 32.5 32.5 #:hp 1500.0)
          (mk-u 82971 'hatchery 62.5 32.5 #:hp 1500.0)
          (mk-u 82972 'spawning-pool 36.0 34.0 #:hp 1000.0)))
  (define obs-scout-open
    (mk-live-obs 'Zerg 'Protoss 3000 #:minerals 100 #:gas 40 #:supply-used 28 #:supply-cap 44
                 #:mineral-harvesters 20 #:vespene-harvesters 3
                 #:ally-units (list (mk-u 82973 'overlord 120.0 120.0 #:hp 200.0 #:flying #t))
                 #:ally-buildings z-bldgs-lat
                 #:enemy-buildings (list (mk-u 82979 'nexus 140.5 140.5 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 82978 'nexus 118.0 118.0 #:hp 1000.0 #:shield 1000.0))
                 #:extra (hasheq 'enemy-natural-x 118.0 'enemy-natural-y 118.0)))
  (step-layer2-economy! rt-lat obs-scout-open)
  (define lings-6
    (for/list ([i (in-range 6)]) (mk-u (+ 82980 i) 'zergling 85.0 (+ 85.0 (* 0.4 i)) #:hp 35.0)))
  (define obs-flood
    (mk-live-obs 'Zerg 'Protoss 3600 #:minerals 100 #:gas 40 #:supply-used 34 #:supply-cap 44
                 #:mineral-harvesters 20 #:vespene-harvesters 3
                 #:ally-units lings-6 #:ally-buildings z-bldgs-lat
                 #:enemy-buildings '()
                 #:extra (hasheq 'enemy-natural-x 118.0 'enemy-natural-y 118.0)))
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt-lat) obs-flood)
  (define-values (acts-flood _vf _rf) (step-layer3-and-4-tactics! rt-lat obs-flood 0.5))
  (define lings-flooded-enemy-ml?
    (has-act? acts-flood
              (lambda (a)
                (and (pair? a) (memq (car a) '(move attack-pos)) (>= (length a) 4)
                     (exact-integer? (second a)) (<= 82980 (second a) 82985)
                     (> (third a) 130.0) (> (fourth a) 130.0)))))

  ;; (ii) Solved Protoss `'door-pos` from `rt-wall-state` `'cached-protoss-wall` feeds
  ;;      `plan-own-wall-integrity-defense` -> Zealot at exact door emits `(hold-position 82995)`!
  (define rt-door (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define solved-door (cons 57.5 34.5))
  (hash-set! (rt-wall-state rt-door)
             'cached-protoss-wall
             (cons 'door-key (hasheq 'door solved-door)))
  (define obs-door
    (mk-live-obs 'Protoss 'Zerg 2600 #:minerals 100 #:gas 0 #:supply-used 22 #:supply-cap 31
                 #:mineral-harvesters 18
                 #:ally-units (list (mk-u 82995 'zealot 57.5 34.5 #:hp 100.0 #:shield 50.0))
                 #:ally-buildings (list (mk-u 82990 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
                                        (mk-u 82991 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)
                                        (mk-u 82992 'gateway 55.5 34.5 #:hp 500.0 #:shield 500.0)
                                        (mk-u 82993 'cybernetics-core 59.5 34.5 #:hp 550.0 #:shield 550.0))
                 #:enemy-units (list (mk-u 82999 'zergling 66.0 34.5 #:hp 35.0))))
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt-door) obs-door)
  (define-values (acts-door _vd _rd) (step-layer3-and-4-tactics! rt-door obs-door 0.5))
  (define door-hold-pos?
    (has-act? acts-door (lambda (a) (and (pair? a) (eq? (car a) 'hold-position) (eqv? (second a) 82995)))))

  (check-true "L82-2f-latched-wall-open-punish-flood-and-solved-protoss-door-hold-position"
              (and lings-flooded-enemy-ml? door-hold-pos?)
              (format "latched=~a flood=~a doorHold=~a"
                      (hash-ref (rt-wall-state rt-lat) 'l82-enemy-wall-open? #f)
                      lings-flooded-enemy-ml?
                      door-hold-pos?)))

;; =============================================================================
;; Loop 82B Regression Tests (5 Surgical Fixes from `iter82` Live Audit `#2613`)
;; =============================================================================

;; -----------------------------------------------------------------------------
;; 82B-1: Protoss `'doorway-corridor` AABB shrunk to exact `0.5x0.5` +
;;        `wall-slot-3` `Gateway #2` frame cutoff raised `< 2600` -> `< 4800`
;; -----------------------------------------------------------------------------
(let ()
  (define rt-p82b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define pkey (list 32.5 32.5 62.5 32.5 'Zerg 'Zerg #f 142.5 138.5 (eq-hash-code #f)))
  (define wall-map
    (hasheq 'pylon (cons 54.0 34.0)
            'slot-1 (cons 57.5 31.5)
            'slot-2 (cons 57.5 34.5)
            'slot-3 (cons 57.5 37.5)
            'door (cons 55.5 36.0)
            'door-park (cons 54.0 36.0)))
  (hash-set! (rt-wall-state rt-p82b) 'cached-protoss-wall (cons pkey wall-map))
  (define p-bldgs-3s
    (list (mk-u 83101 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 83102 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 83103 'pylon 54.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 83104 'gateway 57.5 31.5 #:hp 500.0 #:shield 500.0)
          (mk-u 83105 'cybernetics-core 57.5 34.5 #:hp 550.0 #:shield 550.0)
          (mk-u 83106 'assimilator 28.0 36.0 #:hp 300.0 #:shield 300.0)))
  ;; Frame 4000 (~2:58, well past old 2600 cutoff and inside new < 4800 window):
  (define obs-p82b
    (mk-live-obs 'Protoss 'Zerg 4000 #:minerals 350 #:gas 60 #:supply-used 34 #:supply-cap 46
                 #:mineral-harvesters 28 #:vespene-harvesters 3 #:expansion-locations exps-3
                 #:ally-units (append (mk-workers 'probe 28 83110)
                                      (list (mk-u 83150 'adept 55.0 34.0 #:hp 70.0 #:shield 70.0)))
                 #:ally-buildings p-bldgs-3s))
  (define res-p82b (step-live-bot-runtime! rt-p82b obs-p82b))
  (define aabbs (hash-ref res-p82b 'wall-reserved-aabbs '()))
  (define door-aabbs
    (filter (lambda (r) (and (reserved-aabb? r) (eq? (reserved-aabb-kind r) 'doorway-corridor))) aabbs))
  (define exact-half-0.5?
    (and (= (length door-aabbs) 2)
         (for/and ([r (in-list door-aabbs)])
           (and (<= (abs (- (reserved-aabb-half-w r) 0.5)) 0.01)
                (<= (abs (- (reserved-aabb-half-h r) 0.5)) 0.01)))))
  (define acts-p82b (hash-ref res-p82b 'actions '()))
  (define gw2-at-slot3?
    (has-act? acts-p82b
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway)
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) 57.5 37.5) 1.0)))))
  (check-true "L82B-1-protoss-doorway-corridor-0.5-and-wall-slot-3-gateway2-at-3m05"
              (and exact-half-0.5? gw2-at-slot3?)
              (format "doorCount=~a exact0.5=~a gw2Slot3=~a acts=~a"
                      (length door-aabbs) exact-half-0.5? gw2-at-slot3? acts-p82b)))

;; -----------------------------------------------------------------------------
;; 82B-2: Fogged Terran / 1-Base Protoss Main Ramp NEVER False-Latches Open +
;;        Genuine High-Ground Scout STILL Latches + PvT 1-Base Natural Protected
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Zerg Overlord near Terran natural (118, 118) with fogged main (140.5, 140.5) -> NOT open!
  (define rt-fog-t (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-b (list (mk-u 83201 'hatchery 32.5 32.5 #:hp 1500.0)
                    (mk-u 83202 'hatchery 62.5 32.5 #:hp 1500.0)
                    (mk-u 83203 'spawning-pool 36.0 34.0 #:hp 1000.0)))
  (step-layer2-economy!
   rt-fog-t
   (mk-live-obs 'Zerg 'Terran 3200 #:minerals 150 #:gas 40 #:supply-used 28 #:supply-cap 44
                #:mineral-harvesters 20 #:vespene-harvesters 3
                #:ally-units (list (mk-u 83210 'overlord 120.0 120.0 #:hp 200.0 #:flying #t))
                #:ally-buildings z-b
                #:enemy-buildings (list (mk-u 83219 'command-center 140.5 140.5 #:hp 1500.0))
                #:extra (hasheq 'enemy-natural-x 118.0 'enemy-natural-y 118.0)))
  (define fog-t-closed? (not (hash-ref (rt-wall-state rt-fog-t) 'l82-enemy-wall-open? #f)))

  ;; (b) Zerg Overlord near empty Protoss natural (118, 118), 1-base Protoss main in fog -> NOT open!
  (define rt-fog-p (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (step-layer2-economy!
   rt-fog-p
   (mk-live-obs 'Zerg 'Protoss 3200 #:minerals 150 #:gas 40 #:supply-used 28 #:supply-cap 44
                #:mineral-harvesters 20 #:vespene-harvesters 3
                #:ally-units (list (mk-u 83220 'overlord 120.0 120.0 #:hp 200.0 #:flying #t))
                #:ally-buildings z-b
                #:enemy-buildings (list (mk-u 83229 'nexus 140.5 140.5 #:hp 1000.0 #:shield 1000.0))
                #:extra (hasheq 'enemy-natural-x 118.0 'enemy-natural-y 118.0)))
  (define fog-p-closed? (not (hash-ref (rt-wall-state rt-fog-p) 'l82-enemy-wall-open? #f)))

  ;; (c) Genuine high-ground scout (<= 12t of Terran main 140.5,140.5, 0 ramp buildings) -> STILL open!
  (define rt-vis-t (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (step-layer2-economy!
   rt-vis-t
   (mk-live-obs 'Zerg 'Terran 3200 #:minerals 150 #:gas 40 #:supply-used 28 #:supply-cap 44
                #:mineral-harvesters 20 #:vespene-harvesters 3
                #:ally-units (list (mk-u 83230 'overlord 134.0 134.0 #:hp 200.0 #:flying #t))
                #:ally-buildings z-b
                #:enemy-buildings (list (mk-u 83239 'command-center 140.5 140.5 #:hp 1500.0))
                #:extra (hasheq 'enemy-natural-x 118.0 'enemy-natural-y 118.0)))
  (define vis-t-open? (eq? (hash-ref (rt-wall-state rt-vis-t) 'l82-enemy-wall-open? #f) #t))

  ;; (d) Peaceful 1-base PvT (< 2:10, f=2500, 250M/120G, 1 Gate + CyberCore) -> NO Gate #2, NO Robo, NO extra Adept ahead of Nexus #2!
  (define rt-pvt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-pvt
    (step-layer2-economy!
     rt-pvt
     (mk-live-obs 'Protoss 'Terran 2500 #:minerals 250 #:gas 120 #:supply-used 24 #:supply-cap 31
                  #:mineral-harvesters 18 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units (append (mk-workers 'probe 20 83240)
                                       (list (mk-u 83270 'adept 55.0 34.0 #:hp 70.0 #:shield 70.0)))
                  #:ally-buildings (list (mk-u 83281 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
                                         (mk-u 83282 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
                                         (mk-u 83283 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)
                                         (mk-u 83284 'cybernetics-core 40.0 37.5 #:hp 550.0 #:shield 550.0)
                                         (mk-u 83285 'assimilator 28.0 36.0 #:hp 300.0 #:shield 300.0))
                  #:extra (hasheq 'enemy-wall-open? #t))))
  (define pvt-no-premature-drain?
    (and (not (has-build? acts-pvt 'gateway))
         (not (has-build? acts-pvt 'robotics-facility))
         (not (has-train? acts-pvt 'adept))))
  (check-true "L82B-2-fogged-terran-and-1base-protoss-never-false-open-and-pvt-nat-nexus-protected"
              (and fog-t-closed? fog-p-closed? vis-t-open? pvt-no-premature-drain?)
              (format "fogT=~a fogP=~a visT=~a pvtSafe=~a acts=~a"
                      fog-t-closed? fog-p-closed? vis-t-open? pvt-no-premature-drain? acts-pvt)))

;; -----------------------------------------------------------------------------
;; 82B-3: Terran East-Ramp Blocked Rax #1 Accelerates In-Base Rax #2 Ahead of Ebay
;; -----------------------------------------------------------------------------
(let ()
  (define rt-erax (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define wall-rax-pt (cons 42.5 46.5))
  (hash-set! (rt-wall-state rt-erax)
             'cached-terran-wall
             (cons (list 32.5 32.5 62.5 32.5 (eq-hash-code #f))
                   (hasheq 'barracks wall-rax-pt
                           'addon-clear? #f
                           'barracks-addon #f)))
  (define t-bldgs-erax
    (list (mk-u 83301 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 83302 'command-center 62.5 32.5 #:hp 1500.0 #:build-progress 0.35)
          (mk-u 83303 'supply-depot 45.0 46.0 #:hp 400.0)
          (mk-u 83304 'supply-depot 40.0 48.0 #:hp 400.0)
          (mk-u 83305 'barracks 42.5 46.5 #:hp 1000.0 #:order-count 1)
          (mk-u 83306 'refinery 28.0 36.0 #:hp 500.0)
          (mk-u 83307 'refinery 28.0 29.0 #:hp 500.0)))
  ;; Right after CC #2 & OC #1 & Depot #2 (f=2600 ~1:56, 175M/60G): builds in-base Rax #2 immediately, NOT Ebay!
  (define acts-erax
    (step-layer2-economy!
     rt-erax
     (mk-live-obs 'Terran 'Zerg 2600 #:minerals 175 #:gas 60 #:supply-used 23 #:supply-cap 31
                  #:mineral-harvesters 18 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units (append (mk-workers 'scv 21 83310)
                                       (list (mk-u 83350 'marine 44.0 42.0 #:hp 45.0)))
                  #:ally-buildings t-bldgs-erax)))
  (check-true "L82B-3-terran-east-ramp-blocked-rax1-accelerates-inbase-rax2-ahead-of-ebay"
              (and (has-build? acts-erax 'barracks)
                   (not (has-build? acts-erax 'engineering-bay)))
              (format "acts=~a" acts-erax)))

;; -----------------------------------------------------------------------------
;; 82B-4: Offensive Exp-Block Supply Guard & Distant Pylon Excluded from Home Supply
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Protoss at 23/23 (supply-left = 0) at f=1800 -> MUST NOT drop enemy-nat Pylon; builds home Pylon!
  (define rt-sb1 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-sb
    (list (mk-u 83401 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 83402 'pylon 38.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 83403 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0)))
  (define p-units-sb
    (append (mk-workers 'probe 21 83410)
            (list (mk-u 83440 'probe 120.0 138.5 #:hp 20.0 #:shield 20.0))))
  (define acts-sb1
    (step-layer2-economy!
     rt-sb1
     (mk-live-obs 'Protoss 'Zerg 1800 #:minerals 160 #:gas 0 #:supply-used 23 #:supply-cap 23
                  #:mineral-harvesters 20 #:expansion-locations exps-3
                  #:ally-units p-units-sb #:ally-buildings p-bldgs-sb
                  #:extra (hasheq 'enemy-natural-x 118.0 'enemy-natural-y 138.5))))
  (define no-far-pylon-when-sb?
    (not (has-act? acts-sb1
                   (lambda (a)
                     (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon)
                          (>= (length a) 4)
                          (> (dist2 (third a) (fourth a) 32.5 32.5) 40.0))))))
  (define built-home-pylon-1?
    (has-act? acts-sb1
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon)
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) 32.5 32.5) 35.0)))))

  ;; (b) Distant incomplete enemy-nat Pylon (118, 138.5) with obs pending-supply=1 at 22/23 ->
  ;;     excluded from home pending supply -> STILL builds home Pylon #2 immediately!
  (define rt-sb2 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-sb2
    (step-layer2-economy!
     rt-sb2
     (mk-live-obs 'Protoss 'Zerg 2100 #:minerals 150 #:gas 0 #:supply-used 22 #:supply-cap 23
                  #:mineral-harvesters 20 #:expansion-locations exps-3
                  #:ally-units p-units-sb
                  #:ally-buildings (append p-bldgs-sb
                                           (list (mk-u 83455 'pylon 118.0 138.5 #:hp 80.0 #:max-hp 200.0
                                                       #:shield 80.0 #:max-shield 200.0 #:build-progress 0.40)))
                  #:extra (hasheq 'pending-supply 1 'enemy-natural-x 118.0 'enemy-natural-y 138.5))))
  (define built-home-pylon-2?
    (has-act? acts-sb2
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon)
                     (>= (length a) 4)
                     (<= (dist2 (third a) (fourth a) 32.5 32.5) 35.0)))))
  (check-true "L82B-4-offensive-exp-block-supply-guard-and-distant-pylon-excluded-from-home-pending-supply"
              (and no-far-pylon-when-sb? built-home-pylon-1? built-home-pylon-2?)
              (format "noFar=~a home1=~a home2=~a | a1=~a a2=~a"
                      no-far-pylon-when-sb? built-home-pylon-1? built-home-pylon-2? acts-sb1 acts-sb2)))

;; -----------------------------------------------------------------------------
;; 82B-5: Blocked-Natural Pivot Past f=2500 (T holds 400M before Factory; Z takes 3rd)
;; -----------------------------------------------------------------------------
(let ()
  ;; (a) Terran at f=3044 (> 2500!) with enemy Pylon on Natural, 1 OC + 1 Rax, 180M/160G ->
  ;;     holds 400M escrow (NO Factory jump-in!), then at 400M builds in-base High-Ground CC #2!
  (define rt-tn2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-bldgs-tn2
    (list (mk-u 83501 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 83502 'supply-depot 42.0 34.0 #:hp 400.0)
          (mk-u 83503 'barracks 45.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 83504 'refinery 28.0 36.0 #:hp 500.0)))
  (define t-units-tn2
    (append (mk-workers 'scv 19 83510)
            (list (mk-u 83540 'marine 48.0 34.0 #:hp 45.0))))
  (define enemy-pylon-nat (list (mk-u 83590 'pylon 62.5 32.5 #:hp 200.0 #:shield 200.0)))
  (define acts-tn-180
    (step-layer2-economy!
     rt-tn2
     (mk-live-obs 'Terran 'Protoss 3044 #:minerals 180 #:gas 160 #:supply-used 20 #:supply-cap 23
                  #:mineral-harvesters 16 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units t-units-tn2 #:ally-buildings t-bldgs-tn2
                  #:enemy-buildings enemy-pylon-nat)))
  (define acts-tn-400
    (step-layer2-economy!
     rt-tn2
     (mk-live-obs 'Terran 'Protoss 3200 #:minerals 410 #:gas 180 #:supply-used 20 #:supply-cap 31
                  #:mineral-harvesters 16 #:vespene-harvesters 3 #:expansion-locations exps-3
                  #:ally-units t-units-tn2 #:ally-buildings t-bldgs-tn2
                  #:enemy-buildings enemy-pylon-nat)))
  (define t-held-no-fac? (not (has-build? acts-tn-180 'factory)))
  (define t-built-inbase-cc?
    (has-act? acts-tn-400
              (lambda (a)
                (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'command-center)
                     (>= (length a) 4)
                     (< (dist2 (third a) (fourth a) 32.5 32.5) 20.0)))))

  ;; (b) Zerg at f=2700 (> 2500!) with enemy Pylon on Natural + stray enemy Probe tapping building ->
  ;;     immediately redirects Hatch #2 to 3rd base (> 6t from blocked natural)!
  (define rt-zn2 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define acts-zn2
    (step-layer2-economy!
     rt-zn2
     (mk-live-obs 'Zerg 'Protoss 2700 #:minerals 285 #:gas 0 #:supply-used 18 #:supply-cap 22
                  #:mineral-harvesters 17 #:expansion-locations exps-3
                  #:ally-units (append (mk-workers 'drone 17 83560)
                                       (list (mk-u 83585 'overlord 40.0 34.0 #:hp 200.0 #:flying #t)))
                  #:ally-buildings (list (hash-set (mk-u 83551 'hatchery 32.5 32.5 #:hp 1500.0) 'under-attack #t)
                                         (mk-u 83552 'spawning-pool 36.0 34.0 #:hp 1000.0))
                  #:enemy-units (list (mk-u 83598 'probe 61.0 33.0 #:hp 20.0 #:shield 20.0))
                  #:enemy-buildings (list (mk-u 83599 'pylon 62.5 32.5 #:hp 200.0 #:shield 200.0)))))
  (define z-expanded-3rd?
    (has-act? acts-zn2
              (lambda (a)
                (and (pair? a) (eq? (car a) 'expand) (>= (length a) 3)
                     (> (dist2 (second a) (third a) 62.5 32.5) 6.0)))))

  (check-true "L82B-5-norman-blocked-nat-terran-holds-400m-past-f2500-before-factory-and-zerg-3rd-redirect"
              (and t-held-no-fac? t-built-inbase-cc? z-expanded-3rd?)
              (format "tNoFac=~a tInbaseCC=~a z3rd=~a | tn180=~a tn400=~a zn2=~a"
                      t-held-no-fac? t-built-inbase-cc? z-expanded-3rd? acts-tn-180 acts-tn-400 acts-zn2)))

(printf "\n=== Loop 82 Runtime Suite Summary: ~a/~a passed (~a failed) ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
