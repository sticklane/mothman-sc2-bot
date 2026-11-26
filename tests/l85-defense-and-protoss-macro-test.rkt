#lang racket/base

;; =============================================================================
;; Loop 85 Track 4 Unit Test Suite (`tests/l85-defense-and-protoss-macro-test.rkt`)
;;
;; Verifies general SC2 macro defense responses and Protoss midgame scaling in
;; `lib/priority-macro-brain.rkt`:
;;   1. Shared mirror-signals plumbing via `obs->macro-world-state` (`rush-prob`,
;;      `proxy-all-in-posterior`, `enemy-1base-double-gas?`,
;;      `enemy-missing-main-prod?`, `enemy-early-pool?`,
;;      `protoss-wall-needs-slot3?`).
;;   2. Gap A (PvZ early pool latch + wall Slot-3 Gateway #2):
;;      - Early Spawning Pool latch holds through `f < 3600` (2:40) to abort
;;        400M Nexus escrow and schedule Zealot / CyberCore.
;;      - `protoss-wall-needs-slot3?` boosts Gateway #2 (`u >= 568, blk = #t`)
;;        immediately after CyberCore ahead of Robo / Twilight.
;;   3. Gap B (Proxy / 1-Base 2-Gas All-In Defense `< 5:30`):
;;      - PvT / PvP: prioritizes ShieldBattery -> RoboticsFacility -> Immortal
;;        #1-#3 while deferring Observer (unless confirmed cloak/mine/air-cloak),
;;        Twilight, Forge, RoboticsBay, greedy 2nd/3rd Nexus.
;;      - TvP: prioritizes Bunker -> Factory -> fast Starport (even with < 22
;;        workers or `under-attack?`) -> VikingFighter (never suppressed by
;;        zero-air Viking suppression) + FactoryTechLab & Cyclone once Starport
;;        exists, ahead of EngineeringBay / SiegeTank / 2nd CC.
;;   4. Gap C (TvZ Roach/Ravager Bust Defense + PvT Light-Air Immortal Yield):
;;      - TvZ scouted RoachWarren / Roaches locks 3-4 SiegeTanks (from >= 75G,
;;        `u >= 640`), boosts FactoryTechLab & natural Bunker, and defers
;;        WidowMine / BarracksReactor gas drain.
;;      - PvT 1-2 enemy Vikings + 3 Cyclones with 4 Stalkers & 0 Immortals
;;        yields `stalker@840` override so Immortal #1 trains out of idle Robo.
;;   5. Protoss Midgame Scaling & Pylon Discipline:
;;      - Idle-Robo Immortal cadence (`u >= 625, blk = #t`) from >= 100M &
;;        >= 50G w/ gas income across PvZ/PvT/PvP ahead of Twilight/Forge/Stalker.
;;      - 2-base/3-base Gateway scaling (`u >= 585..592, blk = #t`) ahead of
;;        Robo #2 / RoboticsBay / Forge (< 5 Gates) / 2nd Twilight upgrade while
;;        preserving W6-P0-2 (5 Gates < 5:00 -> Forge #1 allowed before Gate #6).
;;      - Excess Pylon bloat guard suppresses Pylon (`u <= 180, blk = #f`) when
;;        effective supply headroom is >= 12 (1-2b) / >= 16 (3b) while preserving
;;        emergency supply-block Pylon (`supply-left <= 0`).
;;   6. Peaceful Macro Non-Regression:
;;      - Standard PvZ / PvT / TvP / TvZ with low `rush-prob` and all proxy/rush
;;        signals `#f` takes natural expansions normally with zero blind defense.
;; =============================================================================

(require racket/list
         racket/format
         "../lib/sc2-game-constants.rkt"
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

(define (decision-trace dec)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (and (priority-schedule-result? sched)
                      (priority-schedule-result-category-utilities sched)))
  (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))

(define (cand-entry dec sym)
  (findf (lambda (e) (eq? (priority-decision-entry-id e) sym))
         (decision-trace dec)))

(define (cand-u dec sym)
  (define hit (cand-entry dec sym))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

(define (cand-blk? dec sym)
  (define hit (cand-entry dec sym))
  (and hit (priority-decision-entry-blocking-allowed? hit)))

(define (scheduled-syms dec)
  (macro-brain-decision-scheduled-ids dec))

(define (saving-sym dec)
  (macro-brain-decision-saving-for dec))

;; =============================================================================
;; 1. Shared Mirror-Signals Plumbing (`obs->macro-world-state`)
;; =============================================================================
(let ()
  (define obs
    (hasheq 'race 'Protoss 'enemy-race 'Zerg 'frame 2400
            'minerals 240 'gas 25 'supply-used 19 'supply-cap 23 'supply-left 4
            'pending-supply 0 'pending-workers 0 'army-supply 0 'enemy-threat-supply 0
            'under-attack? #f
            'ally-units (for/list ([i (in-range 19)]) (hasheq 'type 'probe))
            'ally-buildings (list (hasheq 'type 'nexus 'build-progress 1.0)
                                  (hasheq 'type 'pylon 'build-progress 1.0)
                                  (hasheq 'type 'gateway 'build-progress 1.0))
            'open-facility-slots (hasheq 'townhall 1 'gateway 1)
            'mirror-signals (hasheq 'rush-prob 0.30
                                    'proxy-all-in-posterior 0.78
                                    'enemy-1base-double-gas? #t
                                    'enemy-missing-main-prod? #t
                                    'enemy-early-pool? #t
                                    'protoss-wall-needs-slot3? #t)))
  (define ws (obs-hash->macro-world-state obs 'Protoss))
  (define ms (macro-world-state-mirror-signals ws))
  (check! (and (hash? ms)
               (>= (hash-ref ms 'rush-prob 0.0) 0.78)
               (>= (hash-ref ms 'proxy-all-in-posterior 0.0) 0.78)
               (eq? (hash-ref ms 'enemy-1base-double-gas? #f) #t)
               (eq? (hash-ref ms 'enemy-missing-main-prod? #f) #t)
               (eq? (hash-ref ms 'enemy-early-pool? #f) #t)
               (eq? (hash-ref ms 'protoss-wall-needs-slot3? #f) #t))
          (format "1a. obs-hash->macro-world-state preserves all 6 Loop 85 mirror-signals keys and merges proxy posterior into rush-prob: ~s" ms)))

;; =============================================================================
;; 2. Gap A: PvZ Early-Pool Latch (< 3600f) + Wall Slot-3 Gateway #2
;; =============================================================================
(let ()
  ;; (2a) PvZ at f=2400 (107s, past old 1904f cutoff!) with enemy-early-pool?=#t:
  ;;      MUST abort 400M natural Nexus escrow and schedule Zealot / CyberCore!
  (reset-macro-escrow-tracker!)
  (define d-early-pool
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 2400
      #:minerals 260 #:gas 0 #:supply-used 20 #:supply-cap 23 #:supply-left 3
      #:workers 19 #:active-bases 1 #:mineral-harvesters 19 #:gas-harvesters 0
      #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
      #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1)
      #:unit-counts (hasheq 'probe 19)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 1)
      #:mirror-signals (hasheq 'enemy-early-pool? #t 'rush-prob 0.72))))
  (check! (and (not (eq? (saving-sym d-early-pool) 'nexus))
               (not (memq 'nexus (scheduled-syms d-early-pool)))
               (or (not (not (memq 'zealot (scheduled-syms d-early-pool))))
                   (not (not (memq 'cybernetics-core (scheduled-syms d-early-pool))))))
          (format "2a. PvZ enemy-early-pool? at f=2400 aborts Nexus escrow and prioritizes Zealot/CyberCore: sched=~s sav=~a"
                  (scheduled-syms d-early-pool) (saving-sym d-early-pool)))

  ;; (2b) PvZ wall Slot-3 Gateway #2 right after CyberCore:
  ;;      protoss-wall-needs-slot3?=#t boosts gateway (u >= 568, blk = #t) ahead of Robo/Twilight!
  (reset-macro-escrow-tracker!)
  (define d-slot3
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 2900
      #:minerals 215 #:gas 100 #:supply-used 26 #:supply-cap 39 #:supply-left 13
      #:workers 21 #:active-bases 2 #:mineral-harvesters 15 #:gas-harvesters 6
      #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 1)
      #:total-building-counts (hasheq 'nexus 2 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 1)
      #:unit-counts (hasheq 'probe 21 'zealot 1 'adept 1)
      #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'cybernetics-core 1)
      #:mirror-signals (hasheq 'protoss-wall-needs-slot3? #t 'rush-prob 0.20))))
  (check! (and (not (not (memq 'gateway (scheduled-syms d-slot3))))
               (>= (cand-u d-slot3 'gateway) 568.0)
               (cand-blk? d-slot3 'gateway)
               (not (memq 'robotics-facility (scheduled-syms d-slot3)))
               (not (memq 'twilight-council (scheduled-syms d-slot3))))
          (format "2b. PvZ protoss-wall-needs-slot3? boosts Gateway #2 (u>=568, blk=#t) ahead of Robo/Twilight: sched=~s gw-u=~a gw-blk=~a"
                  (scheduled-syms d-slot3) (cand-u d-slot3 'gateway) (cand-blk? d-slot3 'gateway))))

;; =============================================================================
;; 3. Gap B: Proxy & 1-Base 2-Gas All-In Defense (< 5:30)
;; =============================================================================
(let ()
  ;; (3a) PvT proxy/1-base 2-gas (f=3600, 1b, Cyber ready, 0 Battery, 0 Robo):
  ;;      Prioritizes ShieldBattery (u>=660, blk=#t) and defers greedy Nexus/Twilight/Forge!
  (reset-macro-escrow-tracker!)
  (define d-pvt-proxy-bat
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 3600
      #:minerals 220 #:gas 110 #:supply-used 28 #:supply-cap 39 #:supply-left 11
      #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
      #:army-supply 6 #:enemy-threat-supply 4 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 21 'stalker 3)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 0 'cybernetics-core 1)
      #:mirror-signals (hasheq 'proxy-all-in-posterior 0.80 'enemy-1base-double-gas? #t))))
  (check! (and (not (not (memq 'shield-battery (scheduled-syms d-pvt-proxy-bat))))
               (>= (cand-u d-pvt-proxy-bat 'shield-battery) 660.0)
               (cand-blk? d-pvt-proxy-bat 'shield-battery)
               (not (memq 'nexus (scheduled-syms d-pvt-proxy-bat)))
               (not (eq? (saving-sym d-pvt-proxy-bat) 'nexus))
               (<= (cand-u d-pvt-proxy-bat 'twilight-council) 240.0)
               (<= (cand-u d-pvt-proxy-bat 'forge) 240.0))
          (format "3a. PvT proxy/1b2g prioritizes ShieldBattery@660 and defers Nexus/Twilight/Forge: sched=~s sav=~a bat-u=~a tw-u=~a fg-u=~a"
                  (scheduled-syms d-pvt-proxy-bat) (saving-sym d-pvt-proxy-bat)
                  (cand-u d-pvt-proxy-bat 'shield-battery)
                  (cand-u d-pvt-proxy-bat 'twilight-council)
                  (cand-u d-pvt-proxy-bat 'forge)))

  ;; (3b) PvT proxy/1-base 2-gas with Battery ready & 0 Robo:
  ;;      Prioritizes RoboticsFacility (u>=640, blk=#t) over Twilight/Forge/Nexus!
  (reset-macro-escrow-tracker!)
  (define d-pvt-proxy-robo
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 3900
      #:minerals 200 #:gas 110 #:supply-used 32 #:supply-cap 39 #:supply-left 7
      #:workers 22 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
      #:army-supply 8 #:enemy-threat-supply 6 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'shield-battery 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1 'shield-battery 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 22 'stalker 4)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 0 'cybernetics-core 1)
      #:mirror-signals (hasheq 'enemy-1base-double-gas? #t 'rush-prob 0.72))))
  (check! (and (not (not (memq 'robotics-facility (scheduled-syms d-pvt-proxy-robo))))
               (>= (cand-u d-pvt-proxy-robo 'robotics-facility) 640.0)
               (cand-blk? d-pvt-proxy-robo 'robotics-facility)
               (not (memq 'twilight-council (scheduled-syms d-pvt-proxy-robo))))
          (format "3b. PvT proxy/1b2g drops RoboticsFacility@640 once ShieldBattery is down: sched=~s robo-u=~a"
                  (scheduled-syms d-pvt-proxy-robo) (cand-u d-pvt-proxy-robo 'robotics-facility)))

  ;; (3c) PvP proxy/1-base with Robo ready (0 Immortals, 0 Observers, NO cloak threat):
  ;;      Prioritizes Immortal #1 (u>=685, blk=#t) and skips Observer #1!
  (reset-macro-escrow-tracker!)
  (define d-pvp-proxy-imm
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Protoss #:frame 4600
      #:minerals 290 #:gas 120 #:supply-used 36 #:supply-cap 47 #:supply-left 11
      #:workers 24 #:active-bases 1 #:mineral-harvesters 18 #:gas-harvesters 6
      #:army-supply 10 #:enemy-threat-supply 8 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 24 'stalker 5)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 1)
      #:mirror-signals (hasheq 'enemy-missing-main-prod? #t 'rush-prob 0.80))))
  (check! (and (not (not (memq 'immortal (scheduled-syms d-pvp-proxy-imm))))
               (>= (cand-u d-pvp-proxy-imm 'immortal) 685.0)
               (cand-blk? d-pvp-proxy-imm 'immortal)
               (not (memq 'observer (scheduled-syms d-pvp-proxy-imm)))
               (<= (cand-u d-pvp-proxy-imm 'observer) 240.0))
          (format "3c. PvP proxy/1b prioritizes Immortal@685 and defers Observer without cloak threat: sched=~s imm-u=~a obs-u=~a"
                  (scheduled-syms d-pvp-proxy-imm) (cand-u d-pvp-proxy-imm 'immortal) (cand-u d-pvp-proxy-imm 'observer)))

  ;; (3d) PvP proxy/1-base WITH confirmed DarkTemplar:
  ;;      Observer is NOT deferred by proxy-defer when cloak is confirmed!
  (reset-macro-escrow-tracker!)
  (define d-pvp-proxy-dt
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Protoss #:frame 4800
      #:minerals 160 #:gas 90 #:supply-used 36 #:supply-cap 47 #:supply-left 11
      #:workers 24 #:active-bases 1 #:mineral-harvesters 18 #:gas-harvesters 6
      #:army-supply 10 #:enemy-threat-supply 8 #:under-attack? #t #:requires-detection? #t
      #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1 'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 24 'stalker 5)
      #:enemy-unit-counts (hasheq 'dark-templar 2)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 1)
      #:mirror-signals (hasheq 'enemy-1base-double-gas? #t 'rush-prob 0.80))))
  (check! (and (not (not (memq 'observer (scheduled-syms d-pvp-proxy-dt))))
               (> (cand-u d-pvp-proxy-dt 'observer) 240.0))
          (format "3d. PvP proxy WITH confirmed DT still schedules Observer immediately: sched=~s obs-u=~a"
                  (scheduled-syms d-pvp-proxy-dt) (cand-u d-pvp-proxy-dt 'observer)))

  ;; (3e) TvP proxy/1-base 2-gas with 19 workers + under-attack?=#t + Factory ready + 0 Starport:
  ;;      Waives workers>=22 / under-attack? blocks to drop fast Starport (u>=665, blk=#t)
  ;;      ahead of EngineeringBay / FactoryTechLab / 2nd CC!
  (reset-macro-escrow-tracker!)
  (define d-tvp-proxy-sp
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 3900
      #:minerals 175 #:gas 110 #:supply-used 29 #:supply-cap 39 #:supply-left 10
      #:workers 19 #:active-bases 1 #:mineral-harvesters 13 #:gas-harvesters 6
      #:army-supply 8 #:enemy-threat-supply 6 #:under-attack? #t
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1 'bunker 1 'factory 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1 'bunker 1 'factory 1 'refinery 2)
      #:unit-counts (hasheq 'scv 19 'marine 8)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 1 'factory 1)
      #:mirror-signals (hasheq 'proxy-all-in-posterior 0.80 'enemy-1base-double-gas? #t))))
  (check! (and (not (not (memq 'starport (scheduled-syms d-tvp-proxy-sp))))
               (>= (cand-u d-tvp-proxy-sp 'starport) 665.0)
               (cand-blk? d-tvp-proxy-sp 'starport)
               (<= (cand-u d-tvp-proxy-sp 'engineering-bay) 240.0)
               (<= (cand-u d-tvp-proxy-sp 'factory-techlab) 240.0)
               (not (memq 'command-center (scheduled-syms d-tvp-proxy-sp))))
          (format "3e. TvP proxy/1b2g (19w, under-attack) drops fast Starport@665 ahead of EBay/FacTL/CC2: sched=~s sp-u=~a ebay-u=~a ftl-u=~a"
                  (scheduled-syms d-tvp-proxy-sp)
                  (cand-u d-tvp-proxy-sp 'starport)
                  (cand-u d-tvp-proxy-sp 'engineering-bay)
                  (cand-u d-tvp-proxy-sp 'factory-techlab)))

  ;; (3f) TvP proxy/1-base 2-gas with Starport ready (0 enemy air visible yet!):
  ;;      Prioritizes VikingFighter (u>=680, blk=#t, NOT suppressed by zero-air Viking suppression!)
  ;;      AND unlocks Cyclone (u>=655) once FactoryTechLab is ready!
  (reset-macro-escrow-tracker!)
  (define d-tvp-proxy-vik
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 4600
      #:minerals 320 #:gas 180 #:supply-used 34 #:supply-cap 47 #:supply-left 13
      #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
      #:army-supply 10 #:enemy-threat-supply 6 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 1 'bunker 1
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 1 'bunker 1
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
      #:unit-counts (hasheq 'scv 21 'marine 10)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 1 'factory 1 'starport 1)
      #:mirror-signals (hasheq 'proxy-all-in-posterior 0.80 'enemy-1base-double-gas? #t))))
  (check! (and (not (not (memq 'viking-fighter (scheduled-syms d-tvp-proxy-vik))))
               (>= (cand-u d-tvp-proxy-vik 'viking-fighter) 680.0)
               (cand-blk? d-tvp-proxy-vik 'viking-fighter)
               (not (not (memq 'cyclone (scheduled-syms d-tvp-proxy-vik))))
               (>= (cand-u d-tvp-proxy-vik 'cyclone) 655.0)
               (cand-blk? d-tvp-proxy-vik 'cyclone))
          (format "3f. TvP proxy/1b2g with Starport+FacTL trains Viking@680 (unblocked despite 0 visible air) & Cyclone@655: sched=~s vik-u=~a cyc-u=~a"
                  (scheduled-syms d-tvp-proxy-vik)
                  (cand-u d-tvp-proxy-vik 'viking-fighter)
                  (cand-u d-tvp-proxy-vik 'cyclone))))

;; =============================================================================
;; 4. Gap C: TvZ Roach/Ravager Bust Defense + PvT Light-Air Immortal Yield
;; =============================================================================
(let ()
  ;; (4a) TvZ scouted RoachWarren + 4 Roaches (Factory+TechLab ready, 1 Tank, 90G):
  ;;      Escrows SiegeTank #2-#4 (`u>=640, blk=#t`) from >= 75G and defers WidowMine / RaxReactor!
  (reset-macro-escrow-tracker!)
  (define d-tvz-roach-tank
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Zerg #:frame 5400
      #:minerals 210 #:gas 90 #:supply-used 46 #:supply-cap 62 #:supply-left 16
      #:workers 30 #:active-bases 2 #:mineral-harvesters 24 #:gas-harvesters 6
      #:army-supply 16 #:enemy-threat-supply 12 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 2 'bunker 1
                                      'factory 1 'factory-techlab 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 2 'bunker 1
                                      'factory 1 'factory-techlab 1 'refinery 2)
      #:unit-counts (hasheq 'scv 30 'marine 12 'siege-tank 1)
      #:enemy-unit-counts (hasheq 'roach 5 'ravager 1)
      #:enemy-building-counts (hasheq 'roach-warren 1)
      #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1))))
  (check! (and (eq? (saving-sym d-tvz-roach-tank) 'siege-tank)
               (>= (cand-u d-tvz-roach-tank 'siege-tank) 640.0)
               (cand-blk? d-tvz-roach-tank 'siege-tank)
               (<= (cand-u d-tvz-roach-tank 'widow-mine) 220.0)
               (<= (cand-u d-tvz-roach-tank 'barracks-reactor) 220.0))
          (format "4a. TvZ scouted Roach/Ravager bust escrows SiegeTank@640 from 90G and defers WidowMine/RaxReactor: sched=~s sav=~a tank-u=~a wm-u=~a rr-u=~a"
                  (scheduled-syms d-tvz-roach-tank) (saving-sym d-tvz-roach-tank)
                  (cand-u d-tvz-roach-tank 'siege-tank)
                  (cand-u d-tvz-roach-tank 'widow-mine)
                  (cand-u d-tvz-roach-tank 'barracks-reactor)))

  ;; (4b) TvZ scouted RoachWarren with bare Factory & 0 Bunker:
  ;;      Boosts FactoryTechLab@645 and Bunker@620!
  (reset-macro-escrow-tracker!)
  (define d-tvz-roach-ftl
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Zerg #:frame 4900
      #:minerals 220 #:gas 60 #:supply-used 40 #:supply-cap 54 #:supply-left 14
      #:workers 28 #:active-bases 2 #:mineral-harvesters 22 #:gas-harvesters 6
      #:army-supply 12 #:enemy-threat-supply 8 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 1 'factory 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 1 'factory 1 'refinery 2)
      #:unit-counts (hasheq 'scv 28 'marine 10)
      #:enemy-unit-counts (hasheq 'roach 4)
      #:enemy-building-counts (hasheq 'roach-warren 1)
      #:open-facility-slots (hasheq 'townhall 2 'barracks 1 'factory 1))))
  (check! (and (not (not (memq 'factory-techlab (scheduled-syms d-tvz-roach-ftl))))
               (>= (cand-u d-tvz-roach-ftl 'factory-techlab) 645.0)
               (not (not (memq 'bunker (scheduled-syms d-tvz-roach-ftl))))
               (>= (cand-u d-tvz-roach-ftl 'bunker) 620.0))
          (format "4b. TvZ scouted Roach bust schedules FactoryTechLab@645 and Bunker@620: sched=~s ftl-u=~a bnk-u=~a"
                  (scheduled-syms d-tvz-roach-ftl)
                  (cand-u d-tvz-roach-ftl 'factory-techlab)
                  (cand-u d-tvz-roach-ftl 'bunker)))

  ;; (4c) PvT light-air yield for Immortal (2 Vikings + 3 Cyclones, 4 Stalkers, 0 Immortals, idle Robo):
  ;;      Stalker@840 AA override yields so Immortal #1 trains out of the idle Robo!
  (reset-macro-escrow-tracker!)
  (define d-pvt-light-air-imm
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 6400
      #:minerals 285 #:gas 110 #:supply-used 48 #:supply-cap 62 #:supply-left 14
      #:workers 30 #:active-bases 2 #:mineral-harvesters 22 #:gas-harvesters 8
      #:army-supply 16 #:enemy-threat-supply 14 #:under-attack? #f #:requires-anti-air? #t
      #:ready-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:total-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 3 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:unit-counts (hasheq 'probe 30 'stalker 4 'zealot 2)
      #:enemy-unit-counts (hasheq 'viking-fighter 2 'cyclone 3)
      #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
  (check! (and (not (not (memq 'immortal (scheduled-syms d-pvt-light-air-imm))))
               (>= (cand-u d-pvt-light-air-imm 'immortal) 625.0)
               (< (cand-u d-pvt-light-air-imm 'stalker) (cand-u d-pvt-light-air-imm 'immortal)))
          (format "4c. PvT 2 Vikings + 3 Cyclones yields Stalker@840 so Immortal #1 trains from idle Robo: sched=~s imm-u=~a stk-u=~a"
                  (scheduled-syms d-pvt-light-air-imm)
                  (cand-u d-pvt-light-air-imm 'immortal)
                  (cand-u d-pvt-light-air-imm 'stalker))))

;; =============================================================================
;; 5. Protoss Midgame Scaling & Excess Pylon Discipline
;; =============================================================================
(let ()
  ;; (5a) Idle-Robo Protoss PvZ at 120M/80G, 0 Immortals, 4 Stalkers, ready Robo:
  ;;      Escrows Immortal #1 (`u>=625, blk=#t`) ahead of Twilight/Forge/Stalker!
  (reset-macro-escrow-tracker!)
  (define d-pvz-idle-robo
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 6000
      #:minerals 130 #:gas 80 #:supply-used 46 #:supply-cap 62 #:supply-left 16
      #:workers 32 #:active-bases 2 #:mineral-harvesters 24 #:gas-harvesters 8
      #:army-supply 12 #:enemy-threat-supply 6 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:total-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:unit-counts (hasheq 'probe 32 'stalker 4 'zealot 2)
      #:enemy-unit-counts (hasheq 'roach 4 'zergling 8)
      #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
  (check! (and (eq? (saving-sym d-pvz-idle-robo) 'immortal)
               (>= (cand-u d-pvz-idle-robo 'immortal) 625.0)
               (cand-blk? d-pvz-idle-robo 'immortal)
               (not (memq 'stalker (scheduled-syms d-pvz-idle-robo)))
               (not (memq 'twilight-council (scheduled-syms d-pvz-idle-robo)))
               (not (memq 'forge (scheduled-syms d-pvz-idle-robo))))
          (format "5a. Idle-Robo PvZ at 130M/80G escrows Immortal #1@625 ahead of Stalker/Twilight/Forge: sched=~s sav=~a imm-u=~a stk-u=~a"
                  (scheduled-syms d-pvz-idle-robo) (saving-sym d-pvz-idle-robo)
                  (cand-u d-pvz-idle-robo 'immortal) (cand-u d-pvz-idle-robo 'stalker)))

  ;; (5b) 2-base Protoss stuck on 3 Gateways (34 Probes, Robo+Twilight up, 2 Immortals, open-robo=0):
  ;;      Prioritizes Gateway #4 (`u>=592, blk=#t`) ahead of Forge / Robo #2 / RoboticsBay / 2nd Twilight upg!
  (reset-macro-escrow-tracker!)
  (define d-protoss-gw4
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 7200
      #:minerals 180 #:gas 140 #:supply-used 56 #:supply-cap 78 #:supply-left 22
      #:workers 34 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 8
      #:army-supply 20 #:enemy-threat-supply 6 #:under-attack? #f
      #:researched-upgrades '(warp-gate-research blink)
      #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'warp-gate 3 'cybernetics-core 1
                                      'robotics-facility 1 'twilight-council 1 'assimilator 3)
      #:total-building-counts (hasheq 'nexus 2 'pylon 7 'warp-gate 3 'cybernetics-core 1
                                      'robotics-facility 1 'twilight-council 1 'assimilator 3)
      #:unit-counts (hasheq 'probe 34 'stalker 6 'immortal 2)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 1 'robotics-facility 0 'twilight-council 1))))
  (check! (and (not (not (memq 'gateway (scheduled-syms d-protoss-gw4))))
               (>= (cand-u d-protoss-gw4 'gateway) 592.0)
               (cand-blk? d-protoss-gw4 'gateway)
               (<= (cand-u d-protoss-gw4 'forge) 440.0)
               (<= (cand-u d-protoss-gw4 'robotics-bay) 440.0)
               (<= (cand-u d-protoss-gw4 'charge) 440.0))
          (format "5b. 2-base Protoss on 3 Gates schedules Gateway #4@592 ahead of Forge/Bay/2nd Twilight upg: sched=~s gw-u=~a fg-u=~a bay-u=~a chg-u=~a"
                  (scheduled-syms d-protoss-gw4)
                  (cand-u d-protoss-gw4 'gateway)
                  (cand-u d-protoss-gw4 'forge)
                  (cand-u d-protoss-gw4 'robotics-bay)
                  (cand-u d-protoss-gw4 'charge)))

  ;; (5c) Preserve W6-P0-2: 2-base Protoss < 5:00 (f=6200) with 5 Gateways already & 0 Forge
  ;;      allows Forge #1 cleanly without deferring it for Gateway #6!
  (reset-macro-escrow-tracker!)
  (define d-w6-forge-ok
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 6200
      #:minerals 200 #:gas 100 #:supply-used 62 #:supply-cap 86 #:supply-left 24
      #:workers 38 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 8
      #:army-supply 24 #:enemy-threat-supply 0 #:under-attack? #f
      #:researched-upgrades '(warp-gate-research)
      #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'warp-gate 5 'cybernetics-core 1
                                      'robotics-facility 1 'twilight-council 1 'assimilator 3)
      #:total-building-counts (hasheq 'nexus 2 'pylon 7 'warp-gate 5 'cybernetics-core 1
                                      'robotics-facility 1 'twilight-council 1 'assimilator 3)
      #:unit-counts (hasheq 'probe 38 'stalker 8 'immortal 2)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 3 'robotics-facility 0))))
  (check! (> (cand-u d-w6-forge-ok 'forge) 440.0)
          (format "5c. W6-P0-2 preserved: 2-base Protoss with 5 Gates < 5:00 does NOT defer Forge #1: sched=~s fg-u=~a"
                  (scheduled-syms d-w6-forge-ok) (cand-u d-w6-forge-ok 'forge)))

  ;; (5d) Excess Pylon bloat guard: 2-base Protoss with 9 Pylons and +18 supply headroom
  ;;      demotes Pylon (u <= 180, blk = #f); emergency supply-left = 0 STILL triggers Pylon!
  (reset-macro-escrow-tracker!)
  (define d-pylon-overbuilt
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 6400
      #:minerals 200 #:gas 60 #:supply-used 60 #:supply-cap 78 #:supply-left 18 #:pending-supply 0
      #:workers 36 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 8
      #:army-supply 24 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'warp-gate 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:total-building-counts (hasheq 'nexus 2 'pylon 9 'warp-gate 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:unit-counts (hasheq 'probe 36 'stalker 8 'immortal 2)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 2 'robotics-facility 0))))
  (reset-macro-escrow-tracker!)
  (define d-pylon-blocked
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 6400
      #:minerals 160 #:gas 60 #:supply-used 62 #:supply-cap 62 #:supply-left 0 #:pending-supply 0
      #:workers 36 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 8
      #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 6 'warp-gate 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:total-building-counts (hasheq 'nexus 2 'pylon 6 'warp-gate 4 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:unit-counts (hasheq 'probe 36 'stalker 8 'immortal 2)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 2 'robotics-facility 0))))
  (check! (and (not (memq 'pylon (scheduled-syms d-pylon-overbuilt)))
               (<= (cand-u d-pylon-overbuilt 'pylon) 180.0)
               (not (cand-blk? d-pylon-overbuilt 'pylon))
               (not (not (memq 'pylon (scheduled-syms d-pylon-blocked))))
               (>= (cand-u d-pylon-blocked 'pylon) 1000.0))
          (format "5d. Excess Pylon bloat suppressed (+18 headroom -> u<=180, blk=#f) while supply-block=0 still schedules emergency Pylon: over=~s(u=~a,blk=~a) blk=~s(u=~a)"
                  (scheduled-syms d-pylon-overbuilt) (cand-u d-pylon-overbuilt 'pylon) (cand-blk? d-pylon-overbuilt 'pylon)
                  (scheduled-syms d-pylon-blocked) (cand-u d-pylon-blocked 'pylon))))

;; =============================================================================
;; 6. Peaceful Macro Non-Regression (Zero False Triggers When Signals Are Low)
;; =============================================================================
(let ()
  ;; (6a) Peaceful PvZ at f=2400 with low rush-prob and enemy-early-pool?=#f:
  ;;      Still takes/escrows natural Nexus cleanly!
  (reset-macro-escrow-tracker!)
  (define d-peaceful-pvz
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 2400
      #:minerals 340 #:gas 0 #:supply-used 20 #:supply-cap 31 #:supply-left 11
      #:workers 19 #:active-bases 1 #:mineral-harvesters 19 #:gas-harvesters 0
      #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
      #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1)
      #:unit-counts (hasheq 'probe 19)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 1)
      #:mirror-signals (hasheq 'rush-prob 0.12 'proxy-all-in-posterior 0.08 'enemy-early-pool? #f))))
  (check! (or (not (not (memq 'nexus (scheduled-syms d-peaceful-pvz))))
              (eq? (saving-sym d-peaceful-pvz) 'nexus))
          (format "6a. Peaceful PvZ (rush=0.12, early-pool=#f) still expands to natural Nexus cleanly: sched=~s sav=~a"
                  (scheduled-syms d-peaceful-pvz) (saving-sym d-peaceful-pvz)))

  ;; (6b) Peaceful TvP with Starport ready & 0 enemy air (rush=0.12, 1b2g=#f):
  ;;      Does NOT trigger blind proxy Viking@680!
  (reset-macro-escrow-tracker!)
  (define d-peaceful-tvp
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 4600
      #:minerals 320 #:gas 180 #:supply-used 42 #:supply-cap 54 #:supply-left 12
      #:workers 28 #:active-bases 2 #:mineral-harvesters 22 #:gas-harvesters 6
      #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 2
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 4 'barracks 2
                                      'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
      #:unit-counts (hasheq 'scv 28 'marine 12 'siege-tank 1)
      #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 1)
      #:mirror-signals (hasheq 'rush-prob 0.12 'proxy-all-in-posterior 0.05 'enemy-1base-double-gas? #f))))
  (check! (and (not (memq 'viking-fighter (scheduled-syms d-peaceful-tvp)))
               (< (cand-u d-peaceful-tvp 'viking-fighter) 600.0))
          (format "6b. Peaceful TvP (rush=0.12, 0 enemy air) does NOT build blind proxy Vikings: sched=~s vik-u=~a"
                  (scheduled-syms d-peaceful-tvp) (cand-u d-peaceful-tvp 'viking-fighter))))

;; =============================================================================
;; 7. Loop 85B Live Drill & Self-Play Regression Guards
;; =============================================================================
(let ()
  ;; (7a) Protoss PvZ under rush=0.47 (<5:30, Robo ready, 0 Immortals, NO cloak):
  ;;      Hard-blocks Observer (even at 85M/90G where Immortal is unaffordable!),
  ;;      WarpPrism, and TwilightCouncil so Observer@55.5 NEVER steals the Robo slot!
  (reset-macro-escrow-tracker!)
  (define d-pvz-rush-no-obs-leak
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Zerg #:frame 4900
      #:minerals 85 #:gas 90 #:supply-used 36 #:supply-cap 54 #:supply-left 18
      #:workers 26 #:active-bases 2 #:mineral-harvesters 20 #:gas-harvesters 6
      #:army-supply 10 #:enemy-threat-supply 8 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 4 'gateway 2 'cybernetics-core 1
                                      'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 2 'pylon 4 'gateway 2 'cybernetics-core 1
                                      'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 26 'stalker 4 'zealot 1)
      #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 1)
      #:mirror-signals (hasheq 'rush-prob 0.47))))
  (check! (and (not (memq 'observer (scheduled-syms d-pvz-rush-no-obs-leak)))
               (not (memq 'warp-prism (scheduled-syms d-pvz-rush-no-obs-leak)))
               (not (memq 'twilight-council (scheduled-syms d-pvz-rush-no-obs-leak)))
               (<= (cand-u d-pvz-rush-no-obs-leak 'observer) 240.0)
               (<= (cand-u d-pvz-rush-no-obs-leak 'twilight-council) 240.0))
          (format "7a. PvZ rush=0.47 (0 Immortals, 85M/90G) hard-blocks Observer/WarpPrism/Twilight: sched=~s sav=~a obs-u=~a tw-u=~a"
                  (scheduled-syms d-pvz-rush-no-obs-leak) (saving-sym d-pvz-rush-no-obs-leak)
                  (cand-u d-pvz-rush-no-obs-leak 'observer) (cand-u d-pvz-rush-no-obs-leak 'twilight-council)))

  ;; (7b) PvT proxy (rush=0.85, f=3460, Battery#1 ready, 160M/163G, 2 Stalkers + 1 Adept):
  ;;      Drops RoboticsFacility@640 immediately (~154s) and hard-blocks excess Adept/Zealot!
  (reset-macro-escrow-tracker!)
  (define d-pvt-proxy-fast-robo
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 3460
      #:minerals 160 #:gas 163 #:supply-used 30 #:supply-cap 39 #:supply-left 9
      #:workers 22 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
      #:army-supply 6 #:enemy-threat-supply 6 #:under-attack? #f
      #:researched-upgrades '(warp-gate-research)
      #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1
                                      'shield-battery 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 2 'cybernetics-core 1
                                      'shield-battery 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 22 'stalker 2 'adept 1)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 2)
      #:mirror-signals (hasheq 'rush-prob 0.85 'enemy-missing-main-prod? #t))))
  (check! (and (not (not (memq 'robotics-facility (scheduled-syms d-pvt-proxy-fast-robo))))
               (>= (cand-u d-pvt-proxy-fast-robo 'robotics-facility) 640.0)
               (not (memq 'adept (scheduled-syms d-pvt-proxy-fast-robo)))
               (not (memq 'zealot (scheduled-syms d-pvt-proxy-fast-robo))))
          (format "7b. PvT proxy (rush=0.85, Battery#1 ready, 160M/163G) drops Robo@640 immediately ahead of extra Adept/Zealot: sched=~s robo-u=~a"
                  (scheduled-syms d-pvt-proxy-fast-robo) (cand-u d-pvt-proxy-fast-robo 'robotics-facility)))

  ;; (7c) TvP proxy (rush=0.85, f=3700, Factory building, RaxTL ready, 150M/130G):
  ;;      Hard-blocks Stimpack, BarracksReactor, FactoryTechLab, EngineeringBay, Hellion, WidowMine
  ;;      so 100G stays intact for fast Starport!
  (reset-macro-escrow-tracker!)
  (define d-tvp-proxy-no-stim-drain
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 3700
      #:minerals 140 #:gas 130 #:supply-used 27 #:supply-cap 39 #:supply-left 12
      #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
      #:army-supply 6 #:enemy-threat-supply 4 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1
                                      'barracks-techlab 1 'bunker 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1
                                      'barracks-techlab 1 'bunker 1 'factory 1 'refinery 2)
      #:unit-counts (hasheq 'scv 21 'marine 6)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 1 'barracks-techlab 1)
      #:mirror-signals (hasheq 'rush-prob 0.85 'enemy-missing-main-prod? #t))))
  (check! (and (not (memq 'stimpack (scheduled-syms d-tvp-proxy-no-stim-drain)))
               (not (eq? (saving-sym d-tvp-proxy-no-stim-drain) 'stimpack))
               (not (memq 'engineering-bay (scheduled-syms d-tvp-proxy-no-stim-drain)))
               (not (memq 'barracks-reactor (scheduled-syms d-tvp-proxy-no-stim-drain)))
               (not (memq 'marauder (scheduled-syms d-tvp-proxy-no-stim-drain))))
          (format "7c. TvP proxy (rush=0.85, Factory building) hard-blocks Stimpack/EBay/RaxReactor/Marauder gas drain: sched=~s sav=~a"
                  (scheduled-syms d-tvp-proxy-no-stim-drain) (saving-sym d-tvp-proxy-no-stim-drain)))

  ;; (7d) Patch-resilient bare-Factory Cyclone (live 4.10 data: require-attached=#f):
  ;;      Once Starport>=1, TvP proxy trains bare-Factory Cyclone@655 immediately AND hard-blocks FactoryTechLab!
  (dynamic-wind
    (lambda ()
      (register-sc2-live-unit-data! 'cyclone 150 100 3.0 720 0 #f 4.72 1.0 7.0 7.0 #f #f))
    (lambda ()
      (reset-macro-escrow-tracker!)
      (define d-tvp-bare-fac-cyc
        (step-priority-macro-brain
         (make-macro-world-state
          #:race 'Terran #:enemy-race 'Protoss #:frame 4300
          #:minerals 180 #:gas 130 #:supply-used 32 #:supply-cap 47 #:supply-left 15
          #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
          #:army-supply 10 #:enemy-threat-supply 6 #:under-attack? #f
          #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 1
                                          'bunker 1 'factory 1 'refinery 2)
          #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 1
                                          'bunker 1 'factory 1 'starport 1 'refinery 2)
          #:unit-counts (hasheq 'scv 21 'marine 10)
          #:open-facility-slots (hasheq 'townhall 1 'barracks 1 'factory 1)
          #:mirror-signals (hasheq 'rush-prob 0.85 'enemy-1base-double-gas? #t))))
      (check! (and (not (not (memq 'cyclone (scheduled-syms d-tvp-bare-fac-cyc))))
                   (>= (cand-u d-tvp-bare-fac-cyc 'cyclone) 655.0)
                   (not (memq 'factory-techlab (scheduled-syms d-tvp-bare-fac-cyc)))
                   (<= (cand-u d-tvp-bare-fac-cyc 'factory-techlab) 240.0))
              (format "7d. Live 4.10 bare-Factory Cyclone trains Cyclone@655 immediately after Starport>=1 while hard-blocking FactoryTechLab: sched=~s cyc-u=~a ftl-u=~a"
                      (scheduled-syms d-tvp-bare-fac-cyc)
                      (cand-u d-tvp-bare-fac-cyc 'cyclone)
                      (cand-u d-tvp-bare-fac-cyc 'factory-techlab))))
    (lambda ()
      (reset-sc2-live-game-data!)))

  ;; (7e) TvZ Roach/Ravager bust (rush=0.62, f=3588, RaxTL ready, 0 Tanks, 110M/110G):
  ;;      Hard-blocks Stimpack, Armory, WidowMine, BarracksReactor and prioritizes Bunker@650 / FactoryTechLab@655 / SiegeTank@660!
  (reset-macro-escrow-tracker!)
  (define d-tvz-roach-no-stim
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Zerg #:frame 3588
      #:minerals 110 #:gas 110 #:supply-used 25 #:supply-cap 39 #:supply-left 14
      #:workers 21 #:active-bases 2 #:mineral-harvesters 15 #:gas-harvesters 6
      #:army-supply 4 #:enemy-threat-supply 6 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'command-center 1 'supply-depot 3
                                      'barracks 1 'barracks-techlab 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'command-center 1 'supply-depot 3
                                      'barracks 1 'barracks-techlab 1 'factory 1 'refinery 2)
      #:unit-counts (hasheq 'scv 21 'marine 4)
      #:enemy-building-counts (hasheq 'roach-warren 1)
      #:open-facility-slots (hasheq 'townhall 2 'barracks 1 'barracks-techlab 1)
      #:mirror-signals (hasheq 'rush-prob 0.62))))
  (check! (and (or (not (not (memq 'bunker (scheduled-syms d-tvz-roach-no-stim))))
                   (eq? (saving-sym d-tvz-roach-no-stim) 'bunker))
               (>= (cand-u d-tvz-roach-no-stim 'bunker) 650.0)
               (not (memq 'stimpack (scheduled-syms d-tvz-roach-no-stim)))
               (not (eq? (saving-sym d-tvz-roach-no-stim) 'stimpack))
               (not (memq 'armory (scheduled-syms d-tvz-roach-no-stim))))
          (format "7e. TvZ Roach bust (f=3588, 0 Tanks) prioritizes Bunker@650 and hard-blocks Stimpack/Armory: sched=~s sav=~a bnk-u=~a"
                  (scheduled-syms d-tvz-roach-no-stim) (saving-sym d-tvz-roach-no-stim)
                  (cand-u d-tvz-roach-no-stim 'bunker)))

  ;; (7f) Post-hold natural expansion release (~225s, f=5040, rush=0.85, Bunker/Battery + >=8 army >=0.9x enemy):
  ;;      Releases CC #2 and Nexus #2 immediately instead of stalling 1-base past 300s!
  (reset-macro-escrow-tracker!)
  (define d-tvp-post-hold-cc2
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Terran #:enemy-race 'Protoss #:frame 5040
      #:minerals 240 #:gas 120 #:supply-used 36 #:supply-cap 47 #:supply-left 11
      #:workers 24 #:active-bases 1 #:mineral-harvesters 18 #:gas-harvesters 6
      #:army-supply 12 #:enemy-threat-supply 6 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 2
                                      'bunker 1 'factory 1 'refinery 2)
      #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 4 'barracks 2
                                      'bunker 1 'factory 1 'refinery 2)
      #:unit-counts (hasheq 'scv 24 'marine 10 'marauder 1)
      #:open-facility-slots (hasheq 'townhall 1 'barracks 2 'factory 1)
      #:mirror-signals (hasheq 'rush-prob 0.85 'enemy-missing-main-prod? #t))))
  (reset-macro-escrow-tracker!)
  (define d-pvt-post-hold-nex2
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 5040
      #:minerals 240 #:gas 100 #:supply-used 36 #:supply-cap 47 #:supply-left 11
      #:workers 24 #:active-bases 1 #:mineral-harvesters 18 #:gas-harvesters 6
      #:army-supply 12 #:enemy-threat-supply 6 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1
                                      'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'pylon 4 'gateway 2 'cybernetics-core 1
                                      'shield-battery 1 'robotics-facility 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 24 'stalker 6)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'robotics-facility 0)
      #:mirror-signals (hasheq 'rush-prob 0.85 'enemy-missing-main-prod? #t))))
  (check! (and (or (eq? (saving-sym d-tvp-post-hold-cc2) 'command-center)
                   (not (not (memq 'command-center (scheduled-syms d-tvp-post-hold-cc2)))))
               (>= (cand-u d-tvp-post-hold-cc2 'command-center) 910.0)
               (or (eq? (saving-sym d-pvt-post-hold-nex2) 'nexus)
                   (not (not (memq 'nexus (scheduled-syms d-pvt-post-hold-nex2)))))
               (>= (cand-u d-pvt-post-hold-nex2 'nexus) 910.0))
          (format "7f. Post-hold release at f=5040 (Bunker/Battery + 12 army vs 6 threat, rush=0.85) unlocks CC#2 & Nexus#2@910: tvp=~a(u=~a) pvt=~a(u=~a)"
                  (saving-sym d-tvp-post-hold-cc2) (cand-u d-tvp-post-hold-cc2 'command-center)
                  (saving-sym d-pvt-post-hold-nex2) (cand-u d-pvt-post-hold-nex2 'nexus))))

  ;; ===========================================================================
  ;; 8. Loop 85C Protoss Priority Inversions (AA Stargate, All-Matchup 3rd Nexus,
  ;;    Peaceful PvT Pre-CyberCore Zealot Guard & Fast Ranged Unit #1)
  ;; ===========================================================================

  ;; (8a) Anti-air Stargate #1 vs air harassment (3 Gates, 34 Probes, 180M/160G, enemy air):
  ;;      Stargate (u >= 605.0, blk=#t) beats midgame Gateway #4 (previously 592 > 535)!
  (reset-macro-escrow-tracker!)
  (define d-pvt-aa-sg-over-gw4
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 7190
      #:minerals 180 #:gas 160 #:supply-used 62 #:supply-cap 78 #:supply-left 16
      #:workers 34 #:active-bases 2 #:mineral-harvesters 25 #:gas-harvesters 9
      #:army-supply 26 #:enemy-threat-supply 6 #:under-attack? #f #:requires-anti-air? #t
      #:researched-upgrades '(warp-gate-research)
      #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'warp-gate 3 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:total-building-counts (hasheq 'nexus 2 'pylon 9 'warp-gate 3 'cybernetics-core 1
                                      'robotics-facility 1 'assimilator 3)
      #:unit-counts (hasheq 'probe 34 'stalker 8 'immortal 1 'observer 1)
      #:enemy-unit-counts (hasheq 'banshee 3)
      #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 0 'robotics-facility 0))))
  (check! (and (not (not (memq 'stargate (scheduled-syms d-pvt-aa-sg-over-gw4))))
               (>= (cand-u d-pvt-aa-sg-over-gw4 'stargate) 605.0)
               (> (cand-u d-pvt-aa-sg-over-gw4 'stargate) (cand-u d-pvt-aa-sg-over-gw4 'gateway))
               (not (memq 'gateway (scheduled-syms d-pvt-aa-sg-over-gw4))))
          (format "8a. Anti-air Stargate@605+ beats midgame Gateway #4 vs Banshees at 180M/160G: sched=~s sg-u=~a gw-u=~a"
                  (scheduled-syms d-pvt-aa-sg-over-gw4)
                  (cand-u d-pvt-aa-sg-over-gw4 'stargate)
                  (cand-u d-pvt-aa-sg-over-gw4 'gateway)))

  ;; (8b) Peaceful 2-base PvT & PvP 3rd Nexus (4 Gates, 42 Probes, 1 Immortal, idle Robo, 310M/120G):
  ;;      3rd Nexus@595 (blk=#t, saving=nexus) beats Immortal #2+, Gateway #5, AND Chargelot!
  (reset-macro-escrow-tracker!)
  (define d-pvt-peaceful-3rd-nex
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 8400
      #:minerals 310 #:gas 120 #:supply-used 72 #:supply-cap 94 #:supply-left 22
      #:workers 42 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 12
      #:army-supply 30 #:enemy-threat-supply 6 #:under-attack? #f
      #:researched-upgrades '(warp-gate-research charge)
      #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'warp-gate 4 'cybernetics-core 1
                                      'twilight-council 1 'robotics-facility 1 'assimilator 4)
      #:total-building-counts (hasheq 'nexus 2 'pylon 10 'warp-gate 4 'cybernetics-core 1
                                      'twilight-council 1 'robotics-facility 1 'assimilator 4)
      #:unit-counts (hasheq 'probe 42 'stalker 8 'zealot 4 'immortal 1 'observer 1 'warp-prism 1)
      #:enemy-unit-counts (hasheq 'marine 10 'marauder 2)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 4 'robotics-facility 1))))
  (reset-macro-escrow-tracker!)
  (define d-pvp-peaceful-3rd-nex
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Protoss #:frame 8400
      #:minerals 310 #:gas 120 #:supply-used 78 #:supply-cap 102 #:supply-left 24
      #:workers 48 #:active-bases 2 #:mineral-harvesters 36 #:gas-harvesters 12
      #:army-supply 30 #:enemy-threat-supply 6 #:under-attack? #f
      #:researched-upgrades '(warp-gate-research blink)
      #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'warp-gate 4 'cybernetics-core 1
                                      'twilight-council 1 'robotics-facility 1 'assimilator 4)
      #:total-building-counts (hasheq 'nexus 2 'pylon 10 'warp-gate 4 'cybernetics-core 1
                                      'twilight-council 1 'robotics-facility 1 'assimilator 4)
      #:unit-counts (hasheq 'probe 48 'stalker 10 'immortal 2 'observer 1 'warp-prism 1)
      #:enemy-unit-counts (hasheq 'stalker 10 'immortal 1)
      #:open-facility-slots (hasheq 'townhall 2 'warp-gate 4 'robotics-facility 1))))
  (check! (and (eq? (saving-sym d-pvt-peaceful-3rd-nex) 'nexus)
               (>= (cand-u d-pvt-peaceful-3rd-nex 'nexus) 595.0)
               (not (memq 'immortal (scheduled-syms d-pvt-peaceful-3rd-nex)))
               (not (memq 'gateway (scheduled-syms d-pvt-peaceful-3rd-nex)))
               (not (memq 'zealot (scheduled-syms d-pvt-peaceful-3rd-nex)))
               (eq? (saving-sym d-pvp-peaceful-3rd-nex) 'nexus)
               (>= (cand-u d-pvp-peaceful-3rd-nex 'nexus) 595.0)
               (not (memq 'immortal (scheduled-syms d-pvp-peaceful-3rd-nex)))
               (not (memq 'gateway (scheduled-syms d-pvp-peaceful-3rd-nex))))
          (format "8b. Peaceful 2-base PvT & PvP 3rd Nexus@595 holds escrow ahead of Immortal/Gateway/Zealot: pvt=~a(u=~a,sched=~s) pvp=~a(u=~a,sched=~s)"
                  (saving-sym d-pvt-peaceful-3rd-nex) (cand-u d-pvt-peaceful-3rd-nex 'nexus)
                  (scheduled-syms d-pvt-peaceful-3rd-nex)
                  (saving-sym d-pvp-peaceful-3rd-nex) (cand-u d-pvp-peaceful-3rd-nex 'nexus)
                  (scheduled-syms d-pvp-peaceful-3rd-nex)))

  ;; (8c) Peaceful PvT pre-CyberCore (0 CyberCore, 1 Gate, 110M/48G, 0 threat):
  ;;      Hard-blocks Zealot and escrows CyberneticsCore #1; under-attack?=#t still allows Zealot!
  (reset-macro-escrow-tracker!)
  (define d-pvt-pre-cyber-no-zealot
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 2100
      #:minerals 110 #:gas 48 #:supply-used 20 #:supply-cap 31 #:supply-left 11
      #:workers 20 #:active-bases 1 #:mineral-harvesters 17 #:gas-harvesters 3
      #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'assimilator 1)
      #:total-building-counts (hasheq 'nexus 2 'pylon 2 'gateway 1 'assimilator 1)
      #:unit-counts (hasheq 'probe 20)
      #:open-facility-slots (hasheq 'townhall 0 'gateway 1))))
  (reset-macro-escrow-tracker!)
  (define d-pvt-pre-cyber-under-attack
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 2100
      #:minerals 110 #:gas 48 #:supply-used 20 #:supply-cap 31 #:supply-left 11
      #:workers 20 #:active-bases 1 #:mineral-harvesters 17 #:gas-harvesters 3
      #:army-supply 0 #:enemy-threat-supply 4 #:under-attack? #t
      #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'assimilator 1)
      #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'assimilator 1)
      #:unit-counts (hasheq 'probe 20)
      #:enemy-unit-counts (hasheq 'marine 4)
      #:open-facility-slots (hasheq 'townhall 0 'gateway 1))))
  (check! (and (not (memq 'zealot (scheduled-syms d-pvt-pre-cyber-no-zealot)))
               (eq? (saving-sym d-pvt-pre-cyber-no-zealot) 'cybernetics-core)
               (not (not (memq 'zealot (scheduled-syms d-pvt-pre-cyber-under-attack)))))
          (format "8c. Peaceful PvT pre-CyberCore hard-blocks Zealot and escrows CyberCore, while under-attack allows Zealot: peace=~s(sav=~a) atk=~s"
                  (scheduled-syms d-pvt-pre-cyber-no-zealot) (saving-sym d-pvt-pre-cyber-no-zealot)
                  (scheduled-syms d-pvt-pre-cyber-under-attack)))

  ;; (8d) CyberCore ready with 0 ranged units (140M/100G, open Gate + open CyberCore, no WarpGate):
  ;;      Schedules Stalker #1 (u >= 626.0, blk=#t) ahead of WarpGate@620; once Stalker=1, WarpGate@620 schedules!
  (reset-macro-escrow-tracker!)
  (define d-pvt-ranged1-before-wg
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 3300
      #:minerals 140 #:gas 100 #:supply-used 23 #:supply-cap 31 #:supply-left 8
      #:workers 23 #:active-bases 2 #:mineral-harvesters 17 #:gas-harvesters 6
      #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 2 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 23)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 1 'cybernetics-core 1))))
  (reset-macro-escrow-tracker!)
  (define d-pvt-wg-after-ranged1
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:enemy-race 'Terran #:frame 3400
      #:minerals 140 #:gas 100 #:supply-used 25 #:supply-cap 39 #:supply-left 14
      #:workers 23 #:active-bases 2 #:mineral-harvesters 17 #:gas-harvesters 6
      #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'pylon 4 'gateway 1 'cybernetics-core 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 2 'pylon 4 'gateway 1 'cybernetics-core 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 23 'stalker 1)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 1 'cybernetics-core 1))))
  (check! (and (not (not (memq 'stalker (scheduled-syms d-pvt-ranged1-before-wg))))
               (>= (cand-u d-pvt-ranged1-before-wg 'stalker) 626.0)
               (> (cand-u d-pvt-ranged1-before-wg 'stalker) (cand-u d-pvt-ranged1-before-wg 'warp-gate-research))
               (not (memq 'warp-gate-research (scheduled-syms d-pvt-ranged1-before-wg)))
               (not (not (memq 'warp-gate-research (scheduled-syms d-pvt-wg-after-ranged1)))))
          (format "8d. CyberCore ready w/ 0 ranged units trains Stalker#1@626 ahead of WarpGate@620, then schedules WarpGate once Stalker=1: r0=~s(stk=~a,wg=~a) r1=~s"
                  (scheduled-syms d-pvt-ranged1-before-wg)
                  (cand-u d-pvt-ranged1-before-wg 'stalker)
                  (cand-u d-pvt-ranged1-before-wg 'warp-gate-research)
                  (scheduled-syms d-pvt-wg-after-ranged1)))

(printf "l85-defense-and-protoss-macro-test: ~a passed, ~a failed\n" passed failed)
(when (> failed 0)
  (exit 1))
