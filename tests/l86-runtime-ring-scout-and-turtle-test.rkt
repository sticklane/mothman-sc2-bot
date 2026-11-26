#lang racket/base

(require racket/list
         racket/math
         racket/set
         racket/string
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-bayesian.rkt"
         "../lib/opponent-world-model.rkt"
         "../lib/mirror-mind-predictor.rkt"
         "../lib/tactics/staging-groups.rkt"
         "../lib/tactics/multiprong-coordinator.rkt"
         "../lib/tactics/mode-and-stealth-safety.rkt"
         "../lib/bot-runtime.rkt")

;; =============================================================================
;; Loop 86 Track 4 Unit Test Suite (`tests/l86-runtime-ring-scout-and-turtle-test.rkt`)
;;
;; Verifies runtime integration of:
;;   1. `live-bot-runtime` 19-field ABI preservation & `rt-choke-attrition-state` reset
;;   2. Midgame (`>= 5:30` / `7392f`) single-unit expansion-ring scouting across P/T/Z
;;      and strict bypass `< 5:30`, under base attack, under cheese mode, `--no-macro`,
;;      under active early rush, and for leased / frontline units
;;   3. Early `enemy-turtle-posterior` (`camp >= 0.45` in `[SCBOT_STATE]`) while keeping
;;      our empty natural `pad-camped-posterior` pure (`<= 0.15`), plus macro-cache key
;;      invalidation (`l86-mc-key`) and zero false positive on early rushes
;;   4. End-to-end `hexp >= 0.45` on confirmed enemy base lead and stale outer ring
;;   5. End-to-end softest-outer-base redirect, choke-attrition breaker (outer-pivot vs
;;      bounded hold), and strict cheese / `--no-macro` bypass
;;   6. End-to-end mobile detector army escort across Protoss Observer (1-obs forward,
;;      2-obs home+army split, sieged unmorph), Terran Raven, and Zerg Overseer
;; =============================================================================

(define pass-count 0)
(define fail-count 0)

(define (check-test name pred [detail ""])
  (if pred
      (begin
        (set! pass-count (add1 pass-count))
        (printf "  [PASS] ~a\n" name))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "  [FAIL] ~a~a\n"
                name
                (if (string=? detail "") "" (format " (~a)" detail))))))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (mk-u id type x y
              #:hp [hp 100.0] #:max-hp [max-hp hp]
              #:shield [shield 0.0] #:max-shield [max-shield shield]
              #:energy [energy 0.0]
              #:flying [flying #f]
              #:cloak [cloak 0]
              #:burrowed [burrowed #f]
              #:hallucination [halluc? #f]
              #:order-count [oc 0]
              #:build-progress [bp 1.0])
  (hash 'id id
        'type type
        'x (exact->inexact x)
        'y (exact->inexact y)
        'hp (exact->inexact hp)
        'max-hp (exact->inexact max-hp)
        'shield (exact->inexact shield)
        'max-shield (exact->inexact max-shield)
        'shields (exact->inexact shield)
        'max-shields (exact->inexact max-shield)
        'energy (exact->inexact energy)
        'flying flying
        'is-flying flying
        'cloak cloak
        'cloaked (or (= cloak 1) (= cloak 2))
        'burrowed burrowed
        'is-burrowed burrowed
        'hallucination halluc?
        'is-hallucination halluc?
        'order-count oc
        'build-progress bp
        'display-type 1))

(define (mk-workers type n start-id bx by)
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) type
          (+ bx (- (* 0.4 (modulo i 8)) 2.0))
          (+ by (if (< i 8) -1.5 1.5))
          #:hp (case type [(scv) 45.0] [(drone) 40.0] [else 20.0])
          #:shield (if (eq? type 'probe) 20.0 0.0))))

(define RING-10-PADS
  (list (cons 32.0 32.0)    ;; own main
        (cons 56.0 32.0)    ;; own nat
        (cons 32.0 64.0)    ;; own 3rd
        (cons 60.0 78.0)    ;; own 4th
        (cons 96.0 36.0)    ;; south outer
        (cons 152.0 42.0)   ;; far south-east outer
        (cons 42.0 148.0)   ;; far north-west outer
        (cons 118.0 156.0)  ;; enemy 4th
        (cons 134.0 136.0)  ;; enemy nat
        (cons 158.0 158.0)));; enemy main

(define (mk-live-obs #:race race
                     #:enemy-race enemy-race
                     #:frame frame
                     #:minerals [minerals 450]
                     #:gas [gas 200]
                     #:supply-used [supply-used 64]
                     #:supply-cap [supply-cap 90]
                     #:army-supply [army-supply 28]
                     #:mineral-harvesters [mharv 30]
                     #:gas-harvesters [gharv 6]
                     #:ally-buildings [ally-bldgs '()]
                     #:ally-units [ally-units '()]
                     #:enemy-buildings [enemy-bldgs '()]
                     #:enemy-units [enemy-units '()]
                     #:expansion-candidates [exp-cands RING-10-PADS]
                     #:under-attack? [under-atk? #f]
                     #:base-x [bx 32.0] #:base-y [by 32.0]
                     #:nat-x [nx 56.0] #:nat-y [ny 32.0]
                     #:third-x [tx 32.0] #:third-y [ty 64.0]
                     #:enemy-x [ex 158.0] #:enemy-y [ey 158.0]
                     #:enemy-nat-x [enx 134.0] #:enemy-nat-y [eny 136.0]
                     #:enable-owm? [enable-owm? #t])
  (hash 'frame frame
        'race race
        'enemy-race enemy-race
        'minerals minerals
        'gas gas
        'supply-used supply-used
        'supply-cap supply-cap
        'army-supply army-supply
        'food-army army-supply
        'mineral-harvesters mharv
        'gas-harvesters gharv
        'vespene-harvesters gharv
        'workers (+ mharv gharv)
        'food-workers (+ mharv gharv)
        'under-attack under-atk?
        'under-attack? under-atk?
        'base-x bx 'base-y by
        'nat-x nx 'nat-y ny
        'third-x tx 'third-y ty
        'enemy-x ex 'enemy-y ey
        'enemy-exp-x enx 'enemy-exp-y eny
        'enemy-natural-x enx 'enemy-natural-y eny
        'map-width 200.0 'map-height 200.0
        'expansion-candidates exp-cands
        'enable-opponent-world-model enable-owm?
        'ally-buildings ally-bldgs
        'ally-units ally-units
        'enemy-buildings enemy-bldgs
        'enemy-units enemy-units
        'mineral-patches (list (mk-u 99001 'mineral-field 26.0 32.0 #:hp 1500.0)
                               (mk-u 99002 'mineral-field 52.0 26.0 #:hp 1500.0))
        'vespene-geysers '()))

(define (step-all-actions res)
  (append (hash-ref res 'actions '())
          (hash-ref res 'mirror-actions '())))

(define (action-targets-any-ring-pad? a pads #:own-ths [own-ths (list (cons 32.0 32.0) (cons 56.0 32.0))])
  (and (pair? a)
       (or (and (eq? (car a) 'move) (= (length a) 4))
           (and (eq? (car a) 'cast-spell) (= (length a) 5) (eq? (caddr a) 'scanner-sweep)))
       (let ([tx (if (eq? (car a) 'move) (caddr a) (cadddr a))]
             [ty (if (eq? (car a) 'move) (cadddr a) (car (cddddr a)))])
         (and (real? tx) (real? ty)
              (for/or ([p (in-list pads)])
                (and (not (for/or ([o (in-list own-ths)])
                            (<= (dist2d (car p) (cdr p) (car o) (cdr o)) 10.0)))
                     (<= (dist2d tx ty (car p) (cdr p)) 2.0)))))))

(printf "\n=== Loop 86 Track 4 Runtime Ring Scout, Early Turtle, Choke Breaker & Detector Escort Tests ===\n")

;; =============================================================================
;; 1. ABI & Weak State Invariants
;; =============================================================================
(let ()
  (define rt1 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define rt2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (check-test "T1a-live-bot-runtime-arity-strictly-19-vec-len-20"
              (= (vector-length (struct->vector rt1)) 20)
              (format "vec-len=~a" (vector-length (struct->vector rt1))))
  (define cs1 (rt-choke-attrition-state rt1))
  (define cs2 (rt-choke-attrition-state rt2))
  (check-test "T1b-rt-choke-attrition-state-distinct-per-runtime"
              (and (not (eq? cs1 cs2))
                   (not (choke-attrition-zone-blacklisted? cs1 (cons 120.0 120.0) 8500))))
  ;; Exercise reset hooks
  (reset-wave3-tactical-state! rt1)
  (reset-tactics-arena-runtime-state! rt1)
  (check-test "T1c-reset-hooks-preserve-clean-choke-state"
              (not (choke-attrition-zone-blacklisted? (rt-choke-attrition-state rt1) (cons 120.0 120.0) 8500))))

;; =============================================================================
;; 2. Midgame Expansion-Ring Scout (`>= 5:30` / `7392f`) Across P/T/Z + Safety Guards
;; =============================================================================
(let ()
  ;; 2A: Zerg dispatches 1 idle zergling at frame 7500, acquires 'scout lease, obeys 784f cooldown,
  ;; and NEVER steals leased door-guard or frontline zergling near enemies!
  (define rt-z (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-bldgs
    (list (mk-u 1001 'hatchery 32.0 32.0 #:hp 1500.0)
          (mk-u 1002 'hatchery 56.0 32.0 #:hp 1500.0)
          (mk-u 1003 'spawning-pool 36.0 35.0 #:hp 1000.0)))
  (define z-units
    (append (mk-workers 'drone 24 1100 32.0 32.0)
            (list (mk-u 1201 'zergling 58.0 34.0 #:hp 35.0)     ;; leased door-guard (MUST NOT pick)
                  (mk-u 1202 'zergling 110.0 110.0 #:hp 35.0)   ;; frontline near enemy (MUST NOT pick)
                  (mk-u 1203 'zergling 52.0 42.0 #:hp 35.0))))  ;; safe idle ling (SHOULD pick)
  ;; Pre-lease 1201 as 'door-guard
  (acquire-unit-lease! (rt-role-leases rt-z) 1201 'door-guard 7490 60 #:x 58.0 #:y 34.0)
  (define obs-z
    (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 7500
                 #:ally-buildings z-bldgs
                 #:ally-units z-units
                 #:enemy-units (list (mk-u 1901 'marine 115.0 112.0 #:hp 45.0))
                 #:enemy-buildings (list (mk-u 1951 'command-center 158.0 158.0 #:hp 1500.0))))
  (define acts-z1 (step-layer2-economy! rt-z obs-z))
  (define ring-moves-z1
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-z1))
  (check-test "T2a-zerg-ring-scout-picks-safe-idle-ling-not-door-guard-or-frontline"
              (and (= (length ring-moves-z1) 1)
                   (= (second (car ring-moves-z1)) 1203))
              (format "ring-moves=~a" ring-moves-z1))
  ;; Verify cooldown blocks immediate re-dispatch at frame 7600 (< 7500 + 784)
  (define acts-z2 (step-layer2-economy! rt-z (hash-set obs-z 'frame 7600)))
  (define ring-moves-z2
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-z2))
  (check-test "T2b-zerg-ring-scout-respects-784f-cooldown"
              (null? ring-moves-z2)
              (format "ring-moves-z2=~a" ring-moves-z2))

  ;; 2B: Protoss with sole Observer #1 + Stalkers (army-supply >= 16) keeps sole Observer reserved
  ;; and dispatches 1 Stalker (or Hallucinated Phoenix if present)
  (define rt-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs
    (list (mk-u 2001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 2002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 2003 'gateway 42.0 36.0 #:hp 500.0 #:shield 500.0)))
  (define p-units-sole-obs
    (append (mk-workers 'probe 24 2100 32.0 32.0)
            (list (mk-u 2201 'observer 45.0 35.0 #:hp 40.0 #:shield 20.0 #:flying #t)
                  (mk-u 2202 'stalker 50.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 2203 'stalker 52.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 2204 'stalker 54.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 2205 'stalker 56.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 2206 'stalker 58.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 2207 'stalker 60.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 2208 'stalker 62.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 2209 'stalker 64.0 36.0 #:hp 80.0 #:shield 80.0))))
  (define acts-p
    (step-layer2-economy!
     rt-p
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7500 #:army-supply 20
                  #:ally-buildings p-bldgs #:ally-units p-units-sole-obs
                  #:enemy-buildings (list (mk-u 2951 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define ring-moves-p
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-p))
  (check-test "T2c-protoss-ring-scout-preserves-sole-observer-dispatches-stalker"
              (and (= (length ring-moves-p) 1)
                   (not (= (second (car ring-moves-p)) 2201))
                   (>= (second (car ring-moves-p)) 2202))
              (format "ring-moves-p=~a" ring-moves-p))

  ;; 2C: Terran spare OC scan fallback when 0 reapers/hellions/vikings and >= 2 OCs with >= 120 energy
  (define rt-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-bldgs
    (list (mk-u 3001 'orbital-command 32.0 32.0 #:hp 1500.0 #:energy 135.0)
          (mk-u 3002 'orbital-command 56.0 32.0 #:hp 1500.0 #:energy 125.0)
          (mk-u 3003 'barracks 42.0 36.0 #:hp 1000.0)))
  (define acts-t
    (step-layer2-economy!
     rt-t
     (mk-live-obs #:race 'Terran #:enemy-race 'Zerg #:frame 7500 #:army-supply 24
                  #:ally-buildings t-bldgs
                  #:ally-units (append (mk-workers 'scv 24 3100 32.0 32.0)
                                       (list (mk-u 3201 'marine 52.0 35.0 #:hp 45.0)))
                  #:enemy-buildings (list (mk-u 3951 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define ring-scans-t
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'scanner-sweep)
                             (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-t))
  (check-test "T2d-terran-ring-scout-spare-oc-scan-at-120e"
              (>= (length ring-scans-t) 1)
              (format "ring-scans-t=~a" ring-scans-t))

  ;; 2D: Strict Safety Guards — ZERO ring scout < 5:30, under base attack, cheese mode, or --no-macro!
  (define (count-ring-dispatches rt obs)
    (length (filter (lambda (a) (action-targets-any-ring-pad? a RING-10-PADS))
                    (step-layer2-economy! rt obs))))
  (define rt-early (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (check-test "T2e-zero-ring-scout-before-5m30-opening-wall-window"
              (= 0 (count-ring-dispatches rt-early (hash-set obs-z 'frame 3600))))
  (define rt-atk (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (check-test "T2f-zero-ring-scout-under-base-attack"
              (= 0 (count-ring-dispatches rt-atk (hash-set* obs-z 'under-attack #t 'under-attack? #t))))
  (define rt-cheese (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (set-rt-cheese-mode?! rt-cheese #t)
  (check-test "T2g-zero-ring-scout-under-cheese-mode"
              (= 0 (count-ring-dispatches rt-cheese obs-z)))
  (define rt-nm (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (set-rt-skip-build-order?! rt-nm #t)
  (check-test "T2h-zero-ring-scout-under-nomacro"
              (= 0 (count-ring-dispatches rt-nm obs-z))))

;; =============================================================================
;; 3. Early Enemy Turtle Posterior (`camp >= 0.45`) vs Pure Natural Pad Posterior
;; =============================================================================
(let ()
  (define rt-turtle (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs
    (list (mk-u 4001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 4002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 4003 'gateway 42.0 36.0 #:hp 500.0 #:shield 500.0)
          (mk-u 4004 'robotics-facility 40.0 30.0 #:hp 450.0 #:shield 450.0)))
  (define p-units
    (append (mk-workers 'probe 32 4100 32.0 32.0)
            (list (mk-u 4201 'stalker 64.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 4202 'stalker 66.0 36.0 #:hp 80.0 #:shield 80.0)
                  (mk-u 4203 'immortal 65.0 38.0 #:hp 200.0 #:shield 100.0))))
  ;; Enemy fortress far across map (`134, 136`): PF + 2 Bunkers + 2 Sieged Tanks + 3 Burrowed Mines.
  ;; Our own natural pad (`56, 32`) is 100% EMPTY!
  (define enemy-fort-bldgs
    (list (mk-u 4901 'command-center 158.0 158.0 #:hp 1500.0)
          (mk-u 4902 'planetary-fortress 134.0 136.0 #:hp 1500.0)
          (mk-u 4903 'bunker 130.0 132.0 #:hp 400.0)
          (mk-u 4904 'bunker 132.0 128.0 #:hp 400.0)))
  (define enemy-fort-units
    (list (mk-u 4951 'siege-tank-sieged 135.0 134.0 #:hp 175.0)
          (mk-u 4952 'siege-tank-sieged 133.0 138.0 #:hp 175.0)
          (mk-u 4953 'widow-mine-burrowed 128.0 130.0 #:hp 90.0 #:burrowed #t)
          (mk-u 4954 'widow-mine-burrowed 126.0 132.0 #:hp 90.0 #:burrowed #t)
          (mk-u 4955 'widow-mine-burrowed 129.0 127.0 #:hp 90.0 #:burrowed #t)))
  ;; Step 1 (non-turtle baseline at frame 6710) -> primes macro cache
  (define res-clean
    (step-live-bot-runtime!
     rt-turtle
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 6710
                  #:ally-buildings p-bldgs #:ally-units p-units
                  #:enemy-buildings (list (mk-u 4901 'command-center 158.0 158.0 #:hp 1500.0))
                  #:enemy-units '())))
  (define tel-clean (hash-ref res-clean 'telemetry (hash)))
  (check-test "T3a-clean-non-turtle-low-enemy-turtle-posterior"
              (< (hash-ref tel-clean 'enemy-turtle-posterior 1.0) 0.15)
              (format "clean-turtle-post=~a" (hash-ref tel-clean 'enemy-turtle-posterior #f)))
  ;; Step 2 (frame 6732, 22f later — inside 29f macro cache TTL! — enemy fortress spotted)
  (define res-fort
    (step-live-bot-runtime!
     rt-turtle
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 6732
                  #:ally-buildings p-bldgs #:ally-units p-units
                  #:enemy-buildings enemy-fort-bldgs
                  #:enemy-units enemy-fort-units)))
  (define tel-fort (hash-ref res-fort 'telemetry (hash)))
  (define slog-fort (hash-ref tel-fort 'state-log (hash)))
  (define slog-mind (hash-ref slog-fort 'mind (hash)))
  (define slog-line (hash-ref tel-fort 'state-log-line ""))
  (define raw-nat-camp (hash-ref tel-fort 'pad-camped-posterior 1.0))
  (define turtle-post (hash-ref tel-fort 'enemy-turtle-posterior 0.0))
  (define logged-camp (hash-ref slog-mind 'pad-camped-posterior 0.0))
  (check-test "T3b-early-enemy-turtle-posterior-fires-at-5m"
              (>= turtle-post 0.45)
              (format "enemy-turtle-posterior=~a" turtle-post))
  (check-test "T3c-scbot-state-camp-logs-high-on-enemy-fortress"
              (and (>= logged-camp 0.45)
                   (string-contains? slog-line "camp="))
              (format "logged-camp=~a line=~a" logged-camp slog-line))
  (check-test "T3d-own-empty-natural-pad-camped-posterior-remains-pure"
              (<= raw-nat-camp 0.15)
              (format "raw-nat-pad-camped=~a" raw-nat-camp))
  ;; Verify macro-cache invalidation updated wall-state l86-mc-key immediately within TTL
  (define ws-fort (rt-wall-state rt-turtle))
  (check-test "T3e-macro-cache-key-invalidates-immediately-on-turtle-signal"
              (and (>= (hash-ref ws-fort 'l86-enemy-turtle-posterior 0.0) 0.45)
                   (>= (hash-ref ws-fort 'l86-static-def-count 0) 3)
                   (>= (hash-ref ws-fort 'l86-burrow-mine-count 0) 3)
                   (= (bitwise-and (hash-ref ws-fort 'l86-mc-key 0) 1) 1))
              (format "ws-turtle=~a sd=~a bm=~a key=~a"
                      (hash-ref ws-fort 'l86-enemy-turtle-posterior 0.0)
                      (hash-ref ws-fort 'l86-static-def-count 0)
                      (hash-ref ws-fort 'l86-burrow-mine-count 0)
                      (hash-ref ws-fort 'l86-mc-key 0)))

  ;; 3F: Negative guard — early pure bio rush (0 static defense) stays low turtle posterior!
  (define rt-rush (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-rush
    (step-live-bot-runtime!
     rt-rush
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 3960
                  #:ally-buildings (take p-bldgs 2) #:ally-units p-units
                  #:enemy-buildings (list (mk-u 4991 'command-center 158.0 158.0 #:hp 1500.0))
                  #:enemy-units (for/list ([i (in-range 10)])
                                  (mk-u (+ 4970 i) 'marine (+ 60.0 (* 0.5 i)) 34.0 #:hp 45.0)))))
  (define tel-rush (hash-ref res-rush 'telemetry (hash)))
  (check-test "T3f-early-bio-rush-zero-false-turtle-posterior"
              (<= (hash-ref tel-rush 'enemy-turtle-posterior 1.0) 0.10)
              (format "rush-turtle-post=~a" (hash-ref tel-rush 'enemy-turtle-posterior #f))))

;; =============================================================================
;; 4. End-to-End `hexp >= 0.45` on Confirmed Enemy Base Lead & Stale Ring
;; =============================================================================
(let ()
  (define rt-hexp (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-2base
    (list (mk-u 5001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 5002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)))
  (define e-4base
    (list (mk-u 5901 'command-center 158.0 158.0 #:hp 1500.0)
          (mk-u 5902 'command-center 134.0 136.0 #:hp 1500.0)
          (mk-u 5903 'command-center 118.0 156.0 #:hp 1500.0)
          (mk-u 5904 'command-center 152.0 42.0 #:hp 1500.0)))
  (define res-hexp
    (step-live-bot-runtime!
     rt-hexp
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8404
                  #:ally-buildings p-2base
                  #:ally-units (mk-workers 'probe 30 5100 32.0 32.0)
                  #:enemy-buildings e-4base
                  #:enemy-units '())))
  (define tel-hexp (hash-ref res-hexp 'telemetry (hash)))
  (define slog-mind (hash-ref (hash-ref tel-hexp 'state-log (hash)) 'mind (hash)))
  (define hexp-val (hash-ref slog-mind 'hidden-expand-posterior 0.0))
  (check-test "T4a-end-to-end-hexp-fires-on-4-vs-2-confirmed-enemy-base-lead"
              (>= hexp-val 0.45)
              (format "hexp=~a line=~a" hexp-val (hash-ref tel-hexp 'state-log-line ""))))

;; =============================================================================
;; 5. End-to-End Softest-Outer-Base Redirect + Choke-Attrition Breaker + Bypasses
;; =============================================================================
(let ()
  (define rt-choke (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs
    (list (mk-u 6001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 6002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 6003 'nexus 32.0 64.0 #:hp 1000.0 #:shield 1000.0)))
  ;; Fortified choke at (120, 120), soft open outer base at (152, 42)
  (define fort-and-soft-ebldgs
    (list (mk-u 6901 'command-center 158.0 158.0 #:hp 1500.0)
          (mk-u 6902 'planetary-fortress 120.0 120.0 #:hp 1500.0)
          (mk-u 6903 'bunker 117.0 118.0 #:hp 400.0)
          (mk-u 6904 'bunker 122.0 116.0 #:hp 400.0)
          (mk-u 6905 'command-center 152.0 42.0 #:hp 1500.0)))
  (define fort-eunits
    (list (mk-u 6951 'siege-tank-sieged 121.0 122.0 #:hp 175.0)
          (mk-u 6952 'siege-tank-sieged 119.0 123.0 #:hp 175.0)
          (mk-u 6953 'widow-mine-burrowed 116.0 118.0 #:hp 90.0 #:burrowed #t)))
  (define stalkers-16
    (for/list ([i (in-range 16)])
      (mk-u (+ 6200 i) 'stalker (+ 114.0 (* 0.5 (modulo i 4))) (+ 114.0 (* 0.5 (quotient i 4)))
            #:hp 80.0 #:shield 80.0)))
  (define workers-30 (mk-workers 'probe 30 6100 32.0 32.0))
  ;; Step 1 at 8500: army approaches fortified choke (120, 120) — all 16 Stalkers alive
  (step-live-bot-runtime!
   rt-choke
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8500 #:supply-used 90 #:army-supply 32
                #:ally-buildings p-bldgs #:ally-units (append workers-30 stalkers-16)
                #:enemy-buildings fort-and-soft-ebldgs #:enemy-units fort-eunits))
  ;; Step 2 at 8540: 9 Stalkers vanish near fortified choke (9 * 175 = 1,575 >= 1,200 lost, 0 TH killed)
  (define res-pivot
    (step-live-bot-runtime!
     rt-choke
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8540 #:supply-used 72 #:army-supply 14
                  #:ally-buildings p-bldgs #:ally-units (append workers-30 (take stalkers-16 7))
                  #:enemy-buildings fort-and-soft-ebldgs #:enemy-units fort-eunits)))
  (define sc-pivot (rt-door-state rt-choke))
  (define redir-pt (hash-ref sc-pivot 'l86-choke-redirect-xy #f))
  (define soft-pt (hash-ref sc-pivot 'l86-soft-target-pt #f))
  (check-test "T5a-choke-attrition-blacklists-fortified-zone-and-pivots-to-soft-outer-base"
              (and (choke-attrition-zone-blacklisted? (rt-choke-attrition-state rt-choke) (cons 115.0 115.0) 8540)
                   (not (hash-ref sc-pivot 'l86-choke-hold-active? #t))
                   (pair? redir-pt)
                   (<= (dist2d (car redir-pt) (cdr redir-pt) 152.0 42.0) 6.0)
                   (pair? soft-pt)
                   (<= (dist2d (car soft-pt) (cdr soft-pt) 152.0 42.0) 6.0))
              (format "bl?=~a hold?=~a redir=~a soft=~a reason=~a"
                      (choke-attrition-zone-blacklisted? (rt-choke-attrition-state rt-choke) (cons 115.0 115.0) 8540)
                      (hash-ref sc-pivot 'l86-choke-hold-active? #f)
                      redir-pt soft-pt
                      (hash-ref sc-pivot 'l86-choke-release-reason #f)))

  ;; 5B: When NO soft outer base exists (ONLY fortified choke exists at enemy main/nat), >= 1200 loss enters bounded hold;
  ;; AND strictly bypasses under --no-macro and Cheese Mode!
  (define rt-hold (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define fort-only-ebldgs
    (list (mk-u 6902 'planetary-fortress 120.0 120.0 #:hp 1500.0)
          (mk-u 6903 'bunker 117.0 118.0 #:hp 400.0)
          (mk-u 6904 'bunker 122.0 116.0 #:hp 400.0)))
  (step-live-bot-runtime!
   rt-hold
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8600 #:supply-used 90 #:army-supply 32
                #:enemy-x 120.0 #:enemy-y 120.0 #:enemy-nat-x 120.0 #:enemy-nat-y 120.0
                #:ally-buildings p-bldgs #:ally-units (append workers-30 stalkers-16)
                #:enemy-buildings fort-only-ebldgs #:enemy-units fort-eunits))
  (step-live-bot-runtime!
   rt-hold
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8640 #:supply-used 72 #:army-supply 14
                #:enemy-x 120.0 #:enemy-y 120.0 #:enemy-nat-x 120.0 #:enemy-nat-y 120.0
                #:ally-buildings p-bldgs #:ally-units (append workers-30 (take stalkers-16 7))
                #:enemy-buildings fort-only-ebldgs #:enemy-units fort-eunits))
  (check-test "T5b-choke-attrition-bounded-hold-when-no-soft-outer-base"
              (eq? (hash-ref (rt-door-state rt-hold) 'l86-choke-hold-active? #f) #t)
              (format "hold?=~a reason=~a"
                      (hash-ref (rt-door-state rt-hold) 'l86-choke-hold-active? #f)
                      (hash-ref (rt-door-state rt-hold) 'l86-choke-release-reason #f)))
  ;; Bypass under --no-macro
  (set-rt-skip-build-order?! rt-hold #t)
  (step-live-bot-runtime!
   rt-hold
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8660 #:supply-used 72 #:army-supply 14
                #:enemy-x 120.0 #:enemy-y 120.0 #:enemy-nat-x 120.0 #:enemy-nat-y 120.0
                #:ally-buildings p-bldgs #:ally-units (append workers-30 (take stalkers-16 7))
                #:enemy-buildings fort-only-ebldgs #:enemy-units fort-eunits))
  (check-test "T5c-choke-attrition-bypassed-under-nomacro"
              (not (hash-ref (rt-door-state rt-hold) 'l86-choke-hold-active? #f)))
  ;; Bypass under active cheese mode (1-base committed cheese < 6:30 fallback window)
  (define rt-cheese-choke (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss))
  (set-rt-cheese-mode?! rt-cheese-choke #t)
  (set-rt-cheese-profile! rt-cheese-choke 'pvt-proxy-stargate-voidray)
  (define p-1base (take p-bldgs 1))
  (step-live-bot-runtime!
   rt-cheese-choke
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8080 #:supply-used 40 #:army-supply 24
                #:enemy-x 120.0 #:enemy-y 120.0 #:enemy-nat-x 120.0 #:enemy-nat-y 120.0
                #:ally-buildings p-1base #:ally-units (append (take workers-30 16) stalkers-16)
                #:enemy-buildings fort-only-ebldgs #:enemy-units fort-eunits))
  (step-live-bot-runtime!
   rt-cheese-choke
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8120 #:supply-used 22 #:army-supply 10
                #:enemy-x 120.0 #:enemy-y 120.0 #:enemy-nat-x 120.0 #:enemy-nat-y 120.0
                #:ally-buildings p-1base #:ally-units (append (take workers-30 16) (take stalkers-16 7))
                #:enemy-buildings fort-only-ebldgs #:enemy-units fort-eunits))
  (check-test "T5d-choke-attrition-bypassed-under-cheese-mode"
              (and (cheese-mode-active? rt-cheese-choke)
                   (not (hash-ref (rt-door-state rt-cheese-choke) 'l86-choke-hold-active? #f)))
              (format "cheese?=~a hold?=~a"
                      (cheese-mode-active? rt-cheese-choke)
                      (hash-ref (rt-door-state rt-cheese-choke) 'l86-choke-hold-active? #f))))

;; =============================================================================
;; 6. End-to-End Mobile Detector Army Escort (Observer, Raven, Overseer)
;; =============================================================================
(let ()
  ;; 6A: Protoss sole Observer (sieged far behind at 55,55) with forward army at (110,110) facing
  ;; burrowed Widow Mines & Bunkers at (132,132) and ZERO home threats -> unmorphs to escort army!
  (define rt-p1 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-ths
    (list (mk-u 7001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 7002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)))
  (define fwd-stalkers
    (for/list ([i (in-range 6)])
      (mk-u (+ 7100 i) 'stalker (+ 109.0 (* 0.5 i)) 110.0 #:hp 80.0 #:shield 80.0)))
  (define mine-fort-bldgs
    (list (mk-u 7901 'command-center 158.0 158.0 #:hp 1500.0)
          (mk-u 7902 'bunker 134.0 134.0 #:hp 400.0)
          (mk-u 7903 'bunker 132.0 130.0 #:hp 400.0)))
  (define mine-fort-units
    (list (mk-u 7951 'widow-mine-burrowed 130.0 130.0 #:hp 90.0 #:burrowed #t)
          (mk-u 7952 'widow-mine-burrowed 132.0 128.0 #:hp 90.0 #:burrowed #t)))
  (define acts-p1
    (step-all-actions
     (step-live-bot-runtime!
      rt-p1
      (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8200 #:army-supply 16
                   #:ally-buildings p-ths
                   #:ally-units (cons (mk-u 7201 'observer-siege-mode 55.0 55.0 #:hp 40.0 #:shield 20.0 #:flying #t)
                                      fwd-stalkers)
                   #:enemy-buildings mine-fort-bldgs
                   #:enemy-units mine-fort-units))))
  (define obs1-unmorph?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (= (second a) 7201) (eq? (caddr a) 'morph-observer-mode)))
           acts-p1))
  (define obs1-lease (hash-ref (rt-role-leases rt-p1) 7201 #f))
  (check-test "T6a-protoss-sole-sieged-observer-unmorphs-and-escorts-forward-army"
              (and obs1-unmorph?
                   (unit-role-lease? obs1-lease)
                   (eq? (unit-role-lease-role obs1-lease) 'detector-escort))
              (format "unmorph?=~a lease=~a" obs1-unmorph? obs1-lease))

  ;; 6B: Protoss 2 Observers + active home DT at (38, 34) + forward army at (110, 110):
  ;; Observer #1 (7301 at 45,35) covers home DT, while Observer #2 (7302 at 85,85) escorts forward army!
  (define rt-p2 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-p2
    (step-all-actions
     (step-live-bot-runtime!
      rt-p2
      (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 8200 #:army-supply 16
                   #:ally-buildings p-ths
                   #:ally-units (append (list (mk-u 7301 'observer 45.0 35.0 #:hp 40.0 #:shield 20.0 #:flying #t)
                                              (mk-u 7302 'observer 85.0 85.0 #:hp 40.0 #:shield 20.0 #:flying #t))
                                        fwd-stalkers)
                   #:enemy-buildings (list (mk-u 7911 'nexus 158.0 158.0 #:hp 1000.0)
                                           (mk-u 7912 'dark-shrine 154.0 154.0 #:hp 150.0))
                   #:enemy-units (list (mk-u 7961 'dark-templar 38.0 34.0 #:hp 40.0 #:shield 80.0 #:cloak 2))))))
  (define obs2-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 7302))) acts-p2))
  (define obs2-lease (hash-ref (rt-role-leases rt-p2) 7302 #f))
  (check-test "T6b-protoss-2-observers-splits-1-home-dt-and-1-forward-army-escort"
              (and obs2-move
                   (>= (third obs2-move) 100.0)
                   (>= (fourth obs2-move) 100.0)
                   (unit-role-lease? obs2-lease)
                   (eq? (unit-role-lease-role obs2-lease) 'detector-escort))
              (format "obs2-move=~a lease=~a" obs2-move obs2-lease))

  ;; 6C: Terran Raven escorts forward army against burrowed Widow Mines / Lurkers
  (define rt-tr (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define fwd-bio
    (for/list ([i (in-range 8)])
      (mk-u (+ 7400 i) 'marauder (+ 109.0 (* 0.4 i)) 110.0 #:hp 125.0)))
  (define acts-tr
    (step-all-actions
     (step-live-bot-runtime!
      rt-tr
      (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 8200 #:army-supply 18
                   #:ally-buildings (list (mk-u 7451 'orbital-command 32.0 32.0 #:hp 1500.0)
                                          (mk-u 7452 'orbital-command 56.0 32.0 #:hp 1500.0))
                   #:ally-units (cons (mk-u 7491 'raven 72.0 72.0 #:hp 140.0 #:flying #t #:energy 75.0)
                                      fwd-bio)
                   #:enemy-buildings mine-fort-bldgs
                   #:enemy-units mine-fort-units))))
  (define raven-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 7491))) acts-tr))
  (define raven-lease (hash-ref (rt-role-leases rt-tr) 7491 #f))
  (check-test "T6c-terran-raven-escorts-forward-army-and-acquires-lease"
              (and raven-move
                   (>= (third raven-move) 100.0)
                   (>= (fourth raven-move) 100.0)
                   (unit-role-lease? raven-lease)
                   (eq? (unit-role-lease-role raven-lease) 'detector-escort))
              (format "raven-move=~a lease=~a" raven-move raven-lease))

  ;; 6D: Zerg sieged Overseer trailing far behind forward army unmorphs & acquires escort lease
  (define rt-zo (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define fwd-roaches
    (for/list ([i (in-range 8)])
      (mk-u (+ 7500 i) 'roach (+ 109.0 (* 0.4 i)) 110.0 #:hp 145.0)))
  (define acts-zo
    (step-all-actions
     (step-live-bot-runtime!
      rt-zo
      (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 8200 #:army-supply 16
                   #:ally-buildings (list (mk-u 7551 'lair 32.0 32.0 #:hp 2000.0)
                                          (mk-u 7552 'hatchery 56.0 32.0 #:hp 1500.0))
                   #:ally-units (cons (mk-u 7591 'overseer-siege-mode 60.0 60.0 #:hp 200.0 #:flying #t)
                                      fwd-roaches)
                   #:enemy-buildings mine-fort-bldgs
                   #:enemy-units mine-fort-units))))
  (define ov-unmorph?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (= (second a) 7591) (eq? (caddr a) 'morph-overseer-mode)))
           acts-zo))
  (define ov-lease (hash-ref (rt-role-leases rt-zo) 7591 #f))
  (check-test "T6d-zerg-sieged-overseer-unmorphs-and-escorts-forward-army"
              (and ov-unmorph?
                   (unit-role-lease? ov-lease)
                   (eq? (unit-role-lease-role ov-lease) 'detector-escort))
              (format "ov-unmorph?=~a lease=~a" ov-unmorph? ov-lease)))

;; =============================================================================
;; 7. Loop 86B Main-Army Target Override Strict Gate & Same-Tag PF Morph Update
;; =============================================================================
(let ()
  (define t-ths
    (list (mk-u 8001 'orbital-command 32.0 32.0 #:hp 1500.0)
          (mk-u 8002 'orbital-command 56.0 32.0 #:hp 1500.0)
          (mk-u 8003 'orbital-command 32.0 64.0 #:hp 1500.0)))
  (define t-army
    (append (mk-workers 'scv 24 8100 32.0 32.0)
            (for/list ([i (in-range 16)])
              (mk-u (+ 8200 i) 'marine (+ 92.0 (* 0.4 (modulo i 4))) (+ 92.0 (* 0.4 (quotient i 4))) #:hp 45.0))))

  ;; T7a: Non-turtle 2-3 base opponent at 6:30 (frame=8736, camp<0.45, eb-cnt=3, no choke redirect)
  ;; MUST NOT hijack main army push (`l86-effective-push-pt == #f`)!
  (define rt-nt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (step-live-bot-runtime!
   rt-nt
   (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 8736 #:army-supply 32 #:supply-used 72
                #:ally-buildings t-ths #:ally-units t-army
                #:enemy-buildings (list (mk-u 8901 'command-center 158.0 158.0 #:hp 1500.0)
                                        (mk-u 8902 'command-center 134.0 136.0 #:hp 1500.0)
                                        (mk-u 8903 'command-center 118.0 156.0 #:hp 1500.0))
                #:enemy-units '()))
  (check-test "T7a-l86b-non-turtle-3base-timing-push-never-hijacked"
              (not (hash-ref (rt-door-state rt-nt) 'l86-effective-push-pt #f))
              (format "push-pt=~a" (hash-ref (rt-door-state rt-nt) 'l86-effective-push-pt #f)))

  ;; T7b: Fortified front door (camp>=0.45 + avoid-pt) + soft outer base -> DOES redirect main army!
  (define rt-ft (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (step-live-bot-runtime!
   rt-ft
   (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 8736 #:army-supply 32 #:supply-used 72
                #:ally-buildings t-ths #:ally-units t-army
                #:enemy-buildings (list (mk-u 8911 'command-center 158.0 158.0 #:hp 1500.0)
                                        (mk-u 8912 'planetary-fortress 120.0 120.0 #:hp 1500.0)
                                        (mk-u 8913 'bunker 118.0 118.0 #:hp 400.0)
                                        (mk-u 8914 'bunker 122.0 117.0 #:hp 400.0)
                                        (mk-u 8915 'command-center 152.0 42.0 #:hp 1500.0))
                #:enemy-units (list (mk-u 8951 'siege-tank-sieged 121.0 121.0 #:hp 175.0))))
  (define ft-push (hash-ref (rt-door-state rt-ft) 'l86-effective-push-pt #f))
  (check-test "T7b-l86b-fortified-front-door-redirects-to-soft-outer-base"
              (pair? ft-push)
              (format "ft-push=~a" ft-push))

  ;; T7c: Wide 4+-base opponent at >= 8:00 (frame=10800) -> DOES allow soft outer base targeting!
  (define rt-4b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (step-live-bot-runtime!
   rt-4b
   (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 10800 #:army-supply 32 #:supply-used 72
                #:ally-buildings t-ths #:ally-units t-army
                #:enemy-buildings (list (mk-u 8921 'command-center 158.0 158.0 #:hp 1500.0)
                                        (mk-u 8922 'command-center 134.0 136.0 #:hp 1500.0)
                                        (mk-u 8923 'command-center 118.0 156.0 #:hp 1500.0)
                                        (mk-u 8924 'command-center 152.0 42.0 #:hp 1500.0))
                #:enemy-units '()))
  (define b4-push (hash-ref (rt-door-state rt-4b) 'l86-effective-push-pt #f))
  (check-test "T7c-l86b-wide-4base-at-8m-allows-soft-outer-target"
              (and (pair? b4-push) (<= (dist2d (car b4-push) (cdr b4-push) 152.0 42.0) 10.0))
              (format "b4-push=~a" b4-push))

  ;; T7d: Same building tag morphs `command-center` -> `planetary-fortress` live -> immediate `camp >= 0.45`!
  (define rt-pf (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-2h (list (mk-u 8801 'hatchery 32.0 32.0 #:hp 1500.0)
                     (mk-u 8802 'hatchery 56.0 32.0 #:hp 1500.0)))
  (step-live-bot-runtime!
   rt-pf
   (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 7370
                #:ally-buildings z-2h #:ally-units (mk-workers 'drone 24 8810 32.0 32.0)
                #:enemy-buildings (list (mk-u 8991 'command-center 158.0 158.0 #:hp 1500.0)
                                        (mk-u 8992 'command-center 134.0 136.0 #:hp 1500.0))))
  (define res-pf-morphed
    (step-live-bot-runtime!
     rt-pf
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 7392
                  #:ally-buildings z-2h #:ally-units (mk-workers 'drone 24 8810 32.0 32.0)
                  #:enemy-buildings (list (mk-u 8991 'command-center 158.0 158.0 #:hp 1500.0)
                                          (mk-u 8992 'planetary-fortress 134.0 136.0 #:hp 1500.0)))))
  (define tel-pf (hash-ref res-pf-morphed 'telemetry (hash)))
  (define camp-pf (hash-ref (hash-ref (hash-ref tel-pf 'state-log (hash)) 'mind (hash)) 'pad-camped-posterior 0.0))
  (check-test "T7d-l86b-same-tag-cc-to-pf-morph-raises-camp-immediately"
              (and (>= (hash-ref tel-pf 'enemy-turtle-posterior 0.0) 0.45)
                   (>= camp-pf 0.45))
              (format "turtle=~a camp=~a" (hash-ref tel-pf 'enemy-turtle-posterior 0.0) camp-pf)))

;; =============================================================================
;; 8. Loop 86C Track 4: Clause #3 Gate, In-Flight Nexus 400M Reserve, Safe In-Main Pylon
;; =============================================================================
(let ()
  ;; T8a: Clause #3 strictly requires own-bases >= 3 AND (not under-tactics-base-attack?)
  (define p-2base
    (list (mk-u 9001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)))
  (define p-3base
    (append p-2base
            (list (mk-u 9003 'nexus 32.0 64.0 #:hp 1000.0 #:shield 1000.0))))
  (define p-army
    (append (mk-workers 'probe 36 9100 32.0 32.0)
            (for/list ([i (in-range 16)])
              (mk-u (+ 9200 i) 'stalker (+ 92.0 (* 0.4 (modulo i 4))) (+ 92.0 (* 0.4 (quotient i 4)))
                    #:hp 80.0 #:shield 80.0))))
  (define e-4base
    (list (mk-u 9901 'command-center 158.0 158.0 #:hp 1500.0)
          (mk-u 9902 'command-center 134.0 136.0 #:hp 1500.0)
          (mk-u 9903 'command-center 118.0 156.0 #:hp 1500.0)
          (mk-u 9904 'command-center 152.0 42.0 #:hp 1500.0)))
  (define rt-c3-2b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (step-live-bot-runtime!
   rt-c3-2b
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 10800 #:army-supply 32 #:supply-used 68
                #:ally-buildings p-2base #:ally-units p-army
                #:enemy-buildings e-4base #:enemy-units '()))
  (define c3-2b-pt (hash-ref (rt-door-state rt-c3-2b) 'l86-effective-push-pt #f))
  (define rt-c3-atk (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (step-live-bot-runtime!
   rt-c3-atk
   (hash-set*
    (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 10800 #:army-supply 32 #:supply-used 68
                 #:ally-buildings p-3base #:ally-units p-army
                 #:enemy-buildings e-4base
                 #:enemy-units (for/list ([i (in-range 6)])
                                 (mk-u (+ 9950 i) 'marine (+ 58.0 (* 0.4 i)) 34.0 #:hp 45.0)))
    'under-attack #t 'under-attack? #t))
  (define c3-atk-pt (hash-ref (rt-door-state rt-c3-atk) 'l86-effective-push-pt #f))
  (define rt-c3-3b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (step-live-bot-runtime!
   rt-c3-3b
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 10800 #:army-supply 32 #:supply-used 68
                #:ally-buildings p-3base #:ally-units p-army
                #:enemy-buildings e-4base #:enemy-units '()))
  (define c3-3b-pt (hash-ref (rt-door-state rt-c3-3b) 'l86-effective-push-pt #f))
  (check-test "T8a-l86c-clause3-requires-3bases-and-not-under-base-attack"
              (and (not c3-2b-pt)
                   (not c3-atk-pt)
                   (pair? c3-3b-pt)
                   (<= (dist2d (car c3-3b-pt) (cdr c3-3b-pt) 152.0 42.0) 10.0))
              (format "2b=~a atk=~a 3b=~a" c3-2b-pt c3-atk-pt c3-3b-pt))

  ;; T8b: Protoss Probe holding ability 880 (BUILD_NEXUS) preserves 400M out of spendable minerals,
  ;; allows surplus above 400M only, and releases immediately once 3rd Nexus materializes!
  (define (protoss-spend-cost acts)
    (for/sum ([a (in-list acts)])
      (cond
        [(and (pair? a) (eq? (car a) 'build) (pair? (cdr a)))
         (case (second a)
           [(pylon) 100] [(gateway) 150] [(templar-archive) 150] [(assimilator) 75]
           [(robotics-facility) 150] [(robotics-bay) 150] [(forge) 150] [(stargate) 150]
           [(shield-battery) 100] [(photon-cannon) 150] [(dark-shrine) 150] [else 100])]
        [(and (pair? a) (eq? (car a) 'train) (pair? (cdr a)))
         (case (second a)
           [(probe) 50] [(zealot) 100] [(stalker) 125] [(adept) 100] [(sentry) 50]
           [(warp-prism) 250] [(immortal) 275] [(observer) 25] [(colossus) 300]
           [(high-templar) 50] [(dark-templar) 125] [else 100])]
        [else 0])))
  (define rt-nx (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define nx-bldgs-2b
    (list (mk-u 9301 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9302 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9303 'pylon 36.0 36.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9304 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9305 'pylon 42.0 36.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9306 'gateway 38.0 36.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9307 'gateway 40.0 36.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9308 'gateway 42.0 32.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9309 'gateway 44.0 32.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9310 'cybernetics-core 36.0 30.0 #:hp 550.0 #:shield 550.0)
          (mk-u 9311 'twilight-council 35.0 38.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9312 'robotics-facility 37.0 28.0 #:hp 450.0 #:shield 450.0)))
  (define walking-probe-880
    (hash-set (mk-u 9399 'probe 44.0 52.0 #:hp 20.0 #:shield 20.0) 'order-ability-id 880))
  (define nx-units-walking
    (append (mk-workers 'probe 42 9400 32.0 32.0)
            (list walking-probe-880)
            (for/list ([i (in-range 10)])
              (mk-u (+ 9460 i) 'stalker (+ 58.0 (* 0.4 i)) 34.0 #:hp 80.0 #:shield 80.0))))
  ;; 440M with Probe holding 880 -> spendable is 40M -> ZERO spend (actual SC2 minerals stay >= 400M!)
  (define acts-nx-440
    (step-layer2-economy!
     rt-nx
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6200
                  #:minerals 440 #:gas 250 #:supply-used 70 #:supply-cap 74 #:army-supply 20
                  #:ally-buildings nx-bldgs-2b #:ally-units nx-units-walking
                  #:enemy-buildings (list (mk-u 9911 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define spend-440 (protoss-spend-cost acts-nx-440))
  (define res-440 (hash-ref (rt-door-state rt-nx) 'l86c-nexus-inflight-reserve-min 0))
  ;; 540M with Probe holding 880 -> spendable is 140M -> spend <= 140M so actual SC2 minerals stay >= 400M!
  (define acts-nx-540
    (step-layer2-economy!
     rt-nx
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6220
                  #:minerals 540 #:gas 250 #:supply-used 70 #:supply-cap 74 #:army-supply 20
                  #:ally-buildings nx-bldgs-2b #:ally-units nx-units-walking
                  #:enemy-buildings (list (mk-u 9911 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define spend-540 (protoss-spend-cost acts-nx-540))
  ;; 3rd Nexus materializes at (32, 64) with build-progress 0.05 & Probe cleared order 880 -> reserve releases immediately!
  (define nx-bldgs-3b
    (cons (hash-set (mk-u 9319 'nexus 32.0 64.0 #:hp 100.0 #:shield 100.0) 'build-progress 0.05)
          nx-bldgs-2b))
  (define nx-units-done
    (append (mk-workers 'probe 43 9400 32.0 32.0)
            (for/list ([i (in-range 10)])
              (mk-u (+ 9460 i) 'stalker (+ 58.0 (* 0.4 i)) 34.0 #:hp 80.0 #:shield 80.0))))
  (define acts-nx-mat
    (step-layer2-economy!
     rt-nx
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6240
                  #:minerals 260 #:gas 250 #:supply-used 70 #:supply-cap 74 #:army-supply 20
                  #:ally-buildings nx-bldgs-3b #:ally-units nx-units-done
                  #:enemy-buildings (list (mk-u 9911 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define res-mat (hash-ref (rt-door-state rt-nx) 'l86c-nexus-inflight-reserve-min 999))
  (define spend-mat (protoss-spend-cost acts-nx-mat))
  (check-test "T8b-l86c-protoss-nexus-inflight-880-preserves-400m-and-releases-on-start"
              (and (= res-440 400)
                   (<= spend-440 40)
                   (<= spend-540 140)
                   (= res-mat 0)
                   (> spend-mat 0))
              (format "res440=~a sp440=~a sp540=~a resMat=~a spMat=~a acts440=~a"
                      res-440 spend-440 spend-540 res-mat spend-mat acts-nx-440))

  ;; T8c: Protoss 12s (268f) post-issue walk window preserves 400M even after 16f oledger TTL expires,
  ;; then auto-releases after 268f timeout!
  (define rt-nx-win (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  ;; Prime step at f=6000 where 2-base Protoss emits `(expand ...)` (recording l86c-nexus-issue-frame=6000)
  (define acts-nx-emit
    (step-layer2-economy!
     rt-nx-win
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 6000
                  #:minerals 750 #:gas 150 #:supply-used 68 #:supply-cap 94 #:army-supply 20
                  #:ally-buildings nx-bldgs-2b #:ally-units nx-units-done
                  #:enemy-buildings (list (mk-u 9912 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define emitted-expand?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts-nx-emit))
  ;; Step at f=6120 (120f later, >16f oledger TTL, <=268f walk window, no 880 order on Probe hash, still 2 Nexuses)
  (define acts-nx-mid
    (step-layer2-economy!
     rt-nx-win
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 6120
                  #:minerals 440 #:gas 250 #:supply-used 68 #:supply-cap 72 #:army-supply 20
                  #:ally-buildings nx-bldgs-2b #:ally-units nx-units-done
                  #:enemy-buildings (list (mk-u 9912 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define res-mid (hash-ref (rt-door-state rt-nx-win) 'l86c-nexus-inflight-reserve-min 0))
  (define spend-mid (protoss-spend-cost acts-nx-mid))
  ;; Step at f=6300 (300f > 268f timeout) -> window expires and releases 400M!
  (step-layer2-economy!
   rt-nx-win
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 6300
                #:minerals 300 #:gas 250 #:supply-used 68 #:supply-cap 78 #:army-supply 20
                #:ally-buildings nx-bldgs-2b #:ally-units nx-units-done
                #:enemy-buildings (list (mk-u 9912 'command-center 158.0 158.0 #:hp 1500.0))))
  (define res-exp (hash-ref (rt-door-state rt-nx-win) 'l86c-nexus-inflight-reserve-min 999))
  (check-test "T8c-l86c-protoss-nexus-12s-walk-window-preserves-400m-and-expires"
              (and emitted-expand?
                   (= res-mid 400)
                   (<= spend-mid 40)
                   (= res-exp 0))
              (format "emit?=~a actsEmit=~a resMid=~a spMid=~a resExp=~a"
                      emitted-expand? acts-nx-emit res-mid spend-mid res-exp))

  ;; T8d: Protoss supply-blocked (supply-left <= 0) for >= 8s (179f) with enemies camping natural
  ;; forces safe in-main Pylon placement (<= 14t of main Nexus, away from enemies), even with
  ;; protoss-pylon-count = 2 (which normally uses natural anchor) AND an unpowered natural Gateway!
  (define rt-sb (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define sb-bldgs
    (list (mk-u 9501 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9502 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9503 'pylon 36.0 36.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9504 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
          (hash-set (mk-u 9505 'gateway 58.0 34.0 #:hp 500.0 #:shield 500.0) 'powered? #f)))
  (define sb-enemies
    (list (mk-u 9591 'stalker 62.0 34.0 #:hp 80.0 #:shield 80.0)
          (mk-u 9592 'stalker 61.0 32.0 #:hp 80.0 #:shield 80.0)))
  ;; Start continuous supply-block clock at frame 7000 (minerals < 100 so no Pylon emitted yet)
  (step-layer2-economy!
   rt-sb
   (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 7000
                #:minerals 80 #:gas 100 #:supply-used 54 #:supply-cap 54 #:army-supply 16
                #:ally-buildings sb-bldgs #:ally-units (mk-workers 'probe 30 9510 32.0 32.0)
                #:enemy-units sb-enemies
                #:enemy-buildings (list (mk-u 9599 'nexus 158.0 158.0 #:hp 1000.0))))
  ;; 200f (>= 179f / 8s) later, still supply-blocked at high mineral bank (900M) -> safe in-main Pylon!
  (define acts-sb
    (step-layer2-economy!
     rt-sb
     (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 7200
                  #:minerals 900 #:gas 100 #:supply-used 54 #:supply-cap 54 #:army-supply 16
                  #:ally-buildings sb-bldgs #:ally-units (mk-workers 'probe 30 9510 32.0 32.0)
                  #:enemy-units sb-enemies
                  #:enemy-buildings (list (mk-u 9599 'nexus 158.0 158.0 #:hp 1000.0)))))
  (define sb-pylon-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-sb))
  (define sb-d-main (and sb-pylon-act (dist2d (third sb-pylon-act) (fourth sb-pylon-act) 32.0 32.0)))
  (define sb-d-enemy (and sb-pylon-act (dist2d (third sb-pylon-act) (fourth sb-pylon-act) 62.0 34.0)))
  (check-test "T8d-l86c-8s-supply-block-forces-safe-inmain-pylon-away-from-natural-enemies"
              (and (eq? (hash-ref (rt-door-state rt-sb) 'l86c-sb-stalled? #f) #t)
                   (eq? (hash-ref (rt-door-state rt-sb) 'l86c-force-safe-inmain-pylon? #f) #t)
                   sb-pylon-act
                   (<= sb-d-main 14.0)
                   (> sb-d-enemy 12.0))
              (format "stalled?=~a act=~a dMain=~a dEnemy=~a"
                      (hash-ref (rt-door-state rt-sb) 'l86c-sb-stalled? #f)
                      sb-pylon-act sb-d-main sb-d-enemy))

  ;; T8e: 2 consecutive failed exposed natural Pylon placements (without 8s supply block)
  ;; trigger l86c-pylon-fail-streak >= 2 and force safe in-main Pylon placement (<= 14t of main)!
  (define rt-pf2 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define pf2-bldgs
    (list (mk-u 9601 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9602 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9603 'pylon 36.0 36.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9604 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)))
  ;; Attempt 1 (f=7000): 2 pylons -> natural anchor (> 14t from main); enemies out of 12t sight
  (define acts-pf2-1
    (step-layer2-economy!
     rt-pf2
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7000
                  #:minerals 300 #:gas 100 #:supply-used 52 #:supply-cap 54 #:army-supply 16
                  #:ally-buildings pf2-bldgs #:ally-units (mk-workers 'probe 30 9610 32.0 32.0)
                  #:enemy-buildings (list (mk-u 9699 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define py1 (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-pf2-1))
  ;; Attempt 2 (f=7060): Attempt 1 never materialized -> fail-streak becomes 1, still tries natural anchor
  (define acts-pf2-2
    (step-layer2-economy!
     rt-pf2
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7060
                  #:minerals 300 #:gas 100 #:supply-used 52 #:supply-cap 54 #:army-supply 16
                  #:ally-buildings pf2-bldgs #:ally-units (mk-workers 'probe 30 9610 32.0 32.0)
                  #:enemy-buildings (list (mk-u 9699 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define py2 (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-pf2-2))
  ;; Attempt 3 (f=7120): Attempt 2 never materialized -> fail-streak hits 2 -> FORCES safe in-main (<= 14t)!
  (define acts-pf2-3
    (step-layer2-economy!
     rt-pf2
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7120
                  #:minerals 300 #:gas 100 #:supply-used 52 #:supply-cap 54 #:army-supply 16
                  #:ally-buildings pf2-bldgs #:ally-units (mk-workers 'probe 30 9610 32.0 32.0)
                  #:enemy-buildings (list (mk-u 9699 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define py3 (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-pf2-3))
  (define d1 (and py1 (dist2d (third py1) (fourth py1) 32.0 32.0)))
  (define d2 (and py2 (dist2d (third py2) (fourth py2) 32.0 32.0)))
  (define d3 (and py3 (dist2d (third py3) (fourth py3) 32.0 32.0)))
  (check-test "T8e-l86c-two-failed-exposed-pylons-force-safe-inmain-placement"
              (and py1 (> d1 14.0)
                   py2 (> d2 14.0)
                   (>= (hash-ref (rt-door-state rt-pf2) 'l86c-pylon-fail-streak 0) 2)
                   (eq? (hash-ref (rt-door-state rt-pf2) 'l86c-force-safe-inmain-pylon? #f) #t)
                   py3 (<= d3 14.0))
              (format "d1=~a d2=~a d3=~a streak=~a py3=~a"
                      d1 d2 d3 (hash-ref (rt-door-state rt-pf2) 'l86c-pylon-fail-streak 0) py3))

  ;; T8f: Opening wall Pylon #1 (< 3:30, real-pylon-count = 0, supply-left = 1) stays untouched!
  (define rt-open (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define acts-open
    (step-layer2-economy!
     rt-open
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 420
                  #:minerals 110 #:gas 0 #:supply-used 14 #:supply-cap 15 #:army-supply 0
                  #:ally-buildings (list (mk-u 9701 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0))
                  #:ally-units (mk-workers 'probe 14 9710 32.0 32.0)
                  #:enemy-buildings (list (mk-u 9799 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define py-open (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-open))
  (check-test "T8f-l86c-opening-wall-pylon1-remains-untouched"
              (and py-open
                   (not (hash-ref (rt-door-state rt-open) 'l86c-force-safe-inmain-pylon? #f))
                   (not (hash-ref (rt-door-state rt-open) 'l86c-sb-stalled? #f)))
              (format "py-open=~a force?=~a"
                      py-open (hash-ref (rt-door-state rt-open) 'l86c-force-safe-inmain-pylon? #f))))

;; =============================================================================
;; 9. Loop 86C Track C1: `[SCBOT_STATE]` eB/eG Logging, Early Gas Scouting & Terran Ring Sweeps
;; =============================================================================
(let ()
  ;; T9a: Live step at 10:00 (f=13440) emits `[SCBOT_STATE]` with `eB=<c>/<e> eG=<c>/<e>`,
  ;; populates state-log hash keys, and sets l86-mc-key bit 256 (est-bases >= 4).
  (define rt-eb (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-eb
    (step-live-bot-runtime!
     rt-eb
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 13440
                  #:minerals 400 #:gas 200 #:supply-used 90 #:supply-cap 110 #:army-supply 36
                  #:ally-buildings (list (mk-u 9801 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 9802 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 9803 'nexus 32.0 64.0 #:hp 1000.0 #:shield 1000.0))
                  #:ally-units (mk-workers 'probe 50 9810 32.0 32.0)
                  #:enemy-buildings (list (mk-u 9891 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define tel-eb (hash-ref res-eb 'telemetry (hash)))
  (define slog-eb (hash-ref tel-eb 'state-log (hash)))
  (define sline-eb (hash-ref tel-eb 'state-log-line ""))
  (define est-b (hash-ref slog-eb 'enemy-estimated-bases 0))
  (define est-g (hash-ref slog-eb 'enemy-estimated-gases 0))
  (define ws-eb (rt-wall-state rt-eb))
  (check-test "T9a-l86c-scbot-state-logs-eb-eg-and-buckets-est-bases"
              (and (regexp-match? #rx" eB=[0-9]+/[0-9]+ eG=[0-9]+/[0-9]+" sline-eb)
                   (>= est-b 4)
                   (>= est-g 4)
                   (>= (hash-ref ws-eb 'l86-enemy-estimated-bases 0) 4)
                   (not (= 0 (bitwise-and (hash-ref ws-eb 'l86-mc-key 0) 256))))
              (format "estB=~a estG=~a mcKey=~a line=~a"
                      est-b est-g (hash-ref ws-eb 'l86-mc-key 0) sline-eb))

  ;; T9b: Zerg Overlord #1 peeks ~11t from enemy main at 1:35-2:30 when confirmed-geysers == 0
  ;; & 0 AA within 14t, then IMMEDIATELY aborts & kites home the instant a Marine enters 14t!
  (define rt-ov (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-base-b
    (list (mk-u 9821 'hatchery 32.0 32.0 #:hp 1500.0)
          (mk-u 9822 'hatchery 56.0 32.0 #:hp 1500.0)))
  (define ov1-safe (hash-set (mk-u 9831 'overlord 136.0 138.0 #:hp 200.0 #:flying #t) 'max-hp 200.0))
  (define acts-ov-peek
    (step-layer2-economy!
     rt-ov
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 2200
                  #:minerals 120 #:gas 0 #:supply-used 22 #:supply-cap 28 #:army-supply 0
                  #:ally-buildings z-base-b
                  #:ally-units (cons ov1-safe (mk-workers 'drone 20 9840 32.0 32.0))
                  #:enemy-buildings (list (mk-u 9892 'command-center 158.0 158.0 #:hp 1500.0))
                  #:enemy-units '())))
  (define ov-peek-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'overlord-scout) (= (second a) 9831))) acts-ov-peek))
  (define peek-d-main
    (and ov-peek-act (dist2d (third ov-peek-act) (fourth ov-peek-act) 158.0 158.0)))
  ;; Now an enemy Marine appears 10t away from Overlord #1 -> instant kite retreat!
  (define ov1-at-edge (hash-set (mk-u 9831 'overlord 148.0 148.0 #:hp 200.0 #:flying #t) 'max-hp 200.0))
  (define acts-ov-retreat
    (step-layer2-economy!
     rt-ov
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 2224
                  #:minerals 140 #:gas 0 #:supply-used 22 #:supply-cap 28 #:army-supply 0
                  #:ally-buildings z-base-b
                  #:ally-units (cons ov1-at-edge (mk-workers 'drone 20 9840 32.0 32.0))
                  #:enemy-buildings (list (mk-u 9892 'command-center 158.0 158.0 #:hp 1500.0))
                  #:enemy-units (list (mk-u 9895 'marine 152.0 152.0 #:hp 45.0)))))
  (define ov-kite-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 9831))) acts-ov-retreat))
  (check-test "T9b-l86c-zerg-overlord-main-edge-peek-and-instant-aa-retreat"
              (and ov-peek-act
                   (<= (abs (- peek-d-main 11.0)) 2.5)
                   ov-kite-act
                   (< (third ov-kite-act) 148.0)
                   (< (fourth ov-kite-act) 148.0))
              (format "peek=~a dMain=~a kite=~a" ov-peek-act peek-d-main ov-kite-act))

  ;; T9c: Zerg 2:45-3:45 (f=4032) lone Ling gas-poke when confirmed-geysers == 0 & >= 4 Lings,
  ;; never stealing a leased door-guard!
  (define rt-lp (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (acquire-unit-lease! (rt-role-leases rt-lp) 9851 'door-guard 4032 200 #:x 60.0 #:y 32.0)
  (define acts-lp
    (step-layer2-economy!
     rt-lp
     (mk-live-obs #:race 'Zerg #:enemy-race 'Protoss #:frame 4032
                  #:minerals 120 #:gas 0 #:supply-used 30 #:supply-cap 36 #:army-supply 2
                  #:ally-buildings z-base-b
                  #:ally-units (append (mk-workers 'drone 24 9860 32.0 32.0)
                                       (list (mk-u 9851 'zergling 60.0 32.0 #:hp 35.0)
                                             (mk-u 9852 'zergling 58.0 34.0 #:hp 35.0)
                                             (mk-u 9853 'zergling 54.0 34.0 #:hp 35.0)
                                             (mk-u 9854 'zergling 52.0 34.0 #:hp 35.0)))
                  #:enemy-buildings (list (mk-u 9893 'nexus 158.0 158.0 #:hp 1000.0)))))
  (define lp-move
    (findf (lambda (a)
             (and (pair? a) (eq? (car a) 'move)
                  (>= (second a) 9851) (<= (second a) 9854)
                  (<= (dist2d (third a) (fourth a) 134.0 136.0) 4.0)))
           acts-lp))
  (check-test "T9c-l86c-zerg-3m-ling-gas-poke-preserves-door-guard"
              (and lp-move (not (= (second lp-move) 9851)))
              (format "lp-move=~a" lp-move))

  ;; T9d: Terran opening Reaper (2:30-4:15, hp >= 35, confirmed-geysers < 2) peeks enemy main cliff!
  (define rt-rp (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-rp
    (step-layer2-economy!
     rt-rp
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 4032
                  #:minerals 120 #:gas 40 #:supply-used 24 #:supply-cap 31 #:army-supply 1
                  #:ally-buildings (list (mk-u 9871 'orbital-command 32.0 32.0 #:hp 1500.0)
                                         (mk-u 9872 'command-center 56.0 32.0 #:hp 1500.0))
                  #:ally-units (cons (mk-u 9879 'reaper 90.0 90.0 #:hp 60.0)
                                     (mk-workers 'scv 20 9880 32.0 32.0))
                  #:enemy-buildings (list (mk-u 9894 'nexus 158.0 158.0 #:hp 1000.0)))))
  (define rp-move
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 9879))) acts-rp))
  (check-test "T9d-l86c-terran-opening-reaper-cliff-peek-into-enemy-main"
              (and rp-move
                   (<= (dist2d (third rp-move) (fourth rp-move) 158.0 158.0) 14.0))
              (format "rp-move=~a" rp-move))

  ;; T9e: Terran midgame ring-scout dispatches 1 lone Marine (>= 12 Marines, army >= 20) at 560f cd
  ;; when >= 4 pads are stale, AND falls back to 100-energy OC scan when < 12 Marines!
  (define rt-tm (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-2oc-105e
    (list (mk-u 9921 'orbital-command 32.0 32.0 #:hp 1500.0 #:energy 105.0)
          (mk-u 9922 'orbital-command 56.0 32.0 #:hp 1500.0 #:energy 105.0)
          (mk-u 9923 'barracks 42.0 36.0 #:hp 1000.0)))
  (define marines-12
    (for/list ([i (in-range 12)])
      (mk-u (+ 9930 i) 'marine (+ 52.0 (* 0.4 i)) 36.0 #:hp 45.0)))
  (define obs-tm-base
    (mk-live-obs #:race 'Terran #:enemy-race 'Zerg #:frame 7500 #:army-supply 24 #:supply-used 56
                 #:ally-buildings t-2oc-105e
                 #:ally-units (append (mk-workers 'scv 24 9950 32.0 32.0) marines-12)
                 #:enemy-buildings (list (mk-u 9981 'hatchery 158.0 158.0 #:hp 1500.0))))
  (define acts-tm1 (step-layer2-economy! rt-tm obs-tm-base))
  (define tm1-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-tm1))
  ;; 400f later (< 560f) -> still on cooldown; 580f later (>= 560f) -> dispatches again!
  (define acts-tm-cd (step-layer2-economy! rt-tm (hash-set obs-tm-base 'frame 7900)))
  (define tm-cd-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-tm-cd))
  (define acts-tm2 (step-layer2-economy! rt-tm (hash-set obs-tm-base 'frame 8080)))
  (define tm2-moves
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'move) (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-tm2))
  ;; With < 12 Marines (6 Marines) & 105-energy OCs (>= 100e when >= 4 stale pads) -> OC scanner-sweep!
  (define rt-ts (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-ts
    (step-layer2-economy!
     rt-ts
     (mk-live-obs #:race 'Terran #:enemy-race 'Zerg #:frame 7500 #:army-supply 20 #:supply-used 48
                  #:ally-buildings t-2oc-105e
                  #:ally-units (append (mk-workers 'scv 24 9950 32.0 32.0) (take marines-12 6))
                  #:enemy-buildings (list (mk-u 9981 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define ts-scans
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (caddr a) 'scanner-sweep)
                             (action-targets-any-ring-pad? a RING-10-PADS)))
            acts-ts))
  (check-test "T9e-l86c-terran-midgame-marine-560f-cd-and-100e-scan-ring-sweep"
              (and (= (length tm1-moves) 1)
                   (= (length tm-cd-moves) 0)
                   (= (length tm2-moves) 1)
                   (>= (length ts-scans) 1))
              (format "tm1=~a cd=~a tm2=~a scans=~a"
                      (length tm1-moves) (length tm-cd-moves) (length tm2-moves) (length ts-scans))))

;; =============================================================================
;; 10. Loop 86E Track 4: In-Flight Nexus +1 Pending TownHall & Choke-Hold Adv/Non-Turtle Guard
;; =============================================================================
(let ()
  ;; T10a: In-flight Protoss Nexus walk (<= 268f after expand OR Probe carrying 880) counts as
  ;; +1 pending Nexus in total-bldg-counts for Brain and blocks any 2nd concurrent expand even
  ;; at 1200M + mined-out=true, then releases immediately once Nexus #3 materializes!
  (define rt-dnx (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-2b
    (list (mk-u 9961 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9962 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9963 'pylon 36.0 36.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9964 'pylon 38.0 30.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9965 'gateway 40.0 36.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9966 'gateway 42.0 36.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9967 'cybernetics-core 36.0 30.0 #:hp 550.0 #:shield 550.0)
          (mk-u 9968 'robotics-facility 37.0 28.0 #:hp 450.0 #:shield 450.0)))
  (define p-units-dnx
    (append (mk-workers 'probe 42 9970 32.0 32.0)
            (for/list ([i (in-range 10)])
              (mk-u (+ 9985 i) 'stalker (+ 58.0 (* 0.4 i)) 34.0 #:hp 80.0 #:shield 80.0))))
  ;; Step 1 (f=6000): emits 3rd Nexus `(expand ...)`
  (define acts-dnx1
    (step-layer2-economy!
     rt-dnx
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6000
                  #:minerals 750 #:gas 150 #:supply-used 68 #:supply-cap 94 #:army-supply 20
                  #:ally-buildings p-2b #:ally-units p-units-dnx
                  #:enemy-buildings (list (mk-u 9998 'hatchery 158.0 158.0 #:hp 1500.0)))))
  (define dnx-emit1? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts-dnx1))
  ;; Step 2 (f=6180, 180f/8s later — past 16f oledger TTL, 1200M bank, mined-out=#t):
  ;; MUST see total-nexus-count-for-brain == 3 and emit ZERO duplicate `(expand ...)`!
  (define acts-dnx2
    (step-layer2-economy!
     rt-dnx
     (hash-set
      (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6180
                   #:minerals 1200 #:gas 200 #:supply-used 68 #:supply-cap 94 #:army-supply 20
                   #:ally-buildings p-2b #:ally-units p-units-dnx
                   #:enemy-buildings (list (mk-u 9998 'hatchery 158.0 158.0 #:hp 1500.0)))
      'mined-out #t)))
  (define dnx-emit2? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts-dnx2))
  (define dnx-pend2? (hash-ref (rt-door-state rt-dnx) 'l86e-nexus-walk-pending? #f))
  (define dnx-brain-cnt2 (hash-ref (rt-door-state rt-dnx) 'l86e-total-nexus-count-for-brain 0))
  ;; Step 3 (f=6200): Nexus #3 materializes at build-progress 0.05 -> pending clears, count stays 3!
  (define p-3b
    (cons (hash-set (mk-u 9969 'nexus 32.0 64.0 #:hp 100.0 #:shield 100.0) 'build-progress 0.05)
          p-2b))
  (step-layer2-economy!
   rt-dnx
   (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6200
                #:minerals 400 #:gas 200 #:supply-used 68 #:supply-cap 94 #:army-supply 20
                #:ally-buildings p-3b #:ally-units p-units-dnx
                #:enemy-buildings (list (mk-u 9998 'hatchery 158.0 158.0 #:hp 1500.0))))
  (define dnx-pend3? (hash-ref (rt-door-state rt-dnx) 'l86e-nexus-walk-pending? #t))
  (define dnx-brain-cnt3 (hash-ref (rt-door-state rt-dnx) 'l86e-total-nexus-count-for-brain 0))
  (check-test "T10a-l86e-inflight-nexus-walk-counts-plus1-for-brain-and-blocks-double-expand"
              (and dnx-emit1?
                   (not dnx-emit2?)
                   (eq? dnx-pend2? #t)
                   (= dnx-brain-cnt2 3)
                   (not dnx-pend3?)
                   (= dnx-brain-cnt3 3))
              (format "e1?=~a e2?=~a p2?=~a cnt2=~a p3?=~a cnt3=~a"
                      dnx-emit1? dnx-emit2? dnx-pend2? dnx-brain-cnt2 dnx-pend3? dnx-brain-cnt3))

  ;; T10b: Belt-and-suspenders `l86-eff-choke-hold?` NEVER feeds into `eff-mass-parity-suppress?`
  ;; when `snowball-adv >= 0.35` OR when `camp < 0.25` with zero active blacklisted static choke!
  (define rt-adv (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define adv-ths
    (list (mk-u 9941 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9942 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9943 'nexus 32.0 64.0 #:hp 1000.0 #:shield 1000.0)))
  (define adv-stalkers
    (for/list ([i (in-range 22)])
      (mk-u (+ 9910 i) 'stalker (+ 114.0 (* 0.4 (modulo i 6))) (+ 114.0 (* 0.4 (quotient i 6)))
            #:hp 80.0 #:shield 80.0)))
  (define adv-ebldgs
    (list (mk-u 9905 'planetary-fortress 120.0 120.0 #:hp 1500.0)
          (mk-u 9906 'bunker 117.0 118.0 #:hp 400.0)
          (mk-u 9907 'bunker 122.0 116.0 #:hp 400.0)))
  (define adv-eunits
    (list (mk-u 9908 'siege-tank-sieged 121.0 122.0 #:hp 175.0)
          (mk-u 9909 'siege-tank-sieged 119.0 123.0 #:hp 175.0)))
  (step-live-bot-runtime!
   rt-adv
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8600 #:supply-used 110 #:army-supply 44
                #:enemy-x 120.0 #:enemy-y 120.0 #:enemy-nat-x 120.0 #:enemy-nat-y 120.0
                #:ally-buildings adv-ths #:ally-units (append (mk-workers 'probe 44 9800 32.0 32.0) adv-stalkers)
                #:enemy-buildings adv-ebldgs #:enemy-units adv-eunits))
  (define res-adv2
    (step-live-bot-runtime!
     rt-adv
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8640 #:supply-used 92 #:army-supply 26
                  #:enemy-x 120.0 #:enemy-y 120.0 #:enemy-nat-x 120.0 #:enemy-nat-y 120.0
                  #:ally-buildings adv-ths #:ally-units (append (mk-workers 'probe 44 9800 32.0 32.0) (take adv-stalkers 13))
                  #:enemy-buildings adv-ebldgs #:enemy-units adv-eunits)))
  (define adv2-sb (hash-ref (hash-ref (hash-ref (hash-ref res-adv2 'telemetry (hash)) 'state-log (hash)) 'tactics (hash)) 'snowball-adv 0.0))
  (check-test "T10b-l86e-eff-choke-hold-never-suppresses-at-high-snowball-adv"
              (and (>= adv2-sb 0.35)
                   (not (hash-ref (rt-door-state rt-adv) 'l86-eff-choke-hold? #f)))
              (format "adv=~a rawHold?=~a effHold?=~a"
                      adv2-sb
                      (hash-ref (rt-door-state rt-adv) 'l86-choke-hold-active? #f)
                      (hash-ref (rt-door-state rt-adv) 'l86-eff-choke-hold? #f))))

(printf "\n=== Loop 86 Track 4 Runtime Summary: ~a passed, ~a failed ===\n"
        pass-count fail-count)
(unless (= fail-count 0)
  (exit 1))
