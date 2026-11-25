#lang racket/base

;; =============================================================================
;; Loop 73 Lane A Unit Test Suite (`tests/l73-belief-supply-spend-test.rkt`)
;;
;; Verifies Loop 73 Lane A (`lib/econ-ledger.rkt` & `lib/priority-macro-brain.rkt`):
;;   1. Zerg opening `13/14` Overlord preemption (`13/14 -> #t`, `12/14 -> #f`,
;;      `13/14 pend=1 -> #f`, plus `cap < 14` Overlord-loss safety `8/8 -> #t`).
;;   2. Protoss opening `13/15` Pylon #1 preemption (`13/15 -> #t`, `12/15 -> #f`),
;;      while keeping Terran `13/15 -> #t` untouched.
;;   3. Protoss `cap = 23` Pylon #2 preemption (`19/23 -> #t`, `18/23 -> #f`).
;;   4. Terran `cap = 23` strictly untouched (`19/23 -> #f`, `20/23 -> #f`,
;;      `21/23 -> #t`) so Natural CC #2 stays ahead of Depot #2.
;;   5. Zerg midgame inject-burst margins (`24/30 -> #t`, `23/30 -> #f`;
;;      `45/52 -> #t`, `44/52 -> #f`).
;;   6. Macro-brain `protoss-cyber-before-pylon2?`: with 1 Pylon, ready Gateway,
;;      0 CyberCore, 150M: at `19/23` (`supply-left = 4`) CyberCore is still allowed,
;;      while at `20/23` (`supply-left = 3`) Pylon #2 strictly takes priority!
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

(define (cand-u dec sym)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))
  (define hit (findf (lambda (e) (eq? (priority-decision-entry-id e) sym)) trace))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

;; 1. Zerg opening 13/14 & cap < 14 Overlord-loss safety
(check! (and (supply-preemption-needed? 13 14 0 #:race 'Zerg)
             (not (supply-preemption-needed? 12 14 0 #:race 'Zerg))
             (not (supply-preemption-needed? 13 14 1 #:race 'Zerg))
             (supply-preemption-needed? 8 8 0 #:race 'Zerg)
             (not (supply-preemption-needed? 7 8 0 #:race 'Zerg)))
        "1. Zerg 13/14 must trigger Overlord preemption (12/14=#f, pend=1=#f) and preserve cap<14 Overlord-loss safety")

;; 2. Protoss 13/15 Pylon #1 & Terran 13/15 untouched
(check! (and (supply-preemption-needed? 13 15 0 #:race 'Protoss)
             (not (supply-preemption-needed? 12 15 0 #:race 'Protoss))
             (not (supply-preemption-needed? 13 15 1 #:race 'Protoss))
             (supply-preemption-needed? 13 15 0 #:race 'Terran)
             (not (supply-preemption-needed? 12 15 0 #:race 'Terran)))
        "2. Protoss 13/15 must trigger Pylon #1 preemption (12/15=#f, pend=1=#f) while Terran 13/15 stays untouched")

;; 3. Protoss cap = 23 Pylon #2 margin = 4 (19/23)
(check! (and (supply-preemption-needed? 19 23 0 #:race 'Protoss)
             (not (supply-preemption-needed? 18 23 0 #:race 'Protoss))
             (not (supply-preemption-needed? 19 23 1 #:race 'Protoss)))
        "3. Protoss cap=23 must trigger Pylon #2 at 19/23 (18/23=#f, pend=1=#f)")

;; 4. Terran cap = 23 strictly untouched (margin = 2 -> 21/23)
(check! (and (not (supply-preemption-needed? 19 23 0 #:race 'Terran))
             (not (supply-preemption-needed? 20 23 0 #:race 'Terran))
             (supply-preemption-needed? 21 23 0 #:race 'Terran))
        "4. Terran cap=23 must remain strictly margin=2 (19/23=#f, 20/23=#f, 21/23=#t)")

;; 5. Zerg midgame inject-burst margins (+2 at cap>=28, +3 at cap>=52)
(check! (and (supply-preemption-needed? 24 30 0 #:race 'Zerg)
             (not (supply-preemption-needed? 23 30 0 #:race 'Zerg))
             (supply-preemption-needed? 45 52 0 #:race 'Zerg)
             (not (supply-preemption-needed? 44 52 0 #:race 'Zerg))
             (not (supply-preemption-needed? 19 22 0 #:race 'Zerg))
             (supply-preemption-needed? 20 22 0 #:race 'Zerg))
        "5. Zerg midgame margins must trigger at 24/30 (margin=6), 45/52 (margin=7), and preserve 20/22 (margin=2)")

;; 6. Macro-brain integration: Protoss 1 Pylon, ready Gateway, 0 CyberCore, 150M:
;;    - At 19/23 (supply-left = 4): CyberCore is still allowed (`cybernetics-core` scheduled);
;;    - At 20/23 (supply-left = 3): Pylon #2 takes priority over CyberCore (`pylon` scheduled, NOT `cybernetics-core`!).
(reset-macro-escrow-tracker!)
(define p-19-23-cyber-ok-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 1800
    #:minerals 150 #:gas 0 #:supply-used 19 #:supply-cap 23 #:supply-left 4 #:pending-supply 0
    #:workers 17 #:active-bases 1 #:mineral-harvesters 14 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 17 'zealot 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))

(reset-macro-escrow-tracker!)
(define p-20-23-pylon2-wins-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 1950
    #:minerals 150 #:gas 0 #:supply-used 20 #:supply-cap 23 #:supply-left 3 #:pending-supply 0
    #:workers 18 #:active-bases 1 #:mineral-harvesters 15 #:gas-harvesters 3
    #:army-supply 2 #:enemy-threat-supply 0 #:under-attack? #f #:requires-anti-air? #f
    #:ready-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
    #:total-building-counts (hasheq 'nexus 1 'pylon 1 'gateway 1 'assimilator 1)
    #:unit-counts (hasheq 'probe 18 'zealot 1)
    #:open-facility-slots (hasheq 'townhall 1 'gateway 1))))

(check! (and (not (not (memq 'cybernetics-core (macro-brain-decision-scheduled-ids p-19-23-cyber-ok-dec))))
             (not (not (memq 'pylon (macro-brain-decision-scheduled-ids p-20-23-pylon2-wins-dec))))
             (not (memq 'cybernetics-core (macro-brain-decision-scheduled-ids p-20-23-pylon2-wins-dec)))
             (> (cand-u p-20-23-pylon2-wins-dec 'pylon)
                (cand-u p-20-23-pylon2-wins-dec 'cybernetics-core)))
        (format "6. Protoss 1-Pylon ready-GW 150M: 19/23 (left=4) must allow CyberCore while 20/23 (left=3) must prioritize Pylon #2; 19/23=~s 20/23=~s u_pyl=~a u_cyb=~a"
                (macro-brain-decision-scheduled-ids p-19-23-cyber-ok-dec)
                (macro-brain-decision-scheduled-ids p-20-23-pylon2-wins-dec)
                (cand-u p-20-23-pylon2-wins-dec 'pylon)
                (cand-u p-20-23-pylon2-wins-dec 'cybernetics-core)))

(printf "l73-belief-supply-spend-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
