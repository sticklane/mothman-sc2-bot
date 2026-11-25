#lang racket/base

;; =============================================================================
;; Loop 81 Track 2A Unit Test Suite (`tests/l81-div8-macro-tactics-test.rkt`)
;;
;; Verifies Loop 81 Macro Brain (`lib/priority-macro-brain.rkt`) & Pure Tactics
;; Helper (`lib/tactics/arena-minimax.rkt`):
;;   1. Terran 3rd+ CC escrow never starves `scv` (< worker cap) while preserving
;;      `saving-for = 'command-center` for runtime mineral reserve.
;;   2. Terran Factory #1 unlocks past 3:30 (`>= 4704f`) even when Natural CC #2
;;      was delayed/stalled, while < 2:10 peaceful 1-base stays locked to Nat CC.
;;   3. Terran peaceful 1-base Nat CC stays locked vs passive enemy home scout,
;;      and releases immediately on real incoming rush/attack.
;;   4. Protoss PvP non-rush Natural Nexus commits cleanly < 2:30 even when
;;      scouting 1 passive enemy home Zealot/Forge/Stargate (0 local threat),
;;      while real proxy Cannon Rush blocks expansion.
;;   5. Protoss PvP strict upgrade priority: `blink` & `protoss-ground-weapons-1`
;;      strictly outrank & gate `charge`, `resonating-glaives`, `gravitic-booster`,
;;      and `gravitic-drive` until Blink + +1W + splash tech are started.
;;   6. Protoss Gateway scaling (5-6 on 2b >= 6:00, 7-8 on 3b >= 7:30) and
;;      2nd Robotics Facility on 3b >= 7:30 across PvP/PvZ/PvT (not bio-only).
;;   7. Protoss mandatory splash tech (`robotics-bay` even vs >= 15 enemy Stalkers
;;      and even with 4-5 Gateways on 3b; fallback `templar-archive` when Twilight
;;      ready without Robo; `disruptor` when Vikings cap Colossi).
;;   8. `locust-wave-dominates-nearby-threat?` in `lib/tactics/arena-minimax.rkt`
;;      cleanly separates pure Locust waves (`#t`) from mixed Zerg armies (`#f`),
;;      distant waves (`#f`), and tiny remnants (`#f`) for both hash & sim-unit.
;; =============================================================================

(require racket/list
         racket/format
         "../lib/econ-ledger.rkt"
         "../lib/priority-macro-brain.rkt"
         "../lib/tactics/arena-minimax.rkt")

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

(define (cand-u dec sym)
  (define hit (findf (lambda (e) (eq? (priority-decision-entry-id e) sym))
                     (decision-trace dec)))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

(define (scheduled-syms dec)
  (define sched (macro-brain-decision-priority-schedule dec))
  (if (priority-schedule-result? sched)
      (for/list ([a (in-list (priority-schedule-result-scheduled-actions sched))])
        (cond
          [(priority-candidate? a) (priority-candidate-id a)]
          [(and (pair? a) (eq? (car a) 'expand)) 'expand]
          [(and (pair? a) (pair? (cdr a))) (cadr a)]
          [else a]))
      '()))

;; =============================================================================
;; 1. Terran 3rd CC Escrow: Preserves `saving-for=command-center`, Never Starves SCV
;; =============================================================================
(let ()
  (define st-260
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Protoss #:frame 8800
     #:minerals 260 #:gas 120 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
     #:workers 36 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 8
     #:army-supply 32 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3
                                     'barracks-techlab 1 'barracks-reactor 1
                                     'factory 1 'factory-techlab 1 'starport 1 'refinery 3)
     #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3
                                     'barracks-techlab 1 'barracks-reactor 1
                                     'factory 1 'factory-techlab 1 'starport 1 'refinery 3)
     #:unit-counts (hasheq 'scv 36 'marine 14 'marauder 4 'siege-tank 2 'medivac 2)
     #:researched-upgrades '(stimpack)
     #:open-facility-slots (hasheq 'townhall 2 'barracks 3 'factory 1 'starport 1)))
  (define dec-260 (step-priority-macro-brain st-260))
  (define sav-260 (macro-brain-decision-saving-for dec-260))
  (define sched-260 (scheduled-syms dec-260))
  (check! (and (eq? sav-260 'command-center)
               (memq 'scv sched-260))
          (format "1a. 2-base Terran 3rd CC saving at 260M must keep saving-for=command-center AND schedule scv; sav=~s sched=~s"
                  sav-260 sched-260))

  ;; At 365M (within 35M of 400M), briefly pause SCVs for 1 tick so 400M lands cleanly!
  (define st-365
    (struct-copy macro-world-state st-260 [minerals 365]))
  (define dec-365 (step-priority-macro-brain st-365))
  (define sav-365 (macro-brain-decision-saving-for dec-365))
  (define sched-365 (scheduled-syms dec-365))
  (check! (and (eq? sav-365 'command-center)
               (not (memq 'scv sched-365)))
          (format "1b. 2-base Terran 3rd CC at 365M should finish last 35M cleanly; sav=~s sched=~s"
                  sav-365 sched-365)))

;; =============================================================================
;; 2. Terran Factory #1 Unlocks Past 3:30 Even If Nat CC Delayed; < 2:10 Stays Locked
;; =============================================================================
(let ()
  ;; Delayed 1-base Terran at 3:52 (frame 5200) with 0 Factories & 140G: Factory #1 MUST unlock!
  (define st-overdue-fac
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Zerg #:frame 5200
     #:minerals 220 #:gas 140 #:supply-used 28 #:supply-cap 39 #:supply-left 11 #:pending-supply 0
     #:workers 21 #:active-bases 1 #:mineral-harvesters 18 #:gas-harvesters 3
     #:army-supply 7 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1 'refinery 1)
     #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 3 'barracks 1 'refinery 1)
     #:unit-counts (hasheq 'scv 21 'marine 7)
     #:open-facility-slots (hasheq 'townhall 1 'barracks 1)))
  (define dec-fac (step-priority-macro-brain st-overdue-fac))
  (define sched-fac (scheduled-syms dec-fac))
  (define fac-u (cand-u dec-fac 'factory))
  (check! (and (memq 'factory sched-fac)
               (>= fac-u 925.0))
          (format "2a. Overdue Terran Factory #1 past 3:30 must schedule immediately even on 1 base; u=~s sched=~s sav=~s"
                  fac-u sched-fac (macro-brain-decision-saving-for dec-fac)))

  ;; Peaceful 1-base Terran at 1:47 (frame 2400 < 2:10): Natural CC MUST stay locked ahead of Factory!
  (define st-early-nat
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Protoss #:frame 2400
     #:minerals 260 #:gas 100 #:supply-used 21 #:supply-cap 23 #:supply-left 2 #:pending-supply 0
     #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
     #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 1)
     #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 1)
     #:unit-counts (hasheq 'scv 19 'marine 2)
     #:open-facility-slots (hasheq 'townhall 1 'barracks 1)))
  (define dec-early (step-priority-macro-brain st-early-nat))
  (check! (and (eq? (macro-brain-decision-saving-for dec-early) 'command-center)
               (not (memq 'factory (scheduled-syms dec-early))))
          (format "2b. Peaceful < 2:10 Terran 1-base must stay locked to Natural CC; sav=~s sched=~s"
                  (macro-brain-decision-saving-for dec-early) (scheduled-syms dec-early))))

;; =============================================================================
;; 3. Terran Peaceful 1-Base Nat CC vs Passive Home Scout vs Real Rush
;; =============================================================================
(let ()
  ;; Passive scout sees 1 enemy Zealot in enemy main (0 local threat, not under-attack) -> keep Nat CC!
  (define st-passive-scout
    (make-macro-world-state
     #:race 'Terran #:enemy-race 'Protoss #:frame 2350
     #:minerals 270 #:gas 60 #:supply-used 21 #:supply-cap 23 #:supply-left 2 #:pending-supply 0
     #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
     #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 1)
     #:total-building-counts (hasheq 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 1)
     #:unit-counts (hasheq 'scv 19 'marine 2)
     #:enemy-unit-counts (hasheq 'zealot 1)
     #:open-facility-slots (hasheq 'townhall 1 'barracks 1)))
  (define dec-passive (step-priority-macro-brain st-passive-scout))

  ;; Real incoming rush (under-attack? = #t, threat = 6.0) -> release Nat CC lock for defense!
  (define st-real-rush
    (struct-copy macro-world-state st-passive-scout
                 [under-attack? #t]
                 [enemy-threat-supply 6.0]))
  (define dec-rush
    (step-priority-macro-brain st-real-rush #:enemy-unit-counts (hasheq 'zealot 3)))
  (check! (and (eq? (macro-brain-decision-saving-for dec-passive) 'command-center)
               (not (eq? (macro-brain-decision-saving-for dec-rush) 'command-center)))
          (format "3. Terran 1-base Nat CC must stay locked vs passive home Zealot and release on real rush; passive=~s rush=~s"
                  (macro-brain-decision-saving-for dec-passive)
                  (macro-brain-decision-saving-for dec-rush))))

;; =============================================================================
;; 4. Protoss PvP Fast Natural Commitment (< 2:30) vs Real Proxy Cannon Rush
;; =============================================================================
(let ()
  (define st-pvp-nat
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Protoss #:frame 2400
     #:minerals 270 #:gas 100 #:supply-used 22 #:supply-cap 31 #:supply-left 9 #:pending-supply 0
     #:workers 20 #:active-bases 1 #:mineral-harvesters 14 #:gas-harvesters 6
     #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 2 'cybernetics-core 1 'assimilator 2)
     #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 2 'cybernetics-core 1 'assimilator 2)
     #:unit-counts (hasheq 'probe 20 'stalker 1)
     #:enemy-unit-counts (hasheq 'zealot 1)
     #:enemy-building-counts (hasheq 'forge 1)
     #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'cybernetics-core 1)))
  (define dec-pvp-nat (step-priority-macro-brain st-pvp-nat))

  ;; Real early proxy Cannon Rush (photon-cannon=1, threat=4.0, frame=2200) -> MUST NOT expand!
  (define st-cannon-rush
    (struct-copy macro-world-state st-pvp-nat
                 [frame 2200]
                 [enemy-threat-supply 4.0]))
  (define dec-cannon-rush
    (step-priority-macro-brain st-cannon-rush
                               #:enemy-building-counts (hasheq 'forge 1 'photon-cannon 1)))
  (check! (and (eq? (macro-brain-decision-saving-for dec-pvp-nat) 'nexus)
               (not (eq? (macro-brain-decision-saving-for dec-cannon-rush) 'nexus)))
          (format "4. Peaceful PvP (even scouting home Zealot/Forge w/ 0 threat) must commit Natural Nexus; proxy Cannon Rush must block; nat=~s cannon=~s"
                  (macro-brain-decision-saving-for dec-pvp-nat)
                  (macro-brain-decision-saving-for dec-cannon-rush))))

;; =============================================================================
;; 5. Protoss PvP Upgrade Priority: Blink & +1 Weapons Strictly Ahead of Others
;; =============================================================================
(let ()
  (define base-pvp
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Protoss #:frame 6720
     #:minerals 220 #:gas 200 #:supply-used 74 #:supply-cap 100 #:supply-left 26 #:pending-supply 0
     #:workers 38 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 12
     #:army-supply 36 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 4 'cybernetics-core 1
                                     'twilight-council 1 'forge 1 'robotics-facility 1
                                     'robotics-bay 1 'assimilator 4)
     #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 4 'cybernetics-core 1
                                     'twilight-council 1 'forge 1 'robotics-facility 1
                                     'robotics-bay 1 'assimilator 4)
     #:unit-counts (hasheq 'probe 38 'stalker 8 'zealot 4 'adept 4 'immortal 2
                           'observer 1 'warp-prism 1 'colossus 2)
     #:researched-upgrades '(warp-gate-research)
     #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'twilight-council 1
                                   'forge 1 'robotics-facility 1 'robotics-bay 1)))
  (define dec-no-blink (step-priority-macro-brain base-pvp))
  (define blink-u (cand-u dec-no-blink 'blink))
  (define w1-u (cand-u dec-no-blink 'protoss-ground-weapons-1))
  (define charge-u (cand-u dec-no-blink 'charge))
  (define glaives-u (cand-u dec-no-blink 'resonating-glaives))
  (define gboost-u (cand-u dec-no-blink 'gravitic-booster))
  (define gdrive-u (cand-u dec-no-blink 'gravitic-drive))
  (check! (and (>= blink-u 630.0)
               (>= w1-u 618.0)
               (memq 'blink (scheduled-syms dec-no-blink))
               (< charge-u 0.0)
               (< glaives-u 0.0)
               (< gboost-u 0.0)
               (< gdrive-u 0.0))
          (format "5a. PvP must schedule Blink (u>=630) & rank +1W (u>=618) strictly ahead of blocked Charge/Glaives/Gravitic; blink=~s w1=~s chg=~s glv=~s gb=~s gd=~s sched=~s"
                  blink-u w1-u charge-u glaives-u gboost-u gdrive-u (scheduled-syms dec-no-blink)))

  ;; Once Blink is done & Forge is ready, +1 Weapons schedules while Gravitic utility stays blocked!
  (define st-blink-done
    (struct-copy macro-world-state base-pvp
                 [researched-upgrades '(warp-gate-research blink)]))
  (define dec-w1 (step-priority-macro-brain st-blink-done))
  (check! (and (memq 'protoss-ground-weapons-1 (scheduled-syms dec-w1))
               (< (cand-u dec-w1 'gravitic-booster) 0.0)
               (< (cand-u dec-w1 'gravitic-drive) 0.0))
          (format "5b. PvP after Blink must schedule +1 Weapons ahead of Gravitic Booster/Drive; sched=~s gb=~s gd=~s"
                  (scheduled-syms dec-w1) (cand-u dec-w1 'gravitic-booster) (cand-u dec-w1 'gravitic-drive)))

  ;; Even with 1 Colossus (colossus-core2 active), PvP Blink must NOT be demoted below 630.0!
  (define st-col1-pvp
    (struct-copy macro-world-state base-pvp
                 [unit-counts (hasheq 'probe 38 'stalker 8 'zealot 4 'adept 4 'immortal 2
                                      'observer 1 'warp-prism 1 'colossus 1)]))
  (define dec-col1 (step-priority-macro-brain st-col1-pvp))
  (check! (>= (cand-u dec-col1 'blink) 630.0)
          (format "5c. PvP Blink must retain u>=630 even while Colossus #2 is active; blink=~s"
                  (cand-u dec-col1 'blink))))

;; =============================================================================
;; 6. Protoss Gateway Scaling (6 on 2b >= 6:00, 8 on 3b >= 7:30) & 2nd Robo on 3b
;; =============================================================================
(let ()
  ;; 2-base PvP at 6:15 (frame 8400) with 4 Gateways & 3 Immortals -> must scale Gateway #5!
  (define st-2b-gw
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Protoss #:frame 8400
     #:minerals 230 #:gas 80 #:supply-used 72 #:supply-cap 94 #:supply-left 22 #:pending-supply 0
     #:workers 36 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 10
     #:army-supply 36 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 4 'cybernetics-core 1
                                     'robotics-facility 1 'twilight-council 1 'forge 1 'assimilator 4)
     #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 4 'cybernetics-core 1
                                     'robotics-facility 1 'twilight-council 1 'forge 1 'assimilator 4)
     #:unit-counts (hasheq 'probe 36 'stalker 10 'immortal 3 'observer 1)
     #:researched-upgrades '(warp-gate-research blink protoss-ground-weapons-1)
     #:open-facility-slots (hasheq 'townhall 2 'gateway 1 'robotics-facility 0)))
  (define dec-2b-gw (step-priority-macro-brain st-2b-gw))
  (check! (and (>= (cand-u dec-2b-gw 'gateway) 568.0)
               (memq 'gateway (scheduled-syms dec-2b-gw)))
          (format "6a. 2-base Protoss at >= 6:00 must scale Gateway #5-#6 (not held behind Immortal #4); gw-u=~s sched=~s"
                  (cand-u dec-2b-gw 'gateway) (scheduled-syms dec-2b-gw)))

  ;; 3-base PvP & PvZ at 7:45 (frame 10416): 6 Gateways, 1 ready Robo -> must unlock 2nd Robo AND GW #7-#8!
  (define (mk-3b-state erace)
    (make-macro-world-state
     #:race 'Protoss #:enemy-race erace #:frame 10416
     #:minerals 380 #:gas 220 #:supply-used 108 #:supply-cap 140 #:supply-left 32 #:pending-supply 0
     #:workers 50 #:active-bases 3 #:mineral-harvesters 34 #:gas-harvesters 16
     #:army-supply 58 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                     'robotics-facility 1 'robotics-bay 1
                                     'twilight-council 1 'forge 1 'assimilator 6)
     #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                     'robotics-facility 1 'robotics-bay 1
                                     'twilight-council 1 'forge 1 'assimilator 6)
     #:unit-counts (hasheq 'probe 50 'stalker 14 'immortal 3 'colossus 2 'observer 1)
     #:researched-upgrades '(warp-gate-research blink protoss-ground-weapons-1 extended-thermal-lance)
     #:open-facility-slots (hasheq 'townhall 3 'gateway 0 'robotics-facility 0)))
  (define dec-3b-pvp (step-priority-macro-brain (mk-3b-state 'Protoss)))
  (define dec-3b-pvz (step-priority-macro-brain (mk-3b-state 'Zerg)))
  (check! (and (>= (cand-u dec-3b-pvp 'robotics-facility) 585.0)
               (memq 'robotics-facility (scheduled-syms dec-3b-pvp))
               (>= (cand-u dec-3b-pvp 'gateway) 568.0)
               (>= (cand-u dec-3b-pvz 'robotics-facility) 585.0)
               (memq 'robotics-facility (scheduled-syms dec-3b-pvz)))
          (format "6b. 3-base Protoss (>= 7:30) must unlock 2nd Robo & GW #7-#8 in PvP and PvZ; pvp-robo=~s pvp-gw=~s pvz-robo=~s pvp-sched=~s pvz-sched=~s"
                  (cand-u dec-3b-pvp 'robotics-facility) (cand-u dec-3b-pvp 'gateway)
                  (cand-u dec-3b-pvz 'robotics-facility) (scheduled-syms dec-3b-pvp) (scheduled-syms dec-3b-pvz))))

;; =============================================================================
;; 7. Protoss Mandatory Splash Tech on 2-3 Bases (0-Splash Prevention)
;; =============================================================================
(let ()
  ;; (a) 3-base PvP at 6:45 (frame 9072), 5 Gateways (< 6!), ready Robo, 0 Splash, vs 18 enemy Stalkers:
  ;;     Robotics Bay MUST fire cleanly (never blocked by mass-Stalker flag or < 6 GW floor!).
  (define st-splash-rb
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Protoss #:frame 9072
     #:minerals 240 #:gas 200 #:supply-used 92 #:supply-cap 120 #:supply-left 28 #:pending-supply 0
     #:workers 46 #:active-bases 3 #:mineral-harvesters 32 #:gas-harvesters 14
     #:army-supply 46 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 5 'cybernetics-core 1
                                     'robotics-facility 1 'twilight-council 1 'forge 1 'assimilator 5)
     #:total-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 5 'cybernetics-core 1
                                     'robotics-facility 1 'twilight-council 1 'forge 1 'assimilator 5)
     #:unit-counts (hasheq 'probe 46 'stalker 15 'immortal 1 'zealot 6 'observer 1)
     #:enemy-unit-counts (hasheq 'stalker 18 'immortal 2)
     #:researched-upgrades '(warp-gate-research blink protoss-ground-weapons-1)
     #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'robotics-facility 1)))
  (define dec-splash-rb (step-priority-macro-brain st-splash-rb))
  (check! (and (>= (cand-u dec-splash-rb 'robotics-bay) 625.0)
               (memq 'robotics-bay (scheduled-syms dec-splash-rb)))
          (format "7a. 3-base PvP with 0 splash vs 18 Stalkers & 5 Gateways must schedule robotics-bay (u>=625); rb-u=~s sched=~s"
                  (cand-u dec-splash-rb 'robotics-bay) (scheduled-syms dec-splash-rb)))

  ;; (b) 3-base Protoss with ready Twilight Council & NO ready Robo (0 splash): Templar Archive MUST fire!
  (define st-splash-ta
    (struct-copy macro-world-state st-splash-rb
                 [gas 240]
                 [ready-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 5 'cybernetics-core 1
                                                'twilight-council 1 'forge 1 'assimilator 5)]
                 [total-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 5 'cybernetics-core 1
                                                'twilight-council 1 'forge 1 'assimilator 5)]
                 [open-facility-slots (hasheq 'townhall 3 'gateway 2)]))
  (define dec-splash-ta (step-priority-macro-brain st-splash-ta))
  (check! (and (>= (cand-u dec-splash-ta 'templar-archive) 615.0)
               (memq 'templar-archive (scheduled-syms dec-splash-ta)))
          (format "7b. 3-base Protoss with ready Twilight & 0 Robo must schedule templar-archive (u>=615); ta-u=~s sched=~s"
                  (cand-u dec-splash-ta 'templar-archive) (scheduled-syms dec-splash-ta)))

  ;; (c) Ready Robotics Bay + >= 6 enemy Vikings & 1 Colossus -> Disruptor splash fires cleanly!
  (define st-splash-dis
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 10800
     #:minerals 280 #:gas 220 #:supply-used 110 #:supply-cap 140 #:supply-left 30 #:pending-supply 0
     #:workers 52 #:active-bases 3 #:mineral-harvesters 36 #:gas-harvesters 16
     #:army-supply 58 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                     'robotics-facility 1 'robotics-bay 1 'forge 1 'assimilator 6)
     #:total-building-counts (hasheq 'nexus 3 'pylon 12 'gateway 6 'cybernetics-core 1
                                     'robotics-facility 1 'robotics-bay 1 'forge 1 'assimilator 6)
     #:unit-counts (hasheq 'probe 52 'stalker 18 'immortal 3 'colossus 1 'observer 1)
     #:enemy-unit-counts (hasheq 'marine 14 'marauder 6 'siege-tank 4 'viking-fighter 6)
     #:researched-upgrades '(warp-gate-research blink protoss-ground-weapons-1)
     #:open-facility-slots (hasheq 'townhall 3 'gateway 2 'robotics-facility 1)))
  (define dec-splash-dis (step-priority-macro-brain st-splash-dis))
  (check! (>= (cand-u dec-splash-dis 'disruptor) 595.0)
          (format "7c. Ready RoboBay vs >= 6 Vikings & 1 Colossus must boost disruptor splash (>= 595); dis-u=~s sched=~s"
                  (cand-u dec-splash-dis 'disruptor) (scheduled-syms dec-splash-dis))))

;; =============================================================================
;; 8. Pure Anti-SwarmHost Helper: `locust-wave-dominates-nearby-threat?`
;; =============================================================================
(let ()
  (define (mk-h id typ x y #:hp [hp 50.0] #:snapshot? [snap? #f])
    (hasheq 'id id 'type typ 'x x 'y y 'hp hp 'health hp 'snapshot? snap?))
  (define allies-h
    (for/list ([i (in-range 10)])
      (mk-h (+ 100 i) 'stalker (+ 50.0 (* 0.4 i)) 50.0 #:hp 80.0)))
  (define allies-sim
    (map (lambda (h) (unit-hash->tactical-sim-unit h 'ally)) allies-h))

  ;; (a) Pure 20-Locust wave within 12t + 8 Swarm Hosts 17t behind + 0 perm combat -> #t
  (define pure-wave
    (append (for/list ([i (in-range 20)])
              (mk-h (+ 200 i) (if (even? i) 'locust-mp 'locust-mp-flying)
                    (+ 58.0 (* 0.3 (modulo i 5))) (+ 50.0 (* 0.4 (quotient i 5)))))
            (for/list ([i (in-range 8)])
              (mk-h (+ 300 i) 'swarm-host-mp (+ 72.0 (* 0.5 i)) 50.0 #:hp 160.0))
            ;; Non-combat Drones/Overlords/Hatchery nearby must NOT count as permanent combat!
            (list (mk-h 390 'drone 56.0 50.0 #:hp 40.0)
                  (mk-h 391 'overlord 56.0 51.0 #:hp 200.0)
                  (mk-h 392 'hatchery 58.0 52.0 #:hp 1500.0))))
  ;; (b) Mixed Zerg army: 4 Locusts + 12 Roaches + 8 Hydras + 3 Ravagers within 14t -> #f!
  (define mixed-zerg
    (append (for/list ([i (in-range 4)]) (mk-h (+ 400 i) 'locust-mp (+ 58.0 i) 50.0))
            (for/list ([i (in-range 12)]) (mk-h (+ 420 i) 'roach (+ 60.0 (* 0.4 i)) 50.0 #:hp 145.0))
            (for/list ([i (in-range 8)]) (mk-h (+ 450 i) 'hydralisk (+ 61.0 (* 0.4 i)) 52.0 #:hp 90.0))
            (for/list ([i (in-range 3)]) (mk-h (+ 470 i) 'ravager (+ 61.0 i) 48.0 #:hp 120.0))))
  ;; (c) Moderate mixed army: 8 Locusts + 6 Roaches (6/14 = 42.9% >= 35% & >= 4 perm) -> #f!
  (define mixed-moderate
    (append (for/list ([i (in-range 8)]) (mk-h (+ 500 i) 'locust-mp (+ 58.0 (* 0.4 i)) 50.0))
            (for/list ([i (in-range 6)]) (mk-h (+ 520 i) 'roach (+ 59.0 (* 0.5 i)) 51.0 #:hp 145.0))))
  ;; (d) Overwhelming Locust wave: 20 Locusts + 4 Roaches (4/24 = 16.7% < 35%) -> #t!
  (define locust-dominated
    (append (for/list ([i (in-range 20)]) (mk-h (+ 600 i) 'locust-mp (+ 58.0 (* 0.3 i)) 50.0))
            (for/list ([i (in-range 4)]) (mk-h (+ 630 i) 'roach (+ 59.0 (* 0.5 i)) 51.0 #:hp 145.0))))
  ;; (e) Distant Locust wave (20 Locusts 25t away) -> #f!
  (define distant-wave
    (for/list ([i (in-range 20)]) (mk-h (+ 700 i) 'locust-mp (+ 78.0 (* 0.2 i)) 50.0)))
  ;; (f) Tiny remnant (3 Locusts nearby) -> #f!
  (define tiny-remnant
    (for/list ([i (in-range 3)]) (mk-h (+ 800 i) 'locust-mp (+ 56.0 i) 50.0)))
  ;; (g) Snapshot/dead Locusts must be ignored -> #f!
  (define dead-or-snap
    (append (for/list ([i (in-range 6)]) (mk-h (+ 900 i) 'locust-mp (+ 56.0 i) 50.0 #:snapshot? #t))
            (for/list ([i (in-range 6)]) (mk-h (+ 910 i) 'locust-mp (+ 56.0 i) 50.0 #:hp 0.0))))

  (define pure-sim (map (lambda (h) (unit-hash->tactical-sim-unit h 'enemy)) pure-wave))
  (define mixed-sim (map (lambda (h) (unit-hash->tactical-sim-unit h 'enemy)) mixed-zerg))

  (check! (and (locust-wave-dominates-nearby-threat? allies-h pure-wave)
               (not (locust-wave-dominates-nearby-threat? allies-h mixed-zerg))
               (not (locust-wave-dominates-nearby-threat? allies-h mixed-moderate))
               (locust-wave-dominates-nearby-threat? allies-h locust-dominated)
               (not (locust-wave-dominates-nearby-threat? allies-h distant-wave))
               (not (locust-wave-dominates-nearby-threat? allies-h tiny-remnant))
               (not (locust-wave-dominates-nearby-threat? allies-h dead-or-snap))
               (locust-wave-dominates-nearby-threat? allies-sim pure-sim)
               (not (locust-wave-dominates-nearby-threat? allies-sim mixed-sim)))
          (format "8. locust-wave-dominates-nearby-threat? mismatch: pure=~s mixed=~s mod=~s dom=~s dist=~s tiny=~s dead=~s sim-pure=~s sim-mixed=~s"
                  (locust-wave-dominates-nearby-threat? allies-h pure-wave)
                  (locust-wave-dominates-nearby-threat? allies-h mixed-zerg)
                  (locust-wave-dominates-nearby-threat? allies-h mixed-moderate)
                  (locust-wave-dominates-nearby-threat? allies-h locust-dominated)
                  (locust-wave-dominates-nearby-threat? allies-h distant-wave)
                  (locust-wave-dominates-nearby-threat? allies-h tiny-remnant)
                  (locust-wave-dominates-nearby-threat? allies-h dead-or-snap)
                  (locust-wave-dominates-nearby-threat? allies-sim pure-sim)
                  (locust-wave-dominates-nearby-threat? allies-sim mixed-sim))))

;; =============================================================================
;; 9. PvZ 2-Ling / Fogged-Hatch False 12-Pool Panic Fix (`#2554` #1)
;; =============================================================================
(let ()
  (define st-pvz-normal
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Zerg #:frame 2240
     #:minerals 350 #:gas 40 #:supply-used 19 #:supply-cap 23 #:supply-left 4 #:pending-supply 0
     #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
     #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
     #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
     #:unit-counts (hasheq 'probe 19)
     #:enemy-unit-counts (hasheq 'zergling 2)
     #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 1)
     #:open-facility-slots (hasheq 'townhall 1 'gateway 1)))
  (define dec-pvz-normal (step-priority-macro-brain st-pvz-normal))

  ;; Real incoming 6-ling 12-Pool rush (threat=3.0) MUST still block Nexus #2 and defend!
  (define st-pvz-real-12p
    (struct-copy macro-world-state st-pvz-normal
                 [enemy-threat-supply 3.0]))
  (define dec-pvz-real-12p
    (step-priority-macro-brain st-pvz-real-12p
                               #:enemy-unit-counts (hasheq 'zergling 6)
                               #:enemy-building-counts (hasheq 'spawning-pool 1 'hatchery 1)))
  (check! (and (eq? (macro-brain-decision-saving-for dec-pvz-normal) 'nexus)
               (not (memq 'zealot (scheduled-syms dec-pvz-normal)))
               (not (eq? (macro-brain-decision-saving-for dec-pvz-real-12p) 'nexus))
               (memq 'zealot (scheduled-syms dec-pvz-real-12p)))
          (format "9. PvZ 2 passive lings + normal Pool w/ fogged natural must keep saving-for=nexus without panic Zealot; real 6-ling rush must defend; norm=~s norm-sched=~s rush=~s rush-sched=~s"
                  (macro-brain-decision-saving-for dec-pvz-normal)
                  (scheduled-syms dec-pvz-normal)
                  (macro-brain-decision-saving-for dec-pvz-real-12p)
                  (scheduled-syms dec-pvz-real-12p))))

;; =============================================================================
;; 10. 1-Scout (`threat = 1.0`) Must Not Trigger `protoss-early-breach` (`#2554` #2)
;; =============================================================================
(let ()
  (define st-1scout
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Protoss #:frame 2400
     #:minerals 280 #:gas 100 #:supply-used 20 #:supply-cap 31 #:supply-left 11 #:pending-supply 0
     #:workers 20 #:active-bases 1 #:mineral-harvesters 14 #:gas-harvesters 6
     #:army-supply 0 #:enemy-threat-supply 1.0 #:under-attack? #f #:requires-anti-air? #f
     #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 1)
     #:total-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 1)
     #:unit-counts (hasheq 'probe 20)
     #:open-facility-slots (hasheq 'townhall 1 'gateway 1 'cybernetics-core 1)))
  (define dec-1scout (step-priority-macro-brain st-1scout))

  ;; Real combat breach (threat=3.0 >= 2.0) MUST trigger zealot@940 and suppress Nexus!
  (define st-real-breach
    (struct-copy macro-world-state st-1scout [enemy-threat-supply 3.0]))
  (define dec-breach (step-priority-macro-brain st-real-breach))
  (check! (and (eq? (macro-brain-decision-saving-for dec-1scout) 'nexus)
               (< (cand-u dec-1scout 'zealot) 900.0)
               (>= (cand-u dec-breach 'zealot) 940.0)
               (not (eq? (macro-brain-decision-saving-for dec-breach) 'nexus)))
          (format "10. 1-scout (threat=1.0) must keep Natural Nexus & not force zealot@940; threat=3.0 must trigger breach; 1sc-sav=~s 1sc-z=~s br-z=~s br-sav=~s"
                  (macro-brain-decision-saving-for dec-1scout)
                  (cand-u dec-1scout 'zealot)
                  (cand-u dec-breach 'zealot)
                  (macro-brain-decision-saving-for dec-breach))))

;; =============================================================================
;; 11. Blocked-Natural Zerg 300M 3rd-as-Natural Not Suppressed < 350M (`#2554` #3)
;; =============================================================================
(let ()
  (define st-z-blocked
    (make-macro-world-state
     #:race 'Zerg #:enemy-race 'Protoss #:frame 1150
     #:minerals 300 #:gas 0 #:supply-used 16 #:supply-cap 22 #:supply-left 6 #:pending-supply 0
     #:workers 16 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 0
     #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
     #:natural-blocked? #t
     #:ready-building-counts (hasheq 'hatchery 1)
     #:total-building-counts (hasheq 'hatchery 1)
     #:unit-counts (hasheq 'drone 16 'overlord 2)
     #:open-facility-slots (hasheq 'larva 2)))
  (define dec-z-blocked (step-priority-macro-brain st-z-blocked))
  (check! (or (memq 'hatchery (scheduled-syms dec-z-blocked))
              (memq 'expand (scheduled-syms dec-z-blocked)))
          (format "11. Zerg at 300M with ws-natural-blocked?=#t must schedule hatchery (3rd-as-Natural); sched=~s sav=~s hat-u=~s"
                  (scheduled-syms dec-z-blocked)
                  (macro-brain-decision-saving-for dec-z-blocked)
                  (cand-u dec-z-blocked 'hatchery))))

(printf "l81-div8-macro-tactics-test: ~a passed, ~a failed\n" passed failed)
(when (> failed 0)
  (exit 1))
