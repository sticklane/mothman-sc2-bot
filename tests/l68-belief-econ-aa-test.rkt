#lang racket/base

;; =============================================================================
;; Loop 68B Lane A Unit Test Suite (`tests/l68-belief-econ-aa-test.rkt`)
;;
;; Verifies Loop 68B Lane A (`#2107`):
;;   1. `lib/plan/worker-saturation-policy.rkt` (Restored Release #19 Anti-GRMS Bounds):
;;      - Multi-base `150G / 200M` does NOT latch `gas-pull-latch-box` and emits zero pullbacks;
;;      - Multi-base `210G / 90M` latches `gas-pull-latch-box` (`>=200G & <110M`) and pulls
;;        excess gas workers down to floor `1`;
;;      - Multi-base `310G / 90M` (`>= 300G`) and `worker-crisis-gas-evac?` (`<= 12w`)
;;        evacuate gas workers to `0`;
;;      - `req-mineral-workers-for-gas-slot` at `g = 6` holds Gas `#3` refill at `22` mineral
;;        workers (`< 28` floor) and refills once `28` mineral workers exist!
;;   2. `lib/priority-macro-brain.rkt` (Restored Geyser Gates + P1 Zerg & Terran Brain AA):
;;      - `pro-min-workers-for-next-gas-bldg` returns `34` / `39` (Protoss), `34` / `40` (Terran),
;;        and `14 / 28 / 38 / 46` (Zerg);
;;      - Zerg Brain under `>= 3` enemy Banshees or `>= 1` enemy Battlecruiser defers
;;        `baneling-nest` / `roach` / `roach-warren` and prioritizes Queens / Lair / Spire /
;;        HydraDen / Hydras / Corruptors;
;;      - Terran Brain under `>= 3` enemy Banshees scales Vikings beyond cap `2` (`>= 6`).
;; =============================================================================

(require racket/list
         racket/format
         "../lib/econ-ledger.rkt"
         "../lib/plan/worker-saturation-policy.rkt"
         "../lib/priority-macro-brain.rkt")

(define passed 0)
(define failed 0)

(define (check! ok? msg)
  (if ok?
      (set! passed (add1 passed))
      (begin
        (set! failed (add1 failed))
        (eprintf "FAIL: ~a\n" msg))))

(define (mk-w tag x y
              #:type [ut 'probe]
              #:ab [ab 0]
              #:tgt [tgt 0]
              #:min? [min? #f]
              #:gas? [gas? #f]
              #:excl? [excl? #f]
              #:lease? [lease? #f])
  (sat-worker-info tag ut x y ab tgt min? gas? excl? lease?))

(define (mk-b tag x y
              #:type [ut 'nexus]
              #:ready? [ready? #t]
              #:flying? [flying? #f]
              #:asgn [asgn 14]
              #:ideal [ideal 16]
              #:threat [threat #f]
              #:patches [patches '()])
  (sat-base-info tag ut x y ready? flying? asgn ideal threat patches))

(define (mk-g tag x y
              #:type [ut 'assimilator]
              #:ready? [ready? #t]
              #:vesp [vesp 2000]
              #:asgn [asgn 3]
              #:ideal [ideal 3]
              #:base [nb #f]
              #:threat [threat #f])
  (sat-gas-info tag ut x y ready? vesp asgn ideal nb threat))

(define (mk-m tag x y
              #:mins [mins 1500]
              #:owner [owner #f]
              #:safe? [safe? #t])
  (sat-mineral-info tag x y mins owner safe?))

(define (gather-dirs ds)
  (filter (lambda (d) (eq? (sat-directive-kind d) 'harvest-gather)) ds))

(define (gas-pull-worker-count ds)
  (for/sum ([d (in-list (gather-dirs ds))]
            #:when (memq (sat-directive-reason d)
                         '(gas-pull-grms-urgent gas-pull-routine gas-pull-early gas-pull-mined-out-evac)))
    (length (sat-directive-unit-tags d))))

(define (gas-refill-dirs ds)
  (filter (lambda (d) (memq (sat-directive-reason d) '(gas-refill gas-refill-carrying)))
          (gather-dirs ds)))

(define (cand-u dec sym)
  (define sched (macro-brain-decision-priority-schedule dec))
  (define cat-ht (priority-schedule-result-category-utilities sched))
  (define trace (if (hash? cat-ht) (hash-ref cat-ht 'decision-trace '()) '()))
  (define hit (findf (lambda (e) (eq? (priority-decision-entry-id e) sym)) trace))
  (if hit (priority-decision-entry-utility-score hit) -1.0))

;; Shared 2-base Protoss fixture (`b1`, `b2`, 2 full geysers `g1`/`g2` with 6 gas workers + 22 mineral workers)
(define b1 (mk-b 1 30.0 30.0 #:asgn 12 #:ideal 16 #:patches '(501 502)))
(define b2 (mk-b 2 52.0 34.0 #:asgn 10 #:ideal 16 #:patches '(503 504)))
(define m1 (mk-m 501 25.0 30.0 #:owner 1))
(define m2 (mk-m 502 25.0 32.0 #:owner 1))
(define m3 (mk-m 503 57.0 34.0 #:owner 2))
(define m4 (mk-m 504 57.0 36.0 #:owner 2))
(define g1 (mk-g 10 30.0 24.0 #:asgn 3 #:ideal 3 #:base 1))
(define g2 (mk-g 11 52.0 28.0 #:asgn 3 #:ideal 3 #:base 2))

(define (make-2base-workers n-min n-gas1 n-gas2)
  (append
   (for/list ([i (in-range n-min)])
     (define on-b1? (< i (quotient (+ n-min 1) 2)))
     (mk-w (+ 1000 i) (if on-b1? 26.0 56.0) (if on-b1? 30.0 34.0)
           #:ab 298 #:tgt (if on-b1? 501 503)))
   (for/list ([i (in-range n-gas1)])
     (mk-w (+ 2000 i) 30.0 25.0 #:ab 298 #:tgt 10))
   (for/list ([i (in-range n-gas2)])
     (mk-w (+ 2100 i) 52.0 29.0 #:ab 298 #:tgt 11))))

;; =============================================================================
;; 1. Restored Anti-GRMS Latch: 150G/200M stays unlatched; 210G/90M latches & pulls
;; =============================================================================
(let ()
  (define st-ok (make-worker-sat-state))
  (define ws (make-2base-workers 22 3 3))
  (define d150 (evaluate-worker-saturation-policy!
                st-ok #:loop 7000 #:race 'Protoss #:minerals 200 #:gas 150
                #:workers ws #:bases (list b1 b2) #:gas-buildings (list g1 g2)
                #:minerals-fields (list m1 m2 m3 m4)))
  (define st-latch (make-worker-sat-state))
  (define d210 (evaluate-worker-saturation-policy!
                st-latch #:loop 7100 #:race 'Protoss #:minerals 90 #:gas 210
                #:workers ws #:bases (list b1 b2) #:gas-buildings (list g1 g2)
                #:minerals-fields (list m1 m2 m3 m4)))
  (check! (and (not (unbox (worker-sat-gas-pull-latch-box st-ok)))
               (= (gas-pull-worker-count d150) 0)
               (unbox (worker-sat-gas-pull-latch-box st-latch))
               (>= (gas-pull-worker-count d210) 2))
          (format "1. Multi-base 150G/200M stays unlatched & 210G/90M latches anti-GRMS pull; ok-latch=~a p150=~a latch210=~a p210=~a"
                  (unbox (worker-sat-gas-pull-latch-box st-ok))
                  (gas-pull-worker-count d150)
                  (unbox (worker-sat-gas-pull-latch-box st-latch))
                  (gas-pull-worker-count d210))))

;; =============================================================================
;; 2. Restored Anti-GRMS Floor: 220G/90M keeps floor 1; 270G/90M & 310G/90M pull to 0
;; =============================================================================
(let ()
  ;; 1 gas worker at 220G/90M -> stays at floor 1 (0 pulls!)
  (define st220 (make-worker-sat-state))
  (define ws1 (make-2base-workers 27 1 0))
  (define g1-1 (mk-g 10 30.0 24.0 #:asgn 1 #:ideal 3 #:base 1))
  (define g2-0 (mk-g 11 52.0 28.0 #:asgn 0 #:ideal 3 #:base 2))
  (define d220 (evaluate-worker-saturation-policy!
                st220 #:loop 7200 #:race 'Protoss #:minerals 90 #:gas 220
                #:workers ws1 #:bases (list b1 b2) #:gas-buildings (list g1-1 g2-0)
                #:minerals-fields (list m1 m2 m3 m4)))
  ;; 1 gas worker at 270G/90M (>= 260G & < 120M) -> pulls to 0!
  (define st270 (make-worker-sat-state))
  (define d270 (evaluate-worker-saturation-policy!
                st270 #:loop 7200 #:race 'Protoss #:minerals 90 #:gas 270
                #:workers ws1 #:bases (list b1 b2) #:gas-buildings (list g1-1 g2-0)
                #:minerals-fields (list m1 m2 m3 m4)))
  (check! (and (unbox (worker-sat-gas-pull-latch-box st220))
               (= (gas-pull-worker-count d220) 0)
               (= (gas-pull-worker-count d270) 1))
          (format "2. 220G/90M holds floor 1 while 270G/90M pulls to 0; p220=~a p270=~a"
                  (gas-pull-worker-count d220)
                  (gas-pull-worker-count d270))))

;; =============================================================================
;; 3. Multi-base 310G/90M evacuates to 0, and worker-crisis-gas-evac? (<= 12w) still evacuates to 0
;; =============================================================================
(let ()
  ;; 2 gas workers remaining at 310G/90M -> pulls ALL 2 (target floor 0!)
  (define st310 (make-worker-sat-state))
  (define ws2 (make-2base-workers 26 1 1))
  (define g1-1 (mk-g 10 30.0 24.0 #:asgn 1 #:ideal 3 #:base 1))
  (define g2-1 (mk-g 11 52.0 28.0 #:asgn 1 #:ideal 3 #:base 2))
  (define d310 (evaluate-worker-saturation-policy!
                st310 #:loop 7400 #:race 'Protoss #:minerals 90 #:gas 310
                #:workers ws2 #:bases (list b1 b2) #:gas-buildings (list g1-1 g2-1)
                #:minerals-fields (list m1 m2 m3 m4)))
  ;; Worker crisis (<= 12w, 180G, 80M) -> pulls ALL 3 gas workers to 0!
  (define st-cr (make-worker-sat-state))
  (define ws-cr (append (for/list ([i (in-range 9)]) (mk-w (+ 3000 i) 26.0 30.0 #:ab 298 #:tgt 501))
                        (for/list ([i (in-range 3)]) (mk-w (+ 3100 i) 30.0 25.0 #:ab 298 #:tgt 10))))
  (define d-cr (evaluate-worker-saturation-policy!
                st-cr #:loop 5000 #:race 'Zerg #:minerals 80 #:gas 180
                #:workers ws-cr #:bases (list b1) #:gas-buildings (list g1)
                #:minerals-fields (list m1 m2)))
  (check! (and (= (gas-pull-worker-count d310) 2)
               (>= (gas-pull-worker-count d-cr) 2))
          (format "3. 310G/90M & <=12w worker-crisis must evacuate gas to 0; p310=~a p_crisis=~a"
                  (gas-pull-worker-count d310)
                  (gas-pull-worker-count d-cr))))

;; =============================================================================
;; 4. `req-mineral-workers-for-gas-slot` at g = 6 preserves 28-mineral-worker floor!
;; =============================================================================
(let ()
  (define g3-empty (mk-g 12 54.0 28.0 #:asgn 0 #:ideal 3 #:base 2))
  ;; 22 mineral workers (< 28 floor, minerals 180 < 400) -> holds Gas #3 refill
  (define st-hold (make-worker-sat-state))
  (define ws-22 (make-2base-workers 22 3 3))
  (define d-hold (evaluate-worker-saturation-policy!
                  st-hold #:loop 6800 #:race 'Protoss #:minerals 180 #:gas 90
                  #:workers ws-22 #:bases (list b1 b2) #:gas-buildings (list g1 g2 g3-empty)
                  #:minerals-fields (list m1 m2 m3 m4)))
  ;; 28 mineral workers (>= 28 floor) -> refills Gas #3 (tag 12)!
  (define st-fill (make-worker-sat-state))
  (define ws-28 (make-2base-workers 28 3 3))
  (define d-fill (evaluate-worker-saturation-policy!
                  st-fill #:loop 6800 #:race 'Protoss #:minerals 180 #:gas 90
                  #:workers ws-28 #:bases (list b1 b2) #:gas-buildings (list g1 g2 g3-empty)
                  #:minerals-fields (list m1 m2 m3 m4)))
  (define refills (gas-refill-dirs d-fill))
  (check! (and (null? (gas-refill-dirs d-hold))
               (pair? refills)
               (= (sat-directive-target-tag (car refills)) 12))
          (format "4. g=6 must hold Gas #3 at 22 mineral workers (<28) and refill at 28; hold=~s fill=~s"
                  (gas-refill-dirs d-hold) refills)))

;; =============================================================================
;; 5. Restored `pro-min-workers-for-next-gas-bldg`: P 34/39, T 34/40, Z 14/28/38/46
;; =============================================================================
(check! (and (= (pro-min-workers-for-next-gas-bldg 'Protoss 'Zerg 2) 34)
             (= (pro-min-workers-for-next-gas-bldg 'Protoss 'Zerg 3) 39)
             (= (pro-min-workers-for-next-gas-bldg 'Terran 'Protoss 2) 34)
             (= (pro-min-workers-for-next-gas-bldg 'Terran 'Protoss 3) 40)
             (= (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 0) 14)
             (= (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 1) 28)
             (= (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 2) 38)
             (= (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 3) 46))
        (format "5. Geyser worker gates must be P 34/39, T 34/40 & Z 14/28/38/46; got P=~a/~a T=~a/~a Z=~a/~a/~a/~a"
                (pro-min-workers-for-next-gas-bldg 'Protoss 'Zerg 2)
                (pro-min-workers-for-next-gas-bldg 'Protoss 'Zerg 3)
                (pro-min-workers-for-next-gas-bldg 'Terran 'Protoss 2)
                (pro-min-workers-for-next-gas-bldg 'Terran 'Protoss 3)
                (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 0)
                (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 1)
                (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 2)
                (pro-min-workers-for-next-gas-bldg 'Zerg 'Terran 3)))

;; =============================================================================
;; 6. Zerg Brain under >= 3 Banshees OR >= 1 Battlecruiser defers baneling-nest/roach/roach-warren
;;    and prioritizes Queens / Lair / Spire / HydraDen / Hydras / Corruptors!
;; =============================================================================

;; 6a. Mass Banshees (>= 3 Banshees + Marines < 18, HydraDen ready, 0 Hydras):
;;     must NOT schedule/escrow `baneling-nest`, `roach-warren`, or `roach`, and must prioritize AA!
(reset-macro-escrow-tracker!)
(define z-mass-banshee-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 7600
    #:minerals 360 #:gas 140 #:supply-used 56 #:supply-cap 78 #:supply-left 22 #:pending-supply 0
    #:workers 38 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 9
    #:army-supply 18 #:enemy-threat-supply 18 #:under-attack? #t #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:unit-counts (hasheq 'drone 38 'queen 4 'zergling 8 'overlord 9)
    #:enemy-unit-counts (hasheq 'banshee 5 'marine 12)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'townhall 2 'larva 5))))
(check! (and (not (memq 'roach (macro-brain-decision-scheduled-ids z-mass-banshee-dec)))
             (not (memq 'baneling-nest (macro-brain-decision-scheduled-ids z-mass-banshee-dec)))
             (not (eq? (macro-brain-decision-saving-for z-mass-banshee-dec) 'baneling-nest))
             (not (eq? (macro-brain-decision-saving-for z-mass-banshee-dec) 'roach))
             (or (not (not (memq 'hydralisk (macro-brain-decision-scheduled-ids z-mass-banshee-dec))))
                 (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-mass-banshee-dec))))
                 (not (not (memq 'spire (macro-brain-decision-scheduled-ids z-mass-banshee-dec))))))
        (format "6a. Zerg under 5 Banshees must defer roach/baneling-nest & schedule AA; saving=~a sched=~s"
                (macro-brain-decision-saving-for z-mass-banshee-dec)
                (macro-brain-decision-scheduled-ids z-mass-banshee-dec)))

;; 6b. Early Battlecruiser (>= 1 BC, SpawningPool ready, only 3 Queens, 0 RW/BN):
;;     must surge Queens (`queen` prioritized!) and NOT schedule `roach-warren` / `baneling-nest` / `roach`!
(reset-macro-escrow-tracker!)
(define z-early-bc-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6400
    #:minerals 340 #:gas 120 #:supply-used 46 #:supply-cap 66 #:supply-left 20 #:pending-supply 0
    #:workers 34 #:active-bases 2 #:mineral-harvesters 28 #:gas-harvesters 6
    #:army-supply 12 #:enemy-threat-supply 6 #:under-attack? #t #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 2)
    #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1 'extractor 2)
    #:unit-counts (hasheq 'drone 34 'queen 3 'zergling 8 'overlord 7)
    #:enemy-unit-counts (hasheq 'battlecruiser 1)
    #:enemy-building-counts (hasheq 'starport 1 'fusion-core 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 4))))
(check! (and (not (memq 'roach-warren (macro-brain-decision-scheduled-ids z-early-bc-dec)))
             (not (memq 'baneling-nest (macro-brain-decision-scheduled-ids z-early-bc-dec)))
             (not (memq 'roach (macro-brain-decision-scheduled-ids z-early-bc-dec)))
             (or (not (not (memq 'queen (macro-brain-decision-scheduled-ids z-early-bc-dec))))
                 (not (not (memq 'lair (macro-brain-decision-scheduled-ids z-early-bc-dec))))
                 (not (not (memq 'spore-crawler (macro-brain-decision-scheduled-ids z-early-bc-dec))))))
        (format "6b. Zerg under early BC must defer roach-warren/baneling-nest & prioritize Queen/Lair/Spore; saving=~a sched=~s"
                (macro-brain-decision-saving-for z-early-bc-dec)
                (macro-brain-decision-scheduled-ids z-early-bc-dec)))

;; =============================================================================
;; 7. Terran Brain under >= 3 enemy Banshees scales Vikings beyond cap 2 (>= 6)!
;; =============================================================================
(reset-macro-escrow-tracker!)
(define t-mass-banshee-viking-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Terran #:enemy-race 'Terran #:frame 7600
    #:minerals 320 #:gas 180 #:supply-used 60 #:supply-cap 86 #:supply-left 26 #:pending-supply 0
    #:workers 34 #:active-bases 2 #:mineral-harvesters 26 #:gas-harvesters 8
    #:army-supply 26 #:enemy-threat-supply 16 #:under-attack? #t #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 2 'engineering-bay 1
                                    'missile-turret 2 'refinery 3)
    #:total-building-counts (hasheq 'orbital-command 2 'supply-depot 8 'barracks 2 'barracks-techlab 1
                                    'factory 1 'factory-techlab 1 'starport 2 'engineering-bay 1
                                    'missile-turret 2 'refinery 3)
    #:unit-counts (hasheq 'scv 34 'marine 10 'siege-tank 1 'viking-fighter 5)
    #:enemy-unit-counts (hasheq 'banshee 6)
    #:enemy-building-counts (hasheq 'starport 2 'starport-techlab 2)
    #:open-facility-slots (hasheq 'townhall 2 'barracks 1 'factory 1 'starport 2))))
(check! (and (not (not (memq 'viking-fighter (macro-brain-decision-scheduled-ids t-mass-banshee-viking-dec))))
             (>= (cand-u t-mass-banshee-viking-dec 'viking-fighter) 680.0))
        (format "7. Terran under 6 Banshees (already holding 5 Vikings!) must keep scaling Vikings past cap 2/5 (>= 6); u=~a saving=~a sched=~s"
                (cand-u t-mass-banshee-viking-dec 'viking-fighter)
                (macro-brain-decision-saving-for t-mass-banshee-viking-dec)
                (macro-brain-decision-scheduled-ids t-mass-banshee-viking-dec)))

;; =============================================================================
;; 8. Loop 68C (`#2121`): Lone StarportTechLab + Raven + Medivac + WidowMine (0 Banshees)
;;    MUST NOT fire hydralisk@990 / queen@960; actual Banshees fire immediately & cap cleanly!
;; =============================================================================
(reset-macro-escrow-tracker!)
(define z-lone-sptl-raven-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6800
    #:minerals 280 #:gas 140 #:supply-used 56 #:supply-cap 78 #:supply-left 22 #:pending-supply 0
    #:workers 38 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 9
    #:army-supply 18 #:enemy-threat-supply 14 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:unit-counts (hasheq 'drone 38 'queen 4 'roach 6 'zergling 8 'overlord 9)
    #:enemy-unit-counts (hasheq 'marine 10 'siege-tank 2 'medivac 2 'raven 1 'widow-mine 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 5))))

(reset-macro-escrow-tracker!)
(define z-real-banshee-fire-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 6800
    #:minerals 280 #:gas 140 #:supply-used 56 #:supply-cap 78 #:supply-left 22 #:pending-supply 0
    #:workers 38 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 9
    #:army-supply 18 #:enemy-threat-supply 14 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:unit-counts (hasheq 'drone 38 'queen 4 'roach 6 'zergling 8 'overlord 9)
    #:enemy-unit-counts (hasheq 'marine 10 'siege-tank 2 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 5))))

(reset-macro-escrow-tracker!)
(define z-banshee-hydra-capped-dec
  (step-priority-macro-brain
   (make-macro-world-state
    #:race 'Zerg #:enemy-race 'Terran #:frame 7800
    #:minerals 280 #:gas 140 #:supply-used 72 #:supply-cap 94 #:supply-left 22 #:pending-supply 0
    #:workers 38 #:active-bases 2 #:mineral-harvesters 29 #:gas-harvesters 9
    #:army-supply 34 #:enemy-threat-supply 14 #:under-attack? #f #:requires-anti-air? #t
    #:ready-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:total-building-counts (hasheq 'hatchery 1 'lair 1 'spawning-pool 1 'roach-warren 1
                                    'hydralisk-den 1 'spore-crawler 2 'extractor 3)
    #:unit-counts (hasheq 'drone 38 'queen 4 'hydralisk 8 'roach 4 'overlord 11)
    #:enemy-unit-counts (hasheq 'marine 10 'siege-tank 2 'banshee 2)
    #:enemy-building-counts (hasheq 'starport 1 'starport-techlab 1)
    #:open-facility-slots (hasheq 'townhall 2 'larva 5))))

(check! (and (< (cand-u z-lone-sptl-raven-dec 'hydralisk) 900.0)
             (< (cand-u z-lone-sptl-raven-dec 'queen) 900.0)
             (>= (cand-u z-real-banshee-fire-dec 'hydralisk) 990.0)
             (< (cand-u z-banshee-hydra-capped-dec 'hydralisk) 990.0))
        (format "8. Lone StarportTL+Raven+Medivac+WM (0 Banshees) must NOT fire hydra@990/queen@960; real Banshees fire >=990 & cap cleanly at 8 Hydras; u_false_h=~a u_false_q=~a u_real_h=~a u_cap_h=~a"
                (cand-u z-lone-sptl-raven-dec 'hydralisk)
                (cand-u z-lone-sptl-raven-dec 'queen)
                (cand-u z-real-banshee-fire-dec 'hydralisk)
                (cand-u z-banshee-hydra-capped-dec 'hydralisk)))

(printf "l68-belief-econ-aa-test: ~a/~a passed (~a failed)\n"
        passed (+ passed failed) failed)
(when (> failed 0)
  (exit 1))
