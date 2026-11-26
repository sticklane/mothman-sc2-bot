#lang racket/base

(require racket/list
         racket/math
         racket/port
         racket/set
         "../lib/bot-runtime.rkt"
         "../lib/tactics/staging-groups.rkt"
         "../lib/engine/arbiter.rkt"
         "../lib/sc2-game-constants.rkt"
         "../lib/mirror-mind-predictor.rkt"
         "../sim/racket-sc2-ladder-main.rkt")

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

(define MACRO-ACTION-HEADS
  '(build expand train train-unit research chrono-boost calldown-mule inject-larva morph
    worker-scout overlord-scout periodic-scout))

(define (non-prism-macro-actions acts)
  (filter (lambda (a)
            (and (pair? a)
                 (memq (car a) MACRO-ACTION-HEADS)
                 ;; Tactical forward Warp-Prism warp-in is explicitly preserved
                 (not (and (eq? (car a) 'train-unit)
                           (>= (length a) 3)
                           (memq (third a)
                                 '(warp-in-zealot warp-in-stalker warp-in-adept
                                   warp-in-dark-templar warp-in-sentry warp-in-high-templar))))))
          acts))

(define (dist2d-t x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (make-rich-race-obs race frame)
  (case race
    [(Protoss)
     (hash 'frame frame
           'race 'Protoss
           'enemy-race 'Terran
           'minerals 1000
           'gas 500
           'supply-used 28
           'supply-cap 46
           'mineral-harvesters 12
           'gas-harvesters 3
           'base-x 28.0 'base-y 28.0
           'natural-x 46.0 'natural-y 28.0
           'third-x 64.0 'third-y 28.0
           'enemy-x 160.0 'enemy-y 160.0
           'map-width 200.0 'map-height 200.0
           'ally-buildings
           (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'shields 1000
                       'energy 100.0 'build-progress 1.0 'busy? #f)
                 (hash 'id 11 'type 'pylon 'x 33.0 'y 28.0 'hp 200 'shields 200 'build-progress 1.0)
                 (hash 'id 12 'type 'gateway 'x 36.0 'y 28.0 'hp 500 'shields 500 'build-progress 1.0 'busy? #f))
           'ally-units
           (append
            (for/list ([i (in-range 12)])
              (hash 'id (+ 200 i) 'type 'probe 'x (+ 24.0 (* 0.5 i)) 'y 28.0
                    'hp 20 'max-hp 20 'shields 20 'max-shields 20))
            (list (hash 'id 101 'type 'stalker 'x 80.0 'y 80.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80 'weapon-cd 0.0)
                  (hash 'id 102 'type 'stalker 'x 81.0 'y 81.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80 'weapon-cd 0.0)
                  (hash 'id 103 'type 'stalker 'x 80.0 'y 82.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80 'weapon-cd 0.0)
                  (hash 'id 104 'type 'zealot  'x 82.0 'y 80.0 'hp 100 'max-hp 100 'shields 50 'max-shields 50 'weapon-cd 0.0)))
           'enemy-units
           (list (hash 'id 501 'type 'marine 'x 89.0 'y 80.0 'hp 45 'max-hp 45)
                 (hash 'id 502 'type 'marine 'x 89.0 'y 81.0 'hp 45 'max-hp 45)
                 (hash 'id 503 'type 'marine 'x 89.0 'y 82.0 'hp 45 'max-hp 45)
                 (hash 'id 504 'type 'marauder 'x 90.0 'y 81.0 'hp 125 'max-hp 125))
           'enemy-buildings '()
           'mineral-patches (list (hash 'id 9001 'x 22.0 'y 28.0 'minerals 900)))]
    [(Terran)
     (hash 'frame frame
           'race 'Terran
           'enemy-race 'Zerg
           'minerals 1000
           'gas 500
           'supply-used 28
           'supply-cap 46
           'mineral-harvesters 12
           'gas-harvesters 3
           'base-x 28.0 'base-y 28.0
           'natural-x 46.0 'natural-y 28.0
           'third-x 64.0 'third-y 28.0
           'enemy-x 160.0 'enemy-y 160.0
           'map-width 200.0 'map-height 200.0
           'ally-buildings
           (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500
                       'energy 100.0 'build-progress 1.0 'busy? #f)
                 (hash 'id 21 'type 'barracks 'x 36.0 'y 28.0 'hp 1000 'max-hp 1000 'build-progress 1.0 'busy? #f))
           'ally-units
           (append
            (for/list ([i (in-range 12)])
              (hash 'id (+ 220 i) 'type 'scv 'x (+ 24.0 (* 0.5 i)) 'y 28.0 'hp 45 'max-hp 45))
            (list (hash 'id 111 'type 'marine 'x 80.0 'y 80.0 'hp 45 'max-hp 45 'weapon-cd 0.0)
                  (hash 'id 112 'type 'marine 'x 81.0 'y 81.0 'hp 45 'max-hp 45 'weapon-cd 0.0)
                  (hash 'id 113 'type 'marine 'x 80.0 'y 82.0 'hp 45 'max-hp 45 'weapon-cd 0.0)
                  (hash 'id 114 'type 'marauder 'x 82.0 'y 80.0 'hp 125 'max-hp 125 'weapon-cd 0.0)))
           'enemy-units
           (list (hash 'id 511 'type 'roach 'x 88.0 'y 80.0 'hp 145 'max-hp 145)
                 (hash 'id 512 'type 'roach 'x 88.0 'y 81.0 'hp 145 'max-hp 145)
                 (hash 'id 513 'type 'zergling 'x 87.0 'y 82.0 'hp 35 'max-hp 35))
           'enemy-buildings '()
           'mineral-patches (list (hash 'id 9002 'x 22.0 'y 28.0 'minerals 900)))]
    [else
     (hash 'frame frame
           'race 'Zerg
           'enemy-race 'Protoss
           'minerals 1000
           'gas 500
           'supply-used 28
           'supply-cap 46
           'mineral-harvesters 12
           'gas-harvesters 3
           'larva-count 6
           'base-x 28.0 'base-y 28.0
           'natural-x 46.0 'natural-y 28.0
           'third-x 64.0 'third-y 28.0
           'enemy-x 160.0 'enemy-y 160.0
           'map-width 200.0 'map-height 200.0
           'ally-buildings
           (list (hash 'id 30 'type 'hatchery 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'build-progress 1.0)
                 (hash 'id 31 'type 'spawning-pool 'x 34.0 'y 28.0 'hp 1000 'max-hp 1000 'build-progress 1.0))
           'ally-units
           (append
            (for/list ([i (in-range 12)])
              (hash 'id (+ 240 i) 'type 'drone 'x (+ 24.0 (* 0.5 i)) 'y 28.0 'hp 40 'max-hp 40))
            (list (hash 'id 121 'type 'roach 'x 80.0 'y 80.0 'hp 145 'max-hp 145 'weapon-cd 0.0)
                  (hash 'id 122 'type 'roach 'x 81.0 'y 81.0 'hp 145 'max-hp 145 'weapon-cd 0.0)
                  (hash 'id 123 'type 'roach 'x 80.0 'y 82.0 'hp 145 'max-hp 145 'weapon-cd 0.0)
                  (hash 'id 124 'type 'hydralisk 'x 79.0 'y 81.0 'hp 90 'max-hp 90 'weapon-cd 0.0)
                  (hash 'id 125 'type 'overlord 'x 78.0 'y 78.0 'hp 200 'max-hp 200)
                  (hash 'id 126 'type 'larva 'x 28.0 'y 29.0 'hp 25 'max-hp 25)))
           'enemy-units
           (list (hash 'id 521 'type 'stalker 'x 88.0 'y 80.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80)
                 (hash 'id 522 'type 'stalker 'x 88.0 'y 81.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80)
                 (hash 'id 523 'type 'zealot 'x 87.0 'y 82.0 'hp 100 'max-hp 100 'shields 50 'max-shields 50))
           'enemy-buildings '()
           'mineral-patches (list (hash 'id 9003 'x 22.0 'y 28.0 'minerals 900)))]))

(printf "=== Loop 83: Full-Bot Micro Fidelity (--no-macro) & Batch Reset Tests ===\n")

;; ---------------------------------------------------------------------------
;; Test 1: P/T/Z with #:skip-build-order? #t emit ZERO macro commands while
;; keeping full L34 combat micro and L5 Human Cortex active.
;; ---------------------------------------------------------------------------
(for ([race (in-list '(Protoss Terran Zerg))])
  (define rt (make-live-bot-runtime #:race race #:skip-build-order? #t))
  (define obs1 (make-rich-race-obs race 100))
  (define obs2 (make-rich-race-obs race 104))
  (define l2-acts (step-layer2-economy! rt obs1))
  (define res1 (step-live-bot-runtime! rt obs1))
  (define res2 (step-live-bot-runtime! rt obs2))
  (define all-acts (append l2-acts
                           (hash-ref res1 'actions '())
                           (hash-ref res1 'mirror-actions '())
                           (hash-ref res2 'actions '())
                           (hash-ref res2 'mirror-actions '())))
  (define macro-leaks (non-prism-macro-actions all-acts))
  (define has-combat?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(attack-unit attack-pos kite cast-spell))))
           (append (hash-ref res1 'actions '()) (hash-ref res2 'actions '()))))
  (define has-cortex?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'human-apm-discipline)))
           (hash-ref res1 'actions '())))
  (check-test (format "l83-p1-nomacro-zero-macro-and-full-micro-~a" race)
              (and (rt-skip-build-order? rt)
                   (null? macro-leaks)
                   has-combat?
                   has-cortex?)
              (format "macro-leaks=~s has-combat=~a has-cortex=~a" macro-leaks has-combat? has-cortex?)))

;; ---------------------------------------------------------------------------
;; Test 2: --no-macro preserves worker defense (SCV combat repair, stasis evac,
;; worker-rush pull, dying-building cancel) AND combat-casts (Protoss Nexus
;; Energy Recharge 4126 w/o Chrono 3755, Terran Depot wall raise/lower 558/556).
;; ---------------------------------------------------------------------------
(let ()
  ;; 2a. Terran SCV combat repair + Supply Depot raise (enemy near) & lower (ally transiting, safe)
  (define rt-t (make-live-bot-runtime #:race 'Terran #:skip-build-order? #t))
  (define obs-depot-raise
    (hash 'frame 200
          'race 'Terran
          'enemy-race 'Zerg
          'minerals 1000 'gas 500
          'supply-used 24 'supply-cap 32
          'mineral-harvesters 8 'gas-harvesters 0
          'base-x 28.0 'base-y 28.0
          'natural-x 46.0 'natural-y 28.0
          'enemy-x 160.0 'enemy-y 160.0
          'ally-buildings
          (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'energy 100.0 'build-progress 1.0)
                (hash 'id 21 'type 'supply-depot-lowered 'x 40.0 'y 28.0 'hp 400 'max-hp 400 'build-progress 1.0)
                (hash 'id 22 'type 'bunker 'x 38.0 'y 28.0 'hp 180 'max-hp 400 'build-progress 1.0))
          'ally-units
          (list (hash 'id 301 'type 'scv 'x 36.0 'y 28.0 'hp 45 'max-hp 45)
                (hash 'id 302 'type 'scv 'x 36.5 'y 29.0 'hp 45 'max-hp 45)
                (hash 'id 303 'type 'marine 'x 35.0 'y 28.0 'hp 45 'max-hp 45))
          'enemy-units
          (list (hash 'id 601 'type 'zergling 'x 48.0 'y 28.0 'hp 35 'max-hp 35)
                (hash 'id 602 'type 'zergling 'x 48.5 'y 28.5 'hp 35 'max-hp 35))
          'mineral-patches (list (hash 'id 9010 'x 22.0 'y 28.0 'minerals 900))))
  (define res-t-raise (step-live-bot-runtime! rt-t obs-depot-raise))
  (define acts-t-raise (hash-ref res-t-raise 'actions '()))
  (define has-depot-raise?
    (ormap (lambda (a) (equal? a '(cast-spell 21 morph-supply-depot-raise))) acts-t-raise))
  (define has-scv-repair?
    (ormap (lambda (a)
             (and (pair? a)
                  (or (eq? (car a) 'repair)
                      (and (eq? (car a) 'cast-spell)
                           (>= (length a) 3)
                           (eq? (third a) 'repair)))))
           acts-t-raise))
  (define obs-depot-lower
    (hash-set* obs-depot-raise
               'frame 220
               'ally-buildings
               (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'energy 100.0 'build-progress 1.0)
                     (hash 'id 21 'type 'supply-depot 'x 40.0 'y 28.0 'hp 400 'max-hp 400 'build-progress 1.0))
               'ally-units
               (list (hash 'id 303 'type 'marine 'x 38.5 'y 28.0 'hp 45 'max-hp 45))
               'enemy-units '()))
  (define res-t-lower (step-live-bot-runtime! rt-t obs-depot-lower))
  (define acts-t-lower (hash-ref res-t-lower 'actions '()))
  (define has-depot-lower?
    (ormap (lambda (a) (equal? a '(cast-spell 21 morph-supply-depot-lower))) acts-t-lower))
  (check-test "l83-p1-nomacro-terran-depot-wall-and-scv-repair-preserved"
              (and has-depot-raise?
                   has-depot-lower?
                   has-scv-repair?
                   (null? (non-prism-macro-actions acts-t-raise))
                   (null? (non-prism-macro-actions acts-t-lower)))
              (format "raise=~a lower=~a repair=~a leaks=~s"
                      has-depot-raise? has-depot-lower? has-scv-repair?
                      (non-prism-macro-actions (append acts-t-raise acts-t-lower))))

  ;; 2b. Protoss Nexus Energy Recharge (4126) preserved, ZERO Chrono Boost (3755), plus Stasis evac
  (define rt-p (make-live-bot-runtime #:race 'Protoss #:skip-build-order? #t))
  (reset-sc2-nexus-recharge-cooldown!)
  (define obs-p-recharge
    (hash 'frame 300
          'race 'Protoss
          'enemy-race 'Terran
          'minerals 1000 'gas 500
          'supply-used 20 'supply-cap 40
          'base-x 28.0 'base-y 28.0
          'natural-x 46.0 'natural-y 28.0
          'enemy-x 160.0 'enemy-y 160.0
          'ally-buildings
          (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'shields 1000
                      'energy 100.0 'build-progress 1.0 'busy? #t)
                (hash 'id 12 'type 'robotics-facility 'x 34.0 'y 28.0 'hp 500 'shields 500
                      'build-progress 1.0 'busy? #t))
          'ally-units
          (list (hash 'id 401 'type 'high-templar 'x 32.0 'y 28.0 'hp 40 'max-hp 40
                      'shields 40 'max-shields 40 'energy 25.0)
                (hash 'id 402 'type 'probe 'x 25.0 'y 28.0 'hp 20 'max-hp 20 'shields 20 'max-shields 20)
                (hash 'id 403 'type 'probe 'x 25.5 'y 28.5 'hp 20 'max-hp 20 'shields 20 'max-shields 20))
          'enemy-units
          (list (hash 'id 651 'type 'marine 'x 60.0 'y 28.0 'hp 45 'max-hp 45)
                (hash 'id 652 'type 'oracle-stasis-trap 'x 26.0 'y 28.0 'hp 30 'max-hp 30))
          'mineral-patches (list (hash 'id 9011 'x 22.0 'y 28.0 'minerals 900))))
  (define acts-p-rech (step-layer2-economy! rt-p obs-p-recharge))
  (define has-recharge?
    (ormap (lambda (a) (equal? a '(cast-spell 10 nexus-energy-recharge 401))) acts-p-rech))
  (define has-stasis-evac?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(evacuate-workers-from-stasis-ward mineral-walk))))
           acts-p-rech))
  (check-test "l83-p1-nomacro-protoss-recharge-and-stasis-evac-no-chrono"
              (and has-recharge?
                   has-stasis-evac?
                   (null? (non-prism-macro-actions acts-p-rech)))
              (format "recharge=~a stasis=~a acts=~s" has-recharge? has-stasis-evac? acts-p-rech))

  ;; 2c. Worker-rush pull & dying-building cancel preserved in --no-macro
  (define rt-z (make-live-bot-runtime #:race 'Zerg #:skip-build-order? #t))
  (define obs-z-wrush
    (hash 'frame 320
          'race 'Zerg
          'enemy-race 'Protoss
          'minerals 900 'gas 200
          'supply-used 14 'supply-cap 22
          'mineral-harvesters 12 'gas-harvesters 0
          'base-x 28.0 'base-y 28.0
          'natural-x 46.0 'natural-y 28.0
          'enemy-x 160.0 'enemy-y 160.0
          'ally-buildings
          (list (hash 'id 30 'type 'hatchery 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'build-progress 1.0)
                (hash 'id 31 'type 'hatchery 'x 46.0 'y 28.0 'hp 80 'max-hp 1500 'hp-pct 0.05 'build-progress 0.45))
          'ally-units
          (for/list ([i (in-range 12)])
            (hash 'id (+ 450 i) 'type 'drone 'x (+ 25.0 (* 0.4 i)) 'y 28.0 'hp 40 'max-hp 40))
          'enemy-units
          (for/list ([i (in-range 8)])
            (hash 'id (+ 700 i) 'type 'probe 'x (+ 29.0 (* 0.3 i)) 'y 28.0 'hp 20 'max-hp 20 'shields 20 'max-shields 20))
          'mineral-patches (list (hash 'id 9012 'x 22.0 'y 28.0 'minerals 900))))
  (define acts-z-wrush (step-layer2-economy! rt-z obs-z-wrush))
  (define has-worker-defense?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(worker-drill-stack-attack pull-workers-attack mineral-walk))))
           acts-z-wrush))
  (define has-dying-cancel?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(cancel cancel-building))
                  (equal? (second a) 31)))
           acts-z-wrush))
  (check-test "l83-p1-nomacro-worker-rush-defense-and-dying-cancel-preserved"
              (and has-worker-defense?
                   has-dying-cancel?
                   (null? (non-prism-macro-actions acts-z-wrush)))
              (format "worker-def=~a cancel=~a leaks=~s"
                      has-worker-defense? has-dying-cancel? (non-prism-macro-actions acts-z-wrush))))

;; ---------------------------------------------------------------------------
;; Test 3: Inter-scenario batch reset triggers (a) frame rewind, (b) pause > 24f,
;; (c) 0 combat-tag overlap (including across empty clearing frame), and wipes
;; wave-loss, bistable, door-state, mirror-mind, arbiter-ledger, nexus-recharge-cd.
;; Normal ladder (skip-build-order? = #f) NEVER triggers arena reset.
;; ---------------------------------------------------------------------------
(let ()
  (define (pollute-runtime-state! rt)
    (hash-set! (rt-wave-loss-state rt) 'pullback-until-frame 9999)
    (hash-set! (rt-wave-loss-state rt) 'peak-wave-supply 80.0)
    (hash-set! (rt-bistable-states rt) 'stale-latch #t)
    (hash-set! (rt-door-state rt) 'l65f-last-contact-frame 111)
    (hash-set! (rt-door-state rt) 'stale-door-key 'leaked)
    (set-mirror-mind-state-predicted-enemy-unit! (live-bot-runtime-mirror-mind rt) 'battlecruiser)
    (arbiter-resolve!
     (rt-arbiter-ledger rt)
     100
     (make-arbiter-budget-snapshot #:minerals 50 #:gas 0 #:supply-left 10)
     (list (make-proposal 'stale-prop 'l2-macro-runtime 'macro 100.0 '(authorize nexus)
                          #:cost (make-proposal-cost #:minerals 400))))
    (record-sc2-nexus-recharge-loop! 100))

  (define (state-clean? rt)
    (and (not (hash-has-key? (rt-wave-loss-state rt) 'pullback-until-frame))
         (not (hash-has-key? (rt-bistable-states rt) 'stale-latch))
         (not (hash-has-key? (rt-door-state rt) 'stale-door-key))
         (not (equal? (hash-ref (rt-door-state rt) 'l65f-last-contact-frame #f) 111))
         (not (eq? (mirror-mind-state-predicted-enemy-unit (live-bot-runtime-mirror-mind rt)) 'battlecruiser))
         (= (hash-ref (arbiter-telemetry-summary (rt-arbiter-ledger rt)) 'total-overrides 0) 0)
         (sc2-nexus-recharge-cooldown-ready? 104)
         (rt-skip-build-order? rt)))

  (define rt (make-live-bot-runtime #:race 'Protoss #:skip-build-order? #t))
  ;; Step 1: initial scenario step (no reset on very first frame)
  (define r0 (step-live-bot-runtime! rt (make-rich-race-obs 'Protoss 100)))
  (pollute-runtime-state! rt)
  ;; Same scenario (+4f, same tags) -> NO reset, polluted state remains
  (define r-same (step-live-bot-runtime! rt (make-rich-race-obs 'Protoss 104)))
  (define stayed-polluted?
    (and (not (hash-ref r0 'arena-reset? #t))
         (not (hash-ref r-same 'arena-reset? #t))
         (hash-has-key? (rt-bistable-states rt) 'stale-latch)))
  (check-test "l83-p2-same-scenario-no-spurious-reset"
              stayed-polluted?
              (format "r0=~a r-same=~a latch=~a"
                      (hash-ref r0 'arena-reset? '?)
                      (hash-ref r-same 'arena-reset? '?)
                      (hash-has-key? (rt-bistable-states rt) 'stale-latch)))

  ;; Trigger (a): frame rewind (< curr-frame prev-frame)
  (define r-a (step-live-bot-runtime! rt (make-rich-race-obs 'Protoss 16)))
  (check-test "l83-p2-batch-reset-trigger-a-frame-rewind"
              (and (hash-ref r-a 'arena-reset? #f) (state-clean? rt))
              (format "reset=~a clean=~a" (hash-ref r-a 'arena-reset? #f) (state-clean? rt)))

  ;; Trigger (b): batch pause > 24 game loops
  (pollute-runtime-state! rt)
  (define r-b (step-live-bot-runtime! rt (make-rich-race-obs 'Protoss 52))) ; 52 - 16 = 36 > 24
  (check-test "l83-p2-batch-reset-trigger-b-pause-gt-24"
              (and (hash-ref r-b 'arena-reset? #f) (state-clean? rt))
              (format "reset=~a clean=~a" (hash-ref r-b 'arena-reset? #f) (state-clean? rt)))

  ;; Trigger (c): 0 combat-tag overlap WITH an intermediate empty clearing frame!
  (pollute-runtime-state! rt)
  (define obs-clear (hash-set (make-rich-race-obs 'Protoss 56) 'ally-units '()))
  (define r-clear (step-live-bot-runtime! rt obs-clear))
  (define obs-new-tags
    (hash-set (make-rich-race-obs 'Protoss 60)
              'ally-units
              (list (hash 'id 901 'type 'stalker 'x 80.0 'y 80.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80)
                    (hash 'id 902 'type 'stalker 'x 81.0 'y 81.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80))))
  (define r-c (step-live-bot-runtime! rt obs-new-tags))
  (check-test "l83-p2-batch-reset-trigger-c-zero-tag-overlap-across-clearing-frame"
              (and (not (hash-ref r-clear 'arena-reset? #t))
                   (hash-ref r-c 'arena-reset? #f)
                   (state-clean? rt))
              (format "clear-reset=~a r-c-reset=~a clean=~a"
                      (hash-ref r-clear 'arena-reset? #f)
                      (hash-ref r-c 'arena-reset? #f)
                      (state-clean? rt)))

  ;; Default ladder runtime (skip-build-order? = #f) NEVER triggers arena reset
  (define rt-lad (make-live-bot-runtime #:race 'Protoss))
  (step-live-bot-runtime! rt-lad (make-rich-race-obs 'Protoss 200))
  (hash-set! (rt-bistable-states rt-lad) 'ladder-keep #t)
  (define r-lad (step-live-bot-runtime! rt-lad (make-rich-race-obs 'Protoss 10)))
  (check-test "l83-p2-ladder-default-never-triggers-arena-reset"
              (and (not (hash-ref r-lad 'arena-reset? #t))
                   (hash-has-key? (rt-bistable-states rt-lad) 'ladder-keep))))

;; ---------------------------------------------------------------------------
;; Test 4: Unified home-base pullback gating (`l34-has-home-economy-base?`)
;; with `live-th-cnt = 1` hidden distant TH in `--no-macro` Arena mode.
;; ---------------------------------------------------------------------------
(let ()
  ;; 4a. `pick-safe-fallback-point`: has-home-base?=#f ignores distant TH at (20,20)
  (define distant-th (list (hash 'id 1 'type 'nexus 'x 20.0 'y 20.0 'hp 1000 'shields 1000 'build-progress 1.0)))
  (define fb-arena
    (pick-safe-fallback-point
     #:domain 'ground
     #:group-x 90.0 #:group-y 90.0
     #:threat-x 102.0 #:threat-y 90.0
     #:severity 'severe
     #:ally-townhalls distant-th
     #:ally-buildings distant-th
     #:ally-units (list (hash 'id 10 'type 'stalker 'x 90.0 'y 90.0))
     #:enemy-units (list (hash 'id 20 'type 'marine 'x 102.0 'y 90.0))
     #:base-x 20.0 #:base-y 20.0
     #:nat-x 35.0 #:nat-y 20.0
     #:has-home-base? #f))
  (define fb-ladder
    (pick-safe-fallback-point
     #:domain 'ground
     #:group-x 90.0 #:group-y 90.0
     #:threat-x 102.0 #:threat-y 90.0
     #:severity 'severe
     #:ally-townhalls distant-th
     #:ally-buildings distant-th
     #:ally-units (list (hash 'id 10 'type 'stalker 'x 90.0 'y 90.0))
     #:enemy-units (list (hash 'id 20 'type 'marine 'x 102.0 'y 90.0))
     #:base-x 20.0 #:base-y 20.0
     #:nat-x 35.0 #:nat-y 20.0
     #:has-home-base? #t))
  (define d-arena-from-group (dist2d-t 90.0 90.0 (car fb-arena) (cdr fb-arena)))
  (define d-ladder-from-th (dist2d-t 20.0 20.0 (car fb-ladder) (cdr fb-ladder)))
  (check-test "l83-p3-fallback-point-nomacro-bounded-local-vs-ladder-th"
              (and (<= d-arena-from-group 10.0)
                   (< d-ladder-from-th 25.0))
              (format "arena=~s (d-grp=~a) ladder=~s (d-th=~a)"
                      fb-arena d-arena-from-group fb-ladder d-ladder-from-th))

  ;; 4b. `step-staging-groups!` bypasses staging when #:skip-build-order? #t
  (define mgr (make-staging-group-manager))
  (define stg-nomacro
    (step-staging-groups! mgr
                          #:frame 500
                          #:live-obs? #t
                          #:ally-units (list (hash 'id 10 'type 'stalker 'x 90.0 'y 90.0))
                          #:combat-units (list (hash 'id 10 'type 'stalker 'x 90.0 'y 90.0))
                          #:ally-buildings distant-th
                          #:enemy-units '()
                          #:base-x 20.0 #:base-y 20.0
                          #:nat-x 35.0 #:nat-y 20.0
                          #:enemy-anchor-x 160.0 #:enemy-anchor-y 160.0
                          #:skip-build-order? #t))
  (check-test "l83-p3-staging-groups-bypassed-in-nomacro"
              (and (staging-step-result? stg-nomacro)
                   (not (staging-step-result-active? stg-nomacro))
                   (null? (staging-step-result-actions stg-nomacro)))
              (format "stg-nomacro=~s" stg-nomacro))

  ;; 4c. Outnumbered 1-TH skirmish: --no-macro does NOT arm wave-loss pullback & fights,
  ;; while default ladder (skip-build-order? = #f) still arms wave-loss pullback!
  (define outnumbered-obs
    (hash 'frame 400
          'race 'Protoss
          'enemy-race 'Terran
          'minerals 500 'gas 200
          'supply-used 12 'supply-cap 30
          'mineral-harvesters 0 'gas-harvesters 0
          'base-x 20.0 'base-y 20.0
          'natural-x 38.0 'natural-y 20.0
          'enemy-x 160.0 'enemy-y 160.0
          'map-width 200.0 'map-height 200.0
          'ally-buildings distant-th
          'ally-units
          (list (hash 'id 101 'type 'stalker 'x 90.0 'y 90.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80 'weapon-cd 0.0)
                (hash 'id 102 'type 'stalker 'x 91.0 'y 91.0 'hp 80 'max-hp 80 'shields 80 'max-shields 80 'weapon-cd 0.0))
          'enemy-units
          (for/list ([i (in-range 12)])
            (hash 'id (+ 800 i) 'type 'marine 'x (+ 98.0 (* 0.3 i)) 'y 90.0 'hp 45 'max-hp 45))))
  (define rt-arena (make-live-bot-runtime #:race 'Protoss #:skip-build-order? #t))
  (hash-set! (rt-bistable-states rt-arena) 'army-attack-wave #t)
  (define res-arena (step-live-bot-runtime! rt-arena outnumbered-obs))
  (define arena-pb-until (hash-ref (rt-wave-loss-state rt-arena) 'pullback-until-frame -1))
  (define arena-attacks?
    (ormap (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack-pos kite))))
           (hash-ref res-arena 'actions '())))

  (define rt-ladder (make-live-bot-runtime #:race 'Protoss #:skip-build-order? #f))
  (hash-set! (rt-bistable-states rt-ladder) 'army-attack-wave #t)
  (step-live-bot-runtime! rt-ladder outnumbered-obs)
  (define ladder-pb-until (hash-ref (rt-wave-loss-state rt-ladder) 'pullback-until-frame -1))
  (check-test "l83-p3-1th-outnumbered-nomacro-fights-while-ladder-arms-pullback"
              (and (< arena-pb-until 400)
                   arena-attacks?
                   (> ladder-pb-until 400))
              (format "arena-pb=~a arena-atk=~a ladder-pb=~a"
                      arena-pb-until arena-attacks? ladder-pb-until))

  ;; 4d. Fog-of-war center sweep (`sh-d01`) fires with 1 hidden distant TH under --no-macro
  (define rt-fog (make-live-bot-runtime #:race 'Terran #:skip-build-order? #t))
  (define fog-obs
    (hash 'frame 120
          'race 'Terran
          'enemy-race 'Zerg
          'minerals 200 'gas 100
          'supply-used 16 'supply-cap 30
          'mineral-harvesters 0 'gas-harvesters 0
          'base-x 20.0 'base-y 20.0
          'natural-x 38.0 'natural-y 20.0
          'enemy-x 175.0 'enemy-y 175.0
          'map-width 200.0 'map-height 200.0
          'ally-buildings
          (list (hash 'id 1 'type 'command-center 'x 20.0 'y 20.0 'hp 1500 'max-hp 1500 'build-progress 1.0))
          'ally-units
          (list (hash 'id 101 'type 'marine 'x 84.0 'y 100.0 'hp 45 'max-hp 45)
                (hash 'id 102 'type 'marine 'x 85.0 'y 100.0 'hp 45 'max-hp 45)
                (hash 'id 103 'type 'marine 'x 86.0 'y 100.0 'hp 45 'max-hp 45)
                (hash 'id 104 'type 'marine 'x 85.0 'y 101.0 'hp 45 'max-hp 45))
          'enemy-units '()
          'enemy-buildings '()))
  (define res-fog (step-live-bot-runtime! rt-fog fog-obs))
  (define fog-center-sweep?
    (ormap (lambda (a)
             (and (pair? a)
                  (eq? (car a) 'attack-pos)
                  (>= (length a) 4)
                  (real? (third a)) (real? (fourth a))
                  (<= (dist2d-t (exact->inexact (third a)) (exact->inexact (fourth a)) 104.0 100.0) 8.0)))
           (hash-ref res-fog 'actions '())))
  (check-test "l83-p3-1th-nomacro-fog-sweeps-map-center"
              fog-center-sweep?
              (format "actions=~s" (hash-ref res-fog 'actions '())))

  ;; 4e. Mineral-line defender in --no-macro (`use_main_base: true`) with 12 SCVs mining and
  ;; 0 visible enemies stays guarding base (does NOT abandon mineral line to march to enemy main!)
  (define rt-mldef (make-live-bot-runtime #:race 'Terran #:skip-build-order? #t))
  (define mldef-obs
    (hash 'frame 120
          'race 'Terran
          'enemy-race 'Protoss
          'minerals 200 'gas 100
          'supply-used 16 'supply-cap 30
          'mineral-harvesters 12 'gas-harvesters 0
          'base-x 28.0 'base-y 28.0
          'natural-x 46.0 'natural-y 28.0
          'enemy-x 175.0 'enemy-y 175.0
          'map-width 200.0 'map-height 200.0
          'ally-buildings
          (list (hash 'id 1 'type 'command-center 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'build-progress 1.0))
          'ally-units
          (append
           (for/list ([i (in-range 12)])
             (hash 'id (+ 500 i) 'type 'scv 'x (+ 24.0 (* 0.4 i)) 'y 28.0 'hp 45 'max-hp 45))
           (list (hash 'id 601 'type 'marine 'x 31.0 'y 28.0 'hp 45 'max-hp 45)
                 (hash 'id 602 'type 'marine 'x 31.5 'y 29.0 'hp 45 'max-hp 45)))
          'enemy-units '()
          'enemy-buildings '()))
  (define res-mldef (step-live-bot-runtime! rt-mldef mldef-obs))
  (define abandoned-to-enemy-main?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(attack-pos move))
                  (>= (length a) 4)
                  (real? (third a)) (real? (fourth a))
                  (<= (dist2d-t (exact->inexact (third a)) (exact->inexact (fourth a)) 175.0 175.0) 30.0)))
           (hash-ref res-mldef 'actions '())))
  (check-test "l83-p3-nomacro-mineral-line-defenders-stay-guarding-base"
              (not abandoned-to-enemy-main?)
              (format "actions=~s" (hash-ref res-mldef 'actions '()))))

;; ---------------------------------------------------------------------------
;; Test 5: Default ladder mode (skip-build-order? = #f) emits normal macro
;; builds/trains and preserves exact 19-field `live-bot-runtime` struct arity.
;; ---------------------------------------------------------------------------
(let ()
  (check-test "l83-p4-live-bot-runtime-struct-arity-unchanged-19"
              (= (procedure-arity live-bot-runtime) 19)
              (format "arity=~a" (procedure-arity live-bot-runtime)))
  (for ([race (in-list '(Protoss Terran Zerg))])
    (define rt-def (make-live-bot-runtime #:race race))
    (define obs-def (make-rich-race-obs race 100))
    (define acts-def (step-layer2-economy! rt-def obs-def))
    (define macro-acts (non-prism-macro-actions acts-def))
    (check-test (format "l83-p4-default-ladder-macro-intact-~a" race)
                (and (not (rt-skip-build-order? rt-def))
                     (pair? macro-acts))
                (format "macro-acts=~s" macro-acts))))

;; ---------------------------------------------------------------------------
;; Test 6: CLI `--no-macro`, `--skip-build-order`, and `MOTHMAN_SKIP_BUILD_ORDER=1`
;; env fallback in `sim/racket-sc2-ladder-main.rkt`.
;; ---------------------------------------------------------------------------
(let ()
  (define orig-env (getenv "MOTHMAN_SKIP_BUILD_ORDER"))
  (define (run-cli-quiet argv-vec env-val)
    (putenv "MOTHMAN_SKIP_BUILD_ORDER" (or env-val ""))
    (define res #f)
    (with-output-to-string
      (lambda ()
        (set! res (run-racket-sc2-cli argv-vec))))
    res)
  (dynamic-wind
    void
    (lambda ()
      (define r-def (run-cli-quiet #("--BotName" "Mothman-P" "--dry-run") ""))
      (define r-nm  (run-cli-quiet #("--BotName" "Mothman-P" "--no-macro" "--dry-run") ""))
      (define r-sbo (run-cli-quiet #("--BotName" "Mothman-T" "--skip-build-order" "--dry-run") ""))
      (define r-env (run-cli-quiet #("--BotName" "Mothman-Z" "--dry-run") "1"))
      (check-test "l83-p5-cli-dry-run-default-false-and-flags-env-true"
                  (and (equal? (hash-ref r-def 'status "") "DRY_RUN_OK")
                       (eq? (hash-ref r-def 'skip_build_order 'missing) #f)
                       (eq? (hash-ref r-nm  'skip_build_order 'missing) #t)
                       (eq? (hash-ref r-sbo 'skip_build_order 'missing) #t)
                       (eq? (hash-ref r-env 'skip_build_order 'missing) #t))
                  (format "def=~a nm=~a sbo=~a env=~a"
                          (hash-ref r-def 'skip_build_order '?)
                          (hash-ref r-nm  'skip_build_order '?)
                          (hash-ref r-sbo 'skip_build_order '?)
                          (hash-ref r-env 'skip_build_order '?))))
    (lambda ()
      (putenv "MOTHMAN_SKIP_BUILD_ORDER" (or orig-env "")))))

(printf "=== Results: ~a/~a passed (~a failed) ===\n"
        pass-count (+ pass-count fail-count) fail-count)
(unless (= fail-count 0)
  (exit 1))
