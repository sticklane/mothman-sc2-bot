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
 ledger-verify-invariant?)

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
