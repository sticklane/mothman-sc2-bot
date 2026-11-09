#lang racket/base

(require racket/list
         racket/match
         "../lib/econ-ledger.rkt"
         "../lib/priority-macro-brain.rkt"
         "../lib/bot-runtime.rkt")

(define total-checks 0)

(define (check-equal? actual expected [msg "check-equal? failed"])
  (set! total-checks (add1 total-checks))
  (unless (equal? actual expected)
    (error 'check-equal? "~a: expected ~v, got ~v" msg expected actual)))

(define (check-true val [msg "check-true failed"])
  (set! total-checks (add1 total-checks))
  (unless val
    (error 'check-true "~a: got ~v" msg val)))

(define (check-false val [msg "check-false failed"])
  (set! total-checks (add1 total-checks))
  (when val
    (error 'check-false "~a: got ~v" msg val)))

(define (check-not-false val [msg "check-not-false failed"])
  (set! total-checks (add1 total-checks))
  (unless val
    (error 'check-not-false "~a: got #f" msg)))

(define-syntax-rule (test-case label body ...)
  (begin
    (printf "  [TEST] ~a ... " label)
    (flush-output)
    (let () body ...)
    (printf "OK\n")
    (flush-output)))

(printf "=== Chaos Monkey Build-Order & Decoupled Priority Macro Brain Test Suite ===\n")

;; -----------------------------------------------------------------------------
;; 1. Declarative SC2 Tech Graph & Self-Healing Prerequisite DAG Tests
;; -----------------------------------------------------------------------------
(test-case "Tech DAG resolves multi-step missing prerequisite chains in topological order"
  ;; Terran: Stimpack requires barracks-techlab -> barracks -> supply-depot
  (check-equal? (resolve-missing-prereq-chain 'stimpack (hasheq 'command-center 1) (hasheq 'command-center 1))
                '(supply-depot barracks barracks-techlab))
  ;; Terran: Siege Tank when depot + barracks exist, but factory + factory-techlab were deleted
  (check-equal? (resolve-missing-prereq-chain 'siege-tank
                                              (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
                                              (hasheq 'command-center 1 'supply-depot 1 'barracks 1))
                '(factory factory-techlab))
  ;; Protoss: Immortal when all Pylons, Gateways, CyberCore, and Robo were deleted
  (check-equal? (resolve-missing-prereq-chain 'immortal (hasheq 'nexus 1) (hasheq 'nexus 1))
                '(pylon gateway cybernetics-core robotics-facility))
  ;; Zerg: Glial Reconstitution when Spawning Pool and Roach Warren were deleted (Lair still alive)
  (check-equal? (resolve-missing-prereq-chain 'glial-reconstitution
                                              (hasheq 'lair 1)
                                              (hasheq 'lair 1))
                '(spawning-pool roach-warren)))

(test-case "find-all-broken-tech-dependencies detects orphaned mid-game tech structures"
  ;; Suppose Zerg has a Lair and Hydralisk Den, but Chaos Monkey deleted Spawning Pool
  (define broken-z
    (find-all-broken-tech-dependencies 'Zerg
                                       (hasheq 'lair 1 'hydralisk-den 1)
                                       (hasheq 'lair 1 'hydralisk-den 1)))
  (check-not-false (memq 'spawning-pool broken-z))

  ;; Suppose Protoss has Cybernetics Core and Twilight Council, but Chaos Monkey deleted Pylon and Gateway
  (define broken-p
    (find-all-broken-tech-dependencies 'Protoss
                                       (hasheq 'nexus 1 'cybernetics-core 1 'twilight-council 1)
                                       (hasheq 'nexus 1 'cybernetics-core 1 'twilight-council 1)))
  (check-equal? broken-p '(pylon gateway)))

;; -----------------------------------------------------------------------------
;; 2. Frame-0 Opening Feasibility (No Unready Units Scheduled at f=0)
;; -----------------------------------------------------------------------------
(test-case "Frame-0 opening schedules only feasible worker (drone/scv/probe), never unready combat units"
  (for ([race-pair (in-list '((Zerg drone hatchery 14)
                              (Terran scv command-center 15)
                              (Protoss probe nexus 15)))])
    (match-define (list r w-sym th-sym cap) race-pair)
    (define st
      (make-macro-world-state
       #:race r
       #:frame 0
       #:minerals 50
       #:gas 0
       #:supply-used 12
       #:supply-cap cap
       #:workers 12
       #:active-bases 1
       #:ready-building-counts (hasheq th-sym 1)
       #:total-building-counts (hasheq th-sym 1)
       #:unit-counts (if (eq? r 'Zerg)
                         (hasheq w-sym 12 'overlord 1)
                         (hasheq w-sym 12))
       #:open-facility-slots (hasheq 'townhall 1 'larva 3)))
    (define dec (step-priority-macro-brain st))
    (check-equal? (macro-brain-decision-scheduled-ids dec) (list w-sym)
                  (format "~a at f=0 must schedule ~a, not unready combat units" r w-sym))
    (check-equal? (macro-brain-decision-saving-for dec) 'none)))

;; -----------------------------------------------------------------------------
;; 3. Zero-Worker & Low-Worker Recovery (No Deadlock Escrowing 100M at 0 Workers)
;; -----------------------------------------------------------------------------
(test-case "Zero-worker crisis with 75M schedules worker immediately instead of escrowing 100M for Zealot/Marine"
  (for ([race-pair (in-list '((Protoss probe nexus gateway)
                              (Terran scv command-center barracks)
                              (Zerg drone hatchery spawning-pool)))])
    (match-define (list r w-sym th-sym fac-sym) race-pair)
    (define st
      (make-macro-world-state
       #:race r
       #:frame 2600
       #:minerals 75
       #:gas 0
       #:supply-used 0
       #:supply-cap 23
       #:workers 0
       #:active-bases 1
       #:ready-building-counts (hasheq th-sym 1 fac-sym 1 'pylon 1 'supply-depot 1)
       #:total-building-counts (hasheq th-sym 1 fac-sym 1 'pylon 1 'supply-depot 1)
       #:unit-counts (hasheq)
       #:open-facility-slots (hasheq 'townhall 1 'larva 3 'gateway 1 'barracks 1)
       #:under-attack? #t))
    (define dec (step-priority-macro-brain st))
    (check-not-false (memq w-sym (macro-brain-decision-scheduled-ids dec))
                     (format "~a with 0 workers and 75M must schedule ~a to restore income" r w-sym))
    (check-equal? (macro-brain-decision-reserved-min-floor dec) 0)))

;; -----------------------------------------------------------------------------
;; 4. Zero-Gas-Building Deadlock Prevention (Gas Escrow Feasibility)
;; -----------------------------------------------------------------------------
(test-case "Gas-requiring tech cannot escrow minerals when all gas buildings are destroyed and gas < cost"
  ;; Zerg has Spawning Pool, 250M/25G, 0 Extractors, needs Lair (150M/100G) and Metabolic Boost (100M/100G)
  (define st-z
    (make-macro-world-state
     #:race 'Zerg
     #:frame 3000
     #:minerals 120
     #:gas 25
     #:supply-used 24
     #:supply-cap 36
     #:workers 20
     #:active-bases 2
     #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1)
     #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1)
     #:unit-counts (hasheq 'drone 20 'overlord 3 'queen 2)
     #:open-facility-slots (hasheq 'townhall 2 'larva 4 'spawning-pool 1)))
  (define dec-z (step-priority-macro-brain st-z))
  ;; Metabolic boost / Lair must NOT set a mineral escrow floor because gas income is 0 (0 extractors);
  ;; Extractor (25M) must be scheduled to restore gas income!
  (check-not-false (memq 'extractor (macro-brain-decision-scheduled-ids dec-z)))
  (check-equal? (macro-brain-decision-reserved-gas-floor dec-z) 0))

;; -----------------------------------------------------------------------------
;; 5. Dual-Resource (Gas + Mineral) & Facility-Slot Escrow (Stimpack vs Concussive)
;; -----------------------------------------------------------------------------
(test-case "Barracks TechLab escrows gas & research slot for Stimpack (100G) at 85G, blocking Concussive Shells (50G)"
  (define st-t
    (make-macro-world-state
     #:race 'Terran
     #:frame 2400
     #:minerals 120
     #:gas 85
     #:supply-used 23
     #:supply-cap 31
     #:workers 20
     #:active-bases 2
     #:ready-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 2 'barracks 1 'barracks-techlab 1 'refinery 1)
     #:total-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 2 'barracks 1 'barracks-techlab 1 'refinery 1)
     #:unit-counts (hasheq 'scv 20 'marine 3)
     #:open-facility-slots (hasheq 'townhall 2 'barracks 1 'barracks-techlab 1)))
  (define dec-t (step-priority-macro-brain st-t))
  (check-equal? (macro-brain-decision-saving-for dec-t) 'stimpack)
  (check-equal? (macro-brain-decision-reserved-gas-floor dec-t) 100)
  (check-not-false (memq 'barracks-techlab (macro-brain-decision-reserved-slots dec-t)))
  ;; Concussive shells (50M/50G) must be blocked by the gas escrow & TechLab slot reservation!
  (check-false (macro-brain-can-spend? dec-t 'concussive-shells 120 85 'tech-upgrade)))

;; -----------------------------------------------------------------------------
;; 6. Supply Deletion Crisis Recovery (Negative Free Supply)
;; -----------------------------------------------------------------------------
(test-case "Deleting all Pylons/Depots/Overlords at 38 supply triggers immediate supply recovery + prereq repair"
  (define st-p
    (make-macro-world-state
     #:race 'Protoss
     #:frame 3600
     #:minerals 150
     #:gas 100
     #:supply-used 38
     #:supply-cap 15      ;; All Pylons destroyed! Only 1 Nexus (15 cap) remains
     #:supply-left -23
     #:pending-supply 0
     #:workers 22
     #:active-bases 1
     #:ready-building-counts (hasheq 'nexus 1 'gateway 2 'cybernetics-core 1 'assimilator 2)
     #:total-building-counts (hasheq 'nexus 1 'gateway 2 'cybernetics-core 1 'assimilator 2)
     #:unit-counts (hasheq 'probe 22 'stalker 6 'zealot 2)
     #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'cybernetics-core 1)))
  (define dec-p (step-priority-macro-brain st-p))
  (check-not-false (memq 'pylon (macro-brain-decision-scheduled-ids dec-p)))
  (check-not-false (memq 'pylon (macro-brain-decision-repaired-prereqs dec-p))))

;; -----------------------------------------------------------------------------
;; 7. Multi-Matchup Chaos Monkey Build-Order Recovery Campaign
;; -----------------------------------------------------------------------------
(test-case "Chaos Monkey Campaign: 27 randomized trials across all 9 matchups recover 100% of build orders"
  (define results
    (run-chaos-monkey-campaign
     #:trials-per-race 3
     #:max-frames 15000
     #:severity 0.65))
  (check-equal? (length results) 27)
  (define total-deletions
    (for/sum ([r (in-list results)])
      (chaos-monkey-trial-result-chaos-deletions-count r)))
  (printf "  Executed 27 full-game Chaos Monkey trials (~~405,000 simulated frames) with ~a random deletion waves.\n"
          total-deletions)
  (for ([r (in-list results)]
        [idx (in-naturals 1)])
    (unless (chaos-monkey-trial-result-recovered-all-bo-goals? r)
      (printf "  [FAILURE] Trial #~a (~a vs ~a, seed=~a) unsatisfied goals: ~s\n    events: ~s\n"
              idx
              (chaos-monkey-trial-result-race r)
              (chaos-monkey-trial-result-enemy-race r)
              (chaos-monkey-trial-result-seed r)
              (chaos-monkey-trial-result-unsatisfied-bo-goals r)
              (map chaos-monkey-event-state-summary (chaos-monkey-trial-result-chaos-events r))))
    (check-true (chaos-monkey-trial-result-recovered-all-bo-goals? r)
                (format "Trial #~a (~a vs ~a) must recover all build-order goals after ~a deletions"
                        idx
                        (chaos-monkey-trial-result-race r)
                        (chaos-monkey-trial-result-enemy-race r)
                        (chaos-monkey-trial-result-chaos-deletions-count r)))
    (check-true (>= (chaos-monkey-trial-result-final-workers r) 20)
                (format "Trial #~a (~a vs ~a) final-workers=~a" idx (chaos-monkey-trial-result-race r) (chaos-monkey-trial-result-enemy-race r) (chaos-monkey-trial-result-final-workers r)))
    (check-true (>= (chaos-monkey-trial-result-final-bases r) 2)
                (format "Trial #~a (~a vs ~a) final-bases=~a" idx (chaos-monkey-trial-result-race r) (chaos-monkey-trial-result-enemy-race r) (chaos-monkey-trial-result-final-bases r)))
    (check-true (>= (chaos-monkey-trial-result-final-supply-cap r)
                    (chaos-monkey-trial-result-final-supply-used r))
                (format "Trial #~a (~a vs ~a) sup=~a/~a" idx (chaos-monkey-trial-result-race r) (chaos-monkey-trial-result-enemy-race r) (chaos-monkey-trial-result-final-supply-used r) (chaos-monkey-trial-result-final-supply-cap r)))))

;; -----------------------------------------------------------------------------
;; 8. Extreme Adversarial Chaos Monkey Wipeout Test (10 Deletion Waves in One Game)
;; -----------------------------------------------------------------------------
(test-case "Extreme Adversarial Chaos Monkey: 8 deletion waves (including 100% worker wipeout + TechLab/Pool/Pylon snipes)"
  (for ([r (in-list '(Zerg Terran Protoss))])
    (define res
      (run-chaos-monkey-build-order-trial
       #:race r
       #:enemy-race 'Terran
       #:seed 999
       #:max-frames 18000
       #:deletion-frames '(1200 2200 3200 4200 5200 6200 7200 8200)
       #:forced-deletion-categories '(supply worker tech-building addon gas-building expansion tech-building worker)
       #:severity 0.85))
    (printf "  [Extreme Chaos ~a] deletions=~a recovered? ~a final_workers=~a bases=~a sup=~a/~a upgs=~a\n"
            r
            (chaos-monkey-trial-result-chaos-deletions-count res)
            (chaos-monkey-trial-result-recovered-all-bo-goals? res)
            (chaos-monkey-trial-result-final-workers res)
            (chaos-monkey-trial-result-final-bases res)
            (chaos-monkey-trial-result-final-supply-used res)
            (chaos-monkey-trial-result-final-supply-cap res)
            (chaos-monkey-trial-result-final-researched-upgrades res))
    (unless (chaos-monkey-trial-result-recovered-all-bo-goals? res)
      (printf "    unsatisfied: ~s\n    ready-bldgs: ~s\n    events: ~s\n"
              (chaos-monkey-trial-result-unsatisfied-bo-goals res)
              (chaos-monkey-trial-result-final-ready-buildings res)
              (map chaos-monkey-event-state-summary (chaos-monkey-trial-result-chaos-events res))))
    (check-true (chaos-monkey-trial-result-recovered-all-bo-goals? res)
                (format "Extreme 8-wave Chaos Monkey for ~a must recover 100% of build order" r))))

;; -----------------------------------------------------------------------------
;; 9. Live Runtime Integration: step-live-bot-runtime! Uses priority-macro-brain
;; -----------------------------------------------------------------------------
(test-case "step-live-bot-runtime! tracks peak-supply-reached & self-heals deleted Spawning Pool when Roach Warren is orphaned"
  (define rt (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  ;; Step 1: Reach 42 supply with Hatchery, Spawning Pool, Roach Warren
  (define obs1
    (hash 'frame 2400
          'minerals 250
          'gas 100
          'supply-used 42
          'supply-cap 54
          'ally-units (for/list ([i (in-range 22)])
                        (hash 'id (+ 100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
          'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                (hash 'id 2 'type 'hatchery 'x 45.0 'y 45.0 'hp 1500 'build-progress 1.0)
                                (hash 'id 3 'type 'spawning-pool 'x 35.0 'y 32.5 'hp 1000 'build-progress 1.0)
                                (hash 'id 4 'type 'roach-warren 'x 36.0 'y 32.5 'hp 850 'build-progress 1.0)
                                (hash 'id 5 'type 'extractor 'x 30.0 'y 32.5 'hp 500 'build-progress 1.0))))
  (step-live-bot-runtime! rt obs1)
  (check-equal? (hash-ref (live-bot-runtime-last-telemetry rt) 'peak-supply-reached 0) 42)
  ;; Step 2: Chaos Monkey snipes Spawning Pool and kills units down to 24 supply
  (define obs2
    (hash 'frame 2500
          'minerals 250
          'gas 100
          'supply-used 24
          'supply-cap 54
          'ally-units (for/list ([i (in-range 18)])
                        (hash 'id (+ 100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
          'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                (hash 'id 2 'type 'hatchery 'x 45.0 'y 45.0 'hp 1500 'build-progress 1.0)
                                (hash 'id 4 'type 'roach-warren 'x 36.0 'y 32.5 'hp 850 'build-progress 1.0)
                                (hash 'id 5 'type 'extractor 'x 30.0 'y 32.5 'hp 500 'build-progress 1.0))))
  (define res2 (step-live-bot-runtime! rt obs2))
  (define cmds2 (hash-ref res2 'actions '()))
  (define tel2 (live-bot-runtime-last-telemetry rt))
  (check-equal? (hash-ref tel2 'peak-supply-reached 0) 42)
  (check-not-false (memq 'spawning-pool (hash-ref tel2 'priority-repaired-prereqs '())))
  (check-not-false (ormap (lambda (c) (and (pair? c) (eq? (car c) 'build) (eq? (cadr c) 'spawning-pool))) cmds2))

  ;; Step 3: Protoss live runtime test — Cybernetics Core sniped while Twilight Council is alive
  (define rt-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define obs-p
    (hash 'frame 3000
          'minerals 200
          'gas 100
          'supply-used 46
          'supply-cap 62
          'ally-units (for/list ([i (in-range 22)])
                        (hash 'id (+ 300 i) 'type 'probe 'x 32.5 'y 32.5 'hp 40))
          'ally-buildings (list (hash 'id 11 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                (hash 'id 12 'type 'pylon 'x 35.0 'y 32.5 'hp 400 'build-progress 1.0)
                                (hash 'id 13 'type 'gateway 'x 36.0 'y 32.5 'hp 500 'build-progress 1.0)
                                (hash 'id 14 'type 'twilight-council 'x 37.0 'y 32.5 'hp 500 'build-progress 1.0)
                                (hash 'id 15 'type 'assimilator 'x 30.0 'y 32.5 'hp 450 'build-progress 1.0))))
  (define res-p (step-live-bot-runtime! rt-p obs-p))
  (define cmds-p (hash-ref res-p 'actions '()))
  (define tel-p (live-bot-runtime-last-telemetry rt-p))
  (check-not-false (memq 'cybernetics-core (hash-ref tel-p 'priority-repaired-prereqs '())))
  (check-not-false (ormap (lambda (c) (and (pair? c) (eq? (car c) 'build) (eq? (cadr c) 'cybernetics-core))) cmds-p)))

(printf "=== All Chaos Monkey & Priority Macro Brain Tests PASSED! ===\n")
