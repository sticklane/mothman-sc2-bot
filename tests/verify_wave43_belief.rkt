#lang racket

;; ============================================================================
;; Loop 43 Track 3 (`L43-P0-2a..2b`) Belief & Macro Verification Suite (12 checks)
;; 1. L43-P0-2a:
;;    (1) `opponent-world-model.rkt` death-Broodling + Hallucination guard
;;        (`PolyMorph T` `141`-tick Viking leak: killing a Zerg building spawns
;;        `broodling`s — NEVER imply `greater-spire`/`spire`/`hive` or AA!)
;;    (2) Zero-Air Terran `viking-fighter` guard (exclude pure `overlord`/ground
;;        armies from Viking production; keep real air / Spire / TvT allowed)
;;    (3) `#62 SmoothBrain` `TvT0Tank` extension: block `medivac`, `armory`,
;;        `widow-mine`, and 2nd `engineering-bay` while TvT `siege-tank < 4`
;;    (4) `H2H #02 TvT`: cap TvT `medivac <= 6` (`<= 4` when trailing enemy
;;        Vikings/Tanks) & boost Viking parity (`>= enemy-vikings + 2`) once >=4 Tanks
;; 2. L43-P0-2b:
;;    (5) `#72 12PoolBot`: strict `2`-Gate cap `< 150s` (`frame < 3360`) on >=6 Lings
;;        while `zealot <= 2` -> spend on `zealot` + `1` wall `shield-battery` + `cybernetics-core`
;;    (6) `#53 zig-reapers`: `>= 4` Reapers in TvT -> prioritize `bunker` + `hellion`/`marine`
;;        strictly ahead of `marauder`, `engineering-bay`, `widow-mine`, `barracks-techlab`, `orbital-command`
;;    (7) `#53 zig-reapers`: once `bunker >= 1`, prioritize `barracks-reactor` + `hellion`
;;    (8) Mass-Roach PvZ (`Clicadinha P`): `>= 6` Roaches -> lock `immortal` floor `>= 4`
;;        ahead of `twilight-council`, extra `zealot`s, `forge`, and 3rd `nexus`
;;    (9) Mass-Roach PvZ (`Clicadinha P`): `>= 6` Roaches w/ 0 Robo -> prioritize
;;        `robotics-facility #1` ahead of `twilight-council` & extra `zealot`s
;;   (10) Anti-Mass-Stalker PvP (`#5138711 PrismForge`): cap `phoenix <= 2` vs
;;        `>= 15` Stalkers & `0` Stargate air, funneling into `immortal` + `8` Gateways on 3 bases
;;   (11) Negative guard: PvP WITH enemy Stargate/Phoenixes still allows `> 2` Phoenixes
;;   (12) Negative guards: PvZ Mass-Roach lock releases at `>= 4` Immortals &
;;        TvT Tank4 lock releases on confirmed Banshees (`terran-tvt-tank4-air-override?`)
;; ============================================================================

(require "../lib/priority-macro-brain.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/opponent-world-model.rkt")

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

(define (cand-blk dec sym)
  (define trace
    (hash-ref (priority-schedule-result-category-utilities
               (macro-brain-decision-priority-schedule dec))
              'decision-trace '()))
  (for/or ([e (in-list trace)])
    (and (eq? (priority-decision-entry-id e) sym)
         (priority-decision-entry-blocking-allowed? e))))

(define (res-gas-floor dec)
  (hash-ref (priority-schedule-result-category-utilities
             (macro-brain-decision-priority-schedule dec))
            'reserved-gas-floor 0))

;; ============================================================================
;; 1. L43-P0-2a: PolyMorph T Broodling/Hallucination OWM Fix + Zero-Air Viking
;;               + #62 SmoothBrain Tank4 Lock + H2H #02 TvT Medivac Cap
;; ============================================================================

;; (1) OWM: Killed Zerg building spawning `broodling`s & Protoss `halluc?` units NEVER imply
;;     `greater-spire`/`spire`/`hive`/`fleet-beacon`, while real `brood-lord` STILL implies `greater-spire`!
(define owm-z-broodling (make-opponent-world-model 'Zerg))
(define sum-z-broodling
  (step-opponent-world-model!
   owm-z-broodling
   (hash 'frame 7500 'enemy-race 'Zerg
         'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 140.0 'enemy-exp-y 144.0
         'ally-units (list (hash 'id 1 'type 'marine 'x 135.0 'y 140.0 'hp 45))
         'enemy-units (list (hash 'id 201 'type 'roach 'x 142.0 'y 142.0 'hp 145)
                            (hash 'id 202 'type 'hydralisk 'x 144.0 'y 142.0 'hp 90)
                            (hash 'id 203 'type 'overlord 'x 146.0 'y 144.0 'hp 200)
                            (hash 'id 204 'type 'broodling 'x 140.0 'y 144.0 'hp 30)
                            (hash 'id 205 'type 'broodling 'x 141.0 'y 144.0 'hp 30))
         'enemy-buildings (list (hash 'id 301 'type 'hatchery 'x 160.0 'y 160.0 'hp 1500 'build-progress 1.0)
                                (hash 'id 302 'type 'roach-warren 'x 158.0 'y 158.0 'hp 850 'build-progress 1.0)))))
(define bldgs-z-broodling (opponent-world-summary-known-bldg-counts sum-z-broodling))

(define owm-p-halluc (make-opponent-world-model 'Protoss))
(define sum-p-halluc
  (step-opponent-world-model!
   owm-p-halluc
   (hash 'frame 6000 'enemy-race 'Protoss
         'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 140.0 'enemy-exp-y 144.0
         'ally-units (list (hash 'id 1 'type 'marine 'x 135.0 'y 140.0 'hp 45))
         'enemy-units (list (hash 'id 401 'type 'stalker 'x 142.0 'y 142.0 'hp 160)
                            (hash 'id 402 'type 'carrier 'x 144.0 'y 142.0 'hp 300 'is-hallucination #t)
                            (hash 'id 403 'type 'void-ray 'x 145.0 'y 142.0 'hp 250 'is-hallucination #t))
         'enemy-buildings (list (hash 'id 501 'type 'nexus 'x 160.0 'y 160.0 'hp 2000 'build-progress 1.0)))))
(define bldgs-p-halluc (opponent-world-summary-known-bldg-counts sum-p-halluc))

(define owm-z-real-bl (make-opponent-world-model 'Zerg))
(define sum-z-real-bl
  (step-opponent-world-model!
   owm-z-real-bl
   (hash 'frame 12000 'enemy-race 'Zerg
         'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0
         'enemy-x 160.0 'enemy-y 160.0 'enemy-exp-x 140.0 'enemy-exp-y 144.0
         'ally-units (list (hash 'id 1 'type 'marine 'x 135.0 'y 140.0 'hp 45))
         'enemy-units (list (hash 'id 601 'type 'brood-lord 'x 142.0 'y 142.0 'hp 225))
         'enemy-buildings (list (hash 'id 701 'type 'hatchery 'x 160.0 'y 160.0 'hp 1500 'build-progress 1.0)))))
(define bldgs-z-real-bl (opponent-world-summary-known-bldg-counts sum-z-real-bl))

(check! (and (= (hash-ref bldgs-z-broodling 'greater-spire 0) 0)
             (= (hash-ref bldgs-z-broodling 'spire 0) 0)
             (= (hash-ref bldgs-z-broodling 'hive 0) 0)
             (not (opponent-world-summary-requires-anti-air? sum-z-broodling))
             (= (hash-ref bldgs-p-halluc 'fleet-beacon 0) 0)
             (= (hash-ref bldgs-p-halluc 'stargate 0) 0)
             (not (opponent-world-summary-requires-anti-air? sum-p-halluc))
             (> (hash-ref bldgs-z-real-bl 'greater-spire 0) 0)
             (opponent-world-summary-requires-anti-air? sum-z-real-bl))
        (format "L43-P0-2a(1) OWM: death broodling & halluc? must NEVER imply greater-spire/fleet-beacon/AA while real brood-lord does: z=~s aa=~a p=~s paa=~a bl=~s"
                bldgs-z-broodling (opponent-world-summary-requires-anti-air? sum-z-broodling)
                bldgs-p-halluc (opponent-world-summary-requires-anti-air? sum-p-halluc)
                bldgs-z-real-bl))

;; (2) PolyMorph T Zero-Air Viking Guard: Pure ground Roach/Hydra + 8 Overlords (even with requires-anti-air? #t)
;;     MUST NOT schedule or escrow `viking-fighter`; real Mutalisk / Spire MUST still allow `viking-fighter`!
(reset-macro-escrow-tracker!)
(define t-polymorph-zero-air
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Zerg #:frame 7500
    #:minerals 250 #:gas 180 #:supply-used 60 #:supply-cap 78 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 18 #:enemy-threat-supply 20 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 4 'barracks-reactor 2
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-reactor 1 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 14 'marauder 4 'siege-tank 2 'medivac 2)
    #:enemy-unit-counts (hasheq 'roach 22 'hydralisk 8 'queen 5 'zergling 12 'overlord 8 'broodling 4)
    #:enemy-building-counts (hasheq 'hatchery 4 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 3 'factory 1 'starport 2))))
(reset-macro-escrow-tracker!)
(define t-tvz-muta-allows-viking
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Zerg #:frame 7500
    #:minerals 350 #:gas 250 #:supply-used 60 #:supply-cap 78 #:workers 46 #:active-bases 3
    #:mineral-harvesters 34 #:gas-harvesters 12
    #:army-supply 20 #:enemy-threat-supply 18 #:under-attack? #t #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 10 'barracks 4 'factory 1 'factory-techlab 1
                                    'starport 1 'starport-reactor 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 10 'barracks 4 'factory 1 'factory-techlab 1
                                    'starport 1 'starport-reactor 1 'refinery 4)
    #:unit-counts (hasheq 'scv 46 'marine 14 'siege-tank 2 'medivac 2)
    #:enemy-unit-counts (hasheq 'mutalisk 8 'zergling 10 'overlord 6)
    #:enemy-building-counts (hasheq 'hatchery 3 'spire 1)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 2 'factory 0 'starport 2))))
(check! (and (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-polymorph-zero-air)))
             (not (eq? (macro-brain-decision-saving-for t-polymorph-zero-air) 'viking-fighter))
             (not (cand-blk t-polymorph-zero-air 'viking-fighter))
             (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-tvz-muta-allows-viking)))))
        (format "L43-P0-2a(2) PolyMorph Zero-Air Viking guard: zero-air sched=~s save=~a blk=~a | muta sched=~s"
                (macro-brain-decision-scheduled-ids t-polymorph-zero-air)
                (macro-brain-decision-saving-for t-polymorph-zero-air)
                (cand-blk t-polymorph-zero-air 'viking-fighter)
                (macro-brain-decision-scheduled-ids t-tvz-muta-allows-viking)))

;; (3) #62 SmoothBrain TvT0Tank: While SiegeTank < 4 in TvT (no Banshee/Cloak, < 2 combat air),
;;     MUST block `medivac`, `armory`, `widow-mine`, AND 2nd `engineering-bay` from draining gas/minerals!
(reset-macro-escrow-tracker!)
(define t-62-tank4-block-medivac-armory-wm-ebay2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 6900
    #:minerals 220 #:gas 160 #:supply-used 56 #:supply-cap 78 #:workers 38 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 10
    #:army-supply 18 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-reactor 1
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-reactor 1
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 3)
    #:unit-counts (hasheq 'scv 38 'marine 14 'siege-tank 1)
    #:enemy-unit-counts (hasheq 'marine 16 'siege-tank 4)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 0 'starport 1))))
(reset-macro-escrow-tracker!)
(define t-62-tank4-open-fac-saves-tank
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 6900
    #:minerals 160 #:gas 115 #:supply-used 56 #:supply-cap 78 #:workers 38 #:active-bases 2
    #:mineral-harvesters 28 #:gas-harvesters 10
    #:army-supply 18 #:enemy-threat-supply 12 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-reactor 1
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-reactor 1
                                    'factory 1 'factory-techlab 1 'starport 1 'engineering-bay 1 'refinery 3)
    #:unit-counts (hasheq 'scv 38 'marine 14 'siege-tank 1)
    #:enemy-unit-counts (hasheq 'marine 16 'siege-tank 4)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1))))
(check! (and (not (memq 'medivac (macro-brain-decision-scheduled-ids t-62-tank4-block-medivac-armory-wm-ebay2)))
             (not (memq 'armory (macro-brain-decision-scheduled-ids t-62-tank4-block-medivac-armory-wm-ebay2)))
             (not (memq 'widow-mine (macro-brain-decision-scheduled-ids t-62-tank4-block-medivac-armory-wm-ebay2)))
             (not (memq 'engineering-bay (macro-brain-decision-scheduled-ids t-62-tank4-block-medivac-armory-wm-ebay2)))
             (not (eq? (macro-brain-decision-saving-for t-62-tank4-block-medivac-armory-wm-ebay2) 'armory))
             (not (eq? (macro-brain-decision-saving-for t-62-tank4-block-medivac-armory-wm-ebay2) 'engineering-bay))
             (eq? (macro-brain-decision-saving-for t-62-tank4-open-fac-saves-tank) 'siege-tank)
             (>= (res-gas-floor t-62-tank4-open-fac-saves-tank) 125))
        (format "L43-P0-2a(3) #62 SmoothBrain Tank4 lock: busy-sched=~s busy-save=~a | open-save=~a gfl=~a"
                (macro-brain-decision-scheduled-ids t-62-tank4-block-medivac-armory-wm-ebay2)
                (macro-brain-decision-saving-for t-62-tank4-block-medivac-armory-wm-ebay2)
                (macro-brain-decision-saving-for t-62-tank4-open-fac-saves-tank)
                (res-gas-floor t-62-tank4-open-fac-saves-tank)))

;; (4) H2H #02 TvT Medivac Cap (<= 4..6) + Viking Air Control (>= enemy-vikings + 2) once >= 4 Tanks!
(reset-macro-escrow-tracker!)
(define t-02-tvt-medivac-cap-and-vikings
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 12000
    #:minerals 360 #:gas 240 #:supply-used 110 #:supply-cap 142 #:workers 54 #:active-bases 3
    #:mineral-harvesters 40 #:gas-harvesters 14
    #:army-supply 56 #:enemy-threat-supply 34 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 3 'supply-depot 16 'barracks 5 'barracks-reactor 2 'barracks-techlab 2
                                    'factory 2 'factory-techlab 2 'starport 2 'starport-reactor 1 'engineering-bay 2 'armory 1 'refinery 6)
    #:total-building-counts (hasheq 'orbital-command 3 'supply-depot 16 'barracks 5 'barracks-reactor 2 'barracks-techlab 2
                                    'factory 2 'factory-techlab 2 'starport 2 'starport-reactor 1 'engineering-bay 2 'armory 1 'refinery 6)
    #:unit-counts (hasheq 'scv 54 'marine 24 'marauder 6 'siege-tank 5 'medivac 6 'viking-fighter 4)
    #:enemy-unit-counts (hasheq 'marine 24 'siege-tank 6 'medivac 4 'viking-fighter 8)
    #:open-facility-slots (hasheq 'townhall 3 'barracks 3 'factory 0 'starport 2))))
(check! (and (not (memq 'medivac (macro-brain-decision-scheduled-ids t-02-tvt-medivac-cap-and-vikings)))
             (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-02-tvt-medivac-cap-and-vikings))))
             (>= (cand-u t-02-tvt-medivac-cap-and-vikings 'viking-fighter) 635.0)
             (cand-blk t-02-tvt-medivac-cap-and-vikings 'viking-fighter))
        (format "L43-P0-2a(4) H2H #02 TvT: cap Medivac<=6 & boost Viking parity>=635: sched=~s u_vik=~a blk=~a"
                (macro-brain-decision-scheduled-ids t-02-tvt-medivac-cap-and-vikings)
                (cand-u t-02-tvt-medivac-cap-and-vikings 'viking-fighter)
                (cand-blk t-02-tvt-medivac-cap-and-vikings 'viking-fighter)))

;; ============================================================================
;; 2. L43-P0-2b: #72 12PoolBot 2-Gate Cap + #53 Reapers + PvZ Mass-Roach Immortals
;;               + PvP Anti-Mass-Stalker Phoenix Cap <= 2 + Negative Guards
;; ============================================================================

;; (5) #72 12PoolBot: >= 6 Zerglings < 150s (`f=2404`) w/ 2 Gateways & Zealot <= 2 MUST cap Gateways at 2
;;     (NEVER build Gateway #3!), spending on CyberCore (when busy) or Zealot + 1 wall ShieldBattery!
(reset-macro-escrow-tracker!)
(define p-72-2gate-cap-busy-cyber
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 2404
    #:minerals 260 #:gas 92 #:supply-used 20 #:supply-cap 31 #:workers 18 #:active-bases 1
    #:mineral-harvesters 15 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'assimilator 1)
    #:unit-counts (hasheq 'probe 18 'zealot 1)
    #:enemy-unit-counts (hasheq 'zergling 8)
    #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(reset-macro-escrow-tracker!)
(define p-72-2gate-cap-zealot-battery
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 2700
    #:minerals 220 #:gas 60 #:supply-used 22 #:supply-cap 31 #:workers 18 #:active-bases 1
    #:mineral-harvesters 16 #:gas-harvesters 2
    #:army-supply 2 #:enemy-threat-supply 8 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 18 'zealot 1)
    #:enemy-unit-counts (hasheq 'zergling 8)
    #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(check! (and (not (memq 'gateway (macro-brain-decision-scheduled-ids p-72-2gate-cap-busy-cyber)))
             (not (not (memq 'cybernetics-core (macro-brain-decision-scheduled-ids p-72-2gate-cap-busy-cyber))))
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-72-2gate-cap-zealot-battery)))
             (not (not (memq 'zealot (macro-brain-decision-scheduled-ids p-72-2gate-cap-zealot-battery))))
             (not (not (memq 'shield-battery (macro-brain-decision-scheduled-ids p-72-2gate-cap-zealot-battery)))))
        (format "L43-P0-2b(5) #72 12PoolBot strict 2-Gate cap: busy=~s zb=~s"
                (macro-brain-decision-scheduled-ids p-72-2gate-cap-busy-cyber)
                (macro-brain-decision-scheduled-ids p-72-2gate-cap-zealot-battery)))

;; (6) #53 zig-reapers (>= 4 Reapers, 0 Bunker, busy Factory): prioritize Bunker>=735 + Marine, BLOCK Marauder/EBay/WidowMine/RaxTL/OC!
(reset-macro-escrow-tracker!)
(define t-53-reapers4-bunker-first
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 3604
    #:minerals 160 #:gas 90 #:supply-used 22 #:supply-cap 39 #:workers 18 #:active-bases 1
    #:mineral-harvesters 15 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 3 'barracks 1 'factory 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 3 'barracks 1 'factory 1 'refinery 1)
    #:unit-counts (hasheq 'scv 18 'marine 2)
    #:enemy-unit-counts (hasheq 'reaper 5)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1 'factory 0))))
(check! (and (not (not (memq 'bunker (macro-brain-decision-scheduled-ids t-53-reapers4-bunker-first))))
             (>= (cand-u t-53-reapers4-bunker-first 'bunker) 660.0)
             (not (memq 'marauder (macro-brain-decision-scheduled-ids t-53-reapers4-bunker-first)))
             (not (memq 'engineering-bay (macro-brain-decision-scheduled-ids t-53-reapers4-bunker-first)))
             (not (memq 'widow-mine (macro-brain-decision-scheduled-ids t-53-reapers4-bunker-first)))
             (not (memq 'barracks-techlab (macro-brain-decision-scheduled-ids t-53-reapers4-bunker-first)))
             (not (memq 'orbital-command (macro-brain-decision-scheduled-ids t-53-reapers4-bunker-first))))
        (format "L43-P0-2b(6) #53 >=4 Reapers w/ 0 Bunker: MUST build bunker>=660 & block marauder/ebay/wm/raxtl/oc: sched=~s save=~a u_bnk=~a"
                (macro-brain-decision-scheduled-ids t-53-reapers4-bunker-first)
                (macro-brain-decision-saving-for t-53-reapers4-bunker-first)
                (cand-u t-53-reapers4-bunker-first 'bunker)))

;; (7) #53 zig-reapers (once Bunker #1 exists, >= 4 Reapers): prioritize Hellion + BarracksReactor ahead of tech!
(reset-macro-escrow-tracker!)
(define t-53-reapers4-reactor-hellion
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 3900
    #:minerals 165 #:gas 80 #:supply-used 24 #:supply-cap 39 #:workers 18 #:active-bases 1
    #:mineral-harvesters 15 #:gas-harvesters 3
    #:army-supply 5 #:enemy-threat-supply 8 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 3 'barracks 1 'factory 1 'bunker 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 3 'barracks 1 'factory 1 'bunker 1 'refinery 1)
    #:unit-counts (hasheq 'scv 18 'marine 3 'hellion 1)
    #:enemy-unit-counts (hasheq 'reaper 6)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1 'factory 1))))
(check! (and (not (not (memq 'hellion (macro-brain-decision-scheduled-ids t-53-reapers4-reactor-hellion))))
             (not (not (memq 'barracks-reactor (macro-brain-decision-scheduled-ids t-53-reapers4-reactor-hellion))))
             (>= (cand-u t-53-reapers4-reactor-hellion 'barracks-reactor) 660.0)
             (not (memq 'engineering-bay (macro-brain-decision-scheduled-ids t-53-reapers4-reactor-hellion)))
             (not (memq 'widow-mine (macro-brain-decision-scheduled-ids t-53-reapers4-reactor-hellion)))
             (not (memq 'factory-techlab (macro-brain-decision-scheduled-ids t-53-reapers4-reactor-hellion))))
        (format "L43-P0-2b(7) #53 >=4 Reapers w/ Bunker#1: MUST schedule hellion + barracks-reactor>=660 over tech: sched=~s u_rxr=~a"
                (macro-brain-decision-scheduled-ids t-53-reapers4-reactor-hellion)
                (cand-u t-53-reapers4-reactor-hellion 'barracks-reactor)))

;; (8) Mass-Roach PvZ (`Clicadinha P` & `sludgement2`): >= 6 Roaches -> lock Immortal floor >= 4
;;     strictly ahead of TwilightCouncil, extra Zealots, Forge, Stalker gas drain, and 3rd Nexus!
(reset-macro-escrow-tracker!)
(define p-pvz-mass-roach-immortal-lock
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 5600
    #:minerals 165 #:gas 90 #:supply-used 46 #:supply-cap 70 #:workers 32 #:active-bases 2
    #:mineral-harvesters 24 #:gas-harvesters 8
    #:army-supply 14 #:enemy-threat-supply 20 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 3 'cybernetics-core 1
                                    'robotics-facility 1 'shield-battery 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 32 'zealot 3 'stalker 3 'immortal 1)
    #:enemy-unit-counts (hasheq 'roach 10 'zergling 8)
    #:enemy-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'roach-warren 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-pvz-mass-roach-immortal-lock) 'immortal)
             (>= (cand-u p-pvz-mass-roach-immortal-lock 'immortal) 665.0)
             (cand-blk p-pvz-mass-roach-immortal-lock 'immortal)
             (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-pvz-mass-roach-immortal-lock)))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-pvz-mass-roach-immortal-lock)))
             (not (memq 'stalker (macro-brain-decision-scheduled-ids p-pvz-mass-roach-immortal-lock)))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvz-mass-roach-immortal-lock))))
        (format "L43-P0-2b(8) Mass-Roach PvZ @165M/90G: MUST escrow immortal>=665 ahead of twilight/zealot/stalker/nexus3: sched=~s save=~a u_imm=~a"
                (macro-brain-decision-scheduled-ids p-pvz-mass-roach-immortal-lock)
                (macro-brain-decision-saving-for p-pvz-mass-roach-immortal-lock)
                (cand-u p-pvz-mass-roach-immortal-lock 'immortal)))

;; (9) Mass-Roach PvZ w/ 0 Robo: >= 6 Roaches -> prioritize RoboticsFacility #1 strictly ahead of TwilightCouncil!
(reset-macro-escrow-tracker!)
(define p-pvz-mass-roach-robo1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 4900
    #:minerals 180 #:gas 110 #:supply-used 40 #:supply-cap 54 #:workers 28 #:active-bases 2
    #:mineral-harvesters 22 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 16 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 28 'zealot 3 'stalker 3)
    #:enemy-unit-counts (hasheq 'roach 8 'zergling 6)
    #:enemy-building-counts (hasheq 'hatchery 2 'roach-warren 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3))))
(check! (and (not (not (memq 'robotics-facility (macro-brain-decision-scheduled-ids p-pvz-mass-roach-robo1))))
             (>= (cand-u p-pvz-mass-roach-robo1 'robotics-facility) 660.0)
             (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-pvz-mass-roach-robo1)))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-pvz-mass-roach-robo1))))
        (format "L43-P0-2b(9) Mass-Roach PvZ 0-Robo: MUST build robotics-facility>=660 ahead of twilight/zealot: sched=~s u_robo=~a"
                (macro-brain-decision-scheduled-ids p-pvz-mass-roach-robo1)
                (cand-u p-pvz-mass-roach-robo1 'robotics-facility)))

;; (10) Anti-Mass-Stalker PvP (`#5138711 PrismForge`): >= 15 enemy Stalkers & 0 Stargate air ->
;;      HARD-CAP Phoenix <= 2 and funnel resources into Immortals + 8-Gateway scaling on 3 bases!
(reset-macro-escrow-tracker!)
(define p-pvp-mass-stalker-phoenix-cap2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 8600
    #:minerals 480 #:gas 260 #:supply-used 98 #:supply-cap 134 #:workers 46 #:active-bases 3
    #:mineral-harvesters 34 #:gas-harvesters 12
    #:army-supply 52 #:enemy-threat-supply 40 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1 'stargate 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1 'stargate 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 5)
    #:unit-counts (hasheq 'probe 46 'stalker 10 'immortal 4 'zealot 6 'phoenix 2)
    #:enemy-unit-counts (hasheq 'stalker 22 'zealot 4)
    #:enemy-building-counts (hasheq 'nexus 3 'gateway 9 'twilight-council 1)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 1 'stargate 1 'robotics-facility 1 'twilight-council 1))))
(check! (and (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-pvp-mass-stalker-phoenix-cap2)))
             (not (eq? (macro-brain-decision-saving-for p-pvp-mass-stalker-phoenix-cap2) 'phoenix))
             (not (not (memq 'immortal (macro-brain-decision-scheduled-ids p-pvp-mass-stalker-phoenix-cap2))))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-pvp-mass-stalker-phoenix-cap2)))))
        (format "L43-P0-2b(10) #5138711 PvP Mass-Stalker: MUST cap phoenix<=2 & funnel into immortal + gateway#7-8: sched=~s save=~a"
                (macro-brain-decision-scheduled-ids p-pvp-mass-stalker-phoenix-cap2)
                (macro-brain-decision-saving-for p-pvp-mass-stalker-phoenix-cap2)))

;; (11) Negative guard: PvP WITH enemy Stargate + Phoenixes STILL allows Phoenix #3+!
(reset-macro-escrow-tracker!)
(define p-pvp-enemy-stargate-allows-phoenix3
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 8600
    #:minerals 380 #:gas 260 #:supply-used 90 #:supply-cap 134 #:workers 46 #:active-bases 3
    #:mineral-harvesters 34 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 30 #:under-attack? #t #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1 'stargate 2 'assimilator 5)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 6 'cybernetics-core 1 'stargate 2 'assimilator 5)
    #:unit-counts (hasheq 'probe 46 'stalker 14 'phoenix 2)
    #:enemy-unit-counts (hasheq 'stalker 8 'phoenix 14 'oracle 4)
    #:enemy-building-counts (hasheq 'nexus 3 'stargate 2)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 0 'stargate 2))))
(check! (not (not (memq 'phoenix (macro-brain-decision-scheduled-ids p-pvp-enemy-stargate-allows-phoenix3))))
        (format "L43-P0-2b(11) neg-guard PvP w/ enemy Stargate+Phoenixes MUST still train phoenix#3: sched=~s"
                (macro-brain-decision-scheduled-ids p-pvp-enemy-stargate-allows-phoenix3)))

;; (12) Negative guards: (a) PvZ Mass-Roach lock releases at >= 4 Immortals (allows Twilight/RoboBay/3rd Nexus),
;;      and (b) TvT Tank4 lock releases on confirmed 2 Banshees (allows anti-Banshee Viking)!
(reset-macro-escrow-tracker!)
(define p-pvz-4immortals-releases-lock
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 7400
    #:minerals 450 #:gas 200 #:supply-used 72 #:supply-cap 94 #:workers 42 #:active-bases 2
    #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 18 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'zealot 3 'stalker 4 'immortal 4)
    #:enemy-unit-counts (hasheq 'roach 10)
    #:enemy-building-counts (hasheq 'hatchery 3 'roach-warren 1)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 0))))
(reset-macro-escrow-tracker!)
(define t-tvt-banshee-releases-tank4
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 6400
    #:minerals 220 #:gas 120 #:supply-used 52 #:supply-cap 78 #:workers 36 #:active-bases 2
    #:mineral-harvesters 26 #:gas-harvesters 10
    #:army-supply 16 #:enemy-threat-supply 10 #:under-attack? #t #:requires-anti-air? #t #:requires-detection? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2 'factory 1 'factory-techlab 1
                                    'starport 1 'engineering-bay 1 'missile-turret 2 'refinery 3)
    #:unit-counts (hasheq 'scv 36 'marine 10 'siege-tank 1)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:enemy-building-counts (hasheq 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1))))
(check! (and (or (not (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvz-4immortals-releases-lock))))
                 (not (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-pvz-4immortals-releases-lock))))
                 (not (not (memq 'robotics-bay (macro-brain-decision-scheduled-ids p-pvz-4immortals-releases-lock)))))
             (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-tvt-banshee-releases-tank4)))))
        (format "L43-P0-2a/2b(12) neg-guards: 4-Immortal PvZ releases lock (sched=~s) & TvT 2-Banshee releases Tank4 (sched=~s)"
                (macro-brain-decision-scheduled-ids p-pvz-4immortals-releases-lock)
                (macro-brain-decision-scheduled-ids t-tvt-banshee-releases-tank4)))

(reset-macro-escrow-tracker!)
(printf "verify_wave43_belief: ~a/~a passed (~a failed)\n" passed (+ passed failed) failed)
(when (> failed 0) (exit 1))
