#lang racket/base

;; =============================================================================
;; Loop 67 Phase D Macro & Static-Defense Policy Regression Suite
;; (`tests/l67-phase-d-macro-policy-test.rkt`)
;;
;; Verifies Loop 67 Lane A (`#2020` / `#2021`):
;;   1. `lib/plan/static-defense.rkt` (`plan-spore-crawler-tactics`):
;;      - NEVER uproots any rooted Spore vs Banshee / DT / cloaked / burrowed enemy
;;        or when rooted Spores <= (max 2 active-townhalls) or sole base Spore or HP < 95%;
;;      - Unconditionally re-roots ALL uprooted Spores even with air-threats = '()
;;        at safe +/-3.5t offset coordinates (NEVER Hatchery center!);
;;      - Raises coverage check to 11.0t (121.0 d2) and emits ONLY `spore-crawler-uproot`
;;        (max 1 per step, NO same-frame uproot+root) when relocating a true surplus Spore.
;;   2. `lib/priority-macro-brain.rkt`:
;;      - Gas-deficit mineral-overflow releases `min-floor = 0` at 420M/40G while
;;        preserving `gas-floor`, and unlocks pure-mineral combat sinks (`zealot`/`marine`/
;;        `zergling`) at >= 420M during gas-gated waits;
;;      - Peaceful `TvP` 3rd CC (`5:15` / `7056f`, `>= 34w`, `>= 10` army, `>= 2` Rax)
;;        promoted (`u >= 615`, `blk = #t` at `>= 225M`) without touching `TvT` Tank4 locks
;;        or active-attack safety;
;;      - Peaceful `ZvP` 3rd Hatchery (`3:15-3:30` / `4368-4704f`, `>= 28w`) promoted
;;        (`u >= 608`, `blk = #t` at `>= 180M`) + `spawning-pool` NEVER escrowed when
;;        `(total-bldg-counts 'spawning-pool) > 0`;
;;      - Peaceful `PvZ` 3rd Nexus (`5:00-5:30` / `6720-7392f`, `>= 36w`, `>= 10` army,
;;        `>= 3` GW, `>= 250M`, `>= 1` Immortal or `>= 5:30`) outranks redundant
;;        `gateway`/`immortal` loops while staying safe under attack / mass-roach lock.
;; =============================================================================

(require racket/list
         racket/format
         "../lib/econ-ledger.rkt"
         "../lib/plan/static-defense.rkt"
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

(define (res-min-floor dec)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (if (hash? cat-ht) (hash-ref cat-ht 'reserved-min-floor 0) 0))

(define (res-gas-floor dec)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (if (hash? cat-ht) (hash-ref cat-ht 'reserved-gas-floor 0) 0))

;; =============================================================================
;; 1. Spore Crawler Tactics Guards & Unconditional Safe Re-Root
;; =============================================================================

;; 1a. NEVER uproot vs Banshee (even with 4 rooted Spores across 2 bases!)
(define sp-obs-banshee
  (hash 'frame 6200 'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0 'third-x 72.0 'third-y 40.0
        'ally-units '()
        'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'max-hp 1500)
                              (hash 'id 2 'type 'hatchery 'x 52.0 'y 36.0 'hp 1500 'max-hp 1500)
                              (hash 'id 10 'type 'spore-crawler 'x 35.0 'y 35.0 'hp 400 'max-hp 400)
                              (hash 'id 11 'type 'spore-crawler 'x 36.0 'y 31.0 'hp 400 'max-hp 400)
                              (hash 'id 12 'type 'spore-crawler 'x 55.0 'y 39.0 'hp 400 'max-hp 400)
                              (hash 'id 13 'type 'spore-crawler 'x 56.0 'y 35.0 'hp 400 'max-hp 400))
        'enemy-units (list (hash 'id 901 'type 'banshee 'x 72.0 'y 40.0 'hp 140 'max-hp 140))
        'enemy-buildings '()))
(define sp-acts-banshee (plan-spore-crawler-tactics sp-obs-banshee))
(check! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'spore-crawler-uproot))) sp-acts-banshee))
        (format "1a. Spore must NEVER uproot vs Banshee; got ~s" sp-acts-banshee))

;; 1b. NEVER uproot when a Dark Templar or cloaked unit exists alongside non-cloak air
(define sp-obs-dt
  (hash 'frame 6200 'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0 'third-x 72.0 'third-y 40.0
        'ally-units '()
        'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'max-hp 1500)
                              (hash 'id 2 'type 'hatchery 'x 52.0 'y 36.0 'hp 1500 'max-hp 1500)
                              (hash 'id 10 'type 'spore-crawler 'x 35.0 'y 35.0 'hp 400 'max-hp 400)
                              (hash 'id 11 'type 'spore-crawler 'x 36.0 'y 31.0 'hp 400 'max-hp 400)
                              (hash 'id 12 'type 'spore-crawler 'x 55.0 'y 39.0 'hp 400 'max-hp 400)
                              (hash 'id 13 'type 'spore-crawler 'x 56.0 'y 35.0 'hp 400 'max-hp 400))
        'enemy-units (list (hash 'id 902 'type 'dark-templar 'x 60.0 'y 40.0 'hp 40 'max-hp 40 'cloak 1)
                           (hash 'id 903 'type 'phoenix 'x 74.0 'y 40.0 'hp 120 'max-hp 120))
        'enemy-buildings '()))
(define sp-acts-dt (plan-spore-crawler-tactics sp-obs-dt))
(check! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'spore-crawler-uproot))) sp-acts-dt))
        (format "1b. Spore must NEVER uproot when DT/cloaked enemy exists; got ~s" sp-acts-dt))

;; 1c. NEVER uproot when rooted Spores <= (max 2 active-townhalls) (e.g., 2 Spores on 2 bases vs Oracle)
(define sp-obs-2spores
  (hash 'frame 5500 'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0 'third-x 72.0 'third-y 40.0
        'ally-units '()
        'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'max-hp 1500)
                              (hash 'id 2 'type 'hatchery 'x 52.0 'y 36.0 'hp 1500 'max-hp 1500)
                              (hash 'id 10 'type 'spore-crawler 'x 35.0 'y 35.0 'hp 400 'max-hp 400)
                              (hash 'id 11 'type 'spore-crawler 'x 55.0 'y 39.0 'hp 400 'max-hp 400))
        'enemy-units (list (hash 'id 904 'type 'oracle 'x 75.0 'y 40.0 'hp 100 'max-hp 100))
        'enemy-buildings '()))
(define sp-acts-2spores (plan-spore-crawler-tactics sp-obs-2spores))
(check! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'spore-crawler-uproot))) sp-acts-2spores))
        (format "1c. Spore must NEVER uproot at <= 2 Spores; got ~s" sp-acts-2spores))

;; 1d. Unconditional re-root of ALL uprooted Spores when air-threats = '(), at safe +/-3.5t offset (NOT Hatchery center!)
(define sp-obs-uprooted-no-air
  (hash 'frame 6400 'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0 'third-x 72.0 'third-y 40.0
        'ally-units (list (hash 'id 701 'type 'spore-crawler-uprooted 'x 35.0 'y 35.0 'hp 400 'max-hp 400)
                          (hash 'id 702 'type 'spore-crawler-uprooted 'x 51.0 'y 38.0 'hp 400 'max-hp 400))
        'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'max-hp 1500)
                              (hash 'id 2 'type 'hatchery 'x 52.0 'y 36.0 'hp 1500 'max-hp 1500))
        'enemy-units '()
        'enemy-buildings '()))
(define sp-acts-reroot (plan-spore-crawler-tactics sp-obs-uprooted-no-air))
(define sp-root-cmds (filter (lambda (a) (and (pair? a) (eq? (car a) 'spore-crawler-root))) sp-acts-reroot))
(check! (and (= (length sp-root-cmds) 2)
             (not (not (memv 701 (map cadr sp-root-cmds))))
             (not (not (memv 702 (map cadr sp-root-cmds))))
             (andmap (lambda (cmd)
                       (define rx (caddr cmd))
                       (define ry (cadddr cmd))
                       (and (not (and (= rx 32.0) (= ry 32.0)))
                            (not (and (= rx 52.0) (= ry 36.0)))
                            (not (and (= rx 72.0) (= ry 40.0)))))
                     sp-root-cmds))
        (format "1d. ALL uprooted Spores must unconditionally re-root with air-threats='() at safe offset (never Hatchery center); got ~s"
                sp-acts-reroot))

;; 1e. Surplus relocation: 3 rooted Spores on 2 bases (2 at main, 1 sole Spore at natural) vs non-cloak Oracle
;;     far away -> uproots ONLY ONE surplus Spore from main (never sole natural Spore, never damaged <95%),
;;     and NEVER emits same-frame spore-crawler-root!
(define sp-obs-surplus
  (hash 'frame 7000 'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0 'third-x 72.0 'third-y 40.0
        'ally-units '()
        'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'max-hp 1500)
                              (hash 'id 2 'type 'hatchery 'x 52.0 'y 36.0 'hp 1500 'max-hp 1500)
                              (hash 'id 10 'type 'spore-crawler 'x 35.0 'y 35.0 'hp 400 'max-hp 400)
                              (hash 'id 11 'type 'spore-crawler 'x 36.0 'y 31.0 'hp 300 'max-hp 400) ;; <95% HP
                              (hash 'id 12 'type 'spore-crawler 'x 55.0 'y 39.0 'hp 400 'max-hp 400)) ;; sole nat spore
        'enemy-units (list (hash 'id 905 'type 'oracle 'x 76.0 'y 40.0 'hp 100 'max-hp 100))
        'enemy-buildings '()))
(define sp-acts-surplus (plan-spore-crawler-tactics sp-obs-surplus))
(check! (and (= (length (filter (lambda (a) (eq? (car a) 'spore-crawler-uproot)) sp-acts-surplus)) 1)
             (= (cadr (car (filter (lambda (a) (eq? (car a) 'spore-crawler-uproot)) sp-acts-surplus))) 10)
             (not (ormap (lambda (a) (eq? (car a) 'spore-crawler-root)) sp-acts-surplus)))
        (format "1e. Surplus relocation must uproot ONLY healthy non-sole Spore (10) with NO same-frame root; got ~s"
                sp-acts-surplus))

;; 1f. Coverage radius raised to 11.0t (121.0 d2): Oracle at 10.0t away is covered -> 0 uproots!
(define sp-obs-covered-10t
  (hash 'frame 7000 'base-x 32.0 'base-y 32.0 'natural-x 52.0 'natural-y 36.0 'third-x 72.0 'third-y 40.0
        'ally-units '()
        'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'max-hp 1500)
                              (hash 'id 2 'type 'hatchery 'x 52.0 'y 36.0 'hp 1500 'max-hp 1500)
                              (hash 'id 10 'type 'spore-crawler 'x 35.0 'y 35.0 'hp 400 'max-hp 400)
                              (hash 'id 11 'type 'spore-crawler 'x 36.0 'y 31.0 'hp 400 'max-hp 400)
                              (hash 'id 12 'type 'spore-crawler 'x 55.0 'y 39.0 'hp 400 'max-hp 400))
        'enemy-units (list (hash 'id 906 'type 'oracle 'x 65.0 'y 39.0 'hp 100 'max-hp 100)) ;; 10.0t from Spore 12
        'enemy-buildings '()))
(define sp-acts-cov10 (plan-spore-crawler-tactics sp-obs-covered-10t))
(check! (not (ormap (lambda (a) (eq? (car a) 'spore-crawler-uproot)) sp-acts-cov10))
        (format "1f. Air threat within 11.0t (10.0t) is covered -> 0 uproots; got ~s" sp-acts-cov10))

;; =============================================================================
;; 2. Loop 67B Gas-Deficit Protected-Tech Escrow & Genuine Gas Starvation (`#2037`)
;; =============================================================================

;; 2a. Protected `colossus` (300M/200G) keeps mineral escrow intact at BOTH 420M/110G AND 450M/120G!
(reset-macro-escrow-tracker!)
(define p-colossus-keep-420m-110g
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 420 #:gas 110 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'immortal 2 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 12 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-colossus-keep-420m-110g) 'colossus)
             (>= (res-min-floor p-colossus-keep-420m-110g) 300)
             (>= (res-gas-floor p-colossus-keep-420m-110g) 200))
        (format "2a. Protected colossus at 420M/110G must keep min-floor>=300 & gas-floor>=200; saving=~a min-f=~a gas-f=~a sched=~s"
                (macro-brain-decision-saving-for p-colossus-keep-420m-110g)
                (res-min-floor p-colossus-keep-420m-110g)
                (res-gas-floor p-colossus-keep-420m-110g)
                (macro-brain-decision-scheduled-ids p-colossus-keep-420m-110g)))

(reset-macro-escrow-tracker!)
(define p-colossus-keep-450m-120g
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 450 #:gas 120 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'immortal 2 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 12 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-colossus-keep-450m-120g) 'colossus)
             (>= (res-min-floor p-colossus-keep-450m-120g) 300)
             (>= (res-gas-floor p-colossus-keep-450m-120g) 200))
        (format "2a2. Protected colossus at 450M/120G must keep min-floor>=300 & gas-floor>=200; saving=~a min-f=~a gas-f=~a sched=~s"
                (macro-brain-decision-saving-for p-colossus-keep-450m-120g)
                (res-min-floor p-colossus-keep-450m-120g)
                (res-gas-floor p-colossus-keep-450m-120g)
                (macro-brain-decision-scheduled-ids p-colossus-keep-450m-120g)))

;; 2b. Protected `robotics-bay` (150M/150G) keeps mineral escrow intact at 420M/110G!
(reset-macro-escrow-tracker!)
(define p-robobay-keep-420m-110g
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8100
    #:minerals 420 #:gas 110 #:supply-used 62 #:supply-cap 86 #:supply-left 24 #:pending-supply 0
    #:workers 38 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 10
    #:army-supply 24 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 38 'stalker 8 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 2 'robotics-facility 0))))
(check! (and (eq? (macro-brain-decision-saving-for p-robobay-keep-420m-110g) 'robotics-bay)
             (>= (res-min-floor p-robobay-keep-420m-110g) 150)
             (>= (res-gas-floor p-robobay-keep-420m-110g) 150))
        (format "2b. Protected robotics-bay at 420M/110G must keep min-floor>=150 & gas-floor>=150; saving=~a min-f=~a gas-f=~a sched=~s"
                (macro-brain-decision-saving-for p-robobay-keep-420m-110g)
                (res-min-floor p-robobay-keep-420m-110g)
                (res-gas-floor p-robobay-keep-420m-110g)
                (macro-brain-decision-scheduled-ids p-robobay-keep-420m-110g)))

;; 2c. Protected `immortal` (250M/100G) keeps mineral escrow intact at 420M/70G!
(reset-macro-escrow-tracker!)
(define p-immortal-keep-420m-70g
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Protoss #:frame 6400
    #:minerals 420 #:gas 70 #:supply-used 52 #:supply-cap 78 #:supply-left 26 #:pending-supply 0
    #:workers 34 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 8
    #:army-supply 18 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 9 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 34 'stalker 6 'zealot 2 'observer 1)
    #:enemy-unit-counts (hasheq 'stalker 8 'immortal 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 4 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-immortal-keep-420m-70g) 'immortal)
             (>= (res-min-floor p-immortal-keep-420m-70g) 250)
             (>= (res-gas-floor p-immortal-keep-420m-70g) 100))
        (format "2c. Protected immortal at 420M/70G must keep min-floor>=250 & gas-floor>=100; saving=~a min-f=~a gas-f=~a sched=~s"
                (macro-brain-decision-saving-for p-immortal-keep-420m-70g)
                (res-min-floor p-immortal-keep-420m-70g)
                (res-gas-floor p-immortal-keep-420m-70g)
                (macro-brain-decision-scheduled-ids p-immortal-keep-420m-70g)))

;; 2d. Genuine gas starvation (500M / 20G waiting on a 150G non-protected upgrade `extended-thermal-lance`):
;;     releases min-floor -> 0 while preserving gas-floor >= 150!
(reset-macro-escrow-tracker!)
(define p-genuine-starve-500m-20g
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8800
    #:minerals 500 #:gas 20 #:supply-used 78 #:supply-cap 110 #:supply-left 32 #:pending-supply 0
    #:workers 50 #:active-bases 3 #:mineral-harvesters 44 #:gas-harvesters 6
    #:army-supply 28 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 8 'forge 1 'cybernetics-core 1 'twilight-council 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 2)
    #:total-building-counts (hasheq 'nexus 3 'pylon 14 'gateway 8 'forge 1 'cybernetics-core 1 'twilight-council 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 2)
    #:unit-counts (hasheq 'probe 50 'stalker 8 'immortal 2 'colossus 2 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 18 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 3 'gateway 4 'robotics-facility 0 'robotics-bay 1 'twilight-council 0 'forge 0))))
(check! (and (eq? (macro-brain-decision-saving-for p-genuine-starve-500m-20g) 'extended-thermal-lance)
             (= (res-min-floor p-genuine-starve-500m-20g) 0)
             (>= (res-gas-floor p-genuine-starve-500m-20g) 150))
        (format "2d. Genuine gas starvation 500M/20G waiting on 150G non-protected upgrade must release min-floor=0 & preserve gas-floor>=150; saving=~a min-f=~a gas-f=~a sched=~s"
                (macro-brain-decision-saving-for p-genuine-starve-500m-20g)
                (res-min-floor p-genuine-starve-500m-20g)
                (res-gas-floor p-genuine-starve-500m-20g)
                (macro-brain-decision-scheduled-ids p-genuine-starve-500m-20g)))

;; 2e. `min-overflow-gas-wait?` stays #f at 450M/140G (Zealot stays gas-locked below gas units while
;;     waiting on Colossus 200G), whereas genuine >= 480M + < 50G allows mineral-only combat sink!
(reset-macro-escrow-tracker!)
(define p-no-overflow-450m-140g
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Terran #:frame 8600
    #:minerals 450 #:gas 140 #:supply-used 68 #:supply-cap 94 #:supply-left 26 #:pending-supply 0
    #:workers 42 #:active-bases 2 #:mineral-harvesters 30 #:gas-harvesters 12
    #:army-supply 26 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:total-building-counts (hasheq 'nexus 2 'pylon 10 'gateway 4 'cybernetics-core 1
                                    'robotics-facility 1 'robotics-bay 1 'assimilator 4)
    #:unit-counts (hasheq 'probe 42 'stalker 8 'immortal 2 'zealot 2)
    #:enemy-unit-counts (hasheq 'marine 12 'marauder 4)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(check! (and (eq? (macro-brain-decision-saving-for p-no-overflow-450m-140g) 'colossus)
             (not (memq 'zealot (macro-brain-decision-scheduled-ids p-no-overflow-450m-140g)))
             (> (cand-u p-genuine-starve-500m-20g 'zealot)
                (cand-u p-no-overflow-450m-140g 'zealot)))
        (format "2e. 450M/140G must keep min-overflow-gas-wait?=#f (no zealot over colossus) while 500M/20G lifts zealot utility; 450M-sched=~s u450=~a u500=~a"
                (macro-brain-decision-scheduled-ids p-no-overflow-450m-140g)
                (cand-u p-no-overflow-450m-140g 'zealot)
                (cand-u p-genuine-starve-500m-20g 'zealot)))

;; =============================================================================
;; 3. Peaceful 3rd-Base Timings (`TvP` 5:15, `ZvP` 3:15-3:30 + Pool Guard, `PvZ` 5:00-5:30)
;;    + Active Attack / Rush Safety Guards
;; =============================================================================

;; 3a. Peaceful TvP 3rd CC at 5:15 (7056f), >= 34w, >= 10 army, >= 2 Rax, >= 225M -> u >= 615 & escrows CC!
(reset-macro-escrow-tracker!)
(define t-tvp-3rd-cc-515
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 7100
    #:minerals 240 #:gas 90 #:supply-used 52 #:supply-cap 78 #:supply-left 26 #:pending-supply 0
    #:workers 35 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 6
    #:army-supply 14 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
    #:unit-counts (hasheq 'scv 35 'marine 10 'marauder 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 1 'factory 0 'starport 0))))
(check! (and (>= (cand-u t-tvp-3rd-cc-515 'command-center) 615.0)
             (eq? (macro-brain-decision-saving-for t-tvp-3rd-cc-515) 'command-center)
             (not (memq 'barracks (macro-brain-decision-scheduled-ids t-tvp-3rd-cc-515))))
        (format "3a. Peaceful TvP 5:15 must promote 3rd CC (u>=615, blk=#t at 240M) ahead of redundant Rax; u=~a saving=~a sched=~s"
                (cand-u t-tvp-3rd-cc-515 'command-center)
                (macro-brain-decision-saving-for t-tvp-3rd-cc-515)
                (macro-brain-decision-scheduled-ids t-tvp-3rd-cc-515)))

;; 3b. TvP under active attack at 5:15 MUST NOT promote 3rd CC!
(reset-macro-escrow-tracker!)
(define t-tvp-3rd-cc-under-attack
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Protoss #:frame 7100
    #:minerals 240 #:gas 90 #:supply-used 52 #:supply-cap 78 #:supply-left 26 #:pending-supply 0
    #:workers 35 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 6
    #:army-supply 14 #:enemy-threat-supply 16 #:under-attack? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 7 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 1 'refinery 2)
    #:unit-counts (hasheq 'scv 35 'marine 10 'marauder 2)
    #:enemy-unit-counts (hasheq 'stalker 6 'zealot 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 2 'factory 1 'starport 0))))
(check! (and (not (eq? (macro-brain-decision-saving-for t-tvp-3rd-cc-under-attack) 'command-center))
             (not (memq 'command-center (macro-brain-decision-scheduled-ids t-tvp-3rd-cc-under-attack))))
        (format "3b. TvP under active attack must NOT escrow/build 3rd CC; saving=~a sched=~s"
                (macro-brain-decision-saving-for t-tvp-3rd-cc-under-attack)
                (macro-brain-decision-scheduled-ids t-tvp-3rd-cc-under-attack)))

;; 3c. Peaceful ZvP 3rd Hatchery at 3:30 (4704f), >= 28w, >= 180M (even before RW started!) -> u >= 608 & escrows Hatchery!
(reset-macro-escrow-tracker!)
(define z-zvp-3rd-hatch-330
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 4720
    #:minerals 190 #:gas 60 #:supply-used 38 #:supply-cap 52 #:supply-left 14 #:pending-supply 0
    #:workers 29 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 3
    #:army-supply 4 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:unit-counts (hasheq 'drone 29 'queen 2 'zergling 4 'overlord 5)
    #:open-facility-slots (hasheq 'townhall 2 'larva 4))))
(check! (and (>= (cand-u z-zvp-3rd-hatch-330 'hatchery) 608.0)
             (eq? (macro-brain-decision-saving-for z-zvp-3rd-hatch-330) 'hatchery))
        (format "3c. Peaceful ZvP 3:30 (>=28w, >=180M) must promote 3rd Hatch (u>=608, saving=hatchery); u=~a saving=~a sched=~s"
                (cand-u z-zvp-3rd-hatch-330 'hatchery)
                (macro-brain-decision-saving-for z-zvp-3rd-hatch-330)
                (macro-brain-decision-scheduled-ids z-zvp-3rd-hatch-330)))

;; 3d. ZvP under attack at 3:30 MUST NOT promote 3rd Hatchery!
(reset-macro-escrow-tracker!)
(define z-zvp-3rd-hatch-attack
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Protoss #:frame 4720
    #:minerals 190 #:gas 60 #:supply-used 38 #:supply-cap 52 #:supply-left 14 #:pending-supply 0
    #:workers 29 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 3
    #:army-supply 4 #:enemy-threat-supply 8 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 1)
    #:unit-counts (hasheq 'drone 29 'queen 2 'zergling 4 'overlord 5)
    #:enemy-unit-counts (hasheq 'zealot 2 'adept 2)
    #:open-facility-slots (hasheq 'townhall 2 'larva 4))))
(check! (and (not (eq? (macro-brain-decision-saving-for z-zvp-3rd-hatch-attack) 'hatchery))
             (not (memq 'hatchery (macro-brain-decision-scheduled-ids z-zvp-3rd-hatch-attack))))
        (format "3d. ZvP under attack must NOT escrow/build 3rd Hatch; saving=~a sched=~s"
                (macro-brain-decision-saving-for z-zvp-3rd-hatch-attack)
                (macro-brain-decision-scheduled-ids z-zvp-3rd-hatch-attack)))

;; 3e. `#47` Spawning-Pool Re-Save Guard: NEVER escrow `spawning-pool` when already started (`total=1`, `ready=0`) even under early rush!
(reset-macro-escrow-tracker!)
(define z-pool-already-building
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 2200
    #:minerals 140 #:gas 0 #:supply-used 18 #:supply-cap 22 #:supply-left 4 #:pending-supply 0
    #:workers 16 #:active-bases 1 #:mineral-harvesters 16 #:gas-harvesters 0
    #:army-supply 0 #:enemy-threat-supply 4 #:under-attack? #t
    #:ready-building-counts (hasheq 'hatchery 1)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1)
    #:unit-counts (hasheq 'drone 16 'overlord 2)
    #:enemy-unit-counts (hasheq 'reaper 2)
    #:open-facility-slots (hasheq 'townhall 1 'larva 2))))
(check! (and (not (eq? (macro-brain-decision-saving-for z-pool-already-building) 'spawning-pool))
             (not (memq 'spawning-pool (macro-brain-decision-scheduled-ids z-pool-already-building))))
        (format "3e. SpawningPool already started (total=1, ready=0) must NEVER be escrowed or re-scheduled; saving=~a sched=~s"
                (macro-brain-decision-saving-for z-pool-already-building)
                (macro-brain-decision-scheduled-ids z-pool-already-building)))

;; 3f. Peaceful PvZ 3rd Nexus at 5:05 (6832f), >= 36 probes, >= 10 army, >= 3 GW, >= 250M, >= 1 Immortal ->
;;     outranks redundant gateway/immortal loops and escrows Nexus!
(reset-macro-escrow-tracker!)
(define p-pvz-3rd-nexus-505
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 6832
    #:minerals 260 #:gas 120 #:supply-used 54 #:supply-cap 78 #:supply-left 24 #:pending-supply 0
    #:workers 37 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 8
    #:army-supply 12 #:enemy-threat-supply 0 #:under-attack? #f
    #:ready-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 37 'stalker 3 'zealot 1 'immortal 1)
    #:enemy-unit-counts (hasheq 'zergling 6 'roach 2)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(check! (and (>= (cand-u p-pvz-3rd-nexus-505 'nexus) 595.0)
             (eq? (macro-brain-decision-saving-for p-pvz-3rd-nexus-505) 'nexus)
             (not (memq 'immortal (macro-brain-decision-scheduled-ids p-pvz-3rd-nexus-505)))
             (not (memq 'gateway (macro-brain-decision-scheduled-ids p-pvz-3rd-nexus-505))))
        (format "3f. Peaceful PvZ 5:05 (>=1 Immortal, >=250M) must promote 3rd Nexus ahead of gateway/immortal; u=~a saving=~a sched=~s"
                (cand-u p-pvz-3rd-nexus-505 'nexus)
                (macro-brain-decision-saving-for p-pvz-3rd-nexus-505)
                (macro-brain-decision-scheduled-ids p-pvz-3rd-nexus-505)))

;; 3g. PvZ under mass-Roach attack MUST NOT promote 3rd Nexus (preserves Immortal lock)!
(reset-macro-escrow-tracker!)
(define p-pvz-3rd-nexus-roach-attack
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Protoss #:enemy-race 'Zerg #:frame 6832
    #:minerals 280 #:gas 120 #:supply-used 54 #:supply-cap 78 #:supply-left 24 #:pending-supply 0
    #:workers 37 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 8
    #:army-supply 12 #:enemy-threat-supply 16 #:under-attack? #t
    #:ready-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:total-building-counts (hasheq 'nexus 2 'pylon 8 'gateway 3 'cybernetics-core 1 'robotics-facility 1 'assimilator 3)
    #:unit-counts (hasheq 'probe 37 'stalker 3 'zealot 1 'immortal 1)
    #:enemy-unit-counts (hasheq 'roach 8)
    #:open-facility-slots (hasheq 'townhall 2 'gateway 3 'robotics-facility 1))))
(check! (and (not (eq? (macro-brain-decision-saving-for p-pvz-3rd-nexus-roach-attack) 'nexus))
             (not (memq 'nexus (macro-brain-decision-scheduled-ids p-pvz-3rd-nexus-roach-attack))))
        (format "3g. PvZ under mass-Roach attack must NOT escrow/build 3rd Nexus; saving=~a sched=~s"
                (macro-brain-decision-saving-for p-pvz-3rd-nexus-roach-attack)
                (macro-brain-decision-scheduled-ids p-pvz-3rd-nexus-roach-attack)))

(printf "l67-phase-d-macro-policy-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
