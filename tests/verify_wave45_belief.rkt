#lang racket/base
(require racket/list
         "../lib/econ-ledger.rkt"
         "../lib/priority-macro-brain.rkt")

(define passed 0)
(define failed 0)
(define (check! cond msg)
  (if cond
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (printf "FAIL: ~a\n" msg))))

(define (cand-u dec sym)
  (hash-ref (hash-ref (priority-schedule-result-category-utilities
                       (macro-brain-decision-priority-schedule dec))
                      'candidate-utilities (hasheq))
            sym 0.0))

;; ============================================================================
;; 1. L45-P0-2a: #04 PvT (3+ Base GW #6-8 + Nexus <= 4 Cap), #03 PvP Natural
;;               Through Opening Scout, & 1BaseLock 4 -> 0 (Pause Unit Drips)
;; ============================================================================

;; (1) #04 PvT: On >= 3 bases with RoboticsBay & Colossus < 2 (and 4 bases @ 7 GW),
;;     protoss-gw-core-tech-hold-active? MUST NOT block Gateways #6-#8 at >= 150M!
(reset-macro-escrow-tracker!)
(define p-04-3b-gw6-unlocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7800
    #:minerals 180 #:gas 90 #:supply-used 84 #:supply-cap 118 #:workers 46 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 10
    #:army-supply 38 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 13 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 13 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:unit-counts (hasheq 'probe 46 'stalker 12 'immortal 2 'colossus 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 1 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-04-4b-gw8-unlocked
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10400
    #:minerals 180 #:gas 80 #:supply-used 112 #:supply-cap 150 #:workers 62 #:active-bases 4
    #:mineral-harvesters 48 #:gas-harvesters 14
    #:army-supply 50 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 4 'pylon 18 'gateway 7 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 7)
    #:total-building-counts (hasheq 'nexus 4 'pylon 18 'gateway 7 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 7)
    #:unit-counts (hasheq 'probe 62 'stalker 18 'immortal 2 'colossus 1)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 1 'robotics-facility 1))))
(check! (and (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-04-3b-gw6-unlocked))))
             (>= (cand-u p-04-3b-gw6-unlocked 'gateway) 535.0)
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-04-4b-gw8-unlocked))))
             (>= (cand-u p-04-4b-gw8-unlocked 'gateway) 535.0))
        (format "L45-P0-2a(1) #04 PvT >=3b MUST unlock GW#6-#8 @180M even w/ Colossus<2: 3b=~s(u=~a) 4b=~s(u=~a)"
                (macro-brain-decision-scheduled-ids p-04-3b-gw6-unlocked) (cand-u p-04-3b-gw6-unlocked 'gateway)
                (macro-brain-decision-scheduled-ids p-04-4b-gw8-unlocked) (cand-u p-04-4b-gw8-unlocked 'gateway)))

;; (2) Negative Guard: 2-base Protoss w/ RoboticsBay & Colossus < 2 STILL holds Gateway #5+ (<400M)!
(reset-macro-escrow-tracker!)
(define p-04-2b-still-holds-gw5
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7100
    #:minerals 310 #:gas 160 #:supply-used 72 #:supply-cap 102 #:workers 38 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 8
    #:army-supply 34 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 38 'stalker 10 'immortal 2 'colossus 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 0))))
(check! (and (not (memq 'gateway (macro-brain-decision-scheduled-ids p-04-2b-still-holds-gw5)))
             (<= (cand-u p-04-2b-still-holds-gw5 'gateway) 440.0))
        (format "L45-P0-2a(2) 2b RoboBay/<2 Colossi MUST still hold GW#5+: sched=~s u=~a"
                (macro-brain-decision-scheduled-ids p-04-2b-still-holds-gw5)
                (cand-u p-04-2b-still-holds-gw5 'gateway)))

;; (3) #04 PvT Nexus <= 4 Cap: Block Nexus #5 while GW < 8 OR army < 75; unlock once GW >= 8 & army >= 75!
(reset-macro-escrow-tracker!)
(define p-04-cap-nex5-low-gw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 12000
    #:minerals 650 #:gas 200 #:supply-used 144 #:supply-cap 174 #:workers 64 #:active-bases 4
    #:mineral-harvesters 50 #:gas-harvesters 14
    #:army-supply 80 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 4 'pylon 22 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'forge 1 'assimilator 8)
    #:total-building-counts (hasheq 'nexus 4 'pylon 22 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'forge 1 'assimilator 8)
    #:unit-counts (hasheq 'probe 64 'stalker 24 'immortal 4 'colossus 3)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 0 'robotics-facility 0))))
(reset-macro-escrow-tracker!)
(define p-04-cap-nex5-low-army
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 12000
    #:minerals 650 #:gas 200 #:supply-used 116 #:supply-cap 160 #:workers 64 #:active-bases 4
    #:mineral-harvesters 50 #:gas-harvesters 14
    #:army-supply 52 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 4 'pylon 20 'gateway 8 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'forge 1 'assimilator 8)
    #:total-building-counts (hasheq 'nexus 4 'pylon 20 'gateway 8 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'forge 1 'assimilator 8)
    #:unit-counts (hasheq 'probe 64 'stalker 18 'immortal 2 'colossus 2)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 0 'robotics-facility 0))))
(reset-macro-escrow-tracker!)
(define p-04-allow-nex5-ready
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 13500
    #:minerals 900 #:gas 200 #:supply-used 148 #:supply-cap 186 #:workers 66 #:active-bases 4
    #:mineral-harvesters 52 #:gas-harvesters 14
    #:army-supply 82 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 4 'pylon 24 'gateway 8 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'forge 1 'assimilator 8)
    #:total-building-counts (hasheq 'nexus 4 'pylon 24 'gateway 8 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'forge 1 'assimilator 8)
    #:unit-counts (hasheq 'probe 66 'stalker 24 'immortal 4 'colossus 3)
    #:open-facility-slots (hasheq 'townhall 4 'gateway 0 'robotics-facility 0))))
(check! (and (not (memq 'nexus (macro-brain-decision-scheduled-ids p-04-cap-nex5-low-gw)))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-04-cap-nex5-low-gw))))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-04-cap-nex5-low-army)))
             (not (not (memq 'nexus (macro-brain-decision-scheduled-ids p-04-allow-nex5-ready)))))
        (format "L45-P0-2a(3) Protoss Nexus<=4 while GW<8 or army<75, unlocks at 8GW+82army: lgw=~s larm=~s ok=~s"
                (macro-brain-decision-scheduled-ids p-04-cap-nex5-low-gw)
                (macro-brain-decision-scheduled-ids p-04-cap-nex5-low-army)
                (macro-brain-decision-scheduled-ids p-04-allow-nex5-ready)))

;; (4) #03 PvP Natural Nexus: Single opening Stalker/Adept scout (enemy-threat-supply=2.0, forge=0, not under-attack)
;;     MUST NOT delay Natural Nexus #2!
(reset-macro-escrow-tracker!)
(define p-03-pvp-nat-through-scout
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 2900
    #:minerals 290 #:gas 100 #:supply-used 28 #:supply-cap 39 #:workers 21 #:active-bases 1
    #:mineral-harvesters 15 #:gas-harvesters 6
    #:army-supply 4 #:enemy-threat-supply 2.0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 21 'stalker 2)
    #:enemy-unit-counts (hasheq 'stalker 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2))))
(check! (and (eq? (macro-brain-decision-saving-for p-03-pvp-nat-through-scout) 'nexus)
             (>= (cand-u p-03-pvp-nat-through-scout 'nexus) 620.0))
        (format "L45-P0-2a(4) #03 PvP opening scout (threat=2.0, forge=0) MUST NOT delay Nat Nexus: save=~a u=~a sched=~s"
                (macro-brain-decision-saving-for p-03-pvp-nat-through-scout)
                (cand-u p-03-pvp-nat-through-scout 'nexus)
                (macro-brain-decision-scheduled-ids p-03-pvp-nat-through-scout)))

;; (5) #03 PvP Negative Guard: Proxy Forge (threat=4) & Proxy Zealot (zealot=1) MUST STILL block Nat Nexus!
(reset-macro-escrow-tracker!)
(define p-03-pvp-proxy-forge-blocks
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 3800
    #:minerals 280 #:gas 140 #:supply-used 28 #:supply-cap 39 #:workers 22 #:active-bases 1
    #:mineral-harvesters 19 #:gas-harvesters 3
    #:army-supply 6 #:enemy-threat-supply 4 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 22 'stalker 3)
    #:enemy-building-counts (hasheq 'forge 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(reset-macro-escrow-tracker!)
(define p-03-pvp-proxy-zealot-blocks
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 2700
    #:minerals 290 #:gas 100 #:supply-used 26 #:supply-cap 39 #:workers 20 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 6
    #:army-supply 4 #:enemy-threat-supply 2.0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 20 'stalker 2)
    #:enemy-unit-counts (hasheq 'zealot 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2))))
(check! (and (not (eq? (macro-brain-decision-saving-for p-03-pvp-proxy-forge-blocks) 'nexus))
             (not (eq? (macro-brain-decision-saving-for p-03-pvp-proxy-zealot-blocks) 'nexus)))
        (format "L45-P0-2a(5) Proxy Forge & Proxy Zealot MUST still block PvP Nat Nexus: forge=~a zealot=~a"
                (macro-brain-decision-saving-for p-03-pvp-proxy-forge-blocks)
                (macro-brain-decision-saving-for p-03-pvp-proxy-zealot-blocks)))

;; (6) 1BaseLock 4 -> 0 (#38/#59/#62/#68): Under late-1base-commit-expand-due? (f>=6048, w>=20, army>=16, <400M),
;;     pause marine/scv/zealot/stalker/probe drips until 400M natural CC/Nexus schedules; keep marine active when army<16!
(reset-macro-escrow-tracker!)
(define t-1baselock-pause-marine-scv
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 6500
    #:minerals 110 #:gas 80 #:supply-used 40 #:supply-cap 54 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 18 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 5 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'refinery 2)
    #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 5 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'refinery 2)
    #:unit-counts (hasheq 'scv 22 'marine 12 'marauder 3)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 2 'factory 1))))
(reset-macro-escrow-tracker!)
(define p-1baselock-pause-units
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 6500
    #:minerals 140 #:gas 60 #:supply-used 40 #:supply-cap 55 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 18 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 5 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 5 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 7 'immortal 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 3 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define t-1baselock-low-army-keeps-marine
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 6500
    #:minerals 110 #:gas 20 #:supply-used 30 #:supply-cap 46 #:workers 22 #:active-bases 1
    #:mineral-harvesters 18 #:gas-harvesters 4
    #:army-supply 8 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 2 'refinery 1)
    #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 2 'refinery 1)
    #:unit-counts (hasheq 'scv 22 'marine 8)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 2))))
(check! (and (eq? (macro-brain-decision-saving-for t-1baselock-pause-marine-scv) 'command-center)
             (not (memq 'marine (macro-brain-decision-scheduled-ids t-1baselock-pause-marine-scv)))
             (not (memq 'scv (macro-brain-decision-scheduled-ids t-1baselock-pause-marine-scv)))
             (eq? (macro-brain-decision-saving-for p-1baselock-pause-units) 'nexus)
             (not (memq 'stalker (macro-brain-decision-scheduled-ids p-1baselock-pause-units)))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-1baselock-pause-units)))
             (not (memq 'probe (macro-brain-decision-scheduled-ids p-1baselock-pause-units)))
             (eq? (macro-brain-decision-saving-for t-1baselock-low-army-keeps-marine) 'command-center))
        (format "L45-P0-2a(6) 1BaseLock MUST pause marine/scv/zealot/stalker/probe @w>=20,a>=16 until 400M CC/Nexus: t=~s(s=~a) p=~s(s=~a) low=~s(s=~a)"
                (macro-brain-decision-scheduled-ids t-1baselock-pause-marine-scv)
                (macro-brain-decision-saving-for t-1baselock-pause-marine-scv)
                (macro-brain-decision-scheduled-ids p-1baselock-pause-units)
                (macro-brain-decision-saving-for p-1baselock-pause-units)
                (macro-brain-decision-scheduled-ids t-1baselock-low-army-keeps-marine)
                (macro-brain-decision-saving-for t-1baselock-low-army-keeps-marine)))

;; ============================================================================
;; 2. L45-P0-2b: #72 12PoolBot (<85s Pool / <115s >=2 Lings), #75 who Hard-Block
;;               (Archon/DarkShrine/TemplarArchive/Gas#3), & Live #5138613 ZvT Corruptor<=12
;; ============================================================================

;; (7) #72 12PoolBot: Completed Pool < 85s (`f=1850`) MUST block 400M Nexus #2 even with 0 Lings seen yet!
(reset-macro-escrow-tracker!)
(define p-72-pool-82s-blocks-nex2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 1850
    #:minerals 410 #:gas 0 #:supply-used 18 #:supply-cap 23 #:workers 18 #:active-bases 1
    #:mineral-harvesters 18 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 18)
    #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 2)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(check! (and (not (memq 'nexus (macro-brain-decision-scheduled-ids p-72-pool-82s-blocks-nex2)))
             (not (eq? (macro-brain-decision-saving-for p-72-pool-82s-blocks-nex2) 'nexus))
             (not (not (memq 'zealot (macro-brain-decision-scheduled-ids p-72-pool-82s-blocks-nex2))))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-72-pool-82s-blocks-nex2)))))
        (format "L45-P0-2b(7) #72 12Pool <85s Pool (0 Lings yet) MUST block Nexus#2 for Zealot+GW#2: sched=~s save=~a"
                (macro-brain-decision-scheduled-ids p-72-pool-82s-blocks-nex2)
                (macro-brain-decision-saving-for p-72-pool-82s-blocks-nex2)))

;; (8) #72 12PoolBot: >= 2 Lings < 115s (`f=2400`) on <= 1 Hatch MUST block 400M Nexus #2!
(reset-macro-escrow-tracker!)
(define p-72-2lings-107s-blocks-nex2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 2400
    #:minerals 410 #:gas 0 #:supply-used 19 #:supply-cap 23 #:workers 19 #:active-bases 1
    #:mineral-harvesters 19 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 1 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 19)
    #:enemy-unit-counts (hasheq 'zergling 2)
    #:enemy-building-counts (hasheq 'hatchery 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(check! (and (not (memq 'nexus (macro-brain-decision-scheduled-ids p-72-2lings-107s-blocks-nex2)))
             (not (eq? (macro-brain-decision-saving-for p-72-2lings-107s-blocks-nex2) 'nexus))
             (not (not (memq 'zealot (macro-brain-decision-scheduled-ids p-72-2lings-107s-blocks-nex2))))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-72-2lings-107s-blocks-nex2)))))
        (format "L45-P0-2b(8) #72 >=2 Lings <115s on 1 Hatch MUST block Nexus#2 for Zealot+GW#2: sched=~s save=~a"
                (macro-brain-decision-scheduled-ids p-72-2lings-107s-blocks-nex2)
                (macro-brain-decision-saving-for p-72-2lings-107s-blocks-nex2)))

;; (9) #75 who (Sole CloakLoss): Hard-block dark-shrine, templar-archive, archon, high-templar, dark-templar,
;;     and assimilator #3 while confirmed Banshee / <=6m StarportTL & Stalker < 10!
(reset-macro-escrow-tracker!)
(define p-75-hard-block-archon-ds-gas3
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 5900
    #:minerals 450 #:gas 300 #:supply-used 52 #:supply-cap 78 #:workers 32 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 20 #:enemy-threat-supply 8 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 2 'cybernetics-core 1
                                    'twilight-council 1 'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 2 'cybernetics-core 1
                                    'twilight-council 1 'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 32 'stalker 3 'high-templar 2 'observer 1)
    #:enemy-unit-counts (hasheq 'banshee 3)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 1))))
(check! (and (not (memq 'archon (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3)))
             (not (memq 'dark-shrine (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3)))
             (not (memq 'templar-archive (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3)))
             (not (memq 'high-templar (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3)))
             (not (memq 'assimilator (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3)))
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3))))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3)))))
        (format "L45-P0-2b(9) #75 Banshees (Stalker<10) MUST hard-block Archon/DarkShrine/TemplarArchive/Gas#3 & build Stalker+GW#3: sched=~s"
                (macro-brain-decision-scheduled-ids p-75-hard-block-archon-ds-gas3)))

;; (10) #75 Negative Guard: Once Stalker >= 10, Assimilator #3 / Archon hard-block releases cleanly!
(reset-macro-escrow-tracker!)
(define p-75-unlocks-at-10-stalkers
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7200
    #:minerals 450 #:gas 300 #:supply-used 74 #:supply-cap 102 #:workers 38 #:active-bases 2
    #:mineral-harvesters 32 #:gas-harvesters 6
    #:army-supply 36 #:enemy-threat-supply 6 #:under-attack? #f #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'twilight-council 1 'templar-archive 1 'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'twilight-council 1 'templar-archive 1 'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 38 'stalker 10 'high-templar 2 'observer 1)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 0))))
(check! (or (not (not (memq 'archon (macro-brain-decision-scheduled-ids p-75-unlocks-at-10-stalkers))))
            (not (not (memq 'assimilator (macro-brain-decision-scheduled-ids p-75-unlocks-at-10-stalkers)))))
        (format "L45-P0-2b(10) #75 hard-block MUST release once Stalker>=10 (Archon or Assim#3 eligible): sched=~s"
                (macro-brain-decision-scheduled-ids p-75-unlocks-at-10-stalkers)))

;; (11) Live Prod #5138613 (ZvT vs 92 Vikings / 0 BCs): Hard-cap ZvT Corruptors at <= 12!
(reset-macro-escrow-tracker!)
(define z-zvt-viking-corruptor-cap12
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 130 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 68 #:enemy-threat-supply 60 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'corruptor 12 'hydralisk 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'viking-fighter 30 'marine 12 'siege-tank 4)
    #:enemy-building-counts (hasheq 'starport 4 'starport-reactor 4)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(check! (and (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvt-viking-corruptor-cap12)))
             (not (eq? (macro-brain-decision-saving-for z-zvt-viking-corruptor-cap12) 'corruptor))
             (not (not (memq 'hydralisk (macro-brain-decision-scheduled-ids z-zvt-viking-corruptor-cap12)))))
        (format "L45-P0-2b(11) #5138613 ZvT vs Vikings/0 BCs MUST hard-cap Corruptors<=12 & train Hydra: sched=~s save=~a"
                (macro-brain-decision-scheduled-ids z-zvt-viking-corruptor-cap12)
                (macro-brain-decision-saving-for z-zvt-viking-corruptor-cap12)))

;; (12) #5138613 Negative Guards: ZvT unlocks >12 Corruptors vs >=2 BCs OR >=4 Liberators,
;;      AND ZvP STILL scales >12 Corruptors vs Tempests!
(reset-macro-escrow-tracker!)
(define z-zvt-bc-unlocks-13plus
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 130 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 68 #:enemy-threat-supply 60 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'corruptor 12 'hydralisk 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'battlecruiser 4 'viking-fighter 8)
    #:enemy-building-counts (hasheq 'starport 3 'fusion-core 1)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(reset-macro-escrow-tracker!)
(define z-zvt-lib-unlocks-13plus
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 130 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 68 #:enemy-threat-supply 50 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'corruptor 12 'hydralisk 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'liberator 6 'viking-fighter 8)
    #:enemy-building-counts (hasheq 'starport 3)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(reset-macro-escrow-tracker!)
(define z-zvp-tempest-still-13plus
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 130 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 68 #:enemy-threat-supply 60 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'corruptor 12 'hydralisk 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'tempest 12)
    #:enemy-building-counts (hasheq 'stargate 3 'fleet-beacon 1)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(check! (and (not (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvt-bc-unlocks-13plus))))
             (not (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvt-lib-unlocks-13plus))))
             (not (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvp-tempest-still-13plus)))))
        (format "L45-P0-2b(12) Corruptor >12 MUST stay unlocked vs >=2 BC, >=4 Lib, and ZvP Tempests: bc=~s lib=~s zvp=~s"
                (macro-brain-decision-scheduled-ids z-zvt-bc-unlocks-13plus)
                (macro-brain-decision-scheduled-ids z-zvt-lib-unlocks-13plus)
                (macro-brain-decision-scheduled-ids z-zvp-tempest-still-13plus)))

(printf "verify_wave45_belief: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
