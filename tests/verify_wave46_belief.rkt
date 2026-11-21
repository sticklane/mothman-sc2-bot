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
;; 1. L46-P0-2a: Fix 0-Colossus Bug (#04 PvT / #05 PvZ / #82 / #83) &
;;               PvPNatDelay (#12 / #51 Gateway #3 & PhotonCannon #2+)
;; ============================================================================

;; (1) H2H #04 PvT 0-Colossus bug: Ready RoboticsBay + 0 Colossi @ 240M/260G (>=250G!):
;;     MUST escrow Colossus #1 & hard-block Disruptor, WarpPrism, Observer #2+, and Gateway #5+ (<450M)!
(reset-macro-escrow-tracker!)
(define p-04-0colossus-block-disruptor-wp-obs-gw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 240 #:gas 260 #:supply-used 90 #:supply-cap 130 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 42 #:enemy-threat-supply 18 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'twilight-council 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 14 'immortal 3 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 20 'marauder 6 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-04-0colossus-block-disruptor-wp-obs-gw) 'colossus)
             (>= (cand-u p-04-0colossus-block-disruptor-wp-obs-gw 'colossus) 655.0)
             (not (memq 'disruptor (macro-brain-decision-scheduled-ids p-04-0colossus-block-disruptor-wp-obs-gw)))
             (not (memq 'warp-prism (macro-brain-decision-scheduled-ids p-04-0colossus-block-disruptor-wp-obs-gw)))
             (not (memq 'observer (macro-brain-decision-scheduled-ids p-04-0colossus-block-disruptor-wp-obs-gw)))
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-04-0colossus-block-disruptor-wp-obs-gw))))
        (format "L46-P0-2a(1) #04 PvT 0-Colossus @240M/260G MUST escrow Colossus over Disruptor/WarpPrism/Obs/GW#6: save=~a u=~a sched=~s"
                (macro-brain-decision-saving-for p-04-0colossus-block-disruptor-wp-obs-gw)
                (cand-u p-04-0colossus-block-disruptor-wp-obs-gw 'colossus)
                (macro-brain-decision-scheduled-ids p-04-0colossus-block-disruptor-wp-obs-gw)))

;; (2) #05 PvZ / #83 PvZ 0-Colossus bug: Even if eff-req-aa?=#t with 0 real combat air,
;;     MUST train Colossus #1 (u>=655) and block Disruptor/WarpPrism!
(reset-macro-escrow-tracker!)
(define p-05-pvz-0colossus-zero-air
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 8400
    #:minerals 340 #:gas 230 #:supply-used 92 #:supply-cap 130 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 12 'immortal 4 'observer 1)
    #:enemy-unit-counts (hasheq 'roach 12 'hydralisk 10 'zergling 16)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'robotics-facility 1))))
(check! (and (not (not (memq 'colossus (macro-brain-decision-scheduled-ids p-05-pvz-0colossus-zero-air))))
             (>= (cand-u p-05-pvz-0colossus-zero-air 'colossus) 655.0)
             (not (memq 'disruptor (macro-brain-decision-scheduled-ids p-05-pvz-0colossus-zero-air)))
             (not (memq 'warp-prism (macro-brain-decision-scheduled-ids p-05-pvz-0colossus-zero-air))))
        (format "L46-P0-2a(2) #05 PvZ zero-air MUST train Colossus>=655 over Disruptor/WarpPrism: sched=~s u=~a"
                (macro-brain-decision-scheduled-ids p-05-pvz-0colossus-zero-air)
                (cand-u p-05-pvz-0colossus-zero-air 'colossus)))

;; (3) Negative Guards: (a) Cloak threat w/ 0 Observers STILL allows Observer #1;
;;                      (b) Once Colossus >= 2, protoss-colossus-core2-gas-guard? releases!
(reset-macro-escrow-tracker!)
(define p-04-cloak-still-allows-obs1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 200 #:gas 150 #:supply-used 90 #:supply-cap 130 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 42 #:enemy-threat-supply 10 #:under-attack? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 14 'immortal 3)
    #:enemy-unit-counts (hasheq 'widow-mine-burrowed 3 'marine 12)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-04-2colossi-releases-gw6
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9400
    #:minerals 240 #:gas 260 #:supply-used 108 #:supply-cap 142 #:workers 50 #:active-bases 3
    #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 58 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 5 'cybernetics-core 1
                                    'twilight-council 1 'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 5 'cybernetics-core 1
                                    'twilight-council 1 'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 50 'stalker 16 'immortal 3 'colossus 2 'observer 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 0 'robotics-facility 0))))
(check! (and (not (not (memq 'observer (macro-brain-decision-scheduled-ids p-04-cloak-still-allows-obs1))))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-04-2colossi-releases-gw6)))))
        (format "L46-P0-2a(3) Cloak still allows Obs#1 & Colossus>=2 releases GW#6+: obs=~s gw=~s"
                (macro-brain-decision-scheduled-ids p-04-cloak-still-allows-obs1)
                (macro-brain-decision-scheduled-ids p-04-2colossi-releases-gw6)))

;; (4) #12/#51 PvPNatDelay <= 195s: Defer Gateway #3+ and PhotonCannon #2+ strictly behind Natural Nexus #2!
(reset-macro-escrow-tracker!)
(define p-12-pvp-nat-over-gw3-cannon2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 3500
    #:minerals 290 #:gas 100 #:supply-used 30 #:supply-cap 47 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 8 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'forge 1 'photon-cannon 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'forge 1 'photon-cannon 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 4)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(check! (and (eq? (macro-brain-decision-saving-for p-12-pvp-nat-over-gw3-cannon2) 'nexus)
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-12-pvp-nat-over-gw3-cannon2)))
             (not (memq 'photon-cannon (macro-brain-decision-scheduled-ids p-12-pvp-nat-over-gw3-cannon2))))
        (format "L46-P0-2a(4) #12/#51 PvP <195s MUST lock Nat Nexus over GW#3 & Cannon#2+: save=~a sched=~s"
                (macro-brain-decision-saving-for p-12-pvp-nat-over-gw3-cannon2)
                (macro-brain-decision-scheduled-ids p-12-pvp-nat-over-gw3-cannon2)))

;; (5) Negative Guard: Active DT invasion under attack STILL blocks Nat Nexus & allows emergency detection/defense!
(reset-macro-escrow-tracker!)
(define p-pvp-dt-attack-allows-cannon2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 3500
    #:minerals 290 #:gas 100 #:supply-used 30 #:supply-cap 47 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 8 #:enemy-threat-supply 6 #:under-attack? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'forge 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'forge 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 4)
    #:enemy-unit-counts (hasheq 'dark-templar 2)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(check! (and (not (eq? (macro-brain-decision-saving-for p-pvp-dt-attack-allows-cannon2) 'nexus))
             (not (not (memq 'photon-cannon (macro-brain-decision-scheduled-ids p-pvp-dt-attack-allows-cannon2)))))
        (format "L46-P0-2a(5) Active PvP DT attack MUST block Nat Nexus & allow emergency PhotonCannon: save=~a sched=~s"
                (macro-brain-decision-saving-for p-pvp-dt-attack-allows-cannon2)
                (macro-brain-decision-scheduled-ids p-pvp-dt-attack-allows-cannon2)))

;; ============================================================================
;; 2. L46-P0-2b: #62 3x EBay, #56 TvT0Tank Medivac#3+, #29/#65 2b Rax<=4,
;;               #73 ZvP DT Lair->Overseer+8 Roaches, Live #5138315 ZvP Corruptor<=12
;; ============================================================================

;; (6) #62 3x EBay Fix: Hard-cap Terran EngineeringBay <= 1 on <= 2 bases & <= 2 max ever!
(reset-macro-escrow-tracker!)
(define t-62-2b-ebay-cap1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 8200
    #:minerals 600 #:gas 250 #:supply-used 76 #:supply-cap 110 #:workers 42 #:active-bases 2
    #:mineral-harvesters 32 #:gas-harvesters 10
    #:army-supply 34 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 3 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 3 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 18 'siege-tank 4 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 0 'factory 0 'starport 0))))
(reset-macro-escrow-tracker!)
(define t-62-3b-ebay-cap2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 12000
    #:minerals 1200 #:gas 400 #:supply-used 118 #:supply-cap 158 #:workers 58 #:active-bases 3
    #:mineral-harvesters 44 #:gas-harvesters 14
    #:army-supply 60 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 16 'barracks 5 'factory 2 'factory-techlab 2
                                    'starport 1 'engineering-bay 2 'armory 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 16 'barracks 5 'factory 2 'factory-techlab 2
                                    'starport 1 'engineering-bay 2 'armory 1 'refinery 6)
    #:unit-counts (hasheq 'scv 58 'marine 28 'siege-tank 6 'medivac 4)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 0 'factory 0 'starport 0))))
(check! (and (not (memq 'engineering-bay (macro-brain-decision-scheduled-ids t-62-2b-ebay-cap1)))
             (not (memq 'engineering-bay (macro-brain-decision-scheduled-ids t-62-3b-ebay-cap2))))
        (format "L46-P0-2b(6) #62 MUST hard-cap EBay<=1 on <=2b & <=2 max ever: 2b=~s 3b=~s"
                (macro-brain-decision-scheduled-ids t-62-2b-ebay-cap1)
                (macro-brain-decision-scheduled-ids t-62-3b-ebay-cap2)))

;; (7) #56/#62 TvT0Tank: Block Medivac #3+ in TvT while SiegeTank < 4 (even under air-override!);
;;     unlock once SiegeTank >= 4!
(reset-macro-escrow-tracker!)
(define t-56-tvt-block-medivac3-under-tank4
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 8600
    #:minerals 400 #:gas 300 #:supply-used 76 #:supply-cap 110 #:workers 42 #:active-bases 2
    #:mineral-harvesters 32 #:gas-harvesters 10
    #:army-supply 34 #:enemy-threat-supply 12 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 3 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 3 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 18 'siege-tank 2 'medivac 2 'viking-fighter 2)
    #:enemy-unit-counts (hasheq 'viking-fighter 3 'marine 12 'siege-tank 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 0 'starport 1))))
(check! (and (not (memq 'medivac (macro-brain-decision-scheduled-ids t-56-tvt-block-medivac3-under-tank4)))
             (not (eq? (macro-brain-decision-saving-for t-56-tvt-block-medivac3-under-tank4) 'medivac)))
        (format "L46-P0-2b(7) #56/#62 TvT MUST block Medivac#3+ while SiegeTank<4: sched=~s save=~a"
                (macro-brain-decision-scheduled-ids t-56-tvt-block-medivac3-under-tank4)
                (macro-brain-decision-saving-for t-56-tvt-block-medivac3-under-tank4)))

;; (8) #29/#65 ProdStall -> 0: Hard-cap true 2-base Terran Barracks <= 4 (<800M),
;;     while preserving 2b + 3rd CC (total-townhalls=3) scaling to Rax #4/#5!
(reset-macro-escrow-tracker!)
(define t-29-2b-rax-cap4
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 8900
    #:minerals 420 #:gas 150 #:supply-used 80 #:supply-cap 110 #:workers 42 #:active-bases 2
    #:mineral-harvesters 34 #:gas-harvesters 8
    #:army-supply 38 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 4 'barracks-techlab 1 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 4 'barracks-techlab 1 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 20 'marauder 4 'siege-tank 2 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 0 'factory 0 'starport 0))))
(reset-macro-escrow-tracker!)
(define t-2b-3rdcc-still-scales-rax
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 7600
    #:minerals 220 #:gas 140 #:supply-used 72 #:supply-cap 102 #:workers 38 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 8
    #:army-supply 34 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'command-center 1 'supply-depot 10 'barracks 3
                                    'barracks-techlab 1 'barracks-reactor 1 'engineering-bay 1
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'command-center 1 'supply-depot 10 'barracks 3
                                    'barracks-techlab 1 'barracks-reactor 1 'engineering-bay 1
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 4)
    #:unit-counts (hasheq 'scv 38 'marine 16 'marauder 4 'siege-tank 2 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 0 'factory 0 'starport 0))))
(check! (and (not (memq 'barracks (macro-brain-decision-scheduled-ids t-29-2b-rax-cap4)))
             (not (not (memq 'barracks (macro-brain-decision-scheduled-ids t-2b-3rdcc-still-scales-rax))))
             (>= (cand-u t-2b-3rdcc-still-scales-rax 'barracks) 535.0))
        (format "L46-P0-2b(8) #29/#65 true 2b MUST cap Rax<=4 while 2b+3rdCC still scales: 2b=~s 3cc=~s(u=~a)"
                (macro-brain-decision-scheduled-ids t-29-2b-rax-cap4)
                (macro-brain-decision-scheduled-ids t-2b-3rdcc-still-scales-rax)
                (cand-u t-2b-3rdcc-still-scales-rax 'barracks)))

;; (9) #73 ZvP DT CloakLoss -> 0: Scouted DarkShrine locks Lair ahead of Baneling/Roach gas drains!
(reset-macro-escrow-tracker!)
(define z-73-dt-lair-lock
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 5400
    #:minerals 200 #:gas 85 #:supply-used 48 #:supply-cap 70 #:workers 32 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 16 #:enemy-threat-supply 6 #:under-attack? #f #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'baneling-nest 1 'spore-crawler 2 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'baneling-nest 1 'spore-crawler 2 'extractor 2)
    #:unit-counts (hasheq 'drone 32 'queen 3 'zergling 14 'roach 2 'overlord 7)
    #:enemy-building-counts (hasheq 'dark-shrine 1 'twilight-council 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 6))))
(check! (and (eq? (macro-brain-decision-saving-for z-73-dt-lair-lock) 'lair)
             (>= (cand-u z-73-dt-lair-lock 'lair) 1165.0)
             (not (memq 'baneling (macro-brain-decision-scheduled-ids z-73-dt-lair-lock)))
             (not (memq 'roach (macro-brain-decision-scheduled-ids z-73-dt-lair-lock))))
        (format "L46-P0-2b(9) #73 ZvP DarkShrine MUST lock Lair>=1165 ahead of Baneling/Roach gas drain: save=~a u=~a sched=~s"
                (macro-brain-decision-saving-for z-73-dt-lair-lock)
                (cand-u z-73-dt-lair-lock 'lair)
                (macro-brain-decision-scheduled-ids z-73-dt-lair-lock)))

;; (10) #73 ZvP DT CloakLoss -> 0: Ready Lair locks Overseer #1 (1240), then trains Roaches >= 8 (660)!
(reset-macro-escrow-tracker!)
(define z-73-dt-overseer-first
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 6200
    #:minerals 220 #:gas 70 #:supply-used 54 #:supply-cap 78 #:workers 34 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 6
    #:army-supply 20 #:enemy-threat-supply 8 #:under-attack? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'spore-crawler 2 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'spore-crawler 2 'extractor 2)
    #:unit-counts (hasheq 'drone 34 'queen 4 'zergling 12 'roach 3 'overlord 8)
    #:enemy-unit-counts (hasheq 'dark-templar 3)
    #:enemy-building-counts (hasheq 'dark-shrine 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 6))))
(reset-macro-escrow-tracker!)
(define z-73-dt-roach8-lock
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 6500
    #:minerals 250 #:gas 100 #:supply-used 58 #:supply-cap 78 #:workers 34 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 6
    #:army-supply 24 #:enemy-threat-supply 8 #:under-attack? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'spore-crawler 2 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'spore-crawler 2 'extractor 2)
    #:unit-counts (hasheq 'drone 34 'queen 4 'zergling 10 'roach 3 'overseer 2 'overlord 6)
    #:enemy-unit-counts (hasheq 'dark-templar 3)
    #:enemy-building-counts (hasheq 'dark-shrine 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 6))))
(check! (and (not (not (memq 'overseer (macro-brain-decision-scheduled-ids z-73-dt-overseer-first))))
             (>= (cand-u z-73-dt-overseer-first 'overseer) 1240.0)
             (not (not (memq 'roach (macro-brain-decision-scheduled-ids z-73-dt-roach8-lock))))
             (>= (cand-u z-73-dt-roach8-lock 'roach) 660.0))
        (format "L46-P0-2b(10) #73 ZvP DT MUST morph Overseer>=1240 then pump Roaches>=660 (<8): ov=~s(u=~a) r=~s(u=~a)"
                (macro-brain-decision-scheduled-ids z-73-dt-overseer-first)
                (cand-u z-73-dt-overseer-first 'overseer)
                (macro-brain-decision-scheduled-ids z-73-dt-roach8-lock)
                (cand-u z-73-dt-roach8-lock 'roach)))

;; (11) Live Prod #5138315 (ZvP vs 45 Stalkers + 8 Observers / non-capital air):
;;      Cap ZvP Corruptors <= 12 (and 0 vs pure Stalker+Observer w/ 0 combat air / 0 Colossus)!
(reset-macro-escrow-tracker!)
(define z-zvp-noncap-corruptor-cap12
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 130 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 68 #:enemy-threat-supply 60 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'corruptor 12 'hydralisk 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'phoenix 10 'colossus 3 'stalker 20)
    #:enemy-building-counts (hasheq 'stargate 2 'robotics-bay 1)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(reset-macro-escrow-tracker!)
(define z-zvp-stalker-obs-zero-corruptor
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 120 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 58 #:enemy-threat-supply 60 #:under-attack? #f #:requires-anti-air? #f
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'hydralisk 10 'roach 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'stalker 45 'observer 8)
    #:enemy-building-counts (hasheq 'gateway 10 'robotics-facility 2)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(check! (and (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvp-noncap-corruptor-cap12)))
             (not (eq? (macro-brain-decision-saving-for z-zvp-noncap-corruptor-cap12) 'corruptor))
             (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvp-stalker-obs-zero-corruptor))))
        (format "L46-P0-2b(11) #5138315 ZvP MUST cap Corruptors<=12 without >=2 cap air & 0 vs Stalker+Obs: c12=~s z0=~s"
                (macro-brain-decision-scheduled-ids z-zvp-noncap-corruptor-cap12)
                (macro-brain-decision-scheduled-ids z-zvp-stalker-obs-zero-corruptor)))

;; (12) #5138315 Negative Guard: ZvP unlocks >12 Corruptors vs >=2 Carriers OR >=2 VoidRays!
(reset-macro-escrow-tracker!)
(define z-zvp-carriers-unlock-13plus
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 130 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 68 #:enemy-threat-supply 60 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'corruptor 12 'hydralisk 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'carrier 8 'void-ray 4)
    #:enemy-building-counts (hasheq 'stargate 3 'fleet-beacon 1)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(reset-macro-escrow-tracker!)
(define z-zvp-voidrays-unlock-13plus
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 14500
    #:minerals 600 #:gas 600 #:supply-used 130 #:supply-cap 170 #:workers 62 #:active-bases 4
    #:mineral-harvesters 46 #:gas-harvesters 16
    #:army-supply 68 #:enemy-threat-supply 50 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:total-building-counts (hasheq 'hatchery 3 'hive 1 'spawning-pool 1 'hydralisk-den 1 'spire 1 'extractor 6)
    #:unit-counts (hasheq 'drone 62 'queen 5 'corruptor 12 'hydralisk 10 'overlord 18)
    #:enemy-unit-counts (hasheq 'void-ray 4 'phoenix 8)
    #:enemy-building-counts (hasheq 'stargate 3)
    #:open-facility-slots (hasheq 'townhall 4 'larva 8))))
(check! (and (not (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvp-carriers-unlock-13plus))))
             (not (not (memq 'corruptor (macro-brain-decision-scheduled-ids z-zvp-voidrays-unlock-13plus)))))
        (format "L46-P0-2b(12) ZvP Corruptor >12 MUST unlock vs >=2 Carriers/VoidRays: car=~s vr=~s"
                (macro-brain-decision-scheduled-ids z-zvp-carriers-unlock-13plus)
                (macro-brain-decision-scheduled-ids z-zvp-voidrays-unlock-13plus)))

(printf "verify_wave46_belief: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
