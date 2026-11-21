#lang racket/base

;; =============================================================================
;; Loop 48 Worker-Rush All-In Verification Suite (`tests/l48-worker-rush-macro-test.rkt`)
;;
;; Verifies Track W1 (`#1076` / `#1077`) — 100% generalizable P/T/Z early
;; worker-rush all-in belief + macro brain fixes:
;;   1. `lib/opponent-world-model.rkt`: First-class purely physical
;;      `early-worker-rush-active?` (`enemy-workers-near-us >= 4`, `frame < 3360`
;;      or latched active while >= 4 remain, `enemy-combat-cnt == 0`, `army < 6`),
;;      immediate `stopped-expanding? = #t`, and `rush-posterior-floor = 0.91`
;;      preventing premature 137.5s decay (`apply-worker-rush-posterior-floor`).
;;   2. Terran (`#5140076`, `#5140013`, `r15`): Gate `terran-rush-wall-depot?` &
;;      `terran-depot2-supply-boost?` so Depot #2 NEVER escrows at 13/23 -> 3/23;
;;      priority `Barracks #1 (750) -> Marine (740)` & suppress `Refinery`/`CC #2`/`OC`/`Factory`.
;;   3. Zerg (`#5140069`, `#5140006`, `r14`): Suppress `bo=hatchery`/`Extractor`/`Queen`;
;;      `SpawningPool (750)` -> `SpineCrawler (710)` at 100M WITHOUT `army >= 2` or
;;      `min >= 150` + `Zergling (740)`.
;;   4. Protoss (`#5140055`, `#5138237`, `r16`): Suppress `Assimilator`/`CyberCore`/`Nexus #2`
;;      until `>= 2` Zealots; `Pylon -> Gateway (750) -> Zealot (940)` + anti-deadlock
;;      release (`workers <= 8` & `50 <= min < 100` -> allow 1 Probe so bank never freezes at 80M).
;;   5. Negative guards: peaceful opening scouts viewing 16 enemy workers at the
;;      enemy main MUST NEVER false-trigger worker-rush defense.
;; =============================================================================

(require racket/list
         racket/format
         "../lib/econ-ledger.rkt"
         "../lib/opponent-world-model.rkt"
         "../lib/priority-macro-brain.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (cand-u dec sym)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))
  (define hit (findf (lambda (e) (eq? (priority-decision-entry-id e) sym)) trace))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

(define (bo-sym dec)
  (define g (macro-brain-decision-bo-active-goal dec))
  (and (pro-bo-goal? g) (pro-bo-goal-target-sym g)))

(define (make-rushing-enemy-workers sym n x y [start-id 900])
  (for/list ([i (in-range n)])
    (hash 'id (+ start-id i) 'type sym 'x (+ x (* 0.25 i)) 'y y 'hp 40 'shields 20)))

;; ============================================================================
;; 1. Opponent World Model: First-Class Early Worker-Rush Detection & Floor
;; ============================================================================

;; (1) 12 enemy Probes arrive near our main at 40s (f=896) -> early-worker-rush-active? = #t,
;;     stopped-expanding? = #t, confirmed-early-greed? = #f, rush-posterior-floor = 0.91!
(define owm-wr (make-opponent-world-model 'Protoss))
(define sum-wr-40s
  (step-opponent-world-model!
   owm-wr
   (hash 'frame 896
         'enemy-race 'Protoss
         'base-x 32.0 'base-y 32.0 'natural-x 50.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 142.0 'enemy-exp-y 156.0
         'ally-units (for/list ([i (in-range 14)])
                       (hash 'id (+ 10 i) 'type 'drone 'x 33.0 'y 32.0 'hp 40))
         'enemy-units (make-rushing-enemy-workers 'probe 12 38.0 34.0)
         'enemy-buildings '())))
(check! (and (= (opponent-world-summary-enemy-workers-near-us sum-wr-40s) 12)
             (opponent-world-summary-early-worker-rush-active? sum-wr-40s)
             (opponent-world-summary-stopped-expanding? sum-wr-40s)
             (not (opponent-world-summary-confirmed-early-greed? sum-wr-40s))
             (>= (opponent-world-summary-rush-posterior-floor sum-wr-40s) 0.91)
             (>= (opponent-world-summary-imminent-reachable-supply sum-wr-40s) 12))
        (format "L48-WR(1) OWM @40s 12 Probes near main MUST set early-worker-rush-active?=#t, stopped-expanding?=#t, floor=0.91: near=~a wr?=~a stop?=~a floor=~a imm=~a"
                (opponent-world-summary-enemy-workers-near-us sum-wr-40s)
                (opponent-world-summary-early-worker-rush-active? sum-wr-40s)
                (opponent-world-summary-stopped-expanding? sum-wr-40s)
                (opponent-world-summary-rush-posterior-floor sum-wr-40s)
                (opponent-world-summary-imminent-reachable-supply sum-wr-40s)))

;; (2) No premature 137.5s (f=3080) or 155s (f=3472) rush-posterior decay while >= 4 Probes remain!
(define sum-wr-137s
  (step-opponent-world-model!
   owm-wr
   (hash 'frame 3080
         'enemy-race 'Protoss
         'base-x 32.0 'base-y 32.0 'natural-x 50.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 142.0 'enemy-exp-y 156.0
         'ally-units (for/list ([i (in-range 10)])
                       (hash 'id (+ 10 i) 'type 'drone 'x 33.0 'y 32.0 'hp 40))
         'enemy-units (make-rushing-enemy-workers 'probe 10 36.0 34.0)
         'enemy-buildings '())))
(define sum-wr-155s
  (step-opponent-world-model!
   owm-wr
   (hash 'frame 3472
         'enemy-race 'Protoss
         'base-x 32.0 'base-y 32.0 'natural-x 50.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 142.0 'enemy-exp-y 156.0
         'ally-units (for/list ([i (in-range 10)])
                       (hash 'id (+ 10 i) 'type 'drone 'x 33.0 'y 32.0 'hp 40))
         'enemy-units (make-rushing-enemy-workers 'probe 8 36.0 34.0)
         'enemy-buildings '())))
(check! (and (opponent-world-summary-early-worker-rush-active? sum-wr-137s)
             (>= (apply-worker-rush-posterior-floor 0.45 sum-wr-137s) 0.91)
             (opponent-world-summary-early-worker-rush-active? sum-wr-155s)
             (>= (apply-worker-rush-posterior-floor 0.45 sum-wr-155s) 0.91))
        (format "L48-WR(2) OWM @137.5s & @155s MUST keep early-worker-rush-active?=#t and floor decayed 0.45 -> 0.91: wr137=~a p137=~a wr155=~a p155=~a"
                (opponent-world-summary-early-worker-rush-active? sum-wr-137s)
                (apply-worker-rush-posterior-floor 0.45 sum-wr-137s)
                (opponent-world-summary-early-worker-rush-active? sum-wr-155s)
                (apply-worker-rush-posterior-floor 0.45 sum-wr-155s)))

;; (3a) Clean OWM release once ally breaks out with >= 6 army supply (3 Zealots = 6 supply)
(define sum-wr-breakout
  (step-opponent-world-model!
   owm-wr
   (hash 'frame 3500
         'enemy-race 'Protoss
         'base-x 32.0 'base-y 32.0 'natural-x 50.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 142.0 'enemy-exp-y 156.0
         'ally-units (list (hash 'id 201 'type 'zealot 'x 35.0 'y 34.0 'hp 100 'shields 50)
                           (hash 'id 202 'type 'zealot 'x 36.0 'y 34.0 'hp 100 'shields 50)
                           (hash 'id 203 'type 'zealot 'x 37.0 'y 34.0 'hp 100 'shields 50))
         'enemy-units (make-rushing-enemy-workers 'probe 8 36.0 34.0)
         'enemy-buildings '())))
(check! (and (not (opponent-world-summary-early-worker-rush-active? sum-wr-breakout))
             (= (apply-worker-rush-posterior-floor 0.45 sum-wr-breakout) 0.45))
        (format "L48-WR(3a) OWM MUST clear early-worker-rush-active? once ally combat supply >= 6: wr?=~a p=~a"
                (opponent-world-summary-early-worker-rush-active? sum-wr-breakout)
                (apply-worker-rush-posterior-floor 0.45 sum-wr-breakout)))

;; (3b) Clean OWM release once < 4 enemy workers remain near our base (rest killed)
(define sum-wr-cleared
  (step-opponent-world-model!
   owm-wr
   (hash 'frame 3640
         'enemy-race 'Protoss
         'base-x 32.0 'base-y 32.0 'natural-x 50.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 142.0 'enemy-exp-y 156.0
         'dead-unit-tags '(903 904 905 906 907 908 909 910 911)
         'ally-units '()
         'enemy-units (make-rushing-enemy-workers 'probe 3 36.0 34.0)
         'enemy-buildings '())))
(check! (and (= (opponent-world-summary-enemy-workers-near-us sum-wr-cleared) 3)
             (not (opponent-world-summary-early-worker-rush-active? sum-wr-cleared)))
        (format "L48-WR(3b) OWM MUST clear early-worker-rush-active? once < 4 enemy workers remain near base: near=~a wr?=~a"
                (opponent-world-summary-enemy-workers-near-us sum-wr-cleared)
                (opponent-world-summary-early-worker-rush-active? sum-wr-cleared)))

;; (4) OWM negative guard: 16 enemy workers peacefully mining at the ENEMY main (160, 160)
(define owm-peaceful (make-opponent-world-model 'Protoss))
(define sum-peaceful
  (step-opponent-world-model!
   owm-peaceful
   (hash 'frame 1680
         'enemy-race 'Protoss
         'base-x 32.0 'base-y 32.0 'natural-x 50.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 142.0 'enemy-exp-y 156.0
         'ally-units (list (hash 'id 1 'type 'probe 'x 156.0 'y 156.0 'hp 40))
         'enemy-units (make-rushing-enemy-workers 'probe 16 159.0 160.0)
         'enemy-buildings (list (hash 'id 800 'type 'nexus 'x 160.0 'y 160.0 'hp 2000 'build-progress 1.0)))))
(check! (and (= (opponent-world-summary-enemy-workers-near-us sum-peaceful) 0)
             (not (opponent-world-summary-early-worker-rush-active? sum-peaceful))
             (not (opponent-world-summary-stopped-expanding? sum-peaceful)))
        (format "L48-WR(4) OWM Neg-guard: 16 Probes mining at enemy main MUST NOT trigger worker rush: near=~a wr?=~a stop?=~a"
                (opponent-world-summary-enemy-workers-near-us sum-peaceful)
                (opponent-world-summary-early-worker-rush-active? sum-peaceful)
                (opponent-world-summary-stopped-expanding? sum-peaceful)))

;; ============================================================================
;; 2. Terran Worker-Rush Macro Brain (`#5140076`, `#5140013`, `r15`)
;; ============================================================================

;; (5) Terran @ 13/23 supply (supply-left=10), 105M, Depot #1 ready, 0 Rax, 12 enemy Probes:
;;     MUST escrow Barracks #1 (750), NEVER escrow SupplyDepot #2 (100M) or Refinery!
(reset-macro-escrow-tracker!)
(define t-wr-no-depot2-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 1200
    #:minerals 105 #:gas 0 #:supply-used 13 #:supply-cap 23 #:supply-left 10 #:pending-supply 0
    #:workers 13 #:active-bases 1 #:mineral-harvesters 6 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 12 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1)
    #:unit-counts (hasheq 'scv 13)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'townhall 1))))
(check! (and (eq? (macro-brain-decision-saving-for t-wr-no-depot2-escrow) 'barracks)
             (>= (cand-u t-wr-no-depot2-escrow 'barracks) 750.0)
             (not (memq 'supply-depot (macro-brain-decision-scheduled-ids t-wr-no-depot2-escrow)))
             (not (eq? (macro-brain-decision-saving-for t-wr-no-depot2-escrow) 'supply-depot))
             (not (memq 'refinery (macro-brain-decision-scheduled-ids t-wr-no-depot2-escrow))))
        (format "L48-WR(5) Terran @13/23 105M vs 12 Probes MUST escrow Barracks(750) & NEVER Depot#2/Refinery: sched=~s save=~a u_rax=~a u_dep=~a"
                (macro-brain-decision-scheduled-ids t-wr-no-depot2-escrow)
                (macro-brain-decision-saving-for t-wr-no-depot2-escrow)
                (cand-u t-wr-no-depot2-escrow 'barracks)
                (cand-u t-wr-no-depot2-escrow 'supply-depot)))

;; (6a) Terran approaching Probe rush (before first hit, threat=12, under-attack?=#f) @155M:
;;      MUST immediately schedule Barracks #1 (750), suppressing Refinery/CC/Depot#2!
(reset-macro-escrow-tracker!)
(define t-wr-rax1-before-hit
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 1050
    #:minerals 155 #:gas 0 #:supply-used 15 #:supply-cap 23 #:supply-left 8 #:pending-supply 0
    #:workers 15 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1)
    #:unit-counts (hasheq 'scv 15)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'townhall 1))))
(check! (and (not (not (memq 'barracks (macro-brain-decision-scheduled-ids t-wr-rax1-before-hit))))
             (>= (cand-u t-wr-rax1-before-hit 'barracks) 750.0)
             (not (memq 'supply-depot (macro-brain-decision-scheduled-ids t-wr-rax1-before-hit)))
             (not (memq 'refinery (macro-brain-decision-scheduled-ids t-wr-rax1-before-hit))))
        (format "L48-WR(6a) Terran pre-hit Probe rush @155M MUST schedule Barracks#1(750): sched=~s u_rax=~a"
                (macro-brain-decision-scheduled-ids t-wr-rax1-before-hit)
                (cand-u t-wr-rax1-before-hit 'barracks)))

;; (6b) Terran with ready Barracks @11/23, 160M/100G vs 12 Probes:
;;      MUST schedule Marine (740), suppressing Depot #2, OC, CC #2, Refinery, Factory!
(reset-macro-escrow-tracker!)
(define t-wr-marine-suppress-tech
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 1800
    #:minerals 160 #:gas 100 #:supply-used 11 #:supply-cap 23 #:supply-left 12 #:pending-supply 0
    #:workers 11 #:active-bases 1 #:mineral-harvesters 5 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 12 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:unit-counts (hasheq 'scv 11)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(define t-wr-sched (macro-brain-decision-scheduled-ids t-wr-marine-suppress-tech))
(check! (and (not (not (memq 'marine t-wr-sched)))
             (>= (cand-u t-wr-marine-suppress-tech 'marine) 740.0)
             (not (memq 'supply-depot t-wr-sched))
             (not (memq 'orbital-command t-wr-sched))
             (not (memq 'refinery t-wr-sched))
             (not (memq 'command-center t-wr-sched))
             (not (memq 'factory t-wr-sched)))
        (format "L48-WR(6b) Terran ready Rax @11/23 160M/100G vs 12 Probes MUST train Marine(740) & suppress Depot2/OC/Ref/CC/Fact: sched=~s u_mar=~a"
                t-wr-sched (cand-u t-wr-marine-suppress-tech 'marine)))

;; (7) Terran supply-tight safety guard: at 22/23 (supply-left=1, 0 pending), Depot #2 STILL fires!
(reset-macro-escrow-tracker!)
(define t-wr-tight-supply-depot
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 2000
    #:minerals 160 #:gas 0 #:supply-used 22 #:supply-cap 23 #:supply-left 1 #:pending-supply 0
    #:workers 19 #:active-bases 1 #:mineral-harvesters 10 #:gas-harvesters 0
    #:army-supply 3 #:enemy-threat-supply 10 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:unit-counts (hasheq 'scv 19 'marine 3)
    #:enemy-unit-counts (hasheq 'probe 10)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(check! (not (not (memq 'supply-depot (macro-brain-decision-scheduled-ids t-wr-tight-supply-depot))))
        (format "L48-WR(7) Terran at 22/23 (supply-left=1) under worker rush MUST still build Depot#2: sched=~s"
                (macro-brain-decision-scheduled-ids t-wr-tight-supply-depot)))

;; ============================================================================
;; 3. Zerg Worker-Rush Macro Brain (`#5140069`, `#5140006`, `r14`)
;; ============================================================================

;; (8) Zerg pre-Pool @210M vs 12 Probes: MUST schedule SpawningPool (750) & NEVER Hatchery/Extractor!
(reset-macro-escrow-tracker!)
(define z-wr-pool-first
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 1000
    #:minerals 210 #:gas 0 #:supply-used 15 #:supply-cap 22 #:supply-left 7 #:pending-supply 0
    #:workers 15 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 1)
    #:total-building-counts (hasheq 'hatchery 1)
    #:unit-counts (hasheq 'drone 15 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'larva 3 'townhall 1))))
(check! (and (not (not (memq 'spawning-pool (macro-brain-decision-scheduled-ids z-wr-pool-first))))
             (>= (cand-u z-wr-pool-first 'spawning-pool) 750.0)
             (not (eq? (bo-sym z-wr-pool-first) 'hatchery))
             (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-wr-pool-first)))
             (not (memq 'extractor (macro-brain-decision-scheduled-ids z-wr-pool-first))))
        (format "L48-WR(8) Zerg @210M vs 12 Probes MUST schedule SpawningPool(750) & drop Hatch/Ext: sched=~s bo=~a u_pool=~a"
                (macro-brain-decision-scheduled-ids z-wr-pool-first)
                (bo-sym z-wr-pool-first)
                (cand-u z-wr-pool-first 'spawning-pool)))

;; (9) Zerg while SpawningPool is constructing (#5140069 exact repro): MUST NOT revert bo=hatchery!
(reset-macro-escrow-tracker!)
(define z-wr-pool-building-no-bo-hatch
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 1350
    #:minerals 305 #:gas 0 #:supply-used 14 #:supply-cap 22 #:supply-left 8 #:pending-supply 0
    #:workers 14 #:active-bases 1 #:mineral-harvesters 6 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 14 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'larva 2 'townhall 1))))
(check! (and (not (eq? (bo-sym z-wr-pool-building-no-bo-hatch) 'hatchery))
             (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-wr-pool-building-no-bo-hatch)))
             (not (eq? (macro-brain-decision-saving-for z-wr-pool-building-no-bo-hatch) 'hatchery))
             (not (memq 'extractor (macro-brain-decision-scheduled-ids z-wr-pool-building-no-bo-hatch))))
        (format "L48-WR(9) Zerg while Pool building @305M MUST suppress bo=hatchery & Extractor: sched=~s bo=~a save=~a"
                (macro-brain-decision-scheduled-ids z-wr-pool-building-no-bo-hatch)
                (bo-sym z-wr-pool-building-no-bo-hatch)
                (macro-brain-decision-saving-for z-wr-pool-building-no-bo-hatch)))

;; (10) Zerg ready Pool @100M, 6 Zerglings (3 pairs), 0 larva vs 15 Probes: MUST drop SpineCrawler#1(760) after first 6 Lings!
(reset-macro-escrow-tracker!)
(define z-wr-spine-at-100m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 2000
    #:minerals 100 #:gas 0 #:supply-used 15 #:supply-cap 22 #:supply-left 7 #:pending-supply 0
    #:workers 12 #:active-bases 1 #:mineral-harvesters 4 #:gas-harvesters 0
    #:army-supply 3 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 12 'zergling 6 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'larva 0 'townhall 1))))
(check! (and (not (not (memq 'spine-crawler (macro-brain-decision-scheduled-ids z-wr-spine-at-100m))))
             (>= (cand-u z-wr-spine-at-100m 'spine-crawler) 760.0)
             (not (memq 'queen (macro-brain-decision-scheduled-ids z-wr-spine-at-100m)))
             (not (memq 'extractor (macro-brain-decision-scheduled-ids z-wr-spine-at-100m))))
        (format "L48-WR(10) Zerg ready Pool w/ 6 Lings @100M & 0 larva MUST schedule SpineCrawler(760): sched=~s u_spine=~a"
                (macro-brain-decision-scheduled-ids z-wr-spine-at-100m)
                (cand-u z-wr-spine-at-100m 'spine-crawler)))

;; (11) L48-W3B (`r14` Zerg): Ready Pool @150M w/ 0 Lings (<6) & 2 larva vs 15 Probes:
;;      MUST prioritize first 6 fast (17s) Zerglings(780) BEFORE 36s SpineCrawler#1, NO Drone/Queen!
(reset-macro-escrow-tracker!)
(define z-wr-ling-and-spine
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 2050
    #:minerals 150 #:gas 0 #:supply-used 12 #:supply-cap 22 #:supply-left 10 #:pending-supply 0
    #:workers 12 #:active-bases 1 #:mineral-harvesters 4 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 12 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'larva 2 'townhall 1))))
(check! (and (not (not (memq 'zergling (macro-brain-decision-scheduled-ids z-wr-ling-and-spine))))
             (>= (cand-u z-wr-ling-and-spine 'zergling) 780.0)
             (not (memq 'spine-crawler (macro-brain-decision-scheduled-ids z-wr-ling-and-spine)))
             (not (memq 'drone (macro-brain-decision-scheduled-ids z-wr-ling-and-spine)))
             (not (memq 'queen (macro-brain-decision-scheduled-ids z-wr-ling-and-spine))))
        (format "L48-WR(11) Zerg ready Pool @150M w/ 0 Lings (<6) MUST prioritize Zergling(780) BEFORE Spine/Drone/Queen: sched=~s u_ling=~a u_spine=~a"
                (macro-brain-decision-scheduled-ids z-wr-ling-and-spine)
                (cand-u z-wr-ling-and-spine 'zergling)
                (cand-u z-wr-ling-and-spine 'spine-crawler)))

;; (12) ZvZ Drone rush (12 enemy Drones) w/ 6 Zerglings @100M, 0 larva, ready Pool -> SpineCrawler(760) & suppress Queen!
(reset-macro-escrow-tracker!)
(define zvz-wr-spine-at-100m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Zerg #:frame 1950
    #:minerals 100 #:gas 0 #:supply-used 15 #:supply-cap 22 #:supply-left 7 #:pending-supply 0
    #:workers 12 #:active-bases 1 #:mineral-harvesters 4 #:gas-harvesters 0
    #:army-supply 3 #:enemy-threat-supply 12 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 12 'zergling 6 'overlord 2)
    #:enemy-unit-counts (hasheq 'drone 12)
    #:open-facility-slots (hasheq 'larva 0 'townhall 1))))
(check! (and (not (not (memq 'spine-crawler (macro-brain-decision-scheduled-ids zvz-wr-spine-at-100m))))
             (>= (cand-u zvz-wr-spine-at-100m 'spine-crawler) 760.0)
             (not (memq 'queen (macro-brain-decision-scheduled-ids zvz-wr-spine-at-100m))))
        (format "L48-WR(12) ZvZ 12-Drone rush w/ 6 Lings @100M MUST drop SpineCrawler(760) & suppress Queen: sched=~s u_spine=~a"
                (macro-brain-decision-scheduled-ids zvz-wr-spine-at-100m)
                (cand-u zvz-wr-spine-at-100m 'spine-crawler)))

;; ============================================================================
;; 4. Protoss Worker-Rush Macro Brain (`#5140055`, `#5138237`, `r16`)
;; ============================================================================

;; (13a) Protoss pre-Gateway @160M vs 12 Probes: Gateway(750), suppress Assimilator & Nexus#2!
(reset-macro-escrow-tracker!)
(define p-wr-gate1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 1050
    #:minerals 160 #:gas 0 #:supply-used 15 #:supply-cap 23 #:supply-left 8 #:pending-supply 0
    #:workers 15 #:active-bases 1 #:mineral-harvesters 10 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1)
    #:unit-counts (hasheq 'probe 15)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'townhall 1))))
(check! (and (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-wr-gate1))))
             (>= (cand-u p-wr-gate1 'gateway) 750.0)
             (not (memq 'assimilator (macro-brain-decision-scheduled-ids p-wr-gate1)))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-wr-gate1))))
        (format "L48-WR(13a) Protoss @160M vs 12 Probes MUST build Gateway#1(750) & suppress Assimilator/Nexus: sched=~s u_gw=~a"
                (macro-brain-decision-scheduled-ids p-wr-gate1)
                (cand-u p-wr-gate1 'gateway)))

;; (13b) Protoss ready Gateway w/ 1 Zealot (<2) @165M vs 12 Probes: Zealot(940), suppress Assim/Cyber/Nexus!
(reset-macro-escrow-tracker!)
(define p-wr-zealot2-suppress-tech
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 1850
    #:minerals 165 #:gas 0 #:supply-used 17 #:supply-cap 23 #:supply-left 6 #:pending-supply 0
    #:workers 15 #:active-bases 1 #:mineral-harvesters 8 #:gas-harvesters 0
    #:army-supply 2 #:enemy-threat-supply 12 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 15 'zealot 1)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(define p-wr-sched (macro-brain-decision-scheduled-ids p-wr-zealot2-suppress-tech))
(check! (and (not (not (memq 'zealot p-wr-sched)))
             (>= (cand-u p-wr-zealot2-suppress-tech 'zealot) 940.0)
             (not (memq 'cybernetics-core p-wr-sched))
             (not (memq 'assimilator p-wr-sched))
             (not (memq 'nexus p-wr-sched)))
        (format "L48-WR(13b) Protoss w/ 1 Zealot (<2) @165M vs 12 Probes MUST train Zealot(940) & suppress CyberCore/Assim/Nexus: sched=~s u_z=~a"
                p-wr-sched (cand-u p-wr-zealot2-suppress-tech 'zealot)))

;; (14) Protoss anti-deadlock release (#5140055 exact repro: workers <= 4 & 50 <= min < 100 -> allow 1 Probe!)
(reset-macro-escrow-tracker!)
(define p-wr-anti-deadlock-probe
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 2100
    #:minerals 80 #:gas 0 #:supply-used 4 #:supply-cap 23 #:supply-left 19 #:pending-supply 0
    #:workers 4 #:active-bases 1 #:mineral-harvesters 3 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 4)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(check! (and (not (not (memq 'probe (macro-brain-decision-scheduled-ids p-wr-anti-deadlock-probe))))
             (= (count (lambda (s) (eq? s 'probe))
                       (macro-brain-decision-scheduled-ids p-wr-anti-deadlock-probe))
                1))
        (format "L48-WR(14) #5140055 Protoss workers=4 (<=4) @80M (50..99M) MUST allow 1 anti-deadlock Probe: sched=~s save=~a"
                (macro-brain-decision-scheduled-ids p-wr-anti-deadlock-probe)
                (macro-brain-decision-saving-for p-wr-anti-deadlock-probe)))

;; (15) Protoss negative guard: healthy worker count (workers=12 > 8) @80M MUST escrow Zealot (NOT spend on Probe)!
(reset-macro-escrow-tracker!)
(define p-wr-healthy-workers-escrow-zealot
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 1850
    #:minerals 80 #:gas 0 #:supply-used 12 #:supply-cap 23 #:supply-left 11 #:pending-supply 0
    #:workers 12 #:active-bases 1 #:mineral-harvesters 6 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 12)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-wr-healthy-workers-escrow-zealot) 'zealot)
             (not (memq 'probe (macro-brain-decision-scheduled-ids p-wr-healthy-workers-escrow-zealot))))
        (format "L48-WR(15) Neg-guard Protoss workers=12 (>8) @80M MUST escrow Zealot instead of draining Probe: sched=~s save=~a"
                (macro-brain-decision-scheduled-ids p-wr-healthy-workers-escrow-zealot)
                (macro-brain-decision-saving-for p-wr-healthy-workers-escrow-zealot)))

;; ============================================================================
;; 5. Negative Guards: Peaceful Opening Scouts Seeing 16 Enemy Workers
;; ============================================================================

;; (16a) Peaceful ZvP opening @16/22, 300M where scout saw 16 Probes at enemy main (threat=0, under-attack?=#f):
;;       MUST still open 16-Hatch (NEVER false-trigger worker rush)!
(reset-macro-escrow-tracker!)
(define z-peaceful-scout-16probes
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 1050
    #:minerals 305 #:gas 0 #:supply-used 16 #:supply-cap 22 #:supply-left 6 #:pending-supply 0
    #:workers 16 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 1)
    #:total-building-counts (hasheq 'hatchery 1)
    #:unit-counts (hasheq 'drone 16 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 16)
    #:open-facility-slots (hasheq 'larva 2 'townhall 1))))
(check! (not (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-peaceful-scout-16probes))))
        (format "L48-WR(16a) Neg-guard peaceful ZvP scout seeing 16 enemy Probes MUST still open 16-Hatch: sched=~s"
                (macro-brain-decision-scheduled-ids z-peaceful-scout-16probes)))

;; (16b) Peaceful TvZ opening @16/23, 135M where scout saw 16 Drones at enemy main (threat=0, under-attack?=#f):
;;       MUST still build wall SupplyDepot #2 (>= 650)!
(reset-macro-escrow-tracker!)
(define t-peaceful-tvz-wall-depot2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Zerg #:frame 1120
    #:minerals 135 #:gas 0 #:supply-used 16 #:supply-cap 23 #:supply-left 7 #:pending-supply 0
    #:workers 16 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:unit-counts (hasheq 'scv 16)
    #:enemy-unit-counts (hasheq 'drone 16)
    #:open-facility-slots (hasheq 'townhall 1))))
(check! (and (not (not (memq 'supply-depot (macro-brain-decision-scheduled-ids t-peaceful-tvz-wall-depot2))))
             (>= (cand-u t-peaceful-tvz-wall-depot2 'supply-depot) 650.0))
        (format "L48-WR(16b) Neg-guard peaceful TvZ scout seeing 16 enemy Drones MUST still build wall Depot#2>=650: sched=~s u_dep=~a"
                (macro-brain-decision-scheduled-ids t-peaceful-tvz-wall-depot2)
                (cand-u t-peaceful-tvz-wall-depot2 'supply-depot)))

;; ============================================================================
;; 6. Loop 48 Wave 2 (`#1094`/`#1096`): r14 Spine#1 Priority, r15 Rax<=1, r16 GW<=1
;; ============================================================================

;; (17) r16 Protoss exact repro: Gateway #1 ready (busy training or open), 0 Zealots, 165M vs 15 Probes:
;;      MUST hard-cap Gateway <= 1 (NEVER spend 150M on Gateway #2 until >= 3 Zealots)!
(reset-macro-escrow-tracker!)
(define p-r16-cap-gw1-until-3zealots
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 1400
    #:minerals 165 #:gas 0 #:supply-used 15 #:supply-cap 23 #:supply-left 8 #:pending-supply 0
    #:workers 15 #:active-bases 1 #:mineral-harvesters 6 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 15)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(check! (and (not (memq 'gateway (macro-brain-decision-scheduled-ids p-r16-cap-gw1-until-3zealots)))
             (not (eq? (macro-brain-decision-saving-for p-r16-cap-gw1-until-3zealots) 'gateway)))
        (format "L48-WR(17) r16 Protoss w/ 1 GW & 0 Zealots (<3) @165M MUST cap Gateway<=1 (no GW#2): sched=~s save=~a"
                (macro-brain-decision-scheduled-ids p-r16-cap-gw1-until-3zealots)
                (macro-brain-decision-saving-for p-r16-cap-gw1-until-3zealots)))

;; (18) r15 Terran exact repro: Barracks #1 ready (busy), 1 Marine (<4), 165M vs 15 Probes:
;;      MUST hard-cap Barracks <= 1 (NEVER spend 150M on Barracks #2 until >= 4 Marines)!
(reset-macro-escrow-tracker!)
(define t-r15-cap-rax1-until-4marines
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 1400
    #:minerals 165 #:gas 0 #:supply-used 15 #:supply-cap 23 #:supply-left 8 #:pending-supply 0
    #:workers 14 #:active-bases 1 #:mineral-harvesters 6 #:gas-harvesters 0
    #:army-supply 1 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:unit-counts (hasheq 'scv 14 'marine 1)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 0))))
(check! (and (not (memq 'barracks (macro-brain-decision-scheduled-ids t-r15-cap-rax1-until-4marines)))
             (not (eq? (macro-brain-decision-saving-for t-r15-cap-rax1-until-4marines) 'barracks)))
        (format "L48-WR(18) r15 Terran w/ 1 Rax & 1 Marine (<4) @165M MUST cap Barracks<=1 (no Rax#2): sched=~s save=~a"
                (macro-brain-decision-scheduled-ids t-r15-cap-rax1-until-4marines)
                (macro-brain-decision-saving-for t-r15-cap-rax1-until-4marines)))

;; (19) L48-W3B (`#1116` `r14` Zerg): First 6 Zerglings (780.0, bypassing Spine escrow) BEFORE SpineCrawler #1 (760.0):
;;      (19a) 0 Lings (<6) @65M, 0 Spine, 2 larva -> train Zergling immediately (NO Spine escrow, NO Drone)!
;;      (19b) 6 Lings (>=6) @65M, 0 Spine, 2 larva -> escrow SpineCrawler#1(760) ahead of extra Zergling(740)!
;;      (19c) 6 Lings (>=6) @60M, 1 Spine, 2 larva -> pump extra Zergling(740)!
(reset-macro-escrow-tracker!)
(define z-r14-first6-lings-at-65m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 1800
    #:minerals 65 #:gas 0 #:supply-used 12 #:supply-cap 22 #:supply-left 10 #:pending-supply 0
    #:workers 12 #:active-bases 1 #:mineral-harvesters 5 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 12 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'larva 2 'townhall 1))))
(reset-macro-escrow-tracker!)
(define z-r14-at6lings-escrow-spine1-at-65m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 1830
    #:minerals 65 #:gas 0 #:supply-used 15 #:supply-cap 22 #:supply-left 7 #:pending-supply 0
    #:workers 12 #:active-bases 1 #:mineral-harvesters 5 #:gas-harvesters 0
    #:army-supply 3 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 12 'zergling 6 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'larva 2 'townhall 1))))
(reset-macro-escrow-tracker!)
(define z-r14-after-spine1-pump-lings
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 1850
    #:minerals 60 #:gas 0 #:supply-used 14 #:supply-cap 22 #:supply-left 8 #:pending-supply 0
    #:workers 11 #:active-bases 1 #:mineral-harvesters 5 #:gas-harvesters 0
    #:army-supply 3 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1 'spine-crawler 1)
    #:unit-counts (hasheq 'drone 11 'zergling 6 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'larva 2 'townhall 1))))
(check! (and (not (not (memq 'zergling (macro-brain-decision-scheduled-ids z-r14-first6-lings-at-65m))))
             (>= (cand-u z-r14-first6-lings-at-65m 'zergling) 780.0)
             (not (eq? (macro-brain-decision-saving-for z-r14-first6-lings-at-65m) 'spine-crawler))
             (not (memq 'drone (macro-brain-decision-scheduled-ids z-r14-first6-lings-at-65m)))
             (eq? (macro-brain-decision-saving-for z-r14-at6lings-escrow-spine1-at-65m) 'spine-crawler)
             (>= (cand-u z-r14-at6lings-escrow-spine1-at-65m 'spine-crawler) 760.0)
             (not (memq 'zergling (macro-brain-decision-scheduled-ids z-r14-at6lings-escrow-spine1-at-65m)))
             (not (not (memq 'zergling (macro-brain-decision-scheduled-ids z-r14-after-spine1-pump-lings)))))
        (format "L48-WR(19) r14 Zerg MUST train first 6 Lings(780) before Spine#1, then escrow Spine#1(760) at 6 Lings, then pump Lings: pre6=~s/sav=~a at6=~s/sav=~a post=~s"
                (macro-brain-decision-scheduled-ids z-r14-first6-lings-at-65m)
                (macro-brain-decision-saving-for z-r14-first6-lings-at-65m)
                (macro-brain-decision-scheduled-ids z-r14-at6lings-escrow-spine1-at-65m)
                (macro-brain-decision-saving-for z-r14-at6lings-escrow-spine1-at-65m)
                (macro-brain-decision-scheduled-ids z-r14-after-spine1-pump-lings)))

;; ============================================================================
;; 7. Loop 48 Wave 3B (`#1116`): Pause Worker Training While Breaking Out (<3 Combat, >=10W)
;; ============================================================================

;; (20) r16 Protoss exact `1006=1/2` (-50..-100M) leak repro: Gateway #1 ready & BUSY (open gateway=0),
;;      1 Zealot (<3), 7 Probes (>=5, even below 10!) @160M -> MUST pause Probe training (zero mineral drain)!
;;      Once 3 Zealots exist (3 >= 3, supply-left=11), Probe training resumes cleanly!
(reset-macro-escrow-tracker!)
(define p-r16-pause-probe-busy-gw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 1450
    #:minerals 160 #:gas 0 #:supply-used 9 #:supply-cap 31 #:supply-left 22 #:pending-supply 0
    #:workers 7 #:active-bases 1 #:mineral-harvesters 4 #:gas-harvesters 0
    #:army-supply 2 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
    #:unit-counts (hasheq 'probe 7 'zealot 1)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(reset-macro-escrow-tracker!)
(define p-r16-resume-probe-at-3zealots
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 2200
    #:minerals 210 #:gas 0 #:supply-used 20 #:supply-cap 31 #:supply-left 11 #:pending-supply 0
    #:workers 14 #:active-bases 1 #:mineral-harvesters 8 #:gas-harvesters 0
    #:army-supply 6 #:enemy-threat-supply 12 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
    #:unit-counts (hasheq 'probe 14 'zealot 3)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(check! (and (not (memq 'probe (macro-brain-decision-scheduled-ids p-r16-pause-probe-busy-gw)))
             (not (eq? (macro-brain-decision-saving-for p-r16-pause-probe-busy-gw) 'probe))
             (not (not (memq 'probe (macro-brain-decision-scheduled-ids p-r16-resume-probe-at-3zealots)))))
        (format "L48-WR(20) r16 Protoss busy GW w/ 1 Zealot (<3) & 14W @160M MUST pause Probe, then resume at 3 Zealots: pause=~s/sav=~a resume=~s/sav=~a"
                (macro-brain-decision-scheduled-ids p-r16-pause-probe-busy-gw)
                (macro-brain-decision-saving-for p-r16-pause-probe-busy-gw)
                (macro-brain-decision-scheduled-ids p-r16-resume-probe-at-3zealots)
                (macro-brain-decision-saving-for p-r16-resume-probe-at-3zealots)))

;; (21) r15 Terran busy Barracks #1: 1 Marine (<3), 14 SCVs (>=10), 160M -> MUST pause SCV!
;;      Once 3 Marines exist (3 >= 3) w/ busy Barracks, SCV resumes cleanly!
(reset-macro-escrow-tracker!)
(define t-r15-pause-scv-busy-rax
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 1450
    #:minerals 160 #:gas 0 #:supply-used 15 #:supply-cap 23 #:supply-left 8 #:pending-supply 0
    #:workers 14 #:active-bases 1 #:mineral-harvesters 4 #:gas-harvesters 0
    #:army-supply 1 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:unit-counts (hasheq 'scv 14 'marine 1)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 0))))
(reset-macro-escrow-tracker!)
(define t-r15-resume-scv-at-3marines
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 1900
    #:minerals 160 #:gas 0 #:supply-used 17 #:supply-cap 23 #:supply-left 6 #:pending-supply 0
    #:workers 14 #:active-bases 1 #:mineral-harvesters 6 #:gas-harvesters 0
    #:army-supply 3 #:enemy-threat-supply 12 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
    #:unit-counts (hasheq 'scv 14 'marine 3)
    #:enemy-unit-counts (hasheq 'probe 12)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 0))))
(check! (and (not (memq 'scv (macro-brain-decision-scheduled-ids t-r15-pause-scv-busy-rax)))
             (not (eq? (macro-brain-decision-saving-for t-r15-pause-scv-busy-rax) 'scv))
             (not (not (memq 'scv (macro-brain-decision-scheduled-ids t-r15-resume-scv-at-3marines)))))
        (format "L48-WR(21) r15 Terran busy Rax w/ 1 Marine (<3) & 14W @160M MUST pause SCV, then resume at 3 Marines: pause=~s/sav=~a resume=~s/sav=~a"
                (macro-brain-decision-scheduled-ids t-r15-pause-scv-busy-rax)
                (macro-brain-decision-saving-for t-r15-pause-scv-busy-rax)
                (macro-brain-decision-scheduled-ids t-r15-resume-scv-at-3marines)
                (macro-brain-decision-saving-for t-r15-resume-scv-at-3marines)))

;; (22) r14 Zerg ready Pool w/ 4 Zerglings (<6), 14 Drones (>=10), 75M, 2 open larva:
;;      MUST train Zergling (780.0), pause Drone, and NOT build/escrow SpineCrawler yet!
(reset-macro-escrow-tracker!)
(define z-r14-pause-drone-4lings
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 1820
    #:minerals 75 #:gas 0 #:supply-used 16 #:supply-cap 22 #:supply-left 6 #:pending-supply 0
    #:workers 14 #:active-bases 1 #:mineral-harvesters 4 #:gas-harvesters 0
    #:army-supply 2 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 14 'zergling 4 'overlord 2)
    #:enemy-unit-counts (hasheq 'probe 15)
    #:open-facility-slots (hasheq 'larva 2 'townhall 1))))
(check! (and (not (not (memq 'zergling (macro-brain-decision-scheduled-ids z-r14-pause-drone-4lings))))
             (>= (cand-u z-r14-pause-drone-4lings 'zergling) 780.0)
             (not (memq 'drone (macro-brain-decision-scheduled-ids z-r14-pause-drone-4lings)))
             (not (memq 'spine-crawler (macro-brain-decision-scheduled-ids z-r14-pause-drone-4lings))))
        (format "L48-WR(22) r14 Zerg w/ 4 Lings (<6) & 14W @75M MUST train Zergling(780) & pause Drone/Spine: sched=~s u_ling=~a"
                (macro-brain-decision-scheduled-ids z-r14-pause-drone-4lings)
                (cand-u z-r14-pause-drone-4lings 'zergling)))

(reset-macro-escrow-tracker!)
(printf "l48-worker-rush-macro-test: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
