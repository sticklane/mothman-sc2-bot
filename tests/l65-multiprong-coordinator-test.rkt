#lang racket/base

;; =============================================================================
;; `tests/l65-multiprong-coordinator-test.rkt`
;; Architecture Phase B + Loop 65 Lane A — Multiprong Coordinator Test Suite
;;
;; Verifies:
;;   - L65-A0: Hard live-match / >=2-TH / >=4:00 / endgame / cleared no-op guards
;;             (0/278 Tactics Arena guarantee)
;;   - L65-A1: Mode 1 Defensive Proportional Split (<=12 sup) vs Immediate Full
;;             Rotation (>12 sup / >=1200 val), AA preference, zero passive 'move,
;;             and 'threat-veto override-signal logging in arbiter-ledger
;;   - L65-A2: Mode 2 Counter-Backstab / Runby capped 10-20% pack, >=20t flank
;;             clearance (4-corner symmetric), flank->strike phase transition,
;;             home-defense safety guard, >=1.25x auto-withdraw & 560f timeout
;;   - L65-A3: Mode 3 Offensive Base-to-Base Rotation around fortified/losing
;;             Base A -> Base B, <=7.5t frontline lock exemption, 224f dwell,
;;             and 336f per-pair anti-oscillation cooldown
;;   - L65-A4: Mode 4 Synchronized 2-Prong Window (hold while ETA_A > 10s,
;;             release at <=10s or 180f anti-stall), arbiter-resolve! same-step
;;             alternatives cascade, claimed-tags & higher role-lease respect,
;;             and >=3 threat-veto hysteresis cooldown
;;   - L65-A5: Frame-rewind auto-reset hygiene & <0.25 ms/step CPU budget
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         "../lib/tactics/multiprong-coordinator.rkt"
         "../lib/engine/arbiter.rkt"
         "../lib/sc2-game-constants.rkt")

(define passed 0)
(define failed 0)

(define (check! cond msg)
  (if cond
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (printf "FAIL: ~a\n" msg))))

(define (mk-u id type x y [flying? #f])
  (hasheq 'id id 'type type 'x (exact->inexact x) 'y (exact->inexact y)
          'hp 80.0 'hp-max 80.0 'flying? flying?))

(define (mk-th id type x y)
  (hasheq 'id id 'type type 'x (exact->inexact x) 'y (exact->inexact y)
          'build-progress 1.0 'hp 1500.0))

(define (dist2d ax ay bx by)
  (sqrt (+ (sqr (- ax bx)) (sqr (- ay by)))))

(define ally-ths-2
  (list (mk-th 1 'hatchery 30.0 30.0)
        (mk-th 2 'hatchery 55.0 34.0)))

(define enemy-ths-2
  (list (mk-th 901 'nexus 155.0 155.0)
        (mk-th 902 'nexus 155.0 110.0)))

(define enemy-ths-3
  (list (mk-th 901 'nexus 155.0 155.0)
        (mk-th 902 'nexus 155.0 110.0)
        (mk-th 903 'nexus 115.0 155.0)))

;; =============================================================================
;; L65-A0: Hard Global Guards (0/278 Tactics Arena Untouched)
;; =============================================================================
(let ()
  (define st (make-multiprong-state))
  (define ledger (make-arbiter-ledger))
  (define army (for/list ([i (in-range 20)]) (mk-u (+ 100 i) 'stalker 110.0 110.0)))
  (define enemies (for/list ([i (in-range 6)]) (mk-u (+ 500 i) 'marine 56.0 36.0)))

  ;; 1. Non-live Arena drill (`live-obs? = #f`) -> strict no-op
  (define r-arena
    (step-multiprong-coordinator!
     st #:frame 7000 #:live-obs? #f #:race 'Protoss
     #:ally-units army #:combat-units army #:ally-townhalls ally-ths-2
     #:enemy-units enemies #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (and (eq? (multiprong-result-mode r-arena) 'inactive)
               (null? (multiprong-result-actions r-arena))
               (set-empty? (multiprong-result-handled-tags r-arena)))
          "L65-A0(1): live-obs?=#f MUST be a strict no-op (0/278 Arena)")

  ;; 2. Pre-4:00 (`frame = 5375 < 5376`) -> strict no-op
  (define r-early
    (step-multiprong-coordinator!
     st #:frame 5375 #:live-obs? #t #:race 'Protoss
     #:ally-units army #:combat-units army #:ally-townhalls ally-ths-2
     #:enemy-units enemies #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (and (eq? (multiprong-result-mode r-early) 'inactive)
               (null? (multiprong-result-actions r-early)))
          "L65-A0(2): frame < 5376 (<4:00) MUST be a strict no-op")

  ;; 3. 1-base (`(length ally-townhalls) < 2`) -> strict no-op
  (define r-1base
    (step-multiprong-coordinator!
     st #:frame 7000 #:live-obs? #t #:race 'Protoss
     #:ally-units army #:combat-units army #:ally-townhalls (list (car ally-ths-2))
     #:enemy-units enemies #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (eq? (multiprong-result-mode r-1base) 'inactive)
          "L65-A0(3): < 2 ally townhalls MUST be a strict no-op")

  ;; 4. Endgame hunt / enemy-main-cleared -> strict no-op
  (define r-eg
    (step-multiprong-coordinator!
     st #:frame 7000 #:live-obs? #t #:race 'Protoss
     #:ally-units army #:combat-units army #:ally-townhalls ally-ths-2
     #:enemy-units enemies #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:endgame-hunt-active? #t))
  (define r-clr
    (step-multiprong-coordinator!
     st #:frame 7000 #:live-obs? #t #:race 'Protoss
     #:ally-units army #:combat-units army #:ally-townhalls ally-ths-2
     #:enemy-units enemies #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:enemy-main-cleared? #t))
  (check! (and (eq? (multiprong-result-mode r-eg) 'inactive)
               (eq? (multiprong-result-mode r-clr) 'inactive))
          "L65-A0(4): endgame-hunt and enemy-main-cleared MUST be strict no-ops"))

;; =============================================================================
;; L65-A1: Mode 1 Defensive Proportional Split vs Immediate Full Rotation
;; =============================================================================
(let ()
  (define st (make-multiprong-state))
  (define ledger (make-arbiter-ledger))
  (define leases (make-hasheqv))
  ;; 20 Stalkers (40 sup) forward at (110, 110) — >=25t away from TH_2 (55, 34)
  (define army
    (append (for/list ([i (in-range 4)]) (mk-u (+ 100 i) 'stalker 85.0 75.0))
            (for/list ([i (in-range 16)]) (mk-u (+ 110 i) 'stalker 118.0 118.0))))
  ;; Small harass: 4 Marines (4 sup, 200 val) hitting TH_2 (55, 34)
  (define small-harass
    (for/list ([i (in-range 4)]) (mk-u (+ 500 i) 'marine (+ 56.0 i) 36.0)))

  (define r-split
    (step-multiprong-coordinator!
     st #:frame 7000 #:live-obs? #t #:race 'Protoss
     #:ally-units army #:combat-units army #:ally-townhalls ally-ths-2
     #:enemy-units small-harass #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger #:role-leases leases))
  (define split-cnt (set-count (multiprong-result-handled-tags r-split)))
  (check! (and (eq? (multiprong-result-mode r-split) 'defensive-split)
               (>= split-cnt 3)
               (<= split-cnt 6)
               (pair? (multiprong-result-actions r-split))
               ;; Must pick closest units first (100..103)
               (set-member? (multiprong-result-handled-tags r-split) 100)
               ;; Zero passive 'move in defense response (`zero_fire_retreat = 0`)
               (andmap (lambda (a) (eq? (car a) 'attack-pos))
                       (multiprong-result-actions r-split))
               ;; Synced into BOTH arbiter-ledger AND caller role-leases
               (unit-role-lease? (hash-ref (arbiter-ledger-role-leases ledger) 100 #f))
               (unit-role-lease? (hash-ref leases 100 #f)))
          (format "L65-A1(1): Small harass (<=12 sup) leases ONLY proportional nearby split (got mode=~a cnt=~a)"
                  (multiprong-result-mode r-split) split-cnt))

  ;; Air harass: 2 Banshees hitting TH_2 -> prefers AA units (hydralisk over roach!)
  (define st-aa (make-multiprong-state))
  (define z-army
    (append (for/list ([i (in-range 8)]) (mk-u (+ 200 i) 'roach 95.0 95.0))
            (for/list ([i (in-range 6)]) (mk-u (+ 220 i) 'hydralisk 105.0 105.0))))
  (define banshees (list (mk-u 601 'banshee 56.0 35.0 #t) (mk-u 602 'banshee 57.0 36.0 #t)))
  (define r-aa
    (step-multiprong-coordinator!
     st-aa #:frame 7200 #:live-obs? #t #:race 'Zerg
     #:ally-units z-army #:combat-units z-army #:ally-townhalls ally-ths-2
     #:enemy-units banshees #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (check! (and (eq? (multiprong-result-mode r-aa) 'defensive-split)
               (set-member? (multiprong-result-handled-tags r-aa) 220))
          "L65-A1(2): Air harass proportional split prefers AA units (Hydralisks over Roaches)")

  ;; Major push (>12 sup / >=1200 val): 10 Roaches (20 sup) hitting TH_2 -> FULL rotation + logs 'threat-veto!
  (define st-maj (make-multiprong-state))
  (define led-maj (make-arbiter-ledger))
  (define major-push
    (for/list ([i (in-range 10)]) (mk-u (+ 700 i) 'roach (+ 54.0 (* 0.5 i)) 36.0)))
  (define r-full
    (step-multiprong-coordinator!
     st-maj #:frame 7400 #:live-obs? #t #:race 'Protoss
     #:ally-units army #:combat-units army #:ally-townhalls ally-ths-2
     #:enemy-units major-push #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger led-maj))
  (define vetoes (arbiter-feedback-for led-maj 'multiprong-coordinator #:reason 'threat-veto))
  (check! (and (eq? (multiprong-result-mode r-full) 'defensive-full-rotate)
               (= (set-count (multiprong-result-handled-tags r-full)) (length army))
               (andmap (lambda (a) (eq? (car a) 'attack-pos)) (multiprong-result-actions r-full))
               (>= (length vetoes) 1))
          (format "L65-A1(3): Major push triggers immediate FULL rotation & logs 'threat-veto (mode=~a claimed=~a/~a vetoes=~a)"
                  (multiprong-result-mode r-full)
                  (set-count (multiprong-result-handled-tags r-full))
                  (length army)
                  (length vetoes))))

;; =============================================================================
;; L65-A2: Mode 2 Counter-Backstab / Runby + Flank Clearance + Safety Guards
;; =============================================================================
(let ()
  ;; 4-corner symmetry check on `compute-flank-waypoint`
  (for ([cfg (in-list (list (list 30.0 30.0 160.0 160.0 95.0 95.0)
                            (list 160.0 30.0 30.0 160.0 95.0 95.0)
                            (list 160.0 160.0 30.0 30.0 95.0 95.0)
                            (list 30.0 160.0 160.0 30.0 95.0 95.0)))])
    (define-values (wx wy)
      (compute-flank-waypoint (first cfg) (second cfg) (third cfg) (fourth cfg)
                              (fifth cfg) (sixth cfg) 200.0 200.0))
    (define d-en (dist2d wx wy (fifth cfg) (sixth cfg)))
    (check! (and (>= d-en 20.0) (>= wx 8.0) (<= wx 192.0) (>= wy 8.0) (<= wy 192.0))
            (format "L65-A2(0): 4-corner flank waypoint >=20t clear of enemy centroid (d=~a pt=(~a,~a))"
                    d-en wx wy)))

  ;; Counter-backstab: Enemy main army (10 Stalkers, 20 sup) parked at mid-map (85, 95)
  ;; >= 30t away from exposed outer enemy base (160, 45); ally army (36 sup) safely at home (40, 40)
  (define st (make-multiprong-state))
  (define ledger (make-arbiter-ledger))
  (define ally-z
    (append (for/list ([i (in-range 12)]) (mk-u (+ 100 i) 'roach 42.0 42.0))     ;; 24 sup core
            (for/list ([i (in-range 16)]) (mk-u (+ 150 i) 'zergling 46.0 38.0)))) ;; 8 sup fast pack
  (define enemy-mid
    (for/list ([i (in-range 10)]) (mk-u (+ 500 i) 'stalker (+ 84.0 (* 0.5 i)) 95.0)))
  (define enemy-bases-bs
    (list (mk-th 901 'nexus 160.0 155.0)
          (mk-th 902 'nexus 160.0 45.0))) ;; exposed outer base >= 30t from (85, 95)!

  (define r-bs1
    (step-multiprong-coordinator!
     st #:frame 8000 #:live-obs? #t #:race 'Zerg
     #:ally-units ally-z #:combat-units ally-z #:ally-townhalls ally-ths-2
     #:enemy-units enemy-mid #:enemy-townhalls enemy-bases-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (define bs-tags (multiprong-result-handled-tags r-bs1))
  (define bs-act0 (and (pair? (multiprong-result-actions r-bs1))
                       (car (multiprong-result-actions r-bs1))))
  (check! (and (eq? (multiprong-result-mode r-bs1) 'counter-backstab)
               (>= (set-count bs-tags) 4)
               (<= (set-count bs-tags) 14)
               ;; Must prioritize Zerglings (>= 150) over slow core Roaches!
               (andmap (lambda (tid) (>= tid 150)) (set->list bs-tags))
               ;; Flank waypoint must be >= 20t clear of enemy centroid (86, 95)
               bs-act0
               (>= (dist2d (caddr bs-act0) (cadddr bs-act0) 86.25 95.0) 20.0))
          (format "L65-A2(1): Counter-backstab dispatches 10-20% Zergling pack via >=20t flank (mode=~a n=~a act=~s)"
                  (multiprong-result-mode r-bs1) (set-count bs-tags) bs-act0))

  ;; Phase transition: once pack nears Target B (160, 45), switches to 'strike ('attack-pos)!
  (define ally-z-near-b
    (append (for/list ([i (in-range 12)]) (mk-u (+ 100 i) 'roach 42.0 42.0))
            (for/list ([i (in-range 16)])
              (if (set-member? bs-tags (+ 150 i))
                  (mk-u (+ 150 i) 'zergling 148.0 46.0)
                  (mk-u (+ 150 i) 'zergling 46.0 38.0)))))
  (define r-bs2
    (step-multiprong-coordinator!
     st #:frame 8120 #:live-obs? #t #:race 'Zerg
     #:ally-units ally-z-near-b #:combat-units ally-z-near-b #:ally-townhalls ally-ths-2
     #:enemy-units enemy-mid #:enemy-townhalls enemy-bases-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (and (eq? (multiprong-result-mode r-bs2) 'counter-backstab)
               (pair? (multiprong-result-actions r-bs2))
               (andmap (lambda (a) (eq? (car a) 'attack-pos)) (multiprong-result-actions r-bs2)))
          "L65-A2(2): Backstab pack transitions cleanly to 'strike ('attack-pos) near exposed base")

  ;; Auto-withdraw when defenders >= 1.25x pack value arrive at Target B!
  (define enemy-def-b
    (append enemy-mid
            (for/list ([i (in-range 6)]) (mk-u (+ 600 i) 'zealot 158.0 46.0))))
  (define r-bs-abort
    (step-multiprong-coordinator!
     st #:frame 8160 #:live-obs? #t #:race 'Zerg
     #:ally-units ally-z-near-b #:combat-units ally-z-near-b #:ally-townhalls ally-ths-2
     #:enemy-units enemy-def-b #:enemy-townhalls enemy-bases-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (eq? (multiprong-result-mode r-bs-abort) 'inactive)
          "L65-A2(3): Backstab auto-withdraws when >= 1.25x enemy defenders arrive")

  ;; Safety guard: NEVER fires when defensive-muster-active? is #t or losing home fight!
  (define st-safe (make-multiprong-state))
  (define r-muster
    (step-multiprong-coordinator!
     st-safe #:frame 8000 #:live-obs? #t #:race 'Zerg
     #:ally-units ally-z #:combat-units ally-z #:ally-townhalls ally-ths-2
     #:enemy-units enemy-mid #:enemy-townhalls enemy-bases-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0
     #:defensive-muster-active? #t))
  (check! (eq? (multiprong-result-mode r-muster) 'inactive)
          "L65-A2(4): Backstab strictly suppressed during defensive-muster-active?"))

;; =============================================================================
;; L65-A3: Mode 3 Offensive Base-to-Base Rotation + 224f Dwell + 336f Cooldown
;; =============================================================================
(let ()
  (define st (make-multiprong-state))
  (define ledger (make-arbiter-ledger))
  ;; Attacking mobile force (10 free Stalkers = 20 sup) outside fortified Enemy Base A (155, 155),
  ;; all > 12t from enemy -> rotates cohesively to undefended Base B!
  (define atk-army
    (for/list ([i (in-range 10)]) (mk-u (+ 310 i) 'stalker 138.0 144.0)))
  ;; Base A fortified with >= 500 static/siege value (2 Bunkers + 2 Sieged Tanks = 950 val)
  (define fort-a
    (list (mk-u 801 'siege-tank-sieged 154.0 154.0)
          (mk-u 802 'siege-tank-sieged 156.0 153.0)
          (mk-u 803 'marine 152.0 152.0)))
  (define fort-bldgs
    (list (mk-th 901 'command-center 155.0 155.0)
          (mk-th 902 'command-center 155.0 110.0)
          (hasheq 'id 951 'type 'bunker 'x 153.0 'y 153.0 'build-progress 1.0)
          (hasheq 'id 952 'type 'bunker 'x 156.0 'y 152.0 'build-progress 1.0)))

  (define r-rot1
    (step-multiprong-coordinator!
     st #:frame 9000 #:live-obs? #t #:race 'Protoss
     #:ally-units atk-army #:combat-units atk-army #:ally-townhalls ally-ths-2
     #:enemy-units fort-a #:enemy-townhalls enemy-ths-2 #:enemy-buildings fort-bldgs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (and (eq? (multiprong-result-mode r-rot1) 'offensive-rotate)
               (pair? (multiprong-result-active-prong-target r-rot1))
               (< (dist2d (car (multiprong-result-active-prong-target r-rot1))
                          (cdr (multiprong-result-active-prong-target r-rot1))
                          155.0 110.0) 1.0)
               (= (set-count (multiprong-result-handled-tags r-rot1)) 10)
               (set-member? (multiprong-result-handled-tags r-rot1) 310)
               (andmap (lambda (a) (eq? (car a) 'attack-pos)) (multiprong-result-actions r-rot1)))
          (format "L65-A3(1): Fortified Base A rotates cohesive >=20-sup free army (>12t) to undefended Base B (mode=~a tgt=~s)"
                  (multiprong-result-mode r-rot1) (multiprong-result-active-prong-target r-rot1)))

  ;; Inside 224f dwell (+100f): stays committed on Base B even if Base B gains static def!
  (define r-dwell
    (step-multiprong-coordinator!
     st #:frame 9100 #:live-obs? #t #:race 'Protoss
     #:ally-units atk-army #:combat-units atk-army #:ally-townhalls ally-ths-2
     #:enemy-units (list (mk-u 805 'siege-tank-sieged 155.0 110.0))
     #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (and (eq? (multiprong-result-mode r-dwell) 'offensive-rotate)
               (< (dist2d (car (multiprong-result-active-prong-target r-dwell))
                          (cdr (multiprong-result-active-prong-target r-dwell))
                          155.0 110.0) 1.0))
          "L65-A3(2): Rotation honors 224f minimum dwell without bouncing back")

  ;; Past 224f dwell (+250f < 336f cooldown): now at fortified Base B, pair (A,B) is STILL on 336f cooldown!
  (define army-at-b
    (for/list ([i (in-range 10)]) (mk-u (+ 310 i) 'stalker 138.0 110.0)))
  (define fort-b
    (list (mk-u 811 'siege-tank-sieged 155.0 110.0)
          (mk-u 812 'siege-tank-sieged 156.0 112.0)))
  (define r-cd
    (step-multiprong-coordinator!
     st #:frame 9250 #:live-obs? #t #:race 'Protoss
     #:ally-units army-at-b #:combat-units army-at-b #:ally-townhalls ally-ths-2
     #:enemy-units fort-b #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (not (eq? (multiprong-result-mode r-cd) 'offensive-rotate))
          (format "L65-A3(3): 336f per-pair cooldown blocks A<->B ping-pong oscillation at +250f (mode=~a)"
                  (multiprong-result-mode r-cd)))

  ;; Past 336f cooldown (+360f): rotation B -> A unlocks cleanly!
  (define r-unlock
    (step-multiprong-coordinator!
     st #:frame 9360 #:live-obs? #t #:race 'Protoss
     #:ally-units army-at-b #:combat-units army-at-b #:ally-townhalls ally-ths-2
     #:enemy-units fort-b #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (check! (and (eq? (multiprong-result-mode r-unlock) 'offensive-rotate)
               (< (dist2d (car (multiprong-result-active-prong-target r-unlock))
                          (cdr (multiprong-result-active-prong-target r-unlock))
                          155.0 155.0) 1.0))
          "L65-A3(4): Rotation unlocks cleanly once 336f cooldown expires"))

;; =============================================================================
;; L65-A4: Mode 4 Synced 2-Prong + 180f Anti-Stall + Arbiter Alternatives + Leases
;; =============================================================================
(let ()
  (define st (make-multiprong-state))
  (define ledger (make-arbiter-ledger))
  ;; Main army (16 Stalkers = 32 sup) closing on Base A (155,155) from (120,140) (~38t -> ETA_A ~10.9s > 10s!)
  ;; Secondary fast prong (4 Zealots = 8 sup) staged near Base B (155,110) at (142,108) (~13t -> ETA_B ~3.1s < ETA_A-6s!)
  ;; Total = 40 sup >= 36.0 sup (70% core = 28 sup reserved on Stalkers, Zealots <= 10.0 sup prong cap!)
  (define p-army
    (append (for/list ([i (in-range 16)]) (mk-u (+ 400 i) 'stalker 120.0 140.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 450 i) 'zealot 142.0 108.0))))
  (define enemy-at-a
    (list (mk-u 851 'stalker 155.0 155.0) (mk-u 852 'stalker 154.0 154.0)))

  ;; Step 1: ETA_A > 10s -> holds secondary prong at safe flank staging waypoint!
  (define r-hold
    (step-multiprong-coordinator!
     st #:frame 10000 #:live-obs? #t #:race 'Protoss
     #:ally-units p-army #:combat-units p-army #:ally-townhalls ally-ths-2
     #:enemy-units enemy-at-a #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (define act-hold (and (pair? (multiprong-result-actions r-hold))
                        (car (multiprong-result-actions r-hold))))
  (check! (and (eq? (multiprong-result-mode r-hold) 'two-prong-sync)
               act-hold
               ;; Holding at flank waypoint (not yet directly on Base B 155,110)
               (> (dist2d (caddr act-hold) (cadddr act-hold) 155.0 110.0) 1.0)
               ;; Secondary prong claims Zealots, NOT main army core Stalkers
               (set-member? (multiprong-result-handled-tags r-hold) 450)
               (not (set-member? (multiprong-result-handled-tags r-hold) 400)))
          (format "L65-A4(1): 2-prong holds secondary prong while ETA_A > 10s (mode=~a act=~s)"
                  (multiprong-result-mode r-hold) act-hold))

  ;; Step 2 (+185f >= 180f anti-stall): releases secondary prong directly onto Base B with 'attack-pos!
  (define r-rel
    (step-multiprong-coordinator!
     st #:frame 10185 #:live-obs? #t #:race 'Protoss
     #:ally-units p-army #:combat-units p-army #:ally-townhalls ally-ths-2
     #:enemy-units enemy-at-a #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (define act-rel (and (pair? (multiprong-result-actions r-rel))
                       (car (multiprong-result-actions r-rel))))
  (check! (and (eq? (multiprong-result-mode r-rel) 'two-prong-sync)
               act-rel
               (eq? (car act-rel) 'attack-pos)
               (< (dist2d (caddr act-rel) (cadddr act-rel) 155.0 110.0) 1.0))
          (format "L65-A4(2): 180f anti-stall releases secondary prong directly onto Base B ('attack-pos, act=~s)"
                  act-rel))

  ;; Respect `claimed-tags` and higher-priority `role-leases` (`detector-escort` prio 75 > `strike-group` 55)
  (define st-cl (make-multiprong-state))
  (define led-cl (make-arbiter-ledger))
  (define ext-leases (make-hasheqv))
  (acquire-unit-lease! ext-leases 450 'detector-escort 10000 200)
  (define r-cl
    (step-multiprong-coordinator!
     st-cl #:frame 10050 #:live-obs? #t #:race 'Protoss
     #:ally-units p-army #:combat-units p-army #:ally-townhalls ally-ths-2
     #:enemy-units enemy-at-a #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:claimed-tags (seteqv 451)
     #:arbiter-ledger led-cl
     #:role-leases ext-leases))
  (check! (and (not (set-member? (multiprong-result-handled-tags r-cl) 450))
               (not (set-member? (multiprong-result-handled-tags r-cl) 451)))
          "L65-A4(3): Strictly honors claimed-tags (451) & higher-priority role-leases (450 detector-escort)")

  ;; Arbiter `alternatives` cascade & `override-signal` logging when primary's tags are locked in ledger!
  (define st-alt (make-multiprong-state))
  (define led-alt (make-arbiter-ledger))
  ;; Lock 450..453 directly inside `arbiter-ledger` at higher priority ('detector-escort prio 75)
  ;; so `mp-two-prong-sync`'s primary pack fails `'unit-claimed-higher-priority` inside `arbiter-resolve!`
  ;; and cascades cleanly to its alternative or records the override-signal!
  (for ([tid (in-list '(450 451 452 453))])
    (hash-set! (arbiter-ledger-role-leases led-alt) tid
               (unit-role-lease 'detector-escort 75 0 0.0 0.0 10500)))
  (define r-alt
    (step-multiprong-coordinator!
     st-alt #:frame 10100 #:live-obs? #t #:race 'Protoss
     #:ally-units p-army #:combat-units p-army #:ally-townhalls ally-ths-2
     #:enemy-units (for/list ([i (in-range 6)]) (mk-u (+ 860 i) 'stalker 155.0 155.0))
     #:enemy-townhalls enemy-ths-3
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger led-alt))
  (define sigs-alt (arbiter-feedback-for led-alt 'multiprong-coordinator))
  (check! (and (not (set-member? (multiprong-result-handled-tags r-alt) 450))
               (pair? sigs-alt)
               (override-signal? (car sigs-alt)))
          (format "L65-A4(4): Arbiter adjudicates ledger leases & records override-signal (sigs=~a mode=~a)"
                  (length sigs-alt) (multiprong-result-mode r-alt))))

;; =============================================================================
;; L65-A6 (`#1845`): Protoss Empty-Warp-Prism Chargelot Backstab (`'prism-warp-backstab`)
;; =============================================================================
(let ()
  (define st (make-multiprong-state))
  (define led (make-arbiter-ledger))
  (define p-ths (list (mk-th 1 'nexus 30.0 30.0) (mk-th 2 'nexus 55.0 34.0)))
  (define e-ths (list (mk-th 10 'orbital-command 165.0 165.0)
                      (mk-th 11 'orbital-command 162.0 130.0)
                      (mk-th 12 'orbital-command 120.0 168.0)))
  ;; Enemy army pushed toward middle `(95, 95)` -> `>= 30t` from exposed base `(120, 168)`
  (define e-mid-army
    (for/list ([i (in-range 8)])
      (mk-u (+ 800 i) 'marine (+ 92.0 (modulo i 4)) (+ 92.0 (quotient i 4)))))

  ;; (1) Loop 65D (`#1891`/`#1892`) decoupled proactive Prism transit vs warp-in readiness:
  ;;     - Lacks transit readiness (`rwg=1, charge=#f`), loaded Prism, or home breach -> inactive!
  ;;     - `minerals=50, rwg=0, supply-left=0, charge=#t` -> PROACTIVELY flies flank & phases at pocket
  ;;       with `active-prong-target = #f` until `rwg >= 1 & min >= 100 & sup >= 2`!
  (define empty-prism-home (mk-u 901 'warp-prism 45.0 48.0))
  (define loaded-prism-home (hasheq 'id 902 'type 'warp-prism 'x 45.0 'y 48.0 'cargo-space-taken 4))
  (define r-low-wg-no-charge
    (step-multiprong-coordinator!
     st #:frame 7000 #:live-obs? #t #:race 'Protoss
     #:ally-units (list empty-prism-home) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:ready-warp-gates 1 #:minerals 300 #:supply-left 8 #:charge-researched? #f))
  (define r-loaded
    (step-multiprong-coordinator!
     st #:frame 7004 #:live-obs? #t #:race 'Protoss
     #:ally-units (list loaded-prism-home) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 10 #:charge-researched? #t))
  (define r-home-breach
    (step-multiprong-coordinator!
     st #:frame 7008 #:live-obs? #t #:race 'Protoss
     #:ally-units (list empty-prism-home) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:defensive-muster-active? #t
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 10 #:charge-researched? #t))
  ;; Proactive transit with `minerals=50, rwg=0, sup=0, charge=#t` on fresh state!
  (define st-pro (make-multiprong-state))
  (define r-pro-fly
    (step-multiprong-coordinator!
     st-pro #:frame 7000 #:live-obs? #t #:race 'Protoss
     #:ally-units (list empty-prism-home) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 0 #:minerals 50 #:supply-left 0 #:charge-researched? #t))
  (define pro-pkt (multiprong-state-prism-pocket st-pro))
  (define r-pro-phase-nowarp
    (step-multiprong-coordinator!
     st-pro #:frame 7040 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 901 'warp-prism (car pro-pkt) (cdr pro-pkt))) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 0 #:minerals 50 #:supply-left 0 #:charge-researched? #t))
  (define r-pro-warp-ready
    (step-multiprong-coordinator!
     st-pro #:frame 7060 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 901 'warp-prism-phasing (car pro-pkt) (cdr pro-pkt))) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 1 #:minerals 100 #:supply-left 2 #:charge-researched? #t))
  (check! (and (eq? (multiprong-result-mode r-low-wg-no-charge) 'inactive)
               (eq? (multiprong-result-mode r-loaded) 'inactive)
               (eq? (multiprong-result-mode r-home-breach) 'inactive)
               (eq? (multiprong-result-mode r-pro-fly) 'prism-warp-backstab)
               (not (multiprong-result-active-prong-target r-pro-fly))
               (equal? (multiprong-result-actions r-pro-phase-nowarp)
                       '((cast-spell 901 morph-warp-prism-phasing 901)))
               (not (multiprong-result-active-prong-target r-pro-phase-nowarp))
               (eq? (multiprong-result-mode r-pro-warp-ready) 'prism-warp-backstab)
               (pair? (multiprong-result-active-prong-target r-pro-warp-ready)))
          (format "L65-A6(1): Decoupled Prism proactive transit (min=50/rwg=0/charge=#t flies & phases w/ warp-target=#f until rwg>=1 & min>=100 & sup>=2)"))

  ;; (2) 0 standing ground units (`combat-units = '()`) + empty Warp Prism + >=2 WG + >=200M + >=4 sup
  ;;     -> launches `'prism-warp-backstab`, claims ONLY prism 901, flies enemy-avoiding flank (`>=20t` clear)
  (define r-fly
    (step-multiprong-coordinator!
     st #:frame 7020 #:live-obs? #t #:race 'Protoss
     #:ally-units (list empty-prism-home) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:ready-warp-gates 2 #:minerals 200 #:supply-left 4 #:charge-researched? #f))
  (define fly-acts (multiprong-result-actions r-fly))
  (define fly-act (and (pair? fly-acts) (car fly-acts)))
  (define fly-clear?
    (and fly-act (eq? (first fly-act) 'move) (= (second fly-act) 901)
         (>= (dist2d (third fly-act) (fourth fly-act) 93.5 92.5) 19.5)))
  (check! (and (eq? (multiprong-result-mode r-fly) 'prism-warp-backstab)
               (equal? (multiprong-result-handled-tags r-fly) (seteqv 901))
               fly-clear?
               (not (multiprong-result-active-prong-target r-fly)))
          (format "L65-A6(2): Empty Prism + 0 ground units launches 'prism-warp-backstab flank (act=~a)"
                  fly-act))

  ;; (3) Once Prism arrives at the chosen pocket (`<= 3.5t`) and safe (`> 14t` from AA):
  ;;     emits `(cast-spell 901 'morph-warp-prism-phasing 901)` AND exposes warp-in target `(cons wx wy)`!
  (define pkt (multiprong-state-prism-pocket st))
  (define prism-at-pkt (mk-u 901 'warp-prism (+ (car pkt) 1.0) (- (cdr pkt) 1.0)))
  (define r-phase
    (step-multiprong-coordinator!
     st #:frame 7060 #:live-obs? #t #:race 'Protoss
     #:ally-units (list prism-at-pkt) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define phase-tgt (multiprong-result-active-prong-target r-phase))
  (check! (and (eq? (multiprong-result-mode r-phase) 'prism-warp-backstab)
               (equal? (multiprong-result-actions r-phase)
                       '((cast-spell 901 morph-warp-prism-phasing 901)))
               (pair? phase-tgt)
               (<= (dist2d (car phase-tgt) (cdr phase-tgt) (car pkt) (cdr pkt)) 3.5))
          (format "L65-A6(3): Prism at safe pocket emits phasing morph & exposes warp-in target (acts=~a tgt=~a)"
                  (multiprong-result-actions r-phase) phase-tgt))

  ;; (4) Already phased (`warp-prism-phasing`) safely at pocket: holds phased (`actions = '()`),
  ;;     keeps Prism claimed in `handled-tags`, and continues exposing `(cons wx wy)` for warp-ins!
  (define prism-phased (mk-u 901 'warp-prism-phasing (car pkt) (cdr pkt)))
  (define r-hold
    (step-multiprong-coordinator!
     st #:frame 7080 #:live-obs? #t #:race 'Protoss
     #:ally-units (list prism-phased) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (check! (and (eq? (multiprong-result-mode r-hold) 'prism-warp-backstab)
               (null? (multiprong-result-actions r-hold))
               (set-member? (multiprong-result-handled-tags r-hold) 901)
               (pair? (multiprong-result-active-prong-target r-hold)))
          "L65-A6(4): Phased Prism at safe pocket holds phased, claims tag, & exposes warp-in pocket")

  ;; (5) Enemy AA arrives within <= 12t of phased Prism -> unphases (`morph-warp-prism-transport`)
  ;;     & clears `active-prong-target` (`#f`); next step in transport mode moves away along escape vector!
  (define close-aa (cons (mk-u 890 'viking-fighter (+ (car pkt) 7.0) (+ (cdr pkt) 2.0)) e-mid-army))
  (define r-unphase
    (step-multiprong-coordinator!
     st #:frame 7100 #:live-obs? #t #:race 'Protoss
     #:ally-units (list prism-phased) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units close-aa #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define prism-unphased (mk-u 901 'warp-prism (car pkt) (cdr pkt)))
  (define r-escape
    (step-multiprong-coordinator!
     st #:frame 7108 #:live-obs? #t #:race 'Protoss
     #:ally-units (list prism-unphased) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units close-aa #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led
     #:ready-warp-gates 4 #:minerals 100 #:supply-left 0 #:charge-researched? #t))
  (define esc-act (and (pair? (multiprong-result-actions r-escape))
                       (car (multiprong-result-actions r-escape))))
  (define esc-away?
    (and esc-act (eq? (first esc-act) 'move) (= (second esc-act) 901)
         (> (dist2d (third esc-act) (fourth esc-act) (+ (car pkt) 7.0) (+ (cdr pkt) 2.0))
            (dist2d (car pkt) (cdr pkt) (+ (car pkt) 7.0) (+ (cdr pkt) 2.0)))))
  (check! (and (equal? (multiprong-result-actions r-unphase)
                       '((cast-spell 901 morph-warp-prism-transport 901)))
               (not (multiprong-result-active-prong-target r-unphase))
               esc-away?
               (not (multiprong-result-active-prong-target r-escape)))
          (format "L65-A6(5): Enemy AA <=12t unphases Prism & retreats along safe escape vector (unp=~a esc=~a)"
                  (multiprong-result-actions r-unphase) esc-act))

  ;; (6) Phased Prism far from target pocket (> 3.5t) unphases first before flying!
  (define st-far (make-multiprong-state))
  (define r-far-phased
    (step-multiprong-coordinator!
     st-far #:frame 7200 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 905 'warp-prism-phasing 50.0 50.0)) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 3 #:minerals 300 #:supply-left 6))
  (check! (and (eq? (multiprong-result-mode r-far-phased) 'prism-warp-backstab)
               (equal? (multiprong-result-actions r-far-phased)
                       '((cast-spell 905 morph-warp-prism-transport 905)))
               (not (multiprong-result-active-prong-target r-far-phased)))
          "L65-A6(6): Phased Prism far from pocket unphases first before flying flank")

  ;; (7) Loop 65C (`#1874`/`#1875`): Phased Prism at enemy pocket STAYS PHASED across `< 200M` /
  ;;     Warp Gate cooldown dips (<= 448f dwell), unphases ONLY past > 448f dwell, AND honors
  ;;     `112f` per-Prism morph refractory (zero morph thrash!).
  (define st-c (make-multiprong-state))
  (define r-c-fly
    (step-multiprong-coordinator!
     st-c #:frame 8000 #:live-obs? #t #:race 'Protoss
     #:ally-units (list empty-prism-home) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define pkt-c (multiprong-state-prism-pocket st-c))
  ;; Phase at pocket at f=8040 -> stamps `prism-last-morph-frame = 8040`, `prism-phased-since-frame = 8040`
  (define r-c-phase
    (step-multiprong-coordinator!
     st-c #:frame 8040 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 901 'warp-prism (car pkt-c) (cdr pkt-c))) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  ;; Minerals dip to 50M and ready-warp-gates = 0 right after warp wave (f=8120, +80f <= 448f) ->
  ;; MUST stay phased (`actions = '()`, ZERO morph-transport!), keeping tag 901 claimed!
  (define r-c-dip
    (step-multiprong-coordinator!
     st-c #:frame 8120 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 901 'warp-prism-phasing (car pkt-c) (cdr pkt-c))) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 0 #:minerals 50 #:supply-left 2 #:charge-researched? #t))
  ;; Past > 448f dwell (f=8500, +460f > 448f) with still 0 WG / 50M -> unphases cleanly & stamps morph frame!
  (define r-c-dwell-end
    (step-multiprong-coordinator!
     st-c #:frame 8500 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 901 'warp-prism-phasing (car pkt-c) (cdr pkt-c))) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 0 #:minerals 50 #:supply-left 2 #:charge-researched? #t))
  ;; Refractory guard (`+40f < 112f` after unphase at f=8500): even if 400M/4WG return at f=8540,
  ;; MUST NOT emit morph-phasing until f >= 8612 (zero thrash!); unlocks cleanly at f=8620!
  (define r-c-refrac
    (step-multiprong-coordinator!
     st-c #:frame 8540 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 901 'warp-prism (car pkt-c) (cdr pkt-c))) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define r-c-rephase
    (step-multiprong-coordinator!
     st-c #:frame 8620 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 901 'warp-prism (car pkt-c) (cdr pkt-c))) #:combat-units '() #:ally-townhalls p-ths
     #:enemy-units e-mid-army #:enemy-townhalls e-ths
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (check! (and (equal? (multiprong-result-actions r-c-phase)
                       '((cast-spell 901 morph-warp-prism-phasing 901)))
               (eq? (multiprong-result-mode r-c-dip) 'prism-warp-backstab)
               (null? (multiprong-result-actions r-c-dip))
               (set-member? (multiprong-result-handled-tags r-c-dip) 901)
               (equal? (multiprong-result-actions r-c-dwell-end)
                       '((cast-spell 901 morph-warp-prism-transport 901)))
               (null? (multiprong-result-actions r-c-refrac))
               (equal? (multiprong-result-actions r-c-rephase)
                       '((cast-spell 901 morph-warp-prism-phasing 901)))
               (eqv? (multiprong-state-prism-tag st-c) 901))
          (format "L65-C1: Prism stays phased across <200M/WG dips (<=448f), unphases >448f, & honors 112f refractory (dip=~a end=~a ref=~a rep=~a)"
                  (multiprong-result-actions r-c-dip)
                  (multiprong-result-actions r-c-dwell-end)
                  (multiprong-result-actions r-c-refrac)
                  (multiprong-result-actions r-c-rephase))))

;; =============================================================================
;; L65-B1 (`#1861`/`#1862`): Caster/Siege/Medivac Exclusion, 12t Engage-Lock,
;;   Mode 2 `combat-suppress-attack?` Gate & En-Route `<= 14t` Interceptor Abort
;; =============================================================================
(let ()
  ;; (1) `'sentry`, `'medivac`, `'siege-tank`, `'lurker`, `'lurker-mp` NEVER claimed by multiprong!
  (define st-excl (make-multiprong-state))
  (define mixed-force
    (list (mk-u 9501 'stalker 118.0 118.0)
          (mk-u 9502 'stalker 119.0 118.0)
          (mk-u 9503 'sentry 118.5 117.5)
          (mk-u 9504 'medivac 118.5 119.0 #t)
          (mk-u 9505 'siege-tank 119.0 119.5)
          (mk-u 9506 'lurker 117.5 118.5)
          (mk-u 9507 'lurker-mp 117.0 118.5)))
  (define maj-home-threat
    (for/list ([i (in-range 10)]) (mk-u (+ 9600 i) 'roach (+ 54.0 (* 0.4 i)) 36.0)))
  (define r-excl
    (step-multiprong-coordinator!
     st-excl #:frame 7600 #:live-obs? #t #:race 'Protoss
     #:ally-units mixed-force #:combat-units mixed-force #:ally-townhalls ally-ths-2
     #:enemy-units maj-home-threat #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (define excl-claimed (multiprong-result-handled-tags r-excl))
  (check! (and (eq? (multiprong-result-mode r-excl) 'defensive-full-rotate)
               (set-member? excl-claimed 9501)
               (set-member? excl-claimed 9502)
               (not (set-member? excl-claimed 9503))
               (not (set-member? excl-claimed 9504))
               (not (set-member? excl-claimed 9505))
               (not (set-member? excl-claimed 9506))
               (not (set-member? excl-claimed 9507)))
          (format "L65-B1(1): sentry/medivac/siege-tank/lurker/lurker-mp NEVER claimed by multiprong (claimed=~a)"
                  excl-claimed))

  ;; (2) Mode 1 12.0t engage-lock handoff + Loop 65D Mode 3 atomic cohesion guard (zero half-army abandonment
  ;;     when ANY frontliner in `near-atk` is engaged <= 12t, plus >= 35% engaged early dwell abort)!
  (define st-lock (make-multiprong-state))
  (define m1-army
    (list (mk-u 9511 'stalker 64.0 36.0)    ;; 10.0t from home roaches at (54, 36) -> <=12t, hands off to Phase 5!
          (mk-u 9512 'stalker 118.0 118.0)  ;; far -> rotated home!
          (mk-u 9513 'stalker 119.0 118.0)))
  (define r-m1-lock
    (step-multiprong-coordinator!
     st-lock #:frame 7700 #:live-obs? #t #:race 'Protoss
     #:ally-units m1-army #:combat-units m1-army #:ally-townhalls ally-ths-2
     #:enemy-units maj-home-threat #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (define st-m3-lock (make-multiprong-state))
  (define m3-army-front-engaged
    (append (list (mk-u 9521 'stalker 142.0 152.0)) ;; 10.0t from enemy marine at (152,152) -> engaged front!
            (for/list ([i (in-range 10)]) (mk-u (+ 9530 i) 'stalker 136.0 144.0)))) ;; 22 sup total, 1 engaged -> MUST ABORT!
  (define m3-fort-a
    (list (mk-u 9541 'siege-tank-sieged 154.0 154.0)
          (mk-u 9542 'siege-tank-sieged 156.0 153.0)
          (mk-u 9543 'marine 152.0 152.0)))
  (define r-m3-cohesion-abort
    (step-multiprong-coordinator!
     st-m3-lock #:frame 9100 #:live-obs? #t #:race 'Protoss
     #:ally-units m3-army-front-engaged #:combat-units m3-army-front-engaged #:ally-townhalls ally-ths-2
     #:enemy-units m3-fort-a #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  ;; Start clean rotation on 10 free Stalkers, then engage 4/10 (40% >= 35%) <= 12t -> early dwell abort!
  (define m3-army-free (for/list ([i (in-range 10)]) (mk-u (+ 9530 i) 'stalker 136.0 144.0)))
  (define r-m3-start
    (step-multiprong-coordinator!
     st-m3-lock #:frame 9110 #:live-obs? #t #:race 'Protoss
     #:ally-units m3-army-free #:combat-units m3-army-free #:ally-townhalls ally-ths-2
     #:enemy-units m3-fort-a #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (define m3-army-40pct-eng
    (append (for/list ([i (in-range 4)]) (mk-u (+ 9530 i) 'stalker 146.0 152.0))
            (for/list ([i (in-range 4 10)]) (mk-u (+ 9530 i) 'stalker 136.0 144.0))))
  (define r-m3-dwell-abort
    (step-multiprong-coordinator!
     st-m3-lock #:frame 9150 #:live-obs? #t #:race 'Protoss
     #:ally-units m3-army-40pct-eng #:combat-units m3-army-40pct-eng #:ally-townhalls ally-ths-2
     #:enemy-units m3-fort-a #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (check! (and (eq? (multiprong-result-mode r-m1-lock) 'defensive-full-rotate)
               (not (set-member? (multiprong-result-handled-tags r-m1-lock) 9511))
               (set-member? (multiprong-result-handled-tags r-m1-lock) 9512)
               (not (eq? (multiprong-result-mode r-m3-cohesion-abort) 'offensive-rotate))
               (eq? (multiprong-result-mode r-m3-start) 'offensive-rotate)
               (not (eq? (multiprong-result-mode r-m3-dwell-abort) 'offensive-rotate)))
          (format "L65-B1(2): Mode 1 12t handoff + Mode 3 atomic cohesion abort (front=~a start=~a dwell=~a)"
                  (multiprong-result-mode r-m3-cohesion-abort)
                  (multiprong-result-mode r-m3-start)
                  (multiprong-result-mode r-m3-dwell-abort)))

  ;; (3) Mode 2 gated on `(not combat-suppress-attack?)`, `>= 32 sup`, `>= 0.90x enemy`, AND aborts
  ;;     `continuing?` when en-route interceptors within `<= 14t` of pack `(px, py)` exceed `1.25 * pack-val`!
  (define st-sup (make-multiprong-state))
  (define z-pack-army
    (append (for/list ([i (in-range 12)]) (mk-u (+ 9700 i) 'roach 42.0 42.0))
            (for/list ([i (in-range 16)]) (mk-u (+ 9750 i) 'zergling 46.0 38.0)))) ;; 32 sup!
  (define e-mid-bs
    (for/list ([i (in-range 10)]) (mk-u (+ 9800 i) 'stalker (+ 84.0 (* 0.5 i)) 95.0)))
  (define e-ths-bs
    (list (mk-th 9891 'nexus 160.0 155.0)
          (mk-th 9892 'nexus 160.0 45.0)))
  (define r-bs-suppressed
    (step-multiprong-coordinator!
     st-sup #:frame 8000 #:live-obs? #t #:race 'Zerg
     #:ally-units z-pack-army #:combat-units z-pack-army #:ally-townhalls ally-ths-2
     #:enemy-units e-mid-bs #:enemy-townhalls e-ths-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0
     #:combat-suppress-attack? #t))
  ;; Launch cleanly when NOT suppressed, then intercept pack mid-flank at (105, 42) (55t from target B!)
  (define r-bs-go
    (step-multiprong-coordinator!
     st-sup #:frame 8008 #:live-obs? #t #:race 'Zerg
     #:ally-units z-pack-army #:combat-units z-pack-army #:ally-townhalls ally-ths-2
     #:enemy-units e-mid-bs #:enemy-townhalls e-ths-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0))
  (define launched-tags (multiprong-result-handled-tags r-bs-go))
  (define z-midflank
    (append (for/list ([i (in-range 12)]) (mk-u (+ 9700 i) 'roach 42.0 42.0))
            (for/list ([i (in-range 16)])
              (if (set-member? launched-tags (+ 9750 i))
                  (mk-u (+ 9750 i) 'zergling 105.0 42.0)
                  (mk-u (+ 9750 i) 'zergling 46.0 38.0)))))
  ;; 5 Stalkers (875 val >> 1.25 * 200-300 pack val) intercepting within 10t of (105, 42)!
  (define e-intercept
    (append e-mid-bs
            (for/list ([i (in-range 5)]) (mk-u (+ 9850 i) 'stalker 114.0 43.0))))
  (define r-bs-intercept-abort
    (step-multiprong-coordinator!
     st-sup #:frame 8080 #:live-obs? #t #:race 'Zerg
     #:ally-units z-midflank #:combat-units z-midflank #:ally-townhalls ally-ths-2
     #:enemy-units e-intercept #:enemy-townhalls e-ths-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0))
  ;; Also verify `continuing?` releases units within `<= 12t` when outnumbered < 1.25x
  (define st-contact (make-multiprong-state))
  (define r-bs-go2
    (step-multiprong-coordinator!
     st-contact #:frame 8400 #:live-obs? #t #:race 'Zerg
     #:ally-units z-pack-army #:combat-units z-pack-army #:ally-townhalls ally-ths-2
     #:enemy-units e-mid-bs #:enemy-townhalls e-ths-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0))
  (define tags2 (multiprong-result-handled-tags r-bs-go2))
  (define z-in-contact
    (append (for/list ([i (in-range 12)]) (mk-u (+ 9700 i) 'roach 42.0 42.0))
            (for/list ([i (in-range 16)])
              (if (set-member? tags2 (+ 9750 i))
                  (mk-u (+ 9750 i) 'zergling 152.0 45.0)
                  (mk-u (+ 9750 i) 'zergling 46.0 38.0)))))
  ;; 1 single Marine (50 val < 1.25x pack) at 8t -> pack hands off <=12t to Phase 5!
  (define r-bs-contact-handoff
    (step-multiprong-coordinator!
     st-contact #:frame 8460 #:live-obs? #t #:race 'Zerg
     #:ally-units z-in-contact #:combat-units z-in-contact #:ally-townhalls ally-ths-2
     #:enemy-units (cons (mk-u 9888 'marine 159.0 45.0) e-mid-bs) #:enemy-townhalls e-ths-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0))
  (check! (and (eq? (multiprong-result-mode r-bs-suppressed) 'inactive)
               (eq? (multiprong-result-mode r-bs-go) 'counter-backstab)
               (eq? (multiprong-result-mode r-bs-intercept-abort) 'inactive)
               (eq? (multiprong-result-mode r-bs-contact-handoff) 'inactive))
          (format "L65-B1(3): Mode 2 respects combat-suppress-attack?, aborts on <=14t interceptors, & hands off <=12t contact (sup=~a int=~a cnt=~a)"
                  (multiprong-result-mode r-bs-suppressed)
                  (multiprong-result-mode r-bs-intercept-abort)
                  (multiprong-result-mode r-bs-contact-handoff)))

  ;; (4) Loop 65D (`#1891`/`#1892`) small-army split guards:
  ;;     - `two-prong` blocks `< 36.0` sup (32 sup) AND blocks `< 1.05x` enemy army (40 vs 40 sup)!
  ;;     - `backstab` blocks `< 32.0` sup (28 sup) AND blocks `< 0.90x` enemy army (32 vs 40 sup)!
  ;;     - Shortened 20f lease TTL (`<= 20f`) & `combat-suppress-attack?` skips mirroring `'strike-group`!
  (define st-d (make-multiprong-state))
  (define p-small-32
    (append (for/list ([i (in-range 12)]) (mk-u (+ 9900 i) 'stalker 120.0 140.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 9920 i) 'zealot 142.0 108.0))))
  (define p-40
    (append (for/list ([i (in-range 16)]) (mk-u (+ 9900 i) 'stalker 120.0 140.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 9920 i) 'zealot 142.0 108.0))))
  (define e-40-at-a (for/list ([i (in-range 20)]) (mk-u (+ 9950 i) 'stalker 155.0 155.0)))
  (define r-tp-small
    (step-multiprong-coordinator!
     st-d #:frame 10000 #:live-obs? #t #:race 'Protoss
     #:ally-units p-small-32 #:combat-units p-small-32 #:ally-townhalls ally-ths-2
     #:enemy-units (list (mk-u 9949 'stalker 155.0 155.0)) #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (define r-tp-ratio
    (step-multiprong-coordinator!
     st-d #:frame 10008 #:live-obs? #t #:race 'Protoss
     #:ally-units p-40 #:combat-units p-40 #:ally-townhalls ally-ths-2
     #:enemy-units e-40-at-a #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (define r-bs-ratio
    (step-multiprong-coordinator!
     st-d #:frame 10016 #:live-obs? #t #:race 'Zerg
     #:ally-units z-pack-army #:combat-units z-pack-army #:ally-townhalls ally-ths-2
     #:enemy-units (for/list ([i (in-range 20)]) (mk-u (+ 9970 i) 'stalker (+ 84.0 (* 0.3 i)) 95.0))
     #:enemy-townhalls e-ths-bs
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0))
  (define st-ttl (make-multiprong-state))
  (define leases-ttl (make-hasheqv))
  (step-multiprong-coordinator!
   st-ttl #:frame 10024 #:live-obs? #t #:race 'Zerg
   #:ally-units z-pack-army #:combat-units z-pack-army #:ally-townhalls ally-ths-2
   #:enemy-units e-mid-bs #:enemy-townhalls e-ths-bs
   #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0
   #:role-leases leases-ttl)
  (define first-lease (for/or ([v (in-hash-values leases-ttl)]) v))
  (define st-sup-lease (make-multiprong-state))
  (define leases-sup (make-hasheqv))
  (step-multiprong-coordinator!
   st-sup-lease #:frame 10024 #:live-obs? #t #:race 'Protoss
   #:ally-units (list (mk-u 9991 'warp-prism 45.0 48.0)) #:combat-units '() #:ally-townhalls ally-ths-2
   #:enemy-units e-mid-bs #:enemy-townhalls e-ths-bs
   #:base-x 30.0 #:base-y 30.0 #:enemy-x 160.0 #:enemy-y 155.0
   #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t
   #:combat-suppress-attack? #t
   #:role-leases leases-sup)
  (check! (and (not (eq? (multiprong-result-mode r-tp-small) 'two-prong-sync))
               (not (eq? (multiprong-result-mode r-tp-ratio) 'two-prong-sync))
               (eq? (multiprong-result-mode r-bs-ratio) 'inactive)
               (unit-role-lease? first-lease)
               (<= (- (unit-role-lease-expires-frame first-lease) 10024) 20)
               (= (hash-count leases-sup) 0))
          (format "L65-D1: Small-army/ratio split guards, 20f TTL, & suppress-no-strike-lease verified (tp-sm=~a tp-rat=~a bs-rat=~a ttl=~a sup-cnt=~a)"
                  (multiprong-result-mode r-tp-small)
                  (multiprong-result-mode r-tp-ratio)
                  (multiprong-result-mode r-bs-ratio)
                  (and (unit-role-lease? first-lease) (- (unit-role-lease-expires-frame first-lease) 10024))
                  (hash-count leases-sup))))

;; =============================================================================
;; L65-E1 (`#1907`/`#1908`): Mode 1 Sticky Hysteresis (25t->12t) & Direct Intercept,
;;   Prism Phasing at 10.5t from Marine/Turret + Damaged 10t Retreat + Endgame-Hunt Prism!
;; =============================================================================
(let ()
  ;; (1) Mode 1 sticky hysteresis (enter >= 25t, stay active down to >= 12t) + direct 0.75*ex+0.25*thx intercept!
  (define st-m1h (make-multiprong-state))
  (define ths-m1h (list (mk-th 1 'hatchery 30.0 30.0) (mk-th 2 'hatchery 55.0 34.0)))
  (define e-push-nat (for/list ([i (in-range 10)]) (mk-u (+ 9100 i) 'roach 62.0 36.0)))
  ;; Step 1: Army 30t away from Nat `(55, 34)` at `(85, 34)` -> enters `'defensive-full-rotate`
  ;;         targeting `(0.75*62 + 0.25*55, 0.75*36 + 0.25*34) = (60.25, 35.5)`!
  (define army-30t (for/list ([i (in-range 8)]) (mk-u (+ 9150 i) 'roach 85.0 34.0)))
  (define r-m1-enter
    (step-multiprong-coordinator!
     st-m1h #:frame 7500 #:live-obs? #t #:race 'Zerg
     #:ally-units army-30t #:combat-units army-30t #:ally-townhalls ths-m1h
     #:enemy-units e-push-nat #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (define m1-tgt (multiprong-result-active-prong-target r-m1-enter))
  ;; Step 2: Army rotates closer to `(75, 34)` (`20t` from Nat: 12t <= 20t < 25t, 13.15t > 12t from enemy!)
  ;;         -> sticky hysteresis KEEPS `'defensive-full-rotate` active (ZERO 24.5<->25.5t ping-pong!)
  (define army-20t (for/list ([i (in-range 8)]) (mk-u (+ 9150 i) 'roach 75.0 34.0)))
  (define r-m1-sticky
    (step-multiprong-coordinator!
     st-m1h #:frame 7516 #:live-obs? #t #:race 'Zerg
     #:ally-units army-20t #:combat-units army-20t #:ally-townhalls ths-m1h
     #:enemy-units e-push-nat #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (check! (and (eq? (multiprong-result-mode r-m1-enter) 'defensive-full-rotate)
               (pair? m1-tgt)
               (< (dist2d (car m1-tgt) (cdr m1-tgt) 60.25 35.5) 0.5)
               (eq? (multiprong-result-mode r-m1-sticky) 'defensive-full-rotate))
          (format "L65-E1(1): Mode 1 sticky hysteresis (25t->12t) & direct 0.75*ex+0.25*thx intercept (tgt=~a sticky=~a)"
                  m1-tgt (multiprong-result-mode r-m1-sticky)))

  ;; (2) Warp Prism phases at `10.5t` from Marine/Turret (healthy, > 9.5t safe-phase / > 8.5t retreat!),
  ;;     retreats at `9.2t` when damaged `< 70%` EHP (`10.0t` threshold), AND runs during `endgame-hunt-active?`
  ;;     when live enemy TH exists (while ground Modes 1-4 stay skipped)!
  (define st-pe (make-multiprong-state))
  (define p-ths-e (list (mk-th 1 'nexus 30.0 30.0) (mk-th 2 'nexus 55.0 34.0)))
  (define e-ths-e (list (mk-th 10 'orbital-command 165.0 165.0)
                        (mk-th 11 'orbital-command 120.0 168.0)))
  ;; Enemy army pushed mid-map `(90, 90)` plus a single Marine/Turret near `(120, 168)` 10.5t from Prism!
  (define e-far-e (for/list ([i (in-range 6)]) (mk-u (+ 9200 i) 'marine (+ 88.0 i) 90.0)))
  (define pkt-e
    (compute-prism-warp-pocket 120.0 168.0 90.0 90.0 '() '() 200.0 200.0))
  (define px-e (car pkt-e))
  (define py-e (cdr pkt-e))
  ;; Place 1 Marine `10.5t` away from `(px-e, py-e)` -> healthy Prism (`100%` EHP) MUST PHASE!
  (define marine-10.5 (mk-u 9250 'marine (+ px-e 10.5) py-e))
  (define prism-healthy (hasheq 'id 9260 'type 'warp-prism 'x px-e 'y py-e 'hp 80.0 'max-hp 80.0 'shield 100.0 'max-shield 100.0))
  (define r-pe-phase
    (step-multiprong-coordinator!
     st-pe #:frame 8000 #:live-obs? #t #:race 'Protoss
     #:ally-units (list prism-healthy) #:combat-units '() #:ally-townhalls p-ths-e
     #:enemy-units (cons marine-10.5 e-far-e) #:enemy-townhalls e-ths-e
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  ;; Damaged Prism (`< 70%` EHP: 60/80 hp + 40/100 shield = 55.6%) with Marine at `9.2t` (<= 10.0t!) -> MUST RETREAT!
  (define st-pe-dmg (make-multiprong-state))
  (define prism-dmg (hasheq 'id 9261 'type 'warp-prism-phasing 'x px-e 'y py-e 'hp 60.0 'max-hp 80.0 'shield 40.0 'max-shield 100.0))
  (define r-pe-dmg-ret
    (step-multiprong-coordinator!
     st-pe-dmg #:frame 8000 #:live-obs? #t #:race 'Protoss
     #:ally-units (list prism-dmg) #:combat-units '() #:ally-townhalls p-ths-e
     #:enemy-units (cons (mk-u 9251 'marine (+ px-e 9.2) py-e) e-far-e) #:enemy-townhalls e-ths-e
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  ;; Endgame hunt active (`#:endgame-hunt-active? #t`) with live enemy THs & `(not enemy-main-cleared?)`:
  ;; empty Prism STILL runs `'prism-warp-backstab` while ground units (`10` Stalkers) stay UNCLAIMED!
  (define st-pe-eg (make-multiprong-state))
  (define eg-ground (for/list ([i (in-range 10)]) (mk-u (+ 9270 i) 'stalker 110.0 110.0)))
  (define r-pe-eg
    (step-multiprong-coordinator!
     st-pe-eg #:frame 14000 #:live-obs? #t #:race 'Protoss
     #:ally-units (cons prism-healthy eg-ground) #:combat-units eg-ground #:ally-townhalls p-ths-e
     #:enemy-units e-far-e #:enemy-townhalls e-ths-e
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:endgame-hunt-active? #t #:enemy-main-cleared? #f
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (check! (and (eq? (multiprong-result-mode r-pe-phase) 'prism-warp-backstab)
               (equal? (multiprong-result-actions r-pe-phase)
                       '((cast-spell 9260 morph-warp-prism-phasing 9260)))
               (pair? (multiprong-result-active-prong-target r-pe-phase))
               (equal? (multiprong-result-actions r-pe-dmg-ret)
                       '((cast-spell 9261 morph-warp-prism-transport 9261)))
               (not (multiprong-result-active-prong-target r-pe-dmg-ret))
               (eq? (multiprong-result-mode r-pe-eg) 'prism-warp-backstab)
               (equal? (multiprong-result-handled-tags r-pe-eg) (seteqv 9260)))
          (format "L65-E1(2): Prism phases at 10.5t from Marine, damaged retreats at 9.2t, & active during endgame-hunt (ph=~a dmg=~a eg=~a/~a)"
                  (multiprong-result-actions r-pe-phase)
                  (multiprong-result-actions r-pe-dmg-ret)
                  (multiprong-result-mode r-pe-eg)
                  (multiprong-result-handled-tags r-pe-eg)))

  ;; (3) Loop 65F (`#1920`/`#1921`): Tiny `<= 4.0`-sup micro-harass (`2` Zerglings at Natural)
  ;;     MUST NOT pull a forward push (`>= 55t` away) via Mode 1, while `2` Zerglings at an
  ;;     undefended Main (`def-sup = 0`) STILL triggers defense!
  (define st-m1-micro (make-multiprong-state))
  (define fwd-army-65t (for/list ([i (in-range 10)]) (mk-u (+ 9280 i) 'stalker 125.0 115.0)))
  (define lings-2-nat (list (mk-u 9295 'zergling 56.0 35.0) (mk-u 9296 'zergling 57.0 35.0)))
  (define lings-2-main (list (mk-u 9297 'zergling 31.0 31.0) (mk-u 9298 'zergling 32.0 31.0)))
  (define r-micro-nat
    (step-multiprong-coordinator!
     st-m1-micro #:frame 8200 #:live-obs? #t #:race 'Protoss
     #:ally-units fwd-army-65t #:combat-units fwd-army-65t #:ally-townhalls p-ths-e
     #:enemy-units lings-2-nat #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (define r-micro-main-undef
    (step-multiprong-coordinator!
     st-m1-micro #:frame 8216 #:live-obs? #t #:race 'Protoss
     #:ally-units fwd-army-65t #:combat-units fwd-army-65t #:ally-townhalls p-ths-e
     #:enemy-units lings-2-main #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0))
  (check! (and (not (memq (multiprong-result-mode r-micro-nat) '(defensive-split defensive-full-rotate)))
               (eq? (multiprong-result-mode r-micro-main-undef) 'defensive-split))
          (format "L65-F1: 2 Zerglings at Nat do NOT peel >=55t forward army, while undefended Main still defends (nat=~a main=~a)"
                  (multiprong-result-mode r-micro-nat)
                  (multiprong-result-mode r-micro-main-undef))))

;; =============================================================================
;; L65-H1 (`#1948`): Protoss Warp Prism Mode 2B Refinement
;;   - `compute-prism-escape-point` 12.0t edge margin clamp
;;   - Segment-aware flank (`d-pocket > 22t` & `seg-d-en <= 16t` or `d-aa <= 16t`, dynamic clearance)
;;     vs straight flight when path is clear
;;   - Widened `7.5..16.0t` safe phase ring & `7.5..16.5t` `phasing-at-enemy-pocket?`
;;   - Deployed forward Prism NEVER drops `'strike-group` lease during home defense!
;; =============================================================================
(let ()
  ;; (1) Escape vector clamps strictly inside `[12.0, mw - 12.0] x [12.0, mh - 12.0]` near map corners!
  (define p-ths-h (list (mk-th 1 'nexus 30.0 30.0) (mk-th 2 'nexus 55.0 34.0)))
  (define e-ths-h (list (mk-th 10 'orbital-command 165.0 165.0)
                        (mk-th 11 'orbital-command 120.0 168.0)))
  (define st-h-esc (make-multiprong-state))
  ;; Prism at corner `(186, 186)` near enemy TH `(165, 165)` with close Viking at `(181, 181)` -> escape pushes
  ;; toward `(200, 200)` corner, MUST clamp to `<= 188.0` (`mw - 12.0`) on both axes!
  (define r-h-esc
    (step-multiprong-coordinator!
     st-h-esc #:frame 7950 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 9301 'warp-prism 186.0 186.0)) #:combat-units '() #:ally-townhalls p-ths-h
     #:enemy-units (list (mk-u 9302 'viking-fighter 181.0 181.0)) #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:map-width 200.0 #:map-height 200.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define esc-h-act (and (pair? (multiprong-result-actions r-h-esc)) (car (multiprong-result-actions r-h-esc))))
  (check! (and esc-h-act (eq? (first esc-h-act) 'move)
               (>= (third esc-h-act) 12.0) (<= (third esc-h-act) 188.0)
               (>= (fourth esc-h-act) 12.0) (<= (fourth esc-h-act) 188.0))
          (format "L65-H1(1): Escape point clamps to 12.0t map edge margin (act=~a)" esc-h-act))

  ;; (2) Segment-aware direct flight vs dynamic flank clearance
  ;; Enemy army far off the direct path at `(160, 40)`: segment `(45, 48) -> pocket(~120, 177)` stays >> 16t clear!
  (define e-off-path (for/list ([i (in-range 6)]) (mk-u (+ 9300 i) 'marine (+ 158.0 i) 40.0)))
  (define st-h-dir (make-multiprong-state))
  (define r-h-dir
    (step-multiprong-coordinator!
     st-h-dir #:frame 8000 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 9310 'warp-prism 45.0 48.0)) #:combat-units '() #:ally-townhalls p-ths-h
     #:enemy-units e-off-path #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define dir-pkt (multiprong-state-prism-pocket st-h-dir))
  (define dir-act (and (pair? (multiprong-result-actions r-h-dir)) (car (multiprong-result-actions r-h-dir))))
  ;; Enemy army sitting directly ON the segment `(45, 48) -> (~120, 177)` at `(82, 112)` -> MUST flank!
  (define e-on-path (for/list ([i (in-range 6)]) (mk-u (+ 9320 i) 'marine (+ 80.0 (* 0.5 i)) 112.0)))
  (define st-h-flk (make-multiprong-state))
  (define r-h-flk
    (step-multiprong-coordinator!
     st-h-flk #:frame 8000 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 9311 'warp-prism 45.0 48.0)) #:combat-units '() #:ally-townhalls p-ths-h
     #:enemy-units e-on-path #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define flk-pkt (multiprong-state-prism-pocket st-h-flk))
  (define flk-act (and (pair? (multiprong-result-actions r-h-flk)) (car (multiprong-result-actions r-h-flk))))
  (check! (and dir-act (eq? (first dir-act) 'move)
               (< (dist2d (third dir-act) (fourth dir-act) (car dir-pkt) (cdr dir-pkt)) 0.5)
               flk-act (eq? (first flk-act) 'move)
               (> (dist2d (third flk-act) (fourth flk-act) (car flk-pkt) (cdr flk-pkt)) 10.0)
               (>= (dist2d (third flk-act) (fourth flk-act) 81.25 112.0) 18.0))
          (format "L65-H1(2): Clear path flies straight to pocket while blocked segment flanks (dir=~a pkt=~a flk=~a)"
                  dir-act dir-pkt flk-act))

  ;; (3) Widened `7.5..16.0t` safe phase ring & `7.5..16.5t` `phasing-at-enemy-pocket?`
  (define st-h-ring (make-multiprong-state))
  ;; Place Prism `14.5t` from enemy TH `(120, 168)` at `(105.5, 168.0)` (`> 12.0t`, `<= 16.0t`, safe AA!) -> phases!
  (define r-h-ring-phase
    (step-multiprong-coordinator!
     st-h-ring #:frame 8100 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 9330 'warp-prism 105.5 168.0)) #:combat-units '() #:ally-townhalls p-ths-h
     #:enemy-units e-off-path #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  ;; Already phased at `15.5t` (`<= 16.5t`) with `0` WG & `50M` -> stays phased (`actions = '()`)!
  (define r-h-ring-hold
    (step-multiprong-coordinator!
     st-h-ring #:frame 8140 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 9330 'warp-prism-phasing 104.5 168.0)) #:combat-units '() #:ally-townhalls p-ths-h
     #:enemy-units e-off-path #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:ready-warp-gates 0 #:minerals 50 #:supply-left 0 #:charge-researched? #t))
  (check! (and (equal? (multiprong-result-actions r-h-ring-phase)
                       '((cast-spell 9330 morph-warp-prism-phasing 9330)))
               (eq? (multiprong-result-mode r-h-ring-hold) 'prism-warp-backstab)
               (null? (multiprong-result-actions r-h-ring-hold))
               (set-member? (multiprong-result-handled-tags r-h-ring-hold) 9330))
          (format "L65-H1(3): Widened 7.5..16.0t phase ring & 7.5..16.5t phasing-at-enemy-pocket? (ph=~a hold=~a/~a)"
                  (multiprong-result-actions r-h-ring-phase)
                  (multiprong-result-mode r-h-ring-hold)
                  (multiprong-result-actions r-h-ring-hold)))

  ;; (4) Deployed forward Prism NEVER drops `'strike-group` lease during `defensive-muster-active?`,
  ;;     `home-defense-deficit?`, or `major-home-push?` (even with `combat-suppress-attack? = #t`!),
  ;;     while close AA still triggers `retreat-prop` and a home Prism (`<= 45t`) stays `'inactive`!
  (define st-h-def (make-multiprong-state))
  (define leases-h-def (make-hasheqv))
  (define led-h-def (make-arbiter-ledger))
  ;; First phase/track forward Prism at `(110.5, 168.0)` (`d-home = 159.7t > 45.0t`)
  (step-multiprong-coordinator!
   st-h-def #:frame 8200 #:live-obs? #t #:race 'Protoss
   #:ally-units (list (mk-u 9340 'warp-prism-phasing 110.5 168.0)) #:combat-units '() #:ally-townhalls p-ths-h
   #:enemy-units e-off-path #:enemy-townhalls e-ths-h
   #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
   #:arbiter-ledger led-h-def #:role-leases leases-h-def
   #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t)
  ;; Now fire `defensive-muster-active? = #t` AND `combat-suppress-attack? = #t`:
  ;; Phased forward Prism MUST keep `'strike-group` lease, stay claimed, and still expose warp target!
  (hash-clear! leases-h-def)
  (define r-h-def-phased
    (step-multiprong-coordinator!
     st-h-def #:frame 8216 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 9340 'warp-prism-phasing 110.5 168.0)) #:combat-units '() #:ally-townhalls p-ths-h
     #:enemy-units e-off-path #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led-h-def #:role-leases leases-h-def
     #:defensive-muster-active? #t #:combat-suppress-attack? #t
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define phased-lease (hash-ref leases-h-def 9340 #f))
  ;; In-transit forward Prism (`> 45.0t` from home, tracked on mission, unphased) during `major-home-push?`
  ;; (10 Roaches attacking home Main!) MUST ALSO retain `'strike-group` lease (NOT dropped to Phase 3)!
  (define st-h-tr (make-multiprong-state))
  (define leases-h-tr (make-hasheqv))
  (define led-h-tr (make-arbiter-ledger))
  (step-multiprong-coordinator!
   st-h-tr #:frame 8300 #:live-obs? #t #:race 'Protoss
   #:ally-units (list (mk-u 9341 'warp-prism 100.0 100.0)) #:combat-units '() #:ally-townhalls p-ths-h
   #:enemy-units e-off-path #:enemy-townhalls e-ths-h
   #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
   #:arbiter-ledger led-h-tr #:role-leases leases-h-tr
   #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t)
  (hash-clear! leases-h-tr)
  (define maj-home-roaches (for/list ([i (in-range 10)]) (mk-u (+ 9350 i) 'roach (+ 34.0 (* 0.4 i)) 34.0)))
  (define far-stalkers (for/list ([i (in-range 6)]) (mk-u (+ 9370 i) 'stalker 110.0 (+ 105.0 i))))
  (define r-h-def-transit
    (step-multiprong-coordinator!
     st-h-tr #:frame 8316 #:live-obs? #t #:race 'Protoss
     #:ally-units (cons (mk-u 9341 'warp-prism 100.0 100.0) far-stalkers)
     #:combat-units far-stalkers #:ally-townhalls p-ths-h
     #:enemy-units (append maj-home-roaches e-off-path) #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led-h-tr #:role-leases leases-h-tr
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (define transit-lease (hash-ref leases-h-tr 9341 #f))
  ;; Same transit forward Prism with close AA (`<= 9.5t`) during `defensive-muster-active?` -> retreats!
  (define r-h-def-aa
    (step-multiprong-coordinator!
     st-h-tr #:frame 8332 #:live-obs? #t #:race 'Protoss
     #:ally-units (list (mk-u 9341 'warp-prism 100.0 100.0)) #:combat-units '() #:ally-townhalls p-ths-h
     #:enemy-units (cons (mk-u 9390 'viking-fighter 107.0 100.0) e-off-path) #:enemy-townhalls e-ths-h
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 165.0 #:enemy-y 165.0
     #:arbiter-ledger led-h-tr #:role-leases leases-h-tr
     #:defensive-muster-active? #t
     #:ready-warp-gates 4 #:minerals 400 #:supply-left 8 #:charge-researched? #t))
  (check! (and (eq? (multiprong-result-mode r-h-def-phased) 'prism-warp-backstab)
               (set-member? (multiprong-result-handled-tags r-h-def-phased) 9340)
               (pair? (multiprong-result-active-prong-target r-h-def-phased))
               (unit-role-lease? phased-lease)
               (eq? (unit-role-lease-role phased-lease) 'strike-group)
               (eq? (multiprong-result-mode r-h-def-transit) 'defensive-full-rotate)
               (set-member? (multiprong-result-handled-tags r-h-def-transit) 9341)
               (unit-role-lease? transit-lease)
               (eq? (unit-role-lease-role transit-lease) 'strike-group)
               (pair? (multiprong-result-actions r-h-def-aa))
               (eq? (first (car (multiprong-result-actions r-h-def-aa))) 'move))
          (format "L65-H1(4): Deployed forward Prism retains 'strike-group lease during home defense (ph=~a/~a tr=~a/~a aa=~a)"
                  (multiprong-result-mode r-h-def-phased)
                  (and (unit-role-lease? phased-lease) (unit-role-lease-role phased-lease))
                  (multiprong-result-mode r-h-def-transit)
                  (and (unit-role-lease? transit-lease) (unit-role-lease-role transit-lease))
                  (multiprong-result-actions r-h-def-aa))))

;; =============================================================================
;; L66-C1: Cross-Step Arbiter Feedback on >= 3 `'unit-claimed-higher-priority`
;;         Overrides in 224f (and Ignored at <= 2 for Anti-Oscillation Hysteresis)
;; =============================================================================
(let ()
  (define (seed-claim-preempts! ledger base-frame n)
    (for ([k (in-range n)])
      (define f (+ base-frame (* k 16)))
      (arbiter-resolve!
       ledger f (make-arbiter-budget-snapshot)
       (list (make-proposal (list 'hd k) 'home-defense 'micro 900.0 '(attack-pos 9501 30.0 30.0)
                            #:claim (make-proposal-claim '(9501) #:role 'home-defense #:lease-ttl 0))
             (make-proposal (list 'mp k) 'multiprong-coordinator 'micro 600.0 '(attack-pos 9501 155.0 155.0)
                            #:claim (make-proposal-claim '(9501) #:role 'strike-group #:lease-ttl 0))))))

  (define mp-army
    (append (for/list ([i (in-range 16)]) (mk-u (+ 9500 i) 'stalker 120.0 140.0))
            (for/list ([i (in-range 4)]) (mk-u (+ 9540 i) 'zealot 142.0 108.0))))
  (define mp-enemies
    (list (mk-u 9601 'stalker 155.0 155.0) (mk-u 9602 'stalker 154.0 154.0)))

  ;; 2 claim preemptions (< 3 threshold) -> NO cooldown, `'two-prong-sync` launches cleanly!
  (define st-2 (make-multiprong-state))
  (define led-2 (make-arbiter-ledger))
  (seed-claim-preempts! led-2 9000 2)
  (define r-2
    (step-multiprong-coordinator!
     st-2 #:frame 9064 #:live-obs? #t #:race 'Protoss
     #:ally-units mp-army #:combat-units mp-army #:ally-townhalls ally-ths-2
     #:enemy-units mp-enemies #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger led-2))

  ;; 3 claim preemptions (>= 3 in 224f) -> bounded 168f cooldown suppresses `'two-prong-sync`!
  (define st-3 (make-multiprong-state))
  (define led-3 (make-arbiter-ledger))
  (seed-claim-preempts! led-3 9000 3)
  (define r-3
    (step-multiprong-coordinator!
     st-3 #:frame 9064 #:live-obs? #t #:race 'Protoss
     #:ally-units mp-army #:combat-units mp-army #:ally-townhalls ally-ths-2
     #:enemy-units mp-enemies #:enemy-townhalls enemy-ths-2
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger led-3))

  (check! (and (eq? (multiprong-result-mode r-2) 'two-prong-sync)
               (< (multiprong-state-def-cooldown-until st-2) 0)
               (eq? (multiprong-result-mode r-3) 'inactive)
               (>= (multiprong-state-def-cooldown-until st-3) (+ 9064 168)))
          (format "L66-C1: >=3 'unit-claimed-higher-priority in 224f cools 2-prong while <=2 does not (2:~a/~a 3:~a/~a)"
                  (multiprong-result-mode r-2) (multiprong-state-def-cooldown-until st-2)
                  (multiprong-result-mode r-3) (multiprong-state-def-cooldown-until st-3))))

;; =============================================================================
;; L65-A5: Frame-Rewind Auto-Reset Hygiene & < 0.25 ms/step Performance Budget
;; =============================================================================
(let ()
  (define st (make-multiprong-state))
  (define ledger (make-arbiter-ledger))
  (define big-army
    (append (for/list ([i (in-range 40)]) (mk-u (+ 1000 i) 'marine (+ 115.0 (modulo i 10)) (+ 120.0 (quotient i 10))))
            (for/list ([i (in-range 20)]) (mk-u (+ 1100 i) 'hellion (+ 125.0 (modulo i 5)) (+ 95.0 (quotient i 5))))))
  (define big-enemies
    (for/list ([i (in-range 30)]) (mk-u (+ 2000 i) 'zergling (+ 152.0 (modulo i 6)) (+ 150.0 (quotient i 6)))))
  (define big-ally-ths
    (list (mk-th 1 'orbital-command 30.0 30.0)
          (mk-th 2 'orbital-command 55.0 34.0)
          (mk-th 3 'orbital-command 32.0 62.0)))

  ;; Trigger a rotation at frame 12000, then rewind to frame 6000 -> state must auto-reset!
  (step-multiprong-coordinator!
   st #:frame 12000 #:live-obs? #t #:race 'Terran
   #:ally-units big-army #:combat-units big-army #:ally-townhalls big-ally-ths
   #:enemy-units big-enemies #:enemy-townhalls enemy-ths-3
   #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
   #:arbiter-ledger ledger)
  (step-multiprong-coordinator!
   st #:frame 6000 #:live-obs? #t #:race 'Terran
   #:ally-units big-army #:combat-units big-army #:ally-townhalls big-ally-ths
   #:enemy-units big-enemies #:enemy-townhalls enemy-ths-3
   #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
   #:arbiter-ledger ledger)
  (check! (= (multiprong-state-last-frame st) 6000)
          "L65-A5(1): Frame rewind resets multiprong-state cleanly")

  ;; Steady-state CPU benchmark: 200 steps with 60 combat units, 30 enemies, 3 enemy bases (< 0.25 ms/step)
  (define n-iters 200)
  (define t0 (current-inexact-monotonic-milliseconds))
  (for ([k (in-range n-iters)])
    (step-multiprong-coordinator!
     st #:frame (+ 6008 (* k 4)) #:live-obs? #t #:race 'Terran
     #:ally-units big-army #:combat-units big-army #:ally-townhalls big-ally-ths
     #:enemy-units big-enemies #:enemy-townhalls enemy-ths-3
     #:base-x 30.0 #:base-y 30.0 #:enemy-x 155.0 #:enemy-y 155.0
     #:arbiter-ledger ledger))
  (define elapsed-ms (- (current-inexact-monotonic-milliseconds) t0))
  (define avg-ms (/ elapsed-ms n-iters))
  (check! (< avg-ms 0.25)
          (format "L65-A5(2): Steady-state CPU < 0.25 ms/step (got ~a ms/step over ~a steps)"
                  (/ (round (* avg-ms 10000.0)) 10000.0) n-iters))
  (printf "l65-multiprong-coordinator-test: ~a/~a passed (~a failed) [avg=~a ms/step]\n"
          passed (+ passed failed) failed (/ (round (* avg-ms 10000.0)) 10000.0)))

(when (> failed 0)
  (exit 1))
