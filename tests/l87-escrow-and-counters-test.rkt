#lang racket/base

;; =============================================================================
;; Loop 87 Track 1 Unit Tests: Priority Escrow Integrity & Anti-Banshee / Tank Macro
;;   1. Terran 4th/5th CC escrow protection (blocks scv/marine drain under mild threat)
;;   2. Protoss anti-Banshee / cloaked-air Stalker escrow & Probe-urgency cap
;;   3. Terran anti-Banshee Turret, Starport, Viking, and Raven escalation
;;   4. Protoss PvT anti-Siege-Tank Immortal & RoboticsBay continuity
;; =============================================================================

(require racket/list
         "../lib/econ-ledger.rkt"
         "../lib/build-orders/cheese.rkt"
         "../lib/priority-macro-brain.rkt")

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

;; =============================================================================
;; Section 1: Terran 4th / 5th CC Escrow Protection
;; =============================================================================

;; 1a: 3-base Terran at 8:20 with 50 SCVs, 35 army, mild threat (12), 180M ->
;; command-center escrows at top AND neither scv nor marine drains below 400M!
(reset-macro-escrow-tracker!)
(define t-4th-escrow-180
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 11225
    #:minerals 180 #:gas 140 #:supply-used 90 #:supply-cap 116 #:supply-left 26 #:pending-supply 0
    #:workers 50 #:active-bases 3 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 35 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 5 'factory 2
                                    'factory-techlab 2 'starport 1 'starport-reactor 1
                                    'engineering-bay 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 5 'factory 2
                                    'factory-techlab 2 'starport 1 'starport-reactor 1
                                    'engineering-bay 1 'refinery 4)
    #:unit-counts (hasheq 'scv 50 'marine 14 'marauder 4 'siege-tank 4 'medivac 2)
    #:enemy-unit-counts (hasheq 'marine 8 'siege-tank 2)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 5 'factory 2 'starport 2)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (eq? (macro-brain-decision-saving-for t-4th-escrow-180) 'command-center)
             (not (memq 'scv (macro-brain-decision-scheduled-ids t-4th-escrow-180)))
             (not (memq 'marine (macro-brain-decision-scheduled-ids t-4th-escrow-180))))
        (format "1a. Terran 4th CC@180M must block scv/marine drain; sav=~a sched=~s cc-u=~a"
                (macro-brain-decision-saving-for t-4th-escrow-180)
                (macro-brain-decision-scheduled-ids t-4th-escrow-180)
                (cand-u t-4th-escrow-180 'command-center)))

;; 1b: 3-base Terran at 9:00 with 52 SCVs, 36 army, 80M bank -> still saves for 4th CC without 50M scv/marine sawtooth!
(reset-macro-escrow-tracker!)
(define t-4th-escrow-80
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 12100
    #:minerals 80 #:gas 120 #:supply-used 94 #:supply-cap 116 #:supply-left 22 #:pending-supply 0
    #:workers 52 #:active-bases 3 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 36 #:enemy-threat-supply 10 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 5 'factory 1
                                    'factory-techlab 1 'starport 1 'starport-reactor 1
                                    'engineering-bay 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 5 'factory 1
                                    'factory-techlab 1 'starport 1 'starport-reactor 1
                                    'engineering-bay 1 'refinery 4)
    #:unit-counts (hasheq 'scv 52 'marine 16 'marauder 6 'siege-tank 2 'medivac 2)
    #:enemy-unit-counts (hasheq 'stalker 5)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 5 'factory 1 'starport 2)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (eq? (macro-brain-decision-saving-for t-4th-escrow-80) 'command-center)
             (>= (cand-u t-4th-escrow-80 'command-center) 915.0)
             (not (memq 'scv (macro-brain-decision-scheduled-ids t-4th-escrow-80)))
             (not (memq 'marine (macro-brain-decision-scheduled-ids t-4th-escrow-80))))
        (format "1b. Terran 4th CC@80M (9:00) must block scv/marine sawtooth; sav=~a sched=~s cc-u=~a"
                (macro-brain-decision-saving-for t-4th-escrow-80)
                (macro-brain-decision-scheduled-ids t-4th-escrow-80)
                (cand-u t-4th-escrow-80 'command-center)))

;; 1c: Safety guard: Terran genuinely under-attack with low army (12 vs 18 threat) MUST still train Marines!
(reset-macro-escrow-tracker!)
(define t-under-attack-safety
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Zerg #:frame 11500
    #:minerals 120 #:gas 40 #:supply-used 64 #:supply-cap 100 #:supply-left 36 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 12 #:enemy-threat-supply 18 #:under-attack? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 10 'barracks 4 'factory 1
                                    'starport 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 10 'barracks 4 'factory 1
                                    'starport 1 'refinery 4)
    #:unit-counts (hasheq 'scv 48 'marine 8 'medivac 2)
    #:enemy-unit-counts (hasheq 'roach 9)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 4 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (memq 'marine (macro-brain-decision-scheduled-ids t-under-attack-safety))
             (not (eq? (macro-brain-decision-saving-for t-under-attack-safety) 'command-center)))
        (format "1c. Terran under-attack w/ low army must train marines, not save for 4th CC; sav=~a sched=~s"
                (macro-brain-decision-saving-for t-under-attack-safety)
                (macro-brain-decision-scheduled-ids t-under-attack-safety)))

;; 1d: 4-base Terran at 9:30 with 48 SCVs (MULE economy), 28 army, mild threat -> 5th CC escrows cleanly!
(reset-macro-escrow-tracker!)
(define t-5th-cc-930
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Zerg #:frame 12800
    #:minerals 180 #:gas 150 #:supply-used 84 #:supply-cap 116 #:supply-left 32 #:pending-supply 0
    #:workers 48 #:active-bases 4 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 10 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 4 'supply-depot 11 'barracks 5 'factory 2
                                    'factory-techlab 1 'starport 1 'starport-reactor 1
                                    'engineering-bay 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 4 'supply-depot 11 'barracks 5 'factory 2
                                    'factory-techlab 1 'starport 1 'starport-reactor 1
                                    'engineering-bay 1 'refinery 4)
    #:unit-counts (hasheq 'scv 48 'marine 16 'marauder 4 'siege-tank 2 'medivac 2)
    #:enemy-unit-counts (hasheq 'roach 5)
    #:open-facility-slots (hasheq 'townhall 4 'barracks 5 'factory 2 'starport 2)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (eq? (macro-brain-decision-saving-for t-5th-cc-930) 'command-center)
             (>= (cand-u t-5th-cc-930 'command-center) 915.0)
             (not (memq 'scv (macro-brain-decision-scheduled-ids t-5th-cc-930)))
             (not (memq 'marine (macro-brain-decision-scheduled-ids t-5th-cc-930))))
        (format "1d. Terran 4b at 9:30 (48w) must escrow 5th CC & block scv/marine; sav=~a sched=~s cc-u=~a"
                (macro-brain-decision-saving-for t-5th-cc-930)
                (macro-brain-decision-scheduled-ids t-5th-cc-930)
                (cand-u t-5th-cc-930 'command-center)))

;; =============================================================================
;; Section 2: Protoss Anti-Banshee / Cloaked-Air Stalker Escrow & Probe Cap
;; =============================================================================

;; 2a: Protoss raided down to 15 Probes (< 20!) vs 4 Banshees, 2 Observers alive, 85M/80G ->
;; stalker@840 stays top of escrow and probe MUST NOT drain 50M!
(reset-macro-escrow-tracker!)
(define p-banshee-15w
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 6720
    #:minerals 85 #:gas 80 #:supply-used 22 #:supply-cap 54 #:supply-left 32 #:pending-supply 0
    #:workers 15 #:active-bases 2 #:mineral-harvesters 9 #:gas-harvesters 6
    #:army-supply 4 #:enemy-threat-supply 12 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 15 'stalker 1 'observer 2)
    #:enemy-unit-counts (hasheq 'banshee 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 1)
    #:mirror-signals (hasheq 'requires-detection? #t 'requires-anti-air? #t 'rush-prob 0.10))))
(check! (and (eq? (macro-brain-decision-saving-for p-banshee-15w) 'stalker)
             (>= (cand-u p-banshee-15w 'stalker) 840.0)
             (not (memq 'probe (macro-brain-decision-scheduled-ids p-banshee-15w))))
        (format "2a. Protoss@15w vs 4 Banshees must hold stalker escrow & block probe; sav=~a sched=~s stalker-u=~a probe-u=~a"
                (macro-brain-decision-saving-for p-banshee-15w)
                (macro-brain-decision-scheduled-ids p-banshee-15w)
                (cand-u p-banshee-15w 'stalker)
                (cand-u p-banshee-15w 'probe)))

;; 2b: Severe Banshee raid down to 5 Probes (< 8!): probe urgency MUST be capped <= 520 (< stalker@840)
;; and MUST NOT bypass stalker's 125M escrow!
(reset-macro-escrow-tracker!)
(define p-banshee-5w
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7950
    #:minerals 80 #:gas 65 #:supply-used 9 #:supply-cap 54 #:supply-left 45 #:pending-supply 0
    #:workers 5 #:active-bases 2 #:mineral-harvesters 3 #:gas-harvesters 2
    #:army-supply 2 #:enemy-threat-supply 18 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 5 'observer 2)
    #:enemy-unit-counts (hasheq 'banshee 6)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 1)
    #:mirror-signals (hasheq 'requires-detection? #t 'requires-anti-air? #t 'rush-prob 0.10))))
(check! (and (<= (cand-u p-banshee-5w 'probe) 520.0)
             (not (cand-blk? p-banshee-5w 'probe))
             (eq? (macro-brain-decision-saving-for p-banshee-5w) 'stalker)
             (not (memq 'probe (macro-brain-decision-scheduled-ids p-banshee-5w))))
        (format "2b. Protoss@5w vs 6 Banshees must cap probe <=520 & hold stalker escrow; probe-u=~a probe-blk=~a sav=~a sched=~s"
                (cand-u p-banshee-5w 'probe)
                (cand-blk? p-banshee-5w 'probe)
                (macro-brain-decision-saving-for p-banshee-5w)
                (macro-brain-decision-scheduled-ids p-banshee-5w)))

;; 2c: Zero-worker safety: at 0 Probes and 60M/0G, Protoss still schedules Probe recovery!
(reset-macro-escrow-tracker!)
(define p-zero-worker-recovery
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8200
    #:minerals 60 #:gas 0 #:supply-used 2 #:supply-cap 38 #:supply-left 36 #:pending-supply 0
    #:workers 0 #:active-bases 1 #:mineral-harvesters 0 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1)
    #:unit-counts (hasheq 'observer 1)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2)
    #:mirror-signals (hasheq 'requires-detection? #t 'requires-anti-air? #t))))
(check! (memq 'probe (macro-brain-decision-scheduled-ids p-zero-worker-recovery))
        (format "2c. 0-Probe Protoss@60M/0G must schedule Probe recovery; sched=~s probe-u=~a"
                (macro-brain-decision-scheduled-ids p-zero-worker-recovery)
                (cand-u p-zero-worker-recovery 'probe)))

;; =============================================================================
;; Section 3: Terran Anti-Banshee Turret, Starport, Viking, and Raven Escalation
;; =============================================================================

;; 3a: 2-base Terran vs 5 Banshees with 1 Turret & low econ (16w, 5 army, 80M) ->
;; Turret #2 MUST stay blocking@1260 (NOT downgraded by low-econ nonblocking)!
(reset-macro-escrow-tracker!)
(define t-banshee-turret2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 6500
    #:minerals 80 #:gas 90 #:supply-used 24 #:supply-cap 46 #:supply-left 22 #:pending-supply 0
    #:workers 16 #:active-bases 2 #:mineral-harvesters 10 #:gas-harvesters 6
    #:army-supply 5 #:enemy-threat-supply 15 #:under-attack? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 2 'factory 1
                                    'engineering-bay 1 'missile-turret 1 'refinery 2)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 2 'factory 1
                                    'engineering-bay 1 'missile-turret 1 'refinery 2)
    #:unit-counts (hasheq 'scv 16 'marine 5)
    #:enemy-unit-counts (hasheq 'banshee 5)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1)
    #:mirror-signals (hasheq 'requires-detection? #t 'requires-anti-air? #t))))
(check! (and (>= (cand-u t-banshee-turret2 'missile-turret) 1260.0)
             (cand-blk? t-banshee-turret2 'missile-turret)
             (eq? (macro-brain-decision-saving-for t-banshee-turret2) 'missile-turret))
        (format "3a. Terran vs 5 Banshees@1 Turret must keep Turret #2 locked@1260; u=~a blk=~a sav=~a sched=~s"
                (cand-u t-banshee-turret2 'missile-turret)
                (cand-blk? t-banshee-turret2 'missile-turret)
                (macro-brain-decision-saving-for t-banshee-turret2)
                (macro-brain-decision-scheduled-ids t-banshee-turret2)))

;; 3b: 2-base Terran vs 6 Banshees with 3 Turrets, Starport ready, 2 Vikings, 85M/60G ->
;; viking-fighter escrows at top AND neither scv nor marine drains below 150M!
(reset-macro-escrow-tracker!)
(define t-banshee-viking-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 7600
    #:minerals 85 #:gas 60 #:supply-used 42 #:supply-cap 62 #:supply-left 20 #:pending-supply 0
    #:workers 24 #:active-bases 2 #:mineral-harvesters 18 #:gas-harvesters 6
    #:army-supply 14 #:enemy-threat-supply 18 #:under-attack? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 6 'barracks 2 'factory 1
                                    'starport 1 'engineering-bay 1 'missile-turret 3 'refinery 2)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 6 'barracks 2 'factory 1
                                    'starport 1 'engineering-bay 1 'missile-turret 3 'refinery 2)
    #:unit-counts (hasheq 'scv 24 'marine 10 'viking-fighter 2)
    #:enemy-unit-counts (hasheq 'banshee 6)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'requires-detection? #t 'requires-anti-air? #t))))
(check! (and (eq? (macro-brain-decision-saving-for t-banshee-viking-escrow) 'viking-fighter)
             (not (memq 'scv (macro-brain-decision-scheduled-ids t-banshee-viking-escrow)))
             (not (memq 'marine (macro-brain-decision-scheduled-ids t-banshee-viking-escrow))))
        (format "3b. Terran vs 6 Banshees must protect viking-fighter escrow from scv/marine drain; sav=~a sched=~s vik-u=~a"
                (macro-brain-decision-saving-for t-banshee-viking-escrow)
                (macro-brain-decision-scheduled-ids t-banshee-viking-escrow)
                (cand-u t-banshee-viking-escrow 'viking-fighter)))

;; 3c: 2-base Terran vs 4 Banshees with StarportTechLab ready, 4 Vikings, 0 Ravens ->
;; Raven #1 boosted >= 680 & blocking!
(reset-macro-escrow-tracker!)
(define t-banshee-raven
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 8200
    #:minerals 160 #:gas 180 #:supply-used 56 #:supply-cap 78 #:supply-left 22 #:pending-supply 0
    #:workers 30 #:active-bases 2 #:mineral-harvesters 22 #:gas-harvesters 8
    #:army-supply 20 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'factory 1
                                    'starport 1 'starport-techlab 1 'engineering-bay 1
                                    'missile-turret 3 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'factory 1
                                    'starport 1 'starport-techlab 1 'engineering-bay 1
                                    'missile-turret 3 'refinery 3)
    #:unit-counts (hasheq 'scv 30 'marine 12 'viking-fighter 4)
    #:enemy-unit-counts (hasheq 'banshee 4)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'requires-detection? #t 'requires-anti-air? #t))))
(check! (and (>= (cand-u t-banshee-raven 'raven) 680.0)
             (cand-blk? t-banshee-raven 'raven))
        (format "3c. Terran vs 4 Banshees w/ StarportTechLab must boost Raven #1 >=680 & blk; u=~a blk=~a sched=~s"
                (cand-u t-banshee-raven 'raven)
                (cand-blk? t-banshee-raven 'raven)
                (macro-brain-decision-scheduled-ids t-banshee-raven)))

;; 3d: 2-base Terran vs 4 Banshees with 4 Vikings, bare Starport, 0 StarportTechLab ->
;; StarportTechLab boosted >= 670!
(reset-macro-escrow-tracker!)
(define t-banshee-sptl
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 8200
    #:minerals 160 #:gas 100 #:supply-used 56 #:supply-cap 78 #:supply-left 22 #:pending-supply 0
    #:workers 30 #:active-bases 2 #:mineral-harvesters 22 #:gas-harvesters 8
    #:army-supply 20 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'factory 1
                                    'starport 1 'engineering-bay 1 'missile-turret 3 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'factory 1
                                    'starport 1 'engineering-bay 1 'missile-turret 3 'refinery 3)
    #:unit-counts (hasheq 'scv 30 'marine 12 'viking-fighter 4)
    #:enemy-unit-counts (hasheq 'banshee 4)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'requires-detection? #t 'requires-anti-air? #t))))
(check! (and (>= (cand-u t-banshee-sptl 'starport-techlab) 670.0)
             (cand-blk? t-banshee-sptl 'starport-techlab))
        (format "3d. Terran vs 4 Banshees w/ 4 Vikings must boost StarportTechLab >=670; u=~a blk=~a"
                (cand-u t-banshee-sptl 'starport-techlab)
                (cand-blk? t-banshee-sptl 'starport-techlab)))

;; =============================================================================
;; Section 4: Protoss PvT Anti-Siege-Tank Transition Continuity
;; =============================================================================

;; 4a: 3-base Protoss vs 7 Siege Tanks with 0 Stargates, 1 Robo, 0 RoboBay, 1 Immortal, Charge ready ->
;; Immortal boosted@635 ahead of Chargelots AND RoboticsBay stays active (>= 600, NOT suppressed)!
(reset-macro-escrow-tracker!)
(define p-pvt-7tanks-no-sg
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9400
    #:minerals 220 #:gas 160 #:supply-used 90 #:supply-cap 116 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 3 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 24 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'twilight-council 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'twilight-council 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'zealot 6 'stalker 8 'immortal 1 'observer 1)
    #:enemy-unit-counts (hasheq 'siege-tank 7 'marine 12 'medivac 2)
    #:researched-upgrades '(warp-gate-research charge)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 5 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.05 'enemy-turtle-posterior 0.55))))
(check! (and (>= (cand-u p-pvt-7tanks-no-sg 'immortal) 635.0)
             (> (cand-u p-pvt-7tanks-no-sg 'immortal) (cand-u p-pvt-7tanks-no-sg 'zealot))
             (>= (cand-u p-pvt-7tanks-no-sg 'robotics-bay) 600.0))
        (format "4a. PvT vs 7 Tanks w/ 0 Stargates must boost Immortal@635 > Zealot AND keep RoboBay >=600; imm=~a zeal=~a bay=~a sched=~s"
                (cand-u p-pvt-7tanks-no-sg 'immortal)
                (cand-u p-pvt-7tanks-no-sg 'zealot)
                (cand-u p-pvt-7tanks-no-sg 'robotics-bay)
                (macro-brain-decision-scheduled-ids p-pvt-7tanks-no-sg)))

;; 4b: 3-base Protoss vs 7 Tanks WITH Stargate ready & 2 Immortals -> FleetBeacon/Tempest pivot works cleanly!
(reset-macro-escrow-tracker!)
(define p-pvt-7tanks-with-sg
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10400
    #:minerals 360 #:gas 260 #:supply-used 102 #:supply-cap 130 #:supply-left 28 #:pending-supply 0
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 24 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'stargate 1 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'stargate 1 'assimilator 5)
    #:unit-counts (hasheq 'probe 56 'zealot 6 'stalker 10 'immortal 2 'observer 1)
    #:enemy-unit-counts (hasheq 'siege-tank 7 'marine 12)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1 'stargate 1)
    #:mirror-signals (hasheq 'rush-prob 0.05 'enemy-turtle-posterior 0.65))))
(check! (>= (cand-u p-pvt-7tanks-with-sg 'fleet-beacon) 635.0)
        (format "4b. PvT vs 7 Tanks w/ Stargate + 2 Immortals must boost FleetBeacon >=635; fb=~a bay=~a"
                (cand-u p-pvt-7tanks-with-sg 'fleet-beacon)
                (cand-u p-pvt-7tanks-with-sg 'robotics-bay)))

;; 4c: Colossus #1 safety: PvT w/ RoboBay READY, 2 Immortals, 0 Colossi vs 4 Tanks -> Colossus@880 still beats Immortal #3!
(reset-macro-escrow-tracker!)
(define p-pvt-colossus-first
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9400
    #:minerals 350 #:gas 220 #:supply-used 92 #:supply-cap 116 #:supply-left 24 #:pending-supply 0
    #:workers 50 #:active-bases 2 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 38 #:enemy-threat-supply 16 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 50 'zealot 4 'stalker 10 'immortal 2 'observer 1)
    #:enemy-unit-counts (hasheq 'siege-tank 4 'marine 14)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (>= (cand-u p-pvt-colossus-first 'colossus) 880.0)
             (memq 'colossus (macro-brain-decision-scheduled-ids p-pvt-colossus-first)))
        (format "4c. PvT w/ RoboBay ready & 2 Immortals must still schedule Colossus #1 first; col=~a imm=~a sched=~s"
                (cand-u p-pvt-colossus-first 'colossus)
                (cand-u p-pvt-colossus-first 'immortal)
                (macro-brain-decision-scheduled-ids p-pvt-colossus-first)))

;; =============================================================================
;; 5. Loop 87B: Active Home-Crisis / Air-Threat Tech & Worker Throttle
;; =============================================================================

;; 5a: Protoss under active Banshee raid (3 Banshees, 6 Stalkers, Gateways busy) must NOT
;; schedule or escrow Twilight Council or Stargate.
(reset-macro-escrow-tracker!)
(define p-banshee-no-luxury-tech
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7500
    #:minerals 200 #:gas 160 #:supply-used 52 #:supply-cap 70 #:supply-left 18 #:pending-supply 0
    #:workers 30 #:active-bases 2 #:mineral-harvesters 22 #:gas-harvesters 8
    #:army-supply 16 #:enemy-threat-supply 12 #:under-attack? #t
    #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 30 'stalker 6 'observer 1)
    #:enemy-unit-counts (hasheq 'banshee 3 'marine 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.1))))
(check! (and (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-banshee-no-luxury-tech)))
             (not (memq 'stargate (macro-brain-decision-scheduled-ids p-banshee-no-luxury-tech)))
             (not (eq? (macro-brain-decision-saving-for p-banshee-no-luxury-tech) 'twilight-council))
             (not (eq? (macro-brain-decision-saving-for p-banshee-no-luxury-tech) 'stargate)))
        (format "5a. Active Banshee raid must suppress Twilight/Stargate sched & escrow; saving=~s sched=~s"
                (macro-brain-decision-saving-for p-banshee-no-luxury-tech)
                (macro-brain-decision-scheduled-ids p-banshee-no-luxury-tech)))

;; 5b: Severe home army deficit (army=20 vs threat=48, 3 bases, 54 Probes) must throttle
;; Probe production and suppress 4th Nexus & Twilight Council while allowing combat units.
(reset-macro-escrow-tracker!)
(define p-severe-home-deficit-throttle
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 11800
    #:minerals 420 #:gas 200 #:supply-used 74 #:supply-cap 110 #:supply-left 36 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 20 #:enemy-threat-supply 48 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 5)
    #:unit-counts (hasheq 'probe 54 'stalker 8 'immortal 1 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 24 'marauder 8 'siege-tank 4)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 5 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.05 'believed-enemy-army-supply 52))))
(check! (and (not (memq 'probe (macro-brain-decision-scheduled-ids p-severe-home-deficit-throttle)))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-severe-home-deficit-throttle)))
             (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-severe-home-deficit-throttle)))
             (<= (cand-u p-severe-home-deficit-throttle 'probe) 100.0))
        (format "5b. Severe home deficit at 54w/3b must throttle Probes & suppress 4th Nexus/Twilight; probe=~a sched=~s saving=~s"
                (cand-u p-severe-home-deficit-throttle 'probe)
                (macro-brain-decision-scheduled-ids p-severe-home-deficit-throttle)
                (macro-brain-decision-saving-for p-severe-home-deficit-throttle)))

;; 5c: Terran severe home deficit at 54w/3b must suppress 4th CC, FusionCore/Armory, and SCV throttle.
(reset-macro-escrow-tracker!)
(define t-severe-home-deficit-throttle
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 11800
    #:minerals 420 #:gas 180 #:supply-used 74 #:supply-cap 110 #:supply-left 36 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 20 #:enemy-threat-supply 48 #:under-attack? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 5)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 11 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 5)
    #:unit-counts (hasheq 'scv 54 'marine 12 'siege-tank 2 'medivac 1)
    #:enemy-unit-counts (hasheq 'marine 30 'siege-tank 5 'thor 2)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 4 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'rush-prob 0.05 'believed-enemy-army-supply 56))))
(check! (and (not (memq 'scv (macro-brain-decision-scheduled-ids t-severe-home-deficit-throttle)))
             (not (memq 'command-center (macro-brain-decision-scheduled-ids t-severe-home-deficit-throttle)))
             (not (memq 'armory (macro-brain-decision-scheduled-ids t-severe-home-deficit-throttle)))
             (not (eq? (macro-brain-decision-saving-for t-severe-home-deficit-throttle) 'command-center)))
        (format "5c. Terran severe home deficit at 54w/3b must suppress SCV/4th CC/Armory; sched=~s saving=~s"
                (macro-brain-decision-scheduled-ids t-severe-home-deficit-throttle)
                (macro-brain-decision-saving-for t-severe-home-deficit-throttle)))

;; 5d: Early-game < 40 worker recovery safety: 24 Probes under attack with open TH & busy GWs
;; must NOT be throttled by the >= 40w severe-crisis worker cap.
(reset-macro-escrow-tracker!)
(define p-early-under-40w-keeps-probes
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 6000
    #:minerals 180 #:gas 40 #:supply-used 36 #:supply-cap 54 #:supply-left 18 #:pending-supply 0
    #:workers 24 #:active-bases 2 #:mineral-harvesters 18 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 26 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 24 'stalker 4 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 14 'marauder 4 'siege-tank 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0)
    #:mirror-signals (hasheq 'rush-prob 0.1))))
(check! (memq 'probe (macro-brain-decision-scheduled-ids p-early-under-40w-keeps-probes))
        (format "5d. <40w early-game recovery must remain unthrottled when production slots are busy; probe=~a sched=~s"
                (cand-u p-early-under-40w-keeps-probes 'probe)
                (macro-brain-decision-scheduled-ids p-early-under-40w-keeps-probes)))

;; =============================================================================
;; 6. Loop 87B: Terran Viking Ratio Cap vs Low-Air Mech/Bio
;; =============================================================================

;; 6a: Low-air TvT Mech/Bio (1 Lib + 1 Viking + 4 Tanks + 24 Marines) with 4 Vikings alive
;; must cap Vikings at 4 and train Tank/Marine/Medivac instead of Viking #5.
(reset-macro-escrow-tracker!)
(define t-low-air-viking-cap4
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 11200
    #:minerals 280 #:gas 200 #:supply-used 88 #:supply-cap 126 #:supply-left 38 #:pending-supply 0
    #:workers 50 #:active-bases 3 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 38 #:enemy-threat-supply 26 #:under-attack? #f
    #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 13 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 5)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 13 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 5)
    #:unit-counts (hasheq 'scv 50 'marine 14 'siege-tank 4 'viking-fighter 4 'medivac 1)
    #:enemy-unit-counts (hasheq 'marine 24 'siege-tank 4 'liberator 1 'viking-fighter 1 'ghost 1)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 4 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-low-air-viking-cap4)))
             (not (eq? (macro-brain-decision-saving-for t-low-air-viking-cap4) 'viking-fighter))
             (<= (cand-u t-low-air-viking-cap4 'viking-fighter) 40.0))
        (format "6a. Low-air Mech/Bio (1 Lib + 1 Viking) must cap Vikings <=4; vik=~a sched=~s saving=~s"
                (cand-u t-low-air-viking-cap4 'viking-fighter)
                (macro-brain-decision-scheduled-ids t-low-air-viking-cap4)
                (macro-brain-decision-saving-for t-low-air-viking-cap4)))

;; 6b: Mid-air Mech/Bio (4 Libs + 2 Vikings = 6 air) with 8 Vikings alive must cap Vikings <= 8.
(reset-macro-escrow-tracker!)
(define t-mid-air-viking-cap8
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 13400
    #:minerals 260 #:gas 200 #:supply-used 108 #:supply-cap 142 #:supply-left 34 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 54 #:enemy-threat-supply 32 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 15 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 5)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 15 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 5)
    #:unit-counts (hasheq 'scv 54 'marine 18 'siege-tank 6 'viking-fighter 8 'medivac 2)
    #:enemy-unit-counts (hasheq 'marine 36 'siege-tank 6 'thor 4 'liberator 4 'viking-fighter 2)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 4 'factory 1 'starport 1)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-mid-air-viking-cap8)))
             (<= (cand-u t-mid-air-viking-cap8 'viking-fighter) 40.0))
        (format "6b. <8 enemy air (4 Libs + 2 Vikings) must cap Vikings <=8; vik=~a sched=~s"
                (cand-u t-mid-air-viking-cap8 'viking-fighter)
                (macro-brain-decision-scheduled-ids t-mid-air-viking-cap8)))

;; 6c: True mass air (>= 8 air combat units: 10 Mutalisks) unlocks Vikings past 8 cleanly.
(reset-macro-escrow-tracker!)
(define t-mass-air-viking-unlock
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Zerg #:frame 12400
    #:minerals 240 #:gas 180 #:supply-used 98 #:supply-cap 134 #:supply-left 36 #:pending-supply 0
    #:workers 50 #:active-bases 3 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 48 #:enemy-threat-supply 30 #:under-attack? #t #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 4 'factory 1
                                    'starport 2 'engineering-bay 1 'refinery 5)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 4 'factory 1
                                    'starport 2 'engineering-bay 1 'refinery 5)
    #:unit-counts (hasheq 'scv 50 'marine 20 'viking-fighter 8 'medivac 2)
    #:enemy-unit-counts (hasheq 'mutalisk 10 'zergling 8)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 4 'factory 1 'starport 2)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-mass-air-viking-unlock))
        (format "6c. >=8 enemy combat air (10 Mutas) must unlock Viking #9+; sched=~s"
                (macro-brain-decision-scheduled-ids t-mass-air-viking-unlock)))

;; =============================================================================
;; 7. Loop 87B: Protoss Observer Cap (<=2) & PvT Bio+Tank Colossus Priority
;; =============================================================================

;; 7a: Protoss with 2 Observers alive (no active cloak crisis) must NOT train Observer #3.
(reset-macro-escrow-tracker!)
(define p-obs-cap2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10800
    #:minerals 200 #:gas 160 #:supply-used 90 #:supply-cap 118 #:supply-left 28 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 36 #:enemy-threat-supply 18 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 54 'stalker 8 'zealot 6 'immortal 2 'observer 2)
    #:enemy-unit-counts (hasheq 'marine 12 'marauder 4 'widow-mine 3 'siege-tank 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (not (memq 'observer (macro-brain-decision-scheduled-ids p-obs-cap2)))
             (not (eq? (macro-brain-decision-saving-for p-obs-cap2) 'observer)))
        (format "7a. Protoss with 2 live Observers & no active cloak must cap Observers <=2; sched=~s saving=~s"
                (macro-brain-decision-scheduled-ids p-obs-cap2)
                (macro-brain-decision-saving-for p-obs-cap2)))

;; 7b: PvT Bio+Tank (7 Marines + 4 Marauders + 2 Tanks) with RoboBay READY, 1 Immortal,
;; 1 Observer, 0 Colossi, 56 Probes at 140M/75G must escrow Colossus #1 with 300M floor
;; (blocking Probe/Zealot mineral drain and blocking Immortal #2 / Observer #2!).
(reset-macro-escrow-tracker!)
(define p-pvt-biotank-colossus1-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10800
    #:minerals 140 #:gas 75 #:supply-used 84 #:supply-cap 118 #:supply-left 34 #:pending-supply 0
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 22 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:unit-counts (hasheq 'probe 56 'stalker 8 'zealot 4 'immortal 1 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 7 'marauder 4 'siege-tank 2 'medivac 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (eq? (macro-brain-decision-saving-for p-pvt-biotank-colossus1-escrow) 'colossus)
             (>= (macro-brain-decision-reserved-min-floor p-pvt-biotank-colossus1-escrow) 300)
             (not (memq 'probe (macro-brain-decision-scheduled-ids p-pvt-biotank-colossus1-escrow)))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-pvt-biotank-colossus1-escrow)))
             (not (memq 'immortal (macro-brain-decision-scheduled-ids p-pvt-biotank-colossus1-escrow)))
             (not (memq 'observer (macro-brain-decision-scheduled-ids p-pvt-biotank-colossus1-escrow))))
        (format "7b. PvT Bio+Tank w/ RoboBay ready & 0 Colossi @140M/75G must protect Colossus #1 300M escrow over Probe/Zealot/Immortal#2/Obs#2; saving=~s minfl=~a sched=~s"
                (macro-brain-decision-saving-for p-pvt-biotank-colossus1-escrow)
                (macro-brain-decision-reserved-min-floor p-pvt-biotank-colossus1-escrow)
                (macro-brain-decision-scheduled-ids p-pvt-biotank-colossus1-escrow)))

;; =============================================================================
;; 8. Loop 87B: Protoss Anti-Roach/Hydra Ranged Focus & Healthy PvZ 3rd Nexus
;; =============================================================================

;; 8a: Protoss vs 16 Roaches + 8 Hydras with 3 Stalkers & 4 Zealots at 300M/160G
;; must warp Stalker (not dump minerals into pure Zealots).
(reset-macro-escrow-tracker!)
(define p-anti-roach-hydra-stalker
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 11600
    #:minerals 300 #:gas 160 #:supply-used 94 #:supply-cap 126 #:supply-left 32 #:pending-supply 0
    #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 40 #:enemy-threat-supply 36 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:unit-counts (hasheq 'probe 54 'stalker 3 'zealot 4 'immortal 4 'colossus 2 'observer 1)
    #:enemy-unit-counts (hasheq 'roach 16 'hydralisk 8 'zergling 4)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 5 'robotics-facility 0)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (memq 'stalker (macro-brain-decision-scheduled-ids p-anti-roach-hydra-stalker))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-anti-roach-hydra-stalker)))
             (> (cand-u p-anti-roach-hydra-stalker 'stalker)
                (cand-u p-anti-roach-hydra-stalker 'zealot)))
        (format "8a. Protoss vs 16 Roaches + 8 Hydras @300M/160G must warp Stalkers over Zealots; stk=~a zeal=~a sched=~s"
                (cand-u p-anti-roach-hydra-stalker 'stalker)
                (cand-u p-anti-roach-hydra-stalker 'zealot)
                (macro-brain-decision-scheduled-ids p-anti-roach-hydra-stalker)))

;; 8b: Protoss with Immortal waiting on gas (140M/75G) must NOT allow 0-gas Zealot
;; to bypass Immortal's 250M mineral escrow.
(reset-macro-escrow-tracker!)
(define p-immortal-blocks-zealot-drain
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 7400
    #:minerals 140 #:gas 75 #:supply-used 60 #:supply-cap 78 #:supply-left 18 #:pending-supply 0
    #:workers 40 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 10
    #:army-supply 20 #:enemy-threat-supply 14 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 40 'stalker 4 'zealot 4 'immortal 1 'observer 1)
    #:enemy-unit-counts (hasheq 'roach 8 'zergling 6)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (eq? (macro-brain-decision-saving-for p-immortal-blocks-zealot-drain) 'immortal)
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-immortal-blocks-zealot-drain))))
        (format "8b. Immortal gas-wait escrow @140M/75G must block 0-gas Zealot mineral drain; saving=~s sched=~s"
                (macro-brain-decision-saving-for p-immortal-blocks-zealot-drain)
                (macro-brain-decision-scheduled-ids p-immortal-blocks-zealot-drain)))

;; 8c: Safe 2-base PvZ at 5:35 (frame=7500, 42 Probes, 1 Immortal, 20 army, 200M/100G)
;; must cleanly escrow 3rd Nexus instead of stalling on 2 bases.
(reset-macro-escrow-tracker!)
(define p-pvz-safe-3rd-nexus
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 7500
    #:minerals 200 #:gas 100 #:supply-used 62 #:supply-cap 78 #:supply-left 16 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 32 #:gas-harvesters 10
    #:army-supply 20 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 6 'zealot 2 'immortal 1 'observer 1)
    #:enemy-unit-counts (hasheq 'zergling 6 'queen 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 0)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (eq? (macro-brain-decision-saving-for p-pvz-safe-3rd-nexus) 'nexus)
        (format "8c. Safe 2-base PvZ @5:35 (42w, 1 Immortal, 200M) must escrow 3rd Nexus cleanly; saving=~s nex=~a sched=~s"
                (macro-brain-decision-saving-for p-pvz-safe-3rd-nexus)
                (cand-u p-pvz-safe-3rd-nexus 'nexus)
                (macro-brain-decision-scheduled-ids p-pvz-safe-3rd-nexus)))

;; =============================================================================
;; 9. Loop 87C: Local-Only Crisis Trigger, Zero-Air Viking Cap=0, Banshee
;;    Stargate/Twilight Hard-Block, Zerg Emergency Overseer/Lair/Spore, and
;;    Version C Cheese Macro Guards
;; =============================================================================

;; 9a: 1-unit home poke (enemy-threat-supply=2, global believed-enemy-army=60) on 1-base PvP
;; must NOT trigger severe-home-army-deficit or suppress Nexus #2 / Immortal.
(reset-macro-escrow-tracker!)
(define p-1unit-poke-no-global-crisis
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 4032
    #:minerals 420 #:gas 140 #:supply-used 34 #:supply-cap 46 #:supply-left 12 #:pending-supply 0
    #:workers 22 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 10 #:enemy-threat-supply 2 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 5 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 5 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 4 'adept 1)
    #:enemy-unit-counts (hasheq 'stalker 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.1 'believed-enemy-army-supply 60))))
(check! (and (> (cand-u p-1unit-poke-no-global-crisis 'nexus) 35.0)
             (or (memq 'nexus (macro-brain-decision-scheduled-ids p-1unit-poke-no-global-crisis))
                 (memq 'immortal (macro-brain-decision-scheduled-ids p-1unit-poke-no-global-crisis))))
        (format "9a. 1-unit poke w/ high global believed army must NOT suppress Nexus #2 or Immortal; nex=~a sched=~s"
                (cand-u p-1unit-poke-no-global-crisis 'nexus)
                (macro-brain-decision-scheduled-ids p-1unit-poke-no-global-crisis)))

;; 9b: Terran vs 0 combat air / 0 Colossi (pure ground Zerg) caps viking-fighter strictly at 0!
(reset-macro-escrow-tracker!)
(define t-zero-air-zerg-viking-cap0
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Zerg #:frame 10800
    #:minerals 450 #:gas 240 #:supply-used 94 #:supply-cap 130 #:supply-left 36 #:pending-supply 0
    #:workers 50 #:active-bases 3 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 18 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 5)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 5)
    #:unit-counts (hasheq 'scv 50 'marine 20 'siege-tank 4 'medivac 2)
    #:enemy-unit-counts (hasheq 'roach 18 'hydralisk 8 'zergling 12)
    #:enemy-building-counts (hasheq 'hatchery 4 'roach-warren 1 'hydralisk-den 1)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 5 'factory 1 'starport 2)
    #:mirror-signals (hasheq 'rush-prob 0.05))))
(check! (and (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-zero-air-zerg-viking-cap0)))
             (not (eq? (macro-brain-decision-saving-for t-zero-air-zerg-viking-cap0) 'viking-fighter))
             (<= (cand-u t-zero-air-zerg-viking-cap0 'viking-fighter) 40.0))
        (format "9b. Terran vs 0 combat air / 0 Colossi must hard-cap Vikings at 0; vik=~a sched=~s saving=~s"
                (cand-u t-zero-air-zerg-viking-cap0 'viking-fighter)
                (macro-brain-decision-scheduled-ids t-zero-air-zerg-viking-cap0)
                (macro-brain-decision-saving-for t-zero-air-zerg-viking-cap0)))

;; 9c: Protoss active Banshee/cloak crisis with 0 Observers (even w/ 8 Stalkers & not under-attack?)
;; MUST hard-block Stargate & Twilight Council and pump Observer + Stalkers instead!
(reset-macro-escrow-tracker!)
(define p-banshee-no-obs-blocks-stargate
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7680
    #:minerals 280 #:gas 200 #:supply-used 56 #:supply-cap 78 #:supply-left 22 #:pending-supply 0
    #:workers 34 #:active-bases 2 #:mineral-harvesters 24 #:gas-harvesters 10
    #:army-supply 16 #:enemy-threat-supply 6 #:under-attack? #f
    #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 34 'stalker 8)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1)
    #:mirror-signals (hasheq 'rush-prob 0.1 'mirror-requires-detection? #t))))
(check! (and (not (memq 'stargate (macro-brain-decision-scheduled-ids p-banshee-no-obs-blocks-stargate)))
             (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-banshee-no-obs-blocks-stargate)))
             (not (eq? (macro-brain-decision-saving-for p-banshee-no-obs-blocks-stargate) 'stargate))
             (not (eq? (macro-brain-decision-saving-for p-banshee-no-obs-blocks-stargate) 'twilight-council))
             (memq 'observer (macro-brain-decision-scheduled-ids p-banshee-no-obs-blocks-stargate)))
        (format "9c. Banshee crisis w/ 0 Observers must hard-block Stargate/Twilight & schedule Observer; sched=~s saving=~s"
                (macro-brain-decision-scheduled-ids p-banshee-no-obs-blocks-stargate)
                (macro-brain-decision-saving-for p-banshee-no-obs-blocks-stargate)))

;; 9d: Zerg emergency detection on OWM cloaking-field / Banshees:
;;   (1) Missing Lair -> triggers urgent Lair + Spore Crawler
;;   (2) Lair ready & 0 Overseers -> morphs Overseer #1 urgently (u >= 1200)
;;   (3) Lair ready & 1 Overseer + HydraDen ready -> morphs Overseer #2 urgently (u >= 900)
(reset-macro-escrow-tracker!)
(define z-banshee-needs-lair-spore
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 7200
    #:minerals 300 #:gas 160 #:supply-used 68 #:supply-cap 90 #:supply-left 22 #:pending-supply 0
    #:workers 40 #:active-bases 3 #:mineral-harvesters 31 #:gas-harvesters 9
    #:army-supply 28 #:enemy-threat-supply 12 #:under-attack? #t
    #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'extractor 3 'roach-warren 1)
    #:total-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'extractor 3 'roach-warren 1)
    #:unit-counts (hasheq 'drone 40 'queen 6 'roach 8 'overlord 8)
    #:enemy-unit-counts (hasheq 'banshee 4)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'larva 6 'townhall 3)
    #:mirror-signals (hasheq 'rush-prob 0.05 'mirror-requires-detection? #t))))
(reset-macro-escrow-tracker!)
(define z-banshee-needs-overseer1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 8512
    #:minerals 320 #:gas 180 #:supply-used 98 #:supply-cap 130 #:supply-left 32 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 50 #:enemy-threat-supply 24 #:under-attack? #t
    #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1 'extractor 4 'spore-crawler 3)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1 'extractor 4 'spore-crawler 3)
    #:unit-counts (hasheq 'drone 48 'queen 8 'hydralisk 16 'overlord 10)
    #:enemy-unit-counts (hasheq 'banshee 7)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'larva 6 'townhall 3)
    #:mirror-signals (hasheq 'rush-prob 0.05 'mirror-requires-detection? #t))))
(reset-macro-escrow-tracker!)
(define z-banshee-needs-overseer2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 8800
    #:minerals 320 #:gas 180 #:supply-used 100 #:supply-cap 130 #:supply-left 30 #:pending-supply 0
    #:workers 48 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 52 #:enemy-threat-supply 24 #:under-attack? #t
    #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1 'extractor 4 'spore-crawler 3)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1 'extractor 4 'spore-crawler 3)
    #:unit-counts (hasheq 'drone 48 'queen 8 'hydralisk 16 'overlord 10 'overseer 1)
    #:enemy-unit-counts (hasheq 'banshee 7)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'larva 6 'townhall 3)
    #:mirror-signals (hasheq 'rush-prob 0.05 'mirror-requires-detection? #t))))
(check! (and (memq 'lair (macro-brain-decision-scheduled-ids z-banshee-needs-lair-spore))
             (memq 'spore-crawler (macro-brain-decision-scheduled-ids z-banshee-needs-lair-spore))
             (memq 'overseer (macro-brain-decision-scheduled-ids z-banshee-needs-overseer1))
             (>= (cand-u z-banshee-needs-overseer1 'overseer) 1200.0)
             (memq 'overseer (macro-brain-decision-scheduled-ids z-banshee-needs-overseer2))
             (>= (cand-u z-banshee-needs-overseer2 'overseer) 900.0))
        (format "9d. Zerg OWM Banshee/cloak detection must trigger Lair+Spore+2x Overseers; lair=~s ov1=(~a,~s) ov2=(~a,~s)"
                (macro-brain-decision-scheduled-ids z-banshee-needs-lair-spore)
                (cand-u z-banshee-needs-overseer1 'overseer)
                (macro-brain-decision-scheduled-ids z-banshee-needs-overseer1)
                (cand-u z-banshee-needs-overseer2 'overseer)
                (macro-brain-decision-scheduled-ids z-banshee-needs-overseer2)))

;; 9e: 4 Version C `(not cheese-active?)` guards in `priority-macro-brain.rkt`:
;;   - `terran-1base-nat-cc-lock?` suppressed during `tvp-1base-2gas-cyclone`
;;   - `protoss-first-gateway-due?` suppressed during `pvz-cannon-rush`
;;   - `protoss-warp-prism-cap >= 1` during 1-base `pvp-proxy-robo-immortal` (< 20 army)
;;   - `terran-suppress-reaper-now?` exempt on `tvt-proxy-2rax-reaper` & active on `tvz-reaper-fe-hellion-banshee`
(let ()
  (define c-cyc (lookup-cheese-build-spec 'tvp-1base-2gas-cyclone))
  (define c-can (lookup-cheese-build-spec 'pvz-cannon-rush))
  (define c-rob (lookup-cheese-build-spec 'pvp-proxy-robo-immortal))
  (define c-rep (lookup-cheese-build-spec 'tvt-proxy-2rax-reaper))
  (define c-rfe (lookup-cheese-build-spec 'tvz-reaper-fe-hellion-banshee))

  (reset-macro-escrow-tracker!)
  (define d-cyc
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 2688
      #:minerals 420 #:gas 150 #:supply-used 22 #:supply-cap 39 #:supply-left 17
      #:workers 19 #:active-bases 1 #:mineral-harvesters 13 #:gas-harvesters 6
      #:army-supply 3 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 2 'factory 1)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 2 'factory 1)
      #:unit-counts (hasheq 'scv 19 'marine 2)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 1 'factory 1))
     #:cheese-spec c-cyc))

  (reset-macro-escrow-tracker!)
  (define d-can
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 1700 ;; 76s < gateway 125s
      #:minerals 180 #:gas 0 #:supply-used 17 #:supply-cap 23 #:supply-left 6
      #:workers 17 #:active-bases 1 #:mineral-harvesters 17 #:gas-harvesters 0
      #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 1)
      #:total-building-counts (hasheq 'nexus 1 'pylon 1 'forge 1)
      #:unit-counts (hasheq 'probe 17)
      #:open-facility-slots (hasheq 'townhall 1))
     #:cheese-spec c-can))

  (reset-macro-escrow-tracker!)
  (define d-rob
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Protoss #:frame 4500
      #:minerals 280 #:gas 50 #:supply-used 30 #:supply-cap 46 #:supply-left 16
      #:workers 22 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
      #:army-supply 12 #:enemy-threat-supply 0 #:under-attack? #f
      #:researched-upgrades '(warp-gate-research)
      #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'warp-gate 2 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'pylon 4 'warp-gate 2 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 22 'stalker 4 'immortal 2)
      #:open-facility-slots (hasheq 'townhall 1 'warp-gate 2 'robotics-facility 1))
     #:cheese-spec c-rob))

  (reset-macro-escrow-tracker!)
  (define d-rep
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Terran #:frame 3500
      #:minerals 150 #:gas 120 #:supply-used 24 #:supply-cap 39 #:supply-left 15
      #:workers 19 #:active-bases 1 #:mineral-harvesters 13 #:gas-harvesters 6
      #:army-supply 5 #:enemy-threat-supply 2 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 2 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 2 'refinery 2)
      #:unit-counts (hasheq 'scv 19 'reaper 3)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 2))
     #:cheese-spec c-rep))

  (reset-macro-escrow-tracker!)
  (define d-rfe
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Zerg #:frame 3600
      #:minerals 150 #:gas 120 #:supply-used 28 #:supply-cap 46 #:supply-left 18
      #:workers 24 #:active-bases 2 #:mineral-harvesters 18 #:gas-harvesters 6
      #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'command-center 1 'supply-depot 2
                                      'barracks 1 'refinery 2 'factory 1)
      #:total-building-counts (hasheq 'orbital-command 1 'command-center 1 'supply-depot 2
                                      'barracks 1 'refinery 2 'factory 1)
      #:unit-counts (hasheq 'scv 24 'reaper 1 'hellion 2)
      #:open-facility-slots (hasheq 'townhall 2 'barracks 1 'factory 1))
     #:cheese-spec c-rfe))

  (check! (and (not (memq 'command-center (macro-brain-decision-scheduled-ids d-cyc)))
               (not (eq? (macro-brain-decision-saving-for d-cyc) 'command-center))
               (not (memq 'gateway (macro-brain-decision-scheduled-ids d-can)))
               (memq 'warp-prism (macro-brain-decision-scheduled-ids d-rob))
               (memq 'reaper (macro-brain-decision-scheduled-ids d-rep))
               (not (memq 'reaper (macro-brain-decision-scheduled-ids d-rfe))))
          (format "9e. Version C cheese guards failed: cyc=~s can=~s rob=~s rep=~s rfe=~s"
                  (macro-brain-decision-scheduled-ids d-cyc)
                  (macro-brain-decision-scheduled-ids d-can)
                  (macro-brain-decision-scheduled-ids d-rob)
                  (macro-brain-decision-scheduled-ids d-rep)
                  (macro-brain-decision-scheduled-ids d-rfe))))

;; =============================================================================
;; Section 10: Loop 87F Track 3 - Disjoint TownHall Worker Slot Decoupling
;; =============================================================================

;; 10a: Protoss with idle Nexus (`open-townhall > 0`, `workers < worker-cap-now`)
;; saving for combat (`immortal`/`stalker`) or scaling (`gateway`/`robotics-bay`)
;; STILL schedules 50M `probe` (even at 41w on 2b during skirmish or 58w on 3b!),
;; while preserving `reserved-min-floor` so lower-priority combat (`zealot`) stays blocked!
(let ()
  (reset-macro-escrow-tracker!)
  (define p-2b-skirmish-immortal
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 7200
      #:minerals 110 #:gas 100 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
      #:workers 41 #:active-bases 2 #:mineral-harvesters 31 #:gas-harvesters 10
      #:army-supply 18 #:enemy-threat-supply 18 #:under-attack? #t
      #:researched-upgrades '(warp-gate-research)
      #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'warp-gate 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 4)
      #:total-building-counts (hasheq 'nexus 2 'pylon 9 'warp-gate 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 4)
      #:unit-counts (hasheq 'probe 41 'stalker 7 'zealot 2 'observer 1)
      #:enemy-unit-counts (hasheq 'marine 10 'marauder 4)
      #:open-facility-slots (hasheq 'townhall 1 'warp-gate 2 'robotics-facility 1))))

  (reset-macro-escrow-tracker!)
  (define p-3b-58w-escrow
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 10400
      #:minerals 110 #:gas 120 #:supply-used 108 #:supply-cap 142 #:supply-left 34 #:pending-supply 0
      #:workers 58 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 14
      #:army-supply 44 #:enemy-threat-supply 12 #:under-attack? #f
      #:researched-upgrades '(warp-gate-research charge)
      #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'warp-gate 6 'cybernetics-core 1
                                      'twilight-council 1 'robotics-facility 1 'assimilator 6)
      #:total-building-counts (hasheq 'nexus 3 'pylon 14 'warp-gate 6 'cybernetics-core 1
                                      'twilight-council 1 'robotics-facility 1 'assimilator 6)
      #:unit-counts (hasheq 'probe 58 'stalker 10 'zealot 6 'immortal 3 'observer 1)
      #:enemy-unit-counts (hasheq 'roach 6)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 3 'robotics-facility 1))))

  (check! (and (memq (macro-brain-decision-saving-for p-2b-skirmish-immortal)
                     '(immortal stalker robotics-bay))
               (>= (macro-brain-decision-reserved-min-floor p-2b-skirmish-immortal) 125)
               (not (memq 'zealot (macro-brain-decision-scheduled-ids p-2b-skirmish-immortal)))
               (not (not (memq 'probe (macro-brain-decision-scheduled-ids p-2b-skirmish-immortal)))))
          (format "10a(1). Protoss 2b skirmish (41w, 110M/100G) must schedule probe on idle Nexus while keeping combat escrow; sav=~a floor=~a sched=~s"
                  (macro-brain-decision-saving-for p-2b-skirmish-immortal)
                  (macro-brain-decision-reserved-min-floor p-2b-skirmish-immortal)
                  (macro-brain-decision-scheduled-ids p-2b-skirmish-immortal)))

  (check! (and (not (eq? (macro-brain-decision-saving-for p-3b-58w-escrow) 'none))
               (>= (macro-brain-decision-reserved-min-floor p-3b-58w-escrow) 125)
               (not (memq 'zealot (macro-brain-decision-scheduled-ids p-3b-58w-escrow)))
               (not (not (memq 'probe (macro-brain-decision-scheduled-ids p-3b-58w-escrow)))))
          (format "10a(2). Protoss 3b (58w < 66, 110M/120G) must not stall probes past 54 under non-exp escrow; sav=~a floor=~a sched=~s"
                  (macro-brain-decision-saving-for p-3b-58w-escrow)
                  (macro-brain-decision-reserved-min-floor p-3b-58w-escrow)
                  (macro-brain-decision-scheduled-ids p-3b-58w-escrow))))

;; 10b: Terran with idle CC (`open-townhall > 0`, `workers < worker-cap-now`)
;; saving for Tank #3+ (`150M/125G`) or Barracks/Starport #2+ STILL schedules 50M `scv`
;; (even at 40w during skirmish or 54w on 3b!), while keeping non-worker escrow intact!
(let ()
  (reset-macro-escrow-tracker!)
  (define t-2b-skirmish-tank3
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Terran #:frame 7800
      #:minerals 110 #:gas 130 #:supply-used 72 #:supply-cap 94 #:supply-left 22 #:pending-supply 0
      #:workers 40 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 10
      #:army-supply 26 #:enemy-threat-supply 24 #:under-attack? #t
      #:researched-upgrades '(stimpack)
      #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 9 'barracks 3
                                      'barracks-techlab 1 'barracks-reactor 1
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 4)
      #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 9 'barracks 3
                                      'barracks-techlab 1 'barracks-reactor 1
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 4)
      #:unit-counts (hasheq 'scv 40 'marine 14 'siege-tank 2 'medivac 2)
      #:enemy-unit-counts (hasheq 'marine 12 'siege-tank 3)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 2 'factory 1 'starport 1))))

  (reset-macro-escrow-tracker!)
  (define t-3b-54w-escrow
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Zerg #:frame 10200
      #:minerals 110 #:gas 130 #:supply-used 106 #:supply-cap 134 #:supply-left 28 #:pending-supply 0
      #:workers 54 #:active-bases 3 #:mineral-harvesters 42 #:gas-harvesters 12
      #:army-supply 44 #:enemy-threat-supply 10 #:under-attack? #f
      #:researched-upgrades '(stimpack combat-shield)
      #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 13 'barracks 5
                                      'barracks-techlab 2 'barracks-reactor 2
                                      'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1
                                      'engineering-bay 1 'refinery 5)
      #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 13 'barracks 5
                                      'barracks-techlab 2 'barracks-reactor 2
                                      'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1
                                      'engineering-bay 1 'refinery 5)
      #:unit-counts (hasheq 'scv 54 'marine 24 'marauder 4 'siege-tank 3 'medivac 3)
      #:enemy-unit-counts (hasheq 'roach 5)
      #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1))))

  (check! (and (eq? (macro-brain-decision-saving-for t-2b-skirmish-tank3) 'siege-tank)
               (>= (macro-brain-decision-reserved-min-floor t-2b-skirmish-tank3) 150)
               (not (not (memq 'scv (macro-brain-decision-scheduled-ids t-2b-skirmish-tank3)))))
          (format "10b(1). Terran 2b skirmish (40w, 2 Tanks -> Tank#3@150M) must schedule scv on idle CC; sav=~a floor=~a sched=~s"
                  (macro-brain-decision-saving-for t-2b-skirmish-tank3)
                  (macro-brain-decision-reserved-min-floor t-2b-skirmish-tank3)
                  (macro-brain-decision-scheduled-ids t-2b-skirmish-tank3)))

  (check! (and (not (eq? (macro-brain-decision-saving-for t-3b-54w-escrow) 'none))
               (not (eq? (macro-brain-decision-saving-for t-3b-54w-escrow) 'command-center))
               (>= (macro-brain-decision-reserved-min-floor t-3b-54w-escrow) 100)
               (not (not (memq 'scv (macro-brain-decision-scheduled-ids t-3b-54w-escrow)))))
          (format "10b(2). Terran 3b (54w < 66, 110M/130G) must not stall scvs past 48 under non-exp escrow; sav=~a floor=~a sched=~s"
                  (macro-brain-decision-saving-for t-3b-54w-escrow)
                  (macro-brain-decision-reserved-min-floor t-3b-54w-escrow)
                  (macro-brain-decision-scheduled-ids t-3b-54w-escrow))))

;; 10c: Negative safety guards - supply preempt, zero-army rush survival, Version C worker cap,
;;      and Zerg Larva-sharing combat/tech escrow MUST still block workers!
(let ()
  ;; (i) Supply preempt at 80M, supply-left=0 -> Pylon escrows & blocks Probe!
  (reset-macro-escrow-tracker!)
  (define p-supply-guard
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 5400
      #:minerals 80 #:gas 60 #:supply-used 54 #:supply-cap 54 #:supply-left 0 #:pending-supply 0
      #:workers 34 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 6
      #:army-supply 18 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 4 'cybernetics-core 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 4 'cybernetics-core 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 34 'stalker 7 'zealot 2)
      #:open-facility-slots (hasheq 'townhall 2 'gateway 2))))

  ;; (ii) Zero-army rush survival (`under-attack?=#t`, `army-supply=0`, `threat=6`, 80M) -> Zealot/Stalker blocks Probe!
  (reset-macro-escrow-tracker!)
  (define p-zero-army-guard
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 3200
      #:minerals 80 #:gas 0 #:supply-used 18 #:supply-cap 31 #:supply-left 13 #:pending-supply 0
      #:workers 18 #:active-bases 1 #:mineral-harvesters 18 #:gas-harvesters 0
      #:army-supply 0 #:enemy-threat-supply 6 #:under-attack? #t
      #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
      #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
      #:unit-counts (hasheq 'probe 18)
      #:enemy-unit-counts (hasheq 'zergling 8)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))

  ;; (iii) Version C cheese worker cap (`workers=19 >= cap=19`) -> SCV stays capped!
  (reset-macro-escrow-tracker!)
  (define c-rep (lookup-cheese-build-spec 'tvt-proxy-2rax-reaper))
  (define t-cheese-cap-guard
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Terran #:frame 3500
      #:minerals 110 #:gas 80 #:supply-used 24 #:supply-cap 39 #:supply-left 15 #:pending-supply 0
      #:workers 19 #:active-bases 1 #:mineral-harvesters 13 #:gas-harvesters 6
      #:army-supply 5 #:enemy-threat-supply 2 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 2 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 2 'refinery 2)
      #:unit-counts (hasheq 'scv 19 'reaper 3)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 2))
     #:cheese-spec c-rep))

  ;; (iv) Zerg Larva-sharing untouched: Lair/Hydra/Roach escrow at 80M/100G still blocks Drone!
  (reset-macro-escrow-tracker!)
  (define z-larva-untouched
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 5400
      #:minerals 90 #:gas 100 #:supply-used 48 #:supply-cap 74 #:supply-left 26 #:pending-supply 0
      #:workers 34 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 6
      #:army-supply 10 #:enemy-threat-supply 12 #:under-attack? #t
      #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'lair 1 'hydralisk-den 1 'extractor 2)
      #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'lair 1 'hydralisk-den 1 'extractor 2)
      #:unit-counts (hasheq 'drone 34 'queen 3 'roach 3 'zergling 4)
      #:enemy-unit-counts (hasheq 'marine 10 'medivac 1)
      #:open-facility-slots (hasheq 'townhall 2 'larva 3))))

  (check! (and (eq? (macro-brain-decision-saving-for p-supply-guard) 'pylon)
               (not (memq 'probe (macro-brain-decision-scheduled-ids p-supply-guard)))
               (not (memq 'probe (macro-brain-decision-scheduled-ids p-zero-army-guard)))
               (not (memq 'scv (macro-brain-decision-scheduled-ids t-cheese-cap-guard)))
               (not (memq 'drone (macro-brain-decision-scheduled-ids z-larva-untouched))))
          (format "10c. Safety guards failed: sup=~a/~s zero=~a/~s cheese=~s zerg=~a/~s"
                  (macro-brain-decision-saving-for p-supply-guard)
                  (macro-brain-decision-scheduled-ids p-supply-guard)
                  (macro-brain-decision-saving-for p-zero-army-guard)
                  (macro-brain-decision-scheduled-ids p-zero-army-guard)
                  (macro-brain-decision-scheduled-ids t-cheese-cap-guard)
                  (macro-brain-decision-saving-for z-larva-untouched)
                  (macro-brain-decision-scheduled-ids z-larva-untouched))))

;; =============================================================================
;; Section 11: Loop 87G Track 3 - Non-Cloak Bio+Tank+Raven Overseer Escrow Guard
;; =============================================================================
(let ()
  ;; 11a: ZvT past 6:00 against Terran Bio+Tank+Raven with lone StarportTechLab & sticky
  ;;      requires-detection?=#t (0 Banshees/Ghosts/WidowMines) must NEVER slam overseer@1240
  ;;      or deadlock bank at 103M/25G!
  (reset-macro-escrow-tracker!)
  (define z-bio-tank-raven-no-ov-lock
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 11264
      #:minerals 103 #:gas 25 #:supply-used 72 #:supply-cap 90 #:supply-left 18 #:pending-supply 0
      #:workers 38 #:active-bases 3 #:mineral-harvesters 28 #:gas-harvesters 10
      #:army-supply 30 #:enemy-threat-supply 28 #:under-attack? #t
      #:requires-anti-air? #t #:requires-detection? #t
      #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1
                                      'hydralisk-den 1 'extractor 4 'spore-crawler 3)
      #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1
                                      'hydralisk-den 1 'extractor 4 'spore-crawler 3)
      #:unit-counts (hasheq 'drone 38 'queen 4 'roach 8 'hydralisk 4 'zergling 6 'overlord 10)
      #:enemy-unit-counts (hasheq 'marine 10 'marauder 5 'medivac 3 'siege-tank 5 'raven 1)
      #:enemy-building-counts (hasheq 'barracks 4 'factory 1 'starport 1 'starport-techlab 1)
      #:open-facility-slots (hasheq 'larva 5 'townhall 3)
      #:mirror-signals (hasheq 'rush-prob 0.05 'mirror-requires-detection? #t))))

  ;; 11b: Early lone StarportTechLab (<= 6:00, 0 Banshees, 0 Ravens) when Zerg ALREADY has 1 Overseer
  ;;      must NOT slam speculative overseer #2 @ 1030.0 blocking combat/drones at 48M/33G!
  (reset-macro-escrow-tracker!)
  (define z-early-sptl-ov1-no-ov2-lock
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 6720
      #:minerals 48 #:gas 33 #:supply-used 52 #:supply-cap 68 #:supply-left 16 #:pending-supply 0
      #:workers 32 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 6
      #:army-supply 18 #:enemy-threat-supply 12 #:under-attack? #f
      #:requires-anti-air? #t #:requires-detection? #t
      #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                      'extractor 2 'spore-crawler 2)
      #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                      'extractor 2 'spore-crawler 2)
      #:unit-counts (hasheq 'drone 32 'queen 4 'roach 7 'overlord 7 'overseer 1)
      #:enemy-unit-counts (hasheq 'marine 3 'marauder 2 'siege-tank 3)
      #:enemy-building-counts (hasheq 'barracks 3 'factory 1 'starport 1 'starport-techlab 1)
      #:open-facility-slots (hasheq 'larva 4 'townhall 2)
      #:mirror-signals (hasheq 'rush-prob 0.05 'mirror-requires-detection? #t))))

  ;; 11c: Positive safety guards:
  ;;   (i) Real confirmed Banshees (>= 1) past 6:00 with 0 Overseers STILL slams overseer@1240!
  ;;   (ii) Real confirmed Banshees with 0 plain Overlords (only overlord-transport) does NOT lock on overseer!
  (reset-macro-escrow-tracker!)
  (define z-real-banshee-still-1240
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 11264
      #:minerals 40 #:gas 40 #:supply-used 72 #:supply-cap 90 #:supply-left 18 #:pending-supply 0
      #:workers 38 #:active-bases 3 #:mineral-harvesters 28 #:gas-harvesters 10
      #:army-supply 30 #:enemy-threat-supply 20 #:under-attack? #t
      #:requires-anti-air? #t #:requires-detection? #t
      #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1
                                      'extractor 4 'spore-crawler 3)
      #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1
                                      'extractor 4 'spore-crawler 3)
      #:unit-counts (hasheq 'drone 38 'queen 6 'hydralisk 10 'overlord 8)
      #:enemy-unit-counts (hasheq 'marine 10 'banshee 2 'siege-tank 2)
      #:enemy-building-counts (hasheq 'barracks 3 'factory 1 'starport 1 'starport-techlab 1)
      #:open-facility-slots (hasheq 'larva 5 'townhall 3)
      #:mirror-signals (hasheq 'rush-prob 0.05 'mirror-requires-detection? #t))))

  (reset-macro-escrow-tracker!)
  (define z-no-plain-overlord-no-ov-lock
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:enemy-race 'Terran #:frame 11264
      #:minerals 110 #:gas 40 #:supply-used 72 #:supply-cap 90 #:supply-left 18 #:pending-supply 0
      #:workers 38 #:active-bases 3 #:mineral-harvesters 28 #:gas-harvesters 10
      #:army-supply 30 #:enemy-threat-supply 20 #:under-attack? #t
      #:requires-anti-air? #t #:requires-detection? #t
      #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1
                                      'extractor 4 'spore-crawler 3)
      #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1
                                      'extractor 4 'spore-crawler 3)
      #:unit-counts (hasheq 'drone 38 'queen 6 'hydralisk 10 'overlord-transport 4)
      #:enemy-unit-counts (hasheq 'marine 10 'banshee 2)
      #:enemy-building-counts (hasheq 'barracks 3 'starport 1 'starport-techlab 1)
      #:open-facility-slots (hasheq 'larva 5 'townhall 3)
      #:mirror-signals (hasheq 'rush-prob 0.05 'mirror-requires-detection? #t))))

  (check! (and (not (eq? (macro-brain-decision-saving-for z-bio-tank-raven-no-ov-lock) 'overseer))
               (not (cand-blk? z-bio-tank-raven-no-ov-lock 'overseer))
               (< (cand-u z-bio-tank-raven-no-ov-lock 'overseer) 800.0)
               (or (memq 'roach (macro-brain-decision-scheduled-ids z-bio-tank-raven-no-ov-lock))
                   (memq 'zergling (macro-brain-decision-scheduled-ids z-bio-tank-raven-no-ov-lock))))
          (format "11a. ZvT Bio+Tank+Raven (lone SPTL, 0 Banshees) must not deadlock on overseer@1240; sav=~a ov-u=~a blk=~a sched=~s"
                  (macro-brain-decision-saving-for z-bio-tank-raven-no-ov-lock)
                  (cand-u z-bio-tank-raven-no-ov-lock 'overseer)
                  (cand-blk? z-bio-tank-raven-no-ov-lock 'overseer)
                  (macro-brain-decision-scheduled-ids z-bio-tank-raven-no-ov-lock)))

  (check! (and (not (eq? (macro-brain-decision-saving-for z-early-sptl-ov1-no-ov2-lock) 'overseer))
               (not (cand-blk? z-early-sptl-ov1-no-ov2-lock 'overseer))
               (< (cand-u z-early-sptl-ov1-no-ov2-lock 'overseer) 800.0))
          (format "11b. Speculative lone SPTL with 1 Overseer alive must not escrow overseer#2@1030; sav=~a ov-u=~a blk=~a"
                  (macro-brain-decision-saving-for z-early-sptl-ov1-no-ov2-lock)
                  (cand-u z-early-sptl-ov1-no-ov2-lock 'overseer)
                  (cand-blk? z-early-sptl-ov1-no-ov2-lock 'overseer)))

  (check! (and (eq? (macro-brain-decision-saving-for z-real-banshee-still-1240) 'overseer)
               (>= (cand-u z-real-banshee-still-1240 'overseer) 1200.0)
               (not (eq? (macro-brain-decision-saving-for z-no-plain-overlord-no-ov-lock) 'overseer)))
          (format "11c. Confirmed Banshee guard failed: real-sav=~a/u=~a no-ov-sav=~a"
                  (macro-brain-decision-saving-for z-real-banshee-still-1240)
                  (cand-u z-real-banshee-still-1240 'overseer)
                  (macro-brain-decision-saving-for z-no-plain-overlord-no-ov-lock))))

(printf "l87-escrow-and-counters-test: ~a passed, ~a failed\n" pass-count fail-count)
(unless (= fail-count 0)
  (exit 1))
