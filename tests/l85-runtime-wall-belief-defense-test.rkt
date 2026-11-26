#lang racket/base

(require racket/list
         racket/math
         racket/set
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-bayesian.rkt"
         "../lib/opponent-world-model.rkt"
         "../lib/plan/wall-and-block.rkt"
         "../lib/bot-runtime.rkt")

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

(define (step-all-actions res)
  (append (hash-ref res 'actions '())
          (hash-ref res 'mirror-actions '())))

(define (make-workers type count start-id base-x base-y)
  (for/list ([i (in-range count)])
    (hash 'id (+ start-id i)
          'type type
          'x (+ base-x (- (* 0.4 (modulo i 8)) 2.5))
          'y (+ base-y (if (< i 8) -1.5 1.5))
          'hp (case type [(scv) 45] [(drone) 40] [else 20])
          'max-hp (case type [(scv) 45] [(drone) 40] [else 20])
          'shields (if (eq? type 'probe) 20 0)
          'max-shields (if (eq? type 'probe) 20 0)
          'carrying-minerals? #f
          'carrying-gas? #f)))

(define (make-obs #:race race
                  #:enemy-race enemy-race
                  #:frame frame
                  #:minerals [minerals 400]
                  #:gas [gas 150]
                  #:supply-used [supply-used 16]
                  #:supply-cap [supply-cap 23]
                  #:ally-buildings [ally-buildings '()]
                  #:ally-units [ally-units '()]
                  #:enemy-units [enemy-units '()]
                  #:enemy-buildings [enemy-buildings '()]
                  #:mineral-harvesters [mineral-harvesters 12]
                  #:gas-harvesters [gas-harvesters 0]
                  #:base-x [base-x 28.0] #:base-y [base-y 28.0]
                  #:nat-x [nat-x 48.0] #:nat-y [nat-y 32.0]
                  #:enemy-x [enemy-x 160.0] #:enemy-y [enemy-y 160.0]
                  #:enemy-nat-x [enemy-nat-x 138.0] #:enemy-nat-y [enemy-nat-y 142.0])
  (hash 'frame frame
        'race race
        'enemy-race enemy-race
        'opponent-requested-race enemy-race
        'minerals minerals
        'gas gas
        'supply-used supply-used
        'supply-cap supply-cap
        'mineral-harvesters mineral-harvesters
        'gas-harvesters gas-harvesters
        'base-x base-x 'base-y base-y
        'natural-x nat-x 'natural-y nat-y
        'nat-x nat-x 'nat-y nat-y
        'third-x 68.0 'third-y 36.0
        'enemy-x enemy-x 'enemy-y enemy-y
        'enemy-base (list enemy-x enemy-y)
        'enemy-natural-x enemy-nat-x 'enemy-natural-y enemy-nat-y
        'enemy-expand-x enemy-nat-x 'enemy-expand-y enemy-nat-y
        'map-width 200.0 'map-height 200.0
        'ally-buildings ally-buildings
        'ally-units ally-units
        'enemy-units enemy-units
        'enemy-buildings enemy-buildings
        'enable-opponent-world-model #t
        'mineral-patches (list (hash 'id 9001 'x (- base-x 6.0) 'y base-y 'minerals 900))
        'vespene-geysers (list (hash 'id 9101 'x (+ base-x 4.0) 'y (+ base-y 4.0) 'gas 2250))))

(define (seed-natural-choke-wall! rt obs
                                  #:pylon [pylon '(57.0 . 37.0)]
                                  #:slot-1 [slot-1 '(61.5 . 40.5)]
                                  #:slot-2 [slot-2 '(57.5 . 43.3)]
                                  #:slot-3 [slot-3 '(53.5 . 41.5)])
  ;; Seed `cached-protoss-wall` matching `l2-phase6-crisis-supply!` key so synthetic tests
  ;; without a map-grid exercise exact `'natural-choke` wall execution deterministically!
  (define wall-st (rt-wall-state rt))
  (define bx (hash-ref obs 'base-x 28.0))
  (define by (hash-ref obs 'base-y 28.0))
  (define nx (hash-ref obs 'nat-x 48.0))
  (define ny (hash-ref obs 'nat-y 32.0))
  (define er (hash-ref obs 'enemy-race 'Zerg))
  (define ex (hash-ref obs 'enemy-x 160.0))
  (define ey (hash-ref obs 'enemy-y 160.0))
  (define pkey (list bx by nx ny er er #f ex ey (eq-hash-code #f)))
  (define wall-ht
    (hash 'locus 'natural-choke
          'sealed? #t
          'pylon pylon
          'slot-1 slot-1
          'slot-2 slot-2
          'slot-3 slot-3
          'door '(59.5 . 42.0)
          'door-park '(58.5 . 41.0)))
  (hash-set! wall-st 'cached-protoss-wall (cons pkey wall-ht))
  wall-ht)

(printf "=== Loop 85: Track 3 Runtime Wall, Belief Wiring & Tactical Defense Tests ===\n")

;; ===========================================================================
;; Group 1: Gap A — Live PvZ Natural Walling, Pre-Walk Probe & Excess Pylons
;; ===========================================================================

;; 1a. Natural-choke Probe pre-walk at >= 60M (f >= 160) eliminates 35.7s supply block
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs
    (make-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 224
              #:minerals 70 #:gas 0 #:supply-used 13 #:supply-cap 15
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'shields 1000 'build-progress 1.0 'busy? #t))
              #:ally-units (make-workers 'probe 13 200 28.0 28.0)))
  (seed-natural-choke-wall! rt obs)
  (define res (step-live-bot-runtime! rt obs))
  (define acts (step-all-actions res))
  (define moved-to-wall-pylon?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'move) (>= (length a) 4)
                  (real? (third a)) (real? (fourth a))
                  (< (dist2d (third a) (fourth a) 57.0 37.0) 1.5)))
           acts))
  (define prewalk-pid (hash-ref (rt-wall-state rt) 'nat-pylon-prewalk-probe-id #f))
  (check-test "l85-1a-nat-choke-probe-prewalk-at-60m-f224"
              (and moved-to-wall-pylon?
                   (exact-integer? prewalk-pid)
                   (> prewalk-pid 0))
              (format "moved?=~a pid=~a acts=~s" moved-to-wall-pylon? prewalk-pid acts)))

;; 1b. `bypass-wall-pylon?` holds 240f (not 24f!) while Probe walks to natural choke + no dup main Pylon
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs1
    (make-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 336
              #:minerals 110 #:gas 0 #:supply-used 14 #:supply-cap 15
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'shields 1000 'build-progress 1.0 'busy? #f))
              #:ally-units (make-workers 'probe 14 200 28.0 28.0)))
  (seed-natural-choke-wall! rt obs1)
  (define res1 (step-live-bot-runtime! rt obs1))
  (define acts1 (step-all-actions res1))
  (define pylon1-at-wall?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon)
                  (< (dist2d (third a) (fourth a) 57.0 37.0) 2.5)))
           acts1))
  ;; 114f later (f=450, well past old 24f timeout, < 240f!), Probe is walking with a build order and supply is 15/15:
  (define walking-probes
    (cons (hash 'id 200 'type 'probe 'x 44.0 'y 33.0 'hp 20 'max-hp 20 'shields 20 'max-shields 20
                'has-build-order? #t 'order-kind 'build)
          (make-workers 'probe 14 201 28.0 28.0)))
  (define obs2
    (hash-set* obs1 'frame 450 'minerals 130 'supply-used 15 'supply-cap 15 'ally-units walking-probes))
  (define res2 (step-live-bot-runtime! rt obs2))
  (define acts2 (step-all-actions res2))
  (define dup-pylon2?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts2))
  (define kept-wall-aabbs? (pair? (hash-ref res2 'wall-reserved-aabbs '())))
  (check-test "l85-1b-nat-choke-240f-walk-timeout-no-abandon-and-no-dup-main-pylon"
              (and pylon1-at-wall? (not dup-pylon2?) kept-wall-aabbs?)
              (format "pyl1-wall?=~a dup2?=~a aabbs?=~a acts1=~s"
                      pylon1-at-wall? dup-pylon2? kept-wall-aabbs?
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts1))))

;; 1c + 1d. `l2-wall-slot-powered?` 6.45t alignment + CyberCore wall-slot-2 past f=2200 & high escrow age
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  ;; Pylon at (57.0, 37.0); CyberCore slot-2 at (57.5, 43.3) -> dist = 6.32t (> old 6.2t, <= 6.45t!)
  (define obs
    (make-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 2600 ;; 116s > old 2200f cap!
              #:minerals 220 #:gas 0 #:supply-used 18 #:supply-cap 23
              #:ally-buildings
              (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'max-hp 1000 'shields 1000 'build-progress 1.0 'busy? #t)
                    (hash 'id 11 'type 'nexus 'x 48.0 'y 32.0 'hp 1000 'max-hp 1000 'shields 1000 'build-progress 0.5 'busy? #f)
                    (hash 'id 12 'type 'pylon 'x 57.0 'y 37.0 'hp 200 'max-hp 200 'shields 200 'build-progress 1.0)
                    (hash 'id 13 'type 'gateway 'x 61.5 'y 40.5 'hp 500 'max-hp 500 'shields 500 'build-progress 1.0 'busy? #t 'order-count 1 'powered? #t)
                    (hash 'id 15 'type 'assimilator 'x 32.0 'y 32.0 'hp 300 'max-hp 300 'shields 300 'build-progress 1.0))
              #:ally-units (make-workers 'probe 18 200 28.0 28.0)))
  (seed-natural-choke-wall! rt obs #:pylon '(57.0 . 37.0) #:slot-2 '(57.5 . 43.3))
  (define res (step-live-bot-runtime! rt obs))
  (define acts (step-all-actions res))
  (define cyber-at-slot2?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'cybernetics-core)
                  (< (dist2d (third a) (fourth a) 57.5 43.3) 1.5)))
           acts))
  (check-test "l85-1cd-cybercore-claims-wall-slot2-at-6.32t-and-frame-2600"
              cyber-at-slot2?
              (format "acts=~s" (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts))))

;; 1e. Gateway #2 claims `wall-slot-3` cleanly even under true 12-pool early rush (before breach!)
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs
    (make-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 1800
              #:minerals 260 #:gas 50 #:supply-used 22 #:supply-cap 31
              #:ally-buildings
              (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'max-hp 1000 'shields 1000 'build-progress 1.0 'busy? #t)
                    (hash 'id 12 'type 'pylon 'x 57.0 'y 37.0 'hp 200 'max-hp 200 'shields 200 'build-progress 1.0)
                    (hash 'id 13 'type 'gateway 'x 61.5 'y 40.5 'hp 500 'max-hp 500 'shields 500 'build-progress 1.0 'busy? #t 'order-count 1 'powered? #t)
                    (hash 'id 14 'type 'cybernetics-core 'x 57.5 'y 43.3 'hp 550 'max-hp 550 'shields 550 'build-progress 0.8 'powered? #t)
                    (hash 'id 15 'type 'assimilator 'x 32.0 'y 32.0 'hp 300 'max-hp 300 'shields 300 'build-progress 1.0))
              #:ally-units (append (make-workers 'probe 19 200 28.0 28.0)
                                   (list (hash 'id 301 'type 'zealot 'x 58.0 'y 41.0 'hp 100 'max-hp 100 'shields 50)
                                         (hash 'id 302 'type 'zealot 'x 59.0 'y 41.0 'hp 100 'max-hp 100 'shields 50)))
              #:enemy-buildings (list (hash 'id 801 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 802 'type 'spawning-pool 'x 156.0 'y 156.0 'build-progress 1.0))))
  (seed-natural-choke-wall! rt obs #:pylon '(57.0 . 37.0) #:slot-3 '(53.5 . 41.5))
  (define res (step-live-bot-runtime! rt obs))
  (define acts (step-all-actions res))
  (define gw2-at-slot3?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway)
                  (< (dist2d (third a) (fourth a) 53.5 41.5) 1.5)))
           acts))
  (check-test "l85-1e-gateway2-claims-wall-slot3-on-3slot-nat-choke"
              gw2-at-slot3?
              (format "build-acts=~s"
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts))))

;; 1f. Early-pool OWM latch persists through fog & suppresses wasted enemy-natural block Pylon
(let ()
  ;; Direct wall-and-block checks:
  (define base-blk-obs
    (hash 'frame 1500 'minerals 200 'our-race 'Protoss 'race 'Protoss 'enemy-race 'Zerg
          'base-x 28.0 'base-y 28.0 'enemy-x 160.0 'enemy-y 160.0
          'enemy-natural-x 138.0 'enemy-natural-y 142.0
          'ally-units (list (hash 'id 205 'type 'probe 'x 140.0 'y 144.0 'hp 20 'shields 20))
          'ally-buildings '()
          'enemy-buildings (list (hash 'id 801 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0))))
  (define cmds-clear (plan-pro-offensive-expansion-block base-blk-obs))
  (define cmds-early-pool
    (plan-pro-offensive-expansion-block (hash-set base-blk-obs 'enemy-early-pool? #t)))
  (define cmds-rush
    (plan-pro-offensive-expansion-block (hash-set base-blk-obs 'rush-prob 0.65)))
  (define cmds-2hatch
    (plan-pro-offensive-expansion-block
     (hash-set base-blk-obs 'enemy-buildings
               (list (hash 'id 801 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                     (hash 'id 802 'type 'hatchery 'x 130.0 'y 140.0 'build-progress 0.4)))))
  ;; Verify existing unfinished block Pylon STILL auto-cancels at progress >= 0.85 even under rush!
  (define cmds-cancel-still-works
    (plan-pro-offensive-expansion-block
     (hash-set* base-blk-obs
                'enemy-early-pool? #t
                'ally-buildings (list (hash 'id 99 'type 'pylon 'x 138.0 'y 142.0 'hp 200 'max-hp 200 'shields 200 'max-shields 200 'build-progress 0.88)))))
  (define cmds-gasblk-early-pool
    (plan-expansion-and-gas-blocks (hash-set base-blk-obs 'enemy-early-pool? #t)))
  (check-test "l85-1f-enemy-nat-block-suppressed-on-early-pool-rush-or-existing-hatch"
              (and (pair? cmds-clear)
                   (null? cmds-early-pool)
                   (null? cmds-rush)
                   (null? cmds-2hatch)
                   (equal? cmds-cancel-still-works '((cancel-building 99)))
                   (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon)))
                               cmds-gasblk-early-pool)))
              (format "clear=~s ep=~s rush=~s 2h=~s cancel=~s"
                      cmds-clear cmds-early-pool cmds-rush cmds-2hatch cmds-cancel-still-works)))

;; 1g. Excess Pylon guard: NO extra Pylon when effective headroom (incl. in-flight Pylons) >= 14
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs
    (make-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 5000
              #:minerals 500 #:gas 200 #:supply-used 40 #:supply-cap 55
              #:ally-buildings
              (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                    (hash 'id 11 'type 'nexus 'x 48.0 'y 32.0 'build-progress 1.0 'busy? #t)
                    (hash 'id 12 'type 'pylon 'x 33.0 'y 28.0 'build-progress 1.0)
                    (hash 'id 13 'type 'pylon 'x 36.0 'y 31.0 'build-progress 1.0)
                    (hash 'id 14 'type 'pylon 'x 44.0 'y 32.0 'build-progress 1.0)
                    (hash 'id 15 'type 'pylon 'x 50.0 'y 36.0 'build-progress 1.0)
                    (hash 'id 16 'type 'pylon 'x 26.0 'y 34.0 'build-progress 0.5) ;; in-flight -> +8 = 23 headroom!
                    (hash 'id 17 'type 'gateway 'x 35.0 'y 25.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                    (hash 'id 18 'type 'gateway 'x 38.0 'y 25.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                    (hash 'id 19 'type 'cybernetics-core 'x 32.0 'y 24.0 'build-progress 1.0 'powered? #t))
              #:ally-units (make-workers 'probe 32 200 28.0 28.0)))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define built-pylon?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts))
  (check-test "l85-1g-protoss-no-excess-pylon-when-headroom-comfortable"
              (not built-pylon?)
              (format "build-acts=~s" (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts))))

;; ===========================================================================
;; Group 2: Gap B — Belief Signals Wired Into `mirror-signals-ht` & OWM
;; ===========================================================================

;; 2a. Missing Terran main Barracks @ 1:50 raises `rush-posterior >= 0.55` & persists through fog!
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  ;; Step 1 (f=2464 = 1:50): Probe inside Terran main sees CC + Depot + Refinery, 0 Barracks, 0 Natural!
  (define obs-scout
    (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 2464
              #:minerals 200 #:gas 100 #:supply-used 22 #:supply-cap 31
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'pylon 'x 33.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 12 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'busy? #f)
                                     (hash 'id 13 'type 'cybernetics-core 'x 36.0 'y 32.0 'build-progress 1.0))
              #:ally-units (append (make-workers 'probe 18 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'probe 'x 156.0 'y 156.0 'hp 20 'shields 20)))
              #:enemy-buildings (list (hash 'id 801 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 802 'type 'supply-depot 'x 153.0 'y 154.0 'build-progress 1.0)
                                      (hash 'id 803 'type 'refinery 'x 164.0 'y 164.0 'build-progress 1.0))))
  (define res1 (step-live-bot-runtime! rt obs-scout))
  (define rp1 (hash-ref (hash-ref res1 'telemetry (hash)) 'rush-posterior 0.0))
  ;; Step 2 (f=2600): Probe leaves (fogged `enemy-buildings = '()`) -> OWM remembers & keeps rush >= 0.55!
  (define obs-fog
    (hash-set* obs-scout 'frame 2600 'ally-units (make-workers 'probe 18 200 28.0 28.0) 'enemy-buildings '()))
  (define res2 (step-live-bot-runtime! rt obs-fog))
  (define rp2 (hash-ref (hash-ref res2 'telemetry (hash)) 'rush-posterior 0.0))
  (define wall-rp (hash-ref (rt-wall-state rt) 'l85-rush-prob 0.0))
  (define missing-prod? (hash-ref (rt-wall-state rt) 'l85-missing-main-prod? #f))
  (check-test "l85-2a-proxy-2rax-missing-main-prod-raises-rush-prob-and-persists-through-fog"
              (and (>= rp1 0.55) (>= rp2 0.55) (>= wall-rp 0.55) missing-prod?)
              (format "rp1=~a rp2=~a wall-rp=~a missing-prod?=~a" rp1 rp2 wall-rp missing-prod?)))

;; 2b. 1-base double-gas missing main tech (Proxy Stargate / Proxy Robo) raises rush-posterior >= 0.55
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs
    (make-obs #:race 'Terran #:enemy-race 'Protoss #:frame 2912 ;; 2:10
              #:minerals 220 #:gas 100 #:supply-used 22 #:supply-cap 31
              #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 22 'type 'barracks 'x 37.0 'y 28.0 'build-progress 1.0 'busy? #f))
              #:ally-units (append (make-workers 'scv 18 300 28.0 28.0)
                                   (list (hash 'id 350 'type 'scv 'x 156.0 'y 156.0 'hp 45 'max-hp 45)))
              #:enemy-buildings (list (hash 'id 810 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 811 'type 'pylon 'x 155.0 'y 155.0 'build-progress 1.0)
                                      (hash 'id 812 'type 'gateway 'x 154.0 'y 152.0 'build-progress 1.0)
                                      (hash 'id 813 'type 'assimilator 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 814 'type 'assimilator 'x 156.0 'y 164.0 'build-progress 1.0))))
  (define res (step-live-bot-runtime! rt obs))
  (define rp (hash-ref (hash-ref res 'telemetry (hash)) 'rush-posterior 0.0))
  (define dbl-gas? (hash-ref (rt-wall-state rt) 'l85-1base-double-gas? #f))
  (check-test "l85-2b-tvp-1base-double-gas-missing-main-tech-raises-rush-prob"
              (and (>= rp 0.55) dbl-gas?)
              (format "rp=~a 1base-2gas?=~a" rp dbl-gas?)))

;; 2c. TvP opening SCV scout dispatches promptly by f=700 (~31s) so it enters Protoss main < 2:00
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs
    (make-obs #:race 'Terran #:enemy-race 'Protoss #:frame 700
              #:minerals 60 #:gas 0 #:supply-used 16 #:supply-cap 23
              #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 22 'type 'barracks 'x 37.0 'y 28.0 'build-progress 0.2))
              #:ally-units (make-workers 'scv 16 300 28.0 28.0)))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define dispatched-scout?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout))) acts))
  (check-test "l85-2c-tvp-opening-scv-scout-dispatches-before-35s"
              dispatched-scout?
              (format "acts=~s" acts)))

;; ===========================================================================
;; Group 3: Gap C — Natural Bunker, Wall SCV Repair & Early Shield Battery
;; ===========================================================================

;; 3a. TvZ scouted RoachWarren triggers natural Bunker anchored near natural (NOT behind main CC!)
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs
    (make-obs #:race 'Terran #:enemy-race 'Zerg #:frame 3600
              #:minerals 220 #:gas 50 #:supply-used 34 #:supply-cap 46
              #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 21 'type 'command-center 'x 48.0 'y 32.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 22 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 23 'type 'barracks 'x 37.0 'y 28.0 'build-progress 1.0 'busy? #t 'order-count 1)
                                     (hash 'id 24 'type 'factory 'x 32.0 'y 34.0 'build-progress 1.0 'busy? #t 'order-count 1))
              #:ally-units (append (make-workers 'scv 26 300 28.0 28.0)
                                   (list (hash 'id 401 'type 'marine 'x 46.0 'y 34.0 'hp 45 'max-hp 45)
                                         (hash 'id 402 'type 'marine 'x 47.0 'y 34.0 'hp 45 'max-hp 45)))
              #:enemy-buildings (list (hash 'id 820 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 821 'type 'roach-warren 'x 155.0 'y 155.0 'build-progress 1.0))))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define bunk-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) acts))
  (define near-natural?
    (and bunk-act
         (< (dist2d (third bunk-act) (fourth bunk-act) 48.0 32.0)
            (dist2d (third bunk-act) (fourth bunk-act) 28.0 28.0))))
  (check-test "l85-3a-tvz-roach-warren-builds-natural-front-bunker"
              (and bunk-act near-natural?)
              (format "bunk=~s" bunk-act)))

;; 3b. TvP proxy/1-base double-gas alert triggers early Bunker even on 1 CC
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs
    (make-obs #:race 'Terran #:enemy-race 'Protoss #:frame 2912
              #:minerals 200 #:gas 60 #:supply-used 22 #:supply-cap 31
              #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 22 'type 'barracks 'x 37.0 'y 28.0 'build-progress 1.0 'busy? #t 'order-count 1))
              #:ally-units (append (make-workers 'scv 18 300 28.0 28.0)
                                   (list (hash 'id 350 'type 'scv 'x 156.0 'y 156.0 'hp 45 'max-hp 45)
                                         (hash 'id 401 'type 'marine 'x 35.0 'y 30.0 'hp 45 'max-hp 45)
                                         (hash 'id 402 'type 'marine 'x 36.0 'y 30.0 'hp 45 'max-hp 45)))
              #:enemy-buildings (list (hash 'id 810 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 812 'type 'gateway 'x 154.0 'y 152.0 'build-progress 1.0)
                                      (hash 'id 813 'type 'assimilator 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 814 'type 'assimilator 'x 156.0 'y 164.0 'build-progress 1.0))))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define built-bunker?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) acts))
  (check-test "l85-3b-tvp-1base-double-gas-triggers-early-bunker"
              built-bunker?
              (format "build-acts=~s" (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts))))

;; 3c. SCV combat repair actively repairs damaged ramp wall Supply Depot / Barracks
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs
    (make-obs #:race 'Terran #:enemy-race 'Zerg #:frame 3600
              #:minerals 100 #:gas 0 #:supply-used 24 #:supply-cap 31
              #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0 'hp 1500 'max-hp 1500)
                                     (hash 'id 21 'type 'supply-depot 'x 36.0 'y 30.0 'build-progress 1.0 'hp 240 'max-hp 400)
                                     (hash 'id 22 'type 'barracks 'x 38.0 'y 33.0 'build-progress 1.0 'hp 720 'max-hp 1000))
              #:ally-units (append (make-workers 'scv 16 300 32.0 30.0)
                                   (list (hash 'id 401 'type 'marine 'x 35.0 'y 31.0 'hp 45 'max-hp 45 'weapon-cd 0.0)))
              #:enemy-units (list (hash 'id 901 'type 'roach 'x 40.0 'y 31.0 'hp 145 'max-hp 145)
                                  (hash 'id 902 'type 'roach 'x 41.0 'y 32.0 'hp 145 'max-hp 145))))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define repaired-wall?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'repair) (>= (length a) 3)
                  (memv (third a) '(21 22))))
           acts))
  (check-test "l85-3c-scv-combat-repair-saves-damaged-ramp-depot-and-barracks"
              repaired-wall?
              (format "repair-acts=~s" (filter (lambda (a) (and (pair? a) (eq? (car a) 'repair))) acts))))

;; 3d. Protoss builds early ShieldBattery anchored at natural front on 1-base 2-gas / high rush-prob
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs
    (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 3300
              #:minerals 220 #:gas 100 #:supply-used 28 #:supply-cap 39
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'nexus 'x 48.0 'y 32.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 12 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 13 'type 'pylon 'x 50.0 'y 35.0 'build-progress 1.0)
                                     (hash 'id 14 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'busy? #t 'order-count 1)
                                     (hash 'id 15 'type 'cybernetics-core 'x 36.0 'y 32.0 'build-progress 1.0))
              #:ally-units (append (make-workers 'probe 24 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'probe 'x 156.0 'y 156.0 'hp 20 'shields 20)))
              #:enemy-buildings (list (hash 'id 830 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 831 'type 'barracks 'x 155.0 'y 155.0 'build-progress 1.0)
                                      (hash 'id 832 'type 'factory 'x 152.0 'y 155.0 'build-progress 1.0)
                                      (hash 'id 833 'type 'refinery 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 834 'type 'refinery 'x 156.0 'y 164.0 'build-progress 1.0))))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define sb-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'shield-battery))) acts))
  (define near-natural?
    (and sb-act
         (< (dist2d (third sb-act) (fourth sb-act) 48.0 32.0)
            (dist2d (third sb-act) (fourth sb-act) 28.0 28.0))))
  (check-test "l85-3d-protoss-1base-2gas-triggers-natural-front-shield-battery"
              (and sb-act near-natural?)
              (format "sb=~s build-acts=~s" sb-act (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts))))

;; ===========================================================================
;; Group 4: Loop 85B Surgical Fixes (Pylon#1 Cancel, Printf Filter, Rush Tech)
;; ===========================================================================

;; 4a. Opening Pylon #1 sitting <= 2.0t behind natural wall door is NEVER self-canceled,
;;     AND pre-walk Probe starts at f >= 64 (< 60M) and is protected from idle-return harvest!
(let ()
  ;; Direct wall-and-block check: tight natural-choke wall Pylon #1 (1.8t from door, 0 enemies)
  (define ew-direct-cmds
    (plan-protoss-emergency-walloff-and-cancel
     (hash 'frame 472 'minerals 25 'our-race 'Protoss 'race 'Protoss 'enemy-race 'Zerg
           'base-x 28.0 'base-y 28.0
           'wall-door-x 58.4 'wall-door-y 38.0
           'wall-pylon-pos '(57.0 . 37.0)
           'ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0)
                                 (hash 'id 77 'type 'pylon 'x 57.0 'y 37.0 'build-progress 0.04 'hp 200 'max-hp 200 'shields 200 'max-shields 200))
           'ally-units (make-workers 'probe 14 200 28.0 28.0)
           'enemy-units '())))
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  ;; Step 1: f=80 (< 60M!) -> pre-walk Probe starts immediately on real `'locus 'natural-choke`!
  (define obs1
    (make-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 80
              #:minerals 35 #:gas 0 #:supply-used 13 #:supply-cap 15
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'shields 1000 'build-progress 1.0 'busy? #t))
              #:ally-units (make-workers 'probe 13 200 28.0 28.0)))
  (seed-natural-choke-wall! rt obs1 #:pylon '(57.0 . 37.0))
  (define res1 (step-live-bot-runtime! rt obs1))
  (define acts1 (step-all-actions res1))
  (define prewalk-pid (hash-ref (rt-wall-state rt) 'nat-pylon-prewalk-probe-id #f))
  (define started-f80?
    (and (exact-integer? prewalk-pid)
         (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'move) (equal? (second a) prewalk-pid)
                       (< (dist2d (third a) (fourth a) 57.0 37.0) 1.5)))
                acts1)))
  ;; Step 2: f=120 — pre-walk Probe is idle mid-walk (`order-count 0`) -> NOT recalled to harvest!
  (define midwalk-probes
    (map (lambda (u)
           (if (equal? (hash-ref u 'id -1) prewalk-pid)
               (hash-set* u 'x 44.0 'y 33.0 'order-count 0)
               u))
         (make-workers 'probe 13 200 28.0 28.0)))
  (define obs2 (hash-set* obs1 'frame 120 'minerals 55 'ally-units midwalk-probes))
  (define acts2 (step-all-actions (step-live-bot-runtime! rt obs2)))
  (define recalled-to-harvest?
    (ormap (lambda (a)
             (and (pair? a) (memq (car a) '(harvest gather gather-minerals))
                  (equal? (second a) prewalk-pid)))
           acts2))
  ;; Step 3: f=472 — warping-in Pylon #1 sits 1.8t behind door (58.4, 38.0) -> NEVER self-canceled!
  (define obs3
    (hash-set* obs1 'frame 472 'minerals 25 'supply-used 14 'supply-cap 15
               'ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'shields 1000 'build-progress 1.0 'busy? #t)
                                     (hash 'id 77 'type 'pylon 'x 57.0 'y 37.0 'hp 200 'max-hp 200 'shields 200 'max-shields 200 'build-progress 0.04))))
  (let* ([entry (hash-ref (rt-wall-state rt) 'cached-protoss-wall)]
         [tight-wall (hash-set (cdr entry) 'door '(58.4 . 38.0))])
    (hash-set! (rt-wall-state rt) 'cached-protoss-wall (cons (car entry) tight-wall)))
  (define acts3 (step-all-actions (step-live-bot-runtime! rt obs3)))
  (define canceled-pylon1?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cancel-building) (equal? (second a) 77)))
           (append ew-direct-cmds acts3)))
  (check-test "l85b-4a-pylon1-never-self-canceled-and-prewalk-f80-protected-from-idle-recall"
              (and (not canceled-pylon1?) started-f80? (not recalled-to-harvest?))
              (format "canceled?=~a started80?=~a recalled?=~a ew=~s"
                      canceled-pylon1? started-f80? recalled-to-harvest? ew-direct-cmds)))

;; 4b. Normal PvZ macro scouting Probe near enemy Hatchery + Spine Crawler NEVER triggers
;;     `plan-static-defense-actions` Printf 3-pylon ramp block Pylon (`Mode B #4` 122s leak)!
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs
    (make-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 2736
              #:minerals 260 #:gas 50 #:supply-used 22 #:supply-cap 31
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'nexus 'x 48.0 'y 32.0 'build-progress 0.7 'busy? #f)
                                     (hash 'id 12 'type 'pylon 'x 57.0 'y 37.0 'build-progress 1.0)
                                     (hash 'id 13 'type 'gateway 'x 61.5 'y 40.5 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                     (hash 'id 14 'type 'cybernetics-core 'x 57.5 'y 43.3 'build-progress 1.0 'powered? #t))
              #:ally-units (append (make-workers 'probe 19 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'probe 'x 139.0 'y 143.0 'hp 20 'max-hp 20 'shields 20 'max-shields 20)))
              #:enemy-buildings (list (hash 'id 801 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 802 'type 'hatchery 'x 138.0 'y 142.0 'build-progress 1.0)
                                      (hash 'id 803 'type 'spine-crawler 'x 136.0 'y 140.0 'build-progress 1.0))))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define enemy-base-pylon?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon)
                  (< (dist2d (third a) (fourth a) 138.0 142.0) 30.0)))
           acts))
  (check-test "l85b-4b-macro-scout-probe-no-printf-3pylon-block-at-enemy-base"
              (not enemy-base-pylon?)
              (format "build-acts=~s" (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts))))

;; 4c. Under rush >= 0.45 (`< 7392f`), Protoss L2 trains Immortal #1 ahead of Observer / WarpPrism /
;;     TwilightCouncil, while confirmed cloaked/DT threat STILL unlocks Observer immediately!
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define base-obs
    (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 4600
              #:minerals 350 #:gas 150 #:supply-used 34 #:supply-cap 47
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 12 'type 'pylon 'x 38.0 'y 31.0 'build-progress 1.0)
                                     (hash 'id 13 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                     (hash 'id 14 'type 'cybernetics-core 'x 36.0 'y 32.0 'build-progress 1.0 'powered? #t)
                                     (hash 'id 15 'type 'shield-battery 'x 40.0 'y 30.0 'build-progress 1.0 'powered? #t)
                                     (hash 'id 16 'type 'robotics-facility 'x 32.0 'y 33.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                     (hash 'id 17 'type 'assimilator 'x 32.0 'y 32.0 'build-progress 1.0)
                                     (hash 'id 18 'type 'assimilator 'x 24.0 'y 32.0 'build-progress 1.0))
              #:ally-units (append (make-workers 'probe 22 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'probe 'x 156.0 'y 156.0 'hp 20 'shields 20)
                                         (hash 'id 301 'type 'stalker 'x 40.0 'y 32.0 'hp 80 'shields 80)
                                         (hash 'id 302 'type 'stalker 'x 41.0 'y 32.0 'hp 80 'shields 80)
                                         (hash 'id 303 'type 'stalker 'x 42.0 'y 32.0 'hp 80 'shields 80)
                                         (hash 'id 304 'type 'stalker 'x 43.0 'y 32.0 'hp 80 'shields 80)))
              ;; 1-base 2-gas Terran -> high rush posterior >= 0.60, NO cloak/DT/Banshee!
              #:enemy-buildings (list (hash 'id 830 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 831 'type 'barracks 'x 155.0 'y 155.0 'build-progress 1.0)
                                      (hash 'id 832 'type 'factory 'x 152.0 'y 155.0 'build-progress 1.0)
                                      (hash 'id 833 'type 'refinery 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 834 'type 'refinery 'x 156.0 'y 164.0 'build-progress 1.0))))
  (define acts-rush (step-all-actions (step-live-bot-runtime! rt base-obs)))
  (define trained-imm? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'immortal))) acts-rush))
  (define leaked-obs-wp-tc?
    (ormap (lambda (a)
             (and (pair? a)
                  (or (and (eq? (car a) 'train) (memq (second a) '(observer warp-prism)))
                      (and (eq? (car a) 'build) (eq? (second a) 'twilight-council)))))
           acts-rush))
  ;; Same rush, but now a visible cloaked Banshee is attacking -> Observer #1 MUST unlock!
  (define rt-cloak (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define cloak-obs
    (hash-set* base-obs 'minerals 200 'gas 100
               'enemy-units (list (hash 'id 950 'type 'banshee 'x 44.0 'y 34.0 'hp 140 'max-hp 140 'cloaked #t 'flying #t))))
  (define acts-cloak (step-all-actions (step-live-bot-runtime! rt-cloak cloak-obs)))
  (define unlocked-obs-cloak?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'observer))) acts-cloak))
  (check-test "l85b-4c-protoss-rush-immortal-first-blocks-obs-prism-twilight-but-cloak-unlocks-obs"
              (and trained-imm? (not leaked-obs-wp-tc?) unlocked-obs-cloak?)
              (format "imm?=~a leak?=~a cloak-obs?=~a rush-acts=~s cloak-acts=~s"
                      trained-imm? leaked-obs-wp-tc? unlocked-obs-cloak?
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train build)))) acts-rush)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train build)))) acts-cloak))))

;; 4d. Terran TvP proxy (`Mode B #16`): defers Stim/Addons/EBay/Marauder, rushes Starport #1,
;;     and directly trains Viking + Cyclone (both 5.0.14+ FactoryTechLab AND live 4.10 bare Factory)!
(let ()
  ;; Part 1: Factory just finished, 0 Starport, RaxTechLab ready, 260M/120G -> Starport #1 (NO Stim/EBay/FacTL/Marauder!)
  (define rt1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-sp1
    (make-obs #:race 'Terran #:enemy-race 'Protoss #:frame 3600
              #:minerals 260 #:gas 120 #:supply-used 28 #:supply-cap 39
              #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 22 'type 'supply-depot 'x 34.0 'y 30.0 'build-progress 1.0)
                                     (hash 'id 23 'type 'barracks 'x 37.0 'y 28.0 'build-progress 1.0 'busy? #f 'order-count 0)
                                     (hash 'id 24 'type 'barracks-techlab 'x 39.5 'y 27.5 'build-progress 1.0 'busy? #f 'order-count 0)
                                     (hash 'id 25 'type 'bunker 'x 44.0 'y 32.0 'build-progress 1.0)
                                     (hash 'id 26 'type 'factory 'x 32.0 'y 34.0 'build-progress 1.0 'busy? #f 'order-count 0)
                                     (hash 'id 28 'type 'refinery 'x 32.0 'y 32.0 'build-progress 1.0)
                                     (hash 'id 29 'type 'refinery 'x 24.0 'y 32.0 'build-progress 1.0))
              #:ally-units (append (make-workers 'scv 20 300 28.0 28.0)
                                   (list (hash 'id 350 'type 'scv 'x 156.0 'y 156.0 'hp 45 'max-hp 45)
                                         (hash 'id 401 'type 'marine 'x 43.0 'y 32.0 'hp 45 'max-hp 45)
                                         (hash 'id 402 'type 'marine 'x 44.0 'y 32.0 'hp 45 'max-hp 45)
                                         (hash 'id 403 'type 'marine 'x 45.0 'y 32.0 'hp 45 'max-hp 45)
                                         (hash 'id 404 'type 'marine 'x 43.0 'y 33.0 'hp 45 'max-hp 45)
                                         (hash 'id 405 'type 'marine 'x 44.0 'y 33.0 'hp 45 'max-hp 45)
                                         (hash 'id 406 'type 'marine 'x 45.0 'y 33.0 'hp 45 'max-hp 45)))
              #:enemy-buildings (list (hash 'id 810 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 811 'type 'pylon 'x 155.0 'y 155.0 'build-progress 1.0)
                                      (hash 'id 812 'type 'gateway 'x 154.0 'y 152.0 'build-progress 1.0)
                                      (hash 'id 813 'type 'assimilator 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 814 'type 'assimilator 'x 156.0 'y 164.0 'build-progress 1.0))))
  (define acts-sp1 (step-all-actions (step-live-bot-runtime! rt1 obs-sp1)))
  (define built-sp1? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'starport))) acts-sp1))
  (define gas-drain-leak?
    (ormap (lambda (a)
             (and (pair? a)
                  (or (and (eq? (car a) 'research) (memq (second a) '(stimpack combat-shield concussive-shells)))
                      (and (eq? (car a) 'build) (memq (second a) '(factory-techlab barracks-reactor engineering-bay)))
                      (and (eq? (car a) 'train) (eq? (second a) 'marauder)))))
           acts-sp1))
  ;; Part 2: Live 4.10 bare-Factory Cyclone hydration + ready Starport -> trains BOTH Viking AND Cyclone (NO Medivac/FacTL)!
  (define-values (trained-vik-410? trained-cyc-410? leaked-med-ftl-410? acts-410)
    (dynamic-wind
      (lambda ()
        (register-sc2-live-unit-data! 'cyclone 150 100 3.0 720 0 #f 4.72 1.0 7.0 7.0 #f #f))
      (lambda ()
        (define rt2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
        (define obs-410
          (hash-set* obs-sp1 'frame 4500 'minerals 380 'gas 220 'supply-used 30 'supply-cap 47
                     'ally-buildings (append (hash-ref obs-sp1 'ally-buildings)
                                             (list (hash 'id 27 'type 'starport 'x 36.0 'y 34.0 'build-progress 1.0 'busy? #f 'order-count 0)))))
        (define a2 (step-all-actions (step-live-bot-runtime! rt2 obs-410)))
        (values
         (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'viking))) a2)
         (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'cyclone))) a2)
         (ormap (lambda (a)
                  (and (pair? a)
                       (or (and (eq? (car a) 'train) (memq (second a) '(medivac widow-mine siege-tank)))
                           (and (eq? (car a) 'build) (eq? (second a) 'factory-techlab)))))
                a2)
         a2))
      (lambda ()
        (reset-sc2-live-game-data!))))
  (check-test "l85b-4d-tvp-proxy-rushes-starport-blocks-stim-drain-and-trains-viking-plus-cyclone"
              (and built-sp1? (not gas-drain-leak?) trained-vik-410? trained-cyc-410? (not leaked-med-ftl-410?))
              (format "sp1?=~a leak1?=~a vik?=~a cyc?=~a leak2?=~a acts1=~s acts2=~s"
                      built-sp1? gas-drain-leak? trained-vik-410? trained-cyc-410? leaked-med-ftl-410?
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build train research)))) acts-sp1)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(build train research)))) acts-410))))

;; 4e. Natural-pad expansion block (`EngineeringBay` or lone `Pylon` on our natural pad)
;;     NEVER triggers false `rush >= 0.55`, while adding a 2nd Pylon / Photon Cannon escalates immediately!
(let ()
  ;; Case 1: Normal Terran 1-Rax FE with lone natural-block EngineeringBay on our natural `(48, 32)` @ f=2700
  (define rt-ebay (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-ebay
    (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 2700
              #:minerals 200 #:gas 60 #:supply-used 22 #:supply-cap 31
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 12 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t))
              #:ally-units (append (make-workers 'probe 18 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'probe 'x 156.0 'y 156.0 'hp 20 'shields 20)))
              #:enemy-buildings (list (hash 'id 840 'type 'command-center 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 841 'type 'supply-depot 'x 154.0 'y 154.0 'build-progress 1.0)
                                      (hash 'id 842 'type 'barracks 'x 155.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 843 'type 'refinery 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 844 'type 'engineering-bay 'x 48.0 'y 32.0 'build-progress 0.3))))
  (define rp-ebay (hash-ref (hash-ref (step-live-bot-runtime! rt-ebay obs-ebay) 'telemetry (hash)) 'rush-posterior 1.0))
  ;; Case 2: Normal Protoss with lone Pylon blocking our natural pad `(48, 32)` @ f=2400 (0 Forge/Cannon)
  (define rt-pyl (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define obs-pyl
    (make-obs #:race 'Zerg #:enemy-race 'Protoss #:frame 2400
              #:minerals 200 #:gas 40 #:supply-used 22 #:supply-cap 28
              #:ally-buildings (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'build-progress 1.0))
              #:ally-units (append (make-workers 'drone 16 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'overlord 'x 156.0 'y 156.0 'hp 200 'max-hp 200 'flying #t)))
              #:enemy-buildings (list (hash 'id 850 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 851 'type 'gateway 'x 155.0 'y 155.0 'build-progress 1.0)
                                      (hash 'id 852 'type 'assimilator 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 853 'type 'pylon 'x 48.0 'y 32.0 'build-progress 0.4))))
  (define rp-pyl (hash-ref (hash-ref (step-live-bot-runtime! rt-pyl obs-pyl) 'telemetry (hash)) 'rush-posterior 1.0))
  ;; Case 3: Escalation — 2nd enemy Pylon appears near our natural -> rush MUST escalate >= 0.55!
  (define obs-pyl2
    (hash-set* obs-pyl 'frame 2420 'enemy-buildings
               (cons (hash 'id 854 'type 'pylon 'x 46.0 'y 36.0 'build-progress 0.2)
                     (hash-ref obs-pyl 'enemy-buildings))))
  (define rp-pyl2 (hash-ref (hash-ref (step-live-bot-runtime! rt-pyl obs-pyl2) 'telemetry (hash)) 'rush-posterior 0.0))
  (check-test "l85b-4e-lone-nat-pad-ebay-or-pylon-block-no-false-rush-escalates-on-2nd-pylon"
              (and (< rp-ebay 0.55) (< rp-pyl 0.55) (>= rp-pyl2 0.55))
              (format "rp-ebay=~a rp-pyl=~a rp-pyl2=~a" rp-ebay rp-pyl rp-pyl2)))

;; ===========================================================================
;; Group 5: Loop 85C Polish (False-Rush Tightening & Protoss Macro Priorities)
;; ===========================================================================

;; 5a. Standard 16-Pool + 4 anti-scout Lings & normal 2-gas PvP do NOT false-trigger rush;
;;     true 12-Pool latches early and clears cleanly past 3:15 (4368f) when 2-base peaceful!
(let ()
  ;; Case 1: Standard 16-Pool (f=1900, bp=0.60 -> est-start=1282 > 950) + 4 Lings at f=2600
  (define rt-16p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-16p
    (make-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 1900
              #:minerals 200 #:gas 50 #:supply-used 20 #:supply-cap 23
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 12 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t))
              #:ally-units (append (make-workers 'probe 16 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'probe 'x 156.0 'y 156.0 'hp 20 'shields 20)))
              #:enemy-buildings (list (hash 'id 860 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 861 'type 'spawning-pool 'x 155.0 'y 155.0 'build-progress 0.60))))
  (step-live-bot-runtime! rt-16p obs-16p)
  (define obs-16p-4l
    (hash-set* obs-16p 'frame 2600
               'enemy-buildings (list (hash 'id 860 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 862 'type 'hatchery 'x 138.0 'y 142.0 'build-progress 0.8)
                                      (hash 'id 861 'type 'spawning-pool 'x 155.0 'y 155.0 'build-progress 1.0))
               'enemy-units (for/list ([i (in-range 4)])
                              (hash 'id (+ 910 i) 'type 'zergling 'x (+ 120.0 i) 'y 120.0 'hp 35 'max-hp 35))))
  (define res-16p (step-live-bot-runtime! rt-16p obs-16p-4l))
  (define ep-16p? (hash-ref (rt-wall-state rt-16p) 'l85-early-pool? #f))
  (define rp-16p (hash-ref (hash-ref res-16p 'telemetry (hash)) 'rush-posterior 1.0))

  ;; Case 2: Standard 2-gas PvP (2 Gateways + CyberCore @ f=3000 < 3584f) -> NO false 1-base 2-gas rush!
  (define rt-pvp (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-pvp
    (make-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 3000
              #:minerals 200 #:gas 100 #:supply-used 24 #:supply-cap 31
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 12 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t))
              #:ally-units (append (make-workers 'probe 18 200 28.0 28.0)
                                   (list (hash 'id 250 'type 'probe 'x 156.0 'y 156.0 'hp 20 'shields 20)))
              #:enemy-buildings (list (hash 'id 870 'type 'nexus 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 871 'type 'gateway 'x 154.0 'y 154.0 'build-progress 1.0)
                                      (hash 'id 872 'type 'gateway 'x 150.0 'y 154.0 'build-progress 1.0)
                                      (hash 'id 873 'type 'cybernetics-core 'x 154.0 'y 150.0 'build-progress 1.0)
                                      (hash 'id 874 'type 'assimilator 'x 164.0 'y 156.0 'build-progress 1.0)
                                      (hash 'id 875 'type 'assimilator 'x 156.0 'y 164.0 'build-progress 1.0))))
  (define res-pvp (step-live-bot-runtime! rt-pvp obs-pvp))
  (define dbl-pvp? (hash-ref (rt-wall-state rt-pvp) 'l85-1base-double-gas? #f))
  (define rp-pvp (hash-ref (hash-ref res-pvp 'telemetry (hash)) 'rush-posterior 1.0))

  ;; Case 3: True 12-Pool (f=1500, bp=0.80 -> est-start=676 <= 950) latches early, then clears > 4368f on 2-base peaceful!
  (define rt-12p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-12p (hash-set* obs-16p 'frame 1500
                             'enemy-buildings (list (hash 'id 860 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                                    (hash 'id 861 'type 'spawning-pool 'x 155.0 'y 155.0 'build-progress 0.80))))
  (step-live-bot-runtime! rt-12p obs-12p)
  (define ep-12p-early? (hash-ref (rt-wall-state rt-12p) 'l85-early-pool? #f))
  (define obs-12p-clear
    (hash-set* obs-12p 'frame 4500 'enemy-units '()
               'enemy-buildings (list (hash 'id 860 'type 'hatchery 'x 160.0 'y 160.0 'build-progress 1.0)
                                      (hash 'id 862 'type 'hatchery 'x 138.0 'y 142.0 'build-progress 1.0)
                                      (hash 'id 861 'type 'spawning-pool 'x 155.0 'y 155.0 'build-progress 1.0))))
  (step-live-bot-runtime! rt-12p obs-12p-clear)
  (define ep-12p-late? (hash-ref (rt-wall-state rt-12p) 'l85-early-pool? #f))
  (check-test "l85c-5a-standard-16pool-and-pvp-2gas-no-false-rush-and-12pool-clears-past-3m15"
              (and (not ep-16p?) (< rp-16p 0.55)
                   (not dbl-pvp?) (< rp-pvp 0.55)
                   ep-12p-early? (not ep-12p-late?))
              (format "ep16?=~a rp16=~a dbl-pvp?=~a rp-pvp=~a ep12-early?=~a ep12-late?=~a"
                      ep-16p? rp-16p dbl-pvp? rp-pvp ep-12p-early? ep-12p-late?)))

;; 5b. Peaceful PvT never drains 100M into Zealot ahead of CyberneticsCore #1, AND trains
;;     first ranged Stalker #1 immediately upon CyberCore completion ahead of WarpGate research!
(let ()
  ;; Part 1: Gateway ready, 0 CyberCore, 130M, peaceful PvT -> ZERO Zealot trained!
  (define rt1 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs1
    (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 1400
              #:minerals 130 #:gas 0 #:supply-used 18 #:supply-cap 23
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 12 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                     (hash 'id 13 'type 'assimilator 'x 32.0 'y 32.0 'build-progress 1.0))
              #:ally-units (make-workers 'probe 18 200 28.0 28.0)))
  (define acts1 (step-all-actions (step-live-bot-runtime! rt1 obs1)))
  (define drained-zealot? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (eq? (second a) 'zealot))) acts1))

  ;; Part 2: CyberCore just finished, 140M/60G, 0 ranged units -> Stalker #1 trains ahead of WarpGate!
  (define rt2 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs2
    (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 2400
              #:minerals 140 #:gas 60 #:supply-used 22 #:supply-cap 31
              #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                     (hash 'id 11 'type 'nexus 'x 48.0 'y 32.0 'build-progress 0.5 'busy? #f)
                                     (hash 'id 12 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 13 'type 'pylon 'x 38.0 'y 31.0 'build-progress 1.0)
                                     (hash 'id 14 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                     (hash 'id 15 'type 'cybernetics-core 'x 36.0 'y 32.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                     (hash 'id 16 'type 'assimilator 'x 32.0 'y 32.0 'build-progress 1.0))
              #:ally-units (make-workers 'probe 21 200 28.0 28.0)))
  (define acts2 (step-all-actions (step-live-bot-runtime! rt2 obs2)))
  (define trained-ranged1?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'train) (memq (second a) '(stalker adept)))) acts2))
  (define stole-wg?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'research) (memq (second a) '(warp-gate-research warpgate)))) acts2))
  (check-test "l85c-5b-pvt-peaceful-no-zealot-before-cybercore-and-ranged1-before-warpgate"
              (and (not drained-zealot?) trained-ranged1? (not stole-wg?))
              (format "zealot?=~a ranged1?=~a wg?=~a acts1=~s acts2=~s"
                      drained-zealot? trained-ranged1? stole-wg?
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train build research)))) acts1)
                      (filter (lambda (a) (and (pair? a) (memq (car a) '(train build research)))) acts2))))

;; 5c. Anti-air Stargate #1 vs Banshees is NEVER starved by midgame Gateway #5!
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs
    (hash-set
     (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7200
               #:minerals 260 #:gas 160 #:supply-used 62 #:supply-cap 79
               #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                      (hash 'id 11 'type 'nexus 'x 48.0 'y 32.0 'build-progress 1.0 'busy? #t)
                                      (hash 'id 12 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                      (hash 'id 13 'type 'pylon 'x 42.0 'y 32.0 'build-progress 1.0)
                                      (hash 'id 14 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                      (hash 'id 15 'type 'gateway 'x 39.0 'y 28.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                      (hash 'id 16 'type 'gateway 'x 36.0 'y 25.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                      (hash 'id 17 'type 'gateway 'x 39.0 'y 25.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                      (hash 'id 18 'type 'cybernetics-core 'x 36.0 'y 32.0 'build-progress 1.0 'powered? #t)
                                      (hash 'id 19 'type 'robotics-facility 'x 32.0 'y 33.0 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                      (hash 'id 20 'type 'shield-battery 'x 45.0 'y 34.0 'build-progress 1.0 'powered? #t)
                                      (hash 'id 21 'type 'assimilator 'x 32.0 'y 32.0 'build-progress 1.0)
                                      (hash 'id 22 'type 'assimilator 'x 24.0 'y 32.0 'build-progress 1.0)
                                      (hash 'id 23 'type 'assimilator 'x 52.0 'y 36.0 'build-progress 1.0)
                                      (hash 'id 24 'type 'assimilator 'x 44.0 'y 36.0 'build-progress 1.0))
               #:ally-units (append (make-workers 'probe 40 200 28.0 28.0)
                                    (for/list ([i (in-range 8)])
                                      (hash 'id (+ 300 i) 'type 'stalker 'x (+ 42.0 i) 'y 34.0 'hp 80 'shields 80))
                                    (list (hash 'id 350 'type 'observer 'x 44.0 'y 34.0 'hp 40 'shields 20 'flying #t)))
               #:enemy-units (for/list ([i (in-range 3)])
                               (hash 'id (+ 960 i) 'type 'banshee 'x (+ 60.0 i) 'y 40.0 'hp 140 'max-hp 140 'flying #t)))
     'researched-upgrades '(warp-gate-research warpgate)))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define built-sg? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'stargate))) acts))
  (define stole-gw? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts))
  (check-test "l85c-5c-pvt-anti-air-stargate-builds-ahead-of-gateway5-vs-banshees"
              (and built-sg? (not stole-gw?))
              (format "sg?=~a gw?=~a builds=~s" built-sg? stole-gw?
                      (filter (lambda (a) (and (pair? a) (eq? (car a) 'build))) acts))))

;; 5d. Peaceful 2-base Protoss saving for 3rd Nexus (>= 250M, >= 1 Immortal, >= 4 Gates, >= 40 workers)
;;     yields continuous Robo Immortal #2+ and Zealot so 3rd Nexus reaches 400M cleanly!
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs
    (hash-set
     (make-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8200
               #:minerals 340 #:gas 150 #:supply-used 68 #:supply-cap 87
               #:ally-buildings (list (hash 'id 10 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #t)
                                      (hash 'id 11 'type 'nexus 'x 48.0 'y 32.0 'build-progress 1.0 'busy? #t)
                                      (hash 'id 12 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                      (hash 'id 13 'type 'pylon 'x 42.0 'y 32.0 'build-progress 1.0)
                                      (hash 'id 14 'type 'gateway 'x 36.0 'y 28.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                      (hash 'id 15 'type 'gateway 'x 39.0 'y 28.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                      (hash 'id 16 'type 'gateway 'x 36.0 'y 25.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                      (hash 'id 17 'type 'gateway 'x 39.0 'y 25.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                      (hash 'id 18 'type 'cybernetics-core 'x 36.0 'y 32.0 'build-progress 1.0 'powered? #t)
                                      (hash 'id 19 'type 'robotics-facility 'x 32.0 'y 33.0 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                      (hash 'id 20 'type 'twilight-council 'x 34.0 'y 35.0 'build-progress 1.0 'powered? #t)
                                      (hash 'id 21 'type 'assimilator 'x 32.0 'y 32.0 'build-progress 1.0)
                                      (hash 'id 22 'type 'assimilator 'x 24.0 'y 32.0 'build-progress 1.0)
                                      (hash 'id 23 'type 'assimilator 'x 52.0 'y 36.0 'build-progress 1.0)
                                      (hash 'id 24 'type 'assimilator 'x 44.0 'y 36.0 'build-progress 1.0))
               #:ally-units (append (make-workers 'probe 42 200 28.0 28.0)
                                    (for/list ([i (in-range 8)])
                                      (hash 'id (+ 300 i) 'type 'stalker 'x (+ 42.0 i) 'y 34.0 'hp 80 'shields 80))
                                    (list (hash 'id 340 'type 'immortal 'x 44.0 'y 35.0 'hp 200 'shields 100)
                                          (hash 'id 350 'type 'observer 'x 44.0 'y 34.0 'hp 40 'shields 20 'flying #t))))
     'researched-upgrades '(warp-gate-research warpgate)))
  (define res (step-live-bot-runtime! rt obs))
  (define acts (step-all-actions res))
  (define drained-imm-or-z?
    (ormap (lambda (a)
             (and (pair? a)
                  (or (and (eq? (car a) 'train) (memq (second a) '(immortal zealot)))
                      (and (eq? (car a) 'build) (eq? (second a) 'gateway)))))
           acts))
  (check-test "l85c-5d-peaceful-2base-saving-for-3rd-nexus-not-drained-by-immortal2-zealot-or-gw5"
              (not drained-imm-or-z?)
              (format "acts=~s" (filter (lambda (a) (and (pair? a) (memq (car a) '(train build expand)))) acts))))

(printf "=== Results: ~a/~a passed (~a failed) ===\n"
        pass-count (+ pass-count fail-count) fail-count)
(unless (= fail-count 0)
  (exit 1))
