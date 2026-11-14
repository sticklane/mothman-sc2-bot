#lang typed/racket/base

;; =============================================================================
;; `lib/build-orders.rkt`
;; Registry & Typed Accessors for Human-Readable Build Orders & Tech Trees.
;;
;; Aggregates one-build-per-file modules under `lib/build-orders/` for Zerg,
;; Terran, and Protoss matchups plus opponent tech-progression graphs.
;; Replaces the monolithic `data/pro_build_orders.sexp` runtime blob.
;; =============================================================================

(require racket/math
         "sc2-types.rkt"
         "build-orders/zvz-16-hatch-pool-bane.rkt"
         "build-orders/zvt-16-hatch-macro-roach-ravager.rkt"
         "build-orders/zvp-16-hatch-3-base-roach-hydra.rkt"
         "build-orders/tvz-reaper-fe-1-1-1-hellion-banshee.rkt"
         "build-orders/tvt-reaper-fe-double-gas-raven-tank.rkt"
         "build-orders/tvp-reaper-fe-3-rax-stim-medivac.rkt"
         "build-orders/pvz-1-gate-fe-stargate-oracle-archon.rkt"
         "build-orders/pvt-1-gate-fe-blink-robo-colossus.rkt"
         "build-orders/pvp-2-gate-cyber-expand-blink-immortal.rkt"
         "build-orders/zerg-tech-tree.rkt"
         "build-orders/terran-tech-tree.rkt"
         "build-orders/protoss-tech-tree.rkt")

(provide
 (struct-out pro-bo-goal)
 pro-bo-goal-target
 make-pro-bo-goal
 (struct-out pro-unit-timing)
 (struct-out pro-upgrade-timing)
 (struct-out build-order-spec)
 (struct-out build-order-tree-node)
 ALL-BUILD-ORDER-SPECS
 ZvZ-BUILD-ORDER
 ZvT-BUILD-ORDER
 ZvP-BUILD-ORDER
 TvZ-BUILD-ORDER
 TvT-BUILD-ORDER
 TvP-BUILD-ORDER
 PvZ-BUILD-ORDER
 PvT-BUILD-ORDER
 PvP-BUILD-ORDER
 lookup-build-order-for-matchup
 pro-build-order-steps-for-matchup
 pro-unit-timings-for-matchup
 pro-upgrade-timings-for-matchup
 due-pro-unit-timings
 due-pro-upgrade-timings
 pro-unit-timing->bo-goal
 pro-upgrade-timing->bo-goal
 pro-supply-curve-target
 PRO-BUILD-ORDER-DB
 find-matchup-entry
 select-pro-build-order
 ZERG-BUILD-ORDER-TREE
 TERRAN-BUILD-ORDER-TREE
 PROTOSS-BUILD-ORDER-TREE
 ZERG-BO-NODE-BY-ID
 TERRAN-BO-NODE-BY-ID
 PROTOSS-BO-NODE-BY-ID
 lookup-race-build-order-tree
 lookup-race-bo-node-by-id)

;; -----------------------------------------------------------------------------
;; 1. Build-Order Registry & Lookup
;; -----------------------------------------------------------------------------

(: ALL-BUILD-ORDER-SPECS (Listof build-order-spec))
(define ALL-BUILD-ORDER-SPECS
  (list
   ZvZ-BUILD-ORDER
   ZvT-BUILD-ORDER
   ZvP-BUILD-ORDER
   TvZ-BUILD-ORDER
   TvT-BUILD-ORDER
   TvP-BUILD-ORDER
   PvZ-BUILD-ORDER
   PvT-BUILD-ORDER
   PvP-BUILD-ORDER))

(: BUILD-ORDER-BY-MATCHUP (HashTable MatchupSym build-order-spec))
(define BUILD-ORDER-BY-MATCHUP
  (for/hash : (HashTable MatchupSym build-order-spec)
            ([spec : build-order-spec (in-list ALL-BUILD-ORDER-SPECS)])
    (values (build-order-spec-matchup spec) spec)))

(: lookup-build-order-for-matchup (->* (Any) (Any) build-order-spec))
(define (lookup-build-order-for-matchup race [enemy-race 'Unknown])
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (hash-ref BUILD-ORDER-BY-MATCHUP m-sym (lambda () ZvT-BUILD-ORDER)))

(: pro-build-order-steps-for-matchup (->* (Any) (Any) (Listof pro-bo-goal)))
(define (pro-build-order-steps-for-matchup race [enemy-race 'Unknown])
  (build-order-spec-steps (lookup-build-order-for-matchup race enemy-race)))

(: pro-unit-timings-for-matchup (->* (Any) (Any) (Listof pro-unit-timing)))
(define (pro-unit-timings-for-matchup race [enemy-race 'Unknown])
  (build-order-spec-unit-timings (lookup-build-order-for-matchup race enemy-race)))

(: pro-upgrade-timings-for-matchup (->* (Any) (Any) (Listof pro-upgrade-timing)))
(define (pro-upgrade-timings-for-matchup race [enemy-race 'Unknown])
  (build-order-spec-upgrade-timings (lookup-build-order-for-matchup race enemy-race)))

(: due-pro-unit-timings (->* (Any Any Any Any) (Real) (Listof pro-unit-timing)))
(define (due-pro-unit-timings race enemy-race raw-frame raw-supply-used [late-window-sec 180.0])
  (define frame (safe-nonneg-int raw-frame 0))
  (define supply-used (safe-nonneg-int raw-supply-used 0))
  (define elapsed-sec (/ (->float frame) 22.4))
  (define w (max 0.0 (->float late-window-sec)))
  (filter
   (lambda ([ut : pro-unit-timing])
     (define tsec (->float (pro-unit-timing-target-sec ut)))
     (define min-sup (pro-unit-timing-min-supply ut))
     ;; Retire early opening unit benchmarks once both clock (+60s) and supply (+16)
     ;; have moved well past the benchmark checkpoint.
     (define opening-passed?
       (and (> frame 0)
            (> elapsed-sec (+ tsec 60.0))
            (>= supply-used (+ min-sup 16))))
     (define not-stale?
       (or (= frame 0)
           (and (<= elapsed-sec (+ tsec w))
                (not opening-passed?))))
     (and not-stale?
          (or (and (= frame 0) (>= supply-used min-sup))
              (and (> frame 0)
                   (or (>= (+ elapsed-sec 15.0) tsec)
                       ;; When frame > 0, allow supply-triggered early activation only
                       ;; within a 30s lead window before target-sec.
                       (and (>= supply-used min-sup)
                            (>= (+ elapsed-sec 30.0) tsec)))))))
   (pro-unit-timings-for-matchup race enemy-race)))

(: due-pro-upgrade-timings (->* (Any Any Any Any) (Real) (Listof pro-upgrade-timing)))
(define (due-pro-upgrade-timings race enemy-race raw-frame raw-supply-used [late-window-sec 240.0])
  (define frame (safe-nonneg-int raw-frame 0))
  (define supply-used (safe-nonneg-int raw-supply-used 0))
  (define elapsed-sec (/ (->float frame) 22.4))
  (define w (max 0.0 (->float late-window-sec)))
  (filter
   (lambda ([up : pro-upgrade-timing])
     (define ssec (->float (pro-upgrade-timing-start-sec up)))
     (define csec (max ssec (->float (pro-upgrade-timing-complete-sec up))))
     (define min-sup (pro-upgrade-timing-min-supply up))
     (define not-stale?
       (or (= frame 0)
           (<= elapsed-sec (+ csec w))))
     (and not-stale?
          (or (and (= frame 0) (>= supply-used min-sup))
              (and (> frame 0)
                   (or (>= (+ elapsed-sec 15.0) ssec)
                       ;; When frame > 0, keep supply-triggered upgrades within 30s of start-sec
                       ;; so high early supply does not fire 4+ min upgrades 60-90s ahead of time.
                       (and (>= supply-used min-sup)
                            (>= (+ elapsed-sec 30.0) ssec)))))))
   (pro-upgrade-timings-for-matchup race enemy-race)))

(: pro-unit-timing->bo-goal (-> pro-unit-timing pro-bo-goal))
(define (pro-unit-timing->bo-goal ut)
  (pro-bo-goal 'train
               (pro-unit-timing-unit-sym ut)
               (pro-unit-timing-target-count ut)
               (pro-unit-timing-min-supply ut)
               (pro-unit-timing-prereq-ready-sym ut)
               (pro-unit-timing-target-sec ut)))

(: pro-upgrade-timing->bo-goal (-> pro-upgrade-timing pro-bo-goal))
(define (pro-upgrade-timing->bo-goal up)
  (pro-bo-goal 'research
               (pro-upgrade-timing-upgrade-sym up)
               1
               (pro-upgrade-timing-min-supply up)
               (pro-upgrade-timing-prereq-ready-sym up)
               (pro-upgrade-timing-start-sec up)))

(: pro-supply-curve-target (->* (Any) (Any Any Any) (Values Integer Integer)))
(define (pro-supply-curve-target race [enemy-race 'Unknown] [raw-frame 0] [raw-active-bases 1])
  (define frame (safe-nonneg-int raw-frame 0))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define sec (/ (->float frame) 22.4))
  (define spec (lookup-build-order-for-matchup race enemy-race))
  (define minute-idx (max 1 (min 7 (+ 1 (exact-floor (/ sec 60.0))))))
  (define pt (assv minute-idx (build-order-spec-supply-curve spec)))
  (define workers-val : Real
    (if pt (car (cdr pt)) (* 22.0 (min 4 active-bases))))
  (define army-val : Real
    (if pt (cdr (cdr pt)) (max 2.0 (* 8.0 minute-idx))))
  (define curve-workers (exact-round workers-val))
  (define curve-army (exact-round army-val))
  (define base-scaled-workers
    (min 70 (max 22 (* 22 (min 4 active-bases)) curve-workers)))
  (values base-scaled-workers curve-army))

;; Backwards-compatible S-expression view constructed directly from typed specs
(: build-order-spec->sexp (-> build-order-spec (Listof Any)))
(define (build-order-spec->sexp spec)
  (define curve-rows : (Listof Any)
    (for/list ([pt : SupplyCurvePoint (in-list (build-order-spec-supply-curve spec))])
      (let ([m (car pt)]
            [w (cadr pt)]
            [a (cddr pt)])
        (list 'minute m
              (list 'sec (* m 60))
              (list 'workers w)
              (list 'army-supply a)))))
  (define step-rows : (Listof Any)
    (for/list ([g : pro-bo-goal (in-list (build-order-spec-steps spec))])
      (list 'step
            (list 'kind (pro-bo-goal-kind g))
            (list 'target (pro-bo-goal-target-sym g))
            (list 'count (pro-bo-goal-target-count g))
            (list 'supply (pro-bo-goal-min-supply g))
            (list 'sec (pro-bo-goal-target-sec g))
            (list 'prereq (pro-bo-goal-prereq-ready-sym g)))))
  (define unit-rows : (Listof Any)
    (for/list ([ut : pro-unit-timing (in-list (build-order-spec-unit-timings spec))])
      (list 'unit-timing
            (list 'unit (pro-unit-timing-unit-sym ut))
            (list 'count (pro-unit-timing-target-count ut))
            (list 'supply (pro-unit-timing-min-supply ut))
            (list 'sec (pro-unit-timing-target-sec ut))
            (list 'prereq (pro-unit-timing-prereq-ready-sym ut)))))
  (define upg-rows : (Listof Any)
    (for/list ([up : pro-upgrade-timing (in-list (build-order-spec-upgrade-timings spec))])
      (list 'upgrade-timing
            (list 'upgrade (pro-upgrade-timing-upgrade-sym up))
            (list 'start-sec (pro-upgrade-timing-start-sec up))
            (list 'complete-sec (pro-upgrade-timing-complete-sec up))
            (list 'supply (pro-upgrade-timing-min-supply up))
            (list 'prereq (pro-upgrade-timing-prereq-ready-sym up)))))
  (list 'matchup
        (build-order-spec-matchup spec)
        (list 'name (build-order-spec-name spec))
        (list 'archetype (build-order-spec-archetype spec))
        (cons 'winning-worker-to-army-supply-curve curve-rows)
        (cons 'steps step-rows)
        (cons 'unit-timings unit-rows)
        (cons 'upgrade-timings upg-rows)))

(: PRO-BUILD-ORDER-DB (Listof Any))
(define PRO-BUILD-ORDER-DB
  (list 'pro-build-order-database
        (cons 'matchups
              (map build-order-spec->sexp ALL-BUILD-ORDER-SPECS))))

(: find-matchup-entry (-> Any (Option (Listof Any))))
(define (find-matchup-entry matchup-sym)
  (and (matchup-sym? matchup-sym)
       (build-order-spec->sexp
        (hash-ref BUILD-ORDER-BY-MATCHUP matchup-sym))))

(: select-pro-build-order (->* (Any) (Any) (Listof Any)))
(define (select-pro-build-order race [enemy-race 'Unknown])
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (build-order-spec->sexp (hash-ref BUILD-ORDER-BY-MATCHUP m-sym)))

;; -----------------------------------------------------------------------------
;; 2. Opponent Race Tech-Progression Trees
;; -----------------------------------------------------------------------------

(: index-tree-by-id (-> (Listof build-order-tree-node) (HashTable Symbol build-order-tree-node)))
(define (index-tree-by-id tree)
  (for/hash : (HashTable Symbol build-order-tree-node)
            ([n : build-order-tree-node (in-list tree)])
    (values (build-order-tree-node-id n) n)))

(: ZERG-BO-NODE-BY-ID (HashTable Symbol build-order-tree-node))
(define ZERG-BO-NODE-BY-ID (index-tree-by-id ZERG-BUILD-ORDER-TREE))

(: TERRAN-BO-NODE-BY-ID (HashTable Symbol build-order-tree-node))
(define TERRAN-BO-NODE-BY-ID (index-tree-by-id TERRAN-BUILD-ORDER-TREE))

(: PROTOSS-BO-NODE-BY-ID (HashTable Symbol build-order-tree-node))
(define PROTOSS-BO-NODE-BY-ID (index-tree-by-id PROTOSS-BUILD-ORDER-TREE))

(: lookup-race-build-order-tree (-> Any (Listof build-order-tree-node)))
(define (lookup-race-build-order-tree race-sym)
  (case (normalize-known-race race-sym)
    [(Zerg)    ZERG-BUILD-ORDER-TREE]
    [(Terran)  TERRAN-BUILD-ORDER-TREE]
    [(Protoss) PROTOSS-BUILD-ORDER-TREE]))

(: lookup-race-bo-node-by-id (-> Any (HashTable Symbol build-order-tree-node)))
(define (lookup-race-bo-node-by-id race-sym)
  (case (normalize-known-race race-sym)
    [(Zerg)    ZERG-BO-NODE-BY-ID]
    [(Terran)  TERRAN-BO-NODE-BY-ID]
    [(Protoss) PROTOSS-BO-NODE-BY-ID]))
