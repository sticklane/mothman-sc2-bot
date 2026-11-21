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
;; 1. L47-P0-2a: Fix 0-Colossus (H2H #04 PvT RoboBay AA Escrow Bypass + #18
;;               Terran <=2 Air Tolerance + PvP 0-7 Tier-3 RoboBay & Colossus
;;               + #21 PolyMorph Colossus@760 > Immortal@745 Priority Inversion)
;; ============================================================================

;; (1) H2H #04 PvT exact f=9204 repro (`185M/103G`, `eff-req-aa?=#t`, Bio+Medivac+1 Viking):
;;     `protoss-aa-stalker-ignores-heavy-escrow?` MUST NOT bypass `robotics-bay` escrow!
;;     RoboticsBay MUST lock `150G` gas floor & block Stalker from draining gas to 19G!
(reset-macro-escrow-tracker!)
(define p-04-robobay-aa-escrow-protected
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9204
    #:minerals 185 #:gas 103 #:supply-used 74 #:supply-cap 102 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 32 #:enemy-threat-supply 16 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 10 'immortal 2 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 18 'marauder 4 'medivac 2 'viking-fighter 1)
    #:enemy-building-counts (hasheq 'starport 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-04-robobay-130g-saves
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9300
    #:minerals 210 #:gas 130 #:supply-used 74 #:supply-cap 102 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 32 #:enemy-threat-supply 16 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 10 'immortal 2 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 18 'marauder 4 'medivac 2 'viking-fighter 1)
    #:enemy-building-counts (hasheq 'starport 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-04-robobay-aa-escrow-protected) 'robotics-bay)
             (>= (res-gas-floor p-04-robobay-aa-escrow-protected) 150)
             (not (memq 'stalker (macro-brain-decision-scheduled-ids p-04-robobay-aa-escrow-protected)))
             (eq? (macro-brain-decision-saving-for p-04-robobay-130g-saves) 'robotics-bay)
             (not (memq 'stalker (macro-brain-decision-scheduled-ids p-04-robobay-130g-saves))))
        (format "L47-P0-2a(1) H2H #04 PvT RoboBay MUST NOT be bypassed by AA Stalker: 103g=~s/sav=~a(gfl=~a) 130g=~s/sav=~a"
                (macro-brain-decision-scheduled-ids p-04-robobay-aa-escrow-protected)
                (macro-brain-decision-saving-for p-04-robobay-aa-escrow-protected)
                (res-gas-floor p-04-robobay-aa-escrow-protected)
                (macro-brain-decision-scheduled-ids p-04-robobay-130g-saves)
                (macro-brain-decision-saving-for p-04-robobay-130g-saves)))

;; (2) #18 RustyNikolaj: Terran Bio + 2 Vikings (`enemy-air-combat-cnt = 2`) STILL schedules `robotics-bay`,
;;     while negative guard (5 Banshees + 12 Vikings) STILL lets Stalker bypass `robotics-bay`!
(reset-macro-escrow-tracker!)
(define p-18-2vikings-builds-robobay
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 7800
    #:minerals 200 #:gas 165 #:supply-used 72 #:supply-cap 102 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 14 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'immortal 2 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 14 'marauder 4 'viking-fighter 2 'medivac 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-18-neg-banshee-viking-stalker-wins
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 11000
    #:minerals 260 #:gas 110 #:supply-used 80 #:supply-cap 120 #:workers 46 #:active-bases 3
    #:mineral-harvesters 36 #:gas-harvesters 10
    #:army-supply 34 #:enemy-threat-supply 28 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 46 'stalker 8 'immortal 2 'observer 1)
    #:enemy-unit-counts (hasheq 'viking-fighter 12 'banshee 5 'marine 20)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 1))))
(check! (and (not (not (memq 'robotics-bay (macro-brain-decision-scheduled-ids p-18-2vikings-builds-robobay))))
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-18-neg-banshee-viking-stalker-wins))))
             (not (eq? (macro-brain-decision-saving-for p-18-neg-banshee-viking-stalker-wins) 'robotics-bay)))
        (format "L47-P0-2a(2) #18 <=2 Vikings builds RoboBay while 5-Banshee+12-Viking still trains Stalker: v2=~s neg=~s/sav=~a"
                (macro-brain-decision-scheduled-ids p-18-2vikings-builds-robobay)
                (macro-brain-decision-scheduled-ids p-18-neg-banshee-viking-stalker-wins)
                (macro-brain-decision-saving-for p-18-neg-banshee-viking-stalker-wins)))

;; (3) PvP 0-7 Tier-3 Unlock (RoboticsBay): 2-base PvP with >=4 Gateways & >=3 Immortals (or >=2 w/ busy Robo)
;;     MUST build `robotics-bay`, while negative guard vs Tempests does NOT build `robotics-bay`!
(reset-macro-escrow-tracker!)
(define p-pvp-robobay-unlock
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 7600
    #:minerals 210 #:gas 165 #:supply-used 74 #:supply-cap 102 #:workers 40 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 14 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 40 'stalker 8 'immortal 3 'zealot 2)
    #:enemy-unit-counts (hasheq 'stalker 8 'immortal 2 'zealot 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvp-tempest-no-robobay
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 9200
    #:minerals 210 #:gas 165 #:supply-used 74 #:supply-cap 102 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 32 #:enemy-threat-supply 24 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'stargate 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'stargate 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 10 'immortal 3)
    #:enemy-unit-counts (hasheq 'tempest 4 'void-ray 2)
    #:enemy-building-counts (hasheq 'stargate 2 'fleet-beacon 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1 'stargate 1))))
(check! (and (not (not (memq 'robotics-bay (macro-brain-decision-scheduled-ids p-pvp-robobay-unlock))))
             (>= (cand-u p-pvp-robobay-unlock 'robotics-bay) 590.0)
             (not (memq 'robotics-bay (macro-brain-decision-scheduled-ids p-pvp-tempest-no-robobay)))
             (not (eq? (macro-brain-decision-saving-for p-pvp-tempest-no-robobay) 'robotics-bay)))
        (format "L47-P0-2a(3) PvP Tier-3 RoboBay unlocks @3 Immortals (u=~a) & stays off vs Tempests: pvp=~s tmp=~s/sav=~a"
                (cand-u p-pvp-robobay-unlock 'robotics-bay)
                (macro-brain-decision-scheduled-ids p-pvp-robobay-unlock)
                (macro-brain-decision-scheduled-ids p-pvp-tempest-no-robobay)
                (macro-brain-decision-saving-for p-pvp-tempest-no-robobay)))

;; (4) PvP 0-7 Colossus Core2 Unlock: Ready RoboBay in PvP with 0 Colossi & 2+ Immortals MUST escrow
;;     Colossus (u>=760, gas-floor>=200) @ 180M/140G and train Colossus (NOT Immortal) @ 320M/220G!
(reset-macro-escrow-tracker!)
(define p-pvp-colossus-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 8600
    #:minerals 180 #:gas 140 #:supply-used 78 #:supply-cap 110 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 36 #:enemy-threat-supply 16 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 10 'immortal 3 'observer 1)
    #:enemy-unit-counts (hasheq 'stalker 10 'immortal 2 'zealot 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvp-colossus-train
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 8700
    #:minerals 320 #:gas 220 #:supply-used 78 #:supply-cap 110 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 36 #:enemy-threat-supply 16 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 10 'immortal 3 'observer 1)
    #:enemy-unit-counts (hasheq 'stalker 10 'immortal 2 'zealot 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-pvp-colossus-escrow) 'colossus)
             (>= (cand-u p-pvp-colossus-escrow 'colossus) 760.0)
             (>= (res-gas-floor p-pvp-colossus-escrow) 200)
             (not (not (memq 'colossus (macro-brain-decision-scheduled-ids p-pvp-colossus-train))))
             (not (memq 'immortal (macro-brain-decision-scheduled-ids p-pvp-colossus-train))))
        (format "L47-P0-2a(4) PvP Colossus core2 locks >=760 & trains Colossus over Immortal: esc=~s/sav=~a(u=~a,gfl=~a) tr=~s"
                (macro-brain-decision-scheduled-ids p-pvp-colossus-escrow)
                (macro-brain-decision-saving-for p-pvp-colossus-escrow)
                (cand-u p-pvp-colossus-escrow 'colossus)
                (res-gas-floor p-pvp-colossus-escrow)
                (macro-brain-decision-scheduled-ids p-pvp-colossus-train)))

;; (5) #21 PolyMorph exact f=11948 repro (`405M/231G`, PvZ Mass-Roach active, ready RoboBay, 0 Colossi, 3 Immortals):
;;     Colossus (`u >= 760.0 > Immortal@745.0`) MUST schedule & block Immortal from stealing the Robo slot!
(reset-macro-escrow-tracker!)
(define p-21-polymorph-colossus-beats-immortal
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 11948
    #:minerals 405 #:gas 231 #:supply-used 96 #:supply-cap 134 #:workers 50 #:active-bases 3
    #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 46 #:enemy-threat-supply 30 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 5)
    #:unit-counts (hasheq 'probe 50 'stalker 12 'immortal 3 'zealot 4 'observer 1)
    #:enemy-unit-counts (hasheq 'roach 12 'ravager 4 'zergling 14)
    #:enemy-building-counts (hasheq 'hatchery 3 'roach-warren 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 3 'robotics-facility 1))))
(check! (and (not (not (memq 'colossus (macro-brain-decision-scheduled-ids p-21-polymorph-colossus-beats-immortal))))
             (not (memq 'immortal (macro-brain-decision-scheduled-ids p-21-polymorph-colossus-beats-immortal)))
             (>= (cand-u p-21-polymorph-colossus-beats-immortal 'colossus) 760.0))
        (format "L47-P0-2a(5) #21 PolyMorph @405M/231G PvZ Mass-Roach MUST train Colossus(>=760) over Immortal(745): sched=~s u_col=~a"
                (macro-brain-decision-scheduled-ids p-21-polymorph-colossus-beats-immortal)
                (cand-u p-21-polymorph-colossus-beats-immortal 'colossus)))

;; (6) Negative guard: Once Colossus >= 2 exist, Immortal unlocks cleanly in PvZ Mass-Roach!
(reset-macro-escrow-tracker!)
(define p-21-neg-2colossi-unlocks-immortal
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 12800
    #:minerals 340 #:gas 180 #:supply-used 110 #:supply-cap 150 #:workers 52 #:active-bases 3
    #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 58 #:enemy-threat-supply 30 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 6 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 52 'stalker 12 'immortal 3 'colossus 2 'observer 1)
    #:enemy-unit-counts (hasheq 'roach 12 'ravager 4 'zergling 14)
    #:enemy-building-counts (hasheq 'hatchery 3 'roach-warren 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 3 'robotics-facility 1))))
(check! (not (not (memq 'immortal (macro-brain-decision-scheduled-ids p-21-neg-2colossi-unlocks-immortal))))
        (format "L47-P0-2a(6) Neg guard: Colossus>=2 unlocks Immortal cleanly in PvZ Mass-Roach: sched=~s"
                (macro-brain-decision-scheduled-ids p-21-neg-2colossi-unlocks-immortal)))

;; ============================================================================
;; 2. L47-P0-2b: H2H #03 PvP Natural (<5600f & >=300M Unit Defer) + #60 CyberCore
;;               Cap + #72 12Pool >=275M Lift + #53 Pre-5m >=2 Reapers OC/CC Defer
;;               + #73 ZvT Banshee Spore 1/Base & >=5 Queens Ahead of Lair/HydraDen
;; ============================================================================

;; (7) H2H #03 PvP exact f=5092 repro (`< 5600f`, `350M..410M`, 1 base unpressured, Robo ready):
;;     MUST defer `immortal`/`stalker`/`zealot`/`gateway#3`/`photon-cannon#2` so Natural Nexus #2 lands!
(reset-macro-escrow-tracker!)
(define p-03-nat-5092-defers-immortal-350m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 5092
    #:minerals 350 #:gas 140 #:supply-used 42 #:supply-cap 55 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 20 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 6 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'forge 1 'photon-cannon 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 6 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'forge 1 'photon-cannon 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 6 'zealot 2 'immortal 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-03-nat-5092-builds-nexus-410m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 5092
    #:minerals 410 #:gas 140 #:supply-used 42 #:supply-cap 55 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 20 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 6 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'forge 1 'photon-cannon 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 6 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'forge 1 'photon-cannon 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 6 'zealot 2 'immortal 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-03-nat-5092-defers-immortal-350m) 'nexus)
             (not (ormap (lambda (s) (memq s '(immortal stalker zealot gateway photon-cannon)))
                         (macro-brain-decision-scheduled-ids p-03-nat-5092-defers-immortal-350m)))
             (not (not (memq 'nexus (macro-brain-decision-scheduled-ids p-03-nat-5092-builds-nexus-410m))))
             (not (memq 'immortal (macro-brain-decision-scheduled-ids p-03-nat-5092-builds-nexus-410m))))
        (format "L47-P0-2b(7) H2H #03 PvP f=5092 MUST defer immortal/stalker/gw#3/cannon#2 for Nexus#2: 350m=~s/sav=~a 410m=~s"
                (macro-brain-decision-scheduled-ids p-03-nat-5092-defers-immortal-350m)
                (macro-brain-decision-saving-for p-03-nat-5092-defers-immortal-350m)
                (macro-brain-decision-scheduled-ids p-03-nat-5092-builds-nexus-410m)))

;; (8) #60 Creepy CyberCore Cap: 2-base Protoss with 1 CyberCore MUST NOT build CyberCore #2;
;;     3-base cap-air Protoss with 2 CyberCores MUST NOT build CyberCore #3!
(reset-macro-escrow-tracker!)
(define p-60-2b-cyber-cap1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 7200
    #:minerals 520 #:gas 260 #:supply-used 68 #:supply-cap 94 #:workers 40 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 12 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'stargate 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'stargate 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 40 'stalker 10 'void-ray 2)
    #:enemy-unit-counts (hasheq 'tempest 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'stargate 1))))
(reset-macro-escrow-tracker!)
(define p-60-3b-cap-air-cyber-cap2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 11200
    #:minerals 600 #:gas 350 #:supply-used 110 #:supply-cap 150 #:workers 54 #:active-bases 3
    #:mineral-harvesters 40 #:gas-harvesters 14
    #:army-supply 56 #:enemy-threat-supply 36 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 6 'cybernetics-core 2 'stargate 2 'fleet-beacon 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 16 'gateway 6 'cybernetics-core 2 'stargate 2 'fleet-beacon 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 54 'stalker 14 'void-ray 6)
    #:enemy-unit-counts (hasheq 'tempest 10)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'stargate 1))))
(check! (and (not (memq 'cybernetics-core (macro-brain-decision-scheduled-ids p-60-2b-cyber-cap1)))
             (not (eq? (macro-brain-decision-saving-for p-60-2b-cyber-cap1) 'cybernetics-core))
             (not (memq 'cybernetics-core (macro-brain-decision-scheduled-ids p-60-3b-cap-air-cyber-cap2)))
             (not (eq? (macro-brain-decision-saving-for p-60-3b-cap-air-cyber-cap2) 'cybernetics-core)))
        (format "L47-P0-2b(8) #60 CyberCore hard-capped <=1 on 2b & <=2 on 3b cap-air: 2b=~s 3b=~s"
                (macro-brain-decision-scheduled-ids p-60-2b-cyber-cap1)
                (macro-brain-decision-scheduled-ids p-60-3b-cap-air-cyber-cap2)))

;; (9) #72 12PoolBot post-Nexus-cancel float (`f=2800`, `345M/120G`, 2 busy Gateways, 1 Zealot, 8 Lings):
;;     `protoss-12pool-2gate-cap-active?` lifts at >=275M & prioritizes Gateway #3 (`>=925.0 > cyber@600.0`),
;;     while negative guard at `240M < 275M` STILL caps Gateways at 2!
(reset-macro-escrow-tracker!)
(define p-72-345m-lifts-2gate-cap
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 2800
    #:minerals 345 #:gas 120 #:supply-used 19 #:supply-cap 31 #:workers 17 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 8 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'assimilator 1)
    #:unit-counts (hasheq 'probe 17 'zealot 1)
    #:enemy-unit-counts (hasheq 'zergling 8)
    #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(reset-macro-escrow-tracker!)
(define p-72-neg-240m-holds-2gate-cap
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 2800
    #:minerals 240 #:gas 120 #:supply-used 19 #:supply-cap 31 #:workers 17 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 8 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'assimilator 1)
    #:unit-counts (hasheq 'probe 17 'zealot 1)
    #:enemy-unit-counts (hasheq 'zergling 8)
    #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(check! (and (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-72-345m-lifts-2gate-cap))))
             (>= (cand-u p-72-345m-lifts-2gate-cap 'gateway) 925.0)
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-72-neg-240m-holds-2gate-cap)))
             (not (not (memq 'cybernetics-core (macro-brain-decision-scheduled-ids p-72-neg-240m-holds-2gate-cap)))))
        (format "L47-P0-2b(9) #72 12Pool @345M lifts 2-Gate cap for GW#3>=925 while @240M keeps 2-Gate cap: 345m=~s(u=~a) 240m=~s"
                (macro-brain-decision-scheduled-ids p-72-345m-lifts-2gate-cap)
                (cand-u p-72-345m-lifts-2gate-cap 'gateway)
                (macro-brain-decision-scheduled-ids p-72-neg-240m-holds-2gate-cap)))

;; (10) #53 zig-reapers exact f=2236 repro (`>= 2` pre-5:00 Reapers, 2 Marines, 0 Bunker, 0 Hellion):
;;      MUST defer `orbital-command` & `command-center #2` and train `marine`/`bunker`;
;;      negative guard: once `>= 6` Marines OR `>= 1` Bunker exist, `orbital-command` unlocks!
(reset-macro-escrow-tracker!)
(define t-53-reapers2-defer-oc-cc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 2236
    #:minerals 155 #:gas 84 #:supply-used 19 #:supply-cap 23 #:workers 17 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 2 'barracks 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 2 'barracks 1 'refinery 1)
    #:unit-counts (hasheq 'scv 17 'marine 2)
    #:enemy-unit-counts (hasheq 'reaper 2)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(reset-macro-escrow-tracker!)
(define t-53-neg-bunker-unlocks-oc
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 2600
    #:minerals 210 #:gas 60 #:supply-used 22 #:supply-cap 31 #:workers 18 #:active-bases 1
    #:mineral-harvesters 15 #:gas-harvesters 3
    #:army-supply 4 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 3 'barracks 1 'bunker 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 2 'supply-depot 3 'barracks 1 'bunker 1 'refinery 1)
    #:unit-counts (hasheq 'scv 18 'marine 4)
    #:enemy-unit-counts (hasheq 'reaper 2)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(check! (and (not (memq 'orbital-command (macro-brain-decision-scheduled-ids t-53-reapers2-defer-oc-cc)))
             (not (eq? (macro-brain-decision-saving-for t-53-reapers2-defer-oc-cc) 'orbital-command))
             (not (memq 'command-center (macro-brain-decision-scheduled-ids t-53-reapers2-defer-oc-cc)))
             (not (not (memq 'bunker (macro-brain-decision-scheduled-ids t-53-reapers2-defer-oc-cc))))
             (not (not (memq 'marine (macro-brain-decision-scheduled-ids t-53-reapers2-defer-oc-cc))))
             (not (not (memq 'orbital-command (macro-brain-decision-scheduled-ids t-53-neg-bunker-unlocks-oc)))))
        (format "L47-P0-2b(10) #53 >=2 Reapers MUST defer OC/CC for Bunker+Marine & unlock OC w/ Bunker: r2=~s/sav=~a neg=~s"
                (macro-brain-decision-scheduled-ids t-53-reapers2-defer-oc-cc)
                (macro-brain-decision-saving-for t-53-reapers2-defer-oc-cc)
                (macro-brain-decision-scheduled-ids t-53-neg-bunker-unlocks-oc)))

;; (11) #73 Z v who Mass Banshees:
;;      (a) f=5284 @ `55M/62G`, Lair morphing, 2 Spores, 3 Queens -> `queen` MUST hold blocking escrow (NO Zergling drain!)
;;      (b) f=5940 @ `110M/110G`, ready Lair, 3 bases, 2 Spores (<1/base), 3 Queens -> `spore-crawler` #3 (`>=1640`) locks AHEAD of HydraDen!
;;      (c) f=5960 @ `160M/110G`, ready Lair, 3 bases, 3 Spores, 3 Queens (<5) -> `queen` #4 (`>=1630`) locks AHEAD of HydraDen!
(reset-macro-escrow-tracker!)
(define z-73-banshee-queen-blocks-ling-55m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 5284
    #:minerals 55 #:gas 62 #:supply-used 38 #:supply-cap 52 #:workers 28 #:active-bases 2
    #:mineral-harvesters 22 #:gas-harvesters 6
    #:army-supply 10 #:enemy-threat-supply 6 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'spore-crawler 2 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 2 'extractor 2)
    #:unit-counts (hasheq 'drone 28 'queen 3 'zergling 6 'overlord 6)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 4))))
(reset-macro-escrow-tracker!)
(define z-73-banshee-spore3-over-hydraden
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 5940
    #:minerals 110 #:gas 110 #:supply-used 52 #:supply-cap 74 #:workers 36 #:active-bases 3
    #:mineral-harvesters 28 #:gas-harvesters 8
    #:army-supply 16 #:enemy-threat-supply 12 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 2 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 2 'extractor 3)
    #:unit-counts (hasheq 'drone 36 'queen 3 'zergling 10 'overlord 8)
    #:enemy-unit-counts (hasheq 'banshee 4)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'townhall 3 'larva 4))))
(reset-macro-escrow-tracker!)
(define z-73-banshee-queen4-over-hydraden
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 5960
    #:minerals 160 #:gas 110 #:supply-used 54 #:supply-cap 74 #:workers 36 #:active-bases 3
    #:mineral-harvesters 28 #:gas-harvesters 8
    #:army-supply 18 #:enemy-threat-supply 12 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 3 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 3 'extractor 3)
    #:unit-counts (hasheq 'drone 36 'queen 3 'zergling 10 'overlord 8)
    #:enemy-unit-counts (hasheq 'banshee 4)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'townhall 3 'larva 4))))
(check! (and (eq? (macro-brain-decision-saving-for z-73-banshee-queen-blocks-ling-55m) 'queen)
             (not (memq 'zergling (macro-brain-decision-scheduled-ids z-73-banshee-queen-blocks-ling-55m)))
             (not (not (memq 'spore-crawler (macro-brain-decision-scheduled-ids z-73-banshee-spore3-over-hydraden))))
             (>= (cand-u z-73-banshee-spore3-over-hydraden 'spore-crawler) 1640.0)
             (not (memq 'hydralisk-den (macro-brain-decision-scheduled-ids z-73-banshee-spore3-over-hydraden)))
             (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-73-banshee-queen4-over-hydraden))))
             (>= (cand-u z-73-banshee-queen4-over-hydraden 'queen) 1630.0)
             (not (memq 'hydralisk-den (macro-brain-decision-scheduled-ids z-73-banshee-queen4-over-hydraden))))
        (format "L47-P0-2b(11) #73 ZvT Banshees lock Queen@55M & Spore3(>=1640)/Queen4(>=1630) ahead of HydraDen: q55=~s/sav=~a sp3=~s(u=~a) q4=~s(u=~a)"
                (macro-brain-decision-scheduled-ids z-73-banshee-queen-blocks-ling-55m)
                (macro-brain-decision-saving-for z-73-banshee-queen-blocks-ling-55m)
                (macro-brain-decision-scheduled-ids z-73-banshee-spore3-over-hydraden)
                (cand-u z-73-banshee-spore3-over-hydraden 'spore-crawler)
                (macro-brain-decision-scheduled-ids z-73-banshee-queen4-over-hydraden)
                (cand-u z-73-banshee-queen4-over-hydraden 'queen)))

;; (12) Negative guard for #73 ZvT Banshee: Once >=1 Spore/base (3 on 3b) AND >=5 Queens exist,
;;      HydraliskDen schedules immediately!
(reset-macro-escrow-tracker!)
(define z-73-neg-5queens-3spores-builds-hydraden
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6200
    #:minerals 180 #:gas 120 #:supply-used 62 #:supply-cap 86 #:workers 38 #:active-bases 3
    #:mineral-harvesters 30 #:gas-harvesters 8
    #:army-supply 24 #:enemy-threat-supply 12 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 3 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 3 'extractor 3)
    #:unit-counts (hasheq 'drone 38 'queen 5 'zergling 10 'overlord 9)
    #:enemy-unit-counts (hasheq 'banshee 4)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'townhall 3 'larva 4))))
(check! (not (not (memq 'hydralisk-den (macro-brain-decision-scheduled-ids z-73-neg-5queens-3spores-builds-hydraden))))
        (format "L47-P0-2b(12) Neg guard: 3 Spores + 5 Queens on 3b immediately unlocks HydraliskDen: sched=~s"
                (macro-brain-decision-scheduled-ids z-73-neg-5queens-3spores-builds-hydraden)))

(reset-macro-escrow-tracker!)
(printf "verify_wave47_belief: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
