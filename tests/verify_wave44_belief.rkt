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
;; 1. L44-P0-2a: Protoss Gateway Cadence (#03 PvP / #04 PvT), PvPNatDelay 0->3,
;;               & Live Prod #5140062 Anti-Tempest PvP
;; ============================================================================

;; (1) H2H #03 PvP exact repro (f=5100, 2b/36w, 4 GW, open-robo=0, immortal=2, 320M):
;;     MUST hold Gateway #5+ (<400M) until Immortal #4 / 3rd Nexus, while TvP 2b/38w @ f=6900 (robo-bay=0) still scales 6 GW!
(reset-macro-escrow-tracker!)
(define p-03-pvp-hold-gw5
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 5100
    #:minerals 320 #:gas 110 #:supply-used 62 #:supply-cap 86 #:workers 36 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 8
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 36 'stalker 8 'immortal 2 'zealot 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 0))))
(reset-macro-escrow-tracker!)
(define p-tvp-2b-still-6gw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 6900
    #:minerals 210 #:gas 100 #:supply-used 66 #:supply-cap 94 #:workers 38 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 8
    #:army-supply 28 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 38 'stalker 10 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 1 'robotics-facility 0))))
(check! (and (not (memq 'gateway (macro-brain-decision-scheduled-ids p-03-pvp-hold-gw5)))
             (<= (cand-u p-03-pvp-hold-gw5 'gateway) 440.0)
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-tvp-2b-still-6gw))))
             (>= (cand-u p-tvp-2b-still-6gw 'gateway) 535.0))
        (format "L44-P0-2a(1) #03 PvP MUST hold GW#5+ before Immortal#4 while TvP 2b/38w@5m+ still scales 6GW: pvp=~s(u=~a) tvp=~s(u=~a)"
                (macro-brain-decision-scheduled-ids p-03-pvp-hold-gw5) (cand-u p-03-pvp-hold-gw5 'gateway)
                (macro-brain-decision-scheduled-ids p-tvp-2b-still-6gw) (cand-u p-tvp-2b-still-6gw 'gateway)))

;; (2) H2H #04 PvT 2b with RoboticsBay up & <2 Colossi (4 GW, 310M) -> MUST hold Gateway #5+ for Colossus #2 / Nexus #3;
;;     while 3b/50w @ 6 GW still scales cleanly to Gateway #7/#8!
(reset-macro-escrow-tracker!)
(define p-04-pvt-hold-gw5-for-colossus
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
(reset-macro-escrow-tracker!)
(define p-3b-50w-scale-8gw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9000
    #:minerals 240 #:gas 120 #:supply-used 94 #:supply-cap 130 #:workers 50 #:active-bases 3
    #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1 'twilight-council 1 'forge 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1 'twilight-council 1 'forge 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 50 'stalker 15 'immortal 2 'colossus 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 0 'robotics-facility 0))))
(check! (and (not (memq 'gateway (macro-brain-decision-scheduled-ids p-04-pvt-hold-gw5-for-colossus)))
             (<= (cand-u p-04-pvt-hold-gw5-for-colossus 'gateway) 440.0)
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-3b-50w-scale-8gw))))
             (>= (cand-u p-3b-50w-scale-8gw 'gateway) 535.0))
        (format "L44-P0-2a(2) #04 PvT 2b RoboBay/<2 Colossi MUST hold GW#5+ while 3b/50w still scales 8GW: pvt=~s(u=~a) 3b=~s(u=~a)"
                (macro-brain-decision-scheduled-ids p-04-pvt-hold-gw5-for-colossus) (cand-u p-04-pvt-hold-gw5-for-colossus 'gateway)
                (macro-brain-decision-scheduled-ids p-3b-50w-scale-8gw) (cand-u p-3b-50w-scale-8gw 'gateway)))

;; (3) PvPNatDelay 0->3 (#30/#51/#60 Creepy exact f=3136 repro @ 290M/100G, supply-used=38 > old 36 cap):
;;     MUST keep saving cleanly for Nexus #2 (u>=620), NEVER draining into Robo/Forge/Twilight/Gateway#3/Probe!
(reset-macro-escrow-tracker!)
(define p-60-pvp-nat-clean-save
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 3136
    #:minerals 290 #:gas 100 #:supply-used 38 #:supply-cap 47 #:workers 22 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 4 'adept 2)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'cybernetics-core 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-60-pvp-nat-clean-save) 'nexus)
             (>= (cand-u p-60-pvp-nat-clean-save 'nexus) 620.0)
             (not (memq 'robotics-facility (macro-brain-decision-scheduled-ids p-60-pvp-nat-clean-save)))
             (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-60-pvp-nat-clean-save)))
             (not (memq 'forge (macro-brain-decision-scheduled-ids p-60-pvp-nat-clean-save)))
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-60-pvp-nat-clean-save)))
             (not (memq 'probe (macro-brain-decision-scheduled-ids p-60-pvp-nat-clean-save))))
        (format "L44-P0-2a(3) #60 PvP natural save @290M/38sup MUST lock Nexus>=620 over Robo/Forge/Twilight/GW/Probe: save=~a u=~a sched=~s"
                (macro-brain-decision-saving-for p-60-pvp-nat-clean-save)
                (cand-u p-60-pvp-nat-clean-save 'nexus)
                (macro-brain-decision-scheduled-ids p-60-pvp-nat-clean-save)))

;; (4) PvPNatDelay Negative Guard: Proxy threat (enemy Cannon / threat=6) MUST STILL block 1-base Natural Nexus!
(reset-macro-escrow-tracker!)
(define p-pvp-proxy-still-blocks-nat
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 2900
    #:minerals 290 #:gas 100 #:supply-used 28 #:supply-cap 39 #:workers 20 #:active-bases 1
    #:mineral-harvesters 14 #:gas-harvesters 6
    #:army-supply 6 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 20 'stalker 3)
    #:enemy-building-counts (hasheq 'forge 1 'photon-cannon 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 2))))
(check! (and (not (eq? (macro-brain-decision-saving-for p-pvp-proxy-still-blocks-nat) 'nexus))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvp-proxy-still-blocks-nat))))
        (format "L44-P0-2a(4) PvP proxy threat MUST still block 1-base Natural Nexus: save=~a sched=~s"
                (macro-brain-decision-saving-for p-pvp-proxy-still-blocks-nat)
                (macro-brain-decision-scheduled-ids p-pvp-proxy-still-blocks-nat)))

;; (5) Live Prod #5140062 Anti-Tempest PvP: >=2 Tempests on 4 GW / 0 Stargate @ 220M/115G (<150G!)
;;     MUST escrow Stargate #1 (u>=885) strictly above Stalker@840, then unlock Blink (u>=848) + VoidRay (u>=1520) + Stargate #2!
(reset-macro-escrow-tracker!)
(define p-5140062-tempest-sg1-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 8200
    #:minerals 220 #:gas 115 #:supply-used 76 #:supply-cap 110 #:workers 40 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 10
    #:army-supply 36 #:enemy-threat-supply 16 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 40 'stalker 8 'immortal 3 'observer 1)
    #:enemy-unit-counts (hasheq 'tempest 4)
    #:enemy-building-counts (hasheq 'stargate 2 'fleet-beacon 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1 'twilight-council 1))))
(reset-macro-escrow-tracker!)
(define p-5140062-tempest-vr-blink-sg2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 9400
    #:minerals 560 #:gas 460 #:supply-used 92 #:supply-cap 130 #:workers 46 #:active-bases 3
    #:mineral-harvesters 34 #:gas-harvesters 12
    #:army-supply 46 #:enemy-threat-supply 24 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 15 'gateway 6 'cybernetics-core 1
                                    'stargate 1 'fleet-beacon 1 'twilight-council 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 15 'gateway 6 'cybernetics-core 1
                                    'stargate 1 'fleet-beacon 1 'twilight-council 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 46 'stalker 10 'void-ray 2 'observer 1)
    #:enemy-unit-counts (hasheq 'tempest 6)
    #:enemy-building-counts (hasheq 'stargate 2 'fleet-beacon 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'stargate 1 'twilight-council 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-5140062-tempest-sg1-escrow) 'stargate)
             (>= (cand-u p-5140062-tempest-sg1-escrow 'stargate) 885.0)
             (not (memq 'stalker (macro-brain-decision-scheduled-ids p-5140062-tempest-sg1-escrow)))
             (not (not (memq 'void-ray (macro-brain-decision-scheduled-ids p-5140062-tempest-vr-blink-sg2))))
             (not (not (memq 'stargate (macro-brain-decision-scheduled-ids p-5140062-tempest-vr-blink-sg2))))
             (not (not (memq 'blink (macro-brain-decision-scheduled-ids p-5140062-tempest-vr-blink-sg2))))
             (>= (cand-u p-5140062-tempest-vr-blink-sg2 'blink) 848.0))
        (format "L44-P0-2a(5) #5140062 Anti-Tempest MUST escrow SG#1@115G(u>=885) & unlock VoidRay+SG#2+Blink(u>=848): sg1=~a(u=~a,sc=~s) combo=~s(bu=~a)"
                (macro-brain-decision-saving-for p-5140062-tempest-sg1-escrow)
                (cand-u p-5140062-tempest-sg1-escrow 'stargate)
                (macro-brain-decision-scheduled-ids p-5140062-tempest-sg1-escrow)
                (macro-brain-decision-scheduled-ids p-5140062-tempest-vr-blink-sg2)
                (cand-u p-5140062-tempest-vr-blink-sg2 'blink)))

;; (6) Live Prod #5140062 Anti-Tempest PvP: High Stalker floor (>=18, still pumping @ 12 Stalkers!)
;;     & Gateway #7/#8 scaling (u>=610) on 3 bases!
(reset-macro-escrow-tracker!)
(define p-5140062-tempest-stalker18-gw8
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 10200
    #:minerals 360 #:gas 120 #:supply-used 112 #:supply-cap 150 #:workers 50 #:active-bases 3
    #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 62 #:enemy-threat-supply 36 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 18 'gateway 6 'cybernetics-core 1
                                    'stargate 2 'fleet-beacon 1 'twilight-council 1 'assimilator 6)
    #:total-building-counts (hasheq 'nexus 3 'pylon 18 'gateway 6 'cybernetics-core 1
                                    'stargate 2 'fleet-beacon 1 'twilight-council 1 'assimilator 6)
    #:unit-counts (hasheq 'probe 50 'stalker 12 'void-ray 4 'observer 1)
    #:researched-upgrades '(blink warp-gate-research)
    #:enemy-unit-counts (hasheq 'tempest 10)
    #:enemy-building-counts (hasheq 'stargate 3 'fleet-beacon 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 1 'stargate 0 'twilight-council 1))))
(check! (and (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-5140062-tempest-stalker18-gw8))))
             (>= (cand-u p-5140062-tempest-stalker18-gw8 'stalker) 840.0)
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-5140062-tempest-stalker18-gw8))))
             (>= (cand-u p-5140062-tempest-stalker18-gw8 'gateway) 610.0))
        (format "L44-P0-2a(6) #5140062 Anti-Tempest @12 Stalkers MUST pump Stalker>=840 (floor 18+) & GW#7-8>=610: sched=~s su=~a gwu=~a"
                (macro-brain-decision-scheduled-ids p-5140062-tempest-stalker18-gw8)
                (cand-u p-5140062-tempest-stalker18-gw8 'stalker)
                (cand-u p-5140062-tempest-stalker18-gw8 'gateway)))

;; ============================================================================
;; 2. L44-P0-2b: #62 SmoothBrain (TvT0Tank -> 0), #72 12PoolBot (Nexus #2 Defer),
;;               & #73/#75 who Mass Banshee (CloakLoss -> 0)
;; ============================================================================

;; (7) #62 SmoothBrain TvT: Once >=2 Turrets (+1 Viking) are up vs StarportTL / 1 Banshee,
;;     MUST unlock FactoryTechLab #1 (u>=890) & SiegeTank #1-2 (u>=660, 125G) instead of starving behind Viking #2-4!
(reset-macro-escrow-tracker!)
(define t-62-turrets-unlock-factl1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 7940
    #:minerals 140 #:gas 110 #:supply-used 52 #:supply-cap 78 #:workers 34 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 8
    #:army-supply 18 #:enemy-threat-supply 4 #:under-attack? #f #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2
                                    'factory 1 'starport 1 'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2
                                    'factory 1 'starport 1 'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:unit-counts (hasheq 'scv 34 'marine 14 'viking-fighter 1)
    #:enemy-unit-counts (hasheq 'banshee 1)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1))))
(reset-macro-escrow-tracker!)
(define t-62-turrets-unlock-tank1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 8400
    #:minerals 180 #:gas 130 #:supply-used 56 #:supply-cap 78 #:workers 36 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 8
    #:army-supply 20 #:enemy-threat-supply 4 #:under-attack? #f #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2
                                    'factory 1 'factory-techlab 1 'starport 1
                                    'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2
                                    'factory 1 'factory-techlab 1 'starport 1
                                    'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:unit-counts (hasheq 'scv 36 'marine 16 'viking-fighter 1)
    #:enemy-unit-counts (hasheq 'banshee 1)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1))))
(check! (and (not (not (memq 'factory-techlab (macro-brain-decision-scheduled-ids t-62-turrets-unlock-factl1))))
             (>= (cand-u t-62-turrets-unlock-factl1 'factory-techlab) 890.0)
             (not (not (memq 'siege-tank (macro-brain-decision-scheduled-ids t-62-turrets-unlock-tank1))))
             (>= (cand-u t-62-turrets-unlock-tank1 'siege-tank) 660.0))
        (format "L44-P0-2b(7) #62 TvT Turrets+1 Viking MUST unlock FactoryTechLab#1>=890 & SiegeTank#1>=660: ftl=~s(u=~a) tk=~s(u=~a)"
                (macro-brain-decision-scheduled-ids t-62-turrets-unlock-factl1)
                (cand-u t-62-turrets-unlock-factl1 'factory-techlab)
                (macro-brain-decision-scheduled-ids t-62-turrets-unlock-tank1)
                (cand-u t-62-turrets-unlock-tank1 'siege-tank)))

;; (8) #62 SmoothBrain Negative Guards:
;;     (a) Hellion #2 blocked before FactoryTechLab #1 in TvT when <3 Reapers (even under attack!)
;;     (b) #74 Multi-Banshee (2 Banshees, 1 Viking, open Starport) STILL prioritizes Viking #2 (u>=940) over Tank!
(reset-macro-escrow-tracker!)
(define t-62-no-hellion2-before-factl1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 4200
    #:minerals 140 #:gas 55 #:supply-used 30 #:supply-cap 46 #:workers 22 #:active-bases 2
    #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 8 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 1 'factory 1 'refinery 2)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 1 'factory 1 'refinery 2)
    #:unit-counts (hasheq 'scv 22 'marine 6 'hellion 1)
    #:enemy-unit-counts (hasheq 'reaper 2 'marine 4)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 1 'factory 1))))
(reset-macro-escrow-tracker!)
(define t-74-2banshee-still-viking2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 6000
    #:minerals 160 #:gas 130 #:supply-used 48 #:supply-cap 70 #:workers 32 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 16 #:enemy-threat-supply 6 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2
                                    'factory 1 'factory-techlab 1 'starport 1
                                    'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2
                                    'factory 1 'factory-techlab 1 'starport 1
                                    'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:unit-counts (hasheq 'scv 32 'marine 12 'viking-fighter 1)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1))))
(check! (and (not (memq 'hellion (macro-brain-decision-scheduled-ids t-62-no-hellion2-before-factl1)))
             (not (not (memq 'factory-techlab (macro-brain-decision-scheduled-ids t-62-no-hellion2-before-factl1))))
             (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-74-2banshee-still-viking2))))
             (not (memq 'siege-tank (macro-brain-decision-scheduled-ids t-74-2banshee-still-viking2))))
        (format "L44-P0-2b(8) #62 blocks Hellion#2 before FactoryTL#1 (<3 Reapers) & #74 2-Banshee still prioritizes Viking#2: h2=~s v2=~s"
                (macro-brain-decision-scheduled-ids t-62-no-hellion2-before-factl1)
                (macro-brain-decision-scheduled-ids t-74-2banshee-still-viking2)))

;; (9) #72 12PoolBot: Strictly block 400M Nexus #2 on >=4 Lings (<150s) OR <60s early SpawningPool,
;;     spending immediately on Zealot + Gateway #2!
(reset-macro-escrow-tracker!)
(define p-72-4lings-block-nexus2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 1732
    #:minerals 410 #:gas 0 #:supply-used 18 #:supply-cap 23 #:workers 18 #:active-bases 1
    #:mineral-harvesters 18 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 2 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 18)
    #:enemy-unit-counts (hasheq 'zergling 4)
    #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(reset-macro-escrow-tracker!)
(define p-72-early-pool-block-nexus2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 1250
    #:minerals 410 #:gas 0 #:supply-used 17 #:supply-cap 23 #:workers 17 #:active-bases 1
    #:mineral-harvesters 17 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
    #:unit-counts (hasheq 'probe 17)
    #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 2)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(check! (and (not (memq 'nexus (macro-brain-decision-scheduled-ids p-72-4lings-block-nexus2)))
             (not (eq? (macro-brain-decision-saving-for p-72-4lings-block-nexus2) 'nexus))
             (not (not (memq 'zealot (macro-brain-decision-scheduled-ids p-72-4lings-block-nexus2))))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-72-4lings-block-nexus2))))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-72-early-pool-block-nexus2)))
             (not (eq? (macro-brain-decision-saving-for p-72-early-pool-block-nexus2) 'nexus))
             (not (not (memq 'zealot (macro-brain-decision-scheduled-ids p-72-early-pool-block-nexus2)))))
        (format "L44-P0-2b(9) #72 12Pool (>=4 Lings or <60s Pool) MUST block Nexus#2 @410M & train Zealot+GW#2: l4=~s(s=~a) p60=~s(s=~a)"
                (macro-brain-decision-scheduled-ids p-72-4lings-block-nexus2)
                (macro-brain-decision-saving-for p-72-4lings-block-nexus2)
                (macro-brain-decision-scheduled-ids p-72-early-pool-block-nexus2)
                (macro-brain-decision-saving-for p-72-early-pool-block-nexus2)))

;; (10) #73 Z v who Mass Banshee: Defer BanelingNest, Baneling morphs, and SpineCrawler #2 (>=1 existing)
;;      while Banshees/StarportTL are scouted & Hydralisk < 8 (even w/ 8 enemy Marines & HydraDen already started)!
(reset-macro-escrow-tracker!)
(define z-73-banshee-defer-bn-spine2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6200
    #:minerals 280 #:gas 140 #:supply-used 60 #:supply-cap 86 #:workers 36 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 8
    #:army-supply 24 #:enemy-threat-supply 12 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'spore-crawler 2 'spine-crawler 1 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'hydralisk-den 1 'spore-crawler 2 'spine-crawler 1 'extractor 3)
    #:unit-counts (hasheq 'drone 36 'queen 4 'zergling 14 'overlord 9)
    #:enemy-unit-counts (hasheq 'banshee 2 'marine 8)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 6))))
(reset-macro-escrow-tracker!)
(define z-73-banshee-defer-bane-morph
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6400
    #:minerals 220 #:gas 140 #:supply-used 62 #:supply-cap 86 #:workers 36 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 8
    #:army-supply 26 #:enemy-threat-supply 12 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'baneling-nest 1 'hydralisk-den 1
                                    'spore-crawler 2 'spine-crawler 1 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'baneling-nest 1 'hydralisk-den 1
                                    'spore-crawler 2 'spine-crawler 1 'extractor 3)
    #:unit-counts (hasheq 'drone 36 'queen 5 'zergling 14 'hydralisk 2 'overlord 9)
    #:enemy-unit-counts (hasheq 'banshee 2 'marine 8)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 5))))
(check! (and (not (memq 'baneling-nest (macro-brain-decision-scheduled-ids z-73-banshee-defer-bn-spine2)))
             (not (memq 'spine-crawler (macro-brain-decision-scheduled-ids z-73-banshee-defer-bn-spine2)))
             (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-73-banshee-defer-bn-spine2))))
             (not (memq 'baneling (macro-brain-decision-scheduled-ids z-73-banshee-defer-bane-morph)))
             (not (memq 'spine-crawler (macro-brain-decision-scheduled-ids z-73-banshee-defer-bane-morph)))
             (not (not (memq 'hydralisk (macro-brain-decision-scheduled-ids z-73-banshee-defer-bane-morph)))))
        (format "L44-P0-2b(10) #73 ZvT Banshees MUST defer BanelingNest/Baneling/Spine#2 for Queen+Hydra: bn=~s bm=~s"
                (macro-brain-decision-scheduled-ids z-73-banshee-defer-bn-spine2)
                (macro-brain-decision-scheduled-ids z-73-banshee-defer-bane-morph)))

;; (11) #75 P v who Mass Banshee: Gateway #3 boosted (u>=845) ahead of Assimilator #3 & ShieldBattery #2,
;;      AND Stalker floor raised 8 -> 10 (still pumping @ 8 Stalkers)!
(reset-macro-escrow-tracker!)
(define p-75-banshee-gate3-over-assim3-sb2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 5450
    #:minerals 160 #:gas 60 #:supply-used 46 #:supply-cap 70 #:workers 32 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 14 #:enemy-threat-supply 6 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 32 'stalker 4 'observer 1 'zealot 2)
    #:enemy-unit-counts (hasheq 'banshee 3)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-75-banshee-stalker-floor-10
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 6200
    #:minerals 200 #:gas 90 #:supply-used 58 #:supply-cap 86 #:workers 34 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 6
    #:army-supply 24 #:enemy-threat-supply 8 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 34 'stalker 8 'observer 1)
    #:enemy-unit-counts (hasheq 'banshee 3)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 1))))
(check! (and (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-75-banshee-gate3-over-assim3-sb2))))
             (>= (cand-u p-75-banshee-gate3-over-assim3-sb2 'gateway) 845.0)
             (not (memq 'assimilator (macro-brain-decision-scheduled-ids p-75-banshee-gate3-over-assim3-sb2)))
             (not (memq 'shield-battery (macro-brain-decision-scheduled-ids p-75-banshee-gate3-over-assim3-sb2)))
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-75-banshee-stalker-floor-10))))
             (>= (cand-u p-75-banshee-stalker-floor-10 'stalker) 840.0)
             (not (memq 'assimilator (macro-brain-decision-scheduled-ids p-75-banshee-stalker-floor-10)))
             (not (memq 'shield-battery (macro-brain-decision-scheduled-ids p-75-banshee-stalker-floor-10))))
        (format "L44-P0-2b(11) #75 PvT Banshees MUST build GW#3>=845 over Assim#3/SB#2 & pump Stalker@8 (floor 10): g3=~s(u=~a) s10=~s(u=~a)"
                (macro-brain-decision-scheduled-ids p-75-banshee-gate3-over-assim3-sb2)
                (cand-u p-75-banshee-gate3-over-assim3-sb2 'gateway)
                (macro-brain-decision-scheduled-ids p-75-banshee-stalker-floor-10)
                (cand-u p-75-banshee-stalker-floor-10 'stalker)))

;; (12) #75 P v who Non-Stall Guard: When Gateways #1-2 are OPEN with 160M/60G, train Stalker FIRST (0 idle GW frame);
;;      when bank >= 275M/60G, schedule BOTH Gateway #3 AND Stalker on the same frame!
(reset-macro-escrow-tracker!)
(define p-75-open-gw-stalker-first
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 5450
    #:minerals 160 #:gas 60 #:supply-used 44 #:supply-cap 70 #:workers 32 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 6 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 32 'stalker 3 'observer 1 'zealot 2)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-75-290m-both-gw3-and-stalker
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 5460
    #:minerals 290 #:gas 60 #:supply-used 44 #:supply-cap 70 #:workers 32 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 6 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 2 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 32 'stalker 3 'observer 1 'zealot 2)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 1))))
(check! (and (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-75-open-gw-stalker-first))))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-75-290m-both-gw3-and-stalker))))
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-75-290m-both-gw3-and-stalker)))))
        (format "L44-P0-2b(12) #75 open-GW@160M trains Stalker first & @290M schedules BOTH GW#3+Stalker: s1=~s both=~s"
                (macro-brain-decision-scheduled-ids p-75-open-gw-stalker-first)
                (macro-brain-decision-scheduled-ids p-75-290m-both-gw3-and-stalker)))

(printf "verify_wave44_belief: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
