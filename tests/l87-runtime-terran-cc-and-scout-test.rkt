#lang racket/base

(require racket/list
         racket/math
         racket/set
         racket/string
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-placement.rkt"
         "../lib/opponent-world-model.rkt"
         "../lib/priority-macro-brain.rkt"
         "../lib/human-cortex.rkt"
         "../lib/plan/nydus.rkt"
         "../lib/bot-runtime.rkt")

;; =============================================================================
;; Loop 87 Track 4 Unit Test Suite (`tests/l87-runtime-terran-cc-and-scout-test.rkt`)
;;
;; Verifies runtime integration of:
;;   1. Terran 400M in-flight SCV walk mineral reserve (ability 318 & 224f window),
;;      +1 pending CC count for Brain, clear on real CC start / 224f expiry, and
;;      release under heavy base attack
;;   2. Brain-scheduled Terran 4th/5th CC emitting cleanly at 48 SCVs (bypassing
;;      64/80 SCV floor) + in-base high-ground CC fallback at >= 450M when pads camped
;;   3. Protoss doorway-corridor AABB widened to >= 1.15 persisting past frame 4800
;;      and faster supply-block stall recovery (134f / 6s)
;;   4. Local PF proximity (<= 14t) for Tank-shell-zone commit-fire, lower Home Muster
;;      thresholds (1100 enter / 0.72x release), winning-Protoss l35/l36 exemption,
;;      and hardened <= 6.5t home Observer anchor vs Banshee & Dark Templar
;;   5. Terran SCV behind-TH geyser-sweep (1568..3360, dot(wp - enemy, enemy->nat) < 0)
;;      & Reaper-less TvT 17-supply scout + Zerg OV1 side-flank geyser arc (1792..3360,
;;      back-wall geysers within 11.0t sight, side alternation, instant 14t AA abort)
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
              #:order-count [oc 0]
              #:orders [orders '()]
              #:weapon-cooldown [wcd 0.0]
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
        'order-count oc
        'orders orders
        'weapon-cooldown (exact->inexact wcd)
        'build-progress bp
        'display-type 1))

(define (mk-workers type n start-id bx by)
  (for/list ([i (in-range n)])
    (mk-u (+ start-id i) type
          (+ bx (- (* 0.35 (modulo i 10)) 1.8))
          (+ by (if (< (modulo i 16) 8) -1.5 1.5))
          #:hp (case type [(scv) 45.0] [(drone) 40.0] [else 20.0])
          #:shield (if (eq? type 'probe) 20.0 0.0))))

(define (mk-mineral-patches bx by [start-id 9000])
  (for/list ([i (in-range 8)])
    (hash 'id (+ start-id i) 'type 'mineral-field
          'x (- bx 5.5) 'y (+ (- by 3.5) (* 1.0 i))
          'mineral-contents 1200)))

(define (mk-live-obs #:race race
                     #:enemy-race [er 'Terran]
                     #:frame frame
                     #:minerals [minerals 450]
                     #:gas [gas 150]
                     #:supply-used [sup-u 60]
                     #:supply-cap [sup-c 90]
                     #:army-supply [army-sup 24]
                     #:ally-units [au '()]
                     #:ally-buildings [ab '()]
                     #:enemy-units [eu '()]
                     #:enemy-buildings [eb '()]
                     #:base-x [bx 32.0] #:base-y [by 32.0]
                     #:nat-x [nx 56.0] #:nat-y [ny 32.0]
                     #:enemy-x [ex 158.0] #:enemy-y [ey 158.0]
                     #:enemy-exp-x [eex 134.0] #:enemy-exp-y [eey 136.0]
                     #:expansions [exps (list (cons 32.0 32.0)
                                              (cons 56.0 32.0)
                                              (cons 80.0 34.0)
                                              (cons 32.0 66.0)
                                              (cons 56.0 86.0)
                                              (cons 134.0 136.0)
                                              (cons 158.0 158.0))]
                     #:mineral-harvesters [mh 32]
                     #:vespene-harvesters [vh 6])
  (hash 'race race
        'enemy-race er
        'frame frame
        'minerals minerals
        'gas gas
        'supply-used sup-u
        'supply-cap sup-c
        'supply-left (max 0 (- sup-c sup-u))
        'army-supply army-sup
        'mineral-harvesters mh
        'vespene-harvesters vh
        'base-x bx 'base-y by
        'natural-x nx 'natural-y ny
        'enemy-x ex 'enemy-y ey
        'enemy-expand-x eex 'enemy-expand-y eey
        'map-width 192.0 'map-height 192.0
        'expansion-locations exps
        'expansion-pads exps
        'mineral-patches (mk-mineral-patches bx by)
        'ally-units au
        'ally-buildings ab
        'enemy-units eu
        'enemy-buildings eb))

(define (run-l34 rt obs)
  (define r (step-live-bot-runtime! rt obs))
  (hash-ref r 'actions '()))

(printf "=== Loop 87 Track 4 Unit Test Suite ===\n")

;; ---------------------------------------------------------------------------
;; T1: Terran 400M In-Flight SCV Walk Mineral Reserve & Pending CC Count
;; ---------------------------------------------------------------------------
(let ()
  (define t-bldgs-3b
    (list (mk-u 1001 'orbital-command 32.0 32.0 #:hp 1500.0 #:order-count 1)
          (mk-u 1002 'orbital-command 56.0 32.0 #:hp 1500.0 #:order-count 1)
          (mk-u 1003 'orbital-command 80.0 34.0 #:hp 1500.0 #:order-count 1)
          (mk-u 1004 'barracks 42.0 34.0 #:hp 1000.0)
          (mk-u 1005 'barracks 42.0 38.0 #:hp 1000.0)
          (mk-u 1006 'factory 46.0 34.0 #:hp 1250.0)
          (mk-u 1007 'starport 46.0 38.0 #:hp 1300.0)
          (mk-u 1008 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 1009 'supply-depot 38.0 32.0 #:hp 400.0)
          (mk-u 1010 'refinery 28.0 36.0 #:hp 500.0)))
  (define scv-walking
    (mk-u 1199 'scv 36.0 54.0 #:hp 45.0 #:order-count 1
          #:orders (list (hasheq 'ability-id 318))))
  (define t-army-mid
    (append (for/list ([i (in-range 12)]) (mk-u (+ 1200 i) 'marine (+ 58.0 (* 0.3 i)) 38.0 #:hp 45.0))
            (for/list ([i (in-range 3)])  (mk-u (+ 1220 i) 'marauder (+ 60.0 (* 0.5 i)) 40.0 #:hp 125.0))
            (for/list ([i (in-range 2)])  (mk-u (+ 1230 i) 'siege-tank (+ 56.0 (* 1.0 i)) 40.0 #:hp 175.0))))

  ;; T1a: SCV carrying ability 318 activates 400M reserve, sets pending CC count (+1 => 4),
  ;; and prevents duplicate expand dispatch!
  (define rt1 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts1
    (step-layer2-economy!
     rt1
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10000
                  #:minerals 460 #:gas 150 #:supply-used 76 #:supply-cap 110 #:army-supply 26
                  #:mineral-harvesters 44 #:vespene-harvesters 6
                  #:ally-buildings t-bldgs-3b
                  #:ally-units (append (list scv-walking)
                                       (mk-workers 'scv 47 1100 32.0 32.0)
                                       t-army-mid))))
  (define ds1 (rt-door-state rt1))
  (define dup-exp1? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts1))
  (check-test "T1a-l87-terran-cc-inflight-reserve-ability-318-and-pending-count"
              (and (= (hash-ref ds1 'l87-cc-inflight-reserve-min 0) 400)
                   (eq? (hash-ref ds1 'l87-cc-walk-pending? #f) #t)
                   (= (hash-ref ds1 'l87-total-cc-count-for-brain 0) 4)
                   (not dup-exp1?))
              (format "res=~a pend=~a brainCC=~a dupExp=~a"
                      (hash-ref ds1 'l87-cc-inflight-reserve-min 0)
                      (hash-ref ds1 'l87-cc-walk-pending? #f)
                      (hash-ref ds1 'l87-total-cc-count-for-brain 0)
                      dup-exp1?))

  ;; T1b: Recent CC issue 224f walk window holds 400M reserve even without ability 318 visible,
  ;; clears immediately on 4th CC start (build-progress 0.05), AND clears after > 224f expiry!
  (define rt2 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-wall-state rt2) 'l87-cc-issue-frame 10000)
  (hash-set! (rt-wall-state rt2) 'l87-cc-issue-base-cnt 3)
  (step-layer2-economy!
   rt2
   (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10120
                #:minerals 460 #:gas 150 #:supply-used 76 #:supply-cap 110 #:army-supply 26
                #:mineral-harvesters 44 #:vespene-harvesters 6
                #:ally-buildings t-bldgs-3b
                #:ally-units (append (mk-workers 'scv 48 1100 32.0 32.0) t-army-mid)))
  (define mid-res (hash-ref (rt-door-state rt2) 'l87-cc-inflight-reserve-min 0))
  (define mid-pend? (hash-ref (rt-door-state rt2) 'l87-cc-walk-pending? #f))
  ;; Real 4th CC begins construction -> clears immediately!
  (step-layer2-economy!
   rt2
   (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10140
                #:minerals 460 #:gas 150 #:supply-used 76 #:supply-cap 110 #:army-supply 26
                #:mineral-harvesters 44 #:vespene-harvesters 6
                #:ally-buildings (cons (mk-u 1099 'command-center 32.0 66.0 #:hp 150.0 #:build-progress 0.05)
                                       t-bldgs-3b)
                #:ally-units (append (mk-workers 'scv 48 1100 32.0 32.0) t-army-mid)))
  (define cleared-start-res (hash-ref (rt-door-state rt2) 'l87-cc-inflight-reserve-min -1))
  (define cleared-start-pend? (hash-ref (rt-door-state rt2) 'l87-cc-walk-pending? #t))
  ;; Separate runtime: 224f walk timeout expires at +225f!
  (define rt2b (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-wall-state rt2b) 'l87-cc-issue-frame 10000)
  (hash-set! (rt-wall-state rt2b) 'l87-cc-issue-base-cnt 3)
  (step-layer2-economy!
   rt2b
   (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10225
                #:minerals 460 #:gas 150 #:supply-used 76 #:supply-cap 110 #:army-supply 26
                #:mineral-harvesters 44 #:vespene-harvesters 6
                #:ally-buildings t-bldgs-3b
                #:ally-units (append (mk-workers 'scv 48 1100 32.0 32.0) t-army-mid)))
  (define expired-res (hash-ref (rt-door-state rt2b) 'l87-cc-inflight-reserve-min -1))
  (check-test "T1b-l87-terran-cc-224f-walk-window-clears-on-start-and-expiry"
              (and (= mid-res 400)
                   (eq? mid-pend? #t)
                   (= cleared-start-res 0)
                   (eq? cleared-start-pend? #f)
                   (= expired-res 0))
              (format "midRes=~a midPend=~a clrRes=~a clrPend=~a expRes=~a"
                      mid-res mid-pend? cleared-start-res cleared-start-pend? expired-res))

  ;; T1c: Under heavy base attack (enemy threat > max(6, army)), 400M walk reserve releases to 0!
  (define rt3 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define heavy-attackers
    (for/list ([i (in-range 14)])
      (mk-u (+ 1900 i) 'stalker (+ 35.0 (* 0.3 i)) 34.0 #:hp 80.0 #:shield 80.0)))
  (step-layer2-economy!
   rt3
   (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 10000
                #:minerals 460 #:gas 150 #:supply-used 60 #:supply-cap 110 #:army-supply 6
                #:mineral-harvesters 44 #:vespene-harvesters 6
                #:ally-buildings t-bldgs-3b
                #:ally-units (append (list scv-walking)
                                     (mk-workers 'scv 47 1100 32.0 32.0)
                                     (for/list ([i (in-range 6)])
                                       (mk-u (+ 1250 i) 'marine (+ 34.0 (* 0.2 i)) 32.0 #:hp 45.0)))
                #:enemy-units heavy-attackers))
  (define attack-res (hash-ref (rt-door-state rt3) 'l87-cc-inflight-reserve-min -1))
  (check-test "T1c-l87-terran-cc-walk-reserve-releases-under-heavy-base-attack"
              (= attack-res 0)
              (format "attackRes=~a" attack-res)))

;; ---------------------------------------------------------------------------
;; T2: Brain-Scheduled Terran 4th CC at 48 SCVs & In-Base Fallback when Camped
;; ---------------------------------------------------------------------------
(let ()
  (define t-bldgs-3b
    (list (mk-u 2001 'orbital-command 32.0 32.0 #:hp 1500.0 #:order-count 1)
          (mk-u 2002 'orbital-command 56.0 32.0 #:hp 1500.0 #:order-count 1)
          (mk-u 2003 'orbital-command 80.0 34.0 #:hp 1500.0 #:order-count 1)
          (mk-u 2004 'barracks 42.0 34.0 #:hp 1000.0 #:order-count 1)
          (mk-u 2005 'barracks 42.0 38.0 #:hp 1000.0 #:order-count 1)
          (mk-u 2006 'barracks 42.0 42.0 #:hp 1000.0 #:order-count 1)
          (mk-u 2007 'factory 46.0 34.0 #:hp 1250.0 #:order-count 1)
          (mk-u 2008 'starport 46.0 38.0 #:hp 1300.0 #:order-count 1)
          (mk-u 2009 'engineering-bay 38.0 38.0 #:hp 850.0 #:order-count 1)
          (mk-u 2010 'supply-depot 38.0 30.0 #:hp 400.0)
          (mk-u 2011 'supply-depot 38.0 32.0 #:hp 400.0)
          (mk-u 2012 'refinery 28.0 36.0 #:hp 500.0)
          (mk-u 2013 'refinery 52.0 36.0 #:hp 500.0)))
  (define t-army
    (append (for/list ([i (in-range 16)]) (mk-u (+ 2200 i) 'marine (+ 60.0 (* 0.3 i)) 38.0 #:hp 45.0))
            (for/list ([i (in-range 4)])  (mk-u (+ 2230 i) 'marauder (+ 62.0 (* 0.4 i)) 40.0 #:hp 125.0))
            (for/list ([i (in-range 3)])  (mk-u (+ 2240 i) 'siege-tank (+ 58.0 (* 1.0 i)) 40.0 #:hp 175.0))
            (for/list ([i (in-range 2)])  (mk-u (+ 2250 i) 'medivac (+ 58.0 (* 1.0 i)) 39.0 #:hp 150.0 #:flying #t))))

  ;; T2a: 3 OCs, 48 SCVs (< 64 SCV floor!), frame 11500, 460M -> emits 4th CC expand!
  (define rt-4cc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-4cc
    (step-layer2-economy!
     rt-4cc
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 11500
                  #:minerals 460 #:gas 180 #:supply-used 86 #:supply-cap 126 #:army-supply 37
                  #:mineral-harvesters 42 #:vespene-harvesters 6
                  #:ally-buildings t-bldgs-3b
                  #:ally-units (append (mk-workers 'scv 48 2100 32.0 32.0) t-army)
                  #:enemy-buildings (list (mk-u 2901 'nexus 158.0 158.0 #:hp 1000.0)
                                          (mk-u 2902 'nexus 134.0 136.0 #:hp 1000.0)
                                          (mk-u 2903 'nexus 110.0 136.0 #:hp 1000.0)))))
  (define emitted-4cc-exp?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) acts-4cc))
  (check-test "T2a-l87-terran-4th-cc-emits-at-48-scvs-bypassing-64-scv-trap"
              emitted-4cc-exp?
              (format "acts=~s" (filter (lambda (a) (and (pair? a) (memq (car a) '(expand build)))) acts-4cc)))

  ;; T2b: Same 3-base Terran at 48 SCVs & 480M (>= 450M) with ALL outer pads camped -> in-base CC!
  (define rt-4cc-inbase (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define pad-campers
    (list (mk-u 2951 'siege-tank-sieged 32.0 66.0 #:hp 175.0)
          (mk-u 2952 'marine 33.0 66.0 #:hp 45.0)
          (mk-u 2953 'marine 34.0 66.0 #:hp 45.0)
          (mk-u 2954 'siege-tank-sieged 56.0 86.0 #:hp 175.0)
          (mk-u 2955 'marine 57.0 86.0 #:hp 45.0)
          (mk-u 2956 'marine 58.0 86.0 #:hp 45.0)))
  (define acts-inbase
    (step-layer2-economy!
     rt-4cc-inbase
     (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 11500
                  #:minerals 480 #:gas 180 #:supply-used 86 #:supply-cap 126 #:army-supply 37
                  #:mineral-harvesters 42 #:vespene-harvesters 6
                  #:ally-buildings t-bldgs-3b
                  #:ally-units (append (mk-workers 'scv 48 2100 32.0 32.0) t-army)
                  #:enemy-units pad-campers
                  #:enemy-buildings (list (mk-u 2901 'command-center 158.0 158.0 #:hp 1500.0)
                                          (mk-u 2902 'command-center 134.0 136.0 #:hp 1500.0)))))
  (define emitted-inbase-cc?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'command-center))) acts-inbase))
  (check-test "T2b-l87-terran-4th-cc-in-base-fallback-when-pads-camped"
              emitted-inbase-cc?
              (format "acts=~s" (filter (lambda (a) (and (pair? a) (memq (car a) '(expand build)))) acts-inbase))))

;; ---------------------------------------------------------------------------
;; T3: Protoss Doorway-Corridor Permanence (1.15 past 4800f) & 134f SB Stall
;; ---------------------------------------------------------------------------
(let ()
  ;; T3a: doorway-corridor has half-w/half-h >= 1.15 AND persists past frame 4800 even when
  ;; bypass-wall-pylon? would otherwise be set!
  (define rt-pdoor (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define pkey (list 32.0 32.0 56.0 32.0 'Zerg 'Zerg #f 158.0 158.0 (eq-hash-code #f)))
  (define wall-map
    (hasheq 'pylon (cons 50.0 34.0)
            'slot-1 (cons 53.5 31.5)
            'slot-2 (cons 53.5 34.5)
            'slot-3 (cons 53.5 37.5)
            'door (cons 51.5 36.0)
            'door-park (cons 50.0 36.0)))
  (hash-set! (rt-wall-state rt-pdoor) 'cached-protoss-wall (cons pkey wall-map))
  (define res-pdoor
    (step-live-bot-runtime!
     rt-pdoor
     (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6500
                  #:minerals 400 #:gas 100 #:supply-used 60 #:supply-cap 60 #:army-supply 18
                  #:mineral-harvesters 36 #:vespene-harvesters 6
                  #:ally-buildings (list (mk-u 3001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 3002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 3003 'gateway 53.5 31.5 #:hp 500.0 #:shield 500.0)
                                         (mk-u 3004 'cybernetics-core 53.5 34.5 #:hp 550.0 #:shield 550.0))
                  #:ally-units (mk-workers 'probe 36 3100 32.0 32.0))))
  (define aabbs (hash-ref res-pdoor 'wall-reserved-aabbs '()))
  (define door-aabbs
    (filter (lambda (r) (and (reserved-aabb? r) (eq? (reserved-aabb-kind r) 'doorway-corridor))) aabbs))
  (define door-wide-and-persistent?
    (and (= (length door-aabbs) 2)
         (for/and ([r (in-list door-aabbs)])
           (and (>= (reserved-aabb-half-w r) 1.15)
                (>= (reserved-aabb-half-h r) 1.15)))))
  (check-test "T3a-l87-protoss-doorway-corridor-1.15-persists-past-frame-4800"
              door-wide-and-persistent?
              (format "doorCount=~a dims=~s"
                      (length door-aabbs)
                      (map (lambda (r) (list (reserved-aabb-half-w r) (reserved-aabb-half-h r))) door-aabbs)))

  ;; T3b: Protoss supply-block stall recovery triggers at 134f (6s < old 179f) forcing safe in-main Pylon!
  (define rt-psb (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-bldgs-sb
    (list (mk-u 3201 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 3202 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 3203 'pylon 50.0 32.0 #:hp 200.0 #:shield 200.0)
          (mk-u 3204 'gateway 53.0 31.0 #:hp 500.0 #:shield 500.0)
          (mk-u 3205 'cybernetics-core 53.0 34.0 #:hp 550.0 #:shield 550.0)))
  ;; Tick 1 (f=7000): starts supply-block timer (supply-left = 0, minerals = 40 so no Pylon yet)
  (step-layer2-economy!
   rt-psb
   (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7000
                #:minerals 40 #:gas 0 #:supply-used 46 #:supply-cap 46 #:army-supply 12
                #:ally-buildings p-bldgs-sb
                #:ally-units (mk-workers 'probe 30 3300 32.0 32.0)
                #:enemy-units (list (mk-u 3901 'marine 62.0 32.0 #:hp 45.0)
                                    (mk-u 3902 'marine 62.5 33.0 #:hp 45.0))))
  ;; Tick 2 (f=7134, +134f = 6s!): supply-block stall triggers -> safe in-main Pylon (<= 14t of Main Nexus)!
  (define acts-sb
    (step-layer2-economy!
     rt-psb
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7134
                  #:minerals 200 #:gas 0 #:supply-used 46 #:supply-cap 46 #:army-supply 12
                  #:ally-buildings p-bldgs-sb
                  #:ally-units (mk-workers 'probe 30 3300 32.0 32.0)
                  #:enemy-units (list (mk-u 3901 'marine 62.0 32.0 #:hp 45.0)
                                      (mk-u 3902 'marine 62.5 33.0 #:hp 45.0)))))
  (define pylon-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-sb))
  (define pylon-in-main?
    (and pylon-act (<= (dist2d (third pylon-act) (fourth pylon-act) 32.0 32.0) 14.5)))
  (check-test "T3b-l87-protoss-sb-stalled-triggers-at-134f-6s-safe-in-main-pylon"
              pylon-in-main?
              (format "pylonAct=~s dMain=~a"
                      pylon-act
                      (and pylon-act (dist2d (third pylon-act) (fourth pylon-act) 32.0 32.0)))))

;; ---------------------------------------------------------------------------
;; T4: Local-PF Tank-Shell Commit-Fire, Home Muster 1100/0.72x, Winning-Protoss
;;     l35/l36 Exemption, & Hardened Home Observer Anchor (<= 6.5t)
;; ---------------------------------------------------------------------------
(let ()
  ;; T4a: Distant enemy PF (> 40t away) does NOT disable Tank-shell-zone commit-fire!
  (define rt-pf (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define stalkers-6
    (for/list ([i (in-range 6)])
      (mk-u (+ 4100 i) 'stalker 88.0 (+ 88.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define enemy-tank-and-distant-pf
    (list (mk-u 4201 'siege-tank-sieged 98.5 89.0 #:hp 175.0)
          (mk-u 4202 'siege-tank-sieged 99.5 91.0 #:hp 175.0)))
  (define distant-pf-bldg
    (list (mk-u 4290 'planetary-fortress 150.0 150.0 #:hp 1500.0)
          (mk-u 4291 'command-center 158.0 158.0 #:hp 1500.0)))
  (define acts-pf
    (run-l34 rt-pf
             (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 9000
                          #:minerals 200 #:gas 100 #:supply-used 60 #:supply-cap 80 #:army-supply 12
                          #:ally-buildings (list (mk-u 4001 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                 (mk-u 4002 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0))
                          #:ally-units stalkers-6
                          #:enemy-units enemy-tank-and-distant-pf
                          #:enemy-buildings distant-pf-bldg)))
  (define attacked-tank-despite-distant-pf?
    (ormap (lambda (a)
             (and (pair? a)
                  (memq (car a) '(attack-unit attack))
                  (member (third a) '(4201 4202))))
           acts-pf))
  (check-test "T4a-l87-distant-enemy-pf-does-not-disable-tank-shell-zone-commit-fire"
              attacked-tank-despite-distant-pf?
              (format "acts=~s" (filter (lambda (a) (and (pair? a) (memq (car a) '(attack-unit attack move kite)))) acts-pf)))

  ;; T4b: Home muster enters at 1200-val Natural push (< old 1800) and releases at 0.78x (>= 0.72, < old 0.85)!
  (define rt-hm (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-2b
    (list (mk-u 4301 'orbital-command 32.0 32.0 #:hp 1500.0)
          (mk-u 4302 'orbital-command 56.0 32.0 #:hp 1500.0)))
  ;; 7 Stalkers = 7 * 175 = 1225 val (>= 1100, < 1800) attacking Natural (56, 32) from (70, 32)!
  (define push-1225
    (for/list ([i (in-range 7)])
      (mk-u (+ 4350 i) 'stalker 70.0 (+ 30.5 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define small-def
    (list (mk-u 4310 'marine 44.0 48.0 #:hp 45.0)
          (mk-u 4311 'marine 45.0 48.0 #:hp 45.0)
          (mk-u 4312 'marine 56.0 34.0 #:hp 45.0)
          (mk-u 4313 'marine 56.0 35.0 #:hp 45.0))) ;; 200 val << 0.80 * 1225
  (run-l34 rt-hm
           (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 7000
                        #:supply-used 44 #:supply-cap 70 #:army-supply 4
                        #:ally-buildings t-2b #:ally-units small-def #:enemy-units push-1225))
  (define hm-entered? (and (hash-ref (rt-door-state rt-hm) 'l64-def-muster-active? #f) #t))
  ;; Reinforce to 19 Marines = 950 val (950 / 1225 = 0.775 >= 0.72, < old 0.85/0.88) -> releases!
  (define mid-reinf
    (for/list ([i (in-range 19)])
      (mk-u (+ 4370 i) 'marine 44.0 (+ 28.0 (* 0.4 i)) #:hp 45.0)))
  (run-l34 rt-hm
           (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 7024
                        #:supply-used 64 #:supply-cap 80 #:army-supply 19
                        #:ally-buildings t-2b #:ally-units mid-reinf #:enemy-units push-1225))
  (define hm-released-at-077x? (not (hash-ref (rt-door-state rt-hm) 'l64-def-muster-active? #f)))
  (check-test "T4b-l87-home-muster-enters-at-1225-val-and-releases-at-0.775x"
              (and hm-entered? hm-released-at-077x?)
              (format "entered=~a released077x=~a" hm-entered? hm-released-at-077x?))

  ;; T4c: Winning Protoss (>= 1.35x army val AND >= 2 Immortals/Colossi) exempt from l35/l36 mass-hold!
  (define rt-pwin (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-win-army
    (append (list (mk-u 4501 'immortal 95.0 95.0 #:hp 200.0 #:shield 100.0)
                  (mk-u 4502 'immortal 96.0 96.0 #:hp 200.0 #:shield 100.0)
                  (mk-u 4503 'colossus 94.0 96.0 #:hp 200.0 #:shield 150.0))
            (for/list ([i (in-range 8)])
              (mk-u (+ 4510 i) 'stalker (+ 95.0 (* 0.4 i)) 94.0 #:hp 80.0 #:shield 80.0))))
  ;; 2 Immortals (750) + 1 Colossus (500) + 8 Stalkers (1400) = 2650 val (~30 sup < 36 l35 floor!)
  ;; vs 3 enemy Siege Tanks (825 val, 9 sup) -> 2650 >= 1.35 * 825 -> MUST NOT mass-hold!
  (define e-3tanks
    (list (mk-u 4591 'siege-tank-sieged 140.0 140.0 #:hp 175.0)
          (mk-u 4592 'siege-tank-sieged 142.0 140.0 #:hp 175.0)
          (mk-u 4593 'siege-tank-sieged 144.0 140.0 #:hp 175.0)))
  (define res-pwin
    (step-live-bot-runtime!
     rt-pwin
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 8500
                  #:supply-used 72 #:supply-cap 94 #:army-supply 30
                  #:ally-buildings (list (mk-u 4401 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                         (mk-u 4402 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0))
                  #:ally-units p-win-army
                  #:enemy-units e-3tanks
                  #:enemy-buildings (list (mk-u 4599 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define pwin-tel (hash-ref res-pwin 'telemetry (hasheq)))
  (define pwin-suppressed? (hash-ref pwin-tel 'combat-suppress-attack? #f))
  (check-test "T4c-l87-winning-protoss-heavy-robo-exempt-from-l35-l36-mass-hold"
              (not pwin-suppressed?)
              (format "suppress=~a" pwin-suppressed?))

  ;; T4d: Home Observer anchors within <= 6.5t of cloaked Banshee & Dark Templar even when
  ;; home AA Stalkers are 9.0t away (instead of drifting to 10.5t on the 11.0t detection edge!)
  (define rt-obs-b (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define stalkers-far
    (for/list ([i (in-range 5)])
      (mk-u (+ 4610 i) 'stalker 30.0 (+ 31.0 (* 0.5 i)) #:hp 80.0 #:shield 80.0)))
  (define obs-far (mk-u 4650 'observer 27.5 32.0 #:hp 40.0 #:shield 20.0 #:flying #t))
  (define cloaked-banshee (mk-u 4680 'banshee 39.0 32.0 #:hp 140.0 #:flying #t #:cloak 1))
  (define acts-obs-b
    (run-l34 rt-obs-b
             (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7200
                          #:supply-used 42 #:supply-cap 54 #:army-supply 11
                          #:ally-buildings (list (mk-u 4601 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0))
                          #:ally-units (cons obs-far stalkers-far)
                          #:enemy-units (list cloaked-banshee))))
  (define (find-unit-move acts uid)
    (findf (lambda (a)
             (and (pair? a) (eq? (car a) 'move)
                  (or (equal? (second a) uid)
                      (and (list? (second a)) (memv uid (second a))))))
           acts))
  (define obs-b-move (find-unit-move acts-obs-b 4650))
  (define obs-b-dist (and obs-b-move (dist2d (third obs-b-move) (fourth obs-b-move) 39.0 32.0)))

  (define rt-obs-dt (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define cloaked-dt (mk-u 4681 'dark-templar 39.0 32.0 #:hp 40.0 #:shield 80.0 #:cloak 1))
  (define acts-obs-dt
    (run-l34 rt-obs-dt
             (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 7200
                          #:supply-used 42 #:supply-cap 54 #:army-supply 11
                          #:ally-buildings (list (mk-u 4602 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0))
                          #:ally-units (cons obs-far stalkers-far)
                          #:enemy-units (list cloaked-dt))))
  (define obs-dt-move (find-unit-move acts-obs-dt 4650))
  (define obs-dt-dist (and obs-dt-move (dist2d (third obs-dt-move) (fourth obs-dt-move) 39.0 32.0)))
  (check-test "T4d-l87-home-observer-anchors-within-6.5t-of-banshee-and-dt"
              (and obs-b-move (<= obs-b-dist 6.5)
                   obs-dt-move (<= obs-dt-dist 6.5))
              (format "bansheeMove=~s dB=~a dtMove=~s dDT=~a"
                      obs-b-move obs-b-dist obs-dt-move obs-dt-dist)))

;; ---------------------------------------------------------------------------
;; T5: Terran SCV Behind-TH Geyser Sweep & TvT 17-Scout + Zerg OV1 Side Arc
;; ---------------------------------------------------------------------------
(let ()
  ;; T5a-1: Terran SCV near enemy natural at f=1650 (1568..3360, earlier than old 1904)
  ;; sweeps strictly BEHIND enemy TownHall: dot(wp - enemy, enemy->nat) < 0!
  (define rt-scv (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-scout-state rt-scv) 'scout-id 5101)
  (hash-set! (rt-scout-state rt-scv) 'dispatched? #t)
  (define scv-near-enat (mk-u 5101 'scv 138.0 140.0 #:hp 45.0))
  (define acts-scv-sweep
    (step-layer2-economy!
     rt-scv
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 1650
                  #:minerals 100 #:gas 0 #:supply-used 18 #:supply-cap 23 #:army-supply 0
                  #:mineral-harvesters 15 #:vespene-harvesters 2
                  #:enemy-x 158.0 #:enemy-y 158.0 #:enemy-exp-x 134.0 #:enemy-exp-y 136.0
                  #:ally-buildings (list (mk-u 5001 'command-center 32.0 32.0 #:hp 1500.0)
                                         (mk-u 5002 'barracks 42.0 32.0 #:hp 1000.0))
                  #:ally-units (cons scv-near-enat (mk-workers 'scv 16 5102 32.0 32.0))
                  #:enemy-buildings (list (mk-u 5901 'nexus 158.0 158.0 #:hp 1000.0)))))
  (define sweep-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout) (= (second a) 5101))) acts-scv-sweep))
  (define sweep-dot
    (and sweep-act
         (+ (* (- (third sweep-act) 158.0) (- 134.0 158.0))
            (* (- (fourth sweep-act) 158.0) (- 136.0 158.0)))))
  ;; T5a-2: Reaper-less TvT at frame 1050, supply 17 dispatches SCV scout; TvT WITH Reaper does NOT!
  (define rt-tvt-noreap (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-tvt-noreap
    (step-layer2-economy!
     rt-tvt-noreap
     (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 1050
                  #:minerals 80 #:gas 20 #:supply-used 17 #:supply-cap 23 #:army-supply 0
                  #:mineral-harvesters 14 #:vespene-harvesters 3
                  #:ally-buildings (list (mk-u 5201 'command-center 32.0 32.0 #:hp 1500.0)
                                         (mk-u 5202 'supply-depot 38.0 32.0 #:hp 400.0)
                                         (mk-u 5203 'barracks 42.0 32.0 #:hp 1000.0))
                  #:ally-units (mk-workers 'scv 17 5210 32.0 32.0))))
  (define tvt-noreap-dispatched?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout))) acts-tvt-noreap))
  (define rt-tvt-reap (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-tvt-reap
    (step-layer2-economy!
     rt-tvt-reap
     (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 1050
                  #:minerals 80 #:gas 20 #:supply-used 18 #:supply-cap 23 #:army-supply 1
                  #:mineral-harvesters 14 #:vespene-harvesters 3
                  #:ally-buildings (list (mk-u 5251 'command-center 32.0 32.0 #:hp 1500.0)
                                         (mk-u 5252 'supply-depot 38.0 32.0 #:hp 400.0)
                                         (mk-u 5253 'barracks 42.0 32.0 #:hp 1000.0
                                               #:orders (list (hasheq 'ability-id 561))))
                  #:ally-units (mk-workers 'scv 17 5260 32.0 32.0))))
  (define tvt-reap-skipped?
    (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout))) acts-tvt-reap)))
  (check-test "T5a-l87-terran-scv-behind-th-geyser-sweep-and-reaperless-tvt-scout"
              (and sweep-act (< sweep-dot 0.0)
                   tvt-noreap-dispatched?
                   tvt-reap-skipped?)
              (format "sweep=~s dot=~a tvtNoReap=~a tvtReapSkip=~a"
                      sweep-act sweep-dot tvt-noreap-dispatched? tvt-reap-skipped?))

  ;; T5b: Zerg OV1 side-flank geyser arc fires at f=1850 (1792..3360), brings back-wall geyser
  ;; strictly inside 11.0t Overlord sight radius, alternates side if still 0 geysers, and
  ;; immediately aborts & kites home when enemy AA enters 14.0t!
  (define rt-ov (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-bldgs
    (list (mk-u 5801 'hatchery 32.0 32.0 #:hp 1500.0)
          (mk-u 5802 'hatchery 56.0 32.0 #:hp 1500.0)))
  (define ov1-start (mk-u 5831 'overlord 136.0 138.0 #:hp 200.0 #:max-hp 200.0 #:flying #t))
  (define acts-ov1
    (step-layer2-economy!
     rt-ov
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 1850
                  #:minerals 120 #:gas 0 #:supply-used 20 #:supply-cap 28 #:army-supply 0
                  #:mineral-harvesters 18 #:vespene-harvesters 0
                  #:enemy-x 158.0 #:enemy-y 158.0 #:enemy-exp-x 134.0 #:enemy-exp-y 136.0
                  #:ally-buildings z-bldgs
                  #:ally-units (cons ov1-start (mk-workers 'drone 18 5840 32.0 32.0))
                  #:enemy-buildings (list (mk-u 5991 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define ov1-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'overlord-scout) (= (second a) 5831))) acts-ov1))
  ;; Back-wall geyser on that side is at enemy - 3.0*u + 6.5*p
  (define ux-en (/ (- 134.0 158.0) (dist2d 158.0 158.0 134.0 136.0)))
  (define uy-en (/ (- 136.0 158.0) (dist2d 158.0 158.0 134.0 136.0)))
  (define px-en (- uy-en))
  (define py-en ux-en)
  (define back-geyser-x (+ 158.0 (* -3.0 ux-en) (* 6.5 px-en)))
  (define back-geyser-y (+ 158.0 (* -3.0 uy-en) (* 6.5 py-en)))
  (define d-peek-to-geyser
    (and ov1-act (dist2d (third ov1-act) (fourth ov1-act) back-geyser-x back-geyser-y)))
  ;; Tick 2 (f=1900): OV1 arrives at side-1 target with 0 geysers -> alternates to opposite side!
  (define ov1-at-side1
    (mk-u 5831 'overlord (if ov1-act (third ov1-act) 148.0) (if ov1-act (fourth ov1-act) 156.0)
          #:hp 200.0 #:max-hp 200.0 #:flying #t))
  (define acts-ov2
    (step-layer2-economy!
     rt-ov
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 1900
                  #:minerals 140 #:gas 0 #:supply-used 20 #:supply-cap 28 #:army-supply 0
                  #:mineral-harvesters 18 #:vespene-harvesters 0
                  #:enemy-x 158.0 #:enemy-y 158.0 #:enemy-exp-x 134.0 #:enemy-exp-y 136.0
                  #:ally-buildings z-bldgs
                  #:ally-units (cons ov1-at-side1 (mk-workers 'drone 18 5840 32.0 32.0))
                  #:enemy-buildings (list (mk-u 5991 'command-center 158.0 158.0 #:hp 1500.0)))))
  (define ov2-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'overlord-scout) (= (second a) 5831))) acts-ov2))
  (define alternated-side?
    (and ov1-act ov2-act
         (> (dist2d (third ov1-act) (fourth ov1-act) (third ov2-act) (fourth ov2-act)) 10.0)))
  ;; Tick 3 (f=1924): Marine appears 10t away (< 14.0t) -> instant abort & kite home!
  (define acts-ov-abort
    (step-layer2-economy!
     rt-ov
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 1924
                  #:minerals 160 #:gas 0 #:supply-used 20 #:supply-cap 28 #:army-supply 0
                  #:mineral-harvesters 18 #:vespene-harvesters 0
                  #:enemy-x 158.0 #:enemy-y 158.0 #:enemy-exp-x 134.0 #:enemy-exp-y 136.0
                  #:ally-buildings z-bldgs
                  #:ally-units (cons ov1-at-side1 (mk-workers 'drone 18 5840 32.0 32.0))
                  #:enemy-buildings (list (mk-u 5991 'command-center 158.0 158.0 #:hp 1500.0))
                  #:enemy-units (list (mk-u 5995 'marine 152.0 152.0 #:hp 45.0)))))
  (define ov-kite
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 5831))) acts-ov-abort))
  (check-test "T5b-l87-zerg-ov1-side-flank-arc-1792-alternates-and-14t-aa-aborts"
              (and ov1-act
                   (<= d-peek-to-geyser 11.0)
                   alternated-side?
                   ov-kite)
              (format "ov1=~s dGeyser=~a ov2=~s alt=~a kite=~s"
                      ov1-act d-peek-to-geyser ov2-act alternated-side? ov-kite)))

;; ---------------------------------------------------------------------------
;; T6: APM Cap 500 & [SCBOT_OWM] 448f Live Telemetry Emission Hook
;; ---------------------------------------------------------------------------
(let ()
  (define rt-owm (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define obs-f1344
    (hash-set
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 1344
                  #:minerals 200 #:gas 60 #:supply-used 24 #:supply-cap 31 #:army-supply 4
                  #:mineral-harvesters 18 #:vespene-harvesters 3
                  #:ally-buildings (list (mk-u 6001 'orbital-command 32.0 32.0 #:hp 1500.0)
                                         (mk-u 6002 'barracks 42.0 32.0 #:hp 1000.0))
                  #:ally-units (mk-workers 'scv 20 6010 32.0 32.0)
                  #:enemy-buildings (list (mk-u 6901 'nexus 158.0 158.0 #:hp 1000.0)
                                          (mk-u 6902 'assimilator 154.0 162.0 #:hp 300.0)
                                          (mk-u 6903 'gateway 144.0 144.0 #:hp 500.0))
                  #:enemy-units (list (mk-u 6910 'stalker 142.0 142.0 #:hp 80.0 #:shield 80.0)))
     'enable-opponent-world-model #t))
  (define err-buf (open-output-string))
  (define res-1
    (parameterize ([current-error-port err-buf])
      (step-live-bot-runtime! rt-owm obs-f1344)))
  (define owm-l1 (hash-ref (hash-ref res-1 'telemetry (hasheq)) 'owm-belief-log-line ""))
  (define apm-cmd
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'human-apm-discipline)))
           (hash-ref res-1 'actions '())))
  ;; Step +100f (< 448f): must NOT emit again (0 step-time impact between intervals!)
  (define res-2
    (parameterize ([current-error-port err-buf])
      (step-live-bot-runtime! rt-owm (hash-set obs-f1344 'frame 1444))))
  (define owm-l2 (hash-ref (hash-ref res-2 'telemetry (hasheq)) 'owm-belief-log-line ""))
  ;; Step +448f (= 1792): MUST emit again with live non-zero prod/units!
  (define res-3
    (parameterize ([current-error-port err-buf])
      (step-live-bot-runtime! rt-owm (hash-set obs-f1344 'frame 1792))))
  (define owm-l3 (hash-ref (hash-ref res-3 'telemetry (hasheq)) 'owm-belief-log-line ""))
  (define stderr-str (get-output-string err-buf))
  (check-test "T6-l87-scbot-owm-448f-live-emission-and-apm-500-ceiling"
              (and (string-prefix? owm-l1 "[SCBOT_OWM] f=1344 ")
                   (string-contains? owm-l1 "prod=(gateway:1)")
                   (string-contains? owm-l1 "units=(stalker:1)")
                   (string=? owm-l2 "")
                   (string-prefix? owm-l3 "[SCBOT_OWM] f=1792 ")
                   (string-contains? stderr-str "[SCBOT_OWM] f=1344 ")
                   (string-contains? stderr-str "[SCBOT_OWM] f=1792 ")
                   (or (not apm-cmd) (<= (second apm-cmd) 500)))
              (format "l1=~s l2=~s l3=~s apm=~s" owm-l1 owm-l2 owm-l3 apm-cmd)))

;; ---------------------------------------------------------------------------
;; T7 (Loop 87B Track D): Exact 2-Waypoint Geyser Sweep (Terran SCV + Zerg OV1)
;;                        & Cortex 760-EPM Headroom Alignment with Track C
;; ---------------------------------------------------------------------------
(let ()
  ;; Asymmetric enemy main layout (both geysers on +X side of enemy main TH at (42, 40),
  ;; with enemy natural North at (40.5, 69.5))!
  (define asym-geysers
    (list (hash 'id 7901 'type 'vespene-geyser 'x 49.0 'y 37.0 'vespene-contents 2250)
          (hash 'id 7902 'type 'vespene-geyser 'x 46.0 'y 33.0 'vespene-contents 2250)))

  ;; T7a: Terran SCV routes directly to open-ground approach of geyser #1 (<= 3t from geyser #1),
  ;; advances cleanly to geyser #2 upon arrival (<= 3t from geyser #2), latches swept on geyser #2
  ;; arrival, and never freezes (160f timeout also advances if blocked)!
  (define rt-t2wp (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-scout-state rt-t2wp) 'scout-id 7101)
  (hash-set! (rt-scout-state rt-t2wp) 'dispatched? #t)
  (define (mk-t2wp-obs f sx sy)
    (hash-set
     (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame f
                  #:minerals 120 #:gas 20 #:supply-used 18 #:supply-cap 23 #:army-supply 0
                  #:mineral-harvesters 15 #:vespene-harvesters 2
                  #:base-x 155.0 #:base-y 133.0 #:nat-x 157.0 #:nat-y 104.0
                  #:enemy-x 42.0 #:enemy-y 40.0 #:enemy-exp-x 40.5 #:enemy-exp-y 69.5
                  #:ally-buildings (list (mk-u 7001 'command-center 155.0 133.0 #:hp 1500.0)
                                         (mk-u 7002 'barracks 148.0 128.0 #:hp 1000.0))
                  #:ally-units (cons (mk-u 7101 'scv sx sy #:hp 45.0)
                                     (mk-workers 'scv 16 7102 155.0 133.0))
                  #:enemy-buildings (list (mk-u 7951 'command-center 42.0 40.0 #:hp 1500.0)))
     'geysers asym-geysers))
  (define acts-wp1 (step-layer2-economy! rt-t2wp (mk-t2wp-obs 1450 42.0 60.0)))
  (define wp1-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout) (= (second a) 7101))) acts-wp1))
  (define d-wp1-g1 (and wp1-act (dist2d (third wp1-act) (fourth wp1-act) 49.0 37.0)))
  ;; SCV arrives near geyser #1 -> immediately advances to geyser #2 (46.0, 33.0)!
  (define acts-wp2 (step-layer2-economy! rt-t2wp (mk-t2wp-obs 1520 46.5 38.0)))
  (define wp2-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout) (= (second a) 7101))) acts-wp2))
  (define d-wp2-g2 (and wp2-act (dist2d (third wp2-act) (fourth wp2-act) 46.0 33.0)))
  ;; SCV arrives near geyser #2 -> completes 2-wp sweep cleanly!
  (step-layer2-economy! rt-t2wp (mk-t2wp-obs 1590 44.5 35.0))
  (define swept-done? (eq? (hash-ref (rt-scout-state rt-t2wp) 'l87b-geyser-wp-idx #f) 'done))
  ;; Separate runtime: 160f anti-stuck timeout advances wp 0 -> 1 even if SCV never reaches wp 0!
  (define rt-t-to (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-scout-state rt-t-to) 'scout-id 7101)
  (hash-set! (rt-scout-state rt-t-to) 'dispatched? #t)
  (step-layer2-economy! rt-t-to (mk-t2wp-obs 1450 42.0 60.0))
  (step-layer2-economy! rt-t-to (mk-t2wp-obs 1615 42.0 60.0))
  (define timeout-advanced? (equal? (hash-ref (rt-scout-state rt-t-to) 'l87b-geyser-wp-idx 0) 1))
  (check-test "T7a-l87b-terran-scv-2wp-exact-geyser-sweep-advances-and-never-freezes"
              (and wp1-act (<= d-wp1-g1 3.0)
                   wp2-act (<= d-wp2-g2 3.0)
                   swept-done?
                   timeout-advanced?)
              (format "wp1=~s dG1=~a wp2=~s dG2=~a done=~a toAdv=~a"
                      wp1-act d-wp1-g1 wp2-act d-wp2-g2 swept-done? timeout-advanced?))

  ;; T7b: Zerg OV1 on long map (f=2850 > 2800, 18t from enemy natural) does NOT prematurely recall
  ;; at 2800f, peeks within <= 8.0t of exact enemy main geyser #1 (inside 11.0t sight), alternates
  ;; to geyser #2 upon arrival, and immediately aborts & kites home when AA enters 14.0t!
  (define rt-ov2 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (hash-set! (rt-scout-state rt-ov2) 'opening-overlord-ids '(7831))
  (define (mk-ov2-obs f ox oy [eu '()])
    (hash-set
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame f
                  #:minerals 140 #:gas 20 #:supply-used 24 #:supply-cap 28 #:army-supply 0
                  #:mineral-harvesters 20 #:vespene-harvesters 2
                  #:base-x 155.0 #:base-y 133.0 #:nat-x 157.0 #:nat-y 104.0
                  #:enemy-x 42.0 #:enemy-y 40.0 #:enemy-exp-x 40.5 #:enemy-exp-y 69.5
                  #:ally-buildings (list (mk-u 7801 'hatchery 155.0 133.0 #:hp 1500.0)
                                         (mk-u 7802 'hatchery 157.0 104.0 #:hp 1500.0))
                  #:ally-units (cons (mk-u 7831 'overlord ox oy #:hp 200.0 #:max-hp 200.0 #:flying #t)
                                     (mk-workers 'drone 20 7840 155.0 133.0))
                  #:enemy-buildings (list (mk-u 7991 'command-center 42.0 40.0 #:hp 1500.0))
                  #:enemy-units eu)
     'geysers asym-geysers))
  ;; f=2850 (> old 2800 hard-abort!), OV1 is 18t from en-nat (56, 78) -> must peek geyser #1, NOT kite home!
  (define acts-ov-p1 (step-layer2-economy! rt-ov2 (mk-ov2-obs 2850 56.0 78.0)))
  (define ov-p1 (findf (lambda (a) (and (pair? a) (eq? (car a) 'overlord-scout) (= (second a) 7831))) acts-ov-p1))
  (define ov-p1-kite (findf (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 7831))) acts-ov-p1))
  (define d-ov-g1 (and ov-p1 (dist2d (third ov-p1) (fourth ov-p1) 49.0 37.0)))
  ;; OV1 arrives at edge #1 with still 0 confirmed geysers -> alternates to edge #2 (46, 33)!
  (define acts-ov-p2
    (step-layer2-economy! rt-ov2
                          (mk-ov2-obs 2920 (if ov-p1 (third ov-p1) 52.8) (if ov-p1 (fourth ov-p1) 43.5))))
  (define ov-p2 (findf (lambda (a) (and (pair? a) (eq? (car a) 'overlord-scout) (= (second a) 7831))) acts-ov-p2))
  (define d-ov-g2 (and ov-p2 (dist2d (third ov-p2) (fourth ov-p2) 46.0 33.0)))
  ;; Enemy Marine appears 9t away (< 14.0t) -> instant abort & kite home!
  (define acts-ov-ab
    (step-layer2-economy! rt-ov2
                          (mk-ov2-obs 2956 52.0 43.0 (list (mk-u 7999 'marine 46.0 40.0 #:hp 45.0)))))
  (define ov-ab-kite (findf (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 7831))) acts-ov-ab))
  (check-test "T7b-l87b-zerg-ov1-exact-geyser-edge-post-2800f-and-14t-aa-abort"
              (and ov-p1 (not ov-p1-kite) (<= d-ov-g1 8.5)
                   ov-p2 (<= d-ov-g2 8.5)
                   ov-ab-kite)
              (format "p1=~s dG1=~a kite1=~s p2=~s dG2=~a abKite=~s"
                      ov-p1 d-ov-g1 ov-p1-kite ov-p2 d-ov-g2 ov-ab-kite))

  ;; T7c: Default live-bot-runtime cortex EPM cap (>= 680) & burst tokens (>= 64) align with
  ;; Track C 680/760 fast-min (~500 SC2-UI) wire governor without choking fights!
  (define rt-apm (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define hc-apm (live-bot-runtime-cortex rt-apm))
  (check-test "T7c-l87b-cortex-epm-cap-aligned-with-track-c-apm-500"
              (and (>= (human-cortex-epm-cap hc-apm) 680)
                   (>= (human-cortex-max-tokens hc-apm) 64))
              (format "epmCap=~a maxTok=~a" (human-cortex-epm-cap hc-apm) (human-cortex-max-tokens hc-apm))))

;; ---------------------------------------------------------------------------
;; T8 (Loop 87C Track 5): Version C Pro-Execution & SCV Sweep Fixes (Items #1-#8)
;; ---------------------------------------------------------------------------
(let ()
  ;; T8a: Overlord egg dedup (1344), due? 1:19 Gateway block, Warp Prism #1 pre-pass before
  ;; Gateway #4+, Reaper <=1 cap outside proxy-reaper, Cannon Rush Zealot <=2 cap, smooth
  ;; +10 post-commit worker ramp on 2+ bases, and smooth >=450M float fallback!
  (define rt-ov-egg (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                           #:cheese-mode? #t #:cheese-profile 'zvz-13-12-ling-bane))
  (define ov-egg (mk-u 8101 'egg 30.0 32.0 #:hp 200.0 #:orders (list (hasheq 'ability-id 1344))))
  (define acts-ov-egg
    (run-l34 rt-ov-egg
             (hash-set
              (mk-live-obs #:race 'Zerg #:enemy-race 'Zerg #:frame 900
                           #:minerals 200 #:gas 0 #:supply-used 14 #:supply-cap 14 #:army-supply 0
                           #:mineral-harvesters 14 #:vespene-harvesters 0
                           #:ally-buildings (list (mk-u 8001 'hatchery 32.0 32.0 #:hp 1500.0)
                                                  (mk-u 8002 'spawning-pool 36.0 32.0 #:hp 1000.0))
                           #:ally-units (cons ov-egg (mk-workers 'drone 14 8010 32.0 32.0)))
              'larva-count 3)))
  (define dup-ov-trained? (ormap (lambda (a) (equal? a '(train overlord))) acts-ov-egg))

  ;; Cannon Rush at 17 supply & 79s (< 125s - 15s = 110s): Gateway MUST NOT leak at 1:19!
  (define rt-cr-due (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                           #:cheese-mode? #t #:cheese-profile 'pvz-cannon-rush))
  (define acts-cr-due
    (run-l34 rt-cr-due
             (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 1770 ;; 79.0s
                          #:minerals 220 #:gas 0 #:supply-used 17 #:supply-cap 31 #:army-supply 0
                          #:mineral-harvesters 17 #:vespene-harvesters 0
                          #:ally-buildings (list (mk-u 8020 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                 (mk-u 8021 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                                                 (mk-u 8022 'forge 38.0 34.0 #:hp 400.0 #:shield 400.0)
                                                 (mk-u 8023 'pylon 145.0 142.0 #:hp 200.0 #:shield 200.0))
                          #:ally-units (mk-workers 'probe 17 8030 32.0 32.0))))
  (define leaked-119-gw?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts-cr-due))

  ;; Warp Prism #1 pre-pass runs BEFORE Gateway #4+ steals 250M!
  (define rt-wp-pre (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                           #:cheese-mode? #t #:cheese-profile 'pvz-32p-8gate-chargelot-prism))
  (define acts-wp-pre
    (run-l34 rt-wp-pre
             (hash-set
              (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 5400 ;; 241s
                           #:minerals 260 #:gas 100 #:supply-used 42 #:supply-cap 78 #:army-supply 10
                           #:mineral-harvesters 26 #:vespene-harvesters 6
                           #:ally-buildings (list (mk-u 8040 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                  (mk-u 8041 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                  (mk-u 8042 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                                                  (mk-u 8043 'cybernetics-core 38.0 30.0 #:hp 550.0 #:shield 550.0)
                                                  (mk-u 8044 'twilight-council 38.0 34.0 #:hp 500.0 #:shield 500.0)
                                                  (mk-u 8045 'robotics-facility 40.0 34.0 #:hp 450.0 #:shield 450.0)
                                                  (mk-u 8046 'warp-gate 34.0 26.0 #:hp 500.0 #:shield 500.0)
                                                  (mk-u 8047 'warp-gate 38.0 26.0 #:hp 500.0 #:shield 500.0)
                                                  (mk-u 8048 'warp-gate 42.0 26.0 #:hp 500.0 #:shield 500.0))
                           #:ally-units (mk-workers 'probe 32 8050 32.0 32.0))
              'researched-upgrades '(warp-gate-research charge))))
  (define trained-wp-before-gw4?
    (and (ormap (lambda (a) (equal? a '(train warp-prism))) acts-wp-pre)
         (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts-wp-pre))))

  ;; Smooth post-commit +10 worker ramp on 2+ bases & state-driven Loop 87D follow-up -> fallback graduation
  (define rt-ramp-fb (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                            #:cheese-mode? #t #:cheese-profile 'zvp-19d-speedling-roach-ravager))
  (hash-set! (rt-cheese-state rt-ramp-fb) 'committed? #t)
  (define acts-post-ramp
    (run-l34 rt-ramp-fb
             (hash-set*
              (mk-live-obs #:race 'Zerg #:enemy-race 'Protoss #:frame 5152 ;; 230s (< edge-sec=295s)
                           #:minerals 250 #:gas 0 #:supply-used 40 #:supply-cap 66 #:army-supply 20
                           #:mineral-harvesters 16 #:vespene-harvesters 3
                           #:ally-buildings (list (mk-u 8060 'hatchery 32.0 32.0 #:hp 1500.0)
                                                  (mk-u 8061 'hatchery 56.0 32.0 #:hp 1500.0)
                                                  (mk-u 8062 'spawning-pool 36.0 32.0 #:hp 1000.0))
                           #:ally-units (mk-workers 'drone 19 8070 32.0 32.0))
              'larva-count 4 'researched-upgrades '(metabolic-boost))))
  (define ramped-past-cap? (ormap (lambda (a) (equal? a '(train drone))) acts-post-ramp))
  (run-l34 rt-ramp-fb
           (mk-live-obs #:race 'Zerg #:enemy-race 'Protoss #:frame 6720 ;; 300s >= edge-sec=295s & 500M >= 420M
                        #:minerals 500 #:gas 0 #:supply-used 40 #:supply-cap 66 #:army-supply 20
                        #:mineral-harvesters 16 #:vespene-harvesters 3
                        #:ally-buildings (list (mk-u 8060 'hatchery 32.0 32.0 #:hp 1500.0)
                                               (mk-u 8061 'hatchery 56.0 32.0 #:hp 1500.0))
                        #:ally-units (mk-workers 'drone 19 8070 32.0 32.0)))
  (define entered-fu-ok? (eq? (rt-cheese-phase rt-ramp-fb) 'follow-up))
  (run-l34 rt-ramp-fb
           (mk-live-obs #:race 'Zerg #:enemy-race 'Protoss #:frame 10400 ;; 464.3s >= graduate-sec=460s
                        #:minerals 500 #:gas 0 #:supply-used 40 #:supply-cap 66 #:army-supply 20
                        #:mineral-harvesters 16 #:vespene-harvesters 3
                        #:ally-buildings (list (mk-u 8060 'hatchery 32.0 32.0 #:hp 1500.0)
                                               (mk-u 8061 'hatchery 56.0 32.0 #:hp 1500.0))
                        #:ally-units (mk-workers 'drone 19 8070 32.0 32.0)))
  (define float-fb-triggered? (and entered-fu-ok? (not (cheese-mode-active? rt-ramp-fb))))
  (check-test "T8a-l87c-ov-egg-dedup-due-guard-prism-prepass-ramp-and-float-fallback"
              (and (not dup-ov-trained?)
                   (not leaked-119-gw?)
                   trained-wp-before-gw4?
                   ramped-past-cap?
                   float-fb-triggered?)
              (format "dupOv=~a gw119=~a wpPre=~a ramp=~a fu=~a floatFb=~a"
                      dup-ov-trained? leaked-119-gw? trained-wp-before-gw4? ramped-past-cap? entered-fu-ok? float-fb-triggered?))

  ;; T8b: Dedicated Version C Warp Prism controller (both 1-base & 2-base): phases in safe 12..18t
  ;; pocket, emits (warp-in ...) across ALL 8 ready Warp Gates (> old 6-cap, even at 18t > 16t!),
  ;; and holds home (train zealot) while forward Prism is phased!
  (define rt-wp2 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                        #:cheese-mode? #t #:cheese-profile 'pvz-32p-8gate-chargelot-prism))
  (define wgs-8
    (for/list ([i (in-range 8)])
      (mk-u (+ 8210 i) 'warp-gate (+ 30.0 (* 2.0 i)) 26.0 #:hp 500.0 #:shield 500.0)))
  ;; Tick 1: flying Warp Prism arrives at safe 15t pocket -> phases immediately!
  (define acts-wp-phase
    (run-l34 rt-wp2
             (hash-set
              (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6400 ;; 285.7s
                           #:minerals 900 #:gas 100 #:supply-used 52 #:supply-cap 94 #:army-supply 20
                           #:mineral-harvesters 26 #:vespene-harvesters 6
                           #:ally-buildings (append (list (mk-u 8201 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                          (mk-u 8202 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                          (mk-u 8203 'robotics-facility 40.0 34.0 #:hp 450.0 #:shield 450.0))
                                                    wgs-8)
                           #:ally-units (cons (mk-u 8250 'warp-prism 146.0 148.0 #:hp 80.0 #:shield 100.0 #:flying #t)
                                              (mk-workers 'probe 32 8260 32.0 32.0)))
              'researched-upgrades '(warp-gate-research charge))))
  (define phased-ok?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (= (second a) 8250)
                            (eq? (third a) 'morph-warp-prism-phasing)))
           acts-wp-phase))
  ;; Tick 2: phased Prism at 18t from enemy main -> emits ALL 8 (warp-in ...) & holds home (train zealot)!
  (define acts-wp-warp8
    (run-l34 rt-wp2
             (hash-set
              (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6448
                           #:minerals 900 #:gas 100 #:supply-used 52 #:supply-cap 94 #:army-supply 20
                           #:mineral-harvesters 26 #:vespene-harvesters 6
                           #:ally-buildings (append (list (mk-u 8201 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                          (mk-u 8202 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                          (mk-u 8203 'robotics-facility 40.0 34.0 #:hp 450.0 #:shield 450.0))
                                                    wgs-8)
                           #:ally-units (cons (mk-u 8250 'warp-prism-phasing 140.0 158.0 #:hp 80.0 #:shield 100.0 #:flying #t)
                                              (mk-workers 'probe 32 8260 32.0 32.0)))
              'researched-upgrades '(warp-gate-research charge))))
  (define warp-in-cnt8 (count (lambda (a) (and (pair? a) (eq? (car a) 'warp-in))) acts-wp-warp8))
  (define home-z-held? (not (ormap (lambda (a) (equal? a '(train zealot))) acts-wp-warp8)))
  ;; Also verify 1-base PvP Proxy Robo Immortal Prism phases cleanly!
  (define rt-wp1 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                        #:cheese-mode? #t #:cheese-profile 'pvp-proxy-robo-immortal))
  (define acts-wp1
    (run-l34 rt-wp1
             (hash-set
              (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 5100
                           #:minerals 500 #:gas 200 #:supply-used 36 #:supply-cap 62 #:army-supply 14
                           #:mineral-harvesters 16 #:vespene-harvesters 6
                           #:ally-buildings (list (mk-u 8281 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                  (mk-u 8282 'warp-gate 36.0 26.0 #:hp 500.0 #:shield 500.0))
                           #:ally-units (cons (mk-u 8290 'warp-prism-phasing 144.0 148.0 #:hp 80.0 #:shield 100.0 #:flying #t)
                                              (mk-workers 'probe 22 8300 32.0 32.0)))
              'researched-upgrades '(warp-gate-research))))
  (define pvp1-warped? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'warp-in) (= (second a) 8282))) acts-wp1))
  (check-test "T8b-l87c-version-c-warp-prism-phases-warps-8-gates-and-holds-home-zealots"
              (and phased-ok? (= warp-in-cnt8 8) home-z-held? pvp1-warped?)
              (format "phased=~a warp8=~a heldHome=~a pvp1=~a"
                      phased-ok? warp-in-cnt8 home-z-held? pvp1-warped?))

  ;; T8c: Cannon Rush skips +/-24t detour, rotates (px, py) on killed proxy Pylon & caps <4 losses,
  ;; and filters Printf high-ground spotter off locked cheese Probes!
  (define rt-cr (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                       #:cheese-mode? #t #:cheese-profile 'pvz-cannon-rush))
  (define cr-probes (mk-workers 'probe 16 8320 32.0 32.0))
  (run-l34 rt-cr
           (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 672
                        #:minerals 200 #:gas 0 #:supply-used 16 #:supply-cap 23 #:army-supply 0
                        #:mineral-harvesters 16 #:vespene-harvesters 0
                        #:ally-buildings (list (mk-u 8310 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                               (mk-u 8311 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                                               (mk-u 8312 'forge 38.0 34.0 #:hp 400.0 #:shield 400.0))
                        #:ally-units cr-probes))
  (define cr-pxy0 (rt-cheese-proxy-xy rt-cr))
  (define cr-wp0 (hash-ref (rt-cheese-state rt-cr) 'proxy-wp #f))
  (define cr-no-detour? (equal? cr-pxy0 cr-wp0))
  ;; Tick 2: Proxy Pylon exists -> Tick 3: Proxy Pylon killed -> shifts (px, py) >= 3.0t!
  (run-l34 rt-cr
           (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 900
                        #:minerals 100 #:gas 0 #:supply-used 16 #:supply-cap 31 #:army-supply 0
                        #:mineral-harvesters 16 #:vespene-harvesters 0
                        #:ally-buildings (list (mk-u 8310 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                               (mk-u 8311 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                                               (mk-u 8312 'forge 38.0 34.0 #:hp 400.0 #:shield 400.0)
                                               (mk-u 8313 'pylon (car cr-pxy0) (cdr cr-pxy0) #:hp 200.0 #:shield 200.0))
                        #:ally-units cr-probes))
  (run-l34 rt-cr
           (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 1050
                        #:minerals 150 #:gas 0 #:supply-used 16 #:supply-cap 23 #:army-supply 0
                        #:mineral-harvesters 16 #:vespene-harvesters 0
                        #:ally-buildings (list (mk-u 8310 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                               (mk-u 8311 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                                               (mk-u 8312 'forge 38.0 34.0 #:hp 400.0 #:shield 400.0))
                        #:ally-units cr-probes))
  (define cr-pxy1 (rt-cheese-proxy-xy rt-cr))
  (define cr-shifted? (>= (dist2d (car cr-pxy0) (cdr cr-pxy0) (car cr-pxy1) (cdr cr-pxy1)) 3.0))
  (hash-set! (rt-cheese-state rt-cr) 'cannon-pylon-deaths 4)
  (define acts-cr-capped
    (run-l34 rt-cr
             (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 1200
                          #:minerals 250 #:gas 0 #:supply-used 16 #:supply-cap 23 #:army-supply 0
                          #:mineral-harvesters 16 #:vespene-harvesters 0
                          #:ally-buildings (list (mk-u 8310 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                 (mk-u 8311 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                                                 (mk-u 8312 'forge 38.0 34.0 #:hp 400.0 #:shield 400.0))
                          #:ally-units cr-probes)))
  (define cr-pylon-capped?
    (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'pylon))) acts-cr-capped)))
  (check-test "T8c-l87c-cannon-rush-no-detour-pylon-death-rotation-and-4-loss-cap"
              (and cr-no-detour? cr-shifted? cr-pylon-capped?)
              (format "noDet=~a shift=~a cap=~a" cr-no-detour? cr-shifted? cr-pylon-capped?))

  ;; T8d: Proxy Spine skips +/-24t detour, holds 100M/Spine ahead of Lings/Queen, and defers
  ;; pull-workers-at-hit until Spines start or >= 135s!
  (define rt-ps (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                       #:cheese-mode? #t #:cheese-profile 'zvz-12pool-proxy-spine))
  (define ps-lings
    (for/list ([i (in-range 14)])
      (mk-u (+ 8360 i) 'zergling (+ 120.0 (* 0.3 i)) 120.0 #:hp 35.0)))
  (define acts-ps
    (run-l34 rt-ps
             (hash-set
              (mk-live-obs #:race 'Zerg #:enemy-race 'Zerg #:frame 2500 ;; 111.6s (commit >= 105s, < 135s!)
                           #:minerals 180 #:gas 0 #:supply-used 22 #:supply-cap 28 #:army-supply 7
                           #:mineral-harvesters 14 #:vespene-harvesters 0
                           #:ally-buildings (list (mk-u 8350 'hatchery 32.0 32.0 #:hp 1500.0)
                                                  (mk-u 8351 'spawning-pool 36.0 32.0 #:hp 1000.0))
                           #:ally-units (append (mk-workers 'drone 14 8380 32.0 32.0) ps-lings)
                           #:enemy-buildings (list (mk-u 8399 'hatchery 134.0 136.0 #:hp 1500.0)))
              'larva-count 4)))
  (define ps-pxy (rt-cheese-proxy-xy rt-ps))
  (define ps-wp (hash-ref (rt-cheese-state rt-ps) 'proxy-wp #f))
  (define ps-pulled (hash-ref (rt-cheese-state rt-ps) 'pulled-worker-tags '()))
  (check-test "T8d-l87c-proxy-spine-tight-anchor-no-detour-and-deferred-drone-pull"
              (and (pair? ps-pxy)
                   (<= (dist2d (car ps-pxy) (cdr ps-pxy) 134.0 136.0) 4.5)
                   (equal? ps-pxy ps-wp)
                   (null? ps-pulled))
              (format "pxy=~s wp=~s pulled=~s" ps-pxy ps-wp ps-pulled))

  ;; T8e: Nydus Overlord pre-spotter (>= 150s, not in proxy-worker-tags), nydus.rkt removes blind
  ;; fogged bunker worm spawn when spotters exist, AND emit-direct-batch! loads multiple Queens + Lings!
  (define nyd-acts-no-blind
    (plan-nydus-actions
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 6500
                  #:minerals 200 #:gas 200 #:supply-used 60 #:supply-cap 86 #:army-supply 12
                  #:ally-buildings (list (mk-u 8401 'nydus-network 32.0 32.0 #:hp 850.0))
                  #:ally-units (list (mk-u 8402 'overlord 40.0 40.0 #:hp 200.0 #:flying #t))
                  #:enemy-buildings (list (mk-u 8490 'bunker 140.0 140.0 #:hp 400.0)))))
  (define blind-bunker-worm?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build-nydus-worm))) nyd-acts-no-blind))
  (define rt-nyd2 (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                         #:cheese-mode? #t #:cheese-profile 'zvt-42d-queen-ling-nydus))
  (define acts-nyd-spot
    (run-l34 rt-nyd2
             (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 3600 ;; 160.7s >= 150s
                          #:minerals 100 #:gas 50 #:supply-used 40 #:supply-cap 66 #:army-supply 10
                          #:mineral-harvesters 28 #:vespene-harvesters 3
                          #:ally-buildings (list (mk-u 8410 'hatchery 32.0 32.0 #:hp 1500.0)
                                                 (mk-u 8411 'spawning-pool 36.0 32.0 #:hp 1000.0))
                          #:ally-units (cons (mk-u 8415 'overlord 50.0 50.0 #:hp 200.0 #:flying #t)
                                             (mk-workers 'drone 31 8420 32.0 32.0)))))
  (define ov-spot-moved?
    (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 8415))) acts-nyd-spot)
         (set-empty? (rt-cheese-proxy-worker-tags rt-nyd2))))
  ;; At 290s with completed Nydus Network + 4 Queens + 8 Lings nearby: ALL load in ONE step!
  (define nyd-army
    (append (for/list ([i (in-range 4)]) (mk-u (+ 8460 i) 'queen 34.0 (+ 32.0 (* 0.5 i)) #:hp 175.0))
            (for/list ([i (in-range 8)]) (mk-u (+ 8470 i) 'zergling 35.0 (+ 30.0 (* 0.5 i)) #:hp 35.0))))
  (define acts-nyd-load
    (run-l34 rt-nyd2
             (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 6500 ;; 290s >= 275s
                          #:minerals 200 #:gas 200 #:supply-used 60 #:supply-cap 86 #:army-supply 12
                          #:mineral-harvesters 36 #:vespene-harvesters 6
                          #:ally-buildings (list (mk-u 8410 'lair 32.0 32.0 #:hp 2000.0)
                                                 (mk-u 8411 'spawning-pool 36.0 32.0 #:hp 1000.0)
                                                 (mk-u 8412 'nydus-network 33.0 33.0 #:hp 850.0))
                          #:ally-units (append (mk-workers 'drone 42 8420 32.0 32.0) nyd-army))))
  (define nyd-load-cnt (count (lambda (a) (and (pair? a) (eq? (car a) 'nydus-load) (= (second a) 8412))) acts-nyd-load))
  (check-test "T8e-l87c-nydus-no-blind-bunker-ov-prespotter-and-multi-unit-nydus-load"
              (and (not blind-bunker-worm?) ov-spot-moved? (>= nyd-load-cnt 8))
              (format "blindWorm=~a ovSpot=~a loadCnt=~a" blind-bunker-worm? ov-spot-moved? nyd-load-cnt))

  ;; T8f: Proxy Bunker requires >=1 Marine before 104s, incomplete damaged proxy Bunker gets SCV
  ;; (repair sid bid), and proxy Bunker loads Marine via cheese-mode bunker-load override!
  (define rt-bk (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                       #:cheese-mode? #t #:cheese-profile 'tvz-proxy-2rax-bunker))
  (define acts-bk-nomarine
    (run-l34 rt-bk
             (mk-live-obs #:race 'Terran #:enemy-race 'Zerg #:frame 2100 ;; 93.75s < 104s, 0 Marines!
                          #:minerals 200 #:gas 0 #:supply-used 17 #:supply-cap 23 #:army-supply 0
                          #:mineral-harvesters 17 #:vespene-harvesters 0
                          #:ally-buildings (list (mk-u 8501 'command-center 32.0 32.0 #:hp 1500.0)
                                                 (mk-u 8502 'supply-depot 38.0 32.0 #:hp 400.0)
                                                 (mk-u 8503 'barracks 120.0 110.0 #:hp 1000.0)
                                                 (mk-u 8504 'barracks 124.0 110.0 #:hp 1000.0))
                          #:ally-units (mk-workers 'scv 17 8510 32.0 32.0))))
  (define deferred-bunker-before-marine?
    (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'bunker))) acts-bk-nomarine)))
  ;; Incomplete damaged proxy Bunker at (130, 130) + nearby SCVs + completed Bunker + Marine!
  (define acts-bk-rep
    (run-l34 rt-bk
             (mk-live-obs #:race 'Terran #:enemy-race 'Zerg #:frame 2500
                          #:minerals 100 #:gas 0 #:supply-used 22 #:supply-cap 31 #:army-supply 4
                          #:mineral-harvesters 15 #:vespene-harvesters 0
                          #:ally-buildings (list (mk-u 8501 'command-center 32.0 32.0 #:hp 1500.0)
                                                 (mk-u 8505 'bunker 130.0 130.0 #:hp 220.0 #:max-hp 400.0 #:build-progress 0.6))
                          #:ally-units (list* (mk-u 8520 'scv 132.0 130.0 #:hp 45.0)
                                              (mk-u 8521 'scv 131.0 132.0 #:hp 45.0)
                                              (mk-workers 'scv 14 8530 32.0 32.0))
                          #:enemy-units (list (mk-u 8590 'zergling 133.0 131.0 #:hp 35.0))
                          #:enemy-buildings (list (mk-u 8599 'hatchery 134.0 136.0 #:hp 1500.0)))))
  (define repaired-incomp-bunker?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'repair) (= (third a) 8505))) acts-bk-rep))
  (check-test "T8f-l87c-proxy-bunker-waits-for-marine-and-repairs-incomplete-bunker"
              (and deferred-bunker-before-marine? repaired-incomp-bunker?)
              (format "deferNoMar=~a repIncomp=~a" deferred-bunker-before-marine? repaired-incomp-bunker?))

  ;; T8g: Home-Raid Survival: Version C peels 1-2 nearest units when 0 local defenders vs small
  ;; raid, small-raid worker survival mineral-walks wounded worker (<=24 EHP) & pulls 3 healthy
  ;; workers vs 1 uncontested Reaper, and builds 1 reactive home static defense!
  (define rt-hr (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                       #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (hash-set! (rt-cheese-state rt-hr) 'committed? #t)
  (define hr-workers
    (cons (mk-u 8610 'scv 31.0 31.0 #:hp 18.0 #:max-hp 45.0) ;; wounded <= 24 EHP -> mineral-walk!
          (mk-workers 'scv 14 8611 32.0 32.0)))
  (define hr-marauders
    (list (mk-u 8640 'marauder 90.0 90.0 #:hp 125.0)
          (mk-u 8641 'marauder 110.0 110.0 #:hp 125.0)
          (mk-u 8642 'marauder 120.0 120.0 #:hp 125.0)))
  (define acts-hr
    (run-l34 rt-hr
             (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame 3200
                          #:minerals 250 #:gas 50 #:supply-used 24 #:supply-cap 31 #:army-supply 6
                          #:mineral-harvesters 15 #:vespene-harvesters 0
                          #:ally-buildings (list (mk-u 8601 'command-center 32.0 32.0 #:hp 1500.0)
                                                 (mk-u 8602 'barracks 38.0 32.0 #:hp 1000.0))
                          #:ally-units (append hr-workers hr-marauders)
                          #:enemy-units (list (mk-u 8690 'reaper 34.0 33.0 #:hp 60.0)))))
  (define (act-has-id? a uid)
    (and (pair? a) (pair? (cdr a))
         (or (equal? (second a) uid)
             (and (list? (second a)) (memv uid (second a))))))
  (define wounded-evac? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (act-has-id? a 8610))) acts-hr))
  (define peeled-nearest? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-unit) (act-has-id? a 8640) (equal? (third a) 8690))) acts-hr))
  (define reactive-home-sd? (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) acts-hr))
  (check-test "T8g-l87c-home-raid-peel-small-raid-worker-evac-and-reactive-home-sd"
              (and wounded-evac? peeled-nearest? reactive-home-sd?)
              (format "evac=~a peel=~a homeSd=~a" wounded-evac? peeled-nearest? reactive-home-sd?))

  ;; T8h: Terran SCV @2:00 gas sweep does NOT expire 160f timer while still 32t outside enemy
  ;; natural ramp, ignores exposed-builder-scv during sweep, and continues with 2 chasing workers!
  (define rt-sw87c (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (hash-set! (rt-scout-state rt-sw87c) 'scout-id 8701)
  (hash-set! (rt-scout-state rt-sw87c) 'dispatched? #t)
  (define geysers-87c
    (list (hash 'id 8791 'type 'vespene-geyser 'x 49.0 'y 37.0 'vespene-contents 2250)
          (hash 'id 8792 'type 'vespene-geyser 'x 46.0 'y 33.0 'vespene-contents 2250)))
  (define (mk-sw87c-obs f sx sy eu eb)
    (hash-set
     (mk-live-obs #:race 'Terran #:enemy-race 'Terran #:frame f
                  #:minerals 120 #:gas 20 #:supply-used 18 #:supply-cap 23 #:army-supply 0
                  #:mineral-harvesters 15 #:vespene-harvesters 2
                  #:base-x 155.0 #:base-y 133.0 #:nat-x 157.0 #:nat-y 104.0
                  #:enemy-x 42.0 #:enemy-y 40.0 #:enemy-exp-x 40.5 #:enemy-exp-y 69.5
                  #:ally-buildings (list (mk-u 8700 'command-center 155.0 133.0 #:hp 1500.0)
                                         (mk-u 8702 'barracks 148.0 128.0 #:hp 1000.0))
                  #:ally-units (cons (mk-u 8701 'scv sx sy #:hp 45.0)
                                     (mk-workers 'scv 16 8710 155.0 133.0))
                  #:enemy-units eu
                  #:enemy-buildings eb)
     'geysers geysers-87c))
  ;; Tick 1 (f=1450) & Tick 2 (f=1630, +180f > 160f!) with SCV still 32t away at (42, 72),
  ;; next to an enemy builder SCV & 2 chasing workers -> wp-idx stays 0 & emits worker-scout!
  (step-layer2-economy!
   rt-sw87c
   (mk-sw87c-obs 1450 42.0 72.0
                 (list (hash 'id 8750 'type 'scv 'x 44.0 'y 70.0 'hp 45.0 'has-build-order? #t)
                       (mk-u 8751 'scv 43.0 72.0 #:hp 45.0))
                 (list (mk-u 8760 'command-center 42.0 40.0 #:hp 1500.0)
                       (mk-u 8761 'barracks 45.0 70.0 #:hp 1000.0 #:build-progress 0.5))))
  (define acts-sw87c
    (step-layer2-economy!
     rt-sw87c
     (mk-sw87c-obs 1630 42.0 70.0
                   (list (hash 'id 8750 'type 'scv 'x 44.0 'y 69.0 'hp 45.0 'has-build-order? #t)
                         (mk-u 8751 'scv 43.0 70.0 #:hp 45.0))
                   (list (mk-u 8760 'command-center 42.0 40.0 #:hp 1500.0)
                         (mk-u 8761 'barracks 45.0 69.0 #:hp 1000.0 #:build-progress 0.6)))))
  (define sw87c-still-wp0? (equal? (hash-ref (rt-scout-state rt-sw87c) 'l87b-geyser-wp-idx 0) 0))
  (define sw87c-sweeping?
    (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout) (= (second a) 8701))) acts-sw87c)
         (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack) (= (second a) 8701))) acts-sw87c))))
  (check-test "T8h-l87c-terran-scv-sweep-no-premature-32t-timeout-and-ignores-ramp-builder"
              (and sw87c-still-wp0? sw87c-sweeping?)
              (format "wpIdx=~a sweeping=~a acts=~s"
                      (hash-ref (rt-scout-state rt-sw87c) 'l87b-geyser-wp-idx #f) sw87c-sweeping? acts-sw87c))

  ;; ===========================================================================
  ;; Loop 87D Track 3 Unit Tests (T9a..T9e): Map-Analysis Cheese Solvers,
  ;; Execution Fixes, and State-Driven 'build -> 'commit -> 'follow-up -> 'fallback
  ;; ===========================================================================

  ;; T9a: 3-Pylon Cannon Wall 4-step sequence (Wall Pylon #1 -> Cannon #1 at cannon-pt
  ;; -> Wall Pylon #2 sealing on Cannon #1 warping) + spot rotation on killed proxy Pylon.
  (define rt-cw9 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                        #:cheese-mode? #t #:cheese-profile 'pvp-cannon-rush))
  (define cw9-mins
    (list (hash 'id 9001 'type 'mineral-field 'x 122.0 'y 120.0)
          (hash 'id 9002 'type 'mineral-field 'x 122.0 'y 122.0)
          (hash 'id 9003 'type 'mineral-field 'x 122.0 'y 124.0)
          (hash 'id 9004 'type 'mineral-field 'x 123.0 'y 126.0)
          (hash 'id 9005 'type 'mineral-field 'x 124.0 'y 128.0)))
  (define cw9-grids
    (hash 'width 180 'height 180
          'placement-ref (lambda (ix iy)
                           (if (and (>= ix 5) (< ix 175) (>= iy 5) (< iy 175)
                                    (not (and (>= ix 135) (<= ix 142) (>= iy 118) (<= iy 132))))
                               1 0))
          'pathing-ref   (lambda (ix iy)
                           (if (and (>= ix 5) (< ix 175) (>= iy 5) (< iy 175)
                                    (not (and (>= ix 135) (<= ix 142) (>= iy 118) (<= iy 132))))
                               1 0))
          'height-ref    (lambda (ix iy)
                           (if (and (>= ix 138) (>= iy 138)) 140 128))))
  (define (mk-cw9-obs f mins bldgs units [eunits '()])
    (hash-set*
     (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame f
                  #:minerals mins #:gas 0 #:supply-used 16 #:supply-cap 23 #:army-supply 0
                  #:mineral-harvesters 14 #:vespene-harvesters 0
                  #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
                  #:enemy-x 150.0 #:enemy-y 150.0 #:enemy-exp-x 128.0 #:enemy-exp-y 124.0
                  #:expansions (list (cons 32.0 32.0) (cons 56.0 32.0)
                                     (cons 128.0 124.0) (cons 150.0 150.0))
                  #:ally-buildings bldgs
                  #:ally-units units
                  #:enemy-units eunits)
     'map-grids cw9-grids
     'mineral-patches cw9-mins))
  ;; Step 1: 0 proxy pylons -> solver caches wall spots and emits Pylon #1 at wall-py-pts[0]
  (define acts-cw9-1
    (step-layer2-economy!
     rt-cw9
     (mk-cw9-obs 1200 150
                 (list (mk-u 9010 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                       (mk-u 9011 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                       (mk-u 9012 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0))
                 (cons (mk-u 9020 'probe 128.0 124.0 #:hp 20.0 #:shield 20.0)
                       (mk-workers 'probe 14 9021 32.0 32.0)))))
  (define cw9-spots (hash-ref (rt-cheese-state rt-cw9) 'cannon-wall-spots '()))
  (define cw9-spot0 (and (pair? cw9-spots) (car cw9-spots)))
  (define cw9-c0 (and (hash? cw9-spot0) (hash-ref cw9-spot0 'cannon-pt #f)))
  (define cw9-pys0 (and (hash? cw9-spot0) (hash-ref cw9-spot0 'pylon-pts '())))
  (define cw9-step1-py1?
    (and (pair? cw9-pys0)
         (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'pylon)
                       (<= (sqrt (+ (sqr (- (third a) (car (car cw9-pys0))))
                                    (sqr (- (fourth a) (cdr (car cw9-pys0))))))
                           0.5)))
                acts-cw9-1)))
  ;; Step 2: Wall Pylon #1 complete -> emits Cannon #1 at cannon-pt
  (define cw9-py1-pt (if (pair? cw9-pys0) (car cw9-pys0) (cons 128.0 124.0)))
  (define acts-cw9-2
    (step-layer2-economy!
     rt-cw9
     (mk-cw9-obs 1600 200
                 (list (mk-u 9010 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                       (mk-u 9011 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                       (mk-u 9012 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0)
                       (mk-u 9015 'pylon (car cw9-py1-pt) (cdr cw9-py1-pt) #:hp 200.0 #:shield 200.0))
                 (cons (mk-u 9020 'probe (car cw9-py1-pt) (cdr cw9-py1-pt) #:hp 20.0 #:shield 20.0)
                       (mk-workers 'probe 14 9021 32.0 32.0)))))
  (define cw9-step2-can1?
    (and (pair? cw9-c0)
         (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'photon-cannon)
                       (<= (sqrt (+ (sqr (- (third a) (car cw9-c0)))
                                    (sqr (- (fourth a) (cdr cw9-c0)))))
                           0.5)))
                acts-cw9-2)))
  ;; Step 3: Wall Pylon #1 complete + Cannon #1 warping -> seals immediately with Wall Pylon #2!
  (define cw9-can1-pt (if (pair? cw9-c0) cw9-c0 (cons 128.0 124.0)))
  (define acts-cw9-3
    (step-layer2-economy!
     rt-cw9
     (mk-cw9-obs 1720 260
                 (list (mk-u 9010 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                       (mk-u 9011 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                       (mk-u 9012 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0)
                       (mk-u 9015 'pylon (car cw9-py1-pt) (cdr cw9-py1-pt) #:hp 200.0 #:shield 200.0)
                       (mk-u 9016 'photon-cannon (car cw9-can1-pt) (cdr cw9-can1-pt)
                             #:hp 100.0 #:shield 100.0 #:build-progress 0.2))
                 (cons (mk-u 9020 'probe (car cw9-py1-pt) (cdr cw9-py1-pt) #:hp 20.0 #:shield 20.0)
                       (mk-workers 'probe 14 9021 32.0 32.0)))))
  (define cw9-step3-seal?
    (or (< (length cw9-pys0) 2)
        (ormap (lambda (a)
                 (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'pylon)
                      (<= (sqrt (+ (sqr (- (third a) (car (second cw9-pys0))))
                                   (sqr (- (fourth a) (cdr (second cw9-pys0))))))
                          0.5)))
               acts-cw9-3)))
  ;; Step 4: Proxy Pylon #1 killed (1 -> 0) -> rotates cannon-wall-idx (0 -> 1)
  (step-layer2-economy!
   rt-cw9
   (mk-cw9-obs 1950 200
               (list (mk-u 9010 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                     (mk-u 9011 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                     (mk-u 9012 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0))
               (cons (mk-u 9020 'probe (car cw9-py1-pt) (cdr cw9-py1-pt) #:hp 20.0 #:shield 20.0)
                     (mk-workers 'probe 14 9021 32.0 32.0))))
  (define cw9-rotated?
    (or (< (length cw9-spots) 2)
        (= (hash-ref (rt-cheese-state rt-cw9) 'cannon-wall-idx 0) 1)))
  (check-test "T9a-l87d-cannon-wall-4step-sequence-and-spot-rotation"
              (and (pair? cw9-spots) cw9-step1-py1? cw9-step2-can1? cw9-step3-seal? cw9-rotated?)
              (format "nSpots=~a s1Py1=~a s2Can1=~a s3Seal=~a rot=~a idx=~a"
                      (length cw9-spots) cw9-step1-py1? cw9-step2-can1? cw9-step3-seal? cw9-rotated?
                      (hash-ref (rt-cheese-state rt-cw9) 'cannon-wall-idx 0)))

  ;; T9b: TechLab-Factory Cyclone training (Base75689 patch) AND Terran addon-swap
  ;; in non-proxy tvz-reaper-fe-hellion-banshee (Barracks-Reactor -> bare Factory).
  (define rt-cyc9 (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                         #:cheese-mode? #t #:cheese-profile 'tvp-1base-2gas-cyclone))
  (define acts-cyc9
    (step-layer2-economy!
     rt-cyc9
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 3600
                  #:minerals 200 #:gas 150 #:supply-used 22 #:supply-cap 47 #:army-supply 2
                  #:mineral-harvesters 14 #:vespene-harvesters 6
                  #:ally-buildings (list (mk-u 9101 'orbital-command 32.0 32.0 #:hp 1500.0)
                                         (mk-u 9102 'supply-depot 36.0 30.0 #:hp 400.0)
                                         (mk-u 9105 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 9108 'supply-depot 40.0 30.0 #:hp 400.0)
                                         (mk-u 9106 'refinery 30.0 26.0 #:hp 500.0)
                                         (mk-u 9107 'refinery 36.0 26.0 #:hp 500.0)
                                         (hash 'id 9103 'type 'barracks 'x 38.0 'y 34.0 'hp 1000.0 'max-hp 1000.0
                                               'build-progress 1.0 'add-on-tag 9109 'addon 'barracks-reactor 'order-count 0)
                                         (mk-u 9109 'barracks-reactor 40.5 33.5 #:hp 400.0)
                                         (hash 'id 9104 'type 'factory 'x 42.0 'y 34.0 'hp 1250.0 'max-hp 1250.0
                                               'build-progress 1.0 'add-on-tag 9119 'addon 'factory-techlab 'order-count 0)
                                         (mk-u 9119 'factory-techlab 44.5 33.5 #:hp 400.0))
                  #:ally-units (append (list (mk-u 9140 'marine 36.0 34.0 #:hp 45.0)
                                             (mk-u 9141 'marine 37.0 34.0 #:hp 45.0))
                                       (mk-workers 'scv 22 9110 32.0 32.0)))))
  (define trained-tl-cyclone? (ormap (lambda (a) (equal? a '(train cyclone))) acts-cyc9))

  (define rt-swp9 (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                         #:cheese-mode? #t #:cheese-profile 'tvz-reaper-fe-hellion-banshee))
  (define acts-swp9
    (step-layer2-economy!
     rt-swp9
     (mk-live-obs #:race 'Terran #:enemy-race 'Zerg #:frame 4500
                  #:minerals 180 #:gas 90 #:supply-used 28 #:supply-cap 46 #:army-supply 4
                  #:mineral-harvesters 20 #:vespene-harvesters 3
                  #:ally-buildings (list (mk-u 9120 'orbital-command 32.0 32.0 #:hp 1500.0)
                                         (mk-u 9121 'command-center 56.0 32.0 #:hp 1500.0)
                                         (mk-u 9122 'supply-depot 36.0 28.0 #:hp 400.0)
                                         (mk-u 9126 'supply-depot 38.0 28.0 #:hp 400.0)
                                         (mk-u 9127 'refinery 30.0 26.0 #:hp 500.0)
                                         (hash 'id 9123 'type 'barracks 'x 36.0 'y 35.0 'hp 1000.0 'max-hp 1000.0
                                               'build-progress 1.0 'add-on-tag 9124 'addon 'barracks-reactor 'order-count 0)
                                         (mk-u 9124 'barracks-reactor 38.5 34.5 #:hp 400.0)
                                         (hash 'id 9125 'type 'factory 'x 42.0 'y 35.0 'hp 1250.0 'max-hp 1250.0
                                               'build-progress 1.0 'add-on-tag 0 'order-count 0))
                  #:ally-units (mk-workers 'scv 23 9130 32.0 32.0))))
  (define emitted-addon-swap?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'terran-addon-swap))) acts-swp9))
  (check-test "T9b-l87d-techlab-factory-cyclone-and-nonproxy-terran-addon-swap"
              (and trained-tl-cyclone? emitted-addon-swap?)
              (format "tlCyclone=~a addonSwap=~a cycActs=~s swpActs=~s"
                      trained-tl-cyclone? emitted-addon-swap? acts-cyc9 acts-swp9))

  ;; T9c: pvp-proxy-robo-immortal trains Immortal #1 BEFORE Warp Prism #1, AND healthy Warp Prism
  ;; encountering a single patrolling AA unit slips tangentially toward enemy main (not backward flee).
  (define rt-imm9 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                         #:cheese-mode? #t #:cheese-profile 'pvp-proxy-robo-immortal))
  (hash-set! (rt-cheese-state rt-imm9) 'proxy-xy (cons 105.0 100.0))
  (hash-set! (rt-cheese-state rt-imm9) 'proxy-wp (cons 105.0 100.0))
  (define imm9-base-bldgs
    (list (mk-u 9201 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 9202 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9203 'gateway 38.0 30.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9206 'gateway 42.0 30.0 #:hp 500.0 #:shield 500.0)
          (mk-u 9207 'assimilator 30.0 26.0 #:hp 450.0 #:shield 450.0)
          (mk-u 9208 'assimilator 36.0 26.0 #:hp 450.0 #:shield 450.0)
          (mk-u 9204 'cybernetics-core 38.0 34.0 #:hp 550.0 #:shield 550.0)
          (mk-u 9215 'pylon 106.0 100.0 #:hp 200.0 #:shield 200.0)
          (mk-u 9205 'robotics-facility 105.0 100.0 #:hp 450.0 #:shield 450.0)))
  (define acts-imm9-1
    (step-layer2-economy!
     rt-imm9
     (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 4400
                  #:minerals 280 #:gas 120 #:supply-used 28 #:supply-cap 46 #:army-supply 8
                  #:mineral-harvesters 16 #:vespene-harvesters 6
                  #:ally-buildings imm9-base-bldgs
                  #:ally-units (mk-workers 'probe 22 9210 32.0 32.0))))
  (define imm1-before-prism?
    (and (ormap (lambda (a) (equal? a '(train immortal))) acts-imm9-1)
         (not (ormap (lambda (a) (equal? a '(train warp-prism))) acts-imm9-1))))
  (define acts-imm9-2
    (step-layer2-economy!
     rt-imm9
     (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame 4600
                  #:minerals 260 #:gas 20 #:supply-used 32 #:supply-cap 46 #:army-supply 12
                  #:mineral-harvesters 16 #:vespene-harvesters 6
                  #:ally-buildings imm9-base-bldgs
                  #:ally-units (cons (mk-u 9209 'immortal 105.0 102.0 #:hp 200.0 #:shield 100.0)
                                     (mk-workers 'probe 22 9210 32.0 32.0)))))
  (define prism-after-imm1?
    (ormap (lambda (a) (equal? a '(train warp-prism))) acts-imm9-2))

  (define rt-wp9 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                        #:cheese-mode? #t #:cheese-profile 'pvz-32p-8gate-chargelot-prism))
  (define acts-wp9
    (run-l34 rt-wp9
             (hash-set
              (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6300
                           #:minerals 300 #:gas 50 #:supply-used 52 #:supply-cap 94 #:army-supply 20
                           #:mineral-harvesters 26 #:vespene-harvesters 6
                           #:enemy-x 154.0 #:enemy-y 155.0 #:enemy-exp-x 132.0 #:enemy-exp-y 142.0
                           #:ally-buildings (list (mk-u 9250 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                  (mk-u 9251 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                  (mk-u 9252 'robotics-facility 40.0 34.0 #:hp 450.0 #:shield 450.0)
                                                  (mk-u 9253 'warp-gate 36.0 28.0 #:hp 500.0 #:shield 500.0))
                           #:ally-units (cons (mk-u 9260 'warp-prism 130.0 132.0 #:hp 80.0 #:shield 100.0 #:flying #t)
                                              (mk-workers 'probe 32 9261 32.0 32.0))
                           #:enemy-units (list (mk-u 9290 'queen 131.0 139.0 #:hp 175.0)))
              'researched-upgrades '(warp-gate-research charge))))
  (define wp9-mv (findf (lambda (a) (and (pair? a) (eq? (car a) 'move) (= (second a) 9260))) acts-wp9))
  (define wp9-slips-forward?
    (and wp9-mv
         (let* ([d-before (sqrt (+ (sqr (- 130.0 154.0)) (sqr (- 132.0 155.0))))]
                [d-after  (sqrt (+ (sqr (- (third wp9-mv) 154.0)) (sqr (- (fourth wp9-mv) 155.0))))])
           (< d-after (- d-before 1.0)))))
  (check-test "T9c-l87d-pvp-immortal-before-prism-and-single-aa-prism-slip"
              (and imm1-before-prism? prism-after-imm1? wp9-slips-forward?)
              (format "imm1Pre=~a wpPost=~a slipFwd=~a wpMv=~s"
                      imm1-before-prism? prism-after-imm1? wp9-slips-forward? wp9-mv))

  ;; T9d: Nydus main-plateau corner + dead-air Overlord perch solver: dispatches Overlord at >= 140s
  ;; to perch, vision-gates nydus-worm when spotter is far, and emits worm when spotter arrives.
  (define rt-nyd9 (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                         #:cheese-mode? #t #:cheese-profile 'zvt-42d-queen-ling-nydus))
  (define nyd9-grids
    (hash 'width 180 'height 180
          'placement-ref (lambda (ix iy)
                           (if (and (>= ix 10) (< ix 168) (>= iy 10) (< iy 168)) 1 0))
          'pathing-ref   (lambda (ix iy)
                           (if (and (>= ix 10) (< ix 168) (>= iy 10) (< iy 168)) 1 0))
          'height-ref    (lambda (ix iy)
                           (if (and (>= ix 126) (>= iy 126)) 140 128))))
  ;; Tick 1 (f=3360 = 150s >= 140s): Overlord is still at home (35, 35) -> worm HELD, Overlord routed to perch!
  (define acts-nyd9-far
    (step-layer2-economy!
     rt-nyd9
     (hash-set*
      (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 3360
                   #:minerals 300 #:gas 200 #:supply-used 42 #:supply-cap 66 #:army-supply 10
                   #:mineral-harvesters 26 #:vespene-harvesters 6
                   #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
                   #:enemy-x 150.0 #:enemy-y 150.0 #:enemy-exp-x 120.0 #:enemy-exp-y 125.0
                   #:ally-buildings (list (mk-u 9301 'lair 32.0 32.0 #:hp 2000.0)
                                          (mk-u 9302 'hatchery 56.0 32.0 #:hp 1500.0)
                                          (mk-u 9303 'spawning-pool 36.0 32.0 #:hp 1000.0)
                                          (mk-u 9304 'nydus-network 38.0 30.0 #:hp 850.0))
                   #:ally-units (append (list (mk-u 9310 'overlord 35.0 35.0 #:hp 200.0 #:flying #t))
                                        (mk-workers 'drone 32 9320 32.0 32.0)))
      'map-grids nyd9-grids)))
  (define nyd9-perch (hash-ref (rt-cheese-state rt-nyd9) 'nydus-perch-xy #f))
  (define nyd9-worm  (hash-ref (rt-cheese-state rt-nyd9) 'proxy-xy #f))
  (define nyd9-held-in-fog?
    (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'nydus-worm)))
                acts-nyd9-far)))
  (define nyd9-ov-routed-to-perch?
    (and (pair? nyd9-perch)
         (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'move) (= (second a) 9310)
                       (<= (sqrt (+ (sqr (- (third a) (car nyd9-perch)))
                                    (sqr (- (fourth a) (cdr nyd9-perch)))))
                           1.5)))
                acts-nyd9-far)))
  ;; Tick 2: Overlord arrives at perch (<= 10.5t from worm-pt) -> emits (build-proxy nydus-worm ...)
  (define nyd9-px (if (pair? nyd9-perch) (car nyd9-perch) 160.0))
  (define nyd9-py (if (pair? nyd9-perch) (cdr nyd9-perch) 160.0))
  (define acts-nyd9-near
    (step-layer2-economy!
     rt-nyd9
     (hash-set*
      (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 3600
                   #:minerals 300 #:gas 200 #:supply-used 42 #:supply-cap 66 #:army-supply 10
                   #:mineral-harvesters 26 #:vespene-harvesters 6
                   #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
                   #:enemy-x 150.0 #:enemy-y 150.0 #:enemy-exp-x 120.0 #:enemy-exp-y 125.0
                   #:ally-buildings (list (mk-u 9301 'lair 32.0 32.0 #:hp 2000.0)
                                          (mk-u 9302 'hatchery 56.0 32.0 #:hp 1500.0)
                                          (mk-u 9303 'spawning-pool 36.0 32.0 #:hp 1000.0)
                                          (mk-u 9304 'nydus-network 38.0 30.0 #:hp 850.0))
                   #:ally-units (append (list (mk-u 9310 'overlord nyd9-px nyd9-py #:hp 200.0 #:flying #t))
                                        (mk-workers 'drone 32 9320 32.0 32.0)))
      'map-grids nyd9-grids)))
  (define nyd9-emitted-worm?
    (and (pair? nyd9-worm)
         (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'nydus-worm)
                       (<= (sqrt (+ (sqr (- (third a) (car nyd9-worm)))
                                    (sqr (- (fourth a) (cdr nyd9-worm)))))
                           1.5)))
                acts-nyd9-near)))
  ;; Also verify plan-nydus-actions uses preferred 'nydus-worm-pt & 'nydus-perch-pt directly!
  (define nyd9-plan-acts
    (plan-nydus-actions
     (hash 'frame 3600 'minerals 200 'gas 200 'enemy-x 150.0 'enemy-y 150.0
           'nydus-worm-pt nyd9-worm 'nydus-perch-pt nyd9-perch
           'ally-buildings (list (mk-u 9304 'nydus-network 38.0 30.0 #:hp 850.0))
           'ally-units (list (mk-u 9310 'overlord nyd9-px nyd9-py #:hp 200.0 #:flying #t))
           'enemy-units '() 'enemy-buildings '())))
  (define nyd9-plan-used-pref?
    (and (pair? nyd9-worm)
         (ormap (lambda (a)
                  (and (pair? a) (eq? (car a) 'build-nydus-worm)
                       (<= (sqrt (+ (sqr (- (third a) (car nyd9-worm)))
                                    (sqr (- (fourth a) (cdr nyd9-worm)))))
                           1.5)))
                nyd9-plan-acts)))
  (check-test "T9d-l87d-nydus-main-plateau-perch-and-vision-gated-worm"
              (and (pair? nyd9-perch) nyd9-held-in-fog? nyd9-ov-routed-to-perch? nyd9-emitted-worm? nyd9-plan-used-pref?)
              (format "perch=~s worm=~s heldFog=~a ovPerch=~a wormEmit=~a planPref=~a"
                      nyd9-perch nyd9-worm nyd9-held-in-fog? nyd9-ov-routed-to-perch? nyd9-emitted-worm? nyd9-plan-used-pref?))

  ;; T9e: State-driven 'build -> 'commit -> 'follow-up -> 'fallback lifecycle, [SCBOT_STATE]
  ;; follow-up telemetry, disabled worker-pull in 'follow-up, and Zerg lifted-Terran Spire close-out.
  (define rt-fu9 (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                        #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (hash-set! (rt-cheese-state rt-fu9) 'committed? #t)
  (hash-set! (rt-cheese-state rt-fu9) 'cheese-phase 'commit)
  ;; Tick at f=5040 (225s >= edge-sec=220s) with 6 enemy workers killed -> enters 'follow-up!
  (define fu9-obs
    (hash-set
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 5040
                  #:minerals 450 #:gas 100 #:supply-used 34 #:supply-cap 54 #:army-supply 15
                  #:mineral-harvesters 16 #:vespene-harvesters 3
                  #:ally-buildings (list (mk-u 9401 'orbital-command 32.0 32.0 #:hp 1500.0)
                                         (mk-u 9402 'barracks 100.0 96.0 #:hp 1000.0)
                                         (mk-u 9403 'barracks 104.0 96.0 #:hp 1000.0))
                  #:ally-units (append (list (mk-u 9410 'marauder 130.0 130.0 #:hp 125.0)
                                             (mk-u 9411 'marauder 131.0 130.0 #:hp 125.0)
                                             (mk-u 9412 'marauder 132.0 130.0 #:hp 125.0))
                                       (mk-workers 'scv 19 9420 32.0 32.0))
                  #:enemy-buildings (list (mk-u 9490 'nexus 154.0 155.0 #:hp 1000.0 #:shield 1000.0)))
     'enemy-workers-killed 6))
  (define acts-fu9 (run-l34 rt-fu9 fu9-obs))
  (define fu9-in-followup? (eq? (rt-cheese-phase rt-fu9) 'follow-up))
  (define fu9-tel-line
    (let ([tl (live-bot-runtime-last-telemetry rt-fu9)])
      (if (hash? tl) (hash-ref tl 'state-log-line "") "")))
  (define fu9-telemetry-ok?
    (and (string? fu9-tel-line) (string-contains? fu9-tel-line "cheese=tvp-proxy-2rax-marauder:follow-up:44")))
  (define fu9-no-worker-pull?
    (null? (hash-ref (rt-cheese-state rt-fu9) 'pulled-worker-tags '())))
  ;; Graduate smoothly to 'fallback at f=9520 (425s >= graduate-sec=420s)
  (run-l34 rt-fu9 (hash-set fu9-obs 'frame 9520))
  (define fu9-graduated?
    (and (eq? (rt-cheese-phase rt-fu9) 'fallback)
         (not (cheese-mode-active? rt-fu9))))
  ;; Zerg lifted-Terran close-out in 'follow-up -> emits (build spire)!
  (define rt-zlift9 (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                           #:cheese-mode? #t #:cheese-profile 'zvt-26d-roach-ravager-bust))
  (hash-set! (rt-cheese-state rt-zlift9) 'committed? #t)
  (hash-set! (rt-cheese-state rt-zlift9) 'cheese-phase 'follow-up)
  (define acts-zlift9
    (step-layer2-economy!
     rt-zlift9
     (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 7200 ;; 321s
                  #:minerals 300 #:gas 250 #:supply-used 50 #:supply-cap 74 #:army-supply 20
                  #:mineral-harvesters 24 #:vespene-harvesters 6
                  #:ally-buildings (list (mk-u 9501 'lair 32.0 32.0 #:hp 2000.0)
                                         (mk-u 9502 'hatchery 56.0 32.0 #:hp 1500.0)
                                         (mk-u 9503 'spawning-pool 36.0 32.0 #:hp 1000.0)
                                         (mk-u 9504 'roach-warren 38.0 34.0 #:hp 850.0))
                  #:ally-units (mk-workers 'drone 30 9510 32.0 32.0)
                  #:enemy-buildings (list (mk-u 9590 'command-center 170.0 170.0 #:hp 1500.0 #:flying #t)))))
  (define zlift9-built-spire?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spire))) acts-zlift9))
  (check-test "T9e-l87d-followup-phase-telemetry-no-worker-pull-lifted-terran-and-graduation"
              (and fu9-in-followup? fu9-telemetry-ok? fu9-no-worker-pull? fu9-graduated? zlift9-built-spire?)
              (format "fu=~a tel=~a noPull=~a grad=~a spire=~a tl=~s"
                      fu9-in-followup? fu9-telemetry-ok? fu9-no-worker-pull? fu9-graduated? zlift9-built-spire?
                      fu9-tel-line))

  ;; ===========================================================================
  ;; Loop 87E Track 3 Regression Tests (T10a..T10d): Never skip 'commit,
  ;; Cannon #1 strictly before Wall Pylons #2/#3, Cyclone TechLab on Base75689,
  ;; Frame-0 inferred enemy-nat hidden proxy, and 42d-Nydus early Lings.
  ;; ===========================================================================

  ;; T10a: cheese-held-transition? NEVER fires before committed? = #t + >= 55s post-commit
  ;; (and cheese-edge-detected? requires >= 30s post-commit after 'commit-sec is recorded!).
  (define rt-c10 (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                        #:cheese-mode? #t #:cheese-profile 'tvp-proxy-2rax-marauder))
  (define c10-base-obs
    (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 6048 ;; 270s >= held-sec=265s
                 #:minerals 200 #:gas 50 #:supply-used 23 #:supply-cap 39 #:army-supply 4
                 #:mineral-harvesters 16 #:vespene-harvesters 3
                 #:ally-buildings (list (mk-u 9601 'orbital-command 32.0 32.0 #:hp 1500.0)
                                        (mk-u 9602 'barracks 100.0 96.0 #:hp 1000.0)
                                        (mk-u 9603 'barracks 104.0 96.0 #:hp 1000.0))
                 #:ally-units (append (list (mk-u 9610 'marauder 100.0 96.0 #:hp 125.0))
                                      (mk-workers 'scv 19 9620 32.0 32.0))
                 #:enemy-buildings (list (mk-u 9690 'nexus 154.0 155.0 #:hp 1000.0 #:shield 1000.0))))
  ;; Uncommitted at 270s (>= held-sec 265s): MUST stay 'build (NEVER jump build -> follow-up!)
  (run-l34 rt-c10 c10-base-obs)
  (define c10-no-skip-build? (eq? (rt-cheese-phase rt-c10) 'build))
  ;; Commit fires at 280s (f=6272) with 6 Marauders + Concussive Shells -> records commit-sec=280.0
  (define c10-commit-obs
    (hash-set* c10-base-obs
               'frame 6272
               'researched-upgrades '(concussive-shells)
               'ally-units (append (for/list ([i (in-range 6)])
                                     (mk-u (+ 9610 i) 'marauder 120.0 120.0 #:hp 125.0))
                                   (mk-workers 'scv 19 9620 32.0 32.0))))
  (run-l34 rt-c10 c10-commit-obs)
  (define c10-entered-commit?
    (and (eq? (rt-cheese-phase rt-c10) 'commit)
         (let ([cs (hash-ref (rt-cheese-state rt-c10) 'commit-sec #f)])
           (and (real? cs) (<= (abs (- cs 280.0)) 0.2)))))
  ;; At 300s (20s < 30s post-commit), even with 6 enemy workers killed -> still 'commit!
  (run-l34 rt-c10 (hash-set* c10-commit-obs 'frame 6720 'enemy-workers-killed 6))
  (define c10-held-at-20s? (eq? (rt-cheese-phase rt-c10) 'commit))
  ;; At 325s (45s < 55s post-commit) with no edge -> still 'commit!
  (run-l34 rt-c10 (hash-set* c10-commit-obs 'frame 7280 'enemy-workers-killed 0
                             'enemy-units (for/list ([i (in-range 6)])
                                            (mk-u (+ 9680 i) 'stalker 140.0 140.0 #:hp 80.0 #:shield 80.0))
                             'enemy-confirmed-bases 2))
  (define c10-held-at-45s? (eq? (rt-cheese-phase rt-c10) 'commit))
  ;; At 340s (60s >= 55s post-commit) -> transitions cleanly 'commit -> 'follow-up!
  (run-l34 rt-c10 (hash-set* c10-commit-obs 'frame 7616 'enemy-workers-killed 0
                             'enemy-units (for/list ([i (in-range 6)])
                                            (mk-u (+ 9680 i) 'stalker 140.0 140.0 #:hp 80.0 #:shield 80.0))
                             'enemy-confirmed-bases 2))
  (define c10-fu-at-60s? (eq? (rt-cheese-phase rt-c10) 'follow-up))
  (check-test "T10a-l87e-held-transition-never-skips-commit-and-respects-post-commit-runway"
              (and c10-no-skip-build? c10-entered-commit? c10-held-at-20s? c10-held-at-45s? c10-fu-at-60s?)
              (format "noSkip=~a comm=~a h20=~a h45=~a fu60=~a phase=~a"
                      c10-no-skip-build? c10-entered-commit? c10-held-at-20s? c10-held-at-45s? c10-fu-at-60s?
                      (rt-cheese-phase rt-c10)))

  ;; T10b: Cannon Rush NEVER builds Wall Pylon #2/#3 before proxy Cannon #1 is placed/warping,
  ;; even when enemy Probes are within 3.0t of cannon-pt!
  (define rt-cw10 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                         #:cheese-mode? #t #:cheese-profile 'pvp-cannon-rush))
  (step-layer2-economy!
   rt-cw10
   (mk-cw9-obs 1200 150
               (list (mk-u 9710 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                     (mk-u 9711 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                     (mk-u 9712 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0))
               (cons (mk-u 9720 'probe 128.0 124.0 #:hp 20.0 #:shield 20.0)
                     (mk-workers 'probe 14 9721 32.0 32.0))))
  (define cw10-sp0 (car (hash-ref (rt-cheese-state rt-cw10) 'cannon-wall-spots)))
  (define cw10-c0  (hash-ref cw10-sp0 'cannon-pt))
  (define cw10-py1 (car (hash-ref cw10-sp0 'pylon-pts)))
  (define cw10-eprobes
    (list (mk-u 9790 'probe (+ (car cw10-c0) 2.0) (cdr cw10-c0) #:hp 20.0 #:shield 20.0)
          (mk-u 9791 'probe (car cw10-c0) (+ (cdr cw10-c0) 2.0) #:hp 20.0 #:shield 20.0)))
  ;; With Wall Pylon #1 ready, 0 Cannons, 120M, and 2 enemy Probes at 2t -> MUST NOT drop Pylon #2!
  (define acts-cw10-hold
    (step-layer2-economy!
     rt-cw10
     (mk-cw9-obs 1500 120
                 (list (mk-u 9710 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                       (mk-u 9711 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                       (mk-u 9712 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0)
                       (mk-u 9715 'pylon (car cw10-py1) (cdr cw10-py1) #:hp 200.0 #:shield 200.0))
                 (cons (mk-u 9720 'probe (car cw10-py1) (cdr cw10-py1) #:hp 20.0 #:shield 20.0)
                       (mk-workers 'probe 14 9721 32.0 32.0))
                 cw10-eprobes)))
  (define cw10-blocked-py2?
    (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'pylon)))
                acts-cw10-hold)))
  ;; With 160M and same 2 enemy Probes -> emits Cannon #1 FIRST (NOT Pylon #2)!
  (define acts-cw10-can1
    (step-layer2-economy!
     rt-cw10
     (mk-cw9-obs 1600 160
                 (list (mk-u 9710 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                       (mk-u 9711 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                       (mk-u 9712 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0)
                       (mk-u 9715 'pylon (car cw10-py1) (cdr cw10-py1) #:hp 200.0 #:shield 200.0))
                 (cons (mk-u 9720 'probe (car cw10-py1) (cdr cw10-py1) #:hp 20.0 #:shield 20.0)
                       (mk-workers 'probe 14 9721 32.0 32.0))
                 cw10-eprobes)))
  (define cw10-built-can1-first?
    (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'photon-cannon)))
                acts-cw10-can1)
         (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build-proxy) (eq? (second a) 'pylon)))
                     acts-cw10-can1))))
  (check-test "T10b-l87e-cannon-rush-never-builds-wall-pylon2-before-cannon1-even-with-workers"
              (and cw10-blocked-py2? cw10-built-can1-first?)
              (format "blockedPy2=~a can1First=~a holdActs=~s can1Acts=~s"
                      cw10-blocked-py2? cw10-built-can1-first? acts-cw10-hold acts-cw10-can1))

  ;; T10c: tvp-1base-2gas-cyclone requires factory-techlab on Base75689 (builds factory-techlab
  ;; on bare Factory, zero bare-Factory cyclone trains, zero premature widow-mine trains!).
  (define rt-cyc10 (make-live-bot-runtime #:bot-name 'Mothman-TC #:race 'Terran
                                          #:cheese-mode? #t #:cheese-profile 'tvp-1base-2gas-cyclone))
  (define acts-cyc10-bare
    (step-layer2-economy!
     rt-cyc10
     (mk-live-obs #:race 'Terran #:enemy-race 'Protoss #:frame 3600
                  #:minerals 200 #:gas 150 #:supply-used 22 #:supply-cap 47 #:army-supply 2
                  #:mineral-harvesters 14 #:vespene-harvesters 6
                  #:ally-buildings (list (mk-u 9801 'orbital-command 32.0 32.0 #:hp 1500.0)
                                         (mk-u 9802 'supply-depot 36.0 30.0 #:hp 400.0)
                                         (mk-u 9805 'supply-depot 38.0 30.0 #:hp 400.0)
                                         (mk-u 9808 'supply-depot 40.0 30.0 #:hp 400.0)
                                         (mk-u 9806 'refinery 30.0 26.0 #:hp 500.0)
                                         (mk-u 9807 'refinery 36.0 26.0 #:hp 500.0)
                                         (hash 'id 9803 'type 'barracks 'x 38.0 'y 34.0 'hp 1000.0 'max-hp 1000.0
                                               'build-progress 1.0 'add-on-tag 9809 'addon 'barracks-reactor 'order-count 0)
                                         (mk-u 9809 'barracks-reactor 40.5 33.5 #:hp 400.0)
                                         (hash 'id 9804 'type 'factory 'x 42.0 'y 34.0 'hp 1250.0 'max-hp 1250.0
                                               'build-progress 1.0 'add-on-tag 0 'order-count 0))
                  #:ally-units (append (list (mk-u 9840 'marine 36.0 34.0 #:hp 45.0)
                                             (mk-u 9841 'marine 37.0 34.0 #:hp 45.0))
                                       (mk-workers 'scv 22 9810 32.0 32.0)))))
  (define cyc10-built-tl?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'factory-techlab))) acts-cyc10-bare))
  (define cyc10-no-bare-cyclone?
    (not (ormap (lambda (a) (equal? a '(train cyclone))) acts-cyc10-bare)))
  (define cyc10-no-early-mine?
    (not (ormap (lambda (a) (equal? a '(train widow-mine))) acts-cyc10-bare)))
  (check-test "T10c-l87e-cyclone-requires-factory-techlab-on-base75689-and-gates-widow-mine"
              (and cyc10-built-tl? cyc10-no-bare-cyclone? cyc10-no-early-mine?)
              (format "builtTl=~a noBareCyc=~a noEarlyMine=~a acts=~s"
                      cyc10-built-tl? cyc10-no-bare-cyclone? cyc10-no-early-mine? acts-cyc10-bare))

  ;; T10d: Frame-0 inferred enemy-nat from 'expansion-locations keeps pvt-proxy-stargate-voidray
  ;; strictly >= 20t from off-axis enemy natural (even without 'enemy-natural-x!), AND
  ;; zvt-42d-queen-ling-nydus trains early safety Lings ahead of Stage 5 Drones with only 2 larva!
  (define rt-sg10 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                         #:cheese-mode? #t #:cheese-profile 'pvt-proxy-stargate-voidray))
  (define sg10-grids
    (hash 'width 180 'height 180
          'placement-ref (lambda (ix iy) (if (and (>= ix 8) (< ix 172) (>= iy 8) (< iy 172)) 1 0))
          'pathing-ref   (lambda (ix iy) (if (and (>= ix 8) (< ix 172) (>= iy 8) (< iy 172)) 1 0))
          'height-ref    (lambda (ix iy) 128)))
  ;; Off-axis real enemy natural at (150.0 . 122.0) with NO 'enemy-natural-x or 'enemy-expand-x on obs!
  (define sg10-obs
    (hash-remove
     (hash-remove
      (hash-set*
       (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 2100 ;; 93.75s >= dispatch 85s
                    #:minerals 200 #:gas 100 #:supply-used 19 #:supply-cap 23 #:army-supply 0
                    #:mineral-harvesters 15 #:vespene-harvesters 4
                    #:base-x 32.0 #:base-y 32.0 #:nat-x 32.0 #:nat-y 60.0
                    #:enemy-x 150.0 #:enemy-y 150.0
                    #:expansions (list (cons 32.0 32.0) (cons 32.0 60.0)
                                       (cons 150.0 150.0) (cons 150.0 122.0)
                                       (cons 118.0 150.0) (cons 90.0 90.0))
                    #:ally-buildings (list (mk-u 9901 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                           (mk-u 9902 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
                                           (mk-u 9903 'gateway 38.0 30.0 #:hp 500.0 #:shield 500.0)
                                           (mk-u 9904 'cybernetics-core 38.0 34.0 #:hp 550.0 #:shield 550.0))
                    #:ally-units (mk-workers 'probe 19 9910 32.0 32.0))
       'map-grids sg10-grids
       'expansion-locations (list (cons 32.0 32.0) (cons 32.0 60.0)
                                  (cons 150.0 150.0) (cons 150.0 122.0)
                                  (cons 118.0 150.0) (cons 90.0 90.0)))
      'enemy-expand-x)
     'enemy-expand-y))
  (step-layer2-economy! rt-sg10 sg10-obs)
  (define sg10-pxy (rt-cheese-proxy-xy rt-sg10))
  (define sg10-bxy (hash-ref (rt-cheese-state rt-sg10) 'proxy-battery-xy #f))
  (define sg10-d-enat
    (and (pair? sg10-pxy)
         (sqrt (+ (sqr (- (car sg10-pxy) 150.0)) (sqr (- (cdr sg10-pxy) 122.0))))))
  (define sg10-bat-d-enat
    (if (pair? sg10-bxy)
        (sqrt (+ (sqr (- (car sg10-bxy) 150.0)) (sqr (- (cdr sg10-bxy) 122.0))))
        99.0))
  (define sg10-hidden-ok? (and (real? sg10-d-enat) (>= sg10-d-enat 20.0) (>= sg10-bat-d-enat 18.0)))

  (define rt-nyd10 (make-live-bot-runtime #:bot-name 'Mothman-ZC #:race 'Zerg
                                          #:cheese-mode? #t #:cheese-profile 'zvt-42d-queen-ling-nydus))
  (define acts-nyd10
    (step-layer2-economy!
     rt-nyd10
     (hash-set*
      (mk-live-obs #:race 'Zerg #:enemy-race 'Terran #:frame 3360 ;; 150s >= 128s safety Lings
                   #:minerals 200 #:gas 50 #:supply-used 29 #:supply-cap 52 #:army-supply 0
                   #:mineral-harvesters 22 #:vespene-harvesters 3
                   #:ally-buildings (list (mk-u 9951 'hatchery 32.0 32.0 #:hp 1500.0)
                                          (mk-u 9952 'hatchery 56.0 32.0 #:hp 1500.0)
                                          (mk-u 9953 'hatchery 78.0 36.0 #:hp 1500.0)
                                          (mk-u 9954 'spawning-pool 36.0 32.0 #:hp 1000.0)
                                          (mk-u 9955 'extractor 30.0 26.0 #:hp 500.0))
                   #:ally-units (append (mk-workers 'drone 25 9960 32.0 32.0)
                                        (for/list ([i (in-range 4)])
                                          (mk-u (+ 9990 i) 'queen 34.0 32.0 #:hp 175.0))))
      'larva-count 2 'researched-upgrades '(metabolic-boost))))
  (define nyd10-trained-early-lings?
    (ormap (lambda (a) (equal? a '(train zergling))) acts-nyd10))
  (check-test "T10d-l87e-frame0-inferred-enemy-nat-hidden-proxy-and-42d-nydus-early-lings"
              (and sg10-hidden-ok? nyd10-trained-early-lings?)
              (format "sgHidden=~a dEnat=~a batDEnat=~a pxy=~s bxy=~s nydLing=~a"
                      sg10-hidden-ok? sg10-d-enat sg10-bat-d-enat sg10-pxy sg10-bxy nyd10-trained-early-lings?))

  ;; ===========================================================================
  ;; Loop 87F Track 2 Regression Tests (T11a..T11d): Ground-BFS Natural +
  ;; Frame-0 Cache Invalidation, Cannon Rush Deadlock Early-Abort,
  ;; pvt-4gate / pvz-8gate Commit Triggers, and 420G/6w Gas-Pull Floor.
  ;; ===========================================================================

  ;; T11a: Ground-BFS natural rejects cliff-blocked pocket base (20t Euclidean, >= 65t walk)
  ;; in favor of true natural (26t walk), AND invalidates Frame-0 defer-expansions placeholder!
  (define rt-bfs11 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                          #:cheese-mode? #t #:cheese-profile 'pvz-cannon-rush))
  ;; Cliff wall at y=136..140, x=130..175 blocks direct south walk from (150,150) to pocket (150,130)!
  (define bfs11-grids
    (hash 'width 180 'height 180
          'placement-ref (lambda (ix iy)
                           (if (and (>= ix 8) (< ix 172) (>= iy 8) (< iy 172)
                                    (not (and (>= ix 130) (<= ix 175) (>= iy 136) (<= iy 140))))
                               1 0))
          'pathing-ref   (lambda (ix iy)
                           (if (and (>= ix 8) (< ix 172) (>= iy 8) (< iy 172)
                                    (not (and (>= ix 130) (<= ix 175) (>= iy 136) (<= iy 140))))
                               1 0))
          'height-ref    (lambda (ix iy) 128)))
  (define bfs11-mins
    (list (hash 'id 11001 'type 'mineral-field 'x 118.0 'y 147.0)
          (hash 'id 11002 'type 'mineral-field 'x 118.0 'y 149.0)
          (hash 'id 11003 'type 'mineral-field 'x 118.0 'y 151.0)
          (hash 'id 11004 'type 'mineral-field 'x 119.0 'y 153.0)))
  ;; Tick 0 (f=0): empty expansions (defer-expansions?) + bogus straight-line enemy-natural=(126,126)
  (step-layer2-economy!
   rt-bfs11
   (hash-set*
    (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 0
                 #:minerals 50 #:gas 0 #:supply-used 12 #:supply-cap 15 #:army-supply 0
                 #:mineral-harvesters 12 #:vespene-harvesters 0
                 #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
                 #:enemy-x 150.0 #:enemy-y 150.0 #:enemy-exp-x 126.0 #:enemy-exp-y 126.0
                 #:expansions '()
                 #:ally-buildings (list (mk-u 11010 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0))
                 #:ally-units (mk-workers 'probe 12 11020 32.0 32.0))
    'enemy-natural-x 126.0 'enemy-natural-y 126.0
    'map-grids bfs11-grids 'mineral-patches bfs11-mins))
  (define bfs11-f0-used-exps? (hash-ref (rt-cheese-state rt-bfs11) 'proxy-xy-used-exps? #f))
  ;; Tick 1 (f=16, before dispatch!): real expansion-candidates arrive with cliff pocket (150,130)
  ;; and true walking natural (124,150) -> MUST invalidate f0 cache and anchor on (124,150)!
  (step-layer2-economy!
   rt-bfs11
   (hash-set*
    (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 16
                 #:minerals 70 #:gas 0 #:supply-used 12 #:supply-cap 15 #:army-supply 0
                 #:mineral-harvesters 12 #:vespene-harvesters 0
                 #:base-x 32.0 #:base-y 32.0 #:nat-x 56.0 #:nat-y 32.0
                 #:enemy-x 150.0 #:enemy-y 150.0 #:enemy-exp-x 126.0 #:enemy-exp-y 126.0
                 #:expansions (list (cons 32.0 32.0) (cons 56.0 32.0)
                                    (cons 150.0 150.0) (cons 150.0 130.0) (cons 124.0 150.0))
                 #:ally-buildings (list (mk-u 11010 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0))
                 #:ally-units (mk-workers 'probe 12 11020 32.0 32.0))
    'enemy-natural-x 126.0 'enemy-natural-y 126.0
    'map-grids bfs11-grids 'mineral-patches bfs11-mins))
  (define bfs11-pxy (rt-cheese-proxy-xy rt-bfs11))
  (define bfs11-used-bfs? (hash-ref (rt-cheese-state rt-bfs11) 'proxy-xy-used-bfs? #f))
  (define bfs11-d-true-nat (and (pair? bfs11-pxy) (dist2d (car bfs11-pxy) (cdr bfs11-pxy) 124.0 150.0)))
  (define bfs11-d-pocket   (and (pair? bfs11-pxy) (dist2d (car bfs11-pxy) (cdr bfs11-pxy) 150.0 130.0)))
  (check-test "T11a-l87f-ground-bfs-natural-rejects-cliff-pocket-and-invalidates-frame0-cache"
              (and (not bfs11-f0-used-exps?) bfs11-used-bfs?
                   (real? bfs11-d-true-nat) (<= bfs11-d-true-nat 14.5)
                   (real? bfs11-d-pocket)   (>= bfs11-d-pocket 18.0))
              (format "f0Exps=~a usedBfs=~a pxy=~s dTrueNat=~a dPocket=~a"
                      bfs11-f0-used-exps? bfs11-used-bfs? bfs11-pxy bfs11-d-true-nat bfs11-d-pocket))

  ;; T11b: Cannon Rush deadlock early-abort on (a) >= 3 pylon deaths & 0 cannons,
  ;; (b) >= 105s & >= 350M & 0 cannons, (c) >= 95s & >= 2 deaths & no live proxy probe,
  ;; while NOT aborting when a live proxy Cannon already exists!
  (define (mk-cr11-obs f mins bldgs units)
    (mk-live-obs #:race 'Protoss #:enemy-race 'Protoss #:frame f
                 #:minerals mins #:gas 0 #:supply-used 16 #:supply-cap 23 #:army-supply 0
                 #:mineral-harvesters 15 #:vespene-harvesters 0
                 #:ally-buildings bldgs #:ally-units units))
  (define cr11-home-bldgs
    (list (mk-u 11101 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 11102 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
          (mk-u 11103 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0)))
  (define cr11-home-probes (mk-workers 'probe 15 11110 32.0 32.0))
  ;; (a) 3 pylon deaths & 0 cannons -> immediate 'fallback!
  (define rt-cr11a (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                          #:cheese-mode? #t #:cheese-profile 'pvp-cannon-rush))
  (hash-set! (rt-cheese-state rt-cr11a) 'proxy-xy (cons 134.0 136.0))
  (hash-set! (rt-cheese-state rt-cr11a) 'cannon-pylon-deaths 3)
  (step-layer2-economy! rt-cr11a (mk-cr11-obs 1800 200 cr11-home-bldgs cr11-home-probes))
  (define cr11a-aborted? (and (eq? (rt-cheese-phase rt-cr11a) 'fallback) (not (cheese-mode-active? rt-cr11a))))
  ;; (b) >= 105s (f=2420 = 108s) & >= 350M (380M) & 0 cannons -> immediate 'fallback!
  (define rt-cr11b (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                          #:cheese-mode? #t #:cheese-profile 'pvp-cannon-rush))
  (hash-set! (rt-cheese-state rt-cr11b) 'proxy-xy (cons 134.0 136.0))
  (step-layer2-economy! rt-cr11b (mk-cr11-obs 2420 380 cr11-home-bldgs cr11-home-probes))
  (define cr11b-aborted? (and (eq? (rt-cheese-phase rt-cr11b) 'fallback) (not (cheese-mode-active? rt-cr11b))))
  ;; (c) >= 95s (f=2200 = 98s) & >= 2 deaths & NO live proxy probe -> immediate 'fallback!
  (define rt-cr11c (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                          #:cheese-mode? #t #:cheese-profile 'pvp-cannon-rush))
  (hash-set! (rt-cheese-state rt-cr11c) 'proxy-xy (cons 134.0 136.0))
  (hash-set! (rt-cheese-state rt-cr11c) 'cannon-pylon-deaths 2)
  (hash-set! (rt-cheese-state rt-cr11c) 'proxy-worker-tags '(999999)) ;; dead tag, no probe near proxy!
  (step-layer2-economy! rt-cr11c (mk-cr11-obs 2200 200 cr11-home-bldgs cr11-home-probes))
  (define cr11c-aborted? (and (eq? (rt-cheese-phase rt-cr11c) 'fallback) (not (cheese-mode-active? rt-cr11c))))
  ;; (d) >= 105s & >= 350M WITH live proxy Cannon -> stays active (does NOT abort)!
  (define rt-cr11d (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                          #:cheese-mode? #t #:cheese-profile 'pvp-cannon-rush))
  (hash-set! (rt-cheese-state rt-cr11d) 'proxy-xy (cons 134.0 136.0))
  (step-layer2-economy! rt-cr11d
                        (mk-cr11-obs 2464 400
                                     (cons (mk-u 11109 'photon-cannon 134.0 136.0 #:hp 150.0 #:shield 150.0)
                                           cr11-home-bldgs)
                                     cr11-home-probes))
  (define cr11d-kept-active? (cheese-mode-active? rt-cr11d))
  (check-test "T11b-l87f-cannon-rush-deadlock-early-abort-on-3-deaths-or-350m-or-probeless"
              (and cr11a-aborted? cr11b-aborted? cr11c-aborted? cr11d-kept-active?)
              (format "d3=~a m350=~a noProbe=~a liveCanKept=~a"
                      cr11a-aborted? cr11b-aborted? cr11c-aborted? cr11d-kept-active?))

  ;; T11c: Broadened commit triggers for pvt-proxy-4gate (4 combat units + proxy gate)
  ;; and pvz-32p-8gate (phasing Warp Prism + 6 Zealots) never stall in 'build -> 'fallback!
  (define rt-4g11 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                         #:cheese-mode? #t #:cheese-profile 'pvt-proxy-4gate-zealot-stalker))
  (hash-set! (rt-cheese-state rt-4g11) 'proxy-xy (cons 115.0 115.0))
  (run-l34 rt-4g11
           (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 3600 ;; 160.7s >= 155s
                        #:minerals 120 #:gas 40 #:supply-used 28 #:supply-cap 39 #:army-supply 8
                        #:mineral-harvesters 16 #:vespene-harvesters 3
                        #:ally-buildings (list (mk-u 11201 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                               (mk-u 11202 'gateway 115.0 115.0 #:hp 500.0 #:shield 500.0)
                                               (mk-u 11203 'cybernetics-core 38.0 34.0 #:hp 550.0 #:shield 550.0))
                        #:ally-units (append (for/list ([i (in-range 4)])
                                               (mk-u (+ 11210 i) 'stalker 118.0 118.0 #:hp 80.0 #:shield 80.0))
                                             (mk-workers 'probe 19 11220 32.0 32.0))))
  (define committed-4g11? (eq? (rt-cheese-phase rt-4g11) 'commit))

  (define rt-8g11 (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                         #:cheese-mode? #t #:cheese-profile 'pvz-32p-8gate-chargelot-prism))
  (run-l34 rt-8g11
           (hash-set
            (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 6160 ;; 275s >= 270s
                         #:minerals 200 #:gas 40 #:supply-used 46 #:supply-cap 78 #:army-supply 12
                         #:mineral-harvesters 26 #:vespene-harvesters 6
                         #:ally-buildings (list (mk-u 11251 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                (mk-u 11252 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
                                                (mk-u 11253 'warp-gate 36.0 28.0 #:hp 500.0 #:shield 500.0))
                         #:ally-units (append (list (mk-u 11260 'warp-prism-phasing 144.0 146.0 #:hp 80.0 #:shield 100.0 #:flying #t))
                                              (for/list ([i (in-range 6)])
                                                (mk-u (+ 11261 i) 'zealot 145.0 147.0 #:hp 100.0 #:shield 50.0))
                                              (mk-workers 'probe 32 11270 32.0 32.0)))
            'researched-upgrades '(warp-gate-research charge)))
  (define committed-8g11? (eq? (rt-cheese-phase rt-8g11) 'commit))
  (check-test "T11c-l87f-pvt-4gate-and-pvz-8gate-commit-triggers-never-stall-in-build"
              (and committed-4g11? committed-8g11?)
              (format "4g=~a(phase=~a) 8g=~a(phase=~a)"
                      committed-4g11? (rt-cheese-phase rt-4g11)
                      committed-8g11? (rt-cheese-phase rt-8g11)))

  ;; T11d (restored in Loop 87G): Duplicate wd-gas-mode safety valve triggers at >= 210G & < 100M
  ;; (> 3 gas harvesters) and stays off below 210G (195G/80M) or at <= 3 gas harvesters!
  (define gas11-bldgs
    (list (mk-u 11301 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 11302 'nexus 56.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (hash 'id 11303 'type 'assimilator 'x 28.0 'y 36.0 'hp 450.0 'max-hp 450.0 'shield 450.0 'max-shield 450.0
                'build-progress 1.0 'assigned-harvesters 3 'ideal-harvesters 3 'vespene-contents 1600)
          (hash 'id 11304 'type 'assimilator 'x 36.0 'y 28.0 'hp 450.0 'max-hp 450.0 'shield 450.0 'max-shield 450.0
                'build-progress 1.0 'assigned-harvesters 3 'ideal-harvesters 3 'vespene-contents 1600)))
  (define gas11-probes-6g
    (append (for/list ([i (in-range 3)])
              (hash 'id (+ 11310 i) 'type 'probe 'x 28.5 'y 35.5 'hp 20.0 'max-hp 20.0 'shield 20.0 'max-shield 20.0
                    'order-ability-id 295 'order-target-id 11303))
            (for/list ([i (in-range 3)])
              (hash 'id (+ 11313 i) 'type 'probe 'x 35.5 'y 28.5 'hp 20.0 'max-hp 20.0 'shield 20.0 'max-shield 20.0
                    'order-ability-id 295 'order-target-id 11304))
            (mk-workers 'probe 30 11320 32.0 32.0)))
  (define acts-gas11-no-pull
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7200
                  #:minerals 80 #:gas 195 #:supply-used 72 #:supply-cap 94 #:army-supply 30
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-buildings gas11-bldgs #:ally-units gas11-probes-6g)))
  (define gas11-no-pull-at-195g?
    (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'rebalance-gas-to-minerals))) acts-gas11-no-pull)))
  (define acts-gas11-pull
    (step-layer2-economy!
     (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
     (mk-live-obs #:race 'Protoss #:enemy-race 'Terran #:frame 7200
                  #:minerals 80 #:gas 215 #:supply-used 72 #:supply-cap 94 #:army-supply 30
                  #:mineral-harvesters 30 #:vespene-harvesters 6
                  #:ally-buildings gas11-bldgs #:ally-units gas11-probes-6g)))
  (define gas11-pulls-at-215g?
    (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'rebalance-gas-to-minerals))) acts-gas11-pull) #t))
  (check-test "T11d-l87g-wd-gas-mode-restored-210g-safety-valve-and-3w-floor"
              (and gas11-no-pull-at-195g? gas11-pulls-at-215g?)
              (format "noPull195g=~a pull215g=~a" gas11-no-pull-at-195g? gas11-pulls-at-215g?))

  ;; T11e: Cannon Rush 0-supply commit fix: 1 proxy Photon Cannon with 0 combat supply commits
  ;; immediately at 100s, then transitions cleanly into 'follow-up releasing proxy probe, stopping
  ;; cannon spam, and immediately building home Gateway #1!
  (define rt-cr11e (make-live-bot-runtime #:bot-name 'Mothman-PC #:race 'Protoss
                                          #:cheese-mode? #t #:cheese-profile 'pvz-cannon-rush))
  (hash-set! (rt-cheese-state rt-cr11e) 'proxy-xy (cons 134.0 136.0))
  (hash-set! (rt-cheese-state rt-cr11e) 'proxy-wp (cons 134.0 136.0))
  (define cr11e-bldgs
    (list (mk-u 11401 'nexus 32.0 32.0 #:hp 1000.0 #:shield 1000.0)
          (mk-u 11402 'pylon 36.0 32.0 #:hp 200.0 #:shield 200.0)
          (mk-u 11403 'forge 38.0 30.0 #:hp 400.0 #:shield 400.0)
          (mk-u 11404 'pylon 132.0 136.0 #:hp 200.0 #:shield 200.0)
          (mk-u 11405 'photon-cannon 134.0 136.0 #:hp 150.0 #:shield 150.0)))
  ;; Tick 1: f=2240 (100.0s), 0 combat supply, 1 proxy Cannon -> commits immediately!
  (step-layer2-economy!
   rt-cr11e
   (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 2240
                #:minerals 180 #:gas 0 #:supply-used 17 #:supply-cap 31 #:army-supply 0
                #:mineral-harvesters 17 #:vespene-harvesters 0
                #:ally-buildings cr11e-bldgs
                #:ally-units (mk-workers 'probe 17 11410 32.0 32.0)))
  (define cr11e-committed-at-100s? (eq? (rt-cheese-phase rt-cr11e) 'commit))
  ;; Tick 2: f=3360 (150.0s >= edge-sec=145s & >= 30s post-commit) with 6 enemy workers killed ->
  ;; transitions to 'follow-up, stops cannon spam, and immediately emits (build gateway ...)!
  (define acts-cr11e-fu
    (step-layer2-economy!
     rt-cr11e
     (hash-set
      (mk-live-obs #:race 'Protoss #:enemy-race 'Zerg #:frame 3360
                   #:minerals 220 #:gas 0 #:supply-used 17 #:supply-cap 31 #:army-supply 0
                   #:mineral-harvesters 17 #:vespene-harvesters 0
                   #:ally-buildings cr11e-bldgs
                   #:ally-units (mk-workers 'probe 17 11410 32.0 32.0))
      'enemy-workers-killed 6)))
  (define cr11e-in-followup? (eq? (rt-cheese-phase rt-cr11e) 'follow-up))
  (define cr11e-built-gw?
    (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts-cr11e-fu))
  (define cr11e-no-cannon-spam?
    (not (ormap (lambda (a) (and (pair? a) (memq (car a) '(build build-proxy)) (eq? (second a) 'photon-cannon)))
                acts-cr11e-fu)))
  (check-test "T11e-l87f-cannon-rush-zero-supply-commit-and-followup-gateway-unlock"
              (and cr11e-committed-at-100s? cr11e-in-followup? cr11e-built-gw? cr11e-no-cannon-spam?)
              (format "comm100=~a fu=~a gw=~a noCanSpam=~a acts=~s"
                      cr11e-committed-at-100s? cr11e-in-followup? cr11e-built-gw? cr11e-no-cannon-spam? acts-cr11e-fu)))

(printf "=== Summary: ~a passed, ~a failed ===\n" pass-count fail-count)
(unless (= fail-count 0)
  (exit 1))
