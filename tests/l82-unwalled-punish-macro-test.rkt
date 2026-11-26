#lang racket/base

;; =============================================================================
;; Loop 82 Track C Unit Test Suite (`tests/l82-unwalled-punish-macro-test.rkt`)
;;
;; Verifies scout-triggered macro-transition unwalled-opponent punish in
;; `lib/priority-macro-brain.rkt`:
;;   1. Enemy wall state decoding (`enemy-wall-assessment->open?`, `obs` keys,
;;      `make-macro-world-state`, `step-priority-macro-brain` kwargs), defaulting
;;      safely to `#f` when unscouted.
;;   2. Protoss (`PvZ`, `PvP`, `PvT`): 2 Adepts vs open Zerg/Protoss, 3 Adepts
;;      vs open Terran (1:45..4:30), strict hard cap at 2/3 total Adepts
;;      resuming Probes/Nexus/macro, never cutting Natural Nexus or Probes,
;;      0 Adepts when walled, unscouted, outside window, or under attack.
;;   3. Zerg (`ZvP`, `ZvT`): 14-16 Speedlings vs open Protoss/Terran (2:00..4:15,
;;      Spawning Pool ready, Metabolic Boost started/ready), keeping 2-base Queen
;;      and Speed intact, strict hard cap at 16 Lings or 4:15 resuming Drones and
;;      3rd Hatchery, 0 blind flood when walled, unscouted, static-defended,
;;      before 2:00, missing Speed, under attack, or ZvZ.
;; =============================================================================

(require racket/list
         racket/format
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

(define (cand-u dec sym)
  (define hit (findf (lambda (e) (eq? (priority-decision-entry-id e) sym))
                     (decision-trace dec)))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

(define (scheduled-syms dec)
  (macro-brain-decision-scheduled-ids dec))

;; Local transparent struct matching EnemyWallAssessment layout for pure decode tests
(struct EnemyWallAssessment
  (wall-state unwalled-posterior wall-structure-count lowered-depot-count
   door-gap-units static-defense-count entry-x entry-y)
  #:transparent)

;; =============================================================================
;; 1. Enemy Wall Assessment Decoding & Default Safety
;; =============================================================================
(let ()
  (check! (not (enemy-wall-assessment->open? #f))
          "1a. #f assessment decodes to #f")
  (check! (enemy-wall-assessment->open? #t)
          "1b. #t assessment decodes to #t")
  (check! (and (enemy-wall-assessment->open? 'no-wall)
               (enemy-wall-assessment->open? 'gapped-wall)
               (enemy-wall-assessment->open? 'open-depot-door)
               (not (enemy-wall-assessment->open? 'walled))
               (not (enemy-wall-assessment->open? 'unknown-unscouted)))
          "1c. Symbol wall states decode accurately")
  (check! (and (enemy-wall-assessment->open?
                (hasheq 'wall-state 'no-wall 'unwalled-posterior 0.82 'static-defense-count 0))
               (not (enemy-wall-assessment->open?
                     (hasheq 'wall-state 'walled 'unwalled-posterior 0.02)))
               (not (enemy-wall-assessment->open?
                     (hasheq 'wall-state 'no-wall 'scouted? #f 'unwalled-posterior 0.82)))
               (not (enemy-wall-assessment->open?
                     (hasheq 'wall-state 'no-wall 'unwalled-posterior 0.35)))
               (not (enemy-wall-assessment->open?
                     (hasheq 'wall-state 'no-wall 'unwalled-posterior 0.82 'static-defense-count 1)
                     #:reject-static-defense? #t)))
          "1d. Hash wall assessments enforce scouted?, posterior, and static-defense gates")
  (check! (and (enemy-wall-assessment->open?
                (EnemyWallAssessment 'no-wall 0.82 0 0 0 0 100.0 100.0))
               (enemy-wall-assessment->open?
                (EnemyWallAssessment 'open-depot-door 0.93 2 1 1 0 100.0 100.0))
               (not (enemy-wall-assessment->open?
                     (EnemyWallAssessment 'walled 0.02 3 0 0 0 100.0 100.0)))
               (not (enemy-wall-assessment->open?
                     (EnemyWallAssessment 'unknown-unscouted 0.18 0 0 0 0 100.0 100.0)))
               (not (enemy-wall-assessment->open?
                     (EnemyWallAssessment 'no-wall 0.62 0 0 0 1 100.0 100.0)
                     #:reject-static-defense? #t)))
          "1e. Transparent EnemyWallAssessment structs decode accurately without extra module import")
  (check! (and (= (protoss-unwalled-adept-target 'Zerg) 2)
               (= (protoss-unwalled-adept-target 'Protoss) 2)
               (= (protoss-unwalled-adept-target 'Terran) 3))
          "1f. Protoss unwalled Adept target: 2 vs Z/P (44 >= 40 HP), 3 vs T (66 >= 45 HP)")

  ;; Default make-macro-world-state & obs-hash->macro-world-state must default safely to #f
  (define ws-default (make-macro-world-state #:race 'Protoss #:enemy-race 'Zerg))
  (define ws-obs-default (obs-hash->macro-world-state (hasheq 'race 'Protoss 'enemy-race 'Zerg 'frame 3360)))
  (define ws-obs-open
    (obs-hash->macro-world-state
     (hasheq 'race 'Protoss 'enemy-race 'Terran 'frame 3360
             'enemy-wall-assessment (hasheq 'wall-state 'no-wall 'unwalled-posterior 0.85)
             'total-adepts-produced 2)))
  (define ws-mirror-open
    (make-macro-world-state
     #:race 'Zerg #:enemy-race 'Protoss #:frame 3600
     #:mirror-signals (hasheq 'enemy-wall-open? #t 'total-zerglings-produced 14)))
  (check! (and (not (macro-world-state-enemy-wall-open? ws-default))
               (not (macro-world-state-enemy-wall-open? ws-obs-default))
               (macro-world-state-enemy-wall-open? ws-obs-open)
               (= (macro-world-state-total-adepts-produced ws-obs-open) 2)
               (macro-world-state-enemy-wall-open? ws-mirror-open)
               (= (macro-world-state-total-zerglings-produced ws-mirror-open) 14))
          "1g. World-state accessors default to #f and read obs, assessment, and mirror-signals cleanly"))

;; =============================================================================
;; 2. Protoss Macro-Transition Unwalled Adept Punish (PvZ, PvP, PvT)
;; =============================================================================
(let ()
  (define (mk-protoss-state enemy-race
                            #:frame [frame 3360]
                            #:minerals [minerals 180]
                            #:gas [gas 80]
                            #:workers [workers 24]
                            #:active-bases [active-bases 2]
                            #:adepts [adepts 0]
                            #:stalkers [stalkers 0]
                            #:under-attack? [under-attack? #f]
                            #:enemy-wall-open? [wall-open? 'unset]
                            #:enemy-wall-assessment [wall-assess #f]
                            #:total-adepts-produced [total-adepts #f]
                            #:open-th [open-th 1]
                            #:open-gw [open-gw 1]
                            #:pending-upgs [pending-upgs '(warp-gate-research)])
    (define bldgs (hasheq 'nexus active-bases 'pylon 3 'gateway 2
                          'cybernetics-core 1 'assimilator 2))
    (make-macro-world-state
     #:race 'Protoss #:enemy-race enemy-race #:frame frame
     #:minerals minerals #:gas gas
     #:supply-used (+ workers (* 2 (+ adepts stalkers)))
     #:supply-cap 46 #:supply-left (- 46 (+ workers (* 2 (+ adepts stalkers))))
     #:pending-supply 0
     #:workers workers #:active-bases active-bases
     #:mineral-harvesters (- workers 6) #:gas-harvesters 6
     #:army-supply (* 2 (+ adepts stalkers))
     #:enemy-threat-supply (if under-attack? 8 0)
     #:under-attack? under-attack?
     #:ready-building-counts bldgs
     #:total-building-counts bldgs
     #:unit-counts (hasheq 'probe workers 'adept adepts 'stalker stalkers)
     #:pending-upgrades pending-upgs
     #:open-facility-slots (hasheq 'townhall open-th 'gateway open-gw 'cybernetics-core 0)
     #:enemy-wall-open? wall-open?
     #:enemy-wall-assessment wall-assess
     #:total-adepts-produced total-adepts))

  ;; 2a. Open Zerg (PvZ): trains Adept #1 and #2 alongside Probes, then hard-stops at 2!
  (reset-macro-escrow-tracker!)
  (define d-pvz-0 (step-priority-macro-brain (mk-protoss-state 'Zerg #:adepts 0 #:enemy-wall-open? #t)))
  (define d-pvz-1 (step-priority-macro-brain (mk-protoss-state 'Zerg #:adepts 1 #:enemy-wall-open? #t)))
  (define d-pvz-2 (step-priority-macro-brain (mk-protoss-state 'Zerg #:adepts 2 #:enemy-wall-open? #t)))
  (define d-pvz-lost-cap
    (step-priority-macro-brain
     (mk-protoss-state 'Zerg #:adepts 1 #:total-adepts-produced 2 #:enemy-wall-open? #t)))
  (check! (and (memq 'adept (scheduled-syms d-pvz-0))
               (memq 'probe (scheduled-syms d-pvz-0))
               (memq 'adept (scheduled-syms d-pvz-1))
               (not (memq 'adept (scheduled-syms d-pvz-2)))
               (memq 'probe (scheduled-syms d-pvz-2))
               (not (memq 'adept (scheduled-syms d-pvz-lost-cap))))
          (format "2a. PvZ open wall must train 2 Adepts alongside Probes then hard-stop; s0=~s s1=~s s2=~s slost=~s"
                  (scheduled-syms d-pvz-0) (scheduled-syms d-pvz-1)
                  (scheduled-syms d-pvz-2) (scheduled-syms d-pvz-lost-cap)))

  ;; 2b. Open Protoss (PvP): trains 2 Adepts then hard-stops at 2!
  (reset-macro-escrow-tracker!)
  (define d-pvp-0 (step-priority-macro-brain (mk-protoss-state 'Protoss #:adepts 0 #:enemy-wall-open? #t)))
  (define d-pvp-1 (step-priority-macro-brain (mk-protoss-state 'Protoss #:adepts 1 #:enemy-wall-open? #t)))
  (define d-pvp-2 (step-priority-macro-brain (mk-protoss-state 'Protoss #:adepts 2 #:enemy-wall-open? #t)))
  (check! (and (memq 'adept (scheduled-syms d-pvp-0))
               (memq 'adept (scheduled-syms d-pvp-1))
               (not (memq 'adept (scheduled-syms d-pvp-2)))
               (or (memq 'probe (scheduled-syms d-pvp-2))
                   (memq 'stalker (scheduled-syms d-pvp-2))))
          (format "2b. PvP open wall must train 2 Adepts then resume macro; s0=~s s1=~s s2=~s"
                  (scheduled-syms d-pvp-0) (scheduled-syms d-pvp-1) (scheduled-syms d-pvp-2)))

  ;; 2c. Open Terran (PvT): trains 3 Adepts (3 x 22 = 66 >= 45 HP SCV 1-volley) then hard-stops at 3!
  (reset-macro-escrow-tracker!)
  (define d-pvt-0 (step-priority-macro-brain (mk-protoss-state 'Terran #:adepts 0 #:enemy-wall-open? #t)))
  (define d-pvt-2 (step-priority-macro-brain (mk-protoss-state 'Terran #:adepts 2 #:enemy-wall-open? #t)))
  (define d-pvt-3 (step-priority-macro-brain (mk-protoss-state 'Terran #:adepts 3 #:enemy-wall-open? #t)))
  (define d-pvt-lost-cap
    (step-priority-macro-brain
     (mk-protoss-state 'Terran #:adepts 2 #:total-adepts-produced 3 #:enemy-wall-open? #t)))
  (check! (and (memq 'adept (scheduled-syms d-pvt-0))
               (memq 'adept (scheduled-syms d-pvt-2))
               (not (memq 'adept (scheduled-syms d-pvt-3)))
               (not (memq 'adept (scheduled-syms d-pvt-lost-cap))))
          (format "2c. PvT open wall must train 3 Adepts then hard-stop at 3; s0=~s s2=~s s3=~s slost=~s"
                  (scheduled-syms d-pvt-0) (scheduled-syms d-pvt-2)
                  (scheduled-syms d-pvt-3) (scheduled-syms d-pvt-lost-cap)))

  ;; 2d. NEVER cut Probes when minerals are tight (120M/60G w/ open TownHall -> Probe MUST schedule first!)
  (reset-macro-escrow-tracker!)
  (define d-probe-first
    (step-priority-macro-brain
     (mk-protoss-state 'Zerg #:minerals 120 #:gas 60 #:adepts 0 #:enemy-wall-open? #t #:open-th 1 #:open-gw 1)))
  (check! (and (memq 'probe (scheduled-syms d-probe-first))
               (> (cand-u d-probe-first 'probe) (cand-u d-probe-first 'adept)))
          (format "2d. Unwalled Adept punish must NEVER cut Probes at 120M; sched=~s probe-u=~a adept-u=~a"
                  (scheduled-syms d-probe-first)
                  (cand-u d-probe-first 'probe)
                  (cand-u d-probe-first 'adept)))

  ;; 2e. NEVER cut Natural Nexus on 1-base PvP expand window!
  (reset-macro-escrow-tracker!)
  (define d-nat-first
    (step-priority-macro-brain
     (mk-protoss-state 'Protoss #:frame 2500 #:minerals 270 #:gas 80 #:workers 20
                       #:active-bases 1 #:adepts 0 #:stalkers 1 #:enemy-wall-open? #t)))
  (check! (and (eq? (macro-brain-decision-saving-for d-nat-first) 'nexus)
               (not (memq 'adept (scheduled-syms d-nat-first))))
          (format "2e. Unwalled Adept punish must NEVER cut Natural Nexus; sav=~s sched=~s"
                  (macro-brain-decision-saving-for d-nat-first) (scheduled-syms d-nat-first)))

  ;; 2f. Walled or unscouted -> 0 Adepts across PvZ, PvP, PvT!
  (reset-macro-escrow-tracker!)
  (define d-pvz-walled (step-priority-macro-brain (mk-protoss-state 'Zerg #:adepts 0 #:enemy-wall-open? #f)))
  (define d-pvz-unscouted (step-priority-macro-brain (mk-protoss-state 'Zerg #:adepts 0)))
  (define d-pvp-walled
    (step-priority-macro-brain
     (mk-protoss-state 'Protoss #:adepts 0
                       #:enemy-wall-assessment (EnemyWallAssessment 'walled 0.02 3 0 0 0 100.0 100.0))))
  (define d-pvt-unscouted (step-priority-macro-brain (mk-protoss-state 'Terran #:adepts 0)))
  (check! (and (not (memq 'adept (scheduled-syms d-pvz-walled)))
               (not (memq 'adept (scheduled-syms d-pvz-unscouted)))
               (not (memq 'adept (scheduled-syms d-pvp-walled)))
               (not (memq 'adept (scheduled-syms d-pvt-unscouted))))
          (format "2f. Walled/unscouted Protoss must train 0 Adepts; pvz-w=~s pvz-u=~s pvp-w=~s pvt-u=~s"
                  (scheduled-syms d-pvz-walled) (scheduled-syms d-pvz-unscouted)
                  (scheduled-syms d-pvp-walled) (scheduled-syms d-pvt-unscouted)))

  ;; 2g. Frame window [1:45, 4:30] = [2352, 6048] and under-attack? gates
  (reset-macro-escrow-tracker!)
  (define d-p-too-early (step-priority-macro-brain (mk-protoss-state 'Zerg #:frame 2200 #:adepts 0 #:enemy-wall-open? #t)))
  (define d-p-too-late  (step-priority-macro-brain (mk-protoss-state 'Zerg #:frame 6100 #:adepts 0 #:enemy-wall-open? #t)))
  (define d-p-attacked  (step-priority-macro-brain (mk-protoss-state 'Terran #:frame 3500 #:adepts 0 #:under-attack? #t #:enemy-wall-open? #t)))
  (check! (and (not (memq 'adept (scheduled-syms d-p-too-early)))
               (not (memq 'adept (scheduled-syms d-p-too-late)))
               (not (memq 'adept (scheduled-syms d-p-attacked))))
          (format "2g. Protoss Adept punish must respect [2352, 6048] window and not under-attack?; early=~s late=~s atk=~s"
                  (scheduled-syms d-p-too-early) (scheduled-syms d-p-too-late) (scheduled-syms d-p-attacked)))

  ;; 2h. End-to-end via obs-hash->macro-world-state with EnemyWallAssessment struct
  (reset-macro-escrow-tracker!)
  (define obs-pvt-open
    (hasheq 'race 'Protoss 'enemy-race 'Terran 'frame 3500
            'minerals 220 'gas 80 'supply-used 28 'supply-cap 46 'supply-left 18
            'pending-supply 0 'pending-workers 0 'army-supply 4 'enemy-threat-supply 0
            'under-attack? #f 'pending-upgrades '(warp-gate-research)
            'ally-units (append (for/list ([i (in-range 24)]) (hasheq 'type 'probe))
                                (list (hasheq 'type 'adept) (hasheq 'type 'adept)))
            'ally-buildings (list (hasheq 'type 'nexus 'build-progress 1.0)
                                  (hasheq 'type 'nexus 'build-progress 1.0)
                                  (hasheq 'type 'pylon 'build-progress 1.0)
                                  (hasheq 'type 'pylon 'build-progress 1.0)
                                  (hasheq 'type 'pylon 'build-progress 1.0)
                                  (hasheq 'type 'gateway 'build-progress 1.0)
                                  (hasheq 'type 'gateway 'build-progress 1.0)
                                  (hasheq 'type 'cybernetics-core 'build-progress 1.0)
                                  (hasheq 'type 'assimilator 'build-progress 1.0)
                                  (hasheq 'type 'assimilator 'build-progress 1.0))
            'open-facility-slots (hasheq 'townhall 1 'gateway 1 'cybernetics-core 0)
            'enemy-wall-assessment (EnemyWallAssessment 'no-wall 0.85 0 0 0 0 120.0 120.0)))
  (define d-obs-pvt (step-priority-macro-brain (obs-hash->macro-world-state obs-pvt-open 'Protoss)))
  (check! (and (memq 'adept (scheduled-syms d-obs-pvt))
               (memq 'probe (scheduled-syms d-obs-pvt)))
          (format "2h. obs-hash->macro-world-state with open EnemyWallAssessment schedules 3rd Adept vs Terran + Probe; sched=~s"
                  (scheduled-syms d-obs-pvt))))

;; =============================================================================
;; 3. Zerg Macro-Transition Unwalled Speedling Flood (ZvP, ZvT)
;; =============================================================================
(let ()
  (define (mk-zerg-state enemy-race
                         #:frame [frame 3800]
                         #:minerals [minerals 220]
                         #:gas [gas 40]
                         #:workers [workers 24]
                         #:active-bases [active-bases 2]
                         #:queens [queens 2]
                         #:lings [lings 4]
                         #:roach-warren? [roach-warren? #f]
                         #:speed-state [speed-state 'pending] ;; 'none | 'pending | 'researched
                         #:under-attack? [under-attack? #f]
                         #:enemy-wall-open? [wall-open? 'unset]
                         #:enemy-wall-assessment [wall-assess #f]
                         #:enemy-building-counts [enemy-b-counts (hasheq)]
                         #:total-zerglings-produced [total-lings #f]
                         #:open-larva [open-larva 4]
                         #:open-th [open-th 2])
    (define bldgs
      (if roach-warren?
          (hasheq 'hatchery active-bases 'spawning-pool 1 'extractor 1 'roach-warren 1)
          (hasheq 'hatchery active-bases 'spawning-pool 1 'extractor 1)))
    (define res-upgs (if (eq? speed-state 'researched) '(metabolic-boost) '()))
    (define pen-upgs (if (eq? speed-state 'pending) '(metabolic-boost) '()))
    (define sup-used (+ workers (* 2 queens) (quotient lings 2)))
    (make-macro-world-state
     #:race 'Zerg #:enemy-race enemy-race #:frame frame
     #:minerals minerals #:gas gas
     #:supply-used sup-used #:supply-cap 52 #:supply-left (- 52 sup-used)
     #:pending-supply 0
     #:workers workers #:active-bases active-bases
     #:mineral-harvesters (- workers 3) #:gas-harvesters 3
     #:army-supply (+ (* 2 queens) (quotient lings 2))
     #:enemy-threat-supply (if under-attack? 8 0)
     #:under-attack? under-attack?
     #:ready-building-counts bldgs
     #:total-building-counts bldgs
     #:unit-counts (hasheq 'drone workers 'queen queens 'zergling lings)
     #:enemy-building-counts enemy-b-counts
     #:researched-upgrades res-upgs
     #:pending-upgrades pen-upgs
     #:open-facility-slots (hasheq 'larva open-larva 'townhall open-th 'spawning-pool (if (eq? speed-state 'none) 1 0))
     #:enemy-wall-open? wall-open?
     #:enemy-wall-assessment wall-assess
     #:total-zerglings-produced total-lings))

  ;; 3a. Open Protoss (ZvP): floods Speedlings from 4 -> 14 -> 16 (w/ 2 Queens & 0 RW), then HARD STOPS at 16 & resumes Drones + 3rd Hatch!
  (reset-macro-escrow-tracker!)
  (define d-zvp-4  (step-priority-macro-brain (mk-zerg-state 'Protoss #:lings 4 #:enemy-wall-open? #t)))
  (define d-zvp-14 (step-priority-macro-brain (mk-zerg-state 'Protoss #:lings 14 #:enemy-wall-open? #t)))
  (define d-zvp-16-macro
    (step-priority-macro-brain (mk-zerg-state 'Protoss #:lings 16 #:minerals 220 #:enemy-wall-open? #t)))
  (define d-zvp-16-drone
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:lings 16 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #t)))
  (define d-zvp-16-hatch
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:lings 16 #:workers 28 #:minerals 320 #:frame 4500 #:roach-warren? #t #:enemy-wall-open? #t)))
  (define d-zvp-lost-cap
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:lings 10 #:total-zerglings-produced 16 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #t)))
  (check! (and (memq 'zergling (scheduled-syms d-zvp-4))
               (not (memq 'drone (scheduled-syms d-zvp-4)))
               (memq 'zergling (scheduled-syms d-zvp-14))
               (not (memq 'zergling (scheduled-syms d-zvp-16-macro)))
               (not (memq 'zergling (scheduled-syms d-zvp-16-drone)))
               (memq 'drone (scheduled-syms d-zvp-16-drone))
               (not (memq 'zergling (scheduled-syms d-zvp-16-hatch)))
               (or (memq 'hatchery (scheduled-syms d-zvp-16-hatch))
                   (eq? (macro-brain-decision-saving-for d-zvp-16-hatch) 'hatchery))
               (not (memq 'zergling (scheduled-syms d-zvp-lost-cap)))
               (memq 'drone (scheduled-syms d-zvp-lost-cap)))
          (format "3a. ZvP open wall must train up to 16 Speedlings then hard-stop & resume Drones/3rd Hatch; s4=~s s14=~s s16m=~s s16d=~s s16h=~s(sav=~s) slost=~s"
                  (scheduled-syms d-zvp-4) (scheduled-syms d-zvp-14)
                  (scheduled-syms d-zvp-16-macro) (scheduled-syms d-zvp-16-drone)
                  (scheduled-syms d-zvp-16-hatch)
                  (macro-brain-decision-saving-for d-zvp-16-hatch)
                  (scheduled-syms d-zvp-lost-cap)))

  ;; 3b. Open Terran (ZvT): floods Speedlings when scouted open, hard-stops at 16 & resumes Drones!
  (reset-macro-escrow-tracker!)
  (define d-zvt-open-4
    (step-priority-macro-brain
     (mk-zerg-state 'Terran #:lings 4 #:speed-state 'researched #:enemy-wall-open? #t)))
  (define d-zvt-open-16
    (step-priority-macro-brain
     (mk-zerg-state 'Terran #:lings 16 #:queens 3 #:roach-warren? #t #:speed-state 'researched #:minerals 160 #:enemy-wall-open? #t)))
  (check! (and (memq 'zergling (scheduled-syms d-zvt-open-4))
               (not (memq 'zergling (scheduled-syms d-zvt-open-16)))
               (memq 'drone (scheduled-syms d-zvt-open-16)))
          (format "3b. ZvT open wall must flood Speedlings up to 16 then resume Drones; s4=~s s16=~s"
                  (scheduled-syms d-zvt-open-4) (scheduled-syms d-zvt-open-16)))

  ;; 3c. Strict 4:15 (5712f) hard time cutoff: at frame 5750 even with only 10 Lings, resumes Drones!
  (reset-macro-escrow-tracker!)
  (define d-zvp-past-415
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:frame 5750 #:lings 10 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #t)))
  (check! (and (memq 'drone (scheduled-syms d-zvp-past-415))
               (not (> (cand-u d-zvp-past-415 'zergling) (cand-u d-zvp-past-415 'drone))))
          (format "3c. Zerg Speedling punish must hard-stop past 4:15 (5712f) and resume Drones; sched=~s ling-u=~a drone-u=~a"
                  (scheduled-syms d-zvp-past-415)
                  (cand-u d-zvp-past-415 'zergling)
                  (cand-u d-zvp-past-415 'drone)))

  ;; 3d. Keeps 2-base Queen (#2) AND Metabolic Boost intact!
  (reset-macro-escrow-tracker!)
  (define d-zvp-queen2
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:queens 1 #:lings 4 #:minerals 240 #:enemy-wall-open? #t)))
  (define d-zvp-need-speed
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:queens 2 #:lings 4 #:minerals 160 #:gas 100 #:speed-state 'none #:enemy-wall-open? #t)))
  (define d-zvp-no-speed-no-gas
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:queens 3 #:roach-warren? #t #:lings 4 #:minerals 160 #:gas 25 #:speed-state 'none #:enemy-wall-open? #t)))
  (check! (and (memq 'queen (scheduled-syms d-zvp-queen2))
               (memq 'zergling (scheduled-syms d-zvp-queen2))
               (> (cand-u d-zvp-queen2 'queen) (cand-u d-zvp-queen2 'zergling))
               (memq 'metabolic-boost (scheduled-syms d-zvp-need-speed))
               (memq 'drone (scheduled-syms d-zvp-no-speed-no-gas))
               (not (> (cand-u d-zvp-no-speed-no-gas 'zergling) (cand-u d-zvp-no-speed-no-gas 'drone))))
          (format "3d. Zerg must keep 2-base Queen & Metabolic Boost intact and not flood slow Lings; q2=~s speed=~s nospeed=~s"
                  (scheduled-syms d-zvp-queen2) (scheduled-syms d-zvp-need-speed)
                  (scheduled-syms d-zvp-no-speed-no-gas)))

  ;; 3e. Walled / unscouted / choke static-def / < 2:00 / ZvZ / under-attack -> ZERO Speedling flood!
  (reset-macro-escrow-tracker!)
  (define d-zvt-walled
    (step-priority-macro-brain (mk-zerg-state 'Terran #:lings 4 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #f)))
  (define d-zvt-unscouted
    (step-priority-macro-brain (mk-zerg-state 'Terran #:lings 4 #:queens 3 #:roach-warren? #t #:minerals 160)))
  (define d-zvp-walled
    (step-priority-macro-brain (mk-zerg-state 'Protoss #:lings 4 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #f)))
  (define d-zvp-cannon
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:lings 4 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #t
                    #:enemy-building-counts (hasheq 'photon-cannon 1))))
  (define d-zvp-too-early
    (step-priority-macro-brain (mk-zerg-state 'Protoss #:frame 2500 #:lings 4 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #t)))
  (define d-zvz-open
    (step-priority-macro-brain (mk-zerg-state 'Zerg #:lings 6 #:queens 3 #:roach-warren? #t #:minerals 160 #:enemy-wall-open? #t)))
  (check! (and (memq 'drone (scheduled-syms d-zvt-walled))
               (not (> (cand-u d-zvt-walled 'zergling) (cand-u d-zvt-walled 'drone)))
               (memq 'drone (scheduled-syms d-zvt-unscouted))
               (not (> (cand-u d-zvt-unscouted 'zergling) (cand-u d-zvt-unscouted 'drone)))
               (memq 'drone (scheduled-syms d-zvp-walled))
               (not (> (cand-u d-zvp-walled 'zergling) (cand-u d-zvp-walled 'drone)))
               (memq 'drone (scheduled-syms d-zvp-cannon))
               (not (> (cand-u d-zvp-cannon 'zergling) (cand-u d-zvp-cannon 'drone)))
               (memq 'drone (scheduled-syms d-zvp-too-early))
               (not (> (cand-u d-zvp-too-early 'zergling) (cand-u d-zvp-too-early 'drone)))
               (memq 'drone (scheduled-syms d-zvz-open))
               (not (> (cand-u d-zvz-open 'zergling) (cand-u d-zvz-open 'drone))))
          (format "3e. Zerg must NOT blind-flood when walled, unscouted, cannon-held, <2:00, or ZvZ; zvt-w=~s zvt-u=~s zvp-w=~s cannon=~s early=~s zvz=~s"
                  (scheduled-syms d-zvt-walled) (scheduled-syms d-zvt-unscouted)
                  (scheduled-syms d-zvp-walled) (scheduled-syms d-zvp-cannon)
                  (scheduled-syms d-zvp-too-early) (scheduled-syms d-zvz-open)))

  ;; 3f. Under-attack defense must NOT be capped at 16 Lings even if enemy-wall-open? is #t!
  (reset-macro-escrow-tracker!)
  (define d-zvp-under-atk
    (step-priority-macro-brain
     (mk-zerg-state 'Protoss #:lings 16 #:minerals 160 #:under-attack? #t #:enemy-wall-open? #t)))
  (check! (memq 'zergling (scheduled-syms d-zvp-under-atk))
          (format "3f. Under-attack Zerg defense must NOT be capped at 16 Lings; sched=~s"
                  (scheduled-syms d-zvp-under-atk)))

  ;; 3g. End-to-end via obs-hash->macro-world-state with 'enemy-wall-open? #t
  (reset-macro-escrow-tracker!)
  (define obs-zvp-open
    (hasheq 'race 'Zerg 'enemy-race 'Protoss 'frame 3800
            'minerals 200 'gas 40 'supply-used 30 'supply-cap 52 'supply-left 22
            'pending-supply 0 'pending-workers 0 'army-supply 6 'enemy-threat-supply 0
            'under-attack? #f 'pending-upgrades '(metabolic-boost)
            'ally-units (append (for/list ([i (in-range 24)]) (hasheq 'type 'drone))
                                (list (hasheq 'type 'queen) (hasheq 'type 'queen)
                                      (hasheq 'type 'zergling) (hasheq 'type 'zergling)
                                      (hasheq 'type 'zergling) (hasheq 'type 'zergling)))
            'ally-buildings (list (hasheq 'type 'hatchery 'build-progress 1.0)
                                  (hasheq 'type 'hatchery 'build-progress 1.0)
                                  (hasheq 'type 'spawning-pool 'build-progress 1.0)
                                  (hasheq 'type 'extractor 'build-progress 1.0))
            'open-facility-slots (hasheq 'larva 4 'townhall 2 'spawning-pool 0)
            'enemy-wall-open? #t))
  (define d-obs-zvp (step-priority-macro-brain (obs-hash->macro-world-state obs-zvp-open 'Zerg)))
  (check! (and (memq 'zergling (scheduled-syms d-obs-zvp))
               (not (memq 'drone (scheduled-syms d-obs-zvp))))
          (format "3g. obs-hash->macro-world-state with enemy-wall-open?=#t schedules Speedling punish; sched=~s"
                  (scheduled-syms d-obs-zvp))))

(printf "l82-unwalled-punish-macro-test: ~a passed, ~a failed\n" passed failed)
(when (> failed 0)
  (exit 1))
