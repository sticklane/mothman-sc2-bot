#lang racket/base

;; =============================================================================
;; `tests/l81-div8-runtime-test.rkt`
;; Loop 81 (Release #23 Candidate) — Div 8 Live Production Root-Cause Runtime Suite
;;
;; Covers ALL 3 P0 Fixes + Opening Build-Order Commitment:
;;   1. Swarm Host `locust-kite-retreat?` Over-Retreat Fix:
;;      - 1a: Mixed standard Zerg ground army (>= 4 Locusts + >= 4 Roaches/Hydras >= 35%)
;;            fights cleanly (NO `locust-kite-retreat?`!).
;;      - 1b: 0-splash base defense (Locusts <= 12t of owned TownHall) stands & clears!
;;      - 1c: <= 3 stray Locusts OR far OWM-only Locusts (> 16t away) do NOT retreat!
;;      - 1d: Pure 0-TH 16-Locust wave (0 permanent non-SH enemies, 0 splash) STILL kites!
;;   2. Terran 2-Base -> 3rd CC Escrow Deadlock & Overdue Factory #1 Fix:
;;      - 2a: Peaceful 2-base Terran (`saving_for=command-center`, 220M) holds Barracks /
;;            Marine / Marauder / Tank mineral drains while keeping SCVs & Supply Depots active!
;;      - 2b: Safety valve releases immediately under base attack OR enemy army <= 22t of Natural!
;;      - 2c: Overdue Factory #1 (>= 4700f, 0 Factories, 180M/120G) unblocks past CC escrow!
;;   3. Protoss PvP Tech Order, Gateway Scaling, 2nd Robo, Mandatory Splash & Opening Guards:
;;      - 3a: Live < 2:00 Protoss (0 enemies) stays in `ForgeFastExpand` (NO f=300 `CannonWallRecovery`).
;;      - 3b: PvP researches `blink` ahead of `charge`/`resonating-glaives`, holds `charge` for
;;            ready Forge `+1` Ground Weapons (< 200G), and blocks `gravitic-booster` before
;;            `blink` + `+1` Weapons + Splash!
;;      - 3c: 2-3 base Protoss scales Gateways (6-8), builds 2nd `robotics-facility` on 3 bases
;;            at >= 7:30, drops mandatory `robotics-bay` at >= 6:00 & >= 18 army (NOT at 5:30 / low army!),
;;            and trains `colossus` ahead of Immortal #5 once `robotics-bay` is ready!
;;      - 3d: PvP 4:00-6:30 midgame push is restored (no passive `l81-pvp-mirror-eval?` freeze)!
;; =============================================================================

(require racket/list
         racket/math
         racket/string
         "../lib/bot-runtime.rkt"
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

(define (mk-live-obs race enemy-race frame
                     #:minerals [minerals 200]
                     #:gas [gas 150]
                     #:supply-used [su 68]
                     #:supply-cap [sc 118]
                     #:mineral-harvesters [mh 34]
                     #:vespene-harvesters [vh 12]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb #f]
                     #:expansion-locations [exps '()]
                     #:base-x [bx 32.5] #:base-y [by 32.5]
                     #:nat-x [nx 62.5] #:nat-y [ny 32.5]
                     #:enemy-x [ex 142.5] #:enemy-y [ey 138.5]
                     #:researched-upgrades [upgs '()]
                     #:under-attack? [ua? #f])
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
            'enemy-x ex 'enemy-y ey
            'researched-upgrades upgs 'upgrades-tracked? #t
            'under-attack? ua? 'under-attack ua?
            'map-width 200 'map-height 200))
  (if (pair? exps)
      (hash-set* h0 'expansion-locations exps 'expansion-candidates exps)
      h0))

(define (run-l34 rt obs [fap 0.5])
  (order-ledger-reconcile-observation! (live-bot-runtime-order-ledger rt) obs)
  (define-values (acts _v _r) (step-layer3-and-4-tactics! rt obs fap))
  acts)

(define (has-build? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(build build-addon morph-building))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (has-train? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (memq (car a) '(train morph-unit warp-in))
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (has-research? acts sym)
  (and (ormap (lambda (a)
                (and (pair? a)
                     (eq? (car a) 'research)
                     (>= (length a) 2)
                     (eq? (second a) sym)))
              acts)
       #t))

(define (act-moves-in-range? a lo hi)
  (and (pair? a) (memq (car a) '(move kite))
       (let ([u0 (second a)])
         (or (and (integer? u0) (<= lo u0 hi))
             (and (list? u0) (ormap (lambda (x) (<= lo x hi)) u0))))))

(define (act-retreats-west-in-range? a lo hi max-x)
  (and (pair? a) (memq (car a) '(move kite)) (>= (length a) 4)
       (real? (third a)) (< (third a) max-x)
       (let ([u0 (second a)])
         (or (and (integer? u0) (<= lo u0 hi))
             (and (list? u0) (ormap (lambda (x) (<= lo x hi)) u0))))))

(define (count-attackers-in-range acts lo hi)
  (for/sum ([a (in-list acts)]
            #:when (and (pair? a) (memq (car a) '(attack-unit attack-pos)) (>= (length a) 3)))
    (let ([u0 (second a)])
      (cond
        [(and (integer? u0) (<= lo u0 hi)) 1]
        [(list? u0) (count (lambda (x) (and (integer? x) (<= lo x hi))) u0)]
        [else 0]))))

(define (mk-workers sym n [start-id 2100] [bx 28.0] [by 30.0])
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) sym
          (+ bx (* 0.15 (modulo i 16))) (+ by (* 0.25 (quotient i 16)))
          #:hp 40.0)))

(define (fmt-fail rt acts)
  (define tel (live-bot-runtime-last-telemetry rt))
  (define pl (and (hash? tel) (hash-ref tel 'priority-log-line #f)))
  (define macro-acts
    (filter (lambda (a)
              (and (pair? a)
                   (memq (car a) '(build build-addon morph-building train morph-unit warp-in
                                   research expand))))
            acts))
  (format "macro=~a prio=~a" macro-acts pl))

(define exps-3 (list (list 32.5 32.5) (list 62.5 32.5) (list 32.5 68.5)))

(printf "=== Loop 81 Div 8 Live Production Runtime Verification Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. P0 — Swarm Host `locust-kite-retreat?` Over-Retreat Fix
;; -----------------------------------------------------------------------------
(let ()
  (define p-bldgs
    (list (mk-u 81001 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 81002 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)))
  (define nosplash-stalkers
    (append (for/list ([i (in-range 10)])
              (mk-u (+ 81100 i) 'stalker 88.0 (+ 66.0 (* 0.6 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 3)])
              (mk-u (+ 81120 i) 'immortal 87.0 (+ 67.5 (* 0.8 i)) #:hp 200.0 #:shield 100.0))))

  ;; 1a: Mixed standard Zerg ground army (6 Locusts + 6 Roaches/Hydras = 50% >= 35% within 16t, 0 splash)
  ;;     MUST NOT force full-army `locust-kite-retreat?` — army fights and attacks!
  (define loc-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 81200 i) 'locust-mp (+ 94.0 (* 0.4 (modulo i 3))) (+ 67.0 (* 0.6 (quotient i 3))) #:hp 50.0)))
  (define roach-hydra-6
    (append (for/list ([i (in-range 3)])
              (mk-u (+ 81220 i) 'roach 95.0 (+ 66.5 (* 0.8 i)) #:hp 145.0))
            (for/list ([i (in-range 3)])
              (mk-u (+ 81230 i) 'hydralisk 96.0 (+ 66.5 (* 0.8 i)) #:hp 90.0))))
  (define rt-1a (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-1a
    (run-l34 rt-1a
             (mk-live-obs 'Protoss 'Zerg 9800
                          #:ally-units nosplash-stalkers #:ally-buildings p-bldgs
                          #:enemy-units (append loc-6 roach-hydra-6))))
  (define mix-retreated? (ormap (lambda (a) (act-moves-in-range? a 81100 81122)) a-1a))
  (define mix-attacked-cnt (count-attackers-in-range a-1a 81100 81122))
  (check-true "L81-1a-mixed-zerg-army-with-locusts-fights-without-over-retreat"
              (and (not mix-retreated?) (>= mix-attacked-cnt 8))
              (format "retreat=~a atkCnt=~a" mix-retreated? mix-attacked-cnt))

  ;; 1b: 0-splash base defense (8 Locusts <= 12t of Natural Nexus 62.5,32.5, 0 Colossi/Archons)
  ;;     MUST stand & clear instead of abandoning the owned TownHall (no westward retreat)!
  (define loc-base-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 81250 i) 'locust-mp (+ 69.0 (* 0.4 (modulo i 4))) (+ 32.0 (* 0.5 (quotient i 4))) #:hp 50.0)))
  (define nosplash-home-def
    (for/list ([i (in-range 8)])
      (mk-u (+ 81270 i) 'stalker 65.0 (+ 30.5 (* 0.6 i)) #:hp 80.0 #:shield 80.0)))
  (define rt-1b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-1b
    (run-l34 rt-1b
             (mk-live-obs 'Protoss 'Zerg 9800
                          #:ally-units nosplash-home-def #:ally-buildings p-bldgs
                          #:enemy-units loc-base-8)))
  (define home-retreated? (ormap (lambda (a) (act-retreats-west-in-range? a 81270 81277 64.0)) a-1b))
  (define home-attacked-cnt (count-attackers-in-range a-1b 81270 81277))
  (check-true "L81-1b-zero-splash-base-defense-stands-and-clears-locusts-near-owned-th"
              (and (not home-retreated?) (>= home-attacked-cnt 6))
              (format "retreat=~a atkCnt=~a" home-retreated? home-attacked-cnt))

  ;; 1c: 2 stray Locusts (< 4) OR far Locusts (> 16t away) MUST NOT trigger retreat!
  (define stray-loc-2
    (list (mk-u 81290 'locust-mp 94.0 67.5 #:hp 50.0)
          (mk-u 81291 'locust-mp 94.5 68.5 #:hp 50.0)))
  (define rt-1c (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-1c
    (run-l34 rt-1c
             (mk-live-obs 'Protoss 'Zerg 9800
                          #:ally-units nosplash-stalkers #:ally-buildings p-bldgs
                          #:enemy-units (append stray-loc-2 (list (mk-u 81295 'roach 95.0 68.0 #:hp 145.0))))))
  (define stray-retreated? (ormap (lambda (a) (act-moves-in-range? a 81100 81122)) a-1c))
  (define stray-atks (count-attackers-in-range a-1c 81100 81122))
  (check-true "L81-1c-under-4-stray-locusts-do-not-trigger-full-army-retreat"
              (and (not stray-retreated?) (>= stray-atks 8))
              (format "retreat=~a atkCnt=~a" stray-retreated? stray-atks))

  ;; 1d: Pure 0-TH 16-Locust wave (0 permanent non-SH enemies, 0 owned THs, 0 splash) STILL kites!
  (define pure-loc-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 81300 i) 'locust-mp (+ 66.5 (* 0.4 (modulo i 4))) (+ 57.5 (* 0.7 (quotient i 4))) #:hp 50.0)))
  (define sh-10
    (for/list ([i (in-range 10)])
      (mk-u (+ 81330 i) 'swarm-host-mp 76.5 (+ 56.0 (* 0.8 i)) #:hp 160.0)))
  (define pure-stalkers-0th
    (for/list ([i (in-range 10)])
      (mk-u (+ 81350 i) 'stalker 59.0 (+ 56.5 (* 0.7 i)) #:hp 80.0 #:shield 80.0)))
  (define rt-1d (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define a-1d
    (run-l34 rt-1d
             (mk-live-obs 'Protoss 'Zerg 420
                          #:ally-units pure-stalkers-0th #:ally-buildings '()
                          #:enemy-units (append pure-loc-16 sh-10)
                          #:enemy-buildings '()
                          #:base-x 60.0 #:base-y 60.0 #:nat-x 60.0 #:nat-y 60.0
                          #:enemy-x 76.0 #:enemy-y 60.0)))
  (define pure-kites (count (lambda (a) (and (pair? a) (eq? (car a) 'kite) (<= 81350 (second a) 81359))) a-1d))
  (check-true "L81-1d-pure-0th-locust-wave-still-kites-cleanly"
              (>= pure-kites 8)
              (format "kites=~a/10" pure-kites)))

;; -----------------------------------------------------------------------------
;; 2. P0 — Terran 2-Base -> 3rd CC Escrow Deadlock & Overdue Factory #1 Fix
;; -----------------------------------------------------------------------------
(let ()
  (define t-bldgs-2b
    (list (mk-u 82001 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 0)
          (mk-u 82002 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 0)
          (mk-u 82003 'supply-depot 36.0 34.0 #:hp 400.0)
          (mk-u 82004 'supply-depot 38.5 34.0 #:hp 400.0)
          (mk-u 82005 'barracks 40.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82006 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82007 'barracks 48.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82020 'barracks 52.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82021 'barracks 56.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82008 'barracks-techlab 42.5 35.5 #:hp 400.0)
          (mk-u 82015 'barracks-reactor 46.5 35.5 #:hp 400.0)
          (mk-u 82016 'barracks-reactor 50.5 35.5 #:hp 400.0)
          (mk-u 82009 'factory 40.0 40.0 #:hp 1250.0 #:order-count 0)
          (mk-u 82010 'factory-techlab 42.5 39.5 #:hp 400.0)
          (mk-u 82011 'starport 46.0 40.0 #:hp 1300.0 #:order-count 0)
          (mk-u 82017 'starport-reactor 48.5 39.5 #:hp 400.0)
          (mk-u 82018 'engineering-bay 36.0 40.0 #:hp 850.0 #:order-count 1)
          (mk-u 82012 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 82013 'refinery 36.5 28.5 #:hp 500.0)
          (mk-u 82014 'refinery 58.5 36.5 #:hp 500.0)
          (mk-u 82019 'refinery 66.5 28.5 #:hp 500.0)))
  (define t-units-2b
    (append (mk-workers 'scv 42 82100)
            (for/list ([i (in-range 16)])
              (mk-u (+ 82200 i) 'marine 56.0 (+ 30.0 (* 0.5 i)) #:hp 55.0))
            (for/list ([i (in-range 4)])
              (mk-u (+ 82230 i) 'siege-tank 54.0 (+ 31.0 (* 1.0 i)) #:hp 175.0))
            (for/list ([i (in-range 2)])
              (mk-u (+ 82240 i) 'medivac 55.0 (+ 32.0 i) #:hp 150.0 #:flying #t))))

  ;; 2a: Peaceful 2-base Terran at 6:50 (9200f) with Starport + >=18 army (`saving_for=command-center`):
  ;;     - At 185M (`[150, 200)`): holds combat drains while SCVs stay unblocked!
  ;;     - At 240M (`>= 200M`): pure final sprint (holds combat drains AND stops SCV drain past 200M)!
  (define rt-2a-185 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2a-185
    (step-layer2-economy!
     rt-2a-185
     (mk-live-obs 'Terran 'Zerg 9200 #:minerals 185 #:gas 160 #:supply-used 74 #:supply-cap 102
                  #:mineral-harvesters 30 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-2b #:ally-buildings t-bldgs-2b
                  #:researched-upgrades '(stimpack combat-shield concussive-shells
                                          terran-infantry-weapons-1 terran-infantry-armor-1))))
  (define rt-2a (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2a
    (step-layer2-economy!
     rt-2a
     (mk-live-obs 'Terran 'Zerg 9200 #:minerals 240 #:gas 160 #:supply-used 74 #:supply-cap 102
                  #:mineral-harvesters 30 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-2b #:ally-buildings t-bldgs-2b
                  #:researched-upgrades '(stimpack combat-shield concussive-shells
                                          terran-infantry-weapons-1 terran-infantry-armor-1))))
  (define prio-2a (or (and (hash? (live-bot-runtime-last-telemetry rt-2a))
                           (hash-ref (live-bot-runtime-last-telemetry rt-2a) 'priority-log-line ""))
                      ""))
  (check-true "L81-2a-terran-2base-3rd-cc-escrow-holds-combat-drains-keeps-scvs-under-200m"
              (and (string-contains? prio-2a "saving_for=command-center")
                   (not (has-train? acts-2a-185 'marine))
                   (not (has-train? acts-2a-185 'siege-tank))
                   (has-train? acts-2a-185 'scv)
                   (not (has-train? acts-2a 'marine))
                   (not (has-train? acts-2a 'marauder))
                   (not (has-train? acts-2a 'siege-tank))
                   (not (has-build? acts-2a 'barracks))
                   (not (has-train? acts-2a 'scv)))
              (format "185M=~a 240M=~a" (fmt-fail rt-2a-185 acts-2a-185) (fmt-fail rt-2a acts-2a)))

  ;; 2b: Safety valve: same 2-base Terran with enemy combat push right outside Natural (<= 22t)
  ;;     MUST release hold immediately and resume combat unit training!
  (define enemy-nat-push
    (for/list ([i (in-range 6)])
      (mk-u (+ 82300 i) 'roach 74.0 (+ 31.0 (* 0.6 i)) #:hp 145.0)))
  (define rt-2b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2b
    (step-layer2-economy!
     rt-2b
     (mk-live-obs 'Terran 'Zerg 9200 #:minerals 240 #:gas 160 #:supply-used 74 #:supply-cap 102
                  #:mineral-harvesters 30 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-2b #:ally-buildings t-bldgs-2b
                  #:enemy-units enemy-nat-push
                  #:researched-upgrades '(stimpack combat-shield concussive-shells
                                          terran-infantry-weapons-1 terran-infantry-armor-1))))
  (check-true "L81-2b-terran-2base-3rd-cc-safety-valve-releases-when-enemy-near-natural"
              (or (has-train? acts-2b 'siege-tank)
                  (has-train? acts-2b 'marine)
                  (has-train? acts-2b 'marauder))
              (fmt-fail rt-2b acts-2b))

  ;; 2c: Overdue Factory #1 past 3:30 (>= 4700f) with 0 Factories and 180M/120G:
  ;;     MUST build `factory` immediately even while CC escrow is active!
  (define t-bldgs-nofac
    (list (mk-u 82401 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82402 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82403 'supply-depot 36.0 34.0 #:hp 400.0)
          (mk-u 82404 'supply-depot 38.5 34.0 #:hp 400.0)
          (mk-u 82405 'barracks 40.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82406 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82407 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 82408 'refinery 36.5 28.5 #:hp 500.0)))
  (define t-units-nofac
    (append (mk-workers 'scv 34 82450)
            (for/list ([i (in-range 10)])
              (mk-u (+ 82500 i) 'marine 54.0 (+ 30.0 (* 0.5 i)) #:hp 55.0))))
  (define rt-2c (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2c
    (step-layer2-economy!
     rt-2c
     (mk-live-obs 'Terran 'Protoss 7200 #:minerals 180 #:gas 120 #:supply-used 46 #:supply-cap 62
                  #:mineral-harvesters 28 #:vespene-harvesters 6
                  #:expansion-locations exps-3
                  #:ally-units t-units-nofac #:ally-buildings t-bldgs-nofac)))
  (check-true "L81-2c-overdue-factory1-past-3m30-never-blocked-by-cc-escrow"
              (has-build? acts-2c 'factory)
              (fmt-fail rt-2c acts-2c))

  ;; 2d (Loop 81B): Terran `stimpack` research reserve MUST NOT starve Starport #1 when 0 Starports & 0 Tanks!
  (define t-bldgs-nosp
    (list (mk-u 82601 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82602 'orbital-command 62.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82603 'supply-depot 36.0 34.0 #:hp 400.0)
          (mk-u 82604 'supply-depot 38.5 34.0 #:hp 400.0)
          (mk-u 82605 'barracks 40.0 36.0 #:hp 1000.0 #:order-count 1)
          (mk-u 82606 'barracks-techlab 42.5 35.5 #:hp 400.0 #:order-count 0)
          (mk-u 82607 'factory 40.0 40.0 #:hp 1250.0 #:order-count 1)
          (mk-u 82608 'factory-techlab 42.5 39.5 #:hp 400.0)
          (mk-u 82609 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 82610 'refinery 36.5 28.5 #:hp 500.0)))
  (define t-units-nosp
    (append (mk-workers 'scv 30 82620)
            (for/list ([i (in-range 8)])
              (mk-u (+ 82660 i) 'marine 54.0 (+ 30.0 (* 0.5 i)) #:hp 45.0))))
  (define rt-2d (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2d
    (step-layer2-economy!
     rt-2d
     (mk-live-obs 'Terran 'Terran 4300 #:minerals 165 #:gas 105 #:supply-used 40 #:supply-cap 54
                  #:mineral-harvesters 24 #:vespene-harvesters 6
                  #:expansion-locations exps-3
                  #:ally-units t-units-nosp #:ally-buildings t-bldgs-nosp)))
  (check-true "L81-2d-terran-starport1-not-starved-by-stimpack-research-reserve"
              (has-build? acts-2d 'starport)
              (fmt-fail rt-2d acts-2d))

  ;; 2e (Loop 81B/81C): 2-base TvT with Starport + >=22 army + ONLY 2 Siege Tanks (< 3 parity!) at 240M/160G
  ;;     MUST keep Siege Tank #3 UNBLOCKED during 3rd-CC escrow, while holding Marines/Marauders;
  ;;     AND 2-base Terran with low army (< 18) OR before 5:45 (`< 7728f`) MUST NOT freeze Barracks!
  (define t-units-2b-2tanks
    (append (mk-workers 'scv 42 82700)
            (for/list ([i (in-range 14)])
              (mk-u (+ 82750 i) 'marine 56.0 (+ 30.0 (* 0.5 i)) #:hp 55.0))
            (for/list ([i (in-range 2)])
              (mk-u (+ 82770 i) 'siege-tank 54.0 (+ 31.0 (* 1.0 i)) #:hp 175.0))
            (for/list ([i (in-range 2)])
              (mk-u (+ 82780 i) 'medivac 55.0 (+ 32.0 i) #:hp 150.0 #:flying #t))))
  (define rt-2e-tank (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2e-tank
    (step-layer2-economy!
     rt-2e-tank
     (mk-live-obs 'Terran 'Terran 9200 #:minerals 240 #:gas 160 #:supply-used 66 #:supply-cap 102
                  #:mineral-harvesters 30 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-2b-2tanks #:ally-buildings t-bldgs-2b
                  #:researched-upgrades '(stimpack combat-shield concussive-shells
                                          terran-infantry-weapons-1 terran-infantry-armor-1))))
  (define t-units-2b-low-army
    (append (mk-workers 'scv 42 82800)
            (for/list ([i (in-range 10)])
              (mk-u (+ 82850 i) 'marine 56.0 (+ 30.0 (* 0.5 i)) #:hp 55.0))))
  (define rt-2e-low (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2e-low
    (step-layer2-economy!
     rt-2e-low
     (mk-live-obs 'Terran 'Zerg 9200 #:minerals 240 #:gas 100 #:supply-used 52 #:supply-cap 102
                  #:mineral-harvesters 30 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-2b-low-army #:ally-buildings t-bldgs-2b
                  #:researched-upgrades '(stimpack combat-shield concussive-shells
                                          terran-infantry-weapons-1 terran-infantry-armor-1))))
  ;; Loop 81C: Before 5:45 (`7200f < 7728f`), even full 2-base army + Starport MUST NOT freeze SCVs/Factory/Barracks!
  (define rt-2e-early (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2e-early
    (step-layer2-economy!
     rt-2e-early
     (mk-live-obs 'Terran 'Zerg 7200 #:minerals 290 #:gas 160 #:supply-used 74 #:supply-cap 102
                  #:mineral-harvesters 30 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units t-units-2b #:ally-buildings t-bldgs-2b
                  #:researched-upgrades '(stimpack combat-shield concussive-shells
                                          terran-infantry-weapons-1 terran-infantry-armor-1))))
  (check-true "L81-2e-terran-3rd-cc-keeps-tvt-tank3-parity-army-floor-and-5m45-frame-floor"
              (and (has-train? acts-2e-tank 'siege-tank)
                   (not (has-train? acts-2e-tank 'marine))
                   (or (has-train? acts-2e-low 'marine)
                       (has-train? acts-2e-low 'marauder))
                   (has-train? acts-2e-early 'scv)
                   (has-train? acts-2e-early 'siege-tank)
                   (or (has-train? acts-2e-early 'marine)
                       (has-train? acts-2e-early 'marauder)))
              (format "tank3=~a lowArmy=~a early521=~a"
                      (fmt-fail rt-2e-tank acts-2e-tank)
                      (fmt-fail rt-2e-low acts-2e-low)
                      (fmt-fail rt-2e-early acts-2e-early)))

  ;; 2f (Loop 81B): Orbital Command escrow (`terran-saving-for-orbital?` at 140M, NOT 400M CC save!)
  ;;     MUST NOT freeze Barracks Marine production when Tank bypass enters Phase 3!
  (define t-bldgs-oc-save
    (list (mk-u 82901 'orbital-command 32.5 32.5 #:hp 1500.0 #:order-count 1)
          (mk-u 82902 'command-center 62.5 32.5 #:hp 1500.0 #:order-count 0)
          (mk-u 82903 'supply-depot 36.0 34.0 #:hp 400.0)
          (mk-u 82904 'supply-depot 38.5 34.0 #:hp 400.0)
          (mk-u 82905 'barracks 40.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82911 'barracks-reactor 42.5 35.5 #:hp 400.0)
          (mk-u 82906 'barracks 44.0 36.0 #:hp 1000.0 #:order-count 0)
          (mk-u 82912 'barracks-reactor 46.5 35.5 #:hp 400.0)
          (mk-u 82907 'factory 40.0 40.0 #:hp 1250.0 #:order-count 1)
          (mk-u 82908 'factory-techlab 42.5 39.5 #:hp 400.0)
          (mk-u 82909 'refinery 28.5 36.5 #:hp 500.0)
          (mk-u 82910 'refinery 36.5 28.5 #:hp 500.0)))
  (define t-units-oc-save
    (append (mk-workers 'scv 28 82920)
            (for/list ([i (in-range 10)])
              (mk-u (+ 82960 i) 'marine 54.0 (+ 30.0 (* 0.5 i)) #:hp 45.0))))
  (define rt-2f (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-2f
    (step-layer2-economy!
     rt-2f
     (mk-live-obs 'Terran 'Terran 5200 #:minerals 140 #:gas 40 #:supply-used 40 #:supply-cap 54
                  #:mineral-harvesters 22 #:vespene-harvesters 6
                  #:expansion-locations exps-3
                  #:ally-units t-units-oc-save #:ally-buildings t-bldgs-oc-save)))
  (check-true "L81-2f-terran-orbital-escrow-never-freezes-barracks-marines"
              (has-train? acts-2f 'marine)
              (fmt-fail rt-2f acts-2f)))

;; -----------------------------------------------------------------------------
;; 3. P0 — Protoss PvP Tech Order, Gateway Scaling, 2nd Robo, Mandatory Splash & Guards
;; -----------------------------------------------------------------------------
(let ()
  ;; 3a: Live < 2:00 Protoss (f=500, 0 enemies) stays in `ForgeFastExpand` (NO f=300 `CannonWallRecovery`),
  ;;     while real enemy combat unit DOES transition to `CannonWallRecovery`!
  (define rt-3a-peace (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-peace (compute-next-posture rt-3a-peace
                                        (mk-live-obs 'Protoss 'Protoss 500 #:supply-used 16 #:supply-cap 23
                                                     #:mineral-harvesters 16 #:vespene-harvesters 0
                                                     #:ally-buildings (list (mk-u 83001 'nexus 32.5 32.5)
                                                                            (mk-u 83002 'gateway 40.0 34.0)))
                                        0.0))
  (define rt-3a-rush (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-rush (compute-next-posture rt-3a-rush
                                       (mk-live-obs 'Protoss 'Zerg 1200 #:supply-used 18 #:supply-cap 23
                                                    #:mineral-harvesters 16 #:vespene-harvesters 0
                                                    #:ally-buildings (list (mk-u 83003 'nexus 32.5 32.5))
                                                    #:enemy-units (list (mk-u 83090 'zergling 38.0 34.0 #:hp 35.0)))
                                       0.0))
  (check-true "L81-3a-protoss-stays-forgefastexpand-peaceful-under-2m-no-spurious-cannonwall"
              (and (eq? p-peace 'ForgeFastExpand)
                   (eq? p-rush 'CannonWallRecovery))
              (format "peace=~a rush=~a" p-peace p-rush))

  ;; 3b: PvP Upgrade Order:
  ;;     (i) With Blink done and ready Forge + Twilight at 140G (< 200G): researches `+1` Weapons (NOT `charge`!).
  ;;     (ii) With Robotics Bay ready (0 Colossi, Blink NOT done) + Observer alive: does NOT research `gravitic-booster`!
  (define p-bldgs-upg
    (list (mk-u 83101 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 83102 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 83103 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 83104 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 83105 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83106 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83107 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83108 'gateway 52.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83109 'gateway 40.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83110 'gateway 44.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83111 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
          (mk-u 83112 'twilight-council 40.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 0)
          (mk-u 83113 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 83114 'robotics-bay 52.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 0)
          (mk-u 83115 'forge 36.0 42.0 #:hp 400.0 #:shield 400.0 #:order-count 0)
          (mk-u 83116 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 83117 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
          (mk-u 83118 'assimilator 58.5 36.5 #:hp 300.0 #:shield 300.0)))
  (define p-units-upg
    (append (mk-workers 'probe 38 83130)
            (for/list ([i (in-range 6)]) (mk-u (+ 83180 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 83190 i) 'adept 53.0 (+ 30.0 (* 0.5 i)) #:hp 70.0 #:shield 70.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 83194 i) 'colossus 51.0 (+ 30.0 (* 0.8 i)) #:hp 200.0 #:shield 150.0))
            (list (mk-u 83199 'observer 54.0 34.0 #:hp 40.0 #:shield 20.0 #:flying #t))))
  ;; (i) Blink done, +1 Weapons NOT done, 140G -> Forge researches +1 Weapons, Twilight holds Charge!
  (define rt-3bi (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3bi
    (step-layer2-economy!
     rt-3bi
     (mk-live-obs 'Protoss 'Protoss 7800 #:minerals 180 #:gas 140 #:supply-used 68 #:supply-cap 102
                  #:mineral-harvesters 29 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units p-units-upg #:ally-buildings p-bldgs-upg
                  #:researched-upgrades '(warpgate warp-gate-research blink extended-thermal-lance))))
  ;; (ii) Blink NOT done, +1 Weapons NOT done, 110G -> blocks gravitic-booster & charge & resonating-glaives!
  (define rt-3bii (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3bii
    (step-layer2-economy!
     rt-3bii
     (mk-live-obs 'Protoss 'Protoss 7200 #:minerals 140 #:gas 110 #:supply-used 68 #:supply-cap 102
                  #:mineral-harvesters 29 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units p-units-upg #:ally-buildings p-bldgs-upg
                  #:researched-upgrades '(warpgate warp-gate-research extended-thermal-lance))))
  (check-true "L81-3b-pvp-upgrade-order-blink-and-wpn1-ahead-of-charge-glaives-gravitic"
              (and (has-research? acts-3bi 'protoss-ground-weapons-1)
                   (not (has-research? acts-3bi 'charge))
                   (not (has-research? acts-3bii 'gravitic-booster))
                   (not (has-research? acts-3bii 'resonating-glaives))
                   (not (has-research? acts-3bii 'charge)))
              (format "3bi=~a 3bii=~a" (fmt-fail rt-3bi acts-3bi) (fmt-fail rt-3bii acts-3bii)))

  ;; 3c: Mandatory Splash `robotics-bay` (even with enemy Observer present!) + 3-base 2nd Robo (>= 7:30)
  ;;     + Colossus #1 ahead of Immortal #5 when Robotics Bay is ready!
  (define p-bldgs-nosplash
    (list (mk-u 83201 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 83202 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
          (mk-u 83203 'pylon 36.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 83204 'pylon 44.0 34.0 #:hp 200.0 #:shield 200.0)
          (mk-u 83205 'gateway 40.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83206 'gateway 44.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83207 'gateway 48.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83208 'gateway 52.0 34.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83209 'gateway 40.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83210 'gateway 44.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83211 'cybernetics-core 44.0 38.0 #:hp 550.0 #:shield 550.0 #:order-count 1)
          (mk-u 83212 'twilight-council 40.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
          (mk-u 83213 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 1)
          (mk-u 83214 'assimilator 28.5 36.5 #:hp 300.0 #:shield 300.0)
          (mk-u 83215 'assimilator 36.5 28.5 #:hp 300.0 #:shield 300.0)
          (mk-u 83216 'assimilator 58.5 36.5 #:hp 300.0 #:shield 300.0)))
  (define p-units-nosplash
    (append (mk-workers 'probe 38 83230)
            (for/list ([i (in-range 6)]) (mk-u (+ 83280 i) 'stalker 52.0 (+ 30.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 2)]) (mk-u (+ 83290 i) 'immortal 51.0 (+ 30.0 (* 0.8 i)) #:hp 200.0 #:shield 100.0))
            (list (mk-u 83299 'observer 54.0 34.0 #:hp 40.0 #:shield 20.0 #:flying #t))))
  (define rt-3ci (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3ci
    (step-layer2-economy!
     rt-3ci
     (mk-live-obs 'Protoss 'Protoss 8200 #:minerals 220 #:gas 180 #:supply-used 60 #:supply-cap 94
                  #:mineral-harvesters 29 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units p-units-nosplash #:ally-buildings p-bldgs-nosplash
                  #:enemy-units (list (mk-u 83390 'warp-prism 120.0 110.0 #:hp 80.0 #:shield 100.0 #:flying #t))
                  #:researched-upgrades '(warpgate warp-gate-research blink))))
  ;; Loop 81C: At 5:30 (`7400f < 8064f`) OR low army (`1` Stalker + `1` Immortal = `6 < 18` sup) in PvZ,
  ;; MUST NOT rush mandatory `robotics-bay` (`200M/200G`) ahead of Stalkers/Immortals!
  (define p-units-pvz-thin
    (append (mk-workers 'probe 44 83230)
            (list (mk-u 83280 'stalker 52.0 30.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 83290 'immortal 51.0 30.0 #:hp 200.0 #:shield 100.0)
                  (mk-u 83299 'observer 54.0 34.0 #:hp 40.0 #:shield 20.0 #:flying #t))))
  (define rt-3ci-early (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3ci-early
    (step-layer2-economy!
     rt-3ci-early
     (mk-live-obs 'Protoss 'Zerg 7400 #:minerals 220 #:gas 200 #:supply-used 56 #:supply-cap 94
                  #:mineral-harvesters 35 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units p-units-pvz-thin #:ally-buildings p-bldgs-nosplash
                  #:researched-upgrades '(warpgate warp-gate-research))))
  (define rt-3ci-lowarmy (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3ci-lowarmy
    (step-layer2-economy!
     rt-3ci-lowarmy
     (mk-live-obs 'Protoss 'Zerg 8200 #:minerals 220 #:gas 200 #:supply-used 56 #:supply-cap 94
                  #:mineral-harvesters 35 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units p-units-pvz-thin #:ally-buildings p-bldgs-nosplash
                  #:researched-upgrades '(warpgate warp-gate-research))))

  ;; 3c(ii): 3-base Protoss at >= 7:30 (10400f) with 1 ready Robo + 1 Colossus -> builds 2nd `robotics-facility`!
  (define p-bldgs-3b
    (append p-bldgs-nosplash
            (list (mk-u 83217 'nexus 32.5 68.5 #:hp 1000.0 #:shield 1000.0 #:order-count 1)
                  (mk-u 83218 'robotics-bay 52.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                  (mk-u 83219 'gateway 48.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1)
                  (mk-u 83220 'gateway 52.0 42.0 #:hp 500.0 #:shield 500.0 #:order-count 1))))
  (define p-units-3b
    (append p-units-nosplash
            (mk-workers 'probe 12 83320 30.0 66.0)
            (list (mk-u 83350 'colossus 53.0 32.0 #:hp 200.0 #:shield 150.0))))
  (define rt-3cii (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3cii
    (step-layer2-economy!
     rt-3cii
     (mk-live-obs 'Protoss 'Protoss 10400 #:minerals 220 #:gas 140 #:supply-used 78 #:supply-cap 118
                  #:mineral-harvesters 38 #:vespene-harvesters 12
                  #:expansion-locations exps-3
                  #:ally-units p-units-3b #:ally-buildings p-bldgs-3b
                  #:researched-upgrades '(warpgate warp-gate-research blink extended-thermal-lance))))

  ;; 3c(iii): Ready Robotics Bay with 0 Colossi and idle Robo at 260M/130G -> MUST NOT drain into Immortal #3!
  (define p-bldgs-col1
    (append (filter (lambda (b) (not (= (hash-ref b 'id 0) 83213))) p-bldgs-nosplash)
            (list (mk-u 83213 'robotics-facility 48.0 38.0 #:hp 450.0 #:shield 450.0 #:order-count 0)
                  (mk-u 83218 'robotics-bay 52.0 38.0 #:hp 500.0 #:shield 500.0 #:order-count 1))))
  (define rt-3ciii (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-3ciii
    (step-layer2-economy!
     rt-3ciii
     (mk-live-obs 'Protoss 'Protoss 8200 #:minerals 260 #:gas 130 #:supply-used 60 #:supply-cap 94
                  #:mineral-harvesters 29 #:vespene-harvesters 9
                  #:expansion-locations exps-3
                  #:ally-units p-units-nosplash #:ally-buildings p-bldgs-col1
                  #:researched-upgrades '(warpgate warp-gate-research blink))))

  (check-true "L81-3c-protoss-mandatory-splash-robobay-6m-18sup-3base-2nd-robo-and-colossus1-guard"
              (and (has-build? acts-3ci 'robotics-bay)
                   (not (has-build? acts-3ci-early 'robotics-bay))
                   (not (has-build? acts-3ci-lowarmy 'robotics-bay))
                   (has-build? acts-3cii 'robotics-facility)
                   (not (has-train? acts-3ciii 'immortal)))
              (format "robobay=~a early530=~a lowArmy=~a robo2=~a col1Hold=~a"
                      (fmt-fail rt-3ci acts-3ci)
                      (fmt-fail rt-3ci-early acts-3ci-early)
                      (fmt-fail rt-3ci-lowarmy acts-3ci-lowarmy)
                      (fmt-fail rt-3cii acts-3cii)
                      (fmt-fail rt-3ciii acts-3ciii)))

  ;; 3d (Loop 81C): Restored PvP 4:00-6:30 midgame timing aggression (no passive `l81-pvp-mirror-eval?` freeze):
  ;;     2-base Protoss with 20 combat supply (`1775` val = `0.63x` vs `2800`-val enemy Skytoss/Gateway OWM)
  ;;     is exempt via restored `early-midgame-pt-timing-exempt?` (`>= 0.45x`, `>= 14` sup) instead of
  ;;     freezing passive under Loop 81B's reverted `0.72x / >= 22 sup` PvP mirror hold!
  (define rt-3d (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-home
    (list (mk-u 83401 'nexus 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
          (mk-u 83402 'nexus 62.5 32.5 #:hp 1000.0 #:shield 1000.0)))
  (define p-small-army
    (append (for/list ([i (in-range 8)]) (mk-u (+ 83420 i) 'stalker 66.0 (+ 30.0 (* 0.6 i)) #:hp 80.0 #:shield 80.0))
            (list (mk-u 83430 'immortal 65.0 32.5 #:hp 200.0 #:shield 100.0))))
  (define enemy-strong-seed
    (append (for/list ([i (in-range 4)]) (mk-u (+ 83460 i) 'stalker 122.0 (+ 124.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0))
            (for/list ([i (in-range 5)]) (mk-u (+ 83470 i) 'zealot 123.0 (+ 124.0 (* 0.5 i)) #:hp 100.0 #:shield 50.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 83480 i) 'void-ray 124.0 (+ 124.0 (* 0.8 i)) #:hp 150.0 #:shield 100.0 #:flying #t))))
  (step-layer1b-mastermind!
   rt-3d
   (mk-live-obs 'Protoss 'Protoss 6350 #:ally-units p-small-army #:ally-buildings p-bldgs-home
                #:enemy-units enemy-strong-seed #:supply-used 48 #:supply-cap 78))
  (define acts-3d-fog
    (run-l34 rt-3d
             (mk-live-obs 'Protoss 'Protoss 6400 #:ally-units p-small-army #:ally-buildings p-bldgs-home
                          #:enemy-units '() #:supply-used 48 #:supply-cap 78)))
  (define pvp-mass-staging-fog? (hash-ref (rt-door-state rt-3d) 'l34-mass-staging? #f))
  ;; With a visible distant enemy unit at enemy natural (not in direct contact, while OWM holds 2800 val):
  ;; restored `early-midgame-pt-timing-exempt?` (0.45x / >=14 sup) clears `l34-mass-staging?` instead of holding!
  (define acts-3d-vis
    (run-l34 rt-3d
             (mk-live-obs 'Protoss 'Protoss 6420 #:ally-units p-small-army #:ally-buildings p-bldgs-home
                          #:enemy-units (list (mk-u 83499 'stalker 122.0 124.0 #:hp 80.0 #:shield 80.0))
                          #:supply-used 48 #:supply-cap 78)))
  (define pvp-mass-staging-vis? (hash-ref (rt-door-state rt-3d) 'l34-mass-staging? #f))
  ;; Control: tiny 4-Stalker (8-supply < 14.0) PvP army STILL stages (`l34-mass-staging? = #t`)!
  (define rt-3d-tiny (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (step-layer1b-mastermind!
   rt-3d-tiny
   (mk-live-obs 'Protoss 'Protoss 6350 #:ally-units (take p-small-army 4) #:ally-buildings p-bldgs-home
                #:enemy-units enemy-strong-seed #:supply-used 36 #:supply-cap 78))
  (run-l34 rt-3d-tiny
           (mk-live-obs 'Protoss 'Protoss 6400 #:ally-units (take p-small-army 4) #:ally-buildings p-bldgs-home
                        #:enemy-units '() #:supply-used 36 #:supply-cap 78))
  (define pvp-tiny-stages? (hash-ref (rt-door-state rt-3d-tiny) 'l34-mass-staging? #f))
  (check-true "L81-3d-pvp-midgame-push-restored-does-not-freeze-passive-at-4m-to-6m"
              (and (not pvp-mass-staging-fog?)
                   (not pvp-mass-staging-vis?)
                   pvp-tiny-stages?)
              (format "massStageFog=~a massStageVis=~a tinyStages=~a fogActs=~a visActs=~a"
                      pvp-mass-staging-fog? pvp-mass-staging-vis? pvp-tiny-stages? acts-3d-fog acts-3d-vis)))

(printf "\n=== Loop 81 Div 8 Runtime Summary: ~a/~a passed (~a failed) ===\n"
        tests-passed tests-run tests-failed)
(when (> tests-failed 0)
  (exit 1))
