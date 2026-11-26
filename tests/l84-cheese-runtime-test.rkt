#lang racket/base

(require racket/file
         racket/list
         racket/math
         racket/port
         racket/set
         racket/string
         json
         "../lib/build-orders/cheese.rkt"
         "../lib/priority-macro-brain.rkt"
         "../lib/bot-runtime.rkt"
         "../lib/sc2-protobuf-ws.rkt"
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

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (step-all-actions res)
  (append (hash-ref res 'actions '())
          (hash-ref res 'mirror-actions '())))

(define (action-is-worker-train? a)
  (and (pair? a)
       (or (and (eq? (car a) 'train)
                (>= (length a) 2)
                (memq (second a) '(drone scv probe)))
           (and (eq? (car a) 'train-unit)
                (>= (length a) 3)
                (memq (third a) '(drone scv probe))))))

(define (action-is-expand? a)
  (and (pair? a)
       (or (eq? (car a) 'expand)
           (and (eq? (car a) 'build)
                (>= (length a) 2)
                (memq (second a) '(hatchery command-center nexus))))))

(define (action-is-build-proxy? a [expected-sym #f])
  (and (pair? a)
       (eq? (car a) 'build-proxy)
       (>= (length a) 4)
       (or (not expected-sym) (eq? (second a) expected-sym))))

(define (make-workers type count start-id base-x base-y #:gas-count [gas-count 0])
  (for/list ([i (in-range count)])
    (define in-gas? (< i gas-count))
    (hash 'id (+ start-id i)
          'type type
          'x (+ base-x (if in-gas? 4.0 (- (* 0.4 (modulo i 8)) 3.0)))
          'y (+ base-y (if in-gas? 4.0 (if (< i 8) -1.5 1.5)))
          'hp (case type [(scv) 45] [(drone) 40] [else 20])
          'max-hp (case type [(scv) 45] [(drone) 40] [else 20])
          'shields (if (eq? type 'probe) 20 0)
          'max-shields (if (eq? type 'probe) 20 0)
          'carrying-gas? in-gas?
          'order-ability (if in-gas? 'harvest-gas 'harvest-minerals))))

(define (make-base-obs #:race race
                       #:enemy-race enemy-race
                       #:frame frame
                       #:minerals [minerals 600]
                       #:gas [gas 300]
                       #:supply-used [supply-used 22]
                       #:supply-cap [supply-cap 46]
                       #:ally-buildings [ally-buildings '()]
                       #:ally-units [ally-units '()]
                       #:enemy-units [enemy-units '()]
                       #:enemy-buildings [enemy-buildings '()]
                       #:researched-upgrades [researched-upgrades '()]
                       #:larva-count [larva-count 0]
                       #:mineral-harvesters [mineral-harvesters 12]
                       #:gas-harvesters [gas-harvesters 0])
  (hash 'frame frame
        'race race
        'enemy-race enemy-race
        'minerals minerals
        'gas gas
        'supply-used supply-used
        'supply-cap supply-cap
        'mineral-harvesters mineral-harvesters
        'gas-harvesters gas-harvesters
        'larva-count larva-count
        'base-x 28.0 'base-y 28.0
        'natural-x 48.0 'natural-y 32.0
        'third-x 68.0 'third-y 36.0
        'enemy-x 160.0 'enemy-y 160.0
        'enemy-base (list 160.0 160.0)
        'map-width 200.0 'map-height 200.0
        'ally-buildings ally-buildings
        'ally-units ally-units
        'enemy-units enemy-units
        'enemy-buildings enemy-buildings
        'researched-upgrades researched-upgrades
        'mineral-patches (list (hash 'id 9001 'x 22.0 'y 28.0 'minerals 900))
        'vespene-geysers (list (hash 'id 9101 'x 32.0 'y 32.0 'gas 2250))))

(define (run-cli-silent argv)
  (let ([out (open-output-string)])
    (parameterize ([current-output-port out])
      (run-racket-sc2-cli (list->vector argv)))))

(printf "=== Loop 84: Version C Cheese Runtime & CLI Integration Tests ===\n")

;; ===========================================================================
;; Group 1: Zero-Diff & Struct Arity Invariants (`cheese-mode? = #f`)
;; ===========================================================================
(let ([rt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)])
  (check-test "l84-1a-live-bot-runtime-struct-arity-unchanged-19"
              (= (vector-length (struct->vector rt)) 20)
              (format "vec-len=~a" (vector-length (struct->vector rt))))
  (check-test "l84-1b-default-cheese-mode-off-and-empty-state"
              (and (not (rt-cheese-mode? rt))
                   (not (cheese-mode-active? rt))
                   (not (rt-cheese-committed? rt))
                   (not (rt-cheese-proxy-xy rt))
                   (set-empty? (rt-cheese-proxy-worker-tags rt)))))

(for ([race (in-list '(Protoss Terran Zerg))])
  (define rt (make-live-bot-runtime #:bot-name 'Mothman #:race race))
  (define th-type (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
  (define w-type (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
  (define obs
    (make-base-obs
     #:race race #:enemy-race 'Terran #:frame 600
     #:minerals 600 #:gas 100 #:supply-used 14 #:supply-cap 28
     #:larva-count (if (eq? race 'Zerg) 4 0)
     #:ally-buildings (list (hash 'id 10 'type th-type 'x 28.0 'y 28.0
                                  'hp 1500 'max-hp 1500 'energy 50.0 'build-progress 1.0 'busy? #f))
     #:ally-units (make-workers w-type 12 200 28.0 28.0)))
  (define res (step-live-bot-runtime! rt obs))
  (define sline (hash-ref (hash-ref res 'telemetry (hash)) 'state-log-line ""))
  (check-test (format "l84-1c-zero-diff-normal-macro-~a" race)
              (and (not (rt-cheese-mode? rt))
                   (not (cheese-mode-active? rt))
                   (not (string-contains? sline "cheese=")))
              (format "sline=~a" sline)))

;; ===========================================================================
;; Group 2: Hard Worker Cutoffs & Expansion Suppression Across All 3 Races
;; ===========================================================================

;; 2a. Zerg `zvz-13-12-ling-bane`: worker-cap = 15, max-bases = 1
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                    #:cheese-mode? #t #:cheese-profile 'zvz-13-12-ling-bane))
  ;; At 15 Drones (AT CAP) & 2 Hatcheries (AT max-bases=2): ZERO Drone training, ZERO 3rd-base expand!
  (define obs-at-cap
    (make-base-obs
     #:race 'Zerg #:enemy-race 'Zerg #:frame 2240 ;; 100s
     #:minerals 800 #:gas 300 #:supply-used 18 #:supply-cap 36
     #:larva-count 6 #:mineral-harvesters 12 #:gas-harvesters 3
     #:ally-buildings
     (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'build-progress 1.0)
           (hash 'id 13 'type 'hatchery 'x 48.0 'y 32.0 'hp 1500 'max-hp 1500 'build-progress 1.0)
           (hash 'id 11 'type 'spawning-pool 'x 34.0 'y 28.0 'hp 1000 'max-hp 1000 'build-progress 1.0)
           (hash 'id 12 'type 'extractor 'x 32.0 'y 32.0 'hp 500 'max-hp 500 'build-progress 1.0))
     #:ally-units
     (append (make-workers 'drone 15 200 28.0 28.0 #:gas-count 3)
             (list (hash 'id 290 'type 'larva 'x 28.0 'y 29.0 'hp 25 'max-hp 25)))))
  (define res-cap (step-live-bot-runtime! rt obs-at-cap))
  (define acts-cap (step-all-actions res-cap))
  (check-test "l84-2a-zerg-zvz-13-12-hard-drone-cap-15-and-no-expand"
              (and (cheese-mode-active? rt)
                   (eq? (cheese-build-spec-id (rt-cheese-active-spec rt)) 'zvz-13-12-ling-bane)
                   (not (ormap action-is-worker-train? acts-cap))
                   (not (ormap action-is-expand? acts-cap))
                   (ormap (lambda (a)
                            (and (pair? a)
                                 (or (equal? a '(train zergling))
                                     (and (eq? (car a) 'build) (eq? (second a) 'baneling-nest))
                                     (and (eq? (car a) 'research) (eq? (second a) 'metabolic-boost)))))
                          acts-cap))
              (format "acts=~s" acts-cap))

  ;; Below cap (13 Drones < 15): DOES train Drone!
  (define rt2 (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                     #:cheese-mode? #t #:cheese-profile 'zvz-13-12-ling-bane))
  (define obs-under
    (make-base-obs
     #:race 'Zerg #:enemy-race 'Zerg #:frame 500
     #:minerals 500 #:gas 0 #:supply-used 13 #:supply-cap 22
     #:larva-count 4 #:mineral-harvesters 13
     #:ally-buildings
     (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'build-progress 1.0)
           (hash 'id 11 'type 'spawning-pool 'x 34.0 'y 28.0 'hp 1000 'max-hp 1000 'build-progress 1.0)
           (hash 'id 12 'type 'extractor 'x 32.0 'y 32.0 'hp 500 'max-hp 500 'build-progress 1.0))
     #:ally-units (make-workers 'drone 13 200 28.0 28.0)))
  (define acts-under (step-all-actions (step-live-bot-runtime! rt2 obs-under)))
  (check-test "l84-2a2-zerg-zvz-13-12-trains-drone-below-cap"
              (and (ormap action-is-worker-train? acts-under) #t)
              (format "acts=~s" acts-under)))

;; 2b. Terran `tvp-proxy-2rax-marauder`: worker-cap = 19, max-bases = 1
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                    #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define obs-at-cap
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 3000 ;; ~134s
     #:minerals 900 #:gas 300 #:supply-used 23 #:supply-cap 46
     #:mineral-harvesters 16 #:gas-harvesters 3
     #:ally-buildings
     (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'hp 1500 'max-hp 1500 'energy 20.0 'build-progress 1.0 'busy? #f)
           (hash 'id 21 'type 'supply-depot 'x 35.0 'y 28.0 'hp 400 'max-hp 400 'build-progress 1.0)
           (hash 'id 22 'type 'refinery 'x 32.0 'y 32.0 'hp 500 'max-hp 500 'build-progress 1.0)
           (hash 'id 23 'type 'barracks 'x 112.0 'y 142.0 'hp 1000 'max-hp 1000 'build-progress 1.0 'addon 'techlab 'add-on-tag 25 'busy? #f 'order-count 0)
           (hash 'id 24 'type 'barracks 'x 116.0 'y 142.0 'hp 1000 'max-hp 1000 'build-progress 1.0 'addon 'techlab 'add-on-tag 26 'busy? #f 'order-count 0)
           (hash 'id 25 'type 'barracks-techlab 'x 114.5 'y 141.5 'hp 400 'max-hp 400 'build-progress 1.0 'busy? #f)
           (hash 'id 26 'type 'barracks-techlab 'x 118.5 'y 141.5 'hp 400 'max-hp 400 'build-progress 1.0 'busy? #f))
     #:ally-units (make-workers 'scv 19 300 28.0 28.0 #:gas-count 3)))
  (define acts-cap (step-all-actions (step-live-bot-runtime! rt obs-at-cap)))
  (check-test "l84-2b-terran-tvp-proxy-2rax-hard-scv-cap-19-and-no-expand"
              (and (not (ormap action-is-worker-train? acts-cap))
                   (not (ormap action-is-expand? acts-cap))
                   (ormap (lambda (a)
                            (and (pair? a)
                                 (or (equal? a '(train marauder))
                                     (and (eq? (car a) 'research) (eq? (second a) 'concussive-shells)))))
                          acts-cap))
              (format "acts=~s" acts-cap)))

;; 2c. Protoss `pvt-proxy-4gate-zealot-stalker`: worker-cap = 16, max-bases = 1
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                    #:cheese-mode? #t #:cheese-profile 'pvt-proxy-4gate-zealot-stalker))
  (define obs-at-cap
    (make-base-obs
     #:race 'Protoss #:enemy-race 'Terran #:frame 3200 ;; ~143s
     #:minerals 900 #:gas 300 #:supply-used 22 #:supply-cap 46
     #:mineral-harvesters 13 #:gas-harvesters 3
     #:ally-buildings
     (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'hp 1000 'shields 1000 'energy 20.0 'build-progress 1.0 'busy? #f)
           (hash 'id 31 'type 'pylon 'x 34.0 'y 28.0 'hp 200 'shields 200 'build-progress 1.0)
           (hash 'id 32 'type 'assimilator 'x 32.0 'y 32.0 'hp 300 'shields 300 'build-progress 1.0)
           (hash 'id 33 'type 'cybernetics-core 'x 36.0 'y 30.0 'hp 550 'shields 550 'build-progress 1.0 'busy? #f)
           (hash 'id 34 'type 'pylon 'x 114.0 'y 142.0 'hp 200 'shields 200 'build-progress 1.0)
           (hash 'id 35 'type 'gateway 'x 112.0 'y 142.0 'hp 500 'shields 500 'build-progress 1.0 'busy? #f 'order-count 0)
           (hash 'id 36 'type 'gateway 'x 116.0 'y 142.0 'hp 500 'shields 500 'build-progress 1.0 'busy? #f 'order-count 0)
           (hash 'id 37 'type 'gateway 'x 112.0 'y 146.0 'hp 500 'shields 500 'build-progress 1.0 'busy? #f 'order-count 0)
           (hash 'id 38 'type 'gateway 'x 116.0 'y 146.0 'hp 500 'shields 500 'build-progress 1.0 'busy? #f 'order-count 0))
     #:ally-units (make-workers 'probe 16 400 28.0 28.0 #:gas-count 3)))
  (define acts-cap (step-all-actions (step-live-bot-runtime! rt obs-at-cap)))
  (check-test "l84-2c-protoss-pvt-proxy-4gate-hard-probe-cap-16-and-no-expand"
              (and (not (ormap action-is-worker-train? acts-cap))
                   (not (ormap action-is-expand? acts-cap))
                   (ormap (lambda (a)
                            (and (pair? a)
                                 (memq (car a) '(train research))
                                 (memq (second a) '(zealot stalker warp-gate-research))))
                          acts-cap))
              (format "acts=~s" acts-cap)))

;; 2d. Direct `priority-macro-brain.rkt` cheese-spec cap vs `#f` zero-diff
(let ()
  (define cspec (lookup-cheese-build-spec 'zvz-13-12-ling-bane))
  (define obs
    (make-base-obs
     #:race 'Zerg #:enemy-race 'Zerg #:frame 2240
     #:minerals 700 #:gas 150 #:supply-used 16 #:supply-cap 28
     #:larva-count 4 #:mineral-harvesters 15
     #:ally-buildings (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 11 'type 'spawning-pool 'x 34.0 'y 28.0 'build-progress 1.0))
     #:ally-units (make-workers 'drone 15 200 28.0 28.0)))
  (define mws (obs-hash->macro-world-state obs))
  (define dec-cheese (step-priority-macro-brain mws #:cheese-spec cspec))
  (define dec-normal (step-priority-macro-brain mws))
  (define cheese-goals (dynamic-macro-plan-actionable-goals (macro-brain-decision-dynamic-plan dec-cheese)))
  (define cheese-has-drone-or-3rd?
    (ormap (lambda (g) (eq? (plan-goal-node-id g) 'drone)) cheese-goals))
  (check-test "l84-2d-priority-macro-brain-cheese-suppresses-extra-drone-and-expand"
              (and (not cheese-has-drone-or-3rd?)
                   (macro-brain-decision? dec-normal))
              (format "cheese-goals=~s" (map plan-goal-node-id cheese-goals))))

;; ===========================================================================
;; Group 3: Proxy-Worker State Machine (`build-proxy`, Waypoint, Replacement)
;; ===========================================================================

;; 3a + 3b + 3c: Terran `tvp-proxy-2rax-marauder`
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                    #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define scvs (make-workers 'scv 14 300 28.0 28.0))
  ;; Frame 44 (1.96s < proxy-dispatch-sec 4.0s): no proxy worker locked yet!
  (define obs-early
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 44
     #:minerals 100 #:gas 0 #:supply-used 14 #:supply-cap 15
     #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f))
     #:ally-units scvs))
  (step-live-bot-runtime! rt obs-early)
  (check-test "l84-3a0-no-proxy-worker-locked-before-dispatch-sec"
              (set-empty? (rt-cheese-proxy-worker-tags rt))
              (format "tags=~s" (rt-cheese-proxy-worker-tags rt)))

  ;; Frame 448 (20s >= 14s), Supply Depot ready, 350M -> locks 2 SCVs, computes off-path (px, py), emits `(build-proxy barracks px py wtag)`
  (define obs-dispatch
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 448
     #:minerals 350 #:gas 0 #:supply-used 15 #:supply-cap 23
     #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))
     #:ally-units scvs))
  (define res-disp (step-live-bot-runtime! rt obs-dispatch))
  (define acts-disp (step-all-actions res-disp))
  (define pxy (rt-cheese-proxy-xy rt))
  (define locked1 (rt-cheese-proxy-worker-tags rt))
  (define bp-acts (filter (lambda (a) (action-is-build-proxy? a 'barracks)) acts-disp))
  (check-test "l84-3a1-tvp-proxy-2rax-locks-2-scvs-and-emits-build-proxy-barracks"
              (and (pair? pxy)
                   (= (set-count locked1) 2)
                   (pair? bp-acts)
                   (= (length (first bp-acts)) 5)
                   (set-member? locked1 (fifth (first bp-acts)))
                   ;; Verify off-path: perpendicular offset from line (28,28)->(160,160) is > 8t
                   (> (/ (abs (- (car pxy) (cdr pxy))) (sqrt 2.0)) 8.0))
              (format "pxy=~s locked=~s bp=~s" pxy locked1 bp-acts))

  ;; 3c. Dead proxy worker replacement: remove 1 of the 2 locked SCVs from obs -> replaced automatically!
  (define dead-tag (car (set->list locked1)))
  (define scvs-after-loss (filter (lambda (w) (not (= (hash-ref w 'id 0) dead-tag))) scvs))
  (define obs-replace
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 560
     #:minerals 100 #:gas 0 #:supply-used 14 #:supply-cap 23
     #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))
     #:ally-units scvs-after-loss))
  (define res-rep (step-live-bot-runtime! rt obs-replace))
  (define acts-rep (step-all-actions res-rep))
  (define locked2 (rt-cheese-proxy-worker-tags rt))
  (define has-waypoint-move?
    (ormap (lambda (a)
             (and (pair? a) (eq? (car a) 'move) (set-member? locked2 (second a))))
           acts-rep))
  (check-test "l84-3c-dead-proxy-worker-replaced-and-routed-via-waypoint"
              (and (= (set-count locked2) 2)
                   (not (set-member? locked2 dead-tag))
                   has-waypoint-move?)
              (format "dead=~a locked2=~s has-wp-move=~a" dead-tag locked2 has-waypoint-move?))

  ;; 3b. Proxy Barracks TechLab emits 4-element `(build-proxy barracks-tech-lab px py)`
  (define px (car pxy))
  (define py (cdr pxy))
  (define obs-addon
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 2200
     #:minerals 200 #:gas 100 #:supply-used 18 #:supply-cap 23
     #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 22 'type 'refinery 'x 32.0 'y 32.0 'build-progress 1.0)
                            (hash 'id 23 'type 'barracks 'x px 'y py 'build-progress 1.0 'order-count 0 'add-on-tag 0)
                            (hash 'id 24 'type 'barracks 'x (+ px 4.0) 'y py 'build-progress 1.0 'order-count 0 'add-on-tag 0))
     #:ally-units scvs-after-loss))
  (define acts-addon (step-all-actions (step-live-bot-runtime! rt obs-addon)))
  (define addon-bp (filter (lambda (a) (action-is-build-proxy? a 'barracks-tech-lab)) acts-addon))
  (check-test "l84-3b-tvp-proxy-emits-build-proxy-barracks-tech-lab"
              (and (pair? addon-bp) (= (length (first addon-bp)) 4))
              (format "addon-bp=~s" addon-bp)))

;; 3d. Protoss `pvz-cannon-rush` (`close-cannon`): close proxy coords + Proxy Pylon -> Proxy Cannon
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                    #:cheese-mode? #t #:cheese-profile 'pvz-cannon-rush))
  (define probes (make-workers 'probe 15 400 28.0 28.0))
  (define obs-pylon
    (make-base-obs
     #:race 'Protoss #:enemy-race 'Zerg #:frame 672 ;; 30s >= dispatch 22s
     #:minerals 200 #:gas 0 #:supply-used 15 #:supply-cap 23
     #:ally-buildings (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 31 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 32 'type 'forge 'x 36.0 'y 28.0 'build-progress 1.0))
     #:ally-units probes))
  (define acts-py (step-all-actions (step-live-bot-runtime! rt obs-pylon)))
  (define pxy (rt-cheese-proxy-xy rt))
  (define locked (rt-cheese-proxy-worker-tags rt))
  (define py-bp (filter (lambda (a) (action-is-build-proxy? a 'pylon)) acts-py))
  (define d-enemy (and pxy (dist2d (car pxy) (cdr pxy) 160.0 160.0)))
  (check-test "l84-3d1-pvz-cannon-rush-close-proxy-pylon"
              (and (pair? pxy)
                   (<= d-enemy 26.0)
                   (= (set-count locked) 2)
                   (pair? py-bp))
              (format "pxy=~s d-enemy=~a locked=~s py-bp=~s" pxy d-enemy locked py-bp))

  ;; Once Proxy Pylon is ready near (px, py), emits `(build-proxy photon-cannon px py wtag)`
  (define obs-can
    (make-base-obs
     #:race 'Protoss #:enemy-race 'Zerg #:frame 1400 ;; 62.5s
     #:minerals 250 #:gas 0 #:supply-used 15 #:supply-cap 31
     #:ally-buildings (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 31 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 32 'type 'forge 'x 36.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 33 'type 'pylon 'x (car pxy) 'y (cdr pxy) 'build-progress 1.0))
     #:ally-units probes))
  (define acts-can (step-all-actions (step-live-bot-runtime! rt obs-can)))
  (define can-bp (filter (lambda (a) (action-is-build-proxy? a 'photon-cannon)) acts-can))
  (check-test "l84-3d2-pvz-cannon-rush-emits-build-proxy-photon-cannon"
              (and (pair? can-bp) (= (length (first can-bp)) 5))
              (format "can-bp=~s" can-bp)))

;; 3e. Zerg `zvt-42d-queen-ling-nydus` (`nydus-main`): emits 4-elem `(build-proxy nydus-worm px py)`
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                    #:cheese-mode? #t #:cheese-profile 'zvt-42d-queen-ling-nydus))
  (define obs-nydus
    (make-base-obs
     #:race 'Zerg #:enemy-race 'Terran #:frame 6720 ;; 300s >= dispatch 286s
     #:minerals 250 #:gas 200 #:supply-used 52 #:supply-cap 78
     #:ally-buildings (list (hash 'id 10 'type 'lair 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 11 'type 'spawning-pool 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 12 'type 'nydus-network 'x 31.0 'y 34.0 'build-progress 1.0))
     #:ally-units (make-workers 'drone 42 200 28.0 28.0)))
  (define acts-ny (step-all-actions (step-live-bot-runtime! rt obs-nydus)))
  (define pxy (rt-cheese-proxy-xy rt))
  (define ny-bp (filter (lambda (a) (action-is-build-proxy? a 'nydus-worm)) acts-ny))
  (check-test "l84-3e-zvt-nydus-main-emits-build-proxy-nydus-worm-zero-locked-drones"
              (and (pair? pxy)
                   (<= (dist2d (car pxy) (cdr pxy) 160.0 160.0) 18.0)
                   (set-empty? (rt-cheese-proxy-worker-tags rt))
                   (pair? ny-bp)
                   (= (length (first ny-bp)) 4))
              (format "pxy=~s ny-bp=~s" pxy ny-bp)))

;; ===========================================================================
;; Group 4: Staging, Hit-Trigger Commit, Pullback Override & SCV Pull
;; ===========================================================================
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                    #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define scvs18 (make-workers 'scv 18 300 28.0 28.0 #:gas-count 3))
  (define marauders-pre
    (for/list ([i (in-range 3)])
      (hash 'id (+ 600 i) 'type 'marauder 'x (+ 42.0 i) 'y 36.0
            'hp 125 'max-hp 125 'weapon-cd 0.0)))
  ;; Pre-commit at 160s (< 195s hit-trigger): committed? = #f, units stage at proxy (px, py)
  (define obs-stage
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 3584 ;; 160s
     #:minerals 100 #:gas 50 #:supply-used 24 #:supply-cap 31
     #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))
     #:ally-units (append scvs18 marauders-pre)))
  (define res-stage (step-live-bot-runtime! rt obs-stage))
  (define acts-stage (step-all-actions res-stage))
  (define pxy (rt-cheese-proxy-xy rt))
  (define (action-unit-ids a)
    (cond
      [(and (pair? a) (>= (length a) 2) (list? (second a))) (second a)]
      [(and (pair? a) (>= (length a) 2) (exact-integer? (second a))) (list (second a))]
      [else '()]))
  (define (any-id-in? ids target-ids)
    (ormap (lambda (id) (memv id target-ids)) ids))
  (define staged-toward-proxy?
    (and (pair? pxy)
         (ormap (lambda (a)
                  (and (pair? a)
                       (memq (car a) '(attack-move attack-pos move move-pos))
                       (>= (length a) 4)
                       (real? (third a)) (real? (fourth a))
                       (any-id-in? (action-unit-ids a) '(600 601 602))
                       (< (dist2d (third a) (fourth a) (car pxy) (cdr pxy)) 12.0)))
                acts-stage)))
  (check-test "l84-4a-pre-commit-stages-combat-at-proxy-not-enemy"
              (and (not (rt-cheese-committed? rt))
                   staged-toward-proxy?)
              (format "committed=~a pxy=~s acts=~s" (rt-cheese-committed? rt) pxy acts-stage))

  ;; Post-commit at 210s (>= 195s) with 6 Marauders (12 sup >= 10), Concussive Shells researched,
  ;; AND larger enemy army defending near enemy natural -> commits, overrides pullback, pulls <= 8 non-gas SCVs!
  (define marauders-hit
    (for/list ([i (in-range 6)])
      (hash 'id (+ 600 i) 'type 'marauder 'x (+ (car pxy) (* 0.8 i)) 'y (cdr pxy)
            'hp 125 'max-hp 125 'weapon-cd 0.0)))
  (define enemy-defenders
    (for/list ([i (in-range 7)])
      (hash 'id (+ 900 i) 'type 'stalker 'x (+ 142.0 (* 0.7 i)) 'y 142.0
            'hp 80 'max-hp 80 'shields 80 'max-shields 80)))
  (define obs-commit
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 4704 ;; 210s
     #:minerals 80 #:gas 40 #:supply-used 30 #:supply-cap 39
     #:researched-upgrades '(concussive-shells)
     #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 23 'type 'barracks 'x (car pxy) 'y (cdr pxy) 'build-progress 1.0)
                            (hash 'id 24 'type 'barracks 'x (+ (car pxy) 4.0) 'y (cdr pxy) 'build-progress 1.0))
     #:ally-units (append scvs18 marauders-hit)
     #:enemy-units enemy-defenders
     #:enemy-buildings (list (hash 'id 950 'type 'nexus 'x 160.0 'y 160.0 'hp 1000 'shields 1000))))
  ;; Even with a pre-armed wave-loss pullback latch, committed cheese overrides pullback and pushes!
  (hash-set! (rt-wave-loss-state rt) 'pullback-until-frame 9999)
  (define res-commit (step-live-bot-runtime! rt obs-commit))
  (define acts-commit (step-all-actions res-commit))
  (define pulled-tags (hash-ref (rt-cheese-state rt) 'pulled-worker-tags '()))
  (define all-excluded (rt-cheese-proxy-worker-tags rt))
  (define gas-scv-ids '(300 301 302))
  (define pulled-has-gas? (ormap (lambda (tid) (memv tid gas-scv-ids)) pulled-tags))
  (define pulled-scv-attacking?
    (and (pair? pulled-tags)
         (ormap (lambda (a)
                  (and (pair? a)
                       (memq (car a) '(attack-move attack-pos))
                       (>= (length a) 4)
                       (real? (third a)) (real? (fourth a))
                       (any-id-in? (action-unit-ids a) pulled-tags)
                       (< (dist2d (third a) (fourth a) 160.0 160.0) 25.0)))
                acts-commit)))
  (define marauders-pushing?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(attack-move attack-pos attack attack-unit))
                  (any-id-in? (action-unit-ids a) '(600 601 602 603 604 605))))
           acts-commit))
  (define marauders-retreating-home?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(move move-pos))
                  (>= (length a) 4)
                  (real? (third a)) (real? (fourth a))
                  (any-id-in? (action-unit-ids a) '(600 601 602 603 604 605))
                  (< (dist2d (third a) (fourth a) 28.0 28.0) 35.0)))
           acts-commit))
  (check-test "l84-4b-hit-trigger-commits-overrides-pullback-and-pulls-non-gas-scvs"
              (and (rt-cheese-committed? rt)
                   marauders-pushing?
                   (not marauders-retreating-home?)
                   (= (length pulled-tags) 8)
                   (not pulled-has-gas?)
                   (for/and ([tid (in-list pulled-tags)]) (set-member? all-excluded tid))
                   pulled-scv-attacking?)
              (format "committed=~a m-push=~a m-retreat=~a pulled=~a gas?=~a scv-atk=~a"
                      (rt-cheese-committed? rt) marauders-pushing? marauders-retreating-home?
                      (length pulled-tags) pulled-has-gas? pulled-scv-attacking?)))

;; 4c. Home bust (`proxy-kind = 'none`): `zvp-19d-speedling-roach-ravager`
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                    #:cheese-mode? #t #:cheese-profile 'zvp-19d-speedling-roach-ravager))
  (define roaches
    (for/list ([i (in-range 8)])
      (hash 'id (+ 700 i) 'type 'roach 'x (+ 38.0 (* 0.5 i)) 'y 30.0 'hp 145 'max-hp 145 'weapon-cd 0.0)))
  (define ravagers
    (for/list ([i (in-range 3)])
      (hash 'id (+ 720 i) 'type 'ravager 'x (+ 40.0 (* 0.5 i)) 'y 32.0 'hp 120 'max-hp 120 'weapon-cd 0.0)))
  ;; Pre-commit at 170s -> stages near own natural (48, 32)
  (define obs-pre
    (make-base-obs
     #:race 'Zerg #:enemy-race 'Protoss #:frame 3808 ;; 170s
     #:minerals 50 #:gas 25 #:supply-used 44 #:supply-cap 52
     #:ally-buildings (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'build-progress 1.0))
     #:ally-units (append (make-workers 'drone 19 200 28.0 28.0) roaches ravagers)))
  (step-live-bot-runtime! rt obs-pre)
  (define pre-comm? (rt-cheese-committed? rt))
  ;; Post-commit at 230s (frame 5152 >= 225s hit-trigger, 25 sup >= 24, metabolic-boost + roach ready)
  (define obs-go
    (hash-set (hash-set obs-pre 'frame 5152) 'researched-upgrades '(metabolic-boost)))
  (step-live-bot-runtime! rt obs-go)
  (check-test "l84-4c-home-bust-zvp-19d-roach-ravager-commits-on-hit-trigger"
              (and (not pre-comm?) (rt-cheese-committed? rt))
              (format "pre=~a post=~a" pre-comm? (rt-cheese-committed? rt))))

;; ===========================================================================
;; Group 5 & 6: Graceful Macro Fallback & `[SCBOT_STATE]` Telemetry Tag
;; ===========================================================================
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                    #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define scvs18 (make-workers 'scv 18 300 28.0 28.0))
  ;; Step 1: build stage (frame 2240 = 100s) -> `[SCBOT_STATE]` has `cheese=tvp-proxy-2rax-marauder:build:19`
  (define obs-build
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 2240
     #:minerals 100 #:gas 50 #:supply-used 18 #:supply-cap 23
     #:ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))
     #:ally-units scvs18))
  (define sline-build (hash-ref (hash-ref (step-live-bot-runtime! rt obs-build) 'telemetry (hash)) 'state-log-line ""))

  ;; Step 2: commit stage (frame 4704 = 210s) -> `[SCBOT_STATE]` has `cheese=tvp-proxy-2rax-marauder:commit:19`
  (define marauders6
    (for/list ([i (in-range 6)])
      (hash 'id (+ 600 i) 'type 'marauder 'x 110.0 'y 140.0 'hp 125 'max-hp 125 'weapon-cd 0.0)))
  (define obs-commit
    (hash-set* obs-build
               'frame 4704
               'researched-upgrades '(concussive-shells)
               'ally-units (append scvs18 marauders6)))
  (define sline-commit (hash-ref (hash-ref (step-live-bot-runtime! rt obs-commit) 'telemetry (hash)) 'state-log-line ""))

  ;; Step 3: fallback at 390s (frame 8736 >= fallback-macro-sec 390.0) -> releases to normal macro!
  (define obs-fb
    (hash-set* obs-commit
               'frame 8736
               'minerals 700
               'supply-cap 60))
  (define res-fb (step-live-bot-runtime! rt obs-fb))
  (define sline-fb (hash-ref (hash-ref res-fb 'telemetry (hash)) 'state-log-line ""))
  (check-test "l84-5a-6a-scbot-state-tags-and-timeout-fallback-at-6m30"
              (and (string-contains? sline-build  "cheese=tvp-proxy-2rax-marauder:build:19")
                   (string-contains? sline-commit "cheese=tvp-proxy-2rax-marauder:commit:19")
                   (string-contains? sline-fb     "cheese=tvp-proxy-2rax-marauder:fallback:19")
                   (not (cheese-mode-active? rt))
                   (not (rt-cheese-committed? rt))
                   (set-empty? (rt-cheese-proxy-worker-tags rt)))
              (format "build=~a | commit=~a | fb=~a" sline-build sline-commit sline-fb)))

;; 5b. Destroyed-proxy fallback post-180s with < 4 combat supply
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                    #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define scvs16 (make-workers 'scv 16 300 28.0 28.0))
  ;; Dispatch proxy so proxy-xy is locked
  (define obs1
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 500
     #:minerals 200 #:gas 0 #:supply-used 16 #:supply-cap 23
     #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))
     #:ally-units scvs16))
  (step-live-bot-runtime! rt obs1)
  (define pxy (rt-cheese-proxy-xy rt))
  ;; Proxy Barracks exists at 100s -> sets proxy-built-any? = #t
  (define obs2
    (hash-set* obs1
               'frame 2240
               'ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 23 'type 'barracks 'x (car pxy) 'y (cdr pxy) 'build-progress 1.0))))
  (step-live-bot-runtime! rt obs2)
  (define active-before? (cheese-mode-active? rt))
  ;; At 190s (frame 4256), proxy Barracks destroyed and 0 combat units -> fallback triggers!
  (define obs3
    (hash-set* obs1
               'frame 4256
               'ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))))
  (step-live-bot-runtime! rt obs3)
  (check-test "l84-5b-destroyed-proxy-post-180s-triggers-macro-fallback"
              (and active-before?
                   (not (cheese-mode-active? rt))
                   (set-empty? (rt-cheese-proxy-worker-tags rt)))
              (format "before=~a after=~a" active-before? (cheese-mode-active? rt))))

;; ===========================================================================
;; Group 7: CLI / Env / `config.json` / `Mothman-{ZC,TC,PC,XC}` Dry-Run
;; ===========================================================================
(let ()
  (define prev-cm (getenv "MOTHMAN_CHEESE_MODE"))
  (define prev-cp (getenv "MOTHMAN_CHEESE_PROFILE"))
  (dynamic-wind
    (lambda ()
      (putenv "MOTHMAN_CHEESE_MODE" "")
      (putenv "MOTHMAN_CHEESE_PROFILE" ""))
    (lambda ()
      ;; 7a. Normal Main Macro `--BotName Mothman-P --dry-run` -> cheese_mode #f
      (define res-p (run-cli-silent '("--BotName" "Mothman-P" "--dry-run")))
      (check-test "l84-7a-cli-dry-run-main-macro-cheese-false"
                  (and (equal? (hash-ref res-p 'status #f) "DRY_RUN_OK")
                       (equal? (hash-ref res-p 'resolved_race #f) "Protoss")
                       (eq? (hash-ref res-p 'cheese_mode #t) #f)
                       (equal? (hash-ref res-p 'cheese_profile #f) "none"))
                  (format "res=~s" res-p))

      ;; 7b. All 4 Version C variants auto-enable cheese_mode and resolve exact race!
      (for ([pair (in-list '(("Mothman-PC" . "Protoss")
                             ("Mothman-TC" . "Terran")
                             ("Mothman-ZC" . "Zerg")
                             ("Mothman-XC" . "Random")))])
        (define r (run-cli-silent (list "--BotName" (car pair) "--dry-run")))
        (check-test (format "l84-7b-cli-dry-run-variant-~a" (car pair))
                    (and (equal? (hash-ref r 'status #f) "DRY_RUN_OK")
                         (equal? (hash-ref r 'resolved_race #f) (cdr pair))
                         (eq? (hash-ref r 'cheese_mode #f) #t)
                         (equal? (hash-ref r 'cheese_profile #f) "auto"))
                    (format "res=~s" r)))

      ;; 7c. CLI flags `--cheese-mode --cheese-profile` & env vars `MOTHMAN_CHEESE_MODE`/`PROFILE`
      (define res-cli
        (run-cli-silent '("--BotName" "Mothman-T" "--cheese-mode"
                          "--cheese-profile" "tvp-proxy-2rax-marauder" "--dry-run")))
      (putenv "MOTHMAN_CHEESE_MODE" "1")
      (putenv "MOTHMAN_CHEESE_PROFILE" "zvz-13-12-ling-bane")
      (define res-env
        (run-cli-silent '("--BotName" "Mothman-Z" "--dry-run")))
      (putenv "MOTHMAN_CHEESE_MODE" "")
      (putenv "MOTHMAN_CHEESE_PROFILE" "")
      (check-test "l84-7c-cli-flags-and-env-vars-cheese-profile"
                  (and (eq? (hash-ref res-cli 'cheese_mode #f) #t)
                       (equal? (hash-ref res-cli 'cheese_profile #f) "tvp-proxy-2rax-marauder")
                       (eq? (hash-ref res-env 'cheese_mode #f) #t)
                       (equal? (hash-ref res-env 'cheese_profile #f) "zvz-13-12-ling-bane"))
                  (format "cli=~s env=~s" res-cli res-env))

      ;; 7d. Stamped `config.json` (like repacked Version C zip / arena staging) with zero CLI flags
      (define tmp-dir (make-temporary-directory "l84-cheese-cfg-~a"))
      (dynamic-wind
        void
        (lambda ()
          (call-with-output-file (build-path tmp-dir "config.json")
            (lambda (out)
              (write-json (hasheq 'BotName "Mothman-PC"
                                  'BotRace "Protoss"
                                  'BotPath "bots/Mothman-P.rkt"
                                  'CheeseMode #t
                                  'CheeseProfile "pvz-cannon-rush")
                          out))
            #:exists 'truncate/replace)
          (define res-cfg
            (parameterize ([current-directory tmp-dir])
              (run-cli-silent '("--dry-run"))))
          (check-test "l84-7d-config-json-cheese-mode-and-profile-zero-cli-flags"
                      (and (equal? (hash-ref res-cfg 'bot_name #f) "Mothman-PC")
                           (equal? (hash-ref res-cfg 'resolved_race #f) "Protoss")
                           (eq? (hash-ref res-cfg 'cheese_mode #f) #t)
                           (equal? (hash-ref res-cfg 'cheese_profile #f) "pvz-cannon-rush"))
                      (format "res=~s" res-cfg)))
        (lambda ()
          (when (directory-exists? tmp-dir)
            (delete-directory/files tmp-dir)))))
    (lambda ()
      (putenv "MOTHMAN_CHEESE_MODE" (or prev-cm ""))
      (putenv "MOTHMAN_CHEESE_PROFILE" (or prev-cp "")))))

;; ===========================================================================
;; Group 8: End-to-End Wire Interop (`build-proxy` + `#:exclude-worker-tags`)
;; ===========================================================================
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                    #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define scvs (make-workers 'scv 14 300 28.0 28.0))
  (define obs
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 448
     #:minerals 350 #:gas 0 #:supply-used 15 #:supply-cap 23
     #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))
     #:ally-units scvs))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define bp-act (findf (lambda (a) (action-is-build-proxy? a 'barracks)) acts))
  (define excl (rt-cheese-proxy-worker-tags rt))
  ;; Build a minimal sc2-observation containing the locked SCV + mineral patch so wire translator & saturation run end-to-end
  (define px (if bp-act (third bp-act) 110.0))
  (define py (if bp-act (fourth bp-act) 140.0))
  (define wtag (if bp-act (fifth bp-act) 300))
  (define (mk-proto-unit tag utype x y #:alliance [alliance 1] #:owner [owner 1] #:radius [radius 1.0] #:hp [hp 100.0] #:minerals [minerals 0] #:assigned [assigned 0] #:ideal [ideal 0])
    (sc2-unit 1 alliance tag utype owner
              (sc2-point3d (exact->inexact x) (exact->inexact y) 10.0)
              0.0 (exact->inexact radius) 1.0
              0 #f #t #f (exact->inexact hp) (exact->inexact hp)
              0.0 0.0 0.0 0.0
              minerals 0 #f #f #f #t #f
              '() 0 '()
              assigned ideal 0.0 0 0 0 0))
  (define open-grid (sc2-image-grid 8 200 200 (make-bytes (* 200 200) 1) #f #t))
  (define proto-gi
    (sc2-game-info "TestCheeseArena" "TestCheeseArena.SC2Map" '()
                   (sc2-point2d 200.0 200.0)
                   (list (sc2-point2d 0.0 0.0) (sc2-point2d 200.0 200.0))
                   (list (sc2-point2d 160.0 160.0))
                   open-grid open-grid #f))
  (define proto-obs
    (sc2-observation
     448
     (sc2-player-common 1 350 0 15 23 0 14 0 0 0 0)
     (list
      (mk-proto-unit 20 18 28.0 28.0 #:radius 2.75 #:hp 1500.0 #:assigned 14 #:ideal 16)
      (mk-proto-unit 21 19 34.0 28.0 #:radius 1.0 #:hp 400.0)
      (mk-proto-unit wtag 45 px py #:radius 0.375 #:hp 45.0)
      (mk-proto-unit 301 45 26.0 28.0 #:radius 0.375 #:hp 45.0)
      (mk-proto-unit 9001 341 22.0 28.0 #:alliance 3 #:owner 0 #:radius 1.0 #:hp 0.0 #:minerals 900))
     '() '() (sc2-point3d 28.0 28.0 10.0) '() '() '() '() '() '()))
  (define before-rej (get-total-bot-action-reject-count))
  (define raw-cmds (translate-bot-actions->sc2-raw-commands (list bp-act) proto-obs #:game-info proto-gi))
  (define after-rej (get-total-bot-action-reject-count))
  (define sat-cmds (saturate-workers-and-gas-commands proto-obs #:exclude-worker-tags excl #:game-info proto-gi))
  (define sat-touched-locked?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (ormap (lambda (t) (set-member? excl t))
                         (sc2-raw-unit-command-unit-tags c))))
           sat-cmds))
  (check-test "l84-8a-end-to-end-build-proxy-and-exclude-worker-tags-wire-interop"
              (and bp-act
                   (= after-rej before-rej)
                   (pair? raw-cmds)
                   (not sat-touched-locked?))
              (format "bp=~s raw-n=~a rej=~a sat-locked?=~a"
                      bp-act (length raw-cmds) (- after-rej before-rej) sat-touched-locked?)))

;; ===========================================================================
;; Group 9: Loop 84B Polish (All 5 Live-Replay Execution Seams)
;; ===========================================================================

;; 9a. Cannon Rush: pending oledger dedup + 72f Pylon lock + Cannon #1 priority ahead of Pylon #2
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                    #:cheese-mode? #t #:cheese-profile 'pvz-cannon-rush))
  (define probes (make-workers 'probe 16 400 28.0 28.0))
  ;; Step 1 (frame 672): drops Proxy Pylon #1
  (define obs1
    (make-base-obs
     #:race 'Protoss #:enemy-race 'Zerg #:frame 672
     #:minerals 200 #:gas 0 #:supply-used 16 #:supply-cap 23
     #:ally-buildings (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 31 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 32 'type 'forge 'x 36.0 'y 28.0 'build-progress 1.0))
     #:ally-units probes))
  (define acts1 (step-all-actions (step-live-bot-runtime! rt obs1)))
  (define pxy (rt-cheese-proxy-xy rt))
  (define py1? (ormap (lambda (a) (action-is-build-proxy? a 'pylon)) acts1))
  ;; Step 2 (frame 680 = 8f later, Pylon #1 pending in oledger, 250M): ZERO duplicate Pylon!
  (define obs2 (hash-set* obs1 'frame 680 'minerals 250))
  (define acts2 (step-all-actions (step-live-bot-runtime! rt obs2)))
  (define py2-dup? (ormap (lambda (a) (action-is-build-proxy? a 'pylon)) acts2))
  ;; Step 3 (frame 1100, Proxy Pylon #1 under construction 0.5, 250M): STILL defers Pylon #2!
  (define obs3
    (hash-set* obs1
               'frame 1100
               'minerals 250
               'ally-buildings (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                                     (hash 'id 31 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 32 'type 'forge 'x 36.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 33 'type 'pylon 'x (car pxy) 'y (cdr pxy) 'build-progress 0.5))))
  (define acts3 (step-all-actions (step-live-bot-runtime! rt obs3)))
  (define py3-premature? (ormap (lambda (a) (action-is-build-proxy? a 'pylon)) acts3))
  ;; Step 4 (frame 1400, Proxy Pylon #1 ready + Forge ready + 160M): drops Photon Cannon #1, NOT Pylon #2!
  (define obs4
    (hash-set* obs1
               'frame 1400
               'minerals 160
               'ally-buildings (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                                     (hash 'id 31 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 32 'type 'forge 'x 36.0 'y 28.0 'build-progress 1.0)
                                     (hash 'id 33 'type 'pylon 'x (car pxy) 'y (cdr pxy) 'build-progress 1.0))))
  (define acts4 (step-all-actions (step-live-bot-runtime! rt obs4)))
  (define can4? (ormap (lambda (a) (action-is-build-proxy? a 'photon-cannon)) acts4))
  (define py4? (ormap (lambda (a) (action-is-build-proxy? a 'pylon)) acts4))
  (check-test "l84b-9a-cannon-rush-oledger-dedup-and-cannon1-priority-over-pylon2"
              (and py1? (not py2-dup?) (not py3-premature?) can4? (not py4?))
              (format "py1=~a dup2=~a pre3=~a can4=~a py4=~a" py1? py2-dup? py3-premature? can4? py4?)))

;; 9b. Proxy Spine (`zvz-12pool-proxy-spine`): enemy-natural creep anchor & ZERO 2nd Hatch when natural-blocked
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                    #:cheese-mode? #t #:cheese-profile 'zvz-12pool-proxy-spine))
  (define obs
    (hash-set*
     (make-base-obs
      #:race 'Zerg #:enemy-race 'Zerg #:frame 2240 ;; 100s >= dispatch 68s
      #:minerals 500 #:gas 0 #:supply-used 16 #:supply-cap 28
      #:larva-count 4 #:mineral-harvesters 15
      #:ally-buildings (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'build-progress 1.0)
                             (hash 'id 11 'type 'spawning-pool 'x 34.0 'y 28.0 'build-progress 1.0))
      #:ally-units (make-workers 'drone 15 200 28.0 28.0))
     'enemy-natural-x 132.0
     'enemy-natural-y 148.0
     'natural-blocked #t))
  (define acts (step-all-actions (step-live-bot-runtime! rt obs)))
  (define pxy (rt-cheese-proxy-xy rt))
  (define d-enat (and pxy (dist2d (car pxy) (cdr pxy) 132.0 148.0)))
  (define spine-bp? (ormap (lambda (a) (action-is-build-proxy? a 'spine-crawler)) acts))
  (define leaked-expand? (ormap action-is-expand? acts))
  (check-test "l84b-9b-proxy-spine-enemy-nat-creep-anchor-and-zero-blocked-nat-hatch"
              (and (pair? pxy) (<= d-enat 8.0) spine-bp? (not leaked-expand?))
              (format "pxy=~s d-enat=~a spine?=~a expand?=~a" pxy d-enat spine-bp? leaked-expand?)))

;; 9c. Timing cheeses: Drone 3x batch + filler gate + Lair 150M/100G reserve + Warp Prism 250M reserve
(let ()
  ;; 9c-1: `zvt-42d-queen-ling-nydus` at 25 Drones (< 40), 160s (< 310-45): trains 3 Drones & gates Stage 7 Lings!
  (define rt-nyd (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                        #:cheese-mode? #t #:cheese-profile 'zvt-42d-queen-ling-nydus))
  (define obs-ramp
    (make-base-obs
     #:race 'Zerg #:enemy-race 'Terran #:frame 3584 ;; 160s
     #:minerals 400 #:gas 50 #:supply-used 29 #:supply-cap 52
     #:larva-count 6 #:mineral-harvesters 22 #:gas-harvesters 3
     #:researched-upgrades '(metabolic-boost)
     #:ally-buildings (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 11 'type 'hatchery 'x 48.0 'y 32.0 'build-progress 1.0)
                            (hash 'id 12 'type 'hatchery 'x 68.0 'y 36.0 'build-progress 1.0)
                            (hash 'id 13 'type 'spawning-pool 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 14 'type 'extractor 'x 32.0 'y 32.0 'build-progress 1.0))
     #:ally-units (append (make-workers 'drone 25 200 28.0 28.0 #:gas-count 3)
                          (for/list ([i (in-range 4)])
                            (hash 'id (+ 260 i) 'type 'queen 'x 30.0 'y 28.0 'hp 175 'max-hp 175 'energy 10.0)))))
  (define acts-ramp (step-all-actions (step-live-bot-runtime! rt-nyd obs-ramp)))
  (define drone-trains (count (lambda (a) (equal? a '(train drone))) acts-ramp))
  (define ling-trains (count (lambda (a) (equal? a '(train zergling))) acts-ramp))
  (check-test "l84b-9c1-timing-cheese-3x-drone-ramp-and-stage7-ling-filler-gated"
              (and (= drone-trains 3) (= ling-trains 0))
              (format "drones=~a lings=~a acts=~s" drone-trains ling-trains acts-ramp))

  ;; 9c-2: `zvt-42d-queen-ling-nydus` at 42 Drones, 240s, 145M/132G (Lair 150M/100G due!): reserves 150M so Lings don't eat it!
  (define obs-lair-res
    (make-base-obs
     #:race 'Zerg #:enemy-race 'Terran #:frame 5376 ;; 240s >= Lair 235s
     #:minerals 145 #:gas 132 #:supply-used 52 #:supply-cap 78
     #:larva-count 6 #:mineral-harvesters 36 #:gas-harvesters 6
     #:researched-upgrades '(metabolic-boost)
     #:ally-buildings (list (hash 'id 10 'type 'hatchery 'x 28.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 11 'type 'hatchery 'x 48.0 'y 32.0 'build-progress 1.0)
                            (hash 'id 12 'type 'hatchery 'x 68.0 'y 36.0 'build-progress 1.0)
                            (hash 'id 13 'type 'spawning-pool 'x 34.0 'y 28.0 'build-progress 1.0)
                            (hash 'id 14 'type 'extractor 'x 32.0 'y 32.0 'build-progress 1.0)
                            (hash 'id 15 'type 'extractor 'x 52.0 'y 36.0 'build-progress 1.0))
     #:ally-units (append (make-workers 'drone 42 200 28.0 28.0 #:gas-count 6)
                          (for/list ([i (in-range 7)])
                            (hash 'id (+ 260 i) 'type 'queen 'x 30.0 'y 28.0 'hp 175 'max-hp 175 'energy 10.0))
                          (for/list ([i (in-range 6)])
                            (hash 'id (+ 280 i) 'type 'overlord 'x 35.0 'y 35.0 'hp 200 'max-hp 200)))))
  (define acts-lair-res (step-all-actions (step-live-bot-runtime! rt-nyd obs-lair-res)))
  (define ling-stole-lair? (ormap (lambda (a) (equal? a '(train zergling))) acts-lair-res))
  ;; Once minerals reach 160M, Lair morphs immediately!
  (define acts-lair-go (step-all-actions (step-live-bot-runtime! rt-nyd (hash-set* obs-lair-res 'frame 5400 'minerals 160))))
  (define morphed-lair? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'morph) (eq? (second a) 'lair))) acts-lair-go))
  (check-test "l84b-9c2-lair-150m-reserve-blocks-ling-spam-and-morphs-lair"
              (and (not ling-stole-lair?) morphed-lair?)
              (format "stole?=~a morphed?=~a" ling-stole-lair? morphed-lair?))

  ;; 9c-3: `pvz-32p-8gate-chargelot-prism` reserves 250M for Warp Prism #1 ahead of Zealot filler!
  (define rt-prism (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                          #:cheese-mode? #t #:cheese-profile 'pvz-32p-8gate-chargelot-prism))
  (define obs-prism-res
    (make-base-obs
     #:race 'Protoss #:enemy-race 'Zerg #:frame 5824 ;; 260s
     #:minerals 200 #:gas 100 #:supply-used 42 #:supply-cap 78
     #:researched-upgrades '(warp-gate-research charge)
     #:ally-buildings (append
                       (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                             (hash 'id 31 'type 'nexus 'x 48.0 'y 32.0 'build-progress 1.0 'busy? #f)
                             (hash 'id 32 'type 'pylon 'x 34.0 'y 28.0 'build-progress 1.0)
                             (hash 'id 33 'type 'pylon 'x 38.0 'y 28.0 'build-progress 1.0)
                             (hash 'id 34 'type 'pylon 'x 42.0 'y 28.0 'build-progress 1.0)
                             (hash 'id 35 'type 'assimilator 'x 32.0 'y 32.0 'build-progress 1.0)
                             (hash 'id 36 'type 'assimilator 'x 52.0 'y 36.0 'build-progress 1.0)
                             (hash 'id 37 'type 'cybernetics-core 'x 36.0 'y 30.0 'build-progress 1.0)
                             (hash 'id 38 'type 'twilight-council 'x 36.0 'y 34.0 'build-progress 1.0)
                             (hash 'id 39 'type 'robotics-facility 'x 40.0 'y 34.0 'build-progress 1.0 'busy? #f 'order-count 0))
                       (for/list ([i (in-range 8)])
                         (hash 'id (+ 40 i) 'type 'warp-gate 'x (+ 32.0 (* 2.0 i)) 'y 24.0 'build-progress 1.0 'busy? #f 'order-count 0)))
     #:ally-units (make-workers 'probe 32 400 28.0 28.0 #:gas-count 6)))
  (define acts-p200 (step-all-actions (step-live-bot-runtime! rt-prism obs-prism-res)))
  (define zealot-stole-prism? (ormap (lambda (a) (equal? a '(train zealot))) acts-p200))
  (define acts-p260 (step-all-actions (step-live-bot-runtime! rt-prism (hash-set* obs-prism-res 'frame 5840 'minerals 260))))
  (define trained-prism? (ormap (lambda (a) (equal? a '(train warp-prism))) acts-p260))
  (check-test "l84b-9c3-chargelot-prism-reserves-250m-and-trains-warp-prism"
              (and (not zealot-stole-prism?) trained-prism?)
              (format "zealot-stole?=~a prism?=~a" zealot-stole-prism? trained-prism?)))

;; 9d. Global Early Double Supply Provider: NO 2nd Depot/Pylon while #1 is unfinished at supply <= 16
(let ()
  (define rt-t (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                      #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define obs-t
    (make-base-obs
     #:race 'Terran #:enemy-race 'Protoss #:frame 580 ;; ~26s
     #:minerals 180 #:gas 0 #:supply-used 15 #:supply-cap 15
     #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 0.5))
     #:ally-units (make-workers 'scv 15 300 28.0 28.0)))
  (define acts-t (step-all-actions (step-live-bot-runtime! rt-t obs-t)))
  (define dup-depot? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'supply-depot))) acts-t))

  (define rt-p (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                      #:cheese-mode? #t #:cheese-profile 'pvz-32p-8gate-chargelot-prism))
  (define obs-p
    (make-base-obs
     #:race 'Protoss #:enemy-race 'Zerg #:frame 600 ;; ~27s
     #:minerals 180 #:gas 0 #:supply-used 15 #:supply-cap 15
     #:ally-buildings (list (hash 'id 30 'type 'nexus 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                            (hash 'id 31 'type 'pylon 'x 34.0 'y 28.0 'build-progress 0.5))
     #:ally-units (make-workers 'probe 15 400 28.0 28.0)))
  (define acts-p (step-all-actions (step-live-bot-runtime! rt-p obs-p)))
  (define dup-pylon? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-p))
  (check-test "l84b-9d-no-early-double-supply-depot-or-pylon-at-supply-le-16"
              (and (not dup-depot?) (not dup-pylon?))
              (format "dup-depot?=~a dup-pylon?=~a" dup-depot? dup-pylon?)))

;; 9e. Forward Bunker Placement (`tvz-proxy-2rax-bunker`): drops outside enemy natural (25..30t), NOT mid-map proxy
(let ()
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                    #:cheese-mode? #t #:cheese-profile 'tvz-proxy-2rax-bunker))
  (define scvs (make-workers 'scv 17 300 28.0 28.0))
  ;; Step 1: establish proxy-xy
  (define obs1
    (hash-set*
     (make-base-obs
      #:race 'Terran #:enemy-race 'Zerg #:frame 448
      #:minerals 100 #:gas 0 #:supply-used 17 #:supply-cap 23
      #:ally-buildings (list (hash 'id 20 'type 'command-center 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                             (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0))
      #:ally-units scvs)
     'enemy-natural-x 138.0
     'enemy-natural-y 142.0))
  (step-live-bot-runtime! rt obs1)
  (define pxy (rt-cheese-proxy-xy rt))
  ;; Step 2 (frame 2400 = 107s): both proxy Barracks exist at (px, py), 200M -> Bunker placed outside enemy natural!
  (define obs2
    (hash-set*
     obs1
     'frame 2400
     'minerals 200
     'ally-buildings (list (hash 'id 20 'type 'orbital-command 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f)
                           (hash 'id 21 'type 'supply-depot 'x 34.0 'y 28.0 'build-progress 1.0)
                           (hash 'id 23 'type 'barracks 'x (car pxy) 'y (cdr pxy) 'build-progress 1.0 'order-count 0)
                           (hash 'id 24 'type 'barracks 'x (+ (car pxy) 4.0) 'y (cdr pxy) 'build-progress 1.0 'order-count 0))))
  (define acts2 (step-all-actions (step-live-bot-runtime! rt obs2)))
  (define bunk-bp (findf (lambda (a) (action-is-build-proxy? a 'bunker)) acts2))
  (define d-enemy (and bunk-bp (dist2d (third bunk-bp) (fourth bunk-bp) 160.0 160.0)))
  (define d-mid-proxy (and bunk-bp pxy (dist2d (third bunk-bp) (fourth bunk-bp) (car pxy) (cdr pxy))))
  (check-test "l84b-9e-tvz-proxy-2rax-bunker-placed-outside-enemy-natural"
              (and bunk-bp
                   (>= d-enemy 24.0)
                   (<= d-enemy 31.0)
                   (> d-mid-proxy 20.0))
              (format "bunk-bp=~s d-enemy=~a d-mid=~a pxy=~s" bunk-bp d-enemy d-mid-proxy pxy)))

;; ===========================================================================
;; Group 10: Loop 84C — `--cheese-profile auto` Lobby `opponent-requested-race`
;; ===========================================================================
(let ()
  (define (make-f0-lobby-obs our-race opp-req-race #:enemy-units [enemy-units '()] #:frame [frame 0])
    (define th-type (case our-race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
    (define w-type (case our-race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
    ;; Intentionally omit `'enemy-race` (just like live `sc2-observation->runtime-obs-hash`!)
    ;; and pass ONLY `'opponent-requested-race` so `auto` MUST read it at f=0!
    (hash 'frame frame
          'race our-race
          'opponent-requested-race opp-req-race
          'minerals 50 'gas 0 'supply-used 12 'supply-cap 15
          'mineral-harvesters 12 'gas-harvesters 0
          'base-x 28.0 'base-y 28.0
          'natural-x 48.0 'natural-y 32.0
          'third-x 68.0 'third-y 36.0
          'enemy-x 160.0 'enemy-y 160.0
          'enemy-base '(160.0 160.0)
          'map-width 200.0 'map-height 200.0
          'ally-buildings (list (hash 'id 10 'type th-type 'x 28.0 'y 28.0 'build-progress 1.0 'busy? #f))
          'ally-units (make-workers w-type 12 200 28.0 28.0)
          'enemy-units enemy-units
          'enemy-buildings '()
          'mineral-patches (list (hash 'id 9001 'x 22.0 'y 28.0 'minerals 900))))

  ;; 10a. Symbol & string `'opponent-requested-race` across Z/P/T selects exact true matchup at f=0!
  (for ([tc (in-list '((Zerg    Protoss  "zvp-" "l84c-10a-auto-ZvP-sym")
                       (Zerg    "Zerg"   "zvz-" "l84c-10a-auto-ZvZ-str")
                       (Protoss Zerg     "pvz-" "l84c-10a-auto-PvZ-sym")
                       (Protoss "Protoss" "pvp-" "l84c-10a-auto-PvP-str")
                       (Terran  Protoss  "tvp-" "l84c-10a-auto-TvP-sym")
                       (Terran  "Terran" "tvt-" "l84c-10a-auto-TvT-str")))])
    (define our-r (first tc))
    (define opp-req (second tc))
    (define exp-prefix (third tc))
    (define label (fourth tc))
    (define rt (make-live-bot-runtime #:bot-name 'Mothman-XC #:race our-r
                                      #:cheese-mode? #t #:cheese-profile 'auto #:cheese-seed "opp-seed-1"))
    (step-live-bot-runtime! rt (make-f0-lobby-obs our-r opp-req))
    (define cspec (rt-cheese-active-spec rt))
    (define cid-str (if cspec (symbol->string (cheese-build-spec-id cspec)) "none"))
    (check-test label
                (and (cheese-build-spec? cspec)
                     (string-prefix? cid-str exp-prefix))
                (format "picked=~a expected-prefix=~a" cid-str exp-prefix)))

  ;; 10b. Random lobby opponent picks safe default at f=0 AND updates to exact matchup once scouted < 45s!
  (define rt-rnd (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                        #:cheese-mode? #t #:cheese-profile 'auto #:cheese-seed "rnd-opp"))
  (step-live-bot-runtime! rt-rnd (make-f0-lobby-obs 'Zerg 'Random #:frame 0))
  (define cspec-f0 (rt-cheese-active-spec rt-rnd))
  ;; Scout sees a Protoss Probe at frame 672 (30s < 45s) -> updates immediately to ZvP!
  (step-live-bot-runtime!
   rt-rnd
   (make-f0-lobby-obs 'Zerg 'Random #:frame 672
                      #:enemy-units (list (hash 'id 901 'type 'probe 'x 110.0 'y 110.0 'hp 20 'shields 20))))
  (define cspec-scouted (rt-cheese-active-spec rt-rnd))
  (define cid-scouted (if cspec-scouted (symbol->string (cheese-build-spec-id cspec-scouted)) "none"))
  (check-test "l84c-10b-auto-vs-random-safe-f0-and-updates-on-early-scout"
              (and (cheese-build-spec? cspec-f0)
                   (cheese-build-spec? cspec-scouted)
                   (string-prefix? cid-scouted "zvp-"))
              (format "f0=~a scouted=~a"
                      (and cspec-f0 (cheese-build-spec-id cspec-f0))
                      cid-scouted)))

(printf "=== Results: ~a/~a passed (~a failed) ===\n"
        pass-count (+ pass-count fail-count) fail-count)
(unless (= fail-count 0)
  (exit 1))
