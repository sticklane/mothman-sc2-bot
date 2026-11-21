#lang racket/base
(require racket/list
         racket/path
         (file "/home/sjaconette/repos/mothman-sc2-bot/lib/econ-ledger.rkt")
         (file "/home/sjaconette/repos/mothman-sc2-bot/lib/priority-macro-brain.rkt"))

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

(define (res-gas-floor dec)
  (hash-ref (priority-schedule-result-category-utilities
             (macro-brain-decision-priority-schedule dec))
            'reserved-gas-floor 0))

;; ============================================================================
;; 1. L48-P0-2a: Fix Live #5138327/#5138328 + Local #82/#57 Phoenix:12..22 Spam
;;               + Colossus@880 > Phoenix@860 + H2H #04 PvT Early RoboBay
;; ============================================================================

;; (1) Live #5138327/#5138328 (`P vs SicToss` Tempests + Stalkers):
;;     `protoss-phoenix-cap` MUST be <= 0 against Tempests / enemy-cap-air? (NEVER build Phoenix #1 into Tempests!)
(reset-macro-escrow-tracker!)
(define p-live-tempest-phoenix-cap0
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 12400
    #:minerals 600 #:gas 400 #:supply-used 110 #:supply-cap 150 #:workers 54 #:active-bases 3
    #:mineral-harvesters 40 #:gas-harvesters 14
    #:army-supply 56 #:enemy-threat-supply 44 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'stargate 2 'fleet-beacon 1 'twilight-council 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'stargate 2 'fleet-beacon 1 'twilight-council 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 54 'stalker 14 'void-ray 4)
    #:enemy-unit-counts (hasheq 'tempest 6 'stalker 24)
    #:enemy-building-counts (hasheq 'stargate 2 'fleet-beacon 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'stargate 2))))
(check! (and (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-live-tempest-phoenix-cap0)))
             (not (eq? (macro-brain-decision-saving-for p-live-tempest-phoenix-cap0) 'phoenix)))
        (format "L48-P0-2a(1) Live #5138327/#5138328 vs Tempests MUST cap Phoenix<=0: sched=~s sav=~a"
                (macro-brain-decision-scheduled-ids p-live-tempest-phoenix-cap0)
                (macro-brain-decision-saving-for p-live-tempest-phoenix-cap0)))

;; (2) Even 1 enemy Carrier or 1 enemy Battlecruiser MUST cap Phoenix <= 0!
(reset-macro-escrow-tracker!)
(define p-1carrier-phoenix-cap0
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 10800
    #:minerals 450 #:gas 300 #:supply-used 90 #:supply-cap 130 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 42 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1 'stargate 2 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1 'stargate 2 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 12)
    #:enemy-unit-counts (hasheq 'carrier 1 'stalker 10)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'stargate 2))))
(reset-macro-escrow-tracker!)
(define p-1bc-phoenix-cap0
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 10800
    #:minerals 450 #:gas 300 #:supply-used 90 #:supply-cap 130 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 42 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1 'stargate 2 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1 'stargate 2 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 12)
    #:enemy-unit-counts (hasheq 'battlecruiser 1 'marine 12)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'stargate 2))))
(check! (and (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-1carrier-phoenix-cap0)))
             (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-1bc-phoenix-cap0))))
        (format "L48-P0-2a(2) >=1 Carrier or >=1 BC MUST cap Phoenix<=0: car=~s bc=~s"
                (macro-brain-decision-scheduled-ids p-1carrier-phoenix-cap0)
                (macro-brain-decision-scheduled-ids p-1bc-phoenix-cap0)))

;; (3) Local #82/#57 PvT Bio (0 Banshees, >=10 ground supply): cap Phoenix <= 4;
;;     Negative guard: PvT vs 10 Banshees & 0 ground STILL allows Phoenix #5+!
(reset-macro-escrow-tracker!)
(define p-82-pvt-bio-phoenix-cap4
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9800
    #:minerals 480 #:gas 320 #:supply-used 96 #:supply-cap 134 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 48 #:enemy-threat-supply 26 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1 'stargate 2 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1 'stargate 2 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 12 'phoenix 4 'immortal 2)
    #:enemy-unit-counts (hasheq 'marine 18 'marauder 4 'medivac 3 'viking-fighter 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'stargate 2))))
(reset-macro-escrow-tracker!)
(define p-neg-banshee10-allows-phoenix5
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 360 #:gas 240 #:supply-used 78 #:supply-cap 110 #:workers 46 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 10
    #:army-supply 32 #:enemy-threat-supply 22 #:under-attack? #f #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'stargate 2 'forge 1 'photon-cannon 2 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'stargate 2 'forge 1 'photon-cannon 2 'assimilator 6)
    #:unit-counts (hasheq 'probe 46 'phoenix 4 'stalker 8 'observer 1)
    #:enemy-unit-counts (hasheq 'banshee 10)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'stargate 2))))
(check! (and (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-82-pvt-bio-phoenix-cap4)))
             (not (eq? (macro-brain-decision-saving-for p-82-pvt-bio-phoenix-cap4) 'phoenix))
             (not (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-neg-banshee10-allows-phoenix5)))))
        (format "L48-P0-2a(3) #82 PvT Bio caps Phoenix<=4 while 10-Banshee still builds Phoenix#5: bio=~s/sav=~a ban=~s"
                (macro-brain-decision-scheduled-ids p-82-pvt-bio-phoenix-cap4)
                (macro-brain-decision-saving-for p-82-pvt-bio-phoenix-cap4)
                (macro-brain-decision-scheduled-ids p-neg-banshee10-allows-phoenix5)))

;; (4) Local #82 exact repro (`f=11288`, `200M/140G` & `320M/220G`, ready RoboBay + ready Stargate, 0 Colossi):
;;     Colossus (`u >= 880.0 > Phoenix@860.0`) MUST lock escrow over Phoenix/VoidRay and train Colossus!
(reset-macro-escrow-tracker!)
(define p-82-colossus-beats-phoenix-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 11288
    #:minerals 200 #:gas 140 #:supply-used 92 #:supply-cap 134 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'stargate 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'stargate 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 12 'immortal 3 'phoenix 2 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 18 'marauder 4 'siege-tank 4 'medivac 2 'viking-fighter 2)
    #:enemy-building-counts (hasheq 'starport 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 3 'robotics-facility 1 'stargate 1))))
(reset-macro-escrow-tracker!)
(define p-82-colossus-beats-phoenix-train
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 11340
    #:minerals 320 #:gas 220 #:supply-used 92 #:supply-cap 134 #:workers 48 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'stargate 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'stargate 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 48 'stalker 12 'immortal 3 'phoenix 2 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 18 'marauder 4 'siege-tank 4 'medivac 2 'viking-fighter 2)
    #:enemy-building-counts (hasheq 'starport 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 3 'robotics-facility 1 'stargate 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-82-colossus-beats-phoenix-escrow) 'colossus)
             (>= (cand-u p-82-colossus-beats-phoenix-escrow 'colossus) 880.0)
             (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-82-colossus-beats-phoenix-escrow)))
             (not (memq 'void-ray (macro-brain-decision-scheduled-ids p-82-colossus-beats-phoenix-escrow)))
             (not (not (memq 'colossus (macro-brain-decision-scheduled-ids p-82-colossus-beats-phoenix-train))))
             (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-82-colossus-beats-phoenix-train))))
        (format "L48-P0-2a(4) #82 Colossus@>=880 MUST block Phoenix/VoidRay & train Colossus: esc=~s/sav=~a(u=~a) tr=~s"
                (macro-brain-decision-scheduled-ids p-82-colossus-beats-phoenix-escrow)
                (macro-brain-decision-saving-for p-82-colossus-beats-phoenix-escrow)
                (cand-u p-82-colossus-beats-phoenix-escrow 'colossus)
                (macro-brain-decision-scheduled-ids p-82-colossus-beats-phoenix-train)))

;; (5) H2H #04 PvT exact f=7248..7332 repro (`2b`, `42w`, `22` army, unbreached `enemy-threat-supply = 12 <= 22`,
;;     Terran Bio `14` Marines + `3` Marauders + `2` Medivacs): MUST NOT false-trigger proxy-Marauder!
;;     `robotics-bay` MUST stay `>= 960.0`, escrow at `115M/145G` & build at `180M/160G` ahead of Stalker/ShieldBattery!
(reset-macro-escrow-tracker!)
(define p-04-unbreached-bio-robobay-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7248
    #:minerals 115 #:gas 145 #:supply-used 64 #:supply-cap 78 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 22 #:enemy-threat-supply 12 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 7 'immortal 2)
    #:enemy-unit-counts (hasheq 'marine 14 'marauder 3 'medivac 2)
    #:enemy-building-counts (hasheq 'starport 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-04-unbreached-bio-robobay-build
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7280
    #:minerals 180 #:gas 160 #:supply-used 64 #:supply-cap 78 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 22 #:enemy-threat-supply 12 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 7 'immortal 2)
    #:enemy-unit-counts (hasheq 'marine 14 'marauder 3 'medivac 2)
    #:enemy-building-counts (hasheq 'starport 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-04-unbreached-bio-robobay-escrow) 'robotics-bay)
             (>= (cand-u p-04-unbreached-bio-robobay-escrow 'robotics-bay) 960.0)
             (not (memq 'shield-battery (macro-brain-decision-scheduled-ids p-04-unbreached-bio-robobay-escrow)))
             (not (not (memq 'robotics-bay (macro-brain-decision-scheduled-ids p-04-unbreached-bio-robobay-build)))))
        (format "L48-P0-2a(5) H2H #04 PvT unbreached 2b Bio MUST keep RoboBay>=960 ahead of Stalker/Battery: esc=~s/sav=~a(u=~a) bld=~s"
                (macro-brain-decision-scheduled-ids p-04-unbreached-bio-robobay-escrow)
                (macro-brain-decision-saving-for p-04-unbreached-bio-robobay-escrow)
                (cand-u p-04-unbreached-bio-robobay-escrow 'robotics-bay)
                (macro-brain-decision-scheduled-ids p-04-unbreached-bio-robobay-build)))

;; (6) Negative guard: Real 1-base proxy Marauder rush (`4` Marauders, `under-attack?=#t`, `1` base)
;;     STILL suppresses `robotics-bay` & boosts `immortal`/`stalker`/`shield-battery`!
(reset-macro-escrow-tracker!)
(define p-neg-real-proxy-marauder
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 3800
    #:minerals 280 #:gas 150 #:supply-used 28 #:supply-cap 39 #:workers 20 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 6
    #:army-supply 8 #:enemy-threat-supply 10 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 20 'stalker 4)
    #:enemy-unit-counts (hasheq 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 1))))
(check! (and (not (memq 'robotics-bay (macro-brain-decision-scheduled-ids p-neg-real-proxy-marauder)))
             (not (not (memq 'immortal (macro-brain-decision-scheduled-ids p-neg-real-proxy-marauder)))))
        (format "L48-P0-2a(6) Neg guard: Real proxy Marauder rush still suppresses RoboBay & trains Immortal: sched=~s"
                (macro-brain-decision-scheduled-ids p-neg-real-proxy-marauder)))

;; ============================================================================
;; 2. L48-P0-2b: H2H #01 ZvZ Non-Blocking Hatchery + #53 Pre-4m >=1 TvT Reaper
;;               + #12/#39/#51 PvPNatDelay TwilightCouncil & Forge Defer
;; ============================================================================

;; (7) H2H #01 ZvZ: When `supply-left <= 2` (`58/60`), `hatchery` MUST NOT escrow-block Overlord/units!
(reset-macro-escrow-tracker!)
(define z-01-zvz-supply-tight-no-hatch-block
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Zerg #:frame 5684
    #:minerals 130 #:gas 62 #:supply-used 58 #:supply-cap 60 #:workers 38 #:active-bases 2
    #:mineral-harvesters 32 #:gas-harvesters 6
    #:army-supply 20 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:unit-counts (hasheq 'drone 38 'queen 3 'roach 6 'zergling 4 'overlord 6)
    #:enemy-unit-counts (hasheq 'roach 6 'zergling 8)
    #:open-facility-slots (hasheq 'townhall 2 'larva 4))))
(check! (and (not (eq? (macro-brain-decision-saving-for z-01-zvz-supply-tight-no-hatch-block) 'hatchery))
             (not (not (memq 'overlord (macro-brain-decision-scheduled-ids z-01-zvz-supply-tight-no-hatch-block)))))
        (format "L48-P0-2b(7) H2H #01 ZvZ @supply-left<=2 MUST NOT let Hatchery block Overlord: sched=~s sav=~a"
                (macro-brain-decision-scheduled-ids z-01-zvz-supply-tight-no-hatch-block)
                (macro-brain-decision-saving-for z-01-zvz-supply-tight-no-hatch-block)))

;; (8) H2H #01 ZvZ exact f=12544 repro (`1` surviving Hatchery, `134M/197G`, `army 18 < threat 20 + 4`):
;;     `hatchery` MUST NOT hold `300M` escrow blocking Hydralisk / Roach / Zergling!
(reset-macro-escrow-tracker!)
(define z-01-zvz-outnumbered-no-hatch-block
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Zerg #:frame 12544
    #:minerals 134 #:gas 197 #:supply-used 58 #:supply-cap 102 #:workers 40 #:active-bases 1
    #:mineral-harvesters 28 #:gas-harvesters 12
    #:army-supply 18 #:enemy-threat-supply 20 #:under-attack? #f
    #:ready-building-counts (hasheq 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 3)
    #:total-building-counts (hasheq 'lair 1 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'extractor 3)
    #:unit-counts (hasheq 'drone 40 'queen 2 'roach 6 'zergling 4 'overlord 12)
    #:enemy-unit-counts (hasheq 'roach 10 'zergling 20)
    #:open-facility-slots (hasheq 'townhall 1 'larva 5))))
(check! (and (not (eq? (macro-brain-decision-saving-for z-01-zvz-outnumbered-no-hatch-block) 'hatchery))
             (ormap (lambda (u) (memq u (macro-brain-decision-scheduled-ids z-01-zvz-outnumbered-no-hatch-block)))
                    '(hydralisk roach ravager zergling)))
        (format "L48-P0-2b(8) H2H #01 ZvZ f=12544 outnumbered MUST train army & never Hatchery-escrow: sched=~s sav=~a"
                (macro-brain-decision-scheduled-ids z-01-zvz-outnumbered-no-hatch-block)
                (macro-brain-decision-saving-for z-01-zvz-outnumbered-no-hatch-block)))

;; (9) Negative guard: Peaceful post-pool ZvZ natural (`f=2200`, `200M/0G`, `18/22`, `threat=0`) STILL escrows Hatchery!
(reset-macro-escrow-tracker!)
(define z-neg-zvz-16hatch-preserved
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Zerg #:frame 2200
    #:minerals 200 #:gas 0 #:supply-used 18 #:supply-cap 22 #:workers 18 #:active-bases 1
    #:mineral-harvesters 18 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 18 'overlord 2)
    #:open-facility-slots (hasheq 'townhall 1 'larva 2))))
(check! (eq? (macro-brain-decision-saving-for z-neg-zvz-16hatch-preserved) 'hatchery)
        (format "L48-P0-2b(9) Neg guard: Peaceful ZvZ 16-Hatch still escrows Hatchery: sched=~s sav=~a"
                (macro-brain-decision-scheduled-ids z-neg-zvz-16hatch-preserved)
                (macro-brain-decision-saving-for z-neg-zvz-16hatch-preserved)))

;; (10) #53 zig-reapers exact Reaper #1 repro (`f=2236`, `155M/60G`, 1 threatening Reaper in TvT, 2 Marines < 4):
;;      MUST defer `orbital-command` & `command-center #2` and pump `marine`/`bunker`!
(reset-macro-escrow-tracker!)
(define t-53-tvt-reaper1-defers-oc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 2236
    #:minerals 155 #:gas 60 #:supply-used 19 #:supply-cap 23 #:workers 17 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 1 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 2 'barracks 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 2 'barracks 1 'refinery 1)
    #:unit-counts (hasheq 'scv 17 'marine 2)
    #:enemy-unit-counts (hasheq 'reaper 1)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(check! (and (not (memq 'orbital-command (macro-brain-decision-scheduled-ids t-53-tvt-reaper1-defers-oc)))
             (not (eq? (macro-brain-decision-saving-for t-53-tvt-reaper1-defers-oc) 'orbital-command))
             (not (memq 'command-center (macro-brain-decision-scheduled-ids t-53-tvt-reaper1-defers-oc)))
             (not (not (memq 'marine (macro-brain-decision-scheduled-ids t-53-tvt-reaper1-defers-oc)))))
        (format "L48-P0-2b(10) #53 TvT >=1 threatening Reaper <4m MUST defer OC/CC & train Marine: sched=~s sav=~a"
                (macro-brain-decision-scheduled-ids t-53-tvt-reaper1-defers-oc)
                (macro-brain-decision-saving-for t-53-tvt-reaper1-defers-oc)))

;; (11) Negative guards for #53 TvT single Reaper:
;;      (a) Once >= 4 Marines exist vs 1 Reaper, OC unlocks cleanly;
;;      (b) Distant non-threatening Reaper (`enemy-threat-supply = 0`, `not under-attack?`) does NOT block OC!
(reset-macro-escrow-tracker!)
(define t-53-neg-4marines-unlocks-oc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 2500
    #:minerals 210 #:gas 60 #:supply-used 22 #:supply-cap 31 #:workers 18 #:active-bases 1
    #:mineral-harvesters 15 #:gas-harvesters 3
    #:army-supply 4 #:enemy-threat-supply 1 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 3 'barracks 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 2 'supply-depot 3 'barracks 1 'refinery 1)
    #:unit-counts (hasheq 'scv 18 'marine 4)
    #:enemy-unit-counts (hasheq 'reaper 1)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(reset-macro-escrow-tracker!)
(define t-53-neg-distant-reaper-allows-oc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 2236
    #:minerals 160 #:gas 60 #:supply-used 19 #:supply-cap 23 #:workers 17 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 2 'barracks 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 2 'supply-depot 2 'barracks 1 'refinery 1)
    #:unit-counts (hasheq 'scv 17 'marine 2)
    #:enemy-unit-counts (hasheq 'reaper 1)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(check! (and (not (not (memq 'orbital-command (macro-brain-decision-scheduled-ids t-53-neg-4marines-unlocks-oc))))
             (not (not (memq 'orbital-command (macro-brain-decision-scheduled-ids t-53-neg-distant-reaper-allows-oc)))))
        (format "L48-P0-2b(11) Neg guard: >=4 Marines OR distant Reaper unlocks OC: m4=~s dist=~s"
                (macro-brain-decision-scheduled-ids t-53-neg-4marines-unlocks-oc)
                (macro-brain-decision-scheduled-ids t-53-neg-distant-reaper-allows-oc)))

;; (12) #12/#39/#51 PvPNatDelay (`f=5820`, 1-base unpressured PvP @ 320M/140G):
;;      MUST defer `twilight-council` & `forge` strictly behind Natural Nexus #2;
;;      Negative guard: when enemy `dark-shrine` is scouted, `forge` detection is NOT deferred!
(reset-macro-escrow-tracker!)
(define p-12-nat-5820-defers-twilight-forge
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 5820
    #:minerals 320 #:gas 140 #:supply-used 40 #:supply-cap 55 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 18 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 6 'gateway 2 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 6 'gateway 2 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 6 'zealot 2 'immortal 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-12-neg-dark-shrine-allows-forge
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 4600
    #:minerals 200 #:gas 20 #:supply-used 34 #:supply-cap 47 #:workers 22 #:active-bases 1
    #:mineral-harvesters 18 #:gas-harvesters 4
    #:army-supply 12 #:enemy-threat-supply 2 #:under-attack? #f #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 5 'gateway 2 'cybernetics-core 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 5 'gateway 2 'cybernetics-core 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 22 'stalker 5 'zealot 1)
    #:enemy-building-counts (hasheq 'dark-shrine 1 'twilight-council 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2))))
(check! (and (eq? (macro-brain-decision-saving-for p-12-nat-5820-defers-twilight-forge) 'nexus)
             (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-12-nat-5820-defers-twilight-forge)))
             (not (memq 'forge (macro-brain-decision-scheduled-ids p-12-nat-5820-defers-twilight-forge)))
             (not (not (memq 'forge (macro-brain-decision-scheduled-ids p-12-neg-dark-shrine-allows-forge)))))
        (format "L48-P0-2b(12) #12 PvP f=5820 defers Twilight/Forge for Nexus#2 & keeps Forge vs DarkShrine: nat=~s/sav=~a ds=~s"
                (macro-brain-decision-scheduled-ids p-12-nat-5820-defers-twilight-forge)
                (macro-brain-decision-saving-for p-12-nat-5820-defers-twilight-forge)
                (macro-brain-decision-scheduled-ids p-12-neg-dark-shrine-allows-forge)))

;; ============================================================================
;; 3. Loop 48 Wave 2 (`#1095`/`#1096`): H2H #02 TvT Mirror Viking Exclusion +
;;    Starport<=2 + Ghost/4th-CC Deferral & H2H #04 PvT Protoss Air-Upgrade Gate
;; ============================================================================

;; (13) H2H #02 TvT exact repro: opponent has 8 mirror Vikings (0 Banshee/Lib/BC) while we have 2 Tanks (<4)
;;      and 2 Starports -> mirror Vikings MUST NOT trigger air-dominance or break Tank4 gas-lock;
;;      MUST keep `siege-tank >= 660` above `viking-fighter`, and cap TvT Starports <= 2!
(reset-macro-escrow-tracker!)
(define t-02-tvt-mirror-vikings-keep-tank4
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 10400
    #:minerals 450 #:gas 135 #:supply-used 92 #:supply-cap 140 #:workers 54 #:active-bases 3
    #:mineral-harvesters 40 #:gas-harvesters 14
    #:army-supply 38 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 4 'barracks-techlab 1
                                    'factory 2 'factory-techlab 2 'starport 2 'engineering-bay 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 4 'barracks-techlab 1
                                    'factory 2 'factory-techlab 2 'starport 2 'engineering-bay 1 'refinery 6)
    #:unit-counts (hasheq 'scv 54 'marine 20 'siege-tank 2 'medivac 2 'viking-fighter 6)
    #:enemy-unit-counts (hasheq 'viking-fighter 8 'marine 4 'siege-tank 2)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 2 'factory 2 'starport 2))))
(check! (and (not (not (memq 'siege-tank (macro-brain-decision-scheduled-ids t-02-tvt-mirror-vikings-keep-tank4))))
             (>= (cand-u t-02-tvt-mirror-vikings-keep-tank4 'siege-tank) 660.0)
             (not (memq 'starport (macro-brain-decision-scheduled-ids t-02-tvt-mirror-vikings-keep-tank4)))
             (not (eq? (macro-brain-decision-saving-for t-02-tvt-mirror-vikings-keep-tank4) 'starport)))
        (format "L48-W2(13) H2H #02 TvT mirror Vikings MUST NOT break Tank4 lock or build Starport#3: sched=~s u_tank=~a u_vik=~a sav=~a"
                (macro-brain-decision-scheduled-ids t-02-tvt-mirror-vikings-keep-tank4)
                (cand-u t-02-tvt-mirror-vikings-keep-tank4 'siege-tank)
                (cand-u t-02-tvt-mirror-vikings-keep-tank4 'viking-fighter)
                (macro-brain-decision-saving-for t-02-tvt-mirror-vikings-keep-tank4)))

;; (14) H2H #02 TvT GhostAcademy/4th-CC deferral: TvT under attack with 1 SiegeTank (<2) @ 550M/150G ->
;;      MUST defer GhostAcademy, Ghost, and 4th CC while prioritizing SiegeTank!
(reset-macro-escrow-tracker!)
(define t-02-tvt-defer-ghost-and-4th-cc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 13800
    #:minerals 550 #:gas 150 #:supply-used 98 #:supply-cap 140 #:workers 56 #:active-bases 3
    #:mineral-harvesters 42 #:gas-harvesters 14 #:depleting-bases 1
    #:army-supply 42 #:enemy-threat-supply 30 #:under-attack? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5 'barracks-techlab 2
                                    'factory 2 'factory-techlab 2 'starport 2 'engineering-bay 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 14 'barracks 5 'barracks-techlab 2
                                    'factory 2 'factory-techlab 2 'starport 2 'engineering-bay 1 'refinery 6)
    #:unit-counts (hasheq 'scv 56 'marine 24 'siege-tank 1 'medivac 2 'viking-fighter 8)
    #:enemy-unit-counts (hasheq 'viking-fighter 10 'marine 14 'siege-tank 7)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 2 'factory 2 'starport 2))))
(check! (and (not (memq 'ghost-academy (macro-brain-decision-scheduled-ids t-02-tvt-defer-ghost-and-4th-cc)))
             (not (memq 'command-center (macro-brain-decision-scheduled-ids t-02-tvt-defer-ghost-and-4th-cc)))
             (not (eq? (macro-brain-decision-saving-for t-02-tvt-defer-ghost-and-4th-cc) 'command-center))
             (not (not (memq 'siege-tank (macro-brain-decision-scheduled-ids t-02-tvt-defer-ghost-and-4th-cc)))))
        (format "L48-W2(14) H2H #02 TvT under-attack/Tank<2 MUST defer GhostAcademy & 4th CC and train Tank: sched=~s sav=~a"
                (macro-brain-decision-scheduled-ids t-02-tvt-defer-ghost-and-4th-cc)
                (macro-brain-decision-saving-for t-02-tvt-defer-ghost-and-4th-cc)))

;; (15) Negative guard for TvT real air dominance: >= 6 enemy Banshees STILL triggers air-dominated AA (Vikings)!
(reset-macro-escrow-tracker!)
(define t-02-tvt-neg-real-banshee-air-dom
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 9000
    #:minerals 400 #:gas 200 #:supply-used 72 #:supply-cap 110 #:workers 42 #:active-bases 2
    #:mineral-harvesters 32 #:gas-harvesters 10
    #:army-supply 30 #:enemy-threat-supply 18 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 3 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'missile-turret 2 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 11 'barracks 3 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'missile-turret 2 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 18 'siege-tank 2 'viking-fighter 2)
    #:enemy-unit-counts (hasheq 'banshee 6 'marine 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1))))
(check! (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-02-tvt-neg-real-banshee-air-dom))))
        (format "L48-W2(15) Neg guard: TvT vs >= 6 Banshees MUST still trigger Viking AA: sched=~s"
                (macro-brain-decision-scheduled-ids t-02-tvt-neg-real-banshee-air-dom)))

;; (16) H2H #04 PvT Protoss Air-Upgrade Gate:
;;      (a) With 0 Stargate & 0 air units (or only 2 Phoenixes < 3), CyberCore MUST NOT schedule/escrow protoss-air-weapons-1!
;;      (b) With Stargate >= 1 AND >= 3 air combat units, protoss-air-weapons-1 IS allowed!
(reset-macro-escrow-tracker!)
(define p-04-block-air-upg-0-stargate
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8300
    #:minerals 220 #:gas 180 #:supply-used 68 #:supply-cap 94 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'forge 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'forge 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'zealot 2 'adept 2)
    #:researched-upgrades '(warp-gate-research)
    #:mirror-signals (hasheq 'bo-steps (list (pro-bo-goal 'research 'protoss-air-weapons-1 1 50 'cybernetics-core 300.0)))
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 0 'cybernetics-core 1 'forge 0))))
(reset-macro-escrow-tracker!)
(define p-04-block-air-upg-2-phoenix
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 220 #:gas 180 #:supply-used 72 #:supply-cap 94 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'stargate 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'stargate 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'phoenix 2)
    #:researched-upgrades '(warp-gate-research)
    #:mirror-signals (hasheq 'bo-steps (list (pro-bo-goal 'research 'protoss-air-weapons-1 1 50 'cybernetics-core 300.0)))
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'stargate 0 'cybernetics-core 1))))
(reset-macro-escrow-tracker!)
(define p-04-allow-air-upg-3-phoenix
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9000
    #:minerals 300 #:gas 250 #:supply-used 74 #:supply-cap 94 #:workers 42 #:active-bases 3
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 32 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 4 'cybernetics-core 1 'stargate 1
                                    'twilight-council 1 'forge 1 'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 4 'cybernetics-core 1 'stargate 1
                                    'twilight-council 1 'forge 1 'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'phoenix 3)
    #:researched-upgrades '(warp-gate-research)
    #:mirror-signals (hasheq 'bo-steps (list (pro-bo-goal 'research 'protoss-air-weapons-1 1 50 'cybernetics-core 300.0)))
    #:open-facility-slots (hasheq 'townhall 3 'gateway 0 'stargate 0 'robotics-facility 0 'cybernetics-core 1 'forge 0 'twilight-council 0))))
(check! (and (not (memq 'protoss-air-weapons-1 (macro-brain-decision-scheduled-ids p-04-block-air-upg-0-stargate)))
             (not (eq? (macro-brain-decision-saving-for p-04-block-air-upg-0-stargate) 'protoss-air-weapons-1))
             (not (memq 'protoss-air-weapons-1 (macro-brain-decision-scheduled-ids p-04-block-air-upg-2-phoenix)))
             (not (not (memq 'protoss-air-weapons-1 (macro-brain-decision-scheduled-ids p-04-allow-air-upg-3-phoenix)))))
        (format "L48-W2(16) H2H #04 Protoss air-weapons-1 MUST require Stargate>0 & air>=3: sg0=~s ph2=~s ph3=~s"
                (macro-brain-decision-scheduled-ids p-04-block-air-upg-0-stargate)
                (macro-brain-decision-scheduled-ids p-04-block-air-upg-2-phoenix)
                (macro-brain-decision-scheduled-ids p-04-allow-air-upg-3-phoenix)))

(reset-macro-escrow-tracker!)
(printf "verify_wave48_belief: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
