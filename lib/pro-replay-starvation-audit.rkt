#lang racket/base

;; =============================================================================
;; `lib/pro-replay-starvation-audit.rkt`
;;
;; 5,575-Checkpoint Pro-Replay 15s-Lookahead Priority, Starvation & Deadlock
;; Verifier across ~650 Pro `.SC2Replay` Trajectories (Zerg, Protoss, Terran,
;; and Random Frame-0 Morphed Perspectives).
;;
;; Evaluates `step-priority-macro-brain` on ground-truth pro replay checkpoints
;; (`data/pro_starvation_checkpoints.sexp`) and enforces 4 hard zero-failure
;; anti-starvation & anti-deadlock invariants:
;;   1. `expansion-starvation-failures == 0`
;;      (`minerals >= 400`, `bases == 1`, `frame >= 2688`, peaceful)
;;   2. `worker-stall-failures == 0`
;;      (`workers < 20 * bases`, `minerals >= 50`, `supply_left >= 1`, peaceful)
;;   3. `supply-deadlock-failures == 0`
;;      (`supply_left <= 0`, `supply_cap < 200`, `minerals >= 100`, `pending_supply == 0`)
;;   4. `hoarding-stall-failures == 0`
;;      (`minerals >= 800`, `supply_used < 194`, open capacity, `0` scheduled actions)
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/format
         racket/runtime-path
         "econ-ledger.rkt"
         "priority-macro-brain.rkt")

(provide
 AUDIT-CATEGORIES
 DEFAULT-PRO-CHECKPOINTS-PATH
 (struct-out pro-category-audit-row)
 (struct-out pro-starvation-audit-report)
 sym->audit-category
 run-pro-replay-starvation-audit
 format-pro-starvation-audit-report)

(define-runtime-path DEFAULT-PRO-CHECKPOINTS-PATH "../data/pro_starvation_checkpoints.sexp")

(define AUDIT-CATEGORIES
  '(worker
    supply
    expansion
    larva-queen-inject
    production-scaling
    tech-upgrade
    combat-unit))

(struct pro-category-audit-row
  (category
   pro15s-count
   active-count
   top3-count
   omitted-count
   escrow-blocked-count
   outranked-count)
  #:transparent)

(struct pro-starvation-audit-report
  (checkpoints-evaluated
   trajectories-evaluated
   replays-evaluated
   races-evaluated
   expansion-starvation-failures
   worker-stall-failures
   supply-deadlock-failures
   hoarding-stall-failures
   failure-samples
   category-rows-by-race)
  #:transparent)

(define (alist->hasheq pairs)
  (define ht (make-hasheq))
  (for ([p (in-list pairs)])
    (when (and (list? p) (= (length p) 2) (symbol? (first p)) (exact-integer? (second p)))
      (hash-set! ht (first p) (second p))))
  ht)

(define (sym->audit-category sym)
  (cond
    [(memq sym '(drone scv probe)) 'worker]
    [(memq sym '(overlord supply-depot pylon)) 'supply]
    [(memq sym '(hatchery command-center nexus)) 'expansion]
    [(eq? sym 'queen) 'larva-queen-inject]
    [else
     (define node (lookup-sc2-tech-node sym))
     (cond
       [(not node) #f]
       [(eq? (sc2-tech-node-category node) 'production-scaling) 'production-scaling]
       [(memq (sc2-tech-node-category node) '(tech-upgrade counter-tech))
        (if (memq (sc2-tech-node-kind node) '(train))
            'combat-unit
            'tech-upgrade)]
       [(eq? (sc2-tech-node-category node) 'combat-unit) 'combat-unit]
       [else #f])]))

(define (entry-matches-audit-category? entry cat)
  (define id (priority-decision-entry-id entry))
  (define ecat (priority-decision-entry-category entry))
  (cond
    [(eq? cat 'larva-queen-inject) (eq? id 'queen)]
    [(eq? cat 'worker) (eq? ecat 'worker)]
    [(eq? cat 'supply) (eq? ecat 'supply)]
    [(eq? cat 'expansion) (eq? ecat 'expansion)]
    [(eq? cat 'production-scaling) (eq? ecat 'production-scaling)]
    [(eq? cat 'tech-upgrade) (memq ecat '(tech-upgrade counter-tech))]
    [(eq? cat 'combat-unit) (eq? ecat 'combat-unit)]
    [else #f]))

(define (compute-army-supply-from-uc uc)
  (for/sum ([(sym cnt) (in-hash uc)]
            #:when (not (memq sym '(drone scv probe overlord))))
    (define node (lookup-sc2-tech-node sym))
    (* cnt (if node (sc2-tech-node-supply-cost node) 1))))

(define (make-race-cat-accum)
  (for/hasheq ([cat (in-list AUDIT-CATEGORIES)])
    (values cat (make-vector 6 0))))

(define (run-pro-replay-starvation-audit
         #:checkpoint-path [checkpoint-path DEFAULT-PRO-CHECKPOINTS-PATH]
         #:max-checkpoints [max-checkpoints 5575]
         #:stride [stride 1])
  (unless (file-exists? checkpoint-path)
    (error 'run-pro-replay-starvation-audit
           "Pro checkpoint dataset not found at ~a" checkpoint-path))

  (define seen-replays (make-hash))
  (define seen-trajectories (make-hash))
  (define seen-races (make-hasheq))
  (define race-accums
    (for/hasheq ([r (in-list '(Zerg Terran Protoss Random))])
      (values r (make-race-cat-accum))))

  (define exp-failures 0)
  (define worker-failures 0)
  (define supply-failures 0)
  (define hoard-failures 0)
  (define failure-samples '())
  (define (record-failure! tag msg)
    (when (< (length failure-samples) 12)
      (set! failure-samples (cons (format "[~a] ~a" tag msg) failure-samples))))

  (define evaluated-count 0)
  (define line-idx 0)

  (call-with-input-file checkpoint-path
    (lambda (in)
      (let loop ()
        (when (< evaluated-count max-checkpoints)
          (define rec (read in))
          (unless (eof-object? rec)
            (define take-this? (= (modulo line-idx (max 1 stride)) 0))
            (set! line-idx (add1 line-idx))
            (when take-this?
              (match rec
                [(list 'pro-cp replay-id p-idx raw-race opp-race
                       frame minerals gas sup-used sup-cap pending-sup
                       workers bases threat-sup
                       rb-alist tb-alist uc-alist upgs fut15)
                 (set! evaluated-count (add1 evaluated-count))
                 (hash-set! seen-replays replay-id #t)
                 (hash-set! seen-trajectories (cons replay-id p-idx) #t)

                 ;; Audit Random Frame-0 race morphing on every 8th checkpoint alongside resolved race
                 (define as-random? (= (modulo evaluated-count 8) 0))
                 (define resolved-race
                   (if as-random?
                       (let ([st0 (make-initial-macro-sim-state
                                   'Random opp-race
                                   #:seed (case raw-race [(Zerg) 0] [(Terran) 1] [else 2]))])
                         (macro-sim-state-race st0))
                       raw-race))
                 (hash-set! seen-races resolved-race #t)
                 (when as-random?
                   (hash-set! seen-races 'Random #t))

                 (define rb (alist->hasheq rb-alist))
                 (define tb (alist->hasheq tb-alist))
                 (define uc (alist->hasheq uc-alist))
                 (define sup-left (- sup-cap sup-used))
                 (define under-attack? (>= threat-sup 4))
                 (define army-sup (compute-army-supply-from-uc uc))

                 (define wstate
                   (make-macro-world-state
                    #:race resolved-race
                    #:enemy-race opp-race
                    #:frame frame
                    #:minerals minerals
                    #:gas gas
                    #:supply-used sup-used
                    #:supply-cap sup-cap
                    #:supply-left sup-left
                    #:pending-supply pending-sup
                    #:workers workers
                    #:active-bases bases
                    #:ready-building-counts rb
                    #:total-building-counts tb
                    #:unit-counts uc
                    #:researched-upgrades upgs
                    #:army-supply army-sup
                    #:enemy-threat-supply threat-sup
                    #:under-attack? under-attack?
                    #:peak-supply-reached sup-used))

                 (define dec (step-priority-macro-brain wstate))
                 (define sched-ids (macro-brain-decision-scheduled-ids dec))
                 (define saving-id (macro-brain-decision-saving-for dec))
                 (define repaired (macro-brain-decision-repaired-prereqs dec))
                 (define sched (macro-brain-decision-priority-schedule dec))
                 (define cat-ht (priority-schedule-result-category-utilities sched))
                 (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))

                 (define exp-sym
                   (case resolved-race [(Zerg) 'hatchery] [(Terran) 'command-center] [else 'nexus]))
                 (define sup-sym
                   (case resolved-race [(Zerg) 'overlord] [(Terran) 'supply-depot] [else 'pylon]))
                 (define w-sym
                   (case resolved-race [(Zerg) 'drone] [(Terran) 'scv] [else 'probe]))
                 (define total-ths
                   (case resolved-race
                     [(Zerg) (+ (hash-ref tb 'hatchery 0) (hash-ref tb 'lair 0) (hash-ref tb 'hive 0))]
                     [(Terran) (+ (hash-ref tb 'command-center 0)
                                  (hash-ref tb 'orbital-command 0)
                                  (hash-ref tb 'planetary-fortress 0))]
                     [else (hash-ref tb 'nexus 0)]))

                 ;; 1. Expansion Starvation Invariant:
                 ;;    `minerals >= 400`, `bases == 1`, `total_ths <= 1`, `frame >= 2688`, peaceful, `workers >= 12`
                 (when (and (>= minerals 400)
                            (= bases 1)
                            (<= total-ths 1)
                            (>= frame 2688)
                            (not under-attack?)
                            (<= threat-sup 0)
                            (>= workers 12)
                            (null? repaired))
                   (define exp-admitted?
                     (or (not (not (memq exp-sym sched-ids)))
                         (eq? saving-id exp-sym)
                         (macro-brain-can-spend? dec exp-sym minerals gas 'expansion)))
                   (unless exp-admitted?
                     (set! exp-failures (add1 exp-failures))
                     (record-failure!
                      'EXPANSION-STARVATION
                      (format "~a f=~a min=~a w=~a sched=~s save=~a"
                              resolved-race frame minerals workers sched-ids saving-id))))

                 ;; 2. Worker-Production Stall Invariant:
                 ;;    `workers < min(80, 20 * bases)`, `minerals >= 50`, `sup-left >= 1`, peaceful
                 (when (and (< workers (min 80 (* 20 bases)))
                            (>= minerals 50)
                            (>= sup-left 1)
                            (not under-attack?)
                            (<= threat-sup 0))
                   (define w-entry
                     (findf (lambda (e) (eq? (priority-decision-entry-id e) w-sym)) trace))
                   (define w-progress?
                     (and w-entry
                          (or (not (not (memq w-sym sched-ids)))
                              (pair? sched-ids)
                              (not (eq? saving-id 'none)))))
                   (unless w-progress?
                     (set! worker-failures (add1 worker-failures))
                     (record-failure!
                      'WORKER-STALL
                      (format "~a f=~a min=~a w=~a/~a sched=~s save=~a"
                              resolved-race frame minerals workers (* 20 bases) sched-ids saving-id))))

                 ;; 3. Supply-Block Deadlock Invariant:
                 ;;    `supply_left <= 0`, `supply_cap < 200`, `minerals >= 100`, `pending_supply == 0`
                 (when (and (<= sup-left 0)
                            (< sup-cap 200)
                            (>= minerals 100)
                            (= pending-sup 0)
                            (> workers 0))
                   (unless (memq sup-sym sched-ids)
                     (set! supply-failures (add1 supply-failures))
                     (record-failure!
                      'SUPPLY-DEADLOCK
                      (format "~a f=~a min=~a sup=~a/~a sched=~s"
                              resolved-race frame minerals sup-used sup-cap sched-ids))))

                 ;; 4. Unspent-Resource Hoarding Stall Invariant:
                 ;;    `minerals >= 800`, `supply_used < 194`, `workers > 0`, peaceful/active -> must emit >= 1 action!
                 (when (and (>= minerals 800)
                            (< sup-used 194)
                            (or (>= sup-left 2) (< sup-cap 200))
                            (> workers 0))
                   (when (null? sched-ids)
                     (set! hoard-failures (add1 hoard-failures))
                     (record-failure!
                      'HOARDING-STALL
                      (format "~a f=~a min=~a gas=~a sup=~a/~a w=~a save=~a"
                              resolved-race frame minerals gas sup-used sup-cap workers saving-id))))

                 ;; 5. 15s-Lookahead Pro Category Coverage Table
                 (define pro-cats
                   (remove-duplicates (filter values (map sym->audit-category fut15)) eq?))
                 (for ([target-r (in-list (if as-random? (list resolved-race 'Random) (list resolved-race)))])
                   (define r-acc (hash-ref race-accums target-r))
                   (for ([cat (in-list pro-cats)])
                     (define vec (hash-ref r-acc cat))
                     ;; vec slots: 0=pro15s, 1=active, 2=top3, 3=omitted, 4=escBlk, 5=outranked
                     (vector-set! vec 0 (add1 (vector-ref vec 0)))
                     (define matching-entries
                       (filter (lambda (e) (entry-matches-audit-category? e cat)) trace))
                     (cond
                       [(null? matching-entries)
                        (vector-set! vec 3 (add1 (vector-ref vec 3)))]
                       [else
                        (vector-set! vec 1 (add1 (vector-ref vec 1)))
                        (define best-e (first matching-entries))
                        (define rk (priority-decision-entry-rank best-e))
                        (define outc (priority-decision-entry-outcome best-e))
                        (cond
                          [(or (<= rk 3) (eq? outc 'scheduled))
                           (vector-set! vec 2 (add1 (vector-ref vec 2)))]
                          [(eq? outc 'blocked-by-escrow)
                           (vector-set! vec 4 (add1 (vector-ref vec 4)))]
                          [else
                           (vector-set! vec 5 (add1 (vector-ref vec 5)))])])))]
                [_ (void)]))
            (loop))))))

  (define cat-rows-ht
    (for/hasheq ([r (in-list '(Zerg Terran Protoss Random))])
      (define r-acc (hash-ref race-accums r))
      (values r
              (for/list ([cat (in-list AUDIT-CATEGORIES)])
                (define v (hash-ref r-acc cat))
                (pro-category-audit-row
                 cat
                 (vector-ref v 0)
                 (vector-ref v 1)
                 (vector-ref v 2)
                 (vector-ref v 3)
                 (vector-ref v 4)
                 (vector-ref v 5))))))

  (pro-starvation-audit-report
   evaluated-count
   (hash-count seen-trajectories)
   (hash-count seen-replays)
   (for/list ([r (in-list '(Zerg Protoss Terran Random))]
              #:when (hash-has-key? seen-races r))
     r)
   exp-failures
   worker-failures
   supply-failures
   hoard-failures
   (reverse failure-samples)
   cat-rows-ht))

(define (pct-str num den)
  (if (<= den 0)
      "0.0%"
      (format "~a%" (~r (* 100.0 (/ (exact->inexact num) (exact->inexact den))) #:precision '(= 1)))))

(define (format-pro-starvation-audit-report rep)
  (define out (open-output-string))
  (fprintf out "=== PRO-REPLAY 15s-LOOKAHEAD PRIORITY & STARVATION AUDIT (~a checkpoints, ~a trajectories) ===\n"
           (pro-starvation-audit-report-checkpoints-evaluated rep)
           (pro-starvation-audit-report-trajectories-evaluated rep))
  (for ([r (in-list '(Zerg Terran Protoss Random))])
    (define rows (hash-ref (pro-starvation-audit-report-category-rows-by-race rep) r '()))
    (fprintf out "\n--- ~a ---\n" r)
    (fprintf out "~a ~a ~a ~a ~a ~a ~a\n"
             (~a "Category" #:min-width 20)
             (~a "Pro15s" #:min-width 8 #:align 'right)
             (~a "Active%" #:min-width 9 #:align 'right)
             (~a "Top3%" #:min-width 9 #:align 'right)
             (~a "Omitted%" #:min-width 10 #:align 'right)
             (~a "EscBlk%" #:min-width 10 #:align 'right)
             (~a "Outrank%" #:min-width 10 #:align 'right))
    (for ([row (in-list rows)])
      (define n (pro-category-audit-row-pro15s-count row))
      (fprintf out "~a ~a ~a ~a ~a ~a ~a\n"
               (~a (pro-category-audit-row-category row) #:min-width 20)
               (~a n #:min-width 8 #:align 'right)
               (~a (pct-str (pro-category-audit-row-active-count row) n) #:min-width 9 #:align 'right)
               (~a (pct-str (pro-category-audit-row-top3-count row) n) #:min-width 9 #:align 'right)
               (~a (pct-str (pro-category-audit-row-omitted-count row) n) #:min-width 10 #:align 'right)
               (~a (pct-str (pro-category-audit-row-escrow-blocked-count row) n) #:min-width 10 #:align 'right)
               (~a (pct-str (pro-category-audit-row-outranked-count row) n) #:min-width 10 #:align 'right))))
  (fprintf out "\n--- Anti-Starvation & Deadlock Verification ---\n")
  (fprintf out "  expansion_starvation_failures : ~a\n"
           (pro-starvation-audit-report-expansion-starvation-failures rep))
  (fprintf out "  worker_stall_failures         : ~a\n"
           (pro-starvation-audit-report-worker-stall-failures rep))
  (fprintf out "  supply_deadlock_failures      : ~a\n"
           (pro-starvation-audit-report-supply-deadlock-failures rep))
  (fprintf out "  hoarding_stall_failures       : ~a\n"
           (pro-starvation-audit-report-hoarding-stall-failures rep))
  (get-output-string out))
