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
  (list 'matchup
        (build-order-spec-matchup spec)
        (list 'name (build-order-spec-name spec))
        (list 'archetype (build-order-spec-archetype spec))
        (cons 'winning-worker-to-army-supply-curve curve-rows)))

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
