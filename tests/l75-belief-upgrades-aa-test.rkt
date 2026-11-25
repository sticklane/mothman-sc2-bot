#lang racket/base

;; =============================================================================
;; Loop 75 Lane A Unit Test Suite (`tests/l75-belief-upgrades-aa-test.rkt`)
;;
;; Verifies Loop 75 Lane A (`lib/priority-macro-brain.rkt`):
;;   1. `t3-endgame-window?` cash-near (`>= 150M/150G`) ready-prereq `+2/+3`
;;      Weapons & `+1/+2/+3` Armor/Carapace utility boosts (`518-526`) across
;;      Zerg, Terran, and Protoss — staying at base `462-474` when broke
;;      (`50M/50G`) and NEVER firing on `< 3` bases (zero early 2-base greed!).
;;   2. Terran `Armory` in `t3-endgame-window?`: stays `468.0` at `frame = 6000`
;;      or without `+1W`, rises to `516.0` at `frame = 10500` (`>= 10080f`) with
;;      `+1W` researched & `200M/120G`.
;;   3. TvT `terran-tvt-tank4-defer-air-sym?`: lifts `< 250G` Armory suppression
;;      strictly at `frame >= 10080` after `+1W`, while still holding `< 10080f`
;;      and when `+1W` is missing.
;;   4. `#5148545` Phoenix cloak-air crisis fix:
;;      - 15 Marines + 6 Widow Mines + 4 Medivacs + 1 Banshee + 3 Phoenixes ->
;;        `phoenix` does NOT boost to `860.0`;
;;      - 0 Banshees + 6 Widow Mines + 4 Medivacs + 1 Phoenix -> `phoenix` does
;;        NOT boost to `860.0`;
;;      - 1 Banshee + 4 Marines (`< 20` ground sup) + 0 Phoenixes -> `phoenix`
;;        STILL boosts `>= 860.0`;
;;      - 2 Banshees + 15 Marines + 0 Phoenixes -> `phoenix` boosts `>= 860.0`,
;;        and at cap (`4` Phoenixes) respects `(not protoss-phoenix-capped?)`.
;; =============================================================================

(require racket/list
         racket/format
         "../lib/econ-ledger.rkt"
         "../lib/priority-macro-brain.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (plan-goal-weight dp id [reason 't3-endgame-tech])
  (define hit
    (findf (lambda (g)
             (and (eq? (plan-goal-node-id g) id)
                  (or (not reason) (eq? (plan-goal-node-reason g) reason))))
           (dynamic-macro-plan-all-goals dp)))
  (and hit (plan-goal-node-priority-weight hit)))

(define (cand-u dec sym)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))
  (define hit (findf (lambda (e) (eq? (priority-decision-entry-id e) sym)) trace))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

;; =============================================================================
;; 1. Zerg `t3-endgame-window?` Cash-Near +1/+2/+3 Upgrades & Zero 2-Base Greed
;; =============================================================================
(let ()
  (define (mk-z-state #:bases [bases 3] #:workers [w 54] #:minerals [m 200] #:gas [g 200]
                      #:ready-bldgs [rb (hasheq 'hatchery 2 'lair 1 'spawning-pool 1
                                                'roach-warren 1 'evolution-chamber 2)]
                      #:upgs [upgs '(zerg-missile-weapons-1)])
    (make-macro-world-state
     #:race 'Zerg #:enemy-race 'Protoss #:frame 11000
     #:minerals m #:gas g #:supply-used 110 #:supply-cap 130 #:supply-left 20 #:pending-supply 0
     #:workers w #:active-bases bases #:mineral-harvesters (- w 12) #:gas-harvesters 12
     #:army-supply 56 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts rb
     #:total-building-counts rb
     #:unit-counts (hasheq 'drone w 'roach 16 'hydralisk 10 'queen 4)
     #:researched-upgrades upgs
     #:open-facility-slots (hasheq 'townhall 3 'evolution-chamber 2)))

  (define dp-z-cash (synthesize-dynamic-macro-plan (mk-z-state)))
  (define dp-z-broke (synthesize-dynamic-macro-plan (mk-z-state #:minerals 50 #:gas 50)))
  (define dp-z-2base (synthesize-dynamic-macro-plan (mk-z-state #:bases 2 #:workers 42)))
  (define dp-z-hive
    (synthesize-dynamic-macro-plan
     (mk-z-state #:ready-bldgs (hasheq 'hatchery 2 'hive 1 'spawning-pool 1
                                       'roach-warren 1 'evolution-chamber 2 'infestation-pit 1)
                 #:upgs '(zerg-missile-weapons-1 zerg-missile-weapons-2
                          zerg-ground-armor-1 zerg-ground-armor-2))))

  (check! (and (equal? (plan-goal-weight dp-z-cash 'zerg-ground-armor-1) 522.0)
               (equal? (plan-goal-weight dp-z-cash 'zerg-missile-weapons-2) 526.0)
               (equal? (plan-goal-weight dp-z-cash 'zerg-ground-armor-2) 468.0)
               (equal? (plan-goal-weight dp-z-broke 'zerg-ground-armor-1) 472.0)
               (equal? (plan-goal-weight dp-z-broke 'zerg-missile-weapons-2) 468.0)
               (not (plan-goal-weight dp-z-2base 'zerg-missile-weapons-2))
               (equal? (plan-goal-weight dp-z-hive 'zerg-missile-weapons-3) 524.0)
               (equal? (plan-goal-weight dp-z-hive 'zerg-ground-armor-3) 518.0))
          (format "1. Zerg cash-near +1/+2/+3 must boost to 518-526 on 3b+cash, stay base when broke, skip 2b; got a1=~s m2=~s a2=~s brk=~s 2b=~s m3=~s a3=~s"
                  (plan-goal-weight dp-z-cash 'zerg-ground-armor-1)
                  (plan-goal-weight dp-z-cash 'zerg-missile-weapons-2)
                  (plan-goal-weight dp-z-cash 'zerg-ground-armor-2)
                  (plan-goal-weight dp-z-broke 'zerg-missile-weapons-2)
                  (plan-goal-weight dp-z-2base 'zerg-missile-weapons-2)
                  (plan-goal-weight dp-z-hive 'zerg-missile-weapons-3)
                  (plan-goal-weight dp-z-hive 'zerg-ground-armor-3))))

;; =============================================================================
;; 2. Terran `t3-endgame-window?` Cash-Near +2/+3 Upgrades & `>= 7:30` Armory
;; =============================================================================
(let ()
  (define (mk-t-state #:frame [f 10500] #:bases [bases 3] #:minerals [m 200] #:gas [g 200]
                      #:armory? [armory? #t]
                      #:upgs [upgs '(terran-infantry-weapons-1 terran-infantry-armor-1)])
    (define bldgs
      (if armory?
          (hasheq 'orbital-command bases 'barracks 5 'factory 1 'starport 1
                  'engineering-bay 2 'armory 1 'refinery 4)
          (hasheq 'orbital-command bases 'barracks 5 'factory 1 'starport 1
                  'engineering-bay 2 'refinery 4)))
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Zerg #:frame f
     #:minerals m #:gas g #:supply-used 112 #:supply-cap 134 #:supply-left 22 #:pending-supply 0
     #:workers 54 #:active-bases bases #:mineral-harvesters 42 #:gas-harvesters 12
     #:army-supply 58 #:enemy-threat-supply 18 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts bldgs
     #:total-building-counts bldgs
     #:unit-counts (hasheq 'scv 54 'marine 28 'marauder 8 'medivac 4 'siege-tank 2)
     #:researched-upgrades upgs
     #:open-facility-slots (hasheq 'townhall 3 'barracks 3 'engineering-bay 2)))

  (define dp-t-cash (synthesize-dynamic-macro-plan (mk-t-state)))
  (define dp-t-broke (synthesize-dynamic-macro-plan (mk-t-state #:minerals 50 #:gas 50)))
  (define dp-t-plus3
    (synthesize-dynamic-macro-plan
     (mk-t-state #:upgs '(terran-infantry-weapons-1 terran-infantry-weapons-2
                          terran-infantry-armor-1 terran-infantry-armor-2))))
  (define dp-t-arm-early (synthesize-dynamic-macro-plan (mk-t-state #:frame 6000 #:minerals 200 #:gas 120 #:armory? #f)))
  (define dp-t-arm-late  (synthesize-dynamic-macro-plan (mk-t-state #:frame 10500 #:minerals 200 #:gas 120 #:armory? #f)))
  (define dp-t-arm-no1w  (synthesize-dynamic-macro-plan (mk-t-state #:frame 10500 #:minerals 200 #:gas 120 #:armory? #f #:upgs '())))

  (check! (and (equal? (plan-goal-weight dp-t-cash 'terran-infantry-weapons-2) 526.0)
               (equal? (plan-goal-weight dp-t-cash 'terran-infantry-armor-2) 522.0)
               (equal? (plan-goal-weight dp-t-broke 'terran-infantry-weapons-2) 466.0)
               (equal? (plan-goal-weight dp-t-broke 'terran-infantry-armor-2) 464.0)
               (equal? (plan-goal-weight dp-t-plus3 'terran-infantry-weapons-3) 524.0)
               (equal? (plan-goal-weight dp-t-plus3 'terran-infantry-armor-3) 518.0)
               (equal? (plan-goal-weight dp-t-arm-early 'armory) 468.0)
               (equal? (plan-goal-weight dp-t-arm-late 'armory) 516.0)
               (equal? (plan-goal-weight dp-t-arm-no1w 'armory) 468.0))
          (format "2. Terran +2/+3 & >=7:30 Armory weights mismatch; w2=~s a2=~s brkW2=~s w3=~s a3=~s arm6k=~s arm105k=~s armNo1w=~s"
                  (plan-goal-weight dp-t-cash 'terran-infantry-weapons-2)
                  (plan-goal-weight dp-t-cash 'terran-infantry-armor-2)
                  (plan-goal-weight dp-t-broke 'terran-infantry-weapons-2)
                  (plan-goal-weight dp-t-plus3 'terran-infantry-weapons-3)
                  (plan-goal-weight dp-t-plus3 'terran-infantry-armor-3)
                  (plan-goal-weight dp-t-arm-early 'armory)
                  (plan-goal-weight dp-t-arm-late 'armory)
                  (plan-goal-weight dp-t-arm-no1w 'armory))))

;; =============================================================================
;; 3. Protoss `t3-endgame-window?` Cash-Near +2/+3 & Armor Upgrades
;; =============================================================================
(let ()
  (define (mk-p-state #:bases [bases 3] #:minerals [m 200] #:gas [g 200]
                      #:upgs [upgs '(protoss-ground-weapons-1)])
    (define bldgs
      (hasheq 'nexus bases 'pylon 10 'gateway 4 'warp-gate 4 'cybernetics-core 1
              'robotics-facility 1 'twilight-council 1 'forge 2 'assimilator 4))
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 10800
     #:minerals m #:gas g #:supply-used 110 #:supply-cap 130 #:supply-left 20 #:pending-supply 0
     #:workers 54 #:active-bases bases #:mineral-harvesters 42 #:gas-harvesters 12
     #:army-supply 56 #:enemy-threat-supply 18 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts bldgs
     #:total-building-counts bldgs
     #:unit-counts (hasheq 'probe 54 'stalker 14 'zealot 8 'immortal 3)
     #:researched-upgrades upgs
     #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'forge 2)))

  (define dp-p-cash (synthesize-dynamic-macro-plan (mk-p-state)))
  (define dp-p-broke (synthesize-dynamic-macro-plan (mk-p-state #:minerals 50 #:gas 50)))
  (define dp-p-plus3
    (synthesize-dynamic-macro-plan
     (mk-p-state #:upgs '(protoss-ground-weapons-1 protoss-ground-weapons-2 protoss-ground-armor-1))))

  (check! (and (equal? (plan-goal-weight dp-p-cash 'protoss-ground-weapons-2) 526.0)
               (equal? (plan-goal-weight dp-p-cash 'protoss-ground-armor-1) 520.0)
               (equal? (plan-goal-weight dp-p-broke 'protoss-ground-weapons-2) 474.0)
               (equal? (plan-goal-weight dp-p-broke 'protoss-ground-armor-1) 470.0)
               (equal? (plan-goal-weight dp-p-plus3 'protoss-ground-weapons-3) 524.0)
               (equal? (plan-goal-weight dp-p-plus3 'protoss-ground-armor-2) 518.0))
          (format "3. Protoss cash-near +2/+3 & Armor weights mismatch; w2=~s a1=~s brkW2=~s w3=~s a2=~s"
                  (plan-goal-weight dp-p-cash 'protoss-ground-weapons-2)
                  (plan-goal-weight dp-p-cash 'protoss-ground-armor-1)
                  (plan-goal-weight dp-p-broke 'protoss-ground-weapons-2)
                  (plan-goal-weight dp-p-plus3 'protoss-ground-weapons-3)
                  (plan-goal-weight dp-p-plus3 'protoss-ground-armor-2))))

;; =============================================================================
;; 4. TvT `terran-tvt-tank4-defer-air-sym?` Lifts Armory `< 250G` at `>= 10080f` + `+1W`
;; =============================================================================
(let ()
  (define (mk-tvt-state frame upgs)
    (define bldgs
      (hasheq 'orbital-command 4 'supply-depot 14 'barracks 5 'barracks-reactor 2 'barracks-techlab 1
              'factory 2 'factory-techlab 2 'starport 1 'engineering-bay 2 'refinery 6))
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Terran #:frame frame
     #:minerals 300 #:gas 150 #:supply-used 108 #:supply-cap 130 #:supply-left 22 #:pending-supply 0
     #:workers 60 #:active-bases 4 #:mineral-harvesters 48 #:gas-harvesters 12
     #:army-supply 54 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts bldgs
     #:total-building-counts bldgs
     #:unit-counts (hasheq 'scv 60 'marine 24 'marauder 4 'siege-tank 2 'medivac 2)
     #:enemy-unit-counts (hasheq 'marine 14 'siege-tank 2)
     #:researched-upgrades upgs
     #:open-facility-slots (hasheq 'townhall 4 'barracks 2 'factory 0 'starport 0 'engineering-bay 2)))

  (reset-macro-escrow-tracker!)
  (define d-early (step-priority-macro-brain (mk-tvt-state 7000 '(terran-infantry-weapons-1))))
  (reset-macro-escrow-tracker!)
  (define d-late-1w (step-priority-macro-brain (mk-tvt-state 10500 '(terran-infantry-weapons-1))))
  (reset-macro-escrow-tracker!)
  (define d-late-no1w (step-priority-macro-brain (mk-tvt-state 10500 '())))

  (define u-early (cand-u d-early 'armory))
  (define u-late-1w (cand-u d-late-1w 'armory))
  (define u-late-no1w (cand-u d-late-no1w 'armory))
  (define s-early (macro-brain-decision-scheduled-ids d-early))
  (define s-late-1w (macro-brain-decision-scheduled-ids d-late-1w))
  (define s-late-no1w (macro-brain-decision-scheduled-ids d-late-no1w))
  (check! (and (<= u-early 440.0)
               (not (memq 'armory s-early))
               (<= u-late-no1w 440.0)
               (not (memq 'armory s-late-no1w))
               (> u-late-1w 440.0)
               (not (not (memq 'armory s-late-1w))))
          (format "4. TvT Tank<4 Armory (<250G) must stay deferred at f=7000 or without +1W, and unlock/schedule at f=10500 with +1W; early=~a/~s no1w=~a/~s late1w=~a/~s"
                  u-early s-early u-late-no1w s-late-no1w u-late-1w s-late-1w)))

;; =============================================================================
;; 5. `#5148545` Phoenix Cloak-Air Crisis Fix & Phoenix Cap Protection
;; =============================================================================
(let ()
  (define (mk-pvt-state #:phoenixes phx #:enemy-units eu #:req-aa? [req-aa? #t] #:req-det? [req-det? #t])
    (define bldgs
      (hasheq 'nexus 3 'pylon 10 'gateway 4 'warp-gate 4 'cybernetics-core 1
              'robotics-facility 1 'robotics-bay 1 'stargate 1 'twilight-council 1 'forge 1 'assimilator 4))
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 9500
     #:minerals 400 #:gas 300 #:supply-used 100 #:supply-cap 124 #:supply-left 24 #:pending-supply 0
     #:workers 50 #:active-bases 3 #:mineral-harvesters 38 #:gas-harvesters 12
     #:army-supply 50 #:enemy-threat-supply 30 #:under-attack? #f
     #:requires-anti-air? req-aa? #:requires-detection? req-det?
     #:ready-building-counts bldgs
     #:total-building-counts bldgs
     #:unit-counts (hasheq 'probe 50 'stalker 10 'zealot 6 'immortal 2 'observer 1 'phoenix phx)
     #:enemy-unit-counts eu
     #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1 'stargate 1)))

  ;; 5a: #5148545 — 15 Marines + 6 Widow Mines + 4 Medivacs + 1 Banshee & 3 Phoenixes -> NO 860 boost!
  (reset-macro-escrow-tracker!)
  (define d-5148545
    (step-priority-macro-brain
     (mk-pvt-state #:phoenixes 3
                   #:enemy-units (hasheq 'marine 15 'widow-mine-burrowed 6 'medivac 4 'banshee 1))))
  ;; 5b: Widow Mines + Medivacs ONLY (0 Banshees) & 1 Phoenix -> NO 860 boost!
  (reset-macro-escrow-tracker!)
  (define d-wm-med
    (step-priority-macro-brain
     (mk-pvt-state #:phoenixes 1
                   #:enemy-units (hasheq 'marine 14 'widow-mine-burrowed 6 'medivac 4))))
  ;; 5c: Real early Banshee threat (1 Banshee, 4 Marines < 20 ground sup, 0 Phoenixes) -> STILL boosts >= 860!
  (reset-macro-escrow-tracker!)
  (define d-1ban-lowgnd
    (step-priority-macro-brain
     (mk-pvt-state #:phoenixes 0
                   #:enemy-units (hasheq 'marine 4 'banshee 1))))
  ;; 5d: Real multi-Banshee threat (2 Banshees + 15 Marines): 0 Phoenixes boosts >= 860, 4 Phoenixes (at cap) suppressed!
  (reset-macro-escrow-tracker!)
  (define d-2ban-0phx
    (step-priority-macro-brain
     (mk-pvt-state #:phoenixes 0
                   #:enemy-units (hasheq 'marine 15 'banshee 2))))
  (reset-macro-escrow-tracker!)
  (define d-2ban-cap4
    (step-priority-macro-brain
     (mk-pvt-state #:phoenixes 4
                   #:enemy-units (hasheq 'marine 15 'banshee 2))))

  (define u-5148545 (cand-u d-5148545 'phoenix))
  (define u-wm-med  (cand-u d-wm-med 'phoenix))
  (define u-1ban    (cand-u d-1ban-lowgnd 'phoenix))
  (define u-2ban-0  (cand-u d-2ban-0phx 'phoenix))
  (define u-2ban-4  (cand-u d-2ban-cap4 'phoenix))
  (check! (and (< u-5148545 800.0)
               (< u-wm-med 800.0)
               (>= u-1ban 860.0)
               (>= u-2ban-0 860.0)
               (< u-2ban-4 100.0))
          (format "5. #5148545 Phoenix crisis fix failed; 5148545=~a wmMed=~a 1banLowGnd=~a 2ban0=~a 2banCap4=~a"
                  u-5148545 u-wm-med u-1ban u-2ban-0 u-2ban-4)))

(printf "l75-belief-upgrades-aa-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
