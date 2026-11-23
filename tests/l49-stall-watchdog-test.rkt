#lang racket/base

;; =============================================================================
;; Loop 49 Wave 1: Generalized 4-Law Stall Watchdog Verification Suite
;; (`tests/l49-stall-watchdog-test.rkt`)
;;
;; Tests:
;;   A. Pure `lib/stall-watchdog.rkt` Contract (Laws 1..4 + edge cases + perf):
;;      1. Law 1: `wd-update-goal-progress!` escalating ladder
;;         ('ok -> 'stage1-check-builder >=32f -> 'stage2-expand-ring >=64f
;;          -> 'stage3-release-escrow >=112f + 160f cooldown)
;;      2. Law 1: Progress reset (count increases), non-affordable reset,
;;         cooldown expiry after 160f, and backward frame jump safety
;;      3. Law 2: `wd-gas-valve-mode` ('pull-to-minerals, 'force-saturate-gas,
;;         'normal, food>=175 guard, gas>=450 precedence over vesp=0)
;;      4. Law 2: `wd-zero-income-recovery?` (>=48f at workers>=5 & min-rate<=0,
;;         suppressed under worker rush, resets when min-rate>0 or workers<5)
;;      5. Law 2: `wd-worker-plateau-floor?` (>=160f flat <target w/ TH/larva,
;;         suppressed under early-worker-rush or target reached, resets on +1W)
;;      6. Law 3: `wd-preemptive-supply-urgent?` (dynamic headroom scaling with
;;         prod count & race, opening tiers 14/15/23 preserved, food>=195 & pending>0 guards)
;;      7. Law 3: `wd-idle-bank-flush?` (>=96f >=500M normal & >=150M early rush,
;;         suppressed when supply-capped or no idle prod/larva, resets below thresh)
;;      8. Law 4: `wd-update-halted-buildings!` (unchanged progress <1.0 for >=24f
;;         across pair/list/hash formats, ignores progressing/completed/removed)
;;      9. Micro-perf: all 8 functions < 0.05ms combined average
;;   B. End-to-End `lib/priority-macro-brain.rkt` Integration:
;;     10. Law 1 E2E: Affordable stalled building (`robotics-facility`) escalates
;;         stage1 -> stage2 -> stage3-release-escrow (160f cooldown), releasing
;;         bank to downstream combat units & clearing cleanly after cooldown!
;;     11. Law 2 E2E: Peaceful 2-base worker plateau (>=160f flat at 30W < 44W)
;;         triggers `wd-worker-plateau?`, boosting worker to >=590 & bypassing
;;         midgame tech escrow (while Zerg under attack stays guarded!)
;;     12. Law 3a E2E: Multi-facility Protoss (`6` Gateways at `100/108`, `0` pending)
;;         and Zerg (`4` Hatches at `82/90`, `0` pending) preempt supply BEFORE cap!
;;     13. Law 3b E2E: Early-rush idle bank (`>= 150M` for `>= 96f` with idle Barracks)
;;         and midgame idle bank (`>= 500M` for `>= 96f` with idle Gateways) trigger
;;         `wd-idle-bank-flush?` and flush bank into combat units (`macro-brain-can-spend?` = #t)!
;; =============================================================================

(require racket/list
         racket/format
         "../lib/econ-ledger.rkt"
         "../lib/stall-watchdog.rkt"
         "../lib/priority-macro-brain.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (cand-u dec sym)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))
  (define hit (findf (lambda (e) (eq? (priority-decision-entry-id e) sym)) trace))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

;; ============================================================================
;; A. Pure `lib/stall-watchdog.rkt` Contract Tests
;; ============================================================================

;; (1) Law 1: Escalating progress ladder (ok -> stage1@32f -> stage2@64f -> stage3@112f + 160f cooldown)
(define st1 (make-stall-watchdog-state))
(define s1-0   (wd-update-goal-progress! st1 'barracks #t 1 1000))
(define s1-31  (wd-update-goal-progress! st1 'barracks #t 1 1031))
(define s1-32  (wd-update-goal-progress! st1 'barracks #t 1 1032))
(define s1-63  (wd-update-goal-progress! st1 'barracks #t 1 1063))
(define s1-64  (wd-update-goal-progress! st1 'barracks #t 1 1064))
(define s1-111 (wd-update-goal-progress! st1 'barracks #t 1 1111))
(define s1-112 (wd-update-goal-progress! st1 'barracks #t 1 1112))
(define cd-112 (wd-goal-on-cooldown? st1 'barracks 1112))
(define cd-271 (wd-goal-on-cooldown? st1 'barracks 1271))
(define cd-272 (wd-goal-on-cooldown? st1 'barracks 1272))
(define s1-post (wd-update-goal-progress! st1 'barracks #t 1 1272))
(check! (and (eq? s1-0 'ok)
             (eq? s1-31 'ok)
             (eq? s1-32 'stage1-check-builder)
             (eq? s1-63 'stage1-check-builder)
             (eq? s1-64 'stage2-expand-ring)
             (eq? s1-111 'stage2-expand-ring)
             (eq? s1-112 'stage3-release-escrow)
             cd-112
             cd-271
             (not cd-272)
             (eq? s1-post 'ok))
        (format "L49-WD(1) Law 1 ladder mismatch: 0=~a 31=~a 32=~a 63=~a 64=~a 111=~a 112=~a cd=~a/~a/~a post=~a"
                s1-0 s1-31 s1-32 s1-63 s1-64 s1-111 s1-112 cd-112 cd-271 cd-272 s1-post))

;; (2) Law 1: Progress reset (count increases), non-affordable reset, stale-gap reset, backward frame safety
(define st2 (make-stall-watchdog-state))
(define _s2-init (wd-update-goal-progress! st2 'gateway #t 1 2000))
(define s2-stage1 (wd-update-goal-progress! st2 'gateway #t 1 2040))
;; Count increases 1 -> 2: MUST reset cleanly to 'ok!
(define s2-prog (wd-update-goal-progress! st2 'gateway #t 2 2044))
(define s2-still-ok (wd-update-goal-progress! st2 'gateway #t 2 2070))
;; Becoming unaffordable resets stall timer cleanly
(define s2-st2 (wd-update-goal-progress! st2 'gateway #t 2 2110)) ; +66f -> stage2
(define s2-unaff (wd-update-goal-progress! st2 'gateway #f 2 2114))
(define s2-fresh (wd-update-goal-progress! st2 'gateway #t 2 2118))
;; Continuous steps reach stage3 & set 160f cooldown; backward frame jump clears cooldown cleanly
(define s2-mid (wd-update-goal-progress! st2 'gateway #t 2 2180)) ; +62f -> stage1
(define s2-st3 (wd-update-goal-progress! st2 'gateway #t 2 2230)) ; +112f -> stage3 + cooldown until 2390
(define cd-before-jump (wd-goal-on-cooldown? st2 'gateway 2240))
(define cd-after-jump  (wd-goal-on-cooldown? st2 'gateway 100))
(check! (and (eq? s2-stage1 'stage1-check-builder)
             (eq? s2-prog 'ok)
             (eq? s2-still-ok 'ok)
             (eq? s2-st2 'stage2-expand-ring)
             (eq? s2-unaff 'ok)
             (eq? s2-fresh 'ok)
             (eq? s2-mid 'stage1-check-builder)
             (eq? s2-st3 'stage3-release-escrow)
             cd-before-jump
             (not cd-after-jump))
        (format "L49-WD(2) Law 1 reset/jump mismatch: st1=~a prog=~a ok=~a st2=~a unaff=~a fresh=~a mid=~a st3=~a cd=~a/~a"
                s2-stage1 s2-prog s2-still-ok s2-st2 s2-unaff s2-fresh s2-mid s2-st3 cd-before-jump cd-after-jump))

;; (3) Law 2: `wd-gas-valve-mode`
(check! (and (eq? (wd-gas-valve-mode 150 480 120 40 2 90 400) 'pull-to-minerals)
             (eq? (wd-gas-valve-mode 199 450 0 40 2 174 400) 'pull-to-minerals) ; pull beats force-sat!
             (eq? (wd-gas-valve-mode 150 480 120 40 2 175 400) 'normal)        ; food >= 175 guard
             (eq? (wd-gas-valve-mode 250 480 120 40 2 90 400) 'normal)         ; min >= 200 guard
             (eq? (wd-gas-valve-mode 350 100 0 24 2 50 300) 'force-saturate-gas)
             (eq? (wd-gas-valve-mode 350 100 0 24 2 50 299) 'normal)           ; sec < 300 guard
             (eq? (wd-gas-valve-mode 350 100 0 15 2 50 350) 'normal)           ; workers < 16 guard
             (eq? (wd-gas-valve-mode 350 100 0 24 0 50 350) 'normal)           ; 0 ready gas bldgs
             (eq? (wd-gas-valve-mode 350 100 40 24 2 50 350) 'normal))         ; vesp > 0
        "L49-WD(3) Law 2 wd-gas-valve-mode branches failed")

;; (4) Law 2: `wd-zero-income-recovery?` (>=48f at workers>=5 & min-rate<=0, not worker rush)
(define st4 (make-stall-watchdog-state))
(define z4-0  (wd-zero-income-recovery? st4 44 0 5000 #f))
(define z4-47 (wd-zero-income-recovery? st4 44 0 5047 #f))
(define z4-48 (wd-zero-income-recovery? st4 44 0 5048 #f))
(define z4-wr (wd-zero-income-recovery? st4 14 0 5060 #t)) ; worker rush suppresses & resets!
(define z4-re (wd-zero-income-recovery? st4 14 0 5064 #f)) ; fresh timer after worker rush
(define z4-ok (wd-zero-income-recovery? st4 44 500 5120 #f))
(define z4-lo (wd-zero-income-recovery? st4 4 0 5200 #f))  ; workers < 5 guard
(check! (and (not z4-0) (not z4-47) z4-48 (not z4-wr) (not z4-re) (not z4-ok) (not z4-lo))
        (format "L49-WD(4) Law 2 zero-income mismatch: 0=~a 47=~a 48=~a wr=~a re=~a ok=~a lo=~a"
                z4-0 z4-47 z4-48 z4-wr z4-re z4-ok z4-lo))

;; (5) Law 2: `wd-worker-plateau-floor?` (>=160f flat <target w/ TH/larva & not early-worker-rush)
(define st5 (make-stall-watchdog-state))
(define wp-0   (wd-worker-plateau-floor? st5 28 50 #t #f 3000))
(define wp-159 (wd-worker-plateau-floor? st5 28 50 #t #f 3159))
(define wp-160 (wd-worker-plateau-floor? st5 28 50 #t #f 3160))
(define wp-inc (wd-worker-plateau-floor? st5 29 50 #t #f 3164)) ; +1 worker clears plateau!
(define wp-wr  (wd-worker-plateau-floor? st5 14 50 #t #t 3400)) ; worker rush guard
(define wp-tgt (wd-worker-plateau-floor? st5 50 50 #t #f 3600)) ; at target guard
(check! (and (not wp-0) (not wp-159) wp-160 (not wp-inc) (not wp-wr) (not wp-tgt))
        (format "L49-WD(5) Law 2 worker-plateau mismatch: 0=~a 159=~a 160=~a inc=~a wr=~a tgt=~a"
                wp-0 wp-159 wp-160 wp-inc wp-wr wp-tgt))

;; (6) Law 3a: `wd-preemptive-supply-urgent?`
(check! (and (not (wd-preemptive-supply-urgent? 12 14 0 1 'Zerg))       ; 12/14 Zerg no early OL
             (wd-preemptive-supply-urgent? 13 14 0 1 'Zerg)             ; 13/14 Zerg 13-OL
             (not (wd-preemptive-supply-urgent? 13 15 0 1 'Protoss))    ; 13/15 Protoss 14-Pylon
             (wd-preemptive-supply-urgent? 14 15 0 1 'Protoss)          ; 14/15 Protoss Pylon#1
             (wd-preemptive-supply-urgent? 13 15 0 1 'Terran)           ; 13/15 Terran Depot#1
             (not (wd-preemptive-supply-urgent? 20 23 0 1 'Terran))     ; 20/23 Terran preserves CC#2 before Depot#2
             (wd-preemptive-supply-urgent? 21 23 0 1 'Terran)           ; 21/23 Terran Depot#2
             (wd-preemptive-supply-urgent? 50 58 0 5 'Protoss)          ; 5-Gate midgame Protoss preempts @ 8 left!
             (wd-preemptive-supply-urgent? 88 96 0 4 'Zerg)             ; 4-Hatch Zerg preempts @ 8 left!
             (not (wd-preemptive-supply-urgent? 50 58 1 5 'Protoss))    ; pending > 0 guard
             (not (wd-preemptive-supply-urgent? 194 196 0 8 'Terran)))  ; food-made >= 195 guard
        "L49-WD(6) Law 3a wd-preemptive-supply-urgent? checks failed")

;; (7) Law 3b: `wd-idle-bank-flush?` (>=96f >=500M normal & >=150M early rush)
(define st7 (make-stall-watchdog-state))
(define ib-0   (wd-idle-bank-flush? st7 550 #f #t #f 4000))
(define ib-95  (wd-idle-bank-flush? st7 550 #f #t #f 4095))
(define ib-96  (wd-idle-bank-flush? st7 550 #f #t #f 4096))
(define ib-cap (wd-idle-bank-flush? st7 600 #t #t #f 4100)) ; supply-capped resets!
(define ib-er0 (wd-idle-bank-flush? st7 160 #f #t #t 1200))
(define ib-er96 (wd-idle-bank-flush? st7 160 #f #t #t 1296)) ; early-rush >=150M triggers @ 96f!
(define ib-no-idle (wd-idle-bank-flush? st7 600 #f #f #f 5000))
(check! (and (not ib-0) (not ib-95) ib-96 (not ib-cap) (not ib-er0) ib-er96 (not ib-no-idle))
        (format "L49-WD(7) Law 3b idle-bank mismatch: 0=~a 95=~a 96=~a cap=~a er0=~a er96=~a noidle=~a"
                ib-0 ib-95 ib-96 ib-cap ib-er0 ib-er96 ib-no-idle))

;; (8) Law 4: `wd-update-halted-buildings!` (pair, list, and unit-hash shapes; >=24f unchanged)
(define st8 (make-stall-watchdog-state))
(define h0  (wd-update-halted-buildings! st8 (list (cons 101 0.35) (list 102 0.20) (hash 'id 103 'build-progress 0.50)) 2000))
;; At +20f (<24f): none halted yet; 102 advances progress!
(define h20 (wd-update-halted-buildings! st8 (list (cons 101 0.35) (list 102 0.45) (hash 'id 103 'build-progress 0.50)) 2020))
;; At +24f: 101 and 103 halted, 102 progressing!
(define h24 (wd-update-halted-buildings! st8 (list (cons 101 0.35) (list 102 0.60) (hash 'id 103 'build-progress 0.50)) 2024))
;; At +28f: 101 resumes, 103 finishes (progress=1.0) -> empty!
(define h28 (wd-update-halted-buildings! st8 (list (cons 101 0.40) (hash 'id 103 'build-progress 1.0)) 2028))
(check! (and (null? h0)
             (null? h20)
             (equal? h24 '(101 103))
             (null? h28))
        (format "L49-WD(8) Law 4 halted-buildings mismatch: h0=~s h20=~s h24=~s h28=~s"
                h0 h20 h24 h28))

;; (9) Micro-perf guard: all 8 watchdog calls combined MUST stay < 0.05ms/iter
(define st-perf (make-stall-watchdog-state))
(define t0 (current-inexact-milliseconds))
(for ([i (in-range 5000)])
  (wd-update-goal-progress! st-perf 'gateway #t 1 (+ 100 i))
  (wd-goal-on-cooldown? st-perf 'gateway (+ 100 i))
  (wd-gas-valve-mode 120 500 80 40 2 80 400)
  (wd-zero-income-recovery? st-perf 20 0 (+ 100 i) #f)
  (wd-preemptive-supply-urgent? 50 55 0 4 'Protoss)
  (wd-idle-bank-flush? st-perf 600 #f #t #f (+ 100 i))
  (wd-worker-plateau-floor? st-perf 30 60 #t #f (+ 100 i))
  (wd-update-halted-buildings! st-perf (list (cons 101 0.45)) (+ 100 i)))
(define avg-ms (/ (- (current-inexact-milliseconds) t0) 5000.0))
(check! (< avg-ms 0.05)
        (format "L49-WD(9) Watchdog perf MUST be < 0.05ms/iter, got ~a ms" avg-ms))

;; ============================================================================
;; B. End-to-End `lib/priority-macro-brain.rkt` Integration Tests
;; ============================================================================

;; (10) Law 1 E2E: Affordable building (`robotics-facility`) stuck for 32f -> 64f -> 112f
;;      MUST escalate stage1 -> stage2 -> stage3-release-escrow and put `robotics-facility` on
;;      160f cooldown so downstream units/buildings immediately unlock!
(reset-macro-escrow-tracker!)
(define (make-stalled-robo-ws f)
  (make-macro-world-state
   #:race 'Protoss #:enemy-race 'Terran #:frame f
   #:minerals 220 #:gas 120 #:supply-used 40 #:supply-cap 54 #:supply-left 14 #:pending-supply 0
   #:workers 32 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 6
   #:army-supply 8 #:enemy-threat-supply 0 #:under-attack? #f
   #:ready-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1 'assimilator 2)
   #:total-building-counts (hasheq 'nexus 2 'pylon 5 'gateway 2 'cybernetics-core 1 'assimilator 2)
   #:unit-counts (hasheq 'probe 32 'stalker 4)
   #:open-facility-slots (hasheq 'townhall 2 'gateway 2)))
(define d10-0   (step-priority-macro-brain (make-stalled-robo-ws 5000)))
(define init-sav (macro-brain-decision-saving-for d10-0))
(define first-bldg (findf (lambda (s) (memq s '(robotics-facility twilight-council forge gateway nexus stargate)))
                          (macro-brain-decision-scheduled-ids d10-0)))
(define d10-1   (step-priority-macro-brain (make-stalled-robo-ws 5004)))
(define d10-s1  (step-priority-macro-brain (make-stalled-robo-ws 5036))) ; +32f -> stage1
(define d10-s2  (step-priority-macro-brain (make-stalled-robo-ws 5068))) ; +64f -> stage2
(define d10-s3  (step-priority-macro-brain (make-stalled-robo-ws 5116))) ; +112f -> stage3 + cooldown!
(define d10-cd  (step-priority-macro-brain (make-stalled-robo-ws 5120))) ; BOTH stalled goals excluded on cooldown!
(define d10-exp (step-priority-macro-brain (make-stalled-robo-ws 5280))) ; >= 5116+160 cooldown expired!
(check! (and first-bldg
             (not (eq? init-sav 'none))
             (eq? (hash-ref (macro-brain-decision-watchdog-info d10-s1) 'goal-stage) 'stage1-check-builder)
             (eq? (hash-ref (macro-brain-decision-watchdog-info d10-s2) 'goal-stage) 'stage2-expand-ring)
             (eq? (hash-ref (macro-brain-decision-watchdog-info d10-s3) 'goal-stage) 'stage3-release-escrow)
             (not (memq first-bldg (macro-brain-decision-scheduled-ids d10-cd)))
             (not (eq? (macro-brain-decision-saving-for d10-cd) init-sav))
             (not (null? (macro-brain-decision-scheduled-ids d10-cd)))
             (eq? (hash-ref (macro-brain-decision-watchdog-info d10-exp) 'goal-stage) 'ok))
        (format "L49-WD(10) Law 1 E2E stalled bldg=~a sav=~a s1=~a s2=~a s3=~a cd-sched=~s/sav=~a exp=~a"
                first-bldg init-sav
                (hash-ref (macro-brain-decision-watchdog-info d10-s1) 'goal-stage)
                (hash-ref (macro-brain-decision-watchdog-info d10-s2) 'goal-stage)
                (hash-ref (macro-brain-decision-watchdog-info d10-s3) 'goal-stage)
                (macro-brain-decision-scheduled-ids d10-cd)
                (macro-brain-decision-saving-for d10-cd)
                (hash-ref (macro-brain-decision-watchdog-info d10-exp) 'goal-stage)))

;; (11) Law 2 E2E: Peaceful 2-base Zerg flat at 28 Drones (< target 44) for >=160f w/ larva available
;;      MUST trigger `wd-worker-plateau?` and boost Drone utility >= 590.0!
(reset-macro-escrow-tracker!)
(define (make-plateau-zerg-ws f)
  (make-macro-world-state
   #:race 'Zerg #:enemy-race 'Protoss #:frame f
   #:minerals 90 #:gas 100 #:supply-used 42 #:supply-cap 54 #:supply-left 12 #:pending-supply 0
   #:workers 28 #:active-bases 2 #:mineral-harvesters 25 #:gas-harvesters 3
   #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
   #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
   #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
   #:unit-counts (hasheq 'drone 28 'queen 2 'roach 5 'overlord 5)
   #:open-facility-slots (hasheq 'larva 3 'townhall 2)))
(define d11-0   (step-priority-macro-brain (make-plateau-zerg-ws 6000)))
(define d11-80  (step-priority-macro-brain (make-plateau-zerg-ws 6080)))
(define d11-164 (step-priority-macro-brain (make-plateau-zerg-ws 6164)))
(check! (and (not (hash-ref (macro-brain-decision-watchdog-info d11-0) 'worker-plateau?))
             (hash-ref (macro-brain-decision-watchdog-info d11-164) 'worker-plateau?)
             (not (not (memq 'drone (macro-brain-decision-scheduled-ids d11-164))))
             (>= (cand-u d11-164 'drone) 590.0))
        (format "L49-WD(11) Law 2 E2E worker-plateau MUST trigger @164f & boost Drone>=590: wp0=~a wp164=~a sched=~s u_drone=~a"
                (hash-ref (macro-brain-decision-watchdog-info d11-0) 'worker-plateau?)
                (hash-ref (macro-brain-decision-watchdog-info d11-164) 'worker-plateau?)
                (macro-brain-decision-scheduled-ids d11-164)
                (cand-u d11-164 'drone)))

;; (12) Law 3a E2E: Multi-facility Protoss (6 Gateways @ 100/110, 0 pending) & Zerg (4 Hatches @ 82/90, 0 pending)
;;      MUST preempt Pylon / Overlord BEFORE supply cap!
(reset-macro-escrow-tracker!)
(define d12-p
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9000
    #:minerals 180 #:gas 120 #:supply-used 100 #:supply-cap 110 #:supply-left 10 #:pending-supply 0
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 44 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 10 'gateway 6 'cybernetics-core 1 'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 56 'stalker 16 'zealot 6)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 6 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define d12-z
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 9000
    #:minerals 180 #:gas 120 #:supply-used 82 #:supply-cap 90 #:supply-left 8 #:pending-supply 0
    #:workers 54 #:active-bases 4 #:mineral-harvesters 45 #:gas-harvesters 9
    #:army-supply 28 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 4 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'lair 1 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 4 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'lair 1 'extractor 3)
    #:unit-counts (hasheq 'drone 54 'queen 4 'roach 10 'overlord 8)
    #:open-facility-slots (hasheq 'larva 6 'townhall 4))))
(check! (and (hash-ref (macro-brain-decision-watchdog-info d12-p) 'supply-urgent?)
             (not (not (memq 'pylon (macro-brain-decision-scheduled-ids d12-p))))
             (hash-ref (macro-brain-decision-watchdog-info d12-z) 'supply-urgent?)
             (not (not (memq 'overlord (macro-brain-decision-scheduled-ids d12-z)))))
        (format "L49-WD(12) Law 3a E2E dynamic supply preempt failed: P(urg=~a sched=~s) Z(urg=~a sched=~s)"
                (hash-ref (macro-brain-decision-watchdog-info d12-p) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids d12-p)
                (hash-ref (macro-brain-decision-watchdog-info d12-z) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids d12-z)))

;; (13) Law 3b E2E: Early-rush idle bank (`>= 150M` for `>= 96f` with idle Barracks, not supply-capped)
;;      MUST trigger `wd-idle-bank-flush?` and unblock combat spending (`macro-brain-can-spend?` = #t)!
(reset-macro-escrow-tracker!)
(define (make-early-rush-idle-bank-ws f)
  (make-macro-world-state
   #:race 'Terran #:enemy-race 'Zerg #:frame f
   #:minerals 180 #:gas 0 #:supply-used 18 #:supply-cap 23 #:supply-left 5 #:pending-supply 0
   #:workers 16 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 0
   #:army-supply 2 #:enemy-threat-supply 8 #:under-attack? #t
   #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
   #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
   #:unit-counts (hasheq 'scv 16 'marine 2)
   #:enemy-unit-counts (hasheq 'zergling 8)
   #:open-facility-slots (hasheq 'townhall 1 'barracks 1)))
(define d13-0   (step-priority-macro-brain (make-early-rush-idle-bank-ws 2400)))
(define d13-48  (step-priority-macro-brain (make-early-rush-idle-bank-ws 2448)))
(define d13-100 (step-priority-macro-brain (make-early-rush-idle-bank-ws 2500)))
(check! (and (not (hash-ref (macro-brain-decision-watchdog-info d13-0) 'idle-bank-flush?))
             (hash-ref (macro-brain-decision-watchdog-info d13-100) 'idle-bank-flush?)
             (not (not (memq 'marine (macro-brain-decision-scheduled-ids d13-100))))
             (macro-brain-can-spend? d13-100 'marine 180 0 'combat-unit))
        (format "L49-WD(13) Law 3b E2E early-rush idle-bank flush failed: f0=~a f100=~a sched=~s can-spend=~a"
                (hash-ref (macro-brain-decision-watchdog-info d13-0) 'idle-bank-flush?)
                (hash-ref (macro-brain-decision-watchdog-info d13-100) 'idle-bank-flush?)
                (macro-brain-decision-scheduled-ids d13-100)
                (macro-brain-can-spend? d13-100 'marine 180 0 'combat-unit)))

;; ============================================================================
;; C. Loop 49 Wave 1B (`#1155`/`#1156`/`#1157`): Zerg Root Cause #4 Tests
;; ============================================================================

;; (14) ZvP/ZvT 3rd Hatchery Pro Timing (~3:00-3:30) + Defer 2-Base BaneNest/Evo/Lair:
;;      (14a) Unpressured 2-base ZvP @ 3:12 (f=4300), 28W, 190M/120G -> escrow 3rd Hatch (595), NO BaneNest/Evo/Lair!
;;      (14b) At 310M/120G -> immediately schedule 3rd Hatchery!
(reset-macro-escrow-tracker!)
(define z-rc4-3rd-hatch-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 4300
    #:minerals 190 #:gas 120 #:supply-used 38 #:supply-cap 52 #:supply-left 14 #:pending-supply 0
    #:workers 28 #:active-bases 2 #:mineral-harvesters 25 #:gas-harvesters 3
    #:army-supply 6 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
    #:unit-counts (hasheq 'drone 28 'queen 2 'zergling 4 'roach 2 'overlord 5)
    #:open-facility-slots (hasheq 'townhall 2 'larva 3))))
(reset-macro-escrow-tracker!)
(define z-rc4-3rd-hatch-build
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 4350
    #:minerals 310 #:gas 120 #:supply-used 38 #:supply-cap 52 #:supply-left 14 #:pending-supply 0
    #:workers 28 #:active-bases 2 #:mineral-harvesters 25 #:gas-harvesters 3
    #:army-supply 6 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
    #:unit-counts (hasheq 'drone 28 'queen 2 'zergling 4 'roach 2 'overlord 5)
    #:open-facility-slots (hasheq 'townhall 2 'larva 3))))
(check! (and (eq? (macro-brain-decision-saving-for z-rc4-3rd-hatch-escrow) 'hatchery)
             (>= (cand-u z-rc4-3rd-hatch-escrow 'hatchery) 595.0)
             (not (memq 'baneling-nest (macro-brain-decision-scheduled-ids z-rc4-3rd-hatch-escrow)))
             (not (memq 'evolution-chamber (macro-brain-decision-scheduled-ids z-rc4-3rd-hatch-escrow)))
             (not (memq 'lair (macro-brain-decision-scheduled-ids z-rc4-3rd-hatch-escrow)))
             (not (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-rc4-3rd-hatch-build)))))
        (format "L49-W1B(14) ZvP unpressured 2b @3:12 MUST prioritize 3rd Hatch(595) & defer BaneNest/Evo/Lair: sav=~a u=~a sched190=~s sched310=~s"
                (macro-brain-decision-saving-for z-rc4-3rd-hatch-escrow)
                (cand-u z-rc4-3rd-hatch-escrow 'hatchery)
                (macro-brain-decision-scheduled-ids z-rc4-3rd-hatch-escrow)
                (macro-brain-decision-scheduled-ids z-rc4-3rd-hatch-build)))

;; (15) ZvT 2-base BanelingNest deferral (< 4:30 unpressured) + negative guard (Bio pressure unlocks):
(reset-macro-escrow-tracker!)
(define z-rc4-defer-bn-240
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 3600
    #:minerals 130 #:gas 80 #:supply-used 32 #:supply-cap 44 #:supply-left 12 #:pending-supply 0
    #:workers 24 #:active-bases 2 #:mineral-harvesters 21 #:gas-harvesters 3
    #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:unit-counts (hasheq 'drone 24 'queen 2 'zergling 4 'overlord 4)
    #:open-facility-slots (hasheq 'townhall 2 'larva 3))))
(reset-macro-escrow-tracker!)
(define z-rc4-bio-unlock-bn
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 5400
    #:minerals 240 #:gas 100 #:supply-used 46 #:supply-cap 60 #:supply-left 14 #:pending-supply 0
    #:workers 30 #:active-bases 2 #:mineral-harvesters 24 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:unit-counts (hasheq 'drone 30 'queen 3 'zergling 12 'roach 3 'overlord 6)
    #:enemy-unit-counts (hasheq 'marine 14)
    #:open-facility-slots (hasheq 'townhall 2 'larva 3))))
(check! (and (not (memq 'baneling-nest (macro-brain-decision-scheduled-ids z-rc4-defer-bn-240)))
             (not (eq? (macro-brain-decision-saving-for z-rc4-defer-bn-240) 'baneling-nest))
             (not (not (memq 'baneling-nest (macro-brain-decision-scheduled-ids z-rc4-bio-unlock-bn)))))
        (format "L49-W1B(15) ZvT @2:40 unpressured MUST defer BaneNest, while 14 Marines unlocks BaneNest: unp=~s/sav=~a bio=~s"
                (macro-brain-decision-scheduled-ids z-rc4-defer-bn-240)
                (macro-brain-decision-saving-for z-rc4-defer-bn-240)
                (macro-brain-decision-scheduled-ids z-rc4-bio-unlock-bn)))

;; (16) Queen #3 & Queen #4 on-time scaling (5.0.14 Queen = 175M; no gas<100 stall on Queen#3, Queen#4 on 3 bases @ 4:00!):
(reset-macro-escrow-tracker!)
(define z-rc4-queen3-with-gas
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 3900
    #:minerals 180 #:gas 120 #:supply-used 34 #:supply-cap 44 #:supply-left 10 #:pending-supply 0
    #:workers 24 #:active-bases 2 #:mineral-harvesters 21 #:gas-harvesters 3
    #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 1)
    #:unit-counts (hasheq 'drone 24 'queen 2 'zergling 4 'overlord 4)
    #:open-facility-slots (hasheq 'townhall 2 'larva 2))))
(reset-macro-escrow-tracker!)
(define z-rc4-queen4-3base
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 5400
    #:minerals 185 #:gas 40 #:supply-used 48 #:supply-cap 66 #:supply-left 18 #:pending-supply 0
    #:workers 34 #:active-bases 3 #:mineral-harvesters 31 #:gas-harvesters 3
    #:army-supply 8 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'roach-warren 1 'spore-crawler 2 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'roach-warren 1 'spore-crawler 2 'extractor 1)
    #:unit-counts (hasheq 'drone 34 'queen 3 'zergling 4 'roach 3 'overlord 6)
    #:open-facility-slots (hasheq 'townhall 3 'larva 3))))
(check! (and (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-rc4-queen3-with-gas))))
             (>= (cand-u z-rc4-queen3-with-gas 'queen) 515.0)
             (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-rc4-queen4-3base))))
             (>= (cand-u z-rc4-queen4-3base 'queen) 515.0))
        (format "L49-W1B(16) Queen #3 (w/ 120G) & Queen #4 (3b @4:00) MUST train >=515: q3=~s/u=~a q4=~s/u=~a"
                (macro-brain-decision-scheduled-ids z-rc4-queen3-with-gas)
                (cand-u z-rc4-queen3-with-gas 'queen)
                (macro-brain-decision-scheduled-ids z-rc4-queen4-3base)
                (cand-u z-rc4-queen4-3base 'queen)))

;; (17) Zerg 3+ base Overlord headroom (+12..16 supply) prevents m=7..10 supply blocks!
(reset-macro-escrow-tracker!)
(define z-rc4-3base-ol-12
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 8600
    #:minerals 200 #:gas 100 #:supply-used 66 #:supply-cap 78 #:supply-left 12 #:pending-supply 0
    #:workers 50 #:active-bases 3 #:mineral-harvesters 41 #:gas-harvesters 9
    #:army-supply 16 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'roach-warren 1 'lair 1 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'roach-warren 1 'lair 1 'extractor 3)
    #:unit-counts (hasheq 'drone 50 'queen 4 'roach 8 'overlord 7)
    #:open-facility-slots (hasheq 'townhall 3 'larva 6))))
(reset-macro-escrow-tracker!)
(define z-rc4-4base-ol-14
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 11200
    #:minerals 240 #:gas 150 #:supply-used 114 #:supply-cap 128 #:supply-left 14 #:pending-supply 0
    #:workers 66 #:active-bases 4 #:mineral-harvesters 54 #:gas-harvesters 12
    #:army-supply 48 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 4 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'lair 1 'extractor 4)
    #:total-building-counts (hasheq 'hatchery 4 'spawning-pool 1 'roach-warren 1 'hydralisk-den 1 'lair 1 'extractor 4)
    #:unit-counts (hasheq 'drone 66 'queen 5 'roach 12 'hydralisk 10 'overlord 13)
    #:open-facility-slots (hasheq 'townhall 4 'larva 9))))
(check! (and (hash-ref (macro-brain-decision-watchdog-info z-rc4-3base-ol-12) 'supply-urgent?)
             (not (not (memq 'overlord (macro-brain-decision-scheduled-ids z-rc4-3base-ol-12))))
             (hash-ref (macro-brain-decision-watchdog-info z-rc4-4base-ol-14) 'supply-urgent?)
             (not (not (memq 'overlord (macro-brain-decision-scheduled-ids z-rc4-4base-ol-14))))
             (not (wd-preemptive-supply-urgent? 48 58 0 2 'Zerg)))
        (format "L49-W1B(17) Zerg 3b(+12)/4b(+14..16) OL headroom failed: 3b=(~a ~s) 4b=(~a ~s)"
                (hash-ref (macro-brain-decision-watchdog-info z-rc4-3base-ol-12) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids z-rc4-3base-ol-12)
                (hash-ref (macro-brain-decision-watchdog-info z-rc4-4base-ol-14) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids z-rc4-4base-ol-14)))

;; ============================================================================
;; Loop 49 Wave 2 Addendum (`#1173`/`#1174`): Protoss 3rd-Nexus Oversat Boost (PvZ/PvT)
;; ============================================================================
;; (18) `#05 PvZ` exact repro (6:32, 2 bases, 52 Probes >= 48, Robo+RoboBay ready,
;;      open Robo/GW/TownHall slots): MUST lock `saving-for = 'nexus` (`u >= 900.0`,
;;      `min-floor = 400`) ahead of Colossus/Immortal/Stalker/Probe at 240M, and
;;      MUST schedule `'nexus` FIRST once >= 400M!
(reset-macro-escrow-tracker!)
(define p-pvz-2b-oversat-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 8784
    #:minerals 240 #:gas 220 #:supply-used 90 #:supply-cap 116 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 2 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 38 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'stalker 10 'immortal 3 'colossus 1)
    #:enemy-unit-counts (hasheq 'roach 4 'zergling 8)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvz-2b-oversat-build
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 8960
    #:minerals 420 #:gas 240 #:supply-used 90 #:supply-cap 116 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 2 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 38 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'stalker 10 'immortal 3 'colossus 1)
    #:enemy-unit-counts (hasheq 'roach 4 'zergling 8)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-pvz-2b-oversat-escrow) 'nexus)
             (>= (cand-u p-pvz-2b-oversat-escrow 'nexus) 900.0)
             (>= (macro-brain-decision-reserved-min-floor p-pvz-2b-oversat-escrow) 400)
             (null? (macro-brain-decision-scheduled-ids p-pvz-2b-oversat-escrow))
             (not (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvz-2b-oversat-build))))
             (eq? (car (macro-brain-decision-scheduled-ids p-pvz-2b-oversat-build)) 'nexus))
        (format "L49-W2(18) PvZ 2b >=48w MUST lock 3rd Nexus ahead of Colossus/Immortal/Stalker/Probe: esc=(save=~a u=~a fl=~a sched=~s) bld=~s"
                (macro-brain-decision-saving-for p-pvz-2b-oversat-escrow)
                (cand-u p-pvz-2b-oversat-escrow 'nexus)
                (macro-brain-decision-reserved-min-floor p-pvz-2b-oversat-escrow)
                (macro-brain-decision-scheduled-ids p-pvz-2b-oversat-escrow)
                (macro-brain-decision-scheduled-ids p-pvz-2b-oversat-build)))

;; (19) PvT 2-base oversat (`workers=48`, 1 Colossus out, army >= 20, 210M/180G):
;;      MUST still lock `saving-for = 'nexus` (`u >= 900.0`, `min-floor = 400`) without Probe/Stalker/Colossus#2 drain!
(reset-macro-escrow-tracker!)
(define p-pvt-2b-oversat-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8960
    #:minerals 210 #:gas 180 #:supply-used 82 #:supply-cap 110 #:supply-left 28 #:pending-supply 0
    #:workers 48 #:active-bases 2 #:mineral-harvesters 36 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 48 'stalker 8 'immortal 3 'colossus 1)
    #:enemy-unit-counts (hasheq 'marine 14 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-pvt-2b-oversat-escrow) 'nexus)
             (>= (cand-u p-pvt-2b-oversat-escrow 'nexus) 900.0)
             (>= (macro-brain-decision-reserved-min-floor p-pvt-2b-oversat-escrow) 400)
             (null? (macro-brain-decision-scheduled-ids p-pvt-2b-oversat-escrow)))
        (format "L49-W2(19) PvT 2b >=48w MUST lock 3rd Nexus ahead of Colossus/Immortal/Stalker/Probe: save=~a u=~a fl=~a sched=~s"
                (macro-brain-decision-saving-for p-pvt-2b-oversat-escrow)
                (cand-u p-pvt-2b-oversat-escrow 'nexus)
                (macro-brain-decision-reserved-min-floor p-pvt-2b-oversat-escrow)
                (macro-brain-decision-scheduled-ids p-pvt-2b-oversat-escrow)))

;; (20) Negative Guards:
;;      (a) Under active base attack (`under-attack? = #t`) -> MUST NOT force 3rd Nexus!
;;      (b) Below 48 Probes (`workers = 40`, 0 Colossi, 320M/220G) -> MUST still prioritize Colossus!
(reset-macro-escrow-tracker!)
(define p-pvz-2b-under-attack-guard
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 8784
    #:minerals 320 #:gas 220 #:supply-used 90 #:supply-cap 116 #:supply-left 26 #:pending-supply 0
    #:workers 52 #:active-bases 2 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 38 #:enemy-threat-supply 28 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'stalker 10 'immortal 3 'colossus 1)
    #:enemy-unit-counts (hasheq 'roach 10 'ravager 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvz-2b-below48-colossus-guard
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 7800
    #:minerals 320 #:gas 220 #:supply-used 74 #:supply-cap 102 #:supply-left 28 #:pending-supply 0
    #:workers 40 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 40 'stalker 10 'immortal 3)
    #:enemy-unit-counts (hasheq 'roach 4 'zergling 8)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (not (eq? (macro-brain-decision-saving-for p-pvz-2b-under-attack-guard) 'nexus))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvz-2b-under-attack-guard)))
             (not (not (memq 'colossus (macro-brain-decision-scheduled-ids p-pvz-2b-below48-colossus-guard)))))
        (format "L49-W2(20) Negative guards failed: atk=(save=~a sched=~s) w40=(save=~a sched=~s)"
                (macro-brain-decision-saving-for p-pvz-2b-under-attack-guard)
                (macro-brain-decision-scheduled-ids p-pvz-2b-under-attack-guard)
                (macro-brain-decision-saving-for p-pvz-2b-below48-colossus-guard)
                (macro-brain-decision-scheduled-ids p-pvz-2b-below48-colossus-guard)))

;; ============================================================================
;; Loop 50 Wave 1 (`#1200`/`#1201`): Fixes 1A, 1B, 1C Regression Tests
;; ============================================================================

;; (21) Fix 1A: Expansion walk grace (`command-center`/`nexus`/`hatchery` get 96f/192f/280f
;;      instead of 32f/64f/112f so builders walking 6-12s to Natural/3rd pad never trip cooldown!)
(define st21 (make-stall-watchdog-state))
(define e21-0   (wd-update-goal-progress! st21 'command-center #t 1 3000))
(define e21-80  (wd-update-goal-progress! st21 'command-center #t 1 3080)) ; +80f < 96f -> still 'ok!
(define e21-112 (wd-update-goal-progress! st21 'command-center #t 1 3112)) ; +112f -> stage1 (NOT stage3!)
(define e21-192 (wd-update-goal-progress! st21 'command-center #t 1 3192)) ; +192f -> stage2 (NOT stage3!)
(define e21-240 (wd-update-goal-progress! st21 'command-center #t 1 3240)) ; +240f -> still stage2!
(define e21-cd-240 (wd-goal-on-cooldown? st21 'command-center 3240))
(define e21-280 (wd-update-goal-progress! st21 'command-center #t 1 3280)) ; +280f -> stage3 + cooldown!
(define e21-cd-280 (wd-goal-on-cooldown? st21 'command-center 3280))
;; Verify nexus & hatchery also get 280f walk grace:
(define _n21-0  (wd-update-goal-progress! st21 'nexus #t 1 3000))
(define n21-112 (wd-update-goal-progress! st21 'nexus #t 1 3080))
(define n21-160 (wd-update-goal-progress! st21 'nexus #t 1 3160))
(define _h21-0  (wd-update-goal-progress! st21 'hatchery #t 1 3000))
(define h21-112 (wd-update-goal-progress! st21 'hatchery #t 1 3080))
(define h21-160 (wd-update-goal-progress! st21 'hatchery #t 1 3160))
(check! (and (eq? e21-0 'ok)
             (eq? e21-80 'ok)
             (eq? e21-112 'stage1-check-builder)
             (eq? e21-192 'stage2-expand-ring)
             (eq? e21-240 'stage2-expand-ring)
             (not e21-cd-240)
             (eq? e21-280 'stage3-release-escrow)
             e21-cd-280
             (eq? n21-112 'ok)
             (eq? n21-160 'stage1-check-builder)
             (not (wd-goal-on-cooldown? st21 'nexus 3160))
             (eq? h21-112 'ok)
             (eq? h21-160 'stage1-check-builder)
             (not (wd-goal-on-cooldown? st21 'hatchery 3160)))
        (format "L50-W1(21) Expansion 280f walk grace failed: cc=(~a ~a ~a ~a ~a cd240=~a ~a cd280=~a) nex=(~a ~a) hat=(~a ~a)"
                e21-0 e21-80 e21-112 e21-192 e21-240 e21-cd-240 e21-280 e21-cd-280
                n21-112 n21-160 h21-112 h21-160))

;; (22) Fix 1A: Idle-bank-flush MUST NOT break `400M` Natural/3rd expansion escrow (`#23 TvP` fix!)
(reset-macro-escrow-tracker!)
(define (make-terran-nat-escrow-ws f)
  (make-macro-world-state
   #:race 'Terran #:enemy-race 'Protoss #:frame f
   #:minerals 280 #:gas 40 #:supply-used 19 #:supply-cap 23 #:supply-left 4 #:pending-supply 0
   #:workers 18 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 3
   #:army-supply 1 #:enemy-threat-supply 1 #:under-attack? #f
   #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1 'refinery 1)
   #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1 'refinery 1)
   #:unit-counts (hasheq 'scv 18 'marine 1)
   #:enemy-unit-counts (hasheq 'probe 1)
   #:open-facility-slots (hasheq 'townhall 1 'barracks 1)))
(define _d22-0 (step-priority-macro-brain (make-terran-nat-escrow-ws 2600)))
(define _d22-1 (step-priority-macro-brain (make-terran-nat-escrow-ws 2660)))
(define d22-2  (step-priority-macro-brain (make-terran-nat-escrow-ws 2710))) ; +110f >= 96f idle-bank-flush active!
(check! (and (eq? (macro-brain-decision-saving-for d22-2) 'command-center)
             (>= (macro-brain-decision-reserved-min-floor d22-2) 400)
             (hash-ref (macro-brain-decision-watchdog-info d22-2) 'idle-bank-flush?)
             (not (macro-brain-can-spend? d22-2 'marine 280 0 'combat-unit))
             (not (macro-brain-can-spend? d22-2 'scv 280 0 'worker)))
        (format "L50-W1(22) Idle-bank-flush MUST NOT break 400M CC escrow: save=~a fl=~a flush?=~a sched=~s can-mar=~a can-scv=~a"
                (macro-brain-decision-saving-for d22-2)
                (macro-brain-decision-reserved-min-floor d22-2)
                (hash-ref (macro-brain-decision-watchdog-info d22-2) 'idle-bank-flush?)
                (macro-brain-decision-scheduled-ids d22-2)
                (macro-brain-can-spend? d22-2 'marine 280 0 'combat-unit)
                (macro-brain-can-spend? d22-2 'scv 280 0 'worker)))

;; (23) Fix 1B: Conservative early supply headroom (`<28 -> 2`, `<38 -> 3`, `<3 prod -> 4`;
;;      Protoss `19..23` on `food-made == 23` w/ Gateway ready -> `4`) so premature Pylons/Depots
;;      at 18/23 & 26/31..35/39..36/43 never starve early units or Natural CC!
(reset-macro-escrow-tracker!)
(define p-early-unit-no-premature-pylon
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 2500
    #:minerals 160 #:gas 60 #:supply-used 18 #:supply-cap 23 #:supply-left 5 #:pending-supply 0
    #:workers 16 #:active-bases 1 #:mineral-harvesters 10 #:gas-harvesters 6
    #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 16 'stalker 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(reset-macro-escrow-tracker!)
(define t-20-23-no-premature-depot
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 2650
    #:minerals 300 #:gas 40 #:supply-used 20 #:supply-cap 23 #:supply-left 3 #:pending-supply 0
    #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
    #:army-supply 1 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1 'refinery 1)
    #:total-building-counts (hasheq 'command-center 1 'supply-depot 1 'barracks 1 'refinery 1)
    #:unit-counts (hasheq 'scv 19 'marine 1)
    #:open-facility-slots (hasheq 'townhall 1 'barracks 1))))
(check! (and (= (wd-dynamic-supply-headroom 18 2 'Protoss 23) 1)
             (= (wd-dynamic-supply-headroom 19 1 'Protoss 23) 4)
             (= (wd-dynamic-supply-headroom 19 0 'Protoss 23) 3)
             (= (wd-dynamic-supply-headroom 20 2 'Protoss 23) 4)
             (= (wd-dynamic-supply-headroom 26 2 'Protoss 31) 3)
             (= (wd-dynamic-supply-headroom 27 2 'Terran 31) 2)
             (= (wd-dynamic-supply-headroom 33 2 'Protoss 39) 3)
             (= (wd-dynamic-supply-headroom 36 3 'Protoss 43) 3)
             (= (wd-dynamic-supply-headroom 37 3 'Terran 41) 3)
             (= (wd-dynamic-supply-headroom 42 2 'Protoss 46) 4)
             (not (wd-preemptive-supply-urgent? 19 23 0 0 'Protoss))
             (wd-preemptive-supply-urgent? 19 23 0 1 'Protoss)
             (wd-preemptive-supply-urgent? 20 23 0 2 'Protoss)
             (not (wd-preemptive-supply-urgent? 20 23 0 2 'Terran))
             (not (wd-preemptive-supply-urgent? 26 31 0 2 'Protoss))
             (not (wd-preemptive-supply-urgent? 35 39 0 2 'Protoss))
             (not (wd-preemptive-supply-urgent? 36 43 0 3 'Protoss))
             (wd-preemptive-supply-urgent? 36 39 0 2 'Protoss)
             (not (hash-ref (macro-brain-decision-watchdog-info p-early-unit-no-premature-pylon) 'supply-urgent?))
             (not (memq 'pylon (macro-brain-decision-scheduled-ids p-early-unit-no-premature-pylon)))
             (or (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-early-unit-no-premature-pylon))))
                 (not (not (memq 'adept (macro-brain-decision-scheduled-ids p-early-unit-no-premature-pylon)))))
             (not (hash-ref (macro-brain-decision-watchdog-info t-20-23-no-premature-depot) 'supply-urgent?))
             (eq? (macro-brain-decision-saving-for t-20-23-no-premature-depot) 'command-center))
        (format "L50-W1(23) Early supply headroom (<38) regression: h19p1=~a h19p0=~a h26p=~a h27t=~a h33=~a h36_3p=~a h42_2p=~a p-wd=~a p-sched=~s t-wd=~a t-sav=~a"
                (wd-dynamic-supply-headroom 19 1 'Protoss 23)
                (wd-dynamic-supply-headroom 19 0 'Protoss 23)
                (wd-dynamic-supply-headroom 26 2 'Protoss 31)
                (wd-dynamic-supply-headroom 27 2 'Terran 31)
                (wd-dynamic-supply-headroom 33 2 'Protoss 39)
                (wd-dynamic-supply-headroom 36 3 'Protoss 43)
                (wd-dynamic-supply-headroom 42 2 'Protoss 46)
                (hash-ref (macro-brain-decision-watchdog-info p-early-unit-no-premature-pylon) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids p-early-unit-no-premature-pylon)
                (hash-ref (macro-brain-decision-watchdog-info t-20-23-no-premature-depot) 'supply-urgent?)
                (macro-brain-decision-saving-for t-20-23-no-premature-depot)))

;; (24) Fix 1C: `PvP` 2-base `>= 48` Probes (`#12 PvP` 73 Probes on 2 bases!) locks 3rd Nexus
;;      ahead of Immortal cadence (`immortal=2 < 4`) while `< 48` Probes & anti-Tempest guards remain intact!
(reset-macro-escrow-tracker!)
(define p-pvp-2b-oversat-escrow
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 8960
    #:minerals 240 #:gas 180 #:supply-used 86 #:supply-cap 116 #:supply-left 30 #:pending-supply 0
    #:workers 50 #:active-bases 2 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 36 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 50 'stalker 10 'immortal 2)
    #:enemy-unit-counts (hasheq 'stalker 10 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvp-2b-oversat-build
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 9120
    #:minerals 420 #:gas 200 #:supply-used 86 #:supply-cap 116 #:supply-left 30 #:pending-supply 0
    #:workers 50 #:active-bases 2 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 36 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 50 'stalker 10 'immortal 2)
    #:enemy-unit-counts (hasheq 'stalker 10 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvp-2b-below48-immortal-guard
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 7600
    #:minerals 290 #:gas 150 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 40 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 40 'stalker 10 'immortal 2)
    #:enemy-unit-counts (hasheq 'stalker 10 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvp-2b-tempest-guard
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 9600
    #:minerals 260 #:gas 200 #:supply-used 86 #:supply-cap 116 #:supply-left 30 #:pending-supply 0
    #:workers 52 #:active-bases 2 #:mineral-harvesters 40 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 16 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 12 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 52 'stalker 12 'immortal 2)
    #:enemy-unit-counts (hasheq 'tempest 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-pvp-2b-oversat-escrow) 'nexus)
             (>= (cand-u p-pvp-2b-oversat-escrow 'nexus) 900.0)
             (>= (macro-brain-decision-reserved-min-floor p-pvp-2b-oversat-escrow) 400)
             (null? (macro-brain-decision-scheduled-ids p-pvp-2b-oversat-escrow))
             (not (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvp-2b-oversat-build))))
             (eq? (car (macro-brain-decision-scheduled-ids p-pvp-2b-oversat-build)) 'nexus)
             (not (not (memq 'immortal (macro-brain-decision-scheduled-ids p-pvp-2b-below48-immortal-guard))))
             (not (eq? (macro-brain-decision-saving-for p-pvp-2b-tempest-guard) 'nexus)))
        (format "L50-W1(24) PvP 2b >=48w 3rd Nexus / guards failed: esc=(save=~a u=~a fl=~a sched=~s) bld=~s w40=~s tmp=(save=~a sched=~s)"
                (macro-brain-decision-saving-for p-pvp-2b-oversat-escrow)
                (cand-u p-pvp-2b-oversat-escrow 'nexus)
                (macro-brain-decision-reserved-min-floor p-pvp-2b-oversat-escrow)
                (macro-brain-decision-scheduled-ids p-pvp-2b-oversat-escrow)
                (macro-brain-decision-scheduled-ids p-pvp-2b-oversat-build)
                (macro-brain-decision-scheduled-ids p-pvp-2b-below48-immortal-guard)
                (macro-brain-decision-saving-for p-pvp-2b-tempest-guard)
                (macro-brain-decision-scheduled-ids p-pvp-2b-tempest-guard)))

;; ============================================================================
;; Loop 50 Wave 2 (`#1212`/`#1213`): W2-1 (`#05 PvZ` 20/23 Pylon #2) & W2-2 (`#04 PvT` Colossus #1)
;; ============================================================================

;; (25) W2-1: Protoss `20/23` (`#05 PvZ` m=1:43) triggers `wd-supply-urgent? = #t` and schedules
;;      Pylon #2 on time (`0s` 22/23 block!), while Terran `20/23` remains `#f` (2-0 Terran intact)!
(reset-macro-escrow-tracker!)
(define p-pvz-20-23-pylon2
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 2310
    #:minerals 120 #:gas 40 #:supply-used 20 #:supply-cap 23 #:supply-left 3 #:pending-supply 0
    #:workers 20 #:active-bases 1 #:mineral-harvesters 17 #:gas-harvesters 3
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'cybernetics-core 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 20)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(check! (and (hash-ref (macro-brain-decision-watchdog-info p-pvz-20-23-pylon2) 'supply-urgent?)
             (not (not (memq 'pylon (macro-brain-decision-scheduled-ids p-pvz-20-23-pylon2))))
             (not (wd-preemptive-supply-urgent? 20 23 0 1 'Terran))
             (not (wd-preemptive-supply-urgent? 27 31 0 2 'Protoss)))
        (format "L50-W2(25) PvZ 20/23 Pylon #2 restore failed: wd-sup?=~a sched=~s"
                (hash-ref (macro-brain-decision-watchdog-info p-pvz-20-23-pylon2) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids p-pvz-20-23-pylon2)))

;; (26) W2-2 (`#04 PvT` Colossus #1 & 3rd Nexus guards):
;;      (a) Naked 3rd Nexus guard: `army-supply = 13 < 20` on 2b/54w MUST NOT force `saving-for = 'nexus`!
;;      (b) Colossus #1 yield: ready RoboticsBay + `colossus == 0` + `gas >= 120` MUST prioritize `'colossus` over 3rd Nexus!
;;      (c) Low-gas (`gas = 45`, `40..59G`) Colossus #1 guard defers `gravitic-booster` & 2nd `robotics-facility`!
(reset-macro-escrow-tracker!)
(define p-pvt-naked-3rd-guard
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8400
    #:minerals 240 #:gas 100 #:supply-used 67 #:supply-cap 102 #:supply-left 35 #:pending-supply 0
    #:workers 54 #:active-bases 2 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 13 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 54 'stalker 4 'immortal 1 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 14 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvt-colossus1-yields-3rd
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 260 #:gas 160 #:supply-used 82 #:supply-cap 110 #:supply-left 28 #:pending-supply 0
    #:workers 54 #:active-bases 2 #:mineral-harvesters 42 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 54 'stalker 8 'immortal 3 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 14 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-pvt-colossus1-gas45-defer
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9000
    #:minerals 340 #:gas 45 #:supply-used 90 #:supply-cap 118 #:supply-left 28 #:pending-supply 0
    #:workers 56 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 34 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 5 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 56 'stalker 10 'immortal 3 'observer 1)
    #:enemy-unit-counts (hasheq 'marine 16 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 5 'robotics-facility 1))))
(check! (and (not (eq? (macro-brain-decision-saving-for p-pvt-naked-3rd-guard) 'nexus))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvt-naked-3rd-guard)))
             (eq? (macro-brain-decision-saving-for p-pvt-colossus1-yields-3rd) 'colossus)
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvt-colossus1-yields-3rd)))
             (eq? (macro-brain-decision-saving-for p-pvt-colossus1-gas45-defer) 'colossus)
             (not (memq 'gravitic-booster (macro-brain-decision-scheduled-ids p-pvt-colossus1-gas45-defer)))
             (not (memq 'robotics-facility (macro-brain-decision-scheduled-ids p-pvt-colossus1-gas45-defer)))
             (<= (cand-u p-pvt-colossus1-gas45-defer 'robotics-facility) 420.0))
        (format "L50-W2(26) #04 PvT Colossus#1/3rdNexus guards failed: naked=(sav=~a sch=~s) col1=(sav=~a sch=~s) g45=(sav=~a sch=~s robo2_u=~a)"
                (macro-brain-decision-saving-for p-pvt-naked-3rd-guard)
                (macro-brain-decision-scheduled-ids p-pvt-naked-3rd-guard)
                (macro-brain-decision-saving-for p-pvt-colossus1-yields-3rd)
                (macro-brain-decision-scheduled-ids p-pvt-colossus1-yields-3rd)
                (macro-brain-decision-saving-for p-pvt-colossus1-gas45-defer)
                (macro-brain-decision-scheduled-ids p-pvt-colossus1-gas45-defer)
                (cand-u p-pvt-colossus1-gas45-defer 'robotics-facility)))

;; ============================================================================
;; Loop 51 Wave 1 (`#1235`/`#1240`): L51-1A, L51-1B, L51-1C, L51-1D Tests
;; ============================================================================

;; (27) L51-1A (`CyberCore Done -> 1st Stalker` Dead Zone):
;;      With CyberCore ready, workers=22 (<26), frame=3200 (<4032), gas=120:
;;      (a) At 135M -> MUST boost & schedule `stalker` (`u >= 525.0 > zealot@494.0`), NOT `zealot`!
;;      (b) At 105M -> MUST hold `saving-for = 'stalker` so `100M` Zealot cannot steal minerals!
(reset-macro-escrow-tracker!)
(define p-cyber-1st-stalker-train
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 3200
    #:minerals 135 #:gas 120 #:supply-used 22 #:supply-cap 31 #:supply-left 9 #:pending-supply 0
    #:workers 22 #:active-bases 2 #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22)
    #:pending-upgrades '(warp-gate-research)
    #:open-facility-slots (hasheq 'townhall 0 'gateway 1))))
(reset-macro-escrow-tracker!)
(define p-cyber-1st-stalker-hold
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 3200
    #:minerals 105 #:gas 130 #:supply-used 22 #:supply-cap 31 #:supply-left 9 #:pending-supply 0
    #:workers 22 #:active-bases 2 #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 2 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 2 'gateway 2 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22)
    #:pending-upgrades '(warp-gate-research)
    #:open-facility-slots (hasheq 'townhall 0 'gateway 2))))
(check! (and (>= (cand-u p-cyber-1st-stalker-train 'stalker) 525.0)
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-cyber-1st-stalker-train))))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-cyber-1st-stalker-train)))
             (eq? (macro-brain-decision-saving-for p-cyber-1st-stalker-hold) 'stalker)
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-cyber-1st-stalker-hold))))
        (format "L51-W1(27) CyberCore->1st Stalker dead-zone failed: tr=(u=~a sch=~s) hd=(sav=~a sch=~s)"
                (cand-u p-cyber-1st-stalker-train 'stalker)
                (macro-brain-decision-scheduled-ids p-cyber-1st-stalker-train)
                (macro-brain-decision-saving-for p-cyber-1st-stalker-hold)
                (macro-brain-decision-scheduled-ids p-cyber-1st-stalker-hold)))

;; (28) L51-1B (`H2H #05 PvZ` `19/23` Pylon #2 with Gateway ready, NOT when Gateway incomplete):
(reset-macro-escrow-tracker!)
(define p-pvz-19-23-gw-ready
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 2150
    #:minerals 110 #:gas 30 #:supply-used 19 #:supply-cap 23 #:supply-left 4 #:pending-supply 0
    #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'cybernetics-core 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 19)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(reset-macro-escrow-tracker!)
(define p-pvz-19-23-gw-building
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 1800
    #:minerals 110 #:gas 30 #:supply-used 19 #:supply-cap 23 #:supply-left 4 #:pending-supply 0
    #:workers 19 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 3
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 19)
    #:open-facility-slots (hasheq 'townhall 1))))
(check! (and (hash-ref (macro-brain-decision-watchdog-info p-pvz-19-23-gw-ready) 'supply-urgent?)
             (not (not (memq 'pylon (macro-brain-decision-scheduled-ids p-pvz-19-23-gw-ready))))
             (not (hash-ref (macro-brain-decision-watchdog-info p-pvz-19-23-gw-building) 'supply-urgent?)))
        (format "L51-W1(28) H2H#05 19/23 Pylon#2 failed: ready=(~a ~s) bldg=(~a ~s)"
                (hash-ref (macro-brain-decision-watchdog-info p-pvz-19-23-gw-ready) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids p-pvz-19-23-gw-ready)
                (hash-ref (macro-brain-decision-watchdog-info p-pvz-19-23-gw-building) 'supply-urgent?)
                (macro-brain-decision-scheduled-ids p-pvz-19-23-gw-building)))

;; (29) L51-1C (`#12` 3rd Nexus w/ Phoenix+Oracle disabling Colossus & `#18` Robo Immortal vs SiegeTanks+Vikings):
(reset-macro-escrow-tracker!)
(define p-12-pvp-phoenix-3rd-nexus
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 9900
    #:minerals 220 #:gas 160 #:supply-used 78 #:supply-cap 102 #:supply-left 24 #:pending-supply 0
    #:workers 50 #:active-bases 2 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 50 'stalker 11 'immortal 1 'observer 1)
    #:enemy-unit-counts (hasheq 'phoenix 6 'oracle 2 'stalker 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(reset-macro-escrow-tracker!)
(define p-18-pvt-tanks-vikings-immortal
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 9200
    #:minerals 330 #:gas 150 #:supply-used 76 #:supply-cap 102 #:supply-left 26 #:pending-supply 0
    #:workers 46 #:active-bases 2 #:mineral-harvesters 34 #:gas-harvesters 12
    #:army-supply 30 #:enemy-threat-supply 16 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 5 'cybernetics-core 1 'forge 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 11 'gateway 5 'cybernetics-core 1 'forge 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 46 'stalker 12 'zealot 4 'colossus 1 'observer 1)
    #:enemy-unit-counts (hasheq 'siege-tank-sieged 4 'viking-fighter 10 'marine 14)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-12-pvp-phoenix-3rd-nexus) 'nexus)
             (>= (cand-u p-12-pvp-phoenix-3rd-nexus 'nexus) 900.0)
             (not (not (memq 'immortal (macro-brain-decision-scheduled-ids p-18-pvt-tanks-vikings-immortal))))
             (>= (cand-u p-18-pvt-tanks-vikings-immortal 'immortal) 560.0))
        (format "L51-W1(29) #12 3rdNexus / #18 Tank+Viking Immortal failed: p12=(sav=~a u=~a) p18=(sch=~s imm_u=~a)"
                (macro-brain-decision-saving-for p-12-pvp-phoenix-3rd-nexus)
                (cand-u p-12-pvp-phoenix-3rd-nexus 'nexus)
                (macro-brain-decision-scheduled-ids p-18-pvt-tanks-vikings-immortal)
                (cand-u p-18-pvt-tanks-vikings-immortal 'immortal)))

;; (30) L51-1D (`#61` 66-Drone cap & ZvT RW drop + `H2H #01 ZvZ` Early HydraDen & InfestationPit defer):
(reset-macro-escrow-tracker!)
(define z-61-drone-cap-66-low-army
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 10000
    #:minerals 200 #:gas 100 #:supply-used 90 #:supply-cap 120 #:supply-left 30 #:pending-supply 0
    #:workers 66 #:active-bases 4 #:mineral-harvesters 54 #:gas-harvesters 12
    #:army-supply 24 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 4 'lair 1 'spawning-pool 1 'baneling-nest 1 'hydralisk-den 1 'extractor 4)
    #:total-building-counts (hasheq 'hatchery 4 'lair 1 'spawning-pool 1 'baneling-nest 1 'hydralisk-den 1 'extractor 4)
    #:unit-counts (hasheq 'drone 66 'queen 4 'zergling 12 'hydralisk 4)
    #:enemy-unit-counts (hasheq 'marine 20 'siege-tank 4)
    #:open-facility-slots (hasheq 'townhall 4 'larva 6))))
(reset-macro-escrow-tracker!)
(define z-01-zvz-early-hydraden
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Zerg #:frame 7400
    #:minerals 160 #:gas 110 #:supply-used 72 #:supply-cap 96 #:supply-left 24 #:pending-supply 0
    #:workers 42 #:active-bases 3 #:mineral-harvesters 33 #:gas-harvesters 9
    #:army-supply 30 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'baneling-nest 1 'evolution-chamber 1 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'baneling-nest 1 'evolution-chamber 1 'extractor 3)
    #:unit-counts (hasheq 'drone 42 'queen 4 'roach 10 'zergling 12)
    #:enemy-unit-counts (hasheq 'roach 10 'zergling 16)
    #:open-facility-slots (hasheq 'townhall 3 'larva 5))))
(reset-macro-escrow-tracker!)
(define z-01-zvz-hydraden-escrow-hold
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Zerg #:frame 7400
    #:minerals 130 #:gas 75 #:supply-used 72 #:supply-cap 96 #:supply-left 24 #:pending-supply 0
    #:workers 42 #:active-bases 3 #:mineral-harvesters 33 #:gas-harvesters 9
    #:army-supply 30 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'baneling-nest 1 'evolution-chamber 1 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'baneling-nest 1 'evolution-chamber 1 'extractor 3)
    #:unit-counts (hasheq 'drone 42 'queen 4 'roach 10 'zergling 12)
    #:enemy-unit-counts (hasheq 'roach 10 'zergling 16)
    #:open-facility-slots (hasheq 'townhall 3 'larva 5))))
(reset-macro-escrow-tracker!)
(define z-01-zvz-defer-infest-pit
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Zerg #:frame 9600
    #:minerals 260 #:gas 160 #:supply-used 98 #:supply-cap 124 #:supply-left 26 #:pending-supply 0
    #:workers 56 #:active-bases 4 #:mineral-harvesters 44 #:gas-harvesters 12
    #:army-supply 42 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 4 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'baneling-nest 1 'hydralisk-den 1 'extractor 5)
    #:total-building-counts (hasheq 'hatchery 4 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'baneling-nest 1 'hydralisk-den 1 'extractor 5)
    #:unit-counts (hasheq 'drone 56 'queen 5 'roach 12 'hydralisk 3 'zergling 12)
    #:enemy-unit-counts (hasheq 'roach 14 'hydralisk 10 'zergling 20)
    #:open-facility-slots (hasheq 'townhall 4 'larva 6))))
(check! (and (not (memq 'drone (macro-brain-decision-scheduled-ids z-61-drone-cap-66-low-army)))
             (not (eq? (macro-brain-decision-saving-for z-61-drone-cap-66-low-army) 'roach-warren))
             (not (memq 'roach-warren (macro-brain-decision-scheduled-ids z-61-drone-cap-66-low-army)))
             (not (not (memq 'hydralisk-den (macro-brain-decision-scheduled-ids z-01-zvz-early-hydraden))))
             (>= (cand-u z-01-zvz-early-hydraden 'hydralisk-den) 560.0)
             (eq? (macro-brain-decision-saving-for z-01-zvz-hydraden-escrow-hold) 'hydralisk-den)
             (not (memq 'roach (macro-brain-decision-scheduled-ids z-01-zvz-hydraden-escrow-hold)))
             (not (memq 'infestation-pit (macro-brain-decision-scheduled-ids z-01-zvz-defer-infest-pit)))
             (not (eq? (macro-brain-decision-saving-for z-01-zvz-defer-infest-pit) 'infestation-pit)))
        (format "L51-W1(30) Zerg 66w/ZvT-RW/ZvZ-HydraDen/InfestPit failed: z61=(sav=~a sch=~s) hd=(u=~a sch=~s) hdesc=(sav=~a sch=~s) ip=(sav=~a sch=~s)"
                (macro-brain-decision-saving-for z-61-drone-cap-66-low-army)
                (macro-brain-decision-scheduled-ids z-61-drone-cap-66-low-army)
                (cand-u z-01-zvz-early-hydraden 'hydralisk-den)
                (macro-brain-decision-scheduled-ids z-01-zvz-early-hydraden)
                (macro-brain-decision-saving-for z-01-zvz-hydraden-escrow-hold)
                (macro-brain-decision-scheduled-ids z-01-zvz-hydraden-escrow-hold)
                (macro-brain-decision-saving-for z-01-zvz-defer-infest-pit)
                (macro-brain-decision-scheduled-ids z-01-zvz-defer-infest-pit)))

;; (31) L56-K9 (`L52-1B` `#54 zig-reapers` Anti-Reaper Macro: defer Zealot & Robo until Stalker >= 4):
(reset-macro-escrow-tracker!)
(define p-l52-reaper-busy-gw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 4100
    #:minerals 160 #:gas 140 #:supply-used 25 #:supply-cap 39 #:supply-left 14 #:pending-supply 0
    #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
    #:army-supply 2 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 21 'stalker 1)
    #:enemy-unit-counts (hasheq 'reaper 4)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 0))))
(reset-macro-escrow-tracker!)
(define p-l52-reaper-open-gw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 3900
    #:minerals 130 #:gas 60 #:supply-used 25 #:supply-cap 39 #:supply-left 14 #:pending-supply 0
    #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
    #:army-supply 2 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 21 'stalker 1)
    #:enemy-unit-counts (hasheq 'reaper 4)
    #:open-facility-slots (hasheq 'townhall 0 'gateway 1))))
(check! (and (not (memq 'robotics-facility (macro-brain-decision-scheduled-ids p-l52-reaper-busy-gw)))
             (not (eq? (macro-brain-decision-saving-for p-l52-reaper-busy-gw) 'robotics-facility))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-l52-reaper-busy-gw)))
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-l52-reaper-open-gw))))
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-l52-reaper-open-gw)))
             (not (memq 'robotics-facility (macro-brain-decision-scheduled-ids p-l52-reaper-open-gw))))
        (format "L56-K9(31) Anti-Reaper macro failed: busy=(sav=~a sch=~s) open=(sav=~a sch=~s)"
                (macro-brain-decision-saving-for p-l52-reaper-busy-gw)
                (macro-brain-decision-scheduled-ids p-l52-reaper-busy-gw)
                (macro-brain-decision-saving-for p-l52-reaper-open-gw)
                (macro-brain-decision-scheduled-ids p-l52-reaper-open-gw)))

;; (32) L56-K10 (`L52-1C` w/o Bunker cap: TvT FactoryTechLab immediately ahead of WidowMine,
;;      block WidowMine/Hellion while SiegeTank < 4):
(reset-macro-escrow-tracker!)
(define t-l52-tvt-factl-before-wm
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 3920
    #:minerals 100 #:gas 60 #:supply-used 24 #:supply-cap 46 #:supply-left 22 #:pending-supply 0
    #:workers 21 #:active-bases 2 #:mineral-harvesters 15 #:gas-harvesters 6
    #:army-supply 2 #:enemy-threat-supply 3 #:under-attack? #t
    #:ready-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 3 'barracks 1 'factory 1 'refinery 2)
    #:total-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 3 'barracks 1 'factory 1 'refinery 2)
    #:unit-counts (hasheq 'scv 21 'marine 2)
    #:enemy-unit-counts (hasheq 'marine 2 'reaper 1)
    #:open-facility-slots (hasheq 'townhall 0 'barracks 0 'factory 1))))
(reset-macro-escrow-tracker!)
(define t-l52-tvt-no-hellion-under4tanks
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 6200
    #:minerals 140 #:gas 80 #:supply-used 52 #:supply-cap 70 #:supply-left 18 #:pending-supply 0
    #:workers 34 #:active-bases 2 #:mineral-harvesters 25 #:gas-harvesters 9
    #:army-supply 18 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 6 'barracks 2
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 3)
    #:total-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 6 'barracks 2
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 3)
    #:unit-counts (hasheq 'scv 34 'marine 12 'siege-tank 2)
    #:enemy-unit-counts (hasheq 'marine 8 'siege-tank 2)
    #:open-facility-slots (hasheq 'townhall 0 'barracks 0 'factory 1 'starport 0))))
(check! (and (not (not (memq 'factory-techlab (macro-brain-decision-scheduled-ids t-l52-tvt-factl-before-wm))))
             (not (memq 'widow-mine (macro-brain-decision-scheduled-ids t-l52-tvt-factl-before-wm)))
             (not (memq 'hellion (macro-brain-decision-scheduled-ids t-l52-tvt-factl-before-wm)))
             (not (memq 'hellion (macro-brain-decision-scheduled-ids t-l52-tvt-no-hellion-under4tanks)))
             (not (memq 'widow-mine (macro-brain-decision-scheduled-ids t-l52-tvt-no-hellion-under4tanks))))
        (format "L56-K10(32) TvT FactTL/WM/Hellion failed: factl=(~s) nohel=(~s)"
                (macro-brain-decision-scheduled-ids t-l52-tvt-factl-before-wm)
                (macro-brain-decision-scheduled-ids t-l52-tvt-no-hellion-under4tanks)))

;; (33) L56-K10 (`L52-P1` `interference-matrix` research 807 at StarportTechLab once Raven >= 1):
(reset-macro-escrow-tracker!)
(define t-l52-im-research-due
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 7500
    #:minerals 140 #:gas 110 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 14 'marauder 4 'siege-tank 2 'raven 1)
    #:enemy-unit-counts (hasheq 'stalker 10 'immortal 2 'colossus 1)
    #:researched-upgrades '(stimpack)
    #:open-facility-slots (hasheq 'townhall 0 'barracks 0 'factory 0 'starport 0 'starport-techlab 1))))
(reset-macro-escrow-tracker!)
(define t-l52-im-research-done
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 7500
    #:minerals 140 #:gas 110 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 3 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'starport-techlab 1 'refinery 4)
    #:unit-counts (hasheq 'scv 42 'marine 14 'marauder 4 'siege-tank 2 'raven 1)
    #:enemy-unit-counts (hasheq 'stalker 10 'immortal 2 'colossus 1)
    #:researched-upgrades '(stimpack interference-matrix)
    #:open-facility-slots (hasheq 'townhall 0 'barracks 0 'factory 0 'starport 0 'starport-techlab 1))))
(check! (and (not (not (memq 'interference-matrix (macro-brain-decision-scheduled-ids t-l52-im-research-due))))
             (>= (cand-u t-l52-im-research-due 'interference-matrix) 585.0)
             (not (memq 'interference-matrix (macro-brain-decision-scheduled-ids t-l52-im-research-done))))
        (format "L56-K10(33) InterferenceMatrix research failed: due=(u=~a sch=~s) done=(sch=~s)"
                (cand-u t-l52-im-research-due 'interference-matrix)
                (macro-brain-decision-scheduled-ids t-l52-im-research-due)
                (macro-brain-decision-scheduled-ids t-l52-im-research-done)))

;; (34) L56-K12 (`L53-1C` `#39 norman` `ESCROW_LOCKOUT: immortal, 455M/92G` under base attack -> warp in Stalkers):
(reset-macro-escrow-tracker!)
(define p-l53-immortal-escrow-break
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 9068
    #:minerals 455 #:gas 92 #:supply-used 34 #:supply-cap 55 #:supply-left 21 #:pending-supply 0
    #:workers 22 #:active-bases 2 #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 28 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 6 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'twilight-council 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 22 'stalker 4 'immortal 1)
    #:enemy-unit-counts (hasheq 'stalker 12 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-l53-immortal-escrow-break))))
             (not (eq? (macro-brain-decision-saving-for p-l53-immortal-escrow-break) 'immortal)))
        (format "L56-K12(34) #39 Immortal escrow break under attack failed: sav=~a sch=~s"
                (macro-brain-decision-saving-for p-l53-immortal-escrow-break)
                (macro-brain-decision-scheduled-ids p-l53-immortal-escrow-break)))

;; (35) L56-K12 (`L54-1B` un-lockers only: `#58` corruptor <100G at >=350M keeps min-floor=0 & allows
;;      Queen/Overseer#1 + `#39` colossus gas-guard releases under attack <180G/army<20 so Stalkers warp in):
(reset-macro-escrow-tracker!)
(define z-l54-corruptor-no-min-lock
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 12000
    #:minerals 420 #:gas 75 #:supply-used 78 #:supply-cap 104 #:supply-left 26 #:pending-supply 0
    #:workers 50 #:active-bases 3 #:mineral-harvesters 38 #:gas-harvesters 12
    #:army-supply 28 #:enemy-threat-supply 32 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'spire 1 'extractor 5)
    #:total-building-counts (hasheq 'hatchery 3 'lair 1 'spawning-pool 1 'spire 1 'extractor 5)
    #:unit-counts (hasheq 'drone 50 'queen 2 'corruptor 4 'overlord 10)
    #:enemy-unit-counts (hasheq 'tempest 8 'carrier 2 'observer 1)
    #:open-facility-slots (hasheq 'townhall 3 'larva 2))))
(reset-macro-escrow-tracker!)
(define p-l54-colossus-release-under-attack
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 10500
    #:minerals 460 #:gas 119 #:supply-used 42 #:supply-cap 70 #:supply-left 28 #:pending-supply 0
    #:workers 30 #:active-bases 2 #:mineral-harvesters 21 #:gas-harvesters 9
    #:army-supply 12 #:enemy-threat-supply 28 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 30 'stalker 4 'immortal 1)
    #:enemy-unit-counts (hasheq 'stalker 12 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 0))))
(check! (and (= (macro-brain-decision-reserved-min-floor z-l54-corruptor-no-min-lock) 0)
             (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-l54-corruptor-no-min-lock))))
             (not (not (memq 'overseer (macro-brain-decision-scheduled-ids z-l54-corruptor-no-min-lock))))
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-l54-colossus-release-under-attack))))
             (not (eq? (macro-brain-decision-saving-for p-l54-colossus-release-under-attack) 'colossus)))
        (format "L56-K12(35) Corruptor/Colossus escrow release failed: corr=(mf=~a sch=~s) col=(sav=~a sch=~s)"
                (macro-brain-decision-reserved-min-floor z-l54-corruptor-no-min-lock)
                (macro-brain-decision-scheduled-ids z-l54-corruptor-no-min-lock)
                (macro-brain-decision-saving-for p-l54-colossus-release-under-attack)
                (macro-brain-decision-scheduled-ids p-l54-colossus-release-under-attack)))

;; (36) L56-K13 (`L55-M1` ZvT early Lair at 525.0 when grounded w/ RoachWarren or >=8 army,
;;      yields when <8 army & 0 RoachWarren or >=2 Reapers):
(reset-macro-escrow-tracker!)
(define z-l55-zvt-early-lair
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 3900
    #:minerals 165 #:gas 115 #:supply-used 35 #:supply-cap 44 #:supply-left 9 #:pending-supply 0
    #:workers 27 #:active-bases 2 #:mineral-harvesters 21 #:gas-harvesters 6
    #:army-supply 8 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:unit-counts (hasheq 'drone 27 'queen 2 'roach 2 'zergling 8)
    #:enemy-unit-counts (hasheq 'marine 3)
    #:open-facility-slots (hasheq 'townhall 2 'larva 3))))
(reset-macro-escrow-tracker!)
(define z-l55-early-lair-blocked-no-rw
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 4100
    #:minerals 165 #:gas 115 #:supply-used 31 #:supply-cap 44 #:supply-left 13 #:pending-supply 0
    #:workers 27 #:active-bases 2 #:mineral-harvesters 21 #:gas-harvesters 6
    #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 2)
    #:unit-counts (hasheq 'drone 27 'queen 2 'zergling 4)
    #:enemy-unit-counts (hasheq 'marine 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 3))))
(reset-macro-escrow-tracker!)
(define z-l55-early-lair-blocked-reapers
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 4100
    #:minerals 165 #:gas 115 #:supply-used 35 #:supply-cap 44 #:supply-left 9 #:pending-supply 0
    #:workers 27 #:active-bases 2 #:mineral-harvesters 21 #:gas-harvesters 6
    #:army-supply 8 #:enemy-threat-supply 3 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1 'extractor 2)
    #:unit-counts (hasheq 'drone 27 'queen 2 'roach 2 'zergling 8)
    #:enemy-unit-counts (hasheq 'reaper 2)
    #:open-facility-slots (hasheq 'townhall 2 'larva 3))))
(check! (and (not (not (memq 'lair (macro-brain-decision-scheduled-ids z-l55-zvt-early-lair))))
             (>= (cand-u z-l55-zvt-early-lair 'lair) 525.0)
             (<= (cand-u z-l55-zvt-early-lair 'lair) 530.0)
             (not (memq 'lair (macro-brain-decision-scheduled-ids z-l55-early-lair-blocked-no-rw)))
             (not (not (memq 'roach-warren (macro-brain-decision-scheduled-ids z-l55-early-lair-blocked-no-rw))))
             (not (memq 'lair (macro-brain-decision-scheduled-ids z-l55-early-lair-blocked-reapers))))
        (format "L56-K13(36) ZvT Early-Lair guard failed: ok=(u=~a sch=~s) norw=(sch=~s) reap=(sch=~s)"
                (cand-u z-l55-zvt-early-lair 'lair)
                (macro-brain-decision-scheduled-ids z-l55-zvt-early-lair)
                (macro-brain-decision-scheduled-ids z-l55-early-lair-blocked-no-rw)
                (macro-brain-decision-scheduled-ids z-l55-early-lair-blocked-reapers)))

;; (37) L56-K13 (`L55-M2` `#25 onlyfans` Spore Crawler stays active up to min(2, bases) vs Banshees
;;      even after weaponless Overseer #1 morphs, ahead of Queen@1630/960):
(reset-macro-escrow-tracker!)
(define z-l55-spore-over-queen-with-overseer
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6000
    #:minerals 100 #:gas 40 #:supply-used 46 #:supply-cap 66 #:supply-left 20 #:pending-supply 0
    #:workers 32 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 14 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1 'extractor 2)
    #:unit-counts (hasheq 'drone 32 'queen 2 'overseer 1 'roach 5 'zergling 8)
    #:enemy-unit-counts (hasheq 'banshee 2 'marine 4)
    #:open-facility-slots (hasheq 'townhall 2 'larva 2))))
(check! (and (>= (cand-u z-l55-spore-over-queen-with-overseer 'spore-crawler) 1640.0)
             (not (not (memq 'spore-crawler (macro-brain-decision-scheduled-ids z-l55-spore-over-queen-with-overseer)))))
        (format "L56-K13(37) Spore Crawler w/ Overseer#1 vs Banshees failed: sp_u=~a sch=~s sav=~a"
                (cand-u z-l55-spore-over-queen-with-overseer 'spore-crawler)
                (macro-brain-decision-scheduled-ids z-l55-spore-over-queen-with-overseer)
                (macro-brain-decision-saving-for z-l55-spore-over-queen-with-overseer)))

;; (38) L56-K13 (`L55-M3` `#25 onlyfans` Post-HydraDen zerg-banshee-aa-gas-protect? drops gas floor 100G -> 50G):
(reset-macro-escrow-tracker!)
(define z-l55-post-hydraden-gas50
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6200
    #:minerals 200 #:gas 65 #:supply-used 46 #:supply-cap 66 #:supply-left 20 #:pending-supply 0
    #:workers 32 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 14 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1 'spore-crawler 2 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'hydralisk-den 1 'spore-crawler 2 'extractor 2)
    #:unit-counts (hasheq 'drone 32 'queen 4 'overseer 1 'roach 3 'hydralisk 1)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:open-facility-slots (hasheq 'townhall 2 'larva 0))))
(reset-macro-escrow-tracker!)
(define z-l55-pre-hydraden-gas100
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 5800
    #:minerals 200 #:gas 65 #:supply-used 46 #:supply-cap 66 #:supply-left 20 #:pending-supply 0
    #:workers 32 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 6
    #:army-supply 14 #:enemy-threat-supply 6 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 2 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'spore-crawler 2 'extractor 2)
    #:unit-counts (hasheq 'drone 32 'queen 4 'overseer 1 'roach 3)
    #:enemy-unit-counts (hasheq 'banshee 2)
    #:open-facility-slots (hasheq 'townhall 2 'larva 0))))
(check! (and (<= (macro-brain-decision-reserved-gas-floor z-l55-post-hydraden-gas50) 50)
             (macro-brain-can-spend? z-l55-post-hydraden-gas50 'hydralisk 200 65 'combat-unit)
             (>= (macro-brain-decision-reserved-gas-floor z-l55-pre-hydraden-gas100) 100))
        (format "L56-K13(38) Post-HydraDen gas floor 100->50 failed: post_gf=~a can_hydra=~a pre_gf=~a"
                (macro-brain-decision-reserved-gas-floor z-l55-post-hydraden-gas50)
                (macro-brain-can-spend? z-l55-post-hydraden-gas50 'hydralisk 200 65 'combat-unit)
                (macro-brain-decision-reserved-gas-floor z-l55-pre-hydraden-gas100)))

;; (39) L57-B1 (Lightweight `L52-1A` ONLY — 1-Base Natural Nexus Escrow Floor >=225M w/ >=2 combat units,
;;      preserving L51-1A 1st Stalker when <2 combat units; `L53-W2-4` Forge/RoboBay/Immortal stays dropped):
(reset-macro-escrow-tracker!)
(define p-l57-1base-nat-floor
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 4100
    #:minerals 260 #:gas 130 #:supply-used 28 #:supply-cap 39 #:supply-left 11 #:pending-supply 0
    #:workers 22 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'stalker 2)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))
(reset-macro-escrow-tracker!)
(define p-l57-1base-still-builds-first-stalker
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 2800
    #:minerals 140 #:gas 65 #:supply-used 24 #:supply-cap 31 #:supply-left 7 #:pending-supply 0
    #:workers 22 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 6
    #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 2 'pylon 2 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 22 'zealot 1)
    #:open-facility-slots (hasheq 'townhall 0 'gateway 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-l57-1base-nat-floor) 'nexus)
             (not (memq 'robotics-facility (macro-brain-decision-scheduled-ids p-l57-1base-nat-floor)))
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-l57-1base-nat-floor)))
             (not (memq 'twilight-council (macro-brain-decision-scheduled-ids p-l57-1base-nat-floor)))
             (not (memq 'stalker (macro-brain-decision-scheduled-ids p-l57-1base-nat-floor)))
             (not (not (memq 'stalker (macro-brain-decision-scheduled-ids p-l57-1base-still-builds-first-stalker)))))
        (format "L57-B1(39) Lightweight 1-Base Nexus floor failed: nat=(sav=~a sch=~s) st1=(sav=~a sch=~s)"
                (macro-brain-decision-saving-for p-l57-1base-nat-floor)
                (macro-brain-decision-scheduled-ids p-l57-1base-nat-floor)
                (macro-brain-decision-saving-for p-l57-1base-still-builds-first-stalker)
                (macro-brain-decision-scheduled-ids p-l57-1base-still-builds-first-stalker)))

;; (40) L57-B2 (`L54-1C` strictly under `mass-reapers?` >= 2 Reapers: Gateway #2 @ 504.0 > Shield Battery #1 @ 496.0,
;;      Shield Battery capped at 1 until gateways >= 2 && stalkers >= 2, while 0-Reaper PvT stays uncapped!):
(reset-macro-escrow-tracker!)
(define p-l57-reaper-gate2-over-sb1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 3900
    #:minerals 160 #:gas 60 #:supply-used 25 #:supply-cap 39 #:supply-left 14 #:pending-supply 0
    #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
    #:army-supply 2 #:enemy-threat-supply 3 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 21 'stalker 1)
    #:enemy-unit-counts (hasheq 'reaper 3)
    #:open-facility-slots (hasheq 'townhall 0 'gateway 0))))
(reset-macro-escrow-tracker!)
(define p-l57-reaper-sb-cap1
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 4100
    #:minerals 160 #:gas 40 #:supply-used 25 #:supply-cap 39 #:supply-left 14 #:pending-supply 0
    #:workers 21 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 6
    #:army-supply 2 #:enemy-threat-supply 3 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'shield-battery 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 1 'pylon 3 'gateway 1 'cybernetics-core 1 'shield-battery 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 21 'stalker 1)
    #:enemy-unit-counts (hasheq 'reaper 3)
    #:open-facility-slots (hasheq 'townhall 0 'gateway 0))))
(check! (and (>= (cand-u p-l57-reaper-gate2-over-sb1 'gateway) 504.0)
             (> (cand-u p-l57-reaper-gate2-over-sb1 'gateway)
                (cand-u p-l57-reaper-gate2-over-sb1 'shield-battery))
             (not (not (memq 'gateway (macro-brain-decision-scheduled-ids p-l57-reaper-gate2-over-sb1))))
             (not (memq 'shield-battery (macro-brain-decision-scheduled-ids p-l57-reaper-sb-cap1))))
        (format "L57-B2(40) Mass-Reaper Gate#2 > ShieldBattery#1 & cap=1 failed: g2=(gu=~a sbu=~a sch=~s) cap1=(sch=~s)"
                (cand-u p-l57-reaper-gate2-over-sb1 'gateway)
                (cand-u p-l57-reaper-gate2-over-sb1 'shield-battery)
                (macro-brain-decision-scheduled-ids p-l57-reaper-gate2-over-sb1)
                (macro-brain-decision-scheduled-ids p-l57-reaper-sb-cap1)))

;; (41) Loop 60 Package C (`5.0.14` Cost Alignment):
;;      Zerg schedules `hatchery` at `275M` and `queen` at `175M` (NOT `150M`!),
;;      and Protoss schedules `immortal` at `250M/100G`!
(reset-macro-escrow-tracker!)
(define z-l60-hatch-275m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 1344
    #:minerals 275 #:gas 0 #:supply-used 16 #:supply-cap 22 #:supply-left 6 #:pending-supply 0
    #:workers 16 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 1)
    #:total-building-counts (hasheq 'hatchery 1)
    #:unit-counts (hasheq 'drone 16 'overlord 2)
    #:open-facility-slots (hasheq 'townhall 1 'larva 2))))
(reset-macro-escrow-tracker!)
(define z-l60-queen-150m-wait
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 2600
    #:minerals 150 #:gas 0 #:supply-used 22 #:supply-cap 36 #:supply-left 14 #:pending-supply 0
    #:workers 20 #:active-bases 2 #:mineral-harvesters 17 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:unit-counts (hasheq 'drone 20 'queen 1 'zergling 4 'overlord 3)
    #:open-facility-slots (hasheq 'townhall 2 'larva 0))))
(reset-macro-escrow-tracker!)
(define z-l60-queen-175m-go
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 2600
    #:minerals 175 #:gas 0 #:supply-used 22 #:supply-cap 36 #:supply-left 14 #:pending-supply 0
    #:workers 20 #:active-bases 2 #:mineral-harvesters 17 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:unit-counts (hasheq 'drone 20 'queen 1 'zergling 4 'overlord 3)
    #:open-facility-slots (hasheq 'townhall 2 'larva 0))))
(reset-macro-escrow-tracker!)
(define p-l60-immortal-250m
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 5400
    #:minerals 250 #:gas 100 #:supply-used 46 #:supply-cap 70 #:supply-left 24 #:pending-supply 0
    #:workers 32 #:active-bases 2 #:mineral-harvesters 24 #:gas-harvesters 8
    #:army-supply 14 #:enemy-threat-supply 6 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 7 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 32 'stalker 6 'observer 1)
    #:enemy-unit-counts (hasheq 'stalker 6)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 0 'robotics-facility 1))))
(check! (and (not (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-l60-hatch-275m))))
             (not (memq 'queen (macro-brain-decision-scheduled-ids z-l60-queen-150m-wait)))
             (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-l60-queen-175m-go))))
             (not (not (memq 'immortal (macro-brain-decision-scheduled-ids p-l60-immortal-250m)))))
        (format "L60-PkgC(41) 5.0.14 costs failed: hatch275=~s q150=~s q175=~s imm250=~s"
                (macro-brain-decision-scheduled-ids z-l60-hatch-275m)
                (macro-brain-decision-scheduled-ids z-l60-queen-150m-wait)
                (macro-brain-decision-scheduled-ids z-l60-queen-175m-go)
                (macro-brain-decision-scheduled-ids p-l60-immortal-250m)))

;; (42) Loop 61 Phase 1 (`#1618`): Per-Building Parallel Upgrade Candidate Emission (T/P/Z)
;;      wired to `due-pro-upgrade-timings` (E-Bay + RaxTL, Forge + Twilight + TemplarArchive,
;;      2x Evo + RoachWarren all emit ready upgrades simultaneously without serial blocking!).
(let ()
  (define (cand-ids cs) (map priority-candidate-id cs))
  (define t-cands-2ebay
    (cand-ids
     (generate-race-priority-candidates
      #:race 'Terran #:enemy-race 'Protoss #:frame 7500
      #:minerals 400 #:gas 400 #:supply-left 20 #:supply-cap 90 #:workers 42 #:active-bases 2
      #:army-supply 28 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'orbital-command 2 'barracks 3 'barracks-techlab 1 'engineering-bay 2 'factory 1)
      #:total-building-counts (hasheq 'orbital-command 2 'barracks 3 'barracks-techlab 1 'engineering-bay 2 'factory 1)
      #:unit-counts (hasheq 'scv 42 'marine 14 'marauder 4)
      #:researched-upgrades '()
      #:open-prod-slots (hasheq 'townhall 2 'barracks 2 'barracks-techlab 1 'engineering-bay 2))))
  (define p-cands-3bldg
    (cand-ids
     (generate-race-priority-candidates
      #:race 'Protoss #:enemy-race 'Terran #:frame 8000
      #:minerals 500 #:gas 500 #:supply-left 20 #:supply-cap 95 #:workers 44 #:active-bases 2
      #:army-supply 31 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'nexus 2 'gateway 4 'cybernetics-core 1 'forge 1 'twilight-council 1 'templar-archive 1)
      #:total-building-counts (hasheq 'nexus 2 'gateway 4 'cybernetics-core 1 'forge 1 'twilight-council 1 'templar-archive 1)
      #:unit-counts (hasheq 'probe 44 'zealot 6 'stalker 6 'high-templar 2)
      #:researched-upgrades '(warp-gate-research)
      #:open-prod-slots (hasheq 'townhall 2 'gateway 4 'forge 1 'twilight-council 1 'templar-archive 1))))
  (define z-cands-2evo
    (cand-ids
     (generate-race-priority-candidates
      #:race 'Zerg #:enemy-race 'Terran #:frame 7800
      #:minerals 500 #:gas 500 #:supply-left 20 #:supply-cap 102 #:workers 50 #:active-bases 3
      #:army-supply 32 #:enemy-threat-supply 0 #:under-attack? #f
      #:ready-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'evolution-chamber 2)
      #:total-building-counts (hasheq 'hatchery 2 'lair 1 'spawning-pool 1 'roach-warren 1 'evolution-chamber 2)
      #:unit-counts (hasheq 'drone 50 'queen 4 'roach 10 'zergling 12)
      #:researched-upgrades '(metabolic-boost)
      #:open-prod-slots (hasheq 'townhall 3 'larva 4 'roach-warren 1 'evolution-chamber 2))))
  (check! (and (not (not (memq 'stimpack t-cands-2ebay)))
               (not (not (memq 'terran-infantry-weapons-1 t-cands-2ebay)))
               (not (not (memq 'terran-infantry-armor-1 t-cands-2ebay)))
               (not (not (memq 'protoss-ground-weapons-1 p-cands-3bldg)))
               (or (not (not (memq 'charge p-cands-3bldg)))
                   (not (not (memq 'blink p-cands-3bldg))))
               (not (not (memq 'psi-storm p-cands-3bldg)))
               (not (not (memq 'glial-reconstitution z-cands-2evo)))
               (>= (length (filter (lambda (u) (memq u z-cands-2evo))
                                   '(zerg-missile-weapons-1 zerg-ground-armor-1 zerg-melee-weapons-1)))
                   2))
          (format "L61-PkgC(42) Parallel per-building upgrades failed: T=~s P=~s Z=~s"
                  t-cands-2ebay p-cands-3bldg z-cands-2evo)))

(reset-macro-escrow-tracker!)
(printf "l49-stall-watchdog-test: ~a/~a passed (~a failed) [wd_8calls_avg=~a ms]\n"
        passed (+ passed failed) failed (~r avg-ms #:precision '(= 5)))
(when (> failed 0) (exit 1))
