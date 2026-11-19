#lang racket/base

(require racket/match
         racket/list
         racket/math
         racket/string
         racket/runtime-path
         "../compiler/syntax.rkt"
         (except-in "sc2-common.rkt"
                    pro-unit-timing
                    struct:pro-unit-timing
                    pro-unit-timing?
                    pro-unit-timing-unit-sym
                    pro-unit-timing-target-count
                    pro-unit-timing-min-supply
                    pro-unit-timing-target-sec
                    pro-unit-timing-prereq-ready-sym
                    pro-upgrade-timing
                    struct:pro-upgrade-timing
                    pro-upgrade-timing?
                    pro-upgrade-timing-upgrade-sym
                    pro-upgrade-timing-start-sec
                    pro-upgrade-timing-complete-sec
                    pro-upgrade-timing-min-supply
                    pro-upgrade-timing-prereq-ready-sym)
         (only-in "sc2-types.rkt"
                  pro-bo-eval-result
                  struct:pro-bo-eval-result
                  pro-bo-eval-result?
                  pro-bo-eval-result-matchup
                  pro-bo-eval-result-active-goal
                  pro-bo-eval-result-ready-actions
                  pro-bo-eval-result-reserved-minerals
                  pro-bo-eval-result-reserved-gas
                  pro-bo-eval-result-target-workers
                  pro-bo-eval-result-target-army-supply
                  normalize-known-race
                  resolve-matchup-symbol)
         "sc2-game-constants.rkt"
         "build-orders.rkt")

(provide
 ;; Build-Order Combinators & Locutus Worker Chaining
 (struct-out bo-node)
 bo-step
 seq>>
 par||
 auto-supply
 saturate-bases
 chain-worker>>
 compile-build-order
 build-order-grade

 ;; McRave UCB1 Multi-Armed Bandit Strategy Selector
 (struct-out ucb1-arm)
 (struct-out ucb1-bandit)
 make-ucb1-bandit
 ucb1-score
 ucb1-select-arm
 ucb1-update-arm!

 ;; BOSS Branch-and-Bound Goal Synthesis
 (struct-out boss-plan)
 boss-synthesize-build-plan

 ;; Stardust HTN Plays
 (struct-out htn-play)
 make-htn-play
 htn-decompose-play
 htn-preempt-play

 ;; Symbiotic Resource Ledger with Borrowing + Crisis Preemption
 (struct-out ledger-lease)
 (struct-out symbiotic-ledger)
 make-symbiotic-ledger
 ledger-available-minerals
 ledger-available-gas
 ledger-available-supply
 ledger-reserve!
 ledger-borrow!
 ledger-preempt-for-crisis!
 ledger-repay!
 ledger-commit!
 ledger-verify-invariant?

 ;; Coupled Depletion-Driven Macro & Map-Wide Expansion Governor
 (struct-out coupled-macro-plan)
 evaluate-coupled-macro-governor

 ;; Planned & Adaptive Build-Order & Tech/Upgrade Goal Planner
 (struct-out build-goal-stage)
 (struct-out adaptive-tech-plan)
 evaluate-adaptive-build-and-tech-plan

 ;; Guns-vs-Butter PPF & Dynamic Gas-to-Mineral Worker Allocation Controller
 (struct-out gas-worker-allocation)
 compute-optimal-gas-workers
 (struct-out guns-vs-butter-ppf)
 evaluate-guns-vs-butter-ppf

 ;; Marginal-Utility Prioritization & Resource Scheduler (PV1-PV9)
 (struct-out priority-candidate)
 (struct-out priority-decision-entry)
 (struct-out priority-schedule-result)
 (struct-out opponent-intel-quality)
 PV-INTEL-GATHERING-UNIT-SYMS
 evaluate-opponent-intel-quality
 select-intel-gathering-method
 ZERG-SIEGE-SPLASH-ENEMY-SYMS
 TERRAN-GHOST-COUNTER-ENEMY-SYMS
 TERRAN-LIBERATOR-COUNTER-ENEMY-SYMS
 PROTOSS-CAPITAL-AIR-ENEMY-SYMS
 normalize-enemy-race-sym
 enemy-counts-have-any?
 gas-building-cap
 gas-building-cap-ok?
 zerg-stepped-drone-army-floor
 zerg-worker-army-floor-ok?
 zergling-target-cap
 terran-desired-barracks-techlabs
 terran-desired-factories
 terran-enemy-needs-ghost?
 terran-enemy-needs-liberator?
 terran-desired-ghost-cap
 terran-desired-liberator-cap
 protoss-enemy-capital-air?
 protoss-4th-nexus-due?
 CRISIS-DEFENDER-SYMS
 CRISIS-DEFERRED-UPGRADE-SYMS
 CRISIS-DEFERRED-TECH-SYMS
 TERRAN-GROUND-AA-SCREEN-ENEMY-SYMS
 crisis-defense-tech-defer-active?
 crisis-deferred-sym?
 terran-enemy-ground-aa-count
 terran-enemy-capital-air-with-ground-aa?
 terran-desired-thor-cap
 terran-air-fleet-count
 terran-ship-weapons-due?
 enemy-any-counts-have?
 enemy-any-count
 has-upgrade-sym?
 normalize-unit-benchmark-sym
 normalized-pro-unit-benchmarks
 compute-benchmark-deficit-ratio
 desired-zerg-queen-count
 zerg-queen-target
 desired-zerg-overseer-count
 desired-zerg-overlord-transport-count
 zerg-enemy-stargate-air-threat?
 ZERG-HARASS-AIR-ENEMY-SYMS
 zerg-enemy-air-spire-needed?
 zerg-enemy-capital-air-corruptor-cap
 desired-zerg-spore-count
 protoss-enemy-fast-kiter-threat?
 terran-enemy-cannon-contain?
 worker-recovery-after-cannon-or-contain?
 suppress-terran-extra-barracks-for-tvp-factory?
 enrich-priority-metrics
 compute-state-pressure-metrics
 compute-candidate-marginal-utility
 generate-race-priority-candidates
 schedule-priority-candidates-with-ledger!
 priority-schedule-decision-trace
 priority-schedule-can-spend?
 priority-schedule-summary-hash
 format-priority-schedule-log-line
 (struct-out refractory-cooldown-tracker)
 make-refractory-cooldown-tracker
 refractory-allow-action?!

 ;; Empirical Pro Replay Build-Order Database & Goal-Queue Executor
 ;; (Canonical definitions in `lib/sc2-types.rkt` and `lib/build-orders.rkt`)
 PRO-BUILD-ORDER-DB
 (struct-out pro-bo-goal)
 make-pro-bo-goal
 (struct-out pro-unit-timing)
 (struct-out pro-upgrade-timing)
 (struct-out pro-bo-eval-result)
 find-matchup-entry
 select-pro-build-order
 pro-build-order-steps-for-matchup
 pro-unit-timings-for-matchup
 pro-unit-benchmark-timings-for-matchup
 pro-unit-benchmarks-at-frame
 pro-upgrade-timings-for-matchup
 due-pro-unit-timings
 due-pro-upgrade-timings
 race-macro-worker-cap
 pro-supply-curve-target
 pro-supply-curve-target-for-spec
 PvZ-ANTI-EARLY-POOL-BUILD-ORDER
 TvZ-ANTI-EARLY-POOL-BUILD-ORDER
 ZvX-ANTI-EARLY-RUSH-BUILD-ORDER
 TvP-2BASE-STIM-TIMING-BUILD-ORDER
 ZvP-2BASE-ROACH-RAVAGER-TIMING-BUILD-ORDER
 REACTIVE-BUILD-ORDER-VARIANTS
 select-reactive-build-order-spec
 evaluate-build-order-next-step
 compute-natural-expansion-mineral-reserve
 ;; Build-Order Tactical Execution & Timing-Attack Plans
 (struct-out bo-tactical-phase-plan)
 (struct-out bo-active-tactical-plan)
 PRO-BO-TACTICAL-PHASE-PLANS
 pro-tactical-phases-for-matchup
 evaluate-build-order-tactical-plan

 ;; Decoupled 8-Stream Resource & Bank Manager + 200/200 Late-Game Max-Supply Manager
 DEC-GOAL-STREAMS
 (struct-out race-bank-target)
 (struct-out stream-budget-slice)
 (struct-out decoupled-bank-allocation)
 (struct-out max-supply-plan)
 compute-bank-targets
 allocate-decoupled-goal-streams
 decoupled-stream-can-spend?
 evaluate-max-supply-manager
 ;; Stage 1 Slice 1B: Build-Order Deviation, 4-Pillar Post-BO Goals & Tactical Extensions
 register-macro-world-state-extractor!
 compute-enemy-comp-attrs
 detect-build-order-deviation
 evaluate-post-bo-strategic-goals
 bo-active-tactical-plan-target-location
 bo-active-tactical-plan-micro-profile
 bo-active-tactical-plan-abort-condition
 bo-active-tactical-plan-strategic-goals
 evaluate-opponent-opportunity-cost-commitment
 evaluate-loss-recovery-macro-mode)

;; =============================================================================
;; 1. Build-Order Combinators & Locutus Worker Chaining
;; =============================================================================

(struct bo-node (kind op children grade) #:transparent)

(define (bo-step op [minerals 50] [gas 0] [supply 1] [cap 'One])
  (bo-node 'primitive op '()
           (sc-grade cap minerals gas supply 1 'fixated 'visible-only)))

(define (seq>> . nodes)
  (define valid (filter values nodes))
  (cond
    [(null? valid) (bo-node 'empty '(noop) '() grade-zero)]
    [(null? (cdr valid)) (car valid)]
    [else
     (define total-grade
       (foldl (lambda (n acc) (grade-seq acc (bo-node-grade n)))
              grade-zero
              valid))
     (bo-node 'seq '(seq) valid total-grade)]))

(define (par|| . nodes)
  (define valid (filter values nodes))
  (cond
    [(null? valid) (bo-node 'empty '(noop) '() grade-zero)]
    [(null? (cdr valid)) (car valid)]
    [else
     (define total-grade
       (foldl (lambda (n acc) (grade-par acc (bo-node-grade n)))
              grade-zero
              valid))
     (bo-node 'par '(par) valid total-grade)]))

(define (auto-supply race node)
  (define supply-bldg
    (case race
      [(Zerg zerg)       (bo-step '(train overlord) 100 0 0 'One)]
      [(Protoss protoss) (bo-step '(build pylon) 100 0 0 'One)]
      [(Terran terran)   (bo-step '(build supply-depot) 100 0 0 'One)]
      [else              (bo-step '(train overlord) 100 0 0 'One)]))
  (define g (bo-node-grade node))
  (if (> (sc-grade-supply g) 0)
      (seq>> supply-bldg node)
      node))

(define (saturate-bases race num-bases)
  (define worker-sym
    (case race
      [(Zerg zerg) 'drone]
      [(Protoss protoss) 'probe]
      [(Terran terran) 'scv]
      [else 'drone]))
  (define steps
    (for/list ([i (in-range (max 1 (* 3 num-bases)))])
      (bo-step (list 'train worker-sym) 50 0 1 'One)))
  (apply seq>> steps))

;; Locutus long-distance worker chaining: pre-move worker along waypoint chain
;; so it arrives at (x, y) on the exact frame minerals reach building cost.
(define (chain-worker>> worker-id waypoints build-op [minerals 300] [gas 0])
  (define move-steps
    (for/list ([wp (in-list waypoints)])
      (bo-step (list 'move-waypoint worker-id (car wp) (cdr wp)) 0 0 0 'Borrowed)))
  (define final-step
    (bo-step build-op minerals gas 0 'One))
  (apply seq>> (append move-steps (list final-step))))

(define (compile-build-order node)
  (match node
    [(bo-node 'empty _ _ _) '()]
    [(bo-node 'primitive op _ _) (list op)]
    [(bo-node (or 'seq 'par) _ children _)
     (append-map compile-build-order children)]
    [(? list? xs) xs]
    [_ (list node)]))

(define (build-order-grade node)
  (if (bo-node? node)
      (bo-node-grade node)
      (derive-grades-from-bot-ast node)))

;; =============================================================================
;; 2. McRave UCB1 Multi-Armed Bandit Strategy Selector
;; =============================================================================

(struct ucb1-arm (name wins plays) #:mutable #:transparent)
(struct ucb1-bandit (arms total-plays c) #:mutable #:transparent)

(define (make-ucb1-bandit arm-names [c 1.41421356])
  (ucb1-bandit
   (for/list ([name (in-list arm-names)])
     (ucb1-arm name 0.0 0))
   0
   c))

(define (ucb1-score arm total-plays [c 1.41421356])
  (define n (ucb1-arm-plays arm))
  (if (zero? n)
      +inf.0
      (+ (/ (ucb1-arm-wins arm) n)
         (* c (sqrt (/ (log (max 1 total-plays)) n))))))

(define (ucb1-select-arm bandit)
  (define tot (max 1 (ucb1-bandit-total-plays bandit)))
  (define c (ucb1-bandit-c bandit))
  (define best
    (argmax (lambda (arm) (ucb1-score arm tot c))
            (ucb1-bandit-arms bandit)))
  (ucb1-arm-name best))

(define (ucb1-update-arm! bandit arm-name reward)
  (for ([arm (in-list (ucb1-bandit-arms bandit))]
        #:when (eq? (ucb1-arm-name arm) arm-name))
    (set-ucb1-arm-wins! arm (+ (ucb1-arm-wins arm) reward))
    (set-ucb1-arm-plays! arm (add1 (ucb1-arm-plays arm))))
  (set-ucb1-bandit-total-plays! bandit (add1 (ucb1-bandit-total-plays bandit)))
  bandit)

;; =============================================================================
;; 3. BOSS Branch-and-Bound Goal Synthesis
;; (Shared `finite-real?`, `safe-real`, `safe-exact-int`, `safe-nonneg-int`,
;;  `safe-list` imported from `sc2-common.rkt`.)
;; =============================================================================

(struct boss-plan (race goal-units steps makespan-frames total-minerals total-gas)
  #:transparent)

(define (unit-prereq-building u)
  (case u
    [(zergling queen) 'spawning-pool]
    [(roach ravager) 'roach-warren]
    [(hydralisk lurker) 'hydralisk-den]
    [(mutalisk corruptor) 'spire]
    [(zealot adept) 'gateway]
    [(stalker sentry) 'cybernetics-core]
    [(immortal colossus disruptor observer warp-prism) 'robotics-facility]
    [(marine marauder reaper) 'barracks]
    [(siege-tank hellion widow-mine cyclone thor) 'factory]
    [(medivac viking liberator banshee raven) 'starport]
    [(ghost) 'ghost-academy]
    [else #f]))

(define (boss-synthesize-build-plan race goal-alist #:existing-buildings [existing '()])
  ;; goal-alist: list of `(cons unit-type count)`
  (define safe-goals (filter pair? (safe-list goal-alist)))
  (define safe-existing (safe-list existing))
  (define needed-prereqs
    (remove-duplicates
     (filter (lambda (b) (and b (not (memq b safe-existing))))
             (map (lambda (pair) (unit-prereq-building (car pair))) safe-goals))))
  (define prereq-steps
    (for/list ([b (in-list needed-prereqs)])
      (list 'build b)))
  (define unit-steps
    (append-map
     (lambda (pair)
       (make-list (safe-nonneg-int (cdr pair) 0) (list 'train (car pair))))
     safe-goals))
  (define all-steps (append prereq-steps unit-steps))
  (define g (derive-grades-from-bot-ast all-steps))
  ;; Makespan lower-bounded by prerequisite build frames + parallel production cycles
  (define makespan
    (+ (* 360 (length prereq-steps))
       (* 120 (length unit-steps))))
  (boss-plan race
             safe-goals
             all-steps
             makespan
             (sc-grade-minerals g)
             (sc-grade-gas g)))

;; =============================================================================
;; 4. Stardust HTN Plays (Hierarchical Task Network with Crisis Preemption)
;; =============================================================================

(struct htn-play (name priority status subtasks reserved-minerals reserved-gas)
  #:mutable
  #:transparent)

(define (make-htn-play name priority subtasks [minerals 0] [gas 0])
  (htn-play name priority 'active subtasks minerals gas))

(define (htn-decompose-play play world-state)
  (cond
    [(not (eq? (htn-play-status play) 'active)) '()]
    [else (htn-play-subtasks play)]))

(define (htn-preempt-play low-play crisis-play)
  (when (> (htn-play-priority crisis-play) (htn-play-priority low-play))
    (set-htn-play-status! low-play 'suspended)
    (set-htn-play-status! crisis-play 'active))
  (list crisis-play low-play))

;; =============================================================================
;; 5. Symbiotic Resource Ledger (Borrowing, Crisis Preemption & Exact Invariant)
;;    Invariant: Total == Available + Reserved + Borrowed - Repaid (or
;;               Total == Available + Reserved + ActiveBorrowed)
;; =============================================================================

(struct ledger-lease (id owner minerals gas supply priority status)
  #:mutable
  #:transparent)

(struct symbiotic-ledger
  (total-minerals
   total-gas
   total-supply
   reserved-minerals
   reserved-gas
   reserved-supply
   borrowed-minerals
   borrowed-gas
   borrowed-supply
   leases)
  #:mutable
  #:transparent)

(define safe-ledger-int safe-nonneg-int)

(define (make-symbiotic-ledger [minerals 500] [gas 200] [supply 10])
  (symbiotic-ledger (safe-ledger-int minerals 500)
                    (safe-ledger-int gas 200)
                    (safe-ledger-int supply 10)
                    0 0 0 0 0 0 '()))

(define (ledger-available-minerals l)
  (- (symbiotic-ledger-total-minerals l)
     (symbiotic-ledger-reserved-minerals l)
     (symbiotic-ledger-borrowed-minerals l)))

(define (ledger-available-gas l)
  (- (symbiotic-ledger-total-gas l)
     (symbiotic-ledger-reserved-gas l)
     (symbiotic-ledger-borrowed-gas l)))

(define (ledger-available-supply l)
  (- (symbiotic-ledger-total-supply l)
     (symbiotic-ledger-reserved-supply l)
     (symbiotic-ledger-borrowed-supply l)))

(define (ledger-verify-invariant? l)
  (and (= (symbiotic-ledger-total-minerals l)
          (+ (ledger-available-minerals l)
             (symbiotic-ledger-reserved-minerals l)
             (symbiotic-ledger-borrowed-minerals l)))
       (= (symbiotic-ledger-total-gas l)
          (+ (ledger-available-gas l)
             (symbiotic-ledger-reserved-gas l)
             (symbiotic-ledger-borrowed-gas l)))
       (= (symbiotic-ledger-total-supply l)
          (+ (ledger-available-supply l)
             (symbiotic-ledger-reserved-supply l)
             (symbiotic-ledger-borrowed-supply l)))
       (>= (ledger-available-minerals l) 0)
       (>= (ledger-available-gas l) 0)
       (>= (ledger-available-supply l) 0)))

(define (ledger-reserve! l lease-id owner raw-m raw-g raw-s [raw-priority 1])
  (define m (safe-ledger-int raw-m 0))
  (define g (safe-ledger-int raw-g 0))
  (define s (safe-ledger-int raw-s 0))
  (define priority (safe-ledger-int raw-priority 1))
  (when (or (< (ledger-available-minerals l) m)
            (< (ledger-available-gas l) g)
            (< (ledger-available-supply l) s))
    (error 'ledger-reserve! "Insufficient unreserved resources in symbiotic ledger"))
  (define lease (ledger-lease lease-id owner m g s priority 'reserved))
  (set-symbiotic-ledger-reserved-minerals! l (+ (symbiotic-ledger-reserved-minerals l) m))
  (set-symbiotic-ledger-reserved-gas! l (+ (symbiotic-ledger-reserved-gas l) g))
  (set-symbiotic-ledger-reserved-supply! l (+ (symbiotic-ledger-reserved-supply l) s))
  (set-symbiotic-ledger-leases! l (cons lease (symbiotic-ledger-leases l)))
  lease)

;; Symbiotic borrowing: borrow from an idle low-priority reservation without violating total accounting
(define (ledger-borrow! l borrower-id raw-m raw-g raw-s [raw-priority 5])
  (define m (safe-ledger-int raw-m 0))
  (define g (safe-ledger-int raw-g 0))
  (define s (safe-ledger-int raw-s 0))
  (define priority (safe-ledger-int raw-priority 5))
  (cond
    [(and (>= (ledger-available-minerals l) m)
          (>= (ledger-available-gas l) g)
          (>= (ledger-available-supply l) s))
     (set-symbiotic-ledger-borrowed-minerals! l (+ (symbiotic-ledger-borrowed-minerals l) m))
     (set-symbiotic-ledger-borrowed-gas! l (+ (symbiotic-ledger-borrowed-gas l) g))
     (set-symbiotic-ledger-borrowed-supply! l (+ (symbiotic-ledger-borrowed-supply l) s))
     (define lease (ledger-lease borrower-id borrower-id m g s priority 'borrowed))
     (set-symbiotic-ledger-leases! l (cons lease (symbiotic-ledger-leases l)))
     lease]
    [else
     ;; Preempt/borrow from lower-priority reserved leases
     (ledger-preempt-for-crisis! l borrower-id m g s priority)]))

(define (ledger-preempt-for-crisis! l crisis-id raw-m raw-g raw-s [raw-priority 10])
  (define m (safe-ledger-int raw-m 0))
  (define g (safe-ledger-int raw-g 0))
  (define s (safe-ledger-int raw-s 0))
  (define priority (safe-ledger-int raw-priority 10))
  ;; Release lower-priority reserved leases until (m, g, s) can be allocated to crisis-id
  (for ([lease (in-list (symbiotic-ledger-leases l))]
        #:when (and (eq? (ledger-lease-status lease) 'reserved)
                    (< (ledger-lease-priority lease) priority)
                    (or (< (ledger-available-minerals l) m)
                        (< (ledger-available-gas l) g)
                        (< (ledger-available-supply l) s))))
    (set-ledger-lease-status! lease 'preempted)
    (set-symbiotic-ledger-reserved-minerals!
     l (- (symbiotic-ledger-reserved-minerals l) (ledger-lease-minerals lease)))
    (set-symbiotic-ledger-reserved-gas!
     l (- (symbiotic-ledger-reserved-gas l) (ledger-lease-gas lease)))
    (set-symbiotic-ledger-reserved-supply!
     l (- (symbiotic-ledger-reserved-supply l) (ledger-lease-supply lease))))
  (when (or (< (ledger-available-minerals l) m)
            (< (ledger-available-gas l) g)
            (< (ledger-available-supply l) s))
    (error 'ledger-preempt-for-crisis! "Even after preemption, insufficient resources for crisis"))
  (set-symbiotic-ledger-borrowed-minerals! l (+ (symbiotic-ledger-borrowed-minerals l) m))
  (set-symbiotic-ledger-borrowed-gas! l (+ (symbiotic-ledger-borrowed-gas l) g))
  (set-symbiotic-ledger-borrowed-supply! l (+ (symbiotic-ledger-borrowed-supply l) s))
  (define crisis-lease (ledger-lease crisis-id crisis-id m g s priority 'borrowed))
  (set-symbiotic-ledger-leases! l (cons crisis-lease (symbiotic-ledger-leases l)))
  crisis-lease)

(define (ledger-repay! l lease-id)
  (for ([lease (in-list (symbiotic-ledger-leases l))]
        #:when (and (eq? (ledger-lease-id lease) lease-id)
                    (eq? (ledger-lease-status lease) 'borrowed)))
    (set-ledger-lease-status! lease 'repaid)
    (set-symbiotic-ledger-borrowed-minerals!
     l (- (symbiotic-ledger-borrowed-minerals l) (ledger-lease-minerals lease)))
    (set-symbiotic-ledger-borrowed-gas!
     l (- (symbiotic-ledger-borrowed-gas l) (ledger-lease-gas lease)))
    (set-symbiotic-ledger-borrowed-supply!
     l (- (symbiotic-ledger-borrowed-supply l) (ledger-lease-supply lease))))
  l)

(define (ledger-commit! l lease-id)
  (for ([lease (in-list (symbiotic-ledger-leases l))]
        #:when (and (eq? (ledger-lease-id lease) lease-id)
                    (memq (ledger-lease-status lease) '(reserved borrowed))))
    (define m (ledger-lease-minerals lease))
    (define g (ledger-lease-gas lease))
    (define s (ledger-lease-supply lease))
    (if (eq? (ledger-lease-status lease) 'reserved)
        (begin
          (set-symbiotic-ledger-reserved-minerals! l (- (symbiotic-ledger-reserved-minerals l) m))
          (set-symbiotic-ledger-reserved-gas! l (- (symbiotic-ledger-reserved-gas l) g))
          (set-symbiotic-ledger-reserved-supply! l (- (symbiotic-ledger-reserved-supply l) s)))
        (begin
          (set-symbiotic-ledger-borrowed-minerals! l (- (symbiotic-ledger-borrowed-minerals l) m))
          (set-symbiotic-ledger-borrowed-gas! l (- (symbiotic-ledger-borrowed-gas l) g))
          (set-symbiotic-ledger-borrowed-supply! l (- (symbiotic-ledger-borrowed-supply l) s))))
    (set-symbiotic-ledger-total-minerals! l (- (symbiotic-ledger-total-minerals l) m))
    (set-symbiotic-ledger-total-gas! l (- (symbiotic-ledger-total-gas l) g))
    (set-symbiotic-ledger-total-supply! l (- (symbiotic-ledger-total-supply l) s))
    (set-ledger-lease-status! lease 'committed))
  l)

;; =============================================================================
;; 6. Coupled Depletion-Driven Macro & Map-Wide Expansion Governor
;;    (`coupled-macro-plan`, `evaluate-coupled-macro-governor`)
;; =============================================================================

(struct coupled-macro-plan
  (active-bases
   depleting-bases
   healthy-bases
   desired-bases
   target-workers
   should-expand?
   expansion-reason
   escrow-minerals
   unreserved-minerals
   unreserved-gas
   idle-worker-production-slots
   idle-unit-production-slots
   zero-unused-production?)
  #:transparent)

(define (evaluate-coupled-macro-governor
         #:race [race 'Zerg]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 200]
         #:gas [raw-gas 100]
         #:supply-left [raw-supply-left 4]
         #:active-bases [raw-active-bases 1]
         #:depleting-bases [raw-depleting-bases 0]
         #:workers [raw-workers 12]
         #:pending-workers [raw-pending-workers 0]
         #:mineral-harvesters [raw-mineral-harvesters #f]
         #:ideal-mineral-harvesters [raw-ideal-mineral-harvesters #f]
         #:gas-harvesters [raw-gas-harvesters #f]
         #:ideal-gas-harvesters [raw-ideal-gas-harvesters #f]
         #:production-facilities [raw-production-facilities 1]
         #:busy-facilities [raw-busy-facilities 0]
         #:busy-townhalls [raw-busy-townhalls 0]
         #:under-crisis? [under-crisis? #f]
         #:recommended-min-bases [raw-recommended-min-bases 1]
         #:max-map-bases [raw-max-map-bases 16])
  (define frame (safe-nonneg-int raw-frame 0))
  (define minerals (safe-nonneg-int raw-minerals 0))
  (define gas (safe-nonneg-int raw-gas 0))
  (define supply-left (safe-exact-int raw-supply-left 0))
  (define active-bases (safe-nonneg-int raw-active-bases 1))
  (define depleting-bases (safe-nonneg-int raw-depleting-bases 0))
  (define workers (safe-nonneg-int raw-workers 12))
  (define pending-workers (safe-nonneg-int raw-pending-workers 0))
  (define production-facilities (max 1 (safe-nonneg-int raw-production-facilities 1)))
  (define busy-facilities (safe-nonneg-int raw-busy-facilities 0))
  (define busy-townhalls (safe-nonneg-int raw-busy-townhalls 0))
  (define recommended-min-bases (max 1 (safe-nonneg-int raw-recommended-min-bases 1)))
  (define max-map-bases (max 1 (safe-nonneg-int raw-max-map-bases 16)))

  (define eff-bases (max 1 active-bases))
  (define healthy-bases (max 0 (- eff-bases depleting-bases)))
  (define total-workers (+ workers pending-workers))
  (define base-cost (if (memq race '(Zerg zerg)) 300 400))

  ;; Live mineral & gas harvester saturation check (replaces hard 36/50 worker cutoffs
  ;; whenever live harvester assignment/capacity telemetry is supplied).
  (define explicit-harvester-telemetry?
    (or (not (eq? raw-mineral-harvesters #f))
        (not (eq? raw-ideal-mineral-harvesters #f))
        (not (eq? raw-gas-harvesters #f))
        (not (eq? raw-ideal-gas-harvesters #f))))
  (define ideal-min-h
    (if (not (eq? raw-ideal-mineral-harvesters #f))
        (safe-nonneg-int raw-ideal-mineral-harvesters (* 16 (max 1 healthy-bases)))
        (* 16 (max 1 healthy-bases))))
  (define cur-min-h
    (if (not (eq? raw-mineral-harvesters #f))
        (safe-nonneg-int raw-mineral-harvesters (max 0 (- total-workers (* 3 (max 1 healthy-bases)))))
        (max 0 (- total-workers (* 3 (max 1 healthy-bases))))))
  (define ideal-gas-h
    (if (not (eq? raw-ideal-gas-harvesters #f))
        (safe-nonneg-int raw-ideal-gas-harvesters (* 3 (max 1 healthy-bases)))
        (* 3 (max 1 healthy-bases))))
  (define cur-gas-h
    (if (not (eq? raw-gas-harvesters #f))
        (safe-nonneg-int raw-gas-harvesters (* 3 (max 1 healthy-bases)))
        (* 3 (max 1 healthy-bases))))
  (define mineral-saturated?
    (and (> ideal-min-h 0)
         (>= cur-min-h (max 1 (- ideal-min-h 2)))))
  (define gas-saturated?
    (or (<= ideal-gas-h 0)
        (>= cur-gas-h (max 1 (- ideal-gas-h 1)))))
  (define harvesters-saturated?
    (if explicit-harvester-telemetry?
        (and mineral-saturated? gas-saturated?)
        (>= total-workers (* 18 (max 1 healthy-bases)))))

  ;; Unconstrained map-wide expansion target: scales up to max-map-bases (default 16)
  ;; whenever mineral+gas harvesters saturate healthy bases, bases deplete, minerals float,
  ;; or Mirror-Mind recommends out-expanding the opponent.
  (define raw-time-bases (add1 (quotient (max 0 frame) 1600)))
  (define time-bases
    (if (< total-workers (* 14 (max 1 healthy-bases)))
        (min raw-time-bases (+ eff-bases 1))
        raw-time-bases))
  (define saturation-bases
    (if harvesters-saturated?
        (+ eff-bases (max 1 depleting-bases))
        eff-bases))
  (define float-bases
    (if (>= minerals (* 2 base-cost))
        (+ eff-bases (quotient minerals (* 2 base-cost)))
        eff-bases))
  (define depletion-replacement-bases
    (+ eff-bases depleting-bases))

  (define desired-bases
    (min max-map-bases
         (max eff-bases
              recommended-min-bases
              depletion-replacement-bases
              saturation-bases
              float-bases
              time-bases)))

  (define should-expand?
    (and (not under-crisis?)
         (or (> depleting-bases 0)
             (> desired-bases eff-bases))))

  ;; Target workers coupled to healthy + desired bases (22 per active/desired base, up to 84),
  ;; capped to healthy bases (+1 if expanding) when depleted bases exist so mined-out bases don't inflate targets.
  (define raw-target-workers
    (min 84 (max 22 (* 22 (min 5 (max healthy-bases desired-bases))))))
  (define target-workers
    (if (< healthy-bases eff-bases)
        (min raw-target-workers
             (min 84 (* 22 (min 5 (max 1 (+ healthy-bases (if should-expand? 1 0)))))))
        raw-target-workers))

  (define expansion-reason
    (cond
      [under-crisis?                           'crisis-hold-expansion]
      [(> depleting-bases 0)                   'depletion-replacement-expand]
      [harvesters-saturated?                   'macro-saturation-expand]
      [(> recommended-min-bases eff-bases)     'mirror-macro-directive-expand]
      [(> float-bases eff-bases)               'mineral-float-macro-expand]
      [(> desired-bases eff-bases)             'map-wide-time-expand]
      [else                                    'bases-satisfied]))

  ;; Expansion escrow: reserve TownHall cost when expansion is scheduled
  (define escrow-minerals
    (if should-expand? base-cost 0))
  (define unreserved-minerals
    (max 0 (- minerals escrow-minerals)))
  (define unreserved-gas
    (max 0 gas))

  ;; Zero-Unused-Production Invariant: compute idle worker & unit production slots
  (define idle-worker-slots
    (if (and (< total-workers target-workers) (> supply-left 0))
        (max 0 (- eff-bases busy-townhalls))
        0))
  (define idle-unit-slots
    (if (> supply-left 0)
        (max 0 (- production-facilities busy-facilities))
        0))
  (define zero-unused?
    (and (zero? idle-worker-slots)
         (zero? idle-unit-slots)))

  (coupled-macro-plan eff-bases
                      depleting-bases
                      healthy-bases
                      desired-bases
                      target-workers
                      should-expand?
                      expansion-reason
                      escrow-minerals
                      unreserved-minerals
                      unreserved-gas
                      idle-worker-slots
                      idle-unit-slots
                      zero-unused?))

;; =============================================================================
;; 7. Planned & Adaptive Build-Order & Tech/Upgrade Goal Planner
;;    (`build-goal-stage`, `adaptive-tech-plan`, `evaluate-adaptive-build-and-tech-plan`)
;; =============================================================================

(struct build-goal-stage
  (stage-name              ; symbol: 'opening-eco-foundation | 'core-synergy-online | 'midgame-counter-tech | 'lategame-tier3-siege
   required-buildings      ; list of symbols
   required-upgrades       ; list of symbols
   core-synergy-invariants ; list of symbols ("what makes the build work")
   stage-satisfied?)       ; boolean
  #:transparent)

(struct adaptive-tech-plan
  (race                     ; 'Zerg | 'Terran | 'Protoss
   build-name               ; symbol
   current-stage            ; symbol
   stages                   ; list of build-goal-stage
   synergy-invariants       ; list of symbols ("what makes the build work")
   missing-synergy-reqs     ; list of symbols
   counter-tech-buildings   ; list of symbols adapted to opponent archetype / Mirror-Mind
   priority-upgrades        ; list of symbols
   priority-morphs          ; list of symbols
   desired-unit-mix         ; alist of (cons unit-sym weight)
   target-gas-mineral-ratio ; flonum: rho^*_{G/M}(t)
   next-actions)            ; list of S-expression commands
  #:transparent)

(define (classify-threat-family enemy-archetype mirror-predicted-unit)
  (cond
    [(or (memq enemy-archetype '(sky-toss muta-flock))
         (memq mirror-predicted-unit
               '(void-ray carrier tempest oracle phoenix mutalisk corruptor
                 brood-lord banshee battlecruiser liberator)))
     'air-fleet]
    [(or (memq enemy-archetype '(mech-siege stalker-colossus roach-ravager lurker-contain))
         (memq mirror-predicted-unit
               '(siege-tank siege-tank-sieged thor cyclone immortal colossus
                 disruptor roach ravager lurker ultralisk)))
     'armored-mech-siege]
    [else
     'bio-swarm-light]))

(define (evaluate-adaptive-build-and-tech-plan
         race
         #:ally-buildings [raw-ally-buildings '()]
         #:ally-units [raw-ally-units '()]
         #:researched-upgrades [raw-researched-upgrades '()]
         #:enemy-archetype [enemy-archetype 'standard-macro]
         #:mirror-predicted-unit [mirror-predicted-unit 'marine]
         #:mirror-macro-verdict [mirror-macro-verdict 'pace-Macro-And-Disrupt]
         #:requires-detection? [requires-detection? #f]
         #:requires-anti-air? [requires-anti-air? #f]
         #:enemy-upgrade-advantage [raw-enemy-upgrade-advantage 0]
         #:minerals [raw-minerals 300]
         #:gas [raw-gas 150])
  (define ally-buildings (safe-list raw-ally-buildings))
  (define ally-units (safe-list raw-ally-units))
  (define researched-upgrades (safe-list raw-researched-upgrades))
  (define enemy-upgrade-advantage (safe-exact-int raw-enemy-upgrade-advantage 0))
  (define minerals (safe-nonneg-int raw-minerals 300))
  (define gas (safe-nonneg-int raw-gas 150))
  (define norm-race
    (case race
      [(Zerg zerg) 'Zerg]
      [(Terran terran) 'Terran]
      [(Protoss protoss) 'Protoss]
      [else 'Zerg]))
  (define threat-family
    (if requires-anti-air?
        'air-fleet
        (classify-threat-family enemy-archetype mirror-predicted-unit)))
  (define (upgrade-aliases u)
    (case u
      [(zergling-movementspeed metabolic-boost)
       '(zergling-movementspeed metabolic-boost)]
      [(missile-attacks-1 zerg-missile-weapons-1)
       '(missile-attacks-1 zerg-missile-weapons-1)]
      [(ground-carapace-1 zerg-ground-armor-1 zerg-ground-carapace-1)
       '(ground-carapace-1 zerg-ground-armor-1 zerg-ground-carapace-1)]
      [(melee-attacks-1 zerg-melee-weapons-1)
       '(melee-attacks-1 zerg-melee-weapons-1)]
      [(centrifical-hooks centrifugal-hooks)
       '(centrifical-hooks centrifugal-hooks)]
      [(infantry-weapons-1 terran-infantry-weapons-1)
       '(infantry-weapons-1 terran-infantry-weapons-1)]
      [(infantry-armor-1 terran-infantry-armor-1)
       '(infantry-armor-1 terran-infantry-armor-1)]
      [(vehicle-weapons-1 terran-vehicle-weapons-1)
       '(vehicle-weapons-1 terran-vehicle-weapons-1)]
      [(infernal-pre-igniter infernal-preigniter)
       '(infernal-pre-igniter infernal-preigniter)]
      [(ground-weapons-1 protoss-ground-weapons-1)
       '(ground-weapons-1 protoss-ground-weapons-1)]
      [(ground-armor-1 protoss-ground-armor-1)
       '(ground-armor-1 protoss-ground-armor-1)]
      [(warp-gate-research warpgate)
       '(warp-gate-research warpgate)]
      [else (list u)]))
  (define (have-up? u pool)
    (ormap (lambda (a) (not (not (memq a pool)))) (upgrade-aliases u)))
  (define (have-bldg? b pool)
    (or (not (not (memq b pool)))
        (ormap (lambda (s) (sc2-structure-matches-target? s b #f)) pool)))
  (define (have-item? x pool)
    (or (have-up? x pool)
        (have-bldg? x pool)
        (ormap (lambda (u) (not (not (memq u pool)))) (sc2-unit-equivalent-syms x))))
  (define (have-all? reqs pool)
    (andmap (lambda (r) (have-item? r pool)) reqs))

  (case norm-race
    [(Zerg)
     ;; Core Zerg Synergy ("What makes Roach/Hydra/Ling/Bane/Lurker work"):
     ;; Metabolic Boost (zergling-movementspeed) + Burrow + Lair + Glial Reconstitution
     ;; + Grooved Spines + +1/+1 Missile/Carapace
     (define synergy-invariants
       '(zergling-movementspeed burrow lair glial-reconstitution
         grooved-spines missile-attacks-1 ground-carapace-1))
     (define st1-b '(hatchery spawning-pool extractor))
     (define st1-u '(zergling-movementspeed))
     (define s1-ok? (and (have-all? st1-b ally-buildings) (have-all? st1-u researched-upgrades)))
     (define zerg-hive-t3-ready?
       (and (have-bldg? 'hive ally-buildings)
            (or (have-bldg? 'ultralisk-cavern ally-buildings)
                (have-bldg? 'greater-spire ally-buildings))))
     (define zerg-lair-priority-ok?
       (or (have-bldg? 'lair ally-buildings)
           (have-bldg? 'hive ally-buildings)
           requires-anti-air?
           requires-detection?
           (>= gas 200)
           (and s1-ok?
                (or (null? ally-units)
                    (have-item? 'queen ally-units)))))
     (define (filter-premature-lair syms)
       (if zerg-lair-priority-ok?
           syms
           (filter (lambda (s) (not (eq? s 'lair))) syms)))
     (define (filter-t3-obsolete-zerg-bldg s)
       (not (and zerg-hive-t3-ready?
                 (memq s '(lair roach-warren baneling-nest))
                 (not (have-bldg? s ally-buildings)))))
     (define base-counter-tech
      (case threat-family
         [(air-fleet)          '(lair spire hydralisk-den spore-crawler)]
         [(armored-mech-siege) '(lair roach-warren hydralisk-den lurker-den spire)]
         [else                 '(lair baneling-nest roach-warren infestation-pit ultralisk-cavern)]))
     (define counter-tech
       (filter filter-t3-obsolete-zerg-bldg
               (filter-premature-lair
                (remove-duplicates
                 (append (if requires-detection? '(spore-crawler lair) '())
                         base-counter-tech)))))
     (define raw-prio-upgrades
       (case threat-family
         [(air-fleet)
          '(zergling-movementspeed burrow grooved-spines muscular-augments missile-attacks-1 ground-carapace-1)]
         [(armored-mech-siege)
          '(zergling-movementspeed burrow glial-reconstitution grooved-spines adaptive-talons missile-attacks-1 ground-carapace-1)]
         [else
          '(zergling-movementspeed burrow centrifical-hooks glial-reconstitution chitinous-plating missile-attacks-1 ground-carapace-1)]))
     (define prio-upgrades
       (if zerg-hive-t3-ready?
           (filter (lambda (u)
                     (not (or (eq? u 'burrow)
                              (and (memq u '(glial-reconstitution tunneling-claws))
                                   (not (have-bldg? 'roach-warren ally-buildings)))
                              (and (eq? u 'centrifical-hooks)
                                   (not (have-bldg? 'baneling-nest ally-buildings)))
                              (and (memq u '(missile-attacks-1 ground-carapace-1 melee-attacks-1))
                                   (not (have-bldg? 'evolution-chamber ally-buildings))))))
                   raw-prio-upgrades)
           raw-prio-upgrades))
     (define base-prio-morphs
       (if zerg-hive-t3-ready?
           (append
            (if (have-bldg? 'greater-spire ally-buildings) '(brood-lord) '())
            (if (have-bldg? 'ultralisk-cavern ally-buildings) '(ultralisk) '())
            '(viper)
            (if (have-bldg? 'infestation-pit ally-buildings) '(infestor) '())
            (if (have-bldg? 'hydralisk-den ally-buildings) '(lurker) '()))
           (case threat-family
             [(air-fleet)          '(lair overseer hive)]
             [(armored-mech-siege) '(lair ravager lurker brood-lord hive)]
             [else                 '(lair baneling ravager overseer hive)])))
     (define prio-morphs
       (filter-premature-lair
        (remove-duplicates
         (append (if requires-detection? '(overseer) '())
                 base-prio-morphs))))
     (define unit-mix
       (if zerg-hive-t3-ready?
           '((ultralisk . 0.35) (brood-lord . 0.30) (viper . 0.20) (hydralisk . 0.15))
           (case threat-family
             [(air-fleet)          '((corruptor . 0.45) (hydralisk . 0.40) (queen . 0.15))]
             [(armored-mech-siege) '((ravager . 0.35) (lurker . 0.35) (brood-lord . 0.15) (roach . 0.15))]
             [else                 '((baneling . 0.35) (zergling . 0.30) (roach . 0.20) (ultralisk . 0.15))])))
     (define target-gm-ratio
       (case threat-family
         [(air-fleet)          0.62]
         [(armored-mech-siege) 0.58]
         [else                 0.42]))

     (define st2-b '(roach-warren lair evolution-chamber))
     (define st2-u '(burrow glial-reconstitution missile-attacks-1 ground-carapace-1))
     (define st3-b counter-tech)
     (define st3-u '(grooved-spines))
     (define st4-b '(hive ultralisk-cavern greater-spire))
     (define st4-u '(chitinous-plating zergling-attackspeed))

     (define s2-ok? (and s1-ok? (have-all? st2-b ally-buildings) (have-all? st2-u researched-upgrades)))
     (define s3-ok? (and s2-ok? (have-all? st3-b ally-buildings) (have-all? st3-u researched-upgrades)))
     (define s4-ok? (and s3-ok? (have-all? st4-b ally-buildings)))

     (define stages
       (list (build-goal-stage 'opening-eco-foundation st1-b st1-u '(zergling-movementspeed queen-inject) s1-ok?)
             (build-goal-stage 'core-synergy-online st2-b st2-u synergy-invariants s2-ok?)
             (build-goal-stage 'midgame-counter-tech st3-b st3-u counter-tech s3-ok?)
             (build-goal-stage 'lategame-tier3-siege st4-b st4-u '(hive brood-lord ultralisk) s4-ok?)))
     (define cur-stage
       (cond [(not s1-ok?) 'opening-eco-foundation]
             [(not s2-ok?) 'core-synergy-online]
             [(not s3-ok?) 'midgame-counter-tech]
             [else         'lategame-tier3-siege]))
     (define known-all (append ally-buildings ally-units researched-upgrades))
     (define missing-synergy
       (filter (lambda (x) (not (have-item? x known-all))) synergy-invariants))
     (define missing-bldgs
       (filter (lambda (b) (not (have-bldg? b ally-buildings)))
               (remove-duplicates (append st1-b st2-b counter-tech))))
     (define missing-upgs
       (filter (lambda (u) (not (have-up? u researched-upgrades))) prio-upgrades))
     (define next-acts
       (append
        (for/list ([b (in-list (take missing-bldgs (min 2 (length missing-bldgs))))])
          (if (memq b '(lair hive greater-spire))
              (list 'morph b)
              (list 'build b)))
        (for/list ([u (in-list (take missing-upgs (min 2 (length missing-upgs))))])
          (list 'research u))
        (list (list 'train (caar unit-mix)))))
     (adaptive-tech-plan 'Zerg
                         'Zerg-RoachHydraLurker-AdaptiveSwarm
                         cur-stage
                         stages
                         synergy-invariants
                         missing-synergy
                         counter-tech
                         prio-upgrades
                         prio-morphs
                         unit-mix
                         target-gm-ratio
                         next-acts)]

    [(Terran)
     ;; Core Terran Synergy ("What makes Bio/Tank/Medivac work"):
     ;; Stimpack + Combat Shield + Concussive Shells + Medivacs + +1/+1 Infantry (Siege Tanks start with LotV Siege Mode!)
     (define synergy-invariants
       '(stimpack combat-shield concussive-shells medivac
         infantry-weapons-1 infantry-armor-1))
     (define base-counter-tech
       (case threat-family
         [(air-fleet)          '(starport armory engineering-bay missile-turret)]
         [(armored-mech-siege) '(barracks-techlab factory factory-techlab starport)]
         [else                 '(factory barracks-reactor starport armory)]))
     (define counter-tech
       (remove-duplicates
        (append (if requires-detection? '(engineering-bay missile-turret starport-techlab) '())
                base-counter-tech)))
     (define prio-upgrades
       (case threat-family
         [(air-fleet)
          '(stimpack combat-shield infantry-weapons-1 infantry-armor-1 vehicle-weapons-1)]
         [(armored-mech-siege)
          '(stimpack combat-shield concussive-shells drilling-claws infantry-weapons-1 infantry-armor-1)]
         [else
          '(stimpack combat-shield infernal-pre-igniter infantry-weapons-1 infantry-armor-1)]))
     (define prio-morphs
       '(orbital-command hellbat planetary-fortress))
     (define unit-mix
       (case threat-family
         [(air-fleet)          '((viking . 0.45) (thor . 0.30) (marine . 0.25))]
         [(armored-mech-siege) '((marauder . 0.40) (siege-tank . 0.35) (medivac . 0.15) (liberator . 0.10))]
         [else                 '((widow-mine . 0.25) (hellbat . 0.25) (siege-tank . 0.20) (marine . 0.20) (medivac . 0.10))]))
     (define target-gm-ratio
       (case threat-family
         [(air-fleet)          0.55]
         [(armored-mech-siege) 0.52]
         [else                 0.38]))

     (define st1-b '(command-center supply-depot barracks refinery))
     (define st1-u '(stimpack))
     (define st2-b '(barracks-techlab factory starport engineering-bay))
     (define st2-u '(combat-shield concussive-shells infantry-weapons-1 infantry-armor-1))
     (define st3-b counter-tech)
     (define st3-u '(drilling-claws))
     (define st4-b '(armory ghost-academy fusion-core))
     (define st4-u '(vehicle-weapons-1))

     (define s1-ok? (and (have-all? st1-b ally-buildings) (have-all? st1-u researched-upgrades)))
     (define s2-ok? (and s1-ok? (have-all? st2-b ally-buildings) (have-all? st2-u researched-upgrades)))
     (define s3-ok? (and s2-ok? (have-all? st3-b ally-buildings)))
     (define s4-ok? (and s3-ok? (have-all? st4-b ally-buildings)))

     (define stages
       (list (build-goal-stage 'opening-eco-foundation st1-b st1-u '(orbital-command stimpack) s1-ok?)
             (build-goal-stage 'core-synergy-online st2-b st2-u synergy-invariants s2-ok?)
             (build-goal-stage 'midgame-counter-tech st3-b st3-u counter-tech s3-ok?)
             (build-goal-stage 'lategame-tier3-siege st4-b st4-u '(thor ghost battlecruiser) s4-ok?)))
     (define cur-stage
       (cond [(not s1-ok?) 'opening-eco-foundation]
             [(not s2-ok?) 'core-synergy-online]
             [(not s3-ok?) 'midgame-counter-tech]
             [else         'lategame-tier3-siege]))
     (define known-all (append ally-buildings ally-units researched-upgrades))
     (define missing-synergy
       (filter (lambda (x) (not (have-item? x known-all))) synergy-invariants))
     (define missing-bldgs
       (filter (lambda (b) (not (have-bldg? b ally-buildings)))
               (remove-duplicates (append st1-b st2-b counter-tech))))
     (define missing-upgs
       (filter (lambda (u) (not (have-up? u researched-upgrades))) prio-upgrades))
     (define next-acts
       (append
        (for/list ([b (in-list (take missing-bldgs (min 2 (length missing-bldgs))))])
          (list 'build b))
        (for/list ([u (in-list (take missing-upgs (min 2 (length missing-upgs))))])
          (list 'research u))
        (list (list 'train (caar unit-mix)))))
     (adaptive-tech-plan 'Terran
                         'Terran-BioTankMedivac-AdaptiveTempo
                         cur-stage
                         stages
                         synergy-invariants
                         missing-synergy
                         counter-tech
                         prio-upgrades
                         prio-morphs
                         unit-mix
                         target-gm-ratio
                         next-acts)]

    [(Protoss)
     ;; Core Protoss Synergy ("What makes Gateway/Robo/Twilight work"):
     ;; WarpGate + Cybernetics Core + Immortal + Charge + Blink + +1/+1 Ground
     (define synergy-invariants
       '(warp-gate-research cybernetics-core immortal charge blink
         ground-weapons-1 ground-armor-1))
     (define base-counter-tech
       (case threat-family
         [(air-fleet)          '(cybernetics-core stargate fleet-beacon twilight-council)]
         [(armored-mech-siege) '(robotics-facility robotics-bay twilight-council)]
         [else                 '(robotics-facility robotics-bay twilight-council templar-archives)]))
     (define counter-tech
       (remove-duplicates
        (append (if requires-detection? '(forge photon-cannon robotics-facility) '())
                base-counter-tech)))
     (define prio-upgrades
       (case threat-family
         [(air-fleet)
          '(warp-gate-research blink psi-storm ground-weapons-1 ground-armor-1)]
         [(armored-mech-siege)
          '(warp-gate-research charge extended-thermal-lance ground-weapons-1 ground-armor-1)]
         [else
          '(warp-gate-research charge extended-thermal-lance psi-storm ground-weapons-1 ground-armor-1)]))
     (define prio-morphs
       '(warp-gate archon))
     (define unit-mix
       (case threat-family
         [(air-fleet)          '((tempest . 0.45) (void-ray . 0.30) (stalker . 0.25))]
         [(armored-mech-siege) '((immortal . 0.45) (colossus . 0.25) (zealot . 0.20) (archon . 0.10))]
         [else                 '((colossus . 0.35) (archon . 0.25) (high-templar . 0.15) (zealot . 0.25))]))
     (define target-gm-ratio
       (case threat-family
         [(air-fleet)          0.58]
         [(armored-mech-siege) 0.50]
         [else                 0.56]))

     (define st1-b '(nexus pylon gateway cybernetics-core assimilator))
     (define st1-u '(warp-gate-research))
     (define st2-b '(robotics-facility twilight-council forge))
     (define st2-u '(charge blink ground-weapons-1 ground-armor-1))
     (define st3-b counter-tech)
     (define st3-u '(extended-thermal-lance))
     (define st4-b '(templar-archives fleet-beacon))
     (define st4-u '(psi-storm))

     (define s1-ok? (and (have-all? st1-b ally-buildings) (have-all? st1-u researched-upgrades)))
     (define s2-ok? (and s1-ok? (have-all? st2-b ally-buildings) (have-all? st2-u researched-upgrades)))
     (define s3-ok? (and s2-ok? (have-all? st3-b ally-buildings)))
     (define s4-ok? (and s3-ok? (have-all? st4-b ally-buildings)))

     (define stages
       (list (build-goal-stage 'opening-eco-foundation st1-b st1-u '(warp-gate-research cybernetics-core) s1-ok?)
             (build-goal-stage 'core-synergy-online st2-b st2-u synergy-invariants s2-ok?)
             (build-goal-stage 'midgame-counter-tech st3-b st3-u counter-tech s3-ok?)
             (build-goal-stage 'lategame-tier3-siege st4-b st4-u '(archon colossus carrier) s4-ok?)))
     (define cur-stage
       (cond [(not s1-ok?) 'opening-eco-foundation]
             [(not s2-ok?) 'core-synergy-online]
             [(not s3-ok?) 'midgame-counter-tech]
             [else         'lategame-tier3-siege]))
     (define known-all (append ally-buildings ally-units researched-upgrades))
     (define missing-synergy
       (filter (lambda (x) (not (have-item? x known-all))) synergy-invariants))
     (define missing-bldgs
       (filter (lambda (b) (not (have-bldg? b ally-buildings)))
               (remove-duplicates (append st1-b st2-b counter-tech))))
     (define missing-upgs
       (filter (lambda (u) (not (have-up? u researched-upgrades))) prio-upgrades))
     (define next-acts
       (append
        (for/list ([b (in-list (take missing-bldgs (min 2 (length missing-bldgs))))])
          (list 'build b))
        (for/list ([u (in-list (take missing-upgs (min 2 (length missing-upgs))))])
          (list 'research u))
        (list (list 'train (caar unit-mix)))))
     (adaptive-tech-plan 'Protoss
                         'Protoss-GateRoboTwilight-AdaptiveArmada
                         cur-stage
                         stages
                         synergy-invariants
                         missing-synergy
                         counter-tech
                         prio-upgrades
                         prio-morphs
                         unit-mix
                         target-gm-ratio
                         next-acts)]))

;; =============================================================================
;; 8. Guns-vs-Butter Production Possibility Frontier (PPF) & Dynamic
;;    Gas-to-Mineral Worker Allocation Controller
;;    (`gas-worker-allocation`, `compute-optimal-gas-workers`,
;;     `guns-vs-butter-ppf`, `evaluate-guns-vs-butter-ppf`)
;; =============================================================================

(struct gas-worker-allocation
  (active-geysers
   current-gas-workers
   desired-gas-workers
   workers-per-geyser
   target-gas-mineral-ratio
   current-gas-mineral-ratio
   action
   delta-gas-workers
   rationale)
  #:transparent)

(define (compute-optimal-gas-workers
         #:race [race 'Zerg]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 200]
         #:gas [raw-gas 0]
         #:workers [raw-workers 16]
         #:active-bases [raw-active-bases 1]
         #:active-geysers [raw-active-geysers 1]
         #:current-gas-workers [raw-current-gas-workers 3]
         #:should-expand? [should-expand? #f]
         #:escrow-minerals [raw-escrow-minerals 0]
         #:tech-gas-demand [raw-tech-gas-demand 100]
         #:unit-gas-ratio [raw-unit-gas-ratio 0.35]
         #:under-crisis? [under-crisis? #f])
  (define frame (safe-nonneg-int raw-frame 0))
  (define minerals (safe-nonneg-int raw-minerals 0))
  (define gas (safe-nonneg-int raw-gas 0))
  (define workers (safe-nonneg-int raw-workers 16))
  (define active-bases (safe-nonneg-int raw-active-bases 1))
  (define active-geysers (safe-nonneg-int raw-active-geysers 1))
  (define current-gas-workers (safe-nonneg-int raw-current-gas-workers 0))
  (define escrow-minerals (safe-nonneg-int raw-escrow-minerals 0))
  (define tech-gas-demand (safe-nonneg-int raw-tech-gas-demand 0))
  (define unit-gas-ratio (max 0.0 (min 1.0 (safe-real raw-unit-gas-ratio 0.35))))
  (define eff-bases (max 1 active-bases))
  (define max-geysers (* 2 eff-bases))
  (define cur-gm-ratio
    (exact->inexact (/ (max 0 gas) (max 50 minerals))))
  (define target-gm-ratio
    (cond
      [(and (< frame 1400) (< workers 16)) 0.15]
      [(and should-expand? (< eff-bases 2) (< minerals 300) (>= gas 100)) 0.12]
      [(and (>= minerals 600) (< gas 150)) 0.85]
      [(>= tech-gas-demand 200) (max 0.55 unit-gas-ratio)]
      [else (max 0.25 unit-gas-ratio)]))

  (cond
    ;; Case 1: Floating high gas (> 400G) while mineral-starved (< 300M), OR
    ;;         saving for early natural expansion with >= 100G banked -> pull off gas!
    [(or (and (> gas 400) (< minerals 300))
         (and should-expand? (< eff-bases 2) (< minerals 300) (>= gas 100))
         (and (< workers 14) (< minerals 200) (>= gas 100)))
     (define wpg (if (or (> gas 600) (< workers 14)) 0 1))
     (define desired (* (min active-geysers eff-bases) wpg))
     (gas-worker-allocation active-geysers
                            current-gas-workers
                            desired
                            wpg
                            target-gm-ratio
                            cur-gm-ratio
                            'pull-off-gas-to-minerals
                            (- desired current-gas-workers)
                            'gas-float-or-expansion-escrow-prioritize-minerals)]

    ;; Case 2: Early game (< 16 workers on 1 base) -> never put > 3 workers in gas
    ;;         (taking 2 gases too early costs -340 min/min and starves natural expand + workers!)
    [(and (< workers 16) (< eff-bases 2))
     (define wpg (if (< workers 13) 0 (min 3 (- workers 12))))
     (define desired (* (min 1 active-geysers) wpg))
     (define act
       (if (< desired current-gas-workers)
           'pull-off-gas-to-minerals
           'hold-gas-workers))
     (gas-worker-allocation active-geysers
                            current-gas-workers
                            desired
                            wpg
                            target-gm-ratio
                            cur-gm-ratio
                            act
                            (- desired current-gas-workers)
                            'protect-early-mineral-income-single-gas-cap)]

    ;; Case 3: Banking minerals (> 600M) or high tech demand while gas-starved (< 150G)
    ;;         -> fill 3/3 per geyser and take additional geysers!
    [(or (and (>= minerals 600) (< gas 150))
         (and (>= tech-gas-demand 200) (< gas 150) (>= workers 20)))
     (define wpg 3)
     (define target-geysers (min max-geysers (max 1 (add1 active-geysers))))
     (define max-gas-workers (max 0 (- workers (* 12 eff-bases))))
     (define desired (min max-gas-workers (* wpg (max 1 target-geysers))))
     (define act
       (if (< active-geysers max-geysers)
           'build-new-geyser-and-saturate
           'saturate-existing-geysers))
     (gas-worker-allocation active-geysers
                            current-gas-workers
                            desired
                            wpg
                            target-gm-ratio
                            cur-gm-ratio
                            act
                            (- desired current-gas-workers)
                            'mineral-bank-gas-starved-expand-and-saturate-geysers)]

    ;; Case 4: Standard balanced macro
    [else
     (define wpg (if (> gas 350) 2 3))
     (define max-gas-workers (max 0 (- workers (* 13 eff-bases))))
     (define desired (min max-gas-workers (* wpg (max 1 active-geysers))))
     (define act
       (cond
         [(< desired current-gas-workers) 'pull-off-gas-to-minerals]
         [(> desired current-gas-workers) 'saturate-existing-geysers]
         [else                            'hold-gas-workers]))
     (gas-worker-allocation active-geysers
                            current-gas-workers
                            desired
                            wpg
                            target-gm-ratio
                            cur-gm-ratio
                            act
                            (- desired current-gas-workers)
                            'balanced-macro-gas-mineral-equilibrium)]))

(struct guns-vs-butter-ppf
  (butter-utility                ; flonum: U'_butter (bases + workers)
   infrastructure-utility        ; flonum: U'_infra (production facilities + supply)
   tech-upgrade-utility          ; flonum: U'_tech (upgrades + tech buildings, Lanchester N^1.7 scaled)
   guns-army-utility             ; flonum: U'_guns (standing combat army)
   disruption-utility            ; flonum: U'_disrupt (burrowed blockers + worker raiders)
   bucket-ranking                ; list of bucket symbols sorted highest-to-lowest marginal utility
   top-priority-bucket           ; symbol: highest marginal utility bucket
   butter-share                  ; flonum in [0.0, 1.0]
   guns-share                    ; flonum in [0.0, 1.0]
   tech-share                    ; flonum in [0.0, 1.0]
   lanchester-upgrade-multiplier ; flonum: N^1.7 force multiplier
   recommended-gas-allocation)   ; gas-worker-allocation
  #:transparent)

(define (evaluate-guns-vs-butter-ppf
         #:race [race 'Zerg]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 200]
         #:gas [raw-gas 100]
         #:supply-left [raw-supply-left 6]
         #:supply-cap [raw-supply-cap 22]
         #:workers [raw-workers 16]
         #:target-workers [raw-target-workers 44]
         #:active-bases [raw-active-bases 1]
         #:depleting-bases [raw-depleting-bases 0]
         #:active-geysers [raw-active-geysers 1]
         #:current-gas-workers [raw-current-gas-workers 3]
         #:production-facilities [raw-production-facilities 1]
         #:busy-facilities [raw-busy-facilities 0]
         #:army-count [raw-army-count 4]
         #:missing-synergy-count [raw-missing-synergy-count 2]
         #:fap-score [raw-fap-score 0]
         #:under-crisis? [under-crisis? #f]
         #:mirror-macro-verdict [mirror-macro-verdict 'pace-Macro-And-Disrupt]
         #:enemy-upgrade-advantage [raw-enemy-upgrade-advantage 0]
         #:enemy-active-research-count [raw-enemy-active-research-count 0]
         #:requires-detection? [requires-detection? #f]
         #:requires-anti-air? [requires-anti-air? #f])
  (define frame (safe-nonneg-int raw-frame 0))
  (define minerals (safe-nonneg-int raw-minerals 0))
  (define gas (safe-nonneg-int raw-gas 0))
  (define supply-left (safe-exact-int raw-supply-left 0))
  (define supply-cap (safe-nonneg-int raw-supply-cap 15))
  (define workers (safe-nonneg-int raw-workers 12))
  (define target-workers (max 1 (safe-nonneg-int raw-target-workers 44)))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define depleting-bases (safe-nonneg-int raw-depleting-bases 0))
  (define active-geysers (safe-nonneg-int raw-active-geysers 1))
  (define current-gas-workers (safe-nonneg-int raw-current-gas-workers 0))
  (define production-facilities (max 1 (safe-nonneg-int raw-production-facilities 1)))
  (define busy-facilities (safe-nonneg-int raw-busy-facilities 0))
  (define army-count (safe-nonneg-int raw-army-count 0))
  (define missing-synergy-count (safe-nonneg-int raw-missing-synergy-count 0))
  (define fap-score (safe-real raw-fap-score 0.0))
  (define enemy-upgrade-advantage (safe-exact-int raw-enemy-upgrade-advantage 0))
  (define enemy-active-research-count (safe-nonneg-int raw-enemy-active-research-count 0))

  ;; 1. Butter — Economy (bases + workers):
  ;;    Compounding rate r_econ ~ 0.95 min^-1, boosted by worker deficit, depleting bases,
  ;;    or passive turtle opponent; heavily discounted under immediate crisis/all-in.
  (define worker-deficit-ratio
    (/ (exact->inexact (max 0 (- target-workers workers)))
       (max 1.0 (exact->inexact target-workers))))
  (define depletion-boost (* 35.0 depleting-bases))
  (define verdict-butter-boost
    (case mirror-macro-verdict
      [(out-Expand-Passive-Turtle)         30.0]
      [(punish-And-Deny-Greedy-Expand)     15.0]
      [(defend-All-In-Then-Counter-Expand) -35.0]
      [else                                8.0]))
  (define crisis-discount (if under-crisis? 0.25 1.0))
  (define butter-u
    (max 5.0
         (* crisis-discount
            (+ 25.0
               (* 65.0 worker-deficit-ratio)
               depletion-boost
               verdict-butter-boost))))

  ;; 2. Infrastructure — Production & Supply:
  ;;    Shadow price spikes when supply-left <= 3 (supply block imminent) or when
  ;;    all production facilities are 100% busy while banking resources.
  (define fac-utilization
    (/ (exact->inexact (min production-facilities busy-facilities))
       (max 1.0 (exact->inexact production-facilities))))
  (define supply-pressure
    (cond
      [(>= supply-cap 200) 0.0]
      [(<= supply-left 2)  85.0]
      [(<= supply-left 4)  45.0]
      [else                8.0]))
  (define bottleneck-pressure
    (if (and (>= fac-utilization 0.95) (>= minerals 450))
        55.0
        (* 25.0 fac-utilization)))
  (define infra-u
    (+ 10.0 supply-pressure bottleneck-pressure))

  ;; 3. Tech & Upgrades (Lanchester N^1.7 Force Multiplier + Opponent Tech Parity):
  ;;    A_eff = alpha(U) * N^1.7 -> dA_eff/dU = (d alpha / dU) * N^1.7.
  ;;    Low marginal value when standing army N < 6; massive value when N >= 12,
  ;;    when core build synergy upgrades are missing, or when opponent has an upgrade lead!
  (define lanchester-mult
    (/ (expt (max 1.0 (exact->inexact army-count)) 1.7)
       (expt 8.0 1.7)))
  (define enemy-tech-parity-boost
    (+ (* 24.0 (max 0 enemy-upgrade-advantage))
       (* 14.0 (max 0 enemy-active-research-count))
       (if (or requires-detection? requires-anti-air?) 16.0 0.0)))
  (define tech-u
    (min 140.0
         (+ 12.0
            (* 22.0 lanchester-mult (max 1 missing-synergy-count))
            enemy-tech-parity-boost
            (if (eq? mirror-macro-verdict 'out-Expand-Passive-Turtle) 20.0 0.0))))

  ;; 4. Guns — Standing Army:
  ;;    Dominates during crisis, enemy 1-base all-in, negative FAP score, or
  ;;    when we have idle production slots and unreserved resources.
  (define crisis-guns-boost
    (cond
      [under-crisis?                                                90.0]
      [(eq? mirror-macro-verdict 'defend-All-In-Then-Counter-Expand) 75.0]
      [(< fap-score -10)                                            45.0]
      [else                                                         0.0]))
  (define idle-fac-boost
    (* 12.0 (max 0 (- production-facilities busy-facilities))))
  (define guns-u
    (+ 28.0 crisis-guns-boost idle-fac-boost))

  ;; 5. Disruption — Asymmetric ROI (25M Zergling blocking 300M Hatchery + 1000M/min):
  (define disrupt-u
    (case mirror-macro-verdict
      [(punish-And-Deny-Greedy-Expand)     95.0]
      [(pace-Macro-And-Disrupt)            42.0]
      [(out-Expand-Passive-Turtle)         38.0]
      [(defend-All-In-Then-Counter-Expand) 12.0]
      [else                                30.0]))

  (define scored-buckets
    (list (cons 'butter-economy butter-u)
          (cons 'infrastructure-production-supply infra-u)
          (cons 'tech-and-upgrades tech-u)
          (cons 'guns-standing-army guns-u)
          (cons 'disruption-asymmetric-roi disrupt-u)))
  (define sorted-buckets
    (sort scored-buckets > #:key cdr))
  (define ranking (map car sorted-buckets))
  (define top-bucket (car ranking))

  (define total-core (+ butter-u guns-u tech-u))
  (define butter-sh (/ butter-u (max 1.0 total-core)))
  (define guns-sh (/ guns-u (max 1.0 total-core)))
  (define tech-sh (/ tech-u (max 1.0 total-core)))

  (define gas-alloc
    (compute-optimal-gas-workers
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:workers workers
     #:active-bases active-bases
     #:active-geysers active-geysers
     #:current-gas-workers current-gas-workers
     #:should-expand? (or (> depleting-bases 0) (< workers target-workers))
     #:tech-gas-demand (* 75 missing-synergy-count)
     #:unit-gas-ratio (if (> tech-sh 0.35) 0.55 0.35)
     #:under-crisis? under-crisis?))

  (guns-vs-butter-ppf butter-u
                      infra-u
                      tech-u
                      guns-u
                      disrupt-u
                      ranking
                      top-bucket
                      butter-sh
                      guns-sh
                      tech-sh
                      lanchester-mult
                      gas-alloc))

;; =============================================================================
;; 9. Marginal-Utility Prioritization & Braun-Heap Resource Scheduler (PV1-PV6)
;; =============================================================================

;; Canonical race normalization lives in `lib/sc2-types.rkt`.
(define normalize-ledger-race normalize-known-race)

;; Category is one of:
;;   'supply | 'combat-unit | 'counter-tech | 'production-scaling
;;   | 'tech-upgrade | 'worker | 'expansion
(struct priority-candidate
  (id
   category
   action
   min-cost
   gas-cost
   supply-cost
   utility-score
   urgency-tier
   blocking-allowed?)
  #:transparent)

(struct priority-decision-entry
  (rank
   id
   category
   action
   min-cost
   gas-cost
   supply-cost
   utility-score
   blocking-allowed?
   outcome
   applicable-min-floor
   applicable-gas-floor
   blocked-by-id)
  #:transparent)

(struct priority-schedule-result
  (scheduled-actions
   scheduled-candidates
   reserved-candidate
   remaining-minerals
   remaining-gas
   remaining-supply
   category-utilities)
  #:transparent)

;; Invariant PV6: Refractory Cooldown Tracker
(struct refractory-cooldown-tracker (table) #:mutable #:transparent)

(define (make-refractory-cooldown-tracker)
  (refractory-cooldown-tracker (make-hash)))

(define (refractory-allow-action?! tracker key frame cooldown-frames)
  (cond
    [(not (refractory-cooldown-tracker? tracker)) #t]
    [else
     (define tbl
       (let ([t (refractory-cooldown-tracker-table tracker)])
         (if (hash? t)
             t
             (let ([nt (make-hash)])
               (set-refractory-cooldown-tracker-table! tracker nt)
               nt))))
     (define f (safe-exact-int frame 0))
     (define cd (max 1 (safe-exact-int cooldown-frames 1)))
     (define last-f (hash-ref tbl key #f))
     (cond
       [(or (not (exact-integer? last-f))
            (>= (- f last-f) cd))
        (hash-set! tbl key f)
        #t]
       [else #f])]))

;; Continuous, breakpoint-free pressure metrics (returns an immutable hash)
;; =============================================================================
;; Opponent Intelligence Freshness & Coverage Model (`opponent-intel-quality`)
;;
;; Models opponent knowledge as two continuous dimensions in [0.0, 1.0] across
;; 4 spatial/functional opponent sectors rather than an all-or-nothing timer:
;;   1. `enemy-main`    (half-life = 1344 frames / 60s: tech tree & main production)
;;   2. `enemy-natural` (half-life = 1120 frames / 50s: natural expansion & defense)
;;   3. `enemy-third`   (half-life = 1344 frames / 60s: 3rd+ bases, active at frame >= 3360)
;;   4. `corridor-army` (half-life = 784 frames  / 35s: mobile army & attack corridor)
;;
;; Produces:
;;   - `freshness`  in [0.0, 1.0]: weighted exponential decay across opponent sectors
;;   - `coverage`   in [0.0, 1.0]: fraction of active opponent sectors with non-expired intel
;;   - `confidence` in [0.0, 1.0]: `0.55 * freshness + 0.45 * coverage`
;;   - `deficit`    in [0.0, 1.0]: `1.0 - confidence`
;;   - `priority-sector`: `'enemy-natural` | `'enemy-main` | `'enemy-third` | `'corridor-army`
;;                        (the sector with largest weighted uncertainty `w_s * (1 - F_s)`)
;;   - `target-goal`:     `'maintain-vision` | `'expand-coverage` | `'refresh-tech-intel`
;;                        | `'harass-and-probe` | `'recon-in-force`
;; =============================================================================

(struct opponent-intel-quality
  (freshness
   coverage
   confidence
   deficit
   priority-sector
   target-goal
   sector-freshness-hash)
  #:transparent)

(define (sector-decay-freshness frame last-seen-frame half-life-frames [fallback-staleness #f])
  (define age
    (cond
      [(and (real? last-seen-frame) (> last-seen-frame 0))
       (max 0.0 (- (exact->inexact frame) (exact->inexact last-seen-frame)))]
      [(and (real? fallback-staleness) (>= fallback-staleness 0))
       (max 0.0 (exact->inexact fallback-staleness))]
      [else
       (max 0.0 (exact->inexact frame))]))
  ;; Opening grace curve: before frame 1120 (50s), while the opening scout is still walking
  ;; across the map, smoothly decay from 1.0 rather than treating frame 300 as "blind".
  (define raw-f
    (if (and (or (not (real? last-seen-frame)) (<= last-seen-frame 0))
             (not fallback-staleness)
             (< frame 1120))
        (max 0.45 (- 1.0 (/ (exact->inexact frame) 1680.0)))
        (exp (* -0.6931471805599453 (/ age (max 1.0 (exact->inexact half-life-frames)))))))
  (max 0.0 (min 1.0 raw-f)))

(define (evaluate-opponent-intel-quality
         #:frame [raw-frame 0]
         #:last-seen-main-frame [last-main -1]
         #:last-seen-natural-frame [last-nat -1]
         #:last-seen-third-frame [last-third -1]
         #:last-seen-army-frame [last-army -1]
         #:intel-staleness-frames [fallback-staleness #f]
         #:army-supply [raw-army-supply 0.0]
         #:ally-units [ally-units '()])
  (define frame (safe-nonneg-int raw-frame 0))
  (define army-sup (safe-real raw-army-supply 0.0))
  (define f-main (sector-decay-freshness frame last-main 1120.0 fallback-staleness))
  (define f-nat  (sector-decay-freshness frame last-nat  784.0  fallback-staleness))
  (define f-third
    (if (< frame 3360)
        1.0
        (sector-decay-freshness frame last-third 1120.0 fallback-staleness)))
  (define f-army (sector-decay-freshness frame last-army 448.0  fallback-staleness))

  ;; Phase-dependent sector weights (3rd base becomes relevant at frame >= 3360 = 2m30s)
  (define w-main  (if (>= frame 3360) 0.32 0.38))
  (define w-nat   (if (>= frame 3360) 0.28 0.36))
  (define w-third (if (>= frame 3360) 0.15 0.00))
  (define w-army  (if (>= frame 3360) 0.25 0.26))

  (define freshness
    (max 0.0 (min 1.0 (+ (* w-main f-main)
                         (* w-nat f-nat)
                         (* w-third f-third)
                         (* w-army f-army)))))

  ;; Sector coverage: an observed sector with freshness >= 0.65 counts as fully covered (1.0),
  ;; tapering smoothly to 0.0 at freshness <= 0.35; unobserved sectors after opening grace have 0.0 coverage.
  (define (sec-cov f last-sec)
    (cond
      [(and (or (not (real? last-sec)) (<= last-sec 0))
            (not fallback-staleness)
            (>= frame 1120))
       0.0]
      [else
       (max 0.0 (min 1.0 (/ (- f 0.35) 0.30)))]))
  (define coverage
    (max 0.0 (min 1.0 (+ (* w-main (sec-cov f-main last-main))
                         (* w-nat (sec-cov f-nat last-nat))
                         (* w-third (if (< frame 3360) 1.0 (sec-cov f-third last-third)))
                         (* w-army (sec-cov f-army last-army))))))

  (define confidence (max 0.0 (min 1.0 (+ (* 0.55 freshness) (* 0.45 coverage)))))
  (define deficit (max 0.0 (- 1.0 confidence)))

  ;; Pick the priority sector with largest weighted uncertainty `w_s * (1 - F_s)`
  (define sector-gaps
    (list (cons 'enemy-natural (* w-nat (- 1.0 f-nat)))
          (cons 'enemy-main    (* w-main (- 1.0 f-main)))
          (cons 'corridor-army (* w-army (- 1.0 f-army)))
          (cons 'enemy-third   (* w-third (- 1.0 f-third)))))
  (define priority-sector
    (car (argmax cdr sector-gaps)))

  (define has-raiders?
    (and (list? ally-units)
         (ormap (lambda (u)
                  (define sym (if (hash? u) (hash-ref u 'type 'none) u))
                  (memq sym '(reaper hellion oracle phoenix adept mutalisk banshee zergling warp-prism medivac)))
                ally-units)))

  ;; Graduated info-gathering goal based on Freshness x Coverage:
  (define target-goal
    (cond
      [(>= confidence 0.65) 'maintain-vision]
      [(and (< confidence 0.35) (>= army-sup 10.0)) 'recon-in-force]
      [(and (< confidence 0.35) (or has-raiders? (>= army-sup 4.0))) 'harass-and-probe]
      [(< coverage 0.55) 'expand-coverage]
      [(< f-main 0.45) 'refresh-tech-intel]
      [(or has-raiders? (>= army-sup 4.0)) 'harass-and-probe]
      [else 'expand-coverage]))

  (opponent-intel-quality
   freshness
   coverage
   confidence
   deficit
   priority-sector
   target-goal
   (hash 'enemy-main f-main
         'enemy-natural f-nat
         'enemy-third f-third
         'corridor-army f-army)))

(define (compute-state-pressure-metrics
         #:race [raw-race 'Zerg]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 200]
         #:gas [raw-gas 0]
         #:supply-left [raw-supply-left 4]
         #:supply-cap [raw-supply-cap 15]
         #:pending-supply [raw-pending-supply 0]
         #:workers [raw-workers 16]
         #:target-workers [raw-target-workers 44]
         #:active-bases [raw-active-bases 1]
         #:desired-bases [raw-desired-bases 2]
         #:production-facilities [raw-prod-facilities 1]
         #:max-facilities [raw-max-facilities 4]
         #:army-supply [raw-army-supply 0]
         #:enemy-threat-supply [raw-enemy-threat-supply 0]
         #:under-attack? [raw-under-attack? #f]
         #:requires-anti-air? [raw-requires-anti-air? #f]
         #:requires-detection? [raw-requires-detection? #f]
         #:escrow-age-frames [raw-escrow-age-frames 0]
         #:max-escrow-frames [raw-max-escrow-frames 224]
         #:intel-staleness-frames [raw-intel-staleness-frames 0]
         #:max-intel-staleness-frames [raw-max-intel-staleness-frames 896]
         #:intel-freshness [override-intel-freshness #f]
         #:intel-coverage [override-intel-coverage #f]
         #:intel-confidence [override-intel-confidence #f]
         #:supply-at-risk? [raw-supply-at-risk? #f]
         #:supply-buffer [override-supply-buffer #f])
  (define race (normalize-ledger-race raw-race))
  (define frame (safe-nonneg-int raw-frame 0))
  (define minerals (safe-nonneg-int raw-minerals 0))
  (define gas (safe-nonneg-int raw-gas 0))
  (define supply-left (max 0 (safe-exact-int raw-supply-left 4)))
  (define supply-cap (min 200 (max 1 (safe-nonneg-int raw-supply-cap 15))))
  (define pending-supply (safe-nonneg-int raw-pending-supply 0))
  (define workers (safe-nonneg-int raw-workers 12))
  (define target-workers (min 70 (max 12 (safe-nonneg-int raw-target-workers 44))))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define desired-bases (max 1 (safe-nonneg-int raw-desired-bases 2)))
  (define prod-facilities (max 1 (safe-nonneg-int raw-prod-facilities 1)))
  (define max-facilities (max 1 (safe-nonneg-int raw-max-facilities 4)))
  (define army-supply (max 0.0 (safe-real raw-army-supply 0.0)))
  (define enemy-threat-supply (max 0.0 (safe-real raw-enemy-threat-supply 0.0)))
  (define under-attack? (eq? raw-under-attack? #t))
  (define requires-anti-air? (eq? raw-requires-anti-air? #t))
  (define requires-detection? (eq? raw-requires-detection? #t))
  (define escrow-age-frames (safe-nonneg-int raw-escrow-age-frames 0))
  (define max-escrow-frames (max 1 (safe-nonneg-int raw-max-escrow-frames 224)))
  (define intel-staleness-frames (safe-nonneg-int raw-intel-staleness-frames 0))
  (define max-intel-staleness-frames (max 1 (safe-nonneg-int raw-max-intel-staleness-frames 896)))
  (define supply-at-risk? (eq? raw-supply-at-risk? #t))

  ;; 1. Supply buffer & continuous supply hazard in [0.0, 2.0]
  ;; Add +2.0 lead headroom between 30 and 90 supply used while keeping < 30 openings unchanged.
  (define supply-used (max 0 (- supply-cap supply-left)))
  (define supply-buffer
    (if (and override-supply-buffer (real? override-supply-buffer) (not (nan? override-supply-buffer)))
        (max 1.0 (exact->inexact override-supply-buffer))
        (+ 2.0
           (* 0.06 (exact->inexact supply-cap))
           (if (and (>= supply-used 30) (<= supply-used 90)) 2.0 0.0))))
  (define pending-credit-per-unit
    (if (eq? race 'Zerg) 4.0 8.0))
  (define eff-supply
    (+ (exact->inexact supply-left) (* pending-credit-per-unit (exact->inexact pending-supply))))
  (define raw-supply-hazard
    (/ (max 0.0 (- supply-buffer eff-supply))
       (max 1.0 supply-buffer)))
  (define supply-margin-cap (compute-supply-preemption-margin supply-cap))
  (define eff-supply-margin (max supply-buffer (exact->inexact supply-margin-cap)))
  (define supply-preempt-now? (supply-preemption-needed? supply-used supply-cap pending-supply #:race race))
  (define supply-hazard
    (cond
      [(>= supply-cap 200) 0.0]
      [supply-preempt-now?
       (min 2.0 (max 0.25 raw-supply-hazard))]
      [(and (> pending-supply 0)
            (not supply-at-risk?)
            (or (>= (+ supply-cap (* 8 pending-supply)) 200)
                (> eff-supply eff-supply-margin))
            (not (and (eq? race 'Zerg) (>= active-bases 3) (<= pending-supply 1))))
       0.0]
      [(and supply-at-risk?
            (< pending-supply 2)
            (<= eff-supply (+ supply-buffer 6.0)))
       (min 2.0 (max 0.5 raw-supply-hazard))]
      [(<= eff-supply supply-buffer)
       ;; Strictly positive in [0.05, 2.0] whenever supply-left <= supply-buffer (PV4)
       (min 2.0 (max 0.05 raw-supply-hazard))]
      [else 0.0]))

  ;; 2. Threat pressure
  (define threat-pressure
    (/ (+ (* 1.5 enemy-threat-supply)
          (if under-attack? 12.0 0.0)
          (if (or under-attack? (> enemy-threat-supply 0.0))
              (max 0.0 (- (* 0.65 (exact->inexact (max 0 (- workers 14))))
                          army-supply))
              0.0))
       (max 4.0 army-supply)))

  ;; 3. Gas imbalance
  (define gas-imbalance
    (/ (exact->inexact gas)
       (max 50.0 (exact->inexact minerals))))

  ;; 4. Worker saturation gap (smoothly decays toward 0 under high threat-pressure)
  (define worker-saturation-gap
    (* (max 0.0 (/ (exact->inexact (- target-workers workers))
                   (max 1.0 (exact->inexact target-workers))))
       (/ 1.0 (+ 1.0 (* 1.8 threat-pressure)))))

  ;; 5. Facility scaling pressure
  (define facility-scaling-pressure
    (* (max 0.0 (/ (exact->inexact (- max-facilities prod-facilities))
                   (max 1.0 (exact->inexact max-facilities))))
       (+ 1.0 (/ (exact->inexact minerals) 250.0))))

  ;; 6. Continuous Opponent Information Freshness, Coverage & Pressure (`intel-pressure` in [0.0, 2.5]):
  ;;    Combines sector-level `intel-freshness` and `intel-coverage` (`intel-confidence = 0.55*F + 0.45*C`)
  ;;    with `intel-staleness-frames / max-intel-staleness-frames` (default 896 frames = 40s):
  ;;      - High confidence (>= 0.65) and low staleness -> 0.0 pressure (zero macro interference)
  ;;      - Moderate deficit (0.35 <= confidence < 0.65) -> smooth [0.1, 0.95] pressure (recon goal, no escrow cancel)
  ;;      - Severe blindness (confidence < 0.35 or staleness >= max-intel-staleness-frames) -> >= 1.0 pressure
  (define default-iq
    (evaluate-opponent-intel-quality
     #:frame frame
     #:intel-staleness-frames intel-staleness-frames
     #:army-supply army-supply))
  (define iq-freshness
    (if (and override-intel-freshness (real? override-intel-freshness))
        (max 0.0 (min 1.0 (exact->inexact override-intel-freshness)))
        (opponent-intel-quality-freshness default-iq)))
  (define iq-coverage
    (if (and override-intel-coverage (real? override-intel-coverage))
        (max 0.0 (min 1.0 (exact->inexact override-intel-coverage)))
        (opponent-intel-quality-coverage default-iq)))
  (define iq-confidence
    (if (and override-intel-confidence (real? override-intel-confidence))
        (max 0.0 (min 1.0 (exact->inexact override-intel-confidence)))
        (max 0.0 (min 1.0 (+ (* 0.55 iq-freshness) (* 0.45 iq-coverage))))))
  (define staleness-ratio
    (if (<= intel-staleness-frames 0)
        0.0
        (/ (exact->inexact intel-staleness-frames)
           (max 1.0 (exact->inexact max-intel-staleness-frames)))))
  (define confidence-pressure
    (cond
      [(>= iq-confidence 0.65) 0.0]
      [(>= iq-confidence 0.35) (* 0.95 (/ (- 0.65 iq-confidence) 0.30))]
      [else (+ 1.0 (min 1.5 (/ (- 0.35 iq-confidence) 0.25)))]))
  (define intel-pressure
    (min 2.5 (max staleness-ratio confidence-pressure)))

  ;; 7. Expansion desire & escrow eligibility (PV1 / PV7 / PV9)
  (define expansion-desire
    (if (and (< active-bases desired-bases) (not under-attack?))
        (* (/ (exact->inexact (- desired-bases active-bases))
              (max 1.0 (exact->inexact desired-bases)))
           (/ 1.0 (+ 1.0 (* 0.8 threat-pressure) (* 0.25 intel-pressure)))
           (+ 0.65 (min 1.35 (/ (exact->inexact minerals) 350.0))))
        0.0))
  (define escrow-eligible?
    (and (< escrow-age-frames (min MAX-ESCROW-AGE-FRAMES max-escrow-frames))
         (< threat-pressure 0.85)
         (< enemy-threat-supply 6.0)
         (or (< intel-pressure 1.0) (< frame 2688) (>= army-supply 12))
         (or (= active-bases 1) (>= army-supply 18))
         (not under-attack?)
         (< active-bases desired-bases)))

  (hash 'race race
        'frame frame
        'minerals minerals
        'gas gas
        'supply-left supply-left
        'supply-cap supply-cap
        'pending-supply pending-supply
        'supply-buffer supply-buffer
        'supply-hazard supply-hazard
        'supply-at-risk? supply-at-risk?
        'workers workers
        'target-workers target-workers
        'active-bases active-bases
        'desired-bases desired-bases
        'production-facilities prod-facilities
        'max-facilities max-facilities
        'army-supply army-supply
        'enemy-threat-supply enemy-threat-supply
        'under-attack? under-attack?
        'requires-anti-air? requires-anti-air?
        'requires-detection? requires-detection?
        'escrow-age-frames escrow-age-frames
        'max-escrow-frames max-escrow-frames
        'intel-staleness-frames intel-staleness-frames
        'max-intel-staleness-frames max-intel-staleness-frames
        'intel-freshness iq-freshness
        'intel-coverage iq-coverage
        'intel-confidence iq-confidence
        'intel-pressure intel-pressure
        'threat-pressure threat-pressure
        'gas-imbalance gas-imbalance
        'worker-saturation-gap worker-saturation-gap
        'facility-scaling-pressure facility-scaling-pressure
        'expansion-desire expansion-desire
        'escrow-eligible? escrow-eligible?))

(define PV5-ANTI-AIR-SYMS
  '(queen hydralisk corruptor mutalisk spore-crawler
    hydralisk-den spire
    viking-fighter viking thor cyclone liberator missile-turret engineering-bay starport
    stalker phoenix void-ray carrier tempest archon photon-cannon cybernetics-core stargate shield-battery))

(define PV5-DETECTOR-SYMS
  '(spore-crawler overseer lair
    missile-turret engineering-bay raven starport starport-techlab
    observer photon-cannon robotics-facility forge))

(define PV5-PURE-DETECTOR-SYMS
  '(observer overseer raven lair robotics-facility starport-techlab forge))

(define PV5-PURE-ANTI-AIR-SYMS
  '(queen hydralisk corruptor mutalisk hydralisk-den spire
    viking-fighter viking thor cyclone liberator
    stalker phoenix void-ray carrier tempest archon cybernetics-core stargate shield-battery))

(define PV5-COUNTER-TECH-AND-UNIT-SYMS
  (remove-duplicates (append PV5-ANTI-AIR-SYMS PV5-DETECTOR-SYMS) eq?))

(define PV3-GAS-COMBAT-UNIT-SYMS
  '(roach ravager hydralisk lurker mutalisk corruptor
    marauder siege-tank widow-mine medivac viking viking-fighter ghost
    stalker sentry adept immortal colossus disruptor oracle void-ray phoenix))

(define PV3-MINERAL-ONLY-COMBAT-UNIT-SYMS
  '(zergling marine zealot))

(define PV-INTEL-GATHERING-UNIT-SYMS
  '(;; Dedicated Scouts & Mobile Detectors (Scouting)
    observer overseer overlord sentry
    ;; Fast Harassment & Recon Raiders (Harassment)
    reaper hellion oracle phoenix adept mutalisk banshee medivac warp-prism
    ;; Mobile Probing / Attacking Units (Attacking for Intel)
    zergling stalker marine zealot roach))

;; Selects the optimal modality for gathering information on the opponent based on
;; continuous Freshness x Coverage (`intel-confidence`, `intel-coverage`) and army state:
;;   - 'attacking  when army-supply >= 10 (recon-in-force / multi-base probing sweep)
;;   - 'harassment when mobile harassment raiders exist or army-supply >= 4 (mineral-line / expansion poke)
;;   - 'scouting   otherwise (worker scout, Overlord, Observer/Overseer/Hallucination/Scan, or single spotter)
(define (select-intel-gathering-method
         #:race [raw-race 'Zerg]
         #:frame [raw-frame 0]
         #:army-supply [raw-army-supply 0]
         #:ally-units [ally-units '()]
         #:intel-staleness-frames [raw-staleness 0]
         #:intel-freshness [raw-freshness #f]
         #:intel-coverage [raw-coverage #f])
  (define army-sup (safe-real raw-army-supply 0.0))
  (define units (if (list? ally-units) ally-units '()))
  (define has-raiders?
    (ormap (lambda (u)
             (define sym (if (hash? u) (hash-ref u 'type 'none) u))
             (memq sym '(reaper hellion oracle phoenix adept mutalisk banshee zergling warp-prism medivac)))
           units))
  (cond
    [(>= army-sup 10.0) 'attacking]
    [(or has-raiders? (>= army-sup 4.0)) 'harassment]
    [else 'scouting]))

;; Shared Matchup, Counter-Composition, Scaling & Resource-Cap Policies
(define ZERG-SIEGE-SPLASH-ENEMY-SYMS
  '(siege-tank siege-tank-sieged colossus archon
    liberator liberator-ag planetary-fortress hellion-tank battlecruiser))

(define TERRAN-GHOST-COUNTER-ENEMY-SYMS
  '(infestor infestor-burrowed viper ultralisk ultralisk-burrowed
    high-templar archon lurker lurker-mp lurker-burrowed lurker-mp-burrowed))

(define TERRAN-LIBERATOR-COUNTER-ENEMY-SYMS
  '(lurker lurker-mp lurker-burrowed lurker-mp-burrowed
    ultralisk ultralisk-burrowed siege-tank siege-tank-sieged))

(define PROTOSS-CAPITAL-AIR-ENEMY-SYMS
  '(tempest carrier battlecruiser brood-lord broodlord mothership))

(define (normalize-enemy-race-sym raw-enemy-race)
  (cond
    [(memq raw-enemy-race '(Zerg Terran Protoss Random Unknown)) raw-enemy-race]
    [(string? raw-enemy-race)
     (case (string-downcase raw-enemy-race)
       [("zerg") 'Zerg]
       [("terran") 'Terran]
       [("protoss") 'Protoss]
       [("random") 'Random]
       [else 'Unknown])]
    [else 'Unknown]))

(define (enemy-counts-have-any? enemy-u-counts syms)
  (and (hash? enemy-u-counts)
       (> (hash-count enemy-u-counts) 0)
       (for/or ([s (in-list syms)])
         (> (safe-nonneg-int (hash-ref enemy-u-counts s 0) 0) 0))))

(define (enemy-any-count enemy-u-counts enemy-b-counts sym)
  (max (if (hash? enemy-u-counts)
           (safe-nonneg-int (hash-ref enemy-u-counts sym 0) 0)
           0)
       (if (hash? enemy-b-counts)
           (safe-nonneg-int (hash-ref enemy-b-counts sym 0) 0)
           0)))

(define (enemy-any-counts-have? enemy-u-counts enemy-b-counts syms)
  (or (enemy-counts-have-any? enemy-u-counts syms)
      (enemy-counts-have-any? enemy-b-counts syms)))

(define (has-upgrade-sym? target-sym upgs)
  (and (list? upgs)
       (case target-sym
         [(metabolic-boost zergling-movementspeed)
          (not (not (or (memq 'metabolic-boost upgs)
                        (memq 'zergling-movementspeed upgs))))]
         [(centrifical-hooks centrifugal-hooks)
          (not (not (or (memq 'centrifical-hooks upgs)
                        (memq 'centrifugal-hooks upgs))))]
         [(banshee-cloak cloaking-field)
          (not (not (or (memq 'banshee-cloak upgs)
                        (memq 'cloaking-field upgs))))]
         [(psi-storm psionic-storm)
          (not (not (or (memq 'psi-storm upgs)
                        (memq 'psionic-storm upgs))))]
         [else (not (not (memq target-sym upgs)))])))

(define (normalize-unit-benchmark-sym sym)
  (case sym
    [(viking viking-assault)                       'viking-fighter]
    [(siege-tank-sieged)                           'siege-tank]
    [(widow-mine-burrowed)                         'widow-mine]
    [(thor-ap)                                     'thor]
    [(liberator-ag)                                'liberator]
    [(broodlord brood-lord-cocoon)                 'brood-lord]
    [(voidray)                                     'void-ray]
    [(lurker-mp lurker-burrowed lurker-mp-burrowed lurker-egg lurker-mp-egg) 'lurker]
    [(overseer-siege-mode overlord-cocoon)         'overseer]
    [(transport-overlord-cocoon)                   'overlord-transport]
    [else sym]))

(define (normalized-pro-unit-benchmarks race enemy-race raw-frame [active-bases 1])
  (define f (safe-nonneg-int raw-frame 0))
  (if (<= f 0)
      (hasheq)
      (for/fold ([ht (hasheq)]) ([(u cnt) (in-hash (pro-unit-benchmarks-at-frame race enemy-race f active-bases))])
        (define cu (normalize-unit-benchmark-sym u))
        (define c (safe-nonneg-int cnt 0))
        (if (> c 0)
            (hash-update ht cu (lambda (old) (+ old c)) 0)
            ht))))

(define *ledger-unit-equiv-uniq-cache* (make-hasheq))

(define (count-unit-in-hash ht sym)
  (define csym (normalize-unit-benchmark-sym sym))
  (cond
    [(not (hash? ht)) 0]
    [(eq? csym 'overlord-transport)
     (+ (safe-nonneg-int (hash-ref ht 'overlord-transport 0) 0)
        (safe-nonneg-int (hash-ref ht 'transport-overlord-cocoon 0) 0))]
    [else
     (define eqs
       (or (hash-ref *ledger-unit-equiv-uniq-cache* csym #f)
           (let ([lst (remove-duplicates (sc2-unit-equivalent-syms csym) eq?)])
             (hash-set! *ledger-unit-equiv-uniq-cache* csym lst)
             lst)))
     (for/sum ([s (in-list eqs)])
       (safe-nonneg-int (hash-ref ht s 0) 0))]))

(define (compute-benchmark-deficit-ratio sym bench-targets unit-counts-ht)
  (define csym (normalize-unit-benchmark-sym sym))
  (define tgt (if (hash? bench-targets) (safe-nonneg-int (hash-ref bench-targets csym 0) 0) 0))
  (if (<= tgt 0)
      0.0
      (let ([cur (count-unit-in-hash unit-counts-ht csym)])
        (if (>= cur tgt)
            0.0
            (min 1.0 (/ (exact->inexact (- tgt cur)) (exact->inexact tgt)))))))

(define (zerg-enemy-stargate-air-threat? enemy-u-counts enemy-b-counts enemy-race requires-aa?)
  (or (enemy-any-counts-have? enemy-u-counts enemy-b-counts
                              '(phoenix oracle stargate void-ray voidray carrier tempest))
      (and (eq? enemy-race 'Protoss) (eq? requires-aa? #t))))

(define (desired-zerg-queen-count active-bases [zvp-stargate-threat? #f] [early-aggro? #f])
  (define bases (max 1 (safe-nonneg-int active-bases 1)))
  (define threat-bonus (if (or zvp-stargate-threat? early-aggro?) 1 0))
  (define base-target
    (cond
      [(>= bases 3) (+ bases 3 (if zvp-stargate-threat? 1 0))]
      [(= bases 2)  (+ 4 threat-bonus)]
      [else         (+ 2 (if zvp-stargate-threat? 1 0))]))
  (min SC2-MAX-QUEENS-CAP base-target))

(define zerg-queen-target desired-zerg-queen-count)

(define (desired-zerg-overseer-count active-bases army-supply has-lair-or-hive? requires-detection?)
  (define bases (max 1 (safe-nonneg-int active-bases 1)))
  (define army (max 0.0 (safe-real army-supply 0.0)))
  (cond
    [(and has-lair-or-hive?
          (or (>= bases 3) requires-detection? (>= army 50.0)))
     3]
    [has-lair-or-hive? 2]
    [requires-detection? 1]
    [else 0]))

(define (desired-zerg-overlord-transport-count active-bases army-supply workers has-lair-or-hive? [under-attack? #f])
  (define bases (max 1 (safe-nonneg-int active-bases 1)))
  (define army (max 0.0 (safe-real army-supply 0.0)))
  (define w (safe-nonneg-int workers 0))
  (if (and has-lair-or-hive? (not under-attack?) (>= w 26) (>= army 16.0))
      (cond
        [(and (>= bases 3) (>= army 40.0)) 3]
        [(or (>= bases 3) (>= army 28.0)) 2]
        [else 1])
      0))

(define ZERG-HARASS-AIR-ENEMY-SYMS
  '(banshee liberator liberator-ag mutalisk oracle void-ray voidray phoenix
    warp-prism warp-prism-phasing medivac))

(define (zerg-enemy-air-spire-needed? enemy-u-counts enemy-b-counts enemy-race requires-aa?)
  (or (protoss-enemy-capital-air? enemy-u-counts)
      (enemy-any-counts-have? enemy-u-counts enemy-b-counts ZERG-HARASS-AIR-ENEMY-SYMS)
      (> (sc2-zerg-corruptor-target-cap enemy-u-counts requires-aa? enemy-race) 0)))

(define (zerg-enemy-capital-air-corruptor-cap enemy-u-counts requires-aa? enemy-race)
  (define base-cap (sc2-zerg-corruptor-target-cap enemy-u-counts requires-aa? enemy-race))
  (define cap-air-cnt
    (if (hash? enemy-u-counts)
        (for/sum ([s (in-list PROTOSS-CAPITAL-AIR-ENEMY-SYMS)])
          (safe-nonneg-int (hash-ref enemy-u-counts s 0) 0))
        0))
  (if (> cap-air-cnt 0)
      (max base-cap (min 20 (+ 12 (* 2 cap-air-cnt))))
      base-cap))

(define (desired-zerg-spore-count active-bases enemy-u-counts enemy-b-counts enemy-race requires-aa? requires-det?)
  (define bases (max 1 (safe-nonneg-int active-bases 1)))
  (cond
    [(enemy-any-counts-have? enemy-u-counts enemy-b-counts PROTOSS-CAPITAL-AIR-ENEMY-SYMS)
     (* 2 bases)]
    [(or (enemy-any-counts-have? enemy-u-counts enemy-b-counts ZERG-HARASS-AIR-ENEMY-SYMS)
         (zerg-enemy-stargate-air-threat? enemy-u-counts enemy-b-counts enemy-race requires-aa?))
     bases]
    [(or requires-aa? requires-det?) 1]
    [else 0]))

(define (protoss-enemy-fast-kiter-threat? enemy-u-counts)
  (or (>= (enemy-any-count enemy-u-counts #f 'reaper) 2)
      (>= (enemy-any-count enemy-u-counts #f 'cyclone) 1)))

(define (terran-enemy-cannon-contain? race enemy-race enemy-u-counts enemy-b-counts)
  (and (eq? race 'Terran)
       (or (eq? enemy-race 'Protoss)
           (enemy-any-counts-have? enemy-u-counts enemy-b-counts '(photon-cannon forge)))
       (enemy-any-counts-have? enemy-u-counts enemy-b-counts '(photon-cannon forge))))

(define (worker-recovery-after-cannon-or-contain?
         race enemy-race workers active-bases army-supply under-attack?
         enemy-threat-supply enemy-u-counts enemy-b-counts)
  (define w (safe-nonneg-int workers 0))
  (define bases (max 1 (safe-nonneg-int active-bases 1)))
  (define army (max 0.0 (safe-real army-supply 0.0)))
  (define threat (max 0.0 (safe-real enemy-threat-supply 0.0)))
  (define cannon? (terran-enemy-cannon-contain? race enemy-race enemy-u-counts enemy-b-counts))
  (define mobile-threat?
    (and (hash? enemy-u-counts)
         (for/or ([(ut cnt) (in-hash enemy-u-counts)])
           (and (> (safe-nonneg-int cnt 0) 0)
                (not (memq ut '(probe photon-cannon pylon forge nexus assimilator
                                gateway cybernetics-core shield-battery)))))))
  (and (eq? race 'Terran)
       (or cannon? (eq? enemy-race 'Protoss))
       (> w 0)
       (< w (min 44 (* 22 bases)))
       (or (and cannon? (or (>= army 2.0) (not mobile-threat?) (not under-attack?)))
           (and (not under-attack?)
                (< w 22)
                (<= threat (* 2.0 (max 4.0 army)))))))

(define (suppress-terran-extra-barracks-for-tvp-factory?
         race enemy-race cur-rax cur-fac cur-tanks minerals frame total-gas-bldgs gas
         enemy-u-counts enemy-b-counts)
  (define cannon? (terran-enemy-cannon-contain? race enemy-race enemy-u-counts enemy-b-counts))
  (and (eq? race 'Terran)
       (or cannon? (eq? enemy-race 'Protoss))
       (>= (safe-nonneg-int cur-rax 0) 1)
       (< (safe-nonneg-int minerals 0) 600)
       (or (and cannon?
                (or (= (safe-nonneg-int cur-fac 0) 0)
                    (< (safe-nonneg-int cur-tanks 0) 3)))
           (and (eq? enemy-race 'Protoss)
                (= (safe-nonneg-int cur-fac 0) 0)
                (or (> (safe-nonneg-int total-gas-bldgs 0) 0)
                    (>= (safe-nonneg-int gas 0) 50)
                    (>= (safe-nonneg-int frame 0) 1800))))))

(define (gas-building-cap active-bases)
  (* 2 (max 1 (safe-nonneg-int active-bases 1))))

(define (gas-building-cap-ok? cur-gas-bldgs active-bases)
  (< (safe-nonneg-int cur-gas-bldgs 0) (gas-building-cap active-bases)))

;; Mirrors runtime stepped Zerg Drone pause vs Terran/Protoss:
;; >38 Drones requires >=12 army supply, >46 requires >=22, >54 requires >=34.
(define (zerg-stepped-drone-army-floor race enemy-race workers)
  (define w (safe-nonneg-int workers 0))
  (if (and (eq? race 'Zerg) (memq enemy-race '(Terran Protoss)))
      (cond
        [(> w 54) 34.0]
        [(> w 46) 22.0]
        [(> w 38) 12.0]
        [else 0.0])
      0.0))

(define (zerg-worker-army-floor-ok? race enemy-race workers army-supply)
  (>= (max 0.0 (safe-real army-supply 0.0))
      (zerg-stepped-drone-army-floor race enemy-race workers)))

(define (zergling-target-cap minerals enemy-u-counts
                             #:workers [workers 0]
                             #:gas [gas 0]
                             #:enemy-b-counts [enemy-b-counts #f])
  (define m-val (safe-nonneg-int minerals 0))
  (define w-val (safe-nonneg-int workers 0))
  (define g-val (safe-nonneg-int gas 0))
  (cond
    [(or (enemy-counts-have-any? enemy-u-counts ZERG-SIEGE-SPLASH-ENEMY-SYMS)
         (and (hash? enemy-b-counts)
              (enemy-counts-have-any? enemy-b-counts
                                      '(bunker planetary-fortress photon-cannon spine-crawler))))
     20]
    [(and (>= w-val 58) (>= g-val 200))
     24]
    [(>= m-val 1500)
     120]
    [(>= w-val 58)
     24]
    [else 32]))

(define (terran-desired-barracks-techlabs race enemy-race barracks-cnt)
  (define r-cnt (safe-nonneg-int barracks-cnt 0))
  (cond
    [(<= r-cnt 0) 0]
    [(and (eq? race 'Terran) (memq enemy-race '(Terran Protoss)))
     (cond
       [(>= r-cnt 5) 3]
       [(>= r-cnt 3) 2]
       [else 1])]
    [else 1]))

(define (terran-desired-factories race enemy-race active-bases supply-used)
  (if (and (eq? race 'Terran)
           (eq? enemy-race 'Terran)
           (>= (safe-nonneg-int active-bases 1) 2)
           (>= (safe-nonneg-int supply-used 0) 68))
      2
      1))

(define (terran-enemy-needs-ghost? enemy-u-counts)
  (or (enemy-counts-have-any? enemy-u-counts TERRAN-GHOST-COUNTER-ENEMY-SYMS)
      (>= (+ (enemy-any-count enemy-u-counts #f 'queen)
             (enemy-any-count enemy-u-counts #f 'queen-burrowed))
          6)))

(define (terran-enemy-needs-liberator? enemy-u-counts)
  (enemy-counts-have-any? enemy-u-counts TERRAN-LIBERATOR-COUNTER-ENEMY-SYMS))

(define (terran-desired-ghost-cap active-bases supply-used enemy-race enemy-u-counts)
  (cond
    [(or (terran-enemy-needs-ghost? enemy-u-counts)
         (memq enemy-race '(Zerg Protoss Unknown)))
     10]
    [(>= (safe-nonneg-int active-bases 1) 4) 6]
    [(>= (safe-nonneg-int supply-used 0) 130) 4]
    [else 2]))

(define (terran-desired-liberator-cap active-bases enemy-u-counts)
  (define bases (max 1 (safe-nonneg-int active-bases 1)))
  (cond
    [(and (>= bases 4) (terran-enemy-needs-liberator? enemy-u-counts)) 8]
    [(and (>= bases 3) (terran-enemy-needs-liberator? enemy-u-counts)) 6]
    [(>= bases 4) 5]
    [else 3]))

(define CRISIS-DEFENDER-SYMS
  '(roach ravager queen spine-crawler
    immortal stalker zealot shield-battery
    marauder siege-tank bunker))

(define CRISIS-DEFERRED-UPGRADE-SYMS
  '(glial-reconstitution
    centrifical-hooks centrifugal-hooks
    grooved-spines muscular-augments
    burrow tunneling-claws
    pathogen-glands neural-parasite chitinous-plating anabolic-synthesis zergling-attackspeed
    zerg-melee-weapons-1 zerg-melee-weapons-2 zerg-melee-weapons-3 melee-attacks-1
    zerg-missile-weapons-1 zerg-missile-weapons-2 zerg-missile-weapons-3 missile-attacks-1
    zerg-ground-armor-1 zerg-ground-armor-2 zerg-ground-armor-3 ground-carapace-1 zerg-ground-carapace-1
    zerg-ground-armors-1 zerg-ground-armors-2 zerg-ground-armors-3
    zerg-flyer-weapons-1 zerg-flyer-weapons-2 zerg-flyer-weapons-3
    zerg-flyer-armor-1 zerg-flyer-armor-2 zerg-flyer-armor-3
    zerg-flyer-armors-1 zerg-flyer-armors-2 zerg-flyer-armors-3
    psi-storm psionic-storm
    extended-thermal-lance
    resonating-glaives gravitic-booster gravitic-boosters gravitic-drive
    protoss-ground-weapons-1 protoss-ground-weapons-2 protoss-ground-weapons-3 ground-weapons-1
    protoss-ground-armor-1 protoss-ground-armor-2 protoss-ground-armor-3 ground-armor-1
    protoss-ground-armors-1 protoss-ground-armors-2 protoss-ground-armors-3
    protoss-shields-1 protoss-shields-2 protoss-shields-3
    protoss-air-weapons-1 protoss-air-weapons-2 protoss-air-weapons-3
    protoss-air-armor-1 protoss-air-armor-2 protoss-air-armor-3
    protoss-air-armors-1 protoss-air-armors-2 protoss-air-armors-3
    banshee-cloak cloaking-field banshee-cloaking-field
    personal-cloaking
    drilling-claws smart-servos advanced-ballistics weapon-refit hyperflight-rotors
    terran-infantry-weapons-1 terran-infantry-weapons-2 terran-infantry-weapons-3 infantry-weapons-1
    terran-infantry-armor-1 terran-infantry-armor-2 terran-infantry-armor-3 infantry-armor-1
    terran-infantry-armors-1 terran-infantry-armors-2 terran-infantry-armors-3
    terran-vehicle-weapons-1 terran-vehicle-weapons-2 terran-vehicle-weapons-3 vehicle-weapons-1
    terran-vehicle-and-ship-plating-1 terran-vehicle-and-ship-plating-2 terran-vehicle-and-ship-plating-3
    terran-vehicle-and-ship-armors-1 terran-vehicle-and-ship-armors-2 terran-vehicle-and-ship-armors-3
    terran-ship-weapons-1 terran-ship-weapons-2 terran-ship-weapons-3))

(define CRISIS-DEFERRED-TECH-SYMS
  '(lair hive infestation-pit spire greater-spire ultralisk-cavern
    templar-archive templar-archives fleet-beacon dark-shrine robotics-bay
    fusion-core))

(define TERRAN-GROUND-AA-SCREEN-ENEMY-SYMS
  '(stalker hydralisk))

(define (crisis-defense-tech-defer-active? under-attack? army-supply enemy-threat-supply [workers 44])
  (and (eq? under-attack? #t)
       (let ([army (safe-real army-supply 0.0)]
             [threat (safe-real enemy-threat-supply 0.0)]
             [w (safe-nonneg-int workers 44)])
         (or (< army threat) (< w 32)))))

(define (crisis-deferred-sym? sym crisis-defer?
                              #:defer-stargate? [defer-stargate? #f]
                              #:keep-ship-weapons? [keep-ship-weapons? #f]
                              #:keep-spire-aa? [keep-spire-aa? #f]
                              #:keep-lair-aa? [keep-lair-aa? #f])
  (and (eq? crisis-defer? #t)
       (or (and (not (and keep-ship-weapons? (eq? sym 'terran-ship-weapons-1)))
                (not (and keep-spire-aa?
                          (memq sym '(zerg-flyer-armor-1 zerg-flyer-armors-1))))
                (not (not (memq sym CRISIS-DEFERRED-UPGRADE-SYMS))))
           (and (not (and keep-spire-aa? (eq? sym 'spire)))
                (not (and (or keep-lair-aa? keep-spire-aa?) (eq? sym 'lair)))
                (not (not (memq sym CRISIS-DEFERRED-TECH-SYMS))))
           (and defer-stargate? (eq? sym 'stargate)))))

(define (terran-enemy-ground-aa-count enemy-u-counts)
  (if (hash? enemy-u-counts)
      (+ (safe-nonneg-int (hash-ref enemy-u-counts 'stalker 0) 0)
         (safe-nonneg-int (hash-ref enemy-u-counts 'hydralisk 0) 0))
      0))

(define (terran-enemy-capital-air-with-ground-aa? enemy-u-counts)
  (and (protoss-enemy-capital-air? enemy-u-counts)
       (>= (terran-enemy-ground-aa-count enemy-u-counts) 6)))

(define (terran-desired-thor-cap enemy-u-counts)
  (cond
    [(terran-enemy-capital-air-with-ground-aa? enemy-u-counts) 6]
    [(protoss-enemy-capital-air? enemy-u-counts) 5]
    [else 0]))

(define (terran-air-fleet-count units-or-hash)
  (define air-syms '(viking-fighter viking viking-assault liberator liberator-ag battlecruiser))
  (cond
    [(hash? units-or-hash)
     (for/sum ([s (in-list air-syms)])
       (safe-nonneg-int (hash-ref units-or-hash s 0) 0))]
    [(list? units-or-hash)
     (count (lambda (u) (not (not (memq u air-syms)))) units-or-hash)]
    [else 0]))

(define (terran-ship-weapons-due? race air-fleet-cnt has-ready-armory? upgs)
  (and (eq? race 'Terran)
       (eq? has-ready-armory? #t)
       (>= (safe-nonneg-int air-fleet-cnt 0) 4)
       (list? upgs)
       (not (memq 'terran-ship-weapons-1 upgs))))

(define (protoss-enemy-capital-air? enemy-u-counts)
  (enemy-counts-have-any? enemy-u-counts PROTOSS-CAPITAL-AIR-ENEMY-SYMS))

(define (protoss-4th-nexus-due? race active-bases workers army-supply minerals enemy-capital-air?
                                #:has-tech? [has-tech? 'unspecified])
  (define army (max 0.0 (safe-real army-supply 0.0)))
  (define mins (safe-nonneg-int minerals 0))
  (and (eq? race 'Protoss)
       (= (safe-nonneg-int active-bases 1) 3)
       (>= (safe-nonneg-int workers 0) 54)
       (if (eq? has-tech? 'unspecified)
           ;; Legacy 6-arg synthetic test compatibility (`tests/run-all-tests.rkt:10332`)
           (or (>= army 12.0)
               (>= mins 500)
               (eq? enemy-capital-air? #t))
           ;; W4-P0-1a: require >= 1 mid-tier tech facility AND (>= 28 army OR (>= 22 army & >= 650M))
           (and (eq? has-tech? #t)
                (or (>= army 28.0)
                    (and (>= army 22.0) (>= mins 650)))))))

(define (enrich-priority-metrics
         base-metrics
         #:race race
         #:enemy-race [raw-enemy-race 'Unknown]
         #:minerals [raw-minerals 0]
         #:active-bases [raw-active-bases 1]
         #:under-attack? [raw-under-attack? #f]
         #:requires-anti-air? [raw-requires-anti-air? #f]
         #:army-supply [raw-army-supply 0.0]
         #:enemy-threat-supply [raw-enemy-threat-supply 0.0]
         #:workers [raw-workers 44]
         #:has-barracks-techlab? [has-rax-tl? #f]
         #:has-twilight-or-charge? [has-twilight-or-charge? #f]
         #:has-hydralisk-den? [has-hydralisk-den? #f]
         #:has-robo? [has-robo? #f]
         #:has-armory? [has-armory? #f]
         #:crisis-defense-defer? [raw-crisis-defer? 'auto]
         #:enemy-capital-air-ground-aa? [raw-cap-air-ground-aa? 'auto]
         #:terran-ship-weapons-due? [ship-weap-due? #f]
         #:stalker-count [stalker-count 0]
         #:roach-count [roach-count 0]
         #:enemy-unit-counts [enemy-u-counts #f]
         #:enemy-building-counts [enemy-b-counts #f]
         #:benchmark-targets [benchmark-targets #f]
         #:unit-counts [unit-counts-ht #f]
         #:bo-goal-sym [bo-goal-sym #f]
         #:strategic-goals [strategic-goals #f])
  (define enemy-race (normalize-enemy-race-sym raw-enemy-race))
  (let* ([m (hash-set base-metrics 'race race)]
         [m (hash-set m 'enemy-race enemy-race)]
         [m (hash-set m 'minerals (safe-nonneg-int raw-minerals 0))]
         [m (hash-set m 'requires-anti-air? (eq? raw-requires-anti-air? #t))]
         [m (hash-set m 'active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))]
         [m (hash-set m 'under-attack? (eq? raw-under-attack? #t))]
         [m (hash-set m 'army-supply (max 0.0 (safe-real raw-army-supply 0.0)))]
         [m (hash-set m 'enemy-threat-supply (max 0.0 (safe-real raw-enemy-threat-supply 0.0)))]
         [m (hash-set m 'has-barracks-techlab? (not (not has-rax-tl?)))]
         [m (hash-set m 'has-twilight-or-charge? (not (not has-twilight-or-charge?)))]
         [m (hash-set m 'has-hydralisk-den? (not (not has-hydralisk-den?)))]
         [m (hash-set m 'stalker-count (safe-nonneg-int stalker-count 0))]
         [m (hash-set m 'roach-count (safe-nonneg-int roach-count 0))]
         [crisis-defer?
          (if (eq? raw-crisis-defer? 'auto)
              (crisis-defense-tech-defer-active?
               raw-under-attack? raw-army-supply raw-enemy-threat-supply raw-workers)
              (eq? raw-crisis-defer? #t))]
         [cap-air-ground-aa?
          (if (eq? raw-cap-air-ground-aa? 'auto)
              (terran-enemy-capital-air-with-ground-aa? enemy-u-counts)
              (eq? raw-cap-air-ground-aa? #t))]
         [m (hash-set m 'enemy-capital-air? (protoss-enemy-capital-air? enemy-u-counts))]
         [m (hash-set m 'keep-spire-aa?
                      (and (eq? race 'Zerg)
                           (zerg-enemy-air-spire-needed? enemy-u-counts enemy-b-counts enemy-race raw-requires-anti-air?)))]
         [m (hash-set m 'enemy-needs-ghost? (terran-enemy-needs-ghost? enemy-u-counts))]
         [m (hash-set m 'enemy-needs-liberator? (terran-enemy-needs-liberator? enemy-u-counts))]
         [m (hash-set m 'zvp-stargate-threat?
                      (and (eq? race 'Zerg)
                           (zerg-enemy-stargate-air-threat? enemy-u-counts enemy-b-counts enemy-race raw-requires-anti-air?)))]
         [m (hash-set m 'pvt-fast-kiter-threat?
                      (and (eq? race 'Protoss)
                           (protoss-enemy-fast-kiter-threat? enemy-u-counts)))]
         [m (hash-set m 'tvp-cannon-contain?
                      (terran-enemy-cannon-contain? race enemy-race enemy-u-counts enemy-b-counts))]
         [m (hash-set m 'benchmark-targets (if (hash? benchmark-targets) benchmark-targets (hasheq)))]
         [m (hash-set m 'unit-counts (if (hash? unit-counts-ht) unit-counts-ht (hasheq)))]
         [m (hash-set m 'has-robo? (eq? has-robo? #t))]
         [m (hash-set m 'has-armory? (eq? has-armory? #t))]
         [m (hash-set m 'crisis-defense-defer? crisis-defer?)]
         [m (hash-set m 'enemy-capital-air-ground-aa? cap-air-ground-aa?)]
         [m (hash-set m 'terran-ship-weapons-due? (eq? ship-weap-due? #t))]
         [m (if (hash? strategic-goals)
                (hash-set* m
                           'strategic-unit-boosts (hash-ref strategic-goals 'recommended-units (hasheq))
                           'strategic-suppressed-units (hash-ref strategic-goals 'suppressed-units '())
                           'upgrade-priority-multiplier (safe-real (hash-ref strategic-goals 'upgrade-priority-multiplier 1.0) 1.0)
                           'depleting-bases (safe-nonneg-int (hash-ref strategic-goals 'depleting-bases 0) 0)
                           'high-bank-macro-inject? (eq? (hash-ref strategic-goals 'high-bank-macro-inject? #f) #t))
                m)])
    (if bo-goal-sym
        (hash-set m 'bo-goal-sym bo-goal-sym)
        m)))

(struct unpacked-utility-metrics
  (m-race
   m-enemy-race
   supply-cap
   pending-supply
   supply-left
   supply-buffer
   supply-hazard
   supply-at-risk?
   threat-pressure
   intel-pressure
   army-supply
   enemy-threat-supply
   under-attack?
   minerals
   gas
   has-rax-tl?
   has-twilight-or-charge?
   has-hydralisk-den?
   pvz-stalker-count
   roach-cnt
   enemy-capital-air?
   enemy-cap-air-ground-aa?
   enemy-needs-ghost?
   enemy-needs-liberator?
   zvp-stargate-threat?
   pvt-fast-kiter-threat?
   tvp-cannon-contain?
   benchmark-targets
   has-bench-targets?
   unit-counts-ht
   has-robo?
   has-armory?
   crisis-defer?
   ship-weapons-due?
   gas-imbalance
   worker-saturation-gap
   facility-scaling-pressure
   expansion-desire
   workers
   active-bases
   escrow-eligible?
   requires-anti-air?
   requires-detection?
   bo-goal-sym
   defer-stargate-here?
   keep-spire-aa?
   severe-crisis-static-def?
   under-threat?
   gas-sink-active?
   supply-urgent?
   outnumbered-by-threat?
   bo-head-boost-val
   zerg-cap-air?
   terran-ghost-matchup?
   cannon-worker-recover?
   light-non-overrun-threat?)
  #:transparent)

(define *last-um-hash* #f)
(define *last-um-val* #f)

(define (unpack-utility-metrics m)
  (define supply-cap (safe-nonneg-int (hash-ref m 'supply-cap 15) 15))
  (define pending-supply (safe-nonneg-int (hash-ref m 'pending-supply 0) 0))
  (define supply-left (safe-exact-int (hash-ref m 'supply-left 4) 4))
  (define supply-buffer (safe-real (hash-ref m 'supply-buffer (+ 2.0 (* 0.06 supply-cap))) 4.0))
  (define supply-hazard (safe-real (hash-ref m 'supply-hazard 0.0) 0.0))
  (define supply-at-risk? (eq? (hash-ref m 'supply-at-risk? #f) #t))
  (define threat-pressure (safe-real (hash-ref m 'threat-pressure 0.0) 0.0))
  (define intel-pressure (safe-real (hash-ref m 'intel-pressure 0.0) 0.0))
  (define army-supply (safe-real (hash-ref m 'army-supply 0.0) 0.0))
  (define enemy-threat-supply (safe-real (hash-ref m 'enemy-threat-supply 0.0) 0.0))
  (define under-attack? (eq? (hash-ref m 'under-attack? #f) #t))
  (define minerals (safe-nonneg-int (hash-ref m 'minerals 0) 0))
  (define gas (safe-nonneg-int (hash-ref m 'gas 0) 0))
  (define m-race (hash-ref m 'race 'Unknown))
  (define m-enemy-race (hash-ref m 'enemy-race 'Unknown))
  (define has-rax-tl? (hash-ref m 'has-barracks-techlab? #f))
  (define has-twilight-or-charge? (hash-ref m 'has-twilight-or-charge? #f))
  (define has-hydralisk-den? (hash-ref m 'has-hydralisk-den? #f))
  (define pvz-stalker-count (safe-nonneg-int (hash-ref m 'stalker-count 0) 0))
  (define roach-cnt (safe-nonneg-int (hash-ref m 'roach-count 0) 0))
  (define enemy-capital-air? (eq? (hash-ref m 'enemy-capital-air? #f) #t))
  (define enemy-cap-air-ground-aa? (eq? (hash-ref m 'enemy-capital-air-ground-aa? #f) #t))
  (define enemy-needs-ghost? (eq? (hash-ref m 'enemy-needs-ghost? #f) #t))
  (define enemy-needs-liberator? (eq? (hash-ref m 'enemy-needs-liberator? #f) #t))
  (define zvp-stargate-threat? (eq? (hash-ref m 'zvp-stargate-threat? #f) #t))
  (define pvt-fast-kiter-threat? (eq? (hash-ref m 'pvt-fast-kiter-threat? #f) #t))
  (define tvp-cannon-contain? (eq? (hash-ref m 'tvp-cannon-contain? #f) #t))
  (define benchmark-targets (hash-ref m 'benchmark-targets #f))
  (define has-bench-targets? (and (hash? benchmark-targets) (> (hash-count benchmark-targets) 0)))
  (define unit-counts-ht (hash-ref m 'unit-counts #f))
  (define has-robo? (eq? (hash-ref m 'has-robo? #f) #t))
  (define has-armory? (eq? (hash-ref m 'has-armory? #f) #t))
  (define crisis-defer? (eq? (hash-ref m 'crisis-defense-defer? #f) #t))
  (define ship-weapons-due? (eq? (hash-ref m 'terran-ship-weapons-due? #f) #t))
  (define gas-imbalance (safe-real (hash-ref m 'gas-imbalance 0.0) 0.0))
  (define worker-saturation-gap (safe-real (hash-ref m 'worker-saturation-gap 0.5) 0.5))
  (define facility-scaling-pressure (safe-real (hash-ref m 'facility-scaling-pressure 0.2) 0.2))
  (define expansion-desire (safe-real (hash-ref m 'expansion-desire 0.0) 0.0))
  (define workers (safe-nonneg-int (hash-ref m 'workers 12) 12))
  (define active-bases (max 1 (safe-nonneg-int (hash-ref m 'active-bases 1) 1)))
  (define escrow-eligible? (eq? (hash-ref m 'escrow-eligible? #f) #t))
  (define requires-anti-air? (eq? (hash-ref m 'requires-anti-air? #f) #t))
  (define requires-detection? (eq? (hash-ref m 'requires-detection? #f) #t))
  (define bo-goal-sym (hash-ref m 'bo-goal-sym #f))
  (define defer-stargate-here?
    (or has-robo? (and (not requires-anti-air?) (not enemy-capital-air?))))
  (define keep-spire-aa?
    (or (eq? (hash-ref m 'keep-spire-aa? #f) #t)
        (and (eq? m-race 'Zerg) enemy-capital-air?)))
  (define severe-crisis-static-def?
    (and crisis-defer?
         (or (>= army-supply 4.0) (>= minerals 200))
         (or (< workers 32)
             (< army-supply (* 0.8 enemy-threat-supply))
             (< army-supply 16.0))))
  (define under-threat?
    (or under-attack?
        (>= threat-pressure 1.0)
        (> enemy-threat-supply 0.0)))
  (define gas-sink-active?
    (and (>= gas 100) (>= gas-imbalance 1.5)))
  (define eff-supply (+ (exact->inexact supply-left) (* 8.0 (exact->inexact pending-supply))))
  (define supply-urgent?
    (and (< supply-cap 200)
         (or (> supply-hazard 0.0)
             (supply-preemption-needed? (- supply-cap supply-left) supply-cap pending-supply #:race m-race)
             (and supply-at-risk? (< pending-supply 2) (<= eff-supply (+ supply-buffer 6.0)))
             (and (= pending-supply 0) (<= supply-left supply-buffer)))))
  (define outnumbered-by-threat?
    (and (> enemy-threat-supply 0.0)
         (< army-supply (* 1.2 enemy-threat-supply))))
  (define bo-head-boost-val
    (if under-attack?
        0.0
        (/ 42.0 (+ 1.0 (* 0.5 threat-pressure)))))
  (define zerg-cap-air? (and (eq? m-race 'Zerg) enemy-capital-air?))
  (define terran-ghost-matchup?
    (and (eq? m-race 'Terran)
         (or enemy-needs-ghost? (not (not (memq m-enemy-race '(Zerg Protoss)))))))
  (define cannon-worker-recover?
    (and (eq? m-race 'Terran)
         (or tvp-cannon-contain? (eq? m-enemy-race 'Protoss))
         (> workers 0)
         (< workers (min 44 (* 22 active-bases)))
         (or (and tvp-cannon-contain? (or (>= army-supply 2.0) (not under-attack?)))
             (and (not under-attack?) (< workers 22)))))
  (define light-non-overrun-threat?
    (and (not under-attack?)
         (<= enemy-threat-supply (* 1.65 (max 6.0 army-supply)))))
  (unpacked-utility-metrics
   m-race m-enemy-race
   supply-cap pending-supply supply-left supply-buffer supply-hazard supply-at-risk?
   threat-pressure intel-pressure army-supply enemy-threat-supply under-attack?
   minerals gas has-rax-tl? has-twilight-or-charge? has-hydralisk-den?
   pvz-stalker-count roach-cnt enemy-capital-air? enemy-cap-air-ground-aa?
   enemy-needs-ghost? enemy-needs-liberator? zvp-stargate-threat?
   pvt-fast-kiter-threat? tvp-cannon-contain? benchmark-targets has-bench-targets?
   unit-counts-ht has-robo? has-armory? crisis-defer? ship-weapons-due?
   gas-imbalance worker-saturation-gap facility-scaling-pressure expansion-desire
   workers active-bases escrow-eligible? requires-anti-air? requires-detection?
   bo-goal-sym defer-stargate-here? keep-spire-aa? severe-crisis-static-def?
   under-threat? gas-sink-active? supply-urgent? outnumbered-by-threat?
   bo-head-boost-val zerg-cap-air? terran-ghost-matchup?
   cannon-worker-recover? light-non-overrun-threat?))

(define (get-unpacked-utility-metrics m)
  (cond
    [(and (immutable? m) (eq? m *last-um-hash*))
     *last-um-val*]
    [else
     (define um (unpack-utility-metrics m))
     (when (immutable? m)
       (set! *last-um-hash* m)
       (set! *last-um-val* um))
     um]))

(define (compute-candidate-marginal-utility cand metrics)
  (define m (if (hash? metrics) metrics (compute-state-pressure-metrics)))
  (define um (get-unpacked-utility-metrics m))
  (define id (priority-candidate-id cand))
  (define cat (priority-candidate-category cand))
  (define m-cost (safe-nonneg-int (priority-candidate-min-cost cand) 0))
  (define g-cost (safe-nonneg-int (priority-candidate-gas-cost cand) 0))
  (define strat-boosts (hash-ref m 'strategic-unit-boosts #f))
  (define strat-unit-adj
    (if (hash? strat-boosts)
        (safe-real (hash-ref strat-boosts id 0.0) 0.0)
        0.0))
  (define strat-suppressed?
    (let ([sups (hash-ref m 'strategic-suppressed-units #f)])
      (and (list? sups) (not (not (memq id sups))))))
  (define strat-upg-mult
    (max 1.0 (safe-real (hash-ref m 'upgrade-priority-multiplier 1.0) 1.0)))
  (define strat-depleting-bases (safe-nonneg-int (hash-ref m 'depleting-bases 0) 0))
  (define strat-high-bank-inject? (eq? (hash-ref m 'high-bank-macro-inject? #f) #t))

  (define m-race (unpacked-utility-metrics-m-race um))
  (define m-enemy-race (unpacked-utility-metrics-m-enemy-race um))
  (define supply-cap (unpacked-utility-metrics-supply-cap um))
  (define supply-hazard (unpacked-utility-metrics-supply-hazard um))
  (define threat-pressure (unpacked-utility-metrics-threat-pressure um))
  (define intel-pressure (unpacked-utility-metrics-intel-pressure um))
  (define army-supply (unpacked-utility-metrics-army-supply um))
  (define enemy-threat-supply (unpacked-utility-metrics-enemy-threat-supply um))
  (define under-attack? (unpacked-utility-metrics-under-attack? um))
  (define minerals (unpacked-utility-metrics-minerals um))
  (define gas (unpacked-utility-metrics-gas um))
  (define has-rax-tl? (unpacked-utility-metrics-has-rax-tl? um))
  (define has-twilight-or-charge? (unpacked-utility-metrics-has-twilight-or-charge? um))
  (define has-hydralisk-den? (unpacked-utility-metrics-has-hydralisk-den? um))
  (define pvz-stalker-count (unpacked-utility-metrics-pvz-stalker-count um))
  (define roach-cnt (unpacked-utility-metrics-roach-cnt um))
  (define enemy-capital-air? (unpacked-utility-metrics-enemy-capital-air? um))
  (define enemy-cap-air-ground-aa? (unpacked-utility-metrics-enemy-cap-air-ground-aa? um))
  (define enemy-needs-ghost? (unpacked-utility-metrics-enemy-needs-ghost? um))
  (define enemy-needs-liberator? (unpacked-utility-metrics-enemy-needs-liberator? um))
  (define zvp-stargate-threat? (unpacked-utility-metrics-zvp-stargate-threat? um))
  (define pvt-fast-kiter-threat? (unpacked-utility-metrics-pvt-fast-kiter-threat? um))
  (define tvp-cannon-contain? (unpacked-utility-metrics-tvp-cannon-contain? um))
  (define benchmark-targets (unpacked-utility-metrics-benchmark-targets um))
  (define has-bench-targets? (unpacked-utility-metrics-has-bench-targets? um))
  (define unit-counts-ht (unpacked-utility-metrics-unit-counts-ht um))
  (define bench-def-ratio
    (if has-bench-targets?
        (compute-benchmark-deficit-ratio id benchmark-targets unit-counts-ht)
        0.0))
  (define bench-deficit-boost
    (cond
      [(<= bench-def-ratio 0.0) 0.0]
      [(and pvt-fast-kiter-threat? (eq? id 'zealot)) 0.0]
      [else
       (+ (* 18.0 bench-def-ratio)
          (if (= (count-unit-in-hash unit-counts-ht id) 0) 14.0 0.0))]))
  (define has-armory? (unpacked-utility-metrics-has-armory? um))
  (define crisis-defer? (unpacked-utility-metrics-crisis-defer? um))
  (define ship-weapons-due? (unpacked-utility-metrics-ship-weapons-due? um))
  (define gas-imbalance (unpacked-utility-metrics-gas-imbalance um))
  (define worker-saturation-gap (unpacked-utility-metrics-worker-saturation-gap um))
  (define facility-scaling-pressure (unpacked-utility-metrics-facility-scaling-pressure um))
  (define expansion-desire (unpacked-utility-metrics-expansion-desire um))
  (define workers (unpacked-utility-metrics-workers um))
  (define active-bases (unpacked-utility-metrics-active-bases um))
  (define escrow-eligible? (unpacked-utility-metrics-escrow-eligible? um))
  (define requires-anti-air? (unpacked-utility-metrics-requires-anti-air? um))
  (define requires-detection? (unpacked-utility-metrics-requires-detection? um))
  (define bo-goal-sym (unpacked-utility-metrics-bo-goal-sym um))
  (define defer-stargate-here? (unpacked-utility-metrics-defer-stargate-here? um))
  (define keep-spire-aa? (unpacked-utility-metrics-keep-spire-aa? um))
  (define crisis-deferred-here?
    (and crisis-defer?
         (crisis-deferred-sym? id #t
                               #:defer-stargate? defer-stargate-here?
                               #:keep-ship-weapons? ship-weapons-due?
                               #:keep-spire-aa? keep-spire-aa?)))
  (define crisis-defender-here?
    (and crisis-defer? (>= workers 8) (not (not (memq id CRISIS-DEFENDER-SYMS)))))
  (define severe-crisis-static-def? (unpacked-utility-metrics-severe-crisis-static-def? um))
  (define under-threat? (unpacked-utility-metrics-under-threat? um))
  (define gas-sink-active? (unpacked-utility-metrics-gas-sink-active? um))
  (define supply-urgent? (unpacked-utility-metrics-supply-urgent? um))
  (define outnumbered-by-threat? (unpacked-utility-metrics-outnumbered-by-threat? um))

  ;; PV5 boost (+ 180.0) split cleanly between anti-air vs detection roles:
  ;; pure detectors (`observer`, `overseer`, `raven`) match `requires-detection?`,
  ;; pure AA units/tech (`viking-fighter`, `corruptor`, `stalker`, `hydralisk-den`) match `requires-anti-air?`,
  ;; and multi-role static defense (`missile-turret`, `photon-cannon`, `spore-crawler`) matches both.
  (define matches-aa-counter?
    (and requires-anti-air?
         (or (not (not (memq id PV5-ANTI-AIR-SYMS)))
             (and (eq? cat 'counter-tech)
                  (not (memq id PV5-PURE-DETECTOR-SYMS))))))
  (define matches-det-counter?
    (and requires-detection?
         (or (not (not (memq id PV5-DETECTOR-SYMS)))
             (and (eq? cat 'counter-tech)
                  (not (memq id PV5-PURE-ANTI-AIR-SYMS))))))
  (define active-counter-match?
    (or matches-aa-counter? matches-det-counter?))
  (define pv5-boost
    (if active-counter-match?
        (+ 180.0 (if (and matches-aa-counter? matches-det-counter?) 20.0 0.0))
        0.0))

  ;; Information-Gathering Boost (PV9): when opponent intel is stale (`intel-pressure > 0.0`),
  ;; boost units/tech that gather opponent information via scouting, harassment, or probing attack.
  (define intel-gathering-boost
    (cond
      [(<= intel-pressure 0.0) 0.0]
      [(memq id '(observer overseer sentry oracle reaper hellion adept phoenix mutalisk banshee warp-prism medivac))
       (* 65.0 intel-pressure)]
      [(memq id PV-INTEL-GATHERING-UNIT-SYMS)
       (* 42.0 intel-pressure)]
      [else 0.0]))

  ;; General Build-Order Alignment Boost: when the candidate matches the active
  ;; head of the Pro Build Order queue (`bo-goal-sym`), boost its marginal utility
  ;; in proportion to `1 / (1 + 0.5 * threat-pressure)` (and 0 under emergency attack).
  (define bo-head-boost
    (if (and bo-goal-sym (eq? id bo-goal-sym))
        (unpacked-utility-metrics-bo-head-boost-val um)
        0.0))

  (case cat
    [(supply)
     (if supply-urgent?
         (+ 1200.0 (* 300.0 (max 0.1 supply-hazard)))
         12.0)]

    [(intel-gathering)
     (if (>= intel-pressure 1.0)
         (+ 215.0 (* 65.0 intel-pressure) bo-head-boost)
         (+ 55.0 (* 95.0 intel-pressure) bo-head-boost))]

    [(counter-tech)
     (define active-counter-need?
       (or active-counter-match?
           (and zvp-stargate-threat? (memq id '(spore-crawler queen hydralisk-den)))
           (and (eq? m-race 'Zerg) enemy-capital-air?
                (memq id '(spore-crawler queen spire corruptor hydralisk-den hydralisk zerg-flyer-armor-1)))
           (and pvt-fast-kiter-threat? (eq? id 'shield-battery))
           (and tvp-cannon-contain? (eq? id 'factory-techlab))))
     (define counter-matchup-adj
       (cond
         [(and (eq? m-race 'Zerg) enemy-capital-air? (eq? id 'spore-crawler)) 52.0]
         [(and (eq? m-race 'Zerg) enemy-capital-air? (memq id '(queen spire corruptor zerg-flyer-armor-1))) 48.0]
         [(and zvp-stargate-threat? (eq? id 'spore-crawler)) 48.0]
         [(and zvp-stargate-threat? (memq id '(queen hydralisk-den))) 42.0]
         [(and pvt-fast-kiter-threat? (eq? id 'shield-battery)) 45.0]
         [(and tvp-cannon-contain? (eq? id 'factory-techlab)) 48.0]
         [(and (eq? m-race 'Terran) (eq? m-enemy-race 'Terran) (eq? id 'viking-fighter)) 26.0]
         [(and (eq? m-race 'Terran) (eq? m-enemy-race 'Terran) (eq? id 'factory-techlab)) 28.0]
         [(and (eq? m-race 'Terran) enemy-capital-air? (eq? id 'viking-fighter)) 24.0]
         [else 0.0]))
     (define threat-boost
       (cond
         [(and active-counter-need? under-threat?)
          (+ 135.0 (* 45.0 (min 4.0 threat-pressure)))]
         [active-counter-need?
          (* 30.0 (min 4.0 threat-pressure))]
         [under-threat?
          (+ 28.0 (* 12.0 (min 4.0 threat-pressure)))]
         [else
          (* 8.0 (min 3.0 threat-pressure))]))
     (define counter-crisis-adj
       (if (and crisis-defender-here?
                (or severe-crisis-static-def?
                    (not (memq id '(spine-crawler shield-battery bunker)))))
           (if (memq id '(spine-crawler shield-battery bunker)) 85.0 45.0)
           0.0))
     (define raw-counter-u
       (+ (if active-counter-need? 138.0 118.0) pv5-boost intel-gathering-boost threat-boost counter-matchup-adj counter-crisis-adj bench-deficit-boost bo-head-boost strat-unit-adj))
     (cond
       [(or crisis-deferred-here? strat-suppressed?) 5.0]
       [(and (memq id '(spine-crawler shield-battery bunker))
             (< army-supply 4.0)
             (< minerals 200)
             (not (and pvt-fast-kiter-threat? (eq? id 'shield-battery))))
        (min 120.0 raw-counter-u)]
       [else raw-counter-u])]

    [(combat-unit)
     (define gas-unit?
       (or (> g-cost 0)
           (memq id PV3-GAS-COMBAT-UNIT-SYMS)))
     (define mineral-only-unit?
       (and (not gas-unit?)
            (or (= g-cost 0)
                (memq id PV3-MINERAL-ONLY-COMBAT-UNIT-SYMS))))
     ;; Continuous tech-tier & resource-value gradient for gas-bearing units:
     ;; higher-tier units with open facility slots (e.g. Colossus > Immortal > Stalker > Zealot;
     ;; Siege Tank > Medivac > Marauder > Marine; Hydralisk > Roach > Zergling) naturally outrank
     ;; lower-tier mineral dumps without any unit-specific special cases.
     (define tech-tier-gradient
       (if gas-unit?
           (min 16.0 (+ (* 0.025 (exact->inexact m-cost))
                        (* 0.075 (exact->inexact g-cost))))
           0.0))
     (define base-combat
       (if gas-unit? (+ 122.0 tech-tier-gradient) 108.0))
     (define threat-boost
       (cond
         [under-attack?
          (+ 165.0 (* 45.0 (min 4.0 threat-pressure)))]
         [under-threat?
          (+ 115.0 (* 35.0 (min 4.0 threat-pressure)))]
         [else
          (* 25.0 threat-pressure)]))
     (define gas-sink-adj
       (cond
         [(and gas-sink-active? gas-unit?)
          (+ 165.0 (* 25.0 (min 4.0 gas-imbalance)))]
         [(and gas-sink-active? mineral-only-unit?)
          -20.0]
         [else 0.0]))
     (define matchup-unit-adj
       (+
        (cond
          [(and (eq? m-race 'Protoss) (eq? m-enemy-race 'Zerg))
           (case id
             [(colossus) 35.0]
             [(immortal) 32.0]
             [(archon) 30.0]
             [(high-templar) 22.0]
             [(zealot) (if (or has-twilight-or-charge? (>= army-supply 4.0) (>= pvz-stalker-count 2))
                           26.0
                           14.0)]
             [(stalker) (if (and (not requires-anti-air?) (not enemy-capital-air?) (>= pvz-stalker-count 3)) -25.0 0.0)]
             [else 0.0])]
          [(and (eq? m-race 'Terran) (eq? m-enemy-race 'Protoss) (eq? id 'marauder) has-rax-tl?)
           34.0]
          [(and (eq? m-race 'Terran) (eq? m-enemy-race 'Terran))
           (case id
             [(siege-tank) 38.0]
             [(marauder) (if has-rax-tl? 32.0 18.0)]
             [(medivac) 24.0]
             [(liberator) 18.0]
             [(marine) 8.0]
             [else 0.0])]
          [else 0.0])
        (if (and (eq? m-race 'Terran) (eq? id 'ghost) (or enemy-needs-ghost? (memq m-enemy-race '(Zerg Protoss))))
            48.0
            0.0)
        (if (and (eq? m-race 'Terran) (eq? id 'liberator) enemy-needs-liberator?)
            38.0
            0.0)
        (if (and (eq? m-race 'Protoss) enemy-capital-air?)
            (case id
              [(tempest) 68.0]
              [(void-ray) 56.0]
              [(stalker) 38.0]
              [(carrier) 24.0]
              [else 0.0])
            0.0)
        (if (and (eq? m-race 'Zerg) (eq? id 'roach) (>= minerals 300) (< roach-cnt 16))
            (if has-hydralisk-den? 1.5 20.0)
            0.0)
        (if (and (eq? m-race 'Zerg) (memq id '(ultralisk brood-lord)) (memq m-enemy-race '(Terran Protoss)))
            12.0
            0.0)
        (if (and (eq? m-race 'Terran) (memq id '(thor thor-ap)) enemy-capital-air?)
            (if enemy-cap-air-ground-aa? 135.0 105.0)
            0.0)
        (if (and (eq? m-race 'Terran) (memq id '(viking viking-fighter)) enemy-capital-air?)
            45.0
            0.0)
        (if (and (eq? m-race 'Zerg) zvp-stargate-threat? (eq? id 'hydralisk))
            46.0
            0.0)
        (if (and (eq? m-race 'Zerg) enemy-capital-air?)
            (case id
              [(corruptor) 58.0]
              [(hydralisk) 42.0]
              [else 0.0])
            0.0)
        (if (and (eq? m-race 'Protoss) pvt-fast-kiter-threat?)
            (case id
              [(stalker) 48.0]
              [(adept) 38.0]
              [(zealot) -160.0]
              [else 0.0])
            0.0)
        (if (and (eq? m-race 'Terran) tvp-cannon-contain? (eq? id 'siege-tank))
            54.0
            0.0)
        (if crisis-defender-here?
            (if (and (eq? id 'zealot) (eq? m-race 'Protoss) (or (>= gas 100) pvt-fast-kiter-threat?))
                (if pvt-fast-kiter-threat? 0.0 30.0)
                65.0)
            0.0)))
     (cond
       [(or crisis-deferred-here? strat-suppressed?) 5.0]
       [(and (eq? m-race 'Protoss) pvt-fast-kiter-threat? (eq? id 'zealot))
        (min 20.0 (+ base-combat matchup-unit-adj))]
       [else
        (+ base-combat threat-boost gas-sink-adj matchup-unit-adj strat-unit-adj pv5-boost intel-gathering-boost bench-deficit-boost bo-head-boost)])]

    [(tech-upgrade)
     (define gas-ready-boost
       (if (and (>= gas 100) (not outnumbered-by-threat?)) 45.0 0.0))
     (define threat-research-boost
       (if (and under-threat? (not under-attack?) (not outnumbered-by-threat?) (>= gas 100))
           (+ 110.0 (* 32.0 (min 4.0 threat-pressure)))
           0.0))
     (define gas-sink-boost
       (if gas-sink-active?
           (if outnumbered-by-threat?
               45.0
               (+ 165.0 (* 25.0 (min 4.0 gas-imbalance))))
           (if outnumbered-by-threat?
               0.0
               (* 15.0 (min 2.0 gas-imbalance)))))
     (define tech-matchup-adj
       (+ (if (and (eq? m-race 'Terran) (eq? id 'ghost-academy) (or enemy-needs-ghost? (eq? m-enemy-race 'Zerg))) 55.0 0.0)
          (if (and (eq? m-race 'Terran) (eq? id 'armory) enemy-capital-air?
                   (or enemy-cap-air-ground-aa? has-armory? (>= gas 80)))
              (if enemy-cap-air-ground-aa? 95.0 60.0)
              0.0)
          (if (and (eq? m-race 'Terran) (eq? id 'terran-ship-weapons-1) ship-weapons-due?) 90.0 0.0)
          (if (and (eq? m-race 'Zerg) enemy-capital-air?)
              (case id
                [(spire) 85.0]
                [(zerg-flyer-armor-1) 65.0]
                [else 0.0])
              0.0)
          (if (and (eq? m-race 'Protoss) enemy-capital-air? (eq? id 'fleet-beacon)) 65.0 0.0)))
     (define eff-bo-boost (if outnumbered-by-threat? 0.0 bo-head-boost))
     (define upg-escalation-bonus
       (+ (* 45.0 (- strat-upg-mult 1.0)) strat-unit-adj))
     (if crisis-deferred-here?
         5.0
         (+ 145.0 gas-ready-boost threat-research-boost gas-sink-boost tech-matchup-adj upg-escalation-bonus pv5-boost eff-bo-boost))]

    [(production-scaling)
     (define gas-tech-bonus
       (if (> g-cost 0)
           (min 18.0 (* 0.14 (exact->inexact g-cost)))
           0.0))
     (define prod-matchup-adj
       (+ (if (and (eq? m-race 'Terran) (memq m-enemy-race '(Terran Protoss)) (eq? id 'barracks-techlab)) 36.0 0.0)
          (if (and (eq? m-race 'Terran) (eq? m-enemy-race 'Terran) (memq id '(factory factory-techlab))) 38.0 0.0)
          (if (and (eq? m-race 'Terran) tvp-cannon-contain? (memq id '(factory factory-techlab))) 52.0 0.0)
          (if (and (eq? m-race 'Terran) enemy-capital-air? (memq id '(starport starport-reactor))) 55.0 0.0)
          (if (and (eq? m-race 'Protoss) enemy-capital-air? (eq? id 'stargate)) 54.0 0.0)
          strat-unit-adj
          (if strat-high-bank-inject? 38.0 0.0)))
     (+ 116.0 gas-tech-bonus (* 45.0 (min 3.0 facility-scaling-pressure)) prod-matchup-adj pv5-boost bo-head-boost)]

    [(worker)
     (define cannon-worker-recover? (unpacked-utility-metrics-cannon-worker-recover? um))
     (define light-non-overrun-threat? (unpacked-utility-metrics-light-non-overrun-threat? um))
     (define base-worker-u
       (if (and under-threat? (not light-non-overrun-threat?) (not cannon-worker-recover?))
           (* 42.0 worker-saturation-gap)
           (+ 35.0 (* 52.0 worker-saturation-gap))))
     (if (and (or (not under-attack?) cannon-worker-recover?)
              (< workers (min 66 (* 22 active-bases))))
         (max (cond
                [(and cannon-worker-recover? (< workers 22)) 135.0]
                [(and light-non-overrun-threat?
                      (< workers (min 44 (* 22 active-bases))))
                 95.0]
                [else 60.0])
              base-worker-u)
         base-worker-u)]

    [(expansion)
     (cond
       [(<= expansion-desire 0.0) 5.0]
       [(and (= active-bases 1) escrow-eligible?)
        ;; Natural expansion on 1 base when escrow-eligible: outranks passive worker
        ;; and non-crisis units, but stays below supply (>1000), PV5 counter-tech (>=318),
        ;; PV2 crisis combat (>=238), and PV3 gas-sink combat/tech (>=287).
        (+ 175.0 (* 20.0 (min 1.5 expansion-desire)))]
       [else
        ;; PV1: When active-bases >= 2 or (not escrow-eligible?), expansion NEVER
        ;; outranks or blocks tech-upgrade (>=142), counter-tech (>=138),
        ;; production-scaling (>=116), or combat-unit (>=88) unless base depletion/1000M inject triggers.
        (+ 48.0 (* 18.0 (min 1.5 expansion-desire))
           (* 35.0 strat-depleting-bases)
           (if strat-high-bank-inject? 28.0 0.0)
           bo-head-boost)])]

    [else 25.0]))

(define (make-scored-candidate id category action min-cost gas-cost supply-cost blocking-allowed? metrics)
  (define blk-bool (not (not blocking-allowed?)))
  (define raw-cand
    (priority-candidate id category action min-cost gas-cost supply-cost 0.0 'medium blk-bool))
  (define score (compute-candidate-marginal-utility raw-cand metrics))
  (define tier
    (cond
      [(>= score 1000.0) 'critical-supply]
      [(>= score 230.0)  'high-priority]
      [(>= score 110.0)  'standard-macro]
      [else              'background-economy]))
  (priority-candidate id category action min-cost gas-cost supply-cost score tier blk-bool))

(define (generate-race-priority-candidates
         #:race [raw-race 'Zerg]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 200]
         #:gas [raw-gas 0]
         #:supply-left [raw-supply-left 4]
         #:supply-cap [raw-supply-cap 15]
         #:pending-supply [raw-pending-supply 0]
         #:workers [raw-workers 12]
         #:target-workers [raw-target-workers 44]
         #:active-bases [raw-active-bases 1]
         #:desired-bases [raw-desired-bases 2]
         #:production-facilities [raw-prod-facilities 1]
         #:max-facilities [raw-max-facilities 4]
         #:army-supply [raw-army-supply 0]
         #:enemy-threat-supply [raw-enemy-threat-supply 0]
         #:under-attack? [raw-under-attack? #f]
         #:requires-anti-air? [raw-requires-anti-air? #f]
         #:requires-detection? [raw-requires-detection? #f]
         #:escrow-age-frames [raw-escrow-age-frames 0]
         #:max-escrow-frames [raw-max-escrow-frames 224]
         #:intel-staleness-frames [raw-intel-staleness-frames 0]
         #:max-intel-staleness-frames [raw-max-intel-staleness-frames 268]
         #:supply-at-risk? [raw-supply-at-risk? #f]
         #:supply-buffer [override-supply-buffer #f]
         #:ally-buildings [ally-buildings '()]
         #:ready-buildings [ready-buildings #f]
         #:open-prod-slots [open-prod-slots #f]
         #:bo-active-goal [bo-active-goal #f]
         #:ally-units [ally-units '()]
         #:researched-upgrades [researched-upgrades '()]
         #:random-stealth-plan [_random-stealth-plan #f]
         #:enemy-race [raw-enemy-race 'Unknown]
         #:enemy-unit-counts [raw-enemy-unit-counts #f]
         #:enemy-building-counts [raw-enemy-building-counts #f]
         #:benchmark-targets [raw-benchmark-targets #f]
         #:unit-counts [raw-unit-counts #f]
         #:total-building-counts [raw-total-bldg-counts #f]
         #:ready-building-counts [raw-ready-bldg-counts #f]
         #:base-x [raw-base-x 32.5]
         #:base-y [raw-base-y 32.5]
         #:nat-x [raw-nat-x 50.5]
         #:nat-y [raw-nat-y 50.5]
         #:third-x [raw-third-x 60.5]
         #:third-y [raw-third-y 40.5]
         #:depleting-bases [raw-depleting-bases 0]
         #:natural-blocked? [raw-natural-blocked? #f]
         #:mirror-signals [raw-mirror-signals #f]
         #:strategic-goals [raw-strategic-goals #f]
         #:post-bo-deviation [raw-post-bo-deviation #f])
  (define race (normalize-ledger-race raw-race))
  (define enemy-race (normalize-enemy-race-sym raw-enemy-race))
  (define enemy-u-counts (and (hash? raw-enemy-unit-counts) raw-enemy-unit-counts))
  (define enemy-b-counts (and (hash? raw-enemy-building-counts) raw-enemy-building-counts))
  (define enemy-cap-air? (protoss-enemy-capital-air? enemy-u-counts))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define base-x (safe-tile-coord raw-base-x 32.5))
  (define base-y (safe-tile-coord raw-base-y 32.5))
  (define nat-x (safe-tile-coord raw-nat-x 50.5))
  (define nat-y (safe-tile-coord raw-nat-y 50.5))
  (define third-x (safe-tile-coord raw-third-x 60.5))
  (define third-y (safe-tile-coord raw-third-y 40.5))
  (define exp-x (if (>= active-bases 2) third-x nat-x))
  (define exp-y (if (>= active-bases 2) third-y nat-y))
  (define upgs (if (list? researched-upgrades) researched-upgrades '()))
  (define bldgs-ht
    (if (hash? raw-total-bldg-counts)
        raw-total-bldg-counts
        (for/fold ([ht (hasheq)]) ([b (in-list (if (list? ally-buildings) ally-buildings '()))])
          (if (symbol? b) (hash-update ht b add1 0) ht))))
  (define r-bldgs-ht
    (cond
      [(hash? raw-ready-bldg-counts) raw-ready-bldg-counts]
      [(list? ready-buildings)
       (for/fold ([ht (hasheq)]) ([b (in-list ready-buildings)])
         (if (symbol? b) (hash-update ht b add1 0) ht))]
      [else bldgs-ht]))
  (define (bldg-has? sym) (> (safe-nonneg-int (hash-ref bldgs-ht sym 0) 0) 0))
  (define (ready-bldg-has? sym) (> (safe-nonneg-int (hash-ref r-bldgs-ht sym 0) 0) 0))
  (define (bldg-eq-count sym)
    (for/sum ([s (in-list (sc2-structure-equivalent-syms sym #f))])
      (safe-nonneg-int (hash-ref bldgs-ht s 0) 0)))
  (define (ready-bldg-eq-count sym)
    (for/sum ([s (in-list (sc2-structure-equivalent-syms sym #f))])
      (safe-nonneg-int (hash-ref r-bldgs-ht s 0) 0)))
  (define enemy-ground-army?
    (if (and (hash? enemy-u-counts) (> (hash-count enemy-u-counts) 0))
        (let ([ground-cnt
               (for/sum ([(utype cnt) (in-hash enemy-u-counts)]
                         #:when (and (> (safe-nonneg-int cnt 0) 0)
                                     (not (memq utype
                                                '(drone scv probe larva egg cocoon
                                                  overlord overlord-transport overseer overseer-siege-mode
                                                  observer observer-siege-mode medivac warp-prism warp-prism-phasing
                                                  mutalisk corruptor brood-lord broodlord viper
                                                  viking viking-fighter liberator banshee raven battlecruiser
                                                  phoenix oracle void-ray voidray carrier tempest mothership interceptor)))))
                 (safe-nonneg-int cnt 0))]
              [air-combat-cnt
               (for/sum ([(utype cnt) (in-hash enemy-u-counts)]
                         #:when (memq utype '(mutalisk corruptor brood-lord broodlord viper
                                               viking viking-fighter liberator banshee raven battlecruiser
                                               phoenix oracle void-ray voidray carrier tempest mothership)))
                 (safe-nonneg-int cnt 0))])
          (or (> ground-cnt 0)
              (and (not raw-requires-anti-air?) (= air-combat-cnt 0))))
        (not raw-requires-anti-air?)))
  (define live-workers (safe-nonneg-int raw-workers 12))
  (define has-robo? (> (bldg-eq-count 'robotics-facility) 0))
  (define has-armory? (> (bldg-eq-count 'armory) 0))
  (define has-ready-armory? (> (ready-bldg-eq-count 'armory) 0))
  (define unit-counts-ht
    (if (hash? raw-unit-counts)
        raw-unit-counts
        (for/fold ([ht (hasheq)]) ([u (in-list (if (list? ally-units) ally-units '()))])
          (if (symbol? u)
              (hash-update ht u add1 0)
              ht))))
  (define (unit-ht-count sym-or-syms)
    (if (symbol? sym-or-syms)
        (safe-nonneg-int (hash-ref unit-counts-ht sym-or-syms 0) 0)
        (for/sum ([s (in-list sym-or-syms)])
          (safe-nonneg-int (hash-ref unit-counts-ht s 0) 0))))
  (define frame-val (safe-nonneg-int raw-frame 0))
  (define min-val (safe-nonneg-int raw-minerals 0))
  (define gas-val (safe-nonneg-int raw-gas 0))
  (define benchmark-targets
    (if (hash? raw-benchmark-targets)
        raw-benchmark-targets
        (normalized-pro-unit-benchmarks race enemy-race frame-val active-bases)))
  (define zvp-stargate-threat?
    (and (eq? race 'Zerg)
         (zerg-enemy-stargate-air-threat? enemy-u-counts enemy-b-counts enemy-race raw-requires-anti-air?)))
  (define pvt-fast-kiter-threat?
    (and (eq? race 'Protoss)
         (protoss-enemy-fast-kiter-threat? enemy-u-counts)))
  (define tvp-cannon-contain?
    (terran-enemy-cannon-contain? race enemy-race enemy-u-counts enemy-b-counts))
  (define cannon-worker-recover?
    (worker-recovery-after-cannon-or-contain?
     race enemy-race live-workers active-bases raw-army-supply
     raw-under-attack? raw-enemy-threat-supply enemy-u-counts enemy-b-counts))
  (define bo-goal-sym (and (pro-bo-goal? bo-active-goal) (pro-bo-goal-target-sym bo-active-goal)))
  (define crisis-defer?
    (crisis-defense-tech-defer-active?
     raw-under-attack? raw-army-supply raw-enemy-threat-supply live-workers))
  (define defer-stargate?
    (or has-robo? (and (not raw-requires-anti-air?) (not enemy-cap-air?))))
  (define enemy-cap-air-ground-aa?
    (terran-enemy-capital-air-with-ground-aa? enemy-u-counts))
  (define desired-thor-cap (terran-desired-thor-cap enemy-u-counts))
  (define air-fleet-cnt (terran-air-fleet-count unit-counts-ht))
  (define ship-weap-due?
    (terran-ship-weapons-due? race air-fleet-cnt has-ready-armory? upgs))
  (define sg-depleting (safe-nonneg-int raw-depleting-bases 0))
  (define sg-world-ht
    (hasheq 'race race
            'enemy-race enemy-race
            'frame (safe-nonneg-int raw-frame 0)
            'minerals (safe-nonneg-int raw-minerals 0)
            'gas (safe-nonneg-int raw-gas 0)
            'supply-left raw-supply-left
            'supply-cap raw-supply-cap
            'workers live-workers
            'active-bases active-bases
            'desired-bases raw-desired-bases
            'army-supply raw-army-supply
            'enemy-threat-supply raw-enemy-threat-supply
            'under-attack? raw-under-attack?
            'requires-anti-air? raw-requires-anti-air?
            'requires-detection? raw-requires-detection?
            'researched-upgrades upgs
            'unit-counts unit-counts-ht
            'building-counts bldgs-ht
            'enemy-unit-counts (or enemy-u-counts (hasheq))
            'enemy-building-counts (or enemy-b-counts (hasheq))
            'depleting-bases sg-depleting
            'natural-blocked? (eq? raw-natural-blocked? #t)))
  (define post-bo-goals
    (if (hash? raw-strategic-goals)
        raw-strategic-goals
        (evaluate-post-bo-strategic-goals sg-world-ht #f raw-mirror-signals)))
  (define post-bo-dev
    (if (hash? raw-post-bo-deviation)
        raw-post-bo-deviation
        (hash-ref post-bo-goals 'deviation (hasheq))))
  (define sg-desired-bases (max raw-desired-bases (safe-nonneg-int (hash-ref post-bo-goals 'desired-bases raw-desired-bases) raw-desired-bases)))
  (define sg-mirror-min-bases (safe-nonneg-int (hash-ref post-bo-goals 'mirror-recommended-min-bases 0) 0))
  (define sg-suppress-opening? (eq? (hash-ref post-bo-goals 'suppress-opening-harass? #f) #t))
  (define sg-reqs-aa? (or raw-requires-anti-air? (eq? (hash-ref post-bo-goals 'requires-anti-air? #f) #t)))
  (define sg-reqs-det? (or raw-requires-detection? (eq? (hash-ref post-bo-goals 'requires-detection? #f) #t)))
  (define sg-recs (hash-ref post-bo-goals 'recommended-units (hasheq)))
  (define sg-suppressed (hash-ref post-bo-goals 'suppressed-units '()))
  (define sg-rec-upgs (hash-ref post-bo-goals 'recommended-upgrades '()))
  (define sg-attrs (hash-ref post-bo-goals 'enemy-comp-attrs (hasheq)))
  (define sg-high-bank? (eq? (hash-ref post-bo-goals 'high-bank-macro-inject? #f) #t))
  (define (sg-rec-bonus sym) (safe-real (hash-ref sg-recs sym 0.0) 0.0))
  (define (sg-suppressed? sym) (not (not (memq sym sg-suppressed))))
  (define severe-crisis-static-def?
    (and crisis-defer?
         (or (>= (safe-real raw-army-supply 0.0) 4.0) (>= (safe-nonneg-int raw-minerals 0) 200))
         (or (< live-workers 32)
             (< (safe-real raw-army-supply 0.0) (* 0.8 (safe-real raw-enemy-threat-supply 0.0)))
             (< (safe-real raw-army-supply 0.0) 16.0))))

  (define base-metrics
    (compute-state-pressure-metrics
     #:race race
     #:frame raw-frame
     #:minerals raw-minerals
     #:gas raw-gas
     #:supply-left raw-supply-left
     #:supply-cap raw-supply-cap
     #:pending-supply raw-pending-supply
     #:workers raw-workers
     #:target-workers raw-target-workers
     #:active-bases active-bases
     #:desired-bases sg-desired-bases
     #:production-facilities raw-prod-facilities
     #:max-facilities raw-max-facilities
     #:army-supply raw-army-supply
     #:enemy-threat-supply raw-enemy-threat-supply
     #:under-attack? raw-under-attack?
     #:requires-anti-air? sg-reqs-aa?
     #:requires-detection? sg-reqs-det?
     #:escrow-age-frames raw-escrow-age-frames
     #:max-escrow-frames raw-max-escrow-frames
     #:intel-staleness-frames raw-intel-staleness-frames
     #:max-intel-staleness-frames raw-max-intel-staleness-frames
     #:supply-at-risk? raw-supply-at-risk?
     #:supply-buffer override-supply-buffer))

  (define metrics
    (enrich-priority-metrics
     base-metrics
     #:race race
     #:enemy-race enemy-race
     #:minerals raw-minerals
     #:active-bases active-bases
     #:under-attack? raw-under-attack?
     #:requires-anti-air? sg-reqs-aa?
     #:army-supply raw-army-supply
     #:enemy-threat-supply raw-enemy-threat-supply
     #:workers live-workers
     #:has-barracks-techlab? (or (ready-bldg-has? 'barracks-techlab)
                                 (ready-bldg-has? 'barracks-tech-lab))
     #:has-twilight-or-charge? (or (ready-bldg-has? 'twilight-council)
                                   (memq 'charge upgs))
     #:has-hydralisk-den? (ready-bldg-has? 'hydralisk-den)
     #:has-robo? has-robo?
     #:has-armory? has-armory?
     #:crisis-defense-defer? crisis-defer?
     #:enemy-capital-air-ground-aa? enemy-cap-air-ground-aa?
     #:terran-ship-weapons-due? ship-weap-due?
     #:stalker-count (unit-ht-count 'stalker)
     #:roach-count (unit-ht-count 'roach)
     #:enemy-unit-counts enemy-u-counts
     #:enemy-building-counts enemy-b-counts
     #:benchmark-targets benchmark-targets
     #:unit-counts unit-counts-ht
     #:bo-goal-sym bo-goal-sym
     #:strategic-goals post-bo-goals))

  (define sup-used
    (max 0 (- (safe-nonneg-int raw-supply-cap 15)
              (max 0 (safe-exact-int raw-supply-left 4)))))
  (define army-val (max 0.0 (safe-real raw-army-supply 0.0)))
  (define threat-val (max 0.0 (safe-real raw-enemy-threat-supply 0.0)))
  (define root-combat-ready?
    (case race
      [(Zerg) (ready-bldg-has? 'spawning-pool)]
      [(Terran) (ready-bldg-has? 'barracks)]
      [else (or (ready-bldg-has? 'gateway)
                (ready-bldg-has? 'warp-gate))]))
  (define under-early-rush-crisis?
    (and (hash? open-prod-slots)
         (< frame-val 3000)
         (or (eq? raw-under-attack? #t) (>= threat-val 4.0))))
  (define t3-endgame?
    (and (hash? open-prod-slots)
         (>= active-bases 3)
         (or (>= live-workers 50) (>= sup-used 90))))
  (define zerg-army-step-ok?
    (zerg-worker-army-floor-ok? race enemy-race live-workers army-val))
  (define zerg-3base-interleave-ok?
    (and (eq? race 'Zerg)
         (>= active-bases 3)
         (< live-workers 55)
         (not raw-under-attack?)
         zerg-army-step-ok?
         (>= army-val 4.0)))
  (define worker-curve-ok?
    (or (not (hash? open-prod-slots))
        cannon-worker-recover?
        (and zerg-army-step-ok?
             (or (< live-workers 24)
                 zerg-3base-interleave-ok?
                 (and (not raw-under-attack?)
                      (< live-workers (min 44 (* 22 active-bases)))
                      (or (<= threat-val 0.0)
                          (and (< threat-val 18.0)
                               (<= threat-val (* 1.65 (max 6.0 army-val))))))
                 (>= army-val (required-army-supply-for-worker-growth live-workers threat-val))))))
  (define emergency-army-before-workers?
    (and (not cannon-worker-recover?)
         (or raw-under-attack? (> threat-val 0.0))
         (< army-val 4.0)
         root-combat-ready?
         (>= live-workers 1)))
  (define worker-survival-crisis?
    (and (hash? open-prod-slots)
         (< live-workers 6)
         (not emergency-army-before-workers?)))
  (define escrow-ok?
    (and (not worker-survival-crisis?)
         (or (eq? (hash-ref metrics 'escrow-eligible? #f) #t)
             ;; Camped-natural redirect unblock: allow 1-base expansion once >= 350M & basic defense ready
             (and (hash? open-prod-slots)
                  (= active-bases 1)
                  (not raw-under-attack?)
                  (<= threat-val 0.0)
                  (>= min-val 350)
                  (>= frame-val 2688)
                  (or root-combat-ready? (>= army-val 6.0))))))
  (define terran-breakout-cc-due?
    (and (eq? race 'Terran)
         (<= active-bases 3)
         (>= min-val 1500)
         (>= live-workers 18)))
  (define mirror-expand-due?
    (and (> sg-mirror-min-bases active-bases)
         (or (< active-bases 2)
             (eq? race 'Zerg)
             (and (>= live-workers 32)
                  (or (>= army-val 10)
                      (>= min-val 550))))))
  (define has-protoss-mid-tech?
    (or has-robo?
        (> (bldg-eq-count 'twilight-council) 0)
        (> (bldg-eq-count 'stargate) 0)))
  (define exp-blocking?
    (and (or (= active-bases 1)
             terran-breakout-cc-due?
             (protoss-4th-nexus-due? race active-bases live-workers army-val min-val enemy-cap-air?
                                     #:has-tech? has-protoss-mid-tech?)
             (and (not raw-under-attack?)
                  (not worker-survival-crisis?)
                  (or (> sg-depleting 0)
                      mirror-expand-due?))
             (and (hash? open-prod-slots)
                  (not (not (memq bo-goal-sym '(hatchery nexus command-center))))))
         (or terran-breakout-cc-due? escrow-ok?)
         (if (hash? open-prod-slots)
             (or terran-breakout-cc-due?
                 (protoss-4th-nexus-due? race active-bases live-workers army-val min-val enemy-cap-air?
                                         #:has-tech? has-protoss-mid-tech?)
                 (> sg-depleting 0)
                 mirror-expand-due?
                 (not (not (memq bo-goal-sym '(hatchery nexus command-center))))
                 (>= min-val 350)
                 (>= live-workers (if (eq? race 'Zerg) 16 19)))
             #t)))
  (define supply-urgent? (> (hash-ref metrics 'supply-hazard 0.0) 0.0))

  ;; When `open-prod-slots` is provided, a facility's production/addon candidate is
  ;; `blocking-allowed? = #t` iff its prerequisite structure is ready AND its facility has
  ;; an open production slot (> 0) AND we are not in a `< 6` worker starvation crisis.
  ;; When `open-prod-slots` is #f (synthetic tests / PV lattice),
  ;; default to #t so all formal PV1-PV6 lattice checks evaluate all candidates.
  (define (facility-slot-open? slot-key [prereq-sym #f])
    (if (hash? open-prod-slots)
        (and (not worker-survival-crisis?)
             (> (hash-ref open-prod-slots slot-key 0) 0)
             (or (not prereq-sym) (ready-bldg-has? prereq-sym)))
        #t))

  (define (cand id category action blocking-allowed?)
    (define base-c
      (make-scored-candidate id
                             category
                             action
                             (sc2-min-cost id)
                             (sc2-gas-cost id)
                             (sc2-supply-cost id 0)
                             (if (and worker-survival-crisis? (not (memq category '(supply worker))))
                                 #f
                                 blocking-allowed?)
                             metrics))
    (cond
      [(and (eq? category 'worker) (hash? open-prod-slots) (>= live-workers 70))
       (struct-copy priority-candidate base-c
                    [utility-score 20.0]
                    [blocking-allowed? #f])]
      [(and (eq? category 'worker)
            (hash? open-prod-slots)
            (< live-workers 8)
            (not emergency-army-before-workers?))
       (struct-copy priority-candidate base-c
                    [utility-score (+ (priority-candidate-utility-score base-c)
                                      (* 120.0 (- 8.0 live-workers)))]
                    [blocking-allowed? (> live-workers 0)])]
      [(and (eq? category 'worker)
            (hash? open-prod-slots)
            cannon-worker-recover?
            (< live-workers 22))
       (struct-copy priority-candidate base-c
                    [utility-score (max (+ (priority-candidate-utility-score base-c) 80.0)
                                        (if (< live-workers 18) 280.0 210.0))]
                    [urgency-tier 'high-priority]
                    [blocking-allowed? (and (> live-workers 0) (< live-workers 18))])]
      [(and (eq? category 'worker)
            (hash? open-prod-slots)
            (not worker-curve-ok?))
       (struct-copy priority-candidate base-c
                    [utility-score (min 105.0 (* 0.55 (priority-candidate-utility-score base-c)))]
                    [blocking-allowed? #f])]
      [else base-c]))

  (define (boost-cand id category action blocking-allowed? bonus-u)
    (define c0 (cand id category action blocking-allowed?))
    (if (and (hash? open-prod-slots) (> bonus-u 0.0))
        (let ([new-u (+ (priority-candidate-utility-score c0) bonus-u)])
          (struct-copy priority-candidate c0
                       [utility-score new-u]
                       [urgency-tier (if (>= new-u 230.0)
                                         'high-priority
                                         (priority-candidate-urgency-tier c0))]))
        c0))

  (define (append-benchmark-unit-cands base-cands spec-fn)
    (if (or (= (hash-count benchmark-targets) 0) worker-survival-crisis?)
        base-cands
        (let ([seen-syms (map priority-candidate-id base-cands)])
          (define extra
            (for/list ([(u-sym tgt) (in-hash benchmark-targets)]
                       #:when (and (> tgt 0)
                                   (not (memq u-sym '(drone scv probe overlord)))
                                   (not (memq u-sym seen-syms))
                                   (< (count-unit-in-hash unit-counts-ht u-sym) tgt)
                                   (spec-fn u-sym)))
              (match-define (list cat act open? bonus) (spec-fn u-sym))
              (boost-cand u-sym cat act open? bonus)))
          (append base-cands extra))))

  (case race
    [(Zerg)
     (define has-lair-or-hive?
       (or (ready-bldg-has? 'lair)
           (ready-bldg-has? 'hive)))
     (define has-hive? (ready-bldg-has? 'hive))
     (define has-ultra-cavern? (ready-bldg-has? 'ultralisk-cavern))
     (define has-hive-t3-tech?
       (and has-hive?
            (or has-ultra-cavern?
                (ready-bldg-has? 'greater-spire))))
     (define cur-roaches-pre (unit-ht-count '(roach roach-burrowed)))
     (define has-burrow-units?
       (or (>= cur-roaches-pre 2)
           (> (unit-ht-count '(lurker lurker-burrowed lurker-mp lurker-mp-burrowed infestor infestor-burrowed)) 0)
           (> (bldg-eq-count 'lurker-den) 0)))
     (define eff-ready-bldgs-ht
       (if (hash? raw-ready-bldg-counts)
           raw-ready-bldg-counts
           (for/fold ([ht (hasheq)]) ([b (in-list (if (list? ready-buildings) ready-buildings (if (list? ally-buildings) ally-buildings '())))])
             (if (symbol? b) (hash-update ht b add1 0) ht))))
     (define eff-total-bldgs-ht
       (if (hash? raw-total-bldg-counts)
           raw-total-bldg-counts
           (for/fold ([ht (hasheq)]) ([b (in-list (if (list? ally-buildings) ally-buildings '()))])
             (if (symbol? b) (hash-update ht b add1 0) ht))))
     (define (zerg-upg-ok? sym)
       (and (not (has-upgrade-sym? sym upgs))
            (upgrade-allowed-by-unit-and-order-gates?
             'Zerg sym frame-val live-workers eff-ready-bldgs-ht eff-total-bldgs-ht unit-counts-ht upgs '())))
     (define early-burrow-due?
       (zerg-upg-ok? 'burrow))
     (define upg-escalation? (or (>= active-bases 2) (>= live-workers 30)))
     (define sg-allowed-upgs
       (filter zerg-upg-ok? sg-rec-upgs))
     (define upg-sym
       (cond
         [(zerg-upg-ok? 'metabolic-boost) 'metabolic-boost]
         [(and upg-escalation? (pair? sg-allowed-upgs)) (car sg-allowed-upgs)]
         [(zerg-upg-ok? 'glial-reconstitution) 'glial-reconstitution]
         [(zerg-upg-ok? 'zerg-missile-weapons-1) 'zerg-missile-weapons-1]
         [(zerg-upg-ok? 'grooved-spines) 'grooved-spines]
         [(zerg-upg-ok? 'muscular-augments) 'muscular-augments]
         [(zerg-upg-ok? 'centrifical-hooks) 'centrifical-hooks]
         [(zerg-upg-ok? 'burrow) 'burrow]
         [(zerg-upg-ok? 'tunneling-claws) 'tunneling-claws]
         [(zerg-upg-ok? 'zerg-ground-armor-1) 'zerg-ground-armor-1]
         [(and has-ultra-cavern? (zerg-upg-ok? 'chitinous-plating)) 'chitinous-plating]
         [(and has-ultra-cavern? (zerg-upg-ok? 'anabolic-synthesis)) 'anabolic-synthesis]
         [(zerg-upg-ok? 'zerg-missile-weapons-2) 'zerg-missile-weapons-2]
         [(zerg-upg-ok? 'zerg-ground-armor-2) 'zerg-ground-armor-2]
         [(zerg-upg-ok? 'zerg-missile-weapons-3) 'zerg-missile-weapons-3]
         [(zerg-upg-ok? 'zerg-ground-armor-3) 'zerg-ground-armor-3]
         [(zerg-upg-ok? 'zerg-melee-weapons-1) 'zerg-melee-weapons-1]
         [(zerg-upg-ok? 'zerg-melee-weapons-2) 'zerg-melee-weapons-2]
         [else 'zerg-melee-weapons-3]))
     (define (zerg-upg-prereq-ok? sym)
       (if (hash? open-prod-slots)
           (case sym
             [(metabolic-boost) (ready-bldg-has? 'spawning-pool)]
             [(burrow) (and (or (ready-bldg-has? 'hatchery) has-lair-or-hive?)
                            (> (hash-ref open-prod-slots 'townhall 1) 0))]
             [(glial-reconstitution tunneling-claws)
              (and (ready-bldg-has? 'roach-warren)
                   has-lair-or-hive?
                   (> (hash-ref open-prod-slots 'roach-warren 1) 0))]
             [(grooved-spines) (ready-bldg-has? 'hydralisk-den)]
             [(muscular-augments) (and (ready-bldg-has? 'hydralisk-den) has-lair-or-hive?)]
             [(centrifical-hooks)
              (and (ready-bldg-has? 'baneling-nest)
                   has-lair-or-hive?
                   (> (hash-ref open-prod-slots 'baneling-nest 1) 0))]
             [(chitinous-plating anabolic-synthesis) has-ultra-cavern?]
             [(zerg-melee-weapons-2 zerg-missile-weapons-2 zerg-ground-armor-2 zerg-ground-armors-2)
              (and (ready-bldg-has? 'evolution-chamber) has-lair-or-hive?)]
             [(zerg-melee-weapons-3 zerg-missile-weapons-3 zerg-ground-armor-3 zerg-ground-armors-3)
              (and (ready-bldg-has? 'evolution-chamber) has-hive?)]
             [(zerg-flyer-weapons-1 zerg-flyer-armor-1 zerg-flyer-armors-1)
              (or (ready-bldg-has? 'spire) (ready-bldg-has? 'greater-spire))]
             [(zerg-flyer-weapons-2 zerg-flyer-armor-2 zerg-flyer-armors-2)
              (and (or (ready-bldg-has? 'spire) (ready-bldg-has? 'greater-spire)) has-lair-or-hive?)]
             [(zerg-flyer-weapons-3 zerg-flyer-armor-3 zerg-flyer-armors-3)
              (and (or (ready-bldg-has? 'spire) (ready-bldg-has? 'greater-spire)) has-hive?)]
             [else (ready-bldg-has? 'evolution-chamber)])
           #t))
     (define zerg-upg-ready? (zerg-upg-prereq-ok? upg-sym))
     (define keep-spire-aa?
       (zerg-enemy-air-spire-needed? enemy-u-counts enemy-b-counts enemy-race raw-requires-anti-air?))
     (define zerg-second-upg-sym
       (for/or ([u (in-list (if (pair? sg-rec-upgs) sg-rec-upgs '()))])
         (and (not (eq? u upg-sym))
              (not (crisis-deferred-sym? u crisis-defer? #:keep-spire-aa? keep-spire-aa?))
              (zerg-upg-ok? u)
              (zerg-upg-prereq-ok? u)
              u)))
     (define cur-queens (unit-ht-count '(queen queen-burrowed)))
     (define max-queens
       (max (desired-zerg-queen-count active-bases zvp-stargate-threat?)
            (if enemy-cap-air? SC2-MAX-QUEENS-CAP 0)))
     (define cur-overseers (unit-ht-count '(overseer overseer-siege-mode overlord-cocoon)))
     (define want-overseers
       (desired-zerg-overseer-count active-bases army-val has-lair-or-hive? raw-requires-detection?))
     (define cur-droppers (unit-ht-count '(overlord-transport transport-overlord-cocoon)))
     (define want-droppers
       (max (desired-zerg-overlord-transport-count active-bases army-val live-workers has-lair-or-hive? raw-under-attack?)
            (hash-ref benchmark-targets 'overlord-transport 0)))
     (define cur-overlords (unit-ht-count 'overlord))
     (define cur-spores (bldg-eq-count 'spore-crawler))
     (define want-spores
       (desired-zerg-spore-count active-bases enemy-u-counts enemy-b-counts enemy-race
                                 raw-requires-anti-air? raw-requires-detection?))
     (define zerg-rush-cands
       (if (or under-early-rush-crisis? severe-crisis-static-def?)
           (append
            (if (and under-early-rush-crisis? (not (bldg-has? 'spawning-pool)))
                (list (boost-cand 'spawning-pool 'production-scaling
                                  (list 'build 'spawning-pool (safe-tile-coord (+ base-x 3.5)) (safe-tile-coord (- base-y 3.5)))
                                  #t 500.0))
                '())
            (if (and root-combat-ready? (< (bldg-eq-count 'spine-crawler) (if severe-crisis-static-def? 2 1)))
                (list (boost-cand 'spine-crawler 'counter-tech
                                  (list 'build 'spine-crawler (safe-tile-coord (+ base-x 3.0)) (safe-tile-coord (- base-y 3.0)))
                                  #t (if under-early-rush-crisis? 260.0 165.0)))
                '()))
           '()))
     (define zerg-pit-spire-army-ok?
       (and (>= active-bases 3) (>= army-val 28.0)))
     (define corruptor-cap
       (zerg-enemy-capital-air-corruptor-cap enemy-u-counts raw-requires-anti-air? enemy-race))
     (define cur-corruptors
       (unit-ht-count '(corruptor brood-lord broodlord brood-lord-cocoon)))
     (define zerg-t3-cands
       (append
        ;; Emergency AA Spire remains permitted when `raw-requires-anti-air?` or enemy air/capital-air is active
        ;; even before T3 army threshold; normal `infestation-pit` and `spire` wait for 3 bases + 28 army.
        (if (and (not crisis-defer?)
                 has-lair-or-hive?
                 (= (bldg-eq-count 'infestation-pit) 0)
                 (or zerg-pit-spire-army-ok?
                     raw-requires-anti-air?
                     raw-requires-detection?))
            (list (boost-cand 'infestation-pit 'tech-upgrade
                              (list 'build 'infestation-pit (safe-tile-coord (+ base-x 5.5)) (safe-tile-coord (- base-y 4.5)))
                              #t 145.0))
            '())
        (if (and (or (not crisis-defer?) keep-spire-aa?)
                 has-lair-or-hive?
                 (= (bldg-eq-count 'spire) 0)
                 (or zerg-pit-spire-army-ok? enemy-cap-air? raw-requires-anti-air?))
            (list (boost-cand 'spire 'tech-upgrade
                              (list 'build 'spire (safe-tile-coord (- base-x 4.5)) (safe-tile-coord (+ base-y 4.5)))
                              #t (if enemy-cap-air? 185.0 140.0)))
            '())
        (if (and (or (> corruptor-cap 0)
                     (and (ready-bldg-has? 'greater-spire) (= cur-corruptors 0)))
                 (or (ready-bldg-has? 'spire) (ready-bldg-has? 'greater-spire))
                 (facility-slot-open? 'larva)
                 (or (bldg-has? 'greater-spire) enemy-cap-air? raw-requires-anti-air?)
                 (< cur-corruptors (max corruptor-cap (if (ready-bldg-has? 'greater-spire) 2 0))))
            (list (boost-cand 'corruptor 'combat-unit '(train corruptor) #t
                              (if enemy-cap-air? 185.0 135.0)))
            '())
        (if (and enemy-cap-air?
                 (or (ready-bldg-has? 'spire) (ready-bldg-has? 'greater-spire))
                 (not (has-upgrade-sym? 'zerg-flyer-armor-1 upgs)))
            (list (boost-cand 'zerg-flyer-armor-1 'tech-upgrade '(research zerg-flyer-armor-1)
                              (or (facility-slot-open? 'spire 'spire)
                                  (facility-slot-open? 'greater-spire 'greater-spire))
                              165.0))
            '())
        ;; Ready-tech Zerg siege-breakers: never disappear below 3 bases / 50 workers once tech is ready
        (if (and (facility-slot-open? 'larva 'ultralisk-cavern)
                 (< (unit-ht-count '(ultralisk ultralisk-burrowed)) 6))
            (list (boost-cand 'ultralisk 'combat-unit '(train ultralisk) #t
                              (if (and has-hive? (ready-bldg-has? 'ultralisk-cavern)) 195.0 155.0)))
            '())
        (if (and (ready-bldg-has? 'greater-spire)
                 (> (unit-ht-count 'corruptor) 0)
                 (< (unit-ht-count '(brood-lord broodlord brood-lord-cocoon)) 6))
            (list (boost-cand 'brood-lord 'combat-unit '(morph brood-lord) #t
                              (if has-hive? 198.0 160.0)))
            '())
        (if (and t3-endgame? (not crisis-defer?))
            (append
             (if (and (ready-bldg-has? 'lair) (ready-bldg-has? 'infestation-pit) (= (bldg-eq-count 'hive) 0))
                 (list (boost-cand 'hive 'tech-upgrade '(morph hive) #t 165.0))
                 '())
             (if (and has-hive? (= (bldg-eq-count 'ultralisk-cavern) 0))
                 (list (boost-cand 'ultralisk-cavern 'tech-upgrade
                                   (list 'build 'ultralisk-cavern (safe-tile-coord (+ base-x 6.5)) (safe-tile-coord (+ base-y 4.5)))
                                   #t 155.0))
                 '())
             (if (and has-hive? (ready-bldg-has? 'spire) (= (bldg-eq-count 'greater-spire) 0))
                 (list (boost-cand 'greater-spire 'tech-upgrade '(morph greater-spire) #t 155.0))
                 '())
             (if (and (facility-slot-open? 'larva 'hive)
                      (< (unit-ht-count 'viper) 3))
                 (list (boost-cand 'viper 'combat-unit '(train viper) #t
                                   (if (or (ready-bldg-has? 'ultralisk-cavern)
                                           (ready-bldg-has? 'greater-spire))
                                       192.0
                                       150.0)))
                 '())
             (if (and (facility-slot-open? 'larva 'infestation-pit)
                      (< (unit-ht-count '(infestor infestor-burrowed)) 2))
                 (list (boost-cand 'infestor 'combat-unit '(train infestor) #t
                                   (if (and has-hive?
                                            (or (ready-bldg-has? 'ultralisk-cavern)
                                                (ready-bldg-has? 'greater-spire)))
                                       188.0
                                       135.0)))
                 '()))
            '())))
     (define cur-zerglings (unit-ht-count '(zergling zergling-burrowed)))
     (define cur-roaches (unit-ht-count '(roach roach-burrowed)))
     (define ling-cap (zergling-target-cap min-val enemy-u-counts))
     (define cur-banelings (unit-ht-count '(baneling baneling-burrowed baneling-cocoon)))
     (define baneling-cap (min 12 (max 4 (quotient cur-zerglings 2))))
     (define cur-hydras (unit-ht-count '(hydralisk hydralisk-burrowed)))
     (define cur-lurkers
       (unit-ht-count '(lurker lurker-burrowed lurker-mp lurker-mp-burrowed lurker-egg lurker-mp-egg)))
     (define cur-ravagers
       (unit-ht-count '(ravager ravager-cocoon)))
     (define zerg-morph-cands
       (append
        (if (and (or crisis-defer? (> (sg-rec-bonus 'ravager) 0.0))
                 (> (ready-bldg-eq-count 'roach-warren) 0)
                 (> cur-roaches 0)
                 (< cur-ravagers (min 8 cur-roaches)))
            (list (boost-cand 'ravager 'combat-unit '(morph ravager) #t (+ 145.0 (sg-rec-bonus 'ravager))))
            '())
        (if (and (> (ready-bldg-eq-count 'baneling-nest) 0)
                 (>= cur-zerglings 4)
                 enemy-ground-army?
                 (< cur-banelings (if (> (sg-rec-bonus 'baneling) 0.0) (max 16 baneling-cap) baneling-cap)))
            (list (boost-cand 'baneling 'combat-unit '(morph baneling) #t
                              (+ (if (< cur-banelings 4) 155.0 135.0) (sg-rec-bonus 'baneling))))
            '())
        (if (and (> (ready-bldg-eq-count 'lurker-den) 0)
                 (>= cur-hydras 2)
                 (< cur-lurkers 12))
            (list (boost-cand 'lurker 'combat-unit '(morph lurker) #t
                              (+ (if (< cur-lurkers 4) 170.0 145.0) (sg-rec-bonus 'lurker))))
            '())))
     (define zerg-hive-t3-ready?
       (and has-hive?
            (or (ready-bldg-has? 'ultralisk-cavern)
                (ready-bldg-has? 'greater-spire))))
     (define zerg-post-bo-cands
       (append
        (if (and (not crisis-defer?)
                 (ready-bldg-has? 'spawning-pool)
                 (< (bldg-eq-count 'evolution-chamber) (if upg-escalation? 2 1))
                 (or (not zerg-hive-t3-ready?)
                     (> (bldg-eq-count 'evolution-chamber) 0)))
            (list (boost-cand 'evolution-chamber 'production-scaling
                              (list 'build 'evolution-chamber (safe-tile-coord (+ base-x 3.5)) (safe-tile-coord (+ base-y 4.5)))
                              #t (if upg-escalation? 152.0 135.0)))
            '())
        (if (and (not crisis-defer?)
                 (ready-bldg-has? 'spawning-pool)
                 (not zerg-hive-t3-ready?)
                 (= (bldg-eq-count 'baneling-nest) 0)
                 (or (> (sg-rec-bonus 'baneling-nest) 0.0) (>= active-bases 3)))
            (list (boost-cand 'baneling-nest 'counter-tech
                              (list 'build 'baneling-nest (safe-tile-coord (+ base-x 4.5)) (safe-tile-coord (- base-y 5.5)))
                              #t (+ 140.0 (sg-rec-bonus 'baneling-nest))))
            '())
        (if (and (not crisis-defer?)
                 (ready-bldg-has? 'spawning-pool)
                 (not has-lair-or-hive?)
                 (= (bldg-eq-count 'lair) 0)
                 (>= active-bases 2)
                 (>= gas-val 100))
            (list (boost-cand 'lair 'tech-upgrade '(morph lair) #t 160.0))
            '())
        (if (and (not crisis-defer?)
                 has-lair-or-hive?
                 (ready-bldg-has? 'hydralisk-den)
                 (= (bldg-eq-count 'lurker-den) 0)
                 (or (> (sg-rec-bonus 'lurker-den) 0.0) t3-endgame?))
            (list (boost-cand 'lurker-den 'counter-tech
                              (list 'build 'lurker-den (safe-tile-coord (+ base-x 5.0)) (safe-tile-coord (+ base-y 5.5)))
                              #t (+ 150.0 (sg-rec-bonus 'lurker-den))))
            '())
        (if (and sg-high-bank?
                 (not worker-survival-crisis?)
                 (not raw-under-attack?)
                 (< (bldg-eq-count 'hatchery) 6)
                 (< (bldg-eq-count 'hatchery) (+ active-bases 2)))
            (list (boost-cand 'hatchery 'production-scaling
                              (list 'build 'hatchery (safe-tile-coord (+ base-x 6.0)) (safe-tile-coord (- base-y 2.0)))
                              #t 168.0))
            '())))
     (define zerg-base-cands
       (append
        zerg-rush-cands
        zerg-morph-cands
        zerg-post-bo-cands
        (if (and has-lair-or-hive?
                 (not crisis-defer?)
                 (>= cur-overlords 2)
                 (< cur-droppers want-droppers))
            (list (boost-cand 'overlord-transport 'combat-unit '(morph overlord-transport)
                              (or (not (hash? open-prod-slots))
                                  (and (not raw-under-attack?) (>= cur-overlords 2)))
                              130.0))
            '())
        (list
         (cand 'overlord 'supply '(train overlord) supply-urgent?)
         (boost-cand 'spore-crawler 'counter-tech (list 'build 'spore-crawler (safe-tile-coord (+ base-x 3.0)) (safe-tile-coord (+ base-y 3.0)))
                     (if (hash? open-prod-slots)
                         (and (ready-bldg-has? 'spawning-pool)
                              (< cur-spores want-spores)
                              (or zvp-stargate-threat? enemy-cap-air? (> want-spores 1) sg-reqs-aa? sg-reqs-det?))
                         #t)
                     (if (and (or zvp-stargate-threat? enemy-cap-air?) (< cur-spores want-spores)) 185.0 0.0))
         (boost-cand 'queen 'counter-tech '(train queen)
                     (and (facility-slot-open? 'townhall 'spawning-pool)
                          (if (hash? open-prod-slots) (< cur-queens max-queens) #t))
                     (max (if (and (or zvp-stargate-threat? enemy-cap-air?) (< cur-queens max-queens)) 175.0 0.0)
                          (sg-rec-bonus 'queen)))
         (boost-cand 'hydralisk-den 'counter-tech (list 'build 'hydralisk-den (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 5.0)))
                     (if (hash? open-prod-slots) (and has-lair-or-hive? (= (bldg-eq-count 'hydralisk-den) 0)) #t)
                     (max (if (and (or zvp-stargate-threat? enemy-cap-air?) has-lair-or-hive? (= (bldg-eq-count 'hydralisk-den) 0)) 175.0 0.0)
                          (sg-rec-bonus 'hydralisk-den)))
         (boost-cand 'overseer 'counter-tech '(morph overseer)
                     (if (hash? open-prod-slots)
                         (and (or has-lair-or-hive? sg-reqs-det?)
                              has-lair-or-hive?
                              (>= cur-overlords 1)
                              (< cur-overseers want-overseers))
                         #t)
                     (if (and has-lair-or-hive? (< cur-overseers (if sg-reqs-det? 3 2))) 145.0 0.0))
         (boost-cand 'roach 'combat-unit '(train roach)
                     (and (facility-slot-open? 'larva 'roach-warren)
                          (not (sg-suppressed? 'roach)))
                     (if (and (not (sg-suppressed? 'roach))
                              (or (> (sg-rec-bonus 'roach) 0.0)
                                  (and (>= min-val 300) (< cur-roaches 16) (not (ready-bldg-has? 'hydralisk-den)))))
                         (max 20.0 (sg-rec-bonus 'roach))
                         0.0))
         (boost-cand 'hydralisk 'combat-unit '(train hydralisk)
                     (facility-slot-open? 'larva 'hydralisk-den)
                     (max (if (and (or zvp-stargate-threat? (and enemy-cap-air? (< cur-hydras 12)))
                                   (ready-bldg-has? 'hydralisk-den))
                              180.0
                              0.0)
                          (sg-rec-bonus 'hydralisk))))
        (if (or (not (hash? open-prod-slots)) (< cur-zerglings ling-cap))
            (list (cand 'zergling 'combat-unit '(train zergling) (facility-slot-open? 'larva 'spawning-pool)))
            '())
        (if (crisis-deferred-sym? upg-sym crisis-defer? #:keep-spire-aa? keep-spire-aa?)
            '()
            (list (cand upg-sym 'tech-upgrade (list 'research upg-sym) zerg-upg-ready?)))
        (if zerg-second-upg-sym
            (list (cand zerg-second-upg-sym 'tech-upgrade (list 'research zerg-second-upg-sym) #t))
            '())
        (if (and (not crisis-defer?)
                 (not (eq? upg-sym 'burrow))
                 early-burrow-due?
                 (or (ready-bldg-has? 'hatchery) has-lair-or-hive?))
            (list (boost-cand 'burrow 'tech-upgrade '(research burrow)
                              (or (not (hash? open-prod-slots)) (> (hash-ref open-prod-slots 'townhall 1) 0))
                              90.0))
            '())
        (if (and (not crisis-defer?)
                 (not (eq? upg-sym 'tunneling-claws))
                 has-lair-or-hive?
                 (ready-bldg-has? 'roach-warren)
                 (>= cur-roaches-pre 4)
                 (not (has-upgrade-sym? 'tunneling-claws upgs)))
            (list (boost-cand 'tunneling-claws 'tech-upgrade '(research tunneling-claws)
                              (or (not (hash? open-prod-slots)) (> (hash-ref open-prod-slots 'roach-warren 1) 0))
                              158.0))
            '())
        (if (and (not crisis-defer?)
                 (not (eq? upg-sym 'centrifical-hooks))
                 has-lair-or-hive?
                 (ready-bldg-has? 'baneling-nest)
                 (zerg-upg-ok? 'centrifical-hooks)
                 (not (has-upgrade-sym? 'centrifical-hooks upgs)))
            (list (boost-cand 'centrifical-hooks 'tech-upgrade '(research centrifical-hooks)
                              (or (not (hash? open-prod-slots)) (> (hash-ref open-prod-slots 'baneling-nest 1) 0))
                              158.0))
            '())
        (if (and (not crisis-defer?)
                 (not zerg-hive-t3-ready?)
                 (ready-bldg-has? 'spawning-pool))
            (list (cand 'roach-warren 'production-scaling (list 'build 'roach-warren (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (- base-y 4.0)))
                        (if (hash? open-prod-slots) (and (ready-bldg-has? 'spawning-pool) (= (bldg-eq-count 'roach-warren) 0)) #t)))
            '())
        (list
         (cand 'drone 'worker '(train drone) #f)
         (cand 'hatchery 'expansion (list 'expand exp-x exp-y) exp-blocking?))
        zerg-t3-cands))
     (append-benchmark-unit-cands
      zerg-base-cands
      (lambda (u-sym)
        (case u-sym
          [(ravager) (and (ready-bldg-has? 'roach-warren) (>= cur-roaches 2)
                          (list 'combat-unit '(morph ravager) (not worker-survival-crisis?) 130.0))]
          [(baneling) (and (ready-bldg-has? 'baneling-nest) (>= cur-zerglings 4)
                           (list 'combat-unit '(morph baneling) (not worker-survival-crisis?) 135.0))]
          [(lurker) (and (ready-bldg-has? 'lurker-den) (>= cur-hydras 1)
                         (list 'combat-unit '(morph lurker) (not worker-survival-crisis?) 150.0))]
          [(mutalisk corruptor) (and (or (ready-bldg-has? 'spire) (ready-bldg-has? 'greater-spire))
                                     (facility-slot-open? 'larva)
                                     (list 'combat-unit (list 'train u-sym) #t 135.0))]
          [(infestor) (and (facility-slot-open? 'larva 'infestation-pit)
                           (list 'combat-unit '(train infestor) #t 135.0))]
          [(viper) (and (facility-slot-open? 'larva 'hive)
                        (list 'combat-unit '(train viper) #t 145.0))]
          [(ultralisk) (and (facility-slot-open? 'larva 'ultralisk-cavern)
                            (list 'combat-unit '(train ultralisk) #t 145.0))]
          [else #f])))]

    [(Protoss)
     (define has-templar-arch?
       (or (ready-bldg-has? 'templar-archive)
           (ready-bldg-has? 'templar-archives)))
     (define has-robo-bay?
       (or (ready-bldg-has? 'robotics-bay)
           (ready-bldg-has? 'robotics-support-bay)))
     (define cur-colossus (unit-ht-count 'colossus))
     (define cur-high-templar (unit-ht-count 'high-templar))
     (define has-colossus? (>= cur-colossus 1))
     (define eff-ready-bldgs-ht
       (if (hash? raw-ready-bldg-counts)
           raw-ready-bldg-counts
           (for/fold ([ht (hasheq)]) ([b (in-list (if (list? ready-buildings) ready-buildings (if (list? ally-buildings) ally-buildings '())))])
             (if (symbol? b) (hash-update ht b add1 0) ht))))
     (define eff-total-bldgs-ht
       (if (hash? raw-total-bldg-counts)
           raw-total-bldg-counts
           (for/fold ([ht (hasheq)]) ([b (in-list (if (list? ally-buildings) ally-buildings '()))])
             (if (symbol? b) (hash-update ht b add1 0) ht))))
     (define (protoss-upg-ok? sym)
       (and (not (has-upgrade-sym? sym upgs))
            (not (memq sym upgs))
            (upgrade-allowed-by-unit-and-order-gates?
             'Protoss sym frame-val live-workers eff-ready-bldgs-ht eff-total-bldgs-ht unit-counts-ht upgs '())))
     (define upg-escalation? (or (>= active-bases 2) (>= live-workers 30)))
     (define sg-allowed-upgs (filter protoss-upg-ok? sg-rec-upgs))
     (define upg-sym
       (cond
         [(protoss-upg-ok? 'warp-gate-research) 'warp-gate-research]
         [(and upg-escalation? (pair? sg-allowed-upgs)) (car sg-allowed-upgs)]
         [(protoss-upg-ok? 'charge) 'charge]
         [(protoss-upg-ok? 'protoss-ground-weapons-1) 'protoss-ground-weapons-1]
         [(protoss-upg-ok? 'blink) 'blink]
         [(protoss-upg-ok? 'protoss-ground-armor-1) 'protoss-ground-armor-1]
         [(and has-robo-bay? has-colossus? (protoss-upg-ok? 'extended-thermal-lance)) 'extended-thermal-lance]
         [(and has-templar-arch? (protoss-upg-ok? 'psi-storm)) 'psi-storm]
         [(protoss-upg-ok? 'protoss-ground-weapons-2) 'protoss-ground-weapons-2]
         [(protoss-upg-ok? 'protoss-ground-armor-2) 'protoss-ground-armor-2]
         [(protoss-upg-ok? 'protoss-ground-weapons-3) 'protoss-ground-weapons-3]
         [(protoss-upg-ok? 'protoss-ground-armor-3) 'protoss-ground-armor-3]
         [(protoss-upg-ok? 'protoss-shields-1) 'protoss-shields-1]
         [(protoss-upg-ok? 'protoss-shields-2) 'protoss-shields-2]
         [else 'protoss-shields-3]))
     (define (protoss-upg-prereq-ok? sym)
       (if (hash? open-prod-slots)
           (case sym
             [(warp-gate-research) has-core?]
             [(charge blink resonating-glaives) (ready-bldg-has? 'twilight-council)]
             [(extended-thermal-lance) (and has-robo-bay? has-colossus?)]
             [(gravitic-drive gravitic-booster) has-robo-bay?]
             [(psi-storm) has-templar-arch?]
             [(protoss-ground-weapons-2 protoss-ground-armor-2 protoss-ground-armors-2
               protoss-ground-weapons-3 protoss-ground-armor-3 protoss-ground-armors-3
               protoss-shields-2 protoss-shields-3)
              (and (ready-bldg-has? 'forge)
                   (ready-bldg-has? 'twilight-council))]
             [(protoss-air-weapons-1 protoss-air-armor-1 protoss-air-armors-1) has-core?]
             [(protoss-air-weapons-2 protoss-air-armor-2 protoss-air-armors-2
               protoss-air-weapons-3 protoss-air-armor-3 protoss-air-armors-3)
              (and has-core? (ready-bldg-has? 'fleet-beacon))]
             [else (ready-bldg-has? 'forge)])
           #t))
     (define protoss-second-upg-sym
       (and (>= (ready-bldg-eq-count 'forge) 2)
            (for/or ([u (in-list (if (pair? sg-rec-upgs) sg-rec-upgs '()))])
              (and (not (eq? u upg-sym))
                   (not (crisis-deferred-sym? u crisis-defer?))
                   (protoss-upg-ok? u)
                   (protoss-upg-prereq-ok? u)
                   u))))
     (define robo-open?
       (and (facility-slot-open? 'robotics-facility 'robotics-facility)
            (if (hash? open-prod-slots)
                (< (unit-ht-count '(immortal colossus))
                   (if t3-endgame? 6 3))
                #t)))
     (define protoss-rush-cands
       (if (or under-early-rush-crisis? severe-crisis-static-def? pvt-fast-kiter-threat?)
           (append
            (if (and under-early-rush-crisis? (ready-bldg-has? 'pylon) (= (bldg-eq-count 'gateway) 0))
                (list (boost-cand 'gateway 'production-scaling
                                  (list 'build 'gateway (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0)))
                                  #t 500.0))
                '())
            (if (and (ready-bldg-has? 'cybernetics-core)
                     (< (bldg-eq-count 'shield-battery)
                        (if (or severe-crisis-static-def? pvt-fast-kiter-threat?) 2 1)))
                (list (boost-cand 'shield-battery 'counter-tech
                                  (list 'build 'shield-battery (safe-tile-coord (+ base-x 3.0)) (safe-tile-coord (+ base-y 3.0)))
                                  #t (cond
                                       [under-early-rush-crisis? 260.0]
                                       [pvt-fast-kiter-threat? 185.0]
                                       [else 165.0])))
                '())
            (if (and (or under-early-rush-crisis? pvt-fast-kiter-threat?)
                     (ready-bldg-has? 'cybernetics-core)
                     (or (facility-slot-open? 'gateway 'cybernetics-core)
                         (facility-slot-open? 'warp-gate 'cybernetics-core)))
                (append
                 (list (boost-cand 'stalker 'combat-unit '(train stalker) #t
                                   (if pvt-fast-kiter-threat? 290.0 280.0)))
                 (if (sg-suppressed? 'adept)
                     '()
                     (list (boost-cand 'adept 'combat-unit '(train adept) #t
                                       (if pvt-fast-kiter-threat? 250.0 240.0)))))
                '()))
           '()))
     (define has-core? (ready-bldg-has? 'cybernetics-core))
     (define has-stargate-ready? (ready-bldg-has? 'stargate))
     (define cur-adepts (unit-ht-count 'adept))
     (define cur-oracles (unit-ht-count 'oracle))
     (define cur-phoenix (unit-ht-count 'phoenix))
     (define pvz-muta-aa-needed?
       (and (eq? enemy-race 'Zerg)
            (or (> (hash-ref sg-attrs 'mutalisk-count 0) 0)
                sg-reqs-aa?)))
     (define want-oracles
       (cond
         [(or (eq? enemy-race 'Terran) enemy-cap-air? sg-suppress-opening? pvz-muta-aa-needed?) 0]
         [(eq? enemy-race 'Zerg)
          (min 1 (max (if has-stargate-ready? 1 0) (hash-ref benchmark-targets 'oracle 0)))]
         [else
          (min 1 (max (if has-stargate-ready? 1 0) (hash-ref benchmark-targets 'oracle 0)))]))
     (define gw-slot-open?
       (or (facility-slot-open? 'gateway 'cybernetics-core)
           (facility-slot-open? 'warp-gate 'cybernetics-core)))
     (define suppress-zealot?
       (and pvt-fast-kiter-threat?
            (or has-core? (>= gas-val 25) (> army-val 0.0))))
     (define protoss-ready-tech-units
       (append
        (if (and has-robo-bay?
                 (facility-slot-open? 'robotics-facility 'robotics-facility)
                 (< cur-colossus 4))
            (list (boost-cand 'colossus 'combat-unit '(train colossus) #t 150.0))
            '())
        (if (and has-robo-bay?
                 (facility-slot-open? 'robotics-facility 'robotics-facility)
                 (< (unit-ht-count '(disruptor disruptor-phased)) 2))
            (list (boost-cand 'disruptor 'combat-unit '(train disruptor) #t 140.0))
            '())
        (if (and has-templar-arch?
                 (or (facility-slot-open? 'gateway) (facility-slot-open? 'warp-gate))
                 (< cur-high-templar 4))
            (list (boost-cand 'high-templar 'combat-unit '(train high-templar) #t 145.0))
            '())
        (if (and (>= cur-high-templar 2)
                 (< (unit-ht-count 'archon) 4))
            (list (boost-cand 'archon 'combat-unit '(morph archon) #t 150.0))
            '())))
     (define pvt-immortal-robo-bay-due?
       (and (eq? enemy-race 'Terran)
            (>= sup-used 52)
            (>= (unit-ht-count 'immortal) 1)
            (ready-bldg-has? 'robotics-facility)
            (= (bldg-eq-count 'robotics-bay) 0)))
     (define protoss-t3-cands
       (append
        protoss-ready-tech-units
        ;; Anti-Capital-Air (`tempest`, `carrier`, `battlecruiser`, `brood-lord`): unlock Stargate/Void-Ray/Fleet-Beacon/Tempest
        ;; immediately regardless of base count or `t3-endgame?` (#5122493 fix).
        (if (and (or enemy-cap-air? raw-requires-anti-air?)
                 (facility-slot-open? 'stargate 'stargate)
                 (< (unit-ht-count '(void-ray voidray))
                    (if enemy-cap-air? 8 4)))
            (list (boost-cand 'void-ray 'combat-unit '(train void-ray) #t
                              (if enemy-cap-air? 172.0 135.0)))
            '())
        (if (and (ready-bldg-has? 'fleet-beacon)
                 (facility-slot-open? 'stargate 'fleet-beacon)
                 (or t3-endgame? enemy-cap-air?)
                 (< (unit-ht-count 'tempest)
                    (if enemy-cap-air? 10 3)))
            (list (boost-cand 'tempest 'combat-unit '(train tempest) #t
                              (if enemy-cap-air? 185.0 145.0)))
            '())
        (if (and (not (crisis-deferred-sym? 'stargate crisis-defer? #:defer-stargate? defer-stargate?))
                 (or enemy-cap-air?
                     (and t3-endgame?
                          (>= active-bases 4)
                          (not (and (<= active-bases 2)
                                    (not raw-requires-anti-air?)
                                    (not raw-requires-detection?)
                                    (> (bldg-eq-count 'robotics-facility) 0)
                                    (> (bldg-eq-count 'twilight-council) 0)))))
                 has-core?
                 (< (bldg-eq-count 'stargate)
                    (if (and enemy-cap-air? (>= active-bases 2)) 2 1)))
            (list (boost-cand 'stargate 'production-scaling
                              (list 'build 'stargate (safe-tile-coord (+ base-x 5.5)) (safe-tile-coord (+ base-y 5.5)))
                              #t (if enemy-cap-air? 172.0 140.0)))
            '())
        (if (and (not crisis-defer?)
                 (or enemy-cap-air? (and t3-endgame? (>= active-bases 4)))
                 has-stargate-ready?
                 (= (bldg-eq-count 'fleet-beacon) 0))
            (list (boost-cand 'fleet-beacon 'tech-upgrade
                              (list 'build 'fleet-beacon (safe-tile-coord (- base-x 6.5)) (safe-tile-coord (+ base-y 5.5)))
                              #t (if enemy-cap-air? 180.0 150.0)))
            '())
        (if (and (not crisis-defer?)
                 has-core?
                 (or t3-endgame? upg-escalation? (> (sg-rec-bonus 'forge) 0.0))
                 (< (bldg-eq-count 'forge)
                    (if (or upg-escalation? (> (sg-rec-bonus 'forge) 0.0)) 2 1)))
            (list (boost-cand 'forge 'production-scaling
                              (list 'build 'forge (safe-tile-coord (+ base-x 3.5)) (safe-tile-coord (- base-y 4.5)))
                              (or t3-endgame? (> (sg-rec-bonus 'forge) 0.0) (>= min-val 300))
                              (if (or t3-endgame? (> (sg-rec-bonus 'forge) 0.0)) 152.0 35.0)))
            '())
        (if (and pvz-muta-aa-needed?
                 (facility-slot-open? 'stargate 'stargate)
                 (< cur-phoenix 6))
            (list (boost-cand 'phoenix 'counter-tech '(train phoenix) #t 180.0))
            '())
        (if (and (not crisis-defer?)
                 (or t3-endgame?
                     pvt-immortal-robo-bay-due?
                     (> (sg-rec-bonus 'robotics-bay) 0.0)
                     (> (sg-rec-bonus 'templar-archive) 0.0)
                     (and (>= active-bases 3) (> (sg-rec-bonus 'twilight-council) 0.0))))
            (append
             (if (and (ready-bldg-has? 'robotics-facility)
                      (= (bldg-eq-count 'robotics-bay) 0)
                      (or t3-endgame?
                          pvt-immortal-robo-bay-due?
                          (> (sg-rec-bonus 'robotics-bay) 0.0)))
                 (list (boost-cand 'robotics-bay 'tech-upgrade
                                   (list 'build 'robotics-bay (safe-tile-coord (+ base-x 6.5)) (safe-tile-coord (- base-y 4.5)))
                                   (or t3-endgame? pvt-immortal-robo-bay-due? (>= min-val 300))
                                   (+ (cond
                                        [pvt-immortal-robo-bay-due? 195.0]
                                        [t3-endgame? 150.0]
                                        [else 60.0])
                                      (sg-rec-bonus 'robotics-bay))))
                 '())
             (if (and t3-endgame? has-core? (= (bldg-eq-count 'twilight-council) 0))
                 (list (boost-cand 'twilight-council 'tech-upgrade
                                   (list 'build 'twilight-council (safe-tile-coord (- base-x 4.5)) (safe-tile-coord (+ base-y 4.5)))
                                   #t 145.0))
                 '())
             (if (and (ready-bldg-has? 'twilight-council)
                      (= (bldg-eq-count 'templar-archive) 0)
                      (or t3-endgame? (> (sg-rec-bonus 'templar-archive) 0.0)))
                 (list (boost-cand 'templar-archive 'tech-upgrade
                                   (list 'build 'templar-archive (safe-tile-coord (- base-x 5.5)) (safe-tile-coord (- base-y 4.5)))
                                   (or t3-endgame? (>= min-val 300))
                                   (+ (if t3-endgame? 150.0 60.0) (sg-rec-bonus 'templar-archive))))
                 '())
             (if (and (>= active-bases 4)
                      (ready-bldg-has? 'fleet-beacon)
                      (facility-slot-open? 'stargate 'fleet-beacon)
                      (< (unit-ht-count 'carrier) 4))
                 (list (boost-cand 'carrier 'combat-unit '(train carrier) #t 150.0))
                 '()))
            '())))
     (define protoss-base-cands
       (append
        protoss-rush-cands
        (list
         (cand 'pylon 'supply (list 'build 'pylon (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0))) supply-urgent?)
         (cand 'photon-cannon 'counter-tech (list 'build 'photon-cannon nat-x nat-y)
               (if (hash? open-prod-slots) (and (or sg-reqs-aa? sg-reqs-det?) (ready-bldg-has? 'forge)) #t))
         (boost-cand 'robotics-facility 'counter-tech (list 'build 'robotics-facility (safe-tile-coord (+ base-x 6.0)) (safe-tile-coord (+ base-y 6.0)))
                     (if (hash? open-prod-slots)
                         (and has-core?
                              (< (bldg-eq-count 'robotics-facility) (if (or sg-high-bank? (> (sg-rec-bonus 'robotics-facility) 0.0)) 2 1)))
                         #t)
                     (sg-rec-bonus 'robotics-facility))
         (cand 'observer 'counter-tech '(train observer)
               (and (facility-slot-open? 'robotics-facility 'robotics-facility)
                    (if (hash? open-prod-slots) (< (unit-ht-count 'observer) (if sg-reqs-det? 2 1)) #t)))
         (boost-cand 'stalker 'combat-unit '(train stalker)
                     gw-slot-open?
                     (max (cond
                            [pvt-fast-kiter-threat? 185.0]
                            [enemy-cap-air? 155.0]
                            [else 0.0])
                          (sg-rec-bonus 'stalker)))
         (boost-cand 'immortal 'combat-unit '(train immortal) robo-open? (sg-rec-bonus 'immortal)))
        (if (sg-suppressed? 'adept)
            '()
            (list
             (boost-cand 'adept 'combat-unit '(train adept)
                         (and gw-slot-open?
                              (or (not (hash? open-prod-slots))
                                  pvt-fast-kiter-threat?
                                  (and (not (ready-bldg-has? 'twilight-council))
                                       (or (eq? enemy-race 'Zerg) (< frame-val 3200))
                                       (< cur-adepts (max (if (eq? enemy-race 'Zerg) 2 1)
                                                          (hash-ref benchmark-targets 'adept 0))))))
                         (if pvt-fast-kiter-threat?
                             175.0
                             (if (and (< cur-adepts 2) (eq? enemy-race 'Zerg)) 25.0 0.0)))))
        (if (and has-stargate-ready?
                 (not enemy-cap-air?)
                 (not (sg-suppressed? 'oracle))
                 (facility-slot-open? 'stargate 'stargate)
                 (< cur-oracles want-oracles))
            (list (boost-cand 'oracle 'combat-unit '(train oracle) #t
                              (if (= cur-oracles 0) 145.0 130.0)))
            '())
        (if suppress-zealot?
            '()
            (list (cand 'zealot 'combat-unit '(train zealot)
                        (or (facility-slot-open? 'gateway) (facility-slot-open? 'warp-gate)))))
        (if (crisis-deferred-sym? upg-sym crisis-defer?)
            '()
            (list
             (cand upg-sym 'tech-upgrade (list 'research upg-sym)
                   (protoss-upg-prereq-ok? upg-sym))))
        (if protoss-second-upg-sym
            (list (cand protoss-second-upg-sym 'tech-upgrade (list 'research protoss-second-upg-sym) #t))
            '())
        (list
         (cand 'gateway 'production-scaling (list 'build 'gateway (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0)))
               (if (hash? open-prod-slots)
                   (let ([cur-gates (bldg-eq-count 'gateway)]
                         [gate-cap (max raw-max-facilities
                                        (cond
                                          [sg-high-bank? 10]
                                          [(>= active-bases 3) 8]
                                          [(>= active-bases 2) (if (or (>= live-workers 34) (>= min-val 400)) 6 4)]
                                          [(memq enemy-race '(Protoss Random)) 2]
                                          [else 1]))])
                     (and (< cur-gates gate-cap)
                          (or (< cur-gates 3)
                              (not gw-slot-open?)
                              (>= min-val 400))
                          (or (> active-bases 1)
                              (and (memq enemy-race '(Protoss Random)) (< cur-gates 2))
                              (< raw-prod-facilities 1)
                              (not escrow-ok?)
                              (< raw-frame 1500)
                              (>= (- raw-minerals 400) (sc2-min-cost 'gateway)))))
                   #t))
         (cand 'probe 'worker '(train probe) #f)
         (cand 'nexus 'expansion (list 'expand exp-x exp-y) exp-blocking?))
        protoss-t3-cands))
     (append-benchmark-unit-cands
      protoss-base-cands
      (lambda (u-sym)
        (case u-sym
          [(sentry) (and gw-slot-open?
                         (< (unit-ht-count 'sentry) (if (>= active-bases 4) 3 2))
                         (list 'combat-unit '(train sentry) #t 130.0))]
          [(warp-prism) (and (facility-slot-open? 'robotics-facility 'robotics-facility)
                             (list 'combat-unit '(train warp-prism) #t 135.0))]
          [(phoenix) (and (not (eq? enemy-race 'Terran))
                          (or pvz-muta-aa-needed?
                              (and (not enemy-cap-air?)
                                   (not (sg-suppressed? 'phoenix))
                                   (< cur-phoenix 1)))
                          (facility-slot-open? 'stargate 'stargate)
                          (list 'counter-tech '(train phoenix) #t 135.0))]
          [(colossus disruptor) (and has-robo-bay?
                                     (facility-slot-open? 'robotics-facility 'robotics-facility)
                                     (list 'combat-unit (list 'train u-sym) #t 145.0))]
          [(high-templar) (and has-templar-arch?
                               (or (facility-slot-open? 'gateway) (facility-slot-open? 'warp-gate))
                               (list 'combat-unit '(train high-templar) #t 140.0))]
          [(archon) (and (>= cur-high-templar 2)
                         (list 'combat-unit '(morph archon) #t 145.0))]
          [else #f])))]

    [else ;; Terran
     (define has-rax-tl?
       (or (ready-bldg-has? 'barracks-techlab)
           (ready-bldg-has? 'barracks-tech-lab)))
     (define has-fac-tl?
       (or (ready-bldg-has? 'factory-techlab)
           (ready-bldg-has? 'factory-tech-lab)))
     (define has-port-tl?
       (or (ready-bldg-has? 'starport-techlab)
           (ready-bldg-has? 'starport-tech-lab)))
     (define has-fusion-core? (ready-bldg-has? 'fusion-core))
     (define has-rax-ready? (ready-bldg-has? 'barracks))
     (define has-fac-ready? (ready-bldg-has? 'factory))
     (define has-port-ready? (ready-bldg-has? 'starport))
     (define cur-medivacs (unit-ht-count 'medivac))
     (define cur-thors (unit-ht-count '(thor thor-ap)))
     (define eff-ready-bldgs-ht
       (if (hash? raw-ready-bldg-counts)
           raw-ready-bldg-counts
           (for/fold ([ht (hasheq)]) ([b (in-list (if (list? ready-buildings) ready-buildings (if (list? ally-buildings) ally-buildings '())))])
             (if (symbol? b) (hash-update ht b add1 0) ht))))
     (define eff-total-bldgs-ht
       (if (hash? raw-total-bldg-counts)
           raw-total-bldg-counts
           (for/fold ([ht (hasheq)]) ([b (in-list (if (list? ally-buildings) ally-buildings '()))])
             (if (symbol? b) (hash-update ht b add1 0) ht))))
     (define (terran-upg-ok? sym)
       (and (not (memq sym upgs))
            (upgrade-allowed-by-unit-and-order-gates?
             'Terran sym frame-val live-workers eff-ready-bldgs-ht eff-total-bldgs-ht unit-counts-ht upgs '())))
     (define upg-escalation? (or (>= active-bases 2) (>= live-workers 30)))
     (define sg-allowed-upgs
       (filter terran-upg-ok? sg-rec-upgs))
     (define upg-sym
       (cond
         [(terran-upg-ok? 'stimpack) 'stimpack]
         [(and upg-escalation? (pair? sg-allowed-upgs)) (car sg-allowed-upgs)]
         [(terran-upg-ok? 'combat-shield) 'combat-shield]
         [(terran-upg-ok? 'terran-infantry-weapons-1) 'terran-infantry-weapons-1]
         [(terran-upg-ok? 'terran-infantry-armor-1) 'terran-infantry-armor-1]
         [(terran-upg-ok? 'concussive-shells) 'concussive-shells]
         [(and has-fusion-core? has-port-tl? (not (memq 'advanced-ballistics upgs))) 'advanced-ballistics]
         [(and has-fusion-core? (>= active-bases 4) (not (memq 'weapon-refit upgs))) 'weapon-refit]
         [(not (memq 'terran-infantry-weapons-2 upgs)) 'terran-infantry-weapons-2]
         [(not (memq 'terran-infantry-armor-2 upgs)) 'terran-infantry-armor-2]
         [(not (memq 'terran-infantry-weapons-3 upgs)) 'terran-infantry-weapons-3]
         [(not (memq 'terran-infantry-armor-3 upgs)) 'terran-infantry-armor-3]
         [(terran-upg-ok? 'banshee-cloak) 'banshee-cloak]
         [else 'terran-vehicle-weapons-1]))
     (define (terran-upg-prereq-ok? sym)
       (if (hash? open-prod-slots)
           (case sym
             [(stimpack combat-shield concussive-shells) has-rax-tl?]
             [(terran-infantry-weapons-2 terran-infantry-armor-2 terran-infantry-armors-2
               terran-infantry-weapons-3 terran-infantry-armor-3 terran-infantry-armors-3)
              (and (ready-bldg-has? 'engineering-bay)
                   (ready-bldg-has? 'armory))]
             [(terran-vehicle-weapons-1 terran-vehicle-weapons-2 terran-vehicle-weapons-3 vehicle-weapons-1
               terran-vehicle-and-ship-plating-1 terran-vehicle-and-ship-plating-2 terran-vehicle-and-ship-plating-3
               terran-vehicle-and-ship-armors-1 terran-vehicle-and-ship-armors-2 terran-vehicle-and-ship-armors-3
               terran-ship-weapons-1 terran-ship-weapons-2 terran-ship-weapons-3)
              (ready-bldg-has? 'armory)]
             [(advanced-ballistics) (and has-fusion-core? has-port-tl?)]
             [(weapon-refit) has-fusion-core?]
             [(banshee-cloak) has-port-tl?]
             [else (ready-bldg-has? 'engineering-bay)])
           #t))
     (define terran-second-upg-sym
       (and (or (>= (ready-bldg-eq-count 'engineering-bay) 2)
                (and (ready-bldg-has? 'engineering-bay) (ready-bldg-has? 'armory)))
            (for/or ([u (in-list (if (pair? sg-rec-upgs) sg-rec-upgs '()))])
              (and (not (eq? u upg-sym))
                   (not (crisis-deferred-sym? u crisis-defer?))
                   (terran-upg-ok? u)
                   (terran-upg-prereq-ok? u)
                   u))))
     (define has-fac-tl-any?
       (or has-fac-tl?
           (bldg-has? 'factory-techlab)
           (bldg-has? 'factory-tech-lab)))
     (define terran-rush-cands
       (if (or under-early-rush-crisis? severe-crisis-static-def?)
           (append
            (if (and under-early-rush-crisis? (ready-bldg-has? 'supply-depot) (not (bldg-has? 'barracks)))
                (list (boost-cand 'barracks 'production-scaling
                                  (list 'build 'barracks (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0)))
                                  #t 500.0))
                '())
            (if (and root-combat-ready? (< (bldg-eq-count 'bunker) (if severe-crisis-static-def? 2 1)))
                (list (boost-cand 'bunker 'counter-tech
                                  (list 'build 'bunker (safe-tile-coord (+ base-x 3.5)) (safe-tile-coord (- base-y 3.0)))
                                  #t (if under-early-rush-crisis? 260.0 165.0)))
                '()))
           '()))
     (define desired-rax-tl
       (terran-desired-barracks-techlabs race enemy-race (bldg-eq-count 'barracks)))
     (define cur-rax-addons
       (+ (bldg-eq-count 'barracks-techlab) (bldg-eq-count 'barracks-reactor)))
     (define desired-factories
       (terran-desired-factories race enemy-race active-bases sup-used))
     (define cur-fac-addons
       (+ (bldg-eq-count 'factory-techlab) (bldg-eq-count 'factory-reactor)))
     (define desired-ghost-cap
       (terran-desired-ghost-cap active-bases sup-used enemy-race enemy-u-counts))
     (define desired-lib-cap
       (terran-desired-liberator-cap active-bases enemy-u-counts))
     (define terran-t3-cands
       (append
        ;; TvT Barracks TechLab + 2nd Factory scaling (#5123417, #5123667)
        (if (and (memq enemy-race '(Terran Protoss))
                 (< (bldg-eq-count 'barracks-techlab) desired-rax-tl)
                 (> (ready-bldg-eq-count 'barracks) cur-rax-addons)
                 (facility-slot-open? 'barracks 'barracks))
            (list (boost-cand 'barracks-techlab 'production-scaling
                              (list 'build 'barracks-techlab (safe-tile-coord (+ base-x 7.5)) (safe-tile-coord (+ base-y 3.0)))
                              #t 145.0))
            '())
        (if (and (>= desired-factories 2)
                 (< (bldg-eq-count 'factory) desired-factories)
                 has-rax-ready?)
            (list (boost-cand 'factory 'production-scaling
                              (list 'build 'factory (safe-tile-coord (+ base-x 6.0)) (safe-tile-coord (+ base-y 2.5)))
                              #t 150.0))
            '())
        ;; Ready-tech / enemy-triggered Ghost Academy (`>= 2` bases when mass Queen/Infestor/HT/Lurker/Viper),
        ;; Ghosts (< 10) & Liberators (< 6-8) (#5123937)
        (if (and has-rax-ready?
                 (= (bldg-eq-count 'ghost-academy) 0)
                 (or t3-endgame?
                     (> (sg-rec-bonus 'ghost-academy) 0.0)
                     (and (>= active-bases 2)
                          (or (eq? enemy-race 'Protoss)
                              (terran-enemy-needs-ghost? enemy-u-counts)))))
            (list (boost-cand 'ghost-academy 'tech-upgrade
                              (list 'build 'ghost-academy (safe-tile-coord (- base-x 4.5)) (safe-tile-coord (- base-y 4.5)))
                              #t (max (if (terran-enemy-needs-ghost? enemy-u-counts) 172.0 140.0)
                                      (+ 140.0 (sg-rec-bonus 'ghost-academy)))))
            '())
        ;; [BUG-4] Multi-Starport + StarportReactor scaling vs enemy capital air (FastBC / Tempest / Carrier / BroodLord)
        (if (and enemy-cap-air?
                 has-fac-ready?
                 (< (bldg-eq-count 'starport) (if (>= active-bases 3) 3 2)))
            (list (boost-cand 'starport 'production-scaling
                              (list 'build 'starport (safe-tile-coord (+ base-x 7.0)) (safe-tile-coord (- base-y 2.5)))
                              #t 172.0))
            '())
        (if (and enemy-cap-air?
                 (hash? open-prod-slots)
                 (> (ready-bldg-eq-count 'starport)
                    (+ (bldg-eq-count 'starport-techlab) (bldg-eq-count 'starport-reactor)))
                 (< (bldg-eq-count 'starport-reactor) (if (>= active-bases 3) 2 1))
                 (or (>= (bldg-eq-count 'starport-techlab) 1)
                     (>= (bldg-eq-count 'starport) 2)
                     (not raw-requires-detection?)))
            (list (boost-cand 'starport-reactor 'production-scaling
                              (list 'build 'starport-reactor (safe-tile-coord (+ base-x 9.5)) (safe-tile-coord (- base-y 2.0)))
                              #t 168.0))
            '())
        (if (and (facility-slot-open? 'starport 'starport)
                 (or t3-endgame?
                     (and (>= active-bases 3) (terran-enemy-needs-liberator? enemy-u-counts))
                     (and (>= active-bases 3) (>= cur-medivacs 2)))
                 (< (unit-ht-count '(liberator liberator-ag)) desired-lib-cap))
            (list (boost-cand 'liberator 'combat-unit '(train liberator) #t
                              (if (terran-enemy-needs-liberator? enemy-u-counts) 165.0 145.0)))
            '())
        (if (and (facility-slot-open? 'barracks 'ghost-academy)
                 has-rax-tl?
                 (< (unit-ht-count 'ghost) desired-ghost-cap))
            (list (boost-cand 'ghost 'combat-unit '(train ghost) #t 155.0))
            '())
        ;; [NOTE-R4-B] Anti-Capital-Air (`tempest`, `carrier`, `battlecruiser`, `brood-lord`):
        ;; unlock Armory + Thors (< 5-6) outside `t3-endgame?`, plus `+1` Ship Weapons when air fleet >= 4.
        (if (and has-fac-ready?
                 (= (bldg-eq-count 'armory) 0)
                 (or (and enemy-cap-air? (or enemy-cap-air-ground-aa? has-fac-tl-any?))
                     (and (not crisis-defer?)
                          (or (> (sg-rec-bonus 'armory) 0.0)
                              (and (>= active-bases 2) (>= live-workers 30))))))
            (list (boost-cand 'armory 'tech-upgrade
                              (list 'build 'armory (safe-tile-coord (+ base-x 6.5)) (safe-tile-coord (- base-y 4.5)))
                              #t (max (if enemy-cap-air-ground-aa? 185.0 165.0)
                                      (+ 145.0 (sg-rec-bonus 'armory)))))
            '())
        (if (and (facility-slot-open? 'factory 'armory)
                 has-fac-tl?
                 enemy-cap-air?
                 (< cur-thors desired-thor-cap))
            (list (boost-cand 'thor 'combat-unit '(train thor) #t
                              (if enemy-cap-air-ground-aa? 180.0 160.0)))
            '())
        (if (and ship-weap-due?
                 (not (crisis-deferred-sym? 'terran-ship-weapons-1 crisis-defer? #:keep-ship-weapons? #t))
                 (or (not (hash? open-prod-slots))
                     (> (hash-ref open-prod-slots 'armory 1) 0)))
            (list (boost-cand 'terran-ship-weapons-1 'tech-upgrade '(research terran-ship-weapons-1)
                              #t 175.0))
            '())
        (if t3-endgame?
            (append
             (if (and has-fac-ready? (not (bldg-has? 'armory)))
                 (list (boost-cand 'armory 'tech-upgrade
                                   (list 'build 'armory (safe-tile-coord (+ base-x 6.5)) (safe-tile-coord (- base-y 4.5)))
                                   #t 150.0))
                 '())
             (if (and (not crisis-defer?) has-port-ready? (= (bldg-eq-count 'fusion-core) 0))
                 (list (boost-cand 'fusion-core 'tech-upgrade
                                   (list 'build 'fusion-core (safe-tile-coord (- base-x 5.5)) (safe-tile-coord (+ base-y 4.5)))
                                   #t 145.0))
                 '())
             (if (and (facility-slot-open? 'starport 'starport)
                      (< cur-medivacs 4))
                 (list (boost-cand 'medivac 'combat-unit '(train medivac) #t 140.0))
                 '())
             (if (and (facility-slot-open? 'factory 'armory)
                      has-fac-tl?
                      (< cur-thors (max 4 desired-thor-cap)))
                 (list (boost-cand 'thor 'combat-unit '(train thor) #t 150.0))
                 '())
             (if (and (>= active-bases 4)
                      (facility-slot-open? 'starport 'fusion-core)
                      has-port-tl?
                      (< (unit-ht-count 'battlecruiser) 4))
                 (list (boost-cand 'battlecruiser 'combat-unit '(train battlecruiser) #t 155.0))
                 '()))
            '())))
     (define cur-rax-cnt (bldg-eq-count 'barracks))
     (define cur-fac-cnt (bldg-eq-count 'factory))
     (define cur-tanks-cnt (unit-ht-count '(siege-tank siege-tank-sieged)))
     (define cur-widow-mines (unit-ht-count '(widow-mine widow-mine-burrowed)))
     (define cur-ravens (unit-ht-count 'raven))
     (define tvp-suppress-extra-rax?
       (suppress-terran-extra-barracks-for-tvp-factory?
        race enemy-race cur-rax-cnt cur-fac-cnt cur-tanks-cnt min-val frame-val
        (bldg-eq-count 'refinery) gas-val enemy-u-counts enemy-b-counts))
     (define tvp-factory-due-now?
       (and (= cur-fac-cnt 0)
            has-rax-ready?
            (or tvp-cannon-contain?
                (and (eq? enemy-race 'Protoss)
                     (or (>= gas-val 60) (> (bldg-eq-count 'refinery) 0) (>= frame-val 1800))))))
     (define want-widow-mines
       (max (if (and has-fac-ready? (memq enemy-race '(Zerg Protoss))) 2 0)
            (hash-ref benchmark-targets 'widow-mine 0)))
     (define want-ravens
       (max (if (and has-port-ready? has-port-tl?)
                (cond
                  [(or sg-reqs-det? (eq? enemy-race 'Terran) (> (sg-rec-bonus 'raven) 0.0)) 2]
                  [else 1])
                0)
            (hash-ref benchmark-targets 'raven 0)))
     (define terran-base-cands
       (append
        terran-rush-cands
        (if (and (facility-slot-open? 'factory 'armory)
                 (< (unit-ht-count '(hellbat hellion-tank)) 12)
                 (or (> (sg-rec-bonus 'hellbat) 0.0)
                     (and (eq? enemy-race 'Zerg) (>= (hash-ref sg-attrs 'zergling-count 0) 6))))
            (list (boost-cand 'hellbat 'combat-unit '(train hellbat) #t (+ 155.0 (sg-rec-bonus 'hellbat))))
            '())
        (if tvp-factory-due-now?
            (list (boost-cand 'factory 'production-scaling
                              (list 'build 'factory (safe-tile-coord (+ base-x 6.0)) (safe-tile-coord (+ base-y 2.5)))
                              #t (if tvp-cannon-contain? 220.0 165.0)))
            '())
        (if (and (hash? open-prod-slots)
                 (facility-slot-open? 'factory 'factory)
                 (> (ready-bldg-eq-count 'factory) cur-fac-addons)
                 (or (< (bldg-eq-count 'factory-techlab) desired-factories)
                     (and tvp-cannon-contain? (not has-fac-tl-any?))))
            (list (boost-cand 'factory-techlab 'counter-tech
                              (list 'build 'factory-techlab (safe-tile-coord (+ base-x 8.5)) (safe-tile-coord (+ base-y 3.0)))
                              #t (if tvp-cannon-contain? 210.0 0.0)))
            '())
        (list
         (cand 'supply-depot 'supply (list 'build 'supply-depot (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (- base-y 3.0))) supply-urgent?)
         (cand 'missile-turret 'counter-tech (list 'build 'missile-turret (safe-tile-coord (+ base-x 3.0)) (safe-tile-coord (+ base-y 3.0)))
               (if (hash? open-prod-slots) (and (or sg-reqs-aa? sg-reqs-det?) (ready-bldg-has? 'engineering-bay)) #t))
         (boost-cand 'engineering-bay 'counter-tech (list 'build 'engineering-bay (safe-tile-coord (+ base-x 5.0)) (safe-tile-coord (- base-y 3.0)))
                     (if (hash? open-prod-slots)
                         (and (ready-bldg-has? 'barracks)
                              (or sg-reqs-aa?
                                  sg-reqs-det?
                                  (and (>= active-bases 2)
                                       (>= live-workers 30)
                                       (ready-bldg-has? 'factory)))
                              (< (bldg-eq-count 'engineering-bay) 2))
                         #t)
                     (if (and upg-escalation?
                              (ready-bldg-has? 'barracks)
                              (>= active-bases 2)
                              (>= live-workers 30)
                              (ready-bldg-has? 'factory)
                              (< (bldg-eq-count 'engineering-bay) 2))
                         142.0
                         0.0))
         (boost-cand 'viking-fighter 'counter-tech '(train viking-fighter)
                     (facility-slot-open? 'starport 'starport)
                     (if (and has-port-ready?
                              (< (unit-ht-count '(viking viking-fighter viking-assault))
                                 (if enemy-cap-air?
                                     20
                                     (max 2 (hash-ref benchmark-targets 'viking-fighter 0)))))
                         (max (if enemy-cap-air? 185.0 135.0) (sg-rec-bonus 'viking-fighter))
                         (sg-rec-bonus 'viking-fighter)))
         (boost-cand 'marauder 'combat-unit '(train marauder)
                     (if (hash? open-prod-slots) (and (facility-slot-open? 'barracks 'barracks) has-rax-tl?) #t)
                     (sg-rec-bonus 'marauder))
         (boost-cand 'siege-tank 'combat-unit '(train siege-tank)
                     (if (hash? open-prod-slots) (and (facility-slot-open? 'factory 'factory) has-fac-tl?) #t)
                     (max (if (and tvp-cannon-contain? (< cur-tanks-cnt 3)) 225.0 0.0) (sg-rec-bonus 'siege-tank)))
         (cand 'marine 'combat-unit '(train marine)
               (facility-slot-open? 'barracks 'barracks)))
        (if (and (facility-slot-open? 'factory 'factory)
                 (< cur-widow-mines want-widow-mines))
            (list (boost-cand 'widow-mine 'combat-unit '(train widow-mine) #t 135.0))
            '())
        (if (and (facility-slot-open? 'starport 'starport)
                 has-port-tl?
                 (< cur-ravens want-ravens))
            (list (boost-cand 'raven 'counter-tech '(train raven) #t
                              (if (and sg-reqs-det? (= cur-ravens 0)) 180.0 135.0)))
            '())
        (if (crisis-deferred-sym? upg-sym crisis-defer?)
            '()
            (list
             (cand upg-sym 'tech-upgrade (list 'research upg-sym)
                   (terran-upg-prereq-ok? upg-sym))))
        (if terran-second-upg-sym
            (list (cand terran-second-upg-sym 'tech-upgrade (list 'research terran-second-upg-sym) #t))
            '())
        (list
         (cand 'barracks 'production-scaling (list 'build 'barracks (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0)))
               (if (hash? open-prod-slots)
                   (let ([cur-rax (bldg-eq-count 'barracks)]
                         [rax-cap (max raw-max-facilities
                                       (cond
                                         [sg-high-bank? 10]
                                         [(>= active-bases 3) 8]
                                         [(>= active-bases 2) (if (or (>= live-workers 34) (>= min-val 400)) 5 3)]
                                         [else 2]))])
                     (and (not tvp-suppress-extra-rax?)
                          (< cur-rax rax-cap)
                          (or (and (>= active-bases 2)
                                   (or (< cur-rax 3) (>= live-workers 20) (>= min-val 350)))
                              (< raw-prod-facilities 1)
                              (not escrow-ok?)
                              (< raw-frame 1500)
                              (>= (- raw-minerals 400) (sc2-min-cost 'barracks)))))
                   #t))
         (cand 'scv 'worker '(train scv) cannon-worker-recover?)
         (cand 'command-center 'expansion (list 'expand exp-x exp-y) exp-blocking?))
        terran-t3-cands))
     (append-benchmark-unit-cands
      terran-base-cands
      (lambda (u-sym)
        (case u-sym
          [(reaper) (and (not (sg-suppressed? 'reaper))
                         (facility-slot-open? 'barracks 'barracks)
                         (list 'combat-unit '(train reaper) #t 130.0))]
          [(hellion) (and (facility-slot-open? 'factory 'factory)
                          (list 'combat-unit '(train hellion) #t 130.0))]
          [(cyclone) (and (facility-slot-open? 'factory 'factory) has-fac-tl?
                          (list 'combat-unit '(train cyclone) #t 140.0))]
          [(thor) (and (facility-slot-open? 'factory 'armory) has-fac-tl?
                       (list 'combat-unit '(train thor) #t 145.0))]
          [(medivac liberator) (and (facility-slot-open? 'starport 'starport)
                                    (list 'combat-unit (list 'train u-sym) #t 140.0))]
          [(banshee) (and (facility-slot-open? 'starport 'starport) has-port-tl?
                          (list 'combat-unit '(train banshee) #t 140.0))]
          [(ghost) (and (facility-slot-open? 'barracks 'ghost-academy) has-rax-tl?
                        (list 'combat-unit '(train ghost) #t 145.0))]
          [(battlecruiser) (and (facility-slot-open? 'starport 'fusion-core) has-port-tl?
                                (list 'combat-unit '(train battlecruiser) #t 145.0))]
          [else #f])))]))

;; Computes reserved minerals for the natural expansion (`400M` Terran/Protoss, `300M` Zerg)
;; when on 1 base (`active-bases + pending-bases < 2`) at `frame >= 1500` (or `workers >= 18/15`)
;; without active base attack or enemy threat, preventing a `150M` 2nd Barracks or Gateway
;; from starving the natural TownHall (Match 5115348 root-cause fix).
;; When `natural-blocked?` is `#t`, returns `0` below `350M` (preserving PV1) and allows
;; reservation at `>= 350M` (`army-supply >= 6` or `frame >= 2688`) for 3rd-base redirect.
(define (compute-natural-expansion-mineral-reserve
         #:race [raw-race 'Terran]
         #:frame [raw-frame 0]
         #:active-bases [raw-active-bases 1]
         #:pending-bases [raw-pending-bases 0]
         #:workers [raw-workers 12]
         #:minerals [raw-minerals 0]
         #:army-supply [raw-army-supply 0]
         #:under-attack? [under-attack? #f]
         #:enemy-threat-supply [enemy-threat 0]
         #:natural-blocked? [natural-blocked? #f]
         #:escrow-expired? [escrow-expired? #f])
  (define race (normalize-ledger-race raw-race))
  (define total-bases (+ (safe-nonneg-int raw-active-bases 1)
                         (safe-nonneg-int raw-pending-bases 0)))
  (define frame (safe-nonneg-int raw-frame 0))
  (define workers (safe-nonneg-int raw-workers 12))
  (define minerals (safe-nonneg-int raw-minerals 0))
  (define army-sup (safe-real raw-army-supply 0.0))
  (if (and (< total-bases 2)
           (not under-attack?)
           (< (safe-real enemy-threat 0.0) 6.0)
           (or (not natural-blocked?)
               (and (>= minerals 350)
                    (or (>= army-sup 6.0) (>= frame 2688))))
           (not escrow-expired?)
           (or (and (>= frame (case race [(Zerg) 1000] [(Protoss) 1200] [else 1450]))
                    (>= workers 12))
               (>= workers (if (eq? race 'Zerg) 16 19))))
      (sc2-race-townhall-min-cost race)
      0))

(define (schedule-priority-candidates-with-ledger!
         candidates
         #:minerals [raw-minerals 200]
         #:gas [raw-gas 0]
         #:supply-left [raw-supply-left 4]
         #:supply-cap [raw-supply-cap 200]
         #:escrow-eligible? [escrow-eligible? #f])
  (define init-min (safe-nonneg-int raw-minerals 0))
  (define init-gas (safe-nonneg-int raw-gas 0))
  (define init-sup (max 0 (safe-exact-int raw-supply-left 0)))
  (define supply-cap (min 200 (max 1 (safe-nonneg-int raw-supply-cap 200))))
  (define ledger (make-symbiotic-ledger init-min init-gas init-sup))
  (define cands (if (list? candidates) (filter priority-candidate? candidates) '()))

  ;; Insert all candidates into an Okasaki Braun heap keyed by (- effective-utility)
  ;; PV1: When (not escrow-eligible?), an 'expansion candidate NEVER outranks
  ;; affordable 'tech-upgrade, 'counter-tech, 'production-scaling, or 'combat-unit.
  (define min-non-exp-utility
    (for/fold ([acc +inf.0])
              ([c (in-list cands)]
               #:when (memq (priority-candidate-category c)
                            '(tech-upgrade counter-tech production-scaling combat-unit)))
      (min acc (safe-real (priority-candidate-utility-score c) 100.0))))

  (define keyed-cands
    (for/list ([c (in-list cands)]
               [idx (in-naturals)])
      (define raw-u (safe-real (priority-candidate-utility-score c) 0.0))
      (define eff-u
        (if (and (eq? (priority-candidate-category c) 'expansion)
                 (or (not escrow-eligible?)
                     (not (priority-candidate-blocking-allowed? c)))
                 (not (infinite? min-non-exp-utility)))
            (min raw-u (- min-non-exp-utility 1.0))
            raw-u))
      (cons (+ (- eff-u) (* 1e-7 idx)) c)))

  ;; Sort candidates in descending utility order (tie-breaking by index)
  (define sorted-cands
    (map cdr (sort keyed-cands < #:key car)))

  ;; Track category -> max utility-score map & candidate id -> utility map
  (define cat-utils0
    (for/fold ([ht (hash)])
              ([c (in-list sorted-cands)])
      (define cat (priority-candidate-category c))
      (define u (safe-real (priority-candidate-utility-score c) 0.0))
      (hash-set ht cat (max u (hash-ref ht cat -inf.0)))))
  (define cand-utils
    (for/fold ([ht (hash)])
              ([c (in-list sorted-cands)])
      (hash-set ht (priority-candidate-id c) (safe-real (priority-candidate-utility-score c) 0.0))))

  (define rem-min init-min)
  (define rem-gas init-gas)
  (define rem-sup init-sup)
  (define scheduled-cands '())
  (define reserved-cand #f)
  (define decision-entries '())
  ;; Each escrowed entry is (list utility min-cost gas-cost id category)
  (define escrowed-entries '())

  ;; Orthogonal mineral & gas reservation floors enforcing PV1-PV4 + general rank-ordered escrow:
  ;;   1. supply-floor: urgent supply (> 1000.0) blocks all non-supply candidates (PV4)
  ;;   2. expansion-floor: 1-base escrow-eligible expansion blocks lower-utility candidates (PV1)
  ;;   3. combat-floor: waiting combat-unit/counter-tech blocks worker / non-blocking candidates (PV2)
  ;;   4. gas-sink-floor: waiting gas-consuming unit/tech blocks mineral-only worker/combat-unit (PV3)
  ;;   5. higher-rank-floor: any ready blocking-allowed? candidate with utility > u(c) + 1.0 and gas-ok?
  ;;      reserves its mineral cost against lower-ranked candidates `c` (including 0-gas escrows!).
  ;;   6. gas-escrow-floor: any ready blocking-allowed? tech-upgrade/counter-tech/production-scaling waiting on gas
  ;;      reserves its gas cost against lower-ranked gas-consuming candidates.
  (define supply-floor 0)
  (define expansion-floor 0)
  (define combat-floor 0)
  (define gas-sink-floor 0)
  (define gas-escrow-floor 0)
  (define seen-tech-counts (make-hasheq))
  (define supply-preempting-needed?
    (and (< supply-cap 200)
         (ormap (lambda (c)
                  (and (eq? (priority-candidate-category c) 'supply)
                       (> (safe-real (priority-candidate-utility-score c) 0.0) 1000.0)))
                sorted-cands)))

  (for ([c (in-list sorted-cands)]
        [rank-idx (in-naturals 1)])
    (define id (priority-candidate-id c))
    (define canon-tech-id
      (case id
        [(lurker-den-mp) 'lurker-den]
        [(templar-archives) 'templar-archive]
        [(robotics-support-bay) 'robotics-bay]
        [else id]))
    (define dup-tech-blocked?
      (or (and (memq id SC2-SINGLETON-TECH-BUILDINGS)
               (>= (hash-ref seen-tech-counts canon-tech-id 0) 1))
          (and (memq id SC2-DUAL-CAP-TECH-BUILDINGS)
               (>= (hash-ref seen-tech-counts canon-tech-id 0) 2))))
    (define cat (priority-candidate-category c))
    (define act (priority-candidate-action c))
    (define m-cost (safe-nonneg-int (priority-candidate-min-cost c) 0))
    (define g-cost (safe-nonneg-int (priority-candidate-gas-cost c) 0))
    (define s-cost (safe-nonneg-int (priority-candidate-supply-cost c) 0))
    (define u-score (safe-real (priority-candidate-utility-score c) 0.0))
    (define blk-ok? (eq? (priority-candidate-blocking-allowed? c) #t))

    (define supply-ok?
      (or (<= s-cost 0)
          (>= rem-sup s-cost)))
    (define gas-ok?
      (>= rem-gas g-cost))
    (define min-ok?
      (>= rem-min m-cost))

    ;; Rank-ordered escrow floor from higher-utility ready candidates (mineral-only & gas-bearing)
    (define supply-scheduled?
      (ormap (lambda (sc) (eq? (priority-candidate-category sc) 'supply))
             scheduled-cands))
    (define supply-preempt-active?
      (and supply-preempting-needed? (not supply-scheduled?)))
    (define higher-rank-min-floor
      (for/fold ([mf 0])
                ([e (in-list escrowed-entries)])
        (match-define (list eu em _eg _eid ecat) e)
        (if (and (> eu (+ u-score 1.0))
                 (not (eq? cat 'supply))
                 ;; Bug 3: supply preemption releases all non-supply escrows
                 (not (and supply-preempt-active? (not (eq? ecat 'supply))))
                 ;; PV1: expansion escrow only applies when escrow-eligible?
                 (or (not (eq? ecat 'expansion)) escrow-eligible?))
            (max mf em)
            mf)))

    ;; Determine effective mineral reservation floor that applies to candidate `c`
    (define applicable-floor
      (if (eq? cat 'supply)
          0
          (max supply-floor
               (if supply-preempt-active? 100 0)
               (if (eq? cat 'expansion) 0 expansion-floor)
               (if (or (eq? cat 'worker) (not blk-ok?)) combat-floor 0)
               (if (and (= g-cost 0) (memq cat '(worker combat-unit))) gas-sink-floor 0)
               higher-rank-min-floor)))

    (define applicable-gas-floor
      (if (or (eq? cat 'supply) (= g-cost 0)) 0 gas-escrow-floor))
    (define floor-ok?
      (and (>= (- rem-min m-cost) applicable-floor)
           (or (= g-cost 0) (>= (- rem-gas g-cost) applicable-gas-floor))))

    (define blocked-by-id
      (and min-ok?
           gas-ok?
           (not floor-ok?)
           (or (and reserved-cand (priority-candidate-id reserved-cand))
               (and (pair? escrowed-entries) (fourth (last escrowed-entries))))))

    (cond
      [dup-tech-blocked?
       (set! decision-entries
             (cons (priority-decision-entry rank-idx id cat act m-cost g-cost s-cost
                                            u-score blk-ok? 'duplicate-singleton-tech
                                            applicable-floor applicable-gas-floor #f)
                   decision-entries))]
      [(and supply-ok? gas-ok? min-ok? floor-ok?)
       (if (ledger-reserve! ledger id cat m-cost g-cost s-cost u-score)
           (begin
             (set! rem-min (- rem-min m-cost))
             (set! rem-gas (- rem-gas g-cost))
             (set! rem-sup (- rem-sup s-cost))
             (when (or (memq id SC2-SINGLETON-TECH-BUILDINGS)
                       (memq id SC2-DUAL-CAP-TECH-BUILDINGS))
               (hash-update! seen-tech-counts canon-tech-id add1 0))
             (set! scheduled-cands (cons c scheduled-cands))
             (set! decision-entries
                   (cons (priority-decision-entry rank-idx id cat act m-cost g-cost s-cost
                                                  u-score blk-ok? 'scheduled
                                                  applicable-floor applicable-gas-floor #f)
                         decision-entries)))
           (set! decision-entries
                 (cons (priority-decision-entry rank-idx id cat act m-cost g-cost s-cost
                                                u-score blk-ok? 'insufficient-resources
                                                applicable-floor applicable-gas-floor #f)
                       decision-entries)))]

      [else
       ;; Candidate was not scheduled; check if it is waiting on minerals or gas and should reserve a floor
       (define escrowed-now? #f)
       (when (and (or (< rem-min m-cost) (< rem-gas g-cost)) supply-ok?)
         (cond
           ;; PV4: Urgent supply reserves 100 minerals before all non-supply candidates
           [(and (eq? cat 'supply) (< supply-cap 200) (< rem-min m-cost) (or (> u-score 1000.0) blk-ok?))
            (set! supply-floor (max supply-floor m-cost))
            (set! escrowed-now? #t)
            (set! escrowed-entries (cons (list u-score m-cost g-cost id cat) escrowed-entries))
            (unless reserved-cand (set! reserved-cand c))]

           ;; PV1: Expansion only reserves minerals when escrow-eligible? AND blocking-allowed?
           [(and (not supply-preempt-active?) (eq? cat 'expansion) (< rem-min m-cost) escrow-eligible? blk-ok?)
            (set! expansion-floor (max expansion-floor m-cost))
            (set! escrowed-now? #t)
            (set! escrowed-entries (cons (list u-score m-cost g-cost id cat) escrowed-entries))
            (unless reserved-cand (set! reserved-cand c))]

           ;; PV2, PV3 & General Rank-Ordered Escrow: Ready blocking combat units, counter-tech,
           ;; tech-upgrade, and production-scaling candidates (including 0-gas escrows!).
           ;; High-bank deadlock guard: when minerals >= 600 and supply-left >= 2, un-actuated
           ;; tech/morph/upgrade/production goals never freeze downstream unit spending.
           ;; Bug 3: Preempt all non-supply escrows whenever supply preemption is active.
           [(and (not supply-preempt-active?)
                 blk-ok?
                 (memq cat '(combat-unit counter-tech tech-upgrade production-scaling))
                 (not (and (memq cat '(tech-upgrade counter-tech production-scaling))
                           (>= init-min 600)
                           (>= rem-sup 2))))
            (when (and (< rem-min m-cost) gas-ok? (memq cat '(combat-unit counter-tech)))
              (set! combat-floor (max combat-floor m-cost))
              (set! escrowed-now? #t)
              (unless reserved-cand (set! reserved-cand c)))
            (when (and (< rem-min m-cost) (or gas-ok? (>= init-gas g-cost)))
              (when (> g-cost 0)
                (set! gas-sink-floor (max gas-sink-floor m-cost)))
              (set! escrowed-now? #t)
              (set! escrowed-entries (cons (list u-score m-cost g-cost id cat) escrowed-entries))
              (unless reserved-cand (set! reserved-cand c)))
            (when (and (> g-cost 0) (< rem-gas g-cost) (memq cat '(tech-upgrade counter-tech production-scaling)))
              (set! gas-escrow-floor (max gas-escrow-floor g-cost))
              (set! escrowed-now? #t)
              (unless (and (pair? escrowed-entries) (eq? (fourth (car escrowed-entries)) id))
                (set! escrowed-entries (cons (list u-score (if (< rem-min m-cost) m-cost 0) g-cost id cat) escrowed-entries)))
              (unless reserved-cand (set! reserved-cand c)))]))

       (define outcome-sym
         (cond
           [escrowed-now? 'escrowed-saving]
           [(not supply-ok?) 'insufficient-supply]
           [(and min-ok? gas-ok? (not floor-ok?)) 'blocked-by-escrow]
           [else 'insufficient-resources]))
       (set! decision-entries
             (cons (priority-decision-entry rank-idx id cat act m-cost g-cost s-cost
                                            u-score blk-ok? outcome-sym
                                            applicable-floor applicable-gas-floor blocked-by-id)
                   decision-entries))]))

  (define final-cands (reverse scheduled-cands))
  (define final-actions (map priority-candidate-action final-cands))
  (define final-trace (reverse decision-entries))
  (define final-escrowed (reverse escrowed-entries))
  (define cat-utils
    (hash-set* cat-utils0
               'decision-trace final-trace
               'escrowed-entries final-escrowed
               'candidate-utilities cand-utils
               'reserved-min-floor (max supply-floor expansion-floor combat-floor gas-sink-floor)
               'reserved-gas-floor gas-escrow-floor))
  (priority-schedule-result final-actions
                            final-cands
                            reserved-cand
                            rem-min
                            rem-gas
                            rem-sup
                            cat-utils))

(define (priority-schedule-decision-trace sched)
  (if (priority-schedule-result? sched)
      (hash-ref (priority-schedule-result-category-utilities sched) 'decision-trace '())
      '()))

(define (normalize-priority-spend-sym s)
  (case s
    [(viking) 'viking-fighter]
    [(templar-archives) 'templar-archive]
    [(robotics-support-bay) 'robotics-bay]
    [(lurker-den-mp) 'lurker-den]
    [(barracks-tech-lab) 'barracks-techlab]
    [(factory-tech-lab) 'factory-techlab]
    [(starport-tech-lab) 'starport-techlab]
    [else s]))

(define (same-priority-spend-sym? a b)
  (and (symbol? a)
       (symbol? b)
       (or (eq? a b)
           (eq? (normalize-priority-spend-sym a)
                (normalize-priority-spend-sym b)))))

;; General query: given the current priority schedule `sched`, can a candidate `id-sym`
;; (of category `cat-sym` and cost `m-cost` / `g-cost`) spend from `(cur-min, cur-gas)`
;; without violating the escrow reserved by strictly higher-priority ready candidates
;; or the active build-order goal?
(define (priority-schedule-can-spend?
         sched
         id-sym
         cur-min
         cur-gas
         #:category [cat-sym 'combat-unit]
         #:min-cost [override-min #f]
         #:gas-cost [override-gas #f]
         #:bo-goal-sym [bo-goal-sym #f]
         #:bo-reserved-min [bo-reserved-min 0]
         #:bo-reserved-gas [bo-reserved-gas 0])
  (define norm-id (normalize-priority-spend-sym id-sym))
  (define m-cost (or override-min (sc2-min-cost norm-id)))
  (define g-cost (or override-gas (sc2-gas-cost norm-id)))
  (cond
    [(or (< cur-min m-cost) (< cur-gas g-cost)) #f]
    [(not (priority-schedule-result? sched)) #t]
    [else
     (define cu (priority-schedule-result-category-utilities sched))
     (define cand-utils (hash-ref cu 'candidate-utilities (hash)))
     (define escrowed (hash-ref cu 'escrowed-entries '()))
     (define u-self
       (hash-ref cand-utils id-sym
                 (hash-ref cand-utils norm-id
                           (hash-ref cu cat-sym
                                     (if (eq? cat-sym 'worker) 65.0 120.0)))))
     (define is-bo-head?
       (and bo-goal-sym (same-priority-spend-sym? norm-id bo-goal-sym)))
     (define high-bank-tech-unlock? (>= cur-min 600))
     (define bo-goal-supply? (memq bo-goal-sym '(overlord pylon supply-depot)))
     (define bo-min-floor
       (if (and (not is-bo-head?)
                (> bo-reserved-min 0)
                (not (eq? cat-sym 'supply))
                (or (not high-bank-tech-unlock?) bo-goal-supply?))
           bo-reserved-min
           0))
     (define bo-gas-floor
       (if (and (not is-bo-head?)
                (> bo-reserved-gas 0)
                (> g-cost 0)
                (not (eq? cat-sym 'supply))
                (or (not high-bank-tech-unlock?) bo-goal-supply?))
           bo-reserved-gas
           0))
     (define higher-escrow-min
      (for/fold ([mf bo-min-floor])
                 ([e (in-list escrowed)])
         (match-define (list eu em _eg eid ecat) e)
         (if (and (not (same-priority-spend-sym? eid norm-id))
                  (not (eq? cat-sym 'supply))
                  (not (and high-bank-tech-unlock?
                            (memq ecat '(tech-upgrade counter-tech production-scaling))))
                  (> eu (+ u-self 1.0)))
             (max mf em)
             mf)))
     (define higher-escrow-gas
       (if (or (= g-cost 0) (eq? cat-sym 'supply))
           0
           (for/fold ([gf bo-gas-floor])
                     ([e (in-list escrowed)])
             (match-define (list eu _em eg eid ecat) e)
             (if (and (not (same-priority-spend-sym? eid norm-id))
                      (> eg 0)
                      (not (and high-bank-tech-unlock?
                                (memq ecat '(tech-upgrade counter-tech production-scaling))))
                      (> eu (+ u-self 1.0)))
                 (max gf eg)
                 gf))))
     (and (>= (- cur-min m-cost) higher-escrow-min)
          (or (= g-cost 0)
              (>= (- cur-gas g-cost) (max bo-gas-floor higher-escrow-gas))))]))

(define (priority-schedule-summary-hash
         sched
         #:frame [frame 0]
         #:race [race 'Zerg]
         #:minerals [minerals 0]
         #:gas [gas 0]
         #:supply-used [supply-used 12]
         #:supply-cap [supply-cap 15]
         #:bo-goal-sym [bo-goal-sym #f]
         #:bo-reserved-min [bo-reserved-min 0]
         #:bo-reserved-gas [bo-reserved-gas 0]
         #:saving-for [saving-for #f])
  (define trace (priority-schedule-decision-trace sched))
  (define res-cand (and (priority-schedule-result? sched)
                        (priority-schedule-result-reserved-candidate sched)))
  (define cu (if (priority-schedule-result? sched)
                 (priority-schedule-result-category-utilities sched)
                 (hash)))
  (define high-bank-unlock?
    (and (>= minerals 600) (>= (- supply-cap supply-used) 2)))
  (define res-min-floor
    (if high-bank-unlock?
        0
        (max bo-reserved-min (hash-ref cu 'reserved-min-floor 0))))
  (define res-gas-floor
    (if high-bank-unlock?
        0
        (max bo-reserved-gas (hash-ref cu 'reserved-gas-floor 0))))
  (define saving-id
    (cond
      [(and (<= res-min-floor 0) (<= res-gas-floor 0)) 'none]
      [(and saving-for (symbol? saving-for)) saving-for]
      [res-cand (priority-candidate-id res-cand)]
      [else (or bo-goal-sym 'none)]))
  (hash 'frame frame
        'race race
        'minerals minerals
        'gas gas
        'supply-used supply-used
        'supply-cap supply-cap
        'bo-goal (or bo-goal-sym 'none)
        'saving-for saving-id
        'reserved-min-floor res-min-floor
        'reserved-gas-floor res-gas-floor
        'scheduled-ids (if (priority-schedule-result? sched)
                           (map priority-candidate-id (priority-schedule-result-scheduled-candidates sched))
                           '())
        'decisions (for/list ([d (in-list trace)])
                     (hash 'rank (priority-decision-entry-rank d)
                           'id (priority-decision-entry-id d)
                           'category (priority-decision-entry-category d)
                           'utility (round1 (priority-decision-entry-utility-score d))
                           'min-cost (priority-decision-entry-min-cost d)
                           'gas-cost (priority-decision-entry-gas-cost d)
                           'blocking? (priority-decision-entry-blocking-allowed? d)
                           'outcome (priority-decision-entry-outcome d)
                           'min-floor (priority-decision-entry-applicable-min-floor d)
                           'blocked-by (or (priority-decision-entry-blocked-by-id d) 'none)))))

(define (format-priority-schedule-log-line
         sched
         #:frame [frame 0]
         #:race [race 'Zerg]
         #:minerals [minerals 0]
         #:gas [gas 0]
         #:supply-used [supply-used 12]
         #:supply-cap [supply-cap 15]
         #:bo-goal-sym [bo-goal-sym #f]
         #:bo-reserved-min [bo-reserved-min 0]
         #:bo-reserved-gas [bo-reserved-gas 0]
         #:saving-for [saving-for #f])
  (define trace (priority-schedule-decision-trace sched))
  (define res-cand (and (priority-schedule-result? sched)
                        (priority-schedule-result-reserved-candidate sched)))
  (define cu (if (priority-schedule-result? sched)
                 (priority-schedule-result-category-utilities sched)
                 (hash)))
  (define high-bank-unlock?
    (and (>= minerals 600) (>= (- supply-cap supply-used) 2)))
  (define res-min-floor
    (if high-bank-unlock?
        0
        (max bo-reserved-min (hash-ref cu 'reserved-min-floor 0))))
  (define res-gas-floor
    (if high-bank-unlock?
        0
        (max bo-reserved-gas (hash-ref cu 'reserved-gas-floor 0))))
  (define saving-id
    (cond
      [(and (<= res-min-floor 0) (<= res-gas-floor 0)) 'none]
      [(and saving-for (symbol? saving-for)) saving-for]
      [res-cand (priority-candidate-id res-cand)]
      [else (or bo-goal-sym 'none)]))
  (define out (open-output-string))
  (display "[SCBOT_PRIORITY] f=" out)
  (display frame out)
  (display " race=" out)
  (display race out)
  (display " bank=" out)
  (display minerals out)
  (display "M/" out)
  (display gas out)
  (display "G sup=" out)
  (display supply-used out)
  (display "/" out)
  (display supply-cap out)
  (display " bo=" out)
  (display (or bo-goal-sym 'none) out)
  (display " saving_for=" out)
  (display saving-id out)
  (display "(floor=" out)
  (display res-min-floor out)
  (display "M/" out)
  (display res-gas-floor out)
  (display "G) sched=(" out)
  (define first-sched? #t)
  (for ([d (in-list trace)]
        #:when (eq? (priority-decision-entry-outcome d) 'scheduled))
    (if first-sched? (set! first-sched? #f) (write-char #\, out))
    (display (priority-decision-entry-id d) out)
    (write-char #\@ out)
    (display (round1 (priority-decision-entry-utility-score d)) out))
  (display ") escrow_queue=(" out)
  (define first-blk? #t)
  (for ([d (in-list trace)]
        #:when (memq (priority-decision-entry-outcome d) '(blocked-by-escrow escrowed-saving)))
    (if first-blk? (set! first-blk? #f) (write-char #\, out))
    (display (priority-decision-entry-id d) out)
    (write-char #\( out)
    (display (priority-decision-entry-outcome d) out)
    (display ",u=" out)
    (display (round1 (priority-decision-entry-utility-score d)) out)
    (display ",floor=" out)
    (display (priority-decision-entry-applicable-min-floor d) out)
    (display "M)" out))
  (write-char #\) out)
  (get-output-string out))

;; =============================================================================
;; 10. Empirical Pro Replay Build-Order Database & Goal-Queue Executor
;;     (Canonical DB, structs, supply curve, and matchup specs imported and
;;      re-exported from `lib/sc2-types.rkt` and `lib/build-orders.rkt`)
;; =============================================================================

(define (evaluate-build-order-next-step
         #:race [raw-race 'Zerg]
         #:enemy-race [enemy-race 'Unknown]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 200]
         #:gas [raw-gas 0]
         #:supply-used [raw-supply-used 12]
         #:supply-left [raw-supply-left 4]
         #:active-bases [raw-active-bases 1]
         #:ready-building-counts [ready-bldg-counts (hash)]
         #:total-building-counts [total-bldg-counts (hash)]
         #:unit-counts [unit-counts (hash)]
         #:researched-upgrades [researched-upgrades '()]
         #:pending-upgrades [pending-upgrades '()]
         #:base-x [raw-base-x 32.5]
         #:base-y [raw-base-y 32.5]
         #:nat-x [raw-nat-x 50.5]
         #:nat-y [raw-nat-y 50.5]
         #:third-x [raw-third-x 60.5]
         #:third-y [raw-third-y 40.5]
         #:early-pool-or-rush? [early-pool-or-rush? #f]
         #:variant [variant #f])
  (define race (normalize-ledger-race raw-race))
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (define frame (safe-nonneg-int raw-frame 0))
  (define elapsed-sec (/ (exact->inexact frame) 22.4))
  (define supply-used (safe-nonneg-int raw-supply-used 12))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define base-x (safe-tile-coord raw-base-x 32.5))
  (define base-y (safe-tile-coord raw-base-y 32.5))
  (define nat-x (safe-tile-coord raw-nat-x 50.5))
  (define nat-y (safe-tile-coord raw-nat-y 50.5))
  (define third-x (safe-tile-coord raw-third-x 60.5))
  (define third-y (safe-tile-coord raw-third-y 40.5))
  (define active-bo-spec
    (select-reactive-build-order-spec
     race enemy-race
     #:early-pool-or-rush? (and early-pool-or-rush? #t)
     #:variant variant))
  (define-values (target-workers target-army)
    (pro-supply-curve-target-for-spec active-bo-spec frame active-bases))

  (define all-upgs
    (append (if (list? researched-upgrades) researched-upgrades '())
            (if (list? pending-upgrades) pending-upgrades '())))

  (define (count-total-bldg sym)
    (sc2-count-equivalent-structures total-bldg-counts sym #f))

  (define (direct-tumor-cnt sym)
    (max (safe-nonneg-int (hash-ref total-bldg-counts sym 0) 0)
         (safe-nonneg-int (hash-ref unit-counts sym 0) 0)))

  (define hatch-count
    (if (eq? race 'Zerg)
        (max active-bases
             (+ (safe-nonneg-int (hash-ref total-bldg-counts 'hatchery 0) 0)
                (safe-nonneg-int (hash-ref total-bldg-counts 'lair 0) 0)
                (safe-nonneg-int (hash-ref total-bldg-counts 'hive 0) 0)))
        active-bases))

  (define active-creep-tumors
    (if (eq? race 'Zerg)
        (+ (direct-tumor-cnt 'creep-tumor)
           (direct-tumor-cnt 'creep-tumor-burrowed)
           (direct-tumor-cnt 'creep-tumor-queen))
        0))

  (define creep-tumor-target
    (if (eq? race 'Zerg)
        (min 6 (* 2 (max 1 hatch-count)))
        0))

  (define queen-count
    (if (eq? race 'Zerg)
        (for/sum ([u-sym (in-list (sc2-unit-equivalent-syms 'queen))])
          (hash-ref unit-counts u-sym 0))
        0))

  (define (prereq-ready? prereq-sym)
    (or (not prereq-sym)
        (> (sc2-count-equivalent-structures ready-bldg-counts prereq-sym #f) 0)))

  (define (goal-satisfied? g)
    (match-define (pro-bo-goal kind sym tgt-cnt _ _ _) g)
    (cond
      [(memq sym '(creep-tumor spawn-creep-tumor))
       (>= active-creep-tumors tgt-cnt)]
      [(eq? sym 'creeping-queen)
       (>= queen-count tgt-cnt)]
      [else
       (case kind
         [(build expand morph)
          (>= (count-total-bldg sym) tgt-cnt)]
         [(train)
          (define unit-cnt
            (for/sum ([u-sym (in-list (sc2-unit-equivalent-syms sym))])
              (hash-ref unit-counts u-sym 0)))
          (>= unit-cnt tgt-cnt)]
         [(research)
          (define upg-syms
            (case sym
              [(metabolic-boost zergling-movementspeed) '(metabolic-boost zergling-movementspeed)]
              [(centrifical-hooks centrifugal-hooks) '(centrifical-hooks centrifugal-hooks)]
              [(warp-gate-research warpgate) '(warp-gate-research warpgate)]
              [(banshee-cloak cloaking-field) '(banshee-cloak cloaking-field)]
              [else (list sym)]))
          (ormap (lambda (u) (not (not (memq u all-upgs)))) upg-syms)]
         [else #t])]))

  (define (goal->action g)
    (match-define (pro-bo-goal kind sym tgt-cnt _ _ _) g)
    (cond
      [(memq sym '(creep-tumor spawn-creep-tumor))
       (list 'spawn-creep-tumor nat-x nat-y)]
      [(eq? sym 'creeping-queen)
       (list 'train 'queen)]
      [else
       (case kind
         [(expand)
          (define ex (if (>= tgt-cnt 3) third-x nat-x))
          (define ey (if (>= tgt-cnt 3) third-y nat-y))
          (list 'expand ex ey)]
         [(morph)
          (list 'morph sym)]
         [(research)
          (list 'research sym)]
         [(train)
          (list 'train sym)]
         [(build)
          (cond
            [(memq sym '(extractor refinery assimilator
                         barracks-techlab barracks-reactor
                         factory-techlab factory-reactor
                         starport-techlab starport-reactor))
             (list 'build sym)]
            [else
             (list 'build sym
                   (safe-tile-coord (+ base-x 4.0))
                   (safe-tile-coord (+ base-y 4.0)))])]
         [else
          (list 'build sym)])]))

  (define (goal-due? g)
    (define min-sup (pro-bo-goal-min-supply g))
    (define tgt-sec (exact->inexact (pro-bo-goal-target-sec g)))
    (or (>= supply-used min-sup)
        (and (> frame 0)
             (> tgt-sec 0.0)
             (>= elapsed-sec tgt-sec))))

  (define zerg-hive-t3-online?
    (and (eq? race 'Zerg)
         (> (sc2-count-equivalent-structures ready-bldg-counts 'hive #f) 0)
         (or (> (sc2-count-equivalent-structures ready-bldg-counts 'ultralisk-cavern #f) 0)
             (> (sc2-count-equivalent-structures ready-bldg-counts 'greater-spire #f) 0))))

  (define (goal-eligible-now? g)
    (define sym (pro-bo-goal-target-sym g))
    (define creep-step? (memq sym '(creep-tumor spawn-creep-tumor)))
    (and (not (goal-satisfied? g))
         (goal-due? g)
         (not (and zerg-hive-t3-online?
                   (or (and (memq sym '(roach-warren baneling-nest))
                            (= (count-total-bldg sym) 0))
                       (memq sym '(burrow))
                       (and (memq sym '(glial-reconstitution tunneling-claws))
                            (= (count-total-bldg 'roach-warren) 0))
                       (and (memq sym '(centrifical-hooks centrifugal-hooks))
                            (= (count-total-bldg 'baneling-nest) 0)))))
         (or (not creep-step?)
             (and (eq? race 'Zerg)
                  (< active-creep-tumors creep-tumor-target)
                  (or (>= queen-count 1) (> active-creep-tumors 0))))
         (not (and (memq sym '(extractor refinery assimilator))
                   (not (gas-building-cap-ok? (count-total-bldg sym) active-bases))))
         (not (and (eq? (pro-bo-goal-kind g) 'train)
                   (not (eq? sym 'creeping-queen))
                   (>= supply-used (+ (pro-bo-goal-min-supply g) 12))))
         (not (and (eq? race 'Protoss)
                   (eq? sym 'assimilator)
                   (>= (pro-bo-goal-target-count g) 2)
                   (or (and (eq? enemy-race 'Random)
                            (< (count-total-bldg 'gateway) 2))
                       (and (not (eq? m-sym 'PvP))
                            (< (count-total-bldg 'nexus) 2)))))))

  (define steps (build-order-spec-steps active-bo-spec))
  (define zerg-creep-steps
    (if (eq? race 'Zerg)
        (append
         (list (pro-bo-goal 'train 'creeping-queen 2 18 'spawning-pool 115.0))
         (if (>= hatch-count 2)
             (list (pro-bo-goal 'train 'creeping-queen 4 28 'spawning-pool 155.0))
             '())
         (if (> creep-tumor-target 0)
             (list (pro-bo-goal 'build 'creep-tumor creep-tumor-target 20 'spawning-pool 125.0))
             '()))
        '()))
  (define extra-timing-goals
    (if (> frame 0)
        (append
         (map pro-upgrade-timing->bo-goal
              (due-pro-upgrade-timings race enemy-race frame supply-used))
         (map pro-unit-timing->bo-goal
              (due-pro-unit-timings race enemy-race frame supply-used)))
        '()))
  (define rem-min (safe-nonneg-int raw-minerals 0))
  (define rem-gas (safe-nonneg-int raw-gas 0))
  (define rem-sup (max 0 (safe-exact-int raw-supply-left 0)))
  (define ready-acts '())
  (define queued-keys (make-hash))
  (define first-ready-head #f)
  (define first-blocked-head #f)
  (define res-min 0)
  (define res-gas 0)

  (define (process-bo-goal! g)
    (define sym (pro-bo-goal-target-sym g))
    (define kind (pro-bo-goal-kind g))
    (define creep-step? (memq sym '(creep-tumor spawn-creep-tumor)))
    (define eff-sym (if (eq? sym 'creeping-queen) 'queen sym))
    (define gkey (cons kind eff-sym))
    (unless (hash-has-key? queued-keys gkey)
      (define m-cost (if creep-step? 0 (sc2-min-cost eff-sym)))
      (define g-cost (if creep-step? 0 (sc2-gas-cost eff-sym)))
      (define s-cost (if (and (not creep-step?) (eq? kind 'train))
                         (sc2-supply-cost eff-sym 0)
                         0))
      (define pre-ok? (prereq-ready? (pro-bo-goal-prereq-ready-sym g)))
      (define non-creep-ready-cnt
        (count (lambda (a) (not (and (pair? a) (eq? (car a) 'spawn-creep-tumor))))
               ready-acts))
      (cond
        [(and (eq? kind 'train) (> s-cost rem-sup))
         ;; Do not reserve or stall BO head on a supply-blocked unit step
         (void)]
        [(and pre-ok?
              (>= (- rem-min res-min) m-cost)
              (>= (- rem-gas res-gas) g-cost)
              (or (<= s-cost 0) (>= rem-sup s-cost))
              ;; Only emit at most 2 build/research/expand actions per frame from BO queue
              ;; (0-cost creep tumor directives do not consume mineral/tech BO action slots)
              (or creep-step? (< non-creep-ready-cnt 2)))
         (set! rem-min (- rem-min m-cost))
         (set! rem-gas (- rem-gas g-cost))
         (set! rem-sup (- rem-sup s-cost))
         (hash-set! queued-keys gkey #t)
         (set! ready-acts (cons (goal->action g) ready-acts))
         (unless (or creep-step? first-ready-head) (set! first-ready-head g))]
        [pre-ok?
         ;; Prerequisite is ready, but waiting on resources -> reserve minerals/gas for first waiting ready step
         (unless (or creep-step? first-ready-head)
           (set! first-ready-head g)
           (when (memq kind '(build expand morph research train))
             (set! res-min m-cost)
             (set! res-gas g-cost)))]
        [else
         ;; Prerequisite building is still under construction -> do NOT emit or block worker production;
         ;; only record fallback head if no prerequisite-ready step exists.
         (unless (or creep-step? first-blocked-head)
           (set! first-blocked-head g))])))

  (for ([g (in-list steps)]
        #:when (goal-eligible-now? g))
    (process-bo-goal! g))

  (for ([g (in-list extra-timing-goals)]
        #:when (and (not (goal-satisfied? g))
                    (not (and (eq? (pro-bo-goal-kind g) 'train)
                              (>= supply-used (+ (pro-bo-goal-min-supply g) 12))))))
    (process-bo-goal! g))

  (for ([g (in-list zerg-creep-steps)]
        #:when (goal-eligible-now? g))
    (process-bo-goal! g))

  (define raw-active-head (or first-ready-head first-blocked-head))
  ;; Resolve 'train goals whose structure prerequisite has 0 total buildings (e.g. immortal -> robotics-facility)
  ;; so saving_for / bo-goal-sym points to the missing prerequisite and escrows its resources.
  (define active-head
    (if (and (pro-bo-goal? raw-active-head)
             (eq? (pro-bo-goal-kind raw-active-head) 'train)
             (pro-bo-goal-prereq-ready-sym raw-active-head)
             (= (count-total-bldg (pro-bo-goal-prereq-ready-sym raw-active-head)) 0))
        (let* ([prereq-sym (pro-bo-goal-prereq-ready-sym raw-active-head)]
               [prereq-step (findf (lambda (s)
                                     (and (memq (pro-bo-goal-kind s) '(build expand morph))
                                          (eq? (pro-bo-goal-target-sym s) prereq-sym)))
                                   steps)])
          (or prereq-step
              (pro-bo-goal 'build prereq-sym 1
                           (pro-bo-goal-min-supply raw-active-head)
                           #f
                           (pro-bo-goal-target-sec raw-active-head))))
        raw-active-head))
  (when (and (not (eq? active-head raw-active-head))
             (pro-bo-goal? active-head)
             (= res-min 0)
             (= res-gas 0)
             (prereq-ready? (pro-bo-goal-prereq-ready-sym active-head)))
    (set! res-min (sc2-min-cost (pro-bo-goal-target-sym active-head)))
    (set! res-gas (sc2-gas-cost (pro-bo-goal-target-sym active-head))))
  (define release-bo-tech-reserve?
    (and (>= (safe-nonneg-int raw-minerals 0) 600)
         (>= (max 0 (safe-exact-int raw-supply-left 0)) 2)
         (pro-bo-goal? active-head)
         (or (memq (pro-bo-goal-kind active-head) '(morph research))
             (and (eq? (pro-bo-goal-kind active-head) 'build)
                  (not (memq (pro-bo-goal-target-sym active-head)
                             '(overlord pylon supply-depot hatchery command-center nexus)))))))
  (pro-bo-eval-result m-sym
                      active-head
                      (reverse ready-acts)
                      (if release-bo-tech-reserve? 0 (safe-nonneg-int res-min 0))
                      (if release-bo-tech-reserve? 0 (safe-nonneg-int res-gas 0))
                      (safe-nonneg-int target-workers 22)
                      target-army))

;; =============================================================================
;; 11. Decoupled 8-Stream Resource & Bank Manager + 200/200 Max-Supply Manager
;; =============================================================================

(define DEC-GOAL-STREAMS
  '(workers
    supply
    expansion
    tech
    upgrades
    production-facilities
    static-defense
    army))

(struct race-bank-target
  (race
   target-minerals
   target-gas
   surge-kind
   trigger-reason
   active?)
  #:transparent)

(struct stream-budget-slice
  (stream
   weight-min
   weight-gas
   allocated-minerals
   allocated-gas
   reserved-minerals
   reserved-gas
   active-goal-sym
   blocked-by-prereq?)
  #:transparent)

(struct decoupled-bank-allocation
  (race
   frame
   total-minerals
   total-gas
   bank-target
   slices-by-stream
   hard-reserved-minerals
   hard-reserved-gas
   spendable-by-stream)
  #:transparent)

(struct max-supply-plan
  (active?
   overcap-target-supply
   fist-of-neeb-actions
   spore-trick-actions
   cheap-unit-sack-actions
   combined-actions
   reason)
  #:transparent)

(define (compute-bank-targets
         #:race [raw-race 'Zerg]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 0]
         #:gas [raw-gas 0]
         #:supply-used [raw-supply-used 12]
         #:supply-cap [raw-supply-cap 15]
         #:workers [raw-workers 12]
         #:active-bases [raw-bases 1]
         #:larva-count [raw-larva 3]
         #:warpgate-count [raw-warpgates 0]
         #:production-facility-count [raw-prod-facs 1]
         #:ready-buildings [raw-ready-bldgs '()]
         #:in-progress-buildings [raw-pending-bldgs '()]
         #:open-production-slots [raw-open-slots #f]
         #:in-progress-max-progress [raw-tech-progress #f]
         #:under-attack? [under-attack? #f])
  (define race (normalize-ledger-race raw-race))
  (define supply-used (safe-nonneg-int raw-supply-used 12))
  (define workers (safe-nonneg-int raw-workers 12))
  (define bases (max 1 (safe-nonneg-int raw-bases 1)))
  (define larva-cnt (safe-nonneg-int raw-larva 0))
  (define wg-cnt (safe-nonneg-int raw-warpgates 0))
  (define prod-cnt (safe-nonneg-int raw-prod-facs 1))
  (define ready-syms (if (list? raw-ready-bldgs) (filter symbol? raw-ready-bldgs) '()))
  (define pending-syms (if (list? raw-pending-bldgs) (filter symbol? raw-pending-bldgs) '()))
  (define has-open-prod-slots?
    (and (exact-integer? raw-open-slots) (> raw-open-slots 0)))
  (define tech-progress-scale
    (if (and (real? raw-tech-progress)
             (not (nan? raw-tech-progress))
             (not (infinite? raw-tech-progress))
             (< raw-tech-progress 0.55))
        (max 0.25 (exact->inexact raw-tech-progress))
        1.0))
  (define (scale-tech-surge v)
    (if (< tech-progress-scale 1.0)
        (exact-round (* v tech-progress-scale))
        v))

  (cond
    ;; Never hold macro bank when fighting a survival crisis below late-game max-out
    [(and under-attack? (< supply-used 185))
     (race-bank-target race 0 0 'emergency-spend-all 'under-attack-crisis #f)]
    [(< workers 12)
     (race-bank-target race 0 0 'worker-recovery 'critical-worker-deficit #f)]

    ;; Zerg: Larva-surge & Spire / Hive tech-switch morph banking
    [(eq? race 'Zerg)
     (cond
       [(or (memq 'spire pending-syms)
            (memq 'greater-spire pending-syms)
            (and (or (memq 'spire ready-syms) (memq 'greater-spire ready-syms))
                 (>= larva-cnt 5)))
        (define eff-l (max 4 (min 8 (if (> larva-cnt 0) larva-cnt 6))))
        (define spire-ready? (or (memq 'spire ready-syms) (memq 'greater-spire ready-syms)))
        (define raw-m (* eff-l 100))
        (define raw-g (* eff-l 100))
        (race-bank-target race
                          (if spire-ready? raw-m (scale-tech-surge raw-m))
                          (if spire-ready? raw-g (scale-tech-surge raw-g))
                          'zerg-muta-corruptor-larva-surge
                          'spire-morph-wave
                          #t)]
       [(or (memq 'ultralisk-cavern pending-syms)
            (memq 'lurker-den pending-syms)
            (memq 'lurker-den-mp pending-syms)
            (and (or (memq 'ultralisk-cavern ready-syms)
                     (memq 'lurker-den ready-syms)
                     (memq 'lurker-den-mp ready-syms))
                 (>= larva-cnt 4)
                 (>= supply-used 100)))
        (define eff-l (max 3 (min 6 (if (> larva-cnt 0) larva-cnt 4))))
        (define hive-tech-ready?
          (or (memq 'ultralisk-cavern ready-syms)
              (memq 'lurker-den ready-syms)
              (memq 'lurker-den-mp ready-syms)))
        (define raw-m (* eff-l 150))
        (define raw-g (* eff-l 100))
        (race-bank-target race
                          (if hive-tech-ready? raw-m (scale-tech-surge raw-m))
                          (if hive-tech-ready? raw-g (scale-tech-surge raw-g))
                          'zerg-hive-splash-larva-surge
                          'hive-tech-switch-wave
                          #t)]
       [(and (>= larva-cnt 6) (>= bases 2) (>= supply-used 40))
        (define eff-l (min 12 larva-cnt))
        (race-bank-target race (* eff-l 75) (* eff-l 25)
                          'zerg-inject-larva-surge
                          'pooled-inject-larva-batch
                          #t)]
       [else
        (race-bank-target race 0 0 'none 'steady-macro-spend #f)])]

    ;; Terran: Production-wave cycle sync & capital transition banking
    [(eq? race 'Terran)
     (cond
       [(or (memq 'fusion-core pending-syms)
            (and (memq 'fusion-core ready-syms)
                 (>= supply-used 110)
                 (or (not has-open-prod-slots?) (>= supply-used 160))))
        (define fc-ready? (not (not (memq 'fusion-core ready-syms))))
        (race-bank-target race
                          (if fc-ready? 400 (scale-tech-surge 400))
                          (if fc-ready? 300 (scale-tech-surge 300))
                          'terran-capital-wave-sync
                          'battlecruiser-liberator-wave
                          #t)]
       [(and (>= prod-cnt 3)
             (>= supply-used 48)
             (or (not has-open-prod-slots?) (>= supply-used 160)))
        (define eff-p (min 8 prod-cnt))
        (race-bank-target race (* eff-p 100) (* eff-p 50)
                          'terran-production-wave-sync
                          'multi-facility-cycle-sync
                          #t)]
       [else
        (race-bank-target race 0 0 'none 'steady-macro-spend #f)])]

    ;; Protoss: Warp-Gate cooldown batching & Robotics/Fleet capital surge banking
    [else
     (define capital-in-progress?
       (or (memq 'fleet-beacon pending-syms)
           (memq 'robotics-bay pending-syms)
           (memq 'robotics-support-bay pending-syms)
           (memq 'templar-archive pending-syms)
           (memq 'templar-archives pending-syms)))
     (define capital-ready?
       (or (memq 'fleet-beacon ready-syms)
           (memq 'robotics-bay ready-syms)
           (memq 'robotics-support-bay ready-syms)
           (memq 'templar-archive ready-syms)
           (memq 'templar-archives ready-syms)))
     (cond
       [(or capital-in-progress?
            (and capital-ready?
                 (>= supply-used 100)
                 (not has-open-prod-slots?)))
        (define eff-wg (max 3 (min 8 wg-cnt)))
        (define raw-m (+ 200 (* eff-wg 100)))
        (define raw-g 300)
        (race-bank-target race
                          (if capital-ready? raw-m (scale-tech-surge raw-m))
                          (if capital-ready? raw-g (scale-tech-surge raw-g))
                          'protoss-capital-warpgate-batch
                          'capital-splash-and-warpin-batch
                          #t)]
       [(and (>= wg-cnt 3)
             (>= supply-used 38)
             (not has-open-prod-slots?))
        (define eff-wg (min 10 wg-cnt))
        (race-bank-target race (* eff-wg 100) (* eff-wg 50)
                          'protoss-warpgate-cycle-batch
                          'warpgate-cooldown-batch
                          #t)]
       [else
        (race-bank-target race 0 0 'none 'steady-macro-spend #f)])]))

(define (allocate-decoupled-goal-streams
         #:race [raw-race 'Zerg]
         #:frame [raw-frame 0]
         #:minerals [raw-minerals 0]
         #:gas [raw-gas 0]
         #:supply-used [raw-supply-used 12]
         #:supply-cap [raw-supply-cap 15]
         #:pending-supply [raw-pending-sup 0]
         #:workers [raw-workers 12]
         #:active-bases [raw-bases 1]
         #:gas-harvesters [raw-gas-harv 3]
         #:under-attack? [under-attack? #f]
         #:wants-expand? [wants-expand? #f]
         #:tech-goal-sym [tech-goal-sym #f]
         #:tech-prereq-ready? [tech-prereq-ready? #t]
         #:upgrade-goal-sym [upgrade-goal-sym #f]
         #:upgrade-prereq-ready? [upgrade-prereq-ready? #t]
         #:open-production-slots [raw-open-slots #f]
         #:larva-count [raw-larva-cnt 0]
         #:warpgate-count [raw-wg-cnt 0]
         #:production-facility-count [raw-prod-cnt 0]
         #:ready-buildings [raw-ready-bldgs '()]
         #:in-progress-buildings [raw-in-prog-bldgs '()]
         #:in-progress-max-progress [raw-tech-progress #f]
         #:bank-target [explicit-bank-target #f])
  (define race (normalize-ledger-race raw-race))
  (define frame (safe-nonneg-int raw-frame 0))
  (define minerals (safe-nonneg-int raw-minerals 0))
  (define gas (safe-nonneg-int raw-gas 0))
  (define supply-used (safe-nonneg-int raw-supply-used 12))
  (define supply-cap (max 1 (safe-nonneg-int raw-supply-cap 15)))
  (define supply-left (- supply-cap supply-used))
  (define pending-sup (safe-nonneg-int raw-pending-sup 0))
  (define workers (safe-nonneg-int raw-workers 12))
  (define bases (max 1 (safe-nonneg-int raw-bases 1)))
  (define gas-harv (safe-nonneg-int raw-gas-harv 0))

  (define btarget
    (if (race-bank-target? explicit-bank-target)
        explicit-bank-target
        (compute-bank-targets
         #:race race
         #:frame frame
         #:minerals minerals
         #:gas gas
         #:supply-used supply-used
         #:supply-cap supply-cap
         #:workers workers
         #:active-bases bases
         #:larva-count raw-larva-cnt
         #:warpgate-count raw-wg-cnt
         #:production-facility-count raw-prod-cnt
         #:ready-buildings raw-ready-bldgs
         #:in-progress-buildings raw-in-prog-bldgs
         #:open-production-slots raw-open-slots
         #:in-progress-max-progress raw-tech-progress
         #:under-attack? under-attack?)))

  (define ideal-workers (min 80 (* 22 bases)))
  (define need-workers? (< workers ideal-workers))
  (define need-supply? (and (< supply-cap 200) (<= (+ supply-left pending-sup) 4)))
  (define critical-supply? (and (< supply-cap 200) (<= supply-left 2) (= pending-sup 0)))
  (define need-static-def? (or under-attack? (>= supply-used 190)))

  ;; Decoupled Non-Blocking Prerequisite & Gas-Feasibility Gate:
  ;; If a tech or upgrade goal has unready prerequisites OR requires gas we do not have
  ;; while 0 gas harvesters are active, mark it blocked so it reserves 0 minerals!
  (define tech-min-cost (if (symbol? tech-goal-sym) (sc2-min-cost tech-goal-sym) 0))
  (define tech-gas-cost (if (symbol? tech-goal-sym) (sc2-gas-cost tech-goal-sym) 0))
  (define tech-blocked?
    (and (symbol? tech-goal-sym)
        (or (not tech-prereq-ready?)
            (and (> tech-gas-cost gas) (= gas-harv 0)))))

  (define upg-min-cost (if (symbol? upgrade-goal-sym) (sc2-min-cost upgrade-goal-sym) 0))
  (define upg-gas-cost (if (symbol? upgrade-goal-sym) (sc2-gas-cost upgrade-goal-sym) 0))
  (define upg-blocked?
    (and (symbol? upgrade-goal-sym)
        (or (not upgrade-prereq-ready?)
            (and (> upg-gas-cost gas) (= gas-harv 0)))))

  ;; Raw priority weights across all 8 streams (`DEC-GOAL-STREAMS`)
  (define raw-min-weights
    (hasheq 'workers               (cond [(< workers 12) 0.45] [need-workers? 0.22] [else 0.03])
            'supply                (cond [critical-supply? 0.35] [need-supply? 0.16] [else 0.04])
            'expansion             (cond [(and wants-expand? (not under-attack?)) 0.28] [else 0.08])
            'tech                  (cond [tech-blocked? 0.02] [(symbol? tech-goal-sym) 0.14] [else 0.08])
            'upgrades              (cond [upg-blocked? 0.02] [(symbol? upgrade-goal-sym) 0.10] [else 0.07])
            'production-facilities (cond [(>= minerals 450) 0.18] [else 0.10])
            'static-defense        (cond [under-attack? 0.20] [(>= supply-used 190) 0.24] [else 0.04])
            'army                  (cond [under-attack? 0.42] [else 0.28])))

  (define raw-gas-weights
    (hasheq 'workers               0.00
            'supply                0.00
            'expansion             0.00
            'tech                  (cond [tech-blocked? 0.02] [(symbol? tech-goal-sym) 0.32] [else 0.22])
            'upgrades              (cond [upg-blocked? 0.02] [(symbol? upgrade-goal-sym) 0.28] [else 0.20])
            'production-facilities 0.08
            'static-defense        0.02
            'army                  (if under-attack? 0.65 0.48)))

  (define sum-mw (max 0.001 (for/sum ([s (in-list DEC-GOAL-STREAMS)]) (hash-ref raw-min-weights s 0.0))))
  (define sum-gw (max 0.001 (for/sum ([s (in-list DEC-GOAL-STREAMS)]) (hash-ref raw-gas-weights s 0.0))))

  ;; Hard crisis/macro mineral & gas reserves (strictly decoupled!)
  (define res-supply-min (if critical-supply? 100 0))
  (define res-worker-min (if (and need-workers? (not under-attack?)) 50 0))
  (define exp-cost (case race [(Zerg) 300] [else 400]))
  (define res-expand-min (if (and wants-expand? (not under-attack?) (not critical-supply?)) exp-cost 0))
  (define res-def-min (if (and under-attack? (< supply-used 60)) 100 0))
  (define high-bank-tech-bypass? (and (>= minerals 600) (>= supply-left 2)))
  (define res-tech-min
    (if (and (symbol? tech-goal-sym)
             (not tech-blocked?)
             (not under-attack?)
             (not high-bank-tech-bypass?))
        (min 200 tech-min-cost)
        0))
  (define res-tech-gas
    (if (and (symbol? tech-goal-sym)
             (not tech-blocked?)
             (not under-attack?)
             (not high-bank-tech-bypass?))
        tech-gas-cost
        0))
  (define res-upg-gas
    (if (and (symbol? upgrade-goal-sym)
             (not upg-blocked?)
             (not under-attack?)
             (not high-bank-tech-bypass?))
        upg-gas-cost
        0))

  ;; Survival-only mineral floor (`supply`, `workers`, `expansion`, `static-defense`).
  ;; Non-survival streams (`tech`, `upgrades`, `army`, `production-facilities`) NEVER subtract
  ;; `res-tech-min` from `hard-res-min`!
  (define hard-res-min (+ res-supply-min res-worker-min res-expand-min res-def-min))
  (define hard-res-gas (+ res-tech-gas res-upg-gas))

  (define tech-cross-ready?
    (and (symbol? tech-goal-sym)
         (not tech-blocked?)
         (not under-attack?)
         (or (= tech-gas-cost 0)
             (>= gas (- tech-gas-cost (* 12 gas-harv))))))
  (define soft-tech-res-min
    (if tech-cross-ready? (min 200 tech-min-cost) 0))
  (define army-tech-res-min
    (if (and tech-cross-ready?
             (or (= tech-gas-cost 0)
                 (>= gas (- tech-gas-cost 30))))
        soft-tech-res-min
        0))

  (define slices-ht
    (for/hasheq ([s (in-list DEC-GOAL-STREAMS)])
      (define wm (/ (hash-ref raw-min-weights s 0.0) sum-mw))
      (define wg (/ (hash-ref raw-gas-weights s 0.0) sum-gw))
      (define alloc-m (exact-round (* wm minerals)))
      (define alloc-g (exact-round (* wg gas)))
      (define r-m
        (case s
          [(supply) res-supply-min]
          [(workers) res-worker-min]
          [(expansion) res-expand-min]
          [(static-defense) res-def-min]
          [(tech) res-tech-min]
          [else 0]))
      (define r-g
        (case s
          [(tech) res-tech-gas]
          [(upgrades) res-upg-gas]
          [else 0]))
      (define g-sym
        (case s
          [(workers) (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe])]
          [(supply) (case race [(Zerg) 'overlord] [(Terran) 'supply-depot] [else 'pylon])]
          [(expansion) (case race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus])]
          [(tech) tech-goal-sym]
          [(upgrades) upgrade-goal-sym]
          [else #f]))
      (define blk?
        (case s
          [(tech) tech-blocked?]
          [(upgrades) upg-blocked?]
          [else #f]))
      (values s (stream-budget-slice s wm wg alloc-m alloc-g r-m r-g g-sym blk?))))

  (define spendable-ht
    (for/hasheq ([s (in-list DEC-GOAL-STREAMS)])
      ;; Survival streams (`supply`, `workers`, `static-defense`, `expansion`) spend against upstream survival floors;
      ;; downstream streams (`tech`, `army`, `production-facilities`, `upgrades`) always respect `hard-res-min`,
      ;; and lower-priority `production-facilities`/`upgrades` also respect `soft-tech-res-min` when tech is cross-resource ready.
      (define other-hard-min
        (case s
          [(supply) 0]
          [(workers) res-supply-min]
          [(static-defense) res-supply-min]
          [(expansion) (+ res-supply-min res-def-min)]
          [(tech) hard-res-min]
          [(army) (+ hard-res-min army-tech-res-min)]
          [(production-facilities upgrades) (+ hard-res-min soft-tech-res-min)]
          [else hard-res-min]))
      (define other-hard-gas
        (case s
          [(tech) 0]
          [(upgrades) res-tech-gas]
          [(army)
           (cond
             [under-attack? 0]
             [(< gas (+ res-tech-gas res-upg-gas)) (max res-tech-gas res-upg-gas)]
             [else (+ res-tech-gas res-upg-gas)])]
          [else hard-res-gas]))
      (values s (cons (max 0 (- minerals other-hard-min))
                      (max 0 (- gas other-hard-gas))))))

  (decoupled-bank-allocation
   race
   frame
   minerals
   gas
   btarget
   slices-ht
   hard-res-min
   hard-res-gas
   spendable-ht))

(define (decoupled-stream-can-spend? alloc stream-sym min-cost [gas-cost 0])
  (cond
    [(not (decoupled-bank-allocation? alloc)) #f]
    [else
     (define sl (hash-ref (decoupled-bank-allocation-slices-by-stream alloc) stream-sym #f))
     (define sp (hash-ref (decoupled-bank-allocation-spendable-by-stream alloc) stream-sym '(0 . 0)))
     (and sl
          (not (stream-budget-slice-blocked-by-prereq? sl))
          (>= (car sp) (safe-nonneg-int min-cost 0))
          (>= (cdr sp) (safe-nonneg-int gas-cost 0)))]))

(define extract-record-sym unit-type-sym)

(define (evaluate-max-supply-manager
         #:race [raw-race 'Zerg]
         #:minerals [raw-minerals 0]
         #:gas [raw-gas 0]
         #:supply-used [raw-supply-used 0]
         #:supply-cap [raw-supply-cap 200]
         #:workers [raw-workers 0]
         #:active-bases [raw-bases 1]
         #:ally-units [raw-ally-units '()]
         #:ally-buildings [raw-ally-bldgs '()]
         #:base-x [raw-base-x 32.5]
         #:base-y [raw-base-y 32.5]
         #:nat-x [raw-nat-x 50.5]
         #:nat-y [raw-nat-y 50.5]
         #:third-x [raw-third-x 68.5]
         #:third-y [raw-third-y 50.5]
         #:enemy-x [raw-enemy-x 160.5]
         #:enemy-y [raw-enemy-y 160.5])
  (define race (normalize-ledger-race raw-race))
  (define minerals (safe-nonneg-int raw-minerals 0))
  (define gas (safe-nonneg-int raw-gas 0))
  (define supply-used (safe-nonneg-int raw-supply-used 0))
  (define supply-cap (max 1 (safe-nonneg-int raw-supply-cap 200)))
  (define workers (safe-nonneg-int raw-workers 0))
  (define ally-units (if (list? raw-ally-units) raw-ally-units '()))
  (define ally-bldgs (if (list? raw-ally-bldgs) raw-ally-bldgs '()))
  (define base-x (safe-tile-coord raw-base-x 32.5))
  (define base-y (safe-tile-coord raw-base-y 32.5))
  (define third-x (safe-tile-coord raw-third-x 68.5))
  (define third-y (safe-tile-coord raw-third-y 50.5))
  (define enemy-x (safe-tile-coord raw-enemy-x 160.5))
  (define enemy-y (safe-tile-coord raw-enemy-y 160.5))

  (define active-bases (max 1 (safe-nonneg-int raw-bases 1)))
  (define static-def-cap (min 12 (* 2 active-bases)))
  (define existing-static-def-count
    (count (lambda (b)
             (memq (extract-record-sym b)
                   '(photon-cannon shield-battery missile-turret bunker spine-crawler spore-crawler)))
           ally-bldgs))

  (define has-pending-spore-overcap?
    (and (eq? race 'Zerg)
         (>= supply-used 198)
         (>= supply-cap 198)
         (ormap (lambda (b)
                  (and (hash? b)
                       (eq? (extract-record-sym b) 'spore-crawler)
                       (let ([bp (hash-ref b 'build-progress 1.0)]
                             [bid (hash-ref b 'id 0)])
                         (and (real? bp) (< bp 0.95) (exact-integer? bid) (> bid 0)))))
                ally-bldgs)))

  (define maxed-window?
    (or has-pending-spore-overcap?
        (and (>= supply-cap 198)
             (>= supply-used 194)
             (or (>= minerals 350) (>= gas 300)))))

  (cond
    [(not maxed-window?)
     (max-supply-plan #f supply-cap '() '() '() '() 'below-max-supply-threshold)]
    [else
     (define ready-bldg-syms
       (for/list ([b (in-list ally-bldgs)]
                  #:when (or (symbol? b)
                             (and (hash? b)
                                  (let ([bp (hash-ref b 'build-progress 1.0)]
                                        [bsym (extract-record-sym b)])
                                    (and (or (not (real? bp)) (>= bp 0.99))
                                         (or (not (sc2-structure-requires-pylon-power? bsym))
                                             (not (eq? (hash-ref b 'powered? #t) #f))))))))
         (extract-record-sym b)))
     (define has-bldg-info? (not (null? ally-bldgs)))
     (define (bldg-ready-or-assumed? sym)
       (or (not has-bldg-info?)
           (not (not (memq sym ready-bldg-syms)))))

     ;; Check for Phase B Spore overcap cancellations up front so `neeb-acts` never
     ;; rebuilds a Spore Crawler on the same frame that `spore-acts` cancels Spores.
     (define pending-spores
       (filter (lambda (b)
                 (and (hash? b)
                      (eq? (extract-record-sym b) 'spore-crawler)
                      (let ([bp (hash-ref b 'build-progress 1.0)]
                            [bid (hash-ref b 'id 0)])
                        (and (real? bp) (< bp 0.95) (exact-integer? bid) (> bid 0)))))
               ally-bldgs))
     (define cancelling-pending-spores?
       (and (eq? race 'Zerg) (>= supply-used 198) (not (null? pending-spores))))

     ;; 1. Fist of Neeb: Convert surplus late-game mineral bank (>= 600M at >= 194/200)
     ;;    into 0-supply forward static defense batteries / Planetary Fortresses,
     ;;    strictly capped at `<= (min 12 (* 2 active-bases))` total static defense!
     (define def-x third-x)
     (define def-y third-y)
     (define def-x2 (safe-tile-coord (min 248.0 (+ def-x 2.0)) def-x))
     (define under-static-def-cap? (< existing-static-def-count static-def-cap))
     (define neeb-acts
       (cond
         [(< minerals 600) '()]
         [(eq? race 'Protoss)
          (if (not under-static-def-cap?)
              '()
              (let ([p1 (if (bldg-ready-or-assumed? 'forge)
                            (list (list 'build 'photon-cannon def-x def-y))
                            (list (list 'build 'pylon def-x def-y)))]
                    [p2 (if (and (>= minerals 750)
                                 (< (add1 existing-static-def-count) static-def-cap)
                                 (bldg-ready-or-assumed? 'cybernetics-core))
                            (list (list 'build 'shield-battery def-x2 def-y))
                            '())])
                (append p1 p2)))]
         [(eq? race 'Terran)
          (define t1
            (if (and under-static-def-cap? (bldg-ready-or-assumed? 'engineering-bay))
                (list (list 'build 'missile-turret def-x def-y))
                '()))
          (define t2
            (cond
              [(and (>= minerals 900)
                    (bldg-ready-or-assumed? 'engineering-bay)
                    (memq 'command-center ready-bldg-syms))
               (list '(morph planetary-fortress))]
              [(and (>= minerals 750)
                    (< (+ existing-static-def-count (length t1)) static-def-cap)
                    (bldg-ready-or-assumed? 'barracks))
               (list (list 'build 'bunker def-x2 def-y))]
              [else '()]))
          (append t1 t2)]
         [else ;; Zerg
          (if (and under-static-def-cap? (bldg-ready-or-assumed? 'spawning-pool))
              (append (list (list 'build 'spine-crawler def-x def-y))
                      (if (or cancelling-pending-spores?
                              (>= (add1 existing-static-def-count) static-def-cap))
                          '()
                          (list (list 'build 'spore-crawler def-x2 def-y))))
              '())]))

     ;; 2. Zerg Spore Crawler Trick (`204/200` Supply Overcap):
     ;;    - If temporary in-progress `spore-crawler`s exist while `supply-used >= 198`,
     ;;      cancel them (`cancel-building`) to pop units above the 200/200 cap (`202..204/200`)!
     ;;    - Otherwise at `198..200 / 200` with `minerals >= 350` and Pool ready, morph temporary
     ;;      Spores to dip to `196..198/200` and queue high-tier units into the freed supply!
     (define zerg-overcap-unit
       (cond
         [(and (bldg-ready-or-assumed? 'ultralisk-cavern) (>= gas 200)) 'ultralisk]
         [(and (or (bldg-ready-or-assumed? 'spire) (bldg-ready-or-assumed? 'greater-spire)) (>= gas 150)) 'corruptor]
         [(bldg-ready-or-assumed? 'roach-warren) 'roach]
         [else 'drone]))
     (define spore-acts
       (cond
         [(not (eq? race 'Zerg)) '()]
         [cancelling-pending-spores?
          (for/list ([sp (in-list (take pending-spores (min 4 (length pending-spores))))])
            (list 'cancel-building (hash-ref sp 'id)))]
         [(and (>= supply-used 198)
               (>= supply-cap 200)
               (>= minerals 350)
               (< existing-static-def-count (+ static-def-cap 2))
               (bldg-ready-or-assumed? 'spawning-pool))
          (define sx1 (safe-tile-coord (min 248.0 (+ base-x 2.0)) base-x))
          (define sy1 (safe-tile-coord (min 248.0 (+ base-y 2.0)) base-y))
          (define sx2 (safe-tile-coord (min 248.0 (+ base-x 4.0)) base-x))
          (list (list 'build 'spore-crawler sx1 sy1)
                (list 'build 'spore-crawler sx2 sy1)
                (list 'train zerg-overcap-unit))]
         [else '()]))

     (define overcap-target
       (if (and (eq? race 'Zerg) (not (null? spore-acts)))
           204
           supply-cap))

     ;; 3. Cheap-Unit Sack / Supply Trading:
     ;;    At >= 196/200 supply with high bank (>= 700M & >= 350G), send up to 4 low-tier
     ;;    supply-inefficient combat units (or surplus workers > 68) on an immediate runby
     ;;    trade (`attack-pos`) so freed supply refills with high-tier capital/splash units!
     (define cheap-tier-syms
       (case race
         [(Zerg)    '(zergling roach)]
         [(Terran)  '(marine hellion reaper)]
         [else      '(zealot adept)]))
     (define worker-sym
       (case race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
     (define sack-candidates
       (if (and (>= supply-used 196) (>= minerals 700) (>= gas 350))
           (let ([low-combat
                  (filter (lambda (u)
                            (and (hash? u)
                                 (memq (extract-record-sym u) cheap-tier-syms)
                                 (let ([uid (hash-ref u 'id 0)])
                                   (and (exact-integer? uid) (> uid 0)))))
                          ally-units)]
                 [surplus-workers
                  (if (> workers 68)
                      (filter (lambda (u)
                                (and (hash? u)
                                     (eq? (extract-record-sym u) worker-sym)
                                     (not (eq? (hash-ref u 'has-build-order? #f) #t))
                                     (let ([uid (hash-ref u 'id 0)])
                                       (and (exact-integer? uid) (> uid 0)))))
                              ally-units)
                      '())])
             (append low-combat surplus-workers))
           '()))
     (define sack-acts
       (for/list ([u (in-list (take sack-candidates (min 4 (length sack-candidates))))])
         (list 'attack-pos (hash-ref u 'id) enemy-x enemy-y)))

     (define combined
       (append spore-acts neeb-acts sack-acts))
     (define active-now? (not (null? combined)))
     (max-supply-plan
      active-now?
      overcap-target
      neeb-acts
      spore-acts
      sack-acts
      combined
      (if active-now? 'max-supply-conversion-active 'max-supply-idle))]))


;; =============================================================================
;; 11B. Build-Order Deviation, 4-Pillar Post-BO Goals & Tactical Side-Tables
;; =============================================================================

(define *macro-world-state-extractor* #f)

(define (register-macro-world-state-extractor! fn)
  (set! *macro-world-state-extractor* fn)
  (void))

(define (coerce-world->ledger-hash world)
  (cond
    [(hash? world) world]
    [(and *macro-world-state-extractor* (procedure? *macro-world-state-extractor*))
     (define res (*macro-world-state-extractor* world))
     (if (hash? res) res (hasheq))]
    [else (hasheq)]))

(define (ledger-world-unit-counts val)
  (cond
    [(hash? val)
     (for/fold ([ht (hasheq)]) ([(k v) (in-hash val)])
       (define sym (and (symbol? k) (canonical-unit-type-sym k)))
       (define cnt (safe-nonneg-int v 0))
       (if (and sym (> cnt 0))
           (hash-update ht sym (lambda (old) (+ old cnt)) 0)
           ht))]
    [(list? val)
     (for/fold ([ht (hasheq)]) ([item (in-list val)])
       (cond
         [(and (pair? item) (symbol? (car item)))
          (define sym (canonical-unit-type-sym (car item)))
          (define cnt (safe-nonneg-int (cdr item) 0))
          (if (> cnt 0)
              (hash-update ht sym (lambda (old) (+ old cnt)) 0)
              ht)]
         [(symbol? item)
          (define sym (canonical-unit-type-sym item))
          (hash-update ht sym add1 0)]
         [(hash? item)
          (define sym (extract-record-sym item))
          (if sym (hash-update ht (canonical-unit-type-sym sym) add1 0) ht)]
         [else ht]))]
    [else (hasheq)]))

(define (ledger-world-upgs val)
  (cond
    [(list? val) (filter symbol? val)]
    [(hash? val) (for/list ([(k v) (in-hash val)] #:when (and (symbol? k) v)) k)]
    [else '()]))

(define (extract-mirror-signals-hash w [explicit-ms #f])
  (define sub (hash-ref w 'mirror-signals #f))
  (define src
    (cond
      [(hash? explicit-ms) explicit-ms]
      [(hash? sub) sub]
      [else (hasheq)]))
  (define (mget k default)
    (cond
      [(and (hash? explicit-ms) (hash-has-key? explicit-ms k)) (hash-ref explicit-ms k default)]
      [(and (hash? sub) (hash-has-key? sub k)) (hash-ref sub k default)]
      [(hash-has-key? w k) (hash-ref w k default)]
      [else (hash-ref src k default)]))
  (hasheq
   'mirror-preemptive-unit (let ([u (mget 'mirror-preemptive-unit #f)])
                             (and (symbol? u) (not (eq? u 'none)) u))
   'mirror-predicted-enemy-unit (let ([u (mget 'mirror-predicted-enemy-unit #f)])
                                  (and (symbol? u) (not (eq? u 'none)) u))
   'mirror-recommended-min-bases (safe-nonneg-int (mget 'mirror-recommended-min-bases 0) 0)
   'mirror-macro-verdict (let ([v (mget 'mirror-macro-verdict 'pace-Macro-And-Disrupt)])
                           (if (symbol? v) v 'pace-Macro-And-Disrupt))
   'mirror-requires-detection? (not (not (mget 'mirror-requires-detection? #f)))
   'mirror-requires-anti-air? (not (not (mget 'mirror-requires-anti-air? #f)))
   'mirror-enemy-upgrade-advantage (safe-exact-int (mget 'mirror-enemy-upgrade-advantage 0) 0)
   'mirror-trust-mode (let ([t (mget 'mirror-trust-mode 'balanced-bayesian-hedged)])
                        (if (symbol? t) t 'balanced-bayesian-hedged))
   'mirror-strategy (mget 'mirror-strategy #f)))

(define LEDGER-AIR-UNIT-SYMS
  '(mutalisk corruptor brood-lord broodlord viper overlord overlord-transport
    overseer overseer-siege-mode viking viking-fighter liberator liberator-ag
    banshee raven battlecruiser medivac phoenix oracle void-ray voidray
    carrier tempest mothership interceptor observer observer-siege-mode
    warp-prism warp-prism-phasing))

(define LEDGER-NONCOMBAT-SYMS
  '(drone scv probe larva egg cocoon overlord mule))

(define LEDGER-CLOAK-BURROW-ENEMY-SYMS
  '(dark-templar banshee ghost lurker lurker-burrowed lurker-mp lurker-mp-burrowed
    roach-burrowed infestor-burrowed widow-mine-burrowed observer mothership))

(define (compute-enemy-comp-attrs enemy-comp)
  (cond
    [(and (hash? enemy-comp)
          (hash-has-key? enemy-comp 'armored-pct)
          (hash-has-key? enemy-comp 'combat-supply))
     enemy-comp]
    [else
     (define counts (ledger-world-unit-counts enemy-comp))
     (define-values (tot-cnt tot-sup worker-cnt combat-cnt combat-sup
                     armored-s light-s bio-s mech-s psi-s shield-s massive-s air-s
                     cap-air-cnt cloak?)
       (for/fold ([tc 0] [ts 0.0] [wc 0] [cc 0] [cs 0.0]
                  [as 0.0] [ls 0.0] [bs 0.0] [ms 0.0] [ps 0.0] [ss 0.0] [mvs 0.0] [ais 0.0]
                  [cac 0] [clk? #f])
                 ([(raw-u cnt) (in-hash counts)]
                  #:when (> cnt 0))
         (define sym (canonical-unit-type-sym raw-u))
         (define c-real (exact->inexact cnt))
         (define unit-sup
           (let ([s (sc2-supply-cost sym 1)])
             (if (and (eq? sym 'zergling) (<= s 1)) 0.5 (max 0.5 (exact->inexact s)))))
         (define sup (* c-real unit-sup))
         (define worker? (not (not (memq sym LEDGER-NONCOMBAT-SYMS))))
         (define mask (unit-attribute-mask sym))
         (define air? (not (not (memq sym LEDGER-AIR-UNIT-SYMS))))
         (define cap-air? (not (not (memq sym PROTOSS-CAPITAL-AIR-ENEMY-SYMS))))
         (define has-clk? (not (not (memq sym LEDGER-CLOAK-BURROW-ENEMY-SYMS))))
         (if worker?
             (values (+ tc cnt) (+ ts sup) (+ wc cnt) cc cs
                     as ls bs ms ps ss mvs ais
                     cac (or clk? has-clk?))
             (values (+ tc cnt) (+ ts sup) wc (+ cc cnt) (+ cs sup)
                     (+ as (if (> (bitwise-and mask SC2-UNIT-ATTR-ARMORED) 0) sup 0.0))
                     (+ ls (if (> (bitwise-and mask SC2-UNIT-ATTR-LIGHT) 0) sup 0.0))
                     (+ bs (if (> (bitwise-and mask SC2-UNIT-ATTR-BIOLOGICAL) 0) sup 0.0))
                     (+ ms (if (> (bitwise-and mask SC2-UNIT-ATTR-MECHANICAL) 0) sup 0.0))
                     (+ ps (if (> (bitwise-and mask SC2-UNIT-ATTR-PSIONIC) 0) sup 0.0))
                     (+ ss (if (> (bitwise-and mask SC2-UNIT-ATTR-SHIELDED) 0) sup 0.0))
                     (+ mvs (if (> (bitwise-and mask SC2-UNIT-ATTR-MASSIVE) 0) sup 0.0))
                     (+ ais (if air? sup 0.0))
                     (+ cac (if cap-air? cnt 0))
                     (or clk? has-clk?)))))
     (define denom (max 1.0 combat-sup))
     (define (pct v) (if (> combat-sup 0.0) (min 1.0 (/ v denom)) 0.0))
     (define (u-cnt . syms)
       (for/sum ([s (in-list syms)])
         (safe-nonneg-int (hash-ref counts (canonical-unit-type-sym s) 0) 0)))
     (define queen-cnt (u-cnt 'queen 'queen-burrowed))
     (define infestor-cnt (u-cnt 'infestor 'infestor-burrowed))
     (define muta-cnt (u-cnt 'mutalisk))
     (define corr-cnt (u-cnt 'corruptor))
     (define bl-cnt (u-cnt 'brood-lord 'broodlord))
     (define temp-cnt (u-cnt 'tempest))
     (define carr-cnt (u-cnt 'carrier))
     (define bc-cnt (u-cnt 'battlecruiser))
     (define imm-cnt (u-cnt 'immortal))
     (hasheq
      'unit-counts counts
      'total-count tot-cnt
      'total-supply tot-sup
      'worker-count worker-cnt
      'combat-count combat-cnt
      'combat-supply combat-sup
      'armored-supply armored-s
      'light-supply light-s
      'biological-supply bio-s
      'mechanical-supply mech-s
      'psionic-supply psi-s
      'shielded-supply shield-s
      'massive-supply massive-s
      'air-supply air-s
      'armored-pct (pct armored-s)
      'light-pct (pct light-s)
      'biological-pct (pct bio-s)
      'mechanical-pct (pct mech-s)
      'psionic-pct (pct psi-s)
      'shielded-pct (pct shield-s)
      'massive-pct (pct massive-s)
      'air-pct (pct air-s)
      'immortal-count imm-cnt
      'queen-count queen-cnt
      'infestor-count infestor-cnt
      'queen-infestor-count (+ queen-cnt infestor-cnt)
      'lurker-count (u-cnt 'lurker 'lurker-burrowed 'lurker-mp 'lurker-mp-burrowed)
      'ultralisk-count (u-cnt 'ultralisk 'ultralisk-burrowed)
      'zergling-count (u-cnt 'zergling 'zergling-burrowed)
      'baneling-count (u-cnt 'baneling 'baneling-burrowed)
      'roach-count (u-cnt 'roach 'roach-burrowed)
      'ravager-count (u-cnt 'ravager)
      'hydralisk-count (u-cnt 'hydralisk 'hydralisk-burrowed)
      'viper-count (u-cnt 'viper)
      'mutalisk-count muta-cnt
      'corruptor-count corr-cnt
      'brood-lord-count bl-cnt
      'hellion-count (u-cnt 'hellion)
      'hellbat-count (u-cnt 'hellbat 'hellion-tank)
      'marine-count (u-cnt 'marine)
      'marauder-count (u-cnt 'marauder)
      'medivac-count (u-cnt 'medivac)
      'siege-tank-count (u-cnt 'siege-tank 'siege-tank-sieged)
      'battlecruiser-count bc-cnt
      'tempest-count temp-cnt
      'carrier-count carr-cnt
      'void-ray-count (u-cnt 'void-ray 'voidray)
      'stalker-count (u-cnt 'stalker)
      'zealot-count (u-cnt 'zealot)
      'adept-count (u-cnt 'adept)
      'colossus-count (u-cnt 'colossus)
      'high-templar-count (u-cnt 'high-templar)
      'archon-count (u-cnt 'archon)
      'disruptor-count (u-cnt 'disruptor 'disruptor-phased)
      'phoenix-count (u-cnt 'phoenix)
      'oracle-count (u-cnt 'oracle)
      'dark-templar-count (u-cnt 'dark-templar)
      'banshee-count (u-cnt 'banshee)
      'capital-air-count cap-air-cnt
      'capital-air? (> cap-air-cnt 0)
      'cloak-or-burrow? cloak?)]))

(define (ledger-world-sup-used w)
  (cond
    [(real? (hash-ref w 'supply-used #f))
     (max 0.0 (exact->inexact (hash-ref w 'supply-used 0)))]
    [else
     (define cap (safe-nonneg-int (hash-ref w 'supply-cap 15) 15))
     (define left (max 0 (safe-exact-int (hash-ref w 'supply-left 4) 4)))
     (exact->inexact (max 0 (- cap left)))]))

(define (ledger-world-effective-phase-supply w)
  (define explicit (hash-ref w 'effective-phase-supply #f))
  (if (real? explicit)
      (max 0.0 (exact->inexact explicit))
      (let ([sup-used (ledger-world-sup-used w)]
            [army (max 0.0 (safe-real (hash-ref w 'army-supply 0.0) 0.0))]
            [workers (exact->inexact (safe-nonneg-int (hash-ref w 'workers (hash-ref w 'worker-count 12)) 12))])
        (max sup-used (+ army workers)))))

(define (detect-build-order-deviation world [enemy-comp-attrs-arg #f] [mirror-signals-arg #f])
  (define w (coerce-world->ledger-hash world))
  (define frame (safe-nonneg-int (hash-ref w 'frame 0) 0))
  (define under-attack? (eq? (hash-ref w 'under-attack? #f) #t))
  (define threat-sup (max 0.0 (safe-real (hash-ref w 'enemy-threat-supply 0.0) 0.0)))
  (define natural-blocked? (eq? (hash-ref w 'natural-blocked? #f) #t))
  (define ms (extract-mirror-signals-hash w mirror-signals-arg))
  (define eu-raw (or enemy-comp-attrs-arg (hash-ref w 'enemy-unit-counts (hash-ref w 'enemy-units (hasheq)))))
  (define attrs (compute-enemy-comp-attrs eu-raw))
  (define eff-sup (ledger-world-effective-phase-supply w))
  (define combat-sup (safe-real (hash-ref attrs 'combat-supply 0.0) 0.0))
  (define imm-cnt (safe-nonneg-int (hash-ref attrs 'immortal-count 0) 0))
  (define qi-cnt (safe-nonneg-int (hash-ref attrs 'queen-infestor-count 0) 0))
  (define max-attr-pct
    (max (safe-real (hash-ref attrs 'armored-pct 0.0) 0.0)
         (safe-real (hash-ref attrs 'light-pct 0.0) 0.0)
         (safe-real (hash-ref attrs 'mechanical-pct 0.0) 0.0)
         (safe-real (hash-ref attrs 'psionic-pct 0.0) 0.0)
         (safe-real (hash-ref attrs 'massive-pct 0.0) 0.0)
         (safe-real (hash-ref attrs 'air-pct 0.0) 0.0)))
  (define m-strat (hash-ref ms 'mirror-strategy #f))
  (define m-verdict (hash-ref ms 'mirror-macro-verdict 'pace-Macro-And-Disrupt))
  (define cheese?
    (or (eq? (hash-ref w 'enemy-cheese? #f) #t)
        (eq? (hash-ref w 'cheese-detected? #f) #t)
        (not (not (memq m-strat '(cannon-rush 12-pool worker-rush proxy-rax proxy-gate cheese bunker-rush))))
        (and (< frame 4200) (eq? m-verdict 'defend-All-In-Then-Counter-Expand))
        (and (< frame 2688) (>= (safe-nonneg-int (hash-ref attrs 'worker-count 0) 0) 6))))
  (define post-bo-phase?
    (or (eq? (hash-ref w 'post-bo-phase? #f) #t)
        (>= eff-sup 75.0)
        (>= frame 7392)))
  (define heavy-skew?
    (or (>= imm-cnt 3)
        (>= qi-cnt 15)
        (and (>= combat-sup 8.0) (>= max-attr-pct 0.75))))
  (define reasons
    (reverse
     (let* ([rs '()]
            [rs (if (and (< frame 3000) (or under-attack? (>= threat-sup 4.0)))
                    (cons 'early-rush-crisis rs)
                    rs)]
            [rs (if natural-blocked?
                    (cons 'blocked-natural rs)
                    rs)]
            [rs (if (or (eq? (hash-ref attrs 'capital-air? #f) #t) cheese?)
                    (cons 'enemy-capital-air-or-cheese rs)
                    rs)]
            [rs (if (>= imm-cnt 3) (cons 'heavy-immortal-skew rs) rs)]
            [rs (if (>= qi-cnt 15) (cons 'heavy-queen-infestor-skew rs) rs)]
            [rs (if (and heavy-skew? (not (memq 'heavy-immortal-skew rs)) (not (memq 'heavy-queen-infestor-skew rs)))
                    (cons 'heavy-attribute-skew rs)
                    rs)]
            [rs (if post-bo-phase?
                    (cons 'post-bo-time-or-supply rs)
                    rs)])
       rs)))
  (define deviated?
    (or (pair? reasons)
        post-bo-phase?
        (eq? (hash-ref w 'deviated? #f) #t)))
  (hasheq
   'deviated? deviated?
   'reasons reasons
   'post-bo-phase? post-bo-phase?
   'suppress-opening-harass? (or deviated? post-bo-phase?)
   'effective-phase-supply eff-sup
   'frame frame
   'enemy-comp-attrs attrs))

(define (mirror-predicted-threat->counters race pred-sym)
  (case race
    [(Zerg)
     (case pred-sym
       [(immortal stalker colossus siege-tank thor) '(hydralisk zergling ravager)]
       [(mutalisk phoenix oracle void-ray carrier tempest battlecruiser liberator banshee)
        '(corruptor hydralisk queen spore-crawler)]
       [(dark-templar lurker ghost banshee widow-mine) '(overseer hydralisk)]
       [(zealot marine adept hellion zergling) '(baneling roach)]
       [else '(hydralisk roach)])]
    [(Terran)
     (case pred-sym
       [(zergling zealot adept marine) '(hellbat marine)]
       [(queen infestor lurker ultralisk high-templar archon immortal) '(ghost marauder liberator)]
       [(siege-tank battlecruiser) '(raven viking-fighter liberator)]
       [(tempest carrier void-ray mutalisk brood-lord) '(viking-fighter thor ghost)]
       [(dark-templar banshee lurker) '(raven)]
       [else '(marauder siege-tank medivac)])]
    [else ;; Protoss
     (case pred-sym
       [(stalker roach marauder siege-tank immortal) '(immortal zealot archon)]
       [(zergling hydralisk marine zealot) '(colossus high-templar archon zealot)]
       [(mutalisk phoenix) '(phoenix stalker)]
       [(carrier tempest battlecruiser brood-lord void-ray liberator) '(tempest void-ray stalker)]
       [(dark-templar banshee lurker) '(observer immortal)]
       [else '(immortal stalker archon)])]))

(define (post-bo-upgrade-chain race enemy-race attrs upgs pend-upgs has-air-fleet? has-robo-or-colossus? has-templar? has-mech?)
  (define (done-or-pend? s)
    (or (has-upgrade-sym? s upgs)
        (not (not (memq s upgs)))
        (has-upgrade-sym? s pend-upgs)
        (not (not (memq s pend-upgs)))))
  (define ordered
    (case race
      [(Zerg)
       (append
        '(metabolic-boost)
        (if (or (> (hash-ref attrs 'roach-count 0) 0) (eq? enemy-race 'Terran))
            '(glial-reconstitution)
            '())
        (if (or (eq? enemy-race 'Protoss) (eq? enemy-race 'Zerg) (> (hash-ref attrs 'immortal-count 0) 0) (> (hash-ref attrs 'lurker-count 0) 0))
            '(zerg-missile-weapons-1 zerg-ground-armor-1 grooved-spines muscular-augments
              zerg-missile-weapons-2 zerg-ground-armor-2
              zerg-melee-weapons-1 zerg-melee-weapons-2
              zerg-missile-weapons-3 zerg-ground-armor-3 zerg-melee-weapons-3
              centrifical-hooks chitinous-plating anabolic-synthesis)
            '(zerg-melee-weapons-1 zerg-ground-armor-1 zerg-missile-weapons-1
              centrifical-hooks grooved-spines muscular-augments
              zerg-melee-weapons-2 zerg-ground-armor-2 zerg-missile-weapons-2
              zerg-melee-weapons-3 zerg-ground-armor-3 zerg-missile-weapons-3
              chitinous-plating anabolic-synthesis))
        (if (or has-air-fleet? (hash-ref attrs 'capital-air? #f) (> (hash-ref attrs 'air-pct 0.0) 0.20))
            '(zerg-flyer-weapons-1 zerg-flyer-armor-1 zerg-flyer-weapons-2 zerg-flyer-armor-2
              zerg-flyer-weapons-3 zerg-flyer-armor-3)
            '()))]
      [(Terran)
       (append
        '(stimpack combat-shield concussive-shells)
        (if (or has-mech? (eq? enemy-race 'Terran))
            '(terran-infantry-weapons-1 terran-infantry-armor-1
              terran-vehicle-weapons-1 terran-vehicle-and-ship-plating-1
              terran-ship-weapons-1
              terran-infantry-weapons-2 terran-infantry-armor-2
              terran-vehicle-weapons-2 terran-vehicle-and-ship-plating-2
              terran-ship-weapons-2
              terran-infantry-weapons-3 terran-infantry-armor-3
              terran-vehicle-weapons-3 terran-vehicle-and-ship-plating-3
              terran-ship-weapons-3
              advanced-ballistics)
            '(terran-infantry-weapons-1 terran-infantry-armor-1
              terran-infantry-weapons-2 terran-infantry-armor-2
              terran-ship-weapons-1 terran-vehicle-weapons-1 terran-vehicle-and-ship-plating-1
              terran-infantry-weapons-3 terran-infantry-armor-3
              terran-vehicle-weapons-2 terran-vehicle-and-ship-plating-2
              terran-ship-weapons-2 terran-ship-weapons-3)))]
      [else ;; Protoss
       (append
        '(warp-gate-research charge)
        '(protoss-ground-weapons-1 protoss-ground-armor-1)
        (if has-robo-or-colossus? '(extended-thermal-lance) '())
        (if has-templar? '(psi-storm) '())
        '(blink
          protoss-ground-weapons-2 protoss-ground-armor-2
          protoss-ground-weapons-3 protoss-ground-armor-3
          protoss-shields-1 protoss-shields-2 protoss-shields-3)
        (if (or has-air-fleet? (hash-ref attrs 'capital-air? #f) (> (hash-ref attrs 'air-pct 0.0) 0.25))
            '(protoss-air-weapons-1 protoss-air-armor-1
              protoss-air-weapons-2 protoss-air-armor-2
              protoss-air-weapons-3 protoss-air-armor-3)
            '()))]))
  (filter (lambda (u) (not (done-or-pend? u))) ordered))

(define (evaluate-post-bo-strategic-goals world [enemy-comp-attrs-arg #f] [mirror-signals-arg #f])
  (define w (coerce-world->ledger-hash world))
  (define race (normalize-ledger-race (hash-ref w 'race 'Zerg)))
  (define enemy-race (normalize-enemy-race-sym (hash-ref w 'enemy-race 'Unknown)))
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (define frame (safe-nonneg-int (hash-ref w 'frame 0) 0))
  (define minerals (safe-nonneg-int (hash-ref w 'minerals 0) 0))
  (define workers (safe-nonneg-int (hash-ref w 'workers (hash-ref w 'worker-count 12)) 12))
  (define active-bases (max 1 (safe-nonneg-int (hash-ref w 'active-bases 1) 1)))
  (define depleting-bases (safe-nonneg-int (hash-ref w 'depleting-bases 0) 0))
  (define base-desired (safe-nonneg-int (hash-ref w 'desired-bases (if (>= workers 30) 3 2)) 2))
  (define army-sup (max 0.0 (safe-real (hash-ref w 'army-supply 0.0) 0.0)))
  (define threat-sup (max 0.0 (safe-real (hash-ref w 'enemy-threat-supply 0.0) 0.0)))
  (define l-ratio (max 0.0 (safe-real (hash-ref w 'lanchester-ratio 1.0) 1.0)))
  (define under-attack? (eq? (hash-ref w 'under-attack? #f) #t))
  (define raw-req-aa? (eq? (hash-ref w 'requires-anti-air? #f) #t))
  (define raw-req-det? (eq? (hash-ref w 'requires-detection? #f) #t))
  (define upgs (ledger-world-upgs (hash-ref w 'researched-upgrades (hash-ref w 'upgrades '()))))
  (define pend-upgs (ledger-world-upgs (hash-ref w 'pending-upgrades '())))
  (define ally-u (ledger-world-unit-counts (hash-ref w 'unit-counts (hash-ref w 'ally-units (hasheq)))))
  (define ally-b (ledger-world-unit-counts (hash-ref w 'building-counts (hash-ref w 'ally-buildings (hasheq)))))
  (define ms (extract-mirror-signals-hash w mirror-signals-arg))
  (define attrs (compute-enemy-comp-attrs
                 (or enemy-comp-attrs-arg (hash-ref w 'enemy-unit-counts (hash-ref w 'enemy-units (hasheq))))))
  (define dev (detect-build-order-deviation w attrs ms))
  (define deviated? (eq? (hash-ref dev 'deviated? #f) #t))
  (define post-bo-phase? (eq? (hash-ref dev 'post-bo-phase? #f) #t))
  (define suppress-opening-harass? (eq? (hash-ref dev 'suppress-opening-harass? #f) #t))
  (define eff-sup (safe-real (hash-ref dev 'effective-phase-supply 0.0) 0.0))

  ;; Mirror-Brain signals
  (define m-pre (hash-ref ms 'mirror-preemptive-unit #f))
  (define m-pred (hash-ref ms 'mirror-predicted-enemy-unit #f))
  (define m-min-bases (safe-nonneg-int (hash-ref ms 'mirror-recommended-min-bases 0) 0))
  (define m-verdict (hash-ref ms 'mirror-macro-verdict 'pace-Macro-And-Disrupt))
  (define m-det? (eq? (hash-ref ms 'mirror-requires-detection? #f) #t))
  (define m-aa? (eq? (hash-ref ms 'mirror-requires-anti-air? #f) #t))
  (define m-upg-adv (safe-exact-int (hash-ref ms 'mirror-enemy-upgrade-advantage 0) 0))
  (define m-trust (hash-ref ms 'mirror-trust-mode 'balanced-bayesian-hedged))
  (define trust-scale
    (case m-trust
      [(level2-preemptive-mirror) 1.0]
      [(skeptical-observational-fallback) 0.35]
      [else 0.75]))

  ;; Pillar 1: Expansion & Macro Scaling
  (define desired-bases
    (min 8 (max base-desired
                m-min-bases
                (if (> depleting-bases 0) (add1 active-bases) active-bases))))
  (define expansion-urgency
    (+ (if (< active-bases desired-bases) 0.9 0.0)
       (* 0.85 depleting-bases)
       (if (eq? m-verdict 'out-Expand-Passive-Turtle) 0.75 0.0)
       (if (and (>= minerals 1000) (not under-attack?)) 0.65 0.0)))
  (define high-bank-macro-inject? (>= minerals 1000))
  (define macro-inject-structures
    (case race
      [(Zerg) '(hatchery)]
      [(Terran) '(command-center barracks factory starport)]
      [else '(nexus gateway robotics-facility)]))

  ;; Pillar 2: Continuous Upgrade Escalation
  (define upgrade-escalation-active?
    (or post-bo-phase?
        (and (>= active-bases 2) (>= workers 30))))
  (define upgrade-priority-mult
    (+ (if upgrade-escalation-active? 1.25 1.0)
       (* 0.45 (max 0 m-upg-adv))))
  (define desired-upgrade-bays (if upgrade-escalation-active? 2 1))
  (define desired-upgrade-bay-sym
    (case race
      [(Zerg) 'evolution-chamber]
      [(Terran) 'engineering-bay]
      [else 'forge]))
  (define has-air-fleet?
    (> (+ (hash-ref ally-u 'corruptor 0)
          (hash-ref ally-u 'mutalisk 0)
          (hash-ref ally-u 'viking-fighter 0)
          (hash-ref ally-u 'liberator 0)
          (hash-ref ally-u 'void-ray 0)
          (hash-ref ally-u 'tempest 0)
          (hash-ref ally-u 'carrier 0))
       2))
  (define has-robo-or-colossus?
    (or (> (hash-ref ally-u 'colossus 0) 0)
        (> (hash-ref ally-b 'robotics-bay 0) 0)))
  (define has-templar?
    (or (> (hash-ref ally-u 'high-templar 0) 0)
        (> (hash-ref ally-b 'templar-archive 0) 0)))
  (define has-mech?
    (> (+ (hash-ref ally-u 'siege-tank 0) (hash-ref ally-u 'hellbat 0) (hash-ref ally-u 'thor 0)) 2))
  (define zerg-hive-t3-ready?
    (and (eq? race 'Zerg)
         (> (hash-ref ally-b 'hive 0) 0)
         (or (> (hash-ref ally-b 'ultralisk-cavern 0) 0)
             (> (hash-ref ally-b 'greater-spire 0) 0))))
  (define raw-recommended-upgrades
    (post-bo-upgrade-chain race enemy-race attrs upgs pend-upgs
                           has-air-fleet? has-robo-or-colossus? has-templar? has-mech?))
  (define recommended-upgrades
    (filter (lambda (u)
              (and (upgrade-allowed-by-unit-and-order-gates?
                    race u frame workers ally-b ally-b ally-u upgs pend-upgs)
                   (or (not zerg-hive-t3-ready?)
                       (not (or (eq? u 'burrow)
                                (and (memq u '(glial-reconstitution tunneling-claws))
                                     (= (hash-ref ally-b 'roach-warren 0) 0))
                                (and (eq? u 'centrifical-hooks)
                                     (= (hash-ref ally-b 'baneling-nest 0) 0))
                                (and (memq u '(zerg-melee-weapons-1 zerg-melee-weapons-2 zerg-melee-weapons-3
                                               zerg-ground-armor-1 zerg-ground-armor-2 zerg-ground-armor-3
                                               zerg-missile-weapons-1 zerg-missile-weapons-2 zerg-missile-weapons-3))
                                     (= (hash-ref ally-b 'evolution-chamber 0) 0)))))))
            raw-recommended-upgrades))

  ;; Pillar 3: Attribute-Counter Composition + 9 Matchups + Mirror-Brain
  (define rec-ht (make-hasheq))
  (define (add-rec! sym amt)
    (when (symbol? sym)
      (hash-set! rec-ht sym (+ (hash-ref rec-ht sym 0.0) amt))))
  (define arm-pct (safe-real (hash-ref attrs 'armored-pct 0.0) 0.0))
  (define light-pct (safe-real (hash-ref attrs 'light-pct 0.0) 0.0))
  (define air-pct (safe-real (hash-ref attrs 'air-pct 0.0) 0.0))
  (define mech-pct (safe-real (hash-ref attrs 'mechanical-pct 0.0) 0.0))
  (define cap-air? (eq? (hash-ref attrs 'capital-air? #f) #t))
  (define muta-cnt (safe-nonneg-int (hash-ref attrs 'mutalisk-count 0) 0))
  (define req-aa? (or raw-req-aa? m-aa? cap-air? (> air-pct 0.20) (> muta-cnt 0)))
  (define req-det? (or raw-req-det? m-det? (eq? (hash-ref attrs 'cloak-or-burrow? #f) #t)))
  (define pvt-fast-kiter?
    (and (eq? race 'Protoss)
         (> (+ (hash-ref attrs 'reaper-count 0)
               (hash-ref attrs 'hellion-count 0)
               (hash-ref attrs 'marine-count 0)
               (hash-ref attrs 'adept-count 0)
               (hash-ref attrs 'stalker-count 0))
            0)))

  ;; Attribute counters
  (when (>= arm-pct 0.45)
    (case race
      [(Zerg)
       (if zerg-hive-t3-ready?
           (begin
             (for-each (lambda (u) (add-rec! u (* 32.0 arm-pct)))
                       (append '(hydralisk lurker viper)
                               (if (> (hash-ref ally-b 'ultralisk-cavern 0) 0) '(ultralisk) '())
                               (if (> (hash-ref ally-b 'greater-spire 0) 0) '(brood-lord) '())
                               (if (> (hash-ref ally-b 'roach-warren 0) 0) '(ravager) '()))))
           (for-each (lambda (u) (add-rec! u (* 32.0 arm-pct))) '(hydralisk ravager lurker)))]
      [(Terran) (for-each (lambda (u) (add-rec! u (* 32.0 arm-pct))) '(marauder liberator siege-tank))]
      [else (for-each (lambda (u) (add-rec! u (* 36.0 arm-pct))) '(immortal void-ray tempest))]))
  (when (>= light-pct 0.45)
    (case race
      [(Zerg)
       (if (and zerg-hive-t3-ready? (= (hash-ref ally-b 'baneling-nest 0) 0))
           (for-each (lambda (u) (add-rec! u (* 30.0 light-pct)))
                     (if (> (hash-ref ally-b 'ultralisk-cavern 0) 0) '(ultralisk lurker) '(lurker)))
           (for-each (lambda (u) (add-rec! u (* 30.0 light-pct))) '(baneling baneling-nest lurker)))]
      [(Terran) (for-each (lambda (u) (add-rec! u (* 32.0 light-pct))) '(hellbat siege-tank))]
      [else (for-each (lambda (u) (add-rec! u (* 34.0 light-pct))) '(colossus high-templar archon))]))
  (when req-aa?
    (case race
      [(Zerg) (for-each (lambda (u) (add-rec! u 42.0)) '(hydralisk corruptor queen spore-crawler))]
      [(Terran) (for-each (lambda (u) (add-rec! u 42.0)) '(viking-fighter thor marine))]
      [else
       (if (eq? enemy-race 'Terran)
           (for-each (lambda (u) (add-rec! u 40.0)) '(stalker tempest void-ray))
           (for-each (lambda (u) (add-rec! u 42.0))
                     (if (> muta-cnt 0) '(phoenix stalker tempest) '(stalker tempest void-ray))))]))
  (when req-det?
    (case race
      [(Zerg) (add-rec! 'overseer 55.0)]
      [(Terran) (add-rec! 'raven 60.0)]
      [else (add-rec! 'observer 55.0)]))

  ;; 9 Matchup Fixes
  (define imm-cnt (hash-ref attrs 'immortal-count 0))
  (define qi-cnt (hash-ref attrs 'queen-infestor-count 0))
  (define zea-cnt (hash-ref attrs 'zealot-count 0))
  (define ling-cnt (hash-ref attrs 'zergling-count 0))
  (define hell-cnt (hash-ref attrs 'hellion-count 0))
  (define roach-cnt (hash-ref attrs 'roach-count 0))
  (define hydra-cnt (hash-ref attrs 'hydralisk-count 0))
  (define stalker-cnt (hash-ref attrs 'stalker-count 0))
  (define tank-cnt (hash-ref attrs 'siege-tank-count 0))
  (define bc-cnt (hash-ref attrs 'battlecruiser-count 0))
  (define temp-cnt (hash-ref attrs 'tempest-count 0))
  (define bio-tank-enemy?
    (and (eq? enemy-race 'Terran)
         (> (+ (hash-ref attrs 'marine-count 0)
               (hash-ref attrs 'marauder-count 0)
               (hash-ref attrs 'medivac-count 0)
               tank-cnt)
            2)))

  (case m-sym
    [(ZvP)
     (when (or (>= imm-cnt 2) (and (>= arm-pct 0.50) (> imm-cnt 0)))
       (for-each (lambda (u) (add-rec! u 48.0)) '(hydralisk-den hydralisk ravager lurker-den lurker)))
     (when (or (>= zea-cnt 4) (>= light-pct 0.50))
       (for-each (lambda (u) (add-rec! u 45.0)) '(baneling-nest baneling)))
     (when cap-air?
       (for-each (lambda (u) (add-rec! u 55.0)) '(corruptor hydralisk viper)))]
    [(ZvZ)
     (when (or (>= qi-cnt 10) (>= (hash-ref attrs 'infestor-count 0) 2))
       (for-each (lambda (u) (add-rec! u 52.0)) '(ravager lurker-den lurker ultralisk-cavern ultralisk)))
     (when (> muta-cnt 0)
       (for-each (lambda (u) (add-rec! u 48.0)) '(hydralisk queen spore-crawler)))]
    [(ZvT)
     (when (> hell-cnt 0)
       (for-each (lambda (u) (add-rec! u 46.0)) '(roach-warren roach queen)))
     (when bio-tank-enemy?
       (for-each (lambda (u) (add-rec! u 45.0)) '(baneling-nest baneling hydralisk lurker-den lurker viper)))]
    [(TvZ)
     (when (or (>= ling-cnt 8) (>= light-pct 0.55))
       (for-each (lambda (u) (add-rec! u 48.0)) '(armory hellbat)))
     (when (or (>= qi-cnt 6) (> (hash-ref attrs 'lurker-count 0) 0) (> (hash-ref attrs 'ultralisk-count 0) 0))
       (for-each (lambda (u) (add-rec! u 52.0)) '(ghost-academy ghost liberator)))]
    [(TvT)
     (when (or (> tank-cnt 0) (> bc-cnt 0) (>= mech-pct 0.40) (>= (hash-ref attrs 'total-count 0) 0))
       (for-each (lambda (u) (add-rec! u 46.0)) '(raven viking-fighter liberator siege-tank)))]
    [(TvP)
     (for-each (lambda (u) (add-rec! u 42.0)) '(barracks-techlab marauder ghost-academy ghost medivac))
     (when (or (> temp-cnt 0) cap-air?)
       (for-each (lambda (u) (add-rec! u 58.0)) '(viking-fighter ghost thor armory)))]
    [(PvZ)
     (when (>= roach-cnt 3)
       (for-each (lambda (u) (add-rec! u 48.0)) '(robotics-facility immortal)))
     (when (or (>= ling-cnt 6) (>= hydra-cnt 2) (>= light-pct 0.45))
       (for-each (lambda (u) (add-rec! u 48.0)) '(robotics-bay colossus templar-archive high-templar archon zealot)))]
    [(PvT)
     (when (or (>= (hash-ref attrs 'bio-count 0) 4)
               (>= (hash-ref attrs 'tank-count 0) 1)
               (>= (hash-ref attrs 'light-count 0) 4)
               (>= (hash-ref attrs 'total-count 0) 6)
               (>= (hash-ref world 'active-bases 1) 3))
       (for-each (lambda (u) (add-rec! u 48.0))
                 '(robotics-bay colossus templar-archive high-templar archon forge)))]
    [(PvP)
     (when (or (>= stalker-cnt 4) (and (> (hash-ref attrs 'total-count 0) 0) (not cap-air?)))
       (for-each (lambda (u) (add-rec! u 45.0)) '(immortal zealot charge archon)))
     (when cap-air?
       (for-each (lambda (u) (add-rec! u 56.0)) '(blink stalker void-ray tempest)))])

  ;; Mirror-Brain closed-loop recommendations
  (when m-pred
    (for ([u (in-list (mirror-predicted-threat->counters race m-pred))])
      (add-rec! u (* 36.0 trust-scale))))
  (when m-pre
    (add-rec! m-pre (* 44.0 trust-scale)))

  ;; Opening harass suppression + PvZ/PvT caps
  (define cur-oracles (hash-ref ally-u 'oracle 0))
  (define cur-phoenix (hash-ref ally-u 'phoenix 0))
  (define combat-aa-phoenix-needed?
    (and (eq? race 'Protoss)
         (not (eq? enemy-race 'Terran))
         (or (> muta-cnt 0)
             (and req-aa? (eq? enemy-race 'Zerg)))))
  (define suppressed-units
    (remove-duplicates
     (filter
      values
      (list
       (and (eq? race 'Terran) suppress-opening-harass? 'reaper)
       (and (eq? race 'Protoss)
            (or suppress-opening-harass?
                (and (eq? enemy-race 'Zerg) (or (>= cur-oracles 1) (> muta-cnt 0) req-aa?)))
            'oracle)
       (and (eq? race 'Protoss)
            (or (eq? enemy-race 'Terran)
                (and (not combat-aa-phoenix-needed?)
                     (or suppress-opening-harass?
                         (and (eq? enemy-race 'Zerg) (>= cur-phoenix 1)))))
            'phoenix)
       (and (eq? race 'Protoss) suppress-opening-harass? (not pvt-fast-kiter?) 'adept)
       (and (eq? m-sym 'ZvP) (>= imm-cnt 3) 'roach)))))

  (for ([su (in-list suppressed-units)])
    (hash-remove! rec-ht su))

  (define unit-caps
    (cond
      [(eq? m-sym 'PvZ)
       (hasheq 'oracle (if (or suppress-opening-harass? (> muta-cnt 0) req-aa?) 0 1)
               'phoenix (if combat-aa-phoenix-needed? 8 (if suppress-opening-harass? 0 1)))]
      [(eq? m-sym 'PvT)
       (hasheq 'phoenix 0
               'oracle (if suppress-opening-harass? 0 1))]
      [else
       (hasheq 'reaper (if suppress-opening-harass? 0 2))]))

  ;; Pillar 4: Dynamic Post-BO Tactical Phase & Power-Spike Timing Goals
  (define emx (safe-tile-coord (hash-ref w 'enemy-main-x 140.0) 140.0))
  (define emy (safe-tile-coord (hash-ref w 'enemy-main-y 140.0) 140.0))
  (define enx (safe-tile-coord (hash-ref w 'enemy-nat-x 120.0) 120.0))
  (define eny (safe-tile-coord (hash-ref w 'enemy-nat-y 120.0) 120.0))
  (define e3x (safe-tile-coord (hash-ref w 'enemy-third-x 105.0) 105.0))
  (define e3y (safe-tile-coord (hash-ref w 'enemy-third-y 125.0) 125.0))
  (define bx (safe-tile-coord (hash-ref w 'base-x 32.5) 32.5))
  (define by (safe-tile-coord (hash-ref w 'base-y 32.5) 32.5))
  (define nx (safe-tile-coord (hash-ref w 'nat-x 50.5) 50.5))
  (define ny (safe-tile-coord (hash-ref w 'nat-y 50.5) 50.5))
  (define upgrade-spike-ready?
    (and (>= (length upgs) 2)
         (<= m-upg-adv 0)))
  (define-values (tactical-phase target-loc micro-profile abort-cond)
    (cond
      [(or under-attack?
           (eq? m-verdict 'defend-All-In-Then-Counter-Expand)
           (memq 'early-rush-crisis (hash-ref dev 'reasons '()))
           (and (not (eq? m-verdict 'out-Expand-Passive-Turtle)) (< l-ratio 0.85))
           (and (eq? m-verdict 'out-Expand-Passive-Turtle) (< active-bases desired-bases) (< eff-sup 150.0)))
       (values 'defend-and-out-expand
               (hasheq 'x nx 'y ny 'locus 'home-natural-and-expand)
               'defensive-concave-and-counter-expand
               'never-abort-defend-home-until-threat-cleared)]
      [(>= eff-sup 180.0)
       (values 'max-supply-multi-prong-break
               (hasheq 'x enx 'y eny 'secondary-x emx 'secondary-y emy 'locus 'enemy-main-and-natural-fork)
               'multi-prong-break-and-mineral-harass
               'abort-losing-prong-below-0.75-ratio-and-regroup)]
      [(and (>= l-ratio 1.05)
            (or (>= eff-sup 125.0)
                (and upgrade-spike-ready? (>= eff-sup 90.0)))
            (not (eq? m-verdict 'punish-And-Deny-Greedy-Expand)))
       (values 'execute-power-spike-push
               (hasheq 'x enx 'y eny 'secondary-x e3x 'secondary-y e3y 'locus 'enemy-natural-power-spike)
               'pre-spread-power-spike-focus-fire
               'abort-on-35pct-army-loss-or-home-counter-all-in)]
      [(or (eq? m-verdict 'punish-And-Deny-Greedy-Expand)
           (and (>= eff-sup 75.0) (>= l-ratio 0.90) (>= active-bases 3)))
       (values 'contain-and-deny-enemy-expansion
               (hasheq 'x e3x 'y e3y 'secondary-x enx 'secondary-y eny 'locus 'enemy-third-base-denial)
               'contain-choke-poke-and-deny-third
               'abort-contain-if-lanchester-below-0.80)]
      [else
       (values 'accumulate-for-upgrade-spike
               (hasheq 'x nx 'y ny 'locus 'home-staging-rally)
               'patient-upgrade-skirmish-and-creep-map-control
               'abort-skirmish-until-upgrade-timing-completes)]))

  (hasheq
   'deviation dev
   'deviated? deviated?
   'post-bo-phase? post-bo-phase?
   'suppress-opening-harass? suppress-opening-harass?
   'race race
   'enemy-race enemy-race
   'matchup m-sym
   ;; Pillar 1
   'desired-bases desired-bases
   'depleting-bases depleting-bases
   'mirror-recommended-min-bases m-min-bases
   'expansion-urgency expansion-urgency
   'high-bank-macro-inject? high-bank-macro-inject?
   'macro-inject-structures macro-inject-structures
   ;; Pillar 2
   'upgrade-escalation-active? upgrade-escalation-active?
   'upgrade-priority-multiplier upgrade-priority-mult
   'mirror-enemy-upgrade-advantage m-upg-adv
   'desired-upgrade-bays desired-upgrade-bays
   'desired-upgrade-bay-sym desired-upgrade-bay-sym
   'recommended-upgrades recommended-upgrades
   ;; Pillar 3
   'enemy-comp-attrs attrs
   'mirror-preemptive-unit m-pre
   'mirror-predicted-enemy-unit m-pred
   'mirror-requires-detection? m-det?
   'mirror-requires-anti-air? m-aa?
   'mirror-trust-mode m-trust
   'mirror-macro-verdict m-verdict
   'requires-detection? req-det?
   'requires-anti-air? req-aa?
   'recommended-units (for/hasheq ([(k v) (in-hash rec-ht)]) (values k v))
   'suppressed-units suppressed-units
   'unit-caps unit-caps
   ;; Pillar 4
   'tactical-phase tactical-phase
   'target-location target-loc
   'micro-profile micro-profile
   'abort-condition abort-cond))

(define *tactical-plan-extras* (make-weak-hasheq))

(define (tactical-plan-store-extras! plan target-loc micro-profile abort-cond strategic-goals)
  (hash-set! *tactical-plan-extras*
             plan
             (hasheq 'target-location target-loc
                     'micro-profile micro-profile
                     'abort-condition abort-cond
                     'strategic-goals strategic-goals))
  plan)

(define (bo-active-tactical-plan-target-location p)
  (define ext (hash-ref *tactical-plan-extras* p #f))
  (if (and (hash? ext) (hash-has-key? ext 'target-location))
      (hash-ref ext 'target-location)
      (and (bo-active-tactical-plan? p)
           (hasheq 'x (bo-active-tactical-plan-primary-target-x p)
                   'y (bo-active-tactical-plan-primary-target-y p)
                   'locus (bo-active-tactical-plan-target-locus p)))))

(define (bo-active-tactical-plan-micro-profile p)
  (define ext (hash-ref *tactical-plan-extras* p #f))
  (if (and (hash? ext) (hash-has-key? ext 'micro-profile))
      (hash-ref ext 'micro-profile)
      (and (bo-active-tactical-plan? p)
           (let ([ds (bo-active-tactical-plan-micro-directives p)])
             (if (pair? ds) (car ds) 'standard-micro)))))

(define (bo-active-tactical-plan-abort-condition p)
  (define ext (hash-ref *tactical-plan-extras* p #f))
  (if (and (hash? ext) (hash-has-key? ext 'abort-condition))
      (hash-ref ext 'abort-condition)
      'abort-if-lanchester-below-0.80))

(define (bo-active-tactical-plan-strategic-goals p)
  (define ext (hash-ref *tactical-plan-extras* p #f))
  (and (hash? ext) (hash-ref ext 'strategic-goals #f)))

;; =============================================================================
;; 12. Build-Order Tactical Execution & Timing-Attack Plans
;; =============================================================================

(struct bo-tactical-phase-plan
  (phase-id
   matchup
   archetype
   window-start-sec
   window-hit-sec
   window-expire-sec
   pre-position-lead-sec
   trigger-units
   trigger-upgrades
   target-locus
   judgment-rules
   micro-directives
   active-tactics
   post-window-transition)
  #:transparent)

(struct bo-active-tactical-plan
  (matchup
   phase-id
   disposition
   target-locus
   primary-target-x
   primary-target-y
   secondary-fork-x
   secondary-fork-y
   judgment-verdict
   judgment-reason
   micro-directives
   active-tactics
   reinforce-unit-syms
   post-window-transition)
  #:transparent)

(define PRO-BO-TACTICAL-PHASE-PLANS
  (list
   ;; PvZ
   (bo-tactical-phase-plan
    'pvz-glaive-adept-prism-timing
    'PvZ
    'glaive-adept-prism-timing
    270.0 360.0 450.0 15.0
    '((adept . 6) (warp-prism . 1))
    '(resonating-glaives)
    'dual-main-and-natural-mineral-fork
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 8))
    '(shade-mineral-line-fork cancel-shade-if-outnumbered-at-target focus-fire-workers warp-prism-reinforce-warp-in stutter-step-light-units)
    '(multitask-harass-and-proxy transport-drop-micro unit-mode-micro)
    'pvz-colossus-charge-immortal-push)
   (bo-tactical-phase-plan
    'pvz-colossus-charge-immortal-push
    'PvZ
    'colossus-charge-immortal-push
    430.0 540.0 720.0 16.0
    '((zealot . 6) (immortal . 2) (colossus . 1))
    '(charge extended-thermal-lance)
    'enemy-third-base-denial
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.20) (allow-choke-bypass . #t) (abort-army-supply . 12))
    '(focus-fire-heavy-armor sweep-high-ground-thermal-lance shield-battery-overcharge-fallback warp-prism-reinforce-warp-in)
    '(unit-mode-micro transport-drop-micro focus-fire-kite)
    'pvz-carrier-storm-lategame)

   ;; PvT
   (bo-tactical-phase-plan
    'pvt-blink-stalker-immortal-push
    'PvT
    'blink-stalker-immortal-push
    260.0 340.0 430.0 15.0
    '((stalker . 6) (immortal . 1))
    '(blink)
    'enemy-natural-front-and-third-denial
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 8))
    '(blink-under-medivac-or-tank focus-fire-siege-tanks cancel-blink-into-bunkers warp-prism-reinforce-warp-in)
    '(unit-mode-micro transport-drop-micro multitask-harass-and-proxy)
    'pvt-charge-colossus-third-denial)
   (bo-tactical-phase-plan
    'pvt-charge-colossus-third-denial
    'PvT
    'charge-colossus-third-denial
    420.0 510.0 690.0 16.0
    '((zealot . 8) (stalker . 6) (colossus . 2))
    '(charge extended-thermal-lance)
    'enemy-third-base-denial
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 12))
    '(pre-split-vs-emp guardian-shield-bio-engage sweep-bio-thermal-lance warp-prism-reinforce-warp-in)
    '(unit-mode-micro transport-drop-micro focus-fire-kite)
    'pvt-disruptor-storm-lategame)

   ;; PvP
   (bo-tactical-phase-plan
    'pvp-2gate-adept-stalker-expand-pressure
    'PvP
    '2gate-adept-stalker-expand-pressure
    175.0 230.0 320.0 12.0
    '((stalker . 3) (adept . 2))
    '()
    'dual-main-and-natural-mineral-fork
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.20) (allow-choke-bypass . #t) (abort-army-supply . 6))
    '(shade-mineral-line-fork cancel-shade-if-outnumbered-at-target pull-unshielded-stalker-back focus-fire-battery-target)
    '(multitask-harass-and-proxy focus-fire-kite)
    'pvp-blink-immortal-disruptor-push)
   (bo-tactical-phase-plan
    'pvp-blink-immortal-disruptor-push
    'PvP
    'blink-immortal-disruptor-push
    340.0 450.0 640.0 15.0
    '((stalker . 8) (immortal . 2) (disruptor . 1))
    '(blink)
    'enemy-natural-front-and-third-denial
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #f) (abort-army-supply . 10))
    '(stagger-purification-novas blink-snipe-disruptors guardian-shield-mirror focus-fire-immortals)
    '(unit-mode-micro focus-fire-kite)
    'pvp-carrier-tempest-transition)

   ;; TvP
   (bo-tactical-phase-plan
    'tvp-3rax-stim-combat-shield-medivac-push
    'TvP
    '3rax-stim-combat-shield-medivac-push
    270.0 365.0 480.0 15.0
    '((marine . 12) (marauder . 4) (medivac . 2))
    '(stimpack combat-shield)
    'main-drop-and-natural-front-pincer
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 10))
    '(pre-split-vs-splash stim-on-engagement-contact medivac-boost-flank-drop focus-fire-splash-casters stutter-step-kite-melee)
    '(multitask-harass-and-proxy transport-drop-micro unit-mode-micro)
    'tvp-ghost-viking-liberator-transition)

   ;; TvZ
   (bo-tactical-phase-plan
    'tvz-hellion-banshee-harass-into-biomech-tank-timing
    'TvZ
    'hellion-banshee-into-biomech-tank-timing
    240.0 350.0 490.0 15.0
    '((marine . 12) (hellion . 4) (siege-tank . 2) (medivac . 2))
    '(stimpack combat-shield)
    'enemy-third-base-denial
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 10))
    '(pre-split-vs-banelings leapfrog-siege-tanks clear-creep-on-advance medivac-boost-flank-drop stutter-step-kite-melee)
    '(multitask-harass-and-proxy transport-drop-micro unit-mode-micro)
    'tvz-3cc-mine-thor-ghost-macro)

   ;; TvT
   (bo-tactical-phase-plan
    'tvt-raven-tank-viking-air-control-push
    'TvT
    'raven-tank-viking-air-control-push
    290.0 390.0 540.0 15.0
    '((marine . 10) (siege-tank . 2) (viking-fighter . 3) (raven . 1))
    '(stimpack)
    'enemy-natural-front-and-third-denial
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 10))
    '(interference-matrix-tanks maintain-viking-air-control leapfrog-siege-tanks medivac-doom-drop-check)
    '(unit-mode-micro transport-drop-micro multitask-harass-and-proxy)
    'tvt-biomech-liberator-range-lategame)

   ;; ZvZ
   (bo-tactical-phase-plan
    'zvz-ling-bane-tempo-into-roach-ravager
    'ZvZ
    'ling-bane-tempo-into-roach-ravager
    180.0 260.0 370.0 12.0
    '((zergling . 12) (baneling . 4) (roach . 4))
    '(metabolic-boost)
    'dual-main-and-natural-mineral-fork
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.20) (allow-choke-bypass . #t) (abort-army-supply . 6))
    '(baneling-exact-lethal-light-clumps pull-banes-off-roaches surround-with-zerglings target-queen-transfuse-first)
    '(multitask-harass-and-proxy zerg-burrow-micro)
    'zvz-roach-ravager-lurker-transition)

   ;; ZvT
   (bo-tactical-phase-plan
    'zvt-roach-ravager-bane-bile-timing
    'ZvT
    'roach-ravager-bane-bile-timing
    280.0 370.0 495.0 15.0
    '((roach . 8) (ravager . 3) (baneling . 4))
    '(glial-reconstitution)
    'enemy-natural-choke-siege-breaker
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 10))
    '(corrosive-bile-tanks-bunkers-forcefields baneling-exact-lethal-light-clumps roach-burrow-regen-rotation avoid-tank-lurker-splash)
    '(zerg-burrow-micro multitask-harass-and-proxy unit-mode-micro)
    'zvt-hydra-lurker-viper-lategame)

   ;; ZvP
   (bo-tactical-phase-plan
    'zvp-3base-roach-hydra-lurker-siege
    'ZvP
    '3base-roach-hydra-lurker-siege
    350.0 460.0 640.0 15.0
    '((roach . 8) (hydralisk . 6) (lurker . 2))
    '(grooved-spines)
    'enemy-third-base-denial
    '((min-combat-ratio . 0.95) (off-spike-ratio . 1.25) (allow-choke-bypass . #t) (abort-army-supply . 12))
    '(burrow-lurkers-in-zone-range corrosive-bile-forcefields focus-fire-warp-prism-and-immortal avoid-disruptor-storm-clump)
    '(zerg-burrow-micro unit-mode-micro multitask-harass-and-proxy)
    'zvp-corruptor-viper-brood-lord-lategame)))

(define (pro-tactical-phases-for-matchup race [enemy-race 'Unknown])
  (define m-sym
    (if (memq race '(PvZ PvT PvP TvP TvZ TvT ZvZ ZvT ZvP))
        race
        (resolve-matchup-symbol (normalize-ledger-race race) enemy-race)))
  (define matched
    (filter (lambda (p) (eq? (bo-tactical-phase-plan-matchup p) m-sym))
            PRO-BO-TACTICAL-PHASE-PLANS))
  (if (pair? matched) matched PRO-BO-TACTICAL-PHASE-PLANS))

(define (tactical-upg-variants sym)
  (case sym
    [(stimpack stim stim-marine) '(stimpack stim)]
    [(combat-shield combat-shields shield) '(combat-shield combat-shields)]
    [(metabolic-boost zergling-movementspeed) '(metabolic-boost zergling-movementspeed)]
    [(resonating-glaives adept-piercing-attack) '(resonating-glaives adept-piercing-attack)]
    [(extended-thermal-lance colossus-range) '(extended-thermal-lance colossus-range)]
    [(glial-reconstitution roach-speed) '(glial-reconstitution roach-speed)]
    [(grooved-spines hydra-range) '(grooved-spines hydra-range)]
    [(charge zealot-charge) '(charge zealot-charge)]
    [(blink stalker-blink) '(blink stalker-blink)]
    [else (list sym)]))

(define (tactical-upg-present? sym lst)
  (and (list? lst)
       (pair? lst)
       (let ([variants (tactical-upg-variants sym)])
         (ormap (lambda (u) (not (not (memq u lst)))) variants))))

(define (tactical-unit-count unit-counts sym)
  (define ht (if (hash? unit-counts) unit-counts (hasheq)))
  (define syms
    (remove-duplicates
     (append (sc2-unit-equivalent-syms sym)
             (case sym
               [(siege-tank) '(siege-tank siege-tank-sieged)]
               [(warp-prism) '(warp-prism warp-prism-phasing)]
               [(viking-fighter viking) '(viking-fighter viking viking-assault)]
               [(lurker) '(lurker lurker-burrowed lurker-mp lurker-mp-burrowed)]
               [(liberator) '(liberator liberator-ag)]
               [else '()]))
     eq?))
  (for/sum ([s (in-list syms)])
    (safe-nonneg-int (hash-ref ht s 0) 0)))

(define (evaluate-build-order-tactical-plan
         #:race [raw-race 'Zerg]
         #:enemy-race [enemy-race 'Unknown]
         #:frame [raw-frame 0]
         #:supply-used [raw-supply-used 12]
         #:unit-counts [unit-counts (hash)]
         #:researched-upgrades [researched-upgrades '()]
         #:pending-upgrades [pending-upgrades '()]
         #:in-progress-upgrade-progress [upg-progress 0.0]
         #:enemy-unit-counts [enemy-u-counts (hash)]
         #:enemy-building-counts [enemy-b-counts (hash)]
         #:lanchester-ratio [lanchester-ratio 1.0]
         #:under-attack? [under-attack? #f]
         #:base-x [base-x 32.5] #:base-y [base-y 32.5]
         #:nat-x [nat-x 50.5] #:nat-y [nat-y 50.5]
         #:enemy-main-x [enemy-main-x 140.0] #:enemy-main-y [enemy-main-y 140.0]
         #:enemy-nat-x [enemy-nat-x 120.0] #:enemy-nat-y [enemy-nat-y 120.0]
         #:enemy-third-x [enemy-third-x 105.0] #:enemy-third-y [enemy-third-y 125.0]
         #:post-bo-phase? [raw-post-bo-phase? 'auto]
         #:deviated? [raw-deviated? #f]
         #:strategic-goals [raw-strategic-goals #f]
         #:mirror-signals [raw-mirror-signals #f]
         #:world [raw-world #f]
         #:depleting-bases [raw-depleting-bases 0]
         #:natural-blocked? [raw-natural-blocked? #f])
  (define race (normalize-ledger-race raw-race))
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (define frame (safe-nonneg-int raw-frame 0))
  (define elapsed-sec (/ (exact->inexact frame) 22.4))
  (define _supply-used (safe-nonneg-int raw-supply-used 12))
  (define upg-prog
    (if (real? upg-progress) (exact->inexact (max 0.0 (min 1.0 upg-progress))) 0.0))
  (define l-ratio
    (if (real? lanchester-ratio) (exact->inexact (max 0.0 lanchester-ratio)) 1.0))
  (define eff-u (if (hash? unit-counts) unit-counts (hasheq)))
  (define eff-eu (if (hash? enemy-u-counts) enemy-u-counts (hasheq)))
  (define eff-eb (if (hash? enemy-b-counts) enemy-b-counts (hasheq)))
  (define res-upgs (if (list? researched-upgrades) researched-upgrades '()))
  (define pend-upgs (if (list? pending-upgrades) pending-upgrades '()))
  (define bx (exact->inexact (safe-tile-coord base-x 32.5)))
  (define by (exact->inexact (safe-tile-coord base-y 32.5)))
  (define nx (exact->inexact (safe-tile-coord nat-x 50.5)))
  (define ny (exact->inexact (safe-tile-coord nat-y 50.5)))
  (define emx (exact->inexact (safe-tile-coord enemy-main-x 140.0)))
  (define emy (exact->inexact (safe-tile-coord enemy-main-y 140.0)))
  (define enx (exact->inexact (safe-tile-coord enemy-nat-x 120.0)))
  (define eny (exact->inexact (safe-tile-coord enemy-nat-y 120.0)))
  (define e3x (exact->inexact (safe-tile-coord enemy-third-x 105.0)))
  (define e3y (exact->inexact (safe-tile-coord enemy-third-y 125.0)))

  (define phases (pro-tactical-phases-for-matchup race enemy-race))
  (define (phase-units-met? p)
    (for/and ([req (in-list (bo-tactical-phase-plan-trigger-units p))])
      (>= (tactical-unit-count eff-u (car req)) (cdr req))))
  (define (phase-upgs-ready? p)
    (define reqs (bo-tactical-phase-plan-trigger-upgrades p))
    (or (null? reqs)
        (for/and ([u (in-list reqs)])
          (tactical-upg-present? u res-upgs))))
  (define active-phase
    (cond
      [(null? phases) (first PRO-BO-TACTICAL-PHASE-PLANS)]
      [(= (length phases) 1) (first phases)]
      [else
       (define p1 (first phases))
       (define p2 (second phases))
       (define p2-active-signal?
         (or (phase-units-met? p2)
             (and (pair? (bo-tactical-phase-plan-trigger-upgrades p2))
                  (for/or ([u (in-list (bo-tactical-phase-plan-trigger-upgrades p2))])
                    (or (tactical-upg-present? u res-upgs)
                        (tactical-upg-present? u pend-upgs))))
             (> (tactical-unit-count eff-u 'colossus) 0)
             (> (tactical-unit-count eff-u 'disruptor) 0)))
       (cond
         [p2-active-signal? p2]
         [(and (> elapsed-sec (+ (exact->inexact (bo-tactical-phase-plan-window-expire-sec p1)) 60.0))
               (<= elapsed-sec (exact->inexact (bo-tactical-phase-plan-window-expire-sec p2))))
          p2]
         [else p1])]))

  (define phase-id (bo-tactical-phase-plan-phase-id active-phase))
  (define w-start (exact->inexact (bo-tactical-phase-plan-window-start-sec active-phase)))
  (define w-hit (exact->inexact (bo-tactical-phase-plan-window-hit-sec active-phase)))
  (define w-exp (exact->inexact (bo-tactical-phase-plan-window-expire-sec active-phase)))
  (define lead-sec (exact->inexact (bo-tactical-phase-plan-pre-position-lead-sec active-phase)))
  (define req-units (bo-tactical-phase-plan-trigger-units active-phase))
  (define req-upgs (bo-tactical-phase-plan-trigger-upgrades active-phase))
  (define locus (bo-tactical-phase-plan-target-locus active-phase))
  (define rules (bo-tactical-phase-plan-judgment-rules active-phase))
  (define min-ratio (exact->inexact (cdr (or (assq 'min-combat-ratio rules) '(min-combat-ratio . 0.95)))))
  (define off-spike-ratio (exact->inexact (cdr (or (assq 'off-spike-ratio rules) '(off-spike-ratio . 1.25)))))
  (define allow-bypass? (cdr (or (assq 'allow-choke-bypass rules) '(allow-choke-bypass . #t))))

  (define units-met? (phase-units-met? active-phase))
  (define upgs-ready? (phase-upgs-ready? active-phase))
  (define pending-req-upg?
    (and (pair? req-upgs)
         (not upgs-ready?)
         (for/or ([u (in-list req-upgs)])
           (tactical-upg-present? u pend-upgs))))
  (define missing-unit-syms
    (for/list ([req (in-list req-units)]
               #:when (< (tactical-unit-count eff-u (car req)) (cdr req)))
      (car req)))
  (define reinforce-syms
    (if (pair? missing-unit-syms) missing-unit-syms (map car req-units)))

  (define total-combat-cnt
    (for/sum ([(sym raw-c) (in-hash eff-u)]
              #:when (not (memq sym '(drone scv probe larva egg overlord overseer queen))))
      (safe-nonneg-int raw-c 0)))

  (define (e-max s)
    (max (safe-nonneg-int (hash-ref eff-eu s 0) 0)
         (safe-nonneg-int (hash-ref eff-eb s 0) 0)))
  (define e-sieged-tanks (e-max 'siege-tank-sieged))
  (define e-burrowed-lurkers (+ (e-max 'lurker-burrowed) (e-max 'lurker-mp-burrowed)))
  (define e-choke-defenses (+ (e-max 'shield-battery) (e-max 'bunker) (e-max 'spine-crawler)))
  (define enemy-choke-fortified?
    (or (>= e-sieged-tanks 2)
        (>= e-burrowed-lurkers 2)
        (>= e-choke-defenses 2)))
  (define enemy-workers-explicit?
    (or (hash-has-key? eff-eu 'scv)
        (hash-has-key? eff-eu 'probe)
        (hash-has-key? eff-eu 'drone)))
  (define enemy-worker-cnt
    (+ (safe-nonneg-int (hash-ref eff-eu 'scv 0) 0)
       (safe-nonneg-int (hash-ref eff-eu 'probe 0) 0)
       (safe-nonneg-int (hash-ref eff-eu 'drone 0) 0)))
  (define mineral-line-locked-down?
    (>= (+ (e-max 'missile-turret) (e-max 'spore-crawler) (e-max 'photon-cannon)) 3))
  (define vulnerable-worker-lines?
    (and (not mineral-line-locked-down?)
         (or (not enemy-workers-explicit?) (> enemy-worker-cnt 0))))

  (define-values (commit-px commit-py commit-sx commit-sy)
    (case locus
      [(dual-main-and-natural-mineral-fork main-drop-and-natural-front-pincer)
       (values enx eny emx emy)]
      [(enemy-third-base-denial)
       (values e3x e3y enx eny)]
      [else
       (values enx eny e3x e3y)]))

  (define pre-pos-time?
    (and (> frame 0)
         (>= elapsed-sec (- w-hit lead-sec))
         (< elapsed-sec w-hit)))
  (define expired?
    (and (> frame 0) (> elapsed-sec w-exp)))
  (define severe-home-attack?
    (and under-attack? (< l-ratio 0.80)))
  (define army-depleted?
    (and (> frame 0)
         (>= elapsed-sec w-start)
         (not units-met?)
         (<= total-combat-cnt 1)
         (< l-ratio 0.70)))
  (define off-spike-commit?
    (and units-met?
         (not upgs-ready?)
         (not pending-req-upg?)
         (not expired?)
         (not severe-home-attack?)
         (or (= frame 0) (>= elapsed-sec w-hit))
         (>= l-ratio off-spike-ratio)))
  (define spike-ready?
    (and units-met? upgs-ready? (not expired?)))

  (define-values (disposition px py sx sy verdict reason)
    (cond
      [(or severe-home-attack? expired? army-depleted?)
       (values 'abort-timing-and-pivot-macro
               bx by nx ny
               'abort-and-pivot
               (cond
                 [severe-home-attack? 'severe-home-attack-abort]
                 [expired? 'timing-window-expired]
                 [else 'army-depleted-pivot]))]
      [(and units-met?
            (not upgs-ready?)
            (or (and pending-req-upg? (>= upg-prog 0.80))
                pre-pos-time?))
       (values 'pre-position-march-out
               commit-px commit-py commit-sx commit-sy
               'march-to-timing-staging
               (if (and pending-req-upg? (>= upg-prog 0.80))
                   'upgrade-near-completion-pre-position
                   'pre-position-before-window-hit))]
      [(and spike-ready?
            allow-bypass?
            enemy-choke-fortified?
            vulnerable-worker-lines?)
       (values 'execute-timing-bypass-harass-fork
               enx eny emx emy
               'bypass-fortified-choke-harass-fork
               'choke-fortified-target-worker-lines)]
      [(and spike-ready?
            (eq? locus 'enemy-third-base-denial)
            (or enemy-choke-fortified? (< l-ratio min-ratio))
            (>= l-ratio 0.80))
       (values 'contain-and-deny-third
               e3x e3y enx eny
               'contain-and-deny-third
               (if enemy-choke-fortified?
                   'contain-fortified-nat-deny-third
                   'deny-third-and-macro-behind))]
      [(or (and spike-ready?
                (>= l-ratio min-ratio)
                (or (not enemy-choke-fortified?) (>= l-ratio 1.45)))
           (and off-spike-commit?
                (or (not enemy-choke-fortified?) (>= l-ratio 1.45))))
       (values 'execute-timing-attack-commit
               commit-px commit-py commit-sx commit-sy
               'commit-timing-attack
               (if spike-ready? 'timing-spike-units-and-upgrades-ready 'off-spike-lanchester-advantage))]
      [(and units-met?
            (or enemy-choke-fortified?
                (and upgs-ready? (>= l-ratio 0.80))))
       (values 'contain-and-deny-third
               e3x e3y enx eny
               'contain-and-deny-third
               (if enemy-choke-fortified?
                   'choke-fortified-contain-outside
                   'borderline-ratio-contain-and-macro))]
      [else
       (values 'accumulate-for-timing
               nx ny bx by
               'accumulate-and-prepare
               (if (pair? missing-unit-syms)
                   'accumulating-trigger-units
                   'waiting-on-trigger-upgrades))]))

  (define base-plan
    (bo-active-tactical-plan
     m-sym
     phase-id
     disposition
     locus
     px py
     sx sy
     verdict
     reason
     (bo-tactical-phase-plan-micro-directives active-phase)
     (bo-tactical-phase-plan-active-tactics active-phase)
     reinforce-syms
     (bo-tactical-phase-plan-post-window-transition active-phase)))
  (define dynamic-post-bo?
    (or (eq? raw-post-bo-phase? #t)
        (eq? raw-deviated? #t)
        (hash? raw-strategic-goals)
        (hash? raw-mirror-signals)
        (and raw-world #t)
        (and (eq? raw-post-bo-phase? 'auto)
             (or (>= _supply-used 130)
                 (and (> frame 0) (> elapsed-sec (+ w-exp 120.0)))))))
  (define sg
    (cond
      [(hash? raw-strategic-goals) raw-strategic-goals]
      [else
       (define base-w
         (if raw-world
             (coerce-world->ledger-hash raw-world)
             (hasheq)))
       (define w-merged
         (hash-set* base-w
                    'race race
                    'enemy-race enemy-race
                    'frame frame
                    'supply-used _supply-used
                    'effective-phase-supply (max _supply-used (if (or (eq? raw-post-bo-phase? #t) dynamic-post-bo?) 75 _supply-used))
                    'unit-counts eff-u
                    'researched-upgrades res-upgs
                    'pending-upgrades pend-upgs
                    'enemy-unit-counts eff-eu
                    'enemy-building-counts eff-eb
                    'lanchester-ratio l-ratio
                    'under-attack? under-attack?
                    'depleting-bases raw-depleting-bases
                    'natural-blocked? raw-natural-blocked?
                    'base-x bx 'base-y by
                    'nat-x nx 'nat-y ny
                    'enemy-main-x emx 'enemy-main-y emy
                    'enemy-nat-x enx 'enemy-nat-y eny
                    'enemy-third-x e3x 'enemy-third-y e3y))
       (evaluate-post-bo-strategic-goals w-merged #f raw-mirror-signals)]))
  (define sg-phase (hash-ref sg 'tactical-phase 'accumulate-for-upgrade-spike))
  (define sg-tloc (hash-ref sg 'target-location (hasheq 'x px 'y py 'locus locus)))
  (define sg-micro (hash-ref sg 'micro-profile (if (pair? (bo-tactical-phase-plan-micro-directives active-phase))
                                                   (car (bo-tactical-phase-plan-micro-directives active-phase))
                                                   'standard-micro)))
  (define sg-abort (hash-ref sg 'abort-condition 'abort-if-lanchester-below-0.80))
  (define final-plan
    (if (and dynamic-post-bo? (not (eq? raw-post-bo-phase? #f)))
        (let ([dyn-px (safe-tile-coord (hash-ref sg-tloc 'x px) px)]
              [dyn-py (safe-tile-coord (hash-ref sg-tloc 'y py) py)]
              [dyn-sx (safe-tile-coord (hash-ref sg-tloc 'secondary-x sx) sx)]
              [dyn-sy (safe-tile-coord (hash-ref sg-tloc 'secondary-y sy) sy)]
              [dyn-locus (hash-ref sg-tloc 'locus locus)])
          (bo-active-tactical-plan
           m-sym
           sg-phase
           sg-phase
           dyn-locus
           dyn-px dyn-py
           dyn-sx dyn-sy
           sg-phase
           'post-bo-4pillar-strategic-goal
           (list sg-micro sg-abort)
           (bo-tactical-phase-plan-active-tactics active-phase)
           reinforce-syms
           (bo-tactical-phase-plan-post-window-transition active-phase)))
        base-plan))
  (define final-tloc
    (hasheq 'x (bo-active-tactical-plan-primary-target-x final-plan)
            'y (bo-active-tactical-plan-primary-target-y final-plan)
            'secondary-x (bo-active-tactical-plan-secondary-fork-x final-plan)
            'secondary-y (bo-active-tactical-plan-secondary-fork-y final-plan)
            'locus (bo-active-tactical-plan-target-locus final-plan)))
  (tactical-plan-store-extras! final-plan final-tloc sg-micro sg-abort sg))

;; =============================================================================
;; Slice 1.5A: Opportunity-Cost Resource Envelope & Loss-Recovery Evaluators
;; =============================================================================

(define *econ-opp-norm-cache* (make-hash))

(define (econ-string->kebab s)
  (define len (string-length s))
  (define out (open-output-string))
  (let loop ([i 0] [prev-ch #f] [prev-dash? #t])
    (if (< i len)
        (let ([ch (string-ref s i)])
          (cond
            [(or (char=? ch #\_) (char=? ch #\space) (char=? ch #\-))
             (unless prev-dash? (write-char #\- out))
             (loop (+ i 1) ch #t)]
            [(and (char-upper-case? ch)
                  prev-ch
                  (not prev-dash?)
                  (or (char-lower-case? prev-ch) (char-numeric? prev-ch)))
             (write-char #\- out)
             (write-char (char-downcase ch) out)
             (loop (+ i 1) ch #f)]
            [else
             (write-char (char-downcase ch) out)
             (loop (+ i 1) ch #f)]))
        (get-output-string out))))

(define (econ-normalize-opp-sym raw)
  (cond
    [(or (symbol? raw) (string? raw))
     (define key (if (symbol? raw) (symbol->string raw) raw))
     (or (hash-ref *econ-opp-norm-cache* key #f)
         (let* ([kebab (string->symbol (econ-string->kebab key))]
                [canon (canonical-unit-type-sym kebab)]
                [final (case canon
                         [(viking-fighter vikingfighter) 'viking]
                         [(siegetank) 'siege-tank]
                         [(siegetanksieged) 'siege-tank-sieged]
                         [(voidray) 'void-ray]
                         [(broodlord) 'brood-lord]
                         [(hightemplar) 'high-templar]
                         [(darktemplar) 'dark-templar]
                         [(fusioncore) 'fusion-core]
                         [(fleetbeacon) 'fleet-beacon]
                         [(greaterspire) 'greater-spire]
                         [(missileturret) 'missile-turret]
                         [(sporecrawler) 'spore-crawler]
                         [(spinecrawler) 'spine-crawler]
                         [(photoncannon) 'photon-cannon]
                         [(shieldbattery) 'shield-battery]
                         [else canon])])
           (hash-set! *econ-opp-norm-cache* key final)
           final))]
    [else 'unknown]))

(define (econ-extract-sym-counts seq)
  (define ht (make-hasheq))
  (define (add-item! item)
    (cond
      [(or (symbol? item) (string? item))
       (define s (econ-normalize-opp-sym item))
       (unless (eq? s 'unknown)
         (hash-set! ht s (+ 1 (hash-ref ht s 0))))]
      [(hash? item)
       (define raw-t (or (hash-ref item 'type #f)
                         (hash-ref item 'unit_type #f)
                         (hash-ref item 'unit-type #f)
                         (hash-ref item 'name #f)
                         (hash-ref item 'unit-name #f)))
       (when raw-t
         (define s (econ-normalize-opp-sym raw-t))
         (define cnt (inexact->exact (floor (max 0 (or (hash-ref item 'count #f)
                                                       (hash-ref item 'qty #f)
                                                       1)))))
         (when (and (not (eq? s 'unknown)) (> cnt 0))
           (hash-set! ht s (+ cnt (hash-ref ht s 0)))))]
      [(pair? item)
       (define s (econ-normalize-opp-sym (car item)))
       (define c-raw (if (list? (cdr item)) (cadr item) (cdr item)))
       (define cnt (if (real? c-raw) (inexact->exact (floor (max 0 c-raw))) 1))
       (when (and (not (eq? s 'unknown)) (> cnt 0))
         (hash-set! ht s (+ cnt (hash-ref ht s 0))))]))
  (cond
    [(list? seq) (for-each add-item! seq)]
    [(vector? seq) (for ([x (in-vector seq)]) (add-item! x))]
    [(hash? seq)
     (if (or (hash-has-key? seq 'type)
             (hash-has-key? seq 'unit_type)
             (hash-has-key? seq 'unit-type)
             (hash-has-key? seq 'name))
         (add-item! seq)
         (for ([(k v) (in-hash seq)])
           (when (real? v)
             (define s (econ-normalize-opp-sym k))
             (define cnt (inexact->exact (floor (max 0 v))))
             (when (and (not (eq? s 'unknown)) (> cnt 0))
               (hash-set! ht s (+ cnt (hash-ref ht s 0)))))))])
  ht)

(define *opp-path-unit-table*
  (hasheq
   ;; 'capital-air-fleet (only true capital/heavy air & T3 air anchors; bare Starport/Stargate/Spire added conditionally below)
   'fusion-core     'capital-air-fleet
   'fleet-beacon    'capital-air-fleet
   'greater-spire   'capital-air-fleet
   'battlecruiser   'capital-air-fleet
   'carrier         'capital-air-fleet
   'tempest         'capital-air-fleet
   'void-ray        'capital-air-fleet
   'brood-lord      'capital-air-fleet
   'mothership      'capital-air-fleet
   ;; 'armored-ground-siege
   'siege-tank      'armored-ground-siege
   'siege-tank-sieged 'armored-ground-siege
   'thor            'armored-ground-siege
   'thor-ap         'armored-ground-siege
   'immortal        'armored-ground-siege
   'colossus        'armored-ground-siege
   'disruptor       'armored-ground-siege
   'stalker         'armored-ground-siege
   'lurker          'armored-ground-siege
   'lurker-burrowed 'armored-ground-siege
   'ultralisk       'armored-ground-siege
   'roach           'armored-ground-siege
   'ravager         'armored-ground-siege
   'marauder        'armored-ground-siege
   ;; 'light-bio-swarm
   'zergling        'light-bio-swarm
   'baneling        'light-bio-swarm
   'marine          'light-bio-swarm
   'reaper          'light-bio-swarm
   'hellion         'light-bio-swarm
   'zealot          'light-bio-swarm
   'adept           'light-bio-swarm
   'mutalisk        'light-bio-swarm
   'hydralisk       'light-bio-swarm
   ;; 'psionic-caster-swarm
   'infestor        'psionic-caster-swarm
   'viper           'psionic-caster-swarm
   'queen           'psionic-caster-swarm
   'high-templar    'psionic-caster-swarm
   'archon          'psionic-caster-swarm
   'ghost           'psionic-caster-swarm
   'raven           'psionic-caster-swarm
   'sentry          'psionic-caster-swarm
   'oracle          'psionic-caster-swarm))

(define *opp-path-t3-anchor-syms*
  '(fusion-core fleet-beacon greater-spire battlecruiser carrier tempest mothership brood-lord))

(define *opp-all-paths*
  '(capital-air-fleet armored-ground-siege light-bio-swarm psionic-caster-swarm))

(define (opp-path-counter-list path)
  (case path
    [(capital-air-fleet)
     (values '(spire corruptor queen spore-crawler viper zerg-flyer-carapace-1
               starport viking raven thor cyclone missile-turret
               stargate void-ray tempest stalker high-templar archon shield-battery photon-cannon)
             '(roach ravager zergling baneling lurker ultralisk
               marauder siege-tank hellion
               zealot colossus disruptor immortal adept))]
    [(armored-ground-siege)
     (values '(ravager zergling viper brood-lord spire mutalisk hydralisk
               marauder starport liberator banshee siege-tank battlecruiser
               robotics-facility immortal stargate void-ray tempest disruptor zealot)
             '(hellion reaper))]
    [(light-bio-swarm)
     (values '(baneling lurker ultralisk infestor
               hellbat siege-tank widow-mine ghost
               colossus high-templar disruptor archon adept)
             '(tempest void-ray))]
    [(psionic-caster-swarm)
     (values '(zergling ultralisk hydralisk lurker
               ghost marauder viking liberator
               disruptor zealot phoenix dark-templar)
             '(corruptor tempest))]
    [else (values '() '())]))

(define (evaluate-opponent-opportunity-cost-commitment enemy-units enemy-bldgs
                                                       [frame 0]
                                                       [enemy-bases 1]
                                                       [enemy-gas-count 0])
  (define unit-counts (econ-extract-sym-counts enemy-units))
  (define bldg-counts (econ-extract-sym-counts enemy-bldgs))
  (define path-mins (make-hasheq))
  (define path-gas (make-hasheq))
  (define path-bonus (make-hasheq))
  (define total-minerals 0.0)
  (define total-gas 0.0)
  (define cap-air-t3-present?
    (or (for/or ([sym (in-list *opp-path-t3-anchor-syms*)])
          (> (+ (hash-ref unit-counts sym 0) (hash-ref bldg-counts sym 0)) 0))
        #f))
  (define cap-air-real-commitment?
    (or cap-air-t3-present?
        (>= (hash-ref unit-counts 'void-ray 0) 2)))
  (define (sym-cost s)
    (define m0 (sc2-min-cost s))
    (define g0 (sc2-gas-cost s))
    (values (if (>= m0 0) (exact->inexact m0) 100.0)
            (if (>= g0 0) (exact->inexact g0) 0.0)))
  (define (accumulate-counts! ht bldg?)
    (for ([(sym cnt) (in-hash ht)])
      (unless (memq sym '(scv drone probe larva egg mule))
        (define-values (m g) (sym-cost sym))
        (define add-m (* cnt m))
        (define add-g (* cnt g))
        ;; Ignore starter townhalls/supply filler for raw offensive commitment unless counted in specific path,
        ;; though gas & tech buildings still tally cleanly
        (unless (and bldg? (memq sym '(command-center orbital-command nexus hatchery lair hive
                                       supply-depot pylon overlord assimilator extractor refinery)))
          (set! total-minerals (+ total-minerals add-m))
          (set! total-gas (+ total-gas add-g)))
        (define p
          (or (hash-ref *opp-path-unit-table* sym #f)
              (and cap-air-real-commitment?
                   (memq sym '(starport stargate spire))
                   'capital-air-fleet)))
        (when p
          (hash-set! path-mins p (+ add-m (hash-ref path-mins p 0.0)))
          (hash-set! path-gas p (+ add-g (hash-ref path-gas p 0.0)))
          (when (memq sym '(fusion-core fleet-beacon greater-spire))
            (hash-set! path-bonus p (+ (* cnt 300.0) (hash-ref path-bonus p 0.0))))
          (when (memq sym *opp-path-t3-anchor-syms*)
            (set! cap-air-t3-present? #t))))))
  (accumulate-counts! unit-counts #f)
  (accumulate-counts! bldg-counts #t)
  ;; Pick dominant path by resource weight (minerals + 2.5*gas + T3 anchor bonus)
  (define best-path 'none)
  (define best-weight 0.0)
  (define total-path-weight 0.0)
  (for ([p (in-list *opp-all-paths*)])
    (define pm (hash-ref path-mins p 0.0))
    (define pg (hash-ref path-gas p 0.0))
    (define pb (hash-ref path-bonus p 0.0))
    (define w (+ pm (* 2.5 pg) pb))
    (set! total-path-weight (+ total-path-weight w))
    (when (> w best-weight)
      (set! best-weight w)
      (set! best-path p)))
  ;; Opportunity-cost resource envelope at `frame`
  (define f-num (if (real? frame) (exact->inexact (max 0 frame)) 0.0))
  (define bases-num (if (real? enemy-bases) (exact->inexact (max 1 enemy-bases)) 1.0))
  (define gas-cnt (if (real? enemy-gas-count) (exact->inexact (max 0 enemy-gas-count)) 0.0))
  (define max-possible-minerals
    (if (> f-num 0.0)
        (let* ([t-sec (/ f-num 22.4)]
               [eff-bases (+ 1.0 (* 0.65 (max 0.0 (- bases-num 1.0))))]
               [est (+ 50.0 (* t-sec 14.0 eff-bases))])
          (max total-minerals est))
        (max total-minerals (* 1500.0 bases-num))))
  (define max-possible-gas
    (if (> f-num 0.0)
        (let* ([t-sec (/ f-num 22.4)]
               [gas-sec (max 15.0 (- t-sec 45.0))]
               [eff-geysers (max (if (> total-gas 0.0) 1.0 0.0)
                                 gas-cnt
                                 (* 1.0 (min bases-num 2.0)))]
               [est (* gas-sec 2.3 eff-geysers)])
          (max total-gas est 100.0))
        (max total-gas (* 450.0 (max 1.0 gas-cnt bases-num)))))
  (define dom-min (hash-ref path-mins best-path 0.0))
  (define dom-gas (hash-ref path-gas best-path 0.0))
  (define gas-commitment-ratio
    (if (> max-possible-gas 0.0)
        (min 1.0 (max 0.0 (/ total-gas max-possible-gas)))
        0.0))
  (define dom-share
    (if (> total-path-weight 0.0)
        (/ best-weight total-path-weight)
        0.0))
  (define dom-env-ratio
    (min 1.0 (/ (+ dom-min (* 2.2 dom-gas) (if cap-air-t3-present? 400.0 0.0))
                (max 1.0 (* 0.55 (+ max-possible-minerals (* 2.2 max-possible-gas)))))))
  (define gas-gate-boost (min 1.0 (/ dom-gas 900.0)))
  (define raw-commit-score
    (if (= total-path-weight 0.0)
        0.0
        (min 1.0
             (* dom-share
                (max dom-env-ratio
                     gas-gate-boost
                     (if cap-air-real-commitment? 0.65 0.0))))))
  ;; Only assert `hard-override-build-order?` on genuine capital-air commitments or massive single-path investments,
  ;; NEVER on standard midgame 350G spending (`#5131026`, `#5131251`, `#5130502`, `#5130656`)!
  (define hard-override?
    (and (not (eq? best-path 'none))
         (or (and (eq? best-path 'capital-air-fleet) cap-air-real-commitment?)
             (and (not (eq? best-path 'capital-air-fleet))
                  (>= raw-commit-score 0.72)
                  (>= (+ dom-min (* 2.0 dom-gas)) 1400.0)))))
  (define closed-paths
    (if hard-override?
        (for/fold ([ht (hasheq)]) ([p (in-list *opp-all-paths*)])
          (if (eq? p best-path)
              ht
              (hash-set ht p 'closed-by-opportunity-cost)))
        (hasheq)))
  (define-values (rec-counters supp-units)
    (if hard-override?
        (opp-path-counter-list best-path)
        (values '() '())))
  (hasheq 'dominant-path best-path
          'commitment-score raw-commit-score
          'gas-commitment-ratio gas-commitment-ratio
          'max-possible-minerals max-possible-minerals
          'max-possible-gas max-possible-gas
          'committed-minerals total-minerals
          'committed-gas total-gas
          'closed-paths closed-paths
          'recommended-counter-units rec-counters
          'suppressed-non-counter-units supp-units
          'hard-override-build-order? hard-override?))

(define (evaluate-loss-recovery-macro-mode metrics-ht)
  (define (mref k default)
    (define v (if (hash? metrics-ht) (hash-ref metrics-ht k default) default))
    (if (real? v) v default))
  (define workers (mref 'workers 0))
  (define peak-workers (max workers (mref 'peak-workers 0)))
  (define active-bases (max 0 (mref 'active-bases 1)))
  (define peak-bases (max active-bases (mref 'peak-bases 0)))
  (define supply-used (mref 'supply-used 0))
  (define peak-supply (max supply-used (mref 'peak-supply-reached 0)))
  (define army-supply (mref 'army-supply 0))
  (define enemy-threat-supply (mref 'enemy-threat-supply 0))
  (define frame (mref 'frame 0))
  ;; Separate sharp loss events from steady-state macro deficits so under-saturated macro
  ;; never masks an acute army wipe, and healthy 3+ base / 48+ worker economies don't stay locked
  ;; in permanent recovery/upgrade-deferral after losing 1 outer base (#5131238, #5130439)!
  (define direct-worker-loss?
    (and (> peak-workers 0)
         (<= workers (- peak-workers (if (>= workers 44) 10 5)))
         (< workers 56)))
  (define chronic-worker-deficit?
    (and (>= frame 3500)
         (< workers (if (>= frame 5500)
                        (max 16 (min 66 (* active-bases 16)))
                        16))))
  (define direct-base-loss?
    (and (> peak-bases 0)
         (< active-bases peak-bases)
         (or (< active-bases 3) (< workers 48))))
  (define chronic-base-deficit?
    (and (>= frame 6000)
         (or (< active-bases 2)
             (and (< active-bases 5) (>= workers (* active-bases 22))))))
  (define army-wipe?
    (or (and (> peak-supply 0) (<= supply-used (- peak-supply 16)))
        (and (>= frame 4000)
             (> enemy-threat-supply 0)
             (< army-supply (* 0.60 enemy-threat-supply)))))
  (define mode
    (cond
      [direct-worker-loss? 'worker-loss-recovery]
      [direct-base-loss? 'base-loss-recovery]
      [army-wipe? 'army-wipe-counter-pivot-recovery]
      [chronic-worker-deficit? 'worker-loss-recovery]
      [chronic-base-deficit? 'base-loss-recovery]
      [else 'none]))
  (define boost-workers? (or direct-worker-loss? chronic-worker-deficit?))
  (define boost-expand? (or direct-base-loss? chronic-base-deficit?))
  (define suppress-failing-comp? (or army-wipe? (eq? mode 'army-wipe-counter-pivot-recovery)))
  (define unlock-locked-path? suppress-failing-comp?)
  (define boost-static-defense?
    (or direct-worker-loss? direct-base-loss? army-wipe?))
  (define preempt-greedy-tech?
    (and (or boost-workers? direct-base-loss? suppress-failing-comp?)
         (or (< workers 36) (< active-bases 2) (< army-supply 16))))
  (hasheq 'mode mode
          'unlock-locked-path? unlock-locked-path?
          'preempt-greedy-tech? preempt-greedy-tech?
          'boost-workers? boost-workers?
          'boost-expand? boost-expand?
          'boost-static-defense? boost-static-defense?
          'suppress-failing-comp? suppress-failing-comp?))

;; =============================================================================
;; Bug 3 / Bug 4 / Bug 5 Shared Policy Helpers
;; =============================================================================

(provide MAX-ESCROW-AGE-FRAMES
         ESCROW-EXPIRATION-BACKOFF-FRAMES
         compute-supply-preemption-margin
         supply-preemption-needed?
         can-fund-within-frames?
         canonicalize-macro-upg-sym
         upgrade-allowed-by-unit-and-order-gates?
         natural-expansion-window-active?)

(define MAX-ESCROW-AGE-FRAMES 221)
(define ESCROW-EXPIRATION-BACKOFF-FRAMES 112)

;; Exact cap-scaled supply preemption margin when supply-cap < 200:
;; 2 at <25 cap, 4 at 25-60, 6 at 60-110, 8 at 110+.
(define (compute-supply-preemption-margin food-cap)
  (define cap (if (number? food-cap) (inexact->exact (floor food-cap)) 0))
  (cond
    [(>= cap 200) 0]
    [(< cap 25) 2]
    [(< cap 60) 4]
    [(< cap 110) 6]
    [else 8]))

;; Return #t when food-used >= food-cap - margin (for food-cap < 200)
;; and pending supply (+8 cap each) is insufficient to cover margin or hit 200.
;; For Terran at starting cap=15 (0 Depots built), trigger Depot #1 at used >= 13
;; to eliminate the 18s 15/15 opening supply block on long-ramp maps.
(define (supply-preemption-needed? food-used food-cap pending-supply #:race [race #f])
  (define used (if (number? food-used) (inexact->exact (ceiling food-used)) 0))
  (define cap (if (number? food-cap) (inexact->exact (floor food-cap)) 0))
  (define pend (if (number? pending-supply) (max 0 (inexact->exact (floor pending-supply))) 0))
  (define margin (compute-supply-preemption-margin cap))
  (define proj-cap (+ cap (* 8 pend)))
  (and (< cap 200)
       (cond
         [(<= cap 14) (>= used cap)]
         [(= cap 15)  (>= used (if (eq? race 'Terran) 13 14))]
         [else        (>= used (- cap margin))])
       (or (= pend 0)
           (and (< proj-cap 200)
                (<= (- proj-cap used) margin)))))

(define (ledger-map-count ht sym)
  (if (hash? ht) (max 0 (safe-nonneg-int (hash-ref ht sym 0) 0)) 0))

;; Plausible ~90-frame resource income affordability gate for escrow creation.
(define (can-fund-within-frames? minerals gas min-cost gas-cost
                                  mineral-harvesters gas-harvesters
                                  workers ready-bldgs race
                                  #:frames [frames 90])
  (define m (max 0.0 (exact->inexact minerals)))
  (define g (max 0.0 (exact->inexact gas)))
  (define mc (max 0.0 (exact->inexact min-cost)))
  (define gc (max 0.0 (exact->inexact gas-cost)))
  (cond
    [(and (>= m mc) (>= g gc)) #t]
    [else
     (define w (max 0 (safe-nonneg-int workers 0)))
     (define gas-bldg-cnt
       (+ (ledger-map-count ready-bldgs 'extractor)
          (ledger-map-count ready-bldgs 'assimilator)
          (ledger-map-count ready-bldgs 'refinery)))
     (define est-g-harv
       (if (exact-integer? gas-harvesters)
           (max 0 gas-harvesters)
           (min (* 3 gas-bldg-cnt) (quotient (max 0 (- w 6)) 3))))
     (define est-m-harv
       (if (exact-integer? mineral-harvesters)
           (max 0 mineral-harvesters)
           (max 0 (- w est-g-harv))))
     ;; ~0.045 min/frame/harvester (~60 min/min peak), ~0.040 gas/frame/harvester
     ;; plus modest MULE contribution when Terran has a ready Orbital Command.
     (define oc-cnt
       (if (eq? race 'Terran) (ledger-map-count ready-bldgs 'orbital-command) 0))
     (define min-rate (+ (* (exact->inexact est-m-harv) 0.045)
                         (if (> oc-cnt 0) (* (min 2 oc-cnt) 0.14) 0.0)))
     (define gas-rate (* (exact->inexact est-g-harv) 0.056))
     (define horizon (max 1.0 (exact->inexact frames)))
     (and (>= (+ m (* horizon min-rate)) mc)
          (>= (+ g (* horizon gas-rate)) gc))]))

;; Canonicalize all upgrade symbol spellings across SC2 API, BOs, and planner DB.
(define (canonicalize-macro-upg-sym sym)
  (case sym
    [(shield-wall shieldwall combat-shields terran-infantry-armors-shield) 'combat-shield]
    [(centrifugal-hooks) 'centrifical-hooks]
    [(punisher-grenades) 'concussive-shells]
    [(high-capacity-barrels infernal-preigniter) 'infernal-pre-igniter]
    [(drill-claws) 'drilling-claws]
    [(banshee-cloaking-field cloaking-field) 'banshee-cloak]
    [(cyclone-lock-on-damage-upgrade mag-field-accelerator cyclone-lock-on)
     'cyclone-lock-on-damage]
    [(blink-tech) 'blink]
    [(adept-piercing-attack) 'resonating-glaives]
    [(observer-gravitic-booster gravitic-boosters) 'gravitic-booster]
    [(protoss-air-weapons-level-1 protoss-air-weapons-level1 air-weapons-1)
     'protoss-air-weapons-1]
    [(protoss-air-weapons-level-2 protoss-air-weapons-level2 air-weapons-2)
     'protoss-air-weapons-2]
    [(protoss-air-weapons-level-3 protoss-air-weapons-level3 air-weapons-3)
     'protoss-air-weapons-3]
    [(protoss-air-armor-level-1 protoss-air-armor-level1 protoss-air-armors-1 air-armor-1)
     'protoss-air-armor-1]
    [(protoss-air-armor-level-2 protoss-air-armor-level2 protoss-air-armors-2 air-armor-2)
     'protoss-air-armor-2]
    [(protoss-air-armor-level-3 protoss-air-armor-level3 protoss-air-armors-3 air-armor-3)
     'protoss-air-armor-3]
    [(ground-weapons-1 protoss-ground-weapons-level-1) 'protoss-ground-weapons-1]
    [(ground-weapons-2 protoss-ground-weapons-level-2) 'protoss-ground-weapons-2]
    [(ground-weapons-3 protoss-ground-weapons-level-3) 'protoss-ground-weapons-3]
    [(ground-armor-1 protoss-ground-armor-level-1 protoss-ground-armors-1)
     'protoss-ground-armor-1]
    [(ground-armor-2 protoss-ground-armor-level-2 protoss-ground-armors-2)
     'protoss-ground-armor-2]
    [(ground-armor-3 protoss-ground-armor-level-3 protoss-ground-armors-3)
     'protoss-ground-armor-3]
    [(zerg-ling-metabolic-boost zergling-movementspeed) 'metabolic-boost]
    [(zerg-ling-attack-speed zergling-attackspeed) 'adrenal-glands]
    [else sym]))

(define (upg-list-contains? upg-list target-sym)
  (define target-canon (canonicalize-macro-upg-sym target-sym))
  (and (list? upg-list)
       (ormap (lambda (u) (eq? (canonicalize-macro-upg-sym u) target-canon))
              upg-list)))

;; Strict Bug 5 unit-count & ordering gates across all 3 races.
(define (upgrade-allowed-by-unit-and-order-gates?
         race upg-sym frame workers ready-bldgs total-bldgs unit-counts
         researched-upgs [pending-upgs '()])
  (define canon (canonicalize-macro-upg-sym upg-sym))
  (define (uc . syms)
    (for/sum ([s (in-list syms)]) (ledger-map-count unit-counts s)))
  (define (bc . syms)
    (for/sum ([s (in-list syms)])
      (max (ledger-map-count ready-bldgs s) (ledger-map-count total-bldgs s))))
  (define (done? u) (upg-list-contains? researched-upgs u))
  (define (started-or-done? u) (or (done? u) (upg-list-contains? pending-upgs u)))
  (case race
    [(Protoss)
     (define air-ships (uc 'void-ray 'carrier 'tempest 'phoenix 'oracle))
     (define zealots (uc 'zealot 'zealot-warp))
     (define stalkers (uc 'stalker 'stalker-warp))
     (define adepts (uc 'adept 'adept-warp))
     (define warp-prisms (uc 'warp-prism 'warp-prism-phasing))
     (define observers (uc 'observer 'observer-siege 'observer-siege-mode))
     (define gateways (bc 'gateway 'warp-gate))
     (define ground-army
       (+ zealots stalkers adepts
          (uc 'sentry 'sentry-warp 'immortal 'colossus 'disruptor 'high-templar 'dark-templar 'archon)))
     (case canon
       [(protoss-air-weapons-1 protoss-air-armor-1
         protoss-air-weapons-2 protoss-air-armor-2
         protoss-air-weapons-3 protoss-air-armor-3)
        (>= air-ships 2)]
       [(charge)
        (or (>= zealots 3) (and (>= gateways 3) (>= ground-army 3)))]
       [(blink) (>= stalkers 3)]
       [(resonating-glaives) (>= adepts 3)]
       [(gravitic-drive) (>= warp-prisms 1)]
       [(gravitic-booster) (>= observers 1)]
       [else #t])]
    [(Terran)
     (define marines (uc 'marine))
     (define marauders (uc 'marauder))
     (define hellions (+ (uc 'hellion) (uc 'hellion-tank) (uc 'hellbat)))
     (define widow-mines (uc 'widow-mine 'widow-mine-burrowed))
     (define cyclones (uc 'cyclone))
     (define banshees (uc 'banshee))
     (define rax-techlabs (bc 'barracks-techlab))
     (define factories (bc 'factory 'factory-flying))
     (define barracks (bc 'barracks 'barracks-flying))
     (define orbitals (bc 'orbital-command 'orbital-command-flying))
     (define marauder-opening? (and (>= marauders 2) (< marines 2)))
     (case canon
       [(terran-infantry-weapons-1 terran-infantry-armor-1 infantry-weapons-1 infantry-armor-1)
        (or (>= factories 1) (>= barracks 2))]
       [(stimpack)
        (or (>= factories 1)
            (>= barracks 2)
            (and (>= rax-techlabs 1) (>= orbitals 2)))]
       [(combat-shield)
        (or (done? 'stimpack)
            (and (started-or-done? 'stimpack) (>= rax-techlabs 2)))]
       [(concussive-shells)
        (or marauder-opening?
            (and (done? 'stimpack)
                 (or (done? 'combat-shield)
                     (and (started-or-done? 'combat-shield) (>= rax-techlabs 2)))))]
       [(infernal-pre-igniter) (>= hellions 3)]
       [(drilling-claws) (>= widow-mines 3)]
       [(cyclone-lock-on-damage) (>= cyclones 2)]
       [(banshee-cloak hyperflight-rotors) (>= banshees 2)]
       [else #t])]
    [(Zerg)
     (define roaches (uc 'roach 'roach-burrowed))
     (define lurkers (uc 'lurker 'lurker-mp 'lurker-burrowed 'lurker-mp-burrowed 'lurker-egg 'lurker-mp-egg))
     (define infestors (uc 'infestor 'infestor-burrowed))
     (define banelings (uc 'baneling 'baneling-burrowed 'baneling-cocoon))
     (define zerglings (uc 'zergling 'zergling-burrowed))
     (define hydralisks (uc 'hydralisk 'hydralisk-burrowed))
     (define baneling-nests (bc 'baneling-nest))
     (define w (safe-nonneg-int workers 0))
     (define f (safe-nonneg-int frame 0))
     (case canon
       [(burrow)
        (and (>= f 5376)
             (or (done? 'metabolic-boost) (done? 'glial-reconstitution))
             (or (>= roaches 4) (>= lurkers 1) (>= infestors 1) (>= w 44)))]
       [(centrifical-hooks)
        (or (>= banelings 3)
            (and (>= baneling-nests 1) (>= zerglings 10)))]
       [(grooved-spines muscular-augments)
        (>= hydralisks 3)]
       [else #t])]
    [else #t]))

;; Bug 4 / W2-P1-3a matchup-aware natural expansion benchmark window when townhall-count < 2 and no proxy/rush.
(define (natural-expansion-window-active?
         race frame workers total-bases ready-bldgs total-bldgs
         under-attack? enemy-threat-supply [proxy-or-rush? #f]
         #:enemy-race [enemy-race 'Unknown])
  (define (bc sym)
    (max (ledger-map-count ready-bldgs sym) (ledger-map-count total-bldgs sym)))
  (define active-rush?
    (or under-attack?
        proxy-or-rush?
        (>= (safe-real enemy-threat-supply 0.0) 6.0)))
  (and (< (safe-nonneg-int total-bases 0) 2)
       (not active-rush?)
       (case race
         [(Zerg)
          (or (>= workers 16) (>= frame 1000))]
         [(Protoss)
          (if (eq? enemy-race 'Protoss)
              ;; W3-P0-3b: PvP 2-Gate Double-Gas Cyber Expand aligned with Pro ~180–194s
              (and (>= (bc 'pylon) 1)
                   (>= (bc 'assimilator) 2)
                   (>= (bc 'cybernetics-core) 1)
                   (>= (+ (bc 'gateway) (bc 'warp-gate)) 2)
                   (or (>= workers 20) (>= frame 2688)))
              ;; PvZ/PvT: require >= 19 workers OR (>= 17 workers & frame >= 1450) — never hijack at 17 Probes / 53s
              (and (>= (bc 'pylon) 1)
                   (>= (+ (bc 'gateway) (bc 'warp-gate)) 1)
                   (>= (bc 'assimilator) 1)
                   (or (>= workers 19)
                       (and (>= workers 17) (>= frame 1450)))))]
         [(Terran)
          (and (>= (+ (bc 'supply-depot) (bc 'supply-depot-lowered)) 1)
               (>= (+ (bc 'barracks) (bc 'barracks-flying)) 1)
               (>= (bc 'refinery) 1)
               (or (>= workers 19)
                   (and (>= frame 1750)
                        (>= (+ (ledger-map-count ready-bldgs 'barracks)
                               (ledger-map-count ready-bldgs 'barracks-flying))
                            1))))]
         [else #f])))
