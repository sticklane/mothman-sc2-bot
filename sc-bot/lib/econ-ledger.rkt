#lang racket/base

(require racket/match
         racket/list
         racket/math
         "../compiler/syntax.rkt")

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
 evaluate-guns-vs-butter-ppf)

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

(struct boss-plan (race goal-units steps makespan-frames total-minerals total-gas)
  #:transparent)

(define (unit-prereq-building u)
  (case u
    [(zergling queen) 'spawning-pool]
    [(roach ravager) 'roach-warren]
    [(hydralisk lurker) 'hydralisk-den]
    [(mutalisk corruptor) 'spire]
    [(zealot) 'gateway]
    [(dragoon stalker sentry) 'cybernetics-core]
    [(reaver immortal colossus observer shuttle) 'robotics-facility]
    [(marine marauder medic) 'barracks]
    [(siege-tank vulture hellion) 'factory]
    [(science-vessel medivac viking) 'starport]
    [(ghost) 'covert-ops]
    [else #f]))

(define (boss-synthesize-build-plan race goal-alist #:existing-buildings [existing '()])
  ;; goal-alist: list of `(cons unit-type count)`
  (define needed-prereqs
    (remove-duplicates
     (filter (lambda (b) (and b (not (memq b existing))))
             (map (lambda (pair) (unit-prereq-building (car pair))) goal-alist))))
  (define prereq-steps
    (for/list ([b (in-list needed-prereqs)])
      (list 'build b)))
  (define unit-steps
    (append-map
     (lambda (pair)
       (make-list (cdr pair) (list 'train (car pair))))
     goal-alist))
  (define all-steps (append prereq-steps unit-steps))
  (define g (derive-grades-from-bot-ast all-steps))
  ;; Makespan lower-bounded by prerequisite build frames + parallel production cycles
  (define makespan
    (+ (* 360 (length prereq-steps))
       (* 120 (length unit-steps))))
  (boss-plan race
             goal-alist
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

(define (make-symbiotic-ledger [minerals 500] [gas 200] [supply 10])
  (symbiotic-ledger minerals gas supply 0 0 0 0 0 0 '()))

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

(define (ledger-reserve! l lease-id owner m g s [priority 1])
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
(define (ledger-borrow! l borrower-id m g s [priority 5])
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

(define (ledger-preempt-for-crisis! l crisis-id m g s [priority 10])
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
         #:frame [frame 0]
         #:minerals [minerals 200]
         #:gas [gas 100]
         #:supply-left [supply-left 4]
         #:active-bases [active-bases 1]
         #:depleting-bases [depleting-bases 0]
         #:workers [workers 12]
         #:pending-workers [pending-workers 0]
         #:production-facilities [production-facilities 1]
         #:busy-facilities [busy-facilities 0]
         #:busy-townhalls [busy-townhalls 0]
         #:under-crisis? [under-crisis? #f]
         #:recommended-min-bases [recommended-min-bases 1]
         #:max-map-bases [max-map-bases 16])
  (define eff-bases (max 1 active-bases))
  (define healthy-bases (max 0 (- eff-bases depleting-bases)))
  (define total-workers (+ workers pending-workers))
  (define base-cost (if (memq race '(Zerg zerg)) 300 400))

  ;; Unconstrained map-wide expansion target: scales up to max-map-bases (default 16)
  ;; whenever workers saturate healthy bases, bases deplete, minerals float, or
  ;; Mirror-Mind recommends out-expanding the opponent.
  (define time-bases (add1 (quotient (max 0 frame) 2200)))
  (define saturation-bases
    (if (>= total-workers (* 18 (max 1 healthy-bases)))
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

  ;; Target workers coupled to healthy + desired bases (22 per active/desired base, up to 80)
  (define target-workers
    (min 80 (max 22 (* 22 (min 4 (max healthy-bases desired-bases))))))

  (define should-expand?
    (and (not under-crisis?)
         (or (> depleting-bases 0)
             (> desired-bases eff-bases))))

  (define expansion-reason
    (cond
      [under-crisis?                           'crisis-hold-expansion]
      [(> depleting-bases 0)                   'depletion-replacement-expand]
      [(>= total-workers (* 18 (max 1 healthy-bases))) 'macro-saturation-expand]
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
                 reaver roach ravager lurker ultralisk)))
     'armored-mech-siege]
    [else
     'bio-swarm-light]))

(define (evaluate-adaptive-build-and-tech-plan
         race
         #:ally-buildings [ally-buildings '()]
         #:ally-units [ally-units '()]
         #:researched-upgrades [researched-upgrades '()]
         #:enemy-archetype [enemy-archetype 'standard-macro]
         #:mirror-predicted-unit [mirror-predicted-unit 'marine]
         #:mirror-macro-verdict [mirror-macro-verdict 'pace-Macro-And-Disrupt]
         #:requires-detection? [requires-detection? #f]
         #:requires-anti-air? [requires-anti-air? #f]
         #:enemy-upgrade-advantage [enemy-upgrade-advantage 0]
         #:minerals [minerals 300]
         #:gas [gas 150])
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
          '(zergling-movementspeed burrow glial-reconstitution grooved-spines lurker-aspect missile-attacks-1 ground-carapace-1)]
         [else
          '(zergling-movementspeed burrow centrifugal-hooks glial-reconstitution chitinous-plating missile-attacks-1 ground-carapace-1)]))
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
         #:frame [frame 0]
         #:minerals [minerals 200]
         #:gas [gas 0]
         #:workers [workers 16]
         #:active-bases [active-bases 1]
         #:active-geysers [active-geysers 1]
         #:current-gas-workers [current-gas-workers 3]
         #:should-expand? [should-expand? #f]
         #:escrow-minerals [escrow-minerals 0]
         #:tech-gas-demand [tech-gas-demand 100]
         #:unit-gas-ratio [unit-gas-ratio 0.35]
         #:under-crisis? [under-crisis? #f])
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
         #:frame [frame 0]
         #:minerals [minerals 200]
         #:gas [gas 100]
         #:supply-left [supply-left 6]
         #:supply-cap [supply-cap 22]
         #:workers [workers 16]
         #:target-workers [target-workers 44]
         #:active-bases [active-bases 1]
         #:depleting-bases [depleting-bases 0]
         #:active-geysers [active-geysers 1]
         #:current-gas-workers [current-gas-workers 3]
         #:production-facilities [production-facilities 1]
         #:busy-facilities [busy-facilities 0]
         #:army-count [army-count 4]
         #:missing-synergy-count [missing-synergy-count 2]
         #:fap-score [fap-score 0]
         #:under-crisis? [under-crisis? #f]
         #:mirror-macro-verdict [mirror-macro-verdict 'pace-Macro-And-Disrupt]
         #:enemy-upgrade-advantage [enemy-upgrade-advantage 0]
         #:enemy-active-research-count [enemy-active-research-count 0]
         #:requires-detection? [requires-detection? #f]
         #:requires-anti-air? [requires-anti-air? #f])
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

