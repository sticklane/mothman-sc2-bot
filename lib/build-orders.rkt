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
 ZvZ-UNIT-BENCHMARKS
 ZvT-UNIT-BENCHMARKS
 ZvP-UNIT-BENCHMARKS
 TvZ-UNIT-BENCHMARKS
 TvT-UNIT-BENCHMARKS
 TvP-UNIT-BENCHMARKS
 PvZ-UNIT-BENCHMARKS
 PvT-UNIT-BENCHMARKS
 PvP-UNIT-BENCHMARKS
 lookup-build-order-for-matchup
 pro-build-order-steps-for-matchup
 pro-unit-timings-for-matchup
 pro-unit-benchmark-timings-for-matchup
 pro-unit-benchmarks-at-frame
 pro-upgrade-timings-for-matchup
 due-pro-unit-timings
 due-pro-upgrade-timings
 pro-unit-timing->bo-goal
 pro-upgrade-timing->bo-goal
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

(: UNIT-BENCHMARKS-BY-MATCHUP (HashTable MatchupSym (Listof pro-unit-timing)))
(define UNIT-BENCHMARKS-BY-MATCHUP
  (make-immutable-hasheq
   (ann
    (list (cons 'ZvZ ZvZ-UNIT-BENCHMARKS)
          (cons 'ZvT ZvT-UNIT-BENCHMARKS)
          (cons 'ZvP ZvP-UNIT-BENCHMARKS)
          (cons 'TvZ TvZ-UNIT-BENCHMARKS)
          (cons 'TvT TvT-UNIT-BENCHMARKS)
          (cons 'TvP TvP-UNIT-BENCHMARKS)
          (cons 'PvZ PvZ-UNIT-BENCHMARKS)
          (cons 'PvT PvT-UNIT-BENCHMARKS)
          (cons 'PvP PvP-UNIT-BENCHMARKS))
    (Listof (Pairof MatchupSym (Listof pro-unit-timing))))))

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

(: pro-unit-benchmark-timings-for-matchup (->* (Any) (Any) (Listof pro-unit-timing)))
(define (pro-unit-benchmark-timings-for-matchup race [enemy-race 'Unknown])
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (hash-ref UNIT-BENCHMARKS-BY-MATCHUP m-sym (lambda () ZvT-UNIT-BENCHMARKS)))

(: pro-unit-benchmarks-at-frame (->* (Any Any Any) (Any) (HashTable Symbol Integer)))
(define (pro-unit-benchmarks-at-frame race enemy-race raw-frame [raw-active-bases 1])
  (define frame (safe-nonneg-int raw-frame 0))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define elapsed-sec (/ (->float frame) 22.4))
  (define eff-sec (if (= frame 0) 0.0 (+ elapsed-sec 15.0)))
  (define base-mult : Float
    (cond
      [(>= active-bases 5) 1.35]
      [(= active-bases 4) 1.20]
      [else 1.0]))
  (define entries
    (append (pro-unit-timings-for-matchup race enemy-race)
            (pro-unit-benchmark-timings-for-matchup race enemy-race)))
  (define tbl : (HashTable Symbol Integer) (make-hasheq))
  (for ([ut : pro-unit-timing (in-list entries)])
    (define tsec (->float (pro-unit-timing-target-sec ut)))
    (when (<= tsec eff-sec)
      (define sym (pro-unit-timing-unit-sym ut))
      (define raw-cnt (pro-unit-timing-target-count ut))
      (define scalable?
        (not (memq sym '(overlord overseer overlord-transport raven observer warp-prism oracle sentry reaper viper))))
      (define scaled-cnt : Integer
        (if (and scalable? (> base-mult 1.0))
            (max raw-cnt (exact-round (* (->float raw-cnt) base-mult)))
            raw-cnt))
      (define prev (hash-ref tbl sym (lambda () 0)))
      (when (> scaled-cnt prev)
        (hash-set! tbl sym scaled-cnt))))
  (for/hash : (HashTable Symbol Integer) ([(k v) (in-hash tbl)])
    (values k v)))

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

(: race-macro-worker-cap (-> Any Integer))
(define (race-macro-worker-cap race)
  (case (normalize-known-race race)
    [(Zerg)    76]
    [(Protoss) 70]
    [(Terran)  66]))

(: pro-supply-curve-target-for-spec (->* (build-order-spec) (Any Any) (Values Integer Integer)))
(define (pro-supply-curve-target-for-spec spec [raw-frame 0] [raw-active-bases 1])
  (define frame (safe-nonneg-int raw-frame 0))
  (define active-bases (max 1 (safe-nonneg-int raw-active-bases 1)))
  (define sec (/ (->float frame) 22.4))
  (define race-cap (race-macro-worker-cap (build-order-spec-race spec)))
  (define minute-idx (max 1 (min 10 (+ 1 (exact-floor (/ sec 60.0))))))
  (define curve (build-order-spec-supply-curve spec))
  (define pt
    (or (assv minute-idx curve)
        (assv (min 7 minute-idx) curve)))
  (define workers-val : Real
    (if pt (car (cdr pt)) (* 22.0 (min 4 active-bases))))
  (define army-val : Real
    (if pt (cdr (cdr pt)) (max 2.0 (* 8.0 minute-idx))))
  (define curve-workers (exact-round workers-val))
  (define curve-army (exact-round army-val))
  (define timing-cut-archetype?
    (memq (build-order-spec-archetype spec)
          '(two-base-timing one-base-all-in roach-ravager-timing bio-timing-allin)))
  (define base-scaled-workers : Integer
    (if (and timing-cut-archetype? (< sec 420.0))
        (min race-cap (max 16 curve-workers))
        (min race-cap (max 22 (* 22 (min 4 active-bases)) curve-workers))))
  (values base-scaled-workers curve-army))

(: pro-supply-curve-target (->* (Any) (Any Any Any) (Values Integer Integer)))
(define (pro-supply-curve-target race [enemy-race 'Unknown] [raw-frame 0] [raw-active-bases 1])
  (define spec (lookup-build-order-for-matchup race enemy-race))
  (pro-supply-curve-target-for-spec spec raw-frame raw-active-bases))

;; -----------------------------------------------------------------------------
;; 1b. Reactive Anti-Early-Pool / Rush & Intentional Worker-Cut Timing Variants
;; -----------------------------------------------------------------------------

(: PvZ-ANTI-EARLY-POOL-BUILD-ORDER build-order-spec)
(define PvZ-ANTI-EARLY-POOL-BUILD-ORDER
  (build-order-spec
   'PvZ
   'Protoss
   "PvZ Reactive Core-Zealot-Battery vs Early Pool into 4-Base Macro"
   'stalker-colossus
   "Scouted 12-pool / pool-first response: Cybernetics Core + Zealot + Pylon #2 + Shield Battery BEFORE Natural Nexus, then 4-base macro."
   (list
    (pro-bo-goal 'build    'pylon                  1 14 #f                 17.5)
    (pro-bo-goal 'build    'gateway                1 16 'pylon             44.5)
    (pro-bo-goal 'build    'assimilator            1 16 'pylon             46.8)
    (pro-bo-goal 'build    'cybernetics-core       1 18 'gateway           72.0)  ;; Core BEFORE Nexus!
    (pro-bo-goal 'train    'zealot                 1 18 'gateway           76.0)  ;; Chrono Zealot to hold lings!
    (pro-bo-goal 'build    'pylon                  2 19 'gateway           88.0)
    (pro-bo-goal 'train    'adept                  1 20 'cybernetics-core 104.0)
    (pro-bo-goal 'build    'shield-battery         1 21 'cybernetics-core 112.0)
    (pro-bo-goal 'expand   'nexus                  2 22 'cybernetics-core 135.0)  ;; Safe Natural Nexus after hold!
    (pro-bo-goal 'research 'warp-gate-research     1 24 'cybernetics-core 145.0)
    (pro-bo-goal 'build    'assimilator            2 26 'cybernetics-core 155.0)
    (pro-bo-goal 'build    'robotics-facility      1 30 'cybernetics-core 195.0)
    (pro-bo-goal 'build    'twilight-council       1 32 'cybernetics-core 210.0)
    (pro-bo-goal 'build    'gateway                2 34 'cybernetics-core 225.0)
    (pro-bo-goal 'build    'gateway                3 36 'cybernetics-core 235.0)
    (pro-bo-goal 'expand   'nexus                  3 48 'robotics-facility 295.0)
    (pro-bo-goal 'build    'assimilator            3 50 'robotics-facility 305.0)
    (pro-bo-goal 'research 'charge                 1 52 'twilight-council  320.0)
    (pro-bo-goal 'build    'forge                  1 56 'cybernetics-core  335.0)
    (pro-bo-goal 'build    'robotics-bay           1 62 'robotics-facility 365.0)
    (pro-bo-goal 'expand   'nexus                  4 92 'robotics-bay      450.0))
   '((1 . (17.0 .  1.0))
     (2 . (19.0 .  4.0))
     (3 . (26.0 .  8.0))
     (4 . (36.0 . 14.0))
     (5 . (47.0 . 20.0))
     (6 . (58.0 . 26.0))
     (7 . (66.0 . 36.0))
     (8 . (70.0 . 54.0))
     (9 . (70.0 . 74.0))
     (10 . (70.0 . 94.0)))
   (build-order-spec-unit-timings PvZ-BUILD-ORDER)
   (build-order-spec-upgrade-timings PvZ-BUILD-ORDER)))

(: TvZ-ANTI-EARLY-POOL-BUILD-ORDER build-order-spec)
(define TvZ-ANTI-EARLY-POOL-BUILD-ORDER
  (build-order-spec
   'TvZ
   'Terran
   "TvZ Reactive Wall-Reaper-Hellion High-Ground CC vs Early Pool"
   'bio-tank
   "Scouted 12-pool / pool-first response: complete Depot wall + Reaper/Marine + Factory + Reactor Hellions + safe CC2, then 4-base macro."
   (list
    (pro-bo-goal 'build    'supply-depot             1 14 #f                 17.1)
    (pro-bo-goal 'build    'barracks                 1 16 'supply-depot      40.6)
    (pro-bo-goal 'build    'refinery                 1 16 'supply-depot      43.9)
    (pro-bo-goal 'build    'supply-depot             2 18 'barracks          78.0)  ;; Wall closed vs 12-pool!
    (pro-bo-goal 'morph    'orbital-command          1 19 'barracks          91.1)
    (pro-bo-goal 'build    'factory                  1 20 'barracks         106.0)
    (pro-bo-goal 'build    'barracks-reactor         1 21 'barracks         114.0)
    (pro-bo-goal 'build    'bunker                   1 21 'barracks         120.0)
    (pro-bo-goal 'expand   'command-center           2 22 'factory          140.0)  ;; Safe CC2 after wall + Factory!
    (pro-bo-goal 'train    'hellion                  4 26 'factory          185.0)
    (pro-bo-goal 'build    'refinery                 2 28 'factory          190.0)
    (pro-bo-goal 'build    'starport                 1 30 'factory          205.0)
    (pro-bo-goal 'morph    'orbital-command          2 32 'barracks         215.0)
    (pro-bo-goal 'build    'barracks                 2 36 'barracks         235.0)
    (pro-bo-goal 'build    'barracks-techlab         1 38 'barracks         248.0)
    (pro-bo-goal 'expand   'command-center           3 44 'starport         275.0)
    (pro-bo-goal 'research 'stimpack                 1 46 'barracks-techlab 285.0)
    (pro-bo-goal 'build    'barracks                 3 50 'barracks         300.0)
    (pro-bo-goal 'build    'engineering-bay          1 52 'barracks         310.0)
    (pro-bo-goal 'expand   'command-center           4 90 'starport         450.0))
   '((1 . (16.0 .  1.0))
     (2 . (18.0 .  4.0))
     (3 . (25.0 .  8.0))
     (4 . (35.0 . 14.0))
     (5 . (45.0 . 22.0))
     (6 . (55.0 . 32.0))
     (7 . (64.0 . 44.0))
     (8 . (66.0 . 62.0))
     (9 . (66.0 . 82.0))
     (10 . (66.0 . 102.0)))
   (build-order-spec-unit-timings TvZ-BUILD-ORDER)
   (build-order-spec-upgrade-timings TvZ-BUILD-ORDER)))

(: ZvX-ANTI-EARLY-RUSH-BUILD-ORDER build-order-spec)
(define ZvX-ANTI-EARLY-RUSH-BUILD-ORDER
  (build-order-spec
   'ZvZ
   'Zerg
   "ZvX Reactive Pool-Ling-Queen-Spine-Roach Hold into 4-Base Macro"
   'ling-bane-roach
   "Scouted 12-pool / proxy / cannon rush response: immediate Pool, Lings, Queens, Spine Crawler & Roach Warren before 3rd Hatchery."
   (list
    (pro-bo-goal 'build    'spawning-pool          1 14 #f                  48.0)
    (pro-bo-goal 'build    'extractor              1 15 #f                  58.0)
    (pro-bo-goal 'train    'overlord               2 15 #f                  65.0)
    (pro-bo-goal 'train    'zergling               6 16 'spawning-pool      92.0)
    (pro-bo-goal 'train    'queen                  2 18 'spawning-pool     102.0)
    (pro-bo-goal 'build    'spine-crawler          1 19 'spawning-pool     108.0)
    (pro-bo-goal 'research 'metabolic-boost        1 20 'spawning-pool     118.0)
    (pro-bo-goal 'build    'roach-warren           1 22 'spawning-pool     135.0)
    (pro-bo-goal 'expand   'hatchery               2 24 'spawning-pool     155.0)
    (pro-bo-goal 'build    'baneling-nest          1 28 'spawning-pool     175.0)
    (pro-bo-goal 'expand   'hatchery               3 34 'spawning-pool     215.0)
    (pro-bo-goal 'build    'extractor              2 38 'spawning-pool     235.0)
    (pro-bo-goal 'morph    'lair                   1 44 'spawning-pool     265.0)
    (pro-bo-goal 'expand   'hatchery               4 64 'lair              360.0)
    (pro-bo-goal 'build    'hydralisk-den          1 68 'lair              385.0))
   '((1 . (14.0 .  4.0))
     (2 . (18.0 .  8.0))
     (3 . (25.0 . 12.0))
     (4 . (34.0 . 18.0))
     (5 . (44.0 . 26.0))
     (6 . (54.0 . 38.0))
     (7 . (64.0 . 54.0))
     (8 . (70.0 . 66.0))
     (9 . (76.0 . 78.0))
     (10 . (76.0 . 90.0)))
   (build-order-spec-unit-timings ZvZ-BUILD-ORDER)
   (build-order-spec-upgrade-timings ZvZ-BUILD-ORDER)))

(: TvP-2BASE-STIM-TIMING-BUILD-ORDER build-order-spec)
(define TvP-2BASE-STIM-TIMING-BUILD-ORDER
  (build-order-spec
   'TvP
   'Terran
   "TvP 2-Base 44-SCV 3-Rax Stim/Medivac/+1 Timing -> 4-Base Transition"
   'two-base-timing
   "Intentional worker cut at 44 SCVs for crisp 2-base Stim/Medivac/+1 timing push, auto-transitioning to 3rd/4th CC at 7:00 if held."
   (build-order-spec-steps TvP-BUILD-ORDER)
   '((1 . (16.0 .  1.0))
     (2 . (19.0 .  2.0))
     (3 . (26.0 .  6.0))
     (4 . (36.0 . 18.0))
     (5 . (44.0 . 30.0))
     (6 . (44.0 . 46.0))
     (7 . (44.0 . 62.0))
     (8 . (58.0 . 72.0))
     (9 . (66.0 . 86.0))
     (10 . (66.0 . 102.0)))
   (build-order-spec-unit-timings TvP-BUILD-ORDER)
   (build-order-spec-upgrade-timings TvP-BUILD-ORDER)))

(: ZvP-2BASE-ROACH-RAVAGER-TIMING-BUILD-ORDER build-order-spec)
(define ZvP-2BASE-ROACH-RAVAGER-TIMING-BUILD-ORDER
  (build-order-spec
   'ZvP
   'Zerg
   "ZvP 38-Drone Roach-Ravager-Ling Timing -> 4-Base Macro Transition"
   'roach-ravager-timing
   "Intentional worker cut at 38 Drones for Roach-Ravager-Speedling timing, auto-transitioning to Lair + 4th Hatchery at 7:00 if held."
   (build-order-spec-steps ZvP-BUILD-ORDER)
   '((1 . (15.0 .  2.0))
     (2 . (20.0 .  2.0))
     (3 . (28.0 . 10.0))
     (4 . (38.0 . 22.0))
     (5 . (38.0 . 38.0))
     (6 . (38.0 . 54.0))
     (7 . (52.0 . 62.0))
     (8 . (66.0 . 70.0))
     (9 . (76.0 . 82.0))
     (10 . (76.0 . 94.0)))
   (build-order-spec-unit-timings ZvP-BUILD-ORDER)
   (build-order-spec-upgrade-timings ZvP-BUILD-ORDER)))

(: REACTIVE-BUILD-ORDER-VARIANTS (Listof build-order-spec))
(define REACTIVE-BUILD-ORDER-VARIANTS
  (list PvZ-ANTI-EARLY-POOL-BUILD-ORDER
        TvZ-ANTI-EARLY-POOL-BUILD-ORDER
        ZvX-ANTI-EARLY-RUSH-BUILD-ORDER
        TvP-2BASE-STIM-TIMING-BUILD-ORDER
        ZvP-2BASE-ROACH-RAVAGER-TIMING-BUILD-ORDER))

(: select-reactive-build-order-spec
   (->* (Any)
        (Any #:early-pool-or-rush? Boolean #:variant (Option Symbol))
        build-order-spec))
(define (select-reactive-build-order-spec race
                                          [enemy-race 'Unknown]
                                          #:early-pool-or-rush? [early-pool-or-rush? #f]
                                          #:variant [variant #f])
  (define m-sym (resolve-matchup-symbol race enemy-race))
  (cond
    [(eq? variant 'two-base-timing)
     (case m-sym
       [(TvP) TvP-2BASE-STIM-TIMING-BUILD-ORDER]
       [(ZvP) ZvP-2BASE-ROACH-RAVAGER-TIMING-BUILD-ORDER]
       [else (lookup-build-order-for-matchup race enemy-race)])]
    [early-pool-or-rush?
     (case m-sym
       [(PvZ) PvZ-ANTI-EARLY-POOL-BUILD-ORDER]
       [(TvZ) TvZ-ANTI-EARLY-POOL-BUILD-ORDER]
       [(ZvZ ZvT ZvP) ZvX-ANTI-EARLY-RUSH-BUILD-ORDER]
       [else (lookup-build-order-for-matchup race enemy-race)])]
    [else
     (lookup-build-order-for-matchup race enemy-race)]))

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
