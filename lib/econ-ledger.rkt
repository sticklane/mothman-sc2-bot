#lang racket/base

(require racket/match
         racket/list
         racket/math
         racket/string
         racket/runtime-path
         "../compiler/syntax.rkt"
         "sc2-game-constants.rkt"
         "okasaki-sc.rkt")

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

 ;; Marginal-Utility Prioritization & Braun-Heap Resource Scheduler (PV1-PV9)
 braun-extract-min
 (struct-out priority-candidate)
 (struct-out priority-decision-entry)
 (struct-out priority-schedule-result)
 (struct-out opponent-intel-quality)
 PV-INTEL-GATHERING-UNIT-SYMS
 evaluate-opponent-intel-quality
 select-intel-gathering-method
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
 PRO-BUILD-ORDER-DB
 (struct-out pro-bo-goal)
 (struct-out pro-bo-eval-result)
 select-pro-build-order
 pro-build-order-steps-for-matchup
 pro-supply-curve-target
 evaluate-build-order-next-step
 compute-natural-expansion-mineral-reserve

 ;; Decoupled 8-Stream Resource & Bank Manager + 200/200 Late-Game Max-Supply Manager
 DEC-GOAL-STREAMS
 (struct-out race-bank-target)
 (struct-out stream-budget-slice)
 (struct-out decoupled-bank-allocation)
 (struct-out max-supply-plan)
 compute-bank-targets
 allocate-decoupled-goal-streams
 decoupled-stream-can-spend?
 evaluate-max-supply-manager)

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
;; =============================================================================

(define (finite-real? v)
  (and (number? v) (real? v) (not (nan? v)) (not (infinite? v))))

(define (safe-real v [default 0.0])
  (if (finite-real? v) (exact->inexact v) default))

(define (safe-exact-int v [default 0])
  (if (finite-real? v) (exact-round v) default))

(define (safe-nonneg-int v [default 0])
  (max 0 (safe-exact-int v default)))

(define (safe-list v)
  (if (list? v) v '()))

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

(define (safe-ledger-int v [default 0])
  (if (and (number? v) (real? v) (not (nan? v)) (not (infinite? v)))
      (max 0 (exact-round v))
      default))

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
  (define time-bases (add1 (quotient (max 0 frame) 1600)))
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

  ;; Target workers coupled to healthy + desired bases (22 per active/desired base, up to 84)
  (define target-workers
    (min 84 (max 22 (* 22 (min 5 (max healthy-bases desired-bases))))))

  (define should-expand?
    (and (not under-crisis?)
         (or (> depleting-bases 0)
             (> desired-bases eff-bases))))

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
  (define have-all?
    (lambda (reqs pool)
      (andmap (lambda (r) (not (not (memq r pool)))) reqs)))

  (case norm-race
    [(Zerg)
     ;; Core Zerg Synergy ("What makes Roach/Hydra/Ling/Bane/Lurker work"):
     ;; Metabolic Boost (zergling-movementspeed) + Burrow + Lair + Glial Reconstitution
     ;; + Grooved Spines + +1/+1 Missile/Carapace
     (define synergy-invariants
       '(zergling-movementspeed burrow lair glial-reconstitution
         grooved-spines missile-attacks-1 ground-carapace-1))
     (define base-counter-tech
       (case threat-family
         [(air-fleet)          '(lair spire hydralisk-den spore-crawler)]
         [(armored-mech-siege) '(lair roach-warren hydralisk-den lurker-den spire)]
         [else                 '(lair baneling-nest roach-warren infestation-pit ultralisk-cavern)]))
     (define counter-tech
       (remove-duplicates
        (append (if requires-detection? '(spore-crawler lair) '())
                base-counter-tech)))
     (define prio-upgrades
       (case threat-family
         [(air-fleet)
          '(zergling-movementspeed burrow grooved-spines muscular-augments missile-attacks-1 ground-carapace-1)]
         [(armored-mech-siege)
          '(zergling-movementspeed burrow glial-reconstitution grooved-spines adaptive-talons missile-attacks-1 ground-carapace-1)]
         [else
          '(zergling-movementspeed burrow centrifical-hooks glial-reconstitution chitinous-plating missile-attacks-1 ground-carapace-1)]))
     (define prio-morphs
       (remove-duplicates
        (append (if requires-detection? '(overseer) '())
                (case threat-family
                  [(air-fleet)          '(lair overseer hive)]
                  [(armored-mech-siege) '(lair ravager lurker brood-lord hive)]
                  [else                 '(lair baneling ravager overseer hive)]))))
     (define unit-mix
       (case threat-family
         [(air-fleet)          '((corruptor . 0.45) (hydralisk . 0.40) (queen . 0.15))]
         [(armored-mech-siege) '((ravager . 0.35) (lurker . 0.35) (brood-lord . 0.15) (roach . 0.15))]
         [else                 '((baneling . 0.35) (zergling . 0.30) (roach . 0.20) (ultralisk . 0.15))]))
     (define target-gm-ratio
       (case threat-family
         [(air-fleet)          0.62]
         [(armored-mech-siege) 0.58]
         [else                 0.42]))

     (define st1-b '(hatchery spawning-pool extractor))
     (define st1-u '(zergling-movementspeed))
     (define st2-b '(roach-warren lair evolution-chamber))
     (define st2-u '(burrow glial-reconstitution missile-attacks-1 ground-carapace-1))
     (define st3-b counter-tech)
     (define st3-u '(grooved-spines))
     (define st4-b '(hive ultralisk-cavern greater-spire))
     (define st4-u '(chitinous-plating zergling-attackspeed))

     (define s1-ok? (and (have-all? st1-b ally-buildings) (have-all? st1-u researched-upgrades)))
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
       (filter (lambda (x) (not (memq x known-all))) synergy-invariants))
     (define missing-bldgs
       (filter (lambda (b) (not (memq b ally-buildings)))
               (remove-duplicates (append st1-b st2-b counter-tech))))
     (define missing-upgs
       (filter (lambda (u) (not (memq u researched-upgrades))) prio-upgrades))
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
     ;; Stimpack + Combat Shield + Concussive Shells + Medivacs + Siege Mode + +1/+1 Infantry
     (define synergy-invariants
       '(stimpack combat-shield concussive-shells medivac siege-mode
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
          '(stimpack combat-shield concussive-shells siege-mode infantry-weapons-1 infantry-armor-1)]
         [else
          '(stimpack combat-shield infernal-pre-igniter siege-mode infantry-weapons-1 infantry-armor-1)]))
     (define prio-morphs
       '(orbital-command siege-mode hellbat planetary-fortress))
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
     (define st3-u '(siege-mode))
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
       (filter (lambda (x) (not (memq x known-all))) synergy-invariants))
     (define missing-bldgs
       (filter (lambda (b) (not (memq b ally-buildings)))
               (remove-duplicates (append st1-b st2-b counter-tech))))
     (define missing-upgs
       (filter (lambda (u) (not (memq u researched-upgrades))) prio-upgrades))
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
         [(air-fleet)          '(cybernetics-core stargate twilight-council templar-archives photon-cannon)]
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
         [(air-fleet)          '((stalker . 0.45) (archon . 0.30) (phoenix . 0.25))]
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
       (filter (lambda (x) (not (memq x known-all))) synergy-invariants))
     (define missing-bldgs
       (filter (lambda (b) (not (memq b ally-buildings)))
               (remove-duplicates (append st1-b st2-b counter-tech))))
     (define missing-upgs
       (filter (lambda (u) (not (memq u researched-upgrades))) prio-upgrades))
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

(define (normalize-ledger-race r)
  (case r
    [(Zerg zerg "Zerg" "zerg") 'Zerg]
    [(Protoss protoss "Protoss" "protoss") 'Protoss]
    [(Terran terran "Terran" "terran") 'Terran]
    [else 'Zerg]))

;; Wrapper around okasaki-sc's braun-min + braun-delete-min
(define (braun-extract-min t)
  (if (braun-empty? t)
      (values #f braun-empty)
      (let ([kv (braun-min t)])
        (values (if (pair? kv) (cdr kv) kv)
                (braun-delete-min t)))))

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
  (define target-workers (max 12 (safe-nonneg-int raw-target-workers 44)))
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
  (define supply-buffer
    (if (and override-supply-buffer (real? override-supply-buffer) (not (nan? override-supply-buffer)))
        (max 1.0 (exact->inexact override-supply-buffer))
        (+ 2.0 (* 0.06 (exact->inexact supply-cap)))))
  (define eff-supply
    (+ (exact->inexact supply-left) (* 8.0 (exact->inexact pending-supply))))
  (define raw-supply-hazard
    (/ (max 0.0 (- supply-buffer eff-supply))
       (max 1.0 supply-buffer)))
  (define supply-hazard
    (cond
      [(>= supply-cap 200) 0.0]
      [(and (> pending-supply 0) (not supply-at-risk?)) 0.0]
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
    (and (< escrow-age-frames max-escrow-frames)
         (< threat-pressure 0.85)
         (<= enemy-threat-supply 0.0)
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

(define PV5-COUNTER-TECH-AND-UNIT-SYMS
  '(queen hydralisk corruptor spore-crawler overseer
    viking-fighter viking missile-turret
    stalker phoenix void-ray observer photon-cannon
    hydralisk-den spire engineering-bay robotics-facility stargate))

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

(define (compute-candidate-marginal-utility cand metrics)
  (define m (if (hash? metrics) metrics (compute-state-pressure-metrics)))
  (define id (priority-candidate-id cand))
  (define cat (priority-candidate-category cand))
  (define m-cost (safe-nonneg-int (priority-candidate-min-cost cand) 0))
  (define g-cost (safe-nonneg-int (priority-candidate-gas-cost cand) 0))

  (define supply-cap (safe-nonneg-int (hash-ref m 'supply-cap 15) 15))
  (define pending-supply (safe-nonneg-int (hash-ref m 'pending-supply 0) 0))
  (define supply-left (safe-exact-int (hash-ref m 'supply-left 4) 4))
  (define supply-buffer (safe-real (hash-ref m 'supply-buffer (+ 2.0 (* 0.06 supply-cap))) 4.0))
  (define supply-hazard (safe-real (hash-ref m 'supply-hazard 0.0) 0.0))
  (define supply-at-risk? (eq? (hash-ref m 'supply-at-risk? #f) #t))
  (define threat-pressure (safe-real (hash-ref m 'threat-pressure 0.0) 0.0))
  (define intel-pressure (safe-real (hash-ref m 'intel-pressure 0.0) 0.0))
  (define enemy-threat-supply (safe-real (hash-ref m 'enemy-threat-supply 0.0) 0.0))
  (define under-attack? (eq? (hash-ref m 'under-attack? #f) #t))
  (define gas (safe-nonneg-int (hash-ref m 'gas 0) 0))
  (define gas-imbalance (safe-real (hash-ref m 'gas-imbalance 0.0) 0.0))
  (define worker-saturation-gap (safe-real (hash-ref m 'worker-saturation-gap 0.5) 0.5))
  (define facility-scaling-pressure (safe-real (hash-ref m 'facility-scaling-pressure 0.2) 0.2))
  (define expansion-desire (safe-real (hash-ref m 'expansion-desire 0.0) 0.0))
  (define active-bases (max 1 (safe-nonneg-int (hash-ref m 'active-bases 1) 1)))
  (define escrow-eligible? (eq? (hash-ref m 'escrow-eligible? #f) #t))
  (define requires-anti-air? (eq? (hash-ref m 'requires-anti-air? #f) #t))
  (define requires-detection? (eq? (hash-ref m 'requires-detection? #f) #t))
  (define bo-goal-sym (hash-ref m 'bo-goal-sym #f))

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
             (and supply-at-risk? (< pending-supply 2) (<= eff-supply (+ supply-buffer 6.0)))
             (and (= pending-supply 0) (<= supply-left supply-buffer)))))

  ;; PV5 boost (+ 180.0) for anti-air & detection units/tech
  (define pv5-boost
    (if (and (or requires-anti-air? requires-detection?)
             (or (eq? cat 'counter-tech)
                 (memq id PV5-COUNTER-TECH-AND-UNIT-SYMS)))
        (+ 180.0 (if (and requires-anti-air? requires-detection?) 20.0 0.0))
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
    (if (and bo-goal-sym (eq? id bo-goal-sym) (not under-attack?))
        (/ 42.0 (+ 1.0 (* 0.5 threat-pressure)))
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
       (or requires-anti-air? requires-detection?))
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
     (+ (if active-counter-need? 138.0 118.0) pv5-boost intel-gathering-boost threat-boost bo-head-boost)]

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
     (+ base-combat threat-boost gas-sink-adj pv5-boost intel-gathering-boost bo-head-boost)]

    [(tech-upgrade)
     (define gas-ready-boost
       (if (>= gas 100) 45.0 0.0))
     (define threat-research-boost
       (if (and under-threat? (not under-attack?) (>= gas 100))
           (+ 110.0 (* 32.0 (min 4.0 threat-pressure)))
           0.0))
     (define gas-sink-boost
       (if gas-sink-active?
           (+ 165.0 (* 25.0 (min 4.0 gas-imbalance)))
           (* 15.0 (min 2.0 gas-imbalance))))
     (+ 145.0 gas-ready-boost threat-research-boost gas-sink-boost pv5-boost bo-head-boost)]

    [(production-scaling)
     (define gas-tech-bonus
       (if (> g-cost 0)
           (min 18.0 (* 0.14 (exact->inexact g-cost)))
           0.0))
     (+ 116.0 gas-tech-bonus (* 45.0 (min 3.0 facility-scaling-pressure)) pv5-boost bo-head-boost)]

    [(worker)
     (if under-threat?
         (* 42.0 worker-saturation-gap)
         (+ 35.0 (* 52.0 worker-saturation-gap)))]

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
        ;; production-scaling (>=116), or combat-unit (>=88).
        (+ 48.0 (* 18.0 (min 1.5 expansion-desire)) bo-head-boost)])]

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

(define (safe-tile-coord v [default 32.5])
  (define raw (if (and (number? v) (real? v) (not (nan? v)) (not (infinite? v))) v default))
  (define clamped (max 0.0 (min 256.0 (exact->inexact raw))))
  (define half-rounded (/ (round (* clamped 2.0)) 2.0))
  (if (and (exact-integer? raw) (= clamped (exact->inexact (exact-round half-rounded))))
      (exact-round half-rounded)
      half-rounded))

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
         #:base-x [raw-base-x 32.5]
         #:base-y [raw-base-y 32.5]
         #:nat-x [raw-nat-x 50.5]
         #:nat-y [raw-nat-y 50.5]
         #:third-x [raw-third-x 60.5]
         #:third-y [raw-third-y 40.5])
  (define race (normalize-ledger-race raw-race))
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
  (define bldgs (if (list? ally-buildings) ally-buildings '()))
  (define r-bldgs (if (list? ready-buildings) ready-buildings bldgs))
  (define units (if (list? ally-units) ally-units '()))
  (define bo-goal-sym (and (pro-bo-goal? bo-active-goal) (pro-bo-goal-target-sym bo-active-goal)))

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
     #:desired-bases raw-desired-bases
     #:production-facilities raw-prod-facilities
     #:max-facilities raw-max-facilities
     #:army-supply raw-army-supply
     #:enemy-threat-supply raw-enemy-threat-supply
     #:under-attack? raw-under-attack?
     #:requires-anti-air? raw-requires-anti-air?
     #:requires-detection? raw-requires-detection?
     #:escrow-age-frames raw-escrow-age-frames
     #:max-escrow-frames raw-max-escrow-frames
     #:intel-staleness-frames raw-intel-staleness-frames
     #:max-intel-staleness-frames raw-max-intel-staleness-frames
     #:supply-at-risk? raw-supply-at-risk?
     #:supply-buffer override-supply-buffer))

  (define metrics
    (if bo-goal-sym
        (hash-set base-metrics 'bo-goal-sym bo-goal-sym)
        base-metrics))

  (define live-workers (safe-nonneg-int raw-workers 12))
  (define worker-survival-crisis?
    (and (hash? open-prod-slots) (< live-workers 6)))
  (define escrow-ok?
    (and (not worker-survival-crisis?)
         (eq? (hash-ref metrics 'escrow-eligible? #f) #t)))
  (define exp-blocking?
    (and (or (= active-bases 1)
             (and (hash? open-prod-slots)
                  (not (not (memq bo-goal-sym '(hatchery nexus command-center))))))
         escrow-ok?
         (if (hash? open-prod-slots)
             (or (not (not (memq bo-goal-sym '(hatchery nexus command-center))))
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
             (or (not prereq-sym) (not (not (memq prereq-sym r-bldgs)))))
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
    (if (and (eq? category 'worker) (hash? open-prod-slots) (< live-workers 8))
        (struct-copy priority-candidate base-c
                     [utility-score (+ (priority-candidate-utility-score base-c)
                                       (* 120.0 (- 8.0 live-workers)))]
                     [blocking-allowed? (> live-workers 0)])
        base-c))

  (case race
    [(Zerg)
     (define upg-sym
       (cond
         [(not (memq 'metabolic-boost upgs)) 'metabolic-boost]
         [(not (memq 'glial-reconstitution upgs)) 'glial-reconstitution]
         [(not (memq 'zerg-missile-weapons-1 upgs)) 'zerg-missile-weapons-1]
         [(not (memq 'burrow upgs)) 'burrow]
         [(not (memq 'tunneling-claws upgs)) 'tunneling-claws]
         [(not (memq 'zerg-ground-armor-1 upgs)) 'zerg-ground-armor-1]
         [(not (memq 'grooved-spines upgs)) 'grooved-spines]
         [(not (memq 'muscular-augments upgs)) 'muscular-augments]
         [(not (memq 'zerg-missile-weapons-2 upgs)) 'zerg-missile-weapons-2]
         [(not (memq 'zerg-ground-armor-2 upgs)) 'zerg-ground-armor-2]
         [(not (memq 'centrifical-hooks upgs)) 'centrifical-hooks]
         [else 'zerg-missile-weapons-3]))
     (define has-lair-or-hive?
       (or (not (not (memq 'lair r-bldgs)))
           (not (not (memq 'hive r-bldgs)))))
     (define zerg-upg-ready?
       (if (hash? open-prod-slots)
           (case upg-sym
             [(metabolic-boost) (not (not (memq 'spawning-pool r-bldgs)))]
             [(burrow) (or (not (not (memq 'hatchery r-bldgs))) has-lair-or-hive?)]
             [(glial-reconstitution tunneling-claws)
              (and (not (not (memq 'roach-warren r-bldgs))) has-lair-or-hive?)]
             [(grooved-spines) (not (not (memq 'hydralisk-den r-bldgs)))]
             [(muscular-augments) (and (not (not (memq 'hydralisk-den r-bldgs))) has-lair-or-hive?)]
             [(centrifical-hooks) (and (not (not (memq 'baneling-nest r-bldgs))) has-lair-or-hive?)]
             [(zerg-missile-weapons-2 zerg-ground-armor-2)
              (and (not (not (memq 'evolution-chamber r-bldgs))) has-lair-or-hive?)]
             [else (not (not (memq 'evolution-chamber r-bldgs)))])
           #t))
     (list
      (cand 'overlord 'supply '(train overlord) supply-urgent?)
      (cand 'spore-crawler 'counter-tech (list 'build 'spore-crawler (safe-tile-coord (+ base-x 3.0)) (safe-tile-coord (+ base-y 3.0)))
            (if (hash? open-prod-slots) (or raw-requires-anti-air? raw-requires-detection?) #t))
      (cand 'queen 'counter-tech '(train queen) (facility-slot-open? 'townhall 'spawning-pool))
      (cand 'hydralisk-den 'counter-tech (list 'build 'hydralisk-den (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 5.0)))
            (if (hash? open-prod-slots) (and (memq 'lair r-bldgs) (not (memq 'hydralisk-den bldgs))) #t))
      (cand 'overseer 'counter-tech '(morph overseer)
            (if (hash? open-prod-slots) (and (or raw-requires-anti-air? raw-requires-detection?) (memq 'lair r-bldgs)) #t))
      (cand 'roach 'combat-unit '(train roach) (facility-slot-open? 'larva 'roach-warren))
      (cand 'hydralisk 'combat-unit '(train hydralisk) (facility-slot-open? 'larva 'hydralisk-den))
      (cand 'zergling 'combat-unit '(train zergling) (facility-slot-open? 'larva 'spawning-pool))
      (cand upg-sym 'tech-upgrade (list 'research upg-sym) zerg-upg-ready?)
      (cand 'roach-warren 'production-scaling (list 'build 'roach-warren (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (- base-y 4.0)))
            (if (hash? open-prod-slots) (and (memq 'spawning-pool r-bldgs) (not (memq 'roach-warren bldgs))) #t))
      (cand 'drone 'worker '(train drone) #f)
      (cand 'hatchery 'expansion (list 'expand exp-x exp-y) exp-blocking?))]

    [(Protoss)
     (define upg-sym
       (cond
         [(not (memq 'warp-gate-research upgs)) 'warp-gate-research]
         [(not (memq 'charge upgs)) 'charge]
         [(not (memq 'protoss-ground-weapons-1 upgs)) 'protoss-ground-weapons-1]
         [(not (memq 'blink upgs)) 'blink]
         [(not (memq 'protoss-ground-armor-1 upgs)) 'protoss-ground-armor-1]
         [(not (memq 'extended-thermal-lance upgs)) 'extended-thermal-lance]
         [(not (memq 'protoss-ground-weapons-2 upgs)) 'protoss-ground-weapons-2]
         [(not (memq 'protoss-ground-armor-2 upgs)) 'protoss-ground-armor-2]
         [else 'protoss-shields-1]))
     (define robo-open?
       (and (facility-slot-open? 'robotics-facility 'robotics-facility)
            (if (hash? open-prod-slots)
                (< (count (lambda (u) (memq u '(immortal colossus))) units) 3)
                #t)))
     (list
      (cand 'pylon 'supply (list 'build 'pylon (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0))) supply-urgent?)
      (cand 'photon-cannon 'counter-tech (list 'build 'photon-cannon nat-x nat-y)
            (if (hash? open-prod-slots) (and (or raw-requires-anti-air? raw-requires-detection?) (memq 'forge r-bldgs)) #t))
      (cand 'robotics-facility 'counter-tech (list 'build 'robotics-facility (safe-tile-coord (+ base-x 6.0)) (safe-tile-coord (+ base-y 6.0)))
            (if (hash? open-prod-slots) (and (memq 'cybernetics-core r-bldgs) (not (memq 'robotics-facility bldgs))) #t))
      (cand 'observer 'counter-tech '(train observer)
            (and (facility-slot-open? 'robotics-facility 'robotics-facility)
                 (if (hash? open-prod-slots) (not (memq 'observer units)) #t)))
      (cand 'stalker 'combat-unit '(train stalker)
            (facility-slot-open? 'gateway 'cybernetics-core))
      (cand 'immortal 'combat-unit '(train immortal) robo-open?)
      (cand 'zealot 'combat-unit '(train zealot)
            (facility-slot-open? 'gateway))
      (cand upg-sym 'tech-upgrade (list 'research upg-sym)
            (if (hash? open-prod-slots)
                (case upg-sym
                  [(warp-gate-research) (not (not (memq 'cybernetics-core r-bldgs)))]
                  [(charge blink) (not (not (memq 'twilight-council r-bldgs)))]
                  [(extended-thermal-lance) (or (not (not (memq 'robotics-bay r-bldgs)))
                                                (not (not (memq 'robotics-support-bay r-bldgs))))]
                  [(protoss-ground-weapons-2 protoss-ground-armor-2)
                   (and (not (not (memq 'forge r-bldgs)))
                        (not (not (memq 'twilight-council r-bldgs))))]
                  [else (not (not (memq 'forge r-bldgs)))])
                #t))
       (cand 'gateway 'production-scaling (list 'build 'gateway (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0)))
             (if (hash? open-prod-slots)
                 (and (< raw-prod-facilities raw-max-facilities)
                      (or (> active-bases 1)
                          (< raw-prod-facilities 1)
                          (not escrow-ok?)
                          (< raw-frame 1500)
                          (>= (- raw-minerals 400) (sc2-min-cost 'gateway))))
                 #t))
       (cand 'probe 'worker '(train probe) #f)
       (cand 'nexus 'expansion (list 'expand exp-x exp-y) exp-blocking?))]

    [else ;; Terran
     (define upg-sym
       (cond
         [(not (memq 'stimpack upgs)) 'stimpack]
         [(not (memq 'combat-shield upgs)) 'combat-shield]
         [(not (memq 'terran-infantry-weapons-1 upgs)) 'terran-infantry-weapons-1]
         [(not (memq 'concussive-shells upgs)) 'concussive-shells]
         [(not (memq 'terran-infantry-armor-1 upgs)) 'terran-infantry-armor-1]
         [(not (memq 'terran-infantry-weapons-2 upgs)) 'terran-infantry-weapons-2]
         [(not (memq 'terran-infantry-armor-2 upgs)) 'terran-infantry-armor-2]
         [(not (memq 'banshee-cloak upgs)) 'banshee-cloak]
         [else 'terran-infantry-weapons-3]))
     (define has-rax-tl?
       (or (memq 'barracks-techlab r-bldgs)
           (memq 'barracks-tech-lab r-bldgs)))
     (define has-fac-tl?
       (or (memq 'factory-techlab r-bldgs)
           (memq 'factory-tech-lab r-bldgs)))
     (define has-fac-tl-any?
       (or has-fac-tl?
           (memq 'factory-techlab bldgs)
           (memq 'factory-tech-lab bldgs)))
     (append
      (if (and (hash? open-prod-slots)
               (facility-slot-open? 'factory 'factory)
               (not has-fac-tl-any?))
          (list (cand 'factory-techlab 'counter-tech
                      (list 'build 'factory-techlab (safe-tile-coord (+ base-x 8.5)) (safe-tile-coord (+ base-y 3.0)))
                      #t))
          '())
      (list
       (cand 'supply-depot 'supply (list 'build 'supply-depot (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (- base-y 3.0))) supply-urgent?)
       (cand 'missile-turret 'counter-tech (list 'build 'missile-turret (safe-tile-coord (+ base-x 3.0)) (safe-tile-coord (+ base-y 3.0)))
             (if (hash? open-prod-slots) (and (or raw-requires-anti-air? raw-requires-detection?) (memq 'engineering-bay r-bldgs)) #t))
       (cand 'engineering-bay 'counter-tech (list 'build 'engineering-bay (safe-tile-coord (+ base-x 5.0)) (safe-tile-coord (- base-y 3.0)))
             (if (hash? open-prod-slots) (and (or raw-requires-anti-air? raw-requires-detection?) (not (memq 'engineering-bay bldgs))) #t))
       (cand 'viking-fighter 'counter-tech '(train viking-fighter)
             (facility-slot-open? 'starport 'starport))
       (cand 'marauder 'combat-unit '(train marauder)
             (if (hash? open-prod-slots) (and (facility-slot-open? 'barracks 'barracks) has-rax-tl?) #t))
       (cand 'siege-tank 'combat-unit '(train siege-tank)
             (if (hash? open-prod-slots) (and (facility-slot-open? 'factory 'factory) has-fac-tl?) #t))
       (cand 'marine 'combat-unit '(train marine)
             (facility-slot-open? 'barracks 'barracks))
       (cand upg-sym 'tech-upgrade (list 'research upg-sym)
             (if (hash? open-prod-slots)
                 (case upg-sym
                   [(stimpack combat-shield concussive-shells) has-rax-tl?]
                   [(terran-infantry-weapons-2 terran-infantry-armor-2 terran-infantry-weapons-3)
                    (and (not (not (memq 'engineering-bay r-bldgs)))
                         (not (not (memq 'armory r-bldgs))))]
                   [(banshee-cloak)
                    (or (not (not (memq 'starport-techlab r-bldgs)))
                        (not (not (memq 'starport-tech-lab r-bldgs))))]
                   [else (not (not (memq 'engineering-bay r-bldgs)))])
                 #t))
       (cand 'barracks 'production-scaling (list 'build 'barracks (safe-tile-coord (+ base-x 4.0)) (safe-tile-coord (+ base-y 4.0)))
             (if (hash? open-prod-slots)
                 (and (< raw-prod-facilities raw-max-facilities)
                      (or (> active-bases 1)
                          (< raw-prod-facilities 1)
                          (not escrow-ok?)
                          (< raw-frame 1500)
                          (>= (- raw-minerals 400) (sc2-min-cost 'barracks))))
                 #t))
       (cand 'scv 'worker '(train scv) #f)
       (cand 'command-center 'expansion (list 'expand exp-x exp-y) exp-blocking?)))]))

;; Computes reserved minerals for the natural expansion (`400M` Terran/Protoss, `300M` Zerg)
;; when on 1 base (`active-bases + pending-bases < 2`) at `frame >= 1500` (or `workers >= 18/15`)
;; without active base attack, enemy threat, or blocked natural, preventing a `150M` 2nd Barracks
;; or Gateway from starving the natural TownHall (Match 5115348 root-cause fix).
(define (compute-natural-expansion-mineral-reserve
         #:race [raw-race 'Terran]
         #:frame [raw-frame 0]
         #:active-bases [raw-active-bases 1]
         #:pending-bases [raw-pending-bases 0]
         #:workers [raw-workers 12]
         #:under-attack? [under-attack? #f]
         #:enemy-threat-supply [enemy-threat 0]
         #:natural-blocked? [natural-blocked? #f]
         #:escrow-expired? [escrow-expired? #f])
  (define race (normalize-ledger-race raw-race))
  (define total-bases (+ (safe-nonneg-int raw-active-bases 1)
                         (safe-nonneg-int raw-pending-bases 0)))
  (define frame (safe-nonneg-int raw-frame 0))
  (define workers (safe-nonneg-int raw-workers 12))
  (if (and (< total-bases 2)
           (not under-attack?)
           (<= (safe-real enemy-threat 0.0) 0.0)
           (not natural-blocked?)
           (not escrow-expired?)
           (or (>= frame 1500)
               (>= workers (if (eq? race 'Zerg) 15 18))))
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

  (define heap
    (for/fold ([h braun-empty])
              ([c (in-list cands)]
               [idx (in-naturals)])
      (define raw-u (safe-real (priority-candidate-utility-score c) 0.0))
      (define eff-u
        (if (and (eq? (priority-candidate-category c) 'expansion)
                 (or (not escrow-eligible?)
                     (not (priority-candidate-blocking-allowed? c)))
                 (not (infinite? min-non-exp-utility)))
            (min raw-u (- min-non-exp-utility 1.0))
            raw-u))
      (define key (+ (- eff-u) (* 1e-7 idx)))
      (braun-insert h key c)))

  ;; Extract candidates in descending utility order via braun-extract-min
  (define sorted-cands
    (let loop ([h heap] [acc '()])
      (if (braun-empty? h)
          (reverse acc)
          (let-values ([(top rest-h) (braun-extract-min h)])
            (loop rest-h (cons top acc))))))

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
  ;;      reserves its mineral cost against lower-ranked candidates `c`.
  ;;   6. gas-escrow-floor: any ready blocking-allowed? tech-upgrade/counter-tech waiting on gas
  ;;      reserves its gas cost against lower-ranked gas-consuming candidates.
  (define supply-floor 0)
  (define expansion-floor 0)
  (define combat-floor 0)
  (define gas-sink-floor 0)
  (define gas-escrow-floor 0)

  (for ([c (in-list sorted-cands)]
        [rank-idx (in-naturals 1)])
    (define id (priority-candidate-id c))
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

    ;; Rank-ordered escrow floor from higher-utility ready candidates
    (define higher-rank-min-floor
      (for/fold ([mf 0])
                ([e (in-list escrowed-entries)])
        (match-define (list eu em eg _eid ecat) e)
        (if (and (> eu (+ u-score 1.0))
                 (not (eq? cat 'supply))
                 ;; PV1: expansion escrow only applies when escrow-eligible?
                 (or (not (eq? ecat 'expansion)) escrow-eligible?)
                 ;; A waiting gas-bearing combat/tech candidate blocks lower-ranked candidates
                 (> eg 0))
            (max mf em)
            mf)))

    ;; Determine effective mineral reservation floor that applies to candidate `c`
    (define applicable-floor
      (max (if (eq? cat 'supply) 0 supply-floor)
           (if (eq? cat 'expansion) 0 expansion-floor)
           (if (or (eq? cat 'worker) (not blk-ok?)) combat-floor 0)
           (if (and (= g-cost 0) (memq cat '(worker combat-unit))) gas-sink-floor 0)
           higher-rank-min-floor))

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
      [(and supply-ok? gas-ok? min-ok? floor-ok?)
       (if (ledger-reserve! ledger id cat m-cost g-cost s-cost u-score)
           (begin
             (set! rem-min (- rem-min m-cost))
             (set! rem-gas (- rem-gas g-cost))
             (set! rem-sup (- rem-sup s-cost))
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
           [(and (eq? cat 'expansion) (< rem-min m-cost) escrow-eligible? blk-ok?)
            (set! expansion-floor (max expansion-floor m-cost))
            (set! escrowed-now? #t)
            (set! escrowed-entries (cons (list u-score m-cost g-cost id cat) escrowed-entries))
            (unless reserved-cand (set! reserved-cand c))]

           ;; PV2, PV3 & General Rank-Ordered Escrow: Ready blocking combat units, counter-tech, and tech-upgrade
           [(and blk-ok? (memq cat '(combat-unit counter-tech tech-upgrade)))
            (when (and (< rem-min m-cost) gas-ok? (memq cat '(combat-unit counter-tech)))
              (set! combat-floor (max combat-floor m-cost))
              (set! escrowed-now? #t)
              (unless reserved-cand (set! reserved-cand c)))
            (when (> g-cost 0)
              (when (and (< rem-min m-cost) gas-ok?)
                (set! gas-sink-floor (max gas-sink-floor m-cost)))
              (when (and (< rem-gas g-cost) (memq cat '(tech-upgrade counter-tech)))
                (set! gas-escrow-floor (max gas-escrow-floor g-cost))
                (set! escrowed-now? #t)
                (set! escrowed-entries (cons (list u-score m-cost g-cost id cat) escrowed-entries))
                (unless reserved-cand (set! reserved-cand c)))
              (when (and (< rem-min m-cost) (>= init-gas g-cost))
                (set! escrowed-now? #t)
                (set! escrowed-entries (cons (list u-score m-cost g-cost id cat) escrowed-entries))
                (unless reserved-cand (set! reserved-cand c))))]))

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
  (define m-cost (or override-min (sc2-min-cost id-sym)))
  (define g-cost (or override-gas (sc2-gas-cost id-sym)))
  (cond
    [(or (< cur-min m-cost) (< cur-gas g-cost)) #f]
    [(not (priority-schedule-result? sched)) #t]
    [else
     (define cu (priority-schedule-result-category-utilities sched))
     (define cand-utils (hash-ref cu 'candidate-utilities (hash)))
     (define escrowed (hash-ref cu 'escrowed-entries '()))
     (define u-self
       (hash-ref cand-utils id-sym
                 (hash-ref cu cat-sym
                           (if (eq? cat-sym 'worker) 65.0 120.0))))
     (define is-bo-head? (and bo-goal-sym (eq? id-sym bo-goal-sym)))
     (define higher-escrow-min
       (for/fold ([mf (if (and (not is-bo-head?) (> bo-reserved-min 0) (not (eq? cat-sym 'supply)))
                          bo-reserved-min
                          0)])
                 ([e (in-list escrowed)])
         (match-define (list eu em _eg eid _ecat) e)
         (if (and (not (eq? eid id-sym))
                  (> eu (+ u-self 1.0)))
             (max mf em)
             mf)))
     (define higher-escrow-gas
       (if (and (not is-bo-head?) (> bo-reserved-gas 0) (> g-cost 0))
           bo-reserved-gas
           0))
     (and (>= (- cur-min m-cost) higher-escrow-min)
          (>= (- cur-gas g-cost) higher-escrow-gas))]))

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
         #:bo-reserved-gas [bo-reserved-gas 0])
  (define trace (priority-schedule-decision-trace sched))
  (define res-cand (and (priority-schedule-result? sched)
                        (priority-schedule-result-reserved-candidate sched)))
  (define cu (if (priority-schedule-result? sched)
                 (priority-schedule-result-category-utilities sched)
                 (hash)))
  (define res-min-floor (max bo-reserved-min (hash-ref cu 'reserved-min-floor 0)))
  (define res-gas-floor (max bo-reserved-gas (hash-ref cu 'reserved-gas-floor 0)))
  (hash 'frame frame
        'race race
        'minerals minerals
        'gas gas
        'supply-used supply-used
        'supply-cap supply-cap
        'bo-goal (or bo-goal-sym 'none)
        'saving-for (if res-cand (priority-candidate-id res-cand) (or bo-goal-sym 'none))
        'reserved-min-floor res-min-floor
        'reserved-gas-floor res-gas-floor
        'scheduled-ids (if (priority-schedule-result? sched)
                           (map priority-candidate-id (priority-schedule-result-scheduled-candidates sched))
                           '())
        'decisions (for/list ([d (in-list trace)])
                     (hash 'rank (priority-decision-entry-rank d)
                           'id (priority-decision-entry-id d)
                           'category (priority-decision-entry-category d)
                           'utility (/ (round (* 10.0 (priority-decision-entry-utility-score d))) 10.0)
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
         #:bo-reserved-gas [bo-reserved-gas 0])
  (define trace (priority-schedule-decision-trace sched))
  (define res-cand (and (priority-schedule-result? sched)
                        (priority-schedule-result-reserved-candidate sched)))
  (define cu (if (priority-schedule-result? sched)
                 (priority-schedule-result-category-utilities sched)
                 (hash)))
  (define res-min-floor (max bo-reserved-min (hash-ref cu 'reserved-min-floor 0)))
  (define res-gas-floor (max bo-reserved-gas (hash-ref cu 'reserved-gas-floor 0)))
  (define saving-id (if res-cand (priority-candidate-id res-cand) (or bo-goal-sym 'none)))
  (define sched-strs
    (for/list ([d (in-list trace)]
               #:when (eq? (priority-decision-entry-outcome d) 'scheduled))
      (format "~a@~a"
              (priority-decision-entry-id d)
              (/ (round (* 10.0 (priority-decision-entry-utility-score d))) 10.0))))
  (define blocked-strs
    (for/list ([d (in-list trace)]
               #:when (memq (priority-decision-entry-outcome d) '(blocked-by-escrow escrowed-saving)))
      (format "~a(~a,u=~a,floor=~aM)"
              (priority-decision-entry-id d)
              (priority-decision-entry-outcome d)
              (/ (round (* 10.0 (priority-decision-entry-utility-score d))) 10.0)
              (priority-decision-entry-applicable-min-floor d))))
  (format "[SCBOT_PRIORITY] f=~a race=~a bank=~aM/~aG sup=~a/~a bo=~a saving_for=~a(floor=~aM/~aG) sched=(~a) escrow_queue=(~a)"
          frame race minerals gas supply-used supply-cap
          (or bo-goal-sym 'none)
          saving-id res-min-floor res-gas-floor
          (string-join sched-strs ",")
          (string-join blocked-strs ",")))

;; =============================================================================
;; 10. Empirical Pro Replay Build-Order Database & Goal-Queue Executor
;;     Loaded from `data/pro_build_orders.sexp` (mined from 1,798 LotV replays)
;; =============================================================================

(require (for-syntax racket/base racket/path))

(define-syntax (compile-time-pro-build-order-db stx)
  (define src (syntax-source stx))
  (define src-dir (if (path? src) (or (path-only src) (current-directory)) (current-directory)))
  (define p (simplify-path (build-path src-dir ".." "data" "pro_build_orders.sexp")))
  (define db
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (and (file-exists? p) (with-input-from-file p read))))
  #`'#,db)

(define COMPILED-PRO-BUILD-ORDER-DB (compile-time-pro-build-order-db))

(define PRO-BUILD-ORDER-DB
  (or COMPILED-PRO-BUILD-ORDER-DB
      (with-handlers ([exn:fail? (lambda (_) '(pro-build-order-database (matchups)))])
        (cond
          [(file-exists? "data/pro_build_orders.sexp")
           (with-input-from-file "data/pro_build_orders.sexp" read)]
          [else '(pro-build-order-database (matchups))]))))

(struct pro-bo-goal
  (kind              ;; 'build | 'expand | 'morph | 'train | 'research
   target-sym        ;; canonical symbol (e.g. 'spawning-pool, 'factory, 'cybernetics-core)
   target-count      ;; cumulative count required to satisfy this step
   min-supply        ;; minimum supply-used before triggering this step
   prereq-ready-sym) ;; prerequisite structure symbol that must be ready (build-progress >= 1.0), or #f
  #:transparent)

(struct pro-bo-eval-result
  (matchup
   active-goal
   ready-actions
   reserved-minerals
   reserved-gas
   target-workers
   target-army-supply)
  #:transparent)

(define (resolve-matchup-symbol race [enemy-race 'Unknown])
  (if (memq race '(ZvZ ZvT ZvP TvZ TvT TvP PvZ PvT PvP))
      race
      (let ([r (normalize-ledger-race race)]
            [er (case enemy-race
                  [(Zerg zerg "Zerg" "zerg") 'Zerg]
                  [(Terran terran "Terran" "terran") 'Terran]
                  [(Protoss protoss "Protoss" "protoss") 'Protoss]
                  [else 'Unknown])])
        (case r
          [(Zerg)
           (case er
             [(Zerg) 'ZvZ]
             [(Terran) 'ZvT]
             [(Protoss) 'ZvP]
             [else 'ZvT])]
          [(Terran)
           (case er
             [(Zerg) 'TvZ]
             [(Terran) 'TvT]
             [(Protoss) 'TvP]
             [else 'TvZ])]
          [else ;; Protoss
           (case er
             [(Zerg) 'PvZ]
             [(Terran) 'PvT]
             [(Protoss) 'PvP]
             [else 'PvT])]))))

(define (find-matchup-entry matchup-sym)
  (define matchups-sec
    (and (pair? PRO-BUILD-ORDER-DB)
         (assq 'matchups (cdr PRO-BUILD-ORDER-DB))))
  (and matchups-sec
       (for/first ([m (in-list (cdr matchups-sec))]
                   #:when (and (pair? m)
                               (eq? (first m) 'matchup)
                               (pair? (cdr m))
                               (eq? (second m) matchup-sym)))
         m)))

(define (select-pro-build-order race [enemy-race 'Unknown])
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (or (find-matchup-entry m-sym)
      (list 'matchup m-sym)))

;; Interpolates the empirical pro winning worker & army supply curve for (race, enemy-race, frame)
(define (pro-supply-curve-target race [enemy-race 'Unknown] [raw-frame 0] [raw-active-bases 1])
  (define frame (safe-nonneg-int raw-frame 0))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define sec (/ (exact->inexact frame) 22.4))
  (define m-entry (select-pro-build-order race enemy-race))
  (define curve-sec
    (and (list? m-entry)
         (for/first ([sub (in-list (cddr m-entry))]
                     #:when (and (pair? sub) (eq? (first sub) 'winning-worker-to-army-supply-curve)))
           (cdr sub))))
  ;; Extract minute -> (workers, army-supply) points or use canonical empirical curve
  (define minute-idx (max 1 (min 7 (add1 (exact-floor (/ sec 60.0))))))
  (define row
    (and curve-sec
         (for/first ([r (in-list curve-sec)]
                     #:when (and (pair? r)
                                 (eq? (first r) 'minute)
                                 (pair? (cdr r))
                                 (= (safe-exact-int (second r) 0) minute-idx)))
           r)))
  (define (row-field sym default)
    (if (and row (list? row))
        (let ([kv (for/first ([x (in-list (cddr row))]
                              #:when (and (pair? x) (eq? (first x) sym) (pair? (cdr x))))
                    (second x))])
          (if kv (safe-real kv default) default))
        default))
  (define curve-workers
    (exact-round (row-field 'workers (* 22.0 (min 4 active-bases)))))
  (define curve-army
    (exact-round (row-field 'army-supply (max 2.0 (* 8.0 minute-idx)))))
  (define base-scaled-workers
    (min 80 (max 22 (* 22 (min 4 active-bases)) curve-workers)))
  (values base-scaled-workers curve-army))

;; Canonical goal-count sequence per matchup derived from `data/pro_build_orders.sexp`
(define (pro-build-order-steps-for-matchup race [enemy-race 'Unknown])
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (case m-sym
    [(ZvZ)
     (list
      (pro-bo-goal 'train 'overlord 2 13 #f)
      (pro-bo-goal 'expand 'hatchery 2 16 #f)
      (pro-bo-goal 'build 'extractor 1 17 #f)
      (pro-bo-goal 'build 'spawning-pool 1 17 #f)
      (pro-bo-goal 'train 'overlord 3 19 #f)
      (pro-bo-goal 'train 'queen 2 20 'spawning-pool)
      (pro-bo-goal 'train 'zergling 6 20 'spawning-pool)
      (pro-bo-goal 'research 'metabolic-boost 1 22 'spawning-pool)
      (pro-bo-goal 'build 'baneling-nest 1 28 'spawning-pool)
      (pro-bo-goal 'expand 'hatchery 3 30 'spawning-pool)
      (pro-bo-goal 'build 'roach-warren 1 36 'spawning-pool)
      (pro-bo-goal 'build 'extractor 2 38 'spawning-pool)
      (pro-bo-goal 'morph 'lair 1 44 'spawning-pool)
      (pro-bo-goal 'build 'evolution-chamber 1 46 'spawning-pool)
      (pro-bo-goal 'build 'extractor 3 50 'lair)
      (pro-bo-goal 'research 'glial-reconstitution 1 52 'lair)
      (pro-bo-goal 'research 'zerg-missile-weapons-1 1 54 'evolution-chamber)
      (pro-bo-goal 'research 'burrow 1 58 'lair)
      (pro-bo-goal 'build 'hydralisk-den 1 62 'lair))]

    [(ZvT ZvP)
     (list
      (pro-bo-goal 'train 'overlord 2 13 #f)
      (pro-bo-goal 'expand 'hatchery 2 16 #f)
      (pro-bo-goal 'build 'extractor 1 17 #f)
      (pro-bo-goal 'build 'spawning-pool 1 17 #f)
      (pro-bo-goal 'train 'overlord 3 19 #f)
      (pro-bo-goal 'train 'queen 2 20 'spawning-pool)
      (pro-bo-goal 'train 'zergling 4 20 'spawning-pool)
      (pro-bo-goal 'research 'metabolic-boost 1 22 'spawning-pool)
      (pro-bo-goal 'expand 'hatchery 3 30 'spawning-pool)
      (pro-bo-goal 'train 'queen 3 32 'spawning-pool)
      (pro-bo-goal 'build 'roach-warren 1 36 'spawning-pool)
      (pro-bo-goal 'build 'baneling-nest 1 38 'spawning-pool)
      (pro-bo-goal 'build 'extractor 2 40 'spawning-pool)
      (pro-bo-goal 'build 'extractor 3 44 'spawning-pool)
      (pro-bo-goal 'morph 'lair 1 46 'spawning-pool)
      (pro-bo-goal 'build 'evolution-chamber 1 48 'spawning-pool)
      (pro-bo-goal 'research 'glial-reconstitution 1 54 'lair)
      (pro-bo-goal 'research 'centrifical-hooks 1 56 'lair)
      (pro-bo-goal 'research 'zerg-missile-weapons-1 1 58 'evolution-chamber)
      (pro-bo-goal 'build 'hydralisk-den 1 62 'lair)
      (pro-bo-goal 'build 'extractor 4 64 'lair)
      (pro-bo-goal 'research 'grooved-spines 1 68 'hydralisk-den))]

    [(TvZ TvT TvP)
     (list
      (pro-bo-goal 'build 'supply-depot 1 14 #f)
      (pro-bo-goal 'build 'barracks 1 16 'supply-depot)
      (pro-bo-goal 'build 'refinery 1 16 'supply-depot)
      (pro-bo-goal 'morph 'orbital-command 1 19 'barracks)
      (pro-bo-goal 'expand 'command-center 2 20 #f)
      (pro-bo-goal 'build 'supply-depot 2 21 'barracks)
      (pro-bo-goal 'research 'stimpack 1 21 'barracks-techlab)
      (pro-bo-goal 'build 'factory 1 21 'barracks)
      (pro-bo-goal 'build 'barracks-techlab 1 21 'barracks)
      (pro-bo-goal 'build 'refinery 2 22 'barracks)
      (pro-bo-goal 'morph 'orbital-command 2 26 'barracks)
      (pro-bo-goal 'build 'starport 1 28 'factory)
      (pro-bo-goal 'build 'factory-techlab 1 30 'factory)
      (pro-bo-goal 'build 'barracks 2 32 'barracks)
      (pro-bo-goal 'build 'barracks 3 36 'barracks)
      (pro-bo-goal 'build 'barracks-reactor 1 36 'barracks)
      (pro-bo-goal 'build 'starport-reactor 1 38 'starport)
      (pro-bo-goal 'research 'combat-shield 1 40 'barracks-techlab)
      (pro-bo-goal 'build 'engineering-bay 1 44 'barracks)
      (pro-bo-goal 'build 'refinery 3 46 'factory)
      (pro-bo-goal 'research 'terran-infantry-weapons-1 1 48 'engineering-bay)
      (pro-bo-goal 'expand 'command-center 3 52 'starport)
      (pro-bo-goal 'research 'concussive-shells 1 56 'barracks-techlab)
      (pro-bo-goal 'build 'armory 1 60 'factory))]

    [else ;; PvZ, PvT, PvP
     (list
      (pro-bo-goal 'build 'pylon 1 14 #f)
      (pro-bo-goal 'build 'gateway 1 16 'pylon)
      (pro-bo-goal 'build 'assimilator 1 16 'pylon)
      (pro-bo-goal 'expand 'nexus 2 19 #f)
      (pro-bo-goal 'build 'cybernetics-core 1 19 'gateway)
      (pro-bo-goal 'build 'assimilator 2 21 'cybernetics-core)
      (pro-bo-goal 'build 'pylon 2 21 'cybernetics-core)
      (pro-bo-goal 'research 'warp-gate-research 1 22 'cybernetics-core)
      (pro-bo-goal 'train 'stalker 2 23 'cybernetics-core)
      (pro-bo-goal 'build 'robotics-facility 1 26 'cybernetics-core)
      (pro-bo-goal 'build 'twilight-council 1 28 'cybernetics-core)
      (pro-bo-goal 'build 'gateway 2 30 'cybernetics-core)
      (pro-bo-goal 'build 'gateway 3 32 'cybernetics-core)
      (pro-bo-goal 'train 'immortal 1 34 'robotics-facility)
      (pro-bo-goal 'train 'observer 1 36 'robotics-facility)
      (pro-bo-goal 'research 'charge 1 38 'twilight-council)
      (pro-bo-goal 'build 'assimilator 3 42 'robotics-facility)
      (pro-bo-goal 'build 'forge 1 48 'cybernetics-core)
      (pro-bo-goal 'research 'protoss-ground-weapons-1 1 52 'forge)
      (pro-bo-goal 'build 'robotics-bay 1 56 'robotics-facility)
      (pro-bo-goal 'expand 'nexus 3 60 'robotics-facility)
      (pro-bo-goal 'research 'extended-thermal-lance 1 64 'robotics-bay))]))

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
         #:third-y [raw-third-y 40.5])
  (define race (normalize-ledger-race raw-race))
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (define supply-used (safe-nonneg-int raw-supply-used 12))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define base-x (safe-tile-coord raw-base-x 32.5))
  (define base-y (safe-tile-coord raw-base-y 32.5))
  (define nat-x (safe-tile-coord raw-nat-x 50.5))
  (define nat-y (safe-tile-coord raw-nat-y 50.5))
  (define third-x (safe-tile-coord raw-third-x 60.5))
  (define third-y (safe-tile-coord raw-third-y 40.5))
  (define-values (target-workers target-army)
    (pro-supply-curve-target race enemy-race raw-frame active-bases))

  (define all-upgs
    (append (if (list? researched-upgrades) researched-upgrades '())
            (if (list? pending-upgrades) pending-upgrades '())))

  (define (count-total-bldg sym)
    (case sym
      [(hatchery)
       (+ (hash-ref total-bldg-counts 'hatchery 0)
          (hash-ref total-bldg-counts 'lair 0)
          (hash-ref total-bldg-counts 'hive 0))]
      [(lair)
       (+ (hash-ref total-bldg-counts 'lair 0)
          (hash-ref total-bldg-counts 'hive 0))]
      [(spire)
       (+ (hash-ref total-bldg-counts 'spire 0)
          (hash-ref total-bldg-counts 'greater-spire 0))]
      [(command-center)
       (+ (hash-ref total-bldg-counts 'command-center 0)
          (hash-ref total-bldg-counts 'orbital-command 0)
          (hash-ref total-bldg-counts 'planetary-fortress 0))]
      [(orbital-command)
       (+ (hash-ref total-bldg-counts 'orbital-command 0)
          (hash-ref total-bldg-counts 'planetary-fortress 0))]
      [(supply-depot)
       (+ (hash-ref total-bldg-counts 'supply-depot 0)
          (hash-ref total-bldg-counts 'supply-depot-lowered 0))]
      [(barracks-techlab barracks-tech-lab)
       (+ (hash-ref total-bldg-counts 'barracks-techlab 0)
          (hash-ref total-bldg-counts 'barracks-tech-lab 0))]
      [(factory-techlab factory-tech-lab)
       (+ (hash-ref total-bldg-counts 'factory-techlab 0)
          (hash-ref total-bldg-counts 'factory-tech-lab 0))]
      [(starport-techlab starport-tech-lab)
       (+ (hash-ref total-bldg-counts 'starport-techlab 0)
          (hash-ref total-bldg-counts 'starport-tech-lab 0))]
      [(starport-reactor)
       (+ (hash-ref total-bldg-counts 'starport-reactor 0)
          (hash-ref total-bldg-counts 'starport-techlab 0)
          (hash-ref total-bldg-counts 'starport-tech-lab 0))]
      [(gateway)
       (+ (hash-ref total-bldg-counts 'gateway 0)
          (hash-ref total-bldg-counts 'warp-gate 0)
          (hash-ref total-bldg-counts 'warpgate 0))]
      [(robotics-bay robotics-support-bay)
       (+ (hash-ref total-bldg-counts 'robotics-bay 0)
          (hash-ref total-bldg-counts 'robotics-support-bay 0))]
      [(templar-archives templar-archive)
       (+ (hash-ref total-bldg-counts 'templar-archives 0)
          (hash-ref total-bldg-counts 'templar-archive 0))]
      [else
       (hash-ref total-bldg-counts sym 0)]))

  (define (prereq-ready? prereq-sym)
    (cond
      [(not prereq-sym) #t]
      [(eq? prereq-sym 'spawning-pool)
       (> (hash-ref ready-bldg-counts 'spawning-pool 0) 0)]
      [(eq? prereq-sym 'lair)
       (> (+ (hash-ref ready-bldg-counts 'lair 0)
             (hash-ref ready-bldg-counts 'hive 0))
          0)]
      [(eq? prereq-sym 'supply-depot)
       (> (+ (hash-ref ready-bldg-counts 'supply-depot 0)
             (hash-ref ready-bldg-counts 'supply-depot-lowered 0))
          0)]
      [(memq prereq-sym '(barracks-techlab barracks-tech-lab))
       (> (+ (hash-ref ready-bldg-counts 'barracks-techlab 0)
             (hash-ref ready-bldg-counts 'barracks-tech-lab 0))
          0)]
      [(memq prereq-sym '(factory-techlab factory-tech-lab))
       (> (+ (hash-ref ready-bldg-counts 'factory-techlab 0)
             (hash-ref ready-bldg-counts 'factory-tech-lab 0))
          0)]
      [(memq prereq-sym '(starport-techlab starport-tech-lab))
       (> (+ (hash-ref ready-bldg-counts 'starport-techlab 0)
             (hash-ref ready-bldg-counts 'starport-tech-lab 0))
          0)]
      [(eq? prereq-sym 'gateway)
       (> (+ (hash-ref ready-bldg-counts 'gateway 0)
             (hash-ref ready-bldg-counts 'warp-gate 0)
             (hash-ref ready-bldg-counts 'warpgate 0))
          0)]
      [(memq prereq-sym '(robotics-bay robotics-support-bay))
       (> (+ (hash-ref ready-bldg-counts 'robotics-bay 0)
             (hash-ref ready-bldg-counts 'robotics-support-bay 0))
          0)]
      [else
       (> (hash-ref ready-bldg-counts prereq-sym 0) 0)]))

  (define (goal-satisfied? g)
    (match-define (pro-bo-goal kind sym tgt-cnt _ _) g)
    (case kind
      [(build expand morph)
       (>= (count-total-bldg sym) tgt-cnt)]
      [(train)
       (>= (hash-ref unit-counts sym 0) tgt-cnt)]
      [(research)
       (not (not (memq sym all-upgs)))]
      [else #t]))

  (define (goal->action g)
    (match-define (pro-bo-goal kind sym tgt-cnt _ _) g)
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
       (list 'build sym)]))

  (define steps (pro-build-order-steps-for-matchup race enemy-race))
  (define rem-min (safe-nonneg-int raw-minerals 0))
  (define rem-gas (safe-nonneg-int raw-gas 0))
  (define rem-sup (max 0 (safe-exact-int raw-supply-left 0)))
  (define ready-acts '())
  (define active-head #f)
  (define res-min 0)
  (define res-gas 0)

  (for ([g (in-list steps)]
        #:when (and (not (goal-satisfied? g))
                    (>= supply-used (pro-bo-goal-min-supply g))))
    (define sym (pro-bo-goal-target-sym g))
    (define kind (pro-bo-goal-kind g))
    (define m-cost (sc2-min-cost sym))
    (define g-cost (sc2-gas-cost sym))
    (define s-cost (if (eq? kind 'train) (sc2-supply-cost sym 0) 0))
    (define pre-ok? (prereq-ready? (pro-bo-goal-prereq-ready-sym g)))
    (cond
      [(and pre-ok?
            (>= (- rem-min res-min) m-cost)
            (>= (- rem-gas res-gas) g-cost)
            (or (<= s-cost 0) (>= rem-sup s-cost))
            ;; Only emit at most 2 build/research/expand actions per frame from BO queue
            (< (length ready-acts) 2))
       (set! rem-min (- rem-min m-cost))
       (set! rem-gas (- rem-gas g-cost))
       (set! rem-sup (- rem-sup s-cost))
       (set! ready-acts (cons (goal->action g) ready-acts))
       (unless active-head (set! active-head g))]
      [pre-ok?
       ;; Prerequisite is ready, but waiting on resources -> reserve minerals/gas for first waiting step
       (unless active-head
         (set! active-head g)
         (when (memq kind '(build expand morph research train))
           (set! res-min m-cost)
           (set! res-gas g-cost)))]
      [else
       ;; Prerequisite building is still under construction -> do NOT emit or block worker production
       (unless active-head
         (set! active-head g))]))

  (pro-bo-eval-result m-sym
                      active-head
                      (reverse ready-acts)
                      res-min
                      res-gas
                      target-workers
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

  (cond
    ;; Never hold macro bank when fighting an early/mid-game survival crisis
    [(and under-attack? (< supply-used 90))
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
        (race-bank-target race (* eff-l 100) (* eff-l 100)
                          'zerg-muta-corruptor-larva-surge
                          'spire-morph-wave
                          #t)]
       [(or (memq 'ultralisk-cavern pending-syms)
            (memq 'lurker-den pending-syms)
            (and (or (memq 'ultralisk-cavern ready-syms) (memq 'lurker-den ready-syms))
                 (>= larva-cnt 4)
                 (>= supply-used 100)))
        (define eff-l (max 3 (min 6 (if (> larva-cnt 0) larva-cnt 4))))
        (race-bank-target race (* eff-l 150) (* eff-l 100)
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
            (and (memq 'fusion-core ready-syms) (>= supply-used 110)))
        (race-bank-target race 400 300
                          'terran-capital-wave-sync
                          'battlecruiser-liberator-wave
                          #t)]
       [(and (>= prod-cnt 3) (>= supply-used 48))
        (define eff-p (min 8 prod-cnt))
        (race-bank-target race (* eff-p 100) (* eff-p 50)
                          'terran-production-wave-sync
                          'multi-facility-cycle-sync
                          #t)]
       [else
        (race-bank-target race 0 0 'none 'steady-macro-spend #f)])]

    ;; Protoss: Warp-Gate cooldown batching & Robotics/Fleet capital surge banking
    [else
     (cond
       [(or (memq 'fleet-beacon pending-syms)
            (memq 'robotics-bay pending-syms)
            (memq 'templar-archive pending-syms)
            (memq 'templar-archives pending-syms)
            (and (or (memq 'fleet-beacon ready-syms)
                     (memq 'robotics-bay ready-syms)
                     (memq 'templar-archive ready-syms))
                 (>= supply-used 100)))
        (define eff-wg (max 3 (min 8 wg-cnt)))
        (race-bank-target race (+ 200 (* eff-wg 100)) 300
                          'protoss-capital-warpgate-batch
                          'capital-splash-and-warpin-batch
                          #t)]
       [(and (>= wg-cnt 3) (>= supply-used 38))
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
  (define res-tech-min (if (and (symbol? tech-goal-sym) (not tech-blocked?) (not under-attack?))
                           (min 200 tech-min-cost)
                           0))
  (define res-tech-gas (if (and (symbol? tech-goal-sym) (not tech-blocked?) (not under-attack?))
                           tech-gas-cost
                           0))
  (define res-upg-gas  (if (and (symbol? upgrade-goal-sym) (not upg-blocked?) (not under-attack?))
                           upg-gas-cost
                           0))

  (define hard-res-min (+ res-supply-min res-worker-min res-expand-min res-def-min))
  (define hard-res-gas (+ res-tech-gas res-upg-gas))

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
      (define own-rm (stream-budget-slice-reserved-minerals (hash-ref slices-ht s)))
      (define own-rg (stream-budget-slice-reserved-gas (hash-ref slices-ht s)))
      ;; Survival streams (`supply`, `workers`, `static-defense`, `expansion`) spend against their own floor;
      ;; downstream streams (`production-facilities`, `army`, `upgrades`, `tech`) respect higher survival floors
      ;; while blocked `tech`/`upgrades` never subtract from `workers`/`supply`/`expansion`/`army`!
      (define other-hard-min
        (case s
          [(supply) 0]
          [(workers) res-supply-min]
          [(static-defense) res-supply-min]
          [(expansion) (+ res-supply-min res-def-min)]
          [else (max 0 (- hard-res-min own-rm))]))
      (define other-hard-gas
        (case s
          [(tech) 0]
          [(upgrades) res-tech-gas]
          [(army) (if under-attack? 0 (max 0 (- hard-res-gas own-rg)))]
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

(define (extract-record-sym rec)
  (cond
    [(hash? rec)
     (define t (hash-ref rec 'type 'unknown))
     (cond
       [(symbol? t) t]
       [(string? t) (string->symbol (string-downcase t))]
       [else 'unknown])]
    [(symbol? rec) rec]
    [else 'unknown]))

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

  (define has-pending-spore-overcap?
    (and (eq? race 'Zerg)
         (>= supply-used 200)
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
                                  (let ([bp (hash-ref b 'build-progress 1.0)])
                                    (or (not (real? bp)) (>= bp 0.99))))))
         (extract-record-sym b)))
     (define has-bldg-info? (not (null? ally-bldgs)))
     (define (bldg-ready-or-assumed? sym)
       (or (not has-bldg-info?)
           (not (not (memq sym ready-bldg-syms)))))

     ;; 1. Fist of Neeb: Convert surplus late-game mineral bank (>= 600M at >= 194/200)
     ;;    into 0-supply forward static defense batteries / Planetary Fortresses!
     (define def-x third-x)
     (define def-y third-y)
     (define def-x2 (safe-tile-coord (min 248.0 (+ def-x 2.0)) def-x))
     (define neeb-acts
       (cond
         [(< minerals 600) '()]
         [(eq? race 'Protoss)
          (define p1
            (if (bldg-ready-or-assumed? 'forge)
                (list (list 'build 'photon-cannon def-x def-y))
                (list (list 'build 'pylon def-x def-y))))
          (define p2
            (if (and (>= minerals 750) (bldg-ready-or-assumed? 'cybernetics-core))
                (list (list 'build 'shield-battery def-x2 def-y))
                '()))
          (append p1 p2)]
         [(eq? race 'Terran)
          (define t1
            (if (bldg-ready-or-assumed? 'engineering-bay)
                (list (list 'build 'missile-turret def-x def-y))
                '()))
          (define t2
            (cond
              [(and (>= minerals 900)
                    (bldg-ready-or-assumed? 'engineering-bay)
                    (memq 'command-center ready-bldg-syms))
               (list '(morph planetary-fortress))]
              [(and (>= minerals 750) (bldg-ready-or-assumed? 'barracks))
               (list (list 'build 'bunker def-x2 def-y))]
              [else '()]))
          (append t1 t2)]
         [else ;; Zerg
          (if (bldg-ready-or-assumed? 'spawning-pool)
              (list (list 'build 'spine-crawler def-x def-y)
                    (list 'build 'spore-crawler def-x2 def-y))
              '())]))

     ;; 2. Zerg Spore Crawler Trick (`204/200` Supply Overcap):
     ;;    - If temporary in-progress `spore-crawler`s exist while `supply-used >= 200`,
     ;;      cancel them (`cancel-building`) to pop Drones above the 200/200 cap (`202..204/200`)!
     ;;    - Otherwise at `198..200 / 200` with `minerals >= 350` and Pool ready, morph temporary
     ;;      Spores to dip to `196..198/200` and queue high-tier units into the freed supply!
     (define pending-spores
       (filter (lambda (b)
                 (and (hash? b)
                      (eq? (extract-record-sym b) 'spore-crawler)
                      (let ([bp (hash-ref b 'build-progress 1.0)]
                            [bid (hash-ref b 'id 0)])
                        (and (real? bp) (< bp 0.95) (exact-integer? bid) (> bid 0)))))
               ally-bldgs))
     (define zerg-overcap-unit
       (cond
         [(and (bldg-ready-or-assumed? 'ultralisk-cavern) (>= gas 200)) 'ultralisk]
         [(and (or (bldg-ready-or-assumed? 'spire) (bldg-ready-or-assumed? 'greater-spire)) (>= gas 150)) 'corruptor]
         [(bldg-ready-or-assumed? 'roach-warren) 'roach]
         [else 'drone]))
     (define spore-acts
       (cond
         [(not (eq? race 'Zerg)) '()]
         [(and (>= supply-used 200) (not (null? pending-spores)))
          (for/list ([sp (in-list (take pending-spores (min 4 (length pending-spores))))])
            (list 'cancel-building (hash-ref sp 'id)))]
         [(and (>= supply-used 198)
               (>= supply-cap 200)
               (>= minerals 350)
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
