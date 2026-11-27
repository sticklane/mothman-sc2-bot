#lang racket/base

;; =============================================================================
;; Loop 86 Track 2 Unit Tests: General Anti-Greed / Anti-Turtle Macro & Gas Valve
;;   1. Protoss 4th / 5th / 6th Nexus pacing & rush/under-attack safety guards
;;   2. Terran 4th / 5th / 6th CC pacing & Zerg 5th / 6th Hatchery cap lifts
;;   3. Late-game gas_rich_min_starved cure across priority-macro-brain,
;;      worker-saturation-policy, and stall-watchdog
;;   4. Early static-defense / burrowed-mine turtle siege-breaker & mobile
;;      detector macro across Protoss, Terran, and Zerg
;; =============================================================================

(require racket/list
         "../lib/econ-ledger.rkt"
         "../lib/priority-macro-brain.rkt"
         "../lib/plan/worker-saturation-policy.rkt"
         "../lib/stall-watchdog.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check! cond-val msg)
  (if cond-val
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (eprintf "FAIL: ~a\n" msg))))

(define (cand-entry dec sym)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))
  (findf (lambda (e) (eq? (priority-decision-entry-id e) sym)) trace))

(define (cand-u dec sym)
  (define hit (cand-entry dec sym))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

(define (cand-blk? dec sym)
  (define hit (cand-entry dec sym))
  (and hit (priority-decision-entry-blocking-allowed? hit) #t))

(define (mk-w tag x y #:type [ut 'probe] #:ab [ab 298] #:tgt [tgt 0] #:cmin? [cm? #f] #:cgas? [cg? #f])
  (sat-worker-info tag ut x y ab tgt cm? cg? #f #f))

(define (mk-b tag x y #:type [ut 'nexus] #:ready? [ready? #t] #:flying? [flying? #f] #:asgn [asgn 12] #:ideal [ideal 16] #:threat [threat #f] #:patches [patches '()])
  (sat-base-info tag ut x y ready? flying? asgn ideal threat patches))

(define (mk-g tag x y #:type [ut 'assimilator] #:ready? [ready? #t] #:vesp [vesp 2000] #:asgn [asgn 3] #:ideal [ideal 3] #:base [nb #f] #:threat [threat #f])
  (sat-gas-info tag ut x y ready? vesp asgn ideal nb threat))

(define (mk-m tag x y #:mins [mins 1500] #:owner [owner #f] #:safe? [safe? #t])
  (sat-mineral-info tag x y mins owner safe?))

(define (gas-pull-worker-count ds)
  (for/sum ([d (in-list ds)]
            #:when (and (eq? (sat-directive-kind d) 'harvest-gather)
                        (memq (sat-directive-reason d)
                              '(gas-pull-grms-urgent gas-pull-routine gas-pull-early gas-pull-mined-out-evac))))
    (length (sat-directive-unit-tags d))))

;; =============================================================================
;; Section 1: Protoss 4th / 5th / 6th Nexus Pacing & Rush-Safety Guards
;; =============================================================================

;; 1a: 3-base Protoss at 7:30 with 4 Gateways (not 8!), 54 Probes, turtle/base-lead signal -> 4th Nexus boosted >= 605
(reset-macro-escrow-tracker!)
(define p-4th-anti-turtle
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10080
    #:minerals 280 #:gas 180 #:supply-used 98 #:supply-cap 124 #:supply-left 26 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 54 'stalker 12 'immortal 2 'observer 2)
    #:enemy-building-counts (hasheq 'command-center 4 'bunker 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65
                             'enemy-static-def-count 2
                             'enemy-confirmed-bases 4
                             'rush-prob 0.05))))
(check! (and (>= (cand-u p-4th-anti-turtle 'nexus) 605.0)
             (cand-blk? p-4th-anti-turtle 'nexus))
        (format "1a. Protoss 3b 4th Nexus anti-turtle should score >=605 & blk=#t; got u=~a blk=~a sav=~a sched=~s"
                (cand-u p-4th-anti-turtle 'nexus)
                (cand-blk? p-4th-anti-turtle 'nexus)
                (macro-brain-decision-saving-for p-4th-anti-turtle)
                (macro-brain-decision-scheduled-ids p-4th-anti-turtle)))

;; 1b: 4-base Protoss at 10:00 with 6 Gateways & 50 army (previously hard-capped below 8 GW / 75 army!) -> 5th Nexus unblocked!
(reset-macro-escrow-tracker!)
(define p-5th-anti-turtle
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 13440
    #:minerals 320 #:gas 220 #:supply-used 110 #:supply-cap 140 #:supply-left 30 #:pending-supply 0
    #:workers 60 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 16
    #:army-supply 50 #:enemy-threat-supply 6 #:under-attack? #f
    #:depleting-bases 1
    #:ready-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 60 'stalker 18 'immortal 2 'colossus 1 'observer 2)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.60 'enemy-confirmed-bases 6 'rush-prob 0.04))))
(check! (and (>= (cand-u p-5th-anti-turtle 'nexus) 610.0)
             (cand-blk? p-5th-anti-turtle 'nexus))
        (format "1b. Protoss 4b 5th Nexus should lift old <8GW/<75army cap & score >=610; got u=~a blk=~a sav=~a"
                (cand-u p-5th-anti-turtle 'nexus)
                (cand-blk? p-5th-anti-turtle 'nexus)
                (macro-brain-decision-saving-for p-5th-anti-turtle)))

;; 1c: 5-base Protoss at 12:30 with 2 depleting bases -> 6th Nexus unblocked & prioritized (>= 675)!
(reset-macro-escrow-tracker!)
(define p-6th-depleting
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 16800
    #:minerals 420 #:gas 300 #:supply-used 124 #:supply-cap 160 #:supply-left 36 #:pending-supply 0
    #:workers 60 #:active-bases 5 #:mineral-harvesters 42 #:gas-harvesters 18
    #:army-supply 66 #:enemy-threat-supply 4 #:under-attack? #f
    #:depleting-bases 2
    #:ready-building-counts (hasheq 'nexus 5 'pylon 18 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 5 'pylon 18 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 60 'stalker 22 'immortal 2 'colossus 2 'observer 2)
    #:open-facility-slots (hasheq 'townhall 5 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.55 'enemy-confirmed-bases 7 'rush-prob 0.02))))
(check! (and (>= (cand-u p-6th-depleting 'nexus) 675.0)
             (not (not (memq 'nexus (macro-brain-decision-scheduled-ids p-6th-depleting)))))
        (format "1c. Protoss 5b 6th Nexus should schedule & score >=675; got u=~a sched=~s"
                (cand-u p-6th-depleting 'nexus)
                (macro-brain-decision-scheduled-ids p-6th-depleting)))

;; 1d: Rush-safety guard: high rush-prob (0.65) OR under-attack? MUST block greedy 4th Nexus!
(reset-macro-escrow-tracker!)
(define p-4th-rush-blocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10080
    #:minerals 280 #:gas 180 #:supply-used 98 #:supply-cap 124 #:supply-left 26 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 54 'stalker 8 'immortal 2 'observer 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'rush-prob 0.65))))
(reset-macro-escrow-tracker!)
(define p-4th-under-atk-blocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10080
    #:minerals 280 #:gas 180 #:supply-used 98 #:supply-cap 124 #:supply-left 26 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 24 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 54 'stalker 8 'immortal 2 'observer 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'rush-prob 0.05))))
(check! (and (< (cand-u p-4th-rush-blocked 'nexus) 600.0)
             (not (eq? (macro-brain-decision-saving-for p-4th-rush-blocked) 'nexus))
             (< (cand-u p-4th-under-atk-blocked 'nexus) 100.0)
             (not (eq? (macro-brain-decision-saving-for p-4th-under-atk-blocked) 'nexus)))
        (format "1d. Rush/under-attack MUST block greedy 4th Nexus; rush=(u=~a sav=~a) atk=(u=~a sav=~a)"
                (cand-u p-4th-rush-blocked 'nexus)
                (macro-brain-decision-saving-for p-4th-rush-blocked)
                (cand-u p-4th-under-atk-blocked 'nexus)
                (macro-brain-decision-saving-for p-4th-under-atk-blocked)))

;; =============================================================================
;; Section 2: Terran 4th / 5th / 6th CC & Zerg 5th / 6th Hatchery Cap Lifts
;; =============================================================================

;; 2a: Terran 4th CC (~7:00 under anti-turtle), 5th CC (~10:00), and 6th CC (~12:30)!
(reset-macro-escrow-tracker!)
(define t-4th-cc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 9408
    #:minerals 420 #:gas 150 #:supply-used 98 #:supply-cap 124 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 3 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5 'factory 1 'starport 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5 'factory 1 'starport 1 'refinery 4)
    #:unit-counts (hasheq 'scv 52 'marine 14 'marauder 4 'siege-tank 2 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 5 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.60 'enemy-confirmed-bases 4 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define t-5th-cc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 13440
    #:minerals 420 #:gas 200 #:supply-used 118 #:supply-cap 148 #:supply-left 30 #:pending-supply 0
    #:workers 56 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 4 'supply-depot 16 'barracks 6 'factory 1 'starport 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 4 'supply-depot 16 'barracks 6 'factory 1 'starport 1 'refinery 6)
    #:unit-counts (hasheq 'scv 56 'marine 18 'marauder 4 'siege-tank 3 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 4 'barracks 6 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.55 'enemy-confirmed-bases 6 'rush-prob 0.04))))
(reset-macro-escrow-tracker!)
(define t-6th-cc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 16800
    #:minerals 450 #:gas 220 #:supply-used 128 #:supply-cap 160 #:supply-left 32 #:pending-supply 0
    #:workers 56 #:active-bases 5 #:mineral-harvesters 42 #:gas-harvesters 14
    #:army-supply 38 #:enemy-threat-supply 4 #:under-attack? #f
    #:depleting-bases 2
    #:ready-building-counts (hasheq 'orbital-command 5 'supply-depot 18 'barracks 8 'factory 1 'starport 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 5 'supply-depot 18 'barracks 8 'factory 1 'starport 1 'refinery 6)
    #:unit-counts (hasheq 'scv 56 'marine 20 'marauder 4 'siege-tank 4 'medivac 3)
    #:open-facility-slots (hasheq 'townhall 5 'barracks 8 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.60 'enemy-confirmed-bases 7 'rush-prob 0.03))))
(check! (and (>= (cand-u t-4th-cc 'command-center) 705.0)
             (not (not (memq 'command-center (macro-brain-decision-scheduled-ids t-4th-cc))))
             (>= (cand-u t-5th-cc 'command-center) 705.0)
             (not (not (memq 'command-center (macro-brain-decision-scheduled-ids t-5th-cc))))
             (>= (cand-u t-6th-cc 'command-center) 915.0)
             (not (not (memq 'command-center (macro-brain-decision-scheduled-ids t-6th-cc)))))
        (format "2a. Terran 4th/5th/6th CC pacing failed: 4th=(u=~a s=~s) 5th=(u=~a s=~s) 6th=(u=~a s=~s)"
                (cand-u t-4th-cc 'command-center) (macro-brain-decision-scheduled-ids t-4th-cc)
                (cand-u t-5th-cc 'command-center) (macro-brain-decision-scheduled-ids t-5th-cc)
                (cand-u t-6th-cc 'command-center) (macro-brain-decision-scheduled-ids t-6th-cc)))

;; 2b: Zerg 5th Hatchery (~9:30 with 30 army, previously blocked below 45) & 6th Hatchery (~12:30, previously hard-capped at 5!)
(reset-macro-escrow-tracker!)
(define z-5th-hatch
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 12768
    #:minerals 340 #:gas 180 #:supply-used 108 #:supply-cap 140 #:supply-left 32 #:pending-supply 0
    #:workers 60 #:active-bases 4 #:mineral-harvesters 48 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 4)
    #:total-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 4)
    #:unit-counts (hasheq 'drone 60 'queen 5 'roach 8 'ravager 2 'hydralisk 4 'overseer 2)
    #:open-facility-slots (hasheq 'larva 8)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.60 'enemy-confirmed-bases 5 'rush-prob 0.04))))
(reset-macro-escrow-tracker!)
(define z-6th-hatch
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 16800
    #:minerals 360 #:gas 200 #:supply-used 128 #:supply-cap 160 #:supply-left 32 #:pending-supply 0
    #:workers 62 #:active-bases 5 #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 40 #:enemy-threat-supply 4 #:under-attack? #f
    #:depleting-bases 2
    #:ready-building-counts (hasheq 'hatchery 4 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 4 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 6 'roach 10 'ravager 4 'hydralisk 6 'overseer 2)
    #:open-facility-slots (hasheq 'larva 10)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-confirmed-bases 7 'rush-prob 0.03))))
(check! (and (>= (cand-u z-5th-hatch 'hatchery) 600.0)
             (not (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-5th-hatch))))
             (>= (cand-u z-6th-hatch 'hatchery) 650.0)
             (not (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-6th-hatch)))))
        (format "2b. Zerg 5th/6th Hatchery cap lift failed: 5th=(u=~a s=~s) 6th=(u=~a s=~s)"
                (cand-u z-5th-hatch 'hatchery) (macro-brain-decision-scheduled-ids z-5th-hatch)
                (cand-u z-6th-hatch 'hatchery) (macro-brain-decision-scheduled-ids z-6th-hatch)))

;; =============================================================================
;; Section 3: gas_rich_min_starved Fix Across Brain, Saturation Policy & Watchdog
;; =============================================================================

;; 3a: Brain demotes extra Assimilator (<= 60, blk=#f) & boosts 4th Nexus (>= 660) at 550G / 230M
(reset-macro-escrow-tracker!)
(define p-gas-rich-starved
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10500
    #:minerals 230 #:gas 550 #:supply-used 104 #:supply-cap 130 #:supply-left 26 #:pending-supply 0
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 56 'stalker 12 'immortal 2 'observer 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.04))))
(check! (and (<= (cand-u p-gas-rich-starved 'assimilator) 60.0)
             (not (cand-blk? p-gas-rich-starved 'assimilator))
             (>= (cand-u p-gas-rich-starved 'nexus) 660.0))
        (format "3a. Gas-rich min-starved should demote extra Assimilator (<=60, blk=#f) & boost 4th Nexus (>=660); assim=(u=~a blk=~a) nex=~a"
                (cand-u p-gas-rich-starved 'assimilator)
                (cand-blk? p-gas-rich-starved 'assimilator)
                (cand-u p-gas-rich-starved 'nexus)))

;; 3b: stall-watchdog `wd-gas-valve-mode` handles midgame >=380G/<200M & late-game >=600G/<150M at >=175 supply,
;;     while strictly preserving legacy `(150 480 ... food=175) == 'normal`!
(check! (and (eq? (wd-gas-valve-mode 150 400 120 45 4 120 500) 'pull-to-minerals)
             (eq? (wd-gas-valve-mode 120 650 140 60 6 185 750) 'pull-to-minerals)
             (eq? (wd-gas-valve-mode 150 480 120 40 2 175 400) 'normal))
        "3b. wd-gas-valve-mode late-game & legacy food=175 checks failed")

;; 3c: worker-saturation-policy pulls gas workers at 450G/100M EVEN IF `#:gas-starvation-boost? #t`,
;;     and pulls up to 4 workers/step at extreme 620G/120M!
(let ()
  (define b1 (mk-b 1 30.0 30.0 #:asgn 10 #:ideal 16 #:patches '(501 502)))
  (define b2 (mk-b 2 52.0 34.0 #:asgn 10 #:ideal 16 #:patches '(503 504)))
  (define m1 (mk-m 501 25.0 30.0 #:owner 1))
  (define m2 (mk-m 502 25.0 32.0 #:owner 1))
  (define m3 (mk-m 503 57.0 34.0 #:owner 2))
  (define m4 (mk-m 504 57.0 36.0 #:owner 2))
  (define g1 (mk-g 10 30.0 24.0 #:asgn 3 #:ideal 3 #:base 1))
  (define g2 (mk-g 11 52.0 28.0 #:asgn 3 #:ideal 3 #:base 2))
  (define ws
    (append
     (for/list ([i (in-range 20)])
       (mk-w (+ 1000 i) (if (< i 10) 26.0 56.0) (if (< i 10) 30.0 34.0) #:tgt (if (< i 10) 501 503)))
     (for/list ([i (in-range 3)]) (mk-w (+ 2000 i) 30.0 25.0 #:tgt 10))
     (for/list ([i (in-range 3)]) (mk-w (+ 2100 i) 52.0 29.0 #:tgt 11))))
  (define st-sev (make-worker-sat-state))
  (define d-sev (evaluate-worker-saturation-policy!
                 st-sev #:loop 9000 #:race 'Protoss #:minerals 100 #:gas 450
                 #:workers ws #:bases (list b1 b2) #:gas-buildings (list g1 g2)
                 #:minerals-fields (list m1 m2 m3 m4)
                 #:gas-starvation-boost? #t))
  (define st-ext (make-worker-sat-state))
  (define d-ext (evaluate-worker-saturation-policy!
                 st-ext #:loop 9200 #:race 'Protoss #:minerals 120 #:gas 620
                 #:workers ws #:bases (list b1 b2) #:gas-buildings (list g1 g2)
                 #:minerals-fields (list m1 m2 m3 m4)
                 #:gas-starvation-boost? #t))
  (check! (and (>= (gas-pull-worker-count d-sev) 2)
               (>= (gas-pull-worker-count d-ext) 4))
          (format "3c. Severe/extreme gas-rich pullback under gas-boost failed: sev=~a ext=~a"
                  (gas-pull-worker-count d-sev)
                  (gas-pull-worker-count d-ext))))

;; =============================================================================
;; Section 4: Early Static-Defense / Burrowed-Mine Siege-Breaker & Detector Macro
;; =============================================================================

;; 4a: Protoss vs early Bunkers + Widow Mines (~6:30) -> Observer #1 (>=640), RoboBay (>=615), Colossus (>=620), Disruptor (>=605)
(reset-macro-escrow-tracker!)
(define p-turtle-obs
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8736
    #:minerals 200 #:gas 125 #:supply-used 72 #:supply-cap 96 #:supply-left 24 #:pending-supply 0
    #:workers 44 #:active-bases 2 #:mineral-harvesters 34 #:gas-harvesters 10
    #:army-supply 24 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 44 'stalker 8 'immortal 2)
    #:enemy-building-counts (hasheq 'bunker 2)
    #:enemy-unit-counts (hasheq 'widow-mine-burrowed 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-burrow-mine-count 4 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-turtle-col-disr
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9408
    #:minerals 350 #:gas 250 #:supply-used 86 #:supply-cap 112 #:supply-left 26 #:pending-supply 0
    #:workers 48 #:active-bases 2 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 8 'immortal 2 'colossus 2 'observer 2)
    #:enemy-building-counts (hasheq 'bunker 3)
    #:enemy-unit-counts (hasheq 'widow-mine-burrowed 4 'siege-tank-sieged 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.72 'enemy-burrow-mine-count 4 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-turtle-obs2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8900
    #:minerals 220 #:gas 150 #:supply-used 76 #:supply-cap 102 #:supply-left 26 #:pending-supply 0
    #:workers 44 #:active-bases 2 #:mineral-harvesters 34 #:gas-harvesters 10
    #:army-supply 26 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 44 'stalker 8 'immortal 2 'observer 1)
    #:enemy-building-counts (hasheq 'bunker 2)
    #:enemy-unit-counts (hasheq 'widow-mine-burrowed 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-burrow-mine-count 2 'rush-prob 0.05))))
(check! (and (>= (cand-u p-turtle-obs 'observer) 640.0)
             (>= (cand-u p-turtle-obs2 'observer) 585.0)
             (>= (cand-u p-turtle-obs 'robotics-bay) 615.0)
             (>= (cand-u p-turtle-col-disr 'colossus) 620.0)
             (>= (cand-u p-turtle-col-disr 'disruptor) 605.0))
        (format "4a. Protoss early turtle siege/detector macro failed: obs1=~a obs2=~a bay=~a col=~a disr=~a"
                (cand-u p-turtle-obs 'observer)
                (cand-u p-turtle-obs2 'observer)
                (cand-u p-turtle-obs 'robotics-bay)
                (cand-u p-turtle-col-disr 'colossus)
                (cand-u p-turtle-col-disr 'disruptor)))

;; 4b: Terran vs early static-D + Mines (~6:30-7:30) -> Raven (>=625), SiegeTank (>=615), Liberator (>=605)
(reset-macro-escrow-tracker!)
(define t-turtle-siege
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 9408
    #:minerals 350 #:gas 250 #:supply-used 90 #:supply-cap 116 #:supply-left 26 #:pending-supply 0
    #:workers 46 #:active-bases 2 #:mineral-harvesters 34 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 12 'barracks 4
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 12 'barracks 4
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:unit-counts (hasheq 'scv 46 'marine 14 'marauder 4 'siege-tank 2 'medivac 2)
    #:enemy-building-counts (hasheq 'bunker 2 'missile-turret 4)
    #:enemy-unit-counts (hasheq 'widow-mine-burrowed 4 'siege-tank-sieged 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 4 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.72 'enemy-burrow-mine-count 4 'rush-prob 0.04))))
(check! (and (>= (cand-u t-turtle-siege 'raven) 625.0)
             (>= (cand-u t-turtle-siege 'siege-tank) 615.0)
             (>= (cand-u t-turtle-siege 'liberator) 605.0))
        (format "4b. Terran early turtle siege/detector macro failed: raven=~a tank=~a lib=~a"
                (cand-u t-turtle-siege 'raven)
                (cand-u t-turtle-siege 'siege-tank)
                (cand-u t-turtle-siege 'liberator)))

;; 4c: Zerg vs Shield Batteries + Cannons (~7:00) -> Overseer (>=635), Ravager (>=605), LurkerDen (>=595)
;;     AND Hive without Greater Spire MUST NOT curb Ravager/Lurker!
(reset-macro-escrow-tracker!)
(define z-turtle-siege
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 9408
    #:minerals 350 #:gas 250 #:supply-used 98 #:supply-cap 124 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 3 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 4)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'hive 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 4)
    #:unit-counts (hasheq 'drone 52 'queen 4 'roach 8 'hydralisk 6)
    #:enemy-building-counts (hasheq 'shield-battery 3 'photon-cannon 3)
    #:enemy-unit-counts (hasheq 'siege-tank 4 'liberator 2)
    #:open-facility-slots (hasheq 'larva 6)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.70 'enemy-static-def-count 6 'rush-prob 0.04))))
(check! (and (>= (cand-u z-turtle-siege 'overseer) 635.0)
             (>= (cand-u z-turtle-siege 'ravager) 605.0)
             (>= (cand-u z-turtle-siege 'lurker-den) 595.0))
        (format "4c. Zerg early turtle siege/detector macro failed: ov=~a rav=~a lden=~a"
                (cand-u z-turtle-siege 'overseer)
                (cand-u z-turtle-siege 'ravager)
                (cand-u z-turtle-siege 'lurker-den)))

;; 4d: Zero Rush False Positive: high rush-prob (0.70) at 6:30 suppresses early turtle siege-breaker macro
(reset-macro-escrow-tracker!)
(define t-rush-no-turtle
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 8736
    #:minerals 300 #:gas 200 #:supply-used 78 #:supply-cap 104 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 32 #:gas-harvesters 10
    #:army-supply 26 #:enemy-threat-supply 20 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 10 'barracks 4
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 10 'barracks 4
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 14 'siege-tank 2 'medivac 2)
    #:enemy-building-counts (hasheq 'bunker 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 4 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'rush-prob 0.70))))
(check! (< (cand-u t-rush-no-turtle 'raven) 625.0)
        (format "4d. High rush-prob MUST suppress turtle Raven macro; got raven=~a"
                (cand-u t-rush-no-turtle 'raven)))

;; =============================================================================
;; Section 5: Loop 86B Surgical Polish (Peaceful 3rd Nexus, Tight Gas-Rich Guard,
;;            and Zero Pylon Suppression at supply-left <= 6)
;; =============================================================================

;; 5a: Peaceful 2b Protoss (44w, 310M/180G, 1 Immortal, 1 Observer) under enemy turtle signal
;;     MUST yield turtle RoboBay & 2nd Observer to 3rd Nexus (`u >= 630.0, saving-for = nexus`)!
(reset-macro-escrow-tracker!)
(define p-86b-peaceful-3rd-vs-turtle
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 310 #:gas 180 #:supply-used 76 #:supply-cap 102 #:supply-left 26 #:pending-supply 0
    #:workers 44 #:active-bases 2 #:mineral-harvesters 32 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 44 'stalker 8 'immortal 1 'observer 1 'warp-prism 1)
    #:enemy-building-counts (hasheq 'bunker 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'rush-prob 0.04))))
(check! (and (eq? (macro-brain-decision-saving-for p-86b-peaceful-3rd-vs-turtle) 'nexus)
             (>= (cand-u p-86b-peaceful-3rd-vs-turtle 'nexus) 630.0)
             (not (memq 'robotics-bay (macro-brain-decision-scheduled-ids p-86b-peaceful-3rd-vs-turtle)))
             (not (memq 'observer (macro-brain-decision-scheduled-ids p-86b-peaceful-3rd-vs-turtle)))
             (not (memq 'immortal (macro-brain-decision-scheduled-ids p-86b-peaceful-3rd-vs-turtle))))
        (format "5a. Peaceful 2b 3rd Nexus@630 must beat turtle RoboBay/Obs2/Immortal; sav=~a nex=~a bay=~a sched=~s"
                (macro-brain-decision-saving-for p-86b-peaceful-3rd-vs-turtle)
                (cand-u p-86b-peaceful-3rd-vs-turtle 'nexus)
                (cand-u p-86b-peaceful-3rd-vs-turtle 'robotics-bay)
                (macro-brain-decision-scheduled-ids p-86b-peaceful-3rd-vs-turtle)))

;; 5b: Tightened gas-rich extra-gas deferral:
;;     (i) 280G / 260M w/ 2 Assimilators demotes 3rd Assimilator <= 60 (blk=#f)
;;     (ii) 210G / 220M w/ 3 Assimilators on 2b (>= 2*2 - 1) demotes 4th Assimilator <= 60 (blk=#f)
(reset-macro-escrow-tracker!)
(define p-86b-gas-defer-280
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7200
    #:minerals 260 #:gas 280 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 36 #:gas-harvesters 6
    #:army-supply 20 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'immortal 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-86b-gas-defer-210
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7400
    #:minerals 220 #:gas 210 #:supply-used 70 #:supply-cap 94 #:supply-left 24 #:pending-supply 0
    #:workers 44 #:active-bases 2 #:mineral-harvesters 35 #:gas-harvesters 9
    #:army-supply 22 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 44 'stalker 8 'immortal 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (<= (cand-u p-86b-gas-defer-280 'assimilator) 60.0)
             (not (cand-blk? p-86b-gas-defer-280 'assimilator))
             (<= (cand-u p-86b-gas-defer-210 'assimilator) 60.0)
             (not (cand-blk? p-86b-gas-defer-210 'assimilator)))
        (format "5b. Tightened gas-rich defer failed: 280G=(u=~a blk=~a) 210G=(u=~a blk=~a)"
                (cand-u p-86b-gas-defer-280 'assimilator) (cand-blk? p-86b-gas-defer-280 'assimilator)
                (cand-u p-86b-gas-defer-210 'assimilator) (cand-blk? p-86b-gas-defer-210 'assimilator)))

;; 5c: Pylon at supply-left <= 6 (e.g. 2b 106/110 or 3b 104/110 with 1 pending Pylon)
;;     MUST NOT be overbuilt-suppressed; must fire supply-crisis immediately (`u >= 1350.0, blk=#t`)!
(reset-macro-escrow-tracker!)
(define p-86b-pylon-low-left-2b
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 11200
    #:minerals 275 #:gas 150 #:supply-used 106 #:supply-cap 110 #:supply-left 4 #:pending-supply 1
    #:workers 48 #:active-bases 2 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 58 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 18 'immortal 4 'observer 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 6 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-86b-pylon-low-left-3b
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 11400
    #:minerals 275 #:gas 150 #:supply-used 104 #:supply-cap 110 #:supply-left 6 #:pending-supply 1
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 48 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 11 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 56 'stalker 16 'immortal 3 'observer 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1))))
(check! (and (>= (cand-u p-86b-pylon-low-left-2b 'pylon) 1350.0)
             (cand-blk? p-86b-pylon-low-left-2b 'pylon)
             (memq 'pylon (macro-brain-decision-scheduled-ids p-86b-pylon-low-left-2b))
             (>= (cand-u p-86b-pylon-low-left-3b 'pylon) 1350.0)
             (cand-blk? p-86b-pylon-low-left-3b 'pylon)
             (memq 'pylon (macro-brain-decision-scheduled-ids p-86b-pylon-low-left-3b)))
        (format "5c. Pylon at supply-left<=6 MUST NOT be overbuilt-suppressed; 2b=(u=~a blk=~a) 3b=(u=~a blk=~a)"
                (cand-u p-86b-pylon-low-left-2b 'pylon) (cand-blk? p-86b-pylon-low-left-2b 'pylon)
                (cand-u p-86b-pylon-low-left-3b 'pylon) (cand-blk? p-86b-pylon-low-left-3b 'pylon)))

;; =============================================================================
;; Section 6: Loop 86C Surgical Fixes (Turtle Observer Cap = 1 w/o Cloak/Mines,
;;            PvZ Roach Immortal Gate, and Terran Midgame Gas-Pull Tier)
;; =============================================================================

;; 6a: Pure turtle (no cloak threat, < 2 burrowed mines) with 1 Observer alive MUST NOT
;;     rebuild Observer #2 via l86-protoss-turtle-obs-due? (`obs u < 585.0`, not scheduled)!
(reset-macro-escrow-tracker!)
(define p-86c-turtle-no-obs2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 9800
    #:minerals 280 #:gas 190 #:supply-used 92 #:supply-cap 118 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 3 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 36 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'stalker 10 'immortal 2 'observer 1)
    #:enemy-building-counts (hasheq 'spine-crawler 4)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.68 'enemy-static-def-count 4 'rush-prob 0.04))))
(check! (and (< (cand-u p-86c-turtle-no-obs2 'observer) 585.0)
             (not (memq 'observer (macro-brain-decision-scheduled-ids p-86c-turtle-no-obs2))))
        (format "6a. Turtle without cloak/mines>=2 MUST cap l86-protoss-turtle-obs-due? at 1; obs-u=~a sched=~s"
                (cand-u p-86c-turtle-no-obs2 'observer)
                (macro-brain-decision-scheduled-ids p-86c-turtle-no-obs2)))

;; 6b: PvZ vs >= 4 Roaches/Ravagers (e.g. 4 Roaches + 1 Ravager = 5) under turtle signal:
;;     (i) < 2 Immortals MUST gate turtle RoboBay & turtle Colossus (#3) so Robo never starves Immortals!
;;     (ii) >= 2 Immortals cleanly unlocks turtle RoboBay (>= 615) & turtle Colossus (>= 620)!
(reset-macro-escrow-tracker!)
(define p-86c-pvz-roach-low-imm-bay
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 8900
    #:minerals 280 #:gas 180 #:supply-used 78 #:supply-cap 104 #:supply-left 26 #:pending-supply 0
    #:workers 44 #:active-bases 2 #:mineral-harvesters 34 #:gas-harvesters 10
    #:army-supply 26 #:enemy-threat-supply 10 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 44 'stalker 8 'immortal 1 'observer 1)
    #:enemy-building-counts (hasheq 'spine-crawler 4)
    #:enemy-unit-counts (hasheq 'roach 4 'ravager 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-static-def-count 4 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-86c-pvz-roach-low-imm-col
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 9400
    #:minerals 350 #:gas 250 #:supply-used 96 #:supply-cap 122 #:supply-left 26 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 42 #:enemy-threat-supply 10 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 8 'immortal 1 'colossus 2 'observer 1)
    #:enemy-building-counts (hasheq 'spine-crawler 4)
    #:enemy-unit-counts (hasheq 'roach 4 'ravager 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-static-def-count 4 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-86c-pvz-roach-2imm-bay
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 9400
    #:minerals 280 #:gas 180 #:supply-used 86 #:supply-cap 112 #:supply-left 26 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 32 #:enemy-threat-supply 10 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 8 'immortal 2 'observer 1)
    #:enemy-building-counts (hasheq 'spine-crawler 4)
    #:enemy-unit-counts (hasheq 'roach 4 'ravager 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-static-def-count 4 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-86c-pvz-roach-2imm-col
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 9400
    #:minerals 350 #:gas 250 #:supply-used 100 #:supply-cap 126 #:supply-left 26 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 46 #:enemy-threat-supply 10 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 8 'immortal 2 'colossus 2 'observer 1)
    #:enemy-building-counts (hasheq 'spine-crawler 4)
    #:enemy-unit-counts (hasheq 'roach 4 'ravager 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-static-def-count 4 'rush-prob 0.05))))
(check! (and (< (cand-u p-86c-pvz-roach-low-imm-bay 'robotics-bay) 615.0)
             (< (cand-u p-86c-pvz-roach-low-imm-col 'colossus) 620.0)
             (>= (cand-u p-86c-pvz-roach-2imm-bay 'robotics-bay) 615.0)
             (>= (cand-u p-86c-pvz-roach-2imm-col 'colossus) 620.0))
        (format "6b. PvZ Roach/Ravager>=4 must gate turtle RoboBay/Colossus until >=2 Immortals; lowBay=~a lowCol=~a okBay=~a okCol=~a"
                (cand-u p-86c-pvz-roach-low-imm-bay 'robotics-bay)
                (cand-u p-86c-pvz-roach-low-imm-col 'colossus)
                (cand-u p-86c-pvz-roach-2imm-bay 'robotics-bay)
                (cand-u p-86c-pvz-roach-2imm-col 'colossus)))

;; 6c: Terran midgame mineral-starvation gas-pull tier (`>= 180G & < 120M & >= 4 gas workers`):
;;     (i) Pulls excess Refineries on 2b/3b down toward safe 2-3 gas worker floor (even under gas-boost!)
;;     (ii) Holds gas resaturation while cur-min < 180 after recent pull
;;     (iii) Releases cleanly once cur-min >= 180
;;     (iv) Never pulls when active gas workers < 4 (preserves Tank/Medivac gas on 1 Refinery)
(let ()
  (define b1 (mk-b 1 30.0 30.0 #:type 'orbital-command #:asgn 12 #:ideal 16 #:patches '(501 502)))
  (define b2 (mk-b 2 62.0 30.0 #:type 'orbital-command #:asgn 10 #:ideal 16 #:patches '(503 504)))
  (define m1 (mk-m 501 25.0 30.0 #:owner 1))
  (define m2 (mk-m 502 25.0 32.0 #:owner 1))
  (define m3 (mk-m 503 67.0 30.0 #:owner 2))
  (define m4 (mk-m 504 67.0 32.0 #:owner 2))
  (define g1 (mk-g 10 30.0 24.0 #:type 'refinery #:asgn 3 #:ideal 3 #:base 1))
  (define g2 (mk-g 11 36.0 24.0 #:type 'refinery #:asgn 3 #:ideal 3 #:base 1))
  (define g3 (mk-g 12 62.0 24.0 #:type 'refinery #:asgn 3 #:ideal 3 #:base 2))
  (define min-ws
    (append (for/list ([i (in-range 12)]) (mk-w (+ 100 i) 26.0 (+ 28.0 (* 0.2 i)) #:type 'scv #:tgt 501))
            (for/list ([i (in-range 10)]) (mk-w (+ 120 i) 66.0 (+ 28.0 (* 0.2 i)) #:type 'scv #:tgt 503))))
  (define gas-ws-9
    (append (for/list ([i (in-range 3)]) (mk-w (+ 200 i) 30.0 25.0 #:type 'scv #:tgt 10))
            (for/list ([i (in-range 3)]) (mk-w (+ 210 i) 36.0 25.0 #:type 'scv #:tgt 11))
            (for/list ([i (in-range 3)]) (mk-w (+ 220 i) 62.0 25.0 #:type 'scv #:tgt 12))))
  (define st (make-worker-sat-state))
  ;; (i) 190G / 95M with 9 gas workers across 3 Refineries under mineral-heavy Bio demand -> pulls >= 3 SCVs!
  (define ds-pull
    (evaluate-worker-saturation-policy!
     st #:loop 8200 #:race 'Terran #:minerals 95 #:gas 190
     #:workers (append min-ws gas-ws-9)
     #:bases (list b1 b2) #:gas-buildings (list g1 g2 g3)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 240.0))
  ;; (ii) Recovery at loop 8320 with 160G / 145M (< 112f opp-cd & low gas need) -> holds resat!
  (define g2-empty (mk-g 11 36.0 24.0 #:type 'refinery #:asgn 0 #:ideal 3 #:base 1))
  (define g3-empty (mk-g 12 62.0 24.0 #:type 'refinery #:asgn 0 #:ideal 3 #:base 2))
  (define gas-ws-3
    (for/list ([i (in-range 3)]) (mk-w (+ 200 i) 30.0 25.0 #:type 'scv #:tgt 10)))
  (define ds-hold
    (evaluate-worker-saturation-policy!
     st #:loop 8300 #:race 'Terran #:minerals 145 #:gas 160
     #:workers (append min-ws gas-ws-3)
     #:bases (list b1 b2) #:gas-buildings (list g1 g2-empty g3-empty)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 900.0 #:gas-demand-rate 450.0))
  (define hold-refill-cnt
    (for/sum ([d (in-list ds-hold)]
              #:when (and (eq? (sat-directive-kind d) 'harvest-gather)
                          (memv (sat-directive-target-tag d) '(10 11 12))))
      (length (sat-directive-unit-tags d))))
  ;; (iii) Once cur-min = 210 past 112f opp-cd with balanced Tank/Medivac demand -> resaturation resumes!
  (define ds-release
    (evaluate-worker-saturation-policy!
     st #:loop 8360 #:race 'Terran #:minerals 210 #:gas 160
     #:workers (append min-ws gas-ws-3)
     #:bases (list b1 b2) #:gas-buildings (list g1 g2-empty g3-empty)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 900.0 #:gas-demand-rate 450.0))
  (define rel-refill-cnt
    (for/sum ([d (in-list ds-release)]
              #:when (and (eq? (sat-directive-kind d) 'harvest-gather)
                          (memv (sat-directive-target-tag d) '(10 11 12))))
      (length (sat-directive-unit-tags d))))
  ;; (iv) 1 Refinery (3 gas workers) under Tank/Medivac demand at 190G / 95M -> 0 pulled (preserves tech gas)!
  (define st-1ref (make-worker-sat-state))
  (define ds-1ref
    (evaluate-worker-saturation-policy!
     st-1ref #:loop 8200 #:race 'Terran #:minerals 95 #:gas 190
     #:workers (append min-ws gas-ws-3)
     #:bases (list b1 b2) #:gas-buildings (list g1)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 800.0 #:gas-demand-rate 480.0))
  (check! (and (>= (gas-pull-worker-count ds-pull) 3)
               (= hold-refill-cnt 0)
               (>= rel-refill-cnt 1)
               (= (gas-pull-worker-count ds-1ref) 0))
          (format "6c. Terran midgame gas-pull tier failed: pull=~a holdRefill=~a relRefill=~a 1refPull=~a"
                  (gas-pull-worker-count ds-pull) hold-refill-cnt rel-refill-cnt
                  (gas-pull-worker-count ds-1ref))))

;; =============================================================================
;; Section 7: Loop 86C Track C2 (OWM enemy-estimated-bases & enemy-estimated-gases
;;            plumbing + post-8:30 deep-fog expansion matching)
;; =============================================================================

;; 7a: obs-hash->macro-world-state plumbs 'enemy-estimated-bases (defaulting to
;;     'enemy-confirmed-bases) and 'enemy-estimated-gases cleanly into mirror-signals.
(let ()
  (define ws-explicit
    (obs-hash->macro-world-state
     (hasheq 'race 'Protoss 'enemy-race 'Terran 'frame 12000
             'minerals 300 'gas 150 'supply-used 90 'supply-cap 120
             'enemy-confirmed-bases 2 'enemy-estimated-bases 5 'enemy-estimated-gases 6)))
  (define ms-explicit (macro-world-state-mirror-signals ws-explicit))
  (define ws-fallback
    (obs-hash->macro-world-state
     (hasheq 'race 'Protoss 'enemy-race 'Terran 'frame 12000
             'minerals 300 'gas 150 'supply-used 90 'supply-cap 120
             'enemy-confirmed-bases 3)))
  (define ms-fallback (macro-world-state-mirror-signals ws-fallback))
  (check! (and (= (hash-ref ms-explicit 'enemy-confirmed-bases 0) 2)
               (= (hash-ref ms-explicit 'enemy-estimated-bases 0) 5)
               (= (hash-ref ms-explicit 'enemy-estimated-gases 0) 6)
               (= (hash-ref ms-fallback 'enemy-estimated-bases 0) 3)
               (= (hash-ref ms-fallback 'enemy-estimated-gases 0) 0))
          (format "7a. obs-hash->macro-world-state eB/eG plumbing failed: exp=(~a,~a,~a) fb=(~a,~a)"
                  (hash-ref ms-explicit 'enemy-confirmed-bases 0)
                  (hash-ref ms-explicit 'enemy-estimated-bases 0)
                  (hash-ref ms-explicit 'enemy-estimated-gases 0)
                  (hash-ref ms-fallback 'enemy-estimated-bases 0)
                  (hash-ref ms-fallback 'enemy-estimated-gases 0))))

;; 7b: Post-8:30 (frame >= 11424) deep-fog enemy-estimated-bases >= max(4, active-bases+1)
;;     unlocks anti-turtle expansion matching (e.g. 5th Nexus at 9:05 w/ confirmed=2, est=5, rush<0.35),
;;     while < 8:30 (frame=9600 on 3b w/ est=4), low est (est=3), OR rush-prob >= 0.35 stay quiet!
(reset-macro-escrow-tracker!)
(define p-86c-est-pre830
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9600
    #:minerals 280 #:gas 180 #:supply-used 98 #:supply-cap 124 #:supply-left 26 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 54 'stalker 12 'immortal 2 'observer 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.05 'hidden-expand-posterior 0.14
                             'enemy-confirmed-bases 2 'enemy-estimated-bases 4
                             'win-prob 0.50 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-86c-est-post830-match
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 12200
    #:minerals 320 #:gas 220 #:supply-used 110 #:supply-cap 140 #:supply-left 30 #:pending-supply 0
    #:workers 60 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 16
    #:army-supply 50 #:enemy-threat-supply 6 #:under-attack? #f
    #:depleting-bases 0
    #:ready-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 60 'stalker 18 'immortal 2 'colossus 1 'observer 1)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.05 'hidden-expand-posterior 0.14
                             'enemy-confirmed-bases 2 'enemy-estimated-bases 5
                             'win-prob 0.50 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-86c-est-post830-no-lead
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 12200
    #:minerals 320 #:gas 220 #:supply-used 110 #:supply-cap 140 #:supply-left 30 #:pending-supply 0
    #:workers 60 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 16
    #:army-supply 50 #:enemy-threat-supply 6 #:under-attack? #f
    #:depleting-bases 0
    #:ready-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 60 'stalker 18 'immortal 2 'colossus 1 'observer 1)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.05 'hidden-expand-posterior 0.14
                             'enemy-confirmed-bases 2 'enemy-estimated-bases 4
                             'win-prob 0.50 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-86c-est-rush-blocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 12200
    #:minerals 320 #:gas 220 #:supply-used 110 #:supply-cap 140 #:supply-left 30 #:pending-supply 0
    #:workers 60 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 16
    #:army-supply 50 #:enemy-threat-supply 6 #:under-attack? #f
    #:depleting-bases 0
    #:ready-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 60 'stalker 18 'immortal 2 'colossus 1 'observer 1)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.05 'hidden-expand-posterior 0.14
                             'enemy-confirmed-bases 2 'enemy-estimated-bases 5
                             'win-prob 0.50 'rush-prob 0.40))))
(check! (and (< (cand-u p-86c-est-pre830 'nexus) 605.0)
             (>= (cand-u p-86c-est-post830-match 'nexus) 610.0)
             (cand-blk? p-86c-est-post830-match 'nexus)
             (< (cand-u p-86c-est-post830-no-lead 'nexus) 610.0)
             (< (cand-u p-86c-est-rush-blocked 'nexus) 610.0))
        (format "7b. Deep-fog estimated-bases matching failed: pre830=~a match=(u=~a blk=~a) noLead=~a rush=~a"
                (cand-u p-86c-est-pre830 'nexus)
                (cand-u p-86c-est-post830-match 'nexus)
                (cand-blk? p-86c-est-post830-match 'nexus)
                (cand-u p-86c-est-post830-no-lead 'nexus)
                (cand-u p-86c-est-rush-blocked 'nexus)))

;; =============================================================================
;; Section 8: Loop 86D (Pending TownHall Guard, Healthy 4th/5th/6th Army Floors,
;;            Terran Anti-Medivac Viking Cap <= 4, and PvZ 2-Immortal Core)
;; =============================================================================

;; 8a: Pending TownHall Guard & Healthy Army Floors:
;;     (i) Protoss w/ 3 ready + 1 building Nexus (pending=1) MUST NOT start 5th Nexus!
;;     (ii) Protoss w/ 4 ready Nexuses & 34 army (<48 floor) MUST NOT start 5th Nexus
;;          even under hidden-expand=0.90 & gas=500/min=240!
;;     (iii) Zerg w/ 4 ready + 1 building Hatchery (pending=1) MUST NOT start 6th Hatchery!
;;     (iv) Terran w/ 3 ready OCs + 1 building CC (pending=1) MUST NOT start 5th CC!
(reset-macro-escrow-tracker!)
(define p-86d-pending-th-blocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 13440
    #:minerals 450 #:gas 220 #:supply-used 110 #:supply-cap 140 #:supply-left 30 #:pending-supply 0
    #:workers 60 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 16
    #:army-supply 52 #:enemy-threat-supply 6 #:under-attack? #f
    #:depleting-bases 1
    #:ready-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 60 'stalker 18 'immortal 2 'colossus 1 'observer 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-confirmed-bases 6 'rush-prob 0.04))))
(reset-macro-escrow-tracker!)
(define p-86d-low-army-5th-blocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 13440
    #:minerals 240 #:gas 500 #:supply-used 94 #:supply-cap 140 #:supply-left 46 #:pending-supply 0
    #:workers 60 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 16
    #:army-supply 34 #:enemy-threat-supply 6 #:under-attack? #f
    #:depleting-bases 0
    #:ready-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 4 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 60 'stalker 10 'immortal 2 'colossus 1 'observer 1)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'hidden-expand-posterior 0.90 'enemy-confirmed-bases 6 'rush-prob 0.04))))
(reset-macro-escrow-tracker!)
(define z-86d-pending-hatch-blocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 16800
    #:minerals 450 #:gas 200 #:supply-used 120 #:supply-cap 150 #:supply-left 30 #:pending-supply 0
    #:workers 62 #:active-bases 5 #:mineral-harvesters 48 #:gas-harvesters 14
    #:army-supply 44 #:enemy-threat-supply 6 #:under-attack? #f
    #:depleting-bases 2
    #:ready-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 4 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'roach 10 'hydralisk 10)
    #:open-facility-slots (hasheq 'larva 6)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-confirmed-bases 6 'rush-prob 0.04))))
(reset-macro-escrow-tracker!)
(define t-86d-pending-cc-blocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 13440
    #:minerals 450 #:gas 200 #:supply-used 118 #:supply-cap 148 #:supply-left 30 #:pending-supply 0
    #:workers 56 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 40 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 16 'barracks 6 'factory 1 'starport 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 3 'command-center 1 'supply-depot 16 'barracks 6 'factory 1 'starport 1 'refinery 6)
    #:unit-counts (hasheq 'scv 56 'marine 20 'marauder 4 'siege-tank 4 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 6 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.60 'enemy-confirmed-bases 6 'rush-prob 0.04))))
(check! (and (< (cand-u p-86d-pending-th-blocked 'nexus) 610.0)
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-86d-pending-th-blocked)))
             (< (cand-u p-86d-low-army-5th-blocked 'nexus) 610.0)
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-86d-low-army-5th-blocked)))
             (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-86d-pending-hatch-blocked)))
             (not (memq 'command-center (macro-brain-decision-scheduled-ids t-86d-pending-cc-blocked))))
        (format "8a. Pending TownHall guard / army floor failed: pPend=(u=~a sched=~s) pLowArmy=~a zSched=~s tSched=~s"
                (cand-u p-86d-pending-th-blocked 'nexus)
                (macro-brain-decision-scheduled-ids p-86d-pending-th-blocked)
                (cand-u p-86d-low-army-5th-blocked 'nexus)
                (macro-brain-decision-scheduled-ids z-86d-pending-hatch-blocked)
                (macro-brain-decision-scheduled-ids t-86d-pending-cc-blocked)))

;; 8b: Terran Anti-Medivac Viking Cap <= 4 when enemy has 0 air-combat / air-siege / Colossus threats
;;     (pure Bio + Medivacs), while still training Vikings past 4 against real enemy combat air!
(reset-macro-escrow-tracker!)
(define t-86d-viking-cap-medivac-only
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 12000
    #:minerals 600 #:gas 260 #:supply-used 112 #:supply-cap 140 #:supply-left 28 #:pending-supply 0
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 56 #:enemy-threat-supply 24 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 4)
    #:unit-counts (hasheq 'scv 56 'marine 24 'marauder 4 'siege-tank 4 'medivac 4 'viking-fighter 4)
    #:enemy-building-counts (hasheq 'barracks 6 'starport 2)
    #:enemy-unit-counts (hasheq 'marine 30 'medivac 6)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 5 'factory 1 'starport 2))))
(reset-macro-escrow-tracker!)
(define t-86d-viking-scales-vs-air
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 12000
    #:minerals 600 #:gas 260 #:supply-used 112 #:supply-cap 140 #:supply-left 28 #:pending-supply 0
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 56 #:enemy-threat-supply 24 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 4)
    #:unit-counts (hasheq 'scv 56 'marine 24 'marauder 4 'siege-tank 5 'medivac 4 'viking-fighter 4)
    #:enemy-unit-counts (hasheq 'marine 18 'siege-tank 4 'viking-fighter 8)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 5 'factory 1 'starport 2))))
(check! (and (<= (cand-u t-86d-viking-cap-medivac-only 'viking-fighter) 30.0)
             (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-86d-viking-cap-medivac-only)))
             (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-86d-viking-scales-vs-air)))))
        (format "8b. Terran anti-Medivac Viking cap failed: medivac=(u=~a sched=~s) airSched=~s"
                (cand-u t-86d-viking-cap-medivac-only 'viking-fighter)
                (macro-brain-decision-scheduled-ids t-86d-viking-cap-medivac-only)
                (macro-brain-decision-scheduled-ids t-86d-viking-scales-vs-air)))

;; 8c: PvZ Unconditional 2-Immortal Core (absent enemy Spire / air dominance):
;;     Even with 0 live Roaches visible on frame, turtle RoboBay is gated until >= 2 Immortals!
(reset-macro-escrow-tracker!)
(define p-86d-pvz-0roach-1imm
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 9400
    #:minerals 280 #:gas 180 #:supply-used 86 #:supply-cap 112 #:supply-left 26 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 8 'immortal 1 'observer 1)
    #:enemy-building-counts (hasheq 'spine-crawler 4)
    #:enemy-unit-counts (hasheq 'zergling 8)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-static-def-count 4 'rush-prob 0.05))))
(reset-macro-escrow-tracker!)
(define p-86d-pvz-0roach-2imm
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 9400
    #:minerals 280 #:gas 180 #:supply-used 90 #:supply-cap 116 #:supply-left 26 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 8 'immortal 2 'observer 1)
    #:enemy-building-counts (hasheq 'spine-crawler 4)
    #:enemy-unit-counts (hasheq 'zergling 8)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1)
    #:mirror-signals (hasheq 'enemy-turtle-posterior 0.65 'enemy-static-def-count 4 'rush-prob 0.05))))
(check! (and (< (cand-u p-86d-pvz-0roach-1imm 'robotics-bay) 615.0)
             (>= (cand-u p-86d-pvz-0roach-2imm 'robotics-bay) 615.0))
        (format "8c. PvZ 2-Immortal core (0 live Roaches) failed: 1immBay=~a 2immBay=~a"
                (cand-u p-86d-pvz-0roach-1imm 'robotics-bay)
                (cand-u p-86d-pvz-0roach-2imm 'robotics-bay)))

;; =============================================================================
;; Section 9: Loop 86E Surgical Polish (TvT Factory/Tank Viking Exemption,
;;            Protoss & Terran Push Gas-Pull Tier, and Protoss Over-Infra Gates)
;; =============================================================================

;; 9a: TvT enemy with Factory / SiegeTank (even with 0 enemy Vikings currently visible in fog!)
;;     exempts viking-fighter from the <=4 anti-Medivac cap so TvT air-vision scales past 4!
(reset-macro-escrow-tracker!)
(define t-86e-tvt-factory-viking-exempt
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 12000
    #:minerals 420 #:gas 260 #:supply-used 112 #:supply-cap 140 #:supply-left 28 #:pending-supply 0
    #:workers 56 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 56 #:enemy-threat-supply 24 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 4 'supply-depot 14 'barracks 5
                                    'factory 2 'factory-techlab 2 'starport 1 'starport-reactor 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 4 'supply-depot 14 'barracks 5
                                    'factory 2 'factory-techlab 2 'starport 1 'starport-reactor 1 'refinery 6)
    #:unit-counts (hasheq 'scv 56 'marine 24 'marauder 4 'siege-tank 5 'medivac 4 'viking-fighter 4)
    #:enemy-building-counts (hasheq 'barracks 4 'factory 1 'starport 1)
    #:enemy-unit-counts (hasheq 'marine 16 'siege-tank 3 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 4 'barracks 5 'factory 2 'starport 2))))
(check! (and (> (cand-u t-86e-tvt-factory-viking-exempt 'viking-fighter) 30.0)
             (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-86e-tvt-factory-viking-exempt)))))
        (format "9a. TvT enemy with Factory/Tanks MUST exempt Viking past 4 even when enemy Vikings are fogged; u=~a sched=~s"
                (cand-u t-86e-tvt-factory-viking-exempt 'viking-fighter)
                (macro-brain-decision-scheduled-ids t-86e-tvt-factory-viking-exempt)))

;; 9b: Protoss midgame gas-pull tier (190G / 95M, >=4 gas workers -> pulls excess, holds <180M,
;;     resumes >=180M) AND Terran push gas-pull tier (165G / 100M, >=4 gas workers -> pulls excess)!
(let ()
  (define pb1 (mk-b 1 30.0 30.0 #:type 'nexus #:asgn 12 #:ideal 16 #:patches '(501 502)))
  (define pb2 (mk-b 2 62.0 30.0 #:type 'nexus #:asgn 10 #:ideal 16 #:patches '(503 504)))
  (define m1 (mk-m 501 25.0 30.0 #:owner 1))
  (define m2 (mk-m 502 25.0 32.0 #:owner 1))
  (define m3 (mk-m 503 67.0 30.0 #:owner 2))
  (define m4 (mk-m 504 67.0 32.0 #:owner 2))
  (define pg1 (mk-g 10 30.0 24.0 #:type 'assimilator #:asgn 3 #:ideal 3 #:base 1))
  (define pg2 (mk-g 11 36.0 24.0 #:type 'assimilator #:asgn 3 #:ideal 3 #:base 1))
  (define pg3 (mk-g 12 62.0 24.0 #:type 'assimilator #:asgn 3 #:ideal 3 #:base 2))
  (define pmin-ws
    (append (for/list ([i (in-range 12)]) (mk-w (+ 100 i) 26.0 (+ 28.0 (* 0.2 i)) #:type 'probe #:tgt 501))
            (for/list ([i (in-range 10)]) (mk-w (+ 120 i) 66.0 (+ 28.0 (* 0.2 i)) #:type 'probe #:tgt 503))))
  (define pgas-ws-9
    (append (for/list ([i (in-range 3)]) (mk-w (+ 200 i) 30.0 25.0 #:type 'probe #:tgt 10))
            (for/list ([i (in-range 3)]) (mk-w (+ 210 i) 36.0 25.0 #:type 'probe #:tgt 11))
            (for/list ([i (in-range 3)]) (mk-w (+ 220 i) 62.0 25.0 #:type 'probe #:tgt 12))))
  (define pst (make-worker-sat-state))
  (define ds-p-pull
    (evaluate-worker-saturation-policy!
     pst #:loop 8200 #:race 'Protoss #:minerals 95 #:gas 190
     #:workers (append pmin-ws pgas-ws-9)
     #:bases (list pb1 pb2) #:gas-buildings (list pg1 pg2 pg3)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 240.0))
  (define pg2-empty (mk-g 11 36.0 24.0 #:type 'assimilator #:asgn 0 #:ideal 3 #:base 1))
  (define pg3-empty (mk-g 12 62.0 24.0 #:type 'assimilator #:asgn 0 #:ideal 3 #:base 2))
  (define pgas-ws-3
    (for/list ([i (in-range 3)]) (mk-w (+ 200 i) 30.0 25.0 #:type 'probe #:tgt 10)))
  (define ds-p-hold
    (evaluate-worker-saturation-policy!
     pst #:loop 8300 #:race 'Protoss #:minerals 145 #:gas 160
     #:workers (append pmin-ws pgas-ws-3)
     #:bases (list pb1 pb2) #:gas-buildings (list pg1 pg2-empty pg3-empty)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 900.0 #:gas-demand-rate 450.0))
  (define p-hold-refill
    (for/sum ([d (in-list ds-p-hold)]
              #:when (and (eq? (sat-directive-kind d) 'harvest-gather)
                          (memv (sat-directive-target-tag d) '(10 11 12))))
      (length (sat-directive-unit-tags d))))
  (define ds-p-rel
    (evaluate-worker-saturation-policy!
     pst #:loop 8360 #:race 'Protoss #:minerals 210 #:gas 160
     #:workers (append pmin-ws pgas-ws-3)
     #:bases (list pb1 pb2) #:gas-buildings (list pg1 pg2-empty pg3-empty)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 900.0 #:gas-demand-rate 450.0))
  (define p-rel-refill
    (for/sum ([d (in-list ds-p-rel)]
              #:when (and (eq? (sat-directive-kind d) 'harvest-gather)
                          (memv (sat-directive-target-tag d) '(10 11 12))))
      (length (sat-directive-unit-tags d))))
  ;; Terran mid-push at 165G / 100M under mineral-heavy Marine push demand -> pulls >= 3 SCVs!
  (define tb1 (mk-b 1 30.0 30.0 #:type 'orbital-command #:asgn 12 #:ideal 16 #:patches '(501 502)))
  (define tb2 (mk-b 2 62.0 30.0 #:type 'orbital-command #:asgn 10 #:ideal 16 #:patches '(503 504)))
  (define tg1 (mk-g 10 30.0 24.0 #:type 'refinery #:asgn 3 #:ideal 3 #:base 1))
  (define tg2 (mk-g 11 36.0 24.0 #:type 'refinery #:asgn 3 #:ideal 3 #:base 1))
  (define tmin-ws
    (append (for/list ([i (in-range 12)]) (mk-w (+ 300 i) 26.0 (+ 28.0 (* 0.2 i)) #:type 'scv #:tgt 501))
            (for/list ([i (in-range 10)]) (mk-w (+ 320 i) 66.0 (+ 28.0 (* 0.2 i)) #:type 'scv #:tgt 503))))
  (define tgas-ws-6
    (append (for/list ([i (in-range 3)]) (mk-w (+ 400 i) 30.0 25.0 #:type 'scv #:tgt 10))
            (for/list ([i (in-range 3)]) (mk-w (+ 410 i) 36.0 25.0 #:type 'scv #:tgt 11))))
  (define tst (make-worker-sat-state))
  (define ds-t-push
    (evaluate-worker-saturation-policy!
     tst #:loop 9000 #:race 'Terran #:minerals 100 #:gas 165
     #:workers (append tmin-ws tgas-ws-6)
     #:bases (list tb1 tb2) #:gas-buildings (list tg1 tg2)
     #:minerals-fields (list m1 m2 m3 m4)
     #:mineral-demand-rate 1400.0 #:gas-demand-rate 180.0))
  (check! (and (>= (gas-pull-worker-count ds-p-pull) 3)
               (= p-hold-refill 0)
               (>= p-rel-refill 1)
               (>= (gas-pull-worker-count ds-t-push) 3))
          (format "9b. Protoss gas-pull / Terran 160G/<105M push pull failed: pPull=~a pHold=~a pRel=~a tPush=~a"
                  (gas-pull-worker-count ds-p-pull) p-hold-refill p-rel-refill
                  (gas-pull-worker-count ds-t-push))))

;; 9c: Protoss Over-Infrastructure Gates:
;;     (i) Gateway #5+ gated behind army >= 20 (or min >= 650); Gateway #7+ behind army >= 32 (or min >= 800)!
;;     (ii) 2nd Robotics Facility gated behind army >= 22 (or min >= 550)!
;;     (iii) Peaceful PvT suppresses speculative PhotonCannon & ShieldBattery!
(reset-macro-escrow-tracker!)
(define p-86e-gw5-low-army
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 7200
    #:minerals 320 #:gas 150 #:supply-used 52 #:supply-cap 78 #:supply-left 26 #:pending-supply 0
    #:workers 38 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 10
    #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 38 'stalker 5 'immortal 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 0))))
(reset-macro-escrow-tracker!)
(define p-86e-gw7-low-army
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 9600
    #:minerals 350 #:gas 180 #:supply-used 76 #:supply-cap 102 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 3 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 24 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'stalker 8 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 0 'robotics-facility 0))))
(reset-macro-escrow-tracker!)
(define p-86e-robo2-low-army
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10400
    #:minerals 320 #:gas 200 #:supply-used 70 #:supply-cap 102 #:supply-left 32 #:pending-supply 0
    #:workers 52 #:active-bases 3 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 18 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'stalker 5 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 0 'robotics-facility 0))))
(reset-macro-escrow-tracker!)
(define p-86e-pvt-peaceful-no-static
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7600
    #:minerals 320 #:gas 140 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 32 #:gas-harvesters 10
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'forge 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'forge 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 42 'stalker 9 'immortal 2)
    #:enemy-unit-counts (hasheq 'marine 10 'marauder 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.08))))
(check! (and (not (memq 'gateway (macro-brain-decision-scheduled-ids p-86e-gw5-low-army)))
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-86e-gw7-low-army)))
             (not (memq 'robotics-facility (macro-brain-decision-scheduled-ids p-86e-robo2-low-army)))
             (not (memq 'photon-cannon (macro-brain-decision-scheduled-ids p-86e-pvt-peaceful-no-static)))
             (not (memq 'shield-battery (macro-brain-decision-scheduled-ids p-86e-pvt-peaceful-no-static))))
        (format "9c. Protoss over-infra gates failed: gw5=~s gw7=~s robo2=~s pvtStatic=~s"
                (macro-brain-decision-scheduled-ids p-86e-gw5-low-army)
                (macro-brain-decision-scheduled-ids p-86e-gw7-low-army)
                (macro-brain-decision-scheduled-ids p-86e-robo2-low-army)
                (macro-brain-decision-scheduled-ids p-86e-pvt-peaceful-no-static)))

(printf "l86-anti-greed-macro-test: ~a passed, ~a failed\n" pass-count fail-count)
(unless (= fail-count 0)
  (exit 1))
